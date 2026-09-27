// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import TersoCore

public enum ScientificConfidence: String, Codable, Sendable { case high, medium, low }
public enum ScientificSymbolType: String, Codable, Sendable { case variable, vector, tensor, `operator`, index, constant, function, unknown }
public enum ScientificDefinitionStatus: String, Codable, Sendable { case defined, undefined, assumedKnowledge }
public enum ScientificClaimCategory: String, Codable, Sendable { case empirical, theoretical, methodological, comparative, background, interpretation, authorStatement, unknown }
public enum ScientificReviewStatus: String, Codable, Sendable { case unreviewed, reviewed, ignored, authorStatement }
public enum ScientificDiagnosticSeverity: String, Codable, Sendable { case error, warning, info
    public var order: Int { switch self { case .error: 0; case .warning: 1; case .info: 2 } }
}
public enum ScientificDiagnosticCategory: String, Codable, Sendable { case notation, definitions, quantities, equations, references, claims, evidence }
public struct ScientificDiagnostic: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let severity: ScientificDiagnosticSeverity
    public let category: ScientificDiagnosticCategory
    public let title: String
    public let explanation: String
    public let sourceRange: TextSpan
    public let relatedObjectIDs: [String]
    public let confidence: ScientificConfidence
    public let suggestedActions: [String]
}
public struct ScientificDefinition: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let term: String
    public let text: String
    public let sourceRange: TextSpan
    public let symbolID: String
    public let usages: [TextSpan]
    public let definitionOccurrence: TextSpan
    public var usedBeforeDefinition: Bool { usages.contains { $0.location < definitionOccurrence.location } }
}
public struct ScientificEquation: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let sourceRange: TextSpan
    public let contents: String
    public let label: String?
    public let symbolIDs: [String]
    public let introducedSymbolIDs: [String]
    public let references: [ScientificReference]
    /// Future dimension checking needs declared dimensions; this parser does not infer them.
    public var dimensionCheckAvailable: Bool { false }
}
public struct ScientificNode: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let title: String
    public let kind: String
    public let sourceRange: TextSpan
}
public struct ScientificRelationship: Identifiable, Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case defines, uses, represents, cites, nearbyEvidence, references }
    public var id: String { "\(sourceID):\(kind.rawValue):\(targetID)" }
    public let sourceID: String
    public let targetID: String
    public let kind: Kind
}
public extension ScientificSymbol {
    var usageCount: Int { occurrences.count }
    var confidence: ScientificConfidence { definitions.isEmpty ? .low : .medium }
    var meaning: String? { guard let definition = definitions.first, let index = occurrences.firstIndex(of: definition) else { return nil }; return contexts[index] }
    var symbolType: ScientificSymbolType { canonicalForm.contains("\\vec") || canonicalForm.contains("\\mathbf") || canonicalForm.contains("\\boldsymbol") ? .vector : .unknown }
}
public extension ScientificClaim {
    var category: ScientificClaimCategory {
        switch type { case .authorStatement: .authorStatement; case .methodological: .methodological; case .background: .background; case .quantitative: .empirical; case .comparative, .agreement: .comparative; case .causal, .strongConclusion: .interpretation; case .novelty: .unknown }
    }
    var confidence: ScientificConfidence { .low }
    var reviewStatus: ScientificReviewStatus { .unreviewed }
    var objectID: String { "claim:\(id)" }
}
public extension ScientificEvidence {
    var id: String { "evidence:\(kind.rawValue):\(sourceRange.location):\(text)" }
}
/// Candidate provenance remains explicit about proximity: it does not assert that
/// a citation actually supplies the value.
public struct ScientificQuantityMetadata: Sendable, Hashable, Codable {
    public let occurrences: [TextSpan]
    public let nearbyCitationIDs: [String]
    public let semanticMeaning: String?
    public let unitDimension: String?
}
public extension ScientificDocumentModel {
    var citations: [ScientificReference] { references.filter(\.isCitation) }
    var crossReferences: [ScientificReference] { references.filter { !$0.isCitation } }
    func definitionStatus(for symbol: ScientificSymbol) -> ScientificDefinitionStatus { !symbol.definitions.isEmpty ? .defined : profile.commonSymbols.contains(symbol.canonicalForm) ? .assumedKnowledge : .undefined }
    func quantityMetadata(for quantity: ScientificQuantity) -> ScientificQuantityMetadata {
        let matching = quantity.symbol.map { symbol in quantities.filter { $0.symbol == symbol } } ?? [quantity]
        let citationIDs = Set(citations.map { "reference:\($0.id)" })
        let nearby = relationships.filter { $0.sourceID == "quantity:\(quantity.id)" && $0.kind == .nearbyEvidence && citationIDs.contains($0.targetID) }.map(\.targetID)
        return ScientificQuantityMetadata(occurrences: matching.map(\.sourceRange), nearbyCitationIDs: nearby,
            semanticMeaning: quantity.symbol.flatMap { symbol in symbols.first { $0.id == symbol }?.meaning },
            unitDimension: quantity.normalizedUnit.flatMap { profile.unitDimensions[$0] })
    }
    func node(id: String) -> ScientificNode? { nodes.first { $0.id == id } }
}

extension ScientificDocumentModel {
    mutating func buildScientificGraph(source: String, originalSource: String) {
        let ns = source as NSString
        let originalNS = originalSource as NSString
        func diagnostic(_ key: String, _ category: ScientificDiagnosticCategory, _ title: String, _ explanation: String, _ range: TextSpan, _ ids: [String], severity: ScientificDiagnosticSeverity = .warning, confidence: ScientificConfidence = .medium) -> ScientificDiagnostic {
            ScientificDiagnostic(id: "science.\(key):\(range.location):\(ids.joined(separator: "|"))", severity: severity, category: category, title: title, explanation: explanation, sourceRange: range, relatedObjectIDs: ids, confidence: confidence, suggestedActions: ["Go to text", "Inspect related objects"])
        }
        for symbol in symbols {
            if Task.isCancelled { return }
            let sid = "symbol:\(symbol.id)"
            nodes.append(.init(id: sid, title: symbol.displayForm, kind: "Notation", sourceRange: symbol.firstOccurrence))
            for span in symbol.definitions {
                let paragraph = ns.paragraphRange(for: span.nsRange)
                let did = "definition:\(span.location)"
                definitions.append(.init(id: did, term: symbol.displayForm, text: originalNS.substring(with: paragraph).trimmingCharacters(in: .whitespacesAndNewlines), sourceRange: TextSpan(paragraph), symbolID: sid, usages: symbol.occurrences, definitionOccurrence: span))
                nodes.append(.init(id: did, title: symbol.displayForm, kind: "Definition", sourceRange: TextSpan(paragraph)))
                relationships.append(.init(sourceID: did, targetID: sid, kind: .defines))
            }
            if symbol.usageCount == 1 && !symbol.definitions.isEmpty && !profile.commonSymbols.contains(symbol.id) {
                diagnostics.append(diagnostic("notation.unused", .notation, "Definition without a detected use: \(symbol.displayForm)", "The notation appears only at its detected definition. Prose uses or external documents may not be indexed.", symbol.firstOccurrence, [sid], severity: .info, confidence: .low))
            }
            if let firstDefinition = symbol.definitions.first, symbol.firstOccurrence.location < firstDefinition.location {
                diagnostics.append(diagnostic("notation.undefined", .definitions, "Notation used before definition: \(symbol.displayForm)", "A likely explicit definition appears later. Check whether the earlier use needs an introduction.", symbol.firstOccurrence, [sid, "definition:\(firstDefinition.location)"]))
            } else if symbol.definitions.isEmpty && !profile.commonSymbols.contains(symbol.canonicalForm) && symbol.usageCount >= profile.minimumUndefinedUses {
                diagnostics.append(diagnostic("notation.undefined", .notation, "Possibly undefined notation: \(symbol.displayForm)", "No explicit definition was detected for \(symbol.usageCount) mathematical occurrences. This may be assumed knowledge or defined outside this document.", symbol.firstOccurrence, [sid], confidence: .low))
            }
        }
        // Explicit prose definitions only: no dictionary of technical terms is guessed.
        for match in SciencePattern.matches(#"(?i)\b(?:we\s+define\s+([A-Za-z][A-Za-z-]{0,40})\s+as|let\s+([A-Za-z][A-Za-z-]{0,40})\s+denote|([A-Za-z][A-Za-z-]{0,40})\s+is\s+defined\s+as)\b[^.!?\n]*"#, source) {
            guard !regions.contains(where: { $0.kind != .prose && $0.range.contains(match.range.location) }) else { continue }
            let termRange = (1...3).map { match.range(at: $0) }.first { $0.location != NSNotFound }!
            let term = ns.substring(with: termRange)
            let did = "definition:\(termRange.location)"
            guard !definitions.contains(where: { $0.id == did }) else { continue }
            let sid = "term:\(term.lowercased())"
            let usages = SciencePattern.matches("\\b" + NSRegularExpression.escapedPattern(for: term) + "\\b", source)
                .filter { match in regions.contains { $0.kind == .prose && $0.range.contains(match.range.location) } }
                .map { TextSpan($0.range) }
            definitions.append(.init(id: did, term: term, text: originalNS.substring(with: match.range), sourceRange: TextSpan(match.range), symbolID: sid, usages: usages, definitionOccurrence: TextSpan(termRange)))
            nodes.append(.init(id: did, title: term, kind: "Definition", sourceRange: TextSpan(match.range)))
            if !nodes.contains(where: { $0.id == sid }) { nodes.append(.init(id: sid, title: term, kind: "Term", sourceRange: usages.first ?? TextSpan(termRange))) }
            relationships.append(.init(sourceID: did, targetID: sid, kind: .defines))
        }
        let variantGroups = Dictionary(grouping: symbols) { symbol in
            symbol.canonicalForm.replacingOccurrences(of: #"\\(?:mathrm|text|mathit)\{([A-Za-z])\}"#, with: "$1", options: .regularExpression)
                .replacingOccurrences(of: #"([_^])\{([A-Za-z])\}"#, with: "$1$2", options: .regularExpression)
        }
        for key in variantGroups.keys.sorted() {
            let group = variantGroups[key]!
            if group.count > 1 { diagnostics.append(diagnostic("notation.variants", .notation, "Possible notation inconsistency", group.map(\.displayForm).joined(separator: ", ") + ": review whether these forms should share a convention. Equivalence is not assumed.", group.flatMap(\.occurrences).sorted()[0], group.map { "symbol:\($0.id)" }, confidence: .low)) }
        }
        for symbol in symbols {
            if let preferred = profile.preferredNotation[symbol.id], preferred != symbol.id { diagnostics.append(diagnostic("notation.preferred", .notation, "Project notation preference", "The configured preference for \(symbol.displayForm) is \(preferred).", symbol.firstOccurrence, ["symbol:\(symbol.id)"], severity: .info)) }
        }
        for region in regions where region.kind == .displayMath {
            guard !ns.substring(with: region.range.nsRange).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            if Task.isCancelled { return }
            let eid = "equation:\(region.range.location)"
            let labels = objects.filter { region.range.intersects($0.sourceRange) }
            let uses = symbols.filter { $0.occurrences.contains { region.range.intersects($0) } }
            equations.append(.init(id: eid, sourceRange: region.range, contents: originalNS.substring(with: region.contentRange.nsRange), label: labels.first?.key, symbolIDs: uses.map { "symbol:\($0.id)" }, introducedSymbolIDs: uses.filter { $0.definitions.contains { region.range.intersects($0) } }.map { "symbol:\($0.id)" }, references: labels.flatMap(\.references)))
            nodes.append(.init(id: eid, title: labels.first?.key ?? "Equation", kind: "Equation", sourceRange: region.range))
            for label in labels { relationships.append(.init(sourceID: "object:\(label.id)", targetID: eid, kind: .references)) }
            relationships += uses.map { .init(sourceID: eid, targetID: "symbol:\($0.id)", kind: .uses) }
        }
        let indexedCitations = citations
        func citationsIntersecting(_ range: TextSpan) -> [ScientificReference] {
            var low = 0, high = indexedCitations.count
            while low < high {
                let mid = (low + high) / 2
                if indexedCitations[mid].sourceRange.upperBound <= range.location { low = mid + 1 } else { high = mid }
            }
            var matches: [ScientificReference] = [], index = low
            while index < indexedCitations.count && indexedCitations[index].sourceRange.location < range.upperBound {
                if range.intersects(indexedCitations[index].sourceRange) { matches.append(indexedCitations[index]) }
                index += 1
            }
            return matches
        }
        let symbolIDs = Set(symbols.map(\.id))
        for quantity in quantities {
            let qid = "quantity:\(quantity.id)"
            nodes.append(.init(id: qid, title: quantity.rawText, kind: "Quantity", sourceRange: quantity.sourceRange))
            let paragraph = TextSpan(ns.paragraphRange(for: quantity.sourceRange.nsRange))
            for reference in citationsIntersecting(paragraph) { relationships.append(.init(sourceID: qid, targetID: "reference:\(reference.id)", kind: .nearbyEvidence)) }
            if let symbol = quantity.symbol, symbolIDs.contains(symbol) { relationships.append(.init(sourceID: qid, targetID: "symbol:\(symbol)", kind: .represents)) }
        }
        for reference in references { nodes.append(.init(id: "reference:\(reference.id)", title: reference.key, kind: reference.isCitation ? "Citation" : "Cross-reference", sourceRange: reference.sourceRange)) }
        for object in objects { nodes.append(.init(id: "object:\(object.id)", title: object.key, kind: object.kind.rawValue, sourceRange: object.sourceRange)) }
        let labels = Dictionary(grouping: objects, by: \.key)
        for reference in crossReferences {
            if let targets = labels[reference.key] {
                for target in targets { relationships.append(.init(sourceID: "reference:\(reference.id)", targetID: "object:\(target.id)", kind: .references)) }
            } else { diagnostics.append(diagnostic("references.missing", .references, "Broken reference: \(reference.key)", "No matching label exists in this document. External files are not resolved.", reference.sourceRange, ["reference:\(reference.id)"], confidence: .high)) }
        }
        let bibliographyKeys = Set(SciencePattern.matches(#"\\bibitem(?:\[[^\]]*\])?\{([^{}]+)\}"#, source).map { ns.substring(with: $0.range(at: 1)) })
        if !bibliographyKeys.isEmpty && !SciencePattern.has(#"\\(?:bibliography|addbibresource)\b"#, source) {
            for reference in citations where !bibliographyKeys.contains(reference.key) {
                diagnostics.append(diagnostic("references.citation", .references, "Citation missing from local bibliography: \(reference.key)", "A local bibliography is present, but this citation key has no matching bibitem. An external bibliography may still supply it.", reference.sourceRange, ["reference:\(reference.id)"], confidence: .medium))
            }
        }
        for key in labels.keys.sorted() {
            let group = labels[key]!
            if group.count > 1 { diagnostics.append(diagnostic("references.duplicate", group[0].kind == .equation ? .equations : .references, "Duplicate label: \(key)", "The label is declared \(group.count) times in this document.", group[0].sourceRange, group.map { "object:\($0.id)" }, confidence: .high)) }
            if group[0].references.isEmpty { diagnostics.append(diagnostic("references.unused", .references, "Unreferenced label: \(key)", "No local reference to this labeled object was detected. This may be intentional.", group[0].sourceRange, group.map { "object:\($0.id)" }, severity: .info)) }
        }
        let referencesBySpan = Dictionary(grouping: references, by: \.sourceRange)
        let quantitiesBySpan = Dictionary(grouping: quantities, by: \.sourceRange)
        var evidenceIDs: Set<String> = []
        for claim in claims {
            if Task.isCancelled { return }
            nodes.append(.init(id: claim.objectID, title: claim.text, kind: "Claim", sourceRange: claim.sourceRange))
            for item in claim.nearbyEvidence {
                if evidenceIDs.insert(item.id).inserted {
                    evidence.append(item)
                    nodes.append(.init(id: item.id, title: item.text, kind: "Evidence", sourceRange: item.sourceRange))
                    for reference in referencesBySpan[item.sourceRange] ?? [] where reference.key == item.text { relationships.append(.init(sourceID: item.id, targetID: "reference:\(reference.id)", kind: .references)) }
                    for quantity in quantitiesBySpan[item.sourceRange] ?? [] { relationships.append(.init(sourceID: item.id, targetID: "quantity:\(quantity.id)", kind: .represents)) }
                }
                relationships.append(.init(sourceID: claim.objectID, targetID: item.id, kind: .nearbyEvidence))
            }
            for reference in claim.nearbyReferences where reference.isCitation && claim.sourceRange.intersects(reference.sourceRange) { relationships.append(.init(sourceID: claim.objectID, targetID: "reference:\(reference.id)", kind: .cites)) }
            if claim.category != .authorStatement && ((claim.type == .strongConclusion && !claim.nearbyEvidence.contains { [.citation, .reference, .quantity].contains($0.kind) }) || (claim.type == .novelty && !claim.nearbyEvidence.contains { $0.kind == .citation })) {
                diagnostics.append(diagnostic(claim.type == .novelty ? "claims.novelty" : "evidence.strong", claim.type == .novelty ? .claims : .evidence, "Claim support needs review", "No explicit \(claim.type == .novelty ? "citation" : "citation, resolved cross-reference, or quantity") was detected in the same paragraph. Proximity is not proof; inspect the wording and its support.", claim.sourceRange, [claim.objectID], confidence: .low))
            }
        }
        for (_, values) in Dictionary(grouping: quantities.filter { $0.symbol != nil && $0.normalizedUnit != nil }, by: { "\($0.symbol!)|\($0.normalizedUnit!)" }) where Set(values.map(\.numericValue)).count > 1 {
            diagnostics.append(diagnostic("quantities.changed", .quantities, "Possible numerical inconsistency: \(values[0].symbol!)", "Different explicit assignments with the same unit were found. They may describe different conditions; compare their contexts.", values[0].sourceRange, values.map { "quantity:\($0.id)" }, confidence: .low))
        }
        let bySymbol = Dictionary(grouping: quantities.filter { $0.symbol != nil }, by: { $0.symbol! })
        for symbol in bySymbol.keys.sorted() {
            let values = bySymbol[symbol]!
            let dimensions = Set(values.compactMap { $0.normalizedUnit.flatMap { profile.unitDimensions[$0] } })
            if dimensions.count > 1 {
                diagnostics.append(diagnostic("quantities.dimension", .quantities, "Possible unit mismatch: \(symbol)", "Explicit assignments use different unit families (\(dimensions.sorted().joined(separator: ", "))). Check whether the symbol changes meaning or a unit convention is missing; equations have not been dimensionally analyzed.", values[0].sourceRange, values.map { "quantity:\($0.id)" }, confidence: .low))
            }
            let repeated = Dictionary(grouping: values.filter { $0.normalizedUnit != nil && $0.uncertainty != nil }, by: { "\($0.numericValue)|\($0.normalizedUnit!)" })
            for key in repeated.keys.sorted() {
                let measurements = repeated[key]!
                if Set(measurements.compactMap(\.uncertainty)).count > 1 {
                    diagnostics.append(diagnostic("quantities.precision", .quantities, "Different stated uncertainties: \(symbol)", "Equal central values with the same unit carry different explicit uncertainties. They may describe different estimates or conditions; compare the sources.", measurements[0].sourceRange, measurements.map { "quantity:\($0.id)" }, severity: .info, confidence: .low))
                }
            }
        }
        var nodeIDs: Set<String> = []
        nodes = nodes.filter { nodeIDs.insert($0.id).inserted }
        var diagnosticIDs: Set<String> = []
        diagnostics = diagnostics.filter { diagnosticIDs.insert($0.id).inserted }
        var relationshipIDs: Set<String> = []
        relationships = relationships.filter { relationshipIDs.insert($0.id).inserted }
        definitions.sort { $0.definitionOccurrence < $1.definitionOccurrence }
        diagnostics.removeAll { profile.disabledRules.contains($0.id.components(separatedBy: ":")[0].components(separatedBy: ".").prefix(2).joined(separator: ".")) }
        diagnostics.sort { $0.severity.order != $1.severity.order ? $0.severity.order < $1.severity.order : $0.sourceRange.location != $1.sourceRange.location ? $0.sourceRange.location < $1.sourceRange.location : $0.id < $1.id }
    }
}
