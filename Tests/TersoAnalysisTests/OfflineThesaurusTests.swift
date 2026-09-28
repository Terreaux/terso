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
}
