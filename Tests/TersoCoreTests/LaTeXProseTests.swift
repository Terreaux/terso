// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import TersoCore

@Suite struct LaTeXProseTests {
    let paper = #"""
    \documentclass{article}
    \usepackage[utf8]{inputenc}
    \title{Hidden title words}
    \newcommand{\pt}{p_T}
    \begin{document}
    \maketitle

    \section{Introduction}
    We measure the cross section at $\sqrt{s} = 13$ TeV. It is \emph{small}.
    % A commented remark stays hidden.
    %\section{Dropped}

    \subsection*{The \textit{fit} model}
    \begin{itemize}
      \item First point is here.
      \item[b)] Second point follows.
    \end{itemize}

    \begin{tabular}{ll}
    alpha & beta \\
    \end{tabular}
    \begin{verbatim}
    code words
    \end{verbatim}
    Closing prose remains~\cite{key}.
    \end{document}
    Trailing words after end.
    """#

    @Test func formatDetection() {
        #expect(SourceFormat.detect(text: "", fileName: "paper.tex") == .latex)
        #expect(SourceFormat.detect(text: "", fileName: "Paper.LATEX") == .latex)
        #expect(SourceFormat.detect(text: "\\documentclass{article}", fileName: "notes.md") == .markdown)
        #expect(SourceFormat.detect(text: "  \n\\documentclass{article}", fileName: nil) == .latex)
        #expect(SourceFormat.detect(text: "\\documentclass{article}", fileName: "Untitled") == .latex)
        #expect(SourceFormat.detect(text: "# Title", fileName: nil) == .markdown)
    }

    @Test func headingsFromSectioning() {
        let p = ProseText(latex: paper)
        #expect(p.headings.map(\.title) == ["Introduction", "The fit model"])
        #expect(p.headings.map(\.level) == [1, 2])
        let ns = paper as NSString
        #expect(ns.substring(with: p.headings[0].range.nsRange) == "\\section{Introduction}")
    }

    @Test func preambleEnvironmentsAndTrailerAreNotProse() {
        let p = ProseText(latex: paper)
        #expect(p.masked.utf16.count == paper.utf16.count)
        for hidden in ["Hidden", "inputenc", "alpha", "beta", "code", "Trailing", "commented", "Dropped"] {
            #expect(!p.masked.contains(hidden), "\(hidden) should be masked")
        }
        for visible in ["We measure the cross section", "small", "Closing prose remains"] {
            #expect(p.masked.contains(visible), "\(visible) should be prose")
        }
        #expect(p.codeBlockCount == 1)
    }

    @Test func itemsAreListBlocks() {
        let p = ProseText(latex: paper)
        let items = p.blocks.filter { $0.kind == .listItem }.map { p.string($0.range).trimmingCharacters(in: .whitespaces) }
        #expect(items.count == 2)
        #expect(items.allSatisfy { !$0.contains("\\item") })
        #expect(p.sentences.contains { p.string($0.range) == "First point is here." })
    }

    @Test func markdownRulesDoNotApplyToLaTeX() {
        let text = "# not a heading in TeX\n\nA | pipe and *stars* stay.\n"
        #expect(ProseText(latex: text).headings.isEmpty)
        #expect(ProseText(markdown: text).headings.count == 1)
        #expect(ProseText(latex: text).masked.contains("A | pipe"))
    }

    @Test func snapshotPicksFormatFromName() {
        let snap = DocumentSnapshot(revision: DocumentRevision(1), text: "\\section{Intro}\nText.\n", fileName: "chapter.tex")
        #expect(ProseText(snap).headings.map(\.title) == ["Intro"])
        let md = DocumentSnapshot(revision: DocumentRevision(1), text: "\\section{Intro}\nText.\n", fileName: "chapter.md")
        #expect(ProseText(md).headings.isEmpty)
    }

    @Test func bookLevelsStartAtChapter() {
        let p = ProseText(latex: "\\chapter{One}\n\\section{Two}\n\\subsection{Three}\n")
        #expect(p.headings.map(\.level) == [1, 2, 3])
    }
}
