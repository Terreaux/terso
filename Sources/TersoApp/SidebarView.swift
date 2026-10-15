// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import TersoCore

struct SidebarView: View {
    let model: WorkspaceModel
    let fileURL: URL?
    @State private var files: [URL] = []
    @State private var showProjects = true
    @State private var showRecent = true
    @State private var expanded: Set<TersoProject.ID> = []
    @State private var naming: Naming?
    @State private var draftName = ""
    private var store: ProjectStore { .shared }

    /// What the name prompt is for.
    private enum Naming: Identifiable {
        case new(with: [URL]), rename(TersoProject)
        var id: String {
            switch self {
            case .new: "new"
            case .rename(let p): p.id.uuidString
            }
        }
    }

    var body: some View {
        List {
            Section(isExpanded: $showProjects) { projects } header: { projectsHeader }
            // The open document is already in front of you; Recent is for the others.
            let recents = RecentDocuments.shared.urls(limit: 9).filter { $0 != fileURL?.standardizedFileURL }.prefix(8)
            if !recents.isEmpty {
                Section("Recent", isExpanded: $showRecent) {
                    ForEach(Array(recents), id: \.self) { url in
                        documentButton(url, systemImage: "clock")
                            .contextMenu { addToProjectMenu([url]); revealButton(url) }
                    }
                }
            }
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
                        documentButton(url, systemImage: "doc.text")
                            .contextMenu { addToProjectMenu([url]) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .themedPanel(Preferences.shared.theme)
        .task(id: fileURL) { loadFiles() }
        .alert(naming.map { if case .rename = $0 { "Rename Project" } else { "New Project" } } ?? "",
               isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Name", text: $draftName)
            Button("Cancel", role: .cancel) { naming = nil }
            Button(naming.map { if case .rename = $0 { "Rename" } else { "Create" } } ?? "OK") { commitName() }
        } message: {
            if case .new(let urls)? = naming, !urls.isEmpty {
                Text(urls.count == 1 ? "Links \(urls[0].lastPathComponent). Files stay where they are."
                                     : "Links \(urls.count) documents. Files stay where they are.")
            } else {
                Text("A project links documents from anywhere on disk. Files stay where they are.")
            }
        }
    }

    // MARK: Projects

    private var projectsHeader: some View {
        HStack {
            Text("Projects")
            Spacer()
            Menu {
                Button("New Project…") { prompt(.new(with: [])) }
                Button("New Project with This Document…") { prompt(.new(with: fileURL.map { [$0] } ?? [])) }
                    .disabled(fileURL == nil)
                Button("New Project from Open Tabs…") { prompt(.new(with: openTabURLs)) }
                    .disabled(openTabURLs.isEmpty)
            } label: { Image(systemName: "plus") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("New project").accessibilityLabel("New Project")
        }
    }

    @ViewBuilder private var projects: some View {
        if store.projects.isEmpty {
            Button { prompt(.new(with: fileURL.map { [$0] } ?? [])) } label: {
                Label("New Project…", systemImage: "folder.badge.plus").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        ForEach(store.projects) { project in
            DisclosureGroup(isExpanded: Binding(get: { expanded.contains(project.id) },
                                                set: { if $0 { expanded.insert(project.id) } else { expanded.remove(project.id) } })) {
                ForEach(project.documents) { doc in
                    projectDocument(doc, in: project)
                }
                if project.documents.isEmpty {
                    Text("Drop documents here").font(.callout).foregroundStyle(.tertiary)
                }
            } label: {
                Label {
                    HStack {
                        Text(project.name).lineLimit(1)
                        Spacer()
                        Text("\(project.documents.count)").monospacedDigit().foregroundStyle(.tertiary)
                    }
                } icon: {
                    Image(systemName: project.documents.contains { $0.url == fileURL?.standardizedFileURL } ? "folder.fill" : "folder")
                }
                .contextMenu { projectMenu(project) }
            }
            .dropDestination(for: URL.self) { urls, _ in
                store.add(urls, to: project.id)
                expanded.insert(project.id)
                return true
            }
        }
    }

    @ViewBuilder private func projectMenu(_ project: TersoProject) -> some View {
        Button("Add This Document") { store.add([fileURL!], to: project.id); expanded.insert(project.id) }
            .disabled(fileURL == nil || store.contains(fileURL!, in: project.id))
        Button("Add Documents…") { chooseDocuments(for: project) }
        Button("Open All") { project.documents.filter(\.exists).forEach { DocumentTabs.shared.open($0.url) } }
            .disabled(!project.documents.contains(where: \.exists))
        Divider()
        Button("Rename…") { prompt(.rename(project)) }
        Button("Delete Project", role: .destructive) { store.delete(project.id) }
    }

    private func projectDocument(_ doc: ProjectDocument, in project: TersoProject) -> some View {
        let missing = !doc.exists
        return Button {
            if missing { NSSound.beep() } else { DocumentTabs.shared.open(doc.url) }
        } label: {
            Label(doc.title, systemImage: missing ? "questionmark.folder" : "doc.text")
                .fontWeight(doc.url == fileURL?.standardizedFileURL ? .semibold : .regular)
                .foregroundStyle(missing ? .tertiary : .primary)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .help(missing ? "Not found: \(doc.path)" : doc.url.path)
        .contextMenu {
            Button("Remove from Project") { store.remove(doc.id, from: project.id) }
            if !missing { revealButton(doc.url) }
        }
    }

    // MARK: Shared pieces

    private func documentButton(_ url: URL, systemImage: String) -> some View {
        Button { DocumentTabs.shared.open(url) } label: {
            Label(url.deletingPathExtension().lastPathComponent, systemImage: systemImage)
                .fontWeight(url.standardizedFileURL == fileURL?.standardizedFileURL ? .semibold : .regular)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .help(url.path)
    }

    @ViewBuilder private func addToProjectMenu(_ urls: [URL]) -> some View {
        Menu("Add to Project") {
            ForEach(store.projects) { p in
                Button(p.name) { store.add(urls, to: p.id); expanded.insert(p.id) }
                    .disabled(urls.allSatisfy { store.contains($0, in: p.id) })
            }
            if !store.projects.isEmpty { Divider() }
            Button("New Project…") { prompt(.new(with: urls)) }
        }
    }

    private func revealButton(_ url: URL) -> some View {
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    private var openTabURLs: [URL] {
        DocumentTabs.shared.activeWorkspace?.documents.compactMap(\.fileURL) ?? []
    }

    private func prompt(_ n: Naming) {
        if case .rename(let p) = n { draftName = p.name } else { draftName = "" }
        naming = n
    }

    private func commitName() {
        switch naming {
        case .new(let urls)?:
            let project = store.create(named: draftName, with: urls)
            expanded.insert(project.id)
            showProjects = true
        case .rename(let p)?:
            store.rename(p.id, to: draftName)
        case nil: break
        }
        naming = nil
    }

    private func chooseDocuments(for project: TersoProject) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ["md", "markdown", "txt", "tex", "latex"].compactMap { UTType(filenameExtension: $0) }
        panel.prompt = "Add to \(project.name)"
        guard panel.runModal() == .OK else { return }
        store.add(panel.urls, to: project.id)
        expanded.insert(project.id)
    }

    private func loadFiles() {
        guard let dir = fileURL?.deletingLastPathComponent() else { files = []; return }
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        files = items.filter { ["md", "markdown", "txt", "tex", "latex"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}
