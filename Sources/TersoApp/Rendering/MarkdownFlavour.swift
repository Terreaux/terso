// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import TersoCore

/// Syntax beyond CommonMark that only some platforms render. Raw values are
/// the names the preview script reads.
enum MarkdownFeature: String, CaseIterable, Identifiable {
    case tables, strikethrough, taskLists, autolinks, footnotes, math, mermaid
    case admonitions, alerts, highlights, critic, wikiLinks, comments
    var id: String { rawValue }
    var title: String {
        switch self {
        case .tables: "tables"
        case .strikethrough: "strikethrough"
        case .taskLists: "task lists"
        case .autolinks: "bare links"
        case .footnotes: "footnotes"
        case .math: "math"
        case .mermaid: "Mermaid diagrams"
        case .admonitions: "admonitions"
        case .alerts: "callouts"
        case .highlights: "highlights"
        case .critic: "CriticMarkup"
        case .wikiLinks: "wiki links"
        case .comments: "%% comments %%"
        }
    }
}

/// Where a Markdown file will be published, so Preview draws it as that
/// platform would: syntax the platform doesn't know stays as typed.
/// Terso itself renders everything it understands.
enum MarkdownFlavour: String, CaseIterable, Identifiable {
    case terso, commonMark, github, gitlab, obsidian, mkdocs, properdocs, material
    var id: String { rawValue }
    var title: String {
        switch self {
        case .terso: "Terso"
        case .commonMark: "CommonMark"
        case .github: "GitHub"
        case .gitlab: "GitLab"
        case .obsidian: "Obsidian"
        case .mkdocs: "MkDocs"
        case .properdocs: "ProperDocs"
        case .material: "Material for MkDocs"
        }
    }
    /// For the header, where room is short.
    var shortTitle: String {
        switch self {
        case .commonMark: "CM"
        case .github: "GFM"
        case .gitlab: "GLFM"
        case .material: "Material"
        default: title
        }
    }
    var help: String {
        switch self {
        case .terso: "Everything Terso understands"
        case .commonMark: "The CommonMark core, no extensions"
        case .github: "GitHub Flavored Markdown with alerts, footnotes, math and Mermaid"
        case .gitlab: "GitLab Flavored Markdown with alerts, footnotes, math and Mermaid"
        case .obsidian: "Obsidian with callouts, wiki links, highlights and %% comments %%"
        case .mkdocs: "Python-Markdown with MkDocs' default extensions (toc, tables, fenced code)"
        case .properdocs: "Python-Markdown with ProperDocs' default extensions, as MkDocs 1.x"
        case .material: "Python-Markdown with Material's recommended pymdown-extensions"
        }
    }

    var features: Set<MarkdownFeature> {
        switch self {
        case .terso: Set(MarkdownFeature.allCases)
        case .commonMark: []
        case .github, .gitlab: [.tables, .strikethrough, .taskLists, .autolinks, .footnotes, .math, .mermaid, .alerts]
        case .obsidian: [.tables, .strikethrough, .taskLists, .autolinks, .footnotes, .math, .mermaid, .alerts,
                         .highlights, .wikiLinks, .comments]
        // MkDocs' defaults are toc, tables and fenced_code; ProperDocs keeps them.
        case .mkdocs, .properdocs: [.tables]
        // admonition, details, superfences, footnotes, tilde, tasklist, arithmatex, mark, critic.
        case .material: [.tables, .strikethrough, .taskLists, .footnotes, .math, .mermaid, .admonitions,
                         .highlights, .critic]
        }
    }

    /// What the preview script installs for this flavour.
    var previewOptions: [String: Any] {
        ["features": features.map(\.rawValue).sorted(), "gfm": self != .commonMark,
         "alerts": self == .github ? "github" : self == .gitlab ? "gitlab" : "obsidian"]
    }

    /// Syntax this document uses that the flavour would leave as typed.
    @MainActor func unrendered(in text: String) -> [MarkdownFeature] {
        let missing = Set(MarkdownFeature.allCases).subtracting(features)
        guard !missing.isEmpty else { return [] }
        let all = NSRange(location: 0, length: (text as NSString).length)
        let fences = MarkdownStyler.fence.matches(in: text, range: all).map(\.range)
            + [MarkdownSyntax.frontMatter(in: text)].compactMap { $0 }
        func uses(_ pattern: NSRegularExpression) -> Bool {
            pattern.matches(in: text, range: all).contains { m in !fences.contains { NSIntersectionRange($0, m.range).length > 0 } }
        }
        return MarkdownFeature.allCases.filter { feature in
            guard missing.contains(feature) else { return false }
            switch feature {
            case .tables: return uses(MarkdownStyler.tableRule)
            case .strikethrough: return MarkdownStyler.critic.allSatisfy { !uses($0) } && uses(MarkdownStyler.strike)
            case .taskLists: return uses(MarkdownStyler.task)
            case .autolinks: return uses(Self.bareLink)
            case .footnotes: return uses(MarkdownStyler.footnote)
            case .math: return !MathPresentation.regions(in: text).isEmpty
            case .mermaid: return !MermaidPresentation.blocks(in: text).isEmpty
            case .admonitions: return uses(MarkdownStyler.admonition)
            case .alerts: return uses(Self.alert)
            case .highlights: return uses(MarkdownStyler.highlight)
            case .critic: return MarkdownStyler.critic.contains { uses($0) }
            case .wikiLinks: return uses(MarkdownStyler.wikiLink)
            case .comments: return uses(Self.percentComment)
            }
        }
    }

    @MainActor static let bareLink = MarkdownStyler.re(#"(?<![(<\[\w])(?:https?://|www\.)[^\s<>()]+[^\s<>().,;:!?'"]"#, [])
    @MainActor static let alert = MarkdownStyler.re(#"^ {0,3}>[ \t]*\[![\w-]+\]"#)
    @MainActor static let percentComment = MarkdownStyler.re(#"%%[\s\S]*?%%"#, [])

}

/// The default flavour, from Settings, and the one chosen for each file,
/// remembered by path.
@MainActor
@Observable
final class MarkdownFlavours {
    static let shared = MarkdownFlavours()
    private let defaults: UserDefaults

    /// Where Markdown files are published unless a file says otherwise.
    var standard: MarkdownFlavour { didSet { defaults.set(standard.rawValue, forKey: "markdownFlavour") } }
    private var chosen: [String: String] { didSet { defaults.set(chosen, forKey: "markdownFlavours") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        standard = MarkdownFlavour(rawValue: defaults.string(forKey: "markdownFlavour") ?? "") ?? .terso
        chosen = defaults.dictionary(forKey: "markdownFlavours") as? [String: String] ?? [:]
    }

    func flavour(for url: URL) -> MarkdownFlavour? {
        chosen[url.standardizedFileURL.path].flatMap(MarkdownFlavour.init(rawValue:))
    }

    func choose(_ flavour: MarkdownFlavour?, for url: URL) {
        chosen[url.standardizedFileURL.path] = flavour?.rawValue
    }
}

extension WorkspaceModel {
    /// How Preview draws this Markdown: as the platform it will be published
    /// on. A file remembers its own; an unsaved one keeps it for the session.
    var markdownFlavour: MarkdownFlavour {
        get { fileURL.flatMap { MarkdownFlavours.shared.flavour(for: $0) } ?? unsavedFlavour ?? MarkdownFlavours.shared.standard }
        set {
            if let fileURL { MarkdownFlavours.shared.choose(newValue, for: fileURL) } else { unsavedFlavour = newValue }
        }
    }
}

/// A quiet line under Preview naming the syntax this flavour leaves as typed.
struct FlavourNote: View {
    let flavour: MarkdownFlavour
    let source: String

    var body: some View {
        let missing = flavour.unrendered(in: source)
        if !missing.isEmpty {
            Text("\(flavour.title) shows \(ListFormatter.localizedString(byJoining: missing.map(\.title))) as typed")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 12)
                .help(flavour.help)
        }
    }
}
