#!/usr/bin/env python3
"""
Sync Kandji ADE (Apple Business Manager) devices into a CSV file.

Python port of the "pullKandjiDataADE" Apps Script. Pulls the list of
Automated Device Enrollment devices and writes Serial Number + Model.

Credentials are read from environment variables (or a local .env file):
    KANDJI_API_URL_ADE     the ADE / ABM devices endpoint
    KANDJI_API_TOKEN       same token used by iru_sync.py

Usage:
    python iru_abm.py                    # writes iru_abm.csv
    python iru_abm.py --out foo.csv      # custom output path
"""

import argparse
import csv
import os
import sys

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
KANDJI_API_URL_ADE = os.environ.get("KANDJI_API_URL_ADE")
KANDJI_API_TOKEN = os.environ.get("KANDJI_API_TOKEN")

HEADERS = ["Serial Number", "Model"]


# ----------------------------------------------------
# MAIN
# ----------------------------------------------------
def pull_kandji_data_ade(out_path="iru_abm.csv"):
    _require_config()

    all_devices = fetch_kandji_data(KANDJI_API_URL_ADE, KANDJI_API_TOKEN)
    if not all_devices:
        print("No devices found.")
        return

    rows = [
        [device.get("serial_number") or "N/A", device.get("model") or "N/A"]
        for device in all_devices
    ]

    with open(out_path, "w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(HEADERS)
        writer.writerows(rows)

    print(f"Synced {len(rows)} ADE devices with {len(HEADERS)} columns -> {out_path}")


# ----------------------------------------------------
# HELPERS
# ----------------------------------------------------
def fetch_kandji_data(url, token):
    """Page through the Kandji ADE endpoint until exhausted.

    The ADE endpoint uses DRF-style page pagination: the response is a dict with
    `count`, `next`, `previous`, and `results`. Crucially it IGNORES `limit` and
    `offset` (always returns a full page of the first results), so we must follow
    the `next` link rather than incrementing an offset — otherwise the same page
    repeats forever. If the endpoint ever returns a bare list, we take it as-is.
    """
    all_devices = []
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    }
    next_url = url
    while next_url:
        resp = requests.get(next_url, headers=headers)
        if resp.status_code != 200:
            raise RuntimeError(f"Error {resp.status_code}: {resp.text}")

        data = resp.json()
        if isinstance(data, list):
            all_devices.extend(data)
            break

        devices_on_page = data.get("results", [])
        all_devices.extend(devices_on_page)

        total = data.get("count")
        suffix = f" of {total}" if total is not None else ""
        print(f"Fetched {len(all_devices)}{suffix} devices so far...")

        next_url = data.get("next")

    return all_devices


def _require_config():
    missing = [
        name
        for name, val in (
            ("KANDJI_API_URL_ADE", KANDJI_API_URL_ADE),
            ("KANDJI_API_TOKEN", KANDJI_API_TOKEN),
        )
        if not val
    ]
    if missing:
        sys.exit(f"Missing required environment variables: {', '.join(missing)}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Sync Kandji ADE (ABM) devices to CSV.")
    parser.add_argument(
        "--out", default="iru_abm.csv", help="Output CSV path (default: iru_abm.csv)"
    )
    args = parser.parse_args()
    pull_kandji_data_ade(args.out)
