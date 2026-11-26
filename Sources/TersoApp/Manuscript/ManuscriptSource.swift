// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import TersoCore

struct ManuscriptLines {
    var starts = [0]
    init(_ text: String) {
        for (offset, character) in text.utf16.enumerated() where character == 10 { starts.append(offset + 1) }
    }
    func line(at offset: Int) -> Int {
        var first = 0, end = starts.count
        while first < end {
            let mid = (first + end) / 2
            if starts[mid] <= offset { first = mid + 1 } else { end = mid }
        }
        return max(first, 1)
    }
}

struct ManuscriptDependency {
    enum Kind { case source, bibliography, asset, package }
    let kind: Kind
    let name: String
    let range: NSRange
    let extensions: [String]
    func resolve(relativeTo base: URL, buffers: [URL: String]) -> URL? {
        guard !name.contains("\\"), !name.contains("#"), !name.contains("://"), !name.isEmpty else { return nil }
        let path = URL(fileURLWithPath: name, relativeTo: base).absoluteURL
        let candidates = [path] + (path.pathExtension.isEmpty ? extensions.map { path.appendingPathExtension($0) } : [])
        return candidates.map(\.manuscriptURL).first { url in
            if buffers[url] != nil { return true }
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue
        }
    }
}

struct ManuscriptSource {
    let source: DocumentSnapshot
    let clean: String
    let markdown: Bool
    let url: URL
    let lines: ManuscriptLines
    var dependencies: [ManuscriptDependency] = []
    var graphicsPaths: [String] = []
    private static let graphicsPath = regex(#"\\graphicspath\s*\{((?:\s*\{[^{}]*\}\s*)+)\}"#)
    private static let directory = regex(#"\{([^{}]+)\}"#)
    private static let bareInput = regex(#"(?<!\\)\\input[ \t]+([^\s{}%\\]+)"#)
    private static func regex(_ pattern: String) -> NSRegularExpression { try! NSRegularExpression(pattern: pattern) }
    private static let dependency = regex(#"(?<!\\)\\(input|include|subfile|bibliography|addbibresource|includegraphics|usepackage|RequirePackage|documentclass|bibliographystyle)\*?(?:\s*\[[^\]]*\])*\s*\{([^{}]+)\}"#)
    private static let front = regex(#"\A---[ \t]*\r?\n[\s\S]*?\r?\n(?:---|\.\.\.)[ \t]*(?:\r?\n|\z)"#)
    private static let yaml = regex(#"(?m)^bibliography:[ \t]*([^\r\n]*)(?:\r?\n((?:[ \t]*-[ \t]+[^\r\n]+(?:\r?\n|\z))+))?"#)
    private static let yamlItem = regex(#"(?:(?m:^[ \t]*-[ \t]+)|^|[,\[])\s*[\"']?([^\"',\[\]\r\n]+?\.bib)[\"']?\s*(?=[,\]\r\n]|$)"#)
    private static let image = regex(#"!\[[^\]\n]*\]\((?:<([^>]+)>|([^\s)]+))[^)\n]*\)"#)
    private static let mathComment = regex(#"(?<!\\)%[^\r\n]*"#)
    init(source: String, url: URL) {
        self.url = url
        lines = ManuscriptLines(source)
        let snapshot = DocumentSnapshot(revision: .init(0), text: source, fileName: url.lastPathComponent)
        self.source = snapshot
        markdown = snapshot.format == .markdown
        let ns = source as NSString, all = NSRange(location: 0, length: ns.length)
        let syntax = ScientificSyntax(snapshot)
        var skipped = syntax.regions.filter { [.comment, .code, .linkDestination].contains($0.kind) }.map(\.range.nsRange)
        if !markdown {
            skipped += LaTeXSyntax.literalEnvironments(in: source).filter { LaTeXSyntax.codeEnvironments.contains($0.name) || $0.name == "comment" }.map(\.range)
            skipped += Self.mathComment.matches(in: source, range: all).map(\.range)
        }
        if markdown, let front = Self.front.firstMatch(in: source, range: all) {
            skipped.append(front.range)
            if let bib = Self.yaml.firstMatch(in: source, range: front.range) {
                for group in [1, 2] where bib.range(at: group).location != NSNotFound {
                    let part = ns.substring(with: bib.range(at: group))
                    let scope = NSRange(location: 0, length: part.utf16.count)
                    for entry in Self.yamlItem.matches(in: part, range: scope) {
                        let r = entry.range(at: 1)
                        let actual = NSRange(location: r.location + bib.range(at: group).location, length: r.length)
                        let name = ns.substring(with: actual).trimmingCharacters(in: .whitespaces)
                        dependencies.append(.init(kind: .bibliography, name: name, range: actual, extensions: ["bib"]))
                    }
                }
            }
        }
        var units = Array(source.utf16)
        for r in skipped {
            for offset in r.location..<r.upperBound where units[offset] != 10 && units[offset] != 13 { units[offset] = 32 }
        }
        clean = String(decoding: units, as: UTF16.self)
        for group in Self.graphicsPath.matches(in: clean, range: all) {
            graphicsPaths += Self.directory.matches(in: clean, range: group.range(at: 1)).map { ns.substring(with: $0.range(at: 1)) }
        }
        for input in Self.bareInput.matches(in: clean, range: all) {
            dependencies.append(.init(kind: .source, name: ns.substring(with: input.range(at: 1)), range: input.range(at: 1), extensions: ["tex"]))
        }
        for m in Self.dependency.matches(in: clean, range: all) {
            let name = ns.substring(with: m.range(at: 1))
            let kind: ManuscriptDependency.Kind
            let ext: [String]
            switch name {
            case "input", "include", "subfile": kind = .source; ext = ["tex"]
            case "bibliography", "addbibresource": kind = .bibliography; ext = ["bib"]
            case "documentclass": kind = .package; ext = ["cls"]
            case "usepackage", "RequirePackage": kind = .package; ext = ["sty"]
            case "bibliographystyle": kind = .package; ext = ["bst"]
            default: kind = .asset; ext = ["pdf", "png", "jpg", "jpeg", "eps"]
            }
            for component in ns.substring(with: m.range(at: 2)).components(separatedBy: ",") {
                dependencies.append(.init(kind: kind, name: component.trimmingCharacters(in: .whitespacesAndNewlines), range: m.range(at: 2), extensions: ext))
            }
        }
        if markdown {
            let protected = skipped.sorted { $0.location < $1.location }
            for img in Self.image.matches(in: source, range: all) where !protected.contains(where: { NSLocationInRange(img.range.location, $0) }) {
                let r = img.range(at: img.range(at: 1).location != NSNotFound ? 1 : 2)
                let name = ns.substring(with: r)
                if !name.contains("://") { dependencies.append(.init(kind: .asset, name: name, range: r, extensions: [])) }
            }
        }
    }
    func inlineBibliography(_ items: [ManuscriptReferenceToken]) -> [ManuscriptCitation] {
        let ns = source.text as NSString
        func prose(_ value: String) -> String {
            value.replacingOccurrences(of: "~", with: " ").filter { $0 != "{" && $0 != "}" }
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        return items.enumerated().map { i, item in
            let start = item.range.upperBound
            let end = i + 1 < items.count ? items[i + 1].range.location : ns.length
            let body = NSRange(location: start, length: max(0, end - start))
            let marker = ns.range(of: #"\end{thebibliography}"#, range: body)
            let stop = marker.location == NSNotFound ? end : marker.location
            let fields = ns.substring(with: NSRange(location: start, length: stop - start)).components(separatedBy: #"\newblock"#)
            return ManuscriptCitation(key: item.key, author: fields.count > 1 ? prose(fields[0]) : "",
                title: fields.count > 1 ? prose(fields[1]) : prose(fields[0]),
                location: location(item.keyRange.nsRange), entryRange: TextSpan(location: item.range.location, length: stop - item.range.location))
        }
    }

    func location(_ range: NSRange) -> ManuscriptLocation {
        .init(url: url, range: TextSpan(range), line: lines.line(at: range.location), anchor: TextAnchor(range: TextSpan(range), in: source))
    }
}
