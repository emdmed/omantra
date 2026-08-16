-- Append to ~/.config/hypr/bindings.lua, then `hyprctl reload`.

-- Dictation to the clipboard.
o.bind("SUPER + ALT + D", "Dictate", "omarchy-shell dictate toggle")
o.bind("SUPER + ALT + SHIFT + D", "Dictate cancel", "omarchy-shell dictate cancel")

-- Double-tap Super for command mode: the transcript goes to the harness, which
-- interprets it with the local LLM and acts. Hyprland only reports the release
-- of the key, so the tap-pair timing lives in the script.
o.bind("SUPER + SUPER_L", "Voice command (double-tap Super)",
  os.getenv("HOME") .. "/.local/bin/dictate-supertap", { release = true })
