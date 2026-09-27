#!/usr/bin/env python3
"""Build a technical-writing reference corpus from documentation snapshots that
predate 2022: Kubernetes docs (release-1.22 @ 2021-12-30, CC BY 4.0), Django docs
(3.2.10, BSD-3), CPython docs (v3.9.9, PSF). Clone them first (see
Evaluation/README.md).

Pages are converted to plain Markdown prose (code, directives and shortcodes
removed), kept when they hold 300–2500 words of prose, capped per project and per
documentation section, and split BY SECTION (sibling pages share authors and
style) into development / calibration / heldout.

  build-technical.py SRC_ROOT OUT_ROOT [--per-project 80] [--per-section 4]"""
import hashlib, os, re, sys

def split_for(group):
    h = int(hashlib.sha256(group.encode()).hexdigest(), 16) % 10
    return "development" if h < 2 else "calibration" if h < 7 else "heldout"

ROLE = re.compile(r":[\w:.-]+:`([^`<]*?)(?:\s*<[^>]*>)?`")

def rst_to_md(text):
    lines = text.split("\n")
    out, i, title = [], 0, None
    skip_indent = None
    while i < len(lines):
        line = lines[i]
        stripped = line.strip()
        if skip_indent is not None:
            if stripped == "" or (len(line) - len(line.lstrip())) > skip_indent:
                i += 1; continue
            skip_indent = None
        # Directives and comments with their indented bodies.
        if stripped.startswith(".. "):
            skip_indent = len(line) - len(line.lstrip()); i += 1; continue
        # Section titles: a line followed by an underline of punctuation.
        if i + 1 < len(lines) and stripped and re.fullmatch(r"([=\-~^\"'`#*+])\1{2,}", lines[i + 1].strip() or "x"):
            title = title or stripped
            out.append("## " + stripped); i += 2; continue
        if re.fullmatch(r"([=\-~^\"'`#*+])\1{2,}", stripped):
            i += 1; continue
        # Literal blocks: "text::" followed by an indented block.
        if stripped.endswith("::"):
            out.append(line.rstrip(":").rstrip() + ("." if stripped != "::" else ""))
            skip_indent = len(line) - len(line.lstrip()); i += 1; continue
        line = ROLE.sub(lambda m: m.group(1), line)
        line = re.sub(r"``([^`]+)``", r"`\1`", line)
        line = re.sub(r"`([^`<]+?)\s*<[^>]+>`_+", r"\1", line)
        out.append(line)
        i += 1
    md = "\n".join(out)
    # Named hyperlinks ("`text`_", "`text <url>`_"), also across line breaks.
    md = re.sub(r"`([^`]+?)(?:\s*<[^>]*>)?`__?", lambda m: re.sub(r"\s+", " ", m.group(1)), md, flags=re.S)
    md = re.sub(r"\|([^|\n]+)\|", r"\1", md)                   # substitutions
    return title, md

def hugo_to_md(text):
    title = None
    m = re.match(r"^---\n(.*?)\n---\n", text, re.S)
    if m:
        t = re.search(r"^title:\s*[\"']?(.*?)[\"']?\s*$", m.group(1), re.M)
        title = t.group(1) if t else None
        text = text[m.end():]
    text = re.sub(r"\{\{[<%].*?[>%]\}\}", "", text, flags=re.S)       # shortcodes
    text = re.sub(r"<!--.*?-->", "", text, flags=re.S)
    return title, text

def prose_words(md):
    md = re.sub(r"```.*?```", "", md, flags=re.S)
    md = "\n".join(l for l in md.split("\n") if not l.startswith(("    ", "\t", "|", "#")))
    return len(re.findall(r"[A-Za-z]+", md))

SOURCES = [
    ("k8s", "k8s/content/en/docs", (".md",), hugo_to_md, 2),
    ("django", "django/docs", (".txt",), rst_to_md, 2),
    ("cpython", "cpython/Doc", (".rst",), rst_to_md, 2),
]
SKIP = re.compile(r"(releases?/|whatsnew|changelog|reference/generated|/api/|glossary|faq/|internals/contributing|license|copyright|c-api|library/)", re.I)

def main():
    src, out = sys.argv[1], sys.argv[2]
    per_project = int(sys.argv[sys.argv.index("--per-project") + 1]) if "--per-project" in sys.argv else 80
    per_section = int(sys.argv[sys.argv.index("--per-section") + 1]) if "--per-section" in sys.argv else 4
    for s in ("development", "calibration", "heldout"):
        os.makedirs(os.path.join(out, s), exist_ok=True)
    rows = []
    for project, root, exts, convert, depth in SOURCES:
        base = os.path.join(src, root)
        taken, per_group = 0, {}
        for dirpath, _, files in sorted(os.walk(base)):
            for fn in sorted(files):
                if taken >= per_project or not fn.endswith(exts):
                    continue
                path = os.path.join(dirpath, fn)
                rel = os.path.relpath(path, base)
                if SKIP.search(rel):
                    continue
                parts = rel.split(os.sep)
                group = project + "/" + "/".join(parts[:depth]) if len(parts) > depth else project + "/" + parts[0]
                if per_group.get(group, 0) >= per_section:
                    continue
                title, md = convert(open(path, encoding="utf-8", errors="replace").read())
                n = prose_words(md)
                if not 300 <= n <= 2500:
                    continue
                split = split_for(group)
                name = f"{project}-{re.sub(r'[^A-Za-z0-9]+', '-', rel.rsplit('.', 1)[0]).strip('-')}.md"
                with open(os.path.join(out, split, name), "w") as f:
                    f.write(md.strip() + "\n")
                per_group[group] = per_group.get(group, 0) + 1
                taken += 1
                rows.append((split, name, n, (title or fn).replace("\t", " ")))
        print(f"{project}: {taken} pages from {len(per_group)} sections", file=sys.stderr)
    with open(os.path.join(out, "titles.tsv"), "w") as f:
        for r in rows:
            f.write("\t".join(map(str, r)) + "\n")
    counts = {s: sum(1 for r in rows if r[0] == s) for s in ("development", "calibration", "heldout")}
    print(f"{len(rows)} pages: {counts}")

if __name__ == "__main__":
    main()
