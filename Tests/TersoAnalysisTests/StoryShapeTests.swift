// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
import TersoCore
@testable import TersoAnalysis

@Suite struct StoryShapeTests {
    func issues(_ text: String) -> [WritingIssue] {
        WritingAnalyzer(rules: StoryShape.rules).analyze(DocumentSnapshot(revision: DocumentRevision(1), text: text)).issues
    }

    // Enough story between the ends that the opening and the close are apart.
    let middle = (1...30).map { "On day \($0) the boats went out early and came back with nets half full, and nobody said much at supper." }

    @Test func endingThatBringsBackTheOpeningIsFlagged() {
        let text = (["The lantern hung in the lighthouse window, swinging in the salt wind."] + middle
            + ["She lit the lantern again and set it in the lighthouse window."]).joined(separator: "\n\n")
        let bookend = issues(text).filter { $0.ruleID == "story.bookend" }
        #expect(bookend.count == 1)
        #expect(bookend.first?.metadata["words"] == "lighthouse window")
    }

    @Test func openEndingIsQuiet() {
        let text = (["The lantern hung in the lighthouse window, swinging in the salt wind."] + middle
            + ["She washed the cups and went to bed early."]).joined(separator: "\n\n")
        #expect(!issues(text).contains { $0.ruleID == "story.bookend" })
    }

    @Test func repeatedCharacterNameIsNotAnOpeningImage() {
        let text = (["Leonard Bilsiter entered the drawing room."] + middle
            + ["Leonard Bilsiter left before supper."]).joined(separator: "\n\n")
        #expect(!issues(text).contains { $0.ruleID == "story.bookend" })
    }

    @Test func statedMoralNearTheEndIsFlagged() {
        let text = (["The lantern hung in the window."] + middle
            + ["She finally understood that grief was never about the house."]).joined(separator: "\n\n")
        let moral = issues(text).filter { $0.ruleID == "story.moral" }
        #expect(moral.count == 1)
    }

    @Test func literalUnderstandingNearTheEndIsNotAMoral() {
        let text = (["Jimmy sat at the card table."] + middle
            + ["Jimmy understood that the game lay between Routh and Ségouin."]).joined(separator: "\n\n")
        #expect(!issues(text).contains { $0.ruleID == "story.moral" })
    }

    @Test func similesBeyondTheAllowanceAreFlagged() {
        let filler = String(repeating: "The road went on past the farms and the fields were wide. ", count: 20)
        let similes = "Her voice was like a bell. The sky hung as if it were tired. The sea was as flat as a plate. He moved like a shadow."
        let found = issues(filler + "\n\n" + similes).filter { $0.ruleID == "story.similes" }
        #expect(found.first?.metadata["count"] == "4")
        // The verb is not a simile.
        #expect(issues(filler + "\n\nI would like a coffee. They like the sea. We like a quiet room.").allSatisfy { $0.ruleID != "story.similes" })
        let idioms = String(repeating: "As soon as the rain stopped, she left. As far as the road went, he followed. ", count: 5)
        #expect(!issues(filler + "\n\n" + idioms).contains { $0.ruleID == "story.similes" })
    }
}
