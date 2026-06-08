#Requires -Version 3.0
<#
.SYNOPSIS
    Very basic Exchange 2016 health check. Read-only.

.DESCRIPTION
    Runs a short, safe set of native health checks and prints a colour-coded PASS / WARN
    / FAIL summary, optionally exporting it to CSV. Checks performed:

        1. Server services   - Test-ServiceHealth: are all required services running?
        2. Databases         - Get-MailboxDatabase -Status: mounted? last full backup age?
        3. Database copies    - Get-MailboxDatabaseCopyStatus: status, copy/replay queue,
                               content index (DAG only; skipped on a standalone server).
        4. Replication       - Test-ReplicationHealth on each DAG member (DAG only).
        5. Transport queues  - Get-Queue: any queue above the message threshold?
        6. Disk space        - free space on each Exchange server's fixed disks (WinRM).

    Every check is wrapped so one failure (e.g. no DAG) degrades to a SKIP rather than
    aborting the run. Nothing here changes Exchange state -- safe to hand to an admin.

    This covers the everyday "is it healthy?" questions in the spirit of Paul Cunningham's
    Test-ExchangeServerHealth.ps1 (MIT, archived 2020, only validated through 2013):
        https://github.com/cunninghamp/Test-ExchangeServerHealth.ps1
    For a deep, *currently maintained* report (build numbers, CVE/SU level, TLS, sizing)
    use Microsoft's official HealthChecker.ps1 from CSS-Exchange:
        https://microsoft.github.io/CSS-Exchange/Diagnostics/HealthChecker/

.PARAMETER BackupWarningHours
    Flag a database whose last full backup is older than this. Default 24.

.PARAMETER QueueWarningCount
    Flag a transport queue holding more than this many messages. Default 25.

.PARAMETER DiskWarningPercent
    Flag a disk with less than this percent free. Default 15.

.PARAMETER OutputFile
    Optional CSV path for the result rows. If omitted, results print to the console only.

.EXAMPLE
    .\Test-ExchangeHealth.ps1
    Run all checks and print the summary to the console.

.EXAMPLE
    .\Test-ExchangeHealth.ps1 -OutputFile C:\Temp\ExHealth.csv -BackupWarningHours 36
    Run with a looser backup window and also write a CSV.

.NOTES
    Run from the Exchange Management Shell (EMS). The disk-space check uses CIM/WinRM
    against each Exchange server, so the account needs remote WMI rights (local admin on
    the Exchange servers is sufficient); if WinRM is blocked, that check reports SKIP.
    Account needs at least View-Only Organization Management for the Exchange checks.
#>
[CmdletBinding()]
param(
    [int]    $BackupWarningHours = 24,
    [int]    $QueueWarningCount  = 25,
    [int]    $DiskWarningPercent = 15,
    [string] $OutputFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-Command Get-ExchangeServer -ErrorAction SilentlyContinue)) {
    throw "Exchange cmdlets not found. Run this from the Exchange Management Shell (EMS)."
}

$results = New-Object System.Collections.Generic.List[object]
function Add-Result {
    param([string] $Check, [string] $Target, [ValidateSet('PASS','WARN','FAIL','SKIP')] [string] $Status, [string] $Detail)
    $results.Add([PSCustomObject][ordered]@{
        Check = $Check; Target = $Target; Status = $Status; Detail = $Detail
    })
}

$exServers = Get-ExchangeServer | Where-Object { $_.ServerRole -match 'Mailbox' }

# 1. Required services per server -------------------------------------------------
Write-Host "[1/6] Service health..." -ForegroundColor Cyan
foreach ($srv in $exServers) {
    try {
        $svc = Test-ServiceHealth -Server $srv.Name -ErrorAction Stop
        $down = $svc | Where-Object { -not $_.RequiredServicesRunning }
        if ($down) {
            $missing = ($down | ForEach-Object { $_.ServicesNotRunning } | Sort-Object -Unique) -join ', '
            Add-Result 'Services' $srv.Name 'FAIL' "Not running: $missing"
        } else {
            Add-Result 'Services' $srv.Name 'PASS' 'All required services running'
        }
    } catch { Add-Result 'Services' $srv.Name 'SKIP' $_.Exception.Message }
}

# 2. Database mount state + last full backup --------------------------------------
Write-Host "[2/6] Database mount + backup age..." -ForegroundColor Cyan
foreach ($db in (Get-MailboxDatabase -Status)) {
    if (-not $db.Mounted) {
        Add-Result 'Database' $db.Name 'FAIL' 'Dismounted'
        continue
    }
    if (-not $db.LastFullBackup) {
        Add-Result 'Database' $db.Name 'WARN' 'Mounted, but no full backup recorded'
    }
    elseif ($db.LastFullBackup -lt (Get-Date).AddHours(-$BackupWarningHours)) {
        $age = [int]((Get-Date) - $db.LastFullBackup).TotalHours
        Add-Result 'Database' $db.Name 'WARN' "Mounted; last full backup ${age}h ago"
    }
    else {
        Add-Result 'Database' $db.Name 'PASS' "Mounted; backed up $($db.LastFullBackup)"
    }
}

# 3. Database copy status (DAG only) ----------------------------------------------
Write-Host "[3/6] Database copy status..." -ForegroundColor Cyan
foreach ($srv in $exServers) {
    try {
        $copies = Get-MailboxDatabaseCopyStatus -Server $srv.Name -ErrorAction Stop
        foreach ($c in $copies) {
            $healthy = $c.Status -in @('Healthy','Mounted','DisconnectedAndHealthy')
            $indexOk = $c.ContentIndexState -in @('Healthy','Disabled') -or $null -eq $c.ContentIndexState
            if ($healthy -and $c.CopyQueueLength -le 10 -and $c.ReplayQueueLength -le 10 -and $indexOk) {
                Add-Result 'DBCopy' $c.Name 'PASS' "$($c.Status); CQ=$($c.CopyQueueLength) RQ=$($c.ReplayQueueLength) Index=$($c.ContentIndexState)"
            } else {
                Add-Result 'DBCopy' $c.Name 'WARN' "$($c.Status); CQ=$($c.CopyQueueLength) RQ=$($c.ReplayQueueLength) Index=$($c.ContentIndexState)"
            }
        }
    } catch { Add-Result 'DBCopy' $srv.Name 'SKIP' 'No copy status (standalone server?)' }
}

# 4. Replication health (DAG members only) ----------------------------------------
# Use Get-MailboxServer here -- it exposes DatabaseAvailabilityGroup, which
# Get-ExchangeServer does not, so we can cheaply tell DAG members from standalones.
Write-Host "[4/6] DAG replication health..." -ForegroundColor Cyan
foreach ($srv in (Get-MailboxServer)) {
    if (-not $srv.DatabaseAvailabilityGroup) {
        Add-Result 'Replication' $srv.Name 'SKIP' 'Not a DAG member'
        continue
    }
    try {
        $rep  = Test-ReplicationHealth -Identity $srv.Name -ErrorAction Stop
        $fail = $rep | Where-Object { $_.Result.Value -eq 'Failed' }
        if ($fail) {
            Add-Result 'Replication' $srv.Name 'FAIL' (($fail.Check) -join ', ')
        } else {
            Add-Result 'Replication' $srv.Name 'PASS' 'All replication checks passed'
        }
    } catch { Add-Result 'Replication' $srv.Name 'SKIP' $_.Exception.Message }
}

# 5. Transport queues -------------------------------------------------------------
Write-Host "[5/6] Transport queues..." -ForegroundColor Cyan
foreach ($srv in (Get-ExchangeServer | Where-Object { $_.ServerRole -match 'Mailbox|Hub|Edge' })) {
    try {
        $big = Get-Queue -Server $srv.Name -ErrorAction Stop |
               Where-Object { $_.MessageCount -gt $QueueWarningCount -and $_.Identity -notlike '*\Shadow\*' }
        if ($big) {
            $detail = ($big | ForEach-Object { "$($_.Identity)=$($_.MessageCount)" }) -join '; '
            Add-Result 'Queues' $srv.Name 'WARN' $detail
        } else {
            Add-Result 'Queues' $srv.Name 'PASS' "No queue over $QueueWarningCount"
        }
    } catch { Add-Result 'Queues' $srv.Name 'SKIP' $_.Exception.Message }
}

# 6. Disk free space (WinRM/CIM) --------------------------------------------------
Write-Host "[6/6] Disk space..." -ForegroundColor Cyan
foreach ($srv in $exServers) {
    try {
        $disks = Get-CimInstance Win32_LogicalDisk -ComputerName $srv.Name `
                    -Filter 'DriveType=3' -ErrorAction Stop
        foreach ($d in $disks) {
            $pct = [math]::Round(($d.FreeSpace / $d.Size) * 100, 1)
            $freeGB = [math]::Round($d.FreeSpace / 1GB, 1)
            if ($pct -lt $DiskWarningPercent) {
                Add-Result 'Disk' "$($srv.Name) $($d.DeviceID)" 'WARN' "$pct% free (${freeGB} GB)"
            } else {
                Add-Result 'Disk' "$($srv.Name) $($d.DeviceID)" 'PASS' "$pct% free (${freeGB} GB)"
            }
        }
    } catch { Add-Result 'Disk' $srv.Name 'SKIP' 'WinRM/WMI unavailable' }
}

# Output --------------------------------------------------------------------------
Write-Host ""
$colour = @{ PASS = 'Green'; WARN = 'Yellow'; FAIL = 'Red'; SKIP = 'DarkGray' }
foreach ($r in $results) {
    Write-Host ("{0,-5} {1,-12} {2,-28} {3}" -f $r.Status, $r.Check, $r.Target, $r.Detail) `
        -ForegroundColor $colour[$r.Status]
}

$counts = $results | Group-Object Status | ForEach-Object { "$($_.Name)=$($_.Count)" }
Write-Host ""
Write-Host ("Summary: " + ($counts -join '  ')) -ForegroundColor Cyan

if ($OutputFile) {
    $results | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8
    Write-Host "Wrote results -> $OutputFile" -ForegroundColor Green
}

# Non-zero exit if anything actually failed, so it's schedulable.
if ($results | Where-Object Status -eq 'FAIL') { exit 1 } else { exit 0 }
