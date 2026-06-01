# general-scripts

A collection of scripts and deployable packages. Each project lives in its own
subfolder with its own README.

## Index

| Project | What it does | Stack |
|---------|--------------|-------|
| [`file-replication-monitoring/`](file-replication-monitoring/) | Azure-native monitoring for a robocopy `/MIR` mirror from an on-prem Pure SMB share to Azure Files. Wrapper script → Windows Event Log → Azure Monitor Agent → Log Analytics → email alerts. | PowerShell, Bicep, KQL |

### file-replication-monitoring

| File | Purpose |
|------|---------|
| [`Invoke-FileReplication.ps1`](file-replication-monitoring/Invoke-FileReplication.ps1) | Scheduled robocopy wrapper. Runs `/MIR`, parses the result, writes EventID 1000/1001/1002 (incl. delete canary). |
| [`deploy-monitoring.bicep`](file-replication-monitoring/deploy-monitoring.bicep) | Log Analytics workspace, DCR + AMA, action group, and all alert rules. |
| [`workbook.json`](file-replication-monitoring/workbook.json) | Ops dashboard (last run, RPO lag, trend, failure history). |
| [`README.md`](file-replication-monitoring/README.md) | Full runbook: prereqs, deploy, task registration, verification matrix. |

See the [project runbook](file-replication-monitoring/README.md) to deploy.
