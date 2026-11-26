// SPDX-License-Identifier: AGPL-3.0-only
import TersoCore

public extension LocalAnalysisResult {
    /// Replace only the single-file reference checks with the active file's
    /// manuscript findings, keeping every editor span in this snapshot.
    func withManuscriptReferences(_ findings: [(rule: String, title: String, detail: String, range: TextSpan)],
                                  snapshot: DocumentSnapshot, resolvedLabels: Set<String> = []) -> LocalAnalysisResult {
        var model = science
        let linkedClaims = Set(model.claims.filter { claim in
            claim.type == .strongConclusion && claim.nearbyReferences.contains {
                !$0.isCitation && resolvedLabels.contains($0.key) && claim.sourceRange.intersects($0.sourceRange)
            }
        }.map(\.sourceRange))
        var revised = issues.filter { issue in
            !issue.ruleID.hasPrefix("science.references.") &&
            !(issue.ruleID == "science.evidence.strong" && issue.ranges.first.map(linkedClaims.contains) == true)
        }
        model.diagnostics.removeAll {
            $0.id.hasPrefix("science.references.") || ($0.id.hasPrefix("science.evidence.strong:") && linkedClaims.contains($0.sourceRange))
        }
        if !model.profile.disabledRules.contains("science.references") {
            for finding in findings {
                let rule = "science.references." + finding.rule
                let info = finding.rule == "unused"
                let id = "\(rule):\(finding.range.location):\(finding.title)"
                let diag = ScientificDiagnostic(id: id, severity: info ? .info : .warning, category: .references, title: finding.title,
                    explanation: finding.detail, sourceRange: finding.range, relatedObjectIDs: [], confidence: info ? .medium : .high,
                    suggestedActions: ["Go to text", "Review manuscript references"])
                model.diagnostics.append(diag)
                revised.append(.init(ruleID: rule, severity: info ? .info : .warning, category: .references,
                    message: finding.title, explanation: finding.detail, ranges: [finding.range], originalText: snapshot.substring(finding.range) ?? "",
                    metadata: ["profile": model.profile.id, "scienceDiagnosticID": id]))
            }
        }
        revised.sort { ($0.ranges.first?.location ?? 0) < ($1.ranges.first?.location ?? 0) }
        model.diagnostics.sort { ($0.severity.order, $0.sourceRange.location, $0.id) < ($1.severity.order, $1.sourceRange.location, $1.id) }
        return LocalAnalysisResult(revision: revision, issues: revised, statistics: statistics, science: model, headings: headings)
    }
}
