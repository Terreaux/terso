// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// One way of writing at a time. Hemingway is the everyday view, with the
/// writing highlights on the page; Typewriter, Letterbox and Zen trade the
/// highlights for focus; Manutius sets the text as the pages of a book.
enum WritingMode: String, CaseIterable, Identifiable {
    case hemingway, typewriter, letterbox, zen, manutius
    var id: String { rawValue }

    var title: String { rawValue.capitalized }

    var symbol: String {
        switch self {
        case .hemingway: "pencil.line"
        case .typewriter: "character.cursor.ibeam"
        case .letterbox: "rectangle.center.inset.filled"
        case .zen: "leaf"
        case .manutius: "book.pages"
        }
    }

    var help: String {
        switch self {
        case .hemingway: "Hemingway: the page with its writing highlights"
        case .typewriter: "Typewriter: keep the current line centred (⌘⇧Y)"
        case .letterbox: "Letterbox: dim everything but the current paragraph (⌘⇧F)"
        case .zen: "Zen: full screen, just the text (⌘⇧J, Esc to leave)"
        case .manutius: "Manutius: the text set as book pages — justified, hyphenated, numbered — and still editable (⌘⇧M)"
        }
    }

    /// Hemingway needs none: choosing the current mode again returns to it.
    var shortcut: Character? {
        switch self {
        case .hemingway: nil
        case .typewriter: "y"
        case .letterbox: "f"
        case .zen: "j"
        case .manutius: "m"
        }
    }

    /// Typewriter, Letterbox and Manutius shape the editor, which Preview hides.
    var shapesEditor: Bool { self == .typewriter || self == .letterbox || self == .manutius }
}

extension WorkspaceModel {
    /// Read from the flags the editor already uses: Letterbox is Focus, and
    /// Zen is Focus in full screen.
    var writingMode: WritingMode {
        manutius ? .manutius : zenMode ? .zen : focusMode ? .letterbox : typewriter ? .typewriter : .hemingway
    }

    func setWritingMode(_ mode: WritingMode) {
        guard mode != writingMode else { return }
        // Leaving Zen leaves Focus too, and full screen if Zen entered it.
        if zenMode { toggleZenMode() }
        if focusMode { toggleFocusMode() }
        typewriter = false
        manutius = false
        switch mode {
        case .hemingway: break
        case .typewriter: typewriter = true
        case .letterbox: toggleFocusMode()
        case .zen: toggleZenMode()
        case .manutius: manutius = true
        }
        // The Book tab belongs to Manutius: it comes forward with it and
        // gives way to Review when the pages go.
        if manutius { inspectorTab = .book } else if inspectorTab == .book { inspectorTab = .review }
        editor?.refreshDecorations()
    }

    /// Menu shortcuts: choosing the current mode again returns to Hemingway.
    func toggleWritingMode(_ mode: WritingMode) {
        setWritingMode(writingMode == mode ? .hemingway : mode)
    }
}
