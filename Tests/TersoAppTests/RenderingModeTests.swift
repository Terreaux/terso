// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import SwiftUI
import Testing
import WebKit
import TersoCore
@testable import TersoApp

@Suite @MainActor struct RenderingModeTests {
    @Test func mathRegionsAndActiveLinesUseOriginalUTF16Offsets() {
        let text = "😀 $x_i$ and $y^2$\n\n$$\n\\frac{a}{b}\n$$\n\n`$code$`\n```latex\n$fenced$\n```\nPrice $5 and $10.\n$unfinished"
        let regions = MathPresentation.regions(in: text)
        #expect(regions.count == 3)
        #expect(regions[0].range.location == 3)
        #expect(MathPresentation.showsSource(regions[1].range.nsRange, selection: NSRange(location: 0, length: 0), text: text))
        let insideDisplay = (text as NSString).range(of: "frac").location
        #expect(MathPresentation.showsSource(regions[2].range.nsRange, selection: NSRange(location: insideDisplay, length: 0), text: text))
        #expect(MathPresentation.regions(in: #"Unfinished $x\$"#).isEmpty)
        #expect(!MathPresentation.showsSource(regions[0].range.nsRange, selection: NSRange(location: insideDisplay, length: 0), text: text))
        #expect(MathPresentation.showsSource(regions[2].range.nsRange, selection: NSRange(location: 0, length: insideDisplay), text: text))
    }

    @Test func nestedMacrosExcludeCodeAndComments() {
        let text = #"""
        \newcommand{\vect}[1]{\mathbf{#1}}
        \newcommand{\energy}{\sqrt{s}}
        % \newcommand{\comment}{bad}
        `\newcommand{\code}{bad}`
        \newcommand{\optional}[1][x]{bad}
        """#
        let macros = MathPresentation.macros(in: text)
        #expect(macros == [#"\vect"#: #"\mathbf{#1}"#, #"\energy"#: #"\sqrt{s}"#])
    }

    @Test func glyphSubstitutionLeavesSourceAndRangesIntact() {
        let text = "Before $x_i$ after."
        let storage = NSTextStorage(string: text, attributes: [.font: NSFont.systemFont(ofSize: 18)])
        let layout = MathLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 500, height: 2000)); layout.addTextContainer(container)
        let range = (text as NSString).range(of: "$x_i$")
        let image = NSImage(size: NSSize(width: 80, height: 45))
        layout.setRendered([RenderedMath(range: range, image: image)])
        layout.ensureLayout(for: container)
        #expect(storage.string == text)
        let first = layout.glyphIndexForCharacter(at: range.location)
        #expect(layout.propertyForGlyph(at: first).contains(.controlCharacter))
        #expect(layout.propertyForGlyph(at: first + 1).contains(.null))
        let box = layout.boundingRect(forGlyphRange: NSRange(location: first, length: 1), in: container)
        #expect(box.width >= 80)
        layout.setRendered([])
        layout.ensureLayout(for: container)
        #expect(!layout.propertyForGlyph(at: first).contains(.controlCharacter))
        #expect(storage.string == text)
    }

    @Test func typingPreservesUnchangedMathAndLinkGlyphs() {
        let text = "Prose\n\n$x$ and $y$\n\n[site](url)"
        let model = WorkspaceModel()
        let coordinator = EditorCoordinator(model: model, text: .constant(text))
        let storage = NSTextStorage(string: text)
        let layout = MathLayoutManager(); storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 700, height: 2000))
        layout.addTextContainer(container)
        let tv = TersoTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), textContainer: container)
        coordinator.textView = tv
        coordinator.config = EditorConfig(prefs: model.prefs, model: model)
        coordinator.mathSource = text
        MarkdownStyler.style(storage, range: NSRange(location: 0, length: storage.length), config: coordinator.config)
        storage.delegate = coordinator
        let image = NSImage(size: NSSize(width: 40, height: 30))
        let math = ["$x$", "$y$"].map { (text as NSString).range(of: $0) }
        layout.setRendered(math.map { RenderedMath(range: $0, image: image) })
        let links = LinkPresentation.hiddenSyntax(in: text, selection: NSRange(location: 0, length: 0))
        layout.hiddenSyntax = links
        layout.ensureLayout(for: container)

        // A surrogate pair shifts UTF-16 offsets by two without exposing any
        // unrelated source, even before the asynchronous renderer can run.
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "😀")
        #expect(layout.rendered.map(\.range) == math.map { NSRange(location: $0.location + 2, length: $0.length) })
        #expect(layout.rendered.allSatisfy { $0.image === image })
        #expect(layout.hiddenSyntax == links.map { NSRange(location: $0.location + 2, length: $0.length) })
        tv.setSelectedRange(NSRange(location: 2, length: 0))
        coordinator.updateMathPresentation()
        #expect(layout.rendered.count == 2)
        coordinator.mathTask?.cancel()

        // Editing one formula reveals only that formula; deletion before the
        // other one shifts its retained image back to the correct source.
        storage.replaceCharacters(in: NSRange(location: math[0].location + 3, length: 1), with: "zz")
        #expect(layout.rendered.map(\.range) == [NSRange(location: math[1].location + 3, length: math[1].length)])
        storage.replaceCharacters(in: NSRange(location: 0, length: 2), with: "")
        #expect(layout.rendered.map(\.range) == [NSRange(location: math[1].location + 1, length: math[1].length)])
        #expect(layout.rendered.first?.image === image)
        layout.ensureLayout(for: container)
        let retained = layout.glyphIndexForCharacter(at: math[1].location + 1)
        #expect(layout.propertyForGlyph(at: retained).contains(.controlCharacter))
        let edited = layout.glyphIndexForCharacter(at: math[0].location)
        #expect(!layout.propertyForGlyph(at: edited).contains(.controlCharacter))
        for range in layout.hiddenSyntax {
            let glyph = layout.glyphIndexForCharacter(at: range.location)
            #expect(layout.propertyForGlyph(at: glyph).contains(.null))
        }
    }

    /// A caret reveal edits nothing, so the selection redraw that follows must
    /// already find the new layout: otherwise a highlight's background is filled
    /// where its text was, under glyphs drawn where they are now.
    @Test func revealsRelayOutAndRedrawTheVisibleText() {
        let text = "The sampler is now ==twice as fast==, as measured.\n\nNext line"
        let storage = NSTextStorage(string: text)
        let layout = MathLayoutManager(); storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 700, height: 2000)); layout.addTextContainer(container)
        let tv = TersoTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), textContainer: container)
        let window = NSWindow(contentRect: tv.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = tv
        window.display()
        let markers = MarkerPresentation.hiddenSyntax(in: text, selection: NSRange(location: storage.length, length: 0),
                                                      latex: false, elements: [.comments])
        #expect(markers.count == 2)
        for hidden in [markers, [], markers] {
            layout.hiddenSyntax = hidden
            #expect(layout.firstUnlaidCharacterIndex() == storage.length)
            let twice = layout.glyphIndexForCharacter(at: (text as NSString).range(of: "twice").location)
            #expect(tv.needsToDraw(layout.lineFragmentRect(forGlyphAt: twice, effectiveRange: nil).offsetBy(dx: tv.textContainerOrigin.x, dy: tv.textContainerOrigin.y)))
            window.display()
        }
    }

    @Test func tallMathAndSourceTransitionsStayInsideTheirLines() {
        let text = "Text before.\n\n*$$\n\\begin{aligned}\nu &= 1 \\\\\nv &= 2\n\\end{aligned}\n$$*\n\nText after."
        let model = WorkspaceModel()
        let storage = NSTextStorage(string: text)
        MarkdownStyler.style(storage, range: NSRange(location: 0, length: storage.length), config: EditorConfig(prefs: model.prefs, model: model))
        let layout = MathLayoutManager(); storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 500, height: 2000)); layout.addTextContainer(container)
        let region = MathPresentation.regions(in: text)[0]
        let image = NSImage(size: NSSize(width: 140, height: 150))
        for rendered in [true, false, true, false] {
            layout.setRendered(rendered ? [RenderedMath(range: region.range.nsRange, image: image)] : [])
            layout.ensureLayout(for: container)
            if rendered {
                let glyph = layout.glyphIndexForCharacter(at: region.range.location)
                let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                let position = layout.location(forGlyphAt: glyph)
                let top = line.minY + position.y - image.size.height + 4
                #expect(top >= line.minY)
                #expect(top + image.size.height <= line.maxY)
            } else {
                let fresh = NSLayoutManager(); let freshStorage = NSTextStorage(attributedString: storage)
                freshStorage.addLayoutManager(fresh)
                let freshContainer = NSTextContainer(size: container.size); fresh.addTextContainer(freshContainer)
                fresh.ensureLayout(for: freshContainer)
                for offset in [region.range.location, region.contentRange.location, region.range.upperBound - 1, storage.length - 1] {
                    let actual = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: offset), effectiveRange: nil)
                    let expected = fresh.lineFragmentRect(forGlyphAt: fresh.glyphIndexForCharacter(at: offset), effectiveRange: nil)
                    #expect(actual == expected)
                }
            }
        }
    }

    @Test func mathPDFSnapshotAndMacrosRenderOffline() async throws {
        let renderer = MathImageRenderer()
        let image = try await renderer.image(formula: #"\vect{p}_T = \frac{a}{b}"#, display: false,
                                             macros: [#"\vect"#: #"\mathbf{#1}"#], fontSize: 18, width: 500, dark: false)
        #expect(image != nil)
        #expect((image?.size.width ?? 0) > 20)
        #expect((image?.size.height ?? 0) > 10)
        let withoutDefinition = try await renderer.image(formula: #"\vect{p}_T = \frac{a}{b}"#, display: false,
                                                         macros: [:], fontSize: 18, width: 500, dark: false)
        #expect(withoutDefinition == nil)
    }

    @Test func mermaidFencesKeepUTF16RangesAndIncompleteSource() {
        let text = "😀 before\n\n```mermaid\ngraph TD\nA-->B\n```\n\n~~~~MERMAID\nsequenceDiagram\nA->>B: Hi\n~~~~~\n\n```other\n```mermaid\nnot a diagram\n```\n```\n\n```mermaid\nunfinished"
        let blocks = MermaidPresentation.blocks(in: text)
        let ns = text as NSString
        #expect(blocks.count == 2)
        #expect(blocks[0].range == ns.range(of: "```mermaid\ngraph TD\nA-->B\n```"))
        #expect(blocks[0].source == "graph TD\nA-->B")
        #expect(blocks[1].source == "sequenceDiagram\nA->>B: Hi")
        #expect(MermaidPresentation.blocks(in: "```mermaid\ngraph TD\nA-->B").isEmpty)
    }

    @Test func mermaidRendersOfflineInPreviewAndMixed() async throws {
        let source = "# Diagram\n\n```mermaid\ngraph TD\nA[Start]-->B[End]\n```\n"
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 700, height: 800))
        web.loadHTMLString(MarkdownPreviewHTML.document(source: source, dark: false, fontSize: 18), baseURL: nil)
        let deadline = ContinuousClock.now + .seconds(10)
        var rendered = false
        while ContinuousClock.now < deadline {
            rendered = (try? await web.evaluateJavaScript("document.querySelector('.mermaid-diagram svg') !== null")) as? Bool ?? false
            if rendered { break }
            try await Task.sleep(for: .milliseconds(40))
        }
        #expect(rendered)
        let offset = try await web.evaluateJavaScript("Number(document.querySelector('.mermaid-diagram').closest('section').dataset.source)") as? Int
        #expect(offset == (source as NSString).range(of: "```mermaid").location)

        let image = try await MermaidImageRenderer().image(source: "graph TD\nA-->B", width: 500, dark: false)
        #expect((image?.size.width ?? 0) > 20)
        #expect((image?.size.height ?? 0) > 20)
    }

    @Test(arguments: ["\n", "\r\n"])
    func fullMarkdownPreviewPreservesMathCodeAndSourceLocations(newline: String) async throws {
        let source = "# Heading 😀\n\nA **bold** result $x_i^2$.\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\n```latex\n$literal$\n```\n\n<script>window.injected=true</script>\n".replacingOccurrences(of: "\n", with: newline)
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 700, height: 800))
        web.loadHTMLString(MarkdownPreviewHTML.document(source: source, dark: false, fontSize: 18), baseURL: nil)
        let deadline = ContinuousClock.now + .seconds(10)
        var ready = false
        while ContinuousClock.now < deadline {
            ready = (try? await web.evaluateJavaScript("document.querySelector('.katex') !== null")) as? Bool ?? false
            if ready { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(ready)
        #expect(try await web.evaluateJavaScript("document.querySelectorAll('h1,strong,table,pre code').length") as? Int == 4)
        #expect(try await web.evaluateJavaScript("document.querySelector('pre code').textContent") as? String == "$literal$\n")
        #expect(try await web.evaluateJavaScript("window.injected === undefined") as? Bool == true)
        let mathOffset = try await web.evaluateJavaScript("Number(document.querySelector('.katex').parentElement.dataset.source)") as? Int
        #expect(mathOffset == (source as NSString).range(of: "$x_i^2$").location)
        let tableOffset = try await web.evaluateJavaScript("Number(document.querySelector('table').parentElement.dataset.source)") as? Int
        #expect(tableOffset == (source as NSString).range(of: "| A | B |").location)
    }

    @Test func previewRendersFootnotesAdmonitionsHighlightsAndCriticMarkup() async throws {
        let source = "Claim.[^a] Again[^a] and ==key== with {++added++} {--cut--} {~~old~>new~~} {==look==}{>>why?<<}.\n\n"
            + "!!! warning \"Mind the gap\"\n    Body with $x$.\n\n    Second paragraph.\n\n??? note\n    Folded.\n\n"
            + "[^a]: The note, **bold**.\n    Indented continuation.\n\nAfter `==code==` and [^missing].\n"
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 700, height: 800))
        web.loadHTMLString(MarkdownPreviewHTML.document(source: source, dark: false, fontSize: 18), baseURL: nil)
        let deadline = ContinuousClock.now + .seconds(10)
        var ready = false
        while ContinuousClock.now < deadline {
            ready = (try? await web.evaluateJavaScript("document.querySelector('.katex') !== null")) as? Bool ?? false
            if ready { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(ready)
        func js(_ script: String) async throws -> Any? { try await web.evaluateJavaScript(script) }
        #expect(try await js("[...document.querySelectorAll('sup.footnote-ref a')].map(a => a.textContent).join()") as? String == "1,1")
        #expect(try await js("document.querySelectorAll('.footnotes li').length") as? Int == 1)
        #expect(try await js("document.querySelector('#fn-a').textContent.includes('Indented continuation')") as? Bool == true)
        #expect(try await js("document.querySelector('#fn-a strong') !== null") as? Bool == true)
        #expect(try await js("Number(document.querySelector('#fn-a').dataset.source)") as? Int == (source as NSString).range(of: "[^a]:").location)
        #expect(try await js("document.body.textContent.includes('[^missing]')") as? Bool == true)
        #expect(try await js("[...document.querySelectorAll('mark')].map(m => m.textContent).join()") as? String == "key,look")
        #expect(try await js("document.querySelector('code').textContent") as? String == "==code==")
        #expect(try await js("[...document.querySelectorAll('ins.critic')].map(m => m.textContent).join()") as? String == "added,new")
        #expect(try await js("[...document.querySelectorAll('del.critic')].map(m => m.textContent).join()") as? String == "cut,old")
        #expect(try await js("document.querySelector('.critic-comment').textContent") as? String == "why?")
        #expect(try await js("document.querySelector('div.admonition.warning .admonition-title').textContent") as? String == "Mind the gap")
        #expect(try await js("document.querySelectorAll('div.admonition.warning p').length") as? Int == 3)
        #expect(try await js("document.querySelector('div.admonition .katex') !== null") as? Bool == true)
        #expect(try await js("document.querySelector('details.admonition.note:not([open]) > summary').textContent") as? String == "Note")
        let admonitionOffset = try await js("Number(document.querySelector('div.admonition').parentElement.dataset.source)") as? Int
        #expect(admonitionOffset == (source as NSString).range(of: "!!!").location)
    }

    @Test func sourceModeDoesNotModifyText() {
        let model = WorkspaceModel(); model.renderMode = .source
        let text = "# Heading\n\n**Bold** and $x_i$"
        let storage = NSTextStorage(string: text)
        MarkdownStyler.style(storage, range: NSRange(location: 0, length: storage.length), config: EditorConfig(prefs: model.prefs, model: model))
        #expect(storage.string == text)
        let font = storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(font?.isFixedPitch == true)
    }
}

@Suite @MainActor struct RenderingTransitionTests {
    @Test func mixedLinksShowLabelsAndRevealSourceOnActiveLines() {
        let text = "# **Heading**\n\n[site](https://example.com) [[Note]] [[Target#Section|alias]]\n\n`[[code]]` and `$x$`\n\nElsewhere"
        let ns = text as NSString
        let hidden = LinkPresentation.hiddenSyntax(in: text, selection: NSRange(location: ns.length, length: 0))
        #expect(hidden.count == 6)
        for token in ["#", "**", "site", "Note", "alias", "[[code]]"] {
            #expect(!hidden.contains { NSIntersectionRange($0, ns.range(of: token)).length > 0 })
        }
        for token in ["](https://example.com)", "[[Target#Section|", "]]"] {
            #expect(hidden.contains { NSIntersectionRange($0, ns.range(of: token)).length > 0 })
        }
        #expect(LinkPresentation.hiddenSyntax(in: text, selection: ns.range(of: "alias")).isEmpty)
        let literal = "---\nkey: [[metadata]]\n---\n`[code](url)`\n```\n[[fenced]]\n```\n$[[math]]$\n![[embed]]\n\\[[escaped]]"
        #expect(LinkPresentation.hiddenSyntax(in: literal, selection: NSRange(location: (literal as NSString).length, length: 0)).isEmpty)
    }

    @Test func mixedMarkersHidePerFormatAndRevealOnActiveLines() {
        let md = "## Title\n\nSome **bold** and *italic* and ~~gone~~.\n\n`**code**` $**x**$\n\nEnd"
        let ns = md as NSString
        let end = NSRange(location: ns.length, length: 0)
        let hidden = { (elements: Set<MixedElement>, selection: NSRange) in
            MarkerPresentation.hiddenSyntax(in: md, selection: selection, latex: false, elements: elements)
                .map { ns.substring(with: $0) }
        }
        #expect(hidden([.math, .links], end).isEmpty)
        #expect(hidden([.headings], end) == ["## "])
        #expect(hidden([.emphasis], end) == ["**", "**", "*", "*", "~~", "~~"])
        #expect(hidden([.headings, .emphasis], ns.range(of: "italic")) == ["## "])

        let tex = "\\section{Intro}\nAn \\emph{idea} and \\textbf{claim}.\n% \\emph{comment}\n\nEnd"
        let ts = tex as NSString
        let texHidden = MarkerPresentation.hiddenSyntax(in: tex, selection: NSRange(location: ts.length, length: 0),
                                                        latex: true, elements: [.headings, .emphasis]).map { ts.substring(with: $0) }
        #expect(texHidden == ["\\section{", "}", "\\emph{", "}", "\\textbf{", "}"])
        #expect(MixedElement.available(latex: true, text: tex) == [.math, .headings, .emphasis])
    }

    @Test func mixedHidesLaTeXFacesAndStarredSectionsWithNestedBraces() {
        let tex = "\\section*{Preface}\n\\paragraph{Aside} A \\textsc{nasa} and \\texttt{ls} and \\underline{this} "
            + "and \\textsf{sans}, \\textup{up}, \\textmd{md}.\n\\emph{a {b} c} and \\textbf{x {y}}.\n"
            + "$\\textsc{m}$ % \\underline{note}\n\nEnd"
        let ts = tex as NSString
        let hidden = { (selection: NSRange) in
            MarkerPresentation.hiddenSyntax(in: tex, selection: selection, latex: true, elements: [.headings, .emphasis])
                .map { ts.substring(with: $0) }
        }
        #expect(hidden(NSRange(location: ts.length, length: 0)) == [
            "\\section*{", "}", "\\paragraph{", "}", "\\emph{", "}", "\\textbf{", "}",
            "\\textsc{", "}", "\\texttt{", "}", "\\underline{", "}", "\\textsf{", "}", "\\textup{", "}", "\\textmd{", "}",
        ])
        // The caret's line shows its source; the rest stay hidden.
        let onFaces = hidden(ts.range(of: "nasa"))
        #expect(onFaces == ["\\section*{", "}", "\\emph{", "}", "\\textbf{", "}"])
        #expect(hidden(ts.range(of: "{b}")) == ["\\section*{", "}", "\\paragraph{", "}", "\\textsc{", "}", "\\texttt{", "}",
                                               "\\underline{", "}", "\\textsf{", "}", "\\textup{", "}", "\\textmd{", "}"])
    }

    @Test func extensionGroupsAppearOnlyWhenUsed() {
        let plain = MixedElement.available(latex: false, text: "Just prose.")
        #expect(!plain.contains(.footnotes) && !plain.contains(.citations) && !plain.contains(.comments))
        #expect(plain.contains(.tables) && plain.contains(.blocks) && plain.contains(.code))
        let rich = MixedElement.available(latex: false, text: "See [@smith2020].[^1] ==key== %%note%%\n\n[^1]: Note.")
        #expect(rich.contains(.footnotes) && rich.contains(.citations) && rich.contains(.comments))
        #expect(!MixedElement.available(latex: false, text: "Mail me at a@b.com").contains(.citations))
    }

    @Test func mixedHidesCodeCommentsFootnotesAndCitationMarkers() {
        let md = "Run `make` now. ==Key== idea %%hidden%%.[^1]\n\nAs [@smith2020, p. 4] and @jones says.\n\n<!-- one\ntwo -->\n\nEnd"
        let ns = md as NSString
        let hidden = MarkerPresentation.hiddenSyntax(in: md, selection: NSRange(location: ns.length, length: 0), latex: false,
                                                     elements: [.code, .comments, .footnotes, .citations])
            .map { ns.substring(with: $0) }
        #expect(hidden == ["`", "`", "==", "==", "%%hidden%%", "<!-- one", "two -->", "@", "@"])
    }

    @Test func mixedHidesCriticMarkupBracesAndKeepsThemFromStrikeAndHighlight() {
        let md = "A {++new++} {--old--} {~~was~>is~~} {==see==}{>>why<<} and ~~struck~~ ==lit==.\n\nEnd"
        let ns = md as NSString
        let hidden = MarkerPresentation.hiddenSyntax(in: md, selection: NSRange(location: ns.length, length: 0), latex: false,
                                                     elements: [.critic, .emphasis, .comments])
            .map { ns.substring(with: $0) }
        #expect(hidden == ["~~", "~~", "==", "==", "{++", "++}", "{--", "--}", "{~~", "~~}", "~>", "{==", "==}", "{>>", "<<}"])
        #expect(MarkerPresentation.hiddenSyntax(in: md, selection: ns.range(of: "new"), latex: false, elements: [.critic]).isEmpty)
    }

    @Test func admonitionsAndCriticMarkupAppearOnlyWhenUsed() {
        let plain = MixedElement.available(latex: false, text: "Just prose. !!! not one")
        #expect(!plain.contains(.admonitions) && !plain.contains(.critic))
        let rich = MixedElement.available(latex: false, text: "!!! note\n    Body.\n\nA {>>comment<<}.")
        #expect(rich.contains(.admonitions) && rich.contains(.critic))
    }

    @Test func mixedDrawsAdmonitionsWholeUntilAnyLineIsEdited() {
        let model = WorkspaceModel(); model.renderMode = .mixed
        let config = EditorConfig(prefs: model.prefs, model: model)
        let md = "!!! tip \"Try this\"\n    First line.\n\n\tSecond.\n\nAfter."
        let ns = md as NSString
        let decor = MixedPresentation.layout(in: md, selection: NSRange(location: ns.length, length: 0), config: config,
                                             elements: [.admonitions], width: 600)
        #expect(decor.glyphs.map(\.range) == [NSRange(location: 0, length: ns.range(of: "Second.").upperBound)])
        #expect(decor.glyphs.first?.reservesHeight == true)
        #expect((decor.glyphs.first?.image.size.height ?? 0) > config.fontSize * 3)
        for line in ["!!!", "First", "Second"] {
            let editing = MixedPresentation.layout(in: md, selection: ns.range(of: line), config: config, elements: [.admonitions], width: 600)
            #expect(editing.glyphs.isEmpty)
        }
        let note = MixedPresentation.Admonition(MarkdownStyler.admonition.firstMatch(in: md, range: NSRange(location: 0, length: ns.length))!, in: ns)
        #expect(note.kind == "tip" && note.title == "Try this" && note.paragraphs == ["First line.", "Second."])
    }

    @Test func mixedNumbersFootnotesAndRevealsOnlyTheEditedLine() {
        let model = WorkspaceModel(); model.renderMode = .mixed
        let config = EditorConfig(prefs: model.prefs, model: model)
        let md = "One.[^b] Two.[^a] Again.[^b] Lost.[^none]\n\n[^a]: First note.\n    More of it.\n\n[^b]: Second note.\n\n[^unused]: Spare.\n\n`[^b]`"
        let ns = md as NSString
        let protected = MarkdownStyler.code.matches(in: md, range: NSRange(location: 0, length: ns.length)).map(\.range)
        #expect(MixedPresentation.footnoteNumbers(in: md, protected: protected) == ["b": 1, "a": 2, "unused": 3])
        let decor = MixedPresentation.layout(in: md, selection: NSRange(location: ns.length, length: 0), config: config,
                                             elements: [.footnotes], width: 600)
        #expect(decor.glyphs.map { ns.substring(with: $0.range) } == ["[^b]", "[^a]", "[^b]", "[^a]: ", "    ", "[^b]: ", "[^unused]: "])
        let editing = MixedPresentation.layout(in: md, selection: ns.range(of: "More"), config: config, elements: [.footnotes], width: 600)
        #expect(editing.glyphs.map { ns.substring(with: $0.range) } == ["[^b]", "[^a]", "[^b]", "[^a]: ", "[^b]: ", "[^unused]: "])
    }

    @Test func crossReferencesNumberLikePandocCrossref() {
        let md = "# Intro {#sec:intro}\n\n## Data {#sec:data}\n\n![A](a.png){#fig:a}\n\n![B](b.png){#fig:b}\n\n$$x$$ {#eq:x}\n\nSee @fig:b, [@fig:a; @fig:b], @Fig:a, @sec:data and @eq:x but not @fig:missing."
        let numbers = PandocSyntax.numbers(in: md)
        #expect(numbers == ["sec:intro": "1", "sec:data": "1.1", "fig:a": "1", "fig:b": "2", "eq:x": "1"])
        #expect(PandocSyntax.display(key: "Fig:a", number: "1") == "Fig.\u{00A0}1")
        let ns = md as NSString
        let hidden = MarkerPresentation.hiddenSyntax(in: md, selection: NSRange(location: 0, length: 0), latex: false, elements: [.citations])
            .map { ns.substring(with: $0) }
        // Labels vanish (except on the caret's line), all-reference brackets
        // go, and an unknown target reads as a citation key.
        #expect(hidden.filter { $0.contains("{#") } == [" {#sec:data}", "{#fig:a}", "{#fig:b}", " {#eq:x}"])
        #expect(hidden.contains("[") && hidden.contains("]"))
        #expect(hidden.filter { $0 == "@" }.count == 1)
    }

    @Test func tablesParseAlignmentEscapesAndCode() {
        let table = MarkdownTable("| Name | Value | Note |\n|:-----|------:|:----:|\n| a \\| b | `x|y` | **ok** |\n| c |")
        #expect(table?.header == ["Name", "Value", "Note"])
        #expect(table?.alignments == [.left, .right, .center])
        #expect(table?.rows == [["a | b", "`x|y`", "**ok**"], ["c"]])
        #expect(MarkdownTable("| not | a table |\n| just pipes |") == nil)
    }

    @Test func mixedDrawsBlocksReferencesAndTablesAwayFromTheCaret() {
        let md = "- item\n- [ ] task\n- [x] done\n\n> quoted\n> > nested\n\n---\n\nText\n---\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\n![F](f.png){#fig:f}\n\nSee @fig:f.\n\nEnd"
        let ns = md as NSString
        let model = WorkspaceModel()
        var config = EditorConfig(prefs: model.prefs, model: model)
        config.renderMode = .mixed
        let all = Set(MixedElement.allCases)
        let decor = MixedPresentation.layout(in: md, selection: NSRange(location: ns.length, length: 0), config: config, elements: all, width: 600)
        let drawn = decor.glyphs.map { ns.substring(with: $0.range) }
        #expect(drawn == ["-", "- [ ]", "- [x]", "> ", "> > ", "---", "| A | B |\n|---|---|\n| 1 | 2 |", "@fig:f"])
        #expect(decor.glyphs.compactMap(\.toggle).map { ns.substring(with: $0) } == ["[ ]", "[x]"])
        #expect(decor.quoteBars.map(\.depth) == [1, 2])
        #expect(decor.glyphs.first { $0.range.length > 20 }?.reservesHeight == true)
        // On the editing line every construct is source again.
        let onTask = MixedPresentation.layout(in: md, selection: ns.range(of: "task"), config: config, elements: all, width: 600)
        #expect(!onTask.glyphs.map { ns.substring(with: $0.range) }.contains("- [ ]"))
        #expect(MixedPresentation.layout(in: md, selection: NSRange(location: 0, length: 0), config: config, elements: [], width: 600).glyphs.isEmpty)
    }


    @Test func imageEmbedsResolveRemoteAndDocumentRelativeSources() {
        let remote = "https://substackcdn.com/image/fetch/$s_!4evp!,w_1456,c_limit,f_auto,q_auto:good,fl_progressive:steep/https%3A%2F%2Fsubstack-post-media.s3.amazonaws.com%2Fpublic%2Fimages%2F504042d6-e8ce-4830-9a80-d38b422b0805_2048x1138.png"
        let text = "Intro $x$\n\n![](\(remote))\n\n![Plot](figs/plot.png \"Title\")\n\n`![](code.png)`\n\\![](escaped.png)\n[link](page.md)"
        let embeds = ImagePresentation.embeds(in: text)
        #expect(embeds.map(\.source) == [remote, "figs/plot.png"])
        #expect(embeds[0].range == (text as NSString).range(of: "![](\(remote))"))
        let directory = URL(fileURLWithPath: "/tmp/terso-doc", isDirectory: true)
        #expect(ImagePresentation.url(for: remote, directory: nil)?.absoluteString == remote)
        #expect(ImagePresentation.url(for: "figs/plot.png", directory: directory)?.lastPathComponent == "plot.png")
        #expect(ImagePresentation.url(for: "../secret.png", directory: directory) == nil)
        #expect(ImagePresentation.url(for: "/etc/secret.png", directory: directory) == nil)
        #expect(ImagePresentation.url(for: "file:///etc/secret.png", directory: directory) == nil)
        #expect(ImagePresentation.url(for: "figs/plot.png", directory: nil) == nil)
        let tall = NSImage(size: NSSize(width: 2048, height: 1138))
        let fitted = InlineImageLoader.fitted(tall, width: 708)
        #expect(fitted.size.width == 700)
        #expect(tall.size.width == 2048)
    }

    @Test func selectingMathRestoresSourceAndModesKeepUndo() async throws {
        let model = WorkspaceModel()
        let text = "# Heading\n\nA **bold** *italic* ~~struck~~ [link](https://example.com) [[Note|alias]] result $x_i$ here.\n\nElsewhere"
        let coordinator = EditorCoordinator(model: model, text: .constant(text))
        let storage = NSTextStorage(string: text)
        let layout = MathLayoutManager(); storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 700, height: 2000)); layout.addTextContainer(container)
        let tv = TersoTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), textContainer: container)
        tv.allowsUndo = true
        let window = NSWindow(contentRect: tv.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = tv
        defer { window.close() }
        coordinator.textView = tv; model.editor = coordinator; tv.delegate = coordinator; storage.delegate = coordinator
        // Heading and emphasis markers stay as styled source when not chosen.
        var config = EditorConfig(prefs: model.prefs, model: model)
        config.mixedRendered = [.math, .images, .links]
        coordinator.applyConfig(config, force: true)
        await coordinator.mathTask?.value
        #expect(layout.rendered.count == 1)
        let math = (text as NSString).range(of: "$x_i$")
        // Markdown keeps its styled source on both active and inactive lines,
        // while links hide their syntax and math substitutes rendered glyphs.
        for caret in [0, (text as NSString).range(of: "bold").location, (text as NSString).length] {
            tv.setSelectedRange(NSRange(location: caret, length: 0))
            coordinator.updateMathPresentation()
            await coordinator.mathTask?.value
            layout.ensureLayout(for: container)
            for marker in ["#", "**", "*italic*", "~~"] {
                let range = (text as NSString).range(of: marker)
                for index in range.location..<range.upperBound {
                    let glyph = layout.glyphIndexForCharacter(at: index)
                    #expect(!layout.propertyForGlyph(at: glyph).contains(.null))
                }
            }
            for marker in ["](https://example.com)", "[[Note|"] {
                let index = (text as NSString).range(of: marker).location
                let glyph = layout.glyphIndexForCharacter(at: index)
                #expect(layout.propertyForGlyph(at: glyph).contains(.null) == (caret != (text as NSString).range(of: "bold").location))
            }
            #expect(storage.string == text)
        }
        #expect(layout.rendered.count == 1)
        tv.setSelectedRange(NSRange(location: math.location + 2, length: 0))
        coordinator.updateMathPresentation()
        await coordinator.mathTask?.value
        #expect(layout.rendered.isEmpty)
        #expect(tv.string == text)
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        coordinator.updateMathPresentation()
        await coordinator.mathTask?.value
        #expect(layout.rendered.count == 1)
        let selection = tv.selectedRange()
        for mode in [RenderMode.source, .preview, .mixed] {
            model.renderMode = mode
            coordinator.applyConfig(EditorConfig(prefs: model.prefs, model: model), force: false)
            await coordinator.mathTask?.value
            #expect(tv.string == text)
            #expect(tv.selectedRange() == selection)
        }
        coordinator.replace(TextSpan(location: math.location + 1, length: 1), with: "y", actionName: "Edit formula")
        #expect(tv.string.contains("$y_i$"))
        #expect(!tv.string.contains("\u{fffc}"))
        let undo = try #require(tv.undoManager)
        #expect(undo.canUndo)
        model.renderMode = .source
        coordinator.applyConfig(EditorConfig(prefs: model.prefs, model: model), force: false)
        undo.undo()
        #expect(tv.string == text)
        coordinator.mathTask?.cancel()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TERSO_TEST_TECTONIC"] == "1"))
    func tectonicCompilesUnsavedSource() async throws {
        let compiler = TectonicPreviewModel()
        await compiler.compile(source: #"\documentclass{article}\begin{document}A result $x_i^2$.\end{document}"#, fileURL: nil, onlyCached: false)
        #expect(compiler.pdf?.starts(with: Data("%PDF".utf8)) == true, "\(compiler.error ?? "") \(compiler.log)")
        #expect(!compiler.running)
        await compiler.compile(source: #"\documentclass{article}\begin{document}Cached $x_i$.\end{document}"#, fileURL: nil)
        #expect(compiler.pdf != nil, "\(compiler.error ?? "") \(compiler.log)")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "Included text.".write(to: directory.appendingPathComponent("section.tex"), atomically: true, encoding: .utf8)
        await compiler.compile(source: #"\documentclass{article}\begin{document}\input{section}\end{document}"#,
                               fileURL: directory.appendingPathComponent("main.tex"))
        #expect(compiler.pdf != nil, "\(compiler.error ?? "") \(compiler.log)")
    }
}
