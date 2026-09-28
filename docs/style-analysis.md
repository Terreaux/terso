# Statistical style analysis

[StyleEngine](../Sources/TersoStyle/StyleEngine.swift) measures local source text
and compares it with a selected register's reference bands. No language-model
request is involved in “AI-style signals.” The result is a count of stylistic
features, not a probability of authorship.

## Feature inputs and formulas

[StyleContext and FeatureCatalog](../Sources/TersoStyle/Features.swift) use the
same masked prose as local analysis, with three distinctions:

- `words` includes all lowercased prose tokens, including short sentences.
- `sentences` includes only prose sentences with at least three words.
- `letterWords` splits tokens at hyphens, removes nonletters, and drops empty pieces.

Let `W` be the number of words and `S` the number of retained sentences. Unless
specified otherwise, a rate is `1000 × count / W`, or zero when `W = 0`.
Population standard deviation divides by `N`, not `N − 1`.

| Feature ID | Measurement |
|---|---|
| `cv_sentence_len` | Population SD of retained sentence lengths / mean; zero when mean is zero |
| `mean_sentence_len` | Mean retained sentence length |
| `long_words_1k` | 1,000 × letterWords of length ≥ 7 / number of letterWords |
| `mean_word_len` | Mean length of letterWords |
| `nominalizations_1k` | Tokens of length ≥ 7 ending in `tion(s)`, `sion(s)`, `ment(s)`, `ness(es)`, or `ity`/`ities`, per 1,000 words |
| `ly_adverbs_1k` | Tokens of length ≥ 6 ending in `ly`, per 1,000 words; does not use the writing rule's exception list |
| `passive_1k` | Shared PassiveDetector matches per 1,000 words |
| `mattr50` | Average distinct-token fraction over every sliding 50-word window; zero for fewer than 50 words |
| `first_person_1k` | `i me my mine myself we us our ours ourselves` matches per 1,000 words |
| `contractions_1k` | Regex matches with apostrophe suffix `s/re/ve/ll/d/m/t`, per 1,000 words |
| `questions_1k` | Retained sentences whose original source slice ends exactly in `?`, per 1,000 words |
| `repeated_openers` | 100 × consecutive equal first-token pairs / `max(S − 1, 1)` |
| `connective_openers` | 100 × retained sentences beginning with a listed connective / `max(S, 1)` |
| `commas_1k` | Commas in masked prose per 1,000 words |
| `semicolons_1k` | Semicolons in masked prose per 1,000 words |
| `em_dashes_1k` | Both em and en dashes in masked prose per 1,000 words |
| `triads_1k` | Regex candidates `A, B(,) and/or C`, with short items and excluded clause-start words, per 1,000 words |
| `participles_1k` | `-ing` candidates after comma/semicolon/colon/dash, retained only when NaturalLanguage tags the candidate as a verb, per 1,000 words |
| `parens_1k` | Opening parentheses in masked prose per 1,000 words |
| `para_words` | W / `max(number of blocks containing a retained sentence, 1)` |
| `headings_1k` | Recorded ATX headings per 1,000 prose words |

MATTR-50 is `Σ distinct(window) / (50 × (W − 49))`. Contributing source ranges are
navigation aids, not always a one-to-one accounting of the numeric value. For
example, long-word rates use split letterWords, while their highlighted ranges
exclude hyphenated tokens. Quoted questions ending in a closing quote do not pass
the exact `hasSuffix("?")` test.

## Reference bands and signal levels

[Baselines.swift](../Sources/TersoStyle/Baselines.swift) loads JSON resources with
human `p10`, `p50`, `p90`, `min`, `max`, and optional AI median, AUC, and `push`
direction (`hi`, `lo`, or undetermined).

| Domain | Shipped reference |
|---|---|
| General | Quirón-derived blog bands |
| Fiction | Quirón-derived short-story bands |
| Academic | Terso-measured bands |
| Technical | Terso-measured bands |
| Business | No shipped band resource; raw measurements only |

See [resource files](../Sources/TersoStyle/Resources) and [NOTICE](../NOTICE) for
parameters and attribution. For Quirón-derived bands, `mean_sentence_len`,
`participles_1k`, and `connective_openers` remain unbanded because Terso's measuring
procedure differs. Profiles marked as measured by Terso allow all available bands.
The decoder currently treats presence of `_measured_by` as that marker.

Comparison includes slack: `margin = 0.05 × (p90 − p10)`. A feature is below the
band only when `value < p10 − margin`, above only when `value > p90 + margin`,
and inside otherwise. `min`/`max` and the AI median do not set these boundaries.
A feature counts on the AI side only if above with `hi`, or below with `lo`.
There are no weights or learned aggregate classifier.

| AI-side feature count | Level |
|---|---|
| 0–2 | Low |
| 3–4 | Moderate |
| ≥ 5 | Elevated |

No profile, fewer than 120 words, or fewer than eight retained sentences suppresses
the aggregate level as insufficient. At 120–399 words (with enough sentences),
comparison is limited; from 400 words it is adequate. Raw measurements still
exist when the level is suppressed. These gates do not independently suppress all
feature annotations: annotation creation checks each feature's AI-side position
and requires 1–60 contributing ranges. Specificity annotations are separate.

## Experimental specificity

[SpecificityAnalyzer](../Sources/TersoStyle/Specificity.swift) examines prose blocks
of at least 20 words. It counts numbers, month names, named entities from
NaturalLanguage, citation/link patterns, quotations, and stated uncertainty.
Citation patterns are matched against original markup; most other patterns use
the mask. Markers can overlap (a year may contribute to more than one kind).

`markersPer100 = 100 × total marker count / block words`.
A block is generic at ≥ 30 words, fewer than one marker per 100 words, and at least
two stock-framing matches. A block is concrete at ≥ 20 words and at least three
markers per 100 words. Concrete blocks are sorted by marker density. Generic
blocks produce informational annotations. These thresholds are provisional and
uncalibrated; they do not establish factual accuracy.

For calibration formulas and regression commands, see [tests and evaluation](testing-and-evaluation.md).
