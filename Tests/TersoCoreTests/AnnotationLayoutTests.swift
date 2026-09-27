// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import TersoCore

@Suite struct AnnotationLayoutTests {
    func ann(_ c: AnnotationCategory, _ loc: Int, _ len: Int, rule: String = "r") -> TextAnnotation {
        TextAnnotation(source: .rule, category: c, ranges: [TextSpan(location: loc, length: len)], severity: .info,
                       message: c.title, explanation: nil, revision: DocumentRevision(0), metadata: ["rule": rule])
    }

    @Test func overlappingFindingsBecomeOneCluster() {
        let sentence = ann(.complexity, 0, 50)
        let passive = ann(.passiveVoice, 10, 13)
        let wordy = ann(.style, 30, 8)
        let spell = ann(.spelling, 60, 5)
        let clusters = AnnotationLayout.clusters([wordy, spell, sentence, passive])
        #expect(clusters.count == 2)
        #expect(clusters[0].range == TextSpan(location: 0, length: 50))
        #expect(Set(clusters[0].annotationIDs) == [sentence.id, passive.id, wordy.id])
        #expect(clusters[0].family == .writing)
        #expect(clusters[1].family == .spelling)
    }

    @Test func mostProminentFamilyWins() {
        let clusters = AnnotationLayout.clusters([ann(.style, 0, 10), ann(.aiSuggestion, 5, 10)])
        #expect(clusters.count == 1)
        #expect(clusters[0].family == .aiSuggestion)
    }

    @Test func blockFindingsAreNotClustered() {
        let generic = ann(.specificity, 0, 200)
        let rhythm = ann(.readability, 0, 200, rule: "readability.rhythm")
        #expect(AnnotationLayout.clusters([generic, rhythm]).isEmpty)
    }

    @Test func primaryPrefersNarrowestAndAISuggestion() {
        let sentence = ann(.complexity, 0, 50), passive = ann(.passiveVoice, 10, 13)
        #expect(AnnotationLayout.primary(at: 12, in: [sentence, passive])?.id == passive.id)
        #expect(AnnotationLayout.primary(at: 40, in: [sentence, passive])?.id == sentence.id)
        let ai = ann(.aiSuggestion, 0, 50)
        #expect(AnnotationLayout.primary(at: 12, in: [sentence, passive, ai])?.id == ai.id)
    }

    @Test func touchingRangesStaySeparate() {
        #expect(AnnotationLayout.clusters([ann(.style, 0, 5), ann(.style, 5, 5)]).count == 2)
    }
}
