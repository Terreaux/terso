// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import SwiftUI

/// Shown in a workspace window after its last tab closes.
struct WorkspaceStartView: View {
    let workspace: TabWorkspace
    @State private var targeted = false

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
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            activate()
            files.forEach(tabs.open)
            return true
        } isTargeted: { targeted = $0 }
    }

    /// New and opened documents join the window that asked for them.
    private func activate() { tabs.activeWorkspace = workspace }
}
