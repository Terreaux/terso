// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import TersoCore
import TersoDocument

extension URL {
    var manuscriptURL: URL { standardizedFileURL.resolvingSymlinksInPath() }
}

struct ManuscriptLocation: Codable, Hashable, Sendable, Identifiable {
    let url: URL
    let range: TextSpan
    let line: Int
    var anchor: TextAnchor? = nil
    var id: Self { self }

    func resolved(in text: String) -> TextSpan? {
        guard let anchor else { return range.upperBound <= text.utf16.count ? range : nil }
        let snapshot = DocumentSnapshot(revision: .init(1), text: text)
        if let current = TextAnchor(range: range, in: snapshot), current == anchor { return range }
        switch AnchorResolver.resolve(anchor, revision: .init(0), in: snapshot) {
        case .exact(let current), .relocated(let current): return current
        case .stale: return nil
        }
    }
}

struct ManuscriptCitation: Hashable, Sendable, Identifiable {
    let key: String
    let author: String
    let title: String
    let location: ManuscriptLocation
    var entryRange: TextSpan? = nil
    var id: ManuscriptLocation { location }
}

struct ManuscriptFinding: Hashable, Sendable, Identifiable {
    let rule: String
    let title: String
    let detail: String
    let location: ManuscriptLocation
    var id: String { "\(rule)|\(location.url.path)|\(location.range.location)|\(title)" }
}

struct ManuscriptIndex: Sendable {
    let id = UUID()
    let root: URL
    private(set) var sources: [URL: String] = [:]
    private(set) var resources: Set<URL> = []
    private(set) var graphics: [ManuscriptLocation: URL] = [:]
    private(set) var bibliographySources: [URL: String] = [:]
    private(set) var bibliography: [ManuscriptCitation] = []
    private(set) var labels: [String: [ManuscriptLocation]] = [:]
    private(set) var references: [String: [ManuscriptLocation]] = [:]
    private(set) var citations: [String: [ManuscriptLocation]] = [:]
    private(set) var findings: [ManuscriptFinding] = []

    init(root: URL, linked: [URL] = [], buffers: [URL: String] = [:]) throws {
        self.root = root.manuscriptURL
        let directory = self.root.deletingLastPathComponent()
        var pending = [self.root]
        var visited = Set<URL>()
        var bibliographyURLs = Set(linked.filter { $0.pathExtension.lowercased() == "bib" }.map(\.manuscriptURL))
        var bibliographyDeclared = !bibliographyURLs.isEmpty
        var complete = true
        var graphicsDirectories: [URL] = []
        func read(_ url: URL) throws -> String {
            if let text = buffers[url] { return text }
            return try PlainTextCodec.decode(Data(contentsOf: url)).0
        }
        while let next = pending.popLast() {
            try Task.checkCancellation()
            guard visited.insert(next).inserted else { continue }
            let source = try read(next)
            sources[next] = source
            let scan = ManuscriptSource(source: source, url: next)
            let tokens = ManuscriptReferenceSyntax.tokens(in: scan.clean, markdown: scan.markdown)
            let items = tokens.filter { $0.kind == .bibitem }
            bibliography += scan.inlineBibliography(items)
            for token in tokens {
                let location = scan.location(token.keyRange.nsRange)
                switch token.kind {
                case .citation: citations[token.key, default: []].append(location)
                case .reference: references[token.key, default: []].append(location)
                case .label: labels[token.key, default: []].append(location)
                case .bibitem: break
                }
            }
            graphicsDirectories += scan.graphicsPaths.map { URL(fileURLWithPath: $0, isDirectory: true, relativeTo: directory).absoluteURL }
            for dependency in scan.dependencies {
                if dependency.kind == .bibliography { bibliographyDeclared = true }
                let name = dependency.name
                // Macro-generated paths belong to the typesetter. Reporting an unknown
                // dependency avoids declaring missing keys high-confidence in partial graphs.
                let base = scan.markdown ? next.deletingLastPathComponent() : directory
                let search = dependency.kind == .asset ? [base] + graphicsDirectories : [base]
                let match = search.lazy.compactMap { dependency.resolve(relativeTo: $0, buffers: buffers) }.first
                guard let target = match else {
                    if dependency.kind == .package { continue } // A system package is resolved by TeX.
                    if dependency.kind == .source || dependency.kind == .bibliography { complete = false }
                    findings.append(.init(rule: "dependency", title: "Inspect manuscript input: \(name)",
                        detail: "This literal file could not be resolved relative to \(base.lastPathComponent).",
                        location: scan.location(dependency.range)))
                    continue
                }
                switch dependency.kind {
                case .source: pending.append(target)
                case .bibliography: bibliographyURLs.insert(target)
                case .asset:
                    graphics[scan.location(dependency.range)] = target
                    resources.insert(target)
                case .package: resources.insert(target)
                }
            }
        }
        for url in bibliographyURLs.sorted(by: { $0.path < $1.path }) {
            try Task.checkCancellation()
            resources.insert(url)
            guard let text = try? read(url) else {
                complete = false
                findings.append(.init(rule: "dependency", title: "Unreadable bibliography: \(url.lastPathComponent)", detail: url.path,
                    location: .init(url: self.root, range: TextSpan(location: 0, length: 0), line: 1)))
                continue
            }
            bibliographySources[url] = text
            bibliography += BibTeXIndex.entries(text, at: url)
        }
        let entries = Dictionary(grouping: bibliography, by: \.key)
        func record(_ rule: String, _ title: String, _ detail: String, _ locations: [ManuscriptLocation]) -> [ManuscriptFinding] {
            locations.map { ManuscriptFinding(rule: rule, title: title, detail: detail, location: $0) }
        }
        for (key, matches) in labels {
            if matches.count > 1 { findings += record("duplicate", "Duplicate label: \(key)", "This label appears \(matches.count) times in the manuscript.", matches) }
            if complete, references[key] == nil { findings += record("unused", "Unreferenced label: \(key)", "No reference in the indexed manuscript uses this label.", matches) }
        }
        for (key, matches) in entries where matches.count > 1 {
            findings += record("duplicateCitation", "Duplicate bibliography key: \(key)", "This key occurs in multiple entries.", matches.map(\.location))
        }
        if complete {
            for (key, uses) in references where labels[key] == nil {
                findings += record("missing", "Broken reference: \(key)", "No matching label exists in the indexed manuscript.", uses)
            }
            if bibliographyDeclared || !entries.isEmpty {
                for (key, uses) in citations where entries[key] == nil {
                    findings += record("citation", "Missing bibliography key: \(key)", "No matching entry exists in the manuscript bibliography.", uses)
                }
            }
        }
        findings.sort { lhs, rhs in
            if (lhs.rule == "unused") != (rhs.rule == "unused") { return rhs.rule == "unused" }
            if lhs.location.url != rhs.location.url { return lhs.location.url.path < rhs.location.url.path }
            if lhs.location.range != rhs.location.range { return lhs.location.range < rhs.location.range }
            return lhs.title < rhs.title
        }
        bibliography.sort { lhs, rhs in
            if lhs.key != rhs.key { return lhs.key < rhs.key }
            if lhs.location.url != rhs.location.url { return lhs.location.url.path < rhs.location.url.path }
            return lhs.location.range < rhs.location.range
        }
    }
}
