// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import TersoCore

/// Index literal fields without expanding TeX or executing bibliography styles.
enum BibTeXIndex {
    static func entries(_ source: String, at url: URL) -> [ManuscriptCitation] {
        let ns = source as NSString, u = Array(source.utf16), lines = ManuscriptLines(source)
        let snapshot = DocumentSnapshot(revision: .init(0), text: source)
        var i = 0, result: [ManuscriptCitation] = []
        func space(_ c: UInt16) -> Bool { c <= 32 }
        func skipSpace() {
            while i < u.count {
                if space(u[i]) || u[i] == 44 { i += 1 }
                else if u[i] == 37 { while i < u.count && u[i] != 10 { i += 1 } }
                else { break }
            }
        }
        func readValue() -> String {
            guard i < u.count else { return "" }
            let opening = u[i]
            if opening == 123 || opening == 34 || opening == 40 {
                let closing: UInt16 = opening == 123 ? 125 : opening == 40 ? 41 : 34
                var depth = 1, braces = 0
                i += 1
                let start = i
                while i < u.count {
                    let c = u[i]
                    if c == 92 { i = min(i + 2, u.count); continue }
                    if opening == 34 {
                        if c == 123 { braces += 1 }
                        if c == 125 { braces = max(braces - 1, 0) }
                        if c == closing && braces == 0 { depth = 0 }
                    } else if c == closing { depth -= 1 }
                    else if c == opening { depth += 1 }
                    if depth == 0 { break }
                    i += 1
                }
                let value = ns.substring(with: NSRange(location: start, length: i - start))
                if i < u.count { i += 1 }
                return value
            }
            let start = i
            while i < u.count && ![44, 125, 41, 35].contains(u[i]) && !space(u[i]) { i += 1 }
            return ns.substring(with: NSRange(location: start, length: i - start))
        }
        while i < u.count {
            skipSpace()
            guard i < u.count else { break }
            guard u[i] == 64 else { i += 1; continue }
            let entryStart = i
            i += 1
            let typeStart = i
            while i < u.count && ((65...90).contains(u[i]) || (97...122).contains(u[i])) { i += 1 }
            let type = ns.substring(with: NSRange(location: typeStart, length: i - typeStart)).lowercased()
            skipSpace()
            guard i < u.count, u[i] == 123 || u[i] == 40 else { continue }
            if ["comment", "preamble", "string"].contains(type) { _ = readValue(); continue }
            let end: UInt16 = u[i] == 123 ? 125 : 41
            i += 1
            skipSpace()
            let start = i
            while i < u.count && u[i] != 44 && u[i] != end && !space(u[i]) { i += 1 }
            let keyRange = NSRange(location: start, length: i - start)
            guard keyRange.length > 0 else { continue }
            let key = ns.substring(with: keyRange)
            var fields: [String: String] = [:]
            while i < u.count {
                skipSpace()
                if i >= u.count || u[i] == end || u[i] == 64 { break }
                let fieldStart = i
                while i < u.count && u[i] != 61 && u[i] != end && u[i] != 44 && u[i] != 64 { i += 1 }
                guard i < u.count, u[i] == 61 else { continue }
                let field = ns.substring(with: NSRange(location: fieldStart, length: i - fieldStart)).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                i += 1
                while i < u.count && space(u[i]) { i += 1 }
                var value = readValue()
                while i < u.count {
                    while i < u.count && space(u[i]) { i += 1 }
                    guard i < u.count && u[i] == 35 else { break }
                    i += 1
                    while i < u.count && space(u[i]) { i += 1 }
                    value += readValue()
                }
                if ["title", "author", "editor"].contains(field) {
                    fields[field] = value.filter { $0 != "{" && $0 != "}" }.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                }
            }
            if i < u.count, u[i] == end { i += 1 }
            result.append(.init(key: key, author: fields["author"] ?? fields["editor"] ?? "", title: fields["title"] ?? "",
                location: .init(url: url, range: TextSpan(keyRange), line: lines.line(at: start), anchor: TextAnchor(range: TextSpan(keyRange), in: snapshot)), entryRange: TextSpan(location: entryStart, length: i - entryStart)))
        }
        return result
    }
}
