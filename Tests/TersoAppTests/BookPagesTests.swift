// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import TersoApp

@Suite @MainActor struct BookPagesTests {
    @Test func canonProportionsAndPlacement() {
        let book = BookPage(column: 480)
        #expect(book.width == 720 && book.height == 1080)
        #expect(book.inner * 2 == book.outer && book.top * 2 == book.bottom)
        #expect(book.place(0, height: 20) == book.top)
        let end = book.height - book.bottom
        #expect(book.place(end - 10, height: 20) == book.stride + book.top)
        #expect(book.place(end - 30, height: 20) == end - 30)
        // A block taller than the page starts a page and runs over.
        #expect(book.place(book.top, height: book.textHeight * 2) == book.top)
        #expect(book.rect(0).minX == -book.inner && book.rect(1).minX == -book.outer)
        #expect(BookPage.measure(fontSize: 17, columnWidth: 720) == 476)
    }

    @Test func manutiusFlowsEveryLineInsideItsPage() throws {
        let paragraph = "The printer set his pages with care, and the reader turned them without noticing the care at all. "
        let text = (1...40).map { "Paragraph \($0). " + String(repeating: paragraph, count: 3) }.joined(separator: "\n\n")
        let (tv, layout, container, close) = editor(text: text, manutius: true, mixed: [])
        defer { close() }
        let book = try #require(tv.book)
        layout.ensureLayout(for: container)
        var pages = Set<Int>()
        layout.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layout.numberOfGlyphs)) { rect, _, _, _, _ in
            let page = Int((rect.minY / book.stride).rounded(.down))
            let top = CGFloat(page) * book.stride + book.top
            #expect(rect.minY >= top - 0.5)
            #expect(rect.maxY <= top + book.textHeight + 0.5)
            pages.insert(page)
        }
        #expect(pages.count > 3)
        #expect(tv.frame.height >= CGFloat(pages.count) * book.stride)
        let style = tv.textStorage?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        #expect(style?.alignment == .justified && (style?.hyphenationFactor ?? 0) > 0)
    }

    /// Renders Manutius and Mixed for a visual check when TERSO_SNAPSHOT_DIR is set.
    @Test func snapshotForVisualReview() throws {
        guard let dir = ProcessInfo.processInfo.environment["TERSO_SNAPSHOT_DIR"] else { return }
        let sample = """
        # On Printing {#sec:print}

        Venice, in the last years of the fifteenth century, was the busiest market for books in Europe, and Aldus came there to print the Greek classics in editions scholars could carry and afford.

        * * *

        Aldus **Manutius** set *small* books with `italic` type, as @fig:press shows [@lowry1979, p. 12].[^1] ==Portable== books changed reading. %%check date%%

        - A bullet item
        - [ ] An open task
        - [x] A finished task

        > Festina lente — make haste slowly.
        > > A nested reply.

        ---

        | Edition | Year | Format |
        |:--------|-----:|:------:|
        | *Virgil* | 1501 | octavo |
        | **Petrarch** | 1501 | `octavo` |

        ![The press](press.png){#fig:press}

        See @fig:press and @sec:print.

        [^1]: The Aldine press, Venice.
        """
        var rules = BookDesign()
        rules.headings = .rules; rules.sceneBreak = .fleuron; rules.folios = .outside; rules.trim = .fiveByEight
        for (name, manutius, design) in [("mixed", false, BookDesign()), ("manutius", true, BookDesign()), ("manutius-rules", true, rules)] {
            let text = manutius ? String(repeating: sample + "\n\n", count: 3) : sample
            let (tv, layout, container, close) = editor(text: text, manutius: manutius, mixed: Set(MixedElement.allCases), design: design)
            defer { close() }
            tv.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            layout.ensureLayout(for: container)
            let bounds = NSRect(x: 0, y: 0, width: tv.bounds.width, height: min(tv.bounds.height, manutius ? 4 * (tv.book?.stride ?? 425) : 1100))
            let rep = try #require(tv.bitmapImageRepForCachingDisplay(in: bounds))
            tv.cacheDisplay(in: bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    @Test func trimsOpenersAndChapters() {
        let digest = BookPage(column: 480, aspect: BookTrim.sevenByTen.aspect)
        #expect(digest.height == (720 * 10 / 7).rounded() && digest.top * 2 == digest.bottom)
        let book = BookPage(column: 480)
        // An empty page takes the chapter sunk; a page with text sends it on.
        #expect(book.placeOpener(0, recto: true) == book.top + book.sink)
        #expect(book.placeOpener(book.top + 200, recto: false) == book.stride + book.top + book.sink)
        #expect(book.placeOpener(book.top + 200, recto: true) == book.stride * 2 + book.top + book.sink)
        #expect(book.placeOpener(book.stride * 2 + book.top + book.sink, recto: true) == book.stride * 2 + book.top + book.sink)
        let text = "---\ntitle: \"On Type\"\n---\n\n# One {#sec:one}\n\nIt was a *quiet* press, and slow.\n\n# Two\n\n- a list first\n\n```\n# not a chapter\n```\n"
        let chapters = BookChapter.scan(text)
        let ns = text as NSString
        #expect(chapters.map(\.title) == ["One", "Two"])
        #expect(chapters[0].initial(in: ns).map(ns.substring(with:)) == "I")
        #expect(chapters[0].openingWords(in: ns).map(ns.substring(with:)) == "It was a")
        #expect(chapters[1].opening == nil)
    }

    @Test(arguments: [RenderMode.source, .mixed])
    func chaptersOpenOnRectosBesideTheirDropCaps(mode: RenderMode) throws {
        let paragraph = "The printer set his pages with care, and the reader turned them without noticing the care at all. "
        let chapter = { (n: Int) in "# Chapter \(n)\n\nOnce " + String(repeating: paragraph, count: 9) + "\n\n" + String(repeating: paragraph, count: 6) }
        let text = (1...4).map(chapter).joined(separator: "\n\n")
        var design = BookDesign()
        design.openers = .rightPage
        design.dropCaps = true
        let (tv, layout, container, close) = editor(text: text, manutius: true, mixed: Set(MixedElement.allCases), design: design, mode: mode)
        defer { close() }
        let book = try #require(tv.book)
        layout.ensureLayout(for: container)
        let ns = text as NSString
        let headings = BookChapter.scan(text).map(\.titleStart)
        #expect(headings.count == 4)
        var pages: [Int] = []
        for heading in headings {
            let rect = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: heading), effectiveRange: nil)
            let page = book.page(at: rect.minY)
            pages.append(page)
            #expect(book.isRecto(page))
            #expect(abs(rect.minY - (CGFloat(page) * book.stride + book.top + book.sink)) < 1)
        }
        // The first chapter opens the book; each later one a fresh recto.
        #expect(pages.first == 0 && pages == pages.sorted() && Set(pages).count == pages.count, "\(pages)")
        // Source shows the letter as written; elsewhere the opening's first
        // lines stand aside for the cap, and later ones don't.
        guard mode != .source else { return }
        let opening = try #require(BookChapter.scan(text).first?.opening)
        var lines: [NSRect] = []
        layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(forCharacterRange: opening, actualCharacterRange: nil)) { rect, _, _, _, _ in
            lines.append(rect)
        }
        #expect(lines.count > DropCap.lines + 1)
        #expect(lines.prefix(DropCap.lines).allSatisfy { $0.minX > 0 })
        #expect(lines.dropFirst(DropCap.lines).allSatisfy { $0.minX == 0 })
        let hidden = tv.textStorage?.attribute(.foregroundColor, at: opening.location, effectiveRange: nil) as? NSColor
        #expect(hidden == .clear)
        _ = ns
        // The whole-book view counts every page and draws each small.
        let coordinator = try #require(tv.delegate as? EditorCoordinator)
        let count = coordinator.bookPageCount()
        #expect(count == (pages.last ?? 0) + 2 || count == (pages.last ?? 0) + 1)
        let thumb = try #require(coordinator.bookPageImage(count - 1, width: 120))
        #expect(thumb.size.width == 120 && abs(thumb.size.height - 120 * book.height / book.width) < 1)
    }

    private func editor(text: String, manutius: Bool, mixed: Set<MixedElement>, design: BookDesign? = nil, mode: RenderMode = .mixed)
        -> (TersoTextView, MathLayoutManager, NSTextContainer, () -> Void) {
        let model = WorkspaceModel()
        model.manutius = manutius
        let coordinator = EditorCoordinator(model: model, text: .constant(text))
        let storage = NSTextStorage(string: text)
        let layout = MathLayoutManager(); storage.addLayoutManager(layout)
        let container = PagedTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        let tv = TersoTextView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800), textContainer: container)
        tv.isVerticallyResizable = true
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let window = NSWindow(contentRect: tv.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = tv
        coordinator.textView = tv; model.editor = coordinator; tv.delegate = coordinator; storage.delegate = coordinator
        var config = EditorConfig(prefs: model.prefs, model: model)
        config.renderMode = mode
        config.mixedRendered = mixed
        if manutius { config.book = design ?? BookDesign() }
        coordinator.applyConfig(config, force: true)
        tv.sizeToFit()
        return (tv, layout, container, { window.close(); _ = coordinator })
    }
}
