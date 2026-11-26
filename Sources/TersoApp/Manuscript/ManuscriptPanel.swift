// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import TersoCore

struct CitationInsertion {
    let range: TextSpan
    let replacement: String
    let query: String
    let isValid: Bool

    init(source: String, selection: TextSpan, key: String, latex: Bool) {
        let ns = source as NSString
        guard selection.location >= 0, selection.location <= ns.length, selection.length >= 0,
              selection.length <= ns.length - selection.location else {
            range = selection
            replacement = ""
            query = ""
            isValid = false
            return
        }
        isValid = true
        let head = ns.substring(to: selection.location)
        let pattern = latex
            ? #"\\(?:\w*?[Cc]ite\w*)\*?(?:\s*\[[^\]]*\])*\s*\{[^{}]*$"#
            : #"(?<![\w@.])@([\w:.\-]*)$"#
        let match = head.range(of: pattern, options: [.regularExpression, .caseInsensitive])
        if selection.length == 0, let match {
            let before = head[match].reversed().prefix { $0.isLetter || $0.isNumber || ":._-/".contains($0) }
            query = String(before.reversed())
            let tail = ns.substring(from: selection.location)
            let after = tail.prefix { $0.isLetter || $0.isNumber || ":._-/".contains($0) }
            range = .init(location: selection.location - query.utf16.count, length: query.utf16.count + after.utf16.count)
            let hasClosingBrace = tail.dropFirst(after.count).drop(while: { $0 == " " }).first.map { $0 == "}" || $0 == "," } ?? false
            replacement = latex && !hasClosingBrace ? key + "}" : key
        } else {
            query = ""
            range = selection
            replacement = latex ? "\\cite{\(key)}" : "[@\(key)]"
        }
    }
}

struct ManuscriptPanel: View {
    enum Section: String, CaseIterable { case review = "Review", sources = "Files", citations = "Citations", labels = "Labels" }
    @Bindable var model: WorkspaceModel
    @State private var section: Section = .review
    @State private var search = ""
    @Environment(\.dismiss) private var dismiss
    @FocusState private var searching: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Manuscript references").font(.title2)
                Spacer()
                Button { model.refreshManuscript() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let index = model.manuscriptIndex {
                Text(index.root.lastPathComponent).font(.callout).foregroundStyle(.secondary).help(index.root.path)
                Picker("View", selection: $section) {
                    ForEach(Section.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden()
                if section == .citations || section == .labels {
                    TextField(section == .citations ? "Search by key, author, or title" : "Search labels", text: $search)
                        .textFieldStyle(.roundedBorder).focused($searching)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) { content(index) }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if let problem = model.manuscriptProblem {
                Text(problem).foregroundStyle(.secondary)
            } else {
                Text("Open a LaTeX file or link a bibliography with a Markdown bibliography field or a manuscript project.")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }.padding(20).frame(minWidth: 540, idealWidth: 640, minHeight: 370, idealHeight: 470)
        .onAppear {
            if model.manuscriptStartsWithCitations {
                section = .citations
                if let editor = model.editor {
                    search = CitationInsertion(source: editor.currentSnapshot.text, selection: editor.selection, key: "", latex: model.isLaTeXDocument).query
                }
                searching = true
            }
        }
    }

    @ViewBuilder private func content(_ index: ManuscriptIndex) -> some View {
        switch section {
        case .review:
            if index.findings.isEmpty { Text("No unresolved manuscript references or inputs.").foregroundStyle(.secondary) }
            ForEach(index.findings) { item in
                sourceButton(item.title, item.detail, item.location, index)
            }
        case .sources:
            ForEach(index.sources.keys.sorted(by: { $0.path < $1.path }), id: \.self) { url in
                sourceButton(relative(url, index), url == index.root ? "Manuscript root" : "Included source", .init(url: url, range: .init(location: 0, length: 0), line: 1), index)
            }
            ForEach(index.resources.sorted(by: { $0.path < $1.path }), id: \.self) { url in
                Button(relative(url, index)) {
                    if url.pathExtension.lowercased() == "bib" { jump(.init(url: url, range: .init(location: 0, length: 0), line: 1)) }
                    else { NSWorkspace.shared.open(url) }
                }.buttonStyle(.link)
            }
        case .citations:
            let matches = index.bibliography.filter { entry in
                search.isEmpty || [entry.key, entry.author, entry.title].contains { $0.localizedCaseInsensitiveContains(search) }
            }
            if matches.isEmpty { Text(index.bibliography.isEmpty ? "No bibliography entries indexed." : "No matching citations.").foregroundStyle(.secondary) }
            ForEach(matches) { entry in
                HStack(alignment: .top) {
                    sourceButton(entry.title.isEmpty ? entry.key : entry.title, [entry.author, entry.key].filter { !$0.isEmpty }.joined(separator: " · "), entry.location, index)
                    Spacer()
                    Button("Insert") { insert(entry.key) }.disabled(model.renderMode == .preview)
                }
            }
        case .labels:
            let keys = index.labels.keys.sorted().filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }
            if keys.isEmpty { Text("No matching labels.").foregroundStyle(.secondary) }
            ForEach(keys, id: \.self) { key in
                ForEach(index.labels[key] ?? []) { loc in
                    sourceButton(key, "Declaration", loc, index)
                }
                ForEach(index.references[key] ?? []) { loc in
                    sourceButton(key, "Reference", loc, index)
                }
            }
        }
    }

    private func sourceButton(_ title: String, _ detail: String, _ location: ManuscriptLocation, _ index: ManuscriptIndex) -> some View {
        Button { jump(location) } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fontWeight(.medium)
                Text([detail, "\(relative(location.url, index)):\(location.line)"].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }.multilineTextAlignment(.leading)
        }.buttonStyle(.plain)
    }

    private func relative(_ url: URL, _ index: ManuscriptIndex) -> String {
        let base = index.root.deletingLastPathComponent().path + "/"
        return url.path.hasPrefix(base) ? String(url.path.dropFirst(base.count)) : url.path
    }

    private func jump(_ location: ManuscriptLocation) {
        dismiss()
        DispatchQueue.main.async { ManuscriptContext.reveal(location) }
    }

    private func insert(_ key: String) {
        guard let editor = model.editor else { return }
        let edit = CitationInsertion(source: editor.currentSnapshot.text, selection: editor.selection, key: key, latex: model.isLaTeXDocument)
        guard edit.isValid else { return }
        editor.replace(edit.range, with: edit.replacement, actionName: "Insert Citation")
        dismiss()
    }
}
