// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import Testing
import TersoCore
@testable import TersoApp

@Suite @MainActor struct LaTeXMixedTests {
    func config() -> EditorConfig {
        let model = WorkspaceModel()
        var config = EditorConfig(prefs: model.prefs, model: model, latex: true)
        config.renderMode = .mixed
        return config
    }

    func drawn(_ tex: String, at selection: NSRange? = nil) -> [String] {
        let ns = tex as NSString
        let decor = MixedPresentation.layout(in: tex, selection: selection ?? NSRange(location: ns.length, length: 0),
                                             config: config(), elements: Set(MixedElement.allCases), width: 600)
        return decor.glyphs.map { ns.substring(with: $0.range) }
    }

    @Test func listsDrawBulletsAndNumbersAwayFromTheCaret() {
        let tex = "\\documentclass{article}\n\\begin{document}\n\\begin{itemize}\n  \\item one\n  \\item two\n\\end{itemize}\n\\begin{enumerate}\n\\item first\n  \\begin{enumerate}\n  \\item inner\n  \\item[*] custom\n  \\item inner two\n  \\end{enumerate}\n\\item second\n\\end{enumerate}\n\\begin{description}\n\\item[Term] text\n\\item[$x$] math\n\\end{description}\nEnd"
        let ns = tex as NSString
        #expect(drawn(tex) == [
            "\\begin{document}", "\\begin{itemize}", "\\item ", "\\item ", "\\end{itemize}",
            "\\begin{enumerate}", "\\item ", "  \\begin{enumerate}", "\\item ", "\\item[*] ", "\\item ", "  \\end{enumerate}", "\\item ", "\\end{enumerate}",
            "\\begin{description}", "\\item[Term] ", "\\end{description}",
        ])
        #expect(LaTeXMixedPresentation.enumerateLabel(2, depth: 1) == "2.")
        #expect(LaTeXMixedPresentation.enumerateLabel(2, depth: 2) == "(b)")
        #expect(LaTeXMixedPresentation.enumerateLabel(4, depth: 3) == "iv.")
        // Nested lists count apart: the outer list resumes at 2 after the inner one.
        let decor = MixedPresentation.layout(in: tex, selection: NSRange(location: ns.length, length: 0), config: config(),
                                             elements: [.blocks], width: 600)
        let second = decor.glyphs.first { ns.substring(with: NSRange(location: $0.range.upperBound, length: 6)) == "second" }
        let first = decor.glyphs.first { ns.substring(with: NSRange(location: $0.range.upperBound, length: 5)) == "first" }
        let flat = "\\documentclass{article}\n\\begin{document}\n\\begin{enumerate}\n\\item a\n\\item b\n\\end{enumerate}"
        let two = MixedPresentation.layout(in: flat, selection: NSRange(location: 0, length: 0), config: config(), elements: [.blocks], width: 600)
            .glyphs.filter { ($0.range.length) == 6 }
        #expect(two.count == 2 && first?.image === two[0].image && second?.image === two[1].image)
        // On the editing line the item, and a begin line, are source again.
        let onTwo = drawn(tex, at: ns.range(of: "two"))
        #expect(onTwo.filter { $0 == "\\item " }.count == 5)
        #expect(!drawn(tex, at: ns.range(of: "\\begin{itemize}")).contains("\\begin{itemize}"))
        #expect(MixedPresentation.layout(in: tex, selection: NSRange(location: 0, length: 0), config: config(), elements: [.math], width: 600).glyphs.isEmpty)
    }

    @Test func documentMatterRendersWithoutRemovingLines() {
        let tex = """
        \\documentclass{book}
        \\title{The {Long} Road}
        \\author{Ada Writer}
        \\begin{document}
        \\frontmatter
        \\maketitle
        \\tableofcontents
        \\mainmatter
        \\chapter{First}
        \\section{Details}
        \\backmatter
        \\end{document}
        """
        let ns = tex as NSString
        let away = MixedPresentation.layout(in: tex, selection: ns.range(of: "\\chapter{First}"),
                                            config: config(), elements: [.blocks], width: 600)
        let rendered = away.glyphs.map { ns.substring(with: $0.range) }
        #expect(rendered == ["\\begin{document}", "\\frontmatter", "\\maketitle", "\\tableofcontents",
                             "\\mainmatter", "\\backmatter", "\\end{document}"])
        #expect(away.glyphs.allSatisfy { $0.range.length > 0 && !ns.substring(with: $0.range).contains("\n") })
        let title = away.glyphs.first { ns.substring(with: $0.range) == "\\maketitle" }!
        let contents = away.glyphs.first { ns.substring(with: $0.range) == "\\tableofcontents" }!
        #expect(title.image.size.height > config().fontSize)
        #expect(contents.image.size.height > title.image.size.height)
        let editing = MixedPresentation.layout(in: tex, selection: ns.range(of: "\\tableofcontents"),
                                               config: config(), elements: [.blocks], width: 600)
        #expect(!editing.glyphs.contains { ns.substring(with: $0.range) == "\\tableofcontents" })
        #expect(editing.reservedLineHeights.first?.height == contents.image.size.height)

        let storage = NSTextStorage(string: tex, attributes: [.font: config().font.font(size: config().fontSize)])
        let layout = MathLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 650, height: 10_000))
        layout.addTextContainer(container)
        let index = ns.range(of: "\\tableofcontents").location
        layout.setRendered(away.glyphs)
        layout.ensureLayout(for: container)
        let renderedHeight = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: index), effectiveRange: nil).height
        layout.setRendered(editing.glyphs)
        layout.reservedLineHeights = editing.reservedLineHeights
        layout.ensureLayout(for: container)
        let editingHeight = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: index), effectiveRange: nil).height
        #expect(abs(renderedHeight - editingHeight) < 2)
    }

    @Test(arguments: ["\n", "\r\n"]) func titleSelectionRevealsOnlyMetadataAndKeepsItEditable(newline: String) {
        let tex = """
        \\documentclass{book}
        \\usepackage[trim=6x9, matter={title-page, contents}]{terso-book}
        \\usepackage[paperwidth=6in,paperheight=9in,margin=0.8in]{geometry}
        % \\title{Ignored}
        \\title[Short]{The {Long} Way 😀
        Round}
        \\author{A. Writer}
        \\date{October 2026}
        \\begin{document}
        \\maketitle
        Body.
        \\end{document}
        """.replacingOccurrences(of: "\n", with: newline)
        let ns = tex as NSString
        func visible(_ selection: NSRange, elements: Set<MixedElement> = [.blocks]) -> String {
            let hidden = MarkerPresentation.hiddenSyntax(in: tex, selection: selection, latex: true, elements: elements)
            let result = NSMutableString(string: tex)
            for range in hidden.sorted(by: { $0.location > $1.location }) { result.deleteCharacters(in: range) }
            return result as String
        }
        let body = ns.range(of: "Body.")
        #expect(visible(body).hasPrefix("\\begin{document}"))
        for selection in [ns.range(of: "\\maketitle"), ns.range(of: "Round}"), ns.range(of: "A. Writer"), ns.range(of: "October 2026")] {
            let shown = visible(selection)
            #expect(shown.hasPrefix("\\title[Short]{The {Long} Way 😀\nRound}\n\\author{A. Writer}\n\\date{October 2026}\n".replacingOccurrences(of: "\n", with: newline)))
            #expect(!shown.contains("\\documentclass") && !shown.contains("\\usepackage") && !shown.contains("Ignored"))
        }
        #expect(visible(NSRange(location: 0, length: 0)).hasPrefix("\\begin{document}"))
        #expect(visible(body, elements: [.math]) == tex)
        #expect(visible(ns.range(of: "\\maketitle"), elements: []) == tex)
        let fragment = "\\title{Fragment}\nBody."
        #expect(MarkerPresentation.hiddenSyntax(in: fragment, selection: body, latex: true, elements: [.blocks]).isEmpty)
    }

    @Test func foldedPreambleOccupiesNoLinesAndPreservesSource() {
        let tex = "\\documentclass{book}\n\\usepackage{geometry}\n\\title{Title}\n\\author{Writer}\n\\begin{document}\n\\maketitle\nBody."
        let ns = tex as NSString
        let storage = NSTextStorage(string: tex, attributes: [.font: config().font.font(size: config().fontSize)])
        let layout = MathLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 650, height: 10_000))
        layout.addTextContainer(container)
        func top(_ needle: String) -> CGFloat {
            layout.ensureLayout(for: container)
            return layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: ns.range(of: needle).location), effectiveRange: nil).minY
        }
        let originalTop = top("\\begin{document}")
        layout.hiddenSyntax = MarkerPresentation.hiddenSyntax(in: tex, selection: ns.range(of: "Body."), latex: true, elements: [.blocks])
        #expect(top("\\begin{document}") < originalTop)
        #expect(top("\\begin{document}") == 0)
        layout.hiddenSyntax = MarkerPresentation.hiddenSyntax(in: tex, selection: ns.range(of: "\\maketitle"), latex: true, elements: [.blocks])
        #expect(top("\\title") == 0)
        #expect(top("\\begin{document}") > 0)
        #expect(storage.string == tex)
        layout.hiddenSyntax = []
        #expect(top("\\begin{document}") == originalTop)
    }

    @Test func referencesResolveToTheirNumbersAndCitationsToLabels() {
        let tex = """
        \\documentclass{article}
        \\newtheorem{theorem}{Theorem}
        \\begin{document}
        \\section{Intro}\\label{sec:intro}
        \\begin{equation}\\label{eq:a} a \\end{equation}
        \\begin{align}
        x &= 1 \\label{eq:b} \\\\
        y &= 2 \\notag \\\\
        z &= 3 \\label{eq:c}
        \\end{align}
        \\subsection{More}\\label{sec:more}
        \\begin{figure}\\caption{F}\\label{fig:f}\\end{figure}
        \\begin{theorem}\\label{thm:t} T \\end{theorem}
        \\begin{enumerate}\\item\\label{it:one} x \\begin{enumerate}\\item y \\item\\label{it:b} z\\end{enumerate}\\end{enumerate}
        See \\ref{sec:intro}, \\ref{sec:more}, \\eqref{eq:a}, \\ref{eq:b}, \\eqref{eq:c}, \\autoref{fig:f}, \\cref{eq:a}, \\ref{thm:t}, \\ref{it:b}, \\ref{missing}.
        As \\citep[see][p.~3]{knuth, lamport} and \\cite{knuth} say.\\footnote{A note with \\cite{x}.} Then.\\footnote{Two}
        \\end{document}
        """
        let ns = tex as NSString
        let labels = LaTeXMixedPresentation.labels(in: tex, quiet: [])
        #expect(labels["sec:intro"]?.number == "1")
        #expect(labels["sec:more"]?.number == "1.1")
        #expect(labels["eq:a"]?.number == "1")
        #expect(labels["eq:b"]?.number == "2")
        #expect(labels["eq:c"]?.number == "3")
        #expect(labels["fig:f"]?.number == "1")
        #expect(labels["thm:t"] == nil)
        #expect(labels["it:one"]?.number == "1")
        #expect(labels["it:b"]?.number == "1b")
        #expect(labels["eq:a"]?.display("eqref") == "(1)")
        #expect(labels["eq:a"]?.display("cref") == "eq. (1)")
        #expect(labels["fig:f"]?.display("autoref") == "Figure 1")
        let line = drawn(tex, at: NSRange(location: 0, length: 0))
        #expect(line.contains("\\ref{sec:intro}") && line.contains("\\eqref{eq:c}") && line.contains("\\autoref{fig:f}"))
        #expect(!line.contains("\\ref{missing}") && !line.contains("\\ref{thm:t}"))
        #expect(line.contains("\\citep[see][p.~3]{knuth, lamport}") && line.contains("\\cite{knuth}"))
        // A footnote is drawn whole, with whatever it holds.
        #expect(line.contains("\\footnote{A note with \\cite{x}.}") && line.contains("\\footnote{Two}"))
        #expect(!line.contains("\\cite{x}"))
        // The editing line shows its source.
        #expect(drawn(tex, at: ns.range(of: "See")).allSatisfy { !$0.hasPrefix("\\ref") && !$0.hasPrefix("\\eqref") })
    }

    @Test func chaptersAppendixAndBookCountersNumberWithinChapters() {
        let tex = "\\documentclass{book}\n\\begin{document}\n\\chapter{A}\\begin{equation}\\label{e1}\\end{equation}\n\\chapter{B}\\section{S}\\label{s}\\begin{table}\\caption{T}\\label{t}\\end{table}\\begin{equation}\\label{e2}\\end{equation}\n\\appendix\\chapter{X}\\label{app}\n\\end{document}"
        let labels = LaTeXMixedPresentation.labels(in: tex, quiet: [])
        #expect(labels["e1"]?.number == "1.1")
        #expect(labels["e2"]?.number == "2.1")
        #expect(labels["s"]?.number == "2.1")
        #expect(labels["t"]?.number == "2.1")
        #expect(labels["app"]?.number == "A")
    }

    @Test func staysLiteralInVerbatimCommentsAndMath() {
        let tex = "\\documentclass{article}\n\\begin{document}\n\\section{S}\\label{s}\n\\begin{verbatim}\n\\begin{itemize}\n\\item x \\ref{s} \\cite{k}\n\\end{itemize}\n\\end{verbatim}\n% \\ref{s} \\cite{k} \\footnote{c}\n$\\ref{s}$\nSee \\ref{s}.\n\\end{document}"
        let ns = tex as NSString
        let decor = MixedPresentation.layout(in: tex, selection: NSRange(location: 0, length: 0), config: config(),
                                             elements: Set(MixedElement.allCases), width: 600)
        #expect(decor.glyphs.map(\.range) == [ns.range(of: "\\begin{document}"),
                                              ns.range(of: "\\ref{s}", options: .backwards, range: NSRange(location: 0, length: ns.length)),
                                              ns.range(of: "\\end{document}")])
        #expect(MixedElement.available(latex: true, text: tex).contains(.citations))
        #expect(!MixedElement.available(latex: true, text: "\\documentclass{article}\nPlain.").contains(.blocks))
    }

    @Test func labelsHideAwayFromTheCaretButNotInMath() {
        let tex = "\\section{Intro}\\label{sec:intro}\nText \\label{p}.\n$x \\label{m}$\nlast"
        let ns = tex as NSString
        func hidden(at location: Int) -> [String] {
            MarkerPresentation.hiddenSyntax(in: tex, selection: NSRange(location: location, length: 0), latex: true, elements: [.citations])
                .map { ns.substring(with: $0) }
        }
        #expect(hidden(at: ns.length) == ["\\label{sec:intro}", "\\label{p}"])
        #expect(hidden(at: 0) == ["\\label{p}"])
    }
}
