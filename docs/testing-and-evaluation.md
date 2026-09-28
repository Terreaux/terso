# Tests and evaluation harnesses

Terso has separate harnesses for code contracts, opt-in live provider round trips,
and statistical style-corpus evaluation. A good result in one does not establish
quality in another. In particular, `terso-eval` does not grade editing suggestions.

## Offline contract tests

Run from the repository root on a supported macOS/Swift toolchain:

```sh
make test
# Focused examples:
swift test --filter TersoAITests
swift test --filter TersoDocumentTests
swift test --filter TersoAnalysisTests
swift test --filter TersoStyleTests
```

| Tests | Contracts exercised |
|---|---|
| [CoreTests](../Tests/TersoCoreTests/CoreTests.swift), [ScientificSyntaxTests](../Tests/TersoCoreTests/ScientificSyntaxTests.swift) | Prose/statistic primitives, source coordinates, math/code masking |
| [RuleTests](../Tests/TersoAnalysisTests/RuleTests.swift) | Local writing heuristics |
| [ScientificTests](../Tests/TersoAnalysisTests/ScientificTests.swift), [ScientificDebuggerTests](../Tests/TersoAnalysisTests/ScientificDebuggerTests.swift), [QuantityDiagnosticsTests](../Tests/TersoAnalysisTests/QuantityDiagnosticsTests.swift) | Scientific indexes, diagnostics, relationships, conservative quantity matching |
| [StyleTests](../Tests/TersoStyleTests/StyleTests.swift) | Feature values, profiles, reliability, bands, specificity |
| [AITests](../Tests/TersoAITests/AITests.swift) | Scope extraction, data policy, prompt containment, parsing, ambiguous/missing originals, HTTP shape/key/locality, CLI stdin/workspace cleanup/timeout, Apple paragraph chunking |
| [InvariantTests](../Tests/TersoDocumentTests/InvariantTests.swift) | Suggestions remain inert until accepted; relocation/staleness and bulk-review gates |
| [DocumentSessionTests](../Tests/TersoAppTests/DocumentSessionTests.swift) | Document-local AI/analysis lifetime and cross-document isolation |
| [ReviewScaleTests](../Tests/TersoAnalysisTests/ReviewScaleTests.swift) | Larger-document review/science behavior |

The CLI contract test uses a controlled executable, not a hosted model. HTTP
request-shape tests do not prove live authentication, endpoint availability, model
access, or model quality. System NaturalLanguage and spelling behavior may vary
with the OS; fixture tests do not remove that dependency.

## Opt-in live provider checks

```sh
make test-live        # TERSO_LIVE_APPLE=1; on-device round trip
make test-live-codex  # TERSO_LIVE_CODEX=1; real CLI, consumes provider usage
```

The live tests are gated by environment variables in
[AITests.swift](../Tests/TersoAITests/AITests.swift) and disabled in the ordinary
suite. They exercise a small real request through proposal anchoring. They are
smoke tests, not a representative benchmark of factual preservation, voice,
argument assessment, robustness, or all task/provider combinations. There is no
comprehensive automated editorial-quality evaluation harness in this repository.

## Statistical evaluation CLI

[terso-eval](../Sources/terso-eval/main.swift) supports:

```text
terso-eval measure DIR [--out FILE.json]
terso-eval calibrate --human DIR [--ai DIR] --out BANDS.json [--source TEXT]
terso-eval evaluate --human DIR [--ai DIR] [--bands BANDS.json] [--label NAME] [--out REPORT.json]
terso-eval compare BEFORE.json AFTER.json
```

Input enumeration is nonrecursive, sorted by filename, and accepts `.md`, `.txt`,
and `.markdown`. Texts below 120 prose words or eight retained style sentences
are skipped. Check usable-text counts rather than counting directory entries;
unreadable files and `.part` files are not evaluated.

Calibration requires at least 20 usable human texts. For sorted values of length
`N`, percentile `p` uses index `min(Int(p × N), N − 1)` with no interpolation.
Thus `p50` is the upper middle order statistic for even N. The separate median
helper used for AI/report medians averages the two middle values for even N.

AUC here is the fraction of AI/human pairs where the AI value is greater, with
half credit for ties. It is a **single-feature directional statistic**, not an
aggregate model score. Calibration sets `push = hi` at AUC ≥ 0.6, `lo` at AUC ≤ 0.4,
and undetermined between them. Without an AI corpus, direction remains unknown.

Evaluation uses the same StyleEngine as the app. Its report includes each usable
text's level, AI-side count/features, group label, and word count, plus per-feature
human/AI medians, AUC, and human outside-band rate. The outside rate counts both
sides using the band's slack; it can be reported for a stored band even when that
feature is excluded from the aggregate by `isBanded`. An empty report group has a
computed rate of zero, which should not be interpreted as evidence of zero errors.

## Corpora and generation prompts

[Evaluation/PROVENANCE.md](../Evaluation/PROVENANCE.md) records the corpus sources
and splits. General human data is split by author, academic by journal, and
technical data comes from pinned pre-2022 project documentation. Academic and
technical calibration use their calibration splits; held-out data is for evaluation.
[Evaluation/README.md](../Evaluation/README.md) contains dated historical results
and their limitations; they are not new results from running these docs.

[scripts/generate-ai-corpus.sh](../scripts/generate-ai-corpus.sh) reads a title and
word count from `titles.tsv`, clamps requested length to 600–1,400 words, and uses
one of these prompt templates (`{words}` is the clamped value):

```text
Write a blog post for dev.to titled "{title}". Around {words} words. Reply with the post in Markdown only.

Write the introduction section of a research article titled "{title}". Around {words} words. Reply with the introduction as plain paragraphs only: no title, no headings, no reference list.

Write a documentation page titled "{title}" for an open-source software project. Around {words} words. Reply with the page in Markdown only.
```

The first is the script default; the other two come from the [Makefile](../Makefile).
The generator skips existing nonempty outputs, writes `.part` files before moving
successful output into place, and uses a temporary directory. Its default is Codex
CLI; `TERSO_AI_CMD` overrides this with a shell command reading stdin. That shell
hook belongs to the developer corpus script, not the app's shell-free CLI adapter.
`make ai-corpus` sets it to [terso-fm](../Sources/terso-fm/main.swift), a plain
FoundationModels session returning generated prose. This bypasses the editorial
PromptBuilder, suggestion schema, and review gate: it generates comparison texts,
not revisions of user passages.

## Reproduce and change measurements

With the corpora already present:

```sh
make evaluate LABEL=before
# After a feature/threshold change:
make evaluate LABEL=after
make compare BEFORE=Evaluation/Reports/before.json AFTER=Evaluation/Reports/after.json

make calibrate-academic
make evaluate-academic
make calibrate-technical
make evaluate-technical
```

Calibration targets overwrite shipped band resources. Use them deliberately on
calibration data and review the resulting parameter changes. For data acquisition
or new generated samples, the Makefile exposes `corpus`, `corpus-academic`,
`corpus-technical`, `ai-corpus`, `ai-corpus-codex`, `ai-corpus-academic`, and
`ai-corpus-technical`; those fetch data or invoke real models.

Feature or threshold changes require before/after reports under the existing
Evaluation policy. Compare the same corpus, split, provider sample set, and band
choice to isolate code effects. Report false positives as human texts reaching
Elevated, together with sample counts and register. AI-side separation in these
corpora does not establish authorship detection in arbitrary writing.

For prompt/provider changes, run relevant offline contracts and explicitly label
any live validation separately. A future editorial benchmark would need labeled
passages, expected or acceptable edits, factual/voice preservation criteria, and
provider/task coverage; those are not supplied by the style-corpus reports.
