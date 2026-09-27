// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Which side of the human band AI-generated text of this register tends to sit.
public enum FeatureDirection: String, Codable, Sendable {
    case higherInAI = "hi"
    case lowerInAI = "lo"
    case undetermined
}

/// Human percentiles for one feature, measured on a labelled corpus.
public struct ReferenceBand: Codable, Sendable, Hashable {
    public let p10: Double
    public let p50: Double
    public let p90: Double
    public let min: Double
    public let max: Double
    /// Median of the AI reference corpus, when one was measured.
    public let ai: Double?
    /// AUC of AI vs human on the calibration corpus (0.5 = no separation).
    public let auc: Double?
    let push: String?

    public init(p10: Double, p50: Double, p90: Double, min: Double, max: Double, ai: Double?, auc: Double?, direction: FeatureDirection) {
        self.p10 = p10; self.p50 = p50; self.p90 = p90; self.min = min; self.max = max
        self.ai = ai; self.auc = auc
        self.push = direction == .undetermined ? nil : direction.rawValue
    }

    public var direction: FeatureDirection { push.flatMap(FeatureDirection.init(rawValue:)) ?? .undetermined }

    /// A value within 5% of the band width past an edge still counts as inside,
    /// so a single extra comma cannot flip a verdict.
    public static let margin = 0.05

    public func position(of value: Double) -> BandPosition {
        let slack = (p90 - p10) * Self.margin
        if value < p10 - slack { return .below }
        if value > p90 + slack { return .above }
        return .inside
    }
}

public enum BandPosition: String, Sendable, Codable {
    case below, inside, above
}

public enum WritingDomain: String, CaseIterable, Identifiable, Codable, Sendable {
    case general, technical, academic, business, fiction
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .general: "General prose"
        case .technical: "Technical writing"
        case .academic: "Academic writing"
        case .business: "Business writing"
        case .fiction: "Fiction"
        }
    }
}

/// A calibrated reference profile for one register.
public struct BaselineProfile: Sendable {
    public let id: String
    public let domain: WritingDomain
    public let title: String
    public let corpusDescription: String
    public let provenance: String
    public let humanTexts: Int
    public let aiTexts: Int
    public let bands: [String: ReferenceBand]
    /// Measured by Terso's own feature code, so every feature's definition
    /// matches its band (none need to be shown unbanded).
    public let measuredByTerso: Bool

    public init(id: String, domain: WritingDomain, title: String, corpusDescription: String, provenance: String,
                humanTexts: Int, aiTexts: Int, bands: [String: ReferenceBand], measuredByTerso: Bool = false) {
        self.id = id; self.domain = domain; self.title = title; self.corpusDescription = corpusDescription
        self.provenance = provenance; self.humanTexts = humanTexts; self.aiTexts = aiTexts
        self.bands = bands; self.measuredByTerso = measuredByTerso
    }

    /// Features compared with a band under this profile.
    public func isBanded(_ featureID: String) -> Bool {
        bands[featureID] != nil && (measuredByTerso || !FeatureCatalog.unbandedIDs.contains(featureID))
    }

    /// Parse a band file (`{"_texts": n, "feature": {p10, p50, p90, min, max, ai, auc, push}}`).
    public static func decodeBands(_ data: Data) throws -> (bands: [String: ReferenceBand], humanTexts: Int, aiTexts: Int, measuredByTerso: Bool, source: String?) {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var bands: [String: ReferenceBand] = [:]
        for (key, value) in obj where !key.hasPrefix("_") {
            guard let d = value as? [String: Any] else { continue }
            let num = { (k: String) -> Double? in (d[k] as? NSNumber)?.doubleValue }
            guard let p10 = num("p10"), let p50 = num("p50"), let p90 = num("p90") else { continue }
            bands[key] = ReferenceBand(
                p10: p10, p50: p50, p90: p90, min: num("min") ?? p10, max: num("max") ?? p90,
                ai: num("ai"), auc: num("auc"),
                direction: (d["push"] as? String).flatMap(FeatureDirection.init(rawValue:)) ?? .undetermined)
        }
        return (bands, (obj["_texts"] as? NSNumber)?.intValue ?? 0, (obj["_ai_texts"] as? NSNumber)?.intValue ?? 0,
                obj["_measured_by"] != nil, obj["_source"] as? String)
    }
}

/// Profiles shipped with the app. A domain without measured data has no
/// profile, and the UI says so rather than borrowing another register's bands.
public enum BaselineLibrary {
    /// The band parameters (percentiles, AI medians, AUCs, directions) are the
    /// published ones from Quirón; the measuring code is Terso's own.
    public static let attribution = "Reference-range parameters: Based on Quirón by ilien — https://github.com/ilien-dev/quiron (AGPL-3.0)."

    public static func profile(for domain: WritingDomain) -> BaselineProfile? {
        switch domain {
        case .general: load(
            id: "general", domain: .general, bands: "bands-general", title: "General prose (blog register)",
            corpus: "Human range: 167 blog posts by 21 authors, published before 2022. AI reference: 48 assistant posts written in 2026.")
        case .fiction: load(
            id: "fiction", domain: .fiction, bands: "bands-fiction", title: "Fiction (short stories)",
            corpus: "Human range: 157 short stories. AI reference: 32 assistant stories written in 2026.")
        case .academic: load(id: "academic", domain: .academic, bands: "bands-academic", title: "Academic writing", corpus: nil)
        case .technical: load(id: "technical", domain: .technical, bands: "bands-technical", title: "Technical writing", corpus: nil)
        case .business: load(id: "business", domain: .business, bands: "bands-business", title: "Business writing", corpus: nil)
        }
    }

    public static var availableDomains: [WritingDomain] { WritingDomain.allCases.filter { profile(for: $0) != nil } }

    /// Quirón-derived files carry Quirón's attribution; Terso's own
    /// measurements describe their corpus in `_source`.
    static func load(id: String, domain: WritingDomain, bands: String, title: String, corpus: String?) -> BaselineProfile? {
        guard let url = Bundle.module.url(forResource: bands, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? BaselineProfile.decodeBands(data) else { return nil }
        let own = decoded.measuredByTerso
        return BaselineProfile(
            id: id, domain: domain, title: title,
            corpusDescription: corpus ?? decoded.source ?? "Measured by Terso.",
            provenance: own ? "Reference ranges measured by Terso (terso-eval calibrate). See Evaluation/README.md." : attribution,
            humanTexts: decoded.humanTexts, aiTexts: decoded.aiTexts, bands: decoded.bands, measuredByTerso: own)
    }
}
