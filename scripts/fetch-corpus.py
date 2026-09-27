#!/usr/bin/env python3
"""Fetch a human reference corpus from the public dev.to API.

Texts published before 2022 predate public LLM chat assistants, so they are human
by date. Posts are drawn from the all-time top lists of several tags (not from a
hand-picked author list), capped per author so no single writer sets the bands,
and split by AUTHOR into development / calibration / heldout, so one writer's
habits cannot leak from calibration into evaluation.

  fetch-corpus.py OUT_ROOT [--target 240] [--per-author 3]

Writes OUT_ROOT/{development,calibration,heldout}/AUTHOR-ID.md and
OUT_ROOT/titles.tsv (split, file, words, title). Texts are for local measurement
only; they are never committed or shipped (authors keep their copyright)."""
import hashlib, json, os, re, sys, time, urllib.request, urllib.error

TAGS = ["career", "productivity", "beginners", "webdev", "discuss", "writing", "opensource",
        "learning", "devops", "design", "startup", "healthydebate", "watercooler", "motivation",
        "leadership", "testing", "security", "python", "javascript", "books"]
CUTOFF = "2022-01-01"

def get(url):
    for wait in (1, 4, 16, 32):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "terso-corpus/1.0"})
            with urllib.request.urlopen(req, timeout=30) as r:
                return json.load(r)
        except urllib.error.HTTPError as e:
            if e.code not in (429, 500, 502, 503):
                return None
        except (urllib.error.URLError, TimeoutError, ValueError):
            pass
        time.sleep(wait)
    return None

def split_for(author):
    h = int(hashlib.sha256(author.encode()).hexdigest(), 16) % 10
    return "development" if h < 2 else "calibration" if h < 7 else "heldout"

def prose_words(md):
    md = re.sub(r"```.*?```", "", md, flags=re.S)
    return len(re.findall(r"[A-Za-z]+", md))

def main():
    out = sys.argv[1]
    target = int(sys.argv[sys.argv.index("--target") + 1]) if "--target" in sys.argv else 240
    cap = int(sys.argv[sys.argv.index("--per-author") + 1]) if "--per-author" in sys.argv else 3
    for s in ("development", "calibration", "heldout"):
        os.makedirs(os.path.join(out, s), exist_ok=True)
    per_author, seen, rows = {}, set(), []
    for page in range(1, 6):
        for tag in TAGS:
            if len(rows) >= target:
                break
            items = get(f"https://dev.to/api/articles?tag={tag}&top=3650&per_page=100&page={page}") or []
            for a in items:
                if len(rows) >= target:
                    break
                user = (a.get("user") or {}).get("username", "")
                if (not user or a["id"] in seen or a.get("published_at", "9") >= CUTOFF
                        or a.get("language", "en") not in ("en", None)
                        or not 3 <= a.get("reading_time_minutes", 0) <= 15
                        or per_author.get(user, 0) >= cap):
                    continue
                seen.add(a["id"])
                full = get(f"https://dev.to/api/articles/{a['id']}")
                body = (full or {}).get("body_markdown") or ""
                n = prose_words(body)
                if n < 300:
                    continue
                split = split_for(user)
                name = f"{user}-{a['id']}.md"
                with open(os.path.join(out, split, name), "w") as f:
                    f.write(body)
                per_author[user] = per_author.get(user, 0) + 1
                rows.append((split, name, n, a["title"].replace("\t", " ")))
                time.sleep(0.35)
            print(f"page {page} {tag}: {len(rows)} texts, {len(per_author)} authors", file=sys.stderr)
    with open(os.path.join(out, "titles.tsv"), "w") as f:
        for r in rows:
            f.write("\t".join(map(str, r)) + "\n")
    counts = {s: sum(1 for r in rows if r[0] == s) for s in ("development", "calibration", "heldout")}
    print(f"{len(rows)} texts by {len(per_author)} authors: {counts}")

if __name__ == "__main__":
    main()
