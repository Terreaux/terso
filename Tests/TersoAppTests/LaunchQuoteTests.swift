// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import TersoApp

@Suite struct LaunchQuoteTests {
    @Test func consecutiveLaunchesNeverRepeatAQuote() throws {
        let defaults = try #require(UserDefaults(suiteName: "LaunchQuoteTests.\(UUID())"))
        var previous = WritingQuote.next(defaults: defaults)
        for _ in 0..<50 {
            let quote = WritingQuote.next(defaults: defaults)
            #expect(quote != previous)
            previous = quote
        }
    }

    @Test func everyQuoteIsAttributed() {
        #expect(WritingQuote.all.count > 1)
        #expect(WritingQuote.all.allSatisfy { !$0.text.isEmpty && !$0.author.isEmpty })
    }
}
