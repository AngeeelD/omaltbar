import QtQuick
import Quickshell
import qs.Ui
import qs.Commons

// Notch Island — settings panel content.
//
// Hosted by SettingsWidget's KeyboardPanel, in whichever bar is currently
// active (the island or the stock omarchy.bar). It therefore depends only on the
// two surfaces every bar exposes: `bar.barConfig` for reading and
// `bar.shell.mutateShellConfig` for writing. Nothing here assumes the island is
// the active bar — the whole point of the bar section is to switch between them.
//
// Round 8b covers the BAR and TIMING sections. The interaction and context
// feature-flag sections land in 8c; the optional doctor section in 8d.
Column {
  id: root

  // The hosting bar. Injected by SettingsWidget.
  required property var bar

  // Emitted when an action will replace or remove this widget (loading another
  // bar, hiding the settings icon). The widget closes the panel first; the write
  // is deferred so it is not running while its own host is being torn down.
  signal requestClose()

  // The bar switch is owned by SettingsWidget: switching to the stock bar
  // disables the plugin, so it goes through a confirmation overlay that lives
  // outside this scrollable content.
  signal requestBarSwitch(string targetId)

  spacing: Style.space(14)

  // --- theme + state --------------------------------------------------------
  readonly property color foreground: (bar && bar.foreground) ? bar.foreground : Color.foreground
  readonly property string fontFamily: (bar && bar.fontFamily) ? bar.fontFamily : Style.font.family

  readonly property var barConfig: bar ? bar.barConfig : null

  readonly property bool islandActive: {
    var id = String((barConfig && barConfig.id) || "")
    return id === "angeeeld.omaltbar"
  }
  readonly property string activeBarValue: root.islandActive ? "angeeeld.omaltbar" : "omarchy.bar"

  readonly property bool settingsIconOn: {
    var v = barConfig ? barConfig.islandSettingsIcon : undefined
    return (v === undefined || v === null) ? true : v === true
  }

  readonly property bool invertPillClicks: (barConfig && barConfig.islandInvertPillClicks) === true

  // Surface appearance. `transparent` is the master switch (it lives in
  // shell.json as bar.transparent and is also what the pill/body read), and
  // `islandOpacity` only modulates it; while transparency is off the surfaces
  // paint opaque and the slider is inert.
  readonly property bool transparent: (barConfig && barConfig.transparent) === true
  readonly property real islandOpacity: root.barReal("islandOpacity", 0.72)

  // Pill form + length (round 9b). Absent `islandPillCompact` means compact:
  // the notch-wide pill is the opt-in look, since most installs have no cutout.
  readonly property bool pillCompact: {
    var v = root.barConfig ? root.barConfig.islandPillCompact : undefined
    return (v === undefined || v === null) ? true : v === true
  }
  readonly property int pillWidthOverride: {
    var v = Number(root.barConfig ? root.barConfig.islandPillWidth : 0)
    return (isFinite(v) && v > 0) ? Math.round(v) : 0
  }
  // Where the slider sits when there is no override: the island bar reports the
  // width it is actually deriving. The stock bar has no island, so fall back to
  // the calibrated 14" pill so the control is still usable (the value only
  // matters once the island is the bar again).
  readonly property int pillWidthEffective: {
    var v = root.bar ? Number(root.bar.pillWidthEffective) : NaN
    if (isFinite(v) && v > 0) return Math.round(v)
    return 546
  }
  readonly property bool pillWidthIsAuto: root.pillWidthOverride === 0

  // True while a hotkey field owns the keyboard. SettingsWidget forwards this to
  // PanelKeyCatcher.blocked so the inline editors receive keys normally instead
  // of the panel consuming them (Escape/Tab/arrows).
  readonly property bool editorActive: hotkeyToggleField.activeFocus || hotkeySettingsField.activeFocus

  readonly property string hotkeyToggle: {
    var map = (barConfig && barConfig.islandHotkeys) || {}
    return String(map["island.toggle"] || "")
  }
  readonly property string hotkeySettingsPanel: {
    var map = (barConfig && barConfig.islandHotkeys) || {}
    return String(map["island.settings"] || "")
  }

  readonly property string pluginDir: {
    var m = bar ? bar.manifest : null
    if (m && m.__sourceDir) return String(m.__sourceDir)
    return Quickshell.env("HOME") + "/.config/omarchy/plugins/angeeeld.omaltbar"
  }
  readonly property string hotkeyScript: root.pluginDir + "/hotkeys.sh"

  // --- config plumbing ------------------------------------------------------
  function mutate(mutator) {
    if (!bar || !bar.shell || typeof bar.shell.mutateShellConfig !== "function") return false
    bar.shell.mutateShellConfig(mutator)
    return true
  }

  function barNumber(key, fallback) {
    var source = root.barConfig ? root.barConfig[key] : undefined
    var v = Number(source)
    return (isFinite(v) && v >= 0 && source !== undefined && source !== null) ? v : fallback
  }

  // Real-valued sibling of barNumber, for the opacity key.
  function barReal(key, fallback) {
    var source = root.barConfig ? root.barConfig[key] : undefined
    if (source === undefined || source === null) return fallback
    var v = Number(source)
    return isFinite(v) ? v : fallback
  }

  function setTransparent(on) {
    var next = on === true
    root.mutate(function(config) {
      if (!Util.isPlainObject(config.bar)) config.bar = {}
      config.bar.transparent = next
    })
  }

  // Rounded to two decimals so a drag writes 0.7, never 0.7000000000000001.
  function setIslandOpacity(value) {
    var v = Math.round(Number(value) * 100) / 100
    if (!isFinite(v)) return
    root.mutate(function(config) {
      if (!Util.isPlainObject(config.bar)) config.bar = {}
      config.bar.islandOpacity = v
    })
  }

  // Pill form. Written to the config (not to the bar object) so it also works
  // while the stock bar is the host; the island picks it up on the config
  // reload, which is why the same row here and the pill's right click agree.
  function setPillCompact(on) {
    var next = on === true
    root.mutate(function(config) {
      if (!Util.isPlainObject(config.bar)) config.bar = {}
      config.bar.islandPillCompact = next
    })
  }

  // Pill length override. 0 removes the key, restoring the derived geometry.
  function setPillWidth(value) {
    var v = Math.round(Number(value))
    var next = (isFinite(v) && v > 0) ? Math.max(140, Math.min(900, v)) : 0
    root.mutate(function(config) {
      if (!Util.isPlainObject(config.bar)) return
      if (next > 0) config.bar.islandPillWidth = next
      else delete config.bar.islandPillWidth
    })
  }

  function setTiming(key, value) {
    var v = Math.round(Number(value))
    if (!isFinite(v)) return
    root.mutate(function(config) {
      if (!Util.isPlainObject(config.bar)) config.bar = {}
      config.bar[key] = v
    })
  }

  function resetTiming() {
    root.mutate(function(config) {
      if (!Util.isPlainObject(config.bar)) return
      for (var i = 0; i < root.timingKeys.length; i++) delete config.bar[root.timingKeys[i]]
    })
  }

  // Bar selection is handed to the hosting widget, which confirms the
  // stock-bar direction before writing `bar.id`. An empty bar.id means the stock
  // bar, exactly like `omarchy bar use default`; both targets are valid bars, so
  // there is no intermediate state where the desktop has none.

  function setSettingsIcon(on) {
    var next = on === true
    root.requestClose()
    root.defer(function() {
      root.mutate(function(config) {
        if (!Util.isPlainObject(config.bar)) config.bar = {}
        config.bar.islandSettingsIcon = next
      })
    })
  }

  function setInvertPillClicks(on) {
    var next = on === true
    root.mutate(function(config) {
      if (!Util.isPlainObject(config.bar)) config.bar = {}
      config.bar.islandInvertPillClicks = next
    })
  }

  // --- context feature flags ------------------------------------------------
  readonly property var disabledContexts: {
    var raw = root.barConfig ? root.barConfig.islandDisabledContexts : null
    return Array.isArray(raw) ? raw : []
  }

  function contextEnabled(id) {
    return root.disabledContexts.indexOf(String(id || "")) === -1
  }

  function setContextEnabled(id, on) {
    var key = String(id || "")
    if (!key) return
    var next = []
    for (var i = 0; i < root.disabledContexts.length; i++) {
      var existing = String(root.disabledContexts[i])
      if (existing && existing !== key && next.indexOf(existing) === -1) next.push(existing)
    }
    if (on !== true) next.push(key)
    root.mutate(function(config) {
      if (!Util.isPlainObject(config.bar)) config.bar = {}
      if (next.length > 0) config.bar.islandDisabledContexts = next
      else delete config.bar.islandDisabledContexts
    })
  }

  // Persist both shortcuts in one write, then mirror them into Hyprland's Lua
  // config through the plugin's script (the only persistent keybind path —
  // Hyprland has no runtime bind API). Empty fields remove the action.
  function applyHotkeys() {
    var toggle = String(hotkeyToggleField.text || "").trim()
    var openPanel = String(hotkeySettingsField.text || "").trim()
    root.mutate(function(config) {
      if (!Util.isPlainObject(config.bar)) config.bar = {}
      var next = {}
      if (toggle) next["island.toggle"] = toggle
      if (openPanel) next["island.settings"] = openPanel
      if (Object.keys(next).length > 0) config.bar.islandHotkeys = next
      else delete config.bar.islandHotkeys
    })
    Quickshell.execDetached(["bash", root.hotkeyScript, "render"])
  }

  // Deferred write: used only by actions that destroy or re-anchor this widget.
  property var pendingWrite: null
  function defer(write) {
    root.pendingWrite = write
    deferTimer.restart()
  }
  Timer {
    id: deferTimer
    interval: 220
    repeat: false
    onTriggered: {
      var write = root.pendingWrite
      root.pendingWrite = null
      if (write) write()
    }
  }

  // --- data -----------------------------------------------------------------
  // Timing/motion rows. `islandToastTtlMs` is intentionally absent: the toast
  // snapshot TTL is derived from the hold so it always outlives the animation.
  readonly property var timingRows: [
    { key: "islandTransientTtlMs", label: "Transient overlay", hint: "How long the volume and brightness overlay stays up.", min: 600, max: 10000, step: 100, def: 1600 },
    { key: "islandTransientLeadMs", label: "Transient collapse lead", hint: "How early the peek starts collapsing before the overlay ends.", min: 0, max: 1500, step: 50, def: 300 },
    { key: "islandToastHoldMs", label: "Notification toast hold", hint: "How long the island stays expanded for a new notification.", min: 1000, max: 15000, step: 250, def: 6500 },
    { key: "islandMediaPeekMs", label: "Media peek", hint: "How long the compact now-playing strip stays up when playback changes on its own.", min: 800, max: 8000, step: 100, def: 2600 },
    { key: "islandMotionFast", label: "Motion · fast", hint: "Small state changes (tile fades, hover feedback).", min: 80, max: 1500, step: 20, def: 200 },
    { key: "islandMotionBase", label: "Motion · base", hint: "Pill and body transitions.", min: 80, max: 2500, step: 20, def: 340 },
    { key: "islandMotionSlow", label: "Motion · slow", hint: "Large reveals and page changes.", min: 80, max: 4000, step: 20, def: 560 }
  ]

  readonly property var timingKeys: [
    "islandTransientTtlMs", "islandTransientLeadMs", "islandToastHoldMs",
    "islandToastTtlMs", "islandMediaPeekMs",
    "islandMotionFast", "islandMotionBase", "islandMotionSlow"
  ]

  // Every context provider the island can surface. `island.default` is not
  // listed: the composed deck is the fallback page and always exists.
  readonly property var contextFlags: [
    { id: "omarchy.media", label: "Media player", hint: "The full now-playing page, and the pill's mini-player." },
    { id: "island.mediaPeek", label: "Media peek", hint: "The compact now-playing strip when playback changes on its own." },
    { id: "omarchy.volume", label: "Volume overlay", hint: "The key-driven volume OSD." },
    { id: "island.brightness", label: "Brightness overlay", hint: "The key-driven brightness OSD." },
    { id: "omarchy.microphone", label: "Microphone", hint: "Microphone-in-use page with its mute toggle." },
    { id: "jankeesvw.notification-center", label: "Notifications", hint: "The notification history page." },
    { id: "island.notificationToast", label: "Notification toast", hint: "Expand the island for a new notification. Off keeps the normal top-right popup." },
    { id: "island.screenrecord", label: "Screen recording", hint: "The recording indicator page with its stop button." }
  ]

  // --- content --------------------------------------------------------------
  Text {
    width: parent.width
    text: "Omaltbar"
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.display
    font.bold: true
  }

  PanelSectionHeader {
    width: parent.width
    text: "BAR"
    foreground: root.foreground
    fontFamily: root.fontFamily
  }

  Column {
    width: parent.width
    spacing: Style.space(6)

    Text {
      width: parent.width
      text: "Active bar"
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }

    ButtonGroup {
      options: [
        { value: "angeeeld.omaltbar", label: "Omaltbar" },
        { value: "omarchy.bar", label: "Stock bar" }
      ]
      value: root.activeBarValue
      foreground: root.foreground
      fontFamily: root.fontFamily
      onChanged: function(v) { if (v !== root.activeBarValue) root.requestBarSwitch(v) }
    }

    Text {
      width: parent.width
      wrapMode: Text.WordWrap
      text: "Applies immediately — the bar reloads and this panel closes. The settings icon stays on the bar, so you can switch back from either one."
      color: root.foreground
      opacity: 0.5
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
  }

  SwitchRow {
    width: parent.width
    label: "Settings icon"
    hint: "Keep the gear on the bar. Hiding it also closes this panel — restore it with: omarchy-shell omarchy.bar settingsIcon true"
    checked: root.settingsIconOn
    foreground: root.foreground
    fontFamily: root.fontFamily
    onToggled: function(next) { root.setSettingsIcon(next) }
  }

  PanelSeparator { width: parent.width; foreground: root.foreground }

  PanelSectionHeader {
    width: parent.width
    text: "APPEARANCE"
    foreground: root.foreground
    fontFamily: root.fontFamily
  }

  SwitchRow {
    width: parent.width
    label: "Transparent surfaces"
    hint: "Master switch for the notch pill and the island body. Off paints both fully opaque; on lets the opacity below show through."
    checked: root.transparent
    foreground: root.foreground
    fontFamily: root.fontFamily
    onToggled: function(next) { root.setTransparent(next) }
  }

  OpacityRow { width: parent.width }

  Column {
    width: parent.width
    spacing: Style.space(6)

    Text {
      width: parent.width
      text: "Pill form"
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }

    ButtonGroup {
      options: [
        { value: "compact", label: "Compact" },
        { value: "notch", label: "Notch" }
      ]
      value: root.pillCompact ? "compact" : "notch"
      foreground: root.foreground
      fontFamily: root.fontFamily
      onChanged: function(v) { if ((v === "compact") !== root.pillCompact) root.setPillCompact(v === "compact") }
    }

    Text {
      width: parent.width
      wrapMode: Text.WordWrap
      text: root.pillCompact
        ? "A single small badge at the notch: time, or the status dials. Right-clicking the pill switches form too, and remembers."
        : "The wide pill: the simulated cutout flanked by the clock and the mini-player. Tune its length below to match your cutout."
      color: root.foreground
      opacity: 0.5
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
  }

  PillLengthRow { width: parent.width }

  PanelSeparator { width: parent.width; foreground: root.foreground }

  PanelSectionHeader {
    width: parent.width
    text: "TIMING"
    foreground: root.foreground
    fontFamily: root.fontFamily
  }

  Repeater {
    model: root.timingRows
    delegate: TimingRow { width: root.width }
  }

  Button {
    text: "Reset timing to defaults"
    bordered: true
    foreground: root.foreground
    fontFamily: root.fontFamily
    onClicked: root.resetTiming()
  }

  PanelSeparator { width: parent.width; foreground: root.foreground }

  PanelSectionHeader {
    width: parent.width
    text: "INTERACTION"
    foreground: root.foreground
    fontFamily: root.fontFamily
  }

  SwitchRow {
    width: parent.width
    label: "Invert pill clicks"
    hint: root.invertPillClicks
      ? "Left click toggles the indicator row. Right click pins the compact dot."
      : "Left click pins the compact dot. Right click toggles the indicator row."
    checked: root.invertPillClicks
    foreground: root.foreground
    fontFamily: root.fontFamily
    onToggled: function(next) { root.setInvertPillClicks(next) }
  }

  PanelSeparator { width: parent.width; foreground: root.foreground }

  PanelSectionHeader {
    width: parent.width
    text: "HOTKEYS"
    foreground: root.foreground
    fontFamily: root.fontFamily
  }

  Text {
    width: parent.width
    wrapMode: Text.WordWrap
    text: "Hyprland key syntax, e.g. SUPER + MOD3 + Hyper_L (Super+Caps with caps:hyper). Leave a field empty to remove that shortcut."
    color: root.foreground
    opacity: 0.5
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  Column {
    width: parent.width
    spacing: Style.space(4)

    Text {
      width: parent.width
      text: "Toggle island"
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }
    TextField {
      id: hotkeyToggleField
      width: parent.width
      text: root.hotkeyToggle
      placeholderText: "not set"
      foreground: root.foreground
      font.family: root.fontFamily
    }
  }

  Column {
    width: parent.width
    spacing: Style.space(4)

    Text {
      width: parent.width
      text: "Open settings panel"
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }
    TextField {
      id: hotkeySettingsField
      width: parent.width
      text: root.hotkeySettingsPanel
      placeholderText: "not set"
      foreground: root.foreground
      font.family: root.fontFamily
    }
  }

  Button {
    text: "Apply shortcuts and reload Hyprland"
    bordered: true
    foreground: root.foreground
    fontFamily: root.fontFamily
    onClicked: root.applyHotkeys()
  }

  Text {
    width: parent.width
    wrapMode: Text.WordWrap
    text: "Persisted in shell.json and mirrored into a managed block in ~/.config/hypr/bindings.lua, then hyprctl reload. Any hand-written bind on the same key is unbound first, so it cannot fire twice."
    color: root.foreground
    opacity: 0.5
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  PanelSeparator { width: parent.width; foreground: root.foreground }

  PanelSectionHeader {
    width: parent.width
    text: "CONTEXTS"
    foreground: root.foreground
    fontFamily: root.fontFamily
  }

  Text {
    width: parent.width
    wrapMode: Text.WordWrap
    text: "Turn a provider off and the island stops surfacing it: no page, no entry page, no overlay. The composed deck is always the fallback."
    color: root.foreground
    opacity: 0.5
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  Repeater {
    model: root.contextFlags
    // Declared as a property (not read as a context property) so the Repeater
    // injects it before the delegate completes — the same shape the timing rows
    // use. Reading `modelData` directly at the delegate root evaluates before the
    // model is attached and assigns undefined to the required strings.
    delegate: SwitchRow {
      required property var modelData
      width: root.width
      label: modelData.label
      hint: modelData.hint
      checked: root.contextEnabled(modelData.id)
      foreground: root.foreground
      fontFamily: root.fontFamily
      onToggled: function(next) { root.setContextEnabled(modelData.id, next) }
    }
  }

  PanelSeparator { width: parent.width; foreground: root.foreground }

  SettingsDoctor {
    width: parent.width
    bar: root.bar
  }

  // --- inline components ----------------------------------------------------
  component SwitchRow: Item {
    id: switchRow
    required property string label
    required property string hint
    required property bool checked
    required property color foreground
    required property string fontFamily
    signal toggled(bool next)

    implicitHeight: Math.max(switchText.implicitHeight, switchControl.implicitHeight)

    Column {
      id: switchText
      anchors.left: parent.left
      anchors.right: switchControl.left
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)

      Text {
        width: parent.width
        text: switchRow.label
        color: switchRow.foreground
        font.family: switchRow.fontFamily
        font.pixelSize: Style.font.body
      }
      Text {
        width: parent.width
        text: switchRow.hint
        color: switchRow.foreground
        opacity: 0.5
        wrapMode: Text.WordWrap
        font.family: switchRow.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
    }

    ToggleSwitch {
      id: switchControl
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      checked: switchRow.checked
      foreground: switchRow.foreground
      onToggled: switchRow.toggled(!switchRow.checked)
    }
  }

  // Opacity of both island surfaces, as a percentage. Inert (and disabled)
  // while the transparent master switch is off, which is exactly how the bar
  // reads the two keys, so the panel matches the painted result.
  component OpacityRow: Column {
    id: opacityRow
    spacing: Style.space(4)
    opacity: root.transparent ? 1 : 0.45

    Row {
      width: parent.width
      spacing: Style.space(8)

      Text {
        width: parent.width - opacityValue.width
        text: "Island opacity"
        color: root.foreground
        elide: Text.ElideRight
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }
      Text {
        id: opacityValue
        text: Math.round(opacitySlider.liveValue * 100) + "%"
        color: root.foreground
        opacity: 0.75
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }
    }

    NoWheelSlider {
      id: opacitySlider
      width: parent.width
      foreground: root.foreground
      minimum: 0.2
      maximum: 1.0
      step: 0.05
      integer: false
      enabled: root.transparent
      value: root.islandOpacity
      onReleased: function(v) { root.setIslandOpacity(v) }
    }

    Text {
      width: parent.width
      text: root.transparent
        ? "Applies to the notch pill and the island body together."
        : "Turn on Transparent surfaces to see this value."
      color: root.foreground
      opacity: 0.5
      wrapMode: Text.WordWrap
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
  }

  // Pill length in logical px. The slider starts where the pill actually is
  // (the bar reports the derived width) so the first drag is relative to what
  // the user sees; any drag writes an explicit override, and Reset to auto
  // removes it. Inert in compact form, which always measures the badge itself.
  component PillLengthRow: Column {
    id: pillLengthRow
    spacing: Style.space(4)
    opacity: root.pillCompact ? 0.45 : 1

    Row {
      width: parent.width
      spacing: Style.space(8)

      Text {
        width: parent.width - pillLengthValue.width
        text: "Pill length"
        color: root.foreground
        elide: Text.ElideRight
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }
      Text {
        id: pillLengthValue
        text: Math.round(pillLengthSlider.liveValue) + " px" + (root.pillWidthIsAuto ? " · auto" : "")
        color: root.foreground
        opacity: 0.75
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }
    }

    NoWheelSlider {
      id: pillLengthSlider
      width: parent.width
      foreground: root.foreground
      minimum: 140
      maximum: 900
      step: 10
      integer: true
      enabled: !root.pillCompact
      value: root.pillWidthOverride > 0 ? root.pillWidthOverride : root.pillWidthEffective
      onReleased: function(v) { root.setPillWidth(v) }
    }

    Row {
      width: parent.width
      spacing: Style.space(8)

      Text {
        width: parent.width - pillAutoButton.width
        text: root.pillCompact
          ? "Only applies to the Notch form."
          : "Type any width between 140 and 900 px; auto follows the cutout."
        color: root.foreground
        opacity: 0.5
        wrapMode: Text.WordWrap
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      Button {
        id: pillAutoButton
        visible: !root.pillWidthIsAuto
        text: "Reset to auto"
        bordered: true
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: root.setPillWidth(0)
      }
    }
  }

  component TimingRow: Column {
    id: timingRow
    required property var modelData
    spacing: Style.space(4)

    Row {
      width: parent.width
      spacing: Style.space(8)

      Text {
        width: parent.width - timingValue.width
        text: timingRow.modelData.label
        color: root.foreground
        elide: Text.ElideRight
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }
      Text {
        id: timingValue
        text: Math.round(timingSlider.liveValue) + " ms"
        color: root.foreground
        opacity: 0.75
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }
    }

    NoWheelSlider {
      id: timingSlider
      width: parent.width
      foreground: root.foreground
      minimum: Number(timingRow.modelData.min)
      maximum: Number(timingRow.modelData.max)
      step: Number(timingRow.modelData.step)
      integer: true
      value: root.barNumber(timingRow.modelData.key, timingRow.modelData.def)
      onReleased: function(v) { root.setTiming(timingRow.modelData.key, v) }
    }

    Text {
      width: parent.width
      text: timingRow.modelData.hint
      color: root.foreground
      opacity: 0.5
      wrapMode: Text.WordWrap
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
  }

  // A slider that leaves the mouse wheel alone. Upstream PanelSlider handles
  // `onWheel` and commits on every notch, so scrolling this panel and crossing a
  // slider silently edited its value instead of scrolling — which also made the
  // scroll feel like it stalled. Using pointer handlers (no MouseArea, no
  // WheelHandler) means the wheel propagates to the enclosing ScrollView.
  component NoWheelSlider: Item {
    id: slider

    property real value: 0
    property real minimum: 0
    property real maximum: 1
    property real step: 1
    property bool integer: true
    property color foreground: Color.foreground
    property real liveValue: value
    property bool dragging: false

    signal released(real value)

    readonly property real range: Math.max(0.0001, maximum - minimum)
    readonly property real progress: Math.max(0, Math.min(1, (liveValue - minimum) / range))
    readonly property color trackColor: Util.alpha(slider.foreground, 0.18)

    onValueChanged: if (!slider.dragging) slider.liveValue = value

    function valueFromX(x) {
      var width = Math.max(1, slider.width)
      var clamped = Math.max(0, Math.min(width, x))
      var raw = slider.minimum + (clamped / width) * slider.range
      // Snap to `step`: without it a drag lands on arbitrary values (1600 vs
      // 2006) and the config reads like noise.
      if (slider.step > 0) raw = Math.round(raw / slider.step) * slider.step
      if (slider.integer) raw = Math.round(raw)
      return Math.max(slider.minimum, Math.min(slider.maximum, raw))
    }

    implicitHeight: Math.max(Style.space(20), Math.round(Style.spacing.controlHeight * 0.55))

    Rectangle {
      id: track
      anchors.verticalCenter: parent.verticalCenter
      anchors.left: parent.left
      anchors.right: parent.right
      height: Math.max(4, Math.round(Style.spacing.controlHeight * 0.11))
      radius: height / 2
      color: slider.trackColor
    }
    Rectangle {
      anchors.verticalCenter: track.verticalCenter
      anchors.left: track.left
      height: track.height
      radius: track.radius
      color: slider.foreground
      width: track.width * slider.progress
    }
    Rectangle {
      width: Math.max(12, Math.round(Style.spacing.controlHeight * 0.32))
      height: width
      radius: width / 2
      color: slider.foreground
      anchors.verticalCenter: track.verticalCenter
      x: Math.max(0, Math.min(track.width - width, track.width * slider.progress - width / 2))
    }

    HoverHandler { cursorShape: Qt.PointingHandCursor }

    TapHandler {
      acceptedButtons: Qt.LeftButton
      onTapped: function(eventPoint) {
        var v = slider.valueFromX(eventPoint.position.x)
        slider.liveValue = v
        slider.released(v)
      }
    }

    DragHandler {
      target: null
      xAxis.enabled: true
      yAxis.enabled: false
      onActiveChanged: {
        if (active) {
          slider.dragging = true
          slider.liveValue = slider.valueFromX(centroid.position.x)
        } else {
          slider.dragging = false
          slider.released(slider.liveValue)
        }
      }
      onCentroidChanged: {
        if (active) slider.liveValue = slider.valueFromX(centroid.position.x)
      }
    }
  }
}
