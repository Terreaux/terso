// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import WebKit

struct MermaidBlock {
    let range: NSRange
    let source: String
}

/// Finds complete Mermaid fences using the same fenced-block boundary as the
/// editor. An incomplete fence stays as source while the writer finishes it.
@MainActor enum MermaidPresentation {
    static func blocks(in text: String) -> [MermaidBlock] {
        let ns = text as NSString
        let opener = try! NSRegularExpression(pattern: #"^[ \t]*(`{3,}|~{3,})(.*)$"#)
        let closer = try! NSRegularExpression(pattern: #"^[ \t]*(`{3,}|~{3,})[ \t]*$"#)
        var blocks: [MermaidBlock] = []
        var location = 0
        while location < ns.length {
            let line = ns.lineRange(for: NSRange(location: location, length: 0))
            let content = ns.substring(with: line).trimmingCharacters(in: .newlines)
            let contentRange = NSRange(location: 0, length: (content as NSString).length)
            guard let opening = opener.firstMatch(in: content, range: contentRange) else {
                location = line.upperBound; continue
            }
            let fence = (content as NSString).substring(with: opening.range(at: 1))
            let language = (content as NSString).substring(with: opening.range(at: 2))
                .trimmingCharacters(in: .whitespaces).split(whereSeparator: \.isWhitespace).first.map(String.init)?.lowercased()
            var next = line.upperBound
            var closeLine: NSRange?
            while next < ns.length {
                let candidate = ns.lineRange(for: NSRange(location: next, length: 0))
                let raw = ns.substring(with: candidate).trimmingCharacters(in: .newlines)
                if let match = closer.firstMatch(in: raw, range: NSRange(location: 0, length: (raw as NSString).length)) {
                    let run = (raw as NSString).substring(with: match.range(at: 1))
                    if run.first == fence.first && run.count >= fence.count { closeLine = candidate; break }
                }
                next = candidate.upperBound
            }
            guard let closeLine else { break }
            if language == "mermaid" {
                let raw = ns.substring(with: NSRange(location: line.upperBound, length: closeLine.location - line.upperBound))
                let source = raw.hasSuffix("\r\n") ? String(raw.dropLast(2)) : raw.hasSuffix("\n") ? String(raw.dropLast()) : raw
                if !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, source.utf16.count <= 10_000 {
                    let closingText = ns.substring(with: closeLine).trimmingCharacters(in: .newlines)
                    let end = closeLine.location + (closingText as NSString).length
                    blocks.append(MermaidBlock(range: NSRange(location: line.location, length: end - line.location), source: source))
                }
            }
            location = closeLine.upperBound
        }
        return blocks
    }

    static let scripts: String = {
        let root = Bundle.module.url(forResource: "Markdown", withExtension: nil)!
        return ["purify.min.js", "mermaid.bundle.js"].map {
            try! String(contentsOf: root.appendingPathComponent($0), encoding: .utf8)
        }.joined(separator: "\n")
    }()

    static func html(source: String, dark: Bool) -> String {
        #"""
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; font-src data:; img-src data:; connect-src 'none'">
        <style>html,body{margin:0;padding:0;background:transparent;color:\#(dark ? "#dedede" : "#292929")}
        #diagram{display:inline-block;max-width:100%}svg{display:block;max-width:100%;height:auto}</style>
        <script>\#(scripts)</script></head><body><div id="diagram"></div><script>
        window.__mermaidState='working';
        TersoMermaid.initialize({startOnLoad:false,securityLevel:'strict',htmlLabels:false,
            flowchart:{htmlLabels:false},maxTextSize:10000,suppressErrorRendering:true,
            theme:\#(dark ? "'dark'" : "'default'")});
        (async()=>{
            try {
                const result=await TersoMermaid.render('terso-mixed-mermaid',\#(MathPresentation.json(source)));
                const target=document.getElementById('diagram');
                const clean=DOMPurify.sanitize(result.svg,{USE_PROFILES:{svg:true,svgFilters:true}});
                if (!clean.includes('<svg')) throw Error('Invalid SVG');
                target.innerHTML=clean;
                await document.fonts.ready;
                window.__mermaidState='ready';
            } catch { window.__mermaidState='failed'; }
        })();
        </script></body></html>
        """#
    }
}

@MainActor final class MermaidImageRenderer {
    private var cache: [String: NSImage] = [:]

    func image(source: String, width: Double, dark: Bool) async throws -> NSImage? {
        let key = "\(source)|\(width)|\(dark)"
        if let cached = cache[key] { return cached }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: max(80, width), height: 3000), configuration: config)
        web.setValue(false, forKey: "drawsBackground")
        defer { web.stopLoading() }
        web.loadHTMLString(MermaidPresentation.html(source: source, dark: dark), baseURL: nil)
        let deadline = ContinuousClock.now + .seconds(8)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            let state = try? await web.evaluateJavaScript("window.__mermaidState") as? String
            if state == "ready" { break }
            if state == "failed" { return nil }
            try await Task.sleep(for: .milliseconds(30))
        }
        try Task.checkCancellation()
        guard let rect = try await web.evaluateJavaScript("(() => { const e=document.querySelector('#diagram svg'); if(!e)return null; const r=e.getBoundingClientRect(); return [r.x,r.y,r.width,r.height]; })()") as? [Double],
              rect.count == 4, rect[2] > 0, rect[3] > 0, rect[2] <= 4096, rect[3] <= 4096 else { return nil }
        let capture = WKPDFConfiguration()
        capture.rect = CGRect(x: max(0, rect[0] - 2), y: max(0, rect[1] - 2),
                              width: min(width, rect[2] + 4), height: rect[3] + 4)
        let data = try await web.pdf(configuration: capture)
        try Task.checkCancellation()
        guard let image = NSImage(data: data) else { return nil }
        image.size = capture.rect!.size
        if cache.count >= 64 { cache.removeAll(keepingCapacity: true) }
        cache[key] = image
        return image
    }
}
