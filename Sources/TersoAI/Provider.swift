// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import TersoCore

public enum ProviderCapability: String, Codable, Sendable, CaseIterable {
    case explain, suggestRevisions, reviewDocument, answerQuestions
}

/// Whether text leaves the machine. Shown next to every provider.
public enum ProviderLocality: String, Codable, Sendable {
    case local = "LOCAL", network = "NETWORK"
}

/// How much of the document is sent. The user picks this every time.
public enum ContextScope: String, Codable, Sendable, CaseIterable, Identifiable {
    case selection, paragraph, section, document
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .selection: "Selection"
        case .paragraph: "Current paragraph"
        case .section: "Current section"
        case .document: "Whole document"
        }
    }
}

/// Exactly the text that will be transmitted, and where it came from.
public struct ContextPayload: Sendable, Hashable {
    public let scope: ContextScope
    public let text: String
    /// Location of `text` in the snapshot, so answers can be anchored.
    public let range: TextSpan
    public let revision: DocumentRevision
    public let fileName: String?

    public var wordCount: Int { text.split(whereSeparator: { $0.isWhitespace }).count }

    public init(scope: ContextScope, text: String, range: TextSpan, revision: DocumentRevision, fileName: String?) {
        self.scope = scope; self.text = text; self.range = range; self.revision = revision; self.fileName = fileName
    }

    /// Cut the requested scope out of a snapshot around `selection`.
    public static func make(scope: ContextScope, snapshot: DocumentSnapshot, selection: TextSpan) -> ContextPayload {
        let ns = snapshot.text as NSString
        let sel = TextSpan(location: min(max(0, selection.location), ns.length),
                            length: max(0, min(selection.length, ns.length - min(max(0, selection.location), ns.length))))
        var r: NSRange
        switch scope {
        case .selection:
            r = sel.length > 0 ? sel.nsRange : ns.paragraphRange(for: sel.nsRange)
        case .paragraph:
            r = paragraph(around: sel.nsRange, in: ns)
        case .section:
            let prose = ProseText(markdown: snapshot.text)
            let start = prose.headings.last { $0.range.location <= sel.location }
            let level = start?.level ?? 0
            let end = prose.headings.first { $0.range.location > sel.location && (level == 0 || $0.level <= level) }
            let lo = start?.range.location ?? 0
            r = NSRange(location: lo, length: (end?.range.location ?? ns.length) - lo)
        case .document:
            r = NSRange(location: 0, length: ns.length)
        }
        return ContextPayload(scope: scope, text: ns.substring(with: r), range: TextSpan(r), revision: snapshot.revision, fileName: snapshot.fileName)
    }

    /// A paragraph is delimited by blank lines, not single newlines.
    static func paragraph(around sel: NSRange, in ns: NSString) -> NSRange {
        var start = ns.lineRange(for: NSRange(location: sel.location, length: 0)).location
        while start > 0 {
            let prev = ns.lineRange(for: NSRange(location: start - 1, length: 0))
            if ns.substring(with: prev).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }
            start = prev.location
        }
        var end = ns.lineRange(for: NSRange(location: max(sel.location, sel.upperBound - 1), length: 0)).upperBound
        while end < ns.length {
            let next = ns.lineRange(for: NSRange(location: end, length: 0))
            if ns.substring(with: next).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }
            end = next.upperBound
        }
        var r = NSRange(location: start, length: end - start)
        while r.length > 0, ns.character(at: r.upperBound - 1) == 0x0A { r.length -= 1 }
        return r
    }
}

public enum AssistantTask: String, Codable, Sendable, CaseIterable, Identifiable {
    case ask, improveClarity, makeConcise, explainUnclear, checkArgument, findUnsupportedClaims, reviewStructure, findAmbiguity, suggestAlternatives, proofread, reviewDocument
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .ask: "Ask…"
        case .improveClarity: "Improve clarity"
        case .makeConcise: "Make concise"
        case .explainUnclear: "Explain what’s unclear"
        case .checkArgument: "Find weak arguments"
        case .findUnsupportedClaims: "Find unsupported claims"
        case .reviewStructure: "Review structure"
        case .findAmbiguity: "Find ambiguity"
        case .suggestAlternatives: "Suggest alternatives"
        case .proofread: "Proofread"
        case .reviewDocument: "Review document"
        }
    }
    var instruction: String {
        switch self {
        case .ask: "Answer the writer's question about the passage."
        case .improveClarity: "Propose revisions that make unclear sentences clearer. Keep the writer's voice and meaning."
        case .makeConcise: "Propose revisions that remove words the passage does not need. Keep meaning and voice."
        case .explainUnclear: "Explain which parts of the passage a reader may find unclear and why. Suggest revisions only where they help."
        case .checkArgument: "Assess whether the argument holds: unsupported claims, gaps, leaps. Explain; propose revisions sparingly."
        case .findUnsupportedClaims: "Identify claims the passage asserts without evidence, example or attribution. Explain each briefly. Do not invent sources; suggest what kind of support would help."
        case .reviewStructure: "Assess the order and structure: does each part follow from the last, is anything out of place, repeated or missing? Explain; propose revisions only for transitions."
        case .findAmbiguity: "Identify ambiguous wording (pronouns, scope, terms) and explain each. Propose disambiguating revisions."
        case .suggestAlternatives: "Offer alternative phrasings for the passage, each as a separate suggestion on the same original text."
        case .proofread: "Correct spelling, grammar and punctuation only. Do not change style."
        case .reviewDocument: "Review the document as an editor. Propose the most valuable revisions (clarity, repetition, argument structure, wordiness). Label each with a kind."
        }
    }
}

public struct AnalysisRequest: Sendable {
    public let task: AssistantTask
    public let question: String?
    public let context: ContextPayload
    public init(task: AssistantTask, question: String? = nil, context: ContextPayload) {
        self.task = task; self.question = question; self.context = context
    }
}

/// A revision proposed by a provider, before it is anchored to the document.
public struct ProposedRevision: Codable, Sendable, Hashable {
    public let original: String
    public let proposed: String
    public let explanation: String?
    public let kind: String?
    public init(original: String, proposed: String, explanation: String?, kind: String?) {
        self.original = original; self.proposed = proposed; self.explanation = explanation; self.kind = kind
    }
}

public struct AnalysisResponse: Sendable {
    public let message: String
    public let proposals: [ProposedRevision]
    public init(message: String, proposals: [ProposedRevision]) {
        self.message = message; self.proposals = proposals
    }
}

public enum ProviderError: LocalizedError, Equatable {
    case notConfigured(String)
    case executableNotFound(String)
    case processFailed(status: Int32, stderr: String)
    case timedOut(TimeInterval)
    case http(Int, String)
    case invalidResponse(String)
    case missingCredential(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured(let s): "Provider not configured: \(s)"
        case .executableNotFound(let s): "Executable not found: \(s)"
        case .processFailed(let status, let err): "The tool exited with status \(status). \(err.prefix(400))"
        case .timedOut(let t): "The provider did not answer within \(Int(t)) seconds."
        case .http(let code, let body): "HTTP \(code): \(body.prefix(400))"
        case .invalidResponse(let s): "Unreadable response: \(s)"
        case .missingCredential(let s): "No API key stored for \(s). Add one in Settings → AI."
        }
    }
}

/// An AI provider. It receives a request containing only the chosen context
/// text and returns proposals as data. It has no reference to the document,
/// the editor or the file system location of the user's file.
public protocol WritingAssistantProvider: Sendable {
    var id: ProviderID { get }
    var displayName: String { get }
    var locality: ProviderLocality { get }
    var capabilities: Set<ProviderCapability> { get }
    func analyze(_ request: AnalysisRequest) async throws -> AnalysisResponse
}

/// The writer's standing limit on how much text may ever be sent.
public enum AIDataAccess: String, Codable, Sendable, CaseIterable, Identifiable {
    case selectionOnly, upToSection, wholeDocument
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .selectionOnly: "Selection only"
        case .upToSection: "Up to the current section"
        case .wholeDocument: "Whole document when explicitly requested"
        }
    }
    public func permits(_ scope: ContextScope) -> Bool {
        switch self {
        case .selectionOnly: scope == .selection
        case .upToSection: scope != .document
        case .wholeDocument: true
        }
    }
}
