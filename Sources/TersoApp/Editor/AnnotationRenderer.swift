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

    /// Each layer's own colour, shared by its underline, its text tint on the
    /// page and its dot in the layer menus, so the menu and the text match.
    static func color(_ c: AnnotationCategory) -> NSColor {
        switch c {
        case .readability: .systemOrange
        case .complexity: .systemBrown
        case .passiveVoice: .systemTeal
        case .style: .systemPink
        case .repetition: dynamic(light: 0xB07D00, dark: 0xE8C547)
        case .specificity: .systemMint
        case .notation: .systemIndigo
        case .quantities: .systemGreen
        case .references: .systemCyan
        case .claims: dynamic(light: 0x5A7F12, dark: 0xA8D84E)
        case .evidence: .systemBlue
        case .spelling: .systemRed
        case .aiSuggestion: .controlAccentColor
        case .aiStyle: .systemPurple
        case .filler: dynamic(light: 0x6E56CF, dark: 0xA594F9)
        case .adverbs: .systemPink
        case .loosePronouns: dynamic(light: 0x2F6FB0, dark: 0x8FBFF0)
        case .misused: dynamic(light: 0xBE123C, dark: 0xFB7185)
        case .lexicalIllusions: dynamic(light: 0xA21CAF, dark: 0xE879F9)
        case .rhythm: .systemGray
        case .storyShape: .systemIndigo
        }
    }

    private static func dynamic(light: Int, dark: Int) -> NSColor {
        func rgb(_ v: Int) -> NSColor {
            NSColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        }
        return NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? rgb(dark) : rgb(light) }
    }

    static func pattern(_ f: AnnotationFamily) -> NSUnderlineStyle {
        switch f {
        case .writing: [.single]
        case .spelling: [.single, .patternDot]
        case .aiSuggestion: [.single, .patternDash]
        case .aiStyle: [.single, .patternDashDotDot]
        }
    }

    private static func thick(_ f: AnnotationFamily) -> Int {
        (pattern(f).rawValue & ~0xFF) | NSUnderlineStyle.thick.rawValue
    }

    /// A quiet finding (a whole sentence, or an AI-style feature's scattered
    /// words) takes a thin, faint underline so word-level findings stand out.
    static func passive(_ c: AnnotationCategory, quiet: Bool = false, contrast: Bool) -> [NSAttributedString.Key: Any] {
        if quiet {
            return [.underlineStyle: pattern(c.family).rawValue, .underlineColor: color(c).withAlphaComponent(contrast ? 0.8 : 0.45)]
        }
        return [.underlineStyle: thick(c.family), .underlineColor: color(c).withAlphaComponent(contrast ? 1 : 0.8)]
    }

    static func hover(_ c: AnnotationCategory, contrast: Bool) -> [NSAttributedString.Key: Any] {
        [.underlineStyle: thick(c.family), .underlineColor: color(c),
         .backgroundColor: color(c).withAlphaComponent(contrast ? 0.2 : 0.13)]
    }

    /// Shared warm accent for the document, Review card and issue rail.
    static let passageAccent = NSColor.systemBrown


    static func selected(_ c: AnnotationCategory, blockLevel: Bool, contrast: Bool) -> [NSAttributedString.Key: Any] {
        // Keep stronger emphasis local to the exact contributing range, tinted
        // in the finding's own colour so a selected spelling error reads red.
        let tint = blockLevel ? color(c).withAlphaComponent(contrast ? 0.14 : 0.07)
                              : color(c).withAlphaComponent(contrast ? 0.4 : 0.28)
        var out: [NSAttributedString.Key: Any] = [.backgroundColor: tint]
        if !blockLevel {
            out[.underlineStyle] = thick(c.family)
            out[.underlineColor] = color(c)
        }
        return out
    }
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
        // Paint each finding's own span, least prominent first, so the
        // strongest finding wins character by character — one underline per
        // character, never stacked, and a small grammar finding does not
        // recolour the whole sentence around it.
        let hovered = clusters.first { $0.id == model.hoveredClusterID }?.range
        let inline = AnnotationLayout.drawOrder(drawn.filter { !AnnotationLayout.isBlockLevel($0) })
        for a in inline {
            for r in a.ranges where r.upperBound <= length && r.length > 0 {
                let isHovered = hovered.map { $0.intersects(r) } ?? false
                let look: [NSAttributedString.Key: Any]
                // Quiet findings get a thin underline rather than a fill: a
                // persistent fill on every flagged sentence drowns the one
                // passage that is actually selected.
                look = isHovered ? HighlightStyle.hover(a.category, contrast: contrast)
                    : HighlightStyle.passive(a.category, quiet: AnnotationLayout.isQuiet(a), contrast: contrast)
                lm.addTemporaryAttributes(look, forCharacterRange: r.nsRange)
            }
        }
        // A map preview can be outside the currently focused Review passage.
        // Use the same temporary attributes, without changing Review selection.
        if let preview = model.annotation(id: model.previewAnnotationID), !model.focusMode {
            for range in preview.ranges where range.location >= 0 && range.upperBound <= length && range.length > 0 {
                lm.addTemporaryAttributes(HighlightStyle.hover(preview.category, contrast: contrast),
                                          forCharacterRange: range.nsRange)
            }
        }
        // Draw a paragraph surface behind the glyphs, never a text-marker fill.
        tv.reviewPassageRange = model.focusMode ? nil : model.selectedPassage?.range.nsRange
        if let range = model.scienceEmphasisRange, !model.focusMode,
           range.location >= 0, range.upperBound <= length, range.length > 0 {
            lm.addTemporaryAttributes(HighlightStyle.selected(.claims, blockLevel: false, contrast: contrast),
                                      forCharacterRange: range.nsRange)
        }
        if let sel = model.selectedFinding, !AnnotationLayout.isBlockLevel(sel) {
            let look = HighlightStyle.selected(sel.category, blockLevel: false, contrast: contrast)
            for r in sel.ranges where r.upperBound <= length && r.length > 0 {
                lm.addTemporaryAttributes(look, forCharacterRange: r.nsRange)
            }
        }
    }

    /// Word- and phrase-level findings also take their layer's colour as text,
    /// so a flagged word reads like the layer menu. Quiet findings keep just
    /// the underline. Called from applyDimming, which owns the foreground.
    func applyFindingText() {
        guard let lm = textView?.layoutManager, !model.focusMode else { return }
        let length = ((textView?.string ?? "") as NSString).length
        let phrases = AnnotationLayout.drawOrder(model.drawnAnnotations
            .filter { !AnnotationLayout.isBlockLevel($0) && !AnnotationLayout.isQuiet($0) })
        for a in phrases {
            for r in a.ranges where r.upperBound <= length && r.length > 0 {
                lm.addTemporaryAttribute(.foregroundColor, value: HighlightStyle.color(a.category), forCharacterRange: r.nsRange)
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
