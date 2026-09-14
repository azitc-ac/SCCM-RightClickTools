# SCCM Right-Click Tools

Console extensions for the Microsoft Configuration Manager admin console (current branch),
file-based, one folder per tool. Both need Windows PowerShell 5.1 and a console.

| Tool | Right-click on | What it does |
| --- | --- | --- |
| [**AZITC Toolkit**](AZITC-Toolkit/README.md) | a device (Devices node, or a device in a collection's member view) | A tabbed window for that device. **Software (ARP)** - installed software with search and sort, Inspect / Uninstall / Uninstall + re-evaluate / Repair per entry, plus the ConfigMgr applications the client knows with Install / Uninstall / Repair. **Logs** - tail of any client log, or the files of a log folder to pick from. **Client** - facts, pending reboot with its sources, services (start/stop/restart), processes (end), cache (delete/clear), client notifications and schedules. Everything on the client runs as SYSTEM through **Run Scripts**; results come back through the **AdminService**. No WinRM, no remote WMI, no local admin rights on the client. Every run leaves a CMTrace-readable line in `CCM\Logs\AZITC-Toolkit\AZITC-Toolkit.log` on the client. |
| [**CollectionMembership**](CollectionMembership/README.md) | a device collection | "Manage Membership": shows in two tabs (required / available) which collections include the selected collection through an include rule, and adds or removes those memberships. Bilingual, German or English by console language. |

## Installing

Both tools have an installer that finds the console, copies the files, compiles a small
hidden-window launcher with the .NET Framework's `csc.exe` and writes the action XML. Run it as
administrator on the machine with the console, then close and reopen the console.

```powershell
.\AZITC-Toolkit\Publish-AZITCTKScripts.ps1 -SmsProvider <provider FQDN> [-SkipCertificateCheck]   # once per site: the Run Scripts
.\AZITC-Toolkit\Install-AZITCTKConsoleExtension.ps1                                                # per console
.\CollectionMembership\Install-Extension.ps1                                                       # per console
```

**The one setting that hides everything:** since ConfigMgr 2103 the hierarchy setting *Only
allow console extensions that are approved for the hierarchy* (Administration > Site
Configuration > Sites > Hierarchy Settings > General) hides every file-based extension without
a trace - no menu entry, no log line. It has to be off. `CollectionMembership\Verify-Installation.ps1`
checks the files and says so again.

## How the console runs them

An `ActionDescription` of class `Executable` under
`<AdminConsole>\XmlStorage\Extensions\Actions\<node GUID>\` names an executable and its
parameters; the console fills in tokens such as `##SUB:Name##`, `##SUB:ResourceID##`,
`##SUB:CollectionID##`, `##SUB:__Server##` and `##SUB:SiteCode##`. Unknown elements make the
console drop the action silently, so the XML files stay minimal. The node GUIDs used here were
read from the console's own `XmlStorage\ConsoleRoot`:

| GUID | Rows are |
| --- | --- |
| `ed9dee86-eadd-4ac8-82a1-7234a4646e62` | devices in the Devices node (`SMS_CombinedDeviceResources`) |
| `3fd01cd1-9e01-461e-92cd-94866b8d1f39` | devices in a collection's member view |
| `a92615d6-9df3-49ba-a8c9-6ecb0e8b956b` | device collections in the result pane |

`CollectionMembership\Find-DeviceCollectionsGUID.ps1` lists the candidates on any console.

## Repository notes

`CLAUDE.md` carries the working rules; `AZITC-Toolkit\CHANGELOG.md` is the dated log of what
was built, measured and found on a real site. All `.ps1` files are UTF-8 with BOM and CRLF. The
toolkit's version (`AZITC-Toolkit\VERSION`, shown in the window title) is raised with every
commit by the pre-commit hook in `.githooks` - `git config core.hooksPath .githooks` once per
clone.

Author: Alexander Zarenko IT Consulting (AZITC).

## License

MIT - see `LICENSE`.
