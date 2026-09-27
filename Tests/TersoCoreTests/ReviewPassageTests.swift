// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import TersoCore

@Suite struct ReviewPassageTests {
    func ann(_ c: AnnotationCategory, _ loc: Int, _ len: Int, rule: String = "r", severity: Severity = .info) -> TextAnnotation {
        TextAnnotation(source: c == .aiSuggestion ? .aiSuggestion : .rule, category: c, ranges: [TextSpan(location: loc, length: len)],
                       severity: severity, message: c.title, explanation: nil, revision: DocumentRevision(0), metadata: ["rule": rule])
    }
    // Three sentences: [0,40) [41,80) [81,120)
    let sentences = [TextSpan(location: 0, length: 40), TextSpan(location: 41, length: 39), TextSpan(location: 81, length: 39)]

    @Test func overlappingAndNearbyFindingsShareAPassage() {
        let hard = ann(.complexity, 0, 40, rule: "sentence.difficulty", severity: .warning)
        let passive = ann(.passiveVoice, 5, 10)
        let wordy = ann(.style, 25, 6)          // same sentence, no overlap
        let other = ann(.style, 90, 5)          // third sentence
        let p = ReviewGrouping.passages([wordy, other, passive, hard], sentences: sentences)
        #expect(p.count == 2)
        #expect(Set(p[0].findingIDs) == [hard.id, passive.id, wordy.id])
        #expect(p[0].primaryID == hard.id)       // warning outranks info
        #expect(p[0].range == TextSpan(location: 0, length: 40))
        #expect(p[1].findingIDs == [other.id])
    }

    @Test func findingAcrossSentencesMergesThem() {
        let a = ann(.style, 35, 10), b = ann(.style, 60, 3)
        let p = ReviewGrouping.passages([a, b], sentences: sentences)
        #expect(p.count == 1)
        #expect(p[0].range == TextSpan(location: 0, length: 80))
    }

    @Test func aiSuggestionTitlesItsPassage() {
        let hard = ann(.complexity, 0, 40, rule: "sentence.difficulty", severity: .warning)
        let ai = ann(.aiSuggestion, 0, 40)
        #expect(ReviewGrouping.passages([hard, ai], sentences: sentences)[0].primaryID == ai.id)
    }

    @Test func paragraphFindingsStandAlone() {
        let generic = ann(.specificity, 0, 120)
        let wordy = ann(.style, 25, 6)
        let p = ReviewGrouping.passages([generic, wordy], sentences: sentences)
        #expect(p.count == 2)
        #expect(p.first { $0.isBlockLevel }?.findingIDs == [generic.id])
    }

    @Test func textOutsideSentencesUsesOwnRange() {
        let heading = ann(.spelling, 200, 5)
        #expect(ReviewGrouping.passages([heading], sentences: sentences)[0].range == TextSpan(location: 200, length: 5))
    }

    @Test func queueNavigation() {
        let p = ReviewGrouping.passages([ann(.style, 5, 2), ann(.style, 50, 2), ann(.style, 90, 2)], sentences: sentences)
        let q = ReviewQueue(p)
        #expect(q.step(from: nil, caret: 45, offset: 1)?.id == 41)    // first at/after caret
        #expect(q.step(from: nil, caret: 45, offset: -1)?.id == 0)    // backwards from caret
        #expect(q.step(from: 81, caret: 0, offset: 1)?.id == 0)       // wraps forward
        #expect(q.step(from: 0, caret: 0, offset: -1)?.id == 81)      // wraps backward
        #expect(ReviewQueue([]).step(from: nil, caret: 0, offset: 1) == nil)
    }
}

@Suite struct WordDiffTests {
    @Test func segmentsRebuildBothSides() {
        let o = "The experiment was very clearly able to demonstrate the effect."
        let p = "The experiment demonstrated the effect."
        let d = WordDiff.diff(o, p)
        #expect(d.filter { $0.kind != .added }.map(\.text).joined() == o)
        #expect(d.filter { $0.kind != .removed }.map(\.text).joined() == p)
        #expect(d.contains { $0.kind == .removed && $0.text.contains("very clearly") })
    }

    @Test func smallEditIsReliableRewriteIsNot() {
        let o = "We utilize a simple model to estimate the effect."
        #expect(WordDiff.isReliable(WordDiff.diff(o, "We use a simple model to estimate the effect."), original: o))
        let rewrite = "Estimation relied on a basic approach."
        #expect(!WordDiff.isReliable(WordDiff.diff(o, rewrite), original: o))
    }
}
