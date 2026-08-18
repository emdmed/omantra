#!/usr/bin/env bash
# `omantra-fetch --check`: the question the widget asks before it lets you
# click the mic, so its answer decides whether a fresh install offers a
# download or a recording.
#
# And the digest check, which is the other half of what this script is for: the
# real download is a gigabyte over the network and belongs to nobody's test
# suite, but OMANTRA_RELEASES is a setting, so a release can be a directory of
# small files served over file:// — and then "what happens when the bytes are
# not the bytes we recorded" is a test rather than a hope.
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

# ---- the digest is what makes a download installable ------------------------
#
# sherpa-onnx is the one that matters: the archive carries the binary every
# transcription then executes, so an archive nobody checked is a program nobody
# checked. A fake release over file:// exercises the real path — download,
# verify, unpack — at four kilobytes instead of four hundred megabytes.

echo
echo "bin/omantra-fetch (digests)"

releases="$fixture/releases"
fake_version=9.9.9
mkdir -p "$releases/v$fake_version" "$releases/asr-models"

# An archive shaped like the real one: the binary lands where have_sherpa looks.
staging="$fixture/staging/sherpa-onnx-v$fake_version-linux-x64-static/bin"
mkdir -p "$staging"
printf '#!/bin/sh\necho fake\n' > "$staging/sherpa-onnx-offline"
chmod +x "$staging/sherpa-onnx-offline"
tar cjf "$releases/v$fake_version/sherpa-onnx-v$fake_version-linux-x64-static.tar.bz2" \
  -C "$fixture/staging" "sherpa-onnx-v$fake_version-linux-x64-static"
good="$(sha256sum "$releases/v$fake_version/sherpa-onnx-v$fake_version-linux-x64-static.tar.bz2" | cut -d\  -f1)"

# The model and the VAD are already on disk from the checks above, so each run
# below has exactly one thing left to download: the runtime under test.
touch "$fixture/models/silero_vad.onnx"

fetch() {
  env -u OMANTRA_SHERPA_BIN -u OMANTRA_MODEL \
    OMANTRA_SHERPA_VERSION="$fake_version" \
    OMANTRA_SHERPA_SHA256="$1" \
    OMANTRA_RELEASES="file://$releases" \
    OMANTRA_OPT_DIR="$fixture/opt" \
    OMANTRA_MODELS_DIR="$fixture/models" \
    OMANTRA_CONFIG_FILE="$fixture/config" \
    "$ROOT/bin/omantra-fetch" 2>&1
}

installed="$fixture/opt/sherpa-onnx-v$fake_version-linux-x64-static/bin/sherpa-onnx-offline"

# A digest that does not match is the whole point: nothing is unpacked, so the
# binary that would have been run never reaches the disk.
out="$(fetch 0000000000000000000000000000000000000000000000000000000000000000 || true)"
if [ -e "$installed" ]; then
  fail "a mismatched digest installs nothing"
  echo "       actual: $installed exists"
else
  pass "a mismatched digest installs nothing"
fi
TESTS_RUN=$((TESTS_RUN + 1))
case "$out" in *"does not match"*"$good"*) pass "and says what it got instead" ;;
  *) fail "and says what it got instead"; echo "       actual: $out" ;; esac
TESTS_RUN=$((TESTS_RUN + 1))

assert_fails "a mismatched digest is a failure, not a warning" \
  fetch 0000000000000000000000000000000000000000000000000000000000000000

# A version with no digest recorded anywhere is refused before the download,
# not after: the empty string is not a digest that happens to match nothing.
out="$(env -u OMANTRA_SHERPA_BIN -u OMANTRA_MODEL \
  OMANTRA_SHERPA_VERSION="$fake_version" \
  OMANTRA_RELEASES="file://$releases" \
  OMANTRA_OPT_DIR="$fixture/opt" \
  OMANTRA_MODELS_DIR="$fixture/models" \
  OMANTRA_CONFIG_FILE="$fixture/config" \
  "$ROOT/bin/omantra-fetch" 2>&1 || true)"
case "$out" in *"no SHA-256 recorded"*) pass "an unpinned version is refused, not downloaded" ;;
  *) fail "an unpinned version is refused, not downloaded"; echo "       actual: $out" ;; esac
TESTS_RUN=$((TESTS_RUN + 1))

# And the matching digest installs, or the check above would pass by never
# working at all.
fetch "$good" >/dev/null 2>&1 || true
if [ -x "$installed" ]; then
  pass "the recorded digest installs the runtime"
else
  fail "the recorded digest installs the runtime"
fi
TESTS_RUN=$((TESTS_RUN + 1))

summary
