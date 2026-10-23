// SPDX-License-Identifier: AGPL-3.0-only
import AppKit

extension NSAttributedString.Key {
    /// Set from `WordStructure` on a whole paragraph, terminator included.
    static let wordRole = Self("org.terso.word.role")
    static let wordList = Self("org.terso.word.list")
    /// A run in a code character style or a monospaced Word font.
    static let wordCode = Self("org.terso.word.code")
}

/// Writes an attributed string as CommonMark with GFM tables and
/// strikethrough. Paragraph structure comes from `wordRole`/`wordList` when
/// present, otherwise from what AppKit kept: text lists, text tables, header
/// levels and larger font sizes. Inline: bold, italic, strikethrough, code
/// and links. Attachments (images) are dropped.
enum WordMarkdown {
    static func markdown(from attributed: NSAttributedString) -> String {
        Writer(attributed).write()
    }

    /// Lays `structure` over AppKit's reading. Paragraphs are matched by
    /// their visible text, so one AppKit skipped or added only loses its own
    /// structure, never shifts the rest.
    static func annotate(_ attributed: NSAttributedString, with structure: WordStructure) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: attributed)
        let ns = attributed.string as NSString
        var next = 0
        for range in paragraphRanges(in: ns) {
            let content = contentRange(of: range, in: ns)
            let text = ns.substring(with: content)
            let key = matchKey(text)
            let window = next..<min(next + 8, structure.paragraphs.count)
            let found = key.isEmpty
                ? (window.first.map { matchKey(structure.paragraphs[$0].text).isEmpty ? $0 : nil } ?? nil)
                : window.first { matchKey(structure.paragraphs[$0].text) == key }
            guard let index = found else { continue }
            next = index + 1
            let paragraph = structure.paragraphs[index]
            if paragraph.role != .body { result.addAttribute(.wordRole, value: paragraph.role, range: range) }
            if let list = paragraph.list { result.addAttribute(.wordList, value: list, range: range) }
            // Spans are located by their text, searching forward, since AppKit
            // may spell tabs and breaks differently from the XML.
            var cursor = 0
            for link in paragraph.links {
                guard let found = locate(link.range, of: paragraph.text, in: text, from: &cursor) else { continue }
                let target = NSRange(location: content.location + found.location, length: found.length)
                if result.attribute(.link, at: target.location, effectiveRange: nil) == nil {
                    result.addAttribute(.link, value: link.url, range: target)
                }
            }
            cursor = 0
            for code in paragraph.code {
                guard let found = locate(code, of: paragraph.text, in: text, from: &cursor) else { continue }
                result.addAttribute(.wordCode, value: true, range: NSRange(location: content.location + found.location, length: found.length))
            }
        }
        return result
    }

    private static func matchKey(_ text: String) -> String {
        String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) && $0 != "\u{FFFC}" }.map(Character.init))
    }

    private static func locate(_ range: NSRange, of source: String, in text: String, from cursor: inout Int) -> NSRange? {
        let needle = (source as NSString).substring(with: range)
        let haystack = text as NSString
        guard cursor <= haystack.length else { return nil }
        let found = haystack.range(of: needle, range: NSRange(location: cursor, length: haystack.length - cursor))
        guard found.location != NSNotFound else { return nil }
        cursor = NSMaxRange(found)
        return found
    }

    static func paragraphRanges(in ns: NSString) -> [NSRange] {
        var ranges: [NSRange] = [], location = 0
        while location < ns.length {
            let range = ns.paragraphRange(for: NSRange(location: location, length: 0))
            ranges.append(range)
            location = NSMaxRange(range)
        }
        return ranges
    }

    static func contentRange(of paragraph: NSRange, in ns: NSString) -> NSRange {
        var end = NSMaxRange(paragraph)
        while end > paragraph.location, let scalar = UnicodeScalar(ns.character(at: end - 1)),
              ["\n", "\r", "\u{2029}", "\u{85}"].contains(scalar) {
            end -= 1
        }
        return NSRange(location: paragraph.location, length: end - paragraph.location)
    }
}

// MARK: - Writer

private struct Writer {
    let source: NSAttributedString
    let ns: NSString
    /// The body text's size and whether it is itself monospaced, which
    /// would otherwise turn a whole typewriter-font document into code.
    let bodySize: CGFloat
    let monospacedBody: Bool
    /// Font sizes larger than the body's, largest first: `#`, `##`, …
    let headingSizes: [CGFloat]

    init(_ source: NSAttributedString) {
        self.source = source
        let string = source.string as NSString
        ns = string
        var sizes: [CGFloat: Int] = [:], mono = 0, total = 0
        source.enumerateAttribute(.font, in: NSRange(location: 0, length: string.length)) { value, range, _ in
            guard let font = value as? NSFont else { return }
            let count = string.substring(with: range).filter { !$0.isWhitespace }.count
            sizes[font.pointSize, default: 0] += count
            total += count
            if Self.isMonospaced(font) { mono += count }
        }
        bodySize = sizes.max { $0.value < $1.value }?.key ?? 12
        monospacedBody = total > 0 && mono * 2 > total
        var larger: Set<CGFloat> = []
        for range in WordMarkdown.paragraphRanges(in: string) {
            if let size = Self.uniformSize(source, WordMarkdown.contentRange(of: range, in: string)), size >= bodySize + 1.5 {
                larger.insert(size)
            }
        }
        headingSizes = larger.sorted(by: >)
    }

    static func isMonospaced(_ font: NSFont) -> Bool {
        font.isFixedPitch || font.fontDescriptor.symbolicTraits.contains(.monoSpace)
    }

    private static func uniformSize(_ source: NSAttributedString, _ range: NSRange) -> CGFloat? {
        guard range.length > 0 else { return nil }
        var size: CGFloat?, uniform = true
        source.enumerateAttribute(.font, in: range) { value, _, stop in
            let pointSize = (value as? NSFont)?.pointSize
            if size == nil { size = pointSize } else if size != pointSize { uniform = false; stop.pointee = true }
        }
        return uniform ? size : nil
    }

    // MARK: Blocks

    private enum Kind {
        case empty, paragraph, quote, code, heading(Int)
        case list(id: String, level: Int, ordered: Bool, start: Int)
        case cell(NSTextTable, row: Int, column: Int)
    }

    /// A list marker AppKit wrote as text, `\t1.\t` or `\t•\t`: in a text
    /// list read from HTML, and as the whole list in a `.docx` AppKit wrote.
    private struct TextMarker { var length: Int; var ordered: Bool; var number: Int? }

    private func textMarker(in content: NSRange, style: NSParagraphStyle?) -> TextMarker? {
        guard style?.textBlocks.isEmpty ?? true else { return nil }
        let text = ns.substring(with: content)
        // Without a text list, only a tab-led marker is unmistakable.
        let lead = style?.textLists.isEmpty ?? true ? "\t" : "\t?"
        for (pattern, ordered) in [(lead + #"([0-9]{1,4}|[a-zA-Z]|[ivxlcdmIVXLCDM]{1,6})[.)]?\t"#, true),
                                   (lead + #"[•◦▪▫‣⁃○●■□–·*-]\t"#, false)] {
            guard let match = text.range(of: "^" + pattern, options: .regularExpression) else { continue }
            let marker = text[match].trimmingCharacters(in: CharacterSet(charactersIn: "\t.)"))
            return TextMarker(length: (String(text[match]) as NSString).length, ordered: ordered, number: Int(marker))
        }
        return nil
    }

    private func kind(of paragraph: NSRange, content: NSRange, listRun: Int, marker: TextMarker?) -> Kind {
        let attributes = source.attributes(at: paragraph.location, effectiveRange: nil)
        let style = attributes[.paragraphStyle] as? NSParagraphStyle
        if let cell = style?.textBlocks.lazy.compactMap({ $0 as? NSTextTableBlock }).first {
            return .cell(cell.table, row: cell.startingRow, column: cell.startingColumn)
        }
        let role = attributes[.wordRole] as? WordStructure.Paragraph.Role
        if role == .code || (role == nil && content.length > 0 && wholly(content, isCode: true)) { return .code }
        guard content.length > 0, !ns.substring(with: content).allSatisfy({ $0.isWhitespace || $0 == "\u{FFFC}" }) else {
            return .empty
        }
        if case .heading(let level) = role { return .heading(level) }
        if role == .quote { return .quote }
        if let list = attributes[.wordList] as? WordStructure.List {
            return .list(id: list.id, level: list.level, ordered: list.ordered, start: list.start)
        }
        if let lists = style?.textLists, let last = lists.last {
            return .list(id: "run\(listRun)", level: lists.count - 1, ordered: Self.isOrdered(last.markerFormat),
                         start: last.startingItemNumber)
        }
        if let marker {
            // Word's default list indent is half an inch a level.
            let level = max(0, Int(((style?.headIndent ?? 0) / 36).rounded()) - 1)
            return .list(id: "run\(listRun)", level: level, ordered: marker.ordered, start: marker.number ?? 1)
        }
        if let level = style?.headerLevel, level > 0 { return .heading(min(level, 6)) }
        if let size = Self.uniformSize(source, content), let rank = headingSizes.firstIndex(of: size),
           content.length <= 200 {
            return .heading(min(rank + 1, 6))
        }
        return .paragraph
    }

    private static func isOrdered(_ format: NSTextList.MarkerFormat) -> Bool {
        ![.disc, .circle, .square, .hyphen, .check, .box, .diamond].contains(format)
    }

    private func wholly(_ range: NSRange, isCode: Bool) -> Bool {
        var all = true
        source.enumerateAttributes(in: range) { attributes, run, stop in
            let text = ns.substring(with: run)
            if text.allSatisfy(\.isWhitespace) { return }
            if code(attributes) != isCode { all = false; stop.pointee = true }
        }
        return all
    }

    private func code(_ attributes: [NSAttributedString.Key: Any]) -> Bool {
        if attributes[.wordCode] != nil { return true }
        guard !monospacedBody, let font = attributes[.font] as? NSFont else { return false }
        return Self.isMonospaced(font)
    }

    func write() -> String {
        var blocks: [String] = []
        /// How the last block joins the next one of the same kind.
        enum Open { case none, list, quote, code([String]), table(NSTextTable, [Int: [Int: String]]) }
        var open = Open.none
        var listRun = 0
        var counters: [String: [Int]] = [:]
        var markers: [Int] = []        // Marker width per open list level.
        var topList: String?           // The open list's top-level `numId`.

        func close() {
            switch open {
            case .code(var lines):
                while lines.last?.isEmpty == true { lines.removeLast() }
                let body = lines.joined(separator: "\n")
                var fence = "```"
                while body.contains(fence) { fence += "`" }
                blocks.append(fence + "\n" + body + "\n" + fence)
            case .table(_, let rows): blocks.append(table(rows))
            case .list, .quote, .none: break
            }
            if case .list = open { markers = []; topList = nil; listRun += 1 }
            open = .none
        }
        func append(_ text: String, joining: Bool) {
            if joining, let last = blocks.popLast() { blocks.append(last + text) } else { blocks.append(text) }
        }

        for paragraph in WordMarkdown.paragraphRanges(in: ns) {
            var content = WordMarkdown.contentRange(of: paragraph, in: ns)
            let marker = textMarker(in: content, style: source.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle)
            if let marker { content = NSRange(location: content.location + marker.length, length: content.length - marker.length) }
            switch kind(of: paragraph, content: content, listRun: listRun, marker: marker) {
            case .empty:
                // Blank lines inside code stay; elsewhere they only separate.
                if case .code(var lines) = open { lines.append(""); open = .code(lines) }
            case .code:
                if case .code = open {} else { close(); open = .code([]) }
                guard case .code(var lines) = open else { break }
                lines.append(ns.substring(with: content).replacingOccurrences(of: "\u{2028}", with: "\n")
                    .replacingOccurrences(of: "\u{FFFC}", with: ""))
                open = .code(lines)
            case .cell(let table, let row, let column):
                if case .table(let current, _) = open, current === table {} else { close(); open = .table(table, [:]) }
                guard case .table(let current, var rows) = open else { break }
                // A header row is bold already; GFM sets it apart anyway.
                let text = Self.cellText(inline(content, heading: rows.isEmpty || rows.keys.min() == row))
                rows[row, default: [:]][column] = rows[row]?[column].map { $0 + "<br>" + text } ?? text
                open = .table(current, rows)
            case .heading(let level):
                close()
                let text = inline(content, heading: true).replacingOccurrences(of: Self.lineBreak, with: " ")
                blocks.append(String(repeating: "#", count: level) + " " + text)
            case .quote:
                let joining: Bool
                if case .quote = open { joining = true } else { close(); open = .quote; joining = false }
                let lines = Self.lines(inline(content, heading: false))
                append((joining ? "\n>\n" : "") + lines.map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n"), joining: joining)
            case .list(let id, let requested, let ordered, let start):
                // Another top-level list is another Markdown list, even with no text between.
                if case .list = open, requested == 0, let topList, topList != id { close() }
                let joining: Bool
                if case .list = open { joining = true } else { close(); open = .list; joining = false }
                if requested == 0 { topList = id }
                // Markdown nests one level at a time under its parent's marker.
                let level = min(requested, markers.count)
                var counter = counters[id] ?? []
                counter = Array(counter.prefix(level + 1))
                if counter.count <= level {
                    while counter.count < level { counter.append(0) }
                    counter.append(start - 1)
                }
                counter[level] += 1
                counters[id] = counter
                let marker = ordered ? "\(counter[level])." : "-"
                markers = Array(markers.prefix(level)) + [marker.count + 1]
                let indent = String(repeating: " ", count: markers.prefix(level).reduce(0, +))
                let lines = Self.lines(inline(content, heading: false))
                let continuation = indent + String(repeating: " ", count: marker.count + 1)
                let item = indent + marker + " " + lines.joined(separator: "\\\n" + continuation)
                append((joining ? "\n" : "") + item, joining: joining)
            case .paragraph:
                close()
                blocks.append(Self.lines(inline(content, heading: false)).joined(separator: "\\\n"))
            }
        }
        close()
        let text = blocks.filter { !$0.isEmpty }.joined(separator: "\n\n")
        return text.isEmpty ? "" : text + "\n"
    }

    private func table(_ rows: [Int: [Int: String]]) -> String {
        let columns = (rows.values.flatMap(\.keys).max() ?? 0) + 1
        func line(_ cells: [String]) -> String { "| " + cells.joined(separator: " | ") + " |" }
        var lines: [String] = []
        for (index, row) in rows.keys.sorted().enumerated() {
            lines.append(line((0..<columns).map { rows[row]?[$0] ?? "" }))
            if index == 0 { lines.append(line(Array(repeating: "---", count: columns))) }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Inline

    /// Stands in for a line break inside a paragraph until the block decides
    /// how to spell it: a backslash break, a space in a heading, `<br>` in a cell.
    static let lineBreak = "\u{2028}"

    /// A paragraph's lines, trimmed; an empty one would end the paragraph.
    private static func lines(_ text: String) -> [String] {
        text.components(separatedBy: lineBreak).map { escapeLineStart($0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
    }

    private static func cellText(_ text: String) -> String {
        lines(text).joined(separator: "<br>").replacingOccurrences(of: "|", with: "\\|")
    }

    private enum Emphasis: CaseIterable { case strike, bold, italic
        var marker: String {
            switch self {
            case .strike: "~~"
            case .bold: "**"
            case .italic: "*"
            }
        }
    }

    private struct Segment {
        var text: String
        var emphasis: [Emphasis]
        var code: Bool
        var link: String?
    }

    private func inline(_ range: NSRange, heading: Bool) -> String {
        var segments: [Segment] = []
        source.enumerateAttributes(in: range) { attributes, run, _ in
            let text = ns.substring(with: run).replacingOccurrences(of: "\u{FFFC}", with: "")
                .replacingOccurrences(of: "\u{0B}", with: Self.lineBreak)
            guard !text.isEmpty else { return }
            var emphasis: [Emphasis] = []
            if let strike = attributes[.strikethroughStyle] as? Int, strike != 0 { emphasis.append(.strike) }
            if let font = attributes[.font] as? NSFont {
                let traits = font.fontDescriptor.symbolicTraits
                // A heading is often bold throughout; `#` already says so.
                if traits.contains(.bold), !heading { emphasis.append(.bold) }
                if traits.contains(.italic) { emphasis.append(.italic) }
            }
            let link = (attributes[.link] as? URL)?.absoluteString ?? attributes[.link] as? String
            segments.append(Segment(text: text, emphasis: emphasis, code: code(attributes), link: link))
        }
        var out = "", index = 0
        while index < segments.count {
            let link = segments[index].link
            var end = index
            while end < segments.count, segments[end].link == link { end += 1 }
            let text = Self.emphasize(segments[index..<end])
            if let link, !text.trimmingCharacters(in: .whitespaces).isEmpty {
                let lead = String(text.prefix { $0 == " " }), trail = String(text.reversed().prefix { $0 == " " })
                let core = text.trimmingCharacters(in: .whitespaces)
                out += lead + "[" + core + "](" + Self.destination(link) + ")" + trail
            } else {
                out += text
            }
            index = end
        }
        return out
    }

    /// Markers open and close around the text, never around its edge
    /// whitespace, which CommonMark would not read as emphasis.
    private static func emphasize(_ segments: ArraySlice<Segment>) -> String {
        var out = "", open: [Emphasis] = [], pending = ""
        for segment in segments {
            let lead = String(segment.text.prefix { $0.isWhitespace && String($0) != lineBreak })
            let trail = String(segment.text.reversed().prefix { $0.isWhitespace && String($0) != lineBreak }.reversed())
            let core = segment.text.count > lead.count + trail.count
                ? String(segment.text.dropFirst(lead.count).dropLast(trail.count)) : ""
            guard !core.isEmpty else { pending += segment.text; continue }
            if let first = open.firstIndex(where: { !segment.emphasis.contains($0) }) {
                out += open[first...].reversed().map(\.marker).joined()
                open.removeSubrange(first...)
            }
            out += pending + lead
            pending = ""
            for emphasis in Emphasis.allCases where segment.emphasis.contains(emphasis) && !open.contains(emphasis) {
                out += emphasis.marker
                open.append(emphasis)
            }
            out += segment.code ? codeSpan(core) : escape(core)
            pending = trail
        }
        return out + open.reversed().map(\.marker).joined() + pending
    }

    private static func codeSpan(_ text: String) -> String {
        var longest = 0, run = 0
        for character in text { run = character == "`" ? run + 1 : 0; longest = max(longest, run) }
        let fence = String(repeating: "`", count: longest + 1)
        let pad = text.hasPrefix("`") || text.hasSuffix("`") ? " " : ""
        return fence + pad + text + pad + fence
    }

    private static func destination(_ url: String) -> String {
        url.contains(where: { $0 == " " || $0 == "(" || $0 == ")" }) ? "<" + url.replacingOccurrences(of: ">", with: "%3E") + ">" : url
    }

    /// Escapes what CommonMark would read as syntax mid-line. An underscore
    /// between letters stays bare: it never starts emphasis there.
    private static func escape(_ text: String) -> String {
        let characters = Array(text)
        var out = ""
        for (index, character) in characters.enumerated() {
            switch character {
            case "\\", "`", "*", "[", "]", "<":
                out += "\\" + String(character)
            case "_":
                let before = index > 0 ? characters[index - 1] : " ", after = index + 1 < characters.count ? characters[index + 1] : " "
                out += before.isLetter || before.isNumber ? (after.isLetter || after.isNumber ? "_" : "\\_") : "\\_"
            case "~" where index + 1 < characters.count && characters[index + 1] == "~":
                out += "\\~"
            default:
                out.append(character)
            }
        }
        return out
    }

    /// A line that would open a heading, quote, list or rule keeps its text.
    private static func escapeLineStart(_ line: String) -> String {
        if let number = line.range(of: #"^\d{1,9}(?=[.)](\s|$))"#, options: .regularExpression) {
            return String(line[..<number.upperBound]) + "\\" + String(line[number.upperBound...])
        }
        let patterns = [#"^#{1,6}(\s|$)"#, #"^>"#, #"^[-+](\s|$)"#, #"^[-=]+\s*$"#]
        return patterns.contains { line.range(of: $0, options: .regularExpression) != nil } ? "\\" + line : line
    }
}
