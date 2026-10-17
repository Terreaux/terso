// SPDX-License-Identifier: AGPL-3.0-only
import Testing
import TersoAnalysis
import TersoStyle
@testable import TersoApp

@Suite struct AnalysisRuleAssemblyTests {
    @Test @MainActor func scienceDefaultsToGeneralForNewDocument() {
        #expect(WorkspaceModel().scienceProfile.id == "general")
        #expect(WritingAnalyzer(enabling: []).profile.id == "general")
    }

    @Test func fictionAndOptionalAdviceComposeWithoutChangingOtherRegisters() {
        let enabled: Set<String> = ["style.sincerity", "style.negatedSetup"]
        let fiction = Set(analysisRules(domain: .fiction, optionalRuleIDs: enabled).map(\.id))
        #expect(fiction.contains("story.bookend"))
        #expect(fiction.contains("story.moral"))
        #expect(fiction.contains("story.similes"))
        #expect(fiction.contains("style.sincerity"))
        #expect(fiction.contains("style.negatedSetup"))

        let general = Set(analysisRules(domain: .general, optionalRuleIDs: enabled).map(\.id))
        #expect(!general.contains("story.bookend"))
        #expect(general.contains("style.sincerity"))

        let disabled = Set(analysisRules(domain: .fiction, optionalRuleIDs: []).map(\.id))
        #expect(!disabled.contains("style.sincerity"))
        #expect(disabled.contains("story.bookend"))
    }
}
