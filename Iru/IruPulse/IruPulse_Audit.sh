#!/bin/bash
#
# IruPulse — IruPulse_Audit.sh
#
# Kandji audit script (audit/remediation idiom). Pair it in Kandji with
# IruPulse_Install.sh as the remediation.
#
# Exit 0  = healthy, no action needed
# Exit 1  = drift detected -> Kandji runs the remediation (installer)
#
# Healthy means:
#   - collector script + LaunchDaemon are installed
#   - the daemon is loaded in launchd
#   - IF the agent is Enabled, a successful run happened within 2x the interval
#     (a disabled agent that is loaded is considered healthy — it's an
#      intentional, MDM-driven kill switch, not drift)

set -u

BUNDLE_ID="com.iru.pulse"
DAEMON_LABEL="com.iru.pulse.daemon"
DAEMON_PLIST="/Library/LaunchDaemons/${DAEMON_LABEL}.plist"
COLLECTOR="/usr/local/iru-pulse/pulse-collector.sh"
HEARTBEAT="/var/db/iru-pulse/last-run.json"
MANAGED_PLIST="/Library/Managed Preferences/${BUNDLE_ID}.plist"
LOCAL_PLIST="/Library/Preferences/${BUNDLE_ID}.plist"

read_cfg() {
    local key="$1" default="$2" value=""
    if [ -f "$MANAGED_PLIST" ]; then
        value=$(/usr/bin/defaults read "$MANAGED_PLIST" "$key" 2>/dev/null)
        if [ -n "$value" ]; then printf '%s' "$value"; return; fi
    fi
    if [ -f "$LOCAL_PLIST" ]; then
        value=$(/usr/bin/defaults read "$LOCAL_PLIST" "$key" 2>/dev/null)
        if [ -n "$value" ]; then printf '%s' "$value"; return; fi
    fi
    printf '%s' "$default"
}

# --- Files present? -------------------------------------------------------
if [ ! -f "$COLLECTOR" ] || [ ! -f "$DAEMON_PLIST" ]; then
    echo "IruPulse audit: collector or daemon missing. Remediation needed."
    exit 1
fi

# --- Daemon loaded? -------------------------------------------------------
if ! launchctl print "system/${DAEMON_LABEL}" >/dev/null 2>&1; then
    echo "IruPulse audit: daemon not loaded. Remediation needed."
    exit 1
fi

# --- Disabled is a healthy, intentional state -----------------------------
ENABLED=$(read_cfg "Enabled" "false")
case "$ENABLED" in
    1|true|True|TRUE|yes|Yes) ENABLED="true" ;;
    *) ENABLED="false" ;;
esac
if [ "$ENABLED" != "true" ]; then
    echo "IruPulse audit: agent disabled by config (healthy no-op)."
    exit 0
fi

# --- Recent successful run? ----------------------------------------------
INTERVAL=$(read_cfg "CollectionInterval" "300")
case "$INTERVAL" in ''|*[!0-9]*) INTERVAL=300 ;; esac
STALE_AFTER=$(( INTERVAL * 2 + 60 ))   # allow one missed cycle + slack

if [ ! -f "$HEARTBEAT" ]; then
    echo "IruPulse audit: enabled but no successful run recorded yet. Remediation needed."
    exit 1
fi

NOW=$(date +%s)
LAST=$(stat -f %m "$HEARTBEAT" 2>/dev/null)
if [ -z "$LAST" ]; then
    echo "IruPulse audit: cannot read heartbeat timestamp. Remediation needed."
    exit 1
fi

AGE=$(( NOW - LAST ))
if [ "$AGE" -gt "$STALE_AFTER" ]; then
    echo "IruPulse audit: last successful run ${AGE}s ago (> ${STALE_AFTER}s). Remediation needed."
    exit 1
fi

echo "IruPulse audit: healthy (last run ${AGE}s ago)."
exit 0
