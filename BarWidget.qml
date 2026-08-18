import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Push-to-talk dictation for the bar.
//
// Left click starts recording and the widget turns urgent with a running
// clock, so "am I still recording?" is answerable at a glance. Left click
// again stops and hands the wav to sherpa-onnx + Parakeet; the transcript
// goes to the clipboard. Right click opens the settings, middle click throws
// a live recording away or re-copies the last transcript when there is none.
//
// Both halves are plain subprocesses — pw-record writes the wav, the
// `transcribe` wrapper reads it — so nothing here needs the network and the
// same pipeline is reproducible from a terminal.
BarWidget {
  id: root
  moduleName: "io.github.emdmed.omantra"

  readonly property string wavPath: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/omantra.wav"

  // Scripts ship inside the plugin, so a checkout is self-contained and works
  // wherever it is cloned. A setting still wins, for pointing at one elsewhere.
  readonly property string pluginDir: String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "").replace(/\/$/, "")

  readonly property string transcribeCommand: setting("transcribeCommand", "") || (pluginDir + "/bin/omantra-transcribe")
  // Whether the transcriber is the one that ships here — and so whether the
  // bundled runtime is the thing that has to be on disk. Someone pointing this
  // at whisper.cpp has their own models and their own idea of ready, and a
  // widget that refused to record until *our* download finished would be
  // wrong about a machine that was working fine.
  readonly property bool bundledTranscriber: setting("transcribeCommand", "") === ""
  readonly property string interpreterCommand: setting("interpreterCommand", "") || (pluginDir + "/bin/omantra")
  readonly property string configCommand: pluginDir + "/bin/omantra-config"
  readonly property string fetchCommand: pluginDir + "/bin/omantra-fetch"
  readonly property string investigateCommand: pluginDir + "/bin/omantra-investigate"

  // What the config panel wrote, reloaded whenever it saves. The scripts read
  // the same file directly, so this copy exists only for the settings the
  // widget itself acts on.
  property var config: ({})

  // Precedence, highest first: the config file, this widget's shell.json entry,
  // the built-in default. The file wins because it is the one store both halves
  // read — a value set in the panel has to mean the same thing to the widget
  // and to `omantra` run from a keybind — while shell.json still works for
  // anyone who set these before the panel existed.
  function configured(key, fallback) {
    var value = config ? config[key] : undefined
    return value === undefined || value === null ? fallback : value
  }

  readonly property int threads: configured("OMANTRA_THREADS", setting("threads", 6))
  readonly property int maxSeconds: configured("OMANTRA_MAX_SECONDS", setting("maxSeconds", 300))
  readonly property bool copyToClipboard: configured("OMANTRA_COPY_CLIPBOARD", setting("copyToClipboard", true))
  readonly property bool typeOut: configured("OMANTRA_TYPE_OUT", setting("typeOut", false))
  // The layout says almost everything: the chip carries a take from mic to
  // result, and the agents button carries an investigation from start to
  // "report done" or "report failed" without expiring. What is left for a
  // notification is the narrow case of news that outlives the surface meant to
  // show it — a transcription that died while you were in another window — and
  // this switch is that case, not a general "tell me things" knob.
  readonly property bool notifyOnError: configured("OMANTRA_NOTIFY", setting("notify", true))
  readonly property bool overlayEnabled: configured("OMANTRA_OVERLAY", setting("overlay", true))

  // "dictate" puts the transcript on the clipboard; "command" hands it to the
  // interpreter to act on. Chosen when recording starts and read when it lands, so
  // stopping by any route still delivers the way the take was begun.
  property string mode: "dictate"

  // The widget is one state machine, and this is it. Every other question —
  // what the glyph is, whether the overlay is up, what a click does — is
  // derived from this property, so there is no way to be recording and
  // transcribing at once, and no pair of flags that can disagree.
  //
  //   idle → recording → working →       done | error → idle
  //            ↓                    ↑
  //        cancelling → idle    interpreting          (command mode only)
  //
  //   idle → recopied → idle                          (middle click, no mic)
  //
  // "cancelling" is the beat between the SIGTERM of a discarded take and
  // pw-record actually exiting; it is what lets recProc.onExited tell "user
  // cancelled" from "user finished", which the exit code cannot.
  //
  // "working" starting the moment recording stops — rather than when the
  // recorder exits — also closes a gap where neither flag was set and the
  // overlay blinked out and back in between the two.
  //
  // "interpreting" is the second slow half of command mode: a model call, then
  // a terminal. It used to be invisible — the transcript was fired off detached
  // and the chip flashed "SENT" over a decision that had not been made yet.
  property string phase: "idle"

  readonly property bool recording: phase === "recording"
  readonly property bool working: phase === "working"
  readonly property bool interpreting: phase === "interpreting"
  readonly property bool busy: recording || working

  // A third strand, independent of both the take machine and the agents: is
  // the ~1 GB of sherpa-onnx and Parakeet on disk at all? The plugin installs
  // without it — a bar widget should not make `omarchy plugin add` download a
  // gigabyte — so the widget has to be able to sit here usefully with no way
  // to transcribe, say so, and offer the download rather than failing a take
  // to explain itself.
  //
  //   unknown → ready
  //           → missing → fetching → ready
  //
  // "unknown" is the beat before the first check answers, and behaves as ready:
  // the check takes milliseconds, and a widget that flashed "not installed" on
  // every shell start would be lying more often than it was right.
  property string runtime: "unknown"
  readonly property bool runtimeMissing: bundledTranscriber && runtime === "missing"
  readonly property bool fetching: bundledTranscriber && runtime === "fetching"

  property int elapsed: 0
  property real level: 0
  // Starts at the ceiling so the first readings of a take pull it straight down
  // to whatever this room actually sounds like.
  property real floorDb: 0
  property string lastText: ""
  property string lastError: ""

  // What the interpreter said it was about to do, off its `plan:` line: the
  // state word and its subject, e.g. "OPEN" / "todo-app · claude". Empty until
  // it has decided, and cleared at the start of every command take so a new
  // one can never flash the last one's decision.
  property string planLabel: ""
  property string planDetail: ""

  // ---- Investigations --------------------------------------------------------
  //
  // A second, independent strand of state: `phase` above is one take from mic to
  // action and lasts seconds, while an investigation is a headless agent that
  // runs for minutes with nothing on screen. They never interact — you can start
  // a take while three agents are reading — so they are two sets of properties
  // rather than two more phases in the machine above.
  //
  // The store is the truth (see lib/investigate.sh); this is a copy of
  // `omantra-investigate list --json`, refreshed when the runner says so.
  property var jobs: []

  readonly property int workingCount: {
    var n = 0
    for (var i = 0; i < jobs.length; i++) if (jobs[i].status === "running") n += 1
    return n
  }

  // Landed and not opened yet. This is the half of the indicator that outlives
  // the work: an agent that finished while you were in a meeting has to still
  // be saying so when you come back. Read is a stamp in each job's own
  // meta.json, so opening one of three leaves the other two saying it.
  readonly property int unreadCount: {
    var n = 0
    for (var i = 0; i < jobs.length; i++) {
      var job = jobs[i]
      if (job.status === "done" && job.read === false && job.report) n += 1
    }
    return n
  }

  // The other way a job ends, counted separately because it is the one the bar
  // has to be able to say out loud. An agent that died four minutes after you
  // walked away leaves nothing on screen at all, and a failure nobody is told
  // about reads as an agent that is still thinking — so it sits here, unread,
  // until the panel shows the log.
  readonly property int failedCount: {
    var n = 0
    for (var i = 0; i < jobs.length; i++) {
      var job = jobs[i]
      if (job.status !== "running" && job.status !== "done" && job.read === false) n += 1
    }
    return n
  }

  readonly property bool showingAgents: workingCount > 0 || unreadCount > 0 || failedCount > 0

  // The button says which of the three things is true, in words while the bar
  // is horizontal and has room for them: an agent is still working, one came
  // back empty-handed, or a report is waiting. A count only appears when there
  // is more than one of a kind, since "1" next to a sentence that already says
  // "report" is a digit doing nothing.
  //
  // Working wins over the rest — a bar that said "failed" while three agents
  // are still reading would be answering a question nobody asked yet — and a
  // failure wins over a landed report, because it is the half of the news that
  // needs a decision.
  readonly property string agentLabel: {
    if (workingCount > 0) {
      if (vertical) return "󱚝 " + workingCount
      return workingCount === 1 ? "󱚝 working" : ("󱚝 " + workingCount + " working")
    }
    if (failedCount > 0) {
      if (vertical) return "󱚡 " + failedCount
      return failedCount === 1 ? "󱚡 report failed" : ("󱚡 " + failedCount + " failed")
    }
    if (vertical) return "󰈙 " + unreadCount
    return unreadCount === 1 ? "󰈙 report done" : ("󰈙 " + unreadCount + " reports done")
  }

  readonly property string agentTooltip: {
    var i, job
    if (workingCount > 0) {
      for (i = 0; i < jobs.length; i++) {
        if (jobs[i].status === "running") {
          return workingCount === 1
            ? "1 agent working: " + jobs[i].subject
            : workingCount + " agents working, oldest: " + jobs[i].subject
        }
      }
    }
    if (failedCount > 0) {
      for (i = 0; i < jobs.length; i++) {
        job = jobs[i]
        if (job.status !== "running" && job.status !== "done" && job.read === false) {
          var lead = failedCount === 1 ? "Click for the log: " : (failedCount + " failed — click for the newest: ")
          return lead + job.subject
        }
      }
    }
    for (i = 0; i < jobs.length; i++) {
      job = jobs[i]
      if (job.status === "done" && job.read === false && job.report) {
        var head = unreadCount === 1 ? "Click to read: " : (unreadCount + " reports — click for the newest: ")
        return head + job.subject
      }
    }
    return ""
  }

  function refreshInvestigations() {
    listProc.running = true
  }

  // The button's whole job, and the only route to the report panel: nothing
  // opens it but a click here, the keybinding, or `omantra-investigate open`.
  // A report landing must never take the screen off what you were doing — the
  // bar says it is done and waits to be asked.
  //
  // Toggles, like every other gesture this widget has: the hand that opened the
  // reports is already on the key that closes them.
  function openReport(id) {
    reportPanel.toggle(id || "")
  }

  // The overlay understands exactly the phases the machine has, minus the two
  // that mean "nothing to show".
  readonly property string overlayPhase:
    (!overlayEnabled || phase === "idle" || phase === "cancelling") ? "" : phase

  readonly property bool commandMode: mode === "command"
  // The one phase the bar has no glyph of its own for: a model deciding is not
  // recording and not transcribing, and the idle glyph would say "nothing is
  // happening" while a terminal is about to open.
  readonly property bool showingCommandGlyph: interpreting || (busy && commandMode)
  // At rest this is a head with sound coming out of it, not a microphone: the
  // stock omarchy.microphone widget is already a microphone, down to the same
  // glyph, and two identical mic icons in one bar is one too many. This one is
  // about speaking to the machine rather than about the input device.
  readonly property string glyph:
    runtimeMissing || fetching ? "󰇚"
      : showingCommandGlyph ? "󰚩" : (recording ? "󰑊" : (working ? "󰔟" : "󰗋"))

  readonly property string elapsedLabel: {
    var m = Math.floor(elapsed / 60)
    var s = elapsed % 60
    return m + ":" + (s < 10 ? "0" + s : String(s))
  }

  readonly property string statusText: {
    if (fetching) return "Downloading speech runtime (~1 GB) — watch the terminal"
    if (runtimeMissing) return "Speech runtime not downloaded — click to get it (~1 GB)"
    if (recording) return (commandMode ? "Command " : "Recording ") + elapsedLabel + " — click to transcribe"
    if (working) return "Transcribing…"
    if (interpreting) return "Interpreting: " + lastText
    if (lastError !== "") return "Failed: " + lastError
    if (planLabel !== "") return planLabel + ": " + planDetail
    if (lastText !== "") return (commandMode ? "Sent: " : "Copied: ") + lastText
    return "Dictate — click to record · right click for settings"
  }

  function start(requestedMode) {
    // Nothing to record with yet. The click still means something — it means
    // "get me the thing I am missing" — which is why this offers the download
    // rather than beeping.
    if (runtimeMissing) { fetch(); return }
    if (fetching) return
    // Only idle takes a new take: "done"/"error" are still showing the last
    // result, and starting from there would be a take begun over a stale card.
    if (phase !== "idle" && phase !== "done" && phase !== "error" && phase !== "recopied") return
    mode = requestedMode === "command" ? "command" : "dictate"
    lastError = ""
    planLabel = ""
    planDetail = ""
    elapsed = 0
    flashTimer.stop()
    phase = "recording"
    recProc.running = true
  }

  // dB to a 0..1 bar height, measured against the room rather than against a
  // constant. A fixed floor is wrong on every machine — this laptop's mic idles
  // near -38 dBFS where another sits at -55 — and a meter that shows a quarter
  // of a bar in an empty room stops meaning "I heard you". So the quietest
  // moment of the take defines silence, with a slow creep back up so a throat-
  // clear at the start doesn't deafen the rest of it.
  //
  // The reading rises immediately and falls over a few frames, the way a needle
  // does: a syllable has to register, but the row shouldn't strobe between
  // words.
  function pushLevel(db) {
    // A muted mic reports digital silence, and letting that set the floor would
    // make the first real sound peg the meter. -70 dBFS is below any room.
    var reading = Math.max(-70, db)
    if (reading < floorDb) floorDb = reading
    // ...and a floor that creeps above -25 would swallow ordinary speech.
    else floorDb = Math.min(-25, floorDb + 0.05)

    // 4 dB of headroom over the room before the bars move at all, then full
    // scale 20 dB above that — conversational speech at arm's length lands
    // around 15 dB over room tone, and it should read as most of a bar, not a
    // twitch. The taper spends more of the row on the quiet end, the way a VU
    // scale does, so ordinary talking moves the meter instead of only shouting.
    var head = Math.max(0, Math.min(1, (reading - floorDb - 4) / 20))
    var next = Math.pow(head, 0.7)
    level = next > level ? next : level * 0.65 + next * 0.35
  }

  // Hold the overlay on a result for a moment before returning to idle.
  function settle(resultPhase) {
    phase = resultPhase
    flashTimer.restart()
  }

  // pw-record finalizes the wav header on SIGTERM, so dropping `running`
  // leaves a complete file behind and the transcribe step runs from onExited.
  function stop() {
    if (!recording) return
    phase = "working"
    recProc.running = false
  }

  function cancel() {
    if (!recording) return
    phase = "cancelling"
    recProc.running = false
    flashTimer.stop()
  }

  function toggle(requestedMode) {
    if (recording) stop()
    else start(requestedMode)
  }

  function deliver(text) {
    lastText = text

    if (commandMode) {
      // Tracked, not detached. The interpreter is the half that decides what a
      // spoken sentence meant, and that decision is the thing worth showing —
      // so the chip waits on it, reads the plan off its stdout, and turns a
      // non-zero exit into the error phase instead of losing it to a subprocess
      // nobody was watching.
      phase = "interpreting"
      interpProc.running = true
      return
    }

    if (copyToClipboard) Quickshell.execDetached({ command: ["wl-copy", "--", text] })
    if (typeOut) Quickshell.execDetached({ command: ["wtype", "--", text] })
    settle("done")
  }

  function recopy() {
    if (lastText === "") return
    Quickshell.execDetached({ command: ["wl-copy", "--", lastText] })
    // A click with no visible answer is a click you make twice. Nothing else is
    // on screen at this point, so the chip is the receipt.
    settle("recopied")
  }

  // Never over a live take: the panel takes the keyboard, and the overlay is
  // holding it for esc while the mic is hot.
  // The download runs in a terminal rather than inside the widget, because a
  // gigabyte over an unknown connection needs a progress bar and somewhere for
  // curl to say what went wrong. The widget's job is to know when it finishes:
  // omantra-fetch calls back over IPC on success, and the timer below covers
  // the run that was closed, killed, or failed.
  function fetch() {
    if (fetching) return
    runtime = "fetching"
    Quickshell.execDetached({
      command: ["xdg-terminal-exec", "--title=Omantra — downloading speech runtime",
                "--", "bash", "-lc", "\"$1\"; echo; read -rsn1 -p 'Enter to close'", "_", fetchCommand]
    })
  }

  function checkRuntime() {
    if (!bundledTranscriber || checkProc.running) return
    checkProc.running = true
  }

  function openConfig() {
    if (busy) return
    configPanel.toggle()
  }

  function notify(title, body) {
    Quickshell.execDetached({
      command: ["notify-send", "--app-name=Omantra", "--icon=audio-input-microphone", title, body]
    })
  }

  implicitWidth: layout.implicitWidth
  implicitHeight: layout.implicitHeight

  Timer {
    running: root.recording
    interval: 1000
    repeat: true
    onTriggered: {
      root.elapsed += 1
      // A forgotten recording is a wav that grows until the disk complains;
      // stop at the cap and transcribe what we have rather than discard it.
      if (root.elapsed >= root.maxSeconds) root.stop()
    }
  }

  // The one timer that returns the machine to idle: a result stays up long
  // enough to read, an error stays up longer because it has more to say, and a
  // command's plan sits in between — two fields to read instead of one, and the
  // last chance to notice that the machine misheard which project you meant.
  Timer {
    id: flashTimer
    interval: root.phase === "error" ? 3200 : (root.planLabel !== "" ? 2600 : 1800)
    onTriggered: root.phase = "idle"
  }

  // How much of the top edge the overlay has to keep clear. Only a visible top
  // bar is in its way: a hidden bar, or one on another edge, leaves the chip
  // sitting at the gap from the screen edge like any other popup.
  readonly property int overlayTopClearance:
    bar && !vertical && String(bar.position || "top") === "top" && bar.barHidden !== true ? barSize : 0

  // The gesture that starts a take has no visible target, so the feedback that
  // it worked can't live in the bar. This is the surface the user actually
  // speaks at.
  VoiceOverlay {
    // Follow the bar that owns this widget instance, so on a multi-monitor
    // setup the card lands on the screen the mic glyph is on rather than on
    // whichever one Quickshell would have picked.
    screen: root.QsWindow.window ? root.QsWindow.window.screen : null
    phase: root.overlayPhase
    topClearance: root.overlayTopClearance
    commandMode: root.commandMode
    elapsedLabel: root.elapsedLabel
    resultText: root.lastText
    errorText: root.lastError
    planLabel: root.planLabel
    planDetail: root.planDetail
    level: root.level
    onStopRequested: root.stop()
    onCancelRequested: root.cancel()
  }

  // Settings live in a file both halves read, so the panel is a front-end for
  // `omantra-config` rather than a second store — see ConfigPanel.qml.
  ConfigPanel {
    id: configPanel
    screen: root.QsWindow.window ? root.QsWindow.window.screen : null
    configCommand: root.configCommand
    fetchCommand: root.fetchCommand
    // A saved profile can change what has to be on disk, so the runtime
    // question is asked again alongside the settings reload.
    onSaved: { configProc.running = true; root.checkRuntime() }
  }

  // The store, as `omantra-investigate list --json` reports it. Started by the
  // runner over IPC when a job starts or ends, which is why there is no fast
  // poll — see the timer below for the one case that needs one.
  Process {
    id: listProc
    running: true
    command: [root.investigateCommand, "list", "--json"]
    stdout: StdioCollector { waitForEnd: true }

    onExited: function(exitCode) {
      if (exitCode !== 0) return
      try {
        root.jobs = JSON.parse(String(listProc.stdout.text || "[]"))
      } catch (e) {
        // A widget that cannot read the store still records and still
        // transcribes; it just stops claiming anything about agents.
        console.warn("omantra: could not parse investigations: " + e)
      }
    }
  }

  // Where a landed investigation is read, on request and never otherwise. Fed
  // from `jobs` rather than loading its own list, so the card is already
  // populated the moment it opens.
  ReportPanel {
    id: reportPanel
    screen: root.QsWindow.window ? root.QsWindow.window.screen : null
    investigateCommand: root.investigateCommand
    jobs: root.jobs

    // A report that has actually been shown is a report that has been read.
    // The stamp goes in the store, so every bar on every monitor drops the
    // button off the same write.
    onWasRead: function(id) {
      readProc.command = [root.investigateCommand, "read", id]
      readProc.running = true
    }
  }

  Process {
    id: readProc
    onExited: function(exitCode) { root.refreshInvestigations() }
  }

  // The safety net, not the mechanism. The runner announces both ends of a job
  // over IPC; this only covers the case where the shell was restarted while an
  // agent was working, so it runs at a rate nobody would notice and only while
  // something is actually running.
  Timer {
    running: root.workingCount > 0
    interval: 30000
    repeat: true
    onTriggered: root.refreshInvestigations()
  }

  // Is there anything to transcribe with? Asked once at startup, again
  // whenever a download says it is done, and on a slow poll while one is
  // running. `omantra-fetch --check` is the same question the transcriber
  // answers by failing, asked before a take rather than during one.
  Process {
    id: checkProc
    // Not asked at all when the answer cannot matter — a custom transcriber
    // leaves `runtime` at "unknown", which behaves as ready.
    running: root.bundledTranscriber
    command: [root.fetchCommand, "--check"]

    onExited: function(exitCode) {
      root.runtime = exitCode === 0 ? "ready" : "missing"
    }
  }

  // The fallback, not the mechanism: omantra-fetch announces its own success.
  // This catches the download that was cancelled, failed, or finished while
  // the shell was restarting, so the bar cannot sit on "downloading" forever.
  Timer {
    running: root.fetching
    interval: 5000
    repeat: true
    onTriggered: root.checkRuntime()
  }

  // The widget's copy of the settings the panel writes. Read once at startup
  // and again after every save; a take in flight keeps the values it started
  // with, which is the behaviour you want when the thing being edited is the
  // recording length.
  Process {
    id: configProc
    running: true
    command: [root.configCommand, "json"]
    stdout: StdioCollector { waitForEnd: true }

    onExited: function(exitCode) {
      if (exitCode !== 0) return
      try {
        root.config = JSON.parse(String(configProc.stdout.text || "{}"))
      } catch (e) {
        // A widget that can't read the file still records and still
        // transcribes; it just uses the defaults it was built with.
        console.warn("omantra: could not parse omantra-config json: " + e)
      }
    }
  }

  // Mic level for the overlay's meter, in parallel with the recording. ffmpeg
  // is already a dependency and PipeWire is happy to hand the same source to
  // two clients, so this costs a filter graph on 16 kHz mono and no new
  // runtime. astats prints one RMS reading per `asetnsamples` block — 800
  // samples is 20 a second, past the point where more would be visible.
  //
  // A meter is decoration: if this process fails to start, the bars simply
  // stay on the floor and the take is unaffected.
  Process {
    id: levelProc
    running: root.recording && root.overlayEnabled
    command: ["ffmpeg", "-hide_banner", "-nostdin", "-f", "pulse", "-i", "default",
              "-ac", "1", "-ar", "16000",
              "-af", "asetnsamples=n=800,astats=metadata=1:reset=1,ametadata=print:key=lavfi.astats.Overall.RMS_level",
              "-f", "null", "-"]

    // astats reports on stderr along with ffmpeg's own chatter, so the readings
    // are picked out by key rather than by position.
    stderr: SplitParser {
      splitMarker: "\n"
      onRead: function(line) {
        var match = String(line).match(/RMS_level=(-?[0-9.]+|-inf)/)
        if (!match) return
        root.pushLevel(match[1] === "-inf" ? -120 : Number(match[1]))
      }
    }

    onRunningChanged: {
      root.level = 0
      root.floorDb = 0
    }
  }

  Process {
    id: recProc
    command: ["pw-record", "--rate", "16000", "--channels", "1", root.wavPath]
    stderr: StdioCollector { waitForEnd: true }

    onExited: function(exitCode) {
      if (root.phase === "cancelling") {
        root.phase = "idle"
        return
      }
      // pw-record exits non-zero on SIGTERM on some setups even though the
      // file is good, so the wav itself is the source of truth, not the code.
      transcribeProc.running = true
    }
  }

  Process {
    id: transcribeProc
    command: ["env", "OMANTRA_THREADS=" + root.threads, root.transcribeCommand, root.wavPath]
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }

    onExited: function(exitCode) {
      var text = String(transcribeProc.stdout.text || "").trim()

      if (exitCode !== 0) {
        root.lastError = String(transcribeProc.stderr.text || "").trim() || ("exit " + exitCode)
        root.settle("error")
        if (root.notifyOnError) root.notify("Transcription failed", root.lastError)
        return
      }

      root.lastError = ""
      if (text === "") {
        // No notification for this one. Silence is not a failure the machine
        // has to survive being looked away from — you stopped the take a second
        // ago and you are looking at the chip that says it, and a tray entry
        // for "the mic heard nothing" is a dismissal to do later for news that
        // was over on arrival.
        root.lastError = "No speech detected"
        root.settle("error")
        return
      }

      root.deliver(text)
    }
  }

  // Command mode's second half: the transcript in, one desktop action out.
  //
  // It reports twice. The `plan:` line lands as soon as the model has picked an
  // action — a second or two before the terminal appears — and that is what the
  // chip shows, because "OPEN todo-app · claude" is the sentence that tells the
  // user whether they were understood. The exit code lands later and only
  // matters when it isn't zero.
  Process {
    id: interpProc
    command: [root.interpreterCommand, root.lastText]
    stderr: StdioCollector { waitForEnd: true }

    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function(line) {
        var match = String(line).match(/^plan: ([^|]*)\|(.*)$/)
        if (!match) return
        root.planLabel = match[1]
        root.planDetail = match[2]
        // From here the script is only opening a window, so the chip flashes
        // the decision and lets go rather than waiting on a terminal.
        root.settle("done")
      }
    }

    onExited: function(exitCode) {
      if (exitCode === 0) return
      // `omantra: ` on the front of its own diagnostics is for a terminal, where
      // the reader needs to know which command in a pipeline spoke. In the chip
      // it is eleven characters of the elision budget saying nothing.
      root.lastError = String(interpProc.stderr.text || "").trim().replace(/^omantra:\s*/, "")
        || ("exit " + exitCode)
      // Deliberately overrides a plan that already flashed: a decision that was
      // announced and then failed is exactly the case worth interrupting for.
      //
      // No notification from here. `omantra` notifies its own failures — it has
      // to, since a keybind can run it with no widget watching — and a second
      // copy from this side was landing in the tray next to the first.
      root.settle("error")
    }
  }

  // Lets a Hyprland keybind drive the same toggle as the click, so dictation
  // works without aiming at the bar.
  IpcHandler {
    target: "omantra"

    function toggle(): void { root.toggle("dictate") }
    function toggleCommand(): void { root.toggle("command") }
    function start(): void { root.start("dictate") }
    function stop(): void { root.stop() }
    function cancel(): void { root.cancel() }
    // The machine's own state, rather than a re-derived summary of it: a script
    // asking "what is it doing" gets "done" and "error" too, not just "idle".
    function status(): string { return root.phase }
    function mode(): string { return root.mode }
    function last(): string { return root.lastText }
    function config(): void { root.openConfig() }
    // What bin/omantra-fetch calls when it finishes, and what a keybinding or a
    // terminal can call after downloading the runtime by hand. Broadcast for
    // the same reason the investigation count is: one bar per monitor, and a
    // widget still saying "not downloaded" on the second screen is a bug.
    function checkRuntime(): void { root.broadcast("checkRuntime") }
    function runtime(): string { return root.runtime }

    // The background half. `investigations` is what bin/omantra-investigate
    // calls when a job starts and when it ends; it is broadcast because an IPC
    // target routes to one handler while a bar exists per monitor, and a count
    // that only updates on the screen the shell happened to pick is worse than
    // no count.
    function investigations(): void { root.broadcast("refreshInvestigations") }
    // Two functions rather than one with an optional argument: an IPC call
    // arrives with exactly the parameters the signature declares, so a
    // `report(id)` a keybinding could call would have to pass an empty string.
    function report(): void { root.openReport("") }
    function reportFor(id: string): void { root.openReport(id) }
    function unread(): string { return String(root.unreadCount) }
    function investigating(): string { return String(root.workingCount) }
  }

  // Two buttons rather than one with two meanings: the mic keeps all three of
  // its click gestures, and the agent segment — which is only there when there
  // is something to say — is a surface of its own next to it. A Grid rather
  // than a Row because the bar can be vertical, and then they stack.
  Grid {
    id: layout
    anchors.fill: parent
    rows: root.vertical ? 2 : 1
    columns: root.vertical ? 1 : 2

    WidgetButton {
      id: button
      bar: root.bar
      // The clock only earns its space while it is counting; the rest of the
      // time this is an icon widget like any other.
      text: root.vertical || !root.recording ? root.glyph : root.glyph + " " + root.elapsedLabel
      active: root.recording
      tooltipText: root.statusText
      horizontalMargin: 8.5

      // One meaning per button per state, rather than three buttons and five
      // meanings: left runs the take, right is the settings, and middle is
      // whichever "undo" the current state has — throw this take away while the
      // mic is hot, hand me the last transcript again when it isn't.
      onPressed: function(b) {
        if (b === Qt.RightButton) root.openConfig()
        else if (b === Qt.MiddleButton) root.busy ? root.cancel() : root.recopy()
        else root.toggle("dictate")
      }
    }

    // The whole ambient signal for the background half: a glyph and a count,
    // present only while there is something to say and gone the moment there
    // isn't. Accent while an agent is working or one of them failed, ordinary
    // once what is left is reading — the colour is the difference between
    // "this wants you" and "your turn, whenever".
    WidgetButton {
      id: agents
      bar: root.bar
      visible: root.showingAgents
      hasVisualContent: root.showingAgents
      text: root.agentLabel
      active: root.workingCount > 0 || root.failedCount > 0
      tooltipText: root.agentTooltip
      horizontalMargin: 6

      // One meaning, whichever button: open the newest report I have not read.
      // While an agent is still working there is nothing to open, and the
      // button is a status rather than a control — clicking it then opens the
      // last finished report, which is the least surprising thing it could do.
      onPressed: function(b) { root.openReport("") }
    }
  }
}
