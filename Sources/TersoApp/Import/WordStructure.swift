// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import TersoDocument

/// What AppKit's `.docx` reader drops: paragraph styles (headings, code,
/// quotes), list numbering and hyperlinks. Word and Google Docs carry all of
/// them as styles or package parts, so they are read straight from the
/// WordprocessingML, one paragraph per `w:p` in document order.
struct WordStructure: Equatable {
    struct Paragraph: Equatable {
        enum Role: Equatable { case body, heading(Int), code, quote }
        var role: Role = .body
        var list: List?
        /// The visible text, so paragraphs can be matched to AppKit's.
        var text = ""
        var links: [Link] = []
        var code: [NSRange] = []
    }
    struct List: Equatable {
        /// Word's `numId`: items of one list share it, across interruptions.
        var id: String
        var level: Int
        var ordered: Bool
        /// The number its first item shows at this level.
        var start = 1
    }
    struct Link: Equatable {
        var range: NSRange
        var url: String
    }

    var paragraphs: [Paragraph]

    init(paragraphs: [Paragraph]) { self.paragraphs = paragraphs }

    init(docx: Data) throws {
        let entries = try ZipArchive.entries(in: docx)
        guard let document = entries["word/document.xml"] else { throw CocoaError(.fileReadCorruptFile) }
        try self.init(document: document, styles: entries["word/styles.xml"],
                      numbering: entries["word/numbering.xml"], relationships: entries["word/_rels/document.xml.rels"])
    }

    init(document: Data, styles: Data? = nil, numbering: Data? = nil, relationships: Data? = nil) throws {
        let styles = styles.map(StyleSheet.init) ?? StyleSheet()
        let numbering = numbering.map(Numbering.init) ?? Numbering()
        let links = relationships.map(Self.externalTargets) ?? [:]
        let reader = DocumentReader(styles: styles, numbering: numbering, links: links)
        guard XML.parse(document, with: reader) else { throw CocoaError(.fileReadCorruptFile) }
        paragraphs = reader.paragraphs
    }

    private static func externalTargets(_ data: Data) -> [String: String] {
        var targets: [String: String] = [:]
        XML.walk(data) { name, attributes in
            guard name == "Relationship", attributes["TargetMode"] == "External",
                  let id = attributes["Id"], let target = attributes["Target"] else { return }
            targets[id] = target
        }
        return targets
    }
}

// MARK: - Styles and numbering

private struct StyleSheet {
    struct Style {
        var name = ""
        var basedOn: String?
        var outline: Int?
        var numID: String?
        var level: Int?
    }
    var styles: [String: Style] = [:]

    init() {}
    init(_ data: Data) {
        var styles: [String: Style] = [:], current: String?
        XML.walk(data) { name, attributes in
            switch name {
            case "style": current = attributes["styleId"]; if let current { styles[current] = Style() }
            case "name": if let current { styles[current]?.name = attributes["val"] ?? "" }
            case "basedOn": if let current { styles[current]?.basedOn = attributes["val"] }
            case "outlineLvl": if let current { styles[current]?.outline = attributes["val"].flatMap(Int.init) }
            case "numId": if let current { styles[current]?.numID = attributes["val"] }
            case "ilvl": if let current { styles[current]?.level = attributes["val"].flatMap(Int.init) }
            default: break
            }
        }
        self.styles = styles
    }

    /// The style and the ones it is based on, nearest first.
    private func chain(_ id: String?) -> [Style] {
        var result: [Style] = [], next = id
        while let id = next, let style = styles[id], result.count < 16 {
            result.append(style)
            next = style.basedOn
        }
        return result
    }

    func role(of id: String?) -> WordStructure.Paragraph.Role {
        for style in chain(id) {
            let name = style.name.lowercased()
            if name == "title" { return .heading(1) }
            if name.hasPrefix("heading "), let level = Int(name.dropFirst(8)) { return .heading(min(max(level, 1), 6)) }
            if let outline = style.outline, outline < 9 { return .heading(min(outline + 1, 6)) }
            if ["code", "preformatted", "verbatim"].contains(where: name.contains) { return .code }
            if name.contains("quote") || name == "block text" { return .quote }
        }
        return .body
    }

    func numbering(of id: String?) -> (id: String, level: Int?)? {
        chain(id).lazy.compactMap { style in style.numID.map { ($0, style.level) } }.first
    }

    func isCode(character id: String?) -> Bool {
        chain(id).contains { style in
            ["code", "verbatim", "typewriter", "keyboard"].contains(where: style.name.lowercased().contains)
        }
    }
}

private struct Numbering {
    /// `numId` → `abstractNumId`, and each abstract list's format and start
    /// per level; a `numId` may override the start.
    var abstractIDs: [String: String] = [:]
    var formats: [String: [Int: String]] = [:]
    var starts: [String: [Int: Int]] = [:]
    var startOverrides: [String: [Int: Int]] = [:]

    init() {}
    init(_ data: Data) {
        var abstractIDs: [String: String] = [:], formats: [String: [Int: String]] = [:]
        var starts: [String: [Int: Int]] = [:], startOverrides: [String: [Int: Int]] = [:]
        var abstract: String?, num: String?, level: Int?
        XML.walk(data) { name, attributes in
            switch name {
            case "abstractNum": abstract = attributes["abstractNumId"]; num = nil
            case "num": num = attributes["numId"]; abstract = nil
            case "abstractNumId": if let num { abstractIDs[num] = attributes["val"] }
            case "lvl": level = attributes["ilvl"].flatMap(Int.init)
            case "lvlOverride": level = attributes["ilvl"].flatMap(Int.init)
            case "numFmt":
                if let abstract, let level { formats[abstract, default: [:]][level] = attributes["val"] }
            case "start":
                if let abstract, let level { starts[abstract, default: [:]][level] = attributes["val"].flatMap(Int.init) }
            case "startOverride":
                if let num, let level { startOverrides[num, default: [:]][level] = attributes["val"].flatMap(Int.init) }
            default: break
            }
        }
        self.abstractIDs = abstractIDs
        self.formats = formats
        self.starts = starts
        self.startOverrides = startOverrides
    }

    func ordered(_ id: String, level: Int) -> Bool {
        let format = abstractIDs[id].flatMap { formats[$0]?[level] } ?? "bullet"
        return format != "bullet" && format != "none"
    }

    func start(_ id: String, level: Int) -> Int {
        startOverrides[id]?[level] ?? abstractIDs[id].flatMap { starts[$0]?[level] } ?? 1
    }
}

// MARK: - Document

private final class DocumentReader: NSObject, XMLParserDelegate {
    let styles: StyleSheet
    let numbering: Numbering
    let links: [String: String]
    private(set) var paragraphs: [WordStructure.Paragraph] = []

    /// Open paragraphs: a text box inside a run nests one `w:p` in another.
    private var open: [Open] = []
    private struct Open {
        var paragraph = WordStructure.Paragraph()
        var style: String?
        var outline: Int?
        var numID: String?
        var level: Int?
        var links: [(start: Int, url: String?)] = []
        var fields: [Field] = []
        var runStart = 0
        var runCode = false
        var length: Int { paragraph.text.utf16.count }
    }
    /// A complex field (`fldChar`): its instruction, then its displayed result.
    private struct Field {
        var instruction = ""
        var url: String?
        var start: Int?
    }

    private var inProperties = false, inRun = false, collecting: Collecting?
    private enum Collecting { case text, instruction }

    init(styles: StyleSheet, numbering: Numbering, links: [String: String]) {
        self.styles = styles
        self.numbering = numbering
        self.links = links
    }

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        let name = XML.local(element), attributes = XML.local(attributes)
        if name == "p" { open.append(Open()); return }
        guard !open.isEmpty else { return }
        let last = open.count - 1
        switch name {
        case "pPr": inProperties = true
        case "pStyle" where inProperties: open[last].style = attributes["val"]
        case "outlineLvl" where inProperties: open[last].outline = attributes["val"].flatMap(Int.init)
        case "numId" where inProperties: open[last].numID = attributes["val"]
        case "ilvl" where inProperties: open[last].level = attributes["val"].flatMap(Int.init)
        case "r":
            inRun = true
            open[last].runStart = open[last].length
            open[last].runCode = false
        case "rStyle" where inRun: if styles.isCode(character: attributes["val"]) { open[last].runCode = true }
        case "rFonts" where inRun: if XML.isMonospaced(attributes["ascii"] ?? attributes["hAnsi"]) { open[last].runCode = true }
        case "t" where inRun: collecting = .text
        case "instrText": collecting = .instruction
        case "tab" where inRun: open[last].paragraph.text += "\t"
        case "br" where inRun, "cr" where inRun: open[last].paragraph.text += "\u{2028}"
        case "hyperlink": open[last].links.append((open[last].length, attributes["id"].flatMap { links[$0] }))
        case "fldSimple":
            open[last].fields.append(Field(url: XML.hyperlink(in: attributes["instr"] ?? ""), start: open[last].length))
        case "fldChar":
            switch attributes["fldCharType"] {
            case "begin": open[last].fields.append(Field())
            case "separate":
                guard var field = open[last].fields.popLast() else { break }
                field.url = XML.hyperlink(in: field.instruction)
                field.start = open[last].length
                open[last].fields.append(field)
            case "end": closeField(last)
            default: break
            }
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        let name = XML.local(element)
        guard !open.isEmpty else { return }
        let last = open.count - 1
        switch name {
        case "p": finish(open.removeLast())
        case "pPr": inProperties = false
        case "t", "instrText": collecting = nil
        case "r":
            inRun = false
            let run = NSRange(location: open[last].runStart, length: open[last].length - open[last].runStart)
            guard open[last].runCode, run.length > 0 else { break }
            if let previous = open[last].paragraph.code.last, NSMaxRange(previous) == run.location {
                open[last].paragraph.code[open[last].paragraph.code.count - 1] = NSUnionRange(previous, run)
            } else {
                open[last].paragraph.code.append(run)
            }
        case "hyperlink":
            guard let link = open[last].links.popLast(), let url = link.url else { break }
            addLink(url, from: link.start, in: last)
        case "fldSimple": closeField(last)
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard let collecting, !open.isEmpty else { return }
        switch collecting {
        case .text: open[open.count - 1].paragraph.text += string
        case .instruction:
            guard !open[open.count - 1].fields.isEmpty else { return }
            open[open.count - 1].fields[open[open.count - 1].fields.count - 1].instruction += string
        }
    }

    private func closeField(_ index: Int) {
        guard let field = open[index].fields.popLast(), let url = field.url, let start = field.start else { return }
        addLink(url, from: start, in: index)
    }

    private func addLink(_ url: String, from start: Int, in index: Int) {
        let range = NSRange(location: start, length: open[index].length - start)
        if range.length > 0 { open[index].paragraph.links.append(WordStructure.Link(range: range, url: url)) }
    }

    private func finish(_ item: Open) {
        var paragraph = item.paragraph
        paragraph.role = styles.role(of: item.style)
        if let outline = item.outline, outline < 9, paragraph.role == .body { paragraph.role = .heading(min(outline + 1, 6)) }
        // A direct `numId` of 0 removes the numbering a style would add.
        let inherited = styles.numbering(of: item.style)
        if let id = item.numID ?? inherited?.id, id != "0", case .body = paragraph.role {
            let level = min(max(item.level ?? inherited?.level ?? 0, 0), 8)
            paragraph.list = WordStructure.List(id: id, level: level, ordered: numbering.ordered(id, level: level),
                                                start: numbering.start(id, level: level))
        }
        paragraphs.append(paragraph)
    }
}

// MARK: - XML helpers

private enum XML {
    static func parse(_ data: Data, with delegate: XMLParserDelegate) -> Bool {
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        return parser.parse()
    }

    /// Visits every element's start tag; enough for the flat style and numbering parts.
    static func walk(_ data: Data, _ visit: @escaping (String, [String: String]) -> Void) {
        _ = parse(data, with: Walker(visit))
    }

    private final class Walker: NSObject, XMLParserDelegate {
        let visit: (String, [String: String]) -> Void
        init(_ visit: @escaping (String, [String: String]) -> Void) { self.visit = visit }
        func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            visit(local(element), local(attributes))
        }
    }

    /// WordprocessingML is always namespaced, but its prefix is a convention.
    static func local(_ name: String) -> String {
        name.firstIndex(of: ":").map { String(name[name.index(after: $0)...]) } ?? name
    }

    static func local(_ attributes: [String: String]) -> [String: String] {
        Dictionary(attributes.map { (local($0.key), $0.value) }) { first, _ in first }
    }

    /// `HYPERLINK "https://…" \o "tip"`; a `\l` bookmark link has no URL.
    static func hyperlink(in instruction: String) -> String? {
        let words = instruction.trimmingCharacters(in: .whitespaces)
        guard words.uppercased().hasPrefix("HYPERLINK"), !words.contains("\\l"),
              let open = words.firstIndex(of: "\"") else { return nil }
        let rest = words[words.index(after: open)...]
        guard let close = rest.firstIndex(of: "\""), close > rest.startIndex else { return nil }
        return String(rest[..<close])
    }

    static func isMonospaced(_ font: String?) -> Bool {
        guard let font = font?.lowercased() else { return false }
        return ["courier", "consolas", "menlo", "monaco", "mono", "code"].contains(where: font.contains)
    }
}
