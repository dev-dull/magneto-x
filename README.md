# Magneto X Monorepo

A community-maintained monorepo consolidating the software stack for the
[Peopoly Magneto X](https://peopoly.net/) 3D printer. The upstream
repositories under [github.com/mypeopoly](https://github.com/mypeopoly) are
effectively unmaintained; this repo gathers them in one place (with their
original Git history preserved) as a base for continued development.

## Contents

| Directory | Upstream repo | Purpose |
|---|---|---|
| `Klipper/` | [mypeopoly/Klipper](https://github.com/mypeopoly/Klipper) | Klipper firmware tailored for the Magneto X (MagXY maglev linear motors, Lancer extruder) |
| `magneto-x-klipper-config/` | [mypeopoly/magneto-x-klipper-config](https://github.com/mypeopoly/magneto-x-klipper-config) | Klipper/KlipperScreen config files and KAMP macros for the Magneto X |
| `magneto-manager-tool/` | [mypeopoly/magneto-manager-tool](https://github.com/mypeopoly/magneto-manager-tool) | Tool to get/set MCU and CAN bus UUIDs over HTTP; ESP flashing helpers |
| `magnetox-os-update/` | [mypeopoly/magnetox-os-update](https://github.com/mypeopoly/magnetox-os-update) | OTA update payload for the printer OS (update script, patched configs, auto-UUID helpers) |
| `magneto-x-os-mirror/` | [mypeopoly/magneto-x-os-mirror](https://github.com/mypeopoly/magneto-x-os-mirror) | Placeholder repo whose GitHub releases carry the MainsailOS-based OS images (images themselves are **not** in this monorepo) |
| `vlare/` | [mypeopoly/vlare](https://github.com/mypeopoly/vlare) | Placeholder repo whose GitHub releases carry VlareSlicer builds (binaries **not** in this monorepo) |

## How this was built

Each upstream repo was cloned, its history rewritten with
`git filter-repo --to-subdirectory-filter <name>` so all paths live under the
repo's own subdirectory, and then merged into this repository with
`git merge --allow-unrelated-histories`. Every upstream commit is preserved
verbatim apart from the path prefix.

Notes:

- Only each upstream's default branch was imported; tags were not carried over.
- Release artifacts (OS images, VlareSlicer installers) live in the upstream
  repos' GitHub Releases and were not imported.
- Upstream Klipper history is shallow: Peopoly published their Klipper tree as
  a handful of squashed commits rather than a fork of
  [Klipper3d/klipper](https://github.com/Klipper3d/klipper).

## Licensing

Each subdirectory retains its upstream license file (Klipper and the configs
are GPL-3.0). See the `LICENSE` files within each directory.
