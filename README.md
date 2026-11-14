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
7. [Command-line parameters](#command-line-parameters)
8. [Safety design](#safety-design)
9. [Power protection (laptops)](#power-protection-laptops)
10. [Logging](#logging)
11. [Running it automatically (scheduled task)](#running-it-automatically-scheduled-task)
12. [The EXE version](#the-exe-version)
13. [Troubleshooting](#troubleshooting)
14. [FAQ](#faq)
15. [Known limitations](#known-limitations)
16. [Disclaimer](#disclaimer)

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
- **Unattended mode.** `-All` / `-Steps` skip the window, so it works in a scheduled task.

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

- Windows 10 or Windows 11
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
4. Tick the steps you want (everything is ticked by default) and press **Start maintenance**.

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

- Every step has a checkbox, a plain-language title, a short explanation and an estimate of how long it takes. Everything is ticked by default.
- Three quick buttons at the top: **Select everything**, **Select nothing** and **Everything except the slow repair**.
- At the bottom a line shows your **power status**. On a laptop that is running on battery it turns red, and the Start button will refuse to start until you plug in the charger.
- Press **Start maintenance**. A short confirmation reminds you to save your work (and tells you if the Recycle Bin is going to be emptied for good).

**While it runs**

- A list shows every selected step as *Waiting*, *Running...*, *Done*, *Failed* or *Skipped*, with a progress bar for the whole run and a line saying what it is doing right now.
- **Show technical details** reveals the full text output (the same text that is saved in the log file).
- **Stop after this step** finishes the step that is running and skips the rest. It never kills a step halfway, because stopping a repair or an update in the middle is riskier than waiting.
- The window cannot be closed by accident while maintenance is running.
- **Open log folder** opens `%USERPROFILE%\MaintenanceLogs`.

**When it is finished**

You see "All done!" (or a warning if some steps failed), how much space was freed, how long it took and whether Windows would like a restart. **Back to options** returns to the first screen.

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

### At the end

A summary table of every step (status, duration, message), total time, space freed, the log locations, and a warning if a reboot is pending.

---

## Command-line parameters

| Parameter | Description |
|---|---|
| `-All` | Run every step without opening the window. Use this for scheduled tasks. |
| `-Steps "1,3,5-6"` | Run only these steps, without the window. Accepts lists and ranges. |
| `-SilentWinget` | Run winget with `--silent` (no installer windows). |
| `-IgnorePower` | Skip the charger check (see below). |
| `-SkipRestorePoint` | Don't run step 1. Existing restore points are left untouched. |
| `-SkipSFC` | Don't run step 5. |
| `-SkipDefender` | Don't run step 6. |
| `-Reboot` | Reboot automatically 30 seconds after finishing. Uses a forced restart, so save your work first. |

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

The script's exit code is `1` if it could not start (invalid `-Steps`, charger never connected) and `0` otherwise. **A failed step does not change the exit code**: check the summary or the history CSV for step results.

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

(When you elevate with a *different* administrator account, this is that account's profile folder.)

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

Transcripts older than **90 days** are deleted automatically. The CSV is never trimmed.

---

## Running it automatically (scheduled task)

Always use `-All` (or `-Steps`) so the script runs without opening the window. Add `-SilentWinget` because a scheduled task has no desktop to show installer windows on.

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
- The window uses classic Windows Forms and is not tuned for very high display scaling (text may look slightly soft on some screens).
- Power loss **during** a step cannot be prevented, only between steps.
- The window shows no live percentage for SFC and DISM, only their output when they finish a line.
- "Stop after this step" cannot interrupt a step that is already running.
- winget can only update what is in its repositories; software not listed there is skipped.
- Temp cleanup skips files in use; some may remain until the next run.
- The exit code does not reflect failed steps (see the CSV).
- Defragmenting large hard disks can take hours.

---

## Disclaimer

This script changes your system and deletes files (temp files, caches, the Recycle Bin and Disk Cleanup categories). Read it before running it, make sure you have normal backups of your important files, and use it at your own risk. No warranty of any kind is provided.
