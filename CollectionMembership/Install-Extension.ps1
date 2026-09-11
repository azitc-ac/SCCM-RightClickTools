#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs the ConfigMgr console extension "Manage Membership" for device collections.

.PARAMETER PatternRequired
    Name pattern of the "required" collections (default: ins-req-dev-*)

.PARAMETER PatternAvailable
    Name pattern of the "available" collections (default: ins-avl-dev-*)

.PARAMETER ConsolePath
    AdminConsole folder. Found by itself when not given.

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

Write-Host "AdminConsole: $ConsolePath" -ForegroundColor Cyan

# GUID of a single device collection in the result pane (the result object).
# Documented, stable ConfigMgr constant - the same on every installation.
# NOT the DeviceCollectionsNode GUID (that is the tree node, not the right-click on an item).
$actionGuid = '{a92615d6-9df3-49ba-a8c9-6ecb0e8b956b}'
Write-Host "Action-GUID (Device Collection Item): $actionGuid" -ForegroundColor Cyan

# Target folders
$scriptDir = Join-Path $ConsolePath 'extensions\RightClickTools'
$actionDir = Join-Path $ConsolePath "XmlStorage\Extensions\Actions\$actionGuid"

# Create the folders
foreach ($dir in $scriptDir, $actionDir) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Write-Host "Created: $dir"
    }
}

# Compile nopswindow.exe (unless it exists)
$srcCs  = Join-Path $PSScriptRoot 'nopswindow.cs'
$dstExe = Join-Path $scriptDir   'nopswindow.exe'

if (Test-Path $srcCs) {
    if (-not (Test-Path $dstExe)) {
        $csc = @(
            'C:\Windows\Microsoft.NET\Framework\v4.0.30319\csc.exe',
            'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
        ) | Where-Object { Test-Path $_ } | Select-Object -First 1

        if (-not $csc) {
            Write-Error "C# compiler (csc.exe) not found - .NET Framework 4 is required."
            exit 1
        }

        Write-Host "Compiling nopswindow.exe..." -ForegroundColor Yellow
        & $csc /target:winexe /out:$dstExe $srcCs 2>&1 | ForEach-Object { Write-Host "  $_" }

        if (-not (Test-Path $dstExe)) {
            Write-Error "Compiling nopswindow.exe failed."
            exit 1
        }
        Write-Host "Created: $dstExe" -ForegroundColor Green
    } else {
        Write-Host "nopswindow.exe already exists: $dstExe" -ForegroundColor Gray
    }
} else {
    Write-Warning "nopswindow.cs not found: $srcCs"
}

# Copy the GUI script
$srcScript = Join-Path $PSScriptRoot 'Manage-CollectionMembership.ps1'
$dstScript = Join-Path $scriptDir   'Manage-CollectionMembership.ps1'
Copy-Item -Path $srcScript -Destination $dstScript -Force
Write-Host "Copied: $dstScript" -ForegroundColor Green

# Read the action XML, fill in the placeholders, write it
$srcXml = Join-Path $PSScriptRoot 'CollectionMembership.xml'
$dstXml = Join-Path $actionDir   'CollectionMembership.xml'

[xml]$xml = Get-Content $srcXml -Encoding UTF8
$xml.ActionDescription.Executable.FilePath = $xml.ActionDescription.Executable.FilePath.Replace('##EXT_PATH##', $scriptDir)
$xml.ActionDescription.Executable.Parameters = $xml.ActionDescription.Executable.Parameters.Replace('##SCRIPT_PATH##', $dstScript)
$xml.ActionDescription.Executable.Parameters = $xml.ActionDescription.Executable.Parameters.Replace('##PATTERN_REQ##', $PatternRequired)
$xml.ActionDescription.Executable.Parameters = $xml.ActionDescription.Executable.Parameters.Replace('##PATTERN_AVL##', $PatternAvailable)

# Localise the menu entry (language of the console machine, or the -Language override)
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
Write-Host ("Menu language: {0}" -f $(if ($useDeMenu) { 'German' } else { 'English' })) -ForegroundColor Cyan

$xml.Save($dstXml)
Write-Host "Installed: $dstXml" -ForegroundColor Green

Write-Host @"

Installation complete.
  Required pattern  : $PatternRequired
  Available pattern : $PatternAvailable

IMPORTANT: restart the ConfigMgr console for the 'Manage Membership' entry to appear.
"@ -ForegroundColor Yellow
