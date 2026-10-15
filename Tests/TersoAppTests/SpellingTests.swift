// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import Testing
import TersoCore
@testable import TersoApp

@Suite @MainActor struct SpellingTests {
    @Test func acronymsIdentifiersAndNumbersAreNotFlagged() {
        for word in ["NASA", "RNA", "camelCase", "snake_case", "H2O", "3rd", "iPhone", "a"] {
            #expect(SpellingLayer.isLikelyIntentional(word), "\(word)")
        }
        for word in ["teh", "Recieve", "definately"] {
            #expect(!SpellingLayer.isLikelyIntentional(word), "\(word)")
        }
    }

    @Test func suggestionsPutBestFirstMatchCaseAndDropDuplicates() {
        let out = SpellingLayer.rankedSuggestions(for: "Recieve", best: "receive",
                                                  guesses: ["receive", "Relieve", "recieve", "reprieve"])
        #expect(out == ["Receive", "Relieve", "Reprieve"])
        #expect(SpellingLayer.rankedSuggestions(for: "teh", best: nil, guesses: ["the", "ten", "tea"], limit: 2) == ["the", "ten"])
    }

    @Test func correctionReplacesTheChosenOccurrenceAndUndoes() throws {
        let model = WorkspaceModel()
        let editor = SpellingEditor(model, text: "🐦 teh cat and teh dog")
        model.editor = editor
        let ns = editor.text as NSString
        let first = ns.range(of: "teh"), second = ns.range(of: "teh", range: NSRange(location: first.upperBound, length: ns.length - first.upperBound))
        let finding = TextAnnotation(source: .spelling, category: .spelling, ranges: [TextSpan(first), TextSpan(second)],
                                     severity: .suggestion, message: "Spelling", explanation: nil, revision: model.revision,
                                     metadata: ["word": "teh", "suggestions": "the\nten"])
        #expect(finding.corrections == ["the", "ten"])
        editor.undoManager?.beginUndoGrouping()
        #expect(model.applyCorrection("the", to: finding, occurrence: 1) == nil)
        editor.undoManager?.endUndoGrouping()
        #expect(editor.text == "🐦 teh cat and the dog")
        editor.undoManager?.undo()
        #expect(editor.text == "🐦 teh cat and teh dog")
    }

    @Test func writingFindingsOfferOneClickFixes() {
        let model = WorkspaceModel()
        let editor = SpellingEditor(model, text: "It was very good.")
        model.editor = editor
        let finding = TextAnnotation(source: .rule, category: .filler, ranges: [TextSpan(location: 7, length: 4)],
                                     severity: .info, message: "Qualifier", explanation: nil, revision: model.revision,
                                     metadata: [QuickFixes.removableKey: "true", "text": "very"])
        let fixes = model.quickFixes(for: finding)
        #expect(fixes.map(\.title) == ["Remove"])
        #expect(model.applyQuickFix(fixes[0], to: finding) == nil)
        #expect(editor.text == "It was good.")
    }

    @Test func staleCorrectionsAreRefused() {
        let model = WorkspaceModel()
        let editor = SpellingEditor(model, text: "teh cat")
        model.editor = editor
        let finding = TextAnnotation(source: .spelling, category: .spelling, ranges: [TextSpan(location: 0, length: 3)],
                                     severity: .suggestion, message: "Spelling", explanation: nil, revision: model.revision,
                                     metadata: ["word": "teh", "suggestions": "the"])
        editor.text = "a teh cat"; model.textDidChange()
        #expect(model.applyCorrection("the", to: finding) != nil)
        #expect(editor.text == "a teh cat")
    }
}

@MainActor private final class SpellingEditor: EditorController {
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
