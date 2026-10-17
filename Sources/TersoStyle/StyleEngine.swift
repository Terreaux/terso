// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import TersoCore

public enum Reliability: Sendable, Hashable {
    case adequate
    case limited(String)
    case insufficient(String)

    public var note: String? {
        switch self {
        case .adequate: nil
        case .limited(let s), .insufficient(let s): s
        }
    }
}

/// One feature measured and placed against the human reference band.
public struct FeatureMeasurement: Identifiable, Sendable {
    public var id: String { featureID }
    public let featureID: String
    public let name: String
    public let unit: String
    public let interpretation: String
    public let value: Double
    public let rawCount: Int?
    public let band: ReferenceBand?
    public let position: BandPosition?
    public let contributingRanges: [TextSpan]
    public let profileID: String?

    public var direction: FeatureDirection { band?.direction ?? .undetermined }

    /// Outside the band on the side where AI text of this register sits.
    public var onAISide: Bool {
        switch (position, direction) {
        case (.above, .higherInAI), (.below, .lowerInAI): true
        default: false
        }
    }
    /// Outside the band on the other side (prose "overshooting" the human range).
    public var overshot: Bool { position != nil && position != .inside && !onAISide && direction != .undetermined }
}

public enum SignalLevel: String, Sendable, CaseIterable {
    case low = "Low", moderate = "Moderate", elevated = "Elevated"
}

/// Summary of AI-style signals. Deliberately not a probability: it counts how
/// many features fall outside the human band on the side AI text sits.
public struct StyleSignalSummary: Sendable {
    public let level: SignalLevel?
    public let aiSideCount: Int
    public let bandedCount: Int
    public let reliability: Reliability

    public static let disclaimer = "This measures stylistic patterns associated with AI-generated prose. It does not determine authorship."

    /// Five or more features on the AI side is rare in human writing (see
    /// Evaluation/README.md for the measured false-positive rate). Recent
    /// frontier models often read as human on these features, so a low level
    /// says little about origin.
    public static let defaultElevatedAt = 5

    /// A register may lower the Elevated threshold (fiction: four, as in
    /// Quirón's fiction band file, where fewer features have a direction).
    /// Moderate starts two below it.
    public static func level(forAISideCount n: Int, elevatedAt: Int = defaultElevatedAt) -> SignalLevel {
        if n >= elevatedAt { return .elevated }
        return n >= elevatedAt - 2 ? .moderate : .low
    }
}

public struct StyleReport: Sendable {
    public let revision: DocumentRevision
    public let profile: BaselineProfile?
    public let domain: WritingDomain
    public let measurements: [FeatureMeasurement]
    public let summary: StyleSignalSummary
    public let specificity: SpecificityReport
    public let wordCount: Int

    public var annotations: [TextAnnotation] {
        var out = specificity.annotations(revision: revision)
        for m in measurements where m.onAISide && !m.contributingRanges.isEmpty && m.contributingRanges.count <= 60 {
            let band = m.band.map { String(format: "%.1f–%.1f", $0.p10, $0.p90) } ?? "n/a"
            out.append(TextAnnotation(
                source: .aiStyle, category: .aiStyle, ranges: m.contributingRanges, severity: .info,
                message: "\(m.name): \(String(format: "%.1f", m.value)) \(m.unit)",
                explanation: "\(m.interpretation)\nTypical human range: \(band) \(m.unit). \(StyleSignalSummary.disclaimer)",
                revision: revision, metadata: ["feature": m.featureID]))
        }
        return out
    }
}

/// The statistical style engine. Pure; run it off the main actor.
public struct StyleEngine: Sendable {
    public let features: [any StatisticalFeature]
    public static let minimumWords = 120
    public static let minimumSentences = 8

    public init(features: [any StatisticalFeature] = FeatureCatalog.all) {
        self.features = features
    }

    public func analyze(_ snapshot: DocumentSnapshot, domain: WritingDomain) -> StyleReport {
        let profile = BaselineLibrary.profile(for: domain)
        return analyze(snapshot, domain: domain, profile: profile)
    }

    public func measureRaw(_ ctx: StyleContext) -> [String: Double] {
        Dictionary(uniqueKeysWithValues: features.map { ($0.id, $0.measure(ctx).value) })
    }

    public func analyze(_ snapshot: DocumentSnapshot, domain: WritingDomain, profile: BaselineProfile?) -> StyleReport {
        let ctx = StyleContext(snapshot: snapshot, aiLexicon: profile?.aiLexicon ?? Lexicon.aiLean)
        let measurements = features.map { f -> FeatureMeasurement in
            let raw = f.measure(ctx)
            let band = profile?.isBanded(f.id) == true ? profile?.bands[f.id] : nil
            return FeatureMeasurement(
                featureID: f.id, name: f.name, unit: f.unit, interpretation: f.interpretation,
                value: raw.value, rawCount: raw.count, band: band, position: band?.position(of: raw.value),
                contributingRanges: raw.ranges, profileID: profile?.id)
        }
        let reliability: Reliability
        if profile == nil {
            reliability = .insufficient("No reference data has been measured for \(domain.title.lowercased()) yet. Measurements are shown without a human range.")
        } else if ctx.wordCount < Self.minimumWords || ctx.sentences.count < Self.minimumSentences {
            reliability = .insufficient("Too short to compare: at least \(Self.minimumWords) words and \(Self.minimumSentences) sentences are needed.")
        } else if ctx.wordCount < 400 {
            reliability = .limited("Rates from under 400 words vary widely; read these as rough.")
        } else {
            reliability = .adequate
        }
        let banded = measurements.filter { $0.band != nil && $0.direction != .undetermined }
        let aiSide = banded.filter(\.onAISide).count
        let level: SignalLevel? = {
            if case .insufficient = reliability { return nil }
            return StyleSignalSummary.level(forAISideCount: aiSide, elevatedAt: profile?.elevatedAt ?? StyleSignalSummary.defaultElevatedAt)
        }()
        return StyleReport(
            revision: snapshot.revision, profile: profile, domain: domain, measurements: measurements,
            summary: StyleSignalSummary(level: level, aiSideCount: aiSide, bandedCount: banded.count, reliability: reliability),
            specificity: SpecificityAnalyzer().analyze(ctx.prose), wordCount: ctx.wordCount)
    }
}
