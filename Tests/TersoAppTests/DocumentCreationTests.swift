// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import Testing
import TersoDocument
@testable import TersoApp

@Suite(.serialized) @MainActor struct DocumentCreationTests {
    private func expectedTitle(_ template: WritingTemplate) -> String {
        switch template {
        case .book: "Untitled Book"
        case .essay: "Untitled Essay"
        case .shortStory: "Untitled Story"
        case .novel: "Untitled Novel"
        case .researchPaper: "Untitled Paper"
        case .report: "Untitled Report"
        }
    }

    private func expectedHeadings(_ template: WritingTemplate) -> [String] {
        switch template {
        case .book, .novel: ["Chapter 1"]
        case .essay: ["Introduction", "Argument", "Conclusion"]
        case .shortStory: []
        case .researchPaper: ["Abstract", "Introduction", "Methods", "Results", "Discussion", "References"]
        case .report: ["Summary", "Background", "Findings", "Recommendations"]
        }
    }

    @Test(arguments: WritingTemplate.allCases, TemplateSourceFormat.allCases)
    func templatesHavePortableSourceAndAnEmptyBody(template: WritingTemplate, format: TemplateSourceFormat) throws {
        let defaults = Preferences.shared.bookDesign
        let document = DocumentCreationRequest.template(template, format).makeDocument()
        defer { document.close() }
        let text = document.contents.text
        let caret = try #require(document.model.initialSelection)
        let source = text as NSString
        #expect(document.fileType == format.contentType.identifier)
        #expect(document.fileURL == nil)
        #expect(document.contents.codec == PlainTextCodec())
        let data = try document.data(ofType: format.contentType.identifier)
        #expect(format == .terso ? try TersoPackage.decode(data).text == text : data == Data(text.utf8))
        #expect(document.isDocumentEdited)
        #expect(document.model.renderMode == .mixed)
        #expect(document.model.writingMode == (template.isBook ? .manutius : .hemingway))
        #expect(document.model.showSidebar == template.isBook)
        #expect(Preferences.shared.bookDesign == defaults)
        #expect(caret.length == 0 && caret.location <= source.length)
        #expect(source.substring(to: caret.location).hasSuffix("\n\n"))
        if caret.location < source.length { #expect(source.substring(from: caret.location).hasPrefix("\n")) }

        let headings = expectedHeadings(template)
        switch format {
        case .markdown, .terso:
            #expect(BookMetadata.read(text).title == expectedTitle(template))
            #expect(text.contains("author: \"\"\n"))
            #expect(text.components(separatedBy: "\n").filter { $0.hasPrefix("# ") } == headings.map { "# \($0)" })
            let metadataEnd = source.range(of: "\n---\n").upperBound
            #expect(caret.location > metadataEnd)
            if let first = headings.first {
                #expect(source.substring(to: caret.location).hasSuffix("# \(first)\n\n"))
            }
            #expect(BookDesign.read(from: text, defaults: BookDesign()) == (template.isBook ? defaults : nil))
        case .latex:
            let documentClass = template.isBook ? "book" : template == .report ? "report" : "article"
            #expect(text.hasPrefix("\\documentclass{\(documentClass)}\n"))
            #expect(text.contains("\\title{\(expectedTitle(template))}\n\\author{}\n\\date{}"))
            #expect(text.contains("\\begin{document}\n\\maketitle\n"))
            #expect(text.hasSuffix("\\end{document}\n"))
            #expect(caret.location > source.range(of: "\\maketitle").upperBound)
            #expect(caret.location < source.range(of: "\\end{document}").location)
            if template == .researchPaper {
                #expect(source.substring(to: caret.location).hasSuffix("\\begin{abstract}\n\n"))
                #expect(source.substring(from: caret.location).hasPrefix("\n\\end{abstract}"))
            }
            let command = template.isBook || template == .report ? "chapter" : "section"
            let sectionHeadings = template == .researchPaper ? Array(headings.dropFirst()) : headings
            #expect(text.components(separatedBy: "\n").filter { $0.hasPrefix("\\\(command){") }
                == sectionHeadings.map { "\\\(command){\($0)}" })
            #expect(BookDesign.read(latex: text, defaults: defaults) == (template.isBook ? defaults : nil))
            #expect(text.contains("{terso-book}") == template.isBook)
        }
    }

    @Test(arguments: WritingTemplate.allCases, TemplateSourceFormat.allCases)
    func firstTypingAndUndoStayInTheNewDocument(template: WritingTemplate, format: TemplateSourceFormat) async throws {
        _ = NSApplication.shared
        let defaults = Preferences.shared.bookDesign
        let document = DocumentCreationRequest.template(template, format).makeDocument()
        let other = TabDocument(), workspace = TabWorkspace()
        defer { document.close(); other.close(); workspace.close() }
        other.contents.text = "Existing document."
        other.model.documentWordTarget = 321
        let scaffold = document.contents.text
        let caret = try #require(document.model.initialSelection)
        workspace.insert(document)
        let host = document.hostedEditor()
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        host.layoutSubtreeIfNeeded()
        let deadline = ContinuousClock.now + .seconds(3)
        while document.model.editor == nil && ContinuousClock.now < deadline { await Task.yield() }
        let editor = try #require(document.model.editor)
        #expect(editor.selection.nsRange == caret)
        #expect(document.model.initialSelection == nil)
        #expect(document.model.documentWordTarget == (template.isBook ? defaults.wordGoal : nil))
        let undo = try #require(document.undoManager)
        undo.beginUndoGrouping()
        editor.replace(editor.selection, with: "First words 🖋️.", actionName: "Test typing")
        undo.endUndoGrouping()
        try await Task.sleep(for: .milliseconds(50))
        let edited = (scaffold as NSString).replacingCharacters(in: caret, with: "First words 🖋️.")
        #expect(document.contents.text == edited)
        workspace.insert(other)
        undo.undo()
        #expect(document.contents.text == scaffold)
        #expect(document.isDocumentEdited)
        #expect(other.contents.text == "Existing document.")
        #expect(other.model.documentWordTarget == 321)
        undo.redo()
        try await Task.sleep(for: .milliseconds(50))
        #expect(document.contents.text == edited)
        #expect(Preferences.shared.bookDesign == defaults)
    }

    @Test(arguments: [WritingTemplate.book, .novel], TemplateSourceFormat.allCases)
    func bookRecoveryKeepsTheSelectedFormatAndFirstWords(template: WritingTemplate, format: TemplateSourceFormat) throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recoveryURL = directory.appendingPathComponent("tabs.json")
        let original = DocumentTabs(recoveryURL: recoveryURL)
        original.isRunning = true
        let workspace = original.newWorkspace()
        let document = DocumentCreationRequest.template(template, format).makeDocument()
        let caret = try #require(document.model.initialSelection)
        document.contents.text = (document.contents.text as NSString).replacingCharacters(in: caret, with: "Recovered first words.")
        workspace.insert(document)
        let expectedText = document.contents.text
        original.saveRecovery()
        document.close(); workspace.close()

        let restored = DocumentTabs(recoveryURL: recoveryURL)
        restored.restore()
        defer {
            for group in restored.workspaces {
                for document in group.documents {
                    TabDocumentController.sharedController.removeDocument(document)
                    document.close()
                }
                group.close()
            }
        }
        #expect(restored.workspaces.count == 1)
        let group = try #require(restored.workspaces.first)
        #expect(group.documents.count == 1)
        let recovered = try #require(group.documents.first)
        #expect(group.selected === recovered)
        #expect(recovered.contents.text == expectedText)
        let data = try recovered.data(ofType: format.contentType.identifier)
        #expect(format == .terso ? try TersoPackage.decode(data).text == expectedText : data == Data(expectedText.utf8))
        #expect(recovered.fileType == format.contentType.identifier)
        #expect(recovered.fileURL == nil)
        #expect(recovered.model.writingMode == .manutius)
        #expect(recovered.isDocumentEdited)
    }

    @Test func bookAndNovelUseTheSameCreator() {
        for format in TemplateSourceFormat.allCases {
            let book = DocumentCreationRequest.template(.book, format).makeDocument()
            let novel = DocumentCreationRequest.template(.novel, format).makeDocument()
            defer { book.close(); novel.close() }
            #expect(book.contents.text.replacingOccurrences(of: "Untitled Book", with: "Untitled Novel") == novel.contents.text)
            #expect(book.model.initialSelection?.location == novel.model.initialSelection.map { $0.location - 1 })
            #expect(book.model.writingMode == novel.model.writingMode)
        }
    }
}
