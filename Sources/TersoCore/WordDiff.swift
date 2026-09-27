// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Word-level differences between an original passage and a proposed one,
/// for tracked-changes rendering.
public enum WordDiff {
    public enum Kind: Sendable, Equatable { case same, removed, added }
    public struct Segment: Sendable, Equatable {
        public let kind: Kind
        public let text: String
    }

    /// Words keep their trailing whitespace, so segments concatenate back to
    /// the original (same + removed) or the proposal (same + added).
    static func tokens(_ s: String) -> [String] {
        var out: [String] = [], cur = ""
        var inSpace = false
        for ch in s {
            if ch.isWhitespace { cur.append(ch); inSpace = true; continue }
            if inSpace { out.append(cur); cur = ""; inSpace = false }
            cur.append(ch)
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    public static func diff(_ original: String, _ proposed: String) -> [Segment] {
        let a = tokens(original), b = tokens(proposed)
        let key = { (t: String) in t.trimmingCharacters(in: .whitespaces) }
        // Longest common subsequence over words (inputs are sentences, so O(n·m) is fine).
        var lcs = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lcs[i][j] = key(a[i]) == key(b[j]) ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var out: [Segment] = []
        func push(_ k: Kind, _ t: String) {
            if let last = out.last, last.kind == k { out[out.count - 1] = Segment(kind: k, text: last.text + t) } else { out.append(Segment(kind: k, text: t)) }
        }
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if key(a[i]) == key(b[j]) { push(.same, b[j]); i += 1; j += 1 }
            else if lcs[i + 1][j] >= lcs[i][j + 1] { push(.removed, a[i]); i += 1 }
            else { push(.added, b[j]); j += 1 }
        }
        while i < a.count { push(.removed, a[i]); i += 1 }
        while j < b.count { push(.added, b[j]); j += 1 }
        return out
    }

    /// Inline tracked changes are readable when most words survive. Beyond
    /// that it is a rewrite, better shown as Original / Suggested blocks.
    public static func isReliable(_ segments: [Segment], original: String) -> Bool {
        let kept = segments.filter { $0.kind == .same }.map { tokens($0.text).count }.reduce(0, +)
        let total = max(tokens(original).count, 1)
        return total <= 60 && Double(kept) / Double(total) >= 0.5
    }
}
