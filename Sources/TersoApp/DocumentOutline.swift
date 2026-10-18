// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import SwiftUI
import TersoCore

/// Source ranges and semantic levels, independent of the last analysis or PDF layout.
struct DocumentOutline {
    struct Heading: Identifiable, Equatable {
        let title: String
        let range: TextSpan
        let level: Int
        var id: TextSpan { range }
    }
    struct Insertion {
        let location: Int
        let text: String
        let selection: NSRange
        let name: String
    }

    let source: String
    let latex: Bool
    let book: Bool
    let headings: [Heading]
    let rootLevel: Int

    init(source: String, latex: Bool, book: Bool) {
        self.source = source
        self.latex = latex
        self.book = book
        let ns = source as NSString
        let end = latex ? LaTeXSyntax.trailer(in: source)?.location ?? ns.length : ns.length
        let all = NSRange(location: 0, length: ns.length)
        var hidden = Self.fences.matches(in: source, range: all).map(\.range)
        if latex {
            hidden += LaTeXSyntax.literalEnvironments(in: source).map(\.range)
            let start = min(end, LaTeXSyntax.preamble(in: source)?.upperBound ?? 0)
            headings = LaTeXSyntax.section.matches(in: source, range: NSRange(location: start, length: end - start))
                .filter { m in !hidden.contains { NSLocationInRange(m.range.location, $0) } && !LaTeXHeading.commented(m.range.location, in: ns) }
                .map { m in
                    Heading(title: LaTeXSyntax.plainTitle(ns.substring(with: m.range(at: 2))), range: TextSpan(m.range),
                            level: LaTeXSyntax.sectionCommands.firstIndex(of: ns.substring(with: m.range(at: 1)))!)
                }
        } else {
            hidden += MarkdownSyntax.frontMatter(in: source).map { [$0] } ?? []
            hidden += MarkdownSyntax.mathRanges(in: source)
            hidden += Self.comments.matches(in: source, range: all)
                .filter { m in !hidden.contains { NSLocationInRange(m.range.location, $0) } }.map(\.range)
            headings = Self.markdownHeadings.matches(in: source, range: all)
                .filter { m in !hidden.contains { NSLocationInRange(m.range.location, $0) } }
                .map { m in Heading(title: ns.substring(with: m.range(at: 2)), range: TextSpan(m.range), level: m.range(at: 1).length) }
        }
        if latex {
            // Existing commands guide custom classes; standard empty books/reports
            // must start with chapters, while an article must start with sections.
            let classPattern = try! NSRegularExpression(pattern: #"\\documentclass(?:\[[^\]]*\])?\s*\{(book|report|memoir|scrbook|scrreprt)\}"#)
            let hasChapters = headings.contains { $0.level == 1 }
                || classPattern.matches(in: source, range: NSRange(location: 0, length: ns.length))
                    .contains { !LaTeXHeading.commented($0.range.location, in: ns) }
            rootLevel = hasChapters ? 1 : 2
        } else {
            rootLevel = 1
        }
    }

    // Scan headings only; sentence segmentation and word analysis stay off the UI path.
    private static let markdownHeadings = try! NSRegularExpression(pattern: #"^[ ]{0,3}(#{1,6})[ \t]+(.*?)[ \t#]*$"#, options: .anchorsMatchLines)
    private static let fences = try! NSRegularExpression(pattern: #"^[ \t]*(`{3,}|~{3,})[^\n]*\n[\s\S]*?(?:^[ \t]*\1[`~]*[ \t]*$|\z)"#, options: .anchorsMatchLines)
    private static let comments = try! NSRegularExpression(pattern: #"<!--[\s\S]*?(?:-->|\z)"#)

    var maximumLevel: Int { 6 }
    func insertionLevel(under parent: Heading?) -> Int {
        parent.map { max($0.level + 1, rootLevel) } ?? rootLevel
    }

    func name(at level: Int) -> String {
        if latex {
            return ["Part", "Chapter", "Section", "Subsection", "Subsubsection", "Paragraph", "Subparagraph"][level]
        }
        let names = book ? ["Chapter", "Section", "Subsection", "Subsubsection"] : ["Section", "Subsection", "Subsubsection"]
        return names.indices.contains(level - 1) ? names[level - 1] : "Heading \(level)"
    }

    /// Append inside the chosen heading's subtree, before its next sibling or ancestor.
    /// A stale row is ignored, rather than inserting into a different heading.
    func insertion(under parent: Heading? = nil) -> Insertion? {
        let level = insertionLevel(under: parent)
        guard level <= maximumLevel else { return nil }
        let ns = source as NSString
        let end = latex ? LaTeXSyntax.trailer(in: source)?.location ?? ns.length : ns.length
        var at = end
        var scopeStart = 0
        if let parent {
            guard let i = headings.firstIndex(of: parent) else { return nil }
            at = headings.dropFirst(i + 1).first { $0.level <= parent.level }?.range.location ?? end
            scopeStart = parent.range.upperBound
        }
        let name = name(at: level)
        let number = headings.filter { $0.level == level && $0.range.location >= scopeStart && $0.range.location < at }.count + 1
        let title = "\(name) \(number)"
        let newline = source.contains("\r\n") ? "\r\n" : "\n"
        let before = ns.substring(to: at)
        let lead = before.isEmpty || before.hasSuffix(newline + newline) ? "" : before.hasSuffix(newline) ? newline : newline + newline
        let marker = latex ? "\\\(LaTeXSyntax.sectionCommands[level]){" : String(repeating: "#", count: level) + " "
        let text = lead + marker + title + (latex ? "}" : "") + newline + newline
        return Insertion(location: at, text: text,
                         selection: NSRange(location: at + lead.utf16.count + marker.utf16.count, length: title.utf16.count), name: name)
    }
}

extension WorkspaceModel {
    var documentOutline: DocumentOutline {
        let source = editor?.currentSnapshot.text ?? ""
        let editorID = editor.map(ObjectIdentifier.init)
        if let cache = sidebarOutlineCache, cache.revision == revision, cache.editorID == editorID,
           cache.fileURL == fileURL, cache.outline.book == manutius, cache.outline.source == source { return cache.outline }
        let outline = DocumentOutline(source: source, latex: RenderMode.isLaTeX(source: source, fileURL: fileURL), book: manutius)
        sidebarOutlineCache = DocumentOutlineCache(revision: revision, editorID: editorID, fileURL: fileURL, outline: outline)
        return outline
    }
}

struct DocumentOutlineCache {
    let revision: DocumentRevision
    let editorID: ObjectIdentifier?
    let fileURL: URL?
    let outline: DocumentOutline
}

extension EditorCoordinator {
    func addHeading(under parent: DocumentOutline.Heading? = nil) {
        guard let tv = textView else { return }
        let outline = DocumentOutline(source: tv.string, latex: config?.latex == true, book: model.manutius)
        guard let edit = outline.insertion(under: parent) else { return }
        let original = tv.string
        replace(TextSpan(location: edit.location, length: 0), with: edit.text, actionName: "Add \(edit.name)")
        guard tv.string != original else { return }
        if model.renderMode == .preview { model.renderMode = .mixed }
        tv.setSelectedRange(edit.selection)
        tv.scrollRangeToVisible(edit.selection)
        tv.window?.makeFirstResponder(tv)
        refreshBookOutline()
    }
}

struct AddHeadingButton: View {
    let model: WorkspaceModel
    let outline: DocumentOutline
    var parent: DocumentOutline.Heading?
    var visible = true
    @FocusState private var focused: Bool

    var body: some View {
        let level = outline.insertionLevel(under: parent)
        if level <= outline.maximumLevel {
            let name = outline.name(at: level)
            Button { (model.editor as? EditorCoordinator)?.addHeading(under: parent) } label: {
                Image(systemName: "plus").opacity(visible || focused ? 1 : 0)
            }
                .buttonStyle(.borderless)
                .focused($focused)
                .allowsHitTesting(visible || focused)
                .help(parent.map { "Add a \(name.lowercased()) in \($0.title)" } ?? "Add a \(name.lowercased()) at the end")
                .accessibilityLabel(parent.map { "Add \(name) to \($0.title)" } ?? "Add \(name)")
                .disabled(model.editor == nil)
        }
    }
}

/// Keep room for the action so titles and page numbers never move on hover.
struct HeadingActionRow<Content: View>: View {
    let model: WorkspaceModel
    let outline: DocumentOutline
    let heading: DocumentOutline.Heading
    @ViewBuilder let content: () -> Content
    @State private var hovered = false

    var body: some View {
        HStack {
            content()
            AddHeadingButton(model: model, outline: outline, parent: heading, visible: hovered)
        }
        .contentShape(Rectangle())
        .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hovered = inside } }
        .accessibilityElement(children: .contain)
    }
}

struct OutlineHeadingRow: View {
    let model: WorkspaceModel
    let outline: DocumentOutline
    let heading: DocumentOutline.Heading

    var body: some View {
        HeadingActionRow(model: model, outline: outline, heading: heading) {
            Button { model.editor?.reveal(heading.range, select: true) } label: {
                Text(heading.title)
                    .font(heading.level == outline.rootLevel ? .body.weight(.medium) : .body)
                    .foregroundStyle(heading.level <= outline.rootLevel + 1 ? .primary : .secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, CGFloat(max(0, heading.level - outline.rootLevel)) * 10)
    }
}
