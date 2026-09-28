> Superseded by [document tabs in one window](DocumentTabs.md). This page records the earlier native-window implementation.

# Native document tabs

Terso keeps its SwiftUI `DocumentGroup` / `FileDocument` architecture. Each
Markdown or text document has a distinct system document window, editor and
`WorkspaceModel`. `DocumentTabbing` configures only those windows with the shared
`org.terso.document` tabbing identifier and AppKit's `.preferred` mode before
ordering. On first presentation, it also explicitly joins the frontmost eligible
document window if AppKit has not already placed it in a tab group. This covers
SwiftUI attaching the configuration view after automatic tab placement. New/Open
therefore prefer an existing document tab group; with no eligible window they
open a standalone window. Settings, minimized windows and windows showing a
sheet are excluded. Grouping runs only once, so manually detached tabs stay
detached when selected again. There is no custom tab bar, window controller, delegate replacement,
close interception or session database.

AppKit owns tab selection, drag detachment, merging, titles and Window commands.
SwiftUI's document infrastructure continues to own New/Open, Save/Save As, edited
indicators, autosave, close confirmation and native restoration. The native plus
button and Window menu are already supplied by that infrastructure. Terso does
not override system preference values; `.preferred` is a deliberate document
window policy to favor tabs, rather than `.automatic`'s preference-dependent
choice. Users can detach tabs through the native Window menu.

## State ownership

| State | Owner / lifetime |
|---|---|
| Persisted text and codec | `MarkdownDocument`, supplied by `DocumentGroup` |
| File URL, save/autosave and restoration identity | System document infrastructure; current URL forwarded to the scene |
| Text selection, caret, scroll and undo | Existing `NSTextView`, `NSScrollView` and editor coordinator belonging to that document scene |
| Revision, local/style/science analysis, suggestions, Assistant exchanges, ignored findings | Scene's `WorkspaceModel`, retained while its document is open |
| Selected finding/passage, inspector tab/visibility, focus and sidebar state | Same scene/model; follow the document tab during detach/merge |
| Fonts, analysis domain, enabled layers and provider settings | Existing shared application preferences |
| Spell-check session | One `SpellingLayer` per workspace; released after the last callback |

Moving a native tab preserves the window and scene, so no text reload or model
replacement is needed. A file URL is not used as session identity: Untitled and
Save As must work without changing the model. Transient selections, Assistant
history and analysis are not newly persisted across application termination.
Native restoration remains subject to macOS settings; exact group restoration
needs a normal quit/relaunch test on the supported OS.

Analysis captures an immutable snapshot and weak reference to its originating
model, then checks cancellation and revision before delivery. Detached utility
work now receives cancellation and checks between stages (and the existing
writing-rule loop can observe cancellation). Switching tabs does not cancel it.
AI likewise returns to its originating model and retains the request revision
for stale-anchor validation. Cancelled provider results cannot publish, and an
older finding request cannot replace a newer request's state. No callback uses
the currently focused window as its destination.

## Validation, September 26, 2026

`swift build --product Terso` and `swift test` passed. The app test target exercises
10 simultaneous document sessions containing Review-heavy scientific text,
superseding one revision while the others finish, independent presentation and
ignored findings, delayed AI delivery after another document becomes active,
and a provider that returns after cancellation. AI tests use a local deterministic
fake, not a live provider. Existing opt-in Apple/Codex live tests were skipped.

UI checks used separate temporary app bundles and disposable files, preserving
the user's running Terso instance:

| Check | Result |
|---|---|
| Open A, then B | Native two-tab group; filename labels and native plus button |
| Control-Tab / Control-Shift-Tab | Changed document; original content/inspector restored |
| Command-N | New Untitled tab in current group |
| Window menu | Native Previous/Next, Move Tab to New Window, Merge All Windows |
| Move Tab to New Window, then Merge All Windows | Detached/recombined successfully; original Review passage selection retained |
| Edited Untitled detach/merge | Text and native edited indicator retained; undo and redo still worked after detachment |
| Command-W on edited Untitled | Native Save/Delete/Cancel sheet; Cancel preserved the tab and its text |
| Pointer drag out/back | Not verified: automation failed with `windowNotFoundAtPosition` / ScreenCaptureKit error -3812 |
| Save/Discard completion and group window-close prompts | Not fully verified; capture error interrupted subsequent close checks |
| Normal quit/relaunch, multiple tab-group restoration | Not verified |
| Ten actual windows/tabs and interactive typing latency | Not completed; ten concurrent model analyses passed, but this is not a UI latency measurement |
| Review/Science/Assistant/Statistics rapid switching | Model isolation tested; live UI coverage is partial |

## Remaining interactive acceptance checks

Use disposable documents. Open A/B/C, select distinct passages, scroll positions
and inspector panels; move B out and back by dragging. Verify Undo/Redo and
selection afterward. Repeat with an edited Untitled tab, then exercise Save,
Discard and Cancel. Close an entire group with a modified middle tab and verify
native save handling. Open two different LaTeX documents and confirm Science
symbols/quantities follow the selected tab. Run delayed AI on A while editing B.
Open ten files, including several long scientific and Review-heavy examples,
and check active typing responsiveness. Finally arrange two tab groups, quit
normally and relaunch with macOS window restoration enabled.

Existing writing shortcuts are unchanged. Control-Tab/Control-Shift-Tab and the
native Window menu provide tab navigation; Command-brackets remain passage
navigation. No duplicate tab commands were added.

References: [NSWindow tabbingMode](https://developer.apple.com/documentation/appkit/nswindow/tabbingmode-swift.property),
[newWindowForTab](https://developer.apple.com/documentation/appkit/nsresponder/newwindowfortab(_:)).
