# Changelog - AZITC Toolkit

## 2026-09-15 - Troubleshoot: the detection, evaluated on the device, and the attempts that led here

The user's two questions: *why has an app that should be on the device not been retried for
days?* and *why is it installed over and over, and never there afterwards?* Both are detection
questions, and both are answered by data the client keeps locally - no site access needed.

### What the client holds (verified on CLIENT01, client 5.00.9141.1011)

* `root\ccm\CIModels` carries the deployment types as *synclets*, one row per DT and revision:
  `CCM_AppDeliveryTypeSynclet` (name, revision), `Local_Detect_Synclet` with the enhanced
  detection as XML (`ExpressionXml`: a `<Settings>` block with `File`, `Folder`, `MSI`,
  `SimpleSetting`/`RegistryDiscoverySource` elements, and a `<Rule>` expression tree with
  `And`/`Or` and `Equals`/`NotEquals`/`GreaterEquals`/… over `SettingReference`
  (`PropertyPath` Version/ProductVersion/…, `Method` Value or Count) and `ConstantValue`),
  `Script_Detect_Synclet` (`ScriptBody`, `ScriptType` 0 = PowerShell, `RunAs32Bit`),
  `MSI_Detect_Synclet` (`ProductCode`, `ProductVersion`), `CCM_LocalInstallationSynclet`
  (install command line, `SuccessExitCodes`, `RebootExitCodes`, `MaxExecuteTime`, context) and
  `CCM_AppEnforceStatus` - the last enforcement result per DT: `ExecutionStatus`, `ExitCode`.
  On CLIENT01 that row for Notepad++ read `Failure, 2278556452` = 0x87D00324, "not detected
  after installation".
* `CCM_ApplicationCIAssignment` in `root\ccm\Policy\Machine\ActualConfig` is the deployment:
  `AssignmentName`, `EnforcementDeadline`, `StartTime`, `OverrideServiceWindows`,
  `AssignedCIs` with the `<CIVersion>` = the application revision the policy carries. The
  application id in there is `RequiredApplication_<guid>` for the same guid that
  `CCM_Application.Id` names as `Application_<guid>`.
* `CCM_Scheduler_History` in `root\ccm\Scheduler`: `LastTriggerTime` per schedule id; `…121`
  is the application deployment evaluation cycle, `…021` the machine policy request. The
  schedule token itself is in `CCM_Scheduler_ScheduledMessage.Triggers`
  (`SMSSchedule;ScheduleString=0062200000100008;…`) and is worded by the provider:
  `SMS_ScheduleMethods.ReadFromString` works on the `/wmi` route as a POST with
  `{ StringData }` and returns `TokenData` (`SMS_ST_RecurInterval`, DaySpan 1 on the lab
  client, DaySpan 7 for the update scans).
* `AppEnforce.log` blocks: `+++ Starting Install enforcement for App DT "…" ApplicationDeliveryType
  - <DT>, Revision - N, ContentPath - …` … `Performing detection …` / `+++ Application not
  discovered` (before) … `Prepared command line: …` … `Process N terminated with exitcode: X` …
  `Matched exit code X to a Success entry` or `Unmatched exit code (X) is considered an execution
  failure` … `Performing detection …` / `+++ Discovered application` (after) … `++++++ App
  enforcement completed (N seconds) for App DT "…" [<DT>], Revision: N`. `AppDiscovery.log`:
  `+++ Evaluating expression to discover application` / `+++ Executing script to discover
  application` then `+++ Discovered application` / `+++ Application not discovered` /
  `+++ Application discovered` / `+++ Application not discovered with script detection`, each
  with `[AppDT Id: <DT>, Revision: N]`; the client keeps evaluating the older revisions too, four
  lines per pass on CLIENT01. `AppIntentEval.log`: `<DT>/<rev> :- Current State = …, Applicability
  = …, ResolvedState = …, ConfigureState = …, Title = …`.

**Time stamps, a trap.** The ClientSDK (`CCM_Application.LastEvalTime`, `Deadline`, …) and
`CCM_Scheduler_History` store the *local* clock with a `+000` offset: raw
`20260914192223.000000+000` while `AppDiscovery.log` shows that evaluation at 19:22:21 local
(`time="…-120"`), and a 13:27 local deadline the site holds as 11:27 UTC. CIM therefore hands
over a DateTime shifted by the zone offset. The policy's `CCM_ApplicationCIAssignment` uses
`+***` with `UseGMTTimes=True` and is right as it comes. `AZITC-TK-Software-Get` showed the
deadline two hours off as "UTC" since 2026-09-11 - fixed (v4), and the new script converts the
same way (`ToIsoLocalDigits`).

### What was built

* `AZITC-TK-CMApp-Troubleshoot.ps1` (v6 in the site, `19C6936E-436A-4501-BB41-1F80C2F1CAD0`,
  parameters `AppId`, `Days`, `MaxLines`; 17-27 s on CLIENT01): reads the application, its
  assignments, and per DT the synclets; **parses `ExpressionXml` and evaluates every clause on
  the device** - `%ProgramFiles%` in a 32-bit clause is the x86 folder, registry through the
  32/64-bit view the clause names, MSI through `WindowsInstaller.Installer.ProductState` /
  `ProductInfo`, versions padded to four parts so `26.02` equals `26.02.0.0` -; **runs the
  detection script** the way the client does (SYSTEM, 64-bit unless `RunAs32Bit`, 60 s cap;
  discovered = exit 0, stdout not empty, stderr empty); parses the three logs for the DT and the
  current revision; reads the scheduler history; lists the ARP entries matching the name; and
  writes verdicts in causal order (policy → applicability → detection vs. ARP → last attempt's
  exit code and post-install detection → waiting states → deadline). One envelope, gzip+base64,
  histories shortened first when the output limit is near.
* Verdicts seen on real data: Notepad++ - *installer exit 0 (13 s), detection afterwards found
  nothing (0x87D00324); evaluated now: MSI product {224C0E17-…} ProductVersion ≥ 8.9.8 → not
  present (Unknown product); Add/Remove Programs lists Notepad++ (64-bit x64) 8.9.8 (non-MSI)* -
  the package installs an EXE, the detection looks for an MSI. SSMS 22 - detection script
  returns "Installed", ARP has 22.9.2, deployment carries 22.3.3: *newer version present, the
  rule accepts it* (the first draft called that a false positive; older-than is the false
  positive, newer-or-equal is fine). 7-Zip 26.02 - four file clauses, the two 64-bit ones true
  with `26.02`, ARP agrees; the attempt history shows rev 7 and rev 18 with exit 0 and "not
  discovered", rev 23 with exit 0 and "discovered" - the 2026-09-14 story in one list.
* Library: `Invoke-TKCMAppTroubleshoot`, `Format-TKTroubleshoot` (verdicts first, then the
  facts), `ConvertFrom-TKScheduleString` (provider-worded schedule). Window: **Troubleshoot**
  button beside Install/Uninstall/Repair, enabled for any selected row - a green row with a
  wrong detection is a case too -, result in the Action result pane, the top Fail/Warn verdict
  in the status bar. `Publish-AZITCTKScripts.ps1` knows the script.

### Provoked failures (afternoon): a throwaway application on CLIENT01

`AZITC-TK-Test` (script DT, `Install.ps1` writes `HKLM\SOFTWARE\AZITC\TK-Test\Version`,
registry detection `Version >= 1.0.0`, required deployment to a collection with the lab
device only, `_testapp.ps1` scenarios), each state read back with the troubleshoot script:

* **Exit 1.** `AppEnforce.log`: `Process N terminated with exitcode: 1`, `Unmatched exit code
  (1) is considered an execution failure`; `CCM_Application.ErrorCode` 0x00000001, state 4.
  Verdict names the exit code, the meaning and the DT's success list (`0,1707`).
* **Requirement not met** (free disk space > 999999999 MB). `ApplicabilityState =
  NotApplicable`, `ResolvedState = None`, state 2 - the deployment resolves to nothing.
  `DCMReporting.log`: `In policy:<DT with _ for - and />_<rev>_Requirements_PolicyDocument,
  rule:Rule_28517d35_… status is:NotConformant`. The rule text is not on the client; the
  library reads it from `SMS_DeploymentType.SDMPackageXML` (`<Requirements><Rule
  id="Rule_28517d35-…"><Annotation><DisplayName Text="Free Disk Space of system drive Greater
  than 999999999 MB"/>`) - `Get-TKDeploymentTypeRequirementNames`.
* **Content gone from the DP** (cache emptied first). State 6, `ErrorCode` 0x87D01107.
  `CAS.log`: `Submitted CTM job {…}`, `Location update from CTM for content …`;
  `ContentTransferManager.log`: `entered phase CCM_DOWNLOADSTATUS_WAITING_CONTENTLOCATIONS`,
  `Queued location request LSRequest('{…}')`, `CCTMJob::UpdateLocations - Received empty
  location update`, `job suspended`; `LocationServices.log`: `LS Request CorrelationID {…} -
  Calling back with empty distribution points list`. Nothing more is logged afterwards - the
  client waits (`ContentLocationTimeoutInterval` 28800 s in the client config). The content id
  comes from `CCM_AppDeliveryTypeSynclet.InstallAction.Content` (`ContentId`,
  `ContentVersion`), the cache state from `root\ccm\SoftMgmtAgent:CacheInfoEx`.
* **Installer exit 0, nothing written** (a broken here-string in the throwaway installer -
  unplanned, and the most common real case): 0x87D00324 again, this time on a registry rule.
* **`Is64Bit` on registry clauses, measured.** `Is64Bit="true"` (`RegistryPathRedirectionMode`
  0): the client reads the 64-bit view only - key moved to the 32-bit view → `NOT discovered`
  → reinstall. `Is64Bit="false"` (mode 1, what `New-CMDetectionClauseRegistryKeyValue` writes
  without `-Is64Bit`, the console's "32-bit application on 64-bit systems"): the client found
  the key with it in the 32-bit view only *and* with it in the 64-bit view only. The script
  evaluates registry clauses the same way (64-bit strict; "32-bit app: either view", noting
  which view supplied the value) and says when a strict 64-bit clause misses a key that
  exists in the other view. File clauses stay strict per view, with a note when the file
  exists in the other Program Files folder - not measured, the 7-Zip rule carries both
  variants explicitly.
* **Verdict order** now: content / maintenance window / reboot / user session / busy first
  (what the client is doing now), then the last attempt (with a note when it ran an older
  revision than the client now holds), then "no attempt" against the deadline. The client's
  Installed against a false rule evaluated now is its own verdict (device changed since).
* Log files are opened with `FileShare.ReadWrite` - `File.ReadAllText` fails on a log the
  client is writing (`PolicyAgent.log` came back empty).
* `CCM_ApplicationCIAssignment` times: `+***` with `UseGMTTimes=True` are UTC digits, with
  `UseGMTTimes=False` (a deployment on "client local time") local digits - `ToIsoAssignment`.

Test application, collection and source folder removed afterwards.

**Tested through the window, not only through the library** (evening): `AZITC-TK.ps1 -AutoCloseSeconds 70
-SmokeTroubleshoot 'Notepad++'` selects the row like a user and runs the button's handler; the pane
text is printed when the window closes. 17 s, verdict in the status bar, no handler error. The
console on the lab server had still been running 0.2.8 - `Install-AZITCTKConsoleExtension.ps1` is
part of every deploy, not only `Publish`. `update.ps1` (new) does the download for a machine without git -
the AZITC-Toolkit folder of the repository's zip over this folder - and with `-Deploy` runs Publish and
Install afterwards; the AppHelper's update.ps1 was the model. Since 2026-09-16 that is the default:
no parameters = update, publish, install, certificate check off; `-NoDeploy` and `-CertificateCheck`
are the opt-outs.

**Maintenance windows and the execution queue** (2026-09-16, early): the customer's 7-Zip and PDF24
waited with state 3 for a 23:00 window and Refresh changed nothing. `root\ccm\ClientSDK:CCM_ServiceWindow`
lists the upcoming occurrences resolved (ID, Type, StartTime, EndTime, Duration; the local clock with
the +000 quirk; Duration 0 / 2038 is the placeholder); types 1 All deployments, 2 Programs, 3 Reboot,
4 Software updates, 5 Task sequences, 6 Business hours (Software Center) - measured on CLIENT01, which
only has type 6 (22:00-05:00, `No Restricting Service Windows exist` in ServiceWindowManager.log for
Type:2 checks). `root\ccm\SoftMgmtAgent:CCM_ExecutionRequestEx` is ExecMgr's queue (State, RunningState,
NextRetryTime, RetryCount, TaskPauseReason). The script lists both, the verdicts name the next window
that gates applications (types 1 and 2), whether the DT's maximum run time fits into it, whether the
deployment ignores windows, and the queue state. `InstallState = NotUpdated` (installed with an older
revision) got its own verdict and grid wording - and a correction an hour later, from the customer
client: with the window open and ServiceWindowManager saying `Program can run`, the client ran
nothing; AppIntentEval reads the new revision as `Current State = Installed`, compliant. NotUpdated
is Software Center's *Update available*; the new revision is used when somebody starts an action.
The grid counts it as reached, the verdict is OK with that explanation, the action script's watch
loop accepts it as installed.

**Report action** (2026-09-16): right-click on the Device Collections node or a folder below it -
`AZITC: Application compliance report` opens `Anwendungs-Installationsstatus - Compliance-Übersicht` in the
browser. Node GUID `6d357b6b-96b3-45f4-ba09-b74e8ce5a509` (RootNodeDescription `DevicesNode` in
AssetManagementNode.xml; a node's actions show on its folders). `AZITC-TK-OpenReport.ps1` reads
`SMS_SCI_SysResUse` (role SMS SRS Reporting Point: `ReportServerUri` `http://cm01/ReportServer`,
`RootFolder` `ConfigMgr_L01`, `ReportManagerUri` empty on the lab site - the portal is derived,
`/ReportServer` -> `/Reports`) and opens `<portal>/report/<root>/<folder>/<report>`; URL verified with
HTTP 200 and the report path on the lab reporting point. Errors land in a message box. Report and
folder are installer parameters.

**Logs tab** (late evening): `PSADT\*` and the logs the troubleshooter reads (DCMReporting, ServiceWindowManager,
LocationServices) are in the dropdown; the first visit of the tab lists the PSADT folder by itself
(one background job, 16 s on CLIENT01) and puts the files on top of the list, newest first; a listing
no longer removes the standard names. `-SmokeLogs` exercises it.

### Open

* `ScriptType` 1/2 (VBScript/JScript) detection scripts are shown, not run. Setting types
  other than File/Folder/MSI/RegistryValue/RegistryKey are reported as "not evaluated".
* 0x87D01107 and the other client error codes are shown as hex; the client has no message
  table this script can read, the console's DLLs cannot be loaded here.
* Dependencies (`AppIntentEval.log` names them) and "Collect client logs" as a console action.

## 2026-09-14 (evening) - the grid says what it means, not what the class calls it

The user looked at the ConfigMgr applications grid and stopped at two cells: **Resolved =
Installed** on an application that was installed anyway, and **Eval = 8**. The first is not a
statement about the client at all - `ResolvedState` is what the *deployment* wants, so
"Installed" there means "a required deployment targets this device" - and the second is the
number for "waiting for a maintenance window". Neither reads as what it is.

* Three columns instead of two numbers and an enum: **On the device** (Installed / Not
  installed / Unknown, from `InstallState`), **Deployment** (required / optional / removal
  required / not targeted, from `ResolvedState`) and **Status** (the `EvaluationState` in
  words). The raw value of each sits in that cell's tooltip, because a log line or a web
  search is keyed on it. `Get-TKInstallText`, `Get-TKTargetText`, `Get-TKEvalText` and
  `Get-TKAppStateText` in `AZITC-TK.ps1` - not in the library, which is dot-sourced into the
  background runspace only and does not exist on the UI thread where the grids are filled.
* The software list's match column read `7-Zip - 26.02 - Installed/Installed`; it now reads
  `7-Zip - 26.02 (required, installed)`. Header **ConfigMgr application (best guess)** instead
  of "heuristic match", **Offered** instead of "Allowed", **Deployments** instead of "Depl.".
* The watched course of an application action prints the state in words instead of the number,
  and the failure message of `AZITC-TK-CMApp-Action` names the state ("The client could not
  carry the action out: Waiting for a pending reboot") instead of only its number. The client
  script's own table was reworded to match the window's - it runs on the client, where the
  window's file does not exist, so the two tables are duplicates on purpose.
* `reached=True timedOut=False` in the status bar became "reached the wanted state"; the client
  overview's `pending=False hard=False deadline=` line became a sentence.

**Target reached.** The question the grid is opened for - did the deployment get what it asked
for - was still spread over three columns. A first column now answers it in one word, coloured:
**OK** green, **Pending** amber, **Failed** red, *offered* and *not targeted* grey because
neither is a fault. `Get-TKDeploymentVerdict` lets the client's own `EvaluationState` decide
first - it is the only one of the three values that knows about a failure or a wait - and falls
back to comparing what is installed against what the deployment wants. The tooltip spells the
three out: *required deployment, not installed on the device. Client state: Waiting for a
maintenance window.* Sorting by the column puts Failed on top, which is where it belongs.
**Possible actions** is the last rename; "Offered" did not say offered by whom.

**The states nobody here has seen.** `EvaluationState` 14 to 28 were shown as `State 17` and
the like, which is barely better than the bare number the user complained about. They are in
the table now, worded the same way as the rest and taken from the published SDK list: waiting
for a user to be logged on, waiting to try again, waiting for presentation mode to end,
download failed, and the rest. None of them has been watched on a client from here, so the
tooltip of such a cell says where the sentence comes from, and a value the table still does
not know reads "no meaning known for this value".

Where they are acted on differs on purpose. The window may colour 16, 24 and 25 red, because a
colour that turns out wrong costs a glance. The watch loop in `AZITC-TK-CMApp-Action` still
ends only on 4 and 13, the two this site has actually reported: cutting the watch of a run
that is still going, on the strength of a number nobody has seen, is a different kind of
mistake. The tooltip also repeats the sentence itself now, because the column is narrower
than the longest of them.

**One thing to check on a client.** The published SDK list reads *"enforced, soft reboot
pending"* for `EvaluationState` 13 - a finished installation - while this repo's table has
"enforced and failed" and the watch loop in `AZITC-TK-CMApp-Action` breaks out of the wait on
4 **and** 13, reporting a failure. If the published list is right, an installation that only
wants a reboot is reported as failed. Nothing was changed: the wording of 13 stands as it was,
values above 13 are shown as `State <n>` rather than guessed at, and the 4/13 test is
untouched. It takes a client that actually reports 13 to settle it, and this session had none.

## 2026-09-14 (afternoon) - orphaned entries, and the exit code that never arrived

**Orphans.** The user asked what Uninstall does to a leftover Add/Remove Programs key - one whose
product is gone but whose registry detection keeps a required deployment from installing again.
Until now: an MSI leftover got `msiexec /x` -> 1605, "success" with the key still there, exit 1;
an EXE leftover got "Executable not found", exit 2. Honest, but the block stayed.

* `AZITC-TK-Software-Action` now decides **Orphaned** for every entry it inspects: MSI - Windows
  Installer is asked (`WindowsInstaller.Installer.ProductState`, 5 = installed for the machine);
  otherwise the uninstaller named in the key (UninstallString, QuietUninstallString) has to
  exist. `OrphanReason` says which. The Uninstall path's "still exists" error points at
  RemoveEntry when the entry is orphaned.
* New action **`RemoveEntry`**: saves the key's values to `<toolkit log folder>\<stamp>-<name>-removed-key.json`,
  deletes the key, optionally triggers the deployment evaluation (`ReEvaluate`). Refused for a
  per-user entry and for anything not orphaned - "Use Uninstall". Tested on LAB01 with two planted
  leftovers (EXE with a missing uninstaller, MSI with an unknown product code): both recognised,
  both removed with a backup; the real 7-Zip entry refused. On CLIENT01 the validator accepted the
  new value and Google Chrome (MSI, installed) was refused with the ProductState reason.
* Window: **Remove orphaned entry** next to Repair, with the explanation in the confirmation;
  Inspect shows Orphaned / OrphanReason in the result pane.
* `Publish-AZITCTKScripts.ps1` compares the parameter *definition* (allowed values, types,
  defaults, required) with the site's, not only the names, and pushes a changed one through
  `UpdateScript` - same GUID, version + 1. That is what carried `RemoveEntry` into the site's
  `ParamsDefinition`; without it the validator would have rejected the value. The XML builder
  moved into `New-TKScriptParameterXml` so Register and Publish produce the same string.

**Exit codes.** Verified on CLIENT01: a script that ends with `exit 2` is reported by the Run Scripts
host as `ScriptExitCode 0`, `ScriptExecutionState 1`; the only non-zero ever seen came from a
thrown error (Get v1). Scripts.log confirms it ("Non-zero exit code" appears only there). So the
intended code now travels inside the JSON as **`ScriptExit`** (envelope top level for Log-Get),
and the library's `ScriptExitCode` prefers it. Client-Manage refusing to stop CcmExec now reads
`ScriptExitCode=2` where the status row still says 0.

Site: Action v5, Log-Get v5, Client-Action v3, CMApp-Action v3, Client-Manage v3.

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
