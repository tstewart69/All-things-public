#!/bin/bash
# check-logi-aipb.sh — Kandji audit script (runs as root).
#
# Purpose: detect Logitech AI Prompt Builder on macOS endpoints. The malware
# TCLBanker ships in a trojanized Windows MSI of this app, so a Mac install
# isn't itself a TCLBanker infection — but it flags users who likely also
# have the app on Windows, where the real risk lives.
#
# Exit codes (Kandji audit convention):
#   0 = compliant   (app NOT found)
#   1 = NON-compliant (app found — review)

set -u

found=0

echo "Logitech AI Prompt Builder audit"
echo "Host: $(scutil --get ComputerName 2>/dev/null || hostname)"
echo "Date: $(date -u '+%Y-%m-%d %H:%M:%SZ')"
echo "----------------------------------------"

# Build a search list:
#   /Applications, /Library/Application Support  — system-wide
#   /Users/*/Applications, /Users/*/Library      — every real user's home
search_roots=( "/Applications" "/Library/Application Support" )
for home in /Users/*; do
  user=$(basename "$home")
  case "$user" in
    Shared|.localized|Guest) continue ;;
  esac
  [ -d "$home" ] || continue
  [ -d "$home/Applications" ] && search_roots+=("$home/Applications")
  [ -d "$home/Library/Application Support" ] && search_roots+=("$home/Library/Application Support")
done

# 1. App-bundle search.
echo "[1] App bundles"
candidates=()
for root in "${search_roots[@]}"; do
  while IFS= read -r -d '' app; do
    candidates+=("$app")
  done < <(find "$root" -maxdepth 6 -iname "Logi AI Prompt Builder.app" -print0 2>/dev/null)
done

# Dedupe (bash 3.2 compatible — no mapfile).
if [ ${#candidates[@]} -gt 0 ]; then
  deduped=()
  while IFS= read -r line; do
    deduped+=("$line")
  done < <(printf '%s\n' "${candidates[@]}" | sort -u)
  candidates=("${deduped[@]}")
fi

if [ ${#candidates[@]} -eq 0 ]; then
  echo "  none"
else
  found=1
  for app in "${candidates[@]}"; do
    plist="$app/Contents/Info.plist"
    bundle_id=""; version=""; build=""
    if [ -f "$plist" ]; then
      bundle_id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$plist" 2>/dev/null)
      version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$plist" 2>/dev/null)
      build=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$plist" 2>/dev/null)
    fi
    echo "  path:      $app"
    echo "  bundle id: ${bundle_id:-?}"
    echo "  version:   ${version:-?} (build ${build:-?})"
    cs=$(codesign -dv --verbose=2 "$app" 2>&1 | grep -E '^(Authority|TeamIdentifier)' | head -5)
    if [ -n "$cs" ]; then
      echo "  signature:"
      echo "$cs" | sed 's/^/    /'
    else
      echo "  signature: NOT SIGNED or unreadable — investigate."
    fi
    stat -f "  installed: %SB    modified: %Sm" "$app"
    echo
  done
fi

# 2. Running processes.
echo "[2] Running processes"
ps_out=$(ps -axo pid,user,etime,command 2>/dev/null \
  | grep -iE 'logi.*prompt.*builder|promptbuilder' \
  | grep -v grep || true)
if [ -z "$ps_out" ]; then
  echo "  none"
else
  found=1
  echo "$ps_out" | sed 's/^/  /'
fi

# 3. LaunchAgents/Daemons (system + every user).
echo "[3] Launch agents / daemons"
launch_paths=( "/Library/LaunchAgents" "/Library/LaunchDaemons" )
for home in /Users/*; do
  [ -d "$home/Library/LaunchAgents" ] && launch_paths+=("$home/Library/LaunchAgents")
done
launch_hits=$(grep -rilE 'logi.*prompt.*builder|promptbuilder' "${launch_paths[@]}" 2>/dev/null || true)
if [ -z "$launch_hits" ]; then
  echo "  none"
else
  found=1
  echo "$launch_hits" | sed 's/^/  /'
fi

echo "----------------------------------------"
if [ "$found" -eq 1 ]; then
  echo "RESULT: NON-COMPLIANT — Logitech AI Prompt Builder present."
  exit 1
else
  echo "RESULT: COMPLIANT — not present."
  exit 0
fi
