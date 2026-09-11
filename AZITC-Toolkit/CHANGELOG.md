# Changelog - AZITC Toolkit

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
