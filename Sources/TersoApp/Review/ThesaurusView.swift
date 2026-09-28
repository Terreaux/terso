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
            proposedText: word, explanation: nil, kind: "synonym", provider: ProviderID("local.thesaurus"))
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
    @State private var meaningID = ""
    @State private var expanded = false
    @State private var selected: String?
    @State private var loading = true
    @State private var error: String?

    private var sense: ThesaurusSense? { senses.first { $0.id == meaningID } ?? senses.first }
    private var alternatives: [String] {
        Array(NSOrderedSet(array: sense?.alternatives(for: request.original) ?? [])) as? [String] ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Alternatives for “\(request.original)”").font(.headline).lineLimit(2)
                Spacer()
                Text("Offline").font(.caption).foregroundStyle(.secondary)
                    .help("Writing alternatives selected for Terso, with WordNet 3.0 for other entries. Alternatives can change nuance; check the preview.")
            }
            if request.isValid {
                if loading { ProgressView("Finding alternatives…") }
                else if senses.isEmpty && error == nil {
                    Text("No alternatives found. Try Look Up in macOS or select a shorter phrase.")
                        .foregroundStyle(.secondary)
                } else if let sense {
                    if senses.count > 1 {
                        Picker("Meaning", selection: $meaningID) {
                            ForEach(senses) { item in
                                Text("\(item.partOfSpeech.capitalized) · \(item.meaning)").tag(item.id)
                            }
                        }.labelsHidden().help(sense.definition)
                    } else {
                        Text(sense.meaning).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    }
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                            ForEach(Array(alternatives.prefix(expanded ? alternatives.count : 6)), id: \.self) { word in
                                Button { selected = word } label: {
                                    HStack {
                                        Text(word).multilineTextAlignment(.leading)
                                        Spacer(minLength: 0)
                                        if selected == word { Image(systemName: "checkmark") }
                                    }
                                    .padding(.horizontal, 10).padding(.vertical, 8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(selected == word ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                                    .contentShape(Rectangle())
                                }.buttonStyle(.plain).accessibilityLabel("Preview \(word)")
                                    .accessibilityAddTraits(selected == word ? .isSelected : [])
                            }
                        }
                    }.frame(maxHeight: 160)
                    if alternatives.count > 6 {
                        Button(expanded ? "Show fewer" : "More alternatives") { expanded.toggle() }
                            .buttonStyle(.link).font(.callout)
                    }
                }
                Divider()
                Text(selected == nil ? "Choose a word to preview the change." : "Preview · this occurrence only")
                    .font(.caption).foregroundStyle(.secondary)
                if let selected {
                    ChangeView(original: preview.original, proposed: preview.proposed(selected))
                } else {
                    Text(preview.original).font(.system(size: 13, design: .serif)).foregroundStyle(.secondary)
                }
            } else {
                Text("Select a word or a short phrase in the editor, then choose Alternatives.")
                    .foregroundStyle(.secondary)
            }
            if let error { Text(error).foregroundStyle(.orange).font(.callout) }
            if model.revision != request.snapshot.revision {
                Text("The document changed. Close and reopen Alternatives.").font(.caption).foregroundStyle(.orange)
            }
            Spacer(minLength: 0)
            HStack {
                if request.isValid { SystemDictionaryButton(term: request.original).fixedSize() }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Replace") {
                    guard let selected else { return }
                    error = model.replaceAlternative(selected, request: request)
                    if error == nil { dismiss() }
                }.keyboardShortcut(.defaultAction).disabled(selected == nil || model.revision != request.snapshot.revision)
                    .help("Replace only this occurrence. Undo restores it.")
            }
        }
        .padding(20).frame(width: 500, height: 420)
        .onChange(of: meaningID) { selected = nil; expanded = false }
        .task {
            defer { loading = false }
            guard request.isValid else { return }
            do {
                senses = try await OfflineThesaurus.shared.lookup(request.original)
                meaningID = senses.first?.id ?? ""
            } catch { self.error = "The bundled dictionary could not be loaded." }
        }
    }

    private var preview: AlternativePreview { AlternativePreview(request: request) }
}

/// Uses Apple's public Look Up presentation; dictionary content stays in the
/// native reference UI and is never parsed or presented as replacement data.
struct SystemDictionaryButton: NSViewRepresentable {
    let term: String
    func makeNSView(context: Context) -> LookupButton { LookupButton() }
    func updateNSView(_ button: LookupButton, context: Context) { button.term = term }

    final class LookupButton: NSButton {
        var term = ""
        init() {
            super.init(frame: .zero)
            title = "Look Up in macOS"
            bezelStyle = .inline
            isBordered = false
            font = .systemFont(ofSize: 12)
            contentTintColor = .linkColor
            target = self
            action = #selector(lookUp)
            toolTip = "Open the system dictionary. Available references depend on your macOS dictionaries."
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        @objc private func lookUp() {
            showDefinition(for: NSAttributedString(string: term), at: NSPoint(x: bounds.minX, y: bounds.maxY))
        }
    }
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
