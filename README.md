# omarchy-harness

Speak to your desktop. Everything runs locally — no audio, no text, and no
instruction leaves the machine.

```
double-tap Super  →  pw-record  →  Parakeet  →  local LLM  →  action
```

Say *"I want to create a new project to create a todo app"* and you get
`~/projects/todo-app`, git-initialised, with Claude open on a brief written
from what you said.

It is an [Omarchy](https://omarchy.org/) shell plugin: a mic widget in the bar,
plus the scripts behind it.

## Why not Whisper

The target machine is a Ryzen 5 5500U with no discrete GPU. Whisper's usual
runtimes want a GPU, and the Python ones want a Python that `onnxruntime` and
`CTranslate2` publish wheels for. So the ASR is
[sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) — statically linked C++,
no Python at all — running NVIDIA's Parakeet TDT 0.6B v2 in int8.

Measured on that CPU, transcribing a 7.4 s clip:

| threads | RTF |
|--------:|----:|
| 2 | 0.137 |
| 4 | 0.097 |
| **6** | **0.090** |
| 8 | 0.117 |
| 12 | 0.126 |

About 11× faster than realtime, and it regresses past 6 threads — the chip has
6 physical cores and SMT contention costs more than the extra threads return.
`TRANSCRIBE_THREADS` overrides the default.

Parakeet v2 is English-only. For other languages, swap the model for
`parakeet-tdt-0.6b-v3` or go back to `whisper.cpp` with `large-v3-turbo`.

## Install

```bash
git clone <this repo> ~/projects/omarchy-harness
cd ~/projects/omarchy-harness
./install.sh
```

The installer pulls ~1 GB of runtime and models into `~/opt` and `~/models/asr`,
symlinks `bin/` into `~/.local/bin`, and symlinks the checkout itself into
`~/.config/omarchy/plugins/`. The symlink means the repo stays the single
source of truth: edit here and the shell reads the change.

Then add the keybindings from `hypr/bindings.example.lua` to
`~/.config/hypr/bindings.lua`.

Command mode also needs an OpenAI-compatible endpoint. Any llama.cpp server
will do:

```bash
llama-server --model ~/models/Qwen3-4B-Q4_K_M.gguf --port 8081 \
  --ctx-size 32768 --jinja -ngl 99 -np 1
```

## Use

| Gesture | Mode | Result |
|---|---|---|
| double-tap Super | command | transcript goes to the harness, which acts on it |
| `Super+Alt+D`, or left click | dictate | transcript goes to the clipboard |
| right click | — | re-copy the last transcript |
| middle click, `Super+Alt+Shift+D` | — | cancel and discard |

The bar glyph shows the mode: 󰚩 command, 󰑊 recording, 󰔟 transcribing.

`transcribe` also stands alone:

```bash
transcribe meeting.m4a           # any format; ffmpeg converts
transcribe meeting.m4a --json    # word-level timestamps
```

## How command mode stays safe

The LLM never emits a command. Its only job is classification and slot-filling
against a JSON schema, enforced by llama.cpp's grammar sampler, so it has to
return one of a fixed set of actions:

| action | fields | effect |
|---|---|---|
| `new_project` | `name`, `prompt` | mkdir under `~/projects`, `git init`, open Claude with the brief |
| `open_project` | `name`, `prompt` | fuzzy-match an existing project, open Claude there |
| `unknown` | — | copy the words to the clipboard and say so |

A misheard sentence can at worst pick the wrong action from a set that is
entirely non-destructive; it cannot invent one. The slug is re-sanitised in
bash after the model returns, so a stray `../` cannot escape `~/projects` even
if the model emits one.

Every decision is appended to
`~/.local/state/omarchy-harness/history.jsonl` next to the transcript that
produced it — when it mishears you, that shows whether the fault was the ear or
the interpreter.

Adding an action means a new `case` in `bin/omarchy-harness` and a line in the
system prompt. Keep them non-destructive; nothing here asks for confirmation.

## Layout

```
manifest.json                 plugin declaration + settings schema
BarWidget.qml                 the bar widget: two Processes, a state machine
bin/transcribe                audio file -> text
bin/dictate-supertap          double-tap detector for the Super key
bin/omarchy-harness           transcript -> LLM -> action
hypr/bindings.example.lua     keybindings to copy
install.sh                    runtime, models, symlinks
```

`BarWidget.qml` shells out rather than linking anything: `pw-record` writes the
wav, `transcribe` reads it. Both halves are runnable from a terminal, which is
what makes the thing debuggable.

## Notes

- Editing `BarWidget.qml` usually hot-reloads, but adding or renaming an IPC
  method needs a full `omarchy restart shell` — `rescanPlugins` reloads the code
  while keeping the old IPC surface.
- The `dictate` IPC target binds to one bar instance, so on multiple monitors
  only one screen's widget animates. Route through `broadcast` if that matters.
- Recording caps at `maxSeconds` (default 300) and transcribes what it has
  rather than discarding it.

## Requirements

Omarchy 4 (Quickshell shell), PipeWire, and `ffmpeg jq curl wl-clipboard
libnotify xdg-terminal-exec`. Optional: `wtype` for the `typeOut` setting.
