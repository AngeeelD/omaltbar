import QtQuick
import qs.Commons

// The app spheres beside the pill: one circle per app with a window on this
// screen, alphabetical so positions are stable, horizontally scrollable when
// they overflow.
//
// Like the indicator row it is a STATIC sibling of the notch body, anchored to
// the strip rather than to the animated wing, and it is click-only: the wheel
// scrolls the run and is accepted so it never reaches the island's
// collapse/peek policy; there is no hover handler anywhere.
Item {
  id: root

  // The owning island unit's WindowSource (grouped, screen-filtered).
  property var windowSource: null
  // IslandState of the owning unit: a sphere opens the window-list context.
  property var islandState: null
  // Widest run the spheres may occupy before the Flickable starts scrolling.
  property int maxWidth: 320

  readonly property var groups: root.windowSource ? root.windowSource.appGroups : []
  readonly property int sphereSize: Style.font.title + Style.space(10)
  readonly property string selectedAppId:
    root.windowSource ? String(root.windowSource.selectedAppId || "") : ""

  // A sphere click selects the app and opens the one context that renders its
  // windows. Selection is kept on the source so the view and the row agree.
  function openWindows(appId) {
    var id = String(appId || "")
    if (id === "" || !root.windowSource || !root.islandState) return
    root.windowSource.selectedAppId = id
    root.islandState.setContext("island.windowList")
  }

  width: Math.min(flick.contentWidth, root.maxWidth)
  height: root.sphereSize

  Flickable {
    id: flick
    anchors.fill: parent
    contentWidth: row.implicitWidth
    contentHeight: height
    boundsBehavior: Flickable.StopAtBounds
    clip: true
    interactive: contentWidth > width

    Row {
      id: row
      spacing: Style.space(8)

      Repeater {
        model: root.groups

        delegate: Item {
          id: sphere
          required property var modelData

          width: root.sphereSize
          height: root.sphereSize

          readonly property bool selected: root.selectedAppId !== ""
            && String(modelData.appId) === root.selectedAppId
          readonly property string iconSource: String(modelData.icon || "")

          Rectangle {
            anchors.fill: parent
            radius: width / 2
            // The pill's own surface, like the indicator circles: a solid bubble
            // instead of the 10%-alpha wash that was nearly invisible over a
            // wallpaper, and the selected app is marked by an accent rim.
            color: Color.bar.background
            border.width: Math.max(1, Math.round(root.sphereSize / 16))
            border.color: sphere.selected
              ? Color.accent
              : Util.alpha(Color.bar.text, 0.28)

            Image {
              anchors.centerIn: parent
              width: Math.round(parent.width * 0.58)
              height: width
              source: sphere.iconSource
              sourceSize.width: Math.round(parent.width * 2)
              sourceSize.height: Math.round(parent.width * 2)
              fillMode: Image.PreserveAspectFit
              asynchronous: true
              smooth: true
              visible: source !== ""
            }

            // Fallback for an app whose icon never resolved: the same generic
            // executable glyph the notification views use, in the accent colour
            // like the indicator circles.
            Text {
              anchors.centerIn: parent
              visible: sphere.iconSource === ""
              text: "󰈔"
              color: Util.alpha(Color.accent, 0.90)
              font.family: Style.font.family
              font.pixelSize: Math.round(root.sphereSize * 0.5)
            }
          }

          TapHandler {
            acceptedButtons: Qt.LeftButton
            onTapped: root.openWindows(modelData.appId)
          }
        }
      }
    }

    // Horizontal overflow: the vertical wheel moves the run sideways. The
    // event is accepted, so it never bubbles into the island's hover/peek
    // policy, and nothing here ever calls setStripHovered.
    WheelHandler {
      onWheel: function(event) {
        var maxX = Math.max(0, flick.contentWidth - flick.width)
        flick.contentX = Math.max(0, Math.min(maxX, flick.contentX - event.angleDelta.y))
        event.accepted = true
      }
    }
  }
}
