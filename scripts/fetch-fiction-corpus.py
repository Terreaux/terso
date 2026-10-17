#!/usr/bin/env python3
"""Fetch public-domain story collections and split them into story units."""

from pathlib import Path
import json
import re
import urllib.request


ROOT = Path(__file__).resolve().parents[1] / "Evaluation/Corpora/Human/fiction"
COLLECTIONS = {
    2814: ("joyce", [
        "THE SISTERS", "AN ENCOUNTER", "ARABY", "EVELINE", "AFTER THE RACE",
        "TWO GALLANTS", "THE BOARDING HOUSE", "A LITTLE CLOUD", "COUNTERPARTS",
        "CLAY", "A PAINFUL CASE", "IVY DAY IN THE COMMITTEE ROOM", "A MOTHER",
        "GRACE", "THE DEAD",
    ]),
    269: ("saki", [
        "THE SHE-WOLF", "LAURA", "THE BOAR-PIG", "THE BROGUE", "THE HEN",
        "THE OPEN WINDOW", "THE TREASURE SHIP", "THE COBWEB", "THE LULL",
        "THE UNKINDEST BLOW", "THE ROMANCERS", "THE SCHARTZ-METTERKLUME METHOD",
        "THE SEVENTH PULLET", "THE BLIND SPOT", "DUSK", "A TOUCH OF REALISM",
        "COUSIN TERESA", "THE YARKAND MANNER", "THE BYZANTINE OMELETTE",
        "THE FEAST OF NEMESIS", "THE DREAMER", "THE QUINCE TREE",
        "THE FORBIDDEN BUZZARDS", "THE STAKE", "CLOVIS ON PARENTAL RESPONSIBILITIES",
        "A HOLIDAY TASK", "THE STALLED OX", "THE STORY-TELLER",
        "A DEFENSIVE DIAMOND", "THE ELK", "“DOWN PENS”", "THE NAME-DAY",
        "THE LUMBER ROOM", "FUR", "THE PHILANTHROPIST AND THE HAPPY CAT",
        "ON APPROVAL",
    ]),
    13415: ("chekhov-garnett", [
        "THE LADY WITH THE DOG", "A DOCTOR'S VISIT", "AN UPHEAVAL", "IONITCH",
        "THE HEAD OF THE FAMILY", "THE BLACK MONK", "VOLODYA",
        "AN ANONYMOUS STORY", "THE HUSBAND",
    ]),
    2776: ("ohenry", [
        "TOBIN’S PALM", "THE GIFT OF THE MAGI", "A COSMOPOLITE IN A CAFÉ",
        "BETWEEN ROUNDS", "THE SKYLIGHT ROOM", "A SERVICE OF LOVE",
        "THE COMING-OUT OF MAGGIE", "MAN ABOUT TOWN", "THE COP AND THE ANTHEM",
        "AN ADJUSTMENT OF NATURE", "MEMOIRS OF A YELLOW DOG",
        "THE LOVE-PHILTRE OF IKEY SCHOENSTEIN", "MAMMON AND THE ARCHER",
        "SPRINGTIME À LA CARTE", "THE GREEN DOOR", "FROM THE CABBY’S SEAT",
        "AN UNFINISHED STORY", "THE CALIPH, CUPID AND THE CLOCK",
        "SISTERS OF THE GOLDEN CIRCLE", "THE ROMANCE OF A BUSY BROKER",
        "AFTER TWENTY YEARS", "LOST ON DRESS PARADE", "BY COURIER",
        "THE FURNISHED ROOM", "THE BRIEF DÉBUT OF TILDY",
    ]),
}


def main() -> None:
    ROOT.mkdir(parents=True, exist_ok=True)
    manifest = []
    for ebook, (author, titles) in COLLECTIONS.items():
        url = f"https://www.gutenberg.org/cache/epub/{ebook}/pg{ebook}.txt"
        raw_file = ROOT / f"pg{ebook}.txt"
        if not raw_file.exists():
            raw_file.write_bytes(urllib.request.urlopen(url, timeout=30).read())
        raw = raw_file.read_text(encoding="utf-8-sig")
        start = raw.index("*** START OF THE PROJECT GUTENBERG EBOOK")
        end = raw.index("*** END OF THE PROJECT GUTENBERG EBOOK")
        lines = raw[start:end].splitlines()
        positions = []
        for title in titles:
            matches = [i for i, line in enumerate(lines) if line.strip() == title]
            if not matches:
                raise ValueError(f"Missing {title!r} in eBook {ebook}")
            positions.append(matches[-1])  # The earlier occurrence may be in the contents.
        if positions != sorted(positions):
            raise ValueError(f"Story order changed in eBook {ebook}")
        for number, (title, position) in enumerate(zip(titles, positions)):
            end_position = positions[number + 1] if number + 1 < len(positions) else len(lines)
            body = "\n".join(lines[position + 1:end_position]).strip()
            body = re.sub(r"(?<!\n)\n(?!\n)", " ", body)
            body = re.sub(r"[ \t]+", " ", body)
            slug = re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")
            file = ROOT / f"{author}-{number + 1:02d}-{slug}.txt"
            file.write_text(body + "\n", encoding="utf-8")
            manifest.append({"author": author, "title": title, "ebook": ebook,
                             "source": url, "file": file.name, "words": len(body.split())})
    (ROOT / "manifest.txt").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Extracted {len(manifest)} stories from {len(COLLECTIONS)} books")


if __name__ == "__main__":
    main()
