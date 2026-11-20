# PC Maintenance (Run-Maintenance)

Windows maintenance tool: one PowerShell script with a WinForms window, plus an exe launcher.
Owner: Thomas (Belgium, IT student). Talk to him in English unless he writes Dutch.
Background and past decisions: `HISTORY.md`. Planned work: `ROADMAP.md`. User docs: `README.md`.

## Files

| File | Role |
|---|---|
| `Run-Maintenance.ps1` | The whole program: engine + unattended mode + window (~3500 lines) |
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
- Unattended exit codes: 0 fine, 1 warnings (stopped, steps unavailable or gated, or any `WARN` line from a check), 2 failures or could not start.
- There is **no PowerShell in the Linux sandbox**, so nothing can be run here. Checks done so far: brace/paren balance, ASCII-only, reading the code. Say so in every report; never claim "tested".

## Architecture of `Run-Maintenance.ps1`

1. **Self-elevate** (relaunches with `-Verb RunAs`, forwards bound parameters).
2. **Shared settings**: log dir `%USERPROFILE%\MaintenanceLogs`, cancel flag file `%TEMP%\pc-maintenance-stop.flag`, `$StepInfo`, the step registry (id, name, title, description, time estimate, `Modes`, `Risk`, optional `Requires` check that returns a reason text when the step cannot run). `Get-SystemInfo` reads ProductType/InstallationType; `$RunMode` (Pc/Server, `-Mode` overrides) selects `$ModeStepIds`; `$Unavailable` maps step id -> reason and travels to the engine in `$Opt`.
3. **`$Engine = { param($Opt) ... }`**: a scriptblock holding all the work. It talks only through output lines:
   - normal line = log text
   - `@@STEP|<id>|START|<name>` and `@@STEP|<id>|END|<OK/Failed/Skipped>|<sec>|<msg>`
   - `@@DONE|<GB freed>|<time>|<failed count>|<reboot pending>|<stopped>|<aborted>|<unavailable count>|<report file>|<warnings>`
4. **Unattended mode** (`-All`, `-Steps`, `-Skip*`): runs `& $Engine $runOpt` in the console and writes the log.
5. **Window**: builds WinForms; `Start-Run` runs the engine in a **background runspace** (`$Engine.ToString()` passed to `AddScript`, options hashtable as the argument). A 300 ms timer (`Poll-Run`) reads the output collection and updates the UI.

Because the engine runs in its own runspace, it cannot see script-level variables. Everything it needs comes through `$Opt`, and its helper functions are defined inside the block.

### `$Opt` keys
`Steps` (int[]), `StepNames`, `KeepRestorePoints`, `WingetSilent`, `CleanStrength` (Standard/Gentle), `TempDays`, `EmptyRecycleBin`, `RepairMode` (Both/SfcOnly/DismOnly), `DefenderMode` (Quick/UpdateOnly/Full), `OptimizeDrive` (All or a letter), `IgnorePower`, `HistoryFile`, `CancelFile`, `Mode`, `SystemText`, `Unavailable` (hashtable id -> reason), `Preview`, `WingetIds`, `WindowsUpdateMode` (Scan/Install), `CacheWindowsUpdate`, `CacheDeliveryOpt`, `CacheBrowsers`, `DiskScan`, `ReportFile`, `MaintenanceWindow`, `Gated`, `IsDomainController`, `OptimizeAction` (Optimize/Analyze), `ServerCleanComponents`, `ServerCleanWuCache`, `ServerCleanTemp`, `IisLogDays`. The window also has `Reboot`.

### Phase 2 additions (see ROADMAP.md)
- Steps 9-14 (Windows Update COM, extra caches, space report, crash summary, hardware health, security check-up). Step 10 has `DefaultOn = $false`: not ticked, not in `-All`/`$ModeDefaultIds`.
- `New-RunOptions` is the one place with engine option defaults; the window (`Get-RunOptions`) and unattended mode both start from it. Add new `$Opt` keys there.
- `$Presets` (QuickTuneUp / DeepClean / WeeklySafe) drive the window buttons and `-Preset`.
- Preview mode (`$Opt.Preview`, `-Preview`): only steps 2, 4, 10, 19; engine steps must not change anything when it is set; no CSV row, no report, no power wait.
- Engine helpers `Get-TempContents` / `Remove-Scanned` are shared by steps 4 and 10. `Write-HtmlReport` builds the report from `$State.Results` and `$State.StepLog` (the lines each step printed).
- The window code is rebuilt in a `do { } while ($script:Restart)` loop (language/theme buttons). Event handlers cannot see function-local variables, so dialogs keep their controls in `$script:Dlg`; do not use `GetNewClosure()`.
- `T 'English text'` translates through `$script:NL` (Dutch). New window strings need a dictionary entry; the .ps1 must stay ASCII, so accented letters are written as `[char]0xEF` style expressions. Logs/engine output stay English.
- **Layout follows the window size.** Labels/panels that wrap are registered with `Add-Wrap` (base `form` or `flow`, offset) and the step cards are in `$script:CardList`; `Update-Layout` (form Resize, Shown, run start; guarded by `$script:InLayout`) sets their widths. Do not hard-code widths for new controls: register them. Window size/maximized are saved in settings.json. Cards are a TableLayoutPanel (colored risk strip + content); steps are shown in groups (`$script:StepGroup`), run order stays by id. Buttons: `Name='primary'` accent, `'ghost'` toolbar, otherwise bordered; `Apply-Theme` styles them in both themes.
- Sizes in the window go through `S`/`Sz`/`Pd` (DPI scale). Settings live in `%APPDATA%\PCMaintenance\settings.json`.
- Decided against: the roadmap's "GitHub release check" (a network call outside the allowed list). Needs the owner's OK first.
- Checking the .ps1 without PowerShell: `pip install tree-sitter tree-sitter-language-pack` then parse with the `powershell` grammar; the only expected ERROR nodes are the `1GB`/`1MB`/`1KB` numeric suffixes. It checks syntax only, not behavior.

### Phase 3 additions: Server mode (see ROADMAP.md)
- Steps 15-19 are Server-only (`Modes = @('Server')`): health report, backup check, role checks (AD DS/DNS/DHCP/IIS/Hyper-V/cluster), storage health, cleanup (`Gate`, `DefaultOn = $false`). Steps 5-9 and 11-14 work in both modes.
- **Maintenance window gate.** `Gate = $true` in the registry (steps 5, 7, 19) -> `$Gated` (Server mode only) -> `$Opt.Gated`. `Invoke-Step` skips a gated step unless `$Opt.MaintenanceWindow` (`-MaintenanceWindow`, or the window's confirmation dialog, or the menu's YES prompt). Step 7 is exempt while `$Opt.OptimizeAction -eq 'Analyze'` (the server default); step 9 installs only with the window. On a server `$ModeDefaultIds` is read-only steps only unless `-MaintenanceWindow`. Never make a server step change something outside this gate.
- **Warnings.** Engine helpers `Add-Warning` / `Write-Check` print `  WARN  ` / `  OK    ` lines and count `$State.Warnings` (field 9 of `@@DONE`). Any warning gives exit code 1. New checks should use them, not raw `Say`.
- Console path: `Invoke-ConsoleRun` (used by unattended mode and the text menu) runs the engine and computes the exit code; `Show-ConsoleMenu` is the Server Core fallback (`-Menu` forces it). Server Core is detected from `InstallationType`; `Launcher.cs` (`IsServerCore`) keeps the console visible for the exe there.
- `Install-MaintTask` / `Remove-MaintTask` are top-level and shared by the window, the menu and `-Schedule`/`-RemoveSchedule`. Server -> runs as SYSTEM; PC -> current user, on AC power only.
- `$LogDir` is `C:\ProgramData\PCMaintenance\Logs` in Server mode (SYSTEM has no useful profile), else `%USERPROFILE%\MaintenanceLogs`. `$SystemInfo` / `$RunMode` / `$ModeLabel` are computed at the top of the script because of that.
- Shared engine helpers added: `Test-SafeTempRoot`, `Clear-WuDownloadCache` (steps 10 and 19). `$PreviewIds` = steps with a preview (2, 4, 10, 19).
- Server-mode text parsing (`vssadmin`, `w32tm`, `dcdiag`) is best effort and English-oriented; keep failures non-fatal (INFO line, not a crash).
- Status: **not run on any Windows Server**. Owner has test VMs (with and without GUI); the first real run is the test.

### Adding a step
Add an entry to `$StepInfo` (set `Modes`, `Risk`, `Requires`, optionally `DefaultOn`), an `Invoke-Step -Id N -Name $Opt.StepNames[N-1]` block in the engine, any dropdown to `$script:StepOptions`, a line in README. Everything printed inside the block must go through `Say`.

## Safety rules (decided by the owner, keep them)

- cleanmgr profile enables all categories **except** `Downloads*`, `Previous Installations`, `*ESD*` (wildcards on purpose). It rebuilds the registry profile every run and removes it afterwards.
- Temp cleanup: only folders named `Temp`/`Tmp` and not junctions; a file is deleted only if **both** creation and modification time are older than N days (default 3); the folder walk skips junctions/symlinks; empty old folders removed with non-recursive delete.
- Restore points: only ones named `Before maintenance ...` are ever removed; keep 2 (new + newest old); remove old ones only after the new one succeeded.
- winget: `upgrade --all` **without** `--include-unknown`.
- Power: on a laptop on battery, wait up to 10 min for the charger, check again before every step, abort the rest if it never comes. `-IgnorePower` is the only override.
- "Stop after this step" never kills a running step.
- cleanmgr is never started with `Start-Process -Wait` (it hangs on helper processes). It polls and has a 30 min timeout.

## Gotchas already hit (see HISTORY.md for the story)

- The main window is resizable on purpose (no `MaximumSize`). Never set a `MaximumSize` of `0` height on a Form (it collapses the window to a title bar); the `Add_Shown` safety net still restores a sane size.
- `Show-Message 'a' + "b" 'title'` does not concatenate. Build the string first.
- Menu/QuickEdit: clicking a classic console pauses output. The unattended path turns QuickEdit off.
- Installers opened by winget may need a window; `--silent` only when asked (`-SilentWinget`).
- The exe has a **copy** of the script baked in; after any change to the .ps1 the exe must be rebuilt with `Build-Exe.cmd`.
- The exe unpacks the script to `C:\Program Files\PCMaintenance\run-<guid>\` on purpose (admin-only folder; a user-writable temp dir would allow privilege escalation).

## Working agreements

- Be honest about what is untested. Review code critically; the owner asked for that and values it.
- Keep README, `$StepInfo` and the advanced-options table in sync when behavior changes.
- Report changes briefly; the owner is not always a PowerShell expert but is IT-literate.
