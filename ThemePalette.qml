import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

// Palette reader for the island's theme picker.
//
// ONE instance lives on the island body (`DynamicIsland.qml`), deliberately
// OUTSIDE the body's content `Loader`: the Loader destroys its item on every
// context switch, so a cache owned by the picker view itself would re-warm the
// whole theme inventory on every open. Owning it here means one warm-up at
// plugin load, shared by every open.
//
// The picker reads `palettes` / `currentName` and may call `ensureReady()`; it
// never spawns a process of its own.
QtObject {
  id: root

  // theme name -> { background, red, green, yellow, blue, magenta, cyan,
  //                 foreground, accent } as resolved color strings.
  property var palettes: ({})
  // The name `omarchy-theme-set <name>` wrote last (read-only, watched).
  property string currentName: ""
  // The warm-up produced at least one theme.
  property bool ready: false
  // A warm-up is in flight; never start a second one.
  property bool warming: false

  signal warmed()

  readonly property string home: Quickshell.env("HOME")
  readonly property string themeNamePath:
    root.home + "/.local/state/omarchy/current/theme.name"

  // The spec's canonical dot order, and the key order the warm-up emits.
  readonly property var canonicalKeys:
    ["background", "red", "green", "yellow", "blue", "magenta", "cyan", "foreground"]

  // --- warm-up --------------------------------------------------------------
  // ONE process at load, re-run only when the active theme changes. The script
  // walks both theme roots itself and skips any directory without a
  // `colors.toml`, which is what drops `aether` — an empty directory that could
  // be listed but never applied.
  //
  // The loop is a fixed literal: no caller data is interpolated into it, and
  // each theme's path reaches the resolver as a single argv. `--all` is the
  // uniform readout the 8-dot spec needs: it cascades the keys a theme omits
  // (`white` ships no `orange`/`brown`) instead of returning a ragged set.
  //
  // Wire format, one line per theme: `name<TAB>k=v,k=v,…` for the 9 keys.
  // A theme whose resolver call fails prints no line at all.
  readonly property string warmScript: [
    "resolver=/usr/share/omarchy/bin/omarchy-theme-color",
    "for themeRoot in \"$HOME/.config/omarchy/themes\" /usr/share/omarchy/themes; do",
    "  [ -d \"$themeRoot\" ] || continue",
    "  for themeDir in \"$themeRoot\"/*/; do",
    "    [ -f \"$themeDir/colors.toml\" ] || continue",
    "    themeName=$(basename \"$themeDir\")",
    "    \"$resolver\" --file \"$themeDir/colors.toml\" --all 2>/dev/null | awk -v n=\"$themeName\" 'BEGIN{split(\"background red green yellow blue magenta cyan foreground accent\",ks,\" \");nk=9}{seen[$1]=$2}END{out=\"\";for(i=1;i<=nk;i++){k=ks[i];if(i>1)out=out \",\";out=out k \"=\" seen[k]}printf \"%s\\t%s\\n\",n,out}'",
    "  done",
    "done"
  ].join("\n")

  // Declared as an explicit property, not a bare child: a QtObject root has no
  // default property, so a bare member cannot be assigned to it.
  property Process warmProcess: Process {
    command: ["bash", "-c", root.warmScript]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parseInventory(String(text))
    }
    onRunningChanged: {
      if (running) return
      root.warming = false
      // A theme change during a warm-up must not be lost: the queued run reads
      // post-change state.
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

  // Called by the picker on open: the first open can beat a cold warm-up, and a
  // warm-up that failed must not leave the picker empty forever. The retry is
  // bounded by user opens — `warming` still forbids a second concurrent run.
  function ensureReady() {
    if (!root.ready && !root.warming) root.warm()
  }

  function parseInventory(raw) {
    var next = ({})
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var line = String(lines[i])
      if (line === "") continue
      var tab = line.indexOf("\t")
      if (tab <= 0) continue
      var name = line.substring(0, tab).trim()
      if (name === "") continue
      var pairs = line.substring(tab + 1).split(",")
      var palette = ({})
      var keys = 0
      for (var j = 0; j < pairs.length; j++) {
        var eq = pairs[j].indexOf("=")
        if (eq <= 0) continue
        var value = pairs[j].substring(eq + 1).trim()
        if (value === "") continue
        palette[pairs[j].substring(0, eq).trim()] = value
        keys++
      }
      // A theme with no resolved key is not a palette: dropping it keeps the
      // list honest instead of offering a card that paints nothing.
      if (keys === 0) continue
      next[name] = palette
    }
    root.palettes = next
    root.ready = Object.keys(next).length > 0
    if (root.ready) root.warmed()
  }

  // --- theme.name identity --------------------------------------------------
  // Read-only watch on the file `omarchy-theme-set` writes. `watchChanges` turns
  // the apply into an event instead of a poll, and the identity is what both the
  // selection ring and the optimistic apply reconcile against. The repaint needs
  // no help from here: the shell's own palette push already reloads `Color`.
  // Same reason as `warmProcess`: declared, not a bare child.
  property FileView themeNameWatch: FileView {
    path: root.themeNamePath
    watchChanges: true
    printErrors: false
    // `text()` is stale inside the change signal, so both paths re-read through
    // reload() → onLoaded().
    onFileChanged: reload()
    onLoaded: root.applyCurrentName(String(text()).trim())
    onLoadFailed: root.applyCurrentName("")
  }

  // The first read only primes the identity; warming again for it would double
  // the load-time inventory for no new information.
  property bool _primed: false

  function applyCurrentName(name) {
    var next = String(name || "")
    if (root.currentName === next) return
    root.currentName = next
  }

  onCurrentNameChanged: {
    if (!root._primed) {
      root._primed = true
      return
    }
    // A theme may have been overlaid or installed since the last inventory, so
    // the cached map is re-read. One run per theme change, never per open.
    root.warm()
  }

  // --- reads the picker binds ----------------------------------------------
  function names() {
    var out = Object.keys(root.palettes)
    // Alphabetical, the order `omarchy theme list` prints: stable, so the
    // counter and the strip are predictable between opens.
    out.sort()
    return out
  }

  function paletteFor(theme) {
    var key = String(theme || "")
    if (key === "") return null
    var map = root.palettes
    return (map && map[key]) ? map[key] : null
  }

  // A missing key must still paint a dot: a theme that omits one (or a map that
  // has not warmed yet) falls back to accent, then foreground, then a neutral
  // grey. Nothing this returns is transparent.
  function resolveDot(key, palette) {
    if (!palette) return "#888888"
    return palette[key] || palette.accent || palette.foreground || "#888888"
  }

  // The 8 canonical dots, in spec order, from resolved values.
  function dots(theme) {
    var palette = root.paletteFor(theme)
    var keys = root.canonicalKeys
    var out = []
    for (var i = 0; i < keys.length; i++) out.push(root.resolveDot(keys[i], palette))
    return out
  }

  // The selected card's own accent, i.e. the theme's, not the active one's.
  function accent(theme) {
    var palette = root.paletteFor(theme)
    if (!palette) return Color.accent
    return palette.accent || palette.foreground || "#888888"
  }

  // Title-cased exactly like `omarchy theme list`: capitalise the leading letter
  // and every letter after a dash, then read the dashes as spaces
  // (`one-dark-pro` → `One Dark Pro`, `retro-82` → `Retro 82`).
  function label(theme) {
    return String(theme || "")
      .replace(/(^|-)([a-z])/g, function(match, separator, letter) {
        return separator + letter.toUpperCase()
      })
      .replace(/-/g, " ")
  }
}
