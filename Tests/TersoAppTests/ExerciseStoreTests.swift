// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import TersoApp

@Suite @MainActor struct ExerciseStoreTests {
    private func scratch() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("terso-exercises-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func onlyExplicitSaveCreatesAnEmptySession() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("WritingExercises.json")
        let store = ExerciseStore(fileURL: url)
        let session = ExerciseSession(template: ExerciseCatalog.templates[0])
        #expect(store.sessions.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(store.save(session))
        #expect(ExerciseStore(fileURL: url).session(session.id) == session)
    }

    @Test func latestResponsesMetadataAndPromptSnapshotSurviveRelaunch() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("WritingExercises.json")
        let manuscript = directory.appendingPathComponent("Draft.md")
        let source = ExerciseSource(documentID: UUID(), name: "Draft", fileURL: manuscript, excerpt: "Source context")
        var template = ExerciseCatalog.templates[0]
        template.version = 2
        template.steps[0].prompt = "The exact prompt this writer originally saw."
        var session = ExerciseSession(template: template, source: source)
        let store = ExerciseStore(fileURL: url)
        for number in 0..<20 {
            session.responses[template.steps[0].id] = "Latest response \(number): café, 雨, 👩🏽‍💻"
            session.updatedAt = session.createdAt.addingTimeInterval(Double(number))
            #expect(store.save(session))
        }
        session.responses[template.steps[2].id] = "The final thought."
        session.currentStep = 2
        session.completed = true
        session.title = "My own title"
        #expect(store.save(session))
        #expect(store.error == nil)
        let reloaded = ExerciseStore(fileURL: url)
        #expect(reloaded.session(session.id) == session)
        #expect(reloaded.session(session.id)?.template != ExerciseCatalog.templates[0])

        // Completion organizes records; it does not lock responses or require all steps.
        session.responses[template.steps[0].id] = "Revised after completion."
        #expect(reloaded.save(session))
        #expect(ExerciseStore(fileURL: url).session(session.id)?.responses[template.steps[0].id] == "Revised after completion.")
        let retry = ExerciseSession(template: session.template, source: session.source)
        #expect(retry.id != session.id)
        #expect(retry.responses.isEmpty)
        #expect(reloaded.save(retry))
        #expect(reloaded.sessions.count == 2)
    }

    @Test func copyContainsOnlyAuthoredResponsesInStepOrder() {
        var session = ExerciseSession(
            template: ExerciseCatalog.templates[0],
            source: ExerciseSource(documentID: UUID(), name: "Context", fileURL: nil, excerpt: "Do not copy this excerpt."))
        let steps = session.template.steps
        session.responses[steps[2].id] = "  Last response.\n"
        session.responses[steps[0].id] = "First response."
        session.responses[steps[1].id] = " \n "
        session.responses["not-a-step"] = "Do not copy unknown fields."
        #expect(session.allResponses == "First response.\n\n  Last response.\n")
    }

    @Test func deletionIsTargetedAndRejectsStaleSaves() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("WritingExercises.json")
        let manuscript = directory.appendingPathComponent("Draft.md")
        let reusedProse = "Original draft.\n\nAlready reused writing."
        try reusedProse.write(to: manuscript, atomically: true, encoding: .utf8)
        var first = ExerciseSession(
            template: ExerciseCatalog.templates[0],
            source: ExerciseSource(documentID: UUID(), name: "Draft", fileURL: manuscript, excerpt: "Original draft."))
        first.updatedAt = Date(timeIntervalSince1970: 100)
        var second = ExerciseSession(template: ExerciseCatalog.templates[1])
        second.updatedAt = Date(timeIntervalSince1970: 200)
        let store = ExerciseStore(fileURL: url)
        #expect(store.save(first))
        #expect(store.save(second))
        #expect(store.sessions.map(\.id) == [second.id, first.id])
        #expect(store.delete(first.id))
        #expect(!store.save(first))
        #expect(store.error != nil)
        #expect(store.session(first.id) == nil)
        #expect(ExerciseStore(fileURL: url).sessions == [second])
        #expect(try String(contentsOf: manuscript, encoding: .utf8) == reusedProse)
    }

    @Test func failedSaveRetainsLatestWritingAndRetryClearsError() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let blockedParent = directory.appendingPathComponent("NotADirectory")
        try Data("file".utf8).write(to: blockedParent)
        let url = blockedParent.appendingPathComponent("WritingExercises.json")
        let store = ExerciseStore(fileURL: url)
        var session = ExerciseSession(template: ExerciseCatalog.templates[0])
        session.responses[session.template.steps[0].id] = "Keep this even when saving fails."
        #expect(!store.save(session))
        #expect(store.error?.contains("retry") == true)
        #expect(store.session(session.id) == session)
        try FileManager.default.removeItem(at: blockedParent)
        #expect(store.save(session))
        #expect(store.error == nil)
        #expect(ExerciseStore(fileURL: url).session(session.id) == session)
    }

    @Test func failedDeletionKeepsTheSessionAvailableForRetry() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let parent = directory.appendingPathComponent("Data")
        let url = parent.appendingPathComponent("WritingExercises.json")
        let store = ExerciseStore(fileURL: url)
        let session = ExerciseSession(template: ExerciseCatalog.templates[0])
        #expect(store.save(session))
        let backup = directory.appendingPathComponent("PreservedData")
        try FileManager.default.moveItem(at: parent, to: backup)
        try Data("file".utf8).write(to: parent)
        #expect(!store.delete(session.id))
        #expect(store.session(session.id) == session)
        #expect(store.error != nil)
        try FileManager.default.removeItem(at: parent)
        try FileManager.default.moveItem(at: backup, to: parent)
        #expect(store.delete(session.id))
        #expect(ExerciseStore(fileURL: url).sessions.isEmpty)
    }

    @Test func unreadableRecordsArePreservedInsteadOfOverwritten() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("WritingExercises.json")
        let original = Data("An unreadable record that must survive.".utf8)
        try original.write(to: url)
        let store = ExerciseStore(fileURL: url)
        #expect(store.error?.contains("preserved") == true)
        let session = ExerciseSession(template: ExerciseCatalog.templates[0])
        #expect(!store.save(session))
        #expect(store.session(session.id) == session)
        #expect(try Data(contentsOf: url) == original)
    }
}
