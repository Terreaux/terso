// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import Combine
import SwiftUI

/// Document windows are hosted by AppKit rather than a SwiftUI document scene,
/// so the Settings scene's default undo commands have no document undo manager.
/// Keep the menu and window key equivalents on the same focused history.
@MainActor enum EditorHistoryAction {
    case undo, redo

    init?(keyEvent event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
        switch (event.charactersIgnoringModifiers?.lowercased(), modifiers) {
        case ("z", .command): self = .undo
        case ("y", .command), ("z", [.command, .shift]): self = .redo
        default: return nil
        }
    }

    static func manager(in window: NSWindow?) -> UndoManager? {
        guard let window else { return nil }
        let manager = window.firstResponder?.undoManager ?? window.undoManager
        // New Tab retains the last document, but its hidden editor must not
        // receive history commands from the start screen.
        if let workspace = window.windowController as? TabWorkspace,
           workspace.showingStart, manager === workspace.selected?.undoManager { return nil }
        return manager
    }

    func isEnabled(in window: NSWindow?) -> Bool {
        guard let manager = Self.manager(in: window) else { return false }
        return self == .undo ? manager.canUndo : manager.canRedo
    }

    @discardableResult func perform(in window: NSWindow?) -> Bool {
        guard isEnabled(in: window), let manager = Self.manager(in: window) else { return false }
        (window?.firstResponder as? NSTextView)?.breakUndoCoalescing()
        if self == .undo { manager.undo() } else { manager.redo() }
        return true
    }
}

final class TabWorkspaceWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let action = EditorHistoryAction(keyEvent: event), action.perform(in: self) { return true }
        return super.performKeyEquivalent(with: event)
    }
}

struct EditorUndoCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .undoRedo) { EditorUndoMenuItems() }
    }
}

private struct EditorUndoMenuItems: View {
    @State private var historyRevision = 0

    private var historyChanges: AnyPublisher<Notification, Never> {
        Publishers.MergeMany([
            .NSUndoManagerDidCloseUndoGroup, .NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange,
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
            NSText.didBeginEditingNotification, NSText.didEndEditingNotification
        ].map { NotificationCenter.default.publisher(for: $0) }).eraseToAnyPublisher()
    }

    var body: some View {
        // UndoManager's availability is not observable; group notifications
        // refresh it, while Observation tracks changes of the selected tab.
        let _ = historyRevision
        let _ = DocumentTabs.shared.activeDocument?.id
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        Group {
            Button("Undo") { EditorHistoryAction.undo.perform(in: NSApp.keyWindow ?? NSApp.mainWindow) }
                .keyboardShortcut("z")
                .disabled(!EditorHistoryAction.undo.isEnabled(in: window))
            Button("Redo") { EditorHistoryAction.redo.perform(in: NSApp.keyWindow ?? NSApp.mainWindow) }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!EditorHistoryAction.redo.isEnabled(in: window))
                .help("Redo the last undone change. You can also use ⌘Y in the document editor.")
        }
        .onReceive(historyChanges) { _ in historyRevision &+= 1 }
    }
}
