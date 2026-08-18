#!/usr/bin/env bash
# `omantra-fetch --check`: the question the widget asks before it lets you
# click the mic, so its answer decides whether a fresh install offers a
# download or a recording. Only the check is tested — the download half is a
# gigabyte over the network and belongs to nobody's test suite.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/test/lib.sh"

fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

version=1.13.5
sherpa="$fixture/opt/sherpa-onnx-v$version-linux-x64-static/bin"
model="$fixture/models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8"

# The environment is the whole fixture: lib/config.sh derives every path below
# from these two, so a check can be run against an empty disk without one.
check() {
  env -u OMANTRA_SHERPA_BIN -u OMANTRA_MODEL \
    OMANTRA_SHERPA_VERSION="$version" \
    OMANTRA_OPT_DIR="$fixture/opt" \
    OMANTRA_MODELS_DIR="$fixture/models" \
    OMANTRA_CONFIG_FILE="$fixture/config" \
    "$ROOT/bin/omantra-fetch" --check 2>&1
}

echo "bin/omantra-fetch --check"

# ---- nothing downloaded -----------------------------------------------------

assert_fails "an empty disk is not ready" check
out="$(check || true)"
case "$out" in *"sherpa-onnx $version"*) pass "names the missing runtime" ;;
  *) fail "names the missing runtime"; echo "       actual: $out" ;; esac
TESTS_RUN=$((TESTS_RUN + 1))
case "$out" in *parakeet*) pass "names the missing model" ;;
  *) fail "names the missing model"; echo "       actual: $out" ;; esac
TESTS_RUN=$((TESTS_RUN + 1))

# ---- half downloaded --------------------------------------------------------

mkdir -p "$sherpa"
touch "$sherpa/sherpa-onnx-offline"
chmod +x "$sherpa/sherpa-onnx-offline"
assert_fails "the runtime without the model is not ready" check

# ---- both there -------------------------------------------------------------

mkdir -p "$model"
# Every file the profile's flags name, not just the encoder: readiness is now
# derived from the command line, so a half-unpacked archive is not "ready".
touch "$model/encoder.int8.onnx" "$model/decoder.int8.onnx" \
      "$model/joiner.int8.onnx" "$model/tokens.txt"
if check >/dev/null 2>&1; then
  pass "runtime plus model is ready"
else
  fail "runtime plus model is ready"
fi
TESTS_RUN=$((TESTS_RUN + 1))

# The VAD is downloaded alongside the rest but nothing reads it yet, so it must
# not be what stands between a fresh install and a working mic.
out="$(check)"
case "$out" in *silero*) pass "mentions the absent VAD without failing on it" ;;
  *) fail "mentions the absent VAD without failing on it"; echo "       actual: $out" ;; esac
TESTS_RUN=$((TESTS_RUN + 1))

# A file the decoder would open and not find is the case the old single-probe
# check got wrong: an encoder present and a joiner missing read as installed.
rm "$model/joiner.int8.onnx"
assert_fails "a model missing one of its graphs is not ready" check
touch "$model/joiner.int8.onnx"

# ---- a non-executable binary is not a binary --------------------------------

chmod -x "$sherpa/sherpa-onnx-offline"
assert_fails "an unextracted (non-executable) sherpa binary is not ready" check

summary
