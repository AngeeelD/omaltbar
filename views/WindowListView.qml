import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons

// Native island view for "island.windowList": the windows of the app chosen on
// the spheres, rendered as cards with live previews and click-to-focus.
//
// Previews are live ScreencopyView captures gated on visibility — the island
// pays for a screencopy session only while this view is the thing on screen
// (the expose pattern) — and every card keeps its icon and title even when a
// capture never delivers content, so the list stays usable without previews.
Item {
  id: root

  // Injected by DynamicIsland, like every other native view.
  property var islandState: null
  property var islandBar: null
  // The owning unit's WindowSource: selectedAppId names the app to list.
  property var windowSource: null

  readonly property color foreground: islandBar ? islandBar.foreground : Color.foreground
  readonly property string fontFamily: islandBar ? islandBar.fontFamily : Style.font.family

  readonly property var windows: root.windowSource ? root.windowSource.selectedWindows : []
  readonly property var group: root.windowSource ? root.windowSource.selectedAppGroup : null
  readonly property string appName: root.group && root.group.name ? String(root.group.name) : ""
  readonly property string appIcon: root.group && root.group.icon ? String(root.group.icon) : ""

  // Live capture is only paid for while this context is the one on screen.
  readonly property bool viewActive:
    root.islandState ? root.islandState.isActive("island.windowList") : false
  readonly property bool inLayout: root.visible && root.width > 0 && root.height > 0
  readonly property bool live: root.viewActive && root.inLayout

  readonly property int cardWidth: Math.round(Style.space(180))
  readonly property int cardHeight: Math.round(Style.space(126))
  readonly property int titleBar: Math.round(Style.space(34))

  // Keyboard selection over the listed instances. The badge number is
  // `index + 1`, and Left/Right move this; a digit key focuses that instance
  // directly. Clamped to the list (see onWindowsChanged), never negative.
  //
  // The key handlers themselves live on the island card (DynamicIsland), which
  // is the surface's proven focus host with the existing Escape handler; this
  // view only exposes the operations and stays a dumb painter.
  property int selectedIndex: 0

  implicitWidth: column.implicitWidth
  implicitHeight: column.implicitHeight

  // Keep the selection inside the list when a window closes under the user.
  onWindowsChanged: {
    if (root.selectedIndex >= root.windows.length) root.selectedIndex = 0
  }

  function windowTitle(toplevel) {
    var title = String((toplevel && toplevel.title) || "")
    return title !== "" ? title : "Untitled window"
  }

  function windowWorkspace(toplevel) {
    var workspace = toplevel ? toplevel.workspace : null
    if (!workspace) return ""
    return String(workspace.name || workspace.id || "")
  }

  function windowIcon(toplevel) {
    if (!root.windowSource) return ""
    return root.windowSource.iconFor(root.windowSource.appIdFor(toplevel))
  }

  // Move the keyboard selection by `delta`, clamped to the list. The Flickable
  // then scrolls the selected card into view.
  function moveSelection(delta) {
    var count = root.windows.length
    if (count === 0) return
    var next = root.selectedIndex + delta
    if (next < 0) next = 0
    if (next > count - 1) next = count - 1
    root.selectedIndex = next
    cardRun.ensureVisible(next)
  }

  // Focus the window through the ONE shared implementation on WindowSource,
  // then collapse. focusToplevel aborts on an invalid/empty address (no command
  // is executed), in which case the island deliberately stays open.
  function focusWindow(toplevel) {
    if (!root.windowSource) return
    if (!root.windowSource.focusToplevel(toplevel)) return
    if (root.islandState) root.islandState.collapse()
  }

  // Digits focus the matching badge (1..9; a badge beyond 9 has no single key).
  // Left/Right move the selection. Called by the island card's key handlers,
  // which are only armed while this view is the active context.
  function handleDigit(digit) {
    var index = Number(digit) - 1
    if (!isFinite(index) || index < 0 || index >= root.windows.length) return
    root.focusWindow(root.windows[index])
  }

  Column {
    id: column
    width: root.width
    spacing: Style.space(8)

    // Header: which app these windows belong to, and how many.
    Row {
      spacing: Style.space(8)

      Image {
        anchors.verticalCenter: parent.verticalCenter
        width: Math.round(Style.space(18))
        height: width
        source: root.appIcon
        fillMode: Image.PreserveAspectFit
        asynchronous: true
        smooth: true
        visible: source !== ""
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: root.appName !== "" ? root.appName : "Windows"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: root.windows.length === 1 ? "1 window" : root.windows.length + " windows"
        color: root.foreground
        opacity: 0.6
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
    }

    Text {
      visible: root.windows.length === 0
      text: "No windows"
      color: root.foreground
      opacity: 0.6
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    // Horizontal card run, CENTERED while it fits the island and left-aligned
    // (scrollable) once it overflows. The Row's `x` is the centering offset
    // inside the Flickable's contentItem; a long run gets offset 0 so the
    // Flickable's own contentX scrolling behaves exactly as before.
    Flickable {
      id: cardRun
      visible: root.windows.length > 0
      width: root.width
      height: root.cardHeight
      contentWidth: cardRow.implicitWidth
      contentHeight: height
      boundsBehavior: Flickable.StopAtBounds
      clip: true
      interactive: contentWidth > width

      // Scroll the selected card into view (keyboard navigation). The Row may
      // carry a centering offset, so the card's content coordinate includes it.
      function ensureVisible(index) {
        var itemX = cardRow.x + index * (root.cardWidth + cardRow.spacing)
        var itemRight = itemX + root.cardWidth
        if (itemX < contentX) contentX = itemX
        else if (itemRight > contentX + width) contentX = itemRight - width
      }

      Row {
        id: cardRow
        spacing: Style.space(10)
        x: Math.max(0, (cardRun.width - cardRow.implicitWidth) / 2)

        Repeater {
          model: root.windows

          delegate: Item {
            id: card
            required property var modelData
            required property int index

            width: root.cardWidth
            height: root.cardHeight

            readonly property string title: root.windowTitle(card.modelData)
            readonly property string workspace: root.windowWorkspace(card.modelData)
            readonly property string icon: root.windowIcon(card.modelData)
            readonly property bool selected: card.index === root.selectedIndex

            Rectangle {
              anchors.fill: parent
              radius: Style.cornerRadius
              color: Util.alpha(Color.bar.text, 0.06)
              border.width: card.selected ? Math.max(2, Style.space(2)) : 1
              border.color: card.selected
                ? Color.accent
                : Util.alpha(Color.bar.text, 0.20)
              clip: true

              Item {
                id: previewArea
                anchors {
                  top: parent.top
                  left: parent.left
                  right: parent.right
                  margins: 1
                }
                height: Math.max(1, root.cardHeight - root.titleBar)

                ScreencopyView {
                  id: preview
                  anchors.centerIn: parent
                  captureSource: card.modelData ? card.modelData.wayland : null
                  live: root.live
                  paintCursor: false
                  visible: hasContent
                  width: {
                    if (!hasContent || sourceSize.width <= 0 || sourceSize.height <= 0)
                      return parent.width
                    return Math.min(parent.width, parent.height * sourceSize.width / sourceSize.height)
                  }
                  height: {
                    if (!hasContent || sourceSize.width <= 0 || sourceSize.height <= 0)
                      return parent.height
                    return Math.min(parent.height, parent.width * sourceSize.height / sourceSize.width)
                  }
                }

                // A capture that never arrives leaves the card honest: the
                // icon and title below still identify the window.
                Text {
                  anchors.centerIn: parent
                  visible: !preview.hasContent
                  text: "Preview unavailable"
                  color: root.foreground
                  opacity: 0.5
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
              }

              Row {
                id: titleRow
                anchors {
                  left: parent.left
                  right: parent.right
                  bottom: parent.bottom
                  leftMargin: Style.space(8)
                  rightMargin: Style.space(8)
                  bottomMargin: Style.space(6)
                }
                spacing: Style.space(6)

                Image {
                  id: cardIcon
                  anchors.verticalCenter: parent.verticalCenter
                  visible: card.icon !== ""
                  width: visible ? Math.round(Style.space(14)) : 0
                  height: Math.round(Style.space(14))
                  source: card.icon
                  fillMode: Image.PreserveAspectFit
                  asynchronous: true
                  smooth: true
                }

                Text {
                  id: titleText
                  anchors.verticalCenter: parent.verticalCenter
                  width: Math.max(1, titleRow.width - cardIcon.width
                    - (workspaceText.visible ? workspaceText.width + titleRow.spacing : 0)
                    - (cardIcon.visible ? titleRow.spacing : 0))
                  text: card.title
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                  maximumLineCount: 1
                }

                Text {
                  id: workspaceText
                  anchors.verticalCenter: parent.verticalCenter
                  visible: card.workspace !== ""
                  text: card.workspace !== "" ? "ws " + card.workspace : ""
                  color: root.foreground
                  opacity: 0.55
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
              }
            }

            // Floating number badge: the digit key that focuses this window,
            // drawn over the preview's top-left corner.
            Rectangle {
              id: numberBadge
              anchors {
                top: parent.top
                left: parent.left
                margins: Style.space(6)
              }
              width: Math.max(Style.space(18), badgeText.implicitWidth + Style.space(8))
              height: Math.round(Style.space(18))
              radius: height / 2
              color: card.selected ? Color.accent : Util.alpha(Color.bar.background, 0.85)
              border.width: 1
              border.color: card.selected ? "transparent" : Util.alpha(Color.bar.text, 0.35)
              z: 2

              Text {
                id: badgeText
                anchors.centerIn: parent
                text: String(card.index + 1)
                color: card.selected ? Color.bar.background : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: true
              }
            }

            // Click-only, like every other surface this feature adds: a raw
            // click (no hover) focuses the window in its own workspace. The
            // click also moves the keyboard selection onto that card.
            TapHandler {
              acceptedButtons: Qt.LeftButton
              onTapped: {
                root.selectedIndex = card.index
                root.focusWindow(card.modelData)
              }
            }
          }
        }
      }
    }
  }
}
