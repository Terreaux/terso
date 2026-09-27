// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

public enum ScientificRegionKind: String, Codable, Sendable {
    case prose, inlineMath, displayMath, command, citation, reference, code, comment
}

public struct ScientificRegion: Sendable, Hashable, Codable {
    public let kind: ScientificRegionKind
    public let range: TextSpan
    public let contentRange: TextSpan
    public let rawText: String
    public let normalizedContent: String
    public let revision: DocumentRevision
}

/// A bounded structural scanner, never a TeX interpreter. Regions partition
/// the source; offsets always refer to the original UTF-16 document.
public struct ScientificSyntax: Sendable {
    public let regions: [ScientificRegion]
    public let maskedProse: String

    public init(_ snapshot: DocumentSnapshot) {
        let ns = snapshot.text as NSString
        let u = Array(snapshot.text.utf16)
        var masked = u
        var result: [ScientificRegion] = []
        func has(_ s: String, _ i: Int) -> Bool {
            let v = Array(s.utf16)
            return i + v.count <= u.count && u[i..<i + v.count].elementsEqual(v)
        }
        func escaped(_ i: Int) -> Bool {
            var j = i, count = 0
            while j > 0 && u[j - 1] == 92 { count += 1; j -= 1 }
            return count % 2 == 1
        }
        func lineEnd(_ i: Int) -> Int {
            var j = i
            while j < u.count && u[j] != 10 && u[j] != 13 { j += 1 }
            return j
        }
        func groupEnd(_ i: Int, open: UInt16 = 123, close: UInt16 = 125) -> Int? {
            guard i < u.count, u[i] == open else { return nil }
            var depth = 0, j = i
            while j < u.count {
                if !escaped(j) {
                    if u[j] == open { depth += 1 }
                    if u[j] == close { depth -= 1; if depth == 0 { return j + 1 } }
                }
                j += 1
            }
            return nil
        }
        func emit(_ kind: ScientificRegionKind, _ start: Int, _ end: Int, _ content: NSRange? = nil) {
            guard end > start else { return }
            let r = NSRange(location: start, length: end - start)
            let c = content ?? r
            result.append(ScientificRegion(kind: kind, range: TextSpan(r), contentRange: TextSpan(c),
                rawText: ns.substring(with: r), normalizedContent: ns.substring(with: c).trimmingCharacters(in: .whitespacesAndNewlines), revision: snapshot.revision))
            if kind != .prose {
                for k in start..<end where u[k] != 10 && u[k] != 13 { masked[k] = 32 }
            }
        }
        var i = 0, proseStart = 0
        func flush(_ end: Int) { emit(.prose, proseStart, end) }
        let mathEnvironments: Set<String> = ["equation", "equation*", "align", "align*", "gather", "gather*", "multline", "multline*", "displaymath", "math"]
        let transparent: Set<String> = ["emph", "textbf", "textit", "textrm", "text", "footnote", "caption", "underline"]
        while i < u.count {
            let start = i
            // Code takes precedence over all TeX syntax.
            if (i == 0 || u[i - 1] == 10), let m = try! NSRegularExpression(pattern: #"^[ \t]*(`{3,}|~{3,})[^\n]*(?:\n|$)"#).firstMatch(in: snapshot.text, options: .anchored, range: NSRange(location: i, length: u.count - i)) {
                let fence = ns.substring(with: m.range(at: 1))
                var end = m.range.upperBound
                while end < u.count {
                    let e = lineEnd(end)
                    let line = ns.substring(with: NSRange(location: end, length: e - end)).trimmingCharacters(in: .whitespaces)
                    if line.count >= fence.count && line.allSatisfy({ $0 == fence.first! }) { end = e; break }
                    end = min(u.count, e + 1)
                }
                flush(i); emit(.code, i, end); i = end; proseStart = i; continue
            }
            if u[i] == 96 {
                var count = 1
                while i + count < u.count && u[i + count] == 96 { count += 1 }
                let marker = String(repeating: "`", count: count)
                var end = i + count
                while end < lineEnd(i) && !has(marker, end) { end += 1 }
                if has(marker, end) { end += count }
                flush(i); emit(.code, i, end); i = end; proseStart = i; continue
            }
            // Markdown scientific prose commonly uses literal 2%. Preserve that
            // form; other unescaped percent signs start TeX comments.
            if u[i] == 37 && !escaped(i) && !(i > 0 && (48...57).contains(u[i - 1])) {
                let end = lineEnd(i)
                flush(i); emit(.comment, i, end); i = end; proseStart = i; continue
            }
            var opening: String?, closing: String?, kind = ScientificRegionKind.inlineMath
            if !escaped(i) {
                if has("$$", i) { opening = "$$"; closing = "$$"; kind = .displayMath }
                else if has(#"\("#, i) { opening = #"\("#; closing = #"\)"# }
                else if has(#"\["#, i) { opening = #"\["#; closing = #"\]"#; kind = .displayMath }
                else if u[i] == 36 && i + 1 < u.count && u[i + 1] != 32 && !(48...57).contains(u[i + 1]) { opening = "$"; closing = "$" }
                else if u[i] == 36 && i + 1 < u.count && (48...57).contains(u[i + 1]) {
                    // Numeric math needs a closing delimiter, unlike currency.
                    let tail = ns.substring(with: NSRange(location: i + 1, length: lineEnd(i) - i - 1))
                    if let match = try! NSRegularExpression(pattern: #"^[^$\n]*?(?<![\s\\])\$(?![\p{N}])"#).firstMatch(in: tail, range: NSRange(location: 0, length: tail.utf16.count)), match.range.length > 1 { opening = "$"; closing = "$" }
                }
                else if has(#"\begin{"#, i), let end = groupEnd(i + 6) {
                    let env = ns.substring(with: NSRange(location: i + 7, length: end - i - 8))
                    if mathEnvironments.contains(env) { opening = ns.substring(with: NSRange(location: i, length: end - i)); closing = "\\end{\(env)}"; kind = env == "math" ? .inlineMath : .displayMath }
                }
            }
            if let opening, let closing {
                let begin = i + opening.utf16.count
                var end = begin
                var limit = u.count
                if kind == .inlineMath {
                    // Permit wrapped inline formulae when a closer is present
                    // before a paragraph break; unfinished input recovers at EOL.
                    let tail = ns.substring(from: begin)
                    let boundary = try! NSRegularExpression(pattern: #"\r?\n[ \t]*\r?\n|\r?\n[ \t]*(?:```|~~~)"#)
                        .firstMatch(in: tail, range: NSRange(location: 0, length: tail.utf16.count))
                    let paragraphEnd = boundary.map { begin + $0.range.location } ?? u.count
                    var candidate = begin
                    while candidate < paragraphEnd && !(has(closing, candidate) && !escaped(candidate)) { candidate += 1 }
                    limit = candidate < paragraphEnd ? paragraphEnd : lineEnd(begin)
                }
                while end < limit {
                    if has(closing, end) && !escaped(end) { break }
                    // A commented-out delimiter must not terminate math.
                    if u[end] == 37 && !escaped(end) { end = lineEnd(end); if end < limit { end += 1 }; continue }
                    end += 1
                }
                let contentEnd = min(end, limit)
                let finish = has(closing, contentEnd) ? contentEnd + closing.utf16.count : contentEnd
                flush(i); emit(kind, i, finish, NSRange(location: begin, length: contentEnd - begin)); i = finish; proseStart = i; continue
            }
            if u[i] == 92 && !escaped(i) {
                var j = i + 1
                while j < u.count && ((65...90).contains(u[j]) || (97...122).contains(u[j])) { j += 1 }
                if j == i + 1 {
                    // Keep the literal character of escaped punctuation.
                    flush(i); emit(.command, i, j); i = min(j + 1, u.count); proseStart = j; continue
                }
                let name = ns.substring(with: NSRange(location: i + 1, length: j - i - 1))
                if j < u.count && u[j] == 42 { j += 1 }
                while j < u.count && (u[j] == 32 || u[j] == 9) { j += 1 }
                while let end = groupEnd(j, open: 91, close: 93) { j = end }
                if transparent.contains(name), j < u.count, u[j] == 123 {
                    flush(i); emit(.command, i, j + 1); i = j + 1; proseStart = i; continue
                }
                var end = j
                while let e = groupEnd(end) { end = e }
                if end < u.count && u[end] == 123 { end = lineEnd(end) }
                flush(i)
                let k: ScientificRegionKind = ["cite", "citep", "citet"].contains(name) ? .citation : ["ref", "eqref", "autoref", "cref"].contains(name) ? .reference : .command
                emit(k, i, end); i = end; proseStart = i; continue
            }
            if u[i] == 123 || u[i] == 125 {
                flush(i); emit(.command, i, i + 1); i += 1; proseStart = i; continue
            }
            i = start + 1
        }
        flush(u.count)
        regions = result
        maskedProse = String(utf16CodeUnits: masked, count: masked.count)
    }
}
