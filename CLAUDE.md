# AVDTune

Team: read `.claude/team/README.md` and `.claude/team/RULES.md`. The lead is the session "AVDTune CTO".

- PowerShell 5.1 tool (WPF GUI) that runs locally and elevated on an Azure Virtual Desktop Golden Master: first setup, updates (Windows, Microsoft 365 Apps, software), update block for users with maintenance mode, optimization, benchmark, watermark, cleanup and seal, protocol and change log per image version.
- Same look as PackTune (dominguez-posh/PackTune, clone C:\git\IntuneChocolateyDeployment). Shared code (theme, sign-in, package store, protocol) is copied into `Shared/` by `Tools\Sync-FromPackTune.ps1`; change it in PackTune first, then sync.
- Software comes from the PackTune package store (SharePoint library) and the winget/Chocolatey catalog. Every winget/choco call inside the `Global\PackTune` mutex.
- Plan: `docs/plans/avdtune.md`. First phase: shell, Updates page, update block for users.
- Real runs only on a throwaway Windows 11 multi-session VM, never on a developer machine. Checks run against fakes.
- Private repo, but still no tenant data, IDs, secrets or customer names in code, docs, tests or commits.
