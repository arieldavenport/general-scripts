# file-share-inventory

> Read-only inventory of Windows file servers for SharePoint / OneDrive migration
> planning: shares, permissions, sizes, stale data, migration blockers, current
> usage, and (on domain controllers) drive maps, logon scripts, users and groups.

Data flow:
**scan each server (locally or via WinRM) → per-server CSVs + zip → (remote mode) pull zips over `C$` → merged `ALL__*.csv` → one zip**

## Files

| File | Purpose |
|------|---------|
| `Get-ShareInventory.ps1` | The scanner. Runs locally on one server, or with `-ComputerName` fans out to several servers in parallel and merges the results. Makes no changes; only writes under `-OutputRoot`. |

## What it collects

| CSV | Contents |
|-----|----------|
| `Shares` | SMB shares scanned (excludes admin shares, `NETLOGON`, `SYSVOL`, `print$`) and their settings. |
| `ShareSummary` | Per share: files, folders, GB, stale GB/%, last modified, long-path counts, invalid names, flagged file types, files over 15 GB, access errors, ABE, offline caching, nested-in-share. |
| `TopFolders` | Size, stale GB and last modified per top-level folder. |
| `FileTypes` | File count and GB per extension. |
| `MigrationIssues` | Up to 5,000 rows per share: invalid SharePoint names, PST/OST, QuickBooks, Access, SQL, VHD(X), paths over 300 chars, files over 15 GB. |
| `AccessErrors` | Up to 1,000 paths per share the scan couldn't read. |
| `SharePermissions` | Share-level ACLs. |
| `NtfsPermissions` | NTFS ACLs on each share root, plus folders (to `-NtfsDepth`) with broken inheritance or explicit entries. Flags orphaned SIDs. |
| `Sessions`, `OpenFiles` | Who is connected and which shares have files open right now. |
| `Volumes`, `InstalledApps`, `ScheduledTasks`, `ServerInfo` | Server context (non-Microsoft scheduled tasks only). |
| `GpoDriveMaps`, `DcPathReferences`, `AdUsers`, `AdGroupMembers` | Domain controllers only: GPP drive maps, UNC paths in NETLOGON / GPO scripts / folder redirection, users (home folders, UPNs), security group members. |
| `DfsNamespaces` | DFS namespace folders and targets, where the server hosts a root. |

## Prerequisites

- Windows Server with PowerShell 5.1+, run **elevated** (or as SYSTEM, e.g. from an RMM).
- On DCs: the `ActiveDirectory` and `GroupPolicy` modules (present on DCs by default).
- Remote mode only: WinRM enabled on the targets, a domain admin account, and
  the `C$` admin share reachable from the collecting server.

## Usage

```powershell
# Local, on each server:
.\Get-ShareInventory.ps1

# Remote, once from any server; each target scans in parallel, results merged:
.\Get-ShareInventory.ps1 -ComputerName FS01,DC01,APP01

# Scan specific folders instead of SMB shares (local mode):
.\Get-ShareInventory.ps1 -Path 'E:\Sales','D:\Archive'
```

| Parameter | Default | Meaning |
|-----------|---------|---------|
| `-ComputerName` | (none) | Run remotely on these servers and merge results. |
| `-OutputRoot` | `C:\Temp\ShareInventory` | Where CSVs and zips are written (on each server). Must be a local drive path for remote collection. |
| `-Path` | (none) | Folders to scan instead of SMB shares. Ignored in remote mode. |
| `-StaleYears` | `3` | Files not written in this many years count as stale. |
| `-NtfsDepth` | `2` | Folder depth below each share root to check for non-inherited ACLs. `0` = root only. |

Output: `<OutputRoot>\<SERVER>-<yyyyMMdd-HHmm>.zip` per server, or
`<OutputRoot>\Collected-<stamp>.zip` in remote mode.

## Verification

| Test | How | Expected |
|------|-----|----------|
| Local scan | `.\Get-ShareInventory.ps1` on a file server | Summary table printed; zip contains `SERVER__ShareSummary.csv` etc. with one row per share. |
| Path scan | `-Path C:\Temp` | `ShareSummary` row for the folder; `SharePermissions` absent. |
| DC extras | Run on a DC | `AdUsers`, `AdGroupMembers`, `GpoDriveMaps` / `DcPathReferences` (if any exist) present. |
| Remote | `-ComputerName` with one unreachable name | Warning naming the unreachable server; zip contains `ALL__*.csv` for the rest. |
| Read-only | Compare share contents/ACLs before and after | No changes outside `-OutputRoot`. |

## Notes

- **Run after hours.** The full recursive scan is I/O heavy; VMs on one host share its disks.
- Sizes are logical (what you'd migrate), from `LastWriteTime`; last-access time isn't used.
- Path lengths are measured **relative to the share root**. SharePoint's 400-char
  limit applies to the full decoded URL (site + library + path), so treat the
  200/300 thresholds as a margin, not an exact test.
- "Files over 15 GB" reflects an older SharePoint upload limit; the current limit
  is 250 GB, so treat these as sync/upload pain points rather than hard blockers.
- `TopLevelFolders` and `TopFolders` count only folders containing files, plus a
  `(files in share root)` bucket.
- Group membership comes from the `member` attribute, so primary-group
  membership (e.g. Domain Users) isn't listed.
