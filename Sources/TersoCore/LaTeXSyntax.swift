// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// The markup a document is written in. Decides which structural rules the
/// analyser and the editor apply; the characters are the same either way.
public enum SourceFormat: Sendable, Hashable {
    case markdown, latex

    /// `.tex`/`.latex` by name; an unnamed document is LaTeX when it opens
    /// with `\documentclass`.
    public static func detect(text: String, fileName: String?) -> SourceFormat {
        if let fileName, let dot = fileName.lastIndex(of: ".") {
            let ext = fileName[fileName.index(after: dot)...].lowercased()
            if ext == "tex" || ext == "latex" { return .latex }
            if !ext.isEmpty && !ext.contains("/") { return .markdown }
        }
        // Look past leading whitespace without copying the whole text.
        guard let first = text.firstIndex(where: { !$0.isWhitespace }) else { return .markdown }
        return text[first...].hasPrefix("\\documentclass") ? .latex : .markdown
    }
}

public extension DocumentSnapshot {
    var format: SourceFormat { SourceFormat.detect(text: text, fileName: fileName) }
}

/// LaTeX structure that both the analyser and the editor need to agree on:
/// sectioning, the preamble, list items and environments that hold no prose.
/// Inline commands, math and comments come from `ScientificSyntax`.
public enum LaTeXSyntax {
    static func re(_ p: String, _ o: NSRegularExpression.Options = [.anchorsMatchLines]) -> NSRegularExpression {
        // Patterns are compile-time constants; a failure here is a programming error.
        try! NSRegularExpression(pattern: p, options: o)
    }

    /// Sectioning commands, outermost first.
    public static let sectionCommands = ["part", "chapter", "section", "subsection", "subsubsection", "paragraph", "subparagraph"]

    /// `\section*[short]{Title}`, allowing one level of nested braces in the title.
    public static let section = re(#"\\(part|chapter|section|subsection|subsubsection|paragraph|subparagraph)\*?[ \t]*(?:\[[^\]\n]*\])?[ \t]*\{((?:[^{}]|\{[^{}]*\})*)\}"#, [])

    /// `\item` or `\item[label]` at the start of a line, with following blanks.
    public static let item = re(#"^[ \t]*\\item\b(?:\[[^\]\n]*\])?[ \t]*"#)

    /// Environments whose body is data, code or drawing rather than prose.
    public static let literalEnvironments = [
        "tabular", "tabular*", "tabularx", "longtable", "array", "tikzpicture", "pgfpicture",
        "verbatim", "verbatim*", "Verbatim", "lstlisting", "minted", "comment",
        "thebibliography", "filecontents", "filecontents*",
    ]
    /// Code-like environments, counted as code blocks.
    public static let codeEnvironments: Set<String> = ["verbatim", "verbatim*", "Verbatim", "lstlisting", "minted"]

    static let literalEnvironment: NSRegularExpression = {
        let names = literalEnvironments.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        return re(#"\\begin\{("# + names + #")\}[\s\S]*?(?:\\end\{\1\}|\z)"#, [])
    }()

    static let beginDocument = re(#"\\begin\{document\}"#, [])
    static let endDocument = re(#"\\end\{document\}"#, [])

    /// Literal environments, whole, with the captured environment name.
    public static func literalEnvironments(in text: String, range: NSRange? = nil) -> [(range: NSRange, name: String)] {
        let ns = text as NSString
        let r = range ?? NSRange(location: 0, length: ns.length)
        return literalEnvironment.matches(in: text, range: r).map { ($0.range, ns.substring(with: $0.range(at: 1))) }
    }

    /// Everything up to and including `\begin{document}`, if the file has one.
    public static func preamble(in text: String) -> NSRange? {
        guard let m = beginDocument.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) else { return nil }
        return NSRange(location: 0, length: m.range.upperBound)
    }

    /// `\end{document}` and anything after it, which TeX never reads.
    public static func trailer(in text: String) -> NSRange? {
        let length = (text as NSString).length
        guard let m = endDocument.firstMatch(in: text, range: NSRange(location: 0, length: length)) else { return nil }
        return NSRange(location: m.range.location, length: length - m.range.location)
    }

    /// Outline levels for the sectioning commands a document uses, so an
    /// article's `\section` and a book's `\chapter` both start at level 1.
    public static func levels(for used: Set<String>) -> [String: Int] {
        let present = sectionCommands.filter(used.contains)
        return Dictionary(uniqueKeysWithValues: present.enumerated().map { ($1, min($0 + 1, 6)) })
    }

    static let titleMarkup = re(#"\\[A-Za-z]+\*?|[{}~]|\\(?=[^A-Za-z])"#, [])

    /// A heading title as a reader sees it: commands and braces dropped.
    public static func plainTitle(_ raw: String) -> String {
        let ns = raw as NSString
        let stripped = titleMarkup.stringByReplacingMatches(in: raw, range: NSRange(location: 0, length: ns.length), withTemplate: " ")
        return stripped.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
