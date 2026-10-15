// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// One way of writing at a time. Hemingway is the everyday view, with the
/// writing highlights on the page; the others trade the highlights for focus.
enum WritingMode: String, CaseIterable, Identifiable {
    case hemingway, typewriter, letterbox, zen
    var id: String { rawValue }

    var title: String { rawValue.capitalized }

    var symbol: String {
        switch self {
        case .hemingway: "pencil.line"
        case .typewriter: "character.cursor.ibeam"
        case .letterbox: "rectangle.center.inset.filled"
        case .zen: "leaf"
        }
    }

    var help: String {
        switch self {
        case .hemingway: "Hemingway: the page with its writing highlights"
        case .typewriter: "Typewriter: keep the current line centred (⌘⇧Y)"
        case .letterbox: "Letterbox: dim everything but the current paragraph (⌘⇧F)"
        case .zen: "Zen: full screen, just the text (⌘⇧J, Esc to leave)"
        }
    }

    /// Hemingway needs none: choosing the current mode again returns to it.
    var shortcut: Character? {
        switch self {
        case .hemingway: nil
        case .typewriter: "y"
        case .letterbox: "f"
        case .zen: "j"
        }
    }

    /// Typewriter and Letterbox follow the caret, which Preview does not have.
    var followsCaret: Bool { self == .typewriter || self == .letterbox }
}

extension WorkspaceModel {
    /// Read from the flags the editor already uses: Letterbox is Focus, and
    /// Zen is Focus in full screen.
    var writingMode: WritingMode {
        zenMode ? .zen : focusMode ? .letterbox : typewriter ? .typewriter : .hemingway
    }

    func setWritingMode(_ mode: WritingMode) {
        guard mode != writingMode else { return }
        // Leaving Zen leaves Focus too, and full screen if Zen entered it.
        if zenMode { toggleZenMode() }
        if focusMode { toggleFocusMode() }
        typewriter = false
        switch mode {
        case .hemingway: break
        case .typewriter: typewriter = true
        case .letterbox: toggleFocusMode()
        case .zen: toggleZenMode()
        }
        editor?.refreshDecorations()
    }

    /// Menu shortcuts: choosing the current mode again returns to Hemingway.
    func toggleWritingMode(_ mode: WritingMode) {
        setWritingMode(writingMode == mode ? .hemingway : mode)
    }
}
