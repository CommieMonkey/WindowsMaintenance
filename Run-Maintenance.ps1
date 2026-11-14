<#
.SYNOPSIS
    PC Maintenance - automated Windows maintenance with a simple window.

.DESCRIPTION
    Start it without parameters and a window opens: tick the things you want
    to do and press "Start maintenance". Tick "Show advanced options" to get a
    dropdown with settings for every step.

    The steps (all use tools that are built into Windows):
      1. Safety restore point (keeps the last few, removes older ones made by this tool)
      2. Update programs with winget
      3. Free up disk space with Disk Cleanup (cleanmgr)
      4. Clear old temp files, empty the Recycle Bin, flush the DNS cache
      5. Check and repair Windows system files (DISM + SFC)
      6. Update Windows Defender and scan
      7. Optimize drives (TRIM for SSDs, defrag for hard disks)
      8. Disk health report

    On a laptop the charger must be connected.

    Logs go to %USERPROFILE%\MaintenanceLogs:
      - Maintenance_<date>.log   everything that happened during a run
      - MaintenanceHistory.csv   one row per step per run
      - Log files older than 90 days are removed automatically

    Unattended mode (no window): pass -All, -Steps or one of the -Skip switches.
    This is what you want for a scheduled task.

.PARAMETER Steps
    Run only these steps without showing the window. Example: -Steps "1,3,5-6"
.PARAMETER All
    Run every step without showing the window.
.PARAMETER SkipSFC
    Unattended run of everything except step 5.
.PARAMETER SkipDefender
    Unattended run of everything except step 6.
.PARAMETER SkipRestorePoint
    Unattended run of everything except step 1.
.PARAMETER SilentWinget
    Unattended mode: run winget with --silent (no installer windows).
.PARAMETER IgnorePower
    Unattended mode: skip the charger check.
.PARAMETER Reboot
    Unattended mode: restart the PC 30 seconds after finishing.

.EXAMPLE
    .\Run-Maintenance.ps1                    (opens the window)
    .\Run-Maintenance.ps1 -All               (everything, no window)
    .\Run-Maintenance.ps1 -Steps "1,3,5-6"   (only these steps, no window)
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
    $selfPath = (Get-Process -Id $PID).Path
    $argList  = @()
    if ($PSCommandPath) {
        # running as a .ps1: relaunch PowerShell with this file
        $argList += @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    }
    foreach ($key in $PSBoundParameters.Keys) {
        $val = $PSBoundParameters[$key]
        if ($val -is [switch]) {
            if ($val.IsPresent) { $argList += "-$key" }
        } else {
            $argList += "-$key", "`"$val`""
        }
    }
    try {
        $startArgs = @{ FilePath = $selfPath; Verb = 'RunAs' }
        if ($argList.Count -gt 0) { $startArgs.ArgumentList = $argList }
        Start-Process @startArgs
    } catch { }   # UAC prompt was cancelled
    exit
}

$headless = [bool]($All -or $Steps -or $SkipSFC -or $SkipDefender -or $SkipRestorePoint)

# ------------------------------------------------------------- Shared settings
$LogDir      = Join-Path $env:USERPROFILE 'MaintenanceLogs'
$HistoryFile = Join-Path $LogDir 'MaintenanceHistory.csv'
$CancelFile  = Join-Path $env:TEMP 'pc-maintenance-stop.flag'
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null

# Remove old transcripts (keep 90 days). The history CSV is kept.
Get-ChildItem -Path $LogDir -Filter 'Maintenance_*.log' -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-90) } |
    Remove-Item -Force -ErrorAction SilentlyContinue

$script:LogWriter = $null
function Open-RunLog {
    $file = Join-Path $LogDir ("Maintenance_{0:yyyy-MM-dd_HH-mm}.log" -f (Get-Date))
    $script:LogWriter = New-Object System.IO.StreamWriter($file, $true, (New-Object System.Text.UTF8Encoding($false)))
    $script:LogWriter.AutoFlush = $true
    return $file
}
function Write-LogLine([string]$Line) {
    if ($script:LogWriter) { try { $script:LogWriter.WriteLine($Line) } catch { } }
}
function Close-RunLog {
    if ($script:LogWriter) { try { $script:LogWriter.Dispose() } catch { }; $script:LogWriter = $null }
}

# The 8 steps: Name goes into the log/CSV, Title/Desc/Time are shown in the window.
$StepInfo = @(
    @{ Id = 1; Name = 'Restore point';                   Title = 'Create a safety restore point';
       Desc = 'Lets you undo system changes if something goes wrong. Keeps your last restore points and removes older ones made by this tool.'; Time = 'about 1 minute' },
    @{ Id = 2; Name = 'Update software (winget)';        Title = 'Update my programs';
       Desc = 'Installs updates for your installed programs with winget, the update tool built into Windows. Some installers may open their own window.'; Time = '5 to 20 minutes' },
    @{ Id = 3; Name = 'Disk cleanup (cleanmgr)';         Title = 'Free up disk space';
       Desc = 'Runs Windows Disk Cleanup. Your Downloads folder and the files Windows needs to reset itself are never touched.'; Time = '2 to 20 minutes' },
    @{ Id = 4; Name = 'Temp files, recycle bin, DNS';    Title = 'Clear temporary files and empty the Recycle Bin';
       Desc = 'Removes old temporary files and empties the Recycle Bin (this cannot be undone). Also refreshes the network (DNS) cache.'; Time = '1 to 10 minutes' },
    @{ Id = 5; Name = 'System repair (DISM + SFC)';      Title = 'Check and repair Windows system files';
       Desc = 'Scans Windows for damaged files and repairs them. This is the slowest step.'; Time = '10 to 30 minutes' },
    @{ Id = 6; Name = 'Defender update + scan';          Title = 'Update virus definitions and scan';
       Desc = 'Updates Windows Defender and runs a quick virus scan.'; Time = '2 to 10 minutes' },
    @{ Id = 7; Name = 'Optimize drives (TRIM/defrag)';   Title = 'Optimize my drives';
       Desc = 'Keeps SSDs fast (TRIM) and tidies hard disks (defrag). Windows picks the right method for every drive.'; Time = '1 to 30 minutes' },
    @{ Id = 8; Name = 'Disk health report';              Title = 'Check the health of my disks';
       Desc = 'Shows whether your drives report any problems and how much space is left.'; Time = 'under 1 minute' }
)

# Turns marker lines from the engine into readable text (for the log).
function Format-MarkerText([string[]]$P) {
    if ($P[0] -eq '@@STEP') {
        if ($P[2] -eq 'START') { return "=== Step $($P[1]): $($P[3]) ===" }
        $extra = ''
        if ($P.Count -gt 5 -and $P[5]) { $extra = " - $($P[5])" }
        return "--- $($P[3]) after $($P[4])s$extra"
    }
    return ($P -join ' ')
}

# Turns "1,3,5 and 6", "2-4", "a" into a sorted list of step numbers (or $null if invalid).
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

# =============================================================================
#  THE ENGINE
#  Does the actual work. The window and the unattended mode both run this same
#  block. It only talks through text lines: normal lines are log output, and
#  lines starting with "@@" are progress markers:
#     @@STEP|<id>|START|<name>
#     @@STEP|<id>|END|<OK/Failed/Skipped>|<seconds>|<message>
#     @@DONE|<GB freed>|<time>|<failed steps>|<reboot pending>|<stopped>|<aborted>
# =============================================================================
$Engine = {
    param($Opt)

    $RunId     = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $startTime = Get-Date
    $State = @{
        Aborted   = $false
        Cancelled = $false
        PowerOk   = $true
        Results   = New-Object System.Collections.Generic.List[object]
    }

    function Say([string]$Text) { Write-Output $Text }

    function Clean-Msg([string]$Text) {
        return (($Text -replace '[\r\n\|]+', ' ').Trim())
    }

    # Tidies one line of output from a tool (removes progress-bar noise etc.)
    function Convert-ToCleanLine($Item) {
        $s = ([string]$Item) -replace "`0", ''
        if ($s.Contains("`r")) {
            $parts = @($s -split "`r" | Where-Object { $_.Trim() })
            if ($parts.Count -eq 0) { return $null }
            $s = $parts[-1]
        }
        if ($s.Trim() -eq '') { return $null }
        if ($s -match '^[\s\-\\|/]+$') { return $null }
        if ($s -match '[\u2580-\u259F]') { return $null }
        if ($s -match '^\s*[\d\.,]+\s*[KMG]?B\s*/\s*[\d\.,]+\s*[KMG]?B\s*$') { return $null }
        return $s
    }

    function Add-Result([string]$Name, [string]$Status, [string]$Duration, [string]$Message) {
        $State.Results.Add([pscustomobject]@{
            RunId    = $RunId
            Step     = $Name
            Status   = $Status
            Duration = $Duration
            Message  = $Message
        })
    }

    function Get-FreeSpaceGB {
        $sum = (Get-PSDrive -PSProvider FileSystem | Where-Object { $null -ne $_.Used } |
                Measure-Object -Property Free -Sum).Sum
        return [double]($sum / 1GB)
    }

    # Desktops (no battery) always pass. On a laptop the charger must be connected.
    function Test-ACPower {
        if ($Opt.IgnorePower) { return $true }
        try {
            Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
            $pw = [System.Windows.Forms.SystemInformation]::PowerStatus
            if ([int]$pw.BatteryChargeStatus -eq 128) { return $true }
            return ($pw.PowerLineStatus -ne 'Offline')
        } catch {
            return $true
        }
    }

    function Wait-ForACPower {
        $State.PowerOk = $true
        if (Test-ACPower) { return }
        Say ""
        Say "!! Your laptop is running on battery. Please connect the charger to continue."
        Say "   (waiting up to 10 minutes)"
        $deadline = (Get-Date).AddMinutes(10)
        while (-not (Test-ACPower)) {
            if ((Get-Date) -gt $deadline) { $State.PowerOk = $false; return }
            Start-Sleep -Seconds 3
        }
        Say "Charger connected - continuing."
    }

    function Invoke-Step {
        param([int]$Id, [string]$Name, [scriptblock]$Action)

        if (@($Opt.Steps) -notcontains $Id) {
            Add-Result $Name 'Skipped' '00:00:00' 'Not selected'
            return
        }
        if (-not $State.Cancelled -and $Opt.CancelFile -and (Test-Path -LiteralPath $Opt.CancelFile)) {
            $State.Cancelled = $true
            Say "Stop requested - the remaining steps will be skipped."
        }
        if ($State.Cancelled) {
            Add-Result $Name 'Skipped' '00:00:00' 'Stopped by user'
            Say "@@STEP|$Id|END|Skipped|0|Stopped by user"
            return
        }
        if ($State.Aborted) {
            Add-Result $Name 'Skipped' '00:00:00' 'Aborted: charger was disconnected'
            Say "@@STEP|$Id|END|Skipped|0|Charger was disconnected"
            return
        }

        Wait-ForACPower
        if (-not $State.PowerOk) {
            $State.Aborted = $true
            Say "!! Charger not connected - skipping this and all remaining steps."
            Add-Result $Name 'Failed' '00:00:00' 'Charger not connected - step not run'
            Say "@@STEP|$Id|END|Failed|0|Charger not connected"
            return
        }

        Say "@@STEP|$Id|START|$Name"
        $sw      = [Diagnostics.Stopwatch]::StartNew()
        $status  = 'OK'
        $message = ''
        try {
            & $Action *>&1 | ForEach-Object {
                $line = Convert-ToCleanLine $_
                if ($null -ne $line) { $line }
            }
        } catch {
            $status  = 'Failed'
            $message = $_.Exception.Message
            Say "ERROR: $message"
        }
        $sw.Stop()
        Add-Result $Name $status ($sw.Elapsed.ToString('hh\:mm\:ss')) $message
        Say ("@@STEP|{0}|END|{1}|{2}|{3}" -f $Id, $status, [int]$sw.Elapsed.TotalSeconds, (Clean-Msg $message))
    }

    $freeBefore = Get-FreeSpaceGB
    Say ("Selected steps: {0}" -f (@($Opt.Steps) -join ', '))

    # ---------------------------------------------------- 1. Restore point
    Invoke-Step -Id 1 -Name $Opt.StepNames[0] -Action {
        # Native API used to delete a single restore point by sequence number
        if (-not ('Native.SysRestore' -as [type])) {
            Add-Type -Namespace Native -Name SysRestore -MemberDefinition @'
[DllImport("srclient.dll")]
public static extern int SRRemoveRestorePoint(int dwRPNum);
'@
        }

        $prefix    = 'Before maintenance'
        $keepTotal = [math]::Max(1, [int]$Opt.KeepRestorePoints)
        $old = @(Get-ComputerRestorePoint -ErrorAction SilentlyContinue |
                 Where-Object { $_.Description -like "$prefix*" })
        Say "Found $($old.Count) restore point(s) from previous runs."

        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop

        # Windows normally allows only one restore point per 24h; lift that
        # limit temporarily so repeat runs work, then restore it.
        $srKey   = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
        $srName  = 'SystemRestorePointCreationFrequency'
        $oldFreq = (Get-ItemProperty -Path $srKey -Name $srName -ErrorAction SilentlyContinue).$srName
        New-ItemProperty -Path $srKey -Name $srName -Value 0 -PropertyType DWord -Force | Out-Null
        try {
            Checkpoint-Computer -Description "$prefix $(Get-Date -Format 'yyyy-MM-dd HH:mm')" `
                -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
            Say "New restore point created."
        } finally {
            if ($null -eq $oldFreq) {
                Remove-ItemProperty -Path $srKey -Name $srName -ErrorAction SilentlyContinue
            } else {
                Set-ItemProperty -Path $srKey -Name $srName -Value $oldFreq
            }
        }

        # Only reached if the new restore point was created successfully.
        $toRemove = @($old | Sort-Object { [int]$_.SequenceNumber } -Descending |
                      Select-Object -Skip ($keepTotal - 1))
        Say "Keeping $($keepTotal - 1) previous restore point(s), removing $($toRemove.Count)."
        foreach ($rp in $toRemove) {
            $rc = [Native.SysRestore]::SRRemoveRestorePoint([int]$rp.SequenceNumber)
            if ($rc -eq 0) {
                Say "Removed old restore point #$($rp.SequenceNumber) ($($rp.Description))"
            } else {
                Say "WARNING: could not remove restore point #$($rp.SequenceNumber) (error $rc)"
            }
        }
    }

    # ---------------------------------------------------- 2. winget
    Invoke-Step -Id 2 -Name $Opt.StepNames[1] -Action {
        if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
            throw "winget not found. Install 'App Installer' from the Microsoft Store."
        }
        winget source update | Out-Null

        $wingetArgs = @('upgrade', '--all',
                        '--accept-package-agreements', '--accept-source-agreements')
        if ($Opt.WingetSilent) {
            $wingetArgs += '--silent'
        } else {
            Say "Installers may show their own windows - check your taskbar if it seems stuck."
        }
        winget @wingetArgs
        # 0 = success, -1978335189 = "no applicable updates found"
        if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne -1978335189) {
            throw "winget exited with code $LASTEXITCODE (some packages may have failed)"
        }
    }

    # ---------------------------------------------------- 3. cleanmgr
    Invoke-Step -Id 3 -Name $Opt.StepNames[2] -Action {
        $sageId   = 1337
        $flagName = "StateFlags$sageId"
        $cacheKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches'

        # NOT cleaned (wildcard patterns): your Downloads folder, old Windows
        # installations (needed to roll back a major update) and the Windows ESD
        # installation files (needed by "Reset this PC").
        $exclude = @('Downloads*', 'Previous Installations', '*ESD*')
        if ($Opt.CleanStrength -eq 'Gentle') { $exclude += @('Device Driver*', '*dump*', '*Recycle*') }
        if (-not $Opt.EmptyRecycleBin)       { $exclude += '*Recycle*' }

        # Clean slate: stop cleanmgr instances left over from a cancelled/hung run
        Get-Process -Name cleanmgr -ErrorAction SilentlyContinue |
            Stop-Process -Force -ErrorAction SilentlyContinue

        $categories = @(Get-ChildItem $cacheKey)
        try {
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
            Say "$($enabled.Count) cleanup categories enabled."
            $kept = @($categories | Where-Object {
                $n = $_.PSChildName
                @($exclude | Where-Object { $n -like $_ }).Count -gt 0
            } | ForEach-Object { $_.PSChildName })
            if ($kept.Count -gt 0) { Say ("Kept on purpose (not cleaned): " + ($kept -join ', ')) }
            if ($enabled.Count -eq 0) { throw "No cleanup categories could be enabled." }

            # Start cleanmgr and keep its windows minimized so they don't get in the way.
            # (Not using "Start-Process -Wait": it also waits for helper processes
            # cleanmgr leaves behind and can hang forever.)
            if (-not ('Native.WinApi' -as [type])) {
                Add-Type -Namespace Native -Name WinApi -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
'@
            }
            $minimized = @{}
            $started   = Get-Date
            $deadline  = $started.AddMinutes(30)
            $lastNote  = $started

            Say "Running Disk Cleanup (its windows are minimized; maximum 30 minutes)..."
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
                        Say ("  still cleaning... {0:N0} min elapsed" -f ((Get-Date) - $started).TotalMinutes)
                        $lastNote = Get-Date
                    }
                    Start-Sleep -Seconds 3
                }
            } while ($procs.Count -gt 0)
            Say "Disk Cleanup finished."
        } finally {
            # Leave the registry tidy: remove our temporary cleanup profile
            foreach ($c in $categories) {
                Remove-ItemProperty -Path $c.PSPath -Name $flagName -ErrorAction SilentlyContinue
            }
        }
    }

    # ---------------------------------------------------- 4. Temp, bin, DNS
    Invoke-Step -Id 4 -Name $Opt.StepNames[3] -Action {
        # Safe temp cleanup:
        #  - a file is only removed when BOTH its creation and modification dates
        #    are older than the chosen number of days
        #  - only folders that really look like temp folders are accepted
        #  - junctions/symlinks are never followed or deleted through
        $days   = [math]::Max(1, [int]$Opt.TempDays)
        $cutoff = (Get-Date).AddDays(-$days)

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
                Say "WARNING: skipping '$path' - it does not look like a normal temp folder."
                continue
            }

            Say "Scanning $path (files created AND modified more than $days day(s) ago)..."
            $scan   = Get-TempContents -Root $path -Cutoff $cutoff
            $sizeMB = [math]::Round((($scan.Files | Measure-Object -Property Length -Sum).Sum) / 1MB, 1)
            Say "Deleting $($scan.Files.Count) files ($sizeMB MB)..."
            if ($scan.Links -gt 0) {
                Say "  ($($scan.Links) junction/symlink entries were left untouched)"
            }

            $i = 0; $deleted = 0
            foreach ($f in $scan.Files) {
                try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $deleted++ } catch { }
                $i++
                if ($i % 2000 -eq 0) { Say "  $i / $($scan.Files.Count)" }
            }
            Say "  removed $deleted files; $($scan.Files.Count - $deleted) in use or protected were left alone"

            # Remove old folders that are now empty (deepest first). Delete() without
            # the recursive flag fails on a non-empty folder, so it can't remove content.
            $scan.Dirs |
                Where-Object { $_.CreationTime -lt $cutoff -and $_.LastWriteTime -lt $cutoff } |
                Sort-Object { $_.FullName.Length } -Descending |
                ForEach-Object {
                    try { [System.IO.Directory]::Delete($_.FullName, $false) } catch { }
                }
        }

        if ($Opt.EmptyRecycleBin) {
            Say "Emptying the Recycle Bin (can take a few minutes if it is large)..."
            try { Clear-RecycleBin -Force -ErrorAction Stop } catch { Say "Recycle Bin was already empty." }
        } else {
            Say "Recycle Bin left alone (your choice)."
        }
        ipconfig /flushdns | Out-Null
        Say "DNS cache flushed."
    }

    # ---------------------------------------------------- 5. DISM + SFC
    Invoke-Step -Id 5 -Name $Opt.StepNames[4] -Action {
        $mode = [string]$Opt.RepairMode
        if ($mode -ne 'SfcOnly') {
            Say "Running DISM (this can take a while)..."
            DISM /Online /Cleanup-Image /StartComponentCleanup
            DISM /Online /Cleanup-Image /RestoreHealth
            if ($LASTEXITCODE -ne 0) { throw "DISM RestoreHealth exited with code $LASTEXITCODE" }
        }
        if ($mode -ne 'DismOnly') {
            Say "Running System File Checker (no live progress is shown here - please wait)..."
            sfc /scannow
        }
    }

    # ---------------------------------------------------- 6. Defender
    Invoke-Step -Id 6 -Name $Opt.StepNames[5] -Action {
        Update-MpSignature -ErrorAction Stop
        Say "Virus definitions updated."
        switch ([string]$Opt.DefenderMode) {
            'Quick' { Say "Running a quick scan..."; Start-MpScan -ScanType QuickScan -ErrorAction Stop; Say "Quick scan finished." }
            'Full'  { Say "Running a full scan (this can take hours)..."; Start-MpScan -ScanType FullScan -ErrorAction Stop; Say "Full scan finished." }
            default { Say "Scan skipped (update only)." }
        }
    }

    # ---------------------------------------------------- 7. Optimize drives
    Invoke-Step -Id 7 -Name $Opt.StepNames[6] -Action {
        $failed = @()
        $vols = @(Get-Volume | Where-Object {
            $_.DriveLetter -and $_.DriveType -eq 'Fixed' -and $_.FileSystemType -in 'NTFS', 'ReFS'
        })
        if ([string]$Opt.OptimizeDrive -ne 'All') {
            $vols = @($vols | Where-Object { "$($_.DriveLetter)" -eq [string]$Opt.OptimizeDrive })
        }
        if ($vols.Count -eq 0) { Say "No matching drives found." }
        foreach ($v in $vols) {
            $letter = $v.DriveLetter
            Say "Optimizing ${letter}: ..."
            try {
                # Picks TRIM or defrag automatically per media type
                Optimize-Volume -DriveLetter $letter -Verbose -ErrorAction Stop
            } catch {
                Say "WARNING: could not optimize ${letter}: $($_.Exception.Message)"
                $failed += $letter
            }
        }
        if ($failed.Count -gt 0) { throw "Failed on drive(s): $($failed -join ', ')" }
    }

    # ---------------------------------------------------- 8. Health report
    Invoke-Step -Id 8 -Name $Opt.StepNames[7] -Action {
        $disks = @(Get-PhysicalDisk)
        $disks | Select-Object FriendlyName, MediaType, HealthStatus, OperationalStatus,
            @{ n = 'SizeGB'; e = { [math]::Round($_.Size / 1GB) } } |
            Format-Table -AutoSize | Out-String -Width 150 -Stream

        Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' } |
            Select-Object DriveLetter, FileSystemLabel,
                @{ n = 'SizeGB'; e = { [math]::Round($_.Size / 1GB, 1) } },
                @{ n = 'FreeGB'; e = { [math]::Round($_.SizeRemaining / 1GB, 1) } } |
            Format-Table -AutoSize | Out-String -Width 150 -Stream

        $unhealthy = @($disks | Where-Object { $_.HealthStatus -ne 'Healthy' })
        if ($unhealthy.Count -gt 0) {
            throw "Disk health warning: $(($unhealthy | ForEach-Object { $_.FriendlyName }) -join ', ')"
        }
    }

    # ---------------------------------------------------- Summary
    $freed   = (Get-FreeSpaceGB) - $freeBefore
    $elapsed = (Get-Date) - $startTime
    $elapsedText = $elapsed.ToString('hh\:mm\:ss')

    try {
        New-Item -ItemType Directory -Path (Split-Path $Opt.HistoryFile) -Force | Out-Null
        $State.Results | Export-Csv -Path $Opt.HistoryFile -Append -NoTypeInformation -Encoding UTF8
    } catch {
        Say "WARNING: could not write the history file: $($_.Exception.Message)"
    }

    Say ""
    Say "================ SUMMARY ================"
    foreach ($r in $State.Results) {
        if ($r.Message -ne 'Not selected') {
            Say ("{0,-38} {1,-8} {2}  {3}" -f $r.Step, $r.Status, $r.Duration, $r.Message)
        }
    }
    Say ("Total time : {0}" -f $elapsedText)
    Say ("Space freed: {0:N2} GB" -f $freed)

    $failedCount   = @($State.Results | Where-Object { $_.Status -eq 'Failed' }).Count
    $rebootPending = [bool]((Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
                            (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'))
    Say ("@@DONE|{0:N2}|{1}|{2}|{3}|{4}|{5}" -f $freed, $elapsedText, $failedCount, $rebootPending, $State.Cancelled, $State.Aborted)
}

# =============================================================================
#  UNATTENDED MODE (no window): -All, -Steps, -Skip...
# =============================================================================
if ($headless) {
    # Turn off console QuickEdit so clicking in the window can't pause the run
    try {
        Add-Type -Namespace Native -Name ConsoleMode -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int nStdHandle);
[DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
[DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
'@
        $hIn = [Native.ConsoleMode]::GetStdHandle(-10)
        [uint32]$consoleMode = 0
        if ([Native.ConsoleMode]::GetConsoleMode($hIn, [ref]$consoleMode)) {
            $newMode = [uint32](($consoleMode -band ([uint32]::MaxValue - 0x40)) -bor 0x80)
            [void][Native.ConsoleMode]::SetConsoleMode($hIn, $newMode)
        }
    } catch { }

    $maxStep = $StepInfo.Count
    $skipped = @()
    if ($SkipRestorePoint) { $skipped += 1 }
    if ($SkipSFC)          { $skipped += 5 }
    if ($SkipDefender)     { $skipped += 6 }

    if ($Steps) {
        $selected = Resolve-StepSelection $Steps $maxStep
        if (-not $selected) {
            Write-Host "Invalid -Steps value '$Steps'. Use numbers 1-$maxStep, e.g. -Steps `"1,3,5-6`"." -ForegroundColor Red
            Start-Sleep -Seconds 5
            exit 1
        }
    } else {
        $selected = @(1..$maxStep)
    }
    $selected = @($selected | Where-Object { $skipped -notcontains $_ })
    if ($selected.Count -eq 0) {
        Write-Host "Nothing to do." -ForegroundColor Yellow
        exit
    }

    Remove-Item -LiteralPath $CancelFile -Force -ErrorAction SilentlyContinue
    $runOpt = @{
        Steps             = [int[]]$selected
        StepNames         = @($StepInfo | ForEach-Object { $_.Name })
        KeepRestorePoints = 2
        WingetSilent      = [bool]$SilentWinget
        CleanStrength     = 'Standard'
        TempDays          = 3
        EmptyRecycleBin   = $true
        RepairMode        = 'Both'
        DefenderMode      = 'Quick'
        OptimizeDrive     = 'All'
        IgnorePower       = [bool]$IgnorePower
        HistoryFile       = $HistoryFile
        CancelFile        = $CancelFile
    }

    $logFile = Open-RunLog
    $script:DoneInfo = $null
    Write-Host "PC Maintenance - log file: $logFile"
    try {
        & $Engine $runOpt | ForEach-Object {
            $line = [string]$_
            if ($line.StartsWith('@@')) {
                $p = $line.Split('|')
                if ($p[0] -eq '@@DONE') { $script:DoneInfo = $p; return }
                $text = Format-MarkerText $p
                Write-LogLine $text
                if ($p[2] -eq 'START') {
                    Write-Host ""
                    Write-Host $text -ForegroundColor Cyan
                } elseif ($p[3] -eq 'Failed') {
                    Write-Host $text -ForegroundColor Red
                } else {
                    Write-Host $text -ForegroundColor Green
                }
            } else {
                Write-LogLine $line
                Write-Host $line
            }
        }
    } finally {
        Close-RunLog
    }

    $exitCode = 0
    if ($script:DoneInfo) {
        if ($script:DoneInfo[6] -eq 'True') { $exitCode = 1 }
        if ($script:DoneInfo[4] -eq 'True') { Write-Host "A reboot is pending." -ForegroundColor Yellow }
    }
    if ($Reboot -and $exitCode -eq 0) {
        Write-Host "Restarting in 30 seconds (run 'shutdown /a' to cancel)..."
        & shutdown.exe /r /t 30 /c "PC Maintenance finished - restarting"
    }
    exit $exitCode
}

# =============================================================================
#  THE WINDOW
# =============================================================================
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Hide the black console window while the GUI is open (restored at the end)
Add-Type -Namespace Native -Name ConWin -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@
$script:ConsoleHwnd = [Native.ConWin]::GetConsoleWindow()
if ($script:ConsoleHwnd -ne [IntPtr]::Zero) { [void][Native.ConWin]::ShowWindow($script:ConsoleHwnd, 0) }

try {
    [System.Windows.Forms.Application]::EnableVisualStyles()
    try { [System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false) } catch { }

    # ----- look and feel
    $script:FontNormal = New-Object System.Drawing.Font('Segoe UI', 10)
    $script:FontBold   = New-Object System.Drawing.Font('Segoe UI Semibold', 10.5)
    $script:FontTitle  = New-Object System.Drawing.Font('Segoe UI Semibold', 20)
    $script:FontSmall  = New-Object System.Drawing.Font('Segoe UI', 9)
    $script:FontMono   = New-Object System.Drawing.Font('Consolas', 9)
    $script:ColText    = [System.Drawing.Color]::FromArgb(33, 37, 41)
    $script:ColMuted   = [System.Drawing.Color]::FromArgb(100, 108, 117)
    $script:ColCard    = [System.Drawing.Color]::FromArgb(243, 246, 250)
    $script:ColGreen   = [System.Drawing.Color]::FromArgb(30, 140, 60)
    $script:ColRed     = [System.Drawing.Color]::FromArgb(200, 40, 40)
    $script:ColAmber   = [System.Drawing.Color]::FromArgb(200, 120, 0)
    $script:ColBlue    = [System.Drawing.Color]::FromArgb(0, 100, 200)

    # ----- dropdown settings per step (shown in "advanced options")
    $driveItems  = @('All drives (recommended)')
    $driveValues = @('All')
    try {
        $fixedVols = @(Get-Volume | Where-Object {
            $_.DriveLetter -and $_.DriveType -eq 'Fixed' -and $_.FileSystemType -in 'NTFS', 'ReFS'
        } | Sort-Object DriveLetter)
        foreach ($v in $fixedVols) {
            $driveItems  += "Only drive $($v.DriveLetter):"
            $driveValues += [string]$v.DriveLetter
        }
    } catch { }

    $script:StepOptions = @{
        1 = @( @{ Key = 'KeepRestorePoints'; Label = 'Restore points to keep:';
                  Items = @('1', '2 (recommended)', '3', '4', '5'); Values = @(1, 2, 3, 4, 5); Default = 1 } )
        2 = @( @{ Key = 'WingetSilent'; Label = 'Installer windows:';
                  Items = @('Show them if an installer needs one (recommended)', 'Never show them (silent)'); Values = @($false, $true); Default = 0 } )
        3 = @( @{ Key = 'CleanStrength'; Label = 'Cleanup strength:';
                  Items = @('Standard (recommended)', 'Gentle (also keeps old driver packages and crash dumps)'); Values = @('Standard', 'Gentle'); Default = 0 } )
        4 = @( @{ Key = 'TempDays'; Label = 'Delete temp files older than:';
                  Items = @('1 day', '3 days (recommended)', '7 days', '30 days'); Values = @(1, 3, 7, 30); Default = 1 },
               @{ Key = 'EmptyRecycleBin'; Label = 'Recycle Bin (also applies to step 3):';
                  Items = @('Empty it (default)', 'Leave it alone'); Values = @($true, $false); Default = 0 } )
        5 = @( @{ Key = 'RepairMode'; Label = 'What to run:';
                  Items = @('Full repair: DISM + SFC (recommended)', 'SFC only (faster)', 'DISM only'); Values = @('Both', 'SfcOnly', 'DismOnly'); Default = 0 } )
        6 = @( @{ Key = 'DefenderMode'; Label = 'Scan type:';
                  Items = @('Quick scan (recommended)', 'Update definitions only', 'Full scan (can take hours)'); Values = @('Quick', 'UpdateOnly', 'Full'); Default = 0 } )
        7 = @( @{ Key = 'OptimizeDrive'; Label = 'Which drives:';
                  Items = $driveItems; Values = $driveValues; Default = 0 } )
        8 = @()
    }

    $script:StepCtl   = @{}     # step id -> controls
    $script:StepTitle = @{}
    $script:StepTime  = @{}
    foreach ($si in $StepInfo) {
        $script:StepTitle[[int]$si.Id] = $si.Title
        $script:StepTime[[int]$si.Id]  = $si.Time
    }
    $script:Run = $null

    # ----- small helpers
    function Show-Message([string]$Text, [string]$Caption, $Buttons, $Icon) {
        return [System.Windows.Forms.MessageBox]::Show($Text, $Caption, $Buttons, $Icon)
    }

    function Get-PowerState {
        try {
            $pw = [System.Windows.Forms.SystemInformation]::PowerStatus
            if ([int]$pw.BatteryChargeStatus -eq 128) { return 'Desktop' }
            if ($pw.PowerLineStatus -eq 'Online')  { return 'Plugged' }
            if ($pw.PowerLineStatus -eq 'Offline') { return 'Battery' }
        } catch { }
        return 'Unknown'
    }

    function Update-PowerLabel {
        switch (Get-PowerState) {
            'Plugged' { $script:UI.lblPower.Text = 'Power: charger connected.';                      $script:UI.lblPower.ForeColor = $script:ColGreen }
            'Battery' { $script:UI.lblPower.Text = 'Power: your laptop is on battery. Please connect the charger before you start.'; $script:UI.lblPower.ForeColor = $script:ColRed }
            'Desktop' { $script:UI.lblPower.Text = 'Power: desktop PC (no battery found).';          $script:UI.lblPower.ForeColor = $script:ColMuted }
            default   { $script:UI.lblPower.Text = '';                                                 $script:UI.lblPower.ForeColor = $script:ColMuted }
        }
    }

    function New-StepCard($Info) {
        $id = [int]$Info.Id

        $card = New-Object System.Windows.Forms.FlowLayoutPanel
        $card.FlowDirection = 'TopDown'
        $card.WrapContents  = $false
        $card.AutoSize      = $true
        $card.AutoSizeMode  = 'GrowAndShrink'
        $card.MinimumSize   = New-Object System.Drawing.Size(748, 0)
        $card.MaximumSize   = New-Object System.Drawing.Size(748, 0)
        $card.Margin        = New-Object System.Windows.Forms.Padding(0, 0, 0, 8)
        $card.Padding       = New-Object System.Windows.Forms.Padding(10, 8, 10, 8)
        $card.BackColor     = $script:ColCard

        $chk = New-Object System.Windows.Forms.CheckBox
        $chk.AutoSize = $true
        $chk.Checked  = $true
        $chk.Font     = $script:FontBold
        $chk.Text     = ("{0}.  {1}" -f $Info.Id, $Info.Title)
        $chk.Margin   = New-Object System.Windows.Forms.Padding(0)
        $card.Controls.Add($chk)

        $desc = New-Object System.Windows.Forms.Label
        $desc.AutoSize    = $true
        $desc.MaximumSize = New-Object System.Drawing.Size(700, 0)
        $desc.Font        = $script:FontSmall
        $desc.ForeColor   = $script:ColMuted
        $desc.Margin      = New-Object System.Windows.Forms.Padding(22, 2, 0, 0)
        $desc.Text        = ("{0}  Takes {1}." -f $Info.Desc, $Info.Time)
        $card.Controls.Add($desc)

        $optPanel = $null
        $combos   = @()
        $defs     = @($script:StepOptions[$id])
        if ($defs.Count -gt 0) {
            $optPanel = New-Object System.Windows.Forms.FlowLayoutPanel
            $optPanel.FlowDirection = 'LeftToRight'
            $optPanel.WrapContents  = $true
            $optPanel.AutoSize      = $true
            $optPanel.AutoSizeMode  = 'GrowAndShrink'
            $optPanel.MaximumSize   = New-Object System.Drawing.Size(710, 0)
            $optPanel.Margin        = New-Object System.Windows.Forms.Padding(22, 6, 0, 0)
            $optPanel.Visible       = $false

            foreach ($d in $defs) {
                $lbl = New-Object System.Windows.Forms.Label
                $lbl.AutoSize  = $true
                $lbl.Text      = $d.Label
                $lbl.Font      = $script:FontSmall
                $lbl.Margin    = New-Object System.Windows.Forms.Padding(0, 6, 6, 0)
                $optPanel.Controls.Add($lbl)

                $combo = New-Object System.Windows.Forms.ComboBox
                $combo.DropDownStyle = 'DropDownList'
                $combo.Width  = 330
                $combo.Font   = $script:FontSmall
                $combo.Margin = New-Object System.Windows.Forms.Padding(0, 2, 18, 4)
                foreach ($itemText in $d.Items) { [void]$combo.Items.Add($itemText) }
                $combo.SelectedIndex = [int]$d.Default
                $combo.Tag = @{ Key = $d.Key; Values = $d.Values }
                $optPanel.Controls.Add($combo)
                $combos += $combo
            }
            $card.Controls.Add($optPanel)
        }

        $script:StepCtl[$id] = @{ Check = $chk; Options = $optPanel; Combos = $combos }
        $chk.Tag = @{ Options = $optPanel }
        $chk.Add_CheckedChanged({
            param($sender, $e)
            if ($sender.Tag.Options) { $sender.Tag.Options.Enabled = $sender.Checked }
        })
        return $card
    }

    # Reads the window and builds the settings for the engine
    function Get-RunOptions {
        $ids = @($script:StepCtl.Keys | Where-Object { $script:StepCtl[$_].Check.Checked } |
                 Sort-Object | ForEach-Object { [int]$_ })
        $o = @{
            Steps             = [int[]]$ids
            StepNames         = @($StepInfo | ForEach-Object { $_.Name })
            KeepRestorePoints = 2
            WingetSilent      = $false
            CleanStrength     = 'Standard'
            TempDays          = 3
            EmptyRecycleBin   = $true
            RepairMode        = 'Both'
            DefenderMode      = 'Quick'
            OptimizeDrive     = 'All'
            IgnorePower       = $false
            Reboot            = $false
            HistoryFile       = $HistoryFile
            CancelFile        = $CancelFile
        }
        # Dropdown choices only count while "Show advanced options" is ticked
        if ($script:UI.chkAdv.Checked) {
            foreach ($sid in $script:StepCtl.Keys) {
                foreach ($combo in $script:StepCtl[$sid].Combos) {
                    $o[$combo.Tag.Key] = $combo.Tag.Values[$combo.SelectedIndex]
                }
            }
            $o.IgnorePower = [bool]($script:UI.cmbCharger.SelectedIndex -eq 1)
            $o.Reboot      = [bool]($script:UI.cmbFinish.SelectedIndex -eq 1)
        }
        return $o
    }

    # ----- the engine's messages arrive here while a run is active
    function Add-LogText([string]$Text) {
        Write-LogLine $Text
        $script:UI.txtLog.AppendText($Text + "`r`n")
    }

    function Set-ItemStatus($Item, [string]$Text, $Color) {
        if (-not $Item) { return }
        $Item.SubItems[1].Text = $Text
        $Item.ForeColor = $Color
    }

    function Handle-EngineLine([string]$Line) {
        if (-not $Line.StartsWith('@@')) { Add-LogText $Line; return }

        $p = $Line.Split('|')
        if ($p[0] -eq '@@STEP') {
            $id   = [int]$p[1]
            $item = $script:Run.Items[$id]
            if ($p[2] -eq 'START') {
                Set-ItemStatus $item 'Running...' $script:ColBlue
                if ($item) { $item.EnsureVisible() }
                $script:UI.lblNow.Text = "Now: " + $script:StepTitle[$id] + "   (usually " + $script:StepTime[$id] + ")"
                $script:Run.Current = $id
            } else {
                switch ($p[3]) {
                    'OK'      { Set-ItemStatus $item 'Done'    $script:ColGreen }
                    'Failed'  { Set-ItemStatus $item 'Failed'  $script:ColRed }
                    default   { Set-ItemStatus $item 'Skipped' $script:ColMuted }
                }
                if ($item) { $item.SubItems[2].Text = ("{0}s" -f $p[4]) }
                $script:Run.Finished++
                $script:UI.pbOverall.Value = [math]::Min($script:UI.pbOverall.Maximum, $script:Run.Finished)
            }
            Add-LogText (Format-MarkerText $p)
        } elseif ($p[0] -eq '@@DONE') {
            $script:Run.Done = $p
        }
    }

    function Poll-Run {
        $r = $script:Run
        if (-not $r) { return }
        $finished = $r.Handle.IsCompleted
        try {
            $count = $r.Out.Count
            while ($r.Read -lt $count) {
                $item = $r.Out[$r.Read]
                $r.Read++
                Handle-EngineLine ([string]$item)
            }
        } catch {
            try { Add-LogText ("ERROR while reading progress: " + $_.Exception.Message) } catch { }
        }
        if ($finished) { Complete-Run }
    }

    function Complete-Run {
        $script:Timer.Stop()
        $r = $script:Run
        try {
            $leftover = @($r.PS.EndInvoke($r.Handle))
            foreach ($x in $leftover) { Handle-EngineLine ([string]$x) }
        } catch { Add-LogText ("ERROR: " + $_.Exception.Message) }
        foreach ($err in $r.PS.Streams.Error) { Add-LogText ("ERROR: " + $err.ToString()) }
        try { $r.PS.Dispose(); $r.RS.Close(); $r.RS.Dispose() } catch { }
        Close-RunLog
        Remove-Item -LiteralPath $CancelFile -Force -ErrorAction SilentlyContinue
        $r.Active = $false

        $script:UI.pbActivity.Visible = $false
        $script:UI.btnStop.Visible    = $false
        $script:UI.btnBack.Enabled    = $true
        $script:UI.btnLogs.Enabled    = $true
        $script:UI.btnClose.Enabled   = $true
        $script:UI.lblNow.Text        = ''

        $d = $r.Done
        if (-not $d) {
            $script:UI.lblTitle.Text      = 'Something went wrong'
            $script:UI.lblTitle.ForeColor = $script:ColRed
            $script:UI.lblSummary.Text    = 'The maintenance did not finish properly. Tick "Show technical details" to see what happened.'
            $script:UI.chkDetails.Checked = $true
            return
        }

        $failed = [int]$d[3]
        if ($d[6] -eq 'True') {
            $script:UI.lblTitle.Text = 'Stopped: charger not connected'; $script:UI.lblTitle.ForeColor = $script:ColRed
        } elseif ($d[5] -eq 'True') {
            $script:UI.lblTitle.Text = 'Stopped as requested'; $script:UI.lblTitle.ForeColor = $script:ColAmber
        } elseif ($failed -gt 0) {
            $script:UI.lblTitle.Text = 'Finished, but some steps had problems'; $script:UI.lblTitle.ForeColor = $script:ColAmber
        } else {
            $script:UI.lblTitle.Text = 'All done!'; $script:UI.lblTitle.ForeColor = $script:ColGreen
        }
        $text = "Space freed: $($d[1]) GB      Time taken: $($d[2])"
        if ($failed -gt 0) { $text += "`r`n$failed step(s) failed - tick 'Show technical details' to see why." }
        if ($d[4] -eq 'True') { $text += "`r`nWindows would like a restart to finish some changes." }
        $script:UI.lblSummary.Text = $text

        if ($r.Opt.Reboot -and $d[5] -ne 'True' -and $d[6] -ne 'True') {
            & shutdown.exe /r /t 60 /c "PC Maintenance finished - restarting"
            $restartMsg = "Maintenance is finished. Your PC will restart in 60 seconds.`r`n`r`nDo you want to cancel the restart?"
            $answer = Show-Message $restartMsg 'Restarting soon' ([System.Windows.Forms.MessageBoxButtons]::YesNo) ([System.Windows.Forms.MessageBoxIcon]::Question)
            if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) { & shutdown.exe /a }
        }
    }

    function Start-Run {
        $o = Get-RunOptions

        Remove-Item -LiteralPath $CancelFile -Force -ErrorAction SilentlyContinue
        [void](Open-RunLog)

        # switch to the progress view
        $script:UI.lvSteps.Items.Clear()
        $script:UI.txtLog.Clear()
        $items = @{}
        foreach ($si in $StepInfo) {
            if ($o.Steps -contains [int]$si.Id) {
                $li = New-Object System.Windows.Forms.ListViewItem($si.Title)
                [void]$li.SubItems.Add('Waiting')
                [void]$li.SubItems.Add('')
                $li.ForeColor = $script:ColMuted
                [void]$script:UI.lvSteps.Items.Add($li)
                $items[[int]$si.Id] = $li
            }
        }
        $script:UI.pbOverall.Minimum = 0
        $script:UI.pbOverall.Maximum = [math]::Max(1, $o.Steps.Count)
        $script:UI.pbOverall.Value   = 0
        $script:UI.pbActivity.Visible = $true
        $script:UI.lblTitle.Text      = 'Maintenance is running...'
        $script:UI.lblTitle.ForeColor = $script:ColText
        $script:UI.lblSummary.Text    = 'Please leave this window open. You can keep using your PC, but avoid closing programs that are being updated.'
        $script:UI.lblNow.Text        = 'Starting...'
        $script:UI.btnStop.Text       = 'Stop after this step'
        $script:UI.btnStop.Enabled    = $true
        $script:UI.btnStop.Visible    = $true
        $script:UI.btnBack.Enabled    = $false
        $script:UI.btnLogs.Enabled    = $true
        $script:UI.btnClose.Enabled   = $false
        $script:UI.pnlSetup.Visible   = $false
        $script:UI.pnlRun.Visible     = $true

        # run the engine on a background thread so the window stays responsive
        $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
        $rs.ApartmentState = 'STA'
        $rs.ThreadOptions  = 'ReuseThread'
        $rs.Open()
        $ps = [System.Management.Automation.PowerShell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript($Engine.ToString()).AddArgument($o)
        $out = New-Object 'System.Management.Automation.PSDataCollection[psobject]'
        $in  = New-Object 'System.Management.Automation.PSDataCollection[psobject]'
        $in.Complete()

        $script:Run = @{
            PS = $ps; RS = $rs; Out = $out; Read = 0; Opt = $o
            Items = $items; Finished = 0; Current = 0; Done = $null; Active = $true
        }
        try {
            $script:Run.Handle = $ps.BeginInvoke($in, $out)
        } catch {
            # Fallback: no live streaming, the output is collected when the run ends
            $script:Run.Handle = $ps.BeginInvoke()
        }
        $script:Timer.Start()
    }

    # ======================= build the window =======================
    $script:UI = @{}
    $form = New-Object System.Windows.Forms.Form
    $form.Text            = 'PC Maintenance'
    $form.StartPosition   = 'CenterScreen'
    $form.Size            = New-Object System.Drawing.Size(840, 720)
    $form.MinimumSize     = New-Object System.Drawing.Size(840, 560)
    # Fixed width, free height. (A height of 0 here can collapse the window to just a title bar.)
    $form.MaximumSize     = New-Object System.Drawing.Size(840, 4000)
    $form.MaximizeBox     = $false
    $form.Font            = $script:FontNormal
    $form.BackColor       = [System.Drawing.Color]::White
    $form.ForeColor       = $script:ColText

    # ---------- setup view
    $pnlSetup = New-Object System.Windows.Forms.TableLayoutPanel
    $pnlSetup.Dock        = 'Fill'
    $pnlSetup.ColumnCount = 1
    $pnlSetup.RowCount    = 5
    $pnlSetup.Padding     = New-Object System.Windows.Forms.Padding(16, 12, 16, 12)
    [void]$pnlSetup.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
    [void]$pnlSetup.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
    [void]$pnlSetup.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$pnlSetup.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
    [void]$pnlSetup.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
    $script:UI.pnlSetup = $pnlSetup

    # header
    $pnlHead = New-Object System.Windows.Forms.FlowLayoutPanel
    $pnlHead.FlowDirection = 'TopDown'
    $pnlHead.WrapContents  = $false
    $pnlHead.AutoSize      = $true
    $pnlHead.Margin        = New-Object System.Windows.Forms.Padding(0, 0, 0, 6)
    $lblHead = New-Object System.Windows.Forms.Label
    $lblHead.Text     = 'PC Maintenance'
    $lblHead.Font     = $script:FontTitle
    $lblHead.AutoSize = $true
    $lblHead.Margin   = New-Object System.Windows.Forms.Padding(0)
    $lblSub = New-Object System.Windows.Forms.Label
    $lblSub.Text        = 'Tick what you would like to do, then press "Start maintenance". If you are not sure, leave everything as it is - the default choices are safe.'
    $lblSub.Font        = $script:FontNormal
    $lblSub.ForeColor   = $script:ColMuted
    $lblSub.AutoSize    = $true
    $lblSub.MaximumSize = New-Object System.Drawing.Size(770, 0)
    $lblSub.Margin      = New-Object System.Windows.Forms.Padding(0, 2, 0, 0)
    $pnlHead.Controls.Add($lblHead)
    $pnlHead.Controls.Add($lblSub)
    $pnlSetup.Controls.Add($pnlHead, 0, 0)

    # quick-select buttons
    $pnlPre = New-Object System.Windows.Forms.FlowLayoutPanel
    $pnlPre.FlowDirection = 'LeftToRight'
    $pnlPre.WrapContents  = $false
    $pnlPre.AutoSize      = $true
    $pnlPre.Margin        = New-Object System.Windows.Forms.Padding(0, 4, 0, 6)
    foreach ($b in @(
        @{ Text = 'Select everything';        Skip = @() },
        @{ Text = 'Select nothing';           Skip = @(1..8) },
        @{ Text = 'Everything except the slow repair'; Skip = @(5) }
    )) {
        $btn = New-Object System.Windows.Forms.Button
        $btn.Text     = $b.Text
        $btn.AutoSize = $true
        $btn.Padding  = New-Object System.Windows.Forms.Padding(6, 2, 6, 2)
        $btn.Margin   = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)
        $btn.Tag      = $b.Skip
        $btn.Add_Click({
            param($sender, $e)
            foreach ($sid in $script:StepCtl.Keys) {
                $script:StepCtl[$sid].Check.Checked = (@($sender.Tag) -notcontains [int]$sid)
            }
        })
        $pnlPre.Controls.Add($btn)
    }
    $pnlSetup.Controls.Add($pnlPre, 0, 1)

    # the step cards
    $flow = New-Object System.Windows.Forms.FlowLayoutPanel
    $flow.Dock          = 'Fill'
    $flow.FlowDirection = 'TopDown'
    $flow.WrapContents  = $false
    $flow.AutoScroll    = $true
    $flow.Padding       = New-Object System.Windows.Forms.Padding(0, 4, 0, 4)
    foreach ($si in $StepInfo) { $flow.Controls.Add((New-StepCard $si)) }
    $pnlSetup.Controls.Add($flow, 0, 2)

    # global advanced options
    $pnlGlobal = New-Object System.Windows.Forms.FlowLayoutPanel
    $pnlGlobal.FlowDirection = 'LeftToRight'
    $pnlGlobal.WrapContents  = $true
    $pnlGlobal.AutoSize      = $true
    $pnlGlobal.BackColor     = $script:ColCard
    $pnlGlobal.Padding       = New-Object System.Windows.Forms.Padding(10, 6, 10, 6)
    $pnlGlobal.Margin        = New-Object System.Windows.Forms.Padding(0, 4, 0, 4)
    $pnlGlobal.Visible       = $false
    $lblCh = New-Object System.Windows.Forms.Label
    $lblCh.Text = 'Charger check:'; $lblCh.AutoSize = $true; $lblCh.Font = $script:FontSmall
    $lblCh.Margin = New-Object System.Windows.Forms.Padding(0, 6, 6, 0)
    $cmbCharger = New-Object System.Windows.Forms.ComboBox
    $cmbCharger.DropDownStyle = 'DropDownList'; $cmbCharger.Width = 250; $cmbCharger.Font = $script:FontSmall
    [void]$cmbCharger.Items.Add('Laptop must be plugged in (recommended)')
    [void]$cmbCharger.Items.Add('Skip the charger check')
    $cmbCharger.SelectedIndex = 0
    $cmbCharger.Margin = New-Object System.Windows.Forms.Padding(0, 2, 18, 2)
    $lblFin = New-Object System.Windows.Forms.Label
    $lblFin.Text = 'When finished:'; $lblFin.AutoSize = $true; $lblFin.Font = $script:FontSmall
    $lblFin.Margin = New-Object System.Windows.Forms.Padding(0, 6, 6, 0)
    $cmbFinish = New-Object System.Windows.Forms.ComboBox
    $cmbFinish.DropDownStyle = 'DropDownList'; $cmbFinish.Width = 220; $cmbFinish.Font = $script:FontSmall
    [void]$cmbFinish.Items.Add('Do nothing')
    [void]$cmbFinish.Items.Add('Restart my PC (60 seconds warning)')
    $cmbFinish.SelectedIndex = 0
    $cmbFinish.Margin = New-Object System.Windows.Forms.Padding(0, 2, 0, 2)
    foreach ($c in @($lblCh, $cmbCharger, $lblFin, $cmbFinish)) { $pnlGlobal.Controls.Add($c) }
    $script:UI.cmbCharger = $cmbCharger
    $script:UI.cmbFinish  = $cmbFinish
    $pnlSetup.Controls.Add($pnlGlobal, 0, 3)

    # footer: power label, advanced toggle, buttons
    $tlpFoot = New-Object System.Windows.Forms.TableLayoutPanel
    $tlpFoot.AutoSize    = $true
    $tlpFoot.Dock        = 'Fill'
    $tlpFoot.ColumnCount = 2
    $tlpFoot.RowCount    = 2
    [void]$tlpFoot.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$tlpFoot.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
    $lblPower = New-Object System.Windows.Forms.Label
    $lblPower.AutoSize = $true
    $lblPower.Font     = $script:FontSmall
    $lblPower.Margin   = New-Object System.Windows.Forms.Padding(0, 4, 0, 4)
    $script:UI.lblPower = $lblPower
    $tlpFoot.Controls.Add($lblPower, 0, 0)
    $tlpFoot.SetColumnSpan($lblPower, 2)

    $chkAdv = New-Object System.Windows.Forms.CheckBox
    $chkAdv.Text     = 'Show advanced options'
    $chkAdv.AutoSize = $true
    $chkAdv.Margin   = New-Object System.Windows.Forms.Padding(0, 14, 0, 0)
    $script:UI.chkAdv = $chkAdv
    $chkAdv.Add_CheckedChanged({
        $show = $script:UI.chkAdv.Checked
        foreach ($sid in $script:StepCtl.Keys) {
            $op = $script:StepCtl[$sid].Options
            if ($op) { $op.Visible = $show }
        }
        $script:UI.cmbCharger.Parent.Visible = $show
    })
    $tlpFoot.Controls.Add($chkAdv, 0, 1)

    $pnlBtns = New-Object System.Windows.Forms.FlowLayoutPanel
    $pnlBtns.FlowDirection = 'RightToLeft'
    $pnlBtns.WrapContents  = $false
    $pnlBtns.AutoSize      = $true
    $btnClose0 = New-Object System.Windows.Forms.Button
    $btnClose0.Text = 'Close'; $btnClose0.Size = New-Object System.Drawing.Size(90, 44)
    $btnClose0.Add_Click({ $form.Close() })
    $btnStart = New-Object System.Windows.Forms.Button
    $btnStart.Text = 'Start maintenance'
    $btnStart.Size = New-Object System.Drawing.Size(210, 44)
    $btnStart.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 12)
    $btnStart.FlatStyle = 'Flat'
    $btnStart.FlatAppearance.BorderSize = 0
    $btnStart.BackColor = $script:ColGreen
    $btnStart.ForeColor = [System.Drawing.Color]::White
    $pnlBtns.Controls.Add($btnClose0)
    $pnlBtns.Controls.Add($btnStart)
    $tlpFoot.Controls.Add($pnlBtns, 1, 1)
    $pnlSetup.Controls.Add($tlpFoot, 0, 4)

    $btnStart.Add_Click({
        $ids = @($script:StepCtl.Keys | Where-Object { $script:StepCtl[$_].Check.Checked })
        if ($ids.Count -eq 0) {
            [void](Show-Message 'Please tick at least one step first.' 'Nothing selected' ([System.Windows.Forms.MessageBoxButtons]::OK) ([System.Windows.Forms.MessageBoxIcon]::Information))
            return
        }
        $skipCharger = $script:UI.chkAdv.Checked -and ($script:UI.cmbCharger.SelectedIndex -eq 1)
        if ((Get-PowerState) -eq 'Battery' -and -not $skipCharger) {
            [void](Show-Message "Your laptop is running on battery.`r`n`r`nPlease connect the charger first. A power cut in the middle of system maintenance can damage Windows." 'Charger needed' ([System.Windows.Forms.MessageBoxButtons]::OK) ([System.Windows.Forms.MessageBoxIcon]::Warning))
            return
        }
        $note = "You are about to run $($ids.Count) step(s).`r`n`r`nBefore you continue:`r`n - save your work`r`n - keep the charger connected (laptops)"
        $emptyBin = $script:StepCtl[4].Check.Checked -or $script:StepCtl[3].Check.Checked
        if ($emptyBin) {
            $leave = $script:UI.chkAdv.Checked -and ($script:StepCtl[4].Combos[1].SelectedIndex -eq 1)
            if (-not $leave) { $note += "`r`n - the Recycle Bin will be emptied for good" }
        }
        $answer = Show-Message $note 'Ready to start?' ([System.Windows.Forms.MessageBoxButtons]::OKCancel) ([System.Windows.Forms.MessageBoxIcon]::Information)
        if ($answer -ne [System.Windows.Forms.DialogResult]::OK) { return }
        Start-Run
    })

    # ---------- progress view
    $pnlRun = New-Object System.Windows.Forms.TableLayoutPanel
    $pnlRun.Dock        = 'Fill'
    $pnlRun.ColumnCount = 1
    $pnlRun.RowCount    = 9
    $pnlRun.Padding     = New-Object System.Windows.Forms.Padding(16, 12, 16, 12)
    $pnlRun.Visible     = $false
    foreach ($rowType in @('AutoSize', 'AutoSize', 'AutoSize', 'AutoSize', 'AutoSize')) {
        [void]$pnlRun.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
    }
    [void]$pnlRun.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))  # step list
    [void]$pnlRun.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))      # details checkbox
    [void]$pnlRun.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 0)))    # log (hidden)
    [void]$pnlRun.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))      # buttons
    $script:UI.pnlRun = $pnlRun
    $script:UI.tlpRun = $pnlRun

    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Font = $script:FontTitle; $lblTitle.AutoSize = $true
    $lblTitle.Margin = New-Object System.Windows.Forms.Padding(0)
    $script:UI.lblTitle = $lblTitle
    $pnlRun.Controls.Add($lblTitle, 0, 0)

    $lblSummary = New-Object System.Windows.Forms.Label
    $lblSummary.Font = $script:FontNormal; $lblSummary.AutoSize = $true
    $lblSummary.ForeColor = $script:ColMuted
    $lblSummary.MaximumSize = New-Object System.Drawing.Size(770, 0)
    $lblSummary.Margin = New-Object System.Windows.Forms.Padding(0, 2, 0, 8)
    $script:UI.lblSummary = $lblSummary
    $pnlRun.Controls.Add($lblSummary, 0, 1)

    $lblNow = New-Object System.Windows.Forms.Label
    $lblNow.Font = $script:FontBold; $lblNow.AutoSize = $true
    $lblNow.ForeColor = $script:ColBlue
    $lblNow.MaximumSize = New-Object System.Drawing.Size(770, 0)
    $lblNow.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 6)
    $script:UI.lblNow = $lblNow
    $pnlRun.Controls.Add($lblNow, 0, 2)

    $pbOverall = New-Object System.Windows.Forms.ProgressBar
    $pbOverall.Dock = 'Top'; $pbOverall.Height = 22; $pbOverall.Style = 'Continuous'
    $pbOverall.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 4)
    $script:UI.pbOverall = $pbOverall
    $pnlRun.Controls.Add($pbOverall, 0, 3)

    $pbActivity = New-Object System.Windows.Forms.ProgressBar
    $pbActivity.Dock = 'Top'; $pbActivity.Height = 8
    $pbActivity.Style = 'Marquee'; $pbActivity.MarqueeAnimationSpeed = 30
    $pbActivity.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 10)
    $script:UI.pbActivity = $pbActivity
    $pnlRun.Controls.Add($pbActivity, 0, 4)

    $lvSteps = New-Object System.Windows.Forms.ListView
    $lvSteps.Dock = 'Fill'; $lvSteps.View = 'Details'; $lvSteps.HeaderStyle = 'None'
    $lvSteps.BorderStyle = 'None'; $lvSteps.FullRowSelect = $false; $lvSteps.GridLines = $false
    $lvSteps.Font = $script:FontNormal
    [void]$lvSteps.Columns.Add('Step', 470)
    [void]$lvSteps.Columns.Add('Status', 160)
    [void]$lvSteps.Columns.Add('Time', 90)
    $script:UI.lvSteps = $lvSteps
    $pnlRun.Controls.Add($lvSteps, 0, 5)

    $chkDetails = New-Object System.Windows.Forms.CheckBox
    $chkDetails.Text = 'Show technical details'
    $chkDetails.AutoSize = $true
    $chkDetails.Margin = New-Object System.Windows.Forms.Padding(0, 8, 0, 4)
    $script:UI.chkDetails = $chkDetails
    $pnlRun.Controls.Add($chkDetails, 0, 6)

    $txtLog = New-Object System.Windows.Forms.TextBox
    $txtLog.Multiline = $true; $txtLog.ReadOnly = $true; $txtLog.ScrollBars = 'Vertical'
    $txtLog.Dock = 'Fill'; $txtLog.Font = $script:FontMono
    $txtLog.BackColor = [System.Drawing.Color]::White
    $txtLog.Visible = $false
    $script:UI.txtLog = $txtLog
    $pnlRun.Controls.Add($txtLog, 0, 7)

    $chkDetails.Add_CheckedChanged({
        $on = $script:UI.chkDetails.Checked
        $script:UI.txtLog.Visible = $on
        $rows = $script:UI.tlpRun.RowStyles
        if ($on) {
            $rows[5].SizeType = [System.Windows.Forms.SizeType]::Percent; $rows[5].Height = 35
            $rows[7].SizeType = [System.Windows.Forms.SizeType]::Percent; $rows[7].Height = 65
        } else {
            $rows[5].SizeType = [System.Windows.Forms.SizeType]::Percent; $rows[5].Height = 100
            $rows[7].SizeType = [System.Windows.Forms.SizeType]::Absolute; $rows[7].Height = 0
        }
    })

    $pnlRunBtns = New-Object System.Windows.Forms.FlowLayoutPanel
    $pnlRunBtns.FlowDirection = 'RightToLeft'; $pnlRunBtns.WrapContents = $false
    $pnlRunBtns.AutoSize = $true; $pnlRunBtns.Dock = 'Fill'
    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = 'Close'; $btnClose.Size = New-Object System.Drawing.Size(90, 36)
    $btnClose.Add_Click({ $form.Close() })
    $btnBack = New-Object System.Windows.Forms.Button
    $btnBack.Text = 'Back to options'; $btnBack.Size = New-Object System.Drawing.Size(140, 36)
    $btnBack.Add_Click({
        $script:Run = $null
        $script:UI.pnlRun.Visible   = $false
        $script:UI.pnlSetup.Visible = $true
        Update-PowerLabel
    })
    $btnLogs = New-Object System.Windows.Forms.Button
    $btnLogs.Text = 'Open log folder'; $btnLogs.Size = New-Object System.Drawing.Size(140, 36)
    $btnLogs.Add_Click({ Start-Process explorer.exe -ArgumentList "`"$LogDir`"" })
    $btnStop = New-Object System.Windows.Forms.Button
    $btnStop.Text = 'Stop after this step'; $btnStop.Size = New-Object System.Drawing.Size(180, 36)
    $btnStop.Add_Click({
        $script:UI.btnStop.Enabled = $false
        $script:UI.btnStop.Text    = 'Stopping after this step...'
        try { Set-Content -LiteralPath $CancelFile -Value 'stop' -ErrorAction Stop } catch { }
    })
    foreach ($b in @($btnClose, $btnBack, $btnLogs, $btnStop)) { $pnlRunBtns.Controls.Add($b) }
    $script:UI.btnClose = $btnClose; $script:UI.btnBack = $btnBack
    $script:UI.btnLogs  = $btnLogs;  $script:UI.btnStop = $btnStop
    $pnlRun.Controls.Add($pnlRunBtns, 0, 8)

    $form.Controls.Add($pnlRun)
    $form.Controls.Add($pnlSetup)

    # ---------- timers and closing
    $script:Timer = New-Object System.Windows.Forms.Timer
    $script:Timer.Interval = 300
    $script:Timer.Add_Tick({ Poll-Run })

    $script:PowerTimer = New-Object System.Windows.Forms.Timer
    $script:PowerTimer.Interval = 3000
    $script:PowerTimer.Add_Tick({ if ($script:UI.pnlSetup.Visible) { Update-PowerLabel } })
    $script:PowerTimer.Start()
    Update-PowerLabel

    $form.Add_FormClosing({
        param($sender, $e)
        if ($script:Run -and $script:Run.Active) {
            $e.Cancel = $true
            [void](Show-Message "Maintenance is still running.`r`n`r`nPlease wait until it has finished, or press 'Stop after this step'." 'Please wait' ([System.Windows.Forms.MessageBoxButtons]::OK) ([System.Windows.Forms.MessageBoxIcon]::Information))
        }
    })

    # Safety net: if the window ever opens collapsed, restore a sensible size
    $form.Add_Shown({
        if ($form.Height -lt 500 -or $form.Width -lt 700) {
            $form.MaximumSize = New-Object System.Drawing.Size(840, 4000)
            $form.Size        = New-Object System.Drawing.Size(840, 720)
        }
        $form.Activate()
    })

    [void]$form.ShowDialog()
}
catch {
    if ($script:ConsoleHwnd -ne [IntPtr]::Zero) { [void][Native.ConWin]::ShowWindow($script:ConsoleHwnd, 5) }
    [void][System.Windows.Forms.MessageBox]::Show("The window could not be opened:`r`n`r`n$($_.Exception.Message)", 'PC Maintenance', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
}
finally {
    Close-RunLog
    Remove-Item -LiteralPath $CancelFile -Force -ErrorAction SilentlyContinue
    if ($script:ConsoleHwnd -ne [IntPtr]::Zero) { [void][Native.ConWin]::ShowWindow($script:ConsoleHwnd, 5) }
}
