// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import TersoCore

/// Styles Markdown in place by setting display attributes. The characters —
/// and therefore the file — are never changed.
@MainActor
enum MarkdownStyler {
    static func re(_ p: String, _ o: NSRegularExpression.Options = [.anchorsMatchLines]) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: o)
    }
    static let heading = re(#"^(#{1,6})([ \t]+)(.*)$"#)
    static let bold = re(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    static let italic = re(#"(?<![*_\p{L}\p{N}])([*_])(?=[^\s*_])(.+?)(?<=[^\s*_])\1(?![*_\p{L}\p{N}])"#)
    static let code = re(#"`[^`\n]+`"#)
    static let link = re(#"(\[)([^\]\n]+)(\]\([^)\n]*\))"#)
    static let wikiLink = re(#"\[\[([^\[\]|\n]+)(?:\|([^\[\]|\n]+))?\]\]"#)
    static let quote = re(#"^[ \t]*>.*$"#)
    static let list = re(#"^[ \t]*(?:[-*+]|\d{1,3}[.)])[ \t]+"#)
    static let rule = re(#"^[ \t]*(?:[-*_][ \t]*){3,}$"#)
    static let fence = re(#"^[ \t]*(```|~~~)[^\n]*\n[\s\S]*?(?:^[ \t]*\1[ \t]*$|\z)"#)
    static let strike = re(#"(~~)(?=\S)(.+?)(?<=\S)~~"#)
    static let footnote = re(#"\[\^[^\]\s]+\](:?)"#)
    static let task = re(#"^[ \t]*(?:[-*+]|\d{1,3}[.)])[ \t]+(\[[ xX]\])"#)
    static let table = re(#"(?:^[ \t]*\|.*(?:\n|\z))+"#)
    static let tableRule = re(#"^[ \t]*\|[ \t:|-]*-[ \t:|-]*$"#)
    static let pipe = re(#"\|"#)
    static let metaKey = re(#"^[ \t]*(?:-[ \t]+)?([\w.-][\w .-]*?)[ \t]*(:|=)(?=[ \t]|$)"#)
    static let metaComment = re(#"^[ \t]*#.*$"#)

    /// Code beside prose in Mixed mode. Monospace reads large per point, but
    /// much below the body size it turns into fine print.
    static let codeScale: CGFloat = 0.95

    static func paragraphStyle(_ c: EditorConfig) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        // lineSpacing (not lineHeightMultiple) keeps highlight backgrounds aligned with glyphs.
        p.lineSpacing = c.fontSize * max(0, c.lineSpacing - 1)
        p.paragraphSpacing = c.fontSize * 0.8
        return p
    }

    /// Metadata, tables and display math read as compact blocks: no gap
    /// between their lines, normal paragraph spacing after the last one.
    static func blockParagraphStyle(_ c: EditorConfig, last: Bool, indent: CGFloat = 0) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = c.fontSize * 0.12
        p.paragraphSpacing = last ? c.fontSize * 0.8 : 0
        p.firstLineHeadIndent = indent
        p.headIndent = indent
        return p
    }

    static func baseAttributes(_ c: EditorConfig) -> [NSAttributedString.Key: Any] {
        [.font: c.font.font(size: c.fontSize), .foregroundColor: c.theme.bodyInk, .paragraphStyle: paragraphStyle(c)]
    }

    static func headingFont(_ c: EditorConfig, level: Int) -> NSFont {
        let scale: [CGFloat] = [1.42, 1.22, 1.08, 1.0, 1.0, 1.0]
        let size = c.fontSize * scale[level - 1]
        switch c.font {
        case .newYork: return NSFont.systemFont(ofSize: size, weight: .semibold).withDesign(.serif)
        case .system: return NSFont.systemFont(ofSize: size, weight: .semibold)
        case .mono: return NSFont.monospacedSystemFont(ofSize: size, weight: .semibold)
        default: return c.font.font(size: size).adding(.bold)
        }
    }

    static func syntaxColor(_ c: EditorConfig) -> NSColor {
        switch c.syntax {
        case .visible: c.theme.secondary
        case .subdued: c.theme.tertiary
        case .faint: c.theme.quaternary
        }
    }

    static func style(_ storage: NSTextStorage, range: NSRange, config: EditorConfig?) {
        guard let c = config, range.length > 0 else { return }
        let text = storage.string
        let ns = text as NSString
        let base = c.font.font(size: c.fontSize)
        let mono = NSFont.monospacedSystemFont(ofSize: c.fontSize * codeScale, weight: .regular)
        let syntax = syntaxColor(c)
        storage.setAttributes(baseAttributes(c), range: range)
        if c.renderMode == .source {
            storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: c.fontSize, weight: .regular), range: range)
            return
        }
        func each(_ r: NSRegularExpression, _ body: (NSTextCheckingResult) -> Void) {
            r.enumerateMatches(in: text, range: range) { m, _, _ in if let m { body(m) } }
        }
        func color(_ col: NSColor, _ r: NSRange) { storage.addAttribute(.foregroundColor, value: col, range: r) }
        /// Paragraph styles for a multi-line block; only the last line gets space after it.
        func block(_ r: NSRange, indent: CGFloat = 0) {
            let lastLine = ns.lineRange(for: NSRange(location: max(r.location, r.upperBound - 1), length: 0))
            storage.addAttribute(.paragraphStyle, value: blockParagraphStyle(c, last: false, indent: indent), range: NSIntersectionRange(r, range))
            storage.addAttribute(.paragraphStyle, value: blockParagraphStyle(c, last: true, indent: indent), range: NSIntersectionRange(lastLine, range))
        }

        if c.renderMode == .source {
            storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: c.fontSize, weight: .regular), range: range)
            // Keep metadata compact even when syntax is shown as plain source.
            if let fm = MarkdownSyntax.frontMatter(in: text), NSIntersectionRange(fm, range).length > 0 {
                block(fm)
            }
            return
        }

        if c.latex {
            styleLaTeX(storage, range: range, config: c, block: block)
            return
        }

        // Literal regions — metadata, fenced code, code spans, math — are
        // claimed first so no other rule reaches inside them.
        var literal: [NSRange] = []
        func inLiteral(_ r: NSRange) -> Bool { literal.contains { NSIntersectionRange($0, r).length > 0 } }

        if let fm = MarkdownSyntax.frontMatter(in: text), NSIntersectionRange(fm, range).length > 0 {
            literal.append(fm)
            styleFrontMatter(storage, NSIntersectionRange(fm, range), config: c, block: block)
        }
        var fences: [NSRange] = []
        each(fence) { m in
            guard !inLiteral(m.range) else { return }
            fences.append(m.range)
        }
        literal += fences
        var spans: [NSRange] = []
        each(code) { m in
            guard !inLiteral(m.range) else { return }
            spans.append(m.range)
        }
        literal += spans
        let maths = MarkdownSyntax.mathRanges(in: text, range: range).filter { !inLiteral($0) }
        literal += maths
        func inCode(_ r: NSRange) -> Bool { inLiteral(r) }

        each(heading) { m in
            guard !inCode(m.range) else { return }
            let level = m.range(at: 1).length
            storage.addAttribute(.font, value: headingFont(c, level: level), range: m.range)
            storage.addAttribute(.foregroundColor, value: c.theme.label, range: m.range(at: 3))
            // The reader should see the heading before its syntax.
            storage.addAttribute(.foregroundColor, value: c.theme.quaternary, range: m.range(at: 1))
            storage.addAttribute(.font, value: c.font.font(size: c.fontSize * 0.96), range: m.range(at: 1))
        }
        each(bold) { m in
            guard !inCode(m.range) else { return }
            storage.addAttribute(.font, value: base.adding(.bold), range: m.range(at: 2))
            storage.addAttribute(.foregroundColor, value: syntax, range: NSRange(location: m.range.location, length: m.range(at: 1).length))
            storage.addAttribute(.foregroundColor, value: syntax, range: NSRange(location: m.range.upperBound - m.range(at: 1).length, length: m.range(at: 1).length))
        }
        each(italic) { m in
            guard !inCode(m.range) else { return }
            let current = storage.attribute(.font, at: m.range(at: 2).location, effectiveRange: nil) as? NSFont ?? base
            storage.addAttribute(.font, value: current.adding(.italic), range: m.range(at: 2))
            storage.addAttribute(.foregroundColor, value: syntax, range: m.range(at: 1))
            storage.addAttribute(.foregroundColor, value: syntax, range: NSRange(location: m.range.upperBound - 1, length: 1))
        }
        each(strike) { m in
            guard !inCode(m.range) else { return }
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: m.range(at: 2))
            color(c.theme.secondary, m.range(at: 2))
            color(syntax, m.range(at: 1))
            color(syntax, NSRange(location: m.range.upperBound - 2, length: 2))
        }
        each(link) { m in
            guard !inCode(m.range) else { return }
            storage.addAttribute(.foregroundColor, value: syntax, range: m.range(at: 1))
            storage.addAttribute(.foregroundColor, value: syntax, range: m.range(at: 3))
            storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: m.range(at: 2))
            storage.addAttribute(.underlineColor, value: c.theme.separator, range: m.range(at: 2))
        }
        each(wikiLink) { m in
            guard !inCode(m.range) else { return }
            let label = m.range(at: m.range(at: 2).location == NSNotFound ? 1 : 2)
            color(syntax, m.range)
            color(c.theme.bodyInk, label)
            storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: label)
            storage.addAttribute(.underlineColor, value: c.theme.separator, range: label)
        }
        each(footnote) { m in
            guard !inCode(m.range) else { return }
            color(syntax, m.range)
            // A reference sits above the line; a definition (`[^1]:`) stays on it.
            if m.range(at: 1).length == 0 {
                storage.addAttribute(.font, value: c.font.font(size: c.fontSize * 0.78), range: m.range)
                storage.addAttribute(.baselineOffset, value: c.fontSize * 0.3, range: m.range)
            }
        }
        each(quote) { m in
            guard !inCode(m.range) else { return }
            storage.addAttribute(.foregroundColor, value: c.theme.secondary, range: m.range)
            storage.addAttribute(.font, value: base.adding(.italic), range: m.range)
        }
        each(list) { m in
            guard !inCode(m.range) else { return }
            storage.addAttribute(.foregroundColor, value: syntax, range: m.range)
        }
        each(task) { m in
            guard !inCode(m.range) else { return }
            color(syntax, m.range(at: 1))
            // A ticked item recedes.
            if ns.substring(with: m.range(at: 1)).lowercased() == "[x]" {
                let line = ns.lineRange(for: m.range)
                let rest = NSRange(location: m.range.upperBound, length: line.upperBound - m.range.upperBound)
                color(c.theme.tertiary, NSIntersectionRange(rest, range))
            }
        }
        each(rule) { m in
            guard !inCode(m.range) else { return }
            storage.addAttribute(.foregroundColor, value: syntax, range: m.range)
        }
        each(table) { m in
            guard !inCode(m.range) else { return }
            storage.addAttribute(.font, value: mono, range: m.range)
            block(m.range)
            tableRule.enumerateMatches(in: text, range: m.range) { r, _, _ in if let r { color(syntax, r.range) } }
            pipe.enumerateMatches(in: text, range: m.range) { r, _, _ in if let r { color(syntax, r.range) } }
        }
        for r in spans {
            storage.addAttribute(.font, value: mono, range: r)
            storage.addAttribute(.foregroundColor, value: c.theme.secondary, range: r)
        }
        for r in fences {
            storage.addAttribute(.font, value: mono, range: r)
            storage.addAttribute(.foregroundColor, value: c.theme.secondary, range: r)
        }
        styleMath(storage, maths, range: range, config: c, block: block)
    }

    static let texCommand = re(#"\\(?:[A-Za-z@]+\*?|[^A-Za-z\s])"#, [])
    static let texComment = re(#"(?<!\\)%.*$"#)
    static let texBrace = re(#"(?<!\\)[{}]"#, [])
    static let texEnvironment = re(#"\\(?:begin|end)\{[^}\n]*\}"#, [])
    static let texEmphasis = re(#"\\(emph|textit|textsl)\{([^{}\n]*)\}"#, [])
    static let texBold = re(#"\\textbf\{([^{}\n]*)\}"#, [])
    static let texCode = re(#"\\(?:texttt|url|path)\{([^{}\n]*)\}"#, [])
    static let texReference = re(#"\\(?:cite[pt]?|citeauthor|citeyear|ref|eqref|autoref|cref|Cref|pageref|label)\*?(?:\[[^\]\n]*\])*\{[^{}\n]*\}"#, [])

    /// LaTeX source: sectioning set like headings, commands and braces receded
    /// to syntax, emphasis shown, citations and labels quiet, comments and
    /// verbatim environments set apart. The characters are never changed.
    static func styleLaTeX(_ storage: NSTextStorage, range: NSRange, config c: EditorConfig, block: (NSRange, CGFloat) -> Void) {
        let text = storage.string
        let base = c.font.font(size: c.fontSize)
        let mono = NSFont.monospacedSystemFont(ofSize: c.fontSize * codeScale, weight: .regular)
        let syntax = syntaxColor(c)
        func each(_ r: NSRegularExpression, in scope: NSRange = range, _ body: (NSTextCheckingResult) -> Void) {
            r.enumerateMatches(in: text, range: scope) { m, _, _ in if let m { body(m) } }
        }
        func color(_ col: NSColor, _ r: NSRange) { storage.addAttribute(.foregroundColor, value: col, range: r) }

        // Literal regions are found across the whole text, since an edit may
        // fall in the middle of an environment that opened paragraphs earlier.
        var literal: [NSRange] = []
        func inLiteral(_ r: NSRange) -> Bool { literal.contains { NSIntersectionRange($0, r).length > 0 } }
        for env in LaTeXSyntax.literalEnvironments(in: text) where LaTeXSyntax.codeEnvironments.contains(env.name) {
            let r = NSIntersectionRange(env.range, range)
            guard r.length > 0 else { continue }
            literal.append(env.range)
            storage.addAttributes([.font: mono, .foregroundColor: c.theme.secondary], range: r)
        }
        var comments: [NSRange] = []
        each(texComment) { m in
            guard !inLiteral(m.range) else { return }
            comments.append(m.range)
        }
        literal += comments
        let maths = MarkdownSyntax.mathRanges(in: text, range: range).filter { !inLiteral($0) }
        literal += maths

        each(texCommand) { m in if !inLiteral(m.range) { color(syntax, m.range) } }
        each(texBrace) { m in if !inLiteral(m.range) { color(syntax, m.range) } }
        each(texEnvironment) { m in if !inLiteral(m.range) { color(syntax, m.range) } }
        each(texEmphasis) { m in
            guard !inLiteral(m.range) else { return }
            storage.addAttribute(.font, value: base.adding(.italic), range: m.range(at: 2))
        }
        each(texBold) { m in
            guard !inLiteral(m.range) else { return }
            storage.addAttribute(.font, value: base.adding(.bold), range: m.range(at: 1))
        }
        each(texCode) { m in
            guard !inLiteral(m.range) else { return }
            storage.addAttributes([.font: mono, .foregroundColor: c.theme.secondary], range: m.range(at: 1))
        }
        each(texReference) { m in
            guard !inLiteral(m.range) else { return }
            color(c.theme.tertiary, m.range)
        }
        // Sectioning: the title reads as a heading, its command recedes.
        let sections = LaTeXSyntax.section.matches(in: text, range: range).filter { !inLiteral($0.range) }
        // Levels depend on every sectioning command in the file, not only the edited span.
        let all = LaTeXSyntax.section.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
        let levels = LaTeXSyntax.levels(for: Set(all.map { (text as NSString).substring(with: $0.range(at: 1)) }))
        for m in sections {
            let level = levels[(text as NSString).substring(with: m.range(at: 1))] ?? 1
            storage.addAttribute(.font, value: headingFont(c, level: min(level, 6)), range: m.range)
            color(c.theme.quaternary, m.range)
            color(c.theme.label, m.range(at: 2))
        }
        each(LaTeXSyntax.item) { m in if !inLiteral(m.range) { color(syntax, m.range) } }
        for r in comments {
            storage.addAttributes([.foregroundColor: c.theme.quaternary, .font: base.adding(.italic)], range: r)
        }
        styleMath(storage, maths, range: range, config: c, block: block)
    }

    /// YAML or TOML metadata: a compact, quiet block set apart from the prose —
    /// keys receded, values legible, delimiters barely there.
    static func styleFrontMatter(_ storage: NSTextStorage, _ fm: NSRange, config c: EditorConfig, block: (NSRange, CGFloat) -> Void) {
        let text = storage.string
        let small = NSFont.monospacedSystemFont(ofSize: c.fontSize * 0.84, weight: .regular)
        storage.addAttributes([.font: small, .foregroundColor: c.theme.secondary], range: fm)
        block(fm, 0)
        let ns = text as NSString
        let first = ns.lineRange(for: NSRange(location: fm.location, length: 0))
        let last = ns.lineRange(for: NSRange(location: max(fm.location, fm.upperBound - 1), length: 0))
        storage.addAttribute(.foregroundColor, value: c.theme.quaternary, range: NSIntersectionRange(first, fm))
        storage.addAttribute(.foregroundColor, value: c.theme.quaternary, range: NSIntersectionRange(last, fm))
        metaKey.enumerateMatches(in: text, range: fm) { m, _, _ in
            guard let m else { return }
            storage.addAttribute(.foregroundColor, value: c.theme.tertiary, range: m.range(at: 1))
            storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: c.fontSize * 0.84, weight: .medium), range: m.range(at: 1))
            storage.addAttribute(.foregroundColor, value: c.theme.quaternary, range: m.range(at: 2))
        }
        metaComment.enumerateMatches(in: text, range: fm) { m, _, _ in
            guard let m else { return }
            storage.addAttribute(.foregroundColor, value: c.theme.quaternary, range: m.range)
        }
    }

    /// LaTeX math in a serif italic, like typeset maths; display math is
    /// indented as its own compact block. The source is left as written.
    static func styleMath(_ storage: NSTextStorage, _ maths: [NSRange], range: NSRange, config c: EditorConfig, block: (NSRange, CGFloat) -> Void) {
        let ns = storage.string as NSString
        let serif = NSFont.systemFont(ofSize: c.fontSize * 0.95).withDesign(.serif).adding(.italic)
        let syntax = syntaxColor(c)
        for r in maths {
            let r = NSIntersectionRange(r, range)
            guard r.length > 0 else { continue }
            storage.addAttributes([.font: serif, .foregroundColor: c.theme.secondary], range: r)
            let s = ns.substring(with: r)
            if s.hasPrefix("\\begin") {
                // Environment names are syntax, the body is maths.
                for token in ["\\begin{", "\\end{"] {
                    var from = r.location
                    while from < r.upperBound {
                        let t = ns.range(of: token, range: NSRange(location: from, length: r.upperBound - from))
                        guard t.location != NSNotFound else { break }
                        let close = ns.range(of: "}", range: NSRange(location: t.upperBound, length: r.upperBound - t.upperBound))
                        guard close.location != NSNotFound else { break }
                        storage.addAttribute(.foregroundColor, value: syntax, range: NSRange(location: t.location, length: close.upperBound - t.location))
                        from = close.upperBound
                    }
                }
            } else {
                let d = (s.hasPrefix("$$")) ? 2 : (s.hasPrefix("$") ? 1 : 2)
                if r.length > 2 * d {
                    storage.addAttribute(.foregroundColor, value: syntax, range: NSRange(location: r.location, length: d))
                    storage.addAttribute(.foregroundColor, value: syntax, range: NSRange(location: r.upperBound - d, length: d))
                }
            }
            // Display maths on lines of its own reads as a block.
            let lines = ns.lineRange(for: r)
            let before = ns.substring(with: NSRange(location: lines.location, length: r.location - lines.location))
            let after = ns.substring(with: NSRange(location: r.upperBound, length: lines.upperBound - r.upperBound))
            let isDisplay = s.hasPrefix("$$") || s.hasPrefix("\\[") || s.hasPrefix("\\begin")
            if isDisplay, before.allSatisfy(\.isWhitespace), after.allSatisfy(\.isWhitespace) {
                block(NSIntersectionRange(lines, range), c.fontSize * 1.5)
            }
        }
    }
}
