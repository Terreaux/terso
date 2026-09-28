// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import WebKit
import TersoCore

struct RenderedMath {
    let range: NSRange
    let image: NSImage
}

/// Substitutes display glyphs, never characters. Copy, undo, analysis, saving,
/// accessibility and source navigation all continue to use the original text.
final class MathLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    var rendered: [RenderedMath] = []
    var hiddenSyntax: [NSRange] = [] {
        didSet {
            guard oldValue != hiddenSyntax, let storage = textStorage else { return }
            invalidateGlyphs(forCharacterRange: NSRange(location: 0, length: storage.length), changeInLength: 0, actualCharacterRange: nil)
        }
    }
    override init() { super.init(); delegate = self }
    required init?(coder: NSCoder) { super.init(coder: coder); delegate = self }

    func setRendered(_ items: [RenderedMath]) {
        guard rendered.map(\.range) != items.map(\.range)
                || zip(rendered, items).contains(where: { $0.image !== $1.image }) else { return }
        rendered = items
        guard let storage = textStorage else { return }
        invalidateGlyphs(forCharacterRange: NSRange(location: 0, length: storage.length), changeInLength: 0, actualCharacterRange: nil)
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>, properties props: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes indexes: UnsafePointer<Int>, font: NSFont, forGlyphRange range: NSRange) -> Int {
        guard !rendered.isEmpty || !hiddenSyntax.isEmpty else { return 0 }
        var properties = Array(UnsafeBufferPointer(start: props, count: range.length))
        var output = Array(UnsafeBufferPointer(start: glyphs, count: range.length))
        var changed = false
        for index in 0..<range.length {
            if let item = rendered.first(where: { NSLocationInRange(indexes[index], $0.range) }) {
                properties[index] = indexes[index] == item.range.location ? .controlCharacter : .null
                output[index] = 0
                changed = true
            } else if hiddenSyntax.contains(where: { NSLocationInRange(indexes[index], $0) }) {
                properties[index] = .null
                output[index] = 0
                changed = true
            }
        }
        guard changed else { return 0 }
        setGlyphs(&output, properties: &properties, characterIndexes: indexes, font: font, forGlyphRange: range)
        return range.length
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction, forControlCharacterAt index: Int) -> NSLayoutManager.ControlCharacterAction {
        rendered.contains { $0.range.location == index } ? .whitespace : action
    }

    func layoutManager(_ layoutManager: NSLayoutManager, boundingBoxForControlGlyphAt glyphIndex: Int, for textContainer: NSTextContainer, proposedLineFragment proposedRect: NSRect, glyphPosition: NSPoint, characterIndex: Int) -> NSRect {
        guard let item = rendered.first(where: { $0.range.location == characterIndex }) else { return .zero }
        return NSRect(x: 0, y: -item.image.size.height + 4, width: item.image.size.width + 4, height: item.image.size.height + 4)
    }

    override func drawGlyphs(forGlyphRange glyphs: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphs, at: origin)
        for item in rendered {
            let index = glyphIndexForCharacter(at: item.range.location)
            guard NSLocationInRange(index, glyphs) else { continue }
            let line = lineFragmentRect(forGlyphAt: index, effectiveRange: nil)
            let position = location(forGlyphAt: index)
            let rect = NSRect(x: origin.x + line.minX + position.x,
                              y: origin.y + line.minY + position.y - item.image.size.height + 4,
                              width: item.image.size.width, height: item.image.size.height)
            item.image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }
}

@MainActor final class MathImageRenderer {
    private var cache: [String: NSImage] = [:]

    func image(formula: String, display: Bool, macros: [String: String], fontSize: Double, width: Double, dark: Bool) async throws -> NSImage? {
        let key = "\(formula)|\(display)|\(fontSize)|\(width)|\(dark)|\(MathPresentation.json(macros))"
        if let cached = cache[key] { return cached }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: max(80, width), height: 2000), configuration: config)
        web.setValue(false, forKey: "drawsBackground")
        defer { web.stopLoading() }
        web.loadHTMLString(ScienceMathHTML.document(source: formula, math: true, dark: dark, macros: macros, fontSize: fontSize, display: display, strictRender: true), baseURL: nil)
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if let ready = try? await web.evaluateJavaScript("document.querySelector('.katex') !== null && document.fonts.status === 'loaded'"), ready as? Bool == true { break }
            if let failed = try? await web.evaluateJavaScript("document.querySelector('.katex-error, [data-render-error]') !== null"), failed as? Bool == true { return nil }
            try await Task.sleep(for: .milliseconds(25))
        }
        try Task.checkCancellation()
        guard let rect = try await web.evaluateJavaScript("(() => { const e = document.querySelector('.katex'); if (!e) return null; const r=e.getBoundingClientRect(); return [r.x,r.y,r.width,r.height]; })()") as? [Double], rect.count == 4, rect[2] > 0, rect[3] > 0 else { return nil }
        let capture = WKPDFConfiguration()
        capture.rect = CGRect(x: max(0, rect[0] - 2), y: max(0, rect[1] - 2), width: min(width, rect[2] + 4), height: rect[3] + 4)
        let data = try await web.pdf(configuration: capture)
        try Task.checkCancellation()
        guard let image = NSImage(data: data) else { return nil }
        image.size = capture.rect!.size
        if cache.count >= 256 { cache.removeAll(keepingCapacity: true) }
        cache[key] = image
        return image
    }
}

extension EditorCoordinator {
    func updateMathPresentation() {
        mathTask?.cancel()
        guard let tv = textView, let layout = tv.layoutManager as? MathLayoutManager, let config else { return }
        guard config.renderMode == .mixed, !tv.hasMarkedText() else { layout.setRendered([]); layout.hiddenSyntax = []; return }
        let source = tv.string
        let selection = tv.selectedRange()
        layout.hiddenSyntax = MarkdownPresentation.hiddenSyntax(in: source, selection: selection)
        let regions = MathPresentation.regions(in: source).filter {
            !MathPresentation.showsSource($0.range.nsRange, selection: selection, text: source)
        }
        // Discard old offsets synchronously before any asynchronous rendering.
        layout.setRendered(layout.rendered.filter { item in
            mathSource == source && regions.contains { $0.range.nsRange == item.range }
        })
        mathSource = source
        let macros = MathPresentation.macros(in: source)
        let dark = tv.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let width = max(80, min(config.columnWidth, Double(tv.textContainer?.size.width ?? CGFloat(config.columnWidth))))
        mathTask = Task { [weak self, weak tv, weak layout] in
            guard let self else { return }
            var output: [RenderedMath] = []
            for region in regions {
                do {
                    let formula = region.normalizedContent
                    if let image = try await mathRenderer.image(formula: formula, display: region.kind == .displayMath,
                                                               macros: macros, fontSize: config.fontSize, width: width, dark: dark) {
                        try Task.checkCancellation()
                        guard tv?.string == source, self.config?.renderMode == .mixed else { return }
                        output.append(RenderedMath(range: region.range.nsRange, image: image))
                        layout?.setRendered(output)
                        tv?.needsDisplay = true
                    }
                } catch { return }
            }
            layout?.setRendered(output)
        }
    }
}
