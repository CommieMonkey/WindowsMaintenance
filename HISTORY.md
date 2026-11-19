# History: how the project got here

Summary of the chat that built this (claude.ai, Nov 2026). Newest context last.

## Original request
A PowerShell script that runs PC maintenance with only built-in Windows tools: winget update, cleanmgr, drive optimize; plus anything else useful.

## Decisions the owner made
- Use `Optimize-Volume` instead of `dfrgui` (dfrgui is a GUI and cannot be automated; Optimize-Volume does TRIM on SSD, defrag on HDD).
- cleanmgr: everything is cleaned **except** Downloads, Previous Windows installations and the **ESD files** (he asked to keep the ESD files).
- **Keep 2 restore points** (name prefix `Before maintenance`), delete older ones the script made.
- winget: **drop `--include-unknown`**.
- **Laptop must be on the charger** (wait, then abort).
- Fix all three weak spots in temp cleanup (creation+modified date, temp-folder sanity check, junction/symlink skipping).
- Wants it **beginner friendly**: a full GUI with checkboxes and an optional advanced view with dropdowns, as a **single exe**.
- Wants: a list of extra PC features, and a **Server mode in the same exe** supporting Windows Server 2019 up to the latest (see ROADMAP.md).
- He made a GitHub fork and wants the GUI version to become `main`.

## Bugs found and how they were fixed
| Symptom | Cause | Fix |
|---|---|---|
| Hang in winget step; works when run by hand | `--silent` hides installer windows that need input | silent only on request (`-SilentWinget`) |
| Step 4 looked frozen | tens of thousands of temp files, no output | progress counter, age filter, progress messages |
| Step 5 only advanced after clicking the window and pressing Enter | console QuickEdit select mode pauses output | disable QuickEdit in unattended console |
| Step 3 hung, cleanmgr windows "disappeared" | `Start-Process -Wait` waits for helper processes; clicking the console covered the windows | poll for cleanmgr, 30 min timeout, minimize its windows, stop leftovers first |
| Script only ran with `-ExecutionPolicy Bypass` | default execution policy | `Run-Maintenance.cmd` launcher, then the exe |
| Window showed only a title bar (exe) | `MaximumSize` height `0` is literal for a Form | height 4000 plus an `Add_Shown` safety net. **Owner confirmed the exe works after rebuilding.** |
| Restart dialog message | `'a' + "b"` passed as command arguments | build the string first |

## Critical review findings (owner said "you make valid points")
Aggressive cleanmgr categories (recycle bin, driver packages, dumps, Windows Update cleanup), temp cleanup weaknesses, only one restore point, `--include-unknown`, no power check, scheduled task in a user-writable folder = privilege escalation. Most were fixed (see decisions). Still true: step 3 empties the Recycle Bin and removes old driver packages/dumps (Gentle strength avoids that), `-Reboot` is a forced restart.

## Windows Server findings
See ROADMAP.md, Phase 3.

## Verification status
Nothing has been executed by the assistant: no PowerShell in its sandbox. The owner ran the exe on a real Windows PC and reported it works. Server editions: untested.

## Phase 2 (built in a Claude Code session, Nov 2026)
Built all of ROADMAP.md phase 2 except the GitHub release check (it needs a network call outside the allowed list). New steps 9-14, presets, preview, remembered settings, winget chooser with pinning, scheduler dialog, HTML report and history window, Tools window (repairs + startup manager), Dutch/English, dark mode, DPI scaling, finished notification. Nothing was executed: no PowerShell in that sandbox. The script was only parsed with a tree-sitter PowerShell grammar (syntax only). Expect a first real run on Windows to find bugs; the riskiest parts are the winget table parsing, the scheduled task settings, the DPI layout and the Dutch/dark-theme rebuild loop.
