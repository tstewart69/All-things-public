#!/usr/bin/env python3
"""
Sync all NinjaOne devices into a CSV file.

Python port of the "syncAllNinjaDevices" Apps Script.

Credentials are read from environment variables (or a local .env file):
    NINJA_CLIENT_ID
    NINJA_CLIENT_SECRET
    NINJA_INSTANCE_URL     e.g. https://app.ninjarmm.com

Usage:
    python ninja_sync.py                 # writes ninja_one.csv
    python ninja_sync.py --out foo.csv   # custom output path
"""

import argparse
import csv
import json
import os
import sys
from datetime import datetime

import requests

# Load a local .env file. Prefer python-dotenv if installed, otherwise fall
# back to a small stdlib parser so no extra packages are required.
def _load_dotenv(path=".env"):
    try:
        from dotenv import load_dotenv

        load_dotenv(path)
        return
    except ImportError:
        pass

    if not os.path.exists(path):
        return
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            key = key.strip()
            value = value.strip().strip('"').strip("'")
            # Don't clobber variables already set in the real environment.
            os.environ.setdefault(key, value)


_load_dotenv()


# ----------------------------------------------------
# CONFIGURATION
# ----------------------------------------------------
NINJA_CLIENT_ID = os.environ.get("NINJA_CLIENT_ID")
NINJA_CLIENT_SECRET = os.environ.get("NINJA_CLIENT_SECRET")
NINJA_INSTANCE_URL = os.environ.get("NINJA_INSTANCE_URL")

# The columns to emit, as source keys, in output order (case-insensitive).
#
# This is an allowlist deliberately. It used to be a denylist applied to the
# union of every flattened key across all devices, which meant any field
# NinjaOne added — or a single device with a different shape — silently widened
# the CSV. On 2026-08-10 a Hyper-V host and a VM guest appeared in the tenant
# and took the file from 6 columns to 34, and the Data Manager 'Ninja One'
# adapter rejected every row with "The column count is not correct."
#
# The adapter is mapped to exactly these six columns in this order, so changing
# the list or its order means updating the adapter config to match.
INCLUDED_COLUMNS = [
    "dnsName",
    "mapped_assignedUser",
    "memory.capacity",
    "system.assetSerialNumber",
    "system.manufacturer",
    "volumes",
]

# Device classes to skip entirely (case-insensitive on nodeClass).
#
# A Hyper-V VM guest is not a tracked asset: it reports no serial number and no
# dnsName, so it would import as a nameless, serial-less object. The Hyper-V
# *host* is deliberately NOT excluded — that is real hardware that belongs in the
# CMDB, it just has no asset serial recorded in NinjaOne.
EXCLUDED_NODE_CLASSES = [
    "HYPERV_VMM_GUEST",
]

# Rename column headers (source key -> display name). Case-insensitive.
COLUMN_RENAMES = {
    "dnsName": "Device Name",
    "mapped_assignedUser": "Assigned User",
    "system.assetSerialNumber": "Serial Number",
    "system.manufacturer": "Manufacturer",
    "volumes": "Storage",
}

# Columns whose byte values should be converted to GB (1 GB = 1024^3 bytes).
# Case-insensitive.
BYTE_TO_GB_COLUMNS = [
    "memory.capacity",
]


# ----------------------------------------------------
# MAIN
# ----------------------------------------------------
def sync_all_ninja_devices(out_path="ninja_one.csv"):
    _require_config()
    token = get_access_token()

    # 1. Fetch data
    user_map = get_user_mapping(token)
    raw_devices = fetch_all_devices(token)

    if not raw_devices:
        print("No devices found.")
        return

    # 2. Drop device classes that aren't tracked assets
    skip_classes = {c.lower() for c in EXCLUDED_NODE_CLASSES}
    devices = [
        d for d in raw_devices
        if str(d.get("nodeClass") or "").lower() not in skip_classes
    ]
    skipped = len(raw_devices) - len(devices)
    if skipped:
        print(f"Skipped {skipped} device(s) in {', '.join(EXCLUDED_NODE_CLASSES)}")

    # 3. Process and flatten data
    flattened_devices = []
    for device in devices:
        flat = flatten_object(device)

        # Enrich specific fields (human readable dates / user names)
        if device.get("assignedOwnerUid"):
            flat["mapped_assignedUser"] = user_map.get(
                device["assignedOwnerUid"], "Unknown User"
            )
        if device.get("lastContact"):
            flat["mapped_lastContact"] = datetime.fromtimestamp(
                device["lastContact"]
            ).strftime("%Y-%m-%d %H:%M:%S")

        flattened_devices.append(flat)

    # 4. Resolve the allowlisted columns against the keys the API actually
    #    returned, matching case-insensitively as the renames always have.
    actual_keys = {}
    for d in flattened_devices:
        for key in d:
            actual_keys.setdefault(key.lower(), key)

    missing = [h for h in INCLUDED_COLUMNS if h.lower() not in actual_keys]
    if missing:
        # An unreported column is still emitted, blank: the adapter needs a fixed
        # column count, so dropping it would break the very check this allowlist
        # exists to protect. Say so, because it usually means NinjaOne renamed
        # the field and the data is quietly gone.
        print(
            f"WARNING: no device reported {', '.join(missing)} - "
            "column(s) will be blank for every row"
        )

    source_headers = [actual_keys.get(h.lower(), h) for h in INCLUDED_COLUMNS]

    # Build display headers using COLUMN_RENAMES (case-insensitive lookup)
    rename_map = {k.lower(): v for k, v in COLUMN_RENAMES.items()}
    display_headers = [rename_map.get(h.lower(), h) for h in INCLUDED_COLUMNS]

    # Lookup set for byte->GB conversion (case-insensitive)
    bytes_to_gb_set = {c.lower() for c in BYTE_TO_GB_COLUMNS}

    # 5. Create row data
    rows = []
    for device in flattened_devices:
        row = []
        for header in source_headers:
            val = device.get(header)
            if val is None or val == "":
                row.append("")
                continue

            # Special case: volumes -> largest volume's capacity as "X GB"/"X TB"
            if header.lower() == "volumes":
                row.append(extract_largest_volume_capacity(val))
                continue

            # Convert bytes to GB for configured columns
            if header.lower() in bytes_to_gb_set:
                try:
                    num = float(val)
                except (TypeError, ValueError):
                    num = 0
                if num > 0:
                    row.append(f"{round(num / (1024 ** 3))} GB")
                else:
                    row.append("")
                continue

            row.append(val)
        rows.append([_strip_commas(v) for v in row])

    # 6. Write to CSV
    display_headers = [_strip_commas(h) for h in display_headers]
    with open(out_path, "w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(display_headers)
        writer.writerows(rows)

    print(f"Synced {len(rows)} devices with {len(display_headers)} columns -> {out_path}")


# ----------------------------------------------------
# HELPERS
# ----------------------------------------------------
def _strip_commas(value):
    """Remove commas from a cell value so no field contains a ','."""
    return value.replace(",", "") if isinstance(value, str) else value


def flatten_object(ob, prefix=""):
    """Recursively flatten nested dicts.

    Special-cases the top-level `volumes` array so extract_largest_volume_capacity()
    can work on it. Other arrays are joined with commas.
    """
    to_return = {}

    for key, value in ob.items():
        full_key = f"{prefix}.{key}" if prefix else key

        if isinstance(value, dict):
            to_return.update(flatten_object(value, full_key))
        elif isinstance(value, list):
            # Keep top-level volumes as-is for extract_largest_volume_capacity()
            if key == "volumes" and not prefix:
                to_return[full_key] = value
            else:
                to_return[full_key] = ", ".join(
                    json.dumps(item) if isinstance(item, (dict, list)) else str(item)
                    for item in value
                )
        else:
            to_return[full_key] = value

    return to_return


def extract_largest_volume_capacity(volumes):
    """Return the largest volume's capacity formatted as "X GB" or "X TB".

    Prefers FIXED volumes (excludes USB drives, network mounts, etc).
    """
    if not isinstance(volumes, list) or not volumes:
        return ""

    candidates = [
        v for v in volumes if str(v.get("deviceType", "")).upper() == "FIXED"
    ]
    if not candidates:
        candidates = volumes

    largest_bytes = 0
    for v in candidates:
        try:
            cap = float(v.get("capacity"))
        except (TypeError, ValueError):
            continue
        if cap > largest_bytes:
            largest_bytes = cap

    if largest_bytes <= 0:
        return ""

    GB = 1024 ** 3
    TB = GB * 1024

    # Snap to common marketed drive sizes (within ~5%)
    value_gb = largest_bytes / GB
    common_gb = [128, 250, 256, 500, 512, 1000, 2000, 4000, 8000]
    for c in common_gb:
        if abs(value_gb - c) / c < 0.05:
            return f"{c // 1000} TB" if c >= 1000 else f"{c} GB"

    if largest_bytes >= TB:
        return f"{round((largest_bytes / TB) * 10) / 10} TB"
    return f"{round(value_gb)} GB"


def fetch_all_devices(token):
    url = f"{NINJA_INSTANCE_URL}/v2/devices-detailed"
    resp = requests.get(
        url,
        headers={"Authorization": f"Bearer {token}", "Accept": "application/json"},
    )
    if resp.status_code != 200:
        raise RuntimeError(f"API Error: {resp.text}")
    return resp.json()


def get_user_mapping(token):
    url = f"{NINJA_INSTANCE_URL}/v2/users"
    resp = requests.get(url, headers={"Authorization": f"Bearer {token}"})
    if resp.status_code != 200:
        return {}

    users = resp.json()
    return {u["uid"]: f"{u.get('firstName', '')} {u.get('lastName', '')}" for u in users}


def get_access_token():
    url = f"{NINJA_INSTANCE_URL}/oauth/token"
    payload = {
        "grant_type": "client_credentials",
        "client_id": NINJA_CLIENT_ID,
        "client_secret": NINJA_CLIENT_SECRET,
        "scope": "monitoring management",
    }
    resp = requests.post(url, data=payload)
    if resp.status_code != 200:
        raise RuntimeError(f"Auth Failed: {resp.text}")
    return resp.json()["access_token"]


def _require_config():
    missing = [
        name
        for name, val in (
            ("NINJA_CLIENT_ID", NINJA_CLIENT_ID),
            ("NINJA_CLIENT_SECRET", NINJA_CLIENT_SECRET),
            ("NINJA_INSTANCE_URL", NINJA_INSTANCE_URL),
        )
        if not val
    ]
    if missing:
        sys.exit(f"Missing required environment variables: {', '.join(missing)}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Sync NinjaOne devices to CSV.")
    parser.add_argument(
        "--out", default="ninja_one.csv", help="Output CSV path (default: ninja_one.csv)"
    )
    args = parser.parse_args()
    sync_all_ninja_devices(args.out)
