#!/usr/bin/env bash
# Omaltbar — local qmllint gate.
#
# qmllint is advisory here: it prints findings and always exits 0 on a completed
# run. The script exists so a contributor has one reproducible command and one
# documented baseline, on top of the tree that is installed on this machine.
#
# Why the temporary import root: this plugin imports the shell modules
# `qs.Commons` and `qs.Ui`. Those URIs carry a `qs` namespace level, so qmllint
# looks for a `qs/` directory level and does NOT resolve them from the installed
# layout, which keeps the modules in `<shell>/Commons` and `<shell>/Ui`. Pointing
# `-I` straight at the shell directory therefore reports 1366 findings, four of
# them "Failed to import qs.…", and the resulting noise hides the plugin's real
# findings. The script links the two module directories into a throwaway root
# shaped like the URIs (`qs/Commons`, `qs/Ui`) and lints through that. Nothing is
# written under /usr/share: the temporary root holds symlinks only and is removed
# on exit. With the modules resolved the run is always 886 findings, and because
# the two categories below are pinned to `info` this script prints exactly
# `10 warning(s), 876 info(s)` — the counts tabulated in docs/linting.md. Reading
# the same 886 under Qt's default levels is where an "880 warning" figure comes
# from (the 870 pinned findings rejoin the 10 real ones); that is the unpinned
# reading, not this script's output.
#
#   bash lint.sh
#
# QMLLINT_BIN and SHELL_IMPORT_DIR override the detected paths. Exit code is
# non-zero only for a missing prerequisite (qmllint, shell modules, or QML
# files), never because findings exist.
set -euo pipefail

QMLLINT_BIN="${QMLLINT_BIN:-/usr/lib/qt6/bin/qmllint}"
SHELL_IMPORT_DIR="${SHELL_IMPORT_DIR:-/usr/share/omarchy/shell}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Categories this plugin triggers on purpose: dynamic `property var` objects whose
# members qmllint cannot resolve, and object-tree navigation through `parent`.
# Pinned to `info` so the baseline is a property of this repository instead of the
# installed Qt defaults. Every other category keeps its Qt default level.
PINNED_CATEGORY_FLAGS=(--unqualified=info --missing-property=info)

# Global on purpose: the EXIT trap must see it after main() returns, where a
# `local` would already be out of scope.
IMPORT_ROOT=""
cleanup() {
  [[ -z $IMPORT_ROOT ]] || rm -rf "$IMPORT_ROOT"
}

fail() {
  printf 'lint.sh: %s\n' "$1" >&2
  exit 1
}

# Every QML file in the repository, sorted for a stable report. Top-level dot
# directories (.git and the agent trails) are pruned; the absolute REPO_DIR path
# itself contains dot directories, so the prune is anchored to the repo root.
qml_files() {
  find "$REPO_DIR" -path "$REPO_DIR/.*" -prune -o -name '*.qml' -print | sort
}

main() {
  [[ -x $QMLLINT_BIN ]] || fail "qmllint not found at $QMLLINT_BIN (set QMLLINT_BIN)"
  [[ -f "$SHELL_IMPORT_DIR/Commons/qmldir" ]] || fail "qs.Commons not found under $SHELL_IMPORT_DIR (set SHELL_IMPORT_DIR)"
  [[ -f "$SHELL_IMPORT_DIR/Ui/qmldir" ]] || fail "qs.Ui not found under $SHELL_IMPORT_DIR (set SHELL_IMPORT_DIR)"

  local files
  mapfile -t files < <(qml_files)
  (( ${#files[@]} > 0 )) || fail "no QML files found under $REPO_DIR"

  local import_root
  import_root="$(mktemp -d)"
  IMPORT_ROOT="$import_root"
  trap cleanup EXIT
  mkdir -p "$import_root/qs"
  ln -s "$SHELL_IMPORT_DIR/Commons" "$import_root/qs/Commons"
  ln -s "$SHELL_IMPORT_DIR/Ui" "$import_root/qs/Ui"

  printf 'qmllint: %s\n' "$("$QMLLINT_BIN" --version)"
  printf 'import root: %s -> %s\n' "$import_root/qs" "$SHELL_IMPORT_DIR"
  printf 'files: %d\n\n' "${#files[@]}"

  # --ignore-settings keeps a contributor-local .qmllint.ini out of the run; the
  # explicit category flags above stay authoritative.
  local output
  if ! output="$("$QMLLINT_BIN" --ignore-settings -I "$import_root" "${PINNED_CATEGORY_FLAGS[@]}" "${files[@]}" 2>&1)"; then
    printf '%s\n' "$output"
    fail "qmllint did not complete"
  fi
  printf '%s\n' "$output"

  local warnings infos
  warnings="$(printf '%s\n' "$output" | grep -cE '^Warning: .*\[[a-z-]+\]$' || true)"
  infos="$(printf '%s\n' "$output" | grep -cE '^Info: .*\[[a-z-]+\]$' || true)"
  printf '\nsummary: %s warning(s), %s info(s) — baseline in docs/linting.md\n' "$warnings" "$infos"
}

main "$@"
