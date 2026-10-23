// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import Testing
import TersoDocument
import UniformTypeIdentifiers
@testable import TersoApp

@MainActor struct WordImportTests {
    // MARK: Whole files

    /// `Fixtures/styled.docx` is `pandoc styled.md -o styled.docx`: real Word
    /// styles, numbering and hyperlink relationships, as Word and Google Docs write.
    @Test func styledDocxKeepsItsStructure() throws {
        let url = try #require(Bundle.module.url(forResource: "styled", withExtension: "docx", subdirectory: "Fixtures"))
        let markdown = try WordImport.markdown(fromDocx: Data(contentsOf: url))
        #expect(markdown == """
            # Word Import

            ## Section *Two*

            A paragraph with **bold**, *italic*, ***both***, `code`, ~~gone~~ and a [link](https://example.com/a). Snake_case stays, but 2 \\* 3 and \\[brackets\\] are escaped.

            - first
            - second
              - nested
            - third

            1. one
            2. two

            Between the lists.

            3. three

            > A quoted line.

            ```
            let x = 1

            let y = 2
            ```

            | Name | Value |
            | --- | --- |
            | a | 1 |
            | b | 2 |

            """)
    }

    /// AppKit's own writer has no styles or numbering: sizes, weights and
    /// list markers typed out as text are all that is left to read.
    @Test func directFormattingDocxStillReads() throws {
        let attributed = try html("<h1>Title</h1><p>Body <b>bold</b>.</p><ol><li>one</li><li>two<ul><li>inner</li></ul></li></ol>")
        let data = try attributed.data(from: NSRange(location: 0, length: attributed.length),
                                       documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
        #expect(try WordImport.markdown(fromDocx: data) == """
            # Title

            Body **bold**.

            1. one
            2. two
               - inner

            """)
    }

    @Test func notADocxIsAnError() {
        #expect(throws: (any Error).self) { try WordImport.markdown(fromDocx: Data("plain".utf8)) }
    }

    @Test func importOpensAnEditedUntitledMarkdownDocument() throws {
        let document = WordImport.makeDocument(markdown: "# Imported\n")
        defer { document.close() }
        #expect(document.fileURL == nil)
        #expect(document.fileType == UTType.markdownText.identifier)
        #expect(document.contents.text == "# Imported\n")
        #expect(document.isDocumentEdited)
    }

    // MARK: WordprocessingML

    private func document(_ body: String) -> Data {
        Data("""
            <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
              xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><w:body>\(body)</w:body></w:document>
            """.utf8)
    }

    @Test func stylesResolveThroughBasedOnAndOutlineLevels() throws {
        let styles = Data("""
            <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
              <w:style w:type="paragraph" w:styleId="H2"><w:name w:val="heading 2"/></w:style>
              <w:style w:type="paragraph" w:styleId="Mine"><w:name w:val="My Section"/><w:basedOn w:val="H2"/></w:style>
              <w:style w:type="paragraph" w:styleId="Outline"><w:name w:val="Part"/><w:pPr><w:outlineLvl w:val="0"/></w:pPr></w:style>
              <w:style w:type="paragraph" w:styleId="Quote"><w:name w:val="Intense Quote"/></w:style>
              <w:style w:type="character" w:styleId="Code"><w:name w:val="Inline Code"/></w:style>
            </w:styles>
            """.utf8)
        let structure = try WordStructure(document: document("""
            <w:p><w:pPr><w:pStyle w:val="Mine"/></w:pPr><w:r><w:t>Based on</w:t></w:r></w:p>
            <w:p><w:pPr><w:pStyle w:val="Outline"/></w:pPr><w:r><w:t>Outline</w:t></w:r></w:p>
            <w:p><w:pPr><w:outlineLvl w:val="2"/></w:pPr><w:r><w:t>Direct</w:t></w:r></w:p>
            <w:p><w:pPr><w:pStyle w:val="Quote"/></w:pPr><w:r><w:t>Said</w:t></w:r></w:p>
            <w:p><w:r><w:t xml:space="preserve">run </w:t></w:r><w:r><w:rPr><w:rStyle w:val="Code"/></w:rPr><w:t>x</w:t></w:r><w:r><w:rPr><w:rFonts w:ascii="Courier New"/></w:rPr><w:t>y</w:t></w:r></w:p>
            """), styles: styles)
        #expect(structure.paragraphs.map(\.role) == [.heading(2), .heading(1), .heading(3), .quote, .body])
        #expect(structure.paragraphs[4].text == "run xy")
        // Adjacent code runs merge into one span.
        #expect(structure.paragraphs[4].code == [NSRange(location: 4, length: 2)])
    }

    @Test func numberingGivesKindLevelAndStart() throws {
        let numbering = Data("""
            <w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
              <w:abstractNum w:abstractNumId="1"><w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="decimal"/></w:lvl>
                <w:lvl w:ilvl="1"><w:numFmt w:val="bullet"/></w:lvl></w:abstractNum>
              <w:num w:numId="5"><w:abstractNumId w:val="1"/></w:num>
              <w:num w:numId="6"><w:abstractNumId w:val="1"/><w:lvlOverride w:ilvl="0"><w:startOverride w:val="4"/></w:lvlOverride></w:num>
            </w:numbering>
            """.utf8)
        let structure = try WordStructure(document: document("""
            <w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="5"/></w:numPr></w:pPr><w:r><w:t>a</w:t></w:r></w:p>
            <w:p><w:pPr><w:numPr><w:ilvl w:val="1"/><w:numId w:val="5"/></w:numPr></w:pPr><w:r><w:t>b</w:t></w:r></w:p>
            <w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="6"/></w:numPr></w:pPr><w:r><w:t>c</w:t></w:r></w:p>
            <w:p><w:pPr><w:numPr><w:numId w:val="0"/></w:numPr></w:pPr><w:r><w:t>d</w:t></w:r></w:p>
            """), numbering: numbering)
        #expect(structure.paragraphs.map(\.list) == [
            WordStructure.List(id: "5", level: 0, ordered: true, start: 1),
            WordStructure.List(id: "5", level: 1, ordered: false, start: 1),
            WordStructure.List(id: "6", level: 0, ordered: true, start: 4),
            nil,
        ])
    }

    @Test func hyperlinksComeFromRelationshipsAndFields() throws {
        let relationships = Data("""
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
              <Relationship Id="rId9" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink"
                Target="https://example.com/rel" TargetMode="External"/>
            </Relationships>
            """.utf8)
        let structure = try WordStructure(document: document("""
            <w:p><w:r><w:t xml:space="preserve">See </w:t></w:r><w:hyperlink r:id="rId9"><w:r><w:t>this</w:t></w:r></w:hyperlink>
              <w:r><w:t xml:space="preserve"> and </w:t></w:r>
              <w:r><w:fldChar w:fldCharType="begin"/></w:r><w:r><w:instrText xml:space="preserve"> HYPERLINK "https://example.com/field" </w:instrText></w:r>
              <w:r><w:fldChar w:fldCharType="separate"/></w:r><w:r><w:t>that</w:t></w:r><w:r><w:fldChar w:fldCharType="end"/></w:r>
              <w:hyperlink w:anchor="_Toc1"><w:r><w:t xml:space="preserve"> here</w:t></w:r></w:hyperlink></w:p>
            """), relationships: relationships)
        let paragraph = try #require(structure.paragraphs.first)
        #expect(paragraph.text == "See this and that here")
        #expect(paragraph.links == [
            WordStructure.Link(range: NSRange(location: 4, length: 4), url: "https://example.com/rel"),
            WordStructure.Link(range: NSRange(location: 13, length: 4), url: "https://example.com/field"),
        ])
    }

    // MARK: Matching AppKit's paragraphs

    @Test func annotationSurvivesAParagraphAppKitSkipped() throws {
        let attributed = NSAttributedString(string: "Heading\nBody text\n", attributes: [.font: NSFont(name: "Times-Roman", size: 12)!])
        var skipped = WordStructure.Paragraph()
        skipped.text = "Only in a text box"
        var heading = WordStructure.Paragraph()
        heading.role = .heading(2)
        heading.text = "Heading"
        var body = WordStructure.Paragraph()
        body.text = "Body text"
        body.links = [WordStructure.Link(range: NSRange(location: 5, length: 4), url: "https://example.com")]
        let structure = WordStructure(paragraphs: [skipped, heading, body])
        #expect(WordMarkdown.markdown(from: WordMarkdown.annotate(attributed, with: structure)) == """
            ## Heading

            Body [text](https://example.com)

            """)
    }

    // MARK: Inline Markdown

    private func runs(_ parts: [(String, NSFont.Weight?, Bool)], size: CGFloat = 12) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (text, weight, italic) in parts {
            var font = NSFont.systemFont(ofSize: size, weight: weight ?? .regular)
            if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            result.append(NSAttributedString(string: text, attributes: [.font: font]))
        }
        return result
    }

    @Test func emphasisMarkersHugTheTextNotItsSpaces() {
        let text = runs([("Plain ", nil, false), ("bold ", .bold, false), ("both", .bold, true), (" plain", nil, false)])
        #expect(WordMarkdown.markdown(from: text) == "Plain **bold *both*** plain\n")
    }

    @Test func syntaxCharactersAreEscaped() {
        let lines = ["# not a heading", "1. not a list", "- nor this", "> nor a quote", "a * b, [c], <d>, `e`, snake_case, _f_"]
        let text = NSAttributedString(string: lines.joined(separator: "\n\n"), attributes: [.font: NSFont.systemFont(ofSize: 12)])
        #expect(WordMarkdown.markdown(from: text) == """
            \\# not a heading

            1\\. not a list

            \\- nor this

            \\> nor a quote

            a \\* b, \\[c\\], \\<d>, \\`e\\`, snake_case, \\_f\\_

            """)
    }

    @Test func codeSpansAndBlocksFollowMonospacedRuns() {
        let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), body = NSFont.systemFont(ofSize: 12)
        let text = NSMutableAttributedString(string: "Run ", attributes: [.font: body])
        text.append(NSAttributedString(string: "a`b", attributes: [.font: mono]))
        text.append(NSAttributedString(string: " here, and a long paragraph of body text to outweigh the code.\n", attributes: [.font: body]))
        text.append(NSAttributedString(string: "let x = \"```\"\n", attributes: [.font: mono]))
        #expect(WordMarkdown.markdown(from: text) == """
            Run ``a`b`` here, and a long paragraph of body text to outweigh the code.

            ````
            let x = "```"
            ````

            """)
    }

    /// A manuscript set entirely in Courier is prose, not one long code block.
    @Test func aMonospacedBodyStaysProse() {
        let text = NSAttributedString(string: "Chapter one.\n\nIt was a dark night.\n", attributes: [.font: NSFont(name: "Courier", size: 12)!])
        #expect(WordMarkdown.markdown(from: text) == "Chapter one.\n\nIt was a dark night.\n")
    }

    @Test func largerUniformSizesBecomeHeadingLevels() {
        let text = NSMutableAttributedString()
        for (line, size) in [("Big", 24.0), ("Medium", 18.0), ("Body text that is long enough to set the body size.", 12.0), ("Medium again", 18.0)] {
            text.append(NSAttributedString(string: line + "\n", attributes: [.font: NSFont.systemFont(ofSize: size)]))
        }
        #expect(WordMarkdown.markdown(from: text) == """
            # Big

            ## Medium

            Body text that is long enough to set the body size.

            ## Medium again

            """)
    }

    @Test func lineBreaksStayInsideTheirParagraph() {
        let text = NSAttributedString(string: "First line\u{2028}second line\n", attributes: [.font: NSFont.systemFont(ofSize: 12)])
        #expect(WordMarkdown.markdown(from: text) == "First line\\\nsecond line\n")
    }

    private func html(_ body: String) throws -> NSAttributedString {
        try NSAttributedString(data: Data("<!doctype html><html><head><meta charset=\"utf-8\"></head><body>\(body)</body></html>".utf8),
                               options: [.documentType: NSAttributedString.DocumentType.html,
                                         .characterEncoding: String.Encoding.utf8.rawValue],
                               documentAttributes: nil)
    }
}
