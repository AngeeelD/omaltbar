import QtQuick
import Quickshell.Hyprland
import qs.Commons
import qs.Ui
import "views" as Views

// The island body: a context router, nothing more. Which view renders is
// decided by IslandState.activeContext and the nativeViews map —
//   ""              -> home (hover/click expansion)
//   grid sentinel   -> this side's widget grid (pill left/right reveal)
//   native view id  -> the registered Component (phase 3 grows this map)
//   anything else   -> generic fallback: icon + plugin name + Open panel
Rectangle {
  id: root

  // IslandState instance owned by this screen's island unit. Named
  // `islandState` because `state` is a reserved Item property.
  required property var islandState
  // NotchIslandBar root: the island's bar contract (findPanelWidget,
  // widgetManifest, shell, plugin access).
  property var islandBar: null
  // The IslandUnit that owns this body, forwarded to the widget grids so a
  // cell click routes to this screen's island rather than the focused one.
  property var islandUnit: null
  // Width the unit wants the card to take; height follows the loaded view.
  property int targetWidth: 320

  // Surfaced to the unit so card hover participates in the auto-collapse
  // policy without the card poking at unit internals.
  property bool cardHovered: false

  opacity: islandState.expanded ? 1 : 0
  // The card is NOT gated by `visible`: the island window holds it mapped for
  // one motion beat after collapse (unit.bodyHeld) so this fade/scale can play
  // as a retraction toward the notch. Anchor-driven, never `visible`-driven.
  transformOrigin: Item.Top
  scale: islandState.expanded ? 1 : 0.80
  // "Oil drop" emergence: the card slides down out of the pill while it grows
  // and fades, so the motion reads as a blob detaching from the notch rather
  // than a rectangle blinking into place.
  transform: Translate {
    y: islandState.expanded ? 0 : -Style.space(12)
    Behavior on y {
      NumberAnimation {
        duration: root.motionSlow
        easing.type: Easing.OutBack
        easing.overshoot: root.motionOvershoot
      }
    }
  }
  radius: Style.spacing.lg
  color: root.transparent ? Util.alpha(Color.bar.background, root.surfaceOpacity) : Color.bar.background
  clip: false

  readonly property bool transparent: islandBar ? islandBar.transparent === true : false
  // Alpha for the transparent body, owned by the bar (bar.islandOpacity). The
  // 0.72 fallback is the pre-round-9 constant, kept for a bar that predates it.
  readonly property real surfaceOpacity: {
    var v = islandBar ? islandBar.islandOpacity : undefined
    return (v === undefined || v === null) ? 0.72 : Number(v)
  }
  readonly property int contentPadding: Style.spacing.xxl
  // Bottom drop bar geometry: only there while a tile is being dragged.
  readonly property bool dragging: !!islandBar && islandBar.dragWidgetId !== ""
  readonly property int dropBarHeight: Style.spacing.controlHeight

  implicitWidth: Math.max(Style.space(240), targetWidth)
  // Height of whichever content is showing: a live grid, or the Loader's
  // current item. The grids are always instantiated, so this stays a stable
  // read while the card animates between contexts.
  readonly property real activeContentHeight: {
    if (!islandState || !islandState.expanded) return 0
    if (islandState.activeContext === islandState.gridContextLeft) return leftWidgetsGrid.implicitHeight
    if (islandState.activeContext === islandState.gridContextRight) return rightWidgetsGrid.implicitHeight
    return contentLoader.item && contentLoader.item.implicitHeight > 0 ? contentLoader.item.implicitHeight : 0
  }
  // Headers for the picker stack add their height when the main view is
  // showing; otherwise the picker/grid determines the height alone.
  readonly property real headerReserve: root.isMainView
    ? topHeader.height + bottomHeader.height + Style.spacing.sm
    : 0
  implicitHeight: contentPadding * 2 + Math.max(
    Style.space(64),
    activeContentHeight
  ) + headerReserve + root.pagerStrip + (root.dragging ? root.dropBarHeight + Style.spacing.sm : 0)
  width: implicitWidth
  height: implicitHeight

  // Only a promotion animates the height: the compact announcement growing into
  // the full context the user just reached for. Every other context change stays
  // instant, which is what the rest of the island is tuned around (the body
  // window follows this height, so an always-on animation would resize the
  // layer surface on every page switch).
  Behavior on height {
    enabled: !!root.islandState && root.islandState.promoting
    NumberAnimation { duration: root.motionBase; easing.type: Easing.OutCubic }
  }
  // The compact media peek is also narrower (see the unit's targetWidth), so the
  // promotion animates width on the same beat or the growth reads lopsided.
  Behavior on width {
    enabled: !!root.islandState && root.islandState.promoting
    NumberAnimation { duration: root.motionBase; easing.type: Easing.OutCubic }
  }

  // Organic "oil-drop" emergence/retraction: the card grows out of and sinks
  // back toward the notch. Durations and the overshoot come from the bar's
  // shared motion vocabulary so the pill and body stay in the same language.
  Behavior on opacity {
    NumberAnimation { duration: root.motionBase; easing.type: Easing.OutCubic }
  }
  Behavior on scale {
    NumberAnimation {
      duration: root.motionSlow
      easing.type: Easing.OutElastic
      easing.amplitude: root.motionElasticAmplitude
      easing.period: root.motionElasticPeriod
    }
  }
  Behavior on height {
    enabled: root.opacity > 0.02
    NumberAnimation {
      duration: root.motionBase
      easing.type: Easing.OutBack
      easing.overshoot: root.motionOvershoot
    }
  }
  Behavior on width {
    enabled: root.opacity > 0.02
    NumberAnimation { duration: root.motionBase; easing.type: Easing.OutCubic }
  }

  // Motion tokens fall back to the same numbers the bar root publishes, so the
  // body still animates when it is instantiated without an islandBar (tests).
  readonly property int motionFast: islandBar ? islandBar.motion.fast : 200
  readonly property int motionBase: islandBar ? islandBar.motion.base : 340
  readonly property int motionSlow: islandBar ? islandBar.motion.slow : 560
  readonly property real motionOvershoot: islandBar ? islandBar.motion.overshoot : 1.7
  readonly property real motionElasticAmplitude: islandBar ? islandBar.motion.elasticAmplitude : 1.0
  readonly property real motionElasticPeriod: islandBar ? islandBar.motion.elasticPeriod : 0.35

  HoverHandler {
    onHoveredChanged: root.cardHovered = hovered
    Component.onDestruction: if (hovered) root.cardHovered = false
  }

  // Empty-area click guard: the card's Rectangle does NOT block mouse events,
  // so a click on padding/gaps would fall through to islandWindow's dismiss
  // MouseArea (outside the card) and collapse the island — bad UX. This
  // background handler swallows clicks on the card itself; interactive
  // children (pager, deck controls, sliders) sit above and receive first.
  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
    hoverEnabled: false
    propagateComposedEvents: false
    onPressed: function(mouse) { mouse.accepted = true }
    onClicked: function(mouse) { mouse.accepted = true }
    z: -1
  }

  // Horizontal paging across the resolved context pages. WheelHandler's
  // DEFAULT orientation is Qt.Vertical, which makes it ignore pure-horizontal
  // wheel events — exactly the two-finger swipe we page with — so the
  // orientation must be Horizontal for the gesture to reach onWheel at all.
  WheelHandler {
    orientation: Qt.Horizontal
    enabled: !!root.islandState && root.islandState.paging
      && root.islandState.pageCount > 1 && !root.islandState.autoOpened
    onWheel: function(event) {
      // Touchpads often deliver only pixelDelta; mice deliver angleDelta.
      // Prefer whichever carries the horizontal movement.
      var dx = event.angleDelta.x
      if (dx === 0) dx = event.pixelDelta.x
      if (dx === 0) return
      if (dx > 0) root.islandState.pagePrev()
      else root.islandState.pageNext()
      event.accepted = true
    }
  }

  // Height reserved below the content for the pager bar. contentPadding is
  // only 12px, so without this strip the pager would overlap the bottom row of
  // whatever view is showing (the media transport, the deck's last row).
  readonly property real pagerStrip: {
    if (!islandState || !islandState.paging || islandState.pageCount <= 1) return 0
    // An automatic appearance is an announcement, not an offer to navigate: no
    // pager until the pointer arrives and promotes it (see IslandState.promoting).
    if (islandState.autoOpened) return 0
    return Style.space(24)
  }

  // Bottom inset for the drag drop bar. The pager owns the lowest strip while
  // paging, so the drop bar sits ABOVE it; otherwise both would be painted over
  // the same bottom band while a control is dragged on the default page.
  readonly property real dropBarBottomInset: root.contentPadding + root.pagerStrip

  // Pager bar: prev arrow · page dots · next arrow. The arrows are the
  // reliable path when a trackpad's horizontal scroll never reaches the
  // surface; the dots jump straight to a page. All three wrap around.
  Row {
    id: pagerBar
    z: 5
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.bottom: parent.bottom
    anchors.bottomMargin: Style.space(4)
    spacing: Style.space(10)
    visible: !!root.islandState && root.islandState.paging
      && root.islandState.pageCount > 1 && !root.islandState.autoOpened
    opacity: visible ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: root.motionFast; easing.type: Easing.OutCubic } }

    Text {
      anchors.verticalCenter: parent.verticalCenter
      text: "‹"
      color: Util.alpha(Color.bar.text, 0.75)
      font.family: Style.font.family
      font.pixelSize: Style.font.title
      MouseArea {
        anchors.fill: parent
        anchors.margins: -Style.space(6)
        onClicked: root.islandState.pagePrev()
      }
    }

    Row {
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(5)
      Repeater {
        model: (!!root.islandState && root.islandState.paging)
          ? root.islandState.pageCount : 0
        delegate: Rectangle {
          required property int index
          width: Style.space(6)
          height: Style.space(6)
          radius: width / 2
          color: index === root.islandState.pageIndex
            ? Color.accent
            : Util.alpha(Color.bar.text, 0.35)
          Behavior on color { ColorAnimation { duration: root.motionFast; easing.type: Easing.OutCubic } }
          MouseArea {
            anchors.fill: parent
            onClicked: root.islandState.goToPage(index)
          }
        }
      }
    }

    Text {
      anchors.verticalCenter: parent.verticalCenter
      text: "›"
      color: Util.alpha(Color.bar.text, 0.75)
      font.family: Style.font.family
      font.pixelSize: Style.font.title
      MouseArea {
        anchors.fill: parent
        anchors.margins: -Style.space(6)
        onClicked: root.islandState.pageNext()
      }
    }
  }

  // --- native views --------------------------------------------------------
  // The map lives on IslandState; this router only registers the components.
  // The media view reads the bar root's shared MediaState so the pill
  // mini-player and this full view always agree on the active track.
  Component {
    id: clockWeatherView
    Views.ClockWeatherView {
      islandState: root.islandState
      islandBar: root.islandBar
    }
  }
  Component {
    id: musicView
    Views.MusicView {
      islandState: root.islandState
      mediaState: root.islandBar ? root.islandBar.mediaState : null
    }
  }
  // The slim strip the island peeks open for a playback change (play/pause, new
  // track, ad). Kept separate from MusicView so the passive appearance stays
  // tiny and the full design remains the reward for asking. The id matches
  // ContextResolver.mediaPeekContextId.
  Component {
    id: mediaPeekView
    Views.MediaPeekView {
      islandState: root.islandState
      mediaState: root.islandBar ? root.islandBar.mediaState : null
      islandBar: root.islandBar
    }
  }
  // One combined quick-settings panel serves all four system widgets: each
  // icon only carries a single toggle plus a short readout, so four separate
  // near-identical notch-scale views would be more chrome than content.
  // Clicking omarchy.audio/.network/.bluetooth/.power thus expands the island
  // with this shared panel, which reads the same live services those panels
  // do. islandBar is injected for the panel's theme colors.
  Component {
    id: quickSettingsView
    Views.QuickSettingsView {
      islandState: root.islandState
      islandBar: root.islandBar
    }
  }
  // The notification tray. Registered for the user's notification widget id so
  // that icon opens the island's own view instead of the widget's hosted popup;
  // the view derives its data from the shell's omarchy.notifications service,
  // not from the widget, so a clone of that widget routes here the same way.
  Component {
    id: notificationsView
    Views.NotificationsView {
      islandState: root.islandState
      islandBar: root.islandBar
    }
  }
  Component {
    id: notificationToastView
    Views.NotificationToastView {
      islandState: root.islandState
      islandBar: root.islandBar
    }
  }
  // Ephemeral overlay shown in place of a page while the resolver's volume
  // transient is live. Registered like any other view, but the router reaches
  // it through islandState.displayedContext, never through a page.
  Component {
    id: volumeView
    Views.VolumeView {
      islandState: root.islandState
    }
  }
  // Round 6 providers: each gets its own bespoke view, never a plugin popup.
  // The microphone context is keyed by the real widget id (omarchy.microphone),
  // so clicking that icon routes here exactly like the page does.
  Component {
    id: microphoneView
    Views.MicrophoneView {
      islandState: root.islandState
      islandBar: root.islandBar
    }
  }
  // Screen recording: reached as a page while a recorder process is alive.
  Component {
    id: screenRecordView
    Views.ScreenRecordingView {
      islandState: root.islandState
      islandBar: root.islandBar
    }
  }
  // Brightness: the resolver's transient overlay, reading the shared
  // BrightnessState off the bar root.
  Component {
    id: brightnessView
    Views.BrightnessView {
      islandState: root.islandState
      islandBar: root.islandBar
    }
  }
  // The default context page: the composed generic surface (clock/weather +
  // controls deck). Served as a page, not a widget view.
  Component {
    id: defaultContextView
    Views.DefaultContextView {
      islandState: root.islandState
      islandBar: root.islandBar
    }
  }
  // The app-sphere window list: one card per window of the chosen app, with
  // live previews and click-to-focus. The reader lives on the island unit, so
  // the list sees the same grouped, screen-filtered model the spheres do. It is
  // a manual context (opened by a sphere click), never a resolved page.
  Component {
    id: windowListView
    Views.WindowListView {
      islandState: root.islandState
      islandBar: root.islandBar
      windowSource: root.islandUnit ? root.islandUnit.windowSource : null
    }
  }

  // Widget grids: the body form of the pill's left/right reveal. Same hosted
  // widgets and prop injection as the bar, laid out as a grid instead of a
  // strip. `side` fixes which layout region each grid renders.
  //
  // These are ALWAYS instantiated — deliberately NOT swapped through the
  // content Loader. A widget's KeyboardPanel anchors to the widget item and
  // keeps its open state on that widget, so any context change that destroyed
  // the grid would kill the anchor mid-open (KeyboardPanel.qml's deferred
  // `root.open` callback then throws "Cannot read property 'open' of null").
  // Keeping both grids alive also avoids re-instantiating every widget on
  // each pill hover. Only the active side is visible, so the body window
  // never maps with both grids painted.
  // The pin the grids lay out by. Solo mode is the primary source; if the
  // solo flag is ever dropped while a real panel is still open, fall back to
  // the tracked panel id so the tile anchoring that panel never moves. The
  // fallback is a no-op for a grid that does not contain that id.
  readonly property string pinnedWidgetId: {
    if (islandState && islandState.soloWidgetId !== "") return islandState.soloWidgetId
    if (islandUnit && islandUnit.pluginPanelOpen) return islandUnit.panelItemId
    return ""
  }

  IslandWidgets {
    id: leftWidgetsGrid
    side: "left"
    islandBar: root.islandBar
    islandUnit: root.islandUnit
    soloWidgetId: root.pinnedWidgetId
    entries: root.islandBar ? root.islandBar.gridEntriesFor("left") : []
    excludedIds: root.islandBar ? root.islandBar.excludedWidgetIds : []
    visible: !!root.islandState && root.islandState.expanded
      && root.islandState.activeContext === root.islandState.gridContextLeft
      && !root.islandState.transientVisible
    anchors {
      top: parent.top
      left: parent.left
      right: parent.right
      margins: root.contentPadding
    }
  }
  IslandWidgets {
    id: rightWidgetsGrid
    side: "right"
    islandBar: root.islandBar
    islandUnit: root.islandUnit
    soloWidgetId: root.pinnedWidgetId
    entries: root.islandBar ? root.islandBar.gridEntriesFor("right") : []
    excludedIds: root.islandBar ? root.islandBar.excludedWidgetIds : []
    visible: !!root.islandState && root.islandState.expanded
      && root.islandState.activeContext === root.islandState.gridContextRight
      && !root.islandState.transientVisible
    anchors {
      top: parent.top
      left: parent.left
      right: parent.right
      margins: root.contentPadding
    }
  }
  // --- drag feedback --------------------------------------------------------
  // Two independent affordances while a tile is dragged, neither of them an
  // overlay on the list:
  //   * the insertion marker shows where the tile lands in a grid (in-grid
  //     reorder AND a positioned cross-side drop);
  //   * the bottom drop bar (below) holds the whole-section targets.
  // Purely visual: the DragHandler keeps the pointer grab, so no input here.
  Item {
    id: dragOverlay
    anchors.fill: parent
    z: 40
    visible: !!root.islandBar && root.islandBar.dragWidgetId !== ""
    // The card is centered in the full-width body window; drag coordinates are
    // window-scene, so the marker needs the card's left offset to line up.
    readonly property real sceneLeft: {
      var monitor = Hyprland.focusedMonitor
      var sw = monitor ? (Number(monitor.width) || 0) : 0
      return sw > 0 ? (sw - dragOverlay.width) / 2 : 0
    }

    // Insertion marker: where the widget will land. In-grid reordering and
    // cross-side drops share it, so moving within a grid reads the same as
    // changing sides.
    Rectangle {
      visible: !!root.islandBar && root.islandBar.dragIndicatorX >= 0 && dragOverlay.visible
      x: Math.round(root.islandBar.dragIndicatorX - dragOverlay.sceneLeft)
      y: Math.round(root.islandBar.dragIndicatorY)
      width: Math.max(2, Style.space(2))
      height: Math.max(2, root.islandBar.dragIndicatorH)
      radius: width / 2
      color: Color.accent
    }
  }

  // --- bottom drop bar ------------------------------------------------------
  // Only while dragging, below the grid. Two targets side by side, split at the
  // bar's centre: moving the tile to the opposite section on the left half, or
  // dropping it into the exclusion list on the right half. A chip dragged out
  // of the exclusion panel gets a single full-width "restore" target instead.
  // Positioned drops use the insertion marker, not this bar.
  Item {
    id: dropBar
    anchors {
      left: parent.left
      right: parent.right
      bottom: parent.bottom
      leftMargin: root.contentPadding
      rightMargin: root.contentPadding
      bottomMargin: root.dropBarBottomInset
    }
    height: root.dropBarHeight
    visible: root.dragging
    opacity: visible ? 1 : 0

    readonly property bool controlDrag: !!root.islandBar
      && root.islandBar.dragKind === "control"
    readonly property bool fromExcluded: !!root.islandBar
      && (root.islandBar.dragSourceSide === "excluded"
        || root.islandBar.dragSourceSide === "control-excluded")
    readonly property string otherSide: (!!root.islandBar
      && root.islandBar.dragSourceSide === "left") ? "right" : "left"
    readonly property int gap: Style.spacing.controlGap
    // A restore (chip) and a deck-control drag each have a single target, so it
    // spans the whole bar; a widget drag keeps the section/exclude split.
    readonly property bool singleTarget: fromExcluded || controlDrag
    readonly property real zoneWidth: singleTarget ? width : Math.max(0, (width - gap) / 2)

    // Publish the bar's rectangle so the bar root can tell a drop on the bar
    // from a drop on the grid (insertion point). Top/Bottom come from tracked
    // geometry (root.height), NOT mapToItem: a Binding over mapToItem does not
    // re-evaluate when the card grows, which is why the zone never highlighted.
    // MidX is window-local; the card is centered in the body window, so the
    // bar's centre equals the window's.
    Binding {
      target: root.islandBar
      property: "dragDropBarTop"
      value: Math.round(root.height - root.dropBarBottomInset - root.dropBarHeight)
      when: !!root.islandBar
    }
    Binding {
      target: root.islandBar
      property: "dragDropBarBottom"
      value: Math.round(root.height - root.dropBarBottomInset)
      when: !!root.islandBar
    }
    Binding {
      target: root.islandBar
      property: "dragDropBarMidX"
      value: {
        var monitor = Hyprland.focusedMonitor
        var sw = monitor ? (Number(monitor.width) || 0) : 0
        return Math.round(sw / 2)
      }
      when: !!root.islandBar
    }

    Rectangle {
      id: moveZone
      // Hidden while a live control is dragged: its only target is exclusion.
      visible: dropBar.fromExcluded || !dropBar.controlDrag
      x: 0
      width: dropBar.fromExcluded ? dropBar.width : dropBar.zoneWidth
      height: parent.height
      radius: Style.cornerRadius
      readonly property bool hot: !!root.islandBar && root.islandBar.dragDropZoneActive
      color: Util.alpha(Color.accent, hot ? 0.30 : 0.08)
      border.width: 1
      border.color: Util.alpha(Color.accent, hot ? 0.85 : 0.35)
      Behavior on color { ColorAnimation { duration: root.motionFast; easing.type: Easing.OutCubic } }
      Behavior on border.color { ColorAnimation { duration: root.motionFast; easing.type: Easing.OutCubic } }

      Text {
        anchors.centerIn: parent
        text: dropBar.fromExcluded
          ? (dropBar.controlDrag ? "Restore control" : "Restore to the grid")
          : (dropBar.otherSide === "left" ? "◀  Move to left section" : "Move to right section  ▶")
        color: Util.alpha(Color.bar.text, moveZone.hot ? 0.95 : 0.55)
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }
    }

    Rectangle {
      id: excludeZone
      visible: !dropBar.fromExcluded
      // A single-target drag (a deck control's exclusion) spans the whole bar.
      x: dropBar.singleTarget ? 0 : dropBar.zoneWidth + dropBar.gap
      width: dropBar.singleTarget ? dropBar.width : dropBar.zoneWidth
      height: parent.height
      radius: Style.cornerRadius
      readonly property bool hot: !!root.islandBar && root.islandBar.dragExcludeZoneActive
      color: Util.alpha(Color.bar.text, hot ? 0.20 : 0.06)
      border.width: 1
      border.color: Util.alpha(Color.bar.text, hot ? 0.70 : 0.25)
      Behavior on color { ColorAnimation { duration: root.motionFast; easing.type: Easing.OutCubic } }
      Behavior on border.color { ColorAnimation { duration: root.motionFast; easing.type: Easing.OutCubic } }

      Text {
        anchors.centerIn: parent
        text: dropBar.controlDrag ? "⊘  Exclude control" : "⊘  Exclude"
        color: Util.alpha(Color.bar.text, excludeZone.hot ? 0.95 : 0.55)
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }
    }
  }

  Component.onCompleted: {
    if (!islandState) return
    // Contexts whose view already shows the time: the pill hides its own time
    // whenever one of these is displayed (see IslandState.bodyShowsClock).
    islandState.markClockFace("omarchy.clock")
    islandState.markClockFace("island.default")
    islandState.setNativeView("omarchy.clock", clockWeatherView)
    islandState.setNativeView("island.default", defaultContextView)
    islandState.setNativeView("omarchy.media", musicView)
    islandState.setNativeView("island.mediaPeek", mediaPeekView)
    islandState.setNativeView("omarchy.audio", quickSettingsView)
    islandState.setNativeView("omarchy.network", quickSettingsView)
    islandState.setNativeView("omarchy.bluetooth", quickSettingsView)
    islandState.setNativeView("omarchy.power", quickSettingsView)
    islandState.setNativeView("omarchy.volume", volumeView)
    islandState.setNativeView("island.brightness", brightnessView)
    islandState.setNativeView("omarchy.microphone", microphoneView)
    islandState.setNativeView("island.screenrecord", screenRecordView)
    islandState.setNativeView("jankeesvw.notification-center", notificationsView)
    islandState.setNativeView("island.notificationToast", notificationToastView)
    // The theme picker is a manual context, not a page: registering it in this
    // map must not add it to ContextResolver.pageIds, so Left/Right keep
    // paging. The open card's Down guard is its only entry (NotchIslandBar),
    // and it is deliberately NOT a clock face — the pill keeps its own time.
    islandState.setNativeView("island.themeSwitcher", themeSwitcherView)
    islandState.setNativeView("island.backgroundPicker", backgroundPickerView)
    // Manual context opened by the app spheres, never a resolved page.
    islandState.setNativeView("island.windowList", windowListView)
  }

  // --- theme picker ---------------------------------------------------------
  // The palette cache is owned HERE, on the island body and outside the content
  // Loader: the Loader destroys its item on every context switch, so a cache
  // living in the view would re-warm the whole theme inventory on every open.
  // Declared below the registration block rather than beside the other
  // components so the registration line numbers the docs cite stay put.
  ThemePalette { id: themePaletteSource }

  Component {
    id: themeSwitcherView
    Views.ThemeSwitcherView {
      islandBar: root.islandBar
      themePalette: themePaletteSource
    }
  }

  // --- background picker ----------------------------------------------------
  // Same ownership rationale as the theme palette: the background inventory
  // (image paths) is cached outside the Loader so a warm-up survives context
  // switches. One instance, shared by every open.
  BackgroundPalette { id: backgroundPaletteSource }

  Component {
    id: backgroundPickerView
    Views.BackgroundPickerView {
      islandBar: root.islandBar
      backgroundPalette: backgroundPaletteSource
    }
  }

  readonly property Component activeComponent: {
    if (!islandState || !islandState.expanded) return null
    // displayedContext is the active page, or the transient overlay while one
    // is live. Grids are manual contexts and never page, so the grid check
    // still reads activeContext safely.
    var contextId = islandState.displayedContext
    // Grid contexts are served by the always-live grids above, never by the
    // Loader: routing them here would destroy the widgets on every switch.
    if (islandState.isGridContext(contextId)) return null
    if (contextId === "") return homeComponent
    var native = islandState.nativeViewFor(contextId)
    if (native) return native
    return fallbackComponent
  }

  function pluginDisplayName(contextId) {
    var id = String(contextId || "")
    var host = root.islandBar
    if (host && typeof host.widgetManifest === "function") {
      var manifest = host.widgetManifest(id)
      if (manifest && manifest.name) return String(manifest.name)
    }
    return id
  }

  // --- window-list keyboard bridge -----------------------------------------
  // The island card is the surface's focus host (it carries the existing
  // Escape handler), so the arrow/digit handlers live there and forward here.
  // The loaded view owns the selection and the numbered quick actions; this
  // card only routes, and only while the window list is the active context.
  readonly property bool windowListActive: !!islandState && islandState.expanded
    && islandState.activeContext === "island.windowList"
    && !islandState.transientVisible

  function windowListMove(delta) {
    if (contentLoader.item) contentLoader.item.moveSelection(delta)
  }

  function windowListFocusDigit(digit) {
    if (contentLoader.item) contentLoader.item.handleDigit(digit)
  }

  // Debug-only diagnostic (read through the unit's debugIslandGeometry readout).
  // Evaluated at call time so the loaded view's real metrics are reported, not a
  // stale snapshot captured at load. Answers "which branch did the router take,
  // and did the loaded view get a non-zero box?" without pointer injection.
  function debugBodySnapshot() {
    var it = contentLoader.item
    var contextId = islandState ? String(islandState.displayedContext || "") : ""
    var kind = "none"
    if (islandState && islandState.expanded) {
      if (islandState.isGridContext(contextId)) kind = "grid"
      else if (contextId === "") kind = "home"
      else kind = islandState.nativeViewFor(contextId) ? "native" : "fallback"
    }
    var snap = {
      kind: kind,
      context: contextId,
      grids: {
        left: leftWidgetsGrid.visible,
        right: rightWidgetsGrid.visible
      },
      cardW: Math.round(root.width),
      cardH: Math.round(root.height),
      pagerStrip: Math.round(root.pagerStrip),
      pagerVisible: pagerBar.visible,
      promoting: !!(islandState && islandState.promoting),
      cardOpacity: Math.round(root.opacity * 100) / 100,
      item: null
    }
    if (!it) return snap
    snap.item = {
      w: Math.round(it.width),
      h: Math.round(it.height),
      implicitW: Math.round(it.implicitWidth),
      implicitH: Math.round(it.implicitHeight),
      opacity: Math.round(it.opacity * 100) / 100,
      visible: it.visible
    }
    return snap
  }

  // Real-panel escape hatch for the fallback view: prefer the live hosted
  // widget's own popup (its KeyboardPanel anchors to the island icon), then
  // the shell-level panel summon for panel-kind plugins.
  function openRealPanel() {
    var id = islandState.displayedContext
    var host = root.islandBar
    if (!host || id === "") return
    var item = typeof host.findPanelWidget === "function" ? host.findPanelWidget(id) : null
    if (item && typeof item.open === "function") {
      item.open()
      return
    }
    if (host.shell && typeof host.shell.summon === "function") host.shell.summon(id, "")
  }

  // Picker stack navigation headers - visible only on the main island view.
  // They offer a clickable, discoverable alternative to the Up/Down keys.
  readonly property bool isMainView: {
    if (!islandState || !islandState.expanded) return false
    if (islandState.transientVisible) return false
    var ctx = String(islandState.displayedContext || "")
    if (ctx === "island.themeSwitcher" || ctx === "island.backgroundPicker") return false
    if (islandState.isGridContext(ctx)) return false
    if (ctx === "island.windowList") return false
    return true
  }

  // Top header: background picker
  Item {
    id: topHeader
    anchors {
      top: parent.top
      left: parent.left
      right: parent.right
      topMargin: Style.spacing.sm
      leftMargin: root.contentPadding
      rightMargin: root.contentPadding
    }
    height: Style.space(18)
    visible: root.isMainView
    opacity: visible ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: root.motionFast; easing.type: Easing.OutCubic } }

    Row {
      anchors.centerIn: parent
      spacing: Style.spacing.sm
      Rectangle {
        width: Math.max(Style.space(24), (topHeader.width - bgLabel.width - parent.spacing * 2) / 2)
        height: 1
        color: Util.alpha(Color.bar.text, 0.15)
        anchors.verticalCenter: parent.verticalCenter
      }
      Text {
        id: bgLabel
        text: "\u2227  background"
        color: topMouse.containsMouse ? Color.accent : Util.alpha(Color.bar.text, 0.55)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        Behavior on color { ColorAnimation { duration: root.motionFast } }
      }
      Rectangle {
        width: Math.max(Style.space(24), (topHeader.width - bgLabel.width - parent.spacing * 2) / 2)
        height: 1
        color: Util.alpha(Color.bar.text, 0.15)
        anchors.verticalCenter: parent.verticalCenter
      }
    }
    MouseArea {
      id: topMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: {
        if (root.islandState) {
          root.islandState.setContext("island.backgroundPicker")
          if (root.islandBar) root.islandBar.markInteraction()
        }
      }
    }
  }

  // Bottom header: theme picker
  Item {
    id: bottomHeader
    anchors {
      bottom: parent.bottom
      left: parent.left
      right: parent.right
      bottomMargin: root.pagerStrip + Style.spacing.sm
      leftMargin: root.contentPadding
      rightMargin: root.contentPadding
    }
    height: Style.space(18)
    visible: root.isMainView
    opacity: visible ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: root.motionFast; easing.type: Easing.OutCubic } }

    Row {
      anchors.centerIn: parent
      spacing: Style.spacing.sm
      Rectangle {
        width: Math.max(Style.space(24), (bottomHeader.width - themeLabel.width - parent.spacing * 2) / 2)
        height: 1
        color: Util.alpha(Color.bar.text, 0.15)
        anchors.verticalCenter: parent.verticalCenter
      }
      Text {
        id: themeLabel
        text: "themes  \u2228"
        color: bottomMouse.containsMouse ? Color.accent : Util.alpha(Color.bar.text, 0.55)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        Behavior on color { ColorAnimation { duration: root.motionFast } }
      }
      Rectangle {
        width: Math.max(Style.space(24), (bottomHeader.width - themeLabel.width - parent.spacing * 2) / 2)
        height: 1
        color: Util.alpha(Color.bar.text, 0.15)
        anchors.verticalCenter: parent.verticalCenter
      }
    }
    MouseArea {
      id: bottomMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: {
        if (root.islandState) {
          root.islandState.setContext("island.themeSwitcher")
          if (root.islandBar) root.islandBar.markInteraction()
        }
      }
    }
  }

  Loader {
    id: contentLoader
    anchors {
      top: topHeader.visible ? topHeader.bottom : parent.top
      bottom: bottomHeader.visible ? bottomHeader.top : parent.bottom
      left: parent.left
      right: parent.right
      topMargin: root.contentPadding
      bottomMargin: root.contentPadding
      leftMargin: root.contentPadding
      rightMargin: root.contentPadding
    }
    sourceComponent: root.activeComponent
  }

  Component {
    id: homeComponent
    Column {
      spacing: Style.spacing.sm

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: "Omaltbar"
        color: Color.bar.text
        font.family: Style.font.family
        font.pixelSize: Style.font.heading
        font.weight: Font.Bold
      }

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: "Click an island icon to open its view"
        color: Util.alpha(Color.bar.text, 0.65)
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }

      Button {
        anchors.horizontalCenter: parent.horizontalCenter
        text: "Close"
        onClicked: root.islandState.collapse()
      }
    }
  }

  Component {
    id: fallbackComponent
    Column {
      spacing: Style.spacing.md

      // Static badge glyph: the widget's own icon stays in the pill row;
      // phase 3 replaces this whole fallback with native views. The glyph is
      // taken from the Nerd Font set the bar already renders (same character
      // used by shell widgets), so it never tofus.
      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: "󰆏"
        color: Color.bar.text
        font.family: Style.font.family
        font.pixelSize: Style.font.display
      }

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: root.pluginDisplayName(root.islandState.displayedContext)
        color: Color.bar.text
        font.family: Style.font.family
        font.pixelSize: Style.font.title
        font.weight: Font.Medium
      }

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        width: Math.min(implicitWidth, root.targetWidth - root.contentPadding * 2)
        text: "No island view yet — open this plugin's panel instead"
        color: Util.alpha(Color.bar.text, 0.55)
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.Wrap
      }

      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.spacing.controlGap

        Button {
          text: "Open panel"
          onClicked: root.openRealPanel()
        }

        Button {
          text: "Dismiss"
          onClicked: root.islandState.collapse()
        }
      }
    }
  }
}
