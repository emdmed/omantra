import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// The "speak now" surface: a centered card on a dimmed screen, shown from the
// moment recording starts until the transcript lands.
//
// A bar glyph is the wrong affordance for this. Double-tapping Super is a
// gesture with no visible target, and the thing it starts is a microphone that
// is already listening — the user has to know *now*, without looking for it, so
// the feedback goes to the middle of the screen and dims everything else.
//
// Nothing here animates on a timer. The only thing that moves is the meter, and
// it moves because the mic heard something: a card that pulses on its own says
// "I am a widget", a card that answers your voice says "I can hear you".
//
// Input-wise this is a poster, not a dialog: `mask` exposes only the card, so
// clicks anywhere else reach the desktop underneath and no keystroke is ever
// stolen from the window the user is dictating into.
PanelWindow {
  id: root

  // "recording" | "working" | "done" | "error" | "" (hidden)
  property string phase: ""
  property bool commandMode: false
  property string elapsedLabel: "0:00"
  property string resultText: ""
  property string errorText: ""
  // 0..1, straight off the mic. See BarWidget's levelProc.
  property real level: 0

  signal stopRequested()
  signal cancelRequested()

  readonly property bool open: phase !== ""
  readonly property bool live: phase === "recording"
  readonly property color accent: phase === "error" ? Color.urgent : Color.accent

  // The installed mark, wherever this Omarchy lives.
  readonly property string logoSource: "file://" + (Quickshell.env("OMARCHY_PATH") || "/usr/share/omarchy") + "/icon.png"

  readonly property string headline: {
    if (phase === "error") return "FAILED"
    // "TRANSCRIBED" rather than "COPIED": where a dictated take lands depends
    // on the copyToClipboard/typeOut settings, and the card shouldn't claim
    // a destination it doesn't know.
    if (phase === "done") return commandMode ? "SENT" : "TRANSCRIBED"
    if (phase === "working") return "TRANSCRIBING"
    return commandMode ? "SPEAK YOUR COMMAND" : "SPEAK"
  }

  readonly property string detail: {
    if (phase === "error") return errorText
    if (phase === "done") return resultText
    if (phase === "working") return "…"
    return elapsedLabel
  }

  readonly property string hint: {
    if (!live) return ""
    // Two routes only: the gesture that started the take ends it, and esc
    // throws it away. Clicking the card also sends, but a hint line that lists
    // everything stops being read at all.
    return (commandMode ? "double-tap Super to send" : "Super+Alt+D to transcribe") + " · esc to discard"
  }

  visible: open
  anchors { top: true; bottom: true; left: true; right: true }
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore
  WlrLayershell.namespace: "omantra-overlay"
  WlrLayershell.layer: WlrLayer.Overlay
  // Esc has to reach *something*, and a layer surface only gets keys if it asks
  // for them. So the card holds the keyboard while the mic is hot and hands it
  // straight back when the take ends — Hyprland resolves its own keybinds before
  // the focused surface sees anything, so Super gestures keep working
  // throughout. The cost is that you can't type into the window behind while
  // recording, which is the trade a modal "speak now" card is making anyway.
  WlrLayershell.keyboardFocus: live ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
  // Only the card is clickable; the rest of the screen stays the desktop's.
  mask: Region { item: card }

  // The surface is created hidden, so focus has to be taken again once it is
  // actually mapped — binding `focus` alone lands before the window exists.
  onLiveChanged: if (live) Qt.callLater(function() {
    if (root.live) keys.forceActiveFocus()
  })

  Item {
    id: keys
    anchors.fill: parent
    focus: true

    Keys.onEscapePressed: root.cancelRequested()
  }

  // Enough dim to pull the eye off whatever the user was reading, not so much
  // that the screen looks locked.
  Rectangle {
    anchors.fill: parent
    color: Qt.rgba(0, 0, 0, 0.45)
  }

  BorderSurface {
    id: card

    anchors.centerIn: parent
    width: Style.space(400)
    height: contentTopInset + column.implicitHeight + contentBottomInset
    padding: Style.space(34)
    color: Util.alpha(Color.background, 0.97)
    borderSpec: root.phase === "error"
      ? Border.flat(Color.urgent, Math.max(1, Style.space(2)))
      : Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))
    radius: Style.cornerRadius

    MouseArea {
      anchors.fill: parent
      enabled: root.live
      cursorShape: root.live ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: root.stopRequested()
    }

    Column {
      id: column
      anchors.centerIn: parent
      width: parent.width - card.contentLeftInset - card.contentRightInset
      spacing: Style.space(22)

      // The mark, at poster size and holding still. It says whose desktop is
      // listening; the meter under it says that it is.
      Item {
        width: Style.space(104)
        height: width
        anchors.horizontalCenter: parent.horizontalCenter

        Image {
          id: logo
          anchors.fill: parent
          fillMode: Image.PreserveAspectFit
          source: root.logoSource
          // Decode at physical pixels; the source is a 300px PNG and the
          // mark's thin strokes go to mush if Qt scales the logical size.
          sourceSize.width: Math.round(width * Screen.devicePixelRatio)
          sourceSize.height: Math.round(height * Screen.devicePixelRatio)
          visible: false
          layer.enabled: true
        }

        // Recolored so the mark belongs to the theme rather than dragging
        // Omarchy's green into every palette — and so a failure turns it red.
        MultiEffect {
          anchors.fill: logo
          source: logo
          colorization: 1.0
          colorizationColor: root.accent
        }
      }

      // ------------------------------------------------------------- meter
      //
      // One RMS reading drives every bar, weighted into a symmetric spread and
      // trailing outward, so the row swells with the voice instead of pretending
      // to be a spectrum it never measured. At rest the bars sit on the floor
      // height: silence looks like silence.
      Row {
        id: meter

        readonly property var weights: [0.45, 0.68, 0.88, 1.0, 0.88, 0.68, 0.45]
        readonly property int floorHeight: Style.space(4)
        readonly property int fullHeight: Style.space(44)

        // Keeps its band when the meter goes away, so the card doesn't jump a
        // row shorter the moment recording stops.
        opacity: root.live ? 1 : 0
        height: fullHeight
        spacing: Style.space(7)
        anchors.horizontalCenter: parent.horizontalCenter

        Repeater {
          model: meter.weights.length

          Rectangle {
            required property int index

            readonly property real weight: meter.weights[index]
            // Distance from the middle, used to stagger the response so the
            // outer bars lag the inner ones and the row moves like a wave.
            readonly property int fromCenter: Math.abs(index - (meter.weights.length - 1) / 2)

            width: Style.space(6)
            radius: width / 2
            height: meter.floorHeight + (meter.fullHeight - meter.floorHeight) * Math.min(1, root.level * weight)
            anchors.verticalCenter: parent.verticalCenter
            color: root.accent
            opacity: 0.35 + 0.65 * Math.min(1, root.level * weight)

            Behavior on height {
              NumberAnimation { duration: 90 + fromCenter * 45; easing.type: Easing.OutCubic }
            }
            Behavior on opacity {
              NumberAnimation { duration: 90 + fromCenter * 45; easing.type: Easing.OutCubic }
            }
          }
        }
      }

      // -------------------------------------------------------------- copy
      Text {
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        text: root.headline
        color: root.phase === "error" ? Color.urgent : Color.popups.text
        font.family: Style.font.family
        font.pixelSize: Style.font.heading
        font.bold: true
        font.letterSpacing: 3
        wrapMode: Text.Wrap
      }

      Text {
        width: parent.width
        visible: root.detail !== ""
        horizontalAlignment: Text.AlignHCenter
        text: root.detail
        color: root.phase === "error" ? Color.urgent : Util.alpha(Color.popups.text, 0.7)
        font.family: Style.font.family
        font.pixelSize: Style.font.subtitle
        wrapMode: Text.Wrap
        maximumLineCount: 3
        elide: Text.ElideRight
      }

      Text {
        width: parent.width
        visible: root.hint !== ""
        horizontalAlignment: Text.AlignHCenter
        text: root.hint
        color: Util.alpha(Color.popups.text, 0.4)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        wrapMode: Text.Wrap
      }
    }
  }
}
