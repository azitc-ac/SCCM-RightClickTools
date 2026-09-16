<#
.SYNOPSIS
    AZITC Toolkit - opens a reporting point report, from a console action.

.DESCRIPTION
    Started by the console action on the Device Collections node and its folders. Reads the
    reporting point of the site through the AdminService (SMS_SCI_SysResUse, role "SMS SRS
    Reporting Point": ReportServerUri, ReportManagerUri, RootFolder) and shows the report

        /<RootFolder>/<Folder>/<Report>

    in a report viewer window - the same Microsoft.ReportViewer.WinForms control the console
    uses for its own report viewer, loaded from the console's bin folder, in remote mode against
    the report server. Page navigation, parameters, print and export work as in the console.
    Signed in as the current user, like the console.

    -Browser opens the report in the web portal instead (also the fallback when the console's
    viewer assemblies are not found):

        <portal>/report/<RootFolder>/<Folder>/<Report>

    ReportManagerUri is empty on some sites; then the portal is derived from ReportServerUri
    (.../ReportServer -> .../Reports). Errors are shown in a message box - there is no console.

.PARAMETER Report
    The report's name as published, e.g. 'Anwendungs-Installationsstatus - Compliance-Übersicht'.

.PARAMETER Folder
    The SSRS folder below the site's root folder. Default: the folder of the sccm-reports
    repository, 'Softwareverteilung - Anwendungsüberwachung'.

.PARAMETER Browser
    Open the web portal instead of the viewer window.

.NOTES
    Test hooks: AZITC_TK_DRYRUN=1 prints the viewer target (server URL and report path) or the
    portal URL and exits; AZITC_TK_TESTCLOSE=<ms> closes the viewer window after that time and
    prints the render result.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Report,
    [string]$Folder = 'Softwareverteilung - Anwendungsüberwachung',
    [string]$SmsProvider = '',
    [string]$SiteCode = '',
    [switch]$SkipCertificateCheck,
    [switch]$Browser
)

$ErrorActionPreference = 'Stop'
# A token the console did not fill in arrives as the literal ##SUB:...## - the same as not given.
foreach ($n in 'SmsProvider', 'SiteCode', 'Folder', 'Report') { if ((Get-Variable $n -ValueOnly) -like '##SUB:*') { Set-Variable $n -Value '' } }
Add-Type -AssemblyName PresentationFramework
function Show-Failure { param([string]$Text) [System.Windows.MessageBox]::Show($Text, 'AZITC Toolkit - open report', 'OK', 'Error') | Out-Null }

# The console's bin folder holds Microsoft.ReportViewer.WinForms; SMS_ADMIN_UI_PATH points to bin\i386.
function Get-ConsoleBin {
    $candidates = @()
    if ($env:SMS_ADMIN_UI_PATH) { $candidates += (Split-Path -Path $env:SMS_ADMIN_UI_PATH -Parent) }
    foreach ($root in @(${env:ProgramFiles(x86)}, $env:ProgramFiles)) {
        if ($root) { $candidates += (Join-Path $root 'Microsoft Endpoint Manager\AdminConsole\bin'); $candidates += (Join-Path $root 'Microsoft Configuration Manager\AdminConsole\bin') }
    }
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath (Join-Path $c 'Microsoft.ReportViewer.WinForms.dll')) -and (Test-Path -LiteralPath (Join-Path $c 'Microsoft.ReportViewer.Common.dll'))) { return $c }
    }
    return $null
}

function Show-ReportViewer {
    param([string]$Bin, [string]$ServerUrl, [string]$ReportPath, [string]$Title)
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    # LoadFrom instead of Add-Type: Common.dll carries types whose dependencies are not in a
    # PowerShell process, Add-Type reports those as an error although the assembly is loaded.
    foreach ($n in 'Microsoft.ReportViewer.Common.dll', 'Microsoft.ReportViewer.WinForms.dll') { [void][System.Reflection.Assembly]::LoadFrom((Join-Path $Bin $n)) }
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $viewer = New-Object Microsoft.Reporting.WinForms.ReportViewer
    $viewer.ProcessingMode = [Microsoft.Reporting.WinForms.ProcessingMode]::Remote
    $viewer.ServerReport.ReportServerUrl = [uri]$ServerUrl
    $viewer.ServerReport.ReportPath = $ReportPath
    $viewer.Dock = [System.Windows.Forms.DockStyle]::Fill
    $viewer.ShowRefreshButton = $true
    $viewer.ShowParameterPrompts = $true

    $form = New-Object System.Windows.Forms.Form
    $form.Text = $Title
    $form.Width = 1280; $form.Height = 860
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.Controls.Add($viewer)

    $script:renderError = $null
    $viewer.add_ReportError({ param($s, $e)
        $script:renderError = $e.Exception.Message
        $e.Handled = $true
        if (-not $env:AZITC_TK_TESTCLOSE) { Show-Failure ("The report server returned an error.`n`n{0}" -f $e.Exception.Message) }
    })
    $form.add_Shown({ $viewer.RefreshReport() })

    if ($env:AZITC_TK_TESTCLOSE) {
        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = [int]$env:AZITC_TK_TESTCLOSE
        $timer.add_Tick({
            # output from inside an event handler is dropped - keep it for after Run
            $script:testResult = 'rendered={0} error={1}' -f $viewer.ServerReport.IsReadyForRendering, $script:renderError
            $form.Close()
        })
        $timer.Start()
    }
    [System.Windows.Forms.Application]::Run($form)
    if ($env:AZITC_TK_TESTCLOSE) { Write-Output $script:testResult }
}

try {
    . (Join-Path $PSScriptRoot 'AZITC-TK-AdminService.ps1')
    if ($SkipCertificateCheck) { Connect-TKAdminService -SmsProvider $SmsProvider -SkipCertificateCheck } else { Connect-TKAdminService -SmsProvider $SmsProvider }

    $filter = "RoleName eq 'SMS SRS Reporting Point'"
    if ($SiteCode) { $filter += " and SiteCode eq '$SiteCode'" }
    $rp = @((Invoke-TKRest -Route wmi -Path ("SMS_SCI_SysResUse?`$filter=" + $filter)).value)
    if ($rp.Count -eq 0) { throw "The site has no reporting point (SMS_SCI_SysResUse, role 'SMS SRS Reporting Point')." }
    $props = @{}
    foreach ($p in @($rp[0].Props)) { $props[[string]$p.PropertyName] = [string]$p.Value2 }
    $server = $props['ReportServerUri']
    $portal = $props['ReportManagerUri']
    if (-not $server -and -not $portal) { throw 'The reporting point has neither ReportServerUri nor ReportManagerUri.' }
    if (-not $server) { $server = ($portal.TrimEnd('/') -replace '/Reports$', '/ReportServer') }
    if (-not $portal) { $portal = ($server.TrimEnd('/') -replace '/ReportServer$', '/Reports') }
    $root = $props['RootFolder']; if (-not $root) { $root = 'ConfigMgr_' + $SiteCode }

    $bin = $null
    if (-not $Browser) { $bin = Get-ConsoleBin }
    if ($bin) {
        $path = '/' + ((@($root, $Folder, $Report) | Where-Object { $_ }) -join '/')
        if ($env:AZITC_TK_DRYRUN) { Write-Output ('viewer {0} {1}' -f $server, $path); exit 0 }
        Show-ReportViewer -Bin $bin -ServerUrl $server -ReportPath $path -Title $Report
    } else {
        $encoded = (@($root, $Folder, $Report) | Where-Object { $_ } | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
        $url = $portal.TrimEnd('/') + '/report/' + $encoded
        if ($env:AZITC_TK_DRYRUN) { Write-Output ('browser ' + $url); exit 0 }
        Start-Process $url
    }
} catch {
    if ($env:AZITC_TK_TESTCLOSE) { Write-Output ('failed: ' + $_.Exception.Message + ' at ' + $_.InvocationInfo.ScriptLineNumber) }
    else { Show-Failure ("Could not open the report.`n`n{0}" -f $_.Exception.Message) }
    exit 1
}
