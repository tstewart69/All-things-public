#!/bin/bash
# =====================================================================
# Mini Shai-Hulud / TeamPCP npm+PyPI Supply Chain IOC Audit (Kandji)
# CVE-2026-45321 / GHSA-g7cv-rxg3-hmpx
# Version: 1.2.1 — fixes empty-FINDINGS crash + SCAN_ROOTS diagnostic
#
# READ-ONLY. Performs NO writes to user filesystems, NO token operations,
# NO package-manager invocations, NO uninstalls. The malware's dead-man's-
# switch fires on token revocation; this script must not touch tokens.
#
# Exit codes (Kandji Audit & Enforce contract):
#   0  GREEN   - no indicators found
#   1  RED or YELLOW - one or more findings; check Slack + /var/log.
#                RED = confirmed IOC, DO NOT touch tokens, image first.
#
# Changes vs 1.2.0:
#   - Fix: "FINDINGS[@]: unbound variable" crash when nothing matches
#     (bash 3.2 + set -u + empty array). All array iterations now use
#     the ${arr[@]+"${arr[@]}"} idiom or temporary set +u.
#   - Fix: SCAN_ROOTS now uses shopt -s nullglob to handle empty /Users
#     glob safely; explicit Guest/.localized exclusion.
#   - New: scan-root diagnostic line printed to stdout AND log file —
#     tells you immediately if Kandji lacks Full Disk Access.
#   - Hardening: all per-user loops (phase2_extras, phase3_network)
#     wrapped with shopt -s nullglob.
# =====================================================================

set -u

# --------- Configuration ---------------------------------------------
WEBHOOK_URL="REPLACE_WITH_SLACK_WEBHOOK_URL"

ATTACK_EPOCH=1778195000   # 2026-05-11 19:23:20 UTC (approx midpoint)
SCRIPT_VERSION="1.2.1"

# Per-phase timeouts (seconds). Sum stays well under Kandji's 10min cap.
TIMEOUT_FIND=60
TIMEOUT_GREP=45
TIMEOUT_LOG_SHOW=20

LOCK_FILE="/var/run/shai_hulud_audit.lock"
AUDIT_LOG="/var/log/shai_hulud_audit.log"

# --------- Lock (prevent overlapping runs) ---------------------------
if [[ -f "$LOCK_FILE" ]]; then
    lock_pid=$(/bin/cat "$LOCK_FILE" 2>/dev/null)
    if [[ -n "${lock_pid:-}" ]] && /bin/kill -0 "$lock_pid" 2>/dev/null; then
        echo "[shai-hulud-audit] another run is in progress (pid=$lock_pid); exiting clean"
        exit 0
    fi
    /bin/rm -f "$LOCK_FILE" 2>/dev/null
fi
echo "$$" > "$LOCK_FILE" 2>/dev/null
trap '/bin/rm -f "$LOCK_FILE" 2>/dev/null' EXIT

# --------- Metadata --------------------------------------------------
HOSTNAME_FQDN="$(/bin/hostname -f 2>/dev/null || /bin/hostname)"
SERIAL="$(/usr/sbin/ioreg -l 2>/dev/null | /usr/bin/awk -F'"' '/IOPlatformSerialNumber/ {print $4; exit}')"
RUN_TS="$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"
RUN_START_EPOCH=$(/bin/date +%s)

# --------- Findings accumulator --------------------------------------
FINDINGS=()
RED_COUNT=0
YELLOW_COUNT=0

add_finding() {
    local sev="$1" cat="$2" det="$3"
    FINDINGS+=("{\"severity\":\"$sev\",\"category\":\"$cat\",\"detail\":\"$det\"}")
    case "$sev" in
        RED)    RED_COUNT=$((RED_COUNT+1)) ;;
        YELLOW) YELLOW_COUNT=$((YELLOW_COUNT+1)) ;;
    esac
}

jescape() {
    /usr/bin/sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' -e ':a;N;$!ba;s/\n/\\n/g'
}

log() { echo "[shai-hulud-audit] $*"; }

run_phase() {
    local name="$1"; shift
    local start=$(/bin/date +%s)
    log "Phase $name: start"
    if ! "$@"; then
        log "Phase $name: WARNING — non-zero exit, continuing"
    fi
    local dur=$(( $(/bin/date +%s) - start ))
    log "Phase $name: done (${dur}s)"
}

# --------- IOC definitions -------------------------------------------
NPM_SCOPES=(
    "@tanstack" "@uipath" "@squawk" "@tallyui" "@draftlab" "@opensearch-project"
)
NPM_EXACT=("@mistralai/mistralai")
PYPI_NAMES=("mistralai" "guardrails-ai" "litellm")

IOC_FILES=("router_init.js" "router_runtime.js" "tanstack_runner.js")
IOC_PATH_PATTERNS=("*/.claude/setup.mjs" "*/.vscode/setup.mjs")

CAMPAIGN_STRINGS=(
    "Shai-Hulud"
    "A Mini Shai-Hulud has Appeared"
    "thebeautifulmarchoftime"
    "thebeautifulsandsoftime"
)

C2_INDICATORS=(
    "83.142.209.194"
    "filev2.getsession.org"
    "seed1.getsession.org"
    "git-tanstack.com"
    "api.masscan.cloud"
)

GREP_EXCLUDE_DIRS=(
    "node_modules" ".git" "Library" "Photos" "Music" "Movies"
    ".Trash" "Caches" ".cache" "iCloud~md~obsidian" ".obsidian"
)
GREP_EXCLUDE_FILES=(
    "tempCodeRunnerFile.*"
    "shai_hulud_audit.sh"
    "*.bear-note"
    "*.md"
)

# --------- Build scan roots (nullglob-safe) --------------------------
SCAN_ROOTS=()
shopt -s nullglob
for u in /Users/*/; do
    user_base=$(/usr/bin/basename "$u")
    case "$user_base" in
        Shared|.localized|Guest) continue ;;
    esac
    [[ -d "$u" ]] && SCAN_ROOTS+=("${u%/}")
done
shopt -u nullglob
[[ -d /opt/src ]] && SCAN_ROOTS+=("/opt/src")
[[ -d /srv ]]     && SCAN_ROOTS+=("/srv")

log "scan roots (${#SCAN_ROOTS[@]}): ${SCAN_ROOTS[*]:-NONE}"
if [[ ${#SCAN_ROOTS[@]} -eq 0 ]]; then
    log "WARNING: no scan roots found — Kandji agent likely lacks Full Disk Access."
    log "         Grant via System Settings > Privacy & Security > Full Disk Access,"
    log "         or deploy Kandji's PPPC profile for the agent."
fi

# --------- §1+2a combined scan ---------------------------------------

phase1_scan() {
    [[ ${#SCAN_ROOTS[@]} -eq 0 ]] && return 0

    local tmp_paths
    tmp_paths=$(/usr/bin/mktemp) || return 1

    local root
    for root in "${SCAN_ROOTS[@]}"; do
        log "  walking $root"
        /usr/bin/timeout "$TIMEOUT_FIND" /usr/bin/find "$root" \
            -type d \( \
                -name .git -o -name Library -o -name Photos \
                -o -name Music -o -name Movies -o -name .Trash \
                -o -name Caches -o -name .cache \
            \) -prune -o \
            \( \
                -type f \( \
                    -name package-lock.json -o -name pnpm-lock.yaml \
                    -o -name yarn.lock -o -name package.json \
                    -o -name requirements.txt -o -name pyproject.toml \
                    -o -name poetry.lock -o -name uv.lock -o -name Pipfile.lock \
                    -o -name router_init.js -o -name router_runtime.js \
                    -o -name tanstack_runner.js \
                    -o -name codeql_analysis.yml \
                    -o -name setup.mjs \
                \) \
                -o \
                -type d -name "@*" \
            \) -print 2>/dev/null
    done > "$tmp_paths"

    local p mtime sz base parent
    while IFS= read -r p; do
        [[ -z "$p" || ! -e "$p" ]] && continue
        mtime=$(/usr/bin/stat -f %m "$p" 2>/dev/null || echo 0)
        sz=$(/usr/bin/stat -f %z "$p" 2>/dev/null || echo 0)
        base=$(/usr/bin/basename "$p")
        parent=$(/usr/bin/dirname "$p")

        case "$p" in
            */node_modules/@*)
                local scope_dir="$base"
                if [[ "$parent" == */node_modules ]]; then
                    local is_ioc=0 s
                    for s in "${NPM_SCOPES[@]}"; do
                        [[ "$scope_dir" == "$s" ]] && is_ioc=1 && break
                    done
                    if [[ "$scope_dir" == "@mistralai" && -d "$p/mistralai" ]]; then
                        is_ioc=1
                    fi
                    if [[ $is_ioc -eq 1 ]]; then
                        local sev="RED"
                        [[ "$mtime" -lt "$ATTACK_EPOCH" ]] && sev="YELLOW"
                        add_finding "$sev" "node_modules-installed" \
                            "$(printf 'path=%s mtime=%s' "$p" "$mtime" | jescape)"
                    fi
                fi
                ;;

            */router_init.js|*/router_runtime.js|*/tanstack_runner.js)
                local sev="YELLOW"
                if [[ "$p" == *"/node_modules/"* ]] && [[ "$sz" -gt 1500000 ]]; then
                    sev="RED"
                fi
                add_finding "$sev" "ioc-file-payload" \
                    "$(printf 'path=%s size=%s' "$p" "$sz" | jescape)"
                ;;

            */.claude/setup.mjs|*/.vscode/setup.mjs)
                add_finding "RED" "ioc-dropper" \
                    "$(printf 'path=%s' "$p" | jescape)"
                ;;

            */.github/workflows/codeql_analysis.yml)
                local sev="YELLOW"
                [[ "$mtime" -ge "$ATTACK_EPOCH" ]] && sev="RED"
                add_finding "$sev" "rogue-workflow" \
                    "$(printf 'path=%s mtime=%s' "$p" "$mtime" | jescape)"
                ;;

            *)
                [[ "$p" == *"/node_modules/"* ]] && continue
                scan_lockfile "$p" "$mtime"
                ;;
        esac
    done < "$tmp_paths"

    /bin/rm -f "$tmp_paths"
    return 0
}

scan_lockfile() {
    local lf="$1" mtime="$2"
    [[ ! -r "$lf" ]] && return 0

    local scope_pattern
    scope_pattern=$(printf '"%s/|' "${NPM_SCOPES[@]}" | /usr/bin/sed 's/|$//')
    if /usr/bin/grep -E -q "$scope_pattern" "$lf" 2>/dev/null; then
        local matched
        matched=$(/usr/bin/grep -E -o "(${scope_pattern})" "$lf" 2>/dev/null \
            | /usr/bin/sort -u | /usr/bin/head -n 3 | /usr/bin/tr '\n' ',' | /usr/bin/sed 's/,$//')
        local sev="RED"
        [[ "$mtime" -lt "$ATTACK_EPOCH" ]] && sev="YELLOW"
        add_finding "$sev" "lockfile-scope" \
            "$(printf 'scopes=%s file=%s mtime=%s' "$matched" "$lf" "$mtime" | jescape)"
    fi

    local pkg
    for pkg in "${NPM_EXACT[@]}"; do
        if /usr/bin/grep -q -F "\"$pkg\"" "$lf" 2>/dev/null; then
            local sev="RED"
            [[ "$mtime" -lt "$ATTACK_EPOCH" ]] && sev="YELLOW"
            add_finding "$sev" "lockfile-npm-exact" \
                "$(printf 'pkg=%s file=%s mtime=%s' "$pkg" "$lf" "$mtime" | jescape)"
        fi
    done

    case "$lf" in
        */requirements*.txt|*/pyproject.toml|*/poetry.lock|*/uv.lock|*/Pipfile.lock)
            local pypi_pattern
            pypi_pattern=$(printf '%s|' "${PYPI_NAMES[@]}" | /usr/bin/sed 's/|$//')
            if /usr/bin/grep -E -q "(^|[[:space:]\"'])(${pypi_pattern})([[:space:]=<>~!\"']|$)" "$lf" 2>/dev/null; then
                local matched
                matched=$(/usr/bin/grep -E -o "(${pypi_pattern})" "$lf" 2>/dev/null \
                    | /usr/bin/sort -u | /usr/bin/head -n 3 | /usr/bin/tr '\n' ',' | /usr/bin/sed 's/,$//')
                local sev="YELLOW"
                [[ "$mtime" -ge "$ATTACK_EPOCH" ]] && sev="RED"
                add_finding "$sev" "lockfile-pypi" \
                    "$(printf 'pkgs=%s file=%s mtime=%s (verify pinned version manually)' "$matched" "$lf" "$mtime" | jescape)"
            fi
            ;;
    esac
    return 0
}

# --------- §2b: persistence + Linux payload --------------------------

phase2_extras() {
    if [[ -f /tmp/transformers.pyz ]]; then
        local sz
        sz=$(/usr/bin/stat -f %z /tmp/transformers.pyz 2>/dev/null || echo 0)
        add_finding "RED" "ioc-pyz-payload" \
            "$(printf 'path=/tmp/transformers.pyz size=%s' "$sz" | jescape)"
    fi

    shopt -s nullglob
    local u user_base plist sysd contents
    for u in /Users/*/; do
        u="${u%/}"
        [[ -d "$u" ]] || continue
        user_base=$(/usr/bin/basename "$u")
        case "$user_base" in
            Shared|.localized|Guest) continue ;;
        esac

        plist="$u/Library/LaunchAgents/com.user.gh-token-monitor.plist"
        if [[ -f "$plist" ]]; then
            contents="$(/usr/bin/plutil -p "$plist" 2>/dev/null | /usr/bin/head -c 2000 | jescape)"
            add_finding "RED" "persistence-launchagent" \
                "$(printf 'user=%s path=%s plist=%s' "$user_base" "$plist" "$contents" | jescape)"
        fi
        sysd="$u/.config/systemd/user/gh-token-monitor.service"
        [[ -f "$sysd" ]] && add_finding "RED" "persistence-systemd" \
            "$(printf 'user=%s path=%s' "$user_base" "$sysd" | jescape)"
    done
    shopt -u nullglob
    return 0
}

# --------- §2c: campaign-string search -------------------------------

phase2_strings() {
    [[ ${#SCAN_ROOTS[@]} -eq 0 ]] && return 0

    local pattern
    pattern=$(printf '%s|' "${CAMPAIGN_STRINGS[@]}" | /usr/bin/sed 's/|$//')

    local exclude_args=()
    local d f
    for d in "${GREP_EXCLUDE_DIRS[@]}"; do
        exclude_args+=("--exclude-dir=$d")
    done
    for f in "${GREP_EXCLUDE_FILES[@]}"; do
        exclude_args+=("--exclude=$f")
    done

    local root hits h markers
    for root in "${SCAN_ROOTS[@]}"; do
        hits=$(/usr/bin/timeout "$TIMEOUT_GREP" /usr/bin/grep -r -l -I -E \
            --max-count=1 \
            "${exclude_args[@]}" \
            "$pattern" "$root" 2>/dev/null | /usr/bin/head -n 20)
        if [[ -n "$hits" ]]; then
            while IFS= read -r h; do
                [[ -z "$h" ]] && continue
                markers=$(/usr/bin/grep -E -o "$pattern" "$h" 2>/dev/null \
                    | /usr/bin/sort -u | /usr/bin/tr '\n' ',' | /usr/bin/sed 's/,$//')
                add_finding "RED" "campaign-string" \
                    "$(printf 'markers=%s path=%s' "$markers" "$h" | jescape)"
            done <<< "$hits"
        fi
    done
    return 0
}

# --------- §3: Network / DNS / shell-history -------------------------

phase3_network() {
    local ind
    for ind in "${C2_INDICATORS[@]}"; do
        if /usr/bin/grep -F -q "$ind" /etc/hosts 2>/dev/null; then
            add_finding "RED" "hosts-tamper" \
                "$(printf 'indicator=%s in /etc/hosts' "$ind" | jescape)"
        fi
    done

    local c2_pattern
    c2_pattern=$(printf '%s|' "${C2_INDICATORS[@]}" | /usr/bin/sed 's/|$//' | /usr/bin/sed 's/\./\\./g')
    local hist_files=(".bash_history" ".zsh_history" ".history" ".python_history" ".node_repl_history")

    shopt -s nullglob
    local u user_base hf path hit indicators
    for u in /Users/*/; do
        u="${u%/}"
        [[ -d "$u" ]] || continue
        user_base=$(/usr/bin/basename "$u")
        case "$user_base" in
            Shared|.localized|Guest) continue ;;
        esac
        for hf in "${hist_files[@]}"; do
            path="$u/$hf"
            [[ -r "$path" ]] || continue
            hit=$(/usr/bin/grep -E -o "$c2_pattern" "$path" 2>/dev/null | /usr/bin/sort -u | /usr/bin/head -n 3)
            if [[ -n "$hit" ]]; then
                indicators=$(echo "$hit" | /usr/bin/tr '\n' ',' | /usr/bin/sed 's/,$//')
                add_finding "RED" "history-c2-reference" \
                    "$(printf 'user=%s file=%s indicators=%s' "$user_base" "$path" "$indicators" | jescape)"
            fi
        done
    done
    shopt -u nullglob

    if [[ -x /usr/sbin/lsof ]]; then
        local conns
        conns=$(/usr/bin/timeout 10 /usr/sbin/lsof -nP -iTCP -sTCP:ESTABLISHED 2>/dev/null \
            | /usr/bin/awk 'NR>1 {print $NF}' | /usr/bin/sort -u)
        for ind in "${C2_INDICATORS[@]}"; do
            if echo "$conns" | /usr/bin/grep -F -q "$ind"; then
                add_finding "RED" "active-c2-connection" \
                    "$(printf 'indicator=%s currently connected' "$ind" | jescape)"
            fi
        done
    fi

    if [[ -x /usr/bin/log ]]; then
        local log_hits
        log_hits=$(/usr/bin/timeout "$TIMEOUT_LOG_SHOW" /usr/bin/log show --last 24h --info --style compact \
            --predicate "subsystem == 'com.apple.mDNSResponder' OR process == 'mDNSResponder'" 2>/dev/null \
            | /usr/bin/grep -E "$c2_pattern" | /usr/bin/head -n 5 || true)
        if [[ -n "$log_hits" ]]; then
            add_finding "RED" "dns-log-c2" \
                "$(printf '%s' "$log_hits" | /usr/bin/head -c 1500 | jescape)"
        fi
    fi
    return 0
}

# --------- Run phases ------------------------------------------------
run_phase "1+2a (lockfile/node_modules/IOC files)" phase1_scan
run_phase "2b (persistence + pyz)"                 phase2_extras
run_phase "2c (campaign strings)"                  phase2_strings
run_phase "3  (network / dns / history)"           phase3_network

# --------- Status decision -------------------------------------------
if [[ "$RED_COUNT" -gt 0 ]]; then
    STATUS="RED"
elif [[ "$YELLOW_COUNT" -gt 0 ]]; then
    STATUS="YELLOW"
else
    STATUS="GREEN"
fi

RUN_DURATION=$(( $(/bin/date +%s) - RUN_START_EPOCH ))

# --------- Build JSON payload (set +u: empty-array safe) -------------
# bash 3.2 on macOS treats "${empty_array[@]}" as unbound under set -u,
# so relax the flag for the remaining output-construction section.
set +u

findings_json="["
first=1
for f in "${FINDINGS[@]}"; do
    [[ -z "$f" ]] && continue
    if [[ $first -eq 1 ]]; then findings_json+="$f"; first=0
    else findings_json+=",$f"; fi
done
findings_json+="]"

PAYLOAD=$(/usr/bin/printf '{"script":"shai-hulud-audit","version":"%s","host":"%s","serial":"%s","timestamp":"%s","duration_s":%d,"scan_roots":%d,"status":"%s","red_count":%d,"yellow_count":%d,"findings":%s}' \
    "$SCRIPT_VERSION" "$HOSTNAME_FQDN" "$SERIAL" "$RUN_TS" "$RUN_DURATION" "${#SCAN_ROOTS[@]}" "$STATUS" "$RED_COUNT" "$YELLOW_COUNT" "$findings_json")

echo "$PAYLOAD"

{
    /bin/echo "$PAYLOAD"
} >> "$AUDIT_LOG" 2>/dev/null || true

# --------- Slack webhook (RED + YELLOW) ------------------------------
if [[ "$STATUS" != "GREEN" && "$WEBHOOK_URL" != *"REPLACE"* && -n "$WEBHOOK_URL" ]]; then
    case "$STATUS" in
        RED)    SLACK_COLOR="#d72b3f"; SLACK_EMOJI=":rotating_light:" ;;
        YELLOW) SLACK_COLOR="#f2c744"; SLACK_EMOJI=":warning:" ;;
    esac

    findings_text=""
    count=0
    total=${#FINDINGS[@]}
    for f in "${FINDINGS[@]}"; do
        [[ -z "$f" ]] && continue
        count=$((count+1))
        if [[ $count -gt 20 ]]; then
            findings_text+="\n…(+$((total - 20)) more in /var/log/shai_hulud_audit.log)"
            break
        fi
        sev=$(echo "$f"  | /usr/bin/sed -E 's/.*"severity":"([^"]*)".*/\1/')
        cat_=$(echo "$f" | /usr/bin/sed -E 's/.*"category":"([^"]*)".*/\1/')
        det=$(echo "$f"  | /usr/bin/sed -E 's/.*"detail":"(.*)"\}$/\1/')
        findings_text+="• [${sev}] ${cat_}: ${det}\n"
    done

    findings_escaped=$(printf '%b' "$findings_text" | jescape)

    SLACK_PAYLOAD=$(/usr/bin/printf '{
  "text": "%s Mini Shai-Hulud audit: *%s* on `%s`",
  "attachments": [{
    "color": "%s",
    "blocks": [
      {"type":"header","text":{"type":"plain_text","text":"%s Shai-Hulud / TeamPCP IOC Audit — %s"}},
      {"type":"section","fields":[
        {"type":"mrkdwn","text":"*Host:*\\n`%s`"},
        {"type":"mrkdwn","text":"*Serial:*\\n`%s`"},
        {"type":"mrkdwn","text":"*Red:*\\n%d"},
        {"type":"mrkdwn","text":"*Yellow:*\\n%d"},
        {"type":"mrkdwn","text":"*Runtime:*\\n%ds"},
        {"type":"mrkdwn","text":"*Script:*\\nv%s"}
      ]},
      {"type":"section","text":{"type":"mrkdwn","text":"*Findings:*\\n%s"}},
      {"type":"context","elements":[{"type":"mrkdwn","text":"CVE-2026-45321 · %s · *Do not rotate tokens on this host until imaged*"}]}
    ]
  }]
}' \
        "$SLACK_EMOJI" "$STATUS" "$HOSTNAME_FQDN" \
        "$SLACK_COLOR" \
        "$SLACK_EMOJI" "$STATUS" \
        "$HOSTNAME_FQDN" "$SERIAL" "$RED_COUNT" "$YELLOW_COUNT" "$RUN_DURATION" "$SCRIPT_VERSION" \
        "$findings_escaped" \
        "$RUN_TS")

    /usr/bin/timeout 15 /usr/bin/curl --silent --show-error --max-time 12 \
        -H "Content-Type: application/json" \
        -X POST --data-binary "$SLACK_PAYLOAD" "$WEBHOOK_URL" >/dev/null 2>&1 \
        || echo "[shai-hulud-audit] WARN: Slack webhook POST failed (non-blocking)"
fi

set -u

log "audit complete: status=$STATUS red=$RED_COUNT yellow=$YELLOW_COUNT roots=${#SCAN_ROOTS[@]} duration=${RUN_DURATION}s"

if [[ "$STATUS" == "GREEN" ]]; then
    exit 0
else
    exit 1
fi
