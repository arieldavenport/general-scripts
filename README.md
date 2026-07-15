# general-scripts

A collection of scripts and deployable packages. Each project lives in its own
subfolder with its own README.

## Index

| Project | What it does | Stack |
|---------|--------------|-------|
| [`file-replication-monitoring/`](file-replication-monitoring/) | Azure-native monitoring for a robocopy `/MIR` mirror from an on-prem Pure SMB share to Azure Files. Wrapper script → Windows Event Log → Azure Monitor Agent → Log Analytics → email alerts. | PowerShell, Bicep, KQL |
| [`dnsfilter-removal/`](dnsfilter-removal/) | Uninstalls the DNSFilter Windows Roaming Client ("DNS Agent") and blocks reinstalls via hosts sinkhole + firewall, locked install dirs, and IFEO execution blocks. One-command rollback. | PowerShell |
| [`keepaware-removal/`](keepaware-removal/) | Forcefully removes the Keep Aware force-installed browser extension across Chromium browsers (and optionally Firefox) and blocks reinstalls via browser policy blocklist + hosts sinkhole + firewall. One-command rollback. | PowerShell |

### file-replication-monitoring

| File | Purpose |
|------|---------|
| [`Invoke-FileReplication.ps1`](file-replication-monitoring/Invoke-FileReplication.ps1) | Scheduled robocopy wrapper. Runs `/MIR`, parses the result, writes EventID 1000/1001/1002 (incl. delete canary). |
| [`deploy-monitoring.bicep`](file-replication-monitoring/deploy-monitoring.bicep) | Log Analytics workspace, DCR + AMA, action group, and all alert rules. |
| [`workbook.json`](file-replication-monitoring/workbook.json) | Ops dashboard (last run, RPO lag, trend, failure history). |
| [`README.md`](file-replication-monitoring/README.md) | Full runbook: prereqs, deploy, task registration, verification matrix. |

See the [project runbook](file-replication-monitoring/README.md) to deploy.

### keepaware-removal

| File | Purpose |
|------|---------|
| [`Remove-KeepAware.ps1`](keepaware-removal/Remove-KeepAware.ps1) | Main script. Removes the force-installed extension and applies the reinstall blocks. Supports `-Mode Full/Uninstall/Block/Restore` and `-WhatIf`. |
| [`Test-KeepAwareRemoval.ps1`](keepaware-removal/Test-KeepAwareRemoval.ps1) | Read-only verification. Confirms the extension is gone/blocked in every browser; exits non-zero on any failure. |
| [`README.md`](keepaware-removal/README.md) | Full runbook: what it does, prerequisites, usage, verification matrix, notes. |

## Adding a new project

Each project gets its own subfolder with a self-contained README. To add one:

1. Copy the template folder:
   ```bash
   cp -r _template my-new-project
   ```
2. Fill in `my-new-project/README.md` (description, files, prerequisites, usage,
   verification) and drop your scripts alongside it.
3. Add the project to the **Index** table above — one row with the folder link,
   a one-line description, and the stack. Add a per-file table if it helps.

`_template/` is the starting point, not a real project; leave it in place.

