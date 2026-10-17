// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import TersoCore
import TersoStyle

/// Review: the places in the document worth a second look. Passages, not
/// warnings — each groups the findings on the same sentence.
struct ReviewInspector: View {
    let model: WorkspaceModel
    @State private var showFilter = false
    @State private var showStoryChecks = false

    var body: some View {
        let passages = model.reviewPassages
        VStack(spacing: 0) {
            header(passages)
            Divider()
            if model.focusedReview {
                FocusedReviewView(model: model)
            } else if passages.isEmpty {
                cleanState
            } else {
                passageList(passages)
                Divider()
                ReviewNavigator(model: model)
            }
        }
    }

    private func header(_ passages: [ReviewPassage]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            // Passages are editing decisions; raw findings live inside them.
            Text(passages.count == 1 ? "1 passage" : "\(passages.count) passages")
                .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                .help("\(passages.count) passages to review, from \(model.reviewFindings.count) findings")
                .accessibilityLabel("\(passages.count) passages to review")
            Spacer()
            if !model.focusedReview && !passages.isEmpty {
                Button("Step Through") { model.startFocusedReview() }
                    .buttonStyle(.borderless).font(ReviewType.meta)
                    .help("Review passages one at a time (⌘⇧E)")
            }
            if model.prefs.domain == .fiction {
                Button("Story checks") { showStoryChecks.toggle() }
                    .buttonStyle(.borderless).font(ReviewType.meta)
                    .help("Questions for reviewing fiction by hand")
                    .popover(isPresented: $showStoryChecks, arrowEdge: .bottom) {
                        fictionChecks
                    }
            }
            Button { showFilter.toggle() } label: {
                Image(systemName: allLayersOn ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
            }
            .buttonStyle(.borderless)
            .help("Choose what to show")
            .accessibilityLabel("Filter findings")
            .popover(isPresented: $showFilter, arrowEdge: .bottom) { ReviewFilter(model: model) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// These need the writer's judgment. Terso does not infer a fault from a
    /// name or a scene's pace, and a finding-free story can still benefit.
    private var fictionChecks: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Story checks")
            Text("Read the whole story with these questions in mind:")
                .foregroundStyle(.secondary)
            Text("Do scenes keep repeating the same setup, turn, and neat resolution?")
            Text("Where should the pace linger, jump ahead, or leave a moment unresolved?")
            Text("Do the characters' names and choices feel specific to this story?")
            Text("These are prompts for your judgment, not automated findings.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .font(ReviewType.body)
        .fixedSize(horizontal: false, vertical: true)
        .padding(16)
        .frame(width: 300, alignment: .leading)
    }

    private var allLayersOn: Bool {
        ReviewFilter.writing.allSatisfy { model.prefs.enabledLayers.contains($0) } && model.prefs.enabledLayers.contains(.spelling)
    }

    private var cleanState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No significant writing issues found.").font(ReviewType.body)
            Text("Continue writing normally.").font(ReviewType.body).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
    }

    private func passageList(_ passages: [ReviewPassage]) -> some View {
        let selectedID = model.selectedPassage?.id
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(passages) { p in
                        Group {
                            if p.id == selectedID {
                                PassageDetail(passage: p, model: model)
                            } else {
                                PassageRow(passage: p, model: model)
                            }
                        }
                        .id(p.id)
                    }
                }
                .padding(8)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: selectedID) { _, id in
                guard let id else { return }
                withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: 0.18)) {
                    proxy.scrollTo(id, anchor: .top)
                }
            }
        }
    }
}

/// "Passage 3 of 8   ‹ Previous   Next ›   [Exit]"
struct ReviewNavigator: View {
    let model: WorkspaceModel
    var showExit = false

    var body: some View {
        HStack(spacing: 12) {
            Text(position).font(ReviewType.meta).monospacedDigit().foregroundStyle(.secondary)
            Spacer()
            Button { model.selectFinding(offset: -1) } label: { Label("Previous", systemImage: "chevron.up") }
                .help("Previous passage (⌘[)")
            Button { model.selectFinding(offset: 1) } label: { Label("Next", systemImage: "chevron.down") }
                .help("Next passage (⌘])")
            if showExit {
                Button("Exit") { model.endFocusedReview() }
                    .keyboardShortcut(.escape, modifiers: [])
                    .help("Leave step-by-step review (Esc)")
            }
        }
        .labelStyle(.titleAndIcon)
        .buttonStyle(.borderless)
        .font(ReviewType.meta)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    var position: String {
        let n = model.reviewPassages.count
        return model.selectedPassageIndex.map { "Passage \($0 + 1) of \(n)" } ?? "\(n) passage\(n == 1 ? "" : "s")"
    }
}

/// Step-by-step review: one passage at a time; everything else recedes.
struct FocusedReviewView: View {
    let model: WorkspaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ReviewNavigator(model: model, showExit: true)
            Divider()
            ScrollView {
                if let p = model.selectedPassage {
                    PassageDetail(passage: p, model: model, focused: true).padding(4)
                } else {
                    Text("Nothing left to review.").font(ReviewType.body).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                }
            }
        }
    }
}

/// Small uppercase section label used across the inspector.
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).font(.caption.weight(.semibold)).tracking(0.8).foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}
