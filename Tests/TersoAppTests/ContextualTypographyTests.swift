// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import Testing
import WebKit
@testable import TersoApp

@Suite @MainActor struct ContextualTypographyTests {
    @Test func markdownPreviewUsesTypographyAndWritingWidth() async throws {
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 700))
        let html = MarkdownPreviewHTML.document(source: "A readable paragraph.", dark: false, fontSize: 20,
                                                fontFamily: EditorFont.georgia.previewCSSFamily,
                                                lineSpacing: 1.8, columnWidth: 600)
        web.loadHTMLString(html, baseURL: nil)
        let deadline = ContinuousClock.now + .seconds(10)
        var ready = false
        while !ready && ContinuousClock.now < deadline {
            ready = (try? await web.evaluateJavaScript("document.querySelector('main p') !== null")) as? Bool ?? false
            if !ready { try await Task.sleep(for: .milliseconds(20)) }
        }
        #expect(ready)
        let style = try await web.evaluateJavaScript("(() => { const b = getComputedStyle(document.body); const m = getComputedStyle(document.querySelector('main')); return [b.fontFamily, b.fontSize, b.lineHeight, m.maxWidth]; })()") as? [String]
        #expect(style == ["Georgia, serif", "20px", "36px", "600px"])
        web.stopLoading()
    }
}
