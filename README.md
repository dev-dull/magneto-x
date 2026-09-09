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
| `magneto-manager-tool/` | [mypeopoly/magneto-manager-tool](https://github.com/mypeopoly/magneto-manager-tool) | ESP32 flashing tools (esptool wrappers). The UUID get/set HTTP service it once carried now lives canonically in `magnetox-os-update/auto-uuid/` |
| `magnetox-os-update/` | [mypeopoly/magnetox-os-update](https://github.com/mypeopoly/magnetox-os-update) | OTA update system (engine + bootstrap under `ota/`), patched configs, auto-UUID/manager service |
| `magneto-x-os-mirror/` | [mypeopoly/magneto-x-os-mirror](https://github.com/mypeopoly/magneto-x-os-mirror) | Placeholder repo whose GitHub releases carry the MainsailOS-based OS images (images themselves are **not** in this monorepo) |
| `vlare/` | [mypeopoly/vlare](https://github.com/mypeopoly/vlare) | Placeholder repo whose GitHub releases carry VlareSlicer builds (binaries **not** in this monorepo) |

## OS updates (OTA)

Printers self-update from this repo's **GitHub Releases** via a systemd
service — the old git-clone `update.sh` flow (which pointed at the dead
mypeopoly upstream) is deprecated. The engine does version gating, sha256
verification, pre-apply backups, per-file atomic installs, automatic
rollback and boot-time power-loss recovery; it never touches the
per-printer `printer.cfg`/`magneto_device.cfg`. Which repo a printer pulls
from is configured on-printer in `/home/pi/magneto-ota/ota.conf`.

See [`magnetox-os-update/ota/README.md`](magnetox-os-update/ota/README.md)
for the architecture and the one-time migration steps (both for stock
Peopoly printers and printers already on this repo's config). Releases are
built with `scripts/build-ota-payload.sh` (or automatically on `v*` tags).

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
