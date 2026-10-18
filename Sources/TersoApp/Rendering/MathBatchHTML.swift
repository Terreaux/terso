// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

struct MathRenderRequest: Hashable {
    let formula: String
    let display: Bool
}

/// One local KaTeX document for a bounded group of equation snapshots.
enum MathBatchHTML {
    static func document(requests: [MathRenderRequest], macros: [String: String], fontSize: Double, dark: Bool) -> String {
        let items = requests.map { ["formula": $0.formula, "display": $0.display] as [String: Any] }
        return #"""
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; font-src data:; connect-src 'none'">
        <style>\#(ScienceMathHTML.stylesheet)</style>
        <style>
        html,body{margin:0;padding:0;background:transparent}
        /* Tall batches keep the full equation width even when macOS always shows scrollbars. */
        ::-webkit-scrollbar{display:none}
        .equation{font:\#(fontSize)px -apple-system;line-height:1.45;color:\#(dark ? "#ededed" : "#222222");overflow-wrap:anywhere;white-space:pre-wrap;padding:6px 0}
        .katex{font-size:1.08em;white-space:normal}
        .katex-display{margin:4px 0;text-align:left}
        .katex-display>.katex{text-align:left}
        </style><script>\#(ScienceMathHTML.scripts)</script></head><body><script>
        window.__tersoMathRects=null;
        const macros=\#(MathPresentation.json(macros));
        const items=\#(MathPresentation.json(items));
        const containers=items.map(item=>{
            const content=document.createElement('div');content.className='equation';document.body.append(content);
            let formula=item.formula.replace(/\\label\{[^}]*\}/g,'');
            if(formula.includes('&')||formula.includes('\\\\'))formula='\\begin{aligned}'+formula+'\\end{aligned}';
            try{katex.render(formula,content,{macros:{...macros},displayMode:item.display,throwOnError:true,
                trust:false,strict:'ignore',maxExpand:200,maxSize:20});}
            catch{content.dataset.renderError='true';content.textContent=formula;}
            return content;
        });
        document.fonts.ready.then(()=>{
            containers.forEach(content=>{
                content.querySelectorAll('.katex-display>.katex, :scope>.katex').forEach(el=>{
                    if(el.scrollWidth>content.clientWidth&&content.clientWidth>0)el.style.zoom=content.clientWidth/el.scrollWidth;
                });
            });
            window.__tersoMathRects=containers.map(content=>{
                if(content.dataset.renderError)return null;
                const el=content.querySelector('.katex');if(!el)return null;
                const r=el.getBoundingClientRect();return [r.x,r.y,r.width,r.height];
            });
        });
        </script></body></html>
        """#
    }
}
