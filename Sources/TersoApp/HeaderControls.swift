// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import TersoCore

/// Highlight layers grouped the way a writer thinks about them. Each header
/// button opens its group's layers; counts stay visible even
/// when a layer is off.
enum HighlightGroup: String, CaseIterable, Identifiable {
    case writing, science, spelling, ai
    var id: String { rawValue }

    var title: String {
        switch self {
        case .writing: "Writing"
        case .science: "Science"
        case .spelling: "Spelling"
        case .ai: "AI"
        }
    }

    var symbol: String {
        switch self {
        case .writing: "text.word.spacing"
        case .science: "function"
        case .spelling: "textformat.abc.dottedunderline"
        case .ai: "sparkles"
        }
    }

    var categories: [AnnotationCategory] {
        switch self {
        case .writing: ReviewFilter.writing
        case .science: [.notation, .quantities, .references, .claims, .evidence]
        case .spelling: [.spelling]
        case .ai: [.aiSuggestion, .aiStyle]
        }
    }

    /// The same colour the document underlines this group in.
    var color: Color { Color(nsColor: HighlightStyle.color(categories[0].family)) }
}

/// How much room the header has: counts go first, then the groups fold
/// into a single highlighter menu.
enum HeaderDensity { case full, compact, minimal }

struct HighlightControls: View {
    let model: WorkspaceModel
    var density: HeaderDensity = .full
    @State private var showAll = false

    var body: some View {
        HStack(spacing: 2) {
            if density == .minimal {
                HeaderToggle(isOn: showAll, help: "Choose highlight layers") { showAll.toggle() } label: {
                    Image(systemName: "highlighter")
                }
                .accessibilityLabel("Highlight layers")
                .popover(isPresented: $showAll, arrowEdge: .bottom) { ReviewFilter(model: model) }
            } else {
                ForEach(HighlightGroup.allCases) { GroupButton(model: model, group: $0, showsCount: density == .full) }
            }
        }
        .padding(2)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
    }
}

/// One group: tinted while any of its layers is shown, grey when none is.
/// Clicking opens the group's layers.
private struct GroupButton: View {
    let model: WorkspaceModel
    let group: HighlightGroup
    let showsCount: Bool
    @State private var open = false

    var body: some View {
        let shown = group.categories.filter(model.prefs.enabledLayers.contains)
        let count = group.categories.reduce(0) { $0 + model.count($1) }
        HeaderToggle(isOn: open || !shown.isEmpty, help: "\(group.title) highlights") { open.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: group.symbol)
                if showsCount { Text(count.formatted()).monospacedDigit() }
            }
            .foregroundStyle(shown.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(group.color))
        }
        .accessibilityLabel("\(group.title) highlights, \(count) findings, \(shown.count) of \(group.categories.count) layers shown")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                GroupLayers(model: model, group: group)
            }
            .padding(14)
            .frame(width: 240)
        }
    }
}

/// A group's layers as toggleable rows, with a one-click All/None.
struct GroupLayers: View {
    let model: WorkspaceModel
    let group: HighlightGroup

    var body: some View {
        let allOn = group.categories.allSatisfy(model.prefs.enabledLayers.contains)
        HStack {
            SectionLabel(group.title)
            Spacer()
            if group.categories.count > 1 {
                Button(allOn ? "None" : "All") { model.setLayers(group.categories, visible: !allOn) }
                    .buttonStyle(.borderless).font(.caption)
            }
        }
        ForEach(group.categories) { LayerRow(model: model, category: $0) }
    }
}

/// A layer as a clickable row: a dot and title in the layer's own colour —
/// the colour its findings take on the page — when shown; greyed when hidden.
struct LayerRow: View {
    let model: WorkspaceModel
    let category: AnnotationCategory

    var body: some View {
        let on = model.prefs.enabledLayers.contains(category)
        let count = model.count(category)
        let color = Color(nsColor: HighlightStyle.color(category))
        Button { model.toggleLayer(category) } label: {
            HStack(spacing: 8) {
                Circle().fill(color.opacity(on ? 1 : 0.3)).frame(width: 8, height: 8)
                Text(category.title)
                    .fontWeight(on ? .semibold : .regular)
                    .foregroundStyle(on ? AnyShapeStyle(color) : AnyShapeStyle(.tertiary))
                Spacer()
                Text("\(count)").monospacedDigit().foregroundStyle(on ? .secondary : .tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(category.title), \(count) findings")
        .accessibilityValue(on ? "shown" : "hidden")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Typewriter, Focus and Zen side by side.
struct WritingModeControls: View {
    let model: WorkspaceModel
    var density: HeaderDensity = .full

    var body: some View {
        if density == .minimal { menu } else { buttons }
    }

    private var menu: some View {
        Menu {
            Toggle("Typewriter", isOn: Binding(get: { model.typewriter }, set: { _ in toggleTypewriter() }))
            Toggle("Focus", isOn: Binding(get: { model.focusMode }, set: { _ in model.toggleFocusMode() }))
            Toggle("Zen", isOn: Binding(get: { model.zenMode }, set: { _ in model.toggleZenMode() }))
        } label: { Image(systemName: "character.cursor.ibeam") }
            .menuIndicator(.hidden).fixedSize()
            .help("Writing modes").accessibilityLabel("Writing modes")
    }

    private func toggleTypewriter() {
        model.typewriter.toggle()
        model.editor?.refreshDecorations()
    }

    private var buttons: some View {
        HStack(spacing: 2) {
            HeaderToggle(isOn: model.typewriter, help: "Typewriter: keep the current line centred (⌘⇧Y)") {
                toggleTypewriter()
            } label: { Image(systemName: "character.cursor.ibeam") }
                .accessibilityLabel("Typewriter mode")
            HeaderToggle(isOn: model.focusMode, help: "Focus: dim everything but the current paragraph (⌘⇧F)") {
                model.toggleFocusMode()
            } label: { Image(systemName: "scope") }
                .accessibilityLabel("Focus mode")
            HeaderToggle(isOn: model.zenMode, help: "Zen: full screen, just the text (⌘⇧J, Esc to leave)") {
                model.toggleZenMode()
            } label: { Image(systemName: "leaf") }
                .accessibilityLabel("Zen mode")
        }
        .padding(2)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
    }
}

/// A compact toggle inside a header group: tinted when on.
struct HeaderToggle<Label: View>: View {
    let isOn: Bool
    let help: String
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button(action: action) {
            label()
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 7)
                .frame(minWidth: 26, minHeight: 22)
                .background(isOn ? Color.primary.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}
