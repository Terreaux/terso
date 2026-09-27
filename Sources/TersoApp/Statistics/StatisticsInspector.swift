// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import TersoCore
import TersoStyle

/// Document-level measurements that inform editing. No scores, gauges or streaks.
struct StatisticsInspector: View {
    let model: WorkspaceModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                DocumentSummary(model: model)
                WritingStatistics(model: model)
                SpecificityStatistics(model: model)
                AIStyleStatistics(model: model)
            }
            .padding(16)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct DocumentSummary: View {
    let model: WorkspaceModel
    var body: some View {
        if let s = model.local?.statistics {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(s.words.formatted()) words").font(.title3)
                Text("\(s.sentences.formatted()) sentences").foregroundStyle(.secondary)
                Text(s.readingTimeLabel == "< 1 min" ? "Under a minute to read" : "\(s.readingTimeLabel) read").foregroundStyle(.secondary)
                if let g = s.gradeLevel { Text("Grade \(Int(g.rounded()))").foregroundStyle(.secondary).help("Flesch–Kincaid grade level") }
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// A label on the left, a value on the right; tapping jumps to the first
/// finding of that kind when there is one.
struct StatLine: View {
    let label: String
    let value: String
    var action: (() -> Void)?
    var body: some View {
        Button { action?() } label: {
            HStack {
                Text(label).foregroundStyle(.secondary)
                Spacer()
                Text(value).monospacedDigit()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
    }
}

struct WritingStatistics: View {
    let model: WorkspaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Writing")
            Divider()
            StatLine(label: "Sentence complexity", value: complexity, action: jump(.complexity, .readability))
            StatLine(label: "Passive voice", value: "\(model.count(.passiveVoice))", action: jump(.passiveVoice))
            StatLine(label: "Repetition", value: "\(model.count(.repetition))", action: jump(.repetition))
            StatLine(label: "Spelling & grammar", value: "\(model.count(.spelling))", action: jump(.spelling))
        }
    }

    /// Share of sentences flagged hard or very hard to read.
    var complexity: String {
        guard let s = model.local?.statistics, s.sentences > 0 else { return "—" }
        let hard = (model.local?.issues ?? []).filter { $0.ruleID == "sentence.difficulty" }.count
        let share = Double(hard) / Double(s.sentences)
        return share < 0.05 ? "Low" : share < 0.15 ? "Moderate" : "High"
    }

    func jump(_ cats: AnnotationCategory...) -> (() -> Void)? {
        guard let first = model.reviewFindings.first(where: { cats.contains($0.category) }) else { return nil }
        return {
            model.select(first)
            model.inspectorTab = .review
        }
    }
}

/// Generic versus concrete writing — shown side by side so the difference
/// is visible, not scored.
struct SpecificityStatistics: View {
    let model: WorkspaceModel

    var body: some View {
        if let spec = model.style?.specificity {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionLabel("Specificity")
                    Spacer()
                    Text(overall(spec)).font(.callout)
                }
                Divider()
                if spec.paragraphs.isEmpty {
                    Text("Not enough prose to assess yet.").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(spec.genericParagraphs) { p in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("GENERIC PASSAGE").font(.caption2.weight(.semibold)).tracking(0.6).foregroundStyle(.secondary)
                        passageButton(p)
                        Text("Broad claims with little concrete evidence or context. Consider a concrete example, evidence or a measurement, an attribution, or a specific observation.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                ForEach(spec.concreteParagraphs.prefix(2)) { p in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("CONCRETE PASSAGE").font(.caption2.weight(.semibold)).tracking(0.6).foregroundStyle(.secondary)
                        passageButton(p)
                        Text(p.markerSummary).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("Add only details that are true. Specific is not always better; some passages should stay general.")
                    .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    func overall(_ spec: SpecificityReport) -> String {
        guard !spec.paragraphs.isEmpty else { return "—" }
        let share = Double(spec.genericParagraphs.count) / Double(spec.paragraphs.count)
        return share == 0 ? "Good" : share < 0.34 ? "Mixed" : "Generic"
    }

    func passageButton(_ p: ParagraphSpecificity) -> some View {
        Button {
            if let a = model.reviewFindings.first(where: { $0.category == .specificity && $0.ranges.first == p.range }) {
                model.select(a)
            } else {
                model.editor?.reveal(p.range, select: false)
            }
        } label: {
            Text(model.editor?.currentSnapshot.substring(p.range) ?? "")
                .font(.system(.callout, design: .serif)).lineLimit(3).multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }
}

struct AIStyleStatistics: View {
    let model: WorkspaceModel
    @State private var exploring = false

    var body: some View {
        @Bindable var prefs = model.prefs
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("AI-style signals")
            Divider()
            if let r = model.style {
                HStack {
                    Text("Overall").foregroundStyle(.secondary)
                    Spacer()
                    Text(r.summary.level?.rawValue ?? "Not assessed")
                }
                if r.summary.level != nil {
                    Text("\(r.summary.aiSideCount) of \(r.summary.bandedCount) signals outside the human reference range")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    ForEach(r.measurements.filter(\.onAISide)) { m in
                        HStack {
                            Text(m.name)
                            Spacer()
                            Image(systemName: m.position == .above ? "arrow.up" : "arrow.down").font(.caption)
                                .accessibilityLabel(m.position == .above ? "above range" : "below range")
                        }
                        .font(.callout)
                    }
                }
                if let note = r.summary.reliability.note {
                    Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Text(StyleSignalSummary.disclaimer).font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)

                Button(exploring ? "Hide Signals" : "Explore Signals") {
                    exploring.toggle()
                    if exploring { model.exploreSignals() } else if model.prefs.enabledLayers.contains(.aiStyle) { model.toggleLayer(.aiStyle) }
                }
                .help("Show every measurement against its human range, and mark the passages that contribute")

                if exploring {
                    Picker("Register", selection: $prefs.domain) {
                        ForEach(WritingDomain.allCases) { d in
                            Text(d.title + (BaselineLibrary.profile(for: d) == nil ? " (no data)" : "")).tag(d)
                        }
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(r.measurements) { m in FeatureRow(m: m) }
                    }
                    .padding(.top, 4)
                    if let p = r.profile {
                        Text(p.corpusDescription).font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                        Text(p.provenance).font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .onAppear { exploring = model.prefs.enabledLayers.contains(.aiStyle) }
    }
}

/// One measurement against its human reference range.
struct FeatureRow: View {
    let m: FeatureMeasurement
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(m.name).font(.callout)
                Spacer()
                Text("\(format(m.value)) \(shortUnit)").monospacedDigit().font(.callout)
            }
            if let b = m.band {
                BandBar(band: b, value: m.value, aiSide: m.onAISide).frame(height: 14)
                HStack {
                    Text("Human reference \(format(b.p10))–\(format(b.p90))")
                    Spacer()
                    if m.onAISide { Text("outside, AI side").fontWeight(.medium) }
                    else if m.position == .inside { Text("in range") }
                    else if m.position != nil { Text("outside") }
                }
                .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text(FeatureCatalog.unbandedIDs.contains(m.featureID) && m.profileID != nil ? "Shown for reference; no human range applies to this definition." : "No reference data for this register.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .help(m.interpretation)
        .accessibilityElement(children: .combine)
    }

    var shortUnit: String {
        switch m.unit {
        case "per 1k words": "/ 1k"
        case "per 100 sentences": "/ 100"
        case "% of sentences": "%"
        default: ""
        }
    }

    func format(_ v: Double) -> String { v >= 100 ? String(format: "%.0f", v) : v >= 10 ? String(format: "%.1f", v) : String(format: "%.2f", v) }
}

///   ├──── typical human range ────┤
///                  ▲ your text
struct BandBar: View {
    let band: ReferenceBand
    let value: Double
    let aiSide: Bool
    var body: some View {
        GeometryReader { g in
            let lo = min(band.min, value), hi = max(band.max, value)
            let span = max(hi - lo, 1e-9)
            let x = { (v: Double) in CGFloat((v - lo) / span) * g.size.width }
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.12)).frame(height: 3)
                Capsule().fill(Color.secondary.opacity(0.4))
                    .frame(width: max(2, x(band.p90) - x(band.p10)), height: 5)
                    .offset(x: x(band.p10))
                Rectangle().fill(Color.secondary).frame(width: 1, height: 9).offset(x: x(band.p50))
                Image(systemName: aiSide ? "triangle.fill" : "triangle")
                    .font(.system(size: 7))
                    .foregroundStyle(aiSide ? Color.orange : Color.primary)
                    .offset(x: x(value) - 3.5, y: 6)
            }
            .frame(maxHeight: .infinity)
        }
        .accessibilityHidden(true)
    }
}
