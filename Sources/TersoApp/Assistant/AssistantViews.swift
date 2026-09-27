// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import TersoAI
import TersoCore
import TersoDocument

struct LocalityBadge: View {
    let locality: ProviderLocality
    var body: some View {
        Text(locality.rawValue)
            .font(.caption2.weight(.semibold)).tracking(0.6)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.secondary.opacity(0.5), lineWidth: 0.5))
            .foregroundStyle(locality == .local ? Color.secondary : Color.orange)
            .help(locality == .local ? "Text stays on this Mac." : "Text is sent over the network to this provider.")
    }
}

/// Shows exactly what will be transmitted.
struct ContextPicker: View {
    let model: WorkspaceModel
    @Binding var scope: ContextScope
    var body: some View {
        let hasSelection = (model.editor?.selection.length ?? 0) > 0
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Context")
            Picker("", selection: $scope) {
                ForEach(ContextScope.allCases) { s in
                    let n = model.contextPreview(s)?.wordCount ?? 0
                    let label = s == .selection && !hasSelection ? "Selection · nothing selected" : "\(s.title) · \(n.formatted()) words"
                    Text(label).tag(s)
                        .selectionDisabled(!model.prefs.dataAccess.permits(s) || (s == .selection && !hasSelection))
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        }
        // Never leave "Selection" chosen when there is nothing selected.
        .onAppear { if scope == .selection && !hasSelection { scope = .paragraph } }
    }
}

struct AIDisabledNotice: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("The assistant is off.").font(.headline)
            Text("Terso works fully without AI. To use an assistant, turn it on and choose a provider in Settings → Assistant. Nothing is sent anywhere until you ask.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SettingsLink { Text("Open Settings…") }
        }
        .padding(16)
    }
}

/// ⌘⇧A: ask about the selection.
struct AskPanel: View {
    let model: WorkspaceModel
    @State private var question = ""
    @State private var scope: ContextScope = .selection
    @Environment(\.dismiss) private var dismiss
    private let quick: [AssistantTask] = [.improveClarity, .makeConcise, .explainUnclear, .checkArgument, .findAmbiguity, .suggestAlternatives, .proofread]

    var body: some View {
        if !model.prefs.aiEnabled {
            AIDisabledNotice().frame(width: 420)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        } else {
            VStack(alignment: .leading, spacing: 14) {
                TextField("Ask about this selection…", text: $question, axis: .vertical)
                    .textFieldStyle(.plain).font(.title3).lineLimit(1...4)
                    .onSubmit { send(.ask) }
                Divider()
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 6) {
                    ForEach(quick) { t in Button(t.title) { send(t) }.buttonStyle(.link) }
                }
                ContextPicker(model: model, scope: $scope)
                HStack {
                    if let p = model.prefs.selectedProvider {
                        Text(p.name).foregroundStyle(.secondary)
                        LocalityBadge(locality: p.locality)
                    }
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Ask") { send(.ask) }.keyboardShortcut(.defaultAction).disabled(question.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(20)
            .frame(width: 480)
            .onAppear { scope = (model.editor?.selection.length ?? 0) > 0 ? .selection : .paragraph }
        }
    }

    func send(_ task: AssistantTask) {
        model.runAI(task: task, question: task == .ask ? question : nil, scope: scope)
        dismiss()
    }
}

/// Contextual to the document, quiet by default: no transcript until asked.
struct AssistantPane: View {
    @Bindable var model: WorkspaceModel
    @State private var scope: ContextScope = Preferences.shared.defaultScope
    @State private var question = ""
    @State private var notice: String?
    private let quick: [AssistantTask] = [.improveClarity, .checkArgument, .findUnsupportedClaims, .makeConcise, .reviewStructure]

    var body: some View {
        // Always scrollable with a flexible width, so the pane can never force
        // the window taller than it is.
        ScrollView {
            if !model.prefs.aiEnabled {
                AIDisabledNotice().frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    if model.review.isReviewMode {
                        ReviewSection(model: model, notice: $notice)
                    } else {
                        ask
                    }
                    if let notice { Text(notice).font(.caption).foregroundStyle(.orange) }
                    let loose = looseSuggestions
                    if !model.review.isReviewMode && !loose.isEmpty {
                        SectionLabel("Suggestions")
                        ForEach(loose) { s in SuggestionCard(suggestion: s, model: model, notice: $notice) }
                    }
                    ForEach(model.exchanges) { ex in ExchangeView(exchange: ex, model: model) }
                    providerFooter
                }
                .padding(16)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var ask: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ask about your writing").font(.headline)
            TextField("Ask about this document…", text: $question, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
                .onSubmit(send)
            ContextPicker(model: model, scope: $scope)
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("Quick actions")
                ForEach(quick) { t in
                    Button(t.title) { model.runAI(task: t, question: nil, scope: scope) }
                        .buttonStyle(.link)
                }
                Button("Review whole document…") { model.runAI(task: .reviewDocument, question: nil, scope: .document) }
                    .buttonStyle(.link)
                    .disabled(!model.prefs.dataAccess.permits(.document))
                    .help(model.prefs.dataAccess.permits(.document)
                          ? "Structured suggestions for the whole document, reviewed one by one. Sends the whole document."
                          : "Sending the whole document is off. Allow it in Settings → Assistant → AI data access.")
            }
        }
    }

    private var providerFooter: some View {
        @Bindable var prefs = model.prefs
        return VStack(alignment: .leading, spacing: 4) {
            Divider()
            HStack {
                Picker("Assistant", selection: $prefs.selectedProviderID) {
                    ForEach(model.prefs.providers) { p in Text(p.name).tag(p.id) }
                }
                .labelsHidden()
                .fixedSize()
                if let p = model.prefs.selectedProvider { LocalityBadge(locality: p.locality) }
            }
            if model.prefs.selectedProvider?.locality == .network {
                Text("Text you send leaves this Mac.").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }

    /// Suggestions not attached to a Review finding (those appear in Review).
    private var looseSuggestions: [WritingSuggestion] {
        let owned = Set(model.issueRequestSuggestionIDs)
        return model.review.pending.filter { !owned.contains($0.id) }
    }

    func send() {
        guard !question.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        model.runAI(task: .ask, question: question, scope: scope)
        question = ""
    }
}

struct ExchangeView: View {
    let exchange: AIExchange
    let model: WorkspaceModel
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(exchange.question ?? exchange.task.title).font(.callout.weight(.medium)).lineLimit(2)
                Spacer()
                if exchange.running {
                    ProgressView().controlSize(.small)
                    Button("Stop") { model.cancelAI() }.controlSize(.small)
                }
            }
            Text("\(exchange.scope.title) · \(exchange.words) words → \(exchange.providerName)")
                .font(.caption2).foregroundStyle(.tertiary)
            if let e = exchange.error { Text(e).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if let m = exchange.message, !m.isEmpty { Text(m).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            if exchange.discarded > 0 {
                Text("\(exchange.discarded) suggestion(s) were dropped because their text could not be located exactly once.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 6)
        Divider()
    }
}

struct SuggestionCard: View {
    let suggestion: WritingSuggestion
    let model: WorkspaceModel
    @Binding var notice: String?
    var selected = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let k = suggestion.kind { Text(k.uppercased()).font(.caption2.weight(.semibold)).tracking(0.6).foregroundStyle(.tertiary) }
            SuggestionDiff(original: suggestion.originalText, proposed: suggestion.proposedText)
            if let why = suggestion.explanation {
                Text("WHY").font(.caption2.weight(.semibold)).tracking(0.6).foregroundStyle(.tertiary)
                Text(why).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Accept") { notice = model.accept(suggestion.id) }
                Button("Reject") { model.reject(suggestion.id) }
                Button("Ask why") {
                    model.runAI(task: .ask, question: "Why would you change “\(suggestion.originalText)” to “\(suggestion.proposedText)”?", scope: .selection, selection: suggestion.anchor.range)
                }
                Button("Try another") {
                    model.runAI(task: .suggestAlternatives, question: nil, scope: .selection, selection: suggestion.anchor.range)
                }
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.05)))
        .onTapGesture {
            model.review.selectedID = suggestion.id
            if let a = model.annotation(id: suggestion.id) { model.select(a) }
        }
    }
}

/// Review Document mode: step through suggestions; Accept All only here.
struct ReviewSection: View {
    let model: WorkspaceModel
    @Binding var notice: String?

    var body: some View {
        let pending = model.review.pending
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("REVIEW").font(.caption.weight(.semibold)).tracking(0.8).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { model.review.endReview() }.controlSize(.small)
            }
            let kinds = Dictionary(grouping: pending, by: { $0.kind ?? "other" }).map { ($0.key, $0.value.count) }.sorted { $0.1 > $1.1 }
            Text("\(pending.count) suggestion\(pending.count == 1 ? "" : "s")").font(.title3)
            if !kinds.isEmpty {
                Text(kinds.map { "\($0.1) \($0.0)" }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button { model.selectSuggestion(offset: -1) } label: { Image(systemName: "chevron.up") }
                    .keyboardShortcut(.upArrow, modifiers: [.option, .command]).help("Previous (⌥⌘↑)")
                Button { model.selectSuggestion(offset: 1) } label: { Image(systemName: "chevron.down") }
                    .keyboardShortcut(.downArrow, modifiers: [.option, .command]).help("Next (⌥⌘↓)")
                Button("Accept") { if let id = model.review.selectedID { notice = model.accept(id) } }
                    .keyboardShortcut(.return, modifiers: [.option, .command])
                Button("Reject") { if let id = model.review.selectedID { model.reject(id) } }
                    .keyboardShortcut(.delete, modifiers: [.option, .command])
                Spacer()
                Button("Accept All") { let n = model.acceptAll(); notice = "Accepted \(n) suggestion(s). Undo reverts each one." }
                    .disabled(pending.isEmpty)
            }
            .controlSize(.small)
            ForEach(pending) { s in
                SuggestionCard(suggestion: s, model: model, notice: $notice, selected: s.id == model.review.selectedID)
            }
        }
        .onAppear { model.review.markInspected() }
    }
}
