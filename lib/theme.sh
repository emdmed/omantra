#!/usr/bin/env bash
# Resolving a spoken theme name to a theme Omarchy actually has installed.
# Sourced by bin/omantra; exercised without a desktop by test/test_theme.sh.
#
# Omarchy keeps themes in two places and merges them, user over system, so both
# are searched here. Directory names are the identity — `omarchy-theme-set`
# lowercases and hyphenates whatever it is handed and then looks for a directory
# of that name, which is why matching a slug against directory names is the same
# question as "will omarchy-theme-set accept this".

# Set only if the caller has not: the tests point this at a fixture, and the
# same override lets someone with themes somewhere unusual say so.
if [ -z "${OMANTRA_THEME_DIRS+set}" ]; then
  OMANTRA_THEME_DIRS=(
    "${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/themes"
    "${OMARCHY_PATH:-/usr/share/omarchy}/themes"
  )
fi

# Every installed theme's directory name, deduplicated — a theme present in both
# trees is one theme, not two. Feeds the system prompt, so the model chooses
# from names that exist rather than from what it remembers about Omarchy.
theme_names() {
  local dir entry base
  {
    for dir in "${OMANTRA_THEME_DIRS[@]}"; do
      # A trailing slash so only directories match, and -d to survive the
      # no-match case where the glob stays literal. Symlinked themes are
      # directories too as far as the glob is concerned, which is what we want:
      # `omarchy-theme-list` counts them.
      for entry in "$dir"/*/; do
        [ -d "$entry" ] || continue
        base="${entry%/}"
        printf '%s\n' "${base##*/}"
      done
    done
  } | sort -u
}

# Resolve a slug to an installed theme, widening from exact to substring the way
# find_project does — speech gets names approximately right, so "make it tokyo
# night" and "switch to tokyo" should both land on `tokyo-night`.
#
# Exact wins outright, and only after every candidate has been seen: `catppuccin`
# must not be answered with `catppuccin-latte` just because the substring match
# was found first. Comparison is fixed-string, so a model-derived slug is never
# treated as a pattern.
find_theme() {
  local want="$1" want_lc name lower exact="" substring=""
  [ -z "$want" ] && return 1
  want_lc="${want,,}"

  while IFS= read -r name; do
    [ -z "$name" ] && continue
    lower="${name,,}"
    if [ "$lower" = "$want_lc" ]; then
      exact="$name"
      break
    fi
    if [ -z "$substring" ] && [[ "$lower" == *"$want_lc"* ]]; then
      substring="$name"
    fi
  done < <(theme_names)

  name="${exact:-$substring}"
  [ -z "$name" ] && return 1
  printf '%s' "$name"
}

# `catppuccin-latte` -> `Catppuccin Latte`, for notifications. The same
# transformation `omarchy-theme-list` and `omarchy-theme-current` print with, so
# the name Omantra says a theme is called matches the name Omarchy says.
theme_title() {
  printf '%s' "${1:-}" | sed -E 's/(^|-)([a-z])/\1\u\2/g; s/-/ /g'
}
