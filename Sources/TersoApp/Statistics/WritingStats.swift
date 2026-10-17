// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import Foundation
import Observation
import SwiftUI
import UserNotifications

/// Words the writer typed: the keyboard, dictation and input methods. Paste,
/// drops, accepted suggestions and undo never reach `insertText`, so they
/// never count.
enum TypedWords {
    /// Characters that keep a word going ("don't", "well-known").
    static func continuesWord(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "'" || c == "’" || c == "-" || c == "_"
    }

    /// How many new words `inserted` begins, given the characters on either
    /// side of where it goes. Fixing a typo inside a word, or typing onto the
    /// front of one, adds none; revising never takes words away.
    static func count(_ inserted: String, before: Character?, after: Character?) -> Int {
        var n = 0
        var previous = before
        var openWord = false
        for c in inserted {
            if c.isLetter || c.isNumber {
                if !(previous.map(continuesWord) ?? false) { n += 1; openWord = true }
            } else if !continuesWord(c) {
                openWord = false
            }
            previous = c
        }
        // The last word ran into one already on the page: it was a prefix.
        if openWord, after.map(continuesWord) ?? false { n -= 1 }
        return n
    }
}

/// Everything Terso remembers about the writer's typing. Counts only, never text.
struct WritingLog: Codable, Equatable {
    /// Typed words per local day, keyed "yyyy-MM-dd".
    var days: [String: Int] = [:]
    /// Typed words by hour of the day.
    var hours: [Int] = Array(repeating: 0, count: 24)
    /// Typed words per document, keyed by standardized path.
    var typed: [String: Int] = [:]
    /// Word-count targets, keyed by document path or `project:<uuid>`.
    var targets: [String: Int] = [:]
    var bestSitting = 0
    var dailyGoal = 500
    /// Award id → when it was earned.
    var earned: [String: Date] = [:]

    var lifetime: Int { days.values.reduce(0, +) }
    var bestDay: Int { days.values.max() ?? 0 }

    func words(on date: Date, calendar: Calendar = .current) -> Int {
        days[WritingLog.key(date, calendar: calendar)] ?? 0
    }

    /// Typed words over the seven days ending `now`.
    func week(ending now: Date, calendar: Calendar = .current) -> Int {
        (0..<7).reduce(0) { sum, back in
            sum + (calendar.date(byAdding: .day, value: -back, to: now).map { words(on: $0, calendar: calendar) } ?? 0)
        }
    }

    /// Days in a row with at least `WritingLog.streakMinimum` typed words. A
    /// streak stays alive through today until the day is over.
    func currentStreak(at now: Date, calendar: Calendar = .current) -> Int {
        var day = now
        if words(on: day, calendar: calendar) < Self.streakMinimum {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: day) else { return 0 }
            day = yesterday
        }
        var n = 0
        while words(on: day, calendar: calendar) >= Self.streakMinimum {
            n += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return n
    }

    var longestStreak: Int {
        let written = days.filter { $0.value >= Self.streakMinimum }.keys.compactMap(Self.date(fromKey:)).sorted()
        var best = 0, run = 0
        var last: Date?
        let calendar = Self.utc
        for day in written {
            if let last, calendar.dateComponents([.day], from: last, to: day).day == 1 { run += 1 } else { run = 1 }
            best = max(best, run)
            last = day
        }
        return best
    }

    func value(for measure: Award.Measure) -> Int {
        switch measure {
        case .lifetime: lifetime
        case .day: bestDay
        case .sitting: bestSitting
        case .streak: longestStreak
        }
    }

    /// A made-up record for previewing the stats: a year of uneven writing
    /// with a recent streak, enough to earn some awards and leave others in
    /// progress. Awards are dated the day their goal was passed.
    static func sample<G: RandomNumberGenerator>(endingAt now: Date = .now, calendar: Calendar = .current, using rng: inout G) -> WritingLog {
        var log = WritingLog()
        let streak = Int.random(in: 8...45, using: &rng)
        var lifetime = 0, chronological: [(Date, Int)] = []
        for back in stride(from: 364, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -back, to: now) else { continue }
            let words: Int
            if back < streak { words = Int.random(in: 300...2_400, using: &rng) }
            else if back == streak { words = 0 }
            else if Double.random(in: 0..<1, using: &rng) < 0.55 { words = Int.random(in: 60...1_900, using: &rng) }
            else { continue }
            if words > 0 { log.days[key(day, calendar: calendar)] = words }
            lifetime += words
            chronological.append((day, lifetime))
        }
        for _ in 0..<Int.random(in: 1...3, using: &rng) {
            if let k = log.days.keys.randomElement(using: &rng) { log.days[k] = Int.random(in: 2_000...5_600, using: &rng) }
        }
        let total = log.lifetime
        let weights = (0..<24).map { h in (7...11).contains(h) || (20...23).contains(h) ? Double.random(in: 2...6, using: &rng) : Double.random(in: 0...1, using: &rng) }
        let sum = weights.reduce(0, +)
        log.hours = weights.map { Int(Double(total) * $0 / sum) }
        log.bestSitting = Int.random(in: 600...min(3_200, log.bestDay), using: &rng)
        log.dailyGoal = 1_000

        // Running totals give a plausible date for the lifetime awards; the rest
        // land somewhere in the last few months.
        for award in Award.all where log.value(for: award.measure) >= award.goal {
            if award.measure == .lifetime, let passed = chronological.first(where: { $0.1 >= award.goal }) {
                log.earned[award.id] = passed.0
            } else {
                log.earned[award.id] = calendar.date(byAdding: .day, value: -Int.random(in: 0...120, using: &rng), to: now)
            }
        }
        return log
    }

    /// A day counts towards a streak from this many typed words.
    static let streakMinimum = 100

    static func key(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }()

    /// Noon UTC on the keyed day: whole-day arithmetic without time zones.
    static func date(fromKey key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return utc.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }
}

/// A milestone worth noticing. Thresholds come from writing itself — daily
/// quotas writers kept, story-length categories, the length of known books.
struct Award: Identifiable, Hashable {
    enum Measure: Hashable { case lifetime, day, sitting, streak }
    enum Group: String, CaseIterable, Identifiable {
        case day = "In a Day", sitting = "In One Sitting", streak = "Days in a Row"
        case length = "Story Lengths", books = "Famous Books"
        var id: String { rawValue }
    }

    let id: String
    let title: String
    let detail: String
    let symbol: String
    let group: Group
    let measure: Measure
    let goal: Int

    static let all: [Award] = [
        day("day500", "Five Hundred", 500, "500 words in a day: Graham Greene’s daily quota."),
        day("day1000", "A Thousand Words", 1_000, "1,000 words in a day."),
        day("day1667", "NaNoWriMo Pace", 1_667, "1,667 words in a day: fifty thousand in thirty days."),
        day("day2000", "Two Thousand", 2_000, "2,000 words in a day: Stephen King’s target in On Writing."),
        day("day5000", "Marathon", 5_000, "5,000 words in a day."),

        sitting("sit500", "Settled In", 500),
        sitting("sit1000", "In the Flow", 1_000),
        sitting("sit2500", "Deep Work", 2_500),

        streak("streak3", "Three Days Running", 3),
        streak("streak7", "A Week of Words", 7),
        streak("streak30", "A Month of Words", 30),
        streak("streak100", "A Hundred Days", 100),
        streak("streak365", "A Year of Words", 365),

        length("len100", "First Words", 100, "Your first hundred words typed in Terso.", "pencil.line"),
        length("len1000", "Flash Fiction", 1_000, "1,000 words: the length of a piece of flash fiction.", "doc.plaintext"),
        length("len7500", "Short Story", 7_500, "7,500 words: the longest a short story runs before it becomes a novelette.", "doc.text"),
        length("len17500", "Novelette", 17_500, "17,500 words: the longest a novelette runs before it becomes a novella.", "doc.richtext"),
        length("len40000", "Novella", 40_000, "40,000 words: past this, a story is a novel.", "book.closed"),
        length("len50000", "Novel", 50_000, "50,000 words: a NaNoWriMo novel.", "book"),

        book("bookAnimalFarm", "Animal Farm", 30_000, "About as many words as Orwell’s Animal Farm."),
        book("bookGatsby", "The Great Gatsby", 47_000, "About as many words as Fitzgerald’s The Great Gatsby."),
        book("bookFrankenstein", "Frankenstein", 75_000, "About as many words as Shelley’s Frankenstein."),
        book("bookPride", "Pride and Prejudice", 122_000, "About as many words as Austen’s Pride and Prejudice."),
        book("bookMobyDick", "Moby-Dick", 206_000, "About as many words as Melville’s Moby-Dick."),
        book("bookWarAndPeace", "War and Peace", 587_000, "About as many words as Tolstoy’s War and Peace."),
        Award(id: "million", title: "A Million Words", detail: "A million words: the apprenticeship writers talk about.",
              symbol: "star", group: .books, measure: .lifetime, goal: 1_000_000),
    ]

    private static func day(_ id: String, _ title: String, _ goal: Int, _ detail: String) -> Award {
        Award(id: id, title: title, detail: detail, symbol: "sun.max", group: .day, measure: .day, goal: goal)
    }
    private static func sitting(_ id: String, _ title: String, _ goal: Int) -> Award {
        Award(id: id, title: title, detail: "\(goal.formatted()) words without a five-minute pause.",
              symbol: "hourglass", group: .sitting, measure: .sitting, goal: goal)
    }
    private static func streak(_ id: String, _ title: String, _ goal: Int) -> Award {
        Award(id: id, title: title, detail: "\(goal) days in a row with at least \(WritingLog.streakMinimum) words typed.",
              symbol: "flame", group: .streak, measure: .streak, goal: goal)
    }
    private static func length(_ id: String, _ title: String, _ goal: Int, _ detail: String, _ symbol: String) -> Award {
        Award(id: id, title: title, detail: detail, symbol: symbol, group: .length, measure: .lifetime, goal: goal)
    }
    private static func book(_ id: String, _ title: String, _ goal: Int, _ detail: String) -> Award {
        Award(id: id, title: title, detail: detail, symbol: "books.vertical", group: .books, measure: .lifetime, goal: goal)
    }
}

/// The writer's typing record, kept locally in Application Support.
@MainActor
@Observable
final class WritingStats {
    static let shared = WritingStats()

    private(set) var log = WritingLog()
    /// What the stats window shows: the real record, or a sample when the
    /// writer has asked to preview one.
    var shown: WritingLog {
        guard Preferences.shared.sampleWritingStats else { return log }
        if let sampleLog { return sampleLog }
        var rng = SystemRandomNumberGenerator()
        let sample = WritingLog.sample(using: &rng)
        sampleLog = sample
        return sample
    }
    /// The award most recently earned, until it has been shown.
    var latestAward: Award?

    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private var sittingWords = 0
    @ObservationIgnored private var lastTyped: Date?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var terminationObserver: NSObjectProtocol?
    @ObservationIgnored private var sampleLog: WritingLog?

    /// A pause longer than this ends a sitting.
    static let sittingGap: TimeInterval = 5 * 60

    init(fileURL: URL? = AppDataPaths.file("WritingStats.json")) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode(WritingLog.self, from: data) {
            log = saved
        }
        if fileURL != nil {
            terminationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.save() }
            }
        }
    }

    func record(_ words: Int, in url: URL?, at now: Date = .now, calendar: Calendar = .current) {
        guard words > 0 else { return }
        log.days[WritingLog.key(now, calendar: calendar), default: 0] += words
        log.hours[calendar.component(.hour, from: now)] += words
        if let url { log.typed[Self.key(url), default: 0] += words }
        if let lastTyped, now.timeIntervalSince(lastTyped) <= Self.sittingGap { sittingWords += words } else { sittingWords = words }
        lastTyped = now
        log.bestSitting = max(log.bestSitting, sittingWords)

        let newly = Award.all.filter { log.earned[$0.id] == nil && log.value(for: $0.measure) >= $0.goal }
        for award in newly { log.earned[award.id] = now }
        if let best = newly.last { announce(best) }
        scheduleSave()
    }

    /// Shows an award the way a real one would be shown, without earning it.
    func previewAward() {
        let earned = shown.earned
        let pool = Award.all.filter { earned[$0.id] != nil }
        guard let award = pool.randomElement() ?? Award.all.randomElement() else { return }
        withAnimation(.easeOut(duration: 0.3)) { latestAward = award }
        AwardNotifications.post(award)
    }

    private func announce(_ award: Award) {
        if Preferences.shared.celebrateAwards { latestAward = award }
        if Preferences.shared.notifyAwards { AwardNotifications.post(award) }
    }

    func typed(in url: URL) -> Int { log.typed[Self.key(url)] ?? 0 }

    func target(for key: String) -> Int? { log.targets[key] }

    func setTarget(_ target: Int?, for key: String) {
        log.targets[key] = target.flatMap { $0 > 0 ? $0 : nil }
        scheduleSave()
    }

    func setDailyGoal(_ goal: Int) {
        log.dailyGoal = max(50, goal)
        scheduleSave()
    }

    nonisolated static func key(_ url: URL) -> String { url.standardizedFileURL.path }
    nonisolated static func key(_ project: TersoProject) -> String { "project:\(project.id.uuidString)" }

    private func scheduleSave() {
        guard fileURL != nil else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    func save() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(log).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Terso: could not save writing stats: \(error.localizedDescription)")
        }
    }
}

/// macOS notifications for earned awards. Only a bundled app can post them,
/// so `swift run` builds stay quiet.
enum AwardNotifications {
    private static var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : .current()
    }

    static func requestAuthorization() {
        center?.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            if !granted { NSLog("Terso: award notifications were not allowed") }
        }
    }

    static func post(_ award: Award) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = "Award earned: \(award.title)"
        content.body = award.detail
        content.sound = .default
        content.threadIdentifier = "awards"
        center.add(UNNotificationRequest(identifier: "award.\(award.id)", content: content, trigger: nil))
    }
}
