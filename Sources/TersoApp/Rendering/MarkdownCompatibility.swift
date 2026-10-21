// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import TersoCore

/// Where a document uses syntax its flavour's platform won't render, so
/// Mixed can mark it the way Preview does. Code and metadata are never
/// marked; math only when the platform has no math.
@MainActor
enum MarkdownCompatibility {
    struct Mark: Equatable {
        let feature: MarkdownFeature
        let range: NSRange
    }

    static let bareLink = MarkdownStyler.re(#"(?<![(<\[\w/@.])(?:https?://|www\.)[^\s<>()\[\]]*[^\s<>()\[\].,;:!?'"*_~]"#, [])

    static func marks(in text: String, flavour: MarkdownDialect) -> [Mark] {
        let features = flavour.features
        // GitHub-style callouts come in five kinds, so each is checked.
        let strictCallouts = features.contains(.alerts) && flavour.alertStyle != "obsidian"
        guard features.count < MarkdownFeature.allCases.count || strictCallouts else { return [] }
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)
        let fences = MarkdownStyler.fence.matches(in: text, range: all).map(\.range)
        let math = MathPresentation.regions(in: text).map(\.range.nsRange)
        let code = fences + [MarkdownSyntax.frontMatter(in: text)].compactMap { $0 }
            + MarkdownStyler.code.matches(in: text, range: all).map(\.range)
        let literal = code + math
        let critics = MarkdownStyler.critic.flatMap { $0.matches(in: text, range: all).map(\.range) }
        func clear(_ range: NSRange, of protected: [NSRange]) -> Bool {
            !protected.contains { NSIntersectionRange($0, range).length > 0 }
        }
        var marks: [Mark] = []
        func add(_ feature: MarkdownFeature, _ ranges: [NSRange], protected: [NSRange]? = nil) {
            guard !features.contains(feature) else { return }
            marks += ranges.filter { $0.length > 0 && clear($0, of: protected ?? literal) }.map { Mark(feature: feature, range: $0) }
        }
        func matches(_ pattern: NSRegularExpression, group: Int = 0) -> [NSRange] {
            pattern.matches(in: text, range: all).map { $0.range(at: group) }.filter { $0.location != NSNotFound }
        }

        add(.math, math, protected: code)
        add(.mermaid, MermaidPresentation.blocks(in: text).map(\.range), protected: [])
        add(.tables, matches(MarkdownStyler.table).filter { table in
            MarkdownStyler.tableRule.firstMatch(in: text, range: table) != nil
        }.map { trimmed($0, in: ns) })
        add(.strikethrough, matches(MarkdownStyler.strike), protected: literal + critics)
        add(.taskLists, matches(MarkdownStyler.task, group: 1))
        add(.autolinks, matches(bareLink))
        add(.footnotes, matches(MarkdownStyler.footnote))
        add(.admonitions, MarkdownConversion.admonitions(in: ns, fences: fences).map(\.range))
        let callouts = MarkdownConversion.callouts(in: ns, fences: fences)
        if features.contains(.alerts) {
            if strictCallouts {
                marks += callouts.filter { !MarkdownConversion.supports($0, flavour) && clear($0.range, of: literal) }
                    .map { Mark(feature: .alerts, range: $0.range) }
            }
        } else {
            add(.alerts, callouts.map(\.range))
        }
        add(.highlights, matches(MarkdownStyler.highlight), protected: literal + critics)
        add(.critic, critics)
        add(.wikiLinks, MarkdownStyler.wikiLink.matches(in: text, range: all).map { m in
            m.range.location > 0 && ns.character(at: m.range.location - 1) == 33
                ? NSRange(location: m.range.location - 1, length: m.range.length + 1) : m.range
        })
        add(.comments, matches(MarkdownConversion.percentComment))
        return marks.sorted { $0.range.location < $1.range.location }
    }

    private static func trimmed(_ range: NSRange, in ns: NSString) -> NSRange {
        var r = range
        while r.length > 0, [10, 13].contains(ns.character(at: r.upperBound - 1)) { r.length -= 1 }
        return r
    }
}
