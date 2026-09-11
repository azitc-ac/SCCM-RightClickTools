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

function Get-TKScriptParameterDefinition {
    <#
    .SYNOPSIS
        Name -> .NET type name of every parameter the script declares, read from its
        ParamsDefinition (stored base64 of the XML; older rows may hold the XML as is).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ScriptGuid)
    $types = @{}
    $r = Invoke-TKRest -Method Get -Route wmi -Path "SMS_Scripts('$ScriptGuid')"
    $row = @($r.value)[0]
    $def = ''
    if ($row -and $row.PSObject.Properties['ParamsDefinition']) { $def = [string]$row.ParamsDefinition }
    if ([string]::IsNullOrWhiteSpace($def)) { return $types }
    if (-not $def.TrimStart().StartsWith('<')) {
        try { $def = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($def)) } catch { return $types }
    }
    try {
        $xml = [xml]$def
        foreach ($p in $xml.SelectNodes('/ScriptParameters//ScriptParameter')) { $types[[string]$p.GetAttribute('Name')] = [string]$p.GetAttribute('Type') }
    } catch { }
    return $types
}

function New-TKScriptContent {
    <#
    .SYNOPSIS
        The base64 Param for InitiateClientOperationEx, built the way the console builds it.
        ParameterType has to be the .NET type name from the script's definition - the
        validator rejects anything else ("Unsupported Type").
    #>
    param(
        [Parameter(Mandatory = $true)]$Script,          # row from Get-TKScript (ScriptGuid, ScriptVersion, ScriptType, ScriptHash)
        [hashtable]$Parameters = @{},
        [hashtable]$ParameterTypes = @{}                # from Get-TKScriptParameterDefinition; inferred from the value when missing
    )
    $groupGuid = [guid]::NewGuid().ToString().ToUpper()
    $sb = New-Object System.Text.StringBuilder
    $null = $sb.Append('<ScriptParameters>')
    foreach ($name in ($Parameters.Keys | Sort-Object)) {
        $raw = $Parameters[$name]
        $type = ''
        if ($ParameterTypes.ContainsKey($name)) { $type = [string]$ParameterTypes[$name] }
        if (-not $type) {
            if ($raw -is [bool]) { $type = 'System.Boolean' }
            elseif ($raw -is [int] -or $raw -is [long] -or $raw -is [int16] -or $raw -is [byte]) { $type = 'System.Int32' }
            else { $type = 'System.String' }
        }
        $value = [System.Security.SecurityElement]::Escape([string]$raw)
        $null = $sb.AppendFormat('<ScriptParameter ParameterGroupGuid="{0}" ParameterGroupName="PG_{0}" ParameterName="{1}" ParameterType="{2}" ParameterDataType="{2}" ParameterValue="{3}"/>', $groupGuid, $name, $type, $value)
    }
    $null = $sb.Append('</ScriptParameters>')
    $parameterXml = $sb.ToString()
    $groupHash = Get-TKSha256Hex -Bytes ([System.Text.Encoding]::Unicode.GetBytes($parameterXml))
    $content = "<ScriptContent ScriptGuid='{0}'><ScriptVersion>{1}</ScriptVersion><ScriptType>{2}</ScriptType><ScriptHash ScriptHashAlg='SHA256'>{3}</ScriptHash>{4}<ParameterGroupHash ParameterHashAlg='SHA256'>{5}</ParameterGroupHash></ScriptContent>" -f `
        $Script.ScriptGuid, $Script.ScriptVersion, [int]$Script.ScriptType, $Script.ScriptHash, $parameterXml, $groupHash
    return [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($content))
}

function ConvertFrom-TKScriptOutput {
    <#
    .SYNOPSIS
        Turns the stored ScriptOutput back into the text the script wrote.
        Observed: the site keeps the JSON-escaped body of the output string WITHOUT the
        surrounding quotes - a script that printed {"a":1} is stored as {\"a\":1}. A JSON array
        of lines ("[\"line\",...]") is joined with newlines.
    #>
    param([string]$ScriptOutput)
    if ([string]::IsNullOrWhiteSpace($ScriptOutput)) { return '' }
    $trimmed = $ScriptOutput.Trim()
    $decoded = $null
    if ($trimmed.StartsWith('"') -or $trimmed.StartsWith('[')) {
        try { $decoded = $trimmed | ConvertFrom-Json } catch { $decoded = $null }
    }
    if ($null -eq $decoded -and $trimmed.Contains('\"')) {
        try { $decoded = ('"' + $trimmed + '"') | ConvertFrom-Json } catch { $decoded = $null }
    }
    if ($null -eq $decoded) { return $ScriptOutput }
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
            $types = @{}
            if ($Parameters.Count -gt 0) { $types = Get-TKScriptParameterDefinition -ScriptGuid ([string]$Script.ScriptGuid) }
            $body = @{
                Type                = 135
                TargetCollectionID  = ''
                TargetResourceIDs   = @($ResourceId)
                RandomizationWindow = 0
                Param               = (New-TKScriptContent -Script $Script -Parameters $Parameters -ParameterTypes $types)
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

function Get-TKScriptFullOutput {
    <#
    .SYNOPSIS
        The complete output of one run. The status row (and the ScriptResult function) cut
        ScriptOutput at 4000 characters - vSMS_ScriptsExecutionStatus does LEFT(..., 4000) for
        every script whose Feature is 0, which is every script created through the API. The
        table holds everything, and vSMS_ScriptsExecutionSummary exposes it as FullOutput,
        one row per distinct output (TaskID, ScriptGuid, ScriptOutputHash).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$StatusRow)
    # FullOutput is a lazy property: it is null in a filtered list and only filled on a GET by
    # key. The key is (OutputAndExitCode, ScriptGuid, TaskID); for the output group (GroupType 1)
    # OutputAndExitCode is the ScriptOutputHash of the status row.
    $path = "SMS_ScriptsExecutionSummary(TaskID='{0}',ScriptGuid='{1}',OutputAndExitCode='{2}')" -f $StatusRow.TaskID, $StatusRow.ScriptGuid, $StatusRow.ScriptOutputHash
    try {
        $r = Invoke-TKRest -Method Get -Route wmi -Path $path
    } catch {
        Write-Warning "Full output not available ($($_.Exception.Message.Split([char]10)[0])); returning the first 4000 characters."
        return [string]$StatusRow.ScriptOutput
    }
    $rows = @($r.value)
    if ($rows.Count -gt 0 -and $rows[0].PSObject.Properties['FullOutput'] -and $null -ne $rows[0].FullOutput) { return [string]$rows[0].FullOutput }
    return [string]$StatusRow.ScriptOutput
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
            # The row appears when the client has reported; observed ScriptExecutionState
            # values: 1 = succeeded, 2 = failed (exit code -2147467259 when the script threw).
            $state = $null
            if ($last.PSObject.Properties['ScriptExecutionState']) { $state = [int]$last.ScriptExecutionState }
            if ($state -eq 1 -or $state -eq 2) {
                $raw = [string]$last.ScriptOutput
                if ($raw.Length -ge 4000) { $raw = Get-TKScriptFullOutput -StatusRow $last }
                $stateText = 'Failed'
                if ($state -eq 1) { $stateText = 'Succeeded' }
                return [pscustomobject]@{
                    OperationId = $operationId
                    State       = $stateText
                    ExitCode    = $last.ScriptExitCode
                    Output      = (ConvertFrom-TKScriptOutput -ScriptOutput $raw)
                    OutputChars = $raw.Length
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
    # Kind = Software fills Items/Apps/Users, Kind = Log fills Lines; Payload is the whole thing.
    $get = { param($obj, $name) if ($obj.PSObject.Properties[$name]) { return $obj.$name } else { return $null } }
    return [pscustomobject]@{
        Kind      = (& $get $envelope 'Kind')
        Host      = $envelope.Host
        TimeUtc   = $envelope.TimeUtc
        Count     = $envelope.Count
        Total     = $envelope.Total
        Truncated = $envelope.Truncated
        AppError  = (& $get $envelope 'AppError')
        Error     = (& $get $envelope 'Error')
        Items     = @(& $get $payload 'Items')
        Apps      = @(& $get $payload 'Apps')
        Users     = (& $get $payload 'Users')
        Lines     = @(& $get $payload 'Lines')
        Payload   = $payload
    }
}

# --- Script registration ------------------------------------------------------

function Register-TKScript {
    <#
    .SYNOPSIS
        Creates (or replaces) a Run Script in the Scripts node from a .ps1 file, with its
        parameter definition, through SMS_Scripts.CreateScripts on the /wmi route - the way
        the console does it. New-CMScript would leave ParamsDefinition empty.
    .PARAMETER Parameters
        One hashtable per parameter: @{ Name; Type ('System.String'|'System.Int32'|'System.Boolean');
        Required ([bool]); Default ([string]); Values ([string[]], optional allowed values) }.
        The order given is kept in the definition.
    .PARAMETER Replace
        Delete an existing script of the same name first (its approval is lost).
    .OUTPUTS
        The new script row (Get-TKScript).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$File,
        [string]$Description = '',
        [int]$Timeout = 300,
        [string]$Version = '1',
        [hashtable[]]$Parameters = @(),
        [switch]$Replace
    )
    $existing = @((Invoke-TKRest -Method Get -Path ("Script?`$filter=ScriptName eq '{0}'" -f $Name)).value)
    if ($existing.Count -gt 0) {
        if (-not $Replace) { throw "Script '$Name' already exists ($($existing[0].ScriptGuid)). Use -Replace to recreate it." }
        foreach ($e in $existing) { $null = Invoke-TKRest -Method Delete -Route wmi -Path "SMS_Scripts('$($e.ScriptGuid)')" }
    }

    # ParamsDefinition: what the validator reads (XPath in smssqlclr.dll), stored base64.
    # ParameterlistXML: the console's stored list (ParameterType carries IsRequired there).
    $groupGuid = [guid]::NewGuid().ToString().ToUpper()
    $def = New-Object System.Text.StringBuilder
    $lst = New-Object System.Text.StringBuilder
    $null = $def.Append('<ScriptParameters>')
    $null = $lst.Append('<ScriptParameters>')
    foreach ($p in $Parameters) {
        $pName = [string]$p.Name
        $pType = 'System.String'; if ($p.ContainsKey('Type') -and $p.Type) { $pType = [string]$p.Type }
        $pReq = 'false'; if ($p.ContainsKey('Required') -and $p.Required) { $pReq = 'true' }
        $pDef = ''; if ($p.ContainsKey('Default') -and $null -ne $p.Default) { $pDef = [string]$p.Default }
        $esc = [System.Security.SecurityElement]::Escape($pDef)
        $null = $def.AppendFormat('<ScriptParameter Name="{0}" FriendlyName="{0}" Type="{1}" Description="" IsRequired="{2}" IsHidden="false" DefaultValue="{3}">', $pName, $pType, $pReq, $esc)
        if ($p.ContainsKey('Values') -and @($p.Values).Count -gt 0) {
            $null = $def.Append('<Values>')
            foreach ($v in @($p.Values)) { $null = $def.AppendFormat('<Value>{0}</Value>', [System.Security.SecurityElement]::Escape([string]$v)) }
            $null = $def.Append('</Values>')
        }
        $null = $def.Append('<Validators /></ScriptParameter>')
        $reqText = 'False'; if ($pReq -eq 'true') { $reqText = 'True' }
        $null = $lst.AppendFormat('<ScriptParameter ParameterGroupGuid="{0}" ParameterGroupName="PG_{0}" ParameterName="{1}" ParameterType="{2}" ParameterValue="{3}"/>', $groupGuid, $pName, $reqText, $esc)
    }
    $null = $def.Append('</ScriptParameters>')
    $null = $lst.Append('</ScriptParameters>')

    $bytes = [System.IO.File]::ReadAllBytes($File)
    $guid = [guid]::NewGuid().ToString().ToUpper()
    $body = @{
        ScriptGuid        = $guid
        ScriptVersion     = $Version
        ScriptName        = $Name
        ScriptDescription = $Description
        Author            = ''
        ScriptType        = 0
        ApprovalState     = 0
        Approver          = ''
        Comment           = ''
        ParamsDefinition  = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($def.ToString()))
        ParameterlistXML  = $lst.ToString()
        Script            = [Convert]::ToBase64String($bytes, [System.Base64FormattingOptions]::InsertLineBreaks)
        Timeout           = $Timeout
    }
    if ($Parameters.Count -eq 0) { $body['ParamsDefinition'] = ''; $body['ParameterlistXML'] = '' }
    $r = Invoke-TKRest -Method Post -Route wmi -Path 'SMS_Scripts.CreateScripts' -Body $body
    if ($r -and $r.PSObject.Properties['ReturnValue'] -and [int]$r.ReturnValue -ne 0) { throw "CreateScripts returned $($r.ReturnValue)." }
    Write-Verbose "Created '$Name' as $guid (version $Version, timeout $Timeout, $($Parameters.Count) parameter(s))"
    return (Get-TKScript -Name $Name -WarningAction SilentlyContinue)
}

function Approve-TKScript {
    <#
    .SYNOPSIS
        Sets ApprovalState 3 through SMS_Scripts.UpdateApprovalState. Works only where the
        hierarchy does not demand a second approver (TwoKeyApproval = 0) or the caller is not
        the author.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ScriptGuid, [string]$Comment = 'Approved by AZITC Toolkit')
    $approver = "$env:USERDOMAIN\$env:USERNAME"
    $r = Invoke-TKRest -Method Post -Route wmi -Path "SMS_Scripts('$ScriptGuid')/AdminService.UpdateApprovalState" -Body @{ ApprovalState = '3'; Approver = $approver; Comment = $Comment }
    if ($r -and $r.PSObject.Properties['ReturnValue'] -and [int]$r.ReturnValue -ne 0) { throw "UpdateApprovalState returned $($r.ReturnValue)." }
    return (@((Invoke-TKRest -Method Get -Route wmi -Path "SMS_Scripts('$ScriptGuid')").value)[0])
}

# --- Client notification ----------------------------------------------------

# The Type codes of SMS_ClientOperation.InitiateClientOperation, read from the console's
# enum Microsoft.ConfigurationManagement.ManagementProvider.ClientActionType. 135
# (RequestScriptExecution) is the one this library verified first, 13 was verified on
# the lab device: BgbAgent received the task 8 s after the call, AppDiscovery evaluated
# every deployment 15 s after it.
$script:TKClientActionTypes = @{
    MachinePolicy      = 8     # ClientNotificationRequestMachinePolicyNow
    UserPolicy         = 9     # ClientNotificationRequestUsersPolicyNow
    DiscoveryData      = 10    # ClientNotificationRequestDDRNow
    SoftwareInventory  = 11    # ClientNotificationRequestSWInvNow
    HardwareInventory  = 12    # ClientNotificationRequestHWInvNow
    AppDeploymentEval  = 13    # ClientNotificationAppDeplEvalNow
    SoftwareUpdateEval = 14    # ClientNotificationSUMDeplEvalNow
    SwitchSUP          = 15    # ClientRequestSUPChangeNow
    Restart            = 17    # ClientNotificationRebootMachine
    CheckCompliance    = 125   # ClientNotificationCheckComplianceNow
    WakeUp             = 150   # ClientNotificationWakeUpClientNow
}

function Send-TKClientNotification {
    <#
    .SYNOPSIS
        The console's "Client Notification" for one device: a push over the notification
        channel, no script, no approval, seconds instead of a Run Script round trip. Returns
        the operation id; there is no result beyond the operation state.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int]$ResourceId,
        [Parameter(Mandatory = $true)]
        [ValidateSet('MachinePolicy', 'UserPolicy', 'DiscoveryData', 'SoftwareInventory', 'HardwareInventory', 'AppDeploymentEval', 'SoftwareUpdateEval', 'SwitchSUP', 'Restart', 'CheckCompliance', 'WakeUp')]
        [string]$Action
    )
    $type = [int]$script:TKClientActionTypes[$Action]
    $r = Invoke-TKRest -Method Post -Route wmi -Path 'SMS_ClientOperation.InitiateClientOperation' -Body @{
        Type                = $type
        TargetCollectionID  = ''
        TargetResourceIDs   = @($ResourceId)
        RandomizationWindow = 0
    }
    if ($r -and $r.PSObject.Properties['ReturnValue'] -and [int]$r.ReturnValue -ne 0) { throw "InitiateClientOperation ($Action, type $type) returned $($r.ReturnValue)." }
    return [pscustomobject]@{ Action = $Action; Type = $type; OperationId = [int]$r.OperationID }
}

# --- Convenience ------------------------------------------------------------

function Get-TKLog {
    <#
    .SYNOPSIS
        Runs AZITC-TK-Log-Get on a device: the last lines of a client log, reduced to
        "date time  component  message".
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$DeviceName,
        [Parameter(Mandatory = $true)][string]$LogName,
        [int]$Lines = 100,
        [string]$Pattern = '',
        [string]$ScriptName = 'AZITC-TK-Log-Get',
        [int]$TimeoutSec = 180
    )
    $dev = Get-TKDevice -Name $DeviceName
    $scr = Get-TKScript -Name $ScriptName
    $res = Invoke-TKScript -ResourceId $dev.MachineId -Script $scr -Parameters @{ LogName = $LogName; Lines = $Lines; Pattern = $Pattern } -TimeoutSec $TimeoutSec
    $envelope = ConvertFrom-TKEnvelope -Json $res.Output
    if ($envelope.Error) { Write-Warning "Log-Get on $($envelope.Host): $($envelope.Error)" }
    if ($envelope.Truncated) { Write-Warning "Tail shortened to fit the output limit: $($envelope.Count) lines returned." }
    return [pscustomobject]@{
        Host        = $envelope.Host
        Path        = $envelope.Payload.Path
        Matched     = $envelope.Payload.Matched
        Lines       = $envelope.Lines
        Error       = $envelope.Error
        OperationId = $res.OperationId
        ExitCode    = $res.ExitCode
    }
}

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
