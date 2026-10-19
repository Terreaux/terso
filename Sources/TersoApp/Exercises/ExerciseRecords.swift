// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Observation

/// A bundled sequence. Sessions retain a value snapshot so future catalog changes
/// never replace instructions the writer has already used.
struct ExerciseTemplate: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var version: Int = 1
    var title: String
    var purpose: String
    var duration: String
    var category: String
    var steps: [ExerciseStep]
}

struct ExerciseStep: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var prompt: String
}

struct ExerciseSource: Codable, Equatable, Sendable {
    var documentID: UUID
    var name: String
    var fileURL: URL?
    var excerpt: String?
}

struct ExerciseSession: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var title: String
    var template: ExerciseTemplate
    var responses: [String: String]
    var currentStep: Int
    var completed: Bool
    var createdAt: Date
    var updatedAt: Date
    var source: ExerciseSource?

    init(template: ExerciseTemplate, source: ExerciseSource? = nil) {
        id = UUID()
        title = template.title
        self.template = template
        responses = [:]
        currentStep = 0
        completed = false
        createdAt = Date()
        updatedAt = createdAt
        self.source = source
    }

    /// Reuse only writing supplied by the author, in the exercise's step order.
    /// Whitespace within a nonempty response is preserved exactly.
    var allResponses: String {
        template.steps.compactMap { step in
            guard let text = responses[step.id],
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return text
        }.joined(separator: "\n\n")
    }
}

enum ExerciseCatalog {
    static let templates: [ExerciseTemplate] = [
        ExerciseTemplate(
            id: "start-anywhere", title: "Start anywhere",
            purpose: "Find a small starting point.", duration: "3–5 minutes", category: "Starting",
            steps: [
                .init(id: "fragments", title: "Gather fragments", prompt: "Write a few fragments, questions, images, or observations connected to what you want to write. Full sentences are optional."),
                .init(id: "choose", title: "Follow your curiosity", prompt: "Choose one that you are curious about. What makes it worth following?"),
                .init(id: "expand", title: "Expand the thought", prompt: "Expand that thought into a few sentences. You can decide where they belong later."),
            ]),
        ExerciseTemplate(
            id: "rough-first-pass", title: "A rough first pass",
            purpose: "Get material down before polishing it.", duration: "5 minutes", category: "Starting",
            steps: [
                .init(id: "write", title: "Get material down", prompt: "Write what is on your mind about this piece. Let incomplete or awkward sentences stand for now."),
                .init(id: "choose", title: "Find a thought", prompt: "Read what you wrote. Which thought would you like to say more about?"),
                .init(id: "continue", title: "Keep going", prompt: "Start from that thought and keep going for another paragraph, or as long as it remains useful."),
            ]),
        ExerciseTemplate(
            id: "next-paragraph", title: "Find the next paragraph",
            purpose: "Recover the thread of an unfinished draft.", duration: "5 minutes", category: "Continuing",
            steps: [
                .init(id: "next", title: "Say what comes next", prompt: "What are you trying to say next? Explain it as you would to a friend. Fragments are welcome."),
                .init(id: "thread", title: "Find the thread", prompt: "Read over your notes. Which thought do you want to follow? Express it in one sentence."),
                .init(id: "develop", title: "Develop a paragraph", prompt: "Develop that thought into a paragraph. Start with an example, observation, or question if that helps."),
            ]),
        ExerciseTemplate(
            id: "explain-to-one-person", title: "Explain it to one person",
            purpose: "Turn a vague idea into a clear explanation.", duration: "5–8 minutes", category: "Clarifying",
            steps: [
                .init(id: "reader", title: "Choose your reader", prompt: "Choose someone who would read this. What do you want them to understand?"),
                .init(id: "explain", title: "Explain the idea", prompt: "Explain the idea in plain language as if you were speaking to that person."),
                .init(id: "example", title: "Try an example", prompt: "Give an example. What might they question or misunderstand?"),
                .init(id: "paragraph", title: "Write the explanation", prompt: "Use those notes to write a paragraph that introduces the idea and answers that question."),
            ]),
        ExerciseTemplate(
            id: "scene-turn", title: "Give the scene a turn",
            purpose: "Find an action that moves a scene forward.", duration: "8–10 minutes", category: "Fiction",
            steps: [
                .init(id: "want", title: "Find the want", prompt: "What does the viewpoint character want at this moment?"),
                .init(id: "obstacle", title: "Find the resistance", prompt: "What person, circumstance, or uncertainty gets in the way?"),
                .init(id: "action", title: "Choose an action", prompt: "What does the character do about it, and what changes because of that action?"),
                .init(id: "scene", title: "Write the moment", prompt: "Write the moment when the action meets resistance. A short exchange or scene fragment is enough."),
            ]),
        ExerciseTemplate(
            id: "make-concrete", title: "Make it concrete",
            purpose: "Find details that give a scene or passage substance.", duration: "5 minutes", category: "Fiction",
            steps: [
                .init(id: "details", title: "Notice the details", prompt: "List a few things someone could see, hear, or physically notice here."),
                .init(id: "viewpoint", title: "Choose a viewpoint", prompt: "Which detail would this particular viewpoint character or narrator notice first?"),
                .init(id: "effect", title: "Follow its effect", prompt: "What does that detail suggest to them, or make them do?"),
                .init(id: "passage", title: "Write the passage", prompt: "Write a short passage using the detail and its effect."),
            ]),
        ExerciseTemplate(
            id: "find-structure", title: "Find the structure",
            purpose: "Give existing material a workable order.", duration: "8–10 minutes", category: "Research",
            steps: [
                .init(id: "purposes", title: "Name the purposes", prompt: "Give each paragraph or section you are working with a one-line purpose."),
                .init(id: "connections", title: "Find the gaps", prompt: "Where do those purposes repeat? What connection or explanation is missing?"),
                .init(id: "order", title: "Try an order", prompt: "Try an order that would help a reader follow your thinking."),
                .init(id: "change", title: "Make one change", prompt: "Choose one change you can make now. Draft the missing connection, revise a section, or record the new outline."),
            ]),
        ExerciseTemplate(
            id: "claim-evidence-uncertainty", title: "Claim, evidence, uncertainty",
            purpose: "Explain a research or analytical point at the strength the evidence supports.", duration: "8–10 minutes", category: "Research",
            steps: [
                .init(id: "claim", title: "State the claim", prompt: "What claim or result do you want to explain? State it as plainly as you can."),
                .init(id: "evidence", title: "Gather the evidence", prompt: "What evidence, observation, calculation, or source do you already have for it?"),
                .init(id: "uncertainty", title: "Record the limits", prompt: "What remains uncertain, limited, or missing? Record Evidence needed wherever appropriate."),
                .init(id: "paragraph", title: "Connect claim and evidence", prompt: "Draft a paragraph that connects the claim to its evidence and accurately states its limits. If evidence is missing, record the next research step instead."),
            ]),
    ]

    static func recommended(register: String?) -> ExerciseTemplate {
        switch register?.lowercased() {
        case "fiction": templates[4]
        case "academic", "research", "science": templates[7]
        case "technical", "business": templates[3]
        default: templates[0]
        }
    }
}

/// App-wide internal records, separate from manuscript documents and settings.
/// Main-actor synchronous writes serialize every edit and leave no delayed save
/// that could replace a newer response or resurrect a deleted session.
@MainActor @Observable
final class ExerciseStore {
    static let shared = ExerciseStore()
    private(set) var sessions: [ExerciseSession] = []
    private(set) var error: String?
    private let fileURL: URL
    private var deletedIDs: Set<UUID> = []
    private var unreadableStore = false

    init(fileURL: URL = AppDataPaths.file("WritingExercises.json")) {
        self.fileURL = fileURL
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            sessions = try JSONDecoder().decode([ExerciseSession].self, from: Data(contentsOf: fileURL))
            sortSessions()
        } catch {
            unreadableStore = true
            self.error = "Could not read saved exercises at \(fileURL.path). Your saved file has been preserved. Restore that file and reopen Terso. \(error.localizedDescription)"
        }
    }

    func session(_ id: UUID) -> ExerciseSession? { sessions.first { $0.id == id } }

    /// Calling save is explicit: an empty session can deliberately be retained.
    /// The chooser and template initializer never write a record themselves.
    @discardableResult
    func save(_ session: ExerciseSession) -> Bool {
        guard !deletedIDs.contains(session.id) else {
            error = "This exercise was deleted. Start a new attempt to keep this writing."
            return false
        }
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.append(session)
        }
        sortSessions()
        return persist(sessions)
    }

    /// A failed deletion keeps the record available so the writer can retry.
    @discardableResult
    func delete(_ id: UUID) -> Bool {
        let remaining = sessions.filter { $0.id != id }
        guard persist(remaining) else { return false }
        sessions = remaining
        deletedIDs.insert(id)
        return true
    }

    private func sortSessions() {
        sessions.sort {
            if $0.updatedAt == $1.updatedAt { return $0.id.uuidString < $1.id.uuidString }
            return $0.updatedAt > $1.updatedAt
        }
    }

    private func persist(_ records: [ExerciseSession]) -> Bool {
        guard !unreadableStore else { return false }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(records).write(to: fileURL, options: .atomic)
            error = nil
            return true
        } catch {
            self.error = "Could not save exercises. Your latest writing is still available here. Check available disk space and access to \(fileURL.deletingLastPathComponent().path), then retry. \(error.localizedDescription)"
            return false
        }
    }
}
