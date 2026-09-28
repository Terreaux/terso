// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import TersoAnalysis
import TersoCore
import TersoDocument

struct ThesaurusRequest: Identifiable {
    let id = UUID()
    let snapshot: DocumentSnapshot
    let range: TextSpan
    var original: String { snapshot.substring(range) ?? "" }
    var isValid: Bool {
        !original.isEmpty && original.utf16.count <= 120 &&
        !original.contains(where: { $0.isNewline }) && original.split(whereSeparator: \.isWhitespace).count <= 6
    }
}

extension WorkspaceModel {
    func showAlternatives(for finding: TextAnnotation? = nil, occurrence: Int = 0) {
        guard let editor else { return }
        if let finding {
            guard finding.revision == editor.currentSnapshot.revision, finding.ranges.indices.contains(occurrence) else { return }
            thesaurusRequest = ThesaurusRequest(snapshot: editor.currentSnapshot, range: finding.ranges[occurrence])
        } else {
            thesaurusRequest = ThesaurusRequest(snapshot: editor.currentSnapshot, range: editor.selection)
        }
    }

    /// Explicit acceptance through the existing review gate. Never relocates a
    /// repeated word to another occurrence if the document changed in the sheet.
    func replaceAlternative(_ word: String, request: ThesaurusRequest) -> String? {
        guard let editor, request.isValid, !word.isEmpty,
              editor.currentSnapshot.revision == request.snapshot.revision,
              editor.currentSnapshot.substring(request.range) == request.original,
              let anchor = TextAnchor(range: request.range, in: request.snapshot) else {
            return "The text changed. Close this window and look up the word again."
        }
        let proposal = WritingSuggestion(documentRevision: request.snapshot.revision, anchor: anchor,
            proposedText: word, explanation: nil, kind: "synonym", provider: ProviderID("local.wordnet"))
        let gate = SuggestionReview()
        gate.add([proposal])
        do {
            let range = try gate.accept(proposal.id, in: editor)
            editor.reveal(range, select: true)
            editor.refreshDecorations()
            return nil
        } catch {
            return "The replacement could not be applied. Look up the word again."
        }
    }
}

struct ThesaurusView: View {
    let model: WorkspaceModel
    let request: ThesaurusRequest
    @Environment(\.dismiss) private var dismiss
    @State private var senses: [ThesaurusSense] = []
    @State private var selected: String?
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Alternatives").font(.title2.bold())
            Text(request.isValid ? "“\(request.original)” · Offline thesaurus" : "Select a word or a short phrase in the editor, then choose Alternatives.")
                .foregroundStyle(.secondary)
            if request.isValid {
                Text("Choose the intended meaning. Technical terms may be best left unchanged.")
                    .font(.callout).foregroundStyle(.secondary)
                if loading { ProgressView("Looking up meanings…") }
                else if senses.isEmpty && error == nil {
                    Text("No alternatives in the bundled dictionary. Try the base form of a word or a shorter phrase.")
                        .padding(.vertical)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(senses) { sense in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(sense.partOfSpeech.capitalized).font(.caption).foregroundStyle(.secondary)
                                    Text(sense.definition).font(.callout).textSelection(.enabled)
                                    // A vertical list stays readable for long multiword alternatives.
                                    ForEach(sense.alternatives(for: request.original), id: \.self) { word in
                                        Button { selected = word } label: {
                                            HStack {
                                                Image(systemName: selected == word ? "checkmark.circle.fill" : "circle")
                                                Text(word)
                                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                        }.buttonStyle(.plain).padding(.vertical, 2)
                                            .accessibilityLabel("Preview \(word)")
                                    }
                                }
                                Divider()
                            }
                        }.padding(.trailing, 8)
                    }
                }
                if let selected {
                    Divider()
                    Text("Preview · this occurrence only").font(.caption).foregroundStyle(.secondary)
                    ChangeView(original: preview.original, proposed: preview.proposed(selected))
                }
            }
            if let error { Text(error).foregroundStyle(.orange).font(.callout) }
            HStack {
                Link("WordNet 3.0 · Princeton University", destination: URL(string: "https://wordnet.princeton.edu/")!)
                    .font(.caption)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Replace This Occurrence") {
                    guard let selected else { return }
                    error = model.replaceAlternative(selected, request: request)
                    if error == nil { dismiss() }
                }.keyboardShortcut(.defaultAction).disabled(selected == nil || model.revision != request.snapshot.revision)
            }
            if model.revision != request.snapshot.revision {
                Text("The document changed. Close and reopen Alternatives.").font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(20).frame(width: 560, height: 570)
        .task {
            defer { loading = false }
            guard request.isValid else { return }
            do { senses = try await OfflineThesaurus.shared.lookup(request.original) }
            catch { self.error = "The bundled dictionary could not be loaded." }
        }
    }

    private var preview: AlternativePreview { AlternativePreview(request: request) }
}

/// Bounded surrounding text, using NSString offsets like the editor.
struct AlternativePreview {
    let original: String
    private let localRange: NSRange
    init(request: ThesaurusRequest) {
        let ns = request.snapshot.text as NSString
        let paragraph = ns.paragraphRange(for: request.range.nsRange)
        let start = max(paragraph.location, request.range.location - 100)
        let end = min(NSMaxRange(paragraph), request.range.upperBound + 100)
        let range = ns.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: end - start))
        original = ns.substring(with: range)
        localRange = NSRange(location: request.range.location - range.location, length: request.range.length)
    }
    func proposed(_ word: String) -> String { (original as NSString).replacingCharacters(in: localRange, with: word) }
}
