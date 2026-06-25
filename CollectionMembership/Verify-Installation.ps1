#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Prueft, ob die Konsolenerweiterung "Mitgliedschaft verwalten" korrekt installiert ist.
.PARAMETER ConsolePath
    Pfad zur AdminConsole. Wird automatisch ermittelt falls nicht angegeben.
#>
param(
    [string]$ConsolePath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Gleiche GUID wie im Installer (Device-Collection im Ergebnisbereich)
$actionGuid = '{a92615d6-9df3-49ba-a8c9-6ecb0e8b956b}'

# AdminConsole-Pfad ermitteln
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
    Write-Error "AdminConsole-Pfad nicht gefunden. Bitte -ConsolePath angeben."
    exit 1
}

Write-Host "AdminConsole : $ConsolePath" -ForegroundColor Cyan
Write-Host "Action-GUID  : $actionGuid`n" -ForegroundColor Cyan

# Datei-Pruefung
$scriptDir = Join-Path $ConsolePath 'extensions\RightClickTools'
$actionDir = Join-Path $ConsolePath "XmlStorage\Extensions\Actions\$actionGuid"

$checks = @(
    @{ Name = 'Manage-CollectionMembership.ps1'; Path = (Join-Path $scriptDir 'Manage-CollectionMembership.ps1') },
    @{ Name = 'nopswindow.exe';                  Path = (Join-Path $scriptDir 'nopswindow.exe') },
    @{ Name = 'CollectionMembership.xml';        Path = (Join-Path $actionDir 'CollectionMembership.xml') }
)

Write-Host "Datei-Pruefung:" -ForegroundColor Yellow
$allOk = $true
foreach ($c in $checks) {
    if (Test-Path $c.Path) {
        Write-Host ("  [OK]    {0}" -f $c.Name) -ForegroundColor Green
    } else {
        Write-Host ("  [FEHLT] {0}" -f $c.Name) -ForegroundColor Red
        Write-Host ("          {0}" -f $c.Path) -ForegroundColor Gray
        $allOk = $false
    }
}

# XML-Inhalt anzeigen
$xmlPath = Join-Path $actionDir 'CollectionMembership.xml'
if (Test-Path $xmlPath) {
    Write-Host "`nXML-Inhalt (Auszug):" -ForegroundColor Yellow
    [xml]$xml = Get-Content $xmlPath -Encoding UTF8
    $a = $xml.ActionDescription
    Write-Host "  DisplayName    : $($a.DisplayName)"
    Write-Host "  FilePath       : $($a.Executable.FilePath)"
    Write-Host "  Parameters     : $($a.Executable.Parameters)"
}

Write-Host "`nWICHTIG - haeufigste Fehlerquelle:" -ForegroundColor Yellow
Write-Host "  Hierarchie-Einstellung 'Only allow console extensions that are" -ForegroundColor Gray
Write-Host "  approved for the hierarchy' MUSS deaktiviert sein, sonst werden" -ForegroundColor Gray
Write-Host "  alle file-basierten Extensions stillschweigend ausgeblendet." -ForegroundColor Gray
Write-Host "  Verwaltung > Standortkonfiguration > Standorte > Hierarchieeinstellungen > Allgemein" -ForegroundColor Gray

if ($allOk) {
    Write-Host "`nAlle Dateien vorhanden. Console komplett beenden und neu starten," -ForegroundColor Green
    Write-Host "dann Rechtsklick auf eine Device Collection im Ergebnisbereich." -ForegroundColor Green
} else {
    Write-Host "`nEs fehlen Dateien - bitte Install-Extension.ps1 (erneut) ausfuehren." -ForegroundColor Red
}
