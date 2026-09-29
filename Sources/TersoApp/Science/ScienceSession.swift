// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Observation
import TersoAnalysis
import TersoCore

/// Review decisions live with the document window, never in the manuscript.
@MainActor @Observable
final class ScienceReviewState {
    var attentionExpanded = false
    var expandedSections: Set<String> = []
    var authorStatements: Set<String> = []
    var ignoredClaims: Set<String> = []
    var dismissalKeys: Set<String> = []
    var occurrencePositions: [String: Int] = [:]
}

extension WorkspaceModel {
    var currentScience: ScientificDocumentModel? {
        guard let science = local?.science, science.revision == revision, science.profile == scienceProfile else { return nil }
        return science
    }

    func scienceAnnotation(for diagnostic: ScientificDiagnostic) -> TextAnnotation? {
        localAnnotations.first { $0.metadata["scienceDiagnosticID"] == diagnostic.id }
    }

    var scienceDiagnostics: [ScientificDiagnostic] {
        guard let science = currentScience else { return [] }
        let keys = Dictionary(localAnnotations.compactMap { annotation -> (String, String)? in
            guard let id = annotation.metadata["scienceDiagnosticID"] else { return nil }
            return (id, annotation.dismissalKey)
        }, uniquingKeysWith: { first, _ in first })
        return science.diagnostics.filter { diagnostic in
            keys[diagnostic.id].map { !dismissed.contains($0) } ?? true
        }
    }

    func selectScienceDiagnostic(_ diagnostic: ScientificDiagnostic, reveal: Bool = true) {
        guard currentScience != nil else { return }
        scienceDetailSection = "Needs attention"
        navigateScience(objectID: diagnostic.id, range: diagnostic.sourceRange, reveal: reveal)
        if let annotation = scienceAnnotation(for: diagnostic) { select(annotation, reveal: false) }
        showInspector = true
        inspectorTab = .science
    }

    @discardableResult
    func selectScienceAnnotation(_ annotation: TextAnnotation, reveal: Bool = true) -> Bool {
        guard let id = annotation.metadata["scienceDiagnosticID"],
              let diagnostic = currentScience?.diagnostics.first(where: { $0.id == id }) else { return false }
        selectScienceDiagnostic(diagnostic, reveal: reveal)
        return true
    }

    func restoreScienceWarnings() {
        let scienceKeys = localAnnotations.filter { $0.metadata["scienceDiagnosticID"] != nil }.map(\.dismissalKey)
        dismissed.subtract(scienceKeys)
        dismissed.subtract(scienceReview.dismissalKeys)
        scienceReview.dismissalKeys.removeAll()
        scienceReview.authorStatements.removeAll()
        scienceReview.ignoredClaims.removeAll()
        editor?.refreshDecorations()
    }

    func ignoreScienceDiagnostic(_ diagnostic: ScientificDiagnostic) {
        if let annotation = scienceAnnotation(for: diagnostic) {
            scienceReview.dismissalKeys.insert(annotation.dismissalKey)
            dismiss(annotation.id)
        }
        for claim in currentScience?.claims ?? [] where diagnostic.relatedObjectIDs.contains(claim.objectID) {
            scienceReview.ignoredClaims.insert(claim.text)
        }
    }

    func markScienceClaim(_ claim: ScientificClaim, asAuthorStatement: Bool) {
        guard currentScience != nil else { return }
        if asAuthorStatement { scienceReview.authorStatements.insert(claim.text) }
        else { scienceReview.ignoredClaims.insert(claim.text) }
        for annotation in localAnnotations where [.claims, .evidence].contains(annotation.category)
            && annotation.ranges.contains(where: { $0.intersects(claim.sourceRange) }) {
            scienceReview.dismissalKeys.insert(annotation.dismissalKey)
            dismiss(annotation.id)
        }
    }

    func findScienceSupport(_ claim: ScientificClaim) {
        guard currentScience != nil else { return }
        // The whole manuscript is the context: support often lives in another
        // section (methods, results, a later figure), not the claim's paragraph.
        runAI(task: .ask,
              question: "Review this claim under the \(scienceProfile.displayName) profile: \"\(claim.text)\". Using the whole document, point to any passages, results, figures or citations that support it, and say what evidence or citation would still be needed. Distinguish author opinion from factual claims. Do not invent references or assert that nearby material proves the claim.",
              scope: .document, selection: claim.sourceRange)
    }
}
