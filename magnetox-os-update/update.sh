#!/bin/bash
# DEPRECATED — this git-clone based update flow has been replaced.
#
# The Magneto X OTA update now runs from GitHub Releases via a systemd
# service, with version gating, checksums, backups, atomic installs and
# rollback. See magnetox-os-update/ota/README.md.
#
# Anyone following old instructions ("clone and run update.sh") lands here;
# hand them off to the new bootstrap when it is available beside this stub.

set -u

echo "=============================================================="
echo " update.sh is DEPRECATED."
echo ""
echo " The Magneto X OTA update has been redesigned. It now installs"
echo " from GitHub Releases via a systemd service (magneto-ota) with"
echo " version gating, checksums, backups and rollback."
echo ""
echo " Documentation: magnetox-os-update/ota/README.md"
echo " (https://github.com/dev-dull/magneto-x)"
echo "=============================================================="

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/ota/bootstrap-ota.sh" ]; then
    echo ""
    echo " Handing off to the new bootstrap: $SCRIPT_DIR/ota/bootstrap-ota.sh"
    echo ""
    exec bash "$SCRIPT_DIR/ota/bootstrap-ota.sh"
fi

echo ""
echo " To migrate this printer, run the new bootstrap:"
echo "   curl -fsSL -o bootstrap-ota.sh https://raw.githubusercontent.com/dev-dull/magneto-x/main/magnetox-os-update/ota/bootstrap-ota.sh"
echo "   less bootstrap-ota.sh   # inspect it"
echo "   bash bootstrap-ota.sh"
exit 1
