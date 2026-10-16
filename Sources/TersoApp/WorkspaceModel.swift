// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import Observation
import TersoAI
import TersoAnalysis
import TersoCore
import TersoDocument
import TersoStyle

/// What the editor exposes to the rest of the window.
@MainActor
protocol EditorController: TextMutationTarget {
    var selection: TextSpan { get }
    var undoManager: UndoManager? { get }
    func reveal(_ range: TextSpan, select: Bool)
    func wrapSelection(prefix: String, suffix: String, placeholder: String)
    func prefixLines(_ marker: String)
    func refreshDecorations()
    func explainAtCaret()
}

enum InspectorTab: String, CaseIterable, Identifiable {
    case review = "Review", ai = "Assistant", science = "Science", statistics = "Statistics"
    /// The book's design: only while Manutius sets the document as pages.
    case book = "Book"
    var id: String { rawValue }
}

struct AIExchange: Identifiable {
    let id = UUID()
    let task: AssistantTask
    let question: String?
    let scope: ContextScope
    let words: Int
    let providerName: String
    let locality: ProviderLocality
    var message: String?
    var error: String?
    var discarded = 0
    var running = true
}

/// An AI request made from one finding (Explain / Suggest rewrite). Its
/// result is shown with the finding in Review, not in the Assistant.
struct IssueRequest {
    var id = UUID()
    let task: AssistantTask
    var running = true
    var message: String?
    var error: String?
    var suggestionIDs: [UUID] = []
    /// Proposals that could not be matched to the text.
    var discarded = 0
}

struct MapMarker: Identifiable, Hashable {
    let id: UUID
    let fraction: CGFloat
    let family: AnnotationFamily
    let severity: Severity
    let category: AnnotationCategory
    let range: TextSpan
    let message: String
    var severityLabel: String? = nil
    var explanation: String? = nil
}

/// One document session, retained by its TabDocument. Moving tabs between windows
/// preserves this identity. Analysis, suggestions and revision belong to this
/// document; selection, inspector and focus state follow its tab. Only user
/// preferences are shared. TabDocument owns the persisted text and file URL.
@MainActor
@Observable
final class WorkspaceModel {
    let prefs = Preferences.shared
    weak var editor: (any EditorController)?

    var showSidebar = false
    var documentUndoManager: UndoManager?
    var renderMode: RenderMode = .mixed
    var scienceProfile: ScientificProfile = .hep { didSet { scheduleAnalysis() } }
    var fileURL: URL?
    private(set) var revision = DocumentRevision(0)
    private(set) var local: LocalAnalysisResult?
    private(set) var style: StyleReport?
    private(set) var spelling: [TextAnnotation] = []
    /// Annotations from the last analysis, built once so their IDs are stable
    /// within a pass (reports compute fresh annotations on every access).
    private(set) var localAnnotations: [TextAnnotation] = []
    private(set) var styleAnnotations: [TextAnnotation] = []
    /// Sentence ranges from the last analysis, for grouping findings into passages.
    private(set) var sentenceSpans: [TextSpan] = []
    /// Dismissed findings, by stable key so they stay dismissed after re-analysis.
    var dismissed: Set<String> = []

    /// The selected finding within the selected passage (nil: the whole passage).
    private(set) var activeAnnotationID: UUID?
    /// What was selected, by stable key, so selection survives re-analysis
    /// (finding IDs are new on every pass).
    private var selectedKey: (key: String, location: Int)?
    private var passageKey: (key: String, location: Int)?
    var hoveredClusterID: Int?
    private(set) var previewAnnotationID: UUID?

    /// Shared transient hover; does not change selection, focus, or scroll.
    func previewAnnotation(_ id: UUID?) {
        let valid = id.flatMap { candidate in visibleAnnotations.first { $0.id == candidate }?.id }
        guard previewAnnotationID != valid else { return }
        previewAnnotationID = valid
        editor?.refreshDecorations()
    }

    var previewScienceDiagnosticID: String? {
        annotation(id: previewAnnotationID)?.metadata["scienceDiagnosticID"]
    }
    /// Science navigation belongs to this document session, including tab switches.
    let scienceReview = ScienceReviewState()
    var scienceDetailSection: String?
    private(set) var selectedScienceObjectID: String?
    private(set) var scienceEmphasisRange: TextSpan?
    @ObservationIgnored private var scienceEmphasisTask: Task<Void, Never>?
    @ObservationIgnored private var analysisGeneration = UUID()

    var showInspector = false
    var inspectorTab: InspectorTab = .review
    var focusMode = false
    var typewriter = false
    /// Manutius: the document set as book pages, still editable.
    var manutius = false
    /// Manutius's whole-book view: every page as spreads.
    var showBookOverview = false
    /// Manutius's chapters and pages as last laid out, for the sidebars.
    var bookOutline = BookOutline()
    /// The sheet that edits the book's title page, dedication and the rest.
    var showBookDetails = false

    /// The book's design lives in the inspector, beside Review.
    func showBookDesign() {
        inspectorTab = .book
        showInspector = true
    }
    /// Zen: Focus plus no tab bar, full screen, nothing on screen but the text.
    private(set) var zenMode = false
    @ObservationIgnored private var zenEnteredFullScreen = false
    /// Focused Review: walk findings one at a time; other annotations recede.
    private(set) var focusedReview = false
    var showAskPanel = false
    var showDocumentReport = false
    /// The writing stats sheet, open at a tab.
    var writingStats: WritingStatsTab?
    var mapMarkers: [MapMarker] = []

    var thesaurusRequest: ThesaurusRequest?
    let review = SuggestionReview()
    var exchanges: [AIExchange] = []
    private(set) var issueRequests: [String: IssueRequest] = [:]
    @ObservationIgnored private var analysisTask: Task<Void, Never>?
    @ObservationIgnored private var aiTask: Task<Void, Never>?
    private let spellingLayer = SpellingLayer()

    deinit {
        analysisTask?.cancel()
        aiTask?.cancel()
        scienceEmphasisTask?.cancel()
    }

    // MARK: Text lifecycle

    func textDidChange() {
        revision = revision.next()
        selectedScienceObjectID = nil
        previewAnnotation(nil)
        scienceReview.occurrencePositions.removeAll()
        scienceEmphasisTask?.cancel()
        scienceEmphasisRange = nil
        scheduleAnalysis(delay: .milliseconds(400))
    }

    func scheduleAnalysis(delay: Duration = .zero) {
        previewAnnotation(nil)
        analysisTask?.cancel()
        let generation = UUID()
        analysisGeneration = generation
        guard let snap = editor?.currentSnapshot else { return }
        let domain = prefs.domain
        let scienceProfile = scienceProfile
        analysisTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            // Analysis runs off the main actor on an immutable snapshot.
            let work = Task.detached(priority: .utility) {
                try Task.checkCancellation()
                let prose = ProseText(snap)
                try Task.checkCancellation()
                let local = WritingAnalyzer(profile: scienceProfile).analyze(snap)
                try Task.checkCancellation()
                let style = StyleEngine().analyze(snap, domain: domain)
                try Task.checkCancellation()
                return (local, style, prose.masked, prose.sentences.map(\.range))
            }
            let result = await withTaskCancellationHandler {
                try? await work.value
            } onCancel: {
                work.cancel()
            }
            guard let (local, style, masked, sentences) = result else { return }
            guard let self, !Task.isCancelled, self.revision == snap.revision, self.analysisGeneration == generation else { return }
            self.local = local
            self.sentenceSpans = sentences
            self.style = style
            self.localAnnotations = local.annotations
            self.styleAnnotations = style.annotations
            self.reselect()
            self.editor?.refreshDecorations()
            self.spellingLayer.check(snap, masked: masked) { [weak self] found in
                // Drop results for text that has since changed.
                guard let self, self.revision == snap.revision, self.analysisGeneration == generation else { return }
                self.spelling = found
                self.reselect()
                self.editor?.refreshDecorations()
            }
        }
    }

    // MARK: Findings

    var aiSuggestionAnnotations: [TextAnnotation] {
        let pending = review.pending
        guard !pending.isEmpty, let snap = editor?.currentSnapshot else { return [] }
        return pending.map { s in
            let resolution = AnchorResolver.resolve(s.anchor, revision: s.documentRevision, in: snap)
            var meta = ["text": s.originalText, "provider": s.provider.rawValue]
            if case .stale = resolution { meta["stale"] = "true" }
            return TextAnnotation(id: s.id, source: .aiSuggestion, category: .aiSuggestion, ranges: [resolution.range ?? s.anchor.range],
                                  severity: .suggestion, message: s.kind.map { "Suggested \($0)" } ?? "Suggested revision",
                                  explanation: s.explanation, consider: s.proposedText, revision: s.documentRevision, metadata: meta)
        }
    }

    var allAnnotations: [TextAnnotation] {
        localAnnotations + styleAnnotations + spelling + aiSuggestionAnnotations
    }

    /// Findings on enabled layers, minus dismissed ones. Layers are
    /// presentation only; toggling one never touches the text.
    var visibleAnnotations: [TextAnnotation] {
        let scienceIsCurrent = currentScience != nil
        return allAnnotations.filter {
            ($0.revision == revision || $0.source == .aiSuggestion)
                && ($0.metadata["scienceDiagnosticID"] == nil || scienceIsCurrent)
                && prefs.enabledLayers.contains($0.category) && !dismissed.contains($0.dismissalKey)
        }
    }

    /// What the document draws: nothing in Focus mode; only the current
    /// passage during Focused Review.
    var drawnAnnotations: [TextAnnotation] {
        if focusMode { return [] }
        if focusedReview, let p = selectedPassage {
            let ids = Set(p.findingIDs)
            return visibleAnnotations.filter { ids.contains($0.id) }
        }
        return visibleAnnotations
    }

    /// Every finding, in document order.
    var reviewFindings: [TextAnnotation] { AnnotationLayout.ordered(visibleAnnotations) }

    /// Places worth reviewing: findings grouped by the sentences they touch.
    var reviewPassages: [ReviewPassage] { ReviewGrouping.passages(visibleAnnotations, sentences: sentenceSpans) }

    func findings(in p: ReviewPassage) -> [TextAnnotation] {
        let byID = Dictionary(visibleAnnotations.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return p.findingIDs.compactMap { byID[$0] }
    }

    func count(_ c: AnnotationCategory) -> Int {
        allAnnotations.filter { $0.category == c && !dismissed.contains($0.dismissalKey) }.count
    }

    func annotation(id: UUID?) -> TextAnnotation? {
        guard let id else { return nil }
        return allAnnotations.first { $0.id == id }
    }

    var selectedFinding: TextAnnotation? { annotation(id: activeAnnotationID) }

    /// The passage containing the selection.
    var selectedPassage: ReviewPassage? {
        guard let key = passageKey else { return nil }
        let passages = reviewPassages
        let match = visibleAnnotations.filter { $0.dismissalKey == key.key }
            .min { abs(($0.ranges.first?.location ?? 0) - key.location) < abs(($1.ranges.first?.location ?? 0) - key.location) }
        return match.flatMap { m in passages.first { $0.findingIDs.contains(m.id) } }
    }

    /// Show or hide several layers at once (the header's highlight group).
    func setLayers(_ categories: [AnnotationCategory], visible: Bool) {
        if visible { prefs.enabledLayers.formUnion(categories) } else { prefs.enabledLayers.subtract(categories) }
        reselect()
        editor?.refreshDecorations()
    }

    func toggleLayer(_ c: AnnotationCategory) {
        if prefs.enabledLayers.contains(c) { prefs.enabledLayers.remove(c) } else { prefs.enabledLayers.insert(c) }
        reselect()
        editor?.refreshDecorations()
    }

    // MARK: Selection and navigation

    /// Reveal a semantic object without changing the insertion point or first responder.
    /// The same layout-manager treatment used by Review supplies a brief emphasis.
    func navigateScience(objectID: String, range: TextSpan, reveal: Bool = true) {
        guard let snapshot = editor?.currentSnapshot, currentScience != nil,
              range.location >= 0, range.length > 0, range.upperBound <= snapshot.utf16Length else { return }
        selectedScienceObjectID = objectID
        selectedKey = nil; passageKey = nil; activeAnnotationID = nil
        scienceEmphasisTask?.cancel()
        scienceEmphasisRange = range
        if reveal { editor?.reveal(range, select: false) }
        editor?.refreshDecorations()
        scienceEmphasisTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.scienceEmphasisRange = nil
            self.editor?.refreshDecorations()
        }
    }

    private func anchor(_ a: TextAnnotation) -> (key: String, location: Int) { (a.dismissalKey, a.ranges.first?.location ?? 0) }

    /// Select a whole passage: its range is highlighted and its findings listed.
    func selectPassage(_ p: ReviewPassage?, reveal: Bool = true) {
        guard let p, let primary = annotation(id: p.primaryID) else {
            passageKey = nil; selectedKey = nil; activeAnnotationID = nil
            editor?.refreshDecorations()
            return
        }
        passageKey = anchor(primary)
        selectedKey = nil
        activeAnnotationID = nil
        if reveal { editor?.reveal(p.range, select: false) }
        editor?.refreshDecorations()
    }

    /// Select one finding: its narrower range is highlighted, inside its passage.
    func select(_ a: TextAnnotation?, reveal: Bool = true) {
        guard let a else { selectPassage(nil); return }
        if let p = reviewPassages.first(where: { $0.findingIDs.contains(a.id) }), let primary = annotation(id: p.primaryID) {
            passageKey = anchor(primary)
        } else {
            passageKey = anchor(a)
        }
        activeAnnotationID = a.id
        selectedKey = anchor(a)
        if reveal, let r = a.ranges.first { editor?.reveal(r, select: false) }
        editor?.refreshDecorations()
    }

    /// Re-find the selection after re-analysis (IDs change every pass).
    private func reselect() {
        guard let key = selectedKey else { activeAnnotationID = nil; return }
        let match = visibleAnnotations.filter { $0.dismissalKey == key.key }
            .min { abs(($0.ranges.first?.location ?? 0) - key.location) < abs(($1.ranges.first?.location ?? 0) - key.location) }
        activeAnnotationID = match?.id
        if match == nil { selectedKey = nil }
    }

    var selectedPassageIndex: Int? { ReviewQueue(reviewPassages).index(of: selectedPassage?.id) }
    var selectedIndex: Int? { selectedPassageIndex }

    /// Next / previous passage, from the selection or the caret.
    func selectFinding(offset: Int) {
        let q = ReviewQueue(reviewPassages)
        selectPassage(q.step(from: selectedPassage?.id, caret: editor?.selection.location ?? 0, offset: offset))
    }

    func dismiss(_ id: UUID) {
        if review.status[id] == .pending { try? review.reject(id) } else if let a = annotation(id: id) { dismissed.insert(a.dismissalKey) }
        if activeAnnotationID == id { activeAnnotationID = nil; selectedKey = nil }
        editor?.refreshDecorations()
    }

    /// Hide every finding in a passage and move to the next one.
    func ignorePassage(_ p: ReviewPassage) {
        let next = ReviewQueue(reviewPassages).step(from: p.id, caret: 0, offset: 1)
        let nextPrimary = next.flatMap { annotation(id: $0.primaryID) }
        for a in findings(in: p) {
            if review.status[a.id] == .pending { try? review.reject(a.id) } else { dismissed.insert(a.dismissalKey) }
        }
        if let nextPrimary, next?.id != p.id, let n = reviewPassages.first(where: { $0.findingIDs.contains(nextPrimary.id) }) {
            selectPassage(n)
        } else {
            selectPassage(nil)
            if focusedReview { endFocusedReview() }
        }
    }

    /// Dismiss one finding; stay in its passage while anything is left there.
    func ignore(_ a: TextAnnotation) {
        let passage = reviewPassages.first { $0.findingIDs.contains(a.id) }
        let remaining = passage.map { findings(in: $0).filter { $0.id != a.id } } ?? []
        dismiss(a.id)
        if let first = remaining.first, let p = reviewPassages.first(where: { $0.findingIDs.contains(first.id) }) {
            selectPassage(p, reveal: false)
        } else if let passage {
            let q = ReviewQueue(reviewPassages)
            selectPassage(q.step(from: nil, caret: passage.range.location, offset: 1))
        }
    }

    func startFocusedReview() {
        focusedReview = true
        if focusMode { toggleFocusMode() }
        showInspector = true
        inspectorTab = .review
        if selectedPassage == nil { selectFinding(offset: 1) } else { editor?.refreshDecorations() }
    }

    func endFocusedReview() {
        focusedReview = false
        editor?.refreshDecorations()
    }

    // MARK: AI

    func contextPreview(_ scope: ContextScope) -> ContextPayload? {
        guard let snap = editor?.currentSnapshot, let sel = editor?.selection else { return nil }
        return ContextPayload.make(scope: scope, snapshot: snap, selection: sel)
    }

    /// The sentence containing a finding: the context sent for issue actions.
    func sentenceRange(for a: TextAnnotation) -> TextSpan? {
        guard let r = a.ranges.first, let snap = editor?.currentSnapshot else { return nil }
        if AnnotationLayout.isBlockLevel(a) { return r }
        let prose = ProseText(snap)
        let covering = prose.sentences.filter { $0.range.intersects(r) }
        guard let first = covering.first, let last = covering.last else { return r }
        return TextSpan(location: first.range.location, length: last.range.upperBound - first.range.location)
    }

    func explain(_ a: TextAnnotation) {
        runAI(task: .explainUnclear,
              question: "A local check flagged this as “\(a.message)”: \(a.explanation ?? ""). Explain the problem in this passage in two or three sentences. Do not rewrite it.",
              scope: .selection, selection: sentenceRange(for: a), target: a)
    }

    /// Small models rarely quote a fragment exactly; a whole-passage reply
    /// can always be placed.
    static let wholePassageReply = "Give exactly one suggestion whose original is the entire passage, copied exactly, and whose proposed text is the whole revised passage."

    func suggestRewrite(_ a: TextAnnotation) {
        if a.source == .spelling {
            // Fix the slip and anything else wrong in the sentence; leave the style alone.
            let flagged = a.flaggedText.map { " (“\($0)”)" } ?? ""
            runAI(task: .proofread,
                  question: "The system checker flagged a \(a.message.lowercased()) problem\(flagged): \(a.explanation ?? ""). Return the sentence corrected for spelling, grammar and punctuation, keeping its wording otherwise. \(Self.wholePassageReply)",
                  scope: .selection, selection: sentenceRange(for: a), target: a)
            return
        }
        runAI(task: .improveClarity,
              question: "A local check flagged this as “\(a.message)”: \(a.explanation ?? ""). Propose a revision that addresses it, keeping the meaning. \(Self.wholePassageReply)",
              scope: .selection, selection: sentenceRange(for: a), target: a)
    }

    func request(for a: TextAnnotation) -> IssueRequest? { issueRequests[a.dismissalKey] }

    /// "Local analysis" or "AI · Provider · model".
    func provenance(_ a: TextAnnotation) -> String {
        guard a.source == .aiSuggestion else { return a.source == .spelling ? "Local analysis · system dictionary" : "Local analysis" }
        let id = a.metadata["provider"] ?? ""
        guard let entry = prefs.providers.first(where: { $0.id == id }) else { return "AI · \(id)" }
        return "AI · " + ([entry.name] + (entry.detail.map { [$0] } ?? [])).joined(separator: " · ")
    }

    func isStale(_ a: TextAnnotation) -> Bool { a.metadata["stale"] == "true" }

    /// Try Another: set this proposal aside and ask again for the same text,
    /// linked to the finding that asked originally when there is one.
    func tryAnother(_ suggestion: TextAnnotation) {
        let origin = issueRequests.first { $0.value.suggestionIDs.contains(suggestion.id) }?.key
        let finding = origin.flatMap { key in visibleAnnotations.first { $0.dismissalKey == key } }
        let previous = suggestion.consider ?? ""
        reject(suggestion.id)
        let target = finding ?? suggestion
        runAI(task: .suggestAlternatives,
              question: "Propose one different revision of this passage. Do not repeat: “\(previous)”." + (finding == nil ? "" : " " + Self.wholePassageReply),
              scope: .selection, selection: finding.flatMap(sentenceRange(for:)) ?? suggestion.ranges.first, target: target)
    }

    var issueRequestSuggestionIDs: [UUID] { issueRequests.values.flatMap(\.suggestionIDs) }

    func pendingSuggestions(for a: TextAnnotation) -> [WritingSuggestion] {
        let ids = Set(request(for: a)?.suggestionIDs ?? [])
        return review.pending.filter { ids.contains($0.id) }
    }

    func runAI(task: AssistantTask, question: String?, scope: ContextScope, selection: TextSpan? = nil, target: TextAnnotation? = nil) {
        guard prefs.aiEnabled, let entry = prefs.selectedProvider,
              let snap = editor?.currentSnapshot, let sel = selection ?? editor?.selection else { return }
        let key = target?.dismissalKey
        guard prefs.dataAccess.permits(scope) else {
            let msg = "Nothing was sent. Your AI data access setting (\(prefs.dataAccess.title.lowercased())) does not allow sending the \(scope.title.lowercased()). Change it in Settings → Assistant."
            if let key { issueRequests[key] = IssueRequest(task: task, running: false, error: msg); return }
            var denied = AIExchange(task: task, question: question, scope: scope, words: 0, providerName: entry.name, locality: entry.locality)
            denied.running = false
            denied.error = msg
            exchanges.insert(denied, at: 0)
            showInspector = true
            inspectorTab = .ai
            return
        }
        let ctx = ContextPayload.make(scope: scope, snapshot: snap, selection: sel)
        startAI(task: task, question: question, context: ctx, snapshot: snap, provider: entry.make(), providerName: entry.name, target: target)
    }

    /// The immutable request and this model's identity determine the destination,
    /// never the key window, selected tab, or a potentially changing file URL.
    func startAI(task: AssistantTask, question: String?, context ctx: ContextPayload,
                 snapshot snap: DocumentSnapshot, provider: any WritingAssistantProvider,
                 providerName: String? = nil, target: TextAnnotation? = nil) {
        let key = target?.dismissalKey
        var ex = AIExchange(task: task, question: question, scope: ctx.scope, words: ctx.wordCount,
                            providerName: providerName ?? provider.displayName, locality: provider.locality)
        let exID = ex.id
        if let key {
            issueRequests[key] = IssueRequest(id: exID, task: task)
        } else {
            exchanges.insert(ex, at: 0)
            showInspector = true
            inspectorTab = .ai
        }
        aiTask?.cancel()
        aiTask = Task { [weak self] in
            do {
                let response = try await provider.analyze(AnalysisRequest(task: task, question: question, context: ctx))
                try Task.checkCancellation()
                // A finding's request sends just its sentence: a whole-sentence answer fits it.
                let built = SuggestionBuilder.build(response.proposals, context: ctx, snapshot: snap, provider: provider.id,
                                                    wholeContext: key != nil)
                guard let self else { return }
                if task == .reviewDocument { self.review.beginReview(with: built.suggestions) } else { self.review.add(built.suggestions) }
                if let key {
                    self.issueRequests[key] = IssueRequest(id: exID, task: task, running: false, message: response.message.nilIfEmpty,
                                                           suggestionIDs: built.suggestions.map(\.id), discarded: built.discarded)
                } else {
                    ex.message = response.message
                    ex.discarded = built.discarded
                    ex.running = false
                    self.replace(exID, with: ex)
                }
                self.editor?.refreshDecorations()
            } catch {
                let msg = error is CancellationError ? "Cancelled." : error.localizedDescription
                if let key {
                    // A cancelled predecessor must not replace the newer request.
                    if self?.issueRequests[key]?.id == exID {
                        self?.issueRequests[key] = IssueRequest(id: exID, task: task, running: false, error: msg)
                    }
                    return
                }
                ex.error = msg
                ex.running = false
                self?.replace(exID, with: ex)
            }
        }
    }

    func cancelAI() { aiTask?.cancel() }

    private func replace(_ id: UUID, with ex: AIExchange) {
        if let i = exchanges.firstIndex(where: { $0.id == id }) { exchanges[i] = ex }
    }

    func accept(_ id: UUID) -> String? {
        guard let editor else { return nil }
        do {
            let r = try review.accept(id, in: editor)
            registerReviewUndo(id, accepted: true)
            editor.reveal(r, select: false)
            editor.refreshDecorations()
            return nil
        } catch ReviewError.stale(let why) {
            editor.refreshDecorations()
            return "This suggestion is out of date: \(why)"
        } catch {
            return "\(error)"
        }
    }

    /// Keeps the review list in step with Undo/Redo of an accepted suggestion.
    /// Registered in the same undo group as the text edit.
    private func registerReviewUndo(_ id: UUID, accepted: Bool) {
        editor?.undoManager?.registerUndo(withTarget: self) { model in
            if accepted { model.review.reopen(id) } else { model.review.markAccepted(id) }
            model.registerReviewUndo(id, accepted: !accepted)
            model.editor?.refreshDecorations()
        }
    }

    func reject(_ id: UUID) {
        try? review.reject(id)
        editor?.refreshDecorations()
    }

    func acceptAll() -> Int {
        guard let editor else { return 0 }
        let before = Set(review.pending.map(\.id))
        let n = (try? review.acceptAll(in: editor)) ?? 0
        for id in before where review.status[id] == .accepted { registerReviewUndo(id, accepted: true) }
        editor.refreshDecorations()
        return n
    }

    func selectSuggestion(offset: Int) {
        review.select(offset: offset)
        if let id = review.selectedID, let s = review.suggestions.first(where: { $0.id == id }),
           let range = editor.flatMap({ review.resolve(id, in: $0)?.range }) ?? s.ranges.first {
            editor?.reveal(range, select: false)
            activeAnnotationID = id
            editor?.refreshDecorations()
        }
    }

    /// Statistics → "Explore signals": show the passages behind the numbers.
    func exploreSignals() {
        prefs.enabledLayers.insert(.aiStyle)
        editor?.refreshDecorations()
    }

    // MARK: Focus

    func toggleFocusMode() {
        // Leaving focus from Zen leaves Zen too: Zen is a deeper focus.
        if zenMode { toggleZenMode(); return }
        focusMode.toggle()
        typewriter = focusMode && prefs.typewriterInFocusMode
        if focusMode { showInspector = false; focusedReview = false }
        editor?.refreshDecorations()
    }

    func toggleZenMode() {
        zenMode.toggle()
        focusMode = zenMode
        typewriter = zenMode && prefs.typewriterInFocusMode
        if zenMode { showInspector = false; focusedReview = false }
        // Full screen belongs to Zen only if Zen asked for it.
        if let window = NSApp.keyWindow {
            let isFull = window.styleMask.contains(.fullScreen)
            if zenMode, !isFull { zenEnteredFullScreen = true; window.toggleFullScreen(nil) }
            else if !zenMode, zenEnteredFullScreen, isFull { window.toggleFullScreen(nil) }
        }
        if !zenMode { zenEnteredFullScreen = false }
        editor?.refreshDecorations()
    }
}
