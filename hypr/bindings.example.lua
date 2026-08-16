-- Append to ~/.config/hypr/bindings.lua, then `hyprctl reload`.

-- Dictation to the clipboard.
o.bind("SUPER + ALT + D", "Dictate to clipboard", "omarchy-shell omantra toggle")
o.bind("SUPER + ALT + SHIFT + D", "Omantra cancel", "omarchy-shell omantra cancel")

-- Double-tap Super for command mode: the transcript goes to Omantra, which
-- interprets it with the local LLM and acts. Hyprland only reports the release
-- of the key, so the tap-pair timing lives in the script.
o.bind("SUPER + SUPER_L", "Voice command (double-tap Super)",
  os.getenv("HOME") .. "/.local/bin/omantra-supertap", { release = true })
