// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import TersoCore

/// A quick look at the document: how long it is, how long it takes to read,
/// and how hard it reads. The Statistics inspector holds the detail.
struct DocumentReport: View {
    let model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Document Report").font(.title2.weight(.semibold))
            if let s = model.local?.statistics, s.words > 0 {
                HStack(alignment: .top, spacing: 12) {
                    FeaturedStat(value: s.words.formatted(), label: s.words == 1 ? "word" : "words")
                    FeaturedStat(value: s.readingTimeLabel, label: "reading time")
                    FeaturedStat(value: grade(s), label: "reading level", detail: ease(s))
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
        .padding(24)
        .frame(width: 440)
    }

    private func grade(_ s: DocumentStatistics) -> String {
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
