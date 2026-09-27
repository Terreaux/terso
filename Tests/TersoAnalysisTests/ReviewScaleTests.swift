// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
import TersoCore
@testable import TersoAnalysis

/// A document with 50+ raw findings should present far fewer passages, fast.
@Suite struct ReviewScaleTests {
    @Test func fiftyPlusFindingsBecomeFewerPassages() {
        let para = "It is important to note that the results were very clearly able to demonstrate the effect that was expected by the team, and in order to utilize the data we basically needed to look at the the numbers. The experiment was conducted quickly. "
        let text = (1...12).map { "## Section \($0)\n\n" + para }.joined(separator: "\n\n")
        let result = WritingAnalyzer().analyze(DocumentSnapshot(revision: DocumentRevision(1), text: text))
        let annotations = result.annotations
        let sentences = ProseText(markdown: text).sentences.map(\.range)
        let clock = ContinuousClock()
        var passages: [ReviewPassage] = []
        let elapsed = clock.measure { passages = ReviewGrouping.passages(annotations, sentences: sentences) }
        print("findings: \(annotations.count), passages: \(passages.count), grouping: \(elapsed)")
        #expect(annotations.count >= 50)
        #expect(passages.count < annotations.count / 2)
        #expect(elapsed < .milliseconds(50))
        // Every finding lands in exactly one passage.
        let all = passages.flatMap(\.findingIDs)
        #expect(all.count == annotations.count && Set(all).count == annotations.count)
        // Navigation visits every passage once per cycle.
        let q = ReviewQueue(passages)
        var seen = Set<Int>(), cur: Int? = nil
        for _ in passages { cur = q.step(from: cur, caret: 0, offset: 1)?.id; seen.insert(cur!) }
        #expect(seen.count == passages.count)
    }
}
