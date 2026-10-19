// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import Observation
import SwiftUI
import TersoCore

/// One owner per native workspace window; saved sessions themselves are app-wide.
@MainActor @Observable
final class ExercisePresentation {
    static let shared = ExercisePresentation()
    static let symbol = "pencil.and.outline"
    var activeController: ExerciseSheetController?
    private var controllers: [ObjectIdentifier: ExerciseSheetController] = [:]
    private var reportRequests: [ObjectIdentifier: (TabWorkspace, UUID?, ExerciseSource?)] = [:]
    private var reportObservers: [ObjectIdentifier: NSObjectProtocol] = [:]
    private let store: ExerciseStore
    private let suggestions: ExerciseSuggestionState

    init(store: ExerciseStore = .shared, suggestions: ExerciseSuggestionState = .shared) {
        self.store = store; self.suggestions = suggestions
    }

    func controller(in workspace: TabWorkspace) -> ExerciseSheetController? { controllers[ObjectIdentifier(workspace)] }

    func open(in workspace: TabWorkspace? = DocumentTabs.shared.activeWorkspace, excerpt: String? = nil, sessionID: UUID? = nil, context: ExerciseSource? = nil) {
        guard let workspace else {
            DocumentTabs.shared.showStartWindow()
            open(in: DocumentTabs.shared.activeWorkspace, excerpt: excerpt, sessionID: sessionID, context: context)
            return
        }
        let key = ObjectIdentifier(workspace)
        if let controller = controllers[key] { controller.window?.makeKeyAndOrderFront(nil); return }
        guard let window = workspace.window, window.attachedSheet == nil else { return }
        let document = workspace.showingStart ? nil : workspace.selected
        let source = context ?? document.map { ExerciseSource(documentID: $0.exerciseIdentity, name: $0.displayName, fileURL: $0.fileURL, excerpt: excerpt) }
        let controller = ExerciseSheetController(workspace: workspace, source: source, store: store, suggestions: suggestions)
        controller.presentation = self
        controllers[key] = controller
        controller.onClose = { [weak self, weak workspace] in
            guard let workspace else { return }
            self?.controllers[ObjectIdentifier(workspace)] = nil
        }
        window.beginSheet(controller.window!)
        if let sessionID, let session = store.session(sessionID) { controller.resume(session) }
    }

    func fromReport(_ model: WorkspaceModel, sessionID: UUID? = nil) {
        guard let workspace = DocumentTabs.shared.workspaces.first(where: { $0.selected?.model === model }),
              model.writingStats != nil else { return }
        let document = workspace.selected
        let selection = model.editor?.selection
        let text = model.editor?.currentSnapshot.text as NSString?
        let excerpt: String?
        if let selection, let text, selection.length > 0, selection.upperBound <= text.length {
            excerpt = text.substring(with: selection.nsRange)
        } else { excerpt = nil }
        let context = document.map { ExerciseSource(documentID: $0.exerciseIdentity, name: $0.displayName, fileURL: $0.fileURL, excerpt: excerpt) }
        let key = ObjectIdentifier(model)
        reportRequests[key] = (workspace, sessionID, context)
        if let previous = reportObservers.removeValue(forKey: key) { NotificationCenter.default.removeObserver(previous) }
        reportObservers[key] = NotificationCenter.default.addObserver(
            forName: NSWindow.didEndSheetNotification, object: workspace.window, queue: .main) { [weak self, weak model] _ in
                MainActor.assumeIsolated {
                    if let model { self?.reportDidDismiss(model) }
                }
            }
        model.writingStats = nil
    }

    func reportDidDismiss(_ model: WorkspaceModel) {
        let key = ObjectIdentifier(model)
        if let observer = reportObservers.removeValue(forKey: key) { NotificationCenter.default.removeObserver(observer) }
        guard let workspace = reportRequests.removeValue(forKey: key) else { return }
        // The native completion has run; no second modal is stacked on the report.
        DispatchQueue.main.async { self.open(in: workspace.0, sessionID: workspace.1, context: workspace.2) }
    }

    func claim(_ id: UUID, for requester: ExerciseSheetController) -> Bool {
        if let existing = controllers.values.first(where: { $0 !== requester && $0.session?.id == id }) {
            existing.workspace?.window?.makeKeyAndOrderFront(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return false
        }
        return true
    }

    func delete(_ id: UUID) -> Bool {
        if let controller = controllers.values.first(where: { $0.session?.id == id }) {
            controller.workspace?.window?.makeKeyAndOrderFront(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            controller.message = "Close this exercise before deleting it from Saved."
            return false
        }
        return store.delete(id)
    }

    func flushAll() -> Bool {
        for controller in controllers.values where !controller.flush() {
            controller.workspace?.window?.makeKeyAndOrderFront(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            return false
        }
        return true
    }
}

@MainActor @Observable
final class ExerciseSheetController: NSWindowController, NSWindowDelegate {
    weak var workspace: TabWorkspace?
    weak var presentation: ExercisePresentation?
    let source: ExerciseSource?
    let store: ExerciseStore
    private let suggestions: ExerciseSuggestionState
    var session: ExerciseSession?
    var page = "New"
    var review = false
    var reuse = false
    var selectedSteps: Set<String> = []
    var selectedText = ""
    var destinationID: UUID?
    var message: String?
    var saveState = ""
    var onClose: (() -> Void)?
    private var durable = false
    private var dirty = false
    private weak var previousResponder: NSResponder?

    init(workspace: TabWorkspace, source: ExerciseSource?, store: ExerciseStore = .shared, suggestions: ExerciseSuggestionState = .shared) {
        self.store = store
        self.suggestions = suggestions
        self.workspace = workspace
        self.source = source
        previousResponder = workspace.window?.firstResponder
        let window = ExerciseSheetWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 580),
                                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Writing Exercises"
        window.minSize = NSSize(width: 460, height: 340)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.cancel = { [weak self] in self?.closeSaving() }
        let available = workspace.window?.contentLayoutRect.size ?? NSSize(width: 700, height: 580)
        window.setContentSize(NSSize(width: min(700, available.width), height: min(580, max(340, available.height - 50))))
        window.contentViewController = NSHostingController(rootView: ExerciseSheet(controller: self))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func begin(_ template: ExerciseTemplate) { begin(template, source: self.source) }

    func begin(_ template: ExerciseTemplate, source: ExerciseSource?) {
        guard flush() else { return }
        session = ExerciseSession(template: template, source: source)
        durable = false; dirty = false; review = false; reuse = false; saveState = ""
        selectedSteps = []; selectedText = ""; message = nil
        suggestions.startExercise()
    }

    func resume(_ saved: ExerciseSession) {
        guard flush(), (presentation ?? .shared).claim(saved.id, for: self) else { return }
        guard !saved.template.steps.isEmpty else { message = "This exercise has no prompts. Its saved writing is preserved in local storage."; return }
        session = saved
        session?.currentStep = min(max(0, saved.currentStep), saved.template.steps.count - 1)
        durable = true; dirty = false; review = false; reuse = false
        selectedSteps = Set(saved.template.steps.filter { !(saved.responses[$0.id] ?? "").isEmpty }.map(\.id))
        selectedText = ""; message = nil
        saveState = "Saved"
        suggestions.startExercise()
    }

    func edit(_ response: String) {
        guard var value = session else { return }
        let id = value.template.steps[value.currentStep].id
        guard value.responses[id] != response else { return }
        value.responses[id] = response
        value.updatedAt = .now
        session = value; dirty = true; durable = true
        suggestions.recordEdit()
        _ = flush()
    }

    func changeStep(_ index: Int) {
        guard flush(), var value = session else { return }
        value.currentStep = min(max(0, index), value.template.steps.count - 1)
        value.updatedAt = .now
        session = value; dirty = durable
        selectedText = ""; review = false
        _ = flush()
    }

    @discardableResult func flush(explicit: Bool = false) -> Bool {
        guard let value = session else { return true }
        if explicit { durable = true; dirty = true }
        guard durable, dirty else { return true }
        saveState = "Saving"
        if store.save(value) {
            saveState = "Saved"; dirty = false; message = nil; return true
        }
        saveState = "Could not save"; message = store.error
        return false
    }

    func markComplete() {
        guard var value = session else { return }
        value.completed = true; value.updatedAt = .now; session = value
        _ = flush(explicit: true)
    }

    func tryAgain() {
        guard let value = session, flush(explicit: true) else { return }
        begin(value.template, source: value.source)
    }

    func rename(_ title: String) {
        guard var value = session else { return }
        value.title = title; value.updatedAt = .now; session = value
        dirty = durable; _ = flush()
    }

    func choose() {
        guard flush() else { return }
        session = nil; durable = false; dirty = false; review = false; reuse = false
    }

    func showReview() {
        guard flush(), let session else { return }
        selectedSteps = Set(session.template.steps.filter { !(session.responses[$0.id] ?? "").isEmpty }.map(\.id))
        selectedText = ""; review = true
    }

    var chosenWriting: String {
        guard let session else { return "" }
        return session.template.steps.filter { selectedSteps.contains($0.id) }
            .compactMap { session.responses[$0.id] }.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    func copy(_ text: String) {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func prepareReuse() {
        destinationID = ExerciseDraftReuse.resolve(session?.source)?.id
        reuse = true; message = nil
    }

    func insert() {
        guard flush(), let id = destinationID,
              let document = ExerciseDraftReuse.openDocuments.first(where: { $0.id == id }),
              ExerciseDraftReuse.append(chosenWriting, to: document) else {
            message = "Choose an open, editable draft and at least one response. Nothing was inserted."
            return
        }
        closeSaving()
        document.workspace?.select(document)
        document.workspace?.window?.makeKeyAndOrderFront(nil)
        if let editor = document.model.editor as? EditorCoordinator {
            editor.textView?.window?.makeFirstResponder(editor.textView)
        }
    }

    func closeSaving() {
        // Commit any marked text before the synchronous final save.
        (window?.firstResponder as? NSTextView)?.unmarkText()
        guard flush() else { return }
        if let window, let parent = window.sheetParent { parent.endSheet(window) }
        window?.orderOut(nil)
        window?.contentViewController = nil
        if let previousResponder { workspace?.window?.makeFirstResponder(previousResponder) }
        if ExercisePresentation.shared.activeController === self { ExercisePresentation.shared.activeController = nil }
        onClose?()
    }
    func windowDidBecomeKey(_ notification: Notification) { ExercisePresentation.shared.activeController = self }
    func windowDidResignKey(_ notification: Notification) {
        if ExercisePresentation.shared.activeController === self { ExercisePresentation.shared.activeController = nil }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { closeSaving(); return false }
}

private final class ExerciseSheetWindow: NSWindow {
    var cancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { cancel?() }
}

/// Explicit append only: never reuses or overwrites a stale manuscript selection.
@MainActor enum ExerciseDraftReuse {
    static var openDocuments: [TabDocument] { DocumentTabs.shared.workspaces.flatMap(\.documents) }
    static func destinationLabel(_ document: TabDocument) -> String {
        let title: String = document.displayName
        guard openDocuments.filter({ $0.displayName == title }).count > 1 else { return title }
        return document.fileURL?.path ?? "\(title) (window \(document.workspace?.window?.windowNumber ?? 0))"
    }
    static func resolve(_ source: ExerciseSource?) -> TabDocument? {
        guard let source else { return nil }
        return openDocuments.first { $0.exerciseIdentity == source.documentID }
            ?? openDocuments.first { source.fileURL != nil && $0.fileURL?.standardizedFileURL == source.fileURL?.standardizedFileURL }
    }
    static func append(_ text: String, to document: TabDocument) -> Bool {
        guard !text.isEmpty, document.model.renderMode != .preview, let editor = document.model.editor else { return false }
        let before = editor.currentSnapshot.text
        let suffix = (before.isEmpty || before.hasSuffix("\n\n") ? "" : before.hasSuffix("\n") ? "\n" : "\n\n") + text
        let location = (before as NSString).length
        let undo = editor.undoManager
        (editor as? EditorCoordinator)?.textView?.breakUndoCoalescing()
        undo?.beginUndoGrouping()
        editor.replace(TextSpan(location: location, length: 0), with: suffix, actionName: "Use Exercise in Draft")
        undo?.endUndoGrouping()
        guard editor.currentSnapshot.text == before + suffix else { return false }
        editor.reveal(TextSpan(location: location, length: (suffix as NSString).length), select: false)
        return true
    }
}
