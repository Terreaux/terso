// SPDX-License-Identifier: AGPL-3.0-only
import TersoDocument
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let latexSource = UTType(importedAs: "org.tug.tex", conformingTo: .plainText)
    static let markdownText = UTType(importedAs: "net.daringfireball.markdown", conformingTo: .plainText)
}

/// A plain file. Bytes in, the same bytes out: Terso never normalises line
/// endings, whitespace or Markdown syntax on load or save.
struct MarkdownDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.markdownText, .latexSource, .plainText]
    static let writableContentTypes: [UTType] = [.markdownText, .latexSource, .plainText]

    var text: String
    var codec = PlainTextCodec()

    init(text: String = "") { self.text = text }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        (text, codec) = try PlainTextCodec.decode(data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try codec.encode(text))
    }
}
