<#
.SYNOPSIS
    Updates this AZITC-Toolkit folder to the current state of the repository, and deploys it.

.DESCRIPTION
    "git pull" for a machine without git. Downloads the branch from GitHub as a zip (the
    repository is public, no credential needed), replaces the files of this folder with the
    AZITC-Toolkit folder of the archive, then runs the two deploy steps:

        Publish-AZITCTKScripts.ps1            the Run Scripts into the site (changed ones only)
        Install-AZITCTKConsoleExtension.ps1   the console extension on this machine (needs admin)

    Run as administrator, without parameters. Scratch files (_*.ps1) and anything not in the
    repository stay as they are.

.PARAMETER NoDeploy
    Only replace the files; run Publish and Install yourself.

.PARAMETER SmsProvider
    Handed to Publish. Optional - Publish finds the provider from the console's connection
    history or the local site installation.

.PARAMETER CertificateCheck
    Publish verifies the AdminService certificate. Off by default - the AdminService usually
    runs with a self-signed certificate.

.EXAMPLE
    .\update.ps1
    Update, publish the scripts, install the console extension. Run as administrator.

.EXAMPLE
    .\update.ps1 -WhatIf
    Lists what would be replaced.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$NoDeploy,
    [string]$SmsProvider = '',
    [switch]$CertificateCheck,
    [string]$Branch = 'main',
    [string]$Token
)
$Deploy = -not $NoDeploy
$SkipCertificateCheck = -not $CertificateCheck

$ErrorActionPreference = 'Stop'
$repoOwner = 'azitc-ac'
$repoName  = 'SCCM-RightClickTools'
$subFolder = 'AZITC-Toolkit'

$root = $PSScriptRoot
if (-not $root) { $root = (Get-Location).Path }

function Write-Step { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "    $Message" -ForegroundColor Green }
function Write-Info { param([string]$Message) Write-Host "    $Message" -ForegroundColor Gray }

# --- download ---------------------------------------------------------------------------------

Write-Step "Downloading $repoOwner/$repoName ($Branch)"
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
$headers = @{ Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28'; 'User-Agent' = 'AZITC-Toolkit-update' }
if ($Token) { $headers['Authorization'] = "Bearer $Token" }

$temp = Join-Path ([System.IO.Path]::GetTempPath()) ('AZITC-Toolkit-update-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $temp -Force -WhatIf:$false
$zip = Join-Path $temp 'repo.zip'
try {
    Invoke-WebRequest -Uri "https://api.github.com/repos/$repoOwner/$repoName/zipball/$Branch" -Headers $headers -OutFile $zip -UseBasicParsing -ErrorAction Stop
} catch {
    $status = ''; try { $status = [int]$_.Exception.Response.StatusCode } catch { }
    switch ($status) {
        401     { throw 'GitHub asked for authentication - is the repository private? Then pass -Token.' }
        403     { throw 'GitHub refused the request (403): 60 unauthenticated calls per hour - wait, or pass -Token.' }
        404     { throw "Neither the repository nor the branch [$Branch] was found." }
        default { throw ('Download failed: {0}' -f $_.Exception.Message) }
    }
}
Write-Ok ('Downloaded: {0:N1} MB' -f ((Get-Item -LiteralPath $zip).Length / 1MB))

Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $temp)
$archiveRoot = Get-ChildItem -LiteralPath $temp -Directory | Select-Object -First 1
if (-not $archiveRoot) { throw 'The downloaded archive holds no folder.' }
$source = Join-Path $archiveRoot.FullName $subFolder
if (-not (Test-Path -LiteralPath $source)) { throw "The archive has no $subFolder folder." }
$commit = ''; if ($archiveRoot.Name -match '-(?<sha>[0-9a-f]{7,40})$') { $commit = $Matches['sha'].Substring(0, 7) }

# --- replace ----------------------------------------------------------------------------------

Write-Step "Updating $root"
$before = ''; if (Test-Path -LiteralPath (Join-Path $root 'VERSION')) { $before = (Get-Content -LiteralPath (Join-Path $root 'VERSION') -Raw).Trim() }
$copied = 0
$prefix = $source.TrimEnd('\') + '\'
foreach ($file in (Get-ChildItem -LiteralPath $source -Recurse -File)) {
    $relative = $file.FullName.Substring($prefix.Length)
    $target = Join-Path $root $relative
    if ($PSCmdlet.ShouldProcess($relative, 'replace')) {
        $parent = Split-Path -Parent $target
        if ($parent -and -not (Test-Path -LiteralPath $parent)) { $null = New-Item -ItemType Directory -Path $parent -Force }
        Copy-Item -LiteralPath $file.FullName -Destination $target -Force
    }
    $copied++
}
Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue -WhatIf:$false
$after = $before; if (-not $WhatIfPreference -and (Test-Path -LiteralPath (Join-Path $root 'VERSION'))) { $after = (Get-Content -LiteralPath (Join-Path $root 'VERSION') -Raw).Trim() }
Write-Ok ('{0} file(s) updated: {1} -> {2}{3}' -f $copied, $(if ($before) { $before } else { '?' }), $after, $(if ($commit) { " ($commit)" } else { '' }))

# --- deploy -----------------------------------------------------------------------------------

if ($Deploy -and -not $WhatIfPreference) {
    Write-Step 'Publishing the Run Scripts'
    $publishArgs = @{}
    if ($SmsProvider) { $publishArgs['SmsProvider'] = $SmsProvider }
    if ($SkipCertificateCheck) { $publishArgs['SkipCertificateCheck'] = $true }
    & (Join-Path $root 'Publish-AZITCTKScripts.ps1') @publishArgs

    Write-Step 'Installing the console extension'
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) { Write-Host '    Not running as administrator - run .\Install-AZITCTKConsoleExtension.ps1 elevated.' -ForegroundColor Yellow }
    else { & (Join-Path $root 'Install-AZITCTKConsoleExtension.ps1') }
}
elseif (-not $WhatIfPreference) {
    Write-Info 'Next: .\Publish-AZITCTKScripts.ps1 (site) and .\Install-AZITCTKConsoleExtension.ps1 (console, as admin) - or run update.ps1 without -NoDeploy.'
}
