# The `.terso` format

A `.terso` file is a ZIP archive with two entries:

| Entry           | Holds                                                  |
| --------------- | ------------------------------------------------------ |
| `document.md`   | The Markdown body, without front matter                |
| `metadata.yaml` | The document's metadata as YAML, without `---` fences  |

Any zip tool can open it, and the writing stays a plain Markdown file.

## In the editor

Terso still edits one text. On open, the YAML becomes `---` front matter
above the body, so titles, book designs and everything else that reads front
matter work as in a `.md` file. On save, that front matter goes back into
`metadata.yaml` and the rest into `document.md`.

Only YAML front matter fenced by `---` on both sides moves into
`metadata.yaml`. TOML (`+++`) front matter, a `...` terminator and an empty
block stay in the body, so a save never changes the text you see.

## On disk

Terso writes entries uncompressed, with UTF-8 names and a fixed timestamp, so
saving the same text always gives the same bytes. Terso reads deflated
entries too, and entries inside a folder, as Finder's **Compress** or
`zip -r` makes them. `metadata.yaml` is optional on read.

The implementation is `TersoPackage` in `Sources/TersoDocument`.
