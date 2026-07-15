# keepaware-removal

> Forcefully removes the Keep Aware browser security extension and blocks it
> from reinstalling, with a one-command rollback.

Removal flow:
**delete force-install policy → delete side-load registration → delete on-disk extension → block (browser policy + network)**

## Files

| File | Purpose |
|------|---------|
| `Remove-KeepAware.ps1` | Main script. Removes the extension and applies the reinstall blocks. Supports `-Mode Full/Uninstall/Block/Restore` and `-WhatIf`. |
| `Test-KeepAwareRemoval.ps1` | Read-only verification. Confirms the extension is gone/blocked in every browser; exits non-zero on any failure. |

## What it does

Keep Aware is an *agentless* browser security product: there is no MSI and no
Windows service. It ships as a **force-installed browser extension**, pushed via
MDM / Group Policy / Intune using the Chromium `ExtensionInstallForcelist`
policy (and the Firefox `ExtensionSettings` policy). A browser silently re-adds
a force-installed extension on the next launch, so "remove from the browser"
does nothing. The script instead:

1. **Uninstall** — for Chrome, Edge, Brave, Vivaldi, Opera and Chromium (which
   share the Keep Aware Chrome Web Store ID `camnmdjjfkcplbdlofbndmkmnfeegjoi`):
   deletes the `ExtensionInstallForcelist` entries and any `force_installed`
   `ExtensionSettings` node (both `HKLM` and `HKCU`), removes the `HKLM`
   external (side-load) registration keys, and deletes the unpacked extension
   from every user/browser profile on disk. Firefox `.xpi` copies are removed
   when `-FirefoxAddonId` is supplied.
2. **Policy block** — adds the ID to `ExtensionInstallBlocklist` and sets
   `ExtensionSettings` `installation_mode = blocked` for every browser. Chromium
   uninstalls an extension the moment it becomes blocked, so this both prevents
   reinstall and guarantees removal. Firefox is blocked via a merged
   `policies.json` when `-FirefoxAddonId` is supplied.
3. **Network block** — sinkholes Keep Aware's console/API domains to `0.0.0.0`
   in the hosts file and adds outbound firewall rules to their resolved IPs. A
   re-pushed extension is inert without its cloud backend, so this neutralizes
   the window before a managed source is cleaned up.

All steps are idempotent — re-running is safe.

### Managed-deployment caveat

If the force-install is delivered by a **domain GPO or Intune/MDM**, the
authoritative copy lives on the management server. This script removes the local
copy and blocks the extension locally, but the next policy refresh can re-push
the force-install and (depending on precedence) override the local block. When a
force-install entry is found in the machine (`HKLM`) policy hive, the script
warns and tells you to also remove it at the source. **Reinstall prevention is
only guaranteed once the source deployment is removed** (GPO setting, Intune
profile / app assignment, RMM policy) and the device is unassigned in the Keep
Aware console.

## Prerequisites

- Windows 10/11 or Windows Server, **run as Administrator** (elevated
  PowerShell). The script declares `#Requires -RunAsAdministrator`.
- PowerShell 5.1+ (the `NetSecurity` firewall cmdlets ship in-box).
- **Authorization to remove this extension.** Keep Aware is a managed security
  control; only run this where you're permitted to (vendor migration,
  decommissioning, offboarding).
- Close/restart browsers for on-disk deletion and policy re-read to fully take
  effect. The policy block applies on the next browser launch.
- For Firefox, supply the add-on ID (`about:debugging` > This Firefox) via
  `-FirefoxAddonId`; the Chromium ID cannot be reused for Firefox.

## Usage

```powershell
# Preview everything first (no changes made):
.\Remove-KeepAware.ps1 -WhatIf

# Full removal + all blocks (default):
.\Remove-KeepAware.ps1

# Just uninstall, leave the machine able to reinstall:
.\Remove-KeepAware.ps1 -Mode Uninstall

# Just apply blocks (e.g. on a machine that never had it):
.\Remove-KeepAware.ps1 -Mode Block

# Choose specific blocks:
.\Remove-KeepAware.ps1 -Mode Block -BlockPolicy

# Include Firefox:
.\Remove-KeepAware.ps1 -FirefoxAddonId 'keep-aware@keepaware.com'

# Roll back every block this script applied (does NOT restore the force-install):
.\Remove-KeepAware.ps1 -Mode Restore

# Verify the result (add -CheckNetwork if you applied the network block):
.\Test-KeepAwareRemoval.ps1 -CheckNetwork
```

Knobs you may want to touch:

- `-ExtensionId` — Chromium extension IDs to purge/block (for a re-published build).
- `-FirefoxAddonId` — Firefox add-on IDs to block via `policies.json`.
- `-Domains` — the Keep Aware domains sinkholed in the hosts file.
- `-LogPath` — defaults to `C:\Windows\Temp\Remove-KeepAware.log`.

If PowerShell blocks the script, unblock it for the session:
`Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass`.

## Verification

| Test | How | Expected |
|------|-----|----------|
| Happy path | `.\Remove-KeepAware.ps1` then `.\Test-KeepAwareRemoval.ps1` | All checks `[PASS]`, exit 0. |
| Not force-installed | `.\Test-KeepAwareRemoval.ps1` | No `ExtensionInstallForcelist` entry references the ID. |
| Reinstall blocked | Relaunch a browser | Extension does not return; ID is in `ExtensionInstallBlocklist`. |
| Files gone | Check `%LOCALAPPDATA%\...\User Data\*\Extensions\<id>` | No such folder. |
| Network block | `Resolve-DnsName app.keepaware.com` | Resolves to `0.0.0.0`. |
| Rollback | `.\Remove-KeepAware.ps1 -Mode Restore` | Blocklist entries, blocked `ExtensionSettings`, hosts entries, and firewall rules removed. |
| Dry run | `.\Remove-KeepAware.ps1 -WhatIf` | Prints intended actions, makes no changes. |

## Notes

- **The blocklist is the load-bearing control**, not the file delete: a
  force-installed extension is re-added from the store on launch, so removing
  files without blocking is pointless. The policy block both prevents reinstall
  and makes Chromium uninstall a present copy.
- **`-Mode Restore` lifts the blocks but does not restore the force-install** —
  that was a managed policy the script deleted on purpose. Re-deploy from your
  MDM/Keep Aware console if you need the extension back.
- **Firefox is opt-in via `-FirefoxAddonId`.** Firefox uses a different add-on
  ID scheme than Chromium; without the ID the script can't safely target it and
  skips Firefox (logging a note) rather than guessing.
- **The same Chrome Web Store ID covers Chrome, Edge, Brave, Vivaldi, Opera and
  Chromium** — that's how Keep Aware force-installs across Chromium browsers.
  The ID is defined at the top of both scripts; extend `-ExtensionId` for a
  custom/re-published build.
- **Network block is best-effort and configurable.** The hosts sinkhole is the
  primary control; the firewall rule targets the domains' currently-resolved
  IPs. The browser policy block is the authoritative reinstall prevention.
