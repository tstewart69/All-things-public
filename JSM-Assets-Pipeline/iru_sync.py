#!/usr/bin/env python3
"""
Sync all Kandji (iru) MDM devices into a CSV file.

Python port of the "pullKandjiDataAll" Apps Script.

Credentials are read from environment variables (or a local .env file):
    KANDJI_API_URL      e.g. https://SUBDOMAIN.api.kandji.io/api/v1/devices
    KANDJI_API_TOKEN

The token needs Prism permissions: the device roster comes from /api/v1/devices,
but the hardware columns come from the Prism device_information category.

Usage:
    python iru_sync.py                    # writes iru_devices.csv
    python iru_sync.py --out foo.csv      # custom output path
"""

import argparse
import csv
import os
import re
import sys
import time
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
KANDJI_API_URL = os.environ.get("KANDJI_API_URL")
KANDJI_API_TOKEN = os.environ.get("KANDJI_API_TOKEN")

PAGE_LIMIT = 300        # records per page (hard API cap)
REQUEST_TIMEOUT = 60    # seconds before a single HTTP request is abandoned
MAX_RETRIES = 4         # retries for 429 / 5xx / connection failures

# Marketed drive sizes in GB. Reported capacity always sits at or a little below
# the advertised size (a "128 GB" SSD reports ~121 GB), so snapping to the
# nearest of these recovers the number on the spec sheet. Adjacent sizes are 2x
# apart, so the nearest match is never ambiguous.
MARKETED_SIZES_GB = [8, 16, 32, 64, 128, 256, 512, 1000, 2000, 4000, 8000]
SNAP_TOLERANCE = 0.12   # widest real gap seen on this fleet is 121 vs 128 (5.5%)

# /api/v1/devices pages by offset, so it needs an explicit stable sort. Without
# one the server may order rows differently between requests and offset paging
# will silently skip or duplicate devices mid-sync.
LIST_ORDERING = "serial_number"

_RETRY_STATUS = (429, 500, 502, 503, 504)

HEADERS = [
    "Device Name",
    "Platform",
    "Serial Number",
    "Model",
    "OS Version",
    "User",
    "Last Check-in",
    "Asset Tag",
    "Memory",
    "Processor",
    "Storage",
]


# ----------------------------------------------------
# MAIN
# ----------------------------------------------------
def pull_kandji_data_all(out_path="iru_devices.csv"):
    _require_config()

    # 1. Fetch every enrolled device (paged) - this is the authoritative roster
    all_devices = fetch_all_devices()
    if not all_devices:
        print("No devices found.")
        return

    # 2. Fetch hardware attributes for the whole fleet in one cursor-paged sweep
    hardware_map = fetch_hardware_map()

    # 3. Build rows
    rows = []
    no_hardware = []
    for device in all_devices:
        details = hardware_map.get(device.get("device_id"))
        if details is None:
            details = {"memory": "", "processor": "", "storage": ""}
            no_hardware.append(device.get("serial_number") or device.get("device_id"))
        user = device.get("user")
        rows.append(
            [
                device.get("device_name", "") or "",
                get_platform(device),
                device.get("serial_number", "") or "",
                device.get("model", "") or "",
                device.get("os_version", "") or "",
                user.get("name", "") if isinstance(user, dict) else "",
                format_checkin(device.get("last_check_in")),
                device.get("asset_tag", "") or "",
                details["memory"],
                details["processor"],
                details["storage"],
            ]
        )

    # 4. Write CSV
    with open(out_path, "w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(HEADERS)
        writer.writerows(rows)

    if no_hardware:
        # A device with no Prism row has never reported inventory, so its
        # Memory/Processor/Storage cells are blank. Make that visible rather than
        # letting it read as "the fleet has no hardware data".
        print(
            f"WARNING: no Prism inventory for {len(no_hardware)} of {len(rows)} "
            f"devices; hardware columns blank for: {', '.join(no_hardware[:10])}"
        )

    print(f"Synced {len(rows)} devices with {len(HEADERS)} columns -> {out_path}")


# ----------------------------------------------------
# FETCHING
# ----------------------------------------------------
def _auth_headers():
    return {
        "Authorization": f"Bearer {KANDJI_API_TOKEN}",
        "Content-Type": "application/json",
    }


def _request(url, params=None):
    """GET with a timeout and bounded retries on throttling / transient errors.

    The tenant is capped at 10,000 requests per hour, so the per-device details
    fan-out can realistically get throttled. Honor Retry-After when the server
    sends it, otherwise back off exponentially.
    """
    delay = 1.0
    for attempt in range(MAX_RETRIES + 1):
        try:
            resp = requests.get(
                url, headers=_auth_headers(), params=params, timeout=REQUEST_TIMEOUT
            )
        except requests.RequestException as exc:
            if attempt == MAX_RETRIES:
                raise
            wait = delay
            print(f"  {type(exc).__name__} on {url} - retrying in {wait:.0f}s")
        else:
            if resp.status_code not in _RETRY_STATUS or attempt == MAX_RETRIES:
                return resp
            wait = delay
            retry_after = resp.headers.get("Retry-After")
            if retry_after:
                try:
                    wait = float(retry_after)
                except ValueError:
                    pass
            print(f"  {resp.status_code} on {url} - retrying in {wait:.0f}s")

        time.sleep(wait)
        delay = min(delay * 2, 30)

    raise RuntimeError(f"Exhausted retries for {url}")  # pragma: no cover


def fetch_all_devices():
    """Page through the devices list endpoint until exhausted.

    /api/v1/devices uses limit/offset paging with a hard cap of 300 per request.
    Cursor pagination is a Prism-only feature; see fetch_prism_all() for that.
    """
    all_devices = []
    offset = 0
    while True:
        resp = _request(
            KANDJI_API_URL,
            params={
                "limit": PAGE_LIMIT,
                "offset": offset,
                "ordering": LIST_ORDERING,
            },
        )
        if resp.status_code != 200:
            raise RuntimeError(f"Error {resp.status_code}: {resp.text}")

        data = resp.json()
        devices_on_page = data if isinstance(data, list) else data.get("results", [])
        if not devices_on_page:
            break

        all_devices.extend(devices_on_page)
        print(f"Fetched {len(all_devices)} devices so far...")

        if len(devices_on_page) < PAGE_LIMIT:
            break
        offset += PAGE_LIMIT

    return all_devices


def fetch_prism_all(category, params=None, limit=PAGE_LIMIT):
    """Page through a Prism category endpoint using cursor pagination.

    Prism (/api/v1/prism/*) is the only part of the API that offers cursor paging,
    and it's what Iru recommends for large data sets. The documented contract:

      * `cursor` is an opaque token - pass it back verbatim, never parse it.
      * Send an empty `cursor` to get the first page (and the first token).
      * `cursor` and `offset` are mutually exclusive; never send both.
      * Custom `ordering` is not supported alongside a cursor, but filters are.
      * A response looks like {"limit":…, "total":…, "cursor":…, "data":[…]}; a
        null or empty `cursor` means there are no more pages.

    Example:
        macs = fetch_prism_all(
            "device_information", {"filter": '{"device__family":{"in":["Mac"]}}'}
        )
    """
    base = KANDJI_API_URL.split("/api/v1/")[0].rstrip("/")
    url = f"{base}/api/v1/prism/{category}"

    records = []
    cursor = ""  # an empty cursor requests the first page
    seen_cursors = set()
    while True:
        query = dict(params or {})
        query.pop("offset", None)  # incompatible with cursor paging
        query.pop("ordering", None)  # unsupported alongside a cursor
        query["limit"] = limit
        query["cursor"] = cursor

        resp = _request(url, params=query)
        if resp.status_code != 200:
            raise RuntimeError(f"Error {resp.status_code}: {resp.text}")

        payload = resp.json()
        page = payload.get("data") or []
        records.extend(page)
        # `total` is documented as a count but comes back null on live tenants.
        total = payload.get("total")
        print(f"Fetched {len(records)}/{total if total is not None else '?'} {category} records...")

        cursor = payload.get("cursor") or ""
        if not cursor or not page:
            break
        if cursor in seen_cursors:
            # Defensive: a repeated token would otherwise page forever.
            print(f"  Warning: repeated cursor from {category}, stopping early.")
            break
        seen_cursors.add(cursor)

    return records


def fetch_hardware_map():
    """Map device_id -> memory / processor / storage for the entire fleet.

    Prism's device_information category carries every hardware attribute this CSV
    needs, so one cursor-paged sweep (2 requests) replaces what used to be a
    /details/ call per device. Devices that have never reported inventory simply
    have no Prism row and are absent from the map.
    """
    records = fetch_prism_all("device_information")
    return {
        r["device_id"]: {
            "memory": trim_memory(r.get("memory") or ""),
            "processor": r.get("processor_name") or "",
            "storage": format_marketed_capacity(r.get("device_capacity")),
        }
        for r in records
        if r.get("device_id")
    }


# ----------------------------------------------------
# PLATFORM / FORMATTING HELPERS
# ----------------------------------------------------
def get_platform(d):
    """Determine a device's platform, checking `platform`, `device_family`,
    then falling back to inferring from the model name."""
    platform = str(d.get("platform") or "").lower()
    family = str(d.get("device_family") or "").lower()
    model = str(d.get("model") or "").lower()

    if platform == "mac" or family == "mac":
        return "Mac"
    if platform == "ipad" or family == "ipad":
        return "iPad"
    if platform == "iphone" or family == "iphone":
        return "iPhone"
    if platform in ("appletv", "tvos") or family == "appletv":
        return "Apple TV"
    if platform == "vision" or family == "vision":
        return "Vision Pro"
    # Fallback: infer from model
    if "ipad" in model:
        return "iPad"
    if "iphone" in model:
        return "iPhone"
    if "apple tv" in model:
        return "Apple TV"
    if "mac" in model or "imac" in model:
        return "Mac"
    return d.get("platform") or d.get("device_family") or "Unknown"


def trim_memory(mem):
    """Trim memory string to "X GB" (e.g. "16 GB 3733 MHz LPDDR4X" -> "16 GB")."""
    if not mem:
        return ""
    match = re.match(r"^(.*?\bGB)\b", mem, re.IGNORECASE)
    return match.group(1).strip() if match else mem


def format_marketed_capacity(capacity_gb):
    """Render Prism's `device_capacity` (GB, base-1000) as its marketed size.

    Reported capacity is the usable figure, which runs a few percent under the
    advertised size, so snap to the nearest standard size to get "128 GB" instead
    of "121 GB". Anything too far from a standard size is left as a rounded value
    rather than being forced into a wrong bucket.
    """
    if capacity_gb is None or capacity_gb == "":
        return ""
    try:
        n = float(capacity_gb)
    except (TypeError, ValueError):
        return ""
    if n <= 0:
        return ""

    nearest = min(MARKETED_SIZES_GB, key=lambda c: abs(n - c))
    if abs(n - nearest) / nearest <= SNAP_TOLERANCE:
        n = nearest

    if n >= 1000:
        return f"{n / 1000:g} TB"
    return f"{round(n):g} GB"


def format_checkin(value):
    """Format Kandji's ISO 8601 last_check_in as "yyyy/MM/d" (e.g. 2024/11/2).
    Falls back to the raw string if it can't be parsed."""
    if not value:
        return ""
    try:
        dt = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
        return f"{dt.year}/{dt.month:02d}/{dt.day}"
    except (ValueError, TypeError):
        return str(value)


# ----------------------------------------------------
# CONFIG CHECK
# ----------------------------------------------------
def _require_config():
    missing = [
        name
        for name, val in (
            ("KANDJI_API_URL", KANDJI_API_URL),
            ("KANDJI_API_TOKEN", KANDJI_API_TOKEN),
        )
        if not val
    ]
    if missing:
        sys.exit(f"Missing required environment variables: {', '.join(missing)}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Sync Kandji (iru) devices to CSV.")
    parser.add_argument(
        "--out",
        default="iru_devices.csv",
        help="Output CSV path (default: iru_devices.csv)",
    )
    args = parser.parse_args()
    pull_kandji_data_all(args.out)
