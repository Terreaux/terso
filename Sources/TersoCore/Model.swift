// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// A range in UTF-16 code units, the unit NSTextView and NSString use.
/// Every range produced by analysis is in these units so it maps onto the
/// editor without conversion.
public struct TextSpan: Hashable, Codable, Sendable, Comparable {
    public var location: Int
    public var length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }

    public init(_ ns: NSRange) {
        self.init(location: ns.location, length: ns.length)
    }

    public var upperBound: Int { location + length }
    public var nsRange: NSRange { NSRange(location: location, length: length) }

    public func contains(_ index: Int) -> Bool { index >= location && index < upperBound }
    public func intersects(_ other: TextSpan) -> Bool {
        location < other.upperBound && other.location < upperBound
    }
    public func shifted(by delta: Int) -> TextSpan {
        TextSpan(location: location + delta, length: length)
    }
    public static func < (a: TextSpan, b: TextSpan) -> Bool {
        (a.location, a.length) < (b.location, b.length)
    }
}

/// Monotonic counter bumped on every change to a document's text.
public struct DocumentRevision: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public let value: UInt64
    public init(_ value: UInt64) { self.value = value }
    public func next() -> DocumentRevision { DocumentRevision(value &+ 1) }
    public static func < (a: DocumentRevision, b: DocumentRevision) -> Bool { a.value < b.value }
    public var description: String { "r\(value)" }
}

/// An immutable view of a document at one revision. Every asynchronous
/// subsystem (rules, statistics, AI) works on snapshots, never on the live text.
public struct DocumentSnapshot: Sendable, Hashable {
    public let revision: DocumentRevision
    public let text: String
    public let fileName: String?

    public init(revision: DocumentRevision, text: String, fileName: String? = nil) {
        self.revision = revision
        self.text = text
        self.fileName = fileName
    }

    public var utf16Length: Int { text.utf16.count }

    /// Text in `range`, or nil when the range falls outside the snapshot.
    public func substring(_ range: TextSpan) -> String? {
        let ns = text as NSString
        guard range.location >= 0, range.upperBound <= ns.length else { return nil }
        return ns.substring(with: range.nsRange)
    }
}

public enum Severity: Int, Codable, Sendable, Comparable, CaseIterable {
    case info = 0, suggestion = 1, warning = 2
    public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    public var label: String {
        switch self {
        case .info: "Note"
        case .suggestion: "Suggestion"
        case .warning: "Warning"
        }
    }
}

/// Presentation layers. Toggling a layer changes only what is drawn.
public enum AnnotationCategory: String, Codable, Sendable, CaseIterable, Identifiable {
    case notation, quantities, references, claims, evidence
    case readability, complexity, passiveVoice, style, repetition, specificity, aiStyle, aiSuggestion, spelling
    case filler, adverbs, loosePronouns, misused, lexicalIllusions, rhythm
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .notation: "Notation"
        case .quantities: "Quantities"
        case .references: "References"
        case .claims: "Claims"
        case .evidence: "Evidence"
        case .readability: "Readability"
        case .complexity: "Complexity"
        case .passiveVoice: "Passive voice"
        case .style: "Style"
        case .repetition: "Repetition"
        case .specificity: "Specificity"
        case .aiStyle: "AI-style signals"
        case .aiSuggestion: "AI suggestions"
        case .spelling: "Spelling & grammar"
        case .filler: "Filler words"
        case .adverbs: "Adverbs"
        case .loosePronouns: "Loose pronouns"
        case .misused: "Commonly misused"
        case .lexicalIllusions: "Lexical illusions"
        case .rhythm: "Sentence rhythm"
        }
    }
}

public enum AnnotationSource: String, Codable, Sendable {
    case rule, statistical, aiStyle, aiSuggestion, spelling
}

/// A finding from a deterministic rule.
public struct WritingIssue: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let ruleID: String
    public let severity: Severity
    public let category: AnnotationCategory
    public let message: String
    public let explanation: String
    /// One finding may cover several ranges (e.g. every occurrence of a phrase).
    public let ranges: [TextSpan]
    public let originalText: String
    /// Optional replacement the writer may consider. Never applied automatically.
    public let consider: String?
    public let metadata: [String: String]

    public init(
        id: UUID = UUID(), ruleID: String, severity: Severity, category: AnnotationCategory,
        message: String, explanation: String, ranges: [TextSpan], originalText: String,
        consider: String? = nil, metadata: [String: String] = [:]
    ) {
        self.id = id
        self.ruleID = ruleID
        self.severity = severity
        self.category = category
        self.message = message
        self.explanation = explanation
        self.ranges = ranges
        self.originalText = originalText
        self.consider = consider
        self.metadata = metadata
    }
}

/// Anything drawn over the text. Annotations are presentation only.
public struct TextAnnotation: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let source: AnnotationSource
    public let category: AnnotationCategory
    public let ranges: [TextSpan]
    public let severity: Severity
    public let message: String
    public let explanation: String?
    public let consider: String?
    public let revision: DocumentRevision
    public let metadata: [String: String]

    public init(
        id: UUID = UUID(), source: AnnotationSource, category: AnnotationCategory, ranges: [TextSpan],
        severity: Severity, message: String, explanation: String?, consider: String? = nil,
        revision: DocumentRevision, metadata: [String: String] = [:]
    ) {
        self.id = id
        self.source = source
        self.category = category
        self.ranges = ranges
        self.severity = severity
        self.message = message
        self.explanation = explanation
        self.consider = consider
        self.revision = revision
        self.metadata = metadata
    }

    public init(issue: WritingIssue, revision: DocumentRevision) {
        self.init(
            id: issue.id, source: .rule, category: issue.category, ranges: issue.ranges,
            severity: issue.severity, message: issue.message, explanation: issue.explanation,
            consider: issue.consider, revision: revision,
            metadata: issue.metadata.merging(["rule": issue.ruleID, "text": issue.originalText]) { a, _ in a })
    }

    /// Identifies "the same finding" across re-analyses, whose annotation IDs
    /// are new each time: used to remember dismissals while the writer types.
    public var dismissalKey: String {
        "\(category.rawValue)|\(message)|\(metadata["text"] ?? metadata["word"] ?? metadata["feature"] ?? id.uuidString)"
    }
}
