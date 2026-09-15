import QtQuick
import Quickshell.Services.Pipewire
import qs.Commons
import qs.Ui

// Native island view for the microphone context (omarchy.microphone).
//
// Bespoke, not a plugin box: it reads the exact sources bar/widgets/
// Microphone.qml reads (defaultAudioSource plus the live capture streams) and
// presents the recording state, what is using the input, and a mute control.
Column {
  id: root

  // Injected by DynamicIsland.
  property var islandState: null
  property var islandBar: null

  readonly property color fg: Color.bar.text
  readonly property color dim: Util.alpha(Color.bar.text, 0.6)

  readonly property var source: Pipewire.defaultAudioSource
  readonly property bool hasSource: !!(source && source.audio)
  readonly property bool muted: hasSource ? source.audio.muted === true : true
  readonly property real volume: hasSource ? source.audio.volume : 0

  // The resolver is the single source of truth for "an app is capturing": it
  // filters Omarchy's own DSP capture streams out, which the raw Pipewire node
  // scan would otherwise count. Null islandBar (bare test) reads empty.
  readonly property var contextResolver: root.islandBar ? root.islandBar.contextResolverState : null
  readonly property var activeStreams: contextResolver ? contextResolver.activeMicrophoneStreams : []
  readonly property bool inUse: root.activeStreams.length > 0 && !root.muted

  readonly property string glyph: root.muted || !root.hasSource ? "󰍭" : "󰍬"

  readonly property string statusText: {
    if (!root.hasSource) return "No input device"
    if (root.muted) return "Muted"
    if (root.inUse) return "In use by " + root.activeStreams.length
      + (root.activeStreams.length === 1 ? " app" : " apps")
    return "Live"
  }

  function field(node, key, fallback) {
    if (!node) return fallback
    var prop = node[key]
    return (prop === undefined || prop === null || prop === "") ? fallback : String(prop)
  }

  function streamLabel(node) {
    return root.field(node, "description",
      root.field(node, "nickname", root.field(node, "name", "Unknown")))
  }

  function toggleMute() {
    if (root.hasSource) root.source.audio.muted = !root.muted
  }

  spacing: Style.spacing.md

  Row {
    width: parent.width
    spacing: Style.spacing.md

    Text {
      anchors.verticalCenter: parent.verticalCenter
      text: root.glyph
      color: root.fg
      opacity: root.muted ? 0.5 : 1.0
      font.family: Style.font.family
      font.pixelSize: Style.font.display
    }

    Column {
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)

      Text {
        text: "Microphone"
        color: root.fg
        font.family: Style.font.family
        font.pixelSize: Style.font.title
        font.weight: Font.Medium
      }

      Text {
        text: root.statusText
        color: root.dim
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }
    }
  }

  // Live input level. A read-only meter: the bar widget owns the input volume
  // keys, so the island shows the state rather than doubling the control.
  Rectangle {
    width: parent.width
    height: Style.space(6)
    radius: height / 2
    color: Util.alpha(root.fg, 0.18)

    Rectangle {
      width: Math.round(parent.width * (root.muted ? 0 : Math.max(0, Math.min(1, root.volume))))
      height: parent.height
      radius: parent.radius
      color: Color.accent
      Behavior on width { NumberAnimation { duration: 90; easing.type: Easing.OutCubic } }
    }
  }

  Text {
    width: parent.width
    visible: root.activeStreams.length > 0
    text: "IN USE"
    color: root.dim
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    font.bold: true
    font.letterSpacing: 1.2
  }

  Column {
    width: parent.width
    spacing: Style.space(4)
    visible: root.activeStreams.length > 0

    Repeater {
      model: root.activeStreams

      delegate: Row {
        required property var modelData
        width: parent.width
        spacing: Style.spacing.sm

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: "󰍬"
          color: Color.accent
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }

        Text {
          width: Math.max(0, parent.width - Style.space(24))
          anchors.verticalCenter: parent.verticalCenter
          text: root.streamLabel(modelData)
          color: root.fg
          elide: Text.ElideRight
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }
      }
    }
  }

  Button {
    width: parent.width
    text: root.muted ? "Unmute" : "Mute"
    iconText: root.muted ? "󰍬" : "󰍭"
    enabled: root.hasSource
    foreground: root.fg
    fontFamily: Style.font.family
    onClicked: root.toggleMute()
  }
}
