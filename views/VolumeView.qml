import QtQuick
import Quickshell.Services.Pipewire
import qs.Commons

// Transient island overlay for the output volume. Compact on purpose: it
// replaces a page for a beat and leaves, so it shows only the essentials.
//
// Reads Pipewire exactly as views/QuickSettingsView.qml and the bar's
// Microphone widget do; no plugin UI is hosted.
Column {
  id: root

  // Injected by DynamicIsland.
  property var islandState: null

  readonly property var sink: Pipewire.defaultAudioSink
  readonly property bool hasAudio: !!(sink && sink.audio)
  readonly property real volume: hasAudio ? sink.audio.volume : 0
  readonly property bool muted: hasAudio ? sink.audio.muted : false
  readonly property real fraction: Math.max(0, Math.min(1, volume))
  readonly property int percent: Math.round(fraction * 100)

  readonly property string glyph: {
    if (!hasAudio || muted || volume <= 0) return "󰖁"
    if (volume >= 0.67) return "󰕾"
    if (volume >= 0.34) return "󰖀"
    return "󰕿"
  }

  spacing: Style.spacing.sm

  Text {
    anchors.horizontalCenter: parent.horizontalCenter
    text: root.glyph + "  " + root.percent + "%"
    color: Color.bar.text
    font.family: Style.font.family
    font.pixelSize: Style.font.title
    font.weight: Font.Medium
  }

  Rectangle {
    anchors.horizontalCenter: parent.horizontalCenter
    width: Style.space(200)
    height: Style.space(6)
    radius: height / 2
    color: Util.alpha(Color.bar.text, 0.18)

    Rectangle {
      width: Math.round(parent.width * (root.muted ? 0 : root.fraction))
      height: parent.height
      radius: parent.radius
      color: Color.accent
    }
  }
}
