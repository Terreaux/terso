// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Broad visual families. The document shows families; the inspector shows
/// the detailed category. Higher raw value wins when findings overlap.
public enum AnnotationFamily: Int, Comparable, Sendable, CaseIterable {
    case aiStyle = 0, writing = 1, spelling = 2, aiSuggestion = 3
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    public var title: String {
        switch self {
        case .aiStyle: "AI-style signals"
        case .writing: "Writing"
        case .spelling: "Spelling & grammar"
        case .aiSuggestion: "AI suggestions"
        }
    }
}

public extension AnnotationCategory {
    var family: AnnotationFamily {
        switch self {
        case .notation, .quantities, .references, .claims, .evidence, .readability, .complexity, .passiveVoice, .style, .repetition, .specificity,
             .filler, .adverbs, .loosePronouns, .misused, .lexicalIllusions, .rhythm, .storyShape: .writing
        case .spelling: .spelling
        case .aiSuggestion: .aiSuggestion
        case .aiStyle: .aiStyle
        }
    }
}

/// Overlapping findings drawn as one interactive region. The findings stay
/// independent; only their presentation is combined.
public struct AnnotationCluster: Identifiable, Hashable, Sendable {
    public var id: Int { range.location }
    public let range: TextSpan
    public let annotationIDs: [UUID]
    public let family: AnnotationFamily

    public func contains(_ index: Int) -> Bool { range.contains(index) }
}

public enum AnnotationLayout {
    /// Rules whose findings cover whole paragraphs. They are never underlined
    /// (that would paint entire paragraphs); they appear in the rail and the
    /// Review inspector, and are tinted only while selected.
    static let blockRules: Set<String> = ["readability.paragraph", "readability.rhythm"]

    public static func isBlockLevel(_ a: TextAnnotation) -> Bool {
        a.category == .specificity || blockRules.contains(a.metadata["rule"] ?? "")
    }

    /// Findings about a whole sentence (reading difficulty). Passively they get
    /// a faint tint rather than an underline, so long sentences don't turn
    /// into walls of underlines.
    public static func isSentenceLevel(_ a: TextAnnotation) -> Bool {
        a.metadata["rule"] == "sentence.difficulty" || a.category == .claims || a.category == .evidence
    }

    /// Findings that mark a whole sentence, or many scattered words at once
    /// (an AI-style feature's hits), are quiet: a thin underline beneath the
    /// word-level findings, never text colour.
    public static func isQuiet(_ a: TextAnnotation) -> Bool {
        isSentenceLevel(a) || a.category == .aiStyle
    }

    /// Least prominent first, so drawing in this order lets the strongest
    /// finding on each character win: family, then word-level over quiet, then
    /// severity, then the narrower range.
    public static func drawOrder(_ annotations: [TextAnnotation]) -> [TextAnnotation] {
        func key(_ a: TextAnnotation) -> (Int, Int, Int, Int) {
            (a.category.family.rawValue, isQuiet(a) ? 0 : 1, a.severity.rawValue,
             -(a.ranges.map(\.length).min() ?? 0))
        }
        return annotations.sorted { key($0) < key($1) }
    }

    /// Categories still drawn inside headings: a misspelt or doubled word
    /// in a title is a mistake; style advice about one is noise.
    static let headingCategories: Set<AnnotationCategory> = [.spelling, .lexicalIllusions, .aiSuggestion]

    /// Whether a finding lies wholly inside headings and is not one they keep.
    public static func isInHeading(_ a: TextAnnotation, headings: [TextSpan]) -> Bool {
        guard !headings.isEmpty, !headingCategories.contains(a.category), !a.ranges.isEmpty else { return false }
        return a.ranges.allSatisfy { r in
            headings.contains { $0.location <= r.location && r.upperBound <= $0.upperBound }
        }
    }

    /// Merge the ranges of inline findings into non-overlapping clusters.
    /// A cluster takes the most prominent family among its members.
    public static func clusters(_ annotations: [TextAnnotation]) -> [AnnotationCluster] {
        var pieces: [(range: TextSpan, id: UUID, family: AnnotationFamily)] = []
        for a in annotations where !isBlockLevel(a) {
            for r in a.ranges where r.length > 0 { pieces.append((r, a.id, a.category.family)) }
        }
        pieces.sort { $0.range.location < $1.range.location }
        var out: [AnnotationCluster] = []
        var cur: (start: Int, end: Int, ids: [UUID], family: AnnotationFamily)?
        for p in pieces {
            if let c = cur, p.range.location < c.end {
                cur = (c.start, max(c.end, p.range.upperBound), c.ids.contains(p.id) ? c.ids : c.ids + [p.id], max(c.family, p.family))
            } else {
                if let c = cur { out.append(AnnotationCluster(range: TextSpan(location: c.start, length: c.end - c.start), annotationIDs: c.ids, family: c.family)) }
                cur = (p.range.location, p.range.upperBound, [p.id], p.family)
            }
        }
        if let c = cur { out.append(AnnotationCluster(range: TextSpan(location: c.start, length: c.end - c.start), annotationIDs: c.ids, family: c.family)) }
        return out
    }

    /// The finding a click at `index` means: AI suggestions first, then the
    /// narrowest range containing the point.
    public static func primary(at index: Int, in annotations: [TextAnnotation]) -> TextAnnotation? {
        annotations
            .filter { a in a.ranges.contains { $0.contains(index) } }
            .min { l, r in
                let lk = (l.category == .aiSuggestion ? 0 : 1, l.ranges.filter { $0.contains(index) }.map(\.length).min() ?? .max)
                let rk = (r.category == .aiSuggestion ? 0 : 1, r.ranges.filter { $0.contains(index) }.map(\.length).min() ?? .max)
                return lk < rk
            }
    }

    /// Document order, for Review navigation.
    public static func ordered(_ annotations: [TextAnnotation]) -> [TextAnnotation] {
        annotations.sorted {
            let l = $0.ranges.first?.location ?? 0, r = $1.ranges.first?.location ?? 0
            return l != r ? l < r : ($0.ranges.first?.length ?? 0) > ($1.ranges.first?.length ?? 0)
        }
    }
}
