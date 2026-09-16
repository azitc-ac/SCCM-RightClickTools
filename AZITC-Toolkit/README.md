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
| `AZITC-TK-Software-Action.ps1` | on the client, as a Run Script | Parameters `Action` (Inspect/Uninstall/Repair), `Key`, `ExtraArgs`, `TimeoutMin`, `KillRunning`, `ReEvaluate`. Strategy cascade MSI -> QuietUninstallString -> Inno/NSIS -> ExtraArgs -> Unknown, timeout with process-tree kill, exit-code mapping, post-verification, optional trigger of schedule `…121`. Detects orphaned entries (product unknown to Windows Installer, uninstaller gone); `RemoveEntry` deletes such a key after saving its values. Per-user entries are reported, never executed. Console timeout 1800 s. |
| `AZITC-TK-Log-Get.ps1` | on the client, as a Run Script | Parameters `LogName` (name, path or wildcard), `Lines` (1..500), `Pattern` (regex). Tail of a client log from the served folders only (the client's log folder, the toolkit's, PSADT's), ConfigMgr entries reduced to `date time  component  message`. Console timeout 120 s. |
| `AZITC-TK-Client-Action.ps1` | on the client, as a Run Script | Parameter `Action`: MachinePolicy, AppDeploymentEval, HardwareInventory, SoftwareInventory, DiscoveryData, SoftwareUpdateScan, SoftwareUpdateEval, All. Triggers the schedule(s) through `SMS_Client.TriggerSchedule`. Console timeout 120 s. |
| `AZITC-TK-CMApp-Action.ps1` | on the client, as a Run Script | `Action` (Install/Uninstall/Repair), `AppId`, `Revision`, `TimeoutMin`, `IsRebootIfNeeded`: the `CCM_Application` method, watched until the state changes. Console timeout 1800 s. |
| `AZITC-TK-Client-Get.ps1` | on the client, as a Run Script, no parameters | Client facts, pending reboot with sources, services, processes, cache - one envelope. Console timeout 300 s. |
| `AZITC-TK-Client-Manage.ps1` | on the client, as a Run Script | `Target` (Service/Process/Cache), `Action` (Start/Stop/Restart/Kill/Delete/Clear), `Name`. ConfigMgr client and core processes protected. Console timeout 300 s. |
| `AZITC-TK-CMApp-Troubleshoot.ps1` | on the client, as a Run Script | `AppId`, `Days` (log window, 14), `MaxLines` (25). Why is this application not where the deployment wants it: the deployments in the client's policy, and per deployment type the **detection method read from `root\ccm\CIModels` and evaluated on the device clause by clause** (file / folder / registry / MSI with the value found, or the detection script run the way the client runs it), the install command and its exit codes, the last enforcement result the client kept (`CCM_AppEnforceStatus`), the requirement rules with their last result (`DCMReporting.log`, texts from the site), the content (in the cache or not, and what CAS / ContentTransferManager / LocationServices / DataTransferService logged about it), every enforcement attempt of the last days from `AppEnforce.log` with exit code and post-install detection, the detection results from `AppDiscovery.log`, the intent evaluations, when the application deployment evaluation cycle last ran and on what schedule, and the Add/Remove Programs entries that match the name. Verdicts drawn from all of that, what the client is doing now first, then the last attempt (an exit code outside the success list while the product is there is named as such). All times in the report are the device's time; the header names the zone. Console timeout 300 s. |
| `AZITC-TK.ps1` | on the admin workstation, started by the console action | The window: Software (ARP) with search, sort, Inspect / Uninstall / Repair / Uninstall + re-evaluate and the `CCM_Application` list with Install / Uninstall / Repair and **Troubleshoot**; Logs; Client (notifications and the client-action script). One background runspace, the UI never blocks. `-SelfTest` and `-AutoCloseSeconds` for scripted checks. |
| | | The grids show what a state means, not what the class calls it: **Target reached** answers the whole question in one coloured word (OK / Pending / Failed / offered / not targeted), and beside it stand `InstallState` as **On the device**, `ResolvedState` as **Deployment** (required / optional / not targeted - what the deployment wants, not what is installed) and `EvaluationState` as **Status** in words. Each of those cells keeps the raw value in its tooltip. |
| `AZITC-TK.xml`, `AZITC-TK-Launcher.cs`, `Install-AZITCTKConsoleExtension.ps1` | console | The right-click action for devices (Devices node and collection member view), the hidden-window STA launcher, and the installer (`-Uninstall` to remove). |
| `AZITC-TK-Report.xml`, `AZITC-TK-OpenReport.ps1` | console | Right-click on the Device Collections node or any folder below it: **AZITC: Application compliance report** opens the reporting point's report `Anwendungs-Installationsstatus - Compliance-Übersicht` (sccm-reports repository) in a report viewer window - the console's own `Microsoft.ReportViewer.WinForms` control from the console's bin folder, in remote mode against the report server, so paging, parameters, print and export work as in the console. The script reads the reporting point from `SMS_SCI_SysResUse` through the AdminService. Installer parameters: `-Report`, `-ReportFolder` (`-Report ''` installs no report action), `-ReportInBrowser` opens the web portal URL instead (also the fallback when the viewer assemblies are not found). |
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

## Deploying to a site

Updates: `update.ps1`, as administrator, no parameters - downloads the current folder from GitHub
(no git needed), publishes the Run Scripts and installs the console extension. `-WhatIf` lists
what would be replaced, `-NoDeploy` only replaces the files, `-CertificateCheck` verifies the
AdminService certificate (off by default, it is usually self-signed).

The two halves it runs, for a first installation or by hand - both from a copy of this folder
on any machine that reaches the SMS Provider (the admin workstation is the natural place):

```powershell
# 1. the eight Run Scripts into the Scripts node - creates, updates changed ones (version + 1),
#    recreates when a parameter set changed, approves where the author may approve
.\Publish-AZITCTKScripts.ps1 -SkipCertificateCheck -WhatIf        # provider: the console's connection history
.\Publish-AZITCTKScripts.ps1 -SkipCertificateCheck
.\Publish-AZITCTKScripts.ps1 -SmsProvider cm01.customer.example    # or name it

# 2. the right-click action into every console that should have it (as administrator)
.\Install-AZITCTKConsoleExtension.ps1
```

`-SmsProvider` may be left out: the library takes the provider the console on this machine last
connected to (or the site server itself when run there) and probes it. A provider that does not
answer is reported with the reason - name not in DNS, port 443 closed, certificate rejected, no
AdminService there - instead of "HTTP 0".

What the site needs: a ConfigMgr administrator with script author rights (Full Administrator
has them) running step 1; the AdminService reachable on the provider (`https://<provider>/AdminService`,
port 443); `-SkipCertificateCheck` only while the provider uses its self-signed certificate.
If the hierarchy has *Script authors require additional script approver* on, step 1 reports
the scripts as *NOT approved* and a second administrator approves them once in the console -
the window says which scripts are missing or unapproved when it opens. Step 2 needs the
hierarchy setting *Only allow console extensions that are approved for the hierarchy* off.
Re-running both steps after an update is safe: unchanged scripts are left alone.

## Installing the console action

```powershell
.\Install-AZITCTKConsoleExtension.ps1          # as administrator, on the machine with the console
```

Copies the window, the library and VERSION to `<AdminConsole>\extensions\AZITC-Toolkit\`, compiles the
launcher, writes `AZITC-TK.xml` for the Devices node and the collection member view. Restart
the console. The hierarchy setting *Only allow console extensions that are approved for the
hierarchy* has to be off, as for every file-based extension.

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

See `CHANGELOG.md`. Steps 1-4 are done: seven scripts in the site, approved and run end to end on the lab
device; the window (Software, Logs, Client with Overview / Services / Processes / Cache /
Actions) and the console action are installed on the lab console.
