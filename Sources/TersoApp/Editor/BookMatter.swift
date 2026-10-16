// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import TersoCore

/// The pages a book carries around its text, as manutius.app lists them.
/// They are drawn from the document's metadata, never typed into the text.
enum MatterPage: String, Codable, CaseIterable, Identifiable {
    case halfTitle, titlePage, copyright, dedication, contents, aboutAuthor
    var id: String { rawValue }

    var title: String {
        switch self {
        case .halfTitle: "Half title"
        case .titlePage: "Title page"
        case .copyright: "Copyright"
        case .dedication: "Dedication"
        case .contents: "Contents"
        case .aboutAuthor: "About the author"
        }
    }

    var isBack: Bool { self == .aboutAuthor }

    /// Display pages open on the right; the copyright page backs the title.
    var wantsRecto: Bool? {
        switch self {
        case .copyright: false
        case .aboutAuthor: nil
        default: true
        }
    }

    /// What a page needs before it is worth printing.
    func hasContent(_ meta: BookMetadata, chapters: Int) -> Bool {
        switch self {
        case .dedication: !(meta.dedication ?? "").isEmpty
        case .aboutAuthor: !(meta.about ?? "").isEmpty
        case .contents: chapters > 1
        default: true
        }
    }

    /// The front matter page by page, with a blank where a page must turn
    /// to land on the side it belongs, and the back matter.
    static func layout(_ chosen: Set<MatterPage>, meta: BookMetadata, chapters: Int) -> (front: [MatterPage?], back: [MatterPage]) {
        var front: [MatterPage?] = []
        for kind in allCases where !kind.isBack && chosen.contains(kind) && kind.hasContent(meta, chapters: chapters) {
            if let recto = kind.wantsRecto, (front.count % 2 == 0) != recto { front.append(nil) }
            front.append(kind)
        }
        // The text opens on a recto, as page 1 does.
        if front.count % 2 == 1 { front.append(nil) }
        let back = allCases.filter { $0.isBack && chosen.contains($0) && $0.hasContent(meta, chapters: chapters) }
        return (front, back)
    }
}

/// The book's particulars, kept in the document's YAML metadata so they
/// travel with the text: `title`, `subtitle`, `author`, `dedication`,
/// `copyright` and `about`.
struct BookMetadata: Equatable {
    var title: String?
    var subtitle: String?
    var author: String?
    var dedication: String?
    var copyright: String?
    var about: String?

    nonisolated(unsafe) static let keys: [(key: String, path: WritableKeyPath<BookMetadata, String?>)] = [
        ("title", \.title), ("subtitle", \.subtitle), ("author", \.author),
        ("dedication", \.dedication), ("copyright", \.copyright), ("about", \.about),
    ]

    @MainActor static func read(_ text: String) -> BookMetadata {
        var meta = BookMetadata()
        guard let fm = MarkdownSyntax.frontMatter(in: text) else { return meta }
        let block = (text as NSString).substring(with: fm)
        for (key, path) in keys {
            meta[keyPath: path] = value(of: key, in: block)
        }
        return meta
    }

    private static func pattern(_ key: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: "^\(key)[ \\t]*[:=][ \\t]*(.*?)[ \\t]*$\\n?", options: .anchorsMatchLines)
    }

    static func value(of key: String, in block: String) -> String? {
        let ns = block as NSString
        guard let m = pattern(key).firstMatch(in: block, range: NSRange(location: 0, length: ns.length)) else { return nil }
        var v = ns.substring(with: m.range(at: 1))
        if v.count >= 2, let q = v.first, q == "\"" || q == "'", v.last == q {
            v = String(v.dropFirst().dropLast())
            if q == "\"" { v = v.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\") }
        }
        return v.isEmpty ? nil : v
    }

    /// The edit that writes these values into the text's metadata: the
    /// range to replace and its replacement. Keys already there are set in
    /// place, emptied ones removed, new ones added before the closing line;
    /// a document without metadata gains a YAML block at the top.
    @MainActor func edit(of text: String) -> (range: NSRange, replacement: String)? {
        let ns = text as NSString
        let fm = MarkdownSyntax.frontMatter(in: text)
        var lines: [String]
        var closing = "---"
        if let fm {
            lines = ns.substring(with: fm).components(separatedBy: "\n")
            if lines.last == "" { lines.removeLast() }
            guard lines.count >= 2 else { return nil }
            closing = lines.removeLast()
            lines.removeFirst()
        } else {
            lines = []
        }
        var changed = false
        for (key, path) in Self.keys {
            let new = self[keyPath: path]?.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces) ?? ""
            let old = lines.firstIndex { Self.value(of: key, in: $0) != nil || $0.range(of: "^\(key)[ \\t]*[:=]", options: .regularExpression) != nil }
            let current = old.flatMap { Self.value(of: key, in: lines[$0]) } ?? ""
            guard new != current else { continue }
            changed = true
            let line = "\(key): \"\(new.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
            if let old { if new.isEmpty { lines.remove(at: old) } else { lines[old] = line } }
            else if !new.isEmpty { lines.append(line) }
        }
        guard changed else { return nil }
        let opening = fm.map { ns.substring(with: ns.lineRange(for: NSRange(location: $0.location, length: 0))).trimmingCharacters(in: .newlines) } ?? "---"
        let block = ([opening] + lines + [closing]).joined(separator: "\n") + "\n"
        if let fm {
            // The block keeps whatever line ending it had.
            return (fm, ns.substring(with: fm).hasSuffix("\n") ? block : String(block.dropLast()))
        }
        return (NSRange(location: 0, length: 0), block + "\n")
    }
}

extension TersoTextView {
    /// A page of front or back matter, set in the book's face within the
    /// text block `block`.
    func drawMatter(_ kind: MatterPage, in block: NSRect, book: BookPage, decoration d: BookDecoration) {
        let body = d.font
        let ink = d.ink
        let quiet = ink.withAlphaComponent(0.7)
        let meta = d.metadata
        let title = meta.title ?? d.title ?? "Untitled"
        func centred(_ s: String, _ font: NSFont, at y: CGFloat, color: NSColor = ink, kern: CGFloat = 0) -> CGFloat {
            let p = NSMutableParagraphStyle()
            p.alignment = .center
            let text = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .kern: kern, .paragraphStyle: p])
            let height = text.boundingRect(with: NSSize(width: block.width, height: .greatestFiniteMagnitude), options: .usesLineFragmentOrigin).height
            text.draw(with: NSRect(x: block.minX, y: y, width: block.width, height: ceil(height)), options: .usesLineFragmentOrigin)
            return y + ceil(height)
        }
        switch kind {
        case .halfTitle:
            _ = centred(title.lowercased(), body.withSize(body.pointSize * 1.1).smallCaps, at: block.minY + block.height * 0.22, kern: 1.6)
        case .titlePage:
            var y = centred(title, body.withSize(body.pointSize * 2.1), at: block.minY + block.height * 0.18)
            if let subtitle = meta.subtitle {
                y = centred(subtitle, body.withSize(body.pointSize * 1.1).adding(.italic), at: y + body.pointSize * 0.8, color: quiet)
            }
            if let author = meta.author {
                _ = centred(author.lowercased(), body.withSize(body.pointSize * 1.05).smallCaps, at: block.minY + block.height * 0.62, kern: 1.4)
            }
        case .copyright:
            let year = Calendar.current.component(.year, from: Date())
            let notice = meta.copyright ?? "Copyright © \(year)\(meta.author.map { " " + $0 } ?? "")"
            let lines = [notice, "All rights reserved.", "", "Set in \(d.face) with Terso."]
            let font = body.withSize(body.pointSize * 0.72)
            let text = NSAttributedString(string: lines.joined(separator: "\n"), attributes: [.font: font, .foregroundColor: quiet])
            let size = text.boundingRect(with: NSSize(width: block.width, height: .greatestFiniteMagnitude), options: .usesLineFragmentOrigin)
            text.draw(with: NSRect(x: block.minX, y: block.maxY - ceil(size.height), width: block.width, height: ceil(size.height)), options: .usesLineFragmentOrigin)
        case .dedication:
            _ = centred(meta.dedication ?? "", body.adding(.italic), at: block.minY + block.height * 0.22, color: quiet)
        case .contents:
            var y = centred("contents", body.withSize(body.pointSize * 1.1).smallCaps, at: block.minY + book.sink * 0.5, kern: 1.6) + body.pointSize * 2
            let placed = chapterPlacements(book, before: Int(Int32.max))
            for chapter in d.chapters {
                let folio = placed.first { $0.heading == chapter.heading }.map { book.folio($0.page) } ?? "…"
                let attrs: [NSAttributedString.Key: Any] = [.font: body, .foregroundColor: ink]
                let number = NSAttributedString(string: folio, attributes: [.font: body.oldStyleFigures, .foregroundColor: quiet])
                let numberWidth = number.size().width
                let name = NSAttributedString(string: chapter.title, attributes: attrs)
                let line = NSRect(x: block.minX, y: y, width: block.width - numberWidth - body.pointSize, height: body.pointSize * 1.6)
                name.draw(with: line, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
                number.draw(at: NSPoint(x: block.maxX - numberWidth, y: y))
                y += body.pointSize * 1.9
                if y > block.maxY - body.pointSize { break }
            }
        case .aboutAuthor:
            let y = centred("about the author", body.withSize(body.pointSize * 1.1).smallCaps, at: block.minY + book.sink, kern: 1.6) + body.pointSize * 2
            let p = NSMutableParagraphStyle()
            p.alignment = .justified
            p.hyphenationFactor = 0.9
            p.lineSpacing = d.lineSpacing
            let text = NSAttributedString(string: meta.about ?? "", attributes: [.font: body, .foregroundColor: ink, .paragraphStyle: p])
            text.draw(with: NSRect(x: block.minX, y: y, width: block.width, height: block.maxY - y), options: .usesLineFragmentOrigin)
        }
    }
}
