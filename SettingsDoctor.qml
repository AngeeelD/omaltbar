import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

// Notch Island — doctor.
//
// Read-only diagnostics for the parts of the setup that live OUTSIDE the plugin
// folder: the bar selection, the hotkey prerequisites, the media-key rebinds and
// the managed keybind block. Every one of those fails SILENTLY — the island just
// does not do what the README says it will, with nothing in the journal — so
// naming them explicitly is worth the space.
//
// Deliberately static: it reads the user's Hyprland files rather than asking
// Hyprland, so there is no subprocess to fail and no plain-output parsing of
// `hyprctl binds` (which does not report the dispatched command on 0.56.x).
Column {
  id: root

  required property var bar

  readonly property color foreground: (bar && bar.foreground) ? bar.foreground : Color.foreground
  readonly property string fontFamily: (bar && bar.fontFamily) ? bar.fontFamily : Style.font.family
  readonly property color warnColor: (bar && bar.urgent) ? bar.urgent : Color.accent

  readonly property var barConfig: bar ? bar.barConfig : null
  readonly property string hyprDir: Quickshell.env("HOME") + "/.config/hypr"

  property string inputLua: ""
  property string bindingsLua: ""

  FileView {
    path: root.hyprDir + "/input.lua"
    watchChanges: true
    printErrors: false
    onLoaded: root.inputLua = text()
    onFileChanged: reload()
    onLoadFailed: root.inputLua = ""
  }
  FileView {
    path: root.hyprDir + "/bindings.lua"
    watchChanges: true
    printErrors: false
    onLoaded: root.bindingsLua = text()
    onFileChanged: reload()
    onLoadFailed: root.bindingsLua = ""
  }

  readonly property bool islandActive:
    String((root.barConfig && root.barConfig.id) || "") === "angeeeld.omaltbar"

  readonly property bool settingsIconInBar: {
    var cfg = root.barConfig
    if (!cfg || !cfg.layout) return false
    var sections = ["left", "center", "right"]
    for (var s = 0; s < sections.length; s++) {
      var entries = cfg.layout[sections[s]]
      if (!Array.isArray(entries)) continue
      for (var i = 0; i < entries.length; i++) {
        var entry = entries[i]
        var id = String((entry && entry.id !== undefined) ? entry.id : (entry || ""))
        if (id === "angeeeld.omaltbar") return true
      }
    }
    return false
  }

  readonly property bool capsHyper: root.inputLua.indexOf("caps:hyper") !== -1

  // Both halves matter: without the `hl.unbind` the omarchy-osd handler stays
  // bound alongside the island route and BOTH fire.
  readonly property bool volumeKeyRebound:
    root.bindingsLua.indexOf('hl.unbind("XF86AudioRaiseVolume")') !== -1
      && root.bindingsLua.indexOf('o.bind("XF86AudioRaiseVolume"') !== -1
  readonly property bool brightnessKeyRebound:
    root.bindingsLua.indexOf('hl.unbind("XF86MonBrightnessUp")') !== -1
      && root.bindingsLua.indexOf('o.bind("XF86MonBrightnessUp"') !== -1

  readonly property bool managedBlock:
    root.bindingsLua.indexOf(">>> angeeeld.omaltbar hotkeys") !== -1

  // The block is written at the end of bindings.lua, so everything after the
  // marker is ours. Counting the managed binds keeps the row informative when
  // the block exists but every shortcut was cleared.
  readonly property int managedBindCount: {
    var marker = ">>> angeeeld.omaltbar hotkeys"
    var idx = root.bindingsLua.indexOf(marker)
    if (idx < 0) return 0
    var text = root.bindingsLua.substring(idx)
    var count = 0
    var at = 0
    while (true) {
      var found = text.indexOf("o.bind(", at)
      if (found < 0) break
      count++
      at = found + 7
    }
    return count
  }

  // Only the island root exposes the backlight watcher; on the stock bar the
  // question does not apply, so it reports healthy rather than warning.
  readonly property bool brightnessApplicable: !!(bar && bar.brightnessState !== undefined)
  readonly property bool brightnessAvailable:
    root.brightnessApplicable ? (bar.brightnessState && bar.brightnessState.available === true) : true

  readonly property var checks: [
    {
      label: "Island is the active bar",
      ok: root.islandActive,
      detail: root.islandActive ? "bar.id = angeeeld.omaltbar" : "another bar is selected",
      hint: root.islandActive ? "" : "Restore it with: omarchy bar use angeeeld.omaltbar"
    },
    {
      label: "Settings icon on the bar",
      ok: root.settingsIconInBar,
      detail: root.settingsIconInBar ? "present in bar.layout" : "not in any bar section",
      hint: root.settingsIconInBar ? "" : "Switch it on above, or run: omarchy-shell omarchy.bar settingsIcon true"
    },
    {
      label: "caps:hyper for the toggle hotkey",
      ok: root.capsHyper,
      detail: root.capsHyper ? "input.lua sets kb_options = caps:hyper" : "no caps:hyper in input.lua",
      hint: root.capsHyper ? "" : "Add hl.config({ input = { kb_options = \"caps:hyper\" } }) to ~/.config/hypr/input.lua, then hyprctl reload"
    },
    {
      label: "Volume keys route to the island",
      ok: root.volumeKeyRebound,
      detail: root.volumeKeyRebound ? "XF86AudioRaiseVolume unbound and rebound" : "XF86AudioRaiseVolume still drives omarchy-osd",
      hint: root.volumeKeyRebound ? "" : "hl.unbind(\"XF86AudioRaiseVolume\") before o.bind(...) in ~/.config/hypr/bindings.lua, or the native popup shows too"
    },
    {
      label: "Brightness keys route to the island",
      ok: root.brightnessKeyRebound,
      detail: root.brightnessKeyRebound ? "XF86MonBrightnessUp unbound and rebound" : "XF86MonBrightnessUp still drives omarchy-osd",
      hint: root.brightnessKeyRebound ? "" : "hl.unbind(\"XF86MonBrightnessUp\") before o.bind(...) in ~/.config/hypr/bindings.lua"
    },
    {
      label: "Managed keybind block",
      ok: root.managedBlock,
      detail: root.managedBlock
        ? (root.managedBindCount > 0
            ? root.managedBindCount + " shortcut(s) managed in bindings.lua"
            : "block present, no shortcut set")
        : "not written yet",
      hint: root.managedBlock ? "" : "Apply a shortcut in the HOTKEYS section above to create it"
    },
    {
      label: "Brightness source",
      ok: root.brightnessAvailable,
      detail: root.brightnessAvailable ? "backlight readable" : "no backlight device reported",
      hint: root.brightnessAvailable ? "" : "The brightness slider and overlay stay hidden on this host"
    }
  ]

  spacing: Style.space(8)

  PanelSectionHeader {
    width: parent.width
    text: "DOCTOR"
    foreground: root.foreground
    fontFamily: root.fontFamily
  }

  Text {
    width: parent.width
    wrapMode: Text.WordWrap
    text: "Setup outside the plugin folder. Anything amber fails silently."
    color: root.foreground
    opacity: 0.5
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  Repeater {
    model: root.checks
    delegate: Item {
      required property var modelData
      width: root.width
      implicitHeight: checkContent.implicitHeight

      Row {
        id: checkContent
        width: parent.width
        spacing: Style.space(8)

        Rectangle {
          width: Math.round(Style.space(8))
          height: width
          radius: width / 2
          anchors.top: parent.top
          anchors.topMargin: Style.space(5)
          color: modelData.ok ? Color.accent : root.warnColor
        }

        Column {
          width: parent.width - Style.space(16)
          spacing: Style.space(2)

          Text {
            width: parent.width
            text: modelData.label
            color: root.foreground
            wrapMode: Text.WordWrap
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }
          Text {
            width: parent.width
            text: modelData.detail
            color: root.foreground
            opacity: 0.55
            wrapMode: Text.WordWrap
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
          Text {
            width: parent.width
            visible: text !== "" && modelData.ok !== true
            text: modelData.hint
            color: root.warnColor
            wrapMode: Text.WordWrap
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }
      }
    }
  }
}
