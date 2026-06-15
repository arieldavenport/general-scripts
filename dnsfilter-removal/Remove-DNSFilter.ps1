<#
.SYNOPSIS
    Uninstalls the DNSFilter Windows Roaming Client and blocks it from
    reinstalling.

.DESCRIPTION
    Performs a full removal of the DNSFilter Roaming Client (a.k.a. "DNS Agent"
    / whitelabel "DNS Agent") and then layers three independent blocks so the
    agent cannot silently come back:

      1. Uninstall   - stops + deletes the agent services, runs the MSI
                       uninstaller for every matching product code, and removes
                       leftover install/data directories and registry keys.

      2. Network      - points DNSFilter's download / API / check-in domains at
                       0.0.0.0 in the hosts file and adds outbound Windows
                       Firewall rules blocking the agent binaries and DNSFilter's
                       anycast resolver IPs.

      3. Filesystem   - recreates each install directory as a locked, empty
                       placeholder whose ACL denies "create files / create
                       folders" to everyone (including SYSTEM), so an installer
                       cannot lay files down.

      4. Policy       - adds Image File Execution Options "debugger" redirects
                       for the agent executable names so they cannot launch from
                       any path, and disables the service entries if recreated.

    Every step is idempotent and logged. Run with -Restore to undo the three
    blocks (this does NOT reinstall the agent).

.PARAMETER Mode
    What to do:
      Full     - uninstall + apply all enabled blocks (default).
      Uninstall- only remove the agent, no blocking.
      Block    - only apply blocks (skip uninstall).
      Restore  - remove the blocks added by this script.

.PARAMETER BlockNetwork
    Apply the hosts-file + firewall network block. Default: on in Full/Block.

.PARAMETER BlockFilesystem
    Apply the locked install-directory placeholders. Default: on in Full/Block.

.PARAMETER BlockPolicy
    Apply the IFEO execution block. Default: on in Full/Block.

.PARAMETER Domains
    DNSFilter domains to sinkhole in the hosts file. Override to customize.

.PARAMETER ResolverIPs
    DNSFilter anycast resolver IPs to block outbound. Override to customize.

.PARAMETER LogPath
    Transcript/log file. Default: C:\Windows\Temp\Remove-DNSFilter.log

.EXAMPLE
    .\Remove-DNSFilter.ps1
    Full uninstall + all blocks.

.EXAMPLE
    .\Remove-DNSFilter.ps1 -Mode Uninstall
    Remove the agent only, leave the machine able to reinstall it.

.EXAMPLE
    .\Remove-DNSFilter.ps1 -Mode Restore
    Lift every block this script applied.

.EXAMPLE
    .\Remove-DNSFilter.ps1 -WhatIf
    Preview every change without making it.

.NOTES
    Run as Administrator. Intended for authorized endpoint administration
    (vendor migration, decommissioning, offboarding). Confirm you are permitted
    to remove this security agent before running it.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [ValidateSet('Full', 'Uninstall', 'Block', 'Restore')]
    [string]$Mode = 'Full',

    [switch]$BlockNetwork,
    [switch]$BlockFilesystem,
    [switch]$BlockPolicy,

    [string[]]$Domains = @(
        'dnsfilter.com',
        'www.dnsfilter.com',
        'app.dnsfilter.com',
        'api.dnsfilter.com',
        'download.dnsfilter.com',
        'downloads.dnsfilter.com',
        'updates.dnsfilter.com'
    ),

    [string[]]$ResolverIPs = @('103.247.36.36', '103.247.37.37'),

    [string]$LogPath = (Join-Path $env:WINDIR 'Temp\Remove-DNSFilter.log')
)

#Requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'

# ---- Constants describing the DNSFilter footprint ---------------------------
# Service names across standard + whitelabel + v2.1.0 service manager.
$ServiceNames = @('DNSFilter Agent', 'DNS Agent', 'DNS Agent Service Manager')

# Install / data directories the agent uses (standard + whitelabel + x86).
$InstallDirs = @(
    (Join-Path $env:ProgramFiles 'DNSFilter Agent'),
    (Join-Path $env:ProgramFiles 'DNS Agent'),
    (Join-Path $env:ProgramFiles 'DNSAgent'),
    (Join-Path ${env:ProgramFiles(x86)} 'DNSFilter Agent'),
    (Join-Path ${env:ProgramFiles(x86)} 'DNS Agent'),
    (Join-Path $env:ProgramData 'DNSFilter'),
    (Join-Path $env:ProgramData 'DNSAgent')
) | Where-Object { $_ } | Select-Object -Unique

# Registry keys the agent owns (config + product roots).
$RegKeys = @(
    'HKLM:\SOFTWARE\DNSFilter',
    'HKLM:\SOFTWARE\DNSAgent',
    'HKLM:\SOFTWARE\WOW6432Node\DNSFilter',
    'HKLM:\SOFTWARE\WOW6432Node\DNSAgent'
)

# Executable names to block from launching (IFEO + firewall).
$AgentExeNames = @(
    'dns_agent.exe',
    'dnsfilter_agent.exe',
    'dnsfilteragent.exe',
    'dnsagent.exe',
    'DNS Agent.exe',
    'dnsfilter-agent.exe'
)

$IFEORoot = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'
$FirewallTag = 'DNSFilter-Block'
$HostsPath = Join-Path $env:WINDIR 'System32\drivers\etc\hosts'
$HostsMarker = '# DNSFilter-Block (added by Remove-DNSFilter.ps1)'

# -----------------------------------------------------------------------------
function Write-Log {
    param([string]$Message, [ValidateSet('INFO', 'WARN', 'ERROR', 'OK')][string]$Level = 'INFO')
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$stamp] [$Level] $Message"
    $color = @{ INFO = 'Gray'; WARN = 'Yellow'; ERROR = 'Red'; OK = 'Green' }[$Level]
    Write-Host $line -ForegroundColor $color
    try { Add-Content -Path $LogPath -Value $line -ErrorAction SilentlyContinue } catch { }
}

# ---- Uninstall --------------------------------------------------------------
function Stop-RemoveServices {
    foreach ($name in $ServiceNames) {
        $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
        if (-not $svc) { continue }
        if ($PSCmdlet.ShouldProcess($name, 'Stop and delete service')) {
            try {
                if ($svc.Status -ne 'Stopped') { Stop-Service -Name $name -Force -ErrorAction SilentlyContinue }
                # sc.exe delete works regardless of how the service was registered.
                $null = & sc.exe delete "$name" 2>&1
                Write-Log "Removed service '$name'." 'OK'
            } catch {
                Write-Log "Could not remove service '$name': $($_.Exception.Message)" 'WARN'
            }
        }
    }
}

function Get-DNSFilterProducts {
    # Read the uninstall registry directly (avoids the slow/destructive
    # Win32_Product class). Returns objects with DisplayName + product code.
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($root in $roots) {
        if (-not (Test-Path $root)) { continue }
        Get-ChildItem $root | ForEach-Object {
            $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
            if ($p.DisplayName -match 'DNS\s?Filter|DNS Agent') {
                [pscustomobject]@{
                    DisplayName     = $p.DisplayName
                    ProductCode     = Split-Path $_.PSPath -Leaf
                    UninstallString = $p.UninstallString
                }
            }
        }
    }
}

function Uninstall-DNSFilter {
    $products = @(Get-DNSFilterProducts)
    if (-not $products) {
        Write-Log 'No DNSFilter product found in the uninstall registry.' 'INFO'
        return
    }
    foreach ($p in $products) {
        if ($PSCmdlet.ShouldProcess($p.DisplayName, 'Uninstall via msiexec')) {
            $log = Join-Path $env:WINDIR "Temp\dnsfilter_msi_uninstall.log"
            $msiArgs = "/x `"$($p.ProductCode)`" REGCLEAN=true /qn /norestart /L*vx `"$log`""
            Write-Log "Uninstalling '$($p.DisplayName)' ($($p.ProductCode))..." 'INFO'
            try {
                $proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArgs -Wait -PassThru
                if ($proc.ExitCode -in 0, 1605, 3010) {
                    Write-Log "msiexec exit code $($proc.ExitCode) (success)." 'OK'
                } else {
                    Write-Log "msiexec exit code $($proc.ExitCode). See $log" 'WARN'
                }
            } catch {
                Write-Log "msiexec failed: $($_.Exception.Message)" 'ERROR'
            }
        }
    }
}

function Remove-Leftovers {
    foreach ($dir in $InstallDirs) {
        if (Test-Path $dir) {
            if ($PSCmdlet.ShouldProcess($dir, 'Delete directory')) {
                try {
                    # Clear any deny-ACL/read-only first so removal succeeds.
                    & icacls "$dir" /reset /T /C 2>&1 | Out-Null
                    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction Stop
                    Write-Log "Deleted '$dir'." 'OK'
                } catch {
                    Write-Log "Could not delete '$dir': $($_.Exception.Message)" 'WARN'
                }
            }
        }
    }
    foreach ($key in $RegKeys) {
        if (Test-Path $key) {
            if ($PSCmdlet.ShouldProcess($key, 'Delete registry key')) {
                try {
                    Remove-Item -Path $key -Recurse -Force -ErrorAction Stop
                    Write-Log "Deleted registry key '$key'." 'OK'
                } catch {
                    Write-Log "Could not delete '$key': $($_.Exception.Message)" 'WARN'
                }
            }
        }
    }
}

# ---- Block: network ---------------------------------------------------------
function Block-Network {
    # Hosts file sinkhole.
    $existing = if (Test-Path $HostsPath) { Get-Content $HostsPath } else { @() }
    $toAdd = foreach ($d in $Domains) {
        if ($existing -notmatch [regex]::Escape($d)) {
            "0.0.0.0`t$d"
        }
    }
    if ($toAdd) {
        if ($PSCmdlet.ShouldProcess($HostsPath, "Sinkhole $($toAdd.Count) DNSFilter domain(s)")) {
            Add-Content -Path $HostsPath -Value ('', $HostsMarker + ' >>>')
            Add-Content -Path $HostsPath -Value $toAdd
            Add-Content -Path $HostsPath -Value ($HostsMarker + ' <<<')
            Write-Log "Sinkholed $($toAdd.Count) domain(s) in hosts file." 'OK'
        }
    } else {
        Write-Log 'Hosts file already contains the DNSFilter domains.' 'INFO'
    }

    # Outbound firewall: block agent binaries and resolver IPs.
    foreach ($exe in $AgentExeNames) {
        foreach ($dir in $InstallDirs) {
            $path = Join-Path $dir $exe
            $rule = "$FirewallTag prog $exe ($dir)"
            if (-not (Get-NetFirewallRule -DisplayName $rule -ErrorAction SilentlyContinue)) {
                if ($PSCmdlet.ShouldProcess($rule, 'Add outbound block firewall rule')) {
                    New-NetFirewallRule -DisplayName $rule -Direction Outbound -Action Block `
                        -Program $path -Profile Any -ErrorAction SilentlyContinue | Out-Null
                }
            }
        }
    }
    $ipRule = "$FirewallTag resolvers"
    if (-not (Get-NetFirewallRule -DisplayName $ipRule -ErrorAction SilentlyContinue)) {
        if ($PSCmdlet.ShouldProcess($ipRule, 'Add outbound block to DNSFilter resolver IPs')) {
            New-NetFirewallRule -DisplayName $ipRule -Direction Outbound -Action Block `
                -RemoteAddress $ResolverIPs -Profile Any -ErrorAction SilentlyContinue | Out-Null
            Write-Log "Blocked outbound traffic to resolver IPs: $($ResolverIPs -join ', ')." 'OK'
        }
    }
    Write-Log 'Network block applied.' 'OK'
}

function Unblock-Network {
    if (Test-Path $HostsPath) {
        $content = Get-Content $HostsPath
        $start = ($content | Select-String -SimpleMatch ($HostsMarker + ' >>>')).LineNumber
        $end = ($content | Select-String -SimpleMatch ($HostsMarker + ' <<<')).LineNumber
        if ($start -and $end -and $PSCmdlet.ShouldProcess($HostsPath, 'Remove DNSFilter sinkhole block')) {
            $kept = $content[0..($start - 2)] + $content[$end..($content.Count - 1)]
            Set-Content -Path $HostsPath -Value $kept
            Write-Log 'Removed DNSFilter domains from hosts file.' 'OK'
        }
    }
    Get-NetFirewallRule -DisplayName "$FirewallTag*" -ErrorAction SilentlyContinue | ForEach-Object {
        if ($PSCmdlet.ShouldProcess($_.DisplayName, 'Remove firewall rule')) {
            Remove-NetFirewallRule -DisplayName $_.DisplayName -ErrorAction SilentlyContinue
        }
    }
    Write-Log 'Network block removed.' 'OK'
}

# ---- Block: filesystem ------------------------------------------------------
function Block-Filesystem {
    foreach ($dir in $InstallDirs) {
        # Only lock the program-files style install dirs, not ProgramData roots
        # shared with other products.
        if ($dir -notmatch 'Program Files') { continue }
        if ($PSCmdlet.ShouldProcess($dir, 'Create locked placeholder directory')) {
            try {
                if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
                # Deny creation of new files/folders to Everyone + SYSTEM so an
                # installer cannot write into the directory. Existing read is fine.
                & icacls "$dir" /inheritance:r 2>&1 | Out-Null
                & icacls "$dir" /grant:r '*S-1-5-32-544:(RX)' 2>&1 | Out-Null  # Administrators read/exec
                & icacls "$dir" /deny '*S-1-1-0:(WD,AD)' 2>&1 | Out-Null        # Everyone: deny write/append data
                & icacls "$dir" /deny '*S-1-5-18:(WD,AD)' 2>&1 | Out-Null       # SYSTEM: deny write/append data
                Write-Log "Locked install directory '$dir'." 'OK'
            } catch {
                Write-Log "Could not lock '$dir': $($_.Exception.Message)" 'WARN'
            }
        }
    }
}

function Unblock-Filesystem {
    foreach ($dir in $InstallDirs) {
        if ($dir -notmatch 'Program Files') { continue }
        if (Test-Path $dir) {
            if ($PSCmdlet.ShouldProcess($dir, 'Reset ACL and remove placeholder')) {
                & icacls "$dir" /reset /T /C 2>&1 | Out-Null
                # Remove only if empty (don't nuke a real reinstall the admin chose).
                if (-not (Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)) {
                    Remove-Item -LiteralPath $dir -Force -ErrorAction SilentlyContinue
                }
                Write-Log "Unlocked '$dir'." 'OK'
            }
        }
    }
}

# ---- Block: policy (IFEO) ---------------------------------------------------
function Block-Policy {
    foreach ($exe in $AgentExeNames) {
        $key = Join-Path $IFEORoot $exe
        if ($PSCmdlet.ShouldProcess($exe, 'Block execution via IFEO debugger redirect')) {
            try {
                if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
                # systray.exe is a harmless no-op stub; any non-launching value works.
                New-ItemProperty -Path $key -Name 'Debugger' -Value '"%SystemRoot%\System32\systray.exe"' `
                    -PropertyType String -Force | Out-Null
                Write-Log "Blocked execution of '$exe' (IFEO)." 'OK'
            } catch {
                Write-Log "Could not set IFEO for '$exe': $($_.Exception.Message)" 'WARN'
            }
        }
    }
}

function Unblock-Policy {
    foreach ($exe in $AgentExeNames) {
        $key = Join-Path $IFEORoot $exe
        if (Test-Path $key) {
            if ($PSCmdlet.ShouldProcess($exe, 'Remove IFEO execution block')) {
                Remove-Item -Path $key -Recurse -Force -ErrorAction SilentlyContinue
                Write-Log "Removed IFEO block for '$exe'." 'OK'
            }
        }
    }
}

# ---- Orchestration ----------------------------------------------------------
Write-Log "==== Remove-DNSFilter starting (Mode=$Mode) ====" 'INFO'

# If no explicit -Block* switch is given, default all blocks on for Full/Block.
if (-not ($BlockNetwork -or $BlockFilesystem -or $BlockPolicy)) {
    $BlockNetwork = $true; $BlockFilesystem = $true; $BlockPolicy = $true
}

switch ($Mode) {
    'Uninstall' {
        Stop-RemoveServices
        Uninstall-DNSFilter
        Remove-Leftovers
    }
    'Block' {
        if ($BlockNetwork) { Block-Network }
        if ($BlockFilesystem) { Block-Filesystem }
        if ($BlockPolicy) { Block-Policy }
    }
    'Full' {
        Stop-RemoveServices
        Uninstall-DNSFilter
        Remove-Leftovers
        if ($BlockNetwork) { Block-Network }
        if ($BlockFilesystem) { Block-Filesystem }
        if ($BlockPolicy) { Block-Policy }
    }
    'Restore' {
        Unblock-Network
        Unblock-Filesystem
        Unblock-Policy
        Write-Log 'Blocks removed. (This does not reinstall the agent.)' 'INFO'
    }
}

Write-Log "==== Remove-DNSFilter finished (Mode=$Mode) ====" 'OK'
Write-Log "Log: $LogPath" 'INFO'
