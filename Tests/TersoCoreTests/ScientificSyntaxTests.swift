// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import TersoCore

@Suite struct ScientificSyntaxTests {
    func syntax(_ text: String) -> ScientificSyntax { ScientificSyntax(DocumentSnapshot(revision: DocumentRevision(9), text: text)) }

    @Test func linkTargetsDoNotStartMathOrComments() {
        let text = #"""
        🧪 [Visible $q_T$](images/$s_!a!,w_1456%2Fplot_(1).png "Title") and $p_L$.
        ![](https://example.com/$s_!b!,c_limit%2Fimage.png)
        <https://example.com/$s_!c!,q_auto> then $m_t$.
        https://example.com/$s_!d!,f_auto then $k_T$.
        `https://example.com/$s_!e!` remains code.
        """#
        let s = syntax(text)
        #expect(s.regions.filter { $0.kind == .inlineMath }.map(\.normalizedContent) == ["q_T", "p_L", "m_t", "k_T"])
        #expect(s.regions.filter { $0.kind == .linkDestination }.count == 4)
        #expect(s.regions.filter { $0.kind == .code }.count == 1)
        #expect(s.regions.map(\.rawText).joined() == text)
        #expect(s.maskedProse.utf16.count == text.utf16.count)
        #expect(s.maskedProse.contains("Visible"))
        for region in s.regions {
            #expect((text as NSString).substring(with: region.range.nsRange) == region.rawText)
        }
    }

    @Test func delimitersAndEnvironments() {
        let text = #"""
        We use $p_T$ and \(q_T\).
        $$a=b$$ \[c=d\]
        \begin{equation}x=1\end{equation}
        \begin{equation*}x=2\end{equation*}
        \begin{align}x&=3\end{align}
        \begin{align*}x&=4\end{align*}
        \begin{gather}x=5\end{gather}
        \begin{multline}x=6\end{multline}
        """#
        let s = syntax(text)
        #expect(s.regions.filter { $0.kind == .inlineMath }.count == 2)
        #expect(s.regions.filter { $0.kind == .displayMath }.count == 8)
        #expect(s.regions.allSatisfy { $0.revision == DocumentRevision(9) })
        #expect(s.regions.map(\.rawText).joined() == text)
        #expect(s.maskedProse.utf16.count == text.utf16.count)
    }

    @Test func nestedCommandsKeepOnlyProseAndExactUnicodeOffsets() {
        let text = #"🧪 We \emph{really \textbf{utilize} these} tools\footnote{They work.} with $\frac{\partial\sigma}{\partial p_T}$; see \citep[see]{a,b}, \ref{fig:a} and \includegraphics{file.pdf}."#
        let p = ProseText(markdown: text)
        #expect(p.masked.contains("utilize"))
        #expect(p.masked.contains("They work."))
        #expect(!p.masked.contains("partial"))
        #expect(!p.masked.contains("file.pdf"))
        #expect(!p.masked.contains("citep"))
        let word = p.words.first { p.string($0) == "utilize" }
        #expect(word?.nsRange == (text as NSString).range(of: "utilize"))
        #expect(p.masked.utf16.count == text.utf16.count)
    }

    @Test func commentsEscapesAndCode() {
        let text = #"""
        Cost \$5 and $10. The effect is 2% for $p_T$.
        % Ignore \ref{missing} and $q_T$.
        Literal \% is visible.
        ````latex
        ```
        $q_T$ \ref{missing}
        ````
        Inline `$q_T$` is code.
        Final prose is analyzed.
        """#
        let s = syntax(text)
        #expect(s.regions.filter { $0.kind == .inlineMath }.count == 1)
        #expect(s.regions.filter { $0.kind == .code }.count == 2)
        #expect(ProseText(markdown: text).masked.contains("Final prose is analyzed."))
        #expect(!s.maskedProse.contains("Ignore"))
        #expect(s.maskedProse.contains("2% for"))
        #expect(s.maskedProse.contains("% is visible"))
    }

    @Test func incompleteMathRecoversAndDoesNotLeakMacros() {
        let text = #"""
        A $\frac{a}{b} unfinished
        Normal prose here.
        \[\partial q
        """#
        let s = syntax(text)
        #expect(s.maskedProse.contains("Normal prose here."))
        #expect(!s.maskedProse.contains("frac"))
        #expect(!s.maskedProse.contains("partial"))
        #expect(s.regions.map(\.rawText).joined() == text)
    }

    @Test func figureContentIsProseAndCommentedMathClosingIgnored() {
        let text = #"""
        \begin{figure}\caption{A useful measurement.}\label{fig:a}\end{figure}
        \begin{equation}
        x=1 % \end{equation}
        y=2
        \end{equation}
        Final prose.
        """#
        let s = syntax(text)
        #expect(s.maskedProse.contains("A useful measurement."))
        #expect(!s.maskedProse.contains("y=2"))
        #expect(s.maskedProse.contains("Final prose."))
    }
    @Test func wrappedInlineMathAndMalformedCommand() {
        let text = "Wrapped $p_T >\n200\\,\\mathrm{GeV}$ remains prose.\n\\unknown{unfinished syntax\nNormal prose."
        let p = ProseText(markdown: text)
        #expect(!p.masked.contains("GeV"))
        #expect(!p.masked.contains("unfinished"))
        #expect(p.masked.contains("Normal prose."))
        #expect(p.masked.contains("remains prose."))
    }

}
