#!/usr/bin/env bash
# Notch Island — managed Hyprland keybinds.
#
# Hyprland has no persistent runtime keybind API: binds live in
# ~/.config/hypr/bindings.lua and are rebuilt on every reload. So the island
# renders one marked block in that file from the `bar.islandHotkeys` object in
# shell.json (written by the settings panel through mutateShellConfig) and then
# asks Hyprland to reload.
#
#   bash hotkeys.sh render    rewrite the managed block and reload Hyprland
#
# Every managed key is unbound immediately before it is bound, so a hand-written
# line for the same key earlier in the file cannot leave a duplicate bind firing
# twice (a double toggle is a silent no-op). Binds that are removed from the
# config simply stop being written; on the next reload Hyprland drops them.
set -euo pipefail

SHELL_JSON="${OMARCHY_SHELL_JSON:-$HOME/.config/omarchy/shell.json}"
BINDINGS_LUA="${HYPR_BINDINGS_LUA:-$HOME/.config/hypr/bindings.lua}"
BEGIN='-- >>> angeeeld.omaltbar hotkeys (managed; edit them in the island settings panel)'
END='-- <<< angeeeld.omaltbar hotkeys'

# action key | bind description | command
ACTIONS=(
  "island.toggle|Omaltbar|omarchy-shell omarchy.bar island"
  "island.settings|Omaltbar settings|omarchy-shell angeeeld.omaltbar.settings toggle"
)

render_block() {
  for entry in "${ACTIONS[@]}"; do
    IFS='|' read -r action description command <<<"$entry"
    local keys
    keys="$(jq -r --arg k "$action" '(.bar.islandHotkeys // {})[$k] // ""' "$SHELL_JSON" 2>/dev/null || true)"
    keys="$(printf '%s' "$keys" | tr -d '\n' | sed 's/^ *//; s/ *$//')"
    [[ -n $keys ]] || continue
    # Refuse anything that could break out of the Lua string literals.
    if [[ ! $keys =~ ^[A-Za-z0-9_+:,.\ -]+$ ]]; then
      printf 'hotkeys.sh: refusing unsafe key string for %s: %s\n' "$action" "$keys" >&2
      continue
    fi
    printf 'hl.unbind("%s")\n' "$keys"
    printf 'o.bind("%s", "%s", "%s")\n' "$keys" "$description" "$command"
  done
}

strip_block() {
  awk -v begin="$BEGIN" -v end="$END" '
    $0 == begin { skip = 1; next }
    $0 == end   { skip = 0; next }
    !skip       { print }
  ' "$1"
}

main() {
  command -v jq >/dev/null 2>&1 || { echo "hotkeys.sh: jq is required" >&2; exit 1; }
  mkdir -p "$(dirname "$BINDINGS_LUA")"
  [[ -f $BINDINGS_LUA ]] || : >"$BINDINGS_LUA"

  local tmp body
  tmp="$(mktemp)"
  body="$(strip_block "$BINDINGS_LUA")"

  {
    [[ -z $body ]] || printf '%s\n' "$body"
    printf '\n%s\n' "$BEGIN"
    render_block
    printf '%s\n' "$END"
  } >"$tmp"

  mv "$tmp" "$BINDINGS_LUA"

  hyprctl reload >/dev/null 2>&1 || true
}

main "$@"
