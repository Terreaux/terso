# Writing Exercises

Open **Tools → Writing Exercises…** for eight short, offline exercises. You can
start from the welcome screen or while a manuscript is open. Right-click a text
selection to start with that excerpt as optional context. Exercises use the
`pencil.and.outline` icon and open in a sheet over the current window.

Choose an exercise, write a response, and move between steps at your own pace.
Every step is optional. **View all responses** opens the review; **Keep writing**
returns to the current step. **Mark complete** helps organize the Saved list and
still lets you edit. **Try again** keeps the previous attempt and starts an empty
one.

Responses save as you edit. **Saved** appears only after the atomic local write
succeeds. A save error keeps your writing in the sheet, provides a retry, and
prevents closing until it is saved. **Save for later** also preserves an empty
exercise. Opening a template and closing without writing leaves no saved record.
The Saved list supports resume, rename, and confirmed deletion. A session already
open in another window is focused there before it can be edited.

In review, select the responses you want to reuse. Copy actions include responses
only. You can also copy a text selection directly from the response editor.
**Use in draft…** shows an explicit destination picker and an append confirmation.
It adds the selected responses in one undoable edit at the end of an open,
editable manuscript. The manuscript's earlier selection is never replaced. The
exercise stays saved after reuse, and deleting it leaves inserted prose intact.

## Suggestions

**Settings → Writing → Exercises** has two independent choices, both off for new
and existing users:

- **Show exercise suggestions in Personal Writing Report** adds one quiet card to
  the Writing Stats overview. It can continue an unfinished exercise linked to the
  current draft or open the chooser.
- **Offer a warm-up when I have not started writing** offers one invitation near
  the editor footer after 5, 10, or 15 minutes; the initial delay is 10 minutes.

The warm-up counts time only in the foreground, while using an editable document.
Time pauses in reports, settings, other modal flows, Preview, Zen, text composition,
and after 60 seconds without an ordinary interaction. Relaunching Terso or changing
the local writing day resets accumulated time. Clock and timezone changes are
handled conservatively.

Any manuscript edit counts as writing activity, including deletion, replacement,
paste, undo, and redo. Exercise edits count too. An invitation requires reliable
local edit coverage, so it stays unavailable on the first partial day after this
feature begins tracking. Later days are covered even when Terso was closed
overnight. Existing typed-word statistics keep their usual definition.

**Not today** suppresses both suggestion surfaces until the next local writing
day. Starting or resuming an exercise, including a manual launch, also suppresses
further offers that day. Automatic delivery is reserved once per day across
windows and relaunches. Turning a suggestion setting off removes its invitation;
manual access and Saved exercises remain available.

## Local records

Sessions and their original prompt snapshots live in
`Application Support/Terso/WritingExercises.json`, separately from manuscripts.
Minimal edit-coverage and suggestion-suppression dates live in
`ExerciseSuggestions.json`; this record contains no text. Both honor the existing
`TERSO_DATA_DIR` isolation option. Workspace recovery retains an optional internal
document identity so links survive ordinary app relaunches. Older recovery files
still load without that field.

Prompts, excerpts, and responses do not add to manuscript goals or writing-analysis
reports. Response practice stays outside combined typed-word totals. Explicit
insertion updates manuscript content and its word count normally, without adding a
second typed-word event. If a source cannot be resolved among open documents,
the exercise remains available and its responses can still be copied or appended
to another draft you choose.
