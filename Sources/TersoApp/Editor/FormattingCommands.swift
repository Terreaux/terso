// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import TersoCore

enum EditorBlockStyle: String, CaseIterable, Identifiable {
    case body = "Body", heading1 = "Heading 1", heading2 = "Heading 2", heading3 = "Heading 3"
    var id: String { rawValue }
}

enum FormattingCommand: Equatable {
    case bold, italic, underline, link, image, bulletedList, numberedList, blockquote, code, codeBlock, horizontalRule
    case blockStyle(EditorBlockStyle)
}

/// One source edit and the resulting UTF-16 selection. Keeping transformation
/// independent of AppKit makes the toolbar and keyboard commands share behavior.
struct FormattingEdit {
    let range: NSRange
    let replacement: String
    let selection: NSRange
}

enum FormattingCommands {
    static func blockStyle(text: String, selection: NSRange, latex: Bool) -> EditorBlockStyle {
        let ns = text as NSString
        guard selection.location >= 0, selection.location <= ns.length else { return .body }
        let line = ns.substring(with: ns.lineRange(for: NSRange(location: selection.location, length: 0)))
        let pattern = latex ? #"^[ \t]*\\(section|subsection|subsubsection)\{"# : #"^[ \t]{0,3}(#{1,3})[ \t]+"#
        guard let match = try! NSRegularExpression(pattern: pattern).firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) else { return .body }
        let marker = (line as NSString).substring(with: match.range(at: 1))
        if latex { return marker == "section" ? .heading1 : marker == "subsection" ? .heading2 : .heading3 }
        return marker.count == 1 ? .heading1 : marker.count == 2 ? .heading2 : .heading3
    }

    static func edit(text: String, selection: NSRange, command: FormattingCommand, latex: Bool) -> FormattingEdit? {
        let ns = text as NSString
        guard selection.location >= 0, selection.length >= 0,
              selection.location <= ns.length, selection.length <= ns.length - selection.location else { return nil }
        switch command {
        case .bold: return wrap(ns, selection, prefix: latex ? "\\textbf{" : "**", suffix: latex ? "}" : "**", placeholder: "bold")
        case .italic: return wrap(ns, selection, prefix: latex ? "\\emph{" : "*", suffix: latex ? "}" : "*", placeholder: "italic")
        case .underline: return wrap(ns, selection, prefix: latex ? "\\underline{" : "<u>", suffix: latex ? "}" : "</u>", placeholder: "text")
        case .code:
            if !latex, ns.substring(with: selection).contains("\n") { return markdownCodeBlock(ns, selection) }
            return latex ? wrap(ns, selection, prefix: "\\texttt{", suffix: "}", placeholder: "code") : inlineCode(ns, selection)
        case .codeBlock:
            return latex ? environment(ns, selection, prefix: "\\begin{verbatim}\n", suffix: "\n\\end{verbatim}", placeholder: "code") : markdownCodeBlock(ns, selection)
        case .link, .image: return destination(ns, selection, image: command == .image, latex: latex)
        case .horizontalRule:
            return FormattingEdit(range: selection, replacement: latex ? "\n\\noindent\\rule{\\linewidth}{0.4pt}\n" : "\n\n---\n\n", selection: NSRange(location: selection.location, length: 0))
        case .blockStyle(let style): return lines(ns, selection, style: style, command: command, latex: latex)
        case .bulletedList, .numberedList, .blockquote: return lines(ns, selection, style: nil, command: command, latex: latex)
        }
    }

    private static func longestTicks(_ text: String) -> Int {
        let runs = try! NSRegularExpression(pattern: "`+")
        return runs.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).map(\.range.length).max() ?? 0
    }

    private static func inlineCode(_ text: NSString, _ selection: NSRange) -> FormattingEdit {
        let selected = text.substring(with: selection)
        let marker = String(repeating: "`", count: max(1, longestTicks(selected) + 1))
        let padding = selected.hasPrefix("`") || selected.hasSuffix("`") ? " " : ""
        let p = ((marker + padding) as NSString).length
        if selection.length > 0, selection.location >= p, NSMaxRange(selection) + p <= text.length,
           text.substring(with: NSRange(location: selection.location - p, length: p)) == marker + padding,
           text.substring(with: NSRange(location: NSMaxRange(selection), length: p)) == padding + marker {
            return FormattingEdit(range: NSRange(location: selection.location - p, length: selection.length + p * 2), replacement: selected,
                                  selection: NSRange(location: selection.location - p, length: selection.length))
        }
        let opening = selected.prefix { $0 == "`" }.count
        let closing = selected.reversed().prefix { $0 == "`" }.count
        if opening > 0, opening == closing, selected.count > opening + closing {
            var content = String(selected.dropFirst(opening).dropLast(closing))
            if longestTicks(content) < opening {
                if content.hasPrefix(" "), content.hasSuffix(" "), !content.trimmingCharacters(in: .whitespaces).isEmpty { content = String(content.dropFirst().dropLast()) }
                return FormattingEdit(range: selection, replacement: content, selection: NSRange(location: selection.location, length: (content as NSString).length))
            }
        }
        return wrap(text, selection, prefix: marker + padding, suffix: padding + marker, placeholder: "code")
    }

    private static func markdownCodeBlock(_ text: NSString, _ selection: NSRange) -> FormattingEdit {
        let touched = NSRange(location: selection.location, length: selection.length > 0 ? selection.length - 1 : 0)
        let block = text.substring(with: text.lineRange(for: touched))
        let marker = String(repeating: "`", count: max(3, longestTicks(block) + 1))
        return environment(text, selection, prefix: marker + "\n", suffix: "\n" + marker, placeholder: "code")
    }

    private static func wrap(_ text: NSString, _ selection: NSRange, prefix: String, suffix: String, placeholder: String) -> FormattingEdit {
        let selected = text.substring(with: selection)
        let p = (prefix as NSString).length, s = (suffix as NSString).length
        let leadingStars = selected.prefix { $0 == "*" }.count
        let trailingStars = selected.reversed().prefix { $0 == "*" }.count
        let selectedItalicWrapper = prefix != "*" || (leadingStars == trailingStars && leadingStars % 2 == 1)
        if selection.length >= p + s, selected.hasPrefix(prefix), selected.hasSuffix(suffix), selectedItalicWrapper {
            let inner = (selected as NSString).substring(with: NSRange(location: p, length: selection.length - p - s))
            return FormattingEdit(range: selection, replacement: inner, selection: NSRange(location: selection.location, length: (inner as NSString).length))
        }
        let starsBefore = text.substring(to: selection.location).reversed().prefix { $0 == "*" }.count
        let starsAfter = text.substring(from: NSMaxRange(selection)).prefix { $0 == "*" }.count
        let surroundingItalicWrapper = prefix != "*" || (starsBefore == starsAfter && starsBefore % 2 == 1)
        if selection.length > 0, selection.location >= p, NSMaxRange(selection) + s <= text.length,
           text.substring(with: NSRange(location: selection.location - p, length: p)) == prefix,
           text.substring(with: NSRange(location: NSMaxRange(selection), length: s)) == suffix,
           // Odd runs carry italic (including bold + italic's three stars).
           surroundingItalicWrapper {
            return FormattingEdit(range: NSRange(location: selection.location - p, length: selection.length + p + s), replacement: selected,
                                  selection: NSRange(location: selection.location - p, length: selection.length))
        }
        let inner = selection.length == 0 ? placeholder : selected
        return FormattingEdit(range: selection, replacement: prefix + inner + suffix,
                              selection: NSRange(location: selection.location + p, length: (inner as NSString).length))
    }

    private static func destination(_ text: NSString, _ selection: NSRange, image: Bool, latex: Bool) -> FormattingEdit {
        let pattern = latex
            ? (image ? #"\\includegraphics(?:\[[^\]\n]*\])?\{([^}\n]*)\}"# : #"\\href\{([^}\n]*)\}\{[^}\n]*\}"#)
            : (image ? #"!\[[^\]\n]*\]\(([^)\n]*)\)"# : #"(?<!!)\[[^\]\n]*\]\(([^)\n]*)\)"#)
        let regex = try! NSRegularExpression(pattern: pattern)
        if let match = regex.matches(in: text as String, range: NSRange(location: 0, length: text.length)).first(where: {
            selection.location >= $0.range.location && NSMaxRange(selection) <= NSMaxRange($0.range)
        }) {
            return FormattingEdit(range: match.range, replacement: text.substring(with: match.range), selection: match.range(at: 1))
        }
        let label = selection.length > 0 ? text.substring(with: selection) : (image ? "image" : "text")
        let prefix: String, value: String, suffix: String
        if latex {
            prefix = image ? "\\includegraphics{" : "\\href{"
            value = image && selection.length > 0 ? label : (image ? "image.png" : "https://")
            suffix = image ? "}" : "}{" + label + "}"
        } else {
            prefix = (image ? "![" : "[") + label + "]("; value = image ? "image.png" : "https://"; suffix = ")"
        }
        return FormattingEdit(range: selection, replacement: prefix + value + suffix,
                              selection: NSRange(location: selection.location + (prefix as NSString).length, length: (value as NSString).length))
    }

    private static func environment(_ text: NSString, _ selection: NSRange, prefix: String, suffix: String, placeholder: String) -> FormattingEdit {
        let touched = NSRange(location: selection.location, length: selection.length > 0 ? selection.length - 1 : 0)
        let range = text.lineRange(for: touched)
        let closing = suffix.hasPrefix("\n") ? String(suffix.dropFirst()) : suffix
        let p = (prefix as NSString).length, s = (closing as NSString).length
        if range.location >= p, NSMaxRange(range) + s <= text.length,
           text.substring(with: NSRange(location: range.location - p, length: p)) == prefix,
           text.substring(with: NSRange(location: NSMaxRange(range), length: s)) == closing {
            let closingEnd = NSMaxRange(range) + s
            let trailing = closingEnd < text.length && text.substring(with: NSRange(location: closingEnd, length: 1)) == "\n"
            let whole = NSRange(location: range.location - p, length: range.length + p + s + (trailing ? 1 : 0))
            var body = text.substring(with: range)
            if !trailing && body.hasSuffix("\n") { body.removeLast() }
            return FormattingEdit(range: whole, replacement: body, selection: NSRange(location: selection.location - p, length: min(selection.length, max(0, (body as NSString).length - (selection.location - range.location)))))
        }
        let source = text.substring(with: range)
        let body = source.isEmpty ? placeholder : source
        let trailing = body.hasSuffix("\n")
        return FormattingEdit(range: range, replacement: prefix + body + (trailing ? "" : "\n") + closing + (trailing ? "\n" : ""),
                              selection: NSRange(location: selection.location + p, length: source.isEmpty ? (placeholder as NSString).length : selection.length))
    }

    private struct Change { let range: NSRange; let replacement: String; var shiftsBoundary = true }

    private static func lines(_ text: NSString, _ selection: NSRange, style: EditorBlockStyle?, command: FormattingCommand, latex: Bool) -> FormattingEdit {
        // A selection ending at the next line's start belongs to the preceding line.
        let touched = NSRange(location: selection.location, length: selection.length > 0 ? selection.length - 1 : 0)
        let range = text.lineRange(for: touched)
        if latex, style == nil {
            let name = command == .bulletedList ? "itemize" : command == .numberedList ? "enumerate" : "quote"
            return latexEnvironment(text, selection, range: range, name: name)
        }
        let block = text.substring(with: range) as NSString
        var rows: [NSRange] = [], position = 0
        while position < block.length {
            var start = 0, end = 0, contentsEnd = 0
            block.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: position, length: 0))
            rows.append(NSRange(location: start, length: contentsEnd - start)); position = end
        }
        if rows.isEmpty { rows = [NSRange(location: 0, length: 0)] }
        let heading = try! NSRegularExpression(pattern: latex ? #"^([ \t]*)\\(?:section|subsection|subsubsection)\{(.*)\}$"# : #"^([ \t]{0,3})(?:#{1,6})[ \t]+"#, options: .anchorsMatchLines)
        let list = try! NSRegularExpression(pattern: #"^([ \t]*)([-+*]|[0-9]+[.)])[ \t]+"#, options: .anchorsMatchLines)
        let quote = try! NSRegularExpression(pattern: #"^([ \t]*)>[ \t]?"#, options: .anchorsMatchLines)
        let kind = command == .blockquote ? quote : list
        func marker(_ row: NSRange) -> NSTextCheckingResult? { kind.firstMatch(in: block as String, range: row) }
        let nonblank = rows.filter { !block.substring(with: $0).trimmingCharacters(in: .whitespaces).isEmpty }
        let toggleOff = !nonblank.isEmpty && nonblank.allSatisfy { row in
            guard let m = marker(row) else { return false }
            if command == .blockquote { return true }
            let value = block.substring(with: m.range(at: 2))
            return command == .numberedList ? value.first?.isNumber == true : value.first?.isNumber == false
        }
        var changes: [Change] = [], number = 0
        for row in rows {
            let source = block.substring(with: row)
            if source.trimmingCharacters(in: .whitespaces).isEmpty && !(selection.length == 0 && rows.count == 1) { continue }
            if let style {
                let match = heading.firstMatch(in: block as String, range: row)
                if latex {
                    let indent = match.map { block.substring(with: $0.range(at: 1)) } ?? String(source.prefix { $0 == " " || $0 == "\t" })
                    let name = style == .heading1 ? "section" : style == .heading2 ? "subsection" : "subsubsection"
                    // Individual prefix/suffix changes retain the selection inside a heading.
                    let oldPrefix = match.map { $0.range(at: 2).location - row.location } ?? (indent as NSString).length
                    let newPrefix = style == .body ? indent : indent + "\\" + name + "{"
                    changes.append(Change(range: NSRange(location: row.location, length: oldPrefix), replacement: newPrefix))
                    changes.append(Change(range: NSRange(location: NSMaxRange(row) - (match == nil ? 0 : 1), length: match == nil ? 0 : 1), replacement: style == .body ? "" : "}", shiftsBoundary: false))
                } else {
                    let indent = match.map { block.substring(with: $0.range(at: 1)) } ?? String(source.prefix { $0 == " " || $0 == "\t" })
                    let marker = style == .body ? "" : String(repeating: "#", count: style == .heading1 ? 1 : style == .heading2 ? 2 : 3) + " "
                    changes.append(Change(range: match?.range ?? NSRange(location: row.location, length: (indent as NSString).length), replacement: indent + marker))
                }
            } else {
                number += 1
                let match = marker(row)
                let indent = match.map { block.substring(with: $0.range(at: 1)) } ?? String(source.prefix { $0 == " " || $0 == "\t" })
                let marker = toggleOff ? "" : command == .blockquote ? "> " : command == .numberedList ? "\(number). " : "- "
                changes.append(Change(range: match?.range ?? NSRange(location: row.location, length: (indent as NSString).length), replacement: indent + marker))
            }
        }
        return applying(changes, to: block, range: range, selection: selection)
    }

    private static func applying(_ changes: [Change], to block: NSString, range: NSRange, selection: NSRange) -> FormattingEdit {
        let output = NSMutableString(string: block as String)
        for change in changes.reversed() { output.replaceCharacters(in: change.range, with: change.replacement) }
        func map(_ index: Int) -> Int {
            let local = index - range.location
            var delta = 0
            for c in changes {
                if local < c.range.location || (local == c.range.location && !c.shiftsBoundary) { break }
                let length = (c.replacement as NSString).length
                if local < NSMaxRange(c.range) { return range.location + c.range.location + delta + length }
                delta += length - c.range.length
            }
            return index + delta
        }
        let start = map(selection.location), end = map(NSMaxRange(selection))
        return FormattingEdit(range: range, replacement: output as String, selection: NSRange(location: start, length: max(0, end - start)))
    }

    private static func latexEnvironment(_ text: NSString, _ selection: NSRange, range: NSRange, name: String) -> FormattingEdit {
        let prefix = "\\begin{\(name)}\n", suffix = "\\end{\(name)}"
        // Recognize the adjacent environment so changing list type replaces its
        // wrapper instead of nesting another list around the selected items.
        let existing = ["itemize", "enumerate", "quote"].first { candidate in
            let p = ("\\begin{\(candidate)}\n" as NSString).length
            let closing = "\\end{\(candidate)}", s = (closing as NSString).length
            return range.location >= p && NSMaxRange(range) + s <= text.length
                && text.substring(with: NSRange(location: range.location - p, length: p)) == "\\begin{\(candidate)}\n"
                && text.substring(with: NSRange(location: NSMaxRange(range), length: s)) == closing
        }
        let oldPrefixLength = existing.map { ("\\begin{\($0)}\n" as NSString).length } ?? 0
        let oldSuffixLength = existing.map { ("\\end{\($0)}" as NSString).length } ?? 0
        let closingEnd = NSMaxRange(range) + oldSuffixLength
        let closingHasNewline = existing != nil && closingEnd < text.length && text.substring(with: NSRange(location: closingEnd, length: 1)) == "\n"
        let bodyRange = NSRange(location: range.location - oldPrefixLength, length: range.length + oldPrefixLength + oldSuffixLength + (closingHasNewline ? 1 : 0))
        let toggleOff = existing == name
        let block = text.substring(with: range) as NSString
        let item = try! NSRegularExpression(pattern: #"(?m)^([ \t]*)(?:\\item[ \t]+)?"#)
        let matches = item.matches(in: block as String, range: NSRange(location: 0, length: block.length)).filter {
            guard $0.range.location < block.length else { return block.length == 0 }
            return !block.substring(with: block.lineRange(for: NSRange(location: $0.range.location, length: 0))).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let needsItems = !toggleOff && name != "quote"
        let changes = (existing != nil && existing != "quote" || needsItems) ? matches.map { m in
            Change(range: m.range, replacement: block.substring(with: m.range(at: 1)) + (needsItems ? "\\item " : ""))
        } : []
        let transformed = applying(changes, to: block, range: range, selection: selection)
        var body = transformed.replacement
        if existing != nil && !closingHasNewline && body.hasSuffix("\n") { body.removeLast() }
        let replacement = toggleOff ? body : prefix + body + (body.hasSuffix("\n") ? "" : "\n") + suffix + (body.hasSuffix("\n") ? "\n" : "")
        return FormattingEdit(range: bodyRange, replacement: replacement,
                              selection: NSRange(location: transformed.selection.location - oldPrefixLength + (toggleOff ? 0 : (prefix as NSString).length), length: transformed.selection.length))
    }
}

extension EditorCoordinator {
    func performFormatting(_ command: FormattingCommand) {
        guard let tv = textView, model.renderMode != .preview, config?.renderMode != .preview,
              let edit = FormattingCommands.edit(text: tv.string, selection: tv.selectedRange(), command: command, latex: config?.latex == true) else { return }
        if (tv.string as NSString).substring(with: edit.range) != edit.replacement {
            let expected = (tv.string as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
            replace(TextSpan(edit.range), with: edit.replacement, actionName: "Format")
            guard tv.string == expected else { return }
        }
        tv.setSelectedRange(edit.selection)
        tv.scrollRangeToVisible(edit.selection)
        tv.window?.makeFirstResponder(tv)
    }
}
