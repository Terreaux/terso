// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

/// Review | Assistant | Science | Statistics. Each pane manages its own scrolling so
/// none can push the window taller than it is.
struct InspectorView: View {
    @Bindable var model: WorkspaceModel
    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $model.inspectorTab) {
                ForEach(InspectorTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()
            switch model.inspectorTab {
            case .review: ReviewInspector(model: model)
            case .ai: AssistantPane(model: model)
            case .science: ScienceInspector(model: model)
            case .statistics: StatisticsInspector(model: model)
            }
        }
        .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
    }
}
