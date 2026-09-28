// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import SwiftUI
import TersoCore

struct SidebarView: View {
    let model: WorkspaceModel
    let fileURL: URL?
    @State private var files: [URL] = []

    var body: some View {
        List {
            Section("Outline") {
                if let hs = model.local?.headings, !hs.isEmpty {
                    ForEach(hs, id: \.range) { h in
                        Button { model.editor?.reveal(h.range, select: false) } label: {
                            Text(h.title)
                                .font(h.level == 1 ? .body.weight(.medium) : .body)
                                .foregroundStyle(h.level <= 2 ? .primary : .secondary)
                                .lineLimit(1)
                                .padding(.leading, CGFloat(h.level - 1) * 10)
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    Text("Headings appear here").foregroundStyle(.tertiary)
                }
            }
            if !files.isEmpty {
                Section("Folder") {
                    ForEach(files, id: \.self) { url in
                        Button {
                            DocumentTabs.shared.open(url)
                        } label: {
                            Label(url.deletingPathExtension().lastPathComponent, systemImage: "doc.text")
                                .fontWeight(url.standardizedFileURL == fileURL?.standardizedFileURL ? .semibold : .regular)
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .task(id: fileURL) { loadFiles() }
    }

    private func loadFiles() {
        guard let dir = fileURL?.deletingLastPathComponent() else { files = []; return }
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        files = items.filter { ["md", "markdown", "txt"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}
