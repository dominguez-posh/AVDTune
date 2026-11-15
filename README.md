# AVDTune

Golden Master management for Azure Virtual Desktop: setup, updates, update block for users, optimization, benchmark, watermark, seal, protocol and change log. Runs locally on the Golden Master. Same look as PackTune.

Status: phase 1 (shell, engine, state, protocol and change log, Overview, start sequence). See docs/plans/avdtune.md.

## Layout

- `Start-AVDTune.ps1`, `UI/AVDTune.xaml`: the window (needs Windows PowerShell 5.1 and administrator rights).
- `Modules/AVDTune.psm1`: engine without UI (machine adapter, state, step contract, change log, Overview data, write gate).
- `Modules/AVDTune.Start.psm1` (first-run questions, environment.json, start stages), `AVDTune.Session.psm1` (sign-in, tokens in memory), `AVDTune.Snapshot.psm1` (VM identity, snapshot, gate), `AVDTune.Directory.psm1` (domain controller over LDAP): the start sequence, see `docs/start-sequence.md`. `AVDTune-Start.ps1` is its part of the window.
- `Modules/AVDTune.Readiness.psm1` and `readiness.json`: the readiness analysis (is the master ready for the v6/v7 VM sizes, and clean enough to become an image). Read only; the criteria are data, each with its Microsoft Learn source, the date it was read and whether Learn really states it (what it does not state is marked "not verified"). Green, yellow, red per check, "not checkable" when Azure cannot be read; red blocks "Abschliessen", yellow needs a confirmation that names every item. `AVDTune-Readiness.ps1` is its card on the Overview. Keep `readiness.json` current: new VM sizes come often.
- `AVDTune-Theme.ps1`, `AVDTune-Protocol.ps1`: AVDTune's own layer on top of the shared PackTune code.
- `Shared/`: copies from PackTune, never edited here. `Tools\Sync-FromPackTune.ps1` copies them and writes `Shared/SOURCE.json` (PackTune commit, SHA256 per file). Change shared code in PackTune first, then sync.
- State on the master: `C:\ProgramData\AVDTune` (Administrators and SYSTEM only).

## Checks

Run from Windows PowerShell, or from Git Bash with `env -u PSModulePath powershell.exe -NoProfile -File ...`:

- `Tests\Check-All.ps1` runs all fast checks (`-Smoke` adds the GUI smoke test).
- `Check-Shared.ps1`, `Check-AVDTune.ps1`, `Check-Readiness.ps1`, `Check-Start.ps1` (start sequence against the fakes in `Tests\Fakes\FakeServices.ps1`), `Check-Protocol.ps1`, `Check-Theme.ps1`; `Invoke-GuiSmoke.ps1` drives the window off-screen with a fake machine and a temporary state folder.

Checks use fakes only. Real runs belong on a throwaway Windows 11 multi-session VM, never on a developer machine.
