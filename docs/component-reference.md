# Component Reference

Topic-scoped reference for the island's internals: the IPC surface it exposes,
the state machine that owns expand/page/overlay, and the context resolution
order. Everything here is derived statically from the QML source, and every row
carries a `File.qml:line` citation so it can be re-checked with `grep -n`. Read
[Architecture](architecture.md) for the shape of the bar and
[Configuration](configuration.md) for the `bar.island*` keys.

## Island IPC

The plugin's IPC surface: the 21 commands declared inside the
`IpcHandler { target: "omarchy.bar" }` block at
`NotchIslandBar.qml:1376-1638`. Invoke them as
`omarchy-shell omarchy.bar <command> [args]`. Supported commands come first; the
8 `debug*` commands are last. Each command cell carries its source line.

> [!CAUTION]
> The 8 rows marked `debug` are debug scaffolding, not a supported API. They
> exist to exercise paths a shell cannot drive (pointer hover, playback edges)
> and may change or disappear without notice.

| command | arguments | observable effect | stability |
|---------|-----------|-------------------|-----------|
| `syncHidden` (`NotchIslandBar.qml:1380`) | none | Re-runs the bar-hidden probe; `barHidden` resyncs from `~/.local/state/omarchy/toggles/bar-off`, and every island collapses while the toggle is on (`:1640-1644`) | stable |
| `island` (`NotchIslandBar.qml:1388`) | none | Toggles the focused screen's island: collapses when expanded, otherwise opens on the resolved page. This is the Super+Caps hotkey | stable |
| `notchScale` (`NotchIslandBar.qml:1408`) | `value` (positive number, as string) | Persists `bar.islandNotchScale` through the shell config API. A non-finite or non-positive value is ignored | stable |
| `islandFirst` (`NotchIslandBar.qml:1419`) | `value` (comma-separated context ids; empty clears) | Replaces `bar.islandFirstContexts` with the trimmed, de-duplicated id list | stable |
| `settingsIcon` (`NotchIslandBar.qml:1435`) | `value` = `true` \| `false` \| `toggle` (also `on`/`off`/`1`/`0`) | Shows or hides this plugin's own settings gear in the bar | stable |
| `useBar` (`NotchIslandBar.qml:1443`) | `id` (bar plugin id, e.g. `angeeeld.omaltbar`; empty = default bar) | Switches the active bar implementation | stable |
| `contextFlag` (`NotchIslandBar.qml:1448`) | `id`, `enabled` (`false`/`off`/`0` disables) | Enables or disables a context provider: no page, no entry page, no overlay | stable |
| `timing` (`NotchIslandBar.qml:1457`) | `key`, `value` | Sets one timing/motion override through the shell config API (clamped on read) | stable |
| `resetTiming` (`NotchIslandBar.qml:1460`) | none | Clears every timing and motion override | stable |
| `opacity` (`NotchIslandBar.qml:1465`) | `value` (alpha) | Sets the surface alpha of both island surfaces through `bar.islandOpacity`; inert while transparent is off | stable |
| `pillCompact` (`NotchIslandBar.qml:1474`) | `value` = `true` \| `false` \| `toggle` (also `on`/`off`/`1`/`0`) | Sets the pill resting form: compact badge or wide notch pill | stable |
| `pillWidth` (`NotchIslandBar.qml:1480`) | `value` (logical px; empty or `0` restores derived geometry) | Sets `bar.islandPillWidth` | stable |
| `hotkey` (`NotchIslandBar.qml:1486`) | `action` (`island.toggle` / `island.settings`), `keys` (Hyprland key string; empty clears) | Manages one Hyprland bind through `bar.islandHotkeys`; the render + reload is `hotkeys.sh` | stable |
| `debugOpen` (`NotchIslandBar.qml:1398`) | `contextId` (string; empty = resolved page) | Mounts that context without pointer injection: `setContext` for a named id, `openResolved` for empty | debug |
| `debugTiming` (`NotchIslandBar.qml:1491`) | none | Returns JSON of the effective, clamped timing/motion/opacity and bar values | debug |
| `debugMediaPeek` (`NotchIslandBar.qml:1512`) | none | Raises the compact media peek exactly as a playback change does | debug |
| `debugPromote` (`NotchIslandBar.qml:1515`) | none | Runs the pointer-approach promotion on the focused island | debug |
| `debugLastPage` (`NotchIslandBar.qml:1522`) | `id` | Pins `lastPageId`, so the resolver's next reopen is forced onto that context | debug |
| `debugToastSnapshots` (`NotchIslandBar.qml:1530`) | none | Returns JSON of the held toast snapshots, default-action argv included. Read-only: the argv is never run here | debug |
| `debugSettingsWidget` (`NotchIslandBar.qml:1544`) | none | Returns JSON of the settings-widget wiring: registry keys, entry presence, icon flag, right-side ids | debug |
| `debugIslandGeometry` (`NotchIslandBar.qml:1567`) | none | Returns JSON of the geometry and state readout (scales, pill/body widths, contexts, providers) | debug |

### Not one of the 21: `debugBarGeometry`

The shell's own `omarchy.bar` handler declares `debugBarGeometry()` at
`/usr/share/omarchy/shell/shell.qml:1000-1001` (read-only) and delegates to the
active bar, so `omarchy-shell omarchy.bar debugBarGeometry` resolves even though
the plugin never declares it in its `IpcHandler`. The plugin's own module-point
helper of that name sits outside the block at `NotchIslandBar.qml:1125`. Neither
is one of the plugin's 21 commands, and neither appears in the table above.

## Island state machine

`IslandState.qml` is the single source of truth for expand/collapse, the active
page and the ephemeral transient overlay; one instance exists per screen. This
section enumerates its state and every transition from the properties and
functions in the file, not from comments.

### State

| state | kind | meaning | source |
|-------|------|---------|--------|
| `expanded` | writable bool | Island body is expanded below the notch pill | `IslandState.qml:15` |
| `pageIds` | writable var | Ordered page list owned by the resolver: active big contexts, default last | `IslandState.qml:23` |
| `pageId` | writable string | Page the user is on, stored by identity so context churn never yanks it | `IslandState.qml:24` |
| `entryId` | writable string | Page a bottom entry lands on; bound from the resolver focus list | `IslandState.qml:28` |
| `pageMemory` | writable var | Back-reference to the resolver, which remembers the last page across collapse | `IslandState.qml:31` |
| `paging` | writable bool | Body is driven by the resolved page list; off for manual contexts and grids | `IslandState.qml:45` |
| `manualContext` | writable string | Non-paged context: `""` home, a native view id, or a grid sentinel | `IslandState.qml:48` |
| `activeContext` | readonly string | Manual context while not paging, else the current resolved page | `IslandState.qml:67` |
| `pageCount` / `pageIndex` | readonly int | Page total while paging (0 otherwise) and the current page's index | `IslandState.qml:77` / `:79` |
| `transientContext` | writable string | Ephemeral overlay id; replaces the shown view without becoming a page | `IslandState.qml:89` |
| `transientSuspenders` | writable var | Token set; a view already hosting the control registers here to keep the overlay down | `IslandState.qml:102` |
| `transientSuspended` | readonly bool | True while any suspension token is held | `IslandState.qml:103` |
| `transientVisible` | readonly bool | Overlay is live: context set, expanded, no panel open, not suspended | `IslandState.qml:136` |
| `displayedContext` | readonly string | Transient while visible, otherwise `activeContext` — what the body renders | `IslandState.qml:139` |
| `clockFaceIds` | writable var | Contexts whose view already shows the time | `IslandState.qml:145` |
| `bodyShowsClock` | readonly bool | Expanded and the displayed context is a clock face (the pill hides its time) | `IslandState.qml:154` |
| `revealSide` | writable string | `""`, `"left"` or `"right"`: which widget grid the body shows | `IslandState.qml:163` |
| `gridContextLeft` / `gridContextRight` | readonly string | Grid sentinels `__island_grid_left` / `__island_grid_right` | `IslandState.qml:168` / `:169` |
| `soloWidgetId` | writable string | The one tile kept centered while that widget's own panel is open | `IslandState.qml:177` |
| `panelOpen` | writable bool | Injected by the island unit: a real plugin panel window is open on this screen | `IslandState.qml:184` |
| `autoOpened` | writable bool | The expansion came from an automatic cause, so the island must not take keyboard focus and hides the pager | `IslandState.qml:194` |
| `promoting` | writable bool | The beat of a promotion, from compact form into the full context | `IslandState.qml:200` |
| `clickOpened` | writable bool | The island was opened by a click (indicator circle / app sphere): hover is locked out and the body may take the keyboard | `IslandState.qml:58` |
| `clickOpenedContext` | writable string | The context that click-opened the island | `IslandState.qml:64` |
| `nativeViews` | writable var | contextId → Component map for the body router | `IslandState.qml:345` |

### Transitions

| from | trigger | to | source |
|------|---------|----|--------|
| any | `openResolved(preferredId, automatic)` — sets `autoOpened = automatic`, clears `revealSide`, turns `paging` on; expands first when a transient is live, then picks the page (preferred → remembered → `entryId` → `pageIds[0]`) and expands | expanded, paging, resolved `pageId` | `IslandState.qml:210` |
| any | `reveal(side)` with `left`/`right` — records `revealSide`, turns `paging` off, clears `autoOpened`, sets `manualContext` to the grid sentinel, expands | expanded, grid context | `IslandState.qml:308` |
| expanded grid | `clearReveal()` — clears `revealSide`, then (unless `panelOpen` or a `soloWidgetId` is set) collapses the grid context | collapsed, `manualContext` cleared | `IslandState.qml:327` |
| any | `clearReveal()` reached with no grid context — native views survive their own policy | unchanged | `IslandState.qml:336` |
| any | `setContext(contextId, byClick)` — clears `revealSide`, turns `paging` off, clears `autoOpened`, writes `manualContext`, sets `clickOpened = byClick === true`, expands | expanded, manual context | `IslandState.qml:368` |
| any | `collapse()` — clears solo, `autoOpened`, `clickOpened`, `expanded`, `paging`, `manualContext`, `pageId`, then calls `clearReveal()` | collapsed, empty | `IslandState.qml:380` |
| paging | `pageNext()` / `pagePrev()` — ignored unless paging with more than one page; wraps | next / previous `pageId` | `IslandState.qml:247` / `:254` |
| paging | `goToPage(index)` — ignored unless paging and the index is valid | `pageId` at that index | `IslandState.qml:261` |
| paging | `onPageIdsChanged` — empty list clears `pageId`; otherwise a `pageId` that left the list falls back to `pageIds[0]` | valid `pageId` | `IslandState.qml:271` |
| any | `onPageIdChanged` — a landed page that is still in `pageIds` is written to `pageMemory.lastPageId` | remembered page | `IslandState.qml:36` |
| any | `enterSolo(id)` / `clearSolo()` | `soloWidgetId` set / cleared | `IslandState.qml:282` / `:288` |
| any | `suspendTransient(token)` / `releaseTransient(token)` — copy-on-write token set | `transientSuspended` true / false | `IslandState.qml:106` / `:115` |
| any | `markClockFace(id)` — registers a view that already shows the time | `bodyShowsClock` may turn true | `IslandState.qml:146` |
| any | `setNativeView(contextId, component)` | view registered in `nativeViews` | `IslandState.qml:355` |

Queries that never mutate: `gridContextFor(side)` (`IslandState.qml:296`),
`isGridContext(id)` (`:302`), `isSolo(id)` (`:292`), `nativeViewFor(id)`
(`:346`), `isActive(id)` (`:394`).

### Terminal modes: the grids

The two grid contexts `__island_grid_left` and `__island_grid_right` are
terminal modes: once `reveal()` has entered one, `collapse()` — or the
`clearReveal()` it calls — is its only exit. Nothing else in this file moves out
of a grid context; `clearReveal()` defers while `panelOpen` is true or a
`soloWidgetId` is set, because the grid tile is the live anchor of an open
widget panel (`IslandState.qml:327-335`).

### Manual context: `island.themeSwitcher`

The theme picker (`views/ThemeSwitcherView.qml`) is a manual context, not a page.
Its whole round trip is traceable through this file:

- **Entry.** `Keys.onDownPressed` on the island card
  (`NotchIslandBar.qml:3256`) bails unless the island is `expanded` and
  `displayedContext` is not already this id, then calls `markInteraction()` and
  `setContext("island.themeSwitcher")` (`IslandState.qml:368`). The picker's own
  field and strip accept their arrow keys, so a Down that reaches the card is
  always an entry from outside the picker.
- **Exit.** `collapse()` (`IslandState.qml:380`) is the only exit: Escape on the
  card, or a click on the body outside it. The picker owns no teardown.
- **`pageIds` exclusion.** The id is registered in the `nativeViews` map only
  (`DynamicIsland.qml:605`), never in the resolver's page list
  (`ContextResolver.qml:298`), so while the picker is inactive
  `pagePrev()`/`pageNext()` (`IslandState.qml:254`/`:247`) keep paging untouched.
- **No new IPC command.** The 21-command block above is unchanged. Down is the
  only trigger, and `debugOpen island.themeSwitcher` is the debug entry.
- **Palette.** The cards read `ThemePalette.qml`, one instance owned by
  `DynamicIsland` outside the body `Loader`, which makes a single warm-up pass at
  plugin load and watches `~/.local/state/omarchy/current/theme.name`. The apply
  path is `omarchy-theme-set <name>`, reconciled against that watcher.

## Indicator row and app spheres

Two static surfaces sit beside the notch pill: the app spheres immediately to
its left, the indicator row immediately to its right. Both are mounted as
siblings of the notch body inside `pillContent` (`NotchIslandBar.qml:3101-3136`)
and parked against the pill's **current logical** edges (`unit.pillLeftEdge` /
`unit.pillRightEdge`), never against the animated wing formula. Those edges are
derived from `unit.pillLogicalWidth`, a plain binding on the logical state
boolean — `unit.pillMinimized ? unit.dotWidth : unit.pillWidth`
(`NotchIslandBar.qml:2679`) — so the two runs **jump** to hug the compact dot
when the pill compacts and the expanded pill when it expands, and never chase
the animation frames (`notchBody.visualW = minWidth + (pillW - minWidth) *
collapse` is deliberately not used). The left run stays right-anchored and the
right run left-anchored, with the same `besidePillGap` margin, so the two runs
still cannot overlap. Both are click-only: the dwell/hover policy belongs to
another change, so neither adds a hover handler.

Every circle in both halves is `unit.besidePillCircle`, one shared derivation of
`Math.round(unit.pillHeight * 0.8)` (`NotchIslandBar.qml:2689`) handed to both
mounts, so the dials and the spheres stay the same size and the arithmetic lives
in one place. While the island body is expanded — the same
`IslandState.expanded` that retracts the pill — both runs fade and shrink away
(`opacity` and `scale` animate 1 → 0 and back together, at the mount's
`motionDuration` = `root.motion.base`, the pill's own motion) and `disable`
themselves, so a faded-out circle can never be tapped blind. The run's geometry
does not move: an Item's `scale` leaves the layout untouched.

### Indicator row

`PillIndicatorRow.qml` is the always-visible row on the right of the pill. It
renders four `PillStatusDial` circles from one `PillStatusSource`, and each
circle opens a context through `IslandState.setContext`:

| circle / role | source reading | context opened |
|---|---|---|
| battery (`power`) | `batteryFraction` / `batteryPresent` | `omarchy.power` |
| Wi-Fi (`network`) | `wifiFraction` / `wifiKind` | `omarchy.network` |
| Bluetooth (`bluetooth`) | `btState.fraction` / `btState.available` | `omarchy.bluetooth` |
| music meter (`media`) | `meterState.level`, and the dial is absent while `meterState.playing` is false | `omarchy.media` |

The role mapping lives on the row (`PillIndicatorRow.contextForRole`), so the
dial stays a dumb painter: it gained a `role` property and a bare `TapHandler`
that emits `clicked(role)` and owns no activation logic
(`PillStatusDial.qml:32-36`, handler at `:125`). The row sizes its four dials
from its own `diameter` property, which the mount feeds with
`unit.besidePillCircle` (`PillIndicatorRow.qml:27`), and it carries the
open-hide on its root (`PillIndicatorRow.qml:66-70`). Its painting gained one
filled circle behind the ring — a `Color.bar.background` bubble (the pill's own
surface) with the glyph and the optional label in the pill clock's
`Color.bar.text` family (each keeping its availability alpha, `:107` and `:116`),
and the value arc in that same `Color.bar.text` (`:85`), so the ring and the glyph
carry one colour. The ring is inset from the bubble's edge on purpose — hugging it
made the arc read as a thicker border instead of as the progress indicator — so
both the track and the value arc share the inset `arcRadius` (`:48-50`). The glyph
is a fraction of the bubble (`glyphRatio`, `:41`), and it deliberately stayed at
80% of the ratio it had before the circles grew, so enlarging the circles did not
enlarge the icons (the glyph `Text` at `PillStatusDial.qml:104-110`).

The indicator line itself is **15% thinner** than the original `diameter / 12`
ring: `arcWidth` is a `real` (`PillStatusDial.qml:29`) rather than a rounded
`int`, because rounding snapped the reduction straight back to the old value at
the current 51 px diameter (4.25 → 3.61 → 4). It keeps the 2 px floor.

`PillStatusSource.qml` gained the two new sources behind those circles:
Bluetooth (`btState`, from the BlueZ adapter and its devices,
`PillStatusSource.qml:112`) and the music meter (`meterState`, MPRIS transport
plus the PipeWire default sink's live peak, `PillStatusSource.qml:147`).

### Pill gesture pair

`bar.islandInvertPillClicks` still swaps two clicks, but the pair changed. The
retired template swap — `togglePillTemplate()`, the session-only
`pillStatusMode` and the two in-pill `PillStatusDial` instances — is gone, and
RIGHT now toggles the circles beside the pill instead:

| `bar.islandInvertPillClicks` | RIGHT click | LEFT click |
|---|---|---|
| `false` | toggles the circles (`toggleCircles()`, session) | pins the compact dot (`togglePillCompact()`, persists `bar.islandPillCompact`) |
| `true` | pins the compact dot | toggles the circles |

`circlesVisible` is session-only and defaults to `true`
(`NotchIslandBar.qml:1872`). It governs the indicator row **and** the app
spheres as one set — `PillIndicatorRow.circlesVisible` and
`PillAppSpheres.circlesVisible` are both fed from `unit.circlesVisible` at the
mounts (`NotchIslandBar.qml:3114` and `:3134`) — so a toggle hides both runs, and
no `bar.*` key was added. The settings-panel hint was updated to name the circles
instead of only the indicator row.

### App spheres and the window-list context

`PillAppSpheres.qml` is the static row parked immediately left of the pill and
growing leftwards: one circle per app with a window on this screen, alphabetical,
inside a horizontal `Flickable` whose wheel event is accepted so it never reaches
the collapse/peek policy. Its `sphereSize` is an overridable property whose
default matches the dial diameter and which the mount sets to
`unit.besidePillCircle` (`PillAppSpheres.qml:22`), and the row carries the same
open-hide as the indicator row (`:82-86`). Each sphere is a filled
`Color.bar.background` bubble — the pill's own surface, so it stays legible over
any wallpaper — with the selected app rimmed in `accent`; the unresolved-icon
fallback glyph uses `Color.bar.text` like the dials
(`PillAppSpheres.qml:143-150`). The app icon is a fraction of the bubble
(`iconRatio`, `:28`) and, like the dial's glyph, it stayed at 80% of the ratio it
had before the spheres grew (`fallbackGlyphRatio`, `:30`).

A sphere click branches on the group size (`PillAppSpheres.qml:51-63`):

- **exactly one window** → that window is focused immediately through
  `WindowSource.focusToplevel` and the island is **not** opened;
- **two or more windows** → `WindowSource.selectedAppId` is set and
  `IslandState.setContext("island.windowList", true)` opens the list. The second
  argument marks the island **click-opened** (see below).

`WindowSource.qml` is the single per-screen reader those surfaces share. It
projects `Hyprland.toplevels` (event-driven; no polling), groups by
`Wayland Toplevel.appId` with the `lastIpcObject.class || initialClass`
fallback, filters to the unit's `hostScreen.name`, and resolves icons through
`DesktopEntries` with the generic executable fallback
(`WindowSource.qml:124`). `addressFor(toplevel)` returns `0x`-prefixed hex only
after validating the bare address against `/^[0-9a-fA-F]+$/`; an empty return
means the focus action must not run (`WindowSource.qml:75`).

`focusToplevel(toplevel)` (`WindowSource.qml:90-99`) is the **one** focus
implementation, shared by the single-window sphere shortcut and by the window
list (a card tap, an arrow key or a digit). It validates through `addressFor`,
aborts without running any command on an invalid/empty address, and otherwise
spawns the proven expose command detached —
`hyprctl eval "hl.dispatch(hl.dsp.focus({ window = 'address:0x…' }))"` — with the
~0.2 s unmap delay inside the surviving process. The delay deliberately lives
outside any view: collapsing the island clears `DynamicIsland.activeComponent`,
which destroys the view and anything timed inside it.

`island.windowList` is a **manual context, not a page**: it is deliberately not
added to `ContextResolver.pageIds`, so it never joins the carousel and never
becomes the entry page. The round trip is:

1. **Entry** — a sphere click on a multi-window app selects the app and calls
   `IslandState.setContext("island.windowList", true)` (`PillAppSpheres.qml:62`);
   the `true` marks the island click-opened. A single-window app never reaches
   here (it focuses directly, see above).
2. **Render** — `DynamicIsland` registers `views/WindowListView.qml` for that
   id (`DynamicIsland.qml:607`), and the router loads it through
   `IslandState.nativeViewFor`.
3. **Live previews** — a card's `ScreencopyView` is live only while this context
   is the one shown and the view is laid out (`views/WindowListView.qml:34`); a
   capture with no content shows "Preview unavailable" while the icon and title
   stay. The card run is **centered** while it fits the island, and only
   left-aligned once it overflows (`views/WindowListView.qml:178`).
4. **Keyboard** — each card carries a floating **number badge** (1..N,
   `views/WindowListView.qml:301-325`); Left/Right move the selection
   (`moveSelection`, `:75-83`) and a digit focuses the matching instance
   (`handleDigit`, `:97-101`). The handlers live on the island card
   (`NotchIslandBar.qml:3226-3249` and `:3266-3273`) and only fire while the
   window list is the active context; ESC is the card's existing Escape handler
   (`:3216-3221`).
5. **Exit / focus** — a card tap, an arrow or a digit calls
   `views/WindowListView.focusWindow` (`:88-92`), which delegates to the one
   shared `WindowSource.focusToplevel` and then collapses the island. The Lua
   dispatcher form is the one this Hyprland's config mode uses.

### Click-opened islands: hover lock and keyboard

`IslandState.clickOpened` (`IslandState.qml:58`) is set by
`setContext(id, true)` (`IslandState.qml:368-378`) — the path taken by an
indicator circle (`PillIndicatorRow.qml:51`) and by a multi-window sphere
(`PillAppSpheres.qml:62`). While it is true:

- the body surface takes `WlrKeyboardFocus.Exclusive`
  (`NotchIslandBar.qml:3179-3181`, through `escapeFocusWanted`, `:2055-2058`), so
  ESC / arrows / digits reach the card's `Keys` handlers; the surface returns to
  `None` the moment the island collapses (or a plugin window opens), because
  `clickOpened` is cleared by `collapse()`;
- hover is muted: `handlePillZone` (`NotchIslandBar.qml:2728-2749`) records the
  zone but takes no action, and the pointer-away `autoHideTimer` refuses to
  retire the island (`:2422-2439`), so moving the pointer cannot expand,
  collapse or swap the context;
- `openResolved` (`IslandState.qml:210`), `reveal` (`:308`) and `collapse`
  (`:380`) all clear the flag, so any hover-owned or hotkey open resumes normal
  behaviour.

The normal hover-driven island never sets `clickOpened`, so the click-opened
grant cannot leak into it; its pre-existing rule — keyboard focus while the
pointer is on the body card and the island was not opened automatically — is
unchanged, so a hover with the pointer still on the pill never grabs the
keyboard.

## Context resolution

`ContextResolver.qml` decides which contexts are alive, the order the island
pages through them, and which one wins entry. One instance lives on the bar root
and is shared by every island unit.

### Precedence

Highest first; the first active id in this order is the winner, and the default
page is the base:

1. `island.screenrecord` — `ContextResolver.qml:269`
2. `omarchy.media` — `ContextResolver.qml:270`
3. `omarchy.microphone` — `ContextResolver.qml:271`
4. `island.notificationToast` — `ContextResolver.qml:272`
5. `jankeesvw.notification-center` — `ContextResolver.qml:273`
6. `island.default` — the always-present fallback, `ContextResolver.qml:298`; its id is declared at `ContextResolver.qml:45`

The first five are the "big" contexts pushed into `activeBigIds` in that order
(`ContextResolver.qml:267-275`). Each is gated on `contextEnabled(id)`, so a
disabled provider is absent from both the page list and the entry page. The page
order is `activeBigIds.concat([defaultContextId])`, so the default page is always
last (`ContextResolver.qml:298`).

### Focus / page split

`focusIds` (`ContextResolver.qml:279-285`) is the subset allowed to own the
initial page: screen recording, media and microphone only. Notifications — both
the toast and the history page — are pageable but deliberately excluded, so a
toast can never reorder where the island opens. `entryContextId` is
`focusIds[0]`, falling back to `island.default` when no focus context is active
(`ContextResolver.qml:287-288`). A non-focus context is reachable by swipe and
by the pager, but never becomes the entry page.

### Transient TTL and sequence

- `transientTtlMs` defaults to 1600 (`ContextResolver.qml:307`).
- `transientSeq` is a monotonic per-request counter: one island peek per
  request, so a repeated id (volume up twice) still bumps it
  (`ContextResolver.qml:312`).
- `mediaPeekContextId` is `island.mediaPeek` (`ContextResolver.qml:392`) and
  `mediaPeekTtlMs` defaults to 2600, longer than the OSD TTL
  (`ContextResolver.qml:395`). `activeTransientTtlMs` picks between the two
  (`ContextResolver.qml:396-397`).

Transients are not pages: they replace `displayedContext` while they live, and
the resolver pushes the id in rather than the island opening itself
(`IslandState.qml:89`).

[← Back to the README](../README.md)
