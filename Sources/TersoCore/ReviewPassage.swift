// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// A place in the document worth reviewing: the sentence (or sentences) that
/// one or more findings point at. The findings stay independent; the passage
/// is how they are presented — "8 places", not "24 warnings".
public struct ReviewPassage: Identifiable, Hashable, Sendable {
    public var id: Int { range.location }
    public let range: TextSpan
    /// Findings in this passage, most important first.
    public let findingIDs: [UUID]
    /// A paragraph-scale finding (generic passage, long paragraph, rhythm).
    public let isBlockLevel: Bool

    public var primaryID: UUID { findingIDs[0] }
}

public enum ReviewGrouping {
    /// Group findings into passages.
    /// - Inline findings are placed on the sentences their first range touches;
    ///   passages whose sentence spans overlap are merged.
    /// - Paragraph-level findings are passages of their own.
    /// - `sentences` must be sorted; text outside any sentence (headings,
    ///   list fragments) uses the finding's own range.
    public static func passages(_ annotations: [TextAnnotation], sentences: [TextSpan]) -> [ReviewPassage] {
        var out: [ReviewPassage] = []
        var spans: [(range: TextSpan, ids: [UUID])] = []
        for a in annotations {
            guard let anchor = a.ranges.first else { continue }
            if AnnotationLayout.isBlockLevel(a) {
                out.append(ReviewPassage(range: anchor, findingIDs: [a.id], isBlockLevel: true))
            } else {
                spans.append((covering(anchor, sentences), [a.id]))
            }
        }
        spans.sort { $0.range.location < $1.range.location }
        var merged: [(range: TextSpan, ids: [UUID])] = []
        for s in spans {
            if let last = merged.last, s.range.location < last.range.upperBound {
                let end = max(last.range.upperBound, s.range.upperBound)
                merged[merged.count - 1] = (TextSpan(location: last.range.location, length: end - last.range.location), last.ids + s.ids)
            } else {
                merged.append(s)
            }
        }
        let byID = Dictionary(annotations.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for m in merged {
            let ordered = m.ids.compactMap { byID[$0] }.sorted { importance($0) > importance($1) }.map(\.id)
            out.append(ReviewPassage(range: m.range, findingIDs: ordered, isBlockLevel: false))
        }
        return out.sorted { $0.range.location != $1.range.location ? $0.range.location < $1.range.location : !$0.isBlockLevel }
    }

    /// Which finding titles a passage: an AI suggestion awaiting a decision,
    /// then severity, then sentence-level findings, then the widest range.
    public static func importance(_ a: TextAnnotation) -> Int {
        (a.category == .aiSuggestion ? 1000 : 0) + a.severity.rawValue * 100
            + (AnnotationLayout.isSentenceLevel(a) ? 50 : 0) + min(a.ranges.first?.length ?? 0, 49)
    }

    /// The sentences touched by `r`, or `r` itself when it lies outside them.
    static func covering(_ r: TextSpan, _ sentences: [TextSpan]) -> TextSpan {
        // Binary search for the first sentence that ends after r starts.
        var lo = 0, hi = sentences.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sentences[mid].upperBound <= r.location { lo = mid + 1 } else { hi = mid }
        }
        var start = r.location, end = r.upperBound, touched = false
        var i = lo
        while i < sentences.count, sentences[i].location < max(r.upperBound, r.location + 1) {
            if sentences[i].intersects(r) || sentences[i].contains(r.location) {
                start = min(start, sentences[i].location)
                end = max(end, sentences[i].upperBound)
                touched = true
            }
            i += 1
        }
        return touched ? TextSpan(location: start, length: end - start) : r
    }
}

/// Sequential navigation over passages.
public struct ReviewQueue: Sendable {
    public let passages: [ReviewPassage]
    public init(_ passages: [ReviewPassage]) { self.passages = passages }

    public func index(of id: Int?) -> Int? { id.flatMap { id in passages.firstIndex { $0.id == id } } }

    /// The passage `offset` steps from `current`; with no current passage,
    /// the first one at or after `caret` (or before it, going backwards).
    public func step(from current: Int?, caret: Int, offset: Int) -> ReviewPassage? {
        guard !passages.isEmpty else { return nil }
        let n = passages.count
        if let i = index(of: current) { return passages[((i + offset) % n + n) % n] }
        let after = passages.firstIndex { $0.range.upperBound > caret } ?? n
        let target = offset >= 0 ? (after == n ? 0 : after) : (after == 0 ? n - 1 : after - 1)
        return passages[target]
    }
}
