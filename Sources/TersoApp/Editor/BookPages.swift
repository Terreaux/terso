// SPDX-License-Identifier: AGPL-3.0-only
import AppKit

/// A book page for Manutius, in text-container coordinates. Proportions follow
/// the Van de Graaf canon: a text block two-thirds of the page's width and
/// height, with inner, top, outer and bottom margins in the ratio 2:3:4:6 on
/// the 2:3 page; other trims keep the same ninths of width and height.
///
/// Lines are typeset down a stack of pages, one per `stride`. Laid out as
/// spreads, that stack is folded into rows: the first page alone on the
/// right, as a book opens, then each verso beside its recto.
struct BookPage: Equatable {
    /// The width of the text block: a book measure, not the editor column.
    let column: CGFloat
    /// Height over width: 1.5 for the canon's 2:3 page.
    var aspect: CGFloat = 1.5
    /// Facing pages side by side, when the view has room for two.
    var spread = false
    /// Pages drawn before the text (half title, title page…) and after it.
    var front = 0
    var back = 0
    var width: CGFloat { column * 1.5 }
    var height: CGFloat { (width * aspect).rounded() }
    var inner: CGFloat { width / 9 }
    var outer: CGFloat { width * 2 / 9 }
    var top: CGFloat { height / 9 }
    var bottom: CGFloat { height * 2 / 9 }
    var textHeight: CGFloat { height - top - bottom }
    static let gap: CGFloat = 36
    /// Between facing pages: the gutter's fold.
    static let spine: CGFloat = 2
    var stride: CGFloat { height + Self.gap }
    /// A chapter on a new page starts a quarter of the way down its text block.
    var sink: CGFloat { (textHeight / 4).rounded() }

    /// About 28 ems: a measure of roughly 66 characters, as books set them.
    static func measure(fontSize: Double, columnWidth: Double) -> CGFloat {
        CGFloat(min(columnWidth, (fontSize * 28).rounded()))
    }

    /// A trim at the editor's scale: 6 inches across is the canon's page at
    /// a 28-em measure, and other trims are wider or narrower in proportion,
    /// so a bigger book holds more words to the line.
    init(trim: BookTrim, fontSize: Double) {
        column = (CGFloat(fontSize) * 28 * trim.inches.width / 6).rounded()
        aspect = trim.aspect
    }

    init(column: CGFloat, aspect: CGFloat = 1.5) {
        self.column = column
        self.aspect = aspect
    }

    // MARK: Spreads

    /// From the verso's text block to the recto's: across the inner margins
    /// and the fold.
    var spreadShift: CGFloat { column + inner * 2 + Self.spine }
    /// The text container: one text block, or two side by side.
    var containerWidth: CGFloat { spread ? spreadShift + column : column }
    /// Paper the view needs across: one page, or a spread.
    var viewWidth: CGFloat { spread ? width * 2 + Self.spine : width }
    /// The row a page is drawn in: its own, or its spread's.
    func row(_ index: Int) -> Int { spread ? (index + 1) / 2 : index }
    /// Rows needed to show `count` pages.
    func rows(_ count: Int) -> Int { count > 0 ? row(count - 1) + 1 : 1 }
    /// How far right a page's text block sits: a recto in a spread moves over.
    func shift(_ index: Int) -> CGFloat { spread && isRecto(index) ? spreadShift : 0 }
    /// Lines are typeset down the stack of pages; this moves a page's lines
    /// up into its row.
    func lift(_ index: Int) -> CGFloat { CGFloat(index - row(index)) * stride }

    // MARK: Placing lines

    /// Where a line proposed at `y` goes: never into a top margin, and onto the
    /// next page when it would cross into the bottom one. A line taller than
    /// the text block starts a page and is allowed to run over. The text
    /// starts after the front matter.
    func place(_ y: CGFloat, height lineHeight: CGFloat) -> CGFloat {
        let page = max(CGFloat(front), (y / stride).rounded(.down))
        let start = page * stride + top
        let end = page * stride + height - bottom
        if y < start { return start }
        if y + lineHeight > end && y > start { return (page + 1) * stride + top }
        return y
    }

    /// Where a chapter heading goes when chapters open a page: sunk on the
    /// page it would start, if nothing is set there yet, or else on the next
    /// one — the next recto when `recto` is asked for.
    func placeOpener(_ y: CGFloat, recto: Bool) -> CGFloat {
        let page = max(front, Int((y / stride).rounded(.down)))
        // The typesetter may propose a line again where it was put: it stays.
        let sunk = CGFloat(page) * stride + top + sink
        if abs(y - sunk) < 0.5, !recto || isRecto(page) { return sunk }
        // Blank lines close up to a couple of points, so a page that holds
        // only those is still empty.
        var target = y <= CGFloat(page) * stride + top + 8 ? page : page + 1
        if recto && !isRecto(target) { target += 1 }
        return CGFloat(target) * stride + top + sink
    }

    /// The page a point in the typeset stack falls on.
    func page(at y: CGFloat) -> Int { max(0, Int((y / stride).rounded(.down))) }

    /// The page a laid-out point falls on: in a spread, its row and side.
    func page(at point: NSPoint) -> Int {
        let row = max(0, Int((point.y / stride).rounded(.down)))
        guard spread else { return row }
        if row == 0 { return 0 }
        return point.x >= spreadShift - inner - Self.spine / 2 ? row * 2 : row * 2 - 1
    }

    /// Pages needed for text that ends at `y` in the typeset stack.
    func pages(through y: CGFloat) -> Int { max(1, Int((y / stride).rounded(.down)) + 1) }

    /// Odd pages are rectos, with the binding (inner margin) on the left.
    func isRecto(_ index: Int) -> Bool { index % 2 == 0 }

    /// The page's rectangle relative to the text block's origin.
    func rect(_ index: Int) -> NSRect {
        NSRect(x: shift(index) - (isRecto(index) ? inner : outer), y: CGFloat(row(index)) * stride, width: width, height: height)
    }

    /// The page's text block relative to the text block's origin.
    func textBlock(_ index: Int) -> NSRect {
        NSRect(x: shift(index), y: CGFloat(row(index)) * stride + top, width: column, height: textHeight)
    }

    /// The number printed on a page: the text's pages count from 1, and the
    /// front matter, which carries none, from i.
    func folio(_ index: Int) -> String {
        index < front ? Self.roman(index + 1) : "\(index - front + 1)"
    }

    static func roman(_ n: Int) -> String {
        let table: [(Int, String)] = [(1000, "m"), (900, "cm"), (500, "d"), (400, "cd"), (100, "c"), (90, "xc"),
                                      (50, "l"), (40, "xl"), (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i")]
        var n = n, out = ""
        for (value, letters) in table { while n >= value { out += letters; n -= value } }
        return out
    }
}

/// Lines a drop cap stands beside: those of its chapter that start within
/// its depth below the opening's first line.
struct DropCapSpan: Equatable {
    var opening: Int
    var end: Int
    var indent: CGFloat
    var depth: CGFloat
}

/// A text container that flows lines from page to page when Manutius sets a
/// book page, and behaves as a plain rectangle otherwise.
///
/// In a spread the typesetter's proposals no longer say which page they are
/// on — a verso's line and its recto's share a height — so the container
/// remembers the page each line went to, and reads a proposal as following
/// the line laid just before it.
final class PagedTextContainer: NSTextContainer {
    var book: BookPage? {
        didSet {
            guard book != oldValue else { return }
            linePages.removeAll()
            layoutManager?.textContainerChangedGeometry(self)
        }
    }
    /// Where chapter headings' lines may start — at the `#`, or at the title
    /// when Mixed hides the marker — and whether they open a page.
    var openers: Set<Int> = []
    var opener: ChapterOpener = .continuous {
        didSet { if opener != oldValue { layoutManager?.textContainerChangedGeometry(self) } }
    }
    var dropCaps: [DropCapSpan] = []
    /// The top of each drop cap's first line and its page, as last laid out.
    private var capTops: [Int: (y: CGFloat, page: Int)] = [:]
    /// The page each line was put on, by the index it starts at, in order.
    /// Layout runs forward from wherever it was invalidated, so a line asked
    /// for again drops what was recorded from it on.
    private var linePages: [(index: Int, page: Int)] = []

    override var isSimpleRectangularTextContainer: Bool { book == nil && super.isSimpleRectangularTextContainer }

    override func lineFragmentRect(forProposedRect proposedRect: NSRect, at characterIndex: Int,
                                   writingDirection baseWritingDirection: NSWritingDirection,
                                   remaining remainingRect: UnsafeMutablePointer<NSRect>?) -> NSRect {
        var rect = proposedRect
        guard let book else {
            return super.lineFragmentRect(forProposedRect: rect, at: characterIndex,
                                          writingDirection: baseWritingDirection, remaining: remainingRect)
        }
        // Back into the typeset stack, below the page the last line went to.
        while let last = linePages.last, last.index >= characterIndex { linePages.removeLast() }
        if book.spread, let previous = linePages.last?.page { rect.origin.y += book.lift(previous) }
        if opener != .continuous, openers.contains(characterIndex) {
            rect.origin.y = book.placeOpener(rect.minY, recto: opener == .rightPage)
        } else {
            rect.origin.y = book.place(rect.minY, height: rect.height)
        }
        let page = book.page(at: rect.minY)
        linePages.append((characterIndex, page))
        // Out of the stack and into the page's place in its spread. The page
        // sets the measure, not the container, which may still be resizing
        // for a spread; a line with no width would be proposed forever.
        rect.origin.y -= book.lift(page)
        rect.size.width = max(1, min(rect.width, book.column - rect.minX))
        rect.origin.x += book.shift(page)
        remainingRect?.pointee = .zero
        var line = rect
        // Lines are laid in order, so a cap's first line is placed before
        // the lines that stand beside it.
        if let cap = dropCaps.first(where: { characterIndex >= $0.opening && characterIndex < $0.end }) {
            if characterIndex == cap.opening { capTops[cap.opening] = (line.minY, page) }
            if let top = capTops[cap.opening], top.page == page, line.minY < top.y + cap.depth, line.width > cap.indent * 2 {
                line.origin.x += cap.indent
                line.size.width -= cap.indent
            }
        }
        return line
    }
}

/// What the pages show besides the text: running heads, folios, chapter
/// ornaments and drop caps, all drawn and none of them in the file.
struct BookDecoration {
    var design = BookDesign()
    var title: String?
    var chapters: [BookChapter] = []
    var font = NSFont.systemFont(ofSize: 17)
    var ink = NSColor.labelColor
    var lineSpacing: CGFloat = 0
    /// The front matter page by page (nil for a blank), and the back matter.
    var front: [MatterPage?] = []
    var back: [MatterPage] = []
    var metadata = BookMetadata()
    /// The typeface's name, for the copyright page.
    var face = ""
}

extension TersoTextView {
    /// The last page the text reaches, once it is all laid out.
    func bookTextEnd(_ book: BookPage) -> Int? {
        guard let lm = layoutManager, lm.firstUnlaidGlyphIndex() >= lm.numberOfGlyphs else { return nil }
        var last = lm.extraLineFragmentRect
        if last.isEmpty, lm.numberOfGlyphs > 0 { last = lm.lineFragmentRect(forGlyphAt: lm.numberOfGlyphs - 1, effectiveRange: nil) }
        guard !last.isEmpty else { return book.front }
        return max(book.front, book.page(at: NSPoint(x: last.minX, y: last.minY)))
    }

    /// Every page of the book, front matter to back, once laid out.
    func bookPageTotal(_ book: BookPage) -> Int? {
        bookTextEnd(book).map { $0 + 1 + book.back }
    }

    /// Paper on a desk: each page with a soft shadow, its running head in
    /// small capitals and its folio in old-style figures. A spread shows
    /// verso and recto side by side; front and back matter are drawn whole.
    func drawBookPages(_ book: BookPage, in dirty: NSRect, decoration d: BookDecoration) {
        let paper = backgroundColor
        paper.blended(withFraction: 0.07, of: .labelColor)?.setFill()
        dirty.fill()
        let origin = textContainerOrigin
        let firstRow = max(0, Int(((dirty.minY - origin.y) / book.stride).rounded(.down)))
        let lastRow = Int(((dirty.maxY - origin.y) / book.stride).rounded(.down))
        guard firstRow <= lastRow else { return }
        let textEnd = bookTextEnd(book)
        let indices = (firstRow...lastRow).flatMap { row in
            book.spread ? (row == 0 ? [0] : [row * 2 - 1, row * 2]) : [row]
        }.filter { textEnd == nil || $0 <= textEnd! + book.back }
        guard let last = indices.last else { return }
        let folioFont = d.font.withSize(d.font.pointSize * 0.78).oldStyleFigures
        let headFont = d.font.withSize(d.font.pointSize * 0.78).smallCaps
        let ink = NSColor.tertiaryLabelColor
        // Chapter headings laid out so far, by page: the running head names
        // the chapter a page is in, and an opening page carries none.
        let placed = chapterPlacements(book, before: last)
        for index in indices {
            let page = book.rect(index).offsetBy(dx: origin.x, dy: origin.y)
            guard page.intersects(dirty) else { continue }
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
            shadow.shadowBlurRadius = 10
            shadow.shadowOffset = NSSize(width: 0, height: -2)
            shadow.set()
            paper.setFill()
            page.fill()
            NSGraphicsContext.restoreGraphicsState()
            let block = book.textBlock(index).offsetBy(dx: origin.x, dy: origin.y)
            if index < book.front {
                if let kind = d.front[safe: index] ?? nil { drawMatter(kind, in: block, book: book, decoration: d) }
                continue
            }
            if let end = textEnd, index > end {
                if let kind = d.back[safe: index - end - 1] { drawMatter(kind, in: block, book: book, decoration: d) }
                continue
            }
            let opens = placed.contains { $0.page == index }
            if d.design.folios != .off {
                let folio = NSAttributedString(string: book.folio(index), attributes: [.font: folioFont, .foregroundColor: ink])
                let size = folio.size()
                let x = d.design.folios == .centre ? block.midX - size.width / 2
                    : book.isRecto(index) ? block.maxX - size.width : block.minX
                folio.draw(at: NSPoint(x: x, y: block.maxY + book.bottom * 0.35))
            }
            // Books carry no running head over their first page or a chapter's.
            guard index > book.front, !opens, d.design.runningHeads != .off else { continue }
            let chapter = placed.last { $0.page <= index }?.title
            let text = d.design.runningHeads == .titleAndChapter && book.isRecto(index) ? chapter ?? d.title : d.title
            if let text, !text.isEmpty {
                let head = NSAttributedString(string: text.lowercased(), attributes: [.font: headFont, .foregroundColor: ink, .kern: 0.6])
                let size = head.size()
                head.draw(at: NSPoint(x: block.midX - size.width / 2, y: page.minY + book.top * 0.45))
            }
        }
    }

    /// The pages chapter headings fall on, for headings already laid out
    /// up to page `last`: drawing never forces layout further than that.
    func chapterPlacements(_ book: BookPage, before last: Int) -> [(page: Int, title: String, heading: NSRange)] {
        guard let lm = layoutManager else { return [] }
        let limit = CGFloat(last + 1) * book.stride
        let laid = lm.characterIndexForGlyph(at: lm.firstUnlaidGlyphIndex())
        var result: [(page: Int, title: String, heading: NSRange)] = []
        for chapter in bookDecoration.chapters where chapter.titleStart < laid {
            let glyph = lm.glyphIndexForCharacter(at: chapter.titleStart)
            let rect = lm.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
            guard rect.minY <= limit else { break }
            result.append((book.page(at: NSPoint(x: rect.minX, y: rect.maxY - 1)), chapter.title, chapter.heading))
        }
        return result
    }

    /// Ornaments that belong to the text and are drawn over it: the big
    /// numeral or rules of a chapter heading, and each chapter's drop cap.
    func drawBookOrnaments(_ book: BookPage, in dirty: NSRect, decoration d: BookDecoration) {
        guard let lm = layoutManager, let container = textContainer else { return }
        let origin = textContainerOrigin
        let ns = string as NSString
        let laid = lm.characterIndexForGlyph(at: lm.firstUnlaidGlyphIndex())
        for (number, chapter) in d.chapters.enumerated() where NSMaxRange(chapter.heading) <= laid && NSMaxRange(chapter.heading) <= ns.length {
            // From the title: Mixed hides the marker, which may end the line before.
            let title = NSRange(location: chapter.titleStart, length: NSMaxRange(chapter.heading) - chapter.titleStart)
            let glyphs = lm.glyphRange(forCharacterRange: title, actualCharacterRange: nil)
            var text = lm.boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: origin.x, dy: origin.y)
            guard text.minY < dirty.maxY + 400, text.maxY > dirty.minY - 400 else { continue }
            let shift = book.shift(book.page(at: NSPoint(x: text.minX - origin.x, y: text.minY - origin.y)))
            text.origin.x = origin.x + shift; text.size.width = book.column
            switch d.design.headings {
            case .bigNumeral:
                let font = d.font.withSize(d.font.pointSize * 3.4).oldStyleFigures
                let numeral = NSAttributedString(string: "\(number + 1)", attributes: [.font: font, .foregroundColor: d.ink])
                let size = numeral.size()
                numeral.draw(at: NSPoint(x: text.midX - size.width / 2, y: text.minY - size.height - d.font.pointSize * 0.4))
            case .rules:
                d.ink.withAlphaComponent(0.55).setFill()
                let width = (book.column / 3).rounded()
                let gap = d.font.pointSize * 0.7
                NSRect(x: text.midX - width / 2, y: (text.minY - gap).rounded(), width: width, height: 0.75).fill()
                NSRect(x: text.midX - width / 2, y: (text.maxY + gap).rounded(), width: width, height: 0.75).fill()
            default: break
            }
            guard d.design.dropCaps, let initial = chapter.initial(in: ns), NSMaxRange(initial) <= laid else { continue }
            let letter = ns.substring(with: initial)
            let cap = DropCap(letter: letter, body: d.font, lineSpacing: d.lineSpacing)
            let glyph = lm.glyphIndexForCharacter(at: initial.location)
            let line = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let baseline = line.minY + lm.location(forGlyphAt: glyph).y + CGFloat(DropCap.lines - 1) * cap.advance
            let drawn = NSAttributedString(string: letter, attributes: [.font: cap.font, .foregroundColor: d.ink])
            drawn.draw(at: NSPoint(x: origin.x + book.shift(book.page(at: line.origin)), y: origin.y + baseline - cap.font.ascender))
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
