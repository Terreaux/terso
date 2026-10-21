// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
import TersoCore
import TersoAnalysis
import TersoStyle
@testable import TersoApp

@Suite struct DocumentStatisticsTests {
    private func aggregate(_ text: String, name: String = "sample.md", revision: UInt64 = 1) -> DocumentStatisticsSnapshot {
        let source = DocumentSnapshot(revision: DocumentRevision(revision), text: text, fileName: name)
        return DocumentStatisticsAggregator.aggregate(documentID: UUID(), snapshot: source, prose: ProseText(source))
    }

    @Test func countsFollowExistingProseSemantics() {
        let text = """
        # A heading that does not enter prose statistics

        The quick brown fox jumps. A patient dog watches.

        - First useful item.
        - Second useful item.

        ```swift
        let notProse = "six unrelated words should be excluded"
        ```

        Measurements of $E = mc^2$ agree with the model at 1.5 percent.
        """
        let source = DocumentSnapshot(revision: DocumentRevision(1), text: text, fileName: "sample.md")
        let prose = ProseText(source)
        let measured = aggregate(text)
        #expect(measured.statistics == DocumentStatistics(prose: prose))
        #expect(measured.statistics.paragraphs == 4)
        #expect(measured.statistics.sentences == prose.sentences.count)
        #expect(measured.paragraphs.map(\.wordCount).reduce(0, +) == measured.statistics.words)
        #expect(measured.sentences.map(\.wordCount).reduce(0, +) == measured.statistics.words)
        #expect(!measured.sentences.contains { $0.preview.contains("notProse") })
    }

    @Test func emptyAndTinyDocumentsRemainFinite() {
        for text in ["", "   \n", "Hello", "A short sentence.", "# Heading only"] {
            let measured = aggregate(text)
            #expect(measured.sentenceLengths.mean.isFinite)
            #expect(measured.sentenceLengths.coefficientOfVariation.isFinite)
            #expect(measured.paragraphLengths.standardDeviation.isFinite)
            #expect(measured.readabilityWindows.isEmpty)
            #expect(measured.readabilityUnavailableReason != nil)
            #expect(measured.vocabulary.mattr50 == nil)
            #expect(measured.activity == nil)
        }
        #expect(aggregate("").statistics.words == 0)
        #expect(aggregate("Hello").statistics.words == 1)
        #expect(aggregate("Hello").statistics.sentences == 1)
        #expect(aggregate("Hello").statistics.paragraphs == 1)
    }

    @Test func sentenceBucketsIncludeEveryBoundaryExactlyOnce() {
        let counts = [1, 10, 11, 20, 21, 30, 31, 40, 41, 50, 51, 75]
        let text = counts.map { Array(repeating: "word", count: $0).joined(separator: " ") + "." }.joined(separator: " ")
        let measured = aggregate(text)
        #expect(measured.sentences.map(\.wordCount) == counts)
        #expect(measured.sentenceBuckets.map(\.count) == [2, 2, 2, 2, 2, 2])
        #expect(measured.sentenceBuckets.flatMap(\.sentenceIndices).sorted() == Array(counts.indices))
        #expect(abs(measured.sentenceBuckets.map(\.fraction).reduce(0, +) - 1) < 0.00001)
    }

    @Test func meansMediansPercentilesAndVariation() {
        let odd = LengthStatistics([1, 3, 5])
        #expect(odd.mean == 3)
        #expect(odd.median == 3)
        #expect(odd.p90 == 5)
        #expect(abs(odd.standardDeviation - sqrt(8.0 / 3)) < 0.00001)
        let even = LengthStatistics([10, 20, 30, 40])
        #expect(even.median == 25)
        #expect(even.p90 == 40)
        #expect(LengthStatistics(Array(1...100)).p90 == 90)
        #expect(LengthStatistics([5, 5]).coefficientOfVariation == 0)
        #expect(LengthStatistics([]).median == 0)
    }

    @Test func paragraphsAndRangesStayInDocumentOrder() {
        let text = "😀 The first paragraph has five words.\n\nThe next paragraph is a little longer than the first paragraph.\n\nShort end."
        let measured = aggregate(text)
        #expect(measured.paragraphs.count == 3)
        #expect(measured.paragraphs.map(\.range).sorted() == measured.paragraphs.map(\.range))
        #expect(measured.shortestParagraph?.wordCount == 2)
        #expect(measured.longestParagraph?.id == 1)
        let ns = text as NSString
        for paragraph in measured.paragraphs {
            #expect(paragraph.range.upperBound <= ns.length)
            #expect(ns.substring(with: paragraph.range.nsRange).contains("paragraph") || paragraph.wordCount == 2)
        }
        for sentence in measured.sentences { #expect(sentence.range.upperBound <= ns.length) }
    }

    @Test func scientificNotationAndUnicodeMatchCore() {
        let documents = [
            "Dr. Smith measured 1.5 units. Fig. 2 shows $\\alpha + \\beta = 2$ and `hidden code`.",
            "Café naïve coöperate. The well-known researcher's result agrees.",
            "这是一个中文段落。第二个句子。\n\n日本語の文章です。",
            "Привет мир. Это научный текст.",
            "\\documentclass{article}\n\\begin{document}\n\\section{Results}\nThe measured $x^2$ agrees with observations. Another sentence follows.\n\\end{document}"
        ]
        for (index, text) in documents.enumerated() {
            let name = index == 4 ? "paper.tex" : "paper.md"
            let source = DocumentSnapshot(revision: DocumentRevision(1), text: text, fileName: name)
            let measured = aggregate(text, name: name)
            #expect(measured.statistics == DocumentStatistics(prose: ProseText(source)))
            #expect(measured.sentences.map(\.wordCount).reduce(0, +) == measured.statistics.words)
        }
        #expect(!aggregate(documents[2]).vocabulary.available)
        #expect(!aggregate(documents[3]).readabilityAvailable)
    }

    @Test func readabilitySamplesAvoidTinyFragmentsAndCoverLongDocument() {
        let sentence = "The careful researcher compared the results with earlier observations and found that the measurements remained consistent."
        let paragraph = Array(repeating: sentence, count: 12).joined(separator: " ")
        let text = Array(repeating: paragraph, count: 6).joined(separator: "\n\n")
        let measured = aggregate(text)
        #expect(measured.readabilityAvailable)
        #expect(!measured.readabilityWindows.isEmpty)
        #expect(measured.readabilityWindows.allSatisfy { $0.words >= 150 && $0.sentences >= 2 })
        #expect(measured.readabilityWindows.map(\.words).reduce(0, +) == measured.statistics.words)
        #expect(measured.readabilityWindows.map(\.range).sorted() == measured.readabilityWindows.map(\.range))
        #expect(measured.paragraphs.allSatisfy { $0.gradeLevel != nil })
        for window in measured.readabilityWindows {
            #expect(window.gradeLevel.isFinite)
            #expect(window.range.upperBound <= text.utf16Length)
        }
    }

    @Test func vocabularyUsesExistingMattrAndNavigableOccurrences() {
        let sentence = "The careful researcher measured the crystal and the careful researcher described the crystal clearly."
        let text = Array(repeating: sentence, count: 8).joined(separator: " ")
        let source = DocumentSnapshot(revision: DocumentRevision(4), text: text)
        let style = StyleEngine().analyze(source, domain: .general)
        let measured = DocumentStatisticsAggregator.aggregate(documentID: UUID(), snapshot: source, prose: ProseText(source), style: style)
        #expect(measured.vocabulary.available)
        let prose = ProseText(source)
        #expect(measured.vocabulary.uniqueWords == Set(prose.words.map { prose.string($0).lowercased() }).count)
        #expect(measured.vocabulary.mattr50 == style.measurements.first { $0.featureID == "mattr50" }?.value)
        #expect(!measured.vocabulary.repeatedWords.contains { $0.text == "the" || $0.text == "and" })
        let crystal = measured.vocabulary.repeatedWords.first { $0.text == "crystal" }
        #expect(crystal?.count == 16)
        #expect(crystal?.ranges.allSatisfy { source.substring($0)?.lowercased() == "crystal" } == true)
        #expect(measured.vocabulary.repeatedOpenings.first?.text == "the careful")
        #expect(measured.vocabulary.repeatedOpenings.first?.count == 8)
    }

    @Test func staleAnalysisCannotContaminateSnapshot() {
        let old = DocumentSnapshot(revision: DocumentRevision(1), text: "Old words.")
        let current = DocumentSnapshot(revision: DocumentRevision(2), text: "The current document has a completely different length and wording.")
        let local = WritingAnalyzer().analyze(old)
        let style = StyleEngine().analyze(old, domain: .general)
        let identity = UUID()
        let measured = DocumentStatisticsAggregator.aggregate(documentID: identity, snapshot: current, prose: ProseText(current), local: local, style: style)
        #expect(measured.documentID == identity)
        #expect(measured.revision == current.revision)
        #expect(measured.statistics.words == ProseText(current).words.count)
        #expect(measured.statistics.words != local.statistics.words)
        #expect(measured.styleSummary == nil)
        #expect(measured.vocabulary.mattr50 == nil)
    }

    @Test func identicalComplexPassagesAppearOnce() throws {
        let hard = "The interdisciplinary investigation systematically characterized the phenomenological implications of the experimental methodology while considering the substantial uncertainty associated with the instrumental calibration and the theoretical interpretation of the measurements."
        let text = String(repeating: "Birds sing. The sun shines. ", count: 30) + String(repeating: hard + " ", count: 3)
        let source = DocumentSnapshot(revision: DocumentRevision(1), text: text)
        let prose = ProseText(source)
        let local = WritingAnalyzer(rules: [SentenceDifficultyRule()]).analyze(source, prose: prose)
        let measured = DocumentStatisticsAggregator.aggregate(documentID: UUID(), snapshot: source, prose: prose, local: local)
        #expect(local.issues.count == 3)
        #expect(measured.readabilityAvailable, "Language: \(measured.languageCode ?? "unknown")")
        #expect(measured.complexPassages.count == 1, "Baseline: \(String(describing: local.statistics.gradeLevel)), grades: \(local.issues.map { $0.metadata["grade"] ?? "none" })")
        let passage = try #require(measured.complexPassages.first)
        #expect(source.substring(passage.range) == hard)
    }

    @Test func goalProgressHandlesUnmetExceededAndInvalidGoals() {
        #expect(DocumentGoalProgress(words: 60, target: 100)?.fraction == 0.6)
        #expect(DocumentGoalProgress(words: 60, target: 100)?.remaining == 40)
        #expect(DocumentGoalProgress(words: 120, target: 100)?.exceeded == 20)
        #expect(DocumentGoalProgress(words: 120, target: 100)?.remaining == 0)
        #expect(DocumentGoalProgress(words: 120, target: 100)?.fraction == 1.2)
        #expect(DocumentGoalProgress(words: 1, target: nil) == nil)
        #expect(DocumentGoalProgress(words: 1, target: 0) == nil)
    }

    @Test func longManuscriptAggregationIsBounded() {
        let paragraph = Array(repeating: "The experiment measured a consistent response across the sample.", count: 10).joined(separator: " ")
        let text = Array(repeating: paragraph, count: 500).joined(separator: "\n\n")
        let source = DocumentSnapshot(revision: DocumentRevision(8), text: text)
        let prose = ProseText(source)
        let clock = ContinuousClock()
        let start = clock.now
        let measured = DocumentStatisticsAggregator.aggregate(documentID: UUID(), snapshot: source, prose: prose)
        let elapsed = start.duration(to: clock.now)
        #expect(measured.statistics.words == 45_000)
        #expect(measured.paragraphs.count == 500)
        #expect(measured.sentences.count == 5_000)
        #expect(measured.vocabulary.repeatedWords.count <= 15)
        #expect(measured.vocabulary.repeatedOpenings.count <= 8)
        #expect(elapsed < .seconds(15), "45,000-word aggregation should remain bounded, measured \(elapsed)")
    }
}
