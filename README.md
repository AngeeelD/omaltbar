# Omaltbar

Omaltbar replaces the Omarchy bar with a notch-anchored pill that hosts your existing bar widgets and expands into a paged "island" body. It is a drop-in `bar` replacement: your widgets render unchanged, the stock bar can be restored at any time, and the plugin also registers as a normal bar widget so it can be discovered, enabled, and removed like any other Omarchy plugin.

- Plugin id: `angeeeld.omaltbar`
- Entry points: `bar` → `NotchIslandBar.qml`, `barWidget` → `SettingsWidget.qml`
- Version `1.0.0`, author Ángel Durán, MIT license
- Repository: <https://github.com/AngeeelD/omaltbar> (the repo root is the plugin folder; `manifest.json` is at the root)

## Demo

![Omaltbar — the pill at rest under the notch, then the island expanded](docs/omaltbar.gif)

*The pill at rest, then the island body expanded.* The animation is produced separately for the marketplace submission and is not committed yet.

The marketplace listing uses `preview.png` at the repository root as its preview/social image.

## Install

```bash
omarchy plugin add https://github.com/AngeeelD/omaltbar.git --enable
```

`omarchy` clones the repository into `~/.config/omarchy/plugins` and enables the plugin. Nothing outside that folder is required to load the bar.

## Usage

```bash
# Make Omaltbar the active bar
omarchy bar use angeeeld.omaltbar

# Switch back to the stock Omarchy bar
omarchy bar use omarchy.bar

# Apply bar changes (hot-reload is not reliable for the bar)
omarchy restart shell
```

The bar switch is reversible from the settings panel too. While another bar is active, the plugin stays installed but reports as disabled, and its settings icon only works while the island is the bar.

## Configure

```bash
# Open the settings panel by clicking the gear icon on the bar, or run:
omarchy-shell angeeeld.omaltbar.settings toggle

# Managed Hyprland shortcuts live in bar.islandHotkeys. The panel writes them
# into one marked block in ~/.config/hypr/bindings.lua and reloads Hyprland.
# Edit them through the panel; do not hand-edit that block.
```

The settings panel sections are BAR, APPEARANCE, TIMING, INTERACTION, HOTKEYS, CONTEXTS and DOCTOR. Every value persists through the shell's config API and applies live.

`bar.islandHotkeys` maps an action (`island.toggle`, `island.settings`) to a key combination. `hotkeys.sh` renders the managed block from that object and calls `hyprctl reload`.

`~/.config/omarchy/shell.json` is only written through the shell's `mutateShellConfig` API. The settings panel, the pill gestures, the settings-icon placement and the hotkey writer all use that API, so the shell config keeps a single writer. Do not hand-edit `shell.json` for keys the plugin owns.

## Remove

```bash
# If Omaltbar is the active bar, switch back first
omarchy bar use omarchy.bar

# Remove the plugin
omarchy plugin remove angeeeld.omaltbar
```

`omarchy plugin remove` disables the plugin (when it is enabled) and then removes it. A plugin installed from git is deleted; its upstream repository is unaffected.

Related plugin commands:

```bash
omarchy plugin list
omarchy plugin update angeeeld.omaltbar
omarchy plugin validate <plugin-folder>
```

## Verify the install

```bash
# The plugin is discovered
omarchy plugin list | grep -i omaltbar

# Geometry and state readout, then a journal filter on the new shell PID
omarchy-shell omarchy.bar debugIslandGeometry | jq '{screen, displayScale, pillWidth, pillHeight}'
PID=$(pgrep -f 'quickshell -n -p /usr/share/omarchy/shell' | tail -1)
journalctl --user --since "1 min ago" | grep -F "$PID" | grep -iE "TypeError|ReferenceError|Cannot read|VMEMetaObject" | grep -vE "hideTooltip|VMEMetaObject|WidgetButton.qml|panels/audio/Panel.qml" | tail -n 30
```

`rescanPlugins` reloads views but does not reliably recompile the active bar or refresh the `IpcHandler` function list. Always use `omarchy restart shell` and judge health from the **new** shell PID.

## How it works

1. **Bar replacement** — `NotchIslandBar.qml` implements the same `bar` contract as `Bar.qml` (colors, `run`, `activePopout`, `moduleSlots`) so hosted widgets render unchanged, laid out in a centered pill under the physical notch.
2. **Island pages** — `ContextResolver` decides which pages exist (`island.default` always, plus `omarchy.media`, `omarchy.microphone`, `island.screenrecord`, `jankeesvw.notification-center`, etc.); `IslandState` owns paging and a transient overlay; `DynamicIsland` routes to the registered native view.
3. **Pill zones** — left third → `layout.left` grid, right third → `layout.right` grid, lower-center dwell → resolved page (media leads, default fallback). The pill ITEM always keeps its full width, so the zones survive the visual retraction; the surface only shrinks. It retracts to the dot when the island expands, and rests there permanently when `bar.islandPillCompact` is on (the default).
4. **Native OSD replacement** — the volume/brightness media keys no longer drive `omarchy.osd`. Volume goes to PipeWire through `wpctl`, brightness to `omarchy brightness display --no-osd`, and the island's transients show the change (see *Setup — required vs optional*).
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

## External dependencies

All dependencies are optional. A missing piece degrades to an honest placeholder, never a crash. Each row names the feature that needs it.

| Dependency | Needed for | Behavior if missing |
|------------|------------|---------------------|
| PipeWire (`Quickshell.Services.Pipewire`) | Audio — the volume overlay, mute, microphone detection, and the quick-settings sink picker | Volume and microphone show muted or unavailable; the sink picker is empty |
| MPRIS (`Quickshell.Services.Mpris`) | Media players — the media page, the now-playing peek, and the auto-playback watcher | No media page and no media peek; the media service (`omarchy.media`) is intentionally unused, MPRIS is read directly |
| UPower (`Quickshell.Services.UPower`) | Battery — the pill's battery dial and the quick-settings power block | Battery rings and tiles are hidden |
| inotify watcher on `/sys/class/backlight/<device>/brightness` (`FileView.watchChanges`) | Brightness — turns every external brightness write into an immediate re-read | Falls back to the 15-second `omarchy-monitor-state` poll |
| `omarchy-hw-display` | Brightness — resolves the backlight device name for the sysfs watcher | No sysfs watcher; the 15-second poll is the only source |

Other runtime helpers the views use:

| Helper | Used by | Behavior if missing |
|--------|---------|---------------------|
| `omarchy-monitor-state` | `BrightnessState` safety poll (line 0 = percent for the focused monitor, line 5 = monitor name) | Brightness slider and overlay unavailable |
| `omarchy-brightness-display --no-osd --monitor <name> <p>%` | `BrightnessState.setBrightness` | Writes silently fail; the read that follows the write is not counted as an external change (`_selfSet`) |
| `wpctl set-volume` / `wpctl set-mute` | The `XF86Audio*` keybindings (not this plugin); the island reacts through `Pipewire` | Keys do nothing |
| `omarchy-audio-output-sink` | `QuickSettingsView` (resolves the real default through the DSP filter chain) | Falls back to `Pipewire.defaultAudioSink` |
| `omarchy-audio-output-set-default` | `QuickSettingsView.setDefaultSink` | Sink switch not persisted |
| `omarchy-audio-sink-availability` | `QuickSettingsView` candidate filter | Shows all sinks, including unavailable ones |
| `omarchy-bluetooth-power` / `omarchy-bluetooth-device` | `QuickSettingsView` Bluetooth toggle/connect | Buttons no-op |
| `omarchy-powerprofiles-list` / `omarchy-powerprofiles-set` | `QuickSettingsView` power-profile pills | Hidden or read-only |
| `omarchy-capture-screenrecording --stop-recording` / `/tmp/omarchy-screenrecord-filename` | `ScreenRecordingView`, `ContextResolver` `screenRecording` poll | Screen-record page never appears |
| `pgrep -f "^(gpu-screen-recorder\|wf-recorder)"` (polled every 2s) | `ContextResolver.screenRecording` | Same as above |
| `curl` + `https://api.open-meteo.com` + `~/.local/state/omarchy/settings/weather.json` | `ClockWeatherView` | Shows the `--°C/--°F` placeholder; no fetch |
| `omarchy-notification-send` (tests) / `omarchy.notifications` service (`popupModel`, `liveRefs`, `clearPopups`, `clearHistory`, `doNotDisturb`) | `ContextResolver` toast capture, `NotificationsView`, `NotificationToastView` | Notifications page and toast hidden; DND toggle inert |
| NetworkManager (via `Quickshell.Services`) / BlueZ | `QuickSettingsView` Wi-Fi/Bluetooth lists | Lists empty |
| Hyprland (`Hyprland.focusedMonitor`, `hyprctl`) | `NotchIslandBar` per-screen units, `focusedScreenName`, debug geometry | Falls back to the first unit |

## Privilege boundary

The plugin runs unsandboxed with your own user privileges. It does not use `sudo`, and it writes only the files described below.

- **(a) Shell config** — the plugin writes `~/.config/omarchy/shell.json` only through the shell's `mutateShellConfig` API, never by hand-editing the file. All persisted keys (`bar.island*`, `bar.layout.*.islandHidden` / `islandPinned`, `bar.id`) go through that API, so the shell remains the single writer of the file.
- **(b) Hyprland bindings** — the plugin writes `~/.config/hypr/bindings.lua` only through its own `hotkeys.sh`. The script renders one marked block bounded by `-- >>> angeeeld.omaltbar hotkeys` and `-- <<< angeeeld.omaltbar hotkeys`, keeps the rest of the file verbatim, and then runs `hyprctl reload`. Each managed bind is `hl.unbind`-ed immediately before it is bound, so a hand-written bind on the same key cannot fire twice. The script also refuses any key string that could break out of the Lua string literals.
- **(c) State** — the plugin keeps one piece of state in `~/.local/state/notch-island/`: `notifications-seen.json`, a read marker for the notification history.
- **(d) Notification actions** — a notification's saved `execArgv` is executed only on an explicit user click on that notification's body. The click handler is the only caller: the argv is not run on capture, on a timer, or by any read-only debug command (`debugToastSnapshots` prints the stored argv but never runs it). The argv is validated structurally (`NotificationLogic.parseExecArgv`) and passed to `Util.execArgv`, which runs it as bash positional arguments with no shell re-tokenization. Note that any same-uid process can set the notification hint, which is equivalent to same-uid code execution; the explicit click is the consent.

## Setup — required vs optional

The plugin is a drop-in **bar** replacement: it loads with nothing but `bar.id`, and every hosted widget keeps working. A few things live **outside** the plugin directory, and they are what turn the *whole* desktop experience into "the island does it". Only the first one is required to run the bar; the rest are opt-in, and each one moves one native piece of the desktop into the island.

| | Tweak | Result if you skip it |
|---|-------|----------------------|
| **Required** | `bar.id = "angeeeld.omaltbar"` | The host never loads this plugin — you keep the stock bar |
| Optional | `caps:hyper` + the Super+Caps bind | No hotkey to toggle the island (the pill hover zones still work) |
| Optional | Volume/brightness key rebind | The media keys keep showing the native `omarchy.osd` popup |
| Optional | Weather location | The weather row shows `--°C` |
| — | Notification double-toast | Nothing to do — the island suppresses the top-right copy internally |

### 1. Required — activate the plugin

```bash
# install from git (omarchy clones into ~/.config/omarchy/plugins and enables it)
omarchy plugin add https://github.com/AngeeelD/omaltbar.git --enable

# make it the active bar (writes bar.id via omarchy-shell-config — no hand-edit)
omarchy bar use angeeeld.omaltbar

# apply (hot-reload is not reliable for the bar)
omarchy restart shell
```

The plugin must be discovered as a `bar` option for `omarchy bar use` to accept it; `omarchy plugin list` shows it, and `omarchy plugin validate <folder>` checks the manifest if you cloned by hand.

### 2. Optional — island toggle hotkey (Super+Caps)

Caps must be a Hyper key first, otherwise Caps and the combo are not distinguishable.

`~/.config/hypr/input.lua`:

```lua
hl.config({ input = { kb_options = "caps:hyper" } })
```

`~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + MOD3 + Hyper_L", "Omaltbar", "omarchy-shell omarchy.bar island")
```

Skipping it costs only the keyboard toggle; the pill hover zones are unaffected.

The panel's **HOTKEYS** section can own this instead: it writes `bar.islandHotkeys` and mirrors it into a marked block at the end of `bindings.lua` (with `hl.unbind` first, so a hand-written line for the same key cannot fire twice) and reloads Hyprland. Use one or the other, not both.

### 3. Optional — replace the native OSD for volume and brightness

Without this the volume/brightness keys keep driving `omarchy.osd` (the popup at the bottom-center of the screen): the defaults live in `/usr/share/omarchy/default/hypr/bindings/media.lua` and end by calling `omarchy-osd`. Unbind them first, then route them through the island. Volume goes straight to PipeWire through `wpctl` (which the island already watches, so the change is reactive); brightness keeps omarchy's own device resolution but passes `--no-osd`.

`~/.config/hypr/bindings.lua`:

```lua
hl.unbind("XF86AudioRaiseVolume")
hl.unbind("XF86AudioLowerVolume")
hl.unbind("XF86AudioMute")
hl.unbind("XF86MonBrightnessUp")
hl.unbind("XF86MonBrightnessDown")
hl.unbind("ALT + XF86AudioRaiseVolume")
hl.unbind("ALT + XF86AudioLowerVolume")
hl.unbind("ALT + XF86MonBrightnessUp")
hl.unbind("ALT + XF86MonBrightnessDown")

o.bind("XF86AudioRaiseVolume", "Volume up", "wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+", { locked = true, repeating = true })
o.bind("XF86AudioLowerVolume", "Volume down", "wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-", { locked = true, repeating = true })
o.bind("XF86AudioMute", "Mute", "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle", { locked = true })
o.bind("XF86MonBrightnessUp", "Brightness up", "omarchy brightness display --no-osd +5%", { locked = true, repeating = true })
o.bind("XF86MonBrightnessDown", "Brightness down", "omarchy brightness display --no-osd 5%-", { locked = true, repeating = true })

-- precise (ALT) steps keep the island overlay too
o.bind("ALT + XF86AudioRaiseVolume", "Volume up precise", "wpctl set-volume @DEFAULT_AUDIO_SINK@ 1%+", { locked = true, repeating = true })
o.bind("ALT + XF86AudioLowerVolume", "Volume down precise", "wpctl set-volume @DEFAULT_AUDIO_SINK@ 1%-", { locked = true, repeating = true })
o.bind("ALT + XF86MonBrightnessUp", "Brightness up precise", "omarchy brightness display --no-osd +1%", { locked = true, repeating = true })
o.bind("ALT + XF86MonBrightnessDown", "Brightness down precise", "omarchy brightness display --no-osd 1%-", { locked = true, repeating = true })
```

Apply and verify:

```bash
hyprctl reload && hyprctl configerrors        # must be empty
wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-
omarchy-shell omarchy.bar debugIslandGeometry | jq '{expanded, displayedContext, transientVisible, transientPeek}'
# expected within ~1.3s: expanded=true, displayedContext="omarchy.volume", transientPeek=true, then it collapses by itself
```

Notes:

- The rebind only affects those keys. The rest of `omarchy.osd` still exists for other callers, and a key you did not rebind still shows the stock OSD (e.g. `SHIFT + XF86AudioMute` = switch output).
- `hl.unbind` before `o.bind` is required: without it the default `omarchy-osd` handler stays active alongside the new one.
- On a host whose default sink is a DSP filter-chain (a speaker tuning), `@DEFAULT_AUDIO_SINK@` is that tuning sink — the same sink omarchy's stock volume keys use, so there is no loudness change versus stock.

### 4. Optional — weather location

The default page's weather row uses Open-Meteo and needs a location. Set it through the Omarchy weather settings UI (it writes `~/.local/state/omarchy/settings/weather.json`); without it the row shows `--°C`. The °C/°F toggle is persisted by the island itself (`bar.islandWeatherUnit`) and needs no config.

## Configuration keys

Optional keys, all written through the shell config API. None are required for install; they show the supported surface.

| Key | Scope | Default | Notes |
|-----|-------|---------|-------|
| `bar.islandNotchScale` | `bar` | `1` | Manual multiplier over the calibrated 14" cutout. Calibrated at 1x then divided by `displayScale` automatically. Set via `omarchy-shell omarchy.bar notchScale 1.1` |
| `bar.islandWeatherUnit` | `bar` | `""` (locale) | `""` = locale, `"metric"` / `"imperial"` persisted. Toggled by clicking the weather row in `ClockWeatherView` |
| `bar.islandFirstContexts` | `bar` | `[]` (disabled) | Ids whose native view wins the **icon click** over the widget's own popup. Empty = every icon opens its panel. `omarchy-shell omarchy.bar islandFirst "a,b"` / `""` to clear |
| `bar.islandExcludedControls` | `bar` | `[]` | Deck controls hidden from the default page. Drag a control to the bottom exclusion drop, or call the bar API `setControlHidden` |
| `bar.islandSettingsIcon` | `bar` | `true` | Keep the settings gear on the bar. The island reconciles its layout entry to this flag on every load (the registry cannot place a bar-kind plugin's widget). `omarchy-shell omarchy.bar settingsIcon true\|false` |
| `bar.islandDisabledContexts` | `bar` | `[]` | Context providers turned off — no page, no entry page, no overlay. Panel → CONTEXTS, or `omarchy-shell omarchy.bar contextFlag <id> false` |
| `bar.islandHotkeys` | `bar` | `{}` | Managed Hyprland shortcuts (`island.toggle`, `island.settings`), mirrored into a marked block in `bindings.lua` by `hotkeys.sh`. Panel → HOTKEYS |
| `bar.islandInvertPillClicks` | `bar` | `false` | Swaps the pill's left/right click: template (clock ⇄ dials) ↔ pin the compact dot. Panel → INTERACTION |
| `bar.islandTransientTtlMs` / `islandTransientLeadMs` | `bar` | `1600` / `300` | How long a transient overlay (volume, brightness) lives, and how early its peek starts collapsing. Panel → TIMING |
| `bar.islandToastHoldMs` / `islandToastTtlMs` | `bar` | `6500` / `hold+500` | How long the island stays expanded for a notification. The snapshot TTL is derived to stay ≥ hold+200, so the page outlives the island animation |
| `bar.islandMediaPeekMs` | `bar` | `2600` | How long the compact now-playing strip stays up when playback changes on its own |
| `bar.islandMotionFast` / `islandMotionBase` / `islandMotionSlow` | `bar` | `200` / `340` / `560` | Motion tokens. The pill, the body and the promotion animation read these |
| `bar.islandOpacity` | `bar` | `0.72` | Alpha of BOTH island surfaces (pill + body) while `bar.transparent` is on. Clamped 0.2–1.0. Panel → APPEARANCE, or `omarchy-shell omarchy.bar opacity 0.8` |
| `bar.islandPillCompact` | `bar` | `true` (absent) | Pill resting form. `true` = the compact badge (time, or the status dials), `false` = the wide notch pill (the simulated cutout flanked by the clock wings). Persisted so the right click and the panel agree and survive a restart. Panel → APPEARANCE, or `omarchy-shell omarchy.bar pillCompact false` |
| `bar.islandPillWidth` | `bar` | `0` = auto | Explicit pill length in logical px (clamped 140–900), for panels whose cutout differs from the calibrated 14" one. `0`/absent = the derived geometry (cutout + side slots on a notched panel, the 6.25 aspect elsewhere). Panel → APPEARANCE, or `omarchy-shell omarchy.bar pillWidth 620` |
| `layout[*].islandHidden` | per entry `bar.layout` | `false` | Per-widget exclusion from the island grid. Written via `omarchy-shell shell setBarWidget <id> islandHidden true '{}'` |
| `layout[*].islandPinned` | per entry `bar.layout` | `false` | Leaves the grid, renders as a full-width row at the top of the island. `omarchy-shell shell setBarWidget <id> islandPinned true '{}'` |

Never hand-edit `shell.json` for per-widget flags if the shell IPC is available — the plugin registry is the single writer and hot-reloads through `barConfig`.

## Configure via shell API

```bash
# Island pages — island-first click policy (empty disables it, the default)
omarchy-shell omarchy.bar islandFirst "omarchy.network,omarchy.bluetooth"
omarchy-shell omarchy.bar islandFirst ""

# Notch geometry fine-tune
omarchy-shell omarchy.bar notchScale 1.15
omarchy-shell omarchy.bar notchScale 1

# Toggle island (same as Super+Caps)
omarchy-shell omarchy.bar island

# Debug: mount a specific island context without pointer injection
omarchy-shell omarchy.bar debugOpen island.default      # the deck page
omarchy-shell omarchy.bar debugOpen omarchy.volume      # the volume overlay view
omarchy-shell omarchy.bar debugOpen __island_grid_left  # the left widget grid
omarchy-shell omarchy.bar debugOpen ""                  # back to the resolved page

# Full geometry + state readout (screen, scales, pill/body widths, active contexts)
omarchy-shell omarchy.bar debugIslandGeometry | jq .

# Per-widget grid membership (mirrors the drag gestures)
omarchy-shell shell setBarWidget omarchy.tray islandHidden true '{}'
omarchy-shell shell setBarWidget omarchy.tray islandHidden false '{}'
omarchy-shell shell setBarWidget omarchy.indicators islandPinned true '{}'

# Which bar is active (empty / "default" means the stock bar)
omarchy-shell omarchy.bar useBar angeeeld.omaltbar
omarchy-shell omarchy.bar useBar omarchy.bar

# Settings gear on the bar (also the CONTEXTS/HOTKEYS/TIMING panel sections)
omarchy-shell omarchy.bar settingsIcon true

# Context providers on/off: no page, no entry page, no overlay
omarchy-shell omarchy.bar contextFlag omarchy.microphone false

# Timing + motion overrides (clamped on read; resetTiming clears them all)
omarchy-shell omarchy.bar timing islandTransientTtlMs 2000
omarchy-shell omarchy.bar timing islandMediaPeekMs 3000
omarchy-shell omarchy.bar resetTiming
omarchy-shell omarchy.bar debugTiming

# Managed Hyprland keybinds (empty clears the action; reloads Hyprland)
omarchy-shell omarchy.bar hotkey island.toggle "SUPER + MOD3 + Hyper_L"

# Debug: exercise the peek/promotion state machine without a pointer
omarchy-shell omarchy.bar debugMediaPeek
omarchy-shell omarchy.bar debugPromote

# Surface opacity (pill + body). Inert while transparent is off
omarchy-shell omarchy.bar opacity 0.8

# Pill form: compact badge (default) or the wide notch pill; `toggle` is what
# the right click does, and the choice is persisted either way
omarchy-shell omarchy.bar pillCompact true
omarchy-shell omarchy.bar pillCompact toggle

# Pill length in logical px (140-900) to match a different cutout;
# 0 deletes the override and restores the derived geometry
omarchy-shell omarchy.bar pillWidth 620
omarchy-shell omarchy.bar pillWidth 0

# Debug: what the island is holding for the clickable toast (the default-action
# argv included). Read-only — it never runs the argv, only a real click does
omarchy-shell omarchy.bar debugToastSnapshots | jq .
```

Inspect the raw config:

```bash
cat ~/.config/omarchy/shell.json | jq .bar
cat ~/.config/omarchy/shell.json | jq '.bar.layout.right[] | {id, islandHidden, islandPinned}'
```

## Behavior notes

- **Notification toast capture + top-right suppression** — On `notificationCount` increment, `ContextResolver.captureToast()` snapshots `popupModel.get(0)` into `toastSnapshots` (max 5, each 7s TTL via a 1s prune timer), then `Qt.callLater(() => clearPopups())`. `clearPopups()` archives the toast out of the top-right notification layer, so it never renders there; the island shows the snapshot in `NotificationToastView`. The island auto-expands to `island.notificationToast` for `6500ms` (`notificationToastDuration`), then collapses. The snapshot outlives the island by 500ms so no page-jump occurs. No archive is written — collapse clears in-memory snapshots only. DND suppresses auto-expand (`if (doNotDisturb) return`).
- **Weather unit toggle** — Click the weather row in `ClockWeatherView` toggles `metric` ⇄ `imperial` and persists via `islandBar.setWeatherUnit()` → `bar.islandWeatherUnit` (`mutateShellConfig`). `""` means the locale default. `Weather.shouldUseImperial` / `formatTemp` from the upstream weather `Model.js` are reused verbatim.
- **Empty-area click guard** — `DynamicIsland` has a background `MouseArea` (`z:-1`, `acceptedButtons: All`) that swallows clicks on padding/gaps. Without it, clicks fall through to `islandWindow`'s dismiss handler and collapse the island.
- **Pill retract gated on expanded** — `pillHoverMinimize` is `islandState.expanded` (not pointer proximity). Order is hover → reveal → retract. Right-click pins to the dot (`pillCompact`), left-click swaps the template (clock ⇄ `PillStatusDial` dials). Digits yield (`pillTimeYields`) only after the body is showing.
- **Transient overlays (the island is the OSD)** — Volume (`omarchy.volume`) and brightness (`island.brightness`) are transients: they replace `displayedContext` while live without becoming pages, and they show over **whatever** the island is displaying — a page, a widget grid or a manual view — hiding the grids while they are up so the two never overlap. A key-driven change peeks the island open for the TTL (`transientTtlMs` 1600ms, collapsing 300ms early so the page underneath never flashes) when it was resting, without taking keyboard focus. If the user already opened the island the overlay borrows the view and hands it back, and a repeated key press extends the peek instead of stranding the island open. The peek stands down while a plugin panel owns the screen (`pluginWindowOpen`), while the displayed view already hosts the control (`transientSuspended` — `QuickSettingsView` owns both sliders, so the deck updates live and no overlay is needed), and briefly after the user dismisses the island (`hoverSuppressed`) or interacts with it; in all of those the overlay still appears if the island is already open. Mute raises the same volume overlay through its own edge. Suspension is **owned and released** by a per-instance token (`suspendTransient` / `releaseTransient`): a plain `Binding { value: true }` latched it at `true` after the view was destroyed and silently killed every key-driven OSD once the deck had been seen.
- **Focus policy (automatic opens never take the keyboard)** — the island body surface is `WlrKeyboardFocus.None` unless the pointer is over the island's **body card** *and* the island was not opened automatically. Automatic opens (transient peek, notification toast, media auto-context) set `IslandState.autoOpened`, so they map with no keyboard focus at all: a notification, a volume/brightness key or a fresh playback can never pull the keyboard out of whatever the user is typing into. Focus is granted only while the pointer is on the body card — not on the pill/notch, and no longer `OnDemand` merely because the window is visible, which is what let a pointer parked on the top strip hand the island the keyboard. Once an automatic open is collapsed, the next explicit open restores normal behaviour.
- **Drag & drop** — `DragHandler` threshold preserves plain clicks; the bottom drop bar splits at screen center (left half = move section, right half = exclude); the insertion marker is computed from the nearest cell. `bar.islandExcludedControls` and `layout.*.islandHidden` share the same `PluginRegistry` single-writer path.

## Troubleshooting

**Display scale looks wrong / pill doubles at 2x**
The island is notch-anchored: geometry is calibrated at 1x (`notchCutoutWidth 370`, `notchSideSlot 88`) then multiplied by `invScale = 1/displayScale` and by `notchScale`. `displayScale` comes from `hostScreen.devicePixelRatio`. At 2x the logical cutout halves, so the physical pill matches 1x. If the bar still looks 30% too large, check `Style.bar.sizeHorizontal` / `Style.font.body` — they also scale with display/font scale. See `IslandUnit.invScale`, `notchCutoutWidth`, `notchSideSlot`.

```bash
omarchy-shell omarchy.bar debugIslandGeometry | jq '{displayScale, notchScale, pillWidth, pillHeight, notchCutoutWidth, notchSideSlot, expandedWidth}'
```

**Island not expanding / journal noise**
Filter by the **new** shell PID only — old PID lines are stale:

```bash
PID=$(pgrep -f 'quickshell -n -p /usr/share/omarchy/shell' | tail -1); echo $PID
journalctl --user --since "2 min ago" | grep -F "$PID" | tail -n 80
```

**Media keys still show the native OSD**
The `XF86Audio*` / `XF86MonBrightness*` defaults live in `default/hypr/bindings/media.lua` and end by calling `omarchy-osd`. The user `bindings.lua` must `hl.unbind` each key before rebinding it, otherwise the OSD handler stays active alongside the new one. Verify the OSD is gone and the island reacts:

```bash
hyprctl configerrors                                  # must be empty after the edit
wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-
omarchy-shell omarchy.bar debugIslandGeometry | jq '{expanded, displayedContext, transientVisible, transientPeek}'
# expected within ~1.3s: expanded=true, displayedContext="omarchy.volume", transientPeek=true
```

Known benign teardown noise (not this plugin): a burst of `QQmlVMEMetaObject: Internal error - attempted to evaluate a function in an invalid context`, `@Ui/WidgetButton.qml ... hideTooltip is not a function` and `panels/audio/Panel.qml ... Cannot read property 'foreground' of null` whenever the island's view `Loader` swaps or tears down. They are `WARN`-level only and the health check above filters them out.

**Hot-reload didn't apply**
Expected. `rescanPlugins` + `Qt.clearComponentCache` can serve a stale bar. Always:

```bash
omarchy restart shell
```

Then verify with `debugIslandGeometry` (new PID). `qmllint` is at `/usr/lib/qt6/bin/qmllint`:

```bash
/usr/lib/qt6/bin/qmllint ~/.config/omarchy/plugins/angeeeld.omaltbar/NotchIslandBar.qml
/usr/lib/qt6/bin/qmllint ~/.config/omarchy/plugins/angeeeld.omaltbar/DynamicIsland.qml
```

**Bar completely hidden (pill at y=-64)**
`~/.local/state/omarchy/toggles/bar-off` exists. Remove it, or toggle via `omarchy-toggle-bar`, or call:

```bash
omarchy-shell omarchy.bar syncHidden
rm -f ~/.local/state/omarchy/toggles/bar-off
omarchy restart shell
```

Note: `chaz.bar-autohide` recreates this file via its daemon — disabling that plugin is the durable fix.

**Apple Silicon vs flat display**
`appleSiliconHost` probes `grep -qi apple /proc/device-tree/compatible`. Only for `eDP` + `notchStrip > 0` does `notchedHost` use cutout geometry; flat/attached monitors fall back to the `pillHeight * 6.25` aspect derivation. `notchStrip` prefers `Style.bar.notchHeight` (from `shell.toml` calibration) before the `BarModel.notchHeight(...)` 16:10 derivation.

**Weather shows `--°C`**
No location set or the fetch failed (5s timeout). Set the location via the Omarchy weather settings UI (writes `~/.local/state/omarchy/settings/weather.json`), then `refreshWeather` fires on `FileView.onLoaded`.

## Development history

### Round 7 — native OSD replacement + cleanup (done)

The pre-publish round before the first release.

| Item | What changed |
|------|--------------|
| **OSD rebind** — volume/mute → `wpctl`, brightness → `omarchy brightness display --no-osd` in `~/.config/hypr/bindings.lua` (defaults unbound first) | No native OSD; the island's `omarchy.volume` / `island.brightness` transients replace it and peek open for 1.6s when the island is at rest |
| **Transient peek** — `ContextResolver.transientSeq` edge drives `IslandUnit.handleTransientRequest` | Auto-open without keyboard focus, respecting `hoverSuppressed`, `pluginWindowOpen` and `transientSuspended` |
| **Brightness poll** — `omarchy-monitor-state` 5s → 15s, plus an inotify `FileView` on the backlight sysfs attribute | Key-driven brightness is detected immediately and the expensive poll runs a third as often |
| **Vestigial proximity** — `timeNear` / `nearRect` / `updateTimeProximity` and the clock hit rects removed | No dead code; the reveal is driven only by `pillZoneAt` / `handlePillZone` |
| **OSD reliability** — `transientSuspended` is now an owned/released token set, and the overlay shows over any context (grids, manual views), not only while paging | A view mounting the sliders used to leave suspension latched at `true` after it was destroyed: once the deck had been seen, every volume/brightness key was suppressed with no OSD at all. It now releases in `Component.onDestruction`, and the overlay behaves like a real OSD. `omarchy-shell omarchy.bar debugOpen <context>` was added to exercise the path without pointer injection |
| **Focus policy** — `IslandState.autoOpened` plus `WlrKeyboardFocus.None` in every non-engaged state | Automatic opens (peek, toast, playback) and a pointer parked on the pill no longer take keyboard focus; `Exclusive` is granted only while the pointer is on the body card of an explicitly opened island |

### Round 8 — first-class plugin: icon, settings panel, managed hotkeys (done)

The round that made the plugin behave like any other Omarchy plugin *besides* being the bar.

| Item | What changed |
|------|--------------|
| **Settings widget** — `kinds: ["bar","bar-widget"]` plus `entryPoints.barWidget` (`SettingsWidget.qml`) | `omarchy plugin list` shows it as a widget and `omarchy plugin add <url> --enable` still activates it as the bar. The icon is a miniature bar plate with the gear on top (`BarIconButton.iconComponent`), and it opens a `qs.Ui.Panel` + `KeyboardPanel` popup exactly like the audio/bluetooth panels |
| **A bar-kind plugin cannot place its own widget** | `PluginRegistry.setEnabled()` writes `bar.id` and returns before the placement block, so `omarchy bar put angeeeld.omaltbar` reports success without adding anything. The island places its own entry through `mutateShellConfig`, governed by `bar.islandSettingsIcon` |
| **The entry is a custom-qml entry** — `{id, source: ".../SettingsWidget.qml"}` | A `bar`-kind plugin is "enabled" only while it is the selected bar, so its registry component disappears on the stock bar and the icon would be a dead placeholder. A `source:` entry loads the file directly, so the gear keeps working in **both** bars — which is what makes the bar switch reversible from the UI |
| **Bar switch with confirmation** | `bar.id` is the only thing written. The stock direction asks first, names what it means (the plugin reports `disabled` while another bar is active — the same way `omarchy.bar` reads `disabled` right now) and shows `omarchy bar use angeeeld.omaltbar` with a copy button |
| **Settings panel** — `SettingsPanel.qml`: BAR · APPEARANCE · TIMING · INTERACTION · HOTKEYS · CONTEXTS · DOCTOR | Everything persists through `shell.mutateShellConfig` and applies live. There is no generic Omarchy settings form (`barWidget.settingsForm` is dead metadata with no consumer), so the rows are hand-rolled from the `qs.Ui` kit |
| **Timing + motion** — `islandTransientTtlMs`, `islandTransientLeadMs`, `islandToastHoldMs`, `islandToastTtlMs`, `islandMediaPeekMs`, `islandMotionFast/Base/Slow` | Clamped on read, so a bad value self-corrects; the toast TTL is derived to stay ahead of the toast hold. The panel's slider leaves the mouse wheel alone (upstream `PanelSlider` commits on every notch, so scrolling the panel edited values instead of scrolling) |
| **Managed hotkeys** — `bar.islandHotkeys` + `hotkeys.sh` | Hyprland has no persistent runtime keybind API, so the script rewrites one marked block in `~/.config/hypr/bindings.lua` and reloads. `hl.unbind` runs before every `o.bind`, so a hand-written line for the same key cannot fire twice |
| **Context feature flags** — `bar.islandDisabledContexts` | A disabled provider never becomes a page, an entry page or an overlay; the code that detects it is untouched. Turning the toast off also skips the popup capture, so the stock notification stays put instead of being swallowed |
| **Compact media peek** — `views/MediaPeekView.qml` | Playback changes (play, pause, a new track, an ad) peek a one-row now-playing strip instead of opening the full page. Reaching for it promotes it to the real player + pager |
| **Pager only when the user opened it** | `autoOpened` gates `pagerStrip`, `pagerBar` and the swipe handler: an automatic appearance is an announcement, not an offer to navigate |
| **Pointer-approach promotion** — `IslandUnit.promoteAutomaticAppearance()` | Cancels the peek timer, hands the island to the user, returns the pager, and for the media peek drops the strip so the full player shows. Width and height animate only for that transition |
| **Doctor** — `SettingsDoctor.qml` | Seven read-only checks for the setup outside the plugin folder (bar selection, icon placement, `caps:hyper`, both media-key rebinds, the managed block, the backlight). Static by design: it reads the Hyprland files rather than `hyprctl binds`, whose plain output does not report the dispatched command on 0.56.x |
| **Ordering fixes** (two silent failures worth knowing) | 1. `openResolved()` wrote `paging`/`pageId` **before** `expanded`, so the remembered page — the deck — mounted first and claimed its transient-suspension token, latching the overlay OFF. It now expands first when a transient is live. 2. A play *burst* (playing, then title/artist/art settling) re-raised the compact strip over the expanded player; a trailing event is now dropped when the page underneath is the player |
| **Debug surfaces** | `omarchy.bar debugMediaPeek`, `debugPromote`, `debugLastPage <id>`, `debugTiming`, `debugSettingsWidget`, `debugOpen`. This host cannot inject hover or clicks, and these make the hover-dependent transitions testable |

### Round 9 — clickable notifications, configurable surfaces (done)

The round that made the island's toasts actionable and its two surfaces (and pill form) user-configurable.

| Item | What changed |
|------|--------------|
| **Clickable notification toasts** — clicking the body of an island toast runs the notification's default action | The cascade is the shell's own (`Service.qml` `invokePopupDefault`), in this order: the persisted `execArgv` → a live `"default"` libnotify action → focus the sending app by class. `ContextResolver.captureToast()` now stores `execArgv` in the snapshot, which is the ONLY path that survives: `clearPopups()` kills the live ref (`Service.qml:165-168` deletes `liveRefs[originalId]`), and Omarchy's own toasts (screenshots, installer prompts) carry their action there precisely because the persistence files preserve it |
| **The same cascade in the history list** — `views/NotificationsView.qml` | Live rows and archived rows both carry `execArgv` now (the archive DOES keep it — `NotificationLogic.historyEntry`). A tap runs the action; a live row is then dismissed exactly like the stock popup, while an archived row stays as a history record until the ✕ or Clear all |
| **A stored argv only ever runs from an explicit click** | `parseExecArgv` is a structural check, not a trust decision: any same-uid process can set the hint (equivalent to same-uid code execution). The click is the consent, which is why the new `debugToastSnapshots` readout prints the argv but never runs it |
| **Surface opacity** — `bar.islandOpacity` (0.2–1.0, default 0.72) drives BOTH surfaces | One value feeds `DynamicIsland`'s body and `SimulatedNotch`'s pill (both used to hardcode 0.72). `bar.transparent` stays the master switch: off = both paint opaque and the slider is inert (and disabled in the panel). Panel → APPEARANCE, with a slider that leaves the wheel alone |
| **Pill form preference** — `bar.islandPillCompact`, absent = compact | `false` keeps the wide notch pill (the simulated cutout flanked by the clock wings); `true` rests the pill as the compact badge. The right click still toggles it *and persists it* — one writer, so the gesture and the panel cannot disagree, and the choice now survives a shell restart (the old pin was session state). Compact is the default because most installs have no cutout |
| **Pill length** — `bar.islandPillWidth` (140–900 px, `0`/absent = auto) | Direct override of the derived length, so a panel whose cutout differs from the calibrated 14" one can be matched without guessing a `notchScale`. The icon-row floor still applies, and the slider starts where the pill actually is (the bar reports the derived width), so the first drag is relative to what you see |
| **The pill's mini-player is gone** — `NotchIslandBar.qml` | The right wing used to carry a play/pause glyph plus `title \|\| artist`, packed against the minutes; it was width-gated, so at the calibrated length the title was elided to nothing and only the glyph showed. Widening the pill gave the title room and it read as clutter, so the whole indicator was removed: the pill shows the clock (or the dials) and nothing else. What is playing still reaches the user through the media peek (on a playback change), the widget grid and the media page. `mediaHovered`, its setter and the `revealNear` term that fed off it went with it — a lone glyph was never worth rendering (the code's own note called it "a stray arrow next to the minutes") |
| **The pill length no longer stretches the body** — `IslandUnit.pillWidthDerived` | `bar.islandPillWidth` is a PILL knob, so the body's width floor now reads the DERIVED length (cutout + side slots / the 6.25 aspect) instead of the overridden one. Before this, a 900 px pill dragged the island body to 900 px with it, because the floor was `pill + one icon`. Verified: the body stays 584 px at 546, 620 and 900 |
| **Teardown bug found by the first real click** | Dropping the last toast snapshot ends the toast context, and the island collapsing can unload the view SYNCHRONOUSLY — so the `rebuild()` call that used to follow the snapshot write ran on a destroyed object (`TypeError: Property 'rebuild' ... is not a function`, column `-1` = invalidated wrapper). The snapshot write is now the last statement of `dismissToast()`, the redundant post-mutation rebuilds are gone (the resolver signal and the model `Connections` already rebuild, and `rebuild()` no-ops when the signature is unchanged), and `NotificationsView.dismissLive()` got the same treatment. A `Component.onDestruction` flag would NOT work: after invalidation every property read returns `undefined` |
| **Two ordering traps worth knowing** | 1. `IslandUnit.applyPillForm()` reads `barConfig` DIRECTLY instead of the derived `pillCompactMode` binding: inside the pass that delivers a config change the binding can still return the previous value (the same trap as #1669/#1671), which made `pillCompact false` persist to `shell.json` while the pill stayed compact. 2. `visible: modelData.actions && ...` on a snapshot entry (which has no `actions` at all) assigned `undefined` to a bool — wrapped in `!!` |
| **Debug surfaces** | `debugToastSnapshots` (the held toasts + their argv), and `debugIslandGeometry` gained `pillWidthOverride`, `pillCompact`, `pillCompactMode`, `pillMinimized` and `pillCollapse`, so both directions of the form/length work can be verified from a shell |

## Roadmap

| Item | Scope | Status |
|------|-------|--------|
| **Multi-monitor** — verify `Quickshell.screens` Variants, per-screen `debugIslandGeometry`, layers `notch-island` + `notch-island-body` per monitor (Mac HDMI not validated yet) | `NotchIslandBar` `IslandUnit`, `DynamicIsland` | PENDING |
| **Per-view redesigns** — bespoke layout per context view (not the plugin-box grid) | each `views/*` | PENDING |
| Sink switch live test with headphones/HDMI (only DSP + unavailable jack on the development host) | `QuickSettingsView` OUTPUT block | PENDING — needs hardware |
| External (DDC) display brightness: the sysfs watcher covers the internal panel only; an external monitor's change is seen by the 15s safety poll | `BrightnessState` | KNOWN LIMITATION |
| Pointer-only checks — hover promotion (compact strip → player + pager), the settings dialog's Escape/Enter, dragging the timing sliders, and the doctor's amber path (break something on purpose) | `SettingsWidget`, `SettingsPanel`, `SettingsDoctor` | PENDING — needs a real pointer; `omarchy-shell omarchy.bar debugMediaPeek` / `debugPromote` / `debugLastPage <id>` exercise the state machine without one |
| Pointer-only checks for the APPEARANCE sliders (opacity, pill length) and the pill-form toggle in the panel. The toast CLICK is already verified (a real click ran a test toast's `--exec`) | `SettingsPanel`, `NotchIslandBar` | PENDING — needs a real pointer for the drags; the form and the length are verifiable from a shell (`debugIslandGeometry`, `pillCompact` / `pillWidth`) |
| Dial nudge debug knobs — `wifiDialNudgeY` / `batteryDialNudgeY` (`IslandUnit`) and `PillStatusDial.nudgeY` tune the battery glyph centring; both sit at `0` now | `NotchIslandBar`, `PillStatusDial` | CLEANUP — remove when the centring is settled |

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

---

The config surface lives in `~/.config/omarchy/shell.json` under `bar` and `bar.layout`; every mutable key has a shell IPC path, so `shell.json` is never hand-edited. Activation is `omarchy bar use angeeeld.omaltbar`, and the optional keys above are set through the shell API. Hot-reload is not trusted for bar changes — `omarchy restart shell` is the supported apply step.
