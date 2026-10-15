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
            Button("Bold") { model?.editor?.wrapSelection(prefix: "**", suffix: "**", placeholder: "bold") }.keyboardShortcut("b")
            Button("Italic") { model?.editor?.wrapSelection(prefix: "*", suffix: "*", placeholder: "italic") }.keyboardShortcut("i")
            Button("Inline Code") { model?.editor?.wrapSelection(prefix: "`", suffix: "`", placeholder: "code") }.keyboardShortcut("e")
            Button("Link") { model?.editor?.wrapSelection(prefix: "[", suffix: "](https://)", placeholder: "text") }.keyboardShortcut("k")
            Divider()
            Button("Heading 1") { model?.editor?.prefixLines("# ") }.keyboardShortcut("1", modifiers: [.command, .option])
            Button("Heading 2") { model?.editor?.prefixLines("## ") }.keyboardShortcut("2", modifiers: [.command, .option])
            Button("Heading 3") { model?.editor?.prefixLines("### ") }.keyboardShortcut("3", modifiers: [.command, .option])
            Divider()
            Button("Blockquote") { model?.editor?.prefixLines("> ") }.keyboardShortcut("'", modifiers: [.command, .option])
            Button("Bulleted List") { model?.editor?.prefixLines("- ") }.keyboardShortcut("l", modifiers: [.command, .option])
            Button("Numbered List") { model?.editor?.prefixLines("1. ") }.keyboardShortcut("n", modifiers: [.command, .option])
            Button("Code Block") { model?.editor?.wrapSelection(prefix: "```\n", suffix: "\n```", placeholder: "code") }
            Button("Horizontal Rule") { model?.editor?.wrapSelection(prefix: "\n---\n", suffix: "", placeholder: "") }
        }
        CommandGroup(after: .sidebar) {
            ForEach(RenderMode.allCases) { mode in
                Button(mode.rawValue + " Mode") { model?.renderMode = mode }
                    .keyboardShortcut(mode == .source ? "1" : mode == .mixed ? "2" : "3", modifiers: [.command, .control])
                    .disabled(model == nil)
            }
            Divider()
            Button(model?.focusMode == true ? "Exit Focus Mode" : "Focus Mode") { model?.toggleFocusMode() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Button("Typewriter Scrolling") { model?.typewriter.toggle(); model?.editor?.refreshDecorations() }
                .keyboardShortcut("y", modifiers: [.command, .shift])
            Button(model?.zenMode == true ? "Exit Zen Mode" : "Zen Mode") { model?.toggleZenMode() }
                .keyboardShortcut("j", modifiers: [.command, .shift])
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
