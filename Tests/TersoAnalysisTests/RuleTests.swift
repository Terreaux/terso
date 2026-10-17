// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
import TersoCore
@testable import TersoAnalysis

func issues(_ rule: some WritingRule, _ text: String) -> [WritingIssue] {
    rule.analyze(AnalysisContext(snapshot: DocumentSnapshot(revision: DocumentRevision(0), text: text)))
}

@Suite struct RuleTests {
    @Test func passiveVoiceHighlightsExactRange() {
        let text = "The experiment was conducted by the team. We were tired."
        let found = issues(PassiveVoiceRule(), text)
        #expect(found.count == 1)
        #expect(found[0].originalText == "was conducted")
        #expect((text as NSString).substring(with: found[0].ranges[0].nsRange) == "was conducted")
    }

    @Test func ruleFindingsCarryQuickFixes() {
        let filler = issues(FillerPhraseRule(), "We ran in order to win. Needless to say, we won.")
        #expect(filler.first { $0.originalText == "in order to" }?.metadata[QuickFixes.suggestionsKey] == "to")
        #expect(filler.first { $0.originalText == "Needless to say" }?.metadata[QuickFixes.removableKey] == "true")
        let misused = issues(MisusedWordRule(), "It is comprised of parts.")
        #expect(misused.first?.metadata[QuickFixes.suggestionsKey] == "composed of\ncomprises")
        #expect(misused.first?.metadata[QuickFixes.removableKey] == nil)
        let doubled = issues(RepeatedWordRule(), "The the cat sat.").first { $0.message == "Doubled word" }
        #expect(doubled?.metadata[QuickFixes.suggestionsKey] == "The")
    }

    @Test func repeatedPhraseHasEveryOccurrence() {
        let text = "It is important to rest. Later, it is important to eat. Finally it is important to sleep."
        let found = issues(RepeatedPhraseRule(), text)
        let phrase = found.first { $0.originalText.contains("important to") }
        #expect(phrase != nil)
        #expect(phrase?.ranges.count == 3)
        for r in phrase?.ranges ?? [] {
            #expect((text as NSString).substring(with: r.nsRange).lowercased().hasPrefix("it is important to"))
        }
    }

    @Test func fillerOffersReplacement() {
        let found = issues(FillerPhraseRule(), "We did it in order to win.")
        #expect(found.first?.consider == "to")
    }

    @Test func doubledWord() {
        let found = issues(RepeatedWordRule(), "This is the the answer.")
        #expect(found.contains { $0.message == "Doubled word" && $0.category == .lexicalIllusions })
    }

    @Test func splitLayers() {
        #expect(issues(QualifierRule(), "It is very good.").first?.category == .filler)
        #expect(issues(FillerPhraseRule(), "We did it in order to win.").first?.category == .filler)
        #expect(AdverbRule().category == .adverbs)
        #expect(SentenceVariationRule().category == .rhythm)
    }

    @Test func loosePronounFlagsOnlyTheOpeningPronoun() {
        let text = "We fit the spectrum. This shows a clear peak. This peak is narrow. It is clear that we win."
        let found = issues(LoosePronounRule(), text)
        #expect(found.map(\.originalText) == ["This", "It"])
        #expect((text as NSString).substring(with: found[0].ranges[0].nsRange) == "This")
    }

    @Test func misusedPhrases() {
        let found = issues(MisusedWordRule(), "The sample is comprised of jets, and the data shows more then expected. Metadata is fine.")
        #expect(Set(found.map(\.originalText)) == ["comprised of", "data shows", "more then"])
        #expect(found.first { $0.originalText == "more then" }?.consider == "more than")
        #expect(found.allSatisfy { $0.category == .misused })
    }

    @Test func longSentence() {
        let s = Array(repeating: "word", count: 42).joined(separator: " ") + "."
        let found = issues(SentenceDifficultyRule(), s)
        #expect(found.first?.severity == .warning)
    }

    @Test func codeIsIgnored() {
        let found = WritingAnalyzer().analyze(DocumentSnapshot(revision: DocumentRevision(0), text: "```\nit was done by the the utilize\n```\n"))
        #expect(found.issues.isEmpty)
    }

    @Test func analyzerIsPureAndSorted() {
        let snap = DocumentSnapshot(revision: DocumentRevision(7), text: "It was written quickly. In order to see, we utilize tools.")
        let r = WritingAnalyzer().analyze(snap)
        #expect(r.revision == DocumentRevision(7))
        #expect(!r.issues.isEmpty)
        let locs = r.issues.map { $0.ranges[0].location }
        #expect(locs == locs.sorted())
    }

    @Test func sincerityMarkersAreOptionalAndRemovable() {
        let text = "Honestly, the build is slow. To be honest, I genuinely like it."
        let found = issues(SincerityMarkerRule(), text)
        #expect(found.map(\.originalText) == ["Honestly", "To be honest", "genuinely"])
        #expect(found.allSatisfy { $0.severity == .info && $0.metadata[QuickFixes.removableKey] == "true" })
        let snap = DocumentSnapshot(revision: DocumentRevision(0), text: text)
        #expect(!WritingAnalyzer().analyze(snap).issues.contains { $0.ruleID == "style.sincerity" })
        #expect(WritingAnalyzer(enabling: ["style.sincerity"]).analyze(snap).issues.contains { $0.ruleID == "style.sincerity" })
    }

    @Test func negatedSetupIsReviewOnly() {
        let text = """
        Speed isn't the problem. The cache is cold on every deploy, so the first requests wait.

        We measured twice. The fix was not a rewrite. It was a single flag in the config.

        The tool is not slow because the disk is full. The queue wasn't empty when we started the long migration over the weekend.
        """
        let found = issues(NegatedSetupRule(), text)
        // Opens a paragraph; before a reframe. Not: has "because", over twelve words, mid-paragraph without reframe.
        #expect(found.map(\.originalText) == ["Speed isn't the problem.", "The fix was not a rewrite."])
        #expect(found.allSatisfy { $0.severity == .info && $0.metadata.isEmpty })
        #expect(!WritingAnalyzer().analyze(DocumentSnapshot(revision: DocumentRevision(0), text: text)).issues.contains { $0.ruleID == "style.negatedSetup" })
    }
}
