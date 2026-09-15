import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import Quickshell.Io
import qs.Commons
import qs.Ui
// The island replaces the system bar, so it reuses the bar's own layout
// helpers verbatim instead of vendoring a copy that would drift. BarModel.js
// is a plain JS library (module.exports) shipped by the shell at the same
// root quickshell runs from (`-p /usr/share/omarchy/shell`), so an absolute
// file-URL import resolves it without touching the read-only system tree.
import "file:///usr/share/omarchy/shell/plugins/bar/BarModel.js" as BarModel

// Grid host for one side of the island body. It instantiates that side's
// layout entries with the same three-loader mechanism and the same prop
// injection Bar.qml's ModuleSlot uses (so first-party and third-party bar
// widgets keep working), then presents them as a clean uniform-cell grid
// inside the island body instead of a strip beside the pill.
//
// Every entry always gets a fixed-size tile, so the raster stays rectangular
// row to row. A widget that widens past one cell claims a second column; a
// widget that draws nothing simply leaves its tile empty. A widget the user
// pins with a right-click is lifted out of the grid into its own full-width,
// accent-tinted row above it (see pinnedEntries).
//
// NOTE on `visible`: Qt propagates an ancestor's visible=false into its whole
// subtree, and a child's `visible` read then reflects that effective state.
// Binding a tile's visibility to its hosted widget's `visible` would therefore
// self-lock (hidden tile -> widget reads hidden -> tile stays hidden), so tiles
// are intentionally kept visible and collapse by SIZE instead.
Item {
  id: root

  required property string side      // "left" | "right"
  required property var islandBar    // NotchIslandBar root (the injected `bar`)
  // The IslandUnit this grid belongs to, so a cell click routes to that
  // monitor's island even when another monitor is focused.
  property var islandUnit: null
  property var entries: []           // layout entries for this side, normalized
  // Solo mode (Function 2): when the bar pins one widget while its panel is
  // open, only that tile is laid out, centered at the top. Every other tile
  // collapses to zero size — never destroyed — so the panel's live anchor
  // keeps resolving and no widget state is lost. Empty means the full grid.
  property string soloWidgetId: ""

  readonly property string soloId: String(root.soloWidgetId || "")
  readonly property bool sideHasSolo: {
    if (root.soloId === "") return false
    for (var i = 0; i < root.entries.length; i++) {
      if (String(root.entryId(root.entries[i])) === root.soloId) return true
    }
    return false
  }
  readonly property bool soloActive: root.sideHasSolo
  // Pinned = the user promoted this widget to its own full-width row at the top
  // (right-click gesture). Pinned widgets leave the grid flow entirely, so the
  // grid below never reflows for them.
  readonly property bool soloPinned: root.soloActive && root.entryIsPinned(root.soloId)
  // The selected entry lives in the grid: turn the grid into a single centered
  // column and collapse every other cell.
  readonly property bool soloCentered: root.soloActive && !root.soloPinned

  // --- grid metrics ----------------------------------------------------------
  // 4 columns keeps the cells close to the bar's own icon rhythm; wide widgets
  // claim a second column instead of stretching one cell out of line.
  property int columns: 4
  property int cellSpacing: Style.space(6)
  property int cellHeight: Style.space(46)
  // Body-height cap: past this the grid scrolls instead of growing the island.
  property int maxGridHeight: Style.space(320)

  // Cell width is derived from the width the body Loader hands us. Every
  // span-1 cell is exactly this wide, so columns stay aligned row to row.
  readonly property real cellWidth: columns > 0
    ? Math.max(0, (root.width - (columns - 1) * cellSpacing) / columns)
    : 0

  // --- learned column span, cached by widget id -------------------------------
  // A widget that widens past one cell claims a second column. That span is
  // resolved from this grid-level map instead of a property on the cell: the
  // Repeater rebuilds EVERY delegate whenever the model changes (pin/unpin,
  // empty-widget filtering), so a delegate-local latch was thrown away and
  // re-measured from scratch — a race the reloaded widget lost, dropping wide
  // widgets back to one column. Keyed by id, a learned span survives any
  // rebuild. Grow-only, so an expandable widget that reserves its full extent
  // on hover keeps the wider span and never reflows the grid back.
  property var spanById: ({})
  function spanFor(id) {
    var key = String(id || "")
    return (key && root.spanById[key] > 0) ? root.spanById[key] : 1
  }
  function growSpan(id, wanted) {
    var key = String(id || "")
    if (!key || wanted <= (root.spanById[key] || 0)) return
    var next = {}
    for (var k in root.spanById) next[k] = root.spanById[k]
    next[key] = wanted
    root.spanById = next
  }

  // True while a tile drag is in progress (NotchIslandBar owns the drag
  // state). The Flickable stops scrolling then, so a drag gesture is not
  // stolen by the scroll instead of reordering the layout.
  readonly property bool dragActive: !!(root.islandBar && root.islandBar.dragWidgetId !== "")

  // ---------------------------------------------------------------------------
  // EXCLUSION PANEL
  // The "Excluded (N)" header at the bottom of the grid lists every widget the
  // user took out of the island (the per-entry `islandHidden` setting). It is
  // always visible so the count stays discoverable, and collapsed by default;
  // expanding shows a grid of chips. Chips are compact labels, NOT live widget
  // instances: a second live copy would double up a widget's panel/IPC
  // handlers. A chip is a drag source, so a widget can be pulled back into the
  // grid from here; pushing one out is the bottom drop bar's "Exclude" target
  // while dragging a grid tile. The list is global (both grids show it).
  // ---------------------------------------------------------------------------
  property var excludedIds: []
  property bool excludedOpen: false

  function widgetLabel(id) {
    var host = root.islandBar
    var key = String(id || "")
    if (host && typeof host.widgetManifest === "function") {
      var manifest = host.widgetManifest(key)
      if (manifest && manifest.barWidget && manifest.barWidget.displayName)
        return String(manifest.barWidget.displayName)
      if (manifest && manifest.name) return String(manifest.name)
    }
    return key
  }

  // ---------------------------------------------------------------------------
  // PINNED-TO-TOP WIDGETS
  // Right-clicking a tile promotes it to its own full-width row here, above the
  // grid; right-clicking it again returns it to the grid. The flag lives on the
  // widget's bar entry (`islandPinned`, persisted by the shell), so it survives
  // restarts. Multiple widgets can be pinned; they stack in layout order.
  // ---------------------------------------------------------------------------
  function entryId(entry) {
    return BarModel.entryId(entry)
  }

  function entryIsPinned(id) {
    var key = String(id || "")
    if (!key) return false
    var host = root.islandBar
    return !!(host && typeof host.isWidgetPinned === "function" && host.isWidgetPinned(key))
  }

  readonly property var pinnedEntries: {
    var out = []
    for (var i = 0; i < root.entries.length; i++) {
      if (root.entryIsPinned(root.entryId(root.entries[i]))) out.push(root.entries[i])
    }
    return out
  }

  readonly property var gridEntries: {
    var out = []
    for (var i = 0; i < root.entries.length; i++) {
      var id = root.entryId(root.entries[i])
      if (root.entryIsPinned(id)) continue
      out.push(root.entries[i])
    }
    return out
  }

  readonly property int excludedHeaderHeight: root.soloActive ? 0 : Style.space(30)
  readonly property int excludedPanelHeight: (root.excludedOpen && !root.soloActive)
    ? excludedGrid.implicitHeight : 0

  implicitWidth: 0
  implicitHeight: Math.min(contentItem.implicitHeight, root.maxGridHeight)
    + root.excludedHeaderHeight
    + root.excludedPanelHeight

  Flickable {
    id: flick
    anchors {
      top: parent.top
      left: parent.left
      right: parent.right
      bottom: excludedHeader.top
    }
    contentWidth: width
    contentHeight: contentItem.implicitHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    flickableDirection: Flickable.VerticalFlick
    interactive: contentHeight > height && !root.dragActive
    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

    Item {
      id: contentItem
      width: flick.width
      implicitHeight: pinnedColumn.height
        + (pinnedColumn.height > 0 && grid.visible ? root.cellSpacing : 0)
        + (grid.visible ? grid.implicitHeight : 0)

      // Pinned rows: widgets promoted to the top of the island with a
      // right-click. Full card width, accent-tinted, stacked in layout order
      // above the grid. Right-clicking again returns the widget to the grid.
      Column {
        id: pinnedColumn
        width: contentItem.width
        spacing: root.cellSpacing

        Repeater {
          model: root.pinnedEntries

          delegate: Rectangle {
            id: pinnedRow
            required property var modelData
            readonly property string rowId: BarModel.entryId(modelData)
            width: pinnedColumn.width
            // In solo mode only the selected pinned widget keeps its row.
            height: root.soloActive && root.soloId !== rowId ? 0 : root.cellHeight
            clip: true
            radius: Style.cornerRadius
            color: Util.alpha(Color.accent, 0.14)
            border.width: 1
            border.color: Util.alpha(Color.accent, 0.40)

            MouseArea {
              anchors.fill: parent
              acceptedButtons: Qt.RightButton
              cursorShape: Qt.PointingHandCursor
              onClicked: root.pinnedRightClicked(pinnedRow.rowId)
            }

            DragHandler {
              target: null
              enabled: pinnedRow.rowId !== "" && !!root.islandBar && !pinnedSlot.commandRunsOnClick
              dragThreshold: Style.space(4)
              grabPermissions: PointerHandler.CanTakeOverFromAnything
              onActiveChanged: {
                if (!root.islandBar) return
                if (active) root.islandBar.beginWidgetDrag(pinnedRow.rowId, root.side)
                else root.islandBar.endWidgetDrag()
              }
              onCentroidChanged: {
                if (!active || !root.islandBar) return
                root.islandBar.updateWidgetDrag(centroid.scenePosition.x, centroid.scenePosition.y)
              }
            }

            IslandModuleSlot {
              id: pinnedSlot
              anchors.centerIn: parent
              entry: pinnedRow.modelData
              hostBar: root.islandBar
              islandUnit: root.islandUnit
              gridSide: root.side
            }
          }
        }
      }

      GridLayout {
        id: grid
        // Solo-centered: the grid shrinks to one cell wide and centers itself,
        // so the single remaining tile sits at the top middle of the body and
        // the panel anchored to it lands centered under the notch. In normal
        // mode it spans the content width.
        width: root.soloCentered ? root.cellWidth : contentItem.width
        x: root.soloCentered ? Math.round((contentItem.width - width) / 2) : 0
        y: pinnedColumn.height + (pinnedColumn.height > 0 ? root.cellSpacing : 0)
        visible: !root.soloPinned
        columns: root.soloCentered ? 1 : root.columns
        columnSpacing: root.cellSpacing
        rowSpacing: root.soloCentered ? 0 : root.cellSpacing
        // The grid reflow SNAPS: animating width/x here dragged the pinned
        // tile (and the plugin panel anchored to it) across the screen while
        // opening/closing a plugin, which read as the icon taking forever to
        // settle. The island's motion lives in the body, clock and mini-player.
        Repeater {
          model: root.gridEntries

          delegate: IslandGridCell {
            required property var modelData
            entry: modelData
            hostBar: root.islandBar
            islandUnit: root.islandUnit
            // Every cell but the selected one collapses to zero size. The
            // delegate is NOT destroyed, so its hosted widget (and any open
            // KeyboardPanel anchored to it) survives the reflow.
            soloCollapsed: root.soloCentered
              && String(BarModel.entryId(modelData)) !== root.soloId
          }
        }
      }
    }
  }

  // --- exclusion panel: header + chip grid ----------------------------------
  // Header pinned at the bottom of the grid (outside the Flickable) so the
  // count is always reachable; the chips grid sits below it, sized by
  // excludedPanelHeight. Collapsed by default.
  Item {
    id: excludedHeader
    anchors {
      left: parent.left
      right: parent.right
      bottom: excludedGridHost.top
    }
    height: root.excludedHeaderHeight
    visible: !root.soloActive

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: root.excludedOpen = !root.excludedOpen
    }

    Row {
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: "Excluded (" + root.excludedIds.length + ")"
        color: Util.alpha(Color.bar.text, root.excludedOpen ? 0.90 : 0.55)
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: root.excludedOpen ? "▾" : "▸"
        color: Util.alpha(Color.bar.text, root.excludedOpen ? 0.90 : 0.55)
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }
    }
  }

  Item {
    id: excludedGridHost
    anchors {
      left: parent.left
      right: parent.right
      bottom: parent.bottom
    }
    height: root.excludedPanelHeight
    visible: root.excludedOpen && !root.soloActive
    clip: true

    GridLayout {
      id: excludedGrid
      anchors {
        top: parent.top
        left: parent.left
        right: parent.right
      }
      columns: root.columns
      columnSpacing: root.cellSpacing
      rowSpacing: root.cellSpacing

      Repeater {
        model: root.excludedIds

        delegate: Rectangle {
          id: chip
          required property var modelData
          readonly property string chipId: String(modelData || "")

          Layout.preferredWidth: root.cellWidth
          Layout.preferredHeight: root.cellHeight
          Layout.alignment: Qt.AlignHCenter | Qt.AlignVCenter
          radius: Style.cornerRadius
          color: Util.alpha(Color.bar.text, 0.06)
          border.width: 1
          border.color: Util.alpha(Color.bar.text, 0.10)
          clip: true
          opacity: (root.islandBar && root.islandBar.dragWidgetId === chip.chipId) ? 0.35 : 1.0

          Column {
            anchors.centerIn: parent
            width: Math.max(0, parent.width - Style.space(8))
            spacing: Style.space(1)

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              // md-cancel (U+F073A): a "disabled/ban" mark, not the copy icon.
              text: "󰜺"
              color: Util.alpha(Color.bar.text, 0.85)
              font.family: Style.font.family
              font.pixelSize: Style.font.title
            }

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              width: parent.width
              text: root.widgetLabel(chip.chipId)
              color: Util.alpha(Color.bar.text, 0.65)
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              horizontalAlignment: Text.AlignHCenter
              elide: Text.ElideRight
            }
          }

          DragHandler {
            target: null
            dragThreshold: Style.space(4)
            grabPermissions: PointerHandler.CanTakeOverFromAnything
            onActiveChanged: {
              if (!root.islandBar) return
              if (active) root.islandBar.beginWidgetDrag(chip.chipId, "excluded")
              else root.islandBar.endWidgetDrag()
            }
            onCentroidChanged: {
              if (!active || !root.islandBar) return
              root.islandBar.updateWidgetDrag(centroid.scenePosition.x, centroid.scenePosition.y)
            }
          }
        }
      }
    }
  }

  // Right-clicking a pinned row returns the widget to the grid (the same toggle
  // as the cell gesture; the flag lives on the widget's bar entry).
  function pinnedRightClicked(id) {
    var host = root.islandBar
    if (host && typeof host.togglePinnedWidget === "function")
      host.togglePinnedWidget(String(id || ""))
  }

  // One uniform grid tile. The tile is fixed to the grid metric; the hosted
  // widget keeps its natural size and is centered inside it. A widget whose
  // natural width overflows one cell claims a second column so the raster
  // stays rectangular instead of one row bulging out of line.
  component IslandGridCell: Rectangle {
    id: cell

    required property var entry
    property var hostBar: null
    property var islandUnit: null
    // Solo mode collapsed this cell: it keeps its widget instance but takes no
    // layout space, so the grid reflows without model churn.
    property bool soloCollapsed: false

    readonly property string moduleName: BarModel.entryId(entry)
    // Span is resolved from the grid's per-id cache (root.spanFor), so a
    // learned span survives the Repeater rebuilding this delegate (pin/unpin,
    // exclusion). A delegate-local latch was discarded on every rebuild and
    // re-measured from scratch, a race the reloaded widget lost. Grow-only,
    // same as before: expandable widgets reserve their full extent.
    function latchSpan() {
      var item = slot.activeItem
      var natural = item ? (item.implicitWidth || 0) : 0
      if (natural <= 0) return
      // Refuse to measure against a collapsed metric: while the body has never
      // been mapped root.width is 0, and every widget would compare as "wider
      // than a cell" and poison the cache with span 2. Wait for a real cell.
      if (root.cellWidth <= 0) return
      var wanted = (natural > root.cellWidth + 1 && root.columns >= 2) ? 2 : 1
      root.growSpan(cell.moduleName, wanted)
    }
    readonly property int span: root.spanFor(cell.moduleName)
    // A cell can be created before its widget has a positive width: the slot's
    // loader is active before the registry component resolves, so the real item
    // swaps in later and its width may already be final when the Connections
    // re-attaches (no implicitWidthChanged left to catch). Poll for a bounded
    // window so at least one positive measurement always lands, and re-latch
    // whenever the slot's active item itself changes.
    property int spanTicks: 0
    Timer {
      interval: 300
      repeat: true
      running: cell.spanTicks < 12
      onTriggered: { cell.spanTicks += 1; cell.latchSpan() }
    }
    Connections {
      target: slot
      function onActiveItemChanged() { cell.latchSpan() }
    }
    Connections {
      target: root
      // The card width is a constant (max(240, expandedWidth)); cellWidth only
      // transitions 0 -> settled the first time the body is laid out, so this
      // re-latch is what captures spans on a session whose body starts unmapped.
      function onCellWidthChanged() { cell.latchSpan() }
      function onVisibleChanged() { cell.latchSpan() }
    }
    Connections {
      target: slot.activeItem
      function onImplicitWidthChanged() { cell.latchSpan() }
    }

    Layout.preferredWidth: {
      if (cell.soloCollapsed) return 0
      if (root.soloCentered) return root.cellWidth
      return cell.span > 1
        ? root.cellWidth * cell.span + root.cellSpacing * (cell.span - 1)
        : root.cellWidth
    }
    Layout.preferredHeight: cell.soloCollapsed ? 0 : root.cellHeight
    Layout.columnSpan: cell.soloCollapsed ? 1 : (root.soloCentered ? 1 : cell.span)
    Layout.alignment: Qt.AlignHCenter | Qt.AlignVCenter
    clip: true
    radius: Style.cornerRadius
    color: Util.alpha(Color.bar.text, 0.06)
    border.width: 1
    border.color: Util.alpha(Color.bar.text, 0.10)
    // The dragged source dims so the drop zone reads as the active target.
    opacity: (cell.hostBar && cell.hostBar.dragWidgetId === cell.moduleName) ? 0.35 : 1.0
    Behavior on opacity {
      NumberAnimation { duration: root.islandBar ? root.islandBar.motion.fast : 160; easing.type: Easing.OutCubic }
    }

    // Background click target around the natural-sized widget. Left click
    // opens the widget; RIGHT click promotes it to its own full-width row at
    // the top of the island (toggle: right-clicking again unpins it).
    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      enabled: !slot.commandRunsOnClick
      cursorShape: Qt.PointingHandCursor
      onClicked: function(mouse) {
        if (!cell.hostBar || cell.moduleName === "") return
        if (mouse.button === Qt.RightButton) {
          if (typeof cell.hostBar.togglePinnedWidget === "function")
            cell.hostBar.togglePinnedWidget(cell.moduleName)
          return
        }
        cell.hostBar.handleWidgetClick(cell.moduleName, cell.islandUnit)
      }
    }

    // Drag source for this tile. Activates only past the threshold, so a
    // plain click still reaches the widget/MouseArea below; once active it
    // takes over the grab and the island moves the widget to the opposite
    // side's set on release (NotchIslandBar.endWidgetDrag).
    DragHandler {
      target: null
      enabled: cell.moduleName !== "" && !!cell.hostBar && !slot.commandRunsOnClick
      dragThreshold: Style.space(4)
      grabPermissions: PointerHandler.CanTakeOverFromAnything
      onActiveChanged: {
        if (!cell.hostBar) return
        if (active) cell.hostBar.beginWidgetDrag(cell.moduleName, root.side)
        else cell.hostBar.endWidgetDrag()
      }
      onCentroidChanged: {
        if (!active || !cell.hostBar) return
        cell.hostBar.updateWidgetDrag(centroid.scenePosition.x, centroid.scenePosition.y)
      }
    }

    IslandModuleSlot {
      id: slot
      anchors.centerIn: parent
      entry: cell.entry
      hostBar: cell.hostBar
      islandUnit: cell.islandUnit
      gridSide: root.side
    }
  }

  // Mirrors Bar.qml's ModuleSlot: registry widgets, inline custom QML
  // modules, and command modules, each behind its own Loader, with props
  // injected after load. Drag-to-reorder and tooltip chrome are intentionally
  // out of scope for the island host.
  component IslandModuleSlot: Item {
    id: slot

    required property var entry
    // The island's bar host, delivered as this delegate's own property at
    // creation instead of resolved through the outer grid. Deferred work that
    // reaches `root.islandBar` by id can run after a plugin reload has
    // destroyed that scope (the reload-time TypeError this replaces).
    property var hostBar: null
    property var islandUnit: null
    // Which grid this slot lives in ("left" | "right"). Consumed by the bar's
    // drag logic to resolve drop targets without depending on item parentage.
    property string gridSide: ""
    readonly property string moduleName: BarModel.entryId(entry)
    readonly property var moduleSettings: BarModel.entrySettings(entry)
    readonly property string customType: BarModel.customModuleType(entry)

    // Reading barWidgetRegistry.widgets creates the binding dependency so the
    // slot rebuilds when the host registry mutates (same as Bar.qml).
    readonly property var registryComponent: {
      var widgets = slot.hostBar && slot.hostBar.barWidgetRegistry
        ? slot.hostBar.barWidgetRegistry.widgets
        : null
      if (customType) return null
      if (!widgets) return null
      var registered = widgets[Util.canonicalWidgetId(moduleName)]
      return registered && registered.component ? registered.component : null
    }
    readonly property bool qmlCustom: customType === "qml"
    readonly property bool commandCustom: customType === "command"
    readonly property bool registered: registryComponent !== null
    // Command modules that define their own onClick action own their press;
    // for them the tile-background fallback stays inert so the island ladder
    // cannot shadow that action. Without one, a click on the tile padding falls
    // into the island routing ladder like any other widget.
    readonly property bool commandRunsOnClick: {
      if (!commandCustom) return false
      var s = moduleSettings
      return !!(s && String(s.onClick || "") !== "")
    }
    readonly property var activeItem: {
      if (registered) return registryLoader.item
      if (qmlCustom) return qmlLoader.item
      return componentLoader.item
    }
    // Panel widgets own their own popup (Panel.qml and compatible widgets):
    // they expose open/close plus an `opened` flag. Those are the ids the
    // island can re-anchor to the centered ghost; everything else (workspaces,
    // tray drawer, command modules) keeps its native press untouched.
    readonly property bool panelWidget: {
      var item = slot.activeItem
      return !!item && typeof item.open === "function"
        && typeof item.close === "function" && item.opened !== undefined
    }

    // Out-of-band opens: the widget opened its own panel without going through
    // the island ladder (its own IPC handler, or its native press when the
    // host has centered anchoring off). Retreat the island all the same by
    // tracking the live item on the unit while it is open. The filtered target
    // keeps Connections bound to panel widgets only, so a plain indicator
    // (no `opened` signal) never raises an unmatched-handler warning.
    readonly property var watchedPanelItem: slot.panelWidget ? slot.activeItem : null
    Connections {
      target: slot.watchedPanelItem
      function onOpenedChanged() {
        if (slot.islandUnit && slot.watchedPanelItem)
          slot.islandUnit.noteSlotPanel(slot, slot.watchedPanelItem.opened === true)
      }
    }

    // Natural footprint, independent of the tile that centers it. The widget's
    // own `visible` is deliberately NOT read here: inside a hidden subtree Qt
    // reports it as hidden, so reading it would lock a hidden tile hidden.
    implicitWidth: activeItem ? (activeItem.implicitWidth || 0) : 0
    implicitHeight: activeItem ? (activeItem.implicitHeight || 0) : 0
    width: implicitWidth
    height: implicitHeight

    Component.onCompleted: if (slot.hostBar) slot.hostBar.registerModuleSlot(slot)
    Component.onDestruction: {
      if (slot.islandUnit) slot.islandUnit.noteSlotPanel(slot, false)
      if (slot.hostBar) slot.hostBar.unregisterModuleSlot(slot)
    }

    // Deferred prop re-injection, scoped to this slot's lifetime. A
    // Qt.callLater closure outlives delegate destruction: on plugin reload
    // it fires against a dead root and throws. A Timer parented to the
    // slot is destroyed with it, so a pending pass can never run late.
    // interval 0 fires on the next event-loop tick — the timing callLater
    // gave (props land after onLoaded has finished wiring the item).
    Timer {
      id: propsTimer
      interval: 0
      repeat: false
      onTriggered: slot.injectProps()
    }

    function injectPropsLater() {
      propsTimer.restart()
    }

    Loader {
      id: componentLoader
      active: !slot.qmlCustom && !slot.registered
      sourceComponent: slot.commandCustom ? customCommandModuleComponent : emptyModuleComponent
      anchors.fill: parent
      onLoaded: {
        slot.injectProps()
        slot.injectPropsLater()
      }
    }

    Loader {
      id: registryLoader
      active: slot.registered
      sourceComponent: slot.registered ? slot.registryComponent : null
      anchors.fill: parent
      onLoaded: {
        slot.injectProps()
        slot.injectPropsLater()
      }
    }

    Loader {
      id: qmlLoader
      active: slot.qmlCustom
      source: slot.qmlCustom ? slot.customModuleSource() : ""
      anchors.fill: parent
      onLoaded: {
        slot.injectProps()
        slot.injectPropsLater()
      }
    }

    function customModuleSource() {
      var host = slot.hostBar
      if (!host) return ""
      var source = BarModel.customModulePath(slot.entry, host.home, host.omarchyConfigDir)
      return source ? Util.fileUrl(source) : ""
    }

    function injectProps() {
      var target = slot.activeItem
      if (!target) return
      var host = slot.hostBar
      if (!host) return
      if ("bar" in target) target.bar = host
      if ("moduleName" in target) target.moduleName = slot.moduleName
      if ("settings" in target) target.settings = slot.moduleSettings
      if ("manifest" in target) target.manifest = host.widgetManifest(slot.moduleName)
      if ("entry" in target) target.entry = slot.entry
      if ("shell" in target) target.shell = host.shell
    }

    onActiveItemChanged: slot.injectPropsLater()
    onModuleSettingsChanged: injectProps()

    Component {
      id: emptyModuleComponent
      Item { implicitWidth: 0; implicitHeight: 0; visible: false }
    }

    Component {
      id: customCommandModuleComponent
      IslandCommandModule { entry: slot.entry }
    }

    // Click routing on the island. Panel widgets (open/close/opened) route
    // their left press through the host's panel-first ladder, which lets the
    // island enter solo mode and center this tile before the panel opens; the
    // panel then anchors under the notch instead of under this grid cell.
    // Non-panel widgets still decline the left press (`mouse.accepted = false`)
    // so it falls through to their native Button — workspace focus, menu
    // launch, command onClick (the W9 behavior). MIDDLE clicks are forwarded to
    // the widget's press handler; RIGHT click pins/unpins the widget to its own
    // full-width row at the top of the island (the island gesture).
    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
      onPressed: function(mouse) {
        var host = slot.hostBar
        if (!host || slot.moduleName === "") { mouse.accepted = false; return }
        if (mouse.button === Qt.LeftButton) {
          if (slot.panelWidget) {
            host.handleWidgetClick(slot.moduleName, slot.islandUnit)
            mouse.accepted = true
            return
          }
          mouse.accepted = false
          return
        }
        if (mouse.button === Qt.RightButton) {
          if (typeof host.togglePinnedWidget === "function")
            host.togglePinnedWidget(slot.moduleName)
          mouse.accepted = true
          return
        }
        var item = slot.activeItem
        if (item && typeof item.triggerPress === "function") {
          item.triggerPress(mouse.button)
          mouse.accepted = true
        } else {
          mouse.accepted = false
        }
      }
    }
  }

  // Command-type custom modules (shell.json entries with `exec`), mirroring
  // Bar.qml's CustomCommandModule so text modules keep rendering on the
  // island.
  component IslandCommandModule: WidgetButton {
    id: customRoot

    // No `moduleName` here: the host's injectProps writes that name, and a
    // readonly declaration (Bar.qml's version) would throw on injection.
    // The slot tracks the id itself via IslandModuleSlot.moduleName.
    required property var entry
    // Writable, host-injected (injectProps) with BarModel.entrySettings().
    property var settings: ({})
    property string outputText: ""
    property string outputTooltip: ""
    property bool outputActive: false

    bar: root.islandBar
    text: outputText || String(setting("text", ""))
    tooltipText: outputTooltip || String(setting("tooltip", ""))
    active: outputActive
    keepSpace: setting("keepSpace", false) === true
    horizontalMargin: Number(setting("horizontalMargin", 7.5))
    verticalPadding: Number(setting("verticalPadding", 6))
    fontSize: Number(setting("fontSize", 12))

    function setting(name, fallback) {
      var value = settings ? settings[name] : undefined
      return value === undefined || value === null ? fallback : value
    }

    function update(raw) {
      var data = Util.parseModuleJson(raw)
      var klass = data.class || data.alt || ""

      outputText = data.text || String(raw || "").trim()
      outputTooltip = data.tooltip || String(setting("tooltip", ""))
      outputActive = klass === "active" || (Array.isArray(klass) && klass.indexOf("active") !== -1)
    }

    onPressed: function(button) {
      var host = root.islandBar
      var command = ""
      if (button === Qt.RightButton)
        command = String(setting("onRightClick", ""))
      else if (button === Qt.MiddleButton)
        command = String(setting("onMiddleClick", ""))
      else
        command = String(setting("onClick", ""))

      if (command && host) host.run(command)
    }

    Process {
      id: customProc
      command: ["bash", "-lc", String(customRoot.setting("exec", ""))]
      stdout: StdioCollector {
        waitForEnd: true
        onStreamFinished: customRoot.update(text)
      }
    }

    Timer {
      interval: Math.max(1, Number(customRoot.setting("interval", 5))) * 1000
      running: String(customRoot.setting("exec", "")) !== ""
      repeat: true
      triggeredOnStart: true
      onTriggered: if (root.islandBar) root.islandBar.runProcess(customProc)
    }
  }
}
