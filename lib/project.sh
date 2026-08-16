#!/usr/bin/env bash
# The two pure functions behind command mode's dispatch, kept apart from
# bin/omantra so they can be exercised without a model, a desktop or a network.
# See test/test_project.sh.

# Reduce anything the model returned to a safe directory name.
#
# This is the security boundary of the whole feature: the JSON schema constrains
# the *shape* of the reply, not its contents, so a model that emits "../../etc"
# has to be defanged here. Everything outside [a-z0-9-] becomes a hyphen, which
# means no slashes, no leading dots, and no path traversal can survive.
slugify() {
  printf '%s' "${1:-}" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9]\+/-/g; s/^-\+//; s/-\+$//' \
    | cut -c1-50
}

# Resolve a slug to a directory under $OMANTRA_PROJECTS, widening from exact to
# case-insensitive to substring. Speech gets names approximately right, so
# "open the todo app" should still find "todo-app-v2".
#
# A glob rather than `ls | grep`, for three reasons: only directories can match
# (a stray file in ~/projects is not a project), a name containing whitespace or
# a newline can't split into two candidates, and there is no pipeline to fail —
# the previous version died on `set -o pipefail` when grep found nothing, taking
# the caller with it, so "no such project" was never reported.
#
# Matching stays fixed-string: `"$want_lc"` is quoted inside the pattern, so a
# model-derived slug is compared literally rather than becoming a glob.
find_project() {
  local want="$1" want_lc entry base lower exact="" substring=""
  [ -z "$want" ] && return 1
  [ -d "$OMANTRA_PROJECTS/$want" ] && { printf '%s' "$want"; return 0; }

  want_lc="${want,,}"
  for entry in "$OMANTRA_PROJECTS"/*/; do
    # Guards the no-match case, where the glob stays literal.
    [ -d "$entry" ] || continue
    base="${entry%/}"
    base="${base##*/}"
    lower="${base,,}"
    if [ "$lower" = "$want_lc" ]; then
      exact="$base"
      break
    fi
    if [ -z "$substring" ] && [[ "$lower" == *"$want_lc"* ]]; then
      substring="$base"
    fi
  done

  entry="${exact:-$substring}"
  [ -z "$entry" ] && return 1
  printf '%s' "$entry"
}
