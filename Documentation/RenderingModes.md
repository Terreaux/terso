# Document rendering modes

The toolbar and View menu offer three modes per document. Shortcuts are Command-Control-1 (Source), Command-Control-2 (Mixed), and Command-Control-3 (Preview).

- **Source** shows editable, monospaced text with every delimiter visible.
- **Mixed** keeps the native editable Markdown view. Markdown syntax stays visible with its existing styling, except regular links and wiki links, which show their label or alias and reveal their source on the editing line. Closed inline and display math renders through bundled KaTeX. Placing the caret on a formula's line, inside a multiline wrapper, or selecting its lines reveals the original source. Leaving those lines renders it again. Tables remain editable source; complete `mermaid` fences display diagrams and reveal source while editing.
- **Preview** shows rendered Markdown, including tables, lists, code blocks, Mermaid diagrams, links, local images, and math. Double-click a passage or formula to return to Mixed at its original source location. For `.tex` and `.latex` documents, Preview compiles the current in-memory text with local Tectonic and displays the resulting PDF.

Switching modes preserves the underlying NSTextView, selection, undo manager, document revision, and original characters. Math changes display glyphs rather than replacing text with attachments. Copying and saving therefore retain source, and Review/Science ranges continue to address the same UTF-16 offsets. Review navigation exits Preview to reveal its source. Mixed is the initial mode; mode choice is retained during the document session, independently of other windows.

## Math and manuscript context

KaTeX, its fonts, Marked, DOMPurify, and Mermaid are bundled and run locally. Mermaid loads into Preview only when the source has a complete Mermaid fence. Invalid diagrams remain visible as source. Common balanced `\newcommand`, `\renewcommand`, and `\providecommand` definitions (including numbered arguments) feed the editor, Markdown preview, and Science sidebar. Definitions in comments or code are excluded. Optional default arguments and arbitrary preamble/package execution are not interpreted by KaTeX. Unsupported or unfinished math stays readable as source; use the compiled LaTeX Preview for full TeX package semantics.

Mixed rendering caches vector PDF snippets per editor and invalidates pending work when source, selection, presentation, or geometry changes. Render results are checked against the originating source before use. Inline/display math and code boundaries come from the existing scientific scanner.

Moving the caret within the same revealed source lines reuses the current presentation and lets pending rendering finish. Uncached equations render in groups of up to sixteen in one local KaTeX document, sharing script and font loading. Duplicate equations reuse the same snapshot; the bounded equation cache evicts individual entries rather than flushing every snapshot when full.

Full Markdown preview sanitizes HTML and disables document scripts and network requests. Relative images beneath the document directory are supported; remote images display their alternative text. External links open only after clicking them. Front matter is omitted from the reading preview.

## Compiled LaTeX preview

Tectonic is discovered on PATH or in standard macOS package-manager locations. It is an optional runtime dependency, not copied into Terso. Compilation uses the unsaved text, the document directory for relative inputs, a temporary output directory, untrusted-input mode, and cached support files by default. Source files are not overwritten. If a font/package is absent from the cache, **Compile and fetch missing packages** explicitly retries with downloads enabled. Errors expose bounded compiler output; changing modes cancels compilation. A 45-second limit terminates stalled jobs.

## LaTeX source

`.tex` and `.latex` files (or unnamed text that opens with `\documentclass`) are read as LaTeX by the editor and every analyser. Sectioning commands (`\part` … `\subparagraph`) become outline headings, levelled by the commands the file actually uses. The preamble, anything after `\end{document}`, comments, and tabular, drawing, verbatim/listing and bibliography environments are excluded from prose; `\item` starts a list item. Markdown-only rules — `#` headings, tables, emphasis markers, front matter — do not apply. Mixed mode colours commands, braces and environments as syntax, sets section titles as headings, shows `\emph`/`\textbf`, and quiets citations, labels and comments.

## Validation

Automated coverage exercises original UTF-16 ranges, active-line/multiline reveal, code/currency exclusions, macro isolation, glyph geometry, source preservation, undo across mode switches, Markdown tables and code, source links, HTML sanitization, and local vector snapshots. The opt-in `TERSO_TEST_TECTONIC=1 swift test` smoke test compiles unsaved TeX, then verifies the cached path. Native checks confirmed Mixed math and full Markdown preview in a separate test app.
