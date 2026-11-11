#!/bin/bash
# =====================================================================
# Mini Shai-Hulud / TeamPCP npm+PyPI Supply Chain IOC Audit (Kandji)
# CVE-2026-45321 / GHSA-g7cv-rxg3-hmpx
# Version: 1.3.3 — macOS-portable timeout shim + Perl-based jescape
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
# Changes vs 1.3.2:
#   - Fix: /usr/bin/timeout is GNU coreutils and NOT present on stock
#     macOS. Phases 1+2a, 2c, and 3 were silently failing because the
#     stderr from "command not found" was masked by 2>/dev/null. Now:
#     detect a timeout binary at startup (timeout / gtimeout / Homebrew
#     paths) and route every former /usr/bin/timeout call through
#     with_timeout(). If no timeout binary is present, commands run
#     without a per-phase cap; Kandji's 10-min process cap remains the
#     backstop.
#   - Fix: jescape() replaced with /usr/bin/perl. BSD sed's N command
#     on a single-line input without a trailing newline (exactly what
#     printf produces) quits without emitting the pattern space, so
#     every finding's `detail` was JSON-escaped to "". Perl is part of
#     base macOS and gives deterministic JSON-escape including tabs,
#     CRs, and embedded newlines.
#
# Changes vs 1.3.0:
#   - New: AUDIT_LOG rotates to .1.gz when it crosses 1 MiB; up to 7
#     gzipped generations retained, oldest dropped.
#
# Changes vs 1.2.1:
#   - New: Phase 4 verifies ~/.npmrc has min-release-age>=7 and
#     ~/.bunfig.toml has minimumReleaseAge>=604800 per user.
#   - Removed: /var/run/shai_hulud_audit.lock overlap guard.
# =====================================================================

set -u

# --------- Configuration ---------------------------------------------
WEBHOOK_URL="REPLACE_WITH_SLACK_WEBHOOK_URL"

ATTACK_EPOCH=1778195000   # 2026-05-11 19:23:20 UTC (approx midpoint)
SCRIPT_VERSION="1.3.3"

# Per-phase timeouts (seconds). Sum stays well under Kandji's 10min cap.
TIMEOUT_FIND=60
TIMEOUT_GREP=45
TIMEOUT_LOG_SHOW=20

AUDIT_LOG="/var/log/shai_hulud_audit.log"
AUDIT_LOG_MAX_BYTES=1048576   # 1 MiB
AUDIT_LOG_KEEP=7              # keep .1.gz … .7.gz, drop the rest

# --------- Timeout shim (macOS lacks GNU `timeout`) ------------------
# Probe common locations; gtimeout ships with Homebrew coreutils.
# Fall back to no-op if none present.
TIMEOUT_CMD=""
for cand in /usr/bin/timeout /usr/local/bin/gtimeout /opt/homebrew/bin/gtimeout; do
    if [[ -x "$cand" ]]; then
        TIMEOUT_CMD="$cand"
        break
    fi
done
if [[ -z "$TIMEOUT_CMD" ]]; then
    echo "[shai-hulud-audit] note: no timeout binary found; phases run unbounded (Kandji 10min cap remains the backstop)"
fi

with_timeout() {
    local secs="$1"; shift
    if [[ -n "$TIMEOUT_CMD" ]]; then
        "$TIMEOUT_CMD" "$secs" "$@"
    else
        "$@"
    fi
}

# --------- Log rotation ----------------------------------------------
rotate_log_if_needed() {
    local log="$1" max="$2" keep="$3"
    [[ -f "$log" ]] || return 0
    local sz
    sz=$(/usr/bin/stat -f %z "$log" 2>/dev/null || echo 0)
    [[ "$sz" -ge "$max" ]] || return 0

    [[ -f "${log}.${keep}.gz" ]] && /bin/rm -f "${log}.${keep}.gz"
    local i
    for (( i=keep-1; i>=1; i-- )); do
        [[ -f "${log}.${i}.gz" ]] && /bin/mv -f "${log}.${i}.gz" "${log}.$((i+1)).gz"
    done

    if /usr/bin/gzip -c "$log" > "${log}.1.gz" 2>/dev/null; then
        : > "$log"
        echo "[shai-hulud-audit] rotated $log (was ${sz} bytes) → ${log}.1.gz"
    else
        echo "[shai-hulud-audit] WARN: gzip failed; log not rotated"
    fi
}
rotate_log_if_needed "$AUDIT_LOG" "$AUDIT_LOG_MAX_BYTES" "$AUDIT_LOG_KEEP"

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

# JSON string escaper. Uses Perl because:
#   - macOS ships /usr/bin/perl in base install (always present).
#   - BSD sed mishandles N on single-line, no-trailing-newline input,
#     which is what printf produces — this previously dropped detail
#     strings entirely.
# -0777 slurps all input as one record; substitutions cover the full
# JSON string-escape minimum: \, ", \t, \n, \r. Order matters: escape
# backslashes first so subsequent inserted backslashes are not doubled.
jescape() {
    /usr/bin/perl -0777 -pe 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g; s/\n/\\n/g; s/\r/\\r/g'
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
        with_timeout "$TIMEOUT_FIND" /usr/bin/find "$root" \
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
        hits=$(with_timeout "$TIMEOUT_GREP" /usr/bin/grep -r -l -I -E \
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
        conns=$(with_timeout 10 /usr/sbin/lsof -nP -iTCP -sTCP:ESTABLISHED 2>/dev/null \
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
        log_hits=$(with_timeout "$TIMEOUT_LOG_SHOW" /usr/bin/log show --last 24h --info --style compact \
            --predicate "subsystem == 'com.apple.mDNSResponder' OR process == 'mDNSResponder'" 2>/dev/null \
            | /usr/bin/grep -E "$c2_pattern" | /usr/bin/head -n 5 || true)
        if [[ -n "$log_hits" ]]; then
            add_finding "RED" "dns-log-c2" \
                "$(printf '%s' "$log_hits" | /usr/bin/head -c 1500 | jescape)"
        fi
    fi
    return 0
}

# --------- §4: Supply-chain hardening checks --------------------------
# Verifies the min-release-age guards recommended after Shai-Hulud:
#   ~/.npmrc       min-release-age=7         (npm 11.5.1+; integer days)
#   ~/.bunfig.toml minimumReleaseAge = 604800 (Bun; seconds = 7 days)
# Absent/weak = YELLOW (hardening gap, not an active IOC).
# Users with no npm/bun footprint are skipped to keep non-dev hosts quiet.

phase4_hardening() {
    shopt -s nullglob
    local u user_base npmrc bunfig val uses_npm uses_bun

    for u in /Users/*/; do
        u="${u%/}"
        [[ -d "$u" ]] || continue
        user_base=$(/usr/bin/basename "$u")
        case "$user_base" in
            Shared|.localized|Guest) continue ;;
        esac

        uses_npm=0
        [[ -d "$u/.npm" || -d "$u/.nvm" || -d "$u/.config/npm" ]] && uses_npm=1
        uses_bun=0
        [[ -d "$u/.bun" || -x "$u/.bun/bin/bun" ]] && uses_bun=1

        npmrc="$u/.npmrc"
        if [[ -r "$npmrc" ]]; then
            val=$(/usr/bin/awk -F'=' '
                /^[[:space:]]*min-release-age[[:space:]]*=/ {
                    v=$2; gsub(/[ \t"]/,"",v); print v; exit
                }' "$npmrc" 2>/dev/null)
            if [[ -z "$val" ]]; then
                add_finding "YELLOW" "hardening-npmrc-missing-key" \
                    "$(printf 'user=%s file=%s missing=min-release-age' \
                        "$user_base" "$npmrc" | jescape)"
            elif ! [[ "$val" =~ ^[0-9]+$ ]] || [[ "$val" -lt 7 ]]; then
                add_finding "YELLOW" "hardening-npmrc-weak" \
                    "$(printf 'user=%s file=%s value=%s expected>=7' \
                        "$user_base" "$npmrc" "$val" | jescape)"
            fi
        elif [[ $uses_npm -eq 1 ]]; then
            add_finding "YELLOW" "hardening-npmrc-absent" \
                "$(printf 'user=%s file=%s (npm footprint present, no guard)' \
                    "$user_base" "$npmrc" | jescape)"
        fi

        bunfig="$u/.bunfig.toml"
        if [[ -r "$bunfig" ]]; then
            val=$(/usr/bin/awk -F'=' '
                /^[[:space:]]*minimumReleaseAge[[:space:]]*=/ {
                    v=$2; gsub(/[ \t"]/,"",v); print v; exit
                }' "$bunfig" 2>/dev/null)
            if [[ -z "$val" ]]; then
                add_finding "YELLOW" "hardening-bunfig-missing-key" \
                    "$(printf 'user=%s file=%s missing=minimumReleaseAge' \
                        "$user_base" "$bunfig" | jescape)"
            elif ! [[ "$val" =~ ^[0-9]+$ ]] || [[ "$val" -lt 604800 ]]; then
                add_finding "YELLOW" "hardening-bunfig-weak" \
                    "$(printf 'user=%s file=%s value=%s expected>=604800' \
                        "$user_base" "$bunfig" "$val" | jescape)"
            fi
        elif [[ $uses_bun -eq 1 ]]; then
            add_finding "YELLOW" "hardening-bunfig-absent" \
                "$(printf 'user=%s file=%s (bun footprint present, no guard)' \
                    "$user_base" "$bunfig" | jescape)"
        fi
    done
    shopt -u nullglob
    return 0
}

# --------- Run phases ------------------------------------------------
run_phase "1+2a (lockfile/node_modules/IOC files)" phase1_scan
run_phase "2b (persistence + pyz)"                 phase2_extras
run_phase "2c (campaign strings)"                  phase2_strings
run_phase "3  (network / dns / history)"           phase3_network
run_phase "4  (hardening: min-release-age guards)" phase4_hardening

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

    slack_err=$(with_timeout 15 /usr/bin/curl --silent --show-error --max-time 12 \
        -H "Content-Type: application/json" \
        -X POST --data-binary "$SLACK_PAYLOAD" "$WEBHOOK_URL" 2>&1) \
        || echo "[shai-hulud-audit] WARN: Slack webhook POST failed (non-blocking): ${slack_err:-no detail}"
fi

set -u

log "audit complete: status=$STATUS red=$RED_COUNT yellow=$YELLOW_COUNT roots=${#SCAN_ROOTS[@]} duration=${RUN_DURATION}s"

if [[ "$STATUS" == "GREEN" ]]; then
    exit 0
else
    exit 1
fi
