#!/usr/bin/env bash
# The settings file is the one thing the config panel and the scripts both
# depend on, and it is read by a hand-written parser rather than by `source` —
# so the parser's edges are worth pinning down: precedence, quoting, junk lines,
# and the keys a file is allowed to set at all.
#
# Every case runs against a throwaway config file. Nothing here touches the
# developer's own ~/.config/omantra/config, and nothing needs a model, a desktop
# or a network.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/test/lib.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
CONFIG="$TMP/config"

# Read a variable the way a script would: clean environment, our config file,
# and any VAR=value pairs after the name exported into it. `env -i` matters —
# an OMANTRA_* exported in the shell running the suite would otherwise beat the
# file and every precedence assertion would pass for the wrong reason.
read_with() {
  local var="$1"; shift
  env -i HOME="$HOME" PATH="$PATH" OMANTRA_CONFIG_FILE="$CONFIG" "$@" \
    bash -c ". '$ROOT/lib/config.sh'; printf '%s' \"\$$var\""
}
read_value() { read_with "$1"; }

config_cli() {
  env -i HOME="$HOME" PATH="$PATH" OMANTRA_CONFIG_FILE="$CONFIG" \
    "$ROOT/bin/omantra-config" "$@"
}

echo "the file is read, and the environment outranks it"

cat > "$CONFIG" <<'EOF'
# a comment
OMANTRA_AGENT=codex

OMANTRA_THREADS=2
junk without an equals sign
OMANTRA_PROJECTS=~/code
OMANTRA_ENDPOINT="http://10.0.0.2:8081/v1/chat/completions"
OMANTRA_STATE_DIR=/tmp/should-be-ignored
EOF

assert_eq "codex" "$(read_value OMANTRA_AGENT)" "a file value is used"
assert_eq "2" "$(read_value OMANTRA_THREADS)" "a file value beats the built-in default"
assert_eq "zed" "$(read_with OMANTRA_AGENT OMANTRA_AGENT=zed)" \
  "the environment beats the file"
assert_eq "$HOME/code" "$(read_value OMANTRA_PROJECTS)" \
  "a leading ~/ is expanded, so a hand-typed path works"
assert_eq "http://10.0.0.2:8081/v1/chat/completions" "$(read_value OMANTRA_ENDPOINT)" \
  "surrounding quotes are stripped"
assert_eq "${XDG_STATE_HOME:-$HOME/.local/state}/omantra" "$(read_value OMANTRA_STATE_DIR)" \
  "a variable outside the settings table is ignored"

echo
echo "the file cannot run anything"

# The parser must treat a value as text. If it ever grows a `source`, this is
# the assertion that catches it: the marker file appears and the value is the
# literal string.
cat > "$CONFIG" <<EOF
OMANTRA_AGENT=\$(touch "$TMP/pwned")
EOF
got="$(read_value OMANTRA_AGENT)"
# shellcheck disable=SC2016  # the literal, unexpanded text is the assertion.
assert_eq '$(touch "'"$TMP"'/pwned")' "$got" "a command substitution stays a string"
assert_fails "and is never executed" test -e "$TMP/pwned"

echo
echo "omantra-config writes what it is asked for"

rm -f "$CONFIG"
config_cli set OMANTRA_AGENT codex OMANTRA_THREADS 4 >/dev/null
assert_eq "codex" "$(config_cli get OMANTRA_AGENT)" "set then get returns the value"
assert_eq "4" "$(config_cli get OMANTRA_THREADS)" "several pairs in one call"

config_cli set OMANTRA_THREADS 8 >/dev/null
assert_eq "8" "$(config_cli get OMANTRA_THREADS)" "a second write updates the value"
assert_eq "1" "$(grep -c '^OMANTRA_THREADS=' "$CONFIG")" \
  "rewritten in place rather than appended twice"

printf '# hand-written note\n' >> "$CONFIG"
config_cli set OMANTRA_AGENT claude >/dev/null
assert_eq "1" "$(grep -c '^# hand-written note$' "$CONFIG")" \
  "comments survive a save"

config_cli unset OMANTRA_THREADS >/dev/null
assert_eq "6" "$(config_cli get OMANTRA_THREADS)" "unset restores the built-in default"
assert_eq "0" "$(grep -c '^OMANTRA_THREADS=' "$CONFIG")" "and drops the line"

echo
echo "omantra-config rejects what the panel must not be able to save"

assert_fails "an unknown key" config_cli set OMANTRA_NONSENSE 1
assert_fails "a non-numeric thread count" config_cli set OMANTRA_THREADS many
assert_fails "a thread count out of range" config_cli set OMANTRA_THREADS 99
assert_fails "a recording length under the floor" config_cli set OMANTRA_MAX_SECONDS 1
assert_fails "a boolean that isn't one" config_cli set OMANTRA_NOTIFY yes
assert_fails "an endpoint that isn't a URL" config_cli set OMANTRA_ENDPOINT 127.0.0.1:8081
assert_fails "an agent with arguments" config_cli set OMANTRA_AGENT "claude --resume"
assert_fails "a relative projects directory" config_cli set OMANTRA_PROJECTS code
assert_fails "an odd number of arguments" config_cli set OMANTRA_AGENT claude OMANTRA_THREADS
assert_fails "unsetting something unknown" config_cli unset OMANTRA_NONSENSE

# A rejected write must leave the file alone — a panel that fails validation on
# the third field should not have committed the first two.
before="$(cat "$CONFIG")"
config_cli set OMANTRA_AGENT codex OMANTRA_THREADS 99 >/dev/null 2>&1
assert_eq "$before" "$(cat "$CONFIG")" "a rejected write changes nothing at all"

echo
echo "the JSON the panel reads is typed"

config_cli set OMANTRA_THREADS 4 OMANTRA_NOTIFY false >/dev/null
json="$(config_cli json)"
assert_eq "number" "$(jq -r '.OMANTRA_THREADS | type' <<<"$json")" "an integer is a number"
assert_eq "boolean" "$(jq -r '.OMANTRA_NOTIFY | type' <<<"$json")" "a boolean is a boolean"
assert_eq "false" "$(jq -r '.OMANTRA_NOTIFY' <<<"$json")" "and carries the saved value"
assert_eq "string" "$(jq -r '.OMANTRA_ENDPOINT | type' <<<"$json")" "an endpoint is a string"
assert_eq "$CONFIG" "$(jq -r '.configFile' <<<"$json")" "the panel is told where the file is"

# Every settable key has to appear, or the panel silently stops offering one.
missing=0
while IFS='|' read -r key _; do
  jq -e --arg k "$key" 'has($k)' <<<"$json" >/dev/null || missing=$((missing + 1))
done < <(env -i HOME="$HOME" PATH="$PATH" OMANTRA_CONFIG_FILE=/dev/null \
  bash -c ". '$ROOT/lib/config.sh'; printf '%s\n' \"\${OMANTRA_SETTINGS[@]}\"")
assert_eq "0" "$missing" "every setting in the table reaches the panel"

summary
