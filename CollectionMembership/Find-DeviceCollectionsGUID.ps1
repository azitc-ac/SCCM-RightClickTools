#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Listet die ActionSpace-GUIDs (NamespaceGuid) aus AssetManagementNode.xml auf, die
    "Device" oder "Collection" im Id/DisplayName tragen. Hilft, den richtigen GUID-Ordner
    fuer eine Konsolenerweiterung zu finden.

    Hinweis: Fuer den Rechtsklick auf eine EINZELNE Device-Collection im Ergebnisbereich
    ist die GUID a92615d6-9df3-49ba-a8c9-6ecb0e8b956b der dokumentierte Standard
    (NICHT die DeviceCollectionsNode-GUID = Baum-Knoten).
.PARAMETER ConsolePath
    Pfad zur AdminConsole. Wird automatisch ermittelt falls nicht angegeben.
#>
param(
    [string]$ConsolePath = ''
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

Write-Host "AdminConsole: $ConsolePath`n" -ForegroundColor Cyan

$assetMgmtXml = Join-Path $ConsolePath 'XmlStorage\ConsoleRoot\AssetManagementNode.xml'
if (-not (Test-Path $assetMgmtXml)) {
    Write-Error "AssetManagementNode.xml nicht gefunden: $assetMgmtXml"
    exit 1
}

[xml]$doc = Get-Content $assetMgmtXml -Raw -Encoding UTF8

Write-Host "Nodes mit 'Device' oder 'Collection' im Id/DisplayName:`n" -ForegroundColor Yellow

$nodes = $doc.SelectNodes(
    "//*[contains(@Id, 'Device') or contains(@Id, 'Collection') or " +
    "contains(@DisplayName, 'Device') or contains(@DisplayName, 'Collection')][@NamespaceGuid]")

$nodes |
    Select-Object @{L='Id';E={$_.Id}},
                  @{L='DisplayName';E={$_.DisplayName}},
                  @{L='NamespaceGuid';E={$_.NamespaceGuid}} |
    Format-Table -AutoSize

Write-Host "Tipp: Die NamespaceGuid (ohne Klammern) ist der Ordnername unter" -ForegroundColor Green
Write-Host "      XmlStorage\Extensions\Actions\{<NamespaceGuid>}\" -ForegroundColor Green
