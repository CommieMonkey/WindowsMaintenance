# Run-Maintenance

Automated Windows PC maintenance in one script, using **only tools that are built into Windows**: winget, Disk Cleanup (cleanmgr), DISM, SFC, Windows Defender, System Restore and the built-in drive optimizer.

Start it and a simple window opens: tick the things you want, press **Start maintenance**, and it works through them, logs what it did, and tells you how much space it freed. No command line needed.

---

## Table of contents

1. [Features](#features)
2. [What is in the package](#what-is-in-the-package)
3. [Requirements](#requirements)
4. [Quick start](#quick-start)
5. [The window](#the-window)
6. [What each step does](#what-each-step-does)
7. [Windows Server (Server mode)](#windows-server-server-mode)
8. [Command-line parameters](#command-line-parameters)
9. [Safety design](#safety-design)
10. [Power protection (laptops)](#power-protection-laptops)
11. [Logging](#logging)
12. [Running it automatically (scheduled task)](#running-it-automatically-scheduled-task)
13. [The EXE version](#the-exe-version)
14. [Troubleshooting](#troubleshooting)
15. [FAQ](#faq)
16. [Known limitations](#known-limitations)
17. [Disclaimer](#disclaimer)

---

## Features

- **A real window, made for beginners.** Plain-language checkboxes for every step, one big Start button, live progress and a clear "All done" summary.
- **Advanced view on demand.** Tick one box to get a dropdown with settings for each step (how many restore points to keep, scan type, which drives, and more).
- **Only built-in tools.** Nothing to install except what Windows already ships (winget comes with Windows 10/11's "App Installer").
- **Safe by design.** Deliberately conservative deletion rules for temp files, protected cleanmgr categories, junction/symlink protection and a restore point before anything happens.
- **Restore point rotation.** Creates a fresh restore point each run and keeps the last 2 of its own, so restore points never pile up.
- **Laptop-friendly.** Refuses to run on battery; waits for you to plug in the charger.
- **Real logging.** A full transcript per run plus a CSV history with one row per step per run (status, duration, error message).
- **Resilient.** A failing step is logged and the script carries on with the next one. Hung steps have timeouts.
- **Self-elevating.** Asks for administrator rights (UAC prompt) when needed.
- **Unattended mode.** `-All` / `-Steps` / `-Preset` skip the window, so it works in a scheduled task.
- **Presets, preview and memory.** Quick tune-up / Deep clean / Weekly safe buttons, a preview of what cleanup would remove, and the window remembers your ticks and dropdown choices.
- **Reports and checks.** Windows Update scan, disk space report, crash summary, hardware health, security check-up, and an HTML report after every run.
- **Tools.** Startup programs, one-click repairs (network, Windows Update, search index, icon cache, print spooler, memory test) and a built-in weekly schedule.
- **Windows Server mode.** Member servers and domain controllers, with or without a desktop: read-only health, backup, role (AD DS, DNS, DHCP, IIS, Hyper-V, cluster) and storage checks by default, changes only in a confirmed maintenance window, a text menu on Server Core, and exit codes for monitoring. See [Windows Server](#windows-server-server-mode).
- **English and Dutch, light and dark.** One click to switch; the language follows Windows on first start.

---

## What is in the package

| File | Purpose |
|---|---|
| `Run-Maintenance.ps1` | The script. This is the actual program. |
| `Run-Maintenance.cmd` | Double-click launcher. Runs the script with the execution policy bypassed **for that one run only**, so you don't have to type a long command. |
| `Run-Maintenance.exe` | The same tool as one single file: double-click, accept the admin prompt, done. You create it yourself with `Build-Exe.cmd` (see [The EXE version](#the-exe-version)). |
| `Build-Exe.cmd` | Double-click to build `Run-Maintenance.exe`. Uses the compiler that is built into Windows. |
| `Launcher.cs`, `app.manifest` | Source of the small launcher program inside the exe, and its "ask for administrator" manifest. Needed by `Build-Exe.cmd`. |
| `README.md` | This file. |

Keep `Run-Maintenance.cmd` in the **same folder** as the `.ps1`. (The finished `.exe` needs no other files.)

---

## Requirements

- Windows 10 or Windows 11, or **Windows Server 2019 / 2022 / 2025** (with or without a desktop, member server or domain controller, see [Windows Server](#windows-server-server-mode))
- **Windows PowerShell 5.1** (the default `powershell.exe` that ships with Windows)
- **Administrator rights** (the script asks for them itself)
- **winget** for step 2 (installed with "App Installer" from the Microsoft Store; already present on current Windows 10/11)
- An internet connection for winget, DISM `/RestoreHealth` and Defender signature updates

System Protection (System Restore) is turned on for the system drive if it was off, because step 1 needs it.

---

## Quick start

### Option A: double-click the launcher (easiest)

1. Put `Run-Maintenance.cmd` and `Run-Maintenance.ps1` in the same folder.
2. Double-click **`Run-Maintenance.cmd`**.
3. Accept the Windows admin prompt (UAC).
4. Tick the steps you want (everything except step 10, which deletes browser and update caches, is ticked by default) and press **Start maintenance**.

### Option B: from a terminal

```powershell
powershell -ExecutionPolicy Bypass -File .\Run-Maintenance.ps1
```

### Option C: the EXE

Double-click `Run-Maintenance.exe` and accept the admin prompt. See [The EXE version](#the-exe-version).

### Why can't I just double-click the .ps1?

Windows blocks PowerShell scripts by default (the *execution policy*), and double-clicking a `.ps1` only opens it in an editor. The `.cmd` launcher exists to get around that safely. If you would rather allow scripts for your user account permanently:

```powershell
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
```

Files downloaded from the internet may additionally need `Unblock-File .\Run-Maintenance.ps1` once. The launcher needs neither.

---

## The window

Start the tool without parameters and this window opens (the black console window hides itself while it is open).

**Choosing what to do**

- Every step has a checkbox, a plain-language title, a short explanation and an estimate of how long it takes. Everything is ticked by default except step 10 (extra caches), which deletes and is opt-in.
- Quick buttons at the top: **Select everything**, **Select nothing**, **Everything except the slow repair** and three presets: **Quick tune-up** (steps 4, 7, 8), **Deep clean** (1, 2, 3, 4, 5, 7, 8, 10) and **Weekly safe** (2, 6, 7, 8, 9, 14, nothing is deleted).
- Step 2 has a **Choose which programs to update...** button: a list of programs with an update, with checkboxes. The option *Never update the programs I did not tick* uses `winget pin`, which `winget upgrade --all` respects. **Remove all pins** undoes it.
- **Preview cleanup** runs steps 2, 4 and 10 in read-only mode: it lists the programs that would be updated, how many temp files and how many MB would be deleted, and how big the Recycle Bin is. Nothing is changed (disk cleanup, step 3, cannot be previewed).
- **Tools...** opens the repairs and the startup manager, **Schedule...** creates the weekly task, **History...** shows `MaintenanceHistory.csv` as a table, and **Nederlands / English** and **Dark mode / Light mode** switch language and theme (the window rebuilds itself).
- The window **remembers** the language, theme, ticked steps and advanced dropdown choices in `%APPDATA%\PCMaintenance\settings.json`.
- At the bottom a line shows your **power status**. On a laptop that is running on battery it turns red, and the Start button will refuse to start until you plug in the charger.
- Press **Start maintenance**. A short confirmation reminds you to save your work (and tells you if the Recycle Bin is going to be emptied for good).

**While it runs**

- A list shows every selected step as *Waiting*, *Running...*, *Done*, *Failed* or *Skipped*, with a progress bar for the whole run and a line saying what it is doing right now.
- **Show technical details** reveals the full text output (the same text that is saved in the log file).
- **Stop after this step** finishes the step that is running and skips the rest. It never kills a step halfway, because stopping a repair or an update in the middle is riskier than waiting.
- The window cannot be closed by accident while maintenance is running.
- **Open log folder** opens `%USERPROFILE%\MaintenanceLogs`.

**When it is finished**

You see "All done!" (or a warning if some steps failed), how much space was freed, how long it took and whether Windows would like a restart. **Open report** shows the HTML report (free space before and after, every step with its log). If the window is not in front, a Windows notification tells you it finished. **Back to options** returns to the first screen.

### Advanced options

Tick **Show advanced options** (bottom left) and a dropdown row appears under every step. The dropdowns only count while that box is ticked; untick it and the safe defaults are used. Default choices are marked "(recommended)" in the window and in **bold** here.

| Step | Dropdown | Choices |
|---|---|---|
| 1 Restore point | Restore points to keep | 1, **2**, 3, 4, 5 |
| 2 Update programs | Installer windows | **Show them if an installer needs one**, Never show them (silent) |
| 3 Free up disk space | Cleanup strength | **Standard**, Gentle (also keeps old driver packages and crash dumps, and the Recycle Bin) |
| 4 Temp files | Delete temp files older than | 1 day, **3 days**, 7 days, 30 days |
| 4 Temp files | Recycle Bin (also applies to step 3) | **Empty it**, Leave it alone |
| 5 System repair | What to run | **DISM + SFC**, SFC only (faster), DISM only |
| 6 Defender | Scan type | **Quick scan**, Update definitions only, Full scan (can take hours) |
| 7 Optimize drives | Which drives | **All drives**, or one specific drive letter |
| 8 Disk health | none | |
| 9 Windows Update | What to do with updates | **Only look for updates**, Download and install them (no automatic restart) |
| 10 Extra caches | Windows Update download cache / Delivery Optimization cache / Browser caches | **Yes**, No (each) |
| 11, 12, 14 | none | |
| 13 Hardware health | Online disk scan | **Skip it**, Run a read-only scan of each drive (slow) |

Two more settings apply to the whole run:

| Setting | Choices |
|---|---|
| Charger check | **Laptop must be plugged in**, Skip the charger check |
| When finished | **Do nothing**, Restart my PC (you get a 60 second warning and can cancel it) |

---

## What each step does

### 1. Restore point

Creates a System Restore point named `Before maintenance <date time>`, then removes older restore points **that this script created** so that only the number you chose remain (2 by default: the new one plus the newest previous one).

- Restore points created by Windows, by installers or by you are never touched.
- Old restore points are only deleted **after** the new one was created successfully.
- Windows normally allows only one restore point per 24 hours. The script lifts that limit temporarily so repeated runs work, then restores the original setting.
- A restore point protects system files, drivers, installed programs and the registry. It does **not** back up your personal documents.

### 2. Update software (winget)

Runs `winget upgrade --all` with agreements accepted.

- `--include-unknown` is deliberately **not** used, so packages whose installed version winget cannot read are left alone.
- By default installers may show their own windows (some installers cannot run silently and would hang otherwise). Check your taskbar if it seems stuck.
- In the window, the advanced option *Installer windows: Never show them* forces `--silent`; unattended runs use the `-SilentWinget` switch (recommended for unattended runs only).
- To keep a package at a specific version, use `winget pin add <id>`.

### 3. Disk cleanup (cleanmgr)

Builds a temporary Disk Cleanup profile, runs `cleanmgr /sagerun`, and removes the profile again afterwards.

- **Enabled:** every cleanup category Windows offers **except** the protected ones below.
- **Never cleaned (kept on purpose):**
  - your **Downloads** folder
  - **Previous Windows installations** (needed to roll back a major Windows update)
  - the **Windows ESD installation files** (needed by "Reset this PC")
- The script prints the list of kept categories before it starts so you can verify it.
- The Disk Cleanup windows are minimized automatically, and the script prints a progress line every minute.
- Safety timeout: if cleanmgr is still running after **30 minutes** it is stopped and the step is logged as failed.

> **Heads-up:** because everything except the protected categories is enabled, this also empties the **Recycle Bin** and removes things like old driver packages, system error memory dumps and superseded Windows Update files. Windows Update cleanup means those updates can no longer be uninstalled. If you do not want some of those, tell the script's maintainer or edit the `$exclude` list in step 3.

### 4. Temp files, recycle bin, DNS cache

- **Temp files:** cleans your `%TEMP%` folder and `C:\Windows\Temp` (files older than 3 days by default; adjustable in the advanced options). See [Safety design](#safety-design) for the strict rules.
- **Recycle Bin:** emptied for all drives. **This is permanent.** You can switch this off in the advanced options (*Leave it alone*), which also protects the Recycle Bin from step 3.
- **DNS cache:** flushed with `ipconfig /flushdns`.

The step prints how many files it found, how many MB they take, a counter while deleting, and how many files were in use and therefore left alone.

### 5. System repair (DISM + SFC)

- `DISM /Online /Cleanup-Image /StartComponentCleanup`
- `DISM /Online /Cleanup-Image /RestoreHealth` (downloads repair files from Windows Update if needed)
- `sfc /scannow`

This is the slowest step (often 10 to 20 minutes). SFC can sit on the same percentage for a minute or two. That is normal. `/ResetBase` is **not** used.

### 6. Defender update + quick scan

Updates Defender signatures and runs a quick scan. If a third-party antivirus is active, this step fails with a warning and the script continues. If Defender finds a threat it handles it according to your Defender settings.

### 7. Optimize drives

Runs `Optimize-Volume` on every fixed NTFS/ReFS volume. Windows chooses the right method itself: **TRIM** for SSDs, **defrag** for hard disks. Defragmenting a large hard disk can take a long time.

### 8. Disk health report

Shows the health status of every physical disk (flagging anything not "Healthy"), plus size and free space per volume.

### 9. Windows Update

Looks for software updates with the Windows Update service through its built-in COM interface (it follows your WSUS server if you have one) and lists them. **Driver updates are only reported, never installed.** By default nothing is installed; with the advanced option *Download and install them* it downloads and installs the updates that do not need your input. It **never restarts** the PC; a pending restart is reported at the end.

### 10. Extra caches (off by default)

Clears the Windows Update download folder (`SoftwareDistribution\Download`, with the update services stopped and started again), the Delivery Optimization cache and the `Cache`, `Code Cache` and `GPUCache` folders of Chrome and Edge and `cache2` of Firefox. Cookies, saved passwords, bookmarks and logins are never touched. Junctions are skipped like in step 4. Because it deletes, this step is not ticked by default, is not part of `-All`, and has to be asked for (`-Steps 10`, the *Deep clean* preset or its checkbox).

### 11. Disk space report

Report only. Shows free space, the size of `hiberfil.sys`, `pagefile.sys`, `swapfile.sys` and `Windows.old`, the output of `DISM /AnalyzeComponentStore`, the 12 biggest folders in the system drive, your profile and `AppData\Local`, and user profiles unused for 90+ days. It measures folders by hand, so it can take several minutes.

### 12. Crash and error summary

Report only. Counts and lists, for the last 30 days: blue screens (bugchecks), unexpected shutdowns (Kernel-Power 41), application crashes and hangs grouped by program, disk and file system errors, and WHEA hardware error reports.

### 13. Hardware health

Report only. Per drive: temperature, SSD wear, power-on hours and read/write error counters; the battery's full-charge capacity compared to when it was new; optionally a read-only online disk scan (`Repair-Volume -Scan`). It warns about heavily worn SSDs, hot drives, drive errors and batteries under 60%.

### 14. Security check-up

Report only. Checks Defender (real-time protection, definition age, passive mode), the firewall profiles, BitLocker on the system drive, Secure Boot, the TPM, SMBv1, Remote Desktop with Network Level Authentication and UAC. Every line starts with `OK`, `WARN` or `INFO`. Warnings do not make the step fail.

### 15. Server health report (Server mode)

Report only. Uptime and last start, whether a restart is pending (component servicing, Windows Update, pending file renames), free space per drive (warns under 15%, *critical* under 10%), **automatic services that are not running** (delayed-start services and a list of services that are normally stopped are ignored), critical and error events from the last 7 days per log, the date of the last installed update (warns after 60 days), personal certificates that expire within 30 days or have expired, and the **time source** (warns when it is the local clock). The firewall is covered by step 14.

### 16. Backup check (Server mode)

Report only. With Windows Server Backup installed: the last successful backup (warns when it is older than 7 days, when there is none or when the last attempt did not finish cleanly), versions kept and the next planned backup. If you use other backup software (Veeam, Acronis, Commvault and similar) the tool only mentions that it seems to be running. Also checks that every **VSS writer is stable** (`vssadmin list writers`) and lists the shadow storage.

### 17. Server roles check (Server mode)

Report only. Finds the installed roles (with `Get-WindowsFeature`, or by their service) and checks each one:

- **Active Directory Domain Services** (domain controllers): the services NTDS, Netlogon, KDC, W32Time, ADWS and DFSR, the SYSVOL and NETLOGON shares, `dcdiag /q` (any output is a warning; it can take a few minutes), replication failures (`Get-ADReplicationFailure`, or `repadmin /replsummary` when the AD module is missing), the operations master roles (`netdom query fsmo`) and errors in the *Directory Service* and *DFS Replication* logs.
- **DNS**: service, zones, forwarders, paused zones, whether the server resolves its own domain, errors in the *DNS Server* log.
- **DHCP**: service, scopes (warns at 90% of the addresses in use) and whether the server is authorized in Active Directory.
- **IIS**: service, sites, application pools that are not started, size of the log folder.
- **Hyper-V**: virtual machines and their health, checkpoints older than 7 days.
- **Failover clustering**: nodes, groups that are not online, failed resources, quorum type.

### 18. Storage health (Server mode)

Report only. Storage Spaces pools, virtual disks, physical disks and volumes with their health and operational status, and running storage jobs (a repair or rebuild).

### 19. Server cleanup (Server mode, off by default, needs a maintenance window)

Component store cleanup (`DISM /StartComponentCleanup`), the Windows Update download cache, old temp files and old IIS logs, as described under [Windows Server](#windows-server-server-mode). The advanced options switch each part on or off and set the IIS log age (leave alone, 30, 90, 180 or 365 days). The preview shows what it would do (it runs `DISM /AnalyzeComponentStore` and counts the files).

### Tools (in the window, not part of a run)

- **Startup programs:** lists the Run registry keys, the Startup folders and the logon/boot scheduled tasks that are not Microsoft's. Unticking switches an item off with the same `StartupApproved` flag that Task Manager uses (or disables the scheduled task). Nothing is deleted and you can switch it back on.
- **Reset the network:** `netsh winsock reset`, `netsh int ip reset` and a DNS flush. Restart afterwards.
- **Reset Windows Update:** stops the update services, renames `SoftwareDistribution` and `catroot2` to `.bak-<date>` and starts the services again.
- **Rebuild the search index:** stops the Search service, removes `Windows.edb` and starts it again so it is rebuilt.
- **Rebuild the icon cache:** removes the icon cache files; the desktop restarts briefly.
- **Restart the print spooler:** restarts it and removes stuck print jobs (documents in the queue are lost).
- **Test the memory:** opens `mdsched.exe`, which asks whether to restart now or at the next start.

Each repair asks for confirmation first.

### At the end

A summary table of every step (status, duration, message), total time, space freed, the log locations, the path of the HTML report, and a warning if a reboot is pending.

---

## Windows Server (Server mode)

On Windows Server the tool switches to **Server mode** by itself (`-Mode Auto` looks at the product type; `-Mode Server` or `-Mode Pc` forces it). It works on member servers and on **domain controllers** (the window and the header show *Server (domain controller)*), with or without a desktop.

**What changes**

- Only the steps that make sense on a server are offered: 5 (repair), 6 (Defender), 7 (drives), 8, 9 (Windows Update), 11, 12, 13, 14 and the server steps **15 to 19**. Steps 1 to 4 and 10 are PC only (restore points, winget, Disk Cleanup, browser caches).
- **Read-only first.** On a server only the steps that change nothing are ticked or run by default (8, 9, 11 to 18). Steps that change the system, **5 (repair), 7 (optimize), 19 (cleanup) and installing Windows updates**, are skipped unless you say it is a **maintenance window**: in the window you get a confirmation question, on the command line you add `-MaintenanceWindow`. Without it the run still works and the skipped steps show up as *Skipped* (exit code 1). Step 7 on a server only *analyzes* the drives by default, which changes nothing and needs no maintenance window.
- **Preset `ServerCheck`** (steps 8, 9, 12, 13, 14, 15, 16, 17, 18) is the all-read-only server check. The window has a *Server check* button for it.
- Logs and reports are saved in `C:\ProgramData\PCMaintenance\Logs` (not in a user profile), because the scheduled task runs as SYSTEM.
- `winget upgrade --all` is never offered on a server.

**Server Core (no desktop)**

Without a desktop there is no window. Start the tool (the .ps1, the .cmd or the exe) from a console and a **text menu** opens: run the server check, choose steps, preview, schedule or remove the weekly run. Everything the menu does is also available with parameters: `-Preset ServerCheck`, `-Steps "8,15-18"`, `-Schedule`, `-RemoveSchedule`, and the exit codes work for monitoring. `-Menu` opens the same menu on a server that does have a desktop (for example over a remote PowerShell session).

```powershell
.\Run-Maintenance.ps1 -Preset ServerCheck                              # read-only check, no window, exit code for monitoring
.\Run-Maintenance.ps1 -Preset ServerCheck -Schedule -ScheduleDay Sunday -ScheduleTime 03:00
.\Run-Maintenance.ps1 -Steps "5,7,19" -MaintenanceWindow               # a repair and cleanup in a planned window
.\Run-Maintenance.ps1 -Menu                                            # text menu
```

**Exit codes for monitoring:** `0` all fine, `1` warnings (a check printed a `WARN` line, a step was skipped, or a run was stopped), `2` failures. The `WARN` lines are also counted in the report.

**Safety on servers**

- Nothing is installed, repaired or deleted unless it is in a maintenance window, and the cleanup step is off by default.
- The cleanup (step 19) removes component store leftovers (`/StartComponentCleanup`, never `/ResetBase`), the Windows Update download cache, old temp files and **old IIS logs** (`*.log` files in the `W3SVC`/`FTPSVC` site folders and `HTTPERR`, default older than 90 days, can be turned off). **Event logs are never touched.** Junctions are never followed.
- Installing Windows updates is only possible with the advanced option *Download and install them* and a maintenance window. Nothing ever restarts the server by itself.
- Defender is skipped when it is passive (another antivirus is active). Step 7 does not defragment unless you choose *Optimize* in a maintenance window.

**Status:** written from the Windows Server documentation and **not tested on any server yet**. Test on a VM first, with and without a desktop, and on a domain controller before you rely on it.

---

## Command-line parameters

| Parameter | Description |
|---|---|
| `-All` | Run every default step without opening the window. Use this for scheduled tasks. Step 10 (extra caches) is not included: it deletes, so you have to ask for it with `-Steps` or `-Preset DeepClean`. |
| `-Steps "1,3,5-6"` | Run only these steps, without the window. Accepts lists and ranges. |
| `-SilentWinget` | Run winget with `--silent` (no installer windows). |
| `-IgnorePower` | Skip the charger check (see below). |
| `-SkipRestorePoint` | Don't run step 1. Existing restore points are left untouched. |
| `-SkipSFC` | Don't run step 5. |
| `-SkipDefender` | Don't run step 6. |
| `-Reboot` | Reboot automatically 30 seconds after finishing. Uses a forced restart, so save your work first. |
| `-Preset QuickTuneUp\|DeepClean\|WeeklySafe\|ServerCheck` | Run a ready-made selection without the window (same as the window's preset buttons; `ServerCheck` is for servers). Ignored when `-Steps` is given. |
| `-MaintenanceWindow` | Server mode: confirms this is a planned maintenance window, so steps that change the server (5, 7 in optimize mode, 19, installing updates) may run. Without it they are skipped. |
| `-Menu` | Open the text menu instead of the window (automatic on Server Core). |
| `-Schedule` | Create the weekly scheduled task and exit. Use with `-Preset`, `-ScheduleDay` (default `Sunday`), `-ScheduleTime` (`HH:mm`, default `03:00`) and optionally `-MaintenanceWindow`. |
| `-RemoveSchedule` | Remove the weekly scheduled task and exit. |
| `-Preview` | Show what steps 2, 4, 10 and 19 would do, without installing or deleting anything. |
| `-Mode Auto\|Pc\|Server` | Which steps to offer. `Auto` (default) picks `Server` on Windows Server and `Pc` otherwise. Steps that do not belong to the mode are hidden in the window and ignored on the command line. |

The `-Skip...` switches also suppress the window (they run "everything except these").

Starting the tool **without** any of these parameters opens the window. The parameters are meant for unattended use; in the window you simply tick boxes instead (the options in the table that only make sense unattended, such as `-SilentWinget`, have an equivalent in the advanced options).

Examples:

```powershell
.\Run-Maintenance.ps1                       # open the window
.\Run-Maintenance.ps1 -All                  # everything, no window
.\Run-Maintenance.ps1 -Steps "1,3,5-6"      # only steps 1, 3, 5 and 6
.\Run-Maintenance.ps1 -All -SkipSFC         # everything except the slow repair
.\Run-Maintenance.ps1 -All -SilentWinget -Reboot
```

The same parameters work with `Run-Maintenance.exe` and `Run-Maintenance.cmd`.

Through the launcher:

```
Run-Maintenance.cmd -All
Run-Maintenance.cmd -Steps "2,3"
```

Exit code of an unattended run: `0` everything fine, `1` warnings (stopped by the user, a step skipped because this PC cannot run it or because it needs `-MaintenanceWindow`, or a check printed a `WARN` line), `2` a step failed, the charger never connected, or the run could not start (invalid `-Steps`).

A step that this PC cannot run (missing tool, Defender in passive mode) is skipped with the reason in the log; in the window its checkbox is greyed out with the reason shown. On Windows Server Core there is no desktop, so a text menu opens instead of the window (or use `-Preset`, `-All` or `-Steps`).

---

## Safety design

This script deletes files and changes system state, so it is built defensively. These are the rules it follows:

### Temp file cleanup

- Only folders that really look like temp folders are cleaned: the folder must be named `Temp` or `Tmp`, must exist, and must not be a junction. A redirected or unusual `%TEMP%` is skipped with a warning.
- A file is only deleted when **both** its creation date and its modification date are older than **3 days**. (Files you extract or copy keep an old modified date; the creation date protects them.)
- **Junctions and symlinks are never followed** and never deleted through, so the cleanup cannot escape into other folders.
- Files in use are skipped, not forced.
- Folders are only removed if they are old **and** empty, using a delete that cannot remove contents.

### Disk Cleanup

- Protected categories (Downloads, previous Windows installations, ESD files) are matched by wildcard so that small naming differences between Windows versions don't matter.
- The temporary cleanup profile is removed from the registry afterwards, even if the step fails.
- A leftover `cleanmgr` from an earlier hung run is stopped before a new one starts.

### Restore points

- Only restore points named `Before maintenance ...` are ever deleted.
- The new restore point is created **before** old ones are removed.

### winget

- No `--include-unknown`.
- Each installer runs with the permissions winget gives it (administrator). Review what `winget upgrade` lists if you want to see what will change before running.

### What the script does not do

- No formatting, no partitioning, no `diskpart`, no `/ResetBase`.
- No permanent changes to your execution policy or other system settings.
- No network activity other than winget, DISM and Defender updates.

---

## Power protection (laptops)

Interrupted power during DISM, SFC, an installer or a defrag is the most realistic way to damage a Windows installation, so the script insists on a charger:

- **In the window:** the power status is shown at the bottom, and the Start button refuses to start on battery.
- **At the start of the run:** if a laptop is on battery, the script waits up to **10 minutes** for you to plug in the charger. If it is still unplugged, it aborts **before changing anything**.
- **Before every step:** power is checked again. If you unplug in the middle of a run, the next step waits for the charger. After 10 minutes the remaining steps are skipped and logged.
- **Desktops** (no battery) always pass.
- **Limit:** unplugging *during* a step cannot be detected. The check happens between steps.
- **Override:** `-IgnorePower` skips the check, for example if a laptop with a faulty battery sensor wrongly reports "on battery".

---

## Logging

Everything is written to:

```
%USERPROFILE%\MaintenanceLogs
```

(When you elevate with a *different* administrator account, this is that account's profile folder. **On a server** it is `C:\ProgramData\PCMaintenance\Logs`.)

| File | Content |
|---|---|
| `Maintenance_<yyyy-MM-dd_HH-mm>.log` | Everything that happened during that run (the same text as "Show technical details" in the window). |
| `MaintenanceHistory.csv` | One row per step per run. Grows over time; open it in Excel. |

`MaintenanceHistory.csv` columns:

| Column | Meaning |
|---|---|
| `RunId` | Start time of the run (groups the steps of one run) |
| `Step` | Step name |
| `Status` | `OK`, `Failed` or `Skipped` |
| `Duration` | `hh:mm:ss` |
| `Message` | Error text for failed steps, or `Not selected` / reason for skipped steps |
| `Os` | Windows name, build, edition and install type (Client / Server / Server Core) |

The first lines of every transcript also show this system line. Every full run also writes `Report_<date>.html` next to the logs (free space before and after, a table of the steps and the log of each step); reports are cleaned up after 90 days like the transcripts. Preview runs write neither a CSV row nor a report.

A history file from an older version (without `Os`) is renamed to `MaintenanceHistory_before-os-column.csv` the first time the new version runs.

Transcripts older than **90 days** are deleted automatically. The CSV is never trimmed.

---

## Running it automatically (scheduled task)

**Easiest way:** in the window press **Schedule...** (on Server Core use the text menu or `-Schedule`), choose the day, the time and a preset (*Weekly safe* is recommended) and press *Create or update*. It copies the script to `C:\Program Files\PCMaintenance\Run-Maintenance.ps1` (administrators only, so nobody can swap the script), creates the task *PC Maintenance (weekly)* with the highest privileges and **run as soon as possible if the PC was off**. On a PC it runs for your account, **only on the charger**; on a server it runs as **SYSTEM**, also when nobody is logged on, and the dialog has a checkbox for allowing changes (a standing maintenance window; off by default, so a scheduled *Server check* is read-only). Press the button again after updating the tool to refresh the copy. **Remove schedule** deletes the task (the copy stays).

By hand: always use `-All` (or `-Steps` / `-Preset`) so the script runs without opening the window. Add `-SilentWinget` because a scheduled task has no desktop to show installer windows on.

```powershell
$action  = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument '-NoProfile -ExecutionPolicy Bypass -File "C:\Program Files\Maintenance\Run-Maintenance.ps1" -All -SilentWinget'
$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At 3am
Register-ScheduledTask -TaskName "Weekly PC Maintenance" -Action $action -Trigger $trigger -RunLevel Highest
```

**Important security note:** because the task runs with the highest privileges, store the script in a folder that only administrators can write to (such as `C:\Program Files\Maintenance\`). If it sits in a folder your normal user can edit, any program running as you could change the script and gain administrator rights.

Notes for scheduled runs:

- On a laptop that is on battery, the run waits 10 minutes and then aborts. The abort is logged.
- Packages that cannot update silently may fail; update those manually once in a while.
- Avoid `-Reboot` for unattended runs. It force-closes applications.
- With a weekly task, "keep 2 restore points" means you can go back roughly one to two weeks. Add `-SkipRestorePoint` if you prefer not to create restore points on a schedule.

---

## The EXE version

`Run-Maintenance.exe` is the same tool as a single file, for people who prefer double-clicking one thing. It opens the same window.

### Building it (once, and again after every change to the script)

You need nothing except Windows itself. The build uses `csc.exe`, the C# compiler that is part of the .NET Framework that ships with Windows 10 and 11.

1. Put these four files in one folder: `Run-Maintenance.ps1`, `Launcher.cs`, `app.manifest`, `Build-Exe.cmd`.
2. Double-click **`Build-Exe.cmd`**.
3. A few seconds later `Run-Maintenance.exe` appears in the same folder. You can copy that one file anywhere.

Optional: put an icon file named `app.ico` in the folder before building to give the exe an icon.

### How it works

The exe is a small launcher with the PowerShell script **embedded inside it**:

1. Windows asks for administrator rights when you start it (UAC prompt), because the exe's manifest requires it.
2. The launcher unpacks the script into a temporary folder under `C:\Program Files\PCMaintenance\`, which only administrators can write to. This matters: a temporary folder in your normal user profile could be tampered with by other programs while the script runs with administrator rights.
3. It runs the script with Windows PowerShell and waits for it to finish.
4. It deletes the unpacked script again (and cleans up leftovers of any run that was killed).

Started **without arguments** you only see the maintenance window. Started **with arguments** it runs unattended and prints its output in the terminal it was started from:

```
Run-Maintenance.exe -All
Run-Maintenance.exe -Steps "1,3,5-6" -SilentWinget
```

The exit code of the script is passed through. For a scheduled task, point the task at the exe with `-All -SilentWinget` and tick "Run with highest privileges".

### Things to know

- **SmartScreen.** The exe is not digitally signed, so the first time Windows may show "Windows protected your PC". Click **More info**, then **Run anyway**. Signing it requires a code-signing certificate, which costs money.
- **Antivirus.** Some antivirus programs distrust small unsigned programs that unpack a script and start PowerShell with `-ExecutionPolicy Bypass`, because malware does the same. This is a false positive, but you may have to allow the file. You build the exe yourself from files you can read, so you can verify exactly what is inside.
- **Managed PCs.** On a PC where an administrator has set a PowerShell execution policy through Group Policy, the `-ExecutionPolicy Bypass` option is overruled and the script will not start.
- **Updating.** The script is baked into the exe. After you change `Run-Maintenance.ps1`, run `Build-Exe.cmd` again.
- **Alternative.** `Run-Maintenance.cmd` runs the plain `.ps1` and needs no building.

---

## Troubleshooting

**The window does not open, or an error box appears**
The error box tells you what failed. Run it once from a command prompt with `Run-Maintenance.cmd` and send the message to the maintainer. As a fallback you can always run the unattended mode, for example `Run-Maintenance.cmd -All`.

**The window says "Maintenance is still running" and will not close**
This is on purpose: closing it mid-run could leave an update or repair half finished. Press **Stop after this step** and wait for the current step to end.

**Nothing seems to happen for a long time on one step**
The little moving bar under the progress bar means it is still working. Tick **Show technical details** to watch the output. Some tools (SFC in particular) only print their result at the end.

**"Running scripts is disabled on this system" / double-clicking opens Notepad**
Use `Run-Maintenance.cmd`, or run `powershell -ExecutionPolicy Bypass -File .\Run-Maintenance.ps1`. See [Quick start](#quick-start).

**The unattended mode (console window) seems to freeze**
In the classic console window, clicking inside the window enters "Select" mode and pauses all output until you press Enter. The script turns this off for its own console, but if the title ever starts with "Select", press **Enter** or **Esc**. This does not affect the normal window.

**Step 2 (winget) hangs**
An installer is probably showing a window that is hidden behind other windows or waiting for a click. Check the taskbar. For unattended runs use `-SilentWinget`. Packages that cannot update silently may need to be updated by hand. Per-user apps (such as some chat or music apps) sometimes dislike being updated from an elevated session; update those normally from the app itself.

**Step 3 (cleanmgr) seems stuck**
The Disk Cleanup windows are minimized on purpose; look on the taskbar. The first cleanup after a long time, particularly "Windows Update Cleanup", can take 10 to 20 minutes. The script prints "still cleaning..." every minute and stops cleanmgr after 30 minutes.

**Step 4 takes a long time**
Large temp folders contain thousands of small files. Watch the counter (it prints every 2,000 files). Task Manager showing disk activity means it is working.

**Step 5 looks stuck at a percentage**
SFC pauses at the same percentage for a minute or two. Wait. Only worry after 10 minutes without any disk activity.

**"Laptop is running on battery"**
Plug in the charger. If you are plugged in and it still complains, use `-IgnorePower`.

**Step 6 fails**
A third-party antivirus is probably managing Defender. This is harmless; the script continues.

**Step 1: restore point could not be created**
System Protection may be disabled by policy, or there is not enough disk space. Check System Properties, System Protection.

**Where are the logs?**
`%USERPROFILE%\MaintenanceLogs`. See [Logging](#logging).

---

## FAQ

**Is it safe to run regularly?**
That is what it is designed for. A weekly or monthly run is typical. Windows 10/11 already trims SSDs on its own schedule, so running step 7 monthly is plenty.

**Will it delete my Downloads or Documents?**
No. Downloads is explicitly protected, and the script never touches Documents, Desktop, Pictures and so on. It *does* empty the Recycle Bin, so restore anything you still need from there first.

**Can I undo what it did?**
Software updates and cleanups cannot be rolled back, but system-level problems can be reverted with the restore point from step 1 (System Properties, System Protection, System Restore). Your own files are not covered by restore points. Keep normal backups.

**Does it update Windows itself?**
No. It uses winget for applications and Defender for its own signatures. Use Windows Update for Windows updates.

**Why not use `dfrgui`?**
`dfrgui` is a graphical tool that cannot be automated. `Optimize-Volume` is the built-in PowerShell equivalent and picks TRIM or defrag automatically.

**Why does step 3 empty the Recycle Bin too?**
All Disk Cleanup categories are enabled except the protected ones, and the Recycle Bin is one of the categories. Step 4 empties it as well.

**Can I add or remove protected cleanup categories?**
Yes: edit the `$exclude` list at the top of step 3 in the script (wildcards allowed).

---

## Known limitations

- Built for Windows 10/11 and Windows PowerShell 5.1. Not tested on older Windows versions or on PowerShell 7.
- The exe is a launcher around the script and must be rebuilt (`Build-Exe.cmd`) after script changes. It has not been tested on every Windows version.
- **Server mode was written from the documentation and has not been run on a server yet.** Output formats that were assumed (for example `vssadmin`, `w32tm`, `dcdiag`) may differ on localized servers; the checks that parse text lines (VSS writers, time source) can then show an INFO line instead of a result.
- The service check in step 15 can list services that are normally stopped; it ignores delayed-start services and a short list of known ones, not every case.
- The window uses classic Windows Forms. It declares itself DPI aware and scales its layout, but that was not tested on high-DPI screens.
- The Dutch translation covers the window only; logs, reports and the text printed by the steps stay English. The translation was written without a native check.
- The winget program list is read from `winget upgrade`'s text table, so it can break if a future winget changes that table.
- The schedule dialog creates a task that runs while you are logged on (it needs your session, not a service account).
- Power loss **during** a step cannot be prevented, only between steps.
- The window shows no live percentage for SFC and DISM, only their output when they finish a line.
- "Stop after this step" cannot interrupt a step that is already running.
- winget can only update what is in its repositories; software not listed there is skipped.
- Temp cleanup skips files in use; some may remain until the next run.
- Defragmenting large hard disks can take hours.

---

## Disclaimer

This script changes your system and deletes files (temp files, caches, the Recycle Bin and Disk Cleanup categories). Read it before running it, make sure you have normal backups of your important files, and use it at your own risk. No warranty of any kind is provided.
