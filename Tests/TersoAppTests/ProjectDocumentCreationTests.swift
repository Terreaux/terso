// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import Testing
import TersoDocument
@testable import TersoApp

@Suite(.serialized) @MainActor struct ProjectDocumentCreationTests {
    @Test(arguments: NewDocumentKind.allCases)
    func savesAndLinksOnlyToTheChosenProject(kind: NewDocumentKind) async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("Projects.json")
        let store = ProjectStore(fileURL: storeURL)
        let project = store.create(named: "Chosen"), other = store.create(named: "Other")
        let document = kind.makeDocument()
        defer { document.close() }
        let text = document.contents.text
        let url = directory.appendingPathComponent("Draft.\(kind.fileExtension)")
        try await ProjectDocumentCreation.save(document, to: url, in: project.id, store: store)
        let saved = kind == .terso ? try TersoPackage.decode(Data(contentsOf: url)).text : try String(contentsOf: url, encoding: .utf8)
        #expect(saved == text)
        #expect(document.fileURL == url)
        #expect(!document.isDocumentEdited)
        #expect(store.contains(url, in: project.id))
        #expect(!store.contains(url, in: other.id))
        let reloaded = ProjectStore(fileURL: storeURL)
        #expect(reloaded.contains(url, in: project.id))
        #expect(ProjectDocumentCreation.suggestedDirectory(for: try #require(reloaded.projects.first))?.path == directory.path)
    }

    @Test func failedSaveDoesNotCreateAProjectLink() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProjectStore(fileURL: directory.appendingPathComponent("Projects.json"))
        let project = store.create(named: "Chosen")
        let document = NewDocumentKind.markdown.makeDocument()
        defer { document.close() }
        // A regular file cannot be the parent directory of a new document.
        let url = directory.appendingPathComponent("Projects.json/Draft.md")
        do {
            try await ProjectDocumentCreation.save(document, to: url, in: project.id, store: store)
            Issue.record("Saving inside a file unexpectedly succeeded")
        } catch {
            #expect(store.projects.first?.documents.isEmpty == true)
            #expect(ProjectDocumentCreation.suggestedDirectory(for: project) == nil)
        }
    }
}
