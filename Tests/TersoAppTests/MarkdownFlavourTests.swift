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

    @Test func githubRendersAlertsButLeavesObsidianAndPythonSyntaxAsTyped() async throws {
        let web = try await render(.github)
        #expect(try await count(web, "table") == 1)
        #expect(try await count(web, "del") == 1)
        #expect(try await count(web, "input[type=checkbox]") == 1)
        #expect(try await count(web, ".katex") == 1)
        #expect(try await count(web, "sup.footnote-ref") == 1)
        #expect(try await count(web, "div.alert.note") == 1)
        // GitHub knows five kinds and no title or fold, so this stays a quote.
        #expect(try await count(web, "details.alert") == 0)
        #expect(try await count(web, "mark, .wikilink, div.admonition.warning, ins.critic") == 0)
        let text = try await web.evaluateJavaScript("document.getElementById('document').textContent") as? String ?? ""
        for typed in ["==key==", "[[Note|alias]]", "%%hidden%%", "!!! warning", "{++added++}"] { #expect(text.contains(typed)) }
    }

    @Test func obsidianFoldsCalloutsAndHidesComments() async throws {
        let web = try await render(.obsidian)
        #expect(try await count(web, "details.alert.tip:not([open])") == 1)
        #expect(try await web.evaluateJavaScript("document.querySelector('details.alert.tip summary').textContent") as? String == "Folded tip")
        #expect(try await web.evaluateJavaScript("document.querySelector('.wikilink').textContent") as? String == "alias")
        #expect(try await count(web, "mark") == 1)
        let text = try await web.evaluateJavaScript("document.getElementById('document').textContent") as? String ?? ""
        #expect(!text.contains("hidden"))
        #expect(text.contains("!!! warning"))
    }

    @Test func mkdocsKeepsOnlyTables() async throws {
        let web = try await render(.mkdocs)
        #expect(try await count(web, "table") == 1)
        #expect(try await count(web, "del, mark, .katex, .alert, .admonition, sup.footnote-ref, input, a[href^=http]") == 0)
        let text = try await web.evaluateJavaScript("document.getElementById('document').textContent") as? String ?? ""
        for typed in ["~~gone~~", "$x^2$", "[x] done", "[^1]"] { #expect(text.contains(typed)) }
    }

    @Test func materialMatchesItsRecommendedExtensions() async throws {
        let web = try await render(.material)
        #expect(try await count(web, "div.admonition.warning") == 1)
        #expect(try await count(web, "mark") == 1)
        #expect(try await count(web, "ins.critic") == 1)
        #expect(try await count(web, ".katex") == 1)
        #expect(try await count(web, ".alert, .wikilink") == 0)
    }

    @Test func commonMarkTurnsOffGFM() async throws {
        let web = try await render(.commonMark)
        #expect(try await count(web, "table, del, input, .katex, sup.footnote-ref") == 0)
        #expect(try await count(web, "h1") == 1)
    }

    @Test func unrenderedNamesSyntaxOutsideCode() {
        let text = "==key== and [[Note]]\n\n```\n!!! note\n```\n\n$x$"
        #expect(MarkdownFlavour.github.unrendered(in: text) == [.highlights, .wikiLinks])
        #expect(MarkdownFlavour.mkdocs.unrendered(in: text) == [.math, .highlights, .wikiLinks])
        #expect(MarkdownFlavour.terso.unrendered(in: text).isEmpty)
        // CriticMarkup deletions are not strikethrough.
        #expect(!MarkdownFlavour.mkdocs.unrendered(in: "{~~a~>b~~}").contains(.strikethrough))
    }

    @Test func documentFlavourFollowsTheFile() throws {
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
    }
}
