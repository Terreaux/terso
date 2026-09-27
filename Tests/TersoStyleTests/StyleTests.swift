// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
import TersoCore
@testable import TersoStyle

@Suite struct StyleTests {
    @Test func bundledProfilesLoad() throws {
        let general = try #require(BaselineLibrary.profile(for: .general))
        #expect(general.humanTexts == 167)
        #expect(general.bands["nominalizations_1k"]?.p10 == 7.29)
        #expect(BaselineLibrary.profile(for: .business) == nil) // no invented baselines
    }

    @Test func tersoMeasuredRegistersBandEveryFeature() throws {
        for domain in [WritingDomain.academic, .technical] {
            let p = try #require(BaselineLibrary.profile(for: domain), "missing \(domain)")
            #expect(p.measuredByTerso)
            #expect(p.humanTexts >= 80)
            for f in FeatureCatalog.all { #expect(p.isBanded(f.id), "\(domain): \(f.id) unbanded") }
        }
        // The Quirón-derived profile keeps the three mismatched definitions unbanded.
        let general = try #require(BaselineLibrary.profile(for: .general))
        #expect(!general.measuredByTerso)
        #expect(!general.isBanded("mean_sentence_len"))
    }

    @Test func everyFeatureHasABand() throws {
        let general = try #require(BaselineLibrary.profile(for: .general))
        for f in FeatureCatalog.all { #expect(general.bands[f.id] != nil, "missing band for \(f.id)") }
    }

    @Test func bandPositionUsesMargin() {
        let b = ReferenceBand(p10: 10, p50: 20, p90: 30, min: 0, max: 40, ai: nil, auc: nil, direction: .higherInAI)
        #expect(b.position(of: 30.5) == .inside)
        #expect(b.position(of: 32) == .above)
        #expect(b.position(of: 5) == .below)
    }

    @Test func shortTextIsInsufficient() {
        let r = StyleEngine().analyze(DocumentSnapshot(revision: DocumentRevision(0), text: "Too short."), domain: .general)
        #expect(r.summary.level == nil)
        if case .insufficient = r.summary.reliability {} else { Issue.record("expected insufficient") }
    }

    @Test func domainWithoutDataSaysSo() {
        let r = StyleEngine().analyze(DocumentSnapshot(revision: DocumentRevision(0), text: String(repeating: "A plain sentence here. ", count: 80)), domain: .business)
        #expect(r.profile == nil)
        #expect(r.summary.level == nil)
    }

    @Test func levelsFollowCalibratedThresholds() {
        #expect(StyleSignalSummary.level(forAISideCount: 1) == .low)
        #expect(StyleSignalSummary.level(forAISideCount: 3) == .moderate)
        #expect(StyleSignalSummary.level(forAISideCount: 5) == .elevated)
    }

    @Test func mattrOnRepetitiveText() {
        let ctx = StyleContext(snapshot: DocumentSnapshot(revision: DocumentRevision(0), text: String(repeating: "the cat ", count: 60)))
        let m = FeatureCatalog.all.first { $0.id == "mattr50" }!.measure(ctx)
        #expect(abs(m.value - 0.04) < 0.001)
    }

    @Test func genericParagraphFlaggedSpecificNot() {
        let generic = "In today's fast-paced world, innovation plays a crucial role across a wide range of industries. Organizations must leverage robust strategies to navigate the evolving landscape and unlock transformative value for stakeholders everywhere, fostering holistic growth."
        let specific = "In March 2024 our team at Fermilab measured 412 events over 18 days, roughly 3% above the 2019 baseline (Smith, 2021). I'm not sure the detector calibration held for the last week."
        let rep = SpecificityAnalyzer().analyze(ProseText(markdown: generic + "\n\n" + specific))
        #expect(rep.paragraphs.count == 2)
        #expect(rep.paragraphs[0].isGeneric)
        #expect(!rep.paragraphs[1].isGeneric)
    }
}
