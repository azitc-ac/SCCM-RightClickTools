# Changelog - AZITC Toolkit

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
