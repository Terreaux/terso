// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import WebKit
import TersoCore

struct RenderedMath {
    let range: NSRange
    let image: NSImage
    /// Formulas and tables raise their line to fit; a bullet, checkbox or
    /// cross-reference sits on the line as text would.
    var reservesHeight = true
    /// For a task checkbox: the `[ ]` a click toggles.
    var toggle: NSRange? = nil
}

/// A blockquote line: Mixed draws one bar per nesting level beside it.
struct QuoteBar: Equatable {
    let range: NSRange
    let depth: Int
}

/// Substitutes display glyphs, never characters. Copy, undo, analysis, saving,
/// accessibility and source navigation all continue to use the original text.
final class MathLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    var rendered: [RenderedMath] = []
    private var syntaxRanges: [NSRange] = []
    var hiddenSyntax: [NSRange] {
        get { syntaxRanges }
        set {
            guard syntaxRanges != newValue else { return }
            syntaxRanges = newValue
            invalidateSubstitutions()
        }
    }
    private var bars: [QuoteBar] = []
    var quoteBars: [QuoteBar] {
        get { bars }
        set {
            guard bars != newValue else { return }
            bars = newValue
            guard let storage = textStorage else { return }
            invalidateDisplay(forCharacterRange: NSRange(location: 0, length: storage.length))
        }
    }
    override init() { super.init(); delegate = self }
    required init?(coder: NSCoder) { super.init(coder: coder); delegate = self }

    func setRendered(_ items: [RenderedMath]) {
        guard rendered.map(\.range) != items.map(\.range)
                || zip(rendered, items).contains(where: { $0.image !== $1.image }) else { return }
        rendered = items
        invalidateSubstitutions()
    }

    /// New glyphs reflow their lines, but a caret reveal edits nothing, so
    /// TextKit neither redraws nor re-lays them out: the next selection redraw
    /// would fill backgrounds at the old positions under glyphs at the new.
    private func invalidateSubstitutions() {
        guard let storage = textStorage else { return }
        invalidateGlyphs(forCharacterRange: NSRange(location: 0, length: storage.length), changeInLength: 0, actualCharacterRange: nil)
        for container in textContainers {
            guard let view = container.textView, view.window != nil else { continue }
            let visible = view.visibleRect
            // Mid-edit, the storage edit lays out and redraws once it lands.
            if storage.editedMask.isEmpty {
                ensureLayout(forBoundingRect: visible.offsetBy(dx: -view.textContainerOrigin.x, dy: -view.textContainerOrigin.y), in: container)
            }
            view.setNeedsDisplay(visible)
        }
    }

    /// Keep substitutions outside an edit alive, translating their UTF-16 offsets
    /// before TextKit lays out the changed storage. Only touched source is revealed.
    func processCharacterEdit(range: NSRange, changeInLength delta: Int) {
        let replaced = NSRange(location: range.location, length: range.length - delta)
        func translated(_ existing: NSRange) -> NSRange? {
            if NSMaxRange(existing) <= replaced.location { return existing }
            if existing.location >= NSMaxRange(replaced) {
                return NSRange(location: existing.location + delta, length: existing.length)
            }
            return nil
        }
        // Storage has not notified its layout managers yet. Update bookkeeping
        // only; invalidating glyphs here would mix new offsets with the old tree.
        // The storage edit and styling pass perform the layout invalidation.
        rendered = rendered.compactMap { item in
            translated(item.range).map { range in
                RenderedMath(range: range, image: item.image, reservesHeight: item.reservesHeight,
                             toggle: item.toggle.flatMap(translated))
            }
        }
        bars = bars.compactMap { bar in translated(bar.range).map { QuoteBar(range: $0, depth: bar.depth) } }
        syntaxRanges = syntaxRanges.compactMap(translated)
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
        // Formulas and tables keep a little air after them; inline decorations
        // (bullets, references) advance exactly as wide as they draw.
        let air: CGFloat = item.reservesHeight ? 4 : 0
        return NSRect(x: 0, y: -item.image.size.height + 4, width: item.image.size.width + air, height: item.image.size.height + 4)
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>, lineFragmentUsedRect: UnsafeMutablePointer<NSRect>, baselineOffset: UnsafeMutablePointer<CGFloat>, in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
        let characters = characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let height = rendered.filter { $0.reservesHeight && NSLocationInRange($0.range.location, characters) }
            .map { $0.image.size.height }.max() ?? 0
        guard height > 0 else { return false }
        // A control glyph reserves horizontal advance, but TextKit does not
        // raise the baseline to accommodate its ascent. Reserve that ascent
        // explicitly so tall fractions/blocks cannot paint over preceding text.
        let extraAscent = max(0, height - baselineOffset.pointee)
        baselineOffset.pointee += extraAscent
        lineFragmentRect.pointee.size.height += extraAscent
        lineFragmentUsedRect.pointee.size.height += extraAscent
        let minimumHeight = baselineOffset.pointee + 4
        lineFragmentRect.pointee.size.height = max(lineFragmentRect.pointee.height, minimumHeight)
        lineFragmentUsedRect.pointee.size.height = max(lineFragmentUsedRect.pointee.height, minimumHeight)
        return true
    }

    override func drawBackground(forGlyphRange glyphs: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphs, at: origin)
        guard !quoteBars.isEmpty else { return }
        let characters = characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        NSColor.tertiaryLabelColor.withAlphaComponent(0.5).setFill()
        for bar in quoteBars where NSIntersectionRange(bar.range, characters).length > 0 || bar.range.length == 0 {
            let range = glyphRange(forCharacterRange: bar.range, actualCharacterRange: nil)
            guard NSIntersectionRange(range, glyphs).length > 0 else { continue }
            enumerateLineFragments(forGlyphRange: range) { line, _, _, _, _ in
                for level in 0..<bar.depth {
                    NSRect(x: origin.x + line.minX + 2 + CGFloat(level) * MixedPresentation.quoteIndent,
                           y: origin.y + line.minY, width: 3, height: line.height).fill()
                }
            }
        }
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
        guard config.renderMode == .mixed, !tv.hasMarkedText() else {
            layout.setRendered([]); layout.hiddenSyntax = []; layout.quoteBars = []; return
        }
        let source = tv.string
        let selection = tv.selectedRange()
        // A book's text block, which a spread's container is two of.
        let width = max(80, tv.book.map { Double($0.column) } ?? min(config.columnWidth, Double(tv.textContainer?.size.width ?? CGFloat(config.columnWidth))))
        let shown = config.mixedRendered.intersection(MixedElement.available(latex: config.latex, text: source))
        let decor = MixedPresentation.layout(in: source, selection: selection, config: config, elements: shown, width: width)
        layout.hiddenSyntax = (shown.contains(.links) ? LinkPresentation.hiddenSyntax(in: source, selection: selection) : [])
            + MarkerPresentation.hiddenSyntax(in: source, selection: selection, latex: config.latex, elements: shown)
        layout.quoteBars = decor.quoteBars
        // Math or an image inside a rendered table is drawn by the table.
        func covered(_ range: NSRange) -> Bool { decor.glyphs.contains { NSIntersectionRange($0.range, range).length > 0 } }
        let allEmbeds = config.latex ? [] : ImagePresentation.embeds(in: source)
        let embeds = !shown.contains(.images) ? [] : allEmbeds.filter {
            !MathPresentation.showsSource($0.range, selection: selection, text: source) && !covered($0.range)
        }
        // A `$` inside an image URL must never render as math over the embed.
        let regions = !shown.contains(.math) ? [] : MathPresentation.regions(in: source).filter { region in
            !covered(region.range.nsRange)
                && !MathPresentation.showsSource(region.range.nsRange, selection: selection, text: source)
                && !allEmbeds.contains { NSIntersectionRange($0.range, region.range.nsRange).length > 0 }
        }
        let visible = regions.map(\.range.nsRange) + embeds.map(\.range)
        // Discard old offsets synchronously before any asynchronous rendering.
        layout.setRendered((layout.rendered.filter { item in
            mathSource == source && visible.contains(item.range)
        } + decor.glyphs).sorted { $0.range.location < $1.range.location })
        mathSource = source
        let macros = MathPresentation.macros(in: source)
        let dark = tv.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let directory = model.fileURL?.deletingLastPathComponent()
        let images = embeds.compactMap { embed in
            ImagePresentation.url(for: embed.source, directory: directory).map { (range: embed.range, url: $0) }
        }
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
                    }
                } catch { return }
            }
            guard !Task.isCancelled, tv?.string == source, self.config?.renderMode == .mixed else { return }
            // Publish the complete batch: a partial prefix would temporarily
            // remove later equations even when their cached images are unchanged.
            // Slow downloads must not hold back math, so cached images go first.
            func publish(_ pictures: [RenderedMath]) {
                layout?.setRendered((output + pictures + decor.glyphs).sorted { $0.range.location < $1.range.location })
            }
            publish(images.compactMap { item in
                imageLoader.cachedImage(for: item.url, width: width).map { RenderedMath(range: item.range, image: $0) }
            })
            guard images.contains(where: { imageLoader.cachedImage(for: $0.url, width: width) == nil }) else { return }
            var pictures: [RenderedMath] = []
            for item in images {
                if let image = await imageLoader.image(for: item.url, width: width) {
                    pictures.append(RenderedMath(range: item.range, image: image))
                }
            }
            guard !Task.isCancelled, tv?.string == source, self.config?.renderMode == .mixed else { return }
            publish(pictures)
        }
    }
}
