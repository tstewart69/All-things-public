# Iru — Kandji / Iru macOS scripts

macOS scripts and configuration profiles for Kandji / Iru device management.

| Folder | What's in it |
|---|---|
| `Security/` | Malware and supply-chain IOC detection, security audits |
| `Software-Audits/` | Per-app audit + remediation pairs (Anaconda, Keynote, Pages, Netskope, Oracle Java) |
| `OS-Updates/` | DDM OS update reminders and Safari update install |
| `Onboarding/` | Liftoff triggers, user assignment, Dock setup, guest Wi-Fi cleanup |
| `Device-Management/` | Device naming audit, battery health alerts, Touch ID for sudo |
| `Configuration-Profiles/` | Standalone `.mobileconfig` profiles (BTM, SAP Privileges, Zoom Rooms) |
| `IruPulse/` | Endpoint telemetry agent (see its own README) |

## Secrets

Don't commit API tokens, webhook URLs or passwords. Leave the variable empty
(or `REPLACE_...`) in the repo and set the real value in Kandji at deploy time.
