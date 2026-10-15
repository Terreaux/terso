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
    /// `wholeContext`: the context is the one passage the writer asked to have
    /// rewritten. A lone proposal that cannot be located but is plainly a
    /// version of the whole passage then replaces the whole passage.
    public static func build(_ proposals: [ProposedRevision], context: ContextPayload, snapshot: DocumentSnapshot,
                             provider: ProviderID, wholeContext: Bool = false) -> (suggestions: [WritingSuggestion], discarded: Int) {
        let ctx = context.text as NSString
        var out: [WritingSuggestion] = []
        var discarded = 0
        for p in proposals {
            var found = locate(p.original, in: ctx)
            var proposed = p.proposed
            if found == nil, wholeContext, proposals.count == 1, resembles(p.original, context.text) || resembles(p.proposed, context.text) {
                found = trimmed(NSRange(location: 0, length: ctx.length), in: ctx)
                proposed = p.proposed.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard let found, found.length > 0 else { discarded += 1; continue }
            let original = ctx.substring(with: found)
            guard proposed != original else { discarded += 1; continue }
            let span = TextSpan(location: context.range.location + found.location, length: found.length)
            guard snapshot.revision == context.revision, let anchor = TextAnchor(range: span, in: snapshot) else { discarded += 1; continue }
            out.append(WritingSuggestion(documentRevision: context.revision, anchor: anchor, proposedText: proposed,
                                         explanation: p.explanation, kind: p.kind, provider: provider))
        }
        return (out, discarded)
    }

    /// The single place `needle` occurs in `hay`: verbatim first, then
    /// ignoring case, curly versus straight quotes, runs of whitespace and
    /// Markdown emphasis marks, which models routinely normalise.
    static func locate(_ needle: String, in hay: NSString) -> NSRange? {
        guard !needle.isEmpty else { return nil }
        let first = hay.range(of: needle, options: .literal)
        if first.location != NSNotFound {
            let after = first.upperBound
            let again = hay.range(of: needle, options: .literal, range: NSRange(location: after, length: hay.length - after))
            return again.location == NSNotFound ? first : nil
        }
        let (h, map) = normalized(hay as String)
        let (n, _) = normalized(needle)
        let nn = n.trimmingCharacters(in: .whitespaces)
        guard !nn.isEmpty else { return nil }
        let hs = h as NSString
        let hit = hs.range(of: nn, options: .literal)
        guard hit.location != NSNotFound else { return nil }
        let after = hit.upperBound
        guard hs.range(of: nn, options: .literal, range: NSRange(location: after, length: hs.length - after)).location == NSNotFound
        else { return nil }
        let start = map[hit.location], end = map[hit.upperBound - 1] + 1
        return NSRange(location: start, length: end - start)
    }

    /// Lowercased, quotes straightened, emphasis marks dropped and whitespace
    /// collapsed, with each output UTF-16 unit's offset in the input.
    static func normalized(_ s: String) -> (String, [Int]) {
        let ns = s as NSString
        var out: [unichar] = [], map: [Int] = []
        var lastSpace = false
        for i in 0..<ns.length {
            var c = ns.character(at: i)
            switch c {
            case 0x2018, 0x2019, 0x2032: c = 0x27           // ‘ ’ ′ → '
            case 0x201C, 0x201D, 0x2033: c = 0x22           // “ ” ″ → "
            case 0x2013, 0x2014: c = 0x2D                   // – — → -
            case 0x2A, 0x5F, 0x60: continue                 // * _ `
            default: break
            }
            if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0xA0 {
                if lastSpace { continue }
                lastSpace = true
                out.append(0x20); map.append(i)
                continue
            }
            lastSpace = false
            out.append(c); map.append(i)
        }
        return ((String(utf16CodeUnits: out, count: out.count) as String).lowercased(), map)
    }

    /// Most of the passage's words appear in `candidate`, and it is about as long.
    static func resembles(_ candidate: String, _ passage: String) -> Bool {
        func words(_ s: String) -> [String] {
            s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        }
        let a = words(candidate), b = words(passage)
        guard b.count >= 3, !a.isEmpty else { return false }
        let ratio = Double(a.count) / Double(b.count)
        guard ratio > 0.6, ratio < 1.6 else { return false }
        let shared = Set(a).intersection(b).count
        return Double(shared) / Double(Set(b).count) >= 0.6
    }

    static func trimmed(_ r: NSRange, in s: NSString) -> NSRange {
        var start = r.location, end = r.upperBound
        let ws = CharacterSet.whitespacesAndNewlines
        while start < end, let u = UnicodeScalar(s.character(at: start)), ws.contains(u) { start += 1 }
        while end > start, let u = UnicodeScalar(s.character(at: end - 1)), ws.contains(u) { end -= 1 }
        return NSRange(location: start, length: end - start)
    }
}
