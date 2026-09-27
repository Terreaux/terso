// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Passive constructions: an auxiliary ("be" or "get") followed, after at most
/// two intervening adverbs or negators, by a past participle. This is the
/// classic surface definition used in register studies (Biber 1988, features
/// 17–18: agentless and by-passives).
public enum PassiveDetector {
    static let auxiliaries: Set<String> = ["am", "is", "are", "was", "were", "be", "been", "being", "get", "gets", "got", "gotten", "getting"]
    static let interveners: Set<String> = ["not", "never", "also", "often", "still", "already", "now", "then", "always", "just", "rarely", "usually", "sometimes", "being", "all", "both"]
    /// Irregular past participles (the regular ones end in -ed).
    static let irregular: Set<String> = Set("""
    arisen awoken borne born beaten become begun bent bet bid bitten bled blown broken bred brought built burnt \
    bought caught chosen clung come cost crept cut dealt dug done drawn dreamt driven drunk eaten fallen fed felt \
    fought found fled flung flown forbidden forgotten forgiven frozen given gone ground grown hung heard hidden hit \
    held hurt kept knelt known laid led leant learnt left lent let lain lit lost made meant met paid proven put quit \
    read rid ridden rung risen run said seen sought sold sent set sewn shaken shed shone shot shown shrunk shut sung \
    sunk slain slept slid slung spoken spent spilt spun split spread sprung stood stolen stuck stung stunk struck \
    strung sworn swept swum swung taken taught torn told thought thrown thrust trodden understood undertaken \
    upheld upset woken worn woven wept won wound withdrawn written overseen overtaken outgrown rewritten rebuilt
    """.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init))
    /// Words ending in -ed that are usually adjectives or not verbs after "be".
    static let notParticiples: Set<String> = Set("""
    bed red need seed feed speed embed shed hundred sacred naked wicked rugged ragged crooked beloved \
    interested tired excited bored married supposed concerned pleased surprised worried scared confused \
    involved related based located prepared advanced limited detailed dedicated experienced talented \
    determined sophisticated complicated outdated qualified skilled aged used
    """.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init))

    public static func isParticiple(_ w: String) -> Bool {
        if irregular.contains(w) { return true }
        return w.count > 4 && w.hasSuffix("ed") && !notParticiples.contains(w)
    }

    /// Spans from the auxiliary to the participle, one per construction.
    public static func find(in prose: ProseText) -> [TextSpan] {
        var out: [TextSpan] = []
        for s in prose.sentences {
            let words = s.words.map { prose.string($0).lowercased() }
            var i = 0
            while i < words.count {
                defer { i += 1 }
                guard auxiliaries.contains(words[i]) else { continue }
                var j = i + 1
                var skipped = 0
                while j < words.count, skipped < 2, interveners.contains(words[j]) || (words[j].hasSuffix("ly") && words[j].count > 4) {
                    j += 1; skipped += 1
                }
                guard j < words.count, isParticiple(words[j]) else { continue }
                out.append(TextSpan(location: s.words[i].location, length: s.words[j].upperBound - s.words[i].location))
                i = j
            }
        }
        return out
    }
}
