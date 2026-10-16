// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import SwiftUI
import TersoCore

/// Manutius's chapters as they fall on the pages, gathered after layout so
/// the sidebar, inspector and status line can show them without laying out.
struct BookOutline: Equatable {
    struct Chapter: Equatable, Identifiable {
        let id: Int
        let title: String
        let heading: NSRange
        /// Folios of the chapter's first and last pages.
        var first: String?
        var last: String?
    }
    var chapters: [Chapter] = []
    /// Every page, front matter to back.
    var pages = 0
    /// The chapter and folio the caret is in.
    var current: Int?
    var page: String?
}

extension EditorCoordinator {
    /// Lays the book out to the end and records where each chapter falls.
    func refreshBookOutline() {
        guard let tv = textView, let book = tv.book, let lm = tv.layoutManager, let container = tv.textContainer else {
            if model.bookOutline != BookOutline() { model.bookOutline = BookOutline() }
            return
        }
        lm.ensureLayout(for: container)
        let end = tv.bookTextEnd(book) ?? book.front
        let placed = tv.chapterPlacements(book, before: Int(Int32.max))
        let firsts = placed.map(\.page)
        var outline = BookOutline()
        outline.chapters = tv.bookDecoration.chapters.enumerated().map { i, chapter in
            let first = placed.first { $0.heading == chapter.heading }?.page
            let next = firsts.first { first != nil && $0 > first! } ?? end + 1
            return .init(id: i, title: chapter.title, heading: chapter.heading,
                         first: first.map(book.folio), last: first.map { _ in book.folio(max(first!, next - 1)) })
        }
        outline.pages = end + 1 + book.back
        locate(in: &outline)
        if outline != model.bookOutline { model.bookOutline = outline }
    }

    /// Notes the caret's chapter and page, from layout already done.
    func refreshBookPosition() {
        var outline = model.bookOutline
        locate(in: &outline)
        if outline != model.bookOutline { model.bookOutline = outline }
    }

    private func locate(in outline: inout BookOutline) {
        guard let tv = textView, let book = tv.book, let lm = tv.layoutManager else { return }
        let caret = tv.selectedRange().location
        outline.current = outline.chapters.last { $0.heading.location <= caret }?.id
        guard lm.numberOfGlyphs > 0 else { outline.page = book.folio(book.front); return }
        let glyph = min(lm.glyphIndexForCharacter(at: caret), lm.numberOfGlyphs - 1)
        guard glyph < lm.firstUnlaidGlyphIndex() else { return }
        let line = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        outline.page = book.folio(book.page(at: line.origin))
    }

    /// Lays out and outlines the book once typing pauses.
    func scheduleBookOutline() {
        outlineTask?.cancel()
        guard config?.book != nil else { refreshBookOutline(); return }
        outlineTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.refreshBookOutline()
        }
    }

    /// A new chapter at the end of the book, with the caret in its title.
    func appendChapter() {
        guard let tv = textView else { return }
        let ns = tv.string as NSString
        let number = BookChapter.scan(tv.string).count + 1
        let lead = ns.length == 0 ? "" : tv.string.hasSuffix("\n\n") ? "" : tv.string.hasSuffix("\n") ? "\n" : "\n\n"
        let title = "Chapter \(number)"
        replace(TextSpan(location: ns.length, length: 0), with: lead + "# " + title + "\n\n", actionName: "Add Chapter")
        let start = ns.length + (lead as NSString).length + 2
        tv.setSelectedRange(NSRange(location: start, length: (title as NSString).length))
        tv.scrollRangeToVisible(tv.selectedRange())
        tv.window?.makeFirstResponder(tv)
    }
}

// MARK: - Sidebar: the chapters

/// In Manutius the sidebar's outline becomes the book's chapters, each with
/// the pages it takes; a click turns to it.
struct BookChapters: View {
    let model: WorkspaceModel

    var body: some View {
        if model.bookOutline.chapters.isEmpty {
            Text("Each # heading starts a chapter").foregroundStyle(.tertiary)
        }
        ForEach(model.bookOutline.chapters) { chapter in
            ChapterRow(chapter: chapter, current: chapter.id == model.bookOutline.current) {
                model.editor?.reveal(TextSpan(location: chapter.heading.location, length: 0), select: true)
            }
        }
    }
}

struct BookChaptersHeader: View {
    let model: WorkspaceModel

    var body: some View {
        HStack {
            Text("Chapters")
            Spacer()
            Button { (model.editor as? EditorCoordinator)?.appendChapter() } label: { Image(systemName: "plus") }
                .buttonStyle(.borderless).help("Add a chapter at the end").accessibilityLabel("Add Chapter")
        }
    }
}

private struct ChapterRow: View {
    let chapter: BookOutline.Chapter
    let current: Bool
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Text("\(chapter.id + 1)").monospacedDigit().foregroundStyle(.tertiary).frame(minWidth: 14, alignment: .trailing)
                Text(chapter.title).lineLimit(1).fontWeight(current ? .semibold : .regular)
                Spacer(minLength: 4)
                if let first = chapter.first {
                    Text(first == chapter.last || chapter.last == nil ? first : "\(first)–\(chapter.last!)")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Go to \(chapter.title)")
        .accessibilityLabel("Chapter \(chapter.id + 1), \(chapter.title)\(chapter.first.map { ", page \($0)" } ?? "")")
        .accessibilityAddTraits(current ? .isSelected : [])
    }
}

/// The front and back matter pages, each on or off; one that needs words
/// from the metadata says so.
private struct MatterToggles: View {
    @Bindable var model: WorkspaceModel
    let meta: BookMetadata

    var body: some View {
        ForEach(MatterPage.allCases) { kind in
            let missing = !kind.hasContent(meta, chapters: max(2, model.bookOutline.chapters.count)) && kind != .contents
            Toggle(isOn: Binding(get: { model.bookDesign.matter.contains(kind) },
                                 set: { on in
                                     model.updateBookDesign { if on { $0.matter.insert(kind) } else { $0.matter.remove(kind) } }
                                 })) {
                HStack(spacing: 4) {
                    Text(kind.title)
                    if missing { Text("— add text").foregroundStyle(.tertiary) }
                }
            }
            .toggleStyle(.checkbox)
            .help(missing ? "\(kind.title) is printed once you write it in Edit front & back matter" : kind.isBack ? "After the last chapter" : "Before the first chapter")
        }
    }
}

/// Words written against the book's goal.
struct WordGoal: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        let words = model.local?.statistics.words ?? 0
        let goal = max(1, model.bookDesign.wordGoal)
        let fraction = min(1, Double(words) / Double(goal))
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(words.formatted()) of \(goal.formatted()) words").monospacedDigit()
                Spacer()
                Text(fraction.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.callout)
            ProgressView(value: fraction).progressViewStyle(.linear)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Inspector: the design

/// The inspector's Book tab: the book's design in four groups, each opened
/// or closed as the writer left it.
struct BookDesignPane: View {
    @Bindable var model: WorkspaceModel
    @AppStorage("bookDesignType") private var type = true
    @AppStorage("bookDesignPage") private var page = false
    @AppStorage("bookDesignChapters") private var chapters = false
    @AppStorage("bookDesignMatter") private var matter = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                BookSource(model: model)
                group("Type", $type) { TypePane(model: model) }
                group("Page", $page) { PagePane(model: model) }
                group("Chapters", $chapters) { ChaptersPane(model: model) }
                group("Front & back matter", $matter) { BookPane(model: model) }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func group<Content: View>(_ title: String, _ open: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) -> some View {
        DisclosureGroup(isExpanded: open) {
            VStack(alignment: .leading, spacing: 14, content: content).padding(.top, 10)
        } label: {
            SectionLabel(title)
        }
    }
}

/// A binding into the stored book design.
@MainActor private func design<T>(_ model: WorkspaceModel, _ path: WritableKeyPath<BookDesign, T>) -> Binding<T> {
    Binding(get: { model.bookDesign[keyPath: path] }, set: { value in model.updateBookDesign { $0[keyPath: path] = value } })
}

private struct Field<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content
    init(_ label: String, @ViewBuilder content: @escaping () -> Content) { self.label = label; self.content = content }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.callout).foregroundStyle(.secondary)
            content()
        }
    }
}

private struct SliderField: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String

    var body: some View {
        Field(label) {
            HStack(spacing: 10) {
                Slider(value: $value, in: range, step: step).labelsHidden()
                Text(format(value)).monospacedDigit().font(.callout).frame(width: 52, alignment: .trailing)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct TypePane: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        let d = model.bookDesign
        let face = d.typeface ?? model.prefs.font
        Field("Font") {
            Picker("Font", selection: design(model, \.typeface)) {
                Text("Editor font — \(model.prefs.font.title)").tag(EditorFont?.none)
                Divider()
                ForEach(EditorFont.allCases.filter { $0 != .mono && $0 != .system }) { font in
                    Text("\(font.title) — \(font.character)").tag(EditorFont?.some(font))
                }
            }
            .labelsHidden()
        }
        Text("The quick brown fox jumps over the lazy dog, fi fl ffi.")
            .font(Font(face.font(size: 15)))
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: model.prefs.theme.background), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
            .accessibilityLabel("Sample of \(face.title)")
        Field("Preset") {
            Picker("Preset", selection: design(model, \.largePrint)) {
                Text("Standard").tag(false)
                Text("Large print").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden()
        }
        SliderField(label: "Size", value: design(model, \.typeSize), range: 9...16, step: 0.1) { String(format: "%.1f pt", $0) }
        SliderField(label: "Line spacing", value: design(model, \.lineSpacing), range: 1.1...2, step: 0.01) { String(format: "%.2f", $0) }
        Field("Paragraphs") {
            Picker("Paragraphs", selection: design(model, \.paragraphs)) {
                ForEach(BookParagraphs.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
        }
        SliderField(label: "Indent", value: design(model, \.indent), range: 0.5...3, step: 0.1) { String(format: "%.1f em", $0) }
            .disabled(d.paragraphs == .spaced)
        Toggle("Justify text", isOn: design(model, \.justify)).toggleStyle(.checkbox)
        Toggle("Hyphenate", isOn: design(model, \.hyphenate)).toggleStyle(.checkbox)
    }
}

private struct PagePane: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        let trim = model.bookDesign.trim
        let inches = trim.inches
        Field("Trim size") {
            Picker("Trim size", selection: design(model, \.trim)) {
                ForEach(BookTrim.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
        }
        Toggle("Facing pages when there's room", isOn: design(model, \.facingPages)).toggleStyle(.checkbox)
            .help("Show verso and recto side by side, as an open book, when the window is wide enough")
        Field("Running heads") {
            Picker("Running heads", selection: design(model, \.runningHeads)) {
                ForEach(RunningHeads.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
        }
        Field("Page numbers") {
            Picker("Page numbers", selection: design(model, \.folios)) {
                ForEach(FolioPosition.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
        }
        Divider()
        Field("Margins") {
            let f = { (v: Double) in v.formatted(.number.precision(.fractionLength(0...2))) + "″" }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow { Text("Inner"); Text(f(inches.width / 9)).monospacedDigit(); Text("Top"); Text(f(inches.height / 9)).monospacedDigit() }
                GridRow { Text("Outer"); Text(f(inches.width * 2 / 9)).monospacedDigit(); Text("Bottom"); Text(f(inches.height * 2 / 9)).monospacedDigit() }
            }
            .font(.callout)
            Text("After the Van de Graaf canon: the text block is two-thirds of the page, margins in the ratio 2 : 3 : 4 : 6.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ChaptersPane: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        Field("Chapter heading") {
            Picker("Chapter heading", selection: design(model, \.headings)) {
                ForEach(ChapterHeadingStyle.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
        }
        Field("Scene break") {
            Picker("Scene break", selection: design(model, \.sceneBreak)) {
                ForEach(SceneBreak.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
        }
        Field("Chapters start on") {
            Picker("Chapters start on", selection: design(model, \.openers)) {
                ForEach(ChapterOpener.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
        }
        Toggle("Drop caps", isOn: design(model, \.dropCaps)).toggleStyle(.checkbox)
        Toggle("Small caps after headings", isOn: design(model, \.smallCapsOpening)).toggleStyle(.checkbox)
        Text("Applied to every chapter at once. Each # heading starts a chapter; a line of *** or --- between paragraphs is a scene break.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

private struct BookPane: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        let meta = BookMetadata.read(model.editor?.currentSnapshot.text ?? "")
        Field("Pages") {
            MatterToggles(model: model, meta: meta)
            Button("Edit front & back matter…") { model.showBookDetails = true }
        }
        Divider()
        Field("Word goal") {
            TextField("Word goal", value: design(model, \.wordGoal), format: .number)
                .textFieldStyle(.roundedBorder).labelsHidden().frame(maxWidth: 140)
        }
        WordGoal(model: model)
        Divider()
        HStack {
            Text("\(model.bookOutline.pages) printed pages").monospacedDigit().foregroundStyle(.secondary)
            Spacer()
            Button("Whole Book…") { model.showBookOverview = true }
        }
        .font(.callout)
    }
}

/// Where the design is kept: in this document, or Terso's defaults until
/// it is set up as a book.
private struct BookSource: View {
    let model: WorkspaceModel

    var body: some View {
        if model.documentBook != nil {
            Label("Saved in this document's metadata, under book:", systemImage: "doc.text")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Using Terso's default design. Changes here apply to every document not set up as a book.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Set Up as Book") { model.setUpAsBook() }
                    .help("Write this design into the document's metadata, so the file keeps it")
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// Offered once on entering Manutius with a document that has no book
/// design of its own: nothing is written until the writer says so.
struct BookSetupBanner: View {
    let model: WorkspaceModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "book.closed").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Set this document up as a book?").font(.callout.weight(.medium))
                Text("Its trim, type and chapters are saved in the metadata at the top, under book:.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button("Not Now") { model.bookSetupDeclined = true }
            Button("Set Up as Book") { model.setUpAsBook() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .frame(maxWidth: 620)
        .padding(.top, 12).padding(.horizontal, 20)
    }
}

// MARK: - Front & back matter

/// The book's particulars, written into the document's metadata.
struct BookDetailsSheet: View {
    let model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var meta = BookMetadata()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Front & Back Matter").font(.headline)
            Text("Saved in the document's metadata, so they travel with the text.")
                .font(.callout).foregroundStyle(.secondary)
            Form {
                TextField("Title", text: text(\.title))
                TextField("Subtitle", text: text(\.subtitle))
                TextField("Author", text: text(\.author))
                TextField("Dedication", text: text(\.dedication), prompt: Text("For…"))
                TextField("Copyright", text: text(\.copyright), prompt: Text("Copyright © \(String(Calendar.current.component(.year, from: Date())))\(meta.author.map { " " + $0 } ?? "")"))
                TextField("About the author", text: text(\.about), axis: .vertical).lineLimit(3...6)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save(); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 460)
        .onAppear { meta = BookMetadata.read(model.editor?.currentSnapshot.text ?? "") }
    }

    private func text(_ path: WritableKeyPath<BookMetadata, String?>) -> Binding<String> {
        Binding(get: { meta[keyPath: path] ?? "" }, set: { meta[keyPath: path] = $0.isEmpty ? nil : $0 })
    }

    private func save() {
        guard let editor = model.editor, let edit = meta.edit(of: editor.currentSnapshot.text) else { return }
        editor.replace(TextSpan(edit.range), with: edit.replacement, actionName: "Edit Front & Back Matter")
    }
}

// MARK: - Status

/// One quiet line under the pages: where the caret is in the book, and how
/// big the book has become.
struct BookStatusBar: View {
    let model: WorkspaceModel

    var body: some View {
        let outline = model.bookOutline
        let d = model.bookDesign
        HStack(spacing: 6) {
            if let current = outline.current, let chapter = outline.chapters[safe: current] {
                Text("Chapter \(current + 1) of \(outline.chapters.count)")
                if let first = chapter.first {
                    Text("·"); Text(first == chapter.last ? "page \(first)" : "pages \(first)–\(chapter.last ?? first)")
                }
                Text("·")
            } else if let page = outline.page {
                Text("Page \(page)"); Text("·")
            }
            Text("\(outline.pages) printed pages")
            if let words = model.local?.statistics.words { Text("·"); Text("\(words.formatted()) words") }
            Spacer()
            Text("\(d.trim.title) · \(String(format: "%.1f", d.typeSize)) pt")
        }
        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 14).frame(height: 24)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
