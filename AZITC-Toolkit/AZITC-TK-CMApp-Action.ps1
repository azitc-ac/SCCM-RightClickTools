<#
.SYNOPSIS
    AZITC Toolkit - install, uninstall or repair a ConfigMgr application through the client SDK.

.DESCRIPTION
    Designed to run as a Configuration Manager "Run Script" (SYSTEM context, Windows PowerShell 5.1).
    Calls CCM_Application.Install / Uninstall / Repair in root\ccm\ClientSDK for the application
    the client already knows (it has to be deployed or available to the device), then watches
    EvaluationState / InstallState for up to TimeoutMin minutes and reports the course.
    Emits ONE JSON object.

    Exit code: 0 = the client reached the wanted state, 1 = enforcement failed or timed out,
    2 = nothing done (application unknown, method rejected, action not allowed).

    Recommended script timeout in the console: 1800 seconds. Keep TimeoutMin below that.

.PARAMETER Action
    Install | Uninstall | Repair
.PARAMETER AppId
    CCM_Application.Id, e.g. ScopeId_.../Application_...
.PARAMETER Revision
    CCM_Application.Revision. 0 = the revision the client currently holds.
.PARAMETER TimeoutMin
    Minutes to watch the enforcement (1..25, default 10). The method itself returns at once.
.PARAMETER IsRebootIfNeeded
    1 = let the client restart if the application demands it. Default 0.

.NOTES
    Author : Alexander Zarenko IT Consulting (AZITC)
    Schema : 1
#>

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Install', 'Uninstall', 'Repair')]
    [string]$Action,

    [Parameter(Mandatory = $true)]
    [string]$AppId,

    [int]$Revision = 0,

    [int]$TimeoutMin = 10,

    [int]$IsRebootIfNeeded = 0
)

$ErrorActionPreference = 'Stop'
$SchemaVersion = 1

# --- Toolkit log: CMTrace format, in a subfolder of the client's log folder ---------------
$TKLogDir = Join-Path -Path $env:windir -ChildPath 'CCM\Logs'
try { $tkCfg = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\CCM\Logging\@Global' -ErrorAction Stop; if ($tkCfg.LogDirectory) { $TKLogDir = [string]$tkCfg.LogDirectory } } catch { }
$TKLogDir = Join-Path -Path $TKLogDir -ChildPath 'AZITC-Toolkit'
function Write-TKLog {
    # Type: 1 info, 2 warning, 3 error - the colours CMTrace uses.
    param([string]$Message, [string]$Component = 'AZITC-TK', [int]$Type = 1)
    try {
        if (-not (Test-Path -LiteralPath $TKLogDir)) { New-Item -ItemType Directory -Path $TKLogDir -Force | Out-Null }
        $file = Join-Path -Path $TKLogDir -ChildPath 'AZITC-Toolkit.log'
        if ((Test-Path -LiteralPath $file) -and (Get-Item -LiteralPath $file).Length -gt 2MB) { Move-Item -LiteralPath $file -Destination ($file -replace '\.log$', '.lo_') -Force }
        $now = Get-Date
        $bias = -[int]([TimeZoneInfo]::Local.GetUtcOffset($now).TotalMinutes)
        $line = '<![LOG[{0}]LOG]!><time="{1}{2}" date="{3}" component="{4}" context="" type="{5}" thread="{6}" file="">' -f $Message, $now.ToString('HH:mm:ss.fff'), ('{0:+000;-000}' -f $bias), $now.ToString('MM-dd-yyyy'), $Component, $Type, $PID
        Add-Content -LiteralPath $file -Value $line -Encoding UTF8
    } catch { }
}

# CCM_Application.EvaluationState, worded as the window words it (AZITC-TK.ps1 holds the same
# table - this script runs on the client, where the window's file does not exist).
#
# 0-12 were read from the client SDK documentation. 14-28 are the published SDK list and have
# never been seen on a site; they are here so a result reads as something, and the watch loop
# below deliberately does not act on them.
#
# 13 is the one value this repo and that list disagree on - the list reads "enforced, soft
# reboot pending", a finished installation, while this table and the loop below call it a
# failure. The repo's own reading stands until a client reports a 13. See CHANGELOG.
$EvalText = @{
    0  = 'No state reported'
    1  = 'In the wanted state'
    2  = 'Not required on this device'
    3  = 'Ready to run, not started'
    4  = 'Last attempt failed'
    5  = 'Waiting for content to download'
    6  = 'Waiting for content to download'
    7  = 'Waiting for dependencies to download'
    8  = 'Waiting for a maintenance window'
    9  = 'Waiting for a pending reboot'
    10 = 'Waiting its turn'
    11 = 'Installing dependencies'
    12 = 'Installing'
    13 = 'Ran and failed'
    # --- from here down: the published list, not seen on a site ---
    14 = 'Ran, reboot required'
    15 = 'An update is waiting to be installed'
    16 = 'Evaluation failed'
    17 = 'Waiting for a user to be logged on'
    18 = 'Waiting for all users to log off'
    19 = 'Waiting for a user to log on'
    20 = 'Waiting to try again'
    21 = 'Waiting for presentation mode to end'
    22 = 'Downloading content in advance'
    23 = 'Downloading dependencies in advance'
    24 = 'Content download failed'
    25 = 'Downloading in advance failed'
    26 = 'Content downloaded'
    27 = 'Checking after the run'
    28 = 'Waiting for a network connection'
}

$result = [ordered]@{
    Schema        = $SchemaVersion
    Kind          = 'CMAppAction'
    Host          = $env:COMPUTERNAME
    TimeUtc       = (Get-Date).ToUniversalTime().ToString('s')
    Action        = $Action
    AppId         = $AppId
    Revision      = $Revision
    Name          = ''
    Version       = ''
    AllowedActions= @()
    Before        = $null
    MethodReturn  = $null
    JobId         = ''
    Course        = @()
    After         = $null
    Reached       = $false
    TimedOut      = $false
    DurationSec   = 0
    Error         = ''
    ScriptExit    = 0
}

function Complete-Script {
    param([int]$Code)
    # The Run Scripts host reports 0 whatever "exit" says (verified on the lab client), so the
    # intended code travels inside the JSON as ScriptExit; only a thrown error makes the state fail.
    $result.ScriptExit = $Code
    $lvl = 1; if ($Code -eq 1) { $lvl = 3 } elseif ($Code -eq 2) { $lvl = 2 }
    $afterText = ''; if ($result.After) { $afterText = '{0}/{1}' -f $result.After.InstallState, $result.After.EvaluationState }
    Write-TKLog -Message ('CMApp-Action {0} ''{1} {2}'' rev {3}: method={4} job={5} reached={6} timedOut={7} after={8} {9}s error=''{10}'' -> script exit {11}' -f $Action, $result.Name, $result.Version, $result.Revision, $result.MethodReturn, $result.JobId, $result.Reached, $result.TimedOut, $afterText, $result.DurationSec, $result.Error, $Code) -Component 'CMApp-Action' -Type $lvl
    $result | ConvertTo-Json -Depth 4 -Compress | Write-Output
    exit $Code
}

function Get-App {
    param([string]$Id, [int]$Rev)
    # The ClientSDK provider refuses WQL filters ("Provider is not capable of the attempted
    # operation"), so every instance is read and the match is made here. The second
    # Get-CimInstance fills the lazy properties of the chosen instance.
    $all = @(Get-CimInstance -Namespace 'root\ccm\ClientSDK' -ClassName 'CCM_Application' -ErrorAction Stop)
    $apps = @($all | Where-Object { [string]$_.Id -eq $Id -and ($Rev -le 0 -or [int]$_.Revision -eq $Rev) } | Get-CimInstance -ErrorAction Stop)
    if ($apps.Count -eq 0) { return $null }
    # Highest revision when none was given.
    return ($apps | Sort-Object { [int]$_.Revision } -Descending | Select-Object -First 1)
}

function Get-State {
    param($App)
    $es = [int]$App.EvaluationState
    $text = 'Unknown'
    if ($EvalText.ContainsKey($es)) { $text = $EvalText[$es] }
    return [pscustomobject]@{
        TimeUtc         = (Get-Date).ToUniversalTime().ToString('HH:mm:ss')
        InstallState    = [string]$App.InstallState
        ResolvedState   = [string]$App.ResolvedState
        EvaluationState = $es
        EvaluationText  = $text
        ErrorCode       = [int]$App.ErrorCode
        PercentComplete = [int]$App.PercentComplete
    }
}

# --- Look up ------------------------------------------------------------------

$app = $null
try { $app = Get-App -Id $AppId -Rev $Revision } catch { $result.Error = "CCM_Application query failed: $($_.Exception.Message)"; Complete-Script -Code 2 }
if ($null -eq $app) { $result.Error = 'Application not known to this client (not deployed / not available to the device).'; Complete-Script -Code 2 }

$result.Name = [string]$app.Name
$result.Version = [string]$app.SoftwareVersion
$result.Revision = [int]$app.Revision
$result.AllowedActions = @($app.AllowedActions)
$result.Before = Get-State -App $app
Write-TKLog -Message ('CMApp-Action {0} requested for ''{1} {2}'' rev {3} ({4}), before {5}/{6}, allowed [{7}]' -f $Action, $result.Name, $result.Version, $result.Revision, $AppId, $result.Before.InstallState, $result.Before.EvaluationState, ($result.AllowedActions -join ',')) -Component 'CMApp-Action'

if ($result.AllowedActions -notcontains $Action) {
    $result.Error = "Action '$Action' is not in AllowedActions ($($result.AllowedActions -join ', ')) for this application on this client."
    Complete-Script -Code 2
}

if ($TimeoutMin -lt 1) { $TimeoutMin = 1 }
if ($TimeoutMin -gt 25) { $TimeoutMin = 25 }

# --- Call ---------------------------------------------------------------------

$sw = [System.Diagnostics.Stopwatch]::StartNew()
try {
    $callArgs = @{
        Id               = [string]$app.Id
        Revision         = [string]$app.Revision
        IsMachineTarget  = [bool]$app.IsMachineTarget
        EnforcePreference= [uint32]0
        Priority         = 'High'
        IsRebootIfNeeded = ($IsRebootIfNeeded -eq 1)
    }
    $r = Invoke-CimMethod -Namespace 'root\ccm\ClientSDK' -ClassName 'CCM_Application' -MethodName $Action -Arguments $callArgs -ErrorAction Stop
    $result.MethodReturn = [int]$r.ReturnValue
    if ($r.PSObject.Properties['JobId']) { $result.JobId = [string]$r.JobId }
} catch {
    $result.Error = "CCM_Application.$Action failed: $($_.Exception.Message)"
    Complete-Script -Code 2
}
if ($result.MethodReturn -ne 0) {
    $result.Error = "CCM_Application.$Action returned $($result.MethodReturn)."
    Complete-Script -Code 2
}

# --- Watch --------------------------------------------------------------------

$wantInstalled = ($Action -ne 'Uninstall')
$deadline = (Get-Date).AddMinutes($TimeoutMin)
$last = ''
$course = New-Object System.Collections.Generic.List[object]
$reached = $false
$failed = $false
$sawEnforcing = $false
do {
    Start-Sleep -Seconds 5
    $cur = $null
    try { $cur = Get-App -Id $AppId -Rev $result.Revision } catch { }
    if ($null -eq $cur) { continue }
    $st = Get-State -App $cur
    $sig = "$($st.InstallState)|$($st.EvaluationState)|$($st.PercentComplete)"
    if ($sig -ne $last) { $course.Add($st); $last = $sig }
    if ($st.EvaluationState -in @(11, 12)) { $sawEnforcing = $true }
    # Only the two values this site has watched a client report end the wait. 16, 24 and 25 are
    # failures in the published list too, but acting on an unconfirmed number would cut the
    # watch of a run that is still going; the window colours them red, which costs nothing.
    if ($st.EvaluationState -in @(4, 13)) { $failed = $true; break }
    $isInstalled = ($st.InstallState -in 'Installed', 'NotUpdated')
    # Done when the state flipped to what was asked for and the client is no longer enforcing.
    if ($isInstalled -eq $wantInstalled -and $st.EvaluationState -notin @(5, 6, 7, 10, 11, 12) -and ($sawEnforcing -or $Action -eq 'Repair' -or $st.EvaluationState -in @(1, 2, 3))) {
        # For Repair the install state does not change; accept once enforcement has run.
        if ($Action -ne 'Repair' -or $sawEnforcing) { $reached = $true; break }
    }
} while ((Get-Date) -lt $deadline)

$sw.Stop()
$result.DurationSec = [int]$sw.Elapsed.TotalSeconds
$result.Course = @($course.ToArray())
$final = $null
try { $final = Get-App -Id $AppId -Rev $result.Revision } catch { }
if ($final) { $result.After = Get-State -App $final }
$result.Reached = $reached
$result.TimedOut = (-not $reached -and -not $failed)

if ($failed) {
    $reason = $EvalText[[int]$result.After.EvaluationState]; if (-not $reason) { $reason = "state $($result.After.EvaluationState)" }
    $result.Error = "The client could not carry the action out: $reason (EvaluationState $($result.After.EvaluationState), ErrorCode $($result.After.ErrorCode))."
    Complete-Script -Code 1
}
if ($result.TimedOut) { $result.Error = "Not finished after $TimeoutMin min - the client is still working on it (see After)."; Complete-Script -Code 1 }
Complete-Script -Code 0
