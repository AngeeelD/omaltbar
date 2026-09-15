import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Ui
import qs.Commons

// Notch Island — settings widget.
//
// A regular Omarchy `bar-widget`: a gear icon the user can place in any bar (the
// island pill grid or the stock `omarchy.bar`). Pressing it opens a keyboard
// panel built on the standard `qs.Ui.Panel` + `qs.Ui.KeyboardPanel` pattern, so
// it behaves exactly like the audio/bluetooth/clock panels: one popup at a time
// through the bar's popout coordinator, Escape and outside-click close, keyboard
// focus only while it is open.
//
// The root satisfies the panel-widget contract the shell routing depends on
// (`open()`, `close()`, `opened`) through the `Panel` base, and the host bar
// injects `bar`, `moduleName` and `settings` like any other widget. The panel
// content (SettingsPanel.qml) reads `bar.barConfig` and writes through
// `bar.shell.mutateShellConfig`, the only config surfaces both bars expose — so
// the same widget works before and after a bar switch.
//
// The bar switch lives here rather than in the content: selecting the stock bar
// disables the plugin (a bar-kind plugin is "enabled" only while it is the
// selected bar), and most of the panel's height is slider, where a wheel gesture
// would otherwise be swallowed.
Panel {
  id: root

  moduleName: "local.notch-island"
  ipcTarget: "local.notch-island.settings"

  readonly property string restoreCommand: "omarchy bar use local.notch-island"

  // --- bar switch (confirmed before it disables the plugin) -----------------
  property bool confirmOpen: false
  property string pendingBarId: ""

  function requestBarSwitch(targetId) {
    var next = String(targetId || "")
    if (next === "omarchy.bar" || next === "" || next === "default") {
      // The stock bar leaves the plugin installed but disabled, and the settings
      // icon only works while the island is the active bar. Confirm that
      // direction and hand over the command that brings it back.
      root.pendingBarId = next
      root.confirmOpen = true
    } else {
      root.applyBarSwitch(next)
    }
  }

  function confirmBarSwitch() {
    var next = root.pendingBarId
    root.confirmOpen = false
    root.applyBarSwitch(next)
  }

  function cancelBarSwitch() {
    root.confirmOpen = false
    keyCatcher.forceActiveFocus()
  }

  // Close the panel first, then write: loading the other bar destroys this
  // widget, so the write must not run inside its own teardown.
  function applyBarSwitch(targetId) {
    var next = String(targetId || "")
    root.close()
    switchTimer.targetId = next
    switchTimer.restart()
  }

  Timer {
    id: switchTimer
    interval: 220
    repeat: false
    property string targetId: ""
    onTriggered: {
      var shell = root.bar ? root.bar.shell : null
      if (!shell || typeof shell.mutateShellConfig !== "function") return
      var next = switchTimer.targetId
      shell.mutateShellConfig(function(config) {
        if (!Util.isPlainObject(config.bar)) config.bar = {}
        if (next === "" || next === "omarchy.bar" || next === "default") delete config.bar.id
        else config.bar.id = next
      })
    }
  }

  function copyRestoreCommand() {
    Quickshell.execDetached(["bash", "-c", "printf %s " + Util.shellQuote(root.restoreCommand) + " | wl-copy"])
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // Drawn by iconComponent rather than a bare glyph: a miniature bar plate
    // with the gear on top, so the icon reads as "settings for the bar" instead
    // of a generic gear. BarIconButton renders the component in its optical
    // canvas and hides the text glyph when one is supplied.
    text: ""
    iconComponent: Component {
      Item {
        Rectangle {
          anchors.centerIn: parent
          width: Math.round(parent.width * 0.98)
          height: Math.max(5, Math.round(parent.height * 0.74))
          radius: height / 2
          color: button.foreground
          opacity: 0.34
        }
        Rectangle {
          anchors.centerIn: parent
          width: Math.round(parent.width * 0.98)
          height: Math.max(5, Math.round(parent.height * 0.74))
          radius: height / 2
          color: "transparent"
          border.width: 1
          border.color: button.foreground
          opacity: 0.6
        }
        Text {
          anchors.centerIn: parent
          text: "󰒓"
          color: button.foreground
          font.family: button.fontFamily
          font.pixelSize: Math.round(parent.height * 0.66)
        }
      }
    }
    onPressed: function(b) {
      root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(430))
    contentHeight: panel.fittedContentHeight(settingsContent.implicitHeight, Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // While a hotkey field or the confirmation owns the keyboard, let it
      // receive keys instead of the panel consuming Escape/Tab/arrows.
      blocked: settingsContent.editorActive || confirmOverlay.visible
      onCloseRequested: root.close()

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: settingsContent.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff

        SettingsPanel {
          id: settingsContent
          width: scrollArea.availableWidth
          bar: root.bar
          onRequestClose: root.close()
          onRequestBarSwitch: function(targetId) { root.requestBarSwitch(targetId) }
        }
      }

      // --- confirmation overlay ---------------------------------------------
      Item {
        id: confirmOverlay
        anchors.fill: parent
        z: 10
        visible: root.confirmOpen
        focus: root.confirmOpen
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            root.cancelBarSwitch()
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.confirmBarSwitch()
            event.accepted = true
          }
        }
        onVisibleChanged: if (visible) confirmOverlay.forceActiveFocus()

        Rectangle {
          anchors.fill: parent
          color: Util.alpha(Color.background, 0.72)
          MouseArea { anchors.fill: parent; onClicked: root.cancelBarSwitch() }
        }

        Rectangle {
          id: confirmCard
          anchors.centerIn: parent
          width: Math.min(parent.width - Style.space(24), Style.space(360))
          height: confirmColumn.implicitHeight + Style.space(28)
          radius: Style.cornerRadius
          color: Color.popups.background
          border.width: 1
          border.color: Util.alpha(Color.popups.border, 0.7)

          // Swallow clicks on the card so they do not dismiss the dialog.
          MouseArea { anchors.fill: parent }

          Column {
            id: confirmColumn
            x: Style.space(14)
            y: Style.space(14)
            width: parent.width - Style.space(28)
            spacing: Style.space(10)

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              text: "Switch to the stock bar?"
              color: Color.popups.text
              font.family: Style.font.family
              font.pixelSize: Style.font.title
              font.bold: true
            }

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              text: "Notch Island stays installed but reports as disabled while another bar is active, and its settings icon only works while the island is the bar. To restore it later, run:"
              color: Color.popups.text
              opacity: 0.75
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }

            Row {
              width: parent.width
              spacing: Style.space(8)

              Rectangle {
                width: parent.width - copyButton.width - Style.space(8)
                height: commandText.implicitHeight + Style.space(8)
                radius: Style.space(4)
                color: Util.alpha(Color.popups.text, 0.10)

                Text {
                  id: commandText
                  anchors.fill: parent
                  anchors.margins: Style.space(4)
                  text: root.restoreCommand
                  color: Color.popups.text
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideMiddle
                  verticalAlignment: Text.AlignVCenter
                }
              }

              PanelActionButton {
                id: copyButton
                iconText: "󰆏"
                tooltipText: "Copy command"
                foreground: Color.popups.text
                hasCursor: true
                onClicked: root.copyRestoreCommand()
              }
            }

            Row {
              width: parent.width
              spacing: Style.space(8)

              Button {
                width: (parent.width - Style.space(8)) / 2
                text: "Cancel"
                bordered: true
                foreground: Color.popups.text
                fontFamily: Style.font.family
                onClicked: root.cancelBarSwitch()
              }
              Button {
                width: (parent.width - Style.space(8)) / 2
                text: "Switch to stock bar"
                bordered: true
                foreground: Color.popups.text
                fontFamily: Style.font.family
                onClicked: root.confirmBarSwitch()
              }
            }
          }
        }
      }
    }
  }
}
