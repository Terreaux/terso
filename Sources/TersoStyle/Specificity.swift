// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import NaturalLanguage
import TersoCore

/// Per-paragraph evidence of concreteness.
public struct ParagraphSpecificity: Sendable, Identifiable {
    public var id: Int { range.location }
    public let range: TextSpan
    public let words: Int
    public let specificMarkers: [String: Int]   // kind → count
    public let genericRanges: [TextSpan]
    public var specificCount: Int { specificMarkers.values.reduce(0, +) }
    public var specificPer100: Double { words == 0 ? 0 : Double(specificCount) / Double(words) * 100 }
    public var isGeneric: Bool { words >= 30 && specificPer100 < 1.0 && genericRanges.count >= 2 }
    /// Dense concrete detail: several markers per hundred words.
    public var isConcrete: Bool { words >= 20 && specificPer100 >= 3.0 }

    /// "2 dates · 1 place · 3 numbers"
    public var markerSummary: String {
        let labels: [(String, String, String)] = [
            ("numbers", "number", "numbers"), ("dates", "date", "dates"), ("names", "name", "names"),
            ("citations", "citation", "citations"), ("quotations", "quotation", "quotations"),
            ("uncertainty", "stated uncertainty", "stated uncertainties"),
        ]
        return labels.compactMap { key, one, many in
            specificMarkers[key].map { "\($0) \($0 == 1 ? one : many)" }
        }.joined(separator: " · ")
    }
}

public struct SpecificityReport: Sendable {
    public let paragraphs: [ParagraphSpecificity]
    public var genericParagraphs: [ParagraphSpecificity] { paragraphs.filter(\.isGeneric) }
    public var concreteParagraphs: [ParagraphSpecificity] {
        paragraphs.filter(\.isConcrete).sorted { $0.specificPer100 > $1.specificPer100 }
    }

    public static let note = "Experimental. Counts concrete detail (names, numbers, dates, citations, quotations, stated uncertainty) against stock framing. Thresholds are provisional and uncalibrated."

    public func annotations(revision: DocumentRevision) -> [TextAnnotation] {
        genericParagraphs.map { p in
            TextAnnotation(
                source: .statistical, category: .specificity, ranges: [p.range], severity: .info,
                message: "Generic passage",
                explanation: "This paragraph makes broad claims but contains little concrete evidence or context. Consider adding a concrete example, evidence or a measurement, an attribution, or a specific observation — only details that are true. Generality is sometimes right; context decides.",
                revision: revision, metadata: ["generic": "\(p.genericRanges.count)", "specific": "\(p.specificCount)"])
        }
    }
}

public struct SpecificityAnalyzer: Sendable {
    public init() {}

    static func re(_ p: String, _ o: NSRegularExpression.Options = []) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: o)
    }
    static let number = re(#"(?<![\p{L}])\d[\d,.]*(?:\s?(?:%|percent|[kKmM]?[bB]|ms|km|kg|mg|mm|cm|GB|MB|TB|x|×|hours?|minutes?|days?|weeks?|years?|months?|people|users|million|billion))?"#)
    static let month = re(#"\b(?:January|February|March|April|May|June|July|August|September|October|November|December)\b"#)
    static let citation = re(#"\[\d+(?:[,–-]\d+)*\]|\([A-Z][\p{L}-]+(?: et al\.| and [A-Z][\p{L}-]+)?,? \d{4}[a-z]?\)|\]\([^)]+\)|https?://"#)
    static let quotation = re(#"[“"][^”"\n]{12,}[”"]"#)
    static let uncertainty = re(#"\b(?:I'm not sure|I am not sure|we don't know|we do not know|it's unclear|it is unclear|unclear whether|roughly|approximately|about \d|I suspect|my guess|not yet known|may not|might not|I was wrong|we were wrong)\b"#, [.caseInsensitive])
    static let generic = re(#"\b(?:in today's (?:\w+ )?world|fast-paced|ever-(?:evolving|changing)|plays? an? (?:crucial|key|vital|pivotal|important) role|a wide (?:range|array|variety) of|various|numerous|crucial|vital|pivotal|landscape|realm|paradigm|robust|seamless(?:ly)?|leverag(?:e|es|ing)|unlock(?:s|ing)?|empower(?:s|ing)?|transformative|game-changer|stakeholders|best practices|moving forward|navigate the|journey|foster(?:s|ing)?|holistic|cutting-edge|innovative|at its core|in the end|the power of|when it comes to|more than ever|it is (?:important|essential|crucial) to|significantly|key (?:factor|aspect|takeaway)s?|delve|tapestry|testament to)\b"#, [.caseInsensitive])

    public func analyze(_ prose: ProseText) -> SpecificityReport {
        let orig = prose.original as NSString
        var out: [ParagraphSpecificity] = []
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = prose.masked
        for (bi, block) in prose.blocks.enumerated() {
            let words = prose.sentences(inBlock: bi).reduce(0) { $0 + $1.words.count }
            guard words >= 20 else { continue }
            let r = block.range.nsRange
            let masked = prose.masked
            func count(_ re: NSRegularExpression, _ text: String) -> Int { re.numberOfMatches(in: text, range: r) }
            var markers: [String: Int] = [:]
            markers["numbers"] = count(Self.number, masked)
            markers["dates"] = count(Self.month, masked)
            // Citations and links live in the markup, so look at the original.
            markers["citations"] = count(Self.citation, orig as String)
            markers["quotations"] = count(Self.quotation, masked)
            markers["uncertainty"] = count(Self.uncertainty, masked)
            var names = 0
            if let range = Range(r, in: masked) {
                tagger.enumerateTags(in: range, unit: .word, scheme: .nameType, options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, _ in
                    if let tag, [.personalName, .placeName, .organizationName].contains(tag) { names += 1 }
                    return true
                }
            }
            markers["names"] = names
            let generic = Self.generic.matches(in: masked, range: r).map { TextSpan($0.range) }
            out.append(ParagraphSpecificity(range: block.range, words: words, specificMarkers: markers.filter { $0.value > 0 }, genericRanges: generic))
        }
        return SpecificityReport(paragraphs: out)
    }
}
