// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import SwiftUI
import TersoCore
import TersoStyle

enum DocumentStatisticsSection: String, CaseIterable, Identifiable {
    case overview = "Overview", structure = "Structure", readability = "Readability", vocabulary = "Vocabulary"
    var id: Self { self }
}

/// Current-document measurements. Writing sessions, goals and awards retain
/// their separate Writing Stats home. No activity tab is offered without data.
struct DocumentStatisticsView: View {
    let model: WorkspaceModel
    var availableSize: CGSize = .zero
    @Environment(\.dismiss) private var dismiss
    @State private var section = DocumentStatisticsSection.overview
    @State private var bucket: Int?
    @State private var paragraphMode = ParagraphMapMode.length
    @State private var repetition: StatisticsRepetition?

    private var snapshot: DocumentStatisticsSnapshot? {
        guard let value = model.documentStatistics,
              value.documentID == model.statisticsDocumentID, value.revision == model.revision else { return nil }
        return value
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Document Statistics").font(.title2.weight(.semibold))
                    Text("\(model.fileURL?.lastPathComponent ?? "Untitled") · \(snapshot.map { $0.statistics.words.formatted() } ?? "—") words")
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Picker("Statistics section", selection: $section) {
                    ForEach(DocumentStatisticsSection.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24).padding(.vertical, 16)
            Divider()
            ScrollView {
                if let snapshot {
                    VStack(alignment: .leading, spacing: 16) {
                        if snapshot.statistics.words == 0 {
                            ContentUnavailableView("Nothing to measure yet", systemImage: "doc.text",
                                                   description: Text("Start writing to explore this document’s structure and vocabulary."))
                        } else {
                            switch section {
                            case .overview: overview(snapshot)
                            case .structure: structure(snapshot)
                            case .readability: readability(snapshot)
                            case .vocabulary: vocabulary(snapshot)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(20)
                } else {
                    ProgressView("Updating document statistics…")
                        .frame(maxWidth: .infinity, minHeight: 240)
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
            Divider()
            HStack {
                Text("Word counts use prose; headings, code and mathematics are excluded.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { model.returnToDocumentReport() } label: {
                    Label("Document Report", systemImage: "chevron.left")
                }.controlSize(.small)
            }.padding(.horizontal, 24).padding(.vertical, 10)
        }
        .frame(width: preferredSize.width, height: preferredSize.height)
        .onExitCommand { dismiss() }
        .onChange(of: model.revision) { _, _ in bucket = nil; repetition = nil }
        .onChange(of: snapshot?.styleSummary?.level) { _, level in
            if level == nil { paragraphMode = .length }
        }
    }

    private var preferredSize: CGSize {
        let width = availableSize.width > 0 ? availableSize.width - 40 : (NSScreen.main?.visibleFrame.width ?? 1080) - 80
        let height = availableSize.height > 0 ? availableSize.height - 40 : (NSScreen.main?.visibleFrame.height ?? 900) - 140
        return CGSize(width: min(1040, max(720, width)), height: min(780, max(400, height)))
    }

    private func reveal(_ range: TextSpan, in s: DocumentStatisticsSnapshot) {
        model.navigateFromStatistics(range, revision: s.revision)
    }

    // MARK: Overview

    private func overview(_ s: DocumentStatisticsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            KPIRow {
                wordsTile(s)
                KPITile(label: "Reading time", value: s.statistics.readingTimeLabel, symbol: "clock",
                        caption: "Speaking \(speakingTime(s.statistics.words))")
                    .help("Speaking time at 150 words per minute, a typical presentation pace")
                KPITile(label: "Reading level", value: DocumentReport.grade(s.statistics), symbol: "graduationcap",
                        caption: readingEaseBand(s) ?? "Needs a few more sentences")
                    .help("Flesch–Kincaid grade level and Flesch reading ease")
                KPITile(label: "Sentences", value: s.statistics.sentences.formatted(), symbol: "text.alignleft",
                        caption: "\(s.statistics.paragraphs.formatted()) paragraphs · \(s.statistics.characters.formatted()) characters")
            }
            HStack(alignment: .top, spacing: 16) {
                DashboardCard(title: "Document shape",
                              subtitle: "Paragraph length in document order. Select a passage to reveal it in the editor.") {
                    DocumentParagraphMap(paragraphs: s.paragraphs, compact: true) { reveal($0, in: s) }
                }
                DashboardCard(title: "Composition") {
                    VStack(alignment: .leading, spacing: 8) {
                        DetailRow(label: "Average sentence", value: "\(number(s.sentenceLengths.mean)) words")
                        DetailRow(label: "Median sentence", value: "\(number(s.sentenceLengths.median)) words")
                        DetailRow(label: "Average paragraph", value: "\(number(s.paragraphLengths.mean)) words")
                        Divider().padding(.vertical, 2)
                        if let longest = s.longestSentence {
                            passageRow("Longest sentence", value: "\(longest.wordCount.formatted()) words", range: longest.range, snapshot: s)
                        }
                        if let longest = s.longestParagraph {
                            passageRow("Longest paragraph", value: "\(longest.wordCount.formatted()) words", range: longest.range, snapshot: s)
                        }
                    }.font(.callout)
                }
                .frame(width: 290)
            }
            .fixedSize(horizontal: false, vertical: true)
            styleSummary(s)
        }
    }

    private func wordsTile(_ s: DocumentStatisticsSnapshot) -> some View {
        let progress = DocumentGoalProgress(words: s.statistics.words, target: model.documentWordTarget)
        return KPITile(label: "Words", value: s.statistics.words.formatted(), symbol: "character.cursor.ibeam",
                       caption: progress.map { p in
                           p.remaining > 0 ? "\(p.remaining.formatted()) to go of \(p.target.formatted())"
                                           : "\(p.exceeded.formatted()) beyond \(p.target.formatted())"
                       } ?? "No word target") {
            if let progress {
                HStack(spacing: 8) {
                    ProgressView(value: min(1, max(0, progress.fraction))).controlSize(.small)
                        .tint(progress.fraction >= 1 ? .green : .accentColor)
                        .accessibilityLabel("Document word goal")
                    Text(progress.fraction, format: .percent.precision(.fractionLength(0)))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Structure

    private func structure(_ s: DocumentStatisticsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            KPIRow {
                KPITile(label: "Average sentence", value: "\(number(s.sentenceLengths.mean))", symbol: "ruler",
                        caption: "words · median \(number(s.sentenceLengths.median))")
                KPITile(label: "90th percentile", value: "\(number(s.sentenceLengths.p90))", symbol: "chart.bar.xaxis",
                        caption: "words; 9 in 10 sentences are shorter or equal")
                KPITile(label: "Sentence variation", value: "±\(number(s.sentenceLengths.standardDeviation))", symbol: "waveform.path",
                        caption: "words standard deviation")
                    .help("Standard deviation describes how widely lengths vary around their mean.")
                KPITile(label: "Paragraph variation", value: "±\(number(s.paragraphLengths.standardDeviation))", symbol: "text.justify.left",
                        caption: "words standard deviation")
                    .help("Standard deviation describes how widely lengths vary around their mean.")
            }
            DashboardCard(title: "Sentence length",
                          subtitle: "Sentences by word count. Select a bar to step through its sentences.") {
                if bucket != nil {
                    Button("Clear Selection") { bucket = nil }.controlSize(.small).buttonStyle(.link)
                }
            } content: {
                SentenceLengthHistogram(buckets: s.sentenceBuckets, selection: $bucket)
                    .frame(height: 170)
                if let bucket, s.sentenceBuckets.indices.contains(bucket) {
                    let selected = s.sentenceBuckets[bucket]
                    StatisticsPassageBrowser(model: model, title: "\(selected.label) words",
                                            ranges: selected.sentenceIndices.map { s.sentences[$0].range }, revision: s.revision)
                        .id(bucket)
                }
            }
            DashboardCard(title: "Paragraph structure",
                          subtitle: "Length and complexity describe the shape of your prose. Longer passages can be deliberate.") {
                Picker("Paragraph map", selection: $paragraphMode) {
                    Text("Length").tag(ParagraphMapMode.length)
                    Text("Readability").tag(ParagraphMapMode.readability)
                    if s.styleSummary != nil { Text("AI-style").tag(ParagraphMapMode.style) }
                }.pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.small)
            } content: {
                DocumentParagraphMap(paragraphs: s.paragraphs, mode: paragraphMode) { reveal($0, in: s) }
                HStack(spacing: 16) {
                    if let shortest = s.shortestParagraph {
                        passageRow("Shortest paragraph", value: "\(shortest.wordCount) words", range: shortest.range, snapshot: s)
                    }
                    if let longest = s.longestParagraph {
                        passageRow("Longest paragraph", value: "\(longest.wordCount) words", range: longest.range, snapshot: s)
                    }
                }
            }
        }
    }

    // MARK: Readability

    private func readability(_ s: DocumentStatisticsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if !s.readabilityAvailable {
                ContentUnavailableView("Reading level unavailable", systemImage: "text.magnifyingglass",
                                       description: Text(s.readabilityUnavailableReason ?? "Reading-level estimates currently support English prose."))
            } else {
                KPIRow {
                    KPITile(label: "Flesch–Kincaid", value: DocumentReport.grade(s.statistics), symbol: "graduationcap",
                            caption: s.statistics.gradeLevel.map { "Grade \(number($0)) · \(model.prefs.domain.title) register" }
                                ?? "Needs 30 words and two sentences")
                    KPITile(label: "Reading ease", value: readingEase(s).map(number) ?? "—", symbol: "book",
                            caption: readingEaseBand(s) ?? "Needs a few more sentences")
                        .help("Flesch reading ease: 0–100, higher reads more easily")
                    KPITile(label: "Complex sentences", value: s.complexity.difficultSentences.formatted(), symbol: "exclamationmark.bubble",
                            caption: "\(s.complexity.complexWords.formatted()) complex words · \(s.complexity.passiveConstructions.formatted()) passive")
                    KPITile(label: "Words per sentence", value: number(s.sentenceLengths.mean), symbol: "ruler",
                            caption: "on average")
                }
                DashboardCard(title: "Across the document",
                              subtitle: "Flesch–Kincaid grade in regions of about 180 words, aligned to paragraphs. Higher values indicate greater reading demand, not lower quality.") {
                    if s.readabilityWindows.isEmpty {
                        Text(s.readabilityUnavailableReason ?? "A regional reading level needs at least 150 words and two sentences. Shorter passages are left unscored.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        ReadabilityRegionChart(regions: s.readabilityWindows, documentGrade: s.statistics.gradeLevel) { reveal($0, in: s) }
                    }
                }
                DashboardCard(title: "Complex passages",
                              subtitle: "Readability findings well above this document’s level. Select one to inspect it in context.") {
                    if s.complexPassages.isEmpty {
                        Label("No unusually complex passages relative to this document.", systemImage: "checkmark.circle")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        VStack(spacing: 2) {
                            ForEach(Array(s.complexPassages.prefix(6).enumerated()), id: \.offset) { _, passage in
                                PassageRowButton { reveal(passage.range, in: s) } label: {
                                    Text(passage.preview).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                    StatChip(label: "Grade", value: number(passage.gradeLevel))
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Vocabulary

    private func vocabulary(_ s: DocumentStatisticsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if !s.vocabulary.available {
                ContentUnavailableView("Vocabulary unavailable", systemImage: "character.book.closed",
                                       description: Text(s.vocabulary.unavailableReason ?? "This document’s language is not supported by the current analyzer."))
            } else {
                KPIRow {
                    KPITile(label: "Unique words", value: s.vocabulary.uniqueWords.formatted(), symbol: "character.book.closed",
                            caption: "of \(s.statistics.words.formatted()) words, case folded")
                    KPITile(label: "Lexical diversity", value: s.vocabulary.mattr50.map {
                        $0.formatted(.number.precision(.fractionLength(2)))
                    } ?? "—", symbol: "circle.hexagongrid", caption: "MATTR-50, from 0 to 1")
                        .help("MATTR-50 averages the share of unique words in 50-word windows. It needs at least 50 words and reduces the effect of document length.")
                    KPITile(label: "Average word length", value: number(s.vocabulary.averageWordLength), symbol: "textformat.size",
                            caption: "letters per word")
                }
                HStack(alignment: .top, spacing: 16) {
                    DashboardCard(title: "Repeated content words", subtitle: "Occurrences and share of all words.") {
                        if s.vocabulary.repeatedWords.isEmpty {
                            Text("No repeated content words yet.").font(.callout).foregroundStyle(.secondary)
                        } else {
                            RepetitionBarList(items: Array(s.vocabulary.repeatedWords.prefix(12)), selection: $repetition)
                        }
                    }
                    DashboardCard(title: "Repeated sentence openings",
                                  subtitle: "Repeated first two words can create rhythm or emphasis.") {
                        if s.vocabulary.repeatedOpenings.isEmpty {
                            Text("No repeated sentence openings yet.").font(.callout).foregroundStyle(.secondary)
                        } else {
                            RepetitionBarList(items: Array(s.vocabulary.repeatedOpenings.prefix(6)), selection: $repetition)
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                if let repetition {
                    StatisticsPassageBrowser(model: model, title: "“\(repetition.text)”",
                                            ranges: repetition.ranges, revision: s.revision).id(repetition.text)
                }
            }
        }
    }

    @ViewBuilder private func styleSummary(_ s: DocumentStatisticsSnapshot) -> some View {
        if let style = s.styleSummary {
            DashboardCard(title: "AI-style patterns", subtitle: StyleSignalSummary.disclaimer) {
                Button("Inspect Measurements") {
                    model.inspectorTab = .statistics
                    model.showInspector = true
                    dismiss()
                }.controlSize(.small)
            } content: {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles").foregroundStyle(style.level == .elevated ? Color.orange : Color.secondary)
                    Text("\(style.count) signals outside the register’s human range").font(.callout)
                    StatChip(label: "Level", value: style.level.rawValue)
                }
            }
        }
    }

    private func passageRow(_ title: String, value: String, range: TextSpan, snapshot: DocumentStatisticsSnapshot) -> some View {
        PassageRowButton { reveal(range, in: snapshot) } label: {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).monospacedDigit()
        }
        .padding(.horizontal, -8)
        .help("Reveal passage in the editor; keeps the insertion point")
    }

    private func readingEase(_ s: DocumentStatisticsSnapshot) -> Double? {
        guard s.statistics.gradeLevel != nil else { return nil }
        return Readability.fleschReadingEase(words: s.statistics.words, sentences: s.statistics.sentences, syllables: s.statistics.syllables)
    }

    /// Plain-language band from Flesch's own table, as the Document Report shows it.
    private func readingEaseBand(_ s: DocumentStatisticsSnapshot) -> String? {
        guard let ease = readingEase(s) else { return nil }
        switch ease {
        case 80...: return "Easy to read"
        case 60..<80: return "Plain English"
        case 50..<60: return "Fairly difficult"
        case 30..<50: return "Difficult"
        default: return "Very difficult"
        }
    }

    private func number(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(1))) }
    private func speakingTime(_ words: Int) -> String {
        words == 0 ? "—" : words < 150 ? "< 1 min" : "\(Int((Double(words) / 150).rounded())) min"
    }
}

/// An inline occurrence browser avoids another sheet or changing the editor's
/// selection while inspecting a histogram bucket or a repeated word.
private struct StatisticsPassageBrowser: View {
    let model: WorkspaceModel
    let title: String
    let ranges: [TextSpan]
    let revision: DocumentRevision
    @State private var index = 0

    var body: some View {
        if !ranges.isEmpty {
            let current = min(index, ranges.count - 1)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(title).font(.callout.weight(.medium))
                    Spacer()
                    Text("\(current + 1) of \(ranges.count)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    Button { index = max(0, current - 1) } label: { Image(systemName: "chevron.left") }
                        .disabled(current == 0).accessibilityLabel("Previous occurrence")
                    Button { index = min(ranges.count - 1, current + 1) } label: { Image(systemName: "chevron.right") }
                        .disabled(current == ranges.count - 1).accessibilityLabel("Next occurrence")
                    Button("Reveal in Document") { model.navigateFromStatistics(ranges[current], revision: revision) }
                }.controlSize(.small)
                Text(excerpt(ranges[current])).font(.callout).foregroundStyle(.secondary).lineLimit(3)
            }
            .padding(12)
            .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 1))
        } else {
            Text("No sentences in this range.").font(.callout).foregroundStyle(.secondary)
        }
    }

    private func excerpt(_ range: TextSpan) -> String {
        guard let snapshot = model.editor?.currentSnapshot, snapshot.revision == revision else { return "Updating…" }
        let ns = snapshot.text as NSString
        // Sentence buckets already identify a full passage. For a word, find
        // its surrounding sentence using the cached source map, without
        // segmenting the document again or displaying chopped words.
        let sentences = model.documentStatistics?.sentences ?? []
        var lower = 0, upper = sentences.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if sentences[middle].range.upperBound <= range.location { lower = middle + 1 } else { upper = middle }
        }
        let passage = lower < sentences.count && sentences[lower].range.intersects(range) ? sentences[lower].range : range
        let start = max(passage.location, range.location - 90)
        let end = min(passage.upperBound, max(range.location + min(range.length, 180), start + 350))
        let bounded = ns.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: end - start))
        var excerpt = ns.substring(with: bounded)
        if start > passage.location {
            excerpt = excerpt.drop(while: { !$0.isWhitespace }).trimmingCharacters(in: .whitespacesAndNewlines)
            excerpt = "…" + excerpt
        }
        if end < passage.upperBound {
            if let space = excerpt.lastIndex(where: \.isWhitespace) { excerpt = String(excerpt[..<space]) }
            excerpt += "…"
        }
        return excerpt.replacingOccurrences(of: "\n", with: " ")
    }
}
