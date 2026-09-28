// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
import TersoCore
@testable import TersoAnalysis

@Suite struct ScientificTests {
    func analyze(_ text: String, profile: ScientificProfile = .hep) -> LocalAnalysisResult {
        WritingAnalyzer(profile: profile).analyze(DocumentSnapshot(revision: DocumentRevision(42), text: text))
    }

    @Test func realisticManuscript() throws {
        let url = try #require(Bundle.module.url(forResource: "manuscript", withExtension: "md", subdirectory: "Fixtures"))
        let text = try String(contentsOf: url, encoding: .utf8)
        let result = analyze(text)
        let science = result.science
        #expect(result.issues.contains { $0.ruleID == "science.quantities.changed" })
        #expect(result.issues.contains { $0.ruleID == "science.notation.undefined" && $0.originalText == "q_T" })
        #expect(result.issues.contains { $0.ruleID == "science.notation.variants" })
        #expect(result.issues.filter { $0.ruleID == "science.references.missing" }.count == 1)
        #expect(result.issues.contains { $0.ruleID == "science.evidence.strong" })
        #expect(science.symbols.first { $0.id == "p_T" }?.occurrences.count == 2)
        #expect(science.objects.first?.caption == "Transverse-momentum distribution at NNLO.")
        #expect(science.objects.first?.imagePath == "spectrum.pdf")
        #expect(science.objects.first?.references.first?.section == "Results")
        #expect(science.symbols.first { $0.id == "q_T" }?.definitions.count == 1)
        #expect(science.claims.contains { $0.type == .quantitative && $0.nearbyEvidence.contains { $0.text == "fig:spectrum" } })
        #expect(science.claims.first { $0.type == .strongConclusion }?.section == "Conclusion")
        #expect(!science.quantities.contains { $0.numericValue == 999 })
        for issue in result.issues {
            #expect(issue.originalText == (text as NSString).substring(with: issue.ranges[0].nsRange))
            for r in issue.ranges { #expect(r.location >= 0 && r.upperBound <= text.utf16.count) }
        }
        #expect(result.annotations.allSatisfy { $0.revision == DocumentRevision(42) })
        let passages = ReviewGrouping.passages(result.annotations, sentences: ProseText(markdown: text).sentences.map(\.range))
        #expect(result.annotations.filter { $0.metadata["rule"]?.hasPrefix("science.") == true }.allSatisfy { a in passages.contains { $0.findingIDs.contains(a.id) } })
        let encoded = try JSONEncoder().encode(science)
        #expect(try JSONDecoder().decode(ScientificDocumentModel.self, from: encoded).revision == science.revision)
    }

    @Test func symbolsAreConservativeAndDefinitionsDetected() {
        let text = #"We define $q_T$ as recoil. The $q_{T}$ and $ q_T $ distributions use $p_T$, $p_\mathrm{T}$ and $p_L$. With $\mu_R$ the renormalization scale, $\mu_R$ varies. $m_t$ is the top-quark mass. $Q$ denotes the hard scale. $Q^2$ and $\alpha_s$ enter $\sqrt{s}$."#
        let model = analyze(text).science
        #expect(model.symbols.contains { $0.id == "q_T" && $0.occurrences.count >= 2 && $0.definitions.count == 1 })
        #expect(model.symbols.contains { $0.id == #"\mu_R"# && $0.definitions.count == 1 })
        #expect(model.symbols.contains { $0.id == "m_t" && $0.definitions.count == 1 })
        #expect(model.symbols.contains { $0.id == #"\sqrt{s}"# })
        #expect(model.symbols.contains { $0.id == "Q^2" })
        #expect(model.symbols.contains { $0.id == "p_L" })
        #expect(!model.symbols.contains { $0.id == "T" || $0.id == #"\mathrm"# })
        #expect(analyze("$x$ $x$ $x$ $x$").issues.filter { $0.category == .notation }.isEmpty)
        var profile = ScientificProfile.hep
        profile.commonSymbols.insert("q_T")
        #expect(!analyze("$q_T$ $q_T$ $q_T$", profile: profile).issues.contains { $0.ruleID == "science.notation.undefined" })
    }

    @Test func quantitiesAndUnits() {
        let text = #"We measure 13.6 TeV, 172.5 GeV, 25 GeV, 2.3%, 0.2 fb, $35\,\mathrm{fb}^{-1}$, $10^{-3}$, $1.2 \pm 0.3$, and 1.2 ± 0.3. The cut is $200,\mathrm{GeV}$ with $2.5\times10^{-3}\,\mathrm{pb}$ and 3e-4 nb."#
        let qs = analyze(text).science.quantities
        #expect(qs.contains { $0.numericValue == 13.6 && $0.normalizedUnit == "TeV" })
        #expect(qs.contains { $0.numericValue == 2.3 && $0.normalizedUnit == "%" })
        #expect(qs.contains { $0.numericValue == 35 && $0.normalizedUnit == "fb^{-1}" })
        #expect(qs.contains { $0.numericValue == 0.001 })
        #expect(qs.filter { $0.numericValue == 1.2 && $0.uncertainty == 0.3 }.count == 2)
        #expect(qs.contains { $0.numericValue == 200 && $0.normalizedUnit == "GeV" })
        #expect(qs.contains { $0.numericValue == 0.0025 && $0.normalizedUnit == "pb" })
        #expect(qs.contains { $0.numericValue == 0.0003 && $0.normalizedUnit == "nb" })
        for q in qs { #expect(q.rawText == (text as NSString).substring(with: q.sourceRange.nsRange)) }
    }

    @Test(arguments: ["", "*", "**", "_"])
    func proseIntroducesVertexListsAndWeightFunctions(wrapper: String) {
        func math(_ value: String) -> String { wrapper + "$" + value + "$" + wrapper }
        let text = "😀 In a weighted graph, every edge has a numerical score. We usually write the weight between vertices \(math("u")) and \(math("v")) as \(math("w(u, v)")).\n\n"
            + "In the puzzle setting, \(math("u")) and \(math("v")) are fragments, and \(math("w(u, v)")) is a mismatch score.\n\n"
            + "$w(u, v)$ and $w(u, v)$."
        let result = analyze(text, profile: .general)
        for name in ["u", "v", "w"] {
            let symbol = result.science.symbols.first { $0.id == name }
            #expect(symbol?.definitions.first == symbol?.occurrences.first)
            #expect(symbol?.definitions.isEmpty == false)
            for span in symbol?.definitions ?? [] {
                #expect((text as NSString).substring(with: span.nsRange) == name)
            }
            #expect(!result.issues.contains { $0.ruleID == "science.notation.undefined" && $0.originalText == name })
        }
    }

    @Test func proseDefinitionsDoNotLeakIntoArgumentsOrLaterSentences() {
        let text = "We write the score as $w(u, v)$. The vertices matter. $q$ and $r$ occur.\n\n$q$ $r$ $w(u, v)$ $q$ $r$ $w(u, v)$."
        let model = analyze(text, profile: .general).science
        #expect(model.symbols.first { $0.id == "w" }?.definitions.count == 1)
        for name in ["u", "v", "q", "r"] {
            #expect(model.symbols.first { $0.id == name }?.definitions.isEmpty == true)
        }
        let excluded = analyze("`vertices $q$ and $r$`\n\n$q$ $q$ $q$ $r$ $r$ $r$", profile: .general).science
        #expect(excluded.symbols.allSatisfy { $0.definitions.isEmpty })
    }

    @Test func comparisonsNeedSameExplicitSymbolAndUnit() {
        #expect(!analyze(#"The cuts are 25 GeV and 35 GeV. $m_t=172.5$ GeV and $m_b=4.8$ GeV."#).issues.contains { $0.category == .quantities })
        #expect(!analyze(#"$m_t=172.5$ GeV and $m_t=0.1725$ TeV."#).issues.contains { $0.category == .quantities })
        #expect(analyze(#"$m_t=172.5$ GeV and $m_t=173.5$ GeV."#).issues.contains { $0.ruleID == "science.quantities.changed" })
        #expect(!analyze(#"$m_t=172.50$ GeV and $m_t=172.5$ GeV."#).issues.contains { $0.category == .quantities })
    }

    @Test func referencesAndEvidenceBoundaries() {
        let text = #"""
        \section{Results}
        This demonstrates agreement; see \ref{fig:a} and \citep[see][p. 3]{one,two}.

        \begin{figure}\label{fig:a}\end{figure}
        \label{fig:a}
        \label{tab:unused}

        This proves the result.

        There are 25 GeV events in \ref{fig:absent}.
        """#
        let r = analyze(text)
        #expect(r.science.references.filter(\.isCitation).count == 2)
        #expect(r.issues.filter { $0.ruleID == "science.evidence.strong" }.count == 1)
        #expect(r.issues.contains { $0.ruleID == "science.references.duplicate" })
        #expect(r.issues.contains { $0.ruleID == "science.references.unused" && $0.severity == .info })
        #expect(r.science.claims.allSatisfy { $0.section == "Results" })
        #expect(analyze(#"This proves the result; see \ref{fig:absent}."#).issues.contains { $0.ruleID == "science.evidence.strong" })
    }

    @Test func allClaimCategoriesAndProfileConfiguration() {
        let text = "The correction is below 2%. The uncertainty is smaller. The predictions agree with the measurement. This reduction results from cancellation. We present the first calculation. This establishes a result."
        #expect(Set(analyze(text).science.claims.map(\.type)).count == 6)
        var profile = ScientificProfile.general
        profile.disabledRules = ["science.claims", "science.evidence"]
        #expect(!analyze(text, profile: profile).issues.contains { $0.category == .claims || $0.category == .evidence })
    }
    @Test func escapedPercentAndInverseUnits() {
        let qs = analyze(#"The error is 2.3\% with $35\,\mathrm{fb^{-1}}$ and $20\,\mathrm{pb}^{-1}$."#).science.quantities
        #expect(qs.contains { $0.numericValue == 2.3 && $0.normalizedUnit == "%" })
        #expect(qs.contains { $0.numericValue == 35 && $0.normalizedUnit == "fb^{-1}" })
        #expect(qs.contains { $0.numericValue == 20 && $0.normalizedUnit == "pb^{-1}" })
    }

    @Test func microbarnAliases() {
        let qs = analyze(#"We measure 2 μb, 2 µb, $2\mu b$ and $2\mu\mathrm{b}$."#).science.quantities
        #expect(qs.filter { $0.numericValue == 2 && $0.normalizedUnit == "μb" }.count == 4)
    }

    @Test func excludedRegionsDoNotCreateScientificObjects() {
        let text = #"""
        ---
        title: '$q_T = 99\mathrm{GeV}$ \label{fake}'
        ---
        % \label{comment} $q_T=98\mathrm{GeV}$
        ```tex
        \label{code} $q_T=97\mathrm{GeV}$
        ```
        Here is `$q_T=96\mathrm{GeV}$` and actual $p_T=25\mathrm{GeV}$.
        """#
        let m = analyze(text).science
        #expect(m.objects.isEmpty)
        #expect(!m.symbols.contains { $0.id == "q_T" })
        #expect(m.quantities.map(\.numericValue) == [25])
    }

    @Test func revisionRangesAndDismissals() throws {
        let text = "🧪 Results\r\n\r\nThis proves the approximation.\r\n"
        let before = analyze(text)
        let issue = try #require(before.annotations.first { $0.category == .evidence })
        #expect((text as NSString).substring(with: issue.ranges[0].nsRange) == "This proves the approximation.")
        let after = WritingAnalyzer().analyze(DocumentSnapshot(revision: DocumentRevision(43), text: "New preface.\n\n" + text))
        let next = try #require(after.annotations.first { $0.category == .evidence })
        #expect(issue.dismissalKey == next.dismissalKey)
        #expect(issue.revision != next.revision)
        #expect(next.ranges[0].location == issue.ranges[0].location + 14)
        #expect(next.category.family == .writing)
        #expect(AnnotationLayout.isSentenceLevel(next))
    }

    @Test func manuscriptScale() {
        let paragraph = #"We compute $p_T$ at $\sqrt{s}=13.6\,\mathrm{TeV}$. The correction is below 2% as shown in \ref{fig:result}."#
        let text = (0..<80).map { "## Section \($0)\n\n" + paragraph }.joined(separator: "\n\n") + #"\label{fig:result}"#
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            let r = analyze(text)
            #expect(r.science.claims.filter { $0.type == .quantitative }.count == 80)
            #expect(r.science.quantities.count == 160)
        }
        #expect(elapsed < .seconds(5))
    }

    @Test func decoratedSymbolsRemainDistinct() {
        let symbols = analyze(#"The $p$, $\mathbf{p}$ and $\vec{p}$ conventions differ."#).science.symbols
        #expect(Set(symbols.map(\.canonicalForm)) == ["p", #"\mathbf{p}"#, #"\vec{p}"#])
    }

}
