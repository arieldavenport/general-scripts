# dnsfilter-removal

> Uninstalls the DNSFilter Windows Roaming Client ("DNS Agent") and blocks it
> from reinstalling, with a one-command rollback.

Removal flow:
**stop + delete services → msiexec uninstall → delete leftovers → block (network + filesystem + policy)**

## Files

| File | Purpose |
|------|---------|
| `Remove-DNSFilter.ps1` | Main script. Uninstalls the agent and applies the three reinstall blocks. Supports `-Mode Full/Uninstall/Block/Restore` and `-WhatIf`. |
| `Test-DNSFilterRemoval.ps1` | Read-only verification. Confirms the agent is gone and every block is in place; exits non-zero on any failure. |

## What it does

1. **Uninstall** — stops and deletes the `DNSFilter Agent` / `DNS Agent` /
   `DNS Agent Service Manager` services, reads the uninstall registry for every
   matching product code, runs `msiexec /x {code} REGCLEAN=true /qn`, then
   deletes leftover install/data directories and `HKLM\SOFTWARE\DNSFilter` /
   `DNSAgent` keys.
2. **Network block** — sinkholes DNSFilter download/API/check-in domains to
   `0.0.0.0` in the hosts file and adds outbound Windows Firewall rules blocking
   the agent binaries and DNSFilter's anycast resolver IPs
   (`103.247.36.36`, `103.247.37.37`).
3. **Filesystem block** — recreates each Program Files install directory as an
   empty placeholder whose ACL denies "create files / append data" to Everyone
   **and** SYSTEM, so an installer can't write into it.
4. **Policy block** — adds Image File Execution Options "debugger" redirects for
   the agent executable names so they can't launch from any path.

All four steps are idempotent — re-running is safe.

## Prerequisites

- Windows 10/11 or Windows Server, **run as Administrator** (elevated
  PowerShell). The script declares `#Requires -RunAsAdministrator`.
- PowerShell 5.1+ (the `NetSecurity` firewall cmdlets ship in-box).
- **Authorization to remove this agent.** DNSFilter is often a managed security
  control; only run this where you're permitted to (vendor migration,
  decommissioning, offboarding). Newer agents may also need to be released from
  *Pending Uninstall* in the DNSFilter dashboard for a clean server-side state.

## Usage

```powershell
# Preview everything first (no changes made):
.\Remove-DNSFilter.ps1 -WhatIf

# Full removal + all blocks (default):
.\Remove-DNSFilter.ps1

# Just uninstall, leave the machine able to reinstall:
.\Remove-DNSFilter.ps1 -Mode Uninstall

# Just apply blocks (e.g. on a machine that never had it):
.\Remove-DNSFilter.ps1 -Mode Block

# Choose specific blocks:
.\Remove-DNSFilter.ps1 -Mode Block -BlockNetwork -BlockPolicy

# Roll back every block this script applied (does NOT reinstall):
.\Remove-DNSFilter.ps1 -Mode Restore

# Verify the result:
.\Test-DNSFilterRemoval.ps1
```

Knobs you may want to touch:

- `-Domains` — the domain list sinkholed in the hosts file.
- `-ResolverIPs` — DNSFilter resolver IPs blocked outbound.
- `-LogPath` — defaults to `C:\Windows\Temp\Remove-DNSFilter.log`.

If PowerShell blocks the script, unblock it for the session:
`Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass`.

## Verification

| Test | How | Expected |
|------|-----|----------|
| Happy path | `.\Remove-DNSFilter.ps1` then `.\Test-DNSFilterRemoval.ps1` | All checks `[PASS]`, exit 0. |
| Services gone | `Get-Service '*DNS Agent*'` | No matching service. |
| Reinstall blocked (policy) | Try launching the agent installer/exe | Launch is intercepted by the IFEO stub; agent does not start. |
| Reinstall blocked (fs) | Run the MSI | Install fails to write into the locked directory. |
| Reinstall blocked (net) | `Resolve-DnsName app.dnsfilter.com` / `ping app.dnsfilter.com` | Resolves to `0.0.0.0`. |
| Rollback | `.\Remove-DNSFilter.ps1 -Mode Restore` | Hosts entries, firewall rules, IFEO keys, and ACL locks removed. |
| Dry run | `.\Remove-DNSFilter.ps1 -WhatIf` | Prints intended actions, makes no changes. |

## Notes

- **Reinstall blocks are layered on purpose.** A network block alone won't stop
  a locally-run MSI; the filesystem + IFEO blocks cover that case, and the
  network block stops a still-present agent from updating/phoning home.
- **IFEO uses `systray.exe` as a harmless no-op "debugger"** — a standard,
  reversible way to prevent a named executable from launching. `-Mode Restore`
  deletes those keys.
- **Service/install/registry names cover standard and whitelabel ("DNS Agent")
  builds and the v2.1.0+ service manager.** Names are defined at the top of the
  script — extend the arrays if your tenant uses a custom whitelabel.
- **`REGCLEAN=true`** asks the MSI to clean its own registry footprint; the
  script also removes leftovers directly in case the MSI is already gone.
- Everything is reversible via `-Mode Restore` except the uninstall itself
  (re-deploy from the DNSFilter dashboard if you need the agent back).
