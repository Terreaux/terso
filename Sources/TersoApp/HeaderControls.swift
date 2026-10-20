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

/// How the page is drawn and how you write on it, as one control: the render
/// mode, what Mixed renders for this document, then one writing mode.
/// Typewriter and Letterbox follow the caret, so they wait out Preview.
struct ViewControls: View {
    @Bindable var model: WorkspaceModel
    let latex: Bool
    /// Extension options (citations, footnotes, comments) appear only when used.
    let source: String
    var density: HeaderDensity = .full
    @State private var showingMixedOptions = false

    var body: some View {
        if density == .minimal { menu } else { controls }
    }

    private var caretModesAvailable: Bool { model.renderMode != .preview }

    private var menu: some View {
        Menu {
            Picker("Rendering", selection: $model.renderMode) {
                ForEach(RenderMode.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.inline)
            if model.renderMode == .mixed { mixedSection }
            if model.writingMode == .manutius {
                Button("Book Design…") { model.showBookDesign() }
                Button("Whole Book…") { model.showBookOverview = true }
            }
            Picker("Writing", selection: Binding(get: { model.writingMode }, set: { model.setWritingMode($0) })) {
                ForEach(WritingMode.allCases) { mode in
                    Text(mode.title).tag(mode).disabled(mode.shapesEditor && !caretModesAvailable)
                }
            }.pickerStyle(.inline)
        } label: { Image(systemName: "eye") }
            .menuIndicator(.hidden).fixedSize()
            .help("View: rendering and writing modes").accessibilityLabel("View")
    }

    @ViewBuilder private var mixedSection: some View {
        Section("Mixed renders") {
            mixedToggles
        }
        if !latex {
            Picker("Markdown Flavour", selection: flavourChoice) { flavourOptions }
        }
    }

    /// nil follows what the file's folder says, else Settings.
    private var flavourChoice: Binding<MarkdownFlavour?> {
        Binding(get: { model.chosenFlavour }, set: { model.chosenFlavour = $0 })
    }

    @ViewBuilder private var flavourOptions: some View {
        Text("Automatic (\(model.automaticFlavour.title))").tag(MarkdownFlavour?.none)
        Divider()
        ForEach(MarkdownFlavour.allCases) { Text($0.title).tag(Optional($0)) }
    }

    private var mixedToggles: some View {
        ForEach(MixedElement.available(latex: latex, text: source, flavour: model.markdownFlavour)) { element in
            Toggle(element.title, isOn: Binding(
                get: { model.prefs.mixedRendered.contains(element) },
                set: { on in
                    if on { model.prefs.mixedRendered.insert(element) } else { model.prefs.mixedRendered.remove(element) }
                }))
        }
    }

    private var renderingModes: some View {
        HStack(spacing: 0) {
            ForEach(RenderMode.allCases) { mode in
                if mode == .mixed {
                    modeButton(mode)
                        .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                            model.renderMode = .mixed
                            showingMixedOptions = true
                        })
                        .contextMenu { mixedSection }
                        .accessibilityAction(named: "Mixed rendering options") { showingMixedOptions = true }
                        .popover(isPresented: $showingMixedOptions, arrowEdge: .bottom) {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Mixed renders").font(.headline)
                                mixedToggles
                                if !latex {
                                    Divider()
                                    // Mixed draws only what this platform renders and marks the rest.
                                    Picker("Flavour", selection: flavourChoice) { flavourOptions }
                                        .help(model.markdownFlavour.help)
                                }
                            }
                            .toggleStyle(.checkbox)
                            .padding(16)
                            .frame(width: 270)
                        }
                } else {
                    modeButton(mode)
                }
            }
        }
        .padding(2)
        .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
        .frame(width: density == .full ? 220 : 170)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Rendering mode")
    }

    private func modeButton(_ mode: RenderMode) -> some View {
        Button { model.renderMode = mode } label: {
            Text(mode.rawValue)
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, minHeight: 22)
                .background(model.renderMode == mode ? Color.primary.opacity(0.16) : .clear,
                            in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mode.rawValue)
        .accessibilityAddTraits(model.renderMode == mode ? [.isSelected] : [])
        .help(mode == .mixed ? "Mixed: hold or right-click for rendering options" : "\(mode.rawValue) mode")
    }

    private var controls: some View {
        HStack(spacing: 4) {
            renderingModes
            HStack(spacing: 2) {
                ForEach(WritingMode.allCases) { mode in
                    let unavailable = mode.shapesEditor && !caretModesAvailable
                    HeaderToggle(isOn: model.writingMode == mode,
                                 help: unavailable ? "\(mode.title) needs an editable view" : mode.help) {
                        model.setWritingMode(mode)
                    } label: { Image(systemName: mode.symbol) }
                        .disabled(unavailable)
                        .accessibilityLabel("\(mode.title) mode")
                }
            }
            .padding(2)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
            // Book options belong to Manutius and appear only with it.
            if model.writingMode == .manutius { BookControls(model: model) }
        }
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
