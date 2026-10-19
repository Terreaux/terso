# Terso

A local-first writing instrument for macOS. It's a quiet Markdown editor first,
with deterministic writing analysis, statistical style analysis, and an optional
AI assistant that can only propose changes.

```
WRITING → LOCAL ANALYSIS → STATISTICAL STYLE ANALYSIS → OPTIONAL AI ASSISTANCE
```

Terso works fully with no network, no API key and no AI model.

## Build and run

Requires macOS 15+ and Swift 6 (Xcode 16 or later).

```sh
make help        # list targets
make test        # unit tests
make run         # build build/Terso.app and open Samples/essay.md (DOC=… for another file)
make app         # just build the .app (CONFIG=debug for a debug build)
make dmg         # build build/Terso-<version>-<architecture>.dmg and SHA-256 checksum
make test-live   # opt-in: live test against Apple's on-device model (free, local)
make test-live-codex   # opt-in: live Codex CLI round-trip (spends Codex tokens)
make corpus ai-corpus evaluate LABEL=after   # evaluation harness; AI samples via the on-device model
make compare BEFORE=Evaluation/Reports/before.json AFTER=Evaluation/Reports/after.json
```

`scripts/bundle.sh` wraps the SwiftPM executable in an `.app` with the `Info.plist`
document types (`.md`, `.markdown`, `.tex`, `.txt`) used by AppKit document handling.
Documents share one window through [in-window tabs](Documentation/DocumentTabs.md),
with separate editor state and undo history for each document.

[Writing Exercises](Documentation/WritingExercises.md) offers eight offline prompts
in a native sheet. Open it from Tools; optional suggestions start off in Settings.

## Download a build

The **Build DMG** GitHub Actions workflow tests the app and uploads a
`Terso-macOS-arm64` artifact on pushes to `main`, version tags (`v*`), pull requests
to `main`, and manual runs. Download the artifact from the run's summary, unzip
it, open the DMG, and drag Terso into Applications. Artifacts are retained for 30 days.
These builds require Apple silicon and macOS 15 or later.

The app is ad-hoc signed, not Developer ID signed or notarized. macOS may block
the downloaded app until you approve it in System Settings → Privacy & Security.
The local `make dmg` target packages the architecture of the Mac running it.

## Technical documentation

See [docs/README.md](docs/README.md) for computation formulas, scientific analysis,
exact AI prompts and context, provider execution, suggestion review, and evaluation harnesses.

## Architecture

| Module | Role | Can mutate the document? |
|---|---|---|
| `TersoCore` | `TextSpan` (UTF-16), `DocumentSnapshot` + revision, `TextAnnotation`, `WritingIssue`, `WritingSuggestion`, `AnchorResolver`, Markdown-aware `ProseText` | no, value types only |
| `TersoAnalysis` | `WritingRule`s: sentence difficulty, passive voice, adverbs, qualifiers, filler, complex words, repeated words and phrases, rhythm, paragraph length, statistics | no |
| `TersoStyle` | `StatisticalFeature`s, human `ReferenceBand`s per `WritingDomain`, AI-style signal level, specificity analysis | no |
| `TersoAI` | `WritingAssistantProvider`: Apple's on-device model (default, free, local), CLI (Codex, Claude Code), OpenAI, Anthropic, OpenAI-compatible local servers (Ollama, LM Studio, llama.cpp); `AIDataAccess` policy; Keychain | no; it **cannot import** `TersoDocument` |
| `TersoDocument` | `SuggestionReview`, the review gate; `PlainTextCodec` | yes, only via `accept` |
| `TersoApp` | SwiftUI + AppKit/TextKit editor, inspector, settings | user edits |
| `terso-eval` | evaluation harness | n/a |

### AI never silently modifies the document

This is enforced by structure, not convention:

1. Providers receive a `ContextPayload`: the text of the scope the writer chose
   (selection, paragraph, section or document), shown with its word count before sending.
2. They return `ProposedRevision`s as data. `SuggestionBuilder` anchors each one to an
   exact span and drops any whose original text isn't found exactly once.
3. `SuggestionReview.accept` is the only code path that edits text. It re-resolves the
   anchor against the **current** text. If the text moved, it relocates the passage by
   context. If the passage changed or is ambiguous, it marks it stale and refuses.
   An old offset is never applied blindly.
4. Accept All exists only in Review Document mode, after the suggestions were shown.
5. `TersoAI` has no dependency on `TersoDocument`, so provider code can't reach a
   mutation target. `Tests/TersoDocumentTests/InvariantTests.swift` covers the
   invariant.

CLI agents run in a throwaway directory holding only the passage. The prompt goes on
stdin, never in a shell string. They get a minimal environment, a timeout and
cancellation. Codex runs with `--sandbox read-only`, and Claude Code with editing tools
disallowed. The workspace is deleted afterwards. The user's file path is never passed.

### Annotations and Review

Findings are drawn in three states. **Passive:** a thin underline in one of four
families (writing analysis, spelling & grammar, AI suggestions, AI-style signals), each
with its own line pattern, so colour is never the only cue. Whole sentences that are hard
to read get a faint tint, and paragraph-level findings appear only in the issue rail.
**Hover:** a stronger underline and a short tooltip. **Selected:** only the selected
finding's exact range is filled. Overlapping findings are drawn once (`AnnotationLayout`
clusters them) and stay independent in the inspector ("3 findings here"). Everything is a
temporary attribute on the layout manager, never part of the text or the undo stack.

The inspector is **Review | Assistant | Science | Statistics**. Review lists findings in document
order; the selected one expands in place with its quoted text, explanation and actions
(Explain, Suggest rewrite, Ignore). AI results for a finding appear with it, and nothing
runs until you ask. Layers live behind **Filter**. AI-style signals are not painted by
default: *Statistics → Explore Signals* turns that layer on.

## Statistical style analysis

Features are standard measures from the register and style literature (Biber 1988;
Covington & McFall 2010; Reinhart et al. 2025), implemented in `TersoStyle/Features.swift`.
General and fiction use Quirón-derived reference-range parameters (human percentiles,
AI medians and directions per feature); academic and technical use Terso-measured
bands. Terso reports
**AI-style signals: Low / Moderate / Elevated**, a count of features outside the human
band on the side where AI text of that register sits. It is not a probability.

> This measures stylistic patterns associated with AI-generated prose. It does not determine authorship.

Registers without measured data (currently business) show raw values and say so.
Terso doesn't invent baselines. See [`Evaluation/README.md`](Evaluation/README.md)
for methodology, corpus hygiene, held-out results and limitations.

## Keyboard

| | |
|---|---|
| ⌘⇧E | Review Writing — step through findings one at a time |
| ⌘] / ⌘[ | Next / previous finding (document and Review stay in sync) |
| ⌘' | Show the finding at the cursor |
| ⌥⌘R | Suggest a rewrite for the selected finding (AI, when enabled) |
| ⌘⇧F | Letterbox (hides chrome and annotations, dims other paragraphs, typewriter scrolling) |
| ⌘⇧Y | Typewriter scrolling |
| ⌘⇧J | Zen (Letterbox in full screen) — pressing a mode's shortcut again returns to Hemingway, the default view |
| ⌘⇧M | Manutius (the text set as book pages: justified, hyphenated, numbered, still editable; its header menu sets trim, chapter openers and headings, drop caps, scene breaks, running heads, folios and large print) |
| ⇧⌘B | Whole Book (in Manutius: every page as spreads; click one to turn to it) |
| ⌘⇧A | Ask about selection… |
| ⌘⇧R | Review document with AI |
| ⌥⌘↓ / ⌥⌘↑ | Next / previous AI suggestion |
| ⌘B ⌘I ⌘E ⌘K | Bold, italic, code, link |
| ⌥⌘1–3 | Headings |

## On-device AI

When Apple Intelligence is available (macOS 26+, Apple silicon), the default assistant is
Apple's on-device model through the FoundationModels framework. It needs no key, uses no
network and costs nothing. Suggestions come back as typed values through guided generation
(`@Generable`) with greedy decoding. Long passages are split into paragraph-aligned
parts targeting 700 words; a single oversized paragraph can still exceed the model
context window. See [AI execution and review](docs/ai-runtime.md) for the exact limits.

## Privacy

No telemetry. Documents stay local as plain files. AI is off until enabled and sends
only the context you choose, when you ask, within the AI data access limit (default: up to
the current section). Each provider is labelled LOCAL or NETWORK.
API keys live in the macOS Keychain.

## Licence

AGPL-3.0-only. See `NOTICE`.
