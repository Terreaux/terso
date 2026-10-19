// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import TersoApp

@Suite @MainActor struct ExerciseSuggestionTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }

    private func date(_ day: Int, hour: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }

    private var active: ExerciseSuggestionSnapshot {
        ExerciseSuggestionSnapshot(enabled: true, appIsForeground: true,
                                   editableDocument: true, userIsPresent: true, isIdle: false)
    }

    private func coveredHistory() -> ExerciseSuggestionHistory {
        ExerciseSuggestionHistory(coverageBegan: date(1))
    }

    private func allowed(_ snapshot: ExerciseSuggestionSnapshot,
                         history: ExerciseSuggestionHistory? = nil,
                         elapsed: TimeInterval = 600) -> Bool {
        ExerciseSuggestionPolicy.isEligible(snapshot: snapshot, history: history ?? coveredHistory(),
                                            eligibleSeconds: elapsed, now: date(2), calendar: calendar)
    }

    @Test func missingKeysStayOffForNewAndUpgradingUsers() throws {
        let suite = "ExercisePreferences-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for upgrading in [false, true] {
            if upgrading { defaults.set(true, forKey: "showWritingProgress"); defaults.set("fiction", forKey: "domain") }
            let values = ExerciseSuggestionPreferences(defaults: defaults)
            #expect(!values.reportEnabled && !values.warmupEnabled)
            #expect(values.delayMinutes == 10)
        }
        defaults.set(true, forKey: "exerciseReportSuggestions")
        defaults.set(15, forKey: "exerciseDelayMinutes")
        let selected = ExerciseSuggestionPreferences(defaults: defaults)
        #expect(selected.reportEnabled && !selected.warmupEnabled && selected.delayMinutes == 15)
    }

    @Test func exactThresholdAndExplicitConsentAreRequired() {
        #expect(!allowed(ExerciseSuggestionSnapshot()))
        #expect(!allowed(active, elapsed: 599))
        #expect(allowed(active))
        var snapshot = active
        snapshot.delayMinutes = 15
        #expect(!allowed(snapshot))
        #expect(allowed(snapshot, elapsed: 900))
    }

    @Test func everyExcludedContextPreventsDelivery() {
        let flags: [WritableKeyPath<ExerciseSuggestionSnapshot, Bool>] = [
            \.enabled, \.reliableActivity, \.appIsForeground, \.editableDocument, \.userIsPresent,
            \.isIdle, \.hasModal, \.isPreview, \.isZen, \.isComposing,
        ]
        for flag in flags {
            var snapshot = active
            snapshot[keyPath: flag].toggle()
            #expect(!allowed(snapshot))
        }
    }

    @Test func firstPartialDayIsUnknownAndFollowingDayIsCovered() {
        let state = ExerciseSuggestionState(fileURL: nil, now: date(2), calendar: calendar)
        #expect(!allowed(active, history: state.history))
        #expect(ExerciseSuggestionPolicy.isEligible(snapshot: active, history: state.history,
                                                   eligibleSeconds: 600, now: date(3), calendar: calendar))
        // Report discovery does not assume missing activity means zero activity.
        #expect(state.reportAllowed(enabled: true, at: date(2), calendar: calendar))
    }

    @Test func anyContentEditSuppressesEvenWithoutPositiveWordGrowth() {
        let state = ExerciseSuggestionState(fileURL: nil, now: date(1), calendar: calendar)
        // Deletions, replacements, and undo all use the same content-edit API;
        // there is intentionally no net-word argument to mistakenly gate them.
        state.recordEdit(at: date(2), calendar: calendar)
        #expect(!allowed(active, history: state.history))
        #expect(!state.invitationAllowed(snapshot: active, at: date(2), calendar: calendar))
        #expect(state.reportAllowed(enabled: true, at: date(2), calendar: calendar))
    }

    @Test func accumulatesAppWideAndReservesOnlyOnce() {
        let state = ExerciseSuggestionState(fileURL: nil, now: date(1), calendar: calendar)
        for second in stride(from: 0, through: 590, by: 10) {
            #expect(!state.tick(snapshot: active, at: date(2).addingTimeInterval(Double(second)),
                                monotonic: Double(second), calendar: calendar))
        }
        #expect(state.tick(snapshot: active, at: date(2).addingTimeInterval(600),
                           monotonic: 600, calendar: calendar))
        // Another window observing the same owner cannot reserve again.
        #expect(!state.tick(snapshot: active, at: date(2).addingTimeInterval(600),
                            monotonic: 600, calendar: calendar))
        #expect(state.invitationAllowed(snapshot: active, at: date(2).addingTimeInterval(600),
                                        calendar: calendar))
        state.recordEdit(at: date(2).addingTimeInterval(601), calendar: calendar)
        #expect(!state.invitationAllowed(snapshot: active, at: date(2).addingTimeInterval(601),
                                         calendar: calendar))
    }

    @Test func excludedTimeSleepAndPreferenceChangesCannotAccumulate() {
        let state = ExerciseSuggestionState(fileURL: nil, now: date(1), calendar: calendar)
        _ = state.tick(snapshot: active, at: date(2), monotonic: 0, calendar: calendar)
        _ = state.tick(snapshot: active, at: date(2).addingTimeInterval(10), monotonic: 10, calendar: calendar)
        #expect(state.eligibleSeconds == 10)
        _ = state.tick(snapshot: active, at: date(2).addingTimeInterval(610), monotonic: 610, calendar: calendar)
        #expect(state.eligibleSeconds == 10, "a long unattended/sleep gap is discarded")
        var excluded = active
        excluded.hasModal = true
        _ = state.tick(snapshot: excluded, at: date(2).addingTimeInterval(620), monotonic: 620, calendar: calendar)
        _ = state.tick(snapshot: active, at: date(2).addingTimeInterval(630), monotonic: 630, calendar: calendar)
        #expect(state.eligibleSeconds == 10)
        excluded = active
        excluded.enabled = false
        _ = state.tick(snapshot: excluded, at: date(2).addingTimeInterval(640), monotonic: 640, calendar: calendar)
        #expect(state.eligibleSeconds == 0)
        #expect(!state.invitationAllowed(snapshot: excluded, at: date(2), calendar: calendar))
    }

    @Test func dayTimezoneAndClockChangesResetActiveTime() {
        let state = ExerciseSuggestionState(fileURL: nil, now: date(1), calendar: calendar)
        _ = state.tick(snapshot: active, at: date(2), monotonic: 0, calendar: calendar)
        _ = state.tick(snapshot: active, at: date(2).addingTimeInterval(60), monotonic: 60, calendar: calendar)
        #expect(state.eligibleSeconds == 60)
        _ = state.tick(snapshot: active, at: date(2).addingTimeInterval(600), monotonic: 61, calendar: calendar)
        #expect(state.eligibleSeconds == 0, "wall clock jumps cannot manufacture elapsed time")
        _ = state.tick(snapshot: active, at: date(2).addingTimeInterval(610), monotonic: 71, calendar: calendar)
        #expect(state.eligibleSeconds == 10)
        _ = state.tick(snapshot: active, at: date(3), monotonic: 72, calendar: calendar)
        #expect(state.eligibleSeconds == 0)
        _ = state.tick(snapshot: active, at: date(3).addingTimeInterval(10), monotonic: 82, calendar: calendar)
        #expect(state.eligibleSeconds == 10)
        var otherZone = calendar
        otherZone.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        _ = state.tick(snapshot: active, at: date(3).addingTimeInterval(20), monotonic: 92, calendar: otherZone)
        #expect(state.eligibleSeconds == 0)
    }

    @Test func dismissalAndManualStartPersistAcrossRelaunch() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ExerciseSuggestions-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let state = ExerciseSuggestionState(fileURL: url, now: date(1), calendar: calendar)
        state.dismissToday(at: date(2), calendar: calendar)
        let relaunched = ExerciseSuggestionState(fileURL: url, now: date(2), calendar: calendar)
        #expect(!relaunched.reportAllowed(enabled: true, at: date(2), calendar: calendar))
        #expect(!allowed(active, history: relaunched.history))
        #expect(relaunched.reportAllowed(enabled: true, at: date(3), calendar: calendar))
        relaunched.startExercise(at: date(3), calendar: calendar)
        let again = ExerciseSuggestionState(fileURL: url, now: date(3), calendar: calendar)
        #expect(!again.reportAllowed(enabled: true, at: date(3), calendar: calendar))
        #expect(again.eligibleSeconds == 0)
        #expect(again.history == relaunched.history)
    }

    @Test func persistedDeliveryAndActivityPreventRelaunchInvitations() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ExerciseSuggestions-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let state = ExerciseSuggestionState(fileURL: url, now: date(1), calendar: calendar)
        for second in stride(from: 0, through: 600, by: 60) {
            _ = state.tick(snapshot: active, at: date(2).addingTimeInterval(Double(second)),
                           monotonic: Double(second), calendar: calendar)
        }
        let relaunched = ExerciseSuggestionState(fileURL: url, now: date(2), calendar: calendar)
        #expect(!allowed(active, history: relaunched.history))
        #expect(relaunched.eligibleSeconds == 0)
        relaunched.recordEdit(at: date(3), calendar: calendar)
        let edited = ExerciseSuggestionState(fileURL: url, now: date(3), calendar: calendar)
        #expect(!edited.invitationAllowed(snapshot: active, at: date(3), calendar: calendar))
    }

    @Test func timezoneRemappingAndRollbackDoNotRepeatSuppressedOffers() {
        let state = ExerciseSuggestionState(fileURL: nil, now: date(1), calendar: calendar)
        let late = date(2, hour: 23)
        state.dismissToday(at: late, calendar: calendar)
        var tokyo = calendar
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        #expect(!state.reportAllowed(enabled: true, at: late, calendar: tokyo),
                "the event falls in the new zone's day even though its saved date key differs")
        #expect(!state.reportAllowed(enabled: true, at: date(1), calendar: calendar),
                "rolling the clock behind a recorded suppression remains conservative")
    }

    @Test func failedPersistenceDoesNotAuthorizeDelivery() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ExerciseSuggestions-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // An existing directory cannot be atomically replaced by the JSON file.
        let state = ExerciseSuggestionState(fileURL: directory, now: date(1), calendar: calendar)
        #expect(state.saveError != nil)
        #expect(!state.invitationAllowed(snapshot: active, at: date(2), calendar: calendar))
        #expect(!state.tick(snapshot: active, at: date(2), monotonic: 0, calendar: calendar))
    }
}
