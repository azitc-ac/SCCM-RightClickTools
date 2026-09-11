<#
.SYNOPSIS
    AZITC Toolkit - enumerate installed software (Add/Remove Programs) on the local client.

.DESCRIPTION
    Designed to run as a Configuration Manager "Run Script" (SYSTEM context, Windows PowerShell 5.1).

    - Enumerates HKLM (64-bit and 32-bit) and all loaded HKEY_USERS hives.
    - Filters system components, update/hotfix entries and nameless keys.
    - Sends a slim record per entry (details are re-read on the client by the Action script).
    - Adds the ConfigMgr application list (root\ccm\ClientSDK) so the GUI can show deployment state.
    - Emits ONE JSON envelope; the payload is gzip + base64 to stay well below the
      Run Scripts output limit (~80 KB). If the payload is still too large the entry list is
      truncated and the envelope says so.

    Recommended script timeout in the console: 300 seconds.
    No parameters.

.NOTES
    Author : Alexander Zarenko IT Consulting (AZITC)
    Schema : 1
#>

$ErrorActionPreference = 'Stop'
$SchemaVersion = 1
$MaxOutputChars = 70000   # safety margin below the Run Scripts output limit

# --- Helpers ----------------------------------------------------------------

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

function Get-ArpEntries {
    param(
        [Parameter(Mandatory = $true)][string]$RootPath,   # e.g. Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall
        [Parameter(Mandatory = $true)][string]$Scope,      # Machine | User:<SID>
        [Parameter(Mandatory = $true)][string]$Arch        # x64 | x86 | n/a
    )
    $list = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path -Path $RootPath)) { return $list }

    foreach ($key in (Get-ChildItem -Path $RootPath -ErrorAction SilentlyContinue)) {
        $p = $null
        try { $p = Get-ItemProperty -Path $key.PSPath -ErrorAction Stop } catch { continue }

        if ([string]::IsNullOrWhiteSpace([string]$p.DisplayName)) { continue }
        if ($p.SystemComponent -eq 1) { continue }
        if (-not [string]::IsNullOrWhiteSpace([string]$p.ParentKeyName)) { continue }   # update child entries
        if ([string]$p.ReleaseType -match 'Update|Hotfix') { continue }

        $isMsi = ($p.WindowsInstaller -eq 1) -or ($key.PSChildName -match '^\{[0-9A-Fa-f\-]{36}\}$')
        $sizeKb = 0
        if ($p.EstimatedSize) { try { $sizeKb = [int]$p.EstimatedSize } catch { $sizeKb = 0 } }

        # Key path without the PowerShell provider prefix -> "HKEY_LOCAL_MACHINE\SOFTWARE\..."
        $keyPath = $key.PSPath -replace '^Microsoft\.PowerShell\.Core\\Registry::', ''

        $list.Add([pscustomobject]@{
            K = $keyPath                                    # registry key (identifier for the Action script)
            N = [string]$p.DisplayName
            V = [string]$p.DisplayVersion
            P = [string]$p.Publisher
            D = [string]$p.InstallDate                      # yyyyMMdd or empty
            S = $Scope
            A = $Arch
            M = [bool]$isMsi                                # Windows Installer based
            Q = (-not [string]::IsNullOrWhiteSpace([string]$p.QuietUninstallString))
            U = (-not [string]::IsNullOrWhiteSpace([string]$p.UninstallString))
            R = (($p.NoRepair -ne 1) -and ($p.NoModify -ne 1))
            Z = $sizeKb                                     # EstimatedSize in KB
        })
    }
    # A plain array, unrolled by the pipeline and collected by the caller's @(). Returning
    # the List itself (",$list") made AddRange append the whole list as one element under 5.1.
    return $list.ToArray()
}

function Resolve-SidName {
    param([string]$Sid)
    try {
        $s = New-Object System.Security.Principal.SecurityIdentifier($Sid)
        return $s.Translate([System.Security.Principal.NTAccount]).Value
    } catch { return '' }
}

# --- ARP enumeration --------------------------------------------------------

$entries = New-Object System.Collections.Generic.List[object]
$entries.AddRange([object[]]@(Get-ArpEntries -RootPath 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' -Scope 'Machine' -Arch 'x64'))
$entries.AddRange([object[]]@(Get-ArpEntries -RootPath 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall' -Scope 'Machine' -Arch 'x86'))

$userHives = @{}
foreach ($hive in (Get-ChildItem -Path 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue)) {
    $sid = $hive.PSChildName
    if ($sid -notmatch '^S-1-5-21-') { continue }
    if ($sid -like '*_Classes') { continue }
    $userHives[$sid] = Resolve-SidName -Sid $sid
    $entries.AddRange([object[]]@(Get-ArpEntries -RootPath "Registry::HKEY_USERS\$sid\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall" -Scope "User:$sid" -Arch 'n/a'))
}

$sorted = $entries | Sort-Object -Property N, V

# --- ConfigMgr application state (best effort) ------------------------------

$apps = New-Object System.Collections.Generic.List[object]
$appError = ''
try {
    # Second Get-CimInstance call materialises lazy properties of CCM_Application.
    $ccmApps = Get-CimInstance -Namespace 'root\ccm\ClientSDK' -ClassName 'CCM_Application' -ErrorAction Stop | Get-CimInstance -ErrorAction Stop
    foreach ($a in $ccmApps) {
        $deadline = ''
        if ($a.Deadline) { $deadline = ([datetime]$a.Deadline).ToUniversalTime().ToString('s') }
        $apps.Add([pscustomobject]@{
            Id  = [string]$a.Id
            Rev = [string]$a.Revision
            N   = [string]$a.Name
            FN  = [string]$a.FullName
            SV  = [string]$a.SoftwareVersion
            Pub = [string]$a.Publisher
            IS  = [string]$a.InstallState          # Installed, NotInstalled, Unknown, ...
            RS  = [string]$a.ResolvedState         # Installed, Available, ...
            ES  = [int]$a.EvaluationState
            MT  = [bool]$a.IsMachineTarget
            AA  = @($a.AllowedActions)             # Install, Uninstall, Repair
            DL  = $deadline                        # non-empty => required deployment
            EP  = [int]$a.EnforcePreference
        })
    }
} catch {
    $appError = $_.Exception.Message
}

# --- Envelope ---------------------------------------------------------------

function New-Envelope {
    param([object[]]$Items, [bool]$Truncated)
    # Windows PowerShell 5.1 refuses a generic List inside [pscustomobject]@{...}
    # ("Argument types do not match"), so both lists become plain arrays first.
    $payload = [pscustomobject]@{
        Items = [object[]]$Items
        Apps  = [object[]]$apps.ToArray()
        Users = $userHives
    }
    $json = $payload | ConvertTo-Json -Depth 5 -Compress
    $envelope = [pscustomobject]@{
        Schema    = $SchemaVersion
        Kind      = 'Software'
        Host      = $env:COMPUTERNAME
        TimeUtc   = (Get-Date).ToUniversalTime().ToString('s')
        Count     = @($Items).Count
        Total     = @($sorted).Count
        AppCount  = $apps.Count
        AppError  = $appError
        Truncated = $Truncated
        Enc       = 'gzip+base64'
        Data      = (ConvertTo-CompressedBase64 -Text $json)
    }
    return ($envelope | ConvertTo-Json -Depth 3 -Compress)
}

$items = @($sorted)
$truncated = $false
$out = New-Envelope -Items $items -Truncated $truncated
while ($out.Length -gt $MaxOutputChars -and $items.Count -gt 10) {
    $truncated = $true
    $keep = [int][math]::Floor($items.Count * 0.75)
    $items = @($items | Select-Object -First $keep)
    $out = New-Envelope -Items $items -Truncated $truncated
}

Write-Output $out
exit 0
