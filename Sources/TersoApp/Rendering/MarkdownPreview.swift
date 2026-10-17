// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import WebKit
import TersoCore

struct MarkdownPreview: NSViewRepresentable {
    let source: String
    let model: WorkspaceModel
    @Environment(\.colorScheme) private var scheme

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(context.coordinator, name: "editSource")
        config.setURLSchemeHandler(PreviewImages(directory: model.fileURL?.deletingLastPathComponent()), forURLScheme: "terso-image")
        let view = WKWebView(frame: .zero, configuration: config)
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = context.coordinator
        view.setAccessibilityLabel("Rendered Markdown. Double-click a passage to edit its source.")
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        let key = "\(scheme):\(model.prefs.theme.rawValue):\(model.prefs.fontSize):\(source)"
        guard key != context.coordinator.key else { return }
        context.coordinator.key = key
        view.loadHTMLString(MarkdownPreviewHTML.document(source: source, dark: scheme == .dark,
                                                         fontSize: model.prefs.fontSize, ink: model.prefs.theme.cssInk,
                                                         selection: model.editor?.selection.location ?? 0), baseURL: nil)
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
    }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "editSource")
        view.stopLoading()
    }
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let model: WorkspaceModel
        var key = ""
        init(model: WorkspaceModel) { self.model = model }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let index = message.body as? Int, let snapshot = model.editor?.currentSnapshot,
                  index >= 0, index <= snapshot.utf16Length else { return }
            model.editor?.reveal(TextSpan(location: index, length: 0), select: true)
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url else { return .allow }
            if url.fragment != nil && (url.scheme == "about" || url.scheme == nil) { return .allow }
            if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
            return .cancel
        }
    }
}

/// Only images beneath this document's directory are available to the web view.
final class PreviewImages: NSObject, WKURLSchemeHandler {
    let directory: URL?
    init(directory: URL?) { self.directory = directory?.resolvingSymlinksInPath() }
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let directory, let url = urlSchemeTask.request.url else { urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist)); return }
        let file = directory.appendingPathComponent(url.path).standardizedFileURL.resolvingSymlinksInPath()
        let mime = ["png":"image/png", "jpg":"image/jpeg", "jpeg":"image/jpeg", "gif":"image/gif", "webp":"image/webp", "svg":"image/svg+xml"][file.pathExtension.lowercased()]
        guard file.path.hasPrefix(directory.path + "/"), let mime,
              let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 20_000_000,
              let data = try? Data(contentsOf: file) else { urlSchemeTask.didFailWithError(URLError(.noPermissionsToReadFile)); return }
        urlSchemeTask.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil))
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}

enum MarkdownPreviewHTML {
    static let scripts: String = {
        let root = Bundle.module.url(forResource: "Markdown", withExtension: nil)!
        return ["marked.umd.js", "terso-markdown.js", "purify.min.js"].map { try! String(contentsOf: root.appendingPathComponent($0), encoding: .utf8) }.joined(separator: "\n")
    }()

    @MainActor static func document(source: String, dark: Bool, fontSize: Double, ink: String? = nil, selection: Int = 0) -> String {
        let mermaidBlocks = MermaidPresentation.blocks(in: source)
        let mermaidScripts = mermaidBlocks.isEmpty ? "" : MermaidPresentation.scripts
        let ns = source as NSString
        let regions = MathPresentation.regions(in: source)
        let marker = "TERSOMATH" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var prepared = source
        for (index, region) in regions.enumerated().reversed() {
            let range = Range(region.range.nsRange, in: prepared)!
            prepared.replaceSubrange(range, with: "\(marker)\(index)END")
        }
        // Front matter is metadata rather than body prose. Retain its length for navigation.
        if let frontMatter = MarkdownSyntax.frontMatter(in: source), let range = Range(frontMatter, in: prepared) {
            prepared.replaceSubrange(range, with: String(repeating: " ", count: frontMatter.length))
        }
        var delta = 0
        let replacements: [[String: Any]] = regions.enumerated().map { index, region in
            let token = "\(marker)\(index)END"
            let offset = region.range.location + delta
            delta += token.utf16.count - region.range.length
            return ["token":token, "offset":offset, "source":region.range.location, "length":region.range.length,
                    "formula":ns.substring(with: region.contentRange.nsRange), "display":region.kind == .displayMath]
        }
        return #"""
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; font-src data:; img-src terso-image: data:; connect-src 'none'">
        <style>\#(ScienceMathHTML.stylesheet)</style>
        <style>
        :root { color-scheme:\#(dark ? "dark" : "light"); }
        body { color:\#(ink ?? (dark ? "#dedede" : "#292929")); background:transparent; font:\#(fontSize)px/1.65 -apple-system; margin:0; }
        main { max-width:760px; padding:48px 36px 100px; margin:auto; overflow-wrap:anywhere; }
        h1,h2,h3 { line-height:1.25; margin:1.5em 0 .6em; } h1 {font-size:1.65em;} h2 {font-size:1.35em;}
        p {margin:.8em 0;} pre {overflow:auto; padding:16px; background:#8881; border-radius:6px;}
        code {font: .88em ui-monospace,monospace; background:#8881;} pre code {background:none;}
        blockquote {border-left:3px solid #8886; padding-left:20px; margin-left:0; color:\#(dark ? "#aaa" : "#666");}
        table {border-collapse:collapse; display:block; overflow:auto;} th,td {border:1px solid #8885; padding:6px 12px;} th {background:#8881;}
        a {color:\#(dark ? "#8cbcff" : "#1565c0");} img {max-width:100%;height:auto;} hr {border:0;border-top:1px solid #8885;}
        .katex-display {overflow-x:auto; overflow-y:hidden; padding:6px 0;} .katex {font-size:1.08em;}
        .math-source {font-family:ui-monospace,monospace;} section {scroll-margin-top:32px;}
        mark {background:\#(dark ? "#e8c54a40" : "#ffe36e80"); color:inherit; border-radius:2px; padding:0 1px;}
        ins.critic {color:\#(dark ? "#7fd18b" : "#1a7f37"); text-decoration-color:currentColor;}
        del.critic {color:\#(dark ? "#f08b8b" : "#c0362c");}
        mark.critic {background:\#(dark ? "#5aa2ff33" : "#5aa2ff2e");}
        .critic-comment {font-size:.85em; font-style:italic; color:\#(dark ? "#aaa" : "#666"); background:#8881; border-radius:4px; padding:1px 6px; margin:0 2px;}
        .critic-comment::before {content:"\201C";} .critic-comment::after {content:"\201D";}
        .admonition {--tone:#448aff; border-left:4px solid var(--tone); background:color-mix(in srgb, var(--tone) 8%, transparent); border-radius:4px; padding:.1em 1em; margin:1em 0;}
        .admonition > :first-child:not(.admonition-title):not(summary) {margin-top:.6em;}
        .admonition-title, .admonition > summary {font-weight:600; color:var(--tone); margin:.6em 0 .4em;}
        details.admonition > summary {cursor:pointer;} details.admonition:not([open]) > summary {margin-bottom:.6em;}
        .admonition:is(.tip,.hint,.success,.check,.done,.important) {--tone:#00a86b;}
        .admonition:is(.question,.help,.faq) {--tone:#14a3b8;}
        .admonition:is(.warning,.caution,.attention) {--tone:#e68a00;}
        .admonition:is(.danger,.error,.failure,.fail,.missing,.bug) {--tone:#e5484d;}
        .admonition:is(.example) {--tone:#7c4dff;} .admonition:is(.quote,.cite) {--tone:#8a8a8a;}
        .footnote-ref {line-height:0;} .footnote-ref a, .footnote-back {text-decoration:none;}
        .footnotes {font-size:.9em; color:\#(dark ? "#bbb" : "#555");} .footnotes li {scroll-margin-top:32px;}
        .mermaid-diagram {overflow:auto; padding:12px; border-radius:6px; background:#8881; text-align:center;}
        .mermaid-diagram svg {max-width:100%; height:auto; display:block; margin:auto;}
        .mermaid-diagram pre {margin:0; text-align:left; background:transparent;}
        </style><script>\#(ScienceMathHTML.scripts)
        \#(scripts)
        \#(mermaidScripts)</script></head><body><main id="document"></main><script>
        const source = \#(MathPresentation.json(prepared));
        const replacements = \#(MathPresentation.json(replacements));
        const macros = \#(MathPresentation.json(MathPresentation.macros(in: source)));
        const root = document.getElementById('document');
        // Marked normalizes CRLF to LF internally. Map its token offsets back
        // through both newline normalization and math placeholder replacement.
        const crlf=[]; const lineEndings=/\r\n/g; let ending;
        while((ending=lineEndings.exec(source))) crlf.push(ending.index-crlf.length);
        function sourceOffset(offset) {
            offset += crlf.filter(position => position < offset).length;
            let delta=0;
            for (const r of replacements) { if (r.offset >= offset) break; delta += r.length-r.token.length; }
            return offset+delta;
        }
        // Without options marked uses its defaults (GFM), which carry Terso's extensions.
        const purify={FORBID_TAGS:['style','form','iframe','object','embed'], FORBID_ATTR:['style']};
        const tokens=marked.lexer(source); let offset=0; const notes=new Map();
        for (const token of tokens) {
            const section=document.createElement('section'); section.dataset.source=sourceOffset(offset);
            if (token.type==='footnoteDefinition' && !notes.has(token.id)) notes.set(token.id, section.dataset.source);
            const group=[token]; group.links=tokens.links;
            if (token.type==='code' && /^mermaid(?:\s|$)/i.test(token.lang?.trim() || '')) {
                const diagram=document.createElement('div'); diagram.className='mermaid-diagram';
                const fallback=document.createElement('pre'); const code=document.createElement('code');
                code.textContent=token.text; fallback.append(code); diagram.append(fallback); section.append(diagram);
            } else {
                section.innerHTML=DOMPurify.sanitize(marked.parser(group), purify);
            }
            if (section.innerHTML) root.append(section);
            offset+=token.raw.length;
        }
        const footnotes=document.createElement('section'); footnotes.className='footnotes';
        footnotes.innerHTML=DOMPurify.sanitize(TersoMarkdown.footnotes(marked, tokens.links, notes), purify);
        if (footnotes.innerHTML) root.append(footnotes);
        window.tersoMermaidReady=Promise.resolve();
        if (typeof TersoMermaid !== 'undefined') {
        TersoMermaid.initialize({startOnLoad:false,securityLevel:'strict',htmlLabels:false,
            flowchart:{htmlLabels:false},maxTextSize:10000,suppressErrorRendering:true,
            theme:\#(dark ? "'dark'" : "'default'")});
        window.tersoMermaidReady=(async () => {
            for (const [index, diagram] of [...root.querySelectorAll('.mermaid-diagram')].entries()) {
                const source=diagram.querySelector('code')?.textContent || '';
                if (!source.trim() || source.length>10000) continue;
                try {
                    const {svg}=await Promise.race([
                        TersoMermaid.render('terso-mermaid-'+index,source),
                        new Promise((_,reject)=>setTimeout(()=>reject(Error('Diagram timed out')),8000))
                    ]);
                    const clean=DOMPurify.sanitize(svg,{USE_PROFILES:{svg:true,svgFilters:true}});
                    if (clean.includes('<svg')) diagram.innerHTML=clean;
                } catch { /* Keep the editable source visible for invalid diagrams. */ }
            }
        })();
        }
        root.querySelectorAll('img').forEach(img => {
            const path=img.getAttribute('src') || '';
            if (!/^(?:[a-z]+:|\/\/|\/)/i.test(path)) img.src='terso-image://document/'+path;
            else if (!path.startsWith('data:image/')) img.replaceWith(document.createTextNode(img.alt || 'Image'));
        });
        root.querySelectorAll('h1,h2,h3,h4,h5,h6').forEach(h => h.id=h.textContent.toLowerCase().trim().replace(/[^\p{L}\p{N}\s-]/gu,'').replace(/\s+/g,'-'));
        const walker=document.createTreeWalker(root,NodeFilter.SHOW_TEXT); const nodes=[]; while(walker.nextNode()) nodes.push(walker.currentNode);
        const pattern=new RegExp('\#(marker)([0-9]+)END','g');
        for (const node of nodes) {
            let last=0, match; const fragment=document.createDocumentFragment(); pattern.lastIndex=0;
            while ((match=pattern.exec(node.textContent))) {
                fragment.append(document.createTextNode(node.textContent.slice(last,match.index)));
                const r=replacements[Number(match[1])]; const math=document.createElement('span'); math.dataset.source=r.source;
                let formula=r.formula.replace(/\\label\{[^}]*\}/g,'');
                if(formula.includes('&') || formula.includes('\\\\')) formula='\\begin{aligned}'+formula+'\\end{aligned}';
                try { katex.render(formula,math,{displayMode:r.display,macros:{...macros},trust:false,throwOnError:true,maxExpand:200,maxSize:20}); }
                catch { math.textContent=r.formula; math.className='math-source'; }
                fragment.append(math); last=pattern.lastIndex;
            }
            if(last) {fragment.append(document.createTextNode(node.textContent.slice(last))); node.replaceWith(fragment);}
        }
        root.addEventListener('dblclick', event => {
            if(event.target.closest('a')) return;
            const block=event.target.closest('[data-source]');
            if(block) window.webkit?.messageHandlers?.editSource?.postMessage(Number(block.dataset.source));
        });
        document.fonts.ready.then(() => {
            const blocks=[...root.querySelectorAll('section[data-source]')];
            const target=blocks.filter(b => Number(b.dataset.source)<=\#(selection)).at(-1);
            if(target && \#(selection)>0) target.scrollIntoView();
        });
        </script></body></html>
        """#
    }
}
