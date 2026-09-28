// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import SwiftUI

struct DocumentTabsView: View {
    @Bindable var workspace: TabWorkspace

    var body: some View {
        VStack(spacing: 0) {
            if let document = workspace.selected {
                if !document.model.focusMode {
                    DocumentControls(model: document.model)
                    Divider()
                }
            }
            HStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(spacing: 2) {
                            ForEach(workspace.documents) { document in
                                DocumentTabLabel(document: document, selected: document === workspace.selected,
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
                        }.padding(4)
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: workspace.selected?.id) { _, id in if let id { proxy.scrollTo(id) } }
                }
                Button { DocumentTabs.shared.newDocument() } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless).help("New Tab").accessibilityLabel("New Tab").padding(.horizontal, 12)
            }
            .frame(height: 36)
            .background(.bar)
            Divider()
            if let document = workspace.selected {
                RetainedDocumentEditor(document: document)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .background(selected ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 5))
        .help(document.fileURL?.path ?? document.tabTitle)
    }
}

private struct DocumentControls: View {
    @Bindable var model: WorkspaceModel
    var body: some View {
        HStack {
            Button { model.showSidebar.toggle() } label: { Image(systemName: "sidebar.left") }
                .help("Show or hide the sidebar").accessibilityLabel("Sidebar")
            Spacer()
            Picker("Rendering mode", selection: $model.renderMode) {
                ForEach(RenderMode.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).frame(width: 220).labelsHidden()
            Spacer()
            Button { model.inspectorTab = .review; model.showInspector = true } label: { Image(systemName: "text.magnifyingglass") }
                .help("Review writing").accessibilityLabel("Review")
            Button { model.showInspector.toggle() } label: { Image(systemName: "sidebar.right") }
                .help("Show or hide the inspector").accessibilityLabel("Inspector")
        }
        .buttonStyle(.borderless).padding(.horizontal, 14).padding(.vertical, 8)
        .background(.bar)
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
                ForEach(TabDocumentController.sharedController.recentDocumentURLs, id: \.self) { url in
                    Button(url.lastPathComponent) { tabs.open(url) }
                }
                Divider()
                Button("Clear Menu") { TabDocumentController.sharedController.clearRecentDocuments(nil) }
            }
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { tabs.activeDocument?.save(nil) }.keyboardShortcut("s").disabled(tabs.activeDocument == nil)
            Button("Save As…") { tabs.activeDocument?.saveAs(nil) }.keyboardShortcut("s", modifiers: [.command, .shift]).disabled(tabs.activeDocument == nil)
            Button("Duplicate") { tabs.activeDocument?.duplicate(nil) }.disabled(tabs.activeDocument == nil)
            Button("Rename…") { tabs.activeDocument?.rename(nil) }.disabled(tabs.activeDocument?.fileURL == nil)
            Button("Revert to Saved…") { tabs.activeDocument?.revertToSaved(nil) }.disabled(tabs.activeDocument?.fileURL == nil)
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
        }
        CommandGroup(before: .saveItem) {
            Button("Close Tab") {
                if let document = tabs.activeDocument { document.workspace?.closeTab(document) }
            }.keyboardShortcut("w").disabled(tabs.activeDocument == nil)
        }
    }
}
