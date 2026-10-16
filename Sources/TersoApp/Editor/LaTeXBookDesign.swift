// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// A LaTeX book's design, kept in its own preamble as the options of the
/// terso-book package, which Terso writes beside the file:
///
///     \documentclass{book}
///     \usepackage[trim=6x9, typeface=baskerville, size=11, ...]{terso-book}
///
/// The keys are those a Markdown book keeps under `book:`. A document is set
/// up as a book when its preamble loads the package; keys left out take the
/// package's defaults, which are Terso's, and keys Terso doesn't know are
/// kept when the line is written again. The package itself leaves alone
/// whatever the preamble already sets (see terso-book.sty).
enum LaTeXBookDesign {
    static let package = "terso-book"

    /// The `\usepackage[…]{terso-book}` command in the preamble, and its
    /// options in order.
    struct Line {
        var range: NSRange
        var options: [Option]
    }

    struct Option: Equatable {
        var key: String
        var value: String
        /// As written, for keys Terso doesn't know and writes back as they were.
        var raw: String
    }

    private static let usepackage = try! NSRegularExpression(
        pattern: #"\\usepackage\s*(?:\[([^\]]*)\])?\s*\{\s*terso-book\s*\}"#)
    private static let documentclass = try! NSRegularExpression(
        pattern: #"\\documentclass\s*(?:\[([^\]]*)\])?\s*\{\s*([^}\s]*)\s*\}"#)
    private static let beginDocument = try! NSRegularExpression(pattern: #"\\begin\s*\{document\}"#)

    /// The text with every comment blanked to spaces, so that commented-out
    /// lines are never taken for the preamble's own, and ranges still match.
    static func uncommented(_ text: String) -> String {
        var units = Array(text.utf16)
        var i = 0, inComment = false
        while i < units.count {
            let c = units[i]
            if c == 10 || c == 13 { inComment = false }
            else if inComment { units[i] = 32 }
            else if c == 92 { i += 1 } // `\%` is a percent sign, `\\` a backslash
            else if c == 37 { inComment = true; units[i] = 32 }
            i += 1
        }
        return String(utf16CodeUnits: units, count: units.count)
    }

    /// The preamble's length: the text before `\begin{document}`, or all of
    /// it in a file that has none yet.
    private static func preambleLength(_ masked: String) -> Int {
        let ns = masked as NSString
        return beginDocument.firstMatch(in: masked, range: NSRange(location: 0, length: ns.length))?.range.location ?? ns.length
    }

    static func line(in text: String) -> Line? {
        let masked = uncommented(text)
        let preamble = NSRange(location: 0, length: preambleLength(masked))
        guard let m = usepackage.firstMatch(in: masked, range: preamble) else { return nil }
        let list = m.range(at: 1).location == NSNotFound ? "" : (text as NSString).substring(with: m.range(at: 1))
        return Line(range: m.range, options: options(list))
    }

    /// `key=value` pairs split at the commas outside braces, so that
    /// `matter={half-title, contents}` stays one option.
    static func options(_ list: String) -> [Option] {
        var items: [String] = [], current = "", depth = 0
        for ch in list {
            switch ch {
            case "{": depth += 1; current.append(ch)
            case "}": depth = max(0, depth - 1); current.append(ch)
            case "," where depth == 0: items.append(current); current = ""
            default: current.append(ch)
            }
        }
        items.append(current)
        return items.compactMap { item in
            let raw = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { return nil }
            let parts = raw.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            var value = parts.count == 2 ? parts[1] : ""
            if value.hasPrefix("{"), value.hasSuffix("}") { value = String(value.dropFirst().dropLast()) }
            return Option(key: parts[0].lowercased(), value: value, raw: raw)
        }
    }

    /// The command that loads the package with `design`, followed by the
    /// options Terso doesn't write, as they were.
    static func command(_ design: BookDesign, keeping existing: [Option] = []) -> String {
        let written = design.fields
        let known = Set(written.map(\.key))
        let options = written.map { "\($0.key)=\($0.key == "matter" ? "{\($0.value)}" : $0.value)" }
            + existing.filter { !known.contains($0.key) }.map(\.raw)
        return "\\usepackage[\(options.joined(separator: ", "))]{\(package)}"
    }

    /// The edit that writes `design` into the document's terso-book line,
    /// or nil when it has none or the line already says so.
    static func edit(of text: String, design: BookDesign) -> (range: NSRange, replacement: String)? {
        guard let line = line(in: text) else { return nil }
        let replacement = command(design, keeping: line.options)
        guard replacement != (text as NSString).substring(with: line.range) else { return nil }
        return (line.range, replacement)
    }

    /// The edit that sets a document up as a book: the terso-book line on
    /// the line after `\documentclass`, and `twoside` (or, for a report
    /// whose chapters open on the right, `openright`) among the class's
    /// options when the class doesn't already set its pages that way. Nil
    /// for a file without `\documentclass`, or one already set up.
    static func setupEdit(of text: String, design: BookDesign) -> (range: NSRange, replacement: String)? {
        guard line(in: text) == nil else { return nil }
        let masked = uncommented(text)
        let ns = text as NSString
        let preamble = NSRange(location: 0, length: preambleLength(masked))
        guard let m = documentclass.firstMatch(in: masked, range: preamble) else { return nil }
        let optionsRange = m.range(at: 1)
        var classOptions = optionsRange.location == NSNotFound ? [] : options(ns.substring(with: optionsRange)).map(\.key)
        let name = ns.substring(with: m.range(at: 2))
        var added: [String] = []
        // book is two-sided and opens chapters on the right already.
        if ["report", "article"].contains(name), !classOptions.contains("twoside"), !classOptions.contains("oneside") {
            added.append("twoside")
        }
        if name == "report", design.openers == .rightPage, !classOptions.contains("openright"), !classOptions.contains("openany") {
            added.append("openright")
        }
        classOptions += added
        // Through the end of \documentclass's line, rewritten.
        let lineEnd = NSMaxRange(ns.lineRange(for: m.range))
        let classLine = ns.substring(with: NSRange(location: m.range.location, length: lineEnd - m.range.location))
        var head = classLine
        if !added.isEmpty {
            let list = added.joined(separator: ",")
            if optionsRange.location == NSNotFound {
                head = (classLine as NSString).replacingCharacters(in: NSRange(location: "\\documentclass".utf16.count, length: 0), with: "[\(list)]")
            } else {
                let local = NSRange(location: optionsRange.location - m.range.location, length: optionsRange.length)
                let existing = (classLine as NSString).substring(with: local)
                let joined = existing.trimmingCharacters(in: .whitespaces).isEmpty ? list : existing + "," + list
                head = (classLine as NSString).replacingCharacters(in: local, with: joined)
            }
        }
        let endsLine = classLine.hasSuffix("\n")
        let replacement = (endsLine ? head : head + "\n") + command(design) + (endsLine ? "\n" : "")
        return (NSRange(location: m.range.location, length: lineEnd - m.range.location), replacement)
    }

    // MARK: - The package file

    /// The terso-book.sty Terso ships.
    static var bundledPackage: URL? {
        Bundle.module.url(forResource: "LaTeX", withExtension: nil)?.appendingPathComponent("\(package).sty")
    }

    enum Install: Equatable { case written, unchanged, kept }

    /// Puts terso-book.sty in `directory`: written when there is none, left
    /// alone when it is Terso's own, and kept when the writer has changed it.
    @discardableResult
    static func install(in directory: URL, from source: URL? = bundledPackage) throws -> Install {
        guard let source else { throw CocoaError(.fileNoSuchFile) }
        let target = directory.appendingPathComponent("\(package).sty")
        let ours = try Data(contentsOf: source)
        if let theirs = try? Data(contentsOf: target) { return theirs == ours ? .unchanged : .kept }
        try ours.write(to: target, options: .atomic)
        return .written
    }
}

extension BookDesign {
    /// The design a LaTeX document's preamble gives terso-book, or nil when
    /// it doesn't load the package. Keys left out are the package's own
    /// defaults — Terso's — apart from what only the screen uses.
    static func read(latex text: String, defaults: BookDesign) -> BookDesign? {
        guard let line = LaTeXBookDesign.line(in: text) else { return nil }
        var base = BookDesign()
        base.facingPages = defaults.facingPages
        base.wordGoal = defaults.wordGoal
        let fields = Dictionary(line.options.map { ($0.key, $0.value) }, uniquingKeysWith: { _, last in last })
        return read(fields: fields, defaults: base)
    }
}
