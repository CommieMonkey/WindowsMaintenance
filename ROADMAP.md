# Roadmap

Phases 1 and 2 are built and were run by the owner on a Windows 11 PC. Phase 3 is written but has not been run on any server. The step ids 1-14 are stable: new steps get new ids. Sizes: S / M / L. Marked with a star = suggested first.

## Phase 1: foundation (do this first, it unlocks the rest)

- [~] **Step registry** (M, star) *(partly done: `$StepInfo` has Modes/Risk/Requires and the window builds its cards from it; per-step dropdown options and the engine's step code are still separate)*: replace the hard-coded 8 steps with a table: id, mode (Pc/Server), title, description, risk level, "requires" check (winget present? cleanmgr.exe present? Defender service active? role installed?), dropdown options. The window builds its cards from it; the engine loops over it.
- [x] **Mode detection** (S, star): `Win32_OperatingSystem.ProductType` (1 = workstation, 2 = domain controller, 3 = server). Server Core: registry `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion` -> `InstallationType`. Add `-Mode Auto|Pc|Server`; the window shows only the matching steps.
- [x] **Capability checks, not version checks** (S, star): grey out a step with the reason ("needs Desktop Experience") instead of failing in the log.
- [x] Log the OS build, edition and install type at the top of every run and in the CSV.
- [x] Exit codes for unattended runs: 0 OK, 1 warnings, 2 failures (today a failed step does not change the exit code).

## Phase 2: PC features

Safer / clearer
- [x] Preview before deleting (M, star) *(window button and `-Preview`; covers steps 2, 4 and 10; cleanmgr cannot be previewed)*
- [x] winget update list with checkboxes; pin or skip packages (M, star) *(pinning uses `winget pin`; the list parses winget's text table)*
- [x] Built-in scheduler button (S, star) *(Schedule... dialog; runs a copy in Program Files)*
- [x] Presets: Quick tune-up / Deep clean / Weekly safe; remember last settings (S)
- [x] Before/after HTML report plus a history view (M) *(a History... window instead of a tab)*

Updates
- [x] Windows Update scan/install via the built-in update COM API (M) *(step 9; scan only by default)*
- [x] Store apps through winget; report (not install) driver updates (S) *(`winget upgrade --all` already covers msstore; drivers are reported in step 9)*

Cleanup
- [x] "What is using my space" (M, star) *(step 11)*
- [x] More caches (M) *(step 10, off by default)*
- [x] Startup manager (M) *(Tools window; uses StartupApproved, deletes nothing)*

Health and fixes
- [x] "Why did my PC crash" (M, star) *(step 12)*
- [x] Hardware health (S to M) *(step 13; memory test is a button in Tools)*
- [x] One-click repairs (S each) *(Tools window)*
- [x] Security check-up (M) *(step 14; pending updates are in step 9)*

Polish
- [x] Dutch/English toggle, dark mode, high-DPI scaling, finished-run notification
- [ ] GitHub release check (notify only): **not built**, it needs a network call outside the allowed list (winget, DISM, Defender); the owner has to allow that first

## Phase 3: Server mode (same exe)

Target: Windows Server 2019, 2022, 2025 (Desktop Experience and Server Core), plus the vNext preview if feasible.

### Findings (researched 2026-11-18; not tested on any server)
- Latest release is Windows Server 2025 (GA November 2024). A next-LTSC preview exists but is still branded "Windows Server 2025". Extended support ends: 2019 -> 2029-01-09, 2022 -> 2031-10-14, 2025 -> 2034-11-14.
- **winget**: not on Server 2022 or earlier; Server 2025 includes it for Desktop Experience only (not Server Core).
- **cleanmgr.exe**: present on graphical (Desktop Experience) editions of 2016/2019 per Microsoft docs; assume missing on Server Core (not confirmed by a source).
- **System Restore**: not available on Server 2019 and later, so step 1 cannot work. (Source is third-party websites, not Microsoft docs; treat as likely.) Replacement: check Windows Server Backup / system state backup age and VSS state.
- **Defender**: installed and active by default on 2016+, but goes passive when a third-party antivirus is installed. Detect passive mode and skip the scan.
- PowerShell: assume Windows PowerShell 5.1 on all three (unverified).

### Design
- Read-only first: reports and checks on by default; anything that changes the system is opt-in behind a "this is a maintenance window" confirmation.
- Server Core has no desktop: no window. Fall back to a console menu, plus `-Steps` / `-All`, with exit codes for monitoring.
- No `winget upgrade --all` on servers by default.
- Optional later: run the engine on other servers via PowerShell remoting (`-ComputerName`); the engine is already a self-contained scriptblock.

### Proposed server steps
| Step | Tool | Default |
|---|---|---|
| Health report: uptime, pending reboot, disk space, stopped auto-start services, recent critical errors, last patch date, expiring certificates, time sync, firewall | CIM, event log, `Get-HotFix`, `w32tm` | on |
| Backup check (replaces restore point) | Windows Server Backup cmdlets, `vssadmin` | on |
| Role checks for installed roles only: AD (`dcdiag`, `repadmin`), DNS, DHCP, IIS, Hyper-V, cluster | tools that ship with the role | on, read-only |
| Windows Update scan (list only; respects WSUS; never reboots) | update COM API | on |
| Defender update + scan, skipped when passive | Defender cmdlets | on |
| Disk and storage health | `Get-PhysicalDisk`, `Get-StoragePool` | on |
| Storage optimize: analyze + TRIM; defrag HDD only in a window | `Optimize-Volume` | analyze |
| Cleanup: component store, update download cache, old temp and IIS logs (never event logs) | DISM, file ops | off |
| System repair (DISM + SFC) | DISM, SFC | off |
| HTML report + exit code | | on |

### Phase 3 status (built, untested on servers)
Decisions from the owner: generic servers and domain controllers, test VMs with and without a desktop, Server Core compatibility wanted.

Built:
- [x] Server mode with a maintenance-window gate (`-MaintenanceWindow`, confirmation in the window and the menu): read-only by default, steps 5/7/19 and installing updates need the window.
- [x] Step 15 health report, 16 backup check (Windows Server Backup + VSS), 17 role checks (AD DS incl. dcdiag and replication, DNS, DHCP, IIS, Hyper-V, cluster), 18 storage health, 19 cleanup (component store, update cache, temp, IIS logs; never event logs).
- [x] Step 7 analyze-only on servers; Windows Update scan (step 9) and Defender (skipped when passive) reused.
- [x] Server Core: text menu (`Show-ConsoleMenu`), `-Menu`, `-Schedule`/`-RemoveSchedule` (task as SYSTEM), exe launcher keeps the console visible.
- [x] Exit codes for monitoring now include `WARN` lines (1) as well as failures (2); `ServerCheck` preset; server logs in ProgramData.

Not built:
- [ ] `-ComputerName` / PowerShell remoting to run the engine on other servers.
- [ ] Roles not covered: file server (shares, DFS-N, FSRM), print server, RDS, WSUS, certificate services, SQL.
- [ ] Deeper AD checks: DFSR/SYSVOL migration state, trust health, AD Recycle Bin, replication topology.
- [ ] Hyper-V replication health, cluster `Test-Cluster`, Storage Spaces Direct specifics.
- [ ] Localized-output support for parsed text (`vssadmin`, `w32tm`).

### Open questions for the owner (answered)
- Which roles will the servers run (file server, domain controller, Hyper-V, IIS, other)? That decides which role checks come first.
- Test VMs: 2019, 2022, 2025, each as Desktop and Core (Microsoft evaluation ISOs are enough).
