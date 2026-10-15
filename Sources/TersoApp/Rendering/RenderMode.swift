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
