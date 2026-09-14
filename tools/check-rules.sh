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
join() {
  local pieces="$1" expected="$2" off="${3:-}"
  local got
  got="$("$BIN" --join-test "$pieces" "$off" 2>/dev/null)"
  if [ "$got" == "$expected" ]; then
    echo "ok    $pieces  ->  $got"
  else
    echo "FAIL  $pieces  ->  $got   (expected: $expected)"
    fail=1
  fi
}
join "Okay, I trust you with the Qwen 3 1.7B situation.|1.8||I just want to know what you think. Talk to me about that.|1.9||Also, let's also discuss the paragraph bit that should be split.|1.6||I'm open to hear your thoughts on long messages.|0" \
     "Okay, I trust you with the Qwen 3 1.7B situation. I just want to know what you think. Talk to me about that. <P> Also, let's also discuss the paragraph bit that should be split. I'm open to hear your thoughts on long messages."
join "one.|1.2||two here. three here.|0"             "One. two here. three here."
join "one sentence here.|2.0||two. three.|0"         "One sentence here. two. three."
join "a b. c d.|2.0||e f. g h.|2.0||i j. k l.|0"     "A b. c d. <P> E f. g h. <P> I j. k l."
join "ends without punctuation|2.0||Next one. and two.|0" "Ends without punctuation next one. and two."
join "a b. c d.|2.0||e f. g h.|2.0||last one.|0"     "A b. c d. <P> E f. g h. last one."
join "a b. c d.|2.0||e f. g h.|2.0||i j. k l.|0"     "A b. c d. e f. g h. i j. k l."      "off"
join "it costs 4.50 today. J. Smith agreed.|2.0||fine. done.|0" "It costs 4.50 today. J. Smith agreed. <P> Fine. done."
rm -rf "$SCRATCH"
exit $fail
