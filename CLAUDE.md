# File Replication Monitoring — Project Context

Azure-native monitoring for a robocopy mirror from an **on-prem Pure FlashArray File
Services SMB share** to an **Azure Files** share. This repo is the deployable package:
the wrapper script, the monitoring IaC, the dashboard, and the runbook.

## Locked design decisions (do not re-litigate without reason)

- **Mover runs on an Azure VM** (not on-prem) → no Azure Arc; AMA installs directly.
- **Engine: robocopy** over **Kerberos / AD DS identity-based auth** — no storage
  account key, no SAS. (azcopy with a managed identity is reserved for the one-time
  initial seed only, if the dataset is large.)
- **Schedule: every 4 hours**, exposed as the single `intervalHours` parameter, which
  drives the dead-man window (interval + 1h) and overrun threshold (80% of interval).
- **New Log Analytics workspace**, single client, retention 30 days.
- **Alerts go to email** (customer support team) via one action group.
- Telemetry path: wrapper → Windows Event Log (`FileRepl` source) → AMA → Log
  Analytics → scheduled-query + metric alerts.

## Event contract

| EventID | Type | Meaning |
|---|---|---|
| 1000 | Information | Successful run (robocopy exit 0–7). JSON payload in message. |
| 1001 | Error | Failed run (exit ≥ 8) or script crash. |
| 1002 | Warning | Delete canary: target purges exceeded threshold (default 100). |

The 1000/1001 message body is `ReplicationResult {<compact JSON>}` with
`DurationSec`, `FilesCopied`, `FilesFailed`, `FilesExtra` (deletions), etc. The KQL
alerts and the workbook parse that JSON out of `RenderedDescription`.

## File map

- `Invoke-FileReplication.ps1` — scheduled wrapper. Single-instance mutex, robocopy
  `/MIR /COPY:DATSO /B`, summary parsing, event emission, local log retention.
- `deploy-monitoring.bicep` — LAW, DCR (event-log collection), AMA + association,
  action group, 5 scheduled-query alerts, storage availability metric alert.
- `workbook.json` — ops dashboard (last run, RPO lag, trend, failure history).
- `README.md` — full runbook: prereqs, deploy, task registration, verification matrix.

## Open items / next steps

- **DCR custom-table transform** — replace the regex-on-`RenderedDescription` parsing
  with a typed custom table so the overrun alert and trend queries are sturdier. This
  is the main hardening task.
- **Tune the delete-canary threshold** after observing ~1 week of normal churn.
- **Heartbeat alert** keys on `Computer == vmName`; confirm it matches the VM's OS
  hostname, not just the Azure resource name.
- Confirm AD DS identities are syncing to Entra ID, or ACLs won't be enforced on
  failover.

## Conventions

- Bicep deploys at resource-group scope.
- Keep the scheduled-task interval and the bicep `intervalHours` parameter in sync.
- This is customer infrastructure config — keep the repo private.
