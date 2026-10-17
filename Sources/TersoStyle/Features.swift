// SPDX-License-Identifier: AGPL-3.0-only
//
// Statistical style features. Each is a published, well-understood measure of
// register or style:
//   Biber, D. (1988). Variation across Speech and Writing. CUP.
//   Covington, M. & McFall, J. (2010). Cutting the Gordian knot: the moving-average
//     type–token ratio (MATTR). J. Quantitative Linguistics 17(2).
//   Björnsson, C. H. (1968). Läsbarhet (LIX: words longer than six letters).
//   Reinhart, A. et al. (2025). Do LLMs write like humans? Variation in grammatical
//     and rhetorical styles. PNAS 122(8).
import Foundation
import NaturalLanguage
import TersoCore

/// Prose prepared once for all features.
public struct StyleContext: Sendable {
    public let prose: ProseText
    public let words: [String]                 // lowercased, aligned with prose.words
    public let sentences: [ProseText.Sentence] // sentences of three or more words
    /// Letters-only tokens, hyphenated compounds split: the unit for word-length measures.
    public let letterWords: [String]
    /// The register's AI-lean word list (`ai_lexicon_1k`).
    public let aiLexicon: Set<String>

    public init(snapshot: DocumentSnapshot, aiLexicon: Set<String> = Lexicon.aiLean) {
        let prose = ProseText(snapshot)
        self.prose = prose
        self.words = prose.words.map { prose.string($0).lowercased() }
        self.sentences = prose.sentences.filter { $0.words.count > 2 }
        self.letterWords = words.flatMap { $0.split(separator: "-").map { $0.filter(\.isLetter) } }.filter { !$0.isEmpty }
        self.aiLexicon = aiLexicon
    }

    public var wordCount: Int { words.count }
    public func per1k(_ count: Int) -> Double { wordCount == 0 ? 0 : Double(count) / Double(wordCount) * 1000 }

    func matches(_ re: NSRegularExpression) -> [NSTextCheckingResult] {
        re.matches(in: prose.masked, range: NSRange(location: 0, length: prose.maskedNS.length))
    }
    func sentenceText(_ s: ProseText.Sentence) -> String { prose.maskedString(s.range) }
    func firstWord(_ s: ProseText.Sentence) -> String { s.words.first.map { prose.string($0).lowercased() } ?? "" }
}

/// One measurement before it is compared with a reference band.
public struct RawMeasurement: Sendable {
    public let value: Double
    public let count: Int?
    public let ranges: [TextSpan]
    public init(value: Double, count: Int? = nil, ranges: [TextSpan] = []) {
        self.value = value; self.count = count; self.ranges = ranges
    }
    static func rate(_ ranges: [TextSpan], _ ctx: StyleContext) -> RawMeasurement {
        RawMeasurement(value: ctx.per1k(ranges.count), count: ranges.count, ranges: ranges)
    }
}

public protocol StatisticalFeature: Sendable {
    var id: String { get }
    var name: String { get }
    var unit: String { get }
    /// What a high or low value means, in plain language.
    var interpretation: String { get }
    func measure(_ ctx: StyleContext) -> RawMeasurement
}

/// A feature defined by a closure.
public struct Feature: StatisticalFeature {
    public let id: String
    public let name: String
    public let unit: String
    public let interpretation: String
    let body: @Sendable (StyleContext) -> RawMeasurement

    public init(_ id: String, _ name: String, unit: String, _ interpretation: String, _ body: @escaping @Sendable (StyleContext) -> RawMeasurement) {
        self.id = id; self.name = name; self.unit = unit; self.interpretation = interpretation; self.body = body
    }
    public func measure(_ ctx: StyleContext) -> RawMeasurement { body(ctx) }
}

enum Lexical {
    static func re(_ p: String, _ o: NSRegularExpression.Options = [.caseInsensitive]) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: o)
    }
    /// Biber's nominalization suffixes.
    static let nominalSuffixes = ["tion", "tions", "sion", "sions", "ment", "ments", "ness", "nesses", "ity", "ities"]
    static let firstPerson: Set<String> = ["i", "me", "my", "mine", "myself", "we", "us", "our", "ours", "ourselves"]
    static let contraction = re(#"\p{L}+['’](?:s|re|ve|ll|d|m|t)\b"#)
    /// Sentence-initial linking adverbials (Biber's conjuncts) and transitions.
    static let connectives: [String] = [
        "however", "moreover", "furthermore", "additionally", "therefore", "thus", "consequently", "nevertheless",
        "nonetheless", "hence", "meanwhile", "instead", "overall", "ultimately", "importantly", "notably", "similarly",
        "likewise", "conversely", "accordingly", "finally", "in addition", "in contrast", "in conclusion", "in summary",
        "as a result", "for example", "for instance", "on the other hand", "that said", "in short",
    ]
    /// Coordinated series of three: "A, B(,) and/or C", each item one to three words.
    static let series = re(#"(\p{L}[\p{L}'-]*(?:\s\p{L}[\p{L}'-]*){0,2}),\s(\p{L}[\p{L}'-]*(?:\s\p{L}[\p{L}'-]*){0,2}),?\s(?:and|or)\s\p{L}"#)
    /// Words that begin a clause or phrase rather than a list item.
    static let nonItemStarts: Set<String> = ["because", "which", "who", "whom", "that", "when", "while", "if", "although", "though", "since",
                                             "so", "but", "and", "or", "the", "a", "an", "to", "of", "in", "on", "for", "with", "as", "where", "whether"]
    /// A clause-leading -ing word after a comma, semicolon, colon or dash.
    static let trailingIng = re(#"[,;:\x{2014}\x{2013}]\s+(\p{L}+ing)\b"#, [])
}

/// Published word lists, bundled from Quirón (see NOTICE). One or more words
/// per line; `#` starts a comment.
public enum Lexicon {
    public static func load(_ name: String) -> Set<String> {
        let base = name.hasSuffix(".txt") ? String(name.dropLast(4)) : name
        guard let url = Bundle.module.url(forResource: base, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Set(text.split(separator: "\n").flatMap { line in
            line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map {
                $0.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
            } ?? []
        })
    }
    /// AI-lean words for general (blog) prose.
    public static let aiLean = load("ai-lean")
    /// Words people use and assistant models under-use.
    public static let humanLean = load("human-lean")

    /// Letter runs of a word ("you're" → you, re), each counted as one token,
    /// so contractions and compounds are matched by their parts.
    static func pieces(_ word: String) -> [Substring] { word.split { !$0.isLetter } }
}

public enum FeatureCatalog {
    /// Features whose Terso definition differs from the procedure that produced
    /// the shipped reference parameters (sentence splitting, participle detection,
    /// connective list). Their values are shown, but no band is applied and they
    /// never count toward the signal level.
    public static let unbandedIDs: Set<String> = ["mean_sentence_len", "participles_1k", "connective_openers"]

    static func punctuation(_ id: String, _ name: String, _ interp: String, _ chars: Set<UInt16>) -> Feature {
        Feature(id, name, unit: "per 1k words", interp) { ctx in
            let ns = ctx.prose.maskedNS
            var ranges: [TextSpan] = []
            for i in 0..<ns.length where chars.contains(ns.character(at: i)) { ranges.append(TextSpan(location: i, length: 1)) }
            return .rate(ranges, ctx)
        }
    }

    static func wordRate(_ id: String, _ name: String, _ interp: String, _ test: @escaping @Sendable (String) -> Bool) -> Feature {
        Feature(id, name, unit: "per 1k words", interp) { ctx in
            .rate(ctx.words.indices.filter { test(ctx.words[$0]) }.map { ctx.prose.words[$0] }, ctx)
        }
    }

    /// Rate of letter runs found in a word list, per 1,000 letter runs.
    static func lexiconRate(_ ctx: StyleContext, _ list: Set<String>, ranges keepRanges: Bool) -> RawMeasurement {
        var total = 0, hits = 0
        var ranges: [TextSpan] = []
        for (i, w) in ctx.words.enumerated() {
            let p = Lexicon.pieces(w)
            total += p.count
            let n = p.filter { list.contains(String($0)) }.count
            hits += n
            if n > 0 && keepRanges { ranges.append(ctx.prose.words[i]) }
        }
        return RawMeasurement(value: total == 0 ? 0 : Double(hits) / Double(total) * 1000, count: hits, ranges: ranges)
    }

    static func stats(_ v: [Double]) -> (mean: Double, sd: Double) {
        guard !v.isEmpty else { return (0, 0) }
        let m = v.reduce(0, +) / Double(v.count)
        return (m, (v.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(v.count)).squareRoot())
    }

    public static let all: [any StatisticalFeature] = [
        Feature("cv_sentence_len", "Sentence-length variation", unit: "CV",
                "Standard deviation of sentence length over its mean. Human prose mixes short and long sentences; very even lengths read as mechanical, very uneven ones as overcorrected.") { ctx in
            let s = stats(ctx.sentences.map { Double($0.words.count) })
            return RawMeasurement(value: s.mean > 0 ? s.sd / s.mean : 0)
        },
        Feature("mean_sentence_len", "Mean sentence length", unit: "words", "Average words per sentence.") { ctx in
            RawMeasurement(value: stats(ctx.sentences.map { Double($0.words.count) }).mean)
        },
        Feature("long_words_1k", "Long words (7+ letters)", unit: "per 1k words",
                "Words longer than six letters (the LIX measure). Assistant prose leans on longer, Latinate vocabulary.") { ctx in
            let n = ctx.letterWords.filter { $0.count >= 7 }.count
            let ranges = ctx.words.indices.filter { ctx.words[$0].count >= 7 && !ctx.words[$0].contains("-") }.map { ctx.prose.words[$0] }
            return RawMeasurement(value: ctx.letterWords.isEmpty ? 0 : Double(n) / Double(ctx.letterWords.count) * 1000, count: n, ranges: ranges)
        },
        Feature("mean_word_len", "Mean word length", unit: "letters", "Average letters per word.") { ctx in
            let w = ctx.letterWords
            return RawMeasurement(value: w.isEmpty ? 0 : Double(w.reduce(0) { $0 + $1.count }) / Double(w.count))
        },
        wordRate("nominalizations_1k", "Nominalizations",
                 "Nouns derived from verbs and adjectives (-tion, -ment, -ness, -ity; Biber 1988). They make prose abstract and hide who acts; instruction-tuned models use more of them (Reinhart et al. 2025).") { w in
            w.count >= 7 && Lexical.nominalSuffixes.contains { w.hasSuffix($0) }
        },
        wordRate("ly_adverbs_1k", "-ly adverbs", "Adverbs ending in -ly.") { w in w.count >= 6 && w.hasSuffix("ly") },
        Feature("passive_1k", "Passive constructions", unit: "per 1k words",
                "Auxiliary plus past participle (Biber 1988). Human writers of informal registers use more of these than assistants.") { ctx in
            .rate(PassiveDetector.find(in: ctx.prose), ctx)
        },
        Feature("mattr50", "Lexical diversity (MATTR-50)", unit: "ratio",
                "Moving-average type–token ratio over 50-word windows (Covington & McFall 2010). Assistant text rarely repeats a word nearby.") { ctx in
            let w = ctx.words, n = 50
            guard w.count >= n else { return RawMeasurement(value: 0) }
            var counts: [String: Int] = [:]
            for x in w[0..<n] { counts[x, default: 0] += 1 }
            var sum = Double(counts.count)
            for i in n..<w.count {
                counts[w[i - n], default: 0] -= 1
                if counts[w[i - n]] == 0 { counts.removeValue(forKey: w[i - n]) }
                counts[w[i], default: 0] += 1
                sum += Double(counts.count)
            }
            return RawMeasurement(value: sum / Double(n) / Double(w.count - n + 1))
        },
        wordRate("first_person_1k", "First person",
                 "I, me, my, we, us, our. Assistants rarely write from a first-person position (Reinhart et al. 2025).") { Lexical.firstPerson.contains($0) },
        Feature("contractions_1k", "Contractions", unit: "per 1k words", "don't, it's, we'll… (Biber 1988).") { ctx in
            .rate(ctx.matches(Lexical.contraction).map { TextSpan($0.range) }, ctx)
        },
        Feature("questions_1k", "Questions", unit: "per 1k words", "Sentences ending in a question mark.") { ctx in
            .rate(ctx.sentences.filter { ctx.prose.string($0.range).hasSuffix("?") }.map(\.range), ctx)
        },
        Feature("repeated_openers", "Repeated sentence openers", unit: "per 100 sentences",
                "Consecutive sentences that start with the same word.") { ctx in
            let first = ctx.sentences.map(ctx.firstWord)
            let hits = first.indices.dropFirst().filter { first[$0] == first[$0 - 1] }
            return RawMeasurement(value: Double(hits.count) / Double(max(first.count - 1, 1)) * 100, count: hits.count,
                                  ranges: hits.compactMap { ctx.sentences[$0].words.first })
        },
        Feature("connective_openers", "Connective openers", unit: "% of sentences",
                "Sentences opening with a linking adverbial such as However, Moreover or As a result.") { ctx in
            let hits = ctx.sentences.filter { s in
                let t = ctx.sentenceText(s).lowercased()
                return Lexical.connectives.contains { c in t.hasPrefix(c) && t.dropFirst(c.count).first.map { !$0.isLetter } != false }
            }
            return RawMeasurement(value: Double(hits.count) / Double(max(ctx.sentences.count, 1)) * 100, count: hits.count,
                                  ranges: hits.compactMap { $0.words.first })
        },
        punctuation("commas_1k", "Commas", "Commas per 1,000 words.", [0x2C]),
        punctuation("semicolons_1k", "Semicolons", "Semicolons per 1,000 words.", [0x3B]),
        punctuation("em_dashes_1k", "Dashes", "Em and en dashes per 1,000 words.", [0x2014, 0x2013]),
        Feature("ai_lexicon_1k", "AI-lean words", unit: "per 1k words",
                "Words that assistant models over-use relative to human writers of this register (delve, pivotal, meticulous; murmured, blinked in fiction), from published word-frequency studies (Kobak et al. 2025; Juzek 2026). Replace one only where a plainer word says the same thing.") { ctx in
            lexiconRate(ctx, ctx.aiLexicon, ranges: true)
        },
        Feature("triads_1k", "Lists of three", unit: "per 1k words",
                "Coordinated series of three short items (“A, B and C”), a rhetorical habit of assistant prose.") { ctx in
            let ns = ctx.prose.maskedNS
            let hits = ctx.matches(Lexical.series).filter { m in
                let second = ns.substring(with: m.range(at: 2)).split(separator: " ").first.map { $0.lowercased() } ?? ""
                return !Lexical.nonItemStarts.contains(second)
            }
            return .rate(hits.map { TextSpan($0.range) }, ctx)
        },
        Feature("participles_1k", "Trailing participial clauses", unit: "per 1k words",
                "A present-participle clause tacked on after punctuation (“…, making it easy”). Instruction-tuned models use them two to five times as often as humans (Reinhart et al. 2025).") { ctx in
            let tagger = NLTagger(tagSchemes: [.lexicalClass])
            tagger.string = ctx.prose.masked
            let hits = ctx.matches(Lexical.trailingIng).compactMap { m -> TextSpan? in
                let r = m.range(at: 1)
                guard let range = Range(r, in: ctx.prose.masked) else { return nil }
                let (tag, _) = tagger.tag(at: range.lowerBound, unit: .word, scheme: .lexicalClass)
                return tag == .verb ? TextSpan(r) : nil
            }
            return .rate(hits, ctx)
        },
        Feature("plain_words_1k", "Plain words", unit: "per 1k words",
                "Everyday words people use and assistant models under-use (about, get, really, said, lot; Juzek 2026). A low rate reads as polished and impersonal. This is a rate, not a list to sprinkle in.") { ctx in
            lexiconRate(ctx, Lexicon.humanLean, ranges: false)
        },
        punctuation("parens_1k", "Parentheses", "Opening parentheses per 1,000 words.", [0x28]),
        Feature("para_words", "Words per paragraph", unit: "words", "Average paragraph length.") { ctx in
            let paragraphs = Set(ctx.sentences.map(\.blockIndex)).count
            return RawMeasurement(value: Double(ctx.wordCount) / Double(max(paragraphs, 1)))
        },
        Feature("headings_1k", "Headings", unit: "per 1k words", "Headings per 1,000 words.") { ctx in
            .rate(ctx.prose.headings.map(\.range), ctx)
        },
    ]
}
