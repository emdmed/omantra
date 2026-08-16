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
// goes to the clipboard. Right click re-copies the last one, middle click
// throws the recording away.
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

  readonly property string transcribeCommand: setting("transcribeCommand", "") || (pluginDir + "/bin/transcribe")
  readonly property string interpreterCommand: setting("interpreterCommand", "") || (pluginDir + "/bin/omantra")
  readonly property int threads: setting("threads", 6)
  readonly property int maxSeconds: setting("maxSeconds", 300)
  readonly property bool copyToClipboard: setting("copyToClipboard", true)
  readonly property bool typeOut: setting("typeOut", false)
  readonly property bool notifyOnDone: setting("notify", true)

  // "dictate" puts the transcript on the clipboard; "command" hands it to the
  // interpreter to act on. Chosen when recording starts and read when it lands, so
  // stopping by any route still delivers the way the take was begun.
  property string mode: "dictate"

  property bool recording: false
  property bool working: false
  // Set before the SIGTERM that stops a discarded take, so onExited can tell
  // "user cancelled" from "user finished" — the exit code is the same.
  property bool discarding: false
  property int elapsed: 0
  property string lastText: ""
  property string lastError: ""

  readonly property bool commandMode: mode === "command"
  readonly property string glyph: recording || working ? (commandMode ? "󰚩" : (recording ? "󰑊" : "󰔟")) : "󰍬"

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
    return "Dictate — click to record"
  }

  function start(requestedMode) {
    if (recording || working) return
    mode = requestedMode === "command" ? "command" : "dictate"
    lastError = ""
    elapsed = 0
    discarding = false
    recording = true
    recProc.running = true
  }

  // pw-record finalizes the wav header on SIGTERM, so dropping `running`
  // leaves a complete file behind and the transcribe step runs from onExited.
  function stop() {
    if (!recording) return
    recording = false
    recProc.running = false
  }

  function cancel() {
    if (!recording) return
    discarding = true
    stop()
  }

  function toggle(requestedMode) {
    if (recording) stop()
    else if (!working) start(requestedMode)
  }

  function deliver(text) {
    lastText = text

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

  Process {
    id: recProc
    command: ["pw-record", "--rate", "16000", "--channels", "1", root.wavPath]
    stderr: StdioCollector { waitForEnd: true }

    onExited: function(exitCode) {
      if (root.discarding) {
        root.discarding = false
        return
      }
      // pw-record exits non-zero on SIGTERM on some setups even though the
      // file is good, so the wav itself is the source of truth, not the code.
      root.working = true
      transcribeProc.running = true
    }
  }

  Process {
    id: transcribeProc
    command: ["env", "OMANTRA_THREADS=" + root.threads, root.transcribeCommand, root.wavPath]
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }

    onExited: function(exitCode) {
      root.working = false
      var text = String(transcribeProc.stdout.text || "").trim()

      if (exitCode !== 0) {
        root.lastError = String(transcribeProc.stderr.text || "").trim() || ("exit " + exitCode)
        if (root.notifyOnDone) root.notify("Transcription failed", root.lastError)
        return
      }

      root.lastError = ""
      if (text === "") {
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
    function status(): string { return root.recording ? "recording" : (root.working ? "working" : "idle") }
    function mode(): string { return root.mode }
    function last(): string { return root.lastText }
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

    onPressed: function(b) {
      if (b === Qt.RightButton) root.recopy()
      else if (b === Qt.MiddleButton) root.cancel()
      else root.toggle("dictate")
    }
  }
}
