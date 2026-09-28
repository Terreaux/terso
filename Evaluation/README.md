# Evaluation

`terso-eval` measures the statistical style engine against labelled corpora. The
rule: **every change to a feature or threshold comes with a before/after report**
(`make compare`).

```
Evaluation/
  Corpora/Human/{development,calibration,heldout}/   fetched, git-ignored
  Corpora/AI/heldout/                                  generated, git-ignored
  Reports/     JSON reports from `terso-eval evaluate`
  PROVENANCE.md
```

## Method

- **Reference ranges:** General and fiction use Quirón's published band parameters
  (see `NOTICE`); they are not recalibrated here. Academic and technical use
  Terso-measured calibration bands, described below.
- **Feature code:** Terso's own, from the published definitions. Three features whose
  definition differs from the one that produced the parameters (mean sentence length,
  participial clauses, connective openers) are shown raw under Quirón-derived profiles;
  Terso-measured academic and technical profiles can band them.
- **Human corpus:** 240 dev.to posts published before 2022 (human by date), drawn
  from the all-time top lists of 20 tags, at most 3 per author, 191 authors. Split **by
  author**: 45 development, 129 calibration, 66 held-out.
- **AI corpus:** one post per held-out title at a similar length, from the plain prompt
  "Write a blog post for dev.to titled …". Generated with Apple's on-device model (66,
  free) and Codex CLI (12).
- **Threshold:** ELEVATED at 5 or more features outside the human range on the AI side.
  Checked on development + calibration (174 texts): 4.0% of human posts reach it. It was
  not tuned on held-out.

## Results (2026-09-26, held-out)

| Set | n | LOW | MODERATE | ELEVATED | Mean AI-side features |
|---|---|---|---|---|---|
| Human posts | 66 | 71% | 20% | **9.1%** | 1.67 |
| Apple on-device model | 66 | 0% | 5% | **95.5%** | 7.86 |
| Codex CLI | 12 | 0% | 0% | **100%** | 6.50 |

Strongest separators, on-device samples vs held-out humans (AUC): dashes 1.00, lists of
three 0.96, MATTR 0.95, long words 0.94, mean word length 0.94, nominalizations 0.93,
commas 0.89, participial clauses 0.85. First person runs strongly the other way (0.11).

## Registers measured by Terso

General (blog) and Fiction use Quirón's published parameters. **Academic** and
**Technical** are Terso's own measurements (`terso-eval calibrate` on the calibration
split; parameters in `Sources/TersoStyle/Resources/bands-{academic,technical}.json`,
corpus details in `PROVENANCE.md`). Because Terso's feature code measured them, every
feature is banded, including the three shown raw under the Quirón-derived bands.

| Held-out set | Human n | Human ELEVATED | Human LOW | AI n | AI ELEVATED |
|---|---|---|---|---|---|
| Academic introductions, **academic bands** | 48 | **2.1%** | 92% | 37 | 89% |
| Academic introductions, general bands | 48 | 66.7% | 0% | 37 | 100% |
| Documentation pages, **technical bands** | 48 | **6.2%** | 75% | 40 | 100% |
| Documentation pages, general bands | 48 | 12.5% | 38% | 40 | 100% |

The general rows show why registers matter. Blog ranges would have rated two
thirds of genuine research introductions ELEVATED: academic prose naturally has
longer words (median 361 per 1k vs 197), more nominalizations (57 vs 20) and less
first person.

What separates the on-device model's text from human text differs by register.
Academic: parentheses and citations (AUC 0.03, human higher) and uneven sentence
lengths (0.02). Technical: lists of three (1.00), lexical diversity (0.99), word
length (0.98).

Limits: the AI reference is one small on-device model, so directions and AI medians
describe *its* style. Academic texts are life-science-heavy (Europe PMC). The
technical corpus is three projects' documentation. Business writing has no
measurement yet.

## How to read this

- **False positives:** 9.1% of held-out human posts are ELEVATED (6 of 66; roughly 3–19%
  at 95% confidence). The tuning splits gave 4.0%. At this sample size the true rate
  lies somewhere between.
- **Detection:** the samples are easy. Unedited output from a small on-device model and
  from Codex, in one register. Quirón's own tests found recent frontier models (Claude
  Opus) inside the human ranges on most features. A LOW level therefore says little about
  who wrote a text, and the app says so.
- **No probability:** the level counts features outside a range. It is not a probability
  and does not determine authorship.
- **Register:** ranges exist for general (blog), fiction, academic, and technical
  writing. Business currently shows raw values with no range.

## Reproduce

```sh
make corpus                    # human corpus (dev.to API), split by author
make corpus-academic corpus-technical ai-corpus-academic ai-corpus-technical
make calibrate-academic evaluate-academic   # same for technical
make ai-corpus AI_LIMIT=66     # AI counterparts with the on-device model (free)
make evaluate LABEL=after      # → Evaluation/Reports/after.json
make compare BEFORE=Evaluation/Reports/before.json AFTER=Evaluation/Reports/after.json
```

`make ai-corpus-codex` uses Codex CLI instead and spends Codex tokens.

For exact feature formulas, calibration semantics, AI generation prompts, and the
distinction between corpus evaluation and suggestion tests, see
[technical evaluation documentation](../docs/testing-and-evaluation.md).
