// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import Testing
import TersoCore
@testable import TersoApp

@Suite @MainActor struct LaTeXTableTests {
    @Test func columnSpecsSetAlignment() {
        #expect(LaTeXTable.alignments("|l|c|r|") == [.left, .center, .right])
        #expect(LaTeXTable.alignments("@{}l p{3cm} >{\\bfseries}m{2em} X@{}") == [.left, .left, .left, .left])
        #expect(LaTeXTable.alignments("*{2}{c}|r") == [.center, .center, .right])
        #expect(LaTeXTable.alignments("lLc") == nil)
        #expect(LaTeXTable.alignments("p") == nil)
        let x = MarkdownTable(latex: "\\begin{tabularx}{\\textwidth}{@{\\extracolsep{\\fill}}lX}\na & b \\\\\n\\end{tabularx}")
        #expect(x?.alignments == [.left, .left])
        let star = MarkdownTable(latex: "\\begin{tabular*}{0.9\\linewidth}[t]{rc}\n1 & 2\n\\end{tabular*}")
        #expect(star?.alignments == [.right, .center])
        #expect(star?.rows == [["1", "2"]])
    }

    @Test func booktabsRuleSetsTheHeaderApart() {
        let source = """
        \\begin{tabular}{@{}lrc@{}}
        \\toprule
        \\textbf{Name} & Share & \\emph{Note} \\\\
        \\midrule
        Alpha & 50\\% & a~b \\\\ % a comment & not a cell
        Beta & 1--2 & $x_1$ \\\\
        \\bottomrule
        \\end{tabular}
        """
        let table = MarkdownTable(latex: source)
        #expect(table?.headed == true)
        #expect(table?.header == ["**Name**", "Share", "*Note*"])
        #expect(table?.alignments == [.left, .right, .center])
        #expect(table?.rows.first == ["Alpha", "50%", "a b"])
        #expect(table?.rows.last == ["Beta", "1–2", "$x\\_1$"])
        // A rule under every row says nothing about a header; no rules at all neither.
        let grid = MarkdownTable(latex: "\\begin{tabular}{|l|l|}\\hline a & b \\\\ \\hline c & d \\\\ \\hline e & f \\\\ \\hline\\end{tabular}")
        #expect(grid?.headed == false)
        #expect(grid?.rows == [["a", "b"], ["c", "d"], ["e", "f"]])
        let plain = MarkdownTable(latex: "\\begin{tabular}{ll} a & b \\\\ c & d \\end{tabular}")
        #expect(plain?.headed == false)
        let hline = MarkdownTable(latex: "\\begin{tabular}{ll}\\hline H & I \\\\ \\hline\\hline a & b \\\\ \\hline c & d \\\\ \\hline\\end{tabular}")
        #expect(hline?.header == ["H", "I"])
        #expect(hline?.rows == [["a", "b"], ["c", "d"]])
    }

    @Test func escapesRowEndsAndSpans() {
        let table = MarkdownTable(latex: """
        \\begin{tabular}{lll}
        Q \\& A & \\texttt{a_b} & {x & y} \\\\[2pt]
        \\multicolumn{2}{c}{Both} & z \\\\*
        \\cline{1-2}
        one\\\\two & \\cite{k} & ``q''
        \\end{tabular}
        """)
        #expect(table?.headed == false)
        // `\\` ends a row wherever it falls outside braces; it never splits a cell.
        #expect(table?.rows == [
            ["Q \\& A", "`a_b`", "x \\& y"],
            ["Both", "", "z"],
            ["one"],
            ["two", "\\\\cite{k}", "“q”"],
        ])
    }

    @Test func unclearTablesStayAsSource() {
        // Unknown column type, too many cells, nested environment, unbalanced braces, no end, a caption.
        #expect(MarkdownTable(latex: "\\begin{tabular}{L}a\\end{tabular}") == nil)
        #expect(MarkdownTable(latex: "\\begin{tabular}{l}a & b\\end{tabular}") == nil)
        #expect(MarkdownTable(latex: "\\begin{tabular}{l}\\begin{tabular}{l}a\\end{tabular}\\end{tabular}") == nil)
        #expect(MarkdownTable(latex: "\\begin{tabular}{l}{a\\end{tabular}") == nil)
        #expect(MarkdownTable(latex: "\\begin{tabular}{l}a \\\\ b") == nil)
        #expect(MarkdownTable(latex: "\\begin{longtable}{l}\\caption{T}\\\\ a\\end{longtable}") == nil)
        #expect(MarkdownTable(latex: "\\begin{tabular}{l}\\hline\\end{tabular}") == nil)
        #expect(MarkdownTable(latex: "\\begin{array}{l}a\\end{array}") == nil)
    }

    @Test func mixedDrawsTabularAwayFromTheCaret() {
        let tex = """
        \\documentclass{article}
        \\begin{document}
        \\begin{table}
          \\centering
          \\begin{tabular}{lr}
            \\toprule
            A & B \\\\ \\midrule
            1 & 2 \\\\
            \\bottomrule
          \\end{tabular}
          \\caption{Numbers}
        \\end{table}
        % \\begin{tabular}{l} c \\end{tabular}
        \\begin{verbatim}
        \\begin{tabular}{l} v \\end{tabular}
        \\end{verbatim}
        End
        \\end{document}
        """
        let ns = tex as NSString
        let model = WorkspaceModel()
        var config = EditorConfig(prefs: model.prefs, model: model, latex: true)
        config.renderMode = .mixed
        let tabular = ns.range(of: "\\begin{tabular}{lr}")
        let whole = NSRange(location: tabular.location, length: NSMaxRange(ns.range(of: "\\end{tabular}")) - tabular.location)
        #expect(MixedPresentation.latexTableRanges(in: tex) == [whole])
        let away = MixedPresentation.layout(in: tex, selection: NSRange(location: ns.range(of: "End").location, length: 0),
                                            config: config, elements: Set(MixedElement.allCases), width: 600)
        #expect(away.glyphs.filter(\.reservesHeight).map(\.range) == [whole])
        // On any of its lines the whole environment is source again; the caption never is drawn.
        let onRow = MixedPresentation.layout(in: tex, selection: ns.range(of: "1 & 2"), config: config, elements: Set(MixedElement.allCases), width: 600)
        #expect(!onRow.glyphs.contains { $0.range == whole })
        let onCaption = MixedPresentation.layout(in: tex, selection: ns.range(of: "Numbers"), config: config, elements: Set(MixedElement.allCases), width: 600)
        #expect(onCaption.glyphs.filter(\.reservesHeight).map(\.range) == [whole])
        #expect(MixedPresentation.layout(in: tex, selection: NSRange(location: 0, length: 0), config: config, elements: [.math], width: 600).glyphs.isEmpty)
        #expect(MixedElement.available(latex: true, text: tex).contains(.tables))
        #expect(!MixedElement.available(latex: true, text: "\\documentclass{article}\nText").contains(.tables))
        let image = MixedPresentation.tableImage(MarkdownTable(latex: ns.substring(with: whole))!, config: config, width: 600)
        #expect(image.size.width > 0 && image.size.height > 0)
    }
}
