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

  implicitWidth: diameter
  implicitHeight: diameter

  readonly property real arcRadius: Math.max(1, (diameter - arcWidth) / 2)
  readonly property bool showValue: root.available && root.value > 0.001

  Shape {
    anchors.fill: parent
    antialiasing: true
    // Track.
    ShapePath {
      strokeWidth: root.arcWidth
      strokeColor: Util.alpha(Color.bar.text, root.available ? 0.18 : 0.10)
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
      color: Util.alpha(Color.bar.text, root.available ? 0.92 : 0.45)
      font.family: Style.font.family
      font.pixelSize: Math.round(root.diameter * 0.52)
    }

    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      visible: root.label !== ""
      text: root.label
      color: Util.alpha(Color.bar.text, 0.70)
      font.family: Style.font.family
      font.pixelSize: Math.max(8, Math.round(root.diameter * 0.26))
    }
  }
}
