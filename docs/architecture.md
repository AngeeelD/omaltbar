# Architecture

## How it works

1. **Bar replacement** — `NotchIslandBar.qml` implements the same `bar` contract as `Bar.qml` (colors, `run`, `activePopout`, `moduleSlots`) so hosted widgets render unchanged, laid out in a centered pill under the physical notch.
2. **Island pages** — `ContextResolver` decides which pages exist (`island.default` always, plus `omarchy.media`, `omarchy.microphone`, `island.screenrecord`, `jankeesvw.notification-center`, etc.); `IslandState` owns paging and a transient overlay; `DynamicIsland` routes to the registered native view.
3. **Pill zones** — left third → `layout.left` grid, right third → `layout.right` grid, lower-center dwell → resolved page (media leads, default fallback). The pill ITEM always keeps its full width, so the zones survive the visual retraction; the surface only shrinks. It retracts to the dot when the island expands, and rests there permanently when `bar.islandPillCompact` is on (the default).
4. **Native OSD replacement** — the volume/brightness media keys no longer drive `omarchy.osd`. Volume goes to PipeWire through `wpctl`, brightness to `omarchy brightness display --no-osd`, and the island's transients show the change (see [Setup](setup.md)).
5. **First-class plugin** — besides being the bar, the plugin is a normal Omarchy bar widget: a gear icon (`SettingsWidget.qml`) whose click opens a settings panel with the bar switch, timing, interaction, managed hotkeys, context flags and a doctor.

## Island surfaces

| Surface | Context id | View | What it does |
|---------|------------|------|--------------|
| Default page (deck) | `island.default` | `views/DefaultContextView.qml` (`ClockWeatherView` + `QuickSettingsView`) | Large clock, date, weather row with the °C/°F toggle, and the controls deck |
| Media | `omarchy.media` | `views/MusicView.qml` | MPRIS transport (play/pause/seek, 1s position while playing) |
| Now-playing peek | `island.mediaPeek` | `views/MediaPeekView.qml` | Slim one-row now-playing strip raised by a playback change |
| Microphone | `omarchy.microphone` | `views/MicrophoneView.qml` | Mic capture indicator and mute toggle |
| Screen recording | `island.screenrecord` | `views/ScreenRecordingView.qml` | Recording file view and stop button |
| Notifications | `jankeesvw.notification-center` | `views/NotificationsView.qml` | History list, DND, dismiss/clear, clickable row bodies |
| Notification toast | `island.notificationToast` | `views/NotificationToastView.qml` | The captured toast snapshot, with a clickable body |
| Volume overlay | `omarchy.volume` | `views/VolumeView.qml` | Transient volume overlay reading `Pipewire.defaultAudioSink` |
| Brightness overlay | `island.brightness` | `views/BrightnessView.qml` | Transient brightness overlay reading `BrightnessState` |
| Left/right grid | `__island_grid_left` / `__island_grid_right` | `IslandWidgets.qml` | The hosted `layout.left` / `layout.right` widget grids |

## File map

| File | One line |
|------|----------|
| `manifest.json` | Plugin identity (`angeeeld.omaltbar`, `kinds: ["bar","bar-widget"]`, entries `bar` → `NotchIslandBar.qml` and `barWidget` → `SettingsWidget.qml`, `barWidget.defaultSection: right`) |
| `SettingsWidget.qml` | The plugin's bar-widget: the gear icon (`iconComponent` = bar plate + gear) and its `qs.Ui.Panel` popup. Works in either bar; owns the bar-switch confirmation overlay |
| `SettingsPanel.qml` | The panel content: BAR, APPEARANCE, TIMING, INTERACTION, HOTKEYS, CONTEXTS, DOCTOR. Reads `bar.barConfig`, writes `bar.shell.mutateShellConfig` — the only config surfaces both bars expose |
| `SettingsDoctor.qml` | Read-only setup diagnostics (bar selection, icon placement, `caps:hyper`, media-key rebinds, managed block, backlight). Static: reads the Hyprland files |
| `hotkeys.sh` | Renders the marked `angeeeld.omaltbar hotkeys` block in `~/.config/hypr/bindings.lua` from `bar.islandHotkeys` and runs `hyprctl reload` |
| `NotchIslandBar.qml` | Bar root, `bar` contract, motion tokens, the clamped `bar.island*` keys, `IslandUnit` (per-screen geometry, pill zones, drag state, transient peek, `IpcHandler` `island`/`notchScale`/`islandFirst`/`opacity`/`pillCompact`/`pillWidth`/`debugIslandGeometry`/`debugToastSnapshots`) |
| `DynamicIsland.qml` | Island body router (painting `surfaceOpacity` from `bar.islandOpacity`), native view registration, pager, drag overlay/drop bar, fallback view |
| `IslandState.qml` | Expand/collapse, `pageIds`/`pageId`/`entryId`/`paging`/`manualContext`, `autoOpened` (automatic opens never take focus), `transientContext`/`transientVisible`/`transientSuspended` (owned token set), `bodyShowsClock`, `revealSide`/`soloWidgetId` |
| `ContextResolver.qml` | Page order + TTL, `transientSeq` (one peek per request), toast snapshot store (7s, each carrying the `execArgv` click action), providers: media/mic/notifications/nightlight/idle/volume+mute/brightness/screenRecording |
| `IslandWidgets.qml` | Hosted grid (left/right `Flow`), `DragHandler`, ghost loader, delegates for each `layout` entry |
| `MediaState.qml` | Shared MPRIS state (`hasMedia`, `canSeek`, `position` timer) for `MusicView`, the media peek and the auto-playback watcher |
| `BrightnessState.qml` | Backlight sysfs watcher (inotify `FileView`) + 15s `omarchy-monitor-state` safety poll, `setBrightness` via `omarchy-brightness-display --no-osd`, `externallyChanged` signal |
| `PillStatusSource.qml` | Live Wi-Fi + UPower source for the pill's status dials |
| `PillStatusDial.qml` | Ring dial widget (Wi-Fi / battery) used by the pill's alternate template |
| `SimulatedNotch.qml` | Visual notch shape + collapse driver for the pill surface, painting `surfaceOpacity` (`bar.islandOpacity`) while transparent |
| `views/ClockWeatherView.qml` | Large clock + date + Open-Meteo weather row with the °C/°F toggle (`islandWeatherUnit`) |
| `views/DefaultContextView.qml` | Composed default page (`ClockWeatherView` + controls deck) |
| `views/QuickSettingsView.qml` | Combined deck: audio slider/mute + DSP-aware sink picker + Wi-Fi/Bluetooth/power + brightness/nightlight/idle/DND/mic — the default page's controls |
| `views/MusicView.qml` | MPRIS transport (play/pause/seek, 1s `positionChanged` while playing) — page `omarchy.media` |
| `views/MediaPeekView.qml` | The slim now-playing row (art · title/artist · play state, no transport) — transient `island.mediaPeek`, the compact form of a playback change |
| `views/MicrophoneView.qml` | Mic capture indicator + mute toggle — page `omarchy.microphone` |
| `views/ScreenRecordingView.qml` | Recording file view + stop button — page `island.screenrecord` |
| `views/BrightnessView.qml` | Transient brightness overlay reading `BrightnessState` — overlay `island.brightness` |
| `views/VolumeView.qml` | Transient volume overlay reading `Pipewire.defaultAudioSink` — overlay `omarchy.volume` |
| `views/NotificationsView.qml` | History list + DND + dismiss/clear + clickable row bodies (default action) — page `jankeesvw.notification-center` |
| `views/NotificationToastView.qml` | Snapshot toast (`toastSnapshots`, per-notification, no `popupModel`) with a clickable body running the default action — page `island.notificationToast` |

## Component reference

[`docs/component-reference.md`](component-reference.md) — the island's 21 IPC commands with arguments, effect and stable/debug marking, the `IslandState` modes and transitions, and the context resolution precedence.

## Views reference

[`docs/views.md`](views.md) — the island's 11 native views with line counts, rendered content, mounting context ids and key interactions, with prose for the three heaviest (`QuickSettingsView`, `NotificationsView`, `NotificationToastView`).

[← Back to the README](../README.md)
