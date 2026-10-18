// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import SwiftUI
import Testing
import TersoCore
@testable import TersoApp

@Suite @MainActor struct FormattingCommandsTests {
    private func apply(_ command: FormattingCommand, to text: String, selection: NSRange? = nil, latex: Bool = false) throws -> (String, NSRange) {
        let edit = try #require(FormattingCommands.edit(text: text, selection: selection ?? NSRange(location: 0, length: (text as NSString).length), command: command, latex: latex))
        return ((text as NSString).replacingCharacters(in: edit.range, with: edit.replacement), edit.selection)
    }

    @Test func inlineFormattingRetainsUnicodeSelectionAndToggles() throws {
        let source = "Before 😀 café after"
        let range = (source as NSString).range(of: "😀 café")
        for command in [FormattingCommand.bold, .italic, .underline, .code] {
            for latex in [false, true] {
                let (formatted, selected) = try apply(command, to: source, selection: range, latex: latex)
                #expect((formatted as NSString).substring(with: selected) == "😀 café")
                let (restored, restoredSelection) = try apply(command, to: formatted, selection: selected, latex: latex)
                #expect(restored == source)
                #expect(restoredSelection == range)
            }
        }
        let (bold, _) = try apply(.bold, to: "**word**")
        #expect(bold == "word")
        let (italicInBold, _) = try apply(.italic, to: "**word**", selection: NSRange(location: 2, length: 4))
        #expect(italicInBold == "***word***")
        let (italicAroundBold, _) = try apply(.italic, to: "**word**")
        #expect(italicAroundBold == "***word***")
        let (boldAfterItalicToggle, _) = try apply(.italic, to: "***word***")
        #expect(boldAfterItalicToggle == "**word**")
        let (firstBold, boldSelection) = try apply(.bold, to: "word")
        let (both, bothSelection) = try apply(.italic, to: firstBold, selection: boldSelection)
        #expect(both == "***word***")
        let (onlyBold, retainedSelection) = try apply(.italic, to: both, selection: bothSelection)
        #expect(onlyBold == "**word**")
        #expect(retainedSelection == boldSelection)
        let (plain, _) = try apply(.bold, to: onlyBold, selection: retainedSelection)
        #expect(plain == "word")
    }

    @Test func insertionPlaceholdersAndDestinationsRemainEditable() throws {
        let (bold, selected) = try apply(.bold, to: "😀", selection: NSRange(location: 2, length: 0))
        #expect(bold == "😀**bold**")
        #expect((bold as NSString).substring(with: selected) == "bold")
        for latex in [false, true] {
            for command in [FormattingCommand.link, .image] {
                let (result, target) = try apply(command, to: "label", latex: latex)
                let destination = (result as NSString).substring(with: target)
                #expect(destination == (command == .link ? "https://" : latex ? "label" : "image.png"))
                let (same, existingTarget) = try apply(command, to: result, selection: target, latex: latex)
                #expect(same == result)
                #expect(existingTarget == target)
            }
        }
        let existing = "Read [docs](https://example.com) today"
        let (same, destination) = try apply(.link, to: existing, selection: (existing as NSString).range(of: "docs"))
        #expect(same == existing)
        #expect((same as NSString).substring(with: destination) == "https://example.com")
    }

    @Test func headingsReplaceTheirStyleAcrossLinesAndKeepSelection() throws {
        let source = "# One\n## Two\nThree\nOutside"
        let selection = NSRange(location: 0, length: ("# One\n## Two\nThree\n" as NSString).length)
        let (result, selected) = try apply(.blockStyle(.heading3), to: source, selection: selection)
        #expect(result == "### One\n### Two\n### Three\nOutside")
        #expect((result as NSString).substring(with: selected).hasPrefix("One"))
        let (body, _) = try apply(.blockStyle(.body), to: result, selection: selected)
        #expect(body == "One\nTwo\nThree\nOutside")
        #expect(FormattingCommands.blockStyle(text: result, selection: selected, latex: false) == .heading3)
    }

    @Test func listsNumberEveryLineAndToggleWithoutAccumulatingPrefixes() throws {
        let source = "😀 one\r\ntwo\r\n\r\nthree\r\nuntouched"
        let range = NSRange(location: 0, length: ("😀 one\r\ntwo\r\n\r\nthree\r\n" as NSString).length)
        let (numbered, selected) = try apply(.numberedList, to: source, selection: range)
        #expect(numbered == "1. 😀 one\r\n2. two\r\n\r\n3. three\r\nuntouched")
        let (restored, _) = try apply(.numberedList, to: numbered, selection: selected)
        #expect(restored == source)
        let (bullets, bulletSelection) = try apply(.bulletedList, to: "8. one\n9. two")
        #expect(bullets == "- one\n- two")
        let (numberedAgain, _) = try apply(.numberedList, to: bullets, selection: bulletSelection)
        #expect(numberedAgain == "1. one\n2. two")
    }

    @Test func caretAndPartialSelectionsStayWithTheirText() throws {
        let source = "first\nsecond\nthird"
        let caret = NSRange(location: 8, length: 0)
        let (result, selected) = try apply(.bulletedList, to: source, selection: caret)
        #expect(result == "first\n- second\nthird")
        #expect(selected == NSRange(location: 10, length: 0))
        let (empty, emptySelection) = try apply(.numberedList, to: "", selection: NSRange(location: 0, length: 0))
        #expect(empty == "1. ")
        #expect(emptySelection == NSRange(location: 3, length: 0))
        let (blankParagraph, blankCaret) = try apply(.bulletedList, to: "first\n\nlast", selection: NSRange(location: 6, length: 0))
        #expect(blankParagraph == "first\n- \nlast")
        #expect(blankCaret == NSRange(location: 8, length: 0))
        let (quote, quoteSelection) = try apply(.blockquote, to: "first\nsecond", selection: NSRange(location: 1, length: 8))
        let (restored, restoredSelection) = try apply(.blockquote, to: quote, selection: quoteSelection)
        #expect(restored == "first\nsecond")
        #expect(restoredSelection == NSRange(location: 1, length: 8))
    }

    @Test func latexProducesNativeHeadingsListsAndQuotation() throws {
        let source = "😀 One\nTwo"
        let (heading, selected) = try apply(.blockStyle(.heading2), to: source, latex: true)
        #expect(heading == "\\subsection{😀 One}\n\\subsection{Two}")
        #expect(FormattingCommands.blockStyle(text: heading, selection: selected, latex: true) == .heading2)
        let (body, _) = try apply(.blockStyle(.body), to: heading, selection: selected, latex: true)
        #expect(body == source)
        for command in [FormattingCommand.bulletedList, .numberedList, .blockquote] {
            let (result, selected) = try apply(command, to: source, latex: true)
            #expect(!result.contains("- "))
            #expect(result.contains(command == .bulletedList ? "\\begin{itemize}" : command == .numberedList ? "\\begin{enumerate}" : "\\begin{quote}"))
            #expect((result as NSString).substring(with: selected).hasPrefix("😀 One"))
            let (restored, _) = try apply(command, to: result, selection: selected, latex: true)
            #expect(restored == source)
            let (withFollowing, selectedFollowing) = try apply(command, to: "one\ntwo", selection: NSRange(location: 0, length: 4), latex: true)
            #expect(withFollowing.contains("}\ntwo"))
            let (unwrappedFollowing, _) = try apply(command, to: withFollowing, selection: selectedFollowing, latex: true)
            #expect(unwrappedFollowing == "one\ntwo")
        }
        let (empty, caret) = try apply(.blockStyle(.heading1), to: "", selection: NSRange(location: 0, length: 0), latex: true)
        #expect(empty == "\\section{}")
        #expect(caret == NSRange(location: 9, length: 0))
        let (bullets, bulletSelection) = try apply(.bulletedList, to: source, latex: true)
        let (numbers, numberSelection) = try apply(.numberedList, to: bullets, selection: bulletSelection, latex: true)
        #expect(numbers == "\\begin{enumerate}\n\\item 😀 One\n\\item Two\n\\end{enumerate}")
        let (quote, quoteSelection) = try apply(.blockquote, to: numbers, selection: numberSelection, latex: true)
        #expect(quote == "\\begin{quote}\n😀 One\nTwo\n\\end{quote}")
        let (plain, _) = try apply(.blockquote, to: quote, selection: quoteSelection, latex: true)
        #expect(plain == source)
    }

    @Test func codeBlocksAndInvalidRanges() throws {
        let (rule, _) = try apply(.horizontalRule, to: "BeforeAfter", selection: NSRange(location: 6, length: 0))
        #expect(rule == "Before\n\n---\n\nAfter")
        for source in ["a`b", "a``b", "`literal` edge", "edge `literal`"] {
            let (code, selected) = try apply(.code, to: source)
            #expect((code as NSString).substring(with: selected) == source)
            let (restored, _) = try apply(.code, to: code, selection: selected)
            #expect(restored == source)
        }
        let (nestedFence, nestedSelection) = try apply(.codeBlock, to: "```\nexample\n```")
        #expect(nestedFence.hasPrefix("````\n"))
        let (restoredFence, _) = try apply(.codeBlock, to: nestedFence, selection: nestedSelection)
        #expect(restoredFence == "```\nexample\n```")
        let nestedNS = nestedFence as NSString
        #expect(MarkdownStyler.fence.firstMatch(in: nestedFence, range: NSRange(location: 0, length: nestedNS.length))?.range == NSRange(location: 0, length: nestedNS.length))
        let inline = "``a`b``\n\nEnd"
        let inlineNS = inline as NSString
        let hidden = MarkerPresentation.hiddenSyntax(in: inline, selection: NSRange(location: inlineNS.length, length: 0), latex: false, elements: [.code])
        #expect(hidden.map { inlineNS.substring(with: $0) } == ["``", "``"])
        for latex in [false, true] {
            let (code, selected) = try apply(.codeBlock, to: "line\n😀", latex: latex)
            #expect((code as NSString).substring(with: selected) == "line\n😀")
            let (restored, _) = try apply(.codeBlock, to: code, selection: selected, latex: latex)
            #expect(restored == "line\n😀")
            let (midline, midlineSelection) = try apply(.codeBlock, to: "first line\nsecond line\nuntouched", selection: NSRange(location: 2, length: 12), latex: latex)
            #expect(midline.hasPrefix(latex ? "\\begin{verbatim}\nfirst line\nsecond line\n\\end{verbatim}\nuntouched" : "```\nfirst line\nsecond line\n```\nuntouched"))
            #expect((midline as NSString).substring(with: midlineSelection) == "rst line\nsec")
        }
        #expect(FormattingCommands.edit(text: "abc", selection: NSRange(location: 4, length: 0), command: .bold, latex: false) == nil)
        #expect(FormattingCommands.edit(text: "abc", selection: NSRange(location: 1, length: Int.max), command: .bold, latex: false) == nil)
    }

    @Test func coordinatorFormatsThroughUndoAndRejectsPreview() {
        let model = WorkspaceModel()
        model.renderMode = .source
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.documentUndoManager = undo
        let textView = TersoTextView(frame: .zero)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.documentUndoManager = model.documentUndoManager
        textView.string = "😀 word"
        let coordinator = EditorCoordinator(model: model, text: .constant(textView.string))
        coordinator.textView = textView
        coordinator.config = EditorConfig(prefs: model.prefs, model: model, latex: true)
        textView.setSelectedRange(NSRange(location: 3, length: 4))
        undo.beginUndoGrouping()
        coordinator.performFormatting(.bold)
        undo.endUndoGrouping()
        #expect(textView.string == "😀 \\textbf{word}")
        #expect((textView.string as NSString).substring(with: textView.selectedRange()) == "word")
        #expect(undo.canUndo)
        undo.undo()
        #expect(textView.string == "😀 word")
        undo.redo()
        #expect(textView.string == "😀 \\textbf{word}")
        model.renderMode = .preview
        coordinator.performFormatting(.italic)
        #expect(textView.string == "😀 \\textbf{word}")
    }

    @Test func underlineHasVisibleStylingAndMixedMarkers() {
        let source = "<u>Underlined</u> and `<u>code</u>`\n\nEnd"
        let model = WorkspaceModel()
        let storage = NSTextStorage(string: source)
        MarkdownStyler.style(storage, range: NSRange(location: 0, length: storage.length), config: EditorConfig(prefs: model.prefs, model: model))
        #expect(storage.attribute(.underlineStyle, at: 3, effectiveRange: nil) as? Int == NSUnderlineStyle.single.rawValue)
        let code = (source as NSString).range(of: "code")
        #expect(storage.attribute(.underlineStyle, at: code.location, effectiveRange: nil) == nil)
        let hidden = MarkerPresentation.hiddenSyntax(in: source, selection: NSRange(location: storage.length, length: 0), latex: false, elements: [.emphasis])
        #expect(hidden.map { (source as NSString).substring(with: $0) } == ["<u>", "</u>"])
    }
}
