// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import TersoCore
import TersoDocument

/// Spelling and grammar as an annotation layer, using the system checker
/// asynchronously so typing is never blocked. Code, URLs and markup are skipped:
/// a finding counts only where the masked prose equals the original text.
@MainActor
final class SpellingLayer {
    private let documentTag = NSSpellChecker.uniqueSpellDocumentTag()

    deinit {
        let tag = documentTag
        Task { @MainActor in NSSpellChecker.shared.closeSpellDocument(withTag: tag) }
    }

    /// A checker result reduced to plain values, safe to hand across threads.
    struct Finding: Sendable {
        let isSpelling: Bool
        let range: NSRange
        let grammar: [(range: NSRange, corrections: [String], description: String?)]
    }

    /// Separator for the suggestion list kept in `metadata["suggestions"]`.
    nonisolated static let suggestionSeparator = "\n"

    /// Tokens the system dictionary flags but a writer never means as words:
    /// acronyms (NASA, RNA), identifiers (camelCase, snake_case) and anything
    /// with a digit (H2O, v1, 3rd).
    nonisolated static func isLikelyIntentional(_ word: String) -> Bool {
        if word.contains(where: { $0.isNumber || $0 == "_" }) { return true }
        let letters = word.filter(\.isLetter)
        guard letters.count > 1 else { return true }
        if letters.allSatisfy(\.isUppercase) { return true }
        return letters.dropFirst().contains(where: \.isUppercase)
    }

    /// Ranked, de-duplicated corrections, matching the word's capitalisation.
    nonisolated static func rankedSuggestions(for word: String, best: String?, guesses: [String], limit: Int = 5) -> [String] {
        let capitalised = word.first?.isUppercase == true
        var seen = Set<String>(), out: [String] = []
        for g in ([best].compactMap { $0 } + guesses) {
            let c = capitalised && g.first?.isLowercase == true ? g.prefix(1).uppercased() + g.dropFirst() : g
            guard c != word, seen.insert(c.lowercased()).inserted else { continue }
            out.append(c)
            if out.count == limit { break }
        }
        return out
    }

    func check(_ snapshot: DocumentSnapshot, masked: String, completion: @escaping @MainActor @Sendable ([TextAnnotation]) -> Void) {
        let text = snapshot.text
        guard !text.isEmpty else { completion([]); return }
        let types: NSTextCheckingTypes = NSTextCheckingResult.CheckingType.spelling.rawValue | NSTextCheckingResult.CheckingType.grammar.rawValue
        NSSpellChecker.shared.requestChecking(
            of: text, range: NSRange(location: 0, length: (text as NSString).length), types: types, options: nil,
            inSpellDocumentWithTag: documentTag,
            completionHandler: Self.handler(snapshot: snapshot, masked: masked, documentTag: documentTag) { [self] annotations in
                // Keep the spell session alive until its last callback finishes.
                withExtendedLifetime(self) { completion(annotations) }
            })
    }

    /// Built outside the main actor: the checker calls it on a background queue.
    nonisolated static func handler(snapshot: DocumentSnapshot, masked: String, documentTag: Int,
                                    completion: @escaping @MainActor @Sendable ([TextAnnotation]) -> Void)
        -> @Sendable (Int, [NSTextCheckingResult], NSOrthography, Int) -> Void {
        { _, results, orthography, _ in
            let findings = results.map { r in
                Finding(isSpelling: r.resultType == .spelling, range: r.range,
                        grammar: (r.grammarDetails ?? []).compactMap { d in
                            guard let local = (d[NSGrammarRange] as? NSValue)?.rangeValue else { return nil }
                            return (NSRange(location: r.range.location + local.location, length: local.length),
                                    (d[NSGrammarCorrections] as? [String]) ?? [], d[NSGrammarUserDescription] as? String)
                        })
            }
            let language = orthography.dominantLanguage
            Task { @MainActor in
                completion(annotations(from: findings, snapshot: snapshot, masked: masked, documentTag: documentTag,
                                       language: language == "und" ? nil : language))
            }
        }
    }

    static func annotations(from findings: [Finding], snapshot: DocumentSnapshot, masked: String, documentTag: Int,
                            language: String? = nil) -> [TextAnnotation] {
        let ns = snapshot.text as NSString
        let mns = masked as NSString
        func isProse(_ r: NSRange) -> Bool { r.upperBound <= ns.length && mns.substring(with: r) == ns.substring(with: r) }
        var out: [TextAnnotation] = []
        for f in findings {
            if f.isSpelling {
                guard isProse(f.range) else { continue } // skip code, links and markup
                let word = ns.substring(with: f.range)
                guard !isLikelyIntentional(word) else { continue }
                let checker = NSSpellChecker.shared
                let best = checker.correction(forWordRange: f.range, in: snapshot.text,
                                              language: language ?? checker.language(), inSpellDocumentWithTag: documentTag)
                let guesses = checker.guesses(forWordRange: f.range, in: snapshot.text, language: language,
                                              inSpellDocumentWithTag: documentTag) ?? []
                let suggestions = rankedSuggestions(for: word, best: best, guesses: guesses)
                var meta = ["word": word]
                if !suggestions.isEmpty { meta["suggestions"] = suggestions.joined(separator: suggestionSeparator) }
                out.append(TextAnnotation(
                    source: .spelling, category: .spelling, ranges: [TextSpan(f.range)], severity: .suggestion,
                    message: "Spelling",
                    explanation: suggestions.isEmpty ? "“\(word)” is not in the dictionary, and no close match was found."
                                                     : "“\(word)” is not in the dictionary.",
                    consider: suggestions.prefix(3).joined(separator: " · ").nilIfEmpty,
                    revision: snapshot.revision, metadata: meta))
            } else {
                for g in f.grammar where isProse(g.range) {
                    let original = ns.substring(with: g.range)
                    let corrections = Array(g.corrections.filter { $0 != original }.prefix(5))
                    var meta = ["text": original]
                    if !corrections.isEmpty { meta["suggestions"] = corrections.joined(separator: suggestionSeparator) }
                    out.append(TextAnnotation(
                        source: .spelling, category: .spelling, ranges: [TextSpan(g.range)], severity: .suggestion,
                        message: "Grammar", explanation: g.description ?? "Possible grammatical problem.",
                        consider: corrections.prefix(3).joined(separator: " · ").nilIfEmpty, revision: snapshot.revision,
                        metadata: meta))
                }
            }
        }
        return out
    }
}

extension TextAnnotation {
    /// One-click replacements offered by the spelling layer, best first.
    var corrections: [String] {
        metadata["suggestions"].map { $0.components(separatedBy: SpellingLayer.suggestionSeparator).filter { !$0.isEmpty } } ?? []
    }

    /// The misspelled word or the grammar span, as it read when checked.
    var flaggedText: String? { metadata["word"] ?? metadata["text"] }
}

extension WorkspaceModel {
    /// Replace one occurrence of a spelling or grammar finding, through the
    /// review gate so it is a single undoable edit that refuses stale text.
    @discardableResult
    func applyCorrection(_ replacement: String, to finding: TextAnnotation, occurrence: Int = 0) -> String? {
        guard let editor, finding.source == .spelling, !replacement.isEmpty,
              finding.revision == editor.currentSnapshot.revision,
              finding.ranges.indices.contains(occurrence) else {
            return "The text changed. Wait for the check to finish and try again."
        }
        let snap = editor.currentSnapshot
        guard let anchor = TextAnchor(range: finding.ranges[occurrence], in: snap) else { return "The text changed." }
        let proposal = WritingSuggestion(documentRevision: snap.revision, anchor: anchor, proposedText: replacement,
                                         explanation: nil, kind: finding.message.lowercased(), provider: ProviderID("local.spelling"))
        let gate = SuggestionReview()
        gate.add([proposal])
        do {
            let range = try gate.accept(proposal.id, in: editor)
            editor.undoManager?.setActionName("Correct \(finding.message)")
            editor.reveal(TextSpan(location: range.upperBound, length: 0), select: true)
            editor.refreshDecorations()
            return nil
        } catch {
            return "The correction could not be applied."
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
