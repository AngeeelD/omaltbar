import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire

// Context resolver: the single place that decides which contexts are alive and
// in what order the island pages through them.
//
// Order contract (round 4, extended by round 6):
//   * "big" contexts come first, most attention-worthy first, so entering from
//     the bottom lands on the most relevant page;
//   * the default page (clock/weather + the generic controls deck) is always
//     last as the stable base;
//   * transients (volume, brightness) are ephemeral overlays that are NOT
//     pages; they never become a page, but a key-driven change peeks the island
//     open for their TTL so they replace the native OSD (see transientSeq).
//
// Round 6 providers, each backed by an existing live source:
//   * screen recording  -> polled pgrep (no reactive source);
//   * media             -> shared MPRIS MediaState (round 4);
//   * microphone in use -> Pipewire streams on the default source;
//   * notifications     -> the shell's omarchy.notifications service.
//
// Notifications is a page but deliberately NOT a focus context: a toast must
// never hijack the page the bottom entry lands on. `entryContextId` owns that
// distinction, and IslandState.openResolved() reads it.
//
// One instance lives on the bar root and is shared by every island unit.
Item {
  id: root

  // Pure logic holder: never paints.
  visible: false

  // Injected by the bar root.
  property var mediaState: null
  // Shell accessor, for firstPartyServiceFor(...). Null in bare tests.
  property var shell: null
  // Shared brightness state (BrightnessState.qml), for the brightness overlay.
  property var brightnessState: null

  // The always-present fallback page. It is a composed island surface
  // (clock/weather + the generic controls deck), distinct from the bare
  // "omarchy.clock" widget view.
  readonly property string defaultContextId: "island.default"

  // Context ids owned by the new providers. The media id is the widget id, so
  // a click on that icon routes to the same view.
  readonly property string mediaContextId: "omarchy.media"
  readonly property string microphoneContextId: "omarchy.microphone"
  readonly property string notificationsContextId: "jankeesvw.notification-center"
  readonly property string notificationToastContextId: "island.notificationToast"
  readonly property string screenRecordContextId: "island.screenrecord"

  // --- media -----------------------------------------------------------------
  // Whether a now-playing context should own a page. `hasMedia` is true as
  // soon as a player exposes a track (playing or paused), so the controls
  // stay reachable while paused.
  readonly property bool mediaActive: !!(mediaState && mediaState.hasMedia)

  // --- microphone in use -----------------------------------------------------
  // Mirrors bar/widgets/Microphone.qml: the default source is capturing when
  // there is at least one live capture stream that is not muted, and the source
  // itself is not muted.
  readonly property var microphoneSource: Pipewire.defaultAudioSource
  readonly property bool microphoneMuted:
    microphoneSource && microphoneSource.audio ? microphoneSource.audio.muted === true : true

  // Omarchy's own filter-chains publish internal capture streams
  // (`audio_effect.*`, `effect_output.*`) that carry no application identity:
  // they are the DSP, not an app recording. Counting them lit the microphone
  // page up whenever a mic tuning existed, with nothing actually capturing.
  function isInternalAudioNode(node) {
    var name = String(node && node.name ? node.name : "")
    return name.indexOf("audio_effect.") === 0
      || name.indexOf("effect_output.") === 0
      || name.indexOf("omarchy_") === 0
      || name === "quickshell"
  }

  // Live capture streams owned by a real application, unmuted.
  readonly property var activeMicrophoneStreams: {
    var list = []
    if (!root.microphoneSource || !root.microphoneSource.audio) return list
    var nodes = Pipewire.nodes ? Pipewire.nodes.values : []
    for (var i = 0; i < nodes.length; i++) {
      var node = nodes[i]
      if (!node || !node.isStream || node.isSink !== false) continue
      if (node.audio && node.audio.muted === true) continue
      if (root.isInternalAudioNode(node)) continue
      list.push(node)
    }
    return list
  }
  readonly property bool microphoneInUse:
    !root.microphoneMuted && root.activeMicrophoneStreams.length > 0

  // --- notifications ---------------------------------------------------------
  readonly property var notificationService:
    root.firstPartyService("omarchy.notifications")
  readonly property var notificationPopups:
    root.notificationService ? root.notificationService.popupModel : null
  readonly property int notificationCount:
    root.notificationPopups ? Number(root.notificationPopups.count || 0) : 0
  // Keep the notifications page alive briefly after the last toast disappears
  // so the island's auto-expand animation doesn't lose its page mid-flight.
  property bool _notificationsHold: false
  Timer {
    id: notificationHoldTimer
    interval: 9000
    repeat: false
    onTriggered: root._notificationsHold = false
  }
  // --- toast snapshot store (per-notification 10s window, island only) -------
  property var toastSnapshots: []
  // Snapshot lifetime. Default 7000; the bar overrides it from
  // bar.islandToastTtlMs, clamped there. Keep it 500ms LONGER than the island's
  // toast-hold so the page outlives the island animation and no page-jump shows.
  property int notificationToastDuration: 7000
  Timer {
    id: toastPruneTimer
    interval: 1000
    repeat: true
    running: root.toastSnapshots.length > 0
    onTriggered: root.pruneExpired()
  }
  function pruneExpired() {
    var now = Date.now()
    var dur = root.notificationToastDuration
    var filtered = []
    for (var i = 0; i < root.toastSnapshots.length; i++) {
      var s = root.toastSnapshots[i]
      if (now - Number(s.timestamp || 0) < dur) filtered.push(s)
    }
    if (filtered.length !== root.toastSnapshots.length) root.toastSnapshots = filtered
  }
  function captureToast() {
    // With the toast flag off the island must not steal the popup: captureToast
    // is what archives the notification out of the top-right layer, so skipping
    // it here is what leaves the stock popup in place instead of swallowing the
    // notification with nothing to show it.
    if (!root.contextEnabled(root.notificationToastContextId)) return
    var svc = root.notificationService
    var model = svc ? svc.popupModel : null
    if (!model || model.count <= 0) return
    var row = model.get(0)
    if (!row || Number(row.originalId) < 0) return
    var ts = Number(row.timestamp || 0) || Date.now()
    var snap = {
      key: String(ts) + "-" + String(row.originalId || 0),
      originalId: Number(row.originalId || 0),
      timestamp: ts,
      app: String(row.app || ""),
      appIcon: String(row.appIcon || ""),
      summary: String(row.summary || ""),
      body: String(row.body || ""),
      image: String(row.image || ""),
      glyph: String(row.glyph || ""),
      urgency: Number(row.urgency || 0),
      // The click action Omarchy's own toasts carry as an argv vector. The
      // capture below archives the notification out of the popup model (and
      // clearPopups kills its live ref), so this is the ONLY action path that
      // survives into the island toast and into the history files — see
      // Service.qml invokePopupDefault and the round-9 note in
      // NotificationToastView.
      execArgv: String(row.execArgv || "")
    }
    var next = [snap].concat(root.toastSnapshots)
    if (next.length > 5) next = next.slice(0, 5)
    root.toastSnapshots = next
    Qt.callLater(function() {
      var svc2 = root.notificationService
      if (svc2 && typeof svc2.clearPopups === "function") svc2.clearPopups()
    })
  }
  property int _prevNotificationCount: 0
  onNotificationCountChanged: {
    var prev = root._prevNotificationCount
    root._prevNotificationCount = root.notificationCount
    if (root.notificationCount > 0) {
      root._notificationsHold = true
      notificationHoldTimer.stop()
    } else {
      // Count dropped to zero: keep the page alive only if we were
      // previously showing notifications (hold was true via count>0).
      // At cold start count is 0 and hold is false -> don't arm the hold.
      if (root._notificationsHold) {
        notificationHoldTimer.restart()
      }
    }
    if (root.notificationCount > prev) {
      root.captureToast()
    }
  }
  readonly property bool notificationsActive: root.notificationCount > 0 || root._notificationsHold
  // Toast is driven by per-notification snapshots, not the hold timer, so the
  // island collapses immediately when the last snapshot expires - no empty frame.
  readonly property bool notificationToastActive: root.toastSnapshots.length > 0
  readonly property bool doNotDisturb:
    root.notificationService ? root.notificationService.doNotDisturb === true : false

  function toggleDoNotDisturb() {
    if (root.notificationService)
      root.notificationService.setDoNotDisturb(!root.doNotDisturb)
  }

  // --- night light / idle ----------------------------------------------------
  readonly property var nightlightService: root.firstPartyService("omarchy.nightlight")
  readonly property bool nightlightEnabled:
    root.nightlightService ? root.nightlightService.enabled === true : false
  readonly property var idleService: root.firstPartyService("omarchy.idle")
  readonly property bool stayAwake:
    root.idleService ? root.idleService.stayAwake === true : false

  function toggleNightlight() {
    if (root.nightlightService) root.nightlightService.setNightlight(!root.nightlightEnabled)
  }

  function toggleStayAwake() {
    if (root.idleService) root.idleService.setIdleEnabled(!root.stayAwake)
  }

  function firstPartyService(name) {
    var host = root.shell
    if (!host || typeof host.firstPartyServiceFor !== "function") return null
    return host.firstPartyServiceFor(String(name || ""))
  }

  // --- screen recording ------------------------------------------------------
  // No reactive source exists, so this polls the same anchored pgrep the
  // ScreenRecording indicator uses. `/tmp/omarchy-screenrecord-filename` (read
  // by the view) only says which file is being written.
  property bool screenRecording: false

  Timer {
    interval: 2000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!recordProc.running) recordProc.running = true
  }

  Process {
    id: recordProc
    command: ["pgrep", "--quiet", "-f", "^(gpu-screen-recorder|wf-recorder)"]
    onExited: function(exitCode) { root.screenRecording = exitCode === 0 }
  }

  // --- page order ------------------------------------------------------------
  // --- context feature flags (round 8c) --------------------------------------
  // Ids the user turned off. A disabled context never becomes a page, never
  // becomes the entry page and never raises its overlay, so a provider they do
  // not want (the microphone page, the screen-record page, a key OSD, the media
  // peek) simply does not exist — the detection code is untouched, only its
  // output is filtered. The list lives in shell.json as `bar.islandDisabledContexts`.
  property var disabledContexts: []
  function contextEnabled(contextId) {
    var id = String(contextId || "")
    if (!id) return false
    if (!Array.isArray(root.disabledContexts)) return true
    return root.disabledContexts.indexOf(id) === -1
  }

  // Active big-context ids, highest priority first. Recording outranks media so
  // the entry surface shows the live recording when both are up; notifications
  // is last and never claims focus (see entryContextId).
  readonly property var activeBigIds: {
    var ids = []
    if (root.screenRecording && root.contextEnabled(root.screenRecordContextId)) ids.push(root.screenRecordContextId)
    if (root.mediaActive && root.contextEnabled(root.mediaContextId)) ids.push(root.mediaContextId)
    if (root.microphoneInUse && root.contextEnabled(root.microphoneContextId)) ids.push(root.microphoneContextId)
    if (root.notificationToastActive && root.contextEnabled(root.notificationToastContextId)) ids.push(root.notificationToastContextId)
    if (root.notificationsActive && root.contextEnabled(root.notificationsContextId)) ids.push(root.notificationsContextId)
    return ids
  }

  // Contexts allowed to own the initial page on bottom entry. Notifications is
  // excluded on purpose: a toast must not reorder where the island opens.
  readonly property var focusIds: {
    var ids = []
    if (root.screenRecording && root.contextEnabled(root.screenRecordContextId)) ids.push(root.screenRecordContextId)
    if (root.mediaActive && root.contextEnabled(root.mediaContextId)) ids.push(root.mediaContextId)
    if (root.microphoneInUse && root.contextEnabled(root.microphoneContextId)) ids.push(root.microphoneContextId)
    return ids
  }

  readonly property string entryContextId:
    root.focusIds.length > 0 ? root.focusIds[0] : root.defaultContextId

  // The page the user last chose, remembered so reopening the island lands on
  // it while that context is still alive, instead of always the highest-priority
  // page. Session scoped: a shell restart starts from the resolved entry again.
  // IslandState writes it on every user-visible page change and reads it in
  // openResolved().
  property string lastPageId: ""

  // Page order: active big contexts first, the default page last.
  readonly property var pageIds: activeBigIds.concat([defaultContextId])

  // --- transient overlay (volume, brightness) --------------------------------
  // Raised by a real change, lives for the TTL, then clears. The overlay is
  // only painted while the island is open and paged (IslandState.transientVisible),
  // so a transient alone never takes focus; the island unit watches
  // transientSeq to peek itself open for one TTL, exactly like a native OSD.
  // Overlay TTL. Default 1600; the bar overrides it from bar.islandTransientTtlMs
  // (clamped there), and the island unit's peek collapses a lead time early.
  property int transientTtlMs: 1600
  property string transientId: ""
  // Monotonic per-request counter: one unit peek per request. An id that
  // repeats while its overlay is still live (volume up twice) still bumps the
  // counter, so every key press is seen instead of only the first.
  property int transientSeq: 0

  readonly property var sink: Pipewire.defaultAudioSink
  readonly property real volume: (root.sink && root.sink.audio) ? root.sink.audio.volume : -1
  readonly property bool muted:
    (root.sink && root.sink.audio) ? root.sink.audio.muted === true : false

  // Skip the first reading (the initial binding) and ignore no-op changes; only
  // a real volume move raises the overlay.
  property real _lastVolume: -1
  property bool _volumeReady: false

  onVolumeChanged: {
    var v = root.volume
    if (v < 0) return
    if (!root._volumeReady) {
      root._volumeReady = true
      root._lastVolume = v
      // Prime mute at the same instant: `muted` defaults to false and only
      // emits when it changes, so its own first edge is a real one (a mute
      // key press), not an initial read. Without this it would be swallowed.
      root._lastMuted = root.muted
      root._mutedReady = true
      return
    }
    if (Math.abs(v - root._lastVolume) < 0.001) return
    root._lastVolume = v
    root.showTransient("omarchy.volume")
  }

  // Mute is not a volume move, so it needs its own edge: the mute key toggles
  // WirePlumber mute and the island shows the same volume overlay, which reads
  // the muted flag. First reading primes; no-op edges are ignored.
  property bool _lastMuted: false
  property bool _mutedReady: false

  onMutedChanged: {
    if (!root._mutedReady) {
      root._mutedReady = true
      root._lastMuted = root.muted
      return
    }
    if (root.muted === root._lastMuted) return
    root._lastMuted = root.muted
    root.showTransient("omarchy.volume")
  }

  // Brightness has no reactive source: BrightnessState polls and tells us when
  // a change did not come from the deck slider.
  Connections {
    target: root.brightnessState
    function onExternallyChanged() { root.showTransient("island.brightness") }
  }

  function showTransient(contextId) {
    var id = String(contextId || "")
    if (!id) return
    // A disabled overlay is not raised at all: no peek, no card, no TTL.
    if (!root.contextEnabled(id)) return
    root.transientId = id
    root.transientSeq = root.transientSeq + 1
    transientTimer.restart()
  }

  // Drop the live transient immediately (the TTL timer would do it later). Used
  // when the user reaches for the island while an automatic appearance is up and
  // the announcement has a full-page counterpart — the compact media strip, for
  // instance, gives way to the real player instead of sitting on top of it.
  function clearTransient() {
    transientTimer.stop()
    root.transientId = ""
  }

  // --- compact media peek ----------------------------------------------------
  // Playback changes on its own constantly (play, pause, a new track, an ad
  // swapping the metadata). Opening the full media page for each of those
  // hijacks the screen, so the island peeks a slim now-playing strip instead —
  // the same mechanism as the volume/brightness OSD — and the full MusicView
  // stays what the user gets when they reach for the pill and ask for the
  // media context.
  readonly property string mediaPeekContextId: "island.mediaPeek"
  // Longer than the OSD TTL: a track title needs a beat to read. Overridden
  // from bar.islandMediaPeekMs.
  property int mediaPeekTtlMs: 2600
  readonly property int activeTransientTtlMs:
    root.transientId === root.mediaPeekContextId ? root.mediaPeekTtlMs : root.transientTtlMs

  // Playback that was already running at login must not peek: the same 2.5s
  // grace the island used for its old full media auto-open.
  property bool _mediaPeekReady: false
  Timer {
    interval: 2500
    running: true
    onTriggered: root._mediaPeekReady = true
  }

  // One comparable key for "what is playing and is it running". It changes on a
  // new track, on play/pause, and when an ad swaps the metadata; it does NOT
  // change on the once-a-second position updates.
  readonly property string mediaKey: {
    if (!root.mediaActive) return ""
    var state = root.mediaState
    if (!state) return ""
    return [String(state.title || ""), String(state.artist || ""),
            String(state.album || ""), String(state.identity || ""),
            state.playing === true ? "1" : "0"].join("\u0001")
  }
  property string _lastMediaKey: ""

  onMediaKeyChanged: {
    var key = root.mediaKey
    if (key === root._lastMediaKey) return
    root._lastMediaKey = key
    if (!root._mediaPeekReady) return
    if (key === "") return // playback ended: nothing to announce
    root.showTransient(root.mediaPeekContextId)
  }

  Timer {
    id: transientTimer
    interval: root.activeTransientTtlMs
    repeat: false
    onTriggered: root.transientId = ""
  }
}
