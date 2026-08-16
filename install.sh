#!/usr/bin/env bash
# Install the speech-to-text runtime this plugin drives, then wire the plugin
# into the Omarchy shell. Safe to re-run: every step is skipped when already
# satisfied.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Versions and paths come from the same file the runtime scripts read, so a
# version bump can't leave the installer and the transcriber disagreeing.
. "$REPO/lib/config.sh"

LOCAL_BIN="$HOME/.local/bin"
PLUGIN_ID="enrique.omantra"
PLUGIN_DIR="$HOME/.config/omarchy/plugins/$PLUGIN_ID"

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

if [ -x "$OMANTRA_SHERPA_BIN/sherpa-onnx-offline" ]; then
  say "sherpa-onnx $OMANTRA_SHERPA_VERSION already installed"
else
  say "Installing sherpa-onnx $OMANTRA_SHERPA_VERSION (~400 MB download)"
  mkdir -p "$OMANTRA_OPT_DIR"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  curl -fL --progress-bar \
    -o "$tmp/sherpa.tar.bz2" \
    "$OMANTRA_RELEASES/v$OMANTRA_SHERPA_VERSION/sherpa-onnx-v$OMANTRA_SHERPA_VERSION-linux-x64-static.tar.bz2"
  tar xf "$tmp/sherpa.tar.bz2" -C "$OMANTRA_OPT_DIR"
fi

# ---- Parakeet model ---------------------------------------------------------

if [ -f "$OMANTRA_MODEL/encoder.int8.onnx" ]; then
  say "Parakeet model already installed"
else
  say "Installing $OMANTRA_MODEL_NAME (~660 MB)"
  mkdir -p "$OMANTRA_MODELS_DIR"
  curl -fL --progress-bar \
    -o "$OMANTRA_MODELS_DIR/model.tar.bz2" \
    "$OMANTRA_RELEASES/asr-models/$OMANTRA_MODEL_NAME.tar.bz2"
  tar xf "$OMANTRA_MODELS_DIR/model.tar.bz2" -C "$OMANTRA_MODELS_DIR"
  rm -f "$OMANTRA_MODELS_DIR/model.tar.bz2"
fi

if [ ! -f "$OMANTRA_MODELS_DIR/silero_vad.onnx" ]; then
  say "Installing Silero VAD"
  curl -fL --progress-bar -o "$OMANTRA_MODELS_DIR/silero_vad.onnx" \
    "$OMANTRA_RELEASES/asr-models/silero_vad.onnx"
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
  omantra-transcribe "$OMANTRA_MODEL/test_wavs/0.wav"
  omantra --dry-run "create a new project for a todo app"
  omarchy-shell omantra status
EOF
