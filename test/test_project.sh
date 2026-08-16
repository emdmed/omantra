#!/usr/bin/env bash
# The slug sanitiser and the project matcher: the two functions command mode's
# safety rests on. Both are string-in/string-out, so neither needs a model, a
# desktop or a network to exercise.
#
# Run under the same `set -euo pipefail` the real script uses, because a couple
# of the bugs these cover were *caused* by those flags rather than caught by
# them.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/test/lib.sh"
. "$ROOT/lib/project.sh"

echo "lib/project.sh"

# ---- slugify ----------------------------------------------------------------

assert_eq "todo-app"   "$(slugify "todo-app")"        "passes a clean slug through"
assert_eq "todo-app"   "$(slugify "Todo App")"        "lowercases and joins words"
assert_eq "todo-app"   "$(slugify "  todo   app  ")"  "collapses runs of separators"
assert_eq "todo-app"   "$(slugify "todo_app")"        "treats underscores as separators"
assert_eq "todo-app-2" "$(slugify "Todo App 2!")"     "keeps digits, drops punctuation"
assert_eq ""           "$(slugify "")"                "empty in, empty out"
assert_eq ""           "$(slugify "!!!")"             "punctuation alone slugs to nothing"

# The security boundary: nothing the model can emit may escape $OMANTRA_PROJECTS.
assert_eq "etc-passwd" "$(slugify "../../etc/passwd")" "path traversal cannot survive"
assert_eq "hidden"     "$(slugify ".hidden")"          "leading dot is stripped"
assert_eq "a-b"        "$(slugify "a/b")"              "slashes cannot survive"
assert_eq "rm-rf"      "$(slugify "; rm -rf ~")"       "shell metacharacters cannot survive"
long="$(slugify "$(printf 'a%.0s' {1..200})")"
assert_eq 50 "${#long}" "truncates to 50 characters"

# ---- find_project -----------------------------------------------------------

fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/todo-app" "$fixture/Notes" "$fixture/omantra-widget"

OMANTRA_PROJECTS="$fixture"

assert_eq "todo-app"       "$(find_project "todo-app")"  "exact directory name wins"
assert_eq "Notes"          "$(find_project "notes")"     "matches case-insensitively"
assert_eq "omantra-widget" "$(find_project "omantra")"   "falls back to a substring match"

# This is the regression that matters most: under `set -euo pipefail` a grep
# that matched nothing used to fail the pipeline, fail the assignment and kill
# the whole script — so "No such project" was unreachable and command mode just
# died in silence.
assert_fails "returns non-zero for no match rather than exiting" \
  find_project "nothing-like-this"
assert_fails "returns non-zero for an empty slug" find_project ""

# A slug must be compared literally, not as a pattern.
mkdir -p "$fixture/a.c"
assert_fails "does not treat a slug as a regex" find_project "axc"
assert_fails "does not treat a slug as a glob" find_project "todo*"

# Only directories are projects. A stray file in ~/projects used to be a
# candidate, because the old implementation listed the directory rather than
# globbing it.
touch "$fixture/scratch-notes.txt"
assert_fails "a plain file is not a project" find_project "scratch-notes"

# Nor may a name with whitespace split into two candidates.
mkdir -p "$fixture/two words"
assert_eq "two words" "$(find_project "two words")" "matches a name containing a space"

summary
