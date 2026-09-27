// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import TersoCore

/// The layer switches, moved out of the permanent inspector into a popover.
/// Toggling a layer changes only what is shown, never the text.
struct ReviewFilter: View {
    let model: WorkspaceModel
    static let writing: [AnnotationCategory] = [.readability, .complexity, .passiveVoice, .style, .repetition, .specificity]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Show")
            ForEach(Self.writing) { row($0) }
            Divider()
            SectionLabel("Science")
            ForEach([AnnotationCategory.notation, .quantities, .references, .claims, .evidence]) { row($0) }
            Divider()
            row(.spelling)
            Divider()
            row(.aiStyle)
            row(.aiSuggestion)
        }
        .padding(14)
        .frame(width: 260)
    }

    private func row(_ c: AnnotationCategory) -> some View {
        Toggle(isOn: Binding(get: { model.prefs.enabledLayers.contains(c) }, set: { _ in model.toggleLayer(c) })) {
            HStack {
                Text(c.title)
                Spacer()
                Text("\(model.count(c))").monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.checkbox)
        .accessibilityLabel("\(c.title), \(model.count(c)) findings")
    }
}
