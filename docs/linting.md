# Linting

`qmllint` is the only static check this repository has. There is no CI and no test runner: the
script below is advisory, and its value is a *single reproducible command with a documented
baseline*, not a pass/fail gate. It never blocks a change — findings are for judgement.

## Run it

```bash
# from the repository root
bash lint.sh
```

The script prints the tool version, the resolved import root, the file count, every finding, and a
one-line summary. It exits `0` on a completed run and non-zero **only** when a prerequisite is
missing (no `qmllint`, no shell modules, no QML files) — never because findings exist.

Two environment variables override the detected paths:

| Variable | Default | Purpose |
|----------|---------|---------|
| `QMLLINT_BIN` | `/usr/lib/qt6/bin/qmllint` | The binary to run. `qmllint` is not on `PATH` on Omarchy. |
| `SHELL_IMPORT_DIR` | `/usr/share/omarchy/shell` | The installed shell tree that holds the `qs.Commons` and `qs.Ui` modules. |

## Prerequisites

| Prerequisite | Detected as | Why |
|--------------|-------------|-----|
| Qt 6 declarative tooling | `/usr/lib/qt6/bin/qmllint` — 6.11.2 on the documented toolchain | Only `qmllint` resolves the plugin's imports; the Qt 6 CLI is not on `PATH` |
| Installed omarchy package | `/usr/share/omarchy/shell/{Commons,Ui}/qmldir` | Declares `module qs.Commons` / `module qs.Ui`; the plugin imports both |

Both are read-only uses. `lint.sh` never writes under `/usr/share`.

## Why the script builds an import root

The plugin imports the shell modules by qualified URI (`import qs.Commons`, `import qs.Ui`). A URI
with a dot is looked up *as a path*: `qs.Commons` is expected at `<import-root>/qs/Commons`. The
installed tree keeps the modules at `<shell>/Commons` and `<shell>/Ui` — there is no `qs` level — so
pointing `-I` straight at the shell directory does **not** resolve them:

```bash
# measured on Qt 6.11.2: 1366 warnings, four of them import failures
/usr/lib/qt6/bin/qmllint --ignore-settings -I /usr/share/omarchy/shell *.qml views/*.qml
#   Warning: …: Failed to import qs.Commons. Are your import paths set up properly? [import]
#   Warning: …: Failed to import qs.Ui. Are your import paths set up properly? [import]
```

Unresolved imports drown the output, and every `qs.*` access then reports as unqualified. So
`lint.sh` links the two module directories into a temporary root shaped like the URIs
(`<tmp>/qs/Commons`, `<tmp>/qs/Ui`) and lints through that root. The temporary root holds symlinks
only and is removed on exit. With the modules resolved the run reports no unresolved shell import,
and the finding count drops to the baseline below. The same resolution is what makes the numbers
comparable between runs — it is the *invocation*, not the toolchain, that produced the 1366.

## Baseline

Measured with `bash lint.sh` on Qt **6.11.2** against the installed omarchy shell, over the 24 QML
files in this repository:

| Category | Findings | Level under `lint.sh` |
|----------|----------|----------------------|
| `[unqualified]` | 439 | `info` (pinned) |
| `[missing-property]` | 431 | `info` (pinned) |
| `[unused-imports]` | 6 | `info` (Qt default) |
| `[unresolved-type]` | 5 | `warning` (Qt default) |
| `[signal-handler-parameters]` | 3 | `warning` (Qt default) |
| `[uncreatable-type]` | 2 | `warning` (Qt default) |
| **total** | **886** | 876 info + 10 warning |

A run matches the baseline when it prints `summary: 10 warning(s), 876 info(s)` and the same
per-category counts. The finding set is expected to be stable; the file paths are absolute and will
differ between checkouts, the counts will not.

### Residual noise

`[unqualified]` and `[missing-property]` are pinned to `info` by the two category flags in
`lint.sh` because they are structural, not defects:

- the plugin renders a large amount of the bar from dynamic `property var` objects (`root.fg`,
  `wifiRow.net`, …), whose members qmllint cannot resolve statically;
- unqualified `parent` / `Style` / `Color` access inside nested components is the existing house
  style.

That pinning is deliberate: it makes the baseline a property of this repository instead of the
installed Qt defaults, and it leaves the 10 remaining warnings (real type and signal issues) as the
part worth reading. It is also why `lint.sh` passes `--ignore-settings`: a contributor-local
`.qmllint.ini` in the tree must not perturb results.

## Updating the baseline

The numbers are tied to the toolchain. When `qmllint` or the installed shell moves to a new Qt
version, run `bash lint.sh`, compare the report against the table above, and update the table with
what the run actually printed — including the version line. Do not adjust the script to reproduce
an old count.
