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
| `activeContext` | readonly string | Manual context while not paging, else the current resolved page | `IslandState.qml:51` |
| `pageCount` / `pageIndex` | readonly int | Page total while paging (0 otherwise) and the current page's index | `IslandState.qml:61` / `:63` |
| `transientContext` | writable string | Ephemeral overlay id; replaces the shown view without becoming a page | `IslandState.qml:73` |
| `transientSuspenders` | writable var | Token set; a view already hosting the control registers here to keep the overlay down | `IslandState.qml:86` |
| `transientSuspended` | readonly bool | True while any suspension token is held | `IslandState.qml:87` |
| `transientVisible` | readonly bool | Overlay is live: context set, expanded, no panel open, not suspended | `IslandState.qml:120` |
| `displayedContext` | readonly string | Transient while visible, otherwise `activeContext` — what the body renders | `IslandState.qml:123` |
| `clockFaceIds` | writable var | Contexts whose view already shows the time | `IslandState.qml:129` |
| `bodyShowsClock` | readonly bool | Expanded and the displayed context is a clock face (the pill hides its time) | `IslandState.qml:138` |
| `revealSide` | writable string | `""`, `"left"` or `"right"`: which widget grid the body shows | `IslandState.qml:147` |
| `gridContextLeft` / `gridContextRight` | readonly string | Grid sentinels `__island_grid_left` / `__island_grid_right` | `IslandState.qml:152` / `:153` |
| `soloWidgetId` | writable string | The one tile kept centered while that widget's own panel is open | `IslandState.qml:161` |
| `panelOpen` | writable bool | Injected by the island unit: a real plugin panel window is open on this screen | `IslandState.qml:168` |
| `autoOpened` | writable bool | The expansion came from an automatic cause, so the island must not take keyboard focus and hides the pager | `IslandState.qml:178` |
| `promoting` | writable bool | The beat of a promotion, from compact form into the full context | `IslandState.qml:184` |
| `nativeViews` | writable var | contextId → Component map for the body router | `IslandState.qml:323` |

### Transitions

| from | trigger | to | source |
|------|---------|----|--------|
| any | `openResolved(preferredId, automatic)` — sets `autoOpened = automatic`, clears `revealSide`, turns `paging` on; expands first when a transient is live, then picks the page (preferred → remembered → `entryId` → `pageIds[0]`) and expands | expanded, paging, resolved `pageId` | `IslandState.qml:194` |
| any | `reveal(side)` with `left`/`right` — records `revealSide`, turns `paging` off, clears `autoOpened`, sets `manualContext` to the grid sentinel, expands | expanded, grid context | `IslandState.qml:288` |
| expanded grid | `clearReveal()` — clears `revealSide`, then (unless `panelOpen` or a `soloWidgetId` is set) collapses the grid context | collapsed, `manualContext` cleared | `IslandState.qml:305` |
| any | `clearReveal()` reached with no grid context — native views survive their own policy | unchanged | `IslandState.qml:314` |
| any | `setContext(contextId)` — clears `revealSide`, turns `paging` off, clears `autoOpened`, writes `manualContext`, expands | expanded, manual context | `IslandState.qml:342` |
| any | `collapse()` — clears solo, `autoOpened`, `expanded`, `paging`, `manualContext`, `pageId`, then calls `clearReveal()` | collapsed, empty | `IslandState.qml:352` |
| paging | `pageNext()` / `pagePrev()` — ignored unless paging with more than one page; wraps | next / previous `pageId` | `IslandState.qml:227` / `:234` |
| paging | `goToPage(index)` — ignored unless paging and the index is valid | `pageId` at that index | `IslandState.qml:241` |
| paging | `onPageIdsChanged` — empty list clears `pageId`; otherwise a `pageId` that left the list falls back to `pageIds[0]` | valid `pageId` | `IslandState.qml:251` |
| any | `onPageIdChanged` — a landed page that is still in `pageIds` is written to `pageMemory.lastPageId` | remembered page | `IslandState.qml:36` |
| any | `enterSolo(id)` / `clearSolo()` | `soloWidgetId` set / cleared | `IslandState.qml:262` / `:268` |
| any | `suspendTransient(token)` / `releaseTransient(token)` — copy-on-write token set | `transientSuspended` true / false | `IslandState.qml:90` / `:99` |
| any | `markClockFace(id)` — registers a view that already shows the time | `bodyShowsClock` may turn true | `IslandState.qml:130` |
| any | `setNativeView(contextId, component)` | view registered in `nativeViews` | `IslandState.qml:333` |

Queries that never mutate: `gridContextFor(side)` (`IslandState.qml:276`),
`isGridContext(id)` (`:282`), `isSolo(id)` (`:272`), `nativeViewFor(id)`
(`:324`), `isActive(id)` (`:364`).

### Terminal modes: the grids

The two grid contexts `__island_grid_left` and `__island_grid_right` are
terminal modes: once `reveal()` has entered one, `collapse()` — or the
`clearReveal()` it calls — is its only exit. Nothing else in this file moves out
of a grid context; `clearReveal()` defers while `panelOpen` is true or a
`soloWidgetId` is set, because the grid tile is the live anchor of an open
widget panel (`IslandState.qml:305-313`).

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
(`IslandState.qml:73`).

[← Back to the README](../README.md)
