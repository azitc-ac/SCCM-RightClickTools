<#
.SYNOPSIS
    AZITC Toolkit - AdminService transport layer (dot-source this file).

.DESCRIPTION
    Windows PowerShell 5.1 compatible. Talks to the ConfigMgr AdminService (REST/OData) on the
    SMS Provider using the caller's Windows credentials. Wraps:

      Connect-TKAdminService      - set base URIs, TLS 1.2, optional certificate check bypass
      Get-TKRunScriptMetadata     - dump the RunScript action / ScriptResult function from $metadata
      Get-TKDevice                - resolve a device name to its ResourceId (MachineId)
      Get-TKScript                - resolve a script name to GUID / version / hash / approval state
      Invoke-TKScript             - start a script on one device and wait for the result
      ConvertFrom-TKEnvelope      - decode the gzip+base64 payload of AZITC-TK-Software-Get
      Get-TKSoftware              - convenience: run the Get script and return item objects
      Invoke-TKSoftwareAction     - convenience: run the Action script

    WHAT WAS VERIFIED ON A REAL SITE (CB 2509, provider 5.2509.1036, 2026-09-11)

    * POST Device(<id>)/AdminService.RunScript accepts exactly ONE body property, "ScriptGuid".
      Any other property - ScriptParameters, ScriptVersion - is answered with HTTP 400. The
      $metadata says the same. So RunScript cannot pass parameters at all.
    * Parameters go through SMS_ClientOperation.InitiateClientOperationEx (Type 135), which the
      AdminService exposes on its /wmi route as an unbound action:
          POST /AdminService/wmi/SMS_ClientOperation.InitiateClientOperationEx
          { Type:135, TargetCollectionID:"", TargetResourceIDs:[<id>], RandomizationWindow:0, Param:<base64> }
      Param is the base64 (UTF-8) of
          <ScriptContent ScriptGuid='G'><ScriptVersion>V</ScriptVersion><ScriptType>T</ScriptType>
          <ScriptHash ScriptHashAlg='SHA256'>H</ScriptHash>
          <ScriptParameters><ScriptParameter ParameterGroupGuid='..' ParameterGroupName='PG_..'
             ParameterName='Action' ParameterType='..' ParameterValue='Inspect'/>...</ScriptParameters>
          <ParameterGroupHash ParameterHashAlg='SHA256'>P</ParameterGroupHash></ScriptContent>
      H = SHA256 of the script file bytes (as stored, BOM included), upper-case hex - the value
      the provider keeps in SMS_Scripts.ScriptHash, so it is simply read back.
      P = SHA256 over the UTF-16LE bytes of the <ScriptParameters>...</ScriptParameters> string,
      lower-case hex (the console's Utilities.GetHash). The provider validates the parameters
      against the script's ParamsDefinition (CLR function fnValidateRunScriptParameters).
      The format string itself is a literal in AdminUI.Scripts.dll.
    * Not approved: RunScript answers 403 with an empty body; InitiateClientOperationEx answers
      500 (SMSProv.log: "Script is not approved."). ApprovalState 3 = approved (the site's own
      CMPivot script carries 3), 0 = waiting, 1 = denied.
    * ScriptResult(OperationId=<unknown>) answers 400, not 404. Results are also queryable as
      entities with documented fields: v1.0/DeviceScriptRunDetails and v1.0/ScriptStatus, both
      filtered by ClientOperationId (ScriptExecutionState, ScriptExitCode, ScriptOutput).
    * On the /wmi route a GET by key returns { "value": [ {...} ] } like a collection, and lazy
      properties (Script, ParamsDefinition, ParameterlistXML) are only filled on a GET by key.
    * Windows PowerShell 5.1: a scriptblock in ServerCertificateValidationCallback fails on the
      request thread ("The underlying connection was closed: An unexpected error occurred on a
      send"). The bypass has to be a compiled delegate - see Enable-TKTrustAllCertificates.

.NOTES
    Author : Alexander Zarenko IT Consulting (AZITC)
#>

Set-StrictMode -Version 2.0

$script:TKBaseUri = $null      # https://<provider>/AdminService/v1.0
$script:TKWmiUri  = $null      # https://<provider>/AdminService/wmi

# --- Connection -------------------------------------------------------------

function Enable-TKTrustAllCertificates {
    <#
    .SYNOPSIS
        Accepts any server certificate for this process. A compiled callback, because a
        PowerShell scriptblock does not survive the thread switch under 5.1.
    #>
    if (-not ([System.Management.Automation.PSTypeName]'AZITC.TrustAllCerts').Type) {
        Add-Type -TypeDefinition @"
using System.Net;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
namespace AZITC {
    public static class TrustAllCerts {
        public static bool Validate(object sender, X509Certificate cert, X509Chain chain, SslPolicyErrors errors) { return true; }
        public static void Enable() { ServicePointManager.ServerCertificateValidationCallback = Validate; }
    }
}
"@
    }
    [AZITC.TrustAllCerts]::Enable()
}

function Connect-TKAdminService {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SmsProvider,   # FQDN of the SMS Provider (##SUB:__Server## from the console)
        [switch]$SkipCertificateCheck
    )
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

    if ($SkipCertificateCheck) {
        # Process-wide for this PowerShell session. Acceptable for a self-signed SMS Provider cert
        # on a trusted admin workstation; remove once the provider has a PKI certificate.
        Enable-TKTrustAllCertificates
    }

    $script:TKBaseUri = "https://$SmsProvider/AdminService/v1.0"
    $script:TKWmiUri  = "https://$SmsProvider/AdminService/wmi"

    # Smoke test: one script row (small, needs only read on SMS Scripts)
    $null = Invoke-TKRest -Method Get -Path 'Script?$top=1'
    Write-Verbose "Connected to $script:TKBaseUri"
}

function Invoke-TKRest {
    <#
    .SYNOPSIS
        One REST call. -Route v1 (default) or wmi. Throws with the HTTP status in the message.
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('Get', 'Post', 'Delete')][string]$Method = 'Get',
        [Parameter(Mandatory = $true)][string]$Path,
        [ValidateSet('v1', 'wmi')][string]$Route = 'v1',
        [object]$Body = $null
    )
    if (-not $script:TKBaseUri) { throw 'Not connected. Call Connect-TKAdminService first.' }
    $base = $script:TKBaseUri
    if ($Route -eq 'wmi') { $base = $script:TKWmiUri }
    $uri = "$base/$Path"
    $params = @{
        Method                = $Method
        Uri                   = $uri
        ContentType           = 'application/json'
        UseDefaultCredentials = $true
        UseBasicParsing       = $true
        ErrorAction           = 'Stop'
    }
    if ($null -ne $Body) { $params['Body'] = ($Body | ConvertTo-Json -Depth 6 -Compress) }
    try {
        $response = Invoke-WebRequest @params
    } catch {
        $status = Get-TKHttpStatus -ErrorRecord $_
        $text = ''
        try {
            $stream = $_.Exception.Response.GetResponseStream()
            if ($stream) { $reader = New-Object System.IO.StreamReader($stream); $text = $reader.ReadToEnd(); $reader.Close() }
        } catch { }
        $ex = New-Object System.Exception(("HTTP {0} on {1} {2}: {3}" -f $status, $Method.ToUpper(), $uri, $text), $_.Exception)
        $ex.Data['HttpStatus'] = $status
        throw $ex
    }
    if ([string]::IsNullOrWhiteSpace($response.Content)) { return $null }
    return ($response.Content | ConvertFrom-Json)
}

function Get-TKHttpStatus {
    param($ErrorRecord)
    try { return [int]$ErrorRecord.Exception.Response.StatusCode } catch { return 0 }
}

function Get-TKExceptionStatus {
    # HTTP status stored by Invoke-TKRest, 0 if it is not one of ours
    param($Exception)
    try { if ($Exception.Data.Contains('HttpStatus')) { return [int]$Exception.Data['HttpStatus'] } } catch { }
    return 0
}

# --- Metadata check ---------------------------------------------------------

function Get-TKRunScriptMetadata {
    <#
    .SYNOPSIS
        Returns the RunScript / RunScriptSimulation actions and the ScriptResult function from the
        v1.0 $metadata, plus the SMS_Scripts and SMS_ClientOperation entries from the wmi $metadata.
        On the reference site the RunScript action has the single parameter ScriptGuid.
    #>
    [CmdletBinding()]
    param()
    if (-not $script:TKBaseUri) { throw 'Not connected. Call Connect-TKAdminService first.' }
    $out = @()
    $raw = Invoke-WebRequest -Uri "$script:TKBaseUri/`$metadata" -UseDefaultCredentials -UseBasicParsing -ErrorAction Stop
    foreach ($m in [regex]::Matches($raw.Content, '(?s)<(Action|Function) Name="(RunScript|RunScriptSimulation|ScriptResult)".*?</\1>')) { $out += $m.Value }
    $rawWmi = Invoke-WebRequest -Uri "$script:TKWmiUri/`$metadata" -UseDefaultCredentials -UseBasicParsing -ErrorAction Stop
    foreach ($m in [regex]::Matches($rawWmi.Content, '<ActionImport Name="(SMS_ClientOperation|SMS_Scripts)\.[^"]*"[^>]*/>')) { $out += $m.Value }
    foreach ($m in [regex]::Matches($rawWmi.Content, '(?s)<Action Name="(UpdateScript|UpdateScriptsParameters|UpdateApprovalState)".*?</Action>')) { $out += $m.Value }
    return ($out -join "`n")
}

# --- Lookups ----------------------------------------------------------------

function Get-TKDevice {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Name)
    $r = Invoke-TKRest -Method Get -Path ("Device?`$filter=Name eq '{0}'" -f $Name)
    $d = @($r.value)
    if ($d.Count -eq 0) { throw "Device '$Name' not found." }
    if ($d.Count -gt 1) { Write-Warning "Multiple devices named '$Name' - using the first (ResourceId $($d[0].MachineId))." }
    return $d[0]
}

function Get-TKScript {
    <#
    .SYNOPSIS
        The script row by name: ScriptGuid, ScriptVersion, ScriptType, ScriptHash, ApprovalState.
        Everything Invoke-TKScript needs to build the ScriptContent. ApprovalState 3 = approved.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Name)
    $r = Invoke-TKRest -Method Get -Path ("Script?`$filter=ScriptName eq '{0}'" -f $Name)
    $s = @($r.value)
    if ($s.Count -eq 0) { throw "Script '$Name' not found in the Scripts node." }
    $scr = $s[0]
    if ($scr.PSObject.Properties['ApprovalState'] -and $scr.ApprovalState -ne 3) {
        Write-Warning "Script '$Name' is not approved (ApprovalState=$($scr.ApprovalState); 3 = approved)."
    }
    return $scr
}

# --- Run script -------------------------------------------------------------

function Get-TKSha256Hex {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes, [switch]$Upper)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash($Bytes) } finally { $sha.Dispose() }
    $format = 'x2'
    if ($Upper) { $format = 'X2' }
    return (($hash | ForEach-Object { $_.ToString($format) }) -join '')
}

function New-TKScriptContent {
    <#
    .SYNOPSIS
        The base64 Param for InitiateClientOperationEx, built the way the console builds it.
    #>
    param(
        [Parameter(Mandatory = $true)]$Script,          # row from Get-TKScript (ScriptGuid, ScriptVersion, ScriptType, ScriptHash)
        [hashtable]$Parameters = @{}
    )
    $groupGuid = [guid]::NewGuid().ToString().ToUpper()
    $sb = New-Object System.Text.StringBuilder
    $null = $sb.Append('<ScriptParameters>')
    foreach ($name in ($Parameters.Keys | Sort-Object)) {
        $value = [System.Security.SecurityElement]::Escape([string]$Parameters[$name])
        $null = $sb.AppendFormat('<ScriptParameter ParameterGroupGuid="{0}" ParameterGroupName="PG_{0}" ParameterName="{1}" ParameterType="" ParameterValue="{2}"/>', $groupGuid, $name, $value)
    }
    $null = $sb.Append('</ScriptParameters>')
    $parameterXml = $sb.ToString()
    $groupHash = Get-TKSha256Hex -Bytes ([System.Text.Encoding]::Unicode.GetBytes($parameterXml))
    $content = "<ScriptContent ScriptGuid='{0}'><ScriptVersion>{1}</ScriptVersion><ScriptType>{2}</ScriptType><ScriptHash ScriptHashAlg='SHA256'>{3}</ScriptHash>{4}<ParameterGroupHash ParameterHashAlg='SHA256'>{5}</ParameterGroupHash></ScriptContent>" -f `
        $Script.ScriptGuid, $Script.ScriptVersion, [int]$Script.ScriptType, $Script.ScriptHash, $parameterXml, $groupHash
    return [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($content))
}

function ConvertFrom-TKScriptOutput {
    # ScriptOutput arrives as a JSON-encoded string: either "\"...\"" (single string) or "[\"line\",...]"
    param([string]$ScriptOutput)
    if ([string]::IsNullOrWhiteSpace($ScriptOutput)) { return '' }
    $decoded = $null
    try { $decoded = $ScriptOutput | ConvertFrom-Json } catch { return $ScriptOutput }
    if ($decoded -is [string]) { return $decoded }
    if ($decoded -is [System.Array]) { return (($decoded | ForEach-Object { [string]$_ }) -join "`n") }
    return $ScriptOutput
}

function Start-TKScript {
    <#
    .SYNOPSIS
        Starts a script on one device and returns the ClientOperationId. Does not wait.
    .PARAMETER Transport
        Auto (default): RunScript when there are no parameters, ClientOperation otherwise.
        RunScript: POST Device(id)/AdminService.RunScript { ScriptGuid } - no parameters possible.
        ClientOperation: POST wmi/SMS_ClientOperation.InitiateClientOperationEx (Type 135).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int]$ResourceId,
        [Parameter(Mandatory = $true)]$Script,
        [hashtable]$Parameters = @{},
        [ValidateSet('Auto', 'RunScript', 'ClientOperation')][string]$Transport = 'Auto'
    )
    if ($Transport -eq 'Auto') {
        if ($Parameters.Count -gt 0) { $Transport = 'ClientOperation' } else { $Transport = 'RunScript' }
    }
    if ($Transport -eq 'RunScript' -and $Parameters.Count -gt 0) {
        throw 'The RunScript action accepts only ScriptGuid (verified: any other property is HTTP 400). Use -Transport ClientOperation for parameters.'
    }

    $operationId = $null
    try {
        if ($Transport -eq 'RunScript') {
            $start = Invoke-TKRest -Method Post -Path "Device($ResourceId)/AdminService.RunScript" -Body @{ ScriptGuid = [string]$Script.ScriptGuid }
            if ($start -is [int] -or $start -is [long]) { $operationId = [int]$start }
            elseif ($start -and $start.PSObject.Properties['value']) { $operationId = [int]$start.value }
        } else {
            $body = @{
                Type                = 135
                TargetCollectionID  = ''
                TargetResourceIDs   = @($ResourceId)
                RandomizationWindow = 0
                Param               = (New-TKScriptContent -Script $Script -Parameters $Parameters)
            }
            $start = Invoke-TKRest -Method Post -Route wmi -Path 'SMS_ClientOperation.InitiateClientOperationEx' -Body $body
            if ($start -and $start.PSObject.Properties['OperationID']) { $operationId = [int]$start.OperationID }
            if ($start -and $start.PSObject.Properties['ReturnValue'] -and [int]$start.ReturnValue -ne 0) {
                throw "InitiateClientOperationEx returned $($start.ReturnValue)."
            }
        }
    } catch {
        $st = Get-TKExceptionStatus -Exception $_.Exception
        if ($st -eq 403) { throw 'RunScript returned 403 - script not approved, or no "Run Script" permission on this device.' }
        if ($st -eq 500 -and $Transport -eq 'ClientOperation') { throw "InitiateClientOperationEx failed (HTTP 500). Usual causes: script not approved, parameter rejected by the ParamsDefinition, hash mismatch. SMSProv.log on the provider names the reason. $($_.Exception.Message)" }
        throw
    }
    if (-not $operationId) { throw "No OperationId returned. Response: $($start | ConvertTo-Json -Compress)" }
    Write-Verbose "OperationId $operationId via $Transport"
    return $operationId
}

function Get-TKScriptRunResult {
    <#
    .SYNOPSIS
        One look at the result of a client operation on one device. $null while nothing is there.
        Reads wmi/SMS_ScriptsExecutionStatus (ScriptExecutionState, ScriptExitCode, ScriptOutput,
        State, LastUpdateTime). The v1.0 sets DeviceScriptRunDetails / ScriptStatus are declared
        in $metadata but answer 404 on this site, whatever the query.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int]$ResourceId,
        [Parameter(Mandatory = $true)][int]$OperationId
    )
    try {
        $r = Invoke-TKRest -Method Get -Route wmi -Path ("SMS_ScriptsExecutionStatus?`$filter=ClientOperationId eq {0} and ResourceId eq {1}" -f $OperationId, $ResourceId)
    } catch {
        $st = Get-TKExceptionStatus -Exception $_.Exception
        if ($st -eq 404 -or $st -eq 400) { return $null }   # nothing recorded yet
        throw
    }
    if ($null -eq $r -or -not $r.PSObject.Properties['value']) { return $null }
    $rows = @($r.value)
    if ($rows.Count -eq 0) { return $null }
    return $rows[0]
}

function Invoke-TKScript {
    <#
    .SYNOPSIS
        Runs an approved script on one device and waits for the result.
    .OUTPUTS
        PSCustomObject with OperationId, State, ExitCode, Output (string), Raw (last row)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int]$ResourceId,
        [Parameter(Mandatory = $true)]$Script,
        [hashtable]$Parameters = @{},
        [ValidateSet('Auto', 'RunScript', 'ClientOperation')][string]$Transport = 'Auto',
        [int]$TimeoutSec = 600,
        [int]$PollSec = 5
    )
    $operationId = Start-TKScript -ResourceId $ResourceId -Script $Script -Parameters $Parameters -Transport $Transport

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $last = $null
    do {
        Start-Sleep -Seconds $PollSec
        $last = Get-TKScriptRunResult -ResourceId $ResourceId -OperationId $operationId
        if ($last) {
            $state = $null
            if ($last.PSObject.Properties['ScriptExecutionState']) { $state = $last.ScriptExecutionState }
            # A row appears when the client reports; output and exit code arrive with it.
            $hasOutput = $last.PSObject.Properties['ScriptOutput'] -and -not [string]::IsNullOrEmpty([string]$last.ScriptOutput)
            $hasExit   = $last.PSObject.Properties['ScriptExitCode'] -and $null -ne $last.ScriptExitCode
            if ($hasOutput -or $hasExit) {
                return [pscustomobject]@{
                    OperationId = $operationId
                    State       = $state
                    ExitCode    = $last.ScriptExitCode
                    Output      = (ConvertFrom-TKScriptOutput -ScriptOutput ([string]$last.ScriptOutput))
                    Raw         = $last
                }
            }
        }
    } while ((Get-Date) -lt $deadline)

    throw "Timed out after $TimeoutSec s waiting for OperationId $operationId (last row: $($last | ConvertTo-Json -Depth 4 -Compress))"
}

# --- Envelope decoding ------------------------------------------------------

function ConvertFrom-TKEnvelope {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Json)
    $envelope = $Json | ConvertFrom-Json
    if ($envelope.Enc -ne 'gzip+base64') { throw "Unexpected encoding '$($envelope.Enc)'." }
    $bytes = [Convert]::FromBase64String($envelope.Data)
    $ms = New-Object System.IO.MemoryStream(, $bytes)
    $gz = New-Object System.IO.Compression.GZipStream($ms, [System.IO.Compression.CompressionMode]::Decompress)
    $sr = New-Object System.IO.StreamReader($gz, [System.Text.Encoding]::UTF8)
    $text = $sr.ReadToEnd()
    $sr.Close(); $gz.Close(); $ms.Close()
    $payload = $text | ConvertFrom-Json
    return [pscustomobject]@{
        Host      = $envelope.Host
        TimeUtc   = $envelope.TimeUtc
        Count     = $envelope.Count
        Total     = $envelope.Total
        Truncated = $envelope.Truncated
        AppError  = $envelope.AppError
        Items     = @($payload.Items)
        Apps      = @($payload.Apps)
        Users     = $payload.Users
    }
}

# --- Convenience ------------------------------------------------------------

function Get-TKSoftware {
    <#
    .SYNOPSIS
        Runs AZITC-TK-Software-Get on a device and returns readable objects.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$DeviceName,
        [string]$ScriptName = 'AZITC-TK-Software-Get',
        [int]$TimeoutSec = 300
    )
    $dev = Get-TKDevice -Name $DeviceName
    $scr = Get-TKScript -Name $ScriptName
    $res = Invoke-TKScript -ResourceId $dev.MachineId -Script $scr -TimeoutSec $TimeoutSec
    if ($res.ExitCode -ne 0) { throw "Script exit $($res.ExitCode), state $($res.State). Output: $($res.Output)" }
    $envelope = ConvertFrom-TKEnvelope -Json $res.Output
    if ($envelope.Truncated) { Write-Warning "List truncated on the client: $($envelope.Count) of $($envelope.Total) entries." }
    if ($envelope.AppError) { Write-Warning "ConfigMgr app enumeration failed on the client: $($envelope.AppError)" }

    $items = foreach ($i in $envelope.Items) {
        [pscustomobject]@{
            Name            = $i.N
            Version         = $i.V
            Publisher       = $i.P
            InstallDate     = $i.D
            Scope           = $i.S
            Arch            = $i.A
            IsMsi           = $i.M
            HasQuietString  = $i.Q
            HasUninstall    = $i.U
            RepairPossible  = $i.R
            SizeMB          = [math]::Round($i.Z / 1024, 1)
            Key             = $i.K
        }
    }
    return [pscustomobject]@{
        Host        = $envelope.Host
        Items       = @($items)
        Apps        = $envelope.Apps
        Users       = $envelope.Users
        OperationId = $res.OperationId
        OutputChars = $res.Output.Length
    }
}

function Invoke-TKSoftwareAction {
    <#
    .SYNOPSIS
        Runs AZITC-TK-Software-Action on a device and returns the parsed result.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$DeviceName,
        [Parameter(Mandatory = $true)][ValidateSet('Inspect', 'Uninstall', 'Repair')][string]$Action,
        [Parameter(Mandatory = $true)][string]$Key,
        [string]$ExtraArgs = '',
        [int]$TimeoutMin = 15,
        [switch]$KillRunning,
        [switch]$ReEvaluate,
        [string]$ScriptName = 'AZITC-TK-Software-Action'
    )
    $dev = Get-TKDevice -Name $DeviceName
    $scr = Get-TKScript -Name $ScriptName
    $kill = 0; if ($KillRunning) { $kill = 1 }
    $reev = 0; if ($ReEvaluate) { $reev = 1 }
    $params = @{
        Action      = $Action
        Key         = $Key
        ExtraArgs   = $ExtraArgs
        TimeoutMin  = $TimeoutMin
        KillRunning = $kill
        ReEvaluate  = $reev
    }
    $wait = ($TimeoutMin * 60) + 180
    $res = Invoke-TKScript -ResourceId $dev.MachineId -Script $scr -Parameters $params -TimeoutSec $wait
    $parsed = $null
    try { $parsed = $res.Output | ConvertFrom-Json } catch { }
    if ($null -eq $parsed) {
        return [pscustomobject]@{ State = $res.State; ExitCode = $res.ExitCode; RawOutput = $res.Output; OperationId = $res.OperationId }
    }
    $parsed | Add-Member -NotePropertyName ScriptState -NotePropertyValue $res.State -Force
    $parsed | Add-Member -NotePropertyName ScriptExitCode -NotePropertyValue $res.ExitCode -Force
    $parsed | Add-Member -NotePropertyName OperationId -NotePropertyValue $res.OperationId -Force
    return $parsed
}

<#
=== Usage (end-to-end test without GUI) ===================================

. .\AZITC-TK-AdminService.ps1

Connect-TKAdminService -SmsProvider 'cm01.corp.local' -SkipCertificateCheck -Verbose

# 1. See what the site offers (RunScript has only ScriptGuid; parameters go through InitiateClientOperationEx):
Get-TKRunScriptMetadata

# 2. List software:
$sw = Get-TKSoftware -DeviceName 'PC0001'
$sw.Items | Out-GridView -Title "Software on $($sw.Host)"

# 3. Dry run for one entry:
$e = $sw.Items | Where-Object Name -like '7-Zip*' | Select-Object -First 1
Invoke-TKSoftwareAction -DeviceName 'PC0001' -Action Inspect -Key $e.Key

# 4. Uninstall (lab device!) and force re-evaluation:
Invoke-TKSoftwareAction -DeviceName 'PC0001' -Action Uninstall -Key $e.Key -ReEvaluate

============================================================================
#>
