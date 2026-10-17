// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import TersoCore

/// Fiction only: review prompts for opening callbacks, explicit lessons, and
/// frequent comparisons. These are ordinary literary choices as well as
/// patterns worth revisiting. The rules run only in the Fiction register.
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

    /// How much of each end counts as the opening and the close. Word windows
    /// include short final paragraphs without making them a special case.
    public var window = 60

    public func analyze(_ ctx: AnalysisContext) -> [WritingIssue] {
        let spans = ctx.prose.words
        guard spans.count >= window * 5 else { return [] }
        let words = spans.map { ctx.text($0).lowercased() }
        let ordinaryTimeWords: Set<String> = ["days", "weeks", "months", "years", "hours", "minutes"]
        func content(_ w: String) -> Bool {
            w.count >= 4 && !Lexicon.stopwords.contains(w) && !ordinaryTimeWords.contains(w)
        }
        func capitalized(_ i: Int) -> Bool {
            ctx.text(spans[i]).unicodeScalars.first.map { CharacterSet.uppercaseLetters.contains($0) } ?? false
        }
        let opening = 0..<window, closing = (words.count - window)..<words.count
        let middle = " " + words[window..<(words.count - window)].joined(separator: " ") + " "
        // A two-word image ("black glass", "the first chime") that opens the
        // story, returns at the end, and is (almost) absent between. Single
        // shared words are mostly the subject and don't separate the two.
        func pairs(_ r: Range<Int>) -> [String: Int] {
            var out: [String: Int] = [:]
            for i in r.dropLast() where content(words[i]) && content(words[i + 1]) && !capitalized(i + 1) {
                out[words[i] + " " + words[i + 1]] = out[words[i] + " " + words[i + 1]] ?? i
            }
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
            explanation: "The ending repeats \(list) from the opening, and the middle of the story barely uses it. This may be an intentional callback; consider whether the repetition gives the ending the degree of closure you want.",
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
        #"\b(?:was|is|had been) never (?:really )?about\b"#,
        #"\bmaybe that was (?:the|all the) (?:point|lesson|answer)\b"#,
        #"\bthat was the (?:point|lesson|thing about)\b"#,
        #"\b(?:some|the) things (?:you|we) (?:can't|can’t|cannot|don't|don’t|never)\b"#,
        #"\b(?:sometimes|perhaps) (?:the|a) \w+ (?:is|was) (?:just|only|simply)\b"#,
        #"\b(?:small|light|quiet) enough to (?:carry|hold|keep)\b"#,
    ].joined(separator: "|"))

    public func analyze(_ ctx: AnalysisContext) -> [WritingIssue] {
        let paras = StoryShape.paragraphs(ctx.prose)
        guard paras.count >= 4 else { return [] }
        // Include the last three paragraphs to catch a short closing line.
        let tail = Set(paras.suffix(3))
        return ctx.prose.sentences.filter { tail.contains($0.blockIndex) }.compactMap { s in
            let text = ctx.prose.maskedString(s.range)
            guard Self.patterns.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil else { return nil }
            return WritingIssue(
                ruleID: id, severity: .suggestion, category: category, message: "Stated moral",
                explanation: "This sentence may spell out a lesson near the ending. If the preceding scene already conveys it, consider letting the scene carry the meaning on its own.",
                ranges: [s.range], originalText: ctx.text(s.range))
        }
    }
}

// MARK: - Similes

/// A prompt to review a concentrated pattern of comparisons.
public struct SimileDensityRule: WritingRule {
    public let id = "story.similes"
    public let name = "Frequent similes"
    public let description = "A concentrated pattern of comparison phrases."
    public let category = AnnotationCategory.storyShape
    public var allowed = 3
    /// Per 1,000 words; a long story may carry a few more.
    public var perThousand = 4.0
    public init() {}

    // "like a", "as if", "as though", "as cold as a". The look-behind skips
    // the verb ("I'd like a", "would like the").
    static let simile = Lexicon.regex([
        #"(?<!\b(?:i|you|we|they|would|'d|’d|do|don't|don’t|didn't|didn’t|to|might|may) )\blike (?:a|an|the|some|someone|something)\b"#,
        #"\bas (?:if|though)\b"#,
        #"\bas (?!soon\b|far\b|long\b|well\b|much\b)\w+ as (?:a|an|the|if)\b"#,
    ].joined(separator: "|"))

    public func analyze(_ ctx: AnalysisContext) -> [WritingIssue] {
        let words = ctx.prose.words.count
        guard words >= 200 else { return [] }
        let matches = Self.simile.matches(in: ctx.prose.masked, range: NSRange(location: 0, length: ctx.prose.maskedNS.length))
        let limit = max(allowed, Int((Double(words) / 1000 * perThousand).rounded(.down)))
        guard matches.count > limit else { return [] }
        let ranges = matches.map { TextSpan($0.range) }
        return [WritingIssue(
            ruleID: id, severity: .info, category: category, message: "\(matches.count) possible similes",
            explanation: "This story has \(matches.count) comparison phrases in \(words.formatted()) words. Frequent comparisons can become a noticeable rhythm. Keep the images that suit the narrator and the scene.",
            ranges: ranges, originalText: ranges.map(ctx.text).joined(separator: " · "), metadata: ["count": "\(matches.count)"])]
    }
}
