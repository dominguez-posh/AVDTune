# AVDTune

Golden Master management for Azure Virtual Desktop: setup, updates, update block for users, optimization, benchmark, watermark, seal, protocol and change log. Runs locally on the Golden Master. Same look as PackTune.

Status: phase 1 (shell, engine, state, protocol and change log, Overview). See docs/plans/avdtune.md.

## Layout

- `Start-AVDTune.ps1`, `UI/AVDTune.xaml`: the window (needs Windows PowerShell 5.1 and administrator rights).
- `Modules/AVDTune.psm1`: engine without UI (machine adapter, state, step contract, change log, Overview data).
- `AVDTune-Theme.ps1`, `AVDTune-Protocol.ps1`: AVDTune's own layer on top of the shared PackTune code.
- `Shared/`: copies from PackTune, never edited here. `Tools\Sync-FromPackTune.ps1` copies them and writes `Shared/SOURCE.json` (PackTune commit, SHA256 per file). Change shared code in PackTune first, then sync.
- State on the master: `C:\ProgramData\AVDTune` (Administrators and SYSTEM only).

## Checks

Run from Windows PowerShell, or from Git Bash with `env -u PSModulePath powershell.exe -NoProfile -File ...`:

- `Tests\Check-All.ps1` runs all fast checks (`-Smoke` adds the GUI smoke test).
- `Check-Shared.ps1`, `Check-AVDTune.ps1`, `Check-Protocol.ps1`, `Check-Theme.ps1`; `Invoke-GuiSmoke.ps1` drives the window off-screen with a fake machine and a temporary state folder.

Checks use fakes only. Real runs belong on a throwaway Windows 11 multi-session VM, never on a developer machine.
