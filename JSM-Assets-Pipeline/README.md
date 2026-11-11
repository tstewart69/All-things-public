# JSM Assets Pipeline

> [!WARNING]
> **Use at your own risk.** I put this together using a combination of AI and my own scripting knowledge. Review the code and test it in your environment before you rely on it. The final step runs a **full cleanse-and-import** into Jira Service Management Assets, which creates and updates objects in your CMDB.

A scheduled pipeline that keeps **Jira Service Management (JSM) Assets** in sync with the tools that actually know about our hardware. Python sync scripts pull device and asset data from CrowdStrike, Intune, Kandji / Iru, Apple Business Manager, NinjaOne and Workday, write each source to a CSV, and then hand those CSVs to **Assets Data Manager**, which runs the adapters and the cleanse-and-import that land everything in Assets.

It is built to run as a **Google Cloud Run Job** on a Cloud Scheduler trigger, with every credential in Secret Manager and the CSVs on a mounted Cloud Storage bucket. The same scripts also run locally from a `.env` file.

## How it works

```
Cloud Scheduler  (weekdays 6 PM, America/Denver)
 └─ POST  …/jobs/assets-pipeline:run   (OAuth as the pipeline service account)

Cloud Run Job "assets-pipeline"  →  run_assets_pipeline.sh
 │   Env vars injected from Secret Manager (every secret labelled app=jira-assets-pipeline)
 │   gs://<bucket> mounted at OUT_DIR so the CSVs outlive the execution
 │
 ├─ 1. Sync scripts  (write CSVs to OUT_DIR, 5 s pause after each)
 │     crowdstrike_sync.py  → crowdstrike_devices.csv
 │     intune_sync.py       → intune_devices.csv
 │     iru_abm.py           → iru_abm.csv
 │     iru_sync.py          → iru_devices.csv
 │     ninja_sync.py        → ninja_one.csv
 │     workday_raas.py      → workday data.csv
 │
 ├─ 2. Assets Data Manager adapters  (dm-adapters, 5 s pause after each)
 │     Each adapter reads one CSV from OUT_DIR into the Data Manager workspace
 │
 └─ 3. Cleanse and import  (dm-cleanseimport --run "full")
       Reconciles the sources and writes the results into JSM Assets
```

Every step runs even if an earlier one fails, and the script exits non-zero if any sync script, adapter or the import fails, so the Cloud Run execution is marked failed.

## Repository layout

| File | Purpose |
|---|---|
| `run_assets_pipeline.sh` | Entry point. Runs the sync scripts, then each Data Manager adapter, then the full cleanse-and-import, and prints a summary. |
| `crowdstrike_sync.py` | CrowdStrike Falcon Mac and Windows hosts in two host groups, enriched with each device's Zero Trust Assessment score. |
| `intune_sync.py` | Intune Windows and macOS managed devices from Microsoft Graph, including devices with no assigned user. |
| `iru_sync.py` | Every Kandji / Iru device, with memory, processor and storage from the Prism `device_information` category. Storage is snapped to the marketed size (121 GB reads as 128 GB). |
| `iru_abm.py` | Kandji / Iru Automated Device Enrollment (Apple Business Manager) devices: serial number and model. |
| `ninja_sync.py` | NinjaOne devices, limited to a fixed allowlist of six columns so the Data Manager adapter's column count never changes. Skips Hyper-V VM guests. |
| `workday_raas.py` | Runs a Workday custom report (RaaS) for fixed assets and keeps only the columns the adapter needs, with dates normalised. |
| `deploy_job.sh` | Builds the container and deploys it as the Cloud Run Job, wiring in the secrets and the bucket mount. |
| `deploy_schedule.sh` | Creates or updates the Cloud Scheduler trigger for the job. |
| `.env.example` | Every variable the pipeline reads, for local runs or as the list of secrets to create. |

All dates are written as `yyyy/MM/d` so they parse the same way in every adapter.

## Prerequisites

### Source systems

| Source | What the credential needs |
|---|---|
| CrowdStrike Falcon | API client with **Hosts: Read** and **Zero Trust Assessment: Read** |
| Microsoft Intune | Entra ID app registration with the Graph application permission **DeviceManagementManagedDevices.Read.All**, admin-consented |
| Kandji / Iru | API token with device read access and **Prism** permissions |
| NinjaOne | Client-credentials API app with the `monitoring` and `management` scopes |
| Workday | An Integration System User that can run the custom report, with the report enabled as a web service |

### JSM Assets Data Manager

- A Data Manager workspace with one adapter per source, each set up to read its CSV from the absolute path in `OUT_DIR`.
- An adapters client token and a cleanse-and-import client token.
- The Atlassian **Assets Data Manager adapters client** (`dm-adapters`) and **cleanse-and-import client** (`dm-cleanseimport`) for each platform you run on. These are Atlassian downloads and are not included here. The script expects them at:

```
assets_data_manager/<platform>/assets-adapters-client/dm-adapters
assets_data_manager/<platform>/assets-cleanse-and-import-client/dm-cleanseimport
```

`<platform>` is `DM_PLATFORM`: `osx-arm64` by default for local runs, `linux-x64` in the container.

The adapter names in `run_assets_pipeline.sh` must match the names in your workspace. Out of the box the list covers Workday, NinjaOne, Iru, Apple Business Manager and CrowdStrike; add an adapter for `intune_devices.csv` to the list if you want Intune data imported too.

### Google Cloud

- A project with the Cloud Run, Cloud Build, Artifact Registry, Secret Manager and Cloud Scheduler APIs enabled.
- A Cloud Storage bucket for the CSVs (defaults to `<project>-assets-data`).
- A service account (defaults to `assets-pipeline@<project>.iam.gserviceaccount.com`) that can read the secrets, read and write the bucket, and run the job (`run.jobs.run`) so Cloud Scheduler can trigger it.

## Setup

### 1. Store the credentials in Secret Manager

Create one secret per variable in [`.env.example`](.env.example). The **secret name must be the variable name** (for example `CS_CLIENT_ID`), and each secret needs the label `app=jira-assets-pipeline`:

```bash
printf '%s' 'the-value' | gcloud secrets create CS_CLIENT_ID \
  --project=your-gcp-project-id \
  --labels=app=jira-assets-pipeline \
  --data-file=-
```

`deploy_job.sh` finds every secret with that label and maps it to an environment variable of the same name, pinned to `:latest`. A rotated secret is picked up on the next run without redeploying; a new secret needs a redeploy.

### 2. Build the container

`deploy_job.sh` deploys with `--source .`, so the folder needs a `Dockerfile` (not included here, since mine bundles the Atlassian clients). It should:

- copy this folder to `/app`, including `assets_data_manager/linux-x64/`
- install Python 3 and `requirements.txt`
- set `PROJECT_DIR=/app` and `DM_PLATFORM=linux-x64`
- run `run_assets_pipeline.sh` as the command

### 3. Deploy the job and the schedule

```bash
PROJECT=your-gcp-project-id ./deploy_job.sh
PROJECT=your-gcp-project-id ./deploy_schedule.sh
```

Every setting has an environment variable override: `PROJECT`, `REGION`, `JOB_NAME`, `SERVICE_ACCOUNT`, `BUCKET` and `OUT_DIR` for the job; `SCHEDULER_JOB`, `SCHEDULE`, `TIME_ZONE` and `SA` for the trigger. Set `GCLOUD_BIN` if `gcloud` is not on your `PATH`.

The job runs with 2 vCPU, 2 GiB of memory, a one-hour timeout and no retries, on the gen2 execution environment (required for the Cloud Storage volume mount).

Run it by hand and follow the logs:

```bash
gcloud run jobs execute assets-pipeline --region us-central1 --project your-gcp-project-id --wait
gcloud beta run jobs logs tail assets-pipeline --region us-central1 --project your-gcp-project-id
```

> [!NOTE]
> Cloud Scheduler reports success as soon as the execution is **created**, not when the pipeline finishes. Use a Cloud Monitoring alert on failed job executions to find out when a run actually fails.

## Running locally

```bash
cp .env.example .env        # fill in the values
pip install -r requirements.txt
./run_assets_pipeline.sh
```

Without `OUT_DIR`, the CSVs are written next to the scripts. Each sync script also runs on its own and takes `--out` for a custom path:

```bash
python3 iru_sync.py --out /tmp/iru_devices.csv
```

## Notes on the trickier sources

- **NinjaOne:** the column list is an allowlist on purpose. It used to be every flattened field minus a denylist, and a single Hyper-V host showing up widened the CSV from 6 columns to 34, so the adapter rejected every row. If you change `INCLUDED_COLUMNS`, update the adapter mapping to match.
- **Kandji ADE:** the endpoint ignores `limit` and `offset`, so the script follows the `next` link instead. Incrementing an offset returns the same page forever.
- **Kandji devices:** `/api/v1/devices` pages by offset, so requests are sorted by serial number to stop devices being skipped or repeated between pages. Hardware details come from one cursor-paged Prism sweep instead of one call per device.
- **CrowdStrike ZTA:** scores are fetched in batches of 40 IDs on the query string. A `414 URI Too Long` splits the batch in half and retries, and a `403` stops early because it means the API client is missing the ZTA scope.
