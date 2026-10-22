// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import TersoDocument
import UniformTypeIdentifiers

extension UTType {
    static let wordDocument = UTType(importedAs: "org.openxmlformats.wordprocessingml.document", conformingTo: .data)
}

/// Brings a `.docx` in as a new, untitled Markdown document. One way only:
/// Terso never writes back to the Word file, so the original stays as it was.
/// Google Docs files arrive the same way, through File → Download → .docx.
@MainActor
enum WordImport {
    static func markdown(fromDocx data: Data) throws -> String {
        let attributed = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML],
                                                documentAttributes: nil)
        // AppKit ignores Word's styles; without them the text still comes in.
        guard let structure = try? WordStructure(docx: data) else { return WordMarkdown.markdown(from: attributed) }
        return WordMarkdown.markdown(from: WordMarkdown.annotate(attributed, with: structure))
    }

    static func makeDocument(markdown: String) -> TabDocument {
        let document = NewDocumentKind.markdown.makeDocument()
        document.contents.text = markdown
        if !markdown.isEmpty { document.updateChangeCount(.changeDone) }
        return document
    }

    static func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.wordDocument]
        panel.allowsMultipleSelection = true
        panel.message = "Each Word document opens as a new Markdown document."
        panel.prompt = "Import"
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls { importFile(at: url) }
        }
    }

    static func importFile(at url: URL) {
        do {
            let document = makeDocument(markdown: try markdown(fromDocx: try Data(contentsOf: url)))
            TabDocumentController.sharedController.addDocument(document)
            DocumentTabs.shared.present(document)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "“\(url.lastPathComponent)” couldn’t be imported."
            alert.informativeText = "Terso can import Word documents saved as .docx."
            alert.runModal()
        }
    }
}
