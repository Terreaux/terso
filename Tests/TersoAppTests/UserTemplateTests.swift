// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
import TersoDocument
import UniformTypeIdentifiers
@testable import TersoApp

@Suite(.serialized) @MainActor struct UserTemplateTests {
    private func storeURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("terso-templates-\(UUID().uuidString)/Templates.json")
    }

    @Test func templatesPersistAndASameNamedSaveReplaces() throws {
        let url = storeURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = UserTemplateStore(fileURL: url)
        let first = store.save(named: "  Lab Notes ", kind: .markdown, text: "# Notes\n")
        store.save(named: "", kind: .text, text: "plain")
        store.save(named: "lab notes", kind: .latex, text: "\\section{Notes}\n")

        let reloaded = UserTemplateStore(fileURL: url)
        #expect(reloaded.templates.map(\.name) == ["Lab Notes", "Untitled Template"])
        #expect(reloaded.templates.first?.id == first.id)
        #expect(reloaded.templates.first?.kind == .latex)
        #expect(reloaded.templates.first?.text == "\\section{Notes}\n")

        reloaded.delete(first.id)
        #expect(UserTemplateStore(fileURL: url).templates.map(\.name) == ["Untitled Template"])
    }

    @Test func onlyCreatableFormatsCanBeSaved() {
        #expect(UserTemplate.kind(forFileType: UTType.markdownText.identifier) == .markdown)
        #expect(UserTemplate.kind(forFileType: UTType.tersoDocument.identifier) == .terso)
        #expect(UserTemplate.kind(forFileType: UTType.latexSource.identifier) == .latex)
        #expect(UserTemplate.kind(forFileType: UTType.plainText.identifier) == .text)
        #expect(UserTemplate.kind(forFileType: UTType.pdf.identifier) == nil)
        #expect(UserTemplate.kind(forFileType: nil) == nil)
    }

    @Test(arguments: NewDocumentKind.allCases)
    func savedTemplatesOpenAsUntitledDocumentsInTheirFormat(kind: NewDocumentKind) throws {
        let text = "# Weekly Review\n\n## Wins\n\n"
        let document = DocumentCreationRequest.saved(UserTemplate(name: "Weekly", kind: kind, text: text)).makeDocument()
        defer { document.close() }
        #expect(document.fileType == kind.contentType.identifier)
        #expect(document.fileURL == nil)
        #expect(document.contents.text == text)
        #expect(document.isDocumentEdited)
        #expect(document.model.renderMode == (kind == .text ? .source : .mixed))
        let data = try document.data(ofType: kind.contentType.identifier)
        #expect(kind == .terso ? try TersoPackage.decode(data).text == text : data == Data(text.utf8))
    }

    @Test func aSavedBookTemplateOpensInBookMode() {
        let book = DocumentCreationRequest.template(.book, .markdown).makeDocument()
        let text = book.contents.text
        book.close()
        let document = UserTemplate(name: "My Book", kind: .markdown, text: text).makeDocument()
        defer { document.close() }
        #expect(document.model.writingMode == .manutius)
        #expect(document.model.showSidebar)
    }
}
