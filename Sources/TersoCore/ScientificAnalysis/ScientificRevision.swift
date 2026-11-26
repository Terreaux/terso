// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Mechanical differences worth checking before accepting a scientific rewrite.
public struct ScientificRevisionChange: Equatable, Sendable, Identifiable {
    public enum Kind: String, CaseIterable, Sendable {
        case number = "Numbers", unit = "Units", uncertainty = "Uncertainty", negation = "Negation", citation = "Citations", math = "Mathematics"
    }

    public var id: Kind { kind }
    public let kind: Kind
    public let before: [String]
    public let after: [String]

    public static func compare(_ original: String, _ proposed: String) -> [Self] {
        guard original != proposed else { return [] }
        let before = signatures(original), after = signatures(proposed)
        return Kind.allCases.compactMap { kind in
            let lhs = before[kind, default: []], rhs = after[kind, default: []]
            guard lhs != rhs else { return nil }
            let delta = rhs.difference(from: lhs)
            let removed: [String] = delta.removals.compactMap {
                guard case .remove(_, let value, _) = $0 else { return nil }
                return value
            }
            let inserted: [String] = delta.insertions.compactMap {
                guard case .insert(_, let value, _) = $0 else { return nil }
                return value
            }
            return Self(kind: kind, before: removed, after: inserted)
        }
    }

    private static let numberPattern = #"[+−-]?(?:\d+(?:\.\d+)?|\.\d+)(?:[eE][+−-]?\d+)?"#
    private static let numbers = regex("(?<![\\p{L}\\p{N}_])" + numberPattern)
    private static let uncertainty = regex(#"(?:±|\\pm|\+/-)\s*"# + numberPattern)
    private static let negations = regex(#"(?i)\b(?:no|not|never|neither|nor|without|cannot|\w+n['’]t)\b"#)
    private static let unitAtom = #"(?:[afpnumcdkhMGTPEµμ]?(?:eV|Hz|Pa|mol|rad|bar|[mgslLJVWAKNb])|mmHg|Da|Gy|Sv|°[CF]|%)"#
    private static let exponent = #"(?:\s*\^\s*\{?[+−-]?\d+\}?|[⁻⁺⁰¹²³⁴⁵⁶⁷⁸⁹]+)?"#
    private static let unitText = regex(numberPattern + #"(?:\s|~|\\[,;! ])*(?:\\(?:mathrm|textrm|text)\s*\{\s*)?(\\?("# + unitAtom + exponent + #"(?:\s*[/·]\s*"# + unitAtom + exponent + #")*))(?![\p{L}\p{N}])"#)
    private static let siUnit = regex(#"\\(?:SI|qty)\*?(?:\[[^\]]*\])?\{[^{}]+\}\{([^{}]+)\}|\\(?:si|unit)\*?(?:\[[^\]]*\])?\{([^{}]+)\}"#)
    private static func regex(_ pattern: String) -> NSRegularExpression { try! NSRegularExpression(pattern: pattern) }

    private static func signatures(_ text: String) -> [Kind: [String]] {
        var results: [Kind: [String]] = [:]
        let ns = text as NSString
        let mask = NSMutableString(string: text)
        let all = NSRange(location: 0, length: ns.length)
        func matches(_ pattern: NSRegularExpression, in text: String, group: Int = 0) -> [String] {
            let source = text as NSString
            return pattern.matches(in: text, range: NSRange(location: 0, length: source.length)).compactMap {
                let r = $0.range(at: group)
                return r.location == NSNotFound ? nil : source.substring(with: r)
            }
        }
        for token in ManuscriptReferenceSyntax.tokens(in: text, markdown: true) {
            if token.kind == .citation { results[.citation, default: []].append(token.key) }
            mask.replaceCharacters(in: token.keyRange.nsRange, with: String(repeating: " ", count: token.keyRange.length))
        }
        results[.citation]?.sort()
        let body = mask as String
        results[.number] = matches(numbers, in: body).map { $0.replacingOccurrences(of: "−", with: "-") }
        results[.unit] = matches(unitText, in: body, group: 1).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\\")) }
        for match in siUnit.matches(in: body, range: all) {
            let range = match.range(at: 1).location == NSNotFound ? match.range(at: 2) : match.range(at: 1)
            results[.unit, default: []].append(mask.substring(with: range))
        }
        results[.uncertainty] = matches(uncertainty, in: body).map {
            $0.replacingOccurrences(of: #"\\pm"#, with: "±").replacingOccurrences(of: "+/-", with: "±").filter { !$0.isWhitespace }
        }
        results[.negation] = matches(negations, in: body).map { $0.lowercased().replacingOccurrences(of: "’", with: "'") }
        let syntax = ScientificSyntax(DocumentSnapshot(revision: DocumentRevision(0), text: body))
        results[.math] = syntax.regions.compactMap {
            guard $0.kind == .inlineMath || $0.kind == .displayMath else { return nil }
            return $0.normalizedContent
        }
        return results
    }
}
