# Configuration

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

The config surface lives in `~/.config/omarchy/shell.json` under `bar` and `bar.layout`; every mutable key has a shell IPC path, so `shell.json` is never hand-edited. Activation is `omarchy bar use angeeeld.omaltbar`, and the optional keys above are set through the shell API. Hot-reload is not trusted for bar changes — `omarchy restart shell` is the supported apply step.

[← Back to the README](../README.md)
