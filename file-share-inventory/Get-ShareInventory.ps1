<#
.SYNOPSIS
    Read-only file share inventory for SharePoint / OneDrive migration planning.

.DESCRIPTION
    Collects, per server:
      - Shares and share settings, share permissions, NTFS permissions (share roots plus
        any folder with broken inheritance or explicit entries)
      - Size, file and folder counts, stale data and last activity per share and per
        top-level folder
      - File type breakdown and SharePoint blockers (long paths, invalid names, PST,
        QuickBooks, Access, very large files) plus access-denied paths
      - Who is connected and has files open now, volumes, installed apps, and
        non-Microsoft scheduled tasks
      - On domain controllers: GPO drive maps, logon script and folder redirection
        paths, AD users (home folders, UPNs), security groups and members, DFS namespaces

    Makes no changes. Only writes CSVs and a zip under -OutputRoot.

    Two ways to run:

      Local, on each server (elevated console, or NinjaOne as SYSTEM):
          .\Get-ShareInventory.ps1

      Remote, once from any one server (elevated, as a domain admin; uses WinRM and C$):
          .\Get-ShareInventory.ps1 -ComputerName FS01,DC01,APP01,HV01
        Each server scans in parallel, then the results are copied back and merged into
        ALL__*.csv files in one zip.

    Scan specific folders instead of SMB shares:
          .\Get-ShareInventory.ps1 -Path 'E:\Sales','D:\Archive'

.NOTES
    Run after hours. A full scan is I/O heavy, and guest VMs on the same host share its disks.
#>
[CmdletBinding()]
param(
    [string[]]$ComputerName,
    [string]$OutputRoot = 'C:\Temp\ShareInventory',
    [string[]]$Path,
    [int]$StaleYears = 3,
    [int]$NtfsDepth = 2
)

$ErrorActionPreference = 'Continue'
$stamp = Get-Date -Format 'yyyyMMdd-HHmm'

# ------------------------------------------------------------------ remote / collector mode
if ($ComputerName) {
    $collect = Join-Path $OutputRoot "Collected-$stamp"
    New-Item $collect -ItemType Directory -Force | Out-Null
    Write-Host "Scanning $($ComputerName -join ', ') in parallel. This can take a while on large shares..."

    $results = Invoke-Command -ComputerName $ComputerName -FilePath $PSCommandPath `
        -ArgumentList $null, $OutputRoot, $null, $StaleYears, $NtfsDepth `
        -ErrorAction SilentlyContinue -ErrorVariable remoteErr
    foreach ($e in $remoteErr) { Write-Warning "$($e.TargetObject): $($e.Exception.Message)" }

    foreach ($r in ($results | Where-Object { $_.Zip })) {
        $unc = "\\$($r.PSComputerName)\" + ($r.Zip -replace '^([A-Za-z]):', '$1$')
        $dest = Join-Path $collect $r.PSComputerName
        try {
            Copy-Item -LiteralPath $unc -Destination "$collect\" -ErrorAction Stop
            $local = Join-Path $collect (Split-Path $unc -Leaf)
            Expand-Archive -LiteralPath $local -DestinationPath $dest -Force
            Remove-Item -LiteralPath $local
            Write-Host "Collected $($r.PSComputerName)"
        } catch {
            Write-Warning "Could not pull $unc : $($_.Exception.Message)"
        }
    }

    Get-ChildItem $collect -Recurse -Filter *.csv |
        Group-Object { ($_.BaseName -split '__')[-1] } |
        ForEach-Object {
            $_.Group | ForEach-Object { Import-Csv -LiteralPath $_.FullName } |
                Export-Csv (Join-Path $collect "ALL__$($_.Name).csv") -NoTypeInformation -Encoding UTF8
        }

    $zipAll = "$collect.zip"
    Compress-Archive -Path "$collect\*" -DestinationPath $zipAll -Force
    $missing = $ComputerName | Where-Object { $_ -notin $results.PSComputerName }
    if ($missing) { Write-Warning "No results from: $($missing -join ', '). Run the script locally on those." }
    Write-Host "`nDone. Send this file back: $zipAll"
    return
}

# ------------------------------------------------------------------ local scan mode
$server = $env:COMPUTERNAME
$outDir = Join-Path $OutputRoot "$server-$stamp"
New-Item $outDir -ItemType Directory -Force | Out-Null
$scanStart = Get-Date
$cutoff = $scanStart.AddYears(-$StaleYears)

function Out-Inv($Data, [string]$Name) {
    if ($null -eq $Data) { return }
    @($Data) | Export-Csv (Join-Path $outDir "$server`__$Name.csv") -NoTypeInformation -Encoding UTF8
}

$badName  = '^(\.lock|CON|PRN|AUX|NUL|COM\d|LPT\d|desktop\.ini)(\..*)?$|_vti_|^~\$|^\s|\s$'
$flagExt  = @{
    '.pst' = 'Outlook PST'; '.ost' = 'Outlook OST'
    '.qbw' = 'QuickBooks company file'; '.qbb' = 'QuickBooks backup'; '.tlg' = 'QuickBooks log'; '.nd' = 'QuickBooks network data'
    '.mdb' = 'Access database'; '.accdb' = 'Access database'; '.ldb' = 'Access lock'; '.laccdb' = 'Access lock'
    '.mdf' = 'SQL data file'; '.ldf' = 'SQL log file'; '.vhd' = 'Virtual disk'; '.vhdx' = 'Virtual disk'
}
$genericRights = @{ '268435456' = 'FullControl (generic)'; '-536805376' = 'Modify (generic)'; '-1610612736' = 'ReadAndExecute (generic)' }

# ---------- shares
$excluded = 'NETLOGON', 'SYSVOL', 'print$'
if ($Path) {
    $shareList = foreach ($p in $Path) {
        $leaf = Split-Path $p -Leaf
        [pscustomobject]@{ Name = $(if ($leaf) { $leaf } else { $p }); Path = $p; Description = '(path scan)'
            FolderEnumerationMode = ''; CachingMode = ''; EncryptData = ''; CurrentUsers = ''; IsSmb = $false }
    }
} else {
    $shareList = Get-SmbShare | Where-Object {
        -not $_.Special -and "$($_.ShareType)" -eq 'FileSystemDirectory' -and $_.Path -and $_.Name -notin $excluded
    } | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; Path = $_.Path; Description = $_.Description
            FolderEnumerationMode = "$($_.FolderEnumerationMode)"; CachingMode = "$($_.CachingMode)"
            EncryptData = $_.EncryptData; CurrentUsers = $_.CurrentUsers; IsSmb = $true }
    }
}
$shareList = @($shareList)

function Get-ParentShare($s) {
    $me = $s.Path.TrimEnd('\') + '\'
    $shareList | Where-Object { $_.Name -ne $s.Name -and $me.StartsWith($_.Path.TrimEnd('\') + '\', 'OrdinalIgnoreCase') } |
        Sort-Object { $_.Path.Length } -Descending | Select-Object -First 1 -ExpandProperty Name
}

# ---------- per share scan
$summary = @(); $folders = @(); $exts = @(); $issues = @(); $scanErrors = @(); $ntfs = @(); $shareAcl = @()

foreach ($s in $shareList) {
    Write-Host "[$server] Scanning $($s.Name) ($($s.Path))..."
    $p = $s.Path.TrimEnd('\'); if ($p -match '^[A-Za-z]:$') { $p += '\' }
    $lp = if ($p -like '\\*') { $p } else { '\\?\' + $p }
    $rootLen = $lp.TrimEnd('\').Length + 1
    $display = $s.Path.TrimEnd('\')

    $files = 0; $dirs = 0; $bytes = 0; $staleBytes = 0; $p200 = 0; $p300 = 0; $bad = 0; $flagged = 0; $huge = 0
    $last = [datetime]::MinValue; $issueCount = 0
    $top = @{}; $ext = @{}; $errs = $null

    Get-ChildItem -LiteralPath $lp -Recurse -Force -ErrorAction SilentlyContinue -ErrorVariable errs | ForEach-Object {
        $rel = $_.FullName.Substring([math]::Min($rootLen, $_.FullName.Length))
        $issue = $null

        if ($_.PSIsContainer) {
            $dirs++
            if ($_.Name -match $badName) { $bad++; $issue = 'Invalid SharePoint folder name' }
        } else {
            $files++; $len = $_.Length; $bytes += $len
            if ($_.LastWriteTime -lt $cutoff) { $staleBytes += $len }
            if ($_.LastWriteTime -gt $last) { $last = $_.LastWriteTime }

            $seg = if ($rel.Contains('\')) { $rel.Substring(0, $rel.IndexOf('\')) } else { '(files in share root)' }
            if (-not $top.ContainsKey($seg)) { $top[$seg] = @{ Files = 0; Bytes = 0; Stale = 0; Last = [datetime]::MinValue } }
            $t = $top[$seg]; $t.Files++; $t.Bytes += $len
            if ($_.LastWriteTime -lt $cutoff) { $t.Stale += $len }
            if ($_.LastWriteTime -gt $t.Last) { $t.Last = $_.LastWriteTime }

            $e = $_.Extension.ToLower(); if (-not $e) { $e = '(none)' }
            if (-not $ext.ContainsKey($e)) { $ext[$e] = @{ Files = 0; Bytes = 0 } }
            $ext[$e].Files++; $ext[$e].Bytes += $len

            if ($len -gt 15GB) { $huge++ }
            if ($_.Name -match $badName) { $bad++; $issue = 'Invalid SharePoint file name' }
            elseif ($flagExt.ContainsKey($e)) { $flagged++; $issue = $flagExt[$e] }
            elseif ($len -gt 15GB) { $issue = 'File over 15 GB' }
        }

        if ($rel.Length -gt 200) { $p200++ }
        if ($rel.Length -gt 300) { $p300++; if (-not $issue) { $issue = 'Path over 300 chars' } }

        if ($issue -and $issueCount -lt 5000) {
            $issueCount++
            $issues += [pscustomobject]@{ Server = $server; Share = $s.Name; Issue = $issue
                Path = "$display\$rel"; PathLength = $rel.Length
                SizeMB = $(if ($_.PSIsContainer) { '' } else { [math]::Round($_.Length / 1MB, 2) })
                LastWrite = $_.LastWriteTime }
        }
    }

    foreach ($er in @($errs | Select-Object -First 1000)) {
        $scanErrors += [pscustomobject]@{ Server = $server; Share = $s.Name
            Path = ("$($er.TargetObject)" -replace '^\\\\\?\\', ''); Error = $er.Exception.Message }
    }

    $summary += [pscustomobject]@{
        Server = $server; Share = $s.Name; Path = $s.Path; Description = $s.Description; NestedInShare = (Get-ParentShare $s)
        Files = $files; Folders = $dirs; GB = [math]::Round($bytes / 1GB, 2)
        StaleGB = [math]::Round($staleBytes / 1GB, 2); StalePct = $(if ($bytes) { [math]::Round(100 * $staleBytes / $bytes, 1) } else { 0 })
        LastModified = $(if ($files) { $last } else { '' }); TopLevelFolders = $top.Count
        Paths200Plus = $p200; Paths300Plus = $p300; InvalidNames = $bad; FlaggedFileTypes = $flagged; FilesOver15GB = $huge
        AccessErrors = @($errs).Count; AccessBasedEnum = $s.FolderEnumerationMode; OfflineCaching = $s.CachingMode
        CurrentUsers = $s.CurrentUsers
    }

    foreach ($k in $top.Keys) {
        $t = $top[$k]
        $folders += [pscustomobject]@{ Server = $server; Share = $s.Name; Folder = $k; Files = $t.Files
            GB = [math]::Round($t.Bytes / 1GB, 3); StaleGB = [math]::Round($t.Stale / 1GB, 3); LastModified = $t.Last }
    }
    foreach ($k in $ext.Keys) {
        $exts += [pscustomobject]@{ Server = $server; Share = $s.Name; Extension = $k; Files = $ext[$k].Files
            GB = [math]::Round($ext[$k].Bytes / 1GB, 3) }
    }

    # share permissions
    if ($s.IsSmb) {
        $shareAcl += Get-SmbShareAccess -Name $s.Name -ErrorAction SilentlyContinue | ForEach-Object {
            [pscustomobject]@{ Server = $server; Share = $s.Name; Account = $_.AccountName
                Type = "$($_.AccessControlType)"; Right = "$($_.AccessRight)" }
        }
    }

    # NTFS permissions: root, plus folders with broken inheritance or explicit entries
    $aclDirs = @(Get-Item -LiteralPath $s.Path -Force -ErrorAction SilentlyContinue)
    $rootFull = if ($aclDirs.Count) { $aclDirs[0].FullName.TrimEnd('\') } else { $s.Path.TrimEnd('\') }
    if ($NtfsDepth -gt 0) {
        $aclDirs += @(Get-ChildItem -LiteralPath $s.Path -Directory -Force -Depth ($NtfsDepth - 1) -ErrorAction SilentlyContinue)
    }
    foreach ($d in $aclDirs) {
        $acl = Get-Acl -LiteralPath $d.FullName -ErrorAction SilentlyContinue
        if (-not $acl) { continue }
        $isRoot = $d.FullName.TrimEnd('\') -eq $rootFull
        $explicit = @($acl.Access | Where-Object { -not $_.IsInherited })
        if (-not ($isRoot -or $acl.AreAccessRulesProtected -or $explicit.Count)) { continue }
        $rules = if ($isRoot -or $acl.AreAccessRulesProtected) { $acl.Access } else { $explicit }
        foreach ($a in $rules) {
            $r = "$([int]$a.FileSystemRights)"
            $ntfs += [pscustomobject]@{ Server = $server; Share = $s.Name; Folder = $d.FullName
                Level = $(if ($isRoot) { 'ShareRoot' } else { 'Subfolder' })
                InheritanceBroken = $acl.AreAccessRulesProtected; Owner = $acl.Owner
                Identity = "$($a.IdentityReference)"; Orphaned = ("$($a.IdentityReference)" -match '^S-1-5-21-')
                Rights = $(if ($genericRights.ContainsKey($r)) { $genericRights[$r] } else { "$($a.FileSystemRights)" })
                Type = "$($a.AccessControlType)"; Inherited = $a.IsInherited
                AppliesTo = "$($a.InheritanceFlags)" }
        }
    }
}

Out-Inv $shareList 'Shares'
Out-Inv $summary 'ShareSummary'
Out-Inv $folders 'TopFolders'
Out-Inv $exts 'FileTypes'
Out-Inv $issues 'MigrationIssues'
Out-Inv $scanErrors 'AccessErrors'
Out-Inv $shareAcl 'SharePermissions'
Out-Inv $ntfs 'NtfsPermissions'

# ---------- activity: sessions and open files right now
$sharePaths = $shareList | Sort-Object { $_.Path.Length } -Descending
Out-Inv (Get-SmbSession -ErrorAction SilentlyContinue | ForEach-Object {
    [pscustomobject]@{ Server = $server; User = $_.ClientUserName; Computer = $_.ClientComputerName
        OpenFiles = $_.NumOpens; SecondsIdle = $_.SecondsIdle; Dialect = $_.Dialect }
}) 'Sessions'

Out-Inv (Get-SmbOpenFile -ErrorAction SilentlyContinue | ForEach-Object {
    $fp = $_.Path
    $sh = $sharePaths | Where-Object { $fp.StartsWith($_.Path.TrimEnd('\') + '\', 'OrdinalIgnoreCase') -or $fp -eq $_.Path } |
        Select-Object -First 1 -ExpandProperty Name
    [pscustomobject]@{ Share = $(if ($sh) { $sh } else { '(other)' }); User = $_.ClientUserName; Computer = $_.ClientComputerName }
} | Group-Object Share, User, Computer | ForEach-Object {
    $f = $_.Group[0]
    [pscustomobject]@{ Server = $server; Share = $f.Share; User = $f.User; Computer = $f.Computer; OpenFiles = $_.Count }
}) 'OpenFiles'

# ---------- server context
Out-Inv (Get-Volume -ErrorAction SilentlyContinue | Where-Object DriveLetter | ForEach-Object {
    [pscustomobject]@{ Server = $server; Drive = "$($_.DriveLetter):"; Label = $_.FileSystemLabel; FileSystem = $_.FileSystem
        SizeGB = [math]::Round($_.Size / 1GB, 1); FreeGB = [math]::Round($_.SizeRemaining / 1GB, 1)
        UsedGB = [math]::Round(($_.Size - $_.SizeRemaining) / 1GB, 1) }
}) 'Volumes'

Out-Inv (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -and $_.SystemComponent -ne 1 -and -not $_.ParentKeyName } |
    Sort-Object DisplayName -Unique | ForEach-Object {
        [pscustomobject]@{ Server = $server; Name = $_.DisplayName; Version = $_.DisplayVersion
            Publisher = $_.Publisher; InstallLocation = $_.InstallLocation }
    }) 'InstalledApps'

Out-Inv (Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskPath -notlike '\Microsoft\*' } | ForEach-Object {
    $t = $_
    foreach ($a in @($t.Actions)) {
        [pscustomobject]@{ Server = $server; Task = "$($t.TaskPath)$($t.TaskName)"; State = "$($t.State)"
            RunAs = $t.Principal.UserId; Execute = $a.Execute; Arguments = $a.Arguments; WorkingDir = $a.WorkingDirectory }
    }
}) 'ScheduledTasks'

$cs = Get-CimInstance Win32_ComputerSystem
$os = Get-CimInstance Win32_OperatingSystem
$isDC = $cs.DomainRole -ge 4
$roles = try { (Get-WindowsFeature -ErrorAction Stop | Where-Object { $_.Installed -and $_.FeatureType -eq 'Role' }).Name -join '; ' } catch { '' }

# ---------- domain controller extras
if ($isDC) {
    Write-Host "[$server] Domain controller: collecting drive maps, scripts, users, groups..."
    $domain = $cs.Domain
    $sysvol = (Get-SmbShare -Name SYSVOL -ErrorAction SilentlyContinue).Path
    $netlogon = (Get-SmbShare -Name NETLOGON -ErrorAction SilentlyContinue).Path
    $policies = if ($sysvol) { Join-Path $sysvol "$domain\Policies" }

    $gpoNames = @{}
    try {
        Import-Module GroupPolicy -ErrorAction Stop
        Get-GPO -All | ForEach-Object { $gpoNames["{$($_.Id)}".ToUpper()] = $_.DisplayName }
    } catch {}
    function Get-GpoGuid($full) {
        if ($policies -and $full.StartsWith($policies, 'OrdinalIgnoreCase')) { ($full.Substring($policies.Length + 1) -split '\\')[0].ToUpper() }
    }

    if ($policies -and (Test-Path $policies)) {
        Out-Inv (Get-ChildItem -LiteralPath $policies -Recurse -Filter Drives.xml -Force -ErrorAction SilentlyContinue | ForEach-Object {
            $g = Get-GpoGuid $_.FullName
            $scope = if ($_.FullName -match '\\Machine\\') { 'Computer' } else { 'User' }
            [xml]$x = Get-Content -LiteralPath $_.FullName -Raw
            foreach ($d in $x.SelectNodes('//Drive')) {
                $pr = $d.SelectSingleNode('Properties')
                [pscustomobject]@{ Server = $server; GPO = $gpoNames[$g]; GpoGuid = $g; Scope = $scope
                    Letter = $pr.letter; UncPath = $pr.path; Action = $pr.action; Label = $pr.label
                    Disabled = $d.disabled
                    Targeting = (($d.SelectNodes('Filters/*') | ForEach-Object { "$($_.LocalName)=$($_.name)" }) -join '; ') }
            }
        }) 'GpoDriveMaps'
    }

    $pattern = '(?i)net\s+use|MapNetworkDrive|New-PSDrive|New-SmbMapping|\\\\[A-Za-z0-9\-\.]+\\'
    $refs = @()
    if ($netlogon -and (Test-Path $netlogon)) {
        $refs += Get-ChildItem -LiteralPath $netlogon -Recurse -File -Force -Include *.bat, *.cmd, *.vbs, *.ps1, *.kix -ErrorAction SilentlyContinue |
            Select-String -Pattern $pattern | ForEach-Object {
                [pscustomobject]@{ Server = $server; Source = 'NETLOGON script'; GPO = ''; File = $_.Path; Line = $_.LineNumber; Text = $_.Line.Trim() }
            }
    }
    if ($policies -and (Test-Path $policies)) {
        $refs += Get-ChildItem -LiteralPath $policies -Recurse -File -Force -Include *.bat, *.cmd, *.vbs, *.ps1, *.kix, scripts.ini, psscripts.ini, fdeploy*.ini -ErrorAction SilentlyContinue |
            Select-String -Pattern $pattern | ForEach-Object {
                $src = if ($_.Path -match 'fdeploy') { 'Folder redirection' } else { 'GPO script' }
                [pscustomobject]@{ Server = $server; Source = $src; GPO = $gpoNames[(Get-GpoGuid $_.Path)]; File = $_.Path; Line = $_.LineNumber; Text = $_.Line.Trim() }
            }
    }
    Out-Inv $refs 'DcPathReferences'

    try {
        Import-Module ActiveDirectory -ErrorAction Stop
        Out-Inv (Get-ADUser -Filter * -Properties DisplayName, mail, Enabled, LastLogonDate, HomeDirectory, HomeDrive, ProfilePath, ScriptPath, Department, Title |
            ForEach-Object {
                [pscustomobject]@{ Server = $server; SamAccountName = $_.SamAccountName; DisplayName = $_.DisplayName
                    UPN = $_.UserPrincipalName; Mail = $_.mail; Enabled = $_.Enabled; LastLogon = $_.LastLogonDate
                    Department = $_.Department; Title = $_.Title; HomeDrive = $_.HomeDrive; HomeDirectory = $_.HomeDirectory
                    ProfilePath = $_.ProfilePath; LogonScript = $_.ScriptPath }
            }) 'AdUsers'

        $groupRows = foreach ($g in (Get-ADGroup -Filter 'GroupCategory -eq "Security"' -Properties Description, Members)) {
            if ($g.DistinguishedName -match 'CN=Builtin,') { continue }
            if (-not $g.Members.Count) {
                [pscustomobject]@{ Server = $server; Group = $g.Name; Scope = "$($g.GroupScope)"; Description = $g.Description; Member = ''; MemberType = '' }
                continue
            }
            foreach ($m in $g.Members) {
                # AD cmdlets throw on not-found even with SilentlyContinue; don't let one member kill the export
                $o = try { Get-ADObject -Identity $m -Properties sAMAccountName -ErrorAction Stop } catch { $null }
                [pscustomobject]@{ Server = $server; Group = $g.Name; Scope = "$($g.GroupScope)"; Description = $g.Description
                    Member = $(if ($o.sAMAccountName) { $o.sAMAccountName } else { $m }); MemberType = $o.ObjectClass }
            }
        }
        Out-Inv $groupRows 'AdGroupMembers'
    } catch { Write-Warning "AD collection skipped: $($_.Exception.Message)" }
}

try {
    Import-Module DFSN -ErrorAction Stop
    Out-Inv (Get-DfsnRoot -ErrorAction Stop | ForEach-Object {
        $root = $_.Path
        Get-DfsnFolder -Path "$root\*" -ErrorAction SilentlyContinue | ForEach-Object {
            Get-DfsnFolderTarget -Path $_.Path -ErrorAction SilentlyContinue | ForEach-Object {
                [pscustomobject]@{ Server = $server; Root = $root; Folder = $_.Path; Target = $_.TargetPath; State = "$($_.State)" }
            }
        }
    }) 'DfsNamespaces'
} catch {}

Out-Inv ([pscustomobject]@{
    Server = $server; OS = $os.Caption; Build = $os.BuildNumber; Domain = $cs.Domain; IsDomainController = $isDC
    Roles = $roles; EntraConnectInstalled = [bool](Get-Service ADSync -ErrorAction SilentlyContinue)
    LongPathsEnabled = ((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -ErrorAction SilentlyContinue).LongPathsEnabled -eq 1)
    RunAs = [Security.Principal.WindowsIdentity]::GetCurrent().Name; SharesScanned = $shareList.Count
    ScanStart = $scanStart; ScanEnd = Get-Date; Minutes = [math]::Round(((Get-Date) - $scanStart).TotalMinutes, 1)
}) 'ServerInfo'

# ---------- package
$zip = "$outDir.zip"
Compress-Archive -Path "$outDir\*" -DestinationPath $zip -Force
Write-Host ($summary | Format-Table Share, GB, Files, StaleGB, Paths300Plus, InvalidNames, FlaggedFileTypes, AccessErrors -AutoSize | Out-String)
Write-Host "[$server] Done. Output: $zip"
[pscustomobject]@{ Server = $server; Zip = $zip; Shares = $shareList.Count }
