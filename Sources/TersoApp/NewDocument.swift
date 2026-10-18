// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import TersoDocument
import UniformTypeIdentifiers

/// Blank documents describe a source format; writing templates describe a task.
enum NewDocumentKind: String, CaseIterable, Identifiable {
    case markdown, latex, text
    var id: Self { self }

    var title: String {
        switch self {
        case .markdown: "Markdown"
        case .latex: "LaTeX"
        case .text: "Plain Text"
        }
    }

    var detail: String {
        switch self {
        case .markdown: "Headings, links and formatted writing · .md"
        case .latex: "A document ready for equations and typesetting · .tex"
        case .text: "A blank page for plain text · .txt"
        }
    }

    var symbol: String {
        switch self {
        case .markdown: "doc.richtext"
        case .latex: "function"
        case .text: "doc.plaintext"
        }
    }

    var contentType: UTType {
        switch self {
        case .markdown: .markdownText
        case .latex: .latexSource
        case .text: .plainText
        }
    }

    var fileExtension: String {
        switch self {
        case .markdown: "md"
        case .latex: "tex"
        case .text: "txt"
        }
    }

    @MainActor func makeDocument() -> TabDocument {
        let document = TabDocument()
        document.fileType = contentType.identifier
        document.contents.codec = PlainTextCodec()
        switch self {
        case .markdown: break
        case .text: document.model.renderMode = .source
        case .latex:
            let opening = "\\documentclass{article}\n\n\\begin{document}\n\n"
            document.contents.text = opening + "\n\\end{document}\n"
            document.model.initialSelection = NSRange(location: opening.utf16.count, length: 0)
        }
        if !document.contents.text.isEmpty { document.updateChangeCount(.changeDone) }
        return document
    }
}

enum WritingTemplate: String, CaseIterable, Identifiable {
    case book, essay, shortStory, novel, researchPaper, report
    var id: Self { self }
    static let starters: [Self] = [.essay, .shortStory, .novel, .researchPaper, .report]

    var title: String {
        switch self {
        case .book: "Book"
        case .essay: "Essay"
        case .shortStory: "Short Story"
        case .novel: "Novel"
        case .researchPaper: "Research Paper"
        case .report: "Report"
        }
    }

    var detail: String {
        switch self {
        case .book: "Start your first chapter with a book design"
        case .essay: "Introduction, argument and conclusion"
        case .shortStory: "A title and an open page for your story"
        case .novel: "A first chapter with a book design"
        case .researchPaper: "Abstract, methods, results and references"
        case .report: "Summary, background, findings and recommendations"
        }
    }

    var symbol: String {
        switch self {
        case .book: "book.pages"
        case .essay: "text.alignleft"
        case .shortStory: "pencil.line"
        case .novel: "books.vertical"
        case .researchPaper: "doc.text.magnifyingglass"
        case .report: "doc.text"
        }
    }

    var isBook: Bool { self == .book || self == .novel }

    fileprivate var documentTitle: String {
        switch self {
        case .shortStory: "Untitled Story"
        case .researchPaper: "Untitled Paper"
        default: "Untitled \(title)"
        }
    }

    fileprivate var headings: [String] {
        switch self {
        case .book, .novel: ["Chapter 1"]
        case .essay: ["Introduction", "Argument", "Conclusion"]
        case .shortStory: []
        case .researchPaper: ["Abstract", "Introduction", "Methods", "Results", "Discussion", "References"]
        case .report: ["Summary", "Background", "Findings", "Recommendations"]
        }
    }
}

/// Only formats the current editor can create and save are offered.
enum TemplateSourceFormat: String, CaseIterable, Identifiable {
    case markdown, latex
    var id: Self { self }
    var title: String { self == .markdown ? "Markdown" : "LaTeX" }
    var contentType: UTType { self == .markdown ? .markdownText : .latexSource }
    var fileExtension: String { self == .markdown ? "md" : "tex" }

    func detail(book: Bool) -> String {
        switch (self, book) {
        case (.markdown, true): "Write directly on editable book pages · .md"
        case (.latex, true): "Edit source beside compiled book pages · .tex"
        case (.markdown, false): "Write with Markdown formatting and a live preview · .md"
        case (.latex, false): "Edit LaTeX source with a typeset preview · .tex"
        }
    }
}

enum DocumentCreationRequest {
    case blank(NewDocumentKind)
    case template(WritingTemplate, TemplateSourceFormat)

    @MainActor func makeDocument() -> TabDocument {
        switch self {
        case .blank(let kind): return kind.makeDocument()
        case .template(let template, let format):
            let document = TabDocument()
            let design = document.model.prefs.bookDesign
            let scaffold = TemplateScaffold(template: template, format: format, design: design)
            document.fileType = format.contentType.identifier
            document.contents.codec = PlainTextCodec()
            document.contents.text = scaffold.text
            document.model.initialSelection = scaffold.selection
            if template.isBook {
                document.model.setWritingMode(.manutius)
                document.model.showSidebar = true
            }
            // The scaffold is real unsaved content, so closing and recovery retain it.
            document.updateChangeCount(.changeDone)
            return document
        }
    }
}

/// Build the prefix and trailer separately so the first caret is always in a
/// blank body paragraph, including after preamble edits that change its length.
private struct TemplateScaffold {
    let text: String
    let selection: NSRange

    init(template: WritingTemplate, format: TemplateSourceFormat, design: BookDesign) {
        var opening: String
        let trailer: String
        switch format {
        case .markdown:
            let metadata = ["---", "title: \"\(template.documentTitle)\"", "author: \"\""]
                + (template.isBook ? design.yaml : []) + ["---", "", ""]
            opening = metadata.joined(separator: "\n")
            if let heading = template.headings.first { opening += "# \(heading)\n\n" }
            trailer = template.headings.dropFirst().map { "\n\n# \($0)\n\n" }.joined()
        case .latex:
            let documentClass = template.isBook ? "book" : template == .report ? "report" : "article"
            opening = "\\documentclass{\(documentClass)}\n\n\\title{\(template.documentTitle)}\n\\author{}\n\\date{}\n\n\\begin{document}\n\\maketitle\n\n"
            // Book and Novel share the same design setup and source structure.
            if template.isBook, let edit = LaTeXBookDesign.setupEdit(of: opening, design: design) {
                opening = (opening as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
            }
            let command = template.isBook || template == .report ? "chapter" : "section"
            if template == .researchPaper {
                opening += "\\begin{abstract}\n\n"
                trailer = "\n\\end{abstract}\n\n"
                    + template.headings.dropFirst().map { "\\section{\($0)}\n\n\n" }.joined()
                    + "\\end{document}\n"
            } else {
                if let heading = template.headings.first { opening += "\\\(command){\(heading)}\n\n" }
                trailer = template.headings.dropFirst().map { "\n\n\\\(command){\($0)}\n\n" }.joined()
                    + "\n\\end{document}\n"
            }
        }
        text = opening + trailer
        selection = NSRange(location: opening.utf16.count, length: 0)
    }
}
