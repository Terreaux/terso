// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
import TersoCore
@testable import TersoAnalysis

@Suite struct QuantityDiagnosticsTests {
    private func model(_ text: String, profile: ScientificProfile = .hep) -> ScientificDocumentModel {
        WritingAnalyzer(profile: profile).analyze(DocumentSnapshot(revision: DocumentRevision(1), text: text)).science
    }

    @Test func incompatibleKnownFamiliesAreAdvisory() {
        let science = model(#"$q=2$ GeV. $q=2$ s."#)
        #expect(science.diagnostics.contains { $0.id.hasPrefix("science.quantities.dimension:") && $0.severity == .warning && $0.confidence == .low })
        #expect(!model(#"$q=1000$ GeV. $q=1$ TeV."#).diagnostics.contains { $0.category == .quantities })
        // Unknown/custom units are not assigned speculative dimensions.
        let custom = ScientificProfile(id: "custom", displayName: "Custom", knownUnits: ["GeV", "s"])
        #expect(!model(#"$q=2$ GeV. $q=2$ s."#, profile: custom).diagnostics.contains { $0.id.hasPrefix("science.quantities.dimension:") })
    }

    @Test func uncertaintyDifferenceIsInformational() {
        let science = model(#"$m_H=125.25 \pm 0.17$ GeV. $m_H=125.25 \pm 0.20$ GeV."#)
        #expect(science.diagnostics.contains { $0.id.hasPrefix("science.quantities.precision:") && $0.severity == .info })
        #expect(!model(#"$m_H=125.250$ GeV. $m_H=125.25$ GeV."#).diagnostics.contains { $0.category == .quantities })
        #expect(!model(#"$m_H=125.25$ GeV. $m_H=125.25 \pm 0.17$ GeV."#).diagnostics.contains { $0.id.hasPrefix("science.quantities.precision:") })
    }

    @Test func metadataLinksOccurrencesMeaningAndCandidateCitations() throws {
        let text = #"Let $m_H$ denote the Higgs mass. We measure $m_H=125.25 \pm 0.17$ GeV \cite{atlas}. Later $m_H=125.25$ GeV."#
        let science = model(text)
        let quantity = try #require(science.quantities.first { $0.symbol == "m_H" })
        let metadata = science.quantityMetadata(for: quantity)
        #expect(metadata.occurrences.count == 2)
        #expect(metadata.semanticMeaning?.contains("Higgs mass") == true)
        #expect(metadata.unitDimension == "energy")
        #expect(metadata.nearbyCitationIDs.count == 1)
        #expect(metadata.nearbyCitationIDs.allSatisfy { science.node(id: $0)?.kind == "Citation" })
        #expect(metadata.occurrences.allSatisfy { $0.upperBound <= text.utf16.count })
    }

    @Test func inverseCrossSectionRemainsDistinct() throws {
        let science = model(#"$L=35\,\mathrm{fb}^{-1}$. $L=35$ fb."#)
        #expect(Set(science.quantities.compactMap { science.quantityMetadata(for: $0).unitDimension }) == ["area", "inverse area"])
        #expect(science.diagnostics.contains { $0.id.hasPrefix("science.quantities.dimension:") })
    }

    @Test func multiKeyReferencesHaveDistinctIDs() {
        let science = model(#"See \ref{eq:a,eq:b} and \cite{missingA,missingB}. \bibitem{known} Existing source."#)
        #expect(science.diagnostics.filter { $0.id.hasPrefix("science.references.missing:") }.count == 2)
        #expect(science.diagnostics.filter { $0.id.hasPrefix("science.references.citation:") }.count == 2)
        #expect(Set(science.diagnostics.map(\.id)).count == science.diagnostics.count)
    }
}
