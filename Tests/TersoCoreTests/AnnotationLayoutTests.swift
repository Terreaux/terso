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

    @Test func strongestFindingIsDrawnLast() {
        let sentence = ann(.complexity, 0, 50, rule: "sentence.difficulty")
        let signal = ann(.aiStyle, 0, 8)
        let filler = ann(.filler, 0, 30)
        let pronoun = ann(.loosePronouns, 0, 2)
        let warning = TextAnnotation(source: .rule, category: .misused, ranges: [TextSpan(location: 0, length: 40)], severity: .warning,
                                     message: "", explanation: nil, revision: DocumentRevision(0), metadata: [:])
        let spell = ann(.spelling, 3, 4)
        let order = AnnotationLayout.drawOrder([spell, warning, pronoun, filler, signal, sentence]).map(\.id)
        // AI-style below writing; quiet sentence below word findings; then
        // severity, then the narrower range; spelling outranks the family.
        #expect(order == [signal.id, sentence.id, filler.id, pronoun.id, warning.id, spell.id])
    }

    @Test func sentencesAndSignalsAreQuiet() {
        #expect(AnnotationLayout.isQuiet(ann(.complexity, 0, 50, rule: "sentence.difficulty")))
        #expect(AnnotationLayout.isQuiet(ann(.aiStyle, 0, 8)))
        #expect(!AnnotationLayout.isQuiet(ann(.complexity, 0, 8, rule: "complexity.word")))
    }

    @Test func headingsKeepOnlyMistakes() {
        let heading = [TextSpan(location: 0, length: 20)]
        #expect(AnnotationLayout.isInHeading(ann(.aiStyle, 2, 7), headings: heading))
        #expect(AnnotationLayout.isInHeading(ann(.complexity, 2, 7), headings: heading))
        #expect(!AnnotationLayout.isInHeading(ann(.spelling, 2, 7), headings: heading))
        #expect(!AnnotationLayout.isInHeading(ann(.lexicalIllusions, 2, 7), headings: heading))
        // A finding that runs past the heading is about the prose too.
        #expect(!AnnotationLayout.isInHeading(ann(.complexity, 15, 10), headings: heading))
    }
}
