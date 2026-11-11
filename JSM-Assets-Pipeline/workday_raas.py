#!/usr/bin/env python3
"""
Execute a Workday RaaS (Report-as-a-Service) URL and save the output.

A Workday custom report enabled as a web service is just an authenticated GET
against its URL (e.g. .../ccx/service/customreport2/<tenant>/<owner>/<Report>).
This script fetches that URL using Basic auth (an Integration System User) and
writes the response to a file.

Credentials are read from environment variables (or a local .env file):
    WORKDAY_RAAS_URL         the report's web-service URL
    WORKDAY_RAAS_USERNAME    ISU for Basic auth, usually ISU_name@tenant
    WORKDAY_RAAS_PASSWORD    ISU password

Usage:
    python workday_raas.py                    # fetch URL, save (default format csv)
    python workday_raas.py --out report.csv   # custom output path
    python workday_raas.py --format json      # force a format if the URL has none
"""

import argparse
import csv
import io
import os
import re
import sys
from datetime import datetime
from urllib.parse import parse_qs, urlparse

import requests


# ----------------------------------------------------
# .env LOADING
# ----------------------------------------------------
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
            os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))


_load_dotenv()


# ----------------------------------------------------
# CONFIGURATION
# ----------------------------------------------------
WORKDAY_RAAS_URL = os.environ.get("WORKDAY_RAAS_URL")
WORKDAY_RAAS_USERNAME = os.environ.get("WORKDAY_RAAS_USERNAME")
WORKDAY_RAAS_PASSWORD = os.environ.get("WORKDAY_RAAS_PASSWORD")

# Save output next to this script, regardless of the current working directory.
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DEFAULT_OUTPUT = os.path.join(SCRIPT_DIR, "workday data.csv")

# Only these columns are written, in this order. Matched against the report's
# header case-insensitively, with a prefix fallback (so "Date_Placed" matches
# "Date_Placed_in_Service"). Set to an empty list to output every column.
KEEP_COLUMNS = [
    "Asset_ID",
    "Asset_Status_as_of_Period",
    "Serial_Number",
    "Supplier",
    "Date_Acquired",
    "Date_Placed_in_Service",
    "Date_Disposed",
    "Disposal_Method",
]


# ----------------------------------------------------
# URL / FORMAT HELPERS
# ----------------------------------------------------
def _effective_url(url, default_format):
    """Return the URL, adding ?format=<default> if it has no format param."""
    query = parse_qs(urlparse(url).query)
    if "format" in query:
        return url
    sep = "&" if "?" in url else "?"
    return f"{url}{sep}format={default_format}"


def _format_of(url):
    """Extract the format query value from a URL (defaults to 'csv')."""
    return parse_qs(urlparse(url).query).get("format", ["csv"])[0].lower()


def _clean_cell(cell):
    """Collapse line breaks inside a field to spaces so no record spans multiple
    physical lines. Commas and double-quotes are left intact — the CSV writer
    quotes/escapes them properly and JSM's qualifier ("\"") handles them."""
    if "\r" in cell or "\n" in cell:
        cell = cell.replace("\r\n", " ").replace("\r", " ").replace("\n", " ")
    return cell


# Slash formats tried after ISO. MM/DD is tried before DD/MM, so an unambiguous
# day-first date (day > 12) still resolves correctly, while a truly ambiguous
# value like 05/06/2026 is read as US-style May 6.
_DATE_SLASH_FORMATS = ("%m/%d/%Y", "%d/%m/%Y", "%Y/%m/%d", "%m/%d/%y", "%d/%m/%y")


def _reformat_date(value):
    """If a cell looks like a date (or datetime), return it as 'yyyy/MM/d'
    (dropping any time component). Anything that doesn't parse is returned
    unchanged, so amounts, IDs, and free text are never touched."""
    v = value.strip()
    # Gate: must contain a 4-digit run (a year) to even be considered.
    if not v or not re.search(r"\d{4}", v):
        return value
    # ISO date or datetime (optionally with Z / timezone offset).
    try:
        dt = datetime.fromisoformat(v.replace("Z", "+00:00"))
        return f"{dt.year}/{dt.month:02d}/{dt.day}"
    except ValueError:
        pass
    # Slash formats \u2014 drop any trailing time component first.
    date_part = re.split(r"[ T]", v, maxsplit=1)[0]
    for fmt in _DATE_SLASH_FORMATS:
        try:
            dt = datetime.strptime(date_part, fmt)
            return f"{dt.year}/{dt.month:02d}/{dt.day}"
        except ValueError:
            continue
    return value


def _read_csv_rows(text):
    """Parse RaaS CSV text (handling multi-line quoted fields) and return rows
    with in-field newlines flattened and date-like values reformatted to
    yyyy/MM/d. The header row is cleaned but not date-converted."""
    if text and text[0] == "\ufeff":  # strip a leading BOM if present
        text = text[1:]
    rows = []
    for i, row in enumerate(csv.reader(io.StringIO(text))):
        if i == 0:  # header row: clean only, never date-convert
            rows.append([_clean_cell(cell) for cell in row])
        else:
            rows.append([_reformat_date(_clean_cell(cell)) for cell in row])
    return rows


def _select_columns(rows):
    """Keep only KEEP_COLUMNS, in that order. Each name is matched against the
    header case-insensitively, then by prefix. Missing columns are warned and
    skipped. Returns rows unchanged if KEEP_COLUMNS is empty."""
    if not KEEP_COLUMNS or not rows:
        return rows
    header_lower = [h.strip().lower() for h in rows[0]]
    idxs = []
    for want in KEEP_COLUMNS:
        wl = want.strip().lower()
        idx = header_lower.index(wl) if wl in header_lower else next(
            (i for i, h in enumerate(header_lower) if h.startswith(wl)), None
        )
        if idx is None:
            print(f"  WARNING: requested column {want!r} not found in report; skipping.")
            continue
        idxs.append(idx)
    return [[row[i] if i < len(row) else "" for i in idxs] for row in rows]


# ----------------------------------------------------
# MAIN
# ----------------------------------------------------
def run_raas(out_path=None, default_format="csv"):
    _require_config()

    url = _effective_url(WORKDAY_RAAS_URL, default_format)
    fmt = _format_of(url)

    print(f"Executing RaaS report as {WORKDAY_RAAS_USERNAME} (format={fmt}) ...")

    resp = requests.get(
        url,
        auth=(WORKDAY_RAAS_USERNAME, WORKDAY_RAAS_PASSWORD),
        timeout=300,
    )
    if resp.status_code != 200:
        raise RuntimeError(f"RaaS request failed (HTTP {resp.status_code}): {resp.text[:500]}")

    if out_path is None:
        out_path = DEFAULT_OUTPUT

    if fmt == "csv":
        # Re-emit the CSV with in-field newlines flattened (so no record spans
        # multiple lines); commas/quotes are preserved and properly quoted.
        rows = _select_columns(_read_csv_rows(resp.text))
        with open(out_path, "w", encoding="utf-8", newline="") as f:
            writer = csv.writer(f, lineterminator="\n")
            writer.writerows(rows)
        data_rows = max(len(rows) - 1, 0)  # minus header
        cols = len(rows[0]) if rows else 0
        print(f"Saved RaaS report ({data_rows} data rows, {cols} columns) -> {out_path}")
    else:
        with open(out_path, "w", encoding="utf-8", newline="") as f:
            f.write(resp.text)
        print(f"Saved RaaS report ({len(resp.text)} chars) -> {out_path}")
    return out_path


def _require_config():
    missing = [
        name
        for name, val in (
            ("WORKDAY_RAAS_URL", WORKDAY_RAAS_URL),
            ("WORKDAY_RAAS_USERNAME", WORKDAY_RAAS_USERNAME),
            ("WORKDAY_RAAS_PASSWORD", WORKDAY_RAAS_PASSWORD),
        )
        if not val
    ]
    if missing:
        sys.exit(f"Missing required environment variables: {', '.join(missing)}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Execute a Workday RaaS report URL.")
    parser.add_argument("--out", default=None, help="Output file path (default: 'workday data.csv' next to the script)")
    parser.add_argument(
        "--format",
        default="csv",
        help="Format to request if the URL has no format param (csv, json, simplexml). Default: csv",
    )
    args = parser.parse_args()
    run_raas(args.out, default_format=args.format)
