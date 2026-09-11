<#
.SYNOPSIS
    AZITC Toolkit - act on a service, a process or the ConfigMgr cache of the local client.

.DESCRIPTION
    Designed to run as a Configuration Manager "Run Script" (SYSTEM context, Windows PowerShell 5.1).
    One action per run, ONE JSON object back. Exit code 0 = done, 1 = tried and failed,
    2 = nothing done (bad target, refused).

      Target Service   Action Start | Stop | Restart      Name = service name (not the display name)
      Target Process   Action Kill                        Name = process id, or a process name (all
                                                          processes of that name, image name with .exe)
      Target Cache     Action Delete                      Name = CacheId of one item (from Client-Get)
                       Action Clear                       Name = '' - every item that is not persisted
                                                          and not in use (ReferenceCount 0)

    Refused on purpose: stopping or killing the ConfigMgr client itself (CcmExec / ccmexec.exe)
    and the script host that runs this script - the script would kill its own reporting.

    Recommended script timeout in the console: 300 seconds.

.NOTES
    Author : Alexander Zarenko IT Consulting (AZITC)
    Schema : 1
#>

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Service', 'Process', 'Cache')]
    [string]$Target,

    [Parameter(Mandatory = $true)]
    [ValidateSet('Start', 'Stop', 'Restart', 'Kill', 'Delete', 'Clear')]
    [string]$Action,

    [string]$Name = ''
)

$ErrorActionPreference = 'Stop'
$SchemaVersion = 1

$result = [ordered]@{
    Schema   = $SchemaVersion
    Kind     = 'ClientManage'
    Host     = $env:COMPUTERNAME
    TimeUtc  = (Get-Date).ToUniversalTime().ToString('s')
    Target   = $Target
    Action   = $Action
    Name     = $Name
    Before   = ''
    After    = ''
    Done     = @()
    Skipped  = @()
    Error    = ''
}

function Complete-Script {
    param([int]$Code)
    $result | ConvertTo-Json -Depth 4 -Compress | Write-Output
    exit $Code
}

$protectedServices = @('CcmExec', 'smstsmgr')
$protectedProcesses = @('ccmexec.exe', 'wmiprvse.exe', 'svchost.exe', 'lsass.exe', 'csrss.exe', 'wininit.exe', 'winlogon.exe', 'services.exe', 'smss.exe', 'system')

switch ($Target) {

    'Service' {
        if ($Action -notin @('Start', 'Stop', 'Restart')) { $result.Error = "Action '$Action' does not apply to a service."; Complete-Script -Code 2 }
        if (-not $Name) { $result.Error = 'Name (the service name) is required.'; Complete-Script -Code 2 }
        if ($protectedServices -contains $Name -and $Action -ne 'Start') { $result.Error = "Service '$Name' is protected - it is the ConfigMgr client."; Complete-Script -Code 2 }
        $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
        if (-not $svc) { $result.Error = "Service '$Name' not found."; Complete-Script -Code 2 }
        $result.Before = [string]$svc.Status
        try {
            switch ($Action) {
                'Start'   { if ($svc.Status -ne 'Running') { Start-Service -Name $Name -ErrorAction Stop } }
                'Stop'    { if ($svc.Status -ne 'Stopped') { Stop-Service -Name $Name -Force -ErrorAction Stop } }
                'Restart' { Restart-Service -Name $Name -Force -ErrorAction Stop }
            }
            $wait = 'Running'; if ($Action -eq 'Stop') { $wait = 'Stopped' }
            try { (Get-Service -Name $Name).WaitForStatus($wait, [TimeSpan]::FromSeconds(60)) } catch { }
        } catch {
            $result.Error = "$Action failed: $($_.Exception.Message)"
            $result.After = [string](Get-Service -Name $Name).Status
            Complete-Script -Code 1
        }
        $result.After = [string](Get-Service -Name $Name).Status
        $result.Done = @("$Name $($result.Before) -> $($result.After)")
        if (($Action -eq 'Stop' -and $result.After -ne 'Stopped') -or ($Action -ne 'Stop' -and $result.After -ne 'Running')) { $result.Error = "Service is '$($result.After)' after $Action."; Complete-Script -Code 1 }
        Complete-Script -Code 0
    }

    'Process' {
        if ($Action -ne 'Kill') { $result.Error = "Action '$Action' does not apply to a process."; Complete-Script -Code 2 }
        if (-not $Name) { $result.Error = 'Name (process id or image name) is required.'; Complete-Script -Code 2 }
        $procs = @()
        $id = 0
        if ([int]::TryParse($Name, [ref]$id)) { $procs = @(Get-Process -Id $id -ErrorAction SilentlyContinue) }
        else { $procs = @(Get-Process -Name ($Name -replace '\.exe$', '') -ErrorAction SilentlyContinue) }
        if ($procs.Count -eq 0) { $result.Error = "No process matches '$Name'."; Complete-Script -Code 2 }
        $result.Before = (($procs | ForEach-Object { "$($_.ProcessName) ($($_.Id))" }) -join ', ')
        $done = @(); $skipped = @(); $failed = @()
        foreach ($p in $procs) {
            $image = ($p.ProcessName + '.exe').ToLower()
            if ($protectedProcesses -contains $image -or $p.Id -eq $PID -or $p.Id -eq 0 -or $p.Id -eq 4) { $skipped += "$($p.ProcessName) ($($p.Id)): protected"; continue }
            try { Stop-Process -Id $p.Id -Force -ErrorAction Stop; $done += "$($p.ProcessName) ($($p.Id))" }
            catch { $failed += "$($p.ProcessName) ($($p.Id)): $($_.Exception.Message)" }
        }
        Start-Sleep -Seconds 1
        $left = @()
        foreach ($p in $procs) { if (Get-Process -Id $p.Id -ErrorAction SilentlyContinue) { $left += "$($p.ProcessName) ($($p.Id))" } }
        $result.After = ($left -join ', ')
        $result.Done = $done; $result.Skipped = $skipped
        if ($failed.Count -gt 0) { $result.Error = ($failed -join '; '); Complete-Script -Code 1 }
        if ($done.Count -eq 0) { $result.Error = 'Nothing was terminated (all matches are protected).'; Complete-Script -Code 2 }
        Complete-Script -Code 0
    }

    'Cache' {
        if ($Action -notin @('Delete', 'Clear')) { $result.Error = "Action '$Action' does not apply to the cache."; Complete-Script -Code 2 }
        $items = @()
        try { $items = @(Get-CimInstance -Namespace 'root\ccm\SoftMgmtAgent' -ClassName 'CacheInfoEx' -ErrorAction Stop) } catch { $result.Error = "CacheInfoEx: $($_.Exception.Message)"; Complete-Script -Code 2 }
        $result.Before = "$($items.Count) items, $([math]::Round((($items | Measure-Object -Property ContentSize -Sum).Sum) / 1024, 1)) MB"
        $targets = @()
        if ($Action -eq 'Delete') {
            if (-not $Name) { $result.Error = 'Name (the CacheId) is required for Delete.'; Complete-Script -Code 2 }
            $targets = @($items | Where-Object { [string]$_.CacheId -eq $Name })
            if ($targets.Count -eq 0) { $result.Error = "No cache item with CacheId '$Name'."; Complete-Script -Code 2 }
        } else {
            $targets = @($items | Where-Object { -not [bool]$_.PersistInCache -and [int]$_.ReferenceCount -eq 0 })
            $result.Skipped = @($items | Where-Object { [bool]$_.PersistInCache -or [int]$_.ReferenceCount -gt 0 } | ForEach-Object { "$($_.ContentId) v$($_.ContentVer): " + $(if ([bool]$_.PersistInCache) { 'persisted' } else { "in use ($($_.ReferenceCount))" }) })
        }
        $done = @(); $failed = @()
        foreach ($t in $targets) {
            try {
                # Deleting the instance is what the client's own cache UI does; the client removes
                # the folder with it.
                Remove-CimInstance -InputObject $t -ErrorAction Stop
                if ($t.Location -and (Test-Path -LiteralPath $t.Location)) { Remove-Item -LiteralPath $t.Location -Recurse -Force -ErrorAction SilentlyContinue }
                $done += "$($t.ContentId) v$($t.ContentVer) ($([math]::Round([double]$t.ContentSize / 1024, 1)) MB)"
            } catch { $failed += "$($t.ContentId): $($_.Exception.Message)" }
        }
        $after = @()
        try { $after = @(Get-CimInstance -Namespace 'root\ccm\SoftMgmtAgent' -ClassName 'CacheInfoEx' -ErrorAction Stop) } catch { }
        $result.After = "$($after.Count) items, $([math]::Round((($after | Measure-Object -Property ContentSize -Sum).Sum) / 1024, 1)) MB"
        $result.Done = $done
        if ($failed.Count -gt 0) { $result.Error = ($failed -join '; '); Complete-Script -Code 1 }
        Complete-Script -Code 0
    }
}
