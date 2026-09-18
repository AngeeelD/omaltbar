import QtQuick
import QtQuick.Shapes
import qs.Commons

// One circular status badge for the pill's right-click template: a track ring,
// a value arc and a centered glyph (with an optional sub-label for readouts
// like the battery percentage). Kept deliberately compact so it reads at pill
// scale; only the arc sweep, the glyph and the opacity ever animate — never the
// layout.
Item {
  id: root

  // 0..1 ring fill.
  property real value: 0
  // False dims the badge (radio off / no battery) without hiding it.
  property bool available: true
  property string glyph: ""
  // Optional readout under the glyph (e.g. "87%"). Empty hides it.
  property string label: ""
  // Debug-only vertical nudge for the centred content, in logical px
  // (positive = down). 0 is production; the dial stays opt-in via the caller
  // so a single ring can be tuned without moving the other.
  property int nudgeY: 0
  property color accent: Color.accent
  property int diameter: Style.font.title + Style.space(10)
  property int arcWidth: Math.max(2, Math.round(diameter / 12))
  // Stable click identifier (e.g. "power", "network"), never a context id: the
  // caller decides what a role opens, the dial only reports the click.
  property string role: ""

  // Emitted on a tap with the dial's own role, so one component serves every
  // indicator circle without knowing which context it opens.
  signal clicked(string role)

  implicitWidth: diameter
  implicitHeight: diameter

  readonly property real arcRadius: Math.max(1, (diameter - arcWidth) / 2)
  readonly property bool showValue: root.available && root.value > 0.001

  // The bubble: the pill's own surface colour, so a circle reads as a small
  // pill parked beside the island rather than as a bare ring floating on the
  // strip. It also gives the accent glyph the contrast it needs.
  Rectangle {
    anchors.fill: parent
    radius: width / 2
    color: Color.bar.background
    border.width: Math.max(1, Math.round(root.diameter / 22))
    border.color: Util.alpha(Color.bar.text, root.available ? 0.22 : 0.12)
  }

  Shape {
    anchors.fill: parent
    antialiasing: true
    // Track.
    ShapePath {
      strokeWidth: root.arcWidth
      strokeColor: Util.alpha(Color.bar.text, root.available ? 0.30 : 0.16)
      fillColor: "transparent"
      capStyle: ShapePath.RoundCap
      PathAngleArc {
        centerX: root.width / 2
        centerY: root.height / 2
        radiusX: root.arcRadius
        radiusY: root.arcRadius
        startAngle: -90
        sweepAngle: 360
      }
    }
    // Value.
    ShapePath {
      strokeWidth: root.arcWidth
      strokeColor: root.showValue ? root.accent : "transparent"
      fillColor: "transparent"
      capStyle: ShapePath.RoundCap
      PathAngleArc {
        centerX: root.width / 2
        centerY: root.height / 2
        radiusX: root.arcRadius
        radiusY: root.arcRadius
        startAngle: -90
        sweepAngle: 360 * Math.max(0, Math.min(1, root.value))
      }
    }
  }

  Column {
    anchors.centerIn: parent
    anchors.verticalCenterOffset: root.nudgeY
    spacing: -Math.round(root.diameter * 0.04)

    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      text: root.glyph
      color: Util.alpha(root.accent, root.available ? 1.0 : 0.45)
      font.family: Style.font.family
      font.pixelSize: Math.round(root.diameter * 0.52)
    }

    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      visible: root.label !== ""
      text: root.label
      color: Util.alpha(root.accent, 0.70)
      font.family: Style.font.family
      font.pixelSize: Math.max(8, Math.round(root.diameter * 0.26))
    }
  }

  // Click-only: the circles react to taps, never to hover — the dwell policy
  // belongs to island-hover-dwell. TapHandler is not a hover handler, so it
  // needs no `hoverEnabled` opt-out (it has no such property).
  TapHandler {
    acceptedButtons: Qt.LeftButton
    onTapped: root.clicked(root.role)
  }
}
