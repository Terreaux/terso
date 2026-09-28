// SPDX-License-Identifier: AGPL-3.0-only
import Testing
@testable import TersoAnalysis

struct OfflineThesaurusTests {
    @Test func bundledMeaningsAndCasePreservation() async throws {
        let senses = try await OfflineThesaurus.shared.lookup("Quick")
        #expect(!senses.isEmpty)
        #expect(senses.allSatisfy { !$0.definition.isEmpty && !$0.partOfSpeech.isEmpty })
        let alternatives = senses.flatMap { $0.alternatives(for: "Quick") }
        #expect(alternatives.contains("Speedy"))
        #expect(!alternatives.contains("Quick"))
        #expect(senses.flatMap { $0.alternatives(for: "QUICK") }.contains("SPEEDY"))
    }

    @Test func multiwordEntriesAndUnknownTerms() async throws {
        let senses = try await OfflineThesaurus.shared.lookup("at once")
        #expect(!senses.isEmpty)
        #expect(senses.flatMap { $0.alternatives(for: "at once") }.contains("immediately"))
        let unknown = try await OfflineThesaurus.shared.lookup("qxzfoobar")
        #expect(unknown.isEmpty)
    }

    /// Product-quality examples: useful choices must be visible in the first
    /// meaning, not merely present somewhere in a large list of associations.
    @Test(arguments: [
        ("explain", "clarify"), ("explain", "describe"), ("describe", "outline"),
        ("show", "display"), ("suggest", "propose"), ("use", "apply"),
        ("important", "significant"), ("improve", "refine"), ("change", "adjust"),
        ("discuss", "explore"), ("analyze", "examine"), ("method", "approach"),
        ("however", "nevertheless"), ("in order to", "to"), ("as a result", "consequently")
    ])
    func usefulFirstChoices(example: (String, String)) async throws {
        let senses = try await OfflineThesaurus.shared.lookup(example.0)
        let first = try #require(senses.first)
        #expect(first.alternatives(for: example.0).prefix(6).contains(example.1))
    }

    @Test func differentMeaningsStaySeparate() async throws {
        let senses = try await OfflineThesaurus.shared.lookup("explain")
        let first = try #require(senses.first)
        #expect(!first.words.contains("excuse"))
        #expect(!first.words.contains("justify"))
        #expect(senses.dropFirst().contains { $0.words.contains("justify") })
        #expect(first.words.count <= 7)
    }

    @Test func inflectedAlternativesPreserveGrammarAndCase() async throws {
        let past = try await OfflineThesaurus.shared.lookup("Explained")
        let alternatives = try #require(past.first).alternatives(for: "Explained")
        #expect(alternatives.contains("Clarified"))
        #expect(alternatives.contains("Spelled out"))
        #expect(!alternatives.contains("Clarify"))
        let ongoing = try await OfflineThesaurus.shared.lookup("describing")
        #expect(ongoing.first?.alternatives(for: "describing").contains("outlining") == true)
        let singular = try await OfflineThesaurus.shared.lookup("EXPLAINS")
        #expect(singular.first?.alternatives(for: "EXPLAINS").contains("CLARIFIES") == true)
    }

    @Test func dictionaryFallbackUsesMeaningOrderRatherThanFileOffsets() async throws {
        let senses = try await OfflineThesaurus.shared.lookup("observe")
        #expect(senses.first?.words.contains("notice") == true)
        #expect(senses.first?.ranks?["observe"] == 1)
        #expect(senses.allSatisfy { !$0.id.hasPrefix("writing.") })
    }

}
