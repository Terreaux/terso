// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import TersoApp

@Suite(.serialized) @MainActor struct ProjectStoreTests {
    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("terso-projects-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func file(_ name: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try "# \(name)\n".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func projectsPersistAndLinkEachDocumentOnce() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = dir.appendingPathComponent("Projects.json")
        let a = try file("a.md", in: dir), b = try file("b.md", in: dir)

        let projects = ProjectStore(fileURL: store)
        let p = projects.create(named: "  Thesis  ", with: [a, a])
        projects.add([a, b], to: p.id)
        #expect(projects.projects.first?.name == "Thesis")
        #expect(projects.projects.first?.documents.map(\.title) == ["a", "b"])

        let reloaded = ProjectStore(fileURL: store)
        #expect(reloaded.projects == projects.projects)
        #expect(reloaded.contains(b, in: p.id))

        let docB = try #require(reloaded.projects.first?.documents.last)
        reloaded.remove(docB.id, from: p.id)
        reloaded.rename(p.id, to: "")
        #expect(reloaded.projects.first?.name == "Thesis")
        #expect(!reloaded.contains(b, in: p.id))
        reloaded.delete(p.id)
        #expect(ProjectStore(fileURL: store).projects.isEmpty)
    }

    @Test func linkedDocumentFollowsARename() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = try file("draft.md", in: dir)
        let doc = ProjectDocument(url: original)
        let renamed = dir.appendingPathComponent("final.md")
        try FileManager.default.moveItem(at: original, to: renamed)
        #expect(doc.exists)
        #expect(doc.title == "final")
    }

    @Test func recentDocumentsAreNewestFirstWithoutDuplicates() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let suite = "terso-recents-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = try file("a.md", in: dir), b = try file("b.md", in: dir)
        let gone = dir.appendingPathComponent("gone.md")

        let recents = RecentDocuments(defaults: defaults)
        recents.note(a); recents.note(gone); recents.note(b); recents.note(a)
        #expect(Array(recents.urls(limit: 10).prefix(2)) == [a, b].map(\.standardizedFileURL))
        #expect(!recents.urls(limit: 10).contains(gone.standardizedFileURL))
        #expect(RecentDocuments(defaults: defaults).paths.first == a.standardizedFileURL.path)
    }
}
