# Offline alternatives

Select text and choose Writing → Alternatives for Selection (Option-Command-T),
or use Alternatives on a repetition finding. The picker shows one meaning at a
time and six choices initially. Choosing an alternative previews the edit;
Replace changes only that occurrence, through the review gate. Undo restores it.

## Quality and scope

`WritingAlternatives.json` supplies a small, authored set of common writing
alternatives, grouped and ordered by meaning. It includes selected phrases and
explicit inflected verb forms. These are editorial alternatives, not promises of
interchangeability in every sentence. They are not copied from Apple's dictionaries.

Other entries fall back to bundled WordNet 3.0 synonyms. WordNet's per-headword
sense order is retained, rather than using raw data-file offsets as a ranking.
The full source definitions remain available as help text; long examples are
not repeated in the picker. A word's sentence is used for preview, not automated
meaning detection. Uncovered inflections and phrases may have no results.

Look Up in macOS uses the public AppKit definition presentation. Available
references depend on installed/enabled system dictionaries. The app does not
parse system dictionary text into replacement candidates or use private APIs.
The bundled alternatives need no network, API key, or language model.

## Validation

`OfflineThesaurusTests` checks useful first choices across common writing words,
separate meanings, inflected forms, case, phrase coverage, unknown terms, and
fallback ordering. `ThesaurusTests` checks occurrence selection, revision guards,
preview offsets, and replacement/Undo through the review gate.
