# PC Maintenance (Run-Maintenance)

Windows maintenance tool: one PowerShell script with a WinForms window, plus an exe launcher.
Owner: Thomas (Belgium, IT student). Talk to him in English unless he writes Dutch.
Background and past decisions: `HISTORY.md`. Planned work: `ROADMAP.md`. User docs: `README.md`.

## Files

| File | Role |
|---|---|
| `Run-Maintenance.ps1` | The whole program: engine + unattended mode + window (~1470 lines) |
| `Run-Maintenance.cmd` | Double-click launcher for the .ps1 (execution-policy bypass, this run only) |
| `Launcher.cs` | Exe launcher. Embeds the .ps1 as a resource, runs it with powershell.exe |
| `app.manifest` | `requireAdministrator` for the exe |
| `Build-Exe.cmd` | Builds `Run-Maintenance.exe` with the csc.exe that ships with Windows |

## Hard constraints (do not break)

- **Windows PowerShell 5.1 only.** No PS7 syntax (`??`, `?.`, ternary, `&&`).
- **The .ps1 must stay pure ASCII.** It has no BOM, and 5.1 misreads UTF-8 otherwise. No curly quotes, no em dashes. Check: `grep -nP '[^\x00-\x7F]' Run-Maintenance.ps1`.
- **`.cmd` files use CRLF.** `.gitattributes` enforces it; keep it.
- **`Launcher.cs` is C# 5.** It is compiled by the .NET Framework csc.exe: no `$""`, `?.`, `=>`, `nameof`, `out var`.
- **Safe by default.** Deleting data must be opt-in or protected (see "Safety rules").
- **Only built-in Windows tools.** No downloads, no third-party modules, no network calls except winget, DISM and Defender.
- Unattended exit codes: 0 fine, 1 warnings (stopped / steps unavailable), 2 failures or could not start.
- There is **no PowerShell in the Linux sandbox**, so nothing can be run here. Checks done so far: brace/paren balance, ASCII-only, reading the code. Say so in every report; never claim "tested".

## Architecture of `Run-Maintenance.ps1`

1. **Self-elevate** (relaunches with `-Verb RunAs`, forwards bound parameters).
2. **Shared settings**: log dir `%USERPROFILE%\MaintenanceLogs`, cancel flag file `%TEMP%\pc-maintenance-stop.flag`, `$StepInfo`, the step registry (id, name, title, description, time estimate, `Modes`, `Risk`, optional `Requires` check that returns a reason text when the step cannot run). `Get-SystemInfo` reads ProductType/InstallationType; `$RunMode` (Pc/Server, `-Mode` overrides) selects `$ModeStepIds`; `$Unavailable` maps step id -> reason and travels to the engine in `$Opt`.
3. **`$Engine = { param($Opt) ... }`**: a scriptblock holding all the work. It talks only through output lines:
   - normal line = log text
   - `@@STEP|<id>|START|<name>` and `@@STEP|<id>|END|<OK/Failed/Skipped>|<sec>|<msg>`
   - `@@DONE|<GB freed>|<time>|<failed count>|<reboot pending>|<stopped>|<aborted>|<unavailable count>`
4. **Unattended mode** (`-All`, `-Steps`, `-Skip*`): runs `& $Engine $runOpt` in the console and writes the log.
5. **Window**: builds WinForms; `Start-Run` runs the engine in a **background runspace** (`$Engine.ToString()` passed to `AddScript`, options hashtable as the argument). A 300 ms timer (`Poll-Run`) reads the output collection and updates the UI.

Because the engine runs in its own runspace, it cannot see script-level variables. Everything it needs comes through `$Opt`, and its helper functions are defined inside the block.

### `$Opt` keys
`Steps` (int[]), `StepNames`, `KeepRestorePoints`, `WingetSilent`, `CleanStrength` (Standard/Gentle), `TempDays`, `EmptyRecycleBin`, `RepairMode` (Both/SfcOnly/DismOnly), `DefenderMode` (Quick/UpdateOnly/Full), `OptimizeDrive` (All or a letter), `IgnorePower`, `HistoryFile`, `CancelFile`, `Mode`, `SystemText`, `Unavailable` (hashtable id -> reason). The window also has `Reboot`.

### Adding a step
Add an entry to `$StepInfo` (set `Modes`, `Risk`, `Requires`), an `Invoke-Step -Id N -Name $Opt.StepNames[N-1]` block in the engine, any dropdown to `$script:StepOptions`, a line in README. Everything printed inside the block must go through `Say`.

## Safety rules (decided by the owner, keep them)

- cleanmgr profile enables all categories **except** `Downloads*`, `Previous Installations`, `*ESD*` (wildcards on purpose). It rebuilds the registry profile every run and removes it afterwards.
- Temp cleanup: only folders named `Temp`/`Tmp` and not junctions; a file is deleted only if **both** creation and modification time are older than N days (default 3); the folder walk skips junctions/symlinks; empty old folders removed with non-recursive delete.
- Restore points: only ones named `Before maintenance ...` are ever removed; keep 2 (new + newest old); remove old ones only after the new one succeeded.
- winget: `upgrade --all` **without** `--include-unknown`.
- Power: on a laptop on battery, wait up to 10 min for the charger, check again before every step, abort the rest if it never comes. `-IgnorePower` is the only override.
- "Stop after this step" never kills a running step.
- cleanmgr is never started with `Start-Process -Wait` (it hangs on helper processes). It polls and has a 30 min timeout.

## Gotchas already hit (see HISTORY.md for the story)

- **A `0` in a Form's `MaximumSize` collapses the window to a title bar.** Use a big number (currently 4000).
- `Show-Message 'a' + "b" 'title'` does not concatenate. Build the string first.
- Menu/QuickEdit: clicking a classic console pauses output. The unattended path turns QuickEdit off.
- Installers opened by winget may need a window; `--silent` only when asked (`-SilentWinget`).
- The exe has a **copy** of the script baked in; after any change to the .ps1 the exe must be rebuilt with `Build-Exe.cmd`.
- The exe unpacks the script to `C:\Program Files\PCMaintenance\run-<guid>\` on purpose (admin-only folder; a user-writable temp dir would allow privilege escalation).

## Working agreements

- Be honest about what is untested. Review code critically; the owner asked for that and values it.
- Keep README, `$StepInfo` and the advanced-options table in sync when behavior changes.
- Report changes briefly; the owner is not always a PowerShell expert but is IT-literate.
