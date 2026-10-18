// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import SwiftUI

/// Shown in a workspace window after its last tab closes, and as a New Tab.
struct WorkspaceStartView: View {
    let workspace: TabWorkspace
    @State private var targeted = false
    @State private var problem: String?
    @FocusState private var focused: Bool

    private var tabs: DocumentTabs { .shared }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 22) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(.secondary)
                    VStack(spacing: 6) {
                        Text(workspace.documents.isEmpty ? "No Open Documents" : "New Tab").font(.title2.weight(.semibold))
                        Text("Choose a format and start writing.").foregroundStyle(.secondary)
                    }
                    dropZone
                        .frame(maxWidth: 460)
                    NewDocumentChoices { kind in
                        activate()
                        tabs.createDocument(kind, in: workspace)
                    }
                    .frame(maxWidth: 460)
                    .multilineTextAlignment(.leading)
                    HStack(spacing: 12) {
                        Button { activate(); TabDocumentController.sharedController.openDocument(nil) } label: { Label("Open…", systemImage: "folder") }
                        OpenRecentMenu { url in activate(); tabs.open(url) }
                    }
                    .controlSize(.large)
                    if let problem {
                        Text(problem).font(.callout).foregroundStyle(.red)
                            .accessibilityLabel("Paste failed: \(problem)")
                    }
                }
                .multilineTextAlignment(.center)
                .padding(32)
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: Preferences.shared.theme.background))
        .contentShape(Rectangle())
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onTapGesture { focused = true }
        .onPasteCommand(of: [.fileURL, .plainText]) { _ in openPasteboard() }
        .dropDestination(for: URL.self) { urls, _ in
            open(urls.compactMap { ExternalFileLinks.fileURL(for: $0) }, emptyProblem: "Terso can't open what was dropped.")
        } isTargeted: { targeted = $0 }
    }

    private var dropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(targeted ? Color.accentColor : .secondary)
            Text(targeted ? "Drop to open" : "Drag documents here")
                .font(.callout.weight(.medium))
            Text("Or paste a copied file or path with ⌘V")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(targeted ? Color.accentColor.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .foregroundStyle(targeted ? Color.accentColor : Color.secondary.opacity(0.4))
        }
        .accessibilityElement(children: .combine)
    }

    /// Finder copies arrive as file URLs; terminal and editor copies as text.
    private func openPasteboard() {
        let pasteboard = NSPasteboard.general
        let copied = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let urls = copied.isEmpty ? Self.fileURLs(fromPastedText: pasteboard.string(forType: .string) ?? "") : copied
        open(urls, emptyProblem: "The clipboard doesn't contain a file path.")
    }

    @discardableResult
    private func open(_ urls: [URL], emptyProblem: String) -> Bool {
        var isDirectory: ObjCBool = false
        let files = urls.filter { FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDirectory) && !isDirectory.boolValue }
        guard !files.isEmpty else {
            problem = urls.isEmpty ? emptyProblem : "No file exists at \(urls[0].path)."
            NSSound.beep()
            return false
        }
        problem = nil
        activate()
        files.forEach(tabs.open)
        return true
    }

    /// Accepts one absolute path, `~` path, `file:` or `obsidian:` URL per line,
    /// optionally quoted or shell-escaped as terminals copy them.
    static func fileURLs(fromPastedText text: String, obsidianVaults: () -> [URL] = ExternalFileLinks.obsidianVaults) -> [URL] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            var path = line.trimmingCharacters(in: .whitespaces)
            if path.count > 1, let first = path.first, "\"'".contains(first), path.last == first {
                path = String(path.dropFirst().dropLast())
            } else {
                path = path.replacingOccurrences(of: #"\\(.)"#, with: "$1", options: .regularExpression)
            }
            if path.hasPrefix("file:") || path.hasPrefix("obsidian:") {
                return URL(string: path).flatMap { ExternalFileLinks.fileURL(for: $0, obsidianVaults: obsidianVaults) }
            }
            path = (path as NSString).expandingTildeInPath
            return path.hasPrefix("/") ? URL(fileURLWithPath: path).standardizedFileURL : nil
        }
    }

    /// New and opened documents join the window that asked for them.
    private func activate() { tabs.activeWorkspace = workspace }
}
