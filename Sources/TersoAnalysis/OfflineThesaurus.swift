// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Dictionary senses, not context-aware rewrite recommendations.
public struct ThesaurusSense: Codable, Identifiable, Sendable {
    public let id: String
    public let partOfSpeech: String
    public let definition: String
    public let words: [String]
    public let ranks: [String: Int]?

    /// Keep definitions concise in the meaning selector; full examples remain in the data.
    public var meaning: String { definition.components(separatedBy: ";").first ?? definition }

    public func alternatives(for original: String) -> [String] {
        words.filter { $0.lowercased() != original.lowercased() }.map { word in
            if original == original.uppercased() { return word.uppercased() }
            if original.first?.isUppercase == true, original.dropFirst() == original.dropFirst().lowercased() {
                return word.prefix(1).uppercased() + word.dropFirst()
            }
            return word
        }
    }
}

/// Loads once off the UI actor; no network, keys, or model are involved.
public actor OfflineThesaurus {
    public static let shared = OfflineThesaurus()
    private var index: [String: [ThesaurusSense]]?
    private var writing: [String: [ThesaurusSense]]?

    public func lookup(_ text: String) throws -> [ThesaurusSense] {
        if writing == nil {
            guard let url = Bundle.module.url(forResource: "WritingAlternatives", withExtension: "json") else {
                throw CocoaError(.fileNoSuchFile)
            }
            writing = try JSONDecoder().decode([String: [ThesaurusSense]].self, from: Data(contentsOf: url))
        }
        if let curated = writing?[text.lowercased()] { return curated }
        if index == nil {
            guard let url = Bundle.module.url(forResource: "synonyms", withExtension: "json", subdirectory: "WordNet") else {
                throw CocoaError(.fileNoSuchFile)
            }
            let senses = try JSONDecoder().decode([ThesaurusSense].self, from: Data(contentsOf: url))
            var loaded: [String: [ThesaurusSense]] = [:]
            for sense in senses {
                for word in Set(sense.words.map { $0.lowercased() }) { loaded[word, default: []].append(sense) }
            }
            for word in loaded.keys {
                loaded[word]?.sort { lhs, rhs in
                    let a = lhs.ranks?[word] ?? Int.max, b = rhs.ranks?[word] ?? Int.max
                    return a == b ? lhs.id < rhs.id : a < b
                }
            }
            index = loaded
        }
        return index?[text.lowercased()] ?? []
    }
}
