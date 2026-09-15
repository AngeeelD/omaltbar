import QtQuick
import Quickshell.Io

// Shared brightness state for the island.
//
// The display brightness has no reactive property in this shell, so this
// poller reads `omarchy-monitor-state` (the same readout panels/monitor uses)
// and writes back through `omarchy-brightness-display --no-osd`. One instance
// lives on the bar root; the default page's deck slider and the ephemeral
// brightness overlay both read it, so they can never disagree.
//
// The readout is event-driven where it can be: the kernel emits inotify events
// for the backlight sysfs attribute, so a FileView on it turns every external
// brightness write (the media keys, the monitor panel) into an immediate
// re-read instead of waiting for the next tick. The 15s poll is only a safety
// net for readouts with no sysfs attribute (an external DDC monitor) and for
// the focused-monitor name.
//
// A change observed by a re-read that we did NOT make (the monitor panel, a
// native Fn key, another client) raises `externallyChanged`, which the resolver
// turns into the transient overlay — the same contract a volume move has.
Item {
  id: root

  // Pure state holder: never paints.
  visible: false

  // Brightness of the focused monitor, 0..100, and whether the panel exposes
  // a controllable backlight at all.
  property int percent: 0
  property bool available: false
  property string focusedMonitor: ""

  signal externallyChanged()

  // First real reading is the baseline, never an "external change".
  property bool _primed: false
  // Set while a write of our own is in flight, so the next read is consumed as
  // our own value instead of being reported as an external change.
  property bool _selfSet: false
  property int _pending: 0
  property bool _queued: false

  // --- backlight sysfs watcher ---------------------------------------------
  // The kernel backlight attribute, resolved through the same helper the write
  // path uses (Apple panel / gmux / intel / acpi). Empty on a host with no
  // local backlight (a DDC-only setup), where the safety poll is the source.
  property string backlightDevice: ""

  Process {
    id: deviceProc
    command: ["omarchy-hw-display"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.backlightDevice = String(text).trim()
    }
  }
  Timer {
    interval: 60000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!deviceProc.running) deviceProc.running = true
  }

  // inotify delivers MODIFY/CLOSE_WRITE for the sysfs attribute on every write
  // (verified on apple-panel-bl), so this is an immediate trigger, not a poll.
  // It only asks for a re-read: the process stays the single value source, so
  // the focused-monitor readout can never disagree with itself.
  FileView {
    id: backlightWatch
    path: root.backlightDevice !== ""
      ? "/sys/class/backlight/" + root.backlightDevice + "/brightness"
      : ""
    watchChanges: true
    printErrors: false
    // Ignore our own write's events; the set process consumes those on exit.
    onFileChanged: if (!setProc.running && !stateProc.running) stateProc.running = true
  }

  // Safety net: catches a changed focused monitor and any readout with no sysfs
  // attribute. The media keys no longer wait for it (see backlightWatch).
  Timer {
    interval: 15000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!stateProc.running) stateProc.running = true
  }

  Process {
    id: stateProc
    command: ["omarchy-monitor-state"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyState(text)
    }
  }

  // Line 0 is the brightness percent (or the literal "unavailable"); line 5 is
  // the focused monitor name (see omarchy-monitor-state). Header/scale lines in
  // between are irrelevant here.
  function applyState(raw) {
    // Never fight an in-flight write: `omarchy-brightness-display` races the
    // driver and can report the pre-write value. The monitor panel skips the
    // re-read for the same reason.
    if (setProc.running) return
    var lines = String(raw || "").split("\n")
    var rawValue = String(lines[0] || "").trim()
    root.focusedMonitor = String(lines[5] || "").trim()
    root.available = rawValue !== "" && rawValue !== "unavailable"
    if (!root.available) return
    var next = Math.max(0, Math.min(100, parseInt(rawValue, 10) || 0))
    if (root._selfSet) {
      root._selfSet = false
      root._primed = true
      root.percent = next
      return
    }
    var changed = root._primed && Math.abs(next - root.percent) >= 1
    root.percent = next
    root._primed = true
    if (changed) root.externallyChanged()
  }

  function setBrightness(value) {
    if (!root.available) return
    var next = Math.max(0, Math.min(100, Math.round(Number(value) || 0)))
    root._selfSet = true
    root.percent = next
    root._pending = next
    if (setProc.running) {
      root._queued = true
      return
    }
    root._queued = false
    setProc.command = ["omarchy-brightness-display", "--no-osd", "--monitor",
      root.focusedMonitor, next + "%"]
    setProc.running = true
  }

  function adjust(delta) {
    root.setBrightness(root.percent + Number(delta || 0))
  }

  Process {
    id: setProc
    stdout: StdioCollector { waitForEnd: true }
    onRunningChanged: {
      if (running) return
      if (root._queued) {
        root.setBrightness(root._pending)
        return
      }
      // Our write is done but its result has not been read yet. Read now so the
      // self-set value is consumed immediately; otherwise the safety poll would
      // be the first reader and an external change landing in between would be
      // swallowed as if it were ours.
      if (root._selfSet && !stateProc.running) stateProc.running = true
    }
  }
}
