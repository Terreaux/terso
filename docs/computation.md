# Computation pipeline

## Snapshot and source coordinates

[DocumentSnapshot and TextSpan](../Sources/TersoCore/Model.swift) bind a string to
a revision and use UTF-16 offsets, matching `NSString` and AppKit. They do not use
Swift grapheme indices or UTF-8 byte offsets. Every annotation ultimately points
back into this source string.

[WorkspaceModel.scheduleAnalysis](../Sources/TersoApp/WorkspaceModel.swift) cancels
the previous analysis, captures a snapshot, writing domain, and science profile,
and runs work in a detached utility task. Typing increments the document revision
and debounces analysis by 400 ms. Publication requires both the captured revision
and analysis-generation UUID to remain current. The generation check also protects
against a profile change without a text edit. Spelling callbacks use the same gates.

The current pass constructs prose for sentence spans/spelling, a WritingAnalyzer
context, and a StyleEngine context separately; it does not cache one shared parse
across all three consumers. Within WritingAnalyzer, rules share an AnalysisContext.

## Prose extraction and tokenization

[ProseText](../Sources/TersoCore/ProseText.swift) replaces excluded source with
spaces while retaining UTF-16 length and line boundaries. This lets a match in
masked text identify the original source without an offset translation table.

The mask excludes front matter, code, non-prose scientific regions, ATX headings,
horizontal rules, setext underline lines, pipe-led table lines, images, HTML tags,
URLs, inline code, and formatting markers. Markdown link labels remain; their
brackets and targets disappear. ScientificSyntax handles TeX before the remaining
Markdown passes. This is a bounded scanner and regex pipeline, not a complete
CommonMark or TeX interpretation. In particular, setext title text is not recorded
as an ATX heading.

Blank lines end prose blocks. List items begin separate blocks; consecutive quote
lines can share a quote block. Consequently the statistics label “paragraphs”
counts prose blocks, including list items and quotes.

Words match `[\p{L}\p{N}]+(?:['’\-][\p{L}\p{N}]+)*`: letters/numbers with internal
apostrophes or hyphens. Sentence boundaries are terminal punctuation (`.!?…`),
optional closing quotes/brackets, then whitespace or block end. Common
abbreviations and initials suppress period boundaries; a decimal point between
digits is not followed by whitespace. An unpunctuated block tail is a sentence
when it contains words. These English-oriented heuristics affect every downstream
count.

## Document statistics

[DocumentStatistics and Readability](../Sources/TersoCore/Readability.swift) use:

| Value | Calculation |
|---|---|
| Words / sentences / paragraphs / headings | Counts from ProseText |
| Characters | `original.count` (Swift Characters, including markup) |
| Characters without spaces | Non-whitespace Unicode scalars in original source; a different unit from Characters |
| Syllables | Sum of heuristic syllable counts over prose words |
| Reading minutes | `words / 238.0`; label is `—` for empty, `< 1 min` below one minute, otherwise rounded minutes |
| Flesch–Kincaid grade | `0.39 × W/S + 11.8 × Y/W − 15.59` |
| Flesch reading ease | `206.835 − 1.015 × W/S − 84.6 × Y/W` |

Here `W` is words, `S` sentences, and `Y` syllables. Both formula functions return
zero when words or sentences are zero. The document grade is absent below 30
words or two sentences and otherwise clamped at zero. Reading ease is available
as a Core function; that does not imply every statistic is displayed in the UI.

Syllables are vowel-group counts after lowercasing and removing nonletters, with
`y` treated as a vowel. Short words get one syllable; terminal `e`, `es`, and `ed`
receive exceptions/corrections. This is a heuristic, not dictionary pronunciation.

## Local writing rules

[WritingAnalyzer](../Sources/TersoAnalysis/WritingAnalyzer.swift) runs the default
rules in order, checks cancellation between rules, then sorts issues by source
span. [Rules.swift](../Sources/TersoAnalysis/Rules.swift) defines the thresholds and
phrase lists:

| Rule | Trigger |
|---|---|
| Sentence difficulty | Only sentences of at least 14 words; hard at 25 words **or** grade ≥ 12; very hard at 40 words **or** grade ≥ 16 |
| Passive voice | `be`/`get` auxiliary forms, up to two intervening adverbs/negators, then a recognized past participle |
| Adverbs | Regex `-ly` candidates minus an exception list; at least two hits and at least eight per 1,000 prose words |
| Qualifiers | Case-insensitive whole-phrase lookup against the fixed qualifier list |
| Filler phrases | Fixed phrase lookup, sometimes with a shorter `consider` alternative |
| Complex words | Fixed word/phrase lookup with a plainer alternative |
| Doubled words | Adjacent equal lowercased tokens with source gap ≤ 2; excludes numbers, `that`, and `had` |
| Repeated content words | Tokens of length ≥ 6 outside the stopword list, at least three occurrences within a 40-token index window |
| Repeated phrases | Sentence-contained 6- through 3-grams; at least two nonoverlapping occurrences, at least one non-stopword; longer reported phrases claim their word indices first |
| Sentence rhythm | At least four sentences in a block and population SD / mean length < 0.2 |
| Paragraph length | More than 150 words in a prose block |
| Science categories | Notation, quantities, references, claims, evidence; see [scientific analysis](scientific-analysis.md) |

[PassiveDetector](../Sources/TersoCore/Passive.swift) recognizes listed irregular
participles or regular words longer than four characters ending in `ed`, with an
adjectival exception list. It is shared with the statistical passive feature;
it is not a syntactic dependency parser. Phrase-rule matches tolerate whitespace
between phrase words. These findings are editorial heuristics; e.g. a qualifier
or passive construction can be intentional.

## Spelling and presentation

[SpellingLayer](../Sources/TersoApp/Editor/SpellingLayer.swift) requests asynchronous
spelling and grammar checks from `NSSpellChecker` on the original text. It retains
only results whose range is unchanged by the prose mask and displays up to three
suggested corrections. Results depend on the system dictionary/checker.

Findings become [TextAnnotations](../Sources/TersoCore/Model.swift).
[ReviewGrouping](../Sources/TersoCore/ReviewPassage.swift) groups them into passages;
[AnnotationLayout](../Sources/TersoCore/AnnotationLayout.swift) handles ordering and
overlap. Layer switches, dismissals, focus mode, and temporary editor decorations
change presentation, not source text. AI suggestions use a separate anchoring and
acceptance path described in [AI execution and review](ai-runtime.md).

## Offline dictionary alternatives

[OfflineThesaurus](../Sources/TersoAnalysis/OfflineThesaurus.swift) is a separate
local suggestion source. Its actor lazily loads bundled WordNet senses from JSON,
indexes each sense under its lowercased words, and caches that index. Lookup is an
exact lowercased dictionary lookup, with no stemming or contextual model ranking.
Alternatives exclude the queried word case-insensitively and mirror all-uppercase
or initial-capital casing. Definitions and examples come from WordNet rather than
AI; [resource provenance](../Sources/TersoAnalysis/Resources/WordNet/SOURCE.txt)
records the dataset and build script. Dictionary alternatives do not run through
the AI prompts or provider adapters.
