import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// The "speak now" surface: a compact chip under the bar, shown from the moment
// recording starts until the transcript lands.
//
// A bar glyph is the wrong affordance for this. Double-tapping Super is a
// gesture with no visible target, and the thing it starts is a microphone that
// is already listening — the user has to know *now*, without looking for it. So
// the feedback goes where the eye already goes for machine status, top center
// just below the bar, and it stays out of the way of the window being dictated
// into: no dim, no screen-sized card, nothing covering the text you are
// talking at. Dictation is something you do *while* working, and a surface that
// blanks the screen to say "I'm listening" says it far louder than it needs to.
//
// One row, read left to right, in two groups a hairline apart:
//
//   󰚩 COMMAND 0:03 ▁▄▂  │  [Super] twice to send  [esc] to discard
//   └─── what it is doing ───┘  └────── how to end it ──────┘
//
// State on the left at full contrast, controls on the right at a third of it.
// The split is the whole point: the left half is read every take, the right half
// only until the gesture is learned, and a status chip whose instructions are
// as loud as its status is mostly instructions.
//
// Nothing here animates on a timer. The only thing that moves is the meter, and
// it moves because the mic heard something: a chip that pulses on its own says
// "I am a widget", a chip that answers your voice says "I can hear you".
//
// Input-wise this is a poster, not a dialog: `mask` exposes only the chip, so
// clicks anywhere else reach the desktop underneath and no keystroke is ever
// stolen from the window the user is dictating into.
PanelWindow {
  id: root

  // "recording" | "working" | "interpreting" | "done" | "recopied" | "error"
  // | "" (hidden)
  property string phase: ""
  property bool commandMode: false
  property string elapsedLabel: "0:00"
  property string resultText: ""
  property string errorText: ""
  // What the interpreter is about to do, as a state word and its subject —
  // "OPEN" / "todo-app · claude". This is the chip's whole reason for existing
  // past the take: a spoken command is a guess at what was said, and the guess
  // has to be readable before the terminal it opens covers the screen.
  property string planLabel: ""
  property string planDetail: ""
  // 0..1, straight off the mic. See BarWidget's levelProc.
  property real level: 0
  // Height of bar to clear at the top of this screen — 0 when the bar is
  // hidden or living on another edge. The overlay is its own layer surface
  // spanning the whole output, so nothing else keeps the chip off the bar.
  property int topClearance: 0

  signal stopRequested()
  signal cancelRequested()

  readonly property bool open: phase !== ""
  readonly property bool live: phase === "recording"
  readonly property color accent: phase === "error" ? Color.urgent : Color.accent
  readonly property color text: phase === "error" ? Color.urgent : Color.popups.text

  // The bar widget's own vocabulary, plus a mark for the two phases the bar
  // never shows. This used to be the Omarchy logo at poster size; shrunk to
  // one line it lost its strokes and read as a missing-glyph box, and a chip
  // that opens with what looks like tofu has spent its first pixels badly. A
  // glyph the icon font actually draws at this size says more anyway: which
  // mode you are in, not whose desktop you are on.
  readonly property string glyph: {
    if (phase === "error") return "󰅚"
    if (phase === "done" || phase === "recopied") return "󰄬"
    if (phase === "working") return "󰔟"
    // Two different waits, two different glyphs: the hourglass is speech
    // becoming text, the robot is a model deciding what the text meant.
    if (phase === "interpreting") return "󰚩"
    return commandMode ? "󰚩" : "󰑊"
  }

  // Short enough to sit on one line beside the meter. "COMMAND" rather than
  // "SPEAK YOUR COMMAND": at chip size the label is a state name, not a prompt.
  readonly property string headline: {
    if (phase === "error") return "FAILED"
    if (phase === "recopied") return "COPIED AGAIN"
    // The interpreter's own word for what it picked — "NEW PROJECT", "THEME",
    // "NOT UNDERSTOOD" — beats anything this file could say about it. "SENT" is
    // the fallback for a command that ended before it announced a plan.
    if (phase === "done" && planLabel !== "") return planLabel
    // "TRANSCRIBED" rather than "COPIED": where a dictated take lands depends
    // on the copyToClipboard/typeOut settings, and the chip shouldn't claim
    // a destination it doesn't know.
    if (phase === "done") return commandMode ? "SENT" : "TRANSCRIBED"
    if (phase === "working") return "TRANSCRIBING"
    if (phase === "interpreting") return "DECIDING"
    return commandMode ? "COMMAND" : "SPEAK"
  }

  readonly property string detail: {
    if (phase === "error") return errorText
    if (phase === "done" && planLabel !== "") return planDetail
    if (phase === "done" || phase === "recopied") return resultText
    if (phase === "working") return "…"
    // The words it is deciding about, so a misheard sentence is visible before
    // it turns into an action rather than after.
    if (phase === "interpreting") return resultText
    return elapsedLabel
  }

  // Two routes only: the gesture that started the take ends it, and esc throws
  // it away. Clicking the chip also sends, but a third row of keys stops the
  // other two from being read at all.
  //
  // Drawn as keycaps rather than prose. A sentence at this size is a gray
  // stripe the eye skips; a cap is a shape the eye recognises as "press this",
  // which is the one thing the right half of the chip has to say.
  readonly property var shortcuts: {
    if (!live) return []
    return [
      commandMode ? { cap: "Super", label: "twice to send" }
                  : { cap: "Super+Alt+D", label: "to send" },
      { cap: "esc", label: "to discard" }
    ]
  }

  visible: open
  anchors { top: true; bottom: true; left: true; right: true }
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore
  WlrLayershell.namespace: "omantra-overlay"
  WlrLayershell.layer: WlrLayer.Overlay
  // Esc has to reach *something*, and a layer surface only gets keys if it asks
  // for them. So the chip holds the keyboard while the mic is hot and hands it
  // straight back when the take ends — Hyprland resolves its own keybinds before
  // the focused surface sees anything, so Super gestures keep working
  // throughout. The cost is that you can't type into the window behind while
  // recording, which is the trade a "speak now" surface is making anyway.
  WlrLayershell.keyboardFocus: live ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
  // Only the chip is clickable; the rest of the screen stays the desktop's.
  mask: Region { item: chip }

  // The surface is created hidden, so focus has to be taken again once it is
  // actually mapped — binding `focus` alone lands before the window exists.
  onLiveChanged: if (live) Qt.callLater(function() {
    if (root.live) keyCatcher.forceActiveFocus()
  })

  Item {
    id: keyCatcher
    anchors.fill: parent
    focus: true

    Keys.onEscapePressed: root.cancelRequested()
  }

  BorderSurface {
    id: chip

    // One text-line tall, so the chip reads as a strip of status rather than a
    // small card: every phase is the same height and only the width moves.
    readonly property int rowHeight: Style.space(20)
    // Past this, a long transcript elides instead of stretching the chip
    // across the screen.
    readonly property int detailLimit: Style.space(300)

    anchors.horizontalCenter: parent.horizontalCenter
    anchors.top: parent.top
    anchors.topMargin: root.topClearance + Style.gapsOut

    width: contentLeftInset + row.implicitWidth + contentRightInset
    height: contentTopInset + rowHeight + contentBottomInset
    topPadding: Style.space(6)
    bottomPadding: Style.space(6)
    leftPadding: Style.space(11)
    rightPadding: Style.space(12)
    color: Util.alpha(Color.background, 0.97)
    // The border is the state: a hot mic outlines the chip in the accent, a
    // failure in the urgent color, and a landed take falls back to the ordinary
    // popup edge. It costs nothing and it is readable from the far side of the
    // screen, which is the reach the dim used to buy.
    borderSpec: root.live || root.phase === "error"
      ? Border.flat(Util.alpha(root.accent, 0.9), Math.max(1, Style.space(2)))
      : Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))
    radius: Style.cornerRadius

    // The meter appearing, the keys leaving, a result arriving: each changes how
    // much there is to say, and the chip grows into it rather than snapping to a
    // new size under the pointer.
    Behavior on width {
      NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
    }

    MouseArea {
      anchors.fill: parent
      enabled: root.live
      cursorShape: root.live ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: root.stopRequested()
    }

    Row {
      id: row
      anchors.centerIn: parent
      height: chip.rowHeight
      spacing: Style.space(8)

      // ------------------------------------------------------- state group
      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: root.glyph
        color: root.accent
        font.family: Style.font.family
        font.pixelSize: Style.font.icon
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: root.headline
        color: root.text
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        font.bold: true
        font.letterSpacing: 1.5
        maximumLineCount: 1
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        visible: root.detail !== ""
        // Natural width up to the cap, then elide: the chip is allowed to grow
        // for a short transcript and refuses to grow for a long one.
        width: Math.min(implicitWidth, chip.detailLimit)
        text: root.detail
        color: Util.alpha(root.text, root.phase === "error" ? 1 : 0.75)
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        maximumLineCount: 1
        elide: Text.ElideRight
      }

      // ------------------------------------------------------------- meter
      //
      // One RMS reading drives every column, weighted into a symmetric spread
      // and trailing outward, so the row swells with the voice instead of
      // pretending to be a spectrum it never measured.
      //
      // Each column is a dim track with an accent fill rising in it, rather
      // than a bar that shrinks to a dot: at chip size a row of dots is an
      // ellipsis, and silence should look like empty tracks — a meter reading
      // nothing — not like punctuation.
      //
      // It exists only while the mic is hot, and the chip narrows by exactly
      // its width when the take ends.
      Row {
        id: meter

        readonly property var weights: [0.5, 0.78, 1.0, 0.78, 0.5]
        // Shorter than the line it sits on, so it reads as an instrument inside
        // the row rather than as a second border, and columns wide enough apart
        // to be counted — packed any tighter they hatch into one gray block.
        readonly property int trackHeight: Style.space(14)

        visible: root.live
        height: chip.rowHeight
        spacing: Style.space(4)
        leftPadding: Style.space(2)
        rightPadding: Style.space(4)
        anchors.verticalCenter: parent.verticalCenter

        Repeater {
          model: meter.weights.length

          Rectangle {
            id: track
            required property int index

            readonly property real weight: meter.weights[index]
            // Distance from the middle, used to stagger the response so the
            // outer columns lag the inner ones and the row moves like a wave.
            readonly property int fromCenter: Math.abs(index - (meter.weights.length - 1) / 2)
            readonly property real reading: Math.min(1, root.level * weight)

            width: Style.space(4)
            height: meter.trackHeight
            anchors.verticalCenter: parent.verticalCenter
            radius: width / 2
            color: Util.alpha(root.text, 0.1)

            Rectangle {
              anchors.bottom: parent.bottom
              width: parent.width
              // Nothing at all at rest. Every floor value tried here — a dot,
              // a stub, a short bar — turns the row into punctuation the eye
              // reads as text: dots became an ellipsis, stubs became a row of
              // `i`. An empty track is unmistakably an instrument reading zero,
              // and the accent glyph and border are already saying "hot mic".
              height: parent.height * track.reading
              radius: parent.radius
              color: root.accent
              opacity: 0.55 + 0.45 * track.reading

              Behavior on height {
                NumberAnimation { duration: 90 + track.fromCenter * 45; easing.type: Easing.OutCubic }
              }
              Behavior on opacity {
                NumberAnimation { duration: 90 + track.fromCenter * 45; easing.type: Easing.OutCubic }
              }
            }
          }
        }
      }

      // -------------------------------------------------------- keys group
      Rectangle {
        visible: root.shortcuts.length > 0
        width: Math.max(1, Style.space(1))
        height: Math.round(chip.rowHeight * 0.7)
        anchors.verticalCenter: parent.verticalCenter
        color: Util.alpha(root.text, 0.15)
      }

      Repeater {
        model: root.shortcuts

        Row {
          required property var modelData

          height: chip.rowHeight
          spacing: Style.space(5)
          // The gap between two shortcuts has to beat the gap inside one, or
          // the caps and labels read as one long alternating strip.
          rightPadding: Style.space(6)

          Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: cap.implicitWidth + Style.space(10)
            height: Style.space(15)
            // Sharp caps under a sharp-cornered theme: the chip's own radius
            // comes from Hyprland's rounding, and a rounded key inside a square
            // chip looks like it came from somewhere else.
            radius: Style.cornerRadius > 0 ? Style.space(3) : 0
            color: Util.alpha(root.text, 0.07)
            border.width: Math.max(1, Style.space(1))
            border.color: Util.alpha(root.text, 0.18)

            Text {
              id: cap
              anchors.centerIn: parent
              text: parent.parent.modelData.cap
              color: Util.alpha(root.text, 0.55)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: parent.modelData.label
            color: Util.alpha(root.text, 0.35)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
