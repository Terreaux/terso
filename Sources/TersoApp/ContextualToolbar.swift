// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import Combine
import SwiftUI

/// Editing, type and presentation follow the active document and its mode.
struct ContextualToolbar: View {
    let model: WorkspaceModel
    let source: String
    let undoManager: UndoManager?
    var floating: Bool = false
    @State private var canUndo = false
    @State private var canRedo = false

    init(model: WorkspaceModel, source: String, undoManager: UndoManager?, floating: Bool = false) {
        self.model = model
        self.source = source
        self.undoManager = undoManager
        self.floating = floating
    }

    init(document: TabDocument, floating: Bool = false) {
        self.init(model: document.model, source: document.contents.text, undoManager: document.undoManager, floating: floating)
    }

    private var editable: Bool { model.renderMode != .preview && model.editor != nil }
    private var latex: Bool { RenderMode.isLaTeX(source: source, fileURL: model.fileURL) }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            controls(compact: false)
            controls(compact: true)
            controls(compact: true, minimal: true)
            controls(compact: true, minimal: true, ultra: true)
        }
        .font(.system(size: 12))
        .buttonStyle(.plain)
        .padding(.horizontal, floating ? 14 : 12)
        .padding(.vertical, floating ? 9 : 7)
        .background {
            if floating {
                Capsule().fill(.regularMaterial)
                    .overlay(Capsule().strokeBorder(.separator.opacity(0.6)))
                    .shadow(color: .black.opacity(0.14), radius: 12, y: 4)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Contextual toolbar")
        .onAppear(perform: refreshUndo)
        .onChange(of: source) { _, _ in refreshUndo() }
        .onReceive(Publishers.Merge3(
            NotificationCenter.default.publisher(for: Notification.Name.NSUndoManagerDidCloseUndoGroup, object: undoManager),
            NotificationCenter.default.publisher(for: Notification.Name.NSUndoManagerDidUndoChange, object: undoManager),
            NotificationCenter.default.publisher(for: Notification.Name.NSUndoManagerDidRedoChange, object: undoManager)
        )) { _ in refreshUndo() }
    }

    private func controls(compact: Bool, minimal: Bool = false, ultra: Bool = false) -> some View {
        HStack(spacing: ultra ? 2 : (compact ? 7 : 10)) {
            if model.renderMode != .preview {
                HStack(spacing: 2) {
                    toolbarButton("Undo", symbol: "arrow.uturn.backward", enabled: editable && canUndo) {
                        undoManager?.undo()
                        refreshUndo()
                    }
                    toolbarButton("Redo", symbol: "arrow.uturn.forward", enabled: editable && canRedo) {
                        undoManager?.redo()
                        refreshUndo()
                    }
                }
                if !ultra { separator }
                FormattingToolbar(model: model, source: source, latex: latex, compact: compact, minimal: minimal, iconOnly: ultra)
                    .disabled(!editable)
                if !ultra { separator }
            }
            TypographyControls(model: model, compact: compact, latex: latex)
            if !ultra { separator }
            more
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var separator: some View {
        Divider().frame(height: 18).padding(.horizontal, 1).accessibilityHidden(true)
    }

    private var more: some View {
        Menu {
            if model.renderMode != .preview {
                Section("Insert") {
                    Button("Code Block", systemImage: "text.badge.plus") { model.editor?.performFormatting(.codeBlock) }
                    Button("Horizontal Rule", systemImage: "minus") { model.editor?.performFormatting(.horizontalRule) }
                }
                .disabled(!editable)
            }
            Section("Presentation") {
                Picker("Editor width", selection: Binding(get: { model.prefs.columnWidth }, set: { model.prefs.columnWidth = $0 })) {
                    Text("Narrow — 600 pt").tag(600.0)
                    Text("Comfortable — 720 pt").tag(720.0)
                    Text("Wide — 860 pt").tag(860.0)
                    if ![600.0, 720.0, 860.0].contains(model.prefs.columnWidth) {
                        Text("Custom — \(Int(model.prefs.columnWidth)) pt").tag(model.prefs.columnWidth)
                    }
                }
                .disabled(model.manutius || (latex && model.renderMode == .preview))
                Picker("Source syntax", selection: Binding(get: { model.prefs.syntax }, set: { model.prefs.syntax = $0 })) {
                    ForEach(SyntaxVisibility.allCases) { Text($0.title).tag($0) }
                }
                .disabled(model.renderMode == .preview)
                Toggle("Document map", isOn: Binding(get: { model.prefs.showDocumentMap }, set: { model.prefs.showDocumentMap = $0 }))
            }
            Section("Contextual Toolbar") {
                Picker("Position", selection: Binding(get: { model.prefs.contextualToolbarPlacement }, set: { model.prefs.contextualToolbarPlacement = $0 })) {
                    ForEach(ContextualToolbarPlacement.allCases) { Text($0.title).tag($0) }
                }
            }
        } label: {
            Image(systemName: "ellipsis").frame(width: 26, height: 26).contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More toolbar options")
        .help("Editor presentation and toolbar position")
    }

    private func refreshUndo() {
        canUndo = undoManager?.canUndo ?? false
        canRedo = undoManager?.canRedo ?? false
    }
}

/// Commands edit the source through the same document editor in Source and Mixed.
struct FormattingToolbar: View {
    let model: WorkspaceModel
    let source: String
    let latex: Bool
    @State private var activeBlock: EditorBlockStyle = .body
    var compact = false
    var minimal = false
    var iconOnly = false

    var body: some View {
        HStack(spacing: 2) {
            if minimal {
                Menu {
                    blockStyles
                    Divider()
                    formattingItems
                } label: {
                    if iconOnly { Image(systemName: "textformat").frame(width: 20, height: 26) }
                    else { Label("Format", systemImage: "textformat") }
                }
                .fixedSize()
                .help("Format the selection or current paragraph")
                .accessibilityLabel("Formatting")
            } else {
                Menu { blockStyles } label: {
                    if compact { Image(systemName: "textformat") } else { Text(activeBlock.rawValue) }
                }
                .fixedSize().padding(.horizontal, 4)
                .help("Change paragraph style").accessibilityLabel("Block style")
                commandButton("Bold", "bold", .bold)
                commandButton("Italic", "italic", .italic)
                commandButton("Underline", "underline", .underline)
                commandButton("Insert Link", "link", .link)
                if compact {
                    Menu { insertionItems } label: { Image(systemName: "plus").frame(width: 26, height: 26) }
                        .menuIndicator(.hidden).fixedSize()
                        .help("Lists, quotes, code and images").accessibilityLabel("Insert formatting")
                } else {
                    commandButton("Bulleted List", "list.bullet", .bulletedList)
                    commandButton("Numbered List", "list.number", .numberedList)
                    commandButton("Blockquote", "text.quote", .blockquote)
                    commandButton("Code", "curlybraces", .code)
                    commandButton("Insert Image", "photo", .image)
                }
            }
        }
        .onAppear(perform: refreshBlockStyle)
        .onChange(of: source) { _, _ in refreshBlockStyle() }
        .onReceive(NotificationCenter.default.publisher(for: NSTextView.didChangeSelectionNotification)) { notification in
            guard let textView = notification.object as? NSTextView,
                  textView === (model.editor as? EditorCoordinator)?.textView else { return }
            refreshBlockStyle()
        }
    }

    private func refreshBlockStyle() {
        guard let editor = model.editor else { activeBlock = .body; return }
        activeBlock = FormattingCommands.blockStyle(text: source, selection: editor.selection.nsRange, latex: latex)
    }

    private var blockStyles: some View {
        Section("Block Style") {
            Button("Body") { perform(.blockStyle(.body)) }
            Button("Heading 1") { perform(.blockStyle(.heading1)) }
            Button("Heading 2") { perform(.blockStyle(.heading2)) }
            Button("Heading 3") { perform(.blockStyle(.heading3)) }
        }
    }

    private var formattingItems: some View {
        Group {
            Button("Bold", systemImage: "bold") { perform(.bold) }
            Button("Italic", systemImage: "italic") { perform(.italic) }
            Button("Underline", systemImage: "underline") { perform(.underline) }
            Button("Insert Link", systemImage: "link") { perform(.link) }
            insertionItems
        }
    }

    private var insertionItems: some View {
        Group {
            Button("Bulleted List", systemImage: "list.bullet") { perform(.bulletedList) }
            Button("Numbered List", systemImage: "list.number") { perform(.numberedList) }
            Button("Blockquote", systemImage: "text.quote") { perform(.blockquote) }
            Button("Code", systemImage: "curlybraces") { perform(.code) }
            Button("Code Block", systemImage: "text.badge.plus") { perform(.codeBlock) }
            Button("Horizontal Rule", systemImage: "minus") { perform(.horizontalRule) }
            Button("Insert Image", systemImage: "photo") { perform(.image) }
        }
    }

    private func commandButton(_ title: String, _ symbol: String, _ command: FormattingCommand) -> some View {
        toolbarButton(title, symbol: symbol) { perform(command) }
    }

    private func perform(_ command: FormattingCommand) {
        guard model.renderMode != .preview else { return }
        model.editor?.performFormatting(command)
    }
}

/// Reading preferences normally apply app-wide; Manutius edits the book's type.
struct TypographyControls: View {
    let model: WorkspaceModel
    var compact = false
    var latex = false

    private var book: Bool { model.manutius }
    private var unmanagedLaTeX: Bool { book && model.isLaTeXDocument && model.documentBook == nil }
    private var size: Double { book ? model.bookDesign.typeSize : model.prefs.fontSize }
    private var spacing: Double { book ? model.bookDesign.lineSpacing : model.prefs.lineSpacing }

    var body: some View {
        Menu {
            if unmanagedLaTeX || (latex && model.renderMode == .preview && !book) {
                Text("Typography is set by this document’s LaTeX preamble.")
                if book { Button("Book Design…") { model.showBookDesign() } }
            } else {
                if model.renderMode == .source && !book {
                    Text("Source uses a monospaced font.")
                } else {
                    Picker("Font", selection: fontBinding) {
                        if book { Text("Editor Font").tag(EditorFont?.none) }
                        ForEach(EditorFont.allCases.filter { !book || ($0 != .mono && $0 != .system) }) {
                            Text($0.title).tag(EditorFont?.some($0))
                        }
                    }
                }
                Picker("Size", selection: sizeBinding) {
                    ForEach(sizes, id: \.self) { Text("\($0.formatted(.number.precision(.fractionLength(0...1)))) pt").tag($0) }
                }
                Picker("Line spacing", selection: spacingBinding) {
                    ForEach(spacings, id: \.self) { Text($0.formatted(.number.precision(.fractionLength(0...2)))).tag($0) }
                }
                if book {
                    Divider()
                    Button("Book Design…") { model.showBookDesign() }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "textformat.size")
                if !compact { Text(book ? "Book Type" : "Text") }
            }
            .padding(.horizontal, 4).frame(minHeight: 26)
        }
        .fixedSize()
        .accessibilityLabel(book ? "Book typography" : "Typography")
        .help(book ? "Font, size and spacing for this book" : "Editor font, size and line spacing")
    }

    private var sizes: [Double] { Array(Set((book ? [9, 10, 11, 12, 13, 14, 16] : [12, 14, 16, 17, 18, 20, 24, 28]) + [size])).sorted() }
    private var spacings: [Double] { Array(Set((book ? [1.1, 1.2, 1.4, 1.6, 1.8, 2] : [1, 1.2, 1.4, 1.6, 1.8, 2, 2.2]) + [spacing])).sorted() }
    private var fontBinding: Binding<EditorFont?> {
        Binding(get: { book ? model.bookDesign.typeface : model.prefs.font }, set: { value in
            if book { model.updateBookDesign { $0.typeface = value } }
            else if let value { model.prefs.font = value }
        })
    }
    private var sizeBinding: Binding<Double> {
        Binding(get: { size }, set: { value in
            if book { model.updateBookDesign { $0.typeSize = value } } else { model.prefs.fontSize = value }
        })
    }
    private var spacingBinding: Binding<Double> {
        Binding(get: { spacing }, set: { value in
            if book { model.updateBookDesign { $0.lineSpacing = value } } else { model.prefs.lineSpacing = value }
        })
    }
}

@MainActor private func toolbarButton(_ title: String, symbol: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Image(systemName: symbol)
            .frame(width: 26, height: 26)
            .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(!enabled)
    .help(title)
    .accessibilityLabel(title)
}
