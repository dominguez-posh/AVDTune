# Plan: AVDTune, Golden Master management for Azure Virtual Desktop

Status: PLAN, no product code yet. Lead: AVDTune CTO. Private repo `dominguez-posh/AVDTune`. Replaces the "Golden Master mode inside PackTune" idea of PackTune's `docs/plans/golden-master.md`: same engine ideas (step contract, Test/Apply/Undo, state file, dry run), but as its own tool in PackTune's look, for AVD only.

Decisions of the user (2026-11-15): own repository (private); shared code copied from PackTune by a sync script; first phase is Updates plus the update block for users; watermark stays bound to a machine name pattern; the benchmark engine lives in AVDTune and the AVD-Benchmark repo stays as its stand-alone version.

Sources: a real change log of a Golden Master build (Windows 11 multi-session 25H2 + M365, mid 2026, customer parts left out), the benchmark script `dominguez-posh/AVD-Benchmark`, Microsoft Learn (links per step in the step catalog).

## 1. Goal

AVDTune runs locally and elevated on the Golden Master VM and takes over its whole life: first setup (language, Office, optimizations, VDI components, software), regular maintenance (one update page for Windows, Office and all software), measurement (benchmark per image version), cleanup and seal for capture. Like PackTune it keeps a protocol of everything an administrator did, ready for a ticket, and a change log per image version (the document that is written by hand today).

Not in scope: customer specific software and shortcuts (they come as packages from the library), host pool management in Azure, Citrix/Horizon.

## 2. Shape

- Own entry point `Start-AVDTune.ps1` + `UI/AVDTune.xaml`, same `UI/Theme.xaml`, same shell (own title bar, left navigation, light/dark), same redesign target.
- Elevated on start (refuses to run otherwise), one instance at a time (`Global\AVDTune` mutex). Every winget/choco call also inside `Global\PackTune` so the tools never collide.
- Engine `Modules/AVDTune.psm1` without UI; the steps are data (`AVDTune/steps/*.json`) plus small scriptblocks. UI and command line (`Invoke-AVDTune -Plan x.json -WhatIf`) use the same engine, so checks run against fakes.
- Step contract: Id, Section, Title, Why, Risk, Reboot, Source URL, Test -> state, Apply -> Changed/Unchanged/Failed with before and after, optional Undo. Idempotent; nothing runs without a visible selection; dry run first.
- Shared with PackTune: Theme, sign-in (`Modules/Keevault.psm1`), package store (`PackTune-Store.ps1`), protocol (`PackTune-Protocol.ps1`, new category set), winget/Chocolatey helpers. They live in `Shared/` as copies: `Tools\Sync-FromPackTune.ps1` copies them from a PackTune clone and writes `Shared/SOURCE.json` (PackTune commit, SHA256 per file); `Tests\Check-Shared.ps1` fails when a file in `Shared/` differs from its recorded hash. Changes to shared code are made in PackTune first, then synced.

## 3. Pages

| Page | Content |
|---|---|
| Overview | image name and version, Windows build/UBR, Office build and channel, last update, last benchmark, health: pending reboot, update block on/off (maintenance mode), sealed or not, AVD agent present (must not be), domain/Entra join (must not be) |
| Setup (Ersteinrichtung) | guided order: language and region for all users, Office, VDI components, optimizations, software, user experience. Each block shows what is done and what is left |
| Updates | one list for everything: Windows (WUA COM API, drivers and previews off by default, KB exclude list), Microsoft 365 Apps (ODT `/configure` or `OfficeC2RClient /update`), Edge, Teams (`teamsbootstrapper`), OneDrive, FSLogix, Defender signatures, winget/Chocolatey apps and library packages. "Update all", per item, history. Runs in maintenance mode only |
| Software | packages of the PackTune library (SharePoint) plus winget/Chocolatey catalog: install, update, remove; detection of what is on the master |
| Office | ODT configuration form (channel, 64 bit, languages, excluded apps, `SharedComputerLicensing=1`, `Updates Enabled=FALSE`), preview of `configuration.xml`, install/update/remove, build info. ODT downloaded from Microsoft, Authenticode checked |
| Optimization | VDOT data re-implemented with attribution (AppX, services, tasks, autologgers), visual effects and transparency off for all users, power plan, widgets/news/consumer features/Copilot off, Edge/Chrome (no hardware acceleration, sleeping tabs, no background run), Storage Sense off, telemetry Required, hibernation off, scheduled defrag off, Xbox/gaming removed |
| VDI components | FSLogix install/update + profile settings + `redirections.xml` editor with the cache template (Windows, Edge, Chrome, Teams, Office caches), Defender exclusions for FSLogix, Defender onboarding for non-persistent VDI (package from the library), new Teams for VDI (`teamsbootstrapper -p`, `IsWVDEnvironment`, SlimCore plugin / WebRTC redirector per Microsoft Learn), MMR, RDP Shortpath, time zone redirection, OneDrive per machine |
| User experience | wallpaper (replace `img0.jpg` with ownership handling), watermark (section 5), Start/taskbar layout and default apps for new profiles, public desktop shortcuts and web apps (PWA) with FSLogix App Masking rules per group |
| Update block for users | everything that offers or runs updates is hidden and off for users (section 4) |
| Benchmark | section 6 |
| Cleanup & seal | DISM component cleanup, temp/logs/caches, default profile check, AppX-per-user check (sysprep blocker), BitLocker off, tokens and sign-in caches of AVDTune removed, snapshot reminder, sysprep `/generalize /oobe /shutdown /mode:vm` as the interactive admin (never SYSTEM), typed confirmation |
| Protocol & change log | session protocol like PackTune (ticket text), change log per image version (Version, date, category, component, change type, text) with automatic entries from every step and free notes, export HTML/Markdown, copy to the library folder `AVDTune/<image>` |

## 4. Updates hidden for users, maintenance mode

One switch with a clear state on the Overview. "Blocked" (normal state, also in the image):
- Windows: `SetDisableUXWUAccess=1`, `NoAutoUpdate=1`, `NoAutoRebootWithLoggedOnUsers=1`; services stay as Windows wants them (WaaSMedic reverts disabled services, the policy is the lever); final check after every run.
- Office: `Updates Enabled=FALSE`, policy `EnableAutomaticUpdates=0`, `HideEnableDisableUpdates=1`.
- Edge/Chrome: `UpdateDefault=0`, `AutoUpdateCheckPeriodMinutes=0`, update tasks off. Teams: auto update off. Adobe: `bUpdater=0`, update service off. Store: `AutoDownload=2`. winget/choco: no user access to the scheduled updates.
"Maintenance": AVDTune lifts the blocks for its own run, updates, and sets them back in a `finally` block; the state is written before and after so a crash is detected and repaired at the next start.

## 5. Watermark

Today: a setup script writes a WinForms overlay (base64 in a VBS launcher) and a scheduled task "at logon" for BUILTIN\Users; the overlay shows "PILOTUMGEBUNG" only when the computer name matches a pattern (pilot hosts). The trigger by machine name stays (user decision). Findings in the current script:
- The single-instance mutex is `Global\...`: on a multi-session host only the first user who signs in gets the label, every later session exits at once. Must be `Local\` (per session).
- Primary screen only; with several monitors the label sits on one of them. Redraw every 1.5 s by timer.
- The VBS launcher depends on VBScript, which Microsoft is phasing out (Feature on Demand, later removed). PowerShell plus WinForms costs about 60 to 80 MB per session.
New:
- Name pattern, text, colour, opacity, size and corner as settings in AVDTune (preview on the page), stored in `C:\ProgramData\AVDTune\config\watermark.json`.
- Launcher without VBS (scheduled task with a hidden `conhost --headless` / or a small signed launcher; decided in the build), mutex `Local\AVDTune-Watermark`, all screens, redraw on display change instead of a timer, click-through (WS_EX_TRANSPARENT), no focus, no taskbar entry.
- Migration: AVDTune detects the old task "PilotOverlay" and the VBS file and offers to replace them.
- Optional the Microsoft watermark (QR code with connection ID, policy `fEnableWatermarking`) for forensic needs, and screen capture protection as a hint (host pool setting, not image).

## 6. Benchmark (rework of AVD-Benchmark)

Findings in the current script:
- The internet test downloads the start page of windows.net (a few KB) and computes as if it were 1 GB; on error it reports a fixed 150 Mbps. The value is not real.
- The SMB throughput writes 1 GB and computes with 5000 MB: 5 times too high.
- The mini-file test says 4096 files, writes 1024.
- diskspd: read only (`-w0`), 150 MB file, no latency (`-L`); results not comparable with other tools.
- CPU and "workload" measure the PowerShell interpreter on one core, not the VM; no multi-core value.
- The HTML report is cut off: the here-string is never closed and never written, so the script does not finish.
- The FSLogix share path is hard coded and names a customer storage account in a public repository; `speedtest.exe` (Ookla) is bundled although its licence does not allow redistribution.

New benchmark in AVDTune:
- Fixed profiles with stored parameters: disk local and FSLogix share (diskspd 4K random 70/30 read/write, 64K sequential, latency percentiles), metadata test (small files create/delete on the share), CPU single and multi core (compiled .NET loop or `7z b` if present), memory bandwidth, network: latency to the region and the AVD gateway, download of a fixed Microsoft test file with real size, optional throughput to the share.
- Logon time per phase from the last real logons (User Profile Service events, FSLogix logs) where available.
- Every test 3 times, median, stored as JSON with image version, Windows build, Office build, VM size and region. Comparison with the previous image version, threshold 10%, score per area. Report in the change log and as HTML.
- diskspd downloaded from Microsoft's GitHub release (MIT) and checked; no Ookla binary. The share path comes from the settings (FSLogix `VHDLocations` as default).
- AVD-Benchmark repo: becomes the stand-alone version of the same engine (one script for hosts without AVDTune), customer path removed.

## 7. State, protocol, change log

- On the master: `C:\ProgramData\AVDTune\` (ACL Administrators/SYSTEM): `state.json` (current), `runs\` (one record per run, append only), `changelog.json`, `benchmark\`, `config\` (Office XML, redirections.xml, watermark), `logs\`. No secrets, no tokens.
- Image version `YYYY.MM.NNN` (as in the hand-written log), raised by "start new version"; capture records the gallery version as free text.
- Protocol per session as in PackTune (DE/EN, ready for a ticket), saved locally and to the library.

## 8. Library (SharePoint) on the master

- The master reads the PackTune package store with the same sign-in (Sites.Selected). Trust anchor stays Intune: the manifest hash in the app notes; AVDTune reads it with read-only Intune access. Packages that are only in the library and not in Intune need their own anchor: open question.
- Before seal every token, refresh token and cache of AVDTune and the sign-in is removed and checked; a captured image must not carry an admin session.

## 9. Security

Elevated tool on a machine that becomes the image of all users: runs from a protected copy (`C:\Program Files\AVDTune`, admin-only ACL) with signature check of its files; downloads only from Microsoft/known hosts over HTTPS with Authenticode or hash check; no command lines built from data; the Sicherheitspruefer reviews update block, seal, sign-in on the master and the downloader.

## 10. Checks

`Tests\Check-AVDTune.ps1` (engine against a fake machine: registry, services, tasks, WUA, ODT; idempotency, maintenance mode restored on error, change log), `Check-Benchmark.ps1` (parsers of diskspd output, score, comparison), GUI smoke with fakes. Real runs only in a throwaway Azure VM (Windows 11 multi-session), never on a developer machine.

## 11. Phases

| Phase | Content |
|---|---|
| 1 | Shell in PackTune look, elevation, engine, state, protocol and change log, Overview |
| 2 | Updates page (Windows, Office, Edge/Teams/OneDrive/FSLogix/Defender, software) and update block with maintenance mode |
| 3 | Software from the library and catalog |
| 4 | Benchmark (new engine, comparison per version), AVD-Benchmark repo stand-alone |
| 5 | Setup: Office, language, VDI components, optimizations, user experience, watermark |
| 6 | Cleanup & seal, export, docs and demo |
