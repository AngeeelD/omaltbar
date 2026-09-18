import QtQuick
import qs.Commons

// The always-visible indicator row beside the pill: click-only status circles
// for battery, Wi-Fi, Bluetooth and the music meter (the meter is absent while
// nothing plays).
//
// It is a STATIC sibling of the notch body — anchored to the strip itself,
// never to the animated pill wing — so a click target never moves when the
// island opens and retracts the pill under the pointer. It grows horizontally
// only: the strip is 64 px tall and the row never touches setStripHeight.
//
// Click-only by contract: the dwell policy belongs to island-hover-dwell, so
// the circles carry TapHandlers and no hover handler at all.
Item {
  id: root

  // Live status projection (the owning island unit's PillStatusSource).
  property var statusSource: null
  // IslandState of the owning unit: a circle click opens its context through it.
  property var islandState: null
  // Session visibility, toggled by the pill's RIGHT click. Default: visible.
  property bool rowVisible: true

  // Role -> context mapping (D9): the caller names the service, the row knows
  // which context it opens. Keeping the map out of the dial leaves the dial a
  // dumb painter with a stable role identifier.
  readonly property var contextForRole: ({
    power: "omarchy.power",
    network: "omarchy.network",
    bluetooth: "omarchy.bluetooth",
    media: "omarchy.media"
  })

  function activate(role) {
    var contextId = root.contextForRole[String(role)] || ""
    if (contextId === "" || !root.islandState) return
    root.islandState.setContext(contextId)
  }

  readonly property var bt: root.statusSource ? root.statusSource.btState : null
  readonly property bool meterPlaying:
    root.statusSource ? root.statusSource.meterState.playing === true : false

  width: row.implicitWidth
  height: row.implicitHeight
  visible: root.rowVisible

  Row {
    id: row
    spacing: Style.space(8)

    // Battery -> power. Dims when no pack is present, but stays clickable.
    PillStatusDial {
      role: "power"
      value: root.statusSource ? root.statusSource.batteryFraction : 0
      available: root.statusSource ? root.statusSource.batteryPresent : false
      glyph: root.statusSource && root.statusSource.batteryPresent
        ? root.statusSource.batteryGlyph : "󰂑"
      accent: Color.accent
      onClicked: function(role) { root.activate(role) }
    }

    // Wi-Fi -> network. Dims when no link is up.
    PillStatusDial {
      role: "network"
      value: root.statusSource ? root.statusSource.wifiFraction : 0
      available: root.statusSource ? root.statusSource.wifiKind !== "disconnected" : false
      glyph: root.statusSource ? root.statusSource.wifiGlyph : ""
      accent: Color.accent
      onClicked: function(role) { root.activate(role) }
    }

    // Bluetooth -> bluetooth. Dims when the radio is absent or off.
    PillStatusDial {
      role: "bluetooth"
      value: root.bt ? root.bt.fraction : 0
      available: root.bt ? root.bt.available : false
      glyph: root.bt ? root.bt.glyph : "󰂲"
      accent: Color.accent
      onClicked: function(role) { root.activate(role) }
    }

    // Music meter -> media. Absent while nothing plays (D4): the Row skips an
    // invisible child, so the dial simply leaves the run.
    PillStatusDial {
      role: "media"
      visible: root.meterPlaying
      value: root.statusSource ? root.statusSource.meterState.level : 0
      available: true
      glyph: "󰎆"
      accent: Color.accent
      onClicked: function(role) { root.activate(role) }
    }
  }
}
