// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import TersoCore

/// What Mixed draws in place of block syntax and cross-references.
struct MixedDecorations {
    var glyphs: [RenderedMath] = []
    var quoteBars: [QuoteBar] = []
}

/// Obsidian-style drawing for Mixed: bullets, task checkboxes, quote bars,
/// rules, numbered cross-references and tables. Like math, each one is a
/// display glyph over unchanged source, shown as source on the editing line.
@MainActor enum MixedPresentation {
    static let quoteIndent: CGFloat = 14
    static let bulletOrTask = MarkdownStyler.re(#"^[ \t]*(?:([-*+])|\d{1,3}[.)])[ \t]+(\[[ xX]\](?=[ \t]|$))?"#)
    static let quoteMarker = MarkdownStyler.re(#"^[ \t]*((?:>[ \t]?)+)"#)
    private static var cache: [String: NSImage] = [:]

    static func layout(in text: String, selection: NSRange, config: EditorConfig, elements: Set<MixedElement>, width: Double) -> MixedDecorations {
        var result = MixedDecorations()
        let drawing: Set<MixedElement> = [.blocks, .admonitions, .tables, .footnotes, .citations]
        guard !config.latex, !elements.isDisjoint(with: drawing) else { return result }
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)
        let regions = ScientificSyntax(DocumentSnapshot(revision: DocumentRevision(0), text: text)).regions
        let protected = regions.filter { [.code, .displayMath, .inlineMath].contains($0.kind) }.map(\.range.nsRange)
            + [MarkdownSyntax.frontMatter(in: text)].compactMap { $0 }
            + MarkdownStyler.fence.matches(in: text, range: all).map(\.range)
            + MarkdownStyler.comment.matches(in: text, range: all).map(\.range)
        func clear(_ r: NSRange) -> Bool { !protected.contains { NSIntersectionRange($0, r).length > 0 } }
        // A table may hold code spans and inline math in its cells; only
        // blocks around it keep it literal.
        let blocks = [MarkdownSyntax.frontMatter(in: text)].compactMap { $0 }
            + MarkdownStyler.fence.matches(in: text, range: all).map(\.range)
            + MarkdownStyler.comment.matches(in: text, range: all).map(\.range)
            + regions.filter { $0.kind == .displayMath }.map(\.range.nsRange)
        func revealed(_ r: NSRange) -> Bool { MathPresentation.showsSource(r, selection: selection, text: text) }
        func each(_ pattern: NSRegularExpression, _ body: (NSTextCheckingResult) -> Void) {
            pattern.enumerateMatches(in: text, range: all) { m, _, _ in if let m { body(m) } }
        }
        let font = config.font.font(size: config.fontSize)
        let style = "\(config.font.rawValue)|\(config.fontSize)|\(config.theme.rawValue)|\(NSApp?.effectiveAppearance.name.rawValue ?? "")"

        if elements.contains(.tables) {
            each(MarkdownStyler.table) { m in
                var r = m.range
                while r.length > 0, [10, 13].contains(ns.character(at: r.upperBound - 1)) { r.length -= 1 }
                let source = ns.substring(with: r)
                guard !blocks.contains(where: { NSIntersectionRange($0, r).length > 0 }), !revealed(r),
                      let table = MarkdownTable(source) else { return }
                let key = "table|\(style)|\(width)|\(source)"
                result.glyphs.append(RenderedMath(range: r, image: image(key) { tableImage(table, config: config, width: width) }))
            }
        }
        if elements.contains(.blocks) {
            each(MarkdownStyler.rule) { m in
                // `---` under a line of text is a heading underline, not a rule.
                let previous = m.range.location == 0 ? "" : ns.substring(with: ns.lineRange(for: NSRange(location: m.range.location - 1, length: 0)))
                guard previous.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, clear(m.range), !revealed(m.range) else { return }
                let rule = config.book.map { sceneBreak($0.sceneBreak, font: font, config: config, width: width) }
                    ?? image("rule|\(style)|\(width)") { ruleImage(font: font, color: config.theme.separator, width: width - 12) }
                result.glyphs.append(RenderedMath(range: m.range, image: rule, reservesHeight: false))
            }
            let rules = result.glyphs.filter { !$0.reservesHeight }.map(\.range)
            each(bulletOrTask) { m in
                guard clear(m.range), !revealed(m.range), !rules.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) else { return }
                let bullet = m.range(at: 1), box = m.range(at: 2)
                if box.location != NSNotFound {
                    let checked = ns.substring(with: box).lowercased() == "[x]"
                    let start = bullet.location != NSNotFound ? bullet.location : box.location
                    let glyph = image("box|\(checked)|\(style)") { checkboxImage(font: font, checked: checked, theme: config.theme) }
                    result.glyphs.append(RenderedMath(range: NSRange(location: start, length: box.upperBound - start),
                                                      image: glyph, reservesHeight: false, toggle: box))
                } else if bullet.location != NSNotFound {
                    // The bullet takes the place of the dash, at the dash's width.
                    let glyph = image("bullet|\(style)") { textImage("•", font: font, color: config.theme.secondary, width: NSAttributedString(string: "-", attributes: [.font: font]).size().width) }
                    result.glyphs.append(RenderedMath(range: bullet, image: glyph, reservesHeight: false))
                }
            }
            each(quoteMarker) { m in
                guard clear(m.range), !revealed(m.range) else { return }
                let marker = m.range(at: 1)
                let depth = ns.substring(with: marker).filter { $0 == ">" }.count
                let spacer = image("quote|\(depth)") { NSImage(size: NSSize(width: CGFloat(depth) * quoteIndent, height: 1)) }
                result.glyphs.append(RenderedMath(range: NSRange(location: m.range.location, length: marker.upperBound - m.range.location),
                                                  image: spacer, reservesHeight: false))
                var line = ns.lineRange(for: m.range)
                while line.length > 0, [10, 13].contains(ns.character(at: line.upperBound - 1)) { line.length -= 1 }
                result.quoteBars.append(QuoteBar(range: line, depth: depth))
            }
        }
        /// Draws each indented line's indent below `header` at `width`, except
        /// on the line being edited, which shows its source.
        func indents(below header: NSRange, through body: NSRange, width: CGFloat) {
            let spacer = image("indent|\(width)") { NSImage(size: NSSize(width: width, height: 1)) }
            var location = ns.lineRange(for: header).upperBound
            while location < body.upperBound {
                let line = ns.lineRange(for: NSRange(location: location, length: 0))
                let indent = NSRange(location: line.location, length: ns.character(at: line.location) == 9 ? 1 : 4)
                if indent.upperBound <= body.upperBound, !revealed(indent),
                   ns.substring(with: indent).allSatisfy({ $0 == " " || $0 == "\t" }) {
                    result.glyphs.append(RenderedMath(range: indent, image: spacer, reservesHeight: false))
                }
                location = line.upperBound
            }
        }
        if elements.contains(.admonitions) {
            // Drawn whole, as the preview shows it, until the caret is on any
            // of its lines; then the whole block is source.
            each(MarkdownStyler.admonition) { m in
                let block = NSRange(location: m.range.location, length: indentedBody(after: m.range, in: ns).upperBound - m.range.location)
                // Like a table, it may hold math and code spans; only a block
                // around its opening line keeps it literal.
                guard clear(m.range), !revealed(block) else { return }
                let source = ns.substring(with: block)
                let key = "admonition|\(style)|\(width)|\(source)"
                result.glyphs.append(RenderedMath(range: block, image: image(key) {
                    admonitionImage(Admonition(m, in: ns), config: config, width: width)
                }))
            }
        }
        if elements.contains(.footnotes) {
            // References read as raised numbers, counted as the preview counts
            // them; a definition's `[^id]:` reads as its number, and its
            // indented lines hang beside it. References without a note stay as written.
            let numbers = footnoteNumbers(in: text, protected: protected)
            each(MarkdownStyler.footnote) { m in
                guard let number = numbers[footnoteID(m, in: ns)], clear(m.range) else { return }
                let definition = m.range(at: 1).length > 0
                if !definition {
                    guard !revealed(m.range) else { return }
                    let glyph = image("fnref|\(number)|\(style)") { superscriptImage("\(number)", font: font, color: config.theme.accent) }
                    result.glyphs.append(RenderedMath(range: m.range, image: glyph, reservesHeight: false))
                    return
                }
                guard m.range.location == ns.lineRange(for: m.range).location else { return }
                // The marker takes the space after it, so the note's text starts where its continuation does.
                var marker = m.range
                if marker.upperBound < ns.length, ns.character(at: marker.upperBound) == 32 { marker.length += 1 }
                let glyph = image("fn|\(number)|\(style)") { textImage("\(number).\u{00A0}", font: font, color: config.theme.tertiary) }
                if !revealed(m.range) {
                    result.glyphs.append(RenderedMath(range: marker, image: glyph, reservesHeight: false))
                }
                indents(below: m.range, through: indentedBody(after: m.range, in: ns), width: glyph.size.width)
            }
        }
        if elements.contains(.citations) {
            let numbers = PandocSyntax.numbers(in: text)
            if !numbers.isEmpty {
                each(PandocSyntax.citation) { m in
                    let key = PandocSyntax.target(of: m, in: ns)
                    guard let number = numbers[key], clear(m.range), !revealed(m.range) else { return }
                    let label = PandocSyntax.display(key: ns.substring(with: m.range(at: 2)), number: number)
                    let glyph = image("ref|\(label)|\(style)") { textImage(label, font: font, color: config.theme.accent) }
                    result.glyphs.append(RenderedMath(range: m.range, image: glyph, reservesHeight: false))
                }
            }
        }
        result.glyphs.sort { $0.range.location < $1.range.location }
        return result
    }

    /// The indented lines after an admonition's opening line or a footnote's
    /// definition, across blank lines, ending before trailing blanks.
    nonisolated static func indentedBody(after header: NSRange, in ns: NSString) -> NSRange {
        var end = header.upperBound, location = ns.lineRange(for: header).upperBound
        while location < ns.length {
            let line = ns.lineRange(for: NSRange(location: location, length: 0))
            let content = ns.substring(with: line).trimmingCharacters(in: .newlines)
            if content.hasPrefix("    ") || content.hasPrefix("\t") {
                end = line.location + (content as NSString).length
            } else if !content.allSatisfy({ $0 == " " || $0 == "\t" }) {
                break
            }
            location = line.upperBound
        }
        return NSRange(location: header.upperBound, length: end - header.upperBound)
    }

    /// A Python-Markdown admonition: its type, title, folding and body paragraphs.
    struct Admonition {
        var kind: String
        var title: String
        var fold: String
        var paragraphs: [String]

        init(_ m: NSTextCheckingResult, in ns: NSString) {
            fold = ns.substring(with: m.range(at: 1))
            kind = ns.substring(with: m.range(at: 2)).lowercased().split(whereSeparator: \.isWhitespace).first.map(String.init) ?? "note"
            title = m.range(at: 3).location != NSNotFound ? ns.substring(with: m.range(at: 3)) : kind.prefix(1).uppercased() + kind.dropFirst()
            let body = ns.substring(with: MixedPresentation.indentedBody(after: m.range, in: ns))
            let lines = body.components(separatedBy: .newlines).map { line in
                line.hasPrefix("\t") ? String(line.dropFirst()) : line.hasPrefix("    ") ? String(line.dropFirst(4)) : line
            }
            paragraphs = lines.split { $0.trimmingCharacters(in: .whitespaces).isEmpty }
                .map { $0.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ") }
        }

        /// The colour of each family of types, as in the preview.
        var tone: NSColor {
            switch kind {
            case "tip", "hint", "success", "check", "done", "important": .systemGreen
            case "question", "help", "faq": .systemTeal
            case "warning", "caution", "attention": .systemOrange
            case "danger", "error", "failure", "fail", "missing", "bug": .systemRed
            case "example": .systemPurple
            case "quote", "cite": .systemGray
            default: .systemBlue
            }
        }
    }

    /// A tinted box with a bar in the type's colour, its title, and its body
    /// with inline styling. A folded `???` shows only its title.
    static func admonitionImage(_ note: Admonition, config: EditorConfig, width: Double) -> NSImage {
        let font = config.font.font(size: config.fontSize)
        let mono = NSFont.monospacedSystemFont(ofSize: config.fontSize * MarkdownStyler.codeScale, weight: .regular)
        let pad = NSSize(width: 14, height: 9), bar: CGFloat = 4
        let size = NSSize(width: max(120, width - 12), height: 0)
        let textWidth = size.width - bar - pad.width * 2
        let marker = note.fold == "!!!" ? "" : note.fold == "???+" ? "▾ " : "▸ "
        let title = NSAttributedString(string: marker + note.title, attributes: [.font: font.adding(.bold), .foregroundColor: note.tone])
        let paragraphs = note.fold == "???" ? [] : note.paragraphs.map {
            cell($0, font: font, mono: mono, color: config.theme.bodyInk, alignment: .natural)
        }
        func height(_ text: NSAttributedString) -> CGFloat {
            ceil(text.boundingRect(with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
                                   options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
        }
        let gap = config.fontSize * 0.6
        let blocks = [title] + paragraphs
        let total = blocks.map(height).reduce(0, +) + gap * CGFloat(blocks.count - 1) + pad.height * 2
        let box = NSSize(width: size.width, height: ceil(total))
        return NSImage(size: box, flipped: true) { _ in
            let frame = NSRect(origin: .zero, size: box)
            let path = NSBezierPath(roundedRect: frame, xRadius: 4, yRadius: 4)
            note.tone.withAlphaComponent(0.09).setFill(); path.fill()
            NSGraphicsContext.saveGraphicsState(); path.addClip()
            note.tone.setFill(); NSRect(x: 0, y: 0, width: bar, height: box.height).fill()
            NSGraphicsContext.restoreGraphicsState()
            var y = pad.height
            for text in blocks {
                let h = height(text)
                text.draw(with: NSRect(x: bar + pad.width, y: y, width: textWidth, height: h), options: [.usesLineFragmentOrigin, .usesFontLeading])
                y += h + gap
            }
            return true
        }
    }

    /// The text between `[^` and `]` of a footnote match.
    static func footnoteID(_ m: NSTextCheckingResult, in ns: NSString) -> String {
        ns.substring(with: NSRange(location: m.range.location + 2, length: m.range.length - 3 - m.range(at: 1).length))
    }

    /// Footnote numbers by first reference, as the preview numbers them; only
    /// notes that have a definition count. Notes never referenced follow.
    static func footnoteNumbers(in text: String, protected: [NSRange]) -> [String: Int] {
        let ns = text as NSString
        let matches = MarkdownStyler.footnote.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .filter { m in !protected.contains { NSIntersectionRange($0, m.range).length > 0 } }
        let defined = Set(matches.filter { $0.range(at: 1).length > 0 && $0.range.location == ns.lineRange(for: $0.range).location }
            .map { footnoteID($0, in: ns) })
        var numbers: [String: Int] = [:]
        for m in matches.sorted(by: { ($0.range(at: 1).length, $0.range.location) < ($1.range(at: 1).length, $1.range.location) }) {
            let id = footnoteID(m, in: ns)
            if defined.contains(id), numbers[id] == nil { numbers[id] = numbers.count + 1 }
        }
        return numbers
    }

    private static func image(_ key: String, make: () -> NSImage) -> NSImage {
        if let cached = cache[key] { return cached }
        if cache.count >= 512 { cache.removeAll(keepingCapacity: true) }
        let made = make()
        cache[key] = made
        return made
    }

    // MARK: Drawing
    //
    // A glyph image hangs from the line: its bottom sits 4pt below the
    // baseline (see MathLayoutManager), so the baseline is at `height - 4`.

    static func textImage(_ string: String, font: NSFont, color: NSColor, width: CGFloat? = nil, inset: CGFloat = 0) -> NSImage {
        let attributed = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
        let natural = attributed.size().width
        let size = NSSize(width: ceil(max(width ?? natural, natural)) + inset, height: ceil(font.ascender) + 4)
        return NSImage(size: size, flipped: true) { _ in
            attributed.draw(at: NSPoint(x: inset + (size.width - inset - natural) / 2, y: size.height - 4 - font.ascender))
            return true
        }
    }

    /// A footnote number set small and raised, on the line's baseline grid.
    static func superscriptImage(_ string: String, font: NSFont, color: NSColor) -> NSImage {
        let small = font.withSize(font.pointSize * 0.72)
        let attributed = NSAttributedString(string: string, attributes: [.font: small, .foregroundColor: color])
        let size = NSSize(width: ceil(attributed.size().width) + 1, height: ceil(font.ascender) + 4)
        return NSImage(size: size, flipped: true) { _ in
            attributed.draw(at: NSPoint(x: 0.5, y: size.height - 4 - small.ascender - font.pointSize * 0.33))
            return true
        }
    }

    static func checkboxImage(font: NSFont, checked: Bool, theme: EditorTheme) -> NSImage {
        let side = round(font.xHeight * 1.7)
        let size = NSSize(width: side + 6, height: ceil(font.ascender) + 4)
        return NSImage(size: size, flipped: true) { _ in
            let baseline = size.height - 4
            let box = NSRect(x: 1, y: baseline - side + 1, width: side, height: side)
            let path = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
            if checked {
                theme.accent.setFill(); path.fill()
                let tick = NSBezierPath()
                tick.move(to: NSPoint(x: box.minX + side * 0.24, y: box.minY + side * 0.52))
                tick.line(to: NSPoint(x: box.minX + side * 0.43, y: box.minY + side * 0.72))
                tick.line(to: NSPoint(x: box.minX + side * 0.78, y: box.minY + side * 0.3))
                tick.lineWidth = 1.6; tick.lineCapStyle = .round; tick.lineJoinStyle = .round
                NSColor.white.setStroke(); tick.stroke()
            } else {
                theme.tertiary.setStroke(); path.lineWidth = 1.2; path.stroke()
            }
            return true
        }
    }

    /// A scene break in Manutius: an ornament, a short rule or white space,
    /// centred by its paragraph.
    static func sceneBreak(_ kind: SceneBreak, font: NSFont, config: EditorConfig, width: Double) -> NSImage {
        let style = "\(kind.rawValue)|\(config.font.rawValue)|\(config.fontSize)|\(config.theme.rawValue)|\(width)"
        return image("scene|\(style)") {
            switch kind {
            case .rule: ruleImage(font: font, color: config.theme.secondary, width: (width / 5).rounded())
            case .space: NSImage(size: NSSize(width: 1, height: ceil(font.ascender) + 4))
            default: textImage(kind.ornament ?? "", font: font, color: config.theme.secondary)
            }
        }
    }

    static func ruleImage(font: NSFont, color: NSColor, width: Double) -> NSImage {
        let size = NSSize(width: max(40, width), height: ceil(font.ascender) + 4)
        return NSImage(size: size, flipped: true) { _ in
            color.setFill()
            NSRect(x: 0, y: round(size.height - 4 - font.xHeight / 2), width: size.width, height: 1).fill()
            return true
        }
    }

    static func tableImage(_ table: MarkdownTable, config: EditorConfig, width: Double) -> NSImage {
        let font = config.font.font(size: config.fontSize * 0.92)
        let mono = NSFont.monospacedSystemFont(ofSize: config.fontSize * 0.85, weight: .regular)
        let pad = NSSize(width: 10, height: 5)
        let rows = [table.header] + table.rows
        let columns = table.alignments.count
        let cells: [[NSAttributedString]] = rows.enumerated().map { index, row in
            (0..<columns).map { column in
                cell(column < row.count ? row[column] : "", font: index == 0 ? font.adding(.bold) : font, mono: mono,
                     color: config.theme.label, alignment: table.alignments[column])
            }
        }
        var widths = (0..<columns).map { column in
            max(36, cells.map { ceil($0[column].size().width) }.max() ?? 0) + pad.width * 2
        }
        let available = max(120, width - 12)
        let natural = widths.reduce(0, +)
        if natural > available { widths = widths.map { max(36, floor($0 * available / natural)) } }
        let heights = cells.map { row in
            row.enumerated().map { column, text in
                ceil(text.boundingRect(with: NSSize(width: widths[column] - pad.width * 2, height: .greatestFiniteMagnitude),
                                       options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
            }.max()! + pad.height * 2
        }
        let size = NSSize(width: widths.reduce(0, +) + 1, height: heights.reduce(0, +) + 1)
        let separator = config.theme.separator
        let header = config.theme.label.withAlphaComponent(0.05)
        return NSImage(size: size, flipped: true) { _ in
            header.setFill()
            NSRect(x: 0.5, y: 0.5, width: size.width - 1, height: heights[0]).fill()
            var y: CGFloat = 0.5
            for (rowIndex, row) in cells.enumerated() {
                var x: CGFloat = 0.5
                for (column, text) in row.enumerated() {
                    let rect = NSRect(x: x + pad.width, y: y + pad.height, width: widths[column] - pad.width * 2, height: heights[rowIndex] - pad.height * 2)
                    text.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading])
                    x += widths[column]
                }
                y += heights[rowIndex]
            }
            let grid = NSBezierPath()
            grid.appendRect(NSRect(x: 0.5, y: 0.5, width: size.width - 1, height: size.height - 1))
            var x: CGFloat = 0.5
            for w in widths.dropLast() { x += w; grid.move(to: NSPoint(x: x, y: 0.5)); grid.line(to: NSPoint(x: x, y: size.height - 0.5)) }
            y = 0.5
            for h in heights.dropLast() { y += h; grid.move(to: NSPoint(x: 0.5, y: y)); grid.line(to: NSPoint(x: size.width - 0.5, y: y)) }
            grid.lineWidth = 1
            separator.setStroke(); grid.stroke()
            return true
        }
    }

    /// A cell's inline Markdown — strong, emphasis, code, strikethrough — as styled text.
    private static func cell(_ source: String, font: NSFont, mono: NSFont, color: NSColor, alignment: NSTextAlignment) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        guard let parsed = try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return NSAttributedString(string: source, attributes: base)
        }
        let result = NSMutableAttributedString()
        for run in parsed.runs {
            var attributes = base
            var runFont = font
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) { runFont = mono }
                if intent.contains(.stronglyEmphasized) { runFont = runFont.adding(.bold) }
                if intent.contains(.emphasized) { runFont = runFont.adding(.italic) }
                if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            }
            attributes[.font] = runFont
            result.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
        }
        return result
    }
}

/// A GitHub-style pipe table: a header row, a delimiter row that sets each
/// column's alignment, then body rows.
struct MarkdownTable: Equatable {
    var header: [String]
    var alignments: [NSTextAlignment]
    var rows: [[String]]

    init?(_ source: String) {
        let lines = source.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.count >= 2 else { return nil }
        let delimiter = Self.cells(lines[1])
        guard !delimiter.isEmpty, delimiter.allSatisfy({ $0.range(of: #"^:?-+:?$"#, options: .regularExpression) != nil }) else { return nil }
        header = Self.cells(lines[0])
        alignments = delimiter.map { d in
            d.hasPrefix(":") && d.hasSuffix(":") ? .center : d.hasSuffix(":") ? .right : .left
        }
        rows = lines.dropFirst(2).map(Self.cells)
    }

    /// Splits on pipes that are neither escaped nor inside a code span.
    static func cells(_ line: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var inCode = false
        var escaped = false
        for char in line.trimmingCharacters(in: .whitespaces) {
            if escaped { current.append(char); escaped = false; continue }
            switch char {
            case "\\": escaped = true; current.append(char)
            case "`": inCode.toggle(); current.append(char)
            case "|" where !inCode: cells.append(current); current = ""
            default: current.append(char)
            }
        }
        cells.append(current)
        if cells.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeFirst() }
        if cells.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeLast() }
        return cells.map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\\|", with: "|") }
    }
}
