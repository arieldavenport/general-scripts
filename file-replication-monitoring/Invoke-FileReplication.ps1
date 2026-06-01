#Requires -Version 5.1
<#
.SYNOPSIS
    Mirrors an on-prem SMB share to an Azure Files share with robocopy and emits
    structured Windows Event Log telemetry for Azure Monitor to alert on.

.DESCRIPTION
    Runs robocopy /MIR, parses the summary, and writes ONE completion event:
        EventID 1000  Information  successful run (exit code 0-7)
        EventID 1001  Error        failed run     (exit code >= 8) or script crash
    Plus a delete canary:
        EventID 1002  Warning      raised when the number of files PURGED from the
                                   target ("Extras" under /MIR) exceeds the threshold.
    The message body of 1000/1001 carries a compact JSON payload that the Azure
    Monitor KQL alerts parse (DurationSec, FilesFailed, FilesExtra, etc.).

    Intended to run from a Scheduled Task on a domain-joined Azure VM that mounts
    the Azure Files share over Kerberos (AD DS identity-based auth) -- no storage
    account key and no SAS token.

.NOTES
    Register the event source ONCE, elevated, before first run:
        New-EventLog -LogName Application -Source 'FileRepl'
    The task service account should be a member of Backup Operators (for /B) and
    hold the 'Storage File Data SMB Share Elevated Contributor' role on the share.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]   $Source,                 # e.g. \\pure-fs01\projects
    [Parameter(Mandatory)] [string]   $Destination,            # e.g. \\acct.file.core.windows.net\projects
    [string]   $LogDirectory          = 'C:\ProgramData\FileRepl\logs',
    [string]   $EventSource           = 'FileRepl',
    [int]      $DeleteCanaryThreshold = 100,                   # purged-from-target files that trip EventID 1002
    [int]      $LocalLogRetentionDays = 30,
    [int]      $Retries               = 2,
    [int]      $WaitSeconds           = 5,
    [int]      $Threads               = 16,
    [string[]] $ExtraRobocopyArgs     = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not [System.Diagnostics.EventLog]::SourceExists($EventSource)) {
    throw "Event source '$EventSource' is not registered. Run once (elevated): New-EventLog -LogName Application -Source '$EventSource'"
}

# Prevent overlapping runs if a cycle overruns the schedule interval.
$mutexName = 'Global\FileRepl_' + ($Source -replace '\W', '_')
$mutex     = New-Object System.Threading.Mutex($false, $mutexName)
if (-not $mutex.WaitOne(0)) {
    Write-Warning 'A previous replication run is still active; exiting without starting a second copy.'
    exit 0
}

function Get-RoboCount {
    param([string[]] $SummaryLines, [string] $Label, [string] $Column)
    # Robocopy summary columns: Total Copied Skipped Mismatch FAILED Extras
    $idx  = @{ Total = 0; Copied = 1; Skipped = 2; Mismatch = 3; Failed = 4; Extras = 5 }
    $line = $SummaryLines | Where-Object { $_ -match "^\s*$Label\s*:" } | Select-Object -First 1
    if (-not $line) { return 0 }
    $nums = [regex]::Matches($line, '\d+') | ForEach-Object { $_.Value }
    if ($nums.Count -le $idx[$Column]) { return 0 }
    return [int]$nums[$idx[$Column]]
}

try {
    if (-not (Test-Path $LogDirectory)) {
        New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
    }
    $stamp   = Get-Date -Format 'yyyyMMdd_HHmmss'
    $logFile = Join-Path $LogDirectory "robocopy_$stamp.log"
    $sw      = [System.Diagnostics.Stopwatch]::StartNew()

    $rcArgs = @(
        $Source, $Destination, '/MIR',
        '/COPY:DATSO', '/DCOPY:DAT', '/B',
        "/R:$Retries", "/W:$WaitSeconds", "/MT:$Threads",
        '/NP', '/NDL', "/LOG:$logFile"
    ) + $ExtraRobocopyArgs

    & robocopy.exe @rcArgs | Out-Null
    $code = $LASTEXITCODE          # robocopy bitmask: 0-7 = non-fatal, >=8 = failure
    $sw.Stop()

    $tail   = Get-Content -LiteralPath $logFile -Tail 15
    $failed = $code -ge 8
    $extras = Get-RoboCount $tail 'Files' 'Extras'   # files removed from target by /MIR == deletions

    $payload = [ordered]@{
        Timestamp   = (Get-Date).ToString('o')
        Host        = $env:COMPUTERNAME
        Source      = $Source
        Destination = $Destination
        Status      = if ($failed) { 'FAILED' } else { 'OK' }
        ExitCode    = $code
        DurationSec = [int]$sw.Elapsed.TotalSeconds
        FilesCopied = Get-RoboCount $tail 'Files' 'Copied'
        FilesFailed = Get-RoboCount $tail 'Files' 'Failed'
        FilesExtra  = $extras
        DirsCopied  = Get-RoboCount $tail 'Dirs'  'Copied'
        LogFile     = $logFile
    }
    $json = $payload | ConvertTo-Json -Compress

    if ($failed) {
        Write-EventLog -LogName Application -Source $EventSource -EventId 1001 `
            -EntryType Error -Message "ReplicationResult $json"
    }
    else {
        Write-EventLog -LogName Application -Source $EventSource -EventId 1000 `
            -EntryType Information -Message "ReplicationResult $json"
    }

    if ($extras -gt $DeleteCanaryThreshold) {
        Write-EventLog -LogName Application -Source $EventSource -EventId 1002 `
            -EntryType Warning `
            -Message "DeleteCanary $extras files purged from target (threshold $DeleteCanaryThreshold). $json"
    }

    Get-ChildItem $LogDirectory -Filter 'robocopy_*.log' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$LocalLogRetentionDays) } |
        Remove-Item -Force -ErrorAction SilentlyContinue

    exit $(if ($failed) { 1 } else { 0 })
}
catch {
    # A crash before the normal completion event would otherwise look like a silent
    # success to the dead-man's switch -- emit a failure event so it still surfaces.
    $msg = ($_.Exception.Message -replace '"', "'")
    try {
        Write-EventLog -LogName Application -Source $EventSource -EventId 1001 `
            -EntryType Error -Message "ReplicationResult {""Status"":""FAILED"",""Error"":""$msg""}"
    } catch { }
    throw
}
finally {
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
