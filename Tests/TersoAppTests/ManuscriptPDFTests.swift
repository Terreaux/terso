// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import PDFKit
import Testing
@testable import TersoApp

/// Opt in with the path of a real, multi-file TeX paper and a populated Tectonic cache.
/// The input is copied; the extra citation and both edits exist only in editor buffers.
@Suite @MainActor struct ManuscriptPDFTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TERSO_TEST_MANUSCRIPT"] != nil))
    func previewAndExportReflectTwoUnsavedTabs() async throws {
        let input = try #require(ProcessInfo.processInfo.environment["TERSO_TEST_MANUSCRIPT"])
        let original = URL(fileURLWithPath: input)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let folder = temp.appendingPathComponent("paper", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.copyItem(at: original.deletingLastPathComponent(), to: folder)
        let root = folder.appendingPathComponent(original.lastPathComponent).manuscriptURL
        let baseline = try ManuscriptIndex(root: root)
        // Some manuscripts put every section heading in the root, then input
        // separate files containing only the body of each section.
        let child = try #require(baseline.sources.keys.sorted(by: { $0.path < $1.path }).first {
            $0 != root && $0.pathExtension.lowercased() == "tex"
        })
        let initialRoot = try #require(baseline.sources[root])
        let initialChild = try #require(baseline.sources[child])
        let originalRootData = try Data(contentsOf: root), originalChildData = try Data(contentsOf: child)
        let end = try #require(initialRoot.range(of: #"\end{document}"#, options: .backwards))
        var editedRoot = initialRoot
        editedRoot.insert(contentsOf: "\nRootbuffercheck.\n", at: end.lowerBound)
        let editedChild = "% !TEX root = \(root.path)\n" + initialChild + "\n\nChildbuffercheck. " + #"\cite{auditMissing2026}"# + "\n"

        _ = NSApplication.shared
        let workspace = DocumentTabs.shared.newWorkspace()
        let rootTab = TabDocument(), childTab = TabDocument()
        defer {
            DocumentTabs.shared.remove(workspace)
            rootTab.close()
            childTab.close()
            workspace.window?.orderOut(nil)
        }
        rootTab.fileURL = root
        rootTab.contents.text = editedRoot
        childTab.fileURL = child
        childTab.contents.text = editedChild
        workspace.insert(rootTab)
        workspace.insert(childTab)
        let indexed = try await ManuscriptContext.index(for: child, source: editedChild)
        #expect(indexed.root == root)
        let issue = try #require(indexed.findings.first { $0.title.contains("auditMissing2026") })
        #expect(issue.location.url == child)
        #expect((editedChild as NSString).substring(with: issue.location.range.nsRange) == "auditMissing2026")
        let preview = TectonicPreviewModel()
        await preview.compile(source: editedChild, fileURL: child)
        let previewBytes = try #require(preview.pdf, "\(preview.error ?? "") \(preview.log)")
        let output = temp.appendingPathComponent("export.pdf")
        try await DocumentExport.write(childTab, as: .pdf, latex: true, to: output, window: nil)
        for bytes in [previewBytes, try Data(contentsOf: output)] {
            let pdf = try #require(PDFDocument(data: bytes))
            let text = try #require(pdf.string)
            #expect(text.contains("Rootbuffercheck"))
            #expect(text.contains("Childbuffercheck"))
        }
        #expect(try Data(contentsOf: root) == originalRootData)
        #expect(try Data(contentsOf: child) == originalChildData)
        print("Verified \(indexed.sources.count) source files and \(indexed.bibliography.count) bibliography entries in \(original.lastPathComponent)")
    }
}
