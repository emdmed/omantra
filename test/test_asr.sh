#!/usr/bin/env bash
# The model table: which flags each family needs, and which files those flags
# name. Pure string-in/string-out, so no model and no network — which is the
# point of having it, since the alternative is discovering a wrong row by
# speaking into a microphone.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/test/lib.sh"

fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

OMANTRA_CONFIG_FILE="$fixture/config"
OMANTRA_MODELS_DIR="$fixture/models"
export OMANTRA_CONFIG_FILE OMANTRA_MODELS_DIR
. "$ROOT/lib/config.sh"

echo "lib/asr.sh"

# ---- the default -----------------------------------------------------------

assert_eq "parakeet-v2" "$OMANTRA_ASR_PROFILE" "parakeet-v2 is the default profile"
assert_fails "an unknown profile has no row" asr_row no-such-model

# ---- a transducer ----------------------------------------------------------
#
# The exact command line omantra-transcribe used to carry as a literal.
p=parakeet-v2
d="$OMANTRA_MODELS_DIR/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8"
assert_eq "$d" "$(asr_model_dir $p)" "the profile names its own directory"
assert_eq "--encoder=$d/encoder.int8.onnx
--decoder=$d/decoder.int8.onnx
--joiner=$d/joiner.int8.onnx
--tokens=$d/tokens.txt
--model-type=nemo_transducer" "$(asr_args $p)" "a transducer takes three graphs and a model type"

# ---- whisper ---------------------------------------------------------------
#
# The family that would break a path-swap abstraction: different flags, and
# every file prefixed with the model stem.
p=whisper-tiny.en
d="$OMANTRA_MODELS_DIR/sherpa-onnx-whisper-tiny.en"
assert_eq "--whisper-encoder=$d/tiny.en-encoder.int8.onnx
--whisper-decoder=$d/tiny.en-decoder.int8.onnx
--tokens=$d/tiny.en-tokens.txt" "$(asr_args $p)" "whisper takes its own flags and stem-prefixed files"

# ---- files come from the flags ---------------------------------------------
#
# The property worth protecting: the readiness check and the command line are
# the same list, so nothing can approve a model the decoder cannot open.
assert_eq "$d/tiny.en-encoder.int8.onnx
$d/tiny.en-decoder.int8.onnx
$d/tiny.en-tokens.txt" "$(asr_files whisper-tiny.en)" "every path in the flags is a file to check for"
assert_eq "4" "$(asr_files parakeet-v2 | wc -l)" "--model-type is a switch, not a file"

# ---- every row carries a digest ---------------------------------------------
#
# A row without one is not a model this can install: the archive is fetched from
# a mutable release asset and unpacked next to a binary that gets executed, so
# the digest is the row's load-bearing column rather than a nicety. Checked for
# every profile, because the one that gets forgotten is the one added last.
for id in $(asr_ids); do
  digest="$(asr_sha256 "$id")"
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] && ok=yes || ok=no
  assert_eq "yes" "$ok" "$id pins a 64-hex sha256"
done

# The note is still the note, which is the thing a shifted column would break
# silently — the panel would offer digests as descriptions.
case "$(asr_note parakeet-v2)" in
  *"English only"*) pass "the note column survived the digest column" ;;
  *) fail "the note column survived the digest column" ;;
esac
TESTS_RUN=$((TESTS_RUN + 1))

# ---- readiness -------------------------------------------------------------

assert_fails "an empty models dir is not ready" asr_ready parakeet-v2

mkdir -p "$OMANTRA_MODELS_DIR/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8"
while IFS= read -r f; do touch "$f"; done < <(asr_files parakeet-v2)
if asr_ready parakeet-v2; then pass "every file present is ready"; else fail "every file present is ready"; fi
TESTS_RUN=$((TESTS_RUN + 1))

# One profile's files must not vouch for another's — the bug where a derived
# OMANTRA_MODEL made every profile resolve to the current one's directory.
assert_fails "a downloaded model does not make its neighbour ready" asr_ready whisper-tiny.en

# ---- the explicit override -------------------------------------------------
#
# Documented before profiles existed and still honoured: a hand-set
# OMANTRA_MODEL points at a directory of your own.
assert_eq "/somewhere/mine" \
  "$(OMANTRA_MODEL_EXPLICIT=1 OMANTRA_MODEL=/somewhere/mine asr_model_dir parakeet-v2)" \
  "a hand-set OMANTRA_MODEL outranks the profile"

summary
