// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// A Markdown document reduced to the author's prose, with every offset
/// preserved. Markup, code, tables, URLs and headings are replaced by spaces
/// in `masked`, which has exactly the same UTF-16 length as the original, so
/// a range found in the masked text is a valid range in the document.
public struct ProseText: Sendable {
    public struct Heading: Sendable, Hashable {
        public let level: Int
        public let title: String
        public let range: TextSpan
    }
    public struct Block: Sendable, Hashable {
        public enum Kind: Sendable, Hashable { case paragraph, listItem, quote }
        public let kind: Kind
        public let range: TextSpan
    }
    public struct Sentence: Sendable, Hashable {
        public let range: TextSpan
        public let blockIndex: Int
        public let words: [TextSpan]
    }

    public let original: String
    public let masked: String
    public let headings: [Heading]
    public let blocks: [Block]
    public let sentences: [Sentence]
    public let words: [TextSpan]
    public let codeBlockCount: Int

    public var maskedNS: NSString { masked as NSString }

    public func string(_ r: TextSpan) -> String { (original as NSString).substring(with: r.nsRange) }
    public func maskedString(_ r: TextSpan) -> String { (masked as NSString).substring(with: r.nsRange) }

    public func sentences(inBlock index: Int) -> [Sentence] { sentences.filter { $0.blockIndex == index } }

    public init(markdown text: String) { self.init(text, format: .markdown) }
    public init(latex text: String) { self.init(text, format: .latex) }
    /// Prose for a snapshot, read as LaTeX or Markdown according to its name.
    public init(_ snapshot: DocumentSnapshot) { self.init(snapshot.text, format: snapshot.format) }

    public init(_ text: String, format: SourceFormat) {
        original = text
        let ns = text as NSString
        var units = Array(text.utf16)
        let space: UInt16 = 0x20

        func blank(_ r: NSRange, keepNewlines: Bool = true) {
            guard r.location != NSNotFound else { return }
            for i in r.location..<min(r.location + r.length, units.count) where !(keepNewlines && units[i] == 0x0A) {
                units[i] = space
            }
        }
        func matches(_ pattern: String, _ options: NSRegularExpression.Options = [.anchorsMatchLines]) -> [NSTextCheckingResult] {
            // Patterns are compile-time constants; a failure here is a programming error.
            let re = try! NSRegularExpression(pattern: pattern, options: options)
            return re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        }

        // Front matter.
        if format == .markdown, let r = MarkdownSyntax.frontMatter(in: text) { blank(r) }
        // One structural scan gives code precedence over LaTeX and preserves
        // all UTF-16 offsets for rules, statistics, and spelling.
        let syntax = ScientificSyntax(DocumentSnapshot(revision: DocumentRevision(0), text: text))
        syntax.regions.filter { $0.kind != .prose }.forEach { blank($0.range.nsRange) }
        let fencedCode = syntax.regions.filter {
            let raw = $0.rawText.trimmingCharacters(in: .whitespaces)
            return $0.kind == .code && (raw.hasPrefix("```") || raw.hasPrefix("~~~")) && raw.contains("\n")
        }.count
        var hs: [Heading] = []
        var blockStarts: [(Int, Block.Kind)] = []
        if format == .latex {
            // The preamble, anything after \end{document}, and environments
            // holding tables, drawings, code or references are not prose.
            if let r = LaTeXSyntax.preamble(in: text) { blank(r) }
            if let r = LaTeXSyntax.trailer(in: text) { blank(r) }
            let environments = LaTeXSyntax.literalEnvironments(in: text)
            environments.forEach { blank($0.range) }
            codeBlockCount = fencedCode + environments.filter { LaTeXSyntax.codeEnvironments.contains($0.name) }.count
            // Sectioning commands are headings unless commented out or inside
            // code, which the structural scan has already classified.
            let hidden = syntax.regions.filter { $0.kind == .comment || $0.kind == .code }.map(\.range.nsRange)
                + (LaTeXSyntax.preamble(in: text).map { [$0] } ?? []) + environments.map(\.range)
            let sections = LaTeXSyntax.section.matches(in: text, range: NSRange(location: 0, length: ns.length))
                .filter { m in !hidden.contains { NSLocationInRange(m.range.location, $0) } }
            let levels = LaTeXSyntax.levels(for: Set(sections.map { ns.substring(with: $0.range(at: 1)) }))
            for m in sections {
                let title = LaTeXSyntax.plainTitle(ns.substring(with: m.range(at: 2)))
                hs.append(Heading(level: levels[ns.substring(with: m.range(at: 1))] ?? 1, title: title, range: TextSpan(m.range)))
                blank(m.range)
            }
            // \item opens a list item; its marker is already masked as a command.
            for m in LaTeXSyntax.item.matches(in: text, range: NSRange(location: 0, length: ns.length))
                where !hidden.contains(where: { NSLocationInRange(m.range.location, $0) }) {
                blank(m.range)
                blockStarts.append((m.range.location, .listItem))
            }
        } else {
            codeBlockCount = fencedCode
            // Headings (recorded for the outline, removed from prose).
            for m in matches(#"^(#{1,6})[ \t]+(.*?)[ \t#]*$"#) {
                let r = m.range
                if units[r.location] != UInt16(UInt8(ascii: "#")) { continue } // already masked (inside code)
                hs.append(Heading(level: m.range(at: 1).length, title: ns.substring(with: m.range(at: 2)), range: TextSpan(r)))
                blank(r)
            }
            // Setext underlines, horizontal rules, tables, HTML, images, URLs.
            matches(#"^[ \t]*(?:[-*_][ \t]*){3,}$"#).forEach { blank($0.range) }
            matches(#"^[ \t]*=+[ \t]*$"#).forEach { blank($0.range) }
            matches(#"^[ \t]*\|.*$"#).forEach { blank($0.range) }
            matches(#"!\[[^\]\n]*\]\([^)\n]*\)"#, []).forEach { blank($0.range) }
            matches(#"<[A-Za-z/!][^>\n]*>"#, []).forEach { blank($0.range) }
            // Links: keep the link text, drop the brackets and target.
            for m in matches(#"\[([^\]\n]+)\]\(([^)\n]*)\)"#, []) {
                let inner = m.range(at: 1)
                blank(NSRange(location: m.range.location, length: 1))
                blank(NSRange(location: inner.upperBound, length: m.range.upperBound - inner.upperBound))
            }
            matches(#"https?://[^\s)>\]]+"#, []).forEach { blank($0.range) }
            matches(#"`[^`\n]+`"#, []).forEach { blank($0.range) }
            // Emphasis markers adjacent to text.
            matches(#"(?<![\p{L}\p{N}\\])(\*{1,3}|_{1,3}|~~)(?=\S)"#, []).forEach { blank($0.range(at: 1)) }
            matches(#"(?<=\S)(\*{1,3}|_{1,3}|~~)(?![\p{L}\p{N}])"#, []).forEach { blank($0.range(at: 1)) }

            // Block markers: record list items and quotes, then blank the markers.
            for m in matches(#"^([ \t]*(?:[-*+]|\d{1,3}[.)])[ \t]+)(?:\[[ xX]\][ \t]+)?"#) {
                blank(m.range)
                blockStarts.append((m.range.location, .listItem))
            }
            for m in matches(#"^[ \t]*(?:>[ \t]?)+"#) {
                blank(m.range)
                blockStarts.append((m.range.location, .quote))
            }

        }
        headings = hs

        let maskedText = String(utf16CodeUnits: units, count: units.count)
        masked = maskedText
        let mns = maskedText as NSString
        // Split into blocks: blank lines end a block; a list item or quote line starts one.
        let startKinds = Dictionary(blockStarts.map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })
        var blocks: [Block] = []
        var cur: (start: Int, end: Int, kind: Block.Kind)?
        var lineStart = 0
        func close() {
            if let c = cur {
                let r = Self.trim(NSRange(location: c.start, length: c.end - c.start), in: mns)
                if r.length > 0 { blocks.append(Block(kind: c.kind, range: TextSpan(r))) }
            }
            cur = nil
        }
        while lineStart < mns.length {
            let lineRange = mns.lineRange(for: NSRange(location: lineStart, length: 0))
            let line = mns.substring(with: lineRange)
            let isBlank = line.allSatisfy { $0.isWhitespace }
            if isBlank {
                close()
            } else if let kind = startKinds[lineStart] {
                if kind == .quote, cur?.kind == .quote {
                    cur?.end = lineRange.upperBound
                } else {
                    close()
                    cur = (lineStart, lineRange.upperBound, kind)
                }
            } else if cur == nil {
                cur = (lineStart, lineRange.upperBound, .paragraph)
            } else {
                cur?.end = lineRange.upperBound
            }
            lineStart = lineRange.upperBound
        }
        close()
        self.blocks = blocks

        // Sentences and words.
        var sentences: [Sentence] = []
        var allWords: [TextSpan] = []
        for (bi, block) in blocks.enumerated() {
            for sr in Self.splitSentences(block.range.nsRange, in: mns) {
                let w = Self.words(in: sr, of: mns)
                guard !w.isEmpty else { continue }
                sentences.append(Sentence(range: TextSpan(sr), blockIndex: bi, words: w))
                allWords.append(contentsOf: w)
            }
        }
        self.sentences = sentences
        self.words = allWords
    }

    // MARK: - Tokenization

    static let wordRegex = try! NSRegularExpression(pattern: #"[\p{L}\p{N}]+(?:['’\-][\p{L}\p{N}]+)*"#)

    public static func words(in range: NSRange, of ns: NSString) -> [TextSpan] {
        wordRegex.matches(in: ns as String, range: range).map { TextSpan($0.range) }
    }

    static let abbreviations: Set<String> = [
        "a.m", "p.m", "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "vs", "etc", "e.g", "i.e", "cf", "al",
        "fig", "no", "vol", "approx", "inc", "ltd", "co", "u.s", "jan", "feb", "mar", "apr", "jun",
        "jul", "aug", "sep", "sept", "oct", "nov", "dec",
    ]

    static func trim(_ r: NSRange, in ns: NSString) -> NSRange {
        var s = r.location, e = r.upperBound
        let ws = CharacterSet.whitespacesAndNewlines
        while s < e, let u = UnicodeScalar(ns.character(at: s)), ws.contains(u) { s += 1 }
        while e > s, let u = UnicodeScalar(ns.character(at: e - 1)), ws.contains(u) { e -= 1 }
        return NSRange(location: s, length: e - s)
    }

    /// Sentence boundaries: terminal punctuation (plus closing quotes or
    /// brackets) followed by whitespace, except after common abbreviations,
    /// initials and decimals.
    public static func splitSentences(_ range: NSRange, in ns: NSString) -> [NSRange] {
        var out: [NSRange] = []
        var start = range.location
        let end = range.upperBound
        var i = range.location
        let closers: Set<UInt16> = Set("\"'”’)]".utf16)
        let terminators: Set<UInt16> = Set(".!?…".utf16)
        while i < end {
            let c = ns.character(at: i)
            if terminators.contains(c) {
                var j = i + 1
                while j < end, terminators.contains(ns.character(at: j)) || closers.contains(ns.character(at: j)) { j += 1 }
                let atWhitespace = j >= end || (UnicodeScalar(ns.character(at: j)).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false)
                if atWhitespace && !(c == 0x2E && isAbbreviation(before: i, from: start, in: ns)) {
                    let r = trim(NSRange(location: start, length: j - start), in: ns)
                    if r.length > 0 { out.append(r) }
                    start = j
                }
                i = j
            } else {
                i += 1
            }
        }
        let tail = trim(NSRange(location: start, length: end - start), in: ns)
        if tail.length > 0 { out.append(tail) }
        return out
    }

    static func isAbbreviation(before dot: Int, from start: Int, in ns: NSString) -> Bool {
        var k = dot
        while k > start, let u = UnicodeScalar(ns.character(at: k - 1)),
              CharacterSet.letters.contains(u) || u == "." { k -= 1 }
        let token = ns.substring(with: NSRange(location: k, length: dot - k)).lowercased()
        if token.isEmpty { return false }
        if token.count == 1, token.first!.isLetter { return true } // initials: "J. Smith"
        return abbreviations.contains(token)
    }
}

public extension String {
    /// UTF-16 length, the unit used by every TextSpan.
    var utf16Length: Int { utf16.count }
}
