// SPDX-License-Identifier: AGPL-3.0-only
import AppKit

/// A book page for Manutius, in text-container coordinates. Proportions follow
/// the Van de Graaf canon: a 2:3 page whose text block is two-thirds of its
/// width, with inner, top, outer and bottom margins in the ratio 2:3:4:6.
struct BookPage: Equatable {
    /// The width of the text block: a book measure, not the editor column.
    let column: CGFloat
    var width: CGFloat { column * 1.5 }
    var height: CGFloat { width * 1.5 }
    var inner: CGFloat { width / 9 }
    var outer: CGFloat { width * 2 / 9 }
    var top: CGFloat { height / 9 }
    var bottom: CGFloat { height * 2 / 9 }
    var textHeight: CGFloat { height - top - bottom }
    static let gap: CGFloat = 36
    var stride: CGFloat { height + Self.gap }

    /// About 28 ems: a measure of roughly 66 characters, as books set them.
    static func measure(fontSize: Double, columnWidth: Double) -> CGFloat {
        CGFloat(min(columnWidth, (fontSize * 28).rounded()))
    }

    /// Where a line proposed at `y` goes: never into a top margin, and onto the
    /// next page when it would cross into the bottom one. A line taller than
    /// the text block starts a page and is allowed to run over.
    func place(_ y: CGFloat, height lineHeight: CGFloat) -> CGFloat {
        let page = max(0, (y / stride).rounded(.down))
        let start = page * stride + top
        let end = page * stride + height - bottom
        if y < start { return start }
        if y + lineHeight > end && y > start { return (page + 1) * stride + top }
        return y
    }

    /// Pages needed for text that ends at `y`.
    func pages(through y: CGFloat) -> Int { max(1, Int((y / stride).rounded(.down)) + 1) }

    /// Odd pages are rectos, with the binding (inner margin) on the left.
    func isRecto(_ index: Int) -> Bool { index % 2 == 0 }

    /// The page's rectangle relative to the text block's origin.
    func rect(_ index: Int) -> NSRect {
        NSRect(x: -(isRecto(index) ? inner : outer), y: CGFloat(index) * stride, width: width, height: height)
    }
}

/// A text container that flows lines from page to page when Manutius sets a
/// book page, and behaves as a plain rectangle otherwise.
final class PagedTextContainer: NSTextContainer {
    var book: BookPage? {
        didSet { if book != oldValue { layoutManager?.textContainerChangedGeometry(self) } }
    }

    override var isSimpleRectangularTextContainer: Bool { book == nil && super.isSimpleRectangularTextContainer }

    override func lineFragmentRect(forProposedRect proposedRect: NSRect, at characterIndex: Int,
                                   writingDirection baseWritingDirection: NSWritingDirection,
                                   remaining remainingRect: UnsafeMutablePointer<NSRect>?) -> NSRect {
        var rect = proposedRect
        if let book { rect.origin.y = book.place(rect.minY, height: rect.height) }
        return super.lineFragmentRect(forProposedRect: rect, at: characterIndex,
                                      writingDirection: baseWritingDirection, remaining: remainingRect)
    }
}

extension TersoTextView {
    /// Paper on a desk: each page with a soft shadow, its running head in
    /// small capitals and its folio in old-style figures.
    func drawBookPages(_ book: BookPage, in dirty: NSRect, runningHead: String?, font: NSFont) {
        let paper = backgroundColor
        paper.blended(withFraction: 0.07, of: .labelColor)?.setFill()
        dirty.fill()
        let origin = textContainerOrigin
        let first = max(0, Int(((dirty.minY - origin.y) / book.stride).rounded(.down)))
        let last = Int(((dirty.maxY - origin.y) / book.stride).rounded(.down))
        guard first <= last else { return }
        let folioFont = Self.oldStyle(font.withSize(font.pointSize * 0.78))
        let headFont = Self.smallCaps(font.withSize(font.pointSize * 0.78))
        let ink = NSColor.tertiaryLabelColor
        for index in first...last {
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
            let block = NSRect(x: origin.x, y: page.minY + book.top, width: book.column, height: book.textHeight)
            let folio = NSAttributedString(string: "\(index + 1)", attributes: [.font: folioFont, .foregroundColor: ink])
            let folioSize = folio.size()
            folio.draw(at: NSPoint(x: block.midX - folioSize.width / 2, y: block.maxY + book.bottom * 0.35))
            // Books carry no running head over their first page.
            if index > 0, let runningHead, !runningHead.isEmpty {
                let head = NSAttributedString(string: runningHead.lowercased(), attributes: [.font: headFont, .foregroundColor: ink, .kern: 0.6])
                let headSize = head.size()
                head.draw(at: NSPoint(x: block.midX - headSize.width / 2, y: page.minY + book.top * 0.45))
            }
        }
    }

    private static func oldStyle(_ font: NSFont) -> NSFont {
        featured(font, [[.typeIdentifier: kNumberCaseType, .selectorIdentifier: kLowerCaseNumbersSelector]])
    }

    private static func smallCaps(_ font: NSFont) -> NSFont {
        featured(font, [[.typeIdentifier: kLowerCaseType, .selectorIdentifier: kLowerCaseSmallCapsSelector]])
    }

    private static func featured(_ font: NSFont, _ settings: [[NSFontDescriptor.FeatureKey: Int]]) -> NSFont {
        NSFont(descriptor: font.fontDescriptor.addingAttributes([.featureSettings: settings]), size: font.pointSize) ?? font
    }
}
