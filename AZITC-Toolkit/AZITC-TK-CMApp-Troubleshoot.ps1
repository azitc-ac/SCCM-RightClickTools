<#
.SYNOPSIS
    AZITC Toolkit - why is this ConfigMgr application not where the deployment wants it?

.DESCRIPTION
    Designed to run as a Configuration Manager "Run Script" (SYSTEM context, Windows PowerShell 5.1).
    Read-only apart from running the deployment type's own detection script, which is what the
    client does on every evaluation anyway. One JSON envelope (payload gzip+base64,
    Kind = 'Troubleshoot').

    Everything comes from the client itself - no site access needed:

      CCM_Application (root\ccm\ClientSDK)        state, deadline, last evaluation, last install
      CCM_ApplicationCIAssignment (ActualConfig)  the deployment(s) that target the app, revision in policy
      root\ccm\CIModels synclets                  per deployment type and revision: the detection
                                                  method (File/Folder/Registry/MSI clauses or the
                                                  detection script), the install command and its exit
                                                  codes, the last enforcement result
      AppDiscovery.log, AppEnforce.log,           the timeline: every detection result, every
      AppIntentEval.log                           enforcement attempt with exit code and post-install
                                                  detection, every intent evaluation
      CCM_Scheduler_History                       when the application deployment evaluation cycle
                                                  last ran (that is what triggers a retry)
      Add/Remove Programs                         what is really registered on the device

    The detection clauses are evaluated here, one by one, against the device: the rule, the
    value found, the outcome. That is the answer to "detection says installed, but it is not"
    and to "the installer reports success, then detection finds nothing" (0x87D00324).

    Parameters
      AppId     CCM_Application.Id (ScopeId_.../Application_...). Required.
      Days      how far back the logs are read. Default 14.
      MaxLines  evidence lines per log and per deployment type. Default 25.

    Recommended script timeout in the console: 300 seconds.

.NOTES
    Author : Alexander Zarenko IT Consulting (AZITC)
    Schema : 1
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$AppId,
    [int]$Days = 14,
    [int]$MaxLines = 25
)

$ErrorActionPreference = 'Stop'
$SchemaVersion = 1

# --- Toolkit log: CMTrace format, in a subfolder of the client's log folder ---------------
$CcmLogDir = Join-Path -Path $env:windir -ChildPath 'CCM\Logs'
try { $tkCfg = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\CCM\Logging\@Global' -ErrorAction Stop; if ($tkCfg.LogDirectory) { $CcmLogDir = [string]$tkCfg.LogDirectory } } catch { }
$TKLogDir = Join-Path -Path $CcmLogDir -ChildPath 'AZITC-Toolkit'
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
    # A CIM datetime that carries its real offset (policy: "...+***" with UseGMTTimes): UTC ISO.
    param($Value)
    if ($null -eq $Value) { return '' }
    try { $d = [datetime]$Value; if ($d.Year -lt 1980) { return '' }; return $d.ToUniversalTime().ToString('s') } catch { return [string]$Value }
}
function ToIsoLocalDigits {
    # The ClientSDK (CCM_Application times) and CCM_Scheduler_History store the LOCAL clock with
    # a "+000" offset: raw "20260914192223.000000+000" while AppDiscovery.log shows 19:22:21 local,
    # and a 13:27 local deadline that the site holds as 11:27 UTC. CIM therefore hands over a
    # DateTime shifted by the zone offset. Undo that: back to the digits, read them as local.
    param($Value)
    if ($null -eq $Value) { return '' }
    try {
        $d = [datetime]$Value; if ($d.Year -lt 1980) { return '' }
        if ($d.Kind -eq 'Local') { $d = $d.ToUniversalTime() }
        return [datetime]::SpecifyKind($d, 'Local').ToUniversalTime().ToString('s')
    } catch { return [string]$Value }
}
function ToIsoAssignment {
    # CCM_ApplicationCIAssignment times come as "...+***": the digits are UTC when the
    # deployment was made with UTC times (UseGMTTimes), the local clock otherwise (a deployment
    # with "client local time": raw 20260915180100+*** for 18:01 local). CIM reads "+***" as UTC.
    param($Assignment, $Value)
    if ([bool]$Assignment.UseGMTTimes) { return (ToIso $Value) }
    return (ToIsoLocalDigits $Value)
}

$errors = New-Object System.Collections.Generic.List[string]
$since = (Get-Date).AddDays(-[math]::Abs($Days))
$appGuid = ''
if ($AppId -match '/(?:Required)?Application_([0-9a-fA-F-]{36})') { $appGuid = $Matches[1].ToLower() }

# --- 1. The application as the client sees it ----------------------------------------------

$app = $null
$appInfo = [ordered]@{ Id = $AppId; Found = $false }
try {
    $app = Get-CimInstance -Namespace 'root\ccm\ClientSDK' -ClassName 'CCM_Application' -ErrorAction Stop | Where-Object { $_.Id -eq $AppId } | Select-Object -First 1
    if ($app) { $app = $app | Get-CimInstance -ErrorAction Stop }   # lazy properties (AppDTs, times)
} catch { $errors.Add("CCM_Application: $($_.Exception.Message)") }
if ($app) {
    $appInfo.Found = $true
    $appInfo.Name = [string]$app.Name
    $appInfo.FullName = [string]$app.FullName
    $appInfo.Version = [string]$app.SoftwareVersion
    $appInfo.Publisher = [string]$app.Publisher
    $appInfo.Revision = [int]$app.Revision
    $appInfo.InstallState = [string]$app.InstallState
    $appInfo.ResolvedState = [string]$app.ResolvedState
    $appInfo.EvaluationState = [int]$app.EvaluationState
    $appInfo.ErrorCode = [uint32]$app.ErrorCode
    $appInfo.ErrorHex = ('0x{0:X8}' -f [uint32]$app.ErrorCode)
    $appInfo.ApplicabilityState = [string]$app.ApplicabilityState
    $appInfo.SupersessionState = [string]$app.SupersessionState
    $appInfo.ConfigureState = [string]$app.ConfigureState
    $appInfo.IsMachineTarget = [bool]$app.IsMachineTarget
    $appInfo.EnforcePreference = [int]$app.EnforcePreference
    $appInfo.LastEvalUtc = ToIsoLocalDigits $app.LastEvalTime
    $appInfo.LastInstallUtc = ToIsoLocalDigits $app.LastInstallTime
    $appInfo.StartTimeUtc = ToIsoLocalDigits $app.StartTime
    $appInfo.DeadlineUtc = ToIsoLocalDigits $app.Deadline
    $appInfo.AllowedActions = @($app.AllowedActions | ForEach-Object { [string]$_ })
}

# --- 2. The deployment(s) in the client's policy -------------------------------------------

$assignments = New-Object System.Collections.Generic.List[object]
try {
    Get-CimInstance -Namespace 'root\ccm\Policy\Machine\ActualConfig' -ClassName 'CCM_ApplicationCIAssignment' -ErrorAction Stop | ForEach-Object {
        $cis = [string]$_.AssignedCIs
        if ($appGuid -and $cis.ToLower().Contains($appGuid)) {
            $ciVersion = ''
            if ($cis -match '<CIVersion>(\d+)</CIVersion>') { $ciVersion = $Matches[1] }
            $assignments.Add([pscustomobject]@{
                Name                   = [string]$_.AssignmentName
                AssignmentId           = [string]$_.AssignmentID
                Purpose                = $(if ([string]$_.EnforcementDeadline) { 'Required' } else { 'Available' })
                DesiredConfigType      = [int]$_.DesiredConfigType          # 1 install, 2 uninstall
                StartUtc               = ToIsoAssignment $_ $_.StartTime
                DeadlineUtc            = ToIsoAssignment $_ $_.EnforcementDeadline
                PolicyRevision         = $ciVersion
                OverrideServiceWindows = [bool]$_.OverrideServiceWindows
                RebootOutsideWindows   = [bool]$_.RebootOutsideOfServiceWindows
                UserUIExperience       = [bool]$_.UserUIExperience
                NotifyUser             = [bool]$_.NotifyUser
                SoftDeadline           = [bool]$_.SoftDeadlineEnabled
            })
        }
    }
} catch { $errors.Add("CCM_ApplicationCIAssignment: $($_.Exception.Message)") }
try {
    # User policy lives under each user's SID; the machine can at least say whether any exists.
    $userNs = Get-CimInstance -Namespace 'root\ccm\Policy' -ClassName '__NAMESPACE' -ErrorAction Stop | Where-Object { $_.Name -like 'S_1_5_21*' }
    foreach ($ns in @($userNs)) {
        try {
            Get-CimInstance -Namespace ('root\ccm\Policy\' + $ns.Name + '\ActualConfig') -ClassName 'CCM_ApplicationCIAssignment' -ErrorAction Stop | ForEach-Object {
                if ($appGuid -and ([string]$_.AssignedCIs).ToLower().Contains($appGuid)) {
                    $assignments.Add([pscustomobject]@{ Name = [string]$_.AssignmentName; AssignmentId = [string]$_.AssignmentID; Purpose = $(if ([string]$_.EnforcementDeadline) { 'Required (user)' } else { 'Available (user)' }); DesiredConfigType = [int]$_.DesiredConfigType; StartUtc = ToIsoAssignment $_ $_.StartTime; DeadlineUtc = ToIsoAssignment $_ $_.EnforcementDeadline; PolicyRevision = ''; OverrideServiceWindows = [bool]$_.OverrideServiceWindows; RebootOutsideWindows = $false; UserUIExperience = $true; NotifyUser = $true; SoftDeadline = $false })
                }
            }
        } catch { }
    }
} catch { }

# --- 3. Log readers (CMTrace format) --------------------------------------------------------

function Read-CmLog {
    # Entries of a client log (and its rolled predecessor) newer than $since: Time, Text.
    param([string]$Name)
    $entries = New-Object System.Collections.Generic.List[object]
    $files = @()
    $base = Join-Path $CcmLogDir $Name
    $rolled = Get-ChildItem -Path $CcmLogDir -Filter ($Name -replace '\.log$', '-*.log') -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($rolled -and $rolled.LastWriteTime -gt $since) { $files += $rolled.FullName }
    if (Test-Path -LiteralPath $base) { $files += $base }
    $rx = New-Object System.Text.RegularExpressions.Regex('<!\[LOG\[(?<msg>.*?)\]LOG\]!><time="(?<time>[^"]+)"\s+date="(?<date>[^"]+)"', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    foreach ($f in $files) {
        try { $fs = New-Object System.IO.FileStream($f, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite); $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8, $true); $text = $sr.ReadToEnd(); $sr.Close(); $fs.Close() } catch { $errors.Add("read $f`: $($_.Exception.Message)"); continue }
        foreach ($m in $rx.Matches($text)) {
            $t = $null
            try { $t = [datetime]::ParseExact(($m.Groups['date'].Value + ' ' + $m.Groups['time'].Value.Substring(0, 12)), 'MM-dd-yyyy HH:mm:ss.fff', [cultureinfo]::InvariantCulture) } catch { continue }
            if ($t -lt $since) { continue }
            $entries.Add([pscustomobject]@{ Time = $t; Text = ($m.Groups['msg'].Value -replace '\s+', ' ').Trim() })
        }
    }
    return ,$entries
}
function Tail-Entries {
    # The last $Max entries as "yyyy-MM-ddTHH:mm:ss  text", UTC like every other time in the
    # envelope, the ScopeId prefix dropped from the ids.
    param($Entries, [int]$Max)
    $arr = @($Entries)
    if ($arr.Count -gt $Max) { $arr = @($arr | Select-Object -Last $Max) }
    return @($arr | ForEach-Object { $x = ($_.Text -replace 'ScopeId_[0-9A-Fa-f-]+/', ''); if ($x.Length -gt 400) { $x = $x.Substring(0, 400) + '...' }; '{0}  {1}' -f $_.Time.ToUniversalTime().ToString('s'), $x })
}

$logDiscovery = Read-CmLog 'AppDiscovery.log'
$logEnforce   = Read-CmLog 'AppEnforce.log'
$logIntent    = Read-CmLog 'AppIntentEval.log'
$logDcm       = Read-CmLog 'DCMReporting.log'   # requirement rules: "In policy:<DT>_<rev>_Requirements_PolicyDocument, rule:Rule_x status is:NotConformant"

# --- 4. Detection clauses: parse and evaluate on this device --------------------------------

function Get-RegistryBaseKey {
    param([string]$Hive, [bool]$Is64Bit)
    $h = switch -Regex ($Hive) {
        'HKEY_LOCAL_MACHINE|^HKLM' { [Microsoft.Win32.RegistryHive]::LocalMachine }
        'HKEY_CURRENT_USER|^HKCU'  { [Microsoft.Win32.RegistryHive]::CurrentUser }
        'HKEY_USERS|^HKU'          { [Microsoft.Win32.RegistryHive]::Users }
        'HKEY_CLASSES_ROOT|^HKCR'  { [Microsoft.Win32.RegistryHive]::ClassesRoot }
        'HKEY_CURRENT_CONFIG'      { [Microsoft.Win32.RegistryHive]::CurrentConfig }
        default                    { [Microsoft.Win32.RegistryHive]::LocalMachine }
    }
    $view = if ($Is64Bit) { [Microsoft.Win32.RegistryView]::Registry64 } else { [Microsoft.Win32.RegistryView]::Registry32 }
    return [Microsoft.Win32.RegistryKey]::OpenBaseKey($h, $view)
}
function Test-OtherRegistryView {
    # The most common registry-detection mistake: the clause names one registry view, the
    # installer wrote the other. Says so when the key (and value) exists over there.
    param([string]$Hive, [string]$Key, [string]$ValueName, [bool]$Is64Bit)
    try {
        $other = Get-RegistryBaseKey -Hive $Hive -Is64Bit (-not $Is64Bit)
        $k = $other.OpenSubKey($Key)
        if (-not $k) { return '' }
        $view = $(if ($Is64Bit) { '32-bit' } else { '64-bit' })
        if ($ValueName) {
            $v = $k.GetValue($ValueName, $null); $k.Close()
            if ($null -ne $v) { return ' - but present in the ' + $view + ' view with value ''' + [string]$v + '''' }
            return ' - the key exists in the ' + $view + ' view, without that value'
        }
        $k.Close()
        return ' - but present in the ' + $view + ' view'
    } catch { return '' }
}
function Expand-CmPath {
    # %ProgramFiles% in a 32-bit clause means the x86 folder; the client does the same.
    param([string]$Path, [bool]$Is64Bit)
    $p = $Path
    if (-not $Is64Bit) {
        $pf86 = ${env:ProgramFiles(x86)}; if (-not $pf86) { $pf86 = $env:ProgramFiles }
        $p = $p -ireplace '%ProgramFiles%', $pf86.Replace('$', '$$')
        $cpf86 = ${env:CommonProgramFiles(x86)}; if ($cpf86) { $p = $p -ireplace '%CommonProgramFiles%', $cpf86.Replace('$', '$$') }
        $p = $p -ireplace '%windir%\\System32', ($env:windir + '\SysWOW64')
    }
    return [Environment]::ExpandEnvironmentVariables($p)
}
function Get-MsiProductInfo {
    param([string]$ProductCode)
    $info = [ordered]@{ State = 'Unknown'; Version = ''; Name = '' }
    try {
        $wi = New-Object -ComObject WindowsInstaller.Installer
        $state = [int]$wi.ProductState($ProductCode)
        $info.State = switch ($state) { 5 { 'Installed' } 1 { 'Advertised' } 2 { 'Absent (registered for another user)' } -1 { 'Unknown product' } default { "State $state" } }
        if ($state -eq 5) {
            try { $info.Version = [string]$wi.ProductInfo($ProductCode, 'VersionString') } catch { }
            try { $info.Name = [string]$wi.ProductInfo($ProductCode, 'ProductName') } catch { }
        }
    } catch { $info.State = "error: $($_.Exception.Message)" }
    return $info
}
function Compare-CmValue {
    # The operators of the AppMgmtDigest rule language, on the DataType the rule names.
    param([string]$Operator, $Actual, [string]$Expected, [string]$DataType)
    if ($null -eq $Actual) { return $false }
    $a = $Actual; $e = $Expected
    switch ($DataType) {
        'Version' {
            # "26.02" and "26.02.0.0" must compare equal: pad both to four parts.
            $norm = { param($s) $s = [string]$s; if ($s -notmatch '^\d+(\.\d+){0,3}$') { return $null }; $parts = @($s.Split('.') | ForEach-Object { [int]$_ }); while ($parts.Count -lt 4) { $parts += 0 }; return New-Object System.Version($parts[0], $parts[1], $parts[2], $parts[3]) }
            $a = & $norm $Actual; $e = & $norm $Expected
            if ($null -eq $a -or $null -eq $e) { return $null }
        }
        'Int64' { try { $a = [int64]$Actual; $e = [int64]$Expected } catch { return $null } }
        'DateTime' { try { $a = [datetime]$Actual; $e = [datetime]$Expected } catch { return $null } }
        default { $a = [string]$Actual; $e = [string]$Expected }
    }
    switch ($Operator) {
        'Equals'        { if ($DataType -eq 'String') { return ($a -ieq $e) }; return ($a -eq $e) }
        'NotEquals'     { if ($DataType -eq 'String') { return ($a -ine $e) }; return ($a -ne $e) }
        'GreaterThan'   { return ($a -gt $e) }
        'GreaterEquals' { return ($a -ge $e) }
        'LessThan'      { return ($a -lt $e) }
        'LessEquals'    { return ($a -le $e) }
        'Contains'      { return ([string]$a -ilike "*$e*") }
        'NotContains'   { return -not ([string]$a -ilike "*$e*") }
        'BeginsWith'    { return ([string]$a -ilike "$e*") }
        'NotBeginsWith' { return -not ([string]$a -ilike "$e*") }
        'EndsWith'      { return ([string]$a -ilike "*$e") }
        'NotEndsWith'   { return -not ([string]$a -ilike "*$e") }
        'Between'       { return $null }
        default         { return $null }
    }
}
function Read-CmSetting {
    # One <Settings> child: what it looks for and what the device holds. Returns a hashtable
    # with Kind, Target, Exists, Values (property -> value) and Note.
    param([System.Xml.XmlElement]$Node)
    $s = [ordered]@{ Kind = $Node.LocalName; LogicalName = [string]$Node.GetAttribute('LogicalName'); Target = ''; Exists = $false; Values = @{}; Note = '' }
    try {
        switch ($Node.LocalName) {
            'File' {
                $is64 = ([string]$Node.GetAttribute('Is64Bit') -eq 'true')
                $dir = Expand-CmPath -Path ([string]$Node.Path) -Is64Bit $is64
                $s.Target = '{0}\{1} ({2})' -f $dir.TrimEnd('\'), [string]$Node.Filter, $(if ($is64) { '64-bit view' } else { '32-bit view' })
                $files = @(Get-ChildItem -Path $dir -Filter ([string]$Node.Filter) -File -ErrorAction SilentlyContinue)
                $s.Values['Count'] = $files.Count
                if ($files.Count -eq 0) {
                    # the other view's folder (Program Files vs Program Files (x86))
                    $dir2 = Expand-CmPath -Path ([string]$Node.Path) -Is64Bit (-not $is64)
                    if ($dir2 -ne $dir) { $f2 = @(Get-ChildItem -Path $dir2 -Filter ([string]$Node.Filter) -File -ErrorAction SilentlyContinue); if ($f2.Count -gt 0) { $s.Note = 'not here, but ' + $f2[0].FullName + ' exists (' + $(if ($is64) { '32-bit' } else { '64-bit' }) + ' view), version ' + $f2[0].VersionInfo.FileVersion } }
                }
                if ($files.Count -gt 0) {
                    $f = $files[0]; $s.Exists = $true
                    $s.Values['Version'] = [string]$f.VersionInfo.FileVersion
                    if ($f.VersionInfo.FileVersion -and $f.VersionInfo.FileVersion -notmatch '^\d+(\.\d+){0,3}$') {
                        # CM reads the numeric file version, not the free-text one
                        $s.Values['Version'] = '{0}.{1}.{2}.{3}' -f $f.VersionInfo.FileMajorPart, $f.VersionInfo.FileMinorPart, $f.VersionInfo.FileBuildPart, $f.VersionInfo.FilePrivatePart
                        $s.Note = 'FileVersion text is ''' + $f.VersionInfo.FileVersion + ''', numeric parts used'
                    }
                    $s.Values['Size'] = [int64]$f.Length
                    $s.Values['DateModified'] = $f.LastWriteTime.ToString('s')
                    $s.Values['DateCreated'] = $f.CreationTime.ToString('s')
                }
            }
            'Folder' {
                $is64 = ([string]$Node.GetAttribute('Is64Bit') -eq 'true')
                $dir = Expand-CmPath -Path ([string]$Node.Path) -Is64Bit $is64
                $s.Target = '{0}\{1} ({2})' -f $dir.TrimEnd('\'), [string]$Node.Filter, $(if ($is64) { '64-bit view' } else { '32-bit view' })
                $dirs = @(Get-ChildItem -Path $dir -Filter ([string]$Node.Filter) -Directory -ErrorAction SilentlyContinue)
                $s.Values['Count'] = $dirs.Count
                if ($dirs.Count -gt 0) { $s.Exists = $true; $s.Values['DateModified'] = $dirs[0].LastWriteTime.ToString('s'); $s.Values['DateCreated'] = $dirs[0].CreationTime.ToString('s') }
            }
            'MSI' {
                $code = [string]$Node.ProductCode
                $s.Target = 'Windows Installer product ' + $code
                $mi = Get-MsiProductInfo -ProductCode $code
                $s.Exists = ($mi.State -eq 'Installed')
                $s.Values['Count'] = $(if ($s.Exists) { 1 } else { 0 })
                $s.Values['ProductVersion'] = $mi.Version
                $s.Values['ProductName'] = $mi.Name
                $s.Note = $mi.State
            }
            'RegistryKey' {
                # Is64Bit="true": the client reads the 64-bit view only. Is64Bit="false" ("32-bit
                # application"): the client accepted the key in either view on the lab client
                # (5.00.9141) - tested with the key in the 32-bit view only and in the 64-bit view
                # only, discovered both times. Evaluated the same way here: 32-bit view first.
                $is64 = ([string]$Node.GetAttribute('Is64Bit') -eq 'true')
                $hive = [string]$Node.GetAttribute('Hive'); if (-not $hive) { $hive = [string]$Node.Hive }
                $key = [string]$Node.Key
                $s.Target = '{0}\{1} ({2})' -f $hive, $key, $(if ($is64) { '64-bit view' } else { '32-bit app: either view' })
                $views = $(if ($is64) { @($true) } else { @($false, $true) })
                foreach ($v64 in $views) {
                    $k = (Get-RegistryBaseKey -Hive $hive -Is64Bit $v64).OpenSubKey($key)
                    if ($k) { $s.Exists = $true; $s.Values['Count'] = 1; $k.Close(); if (-not $is64) { $s.Note = 'found in the ' + $(if ($v64) { '64-bit' } else { '32-bit' }) + ' view' }; break }
                }
                if (-not $s.Exists) { $s.Values['Count'] = 0; $s.Note = 'key missing' + $(if ($is64) { Test-OtherRegistryView -Hive $hive -Key $key -ValueName '' -Is64Bit $true } else { ' in both views' }) }
            }
            'SimpleSetting' {
                $src = $Node.SelectSingleNode("*[local-name()='RegistryDiscoverySource']")
                if ($src) {
                    $is64 = ([string]$src.GetAttribute('Is64Bit') -eq 'true')
                    $hive = [string]$src.GetAttribute('Hive'); $key = [string]$src.Key; $vname = [string]$src.ValueName
                    $s.Kind = 'RegistryValue'
                    $s.Target = '{0}\{1} : {2} ({3})' -f $hive, $key, $vname, $(if ($is64) { '64-bit view' } else { '32-bit app: either view' })
                    $views = $(if ($is64) { @($true) } else { @($false, $true) })
                    $keySeen = $false
                    foreach ($v64 in $views) {
                        $k = (Get-RegistryBaseKey -Hive $hive -Is64Bit $v64).OpenSubKey($key)
                        if (-not $k) { continue }
                        $keySeen = $true
                        $v = $k.GetValue($vname, $null); $k.Close()
                        if ($null -ne $v) { $s.Exists = $true; $s.Values['Value'] = [string]$v; $s.Values['Count'] = 1; if (-not $is64) { $s.Note = 'found in the ' + $(if ($v64) { '64-bit' } else { '32-bit' }) + ' view' }; break }
                    }
                    if (-not $s.Exists) {
                        $s.Values['Count'] = 0
                        if ($keySeen) { $s.Note = 'key exists, value missing' + $(if ($is64) { Test-OtherRegistryView -Hive $hive -Key $key -ValueName $vname -Is64Bit $true } else { '' }) }
                        else { $s.Note = 'key missing' + $(if ($is64) { Test-OtherRegistryView -Hive $hive -Key $key -ValueName $vname -Is64Bit $true } else { ' in both views' }) }
                    }
                } else {
                    $other = $Node.SelectSingleNode("*[contains(local-name(),'DiscoverySource')]")
                    $s.Kind = $(if ($other) { $other.LocalName } else { 'SimpleSetting' })
                    $s.Note = 'setting type not evaluated by this script'
                }
            }
            default { $s.Note = 'setting type not evaluated by this script' }
        }
    } catch { $s.Note = 'error: ' + $_.Exception.Message }
    return $s
}
function Test-CmExpression {
    # Walks the <Rule> expression tree; fills $Clauses with one line per leaf; returns
    # $true / $false / $null (could not evaluate).
    param([System.Xml.XmlElement]$Expr, [hashtable]$Settings, [System.Collections.Generic.List[object]]$Clauses, [int]$Depth = 0)
    $op = [string]$Expr.SelectSingleNode("*[local-name()='Operator']").InnerText
    $operands = $Expr.SelectSingleNode("*[local-name()='Operands']")
    if (-not $operands) { $Clauses.Add([pscustomobject]@{ Clause = $op + ' (no operands)'; Actual = ''; Result = 'not evaluated' }); return $null }
    $subExprs = @($operands.SelectNodes("*[local-name()='Expression']"))
    if ($op -in @('And', 'Or', 'Not') -or $subExprs.Count -gt 0) {
        $results = @()
        foreach ($se in $subExprs) { $results += ,(Test-CmExpression -Expr $se -Settings $Settings -Clauses $Clauses -Depth ($Depth + 1)) }
        switch ($op) {
            'And' { if ($results -contains $false) { return $false }; if ($results -contains $null) { return $null }; return $true }
            'Or'  { if ($results -contains $true) { return $true }; if ($results -contains $null) { return $null }; return $false }
            'Not' { if ($null -eq $results[0]) { return $null }; return -not $results[0] }
            default { return $null }
        }
    }
    $ref = $operands.SelectSingleNode("*[local-name()='SettingReference']")
    $const = $operands.SelectSingleNode("*[local-name()='ConstantValue']")
    if (-not $ref) { $Clauses.Add([pscustomobject]@{ Clause = "$op (no setting reference)"; Actual = ''; Result = 'not evaluated' }); return $null }
    $ln = [string]$ref.GetAttribute('SettingLogicalName')
    $prop = [string]$ref.GetAttribute('PropertyPath'); $method = [string]$ref.GetAttribute('Method'); $dtype = [string]$ref.GetAttribute('DataType')
    $expected = $(if ($const) { [string]$const.GetAttribute('Value') } else { '' })
    $setting = $Settings[$ln]
    if (-not $setting) { $Clauses.Add([pscustomobject]@{ Clause = "$ln $op $expected"; Actual = ''; Result = 'setting not found in policy' }); return $null }
    $what = $(if ($method -eq 'Count') { 'Count' } elseif ($prop) { $prop } else { 'Value' })
    $actual = $null
    if ($setting.Values.ContainsKey($what)) { $actual = $setting.Values[$what] }
    $exists = $setting.Exists
    $desc = '{0} {1}: {2} {3} {4}' -f $setting.Kind, $setting.Target, $what, $op, $expected
    if ($what -eq 'Count' -and $op -eq 'NotEquals' -and $expected -eq '0') { $desc = '{0} {1} exists' -f $setting.Kind, $setting.Target }
    $result = $null
    if ($what -ne 'Count' -and -not $exists) {
        $result = $false
        $Clauses.Add([pscustomobject]@{ Clause = $desc; Actual = 'not present' + $(if ($setting.Note) { ' (' + $setting.Note + ')' } else { '' }); Result = 'false' })
        return $false
    }
    if ($setting.Note -like 'setting type not evaluated*' -or $setting.Note -like 'error:*') {
        $Clauses.Add([pscustomobject]@{ Clause = $desc; Actual = ''; Result = 'not evaluated - ' + $setting.Note }); return $null
    }
    $result = Compare-CmValue -Operator $op -Actual $actual -Expected $expected -DataType $dtype
    $actualText = [string]$actual
    if ($null -eq $result) { $Clauses.Add([pscustomobject]@{ Clause = $desc; Actual = $actualText; Result = 'not evaluated (operator ' + $op + ' / ' + $dtype + ' ''' + $actualText + ''' not comparable)' }); return $null }
    $Clauses.Add([pscustomobject]@{ Clause = $desc; Actual = $actualText + $(if ($setting.Note) { ' (' + $setting.Note + ')' } else { '' }); Result = $result.ToString().ToLower() })
    return $result
}
function Test-LocalDetection {
    param([string]$ExpressionXml)
    $out = [ordered]@{ Type = 'Enhanced (File/Folder/Registry/MSI clauses)'; Clauses = @(); Result = 'unknown'; Note = '' }
    try {
        $xml = New-Object System.Xml.XmlDocument
        $xml.LoadXml($ExpressionXml)
        $settings = @{}
        foreach ($n in $xml.DocumentElement.SelectSingleNode("*[local-name()='Settings']").ChildNodes) {
            if ($n -isnot [System.Xml.XmlElement]) { continue }
            $s = Read-CmSetting -Node $n
            $settings[$s.LogicalName] = $s
        }
        $rule = $xml.DocumentElement.SelectSingleNode("*[local-name()='Rule']")
        $expr = $rule.SelectSingleNode("*[local-name()='Expression']")
        $clauses = New-Object System.Collections.Generic.List[object]
        $r = Test-CmExpression -Expr $expr -Settings $settings -Clauses $clauses
        $out.Clauses = $clauses.ToArray()
        $out.Result = $(if ($null -eq $r) { 'not evaluable' } elseif ($r) { 'DISCOVERED (rule true)' } else { 'NOT DISCOVERED (rule false)' })
        if ([string]$rule.GetAttribute('NonCompliantWhenSettingIsNotFound') -eq 'true') { $out.Note = 'NonCompliantWhenSettingIsNotFound=true' }
    } catch { $out.Result = 'parse error'; $out.Note = $_.Exception.Message }
    return $out
}
function Test-ScriptDetection {
    # Runs the deployment type's detection script the way the client does (SYSTEM, 64-bit
    # unless RunAs32Bit): discovered = exit 0, something on stdout, nothing on stderr.
    param([string]$Body, [int]$ScriptType, [bool]$RunAs32Bit)
    $out = [ordered]@{ Type = 'Script'; Language = $(switch ($ScriptType) { 0 { 'PowerShell' } 1 { 'VBScript' } 2 { 'JScript' } default { "type $ScriptType" } }); RunAs32Bit = $RunAs32Bit; Lines = ([regex]::Matches($Body, "`n").Count + 1); Result = 'unknown'; ExitCode = $null; StdOut = ''; StdErr = ''; Seconds = 0; Note = '' }
    if ($ScriptType -ne 0) { $out.Result = 'not run (only PowerShell detection scripts are run here)'; $out.Head = $Body.Substring(0, [Math]::Min(400, $Body.Length)); return $out }
    try {
        $tmp = Join-Path $env:TEMP ('AZITC-TK-detect-' + [guid]::NewGuid().ToString('N') + '.ps1')
        [System.IO.File]::WriteAllText($tmp, $Body, (New-Object System.Text.UTF8Encoding $true))
        $exe = if ($RunAs32Bit -and (Test-Path "$env:windir\SysWOW64\WindowsPowerShell\v1.0\powershell.exe")) { "$env:windir\SysWOW64\WindowsPowerShell\v1.0\powershell.exe" } else { "$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe" }
        if ($RunAs32Bit -and $env:PROCESSOR_ARCHITEW6432 -eq 'AMD64') { $exe = "$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe" }   # already 32-bit host
        if (-not $RunAs32Bit -and $env:PROCESSOR_ARCHITEW6432 -eq 'AMD64') { $exe = "$env:windir\Sysnative\WindowsPowerShell\v1.0\powershell.exe" }
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $exe
        $psi.Arguments = '-NoLogo -NonInteractive -NoProfile -ExecutionPolicy Bypass -File "' + $tmp + '"'
        $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $stdout = $p.StandardOutput.ReadToEndAsync(); $stderr = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit(60000)) { try { $p.Kill() } catch { }; $out.Result = 'timeout after 60 s'; $out.Seconds = 60 }
        else {
            $out.ExitCode = $p.ExitCode; $out.Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
            $out.StdOut = ($stdout.Result).Trim(); $out.StdErr = ($stderr.Result).Trim()
            if ($out.StdOut.Length -gt 600) { $out.StdOut = $out.StdOut.Substring(0, 600) + '...' }
            if ($out.StdErr.Length -gt 600) { $out.StdErr = $out.StdErr.Substring(0, 600) + '...' }
            if ($p.ExitCode -eq 0 -and $out.StdOut.Length -gt 0 -and $out.StdErr.Length -eq 0) { $out.Result = 'DISCOVERED (exit 0, output on stdout, no stderr)' }
            elseif ($p.ExitCode -eq 0 -and $out.StdOut.Length -eq 0) { $out.Result = 'NOT DISCOVERED (exit 0, nothing on stdout)' }
            elseif ($p.ExitCode -ne 0) { $out.Result = 'ERROR (exit ' + $p.ExitCode + ' - the client treats this as a detection failure, not as "not installed")' }
            else { $out.Result = 'ERROR (exit 0 but stderr not empty - the client treats this as a detection failure)' }
        }
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    } catch { $out.Result = 'could not run: ' + $_.Exception.Message }
    return $out
}

# --- 5. Per deployment type: synclets, detection, enforcement history -----------------------

$dts = New-Object System.Collections.Generic.List[object]
$dtList = @()
if ($app) { $dtList = @($app.AppDTs) }
$synName = @{}
$synContent = @{}
try {
    Get-CimInstance -Namespace 'root\ccm\CIModels' -ClassName 'CCM_AppDeliveryTypeSynclet' -ErrorAction Stop | ForEach-Object {
        $synName[$_.AppDeliveryTypeId + '/' + $_.Revision] = [string]$_.AppDeliveryTypeName
        # the install action's content id and version (embedded ContentInfo)
        try { $ci = $_.InstallAction.Content; if ($ci -and $ci.ContentId) { $synContent[$_.AppDeliveryTypeId + '/' + $_.Revision] = [pscustomobject]@{ Id = [string]$ci.ContentId; Version = [string]$ci.ContentVersion } } } catch { }
    }
} catch { $errors.Add("CCM_AppDeliveryTypeSynclet: $($_.Exception.Message)") }
$cacheItems = @()
try { $cacheItems = @(Get-CimInstance -Namespace 'root\ccm\SoftMgmtAgent' -ClassName 'CacheInfoEx' -ErrorAction Stop) } catch { $errors.Add("CacheInfoEx: $($_.Exception.Message)") }
$logCas = $null; $logCtm = $null; $logLs = $null; $logDts = $null   # read only when a DT has content
$enforceStatus = @{}
try { Get-CimInstance -Namespace 'root\ccm\CIModels' -ClassName 'CCM_AppEnforceStatus' -ErrorAction Stop | ForEach-Object { $enforceStatus[$_.AppDeliveryTypeId] = [pscustomobject]@{ Revision = [int]$_.Revision; ExecutionStatus = [string]$_.ExecutionStatus; ExitCode = [uint32]$_.ExitCode; ExitHex = ('0x{0:X8}' -f [uint32]$_.ExitCode) } } } catch { $errors.Add("CCM_AppEnforceStatus: $($_.Exception.Message)") }

foreach ($d in $dtList) {
    $dtId = [string]$d.Id; $rev = [int]$d.Revision
    $dtGuidPart = ($dtId -split '/')[-1]
    $entry = [ordered]@{
        Name = [string]$d.Name; Id = $dtId; Revision = $rev
        Applicability = [string]$d.ApplicabilityState; Supersession = [string]$d.SupersessionState
        PolicyName = $synName[$dtId + '/' + $rev]
    }
    # install action of this revision
    try {
        $inst = Get-CimInstance -Namespace 'root\ccm\CIModels' -ClassName 'CCM_LocalInstallationSynclet' -ErrorAction Stop | Where-Object { $_.AppDeliveryTypeId -eq $dtId -and [int]$_.Revision -eq $rev -and $_.ActionType -eq 'Install' } | Select-Object -First 1
        if ($inst) {
            $entry.Install = [pscustomobject]@{
                CommandLine = [string]$inst.InstallCommandLine; Context = [string]$inst.ExecutionContext; RequiresLogOn = [string]$inst.RequiresLogOn
                MaxExecuteTimeMin = [int]$inst.MaxExecuteTime; SuccessExitCodes = @($inst.SuccessExitCodes | ForEach-Object { [string]$_ }) -join ','
                RebootExitCodes = @($inst.RebootExitCodes | ForEach-Object { [string]$_ }) -join ','; FastRetryExitCodes = @($inst.FastRetryExitCodes | ForEach-Object { [string]$_ }) -join ','
                PostInstallBehavior = [string]$inst.PostInstallbehavior; RunAs32Bit = [bool]$inst.RunAs32Bit
            }
        } else { $entry.Install = $null }
    } catch { $errors.Add("CCM_LocalInstallationSynclet: $($_.Exception.Message)") }
    # detection method of this revision, evaluated
    $det = $null
    try {
        $loc = Get-CimInstance -Namespace 'root\ccm\CIModels' -ClassName 'Local_Detect_Synclet' -ErrorAction Stop | Where-Object { $_.AppDeliveryTypeId -eq $dtId -and [int]$_.Revision -eq $rev } | Select-Object -First 1
        if ($loc) { $det = Test-LocalDetection -ExpressionXml ([string]$loc.ExpressionXml) }
    } catch { $errors.Add("Local_Detect_Synclet: $($_.Exception.Message)") }
    if (-not $det) {
        try {
            $scr = Get-CimInstance -Namespace 'root\ccm\CIModels' -ClassName 'Script_Detect_Synclet' -ErrorAction Stop | Where-Object { $_.AppDeliveryTypeId -eq $dtId -and [int]$_.Revision -eq $rev } | Select-Object -First 1
            if ($scr) { $det = Test-ScriptDetection -Body ([string]$scr.ScriptBody) -ScriptType ([int]$scr.ScriptType) -RunAs32Bit ([bool]$scr.RunAs32Bit) }
        } catch { $errors.Add("Script_Detect_Synclet: $($_.Exception.Message)") }
    }
    if (-not $det) {
        try {
            $msi = Get-CimInstance -Namespace 'root\ccm\CIModels' -ClassName 'MSI_Detect_Synclet' -ErrorAction Stop | Where-Object { $_.AppDeliveryTypeId -eq $dtId -and [int]$_.Revision -eq $rev } | Select-Object -First 1
            if ($msi) {
                $mi = Get-MsiProductInfo -ProductCode ([string]$msi.ProductCode)
                $det = [ordered]@{ Type = 'MSI product code'; Clauses = @([pscustomobject]@{ Clause = 'Windows Installer product ' + [string]$msi.ProductCode + ' installed' + $(if ([string]$msi.ProductVersion) { ', version ' + [string]$msi.ProductVersion } else { '' }); Actual = $mi.State + $(if ($mi.Version) { ' ' + $mi.Version } else { '' }); Result = $(if ($mi.State -eq 'Installed') { 'true' } else { 'false' }) }); Result = $(if ($mi.State -eq 'Installed') { 'DISCOVERED' } else { 'NOT DISCOVERED' }); Note = '' }
            }
        } catch { $errors.Add("MSI_Detect_Synclet: $($_.Exception.Message)") }
    }
    if (-not $det) {
        $revsHere = @()
        try { $revsHere = @(Get-CimInstance -Namespace 'root\ccm\CIModels' -ClassName 'CCM_HandlerSynclet' -ErrorAction Stop | Where-Object { $_.AppDeliveryTypeId -eq $dtId -and $_.ActionType -eq 'Detect' } | ForEach-Object { [int]$_.Revision } | Sort-Object -Unique) } catch { }
        $det = [ordered]@{ Type = 'unknown'; Clauses = @(); Result = 'no detection synclet for revision ' + $rev + ' on the client'; Note = 'revisions present: ' + ($revsHere -join ',') }
    }
    $entry.Detection = [pscustomobject]$det
    $entry.LastEnforce = $enforceStatus[$dtId]

    # content: is it in the cache, and what do the download logs say about it
    $content = $null
    $ci = $synContent[$dtId + '/' + $rev]
    if ($ci) {
        $content = [ordered]@{ Id = $ci.Id; Version = $ci.Version; InCache = $false; CacheFolder = ''; CacheSizeMB = 0; Cas = @(); Ctm = @(); Ls = @(); Dts = @(); Signal = '' }
        $hit = $cacheItems | Where-Object { $_.ContentId -eq $ci.Id } | Sort-Object { [int]$_.ContentVer } -Descending | Select-Object -First 1
        if ($hit) { $content.InCache = ([string]$hit.ContentVer -eq $ci.Version); $content.CacheFolder = [string]$hit.Location; $content.CacheSizeMB = [math]::Round([double]$hit.ContentSize / 1024, 1); if (-not $content.InCache) { $content.Signal = 'cache holds version ' + $hit.ContentVer + ', policy wants ' + $ci.Version } }
        if ($null -eq $logCas) { $logCas = Read-CmLog 'CAS.log'; $logCtm = Read-CmLog 'ContentTransferManager.log'; $logLs = Read-CmLog 'LocationServices.log'; $logDts = Read-CmLog 'DataTransferService.log' }
        $cas = @($logCas | Where-Object { $_.Text -like ('*' + $ci.Id + '*') -and $_.Text -notmatch '^(Saved|Removed) Content ID Mapping|^Raising event' })
        $jobs = @{}; foreach ($e in $cas) { if ($e.Text -match 'CTM job (\{[0-9A-Fa-f-]+\})') { $jobs[$Matches[1]] = $true } }
        $ctm = @($logCtm | Where-Object { $t = $_.Text; ($jobs.Keys | Where-Object { $t.Contains($_) }).Count -gt 0 })
        $lsReq = @{}; foreach ($e in $ctm) { if ($e.Text -match "LSRequest\('(\{[0-9A-Fa-f-]+\})'\)") { $lsReq[$Matches[1]] = $true } }
        $corr = @{}
        foreach ($e in $logLs) { if ($e.Text -like ('*' + $ci.Id + '*') -and $e.Text -match 'CorrelationID (\{[0-9A-Fa-f-]+\})') { $corr[$Matches[1]] = $true } }
        $ls = @($logLs | Where-Object { $t = $_.Text; $t.Contains($ci.Id) -or ((@($lsReq.Keys) + @($corr.Keys)) | Where-Object { $t.Contains($_) }).Count -gt 0 })
        $dtsJobs = @{}; foreach ($e in $ctm) { if ($e.Text -match 'DTSJob\((\{[0-9A-Fa-f-]+\})\)') { $dtsJobs[$Matches[1]] = $true } }
        $dtsLines = @($logDts | Where-Object { $t = $_.Text; $t.Contains($ci.Id) -or (@($dtsJobs.Keys) | Where-Object { $t.Contains($_) }).Count -gt 0 })
        $content.Cas = @(Tail-Entries -Entries $cas -Max $MaxLines); $content.Ctm = @(Tail-Entries -Entries $ctm -Max $MaxLines)
        $content.Ls = @(Tail-Entries -Entries $ls -Max $MaxLines); $content.Dts = @(Tail-Entries -Entries $dtsLines -Max $MaxLines)
        $lastLs = @($ls | Select-Object -Last 3 | ForEach-Object { $_.Text }) -join ' '
        $lastCtm = @($ctm | Select-Object -Last 3 | ForEach-Object { $_.Text }) -join ' '
        if ($lastLs -match 'empty distribution points list' -or $lastCtm -match 'Received empty location update') { $content.Signal = 'no distribution point offers this content to the device (empty location list)' }
        elseif ($lastCtm -match 'CCM_DOWNLOADSTATUS_WAITING_CONTENTLOCATIONS') { $content.Signal = 'waiting for content locations' }
        elseif ((($dtsLines | Select-Object -Last 3 | ForEach-Object { $_.Text }) -join ' ') -match 'HTTP\D*(\d{3})') { $content.Signal = 'download error, HTTP ' + $Matches[1] }
        elseif ($cas.Count -gt 0 -and $cas[-1].Text -match 'failed|error') { $content.Signal = $cas[-1].Text.Substring(0, [Math]::Min(160, $cas[-1].Text.Length)) }
    }
    $entry.Content = $(if ($content) { [pscustomobject]$content } else { $null })

    # timeline from the logs, this DT and this revision only (the client keeps evaluating
    # older revisions too; they would quadruple the list and say nothing new)
    $otherRevs = 0
    $disc = @($logDiscovery | Where-Object { $_.Text -like "*$dtGuidPart*" -and $_.Text -match 'discover' } | ForEach-Object {
        $r = 'evaluating'; if ($_.Text -match 'not discovered') { $r = 'NOT discovered' } elseif ($_.Text -match '\+\+\+ (Discovered application|Application discovered)') { $r = 'discovered' } else { return }
        $rv = -1; if ($_.Text -match 'Revision:? ?(\d+)') { $rv = [int]$Matches[1] }
        if ($rv -ne $rev) { $otherRevs++; return }
        $how = ''; if ($_.Text -match 'script') { $how = ' (script)' }
        [pscustomobject]@{ Time = $_.Time; Text = ('rev {0}: {1}{2}' -f $rv, $r, $how) }
    })
    $entry.DiscoveryHistory = @(Tail-Entries -Entries $disc -Max $MaxLines)
    $entry.DiscoveryOtherRevisions = $otherRevs
    # enforcement attempts: block from "Starting ... enforcement" to "App enforcement completed"
    $attempts = New-Object System.Collections.Generic.List[object]
    $cur = $null
    foreach ($e in $logEnforce) {
        if ($e.Text -match '^\+\+\+ Starting (\w+) enforcement for App DT "([^"]*)" ApplicationDeliveryType - (\S+), Revision - (\d+)') {
            if ($Matches[3] -ne $dtId) { if ($cur) { $cur = $null }; continue }
            $cur = [ordered]@{ StartUtc = $e.Time.ToUniversalTime().ToString('s'); Action = $Matches[1]; Revision = [int]$Matches[4]; PreDetection = ''; Command = ''; ExitCode = $null; ExitMeaning = ''; PostDetection = ''; Seconds = $null; Notes = @() }
            continue
        }
        if (-not $cur) { continue }
        if ($e.Text -match '^\+\+\+ Application not discovered' -or $e.Text -match '^\+\+\+ (Discovered application|Application discovered)') {
            $val = $(if ($e.Text -match 'not discovered') { 'not discovered' } else { 'discovered' })
            if ($null -eq $cur.ExitCode) { $cur.PreDetection = $val } else { $cur.PostDetection = $val }
            continue
        }
        if ($e.Text -match '^Prepared command line: (.*)$') { $cur.Command = $Matches[1]; continue }
        if ($e.Text -match 'terminated with exitcode: (-?\d+)') { $cur.ExitCode = [int64]$Matches[1]; continue }
        if ($e.Text -match '^Matched exit code (-?\d+) to an? (\w+) entry') { $cur.ExitMeaning = $Matches[2]; continue }
        if ($e.Text -match '^Unmatched exit code \((-?\d+)\) is considered an execution failure') { $cur.ExitMeaning = 'Unmatched = failure'; continue }
        if ($e.Text -match 'Timeout = (\d+) minutes' -or $e.Text -match '^Waiting for process') { continue }
        if ($e.Text -match '(failed|error|exceeded|timed out|cannot|could not|Unable)' -and $cur.Notes.Count -lt 5) { $cur.Notes += $e.Text.Substring(0, [Math]::Min(200, $e.Text.Length)); continue }
        if ($e.Text -match '^\+\+\+\+\+\+ App enforcement completed \((\d+) seconds\) for App DT "[^"]*" \[(\S+)\], Revision:? ?(\d+)') {
            if ($Matches[2] -eq $dtId) { $cur.Seconds = [int]$Matches[1]; $cur.EndUtc = $e.Time.ToUniversalTime().ToString('s'); $attempts.Add([pscustomobject]$cur) }
            $cur = $null
        }
    }
    if ($cur) { $cur.Notes += 'block not closed in the log (still running or log rolled)'; $attempts.Add([pscustomobject]$cur) }
    $entry.Attempts = @($attempts | Select-Object -Last $MaxLines)
    $entry.AttemptsTotal = $attempts.Count
    $entry.IntentHistory = @(Tail-Entries -Entries @($logIntent | Where-Object { $_.Text -like "*$dtGuidPart*" -and $_.Text -notmatch '^No dependencies' }) -Max $MaxLines)
    # requirement rules of this revision, last status per rule (DCMReporting.log names the
    # policy document as the DT id with "_" for "-" and "/", then the revision)
    $polPrefix = (($dtId -replace '[-/]', '_') + '_' + $rev + '_Requirements_PolicyDocument')
    $reqs = @{}
    foreach ($e in $logDcm) {
        if ($e.Text -match '^In policy:(\S+?), rule:(\S+?) status is:(\w+)' -and $Matches[1] -eq $polPrefix) {
            $ruleId = $Matches[2]; $status = $Matches[3]
            if ($ruleId -notlike 'Rule_*') { continue }
            $ruleId = $ruleId -replace '^Rule_([0-9a-fA-F]{8})_([0-9a-fA-F]{4})_([0-9a-fA-F]{4})_([0-9a-fA-F]{4})_([0-9a-fA-F]{12})$', 'Rule_$1-$2-$3-$4-$5'
            $reqs[$ruleId] = [pscustomobject]@{ Rule = $ruleId; Status = $status; TimeUtc = $e.Time.ToUniversalTime().ToString('s') }
        }
    }
    $entry.Requirements = @($reqs.Values | Sort-Object Rule)
    $dts.Add([pscustomobject]$entry)
}

# app-level intent lines (Application_x/rev :- Current State = ...)
$appIntent = @()
if ($appGuid) { $appIntent = @(Tail-Entries -Entries @($logIntent | Where-Object { $_.Text.ToLower().Contains($appGuid) -and $_.Text -notmatch '^(No dependencies|DT id = )' }) -Max $MaxLines) }

# --- 6. Evaluation cycle: when did the client last look, when will it again ---------------

$cycle = [ordered]@{}
try {
    $hist = Get-CimInstance -Namespace 'root\ccm\Scheduler' -ClassName 'CCM_Scheduler_History' -ErrorAction Stop
    $h121 = $hist | Where-Object { $_.ScheduleID -eq '{00000000-0000-0000-0000-000000000121}' -and $_.UserSID -eq 'Machine' } | Select-Object -First 1
    $h021 = $hist | Where-Object { $_.ScheduleID -eq '{00000000-0000-0000-0000-000000000021}' -and $_.UserSID -eq 'Machine' } | Select-Object -First 1
    if ($h121) { $cycle.AppDeploymentEvalLastUtc = ToIsoLocalDigits $h121.LastTriggerTime }
    if ($h021) { $cycle.MachinePolicyLastUtc = ToIsoLocalDigits $h021.LastTriggerTime }
} catch { $errors.Add("CCM_Scheduler_History: $($_.Exception.Message)") }
try {
    $sched = Get-CimInstance -Namespace 'root\ccm\Policy\Machine\ActualConfig' -ClassName 'CCM_Scheduler_ScheduledMessage' -ErrorAction Stop | Where-Object { $_.ScheduledMessageID -eq '{00000000-0000-0000-0000-000000000121}' } | Select-Object -First 1
    if ($sched) { $cycle.AppDeploymentEvalSchedule = ([string]$sched.Triggers -replace '^SMSSchedule;', '') }
} catch { }
try {
    $pa = Read-CmLog 'PolicyAgent.log'
    $lastAssign = @($pa | Where-Object { $_.Text -match 'Assignment Request' } | Select-Object -Last 1)
    if ($lastAssign.Count -gt 0) { $cycle.LastAssignmentRequest = '{0} {1}' -f $lastAssign[0].Time.ToUniversalTime().ToString('s'), $lastAssign[0].Text }
} catch { }

# --- 6b. Maintenance windows and the execution queue: what the client is waiting for -----------

# ServiceWindowType as the console names it. 6 is the "business hours" window Software Center
# lets the user define; the client checks it for user-facing deployments.
$swTypeNames = @{ 1 = 'All deployments'; 2 = 'Programs'; 3 = 'Reboot required'; 4 = 'Software updates'; 5 = 'Task sequences'; 6 = 'Business hours (Software Center)' }
$windows = New-Object System.Collections.Generic.List[object]
$nowLocal = Get-Date
try {
    # CCM_ServiceWindow in the ClientSDK lists the upcoming occurrences with start/end already
    # resolved; the raw schedule tokens sit in ActualConfig. Times carry the local clock (see
    # ToIsoLocalDigits); Duration 0 with a 2038 start is the "no window" placeholder.
    foreach ($w in @(Get-CimInstance -Namespace 'root\ccm\ClientSDK' -ClassName 'CCM_ServiceWindow' -ErrorAction Stop)) {
        if ([int]$w.Duration -le 0) { continue }
        $start = [datetime]$w.StartTime; if ($start.Kind -eq 'Local') { $start = $start.ToUniversalTime() }   # back to the digits = device local time
        $end = [datetime]$w.EndTime;     if ($end.Kind -eq 'Local')   { $end = $end.ToUniversalTime() }
        if ($end -lt $nowLocal.AddHours(-1)) { continue }
        $windows.Add([pscustomobject]@{
            Id = [string]$w.ID; Type = [int]$w.Type; TypeName = $(if ($swTypeNames.ContainsKey([int]$w.Type)) { $swTypeNames[[int]$w.Type] } else { 'type ' + $w.Type })
            StartLocal = $start.ToString('s'); EndLocal = $end.ToString('s'); Minutes = [int]([int]$w.Duration / 60)
            ActiveNow = ($start -le $nowLocal -and $end -gt $nowLocal)
        })
    }
} catch { $errors.Add("CCM_ServiceWindow: $($_.Exception.Message)") }
$windows = @($windows | Sort-Object StartLocal)
$windowInfo = [ordered]@{
    DeviceTimeLocal = $nowLocal.ToString('s'); TimeZone = [TimeZoneInfo]::Local.Id; UtcOffsetMinutes = [int][TimeZoneInfo]::Local.GetUtcOffset($nowLocal).TotalMinutes
    Windows = $windows
    # windows that gate application deployments: "All deployments" and "Programs"
    Restricting = @($windows | Where-Object { $_.Type -in 1, 2 })
    ActiveNow = @($windows | Where-Object { $_.ActiveNow -and $_.Type -in 1, 2 })
    Next = $null
    LogLines = @()
}
$windowInfo.Next = @($windowInfo.Restricting | Where-Object { [datetime]$_.StartLocal -gt $nowLocal } | Select-Object -First 1)
if ($windowInfo.Next.Count -gt 0) { $windowInfo.Next = $windowInfo.Next[0] } else { $windowInfo.Next = $null }
try {
    $logSw = Read-CmLog 'ServiceWindowManager.log'
    $windowInfo.LogLines = @(Tail-Entries -Entries @($logSw | Where-Object { $_.Text -match 'OnIsServiceWindowAvailable|Biggest Active|can run|cannot run|Restricting|SERVICEWINDOWEVENT|Next Event' }) -Max $MaxLines)
} catch { }

# the execution queue: what ExecMgr holds for this application (install jobs waiting for
# content, a window, a retry - or running)
$queue = New-Object System.Collections.Generic.List[object]
try {
    $myIds = @()
    foreach ($d in $dtList) { $myIds += ([string]$d.Id -split '/')[-1]; $ci = $synContent[[string]$d.Id + '/' + [int]$d.Revision]; if ($ci -and $ci.Id) { $myIds += [string]$ci.Id } }
    foreach ($q in @(Get-CimInstance -Namespace 'root\ccm\SoftMgmtAgent' -ClassName 'CCM_ExecutionRequestEx' -ErrorAction Stop)) {
        $progId = [string]$q.ProgramID; $cid = [string]$q.ContentID
        $mine = ($appGuid -and $progId.ToLower().Contains($appGuid))
        foreach ($id in $myIds) { if ($id -and ($progId -like "*$id*" -or $cid -like "*$id*")) { $mine = $true } }
        if (-not $mine) { continue }
        $queue.Add([pscustomobject]@{
            RequestId = [string]$q.RequestID; ProgramId = $progId; ContentId = $cid; State = [string]$q.State; RunningState = [string]$q.RunningState
            CompletionState = [string]$q.CompletionState; ReceivedUtc = (ToIsoLocalDigits $q.ReceivedTime); NextRetryUtc = (ToIsoLocalDigits $q.NextRetryTime)
            RetryCount = [int]$q.RetryCount; RetryInterval = [int]$q.RetryInterval; ExitCode = [string]$q.ProgramExitCode; Reason = [string]$q.TaskPauseReason
        })
    }
} catch { $errors.Add("CCM_ExecutionRequestEx: $($_.Exception.Message)") }

# --- 7. Add/Remove Programs: what is really registered ---------------------------------------

$arp = New-Object System.Collections.Generic.List[object]
try {
    $tokens = New-Object System.Collections.Generic.List[string]
    if ($app) { $tokens.Add(([string]$app.Name)); foreach ($d in $dtList) { $n = ([string]$d.Name -split ' - ')[0]; if ($n) { $tokens.Add($n) } } }
    $tokens = @($tokens | ForEach-Object { $_.Trim() } | Where-Object { $_.Length -ge 3 } | Sort-Object -Unique)
    foreach ($root in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall') {
        Get-ChildItem -Path $root -ErrorAction SilentlyContinue | ForEach-Object {
            $p = Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue
            $dn = [string]$p.DisplayName
            if (-not $dn) { return }
            $hit = $false
            foreach ($t in $tokens) { if ($dn -like "*$t*") { $hit = $true; break } }
            if (-not $hit) { return }
            $arp.Add([pscustomobject]@{
                DisplayName = $dn; DisplayVersion = [string]$p.DisplayVersion; Publisher = [string]$p.Publisher
                Key = $_.PSChildName; View = $(if ($root -like '*WOW6432Node*') { '32-bit' } else { '64-bit' })
                WindowsInstaller = ([int]$p.WindowsInstaller -eq 1); InstallDate = [string]$p.InstallDate
                UninstallString = [string]$p.UninstallString
            })
        }
    }
} catch { $errors.Add("ARP: $($_.Exception.Message)") }

# --- 8. Verdicts: the facts, read in causal order ----------------------------------------------

$verdicts = New-Object System.Collections.Generic.List[object]
function Add-Verdict { param([string]$Level, [string]$Text, [string]$Next = '') $verdicts.Add([pscustomobject]@{ Level = $Level; Text = $Text; Next = $Next }) }

if (-not $app) {
    Add-Verdict 'Fail' ('The client has no CCM_Application with Id ' + $AppId + ' - no policy for this application reached the device.') 'Check the deployment''s collection membership and run a machine policy retrieval; PolicyAgent.log shows what the client asked for.'
} else {
    $required = @($assignments | Where-Object { $_.Purpose -like 'Required*' })
    $wantInstalled = ($app.ResolvedState -eq 'Installed')
    $isInstalled = ($app.InstallState -eq 'Installed')
    $es = [int]$app.EvaluationState
    $main = $dts | Where-Object { $_.Supersession -ne 'Superseded' -and $_.Applicability -eq 'Applicable' } | Select-Object -First 1
    if (-not $main) { $main = $dts | Where-Object { $_.Supersession -ne 'Superseded' } | Select-Object -First 1 }
    if (-not $main) { $main = $dts | Select-Object -First 1 }

    if ($assignments.Count -eq 0) { Add-Verdict 'Warn' 'No deployment for this application is in the client''s machine policy (CCM_ApplicationCIAssignment) - the app is known, but nothing targets it here.' 'If a deployment should target this device, check collection membership and policy retrieval.' }
    if ($app.SupersessionState -eq 'Superseded') { Add-Verdict 'Info' 'This application is superseded by a newer one; the client treats it as not applicable and will neither install nor evaluate it on its own. Look at the superseding application instead.' '' }
    elseif ($app.ApplicabilityState -ne 'Applicable') {
        $failedRules = @()
        foreach ($d in $dts) { foreach ($rq in @($d.Requirements)) { if ($rq.Status -ne 'Conformant') { $failedRules += ('"' + $d.Name + '" ' + $rq.Rule + ' = ' + $rq.Status) } } }
        $ruleText = $(if ($failedRules.Count -gt 0) { ' DCMReporting.log names the rule(s): ' + ($failedRules -join '; ') + ' - the rule text is in the deployment type''s Requirements tab (the window resolves the id when the site can be asked).' } else { ' DCMReporting.log has no requirement result for the current revision in the last ' + $Days + ' days.' })
        Add-Verdict 'Fail' ('The application is ' + $app.ApplicabilityState + ' on this device: a requirement rule of every deployment type failed, so the deployment resolves to nothing and the client will neither install nor retry.' + $ruleText) 'Change the requirement or the device; then "Policy + evaluate".'
    }
    if ($main -and $main.Applicability -ne 'Applicable' -and $app.ApplicabilityState -eq 'Applicable') { Add-Verdict 'Warn' ('Deployment type "' + $main.Name + '" is ' + $main.Applicability + '; another one applies instead.') '' }

    if ($main -and $main.Detection) {
        $dres = [string]$main.Detection.Result
        $detTrue = $dres -like 'DISCOVERED*'
        $detFalse = $dres -like 'NOT DISCOVERED*'
        $detErr = $dres -like 'ERROR*' -or $dres -like 'timeout*' -or $dres -like 'could not*' -or $dres -like 'not evaluable*' -or $dres -like 'parse*'
        $clauseText = @($main.Detection.Clauses | ForEach-Object { '[' + $_.Result + '] ' + $_.Clause + ' -> ' + $_.Actual }) -join ' | '
        if ([string]$main.Detection.Type -eq 'Script') { $clauseText = 'detection script: exit ' + $main.Detection.ExitCode + ', stdout ''' + $main.Detection.StdOut + '''' + $(if ($main.Detection.StdErr) { ', stderr ''' + $main.Detection.StdErr + '''' } else { '' }) }
        # ARP versions against the version the application carries: older ones are the false
        # positives, newer or equal ones are fine (a >= rule is meant to accept them)
        $verOf = { param($s) $s = [string]$s; if ($s -match '(\d+(\.\d+){1,3})') { $parts = @($Matches[1].Split('.') | ForEach-Object { [int]$_ }); while ($parts.Count -lt 4) { $parts += 0 }; return New-Object System.Version($parts[0], $parts[1], $parts[2], $parts[3]) }; return $null }
        $appVer = & $verOf $app.SoftwareVersion
        $arpOlder = @(); $arpSame = @(); $arpUnknown = @()
        foreach ($a in $arp) { $v = & $verOf $a.DisplayVersion; if ($null -eq $v -or $null -eq $appVer) { $arpUnknown += $a } elseif ($v -lt $appVer) { $arpOlder += $a } else { $arpSame += $a } }
        if ($detErr) { Add-Verdict 'Fail' ('The detection of "' + $main.Name + '" rev ' + $main.Revision + ' does not produce a result on this device: ' + $dres + '. The client reports such an app as failed/unknown and never as installed.') 'Fix the detection method (a script must exit 0 and write to stdout only when installed; nothing on stderr).' }
        elseif ($app.InstallState -eq 'NotUpdated') {
            # installed, but with an older revision of the deployment type: the client re-runs
            # the install with the new revision ("Update" in Software Center), for a required
            # deployment on its own - in a maintenance window when one applies
            $wt = ''
            if ($windowInfo.Restricting.Count -gt 0 -and -not [bool](@($required | Select-Object -First 1).OverrideServiceWindows)) {
                if ($windowInfo.ActiveNow.Count -gt 0) { $wt = ' A maintenance window is open now (' + $windowInfo.ActiveNow[0].TypeName + ' until ' + $windowInfo.ActiveNow[0].EndLocal.Replace('T', ' ') + ' device time), so the update is due right now.' }
                elseif ($windowInfo.Next) { $wt = ' It waits for the next maintenance window: ' + $windowInfo.Next.TypeName + ' ' + $windowInfo.Next.StartLocal.Replace('T', ' ') + ' device time.' }
            }
            $qt = ''; $qOpen = @($queue | Where-Object { $_.State -notin 'Completed', 'Expired' }); if ($qOpen.Count -gt 0) { $qt = ' Execution queue: ' + $qOpen[-1].State + $(if ($qOpen[-1].RunningState) { '/' + $qOpen[-1].RunningState } else { '' }) + '.' }
            Add-Verdict $(if ($required.Count -gt 0) { 'Warn' } else { 'Info' }) ('Installed (detection true: ' + $clauseText + '), but with an older revision of the deployment type; the client holds revision ' + $main.Revision + ' now and will run the install again with it - an update, not a repair.' + $(if ($required.Count -gt 0) { ' The deployment is required, so this happens on its own.' } else { ' The deployment is available only; Software Center offers it as Update.' }) + $wt + $qt) 'Wait for the update run; the attempt then appears in the list below with the new revision. Install in this window runs it right away.'
        }
        elseif ($detTrue -and -not $isInstalled) { Add-Verdict 'Warn' ('Evaluated now, the detection says DISCOVERED, while the client''s last evaluation (' + $appInfo.LastEvalUtc + ' UTC) recorded ' + $app.InstallState + '. The device changed since, or the client has not re-evaluated.') 'Run "Policy + evaluate" - the state should turn to Installed.' }
        elseif ($detTrue -and $isInstalled -and $wantInstalled) {
            # the classic false positive: detection true, ARP tells another story
            $arpList = { param($list) ($list | ForEach-Object { $_.DisplayName + ' ' + $_.DisplayVersion + $(if ($_.WindowsInstaller) { ' (MSI)' } else { '' }) }) -join ', ' }
            if ($arp.Count -eq 0) { Add-Verdict 'Warn' ('Detection is true (' + $clauseText + ') but Add/Remove Programs has no entry matching "' + $app.Name + '". The client is satisfied and will not act again; whether the software is really there, the detection rule alone decides.') 'If it is not there: the rule matches something else (leftover file, registry key of an older version, MSI code of another installer). Tighten the rule, then "Policy + evaluate".' }
            elseif ($arpSame.Count -eq 0 -and $arpOlder.Count -gt 0) { Add-Verdict 'Fail' ('Detection is TRUE (' + $clauseText + '), so the client considers "' + $app.Name + '" ' + $app.SoftwareVersion + ' installed and will never retry - but Add/Remove Programs only lists an older ' + (& $arpList $arpOlder) + '. The rule is satisfied by the old version.') 'Change the detection so the older version does not satisfy it (the value the rule reads must change with the version the package installs), then "Policy + evaluate".' }
            elseif ($arpSame.Count -eq 0) { Add-Verdict 'Warn' ('Detection is true (' + $clauseText + '); Add/Remove Programs lists ' + (& $arpList $arpUnknown) + ' - a version that cannot be compared with ' + $app.SoftwareVersion + '.') 'Check by hand whether that is the version the deployment installs.' }
            else {
                $newer = @($arpSame | Where-Object { (& $verOf $_.DisplayVersion) -gt $appVer })
                if ($newer.Count -gt 0) { Add-Verdict 'OK' ('Detection is true; Add/Remove Programs has a newer version than the deployment carries (' + (& $arpList $arpSame) + ' vs ' + $app.SoftwareVersion + ') and the rule accepts it.') '' }
                else { Add-Verdict 'OK' ('Detection is true and Add/Remove Programs agrees (' + (& $arpList $arp) + ').') '' }
            }
        }
        elseif ($detFalse -and $isInstalled) {
            Add-Verdict 'Warn' ('The client''s last evaluation (' + $appInfo.LastEvalUtc + ' UTC) recorded Installed, but evaluated now the detection is false: ' + $clauseText + '. The device changed since (removed by hand, key or file gone), or the client has not looked again.') 'Run "Policy + evaluate": the client re-evaluates, and a required deployment then installs again on its own.'
        }
        elseif ($detFalse -and $wantInstalled) {
            $lastAttempt = $null; if ($main.Attempts.Count -gt 0) { $lastAttempt = $main.Attempts[-1] }
            $attemptIsCurrent = ($lastAttempt -and [int]$lastAttempt.Revision -eq [int]$main.Revision)
            $ct = $main.Content
            $contentText = ''
            # the execution queue and the maintenance windows, worded once for the verdicts below
            $req = @($required | Select-Object -First 1)
            $ignoresWindows = ($req.Count -gt 0 -and [bool]$req[0].OverrideServiceWindows)
            $maxMin = $(if ($main.Install) { [int]$main.Install.MaxExecuteTimeMin } else { 0 })
            $windowText = ''
            if ($windowInfo.Restricting.Count -gt 0) {
                if ($windowInfo.ActiveNow.Count -gt 0) { $windowText = ' A maintenance window is open right now (' + $windowInfo.ActiveNow[0].TypeName + ' until ' + $windowInfo.ActiveNow[0].EndLocal.Replace('T', ' ') + ' device time).' }
                elseif ($windowInfo.Next) {
                    $fits = ($maxMin -le 0 -or $windowInfo.Next.Minutes -ge $maxMin)
                    $windowText = ' Next maintenance window: ' + $windowInfo.Next.TypeName + ' ' + $windowInfo.Next.StartLocal.Replace('T', ' ') + ' - ' + $windowInfo.Next.EndLocal.Replace('T', ' ') + ' device time (' + $windowInfo.Next.Minutes + ' min' + $(if ($fits) { '' } else { ' - SHORTER than the deployment type''s maximum run time of ' + $maxMin + ' min, the client will never start it there' }) + ').' + $(if ($ignoresWindows) { ' This deployment is set to ignore maintenance windows.' } else { '' })
                }
            } else { $windowText = ' No maintenance window applies to this device.' }
            $queueText = ''
            $qOpen = @($queue | Where-Object { $_.State -notin 'Completed', 'Expired' })
            if ($qOpen.Count -gt 0) { $q0 = $qOpen[-1]; $queueText = ' Execution queue: state ' + $q0.State + $(if ($q0.RunningState) { '/' + $q0.RunningState } else { '' }) + ', received ' + $q0.ReceivedUtc + ' UTC' + $(if ($q0.NextRetryUtc) { ', next retry ' + $q0.NextRetryUtc + ' UTC' } else { '' }) + $(if ($q0.Reason) { ', reason ' + $q0.Reason } else { '' }) + '.' }
            if ($ct) { $contentText = ' Content ' + $ct.Id + ' v' + $ct.Version + $(if ($ct.InCache) { ' is in the cache (' + $ct.CacheFolder + ').' } else { ' is not in the cache.' }) + $(if ($ct.Signal) { ' Logs: ' + $ct.Signal + '.' } else { '' }) }
            # what the client is doing right now decides first; an old attempt explains nothing about a wait
            if ($es -in 5, 6, 7, 24, 25, 28 -or ($ct -and $ct.Signal -like 'no distribution point*')) {
                if ($ct -and $ct.Signal -like 'no distribution point*') { Add-Verdict 'Fail' ('The client asked for the content and got an empty distribution point list - no DP in the device''s boundary group has ' + $ct.Id + ' version ' + $ct.Version + '. The client waits and asks again on its own schedule; nothing installs until the content is there.' + $contentText) 'Distribute the content to a DP the device''s boundary group can reach (or check boundary group membership); then "Policy + evaluate".' }
                elseif ($ct -and $ct.Signal -like 'download error*') { Add-Verdict 'Fail' ('The content download fails: ' + $ct.Signal + '.' + $contentText) 'DataTransferService.log on the client names the URL and the HTTP status; 404 = content not on that DP, 401/403 = IIS or certificate, 0x80072EE2 = timeout.' }
                else { Add-Verdict 'Warn' ('The client is waiting for content (state ' + $es + ').' + $contentText) 'CAS.log, ContentTransferManager.log, LocationServices.log and DataTransferService.log on the client (excerpts below); distribution status of the content on the site.' }
            }
            elseif ($es -eq 8) { Add-Verdict 'Warn' ('The client is waiting for a maintenance window before it installs.' + $windowText + $queueText) 'Nothing to do but wait - or set the deployment to ignore maintenance windows.' }
            elseif ($es -eq 9) { Add-Verdict 'Warn' 'The client is waiting for a pending reboot before it installs.' 'Client tab: pending reboot and its sources.' }
            elseif ($es -in 17, 18, 19) { Add-Verdict 'Warn' ('The client is waiting for a user session condition (state ' + $es + ').') '' }
            elseif ($es -in 10, 11, 12, 27) { Add-Verdict 'Info' ('The client is busy with this application right now (state ' + $es + ').') 'Wait, then Troubleshoot again.' }
            elseif ($es -eq 20) { Add-Verdict 'Warn' 'The client is waiting to try again after a failure (state 20).' 'The last attempt below says what failed.' }
            elseif ($lastAttempt -and $null -ne $lastAttempt.ExitCode -and ($lastAttempt.ExitMeaning -eq 'Success' -or $lastAttempt.ExitCode -eq 0) -and $lastAttempt.PostDetection -eq 'not discovered') {
                $arpText = $(if ($arp.Count -gt 0) { 'Add/Remove Programs lists ' + (($arp | ForEach-Object { $_.DisplayName + ' ' + $_.DisplayVersion + $(if ($_.WindowsInstaller) { ' (MSI)' } else { ' (non-MSI)' }) }) -join ', ') + '.' } else { 'Add/Remove Programs has no matching entry at all.' })
                $revNote = $(if (-not $attemptIsCurrent) { ' (that attempt ran revision ' + $lastAttempt.Revision + '; the client now holds revision ' + $main.Revision + ', not tried yet' + $(if ($windowInfo.Restricting.Count -gt 0 -and $windowInfo.ActiveNow.Count -eq 0 -and -not $ignoresWindows) { ' -' + $windowText } else { '' }) + ')' } else { '' })
                Add-Verdict 'Fail' ('The installer ran with exit ' + $lastAttempt.ExitCode + ' (' + $lastAttempt.Seconds + ' s, ' + $lastAttempt.StartUtc + ' UTC) and the detection afterwards found nothing - that is 0x87D00324' + $revNote + '. Evaluated now: ' + $clauseText + '. ' + $arpText) 'The package installs something the rule does not look for (other installer kind, other product code, other path or version). Align the detection with what the installer really writes; the PSADT log of that run shows what it did.'
            }
            elseif ($lastAttempt -and $null -ne $lastAttempt.ExitCode -and $lastAttempt.ExitMeaning -ne 'Success' -and $lastAttempt.ExitCode -ne 0) {
                $revNote = $(if (-not $attemptIsCurrent) { ' That attempt ran revision ' + $lastAttempt.Revision + '; the client now holds revision ' + $main.Revision + ' and has not tried it yet.' + $(if ($windowInfo.Restricting.Count -gt 0 -and $windowInfo.ActiveNow.Count -eq 0 -and -not $ignoresWindows) { $windowText } else { '' }) } else { '' })
                Add-Verdict 'Fail' ('The last install attempt (' + $lastAttempt.StartUtc + ' UTC, rev ' + $lastAttempt.Revision + ') ended with exit code ' + $lastAttempt.ExitCode + ' (' + $lastAttempt.ExitMeaning + ') after ' + $lastAttempt.Seconds + ' s. Detection is false, so the client will try again at the next application deployment evaluation.' + $revNote) ('Read the installer''s own log for that time (PSADT: Logs tab, List files on the PSADT folder). Exit codes the package treats as success must be in the deployment type''s success list (' + $(if ($main.Install) { $main.Install.SuccessExitCodes } else { '?' }) + ').')
            }
            elseif ($main.AttemptsTotal -eq 0) {
                $why = 'No enforcement attempt for this deployment type appears in AppEnforce.log for the last ' + $Days + ' days.'
                if ($required.Count -eq 0) { Add-Verdict 'Warn' ($why + ' The deployment is Available only - nobody has clicked Install in Software Center.') '' }
                else {
                    $dl = ''; if ($required.Count -gt 0) { $dl = $required[0].DeadlineUtc }
                    if ($dl -and ([datetime]$dl) -gt (Get-Date).ToUniversalTime()) { Add-Verdict 'OK' ($why + ' The deadline is ' + $dl + ' UTC, still ahead - nothing is due yet.') '' }
                    elseif ($windowInfo.Restricting.Count -gt 0 -and $windowInfo.ActiveNow.Count -eq 0 -and -not $ignoresWindows) { Add-Verdict 'Warn' ('The deployment is due, the client is ready (state ' + $es + ', last evaluation of this app ' + $appInfo.LastEvalUtc + ' UTC) and waits for a maintenance window.' + $windowText + $queueText + $contentText) 'Nothing to do but wait; Refresh will not change anything before the window opens. To install now: set the deployment to ignore maintenance windows, or use Install in this window (it runs through the client as a user-initiated install).' }
                    else { Add-Verdict 'Warn' ($why + ' The deadline has passed. Last scheduled application deployment evaluation: ' + $cycle.AppDeploymentEvalLastUtc + ' UTC; last evaluation of this app: ' + $appInfo.LastEvalUtc + ' UTC; state ' + $es + '.' + $windowText + $queueText + $contentText) 'Trigger "Policy + evaluate" and watch AppIntentEval.log / AppEnforce.log; if nothing starts, ServiceWindowManager.log is next.' }
                }
            }
            else { Add-Verdict 'Warn' ('Detection is false and the last enforcement block (' + $lastAttempt.StartUtc + ' UTC) has no exit code - the run may still be in progress or was cut off.') 'AppEnforce.log around that time.' }
        }
        elseif ($detFalse -and -not $wantInstalled -and $app.ApplicabilityState -eq 'Applicable' -and $app.SupersessionState -ne 'Superseded') { Add-Verdict 'OK' 'Detection is false and the deployment does not want the app installed (uninstall or not targeted) - consistent.' '' }
        elseif ($detTrue -and -not $wantInstalled -and $isInstalled) {
            if ($app.ResolvedState -eq 'Uninstalled') { Add-Verdict 'Warn' 'The deployment wants the app removed, and the detection still finds it.' 'Uninstall attempts are in AppEnforce.log; the uninstall command of the deployment type must actually remove what the detection looks for.' }
        }
    } elseif ($main) { Add-Verdict 'Warn' ('No detection method could be read for "' + $main.Name + '" rev ' + $main.Revision + ' on the client.') '' }

    # the retry question, answered in one line
    if ($required.Count -gt 0 -and $wantInstalled -and -not $isInstalled) {
        $retry = 'Required deployments are re-attempted when the application deployment evaluation cycle runs (last on this device: ' + $cycle.AppDeploymentEvalLastUtc + ' UTC; its schedule is under Evaluation cycle below), when new policy arrives, or when someone triggers the evaluation. Between cycles a failed app stays failed.'
        Add-Verdict 'Info' $retry ''
    }
}

# --- Envelope ------------------------------------------------------------------------------

function New-Envelope {
    param([object[]]$DtList, [string[]]$Truncated)
    $payload = [pscustomobject]@{
        App         = [pscustomobject]$appInfo
        Assignments = [object[]]$assignments.ToArray()
        DeploymentTypes = [object[]]$DtList
        AppIntent   = [string[]]$appIntent
        Cycle       = [pscustomobject]$cycle
        Windows     = [pscustomobject]$windowInfo
        Queue       = [object[]]$queue.ToArray()
        Arp         = [object[]]$arp.ToArray()
        Verdicts    = [object[]]$verdicts.ToArray()
        Logs        = [string[]]@('AppDiscovery.log', 'AppEnforce.log', 'AppIntentEval.log', 'PolicyAgent.log', 'CAS.log', 'ServiceWindowManager.log')
        Days        = $Days
    }
    $json = $payload | ConvertTo-Json -Depth 8 -Compress
    $envelope = [pscustomobject]@{
        Schema    = $SchemaVersion
        Kind      = 'Troubleshoot'
        Host      = $env:COMPUTERNAME
        TimeUtc   = (Get-Date).ToUniversalTime().ToString('s')
        Count     = $verdicts.Count
        Total     = $dts.Count
        Truncated = ($Truncated.Count -gt 0)
        TruncatedSections = [string[]]$Truncated
        Error     = ($errors -join ' | ')
        Enc       = 'gzip+base64'
        Data      = (ConvertTo-CompressedBase64 -Text $json)
    }
    return ($envelope | ConvertTo-Json -Depth 3 -Compress)
}

$dtOut = $dts.ToArray()
$trunc = New-Object System.Collections.Generic.List[string]
$out = New-Envelope -DtList $dtOut -Truncated @()
$shrink = 1
while ($out.Length -gt $MaxOutputChars -and $shrink -lt 6) {
    $keep = [int][math]::Max(3, $MaxLines / [math]::Pow(2, $shrink))
    $dtOut = @($dtOut | ForEach-Object { $c = $_ | Select-Object *; $c.DiscoveryHistory = @($c.DiscoveryHistory | Select-Object -Last $keep); $c.IntentHistory = @($c.IntentHistory | Select-Object -Last $keep); $c.Attempts = @($c.Attempts | Select-Object -Last $keep); if ($c.Content) { $cc = $c.Content | Select-Object *; foreach ($k in "Cas", "Ctm", "Ls", "Dts") { $cc.$k = @($cc.$k | Select-Object -Last $keep) }; $c.Content = $cc }; $c })
    if ($trunc -notcontains 'History') { $trunc.Add('History') }
    $out = New-Envelope -DtList $dtOut -Truncated $trunc.ToArray()
    $shrink++
}

$summary = ($verdicts | ForEach-Object { $_.Level + ': ' + $_.Text.Substring(0, [Math]::Min(160, $_.Text.Length)) }) -join ' || '
Write-TKLog -Message ('CMApp-Troubleshoot for {0}: {1} DTs, {2} verdicts, envelope {3} chars, errors=''{4}'' - {5}' -f $AppId, $dts.Count, $verdicts.Count, $out.Length, ($errors -join ' | '), $summary) -Component 'CMApp-Troubleshoot'
Write-Output $out
exit 0
