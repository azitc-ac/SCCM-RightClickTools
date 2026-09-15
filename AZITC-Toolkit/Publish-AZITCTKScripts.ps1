<#
.SYNOPSIS
    Puts the AZITC Toolkit Run Scripts into a site's Scripts node - create, update, approve.

.DESCRIPTION
    Run on any machine that reaches the AdminService of the SMS Provider, as a ConfigMgr
    administrator with the "Run Script" / script author rights (Full Administrator does).
    For every script the toolkit ships:
      - not in the site            -> created through SMS_Scripts.CreateScripts with its
                                      parameter definition, version 1
      - in the site, same hash     -> left alone
      - in the site, other hash    -> updated through UpdateScript, version + 1
      - parameter set changed      -> deleted and created anew (a new GUID; the window looks
                                      scripts up by name, so nothing else changes)
    then approved (ApprovalState 3), unless -NoApprove or the hierarchy demands a second
    approver - in that case the script says so and a second administrator approves in the
    console (Software Library > Scripts > Approve/Deny).

    -WhatIf shows what would happen without touching the site.

.PARAMETER SmsProvider
    FQDN of the SMS Provider. Empty: taken from this machine - the console's connection history
    or, on the site server, its own identity - the first one that answers.
.PARAMETER SkipCertificateCheck
    Accept a self-signed AdminService certificate.
.PARAMETER NoApprove
    Create/update only.

.EXAMPLE
    .\Publish-AZITCTKScripts.ps1 -WhatIf                                   # provider from the console's history
    .\Publish-AZITCTKScripts.ps1 -SmsProvider cm01.customer.example -WhatIf
    .\Publish-AZITCTKScripts.ps1 -SmsProvider cm01.customer.example -SkipCertificateCheck

.NOTES
    Author : Alexander Zarenko IT Consulting (AZITC)
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$SmsProvider = '',
    [switch]$SkipCertificateCheck,
    [switch]$NoApprove
)

$ErrorActionPreference = 'Stop'
. (Join-Path -Path $PSScriptRoot -ChildPath 'AZITC-TK-AdminService.ps1')
# Loaded here on purpose: with -WhatIf the automatic module load would print "Set Alias" noise.
& { $WhatIfPreference = $false; Import-Module CimCmdlets -ErrorAction SilentlyContinue }

# The catalogue: file, timeout, description, parameters. Order and names match the scripts'
# param() blocks; a change here means a change there.
$catalogue = @(
    @{ Name = 'AZITC-TK-Software-Get'; Timeout = 300
       Description = 'AZITC Toolkit - installed software (ARP) and CCM_Application list; gzip+base64 JSON envelope.'
       Parameters = @() },
    @{ Name = 'AZITC-TK-Software-Action'; Timeout = 1800
       Description = 'AZITC Toolkit - inspect, uninstall or repair one ARP entry (MSI / QuietUninstallString / Inno / NSIS / ExtraArgs); JSON result.'
       Parameters = @(
           @{ Name = 'Action';      Type = 'System.String'; Required = $true;  Default = '';   Values = @('Inspect', 'Uninstall', 'Repair', 'RemoveEntry') },
           @{ Name = 'Key';         Type = 'System.String'; Required = $true;  Default = '' },
           @{ Name = 'ExtraArgs';   Type = 'System.String'; Required = $false; Default = '' },
           @{ Name = 'TimeoutMin';  Type = 'System.Int32';  Required = $false; Default = '15' },
           @{ Name = 'KillRunning'; Type = 'System.Int32';  Required = $false; Default = '0' },
           @{ Name = 'ReEvaluate';  Type = 'System.Int32';  Required = $false; Default = '0' }) },
    @{ Name = 'AZITC-TK-Log-Get'; Timeout = 120
       Description = 'AZITC Toolkit - tail of a client log (Mode Tail) or the files of a log folder (Mode List); gzip+base64 JSON envelope.'
       Parameters = @(
           @{ Name = 'LogName'; Type = 'System.String'; Required = $true;  Default = '' },
           @{ Name = 'Lines';   Type = 'System.Int32';  Required = $false; Default = '100' },
           @{ Name = 'Pattern'; Type = 'System.String'; Required = $false; Default = '' },
           @{ Name = 'Mode';    Type = 'System.String'; Required = $false; Default = 'Tail'; Values = @('Tail', 'List') }) },
    @{ Name = 'AZITC-TK-Client-Action'; Timeout = 120
       Description = 'AZITC Toolkit - trigger a client schedule (machine policy, app deployment evaluation, inventories, update scan); JSON result.'
       Parameters = @(
           @{ Name = 'Action'; Type = 'System.String'; Required = $true; Default = ''; Values = @('MachinePolicy', 'AppDeploymentEval', 'HardwareInventory', 'SoftwareInventory', 'DiscoveryData', 'SoftwareUpdateScan', 'SoftwareUpdateEval', 'All') }) },
    @{ Name = 'AZITC-TK-CMApp-Action'; Timeout = 1800
       Description = 'AZITC Toolkit - Install / Uninstall / Repair a ConfigMgr application through CCM_Application, watched; JSON result.'
       Parameters = @(
           @{ Name = 'Action';           Type = 'System.String'; Required = $true;  Default = '';  Values = @('Install', 'Uninstall', 'Repair') },
           @{ Name = 'AppId';            Type = 'System.String'; Required = $true;  Default = '' },
           @{ Name = 'Revision';         Type = 'System.Int32';  Required = $false; Default = '0' },
           @{ Name = 'TimeoutMin';       Type = 'System.Int32';  Required = $false; Default = '10' },
           @{ Name = 'IsRebootIfNeeded'; Type = 'System.Int32';  Required = $false; Default = '0' }) },
    @{ Name = 'AZITC-TK-Client-Get'; Timeout = 300
       Description = 'AZITC Toolkit - client facts, pending reboot, services, processes, ConfigMgr cache; gzip+base64 JSON envelope.'
       Parameters = @() },
    @{ Name = 'AZITC-TK-Client-Manage'; Timeout = 300
       Description = 'AZITC Toolkit - service start/stop/restart, process kill, cache delete/clear; JSON result.'
       Parameters = @(
           @{ Name = 'Target'; Type = 'System.String'; Required = $true;  Default = ''; Values = @('Service', 'Process', 'Cache') },
           @{ Name = 'Action'; Type = 'System.String'; Required = $true;  Default = ''; Values = @('Start', 'Stop', 'Restart', 'Kill', 'Delete', 'Clear') },
           @{ Name = 'Name';   Type = 'System.String'; Required = $false; Default = '' }) },
    @{ Name = 'AZITC-TK-CMApp-Troubleshoot'; Timeout = 300
       Description = 'AZITC Toolkit - why is this application not where the deployment wants it: detection clauses evaluated on the device, enforcement history, evaluation cycle; gzip+base64 JSON envelope.'
       Parameters = @(
           @{ Name = 'AppId';    Type = 'System.String'; Required = $true;  Default = '' },
           @{ Name = 'Days';     Type = 'System.Int32';  Required = $false; Default = '14' },
           @{ Name = 'MaxLines'; Type = 'System.Int32';  Required = $false; Default = '25' }) }
)

if ($SkipCertificateCheck) { Connect-TKAdminService -SmsProvider $SmsProvider -SkipCertificateCheck } else { Connect-TKAdminService -SmsProvider $SmsProvider }
$SmsProvider = $script:TKSmsProvider
Write-Host "Connected to $SmsProvider"

# Two-key approval: read-only look at the hierarchy setting so the summary can say who approves.
$twoKey = $null
try {
    $def = Invoke-TKRest -Method Get -Route wmi -Path "SMS_SCI_SiteDefinition?`$filter=ParentSiteCode eq ''"
    foreach ($row in @($def.value)) {
        $full = @((Invoke-TKRest -Method Get -Route wmi -Path "SMS_SCI_SiteDefinition(FileType=$($row.FileType),ItemName='$($row.ItemName)',ItemType='$($row.ItemType)',SiteCode='$($row.SiteCode)')").value)[0]
        foreach ($p in @($full.Props)) { if ($p.PropertyName -eq 'TwoKeyApproval') { $twoKey = [int]$p.Value } }
    }
} catch { }
if ($null -ne $twoKey) { Write-Host "Hierarchy setting 'Script authors require additional script approver': $(if ($twoKey -eq 1) { 'ON - a second administrator approves' } else { 'off - the author can approve' })" }

$me = "$env:USERDOMAIN\$env:USERNAME"
$summary = @()
foreach ($item in $catalogue) {
    $name = $item.Name
    $file = Join-Path -Path $PSScriptRoot -ChildPath "$name.ps1"
    if (-not (Test-Path -LiteralPath $file)) { throw "Missing: $file" }
    $bytes = [System.IO.File]::ReadAllBytes($file)
    $hash = Get-TKSha256Hex -Bytes $bytes -Upper
    $existing = @((Invoke-TKRest -Method Get -Path ("Script?`$filter=ScriptName eq '{0}'" -f $name)).value)
    $state = ''
    $guid = ''
    $version = '1'
    $approval = 0

    if ($existing.Count -eq 0) {
        $state = 'created'
        if ($PSCmdlet.ShouldProcess($name, 'Create')) {
            $s = Register-TKScript -Name $name -File $file -Timeout $item.Timeout -Description $item.Description -Parameters $item.Parameters
            $guid = $s.ScriptGuid; $version = $s.ScriptVersion; $approval = [int]$s.ApprovalState
        }
    } else {
        $cur = $existing[0]
        $guid = [string]$cur.ScriptGuid; $version = [string]$cur.ScriptVersion; $approval = [int]$cur.ApprovalState
        $full = @((Invoke-TKRest -Method Get -Route wmi -Path "SMS_Scripts('$guid')").value)[0]
        $siteParams = @($full.Parameterlist | ForEach-Object { [string]$_.ParameterName } | Sort-Object)
        $wantParams = @($item.Parameters | ForEach-Object { [string]$_.Name } | Sort-Object)
        # The definition the site holds (base64 XML) against the one the catalogue produces:
        # allowed values, types, defaults and required flags count, not only the names. A
        # changed definition with the same names goes through UpdateScript and keeps the GUID.
        $wantDef = ''
        if ($item.Parameters.Count -gt 0) { $wantDef = (New-TKScriptParameterXml -Parameters $item.Parameters).Definition }
        $siteDef = [string]$full.ParamsDefinition
        if ($siteDef -and -not $siteDef.TrimStart().StartsWith('<')) { try { $siteDef = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($siteDef)) } catch { } }
        $defChanged = ($siteDef -ne $wantDef)
        $defB64 = ''
        if ($wantDef) { $defB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($wantDef)) }
        if (($siteParams -join ',') -ne ($wantParams -join ',')) {
            $state = 'recreated (parameter set changed)'
            if ($PSCmdlet.ShouldProcess($name, 'Delete and create anew')) {
                $s = Register-TKScript -Name $name -File $file -Timeout $item.Timeout -Description $item.Description -Parameters $item.Parameters -Replace
                $guid = $s.ScriptGuid; $version = $s.ScriptVersion; $approval = [int]$s.ApprovalState
            }
        } elseif ([string]$cur.ScriptHash -ne $hash -or [int]$full.Timeout -ne $item.Timeout -or $defChanged) {
            $newVersion = ([int]$version + 1).ToString()
            $state = "updated to v$newVersion"
            if ($defChanged -and [string]$cur.ScriptHash -eq $hash) { $state += ' (parameter definition)' }
            if ($PSCmdlet.ShouldProcess($name, "Update to v$newVersion")) {
                $null = Invoke-TKRest -Method Post -Route wmi -Path "SMS_Scripts('$guid')/AdminService.UpdateScript" -Body @{
                    ParamsDefinition = $defB64
                    Script           = [Convert]::ToBase64String($bytes, [System.Base64FormattingOptions]::InsertLineBreaks)
                    ScriptDescription= $item.Description
                    ScriptName       = $name
                    ScriptVersion    = $newVersion
                    Timeout          = $item.Timeout
                }
                $after = @((Invoke-TKRest -Method Get -Route wmi -Path "SMS_Scripts('$guid')").value)[0]
                $version = [string]$after.ScriptVersion; $approval = [int]$after.ApprovalState
            }
        } else {
            $state = 'up to date'
        }
    }

    $approveNote = ''
    if ($approval -ne 3 -and -not $NoApprove -and $guid) {
        if ($PSCmdlet.ShouldProcess($name, 'Approve')) {
            try {
                $a = Approve-TKScript -ScriptGuid $guid -Comment "AZITC Toolkit, published by $me on $(Get-Date -Format 'yyyy-MM-dd')"
                $approval = [int]$a.ApprovalState
                if ($approval -eq 3) { $approveNote = 'approved' } else { $approveNote = "approval state $approval" }
            } catch {
                $approveNote = 'NOT approved - a second administrator has to approve it in the console'
            }
        }
    } elseif ($approval -eq 3) { $approveNote = 'approved' }
    elseif ($NoApprove) { $approveNote = 'not approved (-NoApprove)' }

    $summary += [pscustomobject]@{ Script = $name; Guid = $guid; Version = $version; State = $state; Approval = $approveNote }
}

$summary | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
if ($summary | Where-Object { $_.Approval -like 'NOT approved*' }) {
    Write-Host 'Some scripts wait for a second approver: Software Library > Scripts > select > Approve/Deny.' -ForegroundColor Yellow
}
