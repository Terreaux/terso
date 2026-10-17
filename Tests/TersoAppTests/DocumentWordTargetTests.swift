// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import TersoApp

@Suite @MainActor struct DocumentWordTargetTests {
    @Test func unsavedTargetsStayWithTheirDocumentAndCarryIntoFirstSave() {
        let stats = WritingStats(fileURL: nil)
        let model = WorkspaceModel(wordTargets: stats)
        let other = WorkspaceModel(wordTargets: stats)
        model.documentWordTarget = 5_000
        #expect(model.documentWordTarget == 5_000)
        #expect(other.documentWordTarget == nil)
        #expect(stats.log.targets.isEmpty)

        let url = URL(fileURLWithPath: "/tmp/target-story.md")
        model.fileURL = url
        #expect(stats.target(for: WritingStats.key(url)) == 5_000)
        model.documentWordTarget = 6_000
        model.fileURL = url
        #expect(model.documentWordTarget == 6_000, "Metadata refresh must not restore a stale unsaved target")
    }

    @Test func reportAndWritingStatsShareSavedTargets() {
        let stats = WritingStats(fileURL: nil)
        let model = WorkspaceModel(wordTargets: stats)
        let url = URL(fileURLWithPath: "/tmp/target-story.md")
        let key = WritingStats.key(url)
        model.fileURL = url
        stats.setTarget(2_000, for: key)
        #expect(model.documentWordTarget == 2_000)
        model.documentWordTarget = 3_000
        #expect(stats.target(for: key) == 3_000)
        model.documentWordTarget = nil
        #expect(model.documentWordTarget == nil)
        #expect(stats.target(for: key) == nil)
    }

    @Test func clearingUnsavedTargetLeavesNothingToPersist() {
        let stats = WritingStats(fileURL: nil)
        let model = WorkspaceModel(wordTargets: stats)
        model.documentWordTarget = 1_000
        model.documentWordTarget = nil
        model.fileURL = URL(fileURLWithPath: "/tmp/target-story.md")
        #expect(stats.log.targets.isEmpty)
        #expect(model.documentWordTarget == nil)
        model.documentWordTarget = -1
        #expect(model.documentWordTarget == nil)
    }
}
