# IruPulse

Open-source, headless **macOS endpoint telemetry** you can deploy and control
from Kandji (or any MDM). It's a lightweight, native-tooling alternative to
[Pulse Endpoint](https://pulseformac.dev) — no compiled binary, no Developer ID
cert, no notarization, nothing to code-sign. Just a bash collector run by a
LaunchDaemon that POSTs core system-health metrics as JSON to a webhook you own.

## How it maps to Pulse Endpoint

| Pulse Endpoint | IruPulse |
|---|---|
| Signed Swift binary | Pure `bash` + `launchd` (no signing/notarization) |
| Uploads to Splunk HEC | POSTs JSON to a **generic HTTP webhook** (Slack, custom ingest, Datadog, Elastic, `webhook.site`, …) |
| Runs headless, MDM-controlled | Runs headless via LaunchDaemon, controlled by a Config Profile |
| Config profile / plist / CLI | Config profile (`com.iru.pulse`) with local plist override |
| Queues locally on network drop | Spools failed payloads to disk, flushes on the next successful run |
| Per-metric collector toggles | `CollectCPU` / `CollectMemory` / `CollectDisk` / `CollectUptime` / `CollectThermal` |
| Alerts + thresholds + custom messages | `AlertsEnabled` + per-metric thresholds fire templated alerts to an alert webhook, with cooldown |
| 8 collectors | **Core system** collectors (v1): CPU, memory, disk + I/O, uptime, thermal |

## What it collects

One JSON object per run:

```json
{
  "schema": "iru.pulse/v1",
  "timestamp": "2026-08-05T17:00:00Z",
  "device": {
    "hostname": "MBP-of-someone",
    "serial": "C02XXXXXXXXX",
    "model": "Mac15,7",
    "console_user": "jdoe",
    "os_name": "macOS",
    "os_version": "15.5",
    "os_build": "24F74"
  },
  "metrics": {
    "cpu":    { "cores": 12, "usage_percent": 8.4, "load_1m": 1.9, "load_5m": 1.7, "load_15m": 1.5 },
    "memory": { "total_bytes": 38654705664, "used_percent": 61, "free_percent": 39 },
    "disk":   { "total_kb": 994662584, "used_kb": 412000000, "available_kb": 560000000,
                "used_percent": 42, "io_kb_per_transfer": 18.2, "io_transfers_per_sec": 12, "io_mb_per_sec": 0.21 },
    "uptime_seconds": 486120,
    "thermal": { "cpu_speed_limit": 100, "throttled": false }
  },
  "tags": "engineering-us"
}
```

Missing values serialize as `null` rather than breaking the payload.

## Repository layout

| File | What it is |
|---|---|
| `pulse-collector.sh` | The agent (canonical, reviewable source). Reads config, collects metrics, POSTs, spools on failure. |
| `com.iru.pulse.daemon.plist` | Reference LaunchDaemon (the installer writes its own copy with your interval). |
| `com.iru.pulse.mobileconfig` | Config Profile: `WebhookURL`, `Enabled`, `CollectionInterval`, `ExtraTags`. **Edit before deploying.** |
| `IruPulse_Install.sh` | Self-contained installer (embeds the collector) — use as a Kandji Custom Script. |
| `IruPulse_Uninstall.sh` | Removes the agent, daemon, and local state. |
| `IruPulse_Audit.sh` | Kandji audit script (pair with the installer as remediation). |

## Configuration keys (`com.iru.pulse`)

Grouped like Pulse's Configuration Reference. Every key is a managed preference —
set them in the Config Profile (or a local plist for testing).

### General

| Key | Type | Default | Meaning |
|---|---|---|---|
| `WebhookURL` | String | *(none)* | **Required.** Endpoint that receives the telemetry JSON POST. Nothing ships until this is set. |
| `Enabled` | Boolean | `false` | Master on/off. `false` = agent no-ops every run (MDM kill switch) without uninstalling. |
| `CollectionInterval` | Integer | `300` | Seconds between runs. Also stamped into the daemon's `StartInterval` at install (floor 60s). |
| `ExtraTags` | String | *(empty)* | Free-form label echoed into every payload (site/team/env). |

### Metric collection (toggles)

| Key | Type | Default | Meaning |
|---|---|---|---|
| `CollectCPU` | Boolean | `true` | CPU cores, usage %, load averages. |
| `CollectMemory` | Boolean | `true` | Total bytes, used/free %. |
| `CollectDisk` | Boolean | `true` | Boot-volume capacity + I/O. |
| `CollectUptime` | Boolean | `true` | Seconds since boot. |
| `CollectThermal` | Boolean | `true` | CPU speed limit + throttle flag. |

A disabled collector is skipped (no work done) and its payload section serializes
as `null` — so consumers can tell "off" from "failed".

### Alerts

| Key | Type | Default | Meaning |
|---|---|---|---|
| `AlertsEnabled` | Boolean | `false` | Evaluate thresholds each run and POST an alert on breach. |
| `AlertWebhookURL` | String | *(empty)* | Where alerts POST. Empty = reuse `WebhookURL`. |
| `AlertCooldown` | Integer | `3600` | Min seconds between repeat alerts of the **same type**, per device. |
| `CPUAlertThreshold` | Integer | `90` | Alert when CPU usage % ≥ this. `0` disables. |
| `MemoryAlertThreshold` | Integer | `90` | Alert when memory used % ≥ this. `0` disables. |
| `DiskAlertThreshold` | Integer | `90` | Alert when disk used % ≥ this. `0` disables. |
| `ThermalAlertEnabled` | Boolean | `true` | Alert whenever the CPU is thermally throttled. |

An alert POSTs `{"text": "<message>", "alert": {type, value, threshold, device, timestamp}}`
— the `text` field renders in Slack; any other ingest reads the structured `alert`
object. Alerts only evaluate for collectors that are enabled and returned a value.

### Custom alert messages

| Key | Type | Meaning |
|---|---|---|
| `AlertMessageCPU` | String | Template for CPU alerts. |
| `AlertMessageMemory` | String | Template for memory alerts. |
| `AlertMessageDisk` | String | Template for disk alerts. |
| `AlertMessageThermal` | String | Template for thermal alerts. |

Templates interpolate these placeholders: `{hostname}` `{serial}` `{user}`
`{value}` `{threshold}`. Delete a key to fall back to the built-in default.

> **No secrets in code.** Webhook URLs only ever come from the profile (or a
> local plist for testing) — never hardcode them into the scripts.

## Deploy from Kandji

1. **Config Profile** — edit `com.iru.pulse.mobileconfig`: set `WebhookURL`,
   set `Enabled` to `true`, adjust `CollectionInterval`/`ExtraTags`. In Kandji:
   **Library → Add → Custom Profile**, upload the file, assign to a Blueprint.
2. **Installer** — **Library → Add → Custom Script**. Paste
   `IruPulse_Install.sh`. Set **Execution Frequency** to *Run on every check-in*
   (idempotent; it re-bootstraps only when needed) or *Run once*.
   - *(Optional but recommended)* paste `IruPulse_Audit.sh` as the **Audit
     Script** and `IruPulse_Install.sh` as the **Remediation Script** so Kandji
     self-heals a missing/stopped/stale agent.
3. **Order** — assign the profile so it lands **before** the script runs. If the
   script runs first, its next check-in picks up the config; you can also
   re-run it. Changing `CollectionInterval` later: re-push the profile, then let
   the installer/remediation re-run to restamp `StartInterval`.
4. **Pause fleet-wide** — set `Enabled` to `false` in the profile and re-push.
   No uninstall needed. **Remove** entirely with `IruPulse_Uninstall.sh`.

Other MDMs (Jamf, Mosyle, Munki) work the same way: deploy the profile, run the
installer script as root.

## Manual test (real Mac)

```bash
# 1. Grab a throwaway webhook URL (e.g. https://webhook.site) then create a
#    local config override (no profile needed for testing):
sudo defaults write /Library/Preferences/com.iru.pulse WebhookURL "https://webhook.site/your-uuid"
sudo defaults write /Library/Preferences/com.iru.pulse Enabled -bool true
sudo defaults write /Library/Preferences/com.iru.pulse CollectionInterval -int 120

# 2. Install and load the daemon:
sudo bash IruPulse_Install.sh

# 3. Force a run and watch the log; confirm a POST lands on your webhook:
sudo launchctl kickstart -k system/com.iru.pulse.daemon
tail -f /var/log/iru-pulse.log

# 4. (Optional) test alerting: force a breach with a tiny threshold.
sudo defaults write /Library/Preferences/com.iru.pulse AlertsEnabled -bool true
sudo defaults write /Library/Preferences/com.iru.pulse DiskAlertThreshold -int 1
sudo launchctl kickstart -k system/com.iru.pulse.daemon   # expect a disk alert POST

# 5. Verify the kill switch: agent should no-op on the next run.
sudo defaults write /Library/Preferences/com.iru.pulse Enabled -bool false
sudo launchctl kickstart -k system/com.iru.pulse.daemon

# 6. Clean up:
sudo bash IruPulse_Uninstall.sh
sudo defaults delete /Library/Preferences/com.iru.pulse
```

You can also run the collector directly (`sudo bash pulse-collector.sh`) to see
one run's output without touching launchd.

## On-disk footprint

- Agent: `/usr/local/iru-pulse/pulse-collector.sh`
- Daemon: `/Library/LaunchDaemons/com.iru.pulse.daemon.plist`
- State: `/var/db/iru-pulse/` (`spool/` for offline payloads, `last-run.json` heartbeat)
- Log: `/var/log/iru-pulse.log`

Offline payloads are capped (500 files) so an extended outage can't fill the disk.

## Roadmap / not in v1

Deliberately scoped small. The collector and output path are structured so these
slot in without rework:

- More collectors: per-process / pinned apps, power & battery, network throughput
- Additional output backends: Splunk HEC, batched uploads
- Optional local menu-bar readout (e.g. via swiftDialog)

## License

Provided as open source for the macOS admin community. Add a `LICENSE` file
(MIT is a good default) before publishing publicly.
