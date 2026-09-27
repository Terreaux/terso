// SPDX-License-Identifier: AGPL-3.0-only
import TersoDocument
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let markdownText = UTType(importedAs: "net.daringfireball.markdown", conformingTo: .plainText)
}

/// A plain file. Bytes in, the same bytes out: Terso never normalises line
/// endings, whitespace or Markdown syntax on load or save.
struct MarkdownDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.markdownText, .plainText]
    static let writableContentTypes: [UTType] = [.markdownText, .plainText]

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
