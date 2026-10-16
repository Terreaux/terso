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
    /// Obsidian highlights and comments, and HTML comments.
    static let highlight = re(#"(==)(?=[^\s=])(.+?)(?<=[^\s=])=="#)
    static let comment = re(#"%%[\s\S]*?%%|<!--[\s\S]*?-->"#, [])
    /// A Python-Markdown admonition's opening line: `!!! type "Title"`, or
    /// `???`/`???+` for one that folds. Its body is the indented lines below.
    static let admonition = re(#"^(!!!|\?\?\?\+?)[ \t]+([\w-]+(?:[ \t]+[\w-]+)*)(?:[ \t]+"([^"\n]*)")?[ \t]*$"#)
    /// CriticMarkup, one form each: insertion, deletion, substitution
    /// (`{~~old~>new~~}`), highlight and comment. Group 1 is the text.
    static let criticInsert = re(#"\{\+\+(.+?)\+\+\}"#)
    static let criticDelete = re(#"\{--(.+?)--\}"#)
    static let criticSubstitute = re(#"\{~~(.*?)~>(.*?)~~\}"#)
    static let criticHighlight = re(#"\{==(.+?)==\}"#)
    static let criticComment = re(#"\{>>(.+?)<<\}"#)
    static let critic = [criticInsert, criticDelete, criticSubstitute, criticHighlight, criticComment]
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
        // A book page: justified and hyphenated, as the design asks, with
        // paragraphs told apart by an indent or by space between them.
        if let book = c.book {
            p.alignment = book.justify ? .justified : .natural
            p.hyphenationFactor = book.hyphenate ? 0.9 : 0
            p.paragraphSpacing = book.paragraphs == .spaced ? c.fontSize * 0.7 : 0
        }
        return p
    }

    /// Manutius sets paragraphs as print does: the blank line between them
    /// closes up, prose that follows prose is indented, the first paragraph
    /// after a heading or block is flush, and headings get room above.
    /// Chapter headings and scene breaks are set as the book design asks.
    static func styleBook(_ storage: NSTextStorage, range: NSRange, config c: EditorConfig) {
        let ns = storage.string as NSString
        let blank = NSMutableParagraphStyle()
        blank.minimumLineHeight = 2
        blank.maximumLineHeight = 2
        let indented = paragraphStyle(c).mutableCopy() as! NSMutableParagraphStyle
        if c.book?.paragraphs != .spaced { indented.firstLineHeadIndent = c.fontSize * (c.book?.indent ?? 1.2) }
        let heading = NSMutableParagraphStyle()
        heading.paragraphSpacingBefore = c.fontSize * 1.4
        heading.paragraphSpacing = c.fontSize * 0.5
        let block = NSMutableParagraphStyle()
        block.lineSpacing = paragraphStyle(c).lineSpacing
        let chapter = chapterParagraphStyle(c)
        let scene = NSMutableParagraphStyle()
        scene.alignment = .center
        scene.paragraphSpacingBefore = c.fontSize * 0.9
        scene.paragraphSpacing = c.fontSize * 0.9
        /// Whether the line just above is text: `---` under it is a heading underline.
        func followsText(_ location: Int) -> Bool {
            guard location > 0 else { return false }
            let previous = ns.paragraphRange(for: NSRange(location: location - 1, length: 0))
            return !ns.substring(with: previous).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        /// The nearest non-blank paragraph before `location`, if it is prose.
        func followsProse(_ location: Int) -> Bool {
            var cursor = location
            while cursor > 0 {
                let previous = ns.paragraphRange(for: NSRange(location: cursor - 1, length: 0))
                let text = ns.substring(with: previous).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { return isProse(text) }
                cursor = previous.location
            }
            return false
        }
        ns.enumerateSubstrings(in: ns.paragraphRange(for: range), options: .byParagraphs) { line, inner, enclosing, _ in
            let target = NSIntersectionRange(enclosing, range)
            guard target.length > 0, let line else { return }
            let style: NSParagraphStyle
            if inner.length == 0 || line.trimmingCharacters(in: .whitespaces).isEmpty { style = blank }
            else if line.hasPrefix("# ") || line.hasPrefix("#\t") { style = chapter }
            else if line.hasPrefix("#") { style = heading }
            else if rule.firstMatch(in: line, range: NSRange(location: 0, length: inner.length)) != nil, !followsText(enclosing.location) { style = scene }
            else if isProse(line) { style = followsProse(enclosing.location) ? indented : paragraphStyle(c) }
            else { style = block }
            storage.addAttribute(.paragraphStyle, value: style, range: target)
        }
    }

    /// A line of running prose, as opposed to a heading, list, quote, table,
    /// code, math, image or HTML.
    static func isProse(_ line: String) -> Bool {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        guard let first = trimmed.first else { return false }
        if "#>|-*+`$![<".contains(first) { return false }
        return trimmed.range(of: #"^\d{1,3}[.)]\s"#, options: .regularExpression) == nil
    }

    /// A chapter heading's paragraph: centred, unless Plain, with room above
    /// for a numeral or rule and a generous gap before the text.
    static func chapterParagraphStyle(_ c: EditorConfig) -> NSParagraphStyle {
        let style = c.book?.headings ?? .plain
        let p = NSMutableParagraphStyle()
        p.alignment = style == .plain ? .natural : .center
        p.paragraphSpacingBefore = c.fontSize * (style == .bigNumeral ? 4.6 : style == .rules ? 2.4 : 1.4)
        p.paragraphSpacing = c.fontSize * (style == .plain ? 0.8 : 2.2)
        return p
    }

    /// A chapter heading's face and letter-spacing in each style.
    static func chapterHeadingFont(_ c: EditorConfig, _ style: ChapterHeadingStyle) -> (font: NSFont, kern: CGFloat) {
        let body = c.font.font(size: c.fontSize)
        switch style {
        case .classic: return (body.withSize(c.fontSize * 1.6), 0.2)
        case .smallCaps: return (body.withSize(c.fontSize * 1.3).smallCaps, 1.4)
        case .uppercase: return (body.withSize(c.fontSize * 1.3).allSmallCaps, 2.6)
        case .bigNumeral, .rules: return (body.withSize(c.fontSize * 1.1).smallCaps, 1.6)
        case .plain: return (headingFont(c, level: 1), 0)
        }
    }

    /// Each chapter's opening: its first words in small capitals, and the
    /// first letter folded away where a drop cap is drawn in its place.
    static func styleOpenings(_ storage: NSTextStorage, range: NSRange, config c: EditorConfig) {
        guard let design = c.book, design.dropCaps || design.smallCapsOpening else { return }
        let ns = storage.string as NSString
        for chapter in BookChapter.scan(storage.string) {
            guard let opening = chapter.opening, NSIntersectionRange(opening, range).length > 0 else { continue }
            if design.smallCapsOpening, let words = chapter.openingWords(in: ns) {
                storage.enumerateAttribute(.font, in: words) { value, r, _ in
                    if let font = value as? NSFont { storage.addAttribute(.font, value: font.smallCaps, range: r) }
                }
                storage.addAttribute(.kern, value: c.fontSize * 0.03, range: words)
            }
            if design.dropCaps, let initial = chapter.initial(in: ns) {
                storage.addAttributes([.font: c.font.font(size: 1), .foregroundColor: NSColor.clear], range: initial)
            }
        }
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
        if c.book != nil { styleBook(storage, range: range, config: c) }
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
        var comments: [NSRange] = []
        each(comment) { m in
            guard !inLiteral(m.range) else { return }
            comments.append(m.range)
            storage.addAttributes([.foregroundColor: c.theme.quaternary, .font: base.adding(.italic)], range: NSIntersectionRange(m.range, range))
        }
        literal += comments
        func inCode(_ r: NSRange) -> Bool { inLiteral(r) }
        // CriticMarkup claims its braces' contents from strikethrough and
        // highlight: `{~~a~>b~~}` is a substitution, not struck text.
        var critics: [NSRange] = []
        for pattern in critic { each(pattern) { m in if !inCode(m.range) { critics.append(m.range) } } }
        func inCritic(_ r: NSRange) -> Bool { critics.contains { NSIntersectionRange($0, r).length > 0 } }

        each(heading) { m in
            guard !inCode(m.range) else { return }
            let level = m.range(at: 1).length
            storage.addAttribute(.font, value: headingFont(c, level: level), range: m.range)
            storage.addAttribute(.foregroundColor, value: c.theme.label, range: m.range(at: 3))
            // The reader should see the heading before its syntax.
            storage.addAttribute(.foregroundColor, value: c.theme.quaternary, range: m.range(at: 1))
            storage.addAttribute(.font, value: c.font.font(size: c.fontSize * 0.96), range: m.range(at: 1))
            if let design = c.book, level == 1 {
                let chapter = chapterHeadingFont(c, design.headings)
                storage.addAttributes([.font: chapter.font, .kern: chapter.kern], range: m.range(at: 3))
            }
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
            guard !inCode(m.range), !inCritic(m.range) else { return }
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: m.range(at: 2))
            color(c.theme.secondary, m.range(at: 2))
            color(syntax, m.range(at: 1))
            color(syntax, NSRange(location: m.range.upperBound - 2, length: 2))
        }
        each(highlight) { m in
            guard !inCode(m.range), !inCritic(m.range) else { return }
            storage.addAttribute(.backgroundColor, value: c.theme.accent.withAlphaComponent(0.22), range: m.range(at: 2))
            color(syntax, m.range(at: 1))
            color(syntax, NSRange(location: m.range.upperBound - 2, length: 2))
        }
        styleCritic(storage, critics: critics, range: range, config: c)
        each(admonition) { m in
            guard !inCode(m.range) else { return }
            color(syntax, m.range(at: 1))
            storage.addAttributes([.foregroundColor: c.theme.accent, .font: base.adding(.bold)], range: m.range(at: 2))
            if m.range(at: 3).location != NSNotFound {
                storage.addAttributes([.foregroundColor: c.theme.label, .font: base.adding(.bold)], range: m.range(at: 3))
            }
        }
        each(PandocSyntax.citation) { m in
            guard !inCode(m.range) else { return }
            color(c.theme.tertiary, m.range)
        }
        each(PandocSyntax.label) { m in
            guard !inCode(m.range) else { return }
            color(c.theme.quaternary, m.range)
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
        // Before code and math take their faces, which openings leave alone.
        if c.book != nil { styleOpenings(storage, range: range, config: c) }
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

    /// Suggested edits read as tracked changes: insertions underlined in
    /// green, deletions struck in red, comments quiet; the braces recede.
    static func styleCritic(_ storage: NSTextStorage, critics: [NSRange], range: NSRange, config c: EditorConfig) {
        let text = storage.string, ns = text as NSString
        let syntax = syntaxColor(c)
        let base = c.font.font(size: c.fontSize)
        let inserted: [NSAttributedString.Key: Any] = [.underlineStyle: NSUnderlineStyle.single.rawValue, .underlineColor: NSColor.systemGreen]
        let deleted: [NSAttributedString.Key: Any] = [.strikethroughStyle: NSUnderlineStyle.single.rawValue, .strikethroughColor: NSColor.systemRed,
                                                      .foregroundColor: c.theme.tertiary]
        for r in critics {
            guard let m = critic.lazy.compactMap({ $0.firstMatch(in: text, options: .anchored, range: r) }).first else { continue }
            let open = NSRange(location: r.location, length: 3), close = NSRange(location: r.upperBound - 3, length: 3)
            let body = m.range(at: 1)
            switch ns.substring(with: NSRange(location: r.location + 1, length: 2)) {
            case "++": storage.addAttributes(inserted, range: body)
            case "--": storage.addAttributes(deleted, range: body)
            case "~~":
                storage.addAttributes(deleted, range: body)
                storage.addAttributes(inserted, range: m.range(at: 2))
                storage.addAttribute(.foregroundColor, value: syntax, range: NSRange(location: body.upperBound, length: 2))
            case "==": storage.addAttribute(.backgroundColor, value: c.theme.accent.withAlphaComponent(0.22), range: body)
            default: storage.addAttributes([.foregroundColor: c.theme.tertiary, .font: base.adding(.italic)], range: body)
            }
            storage.addAttribute(.foregroundColor, value: syntax, range: open)
            storage.addAttribute(.foregroundColor, value: syntax, range: close)
        }
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
        // A book prints its metadata as the title page and the rest, so the
        // block folds away; Source still shows it.
        if c.book != nil {
            let folded = NSMutableParagraphStyle()
            folded.minimumLineHeight = 0.01
            folded.maximumLineHeight = 0.01
            storage.addAttributes([.font: c.font.font(size: 0.01), .foregroundColor: NSColor.clear, .paragraphStyle: folded], range: fm)
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
