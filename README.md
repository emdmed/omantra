# omantra

Speak to your desktop. Hearing and understanding run locally — no audio, no
text, and no instruction leaves the machine, as long as the model server you
point it at is on it. The endpoint is a setting, and nothing stops you aiming it
at a box down the hall; the default is `127.0.0.1`.

Two of the things it can *do* with an instruction leave the machine, and say so
where they are described: `web_search` opens a browser, and `investigate` hands
a subject to a coding agent. Everything between the microphone and the choice of
action stays here.

```
double-tap Super  →  pw-record  →  Parakeet  →  local LLM  →  action
```

Say *"I want to create a new project to create a todo app"* and you get
`~/projects/todo-app`, git-initialised, with your coding agent — Claude unless
you change it — open on a brief written from what you said.

It is an [Omarchy](https://omarchy.org/) shell plugin: a widget in the bar,
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
`~/.config/omarchy/plugins/`. Both symlinks point back here, so there is no
second copy to keep in sync: `omantra` on your PATH *is* `bin/omantra`, and an
edit to it is what the next take runs. The QML is the exception — the shell
loads this checkout but loads it once, so widget and panel edits need
`omarchy restart shell` (see Notes).

Then add the keybindings from `hypr/bindings.example.lua` to
`~/.config/hypr/bindings.lua`, and pick both halves up:

```bash
hyprctl reload && omarchy restart shell
```

The restart is not optional: the widget, the settings panel and the
`omarchy-shell omantra …` calls the keybindings make all arrive with it.

Check it landed:

```bash
omantra-transcribe ~/models/asr/*/test_wavs/0.wav   # the ASR half
omantra-config list                                 # the settings half
omarchy-shell omantra status                        # the widget half — "idle"
```

Command mode also needs an OpenAI-compatible endpoint. Any llama.cpp server
will do — point Omantra at it from the settings panel, or leave the default and
run one locally:

```bash
omantra-serve                       # the newest .gguf in ~/models, ctrl-c to stop
omantra-serve --check               # is one already answering?
omantra-serve ~/models/other.gguf   # a particular one
```

That is the `llama-server` line the README used to print, kept next to the
settings it has to agree with:

```bash
llama-server --model <the .gguf> --host 127.0.0.1 --port 8081 \
  --ctx-size 32768 --jinja -ngl 99 -np 1
```

The host and port are read out of `OMANTRA_ENDPOINT` rather than written down a
second time, because the client and the server disagreeing about which port they
are on is the bug the script exists to prevent. It runs in the foreground, since
a model server nobody can see is how you end up with two of them, and refuses to
start a second one when something is already answering. `OMANTRA_LLM_MODEL`,
`OMANTRA_LLM_MODELS_DIR`, `OMANTRA_LLM_SERVER` and `OMANTRA_LLM_CTX` override
the guesses; they are environment-only, since a machine talking to a server down
the hall has no use for any of them.

Worth an alias, since it is the one thing that has to be running before you can
talk to the desktop:

```bash
alias omantra-up='omantra-serve'
```

## Use

| Gesture | Mode | Result |
|---|---|---|
| double-tap Super | command | transcript goes to the interpreter, which acts on it |
| `Super+Alt+D`, or left click | dictate | transcript goes to the clipboard |
| right click while idle, `Super+Alt+C` | — | open the settings panel |
| middle click while idle | — | re-copy the last transcript |
| middle click while recording, `Super+Alt+Shift+D`, Esc | — | cancel and discard |
| click "report done", `Super+Alt+R` | — | open the report panel on the newest report |

The bar glyph shows the mode: 󰗋 idle, 󰚩 command, 󰑊 recording, 󰔟 transcribing.
Idle is a head with sound coming out of it rather than a microphone: that
glyph belongs to Omarchy's own mic widget, which this one used to duplicate
exactly, and Omantra is about speaking to the machine rather than about the
input device. The chip below uses the same glyphs, plus 󰄬 for a landed take and
󰅚 for a failure.

While a take is running, a chip sits at the top center of the screen just under
the bar and stays until the transcript comes back, then flashes what it heard. The
double-tap has no visible target to aim at, so the answer to "is it listening?"
has to arrive where the eyes already are; and because dictation is something you
do *while* working, it arrives without dimming the screen or covering the window
you are talking at. Only the width changes between phases, never the height.

One line, in two groups a hairline apart:

```
󰚩 COMMAND 0:03 ▁▄▂  │  [Super] twice to send  [esc] to discard
└─── what it is doing ───┘  └────── how to end it ──────┘
```

State on the left at full contrast, controls on the right at a third of it. The
left half is read every take; the right half only until the gesture is learned,
and a status chip whose instructions are as loud as its status is mostly
instructions. The keys are drawn as keycaps rather than prose because a sentence
at this size is a gray stripe the eye skips. The chip's border carries the state
too — accent while the mic is hot, urgent on a failure, the ordinary popup edge
once the take has landed — which is legible from across the room, the reach the
dimmed screen used to buy.

In command mode the chip carries the rest of the round trip, because that is
where the machine is guessing. Once the words are transcribed it shows `DECIDING`
next to them while the model picks an action, and then the action itself —
`OPEN todo-app · claude`, `THEME Nord`, `NOT UNDERSTOOD` — printed by `omantra`
before it does anything, so what is about to happen is readable while the
terminal is still opening. The agent is named because it is the part that isn't
obvious: which project got picked is a guess about what was said, and which
command opens it is a setting you may have changed since.

That is also why almost nothing here reaches the tray. The rule is that the
layout says it: the chip carries a take from the mic to its result, and the
agents button carries a background investigation from "working" to "report
done" or "report failed" without expiring, so both endings are on screen
already. A tray entry for a theme switch you can watch happen is the same news
twice and has to be dismissed as well; a tray entry for a mic that heard
nothing is a dismissal for news that was over on arrival.

What is left for a notification is the case where the surface that should have
said it isn't there. A transcription that dies while you are in another window
outlives the chip, so `omantra` notifies its own failures — once, from the half
that knows what went wrong and the half a bare keybind runs with no widget
watching. An investigation that ends on a machine with no bar running has
nothing to land in, so it notifies then and only then; with the bar up it goes
to the button and waits to be asked. That narrow case is what the `notify`
setting means.

Nothing on the chip animates on a timer. The only thing that moves is the meter,
and it moves because the mic heard something: a second ffmpeg reads the same
source and prints an RMS figure 20 times a second, and the columns follow it. A
chip that pulses on its own says "I am a widget"; a chip that answers your voice
says "I can hear you". Silence is empty tracks rather than a row of stubs, since
anything left standing at rest gets read as punctuation at this size. The floor
is set by the quietest moment of the take rather than by a constant, because one
machine's silence is -38 dBFS and another's is -55, and a meter that shows a
quarter of a bar in an empty room has stopped saying anything.

The chip is the only clickable part of that surface: clicking it ends the take,
and clicks anywhere else go to the window underneath. Esc throws the take away.
That last one is why the chip holds the keyboard while the mic is hot — a layer
surface only receives keys if it asks for them — and hands it straight back the
moment the take ends. Hyprland resolves its own keybinds before the focused
surface sees anything, so Super gestures keep working throughout; the cost is
that the window behind can't be typed into mid-take. Turn the whole thing off
with the `overlay` setting.

`omantra-transcribe` also stands alone:

```bash
omantra-transcribe meeting.m4a           # any format; ffmpeg converts
omantra-transcribe meeting.m4a --json    # sherpa's full result, with per-token
                                         # timestamps
```

## Settings

Right-click the widget — or `Super+Alt+C` — for a card with the things
worth changing: which model server command mode talks to, which coding agent a
project opens with, where projects go, and how a dictated take is delivered.
The endpoint field has a **Test** button, because the reason to open this panel
is usually that command mode just failed and the question is whether anything
is listening.

Nothing is written until Save; Esc or Cancel leaves without touching anything,
and a rejected value keeps the card open with the reason under the fields. A
save takes effect on the next take — the scripts read the file each run, and
the widget reloads its copy when the panel saves — so there is nothing to
restart.

The panel edits no state of its own: it is a front-end for

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
| `new_project` | `name`, `prompt` | mkdir under `~/projects`, `git init`, open the agent with the brief |
| `open_project` | `name`, `prompt` | fuzzy-match an existing project, open the agent there |
| `set_theme` | `name` | fuzzy-match an installed Omarchy theme, `omarchy-theme-set` it |
| `open_app` | `name` | fuzzy-match an installed desktop entry, launch it through `uwsm app` |
| `focus_workspace` | `number` | `hyprctl dispatch workspace N` — the Super+N binding, reached by voice |
| `move_to_workspace` | `number` | `hyprctl dispatch movetoworkspace N` |
| `fullscreen` | — | `hyprctl dispatch fullscreen`, which toggles, so saying it twice undoes it |
| `toggle` | `switch` | one of Omarchy's own switches: night light, do-not-disturb, stay-awake, screensaver, bar, transparency, mute |
| `capture` | `kind` | `omarchy-capture-screenshot fullscreen`, or start/stop a screen recording |
| `set_volume` | `level` | `wpctl set-volume` to a named percentage |
| `nudge_volume` | `direction` | the same, ±10% |
| `web_search` | `query` | `xdg-open` on `OMANTRA_SEARCH_URL` — opens a search page and leaves the reading to you |
| `investigate` | `topic` | hand the question to a coding agent running headless in the background; the bar says when the report is done |
| `unknown` | — | copy the words to the clipboard and say so in the chip |

A misheard sentence can at worst pick the wrong action from a set that is
entirely non-destructive; it cannot invent one. Every field is re-checked in
bash after the model returns, so a stray `../` cannot escape `~/projects` and a
workspace number outside 1–10 is a failure rather than a dispatch, even if the
model emits one.

The schema is a union — one branch per action, carrying only that action's
fields — rather than one flat object offering every field to every action:

```jsonc
{ "oneOf": [
  { "properties": { "action": { "const": "new_project" },
                    "name": {…}, "prompt": {…} },
    "required": ["action", "name", "prompt"], "additionalProperties": false },
  { "properties": { "action": { "const": "focus_workspace" }, "number": {…} },
    "required": ["action", "number"], "additionalProperties": false },
  …
] }
```

Flat worked while both actions wanted the same two fields, and stops working
the moment they differ: a model shown `name`, `prompt` and `number` on every
action, and told to leave the irrelevant ones empty, will sooner or later fill
the wrong one. Under a union, `focus_workspace` has no `name` property to fill
— the grammar cannot produce one — and no action is ever asked to emit a field
whose only correct value is `""`. `action` comes first in every branch, which
is also what makes the union cheap to sample: the alternatives share the prefix
`{"action":"` and diverge on the name, so choosing the action is choosing the
rest of the shape.

The cost is that actions now compete on their *sentences*, not just their
names, and with a dozen of them that competition is the whole game. Three of
these were only found by running real sentences past a real model:

- `focus_workspace` first read "the user wants to switch to another workspace",
  and "switch to tokyo night" started landing on workspace 2 — the model was
  matching the verb rather than the object. Its sentence now leads with the
  discriminator (a workspace is always a number) and says the verb means
  nothing on its own.
- `focus_workspace` and `move_to_workspace` take the same slot and differ only
  in what moves, so each sentence now says what *stays put* as well as what
  goes, and points at the other one.
- Volume was one action with a `direction` slot deciding whether `level` meant
  "end up here" or "change by this much". "turn it up a bit" came back as
  `quieter` no matter how the enum was worded — the model is markedly better at
  choosing an action than at filling a slot that changes what a sibling slot
  means. Splitting it into `set_volume` and `nudge_volume` fixed every phrasing
  at once, because the union makes the action the first thing sampled. When a
  slot is doing work the action name should be doing, that is the fix.

Which is the general shape: a misclassification here is a prompt bug, and the
history log is where you find it. The sweep that keeps this honest is 38
sentences run past a real llama-server, not a unit test — the tests cover the
tables and the matchers, and no test can tell you the model reads your sentence
differently than you do.

`open_app` is `set_theme` again in a second domain: the installed applications
go into the prompt as display names, and the name that comes back is matched
against the desktop entries once more before anything is launched. Matching
widens the same way, with one extra tier at the end — an entry's own `Keywords`
and `Categories`. That is what answers a request that names a job rather than a
program, since nobody says "Nautilus" out loud, they say "the file manager", and
`FileManager` is a category Nautilus already declares. It comes last because it
is the vaguest: a program that calls itself Files should win over one that
merely lists the category.

`set_theme` is the same shape a step further: the model picks a name, and bash
decides whether that name is a theme. The list of installed themes goes into
the system prompt — read from `~/.config/omarchy/themes` and
`$OMARCHY_PATH/themes`, the two trees Omarchy merges — and the name that comes
back is matched against those directories again before anything is applied.
So a theme the model has heard of but you do not have is a "no installed theme
matches" failure, not a failed command:

```bash
omantra "switch to tokyo night"        # -> omarchy-theme-set tokyo-night
omantra "make it look like gruvbox"    # -> omarchy-theme-set gruvbox
omantra "go back to velvetnight"       # a bare theme name is enough
omantra --dry-run "I want a dark theme"  # prints the command, runs nothing
```

Matching widens from exact to substring, because speech gets names
approximately right and `omarchy-theme-set` needs them exactly right: "tokyo"
finds `tokyo-night`, "latte" finds `catppuccin-latte`. Exact wins outright, so
"catppuccin" is never answered with `catppuccin-latte`.

Every decision is appended to
`~/.local/state/omantra/history.jsonl` next to the transcript that
produced it — when it mishears you, that shows whether the fault was the ear or
the interpreter. One JSON object per line, trimmed to the most recent
`OMANTRA_LOG_MAX_LINES` (2000) entries:

```jsonc
{"transcript":"go to workspace three","action":"focus_workspace","fields":{"number":"3"}}
```

```bash
jq -r 'select(.action == "unknown") | .transcript' ~/.local/state/omantra/history.jsonl
```

`fields` holds the slots that action declared, as they were after sanitising. A
value that failed sanitising is logged too, under its raw text with an
`"invalid"` key naming the slot that rejected it, and the entry is written
*before* the failure is reported — a value the grammar should have made
impossible is the single most interesting thing that can reach the history, and
dying first was throwing it away.

Adding an action means one row in the `ACTIONS` table in `lib/actions.sh` —
name, the fields it takes, and the sentence that teaches the model when to pick
it — and a matching `do_<name>` function in `bin/omantra`, with a `plan` call
before the side effect. The JSON schema, the system prompt and the dispatch are
all generated from that table, so there is no second and third place to keep in
step. Keep them non-destructive; nothing here asks for confirmation.

A field the action needs and no existing action has is one row in `FIELDS`
above it: key, type, and what to tell the model it is for. The type is the
whole of it — `slug`, `string` or `integer:MIN:MAX` — and it drives both the
JSON schema the sampler enforces and the re-validation on the way back, so a
range is written down once. Each slot arrives in the `do_` function as a
variable named after the field, already sanitised: `$name` is slugified,
`$number` is in range or the take has already failed.

`plan` is the whole interface between the two halves: one line on stdout,
`plan: LABEL|subject`, which the widget reads and puts in the chip. Diagnostics
go to stderr and become the chip's failure text, and `--dry-run`'s `would:`
lines are the only other thing on stdout — so running the script from a terminal
still reads like a normal command, and the widget still has one line to parse.

## Investigations

Every other action finishes before you have let go of the key. `investigate` is
the one that takes minutes:

```bash
omantra "look into how sherpa-onnx decides where a sentence ends"
```

The subject goes to a coding agent — `claude` unless you change it — running
headless in the background. Nothing opens, nothing takes focus, and the only
sign it is happening is a segment that appears in the bar next to the mic:

```
󰗋   󱚝 working          an agent is out reading — hover for the subject
󰗋   󰈙 report done      it came back, and you have not opened it yet
󰗋   󰈙 3 reports done   a count only when there is more than one
```

Accent while an agent is working, ordinary once what is left is reading: "wait"
and "your turn" are different news, and the button says which in words rather
than in a glyph you have to remember.

Clicking it — or `Super+Alt+R` — opens the panel: every investigation down the
left, the selected report rendered as markdown on the right, arrow keys or
`j`/`k` between them, esc to close. Qt renders the markdown itself, so there is
no `glow` or `pandoc` to install and a report looks like the rest of the plugin
rather than like a terminal.

**Nothing ever opens it for you.** A report landing while you are mid-sentence
must not take the screen — that is the whole reason the work happens in the
background in the first place — so the button is the only thing that puts a
report in front of you, and it waits as long as it has to. The panel has exactly
three ways in: that click, the keybinding, and `omantra-investigate open`.

Showing a report marks that report read, and the button goes away when nothing
is left unread. Read is a stamp in each job's own `meta.json` rather than one
"everything up to here" timestamp: three reports land while you are out, you
open the interesting one, and the bar still says two are waiting — which a
single watermark cannot express.

A job that ends without a report counts as unread too: the button says `report
failed`, in the urgent colour, and the click opens the agent's log — which is
the only thing there is to read when it died without writing. That is the case
that used to be a notification's business and nothing else's, and it is the
reason a landing report no longer needs the tray at all. The bar does not
expire, so nothing has to be delivered while you are watching.

The exception is a machine with no bar running — an investigation started from
a terminal over ssh, say. There is no button to land in there, so the ending
notifies instead, under `OMANTRA_NOTIFY`. With the shell up it never does.

The same store from a terminal:

```bash
omantra-investigate start "how sherpa-onnx handles endpointing"   # prints a job id
omantra-investigate list                                          # running/done/failed
omantra-investigate show                                          # the newest report, on stdout
omantra-investigate open                                          # the newest unread, in the panel
omantra-investigate log <id>                                      # what the agent said on stderr
omantra-investigate read                                          # mark everything read
omantra-investigate cancel <id>
```

One directory per investigation under
`~/.local/state/omantra/investigations/<timestamp>-<slug>/`, holding `meta.json`,
`report.md` and `log`. A directory rather than a database because the artefact
worth keeping is a markdown file: `cat`, `grep` and the file manager all work on
this store without knowing it is one. The newest 50 are kept.

Status is *derived* rather than stored — `finished` in `meta.json`, and when
that is absent, whether the recorded pid is still alive. A status field written
by the job itself is a lie the moment something kills it, and "1 agent working"
that never goes away is worse than no indicator at all.

### What the agent is allowed to do

Nobody is watching its permission prompts, so:

```
--allowedTools WebSearch,WebFetch,Read,Grep,Glob
--add-dir <where you asked from>
```

No `Bash`, no `Edit`, no `Write`. It does not need `Write` either — the report
is the agent's stdout, so the one file it produces is a file it never opened.
Its working directory is its own job directory, and `--add-dir` is what lets
*"look into why our transcribe step is slow"* read the project you asked it
from; voice-triggered runs get `OMANTRA_PROJECTS`. The whole set is
`OMANTRA_INVESTIGATION_TOOLS` if you disagree with it, and
`OMANTRA_INVESTIGATION_TIMEOUT` (900 s) is the ceiling on an agent that cannot
find an answer.

The brief it is given asks for a fixed shape — the answer in the first two
sentences, then findings, then what it could not settle, then sources — because
a report you must read to the end to use is one you will not open twice. An
agent that exits 0 having written nothing is recorded as a failure, since an
empty panel is the least useful way to find that out.

The competition this action has to win is with `web_search`, which takes a
free-text slot too. Their sentences in `ACTIONS` now point at each other: a
search page to be *shown* results, an investigation to be *told* an answer. The
slots are deliberately different fields — `query` says "phrased as it would be
typed into a search box", `topic` says "written out as a full question" — so the
schema itself carries some of the distinction rather than leaving all of it to
the prose.

## Layout

```
manifest.json                 plugin declaration + settings schema
BarWidget.qml                 the bar widget: the take machine, plus the agent count
VoiceOverlay.qml              the "speak now" chip under the bar
ConfigPanel.qml               the settings card — a front-end for omantra-config
ReportPanel.qml               the markdown viewer — opens on the button, never by itself
lib/config.sh                 paths, versions and defaults — sourced by everything
lib/actions.sh                the action + field tables, and the schema built from them
lib/project.sh                slugify + find_project, the pure half of dispatch
lib/theme.sh                  listing and matching installed Omarchy themes
lib/app.sh                    listing and matching installed desktop entries
lib/investigate.sh            the investigation store: ids, statuses, listing, pruning
bin/omantra-transcribe        audio file -> text
bin/omantra-supertap          double-tap detector for the Super key
bin/omantra-config            read and write ~/.config/omantra/config
bin/omantra-serve             start the local model server on the configured port
bin/omantra-investigate       subject -> background agent -> report.md
bin/omantra                   transcript -> LLM -> action
test/                         `make test` — no model, desktop or network needed
hypr/bindings.example.lua     keybindings to copy
install.sh                    runtime, models, symlinks
```

`BarWidget.qml` shells out rather than linking anything: `pw-record` writes the
wav, `omantra-transcribe` reads it. Both halves are runnable from a terminal, which is
what makes the thing debuggable.

Every widget-facing default is written down three times — in `lib/config.sh`
for the bash side, in `manifest.json` for the widget, and as the fallback
literal in `BarWidget.qml` — because none of the three languages can import
from the others. `test/test_config.sh` fails the build when they drift apart.

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

`web_search` is the one action that sends anything off the machine, so where it
sends it is a setting rather than a literal: `OMANTRA_SEARCH_URL`, DuckDuckGo by
default, with `%s` for the URL-encoded query.

Environment overrides, all read through `lib/config.sh`: `OMANTRA_THREADS`,
`OMANTRA_MODEL`, `OMANTRA_SHERPA_BIN`, `OMANTRA_ENDPOINT`, `OMANTRA_PROJECTS`,
`OMANTRA_AGENT` (defaults to `claude`), `OMANTRA_MAX_SECONDS`,
`OMANTRA_TAP_WINDOW_MS`, `OMANTRA_LOG`, `OMANTRA_LOG_MAX_LINES`,
`OMANTRA_CONFIG_FILE`, `OMANTRA_SEARCH_URL`. The ones the
panel writes are also settable with `omantra-config set`; see
`omantra-config keys` for the list.

## Notes

- QML edits need `omarchy restart shell` in an installed checkout. The shell
  hot-reloads files saved under `~/.config/omarchy/plugins/`, but this plugin is
  a symlink to the repo, and the watcher does not follow it — a save changes
  nothing, and `rescanPlugins` reloads the code while keeping the old IPC
  surface, so a new IPC method needs the restart regardless.
- The `omantra` IPC target binds to one bar instance, so on multiple monitors
  only one screen's widget animates. Route through `broadcast` if that matters.
- Recording caps at `maxSeconds` (default 300) and transcribes what it has
  rather than discarding it.

## Requirements

Omarchy 4 (Quickshell shell), PipeWire, and `git ffmpeg jq curl wl-clipboard
libnotify xdg-terminal-exec` — `git` because `new_project` initialises a repo,
`wpctl` (PipeWire) for the volume actions. `uwsm` or `gtk-launch` to start an
application, whichever is present.
Optional: `wtype` for the `typeOut` setting.
