#!/usr/bin/env bash
# Single source of truth for the paths, versions and defaults that the
# installer and the runtime scripts both need. Sourced, never executed.
#
# Everything here is overridable from the environment, so a terminal and the
# bar widget see the same knobs. The point of the file is that a value is
# written down once: bumping SHERPA_VERSION used to mean editing install.sh and
# omantra-transcribe in step, and forgetting the second one broke transcription
# with a message telling you to run the installer you had just run.
#
# The QML side has its own copy of the two settings it exposes (threads,
# maxSeconds) because the widget reads them through the plugin settings store
# rather than through bash. test/test_config.sh asserts the copies agree.
#
# On top of the environment sits one user-editable file, written by the config
# panel and by `omantra-config`. Precedence is environment > file > default:
# a value you export for one command still wins, which keeps `OMANTRA_ENDPOINT=…
# omantra "…"` working as a way to try a server without committing to it.

# ---- Where things live ------------------------------------------------------

OMANTRA_OPT_DIR="${OMANTRA_OPT_DIR:-$HOME/opt}"
OMANTRA_MODELS_DIR="${OMANTRA_MODELS_DIR:-$HOME/models/asr}"
OMANTRA_STATE_DIR="${OMANTRA_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/omantra}"
OMANTRA_CONFIG_DIR="${OMANTRA_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/omantra}"
OMANTRA_CONFIG_FILE="${OMANTRA_CONFIG_FILE:-$OMANTRA_CONFIG_DIR/config}"

# ---- The settable settings --------------------------------------------------
#
# One row per knob the config panel offers, in the order it shows them:
#
#   variable | type | widget setting key | label
#
# The type drives validation in omantra-config and the JSON type the widget
# reads back; the widget setting key is the name of the same knob in
# manifest.json, or `-` for the ones only bash acts on. Everything that has to
# know the set of settings — the file parser below, the validator, the JSON the
# panel loads, the test that keeps the manifest in step — reads this table, so
# adding a setting is a row here and a field in ConfigPanel.qml.
OMANTRA_SETTINGS=(
  "OMANTRA_ENDPOINT|url|-|Model server (OpenAI-compatible chat completions)"
  "OMANTRA_AGENT|command|-|Coding agent a project is opened with"
  "OMANTRA_PROJECTS|path|-|Where new projects are created"
  "OMANTRA_THREADS|int:1:12|threads|Decoder threads"
  "OMANTRA_MAX_SECONDS|int:10:3600|maxSeconds|Max recording length (seconds)"
  "OMANTRA_COPY_CLIPBOARD|bool|copyToClipboard|Copy transcript to the clipboard"
  "OMANTRA_TYPE_OUT|bool|typeOut|Type transcript into the focused window"
  "OMANTRA_NOTIFY|bool|notify|Show a notification when done"
  "OMANTRA_OVERLAY|bool|overlay|Show the centered speak-now overlay"
)

omantra_setting_row() {
  local row
  for row in "${OMANTRA_SETTINGS[@]}"; do
    [ "${row%%|*}" = "$1" ] && { printf '%s' "$row"; return 0; }
  done
  return 1
}

# The file is read, not sourced. Sourcing would make every setting an
# opportunity to run a command, and this file is written by a GUI — a value with
# a `$(` in it should be a bad endpoint, not an execution.
omantra_load_config() {
  local line key value
  [ -r "$OMANTRA_CONFIG_FILE" ] || return 0

  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in *=*) ;; *) continue ;; esac

    key="${line%%=*}"
    value="${line#*=}"
    key="${key//[[:space:]]/}"
    omantra_setting_row "$key" >/dev/null || continue

    # Leading whitespace and one layer of quotes are typing conveniences for
    # whoever edits the file by hand; omantra-config never writes either.
    value="${value#"${value%%[![:space:]]*}"}"
    case "$value" in
      \"*\") value="${value:1:${#value}-2}" ;;
      \'*\') value="${value:1:${#value}-2}" ;;
    esac
    # shellcheck disable=SC2088  # matching a literal tilde, then expanding
    # it ourselves — the file is data, so the shell never sees it to expand.
    case "$value" in "~/"*) value="$HOME/${value:2}" ;; esac

    # Set, not overwrite: the environment was there first and outranks the file.
    [ -n "${!key+set}" ] && continue
    printf -v "$key" '%s' "$value"
  done < "$OMANTRA_CONFIG_FILE"
}

omantra_load_config

# ---- Speech-to-text runtime -------------------------------------------------

# SHERPA_VERSION is honoured for compatibility with the documented override.
OMANTRA_SHERPA_VERSION="${OMANTRA_SHERPA_VERSION:-${SHERPA_VERSION:-1.13.5}}"
OMANTRA_SHERPA_DIR="${OMANTRA_SHERPA_DIR:-$OMANTRA_OPT_DIR/sherpa-onnx-v$OMANTRA_SHERPA_VERSION-linux-x64-static}"
OMANTRA_SHERPA_BIN="${OMANTRA_SHERPA_BIN:-$OMANTRA_SHERPA_DIR/bin}"

OMANTRA_MODEL_NAME="${OMANTRA_MODEL_NAME:-sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8}"
OMANTRA_MODEL="${OMANTRA_MODEL:-$OMANTRA_MODELS_DIR/$OMANTRA_MODEL_NAME}"

# Regresses past 6 on the 6-core target machine — see the RTF table in README.
OMANTRA_THREADS="${OMANTRA_THREADS:-6}"

OMANTRA_RELEASES="${OMANTRA_RELEASES:-https://github.com/k2-fsa/sherpa-onnx/releases/download}"

# ---- Command mode -----------------------------------------------------------

OMANTRA_ENDPOINT="${OMANTRA_ENDPOINT:-http://127.0.0.1:8081/v1/chat/completions}"
OMANTRA_PROJECTS="${OMANTRA_PROJECTS:-$HOME/projects}"
# The coding agent a project is opened with. One name, so swapping it out is a
# setting rather than an edit to the dispatch.
OMANTRA_AGENT="${OMANTRA_AGENT:-claude}"

# Is anything listening at the endpoint? Deliberately not "is it a good model
# server": any HTTP answer counts, including the 405 llama.cpp returns for a GET
# on the completions path. The question worth asking cheaply is whether the user
# forgot to start the server, and that is the one this answers.
#
# Lives here because both the installer and the interpreter ask it, and a check
# that disagrees with itself is worse than no check.
omantra_endpoint_up() {
  curl -sS -o /dev/null --connect-timeout 2 --max-time 5 "$OMANTRA_ENDPOINT" 2>/dev/null
}

OMANTRA_LOG="${OMANTRA_LOG:-$OMANTRA_STATE_DIR/history.jsonl}"
# The log is the record of what the model heard versus what it did, which is
# only useful recent. Trim rather than grow without bound.
OMANTRA_LOG_MAX_LINES="${OMANTRA_LOG_MAX_LINES:-2000}"

# ---- Widget-facing defaults -------------------------------------------------
# Mirrored in manifest.json; test/test_config.sh keeps them honest. The widget
# reads these through `omantra-config json` and falls back to its own shell.json
# entry, so the panel and the manifest cannot describe different defaults.

OMANTRA_MAX_SECONDS="${OMANTRA_MAX_SECONDS:-300}"
OMANTRA_COPY_CLIPBOARD="${OMANTRA_COPY_CLIPBOARD:-true}"
OMANTRA_TYPE_OUT="${OMANTRA_TYPE_OUT:-false}"
OMANTRA_NOTIFY="${OMANTRA_NOTIFY:-true}"
OMANTRA_OVERLAY="${OMANTRA_OVERLAY:-true}"

OMANTRA_TAP_WINDOW_MS="${OMANTRA_TAP_WINDOW_MS:-400}"
