import QtQuick

// Single source of truth for the island's expand/collapse state, the active
// context page, and the ephemeral transient overlay. One instance exists per
// screen (created by the island unit inside NotchIslandBar.qml). Visual
// components only read these properties and call the methods below — no
// pill-visibility or hover bookkeeping lives anywhere else.
Item {
  id: root

  // Pure state holder: never paints.
  visible: false

  // Whether the island body is expanded below the notch pill.
  property bool expanded: false

  // --- context pages (the horizontal carousel) -----------------------------
  // pageIds is the ordered page list owned by the context resolver and bound
  // in by the island unit: the active "big" contexts first, the default page
  // last. pageId is the page the user is on. It is stored by identity (not by
  // index) so that a context appearing or disappearing never yanks the user
  // off the page they chose.
  property var pageIds: []
  property string pageId: ""
  // Page the bottom entry (hotkey / dwell) should land on when no explicit
  // preferred id is given. Bound from the resolver's focus list, so a context
  // that is only swipeable (notifications) never becomes the entry page.
  property string entryId: ""
  // Back-reference to the resolver, which remembers the user's last page
  // across a collapse/reopen. Null in bare tests.
  property var pageMemory: null

  // Remember every page the user actually lands on (swipe, dots, entry), so the
  // next open can pre-select it. The guard keeps a page that just disappeared
  // from the resolver from being remembered.
  onPageIdChanged: {
    if (!root.pageMemory || root.pageId === "") return
    if (!root.pageIds || root.pageIds.indexOf(root.pageId) < 0) return
    root.pageMemory.lastPageId = root.pageId
  }

  // True while the body is driven by the resolved page list (bottom entry,
  // media auto-context). Widget-icon clicks and the side grids leave paging
  // off and use manualContext, so the carousel never fights them.
  property bool paging: false

  // Non-paged context: "" -> home view, a native view id, or a grid sentinel.
  property string manualContext: ""

  // --- click-opened island: hover lock + keyboard ownership ----------------
  // True while the island was opened by a click (an indicator circle, an app
  // sphere) rather than by hover, a hotkey or an automatic appearance. While
  // it is set the pointer must not expand/collapse the island nor change the
  // displayed context, and the body surface is allowed to take the keyboard so
  // ESC / arrows / digits work. It is cleared by collapse() and by any
  // hover-owned open (openResolved / reveal), which is exactly when normal
  // hover behaviour must resume.
  property bool clickOpened: false

  // The interaction that opened the island with a click. Kept separate from
  // clickOpened so a context's own dismissal can clear the lock without losing
  // which gesture owned it; currently only "island.windowList" uses it, but the
  // flag is deliberately generic so more click-opened contexts can join.
  property string clickOpenedContext: ""

  // The context the router renders when no transient overlay is up.
  readonly property string activeContext: {
    if (!root.paging) return root.manualContext
    if (root.pageIds && root.pageIds.length > 0) {
      var idx = root.pageIds.indexOf(root.pageId)
      return idx >= 0 ? String(root.pageIds[idx]) : String(root.pageIds[0])
    }
    return ""
  }

  // Number of pages while paging (0 otherwise), and the current page's index.
  readonly property int pageCount:
    (root.paging && root.pageIds) ? root.pageIds.length : 0
  readonly property int pageIndex: {
    if (!root.paging || !root.pageIds) return -1
    return root.pageIds.indexOf(root.pageId)
  }

  // --- transient overlay (volume, brightness...) ---------------------------
  // Ephemeral and deliberately NOT a page: while it lives it replaces the
  // shown view, then the page underneath returns. The resolver owns the TTL
  // and pushes the id in; the island never opens itself for a transient, so it
  // cannot steal focus or reopen after Escape.
  property string transientContext: ""
  // A view that already hosts the transient's control (the quick-settings deck
  // owns the volume and brightness sliders) registers here while it is mounted.
  // Replacing such a view with the overlay would yank the control out from
  // under the user's drag, so the overlay stays down and the view keeps the
  // interaction.
  //
  // Suspension is owned and released explicitly, keyed by a per-instance token.
  // It used to be a plain `Binding { value: true }` inside QuickSettingsView,
  // which latched the property at true after the view was destroyed: QML does
  // not restore a property when its Binding object dies, so once the user had
  // seen the deck every volume/brightness key was silently suppressed (no peek,
  // no overlay). The explicit release in Component.onDestruction cannot latch.
  property var transientSuspenders: ({})
  readonly property bool transientSuspended:
    root.transientSuspenders && Object.keys(root.transientSuspenders).length > 0

  function suspendTransient(token) {
    var key = String(token || "")
    if (!key || root.transientSuspenders[key] === true) return
    var next = {}
    for (var existing in root.transientSuspenders) next[existing] = root.transientSuspenders[existing]
    next[key] = true
    root.transientSuspenders = next
  }

  function releaseTransient(token) {
    var key = String(token || "")
    if (!key || root.transientSuspenders[key] !== true) return
    var next = {}
    for (var existing in root.transientSuspenders) {
      if (existing !== key) next[existing] = root.transientSuspenders[existing]
    }
    root.transientSuspenders = next
  }
  // The overlay is an OSD: it shows over whatever the island is displaying,
  // not only while paging. Requiring `paging` made a key press invisible
  // whenever the island was open on a widget grid or a manual context, which
  // is exactly when a native OSD would still have shown. The grids are hidden
  // while it is up (see DynamicIsland) so the two never overlap.
  //
  // Do NOT make this depend on `autoOpened`: the gate below is reached through
  // the content Loader (a view that claims a suspension token mounts/unmounts
  // with `displayedContext`), so reading `autoOpened` here closes a cycle —
  // QML reports "Binding loop detected for property transientVisible". The
  // ordering that actually matters lives in NotchIslandBar's Connections, which
  // assigns `transientContext` synchronously before the island expands.
  readonly property bool transientVisible:
    root.transientContext !== "" && root.expanded && !root.panelOpen
      && !root.transientSuspended
  readonly property string displayedContext:
    root.transientVisible ? root.transientContext : root.activeContext

  // Contexts whose view already shows the time. Generalises the old
  // "the body is the clock view" special case: the pill hides its own time
  // whenever the body shows time, whatever the view is.
  property var clockFaceIds: ({})
  function markClockFace(contextId) {
    var key = String(contextId || "")
    if (!key || root.clockFaceIds[key] === true) return
    var next = {}
    for (var existing in root.clockFaceIds) next[existing] = root.clockFaceIds[existing]
    next[key] = true
    root.clockFaceIds = next
  }
  readonly property bool bodyShowsClock:
    root.expanded && root.clockFaceIds[root.displayedContext] === true

  // Which side's widget grid the island body is currently showing.
  //   ""      -> no grid (resting pill or a native view)
  //   "left"  -> layout.left widgets laid out in the body as a grid
  //   "right" -> layout.right widgets laid out in the body as a grid
  // Owned here (not by the hover handlers) so every screen's island and its
  // views read one source of truth and the state is cleaned up on collapse.
  property string revealSide: ""

  // Grid contexts live in the same manualContext slot as native views, but
  // under private sentinels no plugin id can collide with. The body router in
  // DynamicIsland maps these to the IslandWidgets grid host.
  readonly property string gridContextLeft: "__island_grid_left"
  readonly property string gridContextRight: "__island_grid_right"

  // Solo mode (Function 2): the id of the single widget whose tile stays
  // centered at the top of the body while that widget's own panel is open.
  // With it set, IslandWidgets lays out only that tile (the other delegates
  // collapse to zero size instead of being destroyed, so the panel's live
  // anchor keeps resolving) and the body must stay mapped. Cleared when the
  // panel closes and on every collapse.
  property string soloWidgetId: ""

  // Injected by the owning island unit: true while a real plugin panel window
  // is open on this screen (panelItem !== null && panelItem.opened === true).
  // This is the authoritative "a panel is up" signal for the collapse policy;
  // it does not depend on hover, on a settle timer, or on soloWidgetId having
  // survived a spurious slot-teardown notification.
  property bool panelOpen: false

  // Whether the current expansion came from an automatic cause (a transient
  // peek, the notification toast, a fresh playback) rather than from the user
  // asking for the island. While true the island must not take keyboard focus:
  // an overlay that yanks the keyboard out of whatever the user is typing in is
  // worse than no overlay. Set by openResolved(_, automatic=true); cleared by
  // every explicit open and on collapse. It is ALSO what hides the pager: a
  // pager is a claim that the user owns what they are looking at, so an
  // announcement gets none until the pointer arrives.
  property bool autoOpened: false

  // True for the beat of a promotion — the pointer reached an automatic
  // appearance and the island is growing from the compact form into the full
  // context. Only then does the card animate its height, so ordinary context
  // changes stay instant.
  property bool promoting: false

  // --- page navigation ------------------------------------------------------
  // Open on the resolved page list. Page 0 is the highest-priority active
  // context (media while a track is present), the default page is last. An
  // optional preferred id wins when the caller knows the context it wants
  // (media auto-context) and the resolver has not listed it yet. Otherwise the
  // page the user last chose wins while it is still available, so reopening the
  // island returns to it; the resolver's entryId is the fallback, and a
  // non-focus page (notifications) can never become the entry page.
  function openResolved(preferredId, automatic) {
    // Automatic opens (transient peek, notification toast, playback) must never
    // steal keyboard focus; explicit ones (dwell, hotkey) may.
    root.autoOpened = automatic === true
    root.revealSide = ""
    // A hover/hotkey open is not the click-opened mode: release its lock so the
    // pointer regains control of this island.
    root.clickOpened = false
    root.clickOpenedContext = ""
    // With a transient live, expand BEFORE writing the page. The body Loader
    // picks its component from displayedContext, which is the transient while one
    // is live and the page otherwise — but `transientVisible` requires `expanded`.
    // Writing paging/pageId while still collapsed therefore let the remembered
    // page mount first: with the memory on `island.default` the deck mounted and
    // claimed its transient-suspension token, which latched the overlay OFF for
    // the whole peek (a key press showed the default page). Expanding first makes
    // the transient the very first thing the Loader sees, so no page mounts.
    // Without a transient the page is written first, as before, so no
    // intermediate component is ever shown for a normal open.
    if (root.transientContext !== "") root.expanded = true
    root.paging = true
    var pages = root.pageIds || []
    var target = String(preferredId || "")
    if (target === "" || pages.indexOf(target) < 0) {
      var remembered = root.pageMemory ? String(root.pageMemory.lastPageId || "") : ""
      target = (remembered !== "" && pages.indexOf(remembered) >= 0)
        ? remembered
        : (root.entryId !== "" ? String(root.entryId) : "")
    }
    if (target !== "" && pages.indexOf(target) >= 0) {
      root.pageId = target
    } else {
      root.pageId = pages.length > 0 ? String(pages[0]) : ""
    }
    root.expanded = true
  }

  function pageNext() {
    if (!root.paging || root.pageCount <= 1) return
    var idx = root.pageIndex
    if (idx < 0) idx = 0
    root.pageId = String(root.pageIds[(idx + 1) % root.pageCount])
  }

  function pagePrev() {
    if (!root.paging || root.pageCount <= 1) return
    var idx = root.pageIndex
    if (idx < 0) idx = 0
    root.pageId = String(root.pageIds[(idx - 1 + root.pageCount) % root.pageCount])
  }

  function goToPage(index) {
    if (!root.paging || !root.pageIds) return
    var i = Number(index)
    if (!isFinite(i) || i < 0 || i >= root.pageIds.length) return
    root.pageId = String(root.pageIds[i])
  }

  // Keep the shown page valid when the resolver's list changes (media starts
  // or stops). Staying on a still-present context is deliberate: the page only
  // changes when the context the user was watching has actually left.
  onPageIdsChanged: {
    if (!root.paging) return
    if (!root.pageIds || root.pageIds.length === 0) {
      root.pageId = ""
      return
    }
    if (root.pageIds.indexOf(root.pageId) < 0) {
      root.pageId = String(root.pageIds[0])
    }
  }

  function enterSolo(id) {
    var next = String(id || "")
    if (next === "") return
    root.soloWidgetId = next
  }

  function clearSolo() {
    if (root.soloWidgetId !== "") root.soloWidgetId = ""
  }

  function isSolo(id) {
    return root.soloWidgetId !== "" && root.soloWidgetId === String(id || "")
  }

  function gridContextFor(side) {
    if (side === "left") return root.gridContextLeft
    if (side === "right") return root.gridContextRight
    return ""
  }

  function isGridContext(contextId) {
    var id = String(contextId || "")
    return id === root.gridContextLeft || id === root.gridContextRight
  }

  // Opening a side both expands the body and records which grid it shows.
  function reveal(side) {
    var next = (side === "left" || side === "right") ? side : ""
    if (next === "") {
      root.clearReveal()
      return
    }
    root.revealSide = next
    root.paging = false
    root.autoOpened = false
    root.clickOpened = false
    root.clickOpenedContext = ""
    var context = root.gridContextFor(next)
    if (root.manualContext !== context) root.manualContext = context
    root.expanded = true
  }

  // Closing the reveal only collapses a grid context: native views (music
  // auto-context, a widget's own island view) are closed by their own policy
  // and must survive the pill's leave-hover cleanup.
  function clearReveal() {
    if (root.revealSide !== "") root.revealSide = ""
    // While a real plugin panel window is open the body must stay put: its
    // widget tile is the panel's live anchor, so collapsing this grid context
    // would hide that anchor and re-anchor the panel to the screen corner.
    if (root.panelOpen) return
    // Solo mode is the transient marker of the same condition; keep it as a
    // second line of defense in case panelOpen has not propagated yet.
    if (root.soloWidgetId !== "") return
    if (root.isGridContext(root.manualContext)) {
      root.expanded = false
      root.manualContext = ""
    }
  }

  // Map of contextId -> Component. DynamicIsland registers its native views
  // through setNativeView() so the map stays owned by the state object and
  // phase 3 can add views without touching any router logic.
  property var nativeViews: ({})
  function nativeViewFor(contextId) {
    var key = String(contextId || "")
    if (key === "") return null
    var views = root.nativeViews
    return views && views[key] ? views[key] : null
  }

  // Reassign (copy-on-write) so bindings on `nativeViews` re-evaluate, the
  // same idiom the bar uses for its click-target and slot registries.
  function setNativeView(contextId, component) {
    var key = String(contextId || "")
    if (!key || !component) return
    var next = {}
    for (var existing in root.nativeViews) next[existing] = root.nativeViews[existing]
    next[key] = component
    root.nativeViews = next
  }

  // Open a manual context. `byClick` marks a click-opened island (an indicator
  // circle or an app sphere): it engages the hover lock and lets the body take
  // the keyboard for ESC / arrows / digits. Hotkeys and widget-icon clicks
  // leave it false and keep the normal hover policy.
  function setContext(contextId, byClick) {
    // A manual view replaces whatever reveal the pointer was holding open and
    // leaves paging, so the carousel never fights an explicit icon click.
    root.revealSide = ""
    root.paging = false
    root.autoOpened = false
    root.manualContext = String(contextId || "")
    root.clickOpened = byClick === true
    root.clickOpenedContext = root.clickOpened ? root.manualContext : ""
    root.expanded = true
  }

  function collapse() {
    root.soloWidgetId = ""
    root.autoOpened = false
    root.clickOpened = false
    root.clickOpenedContext = ""
    root.expanded = false
    root.paging = false
    root.manualContext = ""
    root.pageId = ""
    root.clearReveal()
  }

  // True when this exact context ("" counts as home) is what the island is
  // currently showing. Used for click-to-toggle on widget icons.
  function isActive(contextId) {
    return root.expanded && root.activeContext === String(contextId || "")
  }
}
