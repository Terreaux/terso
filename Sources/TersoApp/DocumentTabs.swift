// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import SwiftUI
import TersoDocument

@MainActor @Observable
final class DocumentTabs {
    static let shared = DocumentTabs()
    private(set) var workspaces: [TabWorkspace] = []
    var activeWorkspace: TabWorkspace?
    var activeDocument: TabDocument? { activeWorkspace?.selected }
    private var recoveryTask: Task<Void, Never>?
    private var restoring = false
    var isRunning = false
    /// Shown over the front window at launch, then cleared.
    var launchQuote: WritingQuote?
    private let recoveryURL: URL

    init(recoveryURL: URL = AppDataPaths.file("DocumentTabs.json")) {
        self.recoveryURL = recoveryURL
    }

    func newWorkspace() -> TabWorkspace {
        let workspace = TabWorkspace()
        workspaces.append(workspace)
        activeWorkspace = workspace
        return workspace
    }

    /// Reuses an empty window's start screen before creating another window.
    func showStartWindow() {
        let workspace = workspaces.first { $0.documents.isEmpty } ?? newWorkspace()
        activeWorkspace = workspace
        workspace.showWindow(nil)
    }

    func present(_ document: TabDocument) {
        let workspace = document.workspace ?? activeWorkspace ?? newWorkspace()
        workspace.insert(document)
        workspace.showWindow(nil)
        activeWorkspace = workspace
        scheduleRecovery()
    }

    func newDocument() {
        let workspace = activeWorkspace ?? newWorkspace()
        workspace.showStart()
        workspace.showWindow(nil)
    }

    func createDocument(_ request: DocumentCreationRequest, in workspace: TabWorkspace) {
        let document = request.makeDocument()
        TabDocumentController.sharedController.addDocument(document)
        workspace.insert(document)
        workspace.showWindow(nil)
        activeWorkspace = workspace
        scheduleRecovery()
    }

    func open(_ url: URL) {
        TabDocumentController.sharedController.openDocument(withContentsOf: url, display: true) { _, _, error in
            if let error { NSApp.presentError(error) }
        }
    }

    func detach(_ document: TabDocument) {
        guard let source = document.workspace, source.documents.count > 1 else { return }
        source.remove(document)
        let destination = newWorkspace()
        destination.insert(document)
        destination.showWindow(nil)
        scheduleRecovery()
    }

    func mergeWindows() {
        guard let destination = activeWorkspace else { return }
        for source in workspaces where source !== destination {
            if source.documents.isEmpty { source.close(); continue }
            for document in source.documents {
                source.remove(document, closingWhenEmpty: true)
                destination.insert(document)
            }
        }
        destination.showWindow(nil)
        scheduleRecovery()
    }

    func moveTab(id: UUID, to destination: TabWorkspace, before target: TabDocument) {
        guard let source = workspaces.first(where: { $0.documents.contains { $0.id == id } }),
              let document = source.documents.first(where: { $0.id == id }), document !== target else { return }
        if source !== destination { source.remove(document, closingWhenEmpty: true) }
        destination.insert(document, before: target)
        scheduleRecovery()
    }

    func remove(_ workspace: TabWorkspace) {
        workspaces.removeAll { $0 === workspace }
        if activeWorkspace === workspace { activeWorkspace = workspaces.last }
        scheduleRecovery()
    }

    func scheduleRecovery() {
        guard isRunning, !restoring else { return }
        recoveryTask?.cancel()
        recoveryTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveRecovery()
        }
    }

    struct SavedDocument: Codable {
        var url: URL?
        var data: Data
        var edited: Bool
        var typeName: String?
        var bookMode: Bool?
    }
    struct SavedWorkspace: Codable {
        var documents: [SavedDocument]
        var selected: Int
    }

    func saveRecovery() {
        guard isRunning else { return }
        do {
            let saved = try workspaces.map { workspace in
                SavedWorkspace(documents: try workspace.documents.map {
                    SavedDocument(url: $0.fileURL, data: try $0.data(ofType: $0.fileType ?? "public.plain-text"), edited: $0.isDocumentEdited, typeName: $0.fileType, bookMode: $0.model.manutius)
                }, selected: workspace.documents.firstIndex { $0 === workspace.selected } ?? 0)
            }
            try FileManager.default.createDirectory(at: recoveryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(saved).write(to: recoveryURL, options: .atomic)
        } catch { NSLog("Terso session recovery: %@", error.localizedDescription) }
    }

    func restore() {
        guard let data = try? Data(contentsOf: recoveryURL),
              let saved = try? JSONDecoder().decode([SavedWorkspace].self, from: data) else { return }
        restoring = true
        defer { restoring = false }
        for group in saved where !group.documents.isEmpty {
            let workspace = newWorkspace()
            for item in group.documents {
                do {
                    if let url = item.url, TabDocumentController.sharedController.document(for: url) != nil { continue }
                    let typeName = item.typeName ?? "public.plain-text"
                    let document: TabDocument
                    if let url = item.url, FileManager.default.fileExists(atPath: url.path) {
                        document = try TabDocument(contentsOf: url, ofType: typeName)
                        if item.edited { try document.read(from: item.data, ofType: typeName) }
                    } else {
                        document = TabDocument()
                        document.fileType = typeName
                        try document.read(from: item.data, ofType: document.fileType!)
                    }
                    if let bookMode = item.bookMode { document.model.setWritingMode(bookMode ? .manutius : .hemingway) }
                    if typeName == "public.plain-text" { document.model.renderMode = .source }
                    TabDocumentController.sharedController.addDocument(document)
                    NSFileCoordinator.addFilePresenter(document)
                    if item.edited || item.url != nil && document.fileURL == nil { document.updateChangeCount(.changeDone) }
                    workspace.insert(document)
                } catch { NSApp.presentError(error) }
            }
            if !workspace.documents.isEmpty {
                workspace.select(workspace.documents[min(group.selected, workspace.documents.count - 1)])
                workspace.showWindow(nil)
            } else {
                workspace.close()
                remove(workspace)
            }
        }
    }
}

@MainActor @Observable
final class TabWorkspace: NSWindowController, NSWindowDelegate {
    private(set) var documents: [TabDocument] = []
    private(set) var selected: TabDocument?
    /// A transient "New Tab" showing the start screen beside open documents.
    /// Opening or selecting any document replaces it.
    private(set) var showingStart = false
    private var closing = false

    init() {
        let window = TabWorkspaceWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 520, height: 360)
        window.isReleasedWhenClosed = false
        window.delegate = self
        let host = NSHostingView(rootView: DocumentTabsView(workspace: self))
        host.sizingOptions = []
        window.contentView = host
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func insert(_ document: TabDocument) {
        if !documents.contains(where: { $0 === document }) { documents.append(document) }
        document.workspace = self
        document.refreshMetadata()
        select(document)
    }

    func insert(_ document: TabDocument, before target: TabDocument) {
        documents.removeAll { $0 === document }
        let index = documents.firstIndex { $0 === target } ?? documents.endIndex
        documents.insert(document, at: index)
        document.workspace = self
        select(document)
    }

    func select(_ document: TabDocument) {
        guard documents.contains(where: { $0 === document }) else { return }
        // End the current typing group before giving another editor focus.
        if let editor = selected?.model.editor as? EditorCoordinator { editor.textView?.breakUndoCoalescing() }
        selected = document
        showingStart = false
        DocumentTabs.shared.activeWorkspace = self
        refreshWindowTitle()
        DocumentTabs.shared.scheduleRecovery()
    }

    func select(offset: Int) {
        guard !documents.isEmpty, let index = documents.firstIndex(where: { $0 === selected }) else { return }
        select(documents[(index + offset + documents.count) % documents.count])
    }

    /// Closing the last tab leaves the window on its start screen. Moving the
    /// last tab elsewhere, or closing the whole window, closes it instead.
    func remove(_ document: TabDocument, closingWhenEmpty: Bool = false) {
        guard let index = documents.firstIndex(where: { $0 === document }) else { return }
        documents.remove(at: index)
        document.workspace = nil
        if selected === document { selected = documents.isEmpty ? nil : documents[min(index, documents.count - 1)] }
        refreshWindowTitle()
        if documents.isEmpty && (closingWhenEmpty || closing) {
            window?.close()
            DocumentTabs.shared.remove(self)
        }
    }

    func showStart() {
        showingStart = true
        DocumentTabs.shared.activeWorkspace = self
        refreshWindowTitle()
    }

    func dismissStart() {
        guard showingStart else { return }
        showingStart = false
        refreshWindowTitle()
    }

    func refreshWindowTitle() {
        guard !showingStart else {
            window?.title = "New Tab"; window?.representedURL = nil; window?.isDocumentEdited = false
            return
        }
        window?.title = selected?.displayName ?? "Terso"
        window?.representedURL = selected?.fileURL
        window?.isDocumentEdited = selected?.isDocumentEdited ?? false
    }

    func closeTab(_ document: TabDocument) {
        document.requestClose { allowed in if allowed { document.close() } }
    }

    func windowDidBecomeKey(_ notification: Notification) { DocumentTabs.shared.activeWorkspace = self }

    /// Edit › Undo/Redo validate and act through the window's undo
    /// manager. The editor registers on its document's, so hand that one out.
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { showingStart ? nil : selected?.undoManager }

    func windowWillClose(_ notification: Notification) {
        // The hosting view retains this workspace through its root view.
        // Break that ownership cycle when its real window closes.
        window?.contentView = nil
        DocumentTabs.shared.remove(self)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !documents.isEmpty else { return true }
        guard !closing else { return false }
        closing = true
        closeNext()
        return false
    }

    private func closeNext() {
        guard let document = documents.first else { closing = false; return }
        document.requestClose { [weak self] allowed in
            guard let self else { return }
            if allowed { document.close(); self.closeNext() }
            else { self.closing = false }
        }
    }
}

@MainActor
final class TersoAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DocumentTabs.shared.isRunning = true
        DocumentTabs.shared.restore()
        if DocumentTabs.shared.workspaces.isEmpty { DocumentTabs.shared.showStartWindow() }
        if Preferences.shared.greetWithQuote { DocumentTabs.shared.launchQuote = WritingQuote.next() }
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        for filename in filenames { DocumentTabs.shared.open(URL(fileURLWithPath: filename)) }
        sender.reply(toOpenOrPrint: .success)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { DocumentTabs.shared.showStartWindow() }
        return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Persist recovery before AppKit reviews saves. Keep documents open so
        // their tab order and unsaved text survive a normal quit as well.
        DocumentTabs.shared.saveRecovery()
        Task { @MainActor in
            self.reviewForTermination(Array(TabDocumentController.sharedController.documents.compactMap { $0 as? TabDocument }))
        }
        return .terminateLater
    }
    private func reviewForTermination(_ documents: [TabDocument]) {
        guard let first = documents.first else {
            DocumentTabs.shared.saveRecovery()
            // Window teardown must not replace the saved session with an empty
            // workspace snapshot after termination has been approved.
            DocumentTabs.shared.isRunning = false
            NSApp.reply(toApplicationShouldTerminate: true)
            return
        }
        first.requestClose { allowed in
            if allowed {
                // A successful save clears edited state; a still-edited
                // document means the user chose Don't Save. Do not recover it.
                if first.isDocumentEdited { first.close() }
                self.reviewForTermination(Array(documents.dropFirst()))
            }
            else { NSApp.reply(toApplicationShouldTerminate: false) }
        }
    }
}
