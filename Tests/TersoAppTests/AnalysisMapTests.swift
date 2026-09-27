// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import Testing
import SwiftUI
import TersoCore
@testable import TersoApp

@Suite @MainActor struct AnalysisMapTests {
    @Test func nearbyFindingsStayReachableAndSeverityWins() {
        let input = (0..<24).map { index in
            MapMarker(id: UUID(), fraction: 0.3 + CGFloat(index) * 0.00001,
                      family: .writing, severity: index == 12 ? .warning : .info,
                      category: index.isMultiple(of: 2) ? .notation : .references,
                      range: TextSpan(location: index, length: 1), message: "Finding \(index)")
        }
        let clusters = MapMarkerCluster.layout(input, height: 600)
        #expect(clusters.count == 1)
        #expect(clusters.first?.markers.first?.id == input[12].id)
        #expect(Set(clusters.flatMap(\.markers).map(\.id)) == Set(input.map(\.id)))
        #expect(clusters.first?.markers.count == 24)
    }

    @Test func resizeAndDocumentEdgesKeepEveryMarkerWithinTrack() {
        let input = (0..<101).map { index in
            MapMarker(id: UUID(), fraction: CGFloat(index) / 100, family: .writing,
                      severity: .warning, category: .claims,
                      range: TextSpan(location: index * 10, length: 5), message: "Claim")
        }
        for height: CGFloat in [0, 1, 18, 80, 400, 1200] {
            let clusters = MapMarkerCluster.layout(input, height: height)
            #expect(clusters.flatMap(\.markers).count == input.count)
            #expect(clusters.allSatisfy { $0.slot >= 0 && CGFloat($0.slot) * 18 <= max(height, 1) })
            #expect(Set(clusters.map(\.slot)).count == clusters.count)
        }
        #expect(MapMarkerCluster.layout([], height: 400).isEmpty)
    }
    @Test func hoverUsesExistingLayoutManagerWithoutChangingCaretOrText() async throws {
        let model = WorkspaceModel()
        let text = "A result uses $q$. Let $q$ denote momentum."
        let coordinator = EditorCoordinator(model: model, text: .constant(text))
        let textView = TersoTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        textView.string = text
        coordinator.textView = textView
        model.editor = coordinator
        model.scheduleAnalysis()
        let deadline = ContinuousClock.now + .seconds(10)
        while model.currentScience == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let diagnostic = try #require(model.scienceDiagnostics.first)
        let annotation = try #require(model.scienceAnnotation(for: diagnostic))
        let layout = try #require(textView.layoutManager)
        let caret = textView.selectedRange()
        model.previewAnnotation(annotation.id)
        #expect(layout.temporaryAttribute(.backgroundColor, atCharacterIndex: diagnostic.sourceRange.location, effectiveRange: nil) != nil)
        #expect(textView.selectedRange() == caret && textView.string == text)
        #expect(model.selectedScienceObjectID == nil)
        model.previewAnnotation(nil)
        #expect(layout.temporaryAttribute(.backgroundColor, atCharacterIndex: diagnostic.sourceRange.location, effectiveRange: nil) == nil)
        #expect(textView.string == text)
    }

}
