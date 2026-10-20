// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
import WebKit
@testable import TersoApp

@Suite @MainActor struct MarkdownFlavourTests {
    static let source = "# Title\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\n~~gone~~ ==key== $x^2$ https://example.com [[Note|alias]] %%hidden%%\n\n"
        + "- [x] done\n\n> [!NOTE]\n> Heads up.\n\n> [!tip]- Folded tip\n> Inside.\n\n!!! warning\n    Careful.\n\n"
        + "Claim.[^1] {++added++}\n\n[^1]: The note.\n"

    private func render(_ flavour: MarkdownFlavour) async throws -> WKWebView {
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 700, height: 800))
        web.loadHTMLString(MarkdownPreviewHTML.document(source: Self.source, dark: false, fontSize: 18, flavour: flavour), baseURL: nil)
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if (try? await web.evaluateJavaScript("document.querySelector('h1') !== null")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        return web
    }

    private func count(_ web: WKWebView, _ selector: String) async throws -> Int {
        try await web.evaluateJavaScript("document.querySelectorAll(\"\(selector)\").length") as? Int ?? -1
    }

    private func marked(_ web: WKWebView) async throws -> [String: Int] {
        try await web.evaluateJavaScript("""
            const counts={}; document.querySelectorAll('.unrendered').forEach(el => counts[el.dataset.feature]=(counts[el.dataset.feature]||0)+1); counts
            """) as? [String: Int] ?? [:]
    }

    @Test func githubRendersAlertsAndMarksWhatItLeavesAsTyped() async throws {
        let web = try await render(.github)
        #expect(try await count(web, "table") == 1)
        #expect(try await count(web, "del") == 1)
        #expect(try await count(web, "input[type=checkbox]") == 1)
        #expect(try await count(web, ".katex") == 1)
        #expect(try await count(web, "sup.footnote-ref") == 1)
        #expect(try await count(web, "div.alert.note") == 1)
        #expect(try await count(web, "details.alert, mark, .wikilink, div.admonition.warning, ins.critic") == 0)
        // GitHub has no folded or custom callouts, so that one is marked rather than drawn as a quote.
        #expect(try await marked(web) == ["highlights": 1, "wikiLinks": 1, "comments": 1, "alerts": 1, "admonitions": 1, "critic": 1])
        #expect(try await web.evaluateJavaScript("document.querySelector('.unrendered[data-feature=alerts]').textContent") as? String
                == "> [!tip]- Folded tip\n> Inside.")
        #expect(try await web.evaluateJavaScript("document.querySelector('.unrendered[data-feature=highlights]').title") as? String
                == "GitHub doesn't render highlights")
        #expect(try await web.evaluateJavaScript("document.querySelector('.unrendered[data-feature=alerts]').title") as? String
                == "GitHub doesn't render this kind of callout")
        // A marked passage still leads back to its source.
        let offset = try await web.evaluateJavaScript("Number(document.querySelector('.unrendered[data-feature=admonitions]').closest('[data-source]').dataset.source)") as? Int
        #expect(offset == (Self.source as NSString).range(of: "!!! warning").location)
    }

    @Test func obsidianFoldsCalloutsAndHidesComments() async throws {
        let web = try await render(.obsidian)
        #expect(try await count(web, "details.alert.tip:not([open])") == 1)
        #expect(try await web.evaluateJavaScript("document.querySelector('details.alert.tip summary').textContent") as? String == "Folded tip")
        #expect(try await web.evaluateJavaScript("document.querySelector('.wikilink').textContent") as? String == "alias")
        #expect(try await count(web, "mark") == 1)
        let text = try await web.evaluateJavaScript("document.getElementById('document').textContent") as? String ?? ""
        #expect(!text.contains("hidden"))
        #expect(try await marked(web) == ["admonitions": 1, "critic": 1])
    }

    @Test func mkdocsKeepsTablesAndMarksEverythingElse() async throws {
        let web = try await render(.mkdocs)
        #expect(try await count(web, "table") == 1)
        #expect(try await count(web, "del, mark, .katex, .alert, .admonition, sup.footnote-ref, input, a[href^=http], .footnotes") == 0)
        #expect(try await marked(web) == ["strikethrough": 1, "highlights": 1, "math": 1, "autolinks": 1, "wikiLinks": 1,
                                          "comments": 1, "taskLists": 1, "alerts": 2, "admonitions": 1, "footnotes": 2, "critic": 1])
        #expect(try await web.evaluateJavaScript("document.querySelector('.unrendered[data-feature=math]').textContent") as? String == "$x^2$")
        #expect(try await web.evaluateJavaScript("document.querySelector('.unrendered[data-feature=autolinks]').textContent") as? String
                == "https://example.com")
    }

    @Test func materialMatchesItsRecommendedExtensions() async throws {
        let web = try await render(.material)
        #expect(try await count(web, "div.admonition.warning") == 1)
        #expect(try await count(web, "mark") == 1)
        #expect(try await count(web, "ins.critic") == 1)
        #expect(try await count(web, ".katex") == 1)
        #expect(try await count(web, "div.alert, .wikilink") == 0)
        #expect(try await marked(web) == ["alerts": 2, "wikiLinks": 1, "comments": 1, "autolinks": 1])
    }

    @Test func commonMarkTurnsOffGFM() async throws {
        let web = try await render(.commonMark)
        #expect(try await count(web, "table, del, input, .katex, sup.footnote-ref") == 0)
        #expect(try await count(web, "h1") == 1)
        #expect(try await marked(web)["tables"] == 1)
    }

    @Test func tersoMarksNothingAndExportIsUnchanged() async throws {
        let web = try await render(.terso)
        #expect(try await marked(web).isEmpty)
    }

    @Test func revealCyclesThroughOneKind() async throws {
        let web = try await render(.mkdocs)
        func reveal(_ feature: String) async throws -> [Int]? { try await web.evaluateJavaScript("tersoReveal('\(feature)')") as? [Int] }
        #expect(try await reveal("footnotes") == [1, 2])
        #expect(try await reveal("footnotes") == [2, 2])
        #expect(try await reveal("footnotes") == [1, 2])
        #expect(try await reveal("math") == [1, 1])
        #expect(try await reveal("tables") == [0, 0])
        #expect(try await count(web, ".unrendered.reveal") == 1)
    }

    // MARK: Detection

    private func folder(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("flavour-\(UUID().uuidString)")
        for (path, contents) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if path.hasSuffix("/") { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
            else { try contents.write(to: url, atomically: true, encoding: .utf8) }
        }
        return root
    }

    @Test func detectsDocsSitesVaultsAndRemotes() throws {
        let site = try folder(["mkdocs.yml": "site_name: X\ntheme:\n  # the look\n  name: 'material'\n",
                               "docs/guide/page.md": "", "README.md": "",
                               ".git/config": "[remote \"origin\"]\n\turl = git@github.com:me/site.git\n"])
        defer { try? FileManager.default.removeItem(at: site) }
        #expect(FlavourDetection.detect(for: site.appendingPathComponent("docs/guide/page.md"))
                == FlavourDetection(flavour: .material, reason: "mkdocs.yml with Material"))
        // A README beside mkdocs.yml is outside docs_dir: GitHub shows it.
        #expect(FlavourDetection.detect(for: site.appendingPathComponent("README.md"))?.flavour == .github)

        let plain = try folder(["mkdocs.yaml": "docs_dir: 'pages/' # source\ntheme: readthedocs\n", "pages/a.md": ""])
        defer { try? FileManager.default.removeItem(at: plain) }
        #expect(FlavourDetection.detect(for: plain.appendingPathComponent("pages/a.md"))?.flavour == .mkdocs)

        let proper = try folder(["properdocs.yml": "site_name: P\n", "docs/a.md": ""])
        defer { try? FileManager.default.removeItem(at: proper) }
        #expect(FlavourDetection.detect(for: proper.appendingPathComponent("docs/a.md"))?.flavour == .properdocs)

        let vault = try folder([".obsidian/": "", "Daily/today.md": ""])
        defer { try? FileManager.default.removeItem(at: vault) }
        #expect(FlavourDetection.detect(for: vault.appendingPathComponent("Daily/today.md"))
                == FlavourDetection(flavour: .obsidian, reason: "Obsidian vault"))

        // The nearest folder decides: a repository without a known host stops the search.
        let nested = try folder([".obsidian/": "", "code/.git/config": "[core]\n", "code/notes.md": "",
                                 "lab/.git/config": "[remote \"origin\"]\n\turl = https://gitlab.example.org/x.git\n", "lab/n.md": ""])
        defer { try? FileManager.default.removeItem(at: nested) }
        #expect(FlavourDetection.detect(for: nested.appendingPathComponent("code/notes.md")) == nil)
        #expect(FlavourDetection.detect(for: nested.appendingPathComponent("lab/n.md"))?.flavour == .gitlab)
    }

    @Test func materialThemeIsReadFromEitherForm() {
        #expect(FlavourDetection.usesMaterial("theme: material\n"))
        #expect(FlavourDetection.usesMaterial("theme:\n  features:\n    - navigation.tabs\n\n  name: \"material\"\n"))
        #expect(!FlavourDetection.usesMaterial("theme:\n  name: readthedocs\nextra:\n  name: material\n"))
        #expect(!FlavourDetection.usesMaterial("site_name: material\n"))
        #expect(FlavourDetection.docsDirectory(in: "site_name: x\n") == "docs")
        #expect(FlavourDetection.docsDirectory(in: "docs_dir: src/docs/\n") == "src/docs")
    }

    @Test func choiceWinsOverDetectionAndDefaults() throws {
        let defaults = try #require(UserDefaults(suiteName: "MarkdownFlavourTests"))
        defer { defaults.removePersistentDomain(forName: "MarkdownFlavourTests") }
        let url = URL(fileURLWithPath: "/tmp/notes/readme.md")
        let flavours = MarkdownFlavours(defaults: defaults)
        #expect(flavours.flavour(for: url) == nil)
        #expect(flavours.standard == .terso)
        flavours.choose(.gitlab, for: url)
        flavours.standard = .obsidian
        let reopened = MarkdownFlavours(defaults: defaults)
        #expect(reopened.flavour(for: URL(fileURLWithPath: "/tmp/notes/./readme.md")) == .gitlab)
        #expect(reopened.standard == .obsidian)
        reopened.choose(nil, for: url)
        #expect(MarkdownFlavours(defaults: defaults).flavour(for: url) == nil)

        let model = WorkspaceModel()
        model.chosenFlavour = .material
        #expect(model.markdownFlavour == .material)
        model.chosenFlavour = nil
        #expect(model.markdownFlavour == model.automaticFlavour)
    }

    // MARK: Conversion

    private func converted(_ text: String, _ flavour: MarkdownFlavour) -> String {
        guard let change = MarkdownConversion.replacement(for: MarkdownConversion.edits(in: text, to: flavour), in: text) else { return text }
        return (text as NSString).replacingCharacters(in: change.range, with: change.text)
    }

    @Test func admonitionsBecomeCalloutsAndBack() {
        let admonition = "Intro.\n\n!!! warning \"Mind the gap\"\n    Body.\n\n    More.\n\nAfter."
        #expect(converted(admonition, .github) == "Intro.\n\n> [!WARNING]\n> **Mind the gap**\n> Body.\n>\n> More.\n\nAfter.")
        #expect(converted(admonition, .gitlab) == "Intro.\n\n> [!WARNING] Mind the gap\n> Body.\n>\n> More.\n\nAfter.")
        #expect(converted("???+ tip\n    Open", .obsidian) == "> [!tip]+\n> Open")
        #expect(converted("!!! bug\n    Ouch", .github) == "> [!CAUTION]\n> Ouch")
        #expect(converted("> [!CAUTION]\n> Hot.\n\nNext", .material) == "!!! danger\n    Hot.\n\nNext")
        #expect(converted("> [!note]- Later \"on\"\n> x\n>\n> y", .material) == "??? note \"Later 'on'\"\n    x\n\n    y")
        // A callout GitHub can't draw is put in GitHub's form; one it can is left alone.
        #expect(converted("> [!tip]- Folded tip\n> Inside.", .github) == "> [!TIP]\n> **Folded tip**\n> Inside.")
        #expect(converted("> [!NOTE]\n> Fine.", .github) == "> [!NOTE]\n> Fine.")
        #expect(MarkdownConversion.edits(in: admonition, to: .material).isEmpty)
        #expect(MarkdownConversion.edits(in: admonition, to: .terso).isEmpty)
    }

    @Test func conversionKeepsLineEndingsAndLeavesCodeAlone() {
        #expect(converted("!!! note\r\n    Body\r\nAfter", .github) == "> [!NOTE]\r\n> Body\r\nAfter")
        let fenced = "```\n!!! note\n    Body\n```\n\n`%%x%%` and $a [[b]]$ and %%y%%"
        #expect(converted(fenced, .github) == "```\n!!! note\n    Body\n```\n\n`%%x%%` and $a [[b]]$ and <!--y-->")
        #expect(converted("%%a -- b%%", .github) == "%%a -- b%%")
    }

    @Test func wikiLinksBecomeLinks() {
        #expect(converted("[[My Note#Part One|see]] ![[pic.png]] ![[Other]] [[Plain]] [[#Local]]", .github)
                == "[see](My%20Note.md#part-one) ![](pic.png) ![[Other]] [Plain](Plain.md) [Local](#local)")
    }

    @Test func pythonMarkdownGetsHTMLForHighlightsAndStrikethrough() {
        #expect(converted("==a== ~~b~~ {==c==} {~~d~>e~~}", .mkdocs) == "<mark>a</mark> <del>b</del> {==c==} {~~d~>e~~}")
        // GitHub may not keep <mark>, so highlights stay for the writer to decide.
        #expect(converted("==a==", .github) == "==a==")
    }

    @Test func summaryNamesEachRewrite() {
        let edits = MarkdownConversion.edits(in: "!!! note\n    a\n\n!!! tip\n    b\n\n[[X]]", to: .github)
        #expect(MarkdownConversion.summary(of: edits, for: .github) == "2 admonitions as callouts and 1 wiki link as a link")
        #expect(MarkdownConversion.replacement(for: [], in: "") == nil)
    }
}

@Suite(.serialized) @MainActor struct MarkdownConversionEditorTests {
    @Test func convertIsOneUndoableEditFromPreview() async throws {
        _ = NSApplication.shared
        let document = TabDocument(), workspace = TabWorkspace()
        defer { document.close(); workspace.close() }
        let original = "# Notes\n\n!!! tip \"Speed\"\n    Twice as fast.\n\nSee [[Benchmarks]] %%todo%%.\n"
        document.contents.text = original
        workspace.insert(document)
        let host = document.hostedEditor()
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        host.layoutSubtreeIfNeeded()
        let deadline = ContinuousClock.now + .seconds(3)
        while document.model.editor == nil && ContinuousClock.now < deadline { await Task.yield() }
        _ = try #require(document.model.editor)
        let undo = try #require(document.undoManager)
        document.model.renderMode = .preview
        document.model.convertMarkdown(to: .github)
        try await Task.sleep(for: .milliseconds(50))
        #expect(document.contents.text == "# Notes\n\n> [!TIP]\n> **Speed**\n> Twice as fast.\n\nSee [Benchmarks](Benchmarks.md) <!--todo-->.\n")
        #expect(undo.undoActionName == "Convert for GitHub")
        undo.undo()
        try await Task.sleep(for: .milliseconds(50))
        #expect(document.contents.text == original)
        // Nothing to convert leaves the document and its undo stack alone.
        document.model.convertMarkdown(to: .terso)
        #expect(!undo.canUndo || undo.undoActionName != "Convert for Terso")
    }
}


@Suite @MainActor struct MixedFlavourTests {
    static let text = "==key== ~~gone~~ [[Note|alias]] [site](https://x.org) %%draft%% <!-- aside --> {++add++}\n\n"
        + "- [x] done\n\n!!! tip\n    Body.\n\n> [!tip]- Folded\n> In.\n\n> [!NOTE]\n> Fine.\n\nClaim.[^1] $x$\n\n[^1]: Note.\n\n`==code==`\n"

    private func marked(_ flavour: MarkdownFlavour) -> [MarkdownFeature: [String]] {
        let ns = Self.text as NSString
        return Dictionary(grouping: MarkdownCompatibility.marks(in: Self.text, flavour: flavour), by: \.feature)
            .mapValues { $0.map { ns.substring(with: $0.range) } }
    }

    @Test func marksWhatEachPlatformLeavesAsTyped() {
        #expect(marked(.terso).isEmpty)
        let github = marked(.github)
        #expect(github[.highlights] == ["==key=="])
        #expect(github[.wikiLinks] == ["[[Note|alias]]"])
        #expect(github[.comments] == ["%%draft%%"])
        #expect(github[.critic] == ["{++add++}"])
        #expect(github[.admonitions] == ["!!! tip\n    Body."])
        // Only the folded callout: GitHub renders the plain NOTE.
        #expect(github[.alerts] == ["> [!tip]- Folded\n> In."])
        #expect(github[.strikethrough] == nil && github[.math] == nil && github[.footnotes] == nil)
        let mkdocs = marked(.mkdocs)
        #expect(mkdocs[.strikethrough] == ["~~gone~~"])
        #expect(mkdocs[.taskLists] == ["[x]"])
        #expect(mkdocs[.math] == ["$x$"])
        #expect(mkdocs[.footnotes] == ["[^1]", "[^1]:"])
        #expect(mkdocs[.alerts]?.count == 2)
        // Code is never marked, and the link's URL is not a bare link.
        #expect(!mkdocs.values.joined().contains { $0.contains("code") })
        #expect(mkdocs[.autolinks] == nil)
        #expect(marked(.obsidian).keys.sorted(by: { $0.rawValue < $1.rawValue }) == [.admonitions, .critic])
        #expect(MarkdownCompatibility.marks(in: "See https://example.com/a.", flavour: .mkdocs).map(\.range.length) == [21])
    }

    @Test func mixedOffersOnlyWhatThePlatformRenders() {
        let terso = MixedElement.available(latex: false, text: Self.text)
        #expect([.admonitions, .critic, .footnotes, .math, .comments].allSatisfy(terso.contains))
        let github = MixedElement.available(latex: false, text: Self.text, flavour: .github)
        #expect(!github.contains(.admonitions) && !github.contains(.critic))
        #expect(github.contains(.footnotes) && github.contains(.math) && github.contains(.comments))
        let mkdocs = MixedElement.available(latex: false, text: Self.text, flavour: .mkdocs)
        #expect(!mkdocs.contains(.math) && !mkdocs.contains(.footnotes) && mkdocs.contains(.tables) == true)
        // LaTeX ignores Markdown flavours.
        #expect(MixedElement.available(latex: true, text: "\\documentclass{article}", flavour: .commonMark).contains(.math))
    }

    @Test func mixedHidesOnlyMarkersThePlatformUses() {
        let ns = Self.text as NSString
        let away = NSRange(location: ns.length, length: 0)
        func hides(_ token: String, _ flavour: MarkdownFlavour) -> Bool {
            let hidden = MarkerPresentation.hiddenSyntax(in: Self.text, selection: away, latex: false,
                                                         elements: Set(MixedElement.allCases), flavour: flavour)
                + LinkPresentation.hiddenSyntax(in: Self.text, selection: away, flavour: flavour)
            let range = ns.range(of: token)
            return hidden.contains { NSIntersectionRange($0, range).length > 0 }
        }
        #expect(hides("==key==", .terso) && !hides("==key==", .github))
        #expect(hides("%%draft%%", .obsidian) && !hides("%%draft%%", .github))
        #expect(hides("<!-- aside -->", .github))
        #expect(hides("~~gone~~", .github) && !hides("~~gone~~", .mkdocs))
        #expect(hides("[[Note|", .obsidian) && !hides("[[Note|", .github))
        #expect(hides("](https://x.org)", .github))
    }

    @Test func taskBoxesStayTypedWithoutTaskLists() {
        let model = WorkspaceModel()
        var config = EditorConfig(prefs: model.prefs, model: model)
        func toggles() -> Int {
            // The caret sits on the blank last line, away from both tasks.
            MixedPresentation.layout(in: "- [x] done\n- [ ] todo\n\n", selection: NSRange(location: 23, length: 0), config: config,
                                     elements: [.blocks], width: 600).glyphs.filter { $0.toggle != nil }.count
        }
        config.flavour = .github
        #expect(toggles() == 2)
        config.flavour = .mkdocs
        #expect(toggles() == 0)
    }

    @Test func calloutsDrawAsThePlatformRendersThem() {
        let model = WorkspaceModel()
        var config = EditorConfig(prefs: model.prefs, model: model)
        let text = "> [!tip]- Folded\n> In.\n\n> [!NOTE]\n> Fine.\n\nEnd.\n"
        let ns = text as NSString
        func drawn(_ flavour: MarkdownFlavour, caret: Int = ns.length) -> [String] {
            config.flavour = flavour
            return MixedPresentation.layout(in: text, selection: NSRange(location: caret, length: 0), config: config,
                                            elements: [.blocks], width: 600).glyphs
                .map { ns.substring(with: $0.range) }.filter { $0.contains("[!") }
        }
        #expect(drawn(.github) == ["> [!NOTE]\n> Fine."])
        #expect(drawn(.obsidian) == ["> [!tip]- Folded\n> In.", "> [!NOTE]\n> Fine."])
        #expect(drawn(.mkdocs).isEmpty)
        // The caret on any line of a callout shows the whole of it as source.
        #expect(drawn(.obsidian, caret: ns.range(of: "In.").location) == ["> [!NOTE]\n> Fine."])
        // One left as typed keeps its quote bars.
        config.flavour = .github
        let bars = MixedPresentation.layout(in: text, selection: NSRange(location: ns.length, length: 0), config: config,
                                            elements: [.blocks], width: 600).quoteBars
        #expect(bars.map { ns.substring(with: $0.range) } == ["> [!tip]- Folded", "> In."])
        // Titles and folds read as the admonition's.
        let blocks = MarkdownConversion.callouts(in: ns, fences: [])
        let folded = MixedPresentation.Admonition(blocks[0]), note = MixedPresentation.Admonition(blocks[1])
        #expect(folded.title == "Folded" && folded.fold == "???" && folded.tone == .systemGreen)
        #expect(note.title == "Note" && note.fold == "!!!" && note.paragraphs == ["Fine."])
    }
}

@Suite(.serialized) @MainActor struct MixedFlavourEditorTests {
    @Test func mixedMarksUnrenderedSyntaxAndExplainsItOnHover() async throws {
        _ = NSApplication.shared
        let document = TabDocument(), workspace = TabWorkspace()
        defer { document.close(); workspace.close() }
        document.contents.text = "# Notes\n\nNow ==twice as fast== and [[Bench]].\n"
        document.model.renderMode = .mixed
        document.model.chosenFlavour = .github
        workspace.insert(document)
        let host = document.hostedEditor()
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        host.layoutSubtreeIfNeeded()
        let deadline = ContinuousClock.now + .seconds(3)
        while document.model.editor == nil && ContinuousClock.now < deadline { await Task.yield() }
        let editor = try #require(document.model.editor as? EditorCoordinator)
        let tv = try #require(editor.textView)
        let layout = try #require(tv.layoutManager as? MathLayoutManager)
        editor.updateMathPresentation()
        #expect(layout.flavourMarks.map(\.feature) == [.highlights, .wikiLinks])
        let index = (tv.string as NSString).range(of: "twice").location
        #expect(layout.temporaryAttribute(.underlineColor, atCharacterIndex: index, effectiveRange: nil) != nil)
        editor.handleHover(at: index)
        #expect(tv.toolTip == "GitHub doesn't render highlights; it's published as typed")
        editor.handleHover(at: 0)
        #expect(tv.toolTip == nil)
        // Back to Terso: nothing is marked.
        document.model.chosenFlavour = .terso
        editor.config?.flavour = .terso
        editor.updateMathPresentation()
        #expect(layout.flavourMarks.isEmpty)
        #expect(layout.temporaryAttribute(.underlineColor, atCharacterIndex: index, effectiveRange: nil) == nil)
    }
}
