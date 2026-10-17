// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import TersoCore
import TersoStyle

/// A quick look at the document: how long it is, how long it takes to read,
/// and how hard it reads. The Statistics inspector holds the detail.
struct DocumentReport: View {
    let model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // The same header as Writing Stats: the two reports are siblings.
            HStack {
                Text("Document Report").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24).padding(.vertical, 16)
            Divider()
            content.padding(24)
        }
        .frame(width: 520)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let s = model.local?.statistics, s.words > 0 {
                HStack(alignment: .top, spacing: 12) {
                    FeaturedStat(value: s.words.formatted(), label: s.words == 1 ? "word" : "words")
                    FeaturedStat(value: s.readingTimeLabel, label: "reading time")
                    FeaturedStat(value: Self.grade(s), label: "reading level", detail: ease(s))
                        .help("Flesch–Kincaid grade level and Flesch reading ease")
                }
                // Cards stretch to the tallest one, so a detail line on one
                // card doesn't leave the others short.
                .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("Details")
                    Divider()
                    DetailRow(label: "Sentences", value: s.sentences.formatted())
                    DetailRow(label: "Paragraphs", value: s.paragraphs.formatted())
                    DetailRow(label: "Average sentence", value: averageSentence(s))
                    DetailRow(label: "Characters", value: s.characters.formatted())
                    DetailRow(label: "Speaking time", value: speakingTime(s))
                        .help("At 150 words per minute, a typical presentation pace")
                    if let r = model.style, let level = r.summary.level {
                        DetailRow(label: "AI-style signals", value: "\(r.summary.aiSideCount) of \(r.summary.bandedCount) · \(level.rawValue)")
                            .help(StyleSignalSummary.disclaimer)
                    }
                }
            } else {
                Text("Nothing to measure yet. Start writing and the report fills in.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            }
            Button("Open Statistics") {
                model.inspectorTab = .statistics
                model.showInspector = true
                dismiss()
            }
            .help("Show writing, specificity and AI-style statistics in the inspector")
        }
    }

    static func grade(_ s: DocumentStatistics) -> String {
        guard let g = s.gradeLevel else { return "—" }
        let n = Int(g.rounded())
        return n >= 17 ? "Graduate" : n >= 13 ? "College" : "Grade \(max(1, n))"
    }

    /// Plain-language band for Flesch reading ease, from Flesch's own table.
    private func ease(_ s: DocumentStatistics) -> String? {
        guard s.gradeLevel != nil else { return "Needs a few more sentences" }
        let e = Readability.fleschReadingEase(words: s.words, sentences: s.sentences, syllables: s.syllables)
        switch e {
        case 80...: return "Easy to read"
        case 60..<80: return "Plain English"
        case 50..<60: return "Fairly difficult"
        case 30..<50: return "Difficult"
        default: return "Very difficult"
        }
    }

    private func averageSentence(_ s: DocumentStatistics) -> String {
        guard s.sentences > 0 else { return "—" }
        return "\(Int((Double(s.words) / Double(s.sentences)).rounded())) words"
    }

    private func speakingTime(_ s: DocumentStatistics) -> String {
        let m = Double(s.words) / 150
        return m < 1 ? "< 1 min" : "\(Int(m.rounded())) min"
    }
}

/// The document in the header, beside today's words: its length as a dial
/// against its word target (the Stats target, else the book's goal), its
/// reading level, and how many AI-style signals sit outside the human range
/// once there are enough to mean something.
struct DocumentReportButton: View {
    let model: WorkspaceModel
    let density: HeaderDensity
    /// The document's word target, when it has one; without one the dial is
    /// hidden and the count stands alone.
    var target: Int?

    var body: some View {
        let s = model.local?.statistics
        let words = s?.words ?? 0
        let measured = words > 0 && s?.gradeLevel != nil
        let grade = measured ? DocumentReport.grade(s!) : "—"
        let flags = Self.flags(model.style)
        Button { model.showDocumentReport = true } label: {
            HStack(spacing: 6) {
                if let target {
                    GoalRing(fraction: Double(words) / Double(target), lineWidth: 2.2)
                        .frame(width: 13, height: 13)
                } else {
                    Image(systemName: "text.magnifyingglass").foregroundStyle(.secondary)
                }
                if density != .minimal {
                    Text(words.formatted()).monospacedDigit()
                    Text(grade).monospacedDigit().foregroundStyle(.secondary)
                }
                if density == .full, measured, let s { Text(s.readingTimeLabel).foregroundStyle(.secondary) }
                if let flags {
                    HStack(spacing: 2) {
                        Image(systemName: "sparkles")
                        Text(flags.count.formatted()).monospacedDigit()
                    }
                    .foregroundStyle(flags.level == .elevated ? Color.orange : Color.secondary)
                }
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 9)
            .frame(minHeight: 22)
            .background(Color.secondary.opacity(0.08), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help(words: words, grade: measured ? grade : nil, flags: flags))
        .accessibilityLabel(accessibility(words: words, grade: measured ? grade : nil, flags: flags))
    }

    /// AI-style signals worth a glance: moderate or elevated only. Fewer
    /// than three on the AI side is common in human writing, so the header
    /// stays quiet about it.
    static func flags(_ r: StyleReport?) -> (count: Int, level: SignalLevel)? {
        guard let r, let level = r.summary.level, level != .low else { return nil }
        return (r.summary.aiSideCount, level)
    }

    private func help(words: Int, grade: String?, flags: (count: Int, level: SignalLevel)?) -> String {
        guard words > 0 else { return "Document report: word count, reading time and reading level" }
        var parts = [target.map { "\(words.formatted()) of \($0.formatted()) words" } ?? "\(words.formatted()) words"]
        if let grade { parts.append("reads at \(grade.lowercased()) level") }
        if let flags { parts.append("\(flags.count) AI-style signals outside the human range") }
        return parts.joined(separator: ", ") + ". Open the document report."
    }

    private func accessibility(words: Int, grade: String?, flags: (count: Int, level: SignalLevel)?) -> String {
        var label = "Document report, \(words) words"
        if let target { label += " of \(target)" }
        if let grade { label += ", reading level \(grade)" }
        if let flags { label += ", \(flags.count) AI-style signals" }
        return label
    }
}

struct FeaturedStat: View {
    let value: String
    let label: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.system(size: 26, weight: .semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.callout).foregroundStyle(.secondary)
            if let detail { Text(detail).font(.caption).foregroundStyle(.tertiary) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}

private struct DetailRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}
