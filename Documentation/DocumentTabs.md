# Document tabs in one window

Terso uses one real `NSWindow` per workspace. Documents are `TabDocument`
(`NSDocument`) objects with their own text, codec, undo manager, `WorkspaceModel`
and retained `NSHostingView<DocumentWindow>`. A document does not create a window.
`RetainedDocumentEditor` moves the selected editor view into the workspace's
content area. Switching tabs therefore preserves the OS window identity and frame.

This replaces the earlier `DocumentGroup` and native `NSWindowTabGroup` design.
AeroSpace treats native macOS tabs as separate windows
([upstream issue #68](https://github.com/nikitabobko/AeroSpace/issues/68)), which
caused extra tiles and size/position jumps. Automatic native tabbing is disabled,
and each workspace explicitly uses `.disallowed`. No AeroSpace configuration
change or frame-synchronization loop is needed.

## Ownership and operations

- New/Open and the plus button add a document to the active workspace. Opening
  an already-open file selects its existing tab through `NSDocumentController`.
- Each document keeps its existing editor view, selection, scroll, undo manager,
  analysis, review and assistant state when switched or moved between windows.
- Drag a tab onto another tab to reorder it or move it between workspaces.
  **Move Tab to New Window** creates a separate workspace; **Merge All Windows**
  moves the same document objects and editor views into the active workspace.
- AppKit `NSDocument` handles Save, Save As, Duplicate, Rename, Revert, file
  coordination and autosave support. Existing `PlainTextCodec` preserves encoding,
  BOM, line endings and whitespace. Editor undo notifications drive change counts.
- Closing the last tab keeps the window open on a start screen with New
  Document, Open…, recent files, and a drop target for files. Command-W there
  closes the window. Moving the last tab to another window, or closing the
  window, still closes it.
- Close Tab reviews that document's unsaved changes. Closing a window reviews all
  of its documents sequentially and stops on Cancel. Quit reviews every document;
  text explicitly discarded by the user is excluded from recovery.
- Recovery snapshots live at `~/Library/Application Support/Terso/DocumentTabs.json`
  and retain tab order, selection, file URLs, file type and current document bytes.
  They are written atomically after edits and before quitting. Clean saved files
  reload from disk; unsaved text is recovered from the snapshot. Undo history and
  analysis results are not serialized across app launches.

## Validation

`DocumentTabsTests` covers stable window identity/frame across tab switches,
retained editor identity across moves, independent inspector and undo state,
neighbor selection after closing, byte-preserving reads/writes, actual editor
edit/undo/redo, and saving the originating document while another tab is selected.
`DocumentSessionTests` covers asynchronous analysis and assistant isolation.

The live AeroSpace check found one Terso window for three document tabs after
this change. Native save/cancel sheets, dragging, multi-monitor placement, and
migration of previous DocumentGroup restoration data require separate UI checks;
unit tests do not establish those behaviors.
