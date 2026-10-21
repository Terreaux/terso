// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import NaturalLanguage
import TersoCore
import TersoAnalysis
import TersoStyle

/// Immutable measurements and UTF-16 navigation targets for one document revision.
struct DocumentStatisticsSnapshot: Sendable {
    let documentID: UUID
    let revision: DocumentRevision
    let documentName: String
    let statistics: DocumentStatistics
    let languageCode: String?
    let readabilityAvailable: Bool
    let sentences: [StatisticsSentence]
    let sentenceBuckets: [SentenceLengthBucket]
    let paragraphs: [StatisticsParagraph]
    let sentenceLengths: LengthStatistics
    let paragraphLengths: LengthStatistics
    let readabilityWindows: [StatisticsReadabilityWindow]
    let readabilityUnavailableReason: String?
    let complexPassages: [StatisticsComplexPassage]
    let complexity: StatisticsComplexityIndicators
    let vocabulary: StatisticsVocabulary
    let styleSummary: StatisticsStyleSummary?
    /// Daily typing totals are not document insertion provenance. No activity is fabricated.
    let activity: DocumentStatisticsActivity? = nil

    var longestSentence: StatisticsSentence? { sentences.max { $0.wordCount < $1.wordCount } }
    var longestParagraph: StatisticsParagraph? { paragraphs.max { $0.wordCount < $1.wordCount } }
    var shortestParagraph: StatisticsParagraph? { paragraphs.min { $0.wordCount < $1.wordCount } }
}

struct StatisticsSentence: Identifiable, Sendable {
    let id: Int
    let range: TextSpan
    let wordCount: Int
    let preview: String
}

struct SentenceLengthBucket: Identifiable, Sendable {
    let id: Int
    let label: String
    let sentenceIndices: [Int]
    let fraction: Double
    var count: Int { sentenceIndices.count }
}

struct StatisticsParagraph: Identifiable, Sendable {
    let id: Int
    let range: TextSpan
    let wordCount: Int
    let sentenceCount: Int
    let gradeLevel: Double?
    let styleFindingCount: Int
}

struct LengthStatistics: Sendable {
    let mean: Double
    let median: Double
    let p90: Double
    let standardDeviation: Double
    var coefficientOfVariation: Double { mean > 0 ? standardDeviation / mean : 0 }

    init(_ values: [Int]) {
        guard !values.isEmpty else {
            mean = 0; median = 0; p90 = 0; standardDeviation = 0
            return
        }
        let sorted = values.sorted()
        mean = Double(values.reduce(0, +)) / Double(values.count)
        let middle = sorted.count / 2
        median = sorted.count.isMultiple(of: 2)
            ? Double(sorted[middle - 1] + sorted[middle]) / 2 : Double(sorted[middle])
        // Nearest-rank percentile: a measured sentence length, including for tiny samples.
        p90 = Double(sorted[max(0, Int(ceil(Double(sorted.count) * 0.9)) - 1)])
        let average = mean
        standardDeviation = sqrt(values.reduce(0.0) { $0 + pow(Double($1) - average, 2) } / Double(values.count))
    }
}

struct StatisticsReadabilityWindow: Identifiable, Sendable {
    let id: Int
    let range: TextSpan
    let words: Int
    let sentences: Int
    let gradeLevel: Double
    let readingEase: Double
}

struct StatisticsComplexPassage: Identifiable, Sendable {
    var id: TextSpan { range }
    let range: TextSpan
    let preview: String
    let gradeLevel: Double
}

struct StatisticsComplexityIndicators: Sendable {
    let difficultSentences: Int
    let complexWords: Int
    let passiveConstructions: Int
}

struct StatisticsVocabulary: Sendable {
    let available: Bool
    let unavailableReason: String?
    let uniqueWords: Int
    let averageWordLength: Double
    /// Existing TersoStyle MATTR-50; nil below its fixed 50-token sample size.
    let mattr50: Double?
    let repeatedWords: [StatisticsRepetition]
    let repeatedOpenings: [StatisticsRepetition]
}

struct StatisticsRepetition: Identifiable, Sendable {
    var id: String { text }
    let text: String
    let ranges: [TextSpan]
    let relativeFrequency: Double
    var count: Int { ranges.count }
}

struct StatisticsStyleSummary: Sendable {
    let level: SignalLevel
    let count: Int
    let ranges: [TextSpan]
}

/// Optional boundary for reliable per-document events, when the app records them.
struct DocumentStatisticsActivity: Sendable {
    struct Insertions: Sendable {
        let keyboard: Int
        let paste: Int
        let alternativeInput: Int
        let unknown: Int
    }
    let insertions: Insertions
}

struct DocumentGoalProgress: Sendable {
    let current: Int
    let target: Int
    var fraction: Double { Double(current) / Double(target) }
    var remaining: Int { max(0, target - current) }
    var exceeded: Int { max(0, current - target) }
    init?(words: Int, target: Int?) {
        guard let target, target > 0 else { return nil }
        current = max(0, words); self.target = target
    }
}

/// Extends the existing analysis pass; never tokenizes in a view or touches the editor.
enum DocumentStatisticsAggregator {
    static func aggregate(
        documentID: UUID, snapshot: DocumentSnapshot, prose: ProseText,
        local: LocalAnalysisResult? = nil, style: StyleReport? = nil
    ) -> DocumentStatisticsSnapshot {
        // Cached analysis from an older revision must never enter this snapshot.
        let local = local.flatMap { $0.revision == snapshot.revision ? $0 : nil }
        let style = style.flatMap { $0.revision == snapshot.revision ? $0 : nil }
        let statistics = local?.statistics ?? DocumentStatistics(prose: prose)
        let ns = prose.original as NSString
        let words = prose.words.map { ns.substring(with: $0.nsRange).lowercased() }
        let recognizer = NLLanguageRecognizer()
        // Sample prose sentences, retaining punctuation and case: a bag of
        // lowercased words can confuse language recognition on repetitive prose.
        // Excluded preambles/code never consume this bounded sample budget.
        let masked = prose.maskedNS
        var languageSample = ""
        var remaining = 12_000
        for sentence in prose.sentences where remaining > 0 {
            let range = masked.rangeOfComposedCharacterSequences(for: NSRange(
                location: sentence.range.location, length: min(sentence.range.length, remaining)))
            languageSample += masked.substring(with: range) + " "
            remaining -= range.length + 1
        }
        recognizer.processString(languageSample)
        let english = recognizer.dominantLanguage == .english
        let syllables = words.map(Readability.syllables)
        var wordSyllables: [TextSpan: Int] = [:]
        for (index, range) in prose.words.enumerated() { wordSyllables[range] = syllables[index] }
        var blockWords = Array(repeating: 0, count: prose.blocks.count)
        var blockSentences = blockWords
        var blockSyllables = blockWords
        var sentenceSyllables: [Int] = []
        var indices = Array(repeating: [Int](), count: 6)
        var sentences: [StatisticsSentence] = []
        for (index, sentence) in prose.sentences.enumerated() {
            let count = sentence.words.count
            let syl = sentence.words.reduce(0) { $0 + (wordSyllables[$1] ?? 0) }
            sentenceSyllables.append(syl)
            blockWords[sentence.blockIndex] += count
            blockSentences[sentence.blockIndex] += 1
            blockSyllables[sentence.blockIndex] += syl
            indices[min(5, max(0, (count - 1) / 10))].append(index)
            sentences.append(StatisticsSentence(id: index, range: sentence.range, wordCount: count,
                                                 preview: preview(sentence.range, in: ns)))
        }
        let labels = ["1–10", "11–20", "21–30", "31–40", "41–50", "51+"]
        let buckets = indices.enumerated().map { index, hits in
            SentenceLengthBucket(id: index, label: labels[index], sentenceIndices: hits,
                                 fraction: Double(hits.count) / Double(max(1, sentences.count)))
        }
        let styleRanges = style?.measurements.filter(\.onAISide).flatMap(\.contributingRanges) ?? []
        let findingCounts = paragraphFindingCounts(blocks: prose.blocks, ranges: styleRanges)
        let paragraphs = prose.blocks.enumerated().map { index, block in
            StatisticsParagraph(id: index, range: block.range, wordCount: blockWords[index],
                sentenceCount: blockSentences[index],
                gradeLevel: english && blockWords[index] >= 150 && blockSentences[index] >= 2
                    ? max(0, Readability.fleschKincaidGrade(words: blockWords[index], sentences: blockSentences[index], syllables: blockSyllables[index])) : nil,
                styleFindingCount: findingCounts[index])
        }
        let windows = english ? readabilityWindows(prose: prose, syllables: sentenceSyllables) : []
        let readabilityReason: String? = !english
            ? "Reading-level distributions currently support English prose."
            : windows.isEmpty ? "At least 150 prose words and two sentences are needed for a reading-level sample." : nil
        let complex = complexPassages(local: local, statistics: statistics, ns: ns, english: english)
        let vocabulary = vocabulary(prose: prose, words: words, style: style, english: english)
        let summary = style.flatMap { report -> StatisticsStyleSummary? in
            guard let level = report.summary.level else { return nil }
            return StatisticsStyleSummary(level: level, count: report.summary.aiSideCount, ranges: styleRanges)
        }
        return DocumentStatisticsSnapshot(documentID: documentID, revision: snapshot.revision,
            documentName: snapshot.fileName ?? "Untitled", statistics: statistics,
            languageCode: recognizer.dominantLanguage?.rawValue, readabilityAvailable: english, sentences: sentences,
            sentenceBuckets: buckets, paragraphs: paragraphs,
            sentenceLengths: LengthStatistics(sentences.map(\.wordCount)),
            paragraphLengths: LengthStatistics(blockWords), readabilityWindows: windows,
            readabilityUnavailableReason: readabilityReason, complexPassages: complex,
            complexity: StatisticsComplexityIndicators(
                difficultSentences: local?.issues.filter { $0.ruleID == "sentence.difficulty" }.count ?? 0,
                complexWords: local?.issues.filter { $0.ruleID == "complexity.word" }.count ?? 0,
                passiveConstructions: local?.issues.filter { $0.ruleID == "style.passive" }.count ?? 0),
            vocabulary: vocabulary, styleSummary: summary)
    }

    private static func preview(_ range: TextSpan, in ns: NSString) -> String {
        // Bound the copied text even for a pathological sentence/paragraph.
        let bounded = NSRange(location: range.location, length: min(range.length, 180))
        let composed = ns.rangeOfComposedCharacterSequences(for: bounded)
        return ns.substring(with: composed).replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines) + (range.length > 180 ? "…" : "")
    }

    private static func paragraphFindingCounts(blocks: [ProseText.Block], ranges: [TextSpan]) -> [Int] {
        var counts = Array(repeating: 0, count: blocks.count)
        for range in ranges {
            var lower = 0, upper = blocks.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if blocks[middle].range.upperBound <= range.location { lower = middle + 1 } else { upper = middle }
            }
            while lower < blocks.count && blocks[lower].range.location < range.upperBound {
                counts[lower] += 1; lower += 1
            }
        }
        return counts
    }

    private static func readabilityWindows(prose: ProseText, syllables: [Int]) -> [StatisticsReadabilityWindow] {
        struct Sample { var start: Int; var end: Int; var words: Int; var sentences: Int; var syllables: Int }
        var samples: [Sample] = []
        var current: Sample?
        for (index, sentence) in prose.sentences.enumerated() {
            if current == nil { current = Sample(start: sentence.range.location, end: sentence.range.upperBound, words: 0, sentences: 0, syllables: 0) }
            current?.end = sentence.range.upperBound
            current?.words += sentence.words.count
            current?.sentences += 1
            current?.syllables += syllables[index]
            let endOfBlock = index + 1 == prose.sentences.count || prose.sentences[index + 1].blockIndex != sentence.blockIndex
            // Prefer paragraph boundaries around 180 words; split unusually long blocks at sentence boundaries.
            if let sample = current, sample.words >= 180 && sample.sentences >= 2 && (endOfBlock || sample.words >= 240) {
                samples.append(sample); current = nil
            }
        }
        if let tail = current {
            if tail.words >= 150 && tail.sentences >= 2 { samples.append(tail) }
            else if !samples.isEmpty {
                samples[samples.count - 1].end = tail.end
                samples[samples.count - 1].words += tail.words
                samples[samples.count - 1].sentences += tail.sentences
                samples[samples.count - 1].syllables += tail.syllables
            }
        }
        return samples.enumerated().map { index, sample in
            StatisticsReadabilityWindow(id: index, range: TextSpan(location: sample.start, length: sample.end - sample.start),
                words: sample.words, sentences: sample.sentences,
                gradeLevel: max(0, Readability.fleschKincaidGrade(words: sample.words, sentences: sample.sentences, syllables: sample.syllables)),
                readingEase: Readability.fleschReadingEase(words: sample.words, sentences: sample.sentences, syllables: sample.syllables))
        }
    }

    private static func complexPassages(local: LocalAnalysisResult?, statistics: DocumentStatistics, ns: NSString, english: Bool) -> [StatisticsComplexPassage] {
        guard english, let baseline = statistics.gradeLevel else { return [] }
        var seen = Set<TextSpan>()
        var seenText = Set<String>()
        return (local?.issues ?? []).filter { $0.ruleID == "sentence.difficulty" }.compactMap { issue in
            guard let range = issue.ranges.first, range.location >= 0, range.upperBound <= ns.length,
                  let gradeText = issue.metadata["grade"], let grade = Double(gradeText), grade >= baseline + 2,
                  seen.insert(range).inserted else { return nil }
            let textKey = issue.originalText.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard seenText.insert(textKey).inserted else { return nil }
            return StatisticsComplexPassage(range: range, preview: preview(range, in: ns), gradeLevel: grade)
        }.sorted { $0.gradeLevel > $1.gradeLevel }.prefix(8).map { $0 }
    }

    private static func vocabulary(prose: ProseText, words: [String], style: StyleReport?, english: Bool) -> StatisticsVocabulary {
        guard english else {
            return StatisticsVocabulary(available: false,
                unavailableReason: words.isEmpty ? "Start writing to see vocabulary statistics." : "Vocabulary analysis currently supports English prose.",
                uniqueWords: 0, averageWordLength: 0, mattr50: nil, repeatedWords: [], repeatedOpenings: [])
        }
        // Same normalization as StyleContext: letters only, hyphenated compounds split.
        let averageWordLength: Double
        if let measured = style?.measurements.first(where: { $0.featureID == "mean_word_len" })?.value {
            averageWordLength = measured
        } else {
            let letterWords = words.flatMap { $0.split(separator: "-").map { $0.filter(\.isLetter) } }.filter { !$0.isEmpty }
            averageWordLength = letterWords.isEmpty ? 0 : Double(letterWords.reduce(0) { $0 + $1.count }) / Double(letterWords.count)
        }
        var occurrences: [String: [TextSpan]] = [:]
        for (index, word) in words.enumerated() where word.contains(where: \.isLetter) {
            occurrences[word, default: []].append(prose.words[index])
        }
        var repeated: [StatisticsRepetition] = []
        let wordTotal = Double(max(1, words.count))
        for (word, ranges) in occurrences where ranges.count >= 2 && !WritingAnalyzer.contentStopwords.contains(word) {
            repeated.append(StatisticsRepetition(text: word, ranges: ranges, relativeFrequency: Double(ranges.count) / wordTotal))
        }
        repeated.sort(by: repetitionPrecedes)
        repeated = Array(repeated.prefix(15))
        var openings: [String: [TextSpan]] = [:]
        for sentence in prose.sentences where sentence.words.count >= 3 {
            let first = sentence.words.prefix(2)
            let phrase = first.map { prose.string($0).lowercased() }.joined(separator: " ")
            openings[phrase, default: []].append(sentence.range)
        }
        var repeatedOpenings: [StatisticsRepetition] = []
        let sentenceTotal = Double(max(1, prose.sentences.count))
        for (phrase, ranges) in openings where ranges.count >= 3 {
            repeatedOpenings.append(StatisticsRepetition(text: phrase, ranges: ranges, relativeFrequency: Double(ranges.count) / sentenceTotal))
        }
        repeatedOpenings.sort(by: repetitionPrecedes)
        repeatedOpenings = Array(repeatedOpenings.prefix(8))
        // The normal pipeline supplies this already calculated feature. Never introduce another diversity formula.
        let mattr = words.count >= 50 ? style?.measurements.first { $0.featureID == "mattr50" }?.value : nil
        return StatisticsVocabulary(available: true, unavailableReason: nil, uniqueWords: Set(words).count,
            averageWordLength: averageWordLength,
            mattr50: mattr, repeatedWords: repeated, repeatedOpenings: repeatedOpenings)
    }

    private static func repetitionPrecedes(_ lhs: StatisticsRepetition, _ rhs: StatisticsRepetition) -> Bool {
        if lhs.count == rhs.count { return lhs.text < rhs.text }
        return lhs.count > rhs.count
    }

}
