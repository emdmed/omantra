import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// The settings card: what the LLM server is, what agent a project opens with,
// where projects go, and how a take is delivered.
//
// It edits no state of its own. `omantra-config json` fills the fields,
// `omantra-config set` writes them, and `omantra-config check` answers "is the
// server up?" — the same three commands a terminal would use. That is the point:
// the panel is a front-end for the file, not a second place settings live, so a
// value changed here is a value `omantra` sees on the next take and a value
// changed in the file is what the panel shows next time it opens.
//
// Nothing is written until Save. A settings surface that commits on keystroke
// turns a half-typed URL into a broken endpoint, and this one is most often
// opened *because* command mode just failed.
PanelWindow {
  id: root

  property bool open: false
  property string configCommand: ""

  // Loaded values, as `omantra-config json` returned them. Save diffs against
  // this, so an untouched field is never written — a file the user hand-edited
  // keeps the comments and ordering around every key the panel didn't change.
  property var loaded: ({})

  // "" | "checking" | "up" | "down" — the endpoint's answer to the Test button.
  property string endpointState: ""
  property string errorText: ""
  property bool saving: false

  signal saved()

  function show() {
    // Reload every time rather than trusting what is on screen: `omantra-config
    // set` from a terminal is a legitimate way to change these, and a stale
    // card would quietly write the old values back over it.
    errorText = ""
    endpointState = ""
    loadProc.running = true
    open = true
  }

  function hide() {
    open = false
  }

  function toggle() {
    if (open) hide()
    else show()
  }

  function apply(cfg) {
    loaded = cfg
    endpointField.text = cfg.OMANTRA_ENDPOINT || ""
    agentField.text = cfg.OMANTRA_AGENT || ""
    projectsField.text = cfg.OMANTRA_PROJECTS || ""
    // Both halves: `value` is the property the component was built with, and
    // `field.value` is the spin box the user has been typing into — editing one
    // breaks its binding to the other, so a reload sets each explicitly rather
    // than trusting a binding that may already be gone.
    threadsField.value = threadsField.field.value = cfg.OMANTRA_THREADS || 6
    secondsField.value = secondsField.field.value = cfg.OMANTRA_MAX_SECONDS || 300
    copyToggle.checked = cfg.OMANTRA_COPY_CLIPBOARD === true
    typeToggle.checked = cfg.OMANTRA_TYPE_OUT === true
    notifyToggle.checked = cfg.OMANTRA_NOTIFY === true
    overlayToggle.checked = cfg.OMANTRA_OVERLAY === true
  }

  // The pairs that differ from what was loaded, flattened into `set`'s
  // argument list. Empty means Save has nothing to do.
  function changes() {
    var out = []
    function diff(key, value) {
      if (String(root.loaded[key]) !== String(value)) out.push(key, String(value))
    }
    diff("OMANTRA_ENDPOINT", endpointField.text.trim())
    diff("OMANTRA_AGENT", agentField.text.trim())
    diff("OMANTRA_PROJECTS", projectsField.text.trim())
    diff("OMANTRA_THREADS", threadsField.field.value)
    diff("OMANTRA_MAX_SECONDS", secondsField.field.value)
    diff("OMANTRA_COPY_CLIPBOARD", copyToggle.checked)
    diff("OMANTRA_TYPE_OUT", typeToggle.checked)
    diff("OMANTRA_NOTIFY", notifyToggle.checked)
    diff("OMANTRA_OVERLAY", overlayToggle.checked)
    return out
  }

  function save() {
    var pairs = changes()
    if (pairs.length === 0) {
      hide()
      return
    }
    errorText = ""
    saving = true
    saveProc.command = [root.configCommand, "set"].concat(pairs)
    saveProc.running = true
  }

  // Tests the field, not the saved value: the reason to type a new endpoint is
  // usually that the old one is wrong, and finding out after saving is one
  // round trip too many.
  function check() {
    endpointState = "checking"
    checkProc.command = [root.configCommand, "check", endpointField.text.trim()]
    checkProc.running = true
  }

  visible: open
  anchors { top: true; bottom: true; left: true; right: true }
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore
  WlrLayershell.namespace: "omantra-config"
  WlrLayershell.layer: WlrLayer.Overlay
  // A dialog, unlike the overlay: it has fields to type into, so it takes the
  // keyboard for as long as it is up.
  WlrLayershell.keyboardFocus: open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
  mask: Region { item: card }

  onOpenChanged: if (open) Qt.callLater(function() {
    if (root.open) endpointField.forceActiveFocus()
  })

  Rectangle {
    anchors.fill: parent
    color: Qt.rgba(0, 0, 0, 0.45)
  }

  Process {
    id: loadProc
    command: [root.configCommand, "json"]
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }

    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.errorText = String(loadProc.stderr.text || "").trim() || ("could not read settings (exit " + exitCode + ")")
        return
      }
      try {
        root.apply(JSON.parse(String(loadProc.stdout.text || "{}")))
      } catch (e) {
        root.errorText = "could not parse settings: " + e
      }
    }
  }

  Process {
    id: saveProc
    stderr: StdioCollector { waitForEnd: true }

    onExited: function(exitCode) {
      root.saving = false
      if (exitCode !== 0) {
        // omantra-config's own message, which names the field and the range it
        // wanted — better copy than anything this file could invent.
        root.errorText = String(saveProc.stderr.text || "").trim() || ("save failed (exit " + exitCode + ")")
        return
      }
      root.saved()
      root.hide()
    }
  }

  Process {
    id: checkProc
    onExited: function(exitCode) { root.endpointState = exitCode === 0 ? "up" : "down" }
  }

  Item {
    id: keys
    anchors.fill: parent
    focus: true
    Keys.onEscapePressed: root.hide()
  }

  BorderSurface {
    id: card

    anchors.centerIn: parent
    width: Style.space(520)
    height: contentTopInset + column.implicitHeight + contentBottomInset
    padding: Style.space(28)
    color: Util.alpha(Color.background, 0.98)
    borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))
    radius: Style.cornerRadius

    Column {
      id: column
      anchors.centerIn: parent
      width: parent.width - card.contentLeftInset - card.contentRightInset
      spacing: Style.space(16)

      // ------------------------------------------------------------- header
      Text {
        text: "OMANTRA SETTINGS"
        color: Color.popups.text
        font.family: Style.font.family
        font.pixelSize: Style.font.heading
        font.bold: true
        font.letterSpacing: 2
      }

      Text {
        width: parent.width
        // Where the values end up, so the file is findable from the GUI rather
        // than only from the README.
        text: root.loaded.configFile || ""
        visible: text !== ""
        color: Util.alpha(Color.popups.text, 0.4)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        elide: Text.ElideMiddle
      }

      // ------------------------------------------------------- command mode
      PanelSectionHeader { text: "COMMAND MODE" }

      Column {
        width: parent.width
        spacing: Style.space(6)

        Text {
          text: "Model server"
          color: Util.alpha(Color.popups.text, 0.6)
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }

        Row {
          width: parent.width
          spacing: Style.space(8)

          TextField {
            id: endpointField
            width: parent.width - testButton.width - statusLabel.width - parent.spacing * 2
            placeholderText: "http://127.0.0.1:8081/v1/chat/completions"
            onTextChanged: root.endpointState = ""
          }

          Text {
            id: statusLabel
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(78)
            horizontalAlignment: Text.AlignRight
            text: root.endpointState === "checking" ? "checking…"
                : root.endpointState === "up" ? "answering"
                : root.endpointState === "down" ? "no answer" : ""
            color: root.endpointState === "down" ? Color.urgent
                 : root.endpointState === "up" ? Color.accent
                 : Util.alpha(Color.popups.text, 0.5)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          Button {
            id: testButton
            anchors.verticalCenter: parent.verticalCenter
            text: "Test"
            bordered: true
            focusable: true
            onClicked: root.check()
          }
        }
      }

      Column {
        width: parent.width
        spacing: Style.space(6)

        Text {
          text: "Coding agent"
          color: Util.alpha(Color.popups.text, 0.6)
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }

        TextField {
          id: agentField
          width: parent.width
          placeholderText: "claude"
        }
      }

      Column {
        width: parent.width
        spacing: Style.space(6)

        Text {
          text: "Projects directory"
          color: Util.alpha(Color.popups.text, 0.6)
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }

        TextField {
          id: projectsField
          width: parent.width
          placeholderText: "/home/you/projects"
        }
      }

      // ---------------------------------------------------------- recording
      PanelSectionHeader { text: "RECORDING" }

      Row {
        width: parent.width
        spacing: Style.space(24)

        NumberField {
          id: threadsField
          label: "Decoder threads"
          from: 1
          to: 12
        }

        NumberField {
          id: secondsField
          label: "Max length (seconds)"
          from: 10
          to: 3600
          stepSize: 10
        }
      }

      // ----------------------------------------------------------- delivery
      PanelSectionHeader { text: "DELIVERY" }

      Toggle {
        id: copyToggle
        width: parent.width
        label: "Copy to clipboard"
        description: "Dictated transcripts land on the clipboard"
        onClicked: checked = !checked
      }

      Toggle {
        id: typeToggle
        width: parent.width
        label: "Type into the focused window"
        description: "Needs wtype"
        onClicked: checked = !checked
      }

      Toggle {
        id: notifyToggle
        width: parent.width
        label: "Notify on failures"
        description: "Successes are shown in the chip, not the tray"
        onClicked: checked = !checked
      }

      Toggle {
        id: overlayToggle
        width: parent.width
        label: "Speak-now overlay"
        description: "The chip under the bar while the mic is hot"
        onClicked: checked = !checked
      }

      // ------------------------------------------------------------- footer
      Text {
        width: parent.width
        visible: root.errorText !== ""
        text: root.errorText
        color: Color.urgent
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        wrapMode: Text.Wrap
        maximumLineCount: 3
        elide: Text.ElideRight
      }

      Row {
        anchors.right: parent.right
        spacing: Style.space(8)

        Button {
          text: "Cancel"
          bordered: true
          focusable: true
          onClicked: root.hide()
        }

        Button {
          text: root.saving ? "Saving…" : "Save"
          bordered: true
          focusable: true
          // The one emphasized control on the card: this is the button the
          // panel exists to be clicked.
          active: true
          enabled: !root.saving
          onClicked: root.save()
        }
      }

      Text {
        width: parent.width
        horizontalAlignment: Text.AlignRight
        text: "esc to close without saving"
        color: Util.alpha(Color.popups.text, 0.35)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }
  }
}
