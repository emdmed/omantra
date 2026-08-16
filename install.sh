#!/usr/bin/env bash
# Install the speech-to-text runtime this plugin drives, then wire the plugin
# into the Omarchy shell. Safe to re-run: every step is skipped when already
# satisfied.
set -euo pipefail

SHERPA_VERSION="${SHERPA_VERSION:-1.13.5}"
MODEL_NAME="sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8"
RELEASES="https://github.com/k2-fsa/sherpa-onnx/releases/download"

OPT="$HOME/opt"
MODELS="$HOME/models/asr"
LOCAL_BIN="$HOME/.local/bin"
PLUGIN_ID="enrique.omantra"
PLUGIN_DIR="$HOME/.config/omarchy/plugins/$PLUGIN_ID"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

say() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

# ---- Dependencies -----------------------------------------------------------

missing=()
for cmd in ffmpeg jq curl pw-record wl-copy notify-send xdg-terminal-exec; do
  command -v "$cmd" >/dev/null || missing+=("$cmd")
done
if [ ${#missing[@]} -gt 0 ]; then
  echo "Missing commands: ${missing[*]}" >&2
  echo "On Omarchy: omarchy pkg add ffmpeg jq curl pipewire-tools wl-clipboard libnotify xdg-terminal-exec" >&2
  exit 1
fi

# ---- sherpa-onnx runtime ----------------------------------------------------

SHERPA_DIR="$OPT/sherpa-onnx-v$SHERPA_VERSION-linux-x64-static"
if [ -x "$SHERPA_DIR/bin/sherpa-onnx-offline" ]; then
  say "sherpa-onnx $SHERPA_VERSION already installed"
else
  say "Installing sherpa-onnx $SHERPA_VERSION (~400 MB download)"
  mkdir -p "$OPT"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  curl -fL --progress-bar \
    -o "$tmp/sherpa.tar.bz2" \
    "$RELEASES/v$SHERPA_VERSION/sherpa-onnx-v$SHERPA_VERSION-linux-x64-static.tar.bz2"
  tar xf "$tmp/sherpa.tar.bz2" -C "$OPT"
fi

# ---- Parakeet model ---------------------------------------------------------

if [ -f "$MODELS/$MODEL_NAME/encoder.int8.onnx" ]; then
  say "Parakeet model already installed"
else
  say "Installing $MODEL_NAME (~660 MB)"
  mkdir -p "$MODELS"
  curl -fL --progress-bar \
    -o "$MODELS/model.tar.bz2" \
    "$RELEASES/asr-models/$MODEL_NAME.tar.bz2"
  tar xf "$MODELS/model.tar.bz2" -C "$MODELS"
  rm -f "$MODELS/model.tar.bz2"
fi

if [ ! -f "$MODELS/silero_vad.onnx" ]; then
  say "Installing Silero VAD"
  curl -fL --progress-bar -o "$MODELS/silero_vad.onnx" "$RELEASES/asr-models/silero_vad.onnx"
fi

# ---- CLI entry points -------------------------------------------------------

say "Linking scripts into $LOCAL_BIN"
mkdir -p "$LOCAL_BIN"
for script in omantra omantra-transcribe omantra-supertap; do
  ln -sfn "$REPO/bin/$script" "$LOCAL_BIN/$script"
  echo "  $LOCAL_BIN/$script -> $REPO/bin/$script"
done

# ---- Shell plugin -----------------------------------------------------------

# A symlink keeps the checkout as the single source of truth; the shell reads
# through it and picks up edits without a copy step.
if [ -e "$PLUGIN_DIR" ] && [ ! -L "$PLUGIN_DIR" ]; then
  echo "$PLUGIN_DIR exists and is not a symlink — move it aside first" >&2
  exit 1
fi
say "Linking plugin into the Omarchy shell"
mkdir -p "$(dirname "$PLUGIN_DIR")"
ln -sfn "$REPO" "$PLUGIN_DIR"

if command -v omarchy-shell >/dev/null; then
  omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
  omarchy plugin enable "$PLUGIN_ID" --section right >/dev/null 2>&1 || true
fi

cat <<EOF

$(say "Done")
Add the keybindings from hypr/bindings.example.lua to ~/.config/hypr/bindings.lua,
then run:  hyprctl reload && omarchy restart shell

Verify with:
  omantra-transcribe "$MODELS/$MODEL_NAME/test_wavs/0.wav"
  omantra --dry-run "create a new project for a todo app"
  omarchy-shell omantra status
EOF
