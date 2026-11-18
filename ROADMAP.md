# Roadmap

Phase 1 is written but unexecuted (no PowerShell in the sandbox); phases 2 and 3 are not started. Sizes: S / M / L. Marked with a star = suggested first.

## Phase 1: foundation (do this first, it unlocks the rest)

- [~] **Step registry** (M, star) *(partly done: `$StepInfo` has Modes/Risk/Requires and the window builds its cards from it; per-step dropdown options and the engine's step code are still separate)*: replace the hard-coded 8 steps with a table: id, mode (Pc/Server), title, description, risk level, "requires" check (winget present? cleanmgr.exe present? Defender service active? role installed?), dropdown options. The window builds its cards from it; the engine loops over it.
- [x] **Mode detection** (S, star): `Win32_OperatingSystem.ProductType` (1 = workstation, 2 = domain controller, 3 = server). Server Core: registry `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion` -> `InstallationType`. Add `-Mode Auto|Pc|Server`; the window shows only the matching steps.
- [x] **Capability checks, not version checks** (S, star): grey out a step with the reason ("needs Desktop Experience") instead of failing in the log.
- [x] Log the OS build, edition and install type at the top of every run and in the CSV.
- [x] Exit codes for unattended runs: 0 OK, 1 warnings, 2 failures (today a failed step does not change the exit code).

## Phase 2: PC features

Safer / clearer
- [ ] Preview before deleting: what each cleanup would remove and how much space it frees (M, star)
- [ ] winget update list with checkboxes; pin or skip packages (M, star)
- [ ] Built-in scheduler button: create the scheduled task (weekly, on AC power, run-if-missed) (S, star)
- [ ] Presets: Quick tune-up / Deep clean / Weekly safe; remember last settings (S)
- [ ] Before/after HTML report plus a history tab built from `MaintenanceHistory.csv` (M)

Updates
- [ ] Windows Update scan/install via the built-in update COM API (`Microsoft.Update.Session`), with reboot reporting (M)
- [ ] Store apps through winget; report (not install) driver updates (S)

Cleanup
- [ ] "What is using my space": largest folders, hibernation/page file, `DISM /AnalyzeComponentStore`, old user profiles; report only (M, star)
- [ ] More caches: Windows Update download cache, Delivery Optimization, browser caches (never passwords/logins) (M)
- [ ] Startup manager: run keys, startup folders, scheduled tasks, enable/disable (M)

Health and fixes
- [ ] "Why did my PC crash": summary of BSODs, app crashes, disk errors from the last 30 days (M, star)
- [ ] Hardware health: SSD wear/temperature/error counters, battery report, online disk scan, schedule memory test (S to M)
- [ ] One-click repairs: network reset, Windows Update component reset, search index/icon cache rebuild, print spooler restart (S each)
- [ ] Security check-up (read-only): Defender definitions, firewall, BitLocker, Secure Boot/TPM, pending updates, SMBv1/RDP (M)

Polish
- [ ] Dutch/English toggle, dark mode, proper high-DPI scaling, finished-run notification, GitHub release check (notify only)

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

### Open questions for the owner
- Which roles will the servers run (file server, domain controller, Hyper-V, IIS, other)? That decides which role checks come first.
- Test VMs: 2019, 2022, 2025, each as Desktop and Core (Microsoft evaluation ISOs are enough).
