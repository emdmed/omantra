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
  moduleName: "enrique.omantra"

  readonly property string wavPath: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/omantra.wav"

  // Scripts ship inside the plugin, so a checkout is self-contained and works
  // wherever it is cloned. A setting still wins, for pointing at one elsewhere.
  readonly property string pluginDir: String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "").replace(/\/$/, "")

  readonly property string transcribeCommand: setting("transcribeCommand", "") || (pluginDir + "/bin/omantra-transcribe")
  readonly property string interpreterCommand: setting("interpreterCommand", "") || (pluginDir + "/bin/omantra")
  readonly property string configCommand: pluginDir + "/bin/omantra-config"

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
  readonly property bool notifyOnDone: configured("OMANTRA_NOTIFY", setting("notify", true))
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
  //   idle → recording → working → done | error → idle
  //            ↓
  //        cancelling → idle
  //
  // "cancelling" is the beat between the SIGTERM of a discarded take and
  // pw-record actually exiting; it is what lets recProc.onExited tell "user
  // cancelled" from "user finished", which the exit code cannot.
  //
  // "working" starting the moment recording stops — rather than when the
  // recorder exits — also closes a gap where neither flag was set and the
  // overlay blinked out and back in between the two.
  property string phase: "idle"

  readonly property bool recording: phase === "recording"
  readonly property bool working: phase === "working"
  readonly property bool busy: recording || working

  property int elapsed: 0
  property real level: 0
  // Starts at the ceiling so the first readings of a take pull it straight down
  // to whatever this room actually sounds like.
  property real floorDb: 0
  property string lastText: ""
  property string lastError: ""

  // The overlay understands exactly the phases the machine has, minus the two
  // that mean "nothing to show".
  readonly property string overlayPhase:
    (!overlayEnabled || phase === "idle" || phase === "cancelling") ? "" : phase

  readonly property bool commandMode: mode === "command"
  // At rest this is a head with sound coming out of it, not a microphone: the
  // stock omarchy.microphone widget is already a microphone, down to the same
  // glyph, and two identical mic icons in one bar is one too many. This one is
  // about speaking to the machine rather than about the input device.
  readonly property string glyph: busy ? (commandMode ? "󰚩" : (recording ? "󰑊" : "󰔟")) : "󰗋"

  readonly property string elapsedLabel: {
    var m = Math.floor(elapsed / 60)
    var s = elapsed % 60
    return m + ":" + (s < 10 ? "0" + s : String(s))
  }

  readonly property string statusText: {
    if (recording) return (commandMode ? "Command " : "Recording ") + elapsedLabel + " — click to transcribe"
    if (working) return "Transcribing…"
    if (lastError !== "") return "Failed: " + lastError
    if (lastText !== "") return (commandMode ? "Sent: " : "Copied: ") + lastText
    return "Dictate — click to record · right click for settings"
  }

  function start(requestedMode) {
    // Only idle takes a new take: "done"/"error" are still showing the last
    // result, and starting from there would be a take begun over a stale card.
    if (phase !== "idle" && phase !== "done" && phase !== "error") return
    mode = requestedMode === "command" ? "command" : "dictate"
    lastError = ""
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
    settle("done")

    if (commandMode) {
      // The interpreter owns its own notifications from here — it knows what it
      // decided to do, which is the useful thing to report, not the words.
      Quickshell.execDetached({ command: [interpreterCommand, text] })
      if (notifyOnDone) notify("Heard", text)
      return
    }

    if (copyToClipboard) Quickshell.execDetached({ command: ["wl-copy", "--", text] })
    if (typeOut) Quickshell.execDetached({ command: ["wtype", "--", text] })
    if (notifyOnDone) notify("Transcribed", text)
  }

  function recopy() {
    if (lastText === "") return
    Quickshell.execDetached({ command: ["wl-copy", "--", lastText] })
    if (notifyOnDone) notify("Copied again", lastText)
  }

  // Never over a live take: the panel takes the keyboard, and the overlay is
  // holding it for esc while the mic is hot.
  function openConfig() {
    if (busy) return
    configPanel.toggle()
  }

  function notify(title, body) {
    Quickshell.execDetached({
      command: ["notify-send", "--app-name=Omantra", "--icon=audio-input-microphone", title, body]
    })
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

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
  // enough to read, and an error stays up longer because it has more to say.
  Timer {
    id: flashTimer
    interval: root.phase === "error" ? 3200 : 1800
    onTriggered: root.phase = "idle"
  }

  // The gesture that starts a take has no visible target, so the feedback that
  // it worked can't live in the bar. This is the surface the user actually
  // speaks at.
  VoiceOverlay {
    // Follow the bar that owns this widget instance, so on a multi-monitor
    // setup the card lands on the screen the mic glyph is on rather than on
    // whichever one Quickshell would have picked.
    screen: root.QsWindow.window ? root.QsWindow.window.screen : null
    phase: root.overlayPhase
    commandMode: root.commandMode
    elapsedLabel: root.elapsedLabel
    resultText: root.lastText
    errorText: root.lastError
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
    onSaved: configProc.running = true
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
        if (root.notifyOnDone) root.notify("Transcription failed", root.lastError)
        return
      }

      root.lastError = ""
      if (text === "") {
        root.lastError = "No speech detected"
        root.settle("error")
        if (root.notifyOnDone) root.notify("Nothing to transcribe", "No speech detected")
        return
      }

      root.deliver(text)
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
  }

  WidgetButton {
    id: button
    anchors.fill: parent
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
}
