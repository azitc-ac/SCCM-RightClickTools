#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Lists the action space GUIDs (NamespaceGuid) in AssetManagementNode.xml whose Id or
    DisplayName contains "Device" or "Collection". Helps to find the right GUID folder
    for a console extension.

    Note: for the right-click on a SINGLE device collection in the result pane the GUID
    a92615d6-9df3-49ba-a8c9-6ecb0e8b956b is the documented constant
    (NOT the DeviceCollectionsNode GUID, which is the tree node).
.PARAMETER ConsolePath
    AdminConsole folder. Found by itself when not given.
#>
param(
    [string]$ConsolePath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

Write-Host "AdminConsole: $ConsolePath`n" -ForegroundColor Cyan

$assetMgmtXml = Join-Path $ConsolePath 'XmlStorage\ConsoleRoot\AssetManagementNode.xml'
if (-not (Test-Path $assetMgmtXml)) {
    Write-Error "AssetManagementNode.xml not found: $assetMgmtXml"
    exit 1
}

[xml]$doc = Get-Content $assetMgmtXml -Raw -Encoding UTF8

Write-Host "Nodes with 'Device' or 'Collection' in Id/DisplayName:`n" -ForegroundColor Yellow

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
