#!/bin/zsh
# Everything that must pass before a commit, in one command (~1 min). Exit 1 on any failure;
# each step's output goes to .build/check/<step>.log. Run it first when coming back to the
# project, and after any macOS or toolchain update.
#   Scripts/check.sh             # tests, warnings, builds, view checks over Examples, the docs
#                                # and generated hostile inputs (Scripts/make-adversarial.py)
#   Scripts/check.sh --corpus    # also smoke + link check .build/corpus (Scripts/make-corpus.sh)
set -uo pipefail
zmodload zsh/datetime   # EPOCHREALTIME
ROOT=${0:A:h:h}
cd "$ROOT"
LOG="$ROOT/.build/check"
rm -rf "$LOG"; mkdir -p "$LOG"
failed=()

# A build or test command that must succeed without a single compiler warning.
clean() {
  local out rc
  out=$("$@" 2>&1); rc=$?
  print -r -- "$out"
  # (Not grep -q: it exits at the first match, print then dies of SIGPIPE on long output, and
  # pipefail + ! turned that into a pass.)
  [[ $rc == 0 ]] && ! print -r -- "$out" | grep -E '\.swift:[0-9]+:[0-9]+: (warning|error):' >/dev/null
}

report() {   # report <name> <status> <seconds>
  if [[ $2 == 0 ]]; then printf '  ok    %-28s %5.1fs\n' $1 $3
  else printf '  FAIL  %-28s %5.1fs  -> .build/check/%s.log\n' $1 $3 $1; failed+=$1; fi
}

step() {     # step <name> <command...>
  local name=$1; shift
  local t0=$EPOCHREALTIME
  "$@" > "$LOG/$name.log" 2>&1
  report $name $? $((EPOCHREALTIME - t0))
}

print "builds and tests (parallel)"
rm -f .build/release/peep-dev   # rebuild, so its warnings are seen
typeset -A pids starts
for name cmd in \
  tests-debug   'clean Scripts/test.sh' \
  tests-release 'clean env CONFIG=release Scripts/test.sh' \
  app           'clean Scripts/build.sh' \
  app-diag      'clean env DIAG=1 Scripts/build.sh typecheck' \
  peep-dev      'clean Scripts/dev.sh --build'; do
  starts[$name]=$EPOCHREALTIME
  ( eval "$cmd" > "$LOG/$name.log" 2>&1 ) &
  pid=$!; pids[$name]=$pid   # (zsh doesn't expand $! in a subscripted assignment)
done
for name in tests-debug tests-release app app-diag peep-dev; do
  wait ${pids[$name]}; report $name $? $((EPOCHREALTIME - starts[$name]))
done
[[ ${#failed} -gt 0 ]] && { print "\nFAILED: ${failed[*]}"; exit 1; }

DEV=.build/release/peep-dev
MD=(Examples/Markdown/*.md(N) Examples/Markdown/*.markdown(N) AGENTS.md README.md)
TILE=($MD Examples/Code/rust-lexer.rs Examples/Code/c-ring.c)
if [[ -f Examples/Large/huge.md ]]; then TILE+=Examples/Large/huge.md
else print "  (no Examples/Large: Scripts/make-examples.sh --large adds the big-file checks)"; fi
print "view checks"
step smoke     $DEV smoke Examples AGENTS.md README.md
step tilecheck $DEV tilecheck $TILE
step linkcheck $DEV linkcheck $MD
step geometry  zsh -c 'for f in "$@"; do out=$('$DEV' layout "$f" 420) || { echo "$f: layout failed"; exit 1 }
  [[ $out == *"GEOMETRY ERRORS"* ]] && { echo "$f"; exit 1 }; done; exit 0' _ $MD
python3 -I Scripts/make-adversarial.py .build/adversarial
# Crashes, traps, runaway work. The budget is ~3x the slowest file on an M4; a super-linear
# case blows through it by far more. CI's shared runners are slower: validate.yml raises it.
step adversarial $DEV smoke --budget ${PEEP_SMOKE_BUDGET:-1500} --max-mb 3000 --images .build/adversarial

if [[ ${1:-} == --corpus ]]; then
  if [[ -d .build/corpus/files ]]; then
    print "corpus"
    step corpus-smoke     $DEV smoke .build/corpus/files
    step corpus-linkcheck $DEV linkcheck .build/corpus/files/*.md(N)
  else
    print "  no .build/corpus: run Scripts/make-corpus.sh"; failed+=corpus
  fi
fi

if [[ ${#failed} -gt 0 ]]; then print "\nFAILED: ${failed[*]}"; exit 1; fi
print "\nall checks passed"
