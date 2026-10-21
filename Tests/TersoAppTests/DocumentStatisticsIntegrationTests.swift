// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import SwiftUI
import Testing
import TersoCore
@testable import TersoApp

@Suite @MainActor struct DocumentStatisticsIntegrationTests {
    @Test func reportRoutesToStatisticsWithoutChangingWritingStatsOrInspector() {
        let model = WorkspaceModel(wordTargets: WritingStats(fileURL: nil))
        model.writingStats = .stories
        model.inspectorTab = .science
        model.openDocumentStatistics()
        #expect(model.showDocumentReport && model.showDocumentStatistics)
        #expect(!model.showInspector && model.inspectorTab == .science)
        #expect(model.writingStats == .stories)
        model.returnToDocumentReport()
        #expect(model.showDocumentReport && !model.showDocumentStatistics)
        model.documentReportDidDismiss()
        #expect(!model.showDocumentStatistics)
    }

    @Test func navigationWaitsForDismissalPreservesCaretAndRejectsStaleRanges() {
        let model = WorkspaceModel()
        let editor = StatisticsTestEditor(model, text: "🪶 First paragraph.\n\nSecond paragraph.")
        model.editor = editor
        let source = editor.currentSnapshot.text as NSString
        let range = TextSpan(source.range(of: "Second paragraph."))
        let caret = editor.selection
        model.openDocumentStatistics()
        model.navigateFromStatistics(range, revision: model.revision)
        #expect(!model.showDocumentReport)
        #expect(editor.revealed == nil)
        model.documentReportDidDismiss()
        #expect(editor.revealed == range && editor.selection == caret)
        // Selection and focus stay under the editor's existing reveal API.
        #expect(editor.selectedOnReveal == false)
        editor.revealed = nil
        model.openDocumentStatistics()
        model.navigateFromStatistics(range, revision: model.revision)
        editor.text = "Changed."
        model.textDidChange()
        model.documentReportDidDismiss()
        #expect(editor.revealed == nil)
        model.openDocumentStatistics()
        model.navigateFromStatistics(range, revision: DocumentRevision(0))
        #expect(model.showDocumentReport)
        model.navigateFromStatistics(TextSpan(location: -1, length: 2), revision: model.revision)
        #expect(model.showDocumentReport)
    }

    @Test func snapshotsStayWithDocumentAndRapidEditsInvalidateImmediately() async throws {
        let a = WorkspaceModel(), b = WorkspaceModel()
        let editorA = StatisticsTestEditor(a, text: String(repeating: "The birds return to the garden. ", count: 40))
        let editorB = StatisticsTestEditor(b, text: "Quiet water reflects the sky.")
        a.editor = editorA; b.editor = editorB
        a.openDocumentStatistics(); b.openDocumentStatistics()
        try await eventually { a.documentStatistics != nil && b.documentStatistics != nil }
        #expect(a.documentStatistics?.statistics == a.local?.statistics)
        #expect(b.documentStatistics?.statistics == b.local?.statistics)
        #expect(a.documentStatistics?.documentID != b.documentStatistics?.documentID)
        #expect(a.documentStatistics?.statistics.words == 240)
        #expect(b.documentStatistics?.statistics.words == 5)
        for count in 1...8 {
            editorA.text = String(repeating: "River ", count: count)
            a.textDidChange()
            #expect(a.documentStatistics == nil)
        }
        try await eventually { a.documentStatistics?.revision == a.revision }
        #expect(a.documentStatistics?.statistics.words == 8)
        #expect(b.documentStatistics?.statistics.words == 5)
        let cachedID = a.statisticsDocumentID
        let cachedRevision = a.documentStatistics?.revision
        a.documentWordTarget = 10
        a.returnToDocumentReport(); a.openDocumentStatistics()
        #expect(a.documentStatistics?.revision == cachedRevision)
        #expect(a.documentStatistics?.documentID == cachedID)
        #expect(DocumentGoalProgress(words: 8, target: a.documentWordTarget)?.remaining == 2)
        withExtendedLifetime((editorA, editorB)) {}
    }

    @Test func nativeEditorNavigationSupportsSourceMixedAndPreviewWithoutChangingSource() {
        let text = "🪶 An opening sentence.\n\nThe destination paragraph is here."
        let range = TextSpan((text as NSString).range(of: "The destination paragraph is here."))
        for mode in [RenderMode.source, .mixed, .preview] {
            let model = WorkspaceModel()
            let coordinator = EditorCoordinator(model: model, text: .constant(text))
            let textView = TersoTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
            textView.string = text
            textView.setSelectedRange(NSRange(location: 3, length: 0))
            coordinator.textView = textView
            model.editor = coordinator
            model.renderMode = mode
            model.navigateFromStatistics(range, revision: model.revision)
            model.documentReportDidDismiss()
            #expect(model.renderMode == (mode == .preview ? .mixed : mode))
            #expect(textView.string == text)
            #expect(textView.selectedRange() == NSRange(location: 3, length: 0))
            #expect(model.revision == DocumentRevision(0))
        }
    }

    private func eventually(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !condition() {
            if ContinuousClock.now >= deadline { Issue.record("Timed out waiting for statistics"); return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

@MainActor private final class StatisticsTestEditor: EditorController {
    let model: WorkspaceModel
    var text: String
    var selection = TextSpan(location: 0, length: 0)
    var revealed: TextSpan?
    var selectedOnReveal: Bool?
    let undoManager: UndoManager? = UndoManager()
    var currentSnapshot: DocumentSnapshot { .init(revision: model.revision, text: text, fileName: model.fileURL?.lastPathComponent) }
    init(_ model: WorkspaceModel, text: String) { self.model = model; self.text = text }
    func reveal(_ range: TextSpan, select: Bool) { revealed = range; selectedOnReveal = select; if select { selection = range } }
    func replace(_ range: TextSpan, with text: String, actionName: String) {}
    func wrapSelection(prefix: String, suffix: String, placeholder: String) {}
    func prefixLines(_ marker: String) {}
    func refreshDecorations() {}
    func explainAtCaret() {}
}
