<#
.SYNOPSIS
    AZITC Toolkit - opens a reporting point report in the browser, from a console action.

.DESCRIPTION
    Started by the console action on the Device Collections node and its folders. Reads the
    reporting point of the site through the AdminService (SMS_SCI_SysResUse, role "SMS SRS
    Reporting Point": ReportManagerUri or ReportServerUri, RootFolder) and opens the report
    in the web portal:

        <portal>/report/<RootFolder>/<Folder>/<Report>

    ReportManagerUri is empty on some sites; then the portal is derived from ReportServerUri
    (…/ReportServer -> …/Reports). Errors are shown in a message box - there is no console.

.PARAMETER Report
    The report's name as published, e.g. 'Anwendungs-Installationsstatus - Compliance-Übersicht'.

.PARAMETER Folder
    The SSRS folder below the site's root folder. Default: the folder of the sccm-reports
    repository, 'Softwareverteilung - Anwendungsüberwachung'.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Report,
    [string]$Folder = 'Softwareverteilung - Anwendungsüberwachung',
    [string]$SmsProvider = '',
    [string]$SiteCode = '',
    [switch]$SkipCertificateCheck
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
function Show-Failure { param([string]$Text) [System.Windows.MessageBox]::Show($Text, 'AZITC Toolkit - open report', 'OK', 'Error') | Out-Null }

try {
    . (Join-Path $PSScriptRoot 'AZITC-TK-AdminService.ps1')
    if ($SkipCertificateCheck) { Connect-TKAdminService -SmsProvider $SmsProvider -SkipCertificateCheck } else { Connect-TKAdminService -SmsProvider $SmsProvider }

    $filter = "RoleName eq 'SMS SRS Reporting Point'"
    if ($SiteCode) { $filter += " and SiteCode eq '$SiteCode'" }
    $rp = @((Invoke-TKRest -Route wmi -Path ("SMS_SCI_SysResUse?`$filter=" + $filter)).value)
    if ($rp.Count -eq 0) { throw "The site has no reporting point (SMS_SCI_SysResUse, role 'SMS SRS Reporting Point')." }
    $props = @{}
    foreach ($p in @($rp[0].Props)) { $props[[string]$p.PropertyName] = [string]$p.Value2 }
    $portal = $props['ReportManagerUri']
    if (-not $portal) {
        $server = $props['ReportServerUri']
        if (-not $server) { throw 'The reporting point has neither ReportManagerUri nor ReportServerUri.' }
        $portal = ($server.TrimEnd('/') -replace '/ReportServer$', '/Reports')
    }
    $root = $props['RootFolder']; if (-not $root) { $root = 'ConfigMgr_' + $SiteCode }

    $encoded = (@($root, $Folder, $Report) | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
    $url = $portal.TrimEnd('/') + '/report/' + $encoded
    if ($env:AZITC_TK_DRYRUN) { Write-Output $url } else { Start-Process $url }
} catch {
    Show-Failure ("Could not open the report.`n`n{0}" -f $_.Exception.Message)
    exit 1
}
