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
        let meta = "---\ntitle: \"On Printing\"\nauthor: Aldus Manutius\ndedication: \"For the readers of small books\"\nabout: \"Aldus Manutius printed in Venice from 1494, and gave the world italic type and the pocket book.\"\n---\n\n"
        for (name, manutius, design, width) in [("mixed", false, BookDesign(), 1000.0), ("manutius", true, BookDesign(), 1000), ("manutius-rules", true, rules, 1000), ("manutius-spread", true, BookDesign(), 1700)] {
            let text = manutius ? meta + String(repeating: sample + "\n\n", count: 3) : sample
            let (tv, layout, container, close) = editor(text: text, manutius: manutius, mixed: Set(MixedElement.allCases), design: design, width: width)
            defer { close() }
            tv.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            layout.ensureLayout(for: container)
            let bounds = NSRect(x: 0, y: 0, width: tv.bounds.width, height: min(tv.bounds.height, manutius ? 5 * (tv.book?.stride ?? 425) : 1100))
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
        // The first chapter opens the text, after the front matter; each
        // later one a fresh recto.
        #expect(pages.first == book.front + (book.isRecto(book.front) ? 0 : 1) && pages == pages.sorted() && Set(pages).count == pages.count, "\(pages)")
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

    @Test func spreadsSetVersoBesideRecto() throws {
        let paragraph = "The printer set his pages with care, and the reader turned them without noticing the care at all. "
        let text = (1...30).map { "Paragraph \($0). " + String(repeating: paragraph, count: 3) }.joined(separator: "\n\n")
        var design = BookDesign()
        design.matter = []
        let (tv, layout, container, close) = editor(text: text, manutius: true, mixed: [], design: design, width: 1800)
        defer { close() }
        let book = try #require(tv.book)
        #expect(book.spread && abs(container.size.width - book.containerWidth) <= 1)
        layout.ensureLayout(for: container)
        var pages: [Int] = []
        layout.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layout.numberOfGlyphs)) { rect, _, _, _, _ in
            let page = book.page(at: rect.origin)
            let block = book.textBlock(page)
            #expect(rect.minY >= block.minY - 0.5 && rect.maxY <= block.maxY + 0.5)
            #expect(rect.minX >= block.minX - 0.5 && rect.maxX <= block.maxX + 0.5)
            pages.append(page)
        }
        // Page after page, each filled before the next, two to a row.
        #expect(pages == pages.sorted() && pages.first == 0 && (pages.last ?? 0) > 4)
        #expect(Set(pages) == Set(0...(pages.last ?? 0)))
        #expect(abs(book.rect(1).maxX + BookPage.spine - book.rect(2).minX) < 0.01 && book.rect(1).minY == book.rect(2).minY)
        #expect(tv.frame.height >= CGFloat(book.rows(pages.last! + 1)) * book.stride)
        // Too narrow for two pages: one page at a time again.
        tv.setFrameSize(NSSize(width: 900, height: tv.frame.height))
        #expect(tv.book?.spread == false)
    }

    @Test func frontMatterFromMetadata() {
        let text = "---\ntitle: \"The Keeper's Daughter\"\nauthor: Alex Rubin\n---\n\n# One\n\nText.\n\n# Two\n\nMore.\n"
        var meta = BookMetadata.read(text)
        #expect(meta.title == "The Keeper's Daughter" && meta.author == "Alex Rubin" && meta.dedication == nil)
        let all = Set(MatterPage.allCases)
        let layout = MatterPage.layout(all, meta: meta, chapters: 2)
        // Display pages open on rectos: a blank backs the half title, and
        // another the contents, so the text's page 1 is a recto.
        #expect(layout.front == [.halfTitle, nil, .titlePage, .copyright, .contents, nil] && layout.back.isEmpty)
        meta.dedication = "For \"M\""
        meta.author = nil
        let edit = meta.edit(of: text)!
        let edited = (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
        #expect(edited.hasPrefix("---\ntitle: \"The Keeper's Daughter\"\ndedication: \"For \\\"M\\\"\"\n---\n\n# One"))
        #expect(BookMetadata.read(edited).dedication == "For \"M\"")
        // Without metadata, a block is added at the top.
        let plain = BookMetadata(title: "T").edit(of: "Body.\n")!
        #expect(plain.range.location == 0 && plain.replacement == "---\ntitle: \"T\"\n---\n\n")
        #expect(BookPage.roman(14) == "xiv")
    }

    @Test func bookDesignLivesInTheMetadata() throws {
        let text = "---\ntitle: \"On Type\"\nbook:\n  trim: 5.5x8.5\n  typeface: baskerville\n  size: 12.5\n  chapters-start: new-page\n  matter: [title-page, contents]\n  word-goal: 60_000\n  unknown: kept\nauthor: A. Printer\n---\n\n# One\n"
        var defaults = BookDesign()
        defaults.headings = .rules
        let d = try #require(BookDesign.read(from: text, defaults: defaults))
        #expect(d.trim == .digest && d.typeface == .baskerville && d.typeSize == 12.5 && d.openers == .newPage)
        #expect(d.matter == [.titlePage, .contents] && d.wordGoal == 60_000)
        // Keys left out take the defaults; the metadata's own keys are untouched.
        #expect(d.headings == .rules && BookMetadata.read(text).author == "A. Printer")
        #expect(BookDesign.read(from: "# One\n", defaults: defaults) == nil)

        // Written back, the block replaces the old one in place and reads the same.
        var changed = d
        changed.sceneBreak = .fleuron
        changed.typeface = nil
        let edit = try #require(changed.edit(of: text))
        let written = (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
        #expect(written.contains("  scene-break: fleuron\n") && written.contains("  typeface: editor\n") && written.contains("  unknown: kept\n"))
        #expect(written.contains("author: A. Printer\n---\n\n# One"))
        #expect(BookDesign.read(from: written, defaults: defaults) == changed)

        // A document without metadata gains a block at the top.
        let plain = try #require(BookDesign().edit(of: "# One\n"))
        #expect(plain.range == NSRange(location: 0, length: 0) && plain.replacement.hasPrefix("---\nbook:\n  trim: 6x9\n"))
        #expect(BookDesign.read(from: plain.replacement + "# One\n", defaults: defaults) == BookDesign())
    }

    @Test func settingUpAsABookIsOneUndoableEdit() throws {
        let text = "Body text.\n"
        let title = BookMetadata(title: "Draft").edit(of: text)
        let titled = (text as NSString).replacingCharacters(in: title!.range, with: title!.replacement)
        let edit = try #require(BookBlock.combine(text, [title, BookDesign().edit(of: titled)]))
        let result = (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
        #expect(edit.range.location == 0 && result.hasSuffix("---\n\nBody text.\n"))
        #expect(BookMetadata.read(result).title == "Draft" && BookDesign.read(from: result, defaults: BookDesign()) == BookDesign())
    }

    private func editor(text: String, manutius: Bool, mixed: Set<MixedElement>, design: BookDesign? = nil, mode: RenderMode = .mixed, width: CGFloat = 1000)
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
        let tv = TersoTextView(frame: NSRect(x: 0, y: 0, width: width, height: 800), textContainer: container)
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
