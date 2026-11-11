#!/bin/bash
#
# IruPulse — IruPulse_Uninstall.sh
#
# Removes the IruPulse collector, LaunchDaemon, and local state.
# Run as root (Kandji Custom Script or `sudo`). Idempotent.
#
# NOTE: this does not remove the com.iru.pulse Config Profile — unassign that
# in your MDM. To pause collection without uninstalling, set Enabled=false in
# the profile instead of running this.

set -u

DAEMON_LABEL="com.iru.pulse.daemon"
DAEMON_PLIST="/Library/LaunchDaemons/${DAEMON_LABEL}.plist"
INSTALL_DIR="/usr/local/iru-pulse"
STATE_DIR="/var/db/iru-pulse"
LOG_FILE="/var/log/iru-pulse.log"

if [ "$(id -u)" -ne 0 ]; then
    echo "IruPulse uninstaller must run as root." >&2
    exit 1
fi

echo "IruPulse: stopping daemon ..."
launchctl bootout system "$DAEMON_PLIST" 2>/dev/null

echo "IruPulse: removing files ..."
rm -f "$DAEMON_PLIST"
rm -rf "$INSTALL_DIR"
rm -rf "$STATE_DIR"
rm -f "$LOG_FILE"

echo "IruPulse: uninstalled. (Remember to unassign the com.iru.pulse profile in MDM.)"
exit 0
