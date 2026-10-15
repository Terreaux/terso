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
        for (name, manutius) in [("mixed", false), ("manutius", true)] {
            let text = manutius ? String(repeating: sample + "\n\n", count: 3) : sample
            let (tv, layout, container, close) = editor(text: text, manutius: manutius, mixed: Set(MixedElement.allCases))
            defer { close() }
            tv.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            layout.ensureLayout(for: container)
            let bounds = NSRect(x: 0, y: 0, width: tv.bounds.width, height: min(tv.bounds.height, manutius ? 1700 : 1100))
            let rep = try #require(tv.bitmapImageRepForCachingDisplay(in: bounds))
            tv.cacheDisplay(in: bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    private func editor(text: String, manutius: Bool, mixed: Set<MixedElement>)
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
        config.renderMode = .mixed
        config.mixedRendered = mixed
        coordinator.applyConfig(config, force: true)
        tv.sizeToFit()
        return (tv, layout, container, { window.close(); _ = coordinator })
    }
}
