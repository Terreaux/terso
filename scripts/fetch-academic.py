#!/usr/bin/env python3
"""Fetch an academic reference corpus: Introduction/Background sections of
open-access articles (CC BY) published 2016–2021, via the Europe PMC API.

Articles are drawn across disciplines, capped per journal, and split BY JOURNAL
(a journal's house style plays the role an author does in the blog corpus) into
development / calibration / heldout.

  fetch-academic.py OUT_ROOT [--target 240] [--per-journal 3]

Writes OUT_ROOT/{split}/PMCID.md and OUT_ROOT/titles.tsv (split, file, words, title).
Texts are for local measurement only; never committed or shipped."""
import hashlib, json, os, re, sys, time, urllib.parse, urllib.request, urllib.error
import xml.etree.ElementTree as ET

TOPICS = ["psychology", "economics", "education", "ecology", "sociology", "linguistics",
          "engineering", "computer science", "public health", "neuroscience", "climate", "materials"]
BASE = "https://www.ebi.ac.uk/europepmc/webservices/rest"

def get(url, as_json=True):
    for wait in (1, 4, 16):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "terso-corpus/1.0"})
            with urllib.request.urlopen(req, timeout=40) as r:
                data = r.read()
                return json.loads(data) if as_json else data
        except (urllib.error.URLError, TimeoutError, ValueError):
            time.sleep(wait)
    return None

def split_for(journal):
    h = int(hashlib.sha256(journal.encode()).hexdigest(), 16) % 10
    return "development" if h < 2 else "calibration" if h < 7 else "heldout"

def text_of(el):
    """Paragraph text without citations, figures or tables."""
    for tag in ("xref", "table-wrap", "fig", "disp-formula", "inline-formula"):
        for child in list(el.iter(tag)):
            child.clear()
            child.text = ""
    t = "".join(el.itertext())
    t = re.sub(r"\[\s*[,–\-\s]*\]|\(\s*[,;–\-\s]*\)", "", t)   # empty brackets left by removed citations
    return re.sub(r"\s+", " ", t).strip()

def introduction(xml_bytes):
    try:
        root = ET.fromstring(xml_bytes)
    except ET.ParseError:
        return None
    body = root.find(".//body")
    if body is None:
        return None
    def keep(ps):
        paras = [text_of(p) for p in ps]
        paras = [p for p in paras if len(p.split()) > 15]
        return "\n\n".join(paras) if paras else None
    for sec in body.findall("./sec"):
        t = sec.find("title")
        title = "".join(t.itertext()).lower() if t is not None else ""
        if any(k in title for k in ("introduction", "background")):
            found = keep(sec.iter("p"))
            if found:
                return found
    # Many articles open with untitled introductory paragraphs before the first section.
    lead = []
    for child in body:
        if child.tag == "sec":
            break
        if child.tag == "p":
            lead.append(child)
    return keep(lead)

def main():
    out = sys.argv[1]
    target = int(sys.argv[sys.argv.index("--target") + 1]) if "--target" in sys.argv else 240
    cap = int(sys.argv[sys.argv.index("--per-journal") + 1]) if "--per-journal" in sys.argv else 3
    for s in ("development", "calibration", "heldout"):
        os.makedirs(os.path.join(out, s), exist_ok=True)
    per_journal, rows, seen = {}, [], set()
    per_topic = -(-target // len(TOPICS))
    for topic in TOPICS:
        got, cursor = 0, "*"
        while got < per_topic and len(rows) < target:
            q = f'"{topic}" AND OPEN_ACCESS:y AND LICENSE:"cc by" AND FIRST_PDATE:[2016-01-01 TO 2021-12-31] AND SRC:PMC AND LANG:eng'
            url = f"{BASE}/search?query={urllib.parse.quote(q)}&resultType=lite&pageSize=100&format=json&cursorMark={urllib.parse.quote(cursor)}"
            d = get(url)
            if not d or not d.get("resultList", {}).get("result"):
                break
            cursor = d.get("nextCursorMark", cursor)
            for r in d["resultList"]["result"]:
                pmcid, journal = r.get("pmcid"), (r.get("journalTitle") or "").strip()
                if not pmcid or not journal or pmcid in seen or per_journal.get(journal, 0) >= cap:
                    continue
                seen.add(pmcid)
                xml = get(f"{BASE}/{pmcid}/fullTextXML", as_json=False)
                intro = introduction(xml) if xml else None
                n = len(intro.split()) if intro else 0
                if not intro or not 300 <= n <= 1800:
                    continue
                split = split_for(journal)
                name = f"{pmcid}.md"
                with open(os.path.join(out, split, name), "w") as f:
                    f.write(intro + "\n")
                per_journal[journal] = per_journal.get(journal, 0) + 1
                rows.append((split, name, n, re.sub(r"\s+", " ", r.get("title", "")).strip(), journal))
                got += 1
                time.sleep(0.2)
                if got >= per_topic or len(rows) >= target:
                    break
        print(f"{topic}: {len(rows)} texts, {len(per_journal)} journals", file=sys.stderr)
    with open(os.path.join(out, "titles.tsv"), "w") as f:
        for r in rows:
            f.write("\t".join(map(str, r[:4])) + "\n")
    with open(os.path.join(out, "journals.tsv"), "w") as f:
        for r in rows:
            f.write(f"{r[1]}\t{r[4]}\n")
    counts = {s: sum(1 for r in rows if r[0] == s) for s in ("development", "calibration", "heldout")}
    print(f"{len(rows)} texts from {len(per_journal)} journals: {counts}")

if __name__ == "__main__":
    main()
