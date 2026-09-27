// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

public enum Readability {
    /// Heuristic English syllable count (vowel groups with common corrections).
    public static func syllables(_ word: String) -> Int {
        let w = word.lowercased().filter { $0.isLetter }
        guard !w.isEmpty else { return 0 }
        if w.count <= 3 { return 1 }
        let vowels: Set<Character> = ["a", "e", "i", "o", "u", "y"]
        var count = 0
        var prevVowel = false
        for ch in w {
            let v = vowels.contains(ch)
            if v && !prevVowel { count += 1 }
            prevVowel = v
        }
        if w.hasSuffix("e") && !w.hasSuffix("le") && !w.hasSuffix("ee") && count > 1 { count -= 1 }
        if w.hasSuffix("es") || w.hasSuffix("ed"), count > 1, !w.hasSuffix("ted"), !w.hasSuffix("ded"), !w.hasSuffix("ses"), !w.hasSuffix("zes"), !w.hasSuffix("ces") {
            count -= 1
        }
        return max(1, count)
    }

    /// Flesch–Kincaid grade level.
    public static func fleschKincaidGrade(words: Int, sentences: Int, syllables: Int) -> Double {
        guard words > 0, sentences > 0 else { return 0 }
        return 0.39 * Double(words) / Double(sentences) + 11.8 * Double(syllables) / Double(words) - 15.59
    }

    /// Flesch reading ease (higher is easier).
    public static func fleschReadingEase(words: Int, sentences: Int, syllables: Int) -> Double {
        guard words > 0, sentences > 0 else { return 0 }
        return 206.835 - 1.015 * Double(words) / Double(sentences) - 84.6 * Double(syllables) / Double(words)
    }
}

/// Plain document statistics. No scores, no streaks.
public struct DocumentStatistics: Sendable, Hashable {
    public var words = 0
    public var sentences = 0
    public var paragraphs = 0
    public var characters = 0
    public var charactersNoSpaces = 0
    public var syllables = 0
    public var headings = 0

    public init() {}

    public init(prose: ProseText) {
        let ns = prose.original as NSString
        words = prose.words.count
        sentences = prose.sentences.count
        paragraphs = prose.blocks.count
        characters = prose.original.count
        charactersNoSpaces = prose.original.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.count
        syllables = prose.words.reduce(0) { $0 + Readability.syllables(ns.substring(with: $1.nsRange)) }
        headings = prose.headings.count
    }

    /// 238 words per minute: the adult silent-reading average for non-fiction
    /// (Brysbaert 2019).
    public var readingMinutes: Double { Double(words) / 238.0 }
    public var readingTimeLabel: String {
        let m = readingMinutes
        if words == 0 { return "—" }
        if m < 1 { return "< 1 min" }
        return "\(Int(m.rounded())) min"
    }
    public var gradeLevel: Double? {
        guard words >= 30, sentences >= 2 else { return nil }
        return max(0, Readability.fleschKincaidGrade(words: words, sentences: sentences, syllables: syllables))
    }
}
