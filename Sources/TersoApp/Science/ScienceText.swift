// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import WebKit

/// Local typesetting only; source text and editor ranges are never rewritten.
struct ScienceText: View {
    let source: String
    var math = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.mathMacros) private var macros
    @State private var height: CGFloat = 20

    init(_ source: String, math: Bool = false) {
        self.source = source
        self.math = math
    }

    var body: some View {
        if math || source.contains("\\") || source.contains("$") {
            ScienceMathView(source: source, math: math, dark: colorScheme == .dark, macros: macros, height: $height)
                .frame(height: height)
                .allowsHitTesting(false)
                .accessibilityLabel(source)
        } else {
            Text(source)
        }
    }
}

private struct ScienceMathView: NSViewRepresentable {
    let source: String
    let math: Bool
    let dark: Bool
    let macros: [String: String]
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(height: $height) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(context.coordinator, name: "size")
        let view = WKWebView(frame: .zero, configuration: config)
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        let key = "\(dark):\(math):\(source):\(MathPresentation.json(macros))"
        guard context.coordinator.key != key else { return }
        context.coordinator.key = key
        context.coordinator.height = $height
        let root = ScienceMathHTML.resourceURL
        view.loadHTMLString(ScienceMathHTML.document(source: source, math: math, dark: dark, macros: macros), baseURL: root)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "size")
        view.stopLoading()
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        var key = ""
        var height: Binding<CGFloat>
        init(height: Binding<CGFloat>) { self.height = height }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let value = message.body as? Double, value.isFinite else { return }
            let newHeight = max(20, ceil(value))
            if abs(height.wrappedValue - newHeight) > 0.5 { height.wrappedValue = newHeight }
        }
    }
}

enum ScienceMathHTML {
    static var resourceURL: URL { Bundle.module.url(forResource: "KaTeX", withExtension: nil)! }
    static let scripts = ["katex.min.js", "auto-render.min.js"].map {
        try! String(contentsOf: resourceURL.appendingPathComponent($0), encoding: .utf8)
    }.joined(separator: "\n")
    static let stylesheet: String = {
        var css = try! String(contentsOf: resourceURL.appendingPathComponent("katex.min.css"), encoding: .utf8)
        let fonts = try! FileManager.default.contentsOfDirectory(at: resourceURL.appendingPathComponent("fonts"), includingPropertiesForKeys: nil)
        for font in fonts where font.pathExtension == "woff2" {
            let encoded = try! Data(contentsOf: font).base64EncodedString()
            css = css.replacingOccurrences(of: "fonts/" + font.lastPathComponent, with: "data:font/woff2;base64," + encoded)
        }
        return css
    }()

    static func document(source: String, math: Bool, dark: Bool, macros: [String: String] = [:], fontSize: Double = 12, display: Bool = false, strictRender: Bool = false) -> String {
        // Insert source only as escaped text, never as HTML or executable JavaScript.
        let escaped = source.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        return #"""
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; font-src data:; connect-src 'none'">
        <style>\#(stylesheet)</style>
        <style>
        html,body { margin:0; padding:0; background:transparent; overflow:hidden; }
        #content { font:\#(fontSize)px -apple-system; line-height:1.45; color:\#(dark ? "#ededed" : "#222222"); overflow-wrap:anywhere; white-space:pre-wrap; padding:2px 0; }
        .katex { font-size:1.08em; white-space:normal; }
        .katex-display { margin:4px 0; text-align:left; }
        .katex-display > .katex { text-align:left; }
        </style><script>\#(scripts)</script>
        </head><body><div id="content">\#(escaped)</div><script>
        const content = document.getElementById('content');
        const options = {macros:\#(MathPresentation.json(macros)), displayMode:\#(display ? "true" : "false"), throwOnError:\#(strictRender ? "true" : "false"), trust:false, strict:'ignore', maxExpand:200, maxSize:20, errorColor:'\#(dark ? "#ededed" : "#222222")'};
        if (\#(math ? "true" : "false")) {
            let formula = content.textContent.replace(/\\label\{[^}]*\}/g, '');
            if (formula.includes('&') || formula.includes('\\\\')) formula = '\\begin{aligned}' + formula + '\\end{aligned}';
            try { katex.render(formula, content, options); }
            catch { content.dataset.renderError='true'; content.textContent=formula; }
        } else {
            renderMathInElement(content, {...options, delimiters:[
                {left:'$$',right:'$$',display:true}, {left:'$',right:'$',display:false},
                {left:'\\(',right:'\\)',display:false}, {left:'\\[',right:'\\]',display:true},
                ...['equation','equation*','align','align*','gather','gather*'].map(e => ({left:'\\begin{'+e+'}',right:'\\end{'+e+'}',display:true}))
            ]});
        }
        function measure() {
            // Fit wide equations to the inspector instead of clipping them.
            content.querySelectorAll('.katex-display > .katex, #content > .katex').forEach(el => {
                el.style.zoom = 1;
                if (el.scrollWidth > content.clientWidth && content.clientWidth > 0) el.style.zoom = content.clientWidth / el.scrollWidth;
            });
            window.webkit?.messageHandlers?.size?.postMessage(content.getBoundingClientRect().height);
        }
        new ResizeObserver(measure).observe(content);
        document.fonts.ready.then(measure);
        measure();
        </script></body></html>
        """#
    }
}

private struct MathMacrosKey: EnvironmentKey {
    static let defaultValue: [String: String] = [:]
}
extension EnvironmentValues {
    var mathMacros: [String: String] {
        get { self[MathMacrosKey.self] }
        set { self[MathMacrosKey.self] = newValue }
    }
}
