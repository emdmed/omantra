#!/usr/bin/env bash
# Undo the parts of install.sh that live outside the plugin folder, so that
# `omarchy plugin remove io.github.emdmed.omantra` afterwards leaves nothing
# behind. The downloads are deliberately not touched: ~/opt and ~/models are
# shared with anything else using sherpa-onnx, and a gigabyte is not something
# to delete on the way past. It says where they are instead.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$REPO/lib/config.sh"

LOCAL_BIN="$HOME/.local/bin"

for script in omantra omantra-config omantra-fetch omantra-investigate omantra-serve omantra-transcribe omantra-supertap; do
  link="$LOCAL_BIN/$script"
  # Only ours: a link pointing into this checkout. Anything else with the name
  # belongs to someone else and is left alone.
  if [ -L "$link" ] && [ "$(readlink -f "$link")" = "$REPO/bin/$script" ]; then
    rm -f "$link"
    echo "removed $link"
  fi
done

cat <<EOF2

Kept, because they are shared and large:
  $OMANTRA_OPT_DIR      sherpa-onnx runtime
  $OMANTRA_MODELS_DIR   Parakeet + Silero models
Your settings are still in ${OMANTRA_CONFIG_FILE:-$HOME/.config/omantra/config}.

Remove the plugin itself with:
  omarchy plugin remove io.github.emdmed.omantra
EOF2
