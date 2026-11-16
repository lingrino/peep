#!/bin/zsh
# Build peep-dev as of another revision (for Scripts/compare.sh); cached per commit in
# .build/baseline/<commit>/. Prints the binary's path.
#   Scripts/baseline.sh [rev]      # default HEAD (the last commit, without working-tree changes)
set -euo pipefail
ROOT=${0:A:h:h}
cd "$ROOT"
REV=$(git rev-parse --short "${1:-HEAD}^{commit}")
OUT="$ROOT/.build/baseline/$REV"
if [[ ! -x "$OUT/peep-dev" ]]; then
  SRC="$ROOT/.build/baseline/src-$REV"
  git worktree remove --force "$SRC" >/dev/null 2>&1 || rm -rf "$SRC"
  git worktree add --detach --quiet "$SRC" "$REV"
  trap 'git -C "$ROOT" worktree remove --force "$SRC" >/dev/null 2>&1 || true' EXIT
  # Older trees' dev.sh has no --build; with no command it builds, then prints usage (exit 2).
  (cd "$SRC" && Scripts/dev.sh --build >/dev/null 2>&1 || true)
  [[ -x "$SRC/.build/release/peep-dev" ]] || { echo "baseline build failed at $REV" >&2; exit 1; }
  mkdir -p "$OUT"
  cp "$SRC/.build/release/peep-dev" "$OUT/peep-dev"
fi
echo "$OUT/peep-dev"
