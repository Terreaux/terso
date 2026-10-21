// SPDX-License-Identifier: AGPL-3.0-only
import Charts
import SwiftUI
import TersoCore

enum ParagraphMapMode: String, CaseIterable, Identifiable {
    case length = "Length"
    case readability = "Readability"
    case style = "AI-style findings"

    var id: String { rawValue }
}

/// A single drawing surface, with a source-addressable inspector instead of a
/// view for every paragraph. Dense maps average adjacent paragraphs by column;
/// the pointer and keyboard still address each original paragraph.
struct DocumentParagraphMap: View {
    let paragraphs: [StatisticsParagraph]
    var mode: ParagraphMapMode = .length
    var compact = false
    let navigate: (TextSpan) -> Void
    @State private var selectedIndex = 0
    @State private var hoveredIndex: Int?
    /// Paragraph 1 is inspected from the start, but only emphasized once the
    /// reader points at or steps through the map: an unprompted highlight reads as data.
    @State private var engaged = false
    private let samples: ParagraphChartSamples

    init(paragraphs: [StatisticsParagraph], mode: ParagraphMapMode = .length, compact: Bool = false,
         navigate: @escaping (TextSpan) -> Void) {
        self.paragraphs = paragraphs
        self.mode = mode
        self.compact = compact
        self.navigate = navigate
        samples = ParagraphChartSamples(paragraphs, columns: 256)
    }

    private var inspectedIndex: Int { min(max(0, hoveredIndex ?? selectedIndex), max(0, paragraphs.count - 1)) }
    private var inspected: StatisticsParagraph? { paragraphs.isEmpty ? nil : paragraphs[inspectedIndex] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if paragraphs.isEmpty {
                Text("Paragraphs appear here as you write.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: compact ? 48 : 100, alignment: .leading)
            } else {
                GeometryReader { geometry in
                    Canvas { context, size in
                        var baseline = Path()
                        baseline.move(to: CGPoint(x: 0, y: size.height - 0.5))
                        baseline.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
                        context.stroke(baseline, with: .color(.secondary.opacity(0.3)), lineWidth: 1)
                        for column in samples.columns {
                            let x = Double(column.indices.lowerBound) * size.width / Double(paragraphs.count)
                            let columnWidth = Double(column.indices.count) * size.width / Double(paragraphs.count)
                            let height = max(2, (size.height - 4) * column.words / max(1, samples.maximumWords))
                            let gap = columnWidth > 4 ? 2.0 : columnWidth > 2 ? 1.0 : 0
                            let rect = CGRect(x: x, y: size.height - height,
                                              width: max(1, columnWidth - gap), height: height)
                            let selected = (engaged || hoveredIndex != nil) && column.indices.contains(inspectedIndex)
                            let dimmed = hoveredIndex != nil && !selected
                            let radius = min(4, rect.width / 2)
                            context.fill(UnevenRoundedRectangle(topLeadingRadius: radius, topTrailingRadius: radius).path(in: rect),
                                         with: .color(color(column, selected: selected, maximumGrade: samples.maximumGrade)
                                                        .opacity(dimmed ? 0.55 : 1)))
                        }
                    }
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point): hoveredIndex = statisticsChartIndex(point.x, width: geometry.size.width, count: paragraphs.count)
                        case .ended: hoveredIndex = nil
                        }
                    }
                    .gesture(SpatialTapGesture().onEnded { tap in
                        let index = statisticsChartIndex(tap.location.x, width: geometry.size.width, count: paragraphs.count)
                        selectedIndex = index
                        navigate(paragraphs[index].range)
                    })
                    .focusable().focusEffectDisabled()
                    .onKeyPress(.leftArrow) { move(-1); return .handled }
                    .onKeyPress(.rightArrow) { move(1); return .handled }
                    .onKeyPress(.return) { reveal(); return .handled }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Paragraph structure, \(paragraphs.count) paragraphs, \(mode.rawValue) mode")
                    .accessibilityValue(inspectorText)
                    .accessibilityHint("Use the arrow keys to inspect paragraphs and Return to reveal one in the editor.")
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: move(1)
                        case .decrement: move(-1)
                        @unknown default: break
                        }
                    }
                    .accessibilityAction(named: "Reveal paragraph") { reveal() }
                    .overlay(alignment: .topLeading) {
                        if let hoveredIndex, let paragraph = inspected {
                            let x = (Double(hoveredIndex) + 0.5) * geometry.size.width / Double(paragraphs.count)
                            ChartTooltip(title: "Paragraph \(hoveredIndex + 1)", lines: tooltipLines(paragraph))
                                .position(x: min(max(x, 70), geometry.size.width - 70), y: 4)
                        }
                    }
                }
                .frame(height: compact ? 88 : 150)
                .padding(.top, 18)
                StatisticsChartInspector(detail: inspectorText, index: inspectedIndex, count: paragraphs.count,
                                         previous: { move(-1) }, next: { move(1) }, reveal: reveal)
                if !compact {
                    Text(modeDescription).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onChange(of: paragraphs.count) { _, count in
            selectedIndex = min(selectedIndex, max(0, count - 1))
            hoveredIndex = nil
        }
    }

    private var inspectorText: String {
        guard let paragraph = inspected else { return "No paragraphs" }
        var value = "Paragraph \(inspectedIndex + 1) · \(paragraph.wordCount.formatted()) words · \(paragraph.sentenceCount) sentences"
        if let grade = paragraph.gradeLevel { value += " · Grade \(grade.formatted(.number.precision(.fractionLength(1))))" }
        if mode == .style { value += " · \(paragraph.styleFindingCount) AI-style findings" }
        return value
    }

    private func tooltipLines(_ paragraph: StatisticsParagraph) -> [String] {
        var lines = ["\(paragraph.wordCount.formatted()) words · \(paragraph.sentenceCount) sentences"]
        if let grade = paragraph.gradeLevel { lines.append("Grade \(grade.formatted(.number.precision(.fractionLength(1))))") }
        if mode == .style { lines.append("\(paragraph.styleFindingCount) AI-style findings") }
        return lines
    }

    private var modeDescription: String {
        switch mode {
        case .length: return "Height represents paragraph length, in document order. Dense maps average neighboring paragraphs."
        case .readability: return "Darker columns indicate a higher reading level. Unmeasured paragraphs appear gray; complexity is descriptive."
        case .style: return "Darker columns contain more AI-style findings. These signals do not establish authorship."
        }
    }

    private func color(_ column: ParagraphChartSamples.Column, selected: Bool, maximumGrade: Double) -> Color {
        if selected { return .accentColor }
        switch mode {
        case .length: return Color.accentColor.opacity(0.6)
        case .readability:
            guard let grade = column.grade else { return Color.secondary.opacity(0.22) }
            return Color.accentColor.opacity(0.2 + 0.65 * min(1, grade / max(1, maximumGrade)))
        case .style:
            return column.findings > 0 ? Color.accentColor.opacity(min(0.85, 0.35 + Double(column.findings) * 0.1)) : Color.secondary.opacity(0.22)
        }
    }

    private func move(_ delta: Int) {
        selectedIndex = min(max(0, inspectedIndex + delta), max(0, paragraphs.count - 1))
        hoveredIndex = nil
        engaged = true
    }

    private func reveal() {
        if let paragraph = inspected { navigate(paragraph.range) }
    }
}

/// Six categorical bars. Hover shows a bucket's share; a click or the arrow
/// keys select it, which only changes the inspector. Revealing a sentence is
/// an explicit action in the enclosing view.
struct SentenceLengthHistogram: View {
    let buckets: [SentenceLengthBucket]
    @Binding var selection: Int?
    @State private var hovered: Int?

    var body: some View {
        let maximum = max(1, buckets.map(\.count).max() ?? 1)
        let total = buckets.reduce(0) { $0 + $1.count }
        Chart(buckets) { bucket in
            BarMark(x: .value("Words per sentence", bucket.label), y: .value("Sentences", bucket.count), width: .ratio(0.72))
                .cornerRadius(4, style: .continuous)
                .foregroundStyle(Color.accentColor.opacity(opacity(bucket.id)))
                .annotation(position: .top, spacing: 4) {
                    Text(bucket.count.formatted()).font(.caption2.monospacedDigit())
                        .foregroundStyle(emphasized(bucket.id) ? .primary : .secondary)
                }
                .accessibilityLabel("\(bucket.label) words")
                .accessibilityValue("\(bucket.count) sentences, \(share(bucket, total: total))")
        }
        // Headroom keeps the tallest bar's count label inside the plot.
        .chartYScale(domain: 0...(Double(maximum) * 1.18))
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3])).foregroundStyle(Color.secondary.opacity(0.35))
                AxisValueLabel().font(.caption2).foregroundStyle(Color.secondary)
            }
        }
        .chartXAxis {
            AxisMarks { _ in AxisValueLabel().font(.caption).foregroundStyle(Color.secondary) }
        }
        .chartXAxisLabel("Words per sentence", alignment: .center)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                let plot = proxy.plotFrame.map { geometry[$0] } ?? .zero
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .frame(width: plot.width, height: plot.height).position(x: plot.midX, y: plot.midY)
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point): hovered = statisticsChartIndex(point.x, width: plot.width, count: buckets.count)
                        case .ended: hovered = nil
                        }
                    }
                    .gesture(SpatialTapGesture().onEnded { tap in
                        let index = statisticsChartIndex(tap.location.x, width: plot.width, count: buckets.count)
                        selection = selection == index ? nil : index
                    })
                    .accessibilityHidden(true)
                if let hovered, buckets.indices.contains(hovered) {
                    let bucket = buckets[hovered]
                    let x = plot.minX + (Double(hovered) + 0.5) * plot.width / Double(buckets.count)
                    ChartTooltip(title: "\(bucket.label) words",
                                 lines: ["\(bucket.count.formatted()) sentences", "\(share(bucket, total: total)) of all"])
                        .position(x: min(max(x, plot.minX + 60), plot.maxX - 60), y: plot.minY + 22)
                }
            }
        }
        .focusable().focusEffectDisabled()
        .onKeyPress(.leftArrow) { move(-1); return .handled }
        .onKeyPress(.rightArrow) { move(1); return .handled }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sentence length distribution")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: move(1)
            case .decrement: move(-1)
            @unknown default: break
            }
        }
    }

    private func emphasized(_ index: Int) -> Bool { index == selection || index == hovered }

    private func opacity(_ index: Int) -> Double {
        if index == selection { return 1 }
        if index == hovered { return 0.8 }
        return selection == nil && hovered == nil ? 0.7 : 0.35
    }

    private func share(_ bucket: SentenceLengthBucket, total: Int) -> String {
        (total > 0 ? Double(bucket.count) / Double(total) : 0).formatted(.percent.precision(.fractionLength(1)))
    }

    private func move(_ delta: Int) {
        guard !buckets.isEmpty else { return }
        selection = min(max(0, (selection ?? (delta > 0 ? -1 : buckets.count)) + delta), buckets.count - 1)
    }
}

/// Reading level as an area over the document, with the document's own level
/// as a reference rule. Hit testing addresses regions, not plotted samples.
struct ReadabilityRegionChart: View {
    let regions: [StatisticsReadabilityWindow]
    var documentGrade: Double?
    let navigate: (TextSpan) -> Void
    @State private var selectedIndex = 0
    @State private var hoveredIndex: Int?
    @State private var engaged = false
    private let samples: [Sample]
    private let maximumGrade: Double

    private struct Sample: Identifiable {
        let id: Int
        /// Center of the sampled regions, in region units on a 0…count axis.
        let position: Double
        let grade: Double
    }

    init(regions: [StatisticsReadabilityWindow], documentGrade: Double? = nil, navigate: @escaping (TextSpan) -> Void) {
        self.regions = regions
        self.documentGrade = documentGrade
        self.navigate = navigate
        let count = min(regions.count, 256)
        samples = (0..<count).map { column in
            let lower = column * regions.count / count
            let upper = (column + 1) * regions.count / count
            return Sample(id: column, position: Double(lower + upper) / 2,
                          grade: regions[lower..<upper].reduce(0) { $0 + $1.gradeLevel } / Double(upper - lower))
        }
        maximumGrade = (max(10, regions.map(\.gradeLevel).max() ?? 10) / 2).rounded(.up) * 2 + 2
    }

    private var inspectedIndex: Int { min(max(0, hoveredIndex ?? selectedIndex), max(0, regions.count - 1)) }
    private var inspected: StatisticsReadabilityWindow? { regions.isEmpty ? nil : regions[inspectedIndex] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if regions.isEmpty {
                Text("A reading-level map needs at least 150 words of prose. Short samples can give unstable results.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)
            } else {
                chart.frame(height: 190)
                HStack { Text("Beginning"); Spacer(); Text("End") }
                    .font(.caption2).foregroundStyle(.secondary).padding(.leading, 28)
                StatisticsChartInspector(detail: inspectorText, index: inspectedIndex, count: regions.count,
                                         previous: { move(-1) }, next: { move(1) }, reveal: reveal)
            }
        }
        .onChange(of: regions.count) { _, count in
            selectedIndex = min(selectedIndex, max(0, count - 1))
            hoveredIndex = nil
        }
    }

    private var chart: some View {
        let gradient = LinearGradient(colors: [Color.accentColor.opacity(0.32), Color.accentColor.opacity(0.03)],
                                      startPoint: .top, endPoint: .bottom)
        let marker = Double(inspectedIndex) + 0.5
        return Chart {
            ForEach(samples) { sample in
                AreaMark(x: .value("Position", sample.position), y: .value("Grade", sample.grade))
                    .interpolationMethod(.monotone).foregroundStyle(gradient)
                LineMark(x: .value("Position", sample.position), y: .value("Grade", sample.grade))
                    .interpolationMethod(.monotone).foregroundStyle(Color.accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            if let documentGrade {
                RuleMark(y: .value("Document grade", documentGrade))
                    .foregroundStyle(Color.secondary.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .annotation(position: .top, alignment: .trailing, spacing: 2) {
                        Text("Document \(documentGrade.formatted(.number.precision(.fractionLength(1))))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
            }
            if let inspected, engaged || hoveredIndex != nil {
                RuleMark(x: .value("Position", marker))
                    .foregroundStyle(Color.secondary.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                PointMark(x: .value("Position", marker), y: .value("Grade", inspected.gradeLevel))
                    .symbol {
                        Circle().fill(Color.accentColor).frame(width: 9, height: 9)
                            .overlay(Circle().strokeBorder(Color(nsColor: .controlBackgroundColor), lineWidth: 2))
                    }
                    .annotation(position: .top, spacing: 6,
                                overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        if hoveredIndex != nil {
                            ChartTooltip(title: "Region \(inspectedIndex + 1)",
                                         lines: ["Grade \(inspected.gradeLevel.formatted(.number.precision(.fractionLength(1))))",
                                                 "\(inspected.words.formatted()) words"])
                        }
                    }
            }
        }
        .chartXScale(domain: 0...Double(regions.count))
        .chartYScale(domain: 0...maximumGrade)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3])).foregroundStyle(Color.secondary.opacity(0.35))
                AxisValueLabel().font(.caption2).foregroundStyle(Color.secondary)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                let plot = proxy.plotFrame.map { geometry[$0] } ?? .zero
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .frame(width: plot.width, height: plot.height).position(x: plot.midX, y: plot.midY)
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point): hoveredIndex = statisticsChartIndex(point.x, width: plot.width, count: regions.count)
                        case .ended: hoveredIndex = nil
                        }
                    }
                    .gesture(SpatialTapGesture().onEnded { tap in
                        let index = statisticsChartIndex(tap.location.x, width: plot.width, count: regions.count)
                        selectedIndex = index
                        engaged = true
                        navigate(regions[index].range)
                    })
            }
        }
        .focusable().focusEffectDisabled()
        .onKeyPress(.leftArrow) { move(-1); return .handled }
        .onKeyPress(.rightArrow) { move(1); return .handled }
        .onKeyPress(.return) { reveal(); return .handled }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Reading level across \(regions.count) document regions")
        .accessibilityValue(inspectorText)
        .accessibilityHint("Use arrow keys to inspect regions and Return to reveal one in the editor.")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: move(1)
            case .decrement: move(-1)
            @unknown default: break
            }
        }
        .accessibilityAction(named: "Reveal passage") { reveal() }
    }

    private var inspectorText: String {
        guard let region = inspected else { return "No reading-level regions" }
        return "Region \(inspectedIndex + 1) · \(region.words.formatted()) words · Grade \(region.gradeLevel.formatted(.number.precision(.fractionLength(1))))"
    }

    private func move(_ delta: Int) {
        selectedIndex = min(max(0, inspectedIndex + delta), max(0, regions.count - 1))
        hoveredIndex = nil
        engaged = true
    }

    private func reveal() {
        if let region = inspected { navigate(region.range) }
    }
}

/// A ranked list whose bars sit behind their labels, so a long list stays
/// one column of text. Selecting a row opens its occurrence browser.
struct RepetitionBarList: View {
    let items: [StatisticsRepetition]
    @Binding var selection: StatisticsRepetition?
    @State private var hovered: String?

    var body: some View {
        let maximum = Double(max(1, items.map(\.count).max() ?? 1))
        VStack(spacing: 3) {
            ForEach(items) { item in
                let selected = selection?.id == item.id
                Button { selection = selected ? nil : item } label: {
                    HStack(spacing: 10) {
                        Text(item.text).lineLimit(1).truncationMode(.tail)
                            .padding(.horizontal, 8)
                            .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                            .background(alignment: .leading) {
                                GeometryReader { geometry in
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .fill(Color.accentColor.opacity(selected ? 0.38 : hovered == item.id ? 0.24 : 0.15))
                                        .frame(width: max(4, geometry.size.width * Double(item.count) / maximum))
                                }
                            }
                        Text(item.count.formatted()).monospacedDigit().fontWeight(.medium)
                            .frame(width: 34, alignment: .trailing)
                        Text(item.relativeFrequency, format: .percent.precision(.fractionLength(1)))
                            .monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                    }
                    .font(.callout)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 ? item.id : (hovered == item.id ? nil : hovered) }
                .accessibilityLabel("\(item.text), \(item.count) occurrences, \(Int((item.relativeFrequency * 100).rounded())) percent. Inspect occurrences")
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
    }
}

private struct StatisticsChartInspector: View {
    let detail: String
    let index: Int
    let count: Int
    let previous: () -> Void
    let next: () -> Void
    let reveal: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(action: previous) { Image(systemName: "chevron.left") }.disabled(index == 0)
                .accessibilityLabel("Previous passage").help("Inspect previous passage")
            Button(action: next) { Image(systemName: "chevron.right") }.disabled(index >= count - 1)
                .accessibilityLabel("Next passage").help("Inspect next passage")
            Button("Reveal", action: reveal).help("Close statistics and reveal this passage in the editor")
        }
        .controlSize(.small)
    }
}

/// Hit testing addresses the original source array, independent of the number
/// of rendered columns. Zero is an inert sentinel for an empty chart; callers
/// only invoke navigation when their source array is nonempty.
func statisticsChartIndex(_ x: CGFloat, width: CGFloat, count: Int) -> Int {
    guard count > 0, width.isFinite, width > 0, x.isFinite else { return 0 }
    let fraction = min(1, max(0, x / width))
    guard fraction < 1 else { return count - 1 }
    return min(Int(fraction * Double(count)), count - 1)
}

struct ParagraphChartSamples {
    struct Column {
        let indices: Range<Int>
        let words: Double
        let grade: Double?
        let findings: Int
    }
    let columns: [Column]
    let maximumWords: Double
    let maximumGrade: Double

    init(_ paragraphs: [StatisticsParagraph], columns limit: Int) {
        let count = min(paragraphs.count, max(1, limit))
        guard count > 0 else { columns = []; maximumWords = 1; maximumGrade = 1; return }
        columns = (0..<count).map { index in
            let indices = (index * paragraphs.count / count)..<((index + 1) * paragraphs.count / count)
            let group = paragraphs[indices]
            let grades = group.compactMap(\.gradeLevel)
            return Column(indices: indices,
                          words: Double(group.reduce(0) { $0 + $1.wordCount }) / Double(group.count),
                          grade: grades.isEmpty ? nil : grades.reduce(0, +) / Double(grades.count),
                          findings: group.reduce(0) { $0 + $1.styleFindingCount })
        }
        maximumWords = columns.map(\.words).max() ?? 1
        maximumGrade = columns.compactMap(\.grade).max() ?? 1
    }
}
