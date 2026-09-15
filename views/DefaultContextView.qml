import QtQuick
import qs.Commons

// The default context page: the island's generic surface. Entering from the
// bottom with no active "big" context lands here instead of a bare clock.
//
// Composition, not new chrome: the bespoke clock/weather view on top of the
// bespoke quick-settings deck, both reused as-is. Later rounds redesign each
// piece; this page only owns the separator and the spacing.
Column {
  id: root

  // Injected by DynamicIsland.
  property var islandState: null
  property var islandBar: null

  spacing: Style.spacing.lg

  ClockWeatherView {
    width: parent.width
    islandState: root.islandState
    islandBar: root.islandBar
  }

  Rectangle {
    width: parent.width
    height: 1
    color: Util.alpha(Color.bar.text, 0.12)
  }

  QuickSettingsView {
    width: parent.width
    islandState: root.islandState
    islandBar: root.islandBar
  }
}
