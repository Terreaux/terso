// SPDX-License-Identifier: AGPL-3.0-only
// terso-eval — evaluation harness for the statistical style engine.
import Foundation
import TersoCore
import TersoStyle
import TersoAnalysis

let usage = """
terso-eval — measure and evaluate style features

  terso-eval measure DIR [--out FILE.json]
      Per-text feature values for every .md/.txt in DIR.
  terso-eval calibrate --human DIR [--ai DIR] --out BANDS.json [--source TEXT] [--lexicon NAME]
      p10/p50/p90 of every feature over the human texts; with --ai, the AI median,
      AUC and direction per feature. Use the CALIBRATION split, never held-out.
      --lexicon picks the bundled AI-lean list for ai_lexicon_1k (default ai-lean;
      ai-lean-fiction for fiction) and is recorded in the band file.
  terso-eval evaluate --human DIR [--ai DIR] [--bands BANDS.json] [--label NAME] [--out REPORT.json]
      Level distributions, human false positives (ELEVATED on human text),
      AI detection rate where labels exist, per-feature AUC and how often
      human texts fall outside each band. Defaults to the shipped general bands.
  terso-eval compare BEFORE.json AFTER.json
      Regression report between two evaluate runs: false-positive movement,
      AI-corpus movement, feature distribution movement, changed documents.
  terso-eval story-shape DIR [--out REPORT.json] [--verbose]
      Run fiction-only story-shape rules on individual stories in DIR.

Texts shorter than \(StyleEngine.minimumWords) words or \(StyleEngine.minimumSentences) sentences are skipped.
"""

// MARK: - Helpers

func texts(in dir: String) -> [(String, String)] {
    let url = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
    let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
    return items.filter { ["md", "txt", "markdown"].contains($0.pathExtension.lowercased()) }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        .compactMap { u in (try? String(contentsOf: u, encoding: .utf8)).map { (u.lastPathComponent, $0) } }
}

struct Row: Codable {
    let file: String
    let words: Int
    let features: [String: Double]
}

/// The AI-lean list `measure` uses for ai_lexicon_1k.
let lexiconName = arg("--lexicon", CommandLine.arguments)
let measureLexicon = lexiconName.map(Lexicon.load) ?? Lexicon.aiLean

func measure(_ dir: String) -> [Row] {
    let engine = StyleEngine()
    return texts(in: dir).compactMap { name, text in
        let ctx = StyleContext(snapshot: DocumentSnapshot(revision: DocumentRevision(0), text: text), aiLexicon: measureLexicon)
        guard ctx.wordCount >= StyleEngine.minimumWords, ctx.sentences.count >= StyleEngine.minimumSentences else { return nil }
        return Row(file: name, words: ctx.wordCount, features: engine.measureRaw(ctx))
    }
}

func median(_ v: [Double]) -> Double {
    let s = v.sorted(); guard !s.isEmpty else { return 0 }
    return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
}
/// P(AI value > human value), ties count half.
func quantile(_ sorted: [Double], _ p: Double) -> Double { sorted[min(Int(p * Double(sorted.count)), sorted.count - 1)] }

func auc(ai: [Double], human: [Double]) -> Double {
    guard !ai.isEmpty, !human.isEmpty else { return 0.5 }
    var s = 0.0
    for a in ai { for h in human { s += a > h ? 1 : (a == h ? 0.5 : 0) } }
    return s / Double(ai.count * human.count)
}
func fmt(_ v: Double, _ d: Int = 3) -> String { String(format: "%.\(d)f", v) }
func arg(_ name: String, _ args: [String]) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
func writeJSON<T: Encodable>(_ v: T, to path: String) throws {
    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    try enc.encode(v).write(to: URL(fileURLWithPath: path))
}

let featureIDs = FeatureCatalog.all.map(\.id)

// MARK: - Commands

func calibrate(_ args: [String]) throws {
    guard let humanDir = arg("--human", args), let out = arg("--out", args) else { print(usage); exit(2) }
    let human = measure(humanDir)
    guard human.count >= 20 else { FileHandle.standardError.write(Data("need at least 20 usable human texts, got \(human.count)\n".utf8)); exit(1) }
    let ai = arg("--ai", args).map(measure)
    var obj: [String: Any] = ["_texts": human.count, "_measured_by": "terso-eval calibrate",
                              "_date": ISO8601DateFormatter().string(from: Date()).prefix(10).description]
    if let src = arg("--source", args) { obj["_source"] = src }
    if let lexiconName { obj["_lexicon"] = lexiconName }
    if let ai { obj["_ai_texts"] = ai.count }
    print("calibrated on \(human.count) human texts" + (ai.map { " and \($0.count) AI texts" } ?? ""))
    for id in featureIDs {
        let v = human.map { $0.features[id] ?? 0 }.sorted()
        var band: [String: Any] = ["p10": quantile(v, 0.1), "p50": quantile(v, 0.5), "p90": quantile(v, 0.9), "min": v.first!, "max": v.last!]
        var line = "  \(id.padding(toLength: 22, withPad: " ", startingAt: 0)) p10 \(fmt(quantile(v, 0.1), 2).leftPad(8))  p50 \(fmt(quantile(v, 0.5), 2).leftPad(8))  p90 \(fmt(quantile(v, 0.9), 2).leftPad(8))"
        if let ai {
            let av = ai.map { $0.features[id] ?? 0 }
            let a = auc(ai: av, human: v)
            band["ai"] = median(av)
            band["auc"] = a
            // Direction only where AI and human text separate on this split.
            band["push"] = a >= 0.6 ? "hi" as Any : (a <= 0.4 ? "lo" as Any : NSNull())
            line += "  AI \(fmt(median(av), 2).leftPad(8))  AUC \(fmt(a, 2))"
        }
        obj[id] = band
        print(line)
    }
    try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: out))
    print("→ \(out)")
}

struct DocResult: Codable {
    let file: String
    let group: String
    let words: Int
    let aiSideCount: Int
    let level: String
    let aiSideFeatures: [String]
}

struct FeatureStats: Codable {
    let humanMedian: Double
    let aiMedian: Double?
    let auc: Double?
    let humanOutsideRate: Double
}

struct EvalReport: Codable {
    let label: String
    let bands: String
    let createdAt: Date
    let documents: [DocResult]
    let features: [String: FeatureStats]

    func docs(_ group: String) -> [DocResult] { documents.filter { $0.group == group } }
    func rate(_ group: String, _ level: String) -> Double {
        let d = docs(group); return d.isEmpty ? 0 : Double(d.filter { $0.level == level }.count) / Double(d.count)
    }
}

func evaluate(_ args: [String]) throws {
    guard let humanDir = arg("--human", args) else { print(usage); exit(2) }
    let profile: BaselineProfile
    let bandsPath = arg("--bands", args) ?? "shipped:general"
    if let path = arg("--bands", args) {
        let decoded = try BaselineProfile.decodeBands(Data(contentsOf: URL(fileURLWithPath: path)))
        profile = BaselineProfile(id: "eval", domain: .general, title: "eval", corpusDescription: "", provenance: "",
                                  humanTexts: decoded.humanTexts, aiTexts: decoded.aiTexts, bands: decoded.bands,
                                  measuredByTerso: decoded.measuredByTerso, aiLexicon: decoded.aiLexicon,
                                  elevatedAt: decoded.elevatedAt)
    } else {
        guard let shipped = BaselineLibrary.profile(for: .general) else { throw CocoaError(.fileNoSuchFile) }
        profile = shipped
    }
    let engine = StyleEngine()
    var groups: [(String, [(String, String)])] = [("human", texts(in: humanDir))]
    if let aiDir = arg("--ai", args) { groups.append(("ai", texts(in: aiDir))) }
    var docs: [DocResult] = []
    var values: [String: [String: [Double]]] = [:]
    for (group, items) in groups {
        for (name, text) in items {
            let r = engine.analyze(DocumentSnapshot(revision: DocumentRevision(0), text: text), domain: .general, profile: profile)
            guard let level = r.summary.level else { continue }
            docs.append(DocResult(file: name, group: group, words: r.wordCount, aiSideCount: r.summary.aiSideCount,
                                  level: level.rawValue, aiSideFeatures: r.measurements.filter(\.onAISide).map(\.featureID)))
            for m in r.measurements { values[group, default: [:]][m.featureID, default: []].append(m.value) }
        }
    }
    var feats: [String: FeatureStats] = [:]
    for id in featureIDs {
        let h = values["human"]?[id] ?? []
        let a = values["ai"]?[id]
        let outside = profile.bands[id].map { b in Double(h.filter { b.position(of: $0) != .inside }.count) / Double(max(h.count, 1)) } ?? 0
        feats[id] = FeatureStats(humanMedian: median(h), aiMedian: a.map(median), auc: a.map { auc(ai: $0, human: h) }, humanOutsideRate: outside)
    }
    let report = EvalReport(label: arg("--label", args) ?? "run", bands: bandsPath, createdAt: Date(), documents: docs, features: feats)
    printReport(report)
    if let out = arg("--out", args) { try writeJSON(report, to: out); print("→ \(out)") }
}

func printReport(_ r: EvalReport) {
    print("\nEVALUATION  \(r.label)  (bands: \(r.bands))\n")
    for g in ["human", "ai"] where !r.docs(g).isEmpty {
        let d = r.docs(g)
        let mean = Double(d.map(\.aiSideCount).reduce(0, +)) / Double(d.count)
        print("  \(g.padding(toLength: 6, withPad: " ", startingAt: 0)) n=\(d.count)  mean AI-side features \(fmt(mean, 2))  LOW \(fmt(r.rate(g, "Low") * 100, 0))%  MODERATE \(fmt(r.rate(g, "Moderate") * 100, 0))%  ELEVATED \(fmt(r.rate(g, "Elevated") * 100, 0))%")
    }
    if !r.docs("human").isEmpty { print("\n  human false-positive rate (ELEVATED): \(fmt(r.rate("human", "Elevated") * 100, 1))%") }
    if !r.docs("ai").isEmpty { print("  AI corpus reaching ELEVATED:          \(fmt(r.rate("ai", "Elevated") * 100, 1))%  (misses: \(fmt((1 - r.rate("ai", "Elevated")) * 100, 1))%)") }
    print("\n  feature                 human p50     AI p50     AUC   human outside band")
    for id in featureIDs {
        guard let f = r.features[id] else { continue }
        print("  \(id.padding(toLength: 22, withPad: " ", startingAt: 0)) \(fmt(f.humanMedian, 2).leftPad(10)) \((f.aiMedian.map { fmt($0, 2) } ?? "-").leftPad(10)) \((f.auc.map { fmt($0, 2) } ?? "-").leftPad(7)) \(fmt(f.humanOutsideRate * 100, 0).leftPad(8))%")
    }
}

func compare(_ args: [String]) throws {
    guard args.count >= 2 else { print(usage); exit(2) }
    let dec = JSONDecoder()
    let before = try dec.decode(EvalReport.self, from: Data(contentsOf: URL(fileURLWithPath: args[0])))
    let after = try dec.decode(EvalReport.self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
    print("\nREGRESSION  \(before.label) → \(after.label)\n")
    for g in ["human", "ai"] {
        for level in ["Low", "Moderate", "Elevated"] {
            let b = before.rate(g, level), a = after.rate(g, level)
            if before.docs(g).isEmpty && after.docs(g).isEmpty { continue }
            let arrow = a > b ? "▲" : (a < b ? "▼" : " ")
            print("  \(g.padding(toLength: 6, withPad: " ", startingAt: 0)) \(level.padding(toLength: 9, withPad: " ", startingAt: 0)) \(fmt(b * 100, 1).leftPad(6))% → \(fmt(a * 100, 1).leftPad(6))%  \(arrow)")
        }
    }
    print("\n  human false positives: \(fmt(before.rate("human", "Elevated") * 100, 1))% → \(fmt(after.rate("human", "Elevated") * 100, 1))%")
    print("\n  feature distribution movement (human median / AUC)")
    for id in featureIDs {
        guard let b = before.features[id], let a = after.features[id] else { continue }
        let dm = a.humanMedian - b.humanMedian
        let da = (a.auc ?? 0.5) - (b.auc ?? 0.5)
        if abs(dm) > 1e-9 || abs(da) > 1e-9 {
            print("  \(id.padding(toLength: 22, withPad: " ", startingAt: 0)) median \(fmt(b.humanMedian, 2)) → \(fmt(a.humanMedian, 2))   AUC \((b.auc.map { fmt($0, 2) } ?? "-")) → \((a.auc.map { fmt($0, 2) } ?? "-"))")
        }
    }
    let bmap = Dictionary(before.documents.map { ("\($0.group)/\($0.file)", $0) }, uniquingKeysWith: { a, _ in a })
    let changed = after.documents.compactMap { d -> String? in
        guard let old = bmap["\(d.group)/\(d.file)"], old.level != d.level else { return nil }
        return "  \(d.group)/\(d.file): \(old.level) → \(d.level)  (AI-side \(old.aiSideCount) → \(d.aiSideCount))"
    }
    print("\n  documents whose level changed: \(changed.count)")
    changed.forEach { print($0) }
}

struct StoryShapeRow: Codable {
    let file: String
    let words: Int
    let ruleCounts: [String: Int]
}

func storyShape(_ args: [String]) throws {
    guard let dir = args.first else { print(usage); exit(2) }
    let analyzer = WritingAnalyzer(rules: StoryShape.rules)
    var rows: [StoryShapeRow] = []
    for (file, text) in texts(in: dir) where !file.hasPrefix("pg") && file != "manifest.txt" {
        let result = analyzer.analyze(DocumentSnapshot(revision: DocumentRevision(0), text: text))
        var counts: [String: Int] = [:]
        for issue in result.issues {
            counts[issue.ruleID, default: 0] += 1
            if args.contains("--verbose") {
                print("  \(file): \(issue.ruleID) \(issue.metadata): \(issue.originalText.prefix(160).replacingOccurrences(of: "\n", with: " "))")
            }
        }
        rows.append(StoryShapeRow(file: file, words: result.statistics.words, ruleCounts: counts))
    }
    for id in StoryShape.rules.map(\.id) {
        let documents = rows.filter { ($0.ruleCounts[id] ?? 0) > 0 }.count
        let findings = rows.reduce(0) { $0 + ($1.ruleCounts[id] ?? 0) }
        print("\(id): \(documents)/\(rows.count) stories, \(findings) findings")
    }
    if let out = arg("--out", args) { try writeJSON(rows, to: out); print("→ \(out)") }
}

extension String {
    func leftPad(_ n: Int) -> String { count >= n ? self : String(repeating: " ", count: n - count) + self }
}

// MARK: - Main

let args = Array(CommandLine.arguments.dropFirst())
do {
    switch args.first {
    case "measure":
        guard args.count >= 2 else { print(usage); exit(2) }
        let rows = measure(args[1])
        if let out = arg("--out", args) { try writeJSON(rows, to: out); print("\(rows.count) texts → \(out)") }
        else { for r in rows { print(r.file, r.words, featureIDs.map { "\($0)=\(fmt(r.features[$0] ?? 0, 2))" }.joined(separator: " ")) } }
    case "calibrate": try calibrate(Array(args.dropFirst()))
    case "evaluate": try evaluate(Array(args.dropFirst()))
    case "compare": try compare(Array(args.dropFirst()))
    case "story-shape": try storyShape(Array(args.dropFirst()))
    default: print(usage)
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
