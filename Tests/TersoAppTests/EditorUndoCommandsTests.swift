// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import Testing
@testable import TersoApp

@Suite(.serialized) @MainActor struct EditorUndoCommandsTests {
    private func event(_ key: String, modifiers: NSEvent.ModifierFlags = .command, window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                     timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                     characters: key, charactersIgnoringModifiers: key, isARepeat: false,
                                     keyCode: key.lowercased() == "y" ? 16 : 6))
    }

    private func editor(for document: TabDocument, in window: NSWindow) throws -> TersoTextView {
        let view = TersoTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 150))
        view.isRichText = false
        view.allowsUndo = true
        view.documentUndoManager = document.undoManager
        window.contentView?.addSubview(view)
        #expect(window.makeFirstResponder(view))
        let undo = try #require(document.undoManager)
        undo.groupsByEvent = false
        return view
    }

    private func type(_ text: String, in view: NSTextView) throws {
        let undo = try #require(view.undoManager)
        undo.beginUndoGrouping()
        view.insertText(text, replacementRange: NSRange(location: 0, length: 0))
        view.breakUndoCoalescing()
        undo.endUndoGrouping()
        #expect(view.string == text)
    }

    @Test func windowDispatchesUndoAndBothRedoShortcutsToTheSelectedTab() throws {
        _ = NSApplication.shared
        let workspace = TabWorkspace(), first = TabDocument(), second = TabDocument()
        defer { first.close(); second.close(); workspace.close() }
        let window = try #require(workspace.window)
        // Use the production window and native text editing, without SwiftUI
        // rendering or a synthetic menu that could hide command-routing bugs.
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        workspace.insert(first)
        let firstEditor = try editor(for: first, in: window)
        try type("First tab", in: firstEditor)
        #expect(window.performKeyEquivalent(with: try event("z", window: window)))
        #expect(firstEditor.string.isEmpty)
        #expect(window.performKeyEquivalent(with: try event("y", window: window)))
        #expect(firstEditor.string == "First tab")

        workspace.insert(second)
        let secondEditor = try editor(for: second, in: window)
        try type("Second tab", in: secondEditor)
        // Toolbar focus still resolves the selected document's history.
        #expect(window.makeFirstResponder(window))
        #expect(window.performKeyEquivalent(with: try event("z", window: window)))
        #expect(secondEditor.string.isEmpty)
        #expect(firstEditor.string == "First tab")
        #expect(window.performKeyEquivalent(with: try event("Z", modifiers: [.command, .shift], window: window)))
        #expect(secondEditor.string == "Second tab")

        workspace.select(first)
        #expect(window.makeFirstResponder(window))
        #expect(window.performKeyEquivalent(with: try event("z", window: window)))
        #expect(firstEditor.string.isEmpty)
        #expect(secondEditor.string == "Second tab")
    }

    @Test func focusedFieldKeepsItsOwnHistoryAndNewTabCannotUndoHiddenDocument() throws {
        _ = NSApplication.shared
        let workspace = TabWorkspace(), document = TabDocument()
        defer { document.close(); workspace.close() }
        let window = try #require(workspace.window)
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        workspace.insert(document)
        let documentEditor = try editor(for: document, in: window)
        try type("Manuscript", in: documentEditor)

        let field = IndependentHistoryTextView(frame: NSRect(x: 0, y: 160, width: 300, height: 100))
        field.isRichText = false
        field.allowsUndo = true
        field.history.groupsByEvent = false
        window.contentView?.addSubview(field)
        #expect(window.makeFirstResponder(field))
        try type("Inspector field", in: field)
        #expect(window.performKeyEquivalent(with: try event("z", window: window)))
        #expect(field.string.isEmpty)
        #expect(documentEditor.string == "Manuscript")
        #expect(window.performKeyEquivalent(with: try event("y", window: window)))
        #expect(field.string == "Inspector field")

        // The Settings scene uses ordinary AppKit windows. Its menu action
        // must likewise keep a focused field's manager instead of falling
        // back to the active manuscript.
        let settingsWindow = NSWindow(contentRect: .zero, styleMask: .titled, backing: .buffered, defer: false)
        settingsWindow.isReleasedWhenClosed = false
        defer { settingsWindow.close() }
        #expect(window.makeFirstResponder(window))
        settingsWindow.contentView?.addSubview(field)
        #expect(settingsWindow.makeFirstResponder(field))
        #expect(EditorHistoryAction.undo.perform(in: settingsWindow))
        #expect(field.string.isEmpty)
        #expect(documentEditor.string == "Manuscript")

        workspace.showStart()
        #expect(window.makeFirstResponder(documentEditor))
        #expect(EditorHistoryAction.manager(in: window) == nil)
        #expect(window.makeFirstResponder(window))
        // NSWindow can supply an empty fallback manager when its delegate
        // returns nil; it must never return the retained document's history.
        #expect(EditorHistoryAction.manager(in: window) !== document.undoManager)
        #expect(!EditorHistoryAction.undo.isEnabled(in: window))
        #expect(!EditorHistoryAction.undo.perform(in: window))
        #expect(documentEditor.string == "Manuscript")
    }

    @Test func unrelatedKeyModifiersDoNotBecomeHistoryCommands() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .zero, styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let modifierSets: [NSEvent.ModifierFlags] = [[], .control, [.command, .option], [.command, .control], [.command, .shift]]
        for modifiers in modifierSets {
            #expect(EditorHistoryAction(keyEvent: try event("y", modifiers: modifiers, window: window)) == nil)
        }
        #expect(EditorHistoryAction(keyEvent: try event("z", modifiers: [.command, .option], window: window)) == nil)
    }
}

private final class IndependentHistoryTextView: NSTextView {
    let history = UndoManager()
    override var undoManager: UndoManager? { history }
}
