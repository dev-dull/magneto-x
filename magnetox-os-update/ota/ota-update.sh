#!/bin/bash
# ota-update.sh — Magneto X OTA update engine.
#
# Replaces the old git-clone based magnetox-os-update/update.sh flow
# (dev-dull/magneto-x issues #13, #14, #15, #46, #8).
#
# Runs as root via magneto-ota.service (systemd oneshot); never in-band
# in a gcode_shell_command, so package installs can never be killed by a
# gcode timeout. The AUTHORITATIVE concurrency guard is the flock below.
#
# Modes:
#   ota-update.sh                    run an update (default)
#   ota-update.sh --restore-last     restore the most recent backup
#   ota-update.sh --verify-or-restore
#                                    boot-time check: if a previous run
#                                    died mid-apply, roll it back
#
# Environment:
#   OTA_FORCE=1   skip the version gate and the "Moonraker unreachable"
#                 abort (NOT the "currently printing" abort).
#
# Configuration: /home/pi/magneto-ota/ota.conf (see ota.conf.example).
# Status:        /home/pi/magneto-ota/status (JSON: state/phase/version/
#                error/timestamp) — surfaced by the OTA_STATUS macro.

set -euo pipefail
set -E  # ERR trap fires inside functions/subshells too

# --------------------------------------------------------------------------
# Layout and defaults
# --------------------------------------------------------------------------
OTA_HOME="/home/pi/magneto-ota"
OTA_CONF="$OTA_HOME/ota.conf"
STATUS_FILE="$OTA_HOME/status"
INSTALLED_VERSION_FILE="$OTA_HOME/installed-version"
LOCK_FILE="$OTA_HOME/lock"
STAGING_DIR="$OTA_HOME/staging"
BACKUP_ROOT="$OTA_HOME/backup"
LAST_BACKUP_FILE="$OTA_HOME/last-backup"
APPLY_MARKER="$OTA_HOME/apply-in-progress"

# Defaults — overridable by ota.conf (R2: nothing hardcoded to any upstream
# that a config edit cannot repoint).
OTA_REPO="dev-dull/magneto-x"
OTA_CHANNEL="latest"
OTA_BASE_URL=""

# Install destinations, keyed by payload top-level directory (dest_for()).
DEST_CONFIG="/home/pi/printer_data/config"
DEST_AUTO_UUID="/home/pi/auto-uuid"
DEST_KS_PANELS="/home/pi/KlipperScreen/panels"
DEST_OTA="$OTA_HOME"

# Files the engine must NEVER install: per-printer identity. Enforced as a
# hard denylist on the payload file list before anything is written.
DENYLIST_BASENAMES=("printer.cfg" "magneto_device.cfg")

MOONRAKER_URL="http://localhost:7125"
MIN_FREE_KB=204800          # 200 MB free on /home before we start
BACKUPS_TO_KEEP=3

CURRENT_PHASE="startup"
TARGET_VERSION=""

# --------------------------------------------------------------------------
# Status + error helpers
# --------------------------------------------------------------------------
write_status() {
    # write_status <state> <error-text-or-empty>
    local state="$1" error="${2:-}" tmp="$STATUS_FILE.tmp"
    jq -n \
        --arg state "$state" \
        --arg phase "$CURRENT_PHASE" \
        --arg version "${TARGET_VERSION:-}" \
        --arg error "$error" \
        --arg timestamp "$(date -Is)" \
        '{state: $state, phase: $phase, version: $version,
          error: $error, timestamp: $timestamp}' > "$tmp"
    mv -f "$tmp" "$STATUS_FILE"
    chmod 644 "$STATUS_FILE" 2>/dev/null || true
}

log() { echo "[ota] $*"; }

die() {
    local msg="$*"
    echo "[ota] ERROR: $msg" >&2
    trap - ERR
    write_status "failed" "$msg"
    exit 1
}

on_err() {
    local line="$1"
    trap - ERR
    write_status "failed" "unexpected error in phase '$CURRENT_PHASE' (line $line)"
    echo "[ota] ERROR: unexpected failure in phase '$CURRENT_PHASE' (line $line)" >&2
    exit 1
}
trap 'on_err $LINENO' ERR

phase() {
    CURRENT_PHASE="$1"
    write_status "running" ""
    log "phase: $CURRENT_PHASE"
}

# --------------------------------------------------------------------------
# Shared helpers
# --------------------------------------------------------------------------
require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "[ota] must run as root — use 'sudo systemctl start magneto-ota.service'" >&2
        echo "[ota] (or 'sudo $0' for a foreground run)" >&2
        exit 1
    fi
}

take_lock() {
    mkdir -p "$OTA_HOME"
    exec {LOCK_FD}>"$LOCK_FILE"
    if ! flock -n "$LOCK_FD"; then
        # Another run holds the lock: do NOT touch its status file.
        echo "[ota] another OTA run is already in progress — exiting." >&2
        exit 1
    fi
}

# Map a payload-relative path to its absolute install destination.
# Payload layout (produced by scripts/build-ota-payload.sh):
#   config/...        -> /home/pi/printer_data/config/...
#   auto-uuid/...     -> /home/pi/auto-uuid/...
#   KlipperScreen/... -> /home/pi/KlipperScreen/panels/...
#   ota/...           -> /home/pi/magneto-ota/...  (the engine updates itself;
#                        applied LAST — systemd units land here as a staged
#                        copy and are installed to /etc/systemd/system in
#                        finalize, see README.md)
dest_for() {
    local rel="$1"
    case "$rel" in
        config/*)        echo "$DEST_CONFIG/${rel#config/}" ;;
        auto-uuid/*)     echo "$DEST_AUTO_UUID/${rel#auto-uuid/}" ;;
        KlipperScreen/*) echo "$DEST_KS_PANELS/${rel#KlipperScreen/}" ;;
        ota/*)           echo "$DEST_OTA/${rel#ota/}" ;;
        *)               return 1 ;;
    esac
}

# Reject absolute paths, parent-directory escapes, and the identity denylist.
validate_file_list() {
    local rel base deny
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        case "$rel" in
            /*)          die "manifest contains absolute path: $rel" ;;
            *../*|*/..|..) die "manifest contains path escape: $rel" ;;
        esac
        base="$(basename "$rel")"
        for deny in "${DENYLIST_BASENAMES[@]}"; do
            if [ "$base" = "$deny" ]; then
                die "manifest contains denylisted per-printer file: $rel — refusing to continue"
            fi
        done
        if ! dest_for "$rel" >/dev/null; then
            die "manifest contains path outside known install roots: $rel"
        fi
    done
}

# Atomically install <src> as <dest>: copy to <dest>.ota-new on the
# destination filesystem, fsync it, then rename(2) over the target.
# A power cut can at worst lose a not-yet-renamed file; every renamed
# file is complete, never truncated.
atomic_install() {
    local src="$1" dest="$2" tmp
    tmp="$dest.ota-new"
    mkdir -p "$(dirname "$dest")" || return 1
    cp -p "$src" "$tmp" || return 1
    case "$dest" in
        /home/pi/*) chown pi:pi "$tmp" 2>/dev/null || true ;;
    esac
    sync "$tmp" || return 1
    mv -f "$tmp" "$dest" || return 1
}

# Restore every file recorded in a backup directory (and delete files that
# were newly introduced by the failed update). Refuses to act on a backup
# that never finished being taken.
restore_from_backup() {
    local backup_dir="$1" rel dest src
    [ -d "$backup_dir" ] || die "backup directory not found: $backup_dir"
    [ -f "$backup_dir/.backup-complete" ] || \
        die "backup at $backup_dir is incomplete — refusing to restore from it"

    log "restoring from backup: $backup_dir"
    # Files that existed before the update: put the old content back.
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        src="$backup_dir/files/$rel"
        dest="$(dest_for "$rel")" || die "unmappable path in backup: $rel"
        atomic_install "$src" "$dest" || die "failed restoring $rel"
    done < <(cd "$backup_dir/files" 2>/dev/null && find . -type f | sed 's|^\./||' || true)

    # Files the update newly created (nothing to restore): remove them.
    if [ -f "$backup_dir/new-files.list" ]; then
        while IFS= read -r rel; do
            [ -n "$rel" ] || continue
            dest="$(dest_for "$rel")" || continue
            rm -f "$dest"
        done < "$backup_dir/new-files.list"
    fi
    sync
    log "restore complete"
}

prune_backups() {
    local dir count=0
    while IFS= read -r dir; do
        count=$((count + 1))
        if [ "$count" -gt "$BACKUPS_TO_KEEP" ]; then
            log "pruning old backup: $dir"
            rm -rf "${BACKUP_ROOT:?}/${dir:?}"
        fi
    done < <(ls -1t "$BACKUP_ROOT" 2>/dev/null || true)
}

# --------------------------------------------------------------------------
# Alternate modes
# --------------------------------------------------------------------------
mode_restore_last() {
    require_root
    take_lock
    CURRENT_PHASE="restore-last"
    local backup_dir
    backup_dir="$(cat "$LAST_BACKUP_FILE" 2>/dev/null || true)"
    [ -n "$backup_dir" ] || die "no backup on record (nothing in $LAST_BACKUP_FILE)"
    restore_from_backup "$backup_dir"
    rm -f "$APPLY_MARKER"
    write_status "restored" ""
    log "restored files from $backup_dir"
    log "restart klipper (and KlipperScreen) or reboot to pick the restored files up"
}

mode_verify_or_restore() {
    require_root
    take_lock
    CURRENT_PHASE="verify"
    if [ ! -f "$APPLY_MARKER" ]; then
        log "no interrupted update found — nothing to do"
        exit 0
    fi
    local backup_dir
    backup_dir="$(cat "$APPLY_MARKER")"
    log "previous update was interrupted mid-apply (power loss?) — rolling back"
    restore_from_backup "$backup_dir"
    rm -f "$APPLY_MARKER"
    write_status "restored" "previous update interrupted mid-apply; rolled back at boot"
}

# --------------------------------------------------------------------------
# Update phases
# --------------------------------------------------------------------------
phase_preflight() {
    phase "preflight"

    # Not-printing guard. The trigger macro checks idle_timeout too; this is
    # the belt-and-braces check because the engine can also be started
    # manually over SSH.
    local resp state
    if resp="$(curl -fsS --max-time 10 \
            "$MOONRAKER_URL/printer/objects/query?print_stats" 2>/dev/null)"; then
        state="$(jq -r '.result.status.print_stats.state // empty' <<<"$resp")"
        case "$state" in
            printing|paused)
                die "printer is ${state} — refusing to update mid-print" ;;
            standby|complete|error|cancelled)
                log "print_stats.state=$state — ok to update" ;;
            *)
                # Moonraker is up but klipper isn't ready: physically not
                # printing, so proceed (this is exactly the state a broken
                # config update needs to be able to fix).
                log "klipper not ready (print_stats.state='$state') — proceeding" ;;
        esac
    else
        if [ "${OTA_FORCE:-0}" = "1" ]; then
            log "WARNING: Moonraker unreachable; proceeding because OTA_FORCE=1"
        else
            die "Moonraker unreachable — cannot verify the printer is not printing. Retry when Moonraker is up, or set OTA_FORCE=1 to override."
        fi
    fi

    # Disk space on /home.
    local free_kb
    free_kb="$(df --output=avail -k /home | tail -1 | tr -d ' ')"
    if [ "$free_kb" -lt "$MIN_FREE_KB" ]; then
        die "not enough free space on /home (${free_kb} KB free, need ${MIN_FREE_KB} KB)"
    fi

    # Network reachability (cheap check; resolve gives the real error detail).
    local probe_url="https://api.github.com"
    if [ -n "$OTA_BASE_URL" ]; then
        probe_url="${OTA_BASE_URL%/}/manifest.json"
    fi
    if ! curl -fsI --max-time 15 "$probe_url" >/dev/null 2>&1; then
        die "network check failed (cannot reach $probe_url) — check connectivity and try again"
    fi
}

phase_resolve() {
    phase "resolve"
    mkdir -p "$STAGING_DIR"
    rm -rf "${STAGING_DIR:?}"/*

    if [ -n "$OTA_BASE_URL" ]; then
        # Fully self-hosted mirror: a directory serving manifest.json and the
        # tarball it names.
        MANIFEST_URL="${OTA_BASE_URL%/}/manifest.json"
        TARBALL_URL=""   # derived from the manifest version below
    else
        local api_url release_json
        if [ "$OTA_CHANNEL" = "latest" ]; then
            api_url="https://api.github.com/repos/$OTA_REPO/releases/latest"
        else
            api_url="https://api.github.com/repos/$OTA_REPO/releases/tags/$OTA_CHANNEL"
        fi
        if ! release_json="$(curl -fsS --max-time 30 \
                -H "Accept: application/vnd.github+json" "$api_url")"; then
            die "could not query $api_url (no such release, network error, or GitHub API rate limit) — try again later"
        fi
        MANIFEST_URL="$(jq -r '.assets[] | select(.name == "manifest.json") | .browser_download_url' <<<"$release_json")"
        TARBALL_URL="$(jq -r '.assets[] | select(.name | startswith("magneto-x-ota-") and endswith(".tar.gz")) | .browser_download_url' <<<"$release_json" | head -1)"
        [ -n "$MANIFEST_URL" ] || die "release has no manifest.json asset"
        [ -n "$TARBALL_URL" ] || die "release has no magneto-x-ota-*.tar.gz asset"
    fi

    MANIFEST="$STAGING_DIR/manifest.json"
    curl -fsSL --max-time 60 -o "$MANIFEST" "$MANIFEST_URL" || \
        die "failed to download manifest from $MANIFEST_URL"
    jq -e '.version and .sha256 and (.files | length > 0)' "$MANIFEST" >/dev/null 2>&1 || \
        die "manifest is malformed (need version, sha256, files[])"

    TARGET_VERSION="$(jq -r '.version' "$MANIFEST")"
    if [ -n "$OTA_BASE_URL" ]; then
        TARBALL_URL="${OTA_BASE_URL%/}/magneto-x-ota-${TARGET_VERSION}.tar.gz"
    fi

    # Version gate (#13: a real one this time).
    local installed
    installed="$(cat "$INSTALLED_VERSION_FILE" 2>/dev/null || echo "")"
    log "installed version: ${installed:-<none>}; available: $TARGET_VERSION"
    if [ "${OTA_FORCE:-0}" != "1" ] && [ -n "$installed" ]; then
        if [ "$installed" = "$TARGET_VERSION" ]; then
            write_status "up-to-date" ""
            log "already up to date ($installed) — nothing to do"
            exit 0
        fi
        local newest
        newest="$(printf '%s\n%s\n' "$installed" "$TARGET_VERSION" | sort -V | tail -1)"
        if [ "$newest" = "$installed" ]; then
            write_status "up-to-date" ""
            log "installed version $installed is newer than available $TARGET_VERSION — nothing to do (OTA_FORCE=1 to downgrade)"
            exit 0
        fi
    fi
}

phase_download() {
    phase "download"
    TARBALL="$STAGING_DIR/magneto-x-ota-${TARGET_VERSION}.tar.gz"
    curl -fsSL --max-time 600 -o "$TARBALL" "$TARBALL_URL" || \
        die "failed to download payload from $TARBALL_URL"

    # Integrity (#14): checksum before anything is touched.
    local want got
    want="$(jq -r '.sha256' "$MANIFEST")"
    got="$(sha256sum "$TARBALL" | awk '{print $1}')"
    if [ "$want" != "$got" ]; then
        die "payload checksum mismatch (expected $want, got $got) — download corrupt, aborting"
    fi
    log "payload sha256 verified"
}

phase_stage() {
    phase "stage"
    PAYLOAD_DIR="$STAGING_DIR/payload"
    mkdir -p "$PAYLOAD_DIR"
    tar -xzf "$TARBALL" -C "$PAYLOAD_DIR" || die "failed to extract payload"

    # Sanity: only known top-level dirs, and every manifest file present.
    local top
    while IFS= read -r top; do
        case "$top" in
            config|auto-uuid|KlipperScreen|ota) ;;
            *) die "payload contains unexpected top-level entry: $top" ;;
        esac
    done < <(ls -1 "$PAYLOAD_DIR")

    # Denylist / path-safety check on the manifest file list (#14, identity
    # preservation): printer.cfg and magneto_device.cfg must never ship.
    # (Process substitution, not a pipe: die() must exit the main shell.)
    validate_file_list < <(jq -r '.files[]' "$MANIFEST")

    local rel
    while IFS= read -r rel; do
        [ -f "$PAYLOAD_DIR/$rel" ] || die "manifest lists $rel but it is missing from the payload"
    done < <(jq -r '.files[]' "$MANIFEST")
}

phase_backup() {
    phase "backup"
    local stamp rel dest
    stamp="$(date +%Y%m%d-%H%M%S)"
    BACKUP_DIR="$BACKUP_ROOT/${TARGET_VERSION}-${stamp}"
    mkdir -p "$BACKUP_DIR/files"
    : > "$BACKUP_DIR/new-files.list"

    while IFS= read -r rel; do
        dest="$(dest_for "$rel")"
        if [ -f "$dest" ]; then
            mkdir -p "$BACKUP_DIR/files/$(dirname "$rel")"
            cp -p "$dest" "$BACKUP_DIR/files/$rel" || die "failed backing up $dest"
        else
            echo "$rel" >> "$BACKUP_DIR/new-files.list"
        fi
    done < <(jq -r '.files[]' "$MANIFEST")

    cp "$MANIFEST" "$BACKUP_DIR/manifest.json"
    touch "$BACKUP_DIR/.backup-complete"
    sync
    echo "$BACKUP_DIR" > "$LAST_BACKUP_FILE"
    log "backup complete: $BACKUP_DIR"
}

apply_one() {
    # Runs with errexit suppressed by the caller's `if !` — every step
    # carries its own `|| return 1`.
    local rel="$1" dest
    dest="$(dest_for "$rel")" || return 1
    atomic_install "$PAYLOAD_DIR/$rel" "$dest" || return 1
}

phase_apply() {
    phase "apply"
    # The marker lets the boot-time verify unit detect a run that died
    # mid-apply (power loss) and roll back automatically.
    echo "$BACKUP_DIR" > "$APPLY_MARKER"
    sync "$APPLY_MARKER"

    # Apply order: everything else first, the engine's own files (ota/*)
    # LAST — so a failure applying regular files still leaves a coherent
    # engine to run the rollback.
    local rel
    while IFS= read -r rel; do
        if ! apply_one "$rel"; then
            log "apply FAILED at $rel — rolling back"
            CURRENT_PHASE="rollback"
            restore_from_backup "$BACKUP_DIR"
            rm -f "$APPLY_MARKER"
            trap - ERR
            write_status "rolled-back" "apply failed at $rel; previous files restored"
            exit 1
        fi
    done < <({ jq -r '.files[]' "$MANIFEST" | grep -v '^ota/' || true;
               jq -r '.files[]' "$MANIFEST" | grep '^ota/' || true; })

    chmod +x "$OTA_HOME/ota-update.sh" "$OTA_HOME/bootstrap-ota.sh" 2>/dev/null || true
    rm -f "$APPLY_MARKER"
    sync
    log "all files applied"
}

phase_apt() {
    local pkgs
    pkgs="$(jq -r '.apt_packages // [] | join(" ")' "$MANIFEST")"
    [ -n "$pkgs" ] || return 0
    phase "apt"
    # Under systemd, as root: immune to gcode timeouts (#15).
    export DEBIAN_FRONTEND=noninteractive
    apt-get update || die "apt-get update failed"
    # shellcheck disable=SC2086  # intentional word splitting of package list
    apt-get install -y $pkgs || die "apt-get install failed ($pkgs)"
}

phase_finalize() {
    phase "finalize"
    echo "$TARGET_VERSION" > "$INSTALLED_VERSION_FILE"
    sync "$INSTALLED_VERSION_FILE"

    # Install staged systemd units if they changed (engine self-update path:
    # units ride in the payload under ota/, land in $OTA_HOME during apply,
    # and are copied into /etc/systemd/system here).
    local unit changed=0
    for unit in magneto-ota.service magneto-ota-verify.service; do
        if [ -f "$OTA_HOME/$unit" ] && \
           ! cmp -s "$OTA_HOME/$unit" "/etc/systemd/system/$unit"; then
            cp "$OTA_HOME/$unit" "/etc/systemd/system/$unit"
            changed=1
        fi
    done
    if [ "$changed" -eq 1 ]; then
        systemctl daemon-reload
    fi

    prune_backups
    rm -rf "${STAGING_DIR:?}"/*

    if [ "$(jq -r '.requires_reboot // false' "$MANIFEST")" = "true" ]; then
        write_status "success" ""
        log "update to $TARGET_VERSION applied; manifest requires a reboot — rebooting"
        systemctl reboot
        return 0
    fi

    # Restart services in dependency order; each is best-effort so a missing
    # unit on an unusual image does not fail an otherwise-complete update.
    log "restarting services"
    if systemctl list-unit-files 2>/dev/null | grep -q '^magneto-manager\.service'; then
        systemctl restart magneto-manager.service || \
            log "WARNING: magneto-manager restart failed"
    else
        log "no magneto-manager.service unit — skipping (changes apply on next reboot)"
    fi
    curl -fsS --max-time 30 -X POST \
        "$MOONRAKER_URL/machine/services/restart?service=klipper" >/dev/null 2>&1 || \
        log "WARNING: klipper restart via Moonraker failed — restart it manually (FIRMWARE_RESTART or reboot)"
    systemctl restart KlipperScreen.service 2>/dev/null || \
        log "WARNING: KlipperScreen restart failed or unit absent"

    write_status "success" ""
    log "update to $TARGET_VERSION complete"
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------
main() {
    case "${1:-}" in
        --restore-last)      mode_restore_last; exit 0 ;;
        --verify-or-restore) mode_verify_or_restore; exit 0 ;;
        "") ;;
        *) echo "usage: $0 [--restore-last|--verify-or-restore]" >&2; exit 2 ;;
    esac

    require_root
    take_lock

    if [ -f "$OTA_CONF" ]; then
        # shellcheck source=/dev/null
        . "$OTA_CONF"
    fi
    mkdir -p "$STAGING_DIR" "$BACKUP_ROOT"

    phase_preflight
    phase_resolve
    phase_download
    phase_stage
    phase_backup
    phase_apply
    phase_apt
    phase_finalize
}

main "$@"
