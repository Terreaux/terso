// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum NewDocumentKind: String, CaseIterable, Identifiable {
    case markdown, latex, text, book
    var id: Self { self }

    var title: String {
        switch self {
        case .markdown: "Markdown"
        case .latex: "LaTeX"
        case .text: "Plain Text"
        case .book: "Book"
        }
    }

    var detail: String {
        switch self {
        case .markdown: "Headings, links and formatted writing · .md"
        case .latex: "A document ready for equations and typesetting · .tex"
        case .text: "A blank page for plain text · .txt"
        case .book: "Start a first chapter on editable book pages · .md"
        }
    }

    var symbol: String {
        switch self {
        case .markdown: "doc.richtext"
        case .latex: "function"
        case .text: "doc.plaintext"
        case .book: "book.pages"
        }
    }

    var contentType: UTType {
        switch self {
        case .markdown, .book: .markdownText
        case .latex: .latexSource
        case .text: .plainText
        }
    }

    @MainActor func makeDocument() -> TabDocument {
        let document = TabDocument()
        document.fileType = contentType.identifier
        switch self {
        case .markdown: break
        case .text: document.model.renderMode = .source
        case .latex:
            let opening = "\\documentclass{article}\n\n\\begin{document}\n\n"
            document.contents.text = opening + "\n\\end{document}\n"
            document.model.initialSelection = NSRange(location: (opening as NSString).length, length: 0)
        case .book:
            document.contents.text = (["---", "title: \"Untitled Book\""]
                + document.model.prefs.bookDesign.yaml + ["---", "", "# Chapter 1", "", ""]).joined(separator: "\n")
            document.model.setWritingMode(.manutius)
            document.model.showSidebar = true
            document.model.initialSelection = NSRange(location: (document.contents.text as NSString).length, length: 0)
        }
        // The scaffold is real unsaved content, so closing and recovery retain it.
        if !document.contents.text.isEmpty { document.updateChangeCount(.changeDone) }
        return document
    }
}

/// Shared by the empty window and the New Tab start screen.
struct NewDocumentChoices: View {
    let create: (NewDocumentKind) -> Void

    var body: some View {
        VStack(spacing: 8) {
            ForEach(NewDocumentKind.allCases) { kind in
                Button { create(kind) } label: {
                    HStack(spacing: 14) {
                        Image(systemName: kind.symbol).font(.title2).frame(width: 30)
                            .foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(kind.title).font(.headline)
                            Text(kind.detail).font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}
