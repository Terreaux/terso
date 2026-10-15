// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import TersoCore

/// Data-only extension point for future project configuration and rule packs.
public struct ScientificProfile: Sendable, Hashable, Codable {
    public var id: String
    public var displayName: String
    public var knownUnits: [String]
    /// Coarse families only; not a unit conversion or dimensional algebra engine.
    public var unitDimensions: [String: String]
    public var unitAliases: [String: String]
    public var commonSymbols: Set<String>
    public var terminology: [String]
    public var preferredNotation: [String: String]
    public var disabledRules: Set<String>
    public var minimumUndefinedUses: Int

    public init(id: String, displayName: String, knownUnits: [String], unitAliases: [String: String] = [:], commonSymbols: Set<String> = ["x", "y", "z", "i", "n", "d", "e", "\\pi"], terminology: [String] = [], preferredNotation: [String: String] = [:], disabledRules: Set<String> = [], minimumUndefinedUses: Int = 3, unitDimensions: [String: String] = [:]) {
        self.id = id; self.displayName = displayName; self.knownUnits = knownUnits
        self.unitDimensions = unitDimensions
        self.unitAliases = unitAliases
        self.commonSymbols = commonSymbols; self.terminology = terminology
        self.preferredNotation = preferredNotation; self.disabledRules = disabledRules
        self.minimumUndefinedUses = minimumUndefinedUses
    }
    public static let general = ScientificProfile(id: "general", displayName: "General Science", knownUnits: ["%", "m", "s", "kg", "K", "Hz", "J", "W", "Pa", "mol"], unitDimensions: ["%": "dimensionless", "m": "length", "s": "time", "kg": "mass", "K": "temperature", "Hz": "frequency", "J": "energy", "W": "power", "Pa": "pressure", "mol": "amount"])
    public static let hep = ScientificProfile(id: "particle-physics", displayName: "Particle Physics / HEP", knownUnits: general.knownUnits + ["eV", "keV", "MeV", "GeV", "TeV", "b", "mb", "μb", "nb", "pb", "fb"], unitAliases: [#"\mu b"#: "μb", #"\mu\mathrm{b}"#: "μb", "µb": "μb"], terminology: ["LO", "NLO", "NNLO", "QCD", "QED", "HEP"], unitDimensions: general.unitDimensions.merging([
        "eV": "energy", "keV": "energy", "MeV": "energy", "GeV": "energy", "TeV": "energy",
        "b": "area", "mb": "area", "μb": "area", "nb": "area", "pb": "area", "fb": "area",
        "b^{-1}": "inverse area", "mb^{-1}": "inverse area", "μb^{-1}": "inverse area", "nb^{-1}": "inverse area", "pb^{-1}": "inverse area", "fb^{-1}": "inverse area"
    ]) { _, domain in domain })
}

public struct ScientificSymbol: Sendable, Hashable, Codable, Identifiable {
    public var id: String { canonicalForm }
    public let canonicalForm: String
    public let displayForm: String
    public let occurrences: [TextSpan]
    public let definitions: [TextSpan]
    public let contexts: [String]
    public var firstOccurrence: TextSpan { occurrences[0] }
}

public struct ScientificQuantity: Sendable, Hashable, Codable, Identifiable {
    public var id: Int { sourceRange.location }
    public let rawText: String
    public let numericValue: Double
    public let uncertainty: Double?
    public let unit: String?
    public let normalizedUnit: String?
    public let sourceRange: TextSpan
    public let context: String
    public let section: String?
    /// Only an explicit adjacent equality binds a quantity to notation.
    public let symbol: String?
    public var indexKey: String { "\(numericValue)\(uncertainty.map { " ± \($0)" } ?? "") \(normalizedUnit ?? "")".trimmingCharacters(in: .whitespaces) }
}

public enum ScientificObjectKind: String, Codable, Sendable { case figure, table, equation, section, unknown }
public struct ScientificReference: Sendable, Hashable, Codable, Identifiable {
    public var id: String { "\(sourceRange.location):\(key)" }
    public let key: String
    public let command: String
    public let sourceRange: TextSpan
    public let section: String?
    public var isCitation: Bool { ["cite", "citep", "citet"].contains(command) }
}
public struct ScientificObject: Sendable, Hashable, Codable, Identifiable {
    public var id: Int { sourceRange.location }
    public let key: String
    public let kind: ScientificObjectKind
    public let sourceRange: TextSpan
    public let section: String?
    public let references: [ScientificReference]
    public let caption: String?
    public let imagePath: String?
}
public enum ScientificClaimType: String, Codable, Sendable { case quantitative, comparative, agreement, causal, novelty, strongConclusion, methodological, authorStatement, background }
public struct ScientificEvidence: Sendable, Hashable, Codable {
    public enum Kind: String, Codable, Sendable { case citation, reference, quantity, measurement, methodology }
    public let kind: Kind
    public let text: String
    public let sourceRange: TextSpan
}
public struct ScientificClaim: Sendable, Hashable, Codable, Identifiable {
    public var id: String { "\(sourceRange.location):\(type.rawValue)" }
    public let type: ScientificClaimType
    public let sourceRange: TextSpan
    public let text: String
    public let section: String?
    public let nearbyEvidence: [ScientificEvidence]
    public let nearbyReferences: [ScientificReference]
    public let nearbyQuantities: [ScientificQuantity]
    /// A phrase, not a context-free numerical ranking of scientific certainty.
    public let strength: String?
}

/// Serializable, revision-bound input for local rules and future advisory tools.
/// Evidence records proximity in the same paragraph, never semantic proof.
public struct ScientificDocumentModel: Sendable, Codable {
    public let revision: DocumentRevision
    public let profile: ScientificProfile
    public let regions: [ScientificRegion]
    public let symbols: [ScientificSymbol]
    public let quantities: [ScientificQuantity]
    public let references: [ScientificReference]
    public let objects: [ScientificObject]
    public let claims: [ScientificClaim]
    public internal(set) var definitions: [ScientificDefinition] = []
    public internal(set) var equations: [ScientificEquation] = []
    public internal(set) var diagnostics: [ScientificDiagnostic] = []
    public internal(set) var relationships: [ScientificRelationship] = []
    public internal(set) var evidence: [ScientificEvidence] = []
    public internal(set) var nodes: [ScientificNode] = []

    public init(snapshot: DocumentSnapshot, prose: ProseText, profile: ScientificProfile = .hep) {
        revision = snapshot.revision; self.profile = profile
        let syntax = ScientificSyntax(snapshot)
        regions = syntax.regions
        let ns = snapshot.text as NSString
        // Exclude code, comments, link targets and front matter from every scientific index.
        var source = Array(snapshot.text.utf16)
        var excluded = regions.filter { $0.kind == .code || $0.kind == .comment || $0.kind == .linkDestination }.map(\.range)
        if let front = SciencePattern.matches(#"\A(---|\+\+\+)[ \t]*\n(?:[\s\S]*?\n)?(?:\1|\.\.\.)[ \t]*(?:\n|\z)"#, snapshot.text).first { excluded.append(TextSpan(front.range)) }
        // Comments inside math are not separate partition regions.
        for region in regions where region.kind == .inlineMath || region.kind == .displayMath {
            for match in SciencePattern.matches(#"(?<!\\)%[^\r\n]*"#, region.rawText) { excluded.append(TextSpan(match.range).shifted(by: region.range.location)) }
        }
        for range in excluded { for i in range.location..<range.upperBound where source[i] != 10 && source[i] != 13 { source[i] = 32 } }
        let clean = String(utf16CodeUnits: source, count: source.count)
        let cleanNS = clean as NSString
        var headings = prose.headings.map { ($0.range.location, $0.title) }
        let known = Set(headings.map(\.0))
        for m in SciencePattern.matches(#"\\(?:section|subsection|subsubsection|chapter)\*?\{([^{}]+)\}|\\begin\{(abstract)\}"#, clean) where !known.contains(m.range.location) {
            let r = m.range(at: m.range(at: 1).location == NSNotFound ? 2 : 1)
            headings.append((m.range.location, cleanNS.substring(with: r)))
        }
        headings.sort { $0.0 < $1.0 }
        func section(_ location: Int) -> String? { headings.last { $0.0 <= location }?.1 }
        func context(_ range: TextSpan) -> String {
            let r = ns.paragraphRange(for: range.nsRange)
            return ns.substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Small, deliberately conservative grammar: a base atom plus scripts.
        let atom = #"(?:\\(?:sqrt|mathbf|boldsymbol|mathcal|mathbb|mathit|vec|hat|bar|tilde)\s*\{[^{}]+\}|\\[A-Za-z]+|[A-Za-z])(?:\s*[_^]\s*(?:\{(?:[^{}]|\{[^{}]*\})*\}|\\(?:mathrm|text|mathit)\s*\{[^{}]*\}|\\[A-Za-z]+|[A-Za-z0-9]))*"#
        let excludedCommands: Set<String> = ["\\frac", "\\partial", "\\mathrm", "\\text", "\\mathbf", "\\mathit", "\\left", "\\right", "\\begin", "\\end", "\\label", "\\ref", "\\eqref", "\\cite", "\\pm", "\\times", "\\cdot", "\\le", "\\ge", "\\leq", "\\geq", "\\in", "\\sum", "\\int", "\\log", "\\ln", "\\exp", "\\sin", "\\cos", "\\to", "\\rightarrow", "\\leftarrow", "\\leftrightarrow", "\\Rightarrow", "\\Leftrightarrow", "\\infty", "\\neq", "\\approx", "\\equiv", "\\propto", "\\notin", "\\subset", "\\forall", "\\exists", "\\prod", "\\lim", "\\tan", "\\min", "\\max", "\\quad", "\\qquad", "\\nonumber", "\\notag", "\\coloneqq"]
        // A bare m, s, or b can be notation. Only suppress an unwrapped unit
        // atom when it immediately follows a number; styled units are masked.
        func isNumericUnit(_ token: String, at location: Int, in text: NSString) -> Bool {
            guard profile.knownUnits.contains(token) else { return false }
            let prefix = text.substring(with: NSRange(location: max(0, location - 40), length: min(40, location)))
            return SciencePattern.has(#"[0-9]\s*(?:\\[,;! ]\s*)*$"#, prefix)
        }
        var occurrences: [String: [TextSpan]] = [:]
        var displays: [String: String] = [:]
        var regionUses: [TextSpan: [TextSpan]] = [:]
        for region in regions where region.kind == .inlineMath || region.kind == .displayMath {
            if Task.isCancelled { break }
            let raw = cleanNS.substring(with: region.contentRange.nsRange)
            let localNS = raw as NSString
            let hidden = SciencePattern.matches(#"\\(?:mathrm|text|operatorname|label|ref|eqref|cite)\s*\{[^{}]*\}|(?<![A-Za-z\\])[A-Za-z]{2,}(?![A-Za-z])"#, raw).map(\.range).filter { range in
                // In dσ/dp_T, the differential d is not part of p_T.
                let token = localNS.substring(with: range)
                return !(token.count == 2 && token.first == "d" && range.upperBound < localNS.length && localNS.character(at: range.upperBound) == 95)
            }
            for m in SciencePattern.matches(atom, raw) {
                if hidden.contains(where: { NSLocationInRange(m.range.location, $0) }) { continue }
                let value = localNS.substring(with: m.range)
                let canonical = SciencePattern.canonical(value)
                let baseCommand = SciencePattern.matches(#"^\\[A-Za-z]+"#, canonical).first.map { (canonical as NSString).substring(with: $0.range) }
                guard !excludedCommands.contains(canonical), !(excludedCommands.contains(baseCommand ?? "") && !(canonical.contains("{") && ["\\mathbf", "\\mathit"].contains(baseCommand ?? ""))), !isNumericUnit(canonical, at: m.range.location, in: localNS) else { continue }
                let use = TextSpan(m.range).shifted(by: region.contentRange.location)
                occurrences[canonical, default: []].append(use)
                regionUses[region.range, default: []].append(use)
                displays[canonical] = value
            }
        }
        // Prose often introduces notation by its role ("vertices $u$ and $v$")
        // rather than a formal "let". Work from parsed inline regions so math
        // arguments, code, and unrelated later equations cannot become definitions.
        let inline = regions.filter { $0.kind == .inlineMath }
        var proseDefinitions: Set<TextSpan> = []
        func prefix(_ region: ScientificRegion) -> String {
            let start = max(0, region.range.location - 200)
            return cleanNS.substring(with: NSRange(location: start, length: region.range.location - start))
        }
        func suffix(_ region: ScientificRegion) -> String {
            cleanNS.substring(with: NSRange(location: region.range.upperBound, length: min(100, cleanNS.length - region.range.upperBound)))
        }
        func loneSymbol(_ region: ScientificRegion) -> TextSpan? {
            let uses = regionUses[region.range] ?? []
            guard uses.count == 1, let use = uses.first,
                  cleanNS.substring(with: region.contentRange.nsRange).trimmingCharacters(in: .whitespacesAndNewlines)
                    == cleanNS.substring(with: use.nsRange) else { return nil }
            return use
        }
        var index = 0
        while index < inline.count {
            let first = inline[index]
            guard let use = loneSymbol(first) else { index += 1; continue }
            var group = [use]
            var end = index
            while end + 1 < inline.count, let next = loneSymbol(inline[end + 1]) {
                let gap = cleanNS.substring(with: NSRange(location: inline[end].range.upperBound, length: inline[end + 1].range.location - inline[end].range.upperBound))
                guard SciencePattern.has(#"(?i)^[*_]{0,2}[ \t]*(?:,\s*(?:and\s+)?|and\s+|or\s+)[*_]{0,2}$"#, gap) else { break }
                group.append(next); end += 1
            }
            let typed = SciencePattern.has(#"(?i)\b(?:vertices|vertex|nodes?|edges?|points?|vectors?|scalars?|matrices|matrix|parameters?|variables?|functions?|sets?)\s+[*_]{0,2}$"#, prefix(first))
            let described = SciencePattern.has(#"(?i)^[*_]{0,2}\s+(?:is\s+(?:a|an|the)|are\s+(?:the\s+)?(?:vertices|nodes|edges|points|vectors|scalars|matrices|parameters|variables|functions|sets|fragments))\b"#, suffix(inline[end]))
            if typed || described { proseDefinitions.formUnion(group) }
            index = end + 1
        }
        for region in inline {
            let uses = regionUses[region.range] ?? []
            guard let head = uses.first else { continue }
            let beforeHead = cleanNS.substring(with: NSRange(location: region.contentRange.location, length: head.location - region.contentRange.location))
            let afterHead = cleanNS.substring(with: NSRange(location: head.upperBound, length: region.contentRange.upperBound - head.upperBound))
            guard beforeHead.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  SciencePattern.has(#"^\s*(?:\([^()=]+\))?\s*$"#, afterHead) else { continue }
            let named = SciencePattern.has(#"(?i)\b(?:we\s+(?:usually\s+)?(?:write|denote|define)|denoted|written)\b[^.!?\n]*\bas\s+[*_]{0,2}$"#, prefix(region))
            let described = SciencePattern.has(#"(?i)^[*_]{0,2}\s+(?:denotes?\b|is\s+(?:a|an|the|defined\s+as)\b)"#, suffix(region))
            if named || described { proseDefinitions.insert(head) }
        }
        symbols = occurrences.keys.sorted().map { key in
            let uses = occurrences[key]!.sorted()
            let defs = uses.filter { r in
                let before = ns.substring(with: NSRange(location: max(0, r.location - 45), length: min(45, r.location)))
                let after = ns.substring(with: NSRange(location: r.upperBound, length: min(100, ns.length - r.upperBound)))
                return proseDefinitions.contains(r)
                    || SciencePattern.has(#"(?i)(?:we\s+define|let|where|with)\s*\$?\s*$"#, before) && SciencePattern.has(#"(?i)^\s*\$?\s*(?:denotes?\b|is\b|as\b|=|:=|\\coloneqq|the\s+\w+)"#, after)
                    || SciencePattern.has(#"^\s*(?::=|\\coloneqq)"#, after)
                    || SciencePattern.has(#"(?i)^\s*\$?\s*(?:denotes?\b|is\s+(?:the|defined\s+as))\b"#, after)
            }
            return ScientificSymbol(canonicalForm: key, displayForm: displays[key]!, occurrences: uses, definitions: defs, contexts: uses.map(context))
        }
        // Normalize only units' presentation; numeric source spans never move.
        let units = (profile.knownUnits + profile.unitAliases.keys).sorted { $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: $0).replacingOccurrences(of: " ", with: #"\s*"#) }.joined(separator: "|")
        let number = #"[+−-]?(?:\d+(?:\.\d+)?|\.\d+)(?:[eE][+−-]?\d+|\s*(?:\\times|×)\s*10\s*\^\s*\{?[+−-]?\d+\}?|\s*\^\s*\{[+−-]?\d+\})?"#
        let quantityPattern = "(?<![A-Za-z0-9_.])(" + number + ")(?:\\s*(?:±|\\\\pm)\\s*(" + number + "))?([\\s,$~]*(?:\\\\[,;! ]\\s*)*(?:\\\\(?:mathrm|text)\\s*\\{\\s*)?(?:\\\\)?(" + units + ")(?:(?:\\s*\\}\\s*)?\\^\\s*(?:\\{\\s*(-1)\\s*\\}|(-1)))?\\}?(?![A-Za-z]))?"
        var qs: [ScientificQuantity] = []
        for m in SciencePattern.matches(quantityPattern, clean) {
            if Task.isCancelled { break }
            let rawNumber = cleanNS.substring(with: m.range(at: 1))
            let unit = m.range(at: 4).location == NSNotFound ? nil : cleanNS.substring(with: m.range(at: 4))
            let uncertainty = m.range(at: 2).location == NSNotFound ? nil : SciencePattern.number(cleanNS.substring(with: m.range(at: 2)))
            let start = m.range.location
            // Bare integers are only quantities with an explicit equality,
            // uncertainty or exponent (not citation keys / section numbers).
            let before = cleanNS.substring(with: NSRange(location: max(0, start - 100), length: min(100, start)))
            let equality = SciencePattern.matches("(" + atom + #")\s*=\s*$"#, before).last
            let binding = equality.map { SciencePattern.canonical((before as NSString).substring(with: $0.range(at: 1))) }
            guard unit != nil || uncertainty != nil || rawNumber.contains("^") || rawNumber.lowercased().contains("e") || binding != nil else { continue }
            let r = TextSpan(m.range)
            // Ignore command arguments (labels, image filenames, citation keys).
            guard !regions.contains(where: { [.command, .citation, .reference].contains($0.kind) && $0.range.contains(r.location) }) else { continue }
            guard let value = SciencePattern.number(rawNumber), value.isFinite else { continue }
            let inverse = m.range(at: 5).location != NSNotFound || m.range(at: 6).location != NSNotFound
            qs.append(ScientificQuantity(rawText: ns.substring(with: m.range), numericValue: value, uncertainty: uncertainty, unit: unit, normalizedUnit: unit.map { raw in
                let canonical = profile.unitAliases.first { SciencePattern.canonical($0.key) == SciencePattern.canonical(raw) }?.value ?? raw
                return canonical + (inverse ? "^{-1}" : "")
            }, sourceRange: r, context: context(r), section: section(start), symbol: binding))
        }
        quantities = qs
        var refs: [ScientificReference] = [], labels: [(String, TextSpan)] = []
        for m in SciencePattern.matches(#"\\(citep|citet|cite|eqref|ref|autoref|cref|label)\*?(?:\s*\[[^\]]*\])*\s*\{([^{}]+)\}"#, clean) {
            let command = cleanNS.substring(with: m.range(at: 1))
            let keys = cleanNS.substring(with: m.range(at: 2)).split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            for key in keys where !key.isEmpty {
                if command == "label" { labels.append((key, TextSpan(m.range))) }
                else { refs.append(ScientificReference(key: key, command: command, sourceRange: TextSpan(m.range), section: section(m.range.location))) }
            }
        }
        references = refs
        let environments = SciencePattern.matches(#"\\begin\{(figure\*?|table\*?|equation\*?|align\*?|gather\*?|multline\*?)\}[\s\S]*?\\end\{\1\}"#, clean)
        let referencesByKey = Dictionary(grouping: refs.filter { !$0.isCitation }, by: \.key)
        objects = labels.map { key, range in
            var kind: ScientificObjectKind = key.hasPrefix("fig:") ? .figure : key.hasPrefix("tab:") ? .table : key.hasPrefix("eq:") ? .equation : key.hasPrefix("sec:") ? .section : .unknown
            var container: NSRange?
            for m in environments where NSLocationInRange(range.location, m.range) {
                container = m.range
                let env = cleanNS.substring(with: m.range(at: 1))
                kind = env.hasPrefix("figure") ? .figure : env.hasPrefix("table") ? .table : .equation
            }
            let content = container.map { cleanNS.substring(with: $0) } ?? ""
            func argument(_ command: String) -> String? {
                SciencePattern.matches("\\\\" + command + #"(?:\[[^\]]*\])?\{([^{}]*)\}"#, content).first.map { (content as NSString).substring(with: $0.range(at: 1)) }
            }
            return ScientificObject(key: key, kind: kind, sourceRange: range, section: section(range.location), references: referencesByKey[key] ?? [], caption: argument("caption"), imagePath: argument("includegraphics"))
        }
        let claimPatterns: [(ScientificClaimType, String)] = [
            (.authorStatement, #"\b(?:I find|I believe|in my experience|we believe|in our experience)\b"#),
            (.methodological, #"\b(?:we use|we compute|we calculate|our method|our approach)\b"#),
            (.background, #"\b(?:it is known|is well known)\b"#),
            (.quantitative, #"\b(?:below|above|within|increases? by|decreases? by|less than|greater than)\b"#),
            (.comparative, #"\b(?:more closely|smaller|larger|higher|lower)\b"#),
            (.agreement, #"\b(?:agrees? with|consistent within|consistent with)\b"#),
            (.causal, #"\b(?:results? from|caused by|due to cancellation)\b"#),
            (.novelty, #"\b(?:the first calculation|present the first|first measurement)\b"#),
            (.strongConclusion, #"\b(?:demonstrates?|establishes?|confirms?|proves?)\b"#)
        ]
        // A sentence is one inspectable claim. Prefer the consequential matched
        // signal; author experience always wins over stronger rhetorical words.
        let claimPriority: [ScientificClaimType] = [.authorStatement, .strongConclusion, .novelty, .quantitative, .agreement, .causal, .comparative, .methodological, .background]
        let orderedClaimPatterns = claimPriority.compactMap { type in claimPatterns.first { $0.0 == type } }
        // The source-sorted indexes preserve intersection semantics without a
        // document-wide scan for every sentence in a paragraph.
        func intersecting<T>(_ values: [T], span: (T) -> TextSpan, range: TextSpan) -> [T] {
            var low = 0, high = values.count
            while low < high {
                let mid = (low + high) / 2
                if span(values[mid]).upperBound <= range.location { low = mid + 1 } else { high = mid }
            }
            var result: [T] = [], index = low
            while index < values.count && span(values[index]).location < range.upperBound {
                if range.intersects(span(values[index])) { result.append(values[index]) }
                index += 1
            }
            return result
        }
        let sentencesByBlock = Dictionary(grouping: prose.sentences, by: \.blockIndex)
        let labelKeys = Set(labels.map { $0.0 })
        let referencesByBlock = prose.blocks.map { intersecting(refs, span: { $0.sourceRange }, range: $0.range) }
        let quantitiesByBlock = prose.blocks.map { intersecting(qs, span: { $0.sourceRange }, range: $0.range) }
        let evidenceByBlock = prose.blocks.indices.map { index in
            let explicit = referencesByBlock[index].filter { $0.isCitation || labelKeys.contains($0.key) }.map {
                ScientificEvidence(kind: $0.isCitation ? .citation : .reference, text: $0.key, sourceRange: $0.sourceRange)
            } + quantitiesByBlock[index].map { ScientificEvidence(kind: .quantity, text: $0.rawText, sourceRange: $0.sourceRange) }
            let textual = (sentencesByBlock[index] ?? []).compactMap { sentence -> ScientificEvidence? in
                let text = prose.maskedString(sentence.range)
                guard SciencePattern.has(#"(?i)\b(?:we measure|measured using|we use|we compute|we calculate)\b"#, text) else { return nil }
                return ScientificEvidence(kind: SciencePattern.has("(?i)measure", text) ? .measurement : .methodology, text: prose.string(sentence.range), sourceRange: sentence.range)
            }
            return (explicit: explicit, textual: textual)
        }
        var cs: [ScientificClaim] = []
        for sentence in prose.sentences {
            if Task.isCancelled { break }
            let text = prose.maskedString(sentence.range)
            let nearbyRefs = referencesByBlock[sentence.blockIndex]
            let nearbyQs = quantitiesByBlock[sentence.blockIndex]
            let cached = evidenceByBlock[sentence.blockIndex]
            let evidence = cached.explicit + cached.textual.filter { $0.sourceRange != sentence.range }
            let strength = SciencePattern.matches(#"(?i)\b(?:suggests?|indicates?|is consistent with|supports?|shows?|demonstrates?|establishes?|confirms?|proves?)\b"#, text).first.map { (text as NSString).substring(with: $0.range) }
            for (type, pattern) in orderedClaimPatterns where SciencePattern.has("(?i)" + pattern, text) {
                if type != .authorStatement && SciencePattern.has(#"(?i)\b(?:I find|I believe|in my experience|we believe|in our experience)\b"#, text) { continue }
                if type == .quantitative && !nearbyQs.contains(where: { sentence.range.intersects($0.sourceRange) }) { continue }
                cs.append(ScientificClaim(type: type, sourceRange: sentence.range, text: prose.string(sentence.range), section: section(sentence.range.location), nearbyEvidence: evidence, nearbyReferences: nearbyRefs, nearbyQuantities: nearbyQs, strength: strength))
                break
            }
        }
        claims = cs
        buildScientificGraph(source: clean, originalSource: snapshot.text)
    }
}

enum SciencePattern {
    static func matches(_ pattern: String, _ text: String) -> [NSTextCheckingResult] {
        let re = try! NSRegularExpression(pattern: pattern)
        return re.matches(in: text, range: NSRange(location: 0, length: text.utf16.count))
    }
    static func has(_ pattern: String, _ text: String) -> Bool { !matches(pattern, text).isEmpty }
    static func canonical(_ text: String) -> String {
        let compact = text.replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
        return compact.replacingOccurrences(of: #"([_^])\{([A-Za-z0-9])\}"#, with: "$1$2", options: .regularExpression)
    }
    static func number(_ raw: String) -> Double? {
        let text = raw.replacingOccurrences(of: "−", with: "-").replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
        if let value = Double(text) { return value }
        if let m = matches(#"^(.+?)(?:\\times|×)10\^\{?([+-]?\d+)\}?$"#, text).first {
            let ns = text as NSString
            if let base = Double(ns.substring(with: m.range(at: 1))), let exp = Double(ns.substring(with: m.range(at: 2))) { return base * pow(10, exp) }
        }
        if let m = matches(#"^10\^\{?([+-]?\d+)\}?$"#, text).first, let exponent = Double((text as NSString).substring(with: m.range(at: 1))) { return pow(10, exponent) }
        return nil
    }
}
