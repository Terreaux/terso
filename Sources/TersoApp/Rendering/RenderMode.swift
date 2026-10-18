// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import TersoCore

enum RenderMode: String, CaseIterable, Identifiable {
    case source = "Source", mixed = "Mixed", preview = "Preview"
    var id: String { rawValue }

    static func isLaTeX(source: String, fileURL: URL?) -> Bool {
        SourceFormat.detect(text: source, fileName: fileURL?.lastPathComponent) == .latex
    }
}

/// A group of constructs Mixed can draw in place of its source, as Obsidian's
/// Live Preview does. Each shows its source again on the line being edited.
/// The same names cover both formats: heading markers are `#` in Markdown and
/// `\section{…}` in TeX.
enum MixedElement: String, CaseIterable, Identifiable {
    case math, images, links, headings, emphasis, code, blocks, admonitions, tables, footnotes, citations, comments, critic
    var id: String { rawValue }
    var title: String {
        switch self {
        case .math: "Math"
        case .images: "Images"
        case .links: "Link targets"
        case .headings: "Heading markers"
        case .emphasis: "Emphasis markers"
        case .code: "Code markers"
        case .blocks: "Lists, tasks, quotes and rules"
        case .admonitions: "Admonitions"
        case .tables: "Tables"
        case .footnotes: "Footnotes"
        case .citations: "Citations and cross-references"
        case .comments: "Comments and highlights"
        case .critic: "Suggested edits (CriticMarkup)"
        }
    }
    static let defaults: [MixedElement] = allCases

    static let addedLater: [MixedElement] = [.code, .blocks, .tables, .footnotes, .citations, .comments, .admonitions, .critic]

    /// Extension syntax (Pandoc, Obsidian) is offered only when the document uses it.
    @MainActor static func available(latex: Bool, text: String) -> [MixedElement] {
        if latex { return [.math, .headings, .emphasis] + LaTeXMixedPresentation.elements(in: text) }
        let all = NSRange(location: 0, length: (text as NSString).length)
        func uses(_ pattern: NSRegularExpression) -> Bool { pattern.firstMatch(in: text, range: all) != nil }
        return allCases.filter { element in
            switch element {
            case .footnotes: uses(MarkdownStyler.footnote)
            case .citations: uses(PandocSyntax.citation) || uses(PandocSyntax.label)
            case .comments: uses(MarkdownStyler.highlight) || uses(MarkdownStyler.comment)
            case .admonitions: uses(MarkdownStyler.admonition)
            case .critic: MarkdownStyler.critic.contains { uses($0) }
            default: true
            }
        }
    }
}

/// Parsing and presentation use the same UTF-16 source ranges as analysis.
enum MathPresentation {
    static func regions(in text: String) -> [ScientificRegion] {
        let frontMatter = MarkdownSyntax.frontMatter(in: text)
        return ScientificSyntax(DocumentSnapshot(revision: DocumentRevision(0), text: text)).regions.filter {
            ($0.kind == .inlineMath || $0.kind == .displayMath)
                && (frontMatter == nil || NSIntersectionRange(frontMatter!, $0.range.nsRange).length == 0)
                && isClosed($0)
        }
    }

    static func isClosed(_ region: ScientificRegion) -> Bool {
        guard region.contentRange.upperBound < region.range.upperBound else { return false }
        let raw = region.rawText
        if raw.hasPrefix("$$") { return raw.count > 4 && raw.hasSuffix("$$") }
        if raw.hasPrefix("$") { return raw.count > 2 && raw.hasSuffix("$") }
        if raw.hasPrefix("\\(") { return raw.hasSuffix("\\)") }
        if raw.hasPrefix("\\[") { return raw.hasSuffix("\\]") }
        return raw.contains("\\end{")
    }

    static func showsSource(_ range: NSRange, selection: NSRange, text: String) -> Bool {
        let ns = text as NSString
        guard selection.location != NSNotFound, selection.location <= ns.length else { return false }
        let selected = NSRange(location: selection.location, length: min(selection.length, ns.length - selection.location))
        // Keep a multiline wrapper open while any of its lines is being edited.
        let lines = ns.lineRange(for: selected)
        return NSIntersectionRange(lines, range).length > 0
            || (selected.length == 0 && selected.location >= range.location && selected.location < range.upperBound)
    }

    /// Common manuscript macros. Balanced groups preserve nested TeX; optional
    /// default arguments and arbitrary TeX execution are deliberately not inferred.
    static func macros(in source: String) -> [String: String] {
        let code = ScientificSyntax(DocumentSnapshot(revision: DocumentRevision(0), text: source)).regions
            .filter { $0.kind == .code || $0.kind == .comment }.map(\.range.nsRange)
        let pattern = try! NSRegularExpression(pattern: #"\\(?:newcommand|renewcommand|providecommand)\*?\s*\{(\\[A-Za-z]+)\}\s*(?:\[([0-9])\])?\s*\{"#)
        let ns = source as NSString
        var result: [String: String] = [:]
        for match in pattern.matches(in: source, range: NSRange(location: 0, length: ns.length)).prefix(128) {
            guard !code.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { continue }
            let start = match.range.upperBound
            var end = start, depth = 1
            while end < ns.length && end - start < 8192 && depth > 0 {
                let char = ns.character(at: end)
                if char == 92 { end += 2; continue }
                if char == 123 { depth += 1 }
                if char == 125 { depth -= 1 }
                if depth > 0 { end += 1 }
            }
            guard depth == 0 else { continue }
            result[ns.substring(with: match.range(at: 1))] = ns.substring(with: NSRange(location: start, length: end - start))
        }
        return result
    }

    static func json(_ value: Any) -> String {
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
        return String(decoding: data, as: UTF8.self).replacingOccurrences(of: "<", with: "\\u003c")
    }
}

/// Links display their label (or wiki alias), revealing source on the editing line.
@MainActor enum LinkPresentation {
    static func hiddenSyntax(in text: String, selection: NSRange) -> [NSRange] {
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)
        let syntax = ScientificSyntax(DocumentSnapshot(revision: DocumentRevision(0), text: text))
        let protected = syntax.regions.filter { [.inlineMath, .displayMath, .code].contains($0.kind) }.map(\.range.nsRange)
            + [MarkdownSyntax.frontMatter(in: text)].compactMap { $0 }
        var hidden: [NSRange] = []
        for pattern in [MarkdownStyler.link, MarkdownStyler.wikiLink] {
            for match in pattern.matches(in: text, range: all) {
                guard !MathPresentation.showsSource(match.range, selection: selection, text: text),
                      !protected.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { continue }
                // Embedded images and escaped brackets remain literal source.
                if match.range.location > 0 {
                    let previous = ns.character(at: match.range.location - 1)
                    if previous == 33 || previous == 92 || previous == 91 { continue }
                }
                if pattern === MarkdownStyler.wikiLink {
                    let label = match.range(at: match.range(at: 2).location == NSNotFound ? 1 : 2)
                    hidden.append(NSRange(location: match.range.location, length: label.location - match.range.location))
                    hidden.append(NSRange(location: label.upperBound, length: match.range.upperBound - label.upperBound))
                } else {
                    hidden += [match.range(at: 1), match.range(at: 3)]
                }
            }
        }
        return hidden
    }
}

/// Markers that recede entirely, revealing on the editing line: headings,
/// emphasis, code, highlights, comments, CriticMarkup braces, citation `@`s
/// and cross-reference labels. Footnotes are drawn by MixedPresentation.
@MainActor enum MarkerPresentation {
    static func hiddenSyntax(in text: String, selection: NSRange, latex: Bool, elements: Set<MixedElement>) -> [NSRange] {
        let hiding: Set<MixedElement> = [.headings, .emphasis, .code, .comments, .citations, .critic, .blocks]
        guard !elements.isDisjoint(with: hiding) else { return [] }
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)
        let regions = ScientificSyntax(DocumentSnapshot(revision: DocumentRevision(0), text: text)).regions
        func kinds(_ k: [ScientificRegionKind]) -> [NSRange] { regions.filter { k.contains($0.kind) }.map(\.range.nsRange) }
        let frontMatter = [MarkdownSyntax.frontMatter(in: text)].compactMap { $0 }
        let fences = latex ? LaTeXSyntax.literalEnvironments(in: text).map(\.range) : MarkdownStyler.fence.matches(in: text, range: all).map(\.range)
        let math = kinds([.inlineMath, .displayMath])
        let comments = latex ? [] : MarkdownStyler.comment.matches(in: text, range: all).map(\.range)
        // Prose markers stay literal inside code, math, metadata and comments.
        // TeX `%` comments come from the scientific syntax; Markdown has its own.
        let prose = kinds(latex ? [.code, .comment] : [.code]) + frontMatter + fences + math + comments
        var hidden: [NSRange] = []
        func revealed(_ range: NSRange) -> Bool { MathPresentation.showsSource(range, selection: selection, text: text) }
        func clear(_ range: NSRange, of protected: [NSRange]) -> Bool {
            !protected.contains { NSIntersectionRange($0, range).length > 0 }
        }
        /// Hides the text before `content` and the `closing` characters after it.
        func wrap(_ match: NSTextCheckingResult, content: NSRange, closing: Int, protected: [NSRange]) {
            guard !revealed(match.range), clear(match.range, of: protected) else { return }
            hidden.append(NSRange(location: match.range.location, length: content.location - match.range.location))
            if closing > 0 { hidden.append(NSRange(location: match.range.upperBound - closing, length: closing)) }
        }
        func each(_ pattern: NSRegularExpression, _ body: (NSTextCheckingResult) -> Void) {
            pattern.enumerateMatches(in: text, range: all) { m, _, _ in if let m { body(m) } }
        }
        if latex {
            if elements.contains(.blocks) {
                hidden += LaTeXMixedPresentation.hiddenPreamble(in: text, selection: selection,
                                                               quiet: kinds([.code, .comment]) + fences)
            }
            if elements.contains(.headings) {
                each(LaTeXSyntax.section) { wrap($0, content: $0.range(at: 2), closing: 1, protected: prose) }
            }
            if elements.contains(.emphasis) {
                each(MarkdownStyler.texEmphasis) { wrap($0, content: $0.range(at: 2), closing: 1, protected: prose) }
                each(MarkdownStyler.texBold) { wrap($0, content: $0.range(at: 1), closing: 1, protected: prose) }
                each(MarkdownStyler.texFace) { wrap($0, content: $0.range(at: 2), closing: 1, protected: prose) }
            }
            if elements.contains(.citations) {
                each(LaTeXMixedPresentation.label) { if !revealed($0.range), clear($0.range, of: prose) { hidden.append($0.range) } }
            }
            return hidden.filter { $0.length > 0 }
        }
        if elements.contains(.headings) {
            each(MarkdownStyler.heading) { wrap($0, content: $0.range(at: 3), closing: 0, protected: prose) }
        }
        // CriticMarkup braces are their own syntax, never strikethrough or highlight.
        let critics = MarkdownStyler.critic.flatMap { $0.matches(in: text, range: all).map(\.range) }
        if elements.contains(.emphasis) {
            each(MarkdownStyler.underline) { wrap($0, content: $0.range(at: 2), closing: $0.range(at: 3).length, protected: prose) }
            for pattern in [MarkdownStyler.bold, MarkdownStyler.italic, MarkdownStyler.strike] {
                each(pattern) { m in
                    guard pattern !== MarkdownStyler.strike || clear(m.range, of: critics) else { return }
                    wrap(m, content: m.range(at: 2), closing: m.range(at: 1).length, protected: prose)
                }
            }
        }
        if elements.contains(.code) {
            // A code span is itself code, so only blocks and math protect it.
            each(MarkdownStyler.code) { m in
                wrap(m, content: m.range(at: 2), closing: m.range(at: 1).length,
                     protected: frontMatter + fences + math + comments)
            }
        }
        if elements.contains(.comments) {
            each(MarkdownStyler.highlight) { wrap($0, content: $0.range(at: 2), closing: 2, protected: prose + critics) }
            // A comment disappears line by line, so its lines stay apart.
            for comment in comments where !revealed(comment) && clear(comment, of: kinds([.code]) + fences + frontMatter) {
                var location = comment.location
                while location < comment.upperBound {
                    let line = ns.lineRange(for: NSRange(location: location, length: 0))
                    var end = min(line.upperBound, comment.upperBound)
                    while end > location, [10, 13].contains(ns.character(at: end - 1)) { end -= 1 }
                    hidden.append(NSRange(location: location, length: end - location))
                    location = line.upperBound
                }
            }
        }
        if elements.contains(.critic) {
            // The braces go; a substitution also loses its `~>`.
            for pattern in MarkdownStyler.critic {
                each(pattern) { m in
                    wrap(m, content: m.range(at: 1), closing: 3, protected: prose)
                    if pattern === MarkdownStyler.criticSubstitute, !revealed(m.range), clear(m.range, of: prose) {
                        hidden.append(NSRange(location: m.range(at: 1).upperBound, length: 2))
                    }
                }
            }
        }
        if elements.contains(.citations) {
            let numbers = PandocSyntax.numbers(in: text)
            each(PandocSyntax.citation) { m in
                // Cross-references with a known target are drawn as "fig. 2";
                // citations lose their `@` and keep the key.
                guard numbers[PandocSyntax.target(of: m, in: ns)] == nil else { return }
                wrap(m, content: m.range(at: 2), closing: 0, protected: prose)
            }
            // `[@fig:a; @fig:b]` reads as pandoc-crossref prints it, without brackets.
            each(PandocSyntax.group) { m in
                let keys = PandocSyntax.citation.matches(in: text, range: m.range(at: 1))
                guard !keys.isEmpty, keys.allSatisfy({ numbers[PandocSyntax.target(of: $0, in: ns)] != nil }) else { return }
                wrap(m, content: m.range(at: 1), closing: 1, protected: prose)
            }
            each(PandocSyntax.label) { m in
                guard !revealed(m.range), clear(m.range, of: prose) else { return }
                hidden.append(m.range)
            }
        }
        return hidden.filter { $0.length > 0 }
    }
}
