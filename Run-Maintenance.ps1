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
      9. Windows Update (scan, optionally install)
     10. Extra caches (off by default)
     11. Disk space report
     12. Crash and error summary
     13. Hardware health
     14. Security check-up
   Server mode only:
     15. Server health report   16. Backup check   17. Server roles check (AD DS, DNS,
     DHCP, IIS, Hyper-V, cluster)   18. Storage health   19. Server cleanup (off by default)

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
    Run every default step without showing the window. Step 10 (extra caches) is
    off by default: name it with -Steps 10 or use -Preset DeepClean.
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
.PARAMETER Preset
    Unattended run of a ready-made selection: QuickTuneUp (steps 4,7,8),
    DeepClean (1,2,3,4,5,7,8,10), WeeklySafe (2,6,7,8,9,14) or, on servers, ServerCheck
    (8,9,12,13,14,15,16,17,18: read-only). Ignored when -Steps is given.
.PARAMETER Preview
    Unattended mode: only show what steps 2, 4, 10 and 19 would do. Nothing is installed or deleted.
.PARAMETER MaintenanceWindow
    Server mode: confirms this is a planned maintenance window. Without it, steps
    that change a server (5 repair, 7 optimize, 19 cleanup, installing updates) are
    skipped and only the read-only checks run.
.PARAMETER Menu
    Show a text menu instead of the window (used automatically on Server Core).
.PARAMETER Schedule
    Create the weekly scheduled task (see -ScheduleDay, -ScheduleTime, -Preset) and exit.
    On a server it runs as SYSTEM; add -MaintenanceWindow to allow changes in that run.
.PARAMETER RemoveSchedule
    Remove the weekly scheduled task and exit.
.PARAMETER Mode
    Auto (default), Pc or Server. Auto picks Server on Windows Server and Pc on
    Windows 10/11. Only the steps that belong to the mode are offered or run.

Exit code (unattended mode): 0 = all fine, 1 = warnings (stopped by the user, a step
skipped because this PC cannot do it or needs -MaintenanceWindow, or a check
reported a WARN line), 2 = a step failed or the run could not start.

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
    [switch]$Reboot,
    [ValidateSet('Auto', 'Pc', 'Server')][string]$Mode = 'Auto',
    [ValidateSet('QuickTuneUp', 'DeepClean', 'WeeklySafe', 'ServerCheck')][string]$Preset,
    [switch]$Preview,
    [switch]$MaintenanceWindow,
    [switch]$Menu,
    [switch]$Schedule,
    [switch]$RemoveSchedule,
    [ValidateSet('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')][string]$ScheduleDay = 'Sunday',
    [string]$ScheduleTime = '03:00'
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

$headless = [bool]($All -or $Steps -or $SkipSFC -or $SkipDefender -or $SkipRestorePoint -or $Preset -or $Preview)

# What are we running on? Product type 1 = workstation, 2/3 = domain controller/server.
# InstallationType (registry) is Client, Server or "Server Core" (no desktop).
function Get-SystemInfo {
    $r = @{ ProductType = 1; InstallType = 'Client'; Text = 'Windows (version unknown)' }
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $cv = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
        $r.ProductType = [int]$os.ProductType
        if ($cv.InstallationType) { $r.InstallType = [string]$cv.InstallationType }
        $build = [string]$os.BuildNumber
        if ($null -ne $cv.UBR) { $build += ".$($cv.UBR)" }
        $r.Text = "{0}, build {1}, edition {2}, install type {3}" -f ([string]$os.Caption).Trim(), $build, $cv.EditionID, $r.InstallType
    } catch { }
    return $r
}

$SystemInfo = Get-SystemInfo
if ($Mode -ne 'Auto')                  { $RunMode = $Mode }
elseif ($SystemInfo.ProductType -eq 1) { $RunMode = 'Pc' }
else                                   { $RunMode = 'Server' }

$ModeLabel = $RunMode
if ($SystemInfo.ProductType -eq 2) { $ModeLabel += ' (domain controller)' }

# ------------------------------------------------------------- Shared settings
# Servers keep logs in ProgramData (they also run as SYSTEM); a PC keeps them in the user profile.
if ($RunMode -eq 'Server') { $LogDir = Join-Path $env:ProgramData 'PCMaintenance\Logs' }
else                       { $LogDir = Join-Path $env:USERPROFILE 'MaintenanceLogs' }
$HistoryFile = Join-Path $LogDir 'MaintenanceHistory.csv'
$CancelFile  = Join-Path $env:TEMP 'pc-maintenance-stop.flag'
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null

# Remove old transcripts (keep 90 days). The history CSV is kept.
Get-ChildItem -Path $LogDir -File -ErrorAction SilentlyContinue |
    Where-Object { ($_.Name -like 'Maintenance_*.log' -or $_.Name -like 'Report_*.html') -and $_.LastWriteTime -lt (Get-Date).AddDays(-90) } |
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

# The step registry. Name goes into the log/CSV, Title/Desc/Time are shown in the window.
#   Modes    which modes offer the step ('Pc', 'Server')
#   Risk     ReadOnly | Changes | Deletes (on a server only ReadOnly steps start ticked)
#   Requires optional check: returns a reason text when this PC cannot run the step, else nothing
$StepInfo = @(
    @{ Id = 1; Name = 'Restore point';                   Title = 'Create a safety restore point';
       Desc = 'Lets you undo system changes if something goes wrong. Keeps your last restore points and removes older ones made by this tool.'; Time = 'about 1 minute';
       Modes = @('Pc'); Risk = 'Changes';
       Requires = { if (-not (Get-Command Checkpoint-Computer -ErrorAction SilentlyContinue)) { 'System Restore is not available on this Windows edition.' } } },
    @{ Id = 2; Name = 'Update software (winget)';        Title = 'Update my programs';
       Desc = 'Installs updates for your installed programs with winget, the update tool built into Windows. Some installers may open their own window.'; Time = '5 to 20 minutes';
       Modes = @('Pc'); Risk = 'Changes';
       Requires = { if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { "winget not found. Install 'App Installer' from the Microsoft Store." } } },
    @{ Id = 3; Name = 'Disk cleanup (cleanmgr)';         Title = 'Free up disk space';
       Desc = 'Runs Windows Disk Cleanup. Your Downloads folder and the files Windows needs to reset itself are never touched.'; Time = '2 to 20 minutes';
       Modes = @('Pc'); Risk = 'Deletes';
       Requires = { if (-not (Test-Path -LiteralPath "$env:SystemRoot\System32\cleanmgr.exe")) { 'Disk Cleanup (cleanmgr.exe) is not installed on this PC.' } } },
    @{ Id = 4; Name = 'Temp files, recycle bin, DNS';    Title = 'Clear temporary files and empty the Recycle Bin';
       Desc = 'Removes old temporary files and empties the Recycle Bin (this cannot be undone). Also refreshes the network (DNS) cache.'; Time = '1 to 10 minutes';
       Modes = @('Pc'); Risk = 'Deletes'; Requires = $null },
    @{ Id = 5; Name = 'System repair (DISM + SFC)';      Title = 'Check and repair Windows system files';
       Desc = 'Scans Windows for damaged files and repairs them. This is the slowest step.'; Time = '10 to 30 minutes';
       Modes = @('Pc', 'Server'); Risk = 'Changes'; Gate = $true; Requires = $null },
    @{ Id = 6; Name = 'Defender update + scan';          Title = 'Update virus definitions and scan';
       Desc = 'Updates Windows Defender and runs a quick virus scan.'; Time = '2 to 10 minutes';
       Modes = @('Pc', 'Server'); Risk = 'Changes';
       Requires = {
           if (-not (Get-Command Update-MpSignature -ErrorAction SilentlyContinue) -or -not (Get-Service WinDefend -ErrorAction SilentlyContinue)) {
               return 'Windows Defender is not installed.'
           }
           try {
               if ([string](Get-MpComputerStatus -ErrorAction Stop).AMRunningMode -like '*Passive*') {
                   return 'Windows Defender is in passive mode because another antivirus is active.'
               }
           } catch { }
       } },
    @{ Id = 7; Name = 'Optimize drives (TRIM/defrag)';   Title = 'Optimize my drives';
       Desc = 'Keeps SSDs fast (TRIM) and tidies hard disks (defrag). Windows picks the right method for every drive.'; Time = '1 to 30 minutes';
       Modes = @('Pc', 'Server'); Risk = 'Changes'; Gate = $true;
       Requires = { if (-not (Get-Command Optimize-Volume -ErrorAction SilentlyContinue)) { 'Optimize-Volume is not available on this PC.' } } },
    @{ Id = 8; Name = 'Disk health report';              Title = 'Check the health of my disks';
       Desc = 'Shows whether your drives report any problems and how much space is left.'; Time = 'under 1 minute';
       Modes = @('Pc', 'Server'); Risk = 'ReadOnly';
       Requires = { if (-not (Get-Command Get-PhysicalDisk -ErrorAction SilentlyContinue)) { 'Get-PhysicalDisk is not available on this PC.' } } },
    @{ Id = 9; Name = 'Windows Update';                  Title = 'Check for Windows updates';
       Desc = 'Looks for Windows updates with the Windows Update service (and your WSUS server, if you have one). By default it only lists them; in the advanced options you can let it install them. Driver updates are only reported. It never restarts your PC.'; Time = '1 to 15 minutes';
       Modes = @('Pc', 'Server'); Risk = 'ReadOnly';
       Requires = { if (-not (Get-Service wuauserv -ErrorAction SilentlyContinue)) { 'The Windows Update service was not found.' } } },
    @{ Id = 10; Name = 'Extra caches';                   Title = 'Clear extra caches (Windows Update, Delivery Optimization, browsers)';
       Desc = 'Removes downloaded update files that are no longer needed, the Delivery Optimization cache and the cache of Chrome, Edge and Firefox. Passwords, bookmarks and logins are never touched. Off by default.'; Time = '1 to 5 minutes';
       Modes = @('Pc'); Risk = 'Deletes'; DefaultOn = $false; Requires = $null },
    @{ Id = 11; Name = 'Disk space report';              Title = 'Show what is using my disk space';
       Desc = 'Lists the largest folders, the hibernation and page files, the Windows component store and old user profiles. Report only: nothing is deleted.'; Time = '3 to 20 minutes';
       Modes = @('Pc', 'Server'); Risk = 'ReadOnly'; Requires = $null },
    @{ Id = 12; Name = 'Crash and error summary';        Title = 'Show why my PC crashed';
       Desc = 'Summarizes blue screens, unexpected shutdowns, application crashes and disk errors from the last 30 days. Report only.'; Time = 'under 2 minutes';
       Modes = @('Pc', 'Server'); Risk = 'ReadOnly'; Requires = $null },
    @{ Id = 13; Name = 'Hardware health';                Title = 'Check hardware health';
       Desc = 'Reads SSD wear and temperature, drive error counters and the battery condition. Optionally runs a read-only online disk scan. Report only.'; Time = 'under 1 minute';
       Modes = @('Pc', 'Server'); Risk = 'ReadOnly';
       Requires = { if (-not (Get-Command Get-StorageReliabilityCounter -ErrorAction SilentlyContinue)) { 'Get-StorageReliabilityCounter is not available on this PC.' } } },
    @{ Id = 14; Name = 'Security check-up';              Title = 'Run a security check-up';
       Desc = 'Checks Defender, the firewall, BitLocker, Secure Boot, the TPM, SMBv1 and Remote Desktop. Report only: nothing is changed.'; Time = 'under 1 minute';
       Modes = @('Pc', 'Server'); Risk = 'ReadOnly'; Requires = $null },
    @{ Id = 15; Name = 'Server health report';           Title = 'Check the health of this server';
       Desc = 'Uptime, pending restart, free disk space, automatic services that are not running, critical events, the last installed update, expiring certificates and time synchronization. Report only.'; Time = '1 to 3 minutes';
       Modes = @('Server'); Risk = 'ReadOnly'; Requires = $null },
    @{ Id = 16; Name = 'Backup check';                   Title = 'Check the backups';
       Desc = 'Windows Server Backup: the last successful backup and its result. Also checks that the VSS writers are stable and shows the shadow storage. Report only.'; Time = 'under 1 minute';
       Modes = @('Server'); Risk = 'ReadOnly'; Requires = $null },
    @{ Id = 17; Name = 'Server roles check';             Title = 'Check the installed server roles';
       Desc = 'Finds the installed roles and checks them: Active Directory (dcdiag, replication, SYSVOL), DNS, DHCP, IIS, Hyper-V and failover clustering. Report only.'; Time = '1 to 10 minutes';
       Modes = @('Server'); Risk = 'ReadOnly'; Requires = $null },
    @{ Id = 18; Name = 'Storage health';                 Title = 'Check storage pools, disks and volumes';
       Desc = 'Health of Storage Spaces pools and virtual disks, physical disks and volumes, and running repair jobs. Report only.'; Time = 'under 1 minute';
       Modes = @('Server'); Risk = 'ReadOnly';
       Requires = { if (-not (Get-Command Get-StoragePool -ErrorAction SilentlyContinue)) { 'The storage cmdlets are not available on this server.' } } },
    @{ Id = 19; Name = 'Server cleanup';                 Title = 'Clean up this server';
       Desc = 'Cleans the Windows component store (without /ResetBase), the Windows Update download cache, old temp files and old IIS logs. Event logs are never touched. Needs a maintenance window and is off by default.'; Time = '2 to 20 minutes';
       Modes = @('Server'); Risk = 'Deletes'; Gate = $true; DefaultOn = $false; Requires = $null }
)

# Ready-made selections (window buttons and -Preset)
$Presets = [ordered]@{
    QuickTuneUp = @(4, 7, 8)
    DeepClean   = @(1, 2, 3, 4, 5, 7, 8, 10)
    WeeklySafe  = @(2, 6, 7, 8, 9, 14)
    ServerCheck = @(8, 9, 12, 13, 14, 15, 16, 17, 18)
}

# Steps this mode offers, and the ones this PC cannot run (id -> reason).
$ModeStepIds = @($StepInfo | Where-Object { $_.Modes -contains $RunMode } | ForEach-Object { [int]$_.Id })
$Unavailable = @{}
foreach ($si in $StepInfo) {
    if ($ModeStepIds -notcontains [int]$si.Id -or -not $si.Requires) { continue }
    $why = $null
    try { $why = & $si.Requires } catch { }   # a broken check must not block the step
    if ($why) { $Unavailable[[int]$si.Id] = [string]$why }
}

# Steps that are ticked / run by default (a step can set DefaultOn = $false)
# On a server only read-only steps are default, unless -MaintenanceWindow says changes are fine.
$ModeDefaultIds = @($StepInfo | Where-Object {
    $_.Modes -contains $RunMode -and $_.DefaultOn -ne $false -and
    ($RunMode -ne 'Server' -or $_.Risk -eq 'ReadOnly' -or $MaintenanceWindow)
} | ForEach-Object { [int]$_.Id })

# Server steps that are skipped outside a maintenance window (the engine enforces this)
$Gated = @()
if ($RunMode -eq 'Server') { $Gated = @($StepInfo | Where-Object { $_.Modes -contains 'Server' -and $_.Gate -eq $true } | ForEach-Object { [int]$_.Id }) }

# Steps that can show what they would do without doing it
$PreviewIds = @(2, 4, 10, 19)

# Defaults for every engine option. The window and the unattended mode both start from this.
function New-RunOptions {
    return @{
        Steps              = [int[]]@()
        StepNames          = @($StepInfo | ForEach-Object { $_.Name })
        KeepRestorePoints  = 2
        WingetSilent       = $false
        WingetIds          = @()          # empty = update everything
        CleanStrength      = 'Standard'
        TempDays           = 3
        EmptyRecycleBin    = $true
        RepairMode         = 'Both'
        DefenderMode       = 'Quick'
        OptimizeDrive      = 'All'
        WindowsUpdateMode  = 'Scan'       # Scan or Install
        CacheWindowsUpdate = $true
        CacheDeliveryOpt   = $true
        CacheBrowsers      = $true
        DiskScan           = $false
        IgnorePower        = $false
        Reboot             = $false
        Preview            = $false
        HistoryFile        = $HistoryFile
        CancelFile         = $CancelFile
        ReportFile         = (Join-Path $LogDir ("Report_{0:yyyy-MM-dd_HH-mm}.html" -f (Get-Date)))
        Mode               = $RunMode
        SystemText         = $SystemInfo.Text
        Unavailable        = $Unavailable
        MaintenanceWindow  = [bool]$MaintenanceWindow
        Gated              = $Gated
        IsDomainController = ($SystemInfo.ProductType -eq 2)
        OptimizeAction     = $(if ($RunMode -eq 'Server') { 'Analyze' } else { 'Optimize' })
        ServerCleanComponents = $true
        ServerCleanWuCache = $true
        ServerCleanTemp    = $true
        IisLogDays         = 90           # 0 = leave IIS logs alone
    }
}

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
#     @@DONE|<GB freed>|<time>|<failed steps>|<reboot pending>|<stopped>|<aborted>|<unavailable steps>|<report file>|<warnings>
# =============================================================================
$Engine = {
    param($Opt)

    $RunId     = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $startTime = Get-Date
    $State = @{
        Aborted   = $false
        Cancelled = $false
        PowerOk   = $true
        Unavail   = 0
        Results   = New-Object System.Collections.Generic.List[object]
        StepLog   = @{}
        Warnings  = 0
    }

    function Say([string]$Text) { Write-Output $Text }

    # A check that found something worth attention. Counted; any warning makes the exit code 1.
    function Add-Warning([string]$Text) { $State.Warnings++; Say "  WARN  $Text" }
    function Write-Check([bool]$Ok, [string]$Text) {
        if ($Ok) { Say "  OK    $Text" } else { Add-Warning $Text }
    }

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
        if ($s -match '^\s*\[[=\s]*\d+(\.\d+)?%[=\s]*\]\s*$') { return $null }   # DISM progress bar
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
            Os       = $Opt.SystemText
        })
    }

    function Format-Bytes([double]$Bytes) {
        if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
        if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
        return ('{0:N0} KB' -f ($Bytes / 1KB))
    }

    function Test-PlainFolder([string]$Path) {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        return [bool]($item -and $item.PSIsContainer -and (([int]$item.Attributes -band 0x400) -eq 0))
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

    # Total size of a folder tree (junctions/symlinks are not followed).
    function Get-FolderBytes([string]$Root) {
        $total = [int64]0
        $stack = New-Object System.Collections.Generic.Stack[string]
        $stack.Push($Root)
        while ($stack.Count -gt 0) {
            $current = $stack.Pop()
            try {
                foreach ($item in (New-Object System.IO.DirectoryInfo($current)).EnumerateFileSystemInfos()) {
                    if (([int]$item.Attributes -band 0x400) -ne 0) { continue }
                    if ($item -is [System.IO.DirectoryInfo]) { $stack.Push($item.FullName) } else { $total += $item.Length }
                }
            } catch { }
        }
        return $total
    }

    # Deletes (or, in preview mode, only counts) what Get-TempContents found.
    function Remove-Scanned($Scan, [datetime]$DirCutoff) {
        $sizeBytes = ($Scan.Files | Measure-Object -Property Length -Sum).Sum
        if (-not $sizeBytes) { $sizeBytes = 0 }
        if ($Scan.Links -gt 0) { Say "  ($($Scan.Links) junction/symlink entries were left untouched)" }
        if ($Opt.Preview) {
            Say ("  Preview: would delete {0} files ({1})" -f $Scan.Files.Count, (Format-Bytes $sizeBytes))
            return
        }
        Say ("  Deleting {0} files ({1})..." -f $Scan.Files.Count, (Format-Bytes $sizeBytes))
        $i = 0; $deleted = 0
        foreach ($f in $Scan.Files) {
            try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $deleted++ } catch { }
            $i++
            if ($i % 2000 -eq 0) { Say "  $i / $($Scan.Files.Count)" }
        }
        Say "  removed $deleted files; $($Scan.Files.Count - $deleted) in use or protected were left alone"

        # Remove old folders that are now empty (deepest first). Delete() without
        # the recursive flag fails on a non-empty folder, so it can't remove content.
        $Scan.Dirs |
            Where-Object { $_.CreationTime -lt $DirCutoff -and $_.LastWriteTime -lt $DirCutoff } |
            Sort-Object { $_.FullName.Length } -Descending |
            ForEach-Object {
                try { [System.IO.Directory]::Delete($_.FullName, $false) } catch { }
            }
    }

    function Get-RecycleBinBytes {
        try {
            $bin = (New-Object -ComObject Shell.Application).Namespace(0xA)
            $sum = [int64]0
            foreach ($i in $bin.Items()) { $sum += [int64]$i.Size }
            return $sum
        } catch { return -1 }
    }

    # Only folders named Temp or Tmp that are not junctions.
    function Test-SafeTempRoot([string]$Path) {
        try { $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\') } catch { return $false }
        if ((Split-Path $full -Leaf) -notin @('Temp', 'Tmp')) { return $false }
        return (Test-PlainFolder $full)
    }

    # Empties the Windows Update download folder (the update services are stopped meanwhile).
    function Clear-WuDownloadCache {
        $everything = [datetime]::MaxValue
        $wu = "$env:SystemRoot\SoftwareDistribution\Download"
        if (-not (Test-PlainFolder $wu)) { Say 'Windows Update download cache: nothing to clear.'; return }
        Say "Windows Update download cache ($wu):"
        $stopped = @()
        $skip = $false
        if (-not $Opt.Preview) {
            foreach ($n in 'wuauserv', 'bits') {
                $svc = Get-Service $n -ErrorAction SilentlyContinue
                if ($svc -and $svc.Status -eq 'Running') {
                    try { Stop-Service $n -Force -ErrorAction Stop; $stopped += $n }
                    catch { Say "  WARNING: could not stop the $n service - leaving this cache alone."; $skip = $true }
                }
            }
        }
        try {
            if (-not $skip) { Remove-Scanned (Get-TempContents -Root $wu -Cutoff $everything) $everything }
        } finally {
            foreach ($n in $stopped) { Start-Service $n -WarningAction SilentlyContinue -ErrorAction SilentlyContinue }
        }
    }

    function Get-HtmlText([string]$Text) { return [System.Net.WebUtility]::HtmlEncode($Text) }

    function Write-HtmlReport {
        param([double]$FreeBefore, [double]$FreeAfter, [string]$Elapsed, [bool]$RebootPending)
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine('<!DOCTYPE html><html><head><meta charset="utf-8"><title>PC Maintenance report</title>')
        [void]$sb.AppendLine('<style>body{font-family:Segoe UI,Arial,sans-serif;margin:24px;color:#212529}table{border-collapse:collapse;margin:8px 0 18px}td,th{border:1px solid #ccd;padding:4px 10px;text-align:left}th{background:#eef2f7}.OK{color:#1e8c3c}.Failed{color:#c82828;font-weight:bold}.Skipped{color:#777}pre{background:#f6f8fa;padding:10px;overflow:auto;font-size:12px}</style></head><body>')
        [void]$sb.AppendLine('<h1>PC Maintenance report</h1>')
        [void]$sb.AppendLine(('<p>Run: {0}<br>System: {1}<br>Mode: {2}</p>' -f (Get-HtmlText $RunId), (Get-HtmlText $Opt.SystemText), (Get-HtmlText $Opt.Mode)))
        [void]$sb.AppendLine('<h2>Before and after</h2><table>')
        [void]$sb.AppendLine(('<tr><th>Free space before</th><td>{0:N2} GB</td></tr>' -f $FreeBefore))
        [void]$sb.AppendLine(('<tr><th>Free space after</th><td>{0:N2} GB</td></tr>' -f $FreeAfter))
        [void]$sb.AppendLine(('<tr><th>Difference</th><td>{0:N2} GB</td></tr>' -f ($FreeAfter - $FreeBefore)))
        [void]$sb.AppendLine(('<tr><th>Total time</th><td>{0}</td></tr>' -f (Get-HtmlText $Elapsed)))
        [void]$sb.AppendLine(('<tr><th>Restart pending</th><td>{0}</td></tr>' -f $(if ($RebootPending) { 'yes' } else { 'no' })))
        [void]$sb.AppendLine(('<tr><th>Warnings</th><td>{0}</td></tr>' -f $State.Warnings))
        [void]$sb.AppendLine('</table><h2>Steps</h2><table><tr><th>Step</th><th>Status</th><th>Time</th><th>Message</th></tr>')
        foreach ($r in $State.Results) {
            if ($r.Message -eq 'Not selected') { continue }
            [void]$sb.AppendLine(('<tr><td>{0}</td><td class="{1}">{1}</td><td>{2}</td><td>{3}</td></tr>' -f (Get-HtmlText $r.Step), (Get-HtmlText $r.Status), (Get-HtmlText $r.Duration), (Get-HtmlText $r.Message)))
        }
        [void]$sb.AppendLine('</table><h2>Details</h2>')
        foreach ($sid in ($State.StepLog.Keys | Sort-Object)) {
            $name = $Opt.StepNames[[int]$sid - 1]
            [void]$sb.AppendLine(('<details><summary>{0}</summary><pre>{1}</pre></details>' -f (Get-HtmlText $name), (Get-HtmlText ($State.StepLog[$sid] -join "`n"))))
        }
        [void]$sb.AppendLine('</body></html>')
        [System.IO.File]::WriteAllText($Opt.ReportFile, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
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
        if ($Opt.Unavailable -and $Opt.Unavailable.ContainsKey($Id)) {
            $why = [string]$Opt.Unavailable[$Id]
            $State.Unavail++
            Say "Step $Id skipped: $why"
            Add-Result $Name 'Skipped' '00:00:00' $why
            Say "@@STEP|$Id|END|Skipped|0|$(Clean-Msg $why)"
            return
        }
        $needsWindow = (@($Opt.Gated) -contains $Id) -and -not $Opt.Preview -and -not $Opt.MaintenanceWindow
        if ($Id -eq 7 -and [string]$Opt.OptimizeAction -eq 'Analyze') { $needsWindow = $false }   # analyzing changes nothing
        if ($needsWindow) {
            $why = 'Changes the server: needs a maintenance window (-MaintenanceWindow)'
            $State.Unavail++
            Say "Step $Id skipped: $why"
            Add-Result $Name 'Skipped' '00:00:00' $why
            Say "@@STEP|$Id|END|Skipped|0|$(Clean-Msg $why)"
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

        if (-not $Opt.Preview) { Wait-ForACPower }
        if (-not $State.PowerOk) {
            $State.Aborted = $true
            Say "!! Charger not connected - skipping this and all remaining steps."
            Add-Result $Name 'Failed' '00:00:00' 'Charger not connected - step not run'
            Say "@@STEP|$Id|END|Failed|0|Charger not connected"
            return
        }

        Say "@@STEP|$Id|START|$Name"
        $State.StepLog[$Id] = New-Object System.Collections.Generic.List[string]
        $sw      = [Diagnostics.Stopwatch]::StartNew()
        $status  = 'OK'
        $message = ''
        try {
            & $Action *>&1 | ForEach-Object {
                $line = Convert-ToCleanLine $_
                if ($null -ne $line) { $State.StepLog[$Id].Add([string]$line); $line }
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
    Say ("System: {0} (mode: {1})" -f $Opt.SystemText, $Opt.Mode)
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
        if ($Opt.Preview) {
            Say "Preview: programs with an update available (nothing is installed)."
            winget upgrade --accept-source-agreements
            return
        }
        winget source update | Out-Null

        $common = @('--accept-package-agreements', '--accept-source-agreements')
        if ($Opt.WingetSilent) {
            $common += '--silent'
        } else {
            Say "Installers may show their own windows - check your taskbar if it seems stuck."
        }
        $ids = @($Opt.WingetIds | Where-Object { $_ })
        if ($ids.Count -eq 0) {
            winget upgrade --all @common
            # 0 = success, -1978335189 = "no applicable updates found"
            if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne -1978335189) {
                throw "winget exited with code $LASTEXITCODE (some packages may have failed)"
            }
        } else {
            $bad = @()
            foreach ($id in $ids) {
                Say "Updating $id ..."
                winget upgrade --id $id --exact @common
                if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne -1978335189) { $bad += $id }
            }
            if ($bad.Count -gt 0) { throw "winget failed for: $($bad -join ', ')" }
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

        foreach ($path in @($env:TEMP, "$env:SystemRoot\Temp") | Select-Object -Unique) {
            if (-not $path -or -not (Test-Path -LiteralPath $path)) { continue }
            if (-not (Test-SafeTempRoot $path)) {
                Say "WARNING: skipping '$path' - it does not look like a normal temp folder."
                continue
            }
            Say "Scanning $path (files created AND modified more than $days day(s) ago)..."
            Remove-Scanned (Get-TempContents -Root $path -Cutoff $cutoff) $cutoff
        }

        if ($Opt.EmptyRecycleBin) {
            if ($Opt.Preview) {
                $bytes = Get-RecycleBinBytes
                if ($bytes -ge 0) { Say ("Preview: the Recycle Bin holds about {0}." -f (Format-Bytes $bytes)) }
                else { Say "Preview: the Recycle Bin size could not be read." }
            } else {
                Say "Emptying the Recycle Bin (can take a few minutes if it is large)..."
                try { Clear-RecycleBin -Force -ErrorAction Stop } catch { Say "Recycle Bin was already empty." }
            }
        } else {
            Say "Recycle Bin left alone (your choice)."
        }
        if (-not $Opt.Preview) {
            ipconfig /flushdns | Out-Null
            Say "DNS cache flushed."
        }
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
        $analyze = ([string]$Opt.OptimizeAction -eq 'Analyze')
        foreach ($v in $vols) {
            $letter = $v.DriveLetter
            if ($analyze) { Say "Analyzing ${letter}: (nothing is changed) ..." } else { Say "Optimizing ${letter}: ..." }
            try {
                if ($analyze) {
                    Optimize-Volume -DriveLetter $letter -Analyze -Verbose -ErrorAction Stop
                } else {
                    # Picks TRIM or defrag automatically per media type
                    Optimize-Volume -DriveLetter $letter -Verbose -ErrorAction Stop
                }
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

    # ---------------------------------------------------- 9. Windows Update
    Invoke-Step -Id 9 -Name $Opt.StepNames[8] -Action {
        $install = ([string]$Opt.WindowsUpdateMode -eq 'Install') -and -not $Opt.Preview
        if ($install -and $Opt.Mode -eq 'Server' -and -not $Opt.MaintenanceWindow) {
            Say 'Installing updates on a server needs -MaintenanceWindow: scanning only.'
            $install = $false
        }
        $session  = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        Say 'Searching for updates (Windows Update or your WSUS server)...'
        $found = $searcher.Search("IsInstalled=0 and IsHidden=0 and Type='Software'")
        $count = $found.Updates.Count
        Say "$count software update(s) available."
        foreach ($u in $found.Updates) {
            Say ("  - {0} ({1})" -f $u.Title, (Format-Bytes ([double]$u.MaxDownloadSize)))
        }
        try {
            $drv = $searcher.Search("IsInstalled=0 and IsHidden=0 and Type='Driver'")
            if ($drv.Updates.Count -gt 0) {
                Say "$($drv.Updates.Count) driver update(s) available (reported only, never installed by this tool):"
                foreach ($u in $drv.Updates) { Say "  - $($u.Title)" }
            } else {
                Say 'No driver updates reported.'
            }
        } catch {
            Say "Driver update search failed: $($_.Exception.Message)"
        }
        if ($count -eq 0) { return }
        if (-not $install) { Say 'Scan only: nothing was installed (change this in the advanced options).'; return }

        $toInstall = New-Object -ComObject Microsoft.Update.UpdateColl
        foreach ($u in $found.Updates) {
            if ($u.InstallationBehavior.CanRequestUserInput) { Say "  skipping (needs your input): $($u.Title)"; continue }
            if (-not $u.EulaAccepted) { $u.AcceptEula() }
            [void]$toInstall.Add($u)
        }
        if ($toInstall.Count -eq 0) { return }
        Say "Downloading $($toInstall.Count) update(s)..."
        $dl = $session.CreateUpdateDownloader()
        $dl.Updates = $toInstall
        [void]$dl.Download()
        $ready = New-Object -ComObject Microsoft.Update.UpdateColl
        foreach ($u in $toInstall) { if ($u.IsDownloaded) { [void]$ready.Add($u) } }
        if ($ready.Count -eq 0) { throw 'No updates could be downloaded.' }
        Say "Installing $($ready.Count) update(s) (this can take a long time)..."
        $inst = $session.CreateUpdateInstaller()
        $inst.Updates = $ready
        $res = $inst.Install()
        $names = @('not started', 'in progress', 'installed', 'installed with errors', 'FAILED', 'aborted')
        $bad = 0
        for ($i = 0; $i -lt $ready.Count; $i++) {
            $code = [int]$res.GetUpdateResult($i).ResultCode
            if ($code -ge 4) { $bad++ }
            Say ("  {0}: {1}" -f $names[[math]::Min($code, 5)], $ready.Item($i).Title)
        }
        if ($res.RebootRequired) { Say 'A restart is needed to finish the updates (it is not done automatically).' }
        if ($bad -gt 0) { throw "$bad update(s) failed to install." }
    }

    # ---------------------------------------------------- 10. Extra caches
    Invoke-Step -Id 10 -Name $Opt.StepNames[9] -Action {
        $everything = [datetime]::MaxValue

        if ($Opt.CacheBrowsers) {
            $roots = New-Object System.Collections.Generic.List[string]
            foreach ($base in @("$env:LOCALAPPDATA\Google\Chrome\User Data", "$env:LOCALAPPDATA\Microsoft\Edge\User Data")) {
                if (-not (Test-Path -LiteralPath $base)) { continue }
                foreach ($prof in @(Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue |
                                    Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' })) {
                    foreach ($sub in 'Cache', 'Code Cache', 'GPUCache') {
                        $roots.Add((Join-Path $prof.FullName $sub))
                    }
                }
            }
            $ff = "$env:LOCALAPPDATA\Mozilla\Firefox\Profiles"
            if (Test-Path -LiteralPath $ff) {
                foreach ($prof in @(Get-ChildItem -LiteralPath $ff -Directory -ErrorAction SilentlyContinue)) {
                    $roots.Add((Join-Path $prof.FullName 'cache2'))
                }
            }
            Say 'Browser caches (Chrome, Edge, Firefox; cookies, logins and bookmarks are not touched):'
            $merged = [pscustomobject]@{
                Files = (New-Object System.Collections.Generic.List[System.IO.FileInfo])
                Dirs  = (New-Object System.Collections.Generic.List[System.IO.DirectoryInfo])
                Links = 0
            }
            foreach ($root in $roots) {
                if (-not (Test-PlainFolder $root)) { continue }
                $one = Get-TempContents -Root $root -Cutoff $everything
                $merged.Files.AddRange($one.Files)
                $merged.Dirs.AddRange($one.Dirs)
                $merged.Links += $one.Links
            }
            Remove-Scanned $merged $everything
        }

        if ($Opt.CacheWindowsUpdate) { Clear-WuDownloadCache }

        if ($Opt.CacheDeliveryOpt) {
            if (Get-Command Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue) {
                if ($Opt.Preview) {
                    Say 'Delivery Optimization cache: would be cleared (size not measured).'
                } else {
                    try { Delete-DeliveryOptimizationCache -Force -ErrorAction Stop; Say 'Delivery Optimization cache cleared.' }
                    catch { Say "WARNING: could not clear the Delivery Optimization cache: $($_.Exception.Message)" }
                }
            } else {
                Say 'Delivery Optimization cache: command not available on this PC, skipped.'
            }
        }
    }

    # ---------------------------------------------------- 11. Disk space report
    Invoke-Step -Id 11 -Name $Opt.StepNames[10] -Action {
        $drive = $env:SystemDrive
        Say '--- Free space'
        Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' } |
            Select-Object DriveLetter, FileSystemLabel,
                @{ n = 'SizeGB'; e = { [math]::Round($_.Size / 1GB, 1) } },
                @{ n = 'FreeGB'; e = { [math]::Round($_.SizeRemaining / 1GB, 1) } } |
            Format-Table -AutoSize | Out-String -Width 150 -Stream

        Say '--- Special files'
        $special = @(Get-ChildItem -LiteralPath "$drive\" -Force -File -ErrorAction SilentlyContinue |
                     Where-Object { $_.Name -in 'hiberfil.sys', 'pagefile.sys', 'swapfile.sys' })
        if ($special.Count -eq 0) { Say '  (none of hiberfil.sys, pagefile.sys, swapfile.sys found on the system drive)' }
        foreach ($f in $special) { Say ("  {0,-14} {1}" -f $f.Name, (Format-Bytes $f.Length)) }
        Say '  (hiberfil.sys can be removed with "powercfg /h off" if you never use hibernate or fast startup)'
        if (Test-Path -LiteralPath "$drive\Windows.old") {
            Say ("  Windows.old    {0}  (removable with Disk Cleanup > Previous Windows installation)" -f (Format-Bytes (Get-FolderBytes "$drive\Windows.old")))
        }

        Say '--- Windows component store (DISM /AnalyzeComponentStore)'
        DISM /Online /Cleanup-Image /AnalyzeComponentStore

        Say '--- Largest folders (this takes a while)'
        foreach ($root in @("$drive\", $env:USERPROFILE, $env:LOCALAPPDATA)) {
            Say "In ${root}:"
            $rows = foreach ($d in (Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue)) {
                if (([int]$d.Attributes -band 0x400) -ne 0) { continue }
                [pscustomobject]@{ Folder = $d.FullName; Bytes = (Get-FolderBytes $d.FullName) }
            }
            $rows | Sort-Object Bytes -Descending | Select-Object -First 12 |
                ForEach-Object { Say ("  {0,10}  {1}" -f (Format-Bytes $_.Bytes), $_.Folder) }
        }

        Say '--- User profiles not used for 90+ days'
        $old = @(Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue |
                 Where-Object { -not $_.Special -and -not $_.Loaded -and $_.LastUseTime -and $_.LastUseTime -lt (Get-Date).AddDays(-90) })
        if ($old.Count -eq 0) { Say '  none' }
        foreach ($p in $old) {
            Say ("  {0,10}  {1} (last used {2:yyyy-MM-dd})" -f (Format-Bytes (Get-FolderBytes $p.LocalPath)), $p.LocalPath, $p.LastUseTime)
        }
        if ($old.Count -gt 0) { Say '  (remove old profiles in System Properties > Advanced > User Profiles, not by deleting the folder)' }
    }

    # ---------------------------------------------------- 12. Crash and error summary
    Invoke-Step -Id 12 -Name $Opt.StepNames[11] -Action {
        $since = (Get-Date).AddDays(-30)
        function Get-Ev([string]$Log, [string]$Provider, [int[]]$Ids) {
            return @(Get-WinEvent -FilterHashtable @{ LogName = $Log; ProviderName = $Provider; Id = $Ids; StartTime = $since } -ErrorAction SilentlyContinue)
        }
        function Get-FirstLine([string]$Text) {
            $l = ($Text -split "`r?`n")[0].Trim()
            if ($l.Length -gt 150) { return $l.Substring(0, 150) + '...' }
            return $l
        }
        function Show-Events($Events, [int]$Max) {
            $Events | Select-Object -First $Max |
                ForEach-Object { Say ("  {0:yyyy-MM-dd HH:mm}  {1}" -f $_.TimeCreated, (Get-FirstLine $_.Message)) }
        }

        Say "Period: since $($since.ToString('yyyy-MM-dd'))"
        $bug = @(Get-Ev 'System' 'Microsoft-Windows-WER-SystemErrorReporting' @(1001))
        Say "Blue screens (bugchecks): $($bug.Count)"
        Show-Events $bug 5
        $power = @(Get-Ev 'System' 'Microsoft-Windows-Kernel-Power' @(41))
        Say "Unexpected shutdowns / power loss: $($power.Count)"
        Show-Events $power 5
        $crash = @(Get-Ev 'Application' 'Application Error' @(1000))
        Say "Application crashes: $($crash.Count)"
        $crash | Group-Object { [string]$_.Properties[0].Value } | Sort-Object Count -Descending | Select-Object -First 8 |
            ForEach-Object { Say ("  {0,4} x {1}" -f $_.Count, $_.Name) }
        $hang = @(Get-Ev 'Application' 'Application Hang' @(1002))
        Say "Application hangs: $($hang.Count)"
        $hang | Group-Object { [string]$_.Properties[0].Value } | Sort-Object Count -Descending | Select-Object -First 5 |
            ForEach-Object { Say ("  {0,4} x {1}" -f $_.Count, $_.Name) }
        $disk = @(Get-Ev 'System' 'disk' @(7, 11, 15, 51, 153)) + @(Get-Ev 'System' 'Ntfs' @(55))
        Say "Disk and file system errors: $($disk.Count)"
        Show-Events ($disk | Sort-Object TimeCreated -Descending) 5
        $whea = @(Get-Ev 'System' 'Microsoft-Windows-WHEA-Logger' @(1, 17, 18, 19, 47))
        Say "Hardware error reports (WHEA): $($whea.Count)"
        Show-Events $whea 5
        if ($bug.Count + $power.Count + $disk.Count + $whea.Count -eq 0) { Say 'No serious problems found in the event log.' }
        else { Say 'WARNING: see the lines above. Blue screens, unexpected shutdowns and disk or hardware errors deserve attention.' }
    }

    # ---------------------------------------------------- 13. Hardware health
    Invoke-Step -Id 13 -Name $Opt.StepNames[12] -Action {
        function Get-Val($v) { if ($null -eq $v) { return 'n/a' } else { return $v } }
        $warnStart = $State.Warnings
        Say '--- Drives'
        foreach ($d in @(Get-PhysicalDisk)) {
            Say ("{0} ({1}, {2})" -f $d.FriendlyName, $d.MediaType, $d.HealthStatus)
            $c = $d | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
            if (-not $c) { Say '  no reliability counters available'; continue }
            Say ("  temperature: {0} C   wear: {1}%   power-on hours: {2}   read errors: {3}   write errors: {4}" -f
                 (Get-Val $c.Temperature), (Get-Val $c.Wear), (Get-Val $c.PowerOnHours), (Get-Val $c.ReadErrorsTotal), (Get-Val $c.WriteErrorsTotal))
            if ($c.Wear -ge 80)                { Add-Warning 'This SSD is heavily worn.' }
            if ($c.Temperature -ge 70)         { Add-Warning 'This drive runs hot.' }
            if ($c.ReadErrorsTotal -gt 0 -or $c.WriteErrorsTotal -gt 0) { Add-Warning 'The drive reports read/write errors.' }
        }

        Say '--- Battery'
        $full   = Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity -ErrorAction SilentlyContinue | Select-Object -First 1
        $design = Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($full -and $design -and $design.DesignedCapacity -gt 0) {
            $pct = [math]::Round(100 * $full.FullChargedCapacity / $design.DesignedCapacity)
            Say ("  full charge: {0} mWh of {1} mWh when new = {2}% health" -f $full.FullChargedCapacity, $design.DesignedCapacity, $pct)
            if ($pct -lt 60) { Add-Warning 'The battery has lost a lot of capacity.' }
        } else {
            Say '  no battery found'
        }

        if ($Opt.DiskScan) {
            Say '--- Online disk scan (read-only)'
            $bad = @()
            $vols = @(Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' -and $_.FileSystemType -eq 'NTFS' })
            foreach ($v in $vols) {
                Say "Scanning $($v.DriveLetter): ..."
                $r = Repair-Volume -DriveLetter $v.DriveLetter -Scan -ErrorAction Stop
                Say "  result: $r"
                if ([string]$r -ne 'NoErrorsFound') { $bad += $v.DriveLetter }
            }
            if ($bad.Count -gt 0) { throw "Disk scan found problems on: $($bad -join ', '). Run chkdsk." }
        }
        Say "Hardware check finished with $($State.Warnings - $warnStart) warning(s)."
    }

    # ---------------------------------------------------- 14. Security check-up
    Invoke-Step -Id 14 -Name $Opt.StepNames[13] -Action {
        $warnStart = $State.Warnings

        try {
            $mp = Get-MpComputerStatus -ErrorAction Stop
            if ([string]$mp.AMRunningMode -like '*Passive*') {
                Say '  INFO  Windows Defender is passive (another antivirus is active).'
            } else {
                Write-Check ([bool]$mp.RealTimeProtectionEnabled) 'Defender real-time protection is on'
                Write-Check ([int]$mp.AntivirusSignatureAge -le 7) "Virus definitions are $($mp.AntivirusSignatureAge) day(s) old"
            }
        } catch { Say '  INFO  Windows Defender status is not available.' }

        try {
            foreach ($fw in @(Get-NetFirewallProfile -ErrorAction Stop)) {
                Write-Check ([string]$fw.Enabled -eq 'True') "Firewall is on for the $($fw.Name) profile"
            }
        } catch { Say '  INFO  Firewall status is not available.' }

        if (Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue) {
            $bl = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction SilentlyContinue
            if ($bl) { Write-Check ([string]$bl.ProtectionStatus -eq 'On') "BitLocker protects $env:SystemDrive" }
        } else {
            Say '  INFO  BitLocker is not available on this edition of Windows.'
        }

        try { Write-Check ([bool](Confirm-SecureBootUEFI)) 'Secure Boot is on' }
        catch { Say '  INFO  Secure Boot: not supported or this PC does not start in UEFI mode.' }

        $tpm = Get-Tpm -ErrorAction SilentlyContinue
        if ($tpm) { Write-Check ([bool]($tpm.TpmPresent -and $tpm.TpmReady)) 'The TPM is present and ready' }
        else      { Say '  INFO  TPM status is not available.' }

        $smb = Get-SmbServerConfiguration -ErrorAction SilentlyContinue
        if ($smb) { Write-Check (-not $smb.EnableSMB1Protocol) 'The old SMBv1 file-sharing protocol is off' }

        $ts = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -ErrorAction SilentlyContinue
        if ($ts -and $ts.fDenyTSConnections -eq 0) {
            $nla = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -ErrorAction SilentlyContinue).UserAuthentication
            Write-Check ($nla -eq 1) 'Remote Desktop is on and requires Network Level Authentication'
        } else {
            Say '  OK    Remote Desktop is off'
        }

        $uac = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction SilentlyContinue).EnableLUA
        Write-Check ($uac -eq 1) 'User Account Control (UAC) is on'

        Say "Security check-up finished with $($State.Warnings - $warnStart) warning(s)."
    }

    # ---------------------------------------------------- 15. Server health report
    Invoke-Step -Id 15 -Name $Opt.StepNames[14] -Action {
        $os = Get-CimInstance Win32_OperatingSystem
        $up = (Get-Date) - $os.LastBootUpTime
        Say '--- System'
        Say ("  Uptime: {0} day(s) {1} hour(s) (last start {2:yyyy-MM-dd HH:mm})" -f [math]::Floor($up.TotalDays), $up.Hours, $os.LastBootUpTime)

        $why = @()
        if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $why += 'component servicing' }
        if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $why += 'Windows Update' }
        if ((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction SilentlyContinue).PendingFileRenameOperations) { $why += 'pending file renames' }
        if ($why.Count -gt 0) { Add-Warning ("A restart is pending ({0})." -f ($why -join ', ')) }
        else { Say '  OK    No restart is pending' }

        Say '--- Disk space'
        foreach ($v in @(Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' -and $_.Size -gt 0 })) {
            $pct  = 100 * $v.SizeRemaining / $v.Size
            $text = ("Drive {0}: {1:N0}% free ({2} of {3})" -f $v.DriveLetter, $pct, (Format-Bytes $v.SizeRemaining), (Format-Bytes $v.Size))
            if ($pct -lt 10) { Add-Warning ($text + ' - critical') } else { Write-Check ($pct -ge 15) $text }
        }

        Say '--- Services'
        # Services that are normally stopped although they are set to automatic
        $ignore = @('sppsvc', 'gupdate', 'gupdatem', 'edgeupdate', 'edgeupdatem', 'RemoteRegistry', 'TrustedInstaller', 'MapsBroker',
                    'clr_optimization_*', 'tiledatamodelsvc', 'CDPUserSvc_*', 'OneSyncSvc_*', 'PimIndexMaintenanceSvc_*', 'UnistoreSvc_*',
                    'UserDataSvc_*', 'WpnUserService_*', 'cbdhsvc_*', 'BcastDVRUserService_*', 'CaptureService_*', 'DevicesFlowUserSvc_*',
                    'webthreatdefsvc', 'MicrosoftEdgeElevationService')
        $stopped = @()
        foreach ($svc in @(Get-CimInstance Win32_Service -Filter "StartMode='Auto' AND State<>'Running'" -ErrorAction SilentlyContinue)) {
            if ($svc.DelayedAutoStart) { continue }
            $name = [string]$svc.Name
            if (@($ignore | Where-Object { $name -like $_ }).Count -gt 0) { continue }
            $stopped += $svc
        }
        if ($stopped.Count -eq 0) {
            Say '  OK    All automatic services are running (delayed-start services are not checked)'
        } else {
            Add-Warning ("{0} automatic service(s) are not running (some can be normal, for example services that stop when they have no work):" -f $stopped.Count)
            foreach ($svc in ($stopped | Select-Object -First 15)) {
                Say ("        {0} ({1}), exit code {2}" -f $svc.Name, $svc.DisplayName, $svc.ExitCode)
            }
        }

        Say '--- Event log (last 7 days)'
        $since = (Get-Date).AddDays(-7)
        foreach ($log in 'System', 'Application') {
            $crit = @(Get-WinEvent -FilterHashtable @{ LogName = $log; Level = 1; StartTime = $since } -ErrorAction SilentlyContinue)
            $err  = @(Get-WinEvent -FilterHashtable @{ LogName = $log; Level = 2; StartTime = $since } -ErrorAction SilentlyContinue)
            Say ("  {0}: {1} critical, {2} error event(s)" -f $log, $crit.Count, $err.Count)
            if ($crit.Count -gt 0) { Add-Warning ("{0} critical event(s) in the {1} log" -f $crit.Count, $log) }
            @($crit + $err) | Group-Object ProviderName | Sort-Object Count -Descending | Select-Object -First 5 |
                ForEach-Object { Say ("        {0,4} x {1}" -f $_.Count, $_.Name) }
        }

        Say '--- Updates'
        $hf = @(Get-HotFix -ErrorAction SilentlyContinue | Where-Object { $_.InstalledOn } | Sort-Object { [datetime]$_.InstalledOn } -Descending)
        if ($hf.Count -gt 0) {
            $last = [datetime]$hf[0].InstalledOn
            $days = [int]((Get-Date) - $last).TotalDays
            Write-Check ($days -le 60) ("Last installed update: {0} on {1:yyyy-MM-dd} ({2} days ago)" -f $hf[0].HotFixID, $last, $days)
        } else {
            Say '  INFO  Get-HotFix reported no installed updates.'
        }

        Say '--- Certificates (local computer, personal store)'
        $soon  = (Get-Date).AddDays(30)
        $certs = @(Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue | Where-Object { $_.NotAfter -lt $soon })
        if ($certs.Count -eq 0) { Say '  OK    No certificate expires within 30 days' }
        foreach ($c in $certs) {
            if ($c.NotAfter -lt (Get-Date)) { Add-Warning ("Certificate EXPIRED on {0:yyyy-MM-dd}: {1}" -f $c.NotAfter, $c.Subject) }
            else                            { Add-Warning ("Certificate expires on {0:yyyy-MM-dd}: {1}" -f $c.NotAfter, $c.Subject) }
        }

        Say '--- Time synchronization'
        $src = (& w32tm.exe /query /source 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) {
            Add-Warning "The Windows Time service does not answer: $src"
        } else {
            Say "  Source: $src"
            Write-Check ($src -notmatch 'Local CMOS Clock|Free-running System Clock') 'The time source is not the local clock'
            (& w32tm.exe /query /status 2>&1) | ForEach-Object { $l = ([string]$_).Trim(); if ($l) { Say "  $l" } }
        }
        Say 'The firewall is checked in step 14 (security check-up).'
    }

    # ---------------------------------------------------- 16. Backup check
    Invoke-Step -Id 16 -Name $Opt.StepNames[15] -Action {
        Say '--- Windows Server Backup'
        if (Get-Command Get-WBSummary -ErrorAction SilentlyContinue) {
            $wb = $null
            try { $wb = Get-WBSummary -ErrorAction Stop } catch { }
            if ($wb -and $wb.LastSuccessfulBackupTime -and ([datetime]$wb.LastSuccessfulBackupTime).Year -gt 2000) {
                $when = [datetime]$wb.LastSuccessfulBackupTime
                $age  = [int]((Get-Date) - $when).TotalDays
                Write-Check ($age -le 7) ("Last successful backup: {0:yyyy-MM-dd HH:mm} ({1} days ago)" -f $when, $age)
                Say ("  Last backup result code: 0x{0:X}   versions kept: {1}   next backup: {2}" -f [int]$wb.LastBackupResultHR, $wb.NumberOfVersions, $wb.NextBackupTime)
                if ([int]$wb.LastBackupResultHR -ne 0) { Add-Warning 'The last backup attempt did not finish cleanly.' }
            } else {
                Add-Warning 'Windows Server Backup is installed but has no successful backup.'
            }
        } else {
            Say '  INFO  Windows Server Backup is not installed.'
        }
        $other = @(Get-Service -ErrorAction SilentlyContinue |
                   Where-Object { $_.Status -eq 'Running' -and $_.DisplayName -match 'Veeam|Acronis|Commvault|Backup Exec|Altaro|Datto|Rubrik|Cohesity|Azure Backup|Recovery Services' })
        if ($other.Count -gt 0) {
            Say ("  INFO  Other backup software seems to be running: {0}" -f (($other | Select-Object -First 6 | ForEach-Object { $_.DisplayName }) -join '; '))
        }

        Say '--- Volume Shadow Copy (VSS)'
        $vss = @(& vssadmin.exe list writers 2>&1 | ForEach-Object { [string]$_ })
        if ($LASTEXITCODE -ne 0 -or $vss.Count -eq 0) {
            Add-Warning 'vssadmin could not list the VSS writers.'
        } else {
            $total = 0; $bad = 0; $current = '?'
            foreach ($line in $vss) {
                if ($line -match "^\s*[^:]+:\s*'(.+)'\s*$") { $current = $Matches[1] }
                elseif ($line -match '^\s*[^:\[\]]+:\s*\[(\d+)\]') {
                    $total++
                    if ($Matches[1] -ne '1') { $bad++; Say ("        writer not stable: {0} ({1})" -f $current, $line.Trim()) }
                }
            }
            if ($total -eq 0) { Say '  INFO  The VSS writer list could not be read (unknown output format).' }
            else              { Write-Check ($bad -eq 0) ("{0} VSS writer(s) checked, {1} not stable" -f $total, $bad) }
        }
        Say '  Shadow storage:'
        (& vssadmin.exe list shadowstorage 2>&1) | ForEach-Object {
            $l = ([string]$_).Trim()
            if ($l -match ':') { Say "    $l" }
        }
    }

    # ---------------------------------------------------- 17. Server roles check
    Invoke-Step -Id 17 -Name $Opt.StepNames[16] -Action {
        function Test-RoleInstalled([string]$Feature, [string]$Service) {
            if (Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue) {
                try { $f = Get-WindowsFeature -Name $Feature -ErrorAction Stop; if ($f) { return [bool]$f.Installed } } catch { }
            }
            if ($Service) { return [bool](Get-Service $Service -ErrorAction SilentlyContinue) }
            return $false
        }
        function Test-ServiceUp([string]$Name) {
            $svc = Get-Service $Name -ErrorAction SilentlyContinue
            if (-not $svc) { Say "  INFO  Service $Name is not installed"; return }
            Write-Check ($svc.Status -eq 'Running') ("Service {0} ({1}) is {2}" -f $svc.Name, $svc.DisplayName, $svc.Status)
        }
        function Show-RecentErrors([string]$Log) {
            $ev = @(Get-WinEvent -FilterHashtable @{ LogName = $Log; Level = 1, 2; StartTime = (Get-Date).AddDays(-7) } -ErrorAction SilentlyContinue)
            if ($ev.Count -eq 0) { Say ("  OK    No errors in the '{0}' log in the last 7 days" -f $Log); return }
            Add-Warning ("{0} error(s) in the '{1}' log in the last 7 days:" -f $ev.Count, $Log)
            $ev | Group-Object Id | Sort-Object Count -Descending | Select-Object -First 5 | ForEach-Object {
                $first = ([string]$_.Group[0].Message -split "`r?`n")[0].Trim()
                if ($first.Length -gt 110) { $first = $first.Substring(0, 110) + '...' }
                Say ("        {0,4} x event {1}: {2}" -f $_.Count, $_.Name, $first)
            }
        }

        $roles = [ordered]@{}
        $roles['AD DS']               = ((Test-RoleInstalled 'AD-Domain-Services' 'NTDS') -or [bool]$Opt.IsDomainController)
        $roles['DNS']                 = Test-RoleInstalled 'DNS' 'DNS'
        $roles['DHCP']                = Test-RoleInstalled 'DHCP' 'DHCPServer'
        $roles['IIS']                 = Test-RoleInstalled 'Web-Server' 'W3SVC'
        $roles['Hyper-V']             = Test-RoleInstalled 'Hyper-V' 'vmms'
        $roles['Failover Clustering'] = Test-RoleInstalled 'Failover-Clustering' 'ClusSvc'
        $found = @($roles.Keys | Where-Object { $roles[$_] })
        if ($found.Count -eq 0) {
            Say 'No known roles found (AD DS, DNS, DHCP, IIS, Hyper-V, Failover Clustering).'
            return
        }
        Say ("Roles found: {0}" -f ($found -join ', '))

        if ($roles['AD DS']) {
            Say '--- Active Directory Domain Services'
            try {
                foreach ($n in 'NTDS', 'Netlogon', 'KDC', 'W32Time', 'ADWS', 'DFSR') { Test-ServiceUp $n }
                if (Get-Command Get-SmbShare -ErrorAction SilentlyContinue) {
                    $shares = @(Get-SmbShare -Name SYSVOL, NETLOGON -ErrorAction SilentlyContinue)
                    Write-Check ($shares.Count -eq 2) 'The SYSVOL and NETLOGON shares exist'
                }
                if (Get-Command dcdiag.exe -ErrorAction SilentlyContinue) {
                    Say '  Running dcdiag /q (this can take a few minutes)...'
                    $dc = @(& dcdiag.exe /q 2>&1 | ForEach-Object { [string]$_ } | Where-Object { $_.Trim() })
                    if ($dc.Count -eq 0) { Say '  OK    dcdiag found no problems' }
                    else {
                        Add-Warning ("dcdiag reported {0} line(s):" -f $dc.Count)
                        $dc | Select-Object -First 25 | ForEach-Object { Say "        $_" }
                    }
                }
                $replDone = $false
                if (Get-Command Get-ADReplicationFailure -ErrorAction SilentlyContinue) {
                    try {
                        $fails = @(Get-ADReplicationFailure -Target $env:COMPUTERNAME -Scope Server -ErrorAction Stop)
                        $replDone = $true
                        if ($fails.Count -eq 0) { Say '  OK    No replication failures are recorded' }
                        else {
                            Add-Warning ("{0} replication failure(s):" -f $fails.Count)
                            $fails | Select-Object -First 10 | ForEach-Object { Say ("        partner {0}: {1} failure(s), last error {2}" -f $_.Partner, $_.FailureCount, $_.LastError) }
                        }
                    } catch { }
                }
                if (-not $replDone -and (Get-Command repadmin.exe -ErrorAction SilentlyContinue)) {
                    Say '  repadmin /replsummary:'
                    & repadmin.exe /replsummary 2>&1 | ForEach-Object { $l = ([string]$_).TrimEnd(); if ($l) { Say "    $l" } }
                }
                if (Get-Command netdom.exe -ErrorAction SilentlyContinue) {
                    Say '  Operations master (FSMO) roles:'
                    & netdom.exe query fsmo 2>&1 | ForEach-Object { $l = ([string]$_).TrimEnd(); if ($l) { Say "    $l" } }
                }
                Show-RecentErrors 'Directory Service'
                Show-RecentErrors 'DFS Replication'
            } catch { Add-Warning "The AD DS check failed: $($_.Exception.Message)" }
        }

        if ($roles['DNS']) {
            Say '--- DNS Server'
            try {
                Test-ServiceUp 'DNS'
                if (Get-Command Get-DnsServerZone -ErrorAction SilentlyContinue) {
                    $zones = @(Get-DnsServerZone -ErrorAction Stop | Where-Object { -not $_.IsAutoCreated })
                    Say ("  {0} zone(s):" -f $zones.Count)
                    $zones | Select-Object -First 15 | ForEach-Object {
                        Say ("    {0} ({1}{2}, dynamic update: {3})" -f $_.ZoneName, $_.ZoneType, $(if ($_.IsDsIntegrated) { ', AD-integrated' } else { '' }), $_.DynamicUpdate)
                    }
                    Write-Check (@($zones | Where-Object { $_.IsPaused }).Count -eq 0) 'No zone is paused'
                }
                if (Get-Command Get-DnsServerForwarder -ErrorAction SilentlyContinue) {
                    $fw = Get-DnsServerForwarder -ErrorAction SilentlyContinue
                    if ($fw -and $fw.IPAddress) { Say ("  Forwarders: {0}" -f (@($fw.IPAddress) -join ', ')) }
                    else                        { Say '  Forwarders: none (root hints are used)' }
                }
                $cs = Get-CimInstance Win32_ComputerSystem
                if ($cs.PartOfDomain) {
                    $ok = $true
                    try { [void](Resolve-DnsName -Name $cs.Domain -Server 127.0.0.1 -ErrorAction Stop) } catch { $ok = $false }
                    Write-Check $ok ("This server resolves {0} by itself" -f $cs.Domain)
                }
                Show-RecentErrors 'DNS Server'
            } catch { Add-Warning "The DNS check failed: $($_.Exception.Message)" }
        }

        if ($roles['DHCP']) {
            Say '--- DHCP Server'
            try {
                Test-ServiceUp 'DHCPServer'
                if (Get-Command Get-DhcpServerv4Scope -ErrorAction SilentlyContinue) {
                    $scopes = @(Get-DhcpServerv4Scope -ErrorAction Stop)
                    Say ("  {0} IPv4 scope(s)" -f $scopes.Count)
                    foreach ($sc in $scopes) {
                        $st = Get-DhcpServerv4ScopeStatistics -ScopeId $sc.ScopeId -ErrorAction SilentlyContinue
                        if ($st) { Write-Check ([double]$st.PercentageInUse -lt 90) ("Scope {0} ({1}): {2:N0}% of the addresses are in use" -f $sc.ScopeId, $sc.Name, [double]$st.PercentageInUse) }
                    }
                }
                if (Get-Command Get-DhcpServerInDC -ErrorAction SilentlyContinue) {
                    try {
                        $mine = @(Get-DhcpServerInDC -ErrorAction Stop | Where-Object { $_.DnsName -like "$env:COMPUTERNAME*" })
                        Write-Check ($mine.Count -gt 0) 'This DHCP server is authorized in Active Directory'
                    } catch { Say '  INFO  Authorization in Active Directory could not be checked.' }
                }
            } catch { Add-Warning "The DHCP check failed: $($_.Exception.Message)" }
        }

        if ($roles['IIS']) {
            Say '--- Web Server (IIS)'
            try {
                Test-ServiceUp 'W3SVC'
                Import-Module WebAdministration -ErrorAction Stop
                foreach ($site in @(Get-Website)) { Say ("  Site {0}: {1}" -f $site.Name, $site.State) }
                $notStarted = @(Get-Website | Where-Object { [string]$_.State -ne 'Started' })
                if ($notStarted.Count -gt 0) { Say ("  INFO  {0} site(s) are not started (this can be intentional)" -f $notStarted.Count) }
                $pools    = @(Get-ChildItem IIS:\AppPools -ErrorAction Stop)
                $badPools = @($pools | Where-Object { [string]$_.State -ne 'Started' })
                Write-Check ($badPools.Count -eq 0) ("{0} application pool(s), {1} not started" -f $pools.Count, $badPools.Count)
                foreach ($pool in $badPools) { Say ("        pool {0}: {1}" -f $pool.Name, $pool.State) }
                $logRoot = "$env:SystemDrive\inetpub\logs\LogFiles"
                if (Test-Path -LiteralPath $logRoot) { Say ("  IIS log folder size: {0}" -f (Format-Bytes (Get-FolderBytes $logRoot))) }
            } catch { Add-Warning "The IIS check failed: $($_.Exception.Message)" }
        }

        if ($roles['Hyper-V']) {
            Say '--- Hyper-V'
            try {
                Test-ServiceUp 'vmms'
                $vms = @(Get-VM -ErrorAction Stop)
                Say ("  {0} virtual machine(s)" -f $vms.Count)
                foreach ($vm in $vms) {
                    Say ("    {0}: {1}, {2}" -f $vm.Name, $vm.State, $vm.Status)
                    if ([string]$vm.State -eq 'Running' -and [string]$vm.PrimaryOperationalStatus -ne 'Ok') {
                        Add-Warning ("VM {0} is not healthy: {1}" -f $vm.Name, $vm.Status)
                    }
                }
                $oldChk = @(Get-VMSnapshot -VMName * -ErrorAction SilentlyContinue | Where-Object { $_.CreationTime -lt (Get-Date).AddDays(-7) })
                Write-Check ($oldChk.Count -eq 0) ("{0} checkpoint(s) older than 7 days" -f $oldChk.Count)
            } catch { Add-Warning "The Hyper-V check failed: $($_.Exception.Message)" }
        }

        if ($roles['Failover Clustering']) {
            Say '--- Failover Cluster'
            try {
                Test-ServiceUp 'ClusSvc'
                Import-Module FailoverClusters -ErrorAction Stop
                foreach ($n in @(Get-ClusterNode -ErrorAction Stop)) { Write-Check ([string]$n.State -eq 'Up') ("Node {0} is {1}" -f $n.Name, $n.State) }
                $grp = @(Get-ClusterGroup -ErrorAction Stop | Where-Object { [string]$_.State -ne 'Online' })
                Write-Check ($grp.Count -eq 0) ("{0} cluster group(s) are not online" -f $grp.Count)
                foreach ($g in $grp) { Say ("        {0}: {1}" -f $g.Name, $g.State) }
                $failedRes = @(Get-ClusterResource -ErrorAction SilentlyContinue | Where-Object { [string]$_.State -eq 'Failed' })
                Write-Check ($failedRes.Count -eq 0) ("{0} cluster resource(s) have failed" -f $failedRes.Count)
                $quorum = Get-ClusterQuorum -ErrorAction SilentlyContinue
                if ($quorum) { Say ("  Quorum type: {0}" -f $quorum.QuorumType) }
            } catch { Add-Warning "The cluster check failed: $($_.Exception.Message)" }
        }
        Say 'Role checks finished.'
    }

    # ---------------------------------------------------- 18. Storage health
    Invoke-Step -Id 18 -Name $Opt.StepNames[17] -Action {
        Say '--- Storage pools and virtual disks'
        $pools = @(Get-StoragePool -IsPrimordial $false -ErrorAction SilentlyContinue)
        if ($pools.Count -eq 0) { Say '  No Storage Spaces pools on this server.' }
        foreach ($pool in $pools) {
            Write-Check ([string]$pool.HealthStatus -eq 'Healthy') ("Pool {0}: {1} / {2}" -f $pool.FriendlyName, $pool.HealthStatus, $pool.OperationalStatus)
        }
        foreach ($vd in @(Get-VirtualDisk -ErrorAction SilentlyContinue)) {
            Write-Check ([string]$vd.HealthStatus -eq 'Healthy') ("Virtual disk {0} ({1}, {2}): {3} / {4}" -f $vd.FriendlyName, $vd.ResiliencySettingName, (Format-Bytes $vd.Size), $vd.HealthStatus, $vd.OperationalStatus)
        }
        Say '--- Physical disks'
        foreach ($d in @(Get-PhysicalDisk -ErrorAction SilentlyContinue)) {
            Write-Check ([string]$d.HealthStatus -eq 'Healthy') ("{0} ({1}, {2}): {3} / {4}" -f $d.FriendlyName, $d.MediaType, (Format-Bytes $d.Size), $d.HealthStatus, $d.OperationalStatus)
        }
        Say '--- Volumes'
        foreach ($v in @(Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveType -eq 'Fixed' })) {
            $label = if ($v.DriveLetter) { "$($v.DriveLetter):" } else { [string]$v.FileSystemLabel }
            Write-Check ([string]$v.HealthStatus -eq 'Healthy') ("Volume {0}: {1}" -f $label, $v.HealthStatus)
        }
        $jobs = @(Get-StorageJob -ErrorAction SilentlyContinue | Where-Object { [string]$_.JobState -ne 'Completed' })
        if ($jobs.Count -gt 0) {
            Say ("  INFO  {0} storage job(s) are running (for example a repair or rebuild):" -f $jobs.Count)
            foreach ($j in $jobs) { Say ("        {0}: {1}%" -f $j.Name, $j.PercentComplete) }
        }
    }

    # ---------------------------------------------------- 19. Server cleanup
    Invoke-Step -Id 19 -Name $Opt.StepNames[18] -Action {
        if ($Opt.ServerCleanComponents) {
            if ($Opt.Preview) {
                Say 'Preview: analyzing the component store (nothing is removed):'
                DISM /Online /Cleanup-Image /AnalyzeComponentStore
            } else {
                Say 'Cleaning the Windows component store (DISM /StartComponentCleanup, without /ResetBase)...'
                DISM /Online /Cleanup-Image /StartComponentCleanup
                if ($LASTEXITCODE -ne 0) { throw "DISM StartComponentCleanup exited with code $LASTEXITCODE" }
            }
        }
        if ($Opt.ServerCleanWuCache) { Clear-WuDownloadCache }
        if ($Opt.ServerCleanTemp) {
            $days   = [math]::Max(1, [int]$Opt.TempDays)
            $cutoff = (Get-Date).AddDays(-$days)
            foreach ($path in @($env:TEMP, "$env:SystemRoot\Temp") | Select-Object -Unique) {
                if (-not $path -or -not (Test-SafeTempRoot $path)) { continue }
                Say "Scanning $path (files created AND modified more than $days day(s) ago)..."
                Remove-Scanned (Get-TempContents -Root $path -Cutoff $cutoff) $cutoff
            }
        }
        $iisDays = [int]$Opt.IisLogDays
        if ($iisDays -gt 0) {
            # Only *.log files inside the W3SVC/FTPSVC site folders and HTTPERR. Event logs (.evtx) are never touched.
            $iisCut = (Get-Date).AddDays(-$iisDays)
            $bases  = New-Object System.Collections.Generic.List[string]
            $bases.Add("$env:SystemDrive\inetpub\logs\LogFiles")
            try {
                Import-Module WebAdministration -ErrorAction Stop
                foreach ($site in @(Get-Website)) {
                    $dir = [Environment]::ExpandEnvironmentVariables([string]$site.logFile.directory)
                    if ($dir -and -not $bases.Contains($dir)) { $bases.Add($dir) }
                }
            } catch { }
            $targets = New-Object System.Collections.Generic.List[string]
            foreach ($b in $bases) {
                if (-not (Test-PlainFolder $b)) { continue }
                foreach ($d in @(Get-ChildItem -LiteralPath $b -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(W3SVC|FTPSVC)\d+$' })) {
                    if (Test-PlainFolder $d.FullName) { $targets.Add($d.FullName) }
                }
            }
            $httperr = "$env:SystemRoot\System32\LogFiles\HTTPERR"
            if (Test-PlainFolder $httperr) { $targets.Add($httperr) }
            Say ("IIS and HTTP.sys logs older than {0} days ({1} folder(s)):" -f $iisDays, $targets.Count)
            $merged = [pscustomobject]@{
                Files = (New-Object System.Collections.Generic.List[System.IO.FileInfo])
                Dirs  = (New-Object System.Collections.Generic.List[System.IO.DirectoryInfo])
                Links = 0
            }
            foreach ($t in $targets) {
                $one = Get-TempContents -Root $t -Cutoff $iisCut
                foreach ($f in $one.Files) { if ($f.Extension -eq '.log') { $merged.Files.Add($f) } }
                $merged.Links += $one.Links
            }
            Remove-Scanned $merged ([datetime]::MinValue)
        }
    }

    # ---------------------------------------------------- Summary
    $freed   = (Get-FreeSpaceGB) - $freeBefore
    $elapsed = (Get-Date) - $startTime
    $elapsedText = $elapsed.ToString('hh\:mm\:ss')

    if (-not $Opt.Preview) { try {
        New-Item -ItemType Directory -Path (Split-Path $Opt.HistoryFile) -Force | Out-Null
        # The CSV gained an "Os" column: keep an older file aside so the columns stay aligned.
        if (Test-Path -LiteralPath $Opt.HistoryFile) {
            $header = Get-Content -LiteralPath $Opt.HistoryFile -TotalCount 1
            if ($header -notmatch '"Os"') {
                Move-Item -LiteralPath $Opt.HistoryFile -Destination ($Opt.HistoryFile -replace '\.csv$', '_before-os-column.csv') -Force
            }
        }
        $State.Results | Export-Csv -Path $Opt.HistoryFile -Append -NoTypeInformation -Encoding UTF8
    } catch {
        Say "WARNING: could not write the history file: $($_.Exception.Message)"
    } }

    Say ""
    Say "================ SUMMARY ================"
    foreach ($r in $State.Results) {
        if ($r.Message -ne 'Not selected') {
            Say ("{0,-38} {1,-8} {2}  {3}" -f $r.Step, $r.Status, $r.Duration, $r.Message)
        }
    }
    Say ("Total time : {0}" -f $elapsedText)
    Say ("Space freed: {0:N2} GB" -f $freed)
    if ($State.Warnings -gt 0) { Say ("Warnings   : {0} (look for WARN lines above)" -f $State.Warnings) }

    $failedCount   = @($State.Results | Where-Object { $_.Status -eq 'Failed' }).Count
    $rebootPending = [bool]((Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
                            (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'))
    $reportPath = ''
    if (-not $Opt.Preview -and $Opt.ReportFile) {
        try {
            Write-HtmlReport -FreeBefore $freeBefore -FreeAfter ($freeBefore + $freed) -Elapsed $elapsedText -RebootPending $rebootPending
            $reportPath = [string]$Opt.ReportFile
            Say "Report saved: $reportPath"
        } catch {
            Say "WARNING: could not write the report: $($_.Exception.Message)"
        }
    }
    Say ("@@DONE|{0:N2}|{1}|{2}|{3}|{4}|{5}|{6}|{7}|{8}" -f $freed, $elapsedText, $failedCount, $rebootPending, $State.Cancelled, $State.Aborted, $State.Unavail, $reportPath, $State.Warnings)
}

# =============================================================================
#  SHARED BY THE WINDOW, THE TEXT MENU AND -Schedule
# =============================================================================
$script:TaskName = 'PC Maintenance (weekly)'

function Get-MaintTask { return (Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue) }

function Remove-MaintTask { Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false -ErrorAction Stop }

# Creates or replaces the weekly task. On a PC it runs as you (only when you are logged on),
# on a server as SYSTEM (also when nobody is logged on). $AllowChanges adds -MaintenanceWindow.
function Install-MaintTask([string]$Day, [datetime]$Time, [string]$PresetName, [bool]$AllowChanges) {
    # The task runs a copy kept in Program Files (writable by administrators only),
    # never a file from a folder an ordinary user could change.
    if (-not $PSCommandPath) { throw 'The script path is unknown.' }
    $destDir = Join-Path $env:ProgramFiles 'PCMaintenance'
    New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    $dest = Join-Path $destDir 'Run-Maintenance.ps1'
    if ($PSCommandPath -ne $dest) { Copy-Item -LiteralPath $PSCommandPath -Destination $dest -Force }
    $arg = "-NoProfile -ExecutionPolicy Bypass -File `"$dest`" -Preset $PresetName -SilentWinget"
    if ($AllowChanges) { $arg += ' -MaintenanceWindow' }
    $action   = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
    $trigger  = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $Day -At ([datetime]::Today.Add($Time.TimeOfDay))
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 6)
    if ($RunMode -eq 'Server') {
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    } else {
        $settings.DisallowStartIfOnBatteries = $true    # laptops only run it on the charger
        $settings.StopIfGoingOnBatteries     = $false   # the tool checks power itself between steps
        $who       = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        $principal = New-ScheduledTaskPrincipal -UserId $who -LogonType Interactive -RunLevel Highest
    }
    Register-ScheduledTask -TaskName $script:TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
}

# Turns off console QuickEdit so clicking in the console can't pause a run
function Disable-QuickEdit {
    try {
        if (-not ('Native.ConsoleMode' -as [type])) {
            Add-Type -Namespace Native -Name ConsoleMode -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int nStdHandle);
[DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
[DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
'@
        }
        $hIn = [Native.ConsoleMode]::GetStdHandle(-10)
        [uint32]$consoleMode = 0
        if ([Native.ConsoleMode]::GetConsoleMode($hIn, [ref]$consoleMode)) {
            $newMode = [uint32](($consoleMode -band ([uint32]::MaxValue - 0x40)) -bor 0x80)
            [void][Native.ConsoleMode]::SetConsoleMode($hIn, $newMode)
        }
    } catch { }
}

# Runs the engine in this console and writes the log. Returns ExitCode and Finished.
#   0 = fine, 1 = warnings (stopped, skipped steps or WARN lines), 2 = failures
function Invoke-ConsoleRun($RunOpt) {
    Disable-QuickEdit
    Remove-Item -LiteralPath $CancelFile -Force -ErrorAction SilentlyContinue
    $logFile = Open-RunLog
    $script:DoneInfo = $null
    Write-Host "PC Maintenance - log file: $logFile"
    try {
        & $Engine $RunOpt | ForEach-Object {
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
                if ($line -match '^\s+WARN\s') { Write-Host $line -ForegroundColor Yellow } else { Write-Host $line }
            }
        }
    } finally {
        Close-RunLog
    }

    $exitCode = 2
    $finished = $false
    if ($script:DoneInfo) {
        $d = $script:DoneInfo
        $warnings = 0
        if ($d.Count -gt 9) { $warnings = [int]$d[9] }
        $finished = ($d[5] -ne 'True' -and $d[6] -ne 'True')
        if ([int]$d[3] -gt 0 -or $d[6] -eq 'True') { $exitCode = 2 }
        elseif ($d[5] -eq 'True' -or [int]$d[7] -gt 0 -or $warnings -gt 0) { $exitCode = 1 }
        else { $exitCode = 0 }
        if ($d[4] -eq 'True') { Write-Host "A reboot is pending." -ForegroundColor Yellow }
        if ($warnings -gt 0)  { Write-Host "$warnings warning(s) found - see the WARN lines or the report." -ForegroundColor Yellow }
        if ($d.Count -gt 8 -and $d[8]) { Write-Host "Report: $($d[8])" }
    }
    return [pscustomobject]@{ ExitCode = $exitCode; Finished = $finished }
}

# ----- text menu (Server Core has no desktop for the window; -Menu asks for it on purpose)
function Read-YesNo([string]$Prompt) {
    $a = (Read-Host "$Prompt [y/N]").Trim().ToLower()
    return ($a -eq 'y' -or $a -eq 'yes')
}

function Start-MenuRun([int[]]$Ids, [bool]$AsPreview) {
    if ($Ids.Count -eq 0) { Write-Host 'Nothing to run.' -ForegroundColor Yellow; return }
    $o = New-RunOptions
    $o.Steps   = [int[]]$Ids
    $o.Preview = $AsPreview
    $needs = @($Ids | Where-Object { $Gated -contains $_ -and -not ($_ -eq 7 -and $o.OptimizeAction -eq 'Analyze') })
    if (-not $AsPreview -and -not $o.MaintenanceWindow -and $needs.Count -gt 0) {
        Write-Host ("Step(s) {0} change this server." -f ($needs -join ', ')) -ForegroundColor Yellow
        Write-Host 'Only continue in a planned maintenance window, with a recent backup.' -ForegroundColor Yellow
        if ((Read-Host 'Type YES if this is a maintenance window') -ceq 'YES') { $o.MaintenanceWindow = $true }
        else { Write-Host 'Those steps will be skipped.' }
    }
    $r = @(Invoke-ConsoleRun $o)[-1]
    Write-Host ''
    Write-Host "Finished. The exit code would be $($r.ExitCode) (0 fine, 1 warnings, 2 failures)."
    [void](Read-Host 'Press Enter to go back to the menu')
}

function Show-ConsoleMenu {
    while ($true) {
        Write-Host ''
        Write-Host "PC Maintenance - $ModeLabel mode" -ForegroundColor Cyan
        Write-Host $SystemInfo.Text
        if ($RunMode -eq 'Server') { Write-Host ' 1  Run the server check (read-only)' } else { Write-Host ' 1  Run the default steps' }
        Write-Host ' 2  Choose the steps to run'
        Write-Host ' 3  Preview what cleanup would remove'
        Write-Host ' 4  Schedule a weekly run'
        Write-Host ' 5  Remove the weekly schedule'
        Write-Host ' 6  Show where logs and reports are saved'
        Write-Host ' Q  Quit'
        $choice = (Read-Host 'Choose').Trim().ToLower()
        switch ($choice) {
            '1' {
                if ($RunMode -eq 'Server') { $ids = @($Presets.ServerCheck) } else { $ids = @($ModeDefaultIds) }
                Start-MenuRun @($ids | Where-Object { $ModeStepIds -contains $_ }) $false
            }
            '2' {
                foreach ($si in $StepInfo) {
                    $id = [int]$si.Id
                    if ($ModeStepIds -notcontains $id) { continue }
                    $tag = ''
                    if ($Unavailable.ContainsKey($id))   { $tag = '   [not available: ' + $Unavailable[$id] + ']' }
                    elseif ($Gated -contains $id)        { $tag = '   [needs a maintenance window]' }
                    elseif ($si.Risk -eq 'Deletes')      { $tag = '   [deletes files]' }
                    Write-Host ('{0,3}  {1}{2}' -f $id, $si.Title, $tag)
                }
                $txt = Read-Host 'Steps to run, for example 8,15-18 (empty = back)'
                if ($txt.Trim()) {
                    $sel = Resolve-StepSelection $txt $StepInfo.Count
                    if (-not $sel) { Write-Host 'That is not a valid list of step numbers.' -ForegroundColor Red }
                    else           { Start-MenuRun @($sel | Where-Object { $ModeStepIds -contains $_ }) $false }
                }
            }
            '3' {
                Start-MenuRun @($PreviewIds | Where-Object { $ModeStepIds -contains $_ }) $true
            }
            '4' {
                $day = (Read-Host 'Day of the week [Sunday]').Trim()
                if (-not $day) { $day = 'Sunday' }
                $dayOk = @([System.Enum]::GetNames([System.DayOfWeek]) | Where-Object { $_ -ieq $day })
                if ($dayOk.Count -eq 0) { Write-Host 'That is not a day of the week (use English names).' -ForegroundColor Red; break }
                $time = (Read-Host 'Time as HH:mm [03:00]').Trim()
                if (-not $time) { $time = '03:00' }
                try { $when = [datetime]::ParseExact($time, 'HH:mm', [System.Globalization.CultureInfo]::InvariantCulture) }
                catch { Write-Host 'That is not a time like 03:00.' -ForegroundColor Red; break }
                if ($RunMode -eq 'Server') { $def = 'ServerCheck' } else { $def = 'WeeklySafe' }
                $pre = (Read-Host ("What to run: {0} [{1}]" -f (@($Presets.Keys) -join ', '), $def)).Trim()
                if (-not $pre) { $pre = $def }
                $preOk = @($Presets.Keys | Where-Object { $_ -ieq $pre })
                if ($preOk.Count -eq 0) { Write-Host 'That is not one of the presets.' -ForegroundColor Red; break }
                $allow = Read-YesNo 'Allow steps that change the system in the scheduled run (a standing maintenance window)?'
                try {
                    Install-MaintTask $dayOk[0] $when $preOk[0] $allow
                    Write-Host "Scheduled '$($script:TaskName)' every $($dayOk[0]) at $time (preset $($preOk[0]))." -ForegroundColor Green
                } catch { Write-Host "The schedule could not be created: $($_.Exception.Message)" -ForegroundColor Red }
            }
            '5' {
                try { Remove-MaintTask; Write-Host 'The weekly schedule was removed.' -ForegroundColor Green }
                catch { Write-Host 'There was no schedule to remove.' }
            }
            '6' { Write-Host "Logs and reports are saved in: $LogDir" }
            'q' { return }
            default { Write-Host 'Please type a number from the list, or Q.' }
        }
    }
}

# =============================================================================
#  -Schedule / -RemoveSchedule (no window, no run)
# =============================================================================
if ($Schedule -or $RemoveSchedule) {
    try {
        if ($RemoveSchedule) {
            Remove-MaintTask
            Write-Host 'The weekly schedule was removed.'
        } else {
            if ($Preset) { $presetName = $Preset } elseif ($RunMode -eq 'Server') { $presetName = 'ServerCheck' } else { $presetName = 'WeeklySafe' }
            $when = [datetime]::ParseExact($ScheduleTime, 'HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)
            Install-MaintTask $ScheduleDay $when $presetName ([bool]$MaintenanceWindow)
            Write-Host ("Scheduled '{0}' every {1} at {2} (preset {3}{4})." -f $script:TaskName, $ScheduleDay, $ScheduleTime, $presetName, $(if ($MaintenanceWindow) { ', maintenance window allowed' } else { '' }))
        }
        exit 0
    } catch {
        Write-Host "The schedule could not be changed: $($_.Exception.Message)" -ForegroundColor Red
        exit 2
    }
}

# =============================================================================
#  UNATTENDED MODE (no window): -All, -Steps, -Preset, -Preview, -Skip...
# =============================================================================
if ($headless) {
    $maxStep = $StepInfo.Count
    $skipped = @()
    if ($SkipRestorePoint) { $skipped += 1 }
    if ($SkipSFC)          { $skipped += 5 }
    if ($SkipDefender)     { $skipped += 6 }

    if ($Steps -and $Steps.Trim() -match '^(a|all|\*)$') {
        $selected = $ModeDefaultIds
    } elseif ($Steps) {
        $selected = Resolve-StepSelection $Steps $maxStep
        if (-not $selected) {
            Write-Host "Invalid -Steps value '$Steps'. Use numbers 1-$maxStep, e.g. -Steps `"1,3,5-6`"." -ForegroundColor Red
            Start-Sleep -Seconds 5
            exit 2
        }
    } elseif ($Preset) {
        $selected = @($Presets[$Preset])
    } else {
        $selected = $ModeDefaultIds
    }
    if ($Preview) { $selected = @($selected | Where-Object { $PreviewIds -contains $_ }) }
    $notInMode = @($selected | Where-Object { $ModeStepIds -notcontains $_ })
    if ($notInMode.Count -gt 0) {
        Write-Host "Ignoring step(s) $($notInMode -join ', '): not available in $RunMode mode." -ForegroundColor Yellow
    }
    $selected = @($selected | Where-Object { $ModeStepIds -contains $_ -and $skipped -notcontains $_ })
    if ($selected.Count -eq 0) {
        Write-Host "Nothing to do." -ForegroundColor Yellow
        exit
    }

    $runOpt = New-RunOptions
    $runOpt.Steps        = [int[]]$selected
    $runOpt.WingetSilent = [bool]$SilentWinget
    $runOpt.IgnorePower  = [bool]$IgnorePower
    $runOpt.Preview      = [bool]$Preview
    $needsWindow = @($selected | Where-Object { $Gated -contains $_ -and -not ($_ -eq 7 -and $runOpt.OptimizeAction -eq 'Analyze') })
    if ($needsWindow.Count -gt 0 -and -not $runOpt.MaintenanceWindow -and -not $Preview) {
        Write-Host "Step(s) $($needsWindow -join ', ') change the server and will be skipped unless you add -MaintenanceWindow." -ForegroundColor Yellow
    }

    $res = @(Invoke-ConsoleRun $runOpt)[-1]
    if ($Reboot -and $res.Finished) {
        Write-Host "Restarting in 30 seconds (run 'shutdown /a' to cancel)..."
        & shutdown.exe /r /t 30 /c "PC Maintenance finished - restarting"
    }
    exit $res.ExitCode
}

# =============================================================================
#  TEXT MENU: Server Core has no desktop, so the window cannot open there
# =============================================================================
if ($Menu -or $SystemInfo.InstallType -eq 'Server Core') {
    Show-ConsoleMenu
    exit 0
}

# =============================================================================
#  THE WINDOW
# =============================================================================
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Sharp text on high-DPI screens. This must run before the first window exists.
try {
    Add-Type -Namespace Native -Name Dpi -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
'@
    [void][Native.Dpi]::SetProcessDPIAware()
} catch { }
try {
    $dpiGraphics  = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
    $script:Scale = [math]::Max(1.0, [double]$dpiGraphics.DpiX / 96.0)
    $dpiGraphics.Dispose()
} catch { $script:Scale = 1.0 }

# Sizes in "96 dpi pixels" become real pixels here.
function S([double]$n) { return [int][math]::Round($n * $script:Scale) }
function Sz([double]$w, [double]$h) { return New-Object System.Drawing.Size -ArgumentList (S $w), (S $h) }
function Pd([double]$l, [double]$t, [double]$r, [double]$b) { return New-Object System.Windows.Forms.Padding -ArgumentList (S $l), (S $t), (S $r), (S $b) }
function Rgb([int]$r, [int]$g, [int]$b) { return [System.Drawing.Color]::FromArgb($r, $g, $b) }

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

    # ----- remembered settings (language, theme, ticked steps, dropdown choices)
    $script:SettingsFile = Join-Path (Join-Path $env:APPDATA 'PCMaintenance') 'settings.json'

    function Read-Settings {
        try {
            if (Test-Path -LiteralPath $script:SettingsFile) {
                return (Get-Content -LiteralPath $script:SettingsFile -Raw -ErrorAction Stop | ConvertFrom-Json)
            }
        } catch { }
        return $null
    }

    function Get-Setting([string]$Name, $Default) {
        $st = $script:Settings
        if ($st -and ($st.PSObject.Properties.Name -contains $Name) -and $null -ne $st.$Name) { return $st.$Name }
        return $Default
    }

    function Save-Settings {
        try {
            $ticked = @()
            $opts   = @{}
            foreach ($sid in $script:StepCtl.Keys) {
                if ($script:StepCtl[$sid].Check.Checked) { $ticked += [int]$sid }
                foreach ($c in $script:StepCtl[$sid].Combos) {
                    $opts[[string]$c.Tag.Key] = [string]$c.Tag.Values[$c.SelectedIndex]
                }
            }
            $data = @{
                Language = $script:Lang
                Theme    = $script:Theme
                Advanced = [bool]$script:UI.chkAdv.Checked
                Steps    = $ticked
                Options  = $opts
            }
            # window size in 96-dpi units (RestoreBounds is the normal size even while maximized)
            try {
                $rb = $script:UI.form.RestoreBounds
                $data.Width     = [int]($rb.Width  / $script:Scale)
                $data.Height    = [int]($rb.Height / $script:Scale)
                $data.Maximized = [bool]($script:UI.form.WindowState -eq 'Maximized')
            } catch { }
            New-Item -ItemType Directory -Path (Split-Path $script:SettingsFile) -Force | Out-Null
            ($data | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $script:SettingsFile -Encoding UTF8
        } catch { }
    }

    # Puts the saved ticks and dropdown choices back into the freshly built window
    function Restore-Settings {
        $st = $script:Settings
        if (-not $st) { return }
        if ($st.PSObject.Properties.Name -contains 'Steps') {
            $saved = @($st.Steps | ForEach-Object { [int]$_ })
            foreach ($sid in $script:StepCtl.Keys) {
                if ($script:StepCtl[$sid].Check.Enabled) { $script:StepCtl[$sid].Check.Checked = ($saved -contains [int]$sid) }
            }
        }
        if ($st.PSObject.Properties.Name -contains 'Options' -and $st.Options) {
            foreach ($sid in $script:StepCtl.Keys) {
                foreach ($c in $script:StepCtl[$sid].Combos) {
                    $prop = $st.Options.PSObject.Properties[[string]$c.Tag.Key]
                    if (-not $prop) { continue }
                    for ($i = 0; $i -lt $c.Tag.Values.Count; $i++) {
                        if ([string]$c.Tag.Values[$i] -eq [string]$prop.Value) { $c.SelectedIndex = $i; break }
                    }
                }
            }
        }
        $script:UI.chkAdv.Checked = [bool](Get-Setting 'Advanced' $false)
    }

    # ----- translations: English text -> Dutch. The log files stay English.
    #       (Dutch text here is ASCII only on purpose, see CLAUDE.md.)
    $script:NL = @{
        'Changes the system' = 'Wijzigt het systeem'
        'Check and report' = 'Controleren en rapporteren'
        'Clean up' = 'Opschonen'
        'Deletes files' = 'Verwijdert bestanden'
        'Protect and update' = 'Beveiligen en bijwerken'
        'Quick select:' = 'Snelle selectie:'
        'Read-only' = 'Alleen lezen'
        'Repair and optimize' = 'Herstellen en optimaliseren'
        'Step {0}' = 'Stap {0}'
        '1 to 3 minutes' = '1 tot 3 minuten'
        '180 days' = '180 dagen'
        '365 days' = '365 dagen'
        '90 days (recommended)' = '90 dagen (aanbevolen)'
        'Allow changes in the scheduled run (maintenance window)' = 'Wijzigingen toestaan in de geplande run (onderhoudsvenster)'
        'Analyze only (nothing is changed, recommended on a server)' = 'Alleen analyseren (er wordt niets gewijzigd, aanbevolen op een server)'
        'Check storage pools, disks and volumes' = 'Opslagpools, schijven en volumes controleren'
        'Check the backups' = 'De back-ups controleren'
        'Check the health of this server' = 'Gezondheid van deze server controleren'
        'Check the installed server roles' = ('De ge' + [char]0xEF + 'nstalleerde serverrollen controleren')
        'Clean up this server' = 'Deze server opschonen'
        'Cleans the Windows component store (without /ResetBase), the Windows Update download cache, old temp files and old IIS logs. Event logs are never touched. Needs a maintenance window and is off by default.' = 'Ruimt de Windows-componentenopslag op (zonder /ResetBase), de downloadcache van Windows Update, oude tijdelijke bestanden en oude IIS-logs. Gebeurtenislogs blijven altijd ongemoeid. Vereist een onderhoudsvenster en staat standaard uit.'
        'Component store (DISM):' = 'Componentenopslag (DISM):'
        'Delete IIS logs older than:' = 'IIS-logs wissen die ouder zijn dan:'
        'Finds the installed roles and checks them: Active Directory (dcdiag, replication, SYSVOL), DNS, DHCP, IIS, Hyper-V and failover clustering. Report only.' = ('Zoekt de ge' + [char]0xEF + 'nstalleerde rollen en controleert ze: Active Directory (dcdiag, replicatie, SYSVOL), DNS, DHCP, IIS, Hyper-V en failover clustering. Alleen een rapport.')
        'Finished, with warnings' = 'Klaar, met waarschuwingen'
        'Health of Storage Spaces pools and virtual disks, physical disks and volumes, and running repair jobs. Report only.' = 'Gezondheid van Storage Spaces-pools en virtuele schijven, fysieke schijven en volumes, en lopende herstelopdrachten. Alleen een rapport.'
        'Is this a maintenance window?' = 'Is dit een onderhoudsvenster?'
        'Leave IIS logs alone' = 'IIS-logs met rust laten'
        'Maintenance window' = 'Onderhoudsvenster'
        'Old temp files:' = 'Oude tijdelijke bestanden:'
        'Only continue in a planned maintenance window, with a recent backup.' = 'Ga alleen verder in een gepland onderhoudsvenster, met een recente back-up.'
        'Optimize: TRIM for SSDs, defrag for hard disks (recommended on a PC)' = 'Optimaliseren: TRIM voor SSD-schijven, defragmenteren voor harde schijven (aanbevolen op een pc)'
        'Run the checks by itself every week, as SYSTEM, also when nobody is logged on. If the server was off at that time it runs as soon as possible after.' = 'Laat de controles elke week vanzelf lopen, als SYSTEM, ook als er niemand is aangemeld. Stond de server dan uit, dan loopt het zo snel mogelijk daarna.'
        'Server check' = 'Servercontrole'
        'Server check (recommended): read-only health checks of the server, backups, roles and storage' = 'Servercontrole (aanbevolen): alleen-lezen controles van de server, back-ups, rollen en opslag'
        'The preview works for steps 2, 4, 10 and 19. Tick at least one of them.' = ('Het voorbeeld werkt voor stap 2, 4, 10 en 19. Vink er minstens ' + [char]0xE9 + [char]0xE9 + 'n aan.')
        'These steps change this server: {0}.' = 'Deze stappen wijzigen deze server: {0}.'
        'Uptime, pending restart, free disk space, automatic services that are not running, critical events, the last installed update, expiring certificates and time synchronization. Report only.' = ('Uptime, openstaande herstart, vrije schijfruimte, automatische services die niet draaien, kritieke gebeurtenissen, de laatst ge' + [char]0xEF + 'nstalleerde update, vervallende certificaten en tijdsynchronisatie. Alleen een rapport.')
        'Weekly safe: update scan, virus scan, drive analysis, health and security checks' = 'Veilig, wekelijks: updatescan, virusscan, schijfanalyse, gezondheids- en beveiligingscontroles'
        'What to do:' = 'Wat te doen:'
        'Windows Server Backup: the last successful backup and its result. Also checks that the VSS writers are stable and shows the shadow storage. Report only.' = 'Windows Server Backup: de laatste geslaagde back-up en het resultaat ervan. Controleert ook of de VSS-writers stabiel zijn en toont de schaduwopslag. Alleen een rapport.'
        '{0} warning(s) found - see the WARN lines in the technical details or the report.' = '{0} waarschuwing(en) gevonden - zie de WARN-regels in de technische details of het rapport.'
        ' - Windows updates will be downloaded and installed (no automatic restart)' = (' - Windows-updates worden gedownload en ge' + [char]0xEF + 'nstalleerd (zonder automatische herstart)')
        ' - browser, Windows Update and Delivery Optimization caches will be cleared (you stay signed in)' = ' - de caches van browsers, Windows Update en Delivery Optimization worden gewist (je blijft aangemeld)'
        ' - keep the charger connected (laptops)' = ' - laat de lader aangesloten (laptops)'
        ' - save your work' = ' - sla je werk op'
        ' - the Recycle Bin will be emptied for good' = ' - de Prullenbak wordt definitief geleegd'
        '1 day' = '1 dag'
        '1 to 10 minutes' = '1 tot 10 minuten'
        '1 to 15 minutes' = '1 tot 15 minuten'
        '1 to 30 minutes' = '1 tot 30 minuten'
        '1 to 5 minutes' = '1 tot 5 minuten'
        '10 to 30 minutes' = '10 tot 30 minuten'
        '2 (recommended)' = '2 (aanbevolen)'
        '2 to 10 minutes' = '2 tot 10 minuten'
        '2 to 20 minutes' = '2 tot 20 minuten'
        '3 days (recommended)' = '3 dagen (aanbevolen)'
        '3 to 20 minutes' = '3 tot 20 minuten'
        '30 days' = '30 dagen'
        '5 to 20 minutes' = '5 tot 20 minuten'
        '7 days' = '7 dagen'
        'A weekly run is scheduled. Next run: {0}' = 'Er staat een wekelijkse run gepland. Volgende run: {0}'
        'All done!' = 'Klaar!'
        'All drives (recommended)' = 'Alle schijven (aanbevolen)'
        'All pins were removed.' = 'Alle vastgezette software is weer vrijgegeven.'
        'All programs with an update will be updated.' = 'Alle software met een update wordt bijgewerkt.'
        'All users (registry)' = 'Alle gebruikers (register)'
        'All users Startup folder' = 'Opstartmap voor alle gebruikers'
        'All users, 32-bit (registry)' = 'Alle gebruikers, 32-bit (register)'
        'Apply' = 'Toepassen'
        'Back to options' = 'Terug naar opties'
        'Before you continue:' = 'Voordat je verdergaat:'
        'Browser caches:' = 'Browsercaches:'
        'Cancel' = 'Annuleren'
        'Charger check:' = 'Laadercontrole:'
        'Charger needed' = 'Lader nodig'
        'Check and repair Windows system files' = 'Windows-systeembestanden controleren en herstellen'
        'Check for Windows updates' = 'Zoeken naar Windows-updates'
        'Check hardware health' = 'Gezondheid van de hardware controleren'
        'Check the health of my disks' = 'Gezondheid van mijn schijven controleren'
        'Checks Defender, the firewall, BitLocker, Secure Boot, the TPM, SMBv1 and Remote Desktop. Report only: nothing is changed.' = 'Controleert Defender, de firewall, BitLocker, Secure Boot, de TPM, SMBv1 en Extern bureaublad. Alleen een rapport: er wordt niets gewijzigd.'
        'Choose which programs to update' = 'Kies welke software wordt bijgewerkt'
        'Choose which programs to update...' = 'Kies welke software wordt bijgewerkt...'
        'Cleanup strength:' = 'Opschoonniveau:'
        'Clear extra caches (Windows Update, Delivery Optimization, browsers)' = 'Extra caches wissen (Windows Update, Delivery Optimization, browsers)'
        'Clear temporary files and empty the Recycle Bin' = 'Tijdelijke bestanden wissen en de Prullenbak legen'
        'Close' = 'Sluiten'
        'Command' = 'Opdracht'
        'Create a safety restore point' = 'Een veiligheidsherstelpunt maken'
        'Create or update' = 'Maken of bijwerken'
        'DISM only' = 'Alleen DISM'
        'Dark mode' = 'Donkere modus'
        'Day:' = 'Dag:'
        'Deep clean' = 'Grondig opschonen'
        'Deep clean: restore point, updates, cleanup, repair, caches' = 'Grondig opschonen: herstelpunt, updates, opschonen, herstel, caches'
        'Delete temp files older than:' = 'Tijdelijke bestanden wissen die ouder zijn dan:'
        'Deletes the Windows search index so it is built again. Helps when search finds nothing.' = 'Verwijdert de Windows-zoekindex zodat die opnieuw wordt opgebouwd. Helpt als zoeken niets vindt.'
        'Delivery Optimization cache:' = 'Delivery Optimization-cache:'
        'Do nothing' = 'Niets doen'
        'Do you want to cancel the restart?' = 'Wil je de herstart annuleren?'
        'Done' = 'Klaar'
        'Download and install them (no automatic restart)' = 'Downloaden en installeren (geen automatische herstart)'
        'Empty it (default)' = 'Legen (standaard)'
        'Everything except the slow repair' = 'Alles behalve het trage herstel'
        'Failed' = 'Mislukt'
        'Finished, but some steps had problems' = 'Klaar, maar bij sommige stappen waren er problemen'
        'Fixes wrong or blank icons. The desktop and taskbar restart for a moment.' = 'Herstelt verkeerde of lege pictogrammen. Het bureaublad en de taakbalk herstarten heel even.'
        'Free up disk space' = 'Schijfruimte vrijmaken'
        'Friday' = 'Vrijdag'
        'Full repair: DISM + SFC (recommended)' = 'Volledig herstel: DISM + SFC (aanbevolen)'
        'Full scan (can take hours)' = 'Volledige scan (kan uren duren)'
        'Gentle (also keeps old driver packages and crash dumps)' = 'Voorzichtig (bewaart ook oude stuurprogrammapakketten en crashdumps)'
        'History' = 'Geschiedenis'
        'History...' = 'Geschiedenis...'
        'Installer windows:' = 'Installatievensters:'
        'Installs updates for your installed programs with winget, the update tool built into Windows. Some installers may open their own window.' = ('Installeert updates voor je ge' + [char]0xEF + 'nstalleerde software met winget, het updateprogramma dat in Windows zit. Sommige installaties openen een eigen venster.')
        'Keeps SSDs fast (TRIM) and tidies hard disks (defrag). Windows picks the right method for every drive.' = 'Houdt SSD-schijven snel (TRIM) en ruimt harde schijven op (defragmenteren). Windows kiest voor elke schijf de juiste methode.'
        'Laptop must be plugged in (recommended)' = 'Laptop moet aan de lader (aanbevolen)'
        'Leave it alone' = 'Met rust laten'
        'Lets you undo system changes if something goes wrong. Keeps your last restore points and removes older ones made by this tool.' = 'Laat je systeemwijzigingen ongedaan maken als er iets misgaat. Bewaart je laatste herstelpunten en verwijdert oudere die dit programma heeft gemaakt.'
        'Light mode' = 'Lichte modus'
        'Lists the largest folders, the hibernation and page files, the Windows component store and old user profiles. Report only: nothing is deleted.' = 'Toont de grootste mappen, het slaapstand- en wisselbestand, de Windows-componentenopslag en oude gebruikersprofielen. Alleen een rapport: er wordt niets verwijderd.'
        'Looks for Windows updates with the Windows Update service (and your WSUS server, if you have one). By default it only lists them; in the advanced options you can let it install them. Driver updates are only reported. It never restarts your PC.' = 'Zoekt Windows-updates via de Windows Update-service (en je WSUS-server, als je er een hebt). Standaard worden ze alleen getoond; in de geavanceerde opties kun je ze laten installeren. Stuurprogramma-updates worden alleen gemeld. Je pc wordt nooit herstart.'
        'Maintenance is finished. Your PC will restart in 60 seconds.' = 'Het onderhoud is klaar. Je pc herstart over 60 seconden.'
        'Maintenance is running...' = 'Onderhoud bezig...'
        'Maintenance is still running.' = 'Het onderhoud loopt nog.'
        'Mode: {0}   |   {1}' = 'Modus: {0}   |   {1}'
        'Monday' = 'Maandag'
        'Name' = 'Naam'
        'Never show them (silent)' = 'Nooit tonen (stil)'
        'Never update the programs I did not tick (pin them)' = 'Software die ik niet aanvink nooit bijwerken (vastzetten)'
        'New' = 'Nieuw'
        'No' = 'Nee'
        'No program updates were found (or winget is not available).' = 'Er zijn geen software-updates gevonden (of winget is niet beschikbaar).'
        'No weekly run is scheduled.' = 'Er is geen wekelijkse run gepland.'
        'Not available: {0}' = 'Niet beschikbaar: {0}'
        'Nothing selected' = 'Niets geselecteerd'
        'Nothing was changed.' = 'Er is niets gewijzigd.'
        'Nothing was changed. The technical details below show what would happen.' = 'Er is niets gewijzigd. De technische details hieronder tonen wat er zou gebeuren.'
        'Now' = 'Nu'
        'Now: {0}   (usually {1})' = 'Bezig: {0}   (meestal {1})'
        'Online disk scan:' = 'Online schijfscan:'
        'Only drive {0}:' = 'Alleen schijf {0}:'
        'Only look for updates (recommended)' = 'Alleen naar updates zoeken (aanbevolen)'
        'Open log folder' = 'Logmap openen'
        'Open report' = 'Rapport openen'
        'Opens the Windows Memory Diagnostic. It asks whether to restart now or at the next start.' = 'Opent de Windows-geheugendiagnose. Die vraagt of je nu of bij de volgende start wilt herstarten.'
        'Optimize my drives' = 'Mijn schijven optimaliseren'
        'Please connect the charger first. A power cut in the middle of system maintenance can damage Windows.' = 'Sluit eerst de lader aan. Een stroomonderbreking midden in systeemonderhoud kan Windows beschadigen.'
        'Please leave this window open. You can keep using your PC, but avoid closing programs that are being updated.' = 'Laat dit venster open. Je kunt je pc blijven gebruiken, maar sluit geen software af die wordt bijgewerkt.'
        'Please tick at least one step first.' = ('Vink eerst minstens ' + [char]0xE9 + [char]0xE9 + 'n stap aan.')
        'Please wait' = 'Even wachten'
        'Please wait until it has finished, or press "Stop after this step".' = 'Wacht tot het klaar is, of druk op "Stoppen na deze stap".'
        'Power: charger connected.' = 'Voeding: lader aangesloten.'
        'Power: desktop PC (no battery found).' = 'Voeding: desktop-pc (geen batterij gevonden).'
        'Power: your laptop is on battery. Please connect the charger before you start.' = 'Voeding: je laptop werkt op batterij. Sluit de lader aan voordat je begint.'
        'Preview cleanup' = 'Voorbeeld van opschonen'
        'Preview finished' = 'Voorbeeld klaar'
        'Preview is running...' = 'Voorbeeld wordt gemaakt...'
        'Program' = 'Programma'
        'Programs' = 'Software'
        'Quick scan (recommended)' = 'Snelle scan (aanbevolen)'
        'Quick tune-up' = 'Snelle opfrisbeurt'
        'Quick tune-up: temp files, drive optimization, health report' = 'Snelle opfrisbeurt: tijdelijke bestanden, schijfoptimalisatie, gezondheidsrapport'
        'Reads SSD wear and temperature, drive error counters and the battery condition. Optionally runs a read-only online disk scan. Report only.' = 'Leest de slijtage en temperatuur van SSD-schijven, foutentellers van schijven en de toestand van de batterij. Kan ook een online schijfscan (alleen lezen) uitvoeren. Alleen een rapport.'
        'Ready to start?' = 'Klaar om te starten?'
        'Rebuild the icon cache' = 'Pictogramcache opnieuw opbouwen'
        'Rebuild the icon cache now? The desktop and taskbar will flash briefly. Save your work first.' = 'Pictogramcache nu opnieuw opbouwen? Het bureaublad en de taakbalk knipperen even. Sla eerst je werk op.'
        'Rebuild the search index' = 'Zoekindex opnieuw opbouwen'
        'Rebuild the search index now? Search can be slow or incomplete for a while.' = 'Zoekindex nu opnieuw opbouwen? Zoeken kan een tijdje traag of onvolledig zijn.'
        'Recycle Bin (also applies to step 3):' = 'Prullenbak (geldt ook voor stap 3):'
        'Remove all pins' = 'Alle pins verwijderen'
        'Remove schedule' = 'Planning verwijderen'
        'Removes downloaded update files that are no longer needed, the Delivery Optimization cache and the cache of Chrome, Edge and Firefox. Passwords, bookmarks and logins are never touched. Off by default.' = 'Verwijdert gedownloade updatebestanden die niet meer nodig zijn, de Delivery Optimization-cache en de cache van Chrome, Edge en Firefox. Wachtwoorden, bladwijzers en aanmeldingen blijven ongemoeid. Staat standaard uit.'
        'Removes old temporary files and empties the Recycle Bin (this cannot be undone). Also refreshes the network (DNS) cache.' = 'Verwijdert oude tijdelijke bestanden en leegt de Prullenbak (dit kan niet ongedaan worden gemaakt). Vernieuwt ook de netwerkcache (DNS).'
        'Reset Windows Update' = 'Windows Update resetten'
        'Reset Windows Update now? Windows will download the update information again.' = 'Windows Update nu resetten? Windows downloadt de update-informatie opnieuw.'
        'Reset the network' = 'Netwerk resetten'
        'Reset the network settings now? You should restart your PC afterwards.' = 'De netwerkinstellingen nu resetten? Herstart daarna je pc.'
        'Resets Winsock and the TCP/IP settings and clears the DNS cache. Helps with many "no internet" problems. Needs a restart afterwards.' = 'Reset Winsock en de TCP/IP-instellingen en wist de DNS-cache. Helpt bij veel "geen internet"-problemen. Daarna is een herstart nodig.'
        'Restart my PC (60 seconds warning)' = 'Mijn pc herstarten (60 seconden waarschuwing)'
        'Restart the print spooler' = 'Afdrukwachtrij herstarten'
        'Restart the print spooler? Documents waiting in the print queue will be removed.' = 'De afdrukwachtrij herstarten? Documenten die wachten om af te drukken worden verwijderd.'
        'Restarting soon' = 'Herstart binnenkort'
        'Restarts the printing service and removes stuck print jobs.' = 'Herstart de afdrukservice en verwijdert vastgelopen afdrukopdrachten.'
        'Restore points to keep:' = 'Herstelpunten bewaren:'
        'Run a read-only scan of each drive (slow)' = 'Een scan (alleen lezen) van elke schijf uitvoeren (traag)'
        'Run a security check-up' = 'Een beveiligingscontrole uitvoeren'
        'Run the maintenance by itself every week. Laptops only start it when the charger is connected. If the PC was off at that time it runs as soon as possible after.' = 'Laat het onderhoud elke week vanzelf lopen. Laptops starten het alleen als de lader is aangesloten. Stond de pc dan uit, dan loopt het zo snel mogelijk daarna.'
        'Running...' = 'Bezig...'
        'Runs Windows Disk Cleanup. Your Downloads folder and the files Windows needs to reset itself are never touched.' = 'Voert Windows Schijfopruiming uit. Je map Downloads en de bestanden die Windows nodig heeft om zichzelf te resetten blijven altijd ongemoeid.'
        'SFC only (faster)' = 'Alleen SFC (sneller)'
        'Saturday' = 'Zaterdag'
        'Scan type:' = 'Soort scan:'
        'Scans Windows for damaged files and repairs them. This is the slowest step.' = 'Zoekt in Windows naar beschadigde bestanden en herstelt ze. Dit is de traagste stap.'
        'Schedule...' = 'Planning...'
        'Scheduled task at logon/startup' = 'Geplande taak bij aanmelden/opstarten'
        'See and switch off programs that start with Windows. Nothing is deleted.' = 'Bekijk en schakel software uit die met Windows start. Er wordt niets verwijderd.'
        'Select everything' = 'Alles selecteren'
        'Select nothing' = 'Niets selecteren'
        'Show advanced options' = 'Geavanceerde opties tonen'
        'Show technical details' = 'Technische details tonen'
        'Show them if an installer needs one (recommended)' = 'Toon ze als een installatie er een nodig heeft (aanbevolen)'
        'Show what is using my disk space' = 'Tonen wat mijn schijfruimte gebruikt'
        'Show why my PC crashed' = 'Tonen waarom mijn pc is gecrasht'
        'Shows whether your drives report any problems and how much space is left.' = 'Toont of je schijven problemen melden en hoeveel ruimte er nog vrij is.'
        'Skip it (recommended)' = 'Overslaan (aanbevolen)'
        'Skip the charger check' = 'Laadercontrole overslaan'
        'Skipped' = 'Overgeslagen'
        'Something went wrong' = 'Er ging iets mis'
        'Space freed: {0} GB      Time taken: {1}' = 'Vrijgemaakte ruimte: {0} GB      Duur: {1}'
        'Standard (recommended)' = 'Standaard (aanbevolen)'
        'Start maintenance' = 'Onderhoud starten'
        'Starting...' = 'Starten...'
        'Startup programs' = 'Opstartsoftware'
        'Startup programs...' = 'Opstartsoftware...'
        'Stop after this step' = 'Stoppen na deze stap'
        'Stopped as requested' = 'Gestopt zoals gevraagd'
        'Stopped: charger not connected' = 'Gestopt: lader niet aangesloten'
        'Stopping after this step...' = 'Stoppen na deze stap...'
        'Stops the update services and renames the update download and catalog folders so Windows rebuilds them. Helps when updates are stuck.' = 'Stopt de updateservices en hernoemt de map met gedownloade updates en de catalogusmap zodat Windows ze opnieuw opbouwt. Helpt als updates vastzitten.'
        'Summarizes blue screens, unexpected shutdowns, application crashes and disk errors from the last 30 days. Report only.' = 'Vat blauwe schermen, onverwachte afsluitingen, programmacrashes en schijffouten van de laatste 30 dagen samen. Alleen een rapport.'
        'Sunday' = 'Zondag'
        'Takes {0}.' = 'Duurt {0}.'
        'Test the memory (RAM)' = 'Geheugen (RAM) testen'
        'That did not work:' = 'Dat is niet gelukt:'
        'The icon cache was rebuilt.' = 'De pictogramcache is opnieuw opgebouwd.'
        'The maintenance did not finish properly. Tick "Show technical details" to see what happened.' = 'Het onderhoud is niet goed afgerond. Vink "Technische details tonen" aan om te zien wat er gebeurde.'
        'The network settings were reset. Please restart your PC to finish.' = 'De netwerkinstellingen zijn gereset. Herstart je pc om af te ronden.'
        'The print spooler was restarted and stuck print jobs were removed.' = 'De afdrukwachtrij is herstart en vastgelopen afdrukopdrachten zijn verwijderd.'
        'The schedule could not be created:' = 'De planning kon niet worden gemaakt:'
        'The search index will be rebuilt. Search results can be incomplete for a while.' = 'De zoekindex wordt opnieuw opgebouwd. Zoekresultaten kunnen een tijdje onvolledig zijn.'
        'There is no history yet. Run the maintenance first.' = 'Er is nog geen geschiedenis. Voer eerst het onderhoud uit.'
        'Thursday' = 'Donderdag'
        'Tick the programs that may start with Windows. Unticking only switches them off (you can switch them on again here); nothing is deleted.' = 'Vink de software aan die met Windows mag starten. Uitvinken schakelt alleen uit (je kunt het hier weer inschakelen); er wordt niets verwijderd.'
        'Tick the programs you want to update now.' = 'Vink de software aan die je nu wilt bijwerken.'
        'Tick what you would like to do, then press "Start maintenance". If you are not sure, leave everything as it is - the default choices are safe.' = 'Vink aan wat je wilt doen en druk dan op "Onderhoud starten". Weet je het niet zeker, laat dan alles zoals het is - de standaardkeuzes zijn veilig.'
        'Time:' = 'Tijd:'
        'Tools' = 'Hulpmiddelen'
        'Tools...' = 'Hulpmiddelen...'
        'Tuesday' = 'Dinsdag'
        'Update definitions only' = 'Alleen definities bijwerken'
        'Update my programs' = 'Mijn software bijwerken'
        'Update virus definitions and scan' = 'Virusdefinities bijwerken en scannen'
        'Updates Windows Defender and runs a quick virus scan.' = 'Werkt Windows Defender bij en voert een snelle virusscan uit.'
        'Waiting' = 'Wachten'
        'Wednesday' = 'Woensdag'
        'Weekly safe' = 'Veilig, wekelijks'
        'Weekly safe (recommended): updates, virus scan, drive optimization, health and security checks' = 'Veilig, wekelijks (aanbevolen): updates, virusscan, schijfoptimalisatie, gezondheids- en beveiligingscontroles'
        'Weekly schedule' = 'Wekelijkse planning'
        'What to do with updates:' = 'Wat te doen met updates:'
        'What to run:' = 'Wat uitvoeren:'
        'When finished:' = 'Als het klaar is:'
        'Where' = 'Waar'
        'Which drives:' = 'Welke schijven:'
        'Windows Update download cache:' = 'Downloadcache van Windows Update:'
        'Windows Update was reset. The old folders were renamed (they end in .bak-date) and can be deleted later. Check for updates again.' = 'Windows Update is gereset. De oude mappen zijn hernoemd (ze eindigen op .bak-datum) en kunnen later worden verwijderd. Zoek opnieuw naar updates.'
        'Windows would like a restart to finish some changes.' = 'Windows wil herstarten om sommige wijzigingen af te ronden.'
        'Yes (recommended)' = 'Ja (aanbevolen)'
        'You are about to run {0} step(s).' = 'Je staat op het punt {0} stap(pen) uit te voeren.'
        'Your Startup folder' = 'Je opstartmap'
        'Your laptop is running on battery.' = 'Je laptop werkt op batterij.'
        'Your logon (registry)' = 'Jouw aanmelding (register)'
        'about 1 minute' = 'ongeveer 1 minuut'
        'under 1 minute' = 'minder dan 1 minuut'
        'under 2 minutes' = 'minder dan 2 minuten'
        '{0} could not be changed.' = '{0} kon(den) niet worden gewijzigd.'
        '{0} program(s) selected.' = 'Geselecteerd: {0}.'
        '{0} startup item(s) changed.' = '{0} opstartitem(s) gewijzigd.'
        '{0} step(s) failed - tick "Show technical details" to see why.' = '{0} stap(pen) mislukt - vink "Technische details tonen" aan om te zien waarom.'
    }
    function T([string]$Text) {
        if ($script:Lang -eq 'nl' -and $script:NL.ContainsKey($Text)) { return $script:NL[$Text] }
        return $Text
    }

    # ----- colors for the light and dark theme
    function Set-ThemeColors {
        if ($script:Theme -eq 'dark') {
            $script:ColBack = Rgb 28 29 32;   $script:ColText  = Rgb 232 234 237; $script:ColMuted = Rgb 150 157 167
            $script:ColCard = Rgb 40 42 47;   $script:ColInput = Rgb 52 55 61
            $script:ColBorder = Rgb 68 72 80; $script:ColHover = Rgb 62 66 74
            $script:ColGreen = Rgb 90 200 120; $script:ColRed  = Rgb 240 110 110; $script:ColAmber = Rgb 240 170 70
            $script:ColBlue = Rgb 110 170 255
            $script:ColAccent = Rgb 96 165 250; $script:ColAccentHover = Rgb 135 190 255; $script:ColOnAccent = Rgb 12 18 28
        } else {
            $script:ColBack = [System.Drawing.Color]::White; $script:ColText = Rgb 32 36 42; $script:ColMuted = Rgb 98 106 116
            $script:ColCard = Rgb 245 247 250; $script:ColInput = [System.Drawing.Color]::White
            $script:ColBorder = Rgb 211 216 224; $script:ColHover = Rgb 230 235 242
            $script:ColGreen = Rgb 28 134 58;  $script:ColRed = Rgb 196 40 40; $script:ColAmber = Rgb 190 112 0
            $script:ColBlue = Rgb 0 95 184
            $script:ColAccent = Rgb 0 95 184;  $script:ColAccentHover = Rgb 0 78 156; $script:ColOnAccent = [System.Drawing.Color]::White
        }
    }

    # Gives buttons one flat look in both themes (Name 'primary' = accent button, 'ghost' = toolbar
    # button without border), and the controls that ignore the form's colors their dark colors.
    function Apply-Theme($Ctl) {
        foreach ($c in $Ctl.Controls) {
            if ($c -is [System.Windows.Forms.Button]) {
                $c.FlatStyle = 'Flat'
                $c.Cursor    = [System.Windows.Forms.Cursors]::Hand
                if ($c.Name -eq 'primary') {
                    $c.FlatAppearance.BorderSize = 0
                    $c.FlatAppearance.MouseOverBackColor = $script:ColAccentHover
                    $c.BackColor = $script:ColAccent
                    $c.ForeColor = $script:ColOnAccent
                } elseif ($c.Name -eq 'ghost') {
                    $c.FlatAppearance.BorderSize = 0
                    $c.FlatAppearance.MouseOverBackColor = $script:ColHover
                    $c.BackColor = $script:ColBack
                    $c.ForeColor = $script:ColText
                } else {
                    $c.FlatAppearance.BorderSize = 1
                    $c.FlatAppearance.BorderColor = $script:ColBorder
                    $c.FlatAppearance.MouseOverBackColor = $script:ColHover
                    $c.BackColor = $script:ColInput
                    $c.ForeColor = $script:ColText
                }
            } elseif ($script:Theme -eq 'dark') {
                if ($c -is [System.Windows.Forms.ComboBox]) {
                    $c.FlatStyle = 'Flat'; $c.BackColor = $script:ColInput; $c.ForeColor = $script:ColText
                } elseif ($c -is [System.Windows.Forms.TextBox] -or $c -is [System.Windows.Forms.ListView]) {
                    $c.BackColor = $script:ColInput; $c.ForeColor = $script:ColText
                } elseif ($c -is [System.Windows.Forms.DataGridView]) {
                    $c.BackgroundColor = $script:ColBack; $c.GridColor = $script:ColBorder
                    $c.EnableHeadersVisualStyles = $false
                    $c.ColumnHeadersDefaultCellStyle.BackColor = $script:ColCard
                    $c.ColumnHeadersDefaultCellStyle.ForeColor = $script:ColText
                    $c.DefaultCellStyle.BackColor = $script:ColInput
                    $c.DefaultCellStyle.ForeColor = $script:ColText
                }
            }
            if ($c.Controls.Count -gt 0) { Apply-Theme $c }
        }
    }

    # ----- small helpers
    # Buttons: OK, OKCancel, YesNo. Icons: Information, Warning, Question, Error.
    function Show-Message([string]$Text, [string]$Caption, [string]$Buttons = 'OK', [string]$Icon = 'Information') {
        return [System.Windows.Forms.MessageBox]::Show($Text, $Caption, [System.Windows.Forms.MessageBoxButtons]$Buttons, [System.Windows.Forms.MessageBoxIcon]$Icon)
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
            'Plugged' { $script:UI.lblPower.Text = (T 'Power: charger connected.');                      $script:UI.lblPower.ForeColor = $script:ColGreen }
            'Battery' { $script:UI.lblPower.Text = (T 'Power: your laptop is on battery. Please connect the charger before you start.'); $script:UI.lblPower.ForeColor = $script:ColRed }
            'Desktop' { $script:UI.lblPower.Text = (T 'Power: desktop PC (no battery found).');          $script:UI.lblPower.ForeColor = $script:ColMuted }
            default   { $script:UI.lblPower.Text = '';                                                     $script:UI.lblPower.ForeColor = $script:ColMuted }
        }
    }

    # A standard dialog frame (the caller adds the controls)
    function New-Dialog([string]$Title, [double]$W, [double]$H) {
        $f = New-Object System.Windows.Forms.Form
        $f.Text            = $Title
        $f.StartPosition   = 'CenterParent'
        $f.FormBorderStyle = 'FixedDialog'
        $f.MaximizeBox     = $false
        $f.MinimizeBox     = $false
        $f.ShowInTaskbar   = $false
        $f.Size            = Sz $W $H
        $f.Font            = $script:FontNormal
        $f.BackColor       = $script:ColBack
        $f.ForeColor       = $script:ColText
        return $f
    }

    function New-Label([string]$Text, $Font, $Color, [double]$MaxWidth) {
        $l = New-Object System.Windows.Forms.Label
        $l.AutoSize = $true
        $l.Text     = $Text
        if ($Font)  { $l.Font = $Font }
        if ($Color) { $l.ForeColor = $Color }
        if ($MaxWidth -gt 0) { $l.MaximumSize = Sz $MaxWidth 0 }
        return $l
    }

    # ----- winget: list of programs that have an update, and a window to choose
    function Get-WingetUpgrades {
        $oldEnc = [Console]::OutputEncoding
        try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
        try {
            $raw = @(& winget upgrade --accept-source-agreements 2>&1 | ForEach-Object { [string]$_ })
        } finally {
            try { [Console]::OutputEncoding = $oldEnc } catch { }
        }
        $lines = @($raw | ForEach-Object {
            $l = $_ -replace "`0", ''
            if ($l.Contains("`r")) { $l = @($l -split "`r" | Where-Object { $_.Trim() } | Select-Object -Last 1)[0] }
            [string]$l
        })
        $sep = -1
        for ($i = 1; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^-{5,}\s*$') { $sep = $i; break }
        }
        if ($sep -lt 1) { return @() }
        # Column positions come from the header line, so this works in any language.
        $starts = @([regex]::Matches($lines[$sep - 1], '\S+(?: \S+)*') | ForEach-Object { $_.Index })
        if ($starts.Count -lt 4) { return @() }
        $cell = {
            param([string]$Row, [int]$n)
            $b = $starts[$n]
            if ($b -ge $Row.Length) { return '' }
            $e = if ($n + 1 -lt $starts.Count) { [math]::Min($starts[$n + 1], $Row.Length) } else { $Row.Length }
            return $Row.Substring($b, $e - $b).Trim()
        }
        $found = @()
        for ($i = $sep + 1; $i -lt $lines.Count; $i++) {
            $row = $lines[$i]
            if ($row.Trim() -eq '') { break }
            $id = & $cell $row 1
            $new = & $cell $row 3
            if ($id -notmatch '^[\w\.\-\+]+$' -or -not $new) { break }   # footer line or next table
            $found += [pscustomobject]@{ Id = $id; Name = (& $cell $row 0); Version = (& $cell $row 2); Available = $new }
        }
        return $found
    }

    function Update-WingetLabel {
        if (-not $script:UI.lblWingetSel) { return }
        if ($script:WingetPick) {
            $script:UI.lblWingetSel.Text = ((T '{0} program(s) selected.') -f @($script:WingetPick).Count)
        } else {
            $script:UI.lblWingetSel.Text = (T 'All programs with an update will be updated.')
        }
    }

    function Show-WingetChooser {
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $items = @()
        try { $items = @(Get-WingetUpgrades) } catch { $items = @() } finally { $form.Cursor = [System.Windows.Forms.Cursors]::Default }
        if ($items.Count -eq 0) {
            [void](Show-Message (T 'No program updates were found (or winget is not available).') (T 'Programs') 'OK' 'Information')
            return
        }
        $dlg = New-Dialog (T 'Choose which programs to update') 720 520
        $script:Dlg = @{ Form = $dlg }

        $top = New-Label (T 'Tick the programs you want to update now.') $script:FontNormal $null 680
        $top.Location = New-Object System.Drawing.Point -ArgumentList (S 14), (S 12)
        $dlg.Controls.Add($top)

        $lv = New-Object System.Windows.Forms.ListView
        $lv.View = 'Details'; $lv.CheckBoxes = $true; $lv.FullRowSelect = $true
        $lv.Location = New-Object System.Drawing.Point -ArgumentList (S 14), (S 40)
        $lv.Size = Sz 676 340
        [void]$lv.Columns.Add((T 'Program'), (S 300))
        [void]$lv.Columns.Add((T 'Now'), (S 120))
        [void]$lv.Columns.Add((T 'New'), (S 120))
        foreach ($u in $items) {
            $li = New-Object System.Windows.Forms.ListViewItem($u.Name)
            [void]$li.SubItems.Add($u.Version)
            [void]$li.SubItems.Add($u.Available)
            $li.Tag = $u.Id
            $li.Checked = $true
            [void]$lv.Items.Add($li)
        }
        $dlg.Controls.Add($lv)
        $script:Dlg.List = $lv

        $chkPin = New-Object System.Windows.Forms.CheckBox
        $chkPin.AutoSize = $true
        $chkPin.Text = (T 'Never update the programs I did not tick (pin them)')
        $chkPin.Location = New-Object System.Drawing.Point -ArgumentList (S 14), (S 392)
        $dlg.Controls.Add($chkPin)
        $script:Dlg.Pin = $chkPin

        $btnOk = New-Object System.Windows.Forms.Button
        $btnOk.Text = (T 'OK'); $btnOk.Size = Sz 90 34; $btnOk.DialogResult = 'OK'
        $btnOk.Location = New-Object System.Drawing.Point -ArgumentList (S 500), (S 430)
        $btnCancel = New-Object System.Windows.Forms.Button
        $btnCancel.Text = (T 'Cancel'); $btnCancel.Size = Sz 90 34; $btnCancel.DialogResult = 'Cancel'
        $btnCancel.Location = New-Object System.Drawing.Point -ArgumentList (S 600), (S 430)
        $btnUnpin = New-Object System.Windows.Forms.Button
        $btnUnpin.Text = (T 'Remove all pins'); $btnUnpin.Size = Sz 150 34
        $btnUnpin.Location = New-Object System.Drawing.Point -ArgumentList (S 14), (S 430)
        $btnUnpin.Add_Click({
            try { & winget pin reset --force 2>&1 | Out-Null } catch { }
            [void](Show-Message (T 'All pins were removed.') (T 'Programs') 'OK' 'Information')
        })
        foreach ($b in @($btnOk, $btnCancel, $btnUnpin)) { $dlg.Controls.Add($b) }
        $dlg.AcceptButton = $btnOk; $dlg.CancelButton = $btnCancel
        Apply-Theme $dlg

        if ($dlg.ShowDialog($form) -ne 'OK') { return }
        $checked   = @($script:Dlg.List.Items | Where-Object { $_.Checked }  | ForEach-Object { [string]$_.Tag })
        $unchecked = @($script:Dlg.List.Items | Where-Object { -not $_.Checked } | ForEach-Object { [string]$_.Tag })
        if ($script:Dlg.Pin.Checked) {
            foreach ($id in $unchecked) { try { & winget pin add --id $id --exact --accept-source-agreements 2>&1 | Out-Null } catch { } }
        }
        if ($checked.Count -eq 0) {
            $script:StepCtl[2].Check.Checked = $false
            $script:WingetPick = $null
        } elseif ($unchecked.Count -eq 0) {
            $script:WingetPick = $null
        } else {
            $script:WingetPick = $checked
        }
        Update-WingetLabel
    }

    # ----- one-click repairs (they run here in the window, not in the engine)
    function Invoke-NetworkReset {
        & netsh.exe winsock reset | Out-Null
        & netsh.exe int ip reset | Out-Null
        & ipconfig.exe /flushdns | Out-Null
        return (T 'The network settings were reset. Please restart your PC to finish.')
    }

    function Invoke-WuReset {
        $stopped = @()
        try {
            foreach ($n in 'wuauserv', 'bits', 'cryptsvc', 'msiserver') {
                $svc = Get-Service $n -ErrorAction SilentlyContinue
                if ($svc -and $svc.Status -eq 'Running') { Stop-Service $n -Force -ErrorAction Stop; $stopped += $n }
            }
            $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
            foreach ($d in @("$env:SystemRoot\SoftwareDistribution", "$env:SystemRoot\System32\catroot2")) {
                if (Test-Path -LiteralPath $d) { Rename-Item -LiteralPath $d -NewName ((Split-Path $d -Leaf) + ".bak-$stamp") -ErrorAction Stop }
            }
        } finally {
            foreach ($n in $stopped) { Start-Service $n -ErrorAction SilentlyContinue }
        }
        return (T 'Windows Update was reset. The old folders were renamed (they end in .bak-date) and can be deleted later. Check for updates again.')
    }

    function Invoke-SearchRebuild {
        Stop-Service WSearch -Force -ErrorAction Stop
        try {
            Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows Search' -Name SetupCompletedSuccessfully -Value 0 -Type DWord -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath "$env:ProgramData\Microsoft\Search\Data\Applications\Windows\Windows.edb" -Force -ErrorAction SilentlyContinue
        } finally {
            Start-Service WSearch -ErrorAction SilentlyContinue
        }
        return (T 'The search index will be rebuilt. Search results can be incomplete for a while.')
    }

    function Invoke-IconRebuild {
        Get-Process -Name explorer -ErrorAction SilentlyContinue | Stop-Process -Force
        Start-Sleep -Seconds 1
        Remove-Item -LiteralPath "$env:LOCALAPPDATA\IconCache.db" -Force -ErrorAction SilentlyContinue
        Get-ChildItem -LiteralPath "$env:LOCALAPPDATA\Microsoft\Windows\Explorer" -Filter 'iconcache_*.db' -Force -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3   # Windows restarts the desktop by itself
        if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
        return (T 'The icon cache was rebuilt.')
    }

    function Invoke-SpoolerReset {
        Stop-Service Spooler -Force -ErrorAction Stop
        try {
            Get-ChildItem -LiteralPath "$env:SystemRoot\System32\spool\PRINTERS" -File -Force -ErrorAction SilentlyContinue |
                Remove-Item -Force -ErrorAction SilentlyContinue
        } finally {
            Start-Service Spooler
        }
        return (T 'The print spooler was restarted and stuck print jobs were removed.')
    }

    # ----- startup programs: Run keys, Startup folders and logon scheduled tasks.
    #       Enable/disable uses the same "StartupApproved" switch as Task Manager, so nothing is deleted.
    function Get-ApprovedEnabled([string]$KeyPath, [string]$ValueName) {
        try {
            $v = (Get-ItemProperty -Path $KeyPath -Name $ValueName -ErrorAction Stop).$ValueName
            if ($v -is [byte[]] -and $v.Length -gt 0) { return (($v[0] -band 1) -eq 0) }
        } catch { }
        return $true
    }

    function Get-StartupItems {
        $items  = New-Object System.Collections.Generic.List[object]
        $appr   = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'
        $runKeys = @(
            @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run';             Hive = 'HKCU'; Appr = 'Run';   Where = 'Your logon (registry)' },
            @{ Path = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run';             Hive = 'HKLM'; Appr = 'Run';   Where = 'All users (registry)' },
            @{ Path = 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Hive = 'HKLM'; Appr = 'Run32'; Where = 'All users, 32-bit (registry)' }
        )
        foreach ($k in $runKeys) {
            $props = Get-ItemProperty -Path $k.Path -ErrorAction SilentlyContinue
            if (-not $props) { continue }
            foreach ($prop in $props.PSObject.Properties) {
                if ($prop.Name -like 'PS*') { continue }
                $key = "$($k.Hive):\$appr\$($k.Appr)"
                $items.Add([pscustomobject]@{
                    Kind = 'Run'; Name = $prop.Name; Command = [string]$prop.Value; Where = $k.Where
                    ApprovedKey = $key; ValueName = $prop.Name; TaskPath = ''
                    Enabled = (Get-ApprovedEnabled $key $prop.Name)
                })
            }
        }
        foreach ($f in @(
            @{ Dir = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup";      Hive = 'HKCU'; Where = 'Your Startup folder' },
            @{ Dir = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp"; Hive = 'HKLM'; Where = 'All users Startup folder' }
        )) {
            foreach ($file in @(Get-ChildItem -LiteralPath $f.Dir -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' })) {
                $key = "$($f.Hive):\$appr\StartupFolder"
                $items.Add([pscustomobject]@{
                    Kind = 'Folder'; Name = $file.BaseName; Command = $file.FullName; Where = $f.Where
                    ApprovedKey = $key; ValueName = $file.Name; TaskPath = ''
                    Enabled = (Get-ApprovedEnabled $key $file.Name)
                })
            }
        }
        try {
            foreach ($t in @(Get-ScheduledTask -ErrorAction Stop)) {
                if ($t.TaskPath -like '\Microsoft\*') { continue }
                $trig = @($t.Triggers | Where-Object { $_.CimClass.CimClassName -in 'MSFT_TaskLogonTrigger', 'MSFT_TaskBootTrigger' })
                if ($trig.Count -eq 0) { continue }
                $cmd = (@($t.Actions | ForEach-Object { ("$($_.Execute) $($_.Arguments)").Trim() }) -join '; ')
                $items.Add([pscustomobject]@{
                    Kind = 'Task'; Name = $t.TaskName; Command = $cmd; Where = 'Scheduled task at logon/startup'
                    ApprovedKey = ''; ValueName = $t.TaskName; TaskPath = $t.TaskPath
                    Enabled = ([string]$t.State -ne 'Disabled')
                })
            }
        } catch { }
        return @($items)
    }

    function Set-StartupItemEnabled($Item, [bool]$Enable) {
        if ($Item.Kind -eq 'Task') {
            if ($Enable) { Enable-ScheduledTask -TaskPath $Item.TaskPath -TaskName $Item.ValueName | Out-Null }
            else         { Disable-ScheduledTask -TaskPath $Item.TaskPath -TaskName $Item.ValueName | Out-Null }
            return
        }
        $bytes = New-Object byte[] 12
        if ($Enable) {
            $bytes[0] = 2
        } else {
            $bytes[0] = 3
            [Array]::Copy([BitConverter]::GetBytes([DateTime]::UtcNow.ToFileTimeUtc()), 0, $bytes, 4, 8)
        }
        if (-not (Test-Path -LiteralPath $Item.ApprovedKey)) { New-Item -Path $Item.ApprovedKey -Force | Out-Null }
        New-ItemProperty -LiteralPath $Item.ApprovedKey -Name $Item.ValueName -PropertyType Binary -Value $bytes -Force | Out-Null
    }

    function Show-StartupDialog {
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $items = @()
        try { $items = @(Get-StartupItems) } finally { $form.Cursor = [System.Windows.Forms.Cursors]::Default }
        $dlg = New-Dialog (T 'Startup programs') 820 540
        $script:Dlg = @{ Form = $dlg; Items = $items }

        $top = New-Label (T 'Tick the programs that may start with Windows. Unticking only switches them off (you can switch them on again here); nothing is deleted.') $script:FontNormal $null 780
        $top.Location = New-Object System.Drawing.Point -ArgumentList (S 14), (S 12)
        $dlg.Controls.Add($top)

        $lv = New-Object System.Windows.Forms.ListView
        $lv.View = 'Details'; $lv.CheckBoxes = $true; $lv.FullRowSelect = $true
        $lv.Location = New-Object System.Drawing.Point -ArgumentList (S 14), (S 62)
        $lv.Size = Sz 780 370
        [void]$lv.Columns.Add((T 'Name'), (S 200))
        [void]$lv.Columns.Add((T 'Where'), (S 200))
        [void]$lv.Columns.Add((T 'Command'), (S 360))
        for ($i = 0; $i -lt $items.Count; $i++) {
            $it = $items[$i]
            $li = New-Object System.Windows.Forms.ListViewItem($it.Name)
            [void]$li.SubItems.Add((T $it.Where))
            [void]$li.SubItems.Add($it.Command)
            $li.Tag = $i
            $li.Checked = [bool]$it.Enabled
            [void]$lv.Items.Add($li)
        }
        $dlg.Controls.Add($lv)
        $script:Dlg.List = $lv

        $btnOk = New-Object System.Windows.Forms.Button
        $btnOk.Text = (T 'Apply'); $btnOk.Size = Sz 100 34; $btnOk.DialogResult = 'OK'
        $btnOk.Location = New-Object System.Drawing.Point -ArgumentList (S 580), (S 450)
        $btnCancel = New-Object System.Windows.Forms.Button
        $btnCancel.Text = (T 'Cancel'); $btnCancel.Size = Sz 100 34; $btnCancel.DialogResult = 'Cancel'
        $btnCancel.Location = New-Object System.Drawing.Point -ArgumentList (S 690), (S 450)
        $dlg.Controls.Add($btnOk); $dlg.Controls.Add($btnCancel)
        $dlg.AcceptButton = $btnOk; $dlg.CancelButton = $btnCancel
        Apply-Theme $dlg

        if ($dlg.ShowDialog($form) -ne 'OK') { return }
        $changed = 0; $failed = 0
        foreach ($li in $script:Dlg.List.Items) {
            $it = $script:Dlg.Items[[int]$li.Tag]
            if ([bool]$it.Enabled -eq [bool]$li.Checked) { continue }
            try { Set-StartupItemEnabled $it ([bool]$li.Checked); $changed++ } catch { $failed++ }
        }
        $msg = ((T '{0} startup item(s) changed.') -f $changed)
        if ($failed -gt 0) { $msg += "`r`n" + ((T '{0} could not be changed.') -f $failed) }
        [void](Show-Message $msg (T 'Startup programs') 'OK' 'Information')
    }

    # ----- Tools window
    function Get-ToolList {
        return @(
            @{ Text = 'Startup programs...'; Desc = 'See and switch off programs that start with Windows. Nothing is deleted.'; Confirm = '';
               Run = { Show-StartupDialog; return $null } },
            @{ Text = 'Reset the network'; Desc = 'Resets Winsock and the TCP/IP settings and clears the DNS cache. Helps with many "no internet" problems. Needs a restart afterwards.';
               Confirm = 'Reset the network settings now? You should restart your PC afterwards.'; Run = { Invoke-NetworkReset } },
            @{ Text = 'Reset Windows Update'; Desc = 'Stops the update services and renames the update download and catalog folders so Windows rebuilds them. Helps when updates are stuck.';
               Confirm = 'Reset Windows Update now? Windows will download the update information again.'; Run = { Invoke-WuReset } },
            @{ Text = 'Rebuild the search index'; Desc = 'Deletes the Windows search index so it is built again. Helps when search finds nothing.';
               Confirm = 'Rebuild the search index now? Search can be slow or incomplete for a while.'; Run = { Invoke-SearchRebuild } },
            @{ Text = 'Rebuild the icon cache'; Desc = 'Fixes wrong or blank icons. The desktop and taskbar restart for a moment.';
               Confirm = 'Rebuild the icon cache now? The desktop and taskbar will flash briefly. Save your work first.'; Run = { Invoke-IconRebuild } },
            @{ Text = 'Restart the print spooler'; Desc = 'Restarts the printing service and removes stuck print jobs.';
               Confirm = 'Restart the print spooler? Documents waiting in the print queue will be removed.'; Run = { Invoke-SpoolerReset } },
            @{ Text = 'Test the memory (RAM)'; Desc = 'Opens the Windows Memory Diagnostic. It asks whether to restart now or at the next start.'; Confirm = '';
               Run = { Start-Process mdsched.exe; return $null } }
        )
    }

    function Show-ToolsDialog {
        $dlg = New-Dialog (T 'Tools') 820 600
        $tools = Get-ToolList
        $script:Dlg = @{ Form = $dlg; Tools = $tools }

        $flow = New-Object System.Windows.Forms.FlowLayoutPanel
        $flow.FlowDirection = 'TopDown'; $flow.WrapContents = $false; $flow.AutoScroll = $true
        $flow.Dock = 'Fill'; $flow.Padding = Pd 12 12 12 12
        for ($i = 0; $i -lt $tools.Count; $i++) {
            $row = New-Object System.Windows.Forms.FlowLayoutPanel
            $row.FlowDirection = 'LeftToRight'; $row.WrapContents = $false; $row.AutoSize = $true
            $row.Margin = Pd 0 0 0 10
            $btn = New-Object System.Windows.Forms.Button
            $btn.Text = (T $tools[$i].Text); $btn.Size = Sz 260 38; $btn.Tag = $i
            $btn.Add_Click({
                param($sender, $e)
                $t = $script:Dlg.Tools[[int]$sender.Tag]
                if ($t.Confirm) {
                    if ((Show-Message (T $t.Confirm) (T $t.Text) 'YesNo' 'Question') -ne 'Yes') { return }
                }
                $script:Dlg.Form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
                $msg = $null
                try { $msg = & $t.Run } catch { $msg = ((T 'That did not work:') + "`r`n" + $_.Exception.Message) } finally { $script:Dlg.Form.Cursor = [System.Windows.Forms.Cursors]::Default }
                if ($msg) { [void](Show-Message ([string]($msg -join "`r`n")) (T $t.Text) 'OK' 'Information') }
            })
            $row.Controls.Add($btn)
            $lbl = New-Label (T $tools[$i].Desc) $script:FontSmall $script:ColMuted 480
            $lbl.Margin = Pd 12 8 0 0
            $row.Controls.Add($lbl)
            $flow.Controls.Add($row)
        }
        $dlg.Controls.Add($flow)
        Apply-Theme $dlg
        [void]$dlg.ShowDialog($form)
    }

    # ----- weekly schedule dialog (the task functions Install-MaintTask etc. are defined above, shared with -Schedule)

    function Update-ScheduleStatus {
        $task = Get-MaintTask
        if ($task) {
            $next = ''
            try { $next = (Get-ScheduledTaskInfo -TaskName $script:TaskName -ErrorAction Stop).NextRunTime.ToString('yyyy-MM-dd HH:mm') } catch { }
            $script:Dlg.Status.Text = ((T 'A weekly run is scheduled. Next run: {0}') -f $next)
            $script:Dlg.Status.ForeColor = $script:ColGreen
            $script:Dlg.BtnRemove.Enabled = $true
        } else {
            $script:Dlg.Status.Text = (T 'No weekly run is scheduled.')
            $script:Dlg.Status.ForeColor = $script:ColMuted
            $script:Dlg.BtnRemove.Enabled = $false
        }
    }

    function Show-ScheduleDialog {
        $dlg = New-Dialog (T 'Weekly schedule') 560 380
        $script:Dlg = @{ Form = $dlg }

        if ($RunMode -eq 'Server') {
            $introText = T 'Run the checks by itself every week, as SYSTEM, also when nobody is logged on. If the server was off at that time it runs as soon as possible after.'
        } else {
            $introText = T 'Run the maintenance by itself every week. Laptops only start it when the charger is connected. If the PC was off at that time it runs as soon as possible after.'
        }
        $intro = New-Label $introText $script:FontNormal $null 520
        $intro.Location = New-Object System.Drawing.Point -ArgumentList (S 14), (S 12)
        $dlg.Controls.Add($intro)

        $y = 100
        $lblDay = New-Label (T 'Day:') $script:FontNormal $null 0
        $lblDay.Location = New-Object System.Drawing.Point -ArgumentList (S 14), (S ($y + 4))
        $cmbDay = New-Object System.Windows.Forms.ComboBox
        $cmbDay.DropDownStyle = 'DropDownList'; $cmbDay.Width = S 200
        $cmbDay.Location = New-Object System.Drawing.Point -ArgumentList (S 140), (S $y)
        $script:Dlg.DayValues = @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')
        foreach ($dn in $script:Dlg.DayValues) { [void]$cmbDay.Items.Add((T $dn)) }
        $cmbDay.SelectedIndex = 6
        $script:Dlg.Day = $cmbDay

        $y += 42
        $lblTime = New-Label (T 'Time:') $script:FontNormal $null 0
        $lblTime.Location = New-Object System.Drawing.Point -ArgumentList (S 14), (S ($y + 4))
        $dtp = New-Object System.Windows.Forms.DateTimePicker
        $dtp.Format = 'Custom'; $dtp.CustomFormat = 'HH:mm'; $dtp.ShowUpDown = $true; $dtp.Width = S 100
        $dtp.Location = New-Object System.Drawing.Point -ArgumentList (S 140), (S $y)
        $dtp.Value = [datetime]::Today.AddHours(12)
        $script:Dlg.Time = $dtp

        $y += 42
        $lblWhat = New-Label (T 'What to run:') $script:FontNormal $null 0
        $lblWhat.Location = New-Object System.Drawing.Point -ArgumentList (S 14), (S ($y + 4))
        $cmbPreset = New-Object System.Windows.Forms.ComboBox
        $cmbPreset.DropDownStyle = 'DropDownList'; $cmbPreset.Width = S 380
        $cmbPreset.Location = New-Object System.Drawing.Point -ArgumentList (S 140), (S $y)
        if ($RunMode -eq 'Server') {
            $script:Dlg.PresetValues = @('ServerCheck', 'WeeklySafe')
            $presetTexts = @('Server check (recommended): read-only health checks of the server, backups, roles and storage',
                             'Weekly safe: update scan, virus scan, drive analysis, health and security checks')
        } else {
            $script:Dlg.PresetValues = @('WeeklySafe', 'QuickTuneUp', 'DeepClean')
            $presetTexts = @('Weekly safe (recommended): updates, virus scan, drive optimization, health and security checks',
                             'Quick tune-up: temp files, drive optimization, health report',
                             'Deep clean: restore point, updates, cleanup, repair, caches')
        }
        foreach ($pt in $presetTexts) { [void]$cmbPreset.Items.Add((T $pt)) }
        $cmbPreset.SelectedIndex = 0
        $script:Dlg.Preset = $cmbPreset

        $status = New-Label '' $script:FontBold $script:ColMuted 520
        $status.Location = New-Object System.Drawing.Point -ArgumentList (S 14), (S 250)
        $script:Dlg.Status = $status

        $script:Dlg.Window = $null
        if ($RunMode -eq 'Server') {
            $chkWin = New-Object System.Windows.Forms.CheckBox
            $chkWin.AutoSize = $true
            $chkWin.Text     = (T 'Allow changes in the scheduled run (maintenance window)')
            $chkWin.Location = New-Object System.Drawing.Point -ArgumentList (S 14), (S 222)
            $script:Dlg.Window = $chkWin
            $dlg.Controls.Add($chkWin)
        }
        foreach ($c in @($lblDay, $cmbDay, $lblTime, $dtp, $lblWhat, $cmbPreset, $status)) { $dlg.Controls.Add($c) }

        $btnCreate = New-Object System.Windows.Forms.Button
        $btnCreate.Text = (T 'Create or update'); $btnCreate.Size = Sz 170 36
        $btnCreate.Location = New-Object System.Drawing.Point -ArgumentList (S 14), (S 292)
        $btnCreate.Add_Click({
            try {
                $day = $script:Dlg.DayValues[$script:Dlg.Day.SelectedIndex]
                $pre = $script:Dlg.PresetValues[$script:Dlg.Preset.SelectedIndex]
                $allow = [bool]($script:Dlg.Window -and $script:Dlg.Window.Checked)
                Install-MaintTask $day $script:Dlg.Time.Value $pre $allow
                Update-ScheduleStatus
            } catch {
                [void](Show-Message ((T 'The schedule could not be created:') + "`r`n" + $_.Exception.Message) (T 'Weekly schedule') 'OK' 'Error')
            }
        })
        $btnRemove = New-Object System.Windows.Forms.Button
        $btnRemove.Text = (T 'Remove schedule'); $btnRemove.Size = Sz 150 36
        $btnRemove.Location = New-Object System.Drawing.Point -ArgumentList (S 194), (S 292)
        $btnRemove.Add_Click({
            try { Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false -ErrorAction Stop } catch { }
            Update-ScheduleStatus
        })
        $script:Dlg.BtnRemove = $btnRemove
        $btnClose = New-Object System.Windows.Forms.Button
        $btnClose.Text = (T 'Close'); $btnClose.Size = Sz 90 36; $btnClose.DialogResult = 'Cancel'
        $btnClose.Location = New-Object System.Drawing.Point -ArgumentList (S 440), (S 292)
        foreach ($b in @($btnCreate, $btnRemove, $btnClose)) { $dlg.Controls.Add($b) }
        $dlg.CancelButton = $btnClose
        Apply-Theme $dlg
        Update-ScheduleStatus
        [void]$dlg.ShowDialog($form)
    }

    # ----- history of earlier runs (from MaintenanceHistory.csv)
    function Show-HistoryDialog {
        if (-not (Test-Path -LiteralPath $HistoryFile)) {
            [void](Show-Message (T 'There is no history yet. Run the maintenance first.') (T 'History') 'OK' 'Information')
            return
        }
        $rows = @()
        try { $rows = @(Import-Csv -LiteralPath $HistoryFile | Sort-Object RunId -Descending) } catch { }
        $dlg = New-Dialog (T 'History') 900 560
        $script:Dlg = @{ Form = $dlg }
        $grid = New-Object System.Windows.Forms.DataGridView
        $grid.Dock = 'Fill'; $grid.ReadOnly = $true; $grid.AllowUserToAddRows = $false
        $grid.RowHeadersVisible = $false; $grid.AutoSizeColumnsMode = 'AllCells'
        $grid.DataSource = (New-Object System.Collections.ArrayList (,$rows))
        $pnl = New-Object System.Windows.Forms.FlowLayoutPanel
        $pnl.Dock = 'Bottom'; $pnl.FlowDirection = 'RightToLeft'; $pnl.Height = S 50; $pnl.Padding = Pd 8 8 8 8
        $btnClose = New-Object System.Windows.Forms.Button
        $btnClose.Text = (T 'Close'); $btnClose.Size = Sz 90 34; $btnClose.DialogResult = 'Cancel'
        $btnFolder = New-Object System.Windows.Forms.Button
        $btnFolder.Text = (T 'Open log folder'); $btnFolder.Size = Sz 150 34
        $btnFolder.Add_Click({ Start-Process explorer.exe -ArgumentList "`"$LogDir`"" })
        $pnl.Controls.Add($btnClose); $pnl.Controls.Add($btnFolder)
        $dlg.Controls.Add($grid); $dlg.Controls.Add($pnl)
        $dlg.CancelButton = $btnClose
        Apply-Theme $dlg
        [void]$dlg.ShowDialog($form)
    }

    function Show-DoneNotification([string]$Title, [string]$Text) {
        try {
            if ($null -ne [System.Windows.Forms.Form]::ActiveForm) { return }   # the window is in front: no balloon needed
            if (-not $script:Notify) {
                $script:Notify = New-Object System.Windows.Forms.NotifyIcon
                $script:Notify.Icon = [System.Drawing.SystemIcons]::Information
            }
            $script:Notify.Visible = $true
            $script:Notify.ShowBalloonTip(8000, $Title, $Text, [System.Windows.Forms.ToolTipIcon]::Info)
        } catch { }
    }

    # ----- layout that follows the window size
    # Controls whose maximum width follows the window (labels that wrap, the toolbar...).
    # Base 'form' = the width of the window, 'flow' = the width of the scrolling step list.
    function Add-Wrap($Ctl, [string]$Base, [double]$Offset) {
        [void]$script:WrapList.Add(@{ Ctl = $Ctl; Base = $Base; Offset = (S $Offset) })
    }

    function Update-Layout {
        $f = $script:UI.form
        if (-not $f -or $f.IsDisposed -or $script:InLayout) { return }
        $cw = $f.ClientSize.Width
        if ($cw -lt 100) { return }
        $script:InLayout = $true      # setting sizes below can raise size events again
        $inner = $cw - (S 40)
        $flowW = $inner
        $flow  = $script:UI.flow
        if ($flow -and $flow.Width -ge (S 300)) {
            # the outer width, so that the scrollbar appearing does not change the result
            $flowW = [math]::Max((S 200), $flow.Width - [System.Windows.Forms.SystemInformation]::VerticalScrollBarWidth - (S 8))
        }
        $f.SuspendLayout()
        if ($flow) { $flow.SuspendLayout() }
        try {
            if ($script:UI.toolbar) {
                # A wrapping panel in an auto-sized column collapses to one column of buttons, so it gets
                # a definite width: wide enough for one row when there is room, narrower (wrapping) when not.
                $tw = [math]::Max((S 300), [math]::Min((S 640), $cw - (S 340)))
                $script:UI.toolbar.MinimumSize = New-Object System.Drawing.Size -ArgumentList $tw, 0
                $script:UI.toolbar.MaximumSize = New-Object System.Drawing.Size -ArgumentList $tw, 0
                if ($script:UI.headTable) {
                    $col = $script:UI.headTable.ColumnStyles[1]
                    $col.SizeType = [System.Windows.Forms.SizeType]::Absolute
                    $col.Width    = $tw + (S 6)
                }
            }
            if ($script:UI.presetPanel) {
                $script:UI.presetPanel.MaximumSize = New-Object System.Drawing.Size -ArgumentList $inner, 0
            }
            foreach ($card in $script:CardList) {
                $card.MinimumSize = New-Object System.Drawing.Size -ArgumentList $flowW, 0
                $card.MaximumSize = New-Object System.Drawing.Size -ArgumentList $flowW, 0
            }
            foreach ($e in $script:WrapList) {
                if ($e.Base -eq 'flow') { $base = $flowW } else { $base = $inner }
                $e.Ctl.MaximumSize = New-Object System.Drawing.Size -ArgumentList ([math]::Max((S 120), $base - $e.Offset)), 0
            }
            $lv = $script:UI.lvSteps
            if ($lv -and $lv.Columns.Count -ge 3 -and $lv.ClientSize.Width -gt (S 360)) {
                $lv.Columns[0].Width = $lv.ClientSize.Width - (S 270)
                $lv.Columns[1].Width = S 170
                $lv.Columns[2].Width = S 90
            }
        } finally {
            if ($flow) { $flow.ResumeLayout($true) }
            $f.ResumeLayout($true)
            $script:InLayout = $false
        }
    }

    # The steps are shown in these groups (the run order is still by step number).
    $script:StepGroup = @{
        1 = 'Protect and update'; 2 = 'Protect and update'; 6 = 'Protect and update'; 9 = 'Protect and update'
        3 = 'Clean up'; 4 = 'Clean up'; 10 = 'Clean up'; 19 = 'Clean up'
        5 = 'Repair and optimize'; 7 = 'Repair and optimize'
        8 = 'Check and report'; 11 = 'Check and report'; 12 = 'Check and report'; 13 = 'Check and report'; 14 = 'Check and report'
        15 = 'Check and report'; 16 = 'Check and report'; 17 = 'Check and report'; 18 = 'Check and report'
    }
    $script:StepGroupOrder = @('Protect and update', 'Clean up', 'Repair and optimize', 'Check and report')

    # ----- the step cards
    function New-StepCard($Info) {
        $id = [int]$Info.Id
        switch ([string]$Info.Risk) {
            'ReadOnly' { $riskColor = $script:ColGreen; $riskText = T 'Read-only' }
            'Deletes'  { $riskColor = $script:ColRed;   $riskText = T 'Deletes files' }
            default    { $riskColor = $script:ColAmber; $riskText = T 'Changes the system' }
        }

        # a card = colored strip on the left (the risk) + the content
        $card = New-Object System.Windows.Forms.TableLayoutPanel
        $card.ColumnCount = 2
        $card.RowCount    = 1
        [void]$card.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, (S 4))))
        [void]$card.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
        [void]$card.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
        $card.AutoSize     = $true
        $card.AutoSizeMode = 'GrowAndShrink'
        $card.Margin       = Pd 0 0 0 8
        $card.Padding      = Pd 0 0 0 0
        $card.BackColor    = $script:ColCard
        [void]$script:CardList.Add($card)

        $strip = New-Object System.Windows.Forms.Panel
        $strip.Dock      = 'Fill'
        $strip.Margin    = Pd 0 0 0 0
        $strip.BackColor = $riskColor
        $card.Controls.Add($strip, 0, 0)

        $content = New-Object System.Windows.Forms.FlowLayoutPanel
        $content.FlowDirection = 'TopDown'
        $content.WrapContents  = $false
        $content.AutoSize      = $true
        $content.AutoSizeMode  = 'GrowAndShrink'
        $content.Dock          = 'Fill'
        $content.Margin        = Pd 0 0 0 0
        $content.Padding       = Pd 12 9 12 9
        $card.Controls.Add($content, 1, 0)

        $chk = New-Object System.Windows.Forms.CheckBox
        $chk.AutoSize = $true
        # on a server only read-only steps start ticked; the Deletes step "extra caches" is always opt-in
        $chk.Checked  = ($Info.DefaultOn -ne $false) -and ($script:RunMode -eq 'Pc' -or $Info.Risk -eq 'ReadOnly')
        $chk.Font     = $script:FontBold
        $chk.Text     = (T $Info.Title)
        $chk.Margin   = Pd 0 0 0 0
        $content.Controls.Add($chk)

        $desc = New-Object System.Windows.Forms.Label
        $desc.AutoSize    = $true
        $desc.Font        = $script:FontSmall
        $desc.ForeColor   = $script:ColMuted
        $desc.Margin      = Pd 22 2 0 0
        $desc.Text        = (T $Info.Desc)
        $content.Controls.Add($desc)
        Add-Wrap $desc 'flow' 62

        # small facts under the description: step number, how long, how risky
        $pnlFacts = New-Object System.Windows.Forms.FlowLayoutPanel
        $pnlFacts.FlowDirection = 'LeftToRight'
        $pnlFacts.WrapContents  = $true
        $pnlFacts.AutoSize      = $true
        $pnlFacts.Margin        = Pd 22 4 0 0
        foreach ($f in @(
            @{ Text = ((T 'Step {0}') -f $Info.Id); Color = $script:ColMuted; Font = $script:FontSmall },
            @{ Text = (T $Info.Time);               Color = $script:ColMuted; Font = $script:FontSmall },
            @{ Text = $riskText;                    Color = $riskColor;       Font = $script:FontSmallBold }
        )) {
            $fl = New-Object System.Windows.Forms.Label
            $fl.AutoSize  = $true
            $fl.Text      = $f.Text
            $fl.ForeColor = $f.Color
            $fl.Font      = $f.Font
            $fl.Margin    = Pd 0 0 16 0
            $pnlFacts.Controls.Add($fl)
        }
        $content.Controls.Add($pnlFacts)
        Add-Wrap $pnlFacts 'flow' 62

        $why = $script:Unavailable[$id]
        if ($why) {
            $lblWhy = New-Object System.Windows.Forms.Label
            $lblWhy.AutoSize    = $true
            $lblWhy.Font        = $script:FontSmallBold
            $lblWhy.ForeColor   = $script:ColAmber
            $lblWhy.Margin      = Pd 22 4 0 0
            $lblWhy.Text        = ((T 'Not available: {0}') -f $why)
            $content.Controls.Add($lblWhy)
            Add-Wrap $lblWhy 'flow' 62
        }

        # step 2: pick the programs to update
        $pnlPick = $null
        if ($id -eq 2) {
            $pnlPick = New-Object System.Windows.Forms.FlowLayoutPanel
            $pnlPick.FlowDirection = 'LeftToRight'
            $pnlPick.WrapContents  = $false
            $pnlPick.AutoSize      = $true
            $pnlPick.Margin        = Pd 22 8 0 0
            $btnPick = New-Object System.Windows.Forms.Button
            $btnPick.Text     = (T 'Choose which programs to update...')
            $btnPick.AutoSize = $true
            $btnPick.Padding  = Pd 8 3 8 3
            $btnPick.Add_Click({ Show-WingetChooser })
            $lblSel = New-Object System.Windows.Forms.Label
            $lblSel.AutoSize  = $true
            $lblSel.Font      = $script:FontSmall
            $lblSel.ForeColor = $script:ColMuted
            $lblSel.Margin    = Pd 10 8 0 0
            $script:UI.lblWingetSel = $lblSel
            $pnlPick.Controls.Add($btnPick)
            $pnlPick.Controls.Add($lblSel)
            $content.Controls.Add($pnlPick)
            Update-WingetLabel
        }

        $optPanel = $null
        $combos   = @()
        $defs     = @($script:StepOptions[$id])
        if ($defs.Count -gt 0) {
            $optPanel = New-Object System.Windows.Forms.FlowLayoutPanel
            $optPanel.FlowDirection = 'LeftToRight'
            $optPanel.WrapContents  = $true
            $optPanel.AutoSize      = $true
            $optPanel.AutoSizeMode  = 'GrowAndShrink'
            $optPanel.Margin        = Pd 22 8 0 0
            $optPanel.Visible       = $false

            foreach ($d in $defs) {
                $lbl = New-Object System.Windows.Forms.Label
                $lbl.AutoSize  = $true
                $lbl.Text      = (T $d.Label)
                $lbl.Font      = $script:FontSmall
                $lbl.Margin    = Pd 0 6 6 0
                $optPanel.Controls.Add($lbl)

                $combo = New-Object System.Windows.Forms.ComboBox
                $combo.DropDownStyle = 'DropDownList'
                $combo.Width  = S 330
                $combo.Font   = $script:FontSmall
                $combo.Margin = Pd 0 2 18 4
                foreach ($itemText in $d.Items) { [void]$combo.Items.Add((T $itemText)) }
                $combo.SelectedIndex = [int]$d.Default
                $combo.Tag = @{ Key = $d.Key; Values = $d.Values }
                $optPanel.Controls.Add($combo)
                $combos += $combo
            }
            $content.Controls.Add($optPanel)
            Add-Wrap $optPanel 'flow' 62
        }

        $script:StepCtl[$id] = @{ Check = $chk; Options = $optPanel; Combos = $combos }
        $chk.Tag = @{ Options = $optPanel; Pick = $pnlPick }
        if ($why) {
            $chk.Checked = $false
            $chk.Enabled = $false
            if ($optPanel) { $optPanel.Enabled = $false }
            if ($pnlPick)  { $pnlPick.Enabled  = $false }
        }
        $chk.Add_CheckedChanged({
            param($sender, $e)
            if ($sender.Tag.Options) { $sender.Tag.Options.Enabled = $sender.Checked }
            if ($sender.Tag.Pick)    { $sender.Tag.Pick.Enabled    = $sender.Checked }
        })
        return $card
    }

    # Reads the window and builds the settings for the engine
    function Get-RunOptions {
        param([switch]$Preview)
        $o = New-RunOptions
        $ids = @($script:StepCtl.Keys | Where-Object { $script:StepCtl[$_].Check.Checked -and $script:StepCtl[$_].Check.Enabled } |
                 Sort-Object | ForEach-Object { [int]$_ })
        if ($Preview) { $ids = @($ids | Where-Object { $PreviewIds -contains $_ }) }
        $o.Steps   = [int[]]$ids
        $o.Preview = [bool]$Preview
        $o.MaintenanceWindow = ($script:MaintWindow -eq $true) -or [bool]$MaintenanceWindow
        if ($script:WingetPick) { $o.WingetIds = @($script:WingetPick) }
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
        if ($Preview) { $o.Reboot = $false; $o.WindowsUpdateMode = 'Scan' }
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
                Set-ItemStatus $item (T 'Running...') $script:ColBlue
                if ($item) { $item.EnsureVisible() }
                $script:UI.lblNow.Text = ((T 'Now: {0}   (usually {1})') -f $script:StepTitle[$id], $script:StepTime[$id])
                $script:Run.Current = $id
            } else {
                switch ($p[3]) {
                    'OK'      { Set-ItemStatus $item (T 'Done')    $script:ColGreen }
                    'Failed'  { Set-ItemStatus $item (T 'Failed')  $script:ColRed }
                    default   { Set-ItemStatus $item (T 'Skipped') $script:ColMuted }
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
        $script:UI.btnReport.Visible  = $false
        $script:WingetPick  = $null
        $script:MaintWindow = $null
        Update-WingetLabel

        $d = $r.Done
        if (-not $d) {
            $script:UI.lblTitle.Text      = (T 'Something went wrong')
            $script:UI.lblTitle.ForeColor = $script:ColRed
            $script:UI.lblSummary.Text    = (T 'The maintenance did not finish properly. Tick "Show technical details" to see what happened.')
            $script:UI.chkDetails.Checked = $true
            return
        }

        if ($r.Opt.Preview) {
            $script:UI.lblTitle.Text      = (T 'Preview finished')
            $script:UI.lblTitle.ForeColor = $script:ColGreen
            $script:UI.lblSummary.Text    = (T 'Nothing was changed. The technical details below show what would happen.')
            $script:UI.chkDetails.Checked = $true
            Show-DoneNotification (T 'Preview finished') (T 'Nothing was changed.')
            return
        }

        $failed = [int]$d[3]
        $warn = 0
        if ($d.Count -gt 9) { $warn = [int]$d[9] }
        if ($d[6] -eq 'True') {
            $script:UI.lblTitle.Text = (T 'Stopped: charger not connected'); $script:UI.lblTitle.ForeColor = $script:ColRed
        } elseif ($d[5] -eq 'True') {
            $script:UI.lblTitle.Text = (T 'Stopped as requested'); $script:UI.lblTitle.ForeColor = $script:ColAmber
        } elseif ($failed -gt 0) {
            $script:UI.lblTitle.Text = (T 'Finished, but some steps had problems'); $script:UI.lblTitle.ForeColor = $script:ColAmber
        } elseif ($warn -gt 0) {
            $script:UI.lblTitle.Text = (T 'Finished, with warnings'); $script:UI.lblTitle.ForeColor = $script:ColAmber
        } else {
            $script:UI.lblTitle.Text = (T 'All done!'); $script:UI.lblTitle.ForeColor = $script:ColGreen
        }
        $text = ((T 'Space freed: {0} GB      Time taken: {1}') -f $d[1], $d[2])
        if ($failed -gt 0) { $text += "`r`n" + ((T '{0} step(s) failed - tick "Show technical details" to see why.') -f $failed) }
        if ($warn -gt 0) { $text += "`r`n" + ((T '{0} warning(s) found - see the WARN lines in the technical details or the report.') -f $warn) }
        if ($d[4] -eq 'True') { $text += "`r`n" + (T 'Windows would like a restart to finish some changes.') }
        $script:UI.lblSummary.Text = $text
        if ($d.Count -gt 8 -and $d[8] -and (Test-Path -LiteralPath $d[8])) {
            $script:LastReport = $d[8]
            $script:UI.btnReport.Visible = $true
        }
        Show-DoneNotification $script:UI.lblTitle.Text ($text -split "`r`n")[0]

        if ($r.Opt.Reboot -and $d[5] -ne 'True' -and $d[6] -ne 'True') {
            & shutdown.exe /r /t 60 /c "PC Maintenance finished - restarting"
            $restartMsg = (T 'Maintenance is finished. Your PC will restart in 60 seconds.') + "`r`n`r`n" + (T 'Do you want to cancel the restart?')
            $answer = Show-Message $restartMsg (T 'Restarting soon') 'YesNo' 'Question'
            if ($answer -eq 'Yes') { & shutdown.exe /a }
        }
    }

    function Start-Run {
        param([switch]$Preview)
        $o = Get-RunOptions -Preview:$Preview
        Save-Settings

        Remove-Item -LiteralPath $CancelFile -Force -ErrorAction SilentlyContinue
        [void](Open-RunLog)

        # switch to the progress view
        $script:UI.lvSteps.Items.Clear()
        $script:UI.txtLog.Clear()
        $items = @{}
        foreach ($si in $StepInfo) {
            if ($o.Steps -contains [int]$si.Id) {
                $li = New-Object System.Windows.Forms.ListViewItem((T $si.Title))
                [void]$li.SubItems.Add((T 'Waiting'))
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
        if ($Preview) { $script:UI.lblTitle.Text = (T 'Preview is running...') } else { $script:UI.lblTitle.Text = (T 'Maintenance is running...') }
        $script:UI.lblTitle.ForeColor = $script:ColText
        $script:UI.lblSummary.Text    = (T 'Please leave this window open. You can keep using your PC, but avoid closing programs that are being updated.')
        $script:UI.lblNow.Text        = (T 'Starting...')
        $script:UI.btnStop.Text       = (T 'Stop after this step')
        $script:UI.btnStop.Enabled    = $true
        $script:UI.btnStop.Visible    = $true
        $script:UI.btnBack.Enabled    = $false
        $script:UI.btnLogs.Enabled    = $true
        $script:UI.btnClose.Enabled   = $false
        $script:UI.btnReport.Visible  = $false
        $script:UI.pnlSetup.Visible   = $false
        $script:UI.pnlRun.Visible     = $true
        Update-Layout

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

    # =============================================================================
    #  Build the window. The language and theme buttons close it and build it again.
    # =============================================================================
    $script:Restart = $false
    $script:Notify  = $null
    do {
        $script:Restart  = $false
        $script:Settings = Read-Settings

        $script:Lang = [string](Get-Setting 'Language' '')
        if ($script:Lang -notin @('en', 'nl')) {
            $script:Lang = 'en'
            try { if ((Get-UICulture).TwoLetterISOLanguageName -eq 'nl') { $script:Lang = 'nl' } } catch { }
        }
        $script:Theme = [string](Get-Setting 'Theme' '')
        if ($script:Theme -notin @('light', 'dark')) {
            $script:Theme = 'light'
            try {
                $lightApps = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -ErrorAction Stop).AppsUseLightTheme
                if ($lightApps -eq 0) { $script:Theme = 'dark' }
            } catch { }
        }
        Set-ThemeColors

        # ----- look and feel
        $script:FontNormal = New-Object System.Drawing.Font('Segoe UI', 10)
        $script:FontBold   = New-Object System.Drawing.Font('Segoe UI Semibold', 10.5)
        $script:FontTitle  = New-Object System.Drawing.Font('Segoe UI Semibold', 20)
        $script:FontSmall  = New-Object System.Drawing.Font('Segoe UI', 9)
        $script:FontMono   = New-Object System.Drawing.Font('Consolas', 9)
        $script:FontSmallBold = New-Object System.Drawing.Font('Segoe UI Semibold', 9)
        $script:FontGroup  = New-Object System.Drawing.Font('Segoe UI Semibold', 9.5)

        # ----- dropdown settings per step (shown in "advanced options")
        $driveItems  = @('All drives (recommended)')
        $driveValues = @('All')
        try {
            $fixedVols = @(Get-Volume | Where-Object {
                $_.DriveLetter -and $_.DriveType -eq 'Fixed' -and $_.FileSystemType -in 'NTFS', 'ReFS'
            } | Sort-Object DriveLetter)
            foreach ($v in $fixedVols) {
                $driveItems  += ((T 'Only drive {0}:') -f $v.DriveLetter)
                $driveValues += [string]$v.DriveLetter
            }
        } catch { }

        $yesNo = @('Yes (recommended)', 'No')
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
            7 = @( @{ Key = 'OptimizeAction'; Label = 'What to do:';
                      Items = @('Optimize: TRIM for SSDs, defrag for hard disks (recommended on a PC)', 'Analyze only (nothing is changed, recommended on a server)');
                      Values = @('Optimize', 'Analyze'); Default = $(if ($RunMode -eq 'Server') { 1 } else { 0 }) },
                   @{ Key = 'OptimizeDrive'; Label = 'Which drives:';
                      Items = $driveItems; Values = $driveValues; Default = 0 } )
            8 = @()
            9 = @( @{ Key = 'WindowsUpdateMode'; Label = 'What to do with updates:';
                      Items = @('Only look for updates (recommended)', 'Download and install them (no automatic restart)'); Values = @('Scan', 'Install'); Default = 0 } )
            10 = @( @{ Key = 'CacheWindowsUpdate'; Label = 'Windows Update download cache:';
                       Items = $yesNo; Values = @($true, $false); Default = 0 },
                    @{ Key = 'CacheDeliveryOpt'; Label = 'Delivery Optimization cache:';
                       Items = $yesNo; Values = @($true, $false); Default = 0 },
                    @{ Key = 'CacheBrowsers'; Label = 'Browser caches:';
                       Items = $yesNo; Values = @($true, $false); Default = 0 } )
            11 = @()
            12 = @()
            13 = @( @{ Key = 'DiskScan'; Label = 'Online disk scan:';
                       Items = @('Skip it (recommended)', 'Run a read-only scan of each drive (slow)'); Values = @($false, $true); Default = 0 } )
            14 = @()
            15 = @()
            16 = @()
            17 = @()
            18 = @()
            19 = @( @{ Key = 'ServerCleanComponents'; Label = 'Component store (DISM):';
                       Items = $yesNo; Values = @($true, $false); Default = 0 },
                    @{ Key = 'ServerCleanWuCache'; Label = 'Windows Update download cache:';
                       Items = $yesNo; Values = @($true, $false); Default = 0 },
                    @{ Key = 'ServerCleanTemp'; Label = 'Old temp files:';
                       Items = $yesNo; Values = @($true, $false); Default = 0 },
                    @{ Key = 'IisLogDays'; Label = 'Delete IIS logs older than:';
                       Items = @('Leave IIS logs alone', '30 days', '90 days (recommended)', '180 days', '365 days');
                       Values = @(0, 30, 90, 180, 365); Default = 2 } )
        }

        $script:StepCtl   = @{}     # step id -> controls
        $script:StepTitle = @{}
        $script:StepTime  = @{}
        foreach ($si in $StepInfo) {
            $script:StepTitle[[int]$si.Id] = (T $si.Title)
            $script:StepTime[[int]$si.Id]  = (T $si.Time)
        }
        $script:Run        = $null
        $script:WingetPick = $null
        $script:LastReport = $null
        $script:UI         = @{}

        # ======================= build the window =======================
        $script:WrapList = New-Object System.Collections.ArrayList
        $script:CardList = New-Object System.Collections.ArrayList
        $script:InLayout = $false

        # size: the remembered one (or a default), never bigger than the screen
        $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $startW = S 1000
        $startH = S 780
        $savedW = [double](Get-Setting 'Width' 0)
        $savedH = [double](Get-Setting 'Height' 0)
        if ($savedW -gt 0 -and $savedH -gt 0) { $startW = [int]($savedW * $script:Scale); $startH = [int]($savedH * $script:Scale) }
        $startW = [math]::Max((S 760), [math]::Min($startW, $wa.Width))
        $startH = [math]::Max((S 540), [math]::Min($startH, $wa.Height))

        $form = New-Object System.Windows.Forms.Form
        $form.Text            = 'PC Maintenance'
        $form.StartPosition   = 'CenterScreen'
        $form.Size            = New-Object System.Drawing.Size -ArgumentList $startW, $startH
        $form.MinimumSize     = Sz 760 540      # no maximum: the window can be any size
        $form.MaximizeBox     = $true
        $form.Font            = $script:FontNormal
        $form.BackColor       = $script:ColBack
        $form.ForeColor       = $script:ColText
        if ((Get-Setting 'Maximized' $false) -eq $true) { $form.WindowState = 'Maximized' }
        $script:UI.form = $form

        # ---------- setup view: header, quick select, steps (scrolls), advanced options, footer
        $pnlSetup = New-Object System.Windows.Forms.TableLayoutPanel
        $pnlSetup.Dock        = 'Fill'
        $pnlSetup.ColumnCount = 1
        $pnlSetup.RowCount    = 5
        $pnlSetup.Padding     = Pd 20 14 20 12
        [void]$pnlSetup.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
        [void]$pnlSetup.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
        [void]$pnlSetup.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
        [void]$pnlSetup.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
        [void]$pnlSetup.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
        $script:UI.pnlSetup = $pnlSetup

        # header: title and toolbar on one line, the explanation below
        $tlpHead = New-Object System.Windows.Forms.TableLayoutPanel
        $tlpHead.ColumnCount = 2
        $tlpHead.RowCount    = 2
        $tlpHead.AutoSize    = $true
        $tlpHead.Dock        = 'Fill'
        $tlpHead.Margin      = Pd 0 0 0 10
        $script:UI.headTable = $tlpHead
        [void]$tlpHead.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
        [void]$tlpHead.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
        [void]$tlpHead.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
        [void]$tlpHead.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))

        $lblHead = New-Object System.Windows.Forms.Label
        $lblHead.Text     = 'PC Maintenance'
        $lblHead.Font     = $script:FontTitle
        $lblHead.ForeColor = $script:ColText
        $lblHead.AutoSize = $true
        $lblHead.Margin   = Pd 0 0 12 0
        $tlpHead.Controls.Add($lblHead, 0, 0)

        $pnlTools = New-Object System.Windows.Forms.FlowLayoutPanel
        $pnlTools.FlowDirection = 'LeftToRight'
        $pnlTools.WrapContents  = $true
        $pnlTools.AutoSize      = $true
        $pnlTools.AutoSizeMode  = 'GrowAndShrink'
        $pnlTools.Anchor        = 'Top, Right'
        $pnlTools.Margin        = Pd 0 6 0 0
        $script:UI.toolbar = $pnlTools
        $langText  = if ($script:Lang -eq 'nl') { 'English' } else { 'Nederlands' }
        $themeText = if ($script:Theme -eq 'dark') { T 'Light mode' } else { T 'Dark mode' }
        foreach ($u in @(
            @{ Key = 'Preview';  Text = (T 'Preview cleanup') },
            @{ Key = 'Tools';    Text = (T 'Tools...') },
            @{ Key = 'Schedule'; Text = (T 'Schedule...') },
            @{ Key = 'History';  Text = (T 'History...') },
            @{ Key = 'Lang';     Text = $langText },
            @{ Key = 'Theme';    Text = $themeText }
        )) {
            $ub = New-Object System.Windows.Forms.Button
            $ub.Name = 'ghost'
            $ub.Text = $u.Text; $ub.AutoSize = $true; $ub.Padding = Pd 8 3 8 3; $ub.Margin = Pd 0 0 2 2
            $ub.Tag  = $u.Key
            $ub.Add_Click({
                param($sender, $e)
                switch ($sender.Tag) {
                    'Preview' {
                        $ids = @($script:StepCtl.Keys | Where-Object { $script:StepCtl[$_].Check.Checked -and $script:StepCtl[$_].Check.Enabled -and ($PreviewIds -contains [int]$_) })
                        if ($ids.Count -eq 0) {
                            [void](Show-Message (T 'The preview works for steps 2, 4, 10 and 19. Tick at least one of them.') (T 'Preview cleanup') 'OK' 'Information')
                        } else { Start-Run -Preview }
                    }
                    'Tools'    { Show-ToolsDialog }
                    'Schedule' { Show-ScheduleDialog }
                    'History'  { Show-HistoryDialog }
                    'Lang'     { $script:Lang  = if ($script:Lang -eq 'nl') { 'en' } else { 'nl' }; Save-Settings; $script:Restart = $true; $form.Close() }
                    'Theme'    { $script:Theme = if ($script:Theme -eq 'dark') { 'light' } else { 'dark' }; Save-Settings; $script:Restart = $true; $form.Close() }
                }
            })
            $pnlTools.Controls.Add($ub)
        }
        $tlpHead.Controls.Add($pnlTools, 1, 0)

        $pnlInfo = New-Object System.Windows.Forms.FlowLayoutPanel
        $pnlInfo.FlowDirection = 'TopDown'
        $pnlInfo.WrapContents  = $false
        $pnlInfo.AutoSize      = $true
        $pnlInfo.Margin        = Pd 0 2 0 0
        $lblMode = New-Object System.Windows.Forms.Label
        $lblMode.Text        = ((T 'Mode: {0}   |   {1}') -f $ModeLabel, $SystemInfo.Text)
        $lblMode.Font        = $script:FontSmallBold
        $lblMode.ForeColor   = $script:ColAccent
        $lblMode.AutoSize    = $true
        $lblMode.Margin      = Pd 0 0 0 2
        Add-Wrap $lblMode 'form' 0
        $lblSub = New-Object System.Windows.Forms.Label
        $lblSub.Text        = (T 'Tick what you would like to do, then press "Start maintenance". If you are not sure, leave everything as it is - the default choices are safe.')
        $lblSub.Font        = $script:FontNormal
        $lblSub.ForeColor   = $script:ColMuted
        $lblSub.AutoSize    = $true
        $lblSub.Margin      = Pd 0 0 0 0
        Add-Wrap $lblSub 'form' 0
        $pnlInfo.Controls.Add($lblMode)
        $pnlInfo.Controls.Add($lblSub)
        $tlpHead.Controls.Add($pnlInfo, 0, 1)
        $tlpHead.SetColumnSpan($pnlInfo, 2)
        $pnlSetup.Controls.Add($tlpHead, 0, 0)

        # quick select
        $pnlPre = New-Object System.Windows.Forms.FlowLayoutPanel
        $pnlPre.FlowDirection = 'LeftToRight'
        $pnlPre.WrapContents  = $true
        $pnlPre.AutoSize      = $true
        $pnlPre.Margin        = Pd 0 0 0 8
        $script:UI.presetPanel = $pnlPre
        $lblQuick = New-Object System.Windows.Forms.Label
        $lblQuick.Text = (T 'Quick select:'); $lblQuick.AutoSize = $true; $lblQuick.Font = $script:FontSmallBold
        $lblQuick.ForeColor = $script:ColMuted
        $lblQuick.Margin = Pd 0 7 10 0
        $pnlPre.Controls.Add($lblQuick)
        if ($RunMode -eq 'Server') {
            $presetButtons = @(
                @{ Text = 'Select everything'; Mode = 'Skip'; Ids = @() },
                @{ Text = 'Select nothing';    Mode = 'Only'; Ids = @() },
                @{ Text = 'Server check';      Mode = 'Only'; Ids = $Presets.ServerCheck }
            )
        } else {
            $presetButtons = @(
                @{ Text = 'Select everything';        Mode = 'Skip'; Ids = @() },
                @{ Text = 'Select nothing';           Mode = 'Only'; Ids = @() },
                @{ Text = 'Everything except the slow repair'; Mode = 'Skip'; Ids = @(5) },
                @{ Text = 'Quick tune-up';            Mode = 'Only'; Ids = $Presets.QuickTuneUp },
                @{ Text = 'Deep clean';               Mode = 'Only'; Ids = $Presets.DeepClean },
                @{ Text = 'Weekly safe';              Mode = 'Only'; Ids = $Presets.WeeklySafe }
            )
        }
        foreach ($b in $presetButtons) {
            $btn = New-Object System.Windows.Forms.Button
            $btn.Text     = (T $b.Text)
            $btn.AutoSize = $true
            $btn.Padding  = Pd 8 3 8 3
            $btn.Margin   = Pd 0 0 8 4
            $btn.Tag      = @{ Mode = $b.Mode; Ids = @($b.Ids) }
            $btn.Add_Click({
                param($sender, $e)
                $t = $sender.Tag
                foreach ($sid in $script:StepCtl.Keys) {
                    if (-not $script:StepCtl[$sid].Check.Enabled) { continue }
                    if ($t.Mode -eq 'Skip') { $script:StepCtl[$sid].Check.Checked = (@($t.Ids) -notcontains [int]$sid) }
                    else                    { $script:StepCtl[$sid].Check.Checked = (@($t.Ids) -contains [int]$sid) }
                }
            })
            $pnlPre.Controls.Add($btn)
        }
        $pnlSetup.Controls.Add($pnlPre, 0, 1)

        # the step cards, in groups, in a scrolling list that follows the window width
        $flow = New-Object System.Windows.Forms.FlowLayoutPanel
        $flow.Dock          = 'Fill'
        $flow.FlowDirection = 'TopDown'
        $flow.WrapContents  = $false
        $flow.AutoScroll    = $true
        $flow.Padding       = Pd 0 0 0 4
        $script:UI.flow = $flow
        foreach ($grp in $script:StepGroupOrder) {
            $members = @($StepInfo | Where-Object { $ModeStepIds -contains [int]$_.Id -and $script:StepGroup[[int]$_.Id] -eq $grp })
            if ($members.Count -eq 0) { continue }
            $lblGrp = New-Object System.Windows.Forms.Label
            $lblGrp.Text      = (T $grp).ToUpper()
            $lblGrp.Font      = $script:FontGroup
            $lblGrp.ForeColor = $script:ColMuted
            $lblGrp.AutoSize  = $true
            $lblGrp.Margin    = Pd 2 8 0 6
            $flow.Controls.Add($lblGrp)
            foreach ($si in $members) { $flow.Controls.Add((New-StepCard $si)) }
        }
        $pnlSetup.Controls.Add($flow, 0, 2)

        # global advanced options
        $pnlGlobal = New-Object System.Windows.Forms.FlowLayoutPanel
        $pnlGlobal.FlowDirection = 'LeftToRight'
        $pnlGlobal.WrapContents  = $true
        $pnlGlobal.AutoSize      = $true
        $pnlGlobal.BackColor     = $script:ColCard
        $pnlGlobal.Padding       = Pd 12 8 12 8
        $pnlGlobal.Margin        = Pd 0 6 0 4
        $pnlGlobal.Visible       = $false
        $lblCh = New-Object System.Windows.Forms.Label
        $lblCh.Text = (T 'Charger check:'); $lblCh.AutoSize = $true; $lblCh.Font = $script:FontSmall
        $lblCh.Margin = Pd 0 6 6 0
        $cmbCharger = New-Object System.Windows.Forms.ComboBox
        $cmbCharger.DropDownStyle = 'DropDownList'; $cmbCharger.Width = S 250; $cmbCharger.Font = $script:FontSmall
        [void]$cmbCharger.Items.Add((T 'Laptop must be plugged in (recommended)'))
        [void]$cmbCharger.Items.Add((T 'Skip the charger check'))
        $cmbCharger.SelectedIndex = 0
        $cmbCharger.Margin = Pd 0 2 18 2
        $lblFin = New-Object System.Windows.Forms.Label
        $lblFin.Text = (T 'When finished:'); $lblFin.AutoSize = $true; $lblFin.Font = $script:FontSmall
        $lblFin.Margin = Pd 0 6 6 0
        $cmbFinish = New-Object System.Windows.Forms.ComboBox
        $cmbFinish.DropDownStyle = 'DropDownList'; $cmbFinish.Width = S 220; $cmbFinish.Font = $script:FontSmall
        [void]$cmbFinish.Items.Add((T 'Do nothing'))
        [void]$cmbFinish.Items.Add((T 'Restart my PC (60 seconds warning)'))
        $cmbFinish.SelectedIndex = 0
        $cmbFinish.Margin = Pd 0 2 0 2
        foreach ($c in @($lblCh, $cmbCharger, $lblFin, $cmbFinish)) { $pnlGlobal.Controls.Add($c) }
        $script:UI.cmbCharger = $cmbCharger
        $script:UI.cmbFinish  = $cmbFinish
        $pnlSetup.Controls.Add($pnlGlobal, 0, 3)

        # footer: a line, the power status and advanced toggle on the left, the buttons on the right
        $tlpFoot = New-Object System.Windows.Forms.TableLayoutPanel
        $tlpFoot.AutoSize    = $true
        $tlpFoot.Dock        = 'Fill'
        $tlpFoot.ColumnCount = 2
        $tlpFoot.RowCount    = 2
        [void]$tlpFoot.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
        [void]$tlpFoot.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
        $sep = New-Object System.Windows.Forms.Panel
        $sep.Height    = [math]::Max(1, (S 1))
        $sep.Dock      = 'Fill'
        $sep.BackColor = $script:ColBorder
        $sep.Margin    = Pd 0 4 0 10
        $tlpFoot.Controls.Add($sep, 0, 0)
        $tlpFoot.SetColumnSpan($sep, 2)

        $pnlFootLeft = New-Object System.Windows.Forms.FlowLayoutPanel
        $pnlFootLeft.FlowDirection = 'TopDown'
        $pnlFootLeft.WrapContents  = $false
        $pnlFootLeft.AutoSize      = $true
        $pnlFootLeft.Margin        = Pd 0 0 0 0
        $lblPower = New-Object System.Windows.Forms.Label
        $lblPower.AutoSize = $true
        $lblPower.Font     = $script:FontSmall
        $lblPower.Margin   = Pd 0 2 0 6
        $script:UI.lblPower = $lblPower
        $chkAdv = New-Object System.Windows.Forms.CheckBox
        $chkAdv.Text     = (T 'Show advanced options')
        $chkAdv.AutoSize = $true
        $chkAdv.Margin   = Pd 0 0 0 0
        $script:UI.chkAdv = $chkAdv
        $chkAdv.Add_CheckedChanged({
            $show = $script:UI.chkAdv.Checked
            foreach ($sid in $script:StepCtl.Keys) {
                $op = $script:StepCtl[$sid].Options
                if ($op) { $op.Visible = $show }
            }
            $script:UI.cmbCharger.Parent.Visible = $show
        })
        $pnlFootLeft.Controls.Add($lblPower)
        $pnlFootLeft.Controls.Add($chkAdv)
        $tlpFoot.Controls.Add($pnlFootLeft, 0, 1)

        $pnlBtns = New-Object System.Windows.Forms.FlowLayoutPanel
        $pnlBtns.FlowDirection = 'RightToLeft'
        $pnlBtns.WrapContents  = $false
        $pnlBtns.AutoSize      = $true
        $pnlBtns.Anchor        = 'Right'
        $btnClose0 = New-Object System.Windows.Forms.Button
        $btnClose0.Text = (T 'Close'); $btnClose0.Size = Sz 100 44
        $btnClose0.Add_Click({ $form.Close() })
        $btnStart = New-Object System.Windows.Forms.Button
        $btnStart.Name = 'primary'
        $btnStart.Text = (T 'Start maintenance')
        $btnStart.Size = Sz 230 44
        $btnStart.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 12)
        $pnlBtns.Controls.Add($btnStart)
        $pnlBtns.Controls.Add($btnClose0)
        $tlpFoot.Controls.Add($pnlBtns, 1, 1)
        $pnlSetup.Controls.Add($tlpFoot, 0, 4)

        $btnStart.Add_Click({
            $ids = @($script:StepCtl.Keys | Where-Object { $script:StepCtl[$_].Check.Checked -and $script:StepCtl[$_].Check.Enabled } | ForEach-Object { [int]$_ })
            if ($ids.Count -eq 0) {
                [void](Show-Message (T 'Please tick at least one step first.') (T 'Nothing selected') 'OK' 'Information')
                return
            }
            $skipCharger = $script:UI.chkAdv.Checked -and ($script:UI.cmbCharger.SelectedIndex -eq 1)
            if ((Get-PowerState) -eq 'Battery' -and -not $skipCharger) {
                $msg = (T 'Your laptop is running on battery.') + "`r`n`r`n" + (T 'Please connect the charger first. A power cut in the middle of system maintenance can damage Windows.')
                [void](Show-Message $msg (T 'Charger needed') 'OK' 'Warning')
                return
            }
            $note = ((T 'You are about to run {0} step(s).') -f $ids.Count) + "`r`n`r`n" + (T 'Before you continue:') + "`r`n" + (T ' - save your work') + "`r`n" + (T ' - keep the charger connected (laptops)')
            if (($ids -contains 3) -or ($ids -contains 4)) {
                $leave = $script:UI.chkAdv.Checked -and $script:StepCtl.ContainsKey(4) -and ($script:StepCtl[4].Combos[1].SelectedIndex -eq 1)
                if (-not $leave) { $note += "`r`n" + (T ' - the Recycle Bin will be emptied for good') }
            }
            if ($ids -contains 10) { $note += "`r`n" + (T ' - browser, Windows Update and Delivery Optimization caches will be cleared (you stay signed in)') }
            if (($ids -contains 9) -and $script:UI.chkAdv.Checked -and ($script:StepCtl[9].Combos[0].SelectedIndex -eq 1)) {
                $note += "`r`n" + (T ' - Windows updates will be downloaded and installed (no automatic restart)')
            }
            $answer = Show-Message $note (T 'Ready to start?') 'OKCancel' 'Information'
            if ($answer -ne 'OK') { return }
            $script:MaintWindow = $null
            if ($RunMode -eq 'Server') {
                $oo = Get-RunOptions
                $needs = @($oo.Steps | Where-Object { $Gated -contains $_ -and -not ($_ -eq 7 -and $oo.OptimizeAction -eq 'Analyze') })
                $wuInstall = (@($oo.Steps) -contains 9) -and ([string]$oo.WindowsUpdateMode -eq 'Install')
                if ($needs.Count -gt 0 -or $wuInstall) {
                    $list = @($needs | ForEach-Object { [string]$_ })
                    if ($wuInstall) { $list += '9 (install updates)' }
                    $msg = ((T 'These steps change this server: {0}.') -f ($list -join ', ')) + "`r`n`r`n" + (T 'Only continue in a planned maintenance window, with a recent backup.') + "`r`n`r`n" + (T 'Is this a maintenance window?')
                    if ((Show-Message $msg (T 'Maintenance window') 'YesNo' 'Warning') -ne 'Yes') { return }
                    $script:MaintWindow = $true
                }
            }
            Start-Run
        })

        # ---------- progress view
        $pnlRun = New-Object System.Windows.Forms.TableLayoutPanel
        $pnlRun.Dock        = 'Fill'
        $pnlRun.ColumnCount = 1
        $pnlRun.RowCount    = 9
        $pnlRun.Padding     = Pd 20 14 20 12
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
        $lblTitle.Margin = Pd 0 0 0 0
        $script:UI.lblTitle = $lblTitle
        $pnlRun.Controls.Add($lblTitle, 0, 0)

        $lblSummary = New-Object System.Windows.Forms.Label
        $lblSummary.Font = $script:FontNormal; $lblSummary.AutoSize = $true
        $lblSummary.ForeColor = $script:ColMuted
        Add-Wrap $lblSummary 'form' 0
        $lblSummary.Margin = Pd 0 2 0 8
        $script:UI.lblSummary = $lblSummary
        $pnlRun.Controls.Add($lblSummary, 0, 1)

        $lblNow = New-Object System.Windows.Forms.Label
        $lblNow.Font = $script:FontBold; $lblNow.AutoSize = $true
        $lblNow.ForeColor = $script:ColBlue
        Add-Wrap $lblNow 'form' 0
        $lblNow.Margin = Pd 0 0 0 6
        $script:UI.lblNow = $lblNow
        $pnlRun.Controls.Add($lblNow, 0, 2)

        $pbOverall = New-Object System.Windows.Forms.ProgressBar
        $pbOverall.Dock = 'Top'; $pbOverall.Height = S 22; $pbOverall.Style = 'Continuous'
        $pbOverall.Margin = Pd 0 0 0 4
        $script:UI.pbOverall = $pbOverall
        $pnlRun.Controls.Add($pbOverall, 0, 3)

        $pbActivity = New-Object System.Windows.Forms.ProgressBar
        $pbActivity.Dock = 'Top'; $pbActivity.Height = S 8
        $pbActivity.Style = 'Marquee'; $pbActivity.MarqueeAnimationSpeed = 30
        $pbActivity.Margin = Pd 0 0 0 10
        $script:UI.pbActivity = $pbActivity
        $pnlRun.Controls.Add($pbActivity, 0, 4)

        $lvSteps = New-Object System.Windows.Forms.ListView
        $lvSteps.Dock = 'Fill'; $lvSteps.View = 'Details'; $lvSteps.HeaderStyle = 'None'
        $lvSteps.BorderStyle = 'None'; $lvSteps.FullRowSelect = $false; $lvSteps.GridLines = $false
        $lvSteps.Font = $script:FontNormal
        [void]$lvSteps.Columns.Add('Step', (S 470))
        [void]$lvSteps.Columns.Add('Status', (S 160))
        [void]$lvSteps.Columns.Add('Time', (S 90))
        $script:UI.lvSteps = $lvSteps
        $lvSteps.Add_SizeChanged({ Update-Layout })
        $pnlRun.Controls.Add($lvSteps, 0, 5)

        $chkDetails = New-Object System.Windows.Forms.CheckBox
        $chkDetails.Text = (T 'Show technical details')
        $chkDetails.AutoSize = $true
        $chkDetails.Margin = Pd 0 8 0 4
        $script:UI.chkDetails = $chkDetails
        $pnlRun.Controls.Add($chkDetails, 0, 6)

        $txtLog = New-Object System.Windows.Forms.TextBox
        $txtLog.Multiline = $true; $txtLog.ReadOnly = $true; $txtLog.ScrollBars = 'Vertical'
        $txtLog.Dock = 'Fill'; $txtLog.Font = $script:FontMono
        $txtLog.BackColor = $script:ColInput
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
        $btnClose.Text = (T 'Close'); $btnClose.Size = Sz 90 36
        $btnClose.Add_Click({ $form.Close() })
        $btnBack = New-Object System.Windows.Forms.Button
        $btnBack.Text = (T 'Back to options'); $btnBack.Size = Sz 140 36
        $btnBack.Add_Click({
            $script:Run = $null
            $script:UI.pnlRun.Visible   = $false
            $script:UI.pnlSetup.Visible = $true
            Update-PowerLabel
        })
        $btnLogs = New-Object System.Windows.Forms.Button
        $btnLogs.Text = (T 'Open log folder'); $btnLogs.Size = Sz 140 36
        $btnLogs.Add_Click({ Start-Process explorer.exe -ArgumentList "`"$LogDir`"" })
        $btnReport = New-Object System.Windows.Forms.Button
        $btnReport.Text = (T 'Open report'); $btnReport.Size = Sz 130 36; $btnReport.Visible = $false
        $btnReport.Add_Click({ if ($script:LastReport) { Start-Process -FilePath $script:LastReport } })
        $btnStop = New-Object System.Windows.Forms.Button
        $btnStop.Text = (T 'Stop after this step'); $btnStop.Size = Sz 180 36
        $btnStop.Add_Click({
            $script:UI.btnStop.Enabled = $false
            $script:UI.btnStop.Text    = (T 'Stopping after this step...')
            try { Set-Content -LiteralPath $CancelFile -Value 'stop' -ErrorAction Stop } catch { }
        })
        foreach ($b in @($btnClose, $btnBack, $btnLogs, $btnReport, $btnStop)) { $pnlRunBtns.Controls.Add($b) }
        $script:UI.btnClose = $btnClose; $script:UI.btnBack = $btnBack
        $script:UI.btnLogs  = $btnLogs;  $script:UI.btnStop = $btnStop
        $script:UI.btnReport = $btnReport
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
                $script:Restart = $false
                [void](Show-Message ((T 'Maintenance is still running.') + "`r`n`r`n" + (T 'Please wait until it has finished, or press "Stop after this step".')) (T 'Please wait') 'OK' 'Information')
            } else {
                Save-Settings
            }
        })

        # The layout follows the window size; the Shown call covers the first display.
        $form.Add_Resize({ Update-Layout })
        $form.Add_Shown({
            # safety net: if the window ever opens collapsed, restore a sensible size
            if ($form.WindowState -eq 'Normal' -and ($form.Height -lt (S 400) -or $form.Width -lt (S 600))) {
                $form.Size = Sz 1000 780
            }
            Update-Layout
            $form.Activate()
        })

        Apply-Theme $form
        Restore-Settings
        Update-Layout

        [void]$form.ShowDialog()

        try { $script:Timer.Stop(); $script:Timer.Dispose(); $script:PowerTimer.Stop(); $script:PowerTimer.Dispose() } catch { }
    } while ($script:Restart)
}
catch {
    if ($script:ConsoleHwnd -ne [IntPtr]::Zero) { [void][Native.ConWin]::ShowWindow($script:ConsoleHwnd, 5) }
    [void][System.Windows.Forms.MessageBox]::Show("The window could not be opened:`r`n`r`n$($_.Exception.Message)", 'PC Maintenance', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
}
finally {
    Close-RunLog
    Remove-Item -LiteralPath $CancelFile -Force -ErrorAction SilentlyContinue
    if ($script:Notify) { try { $script:Notify.Visible = $false; $script:Notify.Dispose() } catch { } }
    if ($script:ConsoleHwnd -ne [IntPtr]::Zero) { [void][Native.ConWin]::ShowWindow($script:ConsoleHwnd, 5) }
}
