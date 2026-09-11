# Working notes for this repository

Console extensions ("right-click tools") for the Configuration Manager admin console, one
folder per tool. `README.md` at the root (German) describes the tools for their users; each
tool folder carries its own `README.md` and, where work is ongoing, a `CHANGELOG.md` that is
the handover log - dated, with what was actually run and measured.

- `CollectionMembership\` - manage include-rule membership of a device collection. Done.
- `AZITC-Toolkit\` - tabbed per-device window (Software/ARP first) driven through Run Scripts
  and the AdminService. In progress; start with `AZITC-Toolkit\CHANGELOG.md`.

## Rules

- This repository is **private** at the moment, so real names may appear in docs. If it is
  ever made public, scrub first (see the sibling repos for how that went).
- Windows PowerShell 5.1 everywhere (`powershell.exe`); no PS7-only syntax. All `.ps1` files
  UTF-8 with BOM and CRLF - a normaliser plus parse check before every commit, not after.
- Code, comments, console output in English; the conversation with the user in German.
- AZITC-Toolkit: never reach a client with WinRM, WMI or local admin rights - only Run
  Scripts, CMPivot, AdminService. If something cannot be done that way, say so and stop.
  Destructive actions (Uninstall/Repair) only against the lab device the user names
  (currently CLIENT01); ask before any other device. Never change hierarchy or client settings,
  the script-approval setting included. The script author account cannot approve its own
  scripts here (`TwoKeyApproval = 1`); approval comes from a second admin account.
- Everything created in the hierarchy carries the prefix `AZITC-TK-`.
- Do not present a guess as a fact. When an API shape is unverified, verify it (metadata,
  WMI class definition, SMSProv.log, the SQL objects) and write down where it came from.
- Scratch scripts in a tool folder are prefixed `_` and are ignored by git; delete them when
  the finding has been written into the CHANGELOG.
- Every commit raises `AZITC-ToolkitVERSION` (last number) through `.githooks/pre-commit`; the
  window shows it in its title. Needs `git config core.hooksPath .githooks` once per clone
  (set on LAB01). A deliberate jump: edit and stage VERSION yourself.
- Commit at milestones; push when asked.
