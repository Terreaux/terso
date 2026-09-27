// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import TersoCore

public enum PromptBuilder {
    /// Editorial rules shared by every provider.
    public static let editorRules = """
    You are an editor helping a writer revise their own text. You never rewrite the \
    whole text unasked, never invent facts, examples, sources or personal experiences, \
    and never claim to detect authorship. You do not edit files; you only reply. \
    Each suggestion's original text must be copied verbatim from the passage, short \
    (a phrase or sentence), and unique within it. Propose a revision wherever the task \
    applies; return no suggestions only if the passage truly needs none.
    """

    public static let system = editorRules + """


    Reply with a single JSON object and nothing else:
    {"message": "<your explanation or answer, plain prose>",
     "suggestions": [{"original": "<exact text copied from the passage>",
                      "proposed": "<replacement>",
                      "explanation": "<why, one or two sentences>",
                      "kind": "<clarity|concision|repetition|argument|ambiguity|grammar|wordiness|alternative>"}]}
    Each "original" must be copied verbatim from the passage, short (a phrase or \
    sentence), and unique within it. Use an empty suggestions list when none are needed.
    """

    public static func user(_ request: AnalysisRequest) -> String {
        var s = "Task: \(request.task.instruction)\n"
        if let q = request.question, !q.isEmpty { s += "Writer's question: \(q)\n" }
        s += "Passage (\(request.context.scope.title.lowercased())):\n<<<PASSAGE\n\(request.context.text)\nPASSAGE>>>\n"
        return s
    }

    /// For CLI tools that take one prompt on stdin.
    public static func combined(_ request: AnalysisRequest) -> String {
        system + "\n\n" + user(request)
    }
}

public enum ResponseParser {
    struct Wire: Decodable {
        let message: String?
        let suggestions: [ProposedRevision]?
    }

    /// Extract the JSON object from a model reply, tolerating code fences and
    /// surrounding prose. A reply without JSON becomes a plain message.
    public static func parse(_ raw: String) -> AnalysisResponse {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for candidate in candidates(in: trimmed) {
            if let data = candidate.data(using: .utf8), let wire = try? JSONDecoder().decode(Wire.self, from: data) {
                return AnalysisResponse(message: wire.message ?? "", proposals: (wire.suggestions ?? []).filter { !$0.original.isEmpty && $0.original != $0.proposed })
            }
        }
        return AnalysisResponse(message: trimmed, proposals: [])
    }

    static func candidates(in s: String) -> [String] {
        var out: [String] = [s]
        if let fence = s.range(of: #"```(?:json)?\s*([\s\S]*?)```"#, options: .regularExpression) {
            out.append(String(s[fence]).replacingOccurrences(of: #"^```(?:json)?"#, with: "", options: .regularExpression).replacingOccurrences(of: "```", with: ""))
        }
        if let first = s.firstIndex(of: "{"), let last = s.lastIndex(of: "}"), first < last {
            out.append(String(s[first...last]))
        }
        return out
    }
}

/// Turns proposals into anchored suggestions. Proposals whose original text
/// cannot be found exactly once in the transmitted context are discarded:
/// guessing a location would risk editing the wrong passage.
public enum SuggestionBuilder {
    public static func build(_ proposals: [ProposedRevision], context: ContextPayload, snapshot: DocumentSnapshot, provider: ProviderID) -> (suggestions: [WritingSuggestion], discarded: Int) {
        let ctx = context.text as NSString
        var out: [WritingSuggestion] = []
        var discarded = 0
        for p in proposals {
            let first = ctx.range(of: p.original, options: .literal)
            guard first.location != NSNotFound else { discarded += 1; continue }
            let after = first.upperBound
            let again = after < ctx.length ? ctx.range(of: p.original, options: .literal, range: NSRange(location: after, length: ctx.length - after)) : NSRange(location: NSNotFound, length: 0)
            guard again.location == NSNotFound else { discarded += 1; continue }
            let span = TextSpan(location: context.range.location + first.location, length: first.length)
            guard snapshot.revision == context.revision, let anchor = TextAnchor(range: span, in: snapshot) else { discarded += 1; continue }
            out.append(WritingSuggestion(documentRevision: context.revision, anchor: anchor, proposedText: p.proposed,
                                         explanation: p.explanation, kind: p.kind, provider: provider))
        }
        return (out, discarded)
    }
}
