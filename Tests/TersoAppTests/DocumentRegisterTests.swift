// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import SwiftUI
import Testing
import TersoStyle
@testable import TersoApp

@Suite @MainActor struct DocumentRegisterTests {
    @Test func paperTemplateSelectsAcademicAcrossFormats() {
        for format in TemplateSourceFormat.allCases {
            let paper = DocumentCreationRequest.template(.researchPaper, format).makeDocument()
            #expect(paper.model.registerOverride == .academic)
            paper.close()
        }
        let essay = DocumentCreationRequest.template(.essay, .markdown).makeDocument()
        #expect(essay.model.registerOverride == nil)
        essay.close()
    }

    @Test func rememberedRegisterSurvivesFirstSaveReopenAndSaveAs() throws {
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = URL(fileURLWithPath: "/tmp/manuscript.tex")
        let copy = URL(fileURLWithPath: "/tmp/revision.tex")
        let paper = WorkspaceModel(registerDefaults: defaults)
        paper.setWritingRegister(.academic)
        paper.fileURL = first
        paper.fileURL = copy
        let original = WorkspaceModel(registerDefaults: defaults)
        original.fileURL = first
        let revision = WorkspaceModel(registerDefaults: defaults)
        revision.fileURL = copy
        #expect(original.registerOverride == .academic)
        #expect(revision.registerOverride == .academic)
        revision.setWritingRegister(nil)
        let reopened = WorkspaceModel(registerDefaults: defaults)
        reopened.fileURL = copy
        #expect(reopened.registerOverride == nil)
        #expect(original.writingRegister == .academic)
    }
    @Test func aliasesShareTheChoiceAndIndependentDocumentsKeepTheirRegisters() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suite)
        }
        let actual = directory.appending(path: "real.tex")
        let alias = directory.appending(path: "alias.tex")
        let essayURL = directory.appending(path: "essay.md")
        try Data().write(to: actual)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual)
        let paper = WorkspaceModel(registerDefaults: defaults), essay = WorkspaceModel(registerDefaults: defaults)
        paper.fileURL = actual
        essay.fileURL = essayURL
        paper.setWritingRegister(.academic)
        essay.setWritingRegister(.fiction)
        let reopened = WorkspaceModel(registerDefaults: defaults)
        reopened.fileURL = alias
        #expect(reopened.writingRegister == .academic)
        #expect(essay.writingRegister == .fiction)

        // Choosing the app default before a first save must supersede an old path's choice.
        let fresh = WorkspaceModel(registerDefaults: defaults)
        fresh.setWritingRegister(.academic)
        fresh.setWritingRegister(nil)
        fresh.fileURL = actual
        #expect(fresh.registerOverride == nil)
    }

    @Test func sectionUsesTheRootRegisterUntilOverriddenAndTracksItsChanges() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let main = dir.appendingPathComponent("paper.tex").manuscriptURL
        let section = dir.appendingPathComponent("results.tex").manuscriptURL
        let sectionSource = "% !TeX root = paper.tex\nResults are shown."
        try #"\documentclass{article}\begin{document}\input{results}\end{document}"#.write(to: main, atomically: true, encoding: .utf8)
        try sectionSource.write(to: section, atomically: true, encoding: .utf8)

        _ = NSApplication.shared
        let tabs = DocumentTabs.shared
        let previous = tabs.activeWorkspace
        let window = tabs.newWorkspace(), child = TabDocument()
        child.fileURL = section
        child.contents.text = sectionSource
        window.insert(child)
        let root = WorkspaceModel()
        root.fileURL = main
        defer {
            child.model.setWritingRegister(nil)
            root.setWritingRegister(nil)
            tabs.remove(window)
            tabs.activeWorkspace = previous
            child.close()
            window.window?.orderOut(nil)
        }
        root.setWritingRegister(.academic)
        let editor = EditorCoordinator(model: child.model, text: .constant(sectionSource))
        let textView = TersoTextView(frame: .zero)
        textView.string = sectionSource
        editor.textView = textView
        child.model.editor = editor
        func waitForAnalysis(_ expected: WritingDomain) async throws {
            let deadline = ContinuousClock.now + .seconds(20)
            while child.model.style?.domain != expected || child.model.documentStatistics == nil {
                guard ContinuousClock.now < deadline else { Issue.record("Timed out waiting for \(expected) section analysis"); return }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(child.model.writingRegister == expected)
        }
        child.model.scheduleAnalysis()
        try await waitForAnalysis(.academic)
        #expect(child.model.registerManuscriptRoot == main && child.model.registerOverride == nil)
        root.setWritingRegister(.technical)
        try await waitForAnalysis(.technical)
        child.model.setWritingRegister(.fiction)
        try await waitForAnalysis(.fiction)
        root.setWritingRegister(.academic)
        #expect(child.model.inheritedRegister == .academic && child.model.writingRegister == .fiction)
        child.model.setWritingRegister(nil)
        try await waitForAnalysis(.academic)
        root.setWritingRegister(nil)
        try await waitForAnalysis(child.model.prefs.domain)
        #expect(child.model.inheritedRegister == nil && child.model.registerOverride == nil)
        withExtendedLifetime((editor, textView)) {}
    }

    @Test func manuscriptReviewOpensAfterTheReportDismissesInTheSameTab() {
        let paper = WorkspaceModel(), other = WorkspaceModel()
        paper.showDocumentReport = true
        paper.manuscriptStartsWithCitations = true
        paper.openFromDocumentReport(.manuscript)
        #expect(!paper.showDocumentReport && !paper.showManuscript)
        other.documentReportDidDismiss()
        #expect(!other.showManuscript)
        paper.documentReportDidDismiss()
        #expect(paper.showManuscript && !paper.manuscriptStartsWithCitations)
        paper.showManuscript = false
        paper.documentReportDidDismiss()
        #expect(!paper.showManuscript)
    }

}
