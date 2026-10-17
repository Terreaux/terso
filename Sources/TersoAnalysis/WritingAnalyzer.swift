// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import TersoCore

public struct LocalAnalysisResult: Sendable {
    public let revision: DocumentRevision
    public let issues: [WritingIssue]
    public let statistics: DocumentStatistics
    public let science: ScientificDocumentModel
    public let headings: [ProseText.Heading]

    public var annotations: [TextAnnotation] { issues.map { TextAnnotation(issue: $0, revision: revision) } }
}

/// Runs every deterministic rule over a snapshot. Pure and thread-safe; call
/// it from a background task so typing is never blocked.
public struct WritingAnalyzer: Sendable {
    public let rules: [any WritingRule]
    public let profile: ScientificProfile

    public static let defaultRules: [any WritingRule] = [
        SentenceDifficultyRule(), PassiveVoiceRule(), AdverbRule(), QualifierRule(), FillerPhraseRule(),
        ComplexWordRule(), MisusedWordRule(), LoosePronounRule(), RepeatedWordRule(), RepeatedPhraseRule(), SentenceVariationRule(), ParagraphLengthRule(),
        ScientificRule(.notation), ScientificRule(.quantities), ScientificRule(.references), ScientificRule(.claims), ScientificRule(.evidence),
    ]

    public init(rules: [any WritingRule] = WritingAnalyzer.defaultRules, profile: ScientificProfile = .general) {
        self.rules = rules
        self.profile = profile
    }

    public func analyze(_ snapshot: DocumentSnapshot) -> LocalAnalysisResult {
        let ctx = AnalysisContext(snapshot: snapshot, profile: profile)
        var issues: [WritingIssue] = []
        for rule in rules {
            if Task.isCancelled { break }
            issues.append(contentsOf: rule.analyze(ctx))
        }
        issues.sort { ($0.ranges.first ?? TextSpan(location: 0, length: 0)) < ($1.ranges.first ?? TextSpan(location: 0, length: 0)) }
        return LocalAnalysisResult(
            revision: snapshot.revision, issues: issues,
            statistics: DocumentStatistics(prose: ctx.prose), science: ctx.science, headings: ctx.prose.headings)
    }
}
