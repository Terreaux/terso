// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import SwiftUI
import Testing
import TersoCore
@testable import TersoApp

@Suite(.serialized) @MainActor struct ExerciseIntegrationTests {
    private func environment() throws -> (TabWorkspace, ExerciseStore, ExerciseSuggestionState, URL) {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (TabWorkspace(), ExerciseStore(fileURL: directory.appendingPathComponent("Exercises.json")),
                ExerciseSuggestionState(fileURL: nil), directory)
    }

    @Test func chooserDoesNotSaveAndExplicitSavePreservesEmptyAttempt() throws {
        let (workspace, store, state, directory) = try environment()
        defer { workspace.close(); try? FileManager.default.removeItem(at: directory) }
        let sheet = ExerciseSheetController(workspace: workspace, source: nil, store: store, suggestions: state)
        sheet.begin(ExerciseCatalog.templates[0])
        #expect(store.sessions.isEmpty)
        sheet.changeStep(1)
        sheet.choose()
        #expect(store.sessions.isEmpty)
        sheet.begin(ExerciseCatalog.templates[0])
        let id = try #require(sheet.session?.id)
        #expect(sheet.flush(explicit: true))
        sheet.choose()
        #expect(store.session(id)?.currentStep == 0)
        #expect(store.session(id)?.allResponses == "")
        #expect(state.reportAllowed(enabled: true) == false)
    }

    @Test func latestResponseNavigationCompletionRetryAndStatisticsRemainSeparate() throws {
        let (workspace, store, state, directory) = try environment()
        defer { workspace.close(); try? FileManager.default.removeItem(at: directory) }
        let stats = WritingStats.shared.log
        let sheet = ExerciseSheetController(workspace: workspace, source: nil, store: store, suggestions: state)
        sheet.begin(ExerciseCatalog.templates[0])
        sheet.edit("草稿 👩🏽‍🔬")
        sheet.edit("Latest 草稿 👩🏽‍🔬")
        sheet.changeStep(2)
        let id = try #require(sheet.session?.id)
        sheet.showReview()
        sheet.markComplete()
        sheet.changeStep(0)
        sheet.edit("Revised after completion")
        #expect(store.session(id)?.completed == true)
        let reloaded = ExerciseStore(fileURL: directory.appendingPathComponent("Exercises.json"))
        #expect(reloaded.session(id)?.allResponses == "Revised after completion")
        sheet.tryAgain()
        #expect(sheet.session?.id != id)
        #expect(store.session(id)?.allResponses == "Revised after completion")
        #expect(store.sessions.count == 1)
        #expect(WritingStats.shared.log == stats)
    }

    @Test func failedSaveRetainsLatestResponseUntilRetry() throws {
        let (workspace, _, state, directory) = try environment()
        defer { workspace.close(); try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory)
        let store = ExerciseStore(fileURL: directory.appendingPathComponent("Exercises.json"))
        let sheet = ExerciseSheetController(workspace: workspace, source: nil, store: store, suggestions: state)
        sheet.begin(ExerciseCatalog.templates[0])
        sheet.edit("Never discard this")
        #expect(sheet.saveState == "Could not save")
        #expect(sheet.flush() == false)
        #expect(sheet.session?.allResponses == "Never discard this")
        try FileManager.default.removeItem(at: directory)
        #expect(sheet.flush())
        #expect(sheet.saveState == "Saved")
        #expect(sheet.message == nil)
    }

    @Test func explicitAppendIsOneUndoableEditAndDoesNotReplaceSelection() throws {
        _ = NSApplication.shared
        let document = TabDocument()
        let editor = ExerciseTestEditor("Original 👩🏽‍🔬 manuscript")
        document.model.editor = editor
        defer { document.close() }
        let original = editor.text
        editor.selection = TextSpan(location: 0, length: 8)
        #expect(ExerciseDraftReuse.append("Useful response", to: document))
        #expect(editor.text == original + "\n\nUseful response")
        #expect(editor.selection == TextSpan(location: 0, length: 8))
        #expect(editor.replacements == 1)
        editor.undoManager?.undo()
        #expect(editor.text == original)
        editor.undoManager?.redo()
        #expect(editor.text == original + "\n\nUseful response")
        document.model.renderMode = .preview
        #expect(!ExerciseDraftReuse.append("No insertion", to: document))
        #expect(!ExerciseDraftReuse.append("", to: document))
    }


    @Test func retryOfStandaloneSessionKeepsItsOptionalSource() throws {
        let (workspace, store, state, directory) = try environment()
        defer { workspace.close(); try? FileManager.default.removeItem(at: directory) }
        let source = ExerciseSource(documentID: UUID(), name: "Unrelated draft", excerpt: "Private context")
        let sheet = ExerciseSheetController(workspace: workspace, source: source, store: store, suggestions: state)
        let standalone = ExerciseSession(template: ExerciseCatalog.templates[0])
        #expect(store.save(standalone))
        sheet.resume(standalone)
        sheet.tryAgain()
        #expect(sheet.session?.source == nil)
        #expect(sheet.session?.id != standalone.id)
    }

    @Test func reportTransitionCapturesSourceAndWaitsForDismissal() async throws {
        let (workspace, store, state, directory) = try environment()
        defer { workspace.close(); try? FileManager.default.removeItem(at: directory) }
        // Use an actual registered workspace so report coordination resolves its owner.
        let tabs = DocumentTabs.shared
        let host = tabs.newWorkspace()
        let document = TabDocument()
        let editor = ExerciseTestEditor("Selected source context. Other text.")
        editor.selection = TextSpan(location: 0, length: 24)
        document.model.editor = editor
        host.insert(document)
        defer { document.close(); host.close(); tabs.remove(host) }
        let presentation = ExercisePresentation(store: store, suggestions: state)
        let report = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let context = ExerciseReportContextView()
        var resolvedModel: WorkspaceModel?
        context.resolved = { resolvedModel = $0 }
        report.contentView = context
        host.window?.beginSheet(report, completionHandler: nil)
        try await Task.sleep(for: .milliseconds(50))
        #expect(resolvedModel === document.model)
        // Mounting the real host installs its own editor; inject the explicit
        // source selection immediately before the report action we are testing.
        document.model.editor = editor
        document.model.writingStats = .overview
        presentation.fromReport(document.model)
        #expect(document.model.writingStats == nil)
        #expect(presentation.controller(in: host) == nil, "wait for the report's native dismissal callback")
        #expect(host.window?.attachedSheet === report)
        host.window?.endSheet(report)
        report.orderOut(nil)
        // Drain the explicitly deferred native presentation on the main run loop.
        try await Task.sleep(for: .milliseconds(80))
        let sheet = try #require(presentation.controller(in: host))
        #expect(sheet.source?.documentID == document.exerciseIdentity)
        #expect(sheet.source?.excerpt == "Selected source context.")
        #expect(host.window?.attachedSheet === sheet.window)
        #expect(store.sessions.isEmpty)
        sheet.closeSaving()
    }

    @Test func oneSavedSessionCannotBeEditedOrDeletedByAnotherWindow() throws {
        let (first, store, state, directory) = try environment()
        let second = TabWorkspace()
        defer { first.close(); second.close(); try? FileManager.default.removeItem(at: directory) }
        let saved = ExerciseSession(template: ExerciseCatalog.templates[0])
        #expect(store.save(saved))
        let presentation = ExercisePresentation(store: store, suggestions: state)
        presentation.open(in: first, sessionID: saved.id)
        presentation.open(in: second, sessionID: saved.id)
        let owner = try #require(presentation.controller(in: first))
        let other = try #require(presentation.controller(in: second))
        #expect(owner.session?.id == saved.id)
        #expect(other.session == nil)
        #expect(!presentation.delete(saved.id))
        #expect(store.session(saved.id) != nil)
        owner.closeSaving()
        #expect(presentation.delete(saved.id))
        other.closeSaving()
        #expect(store.sessions.isEmpty)
    }

    @Test func nativeIdentityRecoveryRemainsBackwardCompatible() throws {
        let old = Data("{\"data\":\"\",\"edited\":false}".utf8)
        #expect(try JSONDecoder().decode(DocumentTabs.SavedDocument.self, from: old).identity == nil)
        let id = UUID()
        let record = DocumentTabs.SavedDocument(data: Data(), edited: false, identity: id)
        #expect(try JSONDecoder().decode(DocumentTabs.SavedDocument.self, from: JSONEncoder().encode(record)).identity == id)
        #expect(NSImage(systemSymbolName: ExercisePresentation.symbol, accessibilityDescription: nil) != nil)
    }
}

@MainActor private final class ExerciseTestEditor: EditorController {
    var text: String
    var selection = TextSpan(location: 0, length: 0)
    var replacements = 0
    let undoManager: UndoManager? = UndoManager()
    init(_ text: String) { self.text = text; undoManager?.groupsByEvent = false }
    var currentSnapshot: DocumentSnapshot { DocumentSnapshot(revision: DocumentRevision(0), text: text) }
    func replace(_ range: TextSpan, with value: String, actionName: String) {
        let before = text
        text = (text as NSString).replacingCharacters(in: range.nsRange, with: value)
        replacements += 1
        undoManager?.registerUndo(withTarget: self) { $0.restore(before) }
    }
    private func restore(_ value: String) {
        let old = text
        undoManager?.registerUndo(withTarget: self) { $0.restore(old) }
        text = value
    }
    func reveal(_ range: TextSpan, select: Bool) { if select { selection = range } }
    func wrapSelection(prefix: String, suffix: String, placeholder: String) {}
    func prefixLines(_ marker: String) {}
    func refreshDecorations() {}
    func explainAtCaret() {}
}
