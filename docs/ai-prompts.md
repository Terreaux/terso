# AI prompts and context

The prompt source of truth is [PromptBuilder](../Sources/TersoAI/Prompting.swift)
and [AssistantTask.instruction](../Sources/TersoAI/Provider.swift). The copies
below preserve their string content; placeholders describe runtime substitutions.
For provider execution and response handling, see [AI execution and review](ai-runtime.md).

## Shared editorial instructions

Every production adapter uses these editorial rules. Apple passes them directly
as session instructions; HTTP and CLI append the JSON reply contract.

```text
You are an editor helping a writer revise their own text. You never rewrite the whole text unasked, never invent facts, examples, sources or personal experiences, and never claim to detect authorship. You do not edit files; you only reply. Each suggestion's original text must be copied verbatim from the passage, short (a phrase or sentence), and unique within it. Propose a revision wherever the task applies; return no suggestions only if the passage truly needs none.
```

## HTTP / CLI system prompt

This is the full `PromptBuilder.system` text. HTTP places it in the system role
(or Anthropic's system field). CLI prepends it to the user prompt with two newlines.

```text
You are an editor helping a writer revise their own text. You never rewrite the whole text unasked, never invent facts, examples, sources or personal experiences, and never claim to detect authorship. You do not edit files; you only reply. Each suggestion's original text must be copied verbatim from the passage, short (a phrase or sentence), and unique within it. Propose a revision wherever the task applies; return no suggestions only if the passage truly needs none.

Reply with a single JSON object and nothing else:
{"message": "<your explanation or answer, plain prose>",
 "suggestions": [{"original": "<exact text copied from the passage>",
                  "proposed": "<replacement>",
                  "explanation": "<why, one or two sentences>",
                  "kind": "<clarity|concision|repetition|argument|ambiguity|grammar|wordiness|alternative>"}]}
Each "original" must be copied verbatim from the passage, short (a phrase or sentence), and unique within it. Use an empty suggestions list when none are needed.
```

## User prompt template

```text
Task: <AssistantTask.instruction>
Writer's question: <question>
Passage (<lowercased scope title>):
<<<PASSAGE
<context.text>
PASSAGE>>>
```

The question line is omitted when the question is nil or empty. The prompt ends
with a newline. Scope titles become `selection`, `current paragraph`,
`current section`, or `whole document`. Source markup is sent as-is: prose masking
used by local checks is not applied to AI context.

## Exact task instructions

| Task ID | Instruction |
|---|---|
| `ask` | Answer the writer's question about the passage. |
| `improveClarity` | Propose revisions that make unclear sentences clearer. Keep the writer's voice and meaning. |
| `makeConcise` | Propose revisions that remove words the passage does not need. Keep meaning and voice. |
| `explainUnclear` | Explain which parts of the passage a reader may find unclear and why. Suggest revisions only where they help. |
| `checkArgument` | Assess whether the argument holds: unsupported claims, gaps, leaps. Explain; propose revisions sparingly. |
| `findUnsupportedClaims` | Identify claims the passage asserts without evidence, example or attribution. Explain each briefly. Do not invent sources; suggest what kind of support would help. |
| `reviewStructure` | Assess the order and structure: does each part follow from the last, is anything out of place, repeated or missing? Explain; propose revisions only for transitions. |
| `findAmbiguity` | Identify ambiguous wording (pronouns, scope, terms) and explain each. Propose disambiguating revisions. |
| `suggestAlternatives` | Offer alternative phrasings for the passage, each as a separate suggestion on the same original text. |
| `proofread` | Correct spelling, grammar and punctuation only. Do not change style. |
| `reviewDocument` | Review the document as an editor. Propose the most valuable revisions (clarity, repetition, argument structure, wordiness). Label each with a kind. |

## Context construction and policy

[ContextPayload.make](../Sources/TersoAI/Provider.swift) clamps selection offsets
to the snapshot's UTF-16 bounds and extracts a contiguous substring:

| Scope | Actual source included |
|---|---|
| Selection | Selected range if nonempty; otherwise `NSString.paragraphRange` around the caret |
| Current paragraph | Expand over nonblank lines around the selection; stop at blank lines and trim trailing LF characters |
| Current section | Begin at the last recorded Markdown ATX heading before/at the caret; end at the next heading of equal or shallower level; before the first heading, begin at document start and end at that heading |
| Whole document | Entire snapshot |

Section scope uses ProseText's Markdown headings, not the separate science index's
LaTeX sections. Selection's empty-range fallback uses NSString paragraph semantics,
not the custom blank-line paragraph expansion. A `selectionOnly` policy checks the
scope enum, so this fallback can still send a caret paragraph without a highlighted
selection. Context preview is the place to inspect the actual text.

The standing policy permits only `.selection`, everything except `.document`, or
all scopes for `selectionOnly`, `upToSection`, or `wholeDocument`, respectively.
Default preferences are AI disabled, selection scope, and up-to-section access.
Whole-document access permits the action; it does not trigger it automatically.
See [Preferences](../Sources/TersoApp/Settings.swift).

ContextPayload holds scope, raw text, source range, revision, and optional filename.
The built-in prompt serializes only scope/text plus the task and optional question;
it does not serialize the filename, range, or revision. The context word-count
preview is whitespace splitting, not the prose tokenizer and not a model token
count. No prior exchanges, full science graph, statistics report, nearby files,
bibliography contents, or retrieval results are automatically appended.

## Issue-action prompts

[WorkspaceModel](../Sources/TersoApp/WorkspaceModel.swift) supplies additional
questions for actions on a local finding. `<message>` and `<explanation>` come from
the finding, with an empty string for a missing explanation.

**Explain** uses `explainUnclear`:

```text
A local check flagged this as “<message>”: <explanation>. Explain the problem in this passage in two or three sentences. Do not rewrite it.
```

**Suggest rewrite** uses `improveClarity`:

```text
A local check flagged this as “<message>”: <explanation>. Propose a revision that addresses it, keeping the meaning.
```

For these actions, scope is selection. The selected context is the first finding
range for block-level findings; otherwise it spans prose sentences intersecting
that first range, falling back to the range itself. It does not automatically send
all ranges of a repeated-word or multi-object finding.

**Try Another** rejects the existing proposal and uses `suggestAlternatives`:

```text
Propose one different revision of this passage. Do not repeat: “<previous replacement>”.
```

It uses the original finding's sentence context when still available, otherwise
the suggestion range. The previous replacement is embedded explicitly here; this
is not conversational memory. An explanation-only action still uses the shared
reply schema; there is no separate runtime rule that strips proposals by task.

## Apple's guided reply contract

[GeneratedReply / GeneratedSuggestion](../Sources/TersoAI/AppleFoundationModelProvider.swift)
replace the JSON schema instruction with `@Generable` types and these guides:

| Field | Guide |
|---|---|
| `message` | Your explanation or answer to the writer, in plain prose |
| `suggestions` | Proposed revisions; empty when none are needed (maximum count 8 per chunk) |
| `original` | Exact text copied verbatim from the passage; a phrase or one sentence |
| `proposed` | The replacement text |
| `explanation` | Why, in one or two sentences |
| `kind` | One of: clarity, concision, repetition, argument, ambiguity, grammar, wordiness, alternative |

The kind field is still a String. Apple's per-chunk user prompt uses the same task,
question, and scope title as above. Only the passage text changes to the chunk.
For the separate prompts used to generate style-evaluation corpora, see
[tests and evaluation](testing-and-evaluation.md).
