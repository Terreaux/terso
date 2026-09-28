// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import TersoCore

extension TextAnnotation {
    /// Detailed category, shown in the inspector (the document shows families).
    var categoryLabel: String {
        switch category {
        case .spelling: message == "Grammar" ? "Grammar" : "Spelling"
        case .aiSuggestion: "AI suggestion"
        default: category.title
        }
    }
    var isSuggestion: Bool { source == .aiSuggestion }
}

/// A shape cue per family, so the inspector never relies on colour alone.
struct FamilyGlyph: View {
    let family: AnnotationFamily
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11))
            .foregroundStyle(Color(nsColor: HighlightStyle.color(family)))
            .frame(width: 14)
            .accessibilityHidden(true)
    }
    var symbol: String {
        switch family {
        case .writing: "text.alignleft"
        case .spelling: "textformat.abc.dottedunderline"
        case .aiSuggestion: "sparkles"
        case .aiStyle: "waveform.path.ecg"
        }
    }
}

@MainActor
func excerpt(_ range: TextSpan?, in model: WorkspaceModel, limit: Int = 180) -> String {
    guard let r = range, let s = model.editor?.currentSnapshot.substring(r) else { return "" }
    let flat = s.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    return flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
}

@MainActor
func excerpt(_ a: TextAnnotation, in model: WorkspaceModel, limit: Int = 180) -> String { excerpt(a.ranges.first, in: model, limit: limit) }

// MARK: - Type scale

/// Review is read, not scanned like a log: nothing needed for an editing
/// decision goes below 12 pt.
enum ReviewType {
    static let passageTitle = Font.system(size: 14, weight: .semibold)
    static let passageText = Font.system(size: 14, design: .serif)
    static let rowTitle = Font.system(size: 13.5, weight: .medium)
    static let findingTitle = Font.system(size: 14, weight: .medium)
    static let findingTitleSelected = Font.system(size: 14, weight: .semibold)
    static let body = Font.system(size: 13)
    static let excerpt = Font.system(size: 12, design: .serif)
    static let meta = Font.system(size: 12)
    static let label = Font.system(size: 11, weight: .semibold)
}

// MARK: - Passages

/// One place worth reviewing, collapsed: title, count, a few categories,
/// one line of the passage. Detail waits for expansion.
struct PassageRow: View {
    let passage: ReviewPassage
    let model: WorkspaceModel

    var body: some View {
        let findings = model.findings(in: passage)
        let primary = findings.first
        let cats = categorySummary(findings)
        Button { model.selectPassage(passage) } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    FamilyGlyph(family: primary?.category.family ?? .writing)
                    Text(primary?.message ?? "").font(ReviewType.rowTitle).lineLimit(1)
                    Spacer(minLength: 4)
                    if findings.count > 1 {
                        Text("\(findings.count)").font(ReviewType.meta).monospacedDigit().foregroundStyle(.secondary)
                            .help("\(findings.count) findings in this passage")
                    }
                }
                Text(excerpt(passage.range, in: model, limit: 90))
                    .font(ReviewType.excerpt).foregroundStyle(.secondary)
                    .lineLimit(1).padding(.leading, 20)
                if findings.count > 1 {
                    Text(cats).font(ReviewType.meta).foregroundStyle(.tertiary).lineLimit(1).padding(.leading, 20)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(primary?.message ?? ""). \(findings.count) findings: \(categories(findings)). \(excerpt(passage.range, in: model, limit: 140))")
        .accessibilityHint("Selects this passage")
        .contextMenu { Button("Ignore Passage") { model.ignorePassage(passage) } }
    }
}

@MainActor
func categoryList(_ findings: [TextAnnotation]) -> [String] {
    findings.map(\.categoryLabel).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
}

@MainActor
func categories(_ findings: [TextAnnotation]) -> String { categoryList(findings).joined(separator: " · ") }

/// "Readability · Style · Passive voice +2"
@MainActor
func categorySummary(_ findings: [TextAnnotation], max: Int = 3) -> String {
    let all = categoryList(findings)
    let shown = all.prefix(max).joined(separator: " · ")
    return all.count > max ? "\(shown)  +\(all.count - max)" : shown
}

/// The selected passage: the writing first, then what kinds of problem it
/// has, then the individual findings. The selected finding expands; with
/// many findings, only the first few are listed until asked.
struct PassageDetail: View {
    let passage: ReviewPassage
    let model: WorkspaceModel
    var focused = false
    @State private var showAll = false
    private static let preview = 3

    var body: some View {
        let findings = model.findings(in: passage)
        let activeIndex = findings.firstIndex { $0.id == model.activeAnnotationID } ?? 0
        let listed = showAll || activeIndex >= Self.preview ? findings : Array(findings.prefix(Self.preview))
        VStack(alignment: .leading, spacing: 12) {
            Text(findings.first?.message ?? "").font(ReviewType.passageTitle)
                .fixedSize(horizontal: false, vertical: true)
            Text(excerpt(passage.range, in: model, limit: 600))
                .font(ReviewType.passageText)
                .lineSpacing(2)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Text(categories(findings)).font(ReviewType.meta).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text(findings.count == 1 ? "1 FINDING" : "\(findings.count) FINDINGS")
                    .font(ReviewType.label).tracking(0.6).foregroundStyle(.tertiary)
                    .accessibilityAddTraits(.isHeader)
                ForEach(listed) { f in
                    if f.id == model.activeAnnotationID {
                        FindingOrSuggestion(annotation: f, model: model)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.05)))
                            .padding(.vertical, 2)
                    } else {
                        FindingLine(annotation: f, model: model)
                    }
                }
                if listed.count < findings.count {
                    Button("Show \(findings.count - listed.count) more") { showAll = true }
                        .buttonStyle(.borderless).font(ReviewType.meta)
                }
            }
            HStack {
                Spacer()
                Button("Ignore Passage") { model.ignorePassage(passage) }
                    .buttonStyle(.borderless).font(ReviewType.meta).foregroundStyle(.secondary)
                    .help("Hide every finding in this passage")
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 9).fill(focused ? Color.clear : Color.primary.opacity(0.035)))
        // Share the selected paragraph’s accent with its Review card.
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 9, bottomLeadingRadius: 9)
                .fill(Color(nsColor: HighlightStyle.passageAccent))
                .frame(width: 4)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Selected passage")
    }
}

/// A finding inside a passage, collapsed. Selecting it narrows the highlight.
struct FindingLine: View {
    let annotation: TextAnnotation
    let model: WorkspaceModel
    var body: some View {
        Button { model.select(annotation) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                FamilyGlyph(family: annotation.category.family)
                VStack(alignment: .leading, spacing: 1) {
                    Text(annotation.message).font(ReviewType.findingTitle)
                    Text(annotation.isSuggestion ? model.provenance(annotation) : "“\(excerpt(annotation, in: model, limit: 60))”")
                        .font(ReviewType.excerpt).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if model.isStale(annotation) { Text("Out of date").font(ReviewType.meta).foregroundStyle(.orange) }
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(annotation.message), \(annotation.categoryLabel)")
    }
}

/// Deterministic findings and AI suggestions are different objects with
/// different actions.
struct FindingOrSuggestion: View {
    let annotation: TextAnnotation
    let model: WorkspaceModel
    var body: some View {
        if annotation.isSuggestion {
            SuggestionDetail(suggestion: annotation, model: model)
        } else {
            FindingDetail(finding: annotation, model: model)
        }
    }
}

// MARK: - Finding

/// A local finding: what, why, and Explain / Suggest Rewrite / Ignore.
struct FindingDetail: View {
    @State private var occurrenceIndex = 0
    let finding: TextAnnotation
    let model: WorkspaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Text("“\(excerpt(finding, in: model, limit: 300))”")
                .font(.system(size: 13, design: .serif)).italic()
                .fixedSize(horizontal: false, vertical: true)
            if let why = finding.explanation {
                Text(why).font(ReviewType.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let c = finding.consider {
                Text("Consider: \(c)").font(ReviewType.body).fixedSize(horizontal: false, vertical: true)
            }
            if finding.ranges.count > 1 {
                HStack {
                    Button("Previous location") { navigateOccurrence(-1) }
                    Text("\(occurrenceIndex + 1) of \(finding.ranges.count)").monospacedDigit()
                    Button("Next location") { navigateOccurrence(1) }
                }
                .font(.caption)
                .disabled(finding.revision != model.revision)
            }
            if finding.category == .repetition {
                Button("Alternatives…") { model.showAlternatives(for: finding, occurrence: occurrenceIndex) }
                    .disabled(finding.revision != model.revision)
                    .help("Look up offline synonyms for this occurrence")
            }
            aiStatus
            actions
        }
        .onChange(of: finding.id) { occurrenceIndex = 0 }
    }

    private func navigateOccurrence(_ offset: Int) {
        guard finding.revision == model.revision, !finding.ranges.isEmpty else { return }
        occurrenceIndex = (occurrenceIndex + offset + finding.ranges.count) % finding.ranges.count
        model.editor?.reveal(finding.ranges[occurrenceIndex], select: true)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                FamilyGlyph(family: finding.category.family)
                Text(finding.message).font(ReviewType.findingTitleSelected)
            }
            Text("\(finding.categoryLabel) · \(model.provenance(finding))").font(ReviewType.meta).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder private var aiStatus: some View {
        if let req = model.request(for: finding) {
            if req.running {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.regular)
                    Text("Asking \(model.prefs.selectedProvider?.name ?? "the assistant")…").font(ReviewType.meta).foregroundStyle(.secondary)
                    Button("Stop") { model.cancelAI() }.buttonStyle(.borderless).font(ReviewType.meta)
                }
            }
            if let e = req.error { Text(e).font(ReviewType.meta).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            if let m = req.message, req.task == .explainUnclear {
                VStack(alignment: .leading, spacing: 2) {
                    Text("AI · \(model.prefs.selectedProvider?.name ?? "assistant")").font(ReviewType.meta).foregroundStyle(.tertiary)
                    Text(m).font(ReviewType.body).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
            if !req.running, req.error == nil, req.task != .explainUnclear, model.pendingSuggestions(for: finding).isEmpty {
                Text(req.message ?? "No rewrite proposed.").font(ReviewType.meta).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var actions: some View {
        let hasSuggestion = !model.pendingSuggestions(for: finding).isEmpty
        return HStack {
            if model.prefs.aiEnabled {
                Button("Explain") { model.explain(finding) }
                    .help("Ask the assistant why this was flagged. Sends only this sentence.")
                Button(hasSuggestion ? "Suggestion Ready" : "Suggest Rewrite") { model.suggestRewrite(finding) }
                    .disabled(hasSuggestion)
                    .help(hasSuggestion ? "A suggestion for this finding is listed in this passage." : "Ask for a revision you can accept or reject. Sends only this sentence.")
            }
            Spacer()
            if let word = finding.metadata["word"] {
                Button("Learn Spelling") {
                    NSSpellChecker.shared.learnWord(word)
                    model.ignore(finding)
                    model.scheduleAnalysis()
                }
            }
            Button("Ignore") { model.ignore(finding) }.help("Hide this finding")
        }
        .controlSize(.regular)
        .disabled(model.request(for: finding)?.running == true)
    }
}

// MARK: - Suggestion

/// An AI proposal awaiting a decision: Accept / Reject / Try Another.
/// Only Accept changes the document, through the review gate.
struct SuggestionDetail: View {
    let suggestion: TextAnnotation
    let model: WorkspaceModel
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    FamilyGlyph(family: .aiSuggestion)
                    Text(suggestion.message).font(ReviewType.findingTitleSelected)
                }
                Text(model.provenance(suggestion)).font(ReviewType.meta).foregroundStyle(.secondary)
            }
            if model.isStale(suggestion) {
                Text("Out of date. The passage changed after this was suggested, so it can’t be applied safely.")
                    .font(ReviewType.body).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                HStack {
                    if model.prefs.aiEnabled { Button("Try Again") { model.tryAnother(suggestion) } }
                    Button("Dismiss") { model.reject(suggestion.id) }
                }
                .controlSize(.regular)
            } else {
                ChangeView(original: excerpt(suggestion, in: model, limit: 2000), proposed: suggestion.consider ?? "")
                if let why = suggestion.explanation { Why(text: why) }
                HStack {
                    Button("Accept") { note = model.accept(suggestion.id) }
                        .keyboardShortcut(.return, modifiers: [.command])
                        .help("Apply this change (⌘↩). Undo reverts it.")
                    Button("Reject") { model.reject(suggestion.id) }
                    if model.prefs.aiEnabled { Button("Try Another") { model.tryAnother(suggestion) } }
                }
                .controlSize(.regular)
            }
            if let note { Text(note).font(ReviewType.meta).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

struct Why: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("WHY").font(ReviewType.label).tracking(0.6).foregroundStyle(.tertiary)
            Text(text).font(ReviewType.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Tracked changes at word level when the edit is small; Original /
/// Suggested blocks when it is a rewrite.
struct ChangeView: View {
    let original: String
    let proposed: String

    var body: some View {
        let segments = WordDiff.diff(original, proposed)
        if WordDiff.isReliable(segments, original: original) {
            Text(inline(segments))
                .font(.system(size: 13, design: .serif))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Change: \(original) becomes \(proposed)")
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("ORIGINAL").font(ReviewType.label).tracking(0.6).foregroundStyle(.tertiary)
                Text(original).font(.system(size: 13, design: .serif)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("SUGGESTED").font(ReviewType.label).tracking(0.6).foregroundStyle(.tertiary)
                Text(proposed).font(.system(size: 13, design: .serif)).fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// Removed words struck through in a muted red; added words underlined in
    /// the accent colour. Shape (strike / underline) carries the meaning too.
    func inline(_ segments: [WordDiff.Segment]) -> AttributedString {
        var out = AttributedString()
        for seg in segments {
            var piece = AttributedString(seg.text)
            switch seg.kind {
            case .same: break
            case .removed:
                piece.strikethroughStyle = .single
                piece.foregroundColor = Color.red.opacity(0.75)
            case .added:
                piece.underlineStyle = .single
                piece.foregroundColor = Color.accentColor
            }
            out += piece
        }
        return out
    }
}

/// Kept for the Assistant's suggestion cards.
struct SuggestionDiff: View {
    let original: String
    let proposed: String
    var body: some View { ChangeView(original: original, proposed: proposed) }
}
