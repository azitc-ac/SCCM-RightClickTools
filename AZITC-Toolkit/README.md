# AZITC Toolkit (AZITC-TK)

A right-click console extension for Configuration Manager that opens a tabbed window for the
selected device. The first tab, **Software (ARP)**, lists the installed software of the device
and offers Inspect / Uninstall / Repair per entry. Everything that touches the client runs as
SYSTEM through ConfigMgr **Run Scripts**; results come back through the **AdminService**. No
WinRM, no WMI against clients, no local administrator rights on the client - the operator is a
ConfigMgr admin and nothing else.

Uninstalling something a required deployment will put back is a feature (clean re-install for
troubleshooting), not a warning.

## Pieces

| File | Runs where | What it does |
| --- | --- | --- |
| `AZITC-TK-Software-Get.ps1` | on the client, as a Run Script, no parameters | Enumerates Add/Remove Programs (HKLM x64/x86, loaded user hives) and the `CCM_Application` list. Emits one JSON envelope whose payload is gzip+base64, kept under the Run Scripts output limit; truncates and says so if it has to. Console timeout 300 s. |
| `AZITC-TK-Software-Action.ps1` | on the client, as a Run Script | Parameters `Action` (Inspect/Uninstall/Repair), `Key`, `ExtraArgs`, `TimeoutMin`, `KillRunning`, `ReEvaluate`. Strategy cascade MSI -> QuietUninstallString -> Inno/NSIS -> ExtraArgs -> Unknown, timeout with process-tree kill, exit-code mapping, post-verification, optional trigger of schedule `…121`. Per-user entries are reported, never executed. Console timeout 1800 s. |
| `AZITC-TK-Log-Get.ps1` | on the client, as a Run Script | Parameters `LogName` (name, path or wildcard), `Lines` (1..500), `Pattern` (regex). Tail of a client log from the served folders only (the client's log folder, the toolkit's, PSADT's), ConfigMgr entries reduced to `date time  component  message`. Console timeout 120 s. |
| `AZITC-TK-AdminService.ps1` | on the admin workstation, dot-sourced | The transport: `Connect-TKAdminService`, `Get-TKDevice`, `Get-TKScript`, `Start-TKScript` / `Invoke-TKScript`, `ConvertFrom-TKEnvelope`, `Get-TKSoftware`, `Invoke-TKSoftwareAction`, `Get-TKLog`, plus `Register-TKScript` / `Approve-TKScript` for putting a script into the Scripts node with its parameter definition. Usage block at the end of the file. |

Everything is Windows PowerShell 5.1; files are UTF-8 with BOM, CRLF.

## How a script reaches the client

Two transports, both through the AdminService on the SMS Provider, both verified on a real
site (CB 2509, 2026-09-11):

1. **`POST /AdminService/v1.0/Device(<id>)/AdminService.RunScript`** with body `{ "ScriptGuid": "..." }`.
   That is the whole contract: the action has exactly one parameter, and any other property in
   the body - `ScriptParameters`, `ScriptVersion` - is answered with HTTP 400. Good for the Get
   script, useless for anything with parameters.
2. **`POST /AdminService/wmi/SMS_ClientOperation.InitiateClientOperationEx`** - the provider
   method behind the console's own *Run Script* wizard, exposed on the `/wmi` route:

   ```json
   { "Type": 135, "TargetCollectionID": "", "TargetResourceIDs": [16777200],
     "RandomizationWindow": 0, "Param": "<base64 of the ScriptContent XML>" }
   ```

   The `ScriptContent` XML carries guid, version, type, the script hash, the parameter list and
   a hash over it; `New-TKScriptContent` builds it, the header of the library documents every
   field and where each value comes from. The provider validates the parameter values against
   the script's `ParamsDefinition` before anything is sent.

`Invoke-TKScript` picks transport 2 whenever parameters are given (`-Transport` overrides).
Results are polled from `wmi/SMS_ScriptsExecutionStatus`, filtered by `ClientOperationId` and
`ResourceId`; the v1.0 result entities (`DeviceScriptRunDetails`, `ScriptStatus`) exist in
`$metadata` but answer 404.

Approval: `ApprovalState` 3 = approved, 0 = waiting, 1 = denied. Running an unapproved script
gives 403 (RunScript) or 500 (InitiateClientOperationEx, "Script is not approved." in
`SMSProv.log`).

## Importing the scripts

`New-CMScript` creates the script but does **not** detect its parameters - `ParamsDefinition`
stays empty and the Action script would run without any. The console does that parsing on the
client side. What works from a script is the provider's static method
`SMS_Scripts.CreateScripts` (also on the `/wmi` route) with `ParamsDefinition` and
`ParameterlistXML` supplied; the XML shapes are in `CHANGELOG.md` under 2026-09-11 and were
taken from the console's own serializer and from the validator's XPath expressions, not
guessed. Timeouts: `New-CMScript` cannot set one, `Set-CMScript` neither, a WMI `Put` is
refused; the bound action `SMS_Scripts(<guid>)/AdminService.UpdateScript` can.

## Status

See `CHANGELOG.md`. Steps 1 and 2 are done - the three scripts are in the site, approved, and
have run end to end against the lab device (Get, Inspect, Uninstall+ReEvaluate, log tail).
Step 3 (GUI) is not started; of Step 4 the log tail exists.
