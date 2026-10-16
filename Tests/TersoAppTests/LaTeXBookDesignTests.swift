// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import TersoApp

@Suite @MainActor struct LaTeXBookDesignTests {
    private let preamble = """
    \\documentclass{book}
    \\usepackage[T1]{fontenc}
    \\title{The Keeper's Daughter}
    \\begin{document}
    \\chapter{One}
    Text.
    \\end{document}

    """

    private func apply(_ edit: (range: NSRange, replacement: String)?, to text: String) -> String {
        guard let edit else { return text }
        return (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
    }

    @Test func aDocumentWithoutThePackageIsNotABook() {
        #expect(BookDesign.read(latex: preamble, defaults: BookDesign()) == nil)
        // Commented out, or after \begin{document}, it is not the preamble's.
        let commented = preamble.replacingOccurrences(of: "\\usepackage[T1]", with: "% \\usepackage{terso-book}\n\\usepackage[T1]")
        #expect(LaTeXBookDesign.line(in: commented) == nil)
        let late = preamble.replacingOccurrences(of: "Text.", with: "\\usepackage{terso-book}")
        #expect(LaTeXBookDesign.line(in: late) == nil)
    }

    @Test func optionsParseIntoADesignWithDefaultsForTheRest() throws {
        let text = preamble.replacingOccurrences(of: "\\usepackage[T1]{fontenc}", with: """
        \\usepackage[trim=5.5x8.5, typeface=hoefler, size=12,
          headings=big-numeral, chapters-start=continuous, drop-caps=false,
          scene-break=fleuron, matter={half-title, contents}, page-numbers=outside]{terso-book}
        """)
        let d = try #require(BookDesign.read(latex: text, defaults: BookDesign()))
        #expect(d.trim == .digest && d.typeface == .hoefler && d.typeSize == 12)
        #expect(d.headings == .bigNumeral && d.openers == .continuous && !d.dropCaps)
        #expect(d.sceneBreak == .fleuron && d.folios == .outside)
        #expect(d.matter == [.halfTitle, .contents])
        // Left out: the package's defaults, which are Terso's.
        #expect(d.lineSpacing == BookDesign().lineSpacing && d.runningHeads == .titleAndChapter && d.smallCapsOpening)
        // With no options at all, a book in the defaults.
        let bare = preamble.replacingOccurrences(of: "\\usepackage[T1]{fontenc}", with: "\\usepackage{terso-book}")
        #expect(BookDesign.read(latex: bare, defaults: BookDesign()) == BookDesign())
    }

    @Test func optionsSplitOutsideBraces() {
        let options = LaTeXBookDesign.options(" trim = 6x9 ,matter={half-title, title-page}, draft,, ")
        #expect(options.map(\.key) == ["trim", "matter", "draft"])
        #expect(options[0].value == "6x9" && options[1].value == "half-title, title-page" && options[2].value == "")
    }

    @Test func writingRoundTripsEveryKey() throws {
        var design = BookDesign()
        design.trim = .sevenByTen; design.typeface = .iowan; design.typeSize = 10.5; design.lineSpacing = 1.35
        design.paragraphs = .spaced; design.indent = 2; design.justify = false; design.hyphenate = false
        design.headings = .rules; design.openers = .newPage; design.sceneBreak = .lozenge
        design.runningHeads = .title; design.folios = .off; design.matter = [.titlePage, .aboutAuthor]
        design.facingPages = false; design.wordGoal = 60_000
        let text = preamble.replacingOccurrences(of: "\\usepackage[T1]{fontenc}", with: "\\usepackage{terso-book}")
        let written = apply(LaTeXBookDesign.edit(of: text, design: design), to: text)
        #expect(written.contains("\\usepackage[trim=7x10, typeface=iowan, size=10.5, line-spacing=1.35,"))
        #expect(written.contains("matter={title-page, about-author}"))
        let read = try #require(BookDesign.read(latex: written, defaults: BookDesign()))
        #expect(read == design)
        // Written again unchanged, there is nothing to do.
        #expect(LaTeXBookDesign.edit(of: written, design: design) == nil)
    }

    @Test func unknownKeysAreKeptAndOnlyTheLineChanges() throws {
        let line = "\\usepackage[headings=plain, bleed=0.125in, crop]{terso-book}"
        let text = preamble.replacingOccurrences(of: "\\usepackage[T1]{fontenc}", with: "\\usepackage[T1]{fontenc}\n" + line)
        var design = try #require(BookDesign.read(latex: text, defaults: BookDesign()))
        #expect(design.headings == .plain)
        design.headings = .smallCaps
        let edit = try #require(LaTeXBookDesign.edit(of: text, design: design))
        #expect((text as NSString).substring(with: edit.range) == line)
        #expect(edit.replacement.hasSuffix("word-goal=80000, bleed=0.125in, crop]{terso-book}"))
        let written = apply(edit, to: text)
        #expect(written.replacingOccurrences(of: edit.replacement, with: line) == text)
        #expect(BookDesign.read(latex: written, defaults: BookDesign())?.headings == .smallCaps)
    }

    @Test func setUpInsertsTheLineAfterDocumentclass() throws {
        let set = apply(LaTeXBookDesign.setupEdit(of: preamble, design: BookDesign()), to: preamble)
        let lines = set.components(separatedBy: "\n")
        #expect(lines[0] == "\\documentclass{book}")
        #expect(lines[1].hasPrefix("\\usepackage[trim=6x9,") && lines[1].hasSuffix("]{terso-book}"))
        #expect(lines[2] == "\\usepackage[T1]{fontenc}")
        #expect(BookDesign.read(latex: set, defaults: BookDesign()) == BookDesign())
        // Once set up, there is nothing more to set up.
        #expect(LaTeXBookDesign.setupEdit(of: set, design: BookDesign()) == nil)
        // A fragment without \documentclass can't be.
        #expect(LaTeXBookDesign.setupEdit(of: "\\chapter{One}\nText.", design: BookDesign()) == nil)
    }

    @Test func setUpMakesOneSidedClassesTwoSided() {
        let report = "\\documentclass[11pt]{report} % a report\n\\begin{document}\n\\end{document}\n"
        let set = apply(LaTeXBookDesign.setupEdit(of: report, design: BookDesign()), to: report)
        #expect(set.hasPrefix("\\documentclass[11pt,twoside,openright]{report} % a report\n\\usepackage["))
        var anywhere = BookDesign(); anywhere.openers = .newPage
        let article = "\\documentclass{article}"
        let plain = apply(LaTeXBookDesign.setupEdit(of: article, design: anywhere), to: article)
        #expect(plain.hasPrefix("\\documentclass[twoside]{article}\n\\usepackage["))
        #expect(!plain.hasSuffix("\n"))
        // A class told to be one-sided stays so; book needs nothing.
        let oneside = "\\documentclass[oneside]{report}\n"
        #expect(apply(LaTeXBookDesign.setupEdit(of: oneside, design: anywhere), to: oneside).hasPrefix("\\documentclass[oneside]{report}\n"))
        #expect(apply(LaTeXBookDesign.setupEdit(of: preamble, design: BookDesign()), to: preamble).hasPrefix("\\documentclass{book}\n"))
    }

    @Test func thePackageIsWrittenBesideTheFileUnlessItIsThere() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("terso-book-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundled = try #require(LaTeXBookDesign.bundledPackage)
        #expect(try String(contentsOf: bundled, encoding: .utf8).contains("\\ProvidesPackage{terso-book}"))
        #expect(try LaTeXBookDesign.install(in: directory) == .written)
        #expect(try LaTeXBookDesign.install(in: directory) == .unchanged)
        let target = directory.appendingPathComponent("terso-book.sty")
        try "% mine\n".write(to: target, atomically: true, encoding: .utf8)
        #expect(try LaTeXBookDesign.install(in: directory) == .kept)
        #expect(try String(contentsOf: target, encoding: .utf8) == "% mine\n")
    }

    @Test func markdownBlocksStillReadAndWriteAsBefore() throws {
        var design = BookDesign()
        design.headings = .uppercase; design.matter = [.contents]
        let written = apply(design.edit(of: "# One\n\nText."), to: "# One\n\nText.")
        #expect(written.hasPrefix("---\nbook:\n  trim: 6x9\n"))
        #expect(written.contains("  matter: [contents]\n"))
        #expect(BookDesign.read(from: written, defaults: BookDesign()) == design)
    }
}
