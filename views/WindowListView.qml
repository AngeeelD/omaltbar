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

  implicitWidth: column.implicitWidth
  implicitHeight: column.implicitHeight

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

  // The focus command must outlive this view: collapse() clears
  // DynamicIsland.activeComponent, which destroys the view and any Timer
  // declared inside it. So the ~0.2 s delay that lets the layer surface unmap
  // before the compositor takes focus is owned by a detached process — the
  // proven expose `activate-window` shape — spawned before the collapse. An
  // invalid or empty address aborts the whole action: no command is executed.
  function focusWindow(toplevel) {
    if (!root.windowSource) return
    var address = root.windowSource.addressFor(toplevel)
    if (address === "") return
    Quickshell.execDetached([
      "sh", "-c",
      "sleep 0.2; hyprctl eval \"hl.dispatch(hl.dsp.focus({ window = 'address:" + address + "' }))\""
    ])
    if (root.islandState) root.islandState.collapse()
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

    // Horizontal card run. The island card is wide but not unbounded, so a
    // long list scrolls sideways instead of growing vertically.
    Flickable {
      visible: root.windows.length > 0
      width: root.width
      height: root.cardHeight
      contentWidth: cardRow.implicitWidth
      contentHeight: height
      boundsBehavior: Flickable.StopAtBounds
      clip: true
      interactive: contentWidth > width

      Row {
        id: cardRow
        spacing: Style.space(10)

        Repeater {
          model: root.windows

          delegate: Item {
            id: card
            required property var modelData

            width: root.cardWidth
            height: root.cardHeight

            readonly property string title: root.windowTitle(card.modelData)
            readonly property string workspace: root.windowWorkspace(card.modelData)
            readonly property string icon: root.windowIcon(card.modelData)

            Rectangle {
              anchors.fill: parent
              radius: Style.cornerRadius
              color: Util.alpha(Color.bar.text, 0.06)
              border.width: 1
              border.color: Util.alpha(Color.bar.text, 0.20)
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

            // Click-only, like every other surface this feature adds: a raw
            // click (no hover) focuses the window in its own workspace.
            TapHandler {
              acceptedButtons: Qt.LeftButton
              onTapped: root.focusWindow(card.modelData)
            }
          }
        }
      }
    }
  }
}
