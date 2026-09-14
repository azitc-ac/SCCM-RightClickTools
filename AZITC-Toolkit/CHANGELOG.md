# Changelog - AZITC Toolkit

## 2026-09-14 - the provider is found, not typed; "HTTP 0" says why

The first deployment attempt at a customer failed with `HTTP 0 on GET https://.../Script?$top=1`
- a name that does not resolve, and a message that did not say so.

* `Connect-TKAdminService` no longer needs `-SmsProvider`. Without it, `Get-TKSmsProviderCandidates`
  lists what the machine knows: the console's connection history
  (`HKCU\SOFTWARE\Microsoft\ConfigMgr10\AdminUI\MRU\*\ServerName`), the site server's identity
  when run on the site server (`HKLM\SOFTWARE\Microsoft\SMS\Identification\Site Server`), the
  local `SMS_ProviderLocation`; the first one that answers wins.
* `Test-TKAdminService` probes one provider and turns a failure into a reason a person can act
  on: name not resolved in DNS, no answer on 443, TLS rejected the certificate (then
  `-SkipCertificateCheck`), 401 (not an administrator), 404 (a host without an AdminService).
  `Invoke-TKRest` puts the same detail into its "HTTP 0" message.
* `Publish-AZITCTKScripts.ps1` and `AZITC-TK.ps1` take `-SmsProvider` as optional; the window
  title shows the provider that answered. The console action still passes `##SUB:__Server##`.
* Publish loads CimCmdlets itself with WhatIf off - the automatic load under `-WhatIf` printed
  five "Set Alias" lines before the plan.

Checked on LAB01: detection finds `cm01.lab.example` from the console history; the placeholder
name from the README fails with "does not resolve in DNS"; without the certificate bypass the
message names TLS; publish and the window's self test run without a provider argument.

## 2026-09-11 (night, third round) - list the files of a log folder

`AZITC-TK-Log-Get` v4 has a `Mode` parameter: `Tail` (as before) or `List`, which returns the
files of the folder `LogName` names - a folder such as `PSADT`, a mask such as `PSADT\*.log`, or
a file whose folder is wanted - as name, size and last write, newest first, capped by `Lines`,
inside the served folders only. The payload carries `Files` (`N`, `P`, `KB`, `W`). Registered
anew (new parameter, new GUID `C0BB9FAC-…`) and approved. In the window a **List files** button
next to *Get log* fills the log box with the files found, so one can be picked and pulled;
the mask stays on top of the list.

Seen on CLIENT01 while testing: the PSADT logs of SCCMAppHelper packages live in
`C:\Windows\CCM\Logs\PSADT` (12 files), not in `%windir%\Logs\Software` - which is why the
earlier wildcard there found nothing.

## 2026-09-11 (night, second round) - what the first screenshot taught, and a toolkit log on the client

The user's first look at the window raised three questions; all three had answers in the
data, two of them needed code.

* **Two 7-Zip rows in the ConfigMgr applications grid, one NotInstalled.** The site holds
  `7-Zip - 24.9.0.0` with `IsSuperseded = True` and no deployment; `7-Zip - 26.02` supersedes
  it. The client receives the superseded application's policy along with the superseding one
  (it has to detect it), so `CCM_Application` lists it with `ResolvedState None`,
  `EvaluationState 2` (not required), no deadline. Correct, not a leftover. The grid now shows
  a **Superseded** column and the deployment count so this reads as what it is.
* **"7-Zip" instead of "7-Zip - 26.02".** `CCM_Application.Name` is the Software Center title
  (`DisplayInfo/Title`), not the console title. The console name is now looked up on the site
  by `ModelName` (= `CCM_Application.Id`) through `Get-TKSiteApplications` and shown as
  *Application (console)*; the Software Center title keeps its own column.
* **The heuristic match pointed at 24.9.0.0.** Both applications carry the same Software
  Center title, and the first one won. The match now scores: version agreement 4, installed 2,
  has a deadline 1, not superseded 1; the label uses the console name. CLIENT01: `7-Zip 26.02 (x64)`
  -> `7-Zip - 26.02 - Installed/Installed`.

**Toolkit log on the client.** Every client script writes one CMTrace-format line per run
(request and result, with the exit code and any error) to
`<client log folder>\AZITC-Toolkit\AZITC-Toolkit.log` - `C:\Windows\CCM\Logs\AZITC-Toolkit`
on a workstation, next to the client's own logs, rotated at 2 MB to `.lo_`. The msiexec logs
of Software-Action go into the same folder (they used to go to ProgramData). Log-Get serves the
folder because it lies under the client's log folder; the window's log list offers
`AZITC-Toolkit\AZITC-Toolkit.log`. Verified on CLIENT01 by reading the log back through Log-Get
after a Get and an Inspect.

All seven scripts were updated in the site (Get v3, Action v3, Log-Get v3, the rest v2) and
re-approved; the console copy is current.

## 2026-09-11 (late) - Step 4: CM application actions, client overview, services / processes / cache

Three more Run Scripts, all registered through `Register-TKScript`, approved, run on CLIENT01, and
wired into the window.

* **`AZITC-TK-CMApp-Action.ps1`** - `Action` (Install/Uninstall/Repair), `AppId`, `Revision`,
  `TimeoutMin`, `IsRebootIfNeeded`. Calls the `CCM_Application` method in `root\ccm\ClientSDK`
  and watches `InstallState` / `EvaluationState` until the wanted state is reached, enforcement
  fails (4, 13) or the timeout runs out; the course is in the result. The ClientSDK provider
  refuses WQL filters on the class ("Provider is not capable of the attempted operation"), so
  instances are enumerated and matched in PowerShell. Refuses an action that is not in the
  application's `AllowedActions`. CLIENT01, Google Chrome: uninstall 33 s (`Installed -> Waiting for
  content -> Enforcing -> NotInstalled`), install 39 s, both watched to the end. In the window:
  Install / Uninstall / Repair buttons above the ConfigMgr applications grid, enabled from
  `AllowedActions`.
* **`AZITC-TK-Client-Get.ps1`** - no parameters, one envelope (Kind `Client`): client facts
  (OS, boot, memory, client version, site, MP, cache config), pending reboot with its sources
  (CBS, Windows Update, pending file renames, computer rename, `CCM_ClientUtilities.
  DetermineIfRebootPending`), every service, every process with owner and command line, every
  cache item. Lists are cut from the biggest section down when the envelope would exceed the
  limit. CLIENT01: 37 s, 258 services, 118 processes, 7 cache items, 15 KB. In the window: the Client
  tab has Overview / Services / Processes / Cache / Actions, filled by one "Read client".
* **`AZITC-TK-Client-Manage.ps1`** - `Target` (Service/Process/Cache), `Action`
  (Start/Stop/Restart/Kill/Delete/Clear), `Name`. The ConfigMgr client service and the core
  system processes are protected on the client side; Clear removes only items that are not
  persisted and have no reference. CLIENT01: Spooler restart 11 s, cache clear 16 s (5.3 GB freed,
  the item in use skipped). In the window: Start/Stop/Restart on the selected service, End
  process, Delete selected / Clear unused on the cache, each with a confirmation, each followed
  by a fresh read.

`Invoke-TKCMAppAction`, `Get-TKClient`, `Invoke-TKClientManage` in the library. The window's
smoke test now also reads the client tab: `autoclose: ... services=258 processes=115
handlerError=''`. Seven scripts in the site.

Not done: the 80 KB test on a device with several hundred ARP entries; column widths and
other polish; nothing of Step 4 is left except what the handover did not list.

## 2026-09-11 (night) - Step 3: the window and the console extension

### `AZITC-TK.ps1` - the window

One file, Windows PowerShell 5.1, WPF from a XAML here-string. Parameters `-DeviceName`,
`-ResourceId`, `-SmsProvider`, `-SiteCode`, `-SkipCertificateCheck`; `-SelfTest` runs the
connect and the software list without a window and prints a summary, `-AutoCloseSeconds n`
closes the window after n idle seconds and prints its state - both exist so the thing can be
checked from a script.

* Tabs: **Software (ARP)** - search box (DataView `RowFilter` over name, publisher, version and
  the match column), column-click sort, Refresh / Inspect / Uninstall / Uninstall + re-evaluate /
  Repair, "kill running processes first", extra args; a lower pane with the action result
  (strategy, exit code, meaning, log tail) and a second grid with the `CCM_Application` rows of
  the device. Uninstall/Repair are disabled for `User:*` entries with a tooltip saying why;
  Repair carries a tooltip when the entry has NoRepair/NoModify. Destructive actions ask once.
  **Logs** - log name (editable list of the usual client logs plus the PSADT folder), lines,
  regex, output in a monospace box. **Client** - one button per client notification
  (`Send-TKClientNotification`) and one per action of the client-action script.
* Status bar: text, OperationId of the last run, elapsed seconds, an indeterminate progress bar
  while a job runs. All buttons that start something are disabled while one runs.
* The grids bind a `System.Data.DataTable`, not PSCustomObjects - the DataView gives filter and
  sort for free and binds without surprises in 5.1.
* Background: one runspace, opened once, the library dot-sourced into its **global** scope by
  the connect job (`AddScript(text, $false)`; a dot-source in local scope would vanish with the
  job, and re-sourcing resets the connection). Every job is a `[PowerShell]` with `BeginInvoke`;
  a `DispatcherTimer` (500 ms) collects the result on the UI thread and hands it to the job's
  callback. Callback errors land in the status bar instead of dying in the dispatcher.
* Heuristic CM application match: ARP name starts with the application name or the other way
  round, longest application name wins; on CLIENT01 9 of 28 entries match. Labelled as heuristic in
  the column header.
* Script GUIDs come from name lookups in the connect job; the window shows which of the four
  scripts is missing or unapproved.

Smoke test on CLIENT01 through the launcher: window opens, list loads in 11 s (28 entries, 20
applications), auto-close reports no handler error.

### Console extension

* `AZITC-TK.xml` - `ActionDescription Class="Executable"` with `<FilePath>` and `<Parameters>`
  (the element names the console accepts; anything unknown makes it drop the action), icon
  `device_actions` from `AdminUI.UIResources.dll` (resource names listed from the assembly).
  Tokens `##SUB:Name##`, `##SUB:ResourceID##`, `##SUB:__Server##`, `##SUB:SiteCode##`.
* Node GUIDs verified in this console's `XmlStorage\ConsoleRoot`:
  `{ed9dee86-eadd-4ac8-82a1-7234a4646e62}` is the QueryDescription of the Devices node
  (`SMS_CombinedDeviceResources`, AssetManagementNode.xml), `{3fd01cd1-9e01-461e-92cd-94866b8d1f39}`
  the one of a collection's member view (`##SUB:MemberClassName##`, ConnectedConsole.xml).
* `AZITC-TK-Launcher.cs` - starts `powershell.exe -NoProfile -NonInteractive -STA
  -ExecutionPolicy Bypass -File` without a console window and re-quotes every argument, so a
  name with a space survives. Compiled by the installer with the .NET Framework `csc.exe`.
* `Install-AZITCTKConsoleExtension.ps1` - finds the console (SMS_ADMIN_UI_PATH first), copies
  the two scripts to `extensions\AZITC-Toolkit\`, compiles the launcher, writes the XML into
  both action folders; `-Uninstall` removes it all; `-SkipCertificateCheck:$false` for a PKI
  provider. Installed on LAB01's console; the hierarchy setting that hides file-based extensions
  (`ConsoleExtensionsRegisteredWithTheSite`) reads 0 there, so the entry should appear after a
  console restart. Not yet clicked in a live console.

### Open

* The right-click in a live console (the user's console had crashed earlier).
* Column widths, keyboard shortcuts, remembering the window size - polish, not function.
* `-Transport` is not exposed in the window; nothing needs it yet.

## 2026-09-11 (evening) - Step 2 done: Get, Inspect, Uninstall+ReEvaluate on CLIENT01; Log-Get added

Everything below was run against CLIENT01 (16777200) through the AdminService, nothing else touched
the client.

### Measured

| Call | Round trip | Result |
| --- | --- | --- |
| `Get-TKSoftware` (RunScript transport) | 16 s | 29 ARP entries, 20 `CCM_Application` rows, envelope 4321 chars (gzip+base64) |
| `Invoke-TKSoftwareAction -Action Inspect` (InitiateClientOperationEx) | 22 s | MSI strategy recognised, nothing executed |
| `Invoke-TKSoftwareAction -Action Uninstall -ReEvaluate` on the 7-Zip MSI | 91 s | msiexec 2 s, exit 0, ARP entry gone, schedule 121 triggered, verbose MSI log on the client |
| `Get-TKLog -LogName AppEnforce.log -Lines 60` | 16 s | 477 entries parsed, 60 returned |

The client reports about 15 s after a script finished; that, not the script, sets the floor
of every round trip.

### Faults found by running, all fixed

* Get script, 5.1 only: `[pscustomobject]@{ Apps = @($list) }` with a `List[object]` throws
  "Argument types do not match", and `return ,$list` handed the List to `AddRange` as one
  element - 3 "entries" (the lists themselves) instead of 38. Lists become arrays now. Get is v2.
* Action script: `LogTail` carried `Get-Content`'s note properties into the JSON - 600 characters
  per line, 24 KB for 40 lines. Plain strings now. Action is v2.
* Library, on the site:
  - `ParamsDefinition` must be stored **base64** (UTF-8 of the XML); the validator
    (`fnValidateRunScriptParameters`) decodes both of its arguments. Plain XML gives
    "not a valid Base-64 string".
  - Every run-time `<ScriptParameter>` needs **`ParameterDataType`** = `System.String` /
    `System.Int32` / `System.Boolean`; without it the validator throws "Unsupported Type ''".
    `ParameterType` is not checked (the console writes IsRequired into it). The types are read
    from the script's own ParamsDefinition (`Get-TKScriptParameterDefinition`).
  - `ScriptOutput` is cut at **4000 characters** in `SMS_ScriptsExecutionStatus` and in the
    `ScriptResult` function - `vSMS_ScriptsExecutionStatus` does `LEFT(ScriptOutput, 4000)`
    for every script with `Feature = 0`, which is every script created through the API. The
    full text is `SMS_ScriptsExecutionSummary.FullOutput`, a lazy property that is null in a
    list and filled only on a GET by key `(OutputAndExitCode, ScriptGuid, TaskID)`, where
    `OutputAndExitCode` is the status row's `ScriptOutputHash`. `Get-TKScriptFullOutput`.
  - The stored output is the JSON-escaped body of the string **without** the outer quotes
    (`{\"Schema\":1,...`); `ConvertFrom-TKScriptOutput` wraps and decodes it.
  - `ScriptExecutionState` 1 = succeeded, 2 = failed (exit code -2147467259 when the script
    threw). `ScriptResult` returned `{"value":{"Status":"1","MoreResult":false,"Result":[{"ScriptOutput":"..."}]}}`.
  - Windows PowerShell 5.1 needs the compiled certificate callback (see the morning entry).

### New: `AZITC-TK-Log-Get.ps1` (Step 4 item, pulled forward with the user's OK)

Tail of a client log as a Run Script. Parameters `LogName` (name, path or wildcard - the
newest match wins), `Lines` (1..500), `Pattern` (regex). Served folders only: the client's
log folder as the client records it in `HKLM\SOFTWARE\Microsoft\CCM\Logging\@Global\LogDirectory`
(`%windir%\CCM\Logs` on a workstation, `<install>\SMS_CCM\Logs` on a site system), the
toolkit's own log folder, and `%windir%\Logs\Software` (PSAppDeployToolkit). ConfigMgr
entries - also multi-line ones - are reduced to `date time  component  message`. Registered
through the new `Register-TKScript`, which builds ParamsDefinition and ParameterlistXML and
calls `SMS_Scripts.CreateScripts`; `Approve-TKScript` sets state 3. Version 2, timeout 120.
Wildcard note: `*Install.log` also matches `…-uninstall.log`; give the folder when it matters.

### What the first uninstall uncovered (not a toolkit fault)

After the 7-Zip MSI was removed and re-evaluation triggered, the required deployment
"7-Zip - 26.02" ran within 36 s, PSADT exited 0 after 12 s, and detection reported
"Application not discovered" - `EvaluationState` 4 on the client. Read through `Get-TKLog`:
the deployment type (revision 18) detects `%ProgramFiles%\7-Zip\7z.exe` >= 26.02; the package
on the share holds `7z2602-x64.exe` and its `Invoke-AppDeployToolkit.ps1` has an **empty
install block**, so PSADT installs nothing (zero-config only covers MSI). The file the
detection wants came from the MSI install that sat next to the EXE one, and the uninstall took
it away. Recorded as an open item in SCCMAppHelper's STATUS.md. The toolkit's job - uninstall,
trigger, show what happened - was done; the log tab is what made the diagnosis possible.

### Later the same evening: `AZITC-TK-Client-Action.ps1`, and the repaired package installs

The user repaired the 7-Zip package. To get it onto CLIENT01 without waiting for the schedules, a
fourth Run Script triggers client schedules by name (`Action` = MachinePolicy /
AppDeploymentEval / HardwareInventory / SoftwareInventory / DiscoveryData / SoftwareUpdateScan /
SoftwareUpdateEval / All; `All` waits 20 s between policy and evaluation). Registered as
`0D44A52D-87AD-4788-B545-59000DB3D06C`, timeout 120, ran in 52 s. Content state was checked
first on `SMS_ObjectContentExtraInfo` (source version 6, 1/1 success). AppEnforce.log then:
install enforcement 19:26:54, exit 0 after 8 s, "Discovered application"; `CCM_Application`
Installed / EvaluationState 1. Four scripts in the site now.

### Open

* `ScriptExecutionState` values other than 1 and 2 have not been observed.
* The 80 KB client-side output limit has not been hit yet; the largest envelope so far is
  5.2 KB for 500 log lines. A device with several hundred ARP entries is still the test.
* Scripts in the site: Get v2 (`C8AB00CF-…`), Action v2 (`E26C27CE-…`), Log-Get v2
  (`4852BF8B-816B-4A7B-AF66-5806EC06D5E1`), all approved by the author after the hierarchy
  setting "Script authors require additional script approver" was switched off by the user.

## 2026-09-11 - Step 1 done, Step 2 up to the approval

Site: CB 2509, provider 5.2509.1036.1200, client 5.00.9141.1011. Lab device CLIENT01 (16777200).

### What the real API shapes are

* `Device(<id>)/AdminService.RunScript` - one parameter, `ScriptGuid`. `$metadata` says so and
  the server enforces it: a body with `ScriptParameters` (array or object shape) or
  `ScriptVersion` is HTTP 400. Unapproved script: HTTP 403, empty body.
* `ScriptResult(OperationId=<n>)` - a bound *function* returning `Edm.Boolean`; an unknown id
  answers 400, not 404. Not used for polling.
* `wmi/SMS_ClientOperation.InitiateClientOperationEx` - accepts
  `{ Type, TargetCollectionID, TargetResourceIDs, RandomizationWindow, Param }` (signature read
  from the WMI class, the OData metadata only lists the import). `Type` 135 = Run Script. The
  provider parses `Param` and checks approval; unapproved gives HTTP 500 and
  `ERROR InitiateClientOperation: Script is not approved.` in SMSProv.log.
* `Param` = base64 (UTF-8) of

  ```xml
  <ScriptContent ScriptGuid='G'><ScriptVersion>V</ScriptVersion><ScriptType>T</ScriptType>
  <ScriptHash ScriptHashAlg='SHA256'>H</ScriptHash>
  <ScriptParameters><ScriptParameter ParameterGroupGuid="P" ParameterGroupName="PG_P"
     ParameterName="Action" ParameterType="" ParameterValue="Inspect"/>…</ScriptParameters>
  <ParameterGroupHash ParameterHashAlg='SHA256'>X</ParameterGroupHash></ScriptContent>
  ```

  The format string is a literal in `AdminUI.Scripts.dll`. `H` is `SMS_Scripts.ScriptHash`
  as stored = SHA-256 of the script file bytes including the BOM, upper-case hex. `X` is
  SHA-256 over the **UTF-16LE** bytes of the `<ScriptParameters>…</ScriptParameters>` string,
  lower-case hex - the console's `Utilities.GetHash`; the provider stores exactly that as
  `ParameterGroupHash` when a script is created. The parameter values are validated on the
  server by the CLR function `fnValidateRunScriptParameters` against `ParamsDefinition`, whose
  XPath expressions are: `/ScriptParameters//ScriptParameter` with `@Name @FriendlyName @Type
  @Description @IsRequired @IsHidden @DefaultValue`, `./Values/Value`, `./Validators/*` with
  `IntegerValidator(@MinimumValue @MaximumValue)` and `StringValidator(@MinimumLength
  @MaximumLength @Regex @CustomErrorMessage)`; types `System.String | System.Int32 |
  System.Boolean`. The run-time list is read as `/ScriptContent/ScriptParameters/ScriptParameter`
  with `@ParameterName @ParameterType @ParameterValue`.
* `ApprovalState` 3 = approved, confirmed on the site's built-in CMPivot script; 0 = waiting.
* `/wmi` route quirks: GET by key returns `{ "value": [ … ] }`; lazy properties (`Script`,
  `ParamsDefinition`, `ParameterlistXML`) come only with a GET by key. `Script` is base64 of the
  file bytes with line breaks every 76 characters.
* Result rows: `wmi/SMS_ScriptsExecutionStatus?$filter=ClientOperationId eq N and ResourceId eq R`
  works and is empty until the client reports. The v1.0 sets `DeviceScriptRunDetails`,
  `ScriptStatus`, `DeviceScriptStatus` answer 404 for every query tried.
* Windows PowerShell 5.1: `ServerCertificateValidationCallback = { $true }` fails on the request
  thread ("The underlying connection was closed: An unexpected error occurred on a send"). The
  library now compiles a tiny callback class (`Enable-TKTrustAllCertificates`).
* The hierarchy has `TwoKeyApproval = 1` ("Script authors require additional script approver"):
  the author account cannot approve its own scripts. Not changed.

### What changed

* `AZITC-TK-AdminService.ps1` rewritten around the findings: `Start-TKScript` (returns the
  operation id) with `-Transport Auto|RunScript|ClientOperation`, `New-TKScriptContent`,
  `Get-TKScriptRunResult`, `Invoke-TKScript` polling `SMS_ScriptsExecutionStatus`;
  `Invoke-TKRest` gained `-Route wmi` and puts the HTTP status into the exception. The two
  client scripts are unchanged (schema 1).
* Both Run Scripts exist in the Scripts node, version 1, waiting for approval:
  `AZITC-TK-Software-Get` (`C8AB00CF-7846-4C7C-8B92-6F43A73699E4`, timeout 300) and
  `AZITC-TK-Software-Action` (`E26C27CE-598A-4F22-BF43-DC3BCF64A5ED`, timeout 1800, six
  parameters, `Action` and `Key` required, `Action` restricted to Inspect/Uninstall/Repair).
  The Action script was created through `SMS_Scripts.CreateScripts` because `New-CMScript`
  detects no parameters; the Get script was created with `New-CMScript` and its timeout set
  through `UpdateScript`.
* Observed provider bug, cosmetic: `CreateScripts` stores `ParameterGroupHash` with the text
  `, @Timeout=1800` appended (format string in smsprov.dll:
  `@ParameterGroupHash=N'%s, @Timeout=%d'`). Console-created scripts get the same.

### Open

* Approval of both scripts by a second admin account.
* First real run: capture the `SMS_ScriptsExecutionStatus` row (numeric
  `ScriptExecutionState` values are still unverified) and one `ScriptResult` response, then
  the end-to-end sequence Get -> Inspect -> Uninstall+ReEvaluate on CLIENT01, and the compressed
  size of the Get output.
