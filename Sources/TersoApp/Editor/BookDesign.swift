// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import TersoCore

/// How Manutius sets the book, after the choices manutius.app offers a
/// typesetter: trim size, chapter openers and headings, the opening of each
/// chapter, scene breaks, running heads, folios and a large-print edition.
/// Shown only in Manutius; stored once for every document.
struct BookDesign: Codable, Equatable {
    var trim: BookTrim = .sixByNine
    var openers: ChapterOpener = .rightPage
    var headings: ChapterHeadingStyle = .classic
    var dropCaps = true
    var smallCapsOpening = true
    var sceneBreak: SceneBreak = .asterism
    var runningHeads: RunningHeads = .titleAndChapter
    var folios: FolioPosition = .centre
    var largePrint = false

    /// Large print sets the type a quarter larger; the measure follows it.
    static let largePrintScale = 1.25
}

/// Trim sizes from a mass-market paperback to a large hardcover. 6 × 9 is
/// the 2:3 page of the Van de Graaf canon.
enum BookTrim: String, Codable, CaseIterable, Identifiable {
    case fiveByEight, digest, sixByNine, sevenByTen
    var id: String { rawValue }
    var title: String {
        switch self {
        case .fiveByEight: "5 × 8 in"
        case .digest: "5.5 × 8.5 in"
        case .sixByNine: "6 × 9 in"
        case .sevenByTen: "7 × 10 in"
        }
    }
    /// Height over width.
    var aspect: CGFloat {
        switch self {
        case .fiveByEight: 8 / 5
        case .digest: 8.5 / 5.5
        case .sixByNine: 9 / 6
        case .sevenByTen: 10 / 7
        }
    }
}

enum ChapterOpener: String, Codable, CaseIterable, Identifiable {
    case continuous, newPage, rightPage
    var id: String { rawValue }
    var title: String {
        switch self {
        case .continuous: "Run On"
        case .newPage: "New Page"
        case .rightPage: "New Right-Hand Page"
        }
    }
}

/// Chapter headings (level-one headings), as manutius.app names its six.
enum ChapterHeadingStyle: String, Codable, CaseIterable, Identifiable {
    case classic, smallCaps, uppercase, bigNumeral, rules, plain
    var id: String { rawValue }
    var title: String {
        switch self {
        case .classic: "Classic"
        case .smallCaps: "Small Caps"
        case .uppercase: "Uppercase"
        case .bigNumeral: "Big Numeral"
        case .rules: "Rules"
        case .plain: "Plain"
        }
    }
}

/// What a thematic break (`***`, `---`) becomes between scenes.
enum SceneBreak: String, Codable, CaseIterable, Identifiable {
    case asterism, asterisks, fleuron, lozenge, rule, space
    var id: String { rawValue }
    var title: String {
        switch self {
        case .asterism: "Asterism ⁂"
        case .asterisks: "Asterisks * * *"
        case .fleuron: "Fleuron ❧"
        case .lozenge: "Lozenge ◆"
        case .rule: "Short Rule"
        case .space: "White Space"
        }
    }
    var ornament: String? {
        switch self {
        case .asterism: "⁂"
        case .asterisks: "*   *   *"
        case .fleuron: "❧"
        case .lozenge: "◆"
        case .rule, .space: nil
        }
    }
}

enum RunningHeads: String, Codable, CaseIterable, Identifiable {
    case off, title, titleAndChapter
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: "None"
        case .title: "Book Title"
        case .titleAndChapter: "Title Left, Chapter Right"
        }
    }
}

enum FolioPosition: String, Codable, CaseIterable, Identifiable {
    case centre, outside, off
    var id: String { rawValue }
    var title: String {
        switch self {
        case .centre: "Foot, Centred"
        case .outside: "Foot, Outside Corner"
        case .off: "None"
        }
    }
}

/// A chapter as the book sees it: a level-one heading outside code and
/// metadata, and the first prose paragraph that opens it.
struct BookChapter: Equatable {
    /// The heading line, without its line break.
    var heading: NSRange
    /// Where the title starts, after the `#` marker.
    var titleStart: Int
    var title: String
    /// The paragraph a drop cap and small-caps opening belong to.
    var opening: NSRange?
    /// Where the chapter's text ends: the next chapter heading, or the end.
    var end: Int

    @MainActor static func scan(_ text: String) -> [BookChapter] {
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)
        let literal = [MarkdownSyntax.frontMatter(in: text)].compactMap { $0 } + MarkdownStyler.fence.matches(in: text, range: all).map(\.range)
        let headings = MarkdownStyler.heading.matches(in: text, range: all).filter { m in
            m.range(at: 1).length == 1 && !literal.contains { NSIntersectionRange($0, m.range).length > 0 }
        }
        return headings.enumerated().map { index, m in
            let end = index + 1 < headings.count ? headings[index + 1].range.location : ns.length
            var opening: NSRange?
            var cursor = NSMaxRange(ns.lineRange(for: m.range))
            while cursor < end {
                let paragraph = ns.paragraphRange(for: NSRange(location: cursor, length: 0))
                let line = ns.substring(with: paragraph)
                if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if MarkdownStyler.isProse(line) { opening = paragraph }
                    break
                }
                cursor = NSMaxRange(paragraph)
            }
            let title = ns.substring(with: m.range(at: 3))
                .replacingOccurrences(of: #"\s*\{#[^}]*\}\s*$"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"[*_`]"#, with: "", options: .regularExpression)
            return BookChapter(heading: m.range, titleStart: m.range(at: 3).location, title: title, opening: opening, end: end)
        }
    }

    /// Every index the heading's first line can begin at.
    var lineStarts: ClosedRange<Int> { heading.location...max(heading.location, titleStart) }

    /// The opening's first character, when it is a letter or figure a drop
    /// cap can stand for.
    func initial(in ns: NSString) -> NSRange? {
        guard let opening, opening.length > 1 else { return nil }
        let range = ns.rangeOfComposedCharacterSequence(at: opening.location)
        let letter = ns.substring(with: range)
        guard letter.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains) else { return nil }
        return range
    }

    /// The opening's first words, which books set in small capitals: up to
    /// three words, or to the first punctuation.
    func openingWords(in ns: NSString) -> NSRange? {
        guard let opening else { return nil }
        let text = ns.substring(with: opening) as NSString
        var words = 0, end = 0, inWord = false
        for i in 0..<text.length {
            let ch = text.character(at: i)
            let isSpace = ch == 32 || ch == 9 || ch == 10
            if ",.;:!?—–)".utf16.contains(ch) { end = i; break }
            if isSpace {
                if inWord { words += 1; inWord = false; if words == 3 { break } }
            } else { inWord = true; end = i + 1 }
        }
        return end > 0 ? NSRange(location: opening.location, length: end) : nil
    }
}

/// A drop cap's geometry: the cap set in the body face, its height running
/// from the first line's cap height to the third line's baseline.
struct DropCap: Equatable {
    static let lines = 3
    let font: NSFont
    /// The space the cap takes from the lines beside it.
    let indent: CGFloat
    /// Line to line, as the body is set.
    let advance: CGFloat

    init(letter: String, body: NSFont, lineSpacing: CGFloat) {
        advance = NSLayoutManager().defaultLineHeight(for: body) + lineSpacing
        let ratio = body.capHeight / max(1, body.pointSize)
        let height = CGFloat(Self.lines - 1) * advance + body.capHeight
        font = body.withSize(height / max(0.3, ratio))
        let width = NSAttributedString(string: letter, attributes: [.font: font]).size().width
        indent = ceil(width + body.pointSize * 0.3)
    }

    /// How far below the first line's top the indented lines reach.
    var depth: CGFloat { CGFloat(Self.lines) * advance - advance * 0.5 }
}

extension NSFont {
    /// Lowercase letters as small capitals; capitals stay.
    var smallCaps: NSFont {
        featured([[.typeIdentifier: kLowerCaseType, .selectorIdentifier: kLowerCaseSmallCapsSelector]])
    }
    /// Every letter as a small capital, as spaced capitals are set.
    var allSmallCaps: NSFont {
        featured([[.typeIdentifier: kLowerCaseType, .selectorIdentifier: kLowerCaseSmallCapsSelector],
                  [.typeIdentifier: kUpperCaseType, .selectorIdentifier: kUpperCaseSmallCapsSelector]])
    }
    /// Old-style (text) figures, which sit among lowercase letters.
    var oldStyleFigures: NSFont {
        featured([[.typeIdentifier: kNumberCaseType, .selectorIdentifier: kLowerCaseNumbersSelector]])
    }
    private func featured(_ settings: [[NSFontDescriptor.FeatureKey: Int]]) -> NSFont {
        NSFont(descriptor: fontDescriptor.addingAttributes([.featureSettings: settings]), size: pointSize) ?? self
    }
}
