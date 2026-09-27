// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import TersoCore

/// Scientific checks use the existing WritingRule contract and Review output.
public struct ScientificRule: WritingRule {
    public enum Check: String, CaseIterable, Sendable { case notation, quantities, references, claims, evidence }
    public let check: Check
    public var id: String { "science.\(check.rawValue)" }
    public var name: String { category.title }
    public var description: String { "Local structural checks; no assessment of scientific correctness." }
    public var category: AnnotationCategory {
        switch check {
        case .notation: .notation
        case .quantities: .quantities
        case .references: .references
        case .claims: .claims
        case .evidence: .evidence
        }
    }
    public init(_ check: Check) { self.check = check }
    public func analyze(_ context: AnalysisContext) -> [WritingIssue] {
        let model = context.science
        guard !model.profile.disabledRules.contains(id) else { return [] }
        return model.diagnostics.filter { $0.id.hasPrefix(id + ".") }.map { diagnostic in
            let ruleID = String(diagnostic.id.split(separator: ":")[0])
            var spans = [diagnostic.sourceRange]
            for objectID in diagnostic.relatedObjectIDs {
                if objectID.hasPrefix("symbol:"), let symbol = model.symbols.first(where: { "symbol:\($0.id)" == objectID }) {
                    if ruleID == "science.notation.undefined", let definition = symbol.definitions.first {
                        spans += symbol.occurrences.filter { $0.location < definition.location } + [definition]
                    } else { spans += symbol.occurrences }
                } else if let definition = model.definitions.first(where: { $0.id == objectID }) {
                    // Navigate the introduction, not unrelated sentences in its paragraph.
                    spans.append(definition.definitionOccurrence)
                } else if let node = model.node(id: objectID) { spans.append(node.sourceRange) }
            }
            var seen: Set<TextSpan> = []
            spans = spans.filter { seen.insert($0).inserted }
            return WritingIssue(ruleID: ruleID,
                severity: diagnostic.severity == .info ? .info : diagnostic.confidence == .high ? .warning : .suggestion,
                category: category, message: diagnostic.title, explanation: diagnostic.explanation,
                ranges: spans, originalText: context.snapshot.substring(diagnostic.sourceRange) ?? "",
                metadata: ["profile": model.profile.id, "scienceDiagnosticID": diagnostic.id,
                    "scienceObjectID": diagnostic.relatedObjectIDs.first ?? ""])
        }
    }
}
