// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
import TersoCore
@testable import TersoAnalysis

@Suite struct ScientificDebuggerTests {
    private func analyze(_ text: String, profile: ScientificProfile = .hep) -> LocalAnalysisResult {
        WritingAnalyzer(profile: profile).analyze(DocumentSnapshot(revision: DocumentRevision(71), text: text))
    }

    @Test func operatorsAreNotNotationObjects() {
        let model = analyze(#"$a \to b \rightarrow c \Rightarrow d \in S$, $\sin x + \cos y + \max z$, $\operatorname{Tr} M$, $\sum_i q_i$."#).science
        let symbols = Set(model.symbols.map(\.canonicalForm))
        #expect(symbols.contains("a"))
        #expect(symbols.contains("q_i"))
        #expect(symbols.isDisjoint(with: [#"\to"#, #"\rightarrow"#, #"\Rightarrow"#, #"\in"#, #"\sin"#, #"\cos"#, #"\max"#, #"\operatorname"#, #"\sum_i"#, "T", "r"]))
    }

    @Test func explicitDefinitionPhrasesAndPriorUsage() throws {
        let text = #"We inspect $r_T$. Let $r_T$ denote the recoil ratio. We define $m_H$ as the Higgs mass. The $v_T$ is defined as the transverse velocity. Here $w_T$, where $w_T$ is the weight, enters the fit."#
        let model = analyze(text).science
        for key in ["r_T", "m_H", "v_T", "w_T"] {
            let symbol = try #require(model.symbols.first { $0.id == key })
            #expect(!symbol.definitions.isEmpty, "Definition missing for \(key)")
        }
        let recoil = try #require(model.symbols.first { $0.id == "r_T" })
        let definition = try #require(recoil.definitions.first)
        #expect(recoil.firstOccurrence.location < definition.location)
    }

    @Test func uncertaintyQuantityBindingAndUnicodeSource() throws {
        let text = #"🧪 The measured $m_H = 125.25 \pm 0.17\,\mathrm{GeV}$ agrees with $m_H = 125.25 ± 0.17$ GeV."#
        let quantities = analyze(text).science.quantities
        #expect(quantities.count == 2)
        for quantity in quantities {
            #expect(quantity.symbol == "m_H")
            #expect(quantity.numericValue == 125.25)
            #expect(quantity.uncertainty == 0.17)
            #expect(quantity.normalizedUnit == "GeV")
            #expect((text as NSString).substring(with: quantity.sourceRange.nsRange) == quantity.rawText)
        }
    }

    @Test func realisticDebuggerFixturePreservesRanges() throws {
        let url = try #require(Bundle.module.url(forResource: "scientific-debugger", withExtension: "md", subdirectory: "Fixtures"))
        let text = try String(contentsOf: url, encoding: .utf8)
        let result = analyze(text)
        #expect(result.science.quantities.contains { $0.symbol == "m_H" && $0.uncertainty == 0.17 })
        #expect(result.issues.contains { $0.ruleID == "science.references.duplicate" })
        #expect(result.issues.contains { $0.ruleID == "science.references.missing" })
        let ns = text as NSString
        for symbol in result.science.symbols {
            for range in symbol.occurrences {
                #expect(range.location >= 0 && range.upperBound <= ns.length)
                #expect(!ns.substring(with: range.nsRange).isEmpty)
            }
        }
        for claim in result.science.claims {
            #expect(ns.substring(with: claim.sourceRange.nsRange) == claim.text)
        }
        for issue in result.issues {
            #expect(ns.substring(with: issue.ranges[0].nsRange) == issue.originalText)
        }
    }
    @Test func authorExperienceDoesNotBecomeUnsupportedScientificFact() throws {
        let text = "In practice, I find this proves useful.\n\nWe compute the acceptance using simulated events.\n\nThis proves the approximation."
        let result = analyze(text)
        let personal = try #require(result.science.claims.first { $0.text.hasPrefix("In practice") })
        #expect(personal.type == .authorStatement)
        #expect(result.science.claims.contains { $0.type == .methodological })
        let evidenceWarnings = result.issues.filter { $0.ruleID == "science.evidence.strong" }
        #expect(evidenceWarnings.count == 1)
        #expect(evidenceWarnings.first?.originalText == "This proves the approximation.")
    }

    @Test func sharedGraphHasResolvableRelationshipsAndOrderedDiagnostics() throws {
        let url = try #require(Bundle.module.url(forResource: "scientific-debugger", withExtension: "md", subdirectory: "Fixtures"))
        let text = try String(contentsOf: url, encoding: .utf8)
        let model = analyze(text).science
        let ids = Set(model.nodes.map(\.id))
        #expect(ids.count == model.nodes.count)
        #expect(!model.relationships.isEmpty)
        #expect(model.relationships.allSatisfy { ids.contains($0.sourceID) && ids.contains($0.targetID) })
        #expect(model.diagnostics.allSatisfy { !$0.relatedObjectIDs.isEmpty && $0.relatedObjectIDs.allSatisfy(ids.contains) })
        #expect(model.relationships.contains { $0.kind == .defines })
        #expect(model.relationships.contains { $0.kind == .uses })
        #expect(model.relationships.contains { $0.kind == .represents })
        #expect(model.relationships.contains { $0.kind == .references })
        #expect(model.equations.count == 2)
        #expect(model.equations.allSatisfy { $0.label == "eq:acceptance" && !$0.references.isEmpty })
        #expect(model.equations.allSatisfy { !$0.dimensionCheckAvailable })
        #expect(model.diagnostics.contains { $0.category == .equations && $0.title.contains("Duplicate") })
        #expect(model.diagnostics.contains { $0.title == "Broken reference: eq:missing" && $0.confidence == .high })
        #expect(model.diagnostics.contains { [.claims, .evidence].contains($0.category) && $0.confidence == .low && $0.severity != .error })
        for (previous, next) in zip(model.diagnostics, model.diagnostics.dropFirst()) {
            #expect(previous.severity.order <= next.severity.order)
            if previous.severity == next.severity { #expect(previous.sourceRange.location <= next.sourceRange.location) }
        }
        for node in model.nodes {
            #expect(node.sourceRange.location >= 0 && node.sourceRange.upperBound <= text.utf16.count)
        }
        let roundTrip = try JSONDecoder().decode(ScientificDocumentModel.self, from: JSONEncoder().encode(model))
        #expect(roundTrip.relationships == model.relationships)
        #expect(roundTrip.diagnostics == model.diagnostics)
    }

    @Test func definitionAndAssumedKnowledgeRemainDistinct() throws {
        let model = analyze(#"We inspect $r_T$. Let $r_T$ denote the recoil ratio. Here $x$ is conventional; $q_T$ occurs with $q_T$ and $q_T$."#).science
        let definition = try #require(model.definitions.first { $0.term == "r_T" })
        #expect(definition.usedBeforeDefinition)
        let conventional = try #require(model.symbols.first { $0.id == "x" })
        #expect(model.definitionStatus(for: conventional) == .assumedKnowledge)
        let undefined = try #require(model.symbols.first { $0.id == "q_T" })
        #expect(model.definitionStatus(for: undefined) == .undefined)
        #expect(model.diagnostics.contains { $0.category == .definitions && $0.relatedObjectIDs.contains("symbol:r_T") })
        #expect(model.diagnostics.contains { $0.category == .notation && $0.confidence == .low })
    }

    @Test func citationSupportRemainsProximityNotSemanticProof() throws {
        let model = analyze(#"This demonstrates agreement; see \cite{atlas2024}."#).science
        let claim = try #require(model.claims.first)
        #expect(model.citations.count == 1)
        #expect(model.crossReferences.isEmpty)
        #expect(model.relationships.contains { $0.sourceID == claim.objectID && $0.kind == .cites })
        #expect(model.relationships.contains { $0.sourceID == claim.objectID && $0.kind == .nearbyEvidence })
        #expect(!model.diagnostics.contains { $0.category == .claims })
        #expect(claim.confidence == .low)
    }

    @Test func localBibliographyAllowsMissingKeyCheckWithoutAssumingExternalCompleteness() {
        let citations = #"The result cites \cite{known,missing}."#
        let local = analyze(citations + #"\begin{thebibliography}{9}\bibitem{known} Known result.\end{thebibliography}"#).science
        #expect(local.diagnostics.filter { $0.id.hasPrefix("science.references.citation:") }.count == 1)
        #expect(local.diagnostics.contains { $0.title == "Citation missing from local bibliography: missing" })
        #expect(!analyze(citations).science.diagnostics.contains { $0.id.hasPrefix("science.references.citation:") })
        let external = analyze(citations + #"\bibitem{known} Known result. \addbibresource{references.bib}"#).science
        #expect(!external.diagnostics.contains { $0.id.hasPrefix("science.references.citation:") })
    }

    @Test func multipleKeysAtOneSourceLocationKeepUniqueDiagnosticIDs() {
        let model = analyze(#"See \cref{eq:absent,fig:absent} and \cite{missingA,missingB}. \bibitem{known} Known citation."#).science
        let broken = model.diagnostics.filter { $0.title.hasPrefix("Broken reference:") || $0.title.hasPrefix("Citation missing from local bibliography:") }
        #expect(broken.count == 4)
        #expect(Set(broken.map(\.id)).count == 4)
        #expect(Set(model.nodes.map(\.id)).count == model.nodes.count)
        #expect(broken.allSatisfy { diagnostic in diagnostic.relatedObjectIDs.allSatisfy { model.node(id: $0) != nil } })
    }

    @Test func separateSentenceCitationIsOnlyNearbyEvidence() throws {
        let model = analyze(#"This proves the approximation. Earlier measurements cite \cite{atlas}."#).science
        let claim = try #require(model.claims.first)
        #expect(model.relationships.contains { $0.sourceID == claim.objectID && $0.kind == .nearbyEvidence })
        #expect(!model.relationships.contains { $0.sourceID == claim.objectID && $0.kind == .cites })
    }

    @Test func overlappingClaimSignalsProduceOneReviewableClaim() throws {
        let model = analyze("We compute a smaller correction that proves the approximation.").science
        #expect(model.claims.count == 1)
        #expect(model.claims.first?.type == .strongConclusion)
        #expect(model.diagnostics.filter { $0.category == .evidence }.count == 1)
    }

    @Test func frontMatterEquationsStayExcluded() {
        let model = analyze("---\ntitle: |\n  $$q = 2$$\n---\n\nActual prose.").science
        #expect(model.equations.isEmpty)
        #expect(model.symbols.isEmpty)
    }

    @Test func largeScientificDocumentRemainsBounded() {
        let paragraph = #"We compute $p_T$ at $\sqrt{s}=13.6\,\mathrm{TeV}$. The correction is below 2% as shown in \ref{fig:result}. We use the same numerical setup for each run."#
        let text = (0..<600).map { "## Section \($0)\n\n" + paragraph }.joined(separator: "\n\n") + #"\label{fig:result}"#
        let elapsed = ContinuousClock().measure {
            let model = analyze(text).science
            #expect(model.claims.count == 1800)
            #expect(model.quantities.count == 1200)
        }
        print("Science scale: \(text.utf16.count) UTF-16 units analyzed in \(elapsed)")
        #expect(elapsed < .seconds(8))
    }

    @Test func priorUseAnnotationDoesNotUnderlineUnrelatedDefinitionProse() throws {
        let result = analyze(#"We inspect $r_T$. Let $r_T$ denote recoil. An unrelated sentence follows. Later $r_T$ is used."#)
        let symbol = try #require(result.science.symbols.first { $0.id == "r_T" })
        let issue = try #require(result.issues.first { $0.ruleID == "science.notation.undefined" })
        #expect(issue.ranges.count == 2)
        #expect(issue.ranges.allSatisfy { symbol.occurrences.contains($0) })
        #expect(!issue.ranges.contains(symbol.occurrences.last!))
    }

    @Test func unitNamesCanAlsoBeScientificVariables() throws {
        let model = analyze(#"Let $m$ denote mass. The $s$ and $b$ variables occur here. Length is $3 m$ and time is $2 s$."#).science
        let mass = try #require(model.symbols.first { $0.id == "m" })
        #expect(mass.occurrences.count == 1)
        #expect(mass.definitions.count == 1)
        #expect(model.symbols.first { $0.id == "s" }?.occurrences.count == 1)
        #expect(model.symbols.contains { $0.id == "b" })
        #expect(model.quantities.contains { $0.numericValue == 3 && $0.normalizedUnit == "m" })
    }

}
