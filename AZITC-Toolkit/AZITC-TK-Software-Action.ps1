<#
.SYNOPSIS
    AZITC Toolkit - inspect, uninstall or repair a single ARP entry on the local client.

.DESCRIPTION
    Designed to run as a Configuration Manager "Run Script" (SYSTEM context, Windows PowerShell 5.1).
    Everything is non-interactive. Any installer that opens a dialog in session 0 will be
    killed when the timeout expires and reported as "TimedOut".

    Strategy cascade (Uninstall):
      1. Windows Installer  -> msiexec /x {ProductCode} /qn /norestart /l*v <log>
      2. QuietUninstallString present -> executed as-is
      3. Known engine detected from UninstallString:
           Inno Setup  (unins*.exe)          -> /VERYSILENT /SUPPRESSMSGBOXES /NORESTART
           NSIS        ("Nullsoft" in exe)   -> /S _?=<InstallLocation>
      4. ExtraArgs supplied by the operator -> <exe from UninstallString> <ExtraArgs>
      5. Otherwise: no action, Strategy = 'Unknown', operator must supply ExtraArgs.

    Strategy cascade (Repair):
      1. Windows Installer  -> msiexec /fomus {ProductCode} /qn /norestart /l*v <log>
      2. ExtraArgs supplied -> <exe from ModifyPath or UninstallString> <ExtraArgs>
      3. Otherwise: no action, Strategy = 'Unknown'.

    Per-user entries (HKEY_USERS) are reported but never executed from SYSTEM.

    Output: ONE JSON object (uncompressed, small). Script exit code:
      0 = action executed with a success-class exit code (0, 1605, 1614, 1641, 3010) or Inspect
      1 = action executed but failed / timed out / entry still present
      2 = nothing executed (unknown strategy, per-user, bad key, ...)

    Recommended script timeout in the console: 1800 seconds (the maximum).
    Keep TimeoutMin below that (default 15, hard cap 25).

.PARAMETER Action
    Inspect | Uninstall | Repair

.PARAMETER Key
    Registry key of the ARP entry as reported by AZITC-TK-Software-Get (field "K"), e.g.
    HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{GUID}

.PARAMETER ExtraArgs
    Additional/alternative arguments. Appended for MSI, used as the complete argument
    string for unknown engines.

.PARAMETER TimeoutMin
    Minutes to wait for the installer process before killing its process tree.

.PARAMETER KillRunning
    1 = terminate processes running from the InstallLocation before the action.

.PARAMETER ReEvaluate
    1 = trigger the Application Deployment Evaluation Cycle after a successful uninstall
        (forces re-installation by required deployments without waiting for the schedule).

.NOTES
    Author : Alexander Zarenko IT Consulting (AZITC)
    Schema : 1
#>

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Inspect', 'Uninstall', 'Repair')]
    [string]$Action,

    [Parameter(Mandatory = $true)]
    [string]$Key,

    [string]$ExtraArgs = '',

    [int]$TimeoutMin = 15,

    [int]$KillRunning = 0,

    [int]$ReEvaluate = 0
)

$ErrorActionPreference = 'Stop'
$SchemaVersion = 1
$LogDir = Join-Path -Path $env:ProgramData -ChildPath 'AZITC\Toolkit\Logs'
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$SuccessCodes = @(0, 1605, 1614, 1641, 3010)

$ExitMeaning = @{
    0    = 'Success'
    5    = 'Access denied'
    1601 = 'Windows Installer service not accessible'
    1602 = 'Cancelled (user/dialog)'
    1603 = 'Fatal error during installation'
    1605 = 'Product not installed (already removed)'
    1612 = 'Installation source not available'
    1614 = 'Product is uninstalled'
    1618 = 'Another installation is in progress'
    1619 = 'Installation package could not be opened'
    1638 = 'Another version of this product is already installed'
    1641 = 'Success - reboot initiated by installer'
    3010 = 'Success - reboot required'
}

# --- Result object ----------------------------------------------------------

$result = [ordered]@{
    Schema             = $SchemaVersion
    Kind               = 'SoftwareAction'
    Host               = $env:COMPUTERNAME
    TimeUtc            = (Get-Date).ToUniversalTime().ToString('s')
    Action             = $Action
    Key                = $Key
    Name               = ''
    Version            = ''
    Publisher          = ''
    Scope              = ''
    IsMsi              = $false
    ProductCode        = ''
    UninstallString    = ''
    QuietUninstall     = ''
    ModifyPath         = ''
    InstallLocation    = ''
    Engine             = ''
    Strategy           = ''
    Command            = ''
    Executed           = $false
    ExitCode           = $null
    ExitMeaning        = ''
    DurationSec        = 0
    TimedOut           = $false
    StillPresent       = $null
    RebootRequired     = $false
    RunningProcesses   = @()
    KilledProcesses    = @()
    ReEvaluateTriggered= $false
    LogFile            = ''
    LogTail            = @()
    Error              = ''
}

function Complete-Script {
    param([int]$Code)
    $result | ConvertTo-Json -Depth 4 -Compress | Write-Output
    exit $Code
}

# --- Helpers ----------------------------------------------------------------

function Split-CommandLine {
    # Returns @{ Exe = ...; Args = ... } for strings like:
    #   "C:\Program Files\Foo\unins000.exe" /SILENT
    #   C:\Program Files\Foo\unins000.exe /SILENT
    #   MsiExec.exe /X{GUID}
    param([string]$CommandLine)
    $cl = $CommandLine.Trim()
    if ($cl.StartsWith('"')) {
        $end = $cl.IndexOf('"', 1)
        if ($end -gt 0) {
            return @{ Exe = $cl.Substring(1, $end - 1); Args = $cl.Substring($end + 1).Trim() }
        }
    }
    $m = [regex]::Match($cl, '^(?<exe>.*?\.exe)\s*(?<args>.*)$', 'IgnoreCase')
    if ($m.Success) { return @{ Exe = $m.Groups['exe'].Value.Trim(); Args = $m.Groups['args'].Value.Trim() } }
    $parts = $cl -split '\s+', 2
    if ($parts.Count -eq 2) { return @{ Exe = $parts[0]; Args = $parts[1] } }
    return @{ Exe = $cl; Args = '' }
}

function Test-FileContains {
    param([string]$Path, [string]$Pattern)
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return $false }
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        $text = [System.Text.Encoding]::ASCII.GetString($bytes)
        return ($text -match $Pattern)
    } catch { return $false }
}

function Get-RunningFromLocation {
    param([string]$Location)
    if ([string]::IsNullOrWhiteSpace($Location)) { return @() }
    $loc = $Location.TrimEnd('\') + '\'
    $found = @()
    foreach ($p in (Get-Process -ErrorAction SilentlyContinue)) {
        $path = $null
        try { $path = $p.Path } catch { }
        if ($path -and $path.StartsWith($loc, [System.StringComparison]::OrdinalIgnoreCase)) {
            $found += [pscustomobject]@{ Id = $p.Id; Name = $p.ProcessName; Path = $path }
        }
    }
    return $found
}

function Invoke-WithTimeout {
    param([string]$FilePath, [string]$Arguments, [int]$Minutes)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $null = $proc.Handle   # cache handle so ExitCode is available
    $timedOut = -not $proc.WaitForExit($Minutes * 60 * 1000)
    if ($timedOut) {
        try { & taskkill.exe /PID $proc.Id /T /F | Out-Null } catch { }
        try { $proc.WaitForExit(15000) | Out-Null } catch { }
    }
    $sw.Stop()
    $code = $null
    try { $code = $proc.ExitCode } catch { }
    return @{ ExitCode = $code; TimedOut = $timedOut; Seconds = [int]$sw.Elapsed.TotalSeconds }
}

function Get-LogTail {
    param([string]$Path, [int]$Lines = 40)
    try {
        if (Test-Path -LiteralPath $Path) {
            # Plain strings: Get-Content decorates each line with PSPath/PSDrive note properties,
            # and ConvertTo-Json would serialise those too - 600 characters per line instead of 60.
            return @(Get-Content -LiteralPath $Path -Tail $Lines -ErrorAction Stop | ForEach-Object { [string]$_ })
        }
    } catch { }
    return @()
}

# --- Validate input ---------------------------------------------------------

if ($TimeoutMin -lt 1) { $TimeoutMin = 1 }
if ($TimeoutMin -gt 25) { $TimeoutMin = 25 }

if ($Key -notmatch '^HKEY_(LOCAL_MACHINE|USERS)\\.+\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\[^\\]+$') {
    $result.Error = 'Key is not an Add/Remove Programs uninstall key.'
    Complete-Script -Code 2
}

$regPath = "Registry::$Key"
if (-not (Test-Path -LiteralPath $regPath)) {
    $result.Error = 'Registry key not found (entry already removed?).'
    $result.StillPresent = $false
    Complete-Script -Code 2
}

$p = Get-ItemProperty -LiteralPath $regPath
$leaf = Split-Path -Path $Key -Leaf

$result.Name            = [string]$p.DisplayName
$result.Version         = [string]$p.DisplayVersion
$result.Publisher       = [string]$p.Publisher
$result.UninstallString = [string]$p.UninstallString
$result.QuietUninstall  = [string]$p.QuietUninstallString
$result.ModifyPath      = [string]$p.ModifyPath
$result.InstallLocation = [string]$p.InstallLocation
$result.Scope           = if ($Key -like 'HKEY_USERS\*') { 'User' } else { 'Machine' }

# --- Determine product code / engine ---------------------------------------

if ($leaf -match '^\{[0-9A-Fa-f\-]{36}\}$') {
    $result.ProductCode = $leaf
} elseif ($result.UninstallString -match '(?i)msiexec.*(/x|/i|/uninstall)\s*(\{[0-9A-Fa-f\-]{36}\})') {
    $result.ProductCode = $Matches[2]
}
$result.IsMsi = ($p.WindowsInstaller -eq 1 -or $result.ProductCode -ne '')

$exeInfo = @{ Exe = ''; Args = '' }
if ($result.UninstallString) { $exeInfo = Split-CommandLine -CommandLine $result.UninstallString }

if ($result.IsMsi) {
    $result.Engine = 'MSI'
} elseif ($exeInfo.Exe -match '(?i)\\unins\d*\.exe$') {
    $result.Engine = 'Inno'
} elseif ($exeInfo.Exe -and (Test-FileContains -Path $exeInfo.Exe -Pattern 'Nullsoft')) {
    $result.Engine = 'NSIS'
} elseif ($exeInfo.Exe -and (Test-FileContains -Path $exeInfo.Exe -Pattern 'InstallShield')) {
    $result.Engine = 'InstallShield'
} elseif ($exeInfo.Exe) {
    $result.Engine = 'Exe'
} else {
    $result.Engine = 'None'
}

$result.RunningProcesses = @(Get-RunningFromLocation -Location $result.InstallLocation | Select-Object Id, Name, Path)

# --- Build command ----------------------------------------------------------

$cmdExe  = ''
$cmdArgs = ''
$logFile = ''

if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force | Out-Null }
$safeName = ($result.Name -replace '[^\w\.\-]', '_')
if ($safeName.Length -gt 60) { $safeName = $safeName.Substring(0, 60) }

switch ($Action) {

    'Uninstall' {
        if ($result.IsMsi -and $result.ProductCode) {
            $logFile = Join-Path $LogDir "$Stamp-$safeName-uninstall.log"
            $result.Strategy = 'MSI'
            $cmdExe  = 'msiexec.exe'
            $cmdArgs = "/x $($result.ProductCode) /qn /norestart /l*v `"$logFile`""
            if ($ExtraArgs) { $cmdArgs += " $ExtraArgs" }
        }
        elseif ($result.QuietUninstall) {
            $result.Strategy = 'QuietUninstallString'
            $q = Split-CommandLine -CommandLine $result.QuietUninstall
            $cmdExe = $q.Exe; $cmdArgs = $q.Args
            if ($ExtraArgs) { $cmdArgs = ($cmdArgs + ' ' + $ExtraArgs).Trim() }
        }
        elseif ($ExtraArgs -and $exeInfo.Exe) {
            $result.Strategy = 'ExtraArgs'
            $cmdExe = $exeInfo.Exe; $cmdArgs = $ExtraArgs
        }
        elseif ($result.Engine -eq 'Inno') {
            $result.Strategy = 'Inno'
            $cmdExe = $exeInfo.Exe
            $cmdArgs = ($exeInfo.Args + ' /VERYSILENT /SUPPRESSMSGBOXES /NORESTART').Trim()
        }
        elseif ($result.Engine -eq 'NSIS') {
            # _?=<dir> keeps the uninstaller in place so WaitForExit actually waits. Must be last, unquoted.
            $result.Strategy = 'NSIS'
            $cmdExe = $exeInfo.Exe
            $dir = $result.InstallLocation
            if (-not $dir) { $dir = Split-Path -Path $exeInfo.Exe -Parent }
            $cmdArgs = ($exeInfo.Args + ' /S _?=' + $dir.TrimEnd('\')).Trim()
        }
        else {
            $result.Strategy = 'Unknown'
        }
    }

    'Repair' {
        if ($result.IsMsi -and $result.ProductCode) {
            $logFile = Join-Path $LogDir "$Stamp-$safeName-repair.log"
            $result.Strategy = 'MSI'
            $cmdExe  = 'msiexec.exe'
            $cmdArgs = "/fomus $($result.ProductCode) /qn /norestart /l*v `"$logFile`""
            if ($ExtraArgs) { $cmdArgs += " $ExtraArgs" }
        }
        elseif ($ExtraArgs) {
            $src = if ($result.ModifyPath) { $result.ModifyPath } else { $result.UninstallString }
            $m = Split-CommandLine -CommandLine $src
            if ($m.Exe) {
                $result.Strategy = 'ExtraArgs'
                $cmdExe = $m.Exe; $cmdArgs = $ExtraArgs
            } else {
                $result.Strategy = 'Unknown'
            }
        }
        else {
            $result.Strategy = 'Unknown'
        }
    }

    'Inspect' {
        # Report what Uninstall would do, without executing.
        if ($result.IsMsi -and $result.ProductCode) { $result.Strategy = 'MSI' }
        elseif ($result.QuietUninstall) { $result.Strategy = 'QuietUninstallString' }
        elseif ($result.Engine -in @('Inno', 'NSIS')) { $result.Strategy = $result.Engine }
        else { $result.Strategy = 'Unknown' }
        $result.LogFile = $LogDir
        Complete-Script -Code 0
    }
}

if ($cmdExe) { $result.Command = ('"' + $cmdExe + '" ' + $cmdArgs).Trim() }
$result.LogFile = $logFile

# --- Guards -----------------------------------------------------------------

if ($result.Scope -eq 'User') {
    $result.Error = 'Per-user installation - cannot be handled from SYSTEM context.'
    Complete-Script -Code 2
}
if ($result.Strategy -eq 'Unknown') {
    $result.Error = "No silent $($Action.ToLower()) method known for engine '$($result.Engine)'. Supply ExtraArgs."
    Complete-Script -Code 2
}
if ($cmdExe -ne 'msiexec.exe' -and -not (Test-Path -LiteralPath $cmdExe)) {
    $result.Error = "Executable not found: $cmdExe"
    Complete-Script -Code 2
}

if ($KillRunning -eq 1 -and $result.RunningProcesses.Count -gt 0) {
    foreach ($rp in $result.RunningProcesses) {
        try {
            Stop-Process -Id $rp.Id -Force -ErrorAction Stop
            $result.KilledProcesses += $rp.Name
        } catch { }
    }
    Start-Sleep -Seconds 2
}

# --- Execute ----------------------------------------------------------------

try {
    $run = Invoke-WithTimeout -FilePath $cmdExe -Arguments $cmdArgs -Minutes $TimeoutMin
    $result.Executed    = $true
    $result.ExitCode    = $run.ExitCode
    $result.TimedOut    = $run.TimedOut
    $result.DurationSec = $run.Seconds
} catch {
    $result.Error = "Failed to start process: $($_.Exception.Message)"
    Complete-Script -Code 1
}

if ($result.TimedOut) {
    $result.ExitMeaning = "Timed out after $TimeoutMin min - process tree killed (installer probably waited for a dialog)"
} elseif ($null -ne $result.ExitCode -and $ExitMeaning.ContainsKey([int]$result.ExitCode)) {
    $result.ExitMeaning = $ExitMeaning[[int]$result.ExitCode]
} else {
    $result.ExitMeaning = 'Unknown exit code'
}
$result.RebootRequired = ($result.ExitCode -eq 3010 -or $result.ExitCode -eq 1641)
$result.StillPresent   = (Test-Path -LiteralPath $regPath)
if ($logFile) { $result.LogTail = @(Get-LogTail -Path $logFile -Lines 40) }

# --- Post actions -----------------------------------------------------------

$success = (-not $result.TimedOut) -and ($null -ne $result.ExitCode) -and ($SuccessCodes -contains [int]$result.ExitCode)

if ($Action -eq 'Uninstall' -and $success -and $ReEvaluate -eq 1) {
    try {
        Invoke-CimMethod -Namespace 'root\ccm' -ClassName 'SMS_Client' -MethodName 'TriggerSchedule' `
            -Arguments @{ sScheduleID = '{00000000-0000-0000-0000-000000000121}' } -ErrorAction Stop | Out-Null
        $result.ReEvaluateTriggered = $true
    } catch {
        $result.Error = "Uninstall done, but ReEvaluate trigger failed: $($_.Exception.Message)"
    }
}

if ($Action -eq 'Uninstall' -and $success -and $result.StillPresent -and -not $result.RebootRequired) {
    $result.Error = 'Installer reported success but the ARP entry still exists.'
    Complete-Script -Code 1
}

if ($success) { Complete-Script -Code 0 } else { Complete-Script -Code 1 }
