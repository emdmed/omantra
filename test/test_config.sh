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
# developer's shell can't make a mismatch look like agreement.
config_value() { env -u "$1" -i HOME="$HOME" bash -c ". '$ROOT/lib/config.sh'; printf '%s' \"\${$1}\""; }

# The literal in `setting("key", <default>)`.
qml_default() { sed -n "s/.*setting(\"$1\", \\([^)]*\\)).*/\\1/p" "$WIDGET" | head -1; }

echo "defaults agree across config.sh / manifest.json / BarWidget.qml"

assert_eq "$(config_value OMANTRA_THREADS)" \
          "$(jq -r '.barWidget.defaults.threads' "$MANIFEST")" \
          "threads: config.sh matches manifest defaults"
assert_eq "$(config_value OMANTRA_THREADS)" "$(qml_default threads)" \
          "threads: config.sh matches the QML fallback"

assert_eq "$(config_value OMANTRA_MAX_SECONDS)" \
          "$(jq -r '.barWidget.defaults.maxSeconds' "$MANIFEST")" \
          "maxSeconds: config.sh matches manifest defaults"
assert_eq "$(config_value OMANTRA_MAX_SECONDS)" "$(qml_default maxSeconds)" \
          "maxSeconds: config.sh matches the QML fallback"

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
