// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import TersoCore

/// A book's design kept in its own Markdown, under a `book:` key of the YAML
/// metadata, so the file says how it is to be set and stays plain Markdown
/// any editor opens:
///
///     ---
///     title: "The Keeper's Daughter"
///     book:
///       trim: 6x9
///       typeface: baskerville
///       size: 11
///     ---
///
/// Keys left out take Terso's defaults; keys and values it does not know are
/// ignored, and kept when the block is written again.
extension BookDesign {
    /// The design a document carries, or nil when it has no `book:` key.
    @MainActor static func read(from text: String, defaults: BookDesign) -> BookDesign? {
        guard let fields = BookBlock.fields(in: text) else { return nil }
        var d = defaults
        func value<T>(_ key: String, _ parse: (String) -> T?) -> T? { fields[key].flatMap(parse) }
        d.trim = value("trim", BookTrim.init(yaml:)) ?? d.trim
        // `editor`, or a face Terso lacks, sets the book in the editor's font.
        if let face = fields["typeface"] { d.typeface = EditorFont(yaml: face) }
        d.typeSize = value("size", Double.init) ?? d.typeSize
        d.lineSpacing = value("line-spacing", Double.init) ?? d.lineSpacing
        d.paragraphs = value("paragraphs", BookParagraphs.init(yaml:)) ?? d.paragraphs
        d.indent = value("indent", Double.init) ?? d.indent
        d.justify = value("justify", Bool.init(yaml:)) ?? d.justify
        d.hyphenate = value("hyphenate", Bool.init(yaml:)) ?? d.hyphenate
        d.facingPages = value("facing-pages", Bool.init(yaml:)) ?? d.facingPages
        d.headings = value("headings", ChapterHeadingStyle.init(yaml:)) ?? d.headings
        d.openers = value("chapters-start", ChapterOpener.init(yaml:)) ?? d.openers
        d.dropCaps = value("drop-caps", Bool.init(yaml:)) ?? d.dropCaps
        d.smallCapsOpening = value("small-caps-opening", Bool.init(yaml:)) ?? d.smallCapsOpening
        d.sceneBreak = value("scene-break", SceneBreak.init(yaml:)) ?? d.sceneBreak
        d.runningHeads = value("running-heads", RunningHeads.init(yaml:)) ?? d.runningHeads
        d.folios = value("page-numbers", FolioPosition.init(yaml:)) ?? d.folios
        d.matter = value("matter") { list in Set(BookBlock.list(list).compactMap(MatterPage.init(yaml:))) } ?? d.matter
        d.wordGoal = value("word-goal") { Int($0.replacingOccurrences(of: "_", with: "")) } ?? d.wordGoal
        return d
    }

    /// The `book:` block as written into the metadata, every key spelled out
    /// so the writer can see and change each one.
    var yaml: [String] {
        [
            "book:",
            "  trim: \(trim.yaml)",
            "  typeface: \(typeface?.yaml ?? "editor")",
            "  size: \(Self.number(typeSize))",
            "  line-spacing: \(Self.number(lineSpacing))",
            "  paragraphs: \(paragraphs.yaml)",
            "  indent: \(Self.number(indent))",
            "  justify: \(justify)",
            "  hyphenate: \(hyphenate)",
            "  facing-pages: \(facingPages)",
            "  headings: \(headings.yaml)",
            "  chapters-start: \(openers.yaml)",
            "  drop-caps: \(dropCaps)",
            "  small-caps-opening: \(smallCapsOpening)",
            "  scene-break: \(sceneBreak.yaml)",
            "  running-heads: \(runningHeads.yaml)",
            "  page-numbers: \(folios.yaml)",
            "  matter: [\(MatterPage.allCases.filter(matter.contains).map(\.yaml).joined(separator: ", "))]",
            "  word-goal: \(wordGoal)",
        ]
    }

    private static func number(_ v: Double) -> String {
        v.formatted(.number.precision(.fractionLength(0...2)).grouping(.never).locale(Locale(identifier: "en_US_POSIX")))
    }

    /// The edit that writes this design into the text's `book:` block,
    /// replacing one already there, or adding metadata when there is none.
    @MainActor func edit(of text: String) -> (range: NSRange, replacement: String)? {
        BookBlock.edit(of: text, block: yaml)
    }
}

/// The `book:` block within YAML metadata: a key on its own line and the
/// indented `key: value` lines under it.
enum BookBlock {
    /// The block's lines within the metadata's lines (delimiters excluded).
    static func span(in lines: [String]) -> Range<Int>? {
        guard let start = lines.firstIndex(where: { $0.range(of: #"^book[ \t]*:[ \t]*$"#, options: .regularExpression) != nil }) else { return nil }
        var end = start + 1
        while end < lines.count, lines[end].first == " " || lines[end].first == "\t" || lines[end].isEmpty { end += 1 }
        // A blank line after the block belongs to what follows it.
        while end > start + 1, lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty { end -= 1 }
        return start..<end
    }

    /// The metadata's lines between its delimiters, when it is YAML.
    @MainActor static func metadataLines(_ text: String) -> (range: NSRange, opening: String, lines: [String], closing: String, newline: Bool)? {
        guard let fm = MarkdownSyntax.frontMatter(in: text) else { return nil }
        let block = (text as NSString).substring(with: fm)
        var lines = block.components(separatedBy: "\n")
        let newline = lines.last == ""
        if newline { lines.removeLast() }
        guard lines.count >= 2, lines[0].hasPrefix("---") else { return nil }
        let opening = lines.removeFirst()
        let closing = lines.removeLast()
        return (fm, opening, lines, closing, newline)
    }

    @MainActor static func fields(in text: String) -> [String: String]? {
        guard let meta = metadataLines(text), let span = span(in: meta.lines) else { return nil }
        var fields: [String: String] = [:]
        for line in meta.lines[span].dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty else { continue }
            var value = parts[1]
            if let hash = value.range(of: " #") { value = String(value[..<hash.lowerBound]).trimmingCharacters(in: .whitespaces) }
            if value.count >= 2, let q = value.first, q == "\"" || q == "'", value.last == q { value = String(value.dropFirst().dropLast()) }
            fields[parts[0].lowercased()] = value
        }
        return fields
    }

    /// The key of an indented `key: value` line.
    private static func key(_ line: String) -> String? {
        let parts = line.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, line.first == " " || line.first == "\t" else { return nil }
        let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
        return key.isEmpty ? nil : key
    }

    /// `[a, b, c]` or `a, b, c`.
    static func list(_ value: String) -> [String] {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")).split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
            .filter { !$0.isEmpty }
    }

    @MainActor static func edit(of text: String, block: [String]) -> (range: NSRange, replacement: String)? {
        if let meta = metadataLines(text) {
            var lines = meta.lines
            if let span = span(in: lines) {
                // Keys Terso doesn't write — the writer's own, or a newer
                // Terso's — stay in the block.
                let written = Set(block.dropFirst().compactMap(key))
                let kept = lines[span].dropFirst().filter { key($0).map { !written.contains($0) } ?? false }
                lines.replaceSubrange(span, with: block + kept)
            } else { lines += block }
            guard lines != meta.lines else { return nil }
            let joined = ([meta.opening] + lines + [meta.closing]).joined(separator: "\n") + (meta.newline ? "\n" : "")
            return (meta.range, joined)
        }
        // TOML metadata (`+++`) is left as it is: a book block is YAML.
        guard MarkdownSyntax.frontMatter(in: text) == nil else { return nil }
        return (NSRange(location: 0, length: 0), (["---"] + block + ["---"]).joined(separator: "\n") + "\n\n")
    }

    /// Several edits to the metadata as one: the text up to the end of the
    /// old metadata, replaced by what the edits made of it.
    static func combine(_ text: String, _ edits: [(range: NSRange, replacement: String)?]) -> (range: NSRange, replacement: String)? {
        var result = text as NSString
        var changed = false
        for edit in edits.compactMap({ $0 }) {
            result = result.replacingCharacters(in: edit.range, with: edit.replacement) as NSString
            changed = true
        }
        guard changed else { return nil }
        let ns = text as NSString
        // The edits only touch the metadata at the top: the rest is the same.
        var suffix = 0
        while suffix < ns.length, suffix < result.length,
              ns.character(at: ns.length - 1 - suffix) == result.character(at: result.length - 1 - suffix) { suffix += 1 }
        return (NSRange(location: 0, length: ns.length - suffix), result.substring(to: result.length - suffix))
    }
}

// MARK: - YAML names

/// Options are written in kebab case: `rightPage` is `right-page`.
private protocol YAMLNamed: RawRepresentable, CaseIterable where RawValue == String {}
extension YAMLNamed {
    var yaml: String { rawValue.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1-$2", options: .regularExpression).lowercased() }
    init?(yaml: String) {
        let key = yaml.lowercased().replacingOccurrences(of: "_", with: "-").replacingOccurrences(of: " ", with: "-")
        guard let match = Self.allCases.first(where: { $0.yaml == key }) else { return nil }
        self = match
    }
}

extension ChapterOpener: YAMLNamed {}
extension ChapterHeadingStyle: YAMLNamed {}
extension SceneBreak: YAMLNamed {}
extension RunningHeads: YAMLNamed {}
extension FolioPosition: YAMLNamed {}
extension BookParagraphs: YAMLNamed {}
extension MatterPage: YAMLNamed {}
extension EditorFont: YAMLNamed {}

extension BookTrim {
    /// Inches as printers write them: `6x9`, `5.5x8.5`.
    var yaml: String {
        let i = inches
        let f = { (v: CGFloat) in v.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(v))" : "\(v)" }
        return "\(f(i.width))x\(f(i.height))"
    }
    init?(yaml: String) {
        let key = yaml.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "×", with: "x").replacingOccurrences(of: "in", with: "")
        guard let match = Self.allCases.first(where: { $0.yaml == key }) else { return nil }
        self = match
    }
}

private extension Bool {
    init?(yaml: String) {
        switch yaml.lowercased() {
        case "true", "yes", "on": self = true
        case "false", "no", "off": self = false
        default: return nil
        }
    }
}
