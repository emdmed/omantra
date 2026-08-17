#!/usr/bin/env bash
# The theme matcher: string-in/string-out, so no desktop, no Omarchy and no
# model needed. The fixture stands in for the two theme trees Omarchy merges.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/test/lib.sh"

fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/system" "$fixture/user"
mkdir -p \
  "$fixture/system/catppuccin" \
  "$fixture/system/catppuccin-latte" \
  "$fixture/system/tokyo-night" \
  "$fixture/system/nord" \
  "$fixture/system/matte-black"
mkdir -p \
  "$fixture/user/velvetnight" \
  "$fixture/user/nord"

# Set before sourcing: lib/theme.sh only supplies the default when the caller
# has not. User tree first, the order omarchy-theme-set overlays them in.
OMANTRA_THEME_DIRS=("$fixture/user" "$fixture/system")
. "$ROOT/lib/theme.sh"

echo "lib/theme.sh"

# ---- theme_names ------------------------------------------------------------

assert_eq "catppuccin catppuccin-latte matte-black nord tokyo-night velvetnight" \
  "$(theme_names | tr '\n' ' ' | sed 's/ $//')" \
  "lists both trees, sorted, with the duplicate collapsed"

# A theme installed as a symlink is a theme — omarchy-theme-list counts those.
ln -s "$fixture/system/nord" "$fixture/user/linked-theme"
assert_eq "linked-theme" "$(theme_names | grep linked-theme)" \
  "a symlinked theme directory counts"
rm "$fixture/user/linked-theme"

# Only directories. A stray file in a theme tree is not a theme.
touch "$fixture/user/README.md"
assert_eq "" "$(theme_names | grep README || true)" "a plain file is not a theme"
rm "$fixture/user/README.md"

# Saved and restored rather than run in a subshell: assert_eq increments a
# counter, and a subshell's increment never reaches the summary.
empty="$(mktemp -d)"
trees=("${OMANTRA_THEME_DIRS[@]}")
OMANTRA_THEME_DIRS=("$empty")
assert_eq "" "$(theme_names)" "an empty tree lists nothing rather than a literal glob"
OMANTRA_THEME_DIRS=("${trees[@]}")
rmdir "$empty"

# ---- find_theme -------------------------------------------------------------

assert_eq "tokyo-night"  "$(find_theme "tokyo-night")" "exact theme name wins"
assert_eq "velvetnight"  "$(find_theme "velvetnight")" "finds a user theme"
assert_eq "tokyo-night"  "$(find_theme "tokyo")"       "falls back to a substring match"
assert_eq "matte-black"  "$(find_theme "black")"       "matches a substring at the end"
assert_eq "catppuccin-latte" "$(find_theme "latte")"   "matches the more specific variant by its distinguishing word"

# The one that bites: `catppuccin` is a prefix of `catppuccin-latte`, so a
# matcher that returned the first substring hit would answer the wrong theme.
# Exact has to beat substring even when the substring is seen first.
assert_eq "catppuccin" "$(find_theme "catppuccin")" "exact beats a longer theme it is a prefix of"

assert_eq "nord" "$(find_theme "NORD")" "matches case-insensitively"

assert_fails "returns non-zero for no match rather than exiting" \
  find_theme "nothing-like-this"
assert_fails "returns non-zero for an empty name" find_theme ""

# A model-derived name is compared literally, never as a pattern.
assert_fails "does not treat a name as a glob" find_theme "tokyo*"
assert_fails "does not treat a name as a regex" find_theme "n.rd"

# ---- theme_title ------------------------------------------------------------

assert_eq "Tokyo Night"      "$(theme_title "tokyo-night")"      "title-cases for display"
assert_eq "Catppuccin Latte" "$(theme_title "catppuccin-latte")" "title-cases every word"
assert_eq "Nord"             "$(theme_title "nord")"             "leaves a single word alone"
assert_eq ""                 "$(theme_title "")"                 "empty in, empty out"

summary
