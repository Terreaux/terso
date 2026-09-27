// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import TersoCore

/// How findings look in the document. Normal text carries nothing; then:
///  • passive  — a thin underline in the finding's family treatment, no fill;
///  • hover    — the same underline, stronger, with a faint tint;
///  • passage  — the selected passage gets one warm wash, so it is obvious
///               which sentences the expanded Review card is about;
///  • finding  — inside that wash, the selected finding's exact range gets a
///               thick underline and a denser tint of its own.
/// Overlapping findings are drawn once, as a cluster, so nothing stacks.
enum HighlightStyle {
    /// Four restrained families instead of one colour per analyzer. Every
    /// family also has its own underline pattern: colour is never the only cue.
    static func color(_ f: AnnotationFamily) -> NSColor {
        switch f {
        case .writing: NSColor.systemBrown
        case .spelling: NSColor.systemRed
        case .aiSuggestion: NSColor.controlAccentColor
        case .aiStyle: NSColor.systemPurple
        }
    }

    static func pattern(_ f: AnnotationFamily) -> NSUnderlineStyle {
        switch f {
        case .writing: [.single]
        case .spelling: [.single, .patternDot]
        case .aiSuggestion: [.single, .patternDash]
        case .aiStyle: [.single, .patternDashDotDot]
        }
    }

    static func passive(_ f: AnnotationFamily, contrast: Bool) -> [NSAttributedString.Key: Any] {
        [.underlineStyle: pattern(f).rawValue, .underlineColor: color(f).withAlphaComponent(contrast ? 0.9 : 0.45)]
    }

    static func hover(_ f: AnnotationFamily, contrast: Bool) -> [NSAttributedString.Key: Any] {
        [.underlineStyle: (pattern(f).rawValue & ~0xFF) | NSUnderlineStyle.thick.rawValue, .underlineColor: color(f).withAlphaComponent(contrast ? 1 : 0.85),
         .backgroundColor: color(f).withAlphaComponent(contrast ? 0.12 : 0.06)]
    }

    /// Shared warm accent for the document, Review card and issue rail.
    static let passageAccent = NSColor.systemBrown


    static func selected(_ f: AnnotationFamily, blockLevel: Bool, contrast: Bool) -> [NSAttributedString.Key: Any] {
        // Keep stronger emphasis local to the exact contributing range.
        let tint = blockLevel ? color(f).withAlphaComponent(contrast ? 0.14 : 0.07)
                              : passageAccent.withAlphaComponent(contrast ? 0.28 : 0.16)
        var out: [NSAttributedString.Key: Any] = [.backgroundColor: tint]
        if !blockLevel {
            out[.underlineStyle] = (pattern(f).rawValue & ~0xFF) | NSUnderlineStyle.thick.rawValue
            out[.underlineColor] = color(f)
        }
        return out
    }
}

/// Least prominent first; within a family, sentence tints before phrase underlines.
private func paintOrder(_ a: TextAnnotation) -> Int {
    a.category.family.rawValue * 2 + (AnnotationLayout.isSentenceLevel(a) ? 0 : 1)
}

extension EditorCoordinator {
    func refreshDecorations() {
        applyHighlights()
        applyDimming()
        computeMapMarkers()
    }

    /// Redraws every annotation. Temporary attributes live on the layout
    /// manager only: the text, its attributes and the undo stack are untouched.
    func applyHighlights() {
        guard let tv = textView, let lm = tv.layoutManager else { return }
        let length = (tv.string as NSString).length
        let all = NSRange(location: 0, length: length)
        for key in [NSAttributedString.Key.backgroundColor, .underlineStyle, .underlineColor] {
            lm.removeTemporaryAttribute(key, forCharacterRange: all)
        }
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let drawn = model.drawnAnnotations
        clusters = AnnotationLayout.clusters(drawn)
        // Paint each finding's own span, least prominent family first, so the
        // most prominent treatment wins character by character — one underline
        // per character, never stacked, and a small grammar finding does not
        // recolour the whole sentence around it.
        let hovered = clusters.first { $0.id == model.hoveredClusterID }?.range
        let inline = drawn.filter { !AnnotationLayout.isBlockLevel($0) }
            .sorted { paintOrder($0) < paintOrder($1) }
        for a in inline {
            let f = a.category.family
            for r in a.ranges where r.upperBound <= length && r.length > 0 {
                let isHovered = hovered.map { $0.intersects(r) } ?? false
                let look: [NSAttributedString.Key: Any]
                // Sentence-level findings get the same underline as phrases:
                // a persistent fill on every flagged sentence drowns the one
                // passage that is actually selected.
                look = isHovered ? HighlightStyle.hover(f, contrast: contrast) : HighlightStyle.passive(f, contrast: contrast)
                lm.addTemporaryAttributes(look, forCharacterRange: r.nsRange)
            }
        }
        // A map preview can be outside the currently focused Review passage.
        // Use the same temporary attributes, without changing Review selection.
        if let preview = model.annotation(id: model.previewAnnotationID), !model.focusMode {
            for range in preview.ranges where range.location >= 0 && range.upperBound <= length && range.length > 0 {
                lm.addTemporaryAttributes(HighlightStyle.hover(preview.category.family, contrast: contrast),
                                          forCharacterRange: range.nsRange)
            }
        }
        // Draw a paragraph surface behind the glyphs, never a text-marker fill.
        tv.reviewPassageRange = model.focusMode ? nil : model.selectedPassage?.range.nsRange
        if let range = model.scienceEmphasisRange, !model.focusMode,
           range.location >= 0, range.upperBound <= length, range.length > 0 {
            lm.addTemporaryAttributes(HighlightStyle.selected(.writing, blockLevel: false, contrast: contrast),
                                      forCharacterRange: range.nsRange)
        }
        if let sel = model.selectedFinding, !AnnotationLayout.isBlockLevel(sel) {
            let look = HighlightStyle.selected(sel.category.family, blockLevel: false, contrast: contrast)
            for r in sel.ranges where r.upperBound <= length && r.length > 0 {
                lm.addTemporaryAttributes(look, forCharacterRange: r.nsRange)
            }
        }
    }

    /// Positions for the issue rail, one marker per finding.
    func computeMapMarkers() {
        guard let tv = textView, let lm = tv.layoutManager, let container = tv.textContainer else { return }
        lm.ensureLayout(for: container)
        let total = max(tv.frame.height, 1)
        let length = (tv.string as NSString).length
        var out: [MapMarker] = []
        let diagnostics = Dictionary((model.currentScience?.diagnostics ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let source = model.focusMode ? [] : model.visibleAnnotations
        for a in source.sorted(by: {
            if $0.severity != $1.severity { return $0.severity > $1.severity }
            return ($0.ranges.first?.location ?? 0) < ($1.ranges.first?.location ?? 0)
        }).prefix(500) {
            guard let r = a.ranges.first, r.upperBound <= length else { continue }
            let g = lm.glyphRange(forCharacterRange: NSRange(location: r.location, length: min(r.length, 1)), actualCharacterRange: nil)
            let rect = lm.boundingRect(forGlyphRange: g, in: container)
            let diagnostic = a.metadata["scienceDiagnosticID"].flatMap { diagnostics[$0] }
            out.append(MapMarker(id: a.id, fraction: min(1, (rect.midY + tv.textContainerOrigin.y) / total),
                                 family: a.category.family, severity: diagnostic.map { $0.severity == .info ? .info : .warning } ?? a.severity,
                                 category: a.category, range: r, message: a.message,
                                 severityLabel: diagnostic?.severity.rawValue.capitalized ?? a.severity.label, explanation: a.explanation))
        }
        model.mapMarkers = out
    }
}
