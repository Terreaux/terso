// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import Observation
import SwiftUI

/// UI sampling stays here; the decision and delivery reservation are pure/local.
@MainActor @Observable
final class ExerciseRuntime {
    static let shared = ExerciseRuntime()
    var invitationWindow: Int?
    var invitationFocused = false
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var interactionMonitor: Any?
    @ObservationIgnored private var lastInteraction: TimeInterval = -.infinity
    @ObservationIgnored private var reportCandidates: [String: UUID] = [:]

    func start() {
        _ = ExerciseSuggestionState.shared // establish comprehensive content-edit coverage even with suggestions off
        preferencesChanged()
    }
    func preferencesChanged() {
        timer?.invalidate(); timer = nil
        if let interactionMonitor { NSEvent.removeMonitor(interactionMonitor); self.interactionMonitor = nil }
        invitationWindow = nil
        ExerciseSuggestionState.shared.resetActiveTime()
        guard ExercisePreferences.shared.exerciseWarmupSuggestions else { return }
        interactionMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel, .mouseMoved]) { [weak self] event in
            MainActor.assumeIsolated {
                if event.window === DocumentTabs.shared.activeWorkspace?.window {
                    self?.lastInteraction = ProcessInfo.processInfo.systemUptime
                }
            }
            return event
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
    }
    private func snapshot(for workspace: TabWorkspace?, retainingInvitation: Bool = false) -> ExerciseSuggestionSnapshot {
        let model = workspace?.selected?.model
        let editor = model?.editor as? EditorCoordinator
        let window = workspace?.window
        let active = NSApp.isActive && NSApp.keyWindow === window
        let presence = ProcessInfo.processInfo.systemUptime - lastInteraction <= 60
        return ExerciseSuggestionSnapshot(
            enabled: ExercisePreferences.shared.exerciseWarmupSuggestions,
            delayMinutes: ExercisePreferences.shared.exerciseDelayMinutes,
            appIsForeground: active,
            editableDocument: model != nil && workspace?.showingStart == false && editor?.textView?.isEditable == true,
            userIsPresent: presence && (window?.firstResponder === editor?.textView || (retainingInvitation && invitationFocused)),
            isIdle: !presence,
            hasModal: window?.attachedSheet != nil || NSApp.modalWindow != nil || model?.showAskPanel == true || model?.writingStats != nil || model?.showDocumentReport == true,
            isPreview: model?.renderMode == .preview,
            isZen: model?.zenMode == true,
            isComposing: editor?.textView?.hasMarkedText() == true)
    }
    func visible(in workspace: TabWorkspace) -> Bool {
        invitationWindow == workspace.window?.windowNumber && ExerciseSuggestionState.shared.invitationAllowed(snapshot: snapshot(for: workspace, retainingInvitation: true))
    }
    private func sample() {
        let workspace = DocumentTabs.shared.activeWorkspace
        let snapshot = snapshot(for: workspace)
        let state = ExerciseSuggestionState.shared
        if invitationWindow != nil, !state.invitationAllowed(snapshot: self.snapshot(for: workspace, retainingInvitation: true)) { invitationWindow = nil }
        if state.tick(snapshot: snapshot) { invitationWindow = workspace?.window?.windowNumber }
    }
    func candidate(for document: TabDocument?) -> ExerciseSession? {
        let key = WritingLog.key(.now) + ":" + (document?.id.uuidString ?? "general")
        if let id = reportCandidates[key], let session = ExerciseStore.shared.session(id), !session.completed { return session }
        let candidate = ExerciseStore.shared.sessions.first { !$0.completed && document != nil && ExerciseDraftReuse.resolve($0.source) === document }
        reportCandidates[key] = candidate?.id
        return candidate
    }
}

struct ExerciseInvitation: View {
    let workspace: TabWorkspace
    @FocusState private var actionFocused: Bool
    var body: some View {
        if ExerciseRuntime.shared.visible(in: workspace) {
            HStack(spacing: 12) {
                Label("Want a short writing warm-up?", systemImage: ExercisePresentation.symbol)
                Spacer(minLength: 8)
                Button("Choose an exercise") { ExercisePresentation.shared.open(in: workspace) }.focused($actionFocused)
                Button("Not today") { ExerciseSuggestionState.shared.dismissToday() }.focused($actionFocused)
            }.onChange(of: actionFocused) { _, focused in ExerciseRuntime.shared.invitationFocused = focused }
                .onDisappear { ExerciseRuntime.shared.invitationFocused = false }
                .font(.caption).padding(.horizontal, 16).padding(.vertical, 10)
                .background(.bar)
        }
    }
}

struct ExerciseReportCard: View {
    let model: WorkspaceModel
    private var document: TabDocument? { ExerciseDraftReuse.openDocuments.first { $0.model === model } }
    var body: some View {
        if ExerciseSuggestionState.shared.reportAllowed(enabled: ExercisePreferences.shared.exerciseReportSuggestions) {
            let candidate = ExerciseRuntime.shared.candidate(for: document)
            VStack(alignment: .leading, spacing: 8) {
                Label("A small next step", systemImage: ExercisePresentation.symbol).font(.headline)
                Text(candidate.map { "Continue \($0.title)." } ?? "Try a short exercise to find your next paragraph.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button(candidate == nil ? "Choose an exercise" : "Continue exercise") {
                        ExercisePresentation.shared.fromReport(model, sessionID: candidate?.id)
                    }
                    Button("Not today") { ExerciseSuggestionState.shared.dismissToday() }
                    Spacer()
                    Menu {
                        Button("Turn off report suggestions") { ExercisePreferences.shared.exerciseReportSuggestions = false }
                    } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Exercise suggestion options")
                }
            }.padding(14).background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

struct ExerciseSettings: View {
    @Bindable var prefs = ExercisePreferences.shared
    var body: some View {
        Form {
            Section("Exercises") {
                Toggle("Show exercise suggestions in Personal Writing Report", isOn: $prefs.exerciseReportSuggestions)
                Toggle("Offer a warm-up when I have not started writing", isOn: $prefs.exerciseWarmupSuggestions)
                if prefs.exerciseWarmupSuggestions {
                    Picker("Offer a warm-up", selection: $prefs.exerciseDelayMinutes) {
                        ForEach([5, 10, 15], id: \.self) { Text("After \($0) minutes").tag($0) }
                    }
                    Text("Time counts while actively using an editable document. Revisions count as writing activity.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Manual exercises are always available from Tools → Writing Exercises. These settings only control suggestions.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}

/// Resolve the report from its native parent window, never another window's active tab.
struct ExerciseReportContext: NSViewRepresentable {
    let resolved: (WorkspaceModel) -> Void
    func makeNSView(context: Context) -> ExerciseReportContextView {
        let view = ExerciseReportContextView()
        view.resolved = resolved
        return view
    }
    func updateNSView(_ view: ExerciseReportContextView, context: Context) { view.resolved = resolved }
}

final class ExerciseReportContextView: NSView {
    var resolved: ((WorkspaceModel) -> Void)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self, let workspace = self.window?.sheetParent?.windowController as? TabWorkspace,
                  let model = workspace.selected?.model else { return }
            self.resolved?(model)
        }
    }
}
