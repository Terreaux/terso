// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import SwiftUI
import TersoAI

@main
struct TersoApp: App {
    @NSApplicationDelegateAdaptor(TersoAppDelegate.self) private var delegate

    init() {
        _ = TabDocumentController.sharedController
        NSWindow.allowsAutomaticWindowTabbing = false
        NSApplication.shared.appearance = Preferences.shared.theme.nsAppearance
    }

    var body: some Scene {
        Settings { SettingsView() }
            .commands {
                EditorUndoCommands()
                TextEditingCommands()
                DocumentTabCommands()
                TersoCommands()
            }
    }
}

struct TersoCommands: Commands {
    private var model: WorkspaceModel? { DocumentTabs.shared.activeDocument?.model }

    var body: some Commands {
        CommandMenu("Format") {
            Group {
                Button("Bold") { model?.editor?.performFormatting(.bold) }.keyboardShortcut("b")
                Button("Italic") { model?.editor?.performFormatting(.italic) }.keyboardShortcut("i")
                Button("Underline") { model?.editor?.performFormatting(.underline) }.keyboardShortcut("u")
                Button("Inline Code") { model?.editor?.performFormatting(.code) }.keyboardShortcut("e")
                Button("Link") { model?.editor?.performFormatting(.link) }.keyboardShortcut("k")
                Button("Image") { model?.editor?.performFormatting(.image) }
                Divider()
                Button("Body") { model?.editor?.performFormatting(.blockStyle(.body)) }
                Button("Heading 1") { model?.editor?.performFormatting(.blockStyle(.heading1)) }.keyboardShortcut("1", modifiers: [.command, .option])
                Button("Heading 2") { model?.editor?.performFormatting(.blockStyle(.heading2)) }.keyboardShortcut("2", modifiers: [.command, .option])
                Button("Heading 3") { model?.editor?.performFormatting(.blockStyle(.heading3)) }.keyboardShortcut("3", modifiers: [.command, .option])
                Divider()
                Button("Blockquote") { model?.editor?.performFormatting(.blockquote) }.keyboardShortcut("'", modifiers: [.command, .option])
                Button("Bulleted List") { model?.editor?.performFormatting(.bulletedList) }.keyboardShortcut("l", modifiers: [.command, .option])
                Button("Numbered List") { model?.editor?.performFormatting(.numberedList) }.keyboardShortcut("n", modifiers: [.command, .option])
                Button("Code Block") { model?.editor?.performFormatting(.codeBlock) }
                Button("Horizontal Rule") { model?.editor?.performFormatting(.horizontalRule) }
            }
            .disabled(model == nil || model?.renderMode == .preview)
        }
        CommandGroup(after: .sidebar) {
            ForEach(RenderMode.allCases) { mode in
                Button(mode.rawValue + " Mode") { model?.renderMode = mode }
                    .keyboardShortcut(mode == .source ? "1" : mode == .mixed ? "2" : "3", modifiers: [.command, .control])
                    .disabled(model == nil)
            }
            Divider()
            ForEach(WritingMode.allCases) { mode in
                Toggle(mode.title, isOn: Binding(get: { model?.writingMode == mode },
                                                 set: { _ in model?.toggleWritingMode(mode) }))
                    .keyboardShortcut(mode.shortcut.map { KeyboardShortcut(KeyEquivalent($0), modifiers: [.command, .shift]) })
                    .disabled(model == nil || (mode.shapesEditor && model?.renderMode == .preview))
            }
            Button("Whole Book") { model?.showBookOverview = true }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .disabled(model?.writingMode != .manutius)
            Divider()
        }
        CommandMenu("Writing") {
            Button("Alternatives for Selection…") { model?.showAlternatives() }
                .keyboardShortcut("t", modifiers: [.command, .option])
                .disabled(model == nil)
            Divider()
            Button(model?.focusedReview == true ? "End Review" : "Review Writing") {
                if model?.focusedReview == true { model?.endFocusedReview() } else { model?.startFocusedReview() }
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            Button("Next Passage") { model?.selectFinding(offset: 1) }.keyboardShortcut("]")
            Button("Previous Passage") { model?.selectFinding(offset: -1) }.keyboardShortcut("[")
            Button("Show Finding at Cursor") { model?.editor?.explainAtCaret() }.keyboardShortcut("'")
            Button("Ignore Finding") { if let a = model?.selectedFinding { model?.ignore(a) } }
                .disabled(model?.selectedFinding == nil)
            Divider()
            Button("Explain Finding") { if let a = model?.selectedFinding { model?.explain(a) } }
                .disabled(model?.selectedFinding == nil || model?.prefs.aiEnabled != true)
            Button("Suggest Rewrite") { if let a = model?.selectedFinding { model?.suggestRewrite(a) } }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(model?.selectedFinding == nil || model?.prefs.aiEnabled != true)
            Divider()
            Button("Review") { model?.inspectorTab = .review; model?.showInspector = true }
            Button("Statistics") { model?.inspectorTab = .statistics; model?.showInspector = true }
            Divider()
            Button("Ask About Selection…") { model?.showAskPanel = true }.keyboardShortcut("a", modifiers: [.command, .shift])
            Button("Review Document with AI") { model?.runAI(task: .reviewDocument, question: nil, scope: .document) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model?.prefs.aiEnabled != true || model?.prefs.dataAccess.permits(.document) != true)
            Button("Next Suggestion") { model?.selectSuggestion(offset: 1) }.keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Button("Previous Suggestion") { model?.selectSuggestion(offset: -1) }.keyboardShortcut(.upArrow, modifiers: [.command, .option])
        }
    }
}
