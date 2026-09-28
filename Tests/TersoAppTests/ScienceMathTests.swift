// SPDX-License-Identifier: AGPL-3.0-only
import Testing
import WebKit
@testable import TersoApp

@Suite @MainActor struct ScienceMathTests {
    @Test func bundledRendererTypesetsMathAndEscapesSource() async throws {
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 260, height: 200))
        let source = #"A result $\frac{\alpha_i^2}{\sqrt{s}}$ <img src=x onerror='window.injected=true'>"#
        web.loadHTMLString(ScienceMathHTML.document(source: source, math: false, dark: false), baseURL: ScienceMathHTML.resourceURL)
        let deadline = ContinuousClock.now + .seconds(10)
        var rendered = false
        while ContinuousClock.now < deadline {
            rendered = (try? await web.evaluateJavaScript("document.querySelectorAll('.katex .mfrac').length > 0")) as? Bool ?? false
            if rendered { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(rendered)
        let images = try await web.evaluateJavaScript("document.querySelectorAll('img').length") as? Int
        #expect(images == 0)
        let text = try await web.evaluateJavaScript("document.getElementById('content').textContent") as? String
        #expect(text?.contains("<img src=x") == true)
        let errors = try await web.evaluateJavaScript("document.querySelectorAll('.katex-error').length") as? Int
        #expect(errors == 0)
    }

    @Test(arguments: [#"\sigma_i = \frac{g^2}{4\pi} \label{eq:sigma}"#, #"x_i &= 1 \\ y_i &= 2"#])
    func bareEquationRendersWithScripts(source: String) async throws {
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 240, height: 200))
        web.loadHTMLString(ScienceMathHTML.document(source: source, math: true, dark: true), baseURL: ScienceMathHTML.resourceURL)
        let deadline = ContinuousClock.now + .seconds(10)
        var rendered = false
        while ContinuousClock.now < deadline {
            rendered = (try? await web.evaluateJavaScript("document.querySelectorAll('.katex .msupsub').length > 0")) as? Bool ?? false
            if rendered { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(rendered)
        let errors = try await web.evaluateJavaScript("document.querySelectorAll('.katex-error').length") as? Int
        #expect(errors == 0)
    }
}
