// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import TersoCore

/// Everything a rule may look at: the snapshot and its segmented prose.
/// Rules are pure functions of this context; they never see the editor.
public struct AnalysisContext: Sendable {
    public let snapshot: DocumentSnapshot
    public let prose: ProseText
    public let science: ScientificDocumentModel

    public init(snapshot: DocumentSnapshot, profile: ScientificProfile = .general) {
        self.snapshot = snapshot
        let prose = ProseText(snapshot)
        self.prose = prose
        self.science = ScientificDocumentModel(snapshot: snapshot, prose: prose, profile: profile)
    }

    public func text(_ r: TextSpan) -> String { prose.string(r) }
}

public protocol WritingRule: Sendable {
    var id: String { get }
    var name: String { get }
    var description: String { get }
    var category: AnnotationCategory { get }
    func analyze(_ context: AnalysisContext) -> [WritingIssue]
}

// MARK: - Shared helpers

enum Lexicon {
    static func regex(_ p: String, _ o: NSRegularExpression.Options = [.caseInsensitive]) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: o)
    }

    /// Find whole-word phrase matches in the masked prose.
    static func find(_ phrases: [String], in prose: ProseText) -> [(TextSpan, String)] {
        let alternation = phrases.sorted { $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: $0).replacingOccurrences(of: " ", with: #"\s+"#) }
            .joined(separator: "|")
        let re = regex(#"(?<![\p{L}\p{N}'’])(?:"# + alternation + #")(?![\p{L}\p{N}])"#)
        return re.matches(in: prose.masked, range: NSRange(location: 0, length: prose.maskedNS.length)).map {
            (TextSpan($0.range), prose.maskedNS.substring(with: $0.range))
        }
    }

    static let stopwords: Set<String> = Set("""
    a an the and or but if then than so as at by for from in into of on onto to up with without about over under \
    is are was were be been being am do does did done have has had having it its it's this that these those there \
    here i me my we us our you your he him his she her they them their what which who whom whose when where why how \
    not no nor can could will would shall should may might must just also very more most less such same other each \
    all any both few many much some one two own only too out off again further once after before while because \
    through during above below between s t don't isn't aren't wasn't weren't i'm we're you're they're
    """.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init))
}

// MARK: - Sentence difficulty

/// Hemingway-style sentence difficulty: long sentences with a high reading
/// grade are hard, and very hard beyond a stricter threshold.
public struct SentenceDifficultyRule: WritingRule {
    public let id = "sentence.difficulty"
    public let name = "Hard-to-read sentences"
    public let description = "Long sentences with a high reading grade."
    public let category = AnnotationCategory.readability
    public var longWords = 25
    public var veryLongWords = 40
    public var hardGrade = 12.0
    public var veryHardGrade = 16.0

    public init() {}

    public func analyze(_ ctx: AnalysisContext) -> [WritingIssue] {
        var out: [WritingIssue] = []
        for s in ctx.prose.sentences where s.words.count >= 14 {
            let syl = s.words.reduce(0) { $0 + Readability.syllables(ctx.text($1)) }
            let grade = Readability.fleschKincaidGrade(words: s.words.count, sentences: 1, syllables: syl)
            let n = s.words.count
            let veryHard = n >= veryLongWords || grade >= veryHardGrade
            let hard = veryHard || n >= longWords || grade >= hardGrade
            guard hard else { continue }
            out.append(WritingIssue(
                ruleID: id,
                severity: veryHard ? .warning : .suggestion,
                category: veryHard ? .complexity : .readability,
                message: veryHard ? "Very hard to read" : "Hard to read",
                explanation: "\(n) words, reading grade \(Int(grade.rounded())). Long sentences ask the reader to hold several ideas at once. Consider splitting it or cutting what the sentence does not need.",
                ranges: [s.range], originalText: ctx.text(s.range),
                metadata: ["words": "\(n)", "grade": String(format: "%.1f", grade)]))
        }
        return out
    }
}

// MARK: - Passive voice

public struct PassiveVoiceRule: WritingRule {
    public let id = "style.passive"
    public let name = "Passive voice"
    public let description = "A form of 'to be' followed by a past participle."
    public let category = AnnotationCategory.passiveVoice

    public init() {}

    public func analyze(_ ctx: AnalysisContext) -> [WritingIssue] {
        let ns = ctx.prose.maskedNS
        return PassiveDetector.find(in: ctx.prose).map { span in
            let after = NSRange(location: span.upperBound, length: min(8, ns.length - span.upperBound))
            let byAgent = ns.substring(with: after).range(of: #"^\s+by\b"#, options: .regularExpression) != nil
            return WritingIssue(
                ruleID: id, severity: .suggestion, category: .passiveVoice,
                message: "Passive voice",
                explanation: byAgent
                    ? "The actor appears after “by”. An active sentence would name it first and is usually shorter."
                    : "The sentence does not say who acted. That can be deliberate; if the actor matters, name it.",
                ranges: [span], originalText: ctx.text(span))
        }
    }
}

// MARK: - Adverbs

public struct AdverbRule: WritingRule {
    public let id = "style.adverb"
    public let name = "Adverbs"
    public let description = "-ly adverbs that often weaken a verb."
    public let category = AnnotationCategory.adverbs
    static let re = Lexicon.regex(#"\b[A-Za-z]{3,}ly\b"#)
    /// Common -ly words that are not manner adverbs, or carry meaning.
    static let exceptions: Set<String> = Set("""
    only family early daily weekly monthly yearly likely unlikely reply apply supply rely ally italy july holy ugly \
    friendly lonely lovely silly belly jelly fly bully rally assembly anomaly butterfly curly elderly costly deadly \
    lively orderly timely underly jolly melancholy oily wholly firstly secondly thirdly finally namely respectively \
    accordingly previously currently recently initially eventually approximately exactly directly
    """.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init))

    public init() {}

    public func analyze(_ ctx: AnalysisContext) -> [WritingIssue] {
        let ns = ctx.prose.maskedNS
        let hits = Self.re.matches(in: ctx.prose.masked, range: NSRange(location: 0, length: ns.length))
            .filter { !Self.exceptions.contains(ns.substring(with: $0.range).lowercased()) }
        // One adverb is fine. Flag them only when they are dense.
        let density = Double(hits.count) / Double(max(ctx.prose.words.count, 1)) * 1000
        guard hits.count >= 2, density >= 8 else { return [] }
        return hits.map {
            WritingIssue(
                ruleID: id, severity: .info, category: .adverbs, message: "Adverb",
                explanation: "A stronger verb often does the adverb’s work. This text has \(Int(density.rounded())) -ly adverbs per 1,000 words.",
                ranges: [TextSpan($0.range)], originalText: ns.substring(with: $0.range),
                metadata: QuickFixes.metadata(replacements: nil, removable: true))
        }
    }
}

// MARK: - Phrase lists with replacements

struct PhraseEntry: Sendable {
    let phrase: String
    let consider: String?
}

protocol PhraseListRule: WritingRule {
    var entries: [PhraseEntry] { get }
    var severity: Severity { get }
    var message: String { get }
    /// Entries without a replacement can simply be deleted.
    var removable: Bool { get }
    func explanation(for entry: PhraseEntry) -> String
}

extension PhraseListRule {
    public func analyze(_ ctx: AnalysisContext) -> [WritingIssue] {
        let map = Dictionary(entries.map { ($0.phrase.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        return Lexicon.find(entries.map(\.phrase), in: ctx.prose).compactMap { range, text in
            let key = text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard let entry = map[key] else { return nil }
            return WritingIssue(
                ruleID: id, severity: severity, category: category, message: message,
                explanation: explanation(for: entry), ranges: [range], originalText: text,
                consider: entry.consider,
                metadata: QuickFixes.metadata(replacements: entry.consider, removable: removable && entry.consider == nil))
        }
    }
}

public struct QualifierRule: PhraseListRule {
    public let id = "style.qualifier"
    public let name = "Weak qualifiers"
    public let description = "Words that hedge or intensify without adding meaning."
    public let category = AnnotationCategory.filler
    let severity = Severity.info
    let message = "Qualifier"
    let removable = true
    let entries: [PhraseEntry] = [
        "very", "really", "quite", "rather", "somewhat", "fairly", "pretty much", "basically", "essentially",
        "actually", "literally", "totally", "extremely", "incredibly", "a bit", "a little", "kind of", "sort of",
        "I think that", "I believe that", "I feel that", "in my opinion", "arguably", "seemingly",
    ].map { PhraseEntry(phrase: $0, consider: nil) }
    public init() {}
    func explanation(for e: PhraseEntry) -> String {
        "“\(e.phrase)” softens or inflates the claim without adding information. Keep it only if the hedge is deliberate."
    }
}

public struct FillerPhraseRule: PhraseListRule {
    public let id = "style.filler"
    public let name = "Filler phrases"
    public let description = "Wordy phrases with shorter equivalents."
    public let category = AnnotationCategory.filler
    let severity = Severity.suggestion
    let message = "Wordy phrase"
    let removable = true
    let entries: [PhraseEntry] = [
        ("in order to", "to"), ("due to the fact that", "because"), ("owing to the fact that", "because"),
        ("the fact that", nil), ("at this point in time", "now"), ("at the present time", "now"),
        ("in the event that", "if"), ("for the purpose of", "to / for"), ("with regard to", "about"),
        ("with respect to", "about"), ("in regard to", "about"), ("in spite of the fact that", "although"),
        ("it is important to note that", nil), ("it is worth noting that", nil), ("it should be noted that", nil),
        ("needless to say", nil), ("as a matter of fact", "in fact"), ("in terms of", nil),
        ("a large number of", "many"), ("a majority of", "most"), ("is able to", "can"), ("are able to", "can"),
        ("has the ability to", "can"), ("in the process of", nil), ("each and every", "each / every"),
        ("first and foremost", "first"), ("at the end of the day", nil), ("the reason why is that", "because"),
        ("in close proximity to", "near"), ("prior to", "before"), ("subsequent to", "after"),
        ("on a daily basis", "daily"), ("until such time as", "until"), ("in light of the fact that", "because"),
    ].map { PhraseEntry(phrase: $0.0, consider: $0.1) }
    public init() {}
    func explanation(for e: PhraseEntry) -> String {
        if let c = e.consider { return "“\(e.phrase)” can usually be “\(c)”." }
        return "“\(e.phrase)” adds length without meaning. The sentence usually reads better without it."
    }
}

public struct ComplexWordRule: PhraseListRule {
    public let id = "complexity.word"
    public let name = "Complex words"
    public let description = "Words with simpler alternatives."
    public let category = AnnotationCategory.complexity
    let severity = Severity.info
    let message = "Simpler word available"
    let removable = false
    let entries: [PhraseEntry] = [
        ("utilize", "use"), ("utilizes", "uses"), ("utilization", "use"), ("facilitate", "help / ease"),
        ("commence", "begin"), ("terminate", "end"), ("endeavor", "try"), ("ascertain", "find out"),
        ("approximately", "about"), ("demonstrate", "show"), ("numerous", "many"), ("sufficient", "enough"),
        ("additional", "more"), ("assist", "help"), ("obtain", "get"), ("purchase", "buy"),
        ("in excess of", "more than"), ("methodology", "method"), ("leverage", "use"), ("optimal", "best"),
        ("individuals", "people"), ("subsequently", "later"), ("nevertheless", "still"), ("aforementioned", "this / these"),
        ("notwithstanding", "despite"), ("predominantly", "mostly"), ("heretofore", "until now"),
    ].map { PhraseEntry(phrase: $0.0, consider: $0.1) }
    public init() {}
    func explanation(for e: PhraseEntry) -> String {
        "“\(e.phrase)” has a plainer alternative: “\(e.consider ?? "")”. Use the plain word unless the precise one is needed."
    }
}

public struct MisusedWordRule: PhraseListRule {
    public let id = "misused.word"
    public let name = "Commonly misused"
    public let description = "Words and phrases often confused with a similar one."
    public let category = AnnotationCategory.misused
    let severity = Severity.suggestion
    let message = "Commonly misused"
    let removable = false
    /// Phrases only, never a lone word: "effect" and "affect" are both right
    /// somewhere, but "an affect on" almost never is.
    static let notes: [String: String] = [
        "comprised of": "The whole comprises its parts; “composed of” or “comprises” is the standard form.",
        "data is": "In scientific writing “data” is usually plural.",
        "data was": "In scientific writing “data” is usually plural.",
        "data shows": "In scientific writing “data” is usually plural.",
        "data suggests": "In scientific writing “data” is usually plural.",
        "different than": "“Different from” is the standard form in formal writing.",
        "very unique": "Unique has no degrees.",
        "most unique": "Unique has no degrees.",
        "the reason is because": "“Because” repeats “the reason”.",
        "principle investigator": "The lead researcher is the principal investigator.",
        "it's own": "“It’s” means “it is”; the possessive is “its”.",
    ]
    let entries: [PhraseEntry] = [
        ("comprised of", "composed of / comprises"), ("irregardless", "regardless"),
        ("could of", "could have"), ("should of", "should have"), ("would of", "would have"), ("must of", "must have"),
        ("data is", "data are"), ("data was", "data were"), ("data shows", "data show"), ("data suggests", "data suggest"),
        ("different than", "different from"), ("very unique", "unique"), ("most unique", "unique"),
        ("in regards to", "regarding"), ("alot", "a lot"),
        ("an affect on", "an effect on"), ("the affect of", "the effect of"), ("affect on", "effect on"),
        ("principle investigator", "principal investigator"), ("the reason is because", "the reason is that"),
        ("orientate", "orient"), ("per say", "per se"), ("et. al", "et al."),
        ("rather then", "rather than"), ("more then", "more than"), ("less then", "less than"),
        ("better then", "better than"), ("larger then", "larger than"), ("smaller then", "smaller than"),
        ("higher then", "higher than"), ("lower then", "lower than"), ("then expected", "than expected"),
        ("it's own", "its own"), ("insure that", "ensure that"),
    ].map { PhraseEntry(phrase: $0.0, consider: $0.1) }
    public init() {}
    func explanation(for e: PhraseEntry) -> String {
        let usual = "“\(e.phrase)” is often a slip for “\(e.consider ?? "")”."
        return Self.notes[e.phrase].map { usual + " " + $0 } ?? usual
    }
}

// MARK: - Loose pronouns

/// A sentence that opens with "This", "It", "These"… followed straight by a
/// verb leaves the reader to work out what the pronoun refers to.
public struct LoosePronounRule: WritingRule {
    public let id = "clarity.loosePronoun"
    public let name = "Loose pronouns"
    public let description = "Sentences that open with a pronoun whose referent is unclear."
    public let category = AnnotationCategory.loosePronouns
    static let pronouns: Set<String> = ["this", "that", "these", "those", "it"]
    static let verbs: Set<String> = Set("""
    is was are were has have had can could will would may might must shows show showed suggests suggest suggested     means meant indicates indicate indicated implies imply implied demonstrates demonstrate demonstrated leads lead led     results result resulted allows allow allowed makes make made gives give gave provides provide provided explains     explain explained confirms confirm confirmed highlights highlight highlighted reflects reflect reflected seems     seem seemed appears appear appeared becomes become became causes cause caused requires require required enables     enable enabled ensures ensure ensured
    """.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init))
    public init() {}

    public func analyze(_ ctx: AnalysisContext) -> [WritingIssue] {
        ctx.prose.sentences.compactMap { s in
            guard s.words.count >= 3 else { return nil }
            let first = ctx.text(s.words[0]).lowercased(), second = ctx.text(s.words[1]).lowercased()
            guard Self.pronouns.contains(first), Self.verbs.contains(second) else { return nil }
            let r = s.words[0]
            return WritingIssue(
                ruleID: id, severity: .suggestion, category: .loosePronouns, message: "Loose pronoun",
                explanation: "“\(ctx.text(r))” could point at several things in the previous sentence. Naming it (“This result…”, “The fit…”) tells the reader which.",
                ranges: [r], originalText: ctx.text(r))
        }
    }
}

// MARK: - Repetition

public struct RepeatedWordRule: WritingRule {
    public let id = "repetition.word"
    public let name = "Repeated words"
    public let description = "Accidental doubles and content words repeated close together."
    public let category = AnnotationCategory.repetition
    public var window = 40
    public init() {}

    public func analyze(_ ctx: AnalysisContext) -> [WritingIssue] {
        var out: [WritingIssue] = []
        let words = ctx.prose.words
        let lower = words.map { ctx.text($0).lowercased() }
        // Doubled words: "the the".
        for i in 1..<max(words.count, 1) where lower[i] == lower[i - 1] && !lower[i].allSatisfy(\.isNumber) {
            let gap = words[i].location - words[i - 1].upperBound
            guard gap <= 2, lower[i] != "that", lower[i] != "had" else { continue }
            let r = TextSpan(location: words[i - 1].location, length: words[i].upperBound - words[i - 1].location)
            // A doubled word is a lexical illusion: the eye skips the second copy.
            out.append(WritingIssue(ruleID: id, severity: .warning, category: .lexicalIllusions, message: "Doubled word",
                                    explanation: "“\(lower[i])” appears twice in a row.", ranges: [r], originalText: ctx.text(r),
                                    metadata: QuickFixes.metadata(replacements: ctx.text(words[i - 1]))))
        }
        // Content words (6+ letters) used three times within a short window.
        var last: [String: [Int]] = [:]
        var reported: Set<String> = []
        for (i, w) in lower.enumerated() where w.count >= 6 && !Lexicon.stopwords.contains(w) {
            var idx = (last[w] ?? []).filter { i - $0 <= window }
            idx.append(i)
            last[w] = idx
            if idx.count >= 3, !reported.contains("\(w)#\(idx[0])") {
                reported.insert("\(w)#\(idx[0])")
                out.append(WritingIssue(
                    ruleID: id, severity: .info, category: .repetition, message: "Repeated word",
                    explanation: "“\(w)” appears \(idx.count) times within \(window) words. Repetition can be emphasis; if it is not, vary or restructure.",
                    ranges: idx.map { words[$0] }, originalText: w, metadata: ["word": w]))
                last[w] = []
            }
        }
        return out
    }
}

public struct RepeatedPhraseRule: WritingRule {
    public let id = "repetition.phrase"
    public let name = "Repeated phrases"
    public let description = "Multi-word phrases used more than once."
    public let category = AnnotationCategory.repetition
    public init() {}

    public func analyze(_ ctx: AnalysisContext) -> [WritingIssue] {
        let words = ctx.prose.words
        guard words.count >= 6 else { return [] }
        let lower = words.map { ctx.text($0).lowercased() }
        // Sentence index per word, so n-grams never cross a sentence boundary.
        var sentenceOf = [Int](repeating: 0, count: words.count)
        var wi = 0
        for (si, s) in ctx.prose.sentences.enumerated() {
            for _ in s.words where wi < words.count { sentenceOf[wi] = si; wi += 1 }
        }
        var claimed = Set<Int>() // word indices already inside a reported longer phrase
        var out: [WritingIssue] = []
        for n in stride(from: 6, through: 3, by: -1) {
            var grams: [String: [Int]] = [:]
            for i in 0...(words.count - n) where sentenceOf[i] == sentenceOf[i + n - 1] {
                let slice = lower[i..<(i + n)]
                let content = slice.filter { !Lexicon.stopwords.contains($0) }
                guard content.count >= 1, slice.filter({ Lexicon.stopwords.contains($0) }).count < n else { continue }
                grams[slice.joined(separator: " "), default: []].append(i)
            }
            for (gram, starts) in grams.sorted(by: { $0.value[0] < $1.value[0] }) {
                // Drop overlapping occurrences and ones inside a longer reported phrase.
                var picked: [Int] = []
                for s in starts where picked.last.map({ s >= $0 + n }) ?? true {
                    if (s..<(s + n)).allSatisfy({ !claimed.contains($0) }) { picked.append(s) }
                }
                guard picked.count >= 2 else { continue }
                picked.forEach { s in (s..<(s + n)).forEach { claimed.insert($0) } }
                let ranges = picked.map { TextSpan(location: words[$0].location, length: words[$0 + n - 1].upperBound - words[$0].location) }
                out.append(WritingIssue(
                    ruleID: id, severity: .suggestion, category: .repetition, message: "Repeated phrase",
                    explanation: "“\(gram)” appears \(picked.count) times. Each occurrence is highlighted.",
                    ranges: ranges, originalText: gram, metadata: ["count": "\(picked.count)"]))
            }
        }
        return out
    }
}

// MARK: - Rhythm and paragraphs

public struct SentenceVariationRule: WritingRule {
    public let id = "readability.rhythm"
    public let name = "Sentence rhythm"
    public let description = "Paragraphs whose sentences are all about the same length."
    public let category = AnnotationCategory.rhythm
    public init() {}

    public func analyze(_ ctx: AnalysisContext) -> [WritingIssue] {
        ctx.prose.blocks.indices.compactMap { bi in
            let s = ctx.prose.sentences(inBlock: bi)
            guard s.count >= 4 else { return nil }
            let lens = s.map { Double($0.words.count) }
            let mean = lens.reduce(0, +) / Double(lens.count)
            let sd = (lens.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(lens.count)).squareRoot()
            guard mean > 0, sd / mean < 0.2 else { return nil }
            let r = ctx.prose.blocks[bi].range
            return WritingIssue(
                ruleID: id, severity: .info, category: .rhythm, message: "Monotone rhythm",
                explanation: "All \(s.count) sentences here run \(Int(lens.min()!))–\(Int(lens.max()!)) words. Varying length gives the reader places to rest.",
                ranges: [r], originalText: ctx.text(r), metadata: ["cv": String(format: "%.2f", sd / mean)])
        }
    }
}

public struct ParagraphLengthRule: WritingRule {
    public let id = "readability.paragraph"
    public let name = "Long paragraphs"
    public let description = "Paragraphs over 150 words."
    public let category = AnnotationCategory.readability
    public var maxWords = 150
    public init() {}

    public func analyze(_ ctx: AnalysisContext) -> [WritingIssue] {
        ctx.prose.blocks.indices.compactMap { bi in
            let n = ctx.prose.sentences(inBlock: bi).reduce(0) { $0 + $1.words.count }
            guard n > maxWords else { return nil }
            let r = ctx.prose.blocks[bi].range
            return WritingIssue(
                ruleID: id, severity: .info, category: .readability, message: "Long paragraph",
                explanation: "\(n) words. A break at the turn in the argument would help the reader see its structure.",
                ranges: [r], originalText: ctx.text(r), metadata: ["words": "\(n)"])
        }
    }
}

// MARK: - Optional advice (off by default)
//
// Both follow Quirón by ilien (https://github.com/ilien-dev/quiron, AGPL-3.0):
// references/word-choice.md for sincerity markers, the A1c review item of
// scripts/audit.py for negated setups. The code is Terso's own.

/// Words that announce sincerity instead of showing it. Assistant prose leans on
/// them; a writer who means the opinion can simply state it.
public struct SincerityMarkerRule: PhraseListRule {
    public let id = "style.sincerity"
    public let name = "Sincerity markers"
    public let description = "Honestly, genuinely, frankly, to be honest, truly."
    public let category = AnnotationCategory.style
    let severity = Severity.info
    let message = "Sincerity marker"
    let removable = true
    let entries: [PhraseEntry] = ["honestly", "genuinely", "frankly", "to be honest", "truly"]
        .map { PhraseEntry(phrase: $0, consider: nil) }
    public init() {}
    func explanation(for e: PhraseEntry) -> String {
        "“\(e.phrase)” vouches for the sentence instead of letting it stand. Assistant models use these words far more than people do (on Quirón’s run, “genuinely” was in 1% of human blog posts and half of Claude Sonnet’s). State the opinion and leave its sincerity alone, unless the word is doing real work."
    }
}

/// A short "X isn't Y." sentence that opens a paragraph or sets up a reframe
/// ("It's Z."). Only ever a question for the writer: no fix is offered, because
/// rewriting these mechanically made prose read more machine-like to blind
/// judges (Quirón, references/numbers.md).
public struct NegatedSetupRule: WritingRule {
    public let id = "style.negatedSetup"
    public let name = "Negated setups"
    public let description = "Short “X isn’t Y.” sentences before the real point. Review only; never fixed automatically."
    public let category = AnnotationCategory.style
    public init() {}

    static let negation = Lexicon.regex(#"\b(?:isn['’]t|wasn['’]t|aren['’]t|weren['’]t|is not|was not|are not|were not)\b"#)
    static let skip = Lexicon.regex(#"\b(?:but|because|if|when|unless|so)\b"#)
    static let reframe = Lexicon.regex(#"^(?:it['’]s|it is|it was|that['’]s|that is|this is|what |the (?:real|actual|point|answer)|instead|rather)"#)
    static let maxWords = 12

    public func analyze(_ ctx: AnalysisContext) -> [WritingIssue] {
        let sentences = ctx.prose.sentences
        var out: [WritingIssue] = []
        for (i, s) in sentences.enumerated() {
            let text = ctx.text(s.range).trimmingCharacters(in: .whitespacesAndNewlines)
            let all = NSRange(location: 0, length: (text as NSString).length)
            guard s.words.count <= Self.maxWords, text.hasSuffix("."),
                  Self.negation.firstMatch(in: text, range: all) != nil,
                  Self.skip.firstMatch(in: text, range: all) == nil else { continue }
            let opens = i == 0 || sentences[i - 1].blockIndex != s.blockIndex
            let next = i + 1 < sentences.count && sentences[i + 1].blockIndex == s.blockIndex
                ? ctx.text(sentences[i + 1].range).trimmingCharacters(in: .whitespacesAndNewlines) : ""
            let reframed = Self.reframe.firstMatch(in: next, range: NSRange(location: 0, length: (next as NSString).length)) != nil
            guard opens || reframed else { continue }
            let place = opens ? "It opens the paragraph, where the real point should be." : "It sits right before the sentence that makes the real point."
            out.append(WritingIssue(
                ruleID: id, severity: .info, category: category, message: "Negated setup",
                explanation: "\(place) Denying something nobody said can make the next sentence sound bigger than it is. A short “X isn’t Y.” like this was in 31% of assistant blog posts and 7% of human ones on Quirón’s held-out run. Often it is the right sentence; you decide.",
                ranges: [s.range], originalText: text))
        }
        return out
    }
}
