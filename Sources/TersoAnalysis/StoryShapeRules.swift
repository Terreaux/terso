// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import TersoCore

/// Fiction only: patterns in a story's shape that readers take for generated
/// prose — the opening brought back at the end, a stated moral, a steady
/// supply of similes. After the story-shape findings published with Quirón
/// (references/fiction.md); the detection here is Terso's own. They run when
/// the register is Fiction, since the same moves are ordinary in an essay.
public enum StoryShape {
    public static let rules: [any WritingRule] = [StoryBookendRule(), StatedMoralRule(), SimileDensityRule()]

    /// Paragraphs of narrative: list items and quotes don't carry the shape.
    static func paragraphs(_ prose: ProseText) -> [Int] {
        prose.blocks.indices.filter { prose.blocks[$0].kind == .paragraph && !prose.sentences(inBlock: $0).isEmpty }
    }
}

// MARK: - Bookends

/// The opening image, line or object brought back in the last paragraph.
public struct StoryBookendRule: WritingRule {
    public let id = "story.bookend"
    public let name = "Bookended ending"
    public let description = "The last paragraph brings back the opening's image or words."
    public let category = AnnotationCategory.storyShape
    public init() {}

    /// How much of each end counts as the opening and the close. Generated
    /// stories often end on a one-line paragraph, so this goes by words.
    public var window = 60

    public func analyze(_ ctx: AnalysisContext) -> [WritingIssue] {
        let spans = ctx.prose.words
        guard spans.count >= window * 5 else { return [] }
        let words = spans.map { ctx.text($0).lowercased() }
        func content(_ w: String) -> Bool { w.count >= 4 && !Lexicon.stopwords.contains(w) }
        let opening = 0..<window, closing = (words.count - window)..<words.count
        let middle = " " + words[window..<(words.count - window)].joined(separator: " ") + " "
        // A two-word image ("black glass", "the first chime") that opens the
        // story, returns at the end, and is (almost) absent between. Single
        // shared words are mostly the subject and don't separate the two.
        func pairs(_ r: Range<Int>) -> [String: Int] {
            var out: [String: Int] = [:]
            for i in r.dropLast() where content(words[i]) && content(words[i + 1]) { out[words[i] + " " + words[i + 1]] = out[words[i] + " " + words[i + 1]] ?? i }
            return out
        }
        let openPairs = pairs(opening)
        let echoed = pairs(closing).filter { openPairs[$0.key] != nil && middle.components(separatedBy: " \($0.key) ").count <= 2 }
        guard !echoed.isEmpty else { return [] }
        let marked = Set(echoed.flatMap { pair, i in [i, i + 1, openPairs[pair]!, openPairs[pair]! + 1] })
        let shown = echoed.keys.sorted()
        let list = shown.map { "“\($0)”" }.joined(separator: ", ")
        let tail = TextSpan(location: spans[closing.lowerBound].location, length: spans[closing.upperBound - 1].upperBound - spans[closing.lowerBound].location)
        return [WritingIssue(
            ruleID: id, severity: .suggestion, category: category, message: "Ending echoes the opening",
            explanation: "The ending brings back \(list) from the opening, and the middle of the story barely uses them. A callback that closes the circle is one of the shapes readers most often name in generated stories. Consider stopping on an ordinary moment instead, and leaving some planted details unpaid.",
            ranges: marked.sorted().map { spans[$0] }, originalText: ctx.text(tail), metadata: ["words": shown.joined(separator: ",")])]
    }
}

// MARK: - Stated moral

/// A line near the end that says what the story means.
public struct StatedMoralRule: WritingRule {
    public let id = "story.moral"
    public let name = "Stated moral"
    public let description = "A sentence near the end that spells out what the story means."
    public let category = AnnotationCategory.storyShape
    public init() {}

    static let patterns = Lexicon.regex([
        #"\b(?:understood|realized|realised|learned|learnt|knew now|came to see) (?:that|what|how|why)\b"#,
        #"\b(?:finally|at last|for the first time\b[^.]{0,30}) (?:understood|realized|realised|learned|learnt|knew|saw)\b"#,
        #"\b(?:was|is|had been) never (?:really )?about\b"#,
        #"\bmaybe that was (?:the|all the) (?:point|lesson|answer)\b"#,
        #"\bthat was the (?:point|lesson|thing about)\b"#,
        #"\bthe thing about \w+ (?:is|was)\b"#,
        #"\b(?:some|the) things (?:you|we) (?:can't|can’t|cannot|don't|don’t|never)\b"#,
        #"\b(?:sometimes|perhaps) (?:the|a) \w+ (?:is|was) (?:just|only|simply)\b"#,
        #"\b(?:small|light|quiet) enough to (?:carry|hold|keep)\b"#,
    ].joined(separator: "|"))

    public func analyze(_ ctx: AnalysisContext) -> [WritingIssue] {
        let paras = StoryShape.paragraphs(ctx.prose)
        guard paras.count >= 4 else { return [] }
        // Generated stories often close on a one-line paragraph, so the last three.
        let tail = Set(paras.suffix(3))
        return ctx.prose.sentences.filter { tail.contains($0.blockIndex) }.compactMap { s in
            let text = ctx.prose.maskedString(s.range)
            guard Self.patterns.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil else { return nil }
            return WritingIssue(
                ruleID: id, severity: .suggestion, category: category, message: "Stated moral",
                explanation: "This sentence tells the reader what the story meant. An aphorism or a realisation at the emotional peak is a mark readers often catch in generated fiction; the scene before it usually says it already. Consider cutting it.",
                ranges: [s.range], originalText: ctx.text(s.range))
        }
    }
}

// MARK: - Similes

/// One or two similes carry a story; one a paragraph reads as a habit.
public struct SimileDensityRule: WritingRule {
    public let id = "story.similes"
    public let name = "Frequent similes"
    public let description = "More similes than a story usually carries."
    public let category = AnnotationCategory.storyShape
    public var allowed = 2
    /// Per 1,000 words; a long story may carry a few more.
    public var perThousand = 2.5
    public init() {}

    // "like a", "as if", "as though", "as cold as a". The look-behind skips
    // the verb ("I'd like a", "would like the").
    static let simile = Lexicon.regex([
        #"(?<!\b(?:i|you|we|they|would|'d|’d|do|don't|don’t|didn't|didn’t|to|might|may) )\blike (?:a|an|the|some|someone|something)\b"#,
        #"\bas (?:if|though)\b"#,
        #"\bas \w+ as (?:a|an|the|if)\b"#,
    ].joined(separator: "|"))

    public func analyze(_ ctx: AnalysisContext) -> [WritingIssue] {
        let words = ctx.prose.words.count
        guard words >= 200 else { return [] }
        let matches = Self.simile.matches(in: ctx.prose.masked, range: NSRange(location: 0, length: ctx.prose.maskedNS.length))
        let limit = max(allowed, Int((Double(words) / 1000 * perThousand).rounded(.down)))
        guard matches.count > limit else { return [] }
        let ranges = matches.map { TextSpan($0.range) }
        return [WritingIssue(
            ruleID: id, severity: .info, category: category, message: "\(matches.count) similes",
            explanation: "This story has \(matches.count) similes in \(words.formatted()) words. A steady supply of them, one a paragraph, is one of the things readers name in generated fiction; human stories usually carry one or two. Keep the ones that matter to the narrator, and never follow an image with its explanation.",
            ranges: ranges, originalText: ranges.map(ctx.text).joined(separator: " · "), metadata: ["count": "\(matches.count)"])]
    }
}
