// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import TersoCore

struct DocumentWindow: View {
    @Binding var document: MarkdownDocument
    let fileURL: URL?
    @State private var model = WorkspaceModel()
    @State private var columns: NavigationSplitViewVisibility = .detailOnly
    @State private var columnsBeforeFocus: NavigationSplitViewVisibility = .detailOnly
    private var prefs: Preferences { Preferences.shared }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView(model: model, fileURL: fileURL)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } detail: {
            editor
                .inspector(isPresented: $model.showInspector) {
                    InspectorView(model: model)
                        .inspectorColumnWidth(min: 300, ideal: 380, max: 560)
                }
        }
        .toolbar(model.focusMode ? .hidden : .visible, for: .windowToolbar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Rendering mode", selection: $model.renderMode) {
                    ForEach(RenderMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                }.pickerStyle(.segmented).frame(width: 220)
                    .help("Source: raw text. Mixed: formatted text with editable math. Preview: fully rendered document.")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.inspectorTab = .review
                    model.showInspector = true
                } label: { Label("Review", systemImage: "text.magnifyingglass") }
                .help("Review writing")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { model.showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
                    .help("Show or hide the inspector")
            }
        }
        .sheet(item: $model.thesaurusRequest) { ThesaurusView(model: model, request: $0) }
        .sheet(isPresented: $model.showAskPanel) { AskPanel(model: model) }
        .focusedSceneValue(\.workspace, model)
        .onAppear { model.fileURL = fileURL }
        .onChange(of: fileURL) { _, new in model.fileURL = new }
        .onChange(of: model.focusMode) { _, focus in
            withAnimation(.easeInOut(duration: 0.25)) {
                if focus { columnsBeforeFocus = columns; columns = .detailOnly } else { columns = columnsBeforeFocus }
            }
        }
        .onChange(of: prefs.domain) { _, _ in model.scheduleAnalysis() }
        .background(Color(nsColor: .textBackgroundColor))
        .background(DocumentTabbing())
    }

    private var editor: some View {
        ZStack {
            EditorView(text: $document.text, model: model, config: EditorConfig(prefs: prefs, model: model))
                .opacity(model.renderMode == .preview ? 0 : 1)
                .allowsHitTesting(model.renderMode != .preview)
                .accessibilityHidden(model.renderMode == .preview)
            if model.renderMode == .preview {
                if RenderMode.isLaTeX(source: document.text, fileURL: fileURL) {
                    TectonicPreview(source: document.text, fileURL: fileURL)
                } else {
                    MarkdownPreview(source: document.text, model: model).id(fileURL?.deletingLastPathComponent())
                }
            }
        }
            .overlay(alignment: .trailing) {
                if prefs.showDocumentMap && !model.focusMode && model.renderMode != .preview {
                    IssueRail(model: model).padding(.trailing, 16)
                }
            }
            .overlay(alignment: .bottom) {
                if model.focusMode { FocusFooter(model: model) }
            }
            .ignoresSafeArea(edges: model.focusMode ? .top : [])
    }
}

/// A single quiet line in focus mode.
struct FocusFooter: View {
    let model: WorkspaceModel
    var body: some View {
        HStack(spacing: 14) {
            if let s = model.local?.statistics {
                Text("\(s.words.formatted()) words")
                Text(s.readingTimeLabel)
            }
            Button("Exit Focus") { model.toggleFocusMode() }.buttonStyle(.plain).keyboardShortcut(.escape, modifiers: [])
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
        .padding(.bottom, 10)
    }
}

struct WorkspaceKey: FocusedValueKey { typealias Value = WorkspaceModel }
extension FocusedValues {
    var workspace: WorkspaceModel? {
        get { self[WorkspaceKey.self] }
        set { self[WorkspaceKey.self] = newValue }
    }
}
