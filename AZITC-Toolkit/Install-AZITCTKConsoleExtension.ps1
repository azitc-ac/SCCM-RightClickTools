<#
.SYNOPSIS
    Installs (or removes) the AZITC Toolkit right-click action in the Configuration Manager console.

.DESCRIPTION
    Copies AZITC-TK.ps1 and AZITC-TK-AdminService.ps1 to <AdminConsole>\extensions\AZITC-Toolkit\,
    compiles AZITC-TK-Launcher.exe there, and writes AZITC-TK.xml into the two action folders
    whose rows are devices:
      {ed9dee86-eadd-4ac8-82a1-7234a4646e62}   Devices node
      {3fd01cd1-9e01-461e-92cd-94866b8d1f39}   member view of a device collection
    Close and reopen the console afterwards.

    The hierarchy setting "Only allow console extensions that are approved for the hierarchy"
    hides every file-based extension without a trace. It has to be off for this action to
    appear; this script does not change it.

.PARAMETER ConsolePath
    AdminConsole folder. Found by itself from SMS_ADMIN_UI_PATH or the usual locations.
.PARAMETER SkipCertificateCheck
    Pass -SkipCertificateCheck to the window (self-signed AdminService certificate). Default on;
    -SkipCertificateCheck:$false once the provider has a PKI certificate.
.PARAMETER Report
    The report the action on the Device Collections node and its folders opens. Default: the
    compliance overview of the sccm-reports repository. '' installs no report action.
.PARAMETER ReportFolder
    The SSRS folder of that report below the site's root folder.
.PARAMETER ReportInBrowser
    Open the report in the web portal instead of the report viewer window (the console's own
    ReportViewer control, loaded from the console's bin folder).
.PARAMETER Uninstall
    Remove the action files and the extension folder.
.PARAMETER KeepWindow
    Wait for Enter at the end. Set by the script itself when it restarts elevated, so the
    new window does not close with the last line of output.
#>
[CmdletBinding()]
param(
    [string]$ConsolePath = '',
    [bool]$SkipCertificateCheck = $true,
    [string]$Report = 'Anwendungs-Installationsstatus - Compliance-Übersicht',
    [string]$ReportFolder = 'Softwareverteilung - Anwendungsüberwachung',
    [switch]$ReportInBrowser,
    [switch]$Uninstall,
    [switch]$KeepWindow
)

$ErrorActionPreference = 'Stop'

# Writing below the AdminConsole folder needs administrator rights. Not elevated,
# the script starts itself again through the UAC prompt with the same arguments
# and hands the result back - so it can be run from any prompt, and update.ps1
# can call it without being elevated itself.
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host 'Not running as administrator - restarting elevated (UAC prompt).'
    # -Command, not -File: in -File mode every argument is a string, and a
    # [switch] or [bool] parameter refuses "-Name:$false" ("cannot convert
    # System.String to SwitchParameter"). Values go in single quotes.
    $call = "& '{0}' -KeepWindow" -f $PSCommandPath.Replace("'", "''")
    foreach ($name in $PSBoundParameters.Keys) {
        $value = $PSBoundParameters[$name]
        if ($name -eq 'KeepWindow') { continue }
        if ($value -is [switch] -or $value -is [bool]) { $call += ' -{0}:${1}' -f $name, [bool]$value }
        else { $call += " -{0} '{1}'" -f $name, ([string]$value -replace "'", "''" -replace '"', '') }
    }
    $argumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', ('"{0}"' -f $call))
    try {
        $elevated = Start-Process -FilePath "$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $argumentList -Verb RunAs -Wait -PassThru
    }
    catch { throw 'The elevation prompt was declined - nothing was installed.' }
    if ($elevated.ExitCode -ne 0) { throw ('The elevated run ended with exit code {0} - see its window.' -f $elevated.ExitCode) }
    Write-Host 'Done in the elevated window.'
    return
}
$exitCode = 0
try {

if (-not $ConsolePath) {
    $candidates = @()
    if ($env:SMS_ADMIN_UI_PATH) { $candidates += (Split-Path -Path (Split-Path -Path $env:SMS_ADMIN_UI_PATH -Parent) -Parent) }
    $candidates += @(
        'D:\Program Files\Microsoft Configuration Manager\AdminConsole',
        "${env:ProgramFiles(x86)}\Microsoft Configuration Manager\AdminConsole",
        "${env:ProgramFiles(x86)}\Microsoft Endpoint Manager\AdminConsole",
        'C:\Program Files (x86)\Microsoft Configuration Manager\AdminConsole'
    )
    foreach ($c in $candidates) { if ($c -and (Test-Path -LiteralPath (Join-Path $c 'bin'))) { $ConsolePath = $c; break } }
}
if (-not $ConsolePath -or -not (Test-Path -LiteralPath $ConsolePath)) { throw 'AdminConsole folder not found - give -ConsolePath.' }
Write-Host "AdminConsole: $ConsolePath"

$actionGuids = @('{ed9dee86-eadd-4ac8-82a1-7234a4646e62}', '{3fd01cd1-9e01-461e-92cd-94866b8d1f39}')
$collectionNodeGuid = '{6d357b6b-96b3-45f4-ba09-b74e8ce5a509}'     # Device Collections node and its folders
$extDir = Join-Path -Path $ConsolePath -ChildPath 'extensions\AZITC-Toolkit'
$xmlName = 'AZITC-TK.xml'
$reportXmlName = 'AZITC-TK-Report.xml'

if ($Uninstall) {
    $files = @()
    foreach ($g in $actionGuids) { $files += (Join-Path -Path $ConsolePath -ChildPath "XmlStorage\Extensions\Actions\$g\$xmlName") }
    $files += (Join-Path -Path $ConsolePath -ChildPath "XmlStorage\Extensions\Actions\$collectionNodeGuid\$reportXmlName")
    foreach ($f in $files) {
        if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force; Write-Host "Removed: $f" }
        $d = Split-Path -Path $f -Parent
        if ((Test-Path -LiteralPath $d) -and -not (Get-ChildItem -LiteralPath $d -Force)) { Remove-Item -LiteralPath $d -Force; Write-Host "Removed: $d" }
    }
    if (Test-Path -LiteralPath $extDir) { Remove-Item -LiteralPath $extDir -Recurse -Force; Write-Host "Removed: $extDir" }
    Write-Host 'Uninstalled. Restart the console.'
    return
}

# --- files ------------------------------------------------------------------

if (-not (Test-Path -LiteralPath $extDir)) { New-Item -ItemType Directory -Path $extDir -Force | Out-Null }
foreach ($n in 'AZITC-TK.ps1', 'AZITC-TK-AdminService.ps1', 'AZITC-TK-OpenReport.ps1', 'VERSION') {
    $src = Join-Path -Path $PSScriptRoot -ChildPath $n
    if (-not (Test-Path -LiteralPath $src)) { throw "Missing: $src" }
    Copy-Item -LiteralPath $src -Destination (Join-Path $extDir $n) -Force
    Write-Host "Copied:   $(Join-Path $extDir $n)"
}

$launcherSrc = Join-Path -Path $PSScriptRoot -ChildPath 'AZITC-TK-Launcher.cs'
$launcherExe = Join-Path -Path $extDir -ChildPath 'AZITC-TK-Launcher.exe'
$csc = @("$env:windir\Microsoft.NET\Framework64\v4.0.30319\csc.exe", "$env:windir\Microsoft.NET\Framework\v4.0.30319\csc.exe") | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $csc) { throw 'csc.exe (.NET Framework 4) not found.' }
$out = & $csc /nologo /target:winexe /out:"$launcherExe" "$launcherSrc" 2>&1
if (-not (Test-Path -LiteralPath $launcherExe)) { throw "Compiling the launcher failed: $out" }
Write-Host "Compiled: $launcherExe"

# --- action XML -------------------------------------------------------------

$scriptPath = Join-Path -Path $extDir -ChildPath 'AZITC-TK.ps1'
$skip = ''
if ($SkipCertificateCheck) { $skip = ' -SkipCertificateCheck' }
$template = Get-Content -LiteralPath (Join-Path $PSScriptRoot $xmlName) -Raw -Encoding UTF8
$content = $template.Replace('##EXT_PATH##', $extDir).Replace('##SCRIPT_PATH##', $scriptPath).Replace('##SKIPCERT##', $skip)
$utf8 = New-Object System.Text.UTF8Encoding($true)
foreach ($g in $actionGuids) {
    $dir = Join-Path -Path $ConsolePath -ChildPath "XmlStorage\Extensions\Actions\$g"
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $target = Join-Path -Path $dir -ChildPath $xmlName
    [System.IO.File]::WriteAllText($target, $content, $utf8)
    Write-Host "Action:   $target"
}

# the report action on the Device Collections node and its folders
$reportTarget = Join-Path -Path $ConsolePath -ChildPath "XmlStorage\Extensions\Actions\$collectionNodeGuid\$reportXmlName"
if ($Report) {
    $reportScript = Join-Path -Path $extDir -ChildPath 'AZITC-TK-OpenReport.ps1'
    $rt = Get-Content -LiteralPath (Join-Path $PSScriptRoot $reportXmlName) -Raw -Encoding UTF8
    $browser = ''
    if ($ReportInBrowser) { $browser = ' -Browser' }
    $rc = $rt.Replace('##EXT_PATH##', $extDir).Replace('##REPORT_SCRIPT##', $reportScript).Replace('##REPORT##', $Report).Replace('##FOLDER##', $ReportFolder).Replace('##SKIPCERT##', $skip).Replace('##BROWSER##', $browser)
    $dir = Split-Path -Path $reportTarget -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($reportTarget, $rc, $utf8)
    Write-Host "Action:   $reportTarget"
} elseif (Test-Path -LiteralPath $reportTarget) { Remove-Item -LiteralPath $reportTarget -Force; Write-Host "Removed:  $reportTarget" }

Write-Host ''
Write-Host 'Installed. Close the console completely and start it again.'
Write-Host 'If the entry does not appear: Administration > Site Configuration > Sites > Hierarchy Settings >'
Write-Host '"Only allow console extensions that are approved for the hierarchy" must be off.'
}
catch {
    $exitCode = 1
    Write-Host ''
    Write-Host ("FAILED: {0}" -f $_.Exception.Message) -ForegroundColor Red
}
finally {
    if ($KeepWindow) { Write-Host ''; $null = Read-Host 'Press Enter to close' }
}
exit $exitCode
