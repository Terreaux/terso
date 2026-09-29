// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import SwiftUI

/// Shown in a workspace window after its last tab closes.
struct WorkspaceStartView: View {
    let workspace: TabWorkspace
    @State private var targeted = false
    @State private var pasteProblem: String?
    @FocusState private var focused: Bool

    private var tabs: DocumentTabs { .shared }
    private var recents: [URL] { Array(TabDocumentController.sharedController.recentDocumentURLs.prefix(5)) }

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: targeted ? "arrow.down.doc" : "doc.text")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(targeted ? Color.accentColor : .secondary)
            VStack(spacing: 6) {
                Text("No Open Documents").font(.title2.weight(.semibold))
                Text("Create a document, open one, or drop Markdown and text files here.")
                    .foregroundStyle(.secondary)
                Text("Paste a copied file or path with ⌘V to open it.")
                    .font(.callout).foregroundStyle(.tertiary)
                if let pasteProblem {
                    Text(pasteProblem).font(.callout).foregroundStyle(.red)
                        .accessibilityLabel("Paste failed: \(pasteProblem)")
                }
            }
            HStack(spacing: 12) {
                Button { activate(); tabs.newDocument() } label: { Label("New Document", systemImage: "square.and.pencil") }
                    .keyboardShortcut(.defaultAction)
                Button { activate(); TabDocumentController.sharedController.openDocument(nil) } label: { Label("Open…", systemImage: "folder") }
            }
            .controlSize(.large)
            if !recents.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recent").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(recents, id: \.self) { url in
                        Button { activate(); tabs.open(url) } label: {
                            Label(url.lastPathComponent, systemImage: "doc").lineLimit(1)
                        }
                        .buttonStyle(.link)
                        .help(url.path)
                    }
                }
                .frame(width: 280, alignment: .leading)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .foregroundStyle(targeted ? Color.accentColor : .clear)
                .padding(16)
        }
        .contentShape(Rectangle())
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onTapGesture { focused = true }
        .onPasteCommand(of: [.fileURL, .plainText]) { _ in openPasteboard() }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            activate()
            files.forEach(tabs.open)
            return true
        } isTargeted: { targeted = $0 }
    }

    /// Finder copies arrive as file URLs; terminal and editor copies as text.
    private func openPasteboard() {
        let pasteboard = NSPasteboard.general
        let copied = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let urls = copied.isEmpty ? Self.fileURLs(fromPastedText: pasteboard.string(forType: .string) ?? "") : copied
        var isDirectory: ObjCBool = false
        let files = urls.filter { FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDirectory) && !isDirectory.boolValue }
        guard !files.isEmpty else {
            pasteProblem = urls.isEmpty ? "The clipboard doesn't contain a file path." : "No file exists at \(urls[0].path)."
            NSSound.beep()
            return
        }
        pasteProblem = nil
        activate()
        files.forEach(tabs.open)
    }

    /// Accepts one absolute path, `~` path or `file:` URL per line, optionally
    /// quoted or shell-escaped as terminals copy them.
    static func fileURLs(fromPastedText text: String) -> [URL] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            var path = line.trimmingCharacters(in: .whitespaces)
            if path.count > 1, let first = path.first, "\"'".contains(first), path.last == first {
                path = String(path.dropFirst().dropLast())
            } else {
                path = path.replacingOccurrences(of: #"\\(.)"#, with: "$1", options: .regularExpression)
            }
            if path.hasPrefix("file:") { return URL(string: path).flatMap { $0.isFileURL ? $0 : nil } }
            path = (path as NSString).expandingTildeInPath
            return path.hasPrefix("/") ? URL(fileURLWithPath: path).standardizedFileURL : nil
        }
    }

    /// New and opened documents join the window that asked for them.
    private func activate() { tabs.activeWorkspace = workspace }
}
