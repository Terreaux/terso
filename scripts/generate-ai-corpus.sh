#!/bin/sh
# Generate AI-written counterparts of human corpus texts with a CLI assistant.
# Each prompt is the plain request a writer would type — same title, similar
# length — so the two corpora differ in author, not in topic.
#
#   scripts/generate-ai-corpus.sh SPLIT [LIMIT] [JOBS]
#   e.g. scripts/generate-ai-corpus.sh heldout 40 4
#
# Reads $TERSO_HUMAN/titles.tsv (split, file, words, title; default
# Evaluation/Corpora/Human) and writes $TERSO_AI_OUT/SPLIT/<tag>-<file> (default
# Evaluation/Corpora/AI). TERSO_PROMPT is the request, with {title} and {words}
# (default: a dev.to blog post). Existing outputs are skipped, so the script can be
# resumed. Uses Codex CLI read-only in a temporary directory unless TERSO_AI_CMD
# names another tool that reads the prompt on stdin.
set -eu
SPLIT="${1:?split: development|calibration|heldout}"
LIMIT="${2:-40}"
JOBS="${3:-4}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HUMAN="${TERSO_HUMAN:-$ROOT/Evaluation/Corpora/Human}"
TITLES="$HUMAN/titles.tsv"
OUT="${TERSO_AI_OUT:-$ROOT/Evaluation/Corpora/AI}/$SPLIT"
PROMPT="${TERSO_PROMPT:-Write a blog post for dev.to titled \"{title}\". Around {words} words. Reply with the post in Markdown only.}"
TAG="${TERSO_AI_TAG:-codex}"
mkdir -p "$OUT"
[ -f "$TITLES" ] || { echo "missing $TITLES — run make corpus first" >&2; exit 1; }

gen() {
  file="$1"; words="$2"; title="$3"
  dest="$OUT/$TAG-$file"
  [ -s "$dest" ] && return 0
  n=$(( words < 600 ? 600 : (words > 1400 ? 1400 : words) ))
  tmp="$(mktemp -d)"
  prompt=$(printf '%s' "$PROMPT" | awk -v t="$title" -v w="$n" '{gsub(/\{title\}/, t); gsub(/\{words\}/, w); print}')
  if [ -n "${TERSO_AI_CMD:-}" ]; then
    printf '%s' "$prompt" | (cd "$tmp" && sh -c "$TERSO_AI_CMD") > "$dest.part"
  else
    printf '%s' "$prompt" | codex exec --sandbox read-only --skip-git-repo-check --ephemeral --color never \
      -C "$tmp" -o "$dest.part" - >/dev/null 2>&1
  fi
  rm -rf "$tmp"
  [ -s "$dest.part" ] && mv "$dest.part" "$dest" && echo "ok  $file" || { rm -f "$dest.part"; echo "ERR $file" >&2; }
}
export -f gen 2>/dev/null || true
export OUT TAG PROMPT
awk -F'\t' -v s="$SPLIT" '$1==s {print $2 "\t" $3 "\t" $4}' "$TITLES" | head -n "$LIMIT" |
while IFS="$(printf '\t')" read -r file words title; do
  while [ "$(jobs -r | wc -l)" -ge "$JOBS" ]; do sleep 1; done
  gen "$file" "$words" "$title" &
done
wait
echo "$(ls "$OUT" | wc -l | tr -d ' ') texts in $OUT"
