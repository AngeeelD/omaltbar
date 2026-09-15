import QtQuick
import qs.Commons

// The simulated notch: the dark rounded body centered under the screen's top
// edge in the collapsed pill. Pure visuals — interaction lives in the island
// unit so the expand/collapse policy stays in one place.
//
// A macOS notch is square where it meets the screen edge and only rounds on
// its bottom corners. A Rectangle rounds all four corners, so a square cover
// of the same color hides the top corner arcs back to the screen edge.
Item {
  id: root

  property int pillW: 220
  property int pillH: 34
  // Width of the hardware camera cutout, centered inside the pill. The pill is
  // pillW wide and the cutout is the physically invisible band in its middle;
  // the lateral strip on each side ((pillW - cutoutW) / 2) is the visible wing
  // that carries the clock and the mini-player. A default >= pillW means "no
  // cutout": the whole pill is one continuous surface.
  property int cutoutW: pillW
  readonly property int sideSlot: Math.max(0, Math.round((pillW - cutoutW) / 2))
  // Informational host identity (the unit still passes it). It must NOT gate
  // painting: on notched Apple panels the compositor renders the wallpaper
  // into the cutout strip (grim-proven), so a transparent body leaves the
  // island invisible, and the pill extends below/beside the cutout anyway.
  // The cutout rows themselves carry no pixels, so painting there is a no-op.
  property bool appleSiliconHost: false
  // bar.transparent — keep the notch legible but see-through.
  property bool transparent: false
  // Alpha of the transparent surface, owned by the bar (bar.islandOpacity).
  // Ignored entirely while `transparent` is off.
  property real surfaceOpacity: 0.72

  width: pillW
  height: pillH
  clip: false
  z: 2

  // How far the visible pill extends beyond the hardware cutout: 1 = full
  // resting pill, 0 = hidden under the cutout (the island body has taken
  // over). The ITEM keeps its full pillW so the island's pointer zones and the
  // hover that keeps a reveal open never lose their target while the visible
  // surface animates; only the painted rectangles collapse.
  property real collapse: 1.0
  property int collapseDuration: 340
  property real collapseOvershoot: 1.35
  // Smallest width the surface may collapse to. The caller passes the "dot"
  // width (maximum collapse) so the surface can shrink PAST the physical
  // cutout band: a flat host has no band, and even a notched host wants a
  // small circular badge there rather than the whole cutout width.
  property int minWidth: cutoutW
  readonly property real visualW: minWidth + Math.max(0, pillW - minWidth) * collapse
  Behavior on collapse {
    NumberAnimation {
      duration: root.collapseDuration
      easing.type: Easing.OutBack
      easing.overshoot: root.collapseOvershoot
    }
  }

  // Rounded body by default; as the surface shrinks toward the dot it rounds
  // all the way into a circle, so the maximum collapse reads as a badge.
  readonly property real dotBlend: Math.max(0, Math.min(1, (height * 2 - visualW) / height))
  readonly property int cornerRadius: Math.round(
    Math.max(Style.spacing.sm, Math.round(height / 3)) * (1 - dotBlend)
    + (visualW / 2) * dotBlend)
  readonly property color surfaceColor: root.transparent
    ? Util.alpha(Color.bar.background, root.surfaceOpacity)
    : Color.bar.background

  Rectangle {
    id: pillSurface
    x: Math.round((parent.width - root.visualW) / 2)
    width: Math.round(root.visualW)
    height: parent.height
    radius: root.cornerRadius
    color: root.surfaceColor
  }

  // Square top edge: repaint the band from the screen edge down to where the
  // corner arcs begin, spanning the visible width between them. Always painted
  // (see appleSiliconHost above: no compositor-side masking to hide behind).
  Rectangle {
    x: pillSurface.x + root.cornerRadius
    width: Math.max(0, pillSurface.width - root.cornerRadius * 2)
    y: 0
    height: root.cornerRadius
    color: root.surfaceColor
  }
}
