<#
.SYNOPSIS
    AZITC Toolkit - tail of a log file on the local client.

.DESCRIPTION
    Designed to run as a Configuration Manager "Run Script" (SYSTEM context, Windows PowerShell 5.1).
    Read-only. Only files below these folders are served, anything else is refused:
      %windir%\CCM\Logs                (client logs)
      %ProgramData%\AZITC\Toolkit\Logs (logs written by AZITC-TK-Software-Action)
    ConfigMgr log lines (<![LOG[...]LOG]!><time=... date=... component=...>) are reduced to
    "time  component  message"; other files are returned as they are.

    Emits ONE JSON envelope, payload gzip+base64 (Enc = 'gzip+base64'), Kind = 'Log':
      Lines[]   the last <Lines> lines, oldest first
      Path      the file that was read
      Matched   number of lines after the pattern filter
    The envelope is kept under the Run Scripts output limit; if the tail does not fit, lines
    are dropped from the start and Truncated is set.

    Recommended script timeout in the console: 120 seconds.

.PARAMETER LogName
    File name (AppEnforce.log) or a path below one of the served folders. A name without a
    folder is looked up in %windir%\CCM\Logs first, then in the toolkit log folder.

.PARAMETER Lines
    How many lines from the end (1..500, default 100).

.PARAMETER Pattern
    Optional regular expression; only matching lines count towards <Lines>.

.NOTES
    Author : Alexander Zarenko IT Consulting (AZITC)
    Schema : 1
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$LogName,

    [int]$Lines = 100,

    [string]$Pattern = ''
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
$MaxOutputChars = 70000

# The client's log folder is wherever the client says it is - %windir%\CCM\Logs on a
# workstation, <site server install>\SMS_CCM\Logs on a site system.
$ccmLogs = Join-Path -Path $env:windir -ChildPath 'CCM\Logs'
try {
    $cfg = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\CCM\Logging\@Global' -ErrorAction Stop
    if ($cfg.LogDirectory) { $ccmLogs = [string]$cfg.LogDirectory }
} catch { }
$roots = @(
    $ccmLogs,
    (Join-Path -Path $env:ProgramData -ChildPath 'AZITC\Toolkit\Logs'),
    (Join-Path -Path $env:windir -ChildPath 'Logs\Software')      # PSAppDeployToolkit
)

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

function New-Envelope {
    param([string[]]$LineList, [string]$Path, [int]$Matched, [bool]$Truncated, [string]$Error)
    $payload = [pscustomobject]@{
        Path    = $Path
        Matched = $Matched
        Lines   = [string[]]$LineList
    }
    $json = $payload | ConvertTo-Json -Depth 3 -Compress
    $envelope = [pscustomobject]@{
        Schema    = $SchemaVersion
        Kind      = 'Log'
        Host      = $env:COMPUTERNAME
        TimeUtc   = (Get-Date).ToUniversalTime().ToString('s')
        Count     = @($LineList).Count
        Total     = $Matched
        Truncated = $Truncated
        Error     = $Error
        Enc       = 'gzip+base64'
        Data      = (ConvertTo-CompressedBase64 -Text $json)
    }
    return ($envelope | ConvertTo-Json -Depth 3 -Compress)
}

function Complete-Script {
    param([string]$Json, [int]$Code)
    Write-Output $Json
    exit $Code
}

# --- Resolve the file, inside the served folders only ----------------------

if ($Lines -lt 1) { $Lines = 1 }
if ($Lines -gt 500) { $Lines = 500 }

$candidates = @()
if ([System.IO.Path]::IsPathRooted($LogName)) {
    $candidates += $LogName
} else {
    foreach ($root in $roots) { $candidates += (Join-Path -Path $root -ChildPath $LogName) }
}

function Test-Allowed {
    param([string]$FullPath)
    foreach ($root in $roots) {
        $r = [System.IO.Path]::GetFullPath($root).TrimEnd('\') + '\'
        if ($FullPath.StartsWith($r, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

$file = $null
foreach ($c in $candidates) {
    if ($c.IndexOfAny([char[]]@('*', '?')) -ge 0) {
        # Wildcard: the newest file that matches, still inside the served folder. .NET
        # Framework's GetFullPath refuses wildcard characters, so only the folder is normalised.
        $dir = $null
        try { $dir = [System.IO.Path]::GetFullPath((Split-Path -Path $c -Parent)) } catch { continue }
        $fileMask = Split-Path -Path $c -Leaf
        if ($fileMask.IndexOfAny([char[]]@('\', '/')) -ge 0) { continue }
        if (-not (Test-Allowed -FullPath ($dir.TrimEnd('\') + '\'))) { continue }
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
        $newest = Get-ChildItem -LiteralPath $dir -Filter $fileMask -File -ErrorAction SilentlyContinue |
            Where-Object { Test-Allowed -FullPath $_.FullName } |
            Sort-Object -Property LastWriteTime -Descending | Select-Object -First 1
        if ($newest) { $file = $newest.FullName; break }
        continue
    }
    $full = $null
    try { $full = [System.IO.Path]::GetFullPath($c) } catch { continue }
    if (-not (Test-Allowed -FullPath $full)) { continue }
    if (Test-Path -LiteralPath $full -PathType Leaf) { $file = $full; break }
}

if (-not $file) {
    Complete-Script -Json (New-Envelope -LineList @() -Path '' -Matched 0 -Truncated $false -Error "Log '$LogName' not found below the served folders ($($roots -join '; ')).") -Code 2
}

# --- Read and reduce -------------------------------------------------------

$text = ''
try {
    # Shared read: CM logs are open for writing all the time.
    $fs = New-Object System.IO.FileStream($file, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8, $true)
    $text = $sr.ReadToEnd()
    $sr.Close(); $fs.Close()
} catch {
    Complete-Script -Json (New-Envelope -LineList @() -Path $file -Matched 0 -Truncated $false -Error "Cannot read '$file': $($_.Exception.Message)") -Code 1
}

$reduced = New-Object System.Collections.Generic.List[string]
# A ConfigMgr entry can span several lines (the message carries its own line breaks), so the
# file is parsed as one text, entry by entry, not line by line.
$cmEntry = [regex]'(?s)<!\[LOG\[(?<msg>.*?)\]LOG\]!><time="(?<time>[^"]*)"\s+date="(?<date>[^"]*)"\s+component="(?<comp>[^"]*)"[^>]*>'
$entries = $cmEntry.Matches($text)
if ($entries.Count -gt 0) {
    foreach ($m in $entries) {
        $t = $m.Groups['time'].Value
        if ($t.Length -gt 12) { $t = $t.Substring(0, 12) }   # 18:30:53.573 without the offset
        $msg = ($m.Groups['msg'].Value -replace "\s*`r?`n\s*", ' | ').Trim()
        $reduced.Add(('{0} {1}  {2}  {3}' -f $m.Groups['date'].Value, $t, $m.Groups['comp'].Value, $msg))
    }
} else {
    foreach ($line in ($text -split "`r?`n")) {
        if (-not [string]::IsNullOrWhiteSpace($line)) { $reduced.Add($line) }
    }
}

$filtered = $reduced
if ($Pattern) {
    $rx = $null
    try { $rx = New-Object System.Text.RegularExpressions.Regex($Pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase) }
    catch { Complete-Script -Json (New-Envelope -LineList @() -Path $file -Matched 0 -Truncated $false -Error "Pattern is not a valid regular expression: $($_.Exception.Message)") -Code 2 }
    $filtered = New-Object System.Collections.Generic.List[string]
    foreach ($l in $reduced) { if ($rx.IsMatch($l)) { $filtered.Add($l) } }
}
$matched = $filtered.Count

$start = $matched - $Lines
if ($start -lt 0) { $start = 0 }
$tail = [string[]]@($filtered.GetRange($start, $matched - $start).ToArray())

# --- Fit into the output limit ---------------------------------------------

$truncated = $false
$out = New-Envelope -LineList $tail -Path $file -Matched $matched -Truncated $truncated -Error ''
while ($out.Length -gt $MaxOutputChars -and $tail.Count -gt 5) {
    $truncated = $true
    $keep = [int][math]::Floor($tail.Count * 0.75)
    $tail = [string[]]@($tail | Select-Object -Last $keep)
    $out = New-Envelope -LineList $tail -Path $file -Matched $matched -Truncated $truncated -Error ''
}

Write-TKLog -Message ('Log-Get: {0} - {1} of {2} lines, pattern=''{3}'', envelope {4} chars' -f $file, $tail.Count, $matched, $Pattern, $out.Length) -Component 'Log-Get'
Complete-Script -Json $out -Code 0
