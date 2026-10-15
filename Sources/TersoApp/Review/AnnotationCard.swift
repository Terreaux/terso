// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import TersoCore

/// Shown at the text when a finding is clicked while the inspector is closed:
/// the same content as the selected Review item, plus a way into Review.
struct AnnotationCard: View {
    let annotation: TextAnnotation
    let model: WorkspaceModel
    /// Which of the finding's ranges was clicked, so the card starts there.
    var occurrence = 0
    let close: () -> Void

    var body: some View {
        if annotation.isSuggestion {
            VStack(alignment: .leading, spacing: 0) {
                SuggestionDetail(suggestion: annotation, model: model).padding(14)
                Divider()
                HStack {
                    Spacer()
                    Button("Open in Review", action: openInReview)
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            .frame(width: 340)
        } else {
            FindingDetail(finding: annotation, model: model, compact: true, occurrence: occurrence, openInReview: openInReview)
                .padding(12)
                .frame(width: 320)
        }
    }

    private func openInReview() {
        close()
        model.inspectorTab = .review
        model.showInspector = true
    }
}
