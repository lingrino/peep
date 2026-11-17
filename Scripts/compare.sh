#!/bin/zsh
# Compare the working tree with another revision on this machine (renders, speed).
#
#   Scripts/compare.sh renders [--rev R] [files...]
#       Renders each file (top; scrolled, dark; narrow, scrolled) with both builds and diffs the
#       pixels. Default files: everything in Examples (not Large) plus AGENTS.md and README.md.
#       Differing pairs stay in .build/compare/ (open them side by side). Exit 1 if any differ.
#   Scripts/compare.sh bench [--rev R] [--rounds N] <peep-dev args...>
#       Runs a benchmark alternately with the baseline and the current build (N rounds,
#       default 3), so both see the same machine state: `bench --rounds 5 parsebench .build/corpus/files`.
#
# R defaults to HEAD: the working tree's uncommitted changes against the last commit.
set -euo pipefail
ROOT=${0:A:h:h}
cd "$ROOT"
mode=${1:-}; shift || true
rev=HEAD rounds=3
while [[ $# -gt 0 ]]; do
  case $1 in
    --rev) rev=$2; shift 2 ;;
    --rounds) rounds=$2; shift 2 ;;
    *) break ;;
  esac
done
BASE=$(Scripts/baseline.sh "$rev")
Scripts/dev.sh --build
NEW=.build/release/peep-dev

case $mode in
renders)
  files=("$@")
  if [[ ${#files} -eq 0 ]]; then
    files=(Examples/**/*(.N))
    files=(${files:#Examples/Large/*} AGENTS.md README.md)
  fi
  OUT=.build/compare; rm -rf $OUT; mkdir -p $OUT
  variants=("--scroll 0" "--scroll 1500 --dark" "--size 520x700 --scroll 900")
  same=0 differ=0
  for f in $files; do
    for v in $variants; do
      tag=${${f//\//_}}.${${v// /}//-/}
      $BASE render $f $OUT/$tag.base.png ${=v} >/dev/null 2>&1 || true
      $NEW render $f $OUT/$tag.new.png ${=v} >/dev/null 2>&1 || true
      if [[ ! -f $OUT/$tag.base.png || ! -f $OUT/$tag.new.png ]]; then
        echo "no render: $f $v"; differ=$((differ + 1))
      elif r=$($NEW imgdiff $OUT/$tag.base.png $OUT/$tag.new.png); then
        same=$((same + 1)); rm -f $OUT/$tag.*.png
      else
        echo "DIFF $f ($v): $r"; differ=$((differ + 1))
      fi
    done
  done
  echo "$same identical, $differ different (vs $rev; pairs in .build/compare/)"
  [[ $differ -eq 0 ]]
  ;;
bench)
  [[ $# -gt 0 ]] || { echo "usage: compare.sh bench [--rev R] [--rounds N] <peep-dev args...>"; exit 2; }
  for i in {1..$rounds}; do
    echo "-- round $i"
    $BASE "$@" 2>&1 | awk -v p="  $rev: " '{ print p $0 }'   # (sed broke on revs like origin/main)
    $NEW "$@" 2>&1 | awk -v p="  new: " '{ print p $0 }'
  done
  ;;
*)
  sed -n '2,15p' "$0"; exit 2 ;;
esac
