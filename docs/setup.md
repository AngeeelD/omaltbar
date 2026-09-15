# Setup

## Required vs optional

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

[← Back to the README](../README.md)
