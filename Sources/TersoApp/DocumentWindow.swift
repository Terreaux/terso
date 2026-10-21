// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import TersoCore

struct DocumentWindow: View {
    @Binding var document: MarkdownDocument
    let fileURL: URL?
    @Bindable var model: WorkspaceModel
    @State private var contentSize: CGSize = .zero
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
        .onGeometryChange(for: CGSize.self) { $0.size } action: { contentSize = $0 }
        .sheet(item: $model.thesaurusRequest) { ThesaurusView(model: model, request: $0) }
        .sheet(isPresented: $model.showAskPanel) { AskPanel(model: model) }
        .sheet(item: $model.writingStats) { WritingStatsView(tab: $0) }
        .sheet(isPresented: $model.showDocumentReport, onDismiss: model.documentReportDidDismiss) {
            if model.showDocumentStatistics {
                DocumentStatisticsView(model: model, availableSize: contentSize)
            } else {
                DocumentReport(model: model)
            }
        }
        .sheet(isPresented: $model.showBookOverview) { BookOverview(model: model) }
        .sheet(isPresented: $model.showBookDetails) { BookDetailsSheet(model: model) }
        .focusedSceneValue(\.workspace, model)
        .onAppear { model.fileURL = fileURL; RecentDocuments.shared.note(fileURL) }
        .onChange(of: fileURL) { _, new in model.fileURL = new; RecentDocuments.shared.note(new) }
        .onChange(of: prefs.domain) { _, _ in model.scheduleAnalysis() }
        .onChange(of: prefs.optionalRules) { _, _ in model.scheduleAnalysis() }
        .background(Color(nsColor: prefs.theme.background))

    }

    private var latex: Bool { RenderMode.isLaTeX(source: document.text, fileURL: fileURL) }

    private var editor: some View {
        // Manutius on LaTeX: the source stays editable on the left and TeX's
        // own pages stand beside it; Preview gives the pages the window.
        let pages = model.manutius && latex
        return HSplitView {
            source(pages: pages)
            if pages && model.renderMode != .preview {
                LaTeXBookPages(model: model, source: document.text, fileURL: fileURL)
                    .frame(minWidth: 260, idealWidth: 560, maxWidth: .infinity)
            }
        }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                floatingToolbar(at: .bottom)
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                floatingToolbar(at: .top)
            }
            .safeAreaInset(edge: .leading, spacing: 0) {
                floatingToolbar(at: .left)
            }
            .safeAreaInset(edge: .trailing, spacing: 0) {
                floatingToolbar(at: .right)
            }
            .overlay(alignment: .bottom) {
                if model.zenMode { ZenExit(model: model) } else if model.focusMode { FocusFooter(model: model) }
                else if model.manutius && (model.renderMode != .preview || pages) { BookStatusBar(model: model) }
            }
            .onChange(of: latex, initial: true) { _, new in model.latexBook.isLaTeX = new }
            .ignoresSafeArea(edges: model.focusMode ? .top : [])
    }

    @ViewBuilder private func floatingToolbar(at edge: ContextualToolbarEdge) -> some View {
        if !model.focusMode && prefs.contextualToolbarPlacement == .floating && prefs.contextualToolbarEdge == edge {
            ContextualToolbar(model: model, source: document.text,
                              undoManager: model.documentUndoManager, floating: true, vertical: edge.isVertical)
                .padding(.horizontal, edge.isVertical ? 8 : 12)
                .padding(.top, edge == .bottom ? 8 : 12)
                .padding(.bottom, model.manutius && edge != .top ? 32 : 12)
        }
    }

    private func source(pages: Bool) -> some View {
        ZStack {
            EditorView(text: $document.text, model: model, config: EditorConfig(prefs: prefs, model: model, latex: latex))
                .opacity(model.renderMode == .preview ? 0 : 1)
                .allowsHitTesting(model.renderMode != .preview)
                .accessibilityHidden(model.renderMode == .preview)
            if model.renderMode == .preview {
                if pages {
                    LaTeXBookPages(model: model, source: document.text, fileURL: fileURL)
                } else if latex {
                    TectonicPreview(source: document.text, fileURL: fileURL)
                } else {
                    MarkdownPreviewPane(source: document.text, model: model).id(fileURL?.deletingLastPathComponent())
                }
            }
        }
            .frame(minWidth: 280)
            .overlay(alignment: .trailing) {
                if prefs.showDocumentMap && !model.focusMode && model.renderMode != .preview {
                    IssueRail(model: model).padding(.trailing, 16)
                }
            }
            .overlay(alignment: .topLeading) {
                // Mixed draws Markdown as its platform will; Preview shows the
                // same chip beside what that platform won't render.
                if !latex, !model.manutius, !model.focusMode, model.renderMode == .mixed {
                    FlavourChip(model: model).padding(12).transition(.opacity)
                }
            }
            .overlay(alignment: .top) {
                if model.manutius, model.documentBook == nil, !model.bookSetupDeclined, model.renderMode != .preview {
                    BookSetupBanner(model: model).transition(.move(edge: .top).combined(with: .opacity))
                }
            }
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
