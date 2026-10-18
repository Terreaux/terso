// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import PDFKit
import SwiftUI
import TersoCore

// Manutius for LaTeX: TeX has already set the book, so Terso shows the pages
// Tectonic makes instead of drawing its own. The source stays as written.

/// A LaTeX book's chapter-level headings, in the order TeX sets them:
/// `\part` and `\chapter`, or `\section` when the class has no chapters.
struct LaTeXHeading: Equatable {
    var range: NSRange
    var title: String
    var part: Bool

    static func scan(_ text: String) -> [LaTeXHeading] {
        let ns = text as NSString
        let preamble = LaTeXSyntax.preamble(in: text)?.upperBound ?? 0
        let end = LaTeXSyntax.trailer(in: text)?.location ?? ns.length
        let literal = LaTeXSyntax.literalEnvironments(in: text).map(\.range)
        let found = LaTeXSyntax.section.matches(in: text, range: NSRange(location: preamble, length: end - preamble)).filter { m in
            !literal.contains { NSIntersectionRange($0, m.range).length > 0 } && !commented(m.range.location, in: ns)
        }
        let command = { (m: NSTextCheckingResult) in ns.substring(with: m.range(at: 1)) }
        let level = found.contains { command($0) == "chapter" } ? "chapter" : "section"
        return found.compactMap { m in
            let name = command(m)
            guard name == "part" || name == level else { return nil }
            return LaTeXHeading(range: m.range, title: LaTeXSyntax.plainTitle(ns.substring(with: m.range(at: 2))), part: name == "part")
        }
    }

    /// Whether an unescaped `%` earlier on the line makes this a comment.
    static func commented(_ location: Int, in ns: NSString) -> Bool {
        let line = ns.lineRange(for: NSRange(location: location, length: 0))
        var escaped = false
        for c in ns.substring(with: NSRange(location: line.location, length: location - line.location)) {
            if c == "%" && !escaped { return true }
            escaped = c == "\\" && !escaped
        }
        return false
    }
}

/// How a printed book opens: the first page alone on the right, then each
/// verso beside its recto. Pages count from zero.
enum BookSpreads {
    /// Spreads a book of `pages` opens to.
    static func count(pages: Int) -> Int { pages == 0 ? 0 : pages / 2 + 1 }

    /// Spread 0 is the first recto alone; spread n holds pages 2n-1 and 2n.
    static func pages(inSpread spread: Int, of pages: Int) -> (verso: Int?, recto: Int?) {
        let verso = spread * 2 - 1, recto = spread * 2
        return (verso >= 0 && verso < pages ? verso : nil, recto < pages ? recto : nil)
    }

    static func spread(of page: Int) -> Int { (page + 1) / 2 }

    /// Facing pages need room for two pages side by side at a readable
    /// width; a landscape page always stands alone.
    static func facing(width: CGFloat, page: CGSize, minimum: CGFloat = 300) -> Bool {
        page.width < page.height && width >= minimum * 2 + 48
    }
}

/// Where each chapter opens in a compiled PDF: the PDF's own outline when
/// hyperref wrote one, else the first page after the last chapter whose text
/// carries the title, contents pages passed over.
enum PDFChapterPages {
    /// Letters and figures only, folded, so TeX's ligatures, quotes and line
    /// breaks don't stand between a title and its page.
    static func key(_ s: String) -> String {
        String(String.UnicodeScalarView(s.precomposedStringWithCompatibilityMapping.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains)))
    }

    static func locate(_ titles: [String], outline: [(label: String, page: Int)], pages: Int, text: (Int) -> String) -> [Int?] {
        let entries = outline.map { (key: key($0.label), page: $0.page) }
        var keys: [Int: (key: String, contents: Bool)] = [:]
        func page(_ i: Int) -> (key: String, contents: Bool) {
            if let known = keys[i] { return known }
            let raw = text(i)
            let contents = raw.split(whereSeparator: \.isNewline).contains {
                let line = $0.trimmingCharacters(in: .whitespaces).lowercased()
                return line == "contents" || line == "table of contents"
            }
            keys[i] = (key(raw), contents)
            return keys[i]!
        }
        var from = 0, used = 0
        return titles.map { title -> Int? in
            let k = key(title)
            guard !k.isEmpty else { return nil }
            if let j = entries[used...].firstIndex(where: { $0.page >= from && labels($0.key, k) }) {
                used = j + 1; from = entries[j].page
                return from
            }
            let hits = (from..<max(from, pages)).filter { !page($0).contents && page($0).key.contains(k) }
            // Best a page that opens with the title, as a chapter's first
            // page does; then one with it near the top; then anywhere.
            func before(_ i: Int) -> String { page(i).key.range(of: k).map { String(page(i).key[..<$0.lowerBound]) } ?? "" }
            let opens = hits.first { before($0).wholeMatch(of: /(chapter|part|appendix)?([0-9]+|[ivxlcdm]+|[a-z])?/) != nil }
            let top = hits.first { before($0).count < 160 }
            guard let found = opens ?? top ?? hits.first else { return nil }
            from = found
            return found
        }
    }

    /// An outline label for the title, numbered or not: "2 Title", "IV Title", "A Title".
    static func labels(_ label: String, _ title: String) -> Bool {
        guard label.hasSuffix(title) else { return false }
        let number = label.dropLast(title.count)
        return number.isEmpty || number.allSatisfy(\.isNumber) || number.allSatisfy("ivxlcdm".contains) || number.count == 1
    }

    static func outline(of document: PDFDocument) -> [(label: String, page: Int)] {
        var entries: [(label: String, page: Int)] = []
        func walk(_ node: PDFOutline) {
            for i in 0..<node.numberOfChildren {
                guard let child = node.child(at: i) else { continue }
                if let label = child.label, let page = child.destination?.page { entries.append((label, document.index(for: page))) }
                walk(child)
            }
        }
        if let root = document.outlineRoot { walk(root) }
        return entries
    }
}

/// The compiled book: Tectonic's pages, where its chapters fall, and the
/// view showing them. Edits are typeset once typing pauses; a compile under
/// way runs to the end and the latest text follows it.
@MainActor @Observable final class LaTeXBook {
    /// The document is LaTeX, so Manutius shows these pages.
    var isLaTeX = false
    private(set) var document: PDFDocument?
    /// Counts compiles that changed the pages, so thumbnails redraw.
    private(set) var generation = 0
    let compiler: TectonicPreviewModel = { let c = TectonicPreviewModel(); c.keepsLastPages = true; return c }()
    /// Each compiled heading, by title, with the page it opens on.
    private(set) var placed: [(key: String, page: Int?)] = []

    @ObservationIgnored weak var view: PDFView?
    @ObservationIgnored private var wanted: (source: String, fileURL: URL?)?
    @ObservationIgnored private var typeset: String?
    @ObservationIgnored private var data: Data?
    @ObservationIgnored private var fetch = false
    @ObservationIgnored private var pause: Task<Void, Never>?
    @ObservationIgnored private var run: Task<Void, Never>?
    @ObservationIgnored var onTypeset: (() -> Void)?

    var pageCount: Int { document?.pageCount ?? 0 }

    /// The first page's size in points.
    var pageSize: CGSize? { document?.page(at: 0)?.bounds(for: .mediaBox).size }

    var trimTitle: String? { pageSize.map(Self.trim) }

    /// The page's printed number: its label, as `\frontmatter` sets roman ones.
    func folio(_ index: Int) -> String { document?.page(at: index)?.label ?? "\(index + 1)" }

    /// Typesets `source` once typing has paused, at once for the first pages.
    func schedule(_ source: String, fileURL: URL?) {
        wanted = (source, fileURL)
        guard source != typeset else { return }
        pause?.cancel()
        let wait = document == nil ? Duration.zero : .milliseconds(1200)
        pause = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            self?.start()
        }
    }

    /// Compiles again, fetching packages Tectonic hasn't cached.
    func fetchMissing() {
        fetch = true; typeset = nil
        start()
    }

    // The compile runs in its own task so a newer edit never cancels it;
    // the loop then typesets whatever arrived meanwhile.
    private func start() {
        guard run == nil else { return }
        run = Task { [weak self] in
            while let self, let next = self.wanted, next.source != self.typeset {
                self.typeset = next.source
                let fetch = self.fetch; self.fetch = false
                await self.compiler.compile(source: next.source, fileURL: next.fileURL, onlyCached: !fetch)
                self.update(next.source)
            }
            self?.run = nil
        }
    }

    private func update(_ source: String) {
        guard let pdf = compiler.pdf, pdf != data, let new = PDFDocument(data: pdf) else { return }
        data = pdf
        let headings = LaTeXHeading.scan(source)
        let pages = PDFChapterPages.locate(headings.map(\.title), outline: PDFChapterPages.outline(of: new), pages: new.pageCount) {
            new.page(at: $0)?.string ?? ""
        }
        placed = zip(headings, pages).map { (PDFChapterPages.key($0.title), $1) }
        document = new
        generation += 1
        onTypeset?()
    }

    /// Turns the pages view to `index`.
    func reveal(page index: Int) {
        guard let view, let page = document?.page(at: index) else { return }
        view.go(to: page)
    }

    /// Manutius's chapters for the current text, with the pages the last
    /// compile found them on. A heading matches the compiled one of the same
    /// title, in order, so pages hold while new headings wait to be typeset.
    func outline(for text: String) -> BookOutline {
        let headings = LaTeXHeading.scan(text)
        var cursor = 0
        let pages: [Int?] = headings.map { heading in
            let k = PDFChapterPages.key(heading.title)
            guard let j = placed[cursor...].firstIndex(where: { $0.key == k }) else { return nil }
            cursor = j + 1
            return placed[j].page
        }
        var outline = BookOutline()
        outline.pages = pageCount
        outline.chapters = headings.enumerated().map { i, heading in
            let first = pages[i]
            let next = first.flatMap { f in pages[(i + 1)...].compactMap { $0 }.first { $0 > f } } ?? pageCount
            return .init(id: i, title: heading.title, heading: heading.range,
                         first: first.map(folio), last: first.map { folio(max($0, next - 1)) }, part: heading.part, page: first)
        }
        return outline
    }

    /// A page size as a printer names it.
    static func trim(_ points: CGSize) -> String {
        let inches = CGSize(width: points.width / 72, height: points.height / 72)
        let named: [(String, CGSize)] = [("US Letter", CGSize(width: 8.5, height: 11)), ("A4", CGSize(width: 8.27, height: 11.69)),
                                         ("A5", CGSize(width: 5.83, height: 8.27)), ("B5", CGSize(width: 6.93, height: 9.84))]
            + BookTrim.allCases.map { ($0.title, $0.inches) }
        if let name = named.first(where: { abs($0.1.width - inches.width) < 0.03 && abs($0.1.height - inches.height) < 0.03 })?.0 {
            return name
        }
        let f = { (v: CGFloat) in Double(v).formatted(.number.precision(.fractionLength(0...2))) }
        return "\(f(inches.width)) × \(f(inches.height)) in"
    }
}

// MARK: - The pages

/// The compiled pages as an open book, typeset again as the source changes.
struct LaTeXBookPages: View {
    let model: WorkspaceModel
    let source: String
    let fileURL: URL?

    private var book: LaTeXBook { model.latexBook }

    var body: some View {
        ZStack {
            Color(nsColor: model.prefs.theme.background)
            if let document = book.document {
                PDFPages(book: book, document: document, background: model.prefs.theme.background)
            } else if book.compiler.running {
                ProgressView("Typesetting LaTeX…").controlSize(.small)
            } else if book.compiler.error == nil {
                ProgressView().controlSize(.small)
            }
            if book.compiler.error != nil {
                VStack { Spacer(); LaTeXBookProblem(book: book).padding(.bottom, 36) }
            }
        }
        .overlay(alignment: .topTrailing) {
            if book.compiler.running && book.document != nil {
                ProgressView().controlSize(.small).padding(10).help("Typesetting LaTeX…")
            }
        }
        .onAppear {
            book.onTypeset = { [weak model = model] in (model?.editor as? EditorCoordinator)?.refreshBookOutline() }
            book.schedule(source, fileURL: fileURL)
        }
        .onChange(of: source) { _, new in book.schedule(new, fileURL: fileURL) }
        .onChange(of: fileURL) { _, new in book.schedule(source, fileURL: new) }
        .accessibilityLabel("Typeset pages")
    }
}

/// A compile that failed, over the last pages that didn't.
private struct LaTeXBookProblem: View {
    let book: LaTeXBook
    @State private var showLog = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            Text(book.document == nil ? (book.compiler.error ?? "") : "The last edit didn't typeset; these are the pages before it.")
                .font(.callout).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if !book.compiler.log.isEmpty {
                Button("Log") { showLog.toggle() }
                    .popover(isPresented: $showLog) {
                        ScrollView { Text(book.compiler.log).font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding(10) }
                            .frame(width: 520, height: 300)
                    }
            }
            if TectonicPreviewModel.executable != nil {
                Button("Fetch Packages") { book.fetchMissing() }.help("Compile again, fetching packages Tectonic hasn't cached")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        .frame(maxWidth: 560)
        .padding(.horizontal, 16)
    }
}

/// PDFKit's book display: two-up with the first page alone on the right,
/// or one page at a time when two won't fit.
private struct PDFPages: NSViewRepresentable {
    let book: LaTeXBook
    let document: PDFDocument
    let background: NSColor

    func makeNSView(context: Context) -> BookPDFView {
        let view = BookPDFView()
        view.autoScales = true
        view.displaysAsBook = true
        view.displayMode = .singlePageContinuous
        view.document = document
        book.view = view
        return view
    }

    func updateNSView(_ view: BookPDFView, context: Context) {
        view.backgroundColor = background
        book.view = view
        guard view.document !== document else { return }
        // A new compile keeps the reader on the page they were reading.
        let index = view.currentPage.flatMap { view.document?.index(for: $0) }
        let point = view.currentDestination?.point
        view.document = document
        view.updateSpreads()
        if let index, let page = document.page(at: min(index, document.pageCount - 1)) {
            view.go(to: PDFDestination(page: page, at: point ?? NSPoint(x: 0, y: page.bounds(for: .mediaBox).maxY)))
        }
    }
}

final class BookPDFView: PDFView {
    override func layout() {
        super.layout()
        updateSpreads()
    }

    func updateSpreads() {
        guard let size = document?.page(at: 0)?.bounds(for: .mediaBox).size else { return }
        let mode: PDFDisplayMode = BookSpreads.facing(width: bounds.width, page: size) ? .twoUpContinuous : .singlePageContinuous
        if displayMode != mode { displayMode = mode; displaysAsBook = true }
    }
}

// MARK: - Whole Book

/// One compiled page, small.
struct PDFPageThumbnail: View {
    let book: LaTeXBook
    let index: Int
    let width: CGFloat
    let open: () -> Void
    @State private var image: NSImage?

    var body: some View {
        let size = book.pageSize ?? CGSize(width: 2, height: 3)
        let height = width * size.height / max(1, size.width)
        Button(action: open) {
            Group {
                if let image { Image(nsImage: image).resizable().interpolation(.high) } else { Rectangle().fill(.white) }
            }
            .frame(width: width, height: height)
            .overlay(alignment: .bottom) {
                Text(book.folio(index)).font(.caption2).monospacedDigit().foregroundStyle(.secondary).offset(y: 16)
            }
        }
        .buttonStyle(.plain)
        .help("Turn to page \(book.folio(index))")
        .accessibilityLabel("Page \(book.folio(index))")
        .task(id: book.generation) {
            image = book.document?.page(at: index)?.thumbnail(of: NSSize(width: width * 2, height: height * 2), for: .mediaBox)
        }
    }
}

// MARK: - Inspector

/// The Book tab for a LaTeX document: the preamble sets the book, so the
/// tab says what it made rather than offering Terso's design.
struct LaTeXBookSummary: View {
    let model: WorkspaceModel

    var body: some View {
        let book = model.latexBook
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Label("Typeset by your preamble", systemImage: "text.book.closed").font(.headline)
                Text("These are the pages LaTeX makes. Trim, type, margins and chapter style come from the document class and the packages the preamble loads.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    GridRow { Text("Trim").foregroundStyle(.secondary); Text(book.trimTitle ?? "—") }
                    if let size = book.pageSize {
                        GridRow {
                            Text("")
                            Text("\(Int(size.width.rounded())) × \(Int(size.height.rounded())) pt").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    GridRow { Text("Pages").foregroundStyle(.secondary); Text(book.document == nil ? "—" : "\(book.pageCount)") }
                    GridRow { Text("Chapters").foregroundStyle(.secondary); Text("\(model.bookOutline.chapters.filter { !$0.part }.count)") }
                }
                .monospacedDigit()
                if book.compiler.running {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Typesetting…").foregroundStyle(.secondary) }.font(.callout)
                } else if let error = book.compiler.error {
                    Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Set Up as Book gives it Manutius's design instead: one \\usepackage line in the preamble and terso-book.sty beside the file. Anything your preamble already sets stays as it is.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Set Up as Book") { model.setUpAsBook() }
                        .help("Load terso-book in the preamble, so the Book tab's controls set this book")
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                Divider()
                WordGoal(model: model)
                HStack {
                    Spacer()
                    Button("Whole Book…") { model.showBookOverview = true }.disabled(book.document == nil)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
