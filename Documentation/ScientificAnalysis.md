# Scientific document debugger

Science starts with **Needs attention**, followed by a compact document model and a relationship explorer. Local checks identify structural problems and uncertain review candidates; they do not assess scientific correctness. Use `Samples/scientific-analysis.md` or the fuller `Tests/TersoAnalysisTests/Fixtures/scientific-debugger.md` manuscript.

## Review and navigation

- The overview shows severity counts and the first three findings, ordered by severity and source position. Show all findings for explanations, confidence, related objects, source navigation, and Ignore.
- Notation, Definitions, Quantities, Equations, References, Claims, and Evidence open focused lists with a Science back button. Selecting an object reveals its source and details. Notation and quantities support cycling through occurrences.
- Navigation uses the existing editor layout manager for temporary emphasis. It scrolls without moving the insertion point or taking focus. Science annotation, keyboard, and minimap navigation select the diagnostic while Science is open. The rail gives more weight to structural warnings and distinguishes references with a small square marker.
- Claim details distinguish locally classified author statements from scientific claims. Mark as author statement and Ignore warning are document-session decisions; neither edits the manuscript. The overview menu restores ignored Science warnings. Decisions survive reanalysis of unchanged claim text but are not saved across application sessions.
- Find support uses the configured Assistant with the selected claim, profile context, and existing data-access controls. It does not run automatically or transmit the whole document in the background.
- Scientific Map is a relationship explorer with source navigation, not a graph canvas. It follows definitions, equation symbols, assigned values, citations, cross-reference targets, and nearby evidence candidates. A nearby relationship is explicitly different from a semantic support judgment.

## Architecture

`ScientificSyntax` and `ProseText` retain the existing UTF-16 source mapping and exclude code, comments, and front matter from extraction. `ScientificDocumentModel` is an immutable snapshot result with stored definitions, equations, nodes, relationships, evidence, and normalized diagnostics. Graph arrays are constructed during background analysis, not in SwiftUI rendering.

`ScientificGraph.swift` supplies typed diagnostic severity, category, confidence, suggested actions, source ranges, and related object IDs. Object IDs are local to the snapshot; selection is cleared on text edits to avoid applying old offsets to a new object. `ScientificRule` adapts those diagnostics to the existing `WritingIssue` and `TextAnnotation` pipeline, preserving Review, dismissal identity, multiple source locations, and annotation layers. There is one diagnostic computation shared by Science and Review.

`ScienceSession` owns UI actions and per-document review overrides. `WorkspaceModel` retains Science selection and detail navigation alongside other inspector state. `MarkdownDocument` remains a plain-text `FileDocument`; no sidecar, database, graph store, or document-format change is introduced.

Analysis still uses a 400 ms typing debounce and detached work on immutable snapshots. Cancellation propagates to that work; generation and revision checks reject superseded results, including same-revision profile changes and delayed spelling callbacks. Source navigation is immediate and revision/profile gated.

Profiles share one engine. Units, coarse unit families, aliases, common-symbol exemptions, terminology, preferred notation, disabled rule IDs, and undefined-use thresholds are profile data. General Science and Particle Physics / HEP remain available. The model and relationships are Codable for future advisory consumers; extraction itself makes no AI calls.

## Deterministic checks and limits

- **Notation:** recognizes a bounded LaTeX atom/script grammar; ignores common operators including arrows and scripted sums. Tracks occurrences, explicit introductions, definition status, and coarse notation type. Checks use before definition, repeated notation without a detected definition, unused definitions, script typography variants, and profile preferences. Common symbols can be marked possibly assumed knowledge. Unknown meanings remain unknown; capitalization, scalar/vector meaning conflicts, and symbol overloading are not inferred without sufficient semantics. Display forms retain source LaTeX rather than introducing another math renderer.
- **Definitions:** recognizes explicit English symbol introductions, `:=`, `\coloneqq`, and constrained single-term prose definitions. Tracks exact definition occurrence separately from its source passage. It does not attempt to define every technical term or expand macros.
- **Claims:** chooses one inspectable claim per sentence using conservative local patterns, including author experience, method, background, comparison, quantitative claims, novelty, and strong conclusions. Classification has low confidence. Unsupported-support diagnostics concern explicit textual links in the same paragraph; they neither validate nor disprove the proposition. Same-sentence citations are linked as citations; other paragraph citations remain nearby evidence candidates.
- **Quantities:** parses explicit symbol assignments, numeric values, decimal/scientific notation, `±`/`\pm` uncertainty, common units, HEP aliases, and inverse luminosity units. Metadata links repeated assignments, detected definition context, and nearby citation candidates. Checks differing values under the same symbol/unit, incompatible profile-defined unit families, and differing explicit uncertainties at equal central values. These remain advisory because conditions or conventions can differ. No unit conversion, uncertainty propagation, or dimensional algebra is performed.
- **Equations:** indexes display math, labels, used/introduced symbols, and references. Shared reference diagnostics catch duplicate, missing, and unused labels. Symbol details expose definition status. `dimensionCheckAvailable` is explicitly false pending defensible semantic dimensions.
- **References:** separates literal TeX citations from equation/figure/table/section cross-references. A local `bibitem` bibliography permits missing-key checks; an external bibliography declaration suppresses completeness assumptions. External TeX includes and bibliography files are not loaded. Object kind uses the containing environment or conventional label prefixes. Markdown/Pandoc bibliography resolution remains future work.

Results may omit valid scientific constructions; a clean panel does not certify a manuscript. Automatic semantic definition inference, validated support/provenance, broader notation consistency, unit algebra, and a full graph canvas remain future work.

## Validation

Run `swift build` and `swift test`. Tests cover source ranges with Unicode/CRLF, operators, explicit definitions and prior usage, unit/uncertainty parsing, equation labels, duplicate/broken/multi-key references, conditional bibliography checks, claim classification, paragraph versus citation relationships, graph endpoint integrity, serialization, diagnostic ordering, Review adapters, source navigation without caret movement, local review decisions, and stale revision/profile replacement. Scale fixtures exercise both an 80-section manuscript and a roughly 100 KB document.

### Validation of this iteration

- All 115 tests passed; debug and release application builds passed.
- The 102,506 UTF-16 scale fixture fell from 6.27 s to 2.72 s in debug after replacing repeated scans with indexes. A measured release run took 0.52 s. These are local engine timings, not a guarantee for every manuscript or device.
- An isolated release app was inspected in dark mode at the normal 380-point inspector width. Verified overview/detail navigation, source reveal with editor focus retained, author-statement dismissal, keyboard source-to-Science selection, and equation → symbol → assigned value exploration.
- The large-source opening/typing smoke check used plain-text import of Markdown content: the isolated preview's Open panel disabled the newly generated `.md` file but accepted its `.txt` copy. The smaller scientific `.md` fixture opened normally. Keystroke/frame latency was not instrumented, and this iteration did not change file-type registration.
- No live AI request was made. The Find support action reuses the existing tested provider/context path.
