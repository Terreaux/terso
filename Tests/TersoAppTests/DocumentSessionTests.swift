// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import Testing
import TersoAI
import TersoCore
@testable import TersoApp

@Suite @MainActor struct DocumentSessionTests {
    @Test func tenIndependentDocumentsAnalyzeWithoutFocusRouting() async throws {
        let models = (0..<10).map { _ in WorkspaceModel() }
        let editors = models.enumerated().map { index, model in
            SessionEditor(model, text: "# Document \(index)\n\n" + String(repeating:
                "It is important to note that we utilize the the data very carefully. Let $x_\(index)$ be a mass of \(index + 1) GeV.\n\n", count: 12))
        }
        for (model, editor) in zip(models, editors) {
            model.editor = editor
            model.scheduleAnalysis()
        }
        // Supersede an in-flight revision, while all other documents continue.
        editors[0].text = "Birds sing."
        models[0].textDidChange()
        models[1].inspectorTab = .science
        models[1].showInspector = true
        models[1].dismissed.insert("only-document-one")
        try await eventually { models.allSatisfy { $0.local?.revision == $0.revision } }
        #expect(models[0].local?.statistics.words == 2)
        #expect(models[0].local?.science.symbols.isEmpty == true)
        for i in 1..<10 {
            #expect(models[i].local?.statistics.words ?? 0 > 100)
            #expect(models[i].local?.science.symbols.isEmpty == false)
            #expect(models[i].localAnnotations.allSatisfy { $0.revision == models[i].revision })
        }
        #expect(models[0].dismissed.isEmpty)
        #expect(models[0].inspectorTab == .review)
        #expect(!models[0].showInspector)
        #expect(models[2].exchanges.isEmpty)
        withExtendedLifetime(editors) {}
    }

    @Test func delayedAIStaysWithOriginatingDocumentAndRevision() async throws {
        let a = WorkspaceModel(), b = WorkspaceModel()
        let editorA = SessionEditor(a, text: "Alpha original."), editorB = SessionEditor(b, text: "Beta original.")
        a.editor = editorA; b.editor = editorB
        let provider = DelayedProvider()
        start(a, editor: editorA, provider: provider)
        try await eventually { await provider.waiting }
        b.showInspector = true; b.inspectorTab = .ai
        editorA.text = "Alpha changed."; a.textDidChange()
        await provider.finish("Alpha original.")
        try await eventually { a.exchanges.first?.running == false }
        #expect(a.exchanges.first?.message == "Alpha original.")
        #expect(a.review.pending.count == 1)
        #expect(a.review.pending.first?.documentRevision == DocumentRevision(0))
        #expect(b.exchanges.isEmpty && b.review.pending.isEmpty)
        #expect(editorA.text == "Alpha changed.")
        #expect(editorB.text == "Beta original.")
    }

    @Test func cancelledProviderCannotPublishOrOverwriteNewFindingRequest() async throws {
        let model = WorkspaceModel()
        let editor = SessionEditor(model, text: "Alpha original.")
        let old = DelayedProvider(), new = DelayedProvider()
        let finding = TextAnnotation(source: .rule, category: .style,
                                     ranges: [TextSpan(location: 0, length: 5)], severity: .suggestion,
                                     message: "Finding", explanation: nil, revision: DocumentRevision(0))
        start(model, editor: editor, provider: old, target: finding)
        try await eventually { await old.waiting }
        start(model, editor: editor, provider: new, target: finding)
        try await eventually { await new.waiting }
        let newID = model.request(for: finding)?.id
        // This provider deliberately ignores cancellation and returns anyway.
        await old.finish("Alpha original.")
        for _ in 0..<20 { await Task.yield() }
        #expect(model.review.pending.isEmpty)
        #expect(model.request(for: finding)?.id == newID)
        #expect(model.request(for: finding)?.running == true)
        await new.finish("Alpha original.")
        try await eventually { model.request(for: finding)?.running == false }
        #expect(model.review.pending.count == 1)
        #expect(model.request(for: finding)?.id == newID)
    }

    @Test func scienceNavigationRevealsSourceWithoutMovingCaretAndRejectsStaleResults() async throws {
        let model = WorkspaceModel()
        let editor = SessionEditor(model, text: "A result uses $q$. Let $q$ denote momentum.")
        model.editor = editor
        model.scheduleAnalysis()
        try await eventually { model.local?.revision == model.revision }
        let symbol = try #require(model.local?.science.symbols.first { $0.canonicalForm == "q" })
        let insertionPoint = editor.selection
        model.navigateScience(objectID: "symbol:q", range: symbol.firstOccurrence)
        #expect(model.selectedScienceObjectID == "symbol:q")
        #expect(model.scienceEmphasisRange == symbol.firstOccurrence)
        #expect(editor.revealedRange == symbol.firstOccurrence)
        #expect(editor.selection == insertionPoint)
        model.scienceDetailSection = "Notation"
        model.inspectorTab = .review; model.inspectorTab = .science
        #expect(model.scienceDetailSection == "Notation")
        editor.text = "Short."
        model.textDidChange()
        #expect(model.scienceEmphasisRange == nil)
        editor.revealedRange = nil
        model.navigateScience(objectID: "stale", range: symbol.firstOccurrence)
        #expect(editor.revealedRange == nil)
        #expect(model.selectedScienceObjectID == nil)
    }

    @Test func scientificAnnotationSelectsDiagnosticInScienceWithoutScrolling() async throws {
        let model = WorkspaceModel()
        let editor = SessionEditor(model, text: "See \\eqref{eq:missing} for the result.")
        model.editor = editor
        model.scheduleAnalysis()
        try await eventually { model.local?.revision == model.revision }
        let diagnostic = try #require(model.scienceDiagnostics.first { $0.title.contains("Broken") })
        let annotation = try #require(model.scienceAnnotation(for: diagnostic))
        #expect(model.selectScienceAnnotation(annotation, reveal: false))
        #expect(model.selectedScienceObjectID == diagnostic.id)
        #expect(model.scienceDetailSection == "Needs attention")
        #expect(model.inspectorTab == .science)
        #expect(editor.revealedRange == nil)
        model.selectScienceDiagnostic(diagnostic)
        #expect(editor.revealedRange == diagnostic.sourceRange)
    }

    @Test func latestProfileWinsWithoutChangingDocumentRevision() async throws {
        let model = WorkspaceModel()
        let editor = SessionEditor(model, text: String(repeating: "The mass is $m_H = 125.25 \\pm 0.17$ GeV.\n\n", count: 20))
        model.editor = editor
        model.scienceProfile = .hep
        model.scheduleAnalysis()
        try await eventually { model.currentScience?.profile.id == "particle-physics" }
        model.scienceProfile = .general
        #expect(model.currentScience == nil)
        #expect(!model.visibleAnnotations.contains { $0.metadata["scienceDiagnosticID"] != nil })
        model.scienceProfile = .hep
        model.scienceProfile = .general
        try await eventually { model.local?.science.profile.id == "general" }
        #expect(model.revision == DocumentRevision(0))
        #expect(model.local?.science.profile.id == model.scienceProfile.id)
    }

    @Test func scienceReviewDecisionsStayLocalAndSurviveReanalysis() async throws {
        let model = WorkspaceModel(), other = WorkspaceModel()
        let editor = SessionEditor(model, text: "This proves the approximation.")
        model.editor = editor
        model.scheduleAnalysis()
        try await eventually { model.currentScience != nil }
        let claim = try #require(model.currentScience?.claims.first)
        let warning = try #require(model.scienceDiagnostics.first)
        model.markScienceClaim(claim, asAuthorStatement: true)
        #expect(model.scienceDiagnostics.isEmpty)
        #expect(model.scienceReview.authorStatements.contains(claim.text))
        #expect(other.scienceReview.authorStatements.isEmpty)
        #expect(editor.text == claim.text)
        editor.text = "New preface.\n\n" + editor.text
        model.textDidChange()
        try await eventually { model.currentScience != nil }
        #expect(model.scienceDiagnostics.isEmpty)
        #expect(model.currentScience?.diagnostics.first?.id != warning.id)
        model.restoreScienceWarnings()
        #expect(model.scienceDiagnostics.count == 1)
        #expect(model.scienceReview.authorStatements.isEmpty)
        let restored = try #require(model.scienceDiagnostics.first)
        model.ignoreScienceDiagnostic(restored)
        #expect(model.scienceDiagnostics.isEmpty)
        #expect(model.scienceReview.ignoredClaims.contains(claim.text))
    }

    @Test func analysisHoverIsTransientLocalAndDoesNotNavigate() async throws {
        let model = WorkspaceModel(), other = WorkspaceModel()
        let editor = SessionEditor(model, text: "See \\eqref{eq:missing}. This proves the approximation.")
        model.editor = editor; model.scheduleAnalysis()
        try await eventually { model.currentScience != nil }
        let diagnostic = try #require(model.scienceDiagnostics.first)
        let annotation = try #require(model.scienceAnnotation(for: diagnostic))
        model.inspectorTab = .science
        model.selectScienceDiagnostic(diagnostic, reveal: false)
        let selected = model.selectedScienceObjectID
        let caret = editor.selection
        model.previewAnnotation(annotation.id)
        #expect(model.previewScienceDiagnosticID == diagnostic.id)
        #expect(other.previewAnnotationID == nil)
        #expect(model.selectedScienceObjectID == selected)
        #expect(editor.revealedRange == nil && editor.selection == caret)
        model.previewAnnotation(nil)
        #expect(model.previewAnnotationID == nil)
        #expect(model.selectedScienceObjectID == selected)
        model.previewAnnotation(annotation.id)
        model.textDidChange()
        #expect(model.previewAnnotationID == nil)
        model.previewAnnotation(annotation.id)
        #expect(model.previewAnnotationID == nil)
    }

    @Test func attentionDisclosureAndDiagnosticsStayDocumentLocal() async throws {
        let model = WorkspaceModel(), other = WorkspaceModel()
        let editor = SessionEditor(model, text: (0..<24).map { "See \\eqref{missing:\($0)}." }.joined(separator: "\n\n"))
        model.editor = editor; model.scheduleAnalysis()
        try await eventually { model.currentScience != nil }
        #expect(model.scienceDiagnostics.count == 24)
        #expect(!model.scienceReview.attentionExpanded)
        model.scienceReview.attentionExpanded = true
        model.inspectorTab = .review; model.inspectorTab = .science
        #expect(model.scienceReview.attentionExpanded)
        #expect(!other.scienceReview.attentionExpanded)
        #expect(model.scienceDiagnostics.map(\.sourceRange) == model.scienceDiagnostics.map(\.sourceRange).sorted())
        let last = try #require(model.scienceDiagnostics.last)
        model.selectScienceDiagnostic(last)
        #expect(editor.revealedRange == last.sourceRange)
    }

    private func start(_ model: WorkspaceModel, editor: SessionEditor, provider: DelayedProvider, target: TextAnnotation? = nil) {
        let snapshot = editor.currentSnapshot
        let context = ContextPayload.make(scope: .document, snapshot: snapshot, selection: editor.selection)
        model.startAI(task: .reviewDocument, question: nil, context: context, snapshot: snapshot, provider: provider, target: target)
    }

    private func eventually(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !(await predicate()) {
            if ContinuousClock.now >= deadline { Issue.record("Timed out waiting for document work"); return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

@MainActor private final class SessionEditor: EditorController {
    let model: WorkspaceModel
    var text: String
    var selection = TextSpan(location: 0, length: 0)
    var revealedRange: TextSpan?
    let undoManager: UndoManager? = UndoManager()
    var currentSnapshot: DocumentSnapshot { .init(revision: model.revision, text: text) }
    init(_ model: WorkspaceModel, text: String) { self.model = model; self.text = text }
    func replace(_ range: TextSpan, with text: String, actionName: String) {}
    func reveal(_ range: TextSpan, select: Bool) { revealedRange = range; if select { selection = range } }
    func wrapSelection(prefix: String, suffix: String, placeholder: String) {}
    func prefixLines(_ marker: String) {}
    func refreshDecorations() {}
    func explainAtCaret() {}
}

private actor DelayedProvider: WritingAssistantProvider {
    nonisolated let id = ProviderID("test.delayed")
    nonisolated let displayName = "Delayed test provider"
    nonisolated let locality = ProviderLocality.local
    nonisolated let capabilities: Set<ProviderCapability> = [.reviewDocument]
    private var continuation: CheckedContinuation<AnalysisResponse, Never>?
    var waiting: Bool { continuation != nil }
    func analyze(_ request: AnalysisRequest) async throws -> AnalysisResponse {
        await withCheckedContinuation { continuation = $0 }
    }
    func finish(_ original: String) {
        continuation?.resume(returning: AnalysisResponse(message: original, proposals: [
            ProposedRevision(original: original, proposed: "Revised.", explanation: nil, kind: nil)
        ]))
        continuation = nil
    }
}
