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
        layout.hiddenLinkSyntax = links
        layout.ensureLayout(for: container)

        // A surrogate pair shifts UTF-16 offsets by two without exposing any
        // unrelated source, even before the asynchronous renderer can run.
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "😀")
        #expect(layout.rendered.map(\.range) == math.map { NSRange(location: $0.location + 2, length: $0.length) })
        #expect(layout.rendered.allSatisfy { $0.image === image })
        #expect(layout.hiddenLinkSyntax == links.map { NSRange(location: $0.location + 2, length: $0.length) })
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
        for range in layout.hiddenLinkSyntax {
            let glyph = layout.glyphIndexForCharacter(at: range.location)
            #expect(layout.propertyForGlyph(at: glyph).contains(.null))
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
        coordinator.applyConfig(EditorConfig(prefs: model.prefs, model: model), force: true)
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
