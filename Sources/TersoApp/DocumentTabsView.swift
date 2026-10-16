// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import SwiftUI

struct DocumentTabsView: View {
    @Bindable var workspace: TabWorkspace

    var body: some View {
        Group {
            if workspace.documents.isEmpty {
                WorkspaceStartView(workspace: workspace)
            } else {
                tabbedEditor
            }
        }
        .overlay {
            // Only the front window greets, so restored windows don't each show one.
            if let quote = DocumentTabs.shared.launchQuote, DocumentTabs.shared.activeWorkspace === workspace {
                LaunchQuoteView(quote: quote) {
                    withAnimation(.easeOut(duration: 0.4)) { DocumentTabs.shared.launchQuote = nil }
                }
                .transition(.opacity)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if DocumentTabs.shared.activeWorkspace === workspace, let award = WritingStats.shared.latestAward {
                AwardNote(award: award) {
                    workspace.selected?.model.writingStats = .awards
                }
                .padding(18)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private var tabbedEditor: some View {
        VStack(spacing: 0) {
            if let document = workspace.selected, !workspace.showingStart {
                if !document.model.focusMode {
                    DocumentControls(document: document)
                    Divider()
                }
            }
            if workspace.selected?.model.zenMode != true || workspace.showingStart {
                HStack(spacing: 0) {
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal) {
                            HStack(spacing: 2) {
                                ForEach(workspace.documents) { document in
                                    DocumentTabLabel(document: document, selected: document === workspace.selected && !workspace.showingStart,
                                                     select: { workspace.select(document) }, close: { workspace.closeTab(document) })
                                        .id(document.id)
                                        .draggable(document.id.uuidString)
                                        .dropDestination(for: String.self) { items, _ in
                                            guard let item = items.first, let id = UUID(uuidString: item) else { return false }
                                            DocumentTabs.shared.moveTab(id: id, to: workspace, before: document)
                                            return true
                                        }
                                        .contextMenu {
                                            Button("Move Tab to New Window") { DocumentTabs.shared.detach(document) }
                                                .disabled(workspace.documents.count < 2)
                                            Button("Close Tab") { workspace.closeTab(document) }
                                        }
                                }
                                if workspace.showingStart {
                                    StartTabLabel(close: { workspace.dismissStart() }).id("start")
                                }
                            }.padding(4)
                        }
                        .scrollIndicators(.hidden)
                        .onChange(of: workspace.selected?.id) { _, id in if let id { proxy.scrollTo(id) } }
                        .onChange(of: workspace.showingStart) { _, showing in if showing { proxy.scrollTo("start") } }
                    }
                    Button { workspace.showStart() } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless).help("New Tab").accessibilityLabel("New Tab").padding(.horizontal, 12)
                }
                .frame(height: 36)
                .themedChrome(Preferences.shared.theme)
                Divider()
            }
            if workspace.showingStart {
                WorkspaceStartView(workspace: workspace)
            } else if let document = workspace.selected {
                RetainedDocumentEditor(document: document)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .themedTint(Preferences.shared.theme)
    }
}

private struct DocumentTabLabel: View {
    @ObservedObject var document: TabDocument
    let selected: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: select) {
                HStack(spacing: 6) {
                    if document.edited { Circle().fill(.secondary).frame(width: 6, height: 6) }
                    Text(document.tabTitle).lineLimit(1)
                        .fontWeight(selected ? .semibold : .regular)
                }
                .frame(minWidth: 70, maxWidth: 190, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? [.isSelected] : [])
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }
                .buttonStyle(.plain).accessibilityLabel("Close \(document.tabTitle)")
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(selected ? Color(nsColor: Preferences.shared.theme.accent).opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 5))
        .help(document.fileURL?.path ?? document.tabTitle)
    }
}

private struct StartTabLabel: View {
    let close: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Text("New Tab").fontWeight(.semibold).lineLimit(1)
                .frame(minWidth: 70, maxWidth: 190, alignment: .leading)
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }
                .buttonStyle(.plain).accessibilityLabel("Close New Tab")
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color(nsColor: Preferences.shared.theme.accent).opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
        .accessibilityAddTraits(.isSelected)
    }
}

private struct DocumentControls: View {
    @ObservedObject var document: TabDocument
    var body: some View {
        // Narrow windows drop counts first, then fold groups into menus,
        // so the header never forces the window wider than it is.
        ViewThatFits(in: .horizontal) {
            row(.full)
            row(.compact)
            row(.minimal)
        }
        .buttonStyle(.borderless).padding(.horizontal, 14).padding(.vertical, 8)
        .themedChrome(Preferences.shared.theme)
    }

    private func row(_ density: HeaderDensity) -> some View {
        @Bindable var model = document.model
        return HStack {
            Button { model.showSidebar.toggle() } label: { Image(systemName: "sidebar.left") }
                .help("Show or hide the sidebar").accessibilityLabel("Sidebar")
            HighlightControls(model: model, density: density).padding(.leading, 6)
            Spacer(minLength: 8)
            if Preferences.shared.showWritingProgress {
                HStack(spacing: 6) {
                    TodayButton(density: density) { model.writingStats = .overview }
                    AwardStack(density: density) { model.writingStats = .awards }
                }
                Spacer(minLength: 8)
            }
            // How the page looks and how you write on it sit together.
            ViewControls(model: model, latex: DocumentExport.isLaTeX(document), source: document.contents.text, density: density)
            Spacer(minLength: 8)
            ThemeMenu()
            CopyDocumentButton(text: document.contents.text)
                .id(document.id)
            ExportMenu(document: document)
            Button { model.showDocumentReport = true } label: { Image(systemName: "text.magnifyingglass") }
                .help("Document report: word count, reading time and reading level").accessibilityLabel("Document Report")
                // A popover, not a sheet: a click anywhere outside closes it.
                .popover(isPresented: $model.showDocumentReport, arrowEdge: .bottom) { DocumentReport(model: model) }
            Button { model.showInspector.toggle() } label: { Image(systemName: "sidebar.right") }
                .help("Show or hide the inspector").accessibilityLabel("Inspector")
        }
    }
}

private struct CopyDocumentButton: View {
    let text: String
    @State private var copyConfirmation: UUID?

    var body: some View {
        Button {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            if pasteboard.setString(text, forType: .string) {
                copyConfirmation = UUID()
            } else {
                copyConfirmation = nil
                NSSound.beep()
            }
        } label: {
            Image(systemName: copyConfirmation == nil ? "square.on.square" : "checkmark")
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .disabled(text.isEmpty)
        .help(copyConfirmation == nil ? "Copy entire document as plain text, including source markup" : "Copied")
        .accessibilityLabel("Copy entire document")
        .accessibilityValue(copyConfirmation == nil ? "" : "Copied")
        .onChange(of: text) { copyConfirmation = nil }
        .task(id: copyConfirmation) {
            guard copyConfirmation != nil else { return }
            do {
                try await Task.sleep(for: .seconds(1.5))
                copyConfirmation = nil
            } catch { /* A new copy, edit, or tab switch cancels the old confirmation. */ }
        }
    }
}

/// Swaps retained views, never windows. Caret, scroll, undo and view-local state
/// survive tab selection and moving a document to another workspace window.
struct RetainedDocumentEditor: NSViewRepresentable {
    let document: TabDocument
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ container: NSView, context: Context) {
        let editor = document.hostedEditor()
        guard editor.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        editor.removeFromSuperview()
        editor.frame = container.bounds
        editor.autoresizingMask = [.width, .height]
        container.addSubview(editor)
        DispatchQueue.main.async { [weak container, weak editor, weak document] in
            guard let container, editor?.superview === container,
                  document?.workspace?.selected === document,
                  let coordinator = document?.model.editor as? EditorCoordinator else { return }
            container.window?.makeFirstResponder(coordinator.textView)
        }
    }
}

struct DocumentTabCommands: Commands {
    private var tabs: DocumentTabs { .shared }
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Tab") { tabs.newDocument() }.keyboardShortcut("n")
            Button("New Window") { _ = tabs.newWorkspace(); tabs.newDocument() }.keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Open…") { TabDocumentController.sharedController.openDocument(nil) }.keyboardShortcut("o")
            Menu("Open Recent") {
                ForEach(RecentDocuments.shared.urls(limit: 15), id: \.self) { url in
                    Button(url.lastPathComponent) { tabs.open(url) }
                }
                Divider()
                Button("Clear Menu") { RecentDocuments.shared.clear() }
            }
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { tabs.activeDocument?.save(nil) }.keyboardShortcut("s").disabled(tabs.activeDocument == nil)
            Button("Save As…") { tabs.activeDocument?.saveAs(nil) }.keyboardShortcut("s", modifiers: [.command, .shift]).disabled(tabs.activeDocument == nil)
            Button("Duplicate") { tabs.activeDocument?.duplicate(nil) }.disabled(tabs.activeDocument == nil)
            Button("Rename…") { tabs.activeDocument?.rename(nil) }.disabled(tabs.activeDocument?.fileURL == nil)
            Button("Revert to Saved…") { tabs.activeDocument?.revertToSaved(nil) }.disabled(tabs.activeDocument?.fileURL == nil)
            Divider()
            Menu("Export As") {
                if let document = tabs.activeDocument {
                    let latex = DocumentExport.isLaTeX(document)
                    ForEach(ExportFormat.available(latex: latex)) { format in
                        Button(format.title(latex: latex) + "…") { DocumentExport.export(document, as: format) }
                    }
                }
            }.disabled(tabs.activeDocument == nil)
        }
        CommandGroup(replacing: .windowArrangement) {
            Button("Next Tab") { tabs.activeWorkspace?.select(offset: 1) }.keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Tab") { tabs.activeWorkspace?.select(offset: -1) }.keyboardShortcut("[", modifiers: [.command, .shift])
            Button("Move Tab to New Window") { if let document = tabs.activeDocument { tabs.detach(document) } }
                .disabled((tabs.activeWorkspace?.documents.count ?? 0) < 2)
            Button("Merge All Windows") { tabs.mergeWindows() }.disabled(tabs.workspaces.count < 2)
        }
        CommandGroup(replacing: .toolbar) {
            Button("Toggle Sidebar") { tabs.activeDocument?.model.showSidebar.toggle() }.keyboardShortcut("s", modifiers: [.command, .control])
            Button("Toggle Inspector") { tabs.activeDocument?.model.showInspector.toggle() }.keyboardShortcut("i", modifiers: [.command, .option])
            Button("Writing Stats…") { tabs.activeDocument?.model.writingStats = .overview }.disabled(tabs.activeDocument == nil)
        }
        CommandGroup(before: .saveItem) {
            Button(tabs.activeDocument == nil ? "Close Window" : "Close Tab") {
                if let workspace = tabs.activeWorkspace, workspace.showingStart { workspace.dismissStart() }
                else if let document = tabs.activeDocument { document.workspace?.closeTab(document) }
                else { tabs.activeWorkspace?.window?.performClose(nil) }
            }.keyboardShortcut("w").disabled(tabs.activeWorkspace == nil)
        }
    }
}
