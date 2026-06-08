# exchange-mailbox-health

> Two small, **read-only** PowerShell scripts to hand to an Exchange 2016 admin: one
> dumps mailbox size/usage to CSV, the other runs a very basic server health check.

Both are self-contained rewrites in the spirit of the most popular community scripts
(see [Credits](#credits)), trimmed to the essentials and hardened for Exchange 2016.
Neither script changes anything in Exchange — safe to run in production.

## Files

| File | Purpose |
|------|---------|
| `Get-MailboxSizeReport.ps1` | Per-mailbox report: item count, total size (MB/GB), deleted items, quota + % used, last logon. Sorts largest-first, exports CSV. |
| `Test-ExchangeHealth.ps1` | Basic health check: required services, DB mount + backup age, DB copy/queue/index status, DAG replication, transport queues, disk free space. Colour-coded PASS/WARN/FAIL, optional CSV. |

## Prerequisites

- Exchange Server 2016 (works on 2013/2019 too; cmdlets are the same).
- Run from the **Exchange Management Shell (EMS)** on the server, or a remote PowerShell
  session connected to it.
- Account with at least **View-Only Organization Management**. The disk-space check in
  the health script additionally needs remote WMI/WinRM rights on the Exchange servers
  (local admin is enough); without it that one check reports `SKIP`, not an error.
- Scripts may need to be unblocked first: `Unblock-File .\*.ps1`, and the session set to
  allow them: `Set-ExecutionPolicy -Scope Process RemoteSigned`.

## Usage

```powershell
# --- Mailbox size report -------------------------------------------------
.\Get-MailboxSizeReport.ps1 -All                      # whole org -> timestamped CSV
.\Get-MailboxSizeReport.ps1 -Database "DB01"          # one database
.\Get-MailboxSizeReport.ps1 -Server  "EXCH01"         # all mailboxes on a server
.\Get-MailboxSizeReport.ps1 -Mailbox jsmith           # one mailbox, on screen
.\Get-MailboxSizeReport.ps1 -All -OutputFile C:\Temp\mbx.csv

# --- Basic health check --------------------------------------------------
.\Test-ExchangeHealth.ps1                              # all checks -> console
.\Test-ExchangeHealth.ps1 -OutputFile C:\Temp\health.csv
.\Test-ExchangeHealth.ps1 -BackupWarningHours 36 -QueueWarningCount 50 -DiskWarningPercent 10
```

**Knobs you'll actually touch**

- `Get-MailboxSizeReport.ps1`: scope (`-All` / `-Server` / `-Database` / `-Mailbox`) and
  `-OutputFile`.
- `Test-ExchangeHealth.ps1`: the three thresholds — `-BackupWarningHours` (default 24),
  `-QueueWarningCount` (default 25), `-DiskWarningPercent` (default 15) — and `-OutputFile`.

The health script exits non-zero when any check is `FAIL`, so it can be wired into a
Scheduled Task or monitoring tool.

## Verification

| Test | How | Expected |
|------|-----|----------|
| Mailbox report, single | `.\Get-MailboxSizeReport.ps1 -Mailbox <you>` | One mailbox printed as a list with a non-zero `TotalSizeMB`. |
| Mailbox report, CSV | `.\Get-MailboxSizeReport.ps1 -Database <db>` | `MailboxSizeReport_*.csv` written; "Wrote N mailbox(es)…" line. |
| Health, healthy server | `.\Test-ExchangeHealth.ps1` | Services/DB/Disk rows show `PASS`; summary line prints counts. |
| Health, standalone (no DAG) | `.\Test-ExchangeHealth.ps1` | DBCopy/Replication rows show `SKIP`, not `FAIL`. |
| Health, exit code | `.\Test-ExchangeHealth.ps1; $LASTEXITCODE` | `0` when no `FAIL`, `1` when a service is down or a DB is dismounted. |

## Credits

These are lean rewrites — not forks — inspired by the canonical community scripts. If the
admin wants the full-featured originals (HTML email reports, more parameters), point them
at the sources below.

- **Get-MailboxReport.ps1** — Paul Cunningham. MIT, archived 2020.
  <https://github.com/cunninghamp/Get-MailboxReport.ps1>
- **Test-ExchangeServerHealth.ps1** — Paul Cunningham. MIT, archived 2020; only validated
  through Exchange 2013. <https://github.com/cunninghamp/Test-ExchangeServerHealth.ps1>
- **HealthChecker.ps1** (Microsoft CSS-Exchange) — the official, *actively maintained*
  deep health/sizing/SU-level report for Exchange 2013/2016/2019. Recommend this for a
  thorough audit beyond the basics here.
  <https://microsoft.github.io/CSS-Exchange/Diagnostics/HealthChecker/>

## Notes

- **Read-only by design.** No `Set-`/`Move-`/`Mount-` cmdlets are used; the scripts only
  read state. Safe to send to an admin and run during business hours.
- Sizes come from `Get-MailboxStatistics.TotalItemSize`. The size parser handles both the
  EMS object form (`.Value.ToBytes()`) and the deserialised string form
  (`"… (12,345,678 bytes)"`) you get over remote PowerShell, so it survives build changes.
- Mailboxes that have never been logged on to (no mounted DB copy) have no statistics yet
  and are skipped in the size report.
- For very large orgs the `-All` size report can take a while — `Get-MailboxStatistics`
  is one call per mailbox; scope by `-Database` or `-Server` to chunk it.
