// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import SwiftUI
import TersoDocument

/// A document owns data, undo and a retained editor, but no NSWindow.
@objc(TersoTabDocument)
final class TabDocument: NSDocument, ObservableObject, Identifiable {
    let id = UUID()
    let model = WorkspaceModel()
    @Published var contents = MarkdownDocument()
    @Published private(set) var tabTitle = "Untitled"
    @Published private(set) var edited = false
    @Published private(set) var url: URL?
    weak var workspace: TabWorkspace?
    private var closeCompletion: ((Bool) -> Void)?
    private(set) var editorHost: NSHostingView<DocumentWindow>?

    override init() {
        super.init()
        undoManager = UndoManager()
        model.documentUndoManager = undoManager
    }

    override class var autosavesInPlace: Bool { true }
    override class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool { false }

    override func read(from data: Data, ofType typeName: String) throws {
        let (text, codec) = try PlainTextCodec.decode(data)
        MainActor.assumeIsolated {
            contents = MarkdownDocument(text: text)
            contents.codec = codec
            refreshEditor()
        }
    }

    override func data(ofType typeName: String) throws -> Data { try contents.codec.encode(contents.text) }

    override var fileURL: URL? {
        didSet { Task { @MainActor [weak self] in self?.refreshMetadata() } }
    }

    override func updateChangeCount(_ change: NSDocument.ChangeType) {
        super.updateChangeCount(change)
        refreshMetadata()
        DocumentTabs.shared.scheduleRecovery()
    }

    override func updateChangeCount(withToken changeCountToken: Any, for saveOperation: NSDocument.SaveOperationType) {
        super.updateChangeCount(withToken: changeCountToken, for: saveOperation)
        refreshMetadata()
        DocumentTabs.shared.scheduleRecovery()
    }

    func refreshMetadata() {
        tabTitle = displayName
        edited = isDocumentEdited
        url = fileURL
        model.fileURL = fileURL
        refreshEditor()
        workspace?.refreshWindowTitle()
    }

    func hostedEditor() -> NSView {
        if let editorHost { return editorHost }
        let host = NSHostingView(rootView: editorView())
        host.sizingOptions = []
        editorHost = host
        return host
    }

    private func refreshEditor() {
        if let editorHost { editorHost.rootView = editorView() }
    }

    private func editorView() -> DocumentWindow {
        let binding = Binding<MarkdownDocument>(get: { [unowned self] in self.contents }, set: { [unowned self] value in
            guard self.contents.text != value.text else { return }
            self.contents = value
            // NSDocument observes this editor's undo manager and updates its
            // change count when groups close/undo/redo. Counting here as well
            // would leave a fully undone document incorrectly marked edited.
            DocumentTabs.shared.scheduleRecovery()
        })
        return DocumentWindow(document: binding, fileURL: fileURL, model: model)
    }

    override func makeWindowControllers() { DocumentTabs.shared.present(self) }
    override func showWindows() { DocumentTabs.shared.present(self) }
    override var windowForSheet: NSWindow? { workspace?.window }

    func requestClose(_ completion: @escaping (Bool) -> Void) {
        guard closeCompletion == nil else { completion(false); return }
        workspace?.select(self)
        closeCompletion = completion
        canClose(withDelegate: self, shouldClose: #selector(didReviewClose(_:shouldClose:contextInfo:)), contextInfo: nil)
    }

    @objc private func didReviewClose(_ document: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?) {
        let completion = closeCompletion
        closeCompletion = nil
        completion?(shouldClose)
    }

    override func close() {
        workspace?.remove(self)
        editorHost = nil
        super.close()
        DocumentTabs.shared.scheduleRecovery()
    }
}

@MainActor
final class TabDocumentController: NSDocumentController {
    static let sharedController = TabDocumentController()
    override init() {
        super.init()
        autosavingDelay = 10
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }
    override var defaultType: String? { "net.daringfireball.markdown" }
    override var currentDocument: NSDocument? { DocumentTabs.shared.activeDocument }
    override func document(for window: NSWindow) -> NSDocument? {
        DocumentTabs.shared.workspaces.first { $0.window === window }?.selected
    }
    override func makeUntitledDocument(ofType typeName: String) throws -> NSDocument {
        let document = TabDocument()
        document.fileType = typeName
        return document
    }
    override func makeDocument(withContentsOf url: URL, ofType typeName: String) throws -> NSDocument {
        try TabDocument(contentsOf: url, ofType: typeName)
    }
}
