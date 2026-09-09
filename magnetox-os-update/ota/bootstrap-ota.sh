#!/bin/bash
# bootstrap-ota.sh — one-time (idempotent) migration of a Magneto X printer
# onto the new OTA update flow. See magnetox-os-update/ota/README.md in
# https://github.com/dev-dull/magneto-x for the full story.
#
# Run as the pi user over SSH:
#   bash bootstrap-ota.sh
# Works both as a standalone download (fetches the engine from GitHub) and
# from a checkout of the repo (uses the files sitting next to it).
#
# Root access: the stock Magneto X image ships user pi with sudo password
# "armbian" (that is the image's factory default, hardcoded by the original
# Peopoly updater). When not already root, this script pipes that password
# via `sudo -S`; if your printer uses a different password, export
# SUDO_PASS=yourpassword before running (or run the script as root).
#
# Environment:
#   OTA_REPO   override the repo written to ota.conf and used for the
#              standalone download (default dev-dull/magneto-x)
#   SUDO_PASS  sudo password when not running as root (default "armbian")

set -euo pipefail

OTA_HOME="/home/pi/magneto-ota"
OTA_REPO_DEFAULT="${OTA_REPO:-dev-dull/magneto-x}"
RAW_BASE="https://raw.githubusercontent.com/${OTA_REPO_DEFAULT}/main/magnetox-os-update/ota"
LEGACY_CLONE="/home/pi/magnetox-os-update"
SUDOERS_FILE="/etc/sudoers.d/magneto-ota"

ENGINE_FILES=(ota-update.sh magneto-ota.service magneto-ota-verify.service ota.conf.example bootstrap-ota.sh)

log() { echo "[bootstrap-ota] $*"; }
die() { echo "[bootstrap-ota] ERROR: $*" >&2; exit 1; }

# --- root helper -----------------------------------------------------------
# Runs a command as root. Only pipes the password when we are NOT already
# root; "armbian" is the stock image's factory sudo password (see header).
as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        echo "${SUDO_PASS:-armbian}" | sudo -S -p "" "$@"
    fi
}

# --- sanity: is this a Magneto X image? ------------------------------------
[ -d /home/pi/printer_data/config ] || \
    die "/home/pi/printer_data/config not found — this does not look like a Magneto X printer image"
[ -d /home/pi/auto-uuid ] || [ -d /home/pi/KlipperScreen ] || \
    die "neither /home/pi/auto-uuid nor /home/pi/KlipperScreen found — this does not look like a Magneto X printer image"

command -v jq >/dev/null 2>&1 || die "jq is required but not installed (it ships on the stock image)"
command -v curl >/dev/null 2>&1 || die "curl is required but not installed"

if [ "$(id -u)" -ne 0 ]; then
    log "verifying sudo access (stock password unless SUDO_PASS is set)..."
    as_root true || die "sudo failed — export SUDO_PASS=<your password> and re-run"
fi

# --- lay down the OTA home -------------------------------------------------
log "creating $OTA_HOME"
mkdir -p "$OTA_HOME/staging" "$OTA_HOME/backup"

# Where do the engine files come from? A repo checkout beside this script,
# or a fresh download from GitHub (standalone bootstrap).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "$SCRIPT_DIR" = "$OTA_HOME" ]; then
    log "running from $OTA_HOME itself — engine files already in place"
elif [ -f "$SCRIPT_DIR/ota-update.sh" ]; then
    log "installing engine from local checkout ($SCRIPT_DIR)"
    for f in "${ENGINE_FILES[@]}"; do
        cp "$SCRIPT_DIR/$f" "$OTA_HOME/$f"
    done
else
    log "downloading engine from $RAW_BASE"
    for f in "${ENGINE_FILES[@]}"; do
        curl -fsSL --max-time 60 -o "$OTA_HOME/$f.tmp" "$RAW_BASE/$f" || \
            die "failed to download $f from $RAW_BASE"
        mv -f "$OTA_HOME/$f.tmp" "$OTA_HOME/$f"
    done
fi
chmod +x "$OTA_HOME/ota-update.sh" "$OTA_HOME/bootstrap-ota.sh"

# --- default config (kept if it already exists: idempotent) ----------------
if [ ! -f "$OTA_HOME/ota.conf" ]; then
    log "writing default ota.conf (repo: $OTA_REPO_DEFAULT)"
    cat > "$OTA_HOME/ota.conf" <<EOF
# Magneto X OTA configuration — see ota.conf.example for all options.
OTA_REPO="$OTA_REPO_DEFAULT"
OTA_CHANNEL="latest"
EOF
else
    log "ota.conf already exists — leaving it alone"
fi

# --- systemd units ---------------------------------------------------------
log "installing systemd units"
as_root cp "$OTA_HOME/magneto-ota.service" /etc/systemd/system/magneto-ota.service
as_root cp "$OTA_HOME/magneto-ota-verify.service" /etc/systemd/system/magneto-ota-verify.service
as_root systemctl daemon-reload
as_root systemctl enable magneto-ota-verify.service

# --- sudoers rule so the gcode macro (user pi) can start the update --------
# Scoped to exactly the one systemctl invocation the OTA_TRIGGER
# gcode_shell_command issues.
log "installing sudoers rule for the OTA trigger macro"
SUDOERS_TMP="$(mktemp)"
cat > "$SUDOERS_TMP" <<'EOF'
# Installed by magneto-x bootstrap-ota.sh: lets the klipper user's
# OTA_TRIGGER gcode_shell_command start an OTA run without a password.
pi ALL=(root) NOPASSWD: /usr/bin/systemctl start --no-block magneto-ota.service
pi ALL=(root) NOPASSWD: /bin/systemctl start --no-block magneto-ota.service
EOF
if as_root visudo -c -f "$SUDOERS_TMP" >/dev/null; then
    as_root install -m 0440 -o root -g root "$SUDOERS_TMP" "$SUDOERS_FILE"
else
    rm -f "$SUDOERS_TMP"
    die "generated sudoers rule failed visudo validation — not installed"
fi
rm -f "$SUDOERS_TMP"

# --- remove the legacy update clone ----------------------------------------
# The old flow's working directory (git clone of the dead mypeopoly repo, or
# of this repo via the old placeholder macros). The new flow keeps no git
# state on the printer.
if [ -d "$LEGACY_CLONE" ]; then
    log "removing legacy update clone $LEGACY_CLONE"
    rm -rf "$LEGACY_CLONE" 2>/dev/null || as_root rm -rf "$LEGACY_CLONE"
fi

# --- first update ----------------------------------------------------------
log "bootstrap complete — starting the first update (this delivers the new"
log "config, including the new UPDATE_MAGNETO_OS / OTA_STATUS macros)"
if as_root systemctl start magneto-ota.service; then
    log "first update finished:"
else
    log "first update FAILED — details follow (also: sudo journalctl -u magneto-ota):"
fi
cat "$OTA_HOME/status" 2>/dev/null || true
echo
log "done. Future updates: run UPDATE_MAGNETO_OS from the printer console,"
log "or 'sudo systemctl start magneto-ota.service' over SSH."
log "Follow progress with the OTA_STATUS macro or 'cat $OTA_HOME/status'."
