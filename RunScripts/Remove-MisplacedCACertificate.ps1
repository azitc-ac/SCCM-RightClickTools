<#
.SYNOPSIS
    Finds - and with -Mode Remove deletes - CA certificates that sit in the wrong computer store:
      * self-signed (root) certificates in Intermediate Certification Authorities (LocalMachine\CA)
      * certificates that are not self-signed (intermediates) in Trusted Root Certification
        Authorities (LocalMachine\Root)

.DESCRIPTION
    Written to run as a ConfigMgr "Run Script" and to be readable in the console's script output
    window. That window shows a tree plus an indented "Raw Output" only when the output is JSON;
    any other text is shown as one line, with line breaks as literal \r\n and Write-Host lines
    glued together by spaces (measured in the lab, see README.md). So the script writes
    exactly one object - the client turns it into JSON - with the verdict first, one line per
    certificate, and nothing else: no Write-Host, no Write-Warning, no second pipeline object.
    It never throws either: a script that throws is shown as Failed with an EMPTY output - even
    what it wrote before the error is gone (measured) - so errors go into the object.

    "Self-signed" means: subject and issuer are the same name AND the Authority Key Identifier is
    absent or equal to the Subject Key Identifier. A name comparison alone would call a CA key
    rollover certificate (same name, signed by the old key) a root and delete it from the
    Intermediate store, where it belongs.

    Only certificates in the computer's own registry store are removed. One that comes from
    Group Policy or from Active Directory (Enterprise store) is reported as "deployed by ..." and
    left alone: deleting it locally would be undone at the next policy refresh / autoenrollment;
    the fix belongs at the source.

    Before removing, every certificate is exported as .cer to
    %windir%\Logs\MisplacedCACertificates\<yyyyMMdd-HHmmss>\ - restore with
    certutil -addstore CA|Root <file>.

    The Run Scripts host reports exit code 0 for any "exit N"; the outcome is the first property
    of the output ("Result"), which also shows in the status list's output column.

.PARAMETER Mode
    Report (default) lists what is misplaced and changes nothing. Remove deletes it.

.PARAMETER ExcludeThumbprints
    Thumbprints to leave alone, separated by comma, semicolon or space.
#>
param(
    [ValidateSet('Report', 'Remove')]
    [string]$Mode = 'Report',
    [string]$ExcludeThumbprints = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

# Lines beyond this are counted, not listed: the status list cuts the output at 4000 characters
# (the full text stays reachable through the detail window), keep the usual case well inside.
$maxLines = 25

# Windows itself puts "Root Agency" (a self-signed test root from the old Microsoft SDK) into
# the Intermediate store. It is reported as a Windows default, never removed.
$windowsDefaults = @{
    'FEE449EE0E3965A5246F000E87FDE2A065FD89D4' = 'Root Agency (Windows default)'
}

$storeNames = @{ CA = 'Intermediate'; Root = 'Root' }

function Get-DerLength {
    # Returns @(length, index of the first content byte) for the DER length at $i.
    param([byte[]]$Data, [int]$i)
    $first = [int]$Data[$i]
    if ($first -lt 0x80) { return @($first, ($i + 1)) }
    $count = $first -band 0x7F
    $len = 0
    for ($k = 1; $k -le $count; $k++) { $len = ($len * 256) + [int]$Data[$i + $k] }
    return @($len, ($i + 1 + $count))
}

function Get-AuthorityKeyId {
    # AuthorityKeyIdentifier ::= SEQUENCE { keyIdentifier [0] IMPLICIT OCTET STRING OPTIONAL, ... }
    # .NET Framework has no class for it; read the [0] element from the raw extension.
    param([System.Security.Cryptography.X509Certificates.X509Certificate2]$Cert)
    $ext = $Cert.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.35' } | Select-Object -First 1
    if (-not $ext) { return $null }
    $d = $ext.RawData
    if ($d.Length -lt 2 -or $d[0] -ne 0x30) { return $null }
    $seq = Get-DerLength -Data $d -i 1
    $i = $seq[1]
    if ($i -ge $d.Length -or $d[$i] -ne 0x80) { return $null }
    $kid = Get-DerLength -Data $d -i ($i + 1)
    if ($kid[0] -le 0) { return $null }
    $bytes = $d[$kid[1]..($kid[1] + $kid[0] - 1)]
    return (($bytes | ForEach-Object { $_.ToString('X2') }) -join '')
}

function Get-SubjectKeyId {
    param([System.Security.Cryptography.X509Certificates.X509Certificate2]$Cert)
    $ext = $Cert.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.14' } | Select-Object -First 1
    if (-not $ext) { return $null }
    return ([System.Security.Cryptography.X509Certificates.X509SubjectKeyIdentifierExtension]$ext).SubjectKeyIdentifier.ToUpperInvariant()
}

function Test-SelfSigned {
    param([System.Security.Cryptography.X509Certificates.X509Certificate2]$Cert)
    $sameName = [Convert]::ToBase64String($Cert.SubjectName.RawData) -eq [Convert]::ToBase64String($Cert.IssuerName.RawData)
    if (-not $sameName) { return $false }
    $aki = Get-AuthorityKeyId -Cert $Cert
    $ski = Get-SubjectKeyId -Cert $Cert
    if ($null -eq $aki -or $null -eq $ski) { return $true }
    return ($aki -eq $ski)
}

function Get-PhysicalStore {
    # Where the certificate of a logical machine store really lives.
    param([string]$Store, [string]$Thumbprint)
    $where = @()
    if (Test-Path -LiteralPath "HKLM:\SOFTWARE\Microsoft\SystemCertificates\$Store\Certificates\$Thumbprint") { $where += 'Registry' }
    if (Test-Path -LiteralPath "HKLM:\SOFTWARE\Policies\Microsoft\SystemCertificates\$Store\Certificates\$Thumbprint") { $where += 'GroupPolicy' }
    if (Test-Path -LiteralPath "HKLM:\SOFTWARE\Microsoft\EnterpriseCertificates\$Store\Certificates\$Thumbprint") { $where += 'Enterprise' }
    if ($where.Count -eq 0) { $where += 'Other' }
    return $where
}

function Get-ShortName {
    # CN if there is one, else the whole name.
    param([string]$DistinguishedName)
    if ($DistinguishedName -match '(?:^|,\s*)CN=("[^"]*"|[^,]*)') { return $Matches[1].Trim('"') }
    return $DistinguishedName
}

$result = [ordered]@{
    Result   = ''
    Computer = $env:COMPUTERNAME
    Mode     = $Mode
    Findings = @()
}

# The client reads the script's stdout as ANSI while powershell.exe writes it in the OEM code
# page: measured, U+00DC arrived as U+0161. With the ANSI code page set here, umlauts, accents and
# the euro sign arrive intact; characters outside it become a best-fit letter or '?'.
try { [Console]::OutputEncoding = [System.Text.Encoding]::Default } catch { }

try {
    $exclude = @{}
    foreach ($t in ($ExcludeThumbprints -split '[\s,;]+')) {
        $clean = ($t -replace '[^0-9A-Fa-f]', '').ToUpperInvariant()
        if ($clean) { $exclude[$clean] = $true }
    }

    $found = New-Object System.Collections.ArrayList
    foreach ($store in 'CA', 'Root') {
        foreach ($cert in @(Get-ChildItem -Path "Cert:\LocalMachine\$store")) {
            $selfSigned = Test-SelfSigned -Cert $cert
            $misplaced = ($store -eq 'CA' -and $selfSigned) -or ($store -eq 'Root' -and -not $selfSigned)
            if (-not $misplaced) { continue }
            $null = $found.Add([pscustomobject]@{
                    Store    = $store
                    Cert     = $cert
                    Physical = @(Get-PhysicalStore -Store $store -Thumbprint $cert.Thumbprint)
                    Outcome  = ''
                })
        }
    }

    $backupDir = $null
    $removed = 0; $failed = 0; $toRemove = 0; $left = 0
    foreach ($f in $found) {
        $thumb = $f.Cert.Thumbprint
        if ($windowsDefaults.ContainsKey($thumb)) { $f.Outcome = 'left: ' + $windowsDefaults[$thumb]; continue }
        if ($exclude.ContainsKey($thumb)) { $f.Outcome = 'left: excluded'; continue }
        $byPolicy = @($f.Physical | Where-Object { $_ -ne 'Registry' })
        if ($byPolicy.Count -gt 0) {
            $names = @{ GroupPolicy = 'Group Policy'; Enterprise = 'AD (Enterprise store)'; Other = 'a store outside the registry' }
            $f.Outcome = 'left: comes from ' + (($byPolicy | ForEach-Object { $names[$_] }) -join ' + ')
            $left++
            continue
        }
        if ($Mode -eq 'Report') { $f.Outcome = 'would remove'; $toRemove++; continue }

        try {
            if (-not $backupDir) {
                $backupDir = Join-Path $env:windir ('Logs\MisplacedCACertificates\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
                $null = New-Item -ItemType Directory -Path $backupDir -Force
            }
            [System.IO.File]::WriteAllBytes((Join-Path $backupDir ('{0}-{1}.cer' -f $f.Store, $thumb)), $f.Cert.RawData)

            $x = New-Object System.Security.Cryptography.X509Certificates.X509Store($f.Store, 'LocalMachine')
            $x.Open('ReadWrite')
            try { $x.Remove($f.Cert) } finally { $x.Close() }

            # "Remove ran" is not "it is gone": check the store again.
            if (Test-Path -LiteralPath "Cert:\LocalMachine\$($f.Store)\$thumb") {
                $f.Outcome = 'FAILED: still in the store after removal'
                $failed++
            } else {
                $f.Outcome = 'removed'
                $removed++
            }
        } catch {
            $f.Outcome = 'FAILED: ' + $_.Exception.Message
            $failed++
        }
    }

    # The verdict is about what this script can act on. Certificates from Group Policy or AD
    # are a note behind it: an Enterprise CA publishes its own certificate to the AIA container,
    # so on a domain member the root of an AD CS usually sits in the Intermediate store through
    # the Enterprise store - normal, and not something to flag on every device.
    if ($Mode -eq 'Report') {
        if ($toRemove -gt 0) { $verdict = 'FOUND - {0} to remove (report only, nothing changed)' -f $toRemove }
        else { $verdict = 'OK - nothing to remove' }
    } elseif ($failed -gt 0) {
        $verdict = 'FAILED - {0} removed, {1} failed' -f $removed, $failed
    } elseif ($removed -gt 0) {
        $verdict = 'REMOVED - {0} certificate(s), backup in {1}' -f $removed, $backupDir
    } else {
        $verdict = 'OK - nothing to remove'
    }
    if ($left -gt 0) { $verdict += '; {0} left in place (from Group Policy/AD, not the local store)' -f $left }
    $result.Result = $verdict

    $lines = @()
    foreach ($f in $found) {
        $c = $f.Cert
        $lines += ('{0} {1}: {2} | issuer {3} | expires {4:yyyy-MM-dd} | {5} | {6} | {7}' -f `
                $storeNames[$f.Store],
                $(if ($f.Store -eq 'CA') { 'store holds root' } else { 'store holds intermediate' }),
                (Get-ShortName $c.Subject), (Get-ShortName $c.Issuer), $c.NotAfter,
                $c.Thumbprint, ($f.Physical -join '+'), $f.Outcome)
    }
    if ($lines.Count -gt $maxLines) {
        $more = $lines.Count - $maxLines
        $lines = @($lines[0..($maxLines - 1)]) + ('... {0} more not listed' -f $more)
    }
    $result.Findings = @($lines)
    if ($backupDir) { $result['Backup'] = $backupDir }
} catch {
    $result.Result = 'ERROR - ' + $_.Exception.Message
}

# One object, nothing else on the pipeline: the client makes it JSON, the console shows it as a
# tree and as indented raw text.
[pscustomobject]$result
