// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

public struct ProviderID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

/// Where a suggestion applies, recorded with enough context to find the
/// passage again after the document has changed.
public struct TextAnchor: Hashable, Codable, Sendable {
    public let range: TextSpan
    public let originalText: String
    public let prefix: String
    public let suffix: String

    public static let contextLength = 32

    public init(range: TextSpan, originalText: String, prefix: String, suffix: String) {
        self.range = range
        self.originalText = originalText
        self.prefix = prefix
        self.suffix = suffix
    }

    /// Anchor `range` inside `snapshot`, capturing surrounding context.
    public init?(range: TextSpan, in snapshot: DocumentSnapshot) {
        let ns = snapshot.text as NSString
        guard range.location >= 0, range.upperBound <= ns.length else { return nil }
        let preStart = max(0, range.location - Self.contextLength)
        let sufEnd = min(ns.length, range.upperBound + Self.contextLength)
        self.init(
            range: range,
            originalText: ns.substring(with: range.nsRange),
            prefix: ns.substring(with: NSRange(location: preStart, length: range.location - preStart)),
            suffix: ns.substring(with: NSRange(location: range.upperBound, length: sufEnd - range.upperBound)))
    }
}

/// A proposed revision. It is data: holding one never changes a document.
/// Only the review gate in TersoDocument can turn it into an edit, and only
/// after an explicit user decision.
public struct WritingSuggestion: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let documentRevision: DocumentRevision
    public let anchor: TextAnchor
    public let proposedText: String
    public let explanation: String?
    public let kind: String?
    public let provider: ProviderID
    public let createdAt: Date

    public init(
        id: UUID = UUID(), documentRevision: DocumentRevision, anchor: TextAnchor, proposedText: String,
        explanation: String?, kind: String? = nil, provider: ProviderID, createdAt: Date = Date()
    ) {
        self.id = id
        self.documentRevision = documentRevision
        self.anchor = anchor
        self.proposedText = proposedText
        self.explanation = explanation
        self.kind = kind
        self.provider = provider
        self.createdAt = createdAt
    }

    public var originalText: String { anchor.originalText }
    public var ranges: [TextSpan] { [anchor.range] }
}

/// The result of locating an anchor in a (possibly newer) snapshot.
public enum AnchorResolution: Equatable, Sendable {
    /// Same revision, same text at the same place.
    case exact(TextSpan)
    /// The text moved but was found unambiguously using its context.
    case relocated(TextSpan)
    /// The passage changed or cannot be located with confidence.
    case stale(String)

    public var range: TextSpan? {
        switch self {
        case .exact(let r), .relocated(let r): r
        case .stale: nil
        }
    }
}

/// Finds where an anchored passage lives now. Never guesses: an ambiguous or
/// missing match is reported stale rather than applied at an old offset.
public enum AnchorResolver {
    public static func resolve(_ anchor: TextAnchor, revision: DocumentRevision, in snapshot: DocumentSnapshot) -> AnchorResolution {
        let ns = snapshot.text as NSString
        let r = anchor.range
        let unchangedAtOffset = r.upperBound <= ns.length && ns.substring(with: r.nsRange) == anchor.originalText
        if snapshot.revision == revision {
            return unchangedAtOffset ? .exact(r) : .stale("The anchored text does not match this revision.")
        }
        guard !anchor.originalText.isEmpty else { return .stale("Empty anchor cannot be relocated.") }

        // Collect every occurrence of the original text.
        var hits: [TextSpan] = []
        var search = NSRange(location: 0, length: ns.length)
        while search.length > 0 {
            let found = ns.range(of: anchor.originalText, options: [.literal], range: search)
            if found.location == NSNotFound { break }
            hits.append(TextSpan(found))
            let next = found.location + max(found.length, 1)
            search = NSRange(location: next, length: ns.length - next)
        }
        if hits.isEmpty { return .stale("The original passage no longer exists.") }

        // Prefer occurrences whose surrounding context still matches.
        func contextScore(_ hit: TextSpan) -> Int {
            let pre = min(anchor.prefix.utf16.count, hit.location)
            let suf = min(anchor.suffix.utf16.count, ns.length - hit.upperBound)
            let before = ns.substring(with: NSRange(location: hit.location - pre, length: pre))
            let after = ns.substring(with: NSRange(location: hit.upperBound, length: suf))
            var score = 0
            if !anchor.prefix.isEmpty, before == anchor.prefix { score += 2 } else if !anchor.prefix.isEmpty, anchor.prefix.hasSuffix(before.suffix(8)) { score += 1 }
            if !anchor.suffix.isEmpty, after == anchor.suffix { score += 2 } else if !anchor.suffix.isEmpty, anchor.suffix.hasPrefix(after.prefix(8)) { score += 1 }
            return score
        }
        let scored = hits.map { ($0, contextScore($0)) }
        let best = scored.map(\.1).max() ?? 0
        let top = scored.filter { $0.1 == best }.map(\.0)
        if top.count == 1 {
            // A lone occurrence with no surviving context is still unambiguous.
            if best > 0 || hits.count == 1 { return .relocated(top[0]) }
        }
        return .stale("The passage appears \(hits.count) times and its context changed; it cannot be placed safely.")
    }
}
