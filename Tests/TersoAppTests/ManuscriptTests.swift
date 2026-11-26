// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
import TersoCore
import TersoAnalysis
@testable import TersoApp

struct ManuscriptTests {
    private func withPaper(_ body: (URL, URL, URL, URL) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true).manuscriptURL
        let sectionDir = folder.appendingPathComponent("sections", isDirectory: true)
        try FileManager.default.createDirectory(at: sectionDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = folder.appendingPathComponent("paper.tex"), child = sectionDir.appendingPathComponent("results.tex"), bib = folder.appendingPathComponent("sources.bib")
        try #"""
        \documentclass{article}
        \usepackage{local}
        \begin{document}
        \input{sections/results}
        \label{sec:main} Read \ref{sec:results}.
        \bibliography{sources}
        \end{document}
        """#.write(to: root, atomically: true, encoding: .utf8)
        try #"""
        \section{Results}\label{sec:results}
        From \ref{sec:main} and \parencite[chap.~2]{smith2022,typo}.
        """#.write(to: child, atomically: true, encoding: .utf8)
        try #"""
        % @book{fake, title={No}}
        @article{smith2022, title={A {Nested} Title}, author="J. Smith and A. Author",
          year=2022}
        """#.write(to: bib, atomically: true, encoding: .utf8)
        try "style".write(to: folder.appendingPathComponent("local.sty"), atomically: true, encoding: .utf8)
        try body(folder, root, child, bib)
    }

    @Test func includesAndCitationsAtOriginalSourcePositions() throws {
        try withPaper { _, root, child, bib in
            let index = try ManuscriptIndex(root: root)
            #expect(Set(index.sources.keys) == [root, child])
            #expect(index.references["sec:main"]?.first?.url == child)
            #expect(index.findings.map(\.title) == ["Missing bibliography key: typo"])
            let finding = try #require(index.findings.first)
            #expect(finding.location.line == 2)
            let moved = "Two extra lines.\nHere.\n" + index.sources[child]!
            let relocated = try #require(finding.location.resolved(in: moved))
            #expect(relocated.location == finding.location.range.location + "Two extra lines.\nHere.\n".utf16.count)
            #expect(finding.location.resolved(in: "Key removed.") == nil)
            #expect((index.sources[child]! as NSString).substring(with: finding.location.range.nsRange) == "typo")
            let entry = try #require(index.bibliography.first)
            #expect(index.bibliography.count == 1)
            #expect(entry.title == "A Nested Title" && entry.author == "J. Smith and A. Author")
            #expect(entry.location.url == bib && entry.location.line == 2)
            #expect((index.bibliographySources[bib]! as NSString).substring(with: try #require(entry.entryRange).nsRange).hasSuffix("year=2022}"))
            let snap = DocumentSnapshot(revision: .init(0), text: index.sources[child]!, fileName: child.path)
            let local = WritingAnalyzer().analyze(snap)
            #expect(local.science.diagnostics.contains { $0.title.contains("Broken reference") })
            let resolved = local.withManuscriptReferences(index.findings.map { ($0.rule, $0.title, $0.detail, $0.location.range) }, snapshot: snap)
            #expect(resolved.science.diagnostics.filter { $0.id.hasPrefix("science.references.") }.map(\.title) == [finding.title])
            #expect(resolved.issues.filter { $0.ruleID.hasPrefix("science.references.") }.map(\.message) == [finding.title])
        }
    }

    @Test func sectionBuildUsesOpenBuffersWithRelativeInputsAndStyle() throws {
        try withPaper { folder, root, child, bib in
            let edited = #"\section{Edited}\label{sec:results}\ref{sec:main}\cite{new}"#
            let revisedBib = "@article{new, title={Unsaved bibliography}}"
            let request = ManuscriptRequest(active: child, source: edited, projects: [.init(root: root, linked: [root])], buffers: [child: edited, bib: revisedBib])
            let index = try request.load()
            #expect(index.root == root && index.findings.isEmpty)
            let shadow = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: shadow) }
            let staged = try ManuscriptBuildTree.stage(index, in: shadow)
            #expect(staged.lastPathComponent == root.lastPathComponent)
            let stagedDir = staged.deletingLastPathComponent()
            #expect(try String(contentsOf: stagedDir.appendingPathComponent("sections/results.tex"), encoding: .utf8) == edited)
            #expect(try String(contentsOf: stagedDir.appendingPathComponent("sources.bib"), encoding: .utf8) == revisedBib)
            #expect(try String(contentsOf: stagedDir.appendingPathComponent("local.sty"), encoding: .utf8) == "style")
            #expect(try String(contentsOf: child, encoding: .utf8) != edited)
            #expect(try String(contentsOf: bib, encoding: .utf8) != revisedBib)
            // A separate paper in the same folder must not inherit this project.
            let other = folder.appendingPathComponent("other.tex")
            let otherDocument = #"\documentclass{article}\begin{document}Other\end{document}"#
            let second = ManuscriptRequest(active: other, source: otherDocument, projects: request.projects, buffers: [other: otherDocument])
            #expect(try second.load().root == other)
        }
    }

    @Test func markdownBibliographiesAndCodeExclusions() throws {
        try withPaper { folder, _, _, _ in
            let active = folder.appendingPathComponent("paper.md")
            for yaml in ["bibliography: sources.bib", "bibliography: [sources.bib]", "bibliography:\n  - sources.bib"] {
                let source = "---\n\(yaml)\n---\n## Results {#sec:r}\nA test [@smith2022; @missing] in @sec:r.\n`@fake`\n"
                let index = try ManuscriptIndex(root: active, buffers: [active: source])
                #expect(index.bibliography.count == 1, "\(yaml)")
                #expect(index.citations.keys.sorted() == ["missing", "smith2022"])
                #expect(index.findings.map(\.title) == ["Missing bibliography key: missing"])
            }
        }
    }

    @Test func externalSiblingPackageCanReadItsCompanion() throws {
        try withPaper { folder, _, _, _ in
            let fm = FileManager.default
            let sources = folder.appendingPathComponent("paper", isDirectory: true)
            let styles = folder.appendingPathComponent("styles", isDirectory: true)
            try fm.createDirectory(at: sources, withIntermediateDirectories: true)
            try fm.createDirectory(at: styles, withIntermediateDirectories: true)
            let root = sources.appendingPathComponent("m.tex")
            try #"\usepackage{../styles/journal}"#.write(to: root, atomically: true, encoding: .utf8)
            try #"\input{../styles/helpers.tex}"#.write(to: styles.appendingPathComponent("journal.sty"), atomically: true, encoding: .utf8)
            try "companion".write(to: styles.appendingPathComponent("helpers.tex"), atomically: true, encoding: .utf8)
            let shadow = folder.appendingPathComponent("shadow", isDirectory: true)
            let index = try ManuscriptIndex(root: root)
            let stagedRoot = try ManuscriptBuildTree.stage(index, in: shadow)
            let helper = stagedRoot.deletingLastPathComponent().appendingPathComponent("../styles/helpers.tex")
            #expect(try String(contentsOf: helper, encoding: .utf8) == "companion")
            #expect(try String(contentsOf: root, encoding: .utf8) == #"\usepackage{../styles/journal}"#)
        }
    }

    @Test func cycleMissingInputAndDuplicateDeclarations() throws {
        try withPaper { _, root, child, _ in
            let text = #"\input{paper}\input{nowhere}\label{sec:main}\ref{elsewhere}"#
            let index = try ManuscriptIndex(root: root, buffers: [child: text])
            #expect(index.sources.count == 2)
            #expect(index.findings.filter { $0.rule == "duplicate" }.count == 2)
            #expect(index.findings.filter { $0.rule == "dependency" }.count == 1)
            #expect(!index.findings.contains { $0.rule == "missing" })
            #expect(ManuscriptRequest.magicRoot(in: "% !TeX root = ../paper.tex\ncontent", at: child) == root)
        }
    }

    @Test func citationInsertionCompletesOneKey() {
        #expect(!CitationInsertion(source: "", selection: .init(location: NSNotFound, length: 0), key: "smith", latex: false).isValid)
        #expect(!CitationInsertion(source: "old", selection: .init(location: 2, length: 5), key: "smith", latex: true).isValid)
        for (source, cursor, latex, expected) in [
            ("text", 4, true, #"text\cite{smith}"#),
            (#"\parencite[p.~2]{jones, sm}"#, 26, true, #"\parencite[p.~2]{jones, smith}"#),
            (#"\cite{sm"#, 8, true, #"\cite{smith}"#),
            ("See [@sm].", 8, false, "See [@smith]."),
            ("See ", 4, false, "See [@smith]"),
        ] {
            let edit = CitationInsertion(source: source, selection: .init(location: cursor, length: 0), key: "smith", latex: latex)
            #expect((source as NSString).replacingCharacters(in: edit.range.nsRange, with: edit.replacement) == expected)
        }
    }

    @Test @MainActor func manuscriptRootPersistsAndRemovalClearsIt() throws {
        try withPaper { folder, root, child, _ in
            let url = folder.appendingPathComponent("projects.json")
            let store = ProjectStore(fileURL: url)
            let project = store.create(named: "Paper", with: [root, child])
            let id = try #require(project.documents.first).id
            store.setManuscriptRoot(id, in: project.id)
            #expect(ProjectStore(fileURL: url).projects.first?.manuscriptRoot?.url.manuscriptURL == root)
            store.remove(id, from: project.id)
            #expect(ProjectStore(fileURL: url).projects.first?.manuscriptRootID == nil)
        }
    }
}
