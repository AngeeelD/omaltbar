import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
// Reuse the shell bar's layout/geometry helpers verbatim (see the note in
// IslandWidgets.qml: absolute file-URL import of the running shell's tree).
import "file:///usr/share/omarchy/shell/plugins/bar/BarModel.js" as BarModel

// Notch Island — Omarchy bar replacement.
//
// Activated by setting shell.json `bar.id = "local.notch-island"`; the host
// (shell.qml pluginBarLoader) instantiates this file via Loader.source and
// injects omarchyPath/shell/manifest/barWidgetRegistry/pluginRegistry/barConfig
// through configureBar(). That is why the injected properties below are plain
// properties with defaults, not `required`: required properties would abort
// instantiation before the host gets a chance to assign them.
//
// This root object is the `bar` every hosted widget receives. It mirrors the
// surface Bar.qml exposes (colors, run, popout coordination, click targets,
// widget slot registry, summon/hide/isOpen) and adds the island's own click
// routing on top: summonBarWidget first offers the click to an island native
// view, then to the widget's own popup, and only then lets callers fall back.
Item {
  id: root

  // --- injected by shell.qml configureBar() -------------------------------
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var barWidgetRegistry: null
  property var barConfig: null
  property var shell: null
  property var manifest: null
  property var pluginRegistry: null

  property string home: Quickshell.env("HOME")
  property string omarchyConfigDir: home + "/.config/omarchy"

  // --- bar contract: identity + palette ------------------------------------
  // The island is always a top-edge notch, regardless of bar.position: the
  // widgets read `position` to orient their popups, and every anchor here is
  // a top-anchored pill.
  readonly property string position: "top"
  readonly property bool vertical: false
  property string fontFamily: Style.font.family
  property bool foregroundAnimationEnabled: true
  property color themeForeground: Color.bar.text
  property color transparentForeground: Color.bar.text
  property color foreground: themeForeground
  property color barForeground: transparent ? transparentForeground : themeForeground
  property color background: Color.bar.background
  property color urgent: Color.bar.active

  // Strip geometry aliases several widgets/panels read off `bar` (mirrors of
  // the Style.bar tokens the default bar surfaces).
  readonly property int sizeHorizontal: Style.bar.sizeHorizontal
  readonly property int sizeVertical: Style.bar.sizeVertical
  readonly property int iconSlot: Style.bar.iconSlot
  readonly property int iconCanvas: Style.bar.iconCanvas
  readonly property int iconFont: Style.bar.iconFont
  readonly property int statusSlot: Style.bar.statusSlot

  // --- motion language --------------------------------------------------------
  // One shared vocabulary for every island transition, so the pill and the
  // body never drift apart. "Oil-drop" motion: a short, slightly overshooting
  // emergence (OutBack) for anything growing toward the viewer, an elastic
  // settle for anything returning, and short durations so the island still
  // feels instant. Never a bare linear/OutCubic transition where a bubble is
  // wanted.
  readonly property QtObject motion: QtObject {
    // Durations come from the timing block below (bar.islandMotion*), so the
    // settings panel can retune the island's motion language live.
    readonly property int fast: root.motionFastMs
    readonly property int base: root.motionBaseMs
    readonly property int slow: root.motionSlowMs
    // OutBack overshoot: >1 means the value passes its target once before
    // settling. 1.7 is a clearly visible "drop", not a cartoon.
    readonly property real overshoot: 1.7
    // OutElastic settle for anything that "pops" toward the viewer (the body
    // growing out of the pill, the clock and mini-player returning): a marked
    // spring, amplitude 1.0 keeps the overshoot under ~10% so it reads as
    // organic rather than wobbly.
    readonly property real elasticAmplitude: 1.0
    readonly property real elasticPeriod: 0.35
  }

  // barSize = the reserved top strip the island paints (the pill height of
  // the tallest live unit). KeyboardPanel adds this to its bar-strip math, so
  // clicks just under the pill while one of its panels is open keep
  // reaching the island icons instead of dismissing.
  property var _stripHeights: ({})
  readonly property int barSize: {
    var tallest = Style.bar.sizeHorizontal
    for (var key in _stripHeights) tallest = Math.max(tallest, Number(_stripHeights[key]) || 0)
    return tallest
  }
  function setStripHeight(screenKey, height) {
    var next = {}
    for (var existing in _stripHeights) next[existing] = _stripHeights[existing]
    next[String(screenKey)] = height
    _stripHeights = next
  }
  function clearStripHeight(screenKey) {
    var next = {}
    for (var existing in _stripHeights) {
      if (existing !== String(screenKey)) next[existing] = _stripHeights[existing]
    }
    _stripHeights = next
  }

  // --- transparency ----------------------------------------------------------
  property bool requestedTransparent: false
  property bool transparent: false
  property var fallbackBarConfig: ({
    position: "top",
    transparent: false,
    centerAnchor: "",
    layout: { left: [], center: [], right: [] }
  })
  property var layoutConfig: ({ left: [], center: [], right: [] })

  function normalizeLayout(layout) {
    var normalized = Util.normalizeLayout(Util.isPlainObject(layout) ? layout : fallbackBarConfig.layout)
    return {
      left: BarModel.pinTrayToInner(normalized.left, "left"),
      center: BarModel.pinTrayToInner(normalized.center, "center"),
      right: BarModel.pinTrayToInner(normalized.right, "right")
    }
  }

  function applyBarConfig() {
    var config = Util.isPlainObject(barConfig) ? barConfig : fallbackBarConfig
    requestedTransparent = config.transparent === true
    transparent = requestedTransparent
    layoutConfig = normalizeLayout(config.layout)
    root.excludedControlIds = root.normalizeControlIds(config.islandExcludedControls)
    // Push the pill form to every screen. Imperative (not a binding): the click
    // gesture assigns the same property, and a binding would be latched away.
    for (var i = 0; i < _units.length; i++) _units[i].applyPillForm()
  }

  // --- default-page control exclusions (Round 5) ----------------------------
  // The quick-settings deck's controls are NOT bar entries, so their exclusion
  // set cannot ride on setBarWidget. It lives on the bar's own config and is
  // written through shell.mutateShellConfig — the shell API keeps shell.json's
  // single writer, so the file is never hand-edited and the set hot-reloads
  // through barConfig like every other bar option.
  function normalizeControlIds(raw) {
    var out = []
    if (!Array.isArray(raw)) return out
    for (var i = 0; i < raw.length; i++) {
      var id = String(raw[i] || "")
      if (id && out.indexOf(id) === -1) out.push(id)
    }
    return out
  }

  property var excludedControlIds: []

  function controlIsHidden(controlId) {
    var key = String(controlId || "")
    if (!key) return false
    return root.excludedControlIds.indexOf(key) !== -1
  }

  function setControlHidden(controlId, hidden) {
    var key = String(controlId || "")
    if (!key) return false
    var next = []
    for (var i = 0; i < root.excludedControlIds.length; i++) {
      var existing = String(root.excludedControlIds[i])
      if (existing !== key) next.push(existing)
    }
    if (hidden === true) next.push(key)
    if (!root.shell || typeof root.shell.mutateShellConfig !== "function") return false
    root.shell.mutateShellConfig(function(config) {
      if (!Util.isPlainObject(config.bar)) config.bar = {}
      config.bar.islandExcludedControls = next
    })
    return true
  }

  // Manual multiplier over the notch-aligned pill geometry (cutout width and the
  // lateral side slot). 1 = the calibrated 14" MacBook Pro cutout. The display
  // scale is applied automatically on top (see IslandUnit.displayScale /
  // notchScale), so this only corrects panels whose physical cutout differs from
  // the reference. Set through the shell API as shell.json `bar.islandNotchScale`.
  readonly property real barNotchScale: {
    var v = Number(barConfig && barConfig.islandNotchScale)
    return (isFinite(v) && v > 0) ? v : 1
  }

  // --- timing + motion (round 8) --------------------------------------------
  // The island's timing constants are tunable from the settings panel and
  // persisted in shell.json through mutateShellConfig. Each value is clamped to
  // a sane range so a bad one can never freeze or flicker the island. The toast
  // TTL is derived from the toast hold so the snapshot always outlives the
  // island animation (the original 6500/7000 relationship).
  function clampInt(raw, min, max, fallback) {
    var v = Number(raw)
    if (!isFinite(v)) return fallback
    v = Math.round(v)
    return Math.max(min, Math.min(max, v))
  }

  readonly property int transientTtlMs: clampInt(barConfig && barConfig.islandTransientTtlMs, 600, 10000, 1600)
  readonly property int transientLeadMs: clampInt(barConfig && barConfig.islandTransientLeadMs, 0, 1500, 300)
  readonly property int toastHoldMs: clampInt(barConfig && barConfig.islandToastHoldMs, 1000, 15000, 6500)
  readonly property int toastTtlMs: {
    var ttl = clampInt(barConfig && barConfig.islandToastTtlMs, 1500, 20000, root.toastHoldMs + 500)
    return Math.max(ttl, root.toastHoldMs + 200)
  }
  readonly property int motionFastMs: clampInt(barConfig && barConfig.islandMotionFast, 80, 1500, 200)
  readonly property int motionBaseMs: clampInt(barConfig && barConfig.islandMotionBase, 80, 2500, 340)
  readonly property int motionSlowMs: clampInt(barConfig && barConfig.islandMotionSlow, 80, 4000, 560)
  // How long the compact now-playing strip stays up when playback changes on its
  // own (play/pause, new track, ad). Longer than the OSD because a title needs a
  // beat to read.
  readonly property int mediaPeekMs: clampInt(barConfig && barConfig.islandMediaPeekMs, 800, 8000, 2600)

  // --- surface opacity (round 9) --------------------------------------------
  // One value drives BOTH island surfaces: the notch pill (SimulatedNotch) and
  // the island body (DynamicIsland). `bar.transparent` stays the master switch:
  // with it off both paint an opaque Color.bar.background and this is inert;
  // with it on this modulates the alpha. Clamped so the surface can neither
  // disappear nor silently round back to opaque.
  function clampReal(raw, min, max, fallback) {
    if (raw === undefined || raw === null) return fallback
    var v = Number(raw)
    if (!isFinite(v)) return fallback
    return Math.max(min, Math.min(max, v))
  }

  readonly property real islandOpacity: clampReal(barConfig && barConfig.islandOpacity, 0.2, 1.0, 0.72)

  // --- pill form + length (round 9b) ----------------------------------------
  // The pill's resting form and length are user preferences, persisted like
  // every other island knob and set from the panel or the pill's own click.
  // `bar.islandPillCompact` ABSENT means compact: most installs are flat panels
  // with no cutout, so the notch-wide pill (a simulated cutout flanked by the
  // clock wings) is the opt-in look, not the default. The units never bind this
  // directly — they apply it imperatively (IslandUnit.applyPillForm), because a
  // binding assigned over by the click gesture would latch.
  readonly property bool pillCompactMode: {
    var v = barConfig ? barConfig.islandPillCompact : undefined
    return (v === undefined || v === null) ? true : v === true
  }
  // Explicit pill length in logical px. 0 (or absent) keeps the derived
  // geometry: cutout-anchored on a notched panel, the 6.25 aspect elsewhere.
  // Floored at 140 / capped at 900 so a bad value can never break the bar.
  readonly property int pillWidthOverride: {
    var v = Number(barConfig ? barConfig.islandPillWidth : 0)
    if (!isFinite(v) || v <= 0) return 0
    return Math.max(140, Math.min(900, Math.round(v)))
  }

  // --- interaction (round 8) ------------------------------------------------
  // Pill click routing. Default: left click swaps the pill template (split
  // clock ⇄ status dials), right click pins the compact dot. Inverting only
  // swaps the two buttons; the hover zones are unaffected either way.
  readonly property bool invertPillClicks: (barConfig && barConfig.islandInvertPillClicks) === true

  // --- context feature flags (round 8c) --------------------------------------
  // Context ids the user turned off (`bar.islandDisabledContexts`). The resolver
  // filters its pages, entry page and overlays by this list, so a disabled
  // provider stops appearing without any change to the code that detects it.
  readonly property var disabledContexts: {
    var raw = barConfig && barConfig.islandDisabledContexts
    if (!Array.isArray(raw)) return []
    var out = []
    for (var i = 0; i < raw.length; i++) {
      var id = String(raw[i] || "")
      if (id && out.indexOf(id) === -1) out.push(id)
    }
    return out
  }

  // --- weather unit (round 6) -----------------------------------------------
  // The island's clock view toggles °C/°F on click and persists the choice here
  // through the shell config API, so shell.json keeps its single writer. An
  // empty value means "follow the locale", which is the upstream default.
  readonly property string weatherUnit: {
    var unit = String((barConfig && barConfig.islandWeatherUnit) || "")
    return (unit === "metric" || unit === "imperial") ? unit : ""
  }

  function setWeatherUnit(unit) {
    var next = (unit === "metric" || unit === "imperial") ? unit : ""
    if (!root.shell || typeof root.shell.mutateShellConfig !== "function") return
    root.shell.mutateShellConfig(function(config) {
      if (!Util.isPlainObject(config.bar)) config.bar = {}
      config.bar.islandWeatherUnit = next
    })
  }

  function toggleTransparency() {
    var next = !(root.requestedTransparent === true)
    if (root.shell && typeof root.shell.mutateShellConfig === "function") {
      root.shell.mutateShellConfig(function(config) {
        if (!Util.isPlainObject(config.bar)) config.bar = {}
        config.bar.transparent = next
      })
    } else {
      root.requestedTransparent = next
      root.transparent = next
    }
  }

  // --- settings widget entry (round 8) --------------------------------------
  // This plugin is a bar first. PluginRegistry.setEnabled() treats any plugin
  // with the "bar" kind as bar-exclusive: enabling it writes bar.id and returns
  // before the bar-widget placement block runs, so `omarchy bar put <id>`
  // reports success without ever adding the widget to bar.layout. The island
  // therefore reconciles its own bar-widget entry here, through the same
  // mutateShellConfig writer the registry uses. `bar.islandSettingsIcon`
  // (default true) is the authority: turning it off removes the icon from the
  // layout and keeps it off.
  readonly property string pluginId:
    String(root.manifest && root.manifest.id ? root.manifest.id : "local.notch-island")

  readonly property bool settingsIconEnabled: {
    var v = barConfig ? barConfig.islandSettingsIcon : undefined
    return (v === undefined || v === null) ? true : v === true
  }

  // Absolute path of the settings widget file, written into the layout entry as
  // `source:`. A custom-qml entry loads the file directly rather than through
  // the plugin registry — which is what lets the icon survive a switch to the
  // stock bar: PluginRegistry.isEnabled() is bar-exclusive for a plugin with the
  // "bar" kind, so the registered component disappears the moment the island
  // stops being the bar and the icon would be a dead placeholder.
  readonly property string settingsWidgetSource: {
    var dir = (root.manifest && root.manifest.__sourceDir) ? String(root.manifest.__sourceDir) : ""
    if (!dir) dir = "~/.config/omarchy/plugins/" + root.pluginId
    return dir + "/SettingsWidget.qml"
  }

  readonly property string settingsEntrySection: {
    var meta = root.manifest && Util.isPlainObject(root.manifest.barWidget) ? root.manifest.barWidget : null
    var section = meta ? String(meta.defaultSection || "") : ""
    return ["left", "center", "right"].indexOf(section) !== -1 ? section : "right"
  }

  readonly property bool settingsEntryPresent: {
    var sections = ["left", "center", "right"]
    for (var s = 0; s < sections.length; s++) {
      var entries = layoutConfig ? layoutConfig[sections[s]] : null
      if (!Array.isArray(entries)) continue
      for (var i = 0; i < entries.length; i++) {
        var entry = entries[i]
        if (BarModel.entryId(entry) !== root.pluginId) continue
        // A mismatch on `source` counts as absent, so the first run after an
        // upgrade migrates a plain {id} entry to the custom-qml form.
        var settings = BarModel.entrySettings(entry) || {}
        return String(settings.source || "") === root.settingsWidgetSource
      }
    }
    return false
  }

  // Drop every entry for this plugin from a config clone, then prepend one to
  // the default section when `want` is true. Pure: mutates the object it is
  // given, so each caller can fold it into a single mutateShellConfig pass.
  function applySettingsEntry(config, want) {
    var key = root.pluginId
    if (!Util.isPlainObject(config.bar)) config.bar = {}
    if (!Util.isPlainObject(config.bar.layout)) config.bar.layout = { left: [], center: [], right: [] }
    var sections = ["left", "center", "right"]
    for (var s = 0; s < sections.length; s++) {
      if (!Array.isArray(config.bar.layout[sections[s]])) config.bar.layout[sections[s]] = []
    }
    for (var r = 0; r < sections.length; r++) {
      var entries = config.bar.layout[sections[r]]
      for (var i = entries.length - 1; i >= 0; i--) {
        if (BarModel.entryId(entries[i]) === key) entries.splice(i, 1)
      }
    }
    if (want) config.bar.layout[root.settingsEntrySection].unshift({ id: key, source: root.settingsWidgetSource })
  }

  // Reconcile the layout to the flag. Idempotent: it writes nothing when the
  // entry already matches, so a steady state costs zero config writes.
  function syncSettingsWidget() {
    if (!root.shell || typeof root.shell.mutateShellConfig !== "function") return
    if (root.settingsIconEnabled === root.settingsEntryPresent) return
    var want = root.settingsIconEnabled
    root.shell.mutateShellConfig(function(config) {
      root.applySettingsEntry(config, want)
    })
  }

  // Explicit control (settings panel + `omarchy-shell omarchy.bar settingsIcon
  // true|false`). Records the decision so it survives the next reconcile, and
  // applies both changes in one config write.
  function setSettingsIcon(on) {
    if (!root.shell || typeof root.shell.mutateShellConfig !== "function") return
    var next = on === true
    root.shell.mutateShellConfig(function(config) {
      root.applySettingsEntry(config, next)
      if (!Util.isPlainObject(config.bar)) config.bar = {}
      config.bar.islandSettingsIcon = next
    })
  }

  // --- bar selection (round 8) ----------------------------------------------
  // `bar.id` picks the bar implementation the shell loads. An empty id means the
  // stock bar (selectedBarId falls back to omarchy.bar), so a switch is always
  // between two valid bars — there is no intermediate state with no bar at all.
  // Written through mutateShellConfig like every other bar option.
  readonly property string activeBarId: {
    var id = String((barConfig && barConfig.id) || "")
    return id === "" ? "omarchy.bar" : id
  }

  function setActiveBar(id) {
    if (!root.shell || typeof root.shell.mutateShellConfig !== "function") return
    var next = String(id || "")
    root.shell.mutateShellConfig(function(config) {
      if (!Util.isPlainObject(config.bar)) config.bar = {}
      if (next === "" || next === "omarchy.bar" || next === "default") delete config.bar.id
      else config.bar.id = next
    })
  }

  // Toggle a context provider from the CLI (`omarchy-shell omarchy.bar
  // contextFlag omarchy.media false`). The settings panel writes the same key
  // itself so it works from either bar; this is the scriptable path.
  function setContextEnabled(contextId, enabled) {
    var key = String(contextId || "")
    if (!key) return
    if (!root.shell || typeof root.shell.mutateShellConfig !== "function") return
    var on = enabled !== false
    root.shell.mutateShellConfig(function(config) {
      if (!Util.isPlainObject(config.bar)) config.bar = {}
      var current = Array.isArray(config.bar.islandDisabledContexts) ? config.bar.islandDisabledContexts : []
      var next = []
      for (var i = 0; i < current.length; i++) {
        var existing = String(current[i] || "")
        if (existing && existing !== key && next.indexOf(existing) === -1) next.push(existing)
      }
      if (!on) next.push(key)
      if (next.length > 0) config.bar.islandDisabledContexts = next
      else delete config.bar.islandDisabledContexts
    })
  }

  // --- timing / motion config writers (round 8) -----------------------------
  // One place owns the shell.json key names and the value shape, so the settings
  // panel and the CLI (`omarchy-shell omarchy.bar timing <key> <value>`) behave
  // identically. Clamping to the safe range happens on read (clampInt above), so
  // an out-of-range value is corrected rather than rejected.
  readonly property var timingKeys: ({
    islandTransientTtlMs: true,
    islandTransientLeadMs: true,
    islandToastHoldMs: true,
    islandToastTtlMs: true,
    islandMediaPeekMs: true,
    islandMotionFast: true,
    islandMotionBase: true,
    islandMotionSlow: true
  })

  function setTiming(key, value) {
    var name = String(key || "")
    if (root.timingKeys[name] !== true) return false
    var v = Number(value)
    if (!isFinite(v)) return false
    if (!root.shell || typeof root.shell.mutateShellConfig !== "function") return false
    root.shell.mutateShellConfig(function(config) {
      if (!Util.isPlainObject(config.bar)) config.bar = {}
      config.bar[name] = Math.round(v)
    })
    return true
  }

  // Drop every timing/motion override, restoring the built-in defaults.
  function resetTiming() {
    if (!root.shell || typeof root.shell.mutateShellConfig !== "function") return
    root.shell.mutateShellConfig(function(config) {
      if (!Util.isPlainObject(config.bar)) return
      for (var key in root.timingKeys) delete config.bar[key]
    })
  }

  // --- surface opacity writer (round 9) -------------------------------------
  // Persisted as `bar.islandOpacity`. Rounded to two decimals so a slider drag
  // cannot write a float like 0.7000000000000001 into shell.json. An empty
  // value removes the override, which restores the 0.72 default.
  function setIslandOpacity(value) {
    if (!root.shell || typeof root.shell.mutateShellConfig !== "function") return
    var v = Math.round(Number(value) * 100) / 100
    if (!isFinite(v)) return
    root.shell.mutateShellConfig(function(config) {
      if (!Util.isPlainObject(config.bar)) config.bar = {}
      config.bar.islandOpacity = v
    })
  }

  // --- pill form + length writers (round 9b) --------------------------------
  // One writer for the form, shared by the panel and the pill's right click, so
  // the two can never disagree — and so the gesture's choice survives a shell
  // restart (the old pin was session-only). The units pick the value up through
  // the config reload (see applyBarConfig), never as a binding.
  function setPillCompact(on) {
    if (!root.shell || typeof root.shell.mutateShellConfig !== "function") return
    var next = on === true
    root.shell.mutateShellConfig(function(config) {
      if (!Util.isPlainObject(config.bar)) config.bar = {}
      config.bar.islandPillCompact = next
    })
  }

  // Explicit pill length; 0 (or anything non-positive) removes the override and
  // restores the derived geometry.
  function setPillWidth(value) {
    if (!root.shell || typeof root.shell.mutateShellConfig !== "function") return
    var v = Math.round(Number(value))
    var next = (isFinite(v) && v > 0) ? Math.max(140, Math.min(900, v)) : 0
    root.shell.mutateShellConfig(function(config) {
      if (!Util.isPlainObject(config.bar)) return
      if (next > 0) config.bar.islandPillWidth = next
      else delete config.bar.islandPillWidth
    })
  }

  // --- managed Hyprland hotkeys (round 8) -----------------------------------
  // Hyprland has no persistent runtime keybind API, so the island renders a
  // marked block in ~/.config/hypr/bindings.lua from `bar.islandHotkeys`
  // (see hotkeys.sh). The config stays the source of truth in shell.json; the
  // script only mirrors it into the Lua file and reloads Hyprland.
  readonly property string pluginDir: {
    var dir = (root.manifest && root.manifest.__sourceDir) ? String(root.manifest.__sourceDir) : ""
    return dir || (root.omarchyConfigDir + "/plugins/" + root.pluginId)
  }
  readonly property string hotkeyScript: root.pluginDir + "/hotkeys.sh"

  function runHotkeyScript() {
    Quickshell.execDetached(["bash", root.hotkeyScript, "render"])
  }

  function setHotkey(action, keys) {
    var name = String(action || "")
    if (!name) return
    var value = String(keys || "").trim()
    if (!root.shell || typeof root.shell.mutateShellConfig !== "function") return
    root.shell.mutateShellConfig(function(config) {
      if (!Util.isPlainObject(config.bar)) config.bar = {}
      var map = Util.isPlainObject(config.bar.islandHotkeys) ? config.bar.islandHotkeys : {}
      var next = {}
      for (var k in map) next[k] = map[k]
      if (value) next[name] = value
      else delete next[name]
      if (Object.keys(next).length > 0) config.bar.islandHotkeys = next
      else delete config.bar.islandHotkeys
    })
    root.runHotkeyScript()
  }

  onBarConfigChanged: {
    applyBarConfig()
    syncSettingsWidget()
  }

  // --- tooltips: present-but-inert -------------------------------------------
  // WidgetButton/BarIconButton call showTooltip/hideTooltip on every hover.
  // The notch pill is too small to also carry tooltips, so the island exposes
  // the API as safe no-ops instead of letting widgets call into undefined.
  function showTooltip(target, text) { }
  function hideTooltip(target) { }
  function clearTooltip() { }

  // --- popout coordination (same single-active-popout model as Bar.qml) -----
  property var activePopout: null
  property var clickTargets: []
  property var moduleSlots: []

  function requestPopout(owner) {
    if (activePopout === owner) return
    if (activePopout) {
      if ("closeForPopoutSwitch" in activePopout) activePopout.closeForPopoutSwitch()
      else if ("close" in activePopout) activePopout.close()
    }
    activePopout = owner
  }

  function releasePopout(owner) {
    if (activePopout === owner) activePopout = null
  }

  function registerClickTarget(target) {
    if (!target || clickTargets.indexOf(target) !== -1) return
    var next = clickTargets.slice()
    next.push(target)
    clickTargets = next
  }

  function unregisterClickTarget(target) {
    clickTargets = clickTargets.filter(function(item) { return item !== target })
  }

  function targetWindow(target) {
    return target && target.QsWindow ? target.QsWindow.window : null
  }

  function targetBelongsToWindow(target, window) {
    return !!target && !!window && targetWindow(target) === window
  }

  // Position of an item inside its own island surface. KeyboardPanel reaches
  // the same result through the native QsWindow method; this is the
  // bar-object convenience with null guards.
  function itemPosition(item) {
    var window = targetWindow(item)
    if (!window || typeof window.itemPosition !== "function") return Qt.point(0, 0)
    return window.itemPosition(item)
  }

  // --- widget slot registry (fed by IslandWidgets delegates) ----------------
  function registerModuleSlot(slot) {
    if (!slot || moduleSlots.indexOf(slot) !== -1) return
    var next = moduleSlots.slice()
    next.push(slot)
    moduleSlots = next
  }

  function unregisterModuleSlot(slot) {
    moduleSlots = moduleSlots.filter(function(item) { return item !== slot })
  }

  function moduleWidgets(pluginId) {
    var id = String(pluginId || "")
    var items = []
    if (!id) return items
    for (var i = 0; i < moduleSlots.length; i++) {
      var slot = moduleSlots[i]
      if (!slot || !slot.activeItem || slot.moduleName !== id) continue
      items.push(slot.activeItem)
    }
    return items
  }

  function slotScreenName(slot) {
    var window = slot ? targetWindow(slot.activeItem) : null
    return window && window.screen ? String(window.screen.name || "") : ""
  }

  function focusedScreenName() {
    var monitor = Hyprland.focusedMonitor
    return monitor ? String(monitor.name || "") : ""
  }

  // Same resolution ladder as Bar.qml: live slots for the id that expose
  // open/close/opened, narrowed by BarModel.pickPanelSlot (open copy first,
  // then the focused monitor's copy).
  function findPanelWidget(pluginId) {
    var id = String(pluginId || "")
    if (!id) return null
    var candidates = []
    for (var i = 0; i < moduleSlots.length; i++) {
      var slot = moduleSlots[i]
      if (!slot || !slot.activeItem) continue
      if (slot.moduleName !== id) continue
      var item = slot.activeItem
      if (typeof item.open !== "function" || typeof item.close !== "function" || item.opened === undefined) continue
      candidates.push({ slot: slot, screenName: slotScreenName(slot), opened: item.opened === true })
    }
    var chosen = BarModel.pickPanelSlot(candidates, focusedScreenName())
    return chosen ? chosen.activeItem : null
  }

  function entryId(entry) {
    return BarModel.entryId(entry)
  }

  function entrySettings(entry) {
    return BarModel.entrySettings(entry)
  }

  // Manifest of the plugin a layout entry refers to, for widgets that
  // declare a `manifest` property (Bar.qml itself only injects
  // bar/moduleName/settings — the island additionally resolves the widget's
  // own manifest so island views and fallback chrome can label themselves).
  function widgetManifest(pluginId) {
    var reg = root.pluginRegistry
    if (!reg || !reg.installedPlugins) return null
    var id = String(pluginId || "")
    if (!id) return null
    var direct = reg.installedPlugins[id]
    if (direct) return direct
    return reg.installedPlugins[Util.canonicalWidgetId(id)] || null
  }

  // --- centered plugin windows ---------------------------------------------
  // The one-line master switch. When true, a hosted widget's own KeyboardPanel
  // is anchored to a hidden clone ("ghost") of that widget placed at the pill's
  // horizontal center, so the panel lands centered under the notch instead of
  // under its grid cell. Set to false to fall back to the live grid instance
  // everywhere (pre-ghost behavior).
  readonly property bool centeredPluginAnchor: false

  // Registered widget Component for a layout id, read the same way
  // IslandWidgets reads its slots. Null for custom (qml/command) modules and
  // for ids the host registry does not know.
  function widgetComponent(pluginId) {
    var registry = root.barWidgetRegistry
    var widgets = registry ? registry.widgets : null
    var id = String(pluginId || "")
    if (!widgets || !id) return null
    var registered = widgets[Util.canonicalWidgetId(id)]
    return registered && registered.component ? registered.component : null
  }

  // Normalized layout entry for an id across all regions. The ghost needs the
  // same settings/entry the grid slot was injected with, so its internal
  // KeyboardPanel builds identical content.
  function layoutEntry(pluginId) {
    var id = String(pluginId || "")
    if (!id || !layoutConfig) return null
    var regions = ["left", "center", "right"]
    for (var r = 0; r < regions.length; r++) {
      var entries = layoutConfig[regions[r]]
      if (!Array.isArray(entries)) continue
      for (var i = 0; i < entries.length; i++) {
        if (String(BarModel.entryId(entries[i]) || "") === id) return entries[i]
      }
    }
    return null
  }

  // One fallback log per id, so a widget the ghost cannot host reports the
  // live-widget fallback once instead of on every open.
  property var _anchorFallbackLogged: ({})
  function logAnchorFallback(pluginId) {
    var id = String(pluginId || "")
    if (root._anchorFallbackLogged[id]) return
    var next = {}
    for (var key in root._anchorFallbackLogged) next[key] = root._anchorFallbackLogged[key]
    next[id] = true
    root._anchorFallbackLogged = next
    console.log("[notch-island] centered anchor unavailable, using live widget: " + id)
  }

  // Last-resort open used by the async ghost path when the clone turns out not
  // to be a panel widget or fails to open. Opens the live grid instance (the
  // pre-ghost behavior) and lets the unit retreat around it.
  function openLivePanelFallback(pluginId, unit) {
    var id = String(pluginId || "")
    var item = findPanelWidget(id)
    if (!item || typeof item.open !== "function") return false
    root.logAnchorFallback(id)
    item.open()
    if (unit && item.opened === true) unit.adoptLivePanel(id, item)
    return true
  }

  function panelWidgetIdAt(region, index) {
    var entries = layoutConfig ? layoutConfig[String(region || "")] : null
    if (!Array.isArray(entries)) return ""
    var entry = entries[Math.round(Number(index)) - 1]
    return entry === undefined ? "" : String(BarModel.entryId(entry) || "")
  }

  // Widgets NOT hosted in the island grid. The ONLY source is the per-entry
  // `islandHidden` setting, so the list is managed from the island UI (the
  // "Excluded" section header) and persisted on the widget's own bar entry
  // through the same shell API as islandPinned:
  //   omarchy-shell shell setBarWidget <id> islandHidden true '{}'
  // Nothing is hardcoded here.
  readonly property var excludedWidgetIds: {
    var out = []
    var cfg = root.layoutConfig
    if (cfg) {
      var sides = ["left", "right"]
      for (var s = 0; s < sides.length; s++) {
        var entries = cfg[sides[s]]
        if (!Array.isArray(entries)) continue
        for (var i = 0; i < entries.length; i++) {
          var id = String(BarModel.entryId(entries[i]) || "")
          if (id && root.entryIsHidden(id)) out.push(id)
        }
      }
    }
    return out
  }

  readonly property var excludedFromGrid: {
    var out = {}
    var ids = root.excludedWidgetIds
    for (var i = 0; i < ids.length; i++) out[ids[i]] = true
    return out
  }

  function entryIsHidden(id) {
    var key = String(id || "")
    if (!key) return false
    var settings = root.entrySettingsFor(key)
    return !!(settings && settings.islandHidden === true)
  }

  // Toggle a widget's membership in the exclusion list; used by the island's
  // drag gestures. Returns true when the setting was written.
  function setWidgetHidden(id, hidden) {
    var key = String(id || "")
    if (!key) return false
    var reg = root.pluginRegistry
    if (!reg || typeof reg.setBarWidget !== "function") return false
    return reg.setBarWidget(key, "islandHidden", hidden === true, {}) === ""
  }

  function gridEntriesFor(side) {
    var entries = layoutConfig ? layoutConfig[String(side || "")] : []
    if (!Array.isArray(entries)) return []
    var out = []
    for (var i = 0; i < entries.length; i++) {
      var id = String(BarModel.entryId(entries[i]) || "")
      if (root.excludedFromGrid[id] === true) continue
      out.push(entries[i])
    }
    return out
  }

  // --- pinned-to-top widgets (right-click gesture) ---------------------------
  // A pinned widget leaves the grid and renders as its own full-width row at
  // the top of the island. Persisted on the widget's own bar entry as
  // `islandPinned`, through the same setBarWidget the shell's omarchy.bar IPC
  // exposes, so it survives a shell restart and shell.json keeps one writer.
  function entrySettingsFor(id) {
    var key = String(id || "")
    if (!key || !layoutConfig) return null
    var sides = ["left", "right"]
    for (var s = 0; s < sides.length; s++) {
      var entries = layoutConfig[sides[s]]
      if (!Array.isArray(entries)) continue
      for (var i = 0; i < entries.length; i++) {
        if (String(BarModel.entryId(entries[i]) || "") === key)
          return BarModel.entrySettings(entries[i])
      }
    }
    return null
  }

  function isWidgetPinned(id) {
    var settings = root.entrySettingsFor(id)
    return !!(settings && settings.islandPinned === true)
  }

  function togglePinnedWidget(id) {
    var key = String(id || "")
    if (!key) return false
    var reg = root.pluginRegistry
    if (!reg || typeof reg.setBarWidget !== "function") return false
    var next = !root.isWidgetPinned(key)
    var error = reg.setBarWidget(key, "islandPinned", next, {})
    return error === ""
  }

  // --- island grid drag & drop ----------------------------------------------
  // Reorder/edit the bar layout from inside the island grid. A tile is dragged
  // with a DragHandler (see IslandWidgets.qml): the handler does not consume
  // the press until the pointer passes its threshold, so a plain click still
  // reaches the hosted widget (workspaces, menu, command onClick) exactly as
  // before. Dropping over the opposite half of the body moves the widget into
  // that side's set and persists it through the shell's own PluginRegistry —
  // the same implementation the `omarchy.bar` IpcHandler (moveBarWidget /
  // putBarWidget / setBarWidget) exposes, so shell.json sees one writer.
  // What is being dragged, so the shared drag machinery can route the release:
  // "widget" = a grid tile/pinned row/excluded chip (reorder + exclude), and
  // "control" = a default-page deck control (exclude + restore only, no
  // insertion point). Empty while nothing is dragged.
  property string dragKind: ""
  property string dragWidgetId: ""
  property string dragSourceSide: ""
  property string dragTargetSide: ""
  // Insertion point: the id to insert BEFORE ("" appends), plus the scene-space
  // rectangle of the insertion marker the body renders.
  property string dragTargetBefore: ""
  property real dragSceneX: 0
  property real dragSceneY: 0
  property real dragIndicatorX: -1
  property real dragIndicatorY: 0
  property real dragIndicatorH: 0
  // Bottom drop bar scene bounds, published by DynamicIsland while dragging.
  property real dragDropBarTop: 0
  property real dragDropBarBottom: 0
  // Window-local X of the bar's centre, splitting its two targets.
  property real dragDropBarMidX: 0
  property bool dragDropZoneActive: false
  // The bar's second (exclusion) target is hot.
  property bool dragExcludeZoneActive: false
  // True while the pointer resolved a real insertion point (a nearest grid
  // cell). This distinguishes "append at the end" (before === "", a target WAS
  // found) from "no drop target at all" (before === "", nothing found). The
  // release handler must not conflate them: dropping to the right of the last
  // cell is a legitimate reorder to the end, not a no-op.
  property bool dragTargetFound: false

  function widgetSideOf(id) {
    var key = String(id || "")
    if (!key || !layoutConfig) return ""
    var sides = ["left", "right"]
    for (var s = 0; s < sides.length; s++) {
      var entries = layoutConfig[sides[s]]
      if (!Array.isArray(entries)) continue
      for (var i = 0; i < entries.length; i++) {
        if (String(BarModel.entryId(entries[i]) || "") === key) return sides[s]
      }
    }
    return ""
  }

  function beginWidgetDrag(id, side) {
    var key = String(id || "")
    if (!key) return
    dragKind = "widget"
    dragWidgetId = key
    dragSourceSide = String(side || widgetSideOf(key) || "")
    dragTargetSide = dragSourceSide
  }

  // Start a deck-control drag. `fromExcluded` distinguishes pulling a chip out
  // of the "Excluded" panel (restore) from dragging a live control (exclude).
  // Both reuse the widget drag slot and drop bar; only the release semantics
  // differ (see endWidgetDrag).
  function beginControlDrag(controlId, fromExcluded) {
    var key = String(controlId || "")
    if (!key) return
    dragKind = "control"
    dragWidgetId = key
    var side = fromExcluded === true ? "control-excluded" : "control"
    dragSourceSide = side
    dragTargetSide = side
    dragTargetBefore = ""
    dragTargetFound = false
  }

  function updateWidgetDrag(sceneX, sceneY) {
    if (dragWidgetId === "") return
    dragSceneX = Number(sceneX) || 0
    dragSceneY = Number(sceneY) || 0

    // Control drags never resolve an in-grid insertion point: the only targets
    // are the exclusion drop (live control) or restore-anywhere (excluded
    // chip). Track the drop bar so the body can light the matching zone.
    if (dragKind === "control") {
      var overControlBar = dragDropBarBottom > dragDropBarTop
        && dragSceneY >= dragDropBarTop && dragSceneY <= dragDropBarBottom
      dragTargetSide = dragSourceSide
      dragTargetBefore = ""
      dragTargetFound = false
      dragIndicatorX = -1
      dragIndicatorY = 0
      dragIndicatorH = 0
      dragDropZoneActive = dragSourceSide === "control-excluded" && overControlBar
      dragExcludeZoneActive = dragSourceSide === "control" && overControlBar
      return
    }

    // A chip dragged out of the exclusion panel only ever goes back into the
    // grid: it has no source section to reorder. Highlight the bar's restore
    // target while over it; release restores wherever the pointer is.
    if (dragSourceSide === "excluded") {
      dragDropZoneActive = dragDropBarBottom > dragDropBarTop
        && dragSceneY >= dragDropBarTop && dragSceneY <= dragDropBarBottom
      dragExcludeZoneActive = false
      dragTargetSide = "excluded"
      dragTargetBefore = ""
      dragIndicatorX = -1
      dragIndicatorY = 0
      dragIndicatorH = 0
      return
    }

    // Cross-section is only ever requested through the bottom bar; inside a
    // grid the drop always reorders the VISIBLE (source) side. Deriving the
    // side from the pointer's screen half misfired: the left grid's own
    // right-hand columns sit past the screen centre, so an in-grid drop there
    // was sent to the other section.
    // The bar carries two targets side by side: the section move on its left
    // half, the exclusion drop on its right half.
    if (dragDropBarBottom > dragDropBarTop
        && dragSceneY >= dragDropBarTop && dragSceneY <= dragDropBarBottom) {
      var leftHalf = dragSceneX < dragDropBarMidX
      dragDropZoneActive = leftHalf
      dragExcludeZoneActive = !leftHalf
      dragTargetSide = leftHalf
        ? (dragSourceSide === "left" ? "right" : "left")
        : "excluded"
      dragTargetBefore = ""
      dragIndicatorX = -1
      dragIndicatorY = 0
      dragIndicatorH = 0
      return
    }
    dragDropZoneActive = false
    dragExcludeZoneActive = false
    dragTargetSide = dragSourceSide
    dragTargetFound = false

    // Nearest CELL (container) on the source side decides the insertion point.
    // The slot item measures the widget's natural footprint, not its cell, so
    // measuring the cell is what puts the marker in the gap BETWEEN containers
    // instead of inside one.
    var best = null
    var bestDist = Infinity
    for (var i = 0; i < moduleSlots.length; i++) {
      var s = moduleSlots[i]
      if (!s || !s.activeItem || s.gridSide !== dragTargetSide) continue
      if (String(s.moduleName) === dragWidgetId) continue
      var container = (s.parent && s.parent.width !== undefined) ? s.parent : s
      if (!(container.width > 0) || !(container.height > 0)) continue
      var p = { x: container.x, y: container.y }
      try { p = container.mapToItem(null, 0, 0) } catch (e) {}
      var cx = p.x + container.width / 2
      var cy = p.y + container.height / 2
      // Horizontal dominates; the vertical term is weighted so a cell in the
      // same row wins over one merely closer in x on another row.
      var d = Math.abs(cx - dragSceneX) + Math.abs(cy - dragSceneY) * 2
      if (d < bestDist) { bestDist = d; best = { slot: s, container: container, p: p, cx: cx } }
    }
    if (best) {
      dragTargetFound = true
      var gap = Style.space(3)
      var after = dragSceneX >= best.cx
      dragIndicatorX = Math.round(after
        ? best.p.x + best.container.width + gap
        : best.p.x - gap)
      dragIndicatorY = Math.round(best.p.y + Style.space(3))
      dragIndicatorH = Math.round(best.container.height - Style.space(6))
      dragTargetBefore = after
        ? nextIdAfter(dragTargetSide, String(best.slot.moduleName))
        : String(best.slot.moduleName)
    } else {
      dragIndicatorX = -1
      dragIndicatorY = 0
      dragIndicatorH = 0
      dragTargetBefore = ""
      dragTargetFound = false
    }
  }

  function nextIdAfter(side, name) {
    var entries = layoutConfig ? layoutConfig[String(side || "")] : null
    if (!Array.isArray(entries)) return ""
    var found = false
    for (var i = 0; i < entries.length; i++) {
      var id = String(BarModel.entryId(entries[i]) || "")
      if (found) return id
      if (id === name) found = true
    }
    return ""
  }

  function endWidgetDrag() {
    var id = dragWidgetId
    var kind = dragKind
    var target = dragTargetSide
    var source = dragSourceSide
    var before = dragTargetBefore
    var found = dragTargetFound
    var excludeHot = dragExcludeZoneActive
    dragKind = ""
    dragWidgetId = ""
    dragSourceSide = ""
    dragTargetSide = ""
    dragTargetBefore = ""
    dragTargetFound = false
    dragIndicatorX = -1
    dragDropZoneActive = false
    dragExcludeZoneActive = false
    if (!id) return

    // Control drags: a live control is excluded only when released over the
    // exclusion target; an excluded chip restores wherever it is released (its
    // deck slot never moved, so it lands back in place).
    if (kind === "control") {
      if (source === "control-excluded") root.setControlHidden(id, false)
      else if (excludeHot) root.setControlHidden(id, true)
      return
    }

    // A chip dragged out of the panel restores to the grid, wherever it was
    // released. Its layout slot never changed, so it lands back in place.
    if (source === "excluded") {
      root.setWidgetHidden(id, false)
      return
    }
    if (!target) return
    // A grid tile dropped on the bar's exclusion target leaves the grid.
    if (target === "excluded") {
      root.setWidgetHidden(id, true)
      return
    }
    // Reordering inside one grid still counts. Only a drop with NO resolved
    // insertion point, or one whose insertion point is the dragged id itself,
    // is a no-op. An empty `before` WITH a found target means "append to the
    // end" and must be honoured (the old check swallowed it).
    if (target === source && (!found || before === id)) return
    moveWidgetToSide(id, target, before)
  }

  // Move the widget to the destination section, inserting before `beforeId`
  // (append when empty). Persisted through the same PluginRegistry the shell's
  // `omarchy.bar` IpcHandler exposes, so shell.json sees one writer.
  function moveWidgetToSide(id, side, beforeId) {
    var key = String(id || "")
    var dest = String(side || "")
    if (!key || !dest) return false
    var reg = root.pluginRegistry
    if (reg && typeof reg.moveBarWidget === "function") {
      var placement = { section: dest }
      var rel = String(beforeId || "")
      if (rel && rel !== key) {
        placement.before = rel
      } else {
        var entries = layoutConfig && Array.isArray(layoutConfig[dest]) ? layoutConfig[dest] : []
        placement.index = entries.length
      }
      var error = reg.moveBarWidget(key, placement)
      return error === ""
    }
    return false
  }

  function debugBarGeometry() {
    var out = []
    for (var i = 0; i < moduleSlots.length; i++) {
      var slot = moduleSlots[i]
      if (!slot || !slot.activeItem) continue
      var point = { x: slot.x, y: slot.y }
      try {
        point = slot.mapToItem(null, 0, 0)
      } catch (e) {
      }
      out.push({
        id: slot.moduleName,
        section: slot.gridSide,
        x: Math.round(point.x),
        y: Math.round(point.y),
        width: Math.round(slot.width),
        height: Math.round(slot.height),
        cellWidth: slot.parent ? Math.round(slot.parent.width) : 0,
        cellHeight: slot.parent ? Math.round(slot.parent.height) : 0,
        visible: slot.visible === true && slot.width > 0 && slot.height > 0,
        itemVisible: slot.activeItem.visible === true,
        itemWidth: Math.round(slot.activeItem.implicitWidth || 0),
        itemHeight: Math.round(slot.activeItem.implicitHeight || 0)
      })
    }
    return out
  }

  // --- commands --------------------------------------------------------------
  function run(command) {
    if (!command) return
    Util.execDetached(command)
  }

  function runProcess(process) {
    if (!process.running)
      process.running = true
  }

  // --- island click routing on top of the bar contract -----------------------
  // summonBarWidget mirrors Bar.qml's signature and ladder order exactly:
  //   1. live widget popup   -> let the widget open its own KeyboardPanel
  //                             (anchored to its island slot item)
  //   2. native island view  -> expand the island with that view
  //   3. nothing openable    -> false, so shell.summon can reach the
  //                             panel-kind loader instead
  // Panel-first is deliberate: a widget that owns a real popup (clock, audio,
  // network, …) must open that surface when summoned, even when the island
  // also carries a native view for the same id. The island's own clock route
  // (the clock-hover dwell, bottomExpandTimer) does not go through
  // here, so it keeps opening the native view. Hotkeys (shell.summon) share
  // this function, so they now open the widget's real panel first too — the
  // intentional consequence of keeping a single ladder.
  function summonBarWidget(pluginId) {
    var id = String(pluginId || "")
    if (!id) return false
    var unit = focusedIslandUnit()
    // Panel-first: only an id with a live panel widget is a candidate. A panel
    // widget opens through the centered ghost when possible (island steps
    // aside, panel lands under the notch); otherwise the live grid instance is
    // used, the previous behavior, logged once per id.
    var item = findPanelWidget(id)
    if (item && typeof item.open === "function") {
      if (root.centeredPluginAnchor && unit && unit.openCenteredPanel(id)) return true
      if (root.centeredPluginAnchor) root.logAnchorFallback(id)
      item.open()
      if (unit) unit.adoptLivePanel(id, item)
      return true
    }
    if (unit && !!unit.islandState.nativeViewFor(id)) {
      unit.islandState.setContext(id)
      return true
    }
    return false
  }

  function hideBarWidget(pluginId) {
    var id = String(pluginId || "")
    var unit = focusedIslandUnit()
    if (unit && unit.islandState.isActive(id)) {
      unit.islandState.collapse()
      return true
    }
    // A centered ghost (or an adopted live panel) is not in the module-slot
    // registry, so it must be closed through the unit's tracked item first.
    if (unit && unit.panelItemId === id && unit.panelItem
        && typeof unit.panelItem.close === "function") {
      unit.panelItem.close()
      return true
    }
    var item = findPanelWidget(id)
    if (!item || typeof item.close !== "function") return false
    item.close()
    return true
  }

  function isBarWidgetOpen(pluginId) {
    var id = String(pluginId || "")
    var unit = focusedIslandUnit()
    if (unit && unit.islandState.isActive(id)) return true
    if (unit && unit.panelItemId === id && unit.panelItem && unit.panelItem.opened === true) return true
    var item = findPanelWidget(id)
    return !!item && item.opened === true
  }

  // --- island-first click policy ---------------------------------------------
  // Context ids that own a bespoke island view and should win over the widget's
  // own upstream panel on an icon click. Everything NOT listed keeps the
  // panel-first ladder in handleWidgetClick, so a widget with a real popup is
  // never shadowed. An id only qualifies when a native view is actually
  // registered for it (IslandState.nativeViewFor), so naming an id here is
  // harmless until its view exists. Editable in one place.
  // Configurable through the shell API (shell.json `bar.islandFirstContexts`):
  //   omarchy-shell omarchy.bar islandFirst "omarchy.network,omarchy.bluetooth"
  // EMPTY (the default) disables island-first entirely: every widget icon opens
  // the widget's own upstream panel, never a bespoke island view. That is the
  // requested behaviour — the island's own controls are reached through the
  // island itself (pill hover, hotkey, the default page), not by hijacking a
  // bar widget's click. Opt an id back in only when its bespoke view should win
  // the click; an id still needs a registered native view to qualify.
  readonly property var defaultIslandFirstContexts: []
  readonly property var islandFirstContextIds: {
    var raw = barConfig && barConfig.islandFirstContexts
    if (!Array.isArray(raw)) return root.defaultIslandFirstContexts
    var out = []
    for (var i = 0; i < raw.length; i++) {
      var id = String(raw[i] || "")
      if (id && out.indexOf(id) === -1) out.push(id)
    }
    return out
  }

  function isIslandFirst(pluginId) {
    var id = String(pluginId || "")
    if (!id || !Array.isArray(root.islandFirstContextIds)) return false
    return root.islandFirstContextIds.indexOf(id) !== -1
  }

  // Island-icons' own click entry point (IslandWidgets left click). Unlike
  // summonBarWidget (the hotkey ladder), a widget icon click prefers the
  // widget's own popup. With centeredPluginAnchor on, that popup is opened
  // from the lazy ghost clone in the pill, so it lands centered under the
  // notch and the grid reveal can be retired safely: the ghost — not the grid
  // item — is the KeyboardPanel's anchor, so hiding the body no longer risks
  // the anchor item mid-open. When the ghost cannot host the id, or the switch
  // is off, this falls back to the live grid instance (W9 path). Only when the
  // widget has no panel does it fall back to the island's native view, and
  // only when that is absent to the generic fallback body. Re-clicking the
  // icon of the currently-shown native context closes it. `sourceUnit` is the
  // unit whose icon was clicked; hotkey-driven paths omit it and target the
  // focused screen.
  function handleWidgetClick(pluginId, sourceUnit) {
    var id = String(pluginId || "")
    if (!id) return
    var unit = sourceUnit || focusedIslandUnit()
    if (!unit) return
    unit.markInteraction()
    var state = unit.islandState

    if (state.isActive(id)) {
      state.collapse()
      return
    }

    // Island-first: an id with a registered bespoke view that is ALSO listed in
    // islandFirstContextIds opens that view instead of the upstream panel. This
    // is what lets the bespoke deck (QuickSettingsView) win the click for the
    // system widgets. Ids not listed — or listed but without a native view —
    // fall through to the panel-first ladder below unchanged.
    if (root.isIslandFirst(id) && state.nativeViewFor(id)) {
      if (state.expanded && state.activeContext !== "" && state.activeContext !== id)
        state.collapse()
      state.setContext(id)
      return
    }

    // Real panel first: this is the widget's own surface, and only an id with
    // a live panel widget reaches the ghost/fallback ladder below. Anything
    // without a panel is a native island view instead.
    var item = findPanelWidget(id)
    if (item && typeof item.open === "function") {
      // Toggle whatever is showing for this id. `unit.panelItem` covers both
      // the centered ghost and an adopted live panel, neither of which is in
      // the module-slot registry.
      if (unit.panelItemId === id && unit.panelItem && unit.panelItem.opened === true
          && typeof unit.panelItem.close === "function") {
        unit.panelItem.close()
        return
      }

      // Solo mode (Function 2): pin this tile at the body's top center before
      // the panel opens, so the panel's own KeyboardPanel anchor sits under
      // the notch instead of under this grid cell. Only a click from the
      // visible grid (or a pinned row) qualifies; hotkey and mini-player
      // opens keep the resting layout.
      var fromGrid = state.isGridContext(state.activeContext)
      if (fromGrid) state.enterSolo(id)

      // Centered ghost: the panel anchors under the notch instead of under
      // this grid cell. Grids are always instantiated (see DynamicIsland), so
      // the reveal can be retired without destroying the widget; the ghost
      // lives in the pill, which is why clearing the reveal no longer risks
      // the anchor. In solo mode the grid stays mapped anyway.
      if (root.centeredPluginAnchor && unit.openCenteredPanel(id)) return
      if (root.centeredPluginAnchor) root.logAnchorFallback(id)

      if (item.opened === true && typeof item.close === "function") item.close()
      else item.open()
      if (item.opened === true) {
        unit.adoptLivePanel(id, item)
        // Do NOT clear the grid context while the solo panel is open: the live
        // tile is the panel's anchor and collapsing the body would hide it.
        if (state.isGridContext(state.activeContext) && !state.isSolo(id)) state.clearReveal()
      } else {
        // The panel refused to open: leave the grid exactly as it was and
        // drop the solo marker (no panel is up, so this is safe).
        unit.clearSoloIfPanelClosed()
      }
      return
    }

    // No panel: only an id we actually built an island view for may open here.
    // A widget with neither a panel nor a bespoke view owns its own behaviour
    // (or has none), and hijacking its click into the island's generic fallback
    // is exactly the redirect this must not do — e.g. bar indicators and
    // third-party widgets we have not given a view.
    if (!state.nativeViewFor(id)) return
    if (state.expanded && state.activeContext !== "" && state.activeContext !== id)
      state.collapse()
    state.setContext(id)
  }

  // --- bar-off toggle ---------------------------------------------------------
  // Mirrors Bar.qml: presence of ~/.local/state/omarchy/toggles/bar-off parks
  // the island off-screen (mapped, no exclusion zone) so `omarchy-toggle-bar`
  // keeps working. The directory watch can go quiet after rapid flag flips,
  // so the syncHidden IPC probe stays as the belt-and-braces nudge.
  property bool barHidden: false

  Process {
    id: barHiddenProbe
    running: true
    command: ["bash", "-c", "[[ -f $HOME/.local/state/omarchy/toggles/bar-off ]] && echo yes || echo no"]
    stdout: SplitParser { onRead: function(line) { root.barHidden = String(line).trim() === "yes" } }
  }
  FileView {
    path: root.home + "/.local/state/omarchy/toggles"
    watchChanges: true
    printErrors: false
    onFileChanged: barHiddenProbe.running = true
  }
  IpcHandler {
    target: "omarchy.bar"
    // Start rather than restart: an in-flight probe already reads post-flip
    // state, and killing it can swallow the result entirely (Bar.qml note).
    function syncHidden(): void {
      barHiddenProbe.running = true
    }
    // Hotkey entry (Super+Hyper_L, i.e. Super+Caps with kb_options=caps:hyper):
    // open the island on its resolved page — the same resolution the bottom-zone
    // dwell uses, so music leads while a track plays and the default deck is the
    // fallback — or collapse it when it is already open.
    // Invoked as `omarchy-shell omarchy.bar island`.
    function island(): void {
      var unit = focusedIslandUnit()
      if (!unit) return
      if (unit.islandState.expanded) unit.islandState.collapse()
      else unit.islandState.openResolved()
    }
    // Debug-only: mount a specific island context without pointer injection, so
    // the transient/suspension paths can be exercised from a shell.
    // `omarchy-shell omarchy.bar debugOpen island.default` (deck),
    // `omarchy-shell omarchy.bar debugOpen omarchy.volume` (overlay view).
    function debugOpen(contextId: string): void {
      var unit = focusedIslandUnit()
      if (!unit) return
      var id = String(contextId || "")
      if (id === "") unit.islandState.openResolved()
      else unit.islandState.setContext(id)
    }
    // Set the manual notch-geometry multiplier through the shell config API (no
    // hand-editing shell.json): `omarchy-shell omarchy.bar notchScale 1.1`.
    // The display scale is applied automatically, so this only fine-tunes.
    function notchScale(value: string): void {
      var v = Number(value)
      if (!isFinite(v) || v <= 0) return
      if (!root.shell || typeof root.shell.mutateShellConfig !== "function") return
      root.shell.mutateShellConfig(function(config) {
        if (!Util.isPlainObject(config.bar)) config.bar = {}
        config.bar.islandNotchScale = v
      })
    }
    // Replace the island-first id set through the shell config API (comma
    // separated; empty clears it). `omarchy-shell omarchy.bar islandFirst ""`.
    function islandFirst(value: string): void {
      var out = []
      var parts = String(value || "").split(",")
      for (var i = 0; i < parts.length; i++) {
        var id = parts[i].trim()
        if (id && out.indexOf(id) === -1) out.push(id)
      }
      if (!root.shell || typeof root.shell.mutateShellConfig !== "function") return
      root.shell.mutateShellConfig(function(config) {
        if (!Util.isPlainObject(config.bar)) config.bar = {}
        config.bar.islandFirstContexts = out
      })
    }
    // Show/hide this plugin's own settings icon in the bar layout through the
    // shell config API (the registry cannot place a bar-kind plugin's widget).
    // `omarchy-shell omarchy.bar settingsIcon true|false|toggle`.
    function settingsIcon(value: string): void {
      var text = String(value || "").trim().toLowerCase()
      if (text === "toggle") root.setSettingsIcon(!root.settingsIconEnabled)
      else if (text === "true" || text === "on" || text === "1") root.setSettingsIcon(true)
      else if (text === "false" || text === "off" || text === "0") root.setSettingsIcon(false)
    }
    // Switch the active bar implementation through the shell config API:
    // `omarchy-shell omarchy.bar useBar local.notch-island|omarchy.bar`.
    function useBar(id: string): void {
      root.setActiveBar(String(id || ""))
    }
    // Enable/disable a context provider:
    // `omarchy-shell omarchy.bar contextFlag omarchy.microphone false`.
    function contextFlag(id: string, enabled: string): void {
      var key = String(id || "")
      if (!key) return
      var text = String(enabled || "").toLowerCase()
      root.setContextEnabled(key, !(text === "false" || text === "off" || text === "0"))
    }
    // Timing/motion overrides through the shell config API:
    // `omarchy-shell omarchy.bar timing islandTransientTtlMs 2000`,
    // `omarchy-shell omarchy.bar resetTiming`.
    function timing(key: string, value: string): void {
      root.setTiming(String(key || ""), String(value || ""))
    }
    function resetTiming(): void {
      root.resetTiming()
    }
    // Island surface opacity (pill + body) through the shell config API:
    // `omarchy-shell omarchy.bar opacity 0.8`. Inert while transparent is off.
    function opacity(value: string): void {
      root.setIslandOpacity(String(value || ""))
    }
    // Pill form + length through the shell config API. `pillCompact` also takes
    // the word `toggle` (what the right click does); an empty / 0 length
    // restores the derived geometry:
    // `omarchy-shell omarchy.bar pillCompact toggle`
    // `omarchy-shell omarchy.bar pillWidth 620`
    // `omarchy-shell omarchy.bar pillWidth 0`
    function pillCompact(value: string): void {
      var text = String(value || "").trim().toLowerCase()
      if (text === "toggle") root.setPillCompact(!root.pillCompactMode)
      else if (text === "true" || text === "on" || text === "1") root.setPillCompact(true)
      else if (text === "false" || text === "off" || text === "0") root.setPillCompact(false)
    }
    function pillWidth(value: string): void {
      root.setPillWidth(String(value || ""))
    }
    // Managed Hyprland keybind through the shell config API:
    // `omarchy-shell omarchy.bar hotkey island.toggle "SUPER + MOD3 + Hyper_L"`.
    // An empty key clears the action.
    function hotkey(action: string, keys: string): void {
      root.setHotkey(String(action || ""), String(keys || ""))
    }
    // Effective timing/motion values after clamping — the settings panel reads
    // the same numbers, and the doctor section (8d) can flag a bad config.
    function debugTiming(): string {
      return JSON.stringify({
        transientTtlMs: root.transientTtlMs,
        transientLeadMs: root.transientLeadMs,
        toastHoldMs: root.toastHoldMs,
        toastTtlMs: root.toastTtlMs,
        motionFastMs: root.motionFastMs,
        motionBaseMs: root.motionBaseMs,
        motionSlowMs: root.motionSlowMs,
        islandOpacity: root.islandOpacity,
        transparent: root.transparent,
        activeBarId: root.activeBarId,
        settingsIcon: root.settingsIconEnabled
      })
    }
    // Read-only diagnostics for the settings widget wiring:
    // `omarchy-shell omarchy.bar debugSettingsWidget`.
    // Debug-only: raise the compact media peek exactly as a playback change does,
    // and run the pointer-approach promotion, so both can be exercised from a
    // shell. This host cannot inject hover, and these two are the transitions
    // that depend on it. `omarchy-shell omarchy.bar debugMediaPeek` / `debugPromote`.
    function debugMediaPeek(): void {
      contextResolver.showTransient(contextResolver.mediaPeekContextId)
    }
    function debugPromote(): void {
      var unit = focusedIslandUnit()
      if (unit) unit.promoteAutomaticAppearance()
    }
    // Debug-only: pin the page the resolver would reopen, so a peek's promotion
    // can be exercised the way a real session hits it (memory sitting on the
    // deck). `omarchy-shell omarchy.bar debugLastPage island.default`.
    function debugLastPage(id: string): void {
      contextResolver.lastPageId = String(id || "")
    }
    // Read-only: the toast snapshots the island is holding, with the default
    // action argv captured from the popup (round 9). Proves the capture half of
    // the clickable-toast path from a shell, where no pointer can be injected:
    // `omarchy-shell omarchy.bar debugToastSnapshots`. The argv is NOT run here
    // — only a real click on the toast body runs it.
    function debugToastSnapshots(): string {
      var snaps = contextResolver.toastSnapshots || []
      var out = []
      for (var i = 0; i < snaps.length; i++) {
        var s = snaps[i]
        out.push({
          key: String(s.key || ""),
          app: String(s.app || ""),
          summary: String(s.summary || ""),
          execArgv: String(s.execArgv || "")
        })
      }
      return JSON.stringify(out)
    }
    function debugSettingsWidget(): string {
      var registry = root.barWidgetRegistry
      var widgets = registry ? registry.widgets : null
      var keys = []
      if (widgets) for (var k in widgets) keys.push(k)
      var rightIds = []
      var entries = root.gridEntriesFor("right")
      for (var i = 0; i < entries.length; i++) rightIds.push(String(BarModel.entryId(entries[i]) || ""))
      var registered = widgets ? widgets[root.pluginId] : null
      return JSON.stringify({
        pluginId: root.pluginId,
        registryCount: keys.length,
        registryHas: !!registered,
        registryComponent: !!(registered && registered.component),
        entryPresent: root.settingsEntryPresent,
        iconEnabled: root.settingsIconEnabled,
        rightIds: rightIds,
        moduleSlots: root.moduleSlots.length
      })
    }
    // Read-only geometry readout for calibrating the notch fit at any scale.
    // Mirrors upstream's debugBarGeometry: `omarchy-shell omarchy.bar
    // debugIslandGeometry`.
    function debugIslandGeometry(): string {
      var unit = focusedIslandUnit()
      if (!unit) return "{}"
      return JSON.stringify({
      screen: unit.screenKey,
      displayScale: unit.displayScale,
      notchScale: unit.notchScale,
      notchCutoutWidth: unit.notchCutoutWidth,
      notchSideSlot: unit.notchSideSlot,
      pillWidth: unit.pillWidth,
      pillWidthOverride: root.pillWidthOverride,
      pillHeight: unit.pillHeight,
      pillCompact: unit.pillCompact,
      pillCompactMode: root.pillCompactMode,
      pillMinimized: unit.pillMinimized,
      pillCollapse: unit.pillCollapse,
      dotWidth: Math.round(unit.dotWidth),
      expandedWidth: unit.expandedWidth,
      notchStrip: unit.notchStrip,
      pillTimeSize: unit.pillTimeSize,
      restTimeInset: unit.restTimeInset,
      styleSizeHorizontal: Style.bar.sizeHorizontal,
      styleNotchHeight: Style.bar.notchHeight,
      space6: Style.space(6),
      fontBody: Style.font.body,
      expanded: unit.islandState.expanded,
      paging: unit.islandState.paging,
      revealSide: unit.islandState.revealSide,
      activeContext: unit.islandState.activeContext,
      displayedContext: unit.islandState.displayedContext,
      transientContext: unit.islandState.transientContext,
      transientVisible: unit.islandState.transientVisible,
      transientPeek: unit.transientPeek,
      transientSuspended: unit.islandState.transientSuspended,
      transientSuspenders: Object.keys(unit.islandState.transientSuspenders || {}),
      autoOpened: unit.islandState.autoOpened,
      escapeFocusWanted: unit.escapeFocusWanted,
      hover: {
        strip: unit.stripHovered,
        card: unit.cardHovered,
        pillBody: unit.pillBodyHovered,
        revealNear: unit.revealNear
      },
      paging: unit.islandState.paging,
      body: unit.debugBodySnapshot(),
      lastPillX: Math.round(unit.lastPillX),
      lastPillZone: unit.lastPillZone,
      // Round-6 provider readout: lets the page resolution be verified without
      // hovering. Read-only; changes nothing.
      pageIds: unit.islandState.pageIds,
      entryId: unit.islandState.entryId,
      pageId: unit.islandState.pageId,
      lastPageId: contextResolver.lastPageId,
      providers: {
        media: contextResolver.mediaActive,
        microphoneInUse: contextResolver.microphoneInUse,
        microphoneMuted: contextResolver.microphoneMuted,
        notifications: contextResolver.notificationCount,
        doNotDisturb: contextResolver.doNotDisturb,
        nightlight: contextResolver.nightlightEnabled,
        stayAwake: contextResolver.stayAwake,
        screenRecording: contextResolver.screenRecording,
        brightnessAvailable: root.brightnessState ? root.brightnessState.available : false,
        brightnessPercent: root.brightnessState ? root.brightnessState.percent : -1,
        volume: contextResolver.volume,
        muted: contextResolver.muted,
        transientSeq: contextResolver.transientSeq,
        transientTtlMs: contextResolver.transientTtlMs
      }
    })
    }
  }

  onBarHiddenChanged: {
    if (!barHidden) return
    for (var i = 0; i < _units.length; i++) _units[i].islandState.collapse()
    if (activePopout && typeof activePopout.close === "function") activePopout.close()
  }

  // Apple Silicon probe: only the built-in panel has a physical cutout, so
  // pill height floors to the derived notch depth there. Fixed hardware, so
  // one probe at startup (same as Bar.qml).
  property bool appleSiliconHost: false
  Process {
    running: true
    command: ["bash", "-c", "grep -qi apple /proc/device-tree/compatible 2>/dev/null && echo yes || echo no"]
    stdout: SplitParser { onRead: function(line) { root.appleSiliconHost = String(line).trim() === "yes" } }
  }

  // --- per-screen island units -------------------------------------------------
  property var _units: []

  function registerIslandUnit(unit) {
    if (!unit || _units.indexOf(unit) !== -1) return
    var next = _units.slice()
    next.push(unit)
    _units = next
    // A unit can register after the config has already loaded, so seed its pill
    // form here too; applyBarConfig covers the other order.
    unit.applyPillForm()
  }

  function unregisterIslandUnit(unit) {
    _units = _units.filter(function(item) { return item !== unit })
  }

  function focusedIslandUnit() {
    if (_units.length === 0) return null
    if (_units.length === 1) return _units[0]
    var focusedName = focusedScreenName()
    if (focusedName) {
      for (var i = 0; i < _units.length; i++) {
        var screen = _units[i].hostScreen
        if (screen && String(screen.name || "") === focusedName) return _units[i]
      }
    }
    return _units[0]
  }

  // Effective pill length of the focused screen's island. The settings panel
  // uses it so an untouched slider sits where the pill actually is; 0 while no
  // screen has an island yet (the bar then falls back to the derived number).
  readonly property int pillWidthEffective: {
    var unit = focusedIslandUnit()
    return unit ? unit.pillWidth : 0
  }

  // --- shared now-playing state ---------------------------------------------
  // One MPRIS state holder for the whole bar: the collapsed-pill mini-player
  // and the expanded MusicView both read it, and the auto-context watcher
  // below turns a fresh playback into a brief music expansion.
  readonly property MediaState mediaState: mediaSource
  MediaState { id: mediaSource }

  // Shared display-brightness state (round 6). Polled, because the display has
  // no reactive property. The default page's deck slider and the brightness
  // transient overlay both read this one instance.
  readonly property var brightnessState: brightnessSource
  BrightnessState { id: brightnessSource }

  // Context resolver: owns the page order (active big contexts first, the
  // default page last) and the transient-overlay TTL. One instance for the
  // whole bar; every island unit binds its state to it, so all screens resolve
  // contexts identically.
  ContextResolver {
    id: contextResolver
    mediaState: root.mediaState
    shell: root.shell
    brightnessState: root.brightnessState
    // Tuned from the timing section of the settings panel (bar.islandTransientTtlMs
    // / bar.islandToastTtlMs); the bar clamps them and keeps the toast TTL ahead
    // of the toast hold.
    transientTtlMs: root.transientTtlMs
    notificationToastDuration: root.toastTtlMs
    mediaPeekTtlMs: root.mediaPeekMs
    disabledContexts: root.disabledContexts
  }

  // Public handle for the native views: QuickSettingsView reads the ambient
  // system toggles (night light, idle, DND, microphone) off the same resolver
  // instance the pages come from, so there is one source of truth.
  readonly property var contextResolverState: contextResolver

  // Shared wall clock for the resting pill. One instance for the whole bar;
  // every island unit reads pillHourText/pillMinuteText, so the pill shows the
  // split time when no widget grid is open: the hour in the left wing and the
  // minutes in the right wing, each against its own outer edge so the physical
  // camera cutout sits cleanly between them.
  readonly property string pillHourText: Qt.formatDateTime(wallClock.date, "HH")
  readonly property string pillMinuteText: Qt.formatDateTime(wallClock.date, "mm")
  SystemClock {
    id: wallClock
    precision: SystemClock.Minutes
  }

  // Playback changes no longer open the full media page from here.
  // ContextResolver raises the compact "island.mediaPeek" transient instead (its
  // mediaKey edge, which also covers pause and an ad swapping the metadata), so
  // the island peeks a slim now-playing strip over whatever it was doing and the
  // full MusicView stays what the resolved media page shows when the user
  // reaches for the pill. The old login grace now lives with that edge.

  Variants {
    model: Quickshell.screens

    delegate: Component {
      IslandUnit {
        required property var modelData
        hostScreen: modelData
      }
    }
  }

  // One lifecycle log is all this plugin prints; hover handlers stay silent.
  Component.onCompleted: {
    applyBarConfig()
    console.log("[notch-island] bar active, screens=" + Quickshell.screens.length)
  }

  Component.onDestruction: {
    if (activePopout && typeof activePopout.close === "function") activePopout.close()
  }

  // A screen's worth of island: one always-mapped pill surface (the notch +
  // both icon rows) and one transient body surface below it. Splitting them
  // keeps the pill window's height constant so KeyboardPanel's bar-strip math
  // (which uses the anchor window's height) stays correct while expanded.
  component IslandUnit: Item {
    id: unit

    required property var hostScreen
    visible: false

    // --- geometry, derived from screen + Style tokens (no magic numbers) ----
    // notchStrip mirrors Bar.qml's notchFloor: the shell.toml calibrated
    // override wins, otherwise the 16:10-leftover derivation applies on
    // Apple panels only; 0 on flat displays.
    readonly property int notchStrip: Style.bar.notchHeight > 0
      ? Style.bar.notchHeight
      : (root.appleSiliconHost && hostScreen
          ? BarModel.notchHeight(hostScreen.name, hostScreen.width, hostScreen.height, hostScreen.devicePixelRatio)
          : 0)
    // Pill height: the cutout depth where one exists; elsewhere the bar strip
    // plus two icon paddings so the pill reads as an island, not a hairline.
    readonly property int pillHeight: Math.max(notchStrip,
      Math.round((Style.bar.sizeHorizontal + Style.space(6) * 2) * unit.invScale))

    // --- pill split-time styling (round 2: display-scale digits) ------------
    // The clock doubles its size (base-size x 2) and gains a bolder, wider
    // face so it reads against the bezel. The lateral containers around the
    // digits shrink by ~27% (see notchSideSlot) so the pill hugs the cutout
    // instead of the clock floating in dead space. `tnum` (Qt 6.7+
    // font.features; supported by this Qt 6.11) keeps the minute field from
    // jittering as digits tick. The glow is a low-opacity, zero-offset
    // MultiEffect shadow so it reads as a halo, not a drop.
    readonly property int pillTimeSize: Math.max(1, Math.round(Style.font.body * 2 * unit.invScale))
    readonly property int pillTimeWeight: Font.Bold
    readonly property real pillTimeTracking: 2.0
    readonly property var pillTimeFeatures: ({ "tnum": 1 })
    readonly property color pillTimeGlowColor: Color.bar.text
    readonly property real pillTimeGlowOpacity: 0.5
    readonly property real pillTimeGlowBlur: 0.7

    // The digits yield when the pill retracts — which now happens only once the
    // body is actually showing (see pillHoverMinimize) — or while a plugin panel
    // window is up. The old proximity yield was removed: it faded the clock
    // before anything was revealed. The return trip is the "bubble"
    // reappearance used after auto-hide.
    readonly property bool pillTimeYields: unit.pillMinimized || unit.pluginWindowOpen
    readonly property real pillTimeOpacity: unit.pillTimeYields ? 0.0 : 1.0

    // The body's own clock view (opened by dwelling on the bottom zone)
    // already shows time/date/weather, so the pill must not duplicate the time
    // while a clock-facing view is up. bodyShowsClock generalises that: it is
    // true for whatever view the resolver marks as showing the time.
    readonly property bool pillTimeDeferred: islandState.bodyShowsClock

    // Shared blink phase for the clock colons (a second visible, a second
    // hidden). It runs while either colon is on screen: the dot clock, or the
    // split clock at rest.
    property bool colonBlinkOn: true
    readonly property bool splitClockVisible: !unit.pillStatusMode
      && unit.pillTimeOpacity > 0 && !unit.pillTimeDeferred
    Timer {
      interval: 1000
      repeat: true
      running: unit.pillMinimized || unit.splitClockVisible
      onTriggered: unit.colonBlinkOn = !unit.colonBlinkOn
    }

    // The lateral containers collapse under the hardware cutout when the
    // island takes over (body expanded or pointer near), so the pill retracts
    // out of the way and only the notch band is left. Flat hosts keep the pill
    // (there is no cutout to hide under). The digits' own hide animation runs
    // in parallel.

    // Right-click pins the pill into its minimum ("dot") form; another
    // right-click restores the full pill. The pinned form is exactly the
    // transient hover collapse, so the click just makes that state persist
    // after the pointer leaves. Since round 9b the pin is a persisted
    // preference (bar.islandPillCompact) rather than session state, and it is
    // APPLIED imperatively from the config — never bound, because the gesture
    // assigns it and an assigned-over binding latches. applyPillForm() is the
    // single entry point; the bar calls it on config load and on registration.
    property bool pillCompact: false
    function applyPillForm() {
      // Read the config object directly instead of root.pillCompactMode: the
      // derived readonly property can still hold the PREVIOUS value in the same
      // pass that delivers the config change (a binding is evaluated one pass
      // later — the ordering trap behind #1669/#1671). Reading the config sees
      // an in-place mutation immediately. The Connections below catches the
      // case where the value arrives as a later property change instead.
      var v = root.barConfig ? root.barConfig.islandPillCompact : undefined
      unit.pillCompact = (v === undefined || v === null) ? true : v === true
    }
    Connections {
      target: root
      function onPillCompactModeChanged() { unit.applyPillForm() }
    }
    // Left-click swaps the template: false = split clock, true = status dials
    // (Wi-Fi ring on the left, battery ring on the right). The template decides
    // what the pill shows when minimized: HH:mm for the clock, the two dials
    // for the icons.
    property bool pillStatusMode: false

    // Minimum surface width: a single centred badge that carries HH:mm at the
    // SAME size as the split clock, so its surface is measured at runtime from
    // the clock row (see the Binding in the pill content); this is only the
    // initial floor.
    property real dotWidth: unit.pillHeight

    // The pill auto-minimizes while the island takes over (body expanded or
    // pointer near) AND stays minimized when pinned compact — those never
    // fight, so they are simply OR-ed. A right click toggles the pin; to make
    // that visible while the hover would otherwise force the pill compact, the
    // click opens a short "preview" window in which the pinned form wins. When
    // it ends the hover rule resumes, so the pill still retracts while you use
    // the island (both requirements coexist).
    // The pill retracts ONLY once the body is actually showing — never on mere
    // pointer proximity. Compacting as soon as the pointer came near read as
    // "it hides before showing anything" and could win the race against the
    // reveal. Order is now: hover -> reveal -> retract.
    readonly property bool pillHoverMinimize: islandState.expanded
    property bool pillPreview: false
    Timer {
      id: pillPreviewTimer
      interval: 1200
      onTriggered: unit.pillPreview = false
    }
    readonly property bool pillMinimized:
      unit.pillCompact || (unit.pillHoverMinimize && !unit.pillPreview)
    readonly property real pillTargetWidth: unit.pillMinimized ? unit.dotWidth : unit.pillWidth
    // Map the target width onto SimulatedNotch's 0..1 collapse driver, where
    // 0 is the dot and 1 is the full pill.
    readonly property real pillCollapse: {
      var span = unit.pillWidth - unit.dotWidth
      if (!(span > 0)) return 1.0
      return Math.max(0, Math.min(1, (unit.pillTargetWidth - unit.dotWidth) / span))
    }

    // Last pointer position inside the pill, pill-local. Kept only for the
    // debug readout (see debugIslandGeometry); the reveal itself is driven by
    // pillZone via pillZoneAt/handlePillZone.
    property real lastPillX: -1
    property string lastPillZone: ""

    // --- physical camera cutout: the two numbers to calibrate ---------------
    // The physical camera cutout is a fixed size in device px, so its logical
    // size depends on the display scale. The HEIGHT already divides by it
    // (BarModel.notchHeight); these width constants did not, which is why the
    // reserved cutout band doubled at 2x and the pill stretched out of the
    // notch. Derive them the same way, then let `bar.islandNotchScale` tune the
    // result. A MacBook Pro 14" (3024x1964 at scale 1) measures ~370px wide
    // (185pt @2x, ~12.2% of the panel width); notchSideSlot is the clear
    // lateral slot reserved outside the cutout on EACH side, where the clock
    // (left) and the mini-player (right) sit.
    readonly property real displayScale: {
      var s = hostScreen ? Number(hostScreen.devicePixelRatio) : 1
      return (isFinite(s) && s > 0) ? s : 1
    }
    readonly property real notchScale: {
      var v = Number(root.barNotchScale)
      return (isFinite(v) && v > 0) ? v : 1
    }
    // The island is notch-anchored: its look is calibrated at scale 1 and then
    // divided by the display scale, so it hugs the PHYSICAL notch the same way
    // at any scale. Style's own tokens drift upward with the display/font scale
    // (fontBody 16, sizeHorizontal 35 at 2x), which is what made the pill ~30%
    // too big AND let the clock swallow the side wings so the grid reveal never
    // fired. Every authored island dimension below applies this factor.
    readonly property real invScale: 1 / unit.displayScale
    // The CUTOUT is physical: the hardware notch never changes size, so its
    // logical width shrinks as the display scale grows (370px is the 14" panel
    // measured at scale 1). The SIDE SLOT is a UI-sized channel that holds the
    // clock and the mini-player, so it tracks the font/logical scale instead —
    // dividing it too would leave the (physically doubled) digits under the
    // notch at 2x, which is exactly the "cut by the notch" symptom.
    readonly property int notchCutoutWidth: Math.round(370 * unit.notchScale * unit.invScale)
    readonly property int notchSideSlot: Math.round(88 * unit.notchScale * unit.invScale)

    // --- debug geometry -----------------------------------------------------
    // Shifts the WHOLE island (pill surface + body surface) down by this many
    // logical px. 0 is the production geometry, byte-for-byte; set e.g. 60 to
    // drag the content out from under a physical notch and inspect what the
    // hardware cutout normally hides. Single knob, one line per surface.
    readonly property int debugTopOffset: 0
    // --- debug: status-dial centring ----------------------------------------
    // Vertical nudge, in logical px, for the pill's status-template glyphs
    // (positive = down). 0 is production. One knob per dial so the Wi-Fi and
    // battery rings can be centred independently while inspecting them up
    // close; restore both to 0 once the final value is agreed.
    readonly property int wifiDialNudgeY: 0
    readonly property int batteryDialNudgeY: 0
    // True only on the built-in notched panel (eDP with a measured strip), so
    // an attached flat monitor keeps the old aspect-derived pill instead of
    // inheriting the wide cutout geometry.
    readonly property bool notchedHost: !!hostScreen
      && String(hostScreen.name || "").indexOf("eDP") === 0
      && notchStrip > 0
    // Notched host: cutout + two lateral slots, floored so the pill never
    // crowds the icon rows. Flat display: the old 6.25 aspect derivation.
    readonly property int pillWidthDerived: notchedHost
      ? notchCutoutWidth + 2 * notchSideSlot
      : Math.round(pillHeight * 6.25)
    // Effective pill length: `bar.islandPillWidth` overrides the derived value,
    // which is how a panel whose cutout differs from the calibrated 14" one gets
    // matched without guessing a notchScale. The icon-row floor still applies.
    readonly property int pillWidth: Math.max(
      2 * Style.bar.iconSlot + Style.space(8),
      root.pillWidthOverride > 0 ? root.pillWidthOverride : pillWidthDerived
    )
    // Body width: 42% of the screen, capped at 520 logical px to keep the
    // island notch-scale on ultrawides, floored at pill width + one icon.
    // The floor reads the DERIVED pill on purpose: bar.islandPillWidth is a pill
    // knob, so widening the pill must not stretch the body with it (an uncoupled
    // body also keeps the body from exceeding its own cap).
    readonly property int expandedWidth: hostScreen
      ? Math.max(pillWidthDerived + Style.bar.iconSlot, Math.min(Math.round(hostScreen.width * 0.42), 520))
      : pillWidth

    // Page list and transient overlay come from the shared resolver; the
    // island state itself owns which page the user is on. `transientContext` is
    // NOT bound here on purpose — see the Connections block that assigns it.
    property IslandState islandState: IslandState {
      pageIds: contextResolver.pageIds
      entryId: contextResolver.entryContextId
      pageMemory: contextResolver
    }

    // Live Wi-Fi/battery source for the pill's status template. Non-visual:
    // the dials own every pixel (see PillStatusDial.qml).
    PillStatusSource {
      id: pillStatus
    }

    readonly property string screenKey: hostScreen ? String(hostScreen.name || "") : "unknown"

    // --- plugin windows: centered ghost anchor + island retreat -------------
    // The widget whose own panel window is open on this screen: the lazy ghost
    // clone for island-initiated opens, or the live grid instance for
    // out-of-band opens. Null while no plugin window is up on this screen.
    property var panelItem: null
    property string panelItemId: ""
    // The clone that anchors a centered panel loads through the same mechanism
    // as every grid slot: a Loader + sourceComponent. That keeps the widget a
    // typed Component whose `open`/`opened`/`manageIpc` members are reachable
    // (a Component returned through a plain JS var can be used as a
    // sourceComponent but cannot be invoked through createObject). The clone
    // exists only while a panel is opening/open.
    property var ghostComponent: null
    property bool ghostRequested: false
    property string ghostRequestId: ""
    property var ghostItem: null
    // Re-entrancy guard: deactivating the Loader re-fires teardown bindings.
    property bool destroyingPanel: false

    // Drives the retreat: the island content hides while any plugin window is
    // tracked (open, or a centered ghost still loading), and the body window
    // stops mapping so the grid cannot sit behind it.
    readonly property bool pluginWindowOpen: unit.panelItem !== null || unit.ghostRequested

    // Escape handling: while the pointer is on the island (and no plugin window
    // owns the keyboard), the body surface takes keyboard focus so a bare
    // Escape returns the island to rest. Focus is released the moment the
    // pointer leaves or a plugin window appears, so typing elsewhere is never
    // captured. Plugin panels keep their own focus and are out of scope here.
    // Escape handling: the body surface takes keyboard focus ONLY while the
    // pointer is over the island BODY CARD and the island was not opened
    // automatically; every other state is WlrKeyboardFocus.None (see the window
    // below). Focus used to follow `revealNear`, which includes the pill notch
    // and the mini-player, and to fall back to OnDemand: parking the pointer on
    // the top strip (where it idles) then made the island claim the keyboard and
    // swallow the user's typing. The pill is where the pointer rests; the card
    // is where the content is.
    readonly property bool escapeFocusWanted: islandWindow.visible
      && unit.cardHovered && !unit.pluginWindowOpen
      && !unit.islandState.autoOpened

    // Single source of truth for "a real plugin panel window is open on this
    // screen": the tracked widget exists AND reports itself open. `opened` is
    // reliable for the panel widgets the island hosts — omarchy.audio and
    // omarchy.network are `qs.Ui.Panel`, whose `opened` is backed by
    // PanelController.open and only flips in open()/close(). For widgets that
    // expose their own `opened` (the slot requires the property to exist), its
    // contract is the same: it is the widget's real popup state.
    //
    // Every collapse/visibility decision keys off this, never off hover or the
    // pointer-leave timers, and never off soloMode having survived a spurious
    // slot-teardown notification.
    readonly property bool pluginPanelOpen: unit.panelItem !== null
      && unit.panelItem.opened === true

    // Solo mode is active on this screen. While it is, the body and the pill
    // stay mapped even with a plugin window open: the single centered tile is
    // the panel's live anchor (see Function 2).
    readonly property bool soloMode: unit.islandState.soloWidgetId !== ""

    // The body must stay mapped while a real panel is open. Solo mode is the
    // intended anchor in that case, but pluginPanelOpen is the authoritative
    // condition so a lost solo flag cannot unmap the anchor out from under the
    // panel.
    readonly property bool bodyKeptForPanel: unit.pluginPanelOpen

    // Clear solo only once the panel window is truly closed. A spurious slot
    // notification that arrives while `opened` is still true must not drop the
    // anchor.
    function clearSoloIfPanelClosed() {
      if (unit.pluginPanelOpen) return
      unit.islandState.clearSolo()
    }

    // Push the real open state into the state holder so clearReveal() can
    // refuse to collapse the body out from under a live panel anchor.
    Binding {
      target: unit.islandState
      property: "panelOpen"
      value: unit.pluginPanelOpen
    }

    // Open (or re-open) the centered panel for an id. Returns false only when
    // the id has no registered widget Component at all, so callers fall back
    // to the live widget. The clone loads on the next event-loop turn; the open
    // is completed in finishGhost().
    function openCenteredPanel(id) {
      var pluginId = String(id || "")
      if (!pluginId) return false
      if (unit.ghostItem && unit.panelItemId === pluginId) {
        if (unit.panelItem && unit.panelItem.opened === true) return true
        if (typeof unit.ghostItem.open === "function") unit.ghostItem.open()
        return unit.ghostItem.opened === true
      }
      if (unit.ghostRequested && unit.ghostRequestId === pluginId) return true
      var widgetComp = root.widgetComponent(pluginId)
      if (!widgetComp) return false
      unit.destroyPanel()
      unit.ghostRequestId = pluginId
      unit.ghostComponent = widgetComp
      unit.ghostRequested = true
      return true
    }

    // Loader.onLoaded entry point: inject the slot props, open the clone's
    // panel, and track it. A clone that is not a panel widget, or that fails
    // to open, tears itself down and hands the id to the live widget — the
    // once-per-id logged fallback.
    function finishGhost() {
      var ghost = ghostLoader.item
      var id = unit.ghostRequestId
      if (!ghost) {
        unit.destroyPanel()
        root.openLivePanelFallback(id, unit)
        return
      }
      var entry = root.layoutEntry(id) || ({ id: id })
      if ("bar" in ghost) ghost.bar = root
      if ("moduleName" in ghost) ghost.moduleName = id
      if ("settings" in ghost) ghost.settings = root.entrySettings(entry)
      if ("manifest" in ghost) ghost.manifest = root.widgetManifest(id)
      if ("entry" in ghost) ghost.entry = entry
      if ("shell" in ghost) ghost.shell = root.shell
      if ("manageIpc" in ghost) ghost.manageIpc = false
      if ("interactive" in ghost) ghost.interactive = false
      if ("pressable" in ghost) ghost.pressable = false
      // Center the clone on the Loader origin, which sits at the pill's
      // horizontal center, so its anchor — whatever its width — is dead center.
      ghost.x = -ghost.width / 2
      ghost.y = 0
      if (typeof ghost.open !== "function" || ghost.opened === undefined) {
        unit.destroyPanel()
        root.openLivePanelFallback(id, unit)
        return
      }
      unit.ghostItem = ghost
      unit.panelItem = ghost
      unit.panelItemId = id
      try {
        ghost.open()
      } catch (error) {
        unit.destroyPanel()
        root.openLivePanelFallback(id, unit)
        return
      }
      if (ghost.opened !== true) {
        unit.destroyPanel()
        root.openLivePanelFallback(id, unit)
      }
    }

    // Track a live hosted panel opened out-of-band (its own IPC handler, or a
    // native press the slot did not redirect). Retreat applies; the panel
    // keeps the widget's own anchor because there is no ghost to redirect to.
    function adoptLivePanel(id, item) {
      if (!item || item.opened !== true) return
      if (unit.panelItem === item) return
      unit.destroyPanel()
      unit.panelItem = item
      unit.panelItemId = String(id || "")
    }

    // Slot-side detector: a hosted grid widget opened/closed its own panel.
    // This runs before the unit's own panelItem Connections on the same
    // openedChanged, so it owns the solo cleanup for live grid panels (the
    // unit Connections would see panelItem already null and bail).
    function noteSlotPanel(slot, opened) {
      if (!slot || !slot.activeItem) return
      if (opened) {
        if (unit.panelItem !== null) return
        unit.panelItem = slot.activeItem
        unit.panelItemId = String(slot.moduleName || "")
      } else if (unit.panelItem === slot.activeItem) {
        // Only a real close is authoritative. A slot-teardown notification can
        // arrive while the widget's own panel is still open (delegate churn, a
        // grid rebuild, a stale signal). Dropping the reference then clears
        // solo, and the pointer-leave timer collapses the body out from under
        // the still-open panel. Trust `opened` over the notification.
        if (unit.panelItem && unit.panelItem.opened === true) return
        unit.panelItem = null
        unit.panelItemId = ""
        unit.clearSoloIfPanelClosed()
        if (!unit.revealNear) revealHideTimer.restart()
      }
    }

    function destroyPanel() {
      if (unit.destroyingPanel) return
      unit.destroyingPanel = true
      if (unit.ghostItem) {
        try {
          if (unit.ghostItem.opened === true && typeof unit.ghostItem.close === "function")
            unit.ghostItem.close()
        } catch (error) {
        }
      }
      unit.ghostItem = null
      unit.panelItem = null
      unit.panelItemId = ""
      unit.ghostRequestId = ""
      // Deactivating the Loader destroys the clone; no manual destroy().
      unit.ghostRequested = false
      unit.ghostComponent = null
      unit.destroyingPanel = false
    }

    // The tracked panel closed itself (outside click, Esc, popout switch):
    // drop the reference and tear the ghost down if that is what closed.
    Connections {
      target: unit.panelItem
      function onOpenedChanged() {
        if (unit.destroyingPanel) return
        if (!unit.panelItem || unit.panelItem.opened === true) return
        if (unit.panelItem === unit.ghostItem) unit.destroyPanel()
        else {
          unit.panelItem = null
          unit.panelItemId = ""
        }
        // The panel that owned solo mode is gone: restore the full grid and
        // resume the normal pointer-leave collapse.
        unit.clearSoloIfPanelClosed()
        if (!unit.revealNear) revealHideTimer.restart()
      }
    }

    Component.onCompleted: {
      root.registerIslandUnit(unit)
      root.setStripHeight(unit.screenKey, unit.pillHeight)
    }
    Component.onDestruction: {
      unit.destroyPanel()
      islandState.collapse()
      root.clearStripHeight(unit.screenKey)
      root.unregisterIslandUnit(unit)
    }

    // --- interaction policy --------------------------------------------------
    // The pill carries three pointer zones:
    //   left third    -> open the body showing layout.left as a widget grid
    //   right third   -> open the body showing layout.right as a widget grid
    //   lower-center  -> open the native clock body (DynamicIsland)
    // A revealed grid stays up while the pointer is on the pill OR on the body
    // card, and hides after a short delay once it leaves both. Native
    // contexts (clock, music, a widget's own island view) follow their own
    // policy; only the context-free home view auto-collapses.
    property bool stripHovered: false
    property bool cardHovered: false
    property bool pillBodyHovered: false
    readonly property bool pointerNear: stripHovered || cardHovered
    readonly property bool revealNear: pillBodyHovered || cardHovered

    // Current pill zone under the pointer ("" while outside). Kept so the
    // lower-center dwell timer arms once on entry instead of on every move.
    property string pillZone: ""

    // Last moment the user visibly interacted with this island (hover or
    // click). Auto-context expansion consults it so a spontaneous music
    // pop-open never interrupts something the user is already doing.
    property double lastInteractionAt: 0

    function markInteraction() {
      unit.lastInteractionAt = Date.now()
    }

    // Lower-center dwell: hovering the clock zone resolves the active context
    // and opens the body on it, so music leads while it plays and the default
    // page is the fallback.
    Timer {
      id: bottomExpandTimer
      interval: 200
      // Never let the clock dwell override a side reveal that already fired: a
      // slow entry can clip the clock (cutout) zone on its way to a wing, and
      // the pending dwell must not replace the grid with the default page.
      onTriggered: if (!islandState.expanded && islandState.revealSide === "")
        islandState.openResolved()
    }

    Timer {
      id: homeCollapseTimer
      interval: 400
      onTriggered: {
        if (islandState.expanded && islandState.activeContext === "" && !unit.pointerNear)
          islandState.collapse()
      }
    }

    // Hides the revealed grid a short while after the pointer leaves both the
    // pill and the body card. Cancelled whenever revealNear becomes true again.
    // The delay is the SAME for every entry path (see autoHideTimer) and just
    // long enough to absorb a mapping/pointer-focus blip without a false close.
    Timer {
      id: revealHideTimer
      interval: 500
      repeat: false
      onTriggered: {
        // The pointer-leave timeout may only retire the grid when no real
        // panel is open. This is the actual invariant: hover is irrelevant
        // while a plugin window anchors to a tile in this body.
        if (!unit.revealNear && !unit.pluginPanelOpen) unit.islandState.clearReveal()
      }
    }

    // Mapping the body surface makes Hyprland re-pick the topmost layer
    // surface, which briefly drops the pill's hover. Ignore hover-loss for a
    // short window after a grid opens, or the island would close itself the
    // moment its own body appears. noteBodyResize() extends this while the body
    // is still loading, so the window only has to cover the first map — aligned
    // with the rest of the hide timers (700ms) so every entry path dwells alike.
    property bool revealSettling: false
    Timer {
      id: revealSettleTimer
      interval: 500
      repeat: false
      onTriggered: {
        unit.revealSettling = false
        if (!unit.revealNear && !unit.pluginPanelOpen) revealHideTimer.restart()
      }
    }

    function beginReveal(zone) {
      unit.revealSettling = true
      revealSettleTimer.restart()
      unit.islandState.reveal(zone)
    }

    // Called while the body resizes; keeps the settle window from expiring
    // mid-load and treats the resize itself as activity, so a false hover
    // exit during loading cannot schedule a close (see the timers above).
    function noteBodyResize() {
      if (unit.revealSettling) revealSettleTimer.restart()
      if (!unit.revealNear) revealHideTimer.restart()
    }

    // --- organic body presence + 5s auto-hide -------------------------------
    // unit.bodyHeld keeps the body surface mapped for one "slow" motion beat
    // after a normal collapse so the card retracts with its own animation
    // instead of being cut off by the unmap. The plugin-anchor rule still wins
    // through the window's own condition, so a held body never survives a live
    // panel.
    property bool bodyHeld: false
    Timer {
      id: bodyHoldTimer
      interval: root.motion.slow
      repeat: false
      onTriggered: unit.bodyHeld = false
    }
    Connections {
      target: unit.islandState
      function onExpandedChanged() {
        if (unit.islandState.expanded) {
          bodyHoldTimer.stop()
          unit.bodyHeld = false
        } else {
          unit.bodyHeld = true
          bodyHoldTimer.restart()
          // Any collapse ends a transient peek: it owned the body only until
          // the user dismissed it or the island came to rest on its own.
          unit.transientPeek = false
          transientPeekTimer.stop()
        }
      }
    }

    // Auto-hide: with content up and the pointer away for ~0.7s, retire the
    // body. ONE value for every entry path (bottom/clock, side grids, transient)
    // so the dwell feels identical no matter how the island was opened. Never
    // fires while a plugin panel window is open (the anchor invariant), and any
    // hover resets the clock. The hour/minutes reappearance is implicit:
    // pillTimeYields keys off islandState.expanded, so the bubble animation
    // plays the moment the collapse lands.
    property double pointerAwaySince: 0
    onPointerNearChanged: {
      unit.pointerAwaySince = unit.pointerNear ? 0 : Date.now()
      if (unit.pointerNear) hoverSuppressRelease.stop()
      else if (unit.hoverSuppressed) hoverSuppressRelease.restart()
    }

    // After Escape the pointer is usually still over the pill, and the collapse
    // animation itself re-fires the hover — which would immediately reopen the
    // island. Suppress the hover reveal until the pointer has actually left the
    // island and come back.
    property bool hoverSuppressed: false
    Timer {
      id: hoverSuppressRelease
      interval: 200
      onTriggered: unit.hoverSuppressed = false
    }
    function suppressHoverAfterDismiss() {
      unit.hoverSuppressed = true
      unit.transientPeek = false
      transientPeekTimer.stop()
      bottomExpandTimer.stop()
      if (unit.pointerNear) hoverSuppressRelease.stop()
      else hoverSuppressRelease.restart()
    }
    Timer {
      id: autoHideTimer
      interval: 200
      repeat: true
      running: unit.islandState.expanded && !unit.pluginPanelOpen
      onTriggered: {
        if (!unit.islandState.expanded || unit.pluginPanelOpen) return
        if (unit.transientPeek) return
        if (notificationAutoCollapse.running) return
        if (unit.pointerNear || unit.revealNear) return
        if (unit.pointerAwaySince <= 0) return
        if (Date.now() - unit.pointerAwaySince < 500) return
        unit.islandState.collapse()
      }
    }

    onRevealNearChanged: {
      if (unit.revealNear) revealHideTimer.stop()
      else if (!unit.revealSettling) revealHideTimer.restart()
    }

    // --- notifications auto-expand (the media counterpart is now the compact
    // "island.mediaPeek" transient; only the toast still opens a full page) ---
    // Same grace as media (avoid popping on every login) and same
    // hover/interaction guard. The collapse respects pointerNear and recent
    // interaction, just like the media timer, but with its own interval so the
    // two auto-contexts never share a timer.
    // Duration the toast stays expanded. From bar.islandToastHoldMs (default
    // 6500); ContextResolver's snapshot TTL is derived to stay ~500ms longer, so
    // the island collapses while the toast page still exists and no page-jump is
    // seen — the snapshot is pruned after the island is already gone.
    readonly property int notificationToastDuration: root.toastHoldMs
    property bool _notificationAutoReady: false
    property int _prevNotifCount: 0
    Timer {
      id: _notificationReadyTimer
      interval: 2500
      running: true
      onTriggered: unit._notificationAutoReady = true
    }
    Timer {
      id: notificationAutoCollapse
      interval: unit.notificationToastDuration
      repeat: false
      onTriggered: {
        var nid = contextResolver ? contextResolver.notificationToastContextId : "island.notificationToast"
        if (!unit.islandState.isActive(nid)) return
        if (unit.pointerNear || (Date.now() - unit.lastInteractionAt) < unit.notificationToastDuration) {
          notificationAutoCollapse.restart()
          return
        }
        unit.islandState.collapse()
      }
    }
    function expandToNotification() {
      if (root.barHidden) return
      unit.pointerAwaySince = Date.now()
      var nid = contextResolver ? contextResolver.notificationToastContextId : "island.notificationToast"
      if (unit.islandState.isActive(nid)) {
        notificationAutoCollapse.restart()
        return
      }
      if (unit.islandState.expanded) return
      if (Date.now() - unit.lastInteractionAt < 5000) return
      unit.islandState.openResolved(nid, true)
      notificationAutoCollapse.restart()
    }
    Connections {
      target: contextResolver
      function onNotificationCountChanged() {
        var count = contextResolver ? contextResolver.notificationCount : 0
        var prev = unit._prevNotifCount
        unit._prevNotifCount = count
        if (count <= prev) return
        if (!unit._notificationAutoReady) return
        if (contextResolver && contextResolver.doNotDisturb) return
        if (count <= 0) return
        unit.expandToNotification()
      }
    }
    Connections {
      target: contextResolver
      function onToastSnapshotsChanged() {
        if (contextResolver.toastSnapshots.length === 0 && unit.islandState.isActive(contextResolver.notificationToastContextId)) unit.islandState.collapse()
      }
    }

    // --- volume/brightness peek (the island is the OSD) ---------------------
    // A key-driven volume or brightness change raises a transient in the
    // resolver; this reacts to the per-request edge and peeks the island open
    // for one TTL when it was resting, then collapses itself. It never takes
    // keyboard focus (focus follows pointer hover only, see escapeFocusWanted)
    // and it stays down when the user just dismissed the island, when a plugin
    // panel owns the screen, or when the mounted view already hosts the control
    // (the deck's own sliders set transientSuspended).
    property bool transientPeek: false

    // Debug-only: forwards the body router's diagnostic snapshot to the bar
    // root's debugIslandGeometry readout.
    function debugBodySnapshot() { return islandCard.debugBodySnapshot() }

    // The pointer reached the island while it was showing something on its own:
    // a transient peek, the notification toast, the compact media strip. Stop
    // treating the appearance as automatic — cancel the timer that would take it
    // away, hand ownership to the user (which brings the pager back and puts the
    // focus policy back on the normal rules) and let the card animate the growth.
    function promoteAutomaticAppearance() {
      if (!unit.islandState.expanded) return
      if (!unit.islandState.autoOpened && !unit.transientPeek) return
      if (unit.transientPeek) {
        transientPeekTimer.stop()
        unit.transientPeek = false
      }
      unit.islandState.autoOpened = false
      // The compact media strip is an announcement, not a destination: drop it
      // and land on the media page itself — the full player — rather than on
      // whatever page happened to be remembered. Reaching for the strip is the
      // user saying "show me that", and the announced context is media.
      // `automatic=false` keeps the island user-owned (pager visible).
      if (contextResolver && contextResolver.transientId === contextResolver.mediaPeekContextId) {
        contextResolver.clearTransient()
        unit.islandState.openResolved(contextResolver.mediaContextId, false)
      }
      unit.islandState.promoting = true
      promotionAnimationTimer.restart()
      unit.markInteraction()
    }

    // Long enough to cover the card's height animation; normal resizes are
    // instant again afterwards.
    Timer {
      id: promotionAnimationTimer
      interval: 700
      repeat: false
      onTriggered: unit.islandState.promoting = false
    }

    function handleTransientRequest() {
      if (root.barHidden) return
      if (unit.pluginWindowOpen) return
      if (unit.islandState.transientSuspended) return
      if (unit.hoverSuppressed) return
      if (Date.now() - unit.lastInteractionAt < 500) return
      if (unit.islandState.expanded) {
        if (contextResolver && contextResolver.transientId === contextResolver.mediaPeekContextId) {
          if (unit.islandState.autoOpened) {
            // The announcement still owns the island. Playback arrives as a
            // BURST (playing flips, then the title/artist/art settle), so keep
            // the strip alive rather than letting the first event's TTL expire
            // mid-read.
            if (unit.transientPeek) transientPeekTimer.restart()
          } else if (unit.islandState.activeContext === contextResolver.mediaContextId) {
            // The user has taken the island and the page underneath is the
            // player: never cover it with the compact strip again. Compare
            // activeContext (the page the overlay would sit on), NOT
            // displayedContext — that one has already flipped to the transient by
            // the time this runs, which is exactly the trap that made the strip
            // come back. The resolver raised the transient before asking us, so
            // dropping it here is the only way to stop it painting; the whole
            // stack is synchronous, so no frame ever shows it.
            contextResolver.clearTransient()
          }
          return
        }
        // Already open. If the peek owns this expansion, extend it so that a
        // repeated key press does not leave the island stranded open past the
        // transient; if the user opened it, leave their island alone.
        if (unit.transientPeek) transientPeekTimer.restart()
        return
      }
      unit.islandState.openResolved("", true)
      unit.transientPeek = true
      transientPeekTimer.restart()
    }

    Connections {
      target: contextResolver
      // Assigned imperatively, not by a binding: a binding re-evaluates a pass
      // later, but handleTransientRequest() expands the island in the same stack
      // as the change. A stale "" there let the resolved page (the deck) mount
      // first and claim its transient-suspension token, which then latched the
      // overlay OFF for the whole peek — the key press showed the default page
      // instead of the volume/brightness overlay, and a playback change showed
      // it instead of the compact now-playing strip. A Connections handler runs
      // synchronously, so the overlay is known before the island expands.
      function onTransientIdChanged() {
        unit.islandState.transientContext = contextResolver.transientId
      }
      function onTransientSeqChanged() { unit.handleTransientRequest() }
    }

    // Lives 300ms shorter than the resolver's transient TTL, so the island is
    // already collapsing when the overlay clears and the page underneath never
    // flashes (the same off-by-500 trick the toast uses). If the user has moved
    // onto the island by then, drop the peek and let the hover/auto-hide policy
    // own it; if not, collapse immediately - a resting island that only opened
    // for the overlay must come to rest again.
    Timer {
      id: transientPeekTimer
      interval: Math.max(300, (contextResolver ? contextResolver.activeTransientTtlMs : 1600) - root.transientLeadMs)
      repeat: false
      onTriggered: {
        if (!unit.transientPeek) return
        unit.transientPeek = false
        if (unit.pluginPanelOpen) return
        // The pointer is on the island: hand the appearance to the user rather
        // than leaving an ownerless island open with its pager hidden.
        if (unit.revealNear) { unit.promoteAutomaticAppearance(); return }
        unit.islandState.collapse()
      }
    }

    function setStripHovered(hovered) {
      unit.stripHovered = hovered
      if (hovered) {
        unit.markInteraction()
        unit.promoteAutomaticAppearance()
        homeCollapseTimer.stop()
      } else {
        homeCollapseTimer.restart()
      }
    }

    function setCardHovered(hovered) {
      unit.cardHovered = hovered
      if (hovered) {
        unit.markInteraction()
        unit.promoteAutomaticAppearance()
        homeCollapseTimer.stop()
      } else {
        homeCollapseTimer.restart()
      }
    }

    function setPillBodyHovered(hovered) {
      unit.pillBodyHovered = hovered
      if (hovered) {
        unit.markInteraction()
        unit.promoteAutomaticAppearance()
      }
    }

    // Inset of the split clock from the pill's outer edge, in the pill's own
    // resting coordinates (not the animated ones): both clock wings and the
    // status dials anchor with it.
    readonly property int restTimeInset: Math.max(1, Math.round(Style.space(12) * unit.invScale))

    // Zone under a point inside the pill: "left" | "right" | "bottom".
    // Coordinates are pill-local, with (0,0) at the pill's top-left corner.
    // The pill is cutout + two lateral slots: the clock's two halves are the
    // native "bottom" route, the rest of the left wing is "left", the rest of
    // the right wing (including the mini-player) is "right", and the cutout's
    // own rows (physically invisible) map to "bottom" so a stray pointer there
    // still reaches the clock view.
    function pillZoneAt(x, y) {
      // Three zones, matching what is actually visible: each painted wing opens
      // its side grid, and only the cutout band in the middle (which carries the
      // colon) opens the native clock body. The hour/minutes digits live IN the
      // wings, so they must not own them — letting the clock rects claim the
      // wings was why hovering a side silently did nothing at higher scales.
      var cutoutLeft = (unit.pillWidth - unit.notchCutoutWidth) / 2
      if (x < cutoutLeft) return "left"
      if (x > cutoutLeft + unit.notchCutoutWidth) return "right"
      return "bottom"
    }

    // Act on the zone the pointer currently occupies. Left/right open their
    // widget grid immediately; the lower-center zone only arms the dwell timer.
    function handlePillZone(zone) {
      // A dismissed island ignores hover until the pointer leaves and returns,
      // so the collapse animation cannot reopen it on its own.
      if (unit.hoverSuppressed) { unit.pillZone = ""; return }
      if (zone === unit.pillZone) return
      unit.pillZone = zone
      if (zone === "left") {
        bottomExpandTimer.stop()
        unit.beginReveal("left")
      } else if (zone === "right") {
        bottomExpandTimer.stop()
        unit.beginReveal("right")
      } else if (zone === "bottom") {
        if (unit.pillBodyHovered) bottomExpandTimer.restart()
      } else {
        bottomExpandTimer.stop()
      }
    }

    // Click routing for the pill. Left click swaps the template between the
    // split clock and the status dials; right click toggles the pinned minimum
    // pill. bar.islandInvertPillClicks swaps the two (see the MouseArea below).
    // Hover keeps opening the grids and the clock view (see handlePillZone). The
    // body is opened by hover, not by a click.
    function togglePillCompact() {
      unit.markInteraction()
      // The preference is the single owner: writing it repaints the pill through
      // the config reload, so the gesture, the panel and the next shell restart
      // all agree (the old session-only pin reset to the wide pill on restart).
      // The local assignment is the same value — instant feedback while the
      // config write lands, and idempotent when it does.
      var next = !root.pillCompactMode
      root.setPillCompact(next)
      unit.pillCompact = next
      // Show the chosen form for a beat so the click is acknowledged even while
      // the hover is forcing the pill compact; the hover then resumes.
      unit.pillPreview = true
      pillPreviewTimer.restart()
    }

    function togglePillTemplate() {
      unit.markInteraction()
      unit.pillStatusMode = !unit.pillStatusMode
    }

    function handlePillHoverExited() {
      bottomExpandTimer.stop()
      unit.pillZone = ""
      unit.setPillBodyHovered(false)
    }

    // --- collapsed pill surface: left icons | notch | right icons ----------
    PanelWindow {
      id: pillWindow

      screen: unit.hostScreen
      color: "transparent"
      surfaceFormat.opaque: false
      // Parking (mapped, slid off the top edge, no exclusion zone) keeps
      // toggle-bar instant and preserves widget state (Bar.qml rationale).
      // debugTopOffset shifts the whole island group for hardware inspection;
      // it must stay a pure addend so 0 restores production geometry exactly.
      exclusionMode: root.barHidden ? ExclusionMode.Ignore : ExclusionMode.Auto
      anchors {
        top: true
        left: true
        right: true
      }
      margins.top: root.barHidden ? -unit.pillHeight : unit.debugTopOffset
      implicitWidth: 0
      implicitHeight: unit.pillHeight
      WlrLayershell.namespace: "notch-island"
      WlrLayershell.layer: WlrLayer.Top
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

      Item {
        id: pillContent
        anchors.fill: parent

        // Full strip hover counts as "pointer near the bar" for the collapse
        // policy; expansion still starts only on the notch body itself.
        HoverHandler {
          onHoveredChanged: unit.setStripHovered(hovered)
          Component.onDestruction: if (hovered) unit.setStripHovered(false)
        }

        // Lazy host for the centered plugin-anchor ghost. Zero opacity and
        // input-disabled: the clone inside exists only so its internal
        // KeyboardPanel anchors to a widget at the pill's center. The host is
        // a plain Item, not a window, so the ghost's anchor window stays the
        // mapped pill surface — the panel's screen and bar-height math remain
        // stable even while the island artwork below is hidden.
        Item {
          id: ghostAnchorHost
          anchors.fill: parent
          opacity: 0
          enabled: false
          z: 6

          // The clone is placed at the host's horizontal center (x = host
          // width / 2), then finishGhost() shifts it by -width/2 so its own
          // center — and therefore its internal KeyboardPanel anchor — lands
          // exactly on the pill center. A zero-width Loader lets the item keep
          // its natural footprint instead of being stretched by the host.
          Loader {
            id: ghostLoader
            x: parent.width / 2
            y: 0
            width: 0
            height: 0
            active: unit.ghostRequested
            sourceComponent: unit.ghostComponent
            onLoaded: unit.finishGhost()
          }
        }

        // Left/right reveals now render inside the island body (see
        // DynamicIsland's widget grids), so the strip itself only carries the
        // pill and the notch. The notch body (split time, mini-player, pill
        // pointer zones) steps aside while a plugin window is open, EXCEPT in
        // solo mode, where the pill stays painted so the panel has a stable
        // visual base above its single centered tile (Function 2, step 3).
        SimulatedNotch {
          id: notchBody
          visible: !unit.pluginWindowOpen || unit.soloMode || unit.bodyKeptForPanel
          anchors.top: parent.top
          anchors.horizontalCenter: parent.horizontalCenter
          pillW: unit.pillWidth
          pillH: unit.pillHeight
          cutoutW: unit.notchCutoutWidth
          minWidth: unit.dotWidth
          collapse: unit.pillCollapse
          collapseDuration: root.motion.base
          collapseOvershoot: root.motion.overshoot
          appleSiliconHost: root.appleSiliconHost
          transparent: root.transparent
          surfaceOpacity: root.islandOpacity

          // Pill pointer tracking. The entry point decides the zone, so no
          // absolute screen math is involved: the clock's slot (and the cutout
          // rows behind it) arms the native clock body; the left wing opens
          // the layout.left grid; the right wing opens the layout.right grid.
          // Disabled while a plugin window is open so the panel owns the
          // pointer without the pill re-routing zones underneath it.
          MouseArea {
            anchors.fill: parent
            enabled: !unit.pluginWindowOpen
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onEntered: {
              unit.setPillBodyHovered(true)
              unit.lastPillX = mouseX
              unit.lastPillZone = unit.pillZoneAt(mouseX, mouseY)
              unit.handlePillZone(unit.lastPillZone)
            }
            onPositionChanged: {
              unit.lastPillX = mouseX
              unit.lastPillZone = unit.pillZoneAt(mouseX, mouseY)
              unit.handlePillZone(unit.lastPillZone)
            }
            onExited: {
              unit.handlePillHoverExited()
            }
            onClicked: function(mouse) {
              // Default: right click pins the compact dot, left click swaps the
              // template. bar.islandInvertPillClicks swaps the two buttons.
              var right = mouse.button === Qt.RightButton
              if (right !== root.invertPillClicks) unit.togglePillCompact()
              else unit.togglePillTemplate()
            }
          }

          // (The old centre tap target lived here. It is gone: the whole pill
          // now owns the left click, and the collapse dot marks the centre by
          // itself. Its debug outline was the orange stadium seen at
          // debugTopOffset > 0.)

          // Pill content: the split time, plus the mini-player when a track is
          // live. Each is anchored to one outer edge so it sits in the visible
          // wing beside the physical cutout instead of behind it: the hour on
          // the far left, the minutes on the far right (both are the
          // native-clock route, see pillZoneAt). The mini-player is packed just
          // inside the minutes (anchored to pillMinutes.left) so the two share
          // the right wing without ever overlapping.
          //
          // Function 1: when the island body is expanded, BOTH time Texts fade
          // out so the pill is not competing with the body. The mini-player
          // deliberately STAYS: if music is playing it keeps the right wing
          // populated instead of leaving the whole pill empty, and the
          // now-playing affordance remains reachable. The body always has its
          // own content, so hiding the time alone never leaves the pill the
          // only thing on screen.
          Text {
            id: pillClock
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left
            anchors.leftMargin: Math.round((parent.width - notchBody.visualW) / 2) + unit.restTimeInset
            text: root.pillHourText
            color: Color.bar.text
            font.family: Style.font.family
            font.pixelSize: unit.pillTimeSize
            font.weight: unit.pillTimeWeight
            font.letterSpacing: unit.pillTimeTracking
            font.features: unit.pillTimeFeatures
            z: 3
            opacity: unit.pillStatusMode ? 0 : unit.pillTimeOpacity
            transformOrigin: Item.Center
            scale: 0.5 + 0.5 * unit.pillTimeOpacity
            Behavior on opacity { NumberAnimation { duration: root.motion.base; easing.type: Easing.OutCubic } }
            Behavior on scale {
              NumberAnimation {
                duration: root.motion.base
                easing.type: Easing.OutElastic
                easing.amplitude: root.motion.elasticAmplitude
                easing.period: root.motion.elasticPeriod
              }
            }
            layer.enabled: true
            layer.effect: MultiEffect {
              shadowEnabled: true
              shadowBlur: unit.pillTimeGlowBlur
              shadowColor: unit.pillTimeGlowColor
              shadowOpacity: unit.pillTimeGlowOpacity
              shadowVerticalOffset: 0
              shadowHorizontalOffset: 0
              autoPaddingEnabled: false
            }
          }

          Text {
            id: pillMinutes
            anchors.verticalCenter: parent.verticalCenter
            anchors.right: parent.right
            anchors.rightMargin: Math.round((parent.width - notchBody.visualW) / 2) + unit.restTimeInset
            text: root.pillMinuteText
            color: Color.bar.text
            font.family: Style.font.family
            font.pixelSize: unit.pillTimeSize
            font.weight: unit.pillTimeWeight
            font.letterSpacing: unit.pillTimeTracking
            font.features: unit.pillTimeFeatures
            z: 3
            opacity: unit.pillStatusMode ? 0 : unit.pillTimeOpacity
            transformOrigin: Item.Center
            scale: 0.5 + 0.5 * unit.pillTimeOpacity
            Behavior on opacity { NumberAnimation { duration: root.motion.base; easing.type: Easing.OutCubic } }
            Behavior on scale {
              NumberAnimation {
                duration: root.motion.base
                easing.type: Easing.OutElastic
                easing.amplitude: root.motion.elasticAmplitude
                easing.period: root.motion.elasticPeriod
              }
            }
            layer.enabled: true
            layer.effect: MultiEffect {
              shadowEnabled: true
              shadowBlur: unit.pillTimeGlowBlur
              shadowColor: unit.pillTimeGlowColor
              shadowOpacity: unit.pillTimeGlowOpacity
              shadowVerticalOffset: 0
              shadowHorizontalOffset: 0
              autoPaddingEnabled: false
            }
          }

          // Status template (right click): a Wi-Fi ring in the left wing and a
          // battery ring in the right wing. Same margins as the split clock so
          // both templates share the pill geometry and the compact collapse.
          PillStatusDial {
            id: wifiDial
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left
            anchors.leftMargin: Math.round((parent.width - notchBody.visualW) / 2) + unit.restTimeInset
            value: pillStatus.wifiFraction
            available: pillStatus.wifiKind !== "disconnected"
            glyph: pillStatus.wifiGlyph
            nudgeY: unit.wifiDialNudgeY
            accent: Color.accent
            z: 3
            opacity: unit.pillStatusMode ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: root.motion.base; easing.type: Easing.OutCubic } }
          }

          PillStatusDial {
            id: batteryDial
            anchors.verticalCenter: parent.verticalCenter
            anchors.right: parent.right
            anchors.rightMargin: Math.round((parent.width - notchBody.visualW) / 2) + unit.restTimeInset
            value: pillStatus.batteryFraction
            available: pillStatus.batteryPresent
            glyph: pillStatus.batteryPresent ? pillStatus.batteryGlyph : "󰂑"
            nudgeY: unit.batteryDialNudgeY
            accent: Color.accent
            z: 3
            opacity: unit.pillStatusMode ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: root.motion.base; easing.type: Easing.OutCubic } }
          }

          // Maximum collapse: the surface has shrunk to the dot, so the wings
          // are gone and the wall clock is shown centred as HH:mm. It uses the
          // SAME face, size, weight, tracking and glow as the split clock; only
          // its surface is smaller. The colon shares the blink phase. On a
          // notched host the dot sits behind the physical cutout; the effect is
          // for flat displays, and harmless when hidden by the hardware.
          Row {
            id: pillDotClock
            anchors.centerIn: parent
            z: 4
            opacity: (unit.pillMinimized && !unit.pillTimeDeferred && !unit.pillStatusMode) ? 1 : 0
            transformOrigin: Item.Center
            scale: unit.pillMinimized ? 1 : 0.6
            Behavior on opacity { NumberAnimation { duration: root.motion.base; easing.type: Easing.OutCubic } }
            Behavior on scale {
              NumberAnimation {
                duration: root.motion.base
                easing.type: Easing.OutElastic
                easing.amplitude: root.motion.elasticAmplitude
                easing.period: root.motion.elasticPeriod
              }
            }
            // The dot surface must fit the clock at FULL size, so its measured
            // width is published back to the unit (dotWidth drives the collapse
            // floor). The texts do not depend on it, so this cannot loop.
            Binding {
              target: unit
              property: "dotWidth"
              value: Math.max(unit.pillHeight, Math.ceil(pillDotClock.implicitWidth) + Style.space(8))
            }
            // One glow for the whole HH:mm row.
            layer.enabled: true
            layer.effect: MultiEffect {
              shadowEnabled: true
              shadowBlur: unit.pillTimeGlowBlur
              shadowColor: unit.pillTimeGlowColor
              shadowOpacity: unit.pillTimeGlowOpacity
              shadowVerticalOffset: 0
              shadowHorizontalOffset: 0
              autoPaddingEnabled: false
            }

            Text {
              text: root.pillHourText
              color: Color.bar.text
              font.family: Style.font.family
              font.pixelSize: unit.pillTimeSize
              font.weight: unit.pillTimeWeight
              font.letterSpacing: unit.pillTimeTracking
              font.features: unit.pillTimeFeatures
            }
            Text {
              text: ":"
              color: Color.bar.text
              opacity: unit.colonBlinkOn ? 1 : 0
              font.family: Style.font.family
              font.pixelSize: unit.pillTimeSize
              font.weight: unit.pillTimeWeight
              font.letterSpacing: unit.pillTimeTracking
              font.features: unit.pillTimeFeatures
            }
            Text {
              text: root.pillMinuteText
              color: Color.bar.text
              font.family: Style.font.family
              font.pixelSize: unit.pillTimeSize
              font.weight: unit.pillTimeWeight
              font.letterSpacing: unit.pillTimeTracking
              font.features: unit.pillTimeFeatures
            }
          }

          // Extended (split) clock: the hour lives in the left wing and the
          // minutes in the right one, so the colon sits at the pill centre and
          // shares the blink phase. On a notched host it falls behind the
          // physical cutout; on a flat display it reads as a plain HH : mm.
          Text {
            id: pillSplitColon
            anchors.centerIn: parent
            text: ":"
            color: Color.bar.text
            font.family: Style.font.family
            font.pixelSize: unit.pillTimeSize
            font.weight: unit.pillTimeWeight
            font.letterSpacing: unit.pillTimeTracking
            font.features: unit.pillTimeFeatures
            z: 3
            opacity: (unit.splitClockVisible && unit.colonBlinkOn) ? 1 : 0
            layer.enabled: true
            layer.effect: MultiEffect {
              shadowEnabled: true
              shadowBlur: unit.pillTimeGlowBlur
              shadowColor: unit.pillTimeGlowColor
              shadowOpacity: unit.pillTimeGlowOpacity
              shadowVerticalOffset: 0
              shadowHorizontalOffset: 0
              autoPaddingEnabled: false
            }
          }

        }
      }
    }

    // --- island body surface: renders below the pill while expanded --------
    PanelWindow {
      id: islandWindow

      screen: unit.hostScreen
      // The body unmaps while a plugin window is open so the grid can never
      // sit behind the panel. The grid items stay alive (they are instantiated
      // permanently), so this only hides the window — it does not kill the
      // widgets. Solo mode is the exception: the single centered tile is the
      // open panel's live anchor, so the body must stay mapped or the panel
      // loses it (Function 2, step 3).
      //
      // unit.bodyHeld keeps the surface mapped for one motion beat after a
      // normal collapse so the card can retract with its own animation instead
      // of being cut off by the unmap. It never overrides the plugin rule: the
      // last clause still wins when a panel is up.
      visible: (unit.islandState.expanded || unit.bodyHeld) && !root.barHidden
        && (!unit.pluginWindowOpen || unit.soloMode || unit.bodyKeptForPanel)
      color: "transparent"
      surfaceFormat.opaque: false
      // The body overlays; only the pill strip reserves desktop space.
      exclusionMode: ExclusionMode.Ignore
      anchors {
        top: true
        left: true
        right: true
      }
      margins.top: unit.pillHeight + Style.space(2) + unit.debugTopOffset
      implicitWidth: 0
      implicitHeight: islandCard.height + Style.space(8)
      WlrLayershell.namespace: "notch-island-body"
      WlrLayershell.layer: WlrLayer.Top
      // While the pointer is on the island the body takes the keyboard so a
      // bare Escape returns to rest; focus is released the instant the pointer
      // leaves or a plugin window opens (see escapeFocusWanted).
      // Only the two states that are safe: Exclusive while the user is on the
      // body, None otherwise. OnDemand is deliberately not used any more - a
      // visible-but-idle island could still be handed the keyboard, which is
      // exactly what an automatic open must never do.
      WlrLayershell.keyboardFocus: unit.escapeFocusWanted
        ? WlrKeyboardFocus.Exclusive
        : WlrKeyboardFocus.None

      // Clicks on the body window outside the card (the sides of the strip)
      // dismiss the view.
      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton
        onClicked: unit.islandState.collapse()
        z: 0
      }

      DynamicIsland {
        id: islandCard
        anchors.top: parent.top
        anchors.horizontalCenter: parent.horizontalCenter
        islandState: unit.islandState
        islandBar: root
        islandUnit: unit
        // The compact media peek is a slim strip, not a page: narrow the card
        // while it is the thing being peeked. It only ever appears when the
        // island was at rest, so this never resizes an island the user opened.
        targetWidth: (unit.transientPeek && contextResolver
                      && contextResolver.transientId === contextResolver.mediaPeekContextId)
          ? Math.min(unit.expandedWidth, Style.space(380))
          : unit.expandedWidth
        onCardHoveredChanged: unit.setCardHovered(cardHovered)
        // The card animates/grows while a fresh grid's widgets load; each
        // resize can steal the pill's hover, so treat it as activity until
        // the body has actually stopped changing size.
        onHeightChanged: unit.noteBodyResize()
        Component.onDestruction: unit.setCardHovered(false)
        z: 2
        // Escape returns the island to rest while the pointer is on it (the
        // window holds keyboard focus in that state; see escapeFocusWanted).
        focus: true
        Keys.onEscapePressed: function(event) {
          unit.markInteraction()
          unit.suppressHoverAfterDismiss()
          unit.islandState.collapse()
          event.accepted = true
        }
        // Keyboard paging: while the island holds focus, the arrow keys move
        // between context pages (a testable fallback for the swipe).
        Keys.onLeftPressed: function(event) {
          if (!unit.islandState.paging || unit.islandState.pageCount <= 1) return
          unit.markInteraction()
          unit.islandState.pagePrev()
          event.accepted = true
        }
        Keys.onRightPressed: function(event) {
          if (!unit.islandState.paging || unit.islandState.pageCount <= 1) return
          unit.markInteraction()
          unit.islandState.pageNext()
          event.accepted = true
        }
      }
    }
  }
}
