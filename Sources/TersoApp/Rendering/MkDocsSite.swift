// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// What an MkDocs or ProperDocs site renders, read from its config: the
/// `markdown_extensions` and `plugins` lists, following `INHERIT:`. Only
/// those lists and the theme's name are read; nothing in the config runs.
struct MkDocsSite: Equatable {
    let config: URL
    /// Extension names without the `markdown.extensions.` prefix, in order.
    let extensions: [String]
    let plugins: [String]
    let material: Bool
    /// A superfences custom fence named `mermaid`.
    let mermaid: Bool

    var properdocs: Bool { config.lastPathComponent.lowercased().hasPrefix("properdocs") }
    var flavour: MarkdownFlavour { properdocs ? .properdocs : material ? .material : .mkdocs }

    /// MkDocs always adds toc, tables and fenced_code; the rest is the config's.
    var features: Set<MarkdownFeature> {
        var features: Set<MarkdownFeature> = [.tables]
        for name in extensions {
            switch name {
            case "admonition", "pymdownx.blocks.admonition", "pymdownx.details", "pymdownx.blocks.details": features.insert(.admonitions)
            case "footnotes", "extra": features.insert(.footnotes)
            case "pymdownx.tilde": features.insert(.strikethrough)
            case "pymdownx.tasklist": features.insert(.taskLists)
            case "pymdownx.arithmatex", "mdx_math", "markdown_katex": features.insert(.math)
            case "pymdownx.mark": features.insert(.highlights)
            case "pymdownx.critic": features.insert(.critic)
            case "pymdownx.magiclink": features.insert(.autolinks)
            case "wikilinks": features.insert(.wikiLinks)
            case "github-callouts": features.insert(.alerts)
            default: break
            }
        }
        if mermaid { features.insert(.mermaid) }
        for name in plugins {
            switch name {
            case "callouts": features.insert(.alerts)
            case "roamlinks", "ezlinks", "wikilinks": features.insert(.wikiLinks)
            default: break
            }
        }
        return features
    }

    /// mkdocs-callouts converts Obsidian's callouts; markdown-callouts' `github-callouts` takes GitHub's five.
    var alertStyle: String { plugins.contains("callouts") ? "obsidian" : "github" }

    var dialect: MarkdownDialect {
        MarkdownDialect(flavour: flavour, features: features, alertStyle: alertStyle, site: self)
    }

    // MARK: Reading

    static func read(_ url: URL, depth: Int = 0) -> MkDocsSite? {
        guard depth < 4, let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 512_000,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var extensions = list("markdown_extensions", in: text)
        var plugins = list("plugins", in: text)
        var material = usesMaterial(text)
        var mermaid = mermaidFence(in: text)
        // A child's lists extend its parent's, as MkDocs merges them.
        if let parent = value("INHERIT", in: text),
           let base = read(url.deletingLastPathComponent().appendingPathComponent(parent).standardizedFileURL, depth: depth + 1) {
            extensions = base.extensions + extensions.filter { !base.extensions.contains($0) }
            plugins = base.plugins + plugins.filter { !base.plugins.contains($0) }
            // A child without its own theme keeps its parent's.
            let themed = text.components(separatedBy: .newlines).contains { $0.hasPrefix("theme:") }
            material = themed ? material : base.material
            mermaid = mermaid || base.mermaid
        }
        return MkDocsSite(config: url, extensions: extensions, plugins: plugins, material: material, mermaid: mermaid)
    }

    /// The item names of a top-level YAML list, block or inline:
    /// `- admonition`, `- pymdownx.superfences:` or `[toc, admonition]`.
    static func list(_ key: String, in text: String) -> [String] {
        let lines = text.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: { $0.hasPrefix("\(key):") }) else { return [] }
        func name(_ item: Substring) -> String? {
            var item = item.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespaces)
            if let colon = item.firstIndex(of: ":") { item = String(item[..<colon]) }
            item = item.trimmingCharacters(in: CharacterSet(charactersIn: "'\" {"))
            guard !item.isEmpty else { return nil }
            return item.hasPrefix("markdown.extensions.") ? String(item.dropFirst("markdown.extensions.".count)) : item
        }
        let rest = lines[start].dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix("[") {
            return rest.dropFirst().split(separator: "]")[0].split(separator: ",").compactMap(name)
        }
        var names: [String] = []
        var itemIndent: Int?
        for line in lines[(start + 1)...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = line.prefix { $0 == " " || $0 == "\t" }.count
            // The next top-level key ends the list; YAML lets its items sit at column 0.
            if indent == 0 && !trimmed.hasPrefix("-") { break }
            guard trimmed.hasPrefix("- ") || trimmed == "-" else { continue }
            if itemIndent == nil { itemIndent = indent }
            if indent == itemIndent, let item = name(trimmed.dropFirst(1)) { names.append(item) }
        }
        return names
    }

    /// A top-level scalar such as `INHERIT: ../base.yml`.
    static func value(_ key: String, in text: String) -> String? {
        guard let line = text.components(separatedBy: .newlines).first(where: { $0.hasPrefix("\(key):") }) else { return nil }
        let value = line.dropFirst(key.count + 1).split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        return value.isEmpty ? nil : value
    }

    /// pymdownx.superfences' `custom_fences` naming `mermaid`.
    static func mermaidFence(in text: String) -> Bool {
        guard let range = text.range(of: "pymdownx.superfences") else { return false }
        let after = text[range.upperBound...]
        // Only within the extensions list: up to the next top-level key.
        let block = after.range(of: #"\n[A-Za-z_]"#, options: .regularExpression).map { after[..<$0.lowerBound] } ?? after
        return block.range(of: #"name:[ \t]*['"]?mermaid"#, options: .regularExpression) != nil
    }

    /// `theme: material`, or a `theme:` block whose `name:` is material.
    static func usesMaterial(_ config: String) -> Bool {
        let pattern = try! NSRegularExpression(
            pattern: ##"^theme:[ \t]*(?:['"]?material['"]?[ \t]*(?:#.*)?$|(?:#.*)?\n(?:(?:[ \t]+.*|[ \t]*)\n)*?[ \t]+name:[ \t]*['"]?material['"]?)"##,
            options: .anchorsMatchLines)
        return pattern.firstMatch(in: config, range: NSRange(location: 0, length: (config as NSString).length)) != nil
    }

    static func docsDirectory(in config: String) -> String {
        let pattern = try! NSRegularExpression(pattern: ##"^docs_dir:[ \t]*['"]?([^'"#\n]+?)['"]?[ \t]*(?:#.*)?$"##, options: .anchorsMatchLines)
        let ns = config as NSString
        guard let m = pattern.firstMatch(in: config, range: NSRange(location: 0, length: ns.length)) else { return "docs" }
        return ns.substring(with: m.range(at: 1)).trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
    }
}
