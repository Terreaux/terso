// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import TersoCore

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
        { _, results, _, _ in
            let findings = results.map { r in
                Finding(isSpelling: r.resultType == .spelling, range: r.range,
                        grammar: (r.grammarDetails ?? []).compactMap { d in
                            guard let local = (d[NSGrammarRange] as? NSValue)?.rangeValue else { return nil }
                            return (NSRange(location: r.range.location + local.location, length: local.length),
                                    (d[NSGrammarCorrections] as? [String]) ?? [], d[NSGrammarUserDescription] as? String)
                        })
            }
            Task { @MainActor in completion(annotations(from: findings, snapshot: snapshot, masked: masked, documentTag: documentTag)) }
        }
    }

    static func annotations(from findings: [Finding], snapshot: DocumentSnapshot, masked: String, documentTag: Int) -> [TextAnnotation] {
        let ns = snapshot.text as NSString
        let mns = masked as NSString
        func isProse(_ r: NSRange) -> Bool { r.upperBound <= ns.length && mns.substring(with: r) == ns.substring(with: r) }
        var out: [TextAnnotation] = []
        for f in findings {
            if f.isSpelling {
                guard isProse(f.range) else { continue } // skip code, links and markup
                let word = ns.substring(with: f.range)
                let guesses = NSSpellChecker.shared.guesses(forWordRange: f.range, in: snapshot.text, language: nil,
                                                            inSpellDocumentWithTag: documentTag) ?? []
                out.append(TextAnnotation(
                    source: .spelling, category: .spelling, ranges: [TextSpan(f.range)], severity: .suggestion,
                    message: "Spelling", explanation: "“\(word)” is not in the dictionary.",
                    consider: guesses.prefix(3).joined(separator: " · ").nilIfEmpty,
                    revision: snapshot.revision, metadata: ["word": word]))
            } else {
                for g in f.grammar where isProse(g.range) {
                    out.append(TextAnnotation(
                        source: .spelling, category: .spelling, ranges: [TextSpan(g.range)], severity: .suggestion,
                        message: "Grammar", explanation: g.description ?? "Possible grammatical problem.",
                        consider: g.corrections.prefix(3).joined(separator: " · ").nilIfEmpty, revision: snapshot.revision,
                        metadata: ["text": ns.substring(with: g.range)]))
                }
            }
        }
        return out
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
