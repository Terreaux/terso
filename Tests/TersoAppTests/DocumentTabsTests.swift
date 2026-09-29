// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import Testing
import TersoDocument
@testable import TersoApp

@Suite(.serialized) @MainActor struct DocumentTabsTests {
    @Test func tabsUseOneWindowAndKeepEditorIdentityWhenMoved() throws {
        _ = NSApplication.shared
        let workspace = TabWorkspace()
        let first = TabDocument(), second = TabDocument()
        defer { first.close(); second.close(); workspace.close() }
        workspace.insert(first)
        let window = try #require(workspace.window)
        let frame = window.frame
        let editor = first.hostedEditor()
        workspace.insert(second)
        second.model.showInspector = true
        second.model.inspectorTab = .science
        for _ in 0..<8 {
            workspace.select(first)
            workspace.select(second)
        }
        #expect(workspace.window === window)
        #expect(window.frame == frame)
        #expect(window.tabbingMode == .disallowed)
        #expect(first.windowControllers.isEmpty && second.windowControllers.isEmpty)
        #expect(first.hostedEditor() === editor)
        #expect(!first.model.showInspector && second.model.showInspector)

        let detached = TabWorkspace()
        defer { detached.close() }
        workspace.remove(first)
        detached.insert(first)
        #expect(first.hostedEditor() === editor)
        #expect(first.workspace === detached)
        #expect(second.workspace === workspace)
        #expect(detached.window !== window)
    }

    @Test func documentsPreserveBytesAndUseIndependentUndoManagers() throws {
        let first = TabDocument(), second = TabDocument()
        let bytes = Data([0xef, 0xbb, 0xbf]) + Data("# One\r\n\r\nText  \r\n".utf8)
        try first.read(from: bytes, ofType: "net.daringfireball.markdown")
        #expect(try first.data(ofType: "net.daringfireball.markdown") == bytes)
        #expect(second.contents.text.isEmpty)
        #expect(first.undoManager !== second.undoManager)
        #expect(first.model.documentUndoManager === first.undoManager)
        let firstView = TersoTextView(), secondView = TersoTextView()
        firstView.documentUndoManager = first.undoManager
        secondView.documentUndoManager = second.undoManager
        #expect(firstView.undoManager !== secondView.undoManager)
    }

    @Test func removingSelectedTabChoosesNeighborWithoutClosingOtherDocuments() {
        _ = NSApplication.shared
        let workspace = TabWorkspace()
        let documents = (0..<3).map { _ in TabDocument() }
        defer { documents.forEach { $0.close() }; workspace.close() }
        documents.forEach { workspace.insert($0) }
        workspace.select(documents[1])
        workspace.remove(documents[1])
        #expect(workspace.documents.count == 2)
        #expect(workspace.selected === documents[2])
        #expect(documents[1].workspace == nil)
        workspace.select(offset: 1)
        #expect(workspace.selected === documents[0])
        workspace.select(offset: -1)
        #expect(workspace.selected === documents[2])
    }

    @Test func closingLastTabKeepsWindowButMovingItAwayClosesIt() throws {
        _ = NSApplication.shared
        let workspace = TabWorkspace(), document = TabDocument()
        defer { document.close(); workspace.close() }
        workspace.insert(document)
        workspace.showWindow(nil)
        let window = try #require(workspace.window)
        workspace.remove(document)
        #expect(workspace.documents.isEmpty && workspace.selected == nil)
        #expect(window.isVisible)
        #expect(window.title == "Terso")

        workspace.insert(document)
        workspace.remove(document, closingWhenEmpty: true)
        #expect(!window.isVisible)
    }

    @Test func editingUndoAndSavingStayWithTheOriginatingTab() async throws {
        _ = NSApplication.shared
        let document = TabDocument(), other = TabDocument()
        let workspace = TabWorkspace()
        workspace.insert(document)
        let host = document.hostedEditor()
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        host.layoutSubtreeIfNeeded()
        defer { document.close(); other.close(); workspace.close() }
        let deadline = ContinuousClock.now + .seconds(3)
        while document.model.editor == nil && ContinuousClock.now < deadline { await Task.yield() }
        let editor = try #require(document.model.editor)
        let undo = try #require(document.undoManager)
        undo.beginUndoGrouping()
        editor.replace(.init(location: 0, length: 0), with: "First tab.", actionName: "Test edit")
        undo.endUndoGrouping()
        // AppKit closes its outer event undo group on the next run-loop turn.
        try await Task.sleep(for: .milliseconds(50))
        #expect(document.contents.text == "First tab.")
        #expect(document.isDocumentEdited)
        workspace.insert(other)
        undo.undo()
        #expect(document.contents.text.isEmpty)
        #expect(!document.isDocumentEdited)
        #expect(other.contents.text.isEmpty)
        undo.redo()
        try await Task.sleep(for: .milliseconds(50))
        #expect(document.contents.text == "First tab.")

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        defer { try? FileManager.default.removeItem(at: url) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            document.save(to: url, ofType: "net.daringfireball.markdown", for: .saveOperation) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(try String(contentsOf: url, encoding: .utf8) == "First tab.")
        #expect(!document.isDocumentEdited)
        #expect(document.fileURL == url)
        #expect(other.fileURL == nil)
    }

    @Test func recoveryRestoresUnsavedBytesAndTabSelection() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("tabs.json")
        let original = DocumentTabs(recoveryURL: url)
        original.isRunning = true
        let workspace = original.newWorkspace()
        let first = TabDocument(), second = TabDocument()
        let bytes = Data([0xef, 0xbb, 0xbf]) + Data("Unsaved\r\ntext.\r\n".utf8)
        try first.read(from: bytes, ofType: "net.daringfireball.markdown")
        first.updateChangeCount(.changeDone)
        workspace.insert(first)
        workspace.insert(second)
        workspace.select(first)
        original.saveRecovery()
        first.close(); second.close(); workspace.close()

        let restored = DocumentTabs(recoveryURL: url)
        restored.restore()
        defer {
            for group in restored.workspaces {
                for document in group.documents {
                    TabDocumentController.sharedController.removeDocument(document)
                    document.close()
                }
                group.close()
            }
        }
        let group = try #require(restored.workspaces.first)
        #expect(group.documents.count == 2)
        let recovered = try #require(group.documents.first)
        #expect(try recovered.data(ofType: "net.daringfireball.markdown") == bytes)
        #expect(recovered.isDocumentEdited)
        #expect(group.selected === recovered)
        #expect(recovered.fileURL == nil)
    }
}
