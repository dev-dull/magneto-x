#!/bin/bash
# build-ota-payload.sh — assemble a Magneto X OTA release payload.
#
# Usage:
#   scripts/build-ota-payload.sh v1.2.0
#
# Produces in dist/:
#   magneto-x-ota-<version>.tar.gz
#   manifest.json   {version, sha256, requires_reboot, apt_packages, files}
# and prints the `gh release create` command to publish them.
#
# Sources (per issue #9): shared config comes from the CANONICAL copy,
# magneto-x-klipper-config/config/. The build REFUSES to run if the
# canonical and vendored (magnetox-os-update/config/) copies have drifted —
# mechanically enforcing #9's "every shared-config change lands in both
# directories in the same commit" rule until the vendored copy is retired.
#
# printer.cfg and magneto_device.cfg are per-printer identity and are never
# part of the payload (the on-printer engine additionally denylists them).

set -euo pipefail

usage() { echo "usage: $0 <version, e.g. v1.2.0>" >&2; exit 2; }

VERSION="${1:-}"
[ -n "$VERSION" ] || usage
case "$VERSION" in
    v[0-9]*) ;;
    *) echo "ERROR: version should look like v1.2.0 (got: $VERSION)" >&2; exit 2 ;;
esac

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CANONICAL="$REPO_ROOT/magneto-x-klipper-config/config"
VENDORED="$REPO_ROOT/magnetox-os-update/config"
OSUPDATE="$REPO_ROOT/magnetox-os-update"
DIST="$REPO_ROOT/dist"

# --- drift check (issue #9) -------------------------------------------------
# "vendored-file:canonical-counterpart" pairs (plain list: portable to the
# bash 3.2 found on macOS dev machines, which lacks associative arrays).
DRIFT_PAIRS="
macros.cfg:macros.cfg
magneto_toolhead.cfg:magneto_toolhead.cfg
Line_Purge.cfg:KAMP/Line_Purge.cfg
"
drift=0
for pair in $DRIFT_PAIRS; do
    vfile="${pair%%:*}"
    cfile="${pair#*:}"
    if [ -f "$VENDORED/$vfile" ] && ! cmp -s "$VENDORED/$vfile" "$CANONICAL/$cfile"; then
        echo "ERROR: config drift: $VENDORED/$vfile != $CANONICAL/$cfile" >&2
        drift=1
    fi
done
if [ "$drift" -ne 0 ]; then
    echo "Refusing to build: the canonical and vendored config copies have" >&2
    echo "diverged (issue #9 requires them to change together). Reconcile" >&2
    echo "them first." >&2
    exit 1
fi

# --- assemble payload -------------------------------------------------------
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
PAYLOAD="$STAGE/payload"
mkdir -p "$PAYLOAD/config/KAMP" "$PAYLOAD/auto-uuid" "$PAYLOAD/KlipperScreen" "$PAYLOAD/ota"

# Shared config, from the canonical tree. Explicit file list — never a
# glob that could sweep in printer.cfg / magneto_device.cfg (#14 lesson).
cp "$CANONICAL/macros.cfg"            "$PAYLOAD/config/macros.cfg"
cp "$CANONICAL/magneto_toolhead.cfg"  "$PAYLOAD/config/magneto_toolhead.cfg"
cp "$CANONICAL/KAMP/Line_Purge.cfg"   "$PAYLOAD/config/KAMP/Line_Purge.cfg"

# auto-uuid service and KlipperScreen panels, as merged in this repo.
cp -p "$OSUPDATE/auto-uuid/"* "$PAYLOAD/auto-uuid/"
cp -p "$OSUPDATE/KlipperScreen/"* "$PAYLOAD/KlipperScreen/"

# The OTA engine itself — so updates can update the updater. The on-printer
# engine applies ota/* files LAST, and installs the systemd units from the
# staged copies in finalize (see ota/README.md).
cp -p "$OSUPDATE/ota/ota-update.sh" \
      "$OSUPDATE/ota/bootstrap-ota.sh" \
      "$OSUPDATE/ota/magneto-ota.service" \
      "$OSUPDATE/ota/magneto-ota-verify.service" \
      "$OSUPDATE/ota/ota.conf.example" \
      "$OSUPDATE/ota/README.md" \
      "$PAYLOAD/ota/"
chmod +x "$PAYLOAD/ota/ota-update.sh" "$PAYLOAD/ota/bootstrap-ota.sh" \
         "$PAYLOAD/auto-uuid/"*.sh "$PAYLOAD/auto-uuid/Magmotor" \
         "$PAYLOAD/auto-uuid/MagnetoWifiHelper" 2>/dev/null || true

# Safety: the identity denylist, enforced at build time too.
for deny in printer.cfg magneto_device.cfg; do
    if find "$PAYLOAD" -name "$deny" | grep -q .; then
        echo "ERROR: payload contains denylisted per-printer file: $deny" >&2
        exit 1
    fi
done

# --- tarball + manifest -----------------------------------------------------
mkdir -p "$DIST"
TARBALL="$DIST/magneto-x-ota-${VERSION}.tar.gz"
# Contents rooted at the payload top level.
tar -czf "$TARBALL" -C "$PAYLOAD" config auto-uuid KlipperScreen ota

SHA256="$(sha256sum "$TARBALL" | awk '{print $1}')"
FILES_JSON="$(cd "$PAYLOAD" && find . -type f | sed 's|^\./||' | LC_ALL=C sort | jq -R . | jq -s .)"

jq -n \
    --arg version "$VERSION" \
    --arg sha256 "$SHA256" \
    --argjson files "$FILES_JSON" \
    '{version: $version, sha256: $sha256, requires_reboot: false,
      apt_packages: [], files: $files}' > "$DIST/manifest.json"

echo "Built:"
echo "  $TARBALL"
echo "  $DIST/manifest.json"
echo "  sha256: $SHA256"
echo
echo "To publish:"
echo "  gh release create '$VERSION' '$TARBALL' '$DIST/manifest.json' \\"
echo "      --repo dev-dull/magneto-x --title 'Magneto X OTA $VERSION' --generate-notes"
