import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Where a background investigation is read.
//
// Nothing here ever opens on its own. A report landing while you are mid-
// sentence must not take the screen — the bar says "report done" and stops
// there — so this card exists only in answer to a click on that button or to
// Super+Alt+R, and it is the only thing in the plugin that covers the window
// you were working in.
//
// The card is two columns: every investigation on the left, newest first, and
// the selected one's report on the right, rendered as markdown. Qt renders it
// natively — `Text.MarkdownText` handles headings, lists, emphasis, code spans
// and links — so the viewer is a Text element rather than a dependency, and a
// report looks like the rest of the plugin instead of like a terminal.
//
// It owns no state of its own beyond the selection: the job list arrives from
// the widget, and the report text comes back from `omantra-investigate show`,
// the same command a terminal would run. Same arrangement as ConfigPanel and
// omantra-config, for the same reason — one reader, and nothing here that can
// disagree with the store.
PanelWindow {
  id: root

  property bool open: false
  property string investigateCommand: ""

  // The widget's copy of `omantra-investigate list --json`, so opening the
  // panel costs no subprocess and a job that lands while it is open moves in
  // the list without being asked.
  property var jobs: []

  property string selectedId: ""
  property string reportText: ""
  property string errorText: ""
  property bool loading: false

  // A report that has actually been put in front of the user. The widget
  // stamps it read, which is what takes the button back off the bar — and it
  // fires per report rather than on opening, so scrolling past two unread ones
  // to reach a third leaves the other two still unread.
  signal wasRead(string id)

  readonly property var selected: {
    for (var i = 0; i < jobs.length; i++) {
      if (jobs[i].id === selectedId) return jobs[i]
    }
    return null
  }

  function select(id) {
    if (id === "") return
    selectedId = id
    reportText = ""
    errorText = ""
    // Two jobs have no report to render and the same thing to show instead: one
    // still working, and one that ended without writing a word. Both get the
    // agent's log. Asking `show` for a report that does not exist would put
    // "no report for …" exactly where the reason it failed belongs.
    if (!selected || selected.status === "running" || !selected.report) {
      loading = false
      logProc.command = [root.investigateCommand, "log", id]
      logProc.running = true
      // A failure that has been put in front of the user is news that has been
      // had. The bar counts one as unread, so it has to clear off the same
      // stamp a landed report does — otherwise "report failed" would sit there
      // for the rest of the session with no gesture that answers it.
      if (selected && selected.status !== "running") root.wasRead(id)
      return
    }
    loading = true
    showProc.command = [root.investigateCommand, "show", id]
    showProc.running = true
    root.wasRead(id)
  }

  function show(id) {
    open = true
    // Whatever was asked for, else whatever is selected, else the newest —
    // which is almost always the report that just landed.
    var want = id && id !== "" ? id : (selectedId !== "" ? selectedId : (jobs.length > 0 ? jobs[0].id : ""))
    select(want)
  }

  function hide() { open = false }

  function toggle(id) {
    if (open) hide()
    else show(id)
  }

  // Reselect when the store changes underneath: a report that lands while the
  // panel is open should become readable without a click, and a selection
  // whose job was pruned should fall back to the newest rather than to a blank
  // pane.
  onJobsChanged: {
    if (!open) return
    if (selectedId === "" || !selected) {
      if (jobs.length > 0) select(jobs[0].id)
      return
    }
    // Only for a job with a report to fetch. Re-selecting one that has none
    // would stamp it read again, which refreshes the store, which lands back
    // here — a loop the empty pane would never show anyone.
    if (selected.status !== "running" && selected.report && reportText === "") select(selectedId)
  }

  function statusColor(status) {
    if (status === "running") return Color.accent
    if (status === "failed" || status === "abandoned") return Color.urgent
    return Util.alpha(Color.popups.text, 0.45)
  }

  function statusLabel(job) {
    if (!job) return ""
    if (job.status === "running") return "working"
    if (job.status === "abandoned") return "stopped"
    if (job.status === "failed") return "failed" + (job.exit === 124 ? " — timed out" : "")
    return job.read ? "read" : "unread"
  }

  // Relative, because the useful question about a report is how fresh it is,
  // not what o'clock it was written.
  function ago(epoch) {
    if (!epoch) return ""
    var secs = Math.max(0, Math.floor(Date.now() / 1000) - epoch)
    if (secs < 60) return secs + "s ago"
    if (secs < 3600) return Math.floor(secs / 60) + "m ago"
    if (secs < 86400) return Math.floor(secs / 3600) + "h ago"
    return Math.floor(secs / 86400) + "d ago"
  }

  function step(delta) {
    if (jobs.length === 0) return
    var index = 0
    for (var i = 0; i < jobs.length; i++) {
      if (jobs[i].id === selectedId) { index = i; break }
    }
    index = Math.max(0, Math.min(jobs.length - 1, index + delta))
    select(jobs[index].id)
  }

  visible: open
  anchors { top: true; bottom: true; left: true; right: true }
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore
  WlrLayershell.namespace: "omantra-report"
  WlrLayershell.layer: WlrLayer.Overlay
  // A reading surface: it holds the keyboard so esc closes it and the arrows
  // move between reports, and hands it back the moment it is closed.
  WlrLayershell.keyboardFocus: open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
  mask: Region { item: card }

  Rectangle {
    anchors.fill: parent
    color: Qt.rgba(0, 0, 0, 0.45)
  }

  Process {
    id: showProc
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }

    onExited: function(exitCode) {
      root.loading = false
      if (exitCode !== 0) {
        root.errorText = String(showProc.stderr.text || "").trim()
          .replace(/^omantra-investigate:\s*/, "") || ("could not read the report (exit " + exitCode + ")")
        return
      }
      root.reportText = String(showProc.stdout.text || "")
    }
  }

  // The agent's stderr, which is what there is to show while it is still
  // working and the only thing there is to show when it failed without writing
  // a word.
  Process {
    id: logProc
    stdout: StdioCollector { waitForEnd: true }

    onExited: function(exitCode) {
      if (exitCode !== 0) return
      var lines = String(logProc.stdout.text || "").trim().split("\n")
      root.reportText = lines.slice(-12).join("\n")
    }
  }

  Process {
    id: cancelProc
    stderr: StdioCollector { waitForEnd: true }
  }

  // While something is running, the elapsed time and the log tail are the only
  // moving parts on the card; a second is as often as either changes.
  Timer {
    running: root.open && root.selected !== null && root.selected.status === "running"
    interval: 1000
    repeat: true
    onTriggered: {
      clock.now = Math.floor(Date.now() / 1000)
      logProc.command = [root.investigateCommand, "log", root.selectedId]
      logProc.running = true
    }
  }

  QtObject {
    id: clock
    property int now: 0
  }

  Item {
    anchors.fill: parent
    focus: true
    Keys.onEscapePressed: root.hide()
    Keys.onUpPressed: root.step(-1)
    Keys.onDownPressed: root.step(1)
    Keys.onPressed: function(event) {
      if (event.key === Qt.Key_K) { root.step(-1); event.accepted = true }
      else if (event.key === Qt.Key_J) { root.step(1); event.accepted = true }
    }
  }

  BorderSurface {
    id: card

    // A window border is a literal pixel count — `border_size` in looknfeel.conf
    // — so this edge is one too. The theme's `[popups] border-width` is 2 under
    // most themes, which reads as a heavier frame than the windows the panel
    // sits over, and `Style.space` would scale it further; matching the window
    // manager means neither.
    readonly property int edgeWidth: 1

    anchors.centerIn: parent
    width: Math.min(parent.width - Style.space(80), Style.space(1000))
    height: Math.min(parent.height - Style.space(80), Style.space(680))
    padding: Style.space(24)
    color: Util.alpha(Color.background, 0.98)
    borderSpec: Border.withWidth(Border.surfaceSpec("popups", "border", Color.popups.border, edgeWidth), edgeWidth)
    radius: Style.cornerRadius

    Column {
      anchors.fill: parent
      anchors.margins: card.contentTopInset
      spacing: Style.space(14)

      // ------------------------------------------------------------- header
      Row {
        width: parent.width
        spacing: Style.space(12)

        Text {
          text: "INVESTIGATIONS"
          color: Color.popups.text
          font.family: Style.font.family
          font.pixelSize: Style.font.heading
          font.bold: true
          font.letterSpacing: 2
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: root.jobs.length === 0 ? "nothing yet"
              : (root.jobs.length + (root.jobs.length === 1 ? " report" : " reports"))
          color: Util.alpha(Color.popups.text, 0.4)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }

      // ------------------------------------------------------------- body
      Row {
        width: parent.width
        height: parent.height - parent.spacing * 2 - Style.space(46)
        spacing: Style.space(18)

        // ---------------------------------------------------- the job list
        Flickable {
          id: list
          width: Style.space(250)
          height: parent.height
          contentHeight: listColumn.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds

          Column {
            id: listColumn
            width: list.width
            spacing: Style.space(2)

            Repeater {
              model: root.jobs

              Rectangle {
                id: jobRow
                required property var modelData

                width: listColumn.width
                height: entry.implicitHeight + Style.space(14)
                color: jobRow.modelData.id === root.selectedId
                  ? Util.alpha(Color.popups.text, 0.08) : "transparent"
                radius: Style.cornerRadius

                Row {
                  id: entry
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(8)
                  anchors.rightMargin: Style.space(8)
                  spacing: Style.space(8)

                  // The one piece of colour in the column: accent while an
                  // agent is working, urgent when it failed, dim when the
                  // report is simply there to read.
                  Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(6)
                    height: width
                    radius: width / 2
                    color: root.statusColor(jobRow.modelData.status)
                  }

                  Column {
                    width: parent.width - Style.space(22)
                    spacing: Style.space(2)

                    Text {
                      width: parent.width
                      text: jobRow.modelData.subject
                      color: Color.popups.text
                      // Unread reads louder than read: the list is also the
                      // answer to "what have I not looked at".
                      font.family: Style.font.family
                      font.pixelSize: Style.font.bodySmall
                      font.bold: jobRow.modelData.status !== "running"
                                 && !jobRow.modelData.read && jobRow.modelData.report
                      elide: Text.ElideRight
                      maximumLineCount: 2
                      wrapMode: Text.Wrap
                    }

                    Text {
                      width: parent.width
                      text: root.statusLabel(jobRow.modelData) + " · "
                            + root.ago(jobRow.modelData.finished || jobRow.modelData.started)
                      color: Util.alpha(Color.popups.text, 0.4)
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideRight
                    }
                  }
                }

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.select(jobRow.modelData.id)
                }
              }
            }

            Text {
              visible: root.jobs.length === 0
              width: listColumn.width
              text: "Say \"look into…\", or run\nomantra-investigate start \"…\""
              color: Util.alpha(Color.popups.text, 0.4)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              wrapMode: Text.Wrap
            }
          }
        }

        Rectangle {
          width: Math.max(1, Style.space(1))
          height: parent.height
          color: Util.alpha(Color.popups.text, 0.12)
        }

        // ------------------------------------------------------ the report
        Flickable {
          id: reader
          width: parent.width - list.width - Style.space(38)
          height: parent.height
          contentHeight: readerColumn.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds

          Column {
            id: readerColumn
            // The document is laid out to the pane, never wider: prose that
            // needed sideways scrolling to be read would be a worse trade than
            // a long line of code clipped at the edge, and Copy hands over the
            // markdown itself when the code is what you came for.
            width: reader.width - Style.space(12)
            spacing: Style.space(10)

            Text {
              width: parent.width
              visible: root.selected !== null && root.selected.status === "running"
              text: {
                if (!root.selected) return ""
                var secs = Math.max(0, (clock.now || Math.floor(Date.now() / 1000)) - root.selected.started)
                return "󱚝  working — " + Math.floor(secs / 60) + "m " + (secs % 60) + "s"
              }
              color: Color.accent
              font.family: Style.font.family
              font.pixelSize: Style.font.subtitle
            }

            Text {
              width: parent.width
              visible: root.errorText !== ""
              text: root.errorText
              color: Color.urgent
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.Wrap
            }

            Text {
              width: parent.width
              visible: root.loading
              text: "reading…"
              color: Util.alpha(Color.popups.text, 0.5)
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }

            // The viewer. Qt's own markdown reader, so there is no converter
            // to install and no HTML to sanitise; links open in the browser
            // because a report's sources are the point of it.
            Text {
              width: parent.width
              text: root.reportText
              textFormat: root.selected && root.selected.status === "running"
                ? Text.PlainText : Text.MarkdownText
              color: root.selected && root.selected.status === "running"
                ? Util.alpha(Color.popups.text, 0.5) : Color.popups.text
              linkColor: Color.accent
              font.family: Style.font.family
              font.pixelSize: root.selected && root.selected.status === "running"
                ? Style.font.caption : Style.font.body
              wrapMode: Text.Wrap
              onLinkActivated: function(link) {
                Quickshell.execDetached({ command: ["xdg-open", link] })
              }

              MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.NoButton
                cursorShape: parent.hoveredLink !== "" ? Qt.PointingHandCursor : Qt.ArrowCursor
              }
            }
          }
        }
      }

      // ------------------------------------------------------------- footer
      Row {
        width: parent.width
        spacing: Style.space(8)

        Text {
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width - Style.space(300)
          text: root.selected ? root.selected.dir : ""
          color: Util.alpha(Color.popups.text, 0.35)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          elide: Text.ElideMiddle
        }

        Button {
          text: "Cancel run"
          bordered: true
          focusable: true
          visible: root.selected !== null && root.selected.status === "running"
          onClicked: {
            cancelProc.command = [root.investigateCommand, "cancel", root.selectedId]
            cancelProc.running = true
          }
        }

        Button {
          text: "Copy"
          bordered: true
          focusable: true
          enabled: root.reportText !== ""
          onClicked: Quickshell.execDetached({ command: ["wl-copy", "--", root.reportText] })
        }

        Button {
          text: "Close"
          bordered: true
          focusable: true
          active: true
          onClicked: root.hide()
        }
      }
    }
  }
}
