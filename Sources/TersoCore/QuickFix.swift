// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// A one-click edit for a finding: replace `range` with `replacement`.
/// Like any suggestion it is data until the writer clicks it.
public struct QuickFix: Hashable, Sendable {
    /// The flagged text, as it reads now.
    public let original: String
    /// What it becomes; empty when the fix removes it.
    public let proposed: String
    /// The span actually edited. A removal also takes a neighbouring space
    /// (and recapitalises the next word at a sentence start).
    public let range: TextSpan
    public let replacement: String

    public init(original: String, proposed: String, range: TextSpan, replacement: String) {
        self.original = original
        self.proposed = proposed
        self.range = range
        self.replacement = replacement
    }

    public var isRemoval: Bool { proposed.isEmpty }
    public var title: String { isRemoval ? "Remove" : proposed }
}

/// Builds quick fixes from what a finding records: `suggestions` (newline-
/// separated replacements, best first) and `removable` (the text can go).
public enum QuickFixes {
    public static let suggestionsKey = "suggestions"
    public static let removableKey = "removable"
    public static let separator = "\n"

    /// Metadata for a finding whose fixes are `replacements` (" / " separates
    /// alternatives, as rule lists write them), optionally also removal.
    public static func metadata(replacements: String?, removable: Bool = false) -> [String: String] {
        var m: [String: String] = [:]
        let options = (replacements ?? "").components(separatedBy: " / ")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !options.isEmpty { m[suggestionsKey] = options.joined(separator: separator) }
        if removable { m[removableKey] = "true" }
        return m
    }

    /// Fixes for one occurrence of a finding in `text`, best first.
    public static func fixes(suggestions: [String], removable: Bool, range: TextSpan, in text: String) -> [QuickFix] {
        let ns = text as NSString
        guard range.location >= 0, range.length > 0, range.upperBound <= ns.length else { return [] }
        let original = ns.substring(with: range.nsRange)
        var out: [QuickFix] = []
        var seen = Set<String>()
        for s in suggestions {
            let p = matchCase(s, to: original)
            guard p != original, seen.insert(p).inserted else { continue }
            out.append(QuickFix(original: original, proposed: p, range: range, replacement: p))
        }
        if removable {
            let (r, rep) = removal(of: range, in: ns)
            out.append(QuickFix(original: original, proposed: "", range: r, replacement: rep))
        }
        return out
    }

    /// "to" replacing "In order to" becomes "To".
    public static func matchCase(_ replacement: String, to original: String) -> String {
        guard let o = original.first, o.isUppercase, let r = replacement.first, r.isLowercase else { return replacement }
        return r.uppercased() + replacement.dropFirst()
    }

    /// The span to delete so no double space or stray comma is left, and the
    /// replacement that recapitalises the next word when removing a sentence opener.
    static func removal(of range: TextSpan, in ns: NSString) -> (TextSpan, String) {
        func char(_ i: Int) -> Character? {
            guard i >= 0, i < ns.length else { return nil }
            return Character(ns.substring(with: NSRange(location: i, length: 1)))
        }
        var start = range.location, end = range.upperBound
        // Is the text the first thing in its sentence?
        var p = start - 1
        while let c = char(p), c == " " || c == "\t" { p -= 1 }
        let opensSentence = char(p).map { ".!?\n\r#>".contains($0) } ?? true
        // A sentence opener often ends in a comma: "Needless to say, …".
        if opensSentence, char(end) == "," { end += 1 }
        if let c = char(end), c == " " || c == "\t" {
            while let c = char(end), c == " " || c == "\t" { end += 1 }
        } else {
            // Followed by punctuation or the line end: take the space before instead.
            while let c = char(start - 1), c == " " || c == "\t" { start -= 1 }
        }
        if opensSentence, let next = char(end), next.isLowercase {
            return (TextSpan(location: start, length: end + 1 - start), next.uppercased())
        }
        return (TextSpan(location: start, length: end - start), "")
    }
}
