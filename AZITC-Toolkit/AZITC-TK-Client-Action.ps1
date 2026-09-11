<#
.SYNOPSIS
    AZITC Toolkit - trigger a ConfigMgr client schedule (the "client actions" of the console).

.DESCRIPTION
    Designed to run as a Configuration Manager "Run Script" (SYSTEM context, Windows PowerShell 5.1).
    Calls SMS_Client.TriggerSchedule in root\ccm for the schedule behind the chosen action and
    reports the result as ONE JSON object. Nothing else is changed on the client.

    Recommended script timeout in the console: 120 seconds.

.PARAMETER Action
    MachinePolicy           Machine policy retrieval and evaluation   ({...0021} + {...0022})
    AppDeploymentEval       Application deployment evaluation          ({...0121})
    HardwareInventory       Hardware inventory cycle                   ({...0001})
    SoftwareInventory       Software inventory cycle                   ({...0002})
    DiscoveryData           Discovery data collection (heartbeat)      ({...0003})
    SoftwareUpdateScan      Software updates scan                      ({...0113})
    SoftwareUpdateEval      Software updates deployment evaluation     ({...0108})
    All                     MachinePolicy, then AppDeploymentEval

.NOTES
    Author : Alexander Zarenko IT Consulting (AZITC)
    Schema : 1
#>

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('MachinePolicy', 'AppDeploymentEval', 'HardwareInventory', 'SoftwareInventory', 'DiscoveryData', 'SoftwareUpdateScan', 'SoftwareUpdateEval', 'All')]
    [string]$Action
)

$ErrorActionPreference = 'Stop'
$SchemaVersion = 1

$schedules = @{
    MachinePolicy      = @('{00000000-0000-0000-0000-000000000021}', '{00000000-0000-0000-0000-000000000022}')
    AppDeploymentEval  = @('{00000000-0000-0000-0000-000000000121}')
    HardwareInventory  = @('{00000000-0000-0000-0000-000000000001}')
    SoftwareInventory  = @('{00000000-0000-0000-0000-000000000002}')
    DiscoveryData      = @('{00000000-0000-0000-0000-000000000003}')
    SoftwareUpdateScan = @('{00000000-0000-0000-0000-000000000113}')
    SoftwareUpdateEval = @('{00000000-0000-0000-0000-000000000108}')
}

$order = @($Action)
if ($Action -eq 'All') { $order = @('MachinePolicy', 'AppDeploymentEval') }

$result = [ordered]@{
    Schema    = $SchemaVersion
    Kind      = 'ClientAction'
    Host      = $env:COMPUTERNAME
    TimeUtc   = (Get-Date).ToUniversalTime().ToString('s')
    Action    = $Action
    Triggered = @()
    Failed    = @()
    Error     = ''
}

$exit = 0
foreach ($name in $order) {
    foreach ($id in $schedules[$name]) {
        try {
            Invoke-CimMethod -Namespace 'root\ccm' -ClassName 'SMS_Client' -MethodName 'TriggerSchedule' -Arguments @{ sScheduleID = $id } -ErrorAction Stop | Out-Null
            $result.Triggered += ('{0} {1}' -f $name, $id)
        } catch {
            $result.Failed += ('{0} {1}: {2}' -f $name, $id, $_.Exception.Message)
            $exit = 1
        }
        # Policy has to arrive before an evaluation of it makes sense.
        if ($name -eq 'MachinePolicy' -and $Action -eq 'All') { Start-Sleep -Seconds 20 }
    }
}
if ($exit -ne 0) { $result.Error = 'One or more schedules could not be triggered.' }

$result | ConvertTo-Json -Depth 3 -Compress | Write-Output
exit $exit
