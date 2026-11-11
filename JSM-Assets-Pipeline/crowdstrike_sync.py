#!/usr/bin/env python3
"""
Sync CrowdStrike Falcon devices (with Zero Trust Assessment scores) into a CSV.

Python port of the "syncCrowdStrikeDevices" Apps Script. Pulls Mac + Windows
devices in two host groups, fetches per-device details, and enriches each with
its ZTA overall score from the dedicated zero-trust-assessment endpoint.

Credentials are read from environment variables (or a local .env file):
    CS_CLIENT_ID
    CS_CLIENT_SECRET
    CS_BASE_URL         e.g. https://api.crowdstrike.com
    CS_GROUP_ID_MAC     host group id for Macs
    CS_GROUP_ID_WIN     host group id for Windows

The API client needs scopes: "Hosts: Read" and "Zero Trust Assessment: Read".

Usage:
    python crowdstrike_sync.py                    # writes crowdstrike_devices.csv
    python crowdstrike_sync.py --out foo.csv      # custom output path
"""

import argparse
import csv
import os
import sys
import time
from datetime import datetime
from urllib.parse import quote

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
CS_CLIENT_ID = os.environ.get("CS_CLIENT_ID")
CS_CLIENT_SECRET = os.environ.get("CS_CLIENT_SECRET")
CS_BASE_URL = os.environ.get("CS_BASE_URL")
CS_GROUP_ID_MAC = os.environ.get("CS_GROUP_ID_MAC")
CS_GROUP_ID_WIN = os.environ.get("CS_GROUP_ID_WIN")

ID_PAGE_LIMIT = 5000      # device-id query page size
DETAILS_BATCH = 100       # ids per details POST
ZTA_BATCH = 40            # ids per ZTA GET (kept small; auto-splits on 414)

HEADERS = [
    "Hostname",
    "First Seen",
    "Last Seen",
    "OS Version",
    "Serial Number",
    "ZTA Score",
    "AID",
]


# ----------------------------------------------------
# MAIN
# ----------------------------------------------------
def sync_crowdstrike_devices(out_path="crowdstrike_devices.csv"):
    _require_config()

    print("Authenticating with Falcon...")
    token = get_crowdstrike_token()

    print("Fetching device IDs...")
    device_ids = get_falcon_device_ids(token)
    if not device_ids:
        print("Zero devices found.")
        return

    print(f"Fetching device details for {len(device_ids)} devices...")
    device_details = get_falcon_device_details_v2(token, device_ids)

    print("Fetching ZTA scores...")
    zta_score_map = get_falcon_zta_scores(token, device_ids)
    print(
        f"ZTA scores retrieved for {len(zta_score_map)} of {len(device_ids)} devices."
    )

    rows = []
    for dev in device_details:
        aid = dev.get("device_id") or ""
        zta_score = zta_score_map.get(aid, "N/A") if aid else "N/A"
        rows.append(
            [
                dev.get("hostname") or "N/A",
                format_ts(dev.get("first_seen")),
                format_ts(dev.get("last_seen")),
                dev.get("os_version") or "N/A",
                dev.get("serial_number") or "N/A",
                zta_score,
                aid or "N/A",
            ]
        )

    with open(out_path, "w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(HEADERS)
        writer.writerows(rows)

    print(
        f"Success! Pulled {len(device_details)} devices "
        f"({len(zta_score_map)} with ZTA scores) -> {out_path}"
    )


# ----------------------------------------------------
# AUTH
# ----------------------------------------------------
def get_crowdstrike_token():
    url = f"{CS_BASE_URL}/oauth2/token"
    resp = requests.post(
        url,
        data={"client_id": CS_CLIENT_ID, "client_secret": CS_CLIENT_SECRET},
    )
    if resp.status_code not in (200, 201):
        raise RuntimeError(f"Auth Failed: {resp.status_code} {resp.text}")
    return resp.json()["access_token"]


# ----------------------------------------------------
# DEVICE IDS + DETAILS
# ----------------------------------------------------
def get_falcon_device_ids(token):
    """Page through the device-id query for Mac + Windows in the two groups."""
    all_ids = []
    offset = 0
    fql = (
        f"platform_name:['Windows','Mac']"
        f"+groups:['{CS_GROUP_ID_MAC}','{CS_GROUP_ID_WIN}']"
    )
    encoded_filter = quote(fql, safe="")

    while True:
        url = (
            f"{CS_BASE_URL}/devices/queries/devices/v1"
            f"?limit={ID_PAGE_LIMIT}&offset={offset}&filter={encoded_filter}"
        )
        resp = requests.get(url, headers={"Authorization": f"Bearer {token}"})
        if resp.status_code != 200:
            raise RuntimeError(f"Error {resp.status_code}: {resp.text}")

        ids = resp.json().get("resources") or []
        all_ids.extend(ids)

        if len(ids) < ID_PAGE_LIMIT:
            break
        offset += ID_PAGE_LIMIT

    return all_ids


def get_falcon_device_details_v2(token, device_ids):
    """Fetch full device entities via the V2 POST endpoint, in batches of 100."""
    details = []
    for i in range(0, len(device_ids), DETAILS_BATCH):
        batch = device_ids[i : i + DETAILS_BATCH]
        url = f"{CS_BASE_URL}/devices/entities/devices/v2"
        resp = requests.post(
            url,
            headers={
                "Authorization": f"Bearer {token}",
                "Accept": "application/json",
                "Content-Type": "application/json",
            },
            json={"ids": batch},
        )
        if resp.status_code == 200:
            resources = resp.json().get("resources")
            if resources:
                details.extend(resources)
        time.sleep(0.3)
    return details


# ----------------------------------------------------
# ZERO TRUST ASSESSMENT SCORES
# ----------------------------------------------------
def get_falcon_zta_scores(token, device_ids):
    """Return { aid: overall_score } from the zero-trust-assessment endpoint.

    Stops early if the API key is missing the 'Zero Trust Assessment: Read'
    scope (a 403), since every subsequent call would fail the same way.
    """
    score_map = {}
    for i in range(0, len(device_ids), ZTA_BATCH):
        batch = device_ids[i : i + ZTA_BATCH]
        scores, scope_missing = _fetch_zta_batch(token, batch)
        if scope_missing:
            print(
                "ZTA endpoint returned 403 Forbidden. The API key is likely "
                "missing the 'Zero Trust Assessment: Read' scope."
            )
            break
        score_map.update(scores)
        time.sleep(0.3)
    return score_map


def _fetch_zta_batch(token, batch):
    """Fetch one ZTA batch. On a 414 (URI too long), recursively split in half.

    Returns (scores_dict, scope_missing_bool).
    """
    if not batch:
        return {}, False

    ids_param = "&".join(f"ids={quote(aid, safe='')}" for aid in batch)
    url = f"{CS_BASE_URL}/zero-trust-assessment/entities/assessments/v1?{ids_param}"

    resp = requests.get(
        url,
        headers={"Authorization": f"Bearer {token}", "Accept": "application/json"},
    )
    code = resp.status_code

    if code == 200:
        scores = {}
        for r in resp.json().get("resources") or []:
            aid = r.get("aid")
            score = None
            assessment = r.get("assessment") or {}
            if assessment.get("overall") is not None:
                score = assessment["overall"]
            elif (r.get("assessment_items") or {}).get("overall_score") is not None:
                score = r["assessment_items"]["overall_score"]
            if aid and score is not None:
                scores[aid] = score
        return scores, False

    if code == 403:
        return {}, True

    if code == 414 and len(batch) > 1:
        mid = len(batch) // 2
        left_scores, left_missing = _fetch_zta_batch(token, batch[:mid])
        if left_missing:
            return left_scores, True
        right_scores, right_missing = _fetch_zta_batch(token, batch[mid:])
        if right_missing:
            return right_scores, True
        left_scores.update(right_scores)
        return left_scores, False

    print(f"ZTA batch returned status {code}: {resp.text[:300]}")
    return {}, False


# ----------------------------------------------------
# HELPERS
# ----------------------------------------------------
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
            ("CS_CLIENT_ID", CS_CLIENT_ID),
            ("CS_CLIENT_SECRET", CS_CLIENT_SECRET),
            ("CS_BASE_URL", CS_BASE_URL),
            ("CS_GROUP_ID_MAC", CS_GROUP_ID_MAC),
            ("CS_GROUP_ID_WIN", CS_GROUP_ID_WIN),
        )
        if not val
    ]
    if missing:
        sys.exit(f"Missing required environment variables: {', '.join(missing)}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Sync CrowdStrike Falcon devices to CSV.")
    parser.add_argument(
        "--out",
        default="crowdstrike_devices.csv",
        help="Output CSV path (default: crowdstrike_devices.csv)",
    )
    args = parser.parse_args()
    sync_crowdstrike_devices(args.out)
