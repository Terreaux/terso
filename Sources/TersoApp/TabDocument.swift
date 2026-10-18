// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import SwiftUI
import TersoDocument
import UniformTypeIdentifiers

/// A document owns data, undo and a retained editor, but no NSWindow.
@objc(TersoTabDocument)
final class TabDocument: NSDocument, ObservableObject, Identifiable {
    let id = UUID()
    let model = WorkspaceModel()
    @Published var contents = MarkdownDocument()
    @Published private(set) var tabTitle = "Untitled"
    @Published private(set) var edited = false
    @Published private(set) var url: URL?
    /// A companion-package failure never puts the saved manuscript at risk.
    /// Kept visible until a later save or an explicit retry succeeds.
    @Published private(set) var bookPackageError: String?
    private var bookPackageDirectory: URL?
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
            bookPackageError = nil
            bookPackageDirectory = nil
            let book = RenderMode.isLaTeX(source: text, fileURL: fileURL)
                ? BookDesign.read(latex: text, defaults: model.prefs.bookDesign)
                : BookDesign.read(from: text, defaults: model.prefs.bookDesign)
            if book != nil {
                model.setWritingMode(.manutius)
                model.showSidebar = true
            }
            refreshEditor()
        }
    }

    override func data(ofType typeName: String) throws -> Data { try contents.codec.encode(contents.text) }

    override func save(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
                       completionHandler: @escaping (Error?) -> Void) {
        // A Markdown tutorial or plain-text note can quote this command.
        // Its explicitly selected format and destination take precedence over
        // source heuristics, so saving examples never creates a sidecar file.
        let nonLaTeXType = typeName == UTType.markdownText.identifier || typeName == UTType.plainText.identifier
        let nonLaTeXExtension = ["md", "markdown", "txt"].contains(url.pathExtension.lowercased())
        let latex = !nonLaTeXType && !nonLaTeXExtension
            && (typeName == UTType.latexSource.identifier || RenderMode.isLaTeX(source: contents.text, fileURL: url))
        let needsPackage = latex && LaTeXBookDesign.line(in: contents.text) != nil
        // This callback runs on the main thread, after AppKit has safely moved
        // the source into its final destination. Never write beside AppKit's
        // temporary safe-save URL, or fail the source save for a missing style.
        super.save(to: url, ofType: typeName, for: saveOperation) { error in
            if error == nil {
                if needsPackage {
                    self.installBookPackage(in: url.deletingLastPathComponent())
                } else {
                    self.bookPackageError = nil
                    self.bookPackageDirectory = nil
                }
            }
            completionHandler(error)
        }
    }

    func retryBookPackageInstallation() {
        guard let directory = bookPackageDirectory else { return }
        installBookPackage(in: directory)
    }

    private func installBookPackage(in directory: URL) {
        do {
            let target = directory.appendingPathComponent("terso-book.sty")
            if (try? FileManager.default.attributesOfItem(atPath: target.path)) != nil {
                // Reading an existing package verifies that LaTeX can access
                // it. Never replace an unreadable file or a writer's symlink
                // just because the installer's comparison could not read it.
                _ = try Data(contentsOf: target)
            } else {
                try LaTeXBookDesign.install(in: directory)
            }
            bookPackageError = nil
            bookPackageDirectory = nil
        } catch {
            bookPackageDirectory = directory
            bookPackageError = "Your manuscript is saved, but terso-book.sty could not be added to \"\(directory.path)\". "
                + "LaTeX needs this file to typeset the book. \(error.localizedDescription) Fix the folder or file access, then retry."
        }
    }

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
