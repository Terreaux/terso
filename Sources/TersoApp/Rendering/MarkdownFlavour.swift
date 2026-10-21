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

    /// Python-Markdown sites: what renders is what their config turns on.
    var readsSiteConfig: Bool { [.mkdocs, .properdocs, .material].contains(self) }

    /// The flavour's own defaults, for a file without a site config.
    var dialect: MarkdownDialect {
        MarkdownDialect(flavour: self, features: features,
                        alertStyle: self == .github ? "github" : self == .gitlab ? "gitlab" : "obsidian")
    }
}

/// What renders for one file: its flavour's defaults, or for MkDocs and
/// ProperDocs what the site's config turns on.
struct MarkdownDialect: Equatable {
    var flavour: MarkdownFlavour
    var features: Set<MarkdownFeature>
    /// Which callouts render: "github" (five kinds, no title), "gitlab"
    /// (five kinds, a title) or "obsidian" (any kind, a title, folding).
    var alertStyle: String
    /// The config these features were read from.
    var site: MkDocsSite? = nil

    var title: String { flavour.title }
    var help: String {
        guard let site else { return flavour.help }
        let named = site.extensions.filter { !["toc", "tables", "fenced_code"].contains($0) }
        let list = named.isEmpty ? "only MkDocs' default extensions"
            : ListFormatter.localizedString(byJoining: Array(named.prefix(6))) + (named.count > 6 ? " and \(named.count - 6) more" : "")
        return "\(flavour.title) with \(list), from \(site.config.lastPathComponent)"
    }

    static let terso = MarkdownFlavour.terso.dialect, commonMark = MarkdownFlavour.commonMark.dialect
    static let github = MarkdownFlavour.github.dialect, gitlab = MarkdownFlavour.gitlab.dialect
    static let obsidian = MarkdownFlavour.obsidian.dialect, mkdocs = MarkdownFlavour.mkdocs.dialect
    static let properdocs = MarkdownFlavour.properdocs.dialect, material = MarkdownFlavour.material.dialect

    /// What the preview script installs, and how its tooltips name what the
    /// platform leaves as typed.
    var previewOptions: [String: Any] {
        var titles = Dictionary(uniqueKeysWithValues: MarkdownFeature.allCases.map { ($0.rawValue, $0.title) })
        // With alerts on, only kinds and forms the platform lacks are marked.
        if features.contains(.alerts) { titles[MarkdownFeature.alerts.rawValue] = "this kind of callout" }
        return ["features": features.map(\.rawValue).sorted(), "gfm": flavour != .commonMark,
                "alerts": alertStyle, "platform": title, "titles": titles]
    }

    /// Distinguishes two dialects of one flavour, for caches.
    var key: String { "\(flavour.rawValue)|\(alertStyle)|" + features.map(\.rawValue).sorted().joined(separator: ",") }
}

/// Where a file's surroundings say it is published: the nearest folder
/// holding a docs-site config, an Obsidian vault or a git remote decides.
struct FlavourDetection: Equatable {
    let flavour: MarkdownFlavour
    /// Why, for the chip: "mkdocs.yml", "GitHub remote".
    let reason: String
    /// The MkDocs or ProperDocs config the site was found by.
    var config: URL? = nil

    static func detect(for file: URL, fileManager: FileManager = .default) -> FlavourDetection? {
        let home = fileManager.homeDirectoryForCurrentUser.standardizedFileURL.path
        var folder = file.standardizedFileURL.deletingLastPathComponent()
        for _ in 0..<24 {
            if let found = inspect(folder, file: file, fileManager: fileManager) { return found }
            let parent = folder.deletingLastPathComponent()
            if parent.path == folder.path || folder.path == home { return nil }
            folder = parent
        }
        return nil
    }

    /// A folder that settles the question; a git repository without a
    /// GitHub or GitLab remote settles it as unknown.
    /// The nil inside means "settled, unknown".
    private static func inspect(_ folder: URL, file: URL, fileManager: FileManager) -> FlavourDetection?? {
        func exists(_ name: String, directory: Bool = false) -> URL? {
            let url = folder.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue == directory else { return nil }
            return url
        }
        for name in ["properdocs.yml", "properdocs.yaml", "mkdocs.yml", "mkdocs.yaml"] {
            guard let config = exists(name), let text = read(config) else { continue }
            // Pages outside docs_dir (a README beside mkdocs.yml) aren't part of the site.
            guard file.standardizedFileURL.path.hasPrefix(folder.appendingPathComponent(MkDocsSite.docsDirectory(in: text)).path + "/") else { break }
            return site(config)
        }
        if exists(".obsidian", directory: true) != nil { return FlavourDetection(flavour: .obsidian, reason: "Obsidian vault") }
        let git = folder.appendingPathComponent(".git")
        guard fileManager.fileExists(atPath: git.path) else { return nil }
        let remotes = read(git.appendingPathComponent("config"))?.lowercased() ?? ""
        if remotes.contains("github.com") { return FlavourDetection(flavour: .github, reason: "GitHub remote") }
        if remotes.contains("gitlab") { return FlavourDetection(flavour: .gitlab, reason: "GitLab remote") }
        return .some(nil)
    }

    /// The site a config describes, found nearby or linked by the writer.
    static func site(_ config: URL, linked: Bool = false) -> FlavourDetection {
        let text = read(config) ?? ""
        let name = config.lastPathComponent
        let flavour: MarkdownFlavour = name.lowercased().hasPrefix("properdocs") ? .properdocs
            : MkDocsSite.usesMaterial(text) ? .material : .mkdocs
        let reason = (linked ? "linked " : "") + name + (flavour == .material ? " with Material" : "")
        return FlavourDetection(flavour: flavour, reason: reason, config: config)
    }

    private static func read(_ url: URL) -> String? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 512_000 else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    static func docsDirectory(in config: String) -> String { MkDocsSite.docsDirectory(in: config) }
    static func usesMaterial(_ config: String) -> Bool { MkDocsSite.usesMaterial(config) }
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
    /// An MkDocs or ProperDocs config the writer linked to a file, by path.
    private var linked: [String: String] { didSet { defaults.set(linked, forKey: "markdownFlavourConfigs") } }
    /// Detection reads a few small files; once per file per session is enough.
    @ObservationIgnored private var detections: [String: FlavourDetection?] = [:]
    /// Configs are read again when they change on disk.
    @ObservationIgnored private var sites: [String: (modified: Date?, site: MkDocsSite?)] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        standard = MarkdownFlavour(rawValue: defaults.string(forKey: "markdownFlavour") ?? "") ?? .terso
        chosen = defaults.dictionary(forKey: "markdownFlavours") as? [String: String] ?? [:]
        linked = defaults.dictionary(forKey: "markdownFlavourConfigs") as? [String: String] ?? [:]
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
        if let path = linked[key] {
            let config = URL(fileURLWithPath: path), site = site(at: config)
            let flavour = site?.flavour ?? .mkdocs
            return FlavourDetection(flavour: flavour, reason: "linked \(config.lastPathComponent)" + (flavour == .material ? " with Material" : ""),
                                    config: config)
        }
        if let known = detections[key] { return known }
        let found = FlavourDetection.detect(for: url)
        detections[key] = found
        return found
    }

    func linkedConfig(for url: URL) -> URL? { linked[url.standardizedFileURL.path].map(URL.init(fileURLWithPath:)) }

    /// Links a site config to a file, or with nil goes back to the one found nearby.
    func link(_ config: URL?, to url: URL) {
        linked[url.standardizedFileURL.path] = config?.standardizedFileURL.path
    }

    /// The site's config as it is on disk now.
    func site(at config: URL) -> MkDocsSite? {
        // URL caches resource values per instance; the file system has the current date.
        let modified = (try? FileManager.default.attributesOfItem(atPath: config.path))?[.modificationDate] as? Date
        if let known = sites[config.path], known.modified == modified { return known.site }
        let site = MkDocsSite.read(config)
        sites[config.path] = (modified, site)
        return site
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

    /// The site config behind this file, when its flavour is MkDocs-like.
    var mkDocsSite: MkDocsSite? {
        guard markdownFlavour.readsSiteConfig, let config = flavourDetection?.config else { return nil }
        return MarkdownFlavours.shared.site(at: config)
    }

    /// What renders for this file: the flavour, with an MkDocs site's own extensions.
    var markdownDialect: MarkdownDialect {
        guard let site = mkDocsSite else { return markdownFlavour.dialect }
        // A chosen flavour keeps its name; the site says what renders.
        var dialect = site.dialect
        dialect.flavour = markdownFlavour
        return dialect
    }
}
