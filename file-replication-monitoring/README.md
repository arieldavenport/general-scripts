# File Replication Monitoring — Runbook

Azure-native monitoring for a robocopy mirror from an on-prem Pure SMB share to an
Azure Files share. Telemetry path: **wrapper script → Windows Event Log → Azure
Monitor Agent → Log Analytics → alerts (email)**.

Files in this package:

| File | Purpose |
|------|---------|
| `Invoke-FileReplication.ps1` | The scheduled wrapper. Runs robocopy `/MIR`, parses the result, writes EventID 1000/1001/1002. |
| `deploy-monitoring.bicep` | Log Analytics workspace, DCR + AMA, action group, and all alert rules. |
| `workbook.json` | Ops dashboard (last run, RPO lag, trend, failure history). |

---

## 1. Prerequisites (one-time, on the mover VM and storage account)

1. **Identity-based auth on the storage account.** Enable AD DS authentication on the
   Azure Files storage account and confirm your AD DS identities are syncing to
   Microsoft Entra ID (Entra Connect). Without the sync, ACLs are copied but **not
   enforced** on failover.
2. **Domain-join the Azure VM** to the same AD DS.
3. **Disallow shared key** on the storage account (`allowSharedKeyAccess = false`) so
   the job can only authenticate via Kerberos identity.
4. **Service account / gMSA** for the scheduled task. Grant it:
   - The **Storage File Data SMB Share Elevated Contributor** role on the file share
     (Elevated, because `/COPY:DATSO` writes ACLs), plus the directory/file NTFS ACLs.
   - Membership in **Backup Operators** on the VM (robocopy `/B` uses
     SeBackupPrivilege/SeRestorePrivilege to read all source files).
   - Read access to the source Pure share.
5. **Register the event source** (elevated, once):
   ```powershell
   New-EventLog -LogName Application -Source 'FileRepl'
   ```
6. **Private connectivity** from the VM to the on-prem Pure share (ExpressRoute/VPN).
   SMB 3.x encryption in transit is on by default for Azure Files.
7. **Snapshots + soft delete** on the file share, so a bad `/MIR` run can't destroy the
   only copy. The delete canary tells you it happened; snapshots let you roll back.

## 2. Deploy the monitoring stack

```bash
az deployment group create -g <resource-group> -f deploy-monitoring.bicep \
  -p vmName=<mover-vm-name> \
     storageAccountName=<files-account> \
     alertEmail=support@customer.com \
     intervalHours=4
```

`intervalHours` is the only knob you normally touch — it drives the dead-man window
(`deadmanWindowHours`, default interval + 1h) and the overrun threshold (default 80%
of the interval). Change the schedule (step 3) and `intervalHours` together.

Import the dashboard: **Azure Monitor → Workbooks → New → Advanced Editor**, paste
`workbook.json`, save, and scope it to the workspace.

## 3. Register the scheduled task (every 4 hours, configurable)

```powershell
$action  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument `
  '-NoProfile -ExecutionPolicy Bypass -File "C:\FileRepl\Invoke-FileReplication.ps1" ' +
  '-Source "\\pure-fs01\projects" -Destination "\\acct.file.core.windows.net\projects"'

# Interval lives here — keep it in step with the bicep intervalHours parameter.
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
  -RepetitionInterval (New-TimeSpan -Hours 4)

$principal = New-ScheduledTaskPrincipal -UserId 'CUSTOMER\svc-filerepl$' `
  -LogonType Password -RunLevel Highest          # gMSA: -LogonType Password

$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew `
  -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 4)

Register-ScheduledTask -TaskName 'FileReplication' -Action $action `
  -Trigger $trigger -Principal $principal -Settings $settings
```

`-MultipleInstances IgnoreNew` plus the script's own mutex are belt-and-suspenders
against overlapping cycles.

## 4. Verification (do these before calling it done)

| Test | How | Expected |
|------|-----|----------|
| Happy path | Run the task manually | EventID 1000; row appears in `Event` within ~5 min; workbook "last run" shows OK |
| Failure detection | Point `-Destination` at an unreachable path and run | EventID 1001; **alrt-filerepl-failed** fires email |
| Dead-man's switch | Disable the task for > `deadmanWindowHours` | **alrt-filerepl-deadman** fires |
| Delete canary | Set `-DeleteCanaryThreshold 0` on a run that purges files | EventID 1002; **alrt-filerepl-canary** fires |
| VM down | Stop the VM / AMA for > 15 min | **alrt-filerepl-vmdown** fires |

If an alert doesn't fire, check that AMA is healthy (`Heartbeat` table has recent rows
for the VM) and that the DCR association exists on the VM.

## Cost note

Native monitoring isn't free: Log Analytics ingestion + retention, plus a per-rule
charge for each scheduled-query alert. The DCR filters to only the `FileRepl` source
to keep ingestion tiny, and retention defaults to 30 days. That keeps this consistent
with the low-cost intent of the Tier 1 design.
