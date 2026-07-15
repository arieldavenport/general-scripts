<#
.SYNOPSIS
    Forcefully removes the Keep Aware browser security extension and blocks it
    from reinstalling.

.DESCRIPTION
    Keep Aware (https://keepaware.com) is an "agentless" enterprise browser
    security product delivered as a force-installed browser extension, pushed
    through MDM / Group Policy / Intune using the Chromium
    ExtensionInstallForcelist policy (and the Firefox ExtensionSettings policy).
    Because the browser re-adds a force-installed extension on the next launch
    or policy refresh, a normal "remove from the browser" does nothing. This
    script removes the extension and then layers blocks so it cannot come back:

      1. Uninstall  - deletes the force-install policy entries (HKLM + HKCU),
                      any force_installed ExtensionSettings, the HKLM external
                      (side-load) registration keys, and the unpacked extension
                      from every user/browser profile on disk.

      2. Policy      - adds the extension ID to ExtensionInstallBlocklist and
                      sets ExtensionSettings installation_mode = blocked for
                      every supported browser (Chromium removes an installed
                      extension the moment it becomes blocked), plus a Firefox
                      policies.json block when -FirefoxAddonId is supplied.

      3. Network     - points Keep Aware's console/API domains at 0.0.0.0 in the
                      hosts file and adds outbound firewall rules to them, so a
                      re-pushed extension (which is useless without its cloud
                      backend) cannot check in.

    Every step is idempotent and logged. Run with -Mode Restore to undo the
    Policy + Network blocks (this does NOT restore the force-install).

    MANAGED-DEPLOYMENT CAVEAT
    -------------------------
    If the force-install entry is delivered by a domain Group Policy object or
    by Intune / another MDM, the authoritative copy lives on the management
    server. This script removes the local copy and blocks the extension
    locally, but the next policy refresh can re-push the force-install and,
    depending on precedence, override the local block. When a force-install
    entry is found in the machine (HKLM) policy hive the script warns loudly:
    finish the job by removing the deployment at its source (GPO / Intune
    profile / RMM policy) and unassigning the device in the Keep Aware console.

.PARAMETER Mode
    What to do:
      Full     - uninstall + apply all enabled blocks (default).
      Uninstall- only remove the extension, no blocking.
      Block    - only apply blocks (skip uninstall).
      Restore  - remove the blocks added by this script.

.PARAMETER BlockPolicy
    Apply the browser blocklist / ExtensionSettings block. Default: on in Full/Block.

.PARAMETER BlockNetwork
    Apply the hosts-file + firewall network block. Default: on in Full/Block.

.PARAMETER ExtensionId
    Chromium extension IDs to purge and block. Defaults to the known Keep Aware
    Chrome Web Store ID. Override/extend for a re-published build.

.PARAMETER FirefoxAddonId
    Firefox add-on IDs (e.g. "something@keepaware.com" or "{GUID}") to block via
    policies.json. Firefox uses a different ID scheme than Chromium, so it can't
    be derived from the Chrome ID. If empty, Firefox handling is skipped.

.PARAMETER Domains
    Keep Aware console/API domains to sinkhole in the hosts file. Override to customize.

.PARAMETER LogPath
    Transcript/log file. Default: C:\Windows\Temp\Remove-KeepAware.log

.EXAMPLE
    .\Remove-KeepAware.ps1
    Full uninstall + all blocks.

.EXAMPLE
    .\Remove-KeepAware.ps1 -Mode Uninstall
    Remove the extension only, leave the machine able to reinstall it.

.EXAMPLE
    .\Remove-KeepAware.ps1 -Mode Block -BlockPolicy
    Only apply the browser policy block (no network block, no uninstall).

.EXAMPLE
    .\Remove-KeepAware.ps1 -Mode Restore
    Lift every block this script applied.

.EXAMPLE
    .\Remove-KeepAware.ps1 -WhatIf
    Preview every change without making it.

.NOTES
    Run as Administrator. Intended for authorized endpoint administration
    (vendor migration, decommissioning, offboarding). Confirm you are permitted
    to remove this security control before running it.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [ValidateSet('Full', 'Uninstall', 'Block', 'Restore')]
    [string]$Mode = 'Full',

    [switch]$BlockPolicy,
    [switch]$BlockNetwork,

    [string[]]$ExtensionId = @('camnmdjjfkcplbdlofbndmkmnfeegjoi'),

    [string[]]$FirefoxAddonId = @(),

    [string[]]$Domains = @(
        'keepaware.com',
        'www.keepaware.com',
        'app.keepaware.com',
        'api.keepaware.com'
    ),

    [string]$LogPath = (Join-Path $env:WINDIR 'Temp\Remove-KeepAware.log')
)

#Requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'

# ---- Constants describing the Keep Aware footprint --------------------------
# Chromium browsers that share the Keep Aware Chrome Web Store ID. Each entry:
#   Name      - friendly name for logging
#   PolicyKey - sub-path under SOFTWARE\Policies for the browser's policies
#   ExtRegKey - sub-path under SOFTWARE for external (side-load) registration
#   UserData  - path, relative to a user profile root, of the user-data dir
$ChromiumBrowsers = @(
    @{ Name = 'Google Chrome' ; PolicyKey = 'Google\Chrome'        ; ExtRegKey = 'Google\Chrome\Extensions'      ; UserData = 'AppData\Local\Google\Chrome\User Data' }
    @{ Name = 'Microsoft Edge'; PolicyKey = 'Microsoft\Edge'       ; ExtRegKey = 'Microsoft\Edge\Extensions'      ; UserData = 'AppData\Local\Microsoft\Edge\User Data' }
    @{ Name = 'Brave'         ; PolicyKey = 'BraveSoftware\Brave'  ; ExtRegKey = 'BraveSoftware\Brave\Extensions' ; UserData = 'AppData\Local\BraveSoftware\Brave-Browser\User Data' }
    @{ Name = 'Vivaldi'       ; PolicyKey = 'Vivaldi'              ; ExtRegKey = 'Vivaldi\Extensions'             ; UserData = 'AppData\Local\Vivaldi\User Data' }
    @{ Name = 'Opera'         ; PolicyKey = 'Opera Software\Opera' ; ExtRegKey = 'Opera Software\Opera\Extensions'; UserData = 'AppData\Roaming\Opera Software\Opera Stable' }
    @{ Name = 'Chromium'      ; PolicyKey = 'Chromium'             ; ExtRegKey = 'Chromium\Extensions'            ; UserData = 'AppData\Local\Chromium\User Data' }
)

# Firefox install locations that receive a policies.json block.
$FirefoxInstallDirs = @(
    (Join-Path $env:ProgramFiles 'Mozilla Firefox'),
    (Join-Path ${env:ProgramFiles(x86)} 'Mozilla Firefox')
) | Where-Object { $_ } | Select-Object -Unique

$FirewallTag = 'KeepAware-Block'
$HostsPath   = Join-Path $env:WINDIR 'System32\drivers\etc\hosts'
$HostsMarker = '# KeepAware-Block (added by Remove-KeepAware.ps1)'

# Tracks whether a machine-hive (GPO/MDM) force-install source was seen.
$script:ManagedSourceFound = $false

# -----------------------------------------------------------------------------
function Write-Log {
    param([string]$Message, [ValidateSet('INFO', 'WARN', 'ERROR', 'OK')][string]$Level = 'INFO')
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$stamp] [$Level] $Message"
    $color = @{ INFO = 'Gray'; WARN = 'Yellow'; ERROR = 'Red'; OK = 'Green' }[$Level]
    Write-Host $line -ForegroundColor $color
    try { Add-Content -Path $LogPath -Value $line -ErrorAction SilentlyContinue } catch { }
}

function Get-UserProfileRoots {
    # Every real user profile under C:\Users (skips the service profiles that
    # never run a browser interactively; keeps Default so a provisioning
    # template is cleaned too).
    $usersRoot = Join-Path $env:SystemDrive 'Users'
    if (-not (Test-Path -LiteralPath $usersRoot)) { return @() }
    $skip = @('Public', 'All Users', 'Default User')
    Get-ChildItem -LiteralPath $usersRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $skip -notcontains $_.Name } |
        Select-Object -ExpandProperty FullName
}

# ---- Uninstall --------------------------------------------------------------
function Remove-ForcelistEntries {
    # Delete ExtensionInstallForcelist values referencing a target ID, in both
    # the machine (HKLM) and user (HKCU) policy hives, for one browser.
    param([hashtable]$Browser, [string]$Id)
    foreach ($hive in @(@{ Root = 'HKLM'; Label = 'machine' }, @{ Root = 'HKCU'; Label = 'user' })) {
        $forcelist = "$($hive.Root):\SOFTWARE\Policies\$($Browser.PolicyKey)\ExtensionInstallForcelist"
        if (-not (Test-Path -LiteralPath $forcelist)) { continue }
        $props = Get-ItemProperty -LiteralPath $forcelist -ErrorAction SilentlyContinue
        if (-not $props) { continue }
        foreach ($p in $props.PSObject.Properties) {
            if ($p.Name -like 'PS*') { continue }
            if ((([string]$p.Value) -split ';')[0].Trim() -ne $Id) { continue }
            if ($hive.Label -eq 'machine') {
                $script:ManagedSourceFound = $true
                Write-Log "$($Browser.Name): force-install for $Id is in the MACHINE hive - almost certainly pushed by GPO/Intune/RMM and will be re-applied unless removed at the source." 'WARN'
            }
            if ($PSCmdlet.ShouldProcess("$($Browser.Name) [$($hive.Label)] forcelist '$($p.Name)'", 'Remove force-install entry')) {
                try {
                    Remove-ItemProperty -LiteralPath $forcelist -Name $p.Name -Force -ErrorAction Stop
                    Write-Log "$($Browser.Name): removed force-install entry ($($hive.Label))." 'OK'
                } catch {
                    Write-Log "$($Browser.Name): could not remove force-install entry '$($p.Name)': $($_.Exception.Message)" 'WARN'
                }
            }
        }
    }
    # Drop a force_installed ExtensionSettings\<id> node if present (the newer
    # way to force an extension). The blocked replacement is written by the
    # policy block.
    foreach ($root in @('HKLM', 'HKCU')) {
        $settings = "$root:\SOFTWARE\Policies\$($Browser.PolicyKey)\ExtensionSettings\$Id"
        if (-not (Test-Path -LiteralPath $settings)) { continue }
        $item = Get-ItemProperty -LiteralPath $settings -ErrorAction SilentlyContinue
        $mode = if ($item -and $item.PSObject.Properties['installation_mode']) { $item.installation_mode } else { $null }
        if ($mode -eq 'force_installed' -and $root -eq 'HKLM') { $script:ManagedSourceFound = $true }
        if ($PSCmdlet.ShouldProcess("$($Browser.Name) [$root] ExtensionSettings\$Id", 'Clear force ExtensionSettings')) {
            try {
                Remove-Item -LiteralPath $settings -Recurse -Force -ErrorAction Stop
                Write-Log "$($Browser.Name): cleared ExtensionSettings\$Id ($root)." 'OK'
            } catch {
                Write-Log "$($Browser.Name): could not clear ExtensionSettings\$Id ($root): $($_.Exception.Message)" 'WARN'
            }
        }
    }
}

function Remove-ExternalRegistration {
    # Remove the HKLM external-extension registration keys that can silently
    # re-add the extension outside of policy (native + WOW6432Node views).
    param([hashtable]$Browser, [string]$Id)
    foreach ($path in @("HKLM:\SOFTWARE\$($Browser.ExtRegKey)\$Id", "HKLM:\SOFTWARE\Wow6432Node\$($Browser.ExtRegKey)\$Id")) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        if ($PSCmdlet.ShouldProcess($path, 'Remove external-registration key')) {
            try {
                Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
                Write-Log "$($Browser.Name): removed external-registration key." 'OK'
            } catch {
                Write-Log "$($Browser.Name): could not remove $path : $($_.Exception.Message)" 'WARN'
            }
        }
    }
}

function Remove-ExtensionFiles {
    # Delete the unpacked extension and its stored data from every browser
    # profile of every user.
    param([hashtable]$Browser, [string]$Id)
    foreach ($userRoot in Get-UserProfileRoots) {
        $userData = Join-Path $userRoot $Browser.UserData
        if (-not (Test-Path -LiteralPath $userData)) { continue }
        # Profiles sit directly under the user-data root (Default, Profile 1,
        # Guest Profile, ...); Opera keeps its profile at the root itself.
        $profileDirs = @($userData)
        $profileDirs += Get-ChildItem -LiteralPath $userData -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' -or $_.Name -like '*Profile' } |
            Select-Object -ExpandProperty FullName
        foreach ($profileDir in ($profileDirs | Select-Object -Unique)) {
            $targets = @(
                (Join-Path $profileDir "Extensions\$Id"),
                (Join-Path $profileDir "Local Extension Settings\$Id"),
                (Join-Path $profileDir "Sync Extension Settings\$Id"),
                (Join-Path $profileDir "Extension Rules\$Id"),
                (Join-Path $profileDir "Extension State\$Id")
            )
            foreach ($target in $targets) {
                if (-not (Test-Path -LiteralPath $target)) { continue }
                if ($PSCmdlet.ShouldProcess($target, 'Delete extension files')) {
                    try {
                        Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop
                        Write-Log "$($Browser.Name): deleted $target" 'OK'
                    } catch {
                        Write-Log "$($Browser.Name): could not delete $target (browser may be running): $($_.Exception.Message)" 'WARN'
                    }
                }
            }
        }
    }
}

function Uninstall-KeepAware {
    foreach ($browser in $ChromiumBrowsers) {
        foreach ($id in $ExtensionId) {
            Remove-ForcelistEntries     -Browser $browser -Id $id
            Remove-ExternalRegistration -Browser $browser -Id $id
            Remove-ExtensionFiles       -Browser $browser -Id $id
        }
    }
    # Firefox: drop any installed XPI copies (the policy block handles reinstall).
    if ($FirefoxAddonId.Count -gt 0) {
        foreach ($userRoot in Get-UserProfileRoots) {
            $profilesRoot = Join-Path $userRoot 'AppData\Roaming\Mozilla\Firefox\Profiles'
            if (-not (Test-Path -LiteralPath $profilesRoot)) { continue }
            foreach ($fid in $FirefoxAddonId) {
                Get-ChildItem -LiteralPath $profilesRoot -Recurse -Filter "$fid.xpi" -ErrorAction SilentlyContinue | ForEach-Object {
                    if ($PSCmdlet.ShouldProcess($_.FullName, 'Delete Firefox add-on')) {
                        try {
                            Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop
                            Write-Log "Firefox: deleted $($_.FullName)" 'OK'
                        } catch {
                            Write-Log "Firefox: could not delete $($_.FullName): $($_.Exception.Message)" 'WARN'
                        }
                    }
                }
            }
        }
    }
    Write-Log 'Uninstall pass complete.' 'OK'
}

# ---- Block: policy (browser blocklist) --------------------------------------
function Block-Policy {
    foreach ($browser in $ChromiumBrowsers) {
        $policyRoot   = "HKLM:\SOFTWARE\Policies\$($browser.PolicyKey)"
        $blocklistKey = Join-Path $policyRoot 'ExtensionInstallBlocklist'
        foreach ($id in $ExtensionId) {
            if ($PSCmdlet.ShouldProcess("$($browser.Name) $id", 'Add to ExtensionInstallBlocklist + set installation_mode=blocked')) {
                try {
                    if (-not (Test-Path -LiteralPath $blocklistKey)) { New-Item -Path $blocklistKey -Force | Out-Null }
                    $existing = Get-ItemProperty -LiteralPath $blocklistKey -ErrorAction SilentlyContinue
                    $already = $false; $maxIndex = 0
                    if ($existing) {
                        foreach ($p in $existing.PSObject.Properties) {
                            if ($p.Name -like 'PS*') { continue }
                            if ([string]$p.Value -eq $id) { $already = $true }
                            $n = 0
                            if ([int]::TryParse($p.Name, [ref]$n) -and $n -gt $maxIndex) { $maxIndex = $n }
                        }
                    }
                    if (-not $already) {
                        New-ItemProperty -LiteralPath $blocklistKey -Name ([string]($maxIndex + 1)) -Value $id -PropertyType String -Force | Out-Null
                    }
                    $settingsKey = Join-Path $policyRoot "ExtensionSettings\$id"
                    if (-not (Test-Path -LiteralPath $settingsKey)) { New-Item -Path $settingsKey -Force | Out-Null }
                    New-ItemProperty -LiteralPath $settingsKey -Name 'installation_mode' -Value 'blocked' -PropertyType String -Force | Out-Null
                    Write-Log "$($browser.Name): blocked $id." 'OK'
                } catch {
                    Write-Log "$($browser.Name): could not block $id : $($_.Exception.Message)" 'WARN'
                }
            }
        }
    }
    Invoke-FirefoxPolicy -Block
    Write-Log 'Policy block applied.' 'OK'
}

function Unblock-Policy {
    foreach ($browser in $ChromiumBrowsers) {
        $policyRoot   = "HKLM:\SOFTWARE\Policies\$($browser.PolicyKey)"
        $blocklistKey = Join-Path $policyRoot 'ExtensionInstallBlocklist'
        foreach ($id in $ExtensionId) {
            if (Test-Path -LiteralPath $blocklistKey) {
                $existing = Get-ItemProperty -LiteralPath $blocklistKey -ErrorAction SilentlyContinue
                if ($existing) {
                    foreach ($p in $existing.PSObject.Properties) {
                        if ($p.Name -like 'PS*') { continue }
                        if ([string]$p.Value -eq $id -and $PSCmdlet.ShouldProcess("$($browser.Name) blocklist '$($p.Name)'", 'Remove blocklist entry')) {
                            Remove-ItemProperty -LiteralPath $blocklistKey -Name $p.Name -Force -ErrorAction SilentlyContinue
                        }
                    }
                }
            }
            $settingsKey = Join-Path $policyRoot "ExtensionSettings\$id"
            if (Test-Path -LiteralPath $settingsKey) {
                $item = Get-ItemProperty -LiteralPath $settingsKey -ErrorAction SilentlyContinue
                $mode = if ($item -and $item.PSObject.Properties['installation_mode']) { $item.installation_mode } else { $null }
                # Only remove the node if WE set it to blocked (don't touch a
                # force_installed node an admin may still want).
                if ($mode -eq 'blocked' -and $PSCmdlet.ShouldProcess("$($browser.Name) ExtensionSettings\$id", 'Remove blocked ExtensionSettings')) {
                    Remove-Item -LiteralPath $settingsKey -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }
    Invoke-FirefoxPolicy -Unblock
    Write-Log 'Policy block removed.' 'OK'
}

function Invoke-FirefoxPolicy {
    # Merge (or remove) a blocked ExtensionSettings entry for each Firefox
    # add-on ID in each install's distribution\policies.json.
    param([switch]$Block, [switch]$Unblock)
    if ($FirefoxAddonId.Count -eq 0) {
        if ($Block) { Write-Log 'Firefox: no -FirefoxAddonId supplied; skipping Firefox policy block.' 'INFO' }
        return
    }
    foreach ($fxDir in $FirefoxInstallDirs) {
        if (-not (Test-Path -LiteralPath $fxDir)) { continue }
        $distDir      = Join-Path $fxDir 'distribution'
        $policiesFile = Join-Path $distDir 'policies.json'

        $policies = $null
        if (Test-Path -LiteralPath $policiesFile) {
            try { $policies = Get-Content -LiteralPath $policiesFile -Raw -ErrorAction Stop | ConvertFrom-Json }
            catch { $policies = $null }
        }
        $policyNode = $null
        if ($policies -and $policies.PSObject.Properties['policies']) { $policyNode = $policies.policies }

        # Start from whatever ExtensionSettings already exist.
        $extSettings = @{}
        if ($policyNode -and $policyNode.PSObject.Properties['ExtensionSettings']) {
            foreach ($prop in $policyNode.ExtensionSettings.PSObject.Properties) { $extSettings[$prop.Name] = $prop.Value }
        }
        foreach ($fid in $FirefoxAddonId) {
            if ($Block) {
                $extSettings[$fid] = @{ installation_mode = 'blocked'; blocked_install_message = 'Removed by IT.' }
            } elseif ($Unblock) {
                $extSettings.Remove($fid) | Out-Null
            }
        }

        if ($PSCmdlet.ShouldProcess($policiesFile, $(if ($Block) { 'Write Firefox extension block' } else { 'Remove Firefox extension block' }))) {
            try {
                $newPolicies = [ordered]@{ policies = [ordered]@{ } }
                if ($extSettings.Count -gt 0) { $newPolicies.policies['ExtensionSettings'] = $extSettings }
                if ($policyNode) {
                    foreach ($prop in $policyNode.PSObject.Properties) {
                        if ($prop.Name -ne 'ExtensionSettings') { $newPolicies.policies[$prop.Name] = $prop.Value }
                    }
                }
                if ($newPolicies.policies.Count -eq 0 -and (Test-Path -LiteralPath $policiesFile)) {
                    Remove-Item -LiteralPath $policiesFile -Force -ErrorAction SilentlyContinue
                } else {
                    if (-not (Test-Path -LiteralPath $distDir)) { New-Item -ItemType Directory -Path $distDir -Force | Out-Null }
                    $newPolicies | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $policiesFile -Encoding UTF8 -Force
                }
                Write-Log "Firefox: updated $policiesFile" 'OK'
            } catch {
                Write-Log "Firefox: could not update $policiesFile : $($_.Exception.Message)" 'WARN'
            }
        }
    }
}

# ---- Block: network ---------------------------------------------------------
function Block-Network {
    $existing = if (Test-Path $HostsPath) { Get-Content $HostsPath } else { @() }
    $toAdd = foreach ($d in $Domains) {
        if ($existing -notmatch [regex]::Escape($d)) { "0.0.0.0`t$d" }
    }
    if ($toAdd) {
        if ($PSCmdlet.ShouldProcess($HostsPath, "Sinkhole $($toAdd.Count) Keep Aware domain(s)")) {
            Add-Content -Path $HostsPath -Value ('', $HostsMarker + ' >>>')
            Add-Content -Path $HostsPath -Value $toAdd
            Add-Content -Path $HostsPath -Value ($HostsMarker + ' <<<')
            Write-Log "Sinkholed $($toAdd.Count) domain(s) in hosts file." 'OK'
        }
    } else {
        Write-Log 'Hosts file already contains the Keep Aware domains.' 'INFO'
    }
    $ruleName = "$FirewallTag domains"
    if (-not (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue)) {
        # Resolve the domains to IPs for an outbound block (best-effort; the
        # hosts sinkhole is the primary control).
        $ips = foreach ($d in $Domains) {
            try { (Resolve-DnsName -Name $d -Type A -ErrorAction Stop | Where-Object { $_.IPAddress }).IPAddress } catch { }
        }
        $ips = $ips | Where-Object { $_ } | Select-Object -Unique
        if ($ips -and $PSCmdlet.ShouldProcess($ruleName, 'Add outbound block to Keep Aware IPs')) {
            New-NetFirewallRule -DisplayName $ruleName -Direction Outbound -Action Block `
                -RemoteAddress $ips -Profile Any -ErrorAction SilentlyContinue | Out-Null
            Write-Log "Blocked outbound traffic to Keep Aware IPs: $($ips -join ', ')." 'OK'
        }
    }
    Write-Log 'Network block applied.' 'OK'
}

function Unblock-Network {
    if (Test-Path $HostsPath) {
        $content = Get-Content $HostsPath
        $start = ($content | Select-String -SimpleMatch ($HostsMarker + ' >>>')).LineNumber
        $end   = ($content | Select-String -SimpleMatch ($HostsMarker + ' <<<')).LineNumber
        if ($start -and $end -and $PSCmdlet.ShouldProcess($HostsPath, 'Remove Keep Aware sinkhole block')) {
            $kept = $content[0..($start - 2)] + $content[$end..($content.Count - 1)]
            Set-Content -Path $HostsPath -Value $kept
            Write-Log 'Removed Keep Aware domains from hosts file.' 'OK'
        }
    }
    Get-NetFirewallRule -DisplayName "$FirewallTag*" -ErrorAction SilentlyContinue | ForEach-Object {
        if ($PSCmdlet.ShouldProcess($_.DisplayName, 'Remove firewall rule')) {
            Remove-NetFirewallRule -DisplayName $_.DisplayName -ErrorAction SilentlyContinue
        }
    }
    Write-Log 'Network block removed.' 'OK'
}

# ---- Orchestration ----------------------------------------------------------
Write-Log "==== Remove-KeepAware starting (Mode=$Mode) ====" 'INFO'
Write-Log "Extension IDs: $($ExtensionId -join ', ')" 'INFO'

# If no explicit -Block* switch is given, default all blocks on for Full/Block.
if (-not ($BlockPolicy -or $BlockNetwork)) {
    $BlockPolicy = $true; $BlockNetwork = $true
}

switch ($Mode) {
    'Uninstall' {
        Uninstall-KeepAware
    }
    'Block' {
        if ($BlockPolicy)  { Block-Policy }
        if ($BlockNetwork) { Block-Network }
    }
    'Full' {
        Uninstall-KeepAware
        if ($BlockPolicy)  { Block-Policy }
        if ($BlockNetwork) { Block-Network }
    }
    'Restore' {
        Unblock-Policy
        Unblock-Network
        Write-Log 'Blocks removed. (This does not restore the force-install.)' 'INFO'
    }
}

if ($script:ManagedSourceFound -and $Mode -ne 'Restore') {
    Write-Log '' 'WARN'
    Write-Log 'ACTION REQUIRED - MANAGED DEPLOYMENT DETECTED.' 'WARN'
    Write-Log 'A machine-level force-install for Keep Aware was found. It is pushed by' 'WARN'
    Write-Log 'GPO / Intune / RMM and will be re-applied (and can override the local' 'WARN'
    Write-Log 'block) on the next policy refresh. Remove it at the source to finish:' 'WARN'
    Write-Log '  - AD Group Policy : delete the ExtensionInstallForcelist setting.' 'WARN'
    Write-Log '  - Intune / MDM    : remove the Keep Aware profile / app assignment.' 'WARN'
    Write-Log '  - RMM             : remove the policy/script that deploys it.' 'WARN'
    Write-Log '  - Keep Aware admin: unassign this device in the Keep Aware console.' 'WARN'
}

Write-Log "==== Remove-KeepAware finished (Mode=$Mode) ====" 'OK'
Write-Log "Log: $LogPath" 'INFO'
