# Working notes for this repository

Console extensions ("right-click tools") for the Configuration Manager admin console, one
folder per tool. `README.md` at the root (English) presents both tools; each
tool folder carries its own `README.md` and, where work is ongoing, a `CHANGELOG.md` that is
the handover log - dated, with what was actually run and measured.

- `CollectionMembership\` - manage include-rule membership of a device collection. Done.
- `AZITC-Toolkit\` - tabbed per-device window (Software/ARP first) driven through Run Scripts
  and the AdminService. In progress; start with `AZITC-Toolkit\CHANGELOG.md`.

## Rules

- This repository is **public**. No real host, domain, account, client or customer names in
  code, docs or commit messages - the lab is `LAB01` / `cm01.lab.example` / site `L01`, the lab
  device `CLIENT01`. Commits are made as `azitc-ac <alexander@zarenko.net>` (repo-local git
  config); the history was rewritten once on 2026-09-14 to get the old identity and the real
  names out.
- Windows PowerShell 5.1 everywhere (`powershell.exe`); no PS7-only syntax. All `.ps1` files
  UTF-8 with BOM and CRLF - a normaliser plus parse check before every commit, not after.
- Code, comments, console output in English; the conversation with the user in German.
- AZITC-Toolkit: never reach a client with WinRM, WMI or local admin rights - only Run
  Scripts, CMPivot, AdminService. If something cannot be done that way, say so and stop.
  Destructive actions (Uninstall/Repair) only against the lab device the user names
  (currently CLIENT01); ask before any other device. Never change hierarchy or client settings,
  the script-approval setting included. The user switched off the two-key script approval on 2026-09-11, so the author account
  approves its own scripts (`Approve-TKScript`); do not touch the setting itself.
- Everything created in the hierarchy carries the prefix `AZITC-TK-`.
- Do not present a guess as a fact. When an API shape is unverified, verify it (metadata,
  WMI class definition, SMSProv.log, the SQL objects) and write down where it came from.
- Scratch scripts in a tool folder are prefixed `_` and are ignored by git; delete them when
  the finding has been written into the CHANGELOG.
- Every commit raises `AZITC-Toolkit\VERSION` (last number) through `.githooks/pre-commit`; the
  window shows it in its title. Needs `git config core.hooksPath .githooks` once per clone
  (set on LAB01). A deliberate jump: edit and stage VERSION yourself.
- Commit at milestones; push when asked.
