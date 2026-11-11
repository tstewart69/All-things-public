#!/usr/bin/env python3
"""
Sync Intune managed devices (Windows + macOS) into a CSV file.

Python port of the "syncIntuneDevices" Apps Script. Pulls all Windows and macOS
managed devices from Microsoft Graph, including unassigned devices (the User
column is left blank when no user is assigned).

Credentials are read from environment variables (or a local .env file):
    INTUNE_TENANT_ID
    INTUNE_CLIENT_ID
    INTUNE_CLIENT_SECRET

The app registration needs the Graph application permission
"DeviceManagementManagedDevices.Read.All" (admin-consented).

Usage:
    python intune_sync.py                    # writes intune_devices.csv
    python intune_sync.py --out foo.csv      # custom output path
"""

import argparse
import csv
import os
import re
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
INTUNE_TENANT_ID = os.environ.get("INTUNE_TENANT_ID")
INTUNE_CLIENT_ID = os.environ.get("INTUNE_CLIENT_ID")
INTUNE_CLIENT_SECRET = os.environ.get("INTUNE_CLIENT_SECRET")

SELECT_FIELDS = ",".join(
    [
        "deviceName",
        "userPrincipalName",
        "operatingSystem",
        "serialNumber",
        "lastSyncDateTime",
        "id",
        "model",
        "manufacturer",
        "osVersion",
        "complianceState",
    ]
)

HEADERS = [
    "Serial Number",
    "Device Name",
    "User",
    "Last Contact",
    "Model",
    "Manufacturer",
    "OS Version",
    "Compliance State",
]


# ----------------------------------------------------
# MAIN
# ----------------------------------------------------
def sync_intune_devices(out_path="intune_devices.csv"):
    _require_config()

    print("Authenticating with Microsoft Graph...")
    token = get_microsoft_graph_token()

    print("Fetching Intune device list...")
    devices = get_intune_devices(token)
    if not devices:
        print("No Windows or Mac devices found in Intune.")
        return

    assigned = sum(1 for d in devices if str(d.get("userPrincipalName") or "").strip())
    unassigned = len(devices) - assigned
    print(
        f"Intune: {len(devices)} total devices "
        f"({assigned} assigned, {unassigned} unassigned)."
    )

    rows = []
    for dev in devices:
        upn = str(dev.get("userPrincipalName") or "").strip()
        rows.append(
            [
                dev.get("serialNumber") or "N/A",
                dev.get("deviceName") or "N/A",
                format_user(upn),  # blank string if no user assigned
                format_ts(dev.get("lastSyncDateTime")),
                dev.get("model") or "N/A",
                dev.get("manufacturer") or "N/A",
                dev.get("osVersion") or "N/A",
                dev.get("complianceState") or "N/A",
            ]
        )

    with open(out_path, "w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(HEADERS)
        writer.writerows(rows)

    print(
        f"Success! Pulled {len(devices)} devices "
        f"({assigned} assigned, {unassigned} unassigned) -> {out_path}"
    )


# ----------------------------------------------------
# HELPERS
# ----------------------------------------------------
def get_microsoft_graph_token():
    url = f"https://login.microsoftonline.com/{INTUNE_TENANT_ID}/oauth2/v2.0/token"
    resp = requests.post(
        url,
        data={
            "client_id": INTUNE_CLIENT_ID,
            "scope": "https://graph.microsoft.com/.default",
            "client_secret": INTUNE_CLIENT_SECRET,
            "grant_type": "client_credentials",
        },
    )
    data = resp.json()
    if not data.get("access_token"):
        raise RuntimeError(
            "Microsoft Auth Failed: " + (data.get("error_description") or "Unknown Error")
        )
    return data["access_token"]


def get_intune_devices(token):
    """Page through managed devices (Windows + macOS), following @odata.nextLink."""
    all_devices = []
    url = (
        "https://graph.microsoft.com/beta/deviceManagement/managedDevices"
        "?$filter=operatingSystem eq 'Windows' or operatingSystem eq 'macOS'"
        f"&$select={SELECT_FIELDS}"
    )
    headers = {"Authorization": f"Bearer {token}"}

    while url:
        resp = requests.get(url, headers=headers)
        if resp.status_code != 200:
            raise RuntimeError(f"Error {resp.status_code}: {resp.text[:500]}")

        data = resp.json()
        if data.get("value"):
            all_devices.extend(data["value"])
            print(f"Fetched {len(all_devices)} Intune devices so far...")

        url = data.get("@odata.nextLink")

    return all_devices


def format_user(upn):
    """Turn a work email like "jane.doe@example.com" into "Jane Doe"."""
    if not upn:
        return ""
    local_part = upn.split("@", 1)[0]
    name_parts = re.split(r"[._]+", local_part)
    return " ".join(p.capitalize() for p in name_parts if p)


def format_ts(value):
    """Format an ISO 8601 timestamp as "yyyy/MM/d" (e.g. 2024/11/2); "N/A" if empty."""
    if not value:
        return "N/A"
    try:
        dt = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
        return f"{dt.year}/{dt.month:02d}/{dt.day}"
    except (ValueError, TypeError):
        return str(value)


def _require_config():
    missing = [
        name
        for name, val in (
            ("INTUNE_TENANT_ID", INTUNE_TENANT_ID),
            ("INTUNE_CLIENT_ID", INTUNE_CLIENT_ID),
            ("INTUNE_CLIENT_SECRET", INTUNE_CLIENT_SECRET),
        )
        if not val
    ]
    if missing:
        sys.exit(f"Missing required environment variables: {', '.join(missing)}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Sync Intune managed devices to CSV.")
    parser.add_argument(
        "--out",
        default="intune_devices.csv",
        help="Output CSV path (default: intune_devices.csv)",
    )
    args = parser.parse_args()
    sync_intune_devices(args.out)
