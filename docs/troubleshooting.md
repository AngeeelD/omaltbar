# Troubleshooting

## Behavior notes

- **Notification toast capture + top-right suppression** — On `notificationCount` increment, `ContextResolver.captureToast()` snapshots `popupModel.get(0)` into `toastSnapshots` (max 5, each 7s TTL via a 1s prune timer), then `Qt.callLater(() => clearPopups())`. `clearPopups()` archives the toast out of the top-right notification layer, so it never renders there; the island shows the snapshot in `NotificationToastView`. The island auto-expands to `island.notificationToast` for `6500ms` (`notificationToastDuration`), then collapses. The snapshot outlives the island by 500ms so no page-jump occurs. No archive is written — collapse clears in-memory snapshots only. DND suppresses auto-expand (`if (doNotDisturb) return`).
- **Weather unit toggle** — Click the weather row in `ClockWeatherView` toggles `metric` ⇄ `imperial` and persists via `islandBar.setWeatherUnit()` → `bar.islandWeatherUnit` (`mutateShellConfig`). `""` means the locale default. `Weather.shouldUseImperial` / `formatTemp` from the upstream weather `Model.js` are reused verbatim.
- **Empty-area click guard** — `DynamicIsland` has a background `MouseArea` (`z:-1`, `acceptedButtons: All`) that swallows clicks on padding/gaps. Without it, clicks fall through to `islandWindow`'s dismiss handler and collapse the island.
- **Pill retract gated on expanded** — `pillHoverMinimize` is `islandState.expanded` (not pointer proximity). Order is hover → reveal → retract. Right-click pins to the dot (`pillCompact`), left-click swaps the template (clock ⇄ `PillStatusDial` dials). Digits yield (`pillTimeYields`) only after the body is showing.
- **Transient overlays (the island is the OSD)** — Volume (`omarchy.volume`) and brightness (`island.brightness`) are transients: they replace `displayedContext` while live without becoming pages, and they show over **whatever** the island is displaying — a page, a widget grid or a manual view — hiding the grids while they are up so the two never overlap. A key-driven change peeks the island open for the TTL (`transientTtlMs` 1600ms, collapsing 300ms early so the page underneath never flashes) when it was resting, without taking keyboard focus. If the user already opened the island the overlay borrows the view and hands it back, and a repeated key press extends the peek instead of stranding the island open. The peek stands down while a plugin panel owns the screen (`pluginWindowOpen`), while the displayed view already hosts the control (`transientSuspended` — `QuickSettingsView` owns both sliders, so the deck updates live and no overlay is needed), and briefly after the user dismisses the island (`hoverSuppressed`) or interacts with it; in all of those the overlay still appears if the island is already open. Mute raises the same volume overlay through its own edge. Suspension is **owned and released** by a per-instance token (`suspendTransient` / `releaseTransient`): a plain `Binding { value: true }` latched it at `true` after the view was destroyed and silently killed every key-driven OSD once the deck had been seen.
- **Focus policy (automatic opens never take the keyboard)** — the island body surface is `WlrKeyboardFocus.None` unless the pointer is over the island's **body card** *and* the island was not opened automatically. Automatic opens (transient peek, notification toast, media auto-context) set `IslandState.autoOpened`, so they map with no keyboard focus at all: a notification, a volume/brightness key or a fresh playback can never pull the keyboard out of whatever the user is typing into. Focus is granted only while the pointer is on the body card — not on the pill/notch, and no longer `OnDemand` merely because the window is visible, which is what let a pointer parked on the top strip hand the island the keyboard. Once an automatic open is collapsed, the next explicit open restores normal behaviour.
- **Drag & drop** — `DragHandler` threshold preserves plain clicks; the bottom drop bar splits at screen center (left half = move section, right half = exclude); the insertion marker is computed from the nearest cell. `bar.islandExcludedControls` and `layout.*.islandHidden` share the same `PluginRegistry` single-writer path.

## Common failures

**Display scale looks wrong / pill doubles at 2x**
The island is notch-anchored: geometry is calibrated at 1x (`notchCutoutWidth 370`, `notchSideSlot 88`) then multiplied by `invScale = 1/displayScale` and by `notchScale`. `displayScale` comes from `hostScreen.devicePixelRatio`. At 2x the logical cutout halves, so the physical pill matches 1x. If the bar still looks 30% too large, check `Style.bar.sizeHorizontal` / `Style.font.body` — they also scale with display/font scale. See `IslandUnit.invScale`, `notchCutoutWidth`, `notchSideSlot`.

```bash
omarchy-shell omarchy.bar debugIslandGeometry | jq '{displayScale, notchScale, pillWidth, pillHeight, notchCutoutWidth, notchSideSlot, expandedWidth}'
```

**Island not expanding / journal noise**
Filter by the **new** shell PID only — old PID lines are stale:

```bash
PID=$(pgrep -x quickshell | head -n 1); echo "$PID"
journalctl --user _PID="$PID" --since "2 min ago" | tail -n 80
```

**Media keys still show the native OSD**
The `XF86Audio*` / `XF86MonBrightness*` defaults live in `default/hypr/bindings/media.lua` and end by calling `omarchy-osd`. The user `bindings.lua` must `hl.unbind` each key before rebinding it, otherwise the OSD handler stays active alongside the new one. Verify the OSD is gone and the island reacts:

```bash
hyprctl configerrors                                  # must be empty after the edit
wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-
omarchy-shell omarchy.bar debugIslandGeometry | jq '{expanded, displayedContext, transientVisible, transientPeek}'
# expected within ~1.3s: expanded=true, displayedContext="omarchy.volume", transientPeek=true
```

Known benign teardown noise (not this plugin): a burst of `QQmlVMEMetaObject: Internal error - attempted to evaluate a function in an invalid context`, `@Ui/WidgetButton.qml ... hideTooltip is not a function` and `panels/audio/Panel.qml ... Cannot read property 'foreground' of null` whenever the island's view `Loader` swaps or tears down. They are `WARN`-level only and are not caused by this plugin: an attribution pass reproduced none of them across a controlled shell restart, traced the `barConfig` binding loop to shell-side wiring (`/usr/share/omarchy/shell/shell.qml:115`, no plugin frame) and attributed part of the historical `QQmlVMEMetaObject` lines to another plugin's `TypeError`. The verify recipe lists them on purpose (see the note in the README), so a regression stays visible instead of being filtered away.

**Hot-reload didn't apply**
Expected. `rescanPlugins` + `Qt.clearComponentCache` can serve a stale bar. Always:

```bash
omarchy restart shell
```

Then verify with `debugIslandGeometry` (new PID). For static checks use the repository lint gate instead of a bare `qmllint <file>`: a bare invocation cannot resolve the shell's `qs.*` modules (it reports ~1366 findings, four of them failed imports) because a dotted import URI needs a `qs/` level the installed tree does not have.

```bash
bash lint.sh
```

See [`linting.md`](linting.md) for the invocation, the prerequisites and the baseline.

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

[← Back to the README](../README.md)
