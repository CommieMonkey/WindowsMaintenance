<#
.SYNOPSIS
    Automated PC maintenance using only built-in Windows tools.

.DESCRIPTION
    When started without -All / -Steps, a menu lets you pick which steps to run.
    On a laptop the charger must be connected (the script waits up to 10 minutes).

    1. Creates a new restore point and keeps only the last 2 (older ones are deleted)
    2. Updates all software via winget
    3. Cleans disk space via cleanmgr (silent, pre-configured profile)
    4. Safely clears old temp files, empties the recycle bin, flushes DNS
    5. Repairs the Windows component store (DISM) and checks system files (SFC)
    6. Updates Defender signatures and runs a quick scan
    7. Optimizes all drives (TRIM for SSDs, defrag for HDDs)
    8. Checks disk health and reports free space

    Logging (in %USERPROFILE%\MaintenanceLogs):
      - Maintenance_<date>.log      full transcript of every run
      - MaintenanceHistory.csv      one row per step per run (status, duration, message)
      - Log files older than 90 days are removed automatically

.PARAMETER Steps
    Run only these steps, without showing the menu. Accepts numbers, lists
    and ranges, e.g. -Steps "1,3,5" or -Steps "2-4,7".
.PARAMETER All
    Run every step without showing the menu (use this for scheduled tasks).
.PARAMETER SkipSFC
    Skip DISM/SFC repair (the slowest step).
.PARAMETER SkipDefender
    Skip the Defender update and quick scan.
.PARAMETER SkipRestorePoint
    Don't create a restore point (old ones are then left untouched).
.PARAMETER SilentWinget
    Force winget to install updates with no UI at all (--silent). By default
    installers may show their own window, which avoids hangs on packages that
    can't really run silently. Use this switch for unattended/scheduled runs.
.PARAMETER IgnorePower
    Skip the AC power check. By default a laptop must be plugged in.
.PARAMETER Reboot
    Reboot automatically when finished.

.EXAMPLE
    .\Run-Maintenance.ps1                  (shows the step menu)
    .\Run-Maintenance.ps1 -All             (normal run, no menu)
    .\Run-Maintenance.ps1 -Steps "1,3,5-6" (only these steps)
    .\Run-Maintenance.ps1 -All -SkipSFC -Reboot
#>

[CmdletBinding()]
param(
    [string]$Steps,
    [switch]$All,
    [switch]$SkipSFC,
    [switch]$SkipDefender,
    [switch]$SkipRestorePoint,
    [switch]$SilentWinget,
    [switch]$IgnorePower,
    [switch]$Reboot
)

# ---------------------------------------------------------------- Self-elevate
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Not running as admin - relaunching elevated..." -ForegroundColor Yellow
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    foreach ($key in $PSBoundParameters.Keys) {
        $val = $PSBoundParameters[$key]
        if ($val -is [switch]) {
            if ($val.IsPresent) { $argList += "-$key" }
        } else {
            $argList += "-$key", "`"$val`""
        }
    }
    Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $argList -Verb RunAs
    exit
}

# ------------------------------------------- Disable console QuickEdit (click-to-pause)
# Clicking inside a classic console window enters "Select" mode, which freezes
# the script's output until you press Enter. Turning QuickEdit off prevents that.
try {
    Add-Type -Namespace Native -Name ConsoleMode -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int nStdHandle);
[DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
[DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
'@
    $hIn = [Native.ConsoleMode]::GetStdHandle(-10)   # STD_INPUT_HANDLE
    [uint32]$consoleMode = 0
    if ([Native.ConsoleMode]::GetConsoleMode($hIn, [ref]$consoleMode)) {
        # clear ENABLE_QUICK_EDIT_MODE (0x40), set ENABLE_EXTENDED_FLAGS (0x80)
        $newMode = [uint32](($consoleMode -band ([uint32]::MaxValue - 0x40)) -bor 0x80)
        [void][Native.ConsoleMode]::SetConsoleMode($hIn, $newMode)
    }
} catch { }   # not fatal: some hosts (e.g. ISE) have no real console

# ------------------------------------------------------------- Step selection
$stepNames = @(
    'Restore point (keeps the last 2)',
    'Update software (winget)',
    'Disk cleanup (cleanmgr)',
    'Temp files, recycle bin, DNS cache',
    'System repair (DISM + SFC) - slow, 10-20 min',
    'Defender update + quick scan',
    'Optimize drives (TRIM/defrag)',
    'Disk health report'
)
$maxStep = $stepNames.Count

# Turns "1,3,5 and 6", "2-4", "a" / "all" into a sorted list of step numbers.
# Returns $null when something is out of range or nothing was recognised.
function Resolve-StepSelection([string]$Text, [int]$Max) {
    $t = $Text.Trim().ToLower()
    if ($t -eq '' -or $t -match '^(a|all|\*)$') { return @(1..$Max) }
    $nums = @()
    foreach ($m in [regex]::Matches($t, '(\d+)\s*-\s*(\d+)|(\d+)')) {
        if ($m.Groups[1].Success) {
            $a = [int]$m.Groups[1].Value; $b = [int]$m.Groups[2].Value
            if ($a -gt $b) { $a, $b = $b, $a }
            $nums += $a..$b
        } else {
            $nums += [int]$m.Groups[3].Value
        }
    }
    if ($nums.Count -eq 0) { return $null }
    if (@($nums | Where-Object { $_ -lt 1 -or $_ -gt $Max }).Count -gt 0) { return $null }
    return @($nums | Sort-Object -Unique)
}

# Old -Skip* switches still work: they remove that step from the selection.
$skipped = @()
if ($SkipRestorePoint) { $skipped += 1 }
if ($SkipSFC)          { $skipped += 5 }
if ($SkipDefender)     { $skipped += 6 }

# No menu for scheduled/unattended runs
$noMenu    = $All -or $Steps -or ($skipped.Count -gt 0) -or (-not [Environment]::UserInteractive)
$menuShown = $false
$selected  = $null

if ($Steps) {
    $selected = Resolve-StepSelection $Steps $maxStep
    if (-not $selected) {
        Write-Host "Invalid -Steps value '$Steps'. Use numbers 1-$maxStep, e.g. -Steps `"1,3,5-6`"." -ForegroundColor Red
        Start-Sleep -Seconds 5
        exit 1
    }
} elseif ($noMenu) {
    $selected = @(1..$maxStep)
} else {
    $menuShown = $true
    while (-not $selected) {
        Write-Host ""
        Write-Host "Which maintenance steps do you want to run?" -ForegroundColor Cyan
        Write-Host ""
        for ($i = 0; $i -lt $maxStep; $i++) {
            Write-Host ("  {0}  {1}" -f ($i + 1), $stepNames[$i])
        }
        Write-Host ""
        Write-Host "  A  All steps (normal run)  [default - just press Enter]"
        Write-Host "  Q  Quit"
        Write-Host ""
        Write-Host "Examples:  1,3,5,6    2-4    A"
        $answer = Read-Host "Your choice"
        if ($answer.Trim() -match '^(q|quit|exit)$') { Write-Host "Cancelled."; exit }
        $selected = Resolve-StepSelection $answer $maxStep
        if (-not $selected) {
            Write-Host "Invalid choice - use numbers between 1 and $maxStep." -ForegroundColor Yellow
        }
    }
}

$selected = @($selected | Where-Object { $skipped -notcontains $_ })
if ($selected.Count -eq 0) {
    Write-Host "Nothing to do." -ForegroundColor Yellow
    Start-Sleep -Seconds 3
    exit
}

# --------------------------------------------------------------------- Logging
$logDir      = Join-Path $env:USERPROFILE 'MaintenanceLogs'
$historyFile = Join-Path $logDir 'MaintenanceHistory.csv'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null

# Remove old transcripts (keep 90 days). The history CSV is kept.
Get-ChildItem -Path $logDir -Filter 'Maintenance_*.log' -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-90) } |
    Remove-Item -Force -ErrorAction SilentlyContinue

$logFile = Join-Path $logDir ("Maintenance_{0:yyyy-MM-dd_HH-mm}.log" -f (Get-Date))
Start-Transcript -Path $logFile | Out-Null

$runId      = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
$results    = New-Object System.Collections.Generic.List[object]
$stepNumber = 0
$totalSteps = $selected.Count

# ----------------------------------------------------------------- AC power check
# Desktops (no battery) always pass. On a laptop the charger must be connected.
function Test-ACPower {
    if ($IgnorePower) { return $true }
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $ps = [System.Windows.Forms.SystemInformation]::PowerStatus
        if ([int]$ps.BatteryChargeStatus -eq 128) { return $true }   # NoSystemBattery = desktop
        return ($ps.PowerLineStatus -ne 'Offline')
    } catch {
        return $true   # can't tell: don't block the run
    }
}

function Wait-ForACPower {
    param([int]$TimeoutMinutes = 10)
    if (Test-ACPower) { return $true }
    Write-Host ""
    Write-Host "!! Laptop is running on battery. Connect the charger to continue." -ForegroundColor Yellow
    Write-Host "   (waiting up to $TimeoutMinutes minutes - press Ctrl+C to cancel)" -ForegroundColor Yellow
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while (-not (Test-ACPower)) {
        if ((Get-Date) -gt $deadline) { return $false }
        Start-Sleep -Seconds 3
    }
    Write-Host "Charger connected - continuing." -ForegroundColor Green
    return $true
}

# Runs one step: prints a header, times it, catches errors, records the result.
function Invoke-Step {
    param(
        [string]$Name,
        [scriptblock]$Action,
        [int]$Id
    )
    if ($script:selected -notcontains $Id) {
        $script:results.Add([pscustomobject]@{
            RunId    = $script:runId
            Step     = $Name
            Status   = 'Skipped'
            Duration = '00:00:00'
            Message  = 'Not selected'
        })
        return
    }
    if ($script:aborted) {
        $script:results.Add([pscustomobject]@{
            RunId    = $script:runId
            Step     = $Name
            Status   = 'Skipped'
            Duration = '00:00:00'
            Message  = 'Aborted: charger was disconnected'
        })
        return
    }
    if (-not (Wait-ForACPower)) {
        $script:aborted = $true
        Write-Warning "Charger not connected - skipping this and all remaining steps."
        $script:results.Add([pscustomobject]@{
            RunId    = $script:runId
            Step     = $Name
            Status   = 'Failed'
            Duration = '00:00:00'
            Message  = 'Charger not connected - step not run'
        })
        return
    }
    $script:stepNumber++
    Write-Host ""
    Write-Host ("[{0}/{1}] {2}" -f $script:stepNumber, $totalSteps, $Name) -ForegroundColor Cyan

    $status  = 'OK'
    $message = ''
    $sw = [Diagnostics.Stopwatch]::StartNew()

    try {
        & $Action
    } catch {
        $status  = 'Failed'
        $message = $_.Exception.Message
        Write-Warning "Step failed: $message"
    }
    $sw.Stop()

    $script:results.Add([pscustomobject]@{
        RunId     = $script:runId
        Step      = $Name
        Status    = $status
        Duration  = $sw.Elapsed.ToString('hh\:mm\:ss')
        Message   = $message
    })
}

function Get-FreeSpaceGB {
    (Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Used -ne $null } |
        Measure-Object -Property Free -Sum).Sum / 1GB
}

Write-Host ("Selected steps: {0}" -f ($selected -join ', '))

$aborted = $false
if (-not (Wait-ForACPower)) {
    Write-Host "Charger not connected - nothing was changed. Aborting." -ForegroundColor Red
    Stop-Transcript | Out-Null
    if ($menuShown) { Read-Host "Press Enter to close this window" | Out-Null }
    exit 1
}

$startTime  = Get-Date
$freeBefore = Get-FreeSpaceGB

# ------------------------------------------------------ 1. Restore point
Invoke-Step -Id 1 -Name 'Restore point (create new, keep last 2)' -Action {
    # Native API used to delete a single restore point by sequence number
    if (-not ('Native.SysRestore' -as [type])) {
        Add-Type -Namespace Native -Name SysRestore -MemberDefinition @'
[DllImport("srclient.dll")]
public static extern int SRRemoveRestorePoint(int dwRPNum);
'@
    }

    $prefix = 'Before maintenance'
    $old = @(Get-ComputerRestorePoint -ErrorAction SilentlyContinue |
             Where-Object { $_.Description -like "$prefix*" })
    Write-Host "Found $($old.Count) restore point(s) from previous runs."

    Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop

    # Windows normally allows only one restore point per 24h; lift that
    # limit temporarily so the script works on repeat runs, then restore it.
    $srKey  = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    $srName = 'SystemRestorePointCreationFrequency'
    $oldFreq = (Get-ItemProperty -Path $srKey -Name $srName -ErrorAction SilentlyContinue).$srName
    New-ItemProperty -Path $srKey -Name $srName -Value 0 -PropertyType DWord -Force | Out-Null

    try {
        Checkpoint-Computer -Description "$prefix $(Get-Date -Format 'yyyy-MM-dd HH:mm')" `
            -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        Write-Host "New restore point created."
    } finally {
        if ($null -eq $oldFreq) {
            Remove-ItemProperty -Path $srKey -Name $srName -ErrorAction SilentlyContinue
        } else {
            Set-ItemProperty -Path $srKey -Name $srName -Value $oldFreq
        }
    }

    # Only reached if the new restore point was created successfully.
    # Keep 2 in total: the new one plus the newest previous one.
    $keepTotal = 2
    $toRemove  = @($old | Sort-Object { [int]$_.SequenceNumber } -Descending |
                   Select-Object -Skip ($keepTotal - 1))
    Write-Host "Keeping $($keepTotal - 1) previous restore point(s), removing $($toRemove.Count)."
    foreach ($rp in $toRemove) {
        $rc = [Native.SysRestore]::SRRemoveRestorePoint([int]$rp.SequenceNumber)
        if ($rc -eq 0) {
            Write-Host "Removed old restore point #$($rp.SequenceNumber) ($($rp.Description))"
        } else {
            Write-Warning "Could not remove restore point #$($rp.SequenceNumber) (error $rc)"
        }
    }
}

# ------------------------------------------------------ 2. winget
Invoke-Step -Id 2 -Name 'Update software (winget)' -Action {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw "winget not found. Install 'App Installer' from the Microsoft Store."
    }
    winget source update | Out-Null

    $wingetArgs = @('upgrade', '--all',
                    '--accept-package-agreements', '--accept-source-agreements')
    if ($SilentWinget) {
        $wingetArgs += '--silent'
    } else {
        Write-Host "Installers may show their own windows - check your taskbar if it seems stuck." -ForegroundColor Yellow
    }
    winget @wingetArgs
    # 0 = success, -1978335189 = "no applicable updates found"
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne -1978335189) {
        throw "winget exited with code $LASTEXITCODE (some packages may have failed)"
    }
}

# ------------------------------------------------------ 3. cleanmgr
Invoke-Step -Id 3 -Name 'Disk cleanup (cleanmgr)' -Action {
    $sageId   = 1337
    $flagName = "StateFlags$sageId"
    $cacheKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches'
    # NOT cleaned (wildcard patterns): your Downloads folder, old Windows
    # installations (needed to roll back a major update) and the Windows ESD
    # installation files (needed by "Reset this PC").
    $exclude  = @('Downloads*', 'Previous Installations', '*ESD*')

    # 1. Clean slate: stop cleanmgr instances left over from a cancelled/hung run
    Get-Process -Name cleanmgr -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue

    $categories = @(Get-ChildItem $cacheKey)
    try {
        # 2. Rebuild the cleanup profile from scratch and verify it
        foreach ($c in $categories) {
            Remove-ItemProperty -Path $c.PSPath -Name $flagName -ErrorAction SilentlyContinue
            $isExcluded = @($exclude | Where-Object { $c.PSChildName -like $_ }).Count -gt 0
            if (-not $isExcluded) {
                New-ItemProperty -Path $c.PSPath -Name $flagName `
                    -Value 2 -PropertyType DWord -Force | Out-Null
            }
        }
        $enabled = @($categories | Where-Object {
            (Get-ItemProperty -Path $_.PSPath -Name $flagName -ErrorAction SilentlyContinue).$flagName -eq 2
        })
        Write-Host "$($enabled.Count) cleanup categories enabled."
        $kept = @($categories | Where-Object {
            $n = $_.PSChildName
            @($exclude | Where-Object { $n -like $_ }).Count -gt 0
        } | ForEach-Object { $_.PSChildName })
        Write-Host ("Kept on purpose (not cleaned): {0}" -f ($(if ($kept.Count) { $kept -join ', ' } else { '(none present on this PC)' })))
        if ($enabled.Count -eq 0) { throw "No cleanup categories could be enabled." }

        # 3. Start cleanmgr and keep its windows minimized so they don't pop up
        #    over the console. (Not using "Start-Process -Wait": it also waits
        #    for helper processes cleanmgr leaves behind and can hang forever.)
        if (-not ('Native.WinApi' -as [type])) {
            Add-Type -Namespace Native -Name WinApi -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
'@
        }
        $minimized = @{}
        $started   = Get-Date
        $deadline  = $started.AddMinutes(30)
        $lastNote  = $started

        Write-Host "Running Disk Cleanup (windows are minimized; max 30 min)..."
        Start-Process -FilePath cleanmgr.exe -ArgumentList "/sagerun:$sageId"
        Start-Sleep -Seconds 3

        do {
            $procs = @(Get-Process -Name cleanmgr -ErrorAction SilentlyContinue)
            foreach ($p in $procs) {
                $p.Refresh()
                $h = $p.MainWindowHandle
                if ($h -ne [IntPtr]::Zero -and -not $minimized.ContainsKey([int64]$h)) {
                    [void][Native.WinApi]::ShowWindowAsync($h, 6)   # SW_MINIMIZE
                    $minimized[[int64]$h] = $true
                }
            }
            if ($procs.Count -gt 0) {
                if ((Get-Date) -gt $deadline) {
                    $procs | Stop-Process -Force -ErrorAction SilentlyContinue
                    throw "cleanmgr did not finish within 30 minutes and was stopped."
                }
                if (((Get-Date) - $lastNote).TotalSeconds -ge 60) {
                    Write-Host ("  still cleaning... {0:N0} min elapsed" -f ((Get-Date) - $started).TotalMinutes)
                    $lastNote = Get-Date
                }
                Start-Sleep -Seconds 3
            }
        } while ($procs.Count -gt 0)
        Write-Host "cleanmgr finished."
    } finally {
        # 4. Leave the registry tidy: remove our temporary cleanup profile
        foreach ($c in $categories) {
            Remove-ItemProperty -Path $c.PSPath -Name $flagName -ErrorAction SilentlyContinue
        }
    }
}

# ------------------------------------------------------ 4. Temp, bin, DNS
Invoke-Step -Id 4 -Name 'Temp files, recycle bin, DNS cache' -Action {
    # Safe temp cleanup:
    #  - a file is only removed when BOTH its creation and modification dates
    #    are older than 3 days (extracted/copied files keep old modified dates)
    #  - only folders that really look like temp folders are accepted
    #  - junctions/symlinks are never followed or deleted through
    $cutoff = (Get-Date).AddDays(-3)

    function Test-SafeTempRoot([string]$Path) {
        try { $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\') } catch { return $false }
        if ((Split-Path $full -Leaf) -notin @('Temp', 'Tmp')) { return $false }
        $item = Get-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
        if (-not $item -or -not $item.PSIsContainer) { return $false }
        if (([int]$item.Attributes -band 0x400) -ne 0) { return $false }   # reparse point
        return $true
    }

    # Walks a folder tree by hand so junctions/symlinks are skipped, not followed.
    function Get-TempContents {
        param([string]$Root, [datetime]$Cutoff)
        $files = New-Object System.Collections.Generic.List[System.IO.FileInfo]
        $dirs  = New-Object System.Collections.Generic.List[System.IO.DirectoryInfo]
        $links = 0
        $stack = New-Object System.Collections.Generic.Stack[string]
        $stack.Push($Root)
        while ($stack.Count -gt 0) {
            $current = $stack.Pop()
            try {
                foreach ($item in (New-Object System.IO.DirectoryInfo($current)).EnumerateFileSystemInfos()) {
                    if (([int]$item.Attributes -band 0x400) -ne 0) { $links++; continue }
                    if ($item -is [System.IO.DirectoryInfo]) {
                        $dirs.Add($item)
                        $stack.Push($item.FullName)
                    } else {
                        $newest = if ($item.LastWriteTime -gt $item.CreationTime) { $item.LastWriteTime } else { $item.CreationTime }
                        if ($newest -lt $Cutoff) { $files.Add($item) }
                    }
                }
            } catch { }   # no access / folder vanished: skip it
        }
        [pscustomobject]@{ Files = $files; Dirs = $dirs; Links = $links }
    }

    foreach ($path in @($env:TEMP, "$env:SystemRoot\Temp") | Select-Object -Unique) {
        if (-not $path -or -not (Test-Path -LiteralPath $path)) { continue }
        if (-not (Test-SafeTempRoot $path)) {
            Write-Warning "Skipping '$path': it does not look like a normal temp folder."
            continue
        }

        Write-Host "Scanning $path (files created AND modified more than 3 days ago)..."
        $scan   = Get-TempContents -Root $path -Cutoff $cutoff
        $sizeMB = [math]::Round((($scan.Files | Measure-Object -Property Length -Sum).Sum) / 1MB, 1)
        Write-Host "Deleting $($scan.Files.Count) files ($sizeMB MB)..."
        if ($scan.Links -gt 0) {
            Write-Host "  ($($scan.Links) junction/symlink entries were left untouched)"
        }

        $i = 0; $deleted = 0
        foreach ($f in $scan.Files) {
            try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $deleted++ } catch { }
            $i++
            if ($i % 2000 -eq 0) { Write-Host "  $i / $($scan.Files.Count)" }
        }
        Write-Host "  removed $deleted files; $($scan.Files.Count - $deleted) in use or protected were left alone"

        # Remove old folders that are now empty (deepest first). Delete() without
        # the recursive flag fails on a non-empty folder, so it can't remove content.
        $scan.Dirs |
            Where-Object { $_.CreationTime -lt $cutoff -and $_.LastWriteTime -lt $cutoff } |
            Sort-Object { $_.FullName.Length } -Descending |
            ForEach-Object {
                try { [System.IO.Directory]::Delete($_.FullName, $false) } catch { }
            }
    }

    Write-Host "Emptying recycle bin (can take a few minutes if it's large)..."
    try { Clear-RecycleBin -Force -ErrorAction Stop } catch { Write-Host "Recycle bin already empty." }
    ipconfig /flushdns | Out-Null
    Write-Host "Done."
}

# ------------------------------------------------------ 5. DISM + SFC
Invoke-Step -Id 5 -Name 'System repair (DISM + SFC)' -Action {
    DISM /Online /Cleanup-Image /StartComponentCleanup
    DISM /Online /Cleanup-Image /RestoreHealth
    if ($LASTEXITCODE -ne 0) { throw "DISM RestoreHealth exited with code $LASTEXITCODE" }
    sfc /scannow
}

# ------------------------------------------------------ 6. Defender
Invoke-Step -Id 6 -Name 'Defender update + quick scan' -Action {
    Update-MpSignature -ErrorAction Stop
    Start-MpScan -ScanType QuickScan -ErrorAction Stop
    Write-Host "Quick scan finished."
}

# ------------------------------------------------------ 7. Optimize drives
Invoke-Step -Id 7 -Name 'Optimize drives (TRIM/defrag)' -Action {
    $failed = @()
    Get-Volume | Where-Object {
        $_.DriveLetter -and $_.DriveType -eq 'Fixed' -and $_.FileSystemType -in 'NTFS', 'ReFS'
    } | ForEach-Object {
        $letter = $_.DriveLetter
        Write-Host "Optimizing ${letter}: ..."
        try {
            # Picks TRIM or defrag automatically per media type
            Optimize-Volume -DriveLetter $letter -Verbose -ErrorAction Stop
        } catch {
            Write-Warning "Could not optimize ${letter}: $($_.Exception.Message)"
            $failed += $letter
        }
    }
    if ($failed.Count -gt 0) { throw "Failed on drive(s): $($failed -join ', ')" }
}

# ------------------------------------------------------ 8. Health report
Invoke-Step -Id 8 -Name 'Disk health report' -Action {
    $disks = Get-PhysicalDisk
    $disks | Select-Object FriendlyName, MediaType, HealthStatus, OperationalStatus,
        @{n='SizeGB'; e={[math]::Round($_.Size / 1GB)}} | Format-Table -AutoSize | Out-Host

    Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' } |
        Select-Object DriveLetter, FileSystemLabel,
            @{n='SizeGB'; e={[math]::Round($_.Size / 1GB, 1)}},
            @{n='FreeGB'; e={[math]::Round($_.SizeRemaining / 1GB, 1)}} |
        Format-Table -AutoSize | Out-Host

    $unhealthy = $disks | Where-Object { $_.HealthStatus -ne 'Healthy' }
    if ($unhealthy) {
        throw "Disk health warning: $(($unhealthy | ForEach-Object { $_.FriendlyName }) -join ', ')"
    }
}

# ------------------------------------------------------------------- Summary
$freeAfter = Get-FreeSpaceGB
$elapsed   = (Get-Date) - $startTime

# Append this run's results to the persistent history CSV
$results | Export-Csv -Path $historyFile -Append -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host "================ MAINTENANCE SUMMARY ================" -ForegroundColor Green
$results | Format-Table Step, Status, Duration, Message -AutoSize -Wrap | Out-Host
Write-Host ("Total time : {0:hh\:mm\:ss}" -f $elapsed)
Write-Host ("Space freed: {0:N2} GB" -f ($freeAfter - $freeBefore))
Write-Host "Transcript : $logFile"
Write-Host "History    : $historyFile"

$failedSteps = @($results | Where-Object Status -eq 'Failed')
if ($failedSteps.Count -gt 0) {
    Write-Host "$($failedSteps.Count) step(s) failed - check the log." -ForegroundColor Red
}

$rebootPending = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
                 (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
if ($rebootPending) { Write-Host "A reboot is pending." -ForegroundColor Yellow }

Stop-Transcript | Out-Null

if ($menuShown -and -not $Reboot) {
    Write-Host ""
    Read-Host "Press Enter to close this window" | Out-Null
}

if ($Reboot) {
    Write-Host "Rebooting in 30 seconds (Ctrl+C to cancel)..."
    Start-Sleep -Seconds 30
    Restart-Computer -Force
}
