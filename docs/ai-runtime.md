# AI execution and review

The app makes one explicit editorial request at a time per document session.
There is no Terso-managed retrieval pipeline, model tool loop, automatic repair
request, provider fallback after failure, or retry/backoff loop. Apple chunking
can make several sequential generations for one request. External CLI tools can
have their own behavior and configuration.

## Request lifecycle

[WorkspaceModel.runAI/startAI](../Sources/TersoApp/WorkspaceModel.swift):

1. Require AI enabled, a selected provider, and an editor snapshot/selection.
2. Check `AIDataAccess.permits(scope)`; a denied action records an error and sends nothing.
3. Build immutable context and capture the source snapshot and originating model.
4. Cancel the previous AI task in this document session and call `provider.analyze`.
5. Check cancellation, anchor returned proposals against the captured request snapshot,
   and add suggestions to the originating review state.
6. A `reviewDocument` task calls `beginReview`, replacing existing review state;
   other tasks append suggestions. Issue-specific actions store their message and
   suggestion IDs beside the issue; general requests update the Assistant exchange.

The destination is the captured document model, not the currently active tab.
Typing does not automatically cancel AI. A reply can arrive for older source;
its suggestions must then resolve against current text before acceptance.
`startAI` is a lower-level entry point and assumes its caller already applied the
UI policy; providers themselves do not enforce `AIDataAccess`.

## Provider adapters

| Adapter | Input/output and execution |
|---|---|
| Apple FoundationModels | New `LanguageModelSession` per chunk; editorial rules as instructions, user prompt as input, typed `@Generable` reply; greedy sampling |
| OpenAI-compatible HTTP | POST `<baseURL>/chat/completions`, configured model, one system and one user message; read first choice's string message content |
| Anthropic HTTP | POST `<baseURL>/messages`, configured model, separate system text, one user message, `max_tokens: 4096`, `anthropic-version: 2023-06-01`; concatenate text content blocks |
| CLI | Combined system + user prompt on stdin, argument vector through Foundation Process; response from stdout or configured output file |
| ScriptedProvider | Test closure returning text, passed through the same response parser; no network |

HTTP uses a default 120-second request timeout, accepts 2xx responses, and reports
non-2xx bodies through a bounded error description. It requests neither streaming
nor server-enforced JSON schema. The OpenAI-compatible body does not specify a
max-token count or temperature. Configuration owns model names; default strings
in source are presets, not a promise of model availability. Keys are read from
macOS Keychain accounts `apikey.<provider-id>` under service
`org.terso.Terso.providers`, not embedded in prompts.

Apple requires a build with FoundationModels, macOS 26+, and an available system
model. It splits on double newlines with a target of 700 whitespace-delimited words,
preserving paragraphs. A single oversized paragraph is **not** subdivided, and
there is no token-budget calculation. Each chunk sees only itself, the same task,
and question. Guided output allows at most eight suggestions per chunk; messages
and proposals are concatenated. Final anchoring checks uniqueness across the
original full selected context, not just the chunk. Context-window and guardrail
errors are surfaced without an automatic smaller-chunk retry. Greedy sampling is
a decoding choice, not a cross-model/OS reproducibility guarantee.

Sources: [HTTPProviders](../Sources/TersoAI/HTTPProviders.swift),
[AppleFoundationModelProvider](../Sources/TersoAI/AppleFoundationModelProvider.swift).

## CLI harness

[CLIProvider](../Sources/TersoAI/CLIProvider.swift) resolves the executable through
PATH and known install locations, creates a `terso-ws-<UUID>` temporary directory,
and writes the selected source as `passage.md`. It substitutes `{workspace}` and
`{output}` (`reply.txt`) in configured arguments, then starts a process without a
shell. Default argument vectors are:

```text
codex exec --sandbox read-only --skip-git-repo-check --ephemeral --color never -C {workspace} -o {output} -
claude -p --output-format text --disallowedTools Bash,Edit,Write,NotebookEdit,WebFetch,WebSearch
```

Codex reads the reply file, falling back to stdout if reading fails; Claude reads
stdout. Nonzero exit status is an error. Default timeout is 180 seconds. Timeout
and cancellation call `Process.terminate()`; there is no explicit descendant-tree
kill or kill-after-grace escalation. Stdout/stderr accumulate in memory.

Environment is an explicit set: HOME, constructed PATH, LANG, TERM, NO_COLOR,
optional USER/TMPDIR, plus configured extras (which can override defaults). HOME
allows tools to find their login/configuration. The temporary workspace is removed
on return using best-effort cleanup.

Terso does not pass the source document's filesystem path. That and the module
boundary protect the app's direct mutation path; a disposable working directory
is not a complete OS filesystem sandbox. External tool configuration, the Codex
sandbox, and Claude's listed tool restrictions still determine external process
capabilities. CLI providers are labelled NETWORK. HTTP locality is inferred only
from the base URL's loopback host; it cannot verify what a local server forwards.

## Parse and anchor

[ResponseParser](../Sources/TersoAI/Prompting.swift) tries the trimmed full reply,
a JSON code-fence candidate, then the substring from the first `{` to the last `}`.
It decodes optional `message` and `suggestions`. Each proposal requires `original`
and `proposed` strings, with optional explanation/kind. Empty originals and
unchanged replacements are filtered out. If decoding fails, the entire reply
becomes a message with no proposals; there is no repair generation. `kind` remains
a string, not an enforced enum. A malformed proposal can make decoding of that
candidate fail rather than preserving its otherwise valid siblings.

`SuggestionBuilder` searches the transmitted context for each original using
literal NSString matching, then searches again **after the first match's end**.
A missing or repeated match is discarded. Thus the check detects nonoverlapping
repetitions, not every possible overlapping substring occurrence. It adds the
context's source offset, checks context/snapshot revisions, and creates a
[TextAnchor](../Sources/TersoCore/Suggestion.swift) containing the original span
and up to 32 UTF-16 units of prefix/suffix.

No semantic validator checks factual accuracy, voice preservation, explanation,
replacement length, or whether several proposals overlap. The instructions in
[AI prompts](ai-prompts.md) guide those qualities; source matching and explicit
acceptance provide the application-side editing constraints.

## Accept, reject, relocate, undo

[SuggestionReview](../Sources/TersoDocument/Review.swift) holds pending, accepted,
rejected, and stale states. Adding, showing, or rejecting proposals does not edit
text. Accept resolves against the target's **current** snapshot:

- Same revision: the original must still occupy its recorded range.
- Newer revision: find literal occurrences of the original and rank their context.
  Each matching full prefix/suffix scores two; the implemented short suffix/prefix
  fallback scores one. A unique highest-scoring candidate can relocate. A sole
  occurrence may relocate even with no surviving context. Missing or tied matches
  become stale instead of applying an old offset.

A successful accept calls `TextMutationTarget.replace` with action name
`Accept Suggestion`. App undo registration keeps the review status in sync with
text undo/redo. Rejection only changes review state.

Accept All requires review mode and `markInspected()` (the UI's indication that
the list was displayed, not proof every suggestion was read). It tries pending
suggestions from later source positions to earlier ones, resolving anew for every
edit and skipping failures. It is not an atomic transaction; overlapping proposals
may become stale after an earlier acceptance.

## Current boundaries

Passage delimiters are plain prompt text, not escaped or enforced instruction
boundaries. The runtime has no dedicated prompt-injection classifier, fact checker,
or semantic output scoring. Messages shown in the UI are not re-fed as chat history.
General exchange records retain provider name/locality, scope, word count, message,
and discard count; issue records retain the response and linked suggestions.
There is no complete persistent prompt/model-parameter audit log in this path.
