# Science navigation refinement

The Scientific review → Needs attention → Document model → Scientific Map
hierarchy remains unchanged. The overview initially shows three findings and an
explicit “Show N more” disclosure; expansion remains local to its document.
Document-model rows keep their compact layout with full-row hit targets, quiet
hover feedback, and secondary text for empty categories.

The existing issue rail now groups markers into 18-point screen-space slots.
Each cluster retains every finding, ordered by severity and source location.
The visible marker remains 5–7 points wide; its hit area is 12 × 18 points. A
split marker denotes multiple findings. Native help gives category, severity,
source excerpt, existing explanation, overlap count and interaction guidance.
Repeated clicks cycle the cluster; the secondary-click menu offers each finding.
Selection reuses the existing Review/Science navigation. Review passage context
remains visible beneath the clustered markers.

Hover is separate from selection. WorkspaceModel owns a transient annotation ID;
the existing NSLayoutManager annotation renderer previews the source, the marker
becomes stronger, and a visible Science finding receives a quiet background.
Leaving the item, changing the text or starting another analysis clears preview.
Hover never opens an inspector, changes the caret, scrolls, edits text or starts
analysis. This introduces no new document model, persistence or highlighting
engine. Inspector modes, gating, typography and reading width are unchanged.

## Native document tabs: original implementation

This section records the September 27 implementation. It is superseded by
[document tabs in one window](DocumentTabs.md) for tiling-window-manager compatibility.

DocumentTabbing still configures the original NSWindow tab groups. Selected tab
titles are semibold; inactive titles use regular system typography. Full source
paths are available as tooltips. AppKit retains close/dirty state, shortcuts,
reordering, detachment, merging and document ownership.

The requested 140–300-point, variable-width strip is **not implemented**. A
presentation prototype backed by NSWindowTabGroup produced a second native tab
bar when multiple windows were merged. Public NSWindowTab configuration exposes
title, attributed title, tooltip and accessory view, but no tab-width setting.
The prototype was removed rather than leave duplicate navigation or replace the
native document/window model without resolving that scope tradeoff with the user.

## Validation (September 27, 2026)

- Debug tests and release build pass: 120 tests, including five new tests for
  clustering, resizing, transient hover/rendering, and document-local state.
- Native UI: multiple documents, long title truncation, active/inactive titles,
  Control-Tab switching, independent inspector state, menu detachment and merge.
- Science: empty overview; four findings with “Show 1 more”; 28 findings with
  “Show 25 more”; in-place disclosure, marker → Science → source navigation,
  scrolling, and individual choices in a six-finding marker cluster.
- A real NSTextView/NSLayoutManager test confirms preview attributes appear and
  disappear without document, caret or selection changes.
- Screenshot: `/Users/lalmei/Desktop/terso-science-refinement.png`, three open
  documents and the dense Science overview at the normal inspector width.
- Some newly generated `.md` fixtures were disabled by the native Open panel;
  identical Markdown content was tested through `.txt` import instead. An
  existing `.md` fixture opened successfully. File-type routing was not changed.
- Live hover-only inspection, pointer dragging/reordering, and exact six-finding
  visual inspection remain unverified. The UI automation has no hover/move action
  and capture became unreliable after detach/merge. This is not a claim that all
  interactive acceptance checks passed.
