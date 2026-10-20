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
        case .comments: "Obsidian comments"
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

    /// What the preview script installs for this flavour, and how its
    /// tooltips name what the platform leaves as typed.
    var previewOptions: [String: Any] {
        var titles = Dictionary(uniqueKeysWithValues: MarkdownFeature.allCases.map { ($0.rawValue, $0.title) })
        // With alerts on, only kinds and forms the platform lacks are marked.
        if features.contains(.alerts) { titles[MarkdownFeature.alerts.rawValue] = "this kind of callout" }
        return ["features": features.map(\.rawValue).sorted(), "gfm": self != .commonMark,
                "alerts": self == .github ? "github" : self == .gitlab ? "gitlab" : "obsidian",
                "platform": title, "titles": titles]
    }
}

/// Where a file's surroundings say it is published: the nearest folder
/// holding a docs-site config, an Obsidian vault or a git remote decides.
struct FlavourDetection: Equatable {
    let flavour: MarkdownFlavour
    /// Why, for the Preview chip: "mkdocs.yml", "GitHub remote".
    let reason: String

    static func detect(for file: URL, fileManager: FileManager = .default) -> FlavourDetection? {
        let home = fileManager.homeDirectoryForCurrentUser.standardizedFileURL.path
        var folder = file.standardizedFileURL.deletingLastPathComponent()
        for _ in 0..<24 {
            if let found = inspect(folder, file: file, fileManager: fileManager) { return found.flavour == nil ? nil : FlavourDetection(flavour: found.flavour!, reason: found.reason) }
            let parent = folder.deletingLastPathComponent()
            if parent.path == folder.path || folder.path == home { return nil }
            folder = parent
        }
        return nil
    }

    /// A folder that settles the question; a git repository without a
    /// GitHub or GitLab remote settles it as unknown.
    private static func inspect(_ folder: URL, file: URL, fileManager: FileManager) -> (flavour: MarkdownFlavour?, reason: String)? {
        func exists(_ name: String, directory: Bool = false) -> URL? {
            let url = folder.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue == directory else { return nil }
            return url
        }
        for name in ["properdocs.yml", "properdocs.yaml", "mkdocs.yml", "mkdocs.yaml"] {
            guard let config = exists(name), let text = read(config) else { continue }
            // Pages outside docs_dir (a README beside mkdocs.yml) aren't part of the site.
            guard file.standardizedFileURL.path.hasPrefix(folder.appendingPathComponent(docsDirectory(in: text)).path + "/") else { break }
            if name.hasPrefix("properdocs") { return (.properdocs, name) }
            return usesMaterial(text) ? (.material, "\(name) with Material") : (.mkdocs, name)
        }
        if exists(".obsidian", directory: true) != nil { return (.obsidian, "Obsidian vault") }
        let git = folder.appendingPathComponent(".git")
        guard fileManager.fileExists(atPath: git.path) else { return nil }
        let remotes = read(git.appendingPathComponent("config"))?.lowercased() ?? ""
        if remotes.contains("github.com") { return (.github, "GitHub remote") }
        if remotes.contains("gitlab") { return (.gitlab, "GitLab remote") }
        return (nil, "")
    }

    private static func read(_ url: URL) -> String? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 512_000 else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    static func docsDirectory(in config: String) -> String {
        let pattern = try! NSRegularExpression(pattern: ##"^docs_dir:[ \t]*['"]?([^'"#\n]+?)['"]?[ \t]*(?:#.*)?$"##, options: .anchorsMatchLines)
        let ns = config as NSString
        guard let m = pattern.firstMatch(in: config, range: NSRange(location: 0, length: ns.length)) else { return "docs" }
        return ns.substring(with: m.range(at: 1)).trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
    }

    /// `theme: material`, or a `theme:` block whose `name:` is material.
    static func usesMaterial(_ config: String) -> Bool {
        let pattern = try! NSRegularExpression(
            pattern: ##"^theme:[ \t]*(?:['"]?material['"]?[ \t]*(?:#.*)?$|(?:#.*)?\n(?:(?:[ \t]+.*|[ \t]*)\n)*?[ \t]+name:[ \t]*['"]?material['"]?)"##,
            options: .anchorsMatchLines)
        return pattern.firstMatch(in: config, range: NSRange(location: 0, length: (config as NSString).length)) != nil
    }
}

/// The default flavour, from Settings, the one chosen for each file,
/// remembered by path, and what each folder's surroundings suggest.
@MainActor
@Observable
final class MarkdownFlavours {
    static let shared = MarkdownFlavours()
    private let defaults: UserDefaults

    /// Where Markdown files are published unless a file or folder says otherwise.
    var standard: MarkdownFlavour { didSet { defaults.set(standard.rawValue, forKey: "markdownFlavour") } }
    private var chosen: [String: String] { didSet { defaults.set(chosen, forKey: "markdownFlavours") } }
    /// Detection reads a few small files; once per file per session is enough.
    @ObservationIgnored private var detections: [String: FlavourDetection?] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        standard = MarkdownFlavour(rawValue: defaults.string(forKey: "markdownFlavour") ?? "") ?? .terso
        chosen = defaults.dictionary(forKey: "markdownFlavours") as? [String: String] ?? [:]
    }

    func flavour(for url: URL) -> MarkdownFlavour? {
        chosen[url.standardizedFileURL.path].flatMap(MarkdownFlavour.init(rawValue:))
    }

    /// nil goes back to automatic: detected, else the default.
    func choose(_ flavour: MarkdownFlavour?, for url: URL) {
        chosen[url.standardizedFileURL.path] = flavour?.rawValue
    }

    func detection(for url: URL) -> FlavourDetection? {
        let key = url.standardizedFileURL.path
        if let known = detections[key] { return known }
        let found = FlavourDetection.detect(for: url)
        detections[key] = found
        return found
    }
}

extension WorkspaceModel {
    /// How Preview draws this Markdown: as the platform it will be published
    /// on. A file's own choice wins, then its surroundings, then Settings.
    var markdownFlavour: MarkdownFlavour {
        get { chosenFlavour ?? automaticFlavour }
        set { chosenFlavour = newValue }
    }

    /// Chosen for this file, or nil to follow `automaticFlavour`. An
    /// unsaved document keeps its choice for the session.
    var chosenFlavour: MarkdownFlavour? {
        get { fileURL.map { MarkdownFlavours.shared.flavour(for: $0) } ?? unsavedFlavour }
        set { if let fileURL { MarkdownFlavours.shared.choose(newValue, for: fileURL) } else { unsavedFlavour = newValue } }
    }

    var flavourDetection: FlavourDetection? { fileURL.flatMap { MarkdownFlavours.shared.detection(for: $0) } }
    var automaticFlavour: MarkdownFlavour { flavourDetection?.flavour ?? MarkdownFlavours.shared.standard }
}
