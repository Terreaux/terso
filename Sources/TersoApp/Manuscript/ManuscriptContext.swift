// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import TersoCore
import UniformTypeIdentifiers

/// Captured on the main actor. Building the index and staging a compile run off it.
struct ManuscriptRequest: Sendable {
    struct Project: Sendable { let root: URL; let linked: [URL] }
    let active: URL
    let source: String
    let projects: [Project]
    let buffers: [URL: String]
    var isPaper: Bool {
        ["tex", "latex"].contains(active.pathExtension.lowercased()) || !projects.isEmpty ||
        source.contains("bibliography:") || source.contains("\\bibliography") || source.contains("\\addbibresource")
    }

    func load() throws -> ManuscriptIndex {
        let active = active.manuscriptURL
        for project in projects {
            try Task.checkCancellation()
            let root = project.root.manuscriptURL
            let linked = project.linked
            if root == active { return try ManuscriptIndex(root: root, linked: linked, buffers: buffers) }
            if let index = try? ManuscriptIndex(root: root, linked: linked, buffers: buffers), index.sources[active] != nil || index.bibliographySources[active] != nil {
                return index
            }
        }
        if let root = Self.magicRoot(in: source, at: active), root != active {
            return try ManuscriptIndex(root: root, buffers: buffers)
        }
        return try ManuscriptIndex(root: active, linked: projects.first(where: { $0.linked.contains(active) })?.linked ?? [], buffers: buffers)
    }

    static func magicRoot(in source: String, at url: URL) -> URL? {
        let lines = source.split(whereSeparator: \.isNewline).prefix(15)
        for line in lines {
            guard let match = line.wholeMatch(of: /(?i)\s*%\s*!\s*TEX\s+root\s*=\s*(.+?)\s*/) else { continue }
            let value = String(match.1).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return URL(fileURLWithPath: value, relativeTo: url.deletingLastPathComponent()).manuscriptURL
        }
        return nil
    }
}

@MainActor enum ManuscriptContext {
    static func request(for file: URL, source: String) -> ManuscriptRequest {
        let active = file.manuscriptURL
        var buffers: [URL: String] = [:]
        for workspace in DocumentTabs.shared.workspaces {
            for doc in workspace.documents {
                if let file = doc.fileURL { buffers[file.manuscriptURL] = doc.contents.text }
            }
        }
        buffers[active] = source
        let candidates = ProjectStore.shared.projects.compactMap { project -> ManuscriptRequest.Project? in
            guard let root = project.manuscriptRoot?.url.manuscriptURL else { return nil }
            let linked = project.documents.map { $0.url.manuscriptURL }
            guard linked.contains(active) || active.path.hasPrefix(root.deletingLastPathComponent().path + "/") else { return nil }
            return .init(root: root, linked: linked)
        }.sorted { $0.root == active && $1.root != active }
        return .init(active: active, source: source, projects: candidates, buffers: buffers)
    }

    static func index(for file: URL, source: String) async throws -> ManuscriptIndex {
        let request = request(for: file, source: source)
        let worker = Task.detached(priority: .userInitiated) { try request.load() }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    static func reveal(_ location: ManuscriptLocation) {
        let controller = TabDocumentController.sharedController
        func select(_ doc: TabDocument) {
            DocumentTabs.shared.present(doc)
            if doc.model.renderMode == .preview { doc.model.renderMode = .mixed }
            guard let range = location.resolved(in: doc.contents.text) else {
                doc.model.refreshManuscript()
                let alert = NSAlert()
                alert.messageText = "This passage changed."
                alert.informativeText = "The manuscript index is refreshing. Open Manuscript References to select the current passage."
                if let window = doc.workspace?.window { alert.beginSheetModal(for: window) }
                return
            }
            if let editor = doc.model.editor { editor.reveal(range, select: true) }
            else { doc.model.initialSelection = range.nsRange }
        }
        if let doc = controller.document(for: location.url) as? TabDocument { select(doc); return }
        controller.openDocument(withContentsOf: location.url, display: true) { document, _, error in
            if let doc = document as? TabDocument { select(doc) }
            else if let error { NSApp.presentError(error) }
        }
    }
}

/// A private shadow tree exposes the manuscript's regular local inputs to TeX.
/// Directories containing open buffers are recreated, so no write touches a source file.
enum ManuscriptBuildTree {
    static func stage(_ index: ManuscriptIndex, in directory: URL) throws -> URL {
        let fm = FileManager.default
        let rootDir = index.root.deletingLastPathComponent()
        var base = rootDir
        let inputs = Set(index.sources.keys).union(index.resources)
        while inputs.contains(where: { !$0.path.hasPrefix(base.path == "/" ? "/" : base.path + "/") }) && base.path != "/" {
            base = base.deletingLastPathComponent()
        }
        func destination(_ url: URL) -> URL {
            let path = String(url.path.dropFirst(base.path == "/" ? 1 : base.path.count + 1))
            return directory.appendingPathComponent(path)
        }
        var overrides = index.sources
        overrides.merge(index.bibliographySources) { _, new in new }
        let directories = Set(inputs.map { $0.deletingLastPathComponent() }).union([rootDir])
        // Construct every private directory and overlay before adding fallback
        // symlinks. A shared ancestor can never point a later write into the
        // original tree, including when a manuscript references ../styles.
        for sourceDir in directories {
            try fm.createDirectory(at: destination(sourceDir), withIntermediateDirectories: true)
        }
        for input in inputs {
            try Task.checkCancellation()
            let target = destination(input)
            if let text = overrides[input] { try text.write(to: target, atomically: true, encoding: .utf8) }
            else { try fm.createSymbolicLink(at: target, withDestinationURL: input) }
        }
        for sourceDir in directories {
            try Task.checkCancellation()
            let targetDir = destination(sourceDir)
            for child in try fm.contentsOfDirectory(at: sourceDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                let target = targetDir.appendingPathComponent(child.lastPathComponent)
                if (try? fm.attributesOfItem(atPath: target.path)) != nil { continue }
                let canonical = child.manuscriptURL
                let known = inputs.contains(canonical) || directories.contains(canonical)
                try fm.createSymbolicLink(at: target, withDestinationURL: known ? destination(canonical) : child)
            }
        }
        return destination(index.root)
    }
}
