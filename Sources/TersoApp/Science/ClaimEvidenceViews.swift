// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import SwiftUI
import TersoAnalysis
import TersoCore

private struct EvidenceRequest: Identifiable {
    let id = UUID()
    let root: URL
    let claim: EvidencePassage
    let sources: [URL: String]
    let index: ManuscriptIndex?
    let previous: ClaimEvidenceLink?

    @MainActor init?(model: WorkspaceModel, claim: ScientificClaim, previous: ClaimEvidenceLink? = nil) {
        guard let root = model.evidenceRoot, let file = model.fileURL, let snapshot = model.editor?.currentSnapshot,
              model.currentScience?.claims.contains(claim) == true,
              let passage = EvidencePassage(file: file, range: claim.sourceRange, text: snapshot.text) else { return nil }
        self.root = root
        self.claim = passage
        sources = model.evidenceSources
        index = model.manuscriptIndex
        self.previous = previous
    }
}

struct ClaimEvidenceActions: View {
    let model: WorkspaceModel
    let claim: ScientificClaim
    @State private var request: EvidenceRequest?

    var body: some View {
        let reviews = model.reviewedEvidence(for: claim)
        ForEach(reviews) { review in
            EvidenceLinkRow(model: model, review: review)
            if !review.isCurrent {
                Button("Choose updated evidence…") { request = EvidenceRequest(model: model, claim: claim, previous: review.link) }
                    .buttonStyle(.borderless)
            }
        }
        if model.fileURL != nil {
            Button("Attach evidence…") { request = EvidenceRequest(model: model, claim: claim) }
                .buttonStyle(.borderless)
        } else {
            Text("Save this draft to attach evidence.").font(.caption).foregroundStyle(.secondary)
        }
        Button("Revise this claim…") {
            let excerpts = reviews.filter(\.isCurrent).map {
                "\($0.link.evidence.file.lastPathComponent)\n\($0.link.evidence.anchor.originalText)"
            }
            ExercisePresentation.shared.reviseClaim(in: model, range: claim.sourceRange, evidence: excerpts)
        }.buttonStyle(.borderless)
        .sheet(item: $request) { request in EvidencePicker(model: model, request: request) }
    }
}

struct PaperEvidenceList: View {
    let model: WorkspaceModel
    var body: some View {
        let reviews = model.reviewedEvidence
        if !reviews.isEmpty {
            Divider()
            DisclosureGroup("Author-confirmed links (\(reviews.count))") {
                ForEach(reviews) { review in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(review.link.claim.anchor.originalText).lineLimit(3)
                        EvidenceLinkRow(model: model, review: review)
                    }.padding(.vertical, 4)
                }
            }
            let changed = reviews.filter { !$0.isCurrent && !$0.checkingAssets }.count
            if changed > 0 {
                Label("\(changed) evidence \(changed == 1 ? "link needs" : "links need") review", systemImage: "arrow.clockwise")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        if let error = model.claimEvidence.error { Text(error).font(.caption).foregroundStyle(.red) }
    }
}

private struct EvidenceLinkRow: View {
    let model: WorkspaceModel
    let review: ClaimEvidenceReview
    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 5) {
                Text(review.link.evidence.anchor.originalText).textSelection(.enabled)
                if review.claimRange == nil { Text("The original claim changed or moved outside this paper.") }
                if review.evidenceRange == nil { Text("The attached passage changed or is unavailable. Review its saved text above.") }
                if review.checkingAssets { Text("Checking the attached figure files…") }
                ForEach(review.changedAssets, id: \.self) { file in
                    Text("\(file.lastPathComponent) changed or is unavailable. Check the figure, then choose updated evidence.")
                }
                if let assets = review.link.assets, !assets.isEmpty {
                    Button("Reveal figure files in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(Array(assets.keys))
                    }.buttonStyle(.borderless)
                }
                HStack {
                    if let range = review.claimRange, let text = model.evidenceSources[review.link.claim.file] {
                        Button("Show claim") {
                            ManuscriptContext.reveal(.init(url: review.link.claim.file, range: range,
                                                          line: ManuscriptLines(text).line(at: range.location), anchor: review.link.claim.anchor))
                        }
                    }
                    if let range = review.evidenceRange, let text = model.evidenceSources[review.link.evidence.file] {
                        Button("Show source") {
                            ManuscriptContext.reveal(.init(url: review.link.evidence.file, range: range,
                                                          line: ManuscriptLines(text).line(at: range.location), anchor: review.link.evidence.anchor))
                        }
                    }
                    if let root = model.evidenceRoot {
                        Button("Remove link") {
                            model.claimEvidence.remove(review.id, from: root)
                            model.editor?.refreshDecorations()
                        }
                    }
                }.buttonStyle(.borderless)
            }.font(.caption).frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("\(review.link.kind.rawValue) · \(review.link.evidence.file.lastPathComponent)",
                  systemImage: review.isCurrent ? "checkmark.circle" : "arrow.clockwise.circle")
                .foregroundStyle(review.isCurrent ? Color.secondary : Color.orange)
        }
    }
}

private struct EvidencePicker: View {
    let model: WorkspaceModel
    let request: EvidenceRequest
    @Environment(\.dismiss) private var dismiss
    @State private var file: URL
    @State private var selection: NSRange
    @State private var kind: ClaimEvidenceLink.Kind
    @State private var query = ""
    @State private var error: String?
    @State private var saving = false

    init(model: WorkspaceModel, request: EvidenceRequest) {
        self.model = model
        self.request = request
        let file = request.previous?.evidence.file ?? request.claim.file
        _file = State(initialValue: request.sources[file] == nil ? request.claim.file : file)
        _selection = State(initialValue: request.previous?.evidence.locate(in: request.sources)?.nsRange ?? NSRange(location: 0, length: 0))
        _kind = State(initialValue: request.previous?.kind ?? .passage)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Attach evidence").font(.title2.bold())
            Text(request.claim.anchor.originalText).lineLimit(3).foregroundStyle(.secondary)
            Picker("Source", selection: Binding(get: { file }, set: { file = $0; selection = .init(location: 0, length: 0); error = nil })) {
                ForEach(request.sources.keys.sorted(by: { $0.path < $1.path }), id: \.self) { url in
                    Text(sourceName(url)).tag(url)
                }
            }
            HStack {
                Picker("Evidence", selection: $kind) {
                    ForEach(ClaimEvidenceLink.Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                if let index = request.index, !index.labels.isEmpty || !index.bibliography.isEmpty {
                    Menu("Go to…") {
                        ForEach(index.labels.keys.sorted(), id: \.self) { key in
                            ForEach(index.labels[key] ?? []) { location in
                                Button("\(key) · \(sourceName(location.url)):\(location.line)") {
                                    let type: ClaimEvidenceLink.Kind = key.hasPrefix("fig:") ? .figure : key.hasPrefix("tab:") || key.hasPrefix("tbl:") ? .table : key.hasPrefix("eq:") ? .derivation : .passage
                                    go(to: location, kind: type)
                                }
                            }
                        }
                        ForEach(index.bibliography) { entry in
                            Button(entry.title.isEmpty ? entry.key : "\(entry.key) · \(entry.title)") {
                                go(to: entry.location, kind: .citation, range: entry.entryRange)
                            }
                        }
                    }.fixedSize()
                }
            }
            HStack {
                TextField("Find text in this source", text: $query).onSubmit(findNext)
                Button("Find next", action: findNext).disabled(query.isEmpty)
            }
            Text("Select the passage that supports this claim.").font(.caption)
            EvidenceExcerptView(text: request.sources[file] ?? "", selection: $selection)
                .frame(minHeight: 150)
            if file.pathExtension.lowercased() == "bib" {
                Text("This excerpt records the bibliography entry. To quote a result, select its passage in a manuscript source.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Button("Confirm evidence") { Task { await confirm() } }.keyboardShortcut(.defaultAction)
                    .disabled(selection.length == 0 || saving)
            }
        }.padding(20).frame(minWidth: 510, idealWidth: 640, minHeight: 410, idealHeight: 580)
            .disabled(saving)
            .interactiveDismissDisabled(saving)
    }

    private func sourceName(_ file: URL) -> String {
        let folder = request.root.deletingLastPathComponent().path + "/"
        return file.path.hasPrefix(folder) ? String(file.path.dropFirst(folder.count)) : file.path
    }

    private func go(to location: ManuscriptLocation, kind: ClaimEvidenceLink.Kind, range: TextSpan? = nil) {
        guard let source = request.sources[location.url] else { return }
        self.kind = kind
        file = location.url
        selection = range?.nsRange ?? EvidenceExcerptView.suggestedRange(in: source, at: location.range)
        error = nil
    }

    private func findNext() {
        guard !query.isEmpty, let source = request.sources[file] else { return }
        let ns = source as NSString
        let start = min(NSMaxRange(selection), ns.length)
        var found = ns.range(of: query, options: [.caseInsensitive], range: NSRange(location: start, length: ns.length - start))
        if found.location == NSNotFound { found = ns.range(of: query, options: [.caseInsensitive]) }
        guard found.location != NSNotFound else { error = "No match in this source."; return }
        selection = found
        error = nil
    }

    private func confirm() async {
        guard !saving else { return }
        guard model.evidenceRoot == request.root, let source = request.sources[file],
              let evidence = EvidencePassage(file: file, range: TextSpan(selection), text: source),
              request.claim.locate(in: model.evidenceSources) != nil,
              evidence.locate(in: model.evidenceSources) != nil else {
            error = "The claim or passage changed. Reopen this picker to select the current text."
            return
        }
        if evidence.file == request.claim.file && evidence.anchor.range.intersects(request.claim.anchor.range) {
            error = "Select the supporting passage outside the claim."
            return
        }
        saving = true
        defer { saving = false }
        let root = request.root
        let index = request.index
        let chosenKind = kind
        var link = ClaimEvidenceLink(claim: request.claim, evidence: evidence, kind: chosenKind)
        do {
            let worker = Task.detached(priority: .utility) { try EvidenceAssets.baseline(for: evidence, root: root, index: index) }
            link.assets = try await worker.value
        } catch {
            self.error = "Could not read a linked figure file. " + error.localizedDescription
            return
        }
        guard model.evidenceRoot == root,
              request.claim.locate(in: model.evidenceSources) != nil,
              evidence.locate(in: model.evidenceSources) != nil else {
            error = "The source changed during confirmation. Reopen this picker to review the current text."
            return
        }
        guard model.claimEvidence.confirm(link, for: request.root, replacing: request.previous?.id) else {
            error = model.claimEvidence.error ?? "The previous link has already been removed."
            return
        }
        model.refreshManuscript()
        model.editor?.refreshDecorations()
        dismiss()
    }
}

/// Read-only source selection retains exact UTF-16 offsets, including mathematical notation.
struct EvidenceExcerptView: NSViewRepresentable {
    let text: String
    @Binding var selection: NSRange

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let view = scroll.documentView as! NSTextView
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.textContainerInset = .init(width: 8, height: 8)
        view.delegate = context.coordinator
        view.setAccessibilityLabel("Supporting source passage")
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.updating = true
        defer { coordinator.updating = false }
        if !view.string.utf16.elementsEqual(text.utf16) { view.string = text }
        guard view.selectedRange() != selection, NSMaxRange(selection) <= (text as NSString).length else { return }
        view.setSelectedRange(selection)
        view.scrollRangeToVisible(selection)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: EvidenceExcerptView
        var updating = false
        init(_ parent: EvidenceExcerptView) { self.parent = parent }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard !updating, let view = notification.object as? NSTextView else { return }
            parent.selection = view.selectedRange()
        }
    }

    private static let environments = try! NSRegularExpression(pattern: #"\\begin\{(figure\*?|table\*?|equation\*?|align\*?|gather\*?|multline\*?)\}[\s\S]*?\\end\{\1\}"#)

    /// Start with a complete figure, table, or equation. Authors may adjust the selection before confirming.
    static func suggestedRange(in source: String, at span: TextSpan) -> NSRange {
        let ns = source as NSString, all = NSRange(location: 0, length: ns.length)
        if let match = environments.matches(in: source, range: all).first(where: { NSLocationInRange(span.location, $0.range) }) {
            return match.range
        }
        return ns.paragraphRange(for: span.nsRange)
    }
}
