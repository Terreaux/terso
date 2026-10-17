// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import TersoCore

/// LaTeX tables in Mixed: a `tabular`, `tabular*`, `tabularx` or `longtable`
/// reads as the same glyph as a pipe table, drawn whole until the caret is
/// on any of its lines. Only the environment is drawn; a surrounding `table`
/// float, its caption and label stay source.
extension MixedPresentation {
    static let latexTableBoundary = MarkdownStyler.re(#"\\(begin|end)[ \t]*\{(tabular\*?|tabularx|longtable)\}"#)

    /// Whether the document has a table environment, for the Tables toggle.
    static func usesLaTeXTables(_ text: String) -> Bool {
        latexTableBoundary.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    static func latexTables(in text: String, selection: NSRange, config: EditorConfig, width: Double) -> [RenderedMath] {
        let ns = text as NSString
        let style = "\(config.font.rawValue)|\(config.fontSize)|\(config.theme.rawValue)|\(NSApp?.effectiveAppearance.name.rawValue ?? "")"
        return latexTableRanges(in: text).compactMap { r in
            guard !MathPresentation.showsSource(r, selection: selection, text: text) else { return nil }
            let source = ns.substring(with: r)
            guard let table = MarkdownTable(latex: source) else { return nil }
            return RenderedMath(range: r, image: image("latextable|\(style)|\(width)|\(source)") { tableImage(table, config: config, width: width) })
        }
    }

    /// Outermost table environments, `\begin` through its balanced `\end`,
    /// skipping those in `%` comments and in verbatim-like environments.
    static func latexTableRanges(in text: String) -> [NSRange] {
        let ns = text as NSString
        let regions = ScientificSyntax(DocumentSnapshot(revision: DocumentRevision(0), text: text)).regions
        let skipped = regions.filter { $0.kind == .comment }.map(\.range.nsRange)
            + LaTeXSyntax.literalEnvironments(in: text).filter { !LaTeXTable.environments.contains($0.name) }.map(\.range)
        var open: [(name: String, location: Int)] = [], found: [NSRange] = []
        for m in latexTableBoundary.matches(in: text, range: NSRange(location: 0, length: ns.length))
        where !skipped.contains(where: { NSLocationInRange(m.range.location, $0) }) {
            let name = ns.substring(with: m.range(at: 2))
            if ns.substring(with: m.range(at: 1)) == "begin" {
                open.append((name, m.range.location))
            } else if let last = open.last, last.name == name {
                open.removeLast()
                if open.isEmpty { found.append(NSRange(location: last.location, length: m.range.upperBound - last.location)) }
            } else {
                open.removeAll()  // An unmatched `\end`: start over.
            }
        }
        return found
    }
}

extension MarkdownTable {
    /// A whole LaTeX table environment as a table: columns from its spec
    /// (`l c r`; `p{…}`, `m{…}`, `b{…}` and `X` lead; `|`, `@{…}`, `>{…}` are
    /// dropped), rows on `\\`, cells on `&`. The first row is the header when
    /// a rule sets it apart (`\midrule`, `\endhead`, or an `\hline` the body
    /// rows don't repeat). `\multicolumn` puts its text in the first spanned
    /// cell and leaves the rest empty. Nil when anything isn't understood, so
    /// the source stays in view.
    init?(latex source: String) {
        var s = LaTeXTable.Scanner(source.trimmingCharacters(in: .whitespacesAndNewlines))
        guard s.take("\\begin"), let name = s.group(), LaTeXTable.environments.contains(name) else { return nil }
        if name == "tabular*" || name == "tabularx" { guard s.group() != nil else { return nil } }
        _ = s.optional()
        guard let spec = s.group(), let alignments = LaTeXTable.alignments(spec), !alignments.isEmpty else { return nil }
        let end = "\\end{\(name)}"
        var body = s.rest
        guard body.hasSuffix(end) else { return nil }
        body.removeLast(end.count)
        guard let parsed = LaTeXTable.rows(body) else { return nil }
        var table: [[String]] = []
        for row in parsed.rows {
            var cells: [String] = []
            for raw in row {
                guard let more = LaTeXTable.cells(raw) else { return nil }
                cells += more
            }
            guard cells.count <= alignments.count else { return nil }
            table.append(cells)
        }
        guard !table.isEmpty else { return nil }
        // Rules between rows; the first gap sets the header apart.
        let gaps = parsed.rules.dropFirst().dropLast()
        let first = gaps.first ?? [], later = gaps.dropFirst()
        let headed = !first.isEmpty && (first.contains { $0 == "midrule" || $0 == "endhead" }
            || later.allSatisfy { $0.count < first.count } || later.contains { $0.isEmpty })
        self.alignments = alignments
        self.headed = headed
        header = headed ? table[0] : []
        rows = headed ? Array(table.dropFirst()) : table
    }
}

/// Reading LaTeX tables, for `MarkdownTable(latex:)`.
enum LaTeXTable {
    static let environments: Set<String> = ["tabular", "tabular*", "tabularx", "longtable"]
    static let ruleCommands: Set<String> = ["hline", "toprule", "midrule", "bottomrule", "endhead", "cline", "cmidrule", "hdashline", "specialrule", "addlinespace"]
    static let declarations: Set<String> = [
        "bfseries", "itshape", "slshape", "scshape", "upshape", "mdseries", "rmfamily", "sffamily", "ttfamily", "normalfont",
        "bf", "it", "rm", "sf", "tt", "em", "centering", "raggedright", "raggedleft", "arraybackslash",
        "tiny", "scriptsize", "footnotesize", "small", "normalsize", "large", "Large", "LARGE", "huge", "Huge", "relax", "strut",
    ]

    /// Column alignments from a spec, or nil for a column type it doesn't know.
    static func alignments(_ spec: String) -> [NSTextAlignment]? {
        var s = Scanner(spec), result: [NSTextAlignment] = []
        while let c = s.next() {
            switch c {
            case "l": result.append(.left)
            case "c": result.append(.center)
            case "r": result.append(.right)
            case "X": result.append(.left)
            case "p", "m", "b": guard s.group() != nil else { return nil }; result.append(.left)
            case "@", "!", ">", "<": guard s.group() != nil else { return nil }
            case "*":
                guard let n = s.group().flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }), (1...64).contains(n),
                      let inner = s.group().flatMap(alignments) else { return nil }
                result += Array(repeating: inner, count: n).flatMap { $0 }
            case "|": continue
            case _ where c.isWhitespace: continue
            default: return nil
            }
        }
        return result
    }

    /// Rows of raw cells, and the rules before each row and after the last
    /// (`rules.count == rows.count + 1`). Nil for nested environments, a
    /// longtable's extra heads and feet, captions or unbalanced braces.
    static func rows(_ body: String) -> (rows: [[String]], rules: [[String]])? {
        var s = Scanner(body), rows: [[String]] = [], rules: [[String]] = [[]]
        var cells: [String] = [], cell = "", depth = 0
        func blank(_ x: String) -> Bool { x.allSatisfy(\.isWhitespace) }
        func endRow() {
            cells.append(cell); cell = ""
            if !(cells.count == 1 && blank(cells[0])) { rows.append(cells); rules.append([]) }
            cells = []
        }
        while let c = s.next() {
            switch c {
            case "%": s.skipLine()
            case "{": depth += 1; cell.append(c)
            case "}": depth -= 1; guard depth >= 0 else { return nil }; cell.append(c)
            case "&" where depth == 0: cells.append(cell); cell = ""
            case "\\":
                guard let n = s.peek() else { return nil }
                if n == "\\" {
                    _ = s.next()
                    if depth > 0 { cell += "\\\\"; continue }
                    if s.peek() == "*" { _ = s.next() }
                    _ = s.optional()
                    endRow()
                } else if n.isLetter {
                    let name = s.letters()
                    switch name {
                    case "begin", "noalign", "endfirsthead", "endfoot", "endlastfoot", "caption": return nil
                    case "tabularnewline" where depth == 0: endRow()
                    case _ where ruleCommands.contains(name) && depth == 0 && cells.isEmpty && blank(cell):
                        switch name {
                        case "cline": _ = s.group()
                        case "cmidrule": _ = s.optional(); _ = s.optional("(", ")"); _ = s.group()
                        case "specialrule": _ = s.group(); _ = s.group(); _ = s.group()
                        default: _ = s.optional()
                        }
                        if name != "addlinespace" { rules[rules.count - 1].append(name) }
                    default: cell += "\\" + name
                    }
                } else {
                    _ = s.next(); cell.append(c); cell.append(n)
                }
            default: cell.append(c)
            }
        }
        guard depth == 0 else { return nil }
        endRow()
        return (rows, rules)
    }

    /// A raw cell as display cells: one, or a `\multicolumn`'s text followed
    /// by empty cells for the rest of its span (its own alignment is ignored).
    static func cells(_ raw: String) -> [String]? {
        var s = Scanner(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        guard s.take("\\multicolumn") else { return [cell(raw)] }
        guard let n = s.group().flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }), (1...64).contains(n),
              s.group() != nil, let content = s.group(), s.rest.allSatisfy(\.isWhitespace) else { return nil }
        return [cell(content)] + Array(repeating: "", count: n - 1)
    }

    /// A cell's TeX as the inline Markdown `tableImage` sets: `\textbf`,
    /// `\emph` and `\texttt` become strong, emphasis and code; escapes, `~`,
    /// dashes and quotes become their characters; `$…$` math stays as text;
    /// other commands keep their source. Markdown's own syntax is escaped.
    static func cell(_ tex: String) -> String {
        var s = Scanner(tex), out = "", math = false
        while let c = s.next() {
            if math {
                if c == "$" { math = false; out += "$"; continue }
                out += escape(c)
                if c == "\\", let n = s.next() { out += escape(n) }
                continue
            }
            switch c {
            case "$": math = true; out += "$"
            case "\\":
                guard let n = s.peek() else { out += escape(c); break }
                if n.isLetter { out += command(s.letters(), &s) } else { _ = s.next(); out += symbol(n) }
            case "{", "}": break
            case "~": out += " "
            case "-" where s.peek() == "-":
                _ = s.next()
                if s.peek() == "-" { _ = s.next(); out += "—" } else { out += "–" }
            case "`" where s.peek() == "`": _ = s.next(); out += "“"
            case "'" where s.peek() == "'": _ = s.next(); out += "”"
            case "`": out += "‘"
            default: out += escape(c)
            }
        }
        return out.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func command(_ name: String, _ s: inout Scanner) -> String {
        func wrap(_ mark: String) -> String {
            let inner = s.group().map(cell) ?? ""
            return inner.isEmpty ? "" : mark + inner + mark
        }
        switch name {
        case "textbf": return wrap("**")
        case "textit", "emph", "textsl": return wrap("*")
        case "texttt":
            guard let arg = s.group() else { return "" }
            var code = "", t = Scanner(arg)
            while let c = t.next() {
                if c == "\\", let n = t.peek(), !n.isLetter { _ = t.next(); code.append(n) } else if c != "{" && c != "}" { code.append(c) }
            }
            return code.isEmpty ? "" : code.contains("`") ? code.map(escape).joined() : "`" + code + "`"
        case "text", "textrm", "textsf", "textup", "textmd", "textnormal", "textsc", "mbox", "hbox", "underline", "makecell", "shortstack":
            _ = s.optional()
            return s.group().map(cell) ?? ""
        case "textcolor", "colorbox":
            _ = s.optional(); _ = s.group()
            return s.group().map(cell) ?? ""
        case "multirow":
            _ = s.group(); _ = s.optional(); _ = s.group(); _ = s.optional()
            return s.group().map(cell) ?? ""
        case "ldots", "dots", "textellipsis": _ = s.empty(); return "…"
        case "textendash": _ = s.empty(); return "–"
        case "textemdash": _ = s.empty(); return "—"
        case "textdegree": _ = s.empty(); return "°"
        case "textbackslash": _ = s.empty(); return "\\\\"
        case "LaTeX", "TeX": _ = s.empty(); return name
        case "newline", "linebreak": return " "
        case _ where declarations.contains(name): s.skipSpace(); return ""
        default:
            var raw = "\\" + name
            while true {
                if let o = s.optional() { raw += "[" + o + "]" } else if let g = s.group() { raw += "{" + g + "}" } else { break }
            }
            return raw.map(escape).joined()
        }
    }

    private static func symbol(_ c: Character) -> String {
        switch c {
        case "%", "&", "_", "#", "$", "{", "}": escape(c)
        case ",", ";", ":", " ", "\\": " "
        case _ where c.isWhitespace: " "
        case "!", "-", "/": ""
        default: escape("\\") + escape(c)
        }
    }

    /// Escapes what inline Markdown would read as syntax.
    static func escape(_ c: Character) -> String {
        "\\`*_[]<>&~".contains(c) ? "\\" + String(c) : String(c)
    }

    /// Walks TeX source by character, reading groups and arguments.
    struct Scanner {
        let chars: [Character]
        var i = 0
        init(_ text: String) { chars = Array(text) }

        var rest: String { String(chars[i...]) }
        func peek() -> Character? { i < chars.count ? chars[i] : nil }
        mutating func next() -> Character? {
            guard i < chars.count else { return nil }
            defer { i += 1 }
            return chars[i]
        }
        mutating func skipSpace() { while let c = peek(), c.isWhitespace { i += 1 } }
        mutating func skipLine() { while let c = next(), !c.isNewline {} }
        mutating func letters() -> String {
            let start = i
            while let c = peek(), c.isLetter { i += 1 }
            return String(chars[start..<i])
        }
        /// Consumes `prefix` when it is a whole control word here.
        mutating func take(_ prefix: String) -> Bool {
            let p = Array(prefix)
            guard chars.count - i >= p.count, Array(chars[i..<i + p.count]) == p,
                  !(i + p.count < chars.count && chars[i + p.count].isLetter) else { return false }
            i += p.count
            return true
        }
        /// A `{…}` group after optional blanks, without its braces.
        mutating func group() -> String? { optional("{", "}") }
        /// An empty `{}` that ends a control word, as in `\ldots{}`.
        mutating func empty() -> Bool {
            guard peek() == "{", i + 1 < chars.count, chars[i + 1] == "}" else { return false }
            i += 2
            return true
        }
        /// An argument between `open` and `close` after optional blanks, with
        /// balanced braces inside; nil, consuming nothing, when there is none.
        mutating func optional(_ open: Character = "[", _ close: Character = "]") -> String? {
            let start = i
            skipSpace()
            guard peek() == open else { i = start; return nil }
            i += 1
            let from = i
            var depth = 0
            while let c = next() {
                if c == "\\" { _ = next(); continue }
                if c == close && depth == 0 { return String(chars[from..<i - 1]) }
                if c == "{" { depth += 1 } else if c == "}" { depth -= 1 }
            }
            i = start
            return nil
        }
    }
}
