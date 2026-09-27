// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Markdown extensions that both the analyser and the editor need to agree
/// on: metadata front matter and LaTeX math. Anything matched here is not
/// prose.
public enum MarkdownSyntax {
    static func re(_ p: String, _ o: NSRegularExpression.Options = []) -> NSRegularExpression {
        // Patterns are compile-time constants; a failure here is a programming error.
        try! NSRegularExpression(pattern: p, options: o)
    }

    /// YAML (`---` … `---` or `...`) or TOML (`+++` … `+++`) metadata at the
    /// very start of the file, as used by Jekyll, Hugo, Pandoc, Quarto, Obsidian.
    static let frontMatterRegex = re(#"\A(---|\+\+\+)[ \t]*\n(?:[\s\S]*?\n)?(?:\1|\.\.\.)[ \t]*(?:\n|\z)"#)

    /// Display math: `$$ … $$`, `\[ … \]` and `\begin{env} … \end{env}`.
    public static let displayMath = re(#"\$\$[\s\S]+?\$\$|\\\[[\s\S]+?\\\]|\\begin\{([A-Za-z]+\*?)\}[\s\S]*?\\end\{\1\}"#)

    /// Inline math: `\( … \)`, or `$ … $` following Pandoc's rule — the
    /// opening `$` is not followed by a space, the closing one is not preceded
    /// by a space nor followed by a digit — so "$5 and $10" stays prose.
    public static let inlineMath = re(#"\\\([^\n]+?\\\)|(?<![\\$])\$(?![\s$])(?:[^$\n\\]|\\.)+?(?<![\s\\])\$(?![$\p{N}])"#)

    /// The front-matter block including its trailing newline, if the text starts with one.
    public static func frontMatter(in text: String) -> NSRange? {
        let ns = text as NSString
        return frontMatterRegex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length))?.range
    }

    /// Display ranges first, then inline ranges that fall outside them.
    public static func mathRanges(in text: String, range: NSRange? = nil) -> [NSRange] {
        let r = range ?? NSRange(location: 0, length: (text as NSString).length)
        let display = displayMath.matches(in: text, range: r).map(\.range)
        let inline = inlineMath.matches(in: text, range: r).map(\.range)
            .filter { i in !display.contains { NSIntersectionRange($0, i).length > 0 } }
        return display + inline
    }
}
