#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Checks whether the console extension "Manage Membership" is installed completely.
.PARAMETER ConsolePath
    AdminConsole folder. Found by itself when not given.
#>
param(
    [string]$ConsolePath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Same GUID as in the installer (device collection in the result pane)
$actionGuid = '{a92615d6-9df3-49ba-a8c9-6ecb0e8b956b}'

# Find the AdminConsole folder
if (-not $ConsolePath) {
    $candidates = @(
        'D:\Program Files\Microsoft Configuration Manager\AdminConsole',
        "${env:ProgramFiles(x86)}\Microsoft Configuration Manager\AdminConsole",
        "${env:ProgramFiles(x86)}\Microsoft Endpoint Manager\AdminConsole",
        'C:\Program Files (x86)\Microsoft Configuration Manager\AdminConsole'
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { $ConsolePath = $c; break }
    }
}

if (-not $ConsolePath -or -not (Test-Path $ConsolePath)) {
    Write-Error "AdminConsole folder not found - give -ConsolePath."
    exit 1
}

Write-Host "AdminConsole : $ConsolePath" -ForegroundColor Cyan
Write-Host "Action GUID  : $actionGuid`n" -ForegroundColor Cyan

# File check
$scriptDir = Join-Path $ConsolePath 'extensions\RightClickTools'
$actionDir = Join-Path $ConsolePath "XmlStorage\Extensions\Actions\$actionGuid"

$checks = @(
    @{ Name = 'Manage-CollectionMembership.ps1'; Path = (Join-Path $scriptDir 'Manage-CollectionMembership.ps1') },
    @{ Name = 'nopswindow.exe';                  Path = (Join-Path $scriptDir 'nopswindow.exe') },
    @{ Name = 'CollectionMembership.xml';        Path = (Join-Path $actionDir 'CollectionMembership.xml') }
)

Write-Host "Files:" -ForegroundColor Yellow
$allOk = $true
foreach ($c in $checks) {
    if (Test-Path $c.Path) {
        Write-Host ("  [OK]    {0}" -f $c.Name) -ForegroundColor Green
    } else {
        Write-Host ("  [MISSING] {0}" -f $c.Name) -ForegroundColor Red
        Write-Host ("            {0}" -f $c.Path) -ForegroundColor Gray
        $allOk = $false
    }
}

# Show the action XML
$xmlPath = Join-Path $actionDir 'CollectionMembership.xml'
if (Test-Path $xmlPath) {
    Write-Host "`nAction XML (excerpt):" -ForegroundColor Yellow
    [xml]$xml = Get-Content $xmlPath -Encoding UTF8
    $a = $xml.ActionDescription
    Write-Host "  DisplayName    : $($a.DisplayName)"
    Write-Host "  FilePath       : $($a.Executable.FilePath)"
    Write-Host "  Parameters     : $($a.Executable.Parameters)"
}

Write-Host "`nIMPORTANT - the usual cause when the entry is missing:" -ForegroundColor Yellow
Write-Host "  The hierarchy setting 'Only allow console extensions that are" -ForegroundColor Gray
Write-Host "  approved for the hierarchy' MUST be off, otherwise every" -ForegroundColor Gray
Write-Host "  file-based extension is hidden without a trace." -ForegroundColor Gray
Write-Host "  Administration > Site Configuration > Sites > Hierarchy Settings > General" -ForegroundColor Gray

if ($allOk) {
    Write-Host "`nAll files present. Close the console completely and start it again," -ForegroundColor Green
    Write-Host "then right-click a device collection in the result pane." -ForegroundColor Green
} else {
    Write-Host "`nFiles are missing - run Install-Extension.ps1 (again)." -ForegroundColor Red
}
