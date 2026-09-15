import QtQuick
import qs.Commons

// Transient island overlay for display brightness. Compact on purpose: it
// replaces a page for a beat and leaves, so it shows only the essentials.
//
// Reads the shared BrightnessState off the bar root; it never polls or writes
// by itself, so the deck slider and this overlay always agree.
Column {
  id: root

  // Injected by DynamicIsland.
  property var islandState: null
  property var islandBar: null

  readonly property var brightness: root.islandBar ? root.islandBar.brightnessState : null
  readonly property bool available: !!brightness && brightness.available === true
  readonly property int percent: available ? brightness.percent : 0
  readonly property real fraction: Math.max(0, Math.min(1, root.percent / 100))

  readonly property string glyph: {
    if (!root.available) return "󰍹"
    if (root.percent >= 67) return "󰃠"
    if (root.percent >= 34) return "󰃟"
    if (root.percent > 0) return "󰃞"
    return "󰃝"
  }

  spacing: Style.spacing.sm

  Text {
    anchors.horizontalCenter: parent.horizontalCenter
    text: root.available ? root.glyph + "  " + root.percent + "%" : "Brightness unavailable"
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
      width: Math.round(parent.width * root.fraction)
      height: parent.height
      radius: parent.radius
      color: Color.accent
    }
  }
}
