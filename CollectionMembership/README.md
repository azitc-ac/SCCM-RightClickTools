# CollectionMembership - "Manage Membership"

Right-click a **device collection** in the result pane -> **Manage Membership** (German
console: *Mitgliedschaft verwalten*).

The dialog shows in two tabs - **Required** (`ins-req-dev-*`) and **Available**
(`ins-avl-dev-*`) - which collections already include the selected collection as a member
(include rule) and which do not. Arrow buttons move collections left and right; **Save** creates
or removes the include rules.

- `...` button: pick another collection at run time (searches for `rol-dev` by default).
- The name patterns in the header can be changed freely.
- GUI **and** menu entry are bilingual (German / English), chosen by the console language.

## Installation

On the machine with the ConfigMgr console, in an **elevated PowerShell**:

```powershell
.\Install-Extension.ps1
```

Optional parameters:

| Parameter           | Default         | Meaning                                              |
|---------------------|-----------------|------------------------------------------------------|
| `-PatternRequired`  | `ins-req-dev-*` | name pattern of the Required tab                     |
| `-PatternAvailable` | `ins-avl-dev-*` | name pattern of the Available tab                    |
| `-ConsolePath`      | *(auto)*        | AdminConsole folder, when it is not found by itself  |
| `-Language`         | `auto`          | `auto` \| `de` \| `en` - forces the language         |

The installer

1. finds the AdminConsole folder,
2. compiles `nopswindow.cs` -> `nopswindow.exe` (starts PowerShell without a console window),
3. copies the GUI script to `AdminConsole\extensions\RightClickTools\`,
4. writes the action XML to `AdminConsole\XmlStorage\Extensions\Actions\{a92615d6-9df3-49ba-a8c9-6ecb0e8b956b}\`.

Then close the console **completely** and start it again.

## The usual reason the entry is missing

Since ConfigMgr 2103 there is the hierarchy setting **"Only allow console extensions that are
approved for the hierarchy"** (on by default for a 2103 baseline installation). While it is on,
**every legacy file-based extension is hidden without a trace** - no menu entry, no log line.

Switch it off: **Administration > Site Configuration > Sites > (ribbon) Hierarchy Settings >
General** - clear the box - restart the console.

## Diagnostics

```powershell
# Are all files in place?
.\Verify-Installation.ps1

# Lists the device- and collection-related action space GUIDs (to adapt the tool to other objects):
.\Find-DeviceCollectionsGUID.ps1
```

## Uninstall

```powershell
$cp = "D:\Program Files\Microsoft Configuration Manager\AdminConsole"  # adjust
Remove-Item "$cp\XmlStorage\Extensions\Actions\{a92615d6-9df3-49ba-a8c9-6ecb0e8b956b}" -Recurse -Force
Remove-Item "$cp\extensions\RightClickTools\Manage-CollectionMembership.ps1" -Force
Remove-Item "$cp\extensions\RightClickTools\nopswindow.exe" -Force
```

## Technical notes

- **GUID `a92615d6-9df3-49ba-a8c9-6ecb0e8b956b`** = a single device collection in the result
  pane (documented, stable). **Not** the DeviceCollectionsNode GUID `6d357b6b-...` (that is
  the tree node, not the right-click on an item).
- **Action schema** (`Class="Executable"`): the elements are `<FilePath>` and `<Parameters>`.
  Unknown elements or attributes make the console **drop the action silently**.
- All `.ps1` files are saved as **UTF-8 with BOM** (otherwise PowerShell 5.x mangles umlauts).
- Run-time tokens the console replaces: `##SUB:CollectionID##`, `##SUB:Name##`.
- The dialog's own texts live in a `$strings` table with a `de` and an `en` set inside
  `Manage-CollectionMembership.ps1`; code, comments and installer messages are English.

## Prerequisites

- Microsoft Configuration Manager admin console (current branch)
- .NET Framework 4 (for compiling `nopswindow.exe` with `csc.exe`)
- run as administrator
