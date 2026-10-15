// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Pandoc citations (`[@smith2020, p. 4]`, `@smith2020`) and pandoc-crossref
/// labels and references (`{#fig:plot}`, `@fig:plot`), for display only.
@MainActor enum PandocSyntax {
    /// `@key` or `-@key`. No word character, `@` or `.` may precede it, so
    /// e-mail addresses never match. Group 1: the marker, group 2: the key.
    static let citation = MarkdownStyler.re(#"(?<![\w@.])(-?@)([A-Za-z0-9_](?:[\w:.#$%&+?<>~/-]*\w)?)"#, [])
    /// A bracketed group of citations: `[@a; @b, p. 4]`.
    static let group = MarkdownStyler.re(#"\[(?!\^)([^\[\]\n]*?(?<![\w@.])-?@[^\[\]\n]*)\](?![(\[{:])"#, [])
    /// A pandoc-crossref label, with the space before it.
    static let label = MarkdownStyler.re(#"[ \t]*\{#((?:fig|tbl|eq|sec|lst):[\w:.-]+)[^}\n]*\}"#, [])

    static let prefixes = ["fig": "fig.", "tbl": "tbl.", "eq": "eq.", "sec": "sec.", "lst": "lst."]

    /// The lookup key of a citation match: its key with a lower-case prefix.
    static func target(of match: NSTextCheckingResult, in ns: NSString) -> String {
        let key = ns.substring(with: match.range(at: 2))
        guard let colon = key.firstIndex(of: ":") else { return key }
        return key[..<colon].lowercased() + key[colon...]
    }

    /// "fig. 2", or "Fig. 2" when the reference is written `@Fig:…`.
    static func display(key: String, number: String) -> String {
        let prefix = String(key.prefix { $0 != ":" })
        let word = prefixes[prefix.lowercased()] ?? prefix
        let capital = prefix.first?.isUppercase == true
        return (capital ? word.prefix(1).uppercased() + word.dropFirst() : word) + "\u{00A0}" + number
    }

    /// Numbers for every label, as pandoc-crossref would count them: figures,
    /// tables, equations and listings in order of appearance; sections by
    /// their place in the heading outline ("2.1").
    static func numbers(in text: String) -> [String: String] {
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)
        let fences = MarkdownStyler.fence.matches(in: text, range: all).map(\.range)
        func literal(_ r: NSRange) -> Bool { fences.contains { NSIntersectionRange($0, r).length > 0 } }
        var result: [String: String] = [:]
        var counters: [String: Int] = [:]
        var outline = [Int](repeating: 0, count: 6)
        var sectionAt: [Int: String] = [:]
        for heading in MarkdownStyler.heading.matches(in: text, range: all) where !literal(heading.range) {
            let level = heading.range(at: 1).length
            outline[level - 1] += 1
            for deeper in level..<6 { outline[deeper] = 0 }
            let parts = outline[..<level].drop { $0 == 0 }.map(String.init)
            sectionAt[heading.range.location] = parts.joined(separator: ".")
        }
        for match in label.matches(in: text, range: all) where !literal(match.range) {
            let key = ns.substring(with: match.range(at: 1))
            let prefix = String(key.prefix { $0 != ":" })
            if prefix == "sec" {
                let line = ns.lineRange(for: match.range)
                if let number = sectionAt[line.location] { result[key] = number }
            } else {
                counters[prefix, default: 0] += 1
                result[key] = String(counters[prefix]!)
            }
        }
        return result
    }
}
