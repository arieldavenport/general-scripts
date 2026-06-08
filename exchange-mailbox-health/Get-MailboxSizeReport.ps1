#Requires -Version 3.0
<#
.SYNOPSIS
    Exchange 2016 mailbox size / usage report. Read-only.

.DESCRIPTION
    Walks the requested mailboxes, pulls Get-MailboxStatistics for each, and writes
    a per-mailbox report (display name, database, item count, total size, deleted-item
    size, quota and % used, last logon). Results sort largest-first and go to a CSV
    unless a single mailbox is requested, in which case they print to the console.

    This is a trimmed, self-contained rewrite in the spirit of Paul Cunningham's
    well-known Get-MailboxReport.ps1 (MIT licensed, archived 2020):
        https://github.com/cunninghamp/Get-MailboxReport.ps1
    The size logic uses the same TotalItemSize.Value approach his script popularised,
    hardened to also parse the "(12,345,678 bytes)" string form so it keeps working
    across Exchange builds. Nothing here writes to Exchange -- safe to hand to an admin.

.PARAMETER All
    Report on every mailbox in the organisation.

.PARAMETER Server
    Report on all mailboxes whose database is homed on this mailbox server.

.PARAMETER Database
    Report on all mailboxes in this mailbox database.

.PARAMETER Mailbox
    Report on a single mailbox (alias, UPN, SMTP, or name). Prints to the console.

.PARAMETER OutputFile
    CSV path for the report. Defaults to MailboxSizeReport_<yyyyMMdd_HHmmss>.csv in the
    current directory. Ignored when -Mailbox is used.

.EXAMPLE
    .\Get-MailboxSizeReport.ps1 -All
    Report every mailbox in the org to a timestamped CSV.

.EXAMPLE
    .\Get-MailboxSizeReport.ps1 -Database "DB01" -OutputFile C:\Temp\DB01.csv
    Report one database to a named CSV.

.EXAMPLE
    .\Get-MailboxSizeReport.ps1 -Mailbox jsmith
    Show one mailbox on screen.

.NOTES
    Run from the Exchange Management Shell (EMS) on the Exchange 2016 server, or from a
    remote PowerShell session connected to it. The signed-in account needs at least
    View-Only Organization Management.
#>
[CmdletBinding(DefaultParameterSetName = 'All')]
param(
    [Parameter(ParameterSetName = 'All')]      [switch] $All,
    [Parameter(ParameterSetName = 'Server')]   [string] $Server,
    [Parameter(ParameterSetName = 'Database')] [string] $Database,
    [Parameter(ParameterSetName = 'Mailbox')]  [string] $Mailbox,
    [string] $OutputFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-Command Get-Mailbox -ErrorAction SilentlyContinue)) {
    throw "Exchange cmdlets not found. Run this from the Exchange Management Shell (EMS)."
}

# Exchange returns sizes as ByteQuantifiedSize. .ToMB() exists in EMS, but a remote
# PowerShell session deserialises it to a plain string like "1.5 GB (1,610,612,736 bytes)".
# Parse the byte count out of whichever form we get so the math is build-proof.
function ConvertTo-MB {
    param($Size)
    if ($null -eq $Size) { return 0 }
    $text = $Size.ToString()
    if ($text -match '([\d,]+)\s*bytes') {
        return [math]::Round([int64]($matches[1] -replace ',', '') / 1MB, 2)
    }
    try { return [math]::Round($Size.Value.ToBytes() / 1MB, 2) } catch { return 0 }
}

# Resolve the mailbox set from whichever parameter set was chosen.
Write-Host "Collecting mailboxes..." -ForegroundColor Cyan
switch ($PSCmdlet.ParameterSetName) {
    'Server'   { $mailboxes = Get-Mailbox -Server   $Server   -ResultSize Unlimited }
    'Database' { $mailboxes = Get-Mailbox -Database $Database -ResultSize Unlimited }
    'Mailbox'  { $mailboxes = Get-Mailbox -Identity $Mailbox }
    default    { $mailboxes = Get-Mailbox -ResultSize Unlimited }
}

$total   = @($mailboxes).Count
Write-Host "Found $total mailbox(es). Pulling statistics..." -ForegroundColor Cyan

$i       = 0
$report  = foreach ($mb in $mailboxes) {
    $i++
    Write-Progress -Activity "Mailbox statistics" -Status $mb.DisplayName `
        -PercentComplete (($i / [math]::Max($total, 1)) * 100)

    $stats = Get-MailboxStatistics -Identity $mb.DistinguishedName -ErrorAction SilentlyContinue
    if (-not $stats) { continue }   # never logged on / no DB copy mounted -> no stats yet

    $sizeMB = ConvertTo-MB $stats.TotalItemSize

    # Quota: mailbox-level value, or the database default when the mailbox inherits it.
    $quota = $mb.ProhibitSendQuota
    if ($mb.UseDatabaseQuotaDefaults) {
        $quota = (Get-MailboxDatabase $mb.Database).ProhibitSendQuota
    }
    $quotaMB   = if ($quota -and "$quota" -ne 'Unlimited') { ConvertTo-MB $quota } else { 0 }
    $pctOfQuota = if ($quotaMB -gt 0) { [math]::Round(($sizeMB / $quotaMB) * 100, 1) } else { $null }

    [PSCustomObject][ordered]@{
        DisplayName     = $mb.DisplayName
        PrimarySMTP     = $mb.PrimarySmtpAddress.ToString()
        Database        = $stats.Database
        ItemCount       = $stats.ItemCount
        TotalSizeMB     = $sizeMB
        TotalSizeGB     = [math]::Round($sizeMB / 1024, 2)
        DeletedItemsMB  = ConvertTo-MB $stats.TotalDeletedItemSize
        QuotaMB         = $quotaMB
        PercentOfQuota  = $pctOfQuota
        LastLogon       = $stats.LastLogonTime
    }
}
Write-Progress -Activity "Mailbox statistics" -Completed

$report = $report | Sort-Object TotalSizeMB -Descending

if ($PSCmdlet.ParameterSetName -eq 'Mailbox') {
    $report | Format-List
}
else {
    if (-not $OutputFile) {
        $OutputFile = "MailboxSizeReport_{0}.csv" -f (Get-Date -Format 'yyyyMMdd_HHmmss')
    }
    $report | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8
    $sumGB = [math]::Round((($report | Measure-Object TotalSizeMB -Sum).Sum / 1024), 2)
    Write-Host ("Wrote {0} mailbox(es), {1} GB total -> {2}" -f $report.Count, $sumGB, $OutputFile) `
        -ForegroundColor Green
}
