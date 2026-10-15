// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import TersoCore

struct DocumentWindow: View {
    @Binding var document: MarkdownDocument
    let fileURL: URL?
    @Bindable var model: WorkspaceModel
    private var prefs: Preferences { Preferences.shared }

    var body: some View {
        // Window-level controls own sidebar visibility. A plain split view
        // avoids NavigationSplitView installing another title-bar toggle in
        // the retained document's hosting view.
        HSplitView {
            if model.showSidebar && !model.focusMode {
                SidebarView(model: model, fileURL: fileURL)
                    .frame(minWidth: 180, idealWidth: 220, maxWidth: 320)
            }
            editor
                .inspector(isPresented: $model.showInspector) {
                    InspectorView(model: model)
                        .inspectorColumnWidth(min: 300, ideal: 380, max: 560)
                }
        }
        .toolbar(.hidden, for: .windowToolbar)
        .sheet(item: $model.thesaurusRequest) { ThesaurusView(model: model, request: $0) }
        .sheet(isPresented: $model.showAskPanel) { AskPanel(model: model) }
        .focusedSceneValue(\.workspace, model)
        .onAppear { model.fileURL = fileURL; RecentDocuments.shared.note(fileURL) }
        .onChange(of: fileURL) { _, new in model.fileURL = new; RecentDocuments.shared.note(new) }
        .onChange(of: prefs.domain) { _, _ in model.scheduleAnalysis() }
        .background(Color(nsColor: prefs.theme.background))

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
                if model.zenMode { ZenExit(model: model) } else if model.focusMode { FocusFooter(model: model) }
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

/// Zen shows nothing but the text; Esc still leads out.
struct ZenExit: View {
    let model: WorkspaceModel
    var body: some View {
        Button("Exit Zen") { model.toggleZenMode() }
            .keyboardShortcut(.escape, modifiers: [])
            .opacity(0).frame(width: 0, height: 0)
            .accessibilityLabel("Exit Zen mode")
    }
}

struct WorkspaceKey: FocusedValueKey { typealias Value = WorkspaceModel }
extension FocusedValues {
    var workspace: WorkspaceModel? {
        get { self[WorkspaceKey.self] }
        set { self[WorkspaceKey.self] = newValue }
    }
}
