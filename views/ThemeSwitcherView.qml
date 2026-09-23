import QtQuick
import qs.Commons
import qs.Ui

// The island's theme picker: a live-filtering search field over a horizontal
// carousel of theme cards, each painted from its own resolved palette.
//
// Mounted as the manual context `island.themeSwitcher`, opened by Down on the
// island card. `islandState` is deliberately NOT injected: the picker never
// drives the island — it enters through the card's guard and leaves through the
// card's Escape / outside click, which already collapse.
//
// The palette cache lives on the island body, outside the body's Loader, and is
// handed in as `themePalette`. This view never spawns a process and never reads
// a theme file itself.
Column {
  id: root

  // Injected by DynamicIsland.
  property var islandBar: null
  property var themePalette: null

  // --- picker state ---------------------------------------------------------
  // Mirrored into the field; the filter is computed from it.
  property string searchText: ""
  // Theme whose apply is in flight ("" when idle).
  property string pendingName: ""
  // The last apply did not land; only then does the password affordance show.
  property string failedName: ""
  // Theme confirmed by the watched theme.name, held for one beat.
  property string confirmedName: ""

  readonly property var palettes: root.themePalette ? root.themePalette.palettes : ({})

  // The truth the apply reconciles against: written by `omarchy-theme-set`.
  readonly property string currentName:
    root.themePalette ? String(root.themePalette.currentName || "") : ""

  spacing: Style.spacing.md
  // Motion vocabulary from the bar, with the same fallbacks DynamicIsland uses
  // so a bare-test instantiation still animates.
  readonly property int motionFast: root.islandBar ? root.islandBar.motion.fast : 200

  // --- card geometry --------------------------------------------------------
  // Style tokens only, so the notch scale and the spacing scale are respected.
  // A 158px card holds the 8 dots (8 × 11 + 7 × 3 = 109) with padding to spare.
  readonly property int cardW: Style.space(158)
  readonly property int cardH: Style.space(58)
  readonly property int dotSize: Style.space(11)
  // The spec's canonical dot count, used only before the inventory lands.
  readonly property int dotCount: 8

  // Placeholder dots for a card whose palette has not arrived yet: the spec's
  // 8 dots must exist from the first frame, and none of them may be
  // transparent.
  readonly property var fallbackDots: {
    var out = []
    for (var i = 0; i < root.dotCount; i++) out.push(Util.alpha(Color.bar.text, 0.30))
    return out
  }

  // --- listing --------------------------------------------------------------
  // The inventory already dropped every directory without a `colors.toml`, so
  // the list needs no second filter.
  readonly property var themeNames: root.themePalette ? root.themePalette.names() : []

  // `total` and `position` are defined over THIS list, never the unfiltered one.
  readonly property var filteredNames: {
    var all = root.themeNames
    var query = root.searchText.trim().toLowerCase()
    if (query === "") return all
    var out = []
    for (var i = 0; i < all.length; i++) {
      var name = String(all[i])
      // Raw name or title-cased label: "tokyo", "Tokyo" and "night" all match.
      if (name.toLowerCase().indexOf(query) >= 0
          || root.labelFor(name).toLowerCase().indexOf(query) >= 0) {
        out.push(name)
      }
    }
    return out
  }
  readonly property int total: root.filteredNames.length
  // Selection lives on the ListView so StrictlyEnforceRange and the highlight
  // range stay the single source of the carousel's position. `position` is
  // 1-based over the filtered list.
  readonly property int selectionIndex:
    (strip.currentIndex >= 0 && strip.currentIndex < root.total) ? strip.currentIndex : -1
  readonly property string selectedName:
    root.selectionIndex >= 0 ? String(root.filteredNames[root.selectionIndex]) : ""
  readonly property int position: root.selectionIndex >= 0 ? root.selectionIndex + 1 : 0

  readonly property string statusText: {
    if (root.pendingName !== "") {
      return "Applying " + root.labelFor(root.pendingName) + "…"
    }
    if (root.failedName !== "") {
      return root.labelFor(root.failedName)
        + " did not apply — a password prompt may be waiting"
    }
    if (root.confirmedName !== "") return root.labelFor(root.confirmedName) + " applied"
    if (root.total === 0) return "No themes match"
    return root.position + "/" + root.total + " · Enter to apply"
  }

  function labelFor(name) {
    return root.themePalette ? root.themePalette.label(name) : String(name || "")
  }

  function dotsFor(name) {
    return root.themePalette ? root.themePalette.dots(name) : root.fallbackDots
  }

  function accentFor(name) {
    return root.themePalette ? root.themePalette.accent(name) : Color.accent
  }

  // --- selection ------------------------------------------------------------
  // Put the selection on a named theme when it is in the filtered list.
  function selectTheme(name) {
    var idx = root.filteredNames.indexOf(String(name || ""))
    if (idx < 0) return false
    strip.currentIndex = idx
    return true
  }

  // Keep the selection inside the list when the inventory or the filter moves,
  // preferring the applied theme and falling back to the first match.
  function clampSelection() {
    var list = root.filteredNames
    if (list.length === 0) {
      strip.currentIndex = -1
      return
    }
    if (strip.currentIndex >= 0 && strip.currentIndex < list.length) return
    if (root.selectTheme(root.currentName)) return
    strip.currentIndex = 0
  }

  // Walk the strip, wrapping at both ends like qs.Ui.ButtonGroup does.
  function step(delta) {
    var count = root.total
    if (count <= 0) return
    var idx = root.selectionIndex
    if (idx < 0) idx = 0
    strip.currentIndex = ((idx + Number(delta || 0)) % count + count) % count
  }

  // --- optimistic apply -----------------------------------------------------
  // A theme may have to take a lock and regenerate templates before it writes
  // theme.name, so the confirmation is never synchronous: mark the card
  // pending, run the apply detached, and reconcile on the watched name.
  function requestApply(name) {
    var theme = String(name || "")
    if (theme === "" || root.pendingName !== "") return
    root.failedName = ""
    root.confirmedName = ""
    // Applying the theme that is already active cannot change theme.name, so
    // there would be nothing for the reconcile to observe. Confirm it directly
    // rather than waiting out the timeout.
    if (theme === root.currentName) {
      root.confirmedName = theme
      confirmTimer.restart()
      return
    }
    root.pendingName = theme
    // argv, not a shell string: the name never reaches a re-tokenizing shell,
    // and a login shell resolves the command on PATH. Detached, so the island
    // never blocks on the apply.
    Util.execArgv(["omarchy-theme-set", theme])
    applyTimer.restart()
  }

  // Timeout: the apply never landed (a failed set, a lock that never released,
  // or a password prompt still waiting). Fall back to the truth.
  function failApply() {
    if (root.pendingName === "") return
    root.failedName = root.pendingName
    root.pendingName = ""
    root.selectTheme(root.currentName)
  }

  // The watched name is the only confirmation that counts.
  onCurrentNameChanged: {
    if (root.pendingName !== "") {
      applyTimer.stop()
      if (root.currentName === root.pendingName) {
        root.confirmedName = root.currentName
        confirmTimer.restart()
      } else {
        // Something else landed. The pending theme did not take.
        root.failedName = root.pendingName
      }
      root.pendingName = ""
      root.selectTheme(root.currentName)
      return
    }
    // No apply in flight: the ring follows the truth (including the first read).
    root.selectTheme(root.currentName)
  }

  onFilteredNamesChanged: root.clampSelection()

  // Typing re-aims the selection at the first match, which is what makes
  // "type a prefix, press Enter" work from the field.
  onSearchTextChanged: {
    var list = root.filteredNames
    strip.currentIndex = list.length > 0 ? 0 : -1
  }

  Component.onCompleted: {
    // The first open can beat the warm-up. Asking here is the lazy read the
    // palette reader owns; the view never spawns.
    if (root.themePalette) root.themePalette.ensureReady()
    root.clampSelection()
    // Autofocus, one turn later: a Loader's item is not focusable the instant
    // it is created.
    Qt.callLater(function() { searchField.forceActiveFocus() })
  }

  // --- zone 1: the search field --------------------------------------------
  TextField {
    id: searchField
    width: root.width
    placeholderText: "Search themes"
    font.family: Style.font.family
    font.pixelSize: Style.font.body
    text: root.searchText
    onTextChanged: if (root.searchText !== text) root.searchText = text
    // Enter from the field applies the match the filter already aimed at, so
    // the hint is true in both zones.
    onAccepted: root.requestApply(root.selectedName)
    // Left/Right step the theme (hand focus to the strip first); Down and
    // Tab also hand the keyboard to the strip. Up from the strip returns
    // here, and a second Up (or Escape) is handled by the island card to
    // navigate the picker stack.
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
      // Up from the picker's field returns to the island. The card's own
      // Up handler (NotchIslandBar) will see that the picker is up and
      // collapse it; we just release focus so the card can handle it.
      // If the field already has focus and the user presses Up again, the
      // card's handler will open the background picker.
      event.accepted = false
    }
  }

  // --- zone 2: the carousel -------------------------------------------------
  Item {
    id: carousel
    width: root.width
    // Slack large enough for BOTH overflows of the selected card: its 1.08
    // scale ((1.08 - 1) * cardH / 2) and its focus ring (one space(3) margin
    // plus a hairline border). At font base-size 17 that is ~8px per side,
    // and Style.space(14) is 20px (10px per side), so the ring is never
    // clipped. A horizontal ListView resets the delegate's y to 0
    // (FxListItemSG::pointForPosition resets the inactive axis), so the
    // cross-axis centring lives inside a full-height delegate, not on y.
    height: root.cardH + Style.space(14)

    ListView {
      id: strip
      anchors.fill: parent
      orientation: ListView.Horizontal
      model: root.filteredNames
      // Edge clipping falls out of the viewport clip plus the partial
      // neighbours the highlight range leaves visible.
      clip: true
      spacing: Style.spacing.md
      // Centred selection: the current card's own span, laid around the middle
      // of the viewport. StrictlyEnforceRange keeps it there between arrow
      // presses and while a drag settles.
      highlightRangeMode: ListView.StrictlyEnforceRange
      preferredHighlightBegin: strip.width / 2 - root.cardW / 2
      preferredHighlightEnd: strip.width / 2 + root.cardW / 2
      highlightMoveDuration: 0
      snapMode: ListView.SnapToItem
      // Two cards of slack either side: enough for the partial neighbours to
      // stay live mid-move without instantiating the whole inventory.
      cacheBuffer: root.cardW * 2
      focus: false
      activeFocusOnTab: true
      // Mirror qs.Ui.ButtonGroup's contract: BeforeItem so the view's own key
      // navigation never runs underneath, h/l alongside the arrows, and
      // Return/Enter/Space activate. Everything else — Escape included — falls
      // through to the island card, which owns the collapse.
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
          root.requestApply(root.selectedName)
          event.accepted = true
        }
      }
      // Re-clamp on arrival so the selection is always a real card.
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
          readonly property string themeName: String(cardSlot.modelData)
          readonly property string themeLabel: root.labelFor(card.themeName)
          // The card's OWN accent, so the affordance names the theme it belongs
          // to rather than the active one.
          readonly property color themeAccent: root.accentFor(card.themeName)
          readonly property var themeDots: root.dotsFor(card.themeName)
          readonly property bool selected: strip.currentIndex === cardSlot.index
          readonly property bool pending: root.pendingName === card.themeName

          width: root.cardW
          height: root.cardH
          radius: Style.cornerRadius
        color: Util.alpha(Color.bar.text, card.selected ? 0.14 : 0.07)
        // Selected: own-accent border plus a larger scale. Unselected cards are
        // borderless, so the affordance reads without a second colour system.
        border.width: card.selected ? Math.max(1, Math.round(Style.space(2))) : 0
        border.color: card.themeAccent
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

        // Zone indicator: the ring is only up while the strip owns the
        // keyboard, so it is never ambiguous which zone receives the keys. The
        // field paints its own focus border.
        Rectangle {
          anchors.fill: parent
          anchors.margins: -Style.space(3)
          radius: card.radius + Style.space(3)
          color: "transparent"
          border.width: Math.max(1, Math.round(Style.space(1)))
          border.color: Util.alpha(card.themeAccent, 0.55)
          visible: card.selected && strip.activeFocus
        }

        Column {
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.verticalCenter: parent.verticalCenter
          width: card.width - Style.spacing.md * 2
          spacing: Style.spacing.sm

          Text {
            width: parent.width
            text: card.themeLabel
            color: card.selected ? Color.bar.text : Util.alpha(Color.bar.text, 0.82)
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            font.weight: card.selected ? Font.DemiBold : Font.Normal
            elide: Text.ElideRight
            horizontalAlignment: Text.AlignHCenter
          }

          // The 8 canonical dots, in spec order, from resolved values. The
          // outline keeps a near-background dot visible on its own card.
          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Style.spacing.xs

            Repeater {
              model: card.themeDots
              delegate: Rectangle {
                required property var modelData
                width: root.dotSize
                height: root.dotSize
                radius: width / 2
                color: modelData
                border.width: 1
                border.color: Util.alpha(Color.bar.text, 0.20)
              }
            }
          }
        }

        // Pending pulse: the card is not yet the truth, so it reads as "on its
        // way" rather than as selected-and-done.
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
            // Selecting only, never applying: a stray click must not repaint
            // the whole desktop. Enter is the deliberate path.
            onClicked: {
              strip.currentIndex = cardSlot.index
              strip.forceActiveFocus()
            }
          }
        }
      }
    }
  }

  // --- status line: counter, hint, apply state ------------------------------
  Text {
    width: root.width
    text: root.statusText
    color: root.failedName !== ""
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
    // Covers lock contention, template regeneration and the IPC repaint, and is
    // short enough that a real failure does not strand the card in "Applying".
    interval: 8000
    onTriggered: root.failApply()
  }

  Timer {
    id: confirmTimer
    interval: 2400
    onTriggered: root.confirmedName = ""
  }
}
