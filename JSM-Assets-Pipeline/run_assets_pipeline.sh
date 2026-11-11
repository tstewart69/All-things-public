#!/usr/bin/env bash
#
# Runs the Assets Data Manager pipeline:
#   1. Python sync scripts that refresh the source CSVs (5s pause after each)
#   2. Each adapter (5s pause after each)
#   3. Then the cleanse-and-import (10s pause before it)
#
# Tokens and workspace id come from the environment (keys DM_WORKSPACE_ID,
# DM_ADAPTERS_TOKEN, DM_IMPORT_TOKEN), falling back to .env when they are not
# already set, so no secrets live in this file. On Cloud Run the environment is
# populated from Secret Manager and no .env file exists.

set -u  # error on undefined variables

# ----------------------------------------------------
# CONFIG
# ----------------------------------------------------
# Both are overridable so the same script runs locally on macOS and inside the
# Linux container, where the code lives at /app and the binaries are linux-x64.
# Defaults to the folder this script lives in.
PROJECT_DIR="${PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
DM_PLATFORM="${DM_PLATFORM:-osx-arm64}"
BASE="$PROJECT_DIR/assets_data_manager/$DM_PLATFORM"
ADAPTERS_DIR="$BASE/assets-adapters-client"
IMPORT_DIR="$BASE/assets-cleanse-and-import-client"
ENV_FILE="$PROJECT_DIR/.env"

# Where the sync scripts write their CSVs. Defaults to PROJECT_DIR, which is
# exactly the previous behaviour locally. In the container this is set to the
# absolute path the Data Manager adapters are configured to read from, and a
# GCS bucket is mounted there so the CSVs outlive the execution.
OUT_DIR="${OUT_DIR:-$PROJECT_DIR}"

# Python sync scripts to run first, as "script|output.csv". The output name has
# to be explicit because the adapters read the CSVs by absolute path, so the
# scripts are invoked with --out rather than relying on their cwd-relative
# defaults. The names match each script's own default, so nothing changes for a
# local run where OUT_DIR is PROJECT_DIR.
PY_SCRIPTS=(
  "crowdstrike_sync.py|crowdstrike_devices.csv"
  "intune_sync.py|intune_devices.csv"
  "iru_abm.py|iru_abm.csv"
  "iru_sync.py|iru_devices.csv"
  "ninja_sync.py|ninja_one.csv"
  "workday_raas.py|workday data.csv"
)

# Resolve a credential: prefer an already-exported environment variable (how
# Cloud Run injects secrets), otherwise read it from .env. The .env read avoids
# sourcing the file, because it contains a URL with & and ? that bash must not
# execute. Returns everything after the first =.
read_env() {
  local key="$1" line
  if [ -n "${!key:-}" ]; then
    printf '%s' "${!key}"
    return 0
  fi
  [ -f "$ENV_FILE" ] || return 1
  line=$(grep -m1 "^${key}=" "$ENV_FILE") || return 1
  line="${line#*=}"        # strip up to and including the first =
  line="${line%$'\r'}"     # strip a trailing CR if the file has CRLF endings
  printf '%s' "$line"
}

WORKSPACE_ID="$(read_env DM_WORKSPACE_ID)"
ADAPTERS_TOKEN="$(read_env DM_ADAPTERS_TOKEN)"
IMPORT_TOKEN="$(read_env DM_IMPORT_TOKEN)"

# Fail fast if any credential is missing from .env.
for pair in "DM_WORKSPACE_ID:$WORKSPACE_ID" "DM_ADAPTERS_TOKEN:$ADAPTERS_TOKEN" "DM_IMPORT_TOKEN:$IMPORT_TOKEN"; do
  if [ -z "${pair#*:}" ]; then
    echo "ERROR: ${pair%%:*} is missing or empty in $ENV_FILE"
    exit 1
  fi
done

# Adapters to run, in order. These are the adapter names as configured in your
# Assets Data Manager workspace; change them to match yours.
ADAPTERS=(
  "workday assets"
  "Ninja One"
  "Iru Devices"
  "Apple Business Manager"
  "Crowdstrike End User Devices"
)

# ----------------------------------------------------
# RUN PYTHON SYNC SCRIPTS (refresh source CSVs)
# ----------------------------------------------------
cd "$PROJECT_DIR" || { echo "ERROR: cannot cd to $PROJECT_DIR"; exit 1; }

mkdir -p "$OUT_DIR" || { echo "ERROR: cannot create OUT_DIR $OUT_DIR"; exit 1; }
echo "==> CSV output directory: $OUT_DIR"

py_fail_count=0
for entry in "${PY_SCRIPTS[@]}"; do
  script="${entry%%|*}"          # text before the first |
  csv_name="${entry#*|}"         # text after the first |
  out_file="$OUT_DIR/$csv_name"
  echo "==> Running sync script: $script -> $out_file"
  python3 "$script" --out "$out_file"
  status=$?
  if [ $status -ne 0 ]; then
    echo "!!! Script '$script' exited with status $status"
    py_fail_count=$((py_fail_count + 1))
  fi
  echo "--- waiting 5s ---"
  sleep 5
done

# ----------------------------------------------------
# RUN ADAPTERS
# ----------------------------------------------------
cd "$ADAPTERS_DIR" || { echo "ERROR: cannot cd to $ADAPTERS_DIR"; exit 1; }

fail_count=0
for name in "${ADAPTERS[@]}"; do
  echo "==> Running adapter: $name"
  ./dm-adapters --run "$name" --token "$ADAPTERS_TOKEN" --workspace-id "$WORKSPACE_ID"
  status=$?
  if [ $status -ne 0 ]; then
    echo "!!! Adapter '$name' exited with status $status"
    fail_count=$((fail_count + 1))
  fi
  echo "--- waiting 5s ---"
  sleep 5
done

# ----------------------------------------------------
# CLEANSE + IMPORT
# ----------------------------------------------------
cd "$IMPORT_DIR" || { echo "ERROR: cannot cd to $IMPORT_DIR"; exit 1; }

echo "==> waiting 10s before cleanse/import ..."
sleep 10

echo "==> Running cleanse/import: full"
./dm-cleanseimport --run "full" --token "$IMPORT_TOKEN" --workspace-id "$WORKSPACE_ID"
import_status=$?

# ----------------------------------------------------
# SUMMARY
# ----------------------------------------------------
echo
echo "===== Pipeline complete ====="
echo "Sync scripts with a non-zero exit: $py_fail_count of ${#PY_SCRIPTS[@]}"
echo "Adapters with a non-zero exit:     $fail_count of ${#ADAPTERS[@]}"
echo "Cleanse/import exit status:        $import_status"

# Exit non-zero if anything failed, so it's automation-friendly.
if [ $py_fail_count -ne 0 ] || [ $fail_count -ne 0 ] || [ $import_status -ne 0 ]; then
  exit 1
fi
exit 0
