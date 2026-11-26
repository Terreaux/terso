// SPDX-License-Identifier: AGPL-3.0-only
import Testing
import TersoAnalysis
import TersoCore

/// Authored regression examples. Each expected outcome refers to one editing rule.
@Suite struct ScientificWritingTests {
    struct Passage: Sendable {
        let section: String
        let text: String
        let rule: String
        let flagged: String
        let shouldFlag: Bool
    }

    static let passages = [
        Passage(section: "Theory", text: "Differentiate the distribution with respect to the cutoff.", rule: "style.filler", flagged: "with respect to", shouldFlag: false),
        Passage(section: "Theory", text: "The optimal transport distance is invariant.", rule: "complexity.word", flagged: "optimal", shouldFlag: false),
        Passage(section: "Results", text: "The estimator is a sufficient statistic for its mean.", rule: "complexity.word", flagged: "sufficient", shouldFlag: false),
        Passage(section: "Theory", text: "The kernel is essentially bounded over the domain.", rule: "style.qualifier", flagged: "essentially", shouldFlag: false),
        Passage(section: "Methods", text: "The samples were collected at noon.", rule: "style.passive", flagged: "were collected", shouldFlag: false),
        Passage(section: "Results", text: "The samples were collected at noon.", rule: "style.passive", flagged: "were collected", shouldFlag: true),
        Passage(section: "Abstract", text: "We gathered data in order to test the model.", rule: "style.filler", flagged: "in order to", shouldFlag: true),
        Passage(section: "Caption", text: "The colors are really quite different.", rule: "style.qualifier", flagged: "really", shouldFlag: true),
        Passage(section: "Methods", text: "We utilize the same calibration in both arms.", rule: "complexity.word", flagged: "utilize", shouldFlag: true),
    ]

    @Test(arguments: passages) func academicAdvice(_ example: Passage) {
        let snapshot = DocumentSnapshot(revision: .init(0), text: "# Manuscript\n\n## " + example.section + "\n\n" + example.text)
        let rule = WritingAnalyzer.standardRules(scientificWording: true).first { $0.id == example.rule }!
        let findings = rule.analyze(AnalysisContext(snapshot: snapshot))
        #expect(findings.contains { $0.originalText == example.flagged } == example.shouldFlag)
    }

    @Test func generalRegisterKeepsFamiliarAdvice() {
        let snapshot = DocumentSnapshot(revision: .init(0), text: "We write with respect to the policy.")
        #expect(FillerPhraseRule().analyze(AnalysisContext(snapshot: snapshot)).contains { $0.originalText == "with respect to" })
    }
}
