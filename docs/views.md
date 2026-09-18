# Views Reference

Topic-scoped reference for the island's native views: every file under `views/`
(12 files, 4,539 lines) with what it renders, the context id that mounts it, and
how a reader interacts with it. Everything here is derived statically from the
QML source, and each row carries a `File.qml:line` citation so it can be
re-checked with `grep -n`.

For the IPC surface, the `IslandState` machine and the context-resolution
precedence, read [Component Reference](component-reference.md) — this document
does not restate them. For the shape of the bar and which context each view
occupies, read [Architecture](architecture.md).

Mounting is declared once, in the `Component.onCompleted` block at
`DynamicIsland.qml:581-603`: 15 registrations across 12 views. The table below is
ordered the way that block registers them. The mapping reads both ways — a view
lists every context id that mounts it, and a context id names its view.

| View | Lines | Renders | Mounting context | Key interactions |
|------|-------|---------|------------------|------------------|
| `views/ClockWeatherView.qml` | 186 | Large clock, full date, and a live Open-Meteo weather row with the `°C`/`°F` toggle when a location is configured | `omarchy.clock` (`DynamicIsland.qml:575`) | Read-only; the unit toggle persists through the bar's shell config API |
| `views/DefaultContextView.qml` | 36 | The composed default page: `ClockWeatherView` above the `QuickSettingsView` deck, separated by a hairline | `island.default` (`DynamicIsland.qml:576`) | None of its own; it forwards to the two composed views |
| `views/MusicView.qml` | 283 | MPRIS now-playing card (art, title/artist, transport, scrubber) reading the shared `MediaState` | `omarchy.media` (`DynamicIsland.qml:577`) | Play/pause and seek drag while playing; position ticks once a second |
| `views/MediaPeekView.qml` | 91 | One slim now-playing row (art · title/artist · play state), no transport | `island.mediaPeek` (`DynamicIsland.qml:578`) | Read-only by design: it appears over content the user is already watching |
| `views/QuickSettingsView.qml` | 1904 | Combined controls deck: audio, brightness, night light / stay awake / mic / DND, Wi-Fi, Bluetooth, power profiles, battery | `omarchy.audio`, `omarchy.network`, `omarchy.bluetooth`, `omarchy.power` (`DynamicIsland.qml:579-582`) | Slider and mute, device lists with connect/disconnect, passphrase prompt, control-exclusion drag |
| `views/VolumeView.qml` | 55 | Transient output-volume overlay: glyph, percent, level bar | `omarchy.volume` (`DynamicIsland.qml:583`) | Read-only; it replaces a page for a beat and leaves |
| `views/BrightnessView.qml` | 54 | Transient brightness overlay reading the shared `BrightnessState` | `island.brightness` (`DynamicIsland.qml:584`) | Read-only; it never polls or writes by itself |
| `views/MicrophoneView.qml` | 165 | Mic recording state: mute, level, and the apps currently capturing | `omarchy.microphone` (`DynamicIsland.qml:585`) | Mute/unmute toggle |
| `views/ScreenRecordingView.qml` | 90 | The recording's target filename and a stop action | `island.screenrecord` (`DynamicIsland.qml:586`) | Stop button |
| `views/NotificationsView.qml` | 878 | Live popup rows plus the archived history list, per-app icons, relative times and the DND toggle | `jankeesvw.notification-center` (`DynamicIsland.qml:587`) | Row tap runs the default action, live action buttons, dismiss/delete, clear all, DND |
| `views/NotificationToastView.qml` | 531 | Toast snapshot cards only — no history, no archive mixing | `island.notificationToast` (`DynamicIsland.qml:588`) | Card-body tap runs the default action, live action buttons, dismiss |
| `views/WindowListView.qml` | 342 | One card per window of the app chosen on the spheres: live `ScreencopyView` preview or the "Preview unavailable" fallback, plus the app icon, window title, workspace, and a floating 1..N number badge; the card run is centered while it fits the island | `island.windowList` (`DynamicIsland.qml:602`) | Card tap, Left/Right arrow or a digit focuses that window at once through the one shared `WindowSource.focusToplevel` — the command is detached and its ~0.2 s unmap delay runs inside that process — and then collapses the island (`views/WindowListView.qml:88-92`) |

This is the **12th** view on `main` at `e0b6257` (11 existing files). It is the
13th only if the retained `feat/island-theme-switcher` branch, which adds
`views/ThemeSwitcherView.qml` as the 12th, lands first.

The three heaviest views carry the detail the table cannot: what they render
beyond the headline, and how a reader interacts with them.

### QuickSettingsView (1,904 lines)

One combined deck, registered for four context ids, so clicking any of the four
quick-settings island icons opens the same view (`views/QuickSettingsView.qml:20-26`).
It is deliberately one panel rather than four near-identical popups: each of
those bar icons carries only a single toggle plus a short readout.

What it renders, block by block:

- **Audio** (`:141-284`) — an output volume slider with mute, and a sink picker
  built from a panel-local snapshot of PipeWire nodes. Where the default output
  is a DSP filter-chain, the volume slider is resolved through it to the
  physical sink the volume keys drive, so the slider and the speakers agree
  (`:141-150`). A tuning that is fronted by a physical sink but reported
  unavailable stays out of the switch list (`:161-168`).
- **Brightness** (`:285-295`) — delegated to the shared `BrightnessState`, so the
  deck slider and the brightness overlay read one value.
- **Night light / stay awake / microphone / DND** (`:296-329`) — a row of state
  toggles, each writing through the shell's own surface.
- **Wi-Fi** (`:330-560`) — a toggle plus the network list, wired to the exact
  calls the first-party network panel makes: connect, credentials prompts,
  enterprise identities, disconnect.
- **Bluetooth** (`:561-714`) — a toggle plus the device list, wired to the exact
  calls the first-party Bluetooth panel makes, including power and per-device
  connect/disconnect.
- **Power** (`:715-1154`) — power-profile pills and the battery block, hidden or
  read-only when the backend is missing.
- **Excluded controls** (`:1336-` end) — the default page's deck controls can be
  dragged out and restored from the collapsible "Excluded (N)" header, reusing
  the widget grid's exact drag vocabulary (`:47-57`).

Key interactions: dragging the volume slider; toggling mute, Wi-Fi, Bluetooth,
night light, stay awake, microphone and DND; picking a sink, a network or a
device row; answering a passphrase prompt; and dragging a control out of the
deck. Every value comes from the live Quickshell services the first-party panels
read, and a block whose backend is missing renders an honest read-only state
instead of inventing data (`:28-30`). The drag affordance is a non-interactive
surface, so a plain click still reaches an inner control and the slider drag and
list scroll are never stolen (`:114-119`).

### NotificationsView (878 lines)

The history and control surface for the notification bar widget, registered for
`jankeesvw.notification-center` (`views/NotificationsView.qml:13-14`).

What it renders: two stores that the shell's own notifications service already
maintains (`:16-30`). The live rows come from `service.popupModel` — the
notifications currently on screen, each backed by a live notification object so
its declared per-app actions can be listed and invoked. The archived rows come
from the history directory under `~/.local/state/omarchy/notifications/history/`,
read exactly like the service's own replay and deleted one file at a time. Each
row carries a resolved per-app icon, a glyph fallback and a relative time
(`:444-478`). With no live service and an empty archive the view renders an
explicit empty state rather than inventing rows.

Key interactions: a row tap runs the notification's default action, and archived
rows still carry the default `execArgv` even though their declared live actions
died with the sender, so a tap on an archived row can still fire it (`:346-392`).
Action buttons appear only for live rows (`:787`). Rows can be dismissed or
deleted (`:393-429`), everything can be cleared at once, the DND toggle flips the
service's own flag (`:306-310`, `:557`), and the read marker is written to the
state file on view (`:259-304`). Nothing is fabricated: the view never creates a
second notification server, because a second one would lose the D-Bus name to
the running shell (`:16-21`).

### NotificationToastView (531 lines)

The bespoke card shown for the auto-toast — the transient that rides in when a
notification arrives (`views/NotificationToastView.qml:13-27`).

What it renders: only the snapshots captured for the island by the resolver, with
no history files and no archive mixing (`:14-17`). It falls back to the live
popup model only when the resolver is unavailable, which is the bare-test path.
The card shows the captured body with its actions, resolved icon and relative
time, and the view shows nothing when there is nothing to show, so the island
collapses immediately instead of leaving an empty frame (`:26-27`). It does not
own its own lifetime; the display duration is a resolver/bar setting, applied
with per-notification pruning (`:23-25`). The snapshot is kept while the shell's
top-right popup is cleared, so the island and the stock popup do not double up.

Key interactions: tapping the card body runs the notification's default action —
the saved `execArgv`, then a live "default" action, then focusing the sending
app (`:19-21`, `:188-243`). The argv is validated with the shell's own
`parseExecArgv` before it runs, so a malformed or hostile argv is rejected
exactly as the notification service would reject it (`:8-11`). Live cards can
also show their action buttons (`:487`), and a card can be dismissed without
waiting out its duration (`:244-277`, `:523`).

[← Back to the README](../README.md)
