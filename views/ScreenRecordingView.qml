import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Native island view for the screen-recording context (island.screenrecord).
//
// Bespoke, not a plugin box. The recorder writes its target path to
// /tmp/omarchy-screenrecord-filename while it runs (see
// omarchy-capture-screenrecording); this view watches that file for the label
// and offers the same stop the bar indicator triggers. It only appears while
// the resolver sees a recorder process, so the view itself never polls.
Column {
  id: root

  // Injected by DynamicIsland.
  property var islandState: null
  property var islandBar: null

  readonly property color fg: Color.bar.text
  readonly property color dim: Util.alpha(Color.bar.text, 0.6)

  property string filename: ""

  function stopRecording() {
    Quickshell.execDetached(["omarchy-capture-screenrecording", "--stop-recording"])
  }

  spacing: Style.spacing.md

  FileView {
    path: "/tmp/omarchy-screenrecord-filename"
    watchChanges: true
    printErrors: false
    onLoaded: root.filename = String(text() || "").trim()
    onFileChanged: root.filename = String(text() || "").trim()
  }

  Row {
    width: parent.width
    spacing: Style.spacing.md

    Rectangle {
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(12)
      height: Style.space(12)
      radius: width / 2
      color: Color.accent

      SequentialAnimation on opacity {
        loops: Animation.Infinite
        running: true
        NumberAnimation { to: 0.25; duration: 700; easing.type: Easing.InOutSine }
        NumberAnimation { to: 1.0; duration: 700; easing.type: Easing.InOutSine }
      }
    }

    Column {
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)

      Text {
        text: "Recording"
        color: root.fg
        font.family: Style.font.family
        font.pixelSize: Style.font.title
        font.weight: Font.Medium
      }

      Text {
        width: Math.min(implicitWidth, root.width - Style.space(28))
        text: root.filename !== "" ? root.filename : "Screen recording in progress"
        color: root.dim
        elide: Text.ElideMiddle
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }
    }
  }

  Button {
    width: parent.width
    text: "Stop recording"
    iconText: "󰓛"
    foreground: root.fg
    fontFamily: Style.font.family
    onClicked: root.stopRecording()
  }
}
