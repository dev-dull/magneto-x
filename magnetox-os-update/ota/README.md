# Magneto X OTA update system

The redesigned over-the-air update flow for the Peopoly Magneto X, replacing
the original git-clone based `update.sh` (which pointed at the abandoned
`mypeopoly/magnetox-os-update` repo and had no version gating, no error
checking, no backups, no lock and an unconditional reboot — issues
[#8](https://github.com/dev-dull/magneto-x/issues/8),
[#13](https://github.com/dev-dull/magneto-x/issues/13),
[#14](https://github.com/dev-dull/magneto-x/issues/14),
[#15](https://github.com/dev-dull/magneto-x/issues/15),
[#46](https://github.com/dev-dull/magneto-x/issues/46)).

## Architecture

**Channel** — updates ship as GitHub Release assets on the repo named in
`ota.conf`: `magneto-x-ota-<version>.tar.gz` plus `manifest.json`
(`{version, sha256, requires_reboot, apt_packages, files}`). No git state
lives on the printer; a release artifact is a single, checksummable,
versioned download.

**Execution** — the `magneto-ota.service` systemd oneshot runs
`/home/pi/magneto-ota/ota-update.sh` as root. Gcode never runs the update
in-band: the `UPDATE_MAGNETO_OS` macro just fires
`sudo -n systemctl start --no-block magneto-ota.service` (a 5-second shell
command) and returns, so a slow download or apt transaction can never be
killed by a gcode timeout. The narrow sudoers rule that permits exactly that
one command is installed by the bootstrap.

**Locking** — the authoritative guard is the engine's own
`flock -n /home/pi/magneto-ota/lock`; a second trigger exits "already
running". The oneshot unit (no `RemainAfterExit`) additionally makes a
concurrent `systemctl start` join the active job, and the version gate makes
a re-run after completion a no-op.

**Engine phases** (each writes `/home/pi/magneto-ota/status`, a JSON
`{state, phase, version, error, timestamp}` readable via the `OTA_STATUS`
macro):

1. **preflight** — lock; not-printing check against Moonraker (Moonraker
   unreachable ⇒ abort, unless `OTA_FORCE=1`); disk space; network.
2. **resolve** — read `ota.conf`, query the release API, compare the
   manifest version against `installed-version`. Equal or older ⇒ exit 0
   "up to date" (`OTA_FORCE=1` overrides).
3. **download** — fetch tarball + manifest, verify the tarball's sha256.
4. **stage** — extract to `staging/payload/`; sanity-check the layout;
   reject any manifest path outside the known install roots — and refuse
   outright if the payload names `printer.cfg` or `magneto_device.cfg`
   (per-printer identity is never touched).
5. **backup** — copy every file about to be replaced into
   `backup/<version>-<timestamp>/`, complete **before** the first write.
6. **apply** — per-file atomic install: write `<target>.ota-new` on the
   destination filesystem, fsync, `rename(2)` over the target. Any failure
   ⇒ automatic restore from the phase-5 backup, `state=rolled-back`.
7. **apt** — `apt-get install` of `manifest.apt_packages` (ships empty).
8. **finalize** — record the installed version, install staged systemd
   units, restart magneto-manager → klipper (via Moonraker) → KlipperScreen.
   Reboots **only** if the manifest says `requires_reboot: true`.

**Power-loss recovery** — the backup is complete before apply begins and an
`apply-in-progress` marker brackets the apply phase. At every boot,
`magneto-ota-verify.service` runs `ota-update.sh --verify-or-restore`: if a
run died mid-apply, the printer is rolled back to the backup automatically.
Every renamed file is complete (rename is atomic), so there is no truncated-
config state.

**Self-update** — the payload carries the engine itself under `ota/`. The
engine applies its own files **last** (so a failure on regular files still
leaves a coherent engine to roll back with), and the systemd unit files ride
along as staged copies in `/home/pi/magneto-ota/` which finalize installs
into `/etc/systemd/system/` (with a `daemon-reload`) only when they changed.

## On-printer layout

```
/home/pi/magneto-ota/
├── ota-update.sh        # the engine
├── bootstrap-ota.sh     # migration/installer (idempotent)
├── ota.conf             # which repo/channel to pull from
├── installed-version    # version gate state
├── status               # JSON status for the OTA_STATUS macro
├── staging/             # downloads + extracted payload (transient)
└── backup/              # last 3 pre-update backups
```

## Migrating a printer (one-time)

Two populations exist; **the same bootstrap handles both**:

- **Stock Peopoly config** — the factory `_UPDATE_OS` macros point at the
  dead `mypeopoly` repo and do nothing useful. We cannot push anything to
  those printers; SSH in and run the bootstrap below. The first update it
  triggers replaces `macros.cfg` with this repo's copy (the same file the
  old flow shipped, so no layout surprises), completing the migration.
- **This repo's merged config** — self-update was shipped disabled with a
  warning. Run the same bootstrap; the first update replaces the disabled
  macros with the new `UPDATE_MAGNETO_OS`/`OTA_STATUS` surface.

Recommended (download, inspect, then run — as user `pi` over SSH):

```sh
curl -fsSL -o bootstrap-ota.sh \
  https://raw.githubusercontent.com/dev-dull/magneto-x/main/magnetox-os-update/ota/bootstrap-ota.sh
less bootstrap-ota.sh    # read what it will do
bash bootstrap-ota.sh
```

One-liner for the impatient:

```sh
curl -fsSL https://raw.githubusercontent.com/dev-dull/magneto-x/main/magnetox-os-update/ota/bootstrap-ota.sh | bash
```

The bootstrap is idempotent (safe to re-run). It verifies this is a Magneto X
image, creates `/home/pi/magneto-ota/` with a default `ota.conf`, installs
both systemd units and the sudoers rule, removes the legacy
`/home/pi/magnetox-os-update` clone, and starts the first update.

Root access: when not run as root it uses `echo 'armbian' | sudo -S` —
`armbian` being the stock image's factory sudo password (the same one the
original Peopoly updater hardcoded). If your printer's password differs,
`export SUDO_PASS=yourpassword` first, or run the script as root.

Anyone following the *old* instructions ("clone the repo and run
`update.sh`") gets a deprecation notice from the `update.sh` stub, which
hands off to `ota/bootstrap-ota.sh` when present beside it.

## Day-to-day use

- **Start an update**: run `UPDATE_MAGNETO_OS` from any console (Mainsail,
  KlipperScreen). `_UPDATE_OS` remains as an alias. Refused while printing —
  both by the macro and independently by the engine.
- **Watch it**: `OTA_STATUS` macro, `cat /home/pi/magneto-ota/status`, or
  `sudo journalctl -u magneto-ota -f`.
- **From SSH**: `sudo systemctl start magneto-ota.service`. Force past the
  version gate (or a down Moonraker) with
  `sudo OTA_FORCE=1 /home/pi/magneto-ota/ota-update.sh`.

## Rollback

- Automatic: any apply failure restores the pre-update backup immediately;
  a power loss mid-apply is restored at next boot by
  `magneto-ota-verify.service`.
- Manual: `sudo /home/pi/magneto-ota/ota-update.sh --restore-last` restores
  the most recent backup in `/home/pi/magneto-ota/backup/` (the last three
  are kept), then restart klipper/KlipperScreen or reboot.

## Pointing at a different repo or mirror

Edit `/home/pi/magneto-ota/ota.conf` (see `ota.conf.example`):

- `OTA_REPO="someone/some-fork"` — pull releases from another GitHub repo.
- `OTA_CHANNEL="v1.2.0"` — pin to a specific release tag instead of latest.
- `OTA_BASE_URL="https://updates.example.com/magneto-x"` — a self-hosted
  mirror directory serving `manifest.json` and
  `magneto-x-ota-<version>.tar.gz`; GitHub is then not contacted at all.

No reflash or re-bootstrap is needed to move channels — that is the point.

## Building a release (maintainers)

```sh
scripts/build-ota-payload.sh v1.2.0
gh release create v1.2.0 dist/magneto-x-ota-v1.2.0.tar.gz dist/manifest.json \
    --repo dev-dull/magneto-x --title 'Magneto X OTA v1.2.0' --generate-notes
```

Config files are sourced from `magneto-x-klipper-config/config/` (the
canonical copy per issue #9); the build refuses to run if the vendored
`magnetox-os-update/config/` copy has drifted. Pushing a `v*` tag runs the
same build automatically via `.github/workflows/release-ota.yml`.
`moonraker.conf` is deliberately not shipped: wholesale-overwriting user
Moonraker customizations was defect #14(3).
