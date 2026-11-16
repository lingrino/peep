#!/bin/zsh
# Gather a Markdown corpus into .build/corpus/files (not committed): real-world documents from
# package caches (an even sample of every .md there), the input for parser and layout changes (`peep-dev mddump` before/after,
# `parsebench <dir>` by size, `Scripts/check.sh --corpus`). Deterministic for a given machine:
# sorted paths, duplicates (same content) dropped.
#   Scripts/make-corpus.sh [max files, default 1500] [more dirs...]
set -euo pipefail
ROOT=${0:A:h:h}
cd "$ROOT"
MAX=${1:-1500}
(( $# )) && shift
DIRS=("$@")
for d in "$(brew --prefix 2>/dev/null || true)" "$HOME/go/pkg/mod" "$HOME/.cargo/registry/src"; do
  [[ -n "$d" && -d "$d" ]] && DIRS+=("$d")
done
[[ ${#DIRS} -gt 0 ]] || { echo "no package caches found; pass directories with .md files" >&2; exit 1; }
OUT="$ROOT/.build/corpus/files"
rm -rf "$OUT"; mkdir -p "$OUT"
# Every candidate, then an even sample across them (sorted order alone would take the first
# directories only).
all=()
find "${DIRS[@]}" -type f \( -iname '*.md' -o -iname '*.markdown' \) -size -8M 2>/dev/null | LC_ALL=C sort |
  while IFS= read -r f; do all+=("$f"); done
step=$(( ${#all} > MAX ? ${#all} / MAX : 1 ))
typeset -A seen
n=0
for (( i = 1; i <= ${#all} && n < MAX; i += step )); do
  f=${all[i]}
  h=$(md5 -q "$f" 2>/dev/null) || continue
  [[ -n ${seen[$h]:-} ]] && continue
  seen[$h]=1
  n=$((n + 1))
  cp "$f" "$OUT/$n-${f:t}"
done
echo "$(ls "$OUT" | wc -l | tr -d ' ') files in .build/corpus/files ($(du -sh "$OUT" | cut -f1)) from ${#DIRS} directories"
