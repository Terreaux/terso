// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Observation

/// Missing preference keys are explicit opt-outs, including on upgrades.
struct ExerciseSuggestionPreferences {
    let reportEnabled: Bool
    let warmupEnabled: Bool
    let delayMinutes: Int
    init(defaults: UserDefaults) {
        reportEnabled = defaults.bool(forKey: "exerciseReportSuggestions")
        warmupEnabled = defaults.bool(forKey: "exerciseWarmupSuggestions")
        let savedDelay = defaults.integer(forKey: "exerciseDelayMinutes")
        delayMinutes = [5, 10, 15].contains(savedDelay) ? savedDelay : 10
    }
}

/// Exercise settings use the app's existing UserDefaults/Observation convention.
/// Keeping their ownership local avoids coupling reminder work to editor settings.
@MainActor @Observable
final class ExercisePreferences {
    static let shared = ExercisePreferences()
    private let defaults: UserDefaults
    var exerciseReportSuggestions: Bool { didSet { defaults.set(exerciseReportSuggestions, forKey: "exerciseReportSuggestions") } }
    var exerciseWarmupSuggestions: Bool { didSet {
        defaults.set(exerciseWarmupSuggestions, forKey: "exerciseWarmupSuggestions")
        ExerciseRuntime.shared.preferencesChanged()
    } }
    var exerciseDelayMinutes: Int { didSet {
        defaults.set(exerciseDelayMinutes, forKey: "exerciseDelayMinutes")
        ExerciseRuntime.shared.preferencesChanged()
    } }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let values = ExerciseSuggestionPreferences(defaults: defaults)
        exerciseReportSuggestions = values.reportEnabled
        exerciseWarmupSuggestions = values.warmupEnabled
        exerciseDelayMinutes = values.delayMinutes
    }
}

/// A snapshot of the active window only. Presence comes from ordinary local app
/// interactions; callers must mark the window idle after 60 unattended seconds.
struct ExerciseSuggestionSnapshot {
    var enabled = false
    var delayMinutes = 10
    var reliableActivity = true
    var appIsForeground = false
    var editableDocument = false
    var userIsPresent = false
    var isIdle = true
    var hasModal = false
    var isPreview = false
    var isZen = false
    var isComposing = false

    var allowsEditorTime: Bool {
        enabled && appIsForeground && editableDocument && userIsPresent && !isIdle
            && !hasModal && !isPreview && !isZen && !isComposing
    }

    var delaySeconds: TimeInterval {
        TimeInterval([5, 10, 15].contains(delayMinutes) ? delayMinutes : 10) * 60
    }
}

/// No manuscript, excerpt, response, word count, or keyboard data belongs here.
/// Keeping the day's edit interval also handles a timezone change conservatively:
/// an interval overlapping the newly interpreted day counts as writing activity.
struct ExerciseSuggestionDay: Codable, Equatable {
    var firstEdit: Date?
    var lastEdit: Date?
    var delivered: Date?
    var dismissed: Date?
    var started: Date?
}

struct ExerciseSuggestionHistory: Codable, Equatable {
    var coverageBegan: Date
    var days: [String: ExerciseSuggestionDay] = [:]
}

/// The decision itself has no UI, timers, preferences, persistence, or clock reads.
enum ExerciseSuggestionPolicy {
    static func reportAllowed(enabled: Bool, history: ExerciseSuggestionHistory,
                              now: Date, calendar: Calendar) -> Bool {
        enabled && !isSuppressed(history: history, now: now, calendar: calendar,
                                 includeDelivery: false)
    }

    static func isEligible(snapshot: ExerciseSuggestionSnapshot,
                           history: ExerciseSuggestionHistory, eligibleSeconds: TimeInterval,
                           now: Date, calendar: Calendar) -> Bool {
        allowsInvitation(snapshot: snapshot, history: history, now: now, calendar: calendar)
            && eligibleSeconds >= snapshot.delaySeconds
            && !isSuppressed(history: history, now: now, calendar: calendar,
                             includeDelivery: true)
    }

    /// Used to withdraw an already reserved invitation. Delivery is deliberately
    /// ignored because reservation necessarily precedes visible presentation.
    static func allowsInvitation(snapshot: ExerciseSuggestionSnapshot,
                                 history: ExerciseSuggestionHistory,
                                 now: Date, calendar: Calendar) -> Bool {
        guard snapshot.allowsEditorTime, snapshot.reliableActivity,
              history.coverageBegan <= calendar.startOfDay(for: now),
              let interval = calendar.dateInterval(of: .day, for: now),
              !isSuppressed(history: history, now: now, calendar: calendar,
                            includeDelivery: false) else { return false }
        let key = WritingLog.key(now, calendar: calendar)
        return !history.days.contains { savedKey, day in
            guard let first = day.firstEdit, let last = day.lastEdit else { return false }
            return savedKey == key || (first < interval.end && last >= interval.start)
        }
    }

    private static func isSuppressed(history: ExerciseSuggestionHistory,
                                     now: Date, calendar: Calendar,
                                     includeDelivery: Bool) -> Bool {
        guard let interval = calendar.dateInterval(of: .day, for: now) else { return true }
        let key = WritingLog.key(now, calendar: calendar)
        return history.days.contains { savedKey, day in
            let events = [day.dismissed, day.started, includeDelivery ? day.delivered : nil].compactMap { $0 }
            // A future suppression also blocks a rolled-back clock. Once wall
            // time catches up, the ordinary local-day tests take over.
            return events.contains { savedKey == key || interval.contains($0) || $0 > now }
        }
    }
}

/// One app-wide owner serializes reservations across document windows. Writes are
/// synchronous and atomic, so a delivery is never announced before it is saved.
/// Active time is deliberately absent from JSON and resets after every relaunch.
@MainActor
@Observable
final class ExerciseSuggestionState {
    static let shared = ExerciseSuggestionState()

    private(set) var history: ExerciseSuggestionHistory
    private(set) var eligibleSeconds: TimeInterval = 0
    private(set) var saveError: String?

    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private var previousUptime: TimeInterval?
    @ObservationIgnored private var previousDate: Date?
    @ObservationIgnored private var previousDay: String?
    @ObservationIgnored private var previousTimezone: String?
    @ObservationIgnored private var previousAllowsTime = false

    init(fileURL: URL? = AppDataPaths.file("ExerciseSuggestions.json"),
         now: Date = .now, calendar: Calendar = .current) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode(ExerciseSuggestionHistory.self, from: data) {
            history = saved
        } else {
            history = ExerciseSuggestionHistory(coverageBegan: now)
            // Starting midway through a day does not assert knowledge of the
            // earlier hours. Subsequent days are covered even if closed overnight.
            _ = persist()
        }
    }

    /// Every user-initiated content edit calls this, including deletion,
    /// replacement, undo, redo, and exercise edits. Net word growth is irrelevant.
    func recordEdit(at now: Date = .now, calendar: Calendar = .current) {
        let key = WritingLog.key(now, calendar: calendar)
        var day = history.days[key, default: ExerciseSuggestionDay()]
        day.firstEdit = min(day.firstEdit ?? now, now)
        day.lastEdit = max(day.lastEdit ?? now, now)
        history.days[key] = day
        resetActiveTime()
        _ = persist()
    }

    func startExercise(at now: Date = .now, calendar: Calendar = .current) {
        let key = WritingLog.key(now, calendar: calendar)
        var day = history.days[key, default: ExerciseSuggestionDay()]
        day.started = day.started ?? now
        history.days[key] = day
        resetActiveTime()
        _ = persist()
    }

    func dismissToday(at now: Date = .now, calendar: Calendar = .current) {
        let key = WritingLog.key(now, calendar: calendar)
        var day = history.days[key, default: ExerciseSuggestionDay()]
        day.dismissed = day.dismissed ?? now
        history.days[key] = day
        resetActiveTime()
        _ = persist()
    }

    func reportAllowed(enabled: Bool, at now: Date = .now, calendar: Calendar = .current) -> Bool {
        ExerciseSuggestionPolicy.reportAllowed(enabled: enabled, history: history,
                                               now: now, calendar: calendar)
    }

    func invitationAllowed(snapshot: ExerciseSuggestionSnapshot, at now: Date = .now,
                           calendar: Calendar = .current) -> Bool {
        saveError == nil && ExerciseSuggestionPolicy.allowsInvitation(
            snapshot: snapshot, history: history, now: now, calendar: calendar)
    }

    /// The integration owner supplies a single app-wide cadence. Only intervals
    /// whose two endpoints are eligible count; a gap exceeding 60 seconds is
    /// discarded as possible sleep/unattended time. No reminder timer lives here.
    /// Returns true only for a newly persisted reservation, never for old delivery.
    @discardableResult
    func tick(snapshot: ExerciseSuggestionSnapshot, at now: Date = .now,
              monotonic uptime: TimeInterval = ProcessInfo.processInfo.systemUptime,
              calendar: Calendar = .current) -> Bool {
        let day = WritingLog.key(now, calendar: calendar)
        let timezone = calendar.timeZone.identifier
        let elapsed = previousUptime.map { uptime - $0 }
        let wallElapsed = previousDate.map { now.timeIntervalSince($0) }
        let discontinuity = elapsed.map { elapsed in
            elapsed < 0 || abs((wallElapsed ?? elapsed) - elapsed) > 5
        } ?? false
        if previousDay != day || previousTimezone != timezone || discontinuity || !snapshot.enabled {
            eligibleSeconds = 0
            previousAllowsTime = false
        }

        let allowed = invitationAllowed(snapshot: snapshot, at: now, calendar: calendar)
        if allowed && previousAllowsTime, let elapsed, elapsed >= 0, elapsed <= 60 {
            eligibleSeconds += elapsed
        }
        previousUptime = uptime
        previousDate = now
        previousDay = day
        previousTimezone = timezone
        previousAllowsTime = allowed

        guard saveError == nil, ExerciseSuggestionPolicy.isEligible(
            snapshot: snapshot, history: history, eligibleSeconds: eligibleSeconds,
            now: now, calendar: calendar) else { return false }
        var record = history.days[day, default: ExerciseSuggestionDay()]
        record.delivered = now
        history.days[day] = record
        return persist()
    }

    func resetActiveTime() {
        eligibleSeconds = 0
        previousUptime = nil
        previousDate = nil
        previousAllowsTime = false
    }

    /// Retrying persistence never presents an invitation by itself.
    @discardableResult
    func save() -> Bool { persist() }

    private func persist() -> Bool {
        guard let fileURL else { saveError = nil; return true }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(history).write(to: fileURL, options: .atomic)
            saveError = nil
            return true
        } catch {
            saveError = error.localizedDescription
            return false
        }
    }
}
