# Scientific analysis

Scientific analysis builds a revision-bound model of the current source. The
app also indexes the manuscript root, included sections, local dependencies,
and declared bibliography with source-file and line locations.
It does not solve equations, check proofs, run a computer algebra system, retrieve
papers, or establish that a citation supports a claim. Its graph is not currently
included in AI prompts.

## Scan, index, connect

[ScientificSyntax](../Sources/TersoCore/ScientificAnalysis/ScientificSyntax.swift)
partitions source into prose, inline/display math, commands, citations, references,
code, and comments. Code takes precedence over TeX. Supported math forms include
`$…$`, `$$…$$`, `\(…\)`, `\[…\]`, and listed math environments such as equation,
align, gather, and multline. Numeric dollar expressions have currency-disambiguation
heuristics. Incomplete inline math recovers at line boundaries when no closer is
found before a paragraph boundary. This is a bounded structural scanner, not macro
expansion or a multi-file TeX parser.

[ScientificDocumentModel](../Sources/TersoAnalysis/ScientificAnalysis/ScientificDocumentModel.swift)
starts from the same snapshot and prose blocks. Scientific indexes exclude code,
comments, and front matter while retaining source offsets. They separately index:

| Object | Extraction and normalization |
|---|---|
| Symbols | Conservative math atom grammar: letter or recognized command/group with scripts; excludes operators, text/unit wrappers, and numeric unit tokens where recognized |
| Symbol identity | Remove whitespace and simplify single-character script braces (`p_{T}` → `p_T`); this does not establish mathematical equivalence |
| Definitions | Explicit nearby forms such as “let,” “we define,” “denotes,” “is defined as,” `:=`, and `\coloneqq`; graph pass also detects bounded prose term definitions |
| Quantities | Numeric literals, optional explicit uncertainty, known units/aliases, scientific notation, and inverse-unit notation; bind to a symbol only through adjacent explicit equality |
| References | Literal TeX labels, cross-references, natbib/biblatex citation commands, Pandoc citation keys, and Markdown label attributes |
| Labeled objects | Kind inferred from a surrounding recognized figure/table/equation environment or a `fig:`, `tab:`, `eq:`, `sec:` key prefix; caption/image argument recorded when recognized |
| Claims | Sentence phrase patterns, with at most one selected type per sentence |
| Equations | Display-math regions, their labels, symbol uses, detected introductions, and local references |

Bare integers are treated as quantities only with a recognized unit, uncertainty,
exponent, or explicit equality binding. Command arguments such as labels and image
filenames are excluded. Number parsing normalizes Unicode minus and handles
ordinary numeric literals, `e` notation, and supported powers of ten. It neither
converts GeV to MeV nor normalizes arbitrary compound units.

Claim priority is author statement, strong conclusion, novelty, quantitative,
agreement, causal, comparative, methodological, then background. Examples include
“demonstrates” for strong conclusions and “present the first” for novelty.
Quantitative claims also require an intersecting quantity. These labels come from
phrases, not semantic inference; claim confidence is low.

## Evidence and relationships

Claim evidence is collected within the same **ProseText block**: citations,
resolved local cross-references, quantities, and measurement/methodology phrases
in other sentences. The claim's own methodological wording is not counted as
independent textual support. Quantity-to-citation proximity instead uses
`NSString.paragraphRange`, which can differ from blank-line prose blocks in wrapped
source. Neither proximity relation proves provenance.

[ScientificGraph](../Sources/TersoAnalysis/ScientificAnalysis/ScientificGraph.swift)
builds source-linked nodes and `defines`, `uses`, `represents`, `cites`,
`nearbyEvidence`, and `references` edges. IDs connect diagnostics with source
objects and navigation. They are derived from source positions and identities;
they are not stable identifiers across arbitrary document edits.

## Diagnostics

| Check | Current trigger |
|---|---|
| Definition without detected use | Defined symbol appears once and is not a configured common symbol |
| Use before definition | First math occurrence precedes the first detected definition |
| Possibly undefined notation | No detected definition, not a common symbol, at least `minimumUndefinedUses` occurrences (default 3) |
| Notation variants | Distinct indexed spellings collapse under the limited variant normalization; equivalence is not assumed |
| Preferred notation | Profile supplies a different preferred spelling |
| Broken reference | A key has no label in the fully indexed manuscript |
| Missing bibliography entry | A citation key is absent from the indexed bibliography |
| Duplicate / unreferenced label | The same key is declared several times, or a label has no use in the indexed manuscript |
| Strong claim support | Strong conclusion has no citation, resolved cross-reference, or quantity in its sentence |
| Novelty support | Novelty claim has no citation in its prose block |
| Numerical inconsistency | Explicit assignments of the same symbol and normalized unit have different numeric values |
| Unit family mismatch | Assignments of one symbol have more than one known coarse unit dimension |
| Different uncertainties | Same symbol, central value, and normalized unit have differing explicit uncertainties |

Numerical and unit findings have low confidence because different conditions or
symbol meanings can be legitimate. Precision findings are informational. Missing
cross-references and duplicate labels have high confidence within the scanned
scope. The core analyzer works on one document. For a paper, the app replaces
its local reference findings with the manuscript index findings and uses
resolved project labels when reviewing strong claims. Missing TeX inputs and
unreadable bibliography files keep the index from declaring absent keys.
Equation `dimensionCheckAvailable` is always false.

[ScientificRule](../Sources/TersoAnalysis/ScientificAnalysis/ScientificRules.swift)
converts diagnostics into ordinary writing issues. Informational diagnostics stay
informational; other high-confidence diagnostics become warnings, and the rest
become suggestions. Metadata retains diagnostic/object IDs for Science navigation.
The Science model also retains the original severity and confidence separately.

## Profiles and UI lifetime

`ScientificProfile` carries known units, aliases, coarse dimensions, common
symbols, terminology, preferred notation, disabled category rule IDs, and the
undefined-use threshold. The app and analyzer start with General Science. Authors
can select the HEP profile. Terminology is configuration data, not a general
terminology checker. Disabled categories such as `science.notation` suppress their
diagnostics.

[ScienceSession](../Sources/TersoApp/Science/ScienceSession.swift) and
[WorkspaceModel](../Sources/TersoApp/WorkspaceModel.swift) expose current analysis
and source navigation. Text edits invalidate current science navigation until a
matching revision arrives. Inspecting related objects or changing review state
does not change the scientific source. Tests are linked in
[tests and evaluation](testing-and-evaluation.md).

Author-confirmed evidence links persist in `ClaimEvidence.json` in Terso’s
application support directory, keyed by manuscript root. Each link retains the
source file, selected text, and surrounding context at both ends. Terso resolves
the original quotations again when the file or manuscript index changes. A
uniquely matched passage can move within its source. Missing, changed, or
ambiguous passages reopen review and retain the earlier quotation. Confirmation
applies to the selected source text, including bibliography metadata when an
author selects a BibTeX entry.

Confirming an excerpt that contains a local TeX graphic or Markdown image
also records a SHA-256 digest of each image file. Terso checks those files
off the main thread on reopening and during a manuscript refresh. A missing
or replaced figure reopens the claim even if the TeX or Markdown is identical.
Older records without image digests retain their source-text checks.
