// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
import TersoCore
@testable import TersoApp

@Suite struct DocumentStatisticsChartTests {
    @Test func sourceHitTestingClampsToDocumentBounds() {
        #expect(statisticsChartIndex(-40, width: 400, count: 4) == 0)
        #expect(statisticsChartIndex(0, width: 400, count: 4) == 0)
        #expect(statisticsChartIndex(99.9, width: 400, count: 4) == 0)
        #expect(statisticsChartIndex(100, width: 400, count: 4) == 1)
        #expect(statisticsChartIndex(399.9, width: 400, count: 4) == 3)
        #expect(statisticsChartIndex(400, width: 400, count: 4) == 3)
        #expect(statisticsChartIndex(900, width: 400, count: 4) == 3)
    }

    @Test func unavailableGeometryAndEmptyChartsCannotProduceInvalidIndices() {
        #expect(statisticsChartIndex(50, width: 0, count: 10) == 0)
        #expect(statisticsChartIndex(50, width: -100, count: 10) == 0)
        #expect(statisticsChartIndex(50, width: 400, count: 0) == 0)
        #expect(statisticsChartIndex(50, width: 400, count: -1) == 0)
        #expect(statisticsChartIndex(.nan, width: 400, count: 10) == 0)
        #expect(statisticsChartIndex(.infinity, width: 400, count: 10) == 0)
        #expect(statisticsChartIndex(50, width: .infinity, count: 10) == 0)
        #expect(statisticsChartIndex(50, width: .nan, count: 10) == 0)
        #expect(statisticsChartIndex(0.2, width: 0.5, count: 5) == 2)
    }

    @Test func denseMapHitTestingStillAddressesEveryOriginalSourceRange() {
        let paragraphs = fixtures(count: 4_099)
        let samples = ParagraphChartSamples(paragraphs, columns: 256)
        let width: CGFloat = 512
        #expect(samples.columns.count == 256)
        #expect(samples.columns.flatMap { Array($0.indices) } == Array(paragraphs.indices))

        for index in paragraphs.indices {
            let x = (CGFloat(index) + 0.5) * width / CGFloat(paragraphs.count)
            let hit = statisticsChartIndex(x, width: width, count: paragraphs.count)
            #expect(hit == index)
            #expect(paragraphs[hit].range == paragraphs[index].range)
            let column = samples.columns.first { $0.indices.contains(hit) }
            #expect(column != nil)
        }
    }

    @Test func neighboringParagraphsRetainSourceOrderAndContributeToDenseColumns() {
        let paragraphs = fixtures(count: 17)
        let samples = ParagraphChartSamples(paragraphs, columns: 4)
        #expect(samples.columns.map(\.indices) == [0..<4, 4..<8, 8..<12, 12..<17])
        for column in samples.columns {
            let originals = paragraphs[column.indices]
            let expectedMean = Double(originals.reduce(0) { $0 + $1.wordCount }) / Double(originals.count)
            #expect(column.words == expectedMean)
            #expect(column.findings == originals.reduce(0) { $0 + $1.styleFindingCount })
            #expect(originals.map(\.range).sorted() == originals.map(\.range))
        }
    }

    @Test func shortAndEmptyMapsPreserveIndividualParagraphs() {
        let empty = ParagraphChartSamples([], columns: 256)
        #expect(empty.columns.isEmpty)
        #expect(empty.maximumWords.isFinite)
        #expect(empty.maximumGrade.isFinite)
        let paragraphs = fixtures(count: 3)
        let samples = ParagraphChartSamples(paragraphs, columns: 256)
        #expect(samples.columns.map(\.indices) == [0..<1, 1..<2, 2..<3])
        #expect(samples.columns.map(\.words) == paragraphs.map { Double($0.wordCount) })
        #expect(ParagraphChartSamples(paragraphs, columns: 0).columns.count == 1)
    }

    private func fixtures(count: Int) -> [StatisticsParagraph] {
        (0..<count).map { index in
            StatisticsParagraph(id: index, range: TextSpan(location: index * 120, length: 80 + index % 20),
                                wordCount: 10 + index % 40, sentenceCount: 2,
                                gradeLevel: index.isMultiple(of: 3) ? nil : Double(5 + index % 12),
                                styleFindingCount: index % 3)
        }
    }
}
