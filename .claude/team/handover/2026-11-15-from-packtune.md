# Handover 2026-11-15: AVD requests that reached the PackTune session

The user wrote these requests in the PackTune session; they belong to AVDTune. PackTune stopped its work on them. Nothing of it is merged or pushed in PackTune. Take what is useful, check it, and fit it into `docs/plans/avdtune.md` (sections 3a shortcuts, 5a FSLogix, 5b App Masking, Optimization). Ask the user only where this note leaves a real decision open.

## Requests of the user (German, as written)

1. "ist berücksichtigt, dass ich gerne fslogix Hiding Rules für die Desktop ICons verwenden will? Also Alle Verknüpfungen auf den Public Desktop und nur für Admins und freigegebene AD Gruppen die Ansicht zur Verfügung stellen. Das will ich bitte mit eigener Liste im Tool eingebaut haben. Ausserdem will ich Komfort Funktionen wie einen Abmelde Button direkt damit erzeugen lassen können für alle User auf dem Public Desktop mit entsprechendem Icon dahinter"
2. "wenn eine Verknüpfung oder Datei in C:\users\public\desktop erkannt wird, soll diese in der Liste aufgeführt werden und wenn die nochnicht von FSLOgix Hiding Rules berücksichtigt ist, soll das signalisiert werden und über einen Wizard eingerichtet werden können."
3. "Sind die AVD Optimierungen bereits berücksichtigt? z.B. das VDOT Tool und die eigenen Optimierungs Scripts? Die würde ich gerne auch noch mit Best Practises aus dem Web erweitern. Bitte recherchier dazu und mach mir sinnvolle Vorschläge. Der User kann dann aus einer Liste von Optimierungen auswählen und diese dann wahlweise aktivieren. Dazu gehören selbst verständlich auch Defender Ausnahme Regeln etc."
4. "bitte einmal alles rübergeben und auch WDOT übernehmen"

## Decision of the user

- **WDOT replaces VDOT** as the source of the optimization list. VDOT is reference only (its repo says future updates go to the Windows Desktop Optimization Tool). Correct the plan, which assumes VDOT under MIT.
- **License not settled:** VDOT ships an `EULA.txt` plus a sample-code disclaimer ("not intended to be used in a production environment"), not MIT. Read the license of WDOT before reusing any of its data, and say what reuse it allows. If it does not allow reuse, write our own list from Microsoft Learn sources and keep WDOT as a reference only.

## What the user wants in AVDTune (derived from 1 to 3)

- **Desktop list:** every file on `C:\Users\Public\Desktop` (shortcuts and other files) with its state: covered by a hiding rule (visible for whom) or not covered (warning, counter). A wizard sets up hiding: select entries (uncovered preselected), visibility "Everyone" or "Administrators + released AD groups" (default group list, per-entry override), preview of the rule, apply.
- **Comfort shortcuts** on the Public Desktop for all users with a proper icon: Log off first; extendable (for example Restart only where not multi-session, Company Portal, Change password).
- **Optimizations:** a selectable list (checkbox, explanation, risk, source link, presets), including Defender exclusions; extended with researched best practices.

## Findings so far (verified by PackTune developers, sources given)

### FSLogix App Masking (rule files)
From Microsoft Learn (tutorial-application-rule-sets, concepts-fslogix-apps-rule-editor-rule-sets) and Microsoft's `FSLogix/FSLogix.Powershell.Rules` module (tests/QA/TestFiles, GUI-written reference files):
- A rule set is two files, rule `.fxr` and assignment `.fxa`, in `C:\Program Files\FSLogix\Apps\Rules`. The FSLogix Apps service uses them right away; no reload command is documented.
- Hiding rules hide files, folders, registry keys and values, printers and fonts.
- Assignments apply top to bottom (later rows win). For "visible only for admins and released groups": Everyone applies, then Administrators and each released group do not apply.
- **Entra ID cloud-only users and groups are not supported** for assignments. Groups must be synced from AD, and the host needs line of sight to a domain controller to resolve SIDs. This affects the Entra-only identity model in the plan (section 1): there, App Masking by group does not work.
- `.fxr`: UTF-16 LE with BOM, CRLF; line 1 `1`; `##comment`; rule line `<folder>TAB<file>TAB TAB TAB 0x00000222 TAB` for a file, `<folder>TAB TAB TAB TAB 0x00000221 TAB` for a folder. Flags: 0x01 dir/key, 0x02 file/value, 0x20 persistent, 0x200 hiding.
- `.fxa`: same encoding; line 1 `1TAB0`; then `<code>TAB<SID or name>TAB<DN>TAB<display name>TAB0TAB0`. Code bits: 0x01 apply, 0x02 remove, 0x04 user, 0x10 group, 0x20 network, 0x40 computer, 0x80 OU. Well-known groups as SID (Everyone `S-1-1-0`, Administrators `S-1-5-32-544`), other groups by name in Microsoft's module.
- Open: is a domain group SID accepted in the `.fxa` identifier column, or must it be `DOMAIN\Group`? Does "Administrators does not apply" hold for a UAC-filtered admin token? Neither is verified live.
- Discovery idea from PackTune: record the Public Desktop before and after each installation (AVDTune's recorded installation already compares the public desktop, plan section 3b, so new shortcuts come from there).
- Draft code (unchecked, Intune-oriented, for reading only): PackTune repo `C:\git\IntuneChocolateyDeployment`, branch `feature/desktop-masking`, commit 197188d, `PackTune-Desktop.ps1` and `docs/plans/desktop-masking.md`.

### FSLogix antivirus exclusions
Source: https://learn.microsoft.com/en-us/fslogix/overview-prerequisites (section "Configure Antivirus file and folder exclusions", page date 2026-03-09)
- Processes `frxsvc.exe`, `frxccds.exe`; drivers `frxdrv.sys`, `frxdrvvt.sys`, `frxccd.sys`.
- Folders `C:\Program Files\FSLogix\Apps\`, `C:\ProgramData\FSLogix\`, `C:\Users\%username%\AppData\Local\FSLogix\`, Cloud Cache `%ProgramData%\FSLogix\Cache\*` and `%ProgramData%\FSLogix\Proxy\*`.
- `%TEMP%\*\*.VHD(X)`, `%WINDIR%\TEMP\*\*.VHD(X)`; share `\\<share>\*\*.VHD(X)` plus `.lock`, `.meta`, `.metadata`.
- Registry `HKLM\SOFTWARE\FSLogix\`, `HKLM\SOFTWARE\Policies\FSLogix\`; also the profile mount points.
- Same page: the April 2026 Windows Server update changes the default Kerberos encryption from RC4 to AES-SHA1. Profile shares that are not upgraded may lose access (worth a check in AVDTune's FSLogix test).

### Microsoft Defender Antivirus on non-persistent VDI
Source: https://learn.microsoft.com/en-us/defender-endpoint/deployment-vdi-microsoft-defender-antivirus (page date 2026-08-20)
- Shared security intelligence ("Define security intelligence location for VDI clients" or `Set-MpPreference -SharedSignaturesPath`): a management machine unpacks `mpam-fe.exe /x` into a GUID folder under `wdav-update`, once a day, never more often than every 4 hours; share Everyone Read, NTFS Authenticated Users Read.
- PUA Block; local admin merge of lists Disabled; exclusions visible to local admins Enabled; randomize scheduled scans Enabled.
- Headless UI mode, suppress all notifications.
- Cloud protection: Advanced MAPS, extended cloud check 20 s, level High.
- CPU limit 50 %, daily quick scan 12 PM, scan after security intelligence update on (off only while building the base image), update interval 8 hours.
- Default actions Quarantine; tamper protection on.
- Run the "Windows Defender Cache Maintenance" task on the image before sealing.

### VDOT (now WDOT)
Source: https://github.com/The-Virtual-Desktop-Team/Virtual-Desktop-Optimization-Tool
- Categories: AppxPackages, Autologgers, DefaultUserSettings, DiskCleanup, LocalPolicy, NetworkOptimizations, ScheduledTasks, Services, WindowsMediaPlayer; advanced: Edge, RemoveLegacyIE, RemoveOneDrive. JSON per OS folder (`2009` = Windows 10/11); `VDIState = Disabled` applies an item.
- Warnings in the repo: removed AppX payloads cannot be re-provisioned without reset or re-image; disabling the Store install service can block app updates; possible Windows Update errors; Sysprep ordering issues with OneDrive; CDPSvc-related crashes in Settings; some policies break Office licensing or certificate revocation checks. Each needs a risk note in the list.

### Azure/RDS-Templates CustomImageTemplateScripts
Source: https://github.com/Azure/RDS-Templates/tree/master/CustomImageTemplateScripts
- Only date-stamped folders seen (`_2022-11-23` to at least `_2024-03-27`); content and license not verified.

## Not researched yet
Teams (new Teams VDI, SlimCore/WebRTC) and multimedia redirection, FSLogix profile settings beyond the plan, Edge/OneDrive per machine, network/SMB client, Windows Update/Storage Sense, power, time zone redirection, RDP Shortpath, GPU, Start/search, logon speed, presets. Also open: what the user means by "die eigenen Optimierungs Scripts". The PackTune lead read it as Microsoft's AVD image scripts (RDS-Templates); it may mean the user's own old Golden Master scripts (see the start handover). Ask the user.
