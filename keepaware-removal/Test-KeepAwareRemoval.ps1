<#
.SYNOPSIS
    Verifies that the Keep Aware browser extension is removed and that the
    blocks applied by Remove-KeepAware.ps1 are in place.

.DESCRIPTION
    Read-only. Prints a pass/fail line per check and exits non-zero if the
    extension is still force-installed / present on disk, or any block is
    missing.

.PARAMETER ExtensionId
    Chromium extension IDs to check. Defaults to the Keep Aware Chrome Web Store ID.

.PARAMETER CheckNetwork
    Also verify the hosts sinkhole + firewall network block (only meaningful if
    Remove-KeepAware.ps1 was run with the network block enabled).

.EXAMPLE
    .\Test-KeepAwareRemoval.ps1

.EXAMPLE
    .\Test-KeepAwareRemoval.ps1 -CheckNetwork
#>
[CmdletBinding()]
param(
    [string[]]$ExtensionId = @('camnmdjjfkcplbdlofbndmkmnfeegjoi'),
    [switch]$CheckNetwork
)

$ChromiumBrowsers = @(
    @{ Name = 'Google Chrome' ; PolicyKey = 'Google\Chrome'        ; ExtRegKey = 'Google\Chrome\Extensions'      ; UserData = 'AppData\Local\Google\Chrome\User Data' }
    @{ Name = 'Microsoft Edge'; PolicyKey = 'Microsoft\Edge'       ; ExtRegKey = 'Microsoft\Edge\Extensions'      ; UserData = 'AppData\Local\Microsoft\Edge\User Data' }
    @{ Name = 'Brave'         ; PolicyKey = 'BraveSoftware\Brave'  ; ExtRegKey = 'BraveSoftware\Brave\Extensions' ; UserData = 'AppData\Local\BraveSoftware\Brave-Browser\User Data' }
    @{ Name = 'Vivaldi'       ; PolicyKey = 'Vivaldi'              ; ExtRegKey = 'Vivaldi\Extensions'             ; UserData = 'AppData\Local\Vivaldi\User Data' }
    @{ Name = 'Opera'         ; PolicyKey = 'Opera Software\Opera' ; ExtRegKey = 'Opera Software\Opera\Extensions'; UserData = 'AppData\Roaming\Opera Software\Opera Stable' }
    @{ Name = 'Chromium'      ; PolicyKey = 'Chromium'             ; ExtRegKey = 'Chromium\Extensions'            ; UserData = 'AppData\Local\Chromium\User Data' }
)
$HostsPath = Join-Path $env:WINDIR 'System32\drivers\etc\hosts'

$fail = 0
function Check {
    param([string]$Name, [bool]$Pass, [string]$Detail)
    if ($Pass) { $tag = '[PASS]'; $color = 'Green' } else { $tag = '[FAIL]'; $color = 'Red'; $script:fail++ }
    Write-Host ("{0} {1}{2}" -f $tag, $Name, $(if ($Detail) { " - $Detail" } else { '' })) -ForegroundColor $color
}

function Get-UserProfileRoots {
    $usersRoot = Join-Path $env:SystemDrive 'Users'
    if (-not (Test-Path -LiteralPath $usersRoot)) { return @() }
    $skip = @('Public', 'All Users', 'Default User')
    Get-ChildItem -LiteralPath $usersRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $skip -notcontains $_.Name } | Select-Object -ExpandProperty FullName
}

function Test-ForcelistReferences {
    param([hashtable]$Browser, [string]$Id)
    foreach ($root in @('HKLM', 'HKCU')) {
        $forcelist = "$root:\SOFTWARE\Policies\$($Browser.PolicyKey)\ExtensionInstallForcelist"
        if (Test-Path -LiteralPath $forcelist) {
            $props = Get-ItemProperty -LiteralPath $forcelist -ErrorAction SilentlyContinue
            if ($props) {
                foreach ($p in $props.PSObject.Properties) {
                    if ($p.Name -like 'PS*') { continue }
                    if ((([string]$p.Value) -split ';')[0].Trim() -eq $Id) { return $true }
                }
            }
        }
        $settings = "$root:\SOFTWARE\Policies\$($Browser.PolicyKey)\ExtensionSettings\$Id"
        if (Test-Path -LiteralPath $settings) {
            $item = Get-ItemProperty -LiteralPath $settings -ErrorAction SilentlyContinue
            if ($item -and $item.PSObject.Properties['installation_mode'] -and $item.installation_mode -eq 'force_installed') { return $true }
        }
    }
    return $false
}

function Test-BlockPresent {
    param([hashtable]$Browser, [string]$Id)
    $blocklistKey = "HKLM:\SOFTWARE\Policies\$($Browser.PolicyKey)\ExtensionInstallBlocklist"
    if (Test-Path -LiteralPath $blocklistKey) {
        $props = Get-ItemProperty -LiteralPath $blocklistKey -ErrorAction SilentlyContinue
        if ($props) {
            foreach ($p in $props.PSObject.Properties) {
                if ($p.Name -like 'PS*') { continue }
                if ([string]$p.Value -eq $Id -or [string]$p.Value -eq '*') { return $true }
            }
        }
    }
    $settings = "HKLM:\SOFTWARE\Policies\$($Browser.PolicyKey)\ExtensionSettings\$Id"
    if (Test-Path -LiteralPath $settings) {
        $item = Get-ItemProperty -LiteralPath $settings -ErrorAction SilentlyContinue
        if ($item -and $item.PSObject.Properties['installation_mode'] -and $item.installation_mode -eq 'blocked') { return $true }
    }
    return $false
}

function Test-ExtensionFilesPresent {
    param([hashtable]$Browser, [string]$Id)
    foreach ($userRoot in Get-UserProfileRoots) {
        $userData = Join-Path $userRoot $Browser.UserData
        if (-not (Test-Path -LiteralPath $userData)) { continue }
        $profileDirs = @($userData)
        $profileDirs += Get-ChildItem -LiteralPath $userData -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' -or $_.Name -like '*Profile' } |
            Select-Object -ExpandProperty FullName
        foreach ($profileDir in ($profileDirs | Select-Object -Unique)) {
            if (Test-Path -LiteralPath (Join-Path $profileDir "Extensions\$Id")) { return $true }
        }
    }
    return $false
}

foreach ($browser in $ChromiumBrowsers) {
    foreach ($id in $ExtensionId) {
        Check "$($browser.Name): not force-installed" (-not (Test-ForcelistReferences -Browser $browser -Id $id))
        Check "$($browser.Name): reinstall blocked"   (Test-BlockPresent -Browser $browser -Id $id)
        Check "$($browser.Name): extension files gone" (-not (Test-ExtensionFilesPresent -Browser $browser -Id $id))
        $extReg = (Test-Path -LiteralPath "HKLM:\SOFTWARE\$($browser.ExtRegKey)\$id") -or
                  (Test-Path -LiteralPath "HKLM:\SOFTWARE\Wow6432Node\$($browser.ExtRegKey)\$id")
        Check "$($browser.Name): no side-load registration" (-not $extReg)
    }
}

if ($CheckNetwork) {
    $hostsOk = (Test-Path $HostsPath) -and ((Get-Content $HostsPath -Raw) -match 'keepaware\.com')
    Check 'Hosts sinkhole present' $hostsOk
    $fwOk = [bool](Get-NetFirewallRule -DisplayName 'KeepAware-Block*' -ErrorAction SilentlyContinue)
    Check 'Firewall block rules present' $fwOk
}

Write-Host ''
if ($fail -eq 0) {
    Write-Host 'All checks passed.' -ForegroundColor Green
    exit 0
} else {
    Write-Host "$fail check(s) failed." -ForegroundColor Red
    exit 1
}
