// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import TersoCore

/// Mixed for TeX: list items as bullets and numbers, tables as tables, `\ref`s
/// as the numbers they print, citations as compact labels and footnotes as raised numbers.
/// Like Markdown's, each is a display glyph over unchanged source, shown as
/// source on the editing line, and literal in verbatim, comments and math.
@MainActor enum LaTeXMixedPresentation {
    /// `\begin{itemize}`, `\end{enumerate}`… or an `\item[label]` with the blanks after it.
    static let listToken = MarkdownStyler.re(#"\\(begin|end)[ \t]*\{(itemize|enumerate|description)\}(?:\[[^\]\n]*\])?|\\item\b(?:\[([^\]\n]*)\])?[ \t]*"#, [])
    static let reference = MarkdownStyler.re(#"\\(ref|eqref|autoref|Autoref|cref|Cref)\*?\{([^{}\s]+)\}"#, [])
    /// natbib and biblatex citations, with up to two optional notes.
    static let citation = MarkdownStyler.re(#"\\(?:[Cc]ite[pt]?|citealp|citealt|[Pp]arencite|[Tt]extcite|[Aa]utocite)\*?(?:[ \t]*\[([^\]\n]*)\])?(?:[ \t]*\[([^\]\n]*)\])?[ \t]*\{([^{}]*)\}"#, [])
    /// Hidden with the other markers: a label prints nothing.
    static let label = MarkdownStyler.re(#"\\label[ \t]*\{[^{}\n]*\}"#, [])
    static let footnote = MarkdownStyler.re(#"\\footnote(?![A-Za-z])[ \t]*(?:\[[^\]\n]*\])?[ \t]*\{"#, [])

    /// The elements beyond math, headings and emphasis a TeX document uses.
    static func elements(in text: String) -> [MixedElement] {
        let all = NSRange(location: 0, length: (text as NSString).length)
        func uses(_ pattern: NSRegularExpression) -> Bool { pattern.firstMatch(in: text, range: all) != nil }
        return [(MixedElement.blocks, uses(listToken)), (.tables, MixedPresentation.usesLaTeXTables(text)),
                (.footnotes, uses(footnote)), (.citations, uses(reference) || uses(citation))]
            .filter(\.1).map(\.0)
    }

    static func layout(in text: String, selection: NSRange, config: EditorConfig, elements: Set<MixedElement>, width: Double) -> MixedDecorations {
        var result = MixedDecorations()
        guard !elements.isDisjoint(with: [.blocks, .tables, .footnotes, .citations]) else { return result }
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)
        let regions = ScientificSyntax(DocumentSnapshot(revision: DocumentRevision(0), text: text)).regions
        // Counting reads labels in math; drawing never touches math or the preamble.
        let quiet = regions.filter { [.code, .comment].contains($0.kind) }.map(\.range.nsRange)
            + LaTeXSyntax.literalEnvironments(in: text).map(\.range)
        let protected = quiet + regions.filter { [.inlineMath, .displayMath].contains($0.kind) }.map(\.range.nsRange)
            + [LaTeXSyntax.preamble(in: text)].compactMap { $0 }
        func clear(_ r: NSRange) -> Bool { !protected.contains { NSIntersectionRange($0, r).length > 0 } }
        func revealed(_ r: NSRange) -> Bool { MathPresentation.showsSource(r, selection: selection, text: text) }
        func each(_ pattern: NSRegularExpression, _ body: (NSTextCheckingResult) -> Void) {
            pattern.enumerateMatches(in: text, range: all) { m, _, _ in if let m { body(m) } }
        }
        let font = config.font.font(size: config.fontSize)
        let style = "\(config.font.rawValue)|\(config.fontSize)|\(config.theme.rawValue)|\(NSApp?.effectiveAppearance.name.rawValue ?? "")"
        func image(_ key: String, _ make: () -> NSImage) -> NSImage { MixedPresentation.image("tex|" + key, make: make) }

        // Footnotes first: a reference or citation inside one is drawn by it.
        var notes: [NSRange] = []
        if elements.contains(.footnotes) {
            let chapters = LaTeXSyntax.section.matches(in: text, range: all)
                .filter { ns.substring(with: $0.range(at: 1)) == "chapter" && clear($0.range) }.map(\.range.location)
            var number = 0, chapter = 0
            each(footnote) { m in
                guard clear(NSRange(location: m.range.location, length: m.range.length - 1)),
                      let end = groupEnd(m.range.upperBound - 1, in: ns) else { return }
                // Book classes count footnotes per chapter.
                let at = chapters.filter { $0 < m.range.location }.count
                if at != chapter { chapter = at; number = 0 }
                number += 1
                let r = NSRange(location: m.range.location, length: end - m.range.location)
                guard !notes.contains(where: { NSIntersectionRange($0, r).length > 0 }) else { return }
                notes.append(r)
                guard !revealed(r) else { return }
                let glyph = image("fn|\(number)|\(style)") { MixedPresentation.superscriptImage("\(number)", font: font, color: config.theme.accent) }
                result.glyphs.append(RenderedMath(range: r, image: glyph, reservesHeight: false))
            }
        }
        func drawable(_ r: NSRange) -> Bool { clear(r) && !notes.contains { NSIntersectionRange($0, r).length > 0 } }

        if elements.contains(.blocks) {
            var lists: [(kind: String, count: Int)] = []
            let hidden = image("hide") { NSImage(size: NSSize(width: 0, height: 1)) }
            each(listToken) { m in
                guard drawable(m.range) else { return }
                if m.range(at: 1).location != NSNotFound {
                    let kind = ns.substring(with: m.range(at: 2))
                    if ns.substring(with: m.range(at: 1)) == "begin" {
                        lists.append((kind, 0))
                    } else if let index = lists.lastIndex(where: { $0.kind == kind }) {
                        lists.removeSubrange(index...)
                    }
                    // A line holding only `\begin{…}` or `\end{…}` folds away, newline and all.
                    let line = ns.lineRange(for: m.range)
                    let content = ns.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard content == ns.substring(with: m.range), !revealed(line) else { return }
                    result.glyphs.append(RenderedMath(range: line, image: hidden, reservesHeight: false))
                    return
                }
                guard let list = lists.last else { return }
                var label: String, bold = false
                if m.range(at: 3).location != NSNotFound {
                    // `\item[Term]`: a description's term in bold; elsewhere the label as given.
                    label = ns.substring(with: m.range(at: 3))
                    guard !label.isEmpty, !label.contains(where: { "\\{}$%".contains($0) }) else { return }
                    bold = list.kind == "description"
                } else if list.kind == "enumerate" {
                    lists[lists.count - 1].count += 1
                    label = enumerateLabel(lists[lists.count - 1].count, depth: lists.filter { $0.kind == "enumerate" }.count)
                } else if list.kind == "itemize" {
                    label = ["•", "–", "∗", "·"][min(4, lists.filter { $0.kind == "itemize" }.count) - 1]
                } else {
                    return
                }
                guard !revealed(m.range) else { return }
                let glyph = image("item|\(label)|\(bold)|\(style)") {
                    MixedPresentation.textImage(label + "\u{00A0}", font: bold ? font.adding(.bold) : font,
                                                color: bold ? config.theme.label : config.theme.secondary)
                }
                result.glyphs.append(RenderedMath(range: m.range, image: glyph, reservesHeight: false))
            }
        }
        if elements.contains(.citations) {
            let labels = labels(in: text, quiet: quiet)
            each(reference) { m in
                guard let target = labels[ns.substring(with: m.range(at: 2))], drawable(m.range), !revealed(m.range) else { return }
                let shown = target.display(ns.substring(with: m.range(at: 1)))
                let glyph = image("ref|\(shown)|\(style)") { MixedPresentation.textImage(shown, font: font, color: config.theme.accent) }
                result.glyphs.append(RenderedMath(range: m.range, image: glyph, reservesHeight: false))
            }
            each(citation) { m in
                guard drawable(m.range), !revealed(m.range) else { return }
                let keys = ns.substring(with: m.range(at: 3)).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                guard !keys.isEmpty else { return }
                // One note is a postnote; with two, the first comes before.
                let extra = [1, 2].map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)).trimmingCharacters(in: .whitespaces) }
                let pre = m.range(at: 2).location == NSNotFound ? "" : extra[0], post = m.range(at: 2).location == NSNotFound ? extra[0] : extra[1]
                let shown = "[" + (pre.isEmpty ? "" : pre + " ") + keys.joined(separator: ", ") + (post.isEmpty ? "" : ", " + post) + "]"
                let glyph = image("cite|\(shown)|\(style)") { MixedPresentation.textImage(shown, font: font, color: config.theme.accent) }
                result.glyphs.append(RenderedMath(range: m.range, image: glyph, reservesHeight: false))
            }
        }
        // Tables are literal environments, so nothing above draws inside one.
        if elements.contains(.tables) {
            result.glyphs += MixedPresentation.latexTables(in: text, selection: selection, config: config, width: width)
        }
        result.glyphs.sort { $0.range.location < $1.range.location }
        return result
    }

    /// LaTeX's default `enumerate` labels: 1. (a) i. A.
    static func enumerateLabel(_ n: Int, depth: Int) -> String {
        switch depth {
        case 1: "\(n)."
        case 2: "(\(alphabetic(n)))"
        case 3: "\(roman(n))."
        default: "\(alphabetic(n).uppercased())."
        }
    }

    nonisolated static func alphabetic(_ n: Int) -> String {
        n >= 1 && n <= 26 ? String(UnicodeScalar(UInt8(96 + n))) : "\(n)"
    }

    nonisolated static func roman(_ n: Int) -> String {
        var n = n, out = ""
        for (value, digits) in [(1000, "m"), (900, "cm"), (500, "d"), (400, "cd"), (100, "c"), (90, "xc"), (50, "l"), (40, "xl"), (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i")] {
            while n >= value { out += digits; n -= value }
        }
        return out
    }

    /// The index after the `}` closing the group opened at `open`, if it closes.
    nonisolated static func groupEnd(_ open: Int, in ns: NSString) -> Int? {
        var i = open + 1, depth = 1
        while i < ns.length, i - open < 8192 {
            switch ns.character(at: i) {
            case 92: i += 1
            case 123: depth += 1
            case 125: depth -= 1; if depth == 0 { return i + 1 }
            default: break
            }
            i += 1
        }
        return nil
    }

    // MARK: Cross-references

    /// What a `\label` names: the number it prints and what kind of thing it numbers.
    struct Target: Equatable {
        enum Kind: Equatable { case equation, figure, table, item, section(String) }
        var number: String
        var kind: Kind

        /// As `\ref`, `\eqref`, hyperref's `\autoref` and cleveref's `\cref` print it.
        func display(_ command: String) -> String {
            let equation = kind == .equation ? "(\(number))" : number
            let name: (auto: String, cref: String) = switch kind {
            case .equation: ("Equation", "eq.")
            case .figure: ("Figure", "fig.")
            case .table: ("Table", "tab.")
            case .item: ("item", "item")
            case .section(let level): (level, ["part", "chapter"].contains(level) ? level : "section")
            }
            func capital(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }
            switch command {
            case "eqref": return "(\(number))"
            case "autoref": return "\(name.auto) \(number)"
            case "Autoref": return "\(capital(name.auto)) \(number)"
            case "cref": return "\(name.cref) \(equation)"
            case "Cref": return "\(capital(name.cref)) \(equation)"
            default: return number
            }
        }
    }

    static let counting = MarkdownStyler.re(#"\\(begin|end)[ \t]*\{([^{}\n]+)\}|\\(part|chapter|section|subsection|subsubsection|paragraph|subparagraph)(\*?)|\\label[ \t]*\{([^{}\n]+)\}|\\(caption|appendix|notag|nonumber)(?![A-Za-z])|\\tag\*?[ \t]*\{([^{}\n]*)\}|\\newtheorem\*?[ \t]*\{([^{}\n]+)\}|\\item(?![A-Za-z])(\[)?|(\\\\)"#, [])

    /// Every `\label` with what it numbers, counted in document order as the
    /// standard classes do. An approximation: `\label` takes the innermost
    /// numbered thing before it in its group (section, equation or align row,
    /// float caption, enumerate item); equations, figures and tables count
    /// within chapters when the document has any; `secnumdepth` is the class
    /// default; `\appendix` letters the top level. Theorem-like environments,
    /// subequations, subfigures, `\setcounter` and custom formats aren't
    /// modelled, so their labels stay unresolved (and are left as source).
    static func labels(in text: String, quiet: [NSRange]) -> [String: Target] {
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)
        let matches = counting.matches(in: text, range: all).filter { m in !quiet.contains { NSIntersectionRange($0, m.range).length > 0 } }
        func group(_ m: NSTextCheckingResult, _ i: Int) -> String? { m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i)) }
        let chapters = matches.contains { group($0, 3) == "chapter" }
        let levels = ["part": -1, "chapter": 0, "section": 1, "subsection": 2, "subsubsection": 3, "paragraph": 4, "subparagraph": 5]
        let depth = chapters ? 2 : 3
        let rows: Set<String> = ["align", "gather", "eqnarray", "flalign", "alignat", "xalignat"]
        let single: Set<String> = ["equation", "multline", "dmath"]
        let floats: [String: Target.Kind] = ["figure": .figure, "figure*": .figure, "wrapfigure": .figure, "table": .table, "table*": .table, "wraptable": .table]
        var theorems: Set<String> = []
        var sections = Array(repeating: 0, count: 7) // part … subparagraph
        var appendix = false
        var equations = 0, figures = 0, tables = 0
        var current: Target?
        var stack: [(name: String, saved: Target?)] = []
        var enumerate: [Int] = [], owns: [String] = []
        var lists: [String] = []
        var row: (labels: [String], tag: String?, notag: Bool)?
        var result: [String: Target] = [:]

        func top(_ n: Int) -> String { appendix ? alphabetic(n).uppercased() : "\(n)" }
        func withinChapter(_ n: Int) -> String { chapters && sections[1] > 0 ? "\(top(sections[1])).\(n)" : "\(n)" }
        func sectionNumber(_ level: Int) -> String {
            if level == -1 { return roman(sections[0]).uppercased() }
            let first = chapters ? 0 : 1
            guard level >= first else { return "" }
            return ([top(sections[first + 1])] + (first..<level).map { "\(sections[$0 + 2])" }).joined(separator: ".")
        }
        func finishRow(starred: Bool) {
            guard let r = row else { return }
            var number = r.tag
            if number == nil, !r.notag, !starred { equations += 1; number = withinChapter(equations) }
            if let number { for key in r.labels { result[key] = Target(number: number, kind: .equation) } }
            row = ([], nil, false)
        }

        for m in matches {
            if let verb = group(m, 1), let name = group(m, 2) {
                let base = name.hasSuffix("*") ? String(name.dropLast()) : name
                if verb == "begin" {
                    stack.append((name, current))
                    if ["itemize", "enumerate", "description"].contains(name) { lists.append(name) }
                    if name == "enumerate" { enumerate.append(0) }
                    if single.contains(name) { equations += 1; current = Target(number: withinChapter(equations), kind: .equation) }
                    if rows.contains(base) { row = ([], nil, false) }
                    if theorems.contains(base) { current = nil }
                } else {
                    if rows.contains(base) { finishRow(starred: name.hasSuffix("*")); row = nil }
                    guard let index = stack.lastIndex(where: { $0.name == name }) else { continue }
                    current = stack[index].saved
                    for closed in stack[index...].map(\.name) {
                        if ["itemize", "enumerate", "description"].contains(closed), !lists.isEmpty { lists.removeLast() }
                        if closed == "enumerate", !enumerate.isEmpty { enumerate.removeLast(); owns = Array(owns.prefix(enumerate.count)) }
                    }
                    stack.removeSubrange(index...)
                }
            } else if let command = group(m, 3), let level = levels[command] {
                guard group(m, 4) != "*", level <= depth else { continue }
                sections[level + 1] += 1
                for lower in (level + 2)..<sections.count { sections[lower] = 0 }
                if chapters, level == 0 { equations = 0; figures = 0; tables = 0 }
                current = Target(number: sectionNumber(level), kind: .section(command))
            } else if let key = group(m, 5) {
                if row != nil { row!.labels.append(key) } else if let current { result[key] = current }
            } else if let command = group(m, 6) {
                switch command {
                case "appendix":
                    appendix = true
                    sections[chapters ? 1 : 2] = 0
                case "caption":
                    guard let float = stack.last(where: { floats[$0.name] != nil }), let kind = floats[float.name] else { continue }
                    if kind == .figure { figures += 1 } else { tables += 1 }
                    current = Target(number: withinChapter(kind == .figure ? figures : tables), kind: kind)
                default:
                    row?.notag = true
                }
            } else if let tag = group(m, 7) {
                if row != nil {
                    row!.tag = tag
                } else if let last = stack.last, single.contains(last.name), current?.kind == .equation {
                    // A tagged equation doesn't step the counter.
                    equations -= 1; current = Target(number: tag, kind: .equation)
                }
            } else if let name = group(m, 8) {
                theorems.insert(name)
            } else if group(m, 10) != nil {
                if row != nil, let env = stack.last(where: { rows.contains($0.name.hasSuffix("*") ? String($0.name.dropLast()) : $0.name) }) {
                    finishRow(starred: env.name.hasSuffix("*"))
                }
            } else if lists.last == "enumerate", group(m, 9) == nil, !enumerate.isEmpty {
                // `\item`: in an enumerate it steps the item counter; `\item[x]` doesn't.
                enumerate[enumerate.count - 1] += 1
                let n = enumerate.last!, level = enumerate.count
                let own = level == 1 ? "\(n)" : level == 2 ? alphabetic(n) : level == 3 ? roman(n) : alphabetic(n).uppercased()
                owns = Array(owns.prefix(level - 1)) + [own]
                // As `\p@enumii`… prefix them: 1a, 1(a)i, 1(a)iA.
                let ref = owns.count >= 3 ? owns[0] + "(\(owns[1]))" + owns[2...].joined() : owns.joined()
                current = Target(number: ref, kind: .item)
            }
        }
        return result
    }
}
