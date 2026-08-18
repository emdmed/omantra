#!/usr/bin/env bash
# Which speech model, and how sherpa-onnx has to be called to use it.
#
# The reason this is a table rather than a few variables: sherpa supports
# several model families and they do not share a calling convention. A NeMo
# transducer is three graphs and a `--model-type`; Whisper is two graphs under
# flags of its own, with every file prefixed by the model stem
# (`tiny.en-encoder.int8.onnx`); SenseVoice is one. So "use a different model"
# is not a path swap — it is a different command line — and the thing worth
# writing down once is the row that produces it.
#
# One row per model, and one function per family. Adding a model you can see on
# the sherpa releases page is a row; adding a family sherpa supports and this
# does not is a row and a case branch.
#
#   id | family | directory (= archive name) | precision | stem | sha256 | note
#
# `precision` is int8 or fp32, and picks the `.int8.onnx` files out of an
# archive that ships both. `stem` is the per-file prefix Whisper-style archives
# use and everything else leaves empty.
#
# `sha256` is the archive's digest, and it is not optional. These downloads are
# release assets on a repository we do not control, and a release asset is
# mutable — the same URL can be made to serve different bytes tomorrow, and
# those bytes are unpacked next to a binary this then executes. Pinning the
# digest here is what makes "the model the row describes" a fact rather than a
# hope, so adding a row means fetching the archive once and recording what came
# back. The digests below are GitHub's own published asset digests, except
# whisper-tiny.en, which predates that field and was hashed from the download.
#
# Sourced by lib/config.sh, which is sourced by everything.

OMANTRA_ASR_PROFILES=(
  "parakeet-v2|transducer|sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8|int8||157c157bc51155e03e37d2466522a3a737dd9c72bb25f36eb18912964161e1ad|English only, ~660 MB. The default: fastest of these on a CPU."
  "parakeet-v3|transducer|sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8|int8||5793d0fd397c5778d2cf2126994d58e9d56b1be7c04d13c7a15bb1b4eafb16bf|25 European languages, ~464 MB."
  "whisper-tiny.en|whisper|sherpa-onnx-whisper-tiny.en|int8|tiny.en|2bd6cf965c8bb3e068ef9fa2191387ee63a9dfa2a4e37582a8109641c20005dd|English only, ~112 MB. Small and quick, and noticeably less accurate."
)

# The row for a profile id, or nothing. Every accessor below goes through this,
# so an unknown profile fails in one place with one message.
asr_row() {
  local row
  for row in "${OMANTRA_ASR_PROFILES[@]}"; do
    [ "${row%%|*}" = "$1" ] && { printf '%s' "$row"; return 0; }
  done
  return 1
}

asr_ids() {
  local row
  for row in "${OMANTRA_ASR_PROFILES[@]}"; do printf '%s\n' "${row%%|*}"; done
}

# field <n> <id> — 1-indexed column of the row.
asr_field() {
  local row
  row="$(asr_row "$2")" || return 1
  printf '%s' "$row" | cut -d'|' -f"$1"
}

asr_family()    { asr_field 2 "$1"; }
asr_dirname()   { asr_field 3 "$1"; }
asr_precision() { asr_field 4 "$1"; }
asr_stem()      { asr_field 5 "$1"; }
asr_sha256()    { asr_field 6 "$1"; }
asr_note()      { asr_field 7 "$1"; }

asr_url() {
  printf '%s/asr-models/%s.tar.bz2' "$OMANTRA_RELEASES" "$(asr_dirname "$1")"
}

# Where the profile's files live. A hand-set OMANTRA_MODEL still wins, so the
# documented "point it at a directory of my own" override outlives the arrival
# of profiles — but only when a person set it, not when lib/config.sh derived
# one from the profile itself.
asr_model_dir() {
  if [ -n "${OMANTRA_MODEL_EXPLICIT:-}" ]; then printf '%s' "$OMANTRA_MODEL"; return 0; fi
  printf '%s/%s' "$OMANTRA_MODELS_DIR" "$(asr_dirname "$1")"
}

# The sherpa flags for a profile, one per line so a caller can read them into
# an array without a word-splitting hazard.
#
# This is also where readiness comes from: `asr_files` below is the same list
# with the flag names stripped, so the check the widget runs and the command
# the transcriber runs cannot describe different files. That was the bug this
# table is shaped to prevent — a checker that says "installed" about a model
# the decoder then cannot open.
asr_args() {
  local id="$1" dir suffix stem
  dir="$(asr_model_dir "$id")"
  [ "$(asr_precision "$id")" = "int8" ] && suffix=".int8" || suffix=""
  stem="$(asr_stem "$id")"
  [ -n "$stem" ] && stem="$stem-"

  case "$(asr_family "$id")" in
    transducer)
      printf -- '--encoder=%s/%sencoder%s.onnx\n' "$dir" "$stem" "$suffix"
      printf -- '--decoder=%s/%sdecoder%s.onnx\n' "$dir" "$stem" "$suffix"
      printf -- '--joiner=%s/%sjoiner%s.onnx\n' "$dir" "$stem" "$suffix"
      printf -- '--tokens=%s/%stokens.txt\n' "$dir" "$stem"
      printf -- '--model-type=nemo_transducer\n'
      ;;
    whisper)
      printf -- '--whisper-encoder=%s/%sencoder%s.onnx\n' "$dir" "$stem" "$suffix"
      printf -- '--whisper-decoder=%s/%sdecoder%s.onnx\n' "$dir" "$stem" "$suffix"
      printf -- '--tokens=%s/%stokens.txt\n' "$dir" "$stem"
      ;;
    # Written from sherpa's documented flags and not exercised here — no
    # profile above uses it, so it is a starting point for a row rather than a
    # tested path. The archive is 999 MB, which is why it is not shipped as a
    # default anybody might pick by accident.
    sense-voice)
      printf -- '--sense-voice-model=%s/%smodel%s.onnx\n' "$dir" "$stem" "$suffix"
      printf -- '--tokens=%s/%stokens.txt\n' "$dir" "$stem"
      ;;
    *)
      return 1
      ;;
  esac
}

# Every file the profile needs on disk, derived from the flags above. A flag
# without a `/` in its value is a switch rather than a path — `--model-type`
# is the one that matters — and is not something to look for on disk.
asr_files() {
  local arg value
  while IFS= read -r arg; do
    value="${arg#*=}"
    case "$value" in */*) printf '%s\n' "$value" ;; esac
  done < <(asr_args "$1")
}

# Is every one of them there? Silent; the caller decides what to say.
asr_ready() {
  local f
  while IFS= read -r f; do
    [ -f "$f" ] || return 1
  done < <(asr_files "$1")
  return 0
}
