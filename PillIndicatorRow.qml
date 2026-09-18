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
  // Session visibility of the circles beside the pill, toggled by the pill's
  // RIGHT click together with the app spheres. Default: visible.
  property bool circlesVisible: true

  // Diameter of one dial; the mount overrides it with 80% of the pill height.
  property int diameter: Style.font.title + Style.space(10)
  // Duration of the open/close hide; the mount passes the island's motion base
  // so the circles retract in step with the pill. 340 is the built-in default.
  property int motionDuration: 340
  // True while the island body is expanded below the strip. The circles then
  // fade and shrink away and stop accepting clicks, mirroring the pill retract.
  readonly property bool islandOpen:
    root.islandState ? root.islandState.expanded === true : false

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
    // byClick: an indicator circle is a click-opened island — ESC dismisses it,
    // the body may take the keyboard, and hover is locked out until it closes.
    root.islandState.setContext(contextId, true)
  }

  readonly property var bt: root.statusSource ? root.statusSource.btState : null
  readonly property bool meterPlaying:
    root.statusSource ? root.statusSource.meterState.playing === true : false

  width: row.implicitWidth
  height: row.implicitHeight
  visible: root.circlesVisible

  // Hidden while the island is open: opacity and scale animate together, and
  // the disabled root refuses clicks, so the faded-out run cannot be tapped
  // blind. scale leaves the layout untouched (the transform origin stays the
  // item centre, the default).
  enabled: !root.islandOpen
  opacity: root.islandOpen ? 0 : 1
  scale: root.islandOpen ? 0 : 1
  Behavior on opacity { NumberAnimation { duration: root.motionDuration; easing.type: Easing.OutCubic } }
  Behavior on scale { NumberAnimation { duration: root.motionDuration; easing.type: Easing.OutCubic } }

  Row {
    id: row
    spacing: Style.space(8)

    // Battery -> power. Dims when no pack is present, but stays clickable.
    PillStatusDial {
      role: "power"
      diameter: root.diameter
      value: root.statusSource ? root.statusSource.batteryFraction : 0
      available: root.statusSource ? root.statusSource.batteryPresent : false
      glyph: root.statusSource && root.statusSource.batteryPresent
        ? root.statusSource.batteryGlyph : "󰂑"
      onClicked: function(role) { root.activate(role) }
    }

    // Wi-Fi -> network. Dims when no link is up.
    PillStatusDial {
      role: "network"
      diameter: root.diameter
      value: root.statusSource ? root.statusSource.wifiFraction : 0
      available: root.statusSource ? root.statusSource.wifiKind !== "disconnected" : false
      glyph: root.statusSource ? root.statusSource.wifiGlyph : ""
      onClicked: function(role) { root.activate(role) }
    }

    // Bluetooth -> bluetooth. Dims when the radio is absent or off.
    PillStatusDial {
      role: "bluetooth"
      diameter: root.diameter
      value: root.bt ? root.bt.fraction : 0
      available: root.bt ? root.bt.available : false
      glyph: root.bt ? root.bt.glyph : "󰂲"
      onClicked: function(role) { root.activate(role) }
    }

    // Music meter -> media. Absent while nothing plays (D4): the Row skips an
    // invisible child, so the dial simply leaves the run.
    PillStatusDial {
      role: "media"
      diameter: root.diameter
      visible: root.meterPlaying
      value: root.statusSource ? root.statusSource.meterState.level : 0
      available: true
      glyph: "󰎆"
      onClicked: function(role) { root.activate(role) }
    }
  }
}
