// SPDX-License-Identifier: AGPL-3.0-only
// Terso's extensions to marked, after Python-Markdown and pymdown-extensions:
// footnotes, admonitions (`!!!`, and collapsible `???`), ==highlights== and
// CriticMarkup; after GitHub and Obsidian: alerts and callouts, wiki links
// and %% comments %%. Each token keeps its exact `raw` so the preview can map
// it back to the source. A Markdown flavour installs only what its platform
// renders, so everything else stays as typed.
const TersoMarkdown = (() => {
    const escape = s => String(s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
    const slug = id => id.replace(/[^\p{L}\p{N}_-]/gu, '-');
    const indented = /^(?: {4}|\t)/;
    const blank = /^[ \t]*$/;

    // Definitions are block tokens, so all of them are known before any
    // reference is tokenized. Notes number in order of first reference.
    const notes = new Map(), order = [], references = new Map();

    const footnoteDefinition = {
        name: 'footnoteDefinition', level: 'block',
        start(src) { return src.match(/^\[\^[^\]\s]+\]:/m)?.index; },
        tokenizer(src) {
            const head = /^\[\^([^\]\s]+)\]:[ \t]?/.exec(src);
            if (!head) return;
            const lines = src.split('\n');
            const body = [lines[0].slice(head[0].length)];
            let take = 1, gap = false;
            // Indented lines continue the note, across blank lines; an
            // unindented line continues only its first paragraph.
            for (let i = 1; i < lines.length; i++) {
                const line = lines[i];
                if (blank.test(line)) { gap = true; continue; }
                if (indented.test(line) || (!gap && !/^(?:\[\^[^\]\s]+\]:|[ \t]*(?:[#>|`*+-]|\d+[.)]|!!!|\?\?\?))/.test(line))) {
                    for (let j = take; j < i; j++) body.push('');
                    body.push(line.replace(indented, ''));
                    take = i + 1;
                    continue;
                }
                break;
            }
            const raw = lines.slice(0, take).join('\n') + (take < lines.length ? '\n' : '');
            const token = { type: 'footnoteDefinition', raw, id: head[1], tokens: [] };
            this.lexer.blockTokens(body.join('\n'), token.tokens);
            if (!notes.has(token.id)) notes.set(token.id, token);
            return token;
        },
        renderer() { return ''; }
    };

    const footnoteReference = {
        name: 'footnoteReference', level: 'inline',
        start(src) { const i = src.indexOf('[^'); return i < 0 ? undefined : i; },
        tokenizer(src) {
            const m = /^\[\^([^\]\s]+)\](?!:)/.exec(src);
            if (m && notes.has(m[1])) return { type: 'footnoteReference', raw: m[0], id: m[1] };
        },
        renderer(token) {
            let number = order.indexOf(token.id) + 1;
            if (!number) { order.push(token.id); number = order.length; }
            const count = (references.get(token.id) || 0) + 1;
            references.set(token.id, count);
            const key = slug(token.id);
            return `<sup class="footnote-ref"><a href="#fn-${key}" id="fnref-${key}${count > 1 ? '-' + count : ''}">${number}</a></sup>`;
        }
    };

    // `!!! type "Title"` with an indented body; `???` folds, `???+` starts open.
    const admonition = {
        name: 'admonition', level: 'block',
        start(src) { return src.match(/^(?:!!!|\?\?\?\+?)[ \t]/m)?.index; },
        tokenizer(src) {
            const head = /^(!!!|\?\?\?\+?)[ \t]+([\w-]+(?:[ \t]+[\w-]+)*)(?:[ \t]+"([^"\n]*)")?[ \t]*(?:\n|$)/.exec(src);
            if (!head) return;
            let raw = head[0], body = [];
            if (raw.endsWith('\n')) {
                const lines = src.slice(raw.length).split('\n');
                let take = 0;
                for (let i = 0; i < lines.length; i++) {
                    if (indented.test(lines[i])) take = i + 1;
                    else if (!blank.test(lines[i])) break;
                }
                raw += lines.slice(0, take).join('\n') + (take && take < lines.length ? '\n' : '');
                body = lines.slice(0, take).map(line => line.replace(indented, ''));
            }
            return { type: 'admonition', raw, fold: head[1], kinds: head[2].toLowerCase().split(/[ \t]+/), title: head[3],
                     tokens: this.lexer.blockTokens(body.join('\n'), []) };
        },
        renderer(token) {
            const kind = token.kinds[0];
            const title = escape(token.title ?? kind.charAt(0).toUpperCase() + kind.slice(1));
            const classes = ['admonition', ...token.kinds].map(escape).join(' ');
            const body = this.parser.parse(token.tokens);
            if (token.fold === '!!!') {
                return `<div class="${classes}">${token.title === '' ? '' : `<p class="admonition-title">${title}</p>`}${body}</div>\n`;
            }
            return `<details class="${classes}"${token.fold === '???+' ? ' open' : ''}><summary>${title || escape(kind)}</summary>${body}</details>\n`;
        }
    };

    // CriticMarkup: {++insert++} {--delete--} {~~old~>new~~} {==mark==} {>>comment<<}.
    const forms = {
        '++': /^\{\+\+([\s\S]*?)\+\+\}/, '--': /^\{--([\s\S]*?)--\}/, '~~': /^\{~~([\s\S]*?)~>([\s\S]*?)~~\}/,
        '==': /^\{==([\s\S]*?)==\}/, '>>': /^\{>>([\s\S]*?)<<\}/
    };
    const critic = {
        name: 'critic', level: 'inline',
        start(src) { const i = src.search(/\{(?:\+\+|--|~~|==|>>)/); return i < 0 ? undefined : i; },
        tokenizer(src) {
            const form = src.slice(1, 3), m = forms[form]?.exec(src);
            if (!m) return;
            return { type: 'critic', raw: m[0], form, tokens: this.lexer.inlineTokens(m[1]),
                     replacement: m[2] === undefined ? null : this.lexer.inlineTokens(m[2]) };
        },
        renderer(token) {
            const text = this.parser.parseInline(token.tokens);
            switch (token.form) {
            case '++': return `<ins class="critic">${text}</ins>`;
            case '--': return `<del class="critic">${text}</del>`;
            case '~~': return `<del class="critic">${text}</del><ins class="critic">${this.parser.parseInline(token.replacement)}</ins>`;
            case '==': return `<mark class="critic">${text}</mark>`;
            default: return `<span class="critic-comment">${text}</span>`;
            }
        }
    };

    // Obsidian and pymdownx.mark highlights, on one line as the editor styles them.
    const mark = {
        name: 'mark', level: 'inline',
        start(src) { const i = src.search(/==(?=[^\s=])/); return i < 0 ? undefined : i; },
        tokenizer(src) {
            const m = /^==(?=[^\s=])([^\n]*?[^\s=])==/.exec(src);
            if (m) return { type: 'mark', raw: m[0], tokens: this.lexer.inlineTokens(m[1]) };
        },
        renderer(token) { return `<mark>${this.parser.parseInline(token.tokens)}</mark>`; }
    };

    // `> [!NOTE]` opening a quote. GitHub knows five kinds and nothing else on
    // the line; GitLab also takes a title. Obsidian takes any kind, a title,
    // and `+` or `-` to fold the callout open or closed.
    const alertKinds = ['note', 'tip', 'important', 'warning', 'caution'];
    const alert = style => ({
        name: 'alert', level: 'block',
        start(src) { return src.match(/^ {0,3}>[ \t]*\[![\w-]+\]/m)?.index; },
        tokenizer(src) {
            const head = /^ {0,3}>[ \t]*\[!([\w-]+)\]([+-]?)[ \t]*([^\n]*)(?:\n|$)/.exec(src);
            if (!head) return;
            const kind = head[1].toLowerCase(), title = head[3].trim();
            if (style !== 'obsidian' && (!alertKinds.includes(kind) || head[2] || (style === 'github' && title))) return;
            const rest = src.slice(head[0].length).split('\n');
            let take = 0;
            while (take < rest.length && /^ {0,3}>/.test(rest[take])) take++;
            const raw = head[0] + (take ? rest.slice(0, take).join('\n') + (take < rest.length ? '\n' : '') : '');
            const body = rest.slice(0, take).map(line => line.replace(/^ {0,3}> ?/, ''));
            return { type: 'alert', raw, kind, fold: head[2], title, tokens: this.lexer.blockTokens(body.join('\n'), []) };
        },
        renderer(token) {
            const title = escape(token.title || token.kind.charAt(0).toUpperCase() + token.kind.slice(1));
            const classes = `admonition alert ${escape(token.kind)}`;
            const body = this.parser.parse(token.tokens);
            if (!token.fold) return `<div class="${classes}"><p class="admonition-title">${title}</p>${body}</div>\n`;
            return `<details class="${classes}"${token.fold === '+' ? ' open' : ''}><summary>${title}</summary>${body}</details>\n`;
        }
    });

    // Obsidian's [[note]], [[note|alias]] and ![[picture.png]] embeds.
    const wikiLink = {
        name: 'wikiLink', level: 'inline',
        start(src) { const i = src.indexOf('[['); return i < 0 ? undefined : (src[i - 1] === '!' ? i - 1 : i); },
        tokenizer(src) {
            const m = /^(!?)\[\[([^\[\]|\n]+)(?:\|([^\[\]|\n]+))?\]\]/.exec(src);
            if (m) return { type: 'wikiLink', raw: m[0], embed: !!m[1], target: m[2].trim(), alias: m[3]?.trim() };
        },
        renderer(token) {
            const label = escape(token.alias ?? token.target);
            if (token.embed && /\.(?:png|jpe?g|gif|webp|svg)$/i.test(token.target)) {
                return `<img src="${escape(token.target)}" alt="${label}">`;
            }
            return `<span class="wikilink${token.embed ? ' embed' : ''}">${label}</span>`;
        }
    };

    // Obsidian's %% comments %% are left out of the reading view.
    const commentBlock = {
        name: 'commentBlock', level: 'block',
        start(src) { return src.match(/^%%/m)?.index; },
        tokenizer(src) {
            const m = /^%%[\s\S]*?%%[ \t]*(?:\n|$)/.exec(src);
            if (m) return { type: 'commentBlock', raw: m[0] };
        },
        renderer() { return ''; }
    };
    const comment = {
        name: 'comment', level: 'inline',
        start(src) { const i = src.indexOf('%%'); return i < 0 ? undefined : i; },
        tokenizer(src) {
            const m = /^%%[\s\S]*?%%/.exec(src);
            if (m) return { type: 'comment', raw: m[0] };
        },
        renderer() { return ''; }
    };

    const everything = ['tables', 'strikethrough', 'taskLists', 'autolinks', 'footnotes', 'admonitions',
                        'alerts', 'highlights', 'critic', 'wikiLinks', 'comments'];
    return {
        /// `features` names what the flavour renders; `alerts` is 'github',
        /// 'gitlab' or 'obsidian'. CommonMark turns off marked's GFM.
        install(marked, { features = everything, alerts = 'obsidian', gfm = true } = {}) {
            const has = new Set(features);
            // An overriding tokenizer that returns nothing turns that syntax off.
            const off = () => undefined;
            const tokenizer = {};
            if (!has.has('tables')) tokenizer.table = off;
            if (!has.has('strikethrough')) tokenizer.del = off;
            if (!has.has('autolinks')) tokenizer.url = off;
            // Marked reads task items with GFM; without task lists they print as typed.
            const renderer = has.has('taskLists') ? {} : { checkbox: ({ checked }) => checked ? '[x]' : '[ ]' };
            const extensions = [];
            if (has.has('footnotes')) extensions.push(footnoteDefinition);
            if (has.has('admonitions')) extensions.push(admonition);
            if (has.has('alerts')) extensions.push(alert(alerts));
            if (has.has('comments')) extensions.push(commentBlock, comment);
            if (has.has('footnotes')) extensions.push(footnoteReference);
            if (has.has('wikiLinks')) extensions.push(wikiLink);
            if (has.has('critic')) extensions.push(critic);
            if (has.has('highlights')) extensions.push(mark);
            marked.use({ gfm, tokenizer, renderer, extensions });
        },
        /// The notes list, rendered after the body so numbering follows the references.
        footnotes(marked, links, sources) {
            const ids = [...order, ...[...notes.keys()].filter(id => !order.includes(id))];
            if (!ids.length) return '';
            const items = ids.map(id => {
                const key = slug(id), group = [...notes.get(id).tokens];
                group.links = links;
                let html = marked.parser(group);
                if (order.includes(id)) {
                    const back = ` <a href="#fnref-${key}" class="footnote-back">↩</a>`;
                    html = /<\/p>\s*$/.test(html) ? html.replace(/<\/p>\s*$/, back + '</p>') : html + back;
                }
                return `<li id="fn-${key}" data-source="${sources.get(id) ?? 0}">${html}</li>`;
            });
            return `<hr><ol>${items.join('')}</ol>`;
        }
    };
})();
