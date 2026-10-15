// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import Observation
import SwiftUI

/// A named set of documents, wherever they live on disk. Linking a document
/// never moves or copies it; a project only remembers where it is.
struct TersoProject: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var documents: [ProjectDocument] = []
}

/// A linked file. The bookmark follows renames and moves; the path is the
/// fallback, and what a missing file is shown as.
struct ProjectDocument: Identifiable, Codable, Hashable {
    var id = UUID()
    var bookmark: Data?
    var path: String

    init(url: URL) {
        bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        path = url.standardizedFileURL.path
    }

    var url: URL {
        var stale = false
        if let bookmark, let resolved = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) {
            return resolved.standardizedFileURL
        }
        return URL(fileURLWithPath: path)
    }

    var exists: Bool { FileManager.default.fileExists(atPath: url.path) }
    var title: String { url.deletingPathExtension().lastPathComponent }
}

@MainActor
@Observable
final class ProjectStore {
    static let shared = ProjectStore()
    private(set) var projects: [TersoProject] = []
    private let fileURL: URL

    init(fileURL: URL = URL.applicationSupportDirectory.appendingPathComponent("Terso/Projects.json")) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([TersoProject].self, from: data) {
            projects = saved
        }
    }

    @discardableResult
    func create(named name: String, with urls: [URL] = []) -> TersoProject {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var project = TersoProject(name: trimmed.isEmpty ? "Untitled Project" : trimmed)
        project.documents = unique(urls).map(ProjectDocument.init(url:))
        projects.append(project)
        save()
        return project
    }

    func rename(_ id: TersoProject.ID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = index(id) else { return }
        projects[i].name = trimmed
        save()
    }

    func delete(_ id: TersoProject.ID) {
        projects.removeAll { $0.id == id }
        save()
    }

    /// Links files to a project; a file already linked is left as it is.
    func add(_ urls: [URL], to id: TersoProject.ID) {
        guard let i = index(id) else { return }
        let linked = Set(projects[i].documents.map { $0.url.standardizedFileURL })
        let new = unique(urls).filter { !linked.contains($0) }
        guard !new.isEmpty else { return }
        projects[i].documents += new.map(ProjectDocument.init(url:))
        save()
    }

    func remove(_ document: ProjectDocument.ID, from id: TersoProject.ID) {
        guard let i = index(id) else { return }
        projects[i].documents.removeAll { $0.id == document }
        save()
    }

    func contains(_ url: URL, in id: TersoProject.ID) -> Bool {
        let target = url.standardizedFileURL
        return projects.first { $0.id == id }?.documents.contains { $0.url == target } ?? false
    }

    private func index(_ id: TersoProject.ID) -> Int? { projects.firstIndex { $0.id == id } }

    private func unique(_ urls: [URL]) -> [URL] {
        var seen = Set<URL>()
        return urls.map(\.standardizedFileURL).filter { $0.isFileURL && seen.insert($0).inserted }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(projects).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Terso: could not save projects: \(error.localizedDescription)")
        }
    }
}

/// Documents shown recently, newest first. Terso keeps its own list because
/// the system's recent-documents list can stay empty (unsigned or moved app
/// bundles), and merges the system's in when it has any.
@MainActor
@Observable
final class RecentDocuments {
    static let shared = RecentDocuments()
    private let defaults: UserDefaults
    private let key = "recentDocuments"
    private(set) var paths: [String]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        paths = defaults.stringArray(forKey: key) ?? []
    }

    func note(_ url: URL?) {
        guard let url, url.isFileURL else { return }
        let path = url.standardizedFileURL.path
        guard paths.first != path else { return }
        paths = Array(([path] + paths.filter { $0 != path }).prefix(20))
        defaults.set(paths, forKey: key)
    }

    func clear() {
        paths = []
        defaults.removeObject(forKey: key)
        TabDocumentController.sharedController.clearRecentDocuments(nil)
    }

    func urls(limit: Int) -> [URL] {
        var seen = Set<String>()
        let system = TabDocumentController.sharedController.recentDocumentURLs.map(\.standardizedFileURL.path)
        return (paths + system)
            .filter { seen.insert($0).inserted && FileManager.default.fileExists(atPath: $0) }
            .prefix(limit).map { URL(fileURLWithPath: $0) }
    }
}

/// Open Recent as a dropdown: recent files (with their folder, since names
/// repeat) and every project's documents.
struct OpenRecentMenu: View {
    let open: (URL) -> Void
    private var recents: [URL] { RecentDocuments.shared.urls(limit: 15) }
    private var projects: [TersoProject] { ProjectStore.shared.projects.filter { !$0.documents.isEmpty } }

    var body: some View {
        Menu {
            if recents.isEmpty { Text("No Recent Documents") }
            ForEach(recents, id: \.self) { url in
                Button("\(url.lastPathComponent) — \(url.deletingLastPathComponent().lastPathComponent)") { open(url) }
            }
            if !projects.isEmpty {
                Divider()
                Menu("Projects") {
                    ForEach(projects) { p in
                        Menu(p.name) {
                            ForEach(p.documents.filter(\.exists)) { d in Button(d.url.lastPathComponent) { open(d.url) } }
                        }
                    }
                }
            }
            if !recents.isEmpty {
                Divider()
                Button("Clear Menu") { RecentDocuments.shared.clear() }
            }
        } label: {
            Label("Open Recent", systemImage: "clock")
        }
        .fixedSize()
        .disabled(recents.isEmpty && projects.isEmpty)
        .help("Open a recent document or one from a project")
    }
}
