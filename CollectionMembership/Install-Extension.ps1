#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installiert die ConfigMgr-Konsolenerweiterung "Mitgliedschaft verwalten" für Device-Collections.

.PARAMETER PatternRequired
    Suchmuster für Pflicht-Collections (Standard: ins-req-dev-*)

.PARAMETER PatternAvailable
    Suchmuster für Verfügbar-Collections (Standard: ins-avl-dev-*)

.PARAMETER ConsolePath
    Pfad zur AdminConsole. Wird automatisch ermittelt falls nicht angegeben.

.EXAMPLE
    .\Install-Extension.ps1
    .\Install-Extension.ps1 -PatternRequired "ins-req-dev-*" -PatternAvailable "ins-avl-dev-*"
#>
param(
    [string]$PatternRequired  = 'ins-req-dev-*',
    [string]$PatternAvailable = 'ins-avl-dev-*',
    [string]$ConsolePath      = '',
    [ValidateSet('auto','de','en')]
    [string]$Language         = 'auto'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

Write-Host "AdminConsole: $ConsolePath" -ForegroundColor Cyan

# GUID der einzelnen Device-Collection im Ergebnisbereich (Result-Object).
# Dokumentierter, stabiler ConfigMgr-Standard - auf jeder Installation identisch.
# NICHT die DeviceCollectionsNode-GUID (das waere der Baum-Knoten, kein Item-Rechtsklick).
$actionGuid = '{a92615d6-9df3-49ba-a8c9-6ecb0e8b956b}'
Write-Host "Action-GUID (Device Collection Item): $actionGuid" -ForegroundColor Cyan

# Zielverzeichnisse
$scriptDir = Join-Path $ConsolePath 'extensions\RightClickTools'
$actionDir = Join-Path $ConsolePath "XmlStorage\Extensions\Actions\$actionGuid"

# Verzeichnisse anlegen
foreach ($dir in $scriptDir, $actionDir) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Write-Host "Erstellt: $dir"
    }
}

# nopswindow.exe kompilieren (falls noch nicht vorhanden)
$srcCs  = Join-Path $PSScriptRoot 'nopswindow.cs'
$dstExe = Join-Path $scriptDir   'nopswindow.exe'

if (Test-Path $srcCs) {
    if (-not (Test-Path $dstExe)) {
        $csc = @(
            'C:\Windows\Microsoft.NET\Framework\v4.0.30319\csc.exe',
            'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
        ) | Where-Object { Test-Path $_ } | Select-Object -First 1

        if (-not $csc) {
            Write-Error "C# Compiler (csc.exe) nicht gefunden. .NET Framework SDK erforderlich."
            exit 1
        }

        Write-Host "Kompiliere nopswindow.exe..." -ForegroundColor Yellow
        & $csc /target:winexe /out:$dstExe $srcCs 2>&1 | ForEach-Object { Write-Host "  $_" }

        if (-not (Test-Path $dstExe)) {
            Write-Error "Kompilierung von nopswindow.exe fehlgeschlagen."
            exit 1
        }
        Write-Host "Erstellt: $dstExe" -ForegroundColor Green
    } else {
        Write-Host "nopswindow.exe existiert bereits: $dstExe" -ForegroundColor Gray
    }
} else {
    Write-Warning "nopswindow.cs nicht gefunden: $srcCs"
}

# PS1 kopieren
$srcScript = Join-Path $PSScriptRoot 'Manage-CollectionMembership.ps1'
$dstScript = Join-Path $scriptDir   'Manage-CollectionMembership.ps1'
Copy-Item -Path $srcScript -Destination $dstScript -Force
Write-Host "Kopiert: $dstScript" -ForegroundColor Green

# XML einlesen, Platzhalter ersetzen, schreiben
$srcXml = Join-Path $PSScriptRoot 'CollectionMembership.xml'
$dstXml = Join-Path $actionDir   'CollectionMembership.xml'

[xml]$xml = Get-Content $srcXml -Encoding UTF8
$xml.ActionDescription.Executable.FilePath = $xml.ActionDescription.Executable.FilePath.Replace('##EXT_PATH##', $scriptDir)
$xml.ActionDescription.Executable.Parameters = $xml.ActionDescription.Executable.Parameters.Replace('##SCRIPT_PATH##', $dstScript)
$xml.ActionDescription.Executable.Parameters = $xml.ActionDescription.Executable.Parameters.Replace('##PATTERN_REQ##', $PatternRequired)
$xml.ActionDescription.Executable.Parameters = $xml.ActionDescription.Executable.Parameters.Replace('##PATTERN_AVL##', $PatternAvailable)

# Menue-Eintrag lokalisieren (Sprache der Console-Maschine, oder -Language override)
$useDeMenu = switch ($Language) {
    'de'    { $true }
    'en'    { $false }
    default { [System.Globalization.CultureInfo]::InstalledUICulture.TwoLetterISOLanguageName -eq 'de' }
}
if ($useDeMenu) {
    $xml.ActionDescription.DisplayName         = 'Mitgliedschaft verwalten'
    $xml.ActionDescription.MnemonicDisplayName = 'Mitgliedschaft verwalten'
    $xml.ActionDescription.Description          = 'Verwaltet in welchen Collections diese Collection als Mitglied (Include-Rule) enthalten ist'
} else {
    $xml.ActionDescription.DisplayName         = 'Manage Membership'
    $xml.ActionDescription.MnemonicDisplayName = 'Manage Membership'
    $xml.ActionDescription.Description          = 'Manages which collections include this collection as a member (include rule)'
}
Write-Host ("Menue-Sprache: {0}" -f $(if ($useDeMenu) { 'Deutsch' } else { 'English' })) -ForegroundColor Cyan

$xml.Save($dstXml)
Write-Host "Installiert: $dstXml" -ForegroundColor Green

Write-Host @"

Installation abgeschlossen.
  Pflicht-Muster   : $PatternRequired
  Verfügbar-Muster : $PatternAvailable

WICHTIG: ConfigMgr-Konsole neu starten, damit der Menüpunkt 'Mitgliedschaft verwalten' erscheint.
"@ -ForegroundColor Yellow
