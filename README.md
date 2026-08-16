# omantra

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
`OMANTRA_THREADS` overrides the default.

Parakeet v2 is English-only. For other languages, swap the model for
`parakeet-tdt-0.6b-v3` or go back to `whisper.cpp` with `large-v3-turbo`.

## Install

```bash
git clone <this repo> ~/projects/omantra
cd ~/projects/omantra
./install.sh
```

The installer pulls ~1 GB of runtime and models into `~/opt` and `~/models/asr`,
symlinks `bin/` into `~/.local/bin`, and symlinks the checkout itself into
`~/.config/omarchy/plugins/`. The symlink means the repo stays the single
source of truth: edit here and the shell reads the change.

Then add the keybindings from `hypr/bindings.example.lua` to
`~/.config/hypr/bindings.lua`.

Command mode also needs an OpenAI-compatible endpoint. Any llama.cpp server
will do — point Omantra at it from the settings panel, or leave the default and
run one locally:

```bash
llama-server --model ~/models/Qwen3-4B-Q4_K_M.gguf --port 8081 \
  --ctx-size 32768 --jinja -ngl 99 -np 1
```

## Use

| Gesture | Mode | Result |
|---|---|---|
| double-tap Super | command | transcript goes to the interpreter, which acts on it |
| `Super+Alt+D`, or left click | dictate | transcript goes to the clipboard |
| right click, `Super+Alt+C` | — | open the settings panel |
| middle click while idle | — | re-copy the last transcript |
| middle click while recording, `Super+Alt+Shift+D`, Esc | — | cancel and discard |

The bar glyph shows the mode: 󰗋 idle, 󰚩 command, 󰑊 recording, 󰔟 transcribing.
Idle is a head with sound coming out of it rather than a microphone, because
Omarchy's own mic widget is a microphone — down to the same glyph — and this
one is about speaking to the machine, not about the input device.

While a take is running, a card lands in the middle of the screen over a dimmed
desktop — the Omarchy mark, a level meter, the mode, and the clock — and stays
until the transcript comes back, then flashes what it heard. The double-tap has
no visible target to aim at, so the answer to "is it listening?" has to arrive
where the eyes already are.

Nothing on the card animates on a timer. The only thing that moves is the meter,
and it moves because the mic heard something: a second ffmpeg reads the same
source and prints an RMS figure 20 times a second, and the bars follow it. A card
that pulses on its own says "I am a widget"; a card that answers your voice says
"I can hear you". The floor is set by the quietest moment of the take rather than
by a constant, because one machine's silence is -38 dBFS and another's is -55,
and a meter that shows a quarter of a bar in an empty room has stopped saying
anything.

The card is the only clickable part of that surface: clicking it ends the take,
and clicks anywhere else go to the window underneath. Esc throws the take away.
That last one is why the card holds the keyboard while the mic is hot — a layer
surface only receives keys if it asks for them — and hands it straight back the
moment the take ends. Hyprland resolves its own keybinds before the focused
surface sees anything, so Super gestures keep working throughout; the cost is
that the window behind can't be typed into mid-take. Turn the whole thing off
with the `overlay` setting.

`omantra-transcribe` also stands alone:

```bash
omantra-transcribe meeting.m4a           # any format; ffmpeg converts
omantra-transcribe meeting.m4a --json    # word-level timestamps
```

## Settings

Right-click the widget — or `Super+Alt+C` — for a card with the things
worth changing: which model server command mode talks to, which coding agent a
project opens with, where projects go, and how a dictated take is delivered.
The endpoint field has a **Test** button, because the reason to open this panel
is usually that command mode just failed and the question is whether anything
is listening.

Nothing is written until Save. The panel edits no state of its own: it is a
front-end for

```bash
omantra-config list                                    # effective settings
omantra-config set OMANTRA_AGENT codex
omantra-config set OMANTRA_ENDPOINT http://box:8081/v1/chat/completions
omantra-config unset OMANTRA_THREADS                   # back to the default
omantra-config check                                   # is the server up?
```

which writes `~/.config/omantra/config`, one `KEY=value` per line, safe to edit
by hand. Every write goes through one validator, so a GUI cannot save a thread
count of 99 or an endpoint that isn't a URL — and there is no second opinion in
QML to disagree with the first.

That file, rather than the plugin settings store, is where these live, because
both halves have to agree: `bin/omantra` runs from a Hyprland keybind with no
idea what the bar widget believes. The file is read, never sourced — a value
with a `$(` in it is a bad endpoint, not an execution — and precedence runs
**environment > file > default**, so

```bash
OMANTRA_ENDPOINT=http://otherbox:8081/v1/chat/completions omantra "…"
```

still tries a server without committing to it.

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
`~/.local/state/omantra/history.jsonl` next to the transcript that
produced it — when it mishears you, that shows whether the fault was the ear or
the interpreter. One JSON object per line, trimmed to the most recent
`OMANTRA_LOG_MAX_LINES` (2000) entries:

```bash
jq -r 'select(.action == "unknown") | .transcript' ~/.local/state/omantra/history.jsonl
```

Adding an action means one row in the `ACTIONS` table at the top of
`bin/omantra` and a matching `do_<name>` function. The JSON schema enum, the
system prompt and the dispatch are all generated from that table, so there is
no second and third place to keep in step. Keep them non-destructive; nothing
here asks for confirmation.

## Layout

```
manifest.json                 plugin declaration + settings schema
BarWidget.qml                 the bar widget: two Processes, one state machine
VoiceOverlay.qml              the centered "speak now" card
ConfigPanel.qml               the settings card — a front-end for omantra-config
lib/config.sh                 paths, versions and defaults — sourced by everything
lib/project.sh                slugify + find_project, the pure half of dispatch
bin/omantra-transcribe        audio file -> text
bin/omantra-supertap          double-tap detector for the Super key
bin/omantra-config            read and write ~/.config/omantra/config
bin/omantra                   transcript -> LLM -> action
test/                         `make test` — no model, desktop or network needed
hypr/bindings.example.lua     keybindings to copy
install.sh                    runtime, models, symlinks
```

`BarWidget.qml` shells out rather than linking anything: `pw-record` writes the
wav, `omantra-transcribe` reads it. Both halves are runnable from a terminal, which is
what makes the thing debuggable.

Three things need a value that bash, QML and JSON all have to agree on, and
none of them can import from the others. `lib/config.sh` is the source of truth
for the bash side; `manifest.json` is the source for the widget; and
`test/test_config.sh` fails the build if they drift apart.

The settable ones are a table at the top of `lib/config.sh` — variable, type,
matching manifest key, label. The file parser, the validator, the JSON the
panel loads and the test that keeps the manifest in step all read that table,
so a new setting is a row there and a field in `ConfigPanel.qml`.

## Developing

```bash
make check     # lint + test
make test      # just the tests
make hooks     # run `make check` before every commit
```

The suite covers the parts worth being sure about: the slug sanitiser that
keeps a hallucinated `../` inside `~/projects`, the project matcher, and the
agreement between the three copies of each default. It needs no model, no
desktop and no network, so it runs anywhere in well under a second.
`make lint` runs `shellcheck` when it is installed and says so when it isn't.

The same `make check` runs in GitHub Actions on every push, and `make hooks`
symlinks it in as a pre-commit hook so a failure arrives before the commit
rather than after the push. Git does not install hooks on clone, so that one is
a deliberate opt-in per checkout; `git commit --no-verify` skips it.

The suite also covers the settings file, which is the one thing the panel and
the scripts both depend on: precedence, quoting, junk lines, the keys a file is
allowed to set at all, and that a value is never executed.

Environment overrides, all read through `lib/config.sh`: `OMANTRA_THREADS`,
`OMANTRA_MODEL`, `OMANTRA_SHERPA_BIN`, `OMANTRA_ENDPOINT`, `OMANTRA_PROJECTS`,
`OMANTRA_AGENT` (defaults to `claude`), `OMANTRA_TAP_WINDOW_MS`,
`OMANTRA_LOG`, `OMANTRA_LOG_MAX_LINES`, `OMANTRA_CONFIG_FILE`. The ones the
panel writes are also settable with `omantra-config set`; see
`omantra-config keys` for the list.

## Notes

- Editing `BarWidget.qml` usually hot-reloads, but adding or renaming an IPC
  method needs a full `omarchy restart shell` — `rescanPlugins` reloads the code
  while keeping the old IPC surface.
- The `omantra` IPC target binds to one bar instance, so on multiple monitors
  only one screen's widget animates. Route through `broadcast` if that matters.
- Recording caps at `maxSeconds` (default 300) and transcribes what it has
  rather than discarding it.

## Requirements

Omarchy 4 (Quickshell shell), PipeWire, and `ffmpeg jq curl wl-clipboard
libnotify xdg-terminal-exec`. Optional: `wtype` for the `typeOut` setting.
