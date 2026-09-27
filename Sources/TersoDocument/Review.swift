// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Observation
import TersoCore

/// Something whose text can be edited: the editor's text view, or an
/// in-memory buffer in tests. Only `SuggestionReview` edits it on behalf of a
/// suggestion; AI code has no path to a target (TersoAI cannot import this
/// module).
@MainActor
public protocol TextMutationTarget: AnyObject {
    var currentSnapshot: DocumentSnapshot { get }
    /// Replace text as one undoable user action.
    func replace(_ range: TextSpan, with text: String, actionName: String)
}

/// Plain in-memory implementation, used by tests and headless tools.
@MainActor
public final class TextBuffer: TextMutationTarget {
    public private(set) var text: String
    public private(set) var revision = DocumentRevision(0)
    public private(set) var undoStack: [(TextSpan, String)] = []

    public init(_ text: String) { self.text = text }

    public var currentSnapshot: DocumentSnapshot { DocumentSnapshot(revision: revision, text: text) }

    /// A keystroke-equivalent edit by the writer.
    public func userEdit(_ range: TextSpan, with s: String) { replace(range, with: s, actionName: "Typing") }

    public func replace(_ range: TextSpan, with s: String, actionName: String) {
        let ns = NSMutableString(string: text)
        undoStack.append((TextSpan(location: range.location, length: s.utf16Length), ns.substring(with: range.nsRange)))
        ns.replaceCharacters(in: range.nsRange, with: s)
        text = ns as String
        revision = revision.next()
    }
}

public enum SuggestionStatus: Equatable, Sendable {
    case pending, accepted, rejected
    case stale(String)
}

public enum ReviewError: Error, Equatable {
    case unknownSuggestion
    case notPending
    case stale(String)
    case acceptAllOutsideReview
    case notInspected
}

/// Holds AI suggestions and applies them only on explicit acceptance.
///
/// Invariants (covered by tests):
/// * adding, listing, rejecting or dismissing a suggestion never edits text;
/// * accepting re-locates the passage in the *current* text and refuses if it
///   cannot be found unambiguously — an old offset is never applied blindly;
/// * Accept All exists only in review mode, after the suggestions were shown.
@MainActor
@Observable
public final class SuggestionReview {
    public private(set) var suggestions: [WritingSuggestion] = []
    public private(set) var status: [UUID: SuggestionStatus] = [:]
    public private(set) var isReviewMode = false
    public private(set) var inspected = false
    public var selectedID: UUID?

    public init() {}

    public var pending: [WritingSuggestion] { suggestions.filter { status[$0.id] == .pending } }

    public func add(_ new: [WritingSuggestion]) {
        for s in new where status[s.id] == nil {
            suggestions.append(s)
            status[s.id] = .pending
        }
    }

    public func clear() {
        suggestions = []
        status = [:]
        isReviewMode = false
        inspected = false
        selectedID = nil
    }

    public func beginReview(with new: [WritingSuggestion]) {
        clear()
        add(new)
        isReviewMode = true
        selectedID = pending.first?.id
    }

    /// The UI calls this once the suggestion list is on screen.
    public func markInspected() { inspected = true }
    public func endReview() { isReviewMode = false; inspected = false }

    public func reject(_ id: UUID) throws {
        guard status[id] != nil else { throw ReviewError.unknownSuggestion }
        guard status[id] == .pending else { throw ReviewError.notPending }
        status[id] = .rejected
        advanceSelection(from: id)
    }

    /// Where the suggestion applies in the current text, or why it cannot.
    public func resolve(_ id: UUID, in target: TextMutationTarget) -> AnchorResolution? {
        guard let s = suggestions.first(where: { $0.id == id }) else { return nil }
        return AnchorResolver.resolve(s.anchor, revision: s.documentRevision, in: target.currentSnapshot)
    }

    /// The one place a suggestion becomes an edit. Requires a user action.
    @discardableResult
    public func accept(_ id: UUID, in target: TextMutationTarget) throws -> TextSpan {
        guard let s = suggestions.first(where: { $0.id == id }) else { throw ReviewError.unknownSuggestion }
        guard status[id] == .pending else { throw ReviewError.notPending }
        let resolution = AnchorResolver.resolve(s.anchor, revision: s.documentRevision, in: target.currentSnapshot)
        guard let range = resolution.range else {
            if case .stale(let why) = resolution { status[id] = .stale(why); throw ReviewError.stale(why) }
            throw ReviewError.stale("unresolved")
        }
        target.replace(range, with: s.proposedText, actionName: "Accept Suggestion")
        status[id] = .accepted
        advanceSelection(from: id)
        return TextSpan(location: range.location, length: s.proposedText.utf16Length)
    }

    /// Accept every pending suggestion. Only inside review mode, and only after
    /// the suggestions have been displayed for inspection.
    @discardableResult
    public func acceptAll(in target: TextMutationTarget) throws -> Int {
        guard isReviewMode else { throw ReviewError.acceptAllOutsideReview }
        guard inspected else { throw ReviewError.notInspected }
        var applied = 0
        // Later passages first, so earlier ones keep their offsets; each is
        // still re-resolved against the current text.
        let ordered = pending.sorted { $0.anchor.range.location > $1.anchor.range.location }
        for s in ordered {
            if (try? accept(s.id, in: target)) != nil { applied += 1 }
        }
        return applied
    }

    /// Undo of an accepted edit: the suggestion is pending again. Text is not
    /// touched here — the undo manager has already restored it.
    public func reopen(_ id: UUID) {
        guard status[id] == .accepted else { return }
        status[id] = .pending
        selectedID = id
    }

    /// Redo of an accepted edit.
    public func markAccepted(_ id: UUID) {
        guard status[id] == .pending else { return }
        status[id] = .accepted
        advanceSelection(from: id)
    }

    public func select(offset: Int) {
        let p = pending
        guard !p.isEmpty else { selectedID = nil; return }
        let i = p.firstIndex { $0.id == selectedID } ?? -offset
        selectedID = p[((i + offset) % p.count + p.count) % p.count].id
    }

    func advanceSelection(from id: UUID) {
        guard selectedID == id else { return }
        let order = suggestions.map(\.id)
        let idx = order.firstIndex(of: id) ?? 0
        selectedID = (order[(idx + 1)...] + order[..<idx]).first { status[$0] == .pending }
    }
}
