# rapidrecovery-repo-sparsify

> Reclaims pre-provisioned empty space from Quest Rapid Recovery DVM repository container files by converting them to NTFS sparse files and punching out the never-written zero regions.

Quest Rapid Recovery DVM repositories use thick / pre-provisioned container files
(`dfs.records`, `dfs.bmap`, `dfs.rmap`, etc.). These files are allocated at the
repository's full configured size up front and never shrink, even when the repo is
only ~30% full. `SparsifyMT.ps1` scans these container files for runs of zero bytes
(the never-written, pre-provisioned space), marks each file NTFS-sparse, and punches
out the zero regions via `FSCTL_SET_ZERO_DATA`, returning that space to the volume.
`WatchSize.ps1` is a live monitor for a second PowerShell window that shows a target
file's actual size-on-disk (allocated bytes, via `GetCompressedFileSize`) shrinking
and the volume's free space rising in real time.

## Files

| File | Purpose |
|------|---------|
| `SparsifyMT.ps1` | Multi-threaded scanner/sparsifier. Measure-only by default; with `-Apply` it sets the NTFS sparse flag and punches zero ranges via `FSCTL_SET_ZERO_DATA`. Includes a `-Sweep` benchmark to find the fastest thread count for the underlying storage. |
| `WatchSize.ps1` | Read-only live monitor. Polls a file's on-disk (allocated) size via the Win32 `GetCompressedFileSize` API plus volume free space, and reports freed bytes and a GB/min reclaim rate. Safe to run against a file another process holds open. |
| `README.md` | This runbook. |

## Prerequisites

- Windows with an **NTFS** volume (NTFS sparse-file support is required).
- An **elevated / Administrator** PowerShell session.
- **.NET** for `Add-Type` / P-Invoke — Windows PowerShell 5.1 is fine.
- The **Rapid Recovery Core service stopped** during an `-Apply` run so the container
  files are unlocked (confirm the exact name with `Get-Service *rapid*`).
- A big enough **maintenance window**. This is I/O-bound: a 32 TB file on a 6-drive
  7.2K SAS RAID array can take roughly **8–15 hours**.

## Usage

Run everything **as Administrator**, and **locally on the storage server** — never over
a UNC / SMB share (reading many TB over SMB is drastically slower).

```powershell
# 1. Measure / find the sweet spot first (safe, read-only — never writes):
.\SparsifyMT.ps1 -RepoPath "E:\Repository" -Sweep

# 2. Stop the Rapid Recovery Core service so the container files unlock
#    (confirm the exact service name first: Get-Service *rapid*):
Stop-Service "Rapid Recovery Core" -Force

# 3. Record free space, then apply with the fastest thread count from the sweep:
Get-PSDrive E | Select Used,Free
.\SparsifyMT.ps1 -RepoPath "E:\Repository" -Apply -Threads 4

# 4. Optionally, in a SECOND elevated PowerShell window, watch a file live:
.\WatchSize.ps1 -File "E:\Repository\dfs.records" -IntervalSec 5

# 5. Verify space was returned, then restart the Core:
Get-PSDrive E | Select Used,Free
Start-Service "Rapid Recovery Core"
```

After the restart, check repository integrity in the Core console and run a **test
backup AND a test restore** before trusting it — and validate on a throwaway **TEST
repository** before ever touching production.

### `SparsifyMT.ps1` parameters and modes

- `-RepoPath` *(mandatory)* — a repository **folder** (processes every file
  `>= -MinSizeBytes`, default 1 GB) **or** a single **file** path.
- `-Sweep` *(switch)* — measure-only benchmark that runs each thread count in
  `-SweepThreads` (default `2,4,8`) and prints a table sorted by throughput, naming the
  fastest. Never writes; ignores `-Apply`.
- `-Apply` *(switch)* — actually sets the sparse flag and punches zero ranges. Omit for
  a safe measure-only pass that reports reclaimable GB.
- `-Threads` *(int, default = logical processor count)* — worker threads for a normal
  run. Each thread scans a 64 KB-aligned contiguous byte range of the file with its own
  handle.
- `-SweepThreads` *(int[], default `2,4,8`)* — thread counts tried in `-Sweep`.
- `-MinSizeBytes` *(long, default 1 GB)* — skip files smaller than this when
  `-RepoPath` is a folder.

Progress: prints a fresh line every 5 s with percent, GB scanned, GB/s, zeros found,
and ETA.

### `WatchSize.ps1` parameters

- `-File` *(mandatory)* — the file to monitor, e.g. `E:\Repository\dfs.records`.
- `-IntervalSec` *(int, default 5)* — refresh interval.

Shows on-disk (allocated) size, total freed since start, volume free space and delta,
and a GB/min reclaim rate. Read-only; uses the Win32 `GetCompressedFileSize` API so it
does not conflict with the file lock held by the worker.

## Verification

| Test | How | Expected |
|------|-----|----------|
| Scripts parse | `[System.Management.Automation.PSParser]::Tokenize((Get-Content .\SparsifyMT.ps1 -Raw),[ref]$null)` | No parse errors. |
| Find fastest thread count | `.\SparsifyMT.ps1 -RepoPath "E:\Repository" -Sweep` | Table of thread counts by throughput; fastest is named. No files modified. |
| Measure reclaimable space | `.\SparsifyMT.ps1 -RepoPath "E:\Repository"` (no `-Apply`) | Reports reclaimable GB; volume free space unchanged. |
| Reclaim space | `.\SparsifyMT.ps1 -RepoPath "E:\Repository" -Apply -Threads 4` (Core stopped) | On-disk size drops; `Get-PSDrive E` free space rises. |
| Watch live | `.\WatchSize.ps1 -File "E:\Repository\dfs.records"` in a 2nd window | On-disk size shrinks, freed total and volume free space climb. |
| Integrity after restart | Restart Core, check repo in console, run test backup + restore | Repository healthy; backup and restore succeed. |

## Notes

- **Only genuinely-zero (never-written) space is reclaimed.** Regions that DVM freed
  internally but that still hold stale, already-compressed blocks are **not** zeros and
  will not be reclaimed — actual recovered space can be well below the repo's reported
  free percentage.
- **Thread count depends on the media.** The target storage here is spinning SAS HDD
  (Dell ST8000NM0185, 8 TB 7.2K) in RAID. On rotational media, high thread counts cause
  seek thrashing and go **slower**; ~2–4 threads (near the spindle count) is usually
  optimal. Use `-Sweep` to find it. High thread counts only help on SSD / flash.
- **Fragmentation.** Making a live backup container sparse causes fragmentation, which
  can degrade backup/restore performance more on HDD than SSD. Validate on a test repo
  first.
- **Effectively one-way.** The sparse flag cannot be cleanly reversed — there is no
  supported way to un-sparse the file.
- **Unsupported by Quest.** This is an unsupported maintenance maneuver. The supported
  alternatives for permanently reducing footprint are relocating the repository or
  migrating protected machines to a right-sized repository.
- **`-Sweep` caching caveat.** `-Sweep` on a file smaller than system RAM can report
  inflated throughput on later passes due to OS file caching; on multi-TB production
  files that is not a factor.
