#!/bin/bash
#
# IruPulse — pulse-collector.sh
#
# Open-source, headless macOS endpoint telemetry collector.
# Gathers core system-health metrics and POSTs them as a single JSON object
# to a generic HTTP webhook. Optionally evaluates per-metric thresholds and
# fires alerts to a (separate) alert webhook. Designed to be run on an interval
# by a LaunchDaemon and deployed/controlled from Kandji (or any MDM).
#
# No secrets live in this file. The webhook URLs and all tuning come from a
# configuration profile (managed preferences) or a local plist override.
#
# Exit codes:
#   0  Ran successfully (metrics shipped, spooled, or agent disabled)
#   1  Fatal configuration error

set -u

##############################################################################
# Paths / constants
##############################################################################

BUNDLE_ID="com.iru.pulse"
STATE_DIR="/var/db/iru-pulse"
SPOOL_DIR="${STATE_DIR}/spool"
ALERT_DIR="${STATE_DIR}/alerts"
HEARTBEAT="${STATE_DIR}/last-run.json"

MANAGED_PLIST="/Library/Managed Preferences/${BUNDLE_ID}.plist"
LOCAL_PLIST="/Library/Preferences/${BUNDLE_ID}.plist"

DEFAULT_ENABLED=false
CURL_MAX_TIME=15
SPOOL_MAX_FILES=500   # cap the spool so a long outage can't fill the disk

##############################################################################
# Config resolution — first source that defines a key wins:
#   1. Managed profile  (MDM config profile)
#   2. Local plist      (manual / testing override)
#   3. Built-in default
##############################################################################

read_key() {
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

# truthy <value> — 0 (true) for 1/true/yes, non-zero otherwise.
truthy() { case "$1" in 1|true|True|TRUE|yes|Yes) return 0 ;; *) return 1 ;; esac; }

# --- Core config ----------------------------------------------------------
# CollectionInterval is consumed by the installer (it drives the daemon's
# StartInterval), not by the collector itself.
WEBHOOK_URL=$(read_key "WebhookURL" "")
ENABLED=$(read_key "Enabled" "$DEFAULT_ENABLED")
EXTRA_TAGS=$(read_key "ExtraTags" "")

# --- Collector toggles (all default on) -----------------------------------
COLLECT_CPU=$(read_key "CollectCPU" "true")
COLLECT_MEMORY=$(read_key "CollectMemory" "true")
COLLECT_DISK=$(read_key "CollectDisk" "true")
COLLECT_UPTIME=$(read_key "CollectUptime" "true")
COLLECT_THERMAL=$(read_key "CollectThermal" "true")

# --- Alerts ---------------------------------------------------------------
ALERTS_ENABLED=$(read_key "AlertsEnabled" "false")
ALERT_WEBHOOK_URL=$(read_key "AlertWebhookURL" "")
[ -z "$ALERT_WEBHOOK_URL" ] && ALERT_WEBHOOK_URL="$WEBHOOK_URL"   # fall back to main
ALERT_COOLDOWN=$(read_key "AlertCooldown" "3600")
case "$ALERT_COOLDOWN" in ''|*[!0-9]*) ALERT_COOLDOWN=3600 ;; esac
CPU_ALERT_THRESHOLD=$(read_key "CPUAlertThreshold" "90")
MEM_ALERT_THRESHOLD=$(read_key "MemoryAlertThreshold" "90")
DISK_ALERT_THRESHOLD=$(read_key "DiskAlertThreshold" "90")
THERMAL_ALERT_ENABLED=$(read_key "ThermalAlertEnabled" "true")

# --- Custom alert message templates ---------------------------------------
# Placeholders: {hostname} {serial} {user} {value} {threshold}
MSG_CPU=$(read_key "AlertMessageCPU" "High CPU on {hostname} ({serial}): {value}% (>= {threshold}%)")
MSG_MEM=$(read_key "AlertMessageMemory" "High memory usage on {hostname} ({serial}): {value}% (>= {threshold}%)")
MSG_DISK=$(read_key "AlertMessageDisk" "Low disk space on {hostname} ({serial}): {value}% used (>= {threshold}%)")
MSG_THERMAL=$(read_key "AlertMessageThermal" "Thermal throttling on {hostname} ({serial}): CPU speed limit {value}%")

case "$ENABLED" in
    1|true|True|TRUE|yes|Yes)  ENABLED="true" ;;
    *)                         ENABLED="false" ;;
esac

##############################################################################
# JSON helpers (no jq dependency)
##############################################################################

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\t'/\\t}"
    s="${s//$'\r'/}"; s="${s//$'\n'/\\n}"
    printf '%s' "$s"
}

# num <value> — bare JSON number, or null when empty/non-numeric.
num() {
    if [ -n "$1" ] && [[ "$1" =~ ^-?[0-9]+([.][0-9]+)?$ ]]; then printf '%s' "$1"; else printf 'null'; fi
}
# str <value> — quoted JSON string, or null when empty.
str() {
    if [ -n "$1" ]; then printf '"%s"' "$(json_escape "$1")"; else printf 'null'; fi
}

##############################################################################
# Early exits
##############################################################################

mkdir -p "$SPOOL_DIR" "$ALERT_DIR" 2>/dev/null

if [ "$ENABLED" != "true" ]; then
    echo "$(date '+%Y-%m-%dT%H:%M:%S%z') IruPulse: agent disabled (Enabled != true); no-op."
    exit 0
fi

if [ -z "$WEBHOOK_URL" ]; then
    echo "$(date '+%Y-%m-%dT%H:%M:%S%z') IruPulse: no WebhookURL configured; nothing to do."
    exit 0
fi

##############################################################################
# Collectors — native macOS tooling only. Each guarded by its toggle;
# a disabled collector emits `null` for its section (intentional vs failed).
##############################################################################

TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

# Identity is always collected (needed for payload + alerts).
HOSTNAME=$(scutil --get ComputerName 2>/dev/null)
SERIAL=$(system_profiler SPHardwareDataType 2>/dev/null | awk '/Serial Number/ {print $4}')
MODEL=$(sysctl -n hw.model 2>/dev/null)
CONSOLE_USER=$(scutil <<< "show State:/Users/ConsoleUser" 2>/dev/null \
    | awk '/Name :/ && !/loginwindow/ { print $3 }')
OS_NAME=$(sw_vers -productName 2>/dev/null)
OS_VERSION=$(sw_vers -productVersion 2>/dev/null)
OS_BUILD=$(sw_vers -buildVersion 2>/dev/null)

# Pre-init metric vars so `set -u` is safe when a toggle is off.
NCPU=""; CPU_USAGE=""; LOAD_1=""; LOAD_5=""; LOAD_15=""
MEM_TOTAL_BYTES=""; MEM_USED_PCT=""; MEM_FREE_PCT=""
DISK_TOTAL_KB=""; DISK_USED_KB=""; DISK_AVAIL_KB=""; DISK_USED_PCT=""
DISK_KB_T=""; DISK_TPS=""; DISK_MB_S=""
UPTIME_SECONDS=""; CPU_SPEED_LIMIT=""; THERMAL_THROTTLED="false"

CPU_JSON="null"; MEM_JSON="null"; DISK_JSON="null"; THERMAL_JSON="null"; UPTIME_JSON="null"

# --- CPU ------------------------------------------------------------------
if truthy "$COLLECT_CPU"; then
    read -r LOAD_1 LOAD_5 LOAD_15 <<< "$(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}')"
    NCPU=$(sysctl -n hw.ncpu 2>/dev/null)
    CPU_IDLE=$(top -l 1 -n 0 2>/dev/null \
        | awk -F'[:,]' '/CPU usage/ {for (i=1;i<=NF;i++) if ($i ~ /idle/) {gsub(/[^0-9.]/,"",$i); print $i}}')
    if [ -n "$CPU_IDLE" ]; then
        CPU_USAGE=$(awk -v idle="$CPU_IDLE" 'BEGIN { printf "%.1f", 100 - idle }')
    fi
    CPU_JSON=$(cat <<EOF
{ "cores": $(num "$NCPU"), "usage_percent": $(num "$CPU_USAGE"), "load_1m": $(num "$LOAD_1"), "load_5m": $(num "$LOAD_5"), "load_15m": $(num "$LOAD_15") }
EOF
)
fi

# --- Memory ---------------------------------------------------------------
if truthy "$COLLECT_MEMORY"; then
    MEM_FREE_PCT=$(memory_pressure 2>/dev/null \
        | awk -F': ' '/free percentage/ {gsub(/[^0-9]/,"",$2); print $2}')
    [ -n "$MEM_FREE_PCT" ] && MEM_USED_PCT=$(( 100 - MEM_FREE_PCT ))
    MEM_TOTAL_BYTES=$(sysctl -n hw.memsize 2>/dev/null)
    MEM_JSON=$(cat <<EOF
{ "total_bytes": $(num "$MEM_TOTAL_BYTES"), "used_percent": $(num "$MEM_USED_PCT"), "free_percent": $(num "$MEM_FREE_PCT") }
EOF
)
fi

# --- Disk (boot volume) ---------------------------------------------------
if truthy "$COLLECT_DISK"; then
    read -r DISK_TOTAL_KB DISK_USED_KB DISK_AVAIL_KB DISK_CAP <<< "$(df -k / 2>/dev/null \
        | awk 'NR==2 {print $2, $3, $4, $5}')"
    DISK_USED_PCT="${DISK_CAP%\%}"
    read -r DISK_KB_T DISK_TPS DISK_MB_S <<< "$(iostat -d -w 1 -c 2 disk0 2>/dev/null \
        | awk 'END {print $1, $2, $3}')"
    DISK_JSON=$(cat <<EOF
{ "total_kb": $(num "$DISK_TOTAL_KB"), "used_kb": $(num "$DISK_USED_KB"), "available_kb": $(num "$DISK_AVAIL_KB"), "used_percent": $(num "$DISK_USED_PCT"), "io_kb_per_transfer": $(num "$DISK_KB_T"), "io_transfers_per_sec": $(num "$DISK_TPS"), "io_mb_per_sec": $(num "$DISK_MB_S") }
EOF
)
fi

# --- Uptime ---------------------------------------------------------------
if truthy "$COLLECT_UPTIME"; then
    BOOT_SEC=$(sysctl -n kern.boottime 2>/dev/null | awk -F'[ ,]+' '{print $4}')
    if [ -n "$BOOT_SEC" ]; then
        UPTIME_SECONDS=$(( $(date +%s) - BOOT_SEC ))
    fi
    UPTIME_JSON=$(num "$UPTIME_SECONDS")
fi

# --- Thermal / throttle ---------------------------------------------------
if truthy "$COLLECT_THERMAL"; then
    CPU_SPEED_LIMIT=$(pmset -g therm 2>/dev/null \
        | awk -F'= ' '/CPU_Speed_Limit/ {gsub(/[^0-9]/,"",$2); print $2}')
    if [ -n "$CPU_SPEED_LIMIT" ] && [ "$CPU_SPEED_LIMIT" -lt 100 ] 2>/dev/null; then
        THERMAL_THROTTLED="true"
    fi
    THERMAL_JSON=$(cat <<EOF
{ "cpu_speed_limit": $(num "$CPU_SPEED_LIMIT"), "throttled": ${THERMAL_THROTTLED} }
EOF
)
fi

##############################################################################
# Assemble JSON payload
##############################################################################

PAYLOAD=$(cat <<EOF
{
  "schema": "iru.pulse/v1",
  "timestamp": "$(json_escape "$TIMESTAMP")",
  "device": {
    "hostname": $(str "$HOSTNAME"),
    "serial": $(str "$SERIAL"),
    "model": $(str "$MODEL"),
    "console_user": $(str "$CONSOLE_USER"),
    "os_name": $(str "$OS_NAME"),
    "os_version": $(str "$OS_VERSION"),
    "os_build": $(str "$OS_BUILD")
  },
  "metrics": {
    "cpu": ${CPU_JSON},
    "memory": ${MEM_JSON},
    "disk": ${DISK_JSON},
    "uptime_seconds": ${UPTIME_JSON},
    "thermal": ${THERMAL_JSON}
  },
  "tags": $(str "$EXTRA_TAGS")
}
EOF
)

##############################################################################
# HTTP helpers
##############################################################################

# post_to <url> <body> — 0 on 2xx, non-zero otherwise.
post_to() {
    local url="$1" body="$2" code
    [ -z "$url" ] && return 1
    code=$(curl -s -o /dev/null -w '%{http_code}' \
        --max-time "$CURL_MAX_TIME" -X POST \
        -H 'Content-Type: application/json' \
        --data "$body" "$url" 2>/dev/null)
    [[ "$code" =~ ^2[0-9][0-9]$ ]]
}

##############################################################################
# Ship telemetry — flush spool first, then this run; spool on failure
##############################################################################

flush_spool() {
    local f count=0
    for f in $(ls -1 "$SPOOL_DIR"/*.json 2>/dev/null | sort); do
        if post_to "$WEBHOOK_URL" "$(cat "$f")"; then
            rm -f "$f"; count=$((count + 1))
        else
            break
        fi
    done
    [ "$count" -gt 0 ] && echo "IruPulse: flushed ${count} spooled payload(s)."
}

spool_payload() {
    local existing
    existing=$(ls -1 "$SPOOL_DIR"/*.json 2>/dev/null | wc -l | tr -d ' ')
    if [ "${existing:-0}" -ge "$SPOOL_MAX_FILES" ]; then
        ls -1 "$SPOOL_DIR"/*.json 2>/dev/null | sort | head -n 1 | xargs -I{} rm -f {}
    fi
    printf '%s' "$PAYLOAD" > "${SPOOL_DIR}/$(date +%s).json"
}

flush_spool

if post_to "$WEBHOOK_URL" "$PAYLOAD"; then
    echo "$(date '+%Y-%m-%dT%H:%M:%S%z') IruPulse: metrics shipped for ${SERIAL:-unknown}."
    printf '%s' "$PAYLOAD" > "$HEARTBEAT" 2>/dev/null
else
    spool_payload
    echo "$(date '+%Y-%m-%dT%H:%M:%S%z') IruPulse: webhook unreachable; payload spooled."
fi

##############################################################################
# Alerts — evaluate thresholds for enabled collectors, honor per-type cooldown
##############################################################################

# render_msg <template> <value> <threshold>
render_msg() {
    local t="$1" value="$2" threshold="$3"
    t="${t//\{hostname\}/$HOSTNAME}"
    t="${t//\{serial\}/$SERIAL}"
    t="${t//\{user\}/$CONSOLE_USER}"
    t="${t//\{value\}/$value}"
    t="${t//\{threshold\}/$threshold}"
    printf '%s' "$t"
}

# ge <a> <b> — 0 (true) if a >= b (float-safe).
ge() { awk -v a="$1" -v b="$2" 'BEGIN { exit !((a + 0) >= (b + 0)) }'; }

# alert_ready <type> — 0 if outside cooldown window.
alert_ready() {
    local last now
    now=$(date +%s)
    last=$(cat "${ALERT_DIR}/$1.ts" 2>/dev/null)
    [ -z "$last" ] && return 0
    [ $(( now - last )) -ge "$ALERT_COOLDOWN" ]
}

# fire_alert <type> <value> <threshold> <message>
fire_alert() {
    local type="$1" value="$2" threshold="$3" msg="$4" body
    if ! alert_ready "$type"; then
        echo "IruPulse: ${type} alert suppressed (cooldown)."
        return
    fi
    body=$(cat <<EOF
{ "text": $(str "$msg"), "alert": { "type": $(str "$type"), "value": $(num "$value"), "threshold": $(num "$threshold"), "device": { "hostname": $(str "$HOSTNAME"), "serial": $(str "$SERIAL"), "console_user": $(str "$CONSOLE_USER") }, "timestamp": "$(json_escape "$TIMESTAMP")" } }
EOF
)
    if post_to "$ALERT_WEBHOOK_URL" "$body"; then
        date +%s > "${ALERT_DIR}/${type}.ts"
        echo "IruPulse: ${type} alert sent."
    else
        echo "IruPulse: ${type} alert send failed."
    fi
}

# is_threshold <value> — numeric and > 0.
is_threshold() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -gt 0 ]; }

if truthy "$ALERTS_ENABLED"; then
    if truthy "$COLLECT_CPU" && [ -n "$CPU_USAGE" ] && is_threshold "$CPU_ALERT_THRESHOLD" \
       && ge "$CPU_USAGE" "$CPU_ALERT_THRESHOLD"; then
        fire_alert "cpu" "$CPU_USAGE" "$CPU_ALERT_THRESHOLD" \
            "$(render_msg "$MSG_CPU" "$CPU_USAGE" "$CPU_ALERT_THRESHOLD")"
    fi

    if truthy "$COLLECT_MEMORY" && [ -n "$MEM_USED_PCT" ] && is_threshold "$MEM_ALERT_THRESHOLD" \
       && ge "$MEM_USED_PCT" "$MEM_ALERT_THRESHOLD"; then
        fire_alert "memory" "$MEM_USED_PCT" "$MEM_ALERT_THRESHOLD" \
            "$(render_msg "$MSG_MEM" "$MEM_USED_PCT" "$MEM_ALERT_THRESHOLD")"
    fi

    if truthy "$COLLECT_DISK" && [ -n "$DISK_USED_PCT" ] && is_threshold "$DISK_ALERT_THRESHOLD" \
       && ge "$DISK_USED_PCT" "$DISK_ALERT_THRESHOLD"; then
        fire_alert "disk" "$DISK_USED_PCT" "$DISK_ALERT_THRESHOLD" \
            "$(render_msg "$MSG_DISK" "$DISK_USED_PCT" "$DISK_ALERT_THRESHOLD")"
    fi

    if truthy "$COLLECT_THERMAL" && truthy "$THERMAL_ALERT_ENABLED" && [ "$THERMAL_THROTTLED" = "true" ]; then
        fire_alert "thermal" "${CPU_SPEED_LIMIT:-0}" "100" \
            "$(render_msg "$MSG_THERMAL" "${CPU_SPEED_LIMIT:-0}" "100")"
    fi
fi

exit 0
