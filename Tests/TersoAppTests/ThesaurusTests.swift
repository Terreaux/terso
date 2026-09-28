// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import Testing
import TersoCore
@testable import TersoApp

@Suite @MainActor struct ThesaurusTests {
    @Test func selectedOccurrencePreviewReplacementAndUndo() throws {
        let model = WorkspaceModel()
        let editor = ThesaurusEditor(model, text: "🐦 Quick birds meet quick birds.")
        model.editor = editor
        let range = TextSpan((editor.text as NSString).range(of: "quick"))
        editor.selection = range
        model.showAlternatives()
        let request = try #require(model.thesaurusRequest)
        #expect(request.original == "quick")
        let preview = AlternativePreview(request: request)
        #expect(preview.proposed("rapid") == "🐦 Quick birds meet rapid birds.")
        #expect(editor.text == preview.original)
        editor.undoManager?.beginUndoGrouping()
        #expect(model.replaceAlternative("rapid", request: request) == nil)
        editor.undoManager?.endUndoGrouping()
        #expect(editor.text == "🐦 Quick birds meet rapid birds.")
        editor.undoManager?.undo()
        #expect(editor.text == "🐦 Quick birds meet quick birds.")
    }

    @Test func staleRequestsCannotChangeAnotherOccurrence() throws {
        let model = WorkspaceModel()
        let editor = ThesaurusEditor(model, text: "quick and quick")
        model.editor = editor
        editor.selection = TextSpan(location: 10, length: 5)
        model.showAlternatives()
        let request = try #require(model.thesaurusRequest)
        editor.text = "quick and slow"; model.textDidChange()
        #expect(model.replaceAlternative("rapid", request: request) != nil)
        #expect(editor.text == "quick and slow")
    }

    @Test func findingUsesChosenOccurrenceAndSessionsStaySeparate() throws {
        let model = WorkspaceModel(), other = WorkspaceModel()
        let editor = ThesaurusEditor(model, text: "quick and quick")
        model.editor = editor
        let ranges = [TextSpan(location: 0, length: 5), TextSpan(location: 10, length: 5)]
        let finding = TextAnnotation(source: .rule, category: .repetition, ranges: ranges,
            severity: .suggestion, message: "Repeated word", explanation: nil, revision: model.revision)
        model.showAlternatives(for: finding, occurrence: 1)
        #expect(model.thesaurusRequest?.range == ranges[1])
        #expect(other.thesaurusRequest == nil)
    }

    @Test func emptyOrLongSelectionsAreNotReplaceable() {
        let snapshot = DocumentSnapshot(revision: DocumentRevision(0), text: "one two three four five six seven")
        #expect(!ThesaurusRequest(snapshot: snapshot, range: TextSpan(location: 0, length: 0)).isValid)
        #expect(!ThesaurusRequest(snapshot: snapshot, range: TextSpan(location: 0, length: snapshot.text.utf16.count)).isValid)
    }
}

@MainActor private final class ThesaurusEditor: EditorController {
    let model: WorkspaceModel
    var text: String
    var selection = TextSpan(location: 0, length: 0)
    let undoManager: UndoManager? = UndoManager()
    var currentSnapshot: DocumentSnapshot { .init(revision: model.revision, text: text) }
    init(_ model: WorkspaceModel, text: String) { self.model = model; self.text = text }
    func replace(_ range: TextSpan, with replacement: String, actionName: String) {
        let old = (text as NSString).substring(with: range.nsRange)
        text = (text as NSString).replacingCharacters(in: range.nsRange, with: replacement)
        undoManager?.registerUndo(withTarget: self) { target in
            target.replace(TextSpan(location: range.location, length: replacement.utf16.count), with: old, actionName: actionName)
        }
        model.textDidChange()
    }
    func reveal(_ range: TextSpan, select: Bool) { if select { selection = range } }
    func wrapSelection(prefix: String, suffix: String, placeholder: String) {}
    func prefixLines(_ marker: String) {}
    func refreshDecorations() {}
    func explainAtCaret() {}
}
