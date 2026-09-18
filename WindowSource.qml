import QtQuick
import Quickshell
import Quickshell.Hyprland

// The island's single window reader: a non-visual projection of
// `Hyprland.toplevels` grouped by app, filtered to one monitor, that feeds the
// app spheres and the window-list view.
//
// Fully event-driven — a `Connections` on the model for add/remove and one
// delegate `Connections` per toplevel for field-level changes (workspace,
// monitor, IPC object, Wayland handle) — so it never spawns `hyprctl` on a
// tick. `revision` is the recompute trigger the grouping binds to.
//
// One instance lives per island unit (like PillStatusSource), because the
// filter is the unit's own screen: on a multi-monitor setup each screen groups
// only its own windows.
Item {
  id: root

  // The island unit's screen. Only windows on this monitor are grouped (D5).
  property var hostScreen: null
  // App whose windows the window-list view shows; set by the spheres.
  property string selectedAppId: ""
  // Monotonic recompute trigger, bumped by every Hyprland event below.
  property int revision: 0

  readonly property var toplevels: Hyprland.toplevels ? Hyprland.toplevels.values : []

  function bump() {
    root.revision = root.revision + 1
  }

  // Collection add/remove.
  Connections {
    target: Hyprland.toplevels
    function onValuesChanged() { root.bump() }
  }

  // Field-level changes per toplevel: this is what makes the grouping live
  // without polling.
  Instantiator {
    model: Hyprland.toplevels

    delegate: Connections {
      required property var modelData
      target: modelData
      function onWorkspaceChanged() { root.bump() }
      function onMonitorChanged() { root.bump() }
      function onLastIpcObjectChanged() { root.bump() }
      function onWaylandHandleChanged() { root.bump() }
    }
  }

  // ---------------------------------------------------------------- readers
  function waylandFor(toplevel) {
    return toplevel && toplevel.wayland ? toplevel.wayland : null
  }

  function ipcFor(toplevel) {
    var ipc = toplevel && toplevel.lastIpcObject
    return ipc && typeof ipc === "object" ? ipc : {}
  }

  // Wayland appId first, then Hyprland's own class metadata — the same
  // precedence the expose overview uses.
  function appIdFor(toplevel) {
    var wayland = root.waylandFor(toplevel)
    if (wayland && wayland.appId) return String(wayland.appId)
    var ipc = root.ipcFor(toplevel)
    return String(ipc.class || ipc.initialClass || "")
  }

  // 0x-prefixed hex only, after validating the bare address. An empty return
  // means "do not focus" — callers must abort rather than run a command.
  function addressFor(toplevel) {
    var address = String((toplevel && toplevel.address) || "")
    return /^[0-9a-fA-F]+$/.test(address) ? "0x" + address : ""
  }

  function isEligible(toplevel) {
    return !!root.waylandFor(toplevel) && root.ipcFor(toplevel).mapped !== false
  }

  // Desktop-entry icon with the measured fallback chain: byId, then the
  // heuristic lookup for the ids browsers and Electron apps report, then the
  // generic executable glyph (the documented icon-miss behaviour).
  function iconFor(appId) {
    var id = String(appId || "")
    if (id === "") return ""
    var entry = DesktopEntries.byId(id) || DesktopEntries.heuristicLookup(id)
    if (entry && entry.icon) return Quickshell.iconPath(entry.icon, true)
    return Quickshell.iconPath("application-x-executable", true)
  }

  function displayNameFor(appId) {
    var id = String(appId || "")
    if (id === "") return ""
    var entry = DesktopEntries.byId(id) || DesktopEntries.heuristicLookup(id)
    return entry && entry.name ? String(entry.name) : id
  }

  // ---------------------------------------------------------------- grouping
  // [{ appId, icon, name, windows: [toplevel] }], alphabetical by app (D6).
  readonly property var appGroups: {
    var tick = root.revision
    var groups = {}
    var screenName = root.hostScreen ? String(root.hostScreen.name || "") : ""
    var list = root.toplevels
    for (var i = 0; i < list.length; i++) {
      var toplevel = list[i]
      if (!toplevel || !root.isEligible(toplevel)) continue
      if (screenName !== "") {
        var monitor = toplevel.monitor ? String(toplevel.monitor.name || "") : ""
        if (monitor !== screenName) continue
      }
      var appId = root.appIdFor(toplevel)
      if (appId === "") continue
      if (!groups[appId]) {
        groups[appId] = {
          appId: appId,
          icon: root.iconFor(appId),
          name: root.displayNameFor(appId),
          windows: []
        }
      }
      groups[appId].windows.push(toplevel)
    }
    var out = []
    for (var key in groups) out.push(groups[key])
    out.sort(function(a, b) {
      return String(a.appId).localeCompare(String(b.appId))
    })
    return out
  }

  readonly property var selectedAppGroup: {
    var tick = root.revision
    var id = root.selectedAppId
    var list = root.appGroups
    for (var i = 0; i < list.length; i++)
      if (list[i].appId === id) return list[i]
    return null
  }

  readonly property var selectedWindows:
    root.selectedAppGroup ? root.selectedAppGroup.windows : []
}
