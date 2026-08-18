#!/usr/bin/env bash
# Wire the plugin into the shell and put its scripts on your PATH. Deliberately
# small and fast: the ~1 GB of speech runtime is `omantra-fetch`, run when you
# want it, so adding the plugin costs a second and a gigabyte is a decision you
# make rather than one made for you. Safe to re-run: every step is skipped when
# already satisfied.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Versions and paths come from the same file the runtime scripts read, so a
# version bump can't leave the installer and the transcriber disagreeing.
. "$REPO/lib/config.sh"

LOCAL_BIN="$HOME/.local/bin"
PLUGIN_ID="io.github.emdmed.omantra"
PLUGINS_DIR="$HOME/.config/omarchy/plugins"
PLUGIN_DIR="$PLUGINS_DIR/$PLUGIN_ID"

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

# A warning, not an error: dictation is the half most people use and it never
# touches the LLM. The server is also not ours to install — the build is
# hardware-specific and the model choice is a VRAM tradeoff — so the most this
# can usefully do is say it is missing before you find out mid-sentence.
if ! omantra_endpoint_up; then
  say "Note: no model server at $OMANTRA_ENDPOINT"
  cat <<'EOF'
  Dictation works without it. Command mode (double-tap Super) needs an
  OpenAI-compatible endpoint; any llama.cpp server will do:

    llama-server --model ~/models/Qwen3-4B-Q4_K_M.gguf --port 8081 \
      --ctx-size 32768 --jinja -ngl 99 -np 1

  Point somewhere else with the config panel (right click the widget),
  or with: omantra-config set OMANTRA_ENDPOINT http://host:port/v1/chat/completions
EOF
fi

# ---- CLI entry points -------------------------------------------------------

say "Linking scripts into $LOCAL_BIN"
mkdir -p "$LOCAL_BIN"
for script in omantra omantra-config omantra-fetch omantra-investigate omantra-serve omantra-transcribe omantra-supertap; do
  ln -sfn "$REPO/bin/$script" "$LOCAL_BIN/$script"
  echo "  $LOCAL_BIN/$script -> $REPO/bin/$script"
done

# ---- Shell plugin -----------------------------------------------------------

# Two ways in. `omarchy plugin add` has already cloned the repo to its final
# home, and this is being run from inside it — there is nothing left to link,
# and linking anything into a plugin folder would fail `omarchy plugin
# validate`, which rejects symlinks. A development checkout somewhere else gets
# the symlink instead, so edits are live without a copy step; that folder is a
# symlink and so is deliberately not a shape you can publish from.
if [ "$REPO" = "$(readlink -f "$PLUGIN_DIR" 2>/dev/null || echo "$PLUGIN_DIR")" ]; then
  say "Installed as $PLUGIN_ID"
else
  # The pre-1.0 id, when the only install path was this script.
  legacy="$PLUGINS_DIR/enrique.omantra"
  if [ -L "$legacy" ]; then
    say "Removing the old enrique.omantra link"
    omarchy plugin disable enrique.omantra >/dev/null 2>&1 || true
    rm -f "$legacy"
  fi

  if [ -e "$PLUGIN_DIR" ] && [ ! -L "$PLUGIN_DIR" ]; then
    echo "$PLUGIN_DIR is already a real checkout — update it with:" >&2
    echo "  omarchy plugin update $PLUGIN_ID" >&2
    exit 1
  fi
  say "Linking this checkout into the Omarchy shell (development install)"
  mkdir -p "$PLUGINS_DIR"
  ln -sfn "$REPO" "$PLUGIN_DIR"
fi

if command -v omarchy-shell >/dev/null; then
  omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
  omarchy plugin enable "$PLUGIN_ID" --section right >/dev/null 2>&1 || true
fi

say "Done"

if "$REPO/bin/omantra-fetch" --check >/dev/null 2>&1; then
  echo "Speech runtime is already downloaded."
else
  cat <<'EOF'
Speech needs its runtime — about 1 GB of sherpa-onnx and Parakeet, downloaded
when you ask for it and not before:

  omantra-fetch

Until then the widget sits in the bar saying so, and clicking it offers the
download. Everything else — settings, the keybindings, command mode against a
model server — is already wired up.
EOF
fi

cat <<EOF

Add the keybindings from hypr/bindings.example.lua to ~/.config/hypr/bindings.lua,
then run:  hyprctl reload && omarchy restart shell

Verify with:
  omantra-fetch --check
  omantra --dry-run "create a new project for a todo app"
  omantra-config list
  omarchy-shell omantra status
EOF
