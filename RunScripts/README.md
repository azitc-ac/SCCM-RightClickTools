# Run Scripts

Scripts meant for the console's **Run Script** action (Software Library > Scripts), written so
that their result is readable in the console's script output window.

## Repair-MisplacedCACertificate.ps1

Finds CA certificates in the wrong computer store and, with `Apply` checked, fixes them:

| Store | Misplaced there | Fix (switch, default) |
|---|---|---|
| Trusted Root Certification Authorities (`Cert:\LocalMachine\Root`) | certificates that are not self-signed (intermediates) | **moved** to Intermediate (`MoveIntermediatesFromRoot`, on) |
| Intermediate Certification Authorities (`Cert:\LocalMachine\CA`) | self-signed certificates (roots) | removed (`RemoveRootsFromIntermediate`, **off**) |

Moving, not deleting, is what Microsoft gives as the remedy for intermediates in Trusted Root -
[AD FS / WAP troubleshooting](https://learn.microsoft.com/en-us/windows-server/identity/ad-fs/troubleshooting/ad-fs-tshoot-wap-trust),
and the 2015 Lync/Skype post the two well-known one-liners come from,
[Checks to do in the Lync/Skype for Business Server Certificate Store](https://learn.microsoft.com/en-us/archive/blogs/uclobby/checks-to-do-in-the-lyncskype4b-certificate-store)
(the Intermediate-store check was added there from a reader's comment). Roots in the
Intermediate store are never moved to Trusted Root: that would make them trusted.

Parameters - all switches are `[bool]`, so the Run Script wizard shows them as **check boxes**
(the console reads `[bool]` from the `param()` block as a check box; it does not know `[switch]`
and ignores `ValidateSet` - read from `ScriptParametersPage.ParseParameters` and
`ScriptParametersControl.InitializeGridViewControl` in `AdminUI.Scripts.dll`):

| Parameter | Default | |
|---|---|---|
| `Apply` | unchecked | unchecked = report only, nothing changes |
| `MoveIntermediatesFromRoot` | checked | move intermediates from Trusted Root to Intermediate |
| `RemoveRootsFromIntermediate` | unchecked | remove roots from Intermediate |
| `ExcludeThumbprints` | empty | thumbprints to leave alone, separated by comma, semicolon or space |

What it does and does not touch:

- **Self-signed** means the same subject and issuer **and** an Authority Key Identifier that is
  absent or equal to the Subject Key Identifier. A CA key-rollover certificate has the same
  name but is signed by the old key; it belongs in the Intermediate store and is not touched.
- Only certificates in the computer's own **registry** store are touched. A certificate that
  comes from **Group Policy** or from **AD** (the Enterprise store) is listed with
  `left: comes from ...` - a local change would come back with the next policy refresh or
  autoenrollment. Where a certificate lives is read from the registry location of each
  physical store (`SOFTWARE\Microsoft\SystemCertificates`, `SOFTWARE\Policies\Microsoft\SystemCertificates`,
  `SOFTWARE\Microsoft\EnterpriseCertificates`); Registry and Enterprise were seen in the lab,
  Group Policy is not tested. A certificate that an installer or Intune put into the local
  store looks like any local one; if it comes back after a fix, that is the sign.
- **The root of an AD CS in the Intermediate store is by design.** Measured in the lab AD: the
  Enterprise CA's setup created its certificate in `CN=Certification Authorities`, `CN=AIA`
  and `CN=NTAuthCertificates` (same second), and every domain member mirrors these into the
  Enterprise stores Root, CA (= Intermediate) and NTAuth. AD CS puts every CA certificate into
  the AIA container, roots included. Removing it there is a PKI change outside this script.
- `Root Agency`, the self-signed test certificate Windows itself puts into the Intermediate
  store, is listed and left alone, also with `RemoveRootsFromIntermediate` checked.
- **Move** = add the public certificate to Intermediate (skipped when it is there already),
  read Intermediate again, then remove it from Trusted Root and read Trusted Root again. If the
  add does not show, Trusted Root is not touched (`FAILED`).
- Every changed certificate is exported first to
  `%windir%\Logs\MisplacedCACertificates\<yyyyMMdd-HHmmss>\<store>-<thumbprint>.cer`.
  Restore: `certutil -addstore Root <file>` (or `CA`).

Output, one object (shown here as the console's *Raw Output* tab shows it):

```json
{
    "Result": "FIXED - 1 moved to Intermediate, 0 removed, backup in C:\\Windows\\Logs\\MisplacedCACertificates\\20261113-101500; 2 left by a switch",
    "Computer": "CLIENT01",
    "Settings": "Apply=True, MoveIntermediatesFromRoot=True, RemoveRootsFromIntermediate=False",
    "Findings": [
        "Intermediate store holds root: Root Agency | issuer Root Agency | expires 2040-01-01 | FEE449EE0E3965A5246F000E87FDE2A065FD89D4 | Registry | left: Root Agency (Windows default)",
        "Intermediate store holds root: Contoso Root | issuer Contoso Root | expires 2030-01-01 | <thumbprint> | Enterprise | left: RemoveRootsFromIntermediate is off",
        "Root store holds intermediate: Contoso Issuing CA | issuer Contoso Root | expires 2028-06-30 | <thumbprint> | Registry | moved to Intermediate"
    ],
    "Backup": "C:\\Windows\\Logs\\MisplacedCACertificates\\20261113-101500"
}
```

`Result` starts with `OK`, `FOUND` (report only), `FIXED`, `FAILED` or `ERROR`, followed by
`; N left by a switch` and `; N left (from Group Policy/AD, not the local store)` where that
applies. Because it is the first property, it is also the start of the stored output text.
More than 25 certificates are counted, not listed.

Tested on 2026-11-13 as a Run Script on the lab client, parameters passed the way the console
passes them (booleans as `1`/`0`), with throw-away certificates created there first
(`New-SelfSignedCertificate`, private keys deleted): roots and a root with `Ü` in its name in
Intermediate, a rollover certificate (same name, signed by the old key) and a proper
intermediate in Intermediate, one intermediate only in Trusted Root, one in both.

- Report, default switches: `FOUND - 2 to fix` - "would move to Intermediate" and "would
  remove from Root (already in Intermediate)"; the roots `left: RemoveRootsFromIntermediate is
  off`; rollover certificate and proper intermediate not listed. With
  `MoveIntermediatesFromRoot` unchecked: `OK - nothing to fix; 5 left by a switch`.
- Apply, default switches: `FIXED - 2 moved to Intermediate`. Read back: both intermediates in
  Intermediate and not in Trusted Root, the roots untouched, two `.cer` files.
- Apply with `RemoveRootsFromIntermediate`: the two test roots removed; rollover certificate
  and intermediates stayed; the lab's AD CS root `left: comes from AD (Enterprise store)`;
  `Root Agency` left.
- `Ü` arrived as U+00DC in the stored output.
- Mutants, each run like the real thing - both must break the result, and did:
  - self-signed by name only (AKI comparison removed): also flags the rollover certificate.
  - move without the add to Intermediate: the intermediate ended up in no store. A first
    version still reported it as "moved" - the end-state check (in Intermediate after the
    removal from Root) was added because of this, and the mutant now reports `FAILED`.
- Certificates made with `New-SelfSignedCertificate` (with and without `-Signer`) also show up
  in the Intermediate store by themselves; the test clears CA and Root before placing them.
  Why is not established.

## Why the output looks like this - measured

Measured in the lab with probe scripts on a client and by reading the console's
`AdminUI.Scripts.dll` (`ScriptOutputView`):

- The console's output window parses the output as JSON when it starts with `{` or `[`. If it
  does, it shows a tree (*JSON Output*) and indented JSON (*Raw Output*). Anything else goes
  into one text box after `Trim()` and `Trim('"')` - **without unescaping**.
- What the client stores, per kind of output:

  | Script output | Stored / shown |
  |---|---|
  | several `Write-Output` strings | `["line one","line two"]` |
  | one string with line breaks | `line one\r\nline two` - literal `\r\n`, one line |
  | `Format-Table \| Out-String` | `\r\nStore Subject\r\n----- -------\r\n...` |
  | `Write-Host` lines | `host one host two` - joined by spaces |
  | `Write-Host` + `Write-Warning` + `Write-Output` | `host line WARNING: a warning "output line` |
  | objects | real JSON - tree and indented raw view |
  | `Write-Error` | not shown at all |
  | `throw` after output | state **Failed**, output **empty** - what came before is lost |

- `exit N` arrives as exit code 0 (see `AZITC-Toolkit\CHANGELOG.md`, 2026-09-14); only a
  thrown error makes a run *Failed*.
- Characters outside ASCII are broken by default: powershell.exe writes stdout in the OEM code
  page and the client reads it as ANSI (`Ü` arrived as `š`). After
  `[Console]::OutputEncoding = [System.Text.Encoding]::Default` in the script, `Ü ä ß é €`
  arrived intact; characters outside the ANSI code page become a best-fit letter or `?`. UTF-8
  makes it worse (`Ãœ`). Measured on one lab client only; a client with a different ANSI code
  page is not tested.
- The status list cuts the output at 4000 characters; the detail window fetches the full text.

So: return exactly **one object** with the verdict as its first property, put lines into a
string array, set the output encoding to ANSI, never write to the host, never throw.
