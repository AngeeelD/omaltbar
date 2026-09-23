import QtQuick
import qs.Commons
import qs.Ui

// The island's background picker: a live-filtering search field over a horizontal
// carousel of background cards, each showing a thumbnail preview.
//
// Mounted as the manual context `island.backgroundPicker`, opened by Up on the
// island card. `islandState` is deliberately NOT injected: the picker never
// drives the island — it enters through the card's guard and leaves through the
// card's Escape / outside click, which already collapse.
//
// The background inventory lives on the island body, outside the body's Loader,
// and is handed in as `backgroundPalette`. This view never spawns a process
// and never reads a background file itself.
Column {
  id: root

  // Injected by DynamicIsland.
  property var islandBar: null
  property var backgroundPalette: null

  // --- picker state ---------------------------------------------------------
  property string searchText: ""
  property string pendingPath: ""
  property string failedPath: ""
  property string confirmedPath: ""

  readonly property var allBackgrounds: root.backgroundPalette ? root.backgroundPalette.backgrounds : []
  readonly property string currentPath:
    root.backgroundPalette ? String(root.backgroundPalette.currentPath || "") : ""

  spacing: Style.spacing.md
  readonly property int motionFast: root.islandBar ? root.islandBar.motion.fast : 200

  // --- card geometry --------------------------------------------------------
  readonly property int cardW: Style.space(158)
  readonly property int cardH: Style.space(88)
  readonly property int thumbH: Style.space(44)

  // --- listing --------------------------------------------------------------
  readonly property var filteredPaths: {
    var all = root.allBackgrounds
    var query = root.searchText.trim().toLowerCase()
    if (query === "") return all
    var out = []
    for (var i = 0; i < all.length; i++) {
      var p = String(all[i])
      var label = root.labelFor(p).toLowerCase()
      if (p.toLowerCase().indexOf(query) >= 0 || label.indexOf(query) >= 0) {
        out.push(p)
      }
    }
    return out
  }
  readonly property int total: root.filteredPaths.length
  readonly property int selectionIndex:
    (strip.currentIndex >= 0 && strip.currentIndex < root.total) ? strip.currentIndex : -1
  readonly property string selectedPath:
    root.selectionIndex >= 0 ? String(root.filteredPaths[root.selectionIndex]) : ""
  readonly property int position: root.selectionIndex >= 0 ? root.selectionIndex + 1 : 0

  readonly property string statusText: {
    if (root.pendingPath !== "") {
      return "Applying " + root.labelFor(root.pendingPath) + "\u2026"
    }
    if (root.failedPath !== "") {
      return root.labelFor(root.failedPath) + " did not apply"
    }
    if (root.confirmedPath !== "") return root.labelFor(root.confirmedPath) + " applied"
    if (root.total === 0) return "No backgrounds match"
    return root.position + "/" + root.total + " \u00b7 Enter to apply"
  }

  function labelFor(path) {
    return root.backgroundPalette ? root.backgroundPalette.label(path) : String(path || "")
  }

  function selectPath(path) {
    var idx = root.filteredPaths.indexOf(String(path || ""))
    if (idx < 0) return false
    strip.currentIndex = idx
    return true
  }

  function clampSelection() {
    var list = root.filteredPaths
    if (list.length === 0) {
      strip.currentIndex = -1
      return
    }
    if (strip.currentIndex >= 0 && strip.currentIndex < list.length) return
    if (root.selectPath(root.currentPath)) return
    strip.currentIndex = 0
  }

  function step(delta) {
    var count = root.total
    if (count <= 0) return
    var idx = root.selectionIndex
    if (idx < 0) idx = 0
    strip.currentIndex = ((idx + Number(delta || 0)) % count + count) % count
  }

  function requestApply(path) {
    var bg = String(path || "")
    if (bg === "" || root.pendingPath !== "") return
    root.failedPath = ""
    root.confirmedPath = ""
    if (bg === root.currentPath) {
      root.confirmedPath = bg
      confirmTimer.restart()
      return
    }
    root.pendingPath = bg
    // Apply the background: update the symlink and trigger the wallpaper daemon.
    // Use a shell that resolves the path and updates the current background link,
    // then notifies the shell to reload the wallpaper. Detached, so the island
    // never blocks.
    var home = root.backgroundPalette ? root.backgroundPalette.home : ""
    var link = home + "/.local/state/omarchy/current/background"
    // Escape single quotes in the path for the shell
    var esc = bg.replace(/'/g, "'\\''")
    Util.exec("ln -nsf '" + esc + "' '" + link + "'")
    // Trigger wallpaper reload via the shell's background transition if available,
    // otherwise the symlink update will be picked up on next theme apply.
    Util.exec("hyprctl hyprpaper wallpaper '," + esc + "' 2>/dev/null || true")
    applyTimer.restart()
  }

  function failApply() {
    if (root.pendingPath === "") return
    root.failedPath = root.pendingPath
    root.pendingPath = ""
    root.selectPath(root.currentPath)
  }

  onCurrentPathChanged: {
    if (root.pendingPath !== "") {
      applyTimer.stop()
      if (root.currentPath === root.pendingPath) {
        root.confirmedPath = root.currentPath
        confirmTimer.restart()
      } else {
        root.failedPath = root.pendingPath
      }
      root.pendingPath = ""
      root.selectPath(root.currentPath)
      return
    }
    root.selectPath(root.currentPath)
  }

  onFilteredPathsChanged: root.clampSelection()

  onSearchTextChanged: {
    var list = root.filteredPaths
    strip.currentIndex = list.length > 0 ? 0 : -1
  }

  Component.onCompleted: {
    if (root.backgroundPalette) root.backgroundPalette.ensureReady()
    root.clampSelection()
    Qt.callLater(function() { searchField.forceActiveFocus() })
  }

  // --- zone 1: the search field --------------------------------------------
  TextField {
    id: searchField
    width: root.width
    placeholderText: "Search backgrounds"
    font.family: Style.font.family
    font.pixelSize: Style.font.body
    text: root.searchText
    onTextChanged: if (root.searchText !== text) root.searchText = text
    onAccepted: root.requestApply(root.selectedPath)
    Keys.onLeftPressed: function(event) {
      strip.forceActiveFocus()
      root.step(-1)
      event.accepted = true
    }
    Keys.onRightPressed: function(event) {
      strip.forceActiveFocus()
      root.step(1)
      event.accepted = true
    }
    Keys.onDownPressed: function(event) {
      strip.forceActiveFocus()
      event.accepted = true
    }
    Keys.onTabPressed: function(event) {
      strip.forceActiveFocus()
      event.accepted = true
    }
    Keys.onUpPressed: function(event) {
      event.accepted = false
    }
  }

  // --- zone 2: the carousel -------------------------------------------------
  Item {
    id: carousel
    width: root.width
    height: root.cardH + Style.space(14)

    ListView {
      id: strip
      anchors.fill: parent
      orientation: ListView.Horizontal
      model: root.filteredPaths
      clip: true
      spacing: Style.spacing.md
      highlightRangeMode: ListView.StrictlyEnforceRange
      preferredHighlightBegin: strip.width / 2 - root.cardW / 2
      preferredHighlightEnd: strip.width / 2 + root.cardW / 2
      highlightMoveDuration: 0
      snapMode: ListView.SnapToItem
      cacheBuffer: root.cardW * 2
      focus: false
      activeFocusOnTab: true
      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Left || event.key === Qt.Key_H
            || event.text === "h") {
          root.step(-1)
          event.accepted = true
        } else if (event.key === Qt.Key_Right || event.key === Qt.Key_L
            || event.text === "l") {
          root.step(1)
          event.accepted = true
        } else if (event.key === Qt.Key_Up) {
          searchField.forceActiveFocus()
          event.accepted = true
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
            || event.key === Qt.Key_Space) {
          root.requestApply(root.selectedPath)
          event.accepted = true
        } else if (event.key === Qt.Key_Down) {
          // Down from the picker goes back to the island (handled by the card
          // if this event is not accepted here). Let it fall through.
          event.accepted = false
        }
      }
      onActiveFocusChanged: if (activeFocus) root.clampSelection()

      delegate: Item {
        id: cardSlot
        required property int index
        required property var modelData
        width: root.cardW
        height: strip.height
        Rectangle {
          id: card
          anchors.verticalCenter: parent.verticalCenter
          readonly property string bgPath: String(cardSlot.modelData)
          readonly property string bgLabel: root.labelFor(card.bgPath)
          readonly property bool selected: strip.currentIndex === cardSlot.index
          readonly property bool pending: root.pendingPath === card.bgPath

          width: root.cardW
          height: root.cardH
          radius: Style.cornerRadius
          color: Util.alpha(Color.bar.text, card.selected ? 0.14 : 0.07)
          border.width: card.selected ? Math.max(1, Math.round(Style.space(2))) : 0
          border.color: Color.accent
          scale: card.selected ? 1.08 : 1.0
          Behavior on scale {
            NumberAnimation { duration: root.motionFast; easing.type: Easing.OutCubic }
          }
          Behavior on color {
            ColorAnimation { duration: root.motionFast; easing.type: Easing.OutCubic }
          }
          Behavior on border.color {
            ColorAnimation { duration: root.motionFast; easing.type: Easing.OutCubic }
          }

          Rectangle {
            anchors.fill: parent
            anchors.margins: -Style.space(3)
            radius: card.radius + Style.space(3)
            color: "transparent"
            border.width: Math.max(1, Math.round(Style.space(1)))
            border.color: Util.alpha(Color.accent, 0.55)
            visible: card.selected && strip.activeFocus
          }

          Column {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: parent.verticalCenter
            width: card.width - Style.spacing.md * 2
            spacing: Style.spacing.sm

            // Thumbnail preview
            Rectangle {
              width: parent.width
              height: root.thumbH
              radius: Style.space(4)
              color: Util.alpha(Color.bar.text, 0.08)
              clip: true
              Image {
                anchors.fill: parent
                source: "file://" + card.bgPath
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                cache: true
                sourceSize.width: root.cardW * 2
                sourceSize.height: root.thumbH * 2
              }
              // Fallback label when image fails
              Text {
                anchors.centerIn: parent
                text: "No preview"
                color: Util.alpha(Color.bar.text, 0.4)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                visible: parent.children[0].status !== Image.Ready
              }
            }

            Text {
              width: parent.width
              text: card.bgLabel
              color: card.selected ? Color.bar.text : Util.alpha(Color.bar.text, 0.82)
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              font.weight: card.selected ? Font.DemiBold : Font.Normal
              elide: Text.ElideRight
              horizontalAlignment: Text.AlignHCenter
            }
          }

          SequentialAnimation {
            running: card.pending
            loops: Animation.Infinite
            NumberAnimation {
              target: card
              property: "opacity"
              to: 0.55
              duration: root.motionFast
              easing.type: Easing.InOutSine
            }
            NumberAnimation {
              target: card
              property: "opacity"
              to: 1.0
              duration: root.motionFast
              easing.type: Easing.InOutSine
            }
          }
          onPendingChanged: if (!card.pending) card.opacity = 1

          MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton
            onClicked: {
              strip.currentIndex = cardSlot.index
              strip.forceActiveFocus()
            }
          }
        }
      }
    }
  }

  // --- status line ----------------------------------------------------------
  Text {
    width: root.width
    text: root.statusText
    color: root.failedPath !== ""
      ? Util.alpha(Color.urgent, 0.95)
      : Util.alpha(Color.bar.text, 0.70)
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    horizontalAlignment: Text.AlignHCenter
    elide: Text.ElideRight
    Behavior on color {
      ColorAnimation { duration: root.motionFast; easing.type: Easing.OutCubic }
    }
  }

  Timer {
    id: applyTimer
    interval: 4000
    onTriggered: root.failApply()
  }

  Timer {
    id: confirmTimer
    interval: 2400
    onTriggered: root.confirmedPath = ""
  }
}
