// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Literal manuscript keys. Offsets refer to the original UTF-16 source.
public struct ManuscriptReferenceToken: Hashable, Sendable {
    public enum Kind: Sendable { case label, reference, citation, bibitem }
    public let kind: Kind
    public let command: String
    public let key: String
    public let range: TextSpan
    public let keyRange: TextSpan
}

public enum ManuscriptReferenceSyntax {
    private static let tex = try! NSRegularExpression(pattern: #"(?<!\\)\\(label|(?:auto|eq|c|page)?ref|cite[pt]?|citeal[pt]|(?:paren|text|auto|foot|super)cite|nocite|bibitem)\*?(?:\s*\[[^\]]*\])*\s*\{([^{}]+)\}"#, options: [.caseInsensitive])
    private static let key = try! NSRegularExpression(pattern: #"[^,\s]+"#)
    private static let pandoc = try! NSRegularExpression(pattern: #"(?<![\w@.\\])@([\w](?:[\w:.#$%&+?<>~/\-]*[\w])?)"#)
    private static let pandocLabel = try! NSRegularExpression(pattern: #"\{#([\w:.-]+)(?:\s[^}\n]*)?\}"#)
    private static let prefixes = ["fig:", "tbl:", "tab:", "eq:", "sec:", "lst:",
                                   "fig-", "tbl-", "eq-", "sec-", "lst-", "thm-", "lem-", "cor-", "def-", "prp-", "exm-", "exr-", "alg-"]
    public static func isCitationCommand(_ command: String) -> Bool { command.lowercased().contains("cite") }

    /// Pass source with literal regions blanked in-place, preserving newlines and offsets.
    public static func tokens(in clean: String, markdown: Bool) -> [ManuscriptReferenceToken] {
        let ns = clean as NSString
        let extent = NSRange(location: 0, length: ns.length)
        var tokens: [ManuscriptReferenceToken] = []
        for match in tex.matches(in: clean, range: extent) {
            let command = ns.substring(with: match.range(at: 1)).lowercased()
            let kind: ManuscriptReferenceToken.Kind = command == "bibitem" ? .bibitem : command == "label" ? .label : isCitationCommand(command) ? .citation : .reference
            for k in key.matches(in: clean, range: match.range(at: 2)) {
                let value = ns.substring(with: k.range)
                guard value != "*", !value.contains("\\") else { continue }
                tokens.append(.init(kind: kind, command: command, key: value, range: TextSpan(match.range), keyRange: TextSpan(k.range)))
            }
        }
        if markdown {
            for match in pandocLabel.matches(in: clean, range: extent) {
                let r = match.range(at: 1)
                tokens.append(.init(kind: .label, command: "label", key: ns.substring(with: r), range: TextSpan(match.range), keyRange: TextSpan(r)))
            }
            for match in pandoc.matches(in: clean, range: extent) {
                let r = match.range(at: 1), value = ns.substring(with: r)
                let prefix = prefixes.first { value.lowercased().hasPrefix($0) }
                let key = prefix.map { $0 + value.dropFirst($0.count) } ?? value
                tokens.append(.init(kind: prefix == nil ? .citation : .reference, command: prefix == nil ? "cite" : "ref", key: key, range: TextSpan(match.range), keyRange: TextSpan(r)))
            }
        }
        return tokens.sorted { $0.keyRange < $1.keyRange }
    }
}
