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

# ---- Where things live ------------------------------------------------------

OMANTRA_OPT_DIR="${OMANTRA_OPT_DIR:-$HOME/opt}"
OMANTRA_MODELS_DIR="${OMANTRA_MODELS_DIR:-$HOME/models/asr}"
OMANTRA_STATE_DIR="${OMANTRA_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/omantra}"

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

OMANTRA_LOG="${OMANTRA_LOG:-$OMANTRA_STATE_DIR/history.jsonl}"
# The log is the record of what the model heard versus what it did, which is
# only useful recent. Trim rather than grow without bound.
OMANTRA_LOG_MAX_LINES="${OMANTRA_LOG_MAX_LINES:-2000}"

# ---- Widget-facing defaults -------------------------------------------------
# Mirrored in manifest.json; test/test_config.sh keeps them honest.

OMANTRA_MAX_SECONDS="${OMANTRA_MAX_SECONDS:-300}"
OMANTRA_TAP_WINDOW_MS="${OMANTRA_TAP_WINDOW_MS:-400}"
