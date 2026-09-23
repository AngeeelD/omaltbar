import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

// Palette reader for the island's background picker.
//
// ONE instance lives on the island body (`DynamicIsland.qml`), deliberately
// OUTSIDE the body's content `Loader`: the Loader destroys its item on every
// context switch, so a cache owned by the picker view itself would re-warm the
// whole background inventory on every open. Owning it here means one warm-up at
// plugin load, shared by every open.
//

QtObject {
  id: root

  property var backgrounds: []
  property string currentPath: ""
  property bool ready: false
  property bool warming: false

  signal warmed()

  readonly property string home: Quickshell.env("HOME")
  readonly property string backgroundLinkPath:
    root.home + "/.local/state/omarchy/current/background"
  readonly property string currentThemePath:
    root.home + "/.local/state/omarchy/current/theme.name"

  readonly property string currentTheme: {
    return root._themeName
  }
  property string _themeName: ""

  // --- warm-up --------------------------------------------------------------
  readonly property string warmScript: [
    "theme=$(cat \"$HOME/.local/state/omarchy/current/theme.name\" 2>/dev/null | xargs)",
    "if [ -z \"$theme\" ]; then exit 0; fi",
    "for root in \"$HOME/.config/omarchy/backgrounds/$theme\" \"$HOME/.local/state/omarchy/current/theme/backgrounds\" /usr/share/omarchy/themes/\"$theme\"/backgrounds; do",
    "  [ -d \"$root\" ] || continue",
    "  find -L \"$root\" -maxdepth 1 -type f \\( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.gif' -o -iname '*.bmp' -o -iname '*.webp' \\) -print 2>/dev/null",
    "done | while IFS= read -r f; do realpath -m \"$f\" 2>/dev/null || echo \"$f\"; done | sort -u"
  ].join("\n")

  property Process warmProcess: Process {
    command: ["bash", "-c", root.warmScript]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parseInventory(String(text))
    }
    onRunningChanged: {
      if (running) return
      root.warming = false
      if (root._queued) root.warm()
    }
  }

  property bool _queued: false

  function warm() {
    if (root.warming) {
      root._queued = true
      return
    }
    root._queued = false
    root.warming = true
    warmProcess.running = true
  }

  function ensureReady() {
    if (!root.ready && !root.warming) root.warm()
  }

  function parseInventory(raw) {
    var lines = String(raw || "").split("\n")
    var seen = {}
    var out = []
    for (var i = 0; i < lines.length; i++) {
      var line = String(lines[i]).trim()
      if (line === "") continue
      // Deduplicate by canonical real path and by basename to handle the same
      // image appearing in both the user and system theme background dirs, or
      // via a symlink vs real path.
      var base = line.substring(line.lastIndexOf("/") + 1).toLowerCase()
      if (seen[base] === true) continue
      // Also dedupe by full path (handles exact duplicates from sort -u)
      if (seen[line] === true) continue
      seen[base] = true
      seen[line] = true
      out.push(line)
    }
    root.backgrounds = out
    root.ready = true
    if (root.ready) root.warmed()
  }

  // --- current background watch ---------------------------------------------
  property FileView backgroundWatch: FileView {
    path: root.backgroundLinkPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.applyCurrentPath(String(text()).trim())
    onLoadFailed: root.applyCurrentPath("")
  }

  property FileView themeWatch: FileView {
    path: root.currentThemePath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var t = String(text()).trim()
      if (root._themeName !== t) {
        root._themeName = t
        root.warm()
      }
    }
  }

  property bool _primed: false

  function applyCurrentPath(path) {
    var next = String(path || "")
    if (root.currentPath === next) return
    root.currentPath = next
  }

  onCurrentPathChanged: {
    if (!root._primed) {
      root._primed = true
      return
    }
  }

  // --- reads the picker binds -----------------------------------------------
  function names() {
    return root.backgrounds.slice()
  }

  function label(path) {
    var p = String(path || "")
    var slash = p.lastIndexOf("/")
    var name = slash >= 0 ? p.substring(slash + 1) : p
    var dot = name.lastIndexOf(".")
    if (dot > 0) name = name.substring(0, dot)
    return name.replace(/(^|[-_])([a-z])/g, function(m, s, l) {
      return s + l.toUpperCase()
    }).replace(/[-_]/g, " ")
  }

  function isCurrent(path) {
    return String(path || "") === root.currentPath
  }
}
