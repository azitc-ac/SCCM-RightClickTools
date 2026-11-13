<#
.SYNOPSIS
    Finds CA certificates in the wrong computer store and, with Apply checked, fixes them:
      * certificates that are not self-signed (intermediates) in Trusted Root Certification
        Authorities (LocalMachine\Root) are MOVED to Intermediate Certification Authorities
        (LocalMachine\CA) - the remedy Microsoft gives for AD FS / WAP and Lync / Skype servers
      * self-signed (root) certificates in Intermediate Certification Authorities are listed and
        only removed when RemoveRootsFromIntermediate is checked (off by default)

.DESCRIPTION
    Every switch is a [bool] parameter because the console turns [bool] into a check box in the
    Run Script wizard; it does not know [switch], and it ignores ValidateSet (read from
    AdminUI.Scripts.dll, see README.md).

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

    Only certificates in the computer's own registry store are touched. One that comes from
    Group Policy or from Active Directory (Enterprise store) is listed as "left: comes from ..."
    and left alone: a local change would be undone at the next policy refresh / autoenrollment;
    the fix belongs at the source.

    Moving = add to Intermediate (unless it is there already), check it is there, then remove it
    from Root and check it is gone. If the add fails, Root is not touched. Before any change the
    certificate is exported as .cer to %windir%\Logs\MisplacedCACertificates\<yyyyMMdd-HHmmss>\ -
    restore with certutil -addstore CA|Root <file>.

    The Run Scripts host reports exit code 0 for any "exit N"; the outcome is the first property
    of the output ("Result").

.PARAMETER Apply
    Unchecked (default): report only, nothing changes. Checked: carry out what the switches say.

.PARAMETER MoveIntermediatesFromRoot
    Checked (default): intermediates found in Trusted Root are moved to Intermediate.

.PARAMETER RemoveRootsFromIntermediate
    Unchecked (default): roots found in Intermediate are listed and left alone. Checked: they
    are removed. They are not moved to Trusted Root - that would make them trusted.

.PARAMETER RemoveWindowsDefaultRoots
    Unchecked (default): roots Windows itself puts into Intermediate (Root Agency) are listed and
    never removed. Checked (strict): they are treated like any other root - removed when
    RemoveRootsFromIntermediate is checked too. Roots from AD (Enterprise store, i.e. the AIA
    container) stay untouched either way.

.PARAMETER ExcludeThumbprints
    Thumbprints to leave alone, separated by comma, semicolon or space.
#>
param(
    [bool]$Apply = $false,
    [bool]$MoveIntermediatesFromRoot = $true,
    [bool]$RemoveRootsFromIntermediate = $false,
    [bool]$RemoveWindowsDefaultRoots = $false,
    [string]$ExcludeThumbprints = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

# Lines beyond this are counted, not listed: the status list cuts the output at 4000 characters
# (the full text stays reachable through the detail window), keep the usual case well inside.
$maxLines = 25

# Windows itself puts "Root Agency" (a self-signed test root from the old Microsoft SDK) into
# the Intermediate store. It is reported as a Windows default and not removed, also when
# RemoveRootsFromIntermediate is checked - unless RemoveWindowsDefaultRoots is checked as well.
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

function Test-InStore {
    param([string]$Store, [string]$Thumbprint)
    return (Test-Path -LiteralPath "Cert:\LocalMachine\$Store\$Thumbprint")
}

function Invoke-StoreChange {
    # Add or Remove one certificate in a machine store.
    param([string]$Store, [string]$Action, [System.Security.Cryptography.X509Certificates.X509Certificate2]$Cert)
    $x = New-Object System.Security.Cryptography.X509Certificates.X509Store($Store, 'LocalMachine')
    $x.Open('ReadWrite')
    try {
        if ($Action -eq 'Add') { $x.Add($Cert) } else { $x.Remove($Cert) }
    } finally { $x.Close() }
}

$result = [ordered]@{
    Result   = ''
    Computer = $env:COMPUTERNAME
    Settings = 'Apply={0}, MoveIntermediatesFromRoot={1}, RemoveRootsFromIntermediate={2}, RemoveWindowsDefaultRoots={3}' -f $Apply, $MoveIntermediatesFromRoot, $RemoveRootsFromIntermediate, $RemoveWindowsDefaultRoots
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
    $moved = 0; $removed = 0; $failed = 0; $toDo = 0; $leftPolicy = 0; $leftSwitch = 0
    $names = @{ GroupPolicy = 'Group Policy'; Enterprise = 'AD (Enterprise store)'; Other = 'a store outside the registry' }
    foreach ($f in $found) {
        $thumb = $f.Cert.Thumbprint
        $isIntermediateInRoot = ($f.Store -eq 'Root')
        if ($windowsDefaults.ContainsKey($thumb) -and -not $RemoveWindowsDefaultRoots) { $f.Outcome = 'left: ' + $windowsDefaults[$thumb]; continue }
        if ($exclude.ContainsKey($thumb)) { $f.Outcome = 'left: excluded'; continue }
        if ($isIntermediateInRoot -and -not $MoveIntermediatesFromRoot) { $f.Outcome = 'left: MoveIntermediatesFromRoot is off'; $leftSwitch++; continue }
        if (-not $isIntermediateInRoot -and -not $RemoveRootsFromIntermediate) { $f.Outcome = 'left: RemoveRootsFromIntermediate is off'; $leftSwitch++; continue }
        $byPolicy = @($f.Physical | Where-Object { $_ -ne 'Registry' })
        if ($byPolicy.Count -gt 0) {
            $f.Outcome = 'left: comes from ' + (($byPolicy | ForEach-Object { $names[$_] }) -join ' + ')
            $leftPolicy++
            continue
        }
        $alreadyInCA = $isIntermediateInRoot -and (Test-InStore -Store 'CA' -Thumbprint $thumb)
        if (-not $Apply) {
            if (-not $isIntermediateInRoot) { $f.Outcome = 'would remove' }
            elseif ($alreadyInCA) { $f.Outcome = 'would remove from Root (already in Intermediate)' }
            else { $f.Outcome = 'would move to Intermediate' }
            $toDo++
            continue
        }

        try {
            if (-not $backupDir) {
                $backupDir = Join-Path $env:windir ('Logs\MisplacedCACertificates\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
                $null = New-Item -ItemType Directory -Path $backupDir -Force
            }
            [System.IO.File]::WriteAllBytes((Join-Path $backupDir ('{0}-{1}.cer' -f $f.Store, $thumb)), $f.Cert.RawData)

            if ($isIntermediateInRoot -and -not $alreadyInCA) {
                # Public part only - a CA certificate in Root has no business with a private key.
                $pub = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(, $f.Cert.RawData)
                Invoke-StoreChange -Store 'CA' -Action 'Add' -Cert $pub
                if (-not (Test-InStore -Store 'CA' -Thumbprint $thumb)) {
                    $f.Outcome = 'FAILED: not in Intermediate after adding - Root left unchanged'
                    $failed++
                    continue
                }
            }

            Invoke-StoreChange -Store $f.Store -Action 'Remove' -Cert $f.Cert
            # "Remove ran" is not "it is gone": check the store again.
            if (Test-InStore -Store $f.Store -Thumbprint $thumb) {
                $f.Outcome = 'FAILED: still in {0} after removal' -f $storeNames[$f.Store]
                $failed++
            } elseif (-not $isIntermediateInRoot) {
                $f.Outcome = 'removed'
                $removed++
            } elseif (-not (Test-InStore -Store 'CA' -Thumbprint $thumb)) {
                # The end state is what counts: out of Root AND in Intermediate.
                $f.Outcome = 'FAILED: removed from Root but not in Intermediate - restore from the backup'
                $failed++
            } elseif ($alreadyInCA) {
                $f.Outcome = 'removed from Root (already in Intermediate)'
                $moved++
            } else {
                $f.Outcome = 'moved to Intermediate'
                $moved++
            }
        } catch {
            $f.Outcome = 'FAILED: ' + $_.Exception.Message
            $failed++
        }
    }

    # The verdict is about what this script acts on. What a switch leaves out, and certificates
    # from Group Policy or AD, are notes behind it: an Enterprise CA publishes its own certificate
    # to the AIA container, so on a domain member the root of an AD CS sits in the Intermediate
    # store through the Enterprise store (measured in the lab) - by design of AD CS.
    if (-not $Apply) {
        if ($toDo -gt 0) { $verdict = 'FOUND - {0} to fix (report only, nothing changed)' -f $toDo }
        else { $verdict = 'OK - nothing to fix' }
    } elseif ($failed -gt 0) {
        $verdict = 'FAILED - {0} moved, {1} removed, {2} failed' -f $moved, $removed, $failed
    } elseif (($moved + $removed) -gt 0) {
        $verdict = 'FIXED - {0} moved to Intermediate, {1} removed, backup in {2}' -f $moved, $removed, $backupDir
    } else {
        $verdict = 'OK - nothing to fix'
    }
    if ($leftSwitch -gt 0) { $verdict += '; {0} left by a switch' -f $leftSwitch }
    if ($leftPolicy -gt 0) { $verdict += '; {0} left (from Group Policy/AD, not the local store)' -f $leftPolicy }
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
