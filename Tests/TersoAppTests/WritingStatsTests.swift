// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import TersoApp

@Suite struct TypedWordsTests {
    @Test func aLetterAfterASpaceStartsAWord() {
        #expect(TypedWords.count("h", before: " ", after: nil) == 1)
        #expect(TypedWords.count("h", before: nil, after: nil) == 1)
    }

    @Test func typingInsideAWordAddsNothing() {
        #expect(TypedWords.count("e", before: "h", after: nil) == 0)
        #expect(TypedWords.count("t", before: "n", after: "'") == 0)
        #expect(TypedWords.count("x", before: " ", after: "c") == 0, "a prefix onto an existing word")
    }

    @Test func punctuationAndSpacesAreNotWords() {
        #expect(TypedWords.count(" ", before: "a", after: nil) == 0)
        #expect(TypedWords.count("*", before: " ", after: nil) == 0)
    }

    @Test func dictatedPhrasesCountEachWord() {
        #expect(TypedWords.count("the quick brown fox", before: " ", after: nil) == 4)
        #expect(TypedWords.count("don't stop, well-known", before: nil, after: nil) == 3)
        #expect(TypedWords.count("and more", before: " ", after: "s") == 1, "the last word joins the next")
    }
}

@Suite @MainActor struct WritingStatsTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func day(_ d: Int, hour: Int = 10, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: d, hour: hour, minute: minute))!
    }

    @Test func recordsDaysHoursAndDocuments() {
        let stats = WritingStats(fileURL: nil)
        let url = URL(fileURLWithPath: "/tmp/story.md")
        stats.record(3, in: url, at: day(1), calendar: calendar)
        stats.record(2, in: nil, at: day(1, minute: 1), calendar: calendar)
        #expect(stats.log.words(on: day(1), calendar: calendar) == 5)
        #expect(stats.log.hours[10] == 5)
        #expect(stats.typed(in: url) == 3)
        #expect(stats.log.lifetime == 5)
    }

    @Test func aLongPauseEndsASitting() {
        let stats = WritingStats(fileURL: nil)
        stats.record(300, in: nil, at: day(1, minute: 0), calendar: calendar)
        stats.record(300, in: nil, at: day(1, minute: 4), calendar: calendar)
        stats.record(100, in: nil, at: day(1, minute: 20), calendar: calendar)
        #expect(stats.log.bestSitting == 600)
    }

    @Test func streaksSurviveUntilTheDayIsOver() {
        var log = WritingLog()
        for d in [1, 2, 3, 5, 6] { log.days[WritingLog.key(day(d), calendar: calendar)] = 150 }
        #expect(log.longestStreak == 3)
        #expect(log.currentStreak(at: day(6), calendar: calendar) == 2)
        #expect(log.currentStreak(at: day(7), calendar: calendar) == 2, "today isn't over yet")
        #expect(log.currentStreak(at: day(8), calendar: calendar) == 0)
    }

    @Test func awardsAreEarnedOnceAndKept() {
        let stats = WritingStats(fileURL: nil)
        stats.record(100, in: nil, at: day(1), calendar: calendar)
        let first = stats.log.earned["len100"]
        #expect(first != nil)
        stats.record(500, in: nil, at: day(1, minute: 2), calendar: calendar)
        #expect(stats.log.earned["len100"] == first)
        #expect(stats.log.earned["day500"] != nil)
        #expect(stats.log.earned["sit500"] != nil)
        #expect(stats.log.earned["day1000"] == nil)
    }

    @Test func awardIDsAreUnique() {
        #expect(Set(Award.all.map(\.id)).count == Award.all.count)
    }

    @Test func targetsClearWhenEmptyOrZero() {
        let stats = WritingStats(fileURL: nil)
        stats.setTarget(2_000, for: "/tmp/a.md")
        #expect(stats.target(for: "/tmp/a.md") == 2_000)
        stats.setTarget(0, for: "/tmp/a.md")
        #expect(stats.target(for: "/tmp/a.md") == nil)
    }

    @Test func logRoundTripsThroughDisk() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("WritingStats-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let stats = WritingStats(fileURL: url)
        stats.record(42, in: nil, at: day(1), calendar: calendar)
        stats.setTarget(1_000, for: "project:x")
        stats.save()
        #expect(WritingStats(fileURL: url).log == stats.log)
    }
}
