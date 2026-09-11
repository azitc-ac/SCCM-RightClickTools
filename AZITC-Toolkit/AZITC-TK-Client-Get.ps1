<#
.SYNOPSIS
    AZITC Toolkit - client overview: services, processes, pending reboot, ConfigMgr cache, client facts.

.DESCRIPTION
    Designed to run as a Configuration Manager "Run Script" (SYSTEM context, Windows PowerShell 5.1).
    Read-only. One JSON envelope (payload gzip+base64, Kind = 'Client') with:

      Client     client version, site code, management point, last policy request, cache config,
                 uptime, last boot, OS, logged-on users
      Reboot     pending reboot and where it comes from (CBS, Windows Update, pending file
                 renames, computer rename, ConfigMgr's own CCM_ClientUtilities.DetermineIfRebootPending)
      Services   name, display name, state, start mode, account, process id - all services
      Processes  name, id, session, user, start time, CPU seconds, working set MB, path, command line
      Cache      CCM cache items: content id, version, size MB, reference count, last referenced,
                 location, persistent - plus the used/total size

    Recommended script timeout in the console: 300 seconds. No parameters.
    Lists are capped so the envelope stays under the Run Scripts output limit; the envelope
    says when that happened (Truncated with the section names).

.NOTES
    Author : Alexander Zarenko IT Consulting (AZITC)
    Schema : 1
#>

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
$MaxOutputChars = 70000

function ConvertTo-CompressedBase64 {
    param([Parameter(Mandatory = $true)][string]$Text)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $ms = New-Object System.IO.MemoryStream
    $gz = New-Object System.IO.Compression.GZipStream($ms, [System.IO.Compression.CompressionMode]::Compress)
    $gz.Write($bytes, 0, $bytes.Length)
    $gz.Close()
    $result = [Convert]::ToBase64String($ms.ToArray())
    $ms.Close()
    return $result
}

function ToIso {
    param($Value)
    if ($null -eq $Value) { return '' }
    try { $d = [datetime]$Value; if ($d.Year -lt 1980) { return '' }; return $d.ToUniversalTime().ToString('s') } catch { return [string]$Value }
}

$errors = New-Object System.Collections.Generic.List[string]

# --- Client facts -------------------------------------------------------------

$client = [ordered]@{}
try {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $client.OS = [string]$os.Caption
    $client.OSVersion = [string]$os.Version
    $client.LastBootUtc = ToIso $os.LastBootUpTime
    $client.UptimeHours = [math]::Round(((Get-Date) - [datetime]$os.LastBootUpTime).TotalHours, 1)
    $client.MemoryTotalMB = [int]($os.TotalVisibleMemorySize / 1024)
    $client.MemoryFreeMB = [int]($os.FreePhysicalMemory / 1024)
} catch { $errors.Add("OS: $($_.Exception.Message)") }
try {
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    $client.Domain = [string]$cs.Domain
    $client.Model = ('{0} {1}' -f $cs.Manufacturer, $cs.Model).Trim()
    $client.LoggedOnUser = [string]$cs.UserName
} catch { $errors.Add("ComputerSystem: $($_.Exception.Message)") }
try {
    $sms = Get-CimInstance -Namespace 'root\ccm' -ClassName 'SMS_Client' -ErrorAction Stop
    $client.ClientVersion = [string]$sms.ClientVersion
    $auth = Get-CimInstance -Namespace 'root\ccm' -ClassName 'SMS_Authority' -ErrorAction Stop | Select-Object -First 1
    $client.SiteCode = ([string]$auth.Name) -replace '^SMS:', ''
    $client.ManagementPoint = [string]$auth.CurrentManagementPoint
} catch { $errors.Add("SMS_Client: $($_.Exception.Message)") }
try {
    $lp = Get-CimInstance -Namespace 'root\ccm\Policy\Machine' -ClassName 'CCM_PolicyAgent_Configuration' -ErrorAction SilentlyContinue
    $client.PolicyRequestMinutes = if ($lp) { [int]$lp.PolicyRequestAssignmentsSchedule } else { 0 }
} catch { }
try {
    $cfg = Get-CimInstance -Namespace 'root\ccm\SoftMgmtAgent' -ClassName 'CacheConfig' -ErrorAction Stop
    $client.CacheLocation = [string]$cfg.Location
    $client.CacheSizeMB = [int]$cfg.Size
} catch { $errors.Add("CacheConfig: $($_.Exception.Message)") }
try {
    $client.LoggedOnSessions = @(query user 2>$null | Select-Object -Skip 1 | ForEach-Object { ($_ -replace '^\s*>?', '') -replace '\s{2,}', ' | ' })
} catch { $client.LoggedOnSessions = @() }

# --- Pending reboot -----------------------------------------------------------

$reboot = [ordered]@{ Pending = $false; Reasons = @() }
$reasons = New-Object System.Collections.Generic.List[string]
try { if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $reasons.Add('Component Based Servicing') } } catch { }
try { if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $reasons.Add('Windows Update') } } catch { }
try {
    $pfr = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
    if ($pfr -and $pfr.PendingFileRenameOperations) { $reasons.Add('Pending file rename operations (' + @($pfr.PendingFileRenameOperations | Where-Object { $_ }).Count + ')') }
} catch { }
try {
    $active = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName').ComputerName
    $pending = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName').ComputerName
    if ($active -and $pending -and $active -ne $pending) { $reasons.Add("Computer rename ($active -> $pending)") }
} catch { }
try {
    $ccm = Invoke-CimMethod -Namespace 'root\ccm\ClientSDK' -ClassName 'CCM_ClientUtilities' -MethodName 'DetermineIfRebootPending' -ErrorAction Stop
    $reboot.CcmRebootPending = [bool]$ccm.RebootPending
    $reboot.CcmIsHardRebootPending = [bool]$ccm.IsHardRebootPending
    $reboot.CcmRebootDeadlineUtc = ToIso $ccm.RebootDeadline
    if ($ccm.RebootPending -or $ccm.IsHardRebootPending) { $reasons.Add('ConfigMgr client (CCM_ClientUtilities)') }
} catch { $errors.Add("DetermineIfRebootPending: $($_.Exception.Message)") }
$reboot.Reasons = @($reasons.ToArray())
$reboot.Pending = ($reasons.Count -gt 0)

# --- Services -----------------------------------------------------------------

$services = New-Object System.Collections.Generic.List[object]
try {
    foreach ($s in (Get-CimInstance -ClassName Win32_Service -ErrorAction Stop | Sort-Object Name)) {
        $services.Add([pscustomobject]@{
            N  = [string]$s.Name
            D  = [string]$s.DisplayName
            S  = [string]$s.State
            M  = [string]$s.StartMode
            A  = [string]$s.StartName
            P  = [int]$s.ProcessId
        })
    }
} catch { $errors.Add("Services: $($_.Exception.Message)") }

# --- Processes ----------------------------------------------------------------

$processes = New-Object System.Collections.Generic.List[object]
try {
    $owners = @{}
    foreach ($p in (Get-CimInstance -ClassName Win32_Process -ErrorAction Stop)) {
        $user = ''
        try { $o = Invoke-CimMethod -InputObject $p -MethodName GetOwner -ErrorAction Stop; if ($o.User) { $user = ('{0}\{1}' -f $o.Domain, $o.User) } } catch { }
        $cpu = 0
        try { $cpu = [math]::Round(([double]$p.KernelModeTime + [double]$p.UserModeTime) / 10000000, 1) } catch { }
        $processes.Add([pscustomobject]@{
            N  = [string]$p.Name
            I  = [int]$p.ProcessId
            PP = [int]$p.ParentProcessId
            SE = [int]$p.SessionId
            U  = $user
            T  = (ToIso $p.CreationDate)
            C  = $cpu
            W  = [math]::Round([double]$p.WorkingSetSize / 1MB, 1)
            E  = [string]$p.ExecutablePath
            L  = [string]$p.CommandLine
        })
    }
} catch { $errors.Add("Processes: $($_.Exception.Message)") }
$processes = [System.Collections.Generic.List[object]]@($processes | Sort-Object -Property W -Descending)

# --- Cache --------------------------------------------------------------------

$cache = New-Object System.Collections.Generic.List[object]
$cacheUsedMB = 0
try {
    foreach ($c in (Get-CimInstance -Namespace 'root\ccm\SoftMgmtAgent' -ClassName 'CacheInfoEx' -ErrorAction Stop)) {
        $mb = [math]::Round([double]$c.ContentSize / 1024, 1)
        $cacheUsedMB += $mb
        $cache.Add([pscustomobject]@{
            ID  = [string]$c.ContentId
            V   = [string]$c.ContentVer
            MB  = $mb
            R   = [int]$c.ReferenceCount
            L   = (ToIso $c.LastReferenced)
            P   = [bool]$c.PersistInCache
            DIR = [string]$c.Location
            CID = [string]$c.CacheId
        })
    }
} catch { $errors.Add("CacheInfoEx: $($_.Exception.Message)") }
$client.CacheUsedMB = [math]::Round($cacheUsedMB, 1)
$cache = [System.Collections.Generic.List[object]]@($cache | Sort-Object -Property L -Descending)

# --- Envelope -----------------------------------------------------------------

function New-Envelope {
    param([object[]]$Svc, [object[]]$Proc, [object[]]$Cch, [string[]]$Truncated)
    $payload = [pscustomobject]@{
        Client    = [pscustomobject]$client
        Reboot    = [pscustomobject]$reboot
        Services  = [object[]]$Svc
        Processes = [object[]]$Proc
        Cache     = [object[]]$Cch
    }
    $json = $payload | ConvertTo-Json -Depth 5 -Compress
    $envelope = [pscustomobject]@{
        Schema    = $SchemaVersion
        Kind      = 'Client'
        Host      = $env:COMPUTERNAME
        TimeUtc   = (Get-Date).ToUniversalTime().ToString('s')
        Count     = @($Svc).Count + @($Proc).Count + @($Cch).Count
        Total     = $services.Count + $processes.Count + $cache.Count
        Truncated = ($Truncated.Count -gt 0)
        TruncatedSections = [string[]]$Truncated
        Error     = ($errors -join ' | ')
        Enc       = 'gzip+base64'
        Data      = (ConvertTo-CompressedBase64 -Text $json)
    }
    return ($envelope | ConvertTo-Json -Depth 3 -Compress)
}

$svc = $services.ToArray(); $proc = $processes.ToArray(); $cch = $cache.ToArray()
$trunc = New-Object System.Collections.Generic.List[string]
$out = New-Envelope -Svc $svc -Proc $proc -Cch $cch -Truncated @()
while ($out.Length -gt $MaxOutputChars) {
    # Processes are the biggest section (command lines); shorten them first, then services.
    if ($proc.Count -gt 20) { $proc = @($proc | Select-Object -First ([int][math]::Floor($proc.Count * 0.75))); if ($trunc -notcontains 'Processes') { $trunc.Add('Processes') } }
    elseif ($svc.Count -gt 20) { $svc = @($svc | Select-Object -First ([int][math]::Floor($svc.Count * 0.75))); if ($trunc -notcontains 'Services') { $trunc.Add('Services') } }
    elseif ($cch.Count -gt 10) { $cch = @($cch | Select-Object -First ([int][math]::Floor($cch.Count * 0.75))); if ($trunc -notcontains 'Cache') { $trunc.Add('Cache') } }
    else { break }
    $out = New-Envelope -Svc $svc -Proc $proc -Cch $cch -Truncated $trunc.ToArray()
}

Write-TKLog -Message ('Client-Get: {0} services, {1} processes, {2} cache items, reboot pending={3} [{4}], envelope {5} chars, truncated=[{6}], errors=''{7}''' -f $svc.Count, $proc.Count, $cch.Count, $reboot.Pending, ($reboot.Reasons -join '; '), $out.Length, ($trunc -join ','), ($errors -join ' | ')) -Component 'Client-Get'
Write-Output $out
exit 0
