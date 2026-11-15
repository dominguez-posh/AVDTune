# AVDTune

Golden Master management for Azure Virtual Desktop: setup, updates, update block for users, optimization, benchmark, watermark, cleanup and finish, protocol and change log. Runs locally on the Golden Master. Same look as PackTune.

Status: phases 1 and 2 (shell, engine, state, protocol and change log, Overview, start sequence, updates and update block) and the readiness analysis. See docs/plans/avdtune.md.

## Layout

- `Start-AVDTune.ps1`, `UI/AVDTune.xaml`: the window (needs Windows PowerShell 5.1 and administrator rights).
- `Modules/AVDTune.psm1`: engine without UI (machine adapter, state, step contract, change log, Overview data, write gate).
- `Modules/AVDTune.Start.psm1` (first-run questions, environment.json, start stages), `AVDTune.Session.psm1` (sign-in, tokens in memory), `AVDTune.Snapshot.psm1` (VM identity, snapshot, gate), `AVDTune.Directory.psm1` (domain controller over LDAP): the start sequence, see `docs/start-sequence.md`. `AVDTune-Start.ps1` is its part of the window.
- `Modules/AVDTune.Readiness.psm1` and `readiness.json`: the readiness analysis (is the master ready for the v6/v7 VM sizes, and clean enough to become an image). Read only; the criteria are data, each with its Microsoft Learn source, the date it was read and whether Learn really states it (what it does not state is marked "not verified"). Green, yellow, red per check, "not checkable" when Azure cannot be read; red blocks "Abschliessen", yellow needs a confirmation that names every item. `AVDTune-Readiness.ps1` is its card on the Overview. Keep `readiness.json` current: new VM sizes come often.
- `AVDTune-Theme.ps1`, `AVDTune-Protocol.ps1`: AVDTune's own layer on top of the shared PackTune code.
- `Shared/`: copies from PackTune, never edited here. `Tools\Sync-FromPackTune.ps1` copies them and writes `Shared/SOURCE.json` (PackTune commit, SHA256 per file). Change shared code in PackTune first, then sync.
- `Modules/AVDTune.Release.psm1`, `AVDTune-Release.ps1`, `VERSION`: integrity check, update check, update, repair and rollback against GitHub releases (card "Integrity and updates" on the Overview), see Releases below. `Tools\New-AVDTuneRelease.ps1` and `.github/workflows/release.yml` build a release.
- State on the master: `C:\ProgramData\AVDTune` (Administrators and SYSTEM only).

## Releases, integrity and updates

A release is made by the workflow `.github/workflows/release.yml` when a tag `vX.Y.Z` (stable) or `vX.Y.Z-ea.N` (early access, marked as pre-release) is pushed on a commit of `main` whose file `VERSION` says the same version. The workflow runs `Tests\Check-All.ps1` (including `Check-PublicContent.ps1`), builds `AVDTune-<version>.zip` and `manifest.json` with `Tools\New-AVDTuneRelease.ps1` from the clean checkout and attaches both to the release. The manifest holds version, commit, date, release notes, size and SHA256 of the ZIP and of every file. Not in the ZIP: `.claude`, `.github`, `Tests`, `Tools`, `docs`, `CLAUDE.md` (the master has no use for them, and every file in the ZIP is one more to verify). The ZIP is reproducible: the same commit gives the same ZIP.

On the master the tool lives side by side in `C:\Program Files\AVDTune\<version>` (administrators only). `current.json` there names the version that the launcher `C:\Program Files\AVDTune\Start-AVDTune.ps1` starts, and the one before it; switching and going back is one atomic write of that file, and a shortcut to the launcher never changes. The first install is by hand: unpack the ZIP of a release anywhere and start `Start-AVDTune.ps1` from it (the card says "not protected" and offers the install into Program Files), then use the launcher.

- At every start AVDTune compares its files with the `manifest.json` of its own version (from GitHub over HTTPS, TLS 1.2, only `github.com` and the hosts GitHub redirects downloads to; the copy saved at install time when GitHub cannot be reached). Missing, changed or extra files (and links) make the card red with the file list; AVDTune is then read only (the write gate stays shut) until "Repair" has downloaded the release again, checked it and put the files right, and AVDTune was started again. A git checkout is not checked ("development copy").
- The update check looks for the newest stable release (early access only when switched on in the card) and shows its release notes. An update is installed only on a click, never during a run or the maintenance mode: ZIP and manifest are loaded, the SHA256 of the ZIP and of every file is checked (nothing missing, nothing extra, no path outside the target), the version is installed next to the running one and switched; the previous version stays and "Back to the previous version" switches back. Every step goes into the protocol and the change log (every change log entry carries the tool version).
- Limit: the hash manifest proves that the files are the ones published on GitHub for that version and unchanged on this master. It does not protect against a compromised GitHub account or repository (whoever can publish a release can publish a matching manifest), and the check runs inside the tool it checks. Authenticode signing can be added later without changing the flow; the publisher would then be pinned as well.

`Tests\Check-PublicContent.ps1` keeps the public repo clean: it fails on GUIDs outside `Tests\` that are not on its list of public IDs, storage account host names (`*.file.core.windows.net`) with a real name, IP addresses outside the documentation ranges (`192.0.2.0/24`, `198.51.100.0/24`, `203.0.113.0/24`), and on every name in the local deny list `%LOCALAPPDATA%\AVDTune\deny-list.txt` (one name per line, never committed; without it the check only notes that names were not checked). A line with `public-content-ok` is skipped.

## Checks

Run from Windows PowerShell, or from Git Bash with `env -u PSModulePath powershell.exe -NoProfile -File ...`:

- `Tests\Check-All.ps1` runs all fast checks (`-Smoke` adds the GUI smoke test).
- `Check-Shared.ps1`, `Check-AVDTune.ps1`, `Check-Readiness.ps1`, `Check-Start.ps1` (start sequence against the fakes in `Tests\Fakes\FakeServices.ps1`), `Check-Protocol.ps1`, `Check-Theme.ps1`, `Check-Release.ps1` (release script, integrity, update, repair, rollback against a fake HTTP adapter and temp folders), `Check-PublicContent.ps1`; `Invoke-GuiSmoke.ps1` drives the window off-screen with a fake machine and a temporary state folder.

Checks use fakes only. Real runs belong on a throwaway Windows 11 multi-session VM, never on a developer machine.
