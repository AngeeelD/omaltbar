# Development

How to take a change in this plugin from an edit to a verified change. The path
is short: lint the tree, apply the change to the running shell, then check the
shell's health.

Each step names its canonical recipe and links to where that recipe lives, and
none of them is copied here. Lint, restart and health-check instructions already
exist in [the README](../README.md) and [Troubleshooting](troubleshooting.md);
a second copy would drift from them the way the README's journal recipe and the
troubleshooting version already drifted apart once. This document is the map,
not a third source.

## Quick path

1. **Lint** — run the local `qmllint` gate: `lint.sh`. Invocation, prerequisites
   and the documented finding baseline are in [Linting](linting.md).
2. **Apply** — restart the shell so the bar recompiles and the IPC handler
   function list refreshes. The command is `omarchy restart shell`, documented
   under [Usage](../README.md#usage).
3. **Health check** — confirm the install and inspect the new shell process. The
   primary recipe is [Verify the install](../README.md#verify-the-install) in the
   README; [Troubleshooting](troubleshooting.md) covers the failure modes.

## Where each step lives

| Step | Canonical recipe | What it gives you |
|------|------------------|-------------------|
| Lint | `lint.sh`, documented in [Linting](linting.md) | One reproducible qmllint run and the warning/info baseline for this tree |
| Apply | `omarchy restart shell`, under [Usage](../README.md#usage) | A recompiled bar and a fresh process, which `rescanPlugins` does not reliably provide |
| Health check | [Verify the install](../README.md#verify-the-install) | Plugin discovery, the geometry/state readout, and the journal filter bound to the live shell PID |
| Failure modes | [Troubleshooting](troubleshooting.md) | Behavior notes and fixes for the common failures, including the journal recipe's stale-recipe pitfalls |

## Reading the path

Lint is advisory: a completed run always exits 0, so use it to catch
regressions against the documented baseline rather than as a pass/fail gate.
Apply is not optional — hot-reload is not reliable for the bar, and the IPC
handler function list does not refresh on a plugin rescan. Judge health from the
**new** shell process, not the one you just replaced.

For what a view renders and which context mounts it, read
[Views Reference](views.md). For the IPC surface, the state machine and the
context precedence, read [Component Reference](component-reference.md).

[← Back to the README](../README.md)
