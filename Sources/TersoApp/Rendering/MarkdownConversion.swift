// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import TersoCore

/// Rewrites syntax a flavour leaves as typed into the platform's own form,
/// where one says the same thing: admonitions and callouts into each other,
/// wiki links into links, `%%` comments into HTML comments, highlights and
/// strikethrough into HTML for Python-Markdown. Footnotes, math, tables and
/// CriticMarkup have no equivalent and are left alone. Code, math and
/// metadata are never touched.
@MainActor
enum MarkdownConversion {
    struct Edit: Equatable {
        let range: NSRange
        let replacement: String
        let feature: MarkdownFeature
    }

    static func edits(in text: String, to flavour: MarkdownDialect) -> [Edit] {
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)
        let features = flavour.features
        let fences = MarkdownStyler.fence.matches(in: text, range: all).map(\.range)
        let literal = fences + [MarkdownSyntax.frontMatter(in: text)].compactMap { $0 }
            + MarkdownStyler.code.matches(in: text, range: all).map(\.range)
            + MathPresentation.regions(in: text).map(\.range.nsRange)
        let critics = MarkdownStyler.critic.flatMap { $0.matches(in: text, range: all).map(\.range) }
        func clear(_ range: NSRange, of protected: [NSRange]) -> Bool {
            !protected.contains { NSIntersectionRange($0, range).length > 0 }
        }
        // Terso never normalises line endings; new lines match the file's.
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        var edits: [Edit] = []

        if features.contains(.alerts) && !features.contains(.admonitions) {
            for block in admonitions(in: ns, fences: fences) where clear(block.range, of: literal) {
                edits.append(Edit(range: block.range, replacement: callout(block, for: flavour, newline: newline), feature: .admonitions))
            }
        }
        for block in callouts(in: ns, fences: fences) where clear(block.range, of: literal) {
            if features.contains(.admonitions) && !features.contains(.alerts) {
                edits.append(Edit(range: block.range, replacement: admonition(block, newline: newline), feature: .alerts))
            } else if features.contains(.alerts), flavour.alertStyle != "obsidian", !supports(block, flavour) {
                edits.append(Edit(range: block.range, replacement: callout(block, for: flavour, newline: newline), feature: .alerts))
            }
        }
        if !features.contains(.wikiLinks) {
            for match in MarkdownStyler.wikiLink.matches(in: text, range: all) {
                let embed = match.range.location > 0 && ns.character(at: match.range.location - 1) == 33
                let range = embed ? NSRange(location: match.range.location - 1, length: match.range.length + 1) : match.range
                guard clear(range, of: literal),
                      let link = link(target: ns.substring(with: match.range(at: 1)),
                                      alias: match.range(at: 2).location == NSNotFound ? nil : ns.substring(with: match.range(at: 2)),
                                      embed: embed) else { continue }
                edits.append(Edit(range: range, replacement: link, feature: .wikiLinks))
            }
        }
        if !features.contains(.comments) {
            for match in percentComment.matches(in: text, range: all) where clear(match.range, of: literal) {
                let inner = ns.substring(with: NSRange(location: match.range.location + 2, length: match.range.length - 4))
                // `--` can't sit inside an HTML comment.
                guard !inner.contains("--") else { continue }
                edits.append(Edit(range: match.range, replacement: "<!--\(inner)-->", feature: .comments))
            }
        }
        // Python-Markdown and CommonMark pass inline HTML through.
        if flavour.flavour.readsSiteConfig || flavour.flavour == .commonMark {
            for (pattern, tag, feature) in [(MarkdownStyler.highlight, "mark", MarkdownFeature.highlights),
                                            (MarkdownStyler.strike, "del", .strikethrough)] where !features.contains(feature) {
                for match in pattern.matches(in: text, range: all) where clear(match.range, of: literal + critics) {
                    edits.append(Edit(range: match.range, replacement: "<\(tag)>\(ns.substring(with: match.range(at: 2)))</\(tag)>", feature: feature))
                }
            }
        }
        // One edit per stretch of text: the first found wins an overlap.
        var kept: [Edit] = []
        for edit in edits.sorted(by: { $0.range.location < $1.range.location })
        where kept.last.map({ $0.range.upperBound <= edit.range.location }) ?? true {
            kept.append(edit)
        }
        return kept
    }

    /// The span the edits cover and what replaces it, so the conversion is one undoable change.
    static func replacement(for edits: [Edit], in text: String) -> (range: NSRange, text: String)? {
        guard let first = edits.first, let last = edits.last else { return nil }
        let ns = text as NSString
        let span = NSRange(location: first.range.location, length: last.range.upperBound - first.range.location)
        var result = "", cursor = span.location
        for edit in edits {
            result += ns.substring(with: NSRange(location: cursor, length: edit.range.location - cursor)) + edit.replacement
            cursor = edit.range.upperBound
        }
        return (span, result)
    }

    /// "2 admonitions as callouts and 1 wiki link as a link".
    static func summary(of edits: [Edit], for flavour: MarkdownDialect) -> String {
        var counts: [MarkdownFeature: Int] = [:]
        for edit in edits { counts[edit.feature, default: 0] += 1 }
        let parts = MarkdownFeature.allCases.compactMap { feature -> String? in
            guard let n = counts[feature] else { return nil }
            func noun(_ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }
            switch feature {
            case .admonitions: return noun("admonition", "admonitions") + " as callouts"
            case .alerts: return flavour.features.contains(.admonitions)
                ? noun("callout", "callouts") + " as admonitions"
                : noun("callout", "callouts") + " in \(flavour.title)'s form"
            case .wikiLinks: return noun("wiki link", "wiki links") + (n == 1 ? " as a link" : " as links")
            case .comments: return noun("comment", "comments") + " as HTML comments"
            case .highlights: return noun("highlight", "highlights") + " as <mark>"
            case .strikethrough: return noun("strikethrough", "strikethroughs") + " as <del>"
            default: return nil
            }
        }
        return ListFormatter.localizedString(byJoining: parts)
    }

    // MARK: Blocks

    struct Block {
        var range: NSRange
        var kind: String
        /// `!!!`/`???`/`???+`, or `""`/`-`/`+` for a callout.
        var fold: String
        var title: String?
        var body: [String]
    }

    static let admonitionHead = MarkdownStyler.re(#"^(!!!|\?\?\?\+?)[ \t]+([\w-]+)(?:[ \t]+[\w-]+)*(?:[ \t]+"([^"\n]*)")?[ \t]*$"#)
    static let calloutHead = MarkdownStyler.re(#"^ {0,3}>[ \t]*\[!([\w-]+)\]([+-]?)[ \t]*(.*)$"#)
    static let percentComment = MarkdownStyler.re(#"%%[\s\S]*?%%"#, [])

    /// `!!! kind "Title"` and the indented lines under it, blank lines
    /// inside included and trailing ones left out.
    static func admonitions(in ns: NSString, fences: [NSRange]) -> [Block] {
        admonitionHead.matches(in: ns as String, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            guard !fences.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) else { return nil }
            var body: [String] = [], blanks = 0, end = m.range.upperBound
            for (line, content) in lines(after: m.range, in: ns) {
                if content.trimmingCharacters(in: .whitespaces).isEmpty { blanks += 1; continue }
                guard content.hasPrefix("    ") || content.hasPrefix("\t") else { break }
                body += Array(repeating: "", count: blanks) + [content.hasPrefix("\t") ? String(content.dropFirst()) : String(content.dropFirst(4))]
                blanks = 0
                end = line.location + (content as NSString).length
            }
            let title = m.range(at: 3).location == NSNotFound ? nil : ns.substring(with: m.range(at: 3))
            return Block(range: NSRange(location: m.range.location, length: end - m.range.location),
                         kind: ns.substring(with: m.range(at: 2)).lowercased(), fold: ns.substring(with: m.range(at: 1)),
                         title: title, body: body)
        }
    }

    /// `> [!kind]± Title` and the quoted lines under it.
    static func callouts(in ns: NSString, fences: [NSRange]) -> [Block] {
        calloutHead.matches(in: ns as String, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            guard !fences.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) else { return nil }
            var body: [String] = [], end = m.range.upperBound
            for (line, content) in lines(after: m.range, in: ns) {
                guard let quote = content.range(of: #"^ {0,3}> ?"#, options: .regularExpression) else { break }
                body.append(String(content[quote.upperBound...]))
                end = line.location + (content as NSString).length
            }
            let title = ns.substring(with: m.range(at: 3)).trimmingCharacters(in: .whitespaces)
            return Block(range: NSRange(location: m.range.location, length: end - m.range.location),
                         kind: ns.substring(with: m.range(at: 1)).lowercased(), fold: ns.substring(with: m.range(at: 2)),
                         title: title.isEmpty ? nil : title, body: body)
        }
    }

    /// The lines after the one holding `range`, each without its line ending.
    private static func lines(after range: NSRange, in ns: NSString) -> [(range: NSRange, content: String)] {
        var result: [(NSRange, String)] = []
        var location = NSMaxRange(ns.lineRange(for: NSRange(location: range.location, length: 0)))
        while location < ns.length {
            let line = ns.lineRange(for: NSRange(location: location, length: 0))
            result.append((line, ns.substring(with: line).trimmingCharacters(in: .newlines)))
            location = NSMaxRange(line)
        }
        return result
    }

    /// GitHub and GitLab know five kinds of alert.
    static func alertKind(_ kind: String) -> String {
        switch kind {
        case "tip", "hint", "success", "check", "done": "TIP"
        case "important": "IMPORTANT"
        case "warning", "attention": "WARNING"
        case "caution", "danger", "error", "failure", "fail", "missing", "bug": "CAUTION"
        default: "NOTE"
        }
    }

    static func supports(_ block: Block, _ flavour: MarkdownDialect) -> Bool {
        if flavour.alertStyle == "obsidian" { return true }
        guard ["note", "tip", "important", "warning", "caution"].contains(block.kind), block.fold.isEmpty else { return false }
        return flavour.alertStyle != "github" || block.title == nil
    }

    /// The block as the flavour's callout: GitHub has no title, so one becomes a bold first line.
    static func callout(_ block: Block, for flavour: MarkdownDialect, newline: String = "\n") -> String {
        let obsidian = flavour.alertStyle == "obsidian"
        let kind = obsidian ? block.kind : alertKind(block.kind)
        let fold = obsidian ? (block.fold == "???" || block.fold == "-" ? "-" : block.fold == "???+" || block.fold == "+" ? "+" : "") : ""
        let title = block.title.flatMap { $0.isEmpty ? nil : $0 }
        let github = flavour.alertStyle == "github"
        var lines = ["> [!\(kind)]\(fold)" + (title != nil && !github ? " \(title!)" : "")]
        if let title, github { lines.append("> **\(title)**") }
        lines += block.body.map { $0.isEmpty ? ">" : "> \($0)" }
        return lines.joined(separator: newline)
    }

    /// The block as a Material admonition; GitHub's red "caution" is Material's "danger".
    static func admonition(_ block: Block, newline: String = "\n") -> String {
        let marker = block.fold == "-" ? "???" : block.fold == "+" ? "???+" : "!!!"
        let kind = block.kind == "caution" ? "danger" : block.kind
        let title = block.title.map { " \"\($0.replacingOccurrences(of: "\"", with: "'"))\"" } ?? ""
        return (["\(marker) \(kind)\(title)"] + block.body.map { $0.isEmpty ? "" : "    \($0)" }).joined(separator: newline)
    }

    /// `[[Note#Part|alias]]` as `[alias](Note.md#part)`; an image embed as an image.
    /// Embedding another note has no Markdown form.
    static func link(target raw: String, alias: String?, embed: Bool) -> String? {
        let target = raw.trimmingCharacters(in: .whitespaces)
        let parts = target.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        var path = parts[0].trimmingCharacters(in: .whitespaces)
        let heading = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : nil
        let image = ["png", "jpg", "jpeg", "gif", "webp", "svg"].contains((path as NSString).pathExtension.lowercased())
        if embed && !image { return nil }
        if !path.isEmpty && (path as NSString).pathExtension.isEmpty { path += ".md" }
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "()"))) ?? path
        let anchor = heading.map { "#" + slug($0) } ?? ""
        let label = alias?.trimmingCharacters(in: .whitespaces) ?? (heading.map { path.isEmpty ? $0 : "\(parts[0].trimmingCharacters(in: .whitespaces)) › \($0)" } ?? parts[0].trimmingCharacters(in: .whitespaces))
        return embed ? "![\(alias ?? "")](\(encoded))" : "[\(label)](\(encoded)\(anchor))"
    }

    /// GitHub's heading anchors: lower case, punctuation dropped, spaces as hyphens.
    static func slug(_ heading: String) -> String {
        String(heading.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " || $0 == "-" || $0 == "_" })
            .replacingOccurrences(of: " ", with: "-")
    }
}

extension WorkspaceModel {
    /// Rewrites what `flavour` would leave as typed into its own form, as
    /// one undoable edit made against the editor's current text.
    func convertMarkdown(to flavour: MarkdownDialect) {
        guard let editor else { return }
        let text = editor.currentSnapshot.text
        guard let change = MarkdownConversion.replacement(for: MarkdownConversion.edits(in: text, to: flavour), in: text) else { return }
        editor.replace(TextSpan(location: change.range.location, length: change.range.length), with: change.text,
                       actionName: "Convert for \(flavour.title)")
    }
}
