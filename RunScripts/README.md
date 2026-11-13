# Run Scripts

Scripts meant for the console's **Run Script** action (Software Library > Scripts), written so
that their result is readable in the console's script output window.

## Remove-MisplacedCACertificate.ps1

Finds CA certificates in the wrong computer store and, with `Mode = Remove`, deletes them:

| Store | Misplaced there |
|---|---|
| Intermediate Certification Authorities (`Cert:\LocalMachine\CA`) | self-signed certificates (roots) |
| Trusted Root Certification Authorities (`Cert:\LocalMachine\Root`) | certificates that are not self-signed (intermediates) |

Parameters:

- `Mode` - `Report` (default, changes nothing) or `Remove`.
- `ExcludeThumbprints` - thumbprints to leave alone, separated by comma, semicolon or space.

What it does and does not touch:

- **Self-signed** means the same subject and issuer **and** an Authority Key Identifier that is
  absent or equal to the Subject Key Identifier. A CA key-rollover certificate has the same
  name but is signed by the old key; it belongs in the Intermediate store and is not touched.
- Only certificates in the computer's own **registry** store are removed. A certificate that
  comes from **Group Policy** or from **AD** (the Enterprise store) is listed with
  `left: comes from ...` - a local deletion would come back with the next policy refresh or
  autoenrollment. An Enterprise CA publishes its own certificate to the AIA container, so on
  domain members its root normally sits in the Intermediate store through the Enterprise
  store; that is expected and does not make the verdict `FOUND`.
- `Root Agency`, the self-signed test certificate Windows itself puts into the Intermediate
  store, is listed and left alone.
- Every removed certificate is exported first to
  `%windir%\Logs\MisplacedCACertificates\<yyyyMMdd-HHmmss>\<store>-<thumbprint>.cer`.
  Restore: `certutil -addstore CA <file>` or `certutil -addstore Root <file>`.
- After the removal the store is read again; a certificate still there is `FAILED`.

Output, one object (shown here as the console's *Raw Output* tab shows it):

```json
{
    "Result": "REMOVED - 2 certificate(s), backup in C:\\Windows\\Logs\\MisplacedCACertificates\\20261113-101500",
    "Computer": "CLIENT01",
    "Mode": "Remove",
    "Findings": [
        "Intermediate store holds root: Contoso Root | issuer Contoso Root | expires 2030-01-01 | <thumbprint> | Registry | removed",
        "Root store holds intermediate: Contoso Issuing CA | issuer Contoso Root | expires 2028-06-30 | <thumbprint> | Registry | removed"
    ],
    "Backup": "C:\\Windows\\Logs\\MisplacedCACertificates\\20261113-101500"
}
```

`Result` starts with `OK`, `FOUND` (Report), `REMOVED`, `FAILED` or `ERROR`; certificates
from Group Policy or AD are added as `; N left in place (from Group Policy/AD, not the local store)`.
Because it is the first property, it is also the start of the stored output text. More than
25 certificates are counted, not listed.

Tested on 2026-11-13 as a Run Script on the lab client, with throw-away certificates created
there first (self-signed and signed with `New-SelfSignedCertificate`, private keys deleted):

- Report found the root in the Intermediate store, a root with `Ü` in its name (arrived as
  U+00DC), the self-signed old key of a rollover pair, and the intermediate in the Trusted Root
  store. It left alone the rollover certificate (same name, signed by the old key), two
  properly placed intermediates, `Root Agency`, and the lab's AD CS root that sits in the
  Intermediate store through the Enterprise store.
- The same script with a name-only check (the AKI comparison removed) also reported the
  rollover certificate - the check is what keeps it.
- Remove deleted the four, wrote four `.cer` files, and the following Report was back to `OK`.
- Certificates made with `New-SelfSignedCertificate` (with and without `-Signer`) also showed
  up in the Intermediate store although the test never put them there: an intermediate added
  only to the Root store, and the self-signed old key of the rollover pair, added nowhere.
  Why is not established; worth knowing when building test certificates.

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
