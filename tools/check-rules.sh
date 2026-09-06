#!/bin/bash
# Runnable check for the cleanup rules, against the seed Resources/rules.json.
# Fails loudly if any expectation breaks. Usage: ./tools/check-rules.sh (after ./build.sh)
set -u
cd "$(dirname "$0")/.."
BIN="YTT.app/Contents/MacOS/YTT"
# Point the app at a scratch data folder so the check never touches real rules.
SCRATCH="$(mktemp -d)"
cp Resources/rules.json "$SCRATCH/rules.json"
export YTT_DATA_DIR_OVERRIDE="$SCRATCH"
fail=0
check() {
  local input="$1" expected="$2"
  local got
  got="$("$BIN" --clean "$input" 2>/dev/null)"
  if [ "$got" == "$expected" ]; then
    echo "ok    $input  ->  $got"
  else
    echo "FAIL  $input  ->  $got   (expected: $expected)"
    fail=1
  fi
}
check "hello there"                          "Hello there."
check "push it to get hub tonight"           "Push it to GitHub tonight."
check "open cloud code on mac os"            "Open Claude Code on macOS."
check "it costs\$4,281.50 today"             "It costs \$4,281.50 today."
check "where is the file"                    "Where is the file?"
check "Already done."                        "Already done."
check "the jason file is broken"             "The JSON file is broken."
check "jasonville is a town"                 "Jasonville is a town."
stitch() {
  local pieces="$1" expected="$2" protected="${3:-}"
  local got
  got="$("$BIN" --stitch-test "$pieces" "$protected" 2>/dev/null)"
  if [ "$got" == "$expected" ]; then
    echo "ok    $pieces  ->  $got"
  else
    echo "FAIL  $pieces  ->  $got   (expected: $expected)"
    fail=1
  fi
}
stitch "looking at the output|It seems that"        "looking at the output it seems that"
stitch "done.|It seems"                             "done. It seems"
stitch "review the|OASIS form"                      "review the OASIS form"
stitch "and then|I think"                           "and then I think"
stitch "talk to|Raffi today"                        "talk to Raffi today"          "raffi"
stitch "I talked to Bob,|And then left"              "I talked to Bob, and then left"
rm -rf "$SCRATCH"
exit $fail
