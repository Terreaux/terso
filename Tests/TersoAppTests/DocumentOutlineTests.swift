// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import Testing
import TersoCore
@testable import TersoApp

struct DocumentOutlineTests {
    @Test func childrenStayInsideTheChosenChapterAndSection() throws {
        let text = "# One\n\nText 😀.\n\n## Existing\n\n### Nested\n\nBody.\n\n## Sibling\n\n# Two\n\nOther.\n"
        let outline = DocumentOutline(source: text, latex: false, book: true)
        let chapter = try #require(outline.insertion(under: outline.headings[0]))
        #expect(chapter.location == (text as NSString).range(of: "# Two").location)
        #expect(chapter.text == "## Section 3\n\n")
        let section = try #require(outline.insertion(under: outline.headings[1]))
        #expect(section.location == (text as NSString).range(of: "## Sibling").location)
        #expect(section.text == "### Subsection 2\n\n")
        #expect((chapter.text as NSString).substring(with: NSRange(location: 3, length: chapter.selection.length)) == "Section 3")
    }

    @Test func ignoresMetadataCodeAndCommentHeadings() throws {
        let text = "---\ntitle: Example\n# Metadata\n---\n# Real\n\n```md\n# Fake\n## Fake too\n```\n\n<!--\n# Hidden\n-->\n\n# Next\n"
        let outline = DocumentOutline(source: text, latex: false, book: true)
        #expect(outline.headings.map(\.title) == ["Real", "Next"])
        let edit = try #require(outline.insertion(under: outline.headings[0]))
        #expect(edit.text == "## Section 1\n\n")
        #expect(edit.location == (text as NSString).range(of: "# Next").location)
    }

    @Test func preservesCRLFAndUTF16TitleSelection() throws {
        let text = "# Café 😀\r\n\r\nBody."
        let outline = DocumentOutline(source: text, latex: false, book: true)
        let edit = try #require(outline.insertion(under: outline.headings[0]))
        let result = (text as NSString).replacingCharacters(in: NSRange(location: edit.location, length: 0), with: edit.text) as NSString
        #expect(edit.text == "\r\n\r\n## Section 1\r\n\r\n")
        #expect(result.substring(with: edit.selection) == "Section 1")
    }

    @Test(arguments: ["article", "book", "report", "memoir", "scrbook", "scrreprt"])
    func emptyLaTeXDocumentsChooseValidRootCommands(documentClass: String) throws {
        let text = "\\documentclass[12pt]{\(documentClass)}\n\\begin{document}\n\n\\end{document}\n"
        let outline = DocumentOutline(source: text, latex: true, book: true)
        let edit = try #require(outline.insertion())
        let command = documentClass == "article" ? "section" : "chapter"
        #expect(edit.text.hasPrefix("\\\(command){"))
        #expect(edit.location == (text as NSString).range(of: "\\end{document}").location)
    }

    @Test func latexKeepsNativeLevelsWhenIntermediateCommandsAreMissing() throws {
        let text = "\\documentclass{book}\n\\begin{document}\n\\part{First}\n\\chapter{One}\n\\subsection*{Deep}\nText.\n% \\chapter{Fake}\n\\begin{verbatim}\n\\chapter{Fake too}\n\\end{verbatim}\n\\chapter{Two}\n\\end{document}\n\\chapter{Ignored}\n"
        let outline = DocumentOutline(source: text, latex: true, book: true)
        #expect(outline.headings.map(\.title) == ["First", "One", "Deep", "Two"])
        #expect(outline.headings.map(\.level) == [0, 1, 3, 1])
        let edit = try #require(outline.insertion(under: outline.headings[1]))
        #expect(edit.text == "\n\\section{Section 1}\n\n")
        #expect(edit.location == (text as NSString).range(of: "\\chapter{Two}").location)
        let deep = try #require(outline.insertion(under: outline.headings[2]))
        #expect(deep.text.contains("\\subsubsection{Subsubsection 1}"))
    }

    @Test func plainTextUsesReadableHeadingMarkersAndLimitsDepth() throws {
        let outline = DocumentOutline(source: "Notes", latex: false, book: false)
        #expect(try #require(outline.insertion()).text == "\n\n# Section 1\n\n")
        let deep = DocumentOutline(source: "###### Last\n", latex: false, book: false)
        #expect(deep.insertion(under: deep.headings[0]) == nil)
        #expect(deep.insertion(under: DocumentOutline(source: "# Gone\n", latex: false, book: false).headings[0]) == nil)
    }

    @Test func articlePartsAddSectionsInsteadOfUnsupportedChapters() throws {
        let source = "\\documentclass{article}\n\\begin{document}\n\\part{First}\n\\section{One}\n\\part{Second}\n\\end{document}\n"
        let outline = DocumentOutline(source: source, latex: true, book: true)
        let edit = try #require(outline.insertion(under: outline.headings[0]))
        #expect(outline.insertionLevel(under: outline.headings[0]) == 2)
        #expect(edit.text == "\n\\section{Section 2}\n\n")
        #expect(edit.location == (source as NSString).range(of: "\\part{Second}").location)
    }

    @Test func headingScanSkipsDisplayMathAndIndentedCode() {
        let source = "# Real\n\n$$\n## Math\n$$\n\n    ## Code\n\n  ## Child\n"
        let outline = DocumentOutline(source: source, latex: false, book: true)
        #expect(outline.headings.map(\.title) == ["Real", "Child"])
    }
}

@Suite(.serialized) @MainActor struct OutlineEditorTests {
    @Test(arguments: NewDocumentKind.allCases)
    func insertionIsOneUndoableEditInItsOwnDocument(kind: NewDocumentKind) async throws {
        _ = NSApplication.shared
        let document = kind.makeDocument(), other = TabDocument(), workspace = TabWorkspace()
        defer { document.close(); other.close(); workspace.close() }
        document.contents.text = kind == .latex
            ? "\\documentclass{article}\n\\begin{document}\n\\section{One}\n\nText.\n\n\\section{Two}\n\\end{document}\n"
            : "# One\n\nText.\n\n# Two\n"
        let original = document.contents.text
        other.contents.text = "Untouched."
        workspace.insert(document)
        let host = document.hostedEditor()
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        host.layoutSubtreeIfNeeded()
        let deadline = ContinuousClock.now + .seconds(3)
        while document.model.editor == nil && ContinuousClock.now < deadline { await Task.yield() }
        let editor = try #require(document.model.editor as? EditorCoordinator)
        let undo = try #require(document.undoManager)
        let outline = document.model.documentOutline
        let parent = try #require(outline.headings.first)
        let edit = try #require(outline.insertion(under: parent))
        undo.beginUndoGrouping()
        editor.addHeading(under: parent)
        undo.endUndoGrouping()
        try await eventually { document.isDocumentEdited && document.model.documentOutline.headings.count == 3 }
        #expect(document.contents.text == (original as NSString).replacingCharacters(in: NSRange(location: edit.location, length: 0), with: edit.text))
        #expect(editor.selection.nsRange == edit.selection)
        undo.undo()
        try await eventually { document.model.documentOutline.headings.count == 2 }
        #expect(document.contents.text == original)
        undo.redo()
        try await eventually { document.model.documentOutline.headings.count == 3 }
        #expect(document.contents.text.contains("Subsection 1"))
        #expect(other.contents.text == "Untouched.")
    }

    /// NSDocument counts the change after the undo group closes, and the
    /// outline reads the model's current editor, which SwiftUI may rebuild
    /// while other suites drive the main actor. Wait for both, not a delay.
    private func eventually(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            if ContinuousClock.now >= deadline { Issue.record("Timed out waiting for the outline"); return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
