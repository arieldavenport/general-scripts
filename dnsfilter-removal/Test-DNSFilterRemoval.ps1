<#
.SYNOPSIS
    Verifies that the DNSFilter Roaming Client is removed and that the blocks
    applied by Remove-DNSFilter.ps1 are in place.

.DESCRIPTION
    Read-only. Prints a pass/fail line per check and exits non-zero if anything
    that should be gone is still present (or any block is missing).

.EXAMPLE
    .\Test-DNSFilterRemoval.ps1
#>
[CmdletBinding()]
param()

$ServiceNames = @('DNSFilter Agent', 'DNS Agent', 'DNS Agent Service Manager')
$InstallDirs  = @(
    (Join-Path $env:ProgramFiles 'DNSFilter Agent'),
    (Join-Path $env:ProgramFiles 'DNS Agent'),
    (Join-Path ${env:ProgramFiles(x86)} 'DNSFilter Agent')
) | Where-Object { $_ }
$AgentExeNames = @('dns_agent.exe', 'dnsfilter_agent.exe', 'dnsfilteragent.exe', 'dnsagent.exe', 'DNS Agent.exe', 'dnsfilter-agent.exe')
$IFEORoot = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'
$HostsPath = Join-Path $env:WINDIR 'System32\drivers\etc\hosts'

$fail = 0
function Check {
    param([string]$Name, [bool]$Pass, [string]$Detail)
    if ($Pass) {
        $tag = '[PASS]'; $color = 'Green'
    } else {
        $tag = '[FAIL]'; $color = 'Red'; $script:fail++
    }
    Write-Host ("{0} {1}{2}" -f $tag, $Name, $(if ($Detail) { " - $Detail" } else { '' })) -ForegroundColor $color
}

# Services gone
foreach ($s in $ServiceNames) {
    $svc = Get-Service -Name $s -ErrorAction SilentlyContinue
    Check "Service '$s' removed" (-not $svc) $(if ($svc) { "status=$($svc.Status)" })
}

# Install dirs gone or locked
foreach ($d in $InstallDirs) {
    if (-not (Test-Path $d)) {
        Check "Install dir absent: $d" $true
    } else {
        $hasFiles = [bool](Get-ChildItem -LiteralPath $d -Force -ErrorAction SilentlyContinue)
        Check "Install dir locked/empty: $d" (-not $hasFiles) $(if ($hasFiles) { 'contains files' } else { 'empty placeholder' })
    }
}

# Process not running
$proc = Get-Process -ErrorAction SilentlyContinue | Where-Object { $AgentExeNames -contains ($_.Path | Split-Path -Leaf -ErrorAction SilentlyContinue) }
Check 'No agent process running' (-not $proc)

# IFEO block present
$ifeoOk = $AgentExeNames | ForEach-Object { Test-Path (Join-Path $IFEORoot $_) } | Where-Object { $_ }
Check 'IFEO execution block present' ([bool]$ifeoOk)

# Hosts sinkhole present
$hostsOk = (Test-Path $HostsPath) -and ((Get-Content $HostsPath -Raw) -match 'dnsfilter\.com')
Check 'Hosts sinkhole present' $hostsOk

# Firewall rules present
$fwOk = [bool](Get-NetFirewallRule -DisplayName 'DNSFilter-Block*' -ErrorAction SilentlyContinue)
Check 'Firewall block rules present' $fwOk

Write-Host ''
if ($fail -eq 0) {
    Write-Host 'All checks passed.' -ForegroundColor Green
    exit 0
} else {
    Write-Host "$fail check(s) failed." -ForegroundColor Red
    exit 1
}
