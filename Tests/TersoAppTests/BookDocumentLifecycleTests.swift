// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import Testing
@testable import TersoApp

@Suite(.serialized) @MainActor struct BookDocumentLifecycleTests {
    private let latex = "\\documentclass{book}\r\n\\usepackage{terso-book}\r\n\\begin{document}\r\n\\chapter{One}\r\nWords.  \r\n\\end{document}\r\n"
    private let latexType = "org.tug.tex"

    @Test func firstSaveInstallsTheCompanionAndPreservesSourceBytes() async throws {
        _ = NSApplication.shared
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = TabDocument()
        defer { document.close() }
        let bytes = Data([0xef, 0xbb, 0xbf]) + Data(latex.utf8)
        try document.read(from: bytes, ofType: latexType)
        document.fileType = latexType
        document.updateChangeCount(.changeDone)
        let url = directory.appendingPathComponent("Book.tex")

        try await save(document, to: url, operation: .saveOperation)

        #expect(try Data(contentsOf: url) == bytes)
        #expect(try packageData(in: directory) == bundledPackageData())
        #expect(document.fileURL == url)
        #expect(!document.isDocumentEdited)
        #expect(document.bookPackageError == nil)
    }

    @Test func autosaveReinstallsAMissingCompanionAndKeepsAnEditedOne() async throws {
        _ = NSApplication.shared
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = try bookDocument()
        defer { document.close() }
        let url = directory.appendingPathComponent("Book.tex")
        try await save(document, to: url, operation: .saveOperation)
        let package = directory.appendingPathComponent("terso-book.sty")
        try FileManager.default.removeItem(at: package)
        document.contents.text = latex.replacingOccurrences(of: "Words.", with: "A new paragraph.")
        document.updateChangeCount(.changeDone)

        try await save(document, to: url, operation: .autosaveInPlaceOperation)

        #expect(try packageData(in: directory) == bundledPackageData())
        #expect(try String(contentsOf: url, encoding: .utf8) == document.contents.text)
        let editedPackage = Data("% Writer's own package\n".utf8)
        try editedPackage.write(to: package)
        document.contents.text += "% Another change\r\n"
        document.updateChangeCount(.changeDone)
        try await save(document, to: url, operation: .autosaveInPlaceOperation)
        #expect(try packageData(in: directory) == editedPackage)
        #expect(document.bookPackageError == nil)
    }

    @Test func saveAsInstallsBesideTheNewFileWithoutChangingExistingPackages() async throws {
        _ = NSApplication.shared
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try temporaryDirectory(in: directory)
        let second = try temporaryDirectory(in: directory)
        let third = try temporaryDirectory(in: directory)
        let document = try bookDocument()
        defer { document.close() }
        let original = first.appendingPathComponent("Book.tex")
        try await save(document, to: original, operation: .saveOperation)
        let custom = Data("% custom style, keep me\n".utf8)
        try custom.write(to: first.appendingPathComponent("terso-book.sty"))
        let copy = second.appendingPathComponent("Revised.tex")

        try await save(document, to: copy, operation: .saveAsOperation)

        #expect(document.fileURL == copy)
        #expect(try packageData(in: first) == custom)
        #expect(try packageData(in: second) == bundledPackageData())
        #expect(try Data(contentsOf: original) == Data(contentsOf: copy))
        try custom.write(to: third.appendingPathComponent("terso-book.sty"))
        try await save(document, to: third.appendingPathComponent("Custom.tex"), operation: .saveAsOperation)
        #expect(try packageData(in: third) == custom)
    }

    @Test func packageFailureLeavesTheSourceSavedAndOffersARetry() async throws {
        _ = NSApplication.shared
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let package = directory.appendingPathComponent("terso-book.sty")
        // A directory occupying the companion's name reliably blocks the copy
        // even when the test runner has permission to write the parent folder.
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        let document = try bookDocument()
        defer { document.close() }
        let url = directory.appendingPathComponent("Book.tex")

        try await save(document, to: url, operation: .saveOperation)

        #expect(try Data(contentsOf: url) == Data(latex.utf8))
        #expect(!document.isDocumentEdited)
        let warning = try #require(document.bookPackageError)
        #expect(warning.contains("manuscript is saved"))
        #expect(warning.contains("terso-book.sty"))
        #expect(warning.contains(directory.path))
        document.retryBookPackageInstallation()
        #expect(document.bookPackageError != nil)
        try FileManager.default.removeItem(at: package)

        document.retryBookPackageInstallation()

        #expect(document.bookPackageError == nil)
        #expect(try packageData(in: directory) == bundledPackageData())
        #expect(try Data(contentsOf: url) == Data(latex.utf8))
    }

    @Test(arguments: ["md", "txt"])
    func savingQuotedPackageCommandsDoesNotCreateACompanion(fileExtension: String) async throws {
        _ = NSApplication.shared
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let selectedType = fileExtension == "md" ? "net.daringfireball.markdown" : "public.plain-text"
        let source = fileExtension == "md" ? "# LaTeX example\n\n```latex\n\(latex)```\n" : latex
        // Ensure this example would trip the package-command matcher by itself.
        #expect(LaTeXBookDesign.line(in: source) != nil)
        let document = TabDocument()
        defer { document.close() }
        document.fileType = selectedType
        document.contents.text = source
        document.updateChangeCount(.changeDone)
        let url = directory.appendingPathComponent("Example.\(fileExtension)")

        try await save(document, to: url, operation: .saveOperation, type: selectedType)

        #expect(try Data(contentsOf: url) == Data(source.utf8))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("terso-book.sty").path))
        #expect(document.bookPackageError == nil)
    }

    @Test func portableBookMarkersReopenInBookModeWithoutEditingTheFile() throws {
        _ = NSApplication.shared
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let markdown = "---\ntitle: My Book\nbook:\n  trim: 6x9\n---\n\n# One\n\nWords.  \n"
        for (name, type, source) in [("Book.md", "net.daringfireball.markdown", markdown), ("Book.tex", latexType, latex)] {
            let bytes = Data([0xef, 0xbb, 0xbf]) + Data(source.utf8)
            let url = directory.appendingPathComponent(name)
            try bytes.write(to: url)
            let document = try TabDocument(contentsOf: url, ofType: type)
            defer { document.close() }
            #expect(document.model.writingMode == .manutius)
            #expect(document.model.showSidebar)
            #expect(!document.model.showInspector)
            #expect(!document.isDocumentEdited)
            #expect(try document.data(ofType: type) == bytes)
            #expect(try Data(contentsOf: url) == bytes)
        }
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("terso-book.sty").path))
    }

    @Test(arguments: [
        "\\documentclass{book}\n\\begin{document}\n\\chapter{One}\n\\end{document}\n",
        "\\documentclass{book}\n% \\usepackage{terso-book}\n\\begin{document}\n\\end{document}\n",
        "\\documentclass{book}\n\\begin{document}\n\\usepackage{terso-book}\n\\end{document}\n",
        "---\ntitle: A Report\n---\n\n# One\n"
    ])
    func ordinaryDocumentsDoNotOptIntoBookMode(source: String) throws {
        let document = TabDocument()
        defer { document.close() }
        try document.read(from: Data(source.utf8), ofType: "public.plain-text")
        #expect(document.model.writingMode == .hemingway)
        #expect(!document.model.showSidebar)
        #expect(document.contents.text == source)
    }

    private func bookDocument() throws -> TabDocument {
        let document = TabDocument()
        document.fileType = latexType
        try document.read(from: Data(latex.utf8), ofType: latexType)
        document.updateChangeCount(.changeDone)
        return document
    }

    private func save(_ document: TabDocument, to url: URL, operation: NSDocument.SaveOperationType, type: String? = nil) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            document.save(to: url, ofType: type ?? latexType, for: operation) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    private func temporaryDirectory(in parent: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let directory = parent.appendingPathComponent("terso-book-lifecycle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func packageData(in directory: URL) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent("terso-book.sty"))
    }

    private func bundledPackageData() throws -> Data {
        try Data(contentsOf: #require(LaTeXBookDesign.bundledPackage))
    }
}
