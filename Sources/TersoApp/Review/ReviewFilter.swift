// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import TersoCore

/// The layer switches, moved out of the permanent inspector into a popover.
/// Toggling a layer changes only what is shown, never the text.
struct ReviewFilter: View {
    let model: WorkspaceModel
    nonisolated static let writing: [AnnotationCategory] = [
        .filler, .adverbs, .passiveVoice, .loosePronouns, .misused, .repetition, .lexicalIllusions,
        .readability, .complexity, .rhythm, .specificity,
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(HighlightGroup.allCases.enumerated()), id: \.element) { index, group in
                if index > 0 { Divider() }
                GroupLayers(model: model, group: group)
            }
        }
        .padding(14)
        .frame(width: 260)
    }
}
