#!/usr/bin/env bash
# Defaults live in three places that cannot import from each other: lib/config.sh
# (bash), manifest.json (the plugin settings store) and BarWidget.qml (the
# fallback used when a setting has never been written). Nothing stops them
# drifting apart except this file.
#
# Drift here is quiet and nasty: the widget transcribes with one thread count
# and the terminal you debug it in uses another, so the numbers in the README's
# RTF table stop describing either.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/test/lib.sh"

MANIFEST="$ROOT/manifest.json"
WIDGET="$ROOT/BarWidget.qml"

# Source the config in a clean environment so an exported override in the
# developer's shell can't make a mismatch look like agreement — and with the
# config file pointed at nothing, so the developer's own saved settings are not
# mistaken for the built-in defaults either.
config_value() {
  env -u "$1" -i HOME="$HOME" OMANTRA_CONFIG_FILE=/dev/null \
    bash -c ". '$ROOT/lib/config.sh'; printf '%s' \"\${$1}\""
}

# The literal in `setting("key", <default>)`.
qml_default() { sed -n "s/.*setting(\"$1\", \\([^)]*\\)).*/\\1/p" "$WIDGET" | head -1; }

# The settings table in config.sh names, for each variable, the manifest key
# that is the same knob — so the list of things to check is the list itself
# rather than a copy of it that can fall behind.
settings_table() {
  env -i HOME="$HOME" OMANTRA_CONFIG_FILE=/dev/null \
    bash -c ". '$ROOT/lib/config.sh'; printf '%s\n' \"\${OMANTRA_SETTINGS[@]}\""
}

echo "defaults agree across config.sh / manifest.json / BarWidget.qml"

while IFS='|' read -r var _ key _; do
  [ "$key" = "-" ] && continue
  assert_eq "$(config_value "$var")" \
            "$(jq -r --arg k "$key" '.barWidget.defaults[$k]' "$MANIFEST")" \
            "$key: config.sh ($var) matches manifest defaults"
  assert_eq "$(config_value "$var")" "$(qml_default "$key")" \
            "$key: config.sh ($var) matches the QML fallback"
done < <(settings_table)

echo
echo "the config panel offers every setting"

# A knob added to the table but not to the panel is invisible to anyone who
# never opens a terminal — which is the audience the panel is for.
PANEL="$ROOT/ConfigPanel.qml"
while IFS='|' read -r var _ _ _; do
  if grep -q "\"$var\"" "$PANEL"; then
    pass "$var has a field in ConfigPanel.qml"
  else
    fail "$var is settable but ConfigPanel.qml never mentions it"
  fi
  TESTS_RUN=$((TESTS_RUN + 1))
done < <(settings_table)

echo
echo "manifest.json is internally consistent"

# Every settable key needs a default, and the schema's own defaultValue has to
# agree with the defaults block — the store reads one, the settings UI shows the
# other.
while read -r key; do
  assert_eq "$(jq -r --arg k "$key" '.barWidget.defaults[$k]' "$MANIFEST")" \
            "$(jq -r --arg k "$key" '.barWidget.schema[] | select(.key == $k) | .defaultValue' "$MANIFEST")" \
            "$key: schema defaultValue matches the defaults block"
done < <(jq -r '.barWidget.schema[].key' "$MANIFEST")

assert_eq "$(jq -r '.barWidget.schema | length' "$MANIFEST")" \
          "$(jq -r '.barWidget.defaults | length' "$MANIFEST")" \
          "every default has a schema entry and vice versa"

echo
echo "the QML reads only settings the manifest declares"

# A `setting("typo", …)` silently returns its fallback forever, which reads as
# "the setting does nothing" and is a genuinely slow bug to find.
while read -r key; do
  if jq -e --arg k "$key" '.barWidget.defaults | has($k)' "$MANIFEST" >/dev/null; then
    pass "$key is declared in the manifest"
    TESTS_RUN=$((TESTS_RUN + 1))
  else
    fail "$key is read by BarWidget.qml but not declared in the manifest"
    TESTS_RUN=$((TESTS_RUN + 1))
  fi
done < <(sed -n 's/.*setting("\([a-zA-Z]*\)".*/\1/p' "$WIDGET" | sort -u)

summary
