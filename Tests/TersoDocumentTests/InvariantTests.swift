// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
import TersoCore
import TersoAI
@testable import TersoDocument

/// AI must never silently modify the document.
@MainActor
@Suite struct SafetyInvariantTests {
    let original = "The experiment was very clearly able to demonstrate the effect. Results were good."

    func suggestionsFromProvider(_ buffer: TextBuffer) async throws -> [WritingSuggestion] {
        let provider = ScriptedProvider { _ in
            #"{"message":"m","suggestions":[{"original":"was very clearly able to demonstrate","proposed":"demonstrated","explanation":"Removes qualifiers."},{"original":"Results were good.","proposed":"The results held.","explanation":"x"}]}"#
        }
        let snap = buffer.currentSnapshot
        let ctx = ContextPayload.make(scope: .document, snapshot: snap, selection: TextSpan(location: 0, length: 0))
        let resp = try await provider.analyze(AnalysisRequest(task: .reviewDocument, context: ctx))
        return SuggestionBuilder.build(resp.proposals, context: ctx, snapshot: snap, provider: provider.id).suggestions
    }

    @Test func analysisAndSuggestionsNeverMutate() async throws {
        let buffer = TextBuffer(original)
        let review = SuggestionReview()
        let s = try await suggestionsFromProvider(buffer)
        review.add(s)
        review.select(offset: 1)
        _ = review.resolve(s[0].id, in: buffer)
        try review.reject(s[1].id)
        #expect(buffer.text == original)
        #expect(buffer.revision == DocumentRevision(0))
    }

    @Test func onlyAcceptMutates() async throws {
        let buffer = TextBuffer(original)
        let review = SuggestionReview()
        let s = try await suggestionsFromProvider(buffer)
        review.add(s)
        try review.accept(s[0].id, in: buffer)
        #expect(buffer.text == "The experiment demonstrated the effect. Results were good.")
        #expect(review.status[s[0].id] == .accepted)
        #expect(throws: ReviewError.notPending) { try review.accept(s[0].id, in: buffer) }
    }

    @Test func staleSuggestionIsRefused() async throws {
        let buffer = TextBuffer(original)
        let review = SuggestionReview()
        let s = try await suggestionsFromProvider(buffer)
        review.add(s)
        // Writer edits the passage after the suggestion was produced.
        let r = (buffer.text as NSString).range(of: "very clearly")
        buffer.userEdit(TextSpan(r), with: "plainly")
        let before = buffer.text
        #expect(throws: ReviewError.self) { try review.accept(s[0].id, in: buffer) }
        #expect(buffer.text == before)
        if case .stale = review.status[s[0].id] {} else { Issue.record("expected stale status") }
    }

    @Test func relocatesAfterUnrelatedEdit() async throws {
        let buffer = TextBuffer(original)
        let review = SuggestionReview()
        let s = try await suggestionsFromProvider(buffer)
        review.add(s)
        buffer.userEdit(TextSpan(location: 0, length: 0), with: "Preface. ")
        try review.accept(s[1].id, in: buffer)
        #expect(buffer.text.hasSuffix("The results held."))
        #expect(buffer.text.hasPrefix("Preface. The experiment was very clearly"))
    }

    @Test func acceptAllRequiresReviewModeAndInspection() async throws {
        let buffer = TextBuffer(original)
        let review = SuggestionReview()
        let s = try await suggestionsFromProvider(buffer)
        review.add(s)
        #expect(throws: ReviewError.acceptAllOutsideReview) { try review.acceptAll(in: buffer) }
        review.beginReview(with: s)
        #expect(throws: ReviewError.notInspected) { try review.acceptAll(in: buffer) }
        #expect(buffer.text == original)
        review.markInspected()
        #expect(try review.acceptAll(in: buffer) == 2)
        #expect(buffer.text == "The experiment demonstrated the effect. The results held.")
    }
}

@MainActor
@Suite struct ReopenTests {
    @Test func reopenOnlyChangesStatus() {
        let buffer = TextBuffer("alpha beta")
        let snap = buffer.currentSnapshot
        let s = WritingSuggestion(documentRevision: snap.revision, anchor: TextAnchor(range: TextSpan(location: 6, length: 4), in: snap)!,
                                  proposedText: "gamma", explanation: nil, provider: ProviderID("t"))
        let review = SuggestionReview()
        review.add([s])
        review.reopen(s.id)                       // not accepted yet: no-op
        #expect(review.status[s.id] == .pending)
        try? review.accept(s.id, in: buffer)
        let text = buffer.text
        review.reopen(s.id)
        #expect(review.status[s.id] == .pending)
        #expect(buffer.text == text)              // reopening never edits
        review.markAccepted(s.id)
        #expect(review.status[s.id] == .accepted)
    }
}

/// A suggestion whose passage was edited is shown in its passage but can't be applied.
@MainActor
@Suite struct StaleSuggestionTests {
    @Test func staleSuggestionIsRefusedAndStillGrouped() throws {
        let text = "The experiment was very clearly able to demonstrate the effect. Results were good."
        let buffer = TextBuffer(text)
        let snap = buffer.currentSnapshot
        let r = (text as NSString).range(of: "was very clearly able to demonstrate")
        let s = WritingSuggestion(documentRevision: snap.revision, anchor: try #require(TextAnchor(range: TextSpan(r), in: snap)),
                                  proposedText: "demonstrated", explanation: nil, provider: ProviderID("local.apple"))
        let review = SuggestionReview()
        review.add([s])
        // The writer edits inside the anchored passage.
        buffer.userEdit(TextSpan((buffer.text as NSString).range(of: "very clearly")), with: "plainly")
        let resolution = AnchorResolver.resolve(s.anchor, revision: s.documentRevision, in: buffer.currentSnapshot)
        guard case .stale = resolution else { Issue.record("expected stale"); return }
        // Presented at its original range, it still groups with the sentence.
        let ann = TextAnnotation(id: s.id, source: .aiSuggestion, category: .aiSuggestion, ranges: [s.anchor.range],
                                 severity: .suggestion, message: "Suggested revision", explanation: nil, revision: s.documentRevision)
        let sentences = ProseText(markdown: buffer.text).sentences.map(\.range)
        #expect(ReviewGrouping.passages([ann], sentences: sentences).count == 1)
        let before = buffer.text
        #expect(throws: ReviewError.self) { try review.accept(s.id, in: buffer) }
        #expect(buffer.text == before)
        // Rejecting a stale suggestion is allowed only while pending; it is now stale.
        if case .stale = review.status[s.id] {} else { Issue.record("expected stale status") }
    }

    @Test func rejectLeavesTextAndAcceptAppliesOnce() throws {
        let buffer = TextBuffer("We utilize a simple model.")
        let snap = buffer.currentSnapshot
        let a = WritingSuggestion(documentRevision: snap.revision, anchor: try #require(TextAnchor(range: TextSpan(location: 3, length: 7), in: snap)),
                                  proposedText: "use", explanation: nil, provider: ProviderID("t"))
        let b = WritingSuggestion(documentRevision: snap.revision, anchor: try #require(TextAnchor(range: TextSpan(location: 13, length: 6), in: snap)),
                                  proposedText: "basic", explanation: nil, provider: ProviderID("t"))
        let review = SuggestionReview()
        review.add([a, b])
        try review.reject(b.id)
        #expect(buffer.text == "We utilize a simple model.")
        try review.accept(a.id, in: buffer)
        #expect(buffer.text == "We use a simple model.")
        #expect(throws: ReviewError.notPending) { try review.accept(b.id, in: buffer) }
    }
}
