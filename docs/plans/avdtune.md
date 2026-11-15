# Plan: AVDTune, Golden Master management for Azure Virtual Desktop

Status: PLAN, phase 1 in progress. Lead: AVDTune CTO. Public repo `dominguez-posh/AVDTune` (public since 2026-11-15; no customer names, hosts, tenant data or IDs, ever). Replaces the "Golden Master mode inside PackTune" idea of PackTune's `docs/plans/golden-master.md`: same engine ideas (step contract, Test/Apply/Undo, state file, dry run), but as its own tool in PackTune's look, for AVD only.

Decisions of the user (2026-11-15): own repository (private); shared code copied from PackTune by a sync script; first phase is Updates plus the update block for users; watermark stays bound to a machine name pattern; the benchmark engine lives in AVDTune and the AVD-Benchmark repo stays as its stand-alone version.

Sources: a real change log of a Golden Master build (Windows 11 multi-session 25H2 + M365, mid 2026, customer parts left out), the benchmark script `dominguez-posh/AVD-Benchmark`, Microsoft Learn (links per step in the step catalog).

## 1. Goal

AVDTune runs locally and elevated on the Golden Master VM and takes over its whole life: first setup (language, Office, optimizations, VDI components, software), regular maintenance (one update page for Windows, Office and all software), measurement (benchmark per image version), cleanup and seal for capture. Like PackTune it keeps a protocol of everything an administrator did, ready for a ticket, and a change log per image version (the document that is written by hand today).

Not in scope: customer specific software and shortcuts (they come as packages from the library), host pool management in Azure, Citrix/Horizon.

## 1a. Start: sign-in, domain, snapshot gate (added 2026-11-15)

Nothing changes the master before these three steps are done; the Overview shows them as a short start sequence.

1. **Microsoft 365 / Azure sign-in.** A normal interactive Microsoft sign-in, without Keevault (user decision 2026-11-15: AVDTune never uses the Keevault password manager or its fill-in). One sign-in with four token audiences (the fourth, Azure Storage for the NTFS rows of the FSLogix check, is optional, issue 18): Microsoft Graph (SharePoint site of the environment, read of Intune app notes for the package trust anchor), Azure Resource Manager (snapshot of the OS disk, VM size and region for the benchmark), and the PackTune package store (Sites.Selected). The app registration needs `user_impersonation` on Azure Service Management in addition to PackTune's permissions; the setup assistant adds it. Tokens live in memory only and are removed and checked before seal.
2. **Domain** (only for the identity models with a domain controller, section 1b; with Entra only this step is skipped and groups come from Entra ID through Graph). The master is not domain joined (it must not be, because of sysprep), so the user enters the IP (or name) of a domain controller and a domain account with the rights to create groups in an OU. AVDTune reads everything else itself from the DC: RootDSE (domain DNS name, NetBIOS name, naming contexts, functional level), the OU tree, existing groups and their SIDs, the site, optionally the DNS servers. Connection: LDAPS 636 first; fallback LDAP 389 only with Negotiate signing and sealing; never a simple bind in clear text. The certificate of the DC is shown on first contact (thumbprint) and pinned per environment. The password stays in a SecureString in memory, never on disk, never in the protocol.
3. **Snapshot gate.** AVDTune finds its own VM through the Azure Instance Metadata Service (subscription, resource group, VM, OS disk) and offers "Create snapshot now" (incremental snapshot of the OS disk; name pattern per environment, default as in the user's current process `<OS disk name>-DD.MM.YYYY-N` with a counter per day; tags with image version, user and "CreatedWith=AVDTune"). It then checks that a finished snapshot of the OS disk exists that is **newer than the last change AVDTune made on the master** (user decision 2026-11-15; with no change recorded yet, any finished snapshot counts), and the user confirms by typing their full name (at least first and last name; not matched against the sign-in, because shared admin accounts are used, user decision 2026-11-15; the protocol and change log record the typed name together with the signed-in account and the local Windows account): "Ich bestaetige, dass vor diesem Lauf ein Snapshot des Golden Masters erstellt wurde und ein Rollback moeglich ist." Name, time, snapshot resource ID and whether AVDTune made it go into the protocol and the change log. Without the confirmation every page is read only. Rollback hint on the Overview: how to create a disk from the snapshot and swap the OS disk.

## 1b. First run: environment wizard and automatic FSLogix setup (added 2026-11-15)

On the first start (no `environment.json` yet) a wizard asks how the AVD environment is planned. The answers decide which pages, checks and steps exist; they can be changed later (with a change log entry).

| Question | Choices |
|---|---|
| Join of the session hosts | Entra ID only (no hybrid join) / Microsoft Entra hybrid join / AD DS join only |
| Domain controller | none / AD DS in Azure (VM) / AD DS on premises over VPN or ExpressRoute / Microsoft Entra Domain Services |
| Identities of the users | cloud only / synchronized (Entra Connect / Cloud Sync) |
| Profiles | FSLogix profile container on Azure Files / on another SMB share (e.g. Azure NetApp Files, file server) / no FSLogix |
| Azure Files authentication | follows from the answers: AD DS (with DC), Microsoft Entra Kerberos (hybrid or cloud-only identities), Entra Domain Services |
| Network | private endpoint (recommended) / public endpoint with firewall; VNet and subnet of the session hosts; private DNS zone `privatelink.file.core.windows.net` in Azure or on the own DNS servers |

What follows from the identity model:
- **Entra ID only**: no DC step; groups for App Masking and the FSLogix include/exclude lists are Entra groups created through Graph (`Group.ReadWrite.All` only during that action), referenced by their SID (`S-1-12-1-...`); Azure Files with Microsoft Entra Kerberos; session hosts need `CloudKerberosTicketRetrievalEnabled=1` and `LoadCredKeyFromProfile=1` (set in the image); the Entra app of the storage account needs admin consent and must be excluded from Conditional Access policies that require MFA (AVDTune checks both). Support for cloud-only identities in Azure Files is verified against Microsoft Learn in phase 0 of this part and shown on the page with its status. **FSLogix App Masking does not support Entra ID cloud-only users and groups in assignments** (Microsoft Learn, tutorial-application-rule-sets; groups must be synced from AD and the host needs line of sight to a DC to resolve SIDs). So with Entra only, App Masking by group is not offered: the Public Desktop page (5c) can only show an entry for everyone or hide it for everyone (and the user is told why); with hybrid identities, groups synced from AD work.
- **Hybrid / AD DS**: DC step of section 1a; groups in the chosen OU; Azure Files with AD DS (or Entra Kerberos for hybrid identities, choice in the wizard).
- **Without FSLogix**: the FSLogix pages are hidden, the seal checklist drops the FSLogix test.

Automatic FSLogix setup (first setup, every step shown as a plan with the Azure resources and their settings before anything is created, then done one by one with a result per step):
1. **Storage account**: use an existing one (check) or create one: kind FileStorage, Premium (SSD) with LRS or ZRS (the wizard explains the choice), secure transfer, TLS 1.2, no public blob access, public network access off when a private endpoint is used, SMB settings (SMB 3.1.1, AES-256 Kerberos, AES-256-GCM channel encryption). An existing Standard account gets a yellow "not recommended for FSLogix profiles" with the reason (latency, IOPS).
2. **Share**: name, provisioned size, quota and expected IOPS/throughput shown (size per user x users), the profile folder layout.
3. **Private endpoint**: in the chosen subnet, private DNS zone `privatelink.file.core.windows.net` with a VNet link (or the record for own DNS servers is shown to be created there). Check from the master: the name resolves to the private IP, TCP 445 reachable, public endpoint refused.
4. **Identity of the storage account**: AD DS: computer account in the chosen OU over LDAP, the account's Kerberos key from ARM set as its password, SPN set, `activeDirectoryProperties` set on the storage account (the same steps as Microsoft's AzFilesHybrid module, done without that module; checked against it in the build). Entra Kerberos: enable on the storage account, domain information for hybrid identities, admin consent for the storage account app, Conditional Access exclusion checked and explained (not changed automatically).
5. **Share permissions**: default share-level permission or role assignments (Storage File Data SMB Share Contributor for the user group, Elevated Contributor for the admin group).
6. **NTFS ACLs**: Microsoft's FSLogix recommendation set on the root by OAuth over REST (Privileged Contributor), shown as a diff first.
7. **FSLogix on the master**: install, profile settings with `VHDLocations` pointing to the new share, `redirections.xml`, Defender exclusions, Entra Kerberos registry values where needed.
8. **Test**: the full FSLogix and storage check of section 5a.

Required rights are checked before the plan is shown (Contributor on the resource group, Network Contributor on the subnet and the DNS zone, User Access Administrator or Role Based Access Control Administrator for the role assignments, Application Administrator for the consent of Entra Kerberos, OU rights in AD) and missing ones are named with the reason.

Documentation: the wizard answers and every created or checked resource (resource IDs, SKU, endpoint IP, DNS record, auth type, roles, ACL as SDDL, FSLogix settings) form the environment document "Umgebung" in the change log, as HTML/Markdown export and in the SharePoint list of the environment. `environment.json` on the master holds the answers and resource IDs, never secrets.

## 2. Shape

- Own entry point `Start-AVDTune.ps1` + `UI/AVDTune.xaml`, same `UI/Theme.xaml`, same shell (own title bar, left navigation, light/dark), same redesign target.
- Elevated on start (refuses to run otherwise), one instance at a time (`Global\AVDTune` mutex). Every winget/choco call also inside `Global\PackTune` so the tools never collide.
- Engine `Modules/AVDTune.psm1` without UI; the steps are data (`AVDTune/steps/*.json`) plus small scriptblocks. UI and command line (`Invoke-AVDTune -Plan x.json -WhatIf`) use the same engine, so checks run against fakes.
- Step contract: Id, Section, Title, Why, Risk, Reboot, Source URL, Test -> state, Apply -> Changed/Unchanged/Failed with before and after, optional Undo. Idempotent; nothing runs without a visible selection; dry run first.
- Shared with PackTune: Theme, sign-in (`Modules/PackTune.SignIn.psm1`, without Keevault), package store (`PackTune-Store.ps1`), protocol (`PackTune-Protocol.ps1`, new category set), winget/Chocolatey helpers. They live in `Shared/` as copies: `Tools\Sync-FromPackTune.ps1` copies them from a PackTune clone and writes `Shared/SOURCE.json` (PackTune commit, SHA256 per file); `Tests\Check-Shared.ps1` fails when a file in `Shared/` differs from its recorded hash. Changes to shared code are made in PackTune first, then synced.

## 1c. Initial analysis on the first run (user decision 2026-11-15)

The first run ends with one guided "Erstanalyse" after the environment wizard (1b), all sign-ins and connections (M365/Azure, DC when used, FSLogix share and storage account when used) and the snapshot gate (1a), and before AVDTune changes anything:
1. Readiness and hygiene analysis (section 2a).
2. Inventory: Windows build/UBR, Office build and channel, installed software with versions, drivers, FSLogix settings, update block state, existing scheduled tasks and leftovers of earlier scripts.
3. Storage and FSLogix check (section 5a) when FSLogix is used.
4. Baseline benchmark (section 6), with the share of the environment.
The result is the document "Ausgangszustand" (version 0 of the change log): stored locally, in the SharePoint list of the environment, and the reference for every later benchmark and diff. It can be repeated by hand (e.g. after a rollback to the snapshot), and the user chooses which run stays the baseline.

Before every seal the same check runs again as "Healthcheck" (user decision 2026-11-15): readiness and hygiene (2a), inventory, FSLogix and storage check (5a) and the benchmark (6). It is required: the seal button stays locked until a healthcheck of the current state passed (red items fixed, yellow ones acknowledged by typed name) and nothing was changed after it. The result is logged in the protocol, the change log of the version ("Healthcheck vor Seal", with the diff to the baseline and to the last sealed version) and the SharePoint list. The healthcheck can also be run by hand at any time.

While the benchmark engine is not built yet (phase 5), the initial analysis runs without step 4 and says so; the baseline benchmark is then offered once at the next start, marked as "taken after changes" when AVDTune changed something in between.

## 2a. Readiness analysis: is the master set up correctly, ready for current VM sizes (added 2026-11-15)

A read-only analysis on the Overview ("Bereitschaft"), run at every start and as part of the seal checklist. Each check is green/yellow/red with the reason, the source (Microsoft Learn) and a fix where AVDTune can do it (always as a step with confirmation and change log entry). The list of VM families and what they need is data (`AVDTune/readiness.json`), checked against Microsoft Learn when the analysis is built and kept current with releases, because new sizes come often.

Hardware generation (v6/v7 sizes and later):
- **NVMe**: the current OS disk controller of the VM (ARM: `storageProfile.diskControllerType`, IMDS); the Windows NVMe driver `stornvme` present and set to start at boot (Microsoft's NVMe conversion sets it for Windows; a master that only ever ran on SCSI may not have it); if the VM still runs on SCSI, the conversion path is shown (switch the controller with the VM deallocated, script from Microsoft).
- **Network adapter**: the Microsoft Azure Network Adapter (MANA) driver present (needed for accelerated networking on the newer sizes) besides the Mellanox driver of older sizes; accelerated networking on the VM's NIC.
- **No temp disk / NVMe temp disk**: many new sizes have no temp disk or only an NVMe temp disk that is not formatted at start; the page file and any path on `D:` (page file, FSLogix temp, TEMP variables, application caches) are flagged, because a master built on a size with a `D:` drive breaks on such sizes.
- **Generation 2 / Trusted Launch**: UEFI boot, Secure Boot, vTPM on the VM; the image definition in the Azure Compute Gallery (when it can be read with the sign-in) has the features `DiskControllerTypes` = `SCSI, NVMe`, `SecurityType` = Trusted Launch supported, accelerated networking supported, architecture x64. A capture into a definition without NVMe would produce an image that cannot start on v6/v7.
- **Sizes**: list of the v6/v7 families that this master can run on, and what is missing for the others (e.g. Arm64 families need an Arm64 image: shown as not possible, not as a fix).

Image hygiene (from the same analysis):
- Windows 11 multi-session edition and build, servicing state (supported or end of service), last cumulative update age.
- AVD agent and boot loader not installed, master not domain or Entra joined, no host pool registration token in the registry, BitLocker off, no pending reboot, no pending Windows setup operations.
- Update block for users active (section 4), FSLogix test passed (5a), Defender onboarding not executed on the master itself, language packs complete for all users.
- Azure VM agent present and current, time sync, no leftovers of earlier tools (old scheduled tasks, VBS launchers, folders such as installer exports).

Result: stored with every run, in the change log of the version and in the SharePoint list; a red item blocks the seal, a yellow one needs a typed acknowledgement.

## 3. Pages

| Page | Content |
|---|---|
| Overview | image name and version, Windows build/UBR, Office build and channel, last update, last benchmark, health: pending reboot, update block on/off (maintenance mode), sealed or not, AVD agent present (must not be), domain/Entra join (must not be) |
| Setup (Ersteinrichtung) | guided order: language and region for all users, Office, VDI components, optimizations, software, user experience. Each block shows what is done and what is left |
| Updates | one list for everything: Windows (WUA COM API, drivers and previews off by default, KB exclude list), Microsoft 365 Apps (ODT `/configure` or `OfficeC2RClient /update`), Edge, Teams (`teamsbootstrapper`), OneDrive, FSLogix, Defender signatures, winget/Chocolatey apps and library packages. "Update all", per item, history. Runs in maintenance mode only |
| Software | packages of the PackTune library (SharePoint) plus winget/Chocolatey catalog: install, update, remove; detection of what is on the master |
| Office | ODT configuration form (channel, 64 bit, languages, excluded apps, `SharedComputerLicensing=1`, `Updates Enabled=FALSE`), preview of `configuration.xml`, install/update/remove, build info. ODT downloaded from Microsoft, Authenticode checked |
| Optimization | selectable list (section 5d): WDOT data re-implemented with attribution (AppX, services, tasks, autologgers), Defender VDI preset, visual effects and transparency off for all users, power plan, widgets/news/consumer features/Copilot off, Edge/Chrome (no hardware acceleration, sleeping tabs, no background run), Storage Sense off, telemetry Required, hibernation off, scheduled defrag off, Xbox/gaming removed |
| FSLogix | setup, settings, `redirections.xml`, function test (section 5a) |
| App Masking | FSLogix hiding rules for icons and apps, groups in the domain (section 5b); Public Desktop list with hiding wizard and comfort shortcuts (section 5c) |
| VDI components | Defender onboarding for non-persistent VDI (package from the library), new Teams for VDI (`teamsbootstrapper -p`, `IsWVDEnvironment`, SlimCore plugin / WebRTC redirector per Microsoft Learn), MMR, RDP Shortpath, time zone redirection, OneDrive per machine |
| User experience | wallpaper (replace `img0.jpg` with ownership handling), watermark (section 5), Start/taskbar layout and default apps for new profiles, public desktop shortcuts and web apps (PWA) with FSLogix App Masking rules per group |
| Update block for users | everything that offers or runs updates is hidden and off for users (section 4) |
| Benchmark | section 6 |
| Cleanup & finish ("Abschliessen") | the last button of a version (section 7a; the word "seal" elsewhere in this plan means this step): healthcheck that must be green, cleanup, tokens removed, restart check, change log to SharePoint, log off or shut down; the image is then made from a copy by Hydra (or another imaging tool), the master is never sysprepped. Sysprep on the master only as an expert option |
| Protocol & change log | session protocol like PackTune (ticket text), change log per image version (Version, date, category, component, change type, text) with automatic entries from every step and free notes, export HTML/Markdown, copy to the library folder `AVDTune/<image>` |

## 3a. Web apps (PWA) as a fourth software source (added 2026-11-15)

Software sources: winget, Chocolatey, custom applications (PackTune library) and web apps (PWA).

Findings in the current script (`deploy-pwa-apps-goldenmaster.ps1` of a customer environment):
- The value names of `WebAppInstallForceList` are written as `[string]1`, `[string]2` ... (PowerShell passes `-Name [string]$counter` as the text "[string]1"; checked). Edge reads a list policy only from values named 1, 2, 3, so most likely no web app was ever force-installed; the users get the shortcuts only.
- The shortcuts start `msedge.exe --app=<url>`. Such a window is not the installed web app: the taskbar groups it by Edge's own identity, so the icon of the shortcut is not the icon of the running window and a pinned icon does not match the window. This is the icon problem.
- The counter starts at 1 on every run and overwrites force-list entries made by other means.
- `$fslogixRules` is used but never set (error at the first `Test-Path`); the FSLogix rules are made by hand afterwards.
- `StartupBoostEnabled=1` and `BackgroundModeEnabled=1` keep an Edge process per user in the background: on a multi-session host this costs memory for every session and contradicts the browser optimization.
- The icons are base64 inside the script (1.1 MB script).

New:
- A web app entry: name, start URL, optional manifest id, icon (upload `.ico`/`.png`/`.svg`; or read from the site's web manifest and pick the largest; AVDTune makes a multi-size `.ico` 16 to 256 px and shows it in taskbar size as a preview), window mode, shortcut on the public desktop and/or Start menu, optional App Masking group (section 5b; the rule is made with it).
- Stored as a package of the kind `webapp` in the PackTune library (manifest with SHA256 like the other kinds; icon as file), so PackTune can later deploy the same web apps through Intune. The store format change is made in PackTune first, then synced.
- Install: Edge policy `WebAppInstallForceList` with correct value names, merged with existing entries (AVDTune only touches the entries it owns, marked by URL). The shortcut starts the installed app the way Edge does (`msedge_proxy.exe --profile-directory=Default --app-id=<id>`) and carries the same AppUserModelID as the app window, so the taskbar shows the chosen icon for the shortcut, the pinned entry and the running window. The icon is also set for the installed app (policy option for a custom icon where Edge supports it, otherwise the app's own manifest icon and only the shortcut uses the custom icon). Sites that are not installable (no manifest) get an app window with its own AppUserModelID set on the shortcut.
- The exact app id and AppUserModelID scheme of Edge and which policy options Edge honours (`custom_name`, `custom_icon`) are verified in a spike on a Windows 11 multi-session VM before the build: pinned icon, running window, Start menu, after a logon with FSLogix.
- Migration: AVDTune reads the existing list (names, URLs, base64 icons) from such a script and offers to import it as web app entries.

## 3b. Printer drivers from a print server (added 2026-11-15)

Users must not install printer drivers themselves (Point and Print restriction since PrintNightmare), so every driver of the print server has to be in the image.

Findings in the current script (`Install-PrinterDriver.ps1` of a customer environment):
- `pnputil /export-driver *` exports every third-party driver of the server (network, storage, VM drivers of a domain controller), and all of them are added to the image's driver store.
- The drivers are only added to the driver store (`pnputil /add-driver`), not installed as printer drivers (`Add-PrinterDriver`), so the version that Point and Print expects may still be missing.
- `TrustedHosts` is overwritten (other entries lost) and stays set; WinRM over HTTP with a domain admin; the password as a placeholder in the script; `C:\PrinterdriverToImport` stays in the image.

New (page "Drucker", identity models with a domain; with Entra only the page points to Universal Print):
1. The user picks the print server (list of print servers found in AD, or a name). AVDTune reads its shared printers with driver name, version, architecture, package-aware or not, with the domain account of the start sequence (spooler RPC, no WinRM needed).
2. The user selects printers (default: all shared); the needed drivers are the distinct drivers of those printers.
3. Install per driver: package-aware drivers by a temporary printer connection as admin (`Add-Printer -ConnectionName`), which downloads exactly the server's driver package, then the connection is removed and the driver stays. Drivers that are not package-aware: only their own INF and files are exported on the server (`pnputil /export-driver <oem>.inf`, by WinRM only when needed, `TrustedHosts` appended and restored), copied, installed with `pnputil /add-driver` plus `Add-PrinterDriver`; temporary files removed on both sides.
4. Point and Print policies in the image: `RestrictDriverInstallationToAdministrators=1`, package Point and Print limited to the chosen server(s) (`PackagePointAndPrintServerList`), so users connect printers without prompts and without driver installs.
5. Check: each selected driver installed with the server's version; result in the change log (driver, version, server, printers that use it).

Maintenance: the Updates page compares the driver versions on the print server with the installed ones, shows new and changed drivers and drivers of printers added on the server since the last run, and updates them like software (in maintenance mode, change log entry). Drivers no printer of the server uses any more can be removed.

## 3c. Coverage of the hand-written Golden Master log (checked 2026-11-15)

Every general step of the real change log and where it is in AVDTune. Customer software (DMS, accounting, ERP clients and their ini/registry details) is not built in; it comes as packages or as own steps.

| Step in the log | In AVDTune |
|---|---|
| Base image from the Marketplace (Windows 11 25H2 multi-session + M365, NVMe) by Terraform | out of scope for building; the Overview and the change log record the source image (publisher, offer, SKU, version from the Instance Metadata Service), disk controller and VM size |
| German language for all users, reboot test | Setup: language and region for all users, default user and welcome screen, reboot check |
| Visual effects, transparency, power plan | Optimization |
| Defender onboarding for non-persistent VDI (local scripts, rollout through Hydra) | VDI components: onboarding package from the library, check that it must not run on the master itself |
| Benchmark before and after optimization | Benchmark (section 6, baseline and before every seal) |
| VDOT | Optimization list from WDOT, the successor (data re-implemented, 5d) |
| Defender exclusions | FSLogix (section 5a) |
| Browser hardware acceleration, sleeping tabs | Optimization |
| Widgets, news, Start ads, Bing search | Optimization |
| Windows and Office updates | Updates |
| Remove Xbox/gaming | Optimization |
| 7-Zip, Adobe Reader, runtimes (x86/x64), password manager | Software (winget/Chocolatey/library) |
| Printer drivers from the old DC | Printers (section 3b) |
| Office reinstalled in German | Office page (language in the ODT form) |
| NTFS of `C:\admin` adjusted | Cleanup: check of admin folders on C: (scripts, exports, installers) readable by users; AVDTune's own folders are admin-only; offer to remove or lock them before seal |
| Windows Update and Update Orchestrator disabled | Update block (section 4; policy instead of disabled services, with reason) |
| Public desktop shortcuts, PWAs, FSLogix hiding rules | Shortcuts and web apps (section 3a, 3d), App Masking (5b) |
| Watermark for the pilot | Watermark (section 5) |
| Windows update that failed (one KB) and DISM cleanup / RestoreHealth | Updates: result code per update with explanation, retry, `DISM /RestoreHealth` and `sfc` as repair steps offered on failure, component cleanup in Cleanup |
| Host file entries for servers | Own steps: hosts file entries (section 3d) |
| Wallpaper replaced (`img0.jpg`, owner TrustedInstaller) | User experience (with ownership restored), optional lock screen image |
| Shortcuts with arguments and working folder on network shares, own icons | Shortcuts (section 3d) |
| Folder structures for an application | Own steps |
| Fonts installed | Fonts (section 3d) |
| Shared computer activation for Microsoft 365 | Office page |
| FSLogix `redirections.xml` (incl. the WAM/TokenBroker excludes that were added and removed again) | FSLogix (5a), WAM/TokenBroker never excluded, with reason |
| Default user profile reset to a fresh Windows state | Cleanup: check of `C:\Users\Default` against a clean reference (size, extra folders, NTUSER.DAT changes), reset offered |
| .NET Desktop Runtime as a dependency, .NET security updates | Software; Windows Update with "updates for other Microsoft products" (Microsoft Update service registered) so .NET, and other Microsoft products get updates |
| Edge, Acrobat, password manager updates | Updates |

## 3d. Shortcuts, fonts, own steps (added 2026-11-15)

- **Shortcuts**: public desktop and/or Start menu; target, arguments, working folder (also UNC paths), icon (file from the library or extracted from the target), App Masking group. Listed with a check whether target and icon are reachable.
- **Fonts**: install for all users from the library (`.ttf`/`.otf`), listed and removable.
- **Own steps** for customer details without code in AVDTune: registry value, ini value, hosts file entry, folder with permissions, file copy from the library, script from the library (signed or with SHA256 from the library manifest). Each own step has Test/Apply like the built-in steps, runs again after a rollback, and is recorded in the change log.

## 4. Updates hidden for users, maintenance mode

One switch with a clear state on the Overview. "Blocked" (normal state, also in the image):
- Windows: `SetDisableUXWUAccess=1`, `NoAutoUpdate=1`, `NoAutoRebootWithLoggedOnUsers=1`; services stay as Windows wants them (WaaSMedic reverts disabled services, the policy is the lever); final check after every run.
- Office: `Updates Enabled=FALSE`, policy `EnableAutomaticUpdates=0`, `HideEnableDisableUpdates=1`.
- Edge/Chrome: `UpdateDefault=0`, `AutoUpdateCheckPeriodMinutes=0`, update tasks off. Teams: auto update off. Adobe: `bUpdater=0`, update service off. Store: `AutoDownload=2`. winget/choco: no user access to the scheduled updates.
"Maintenance": AVDTune lifts the blocks for its own run, updates, and sets them back in a `finally` block; the state is written before and after so a crash is detected and repaired at the next start.

## 3e. Custom software: install wizard with recording (added 2026-11-15)

Customer software (DMS, accounting, ERP clients, vendor installers with dialogs, licence servers, ini files) is often installed by hand, sometimes together with the vendor. A sandbox test is not possible on the master (an Azure VM, the software needs the real network, servers and licences). So AVDTune records the real installation on the master and makes it reproducible.

**Wizard "Neue Software"**
1. Details: name, vendor, version, contact or ticket of the vendor, installer source (file from a share or upload; SHA256 and signature are recorded), dependencies (runtimes, .NET, VC++), licence notes (text; no licence keys, no passwords: the wizard says so and the secret check of the protocol cleans the text).
2. Start recording. A red frame and a small toolbar (pause, note, mark step, stop) show that it runs. Based on the user's own screen tools (`dev-team-framework/tools/screen`: live recording with toolbar, step images with arrow and text), adapted for this.
3. During the recording AVDTune collects:
   - **Steps**: a screenshot at every mouse click and at Enter, with the window title, the clicked element (UI Automation name, e.g. button "Weiter") and a red mark where it was clicked; the admin can add a note or mark a step as important. Key presses are never logged as text (no keylogger); password fields are never captured (UI Automation `IsPassword`), the window is blurred instead.
   - **Processes**: every process started during the recording with its command line (secrets removed), so silent install switches and the real installer chain become visible.
   - **System changes**: a before/after comparison of installed programs (uninstall keys with version and product code), files in Program Files, ProgramData, the public desktop and the Start menu, `HKLM\SOFTWARE` (and WOW6432Node), services, scheduled tasks, drivers, firewall rules, ODBC data sources, environment variables, hosts file, fonts, shortcuts, printers.
4. Stop, then review: timeline of the steps (captions editable, steps deletable, areas blurrable before anything is stored), the list of changes, the processes. AVDTune proposes a **detection rule** (uninstall key and version or a file version) and, if the processes show one, a **silent install command**.
   - **Notes window** (user decision 2026-11-15): a small window beside the installer, always on top but never captured in the screenshots, where the admin writes free notes at any time (what was agreed with the vendor, why an option was chosen, what to watch at the next update). Each note is linked to the step that was current when it was written and shown there in the documentation; notes can also be written after the recording in the review.
5. Save. The documentation is generated automatically and is complete: every click is one step with its screenshot (full window plus a zoom on the clicked area with the red mark), a generated sentence ("Klick auf 'Weiter' im Fenster 'Setup - Produkt 5.2'"), time, and the admin's notes at that step; between the steps the processes started and the system changes that appeared at that moment. It opens with a summary (software, version, source with SHA256, duration, admin, image version, number of steps, detection rule, silent command if found) and ends with the full change list. HTML (navigable, every image enlargeable) and PDF. Besides it: change list, recipe (machine-readable: source, commands, detection, follow-up steps such as ini values, shortcuts, App Masking). The recipe uses the format of PackTune's custom applications where it fits, so a recorded app can later become a PackTune package. Change log entry of the image version.

**List of custom software** (page Software, tab "Eigene Software")
- Every recorded app with the installed version (by its detection rule), the last documented version, the date and admin of the last installation or update, and a link to every documentation (all versions, newest first).
- "Update erfassen": the same wizard in update mode; the documentation of the last installation or update is shown beside it while recording, step by step, so the admin can follow it. The new documentation is stored as a new version; the difference to the last one (steps, changes) is shown.
- "Neu installieren": with a silent recipe AVDTune installs on its own; otherwise it shows the recorded steps as a checklist on top (step image, text, done), and records again.
- Optional watched source: a share folder or URL of the vendor; when a newer installer appears there (file version or name), the list shows "neue Version verfuegbar". Also part of the Updates page.

**SharePoint** (site of the environment, section 7): one folder per app and version with documentation, step images, change list, recipe and (optional) the installer files with SHA256; a list "AVDTune Software" (app, vendor, version, kind install/update, image version, date, admin, links to documentation and folder, detection rule). Everything is written there after saving; when SharePoint is not reachable it waits in the local queue. The local copy under `C:\ProgramData\AVDTune\software\` stays until it is confirmed in SharePoint and is removed before seal (step images may show internal data, they do not belong in the image).

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

Built (#12, branch feature/12-watermark): `Watermark\` (overlay `Show-AVDTuneWatermark.ps1`, shared validation `AVDTune-WatermarkCore.ps1`), `Modules\AVDTune.Watermark.psm1` (steps `userexperience.watermark-*`), page User experience (`AVDTune-UserExperience.ps1`), checks `Tests\Check-Watermark.ps1`.
- Files: program folder `C:\Program Files\AVDTune\Watermark` (admin-only); read-only settings copy for users in `C:\ProgramData\AVDTune-Public\watermark.json` (own folder, ACL Users read, Administrators/SYSTEM write, a folder someone else prepared is refused); never inside `C:\ProgramData\AVDTune`.
- Task `AVDTune Watermark`: logon trigger, principal group S-1-5-32-545 by SID, least privilege, no time limit, `powershell.exe -WindowStyle Hidden -NoProfile -NonInteractive -ExecutionPolicy Bypass -File <script>`. The console window of powershell.exe is created before the hide flag is read, so it can flash for a moment (documented behaviour of the host, not verified visually here). Option "Headless": `conhost.exe --headless powershell.exe ...` avoids it; it works on this Windows 11 build (checked: the command ran) but is undocumented by Microsoft and reported by EDR rules, so it is off by default. Not verified: the logon task for the group on a live multi-session host, mixed-DPI monitors.
- Microsoft watermark (optional switch): Learn page `azure/virtual-desktop/watermarking` (verified 2026-11-15) gives options and ranges (QR scale 1-10, opacity 100-9999 default 2000, grid width 100-1000 default 320, height 100-1000 default 180, connection ID or device ID) and the warning that unsupported clients cannot connect and RemoteApp is not marked. The registry value names (`HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services`: fEnableWatermarking, WatermarkingQrScale, WatermarkingOpacity, WatermarkingWidthFactor, WatermarkingHeightFactor) are NOT on that page (ADMX): not verified on a live host. The QR content option (device ID) is not set.
- Old overlay: task `PilotOverlay` and `C:\ProgramData\PilotOverlayLauncher.vbs` are detected, shown and removed only on its own confirmation (backup in `config\watermark-legacy.json`, undo restores). Taking over the old name pattern from the old script is not done.

## 5a. FSLogix setup and function test

Setup:
- Install or update FSLogix (download from Microsoft, Authenticode check), version shown on the Updates page.
- Profile container settings as a form with Microsoft's recommended values and an explanation per value: `Enabled`, `VHDLocations` (or Cloud Cache `CCDLocations`), `VolumeType=VHDX`, `IsDynamic=1`, `SizeInMBs`, `DeleteLocalProfileWhenVHDShouldApply`, `FlipFlopProfileDirectoryName`, `LockedRetryCount`/`LockedRetryInterval`, `ReAttachRetryCount`/`ReAttachIntervalSeconds`, `PreventLoginWithFailure`/`PreventLoginWithTempProfile`, `ProfileType`; optional Office container (ODFC). Include/exclude groups (`FSLogix Profile Include List`/`Exclude List`) with groups from the domain (section 1a).
- `redirections.xml` editor with the cache template from the change log (Windows, Edge, Chrome, Teams, Office caches; no exclusion of WAM/TokenBroker, which broke SSO in the change log), written to the profile share's `redirections.xml` path setting (`RedirXMLSourceFolder`) or locally.
- Defender exclusions for FSLogix (VHD/VHDX, `%ProgramFiles%\FSLogix\Apps\frxdrv.sys` etc., Microsoft's list) and the local administrators exclusion (built-in Administrators must be excluded from the profile).
- Azure Files: the authentication type of the share (AD DS or Entra Kerberos) is read from the storage account with the Azure sign-in, shown and checked (share and NTFS permissions as Microsoft recommends: Users modify on the share root only "this folder", Creator Owner on subfolders).

Function test ("FSLogix-Test", also part of the seal checklist):
1. Installed version, services `frxsvc` and `frxccds` running, filter driver loaded (`fltmc`).
2. Registry valid (required values present, no typos in paths, no conflicting Cloud Cache plus VHDLocations).
3. Each `VHDLocations` path: DNS resolution, TCP 445 reachable, SMB session, Kerberos ticket for `cifs/<host>` when AD auth is used.
4. Permissions: create a test folder, write/read/delete a file, check the effective NTFS rights on the root against the recommendation.
5. VHDX test: `frx create-vhd` of a small dynamic VHDX in the share, mount it, write, dismount, delete (proves VHDX creation, locking and the driver without a real user).
6. `redirections.xml` parses and matches the editor; Defender exclusions present; local Administrators in the exclude list.
7. Optional with a test user from the domain: sign-in of a test user is not possible on the master itself without join, so the real logon test runs on a session host after rollout; AVDTune reads the FSLogix logs and `frx list-redirects` there through the Benchmark/Status script in the stand-alone package.
Result: green/yellow/red per step with a fix hint, stored in the change log.

Storage account check through the Azure sign-in (added 2026-11-15, user idea). There is no short-lived storage key in Azure Files: the account key is long-lived and gives full access. So AVDTune uses the user's token, not a key:
1. Find the storage account from `VHDLocations` (host name) in the subscriptions the user can see.
2. Domain join of the storage account (ARM, Reader): `azureFilesIdentityBasedAuthentication` (AD DS or Entra Kerberos), `activeDirectoryProperties` (domain name, domain GUID, domain SID, storage account SID, sAMAccountName, account type). Compared with the DC over LDAP (section 1a): the computer or service account exists, its SID matches `azureStorageSid`, the SPN `cifs/<account>.file.core.windows.net` is set, domain GUID/SID match, and `pwdLastSet` against the domain's maximum password age. An expired password of that AD object is a common cause of FSLogix logon failures; AVDTune warns before it happens and explains the rotation (`Update-AzStorageAccountADObjectPassword`, only on the user's explicit order, because it changes the Kerberos key).
3. SMB settings of the file service (ARM): SMB versions, Kerberos ticket encryption (AES-256), channel encryption, authentication methods, so the session host can connect at all. Network: public access or private endpoint, and whether the share name resolves to the private IP from the master.
4. Share-level permissions (ARM): the default share-level permission and the role assignments on the share (Storage File Data SMB Share Contributor / Elevated Contributor) for the user groups and the admins.
5. NTFS ACLs (data plane, OAuth over REST, no key): with the role "Storage File Data Privileged Reader" the user's token reads the SDDL of the share root and the profile folders (`x-ms-file-request-intent: backup`) and compares them with Microsoft's recommendation for FSLogix (Users: modify, this folder only; Creator Owner: modify, subfolders and files; admins full; no Users access to other users' folders). With "Storage File Data Privileged Contributor" AVDTune can set the recommended ACL on the root, only after a shown diff and the user's confirmation, recorded in the change log.
6. Real access test as a domain user: with the domain account from the start sequence (or a test user the admin enters) AVDTune opens an SMB session to the share with Kerberos against the given DC (`runas /netonly`-style logon in a separate process), creates its folder, writes, reads and deletes a file, and runs the VHDX test of step 5 as that user. This proves Kerberos, share permission and NTFS together.
7. Fallback with the account key only when the token path is not possible (role missing) and only after the user confirms it for this run: key fetched with `listKeys`, used for one SMB mapping in memory, mapping removed at the end, key never written to disk, protocol or log; the change log records that the key was used. AVDTune never rotates or regenerates keys on its own.

Roles the admin needs: Reader on the storage account, Storage File Data Privileged Reader (read ACLs) or Privileged Contributor (fix ACLs); `listKeys` only for the fallback. The page shows which of them are missing.

## 5b. App Masking (FSLogix hiding rules) with the domain

- Page lists every rule set in `C:\Program Files\FSLogix\Apps\Rules` (`.fxr` + `.fxa`) with what it hides (public desktop shortcuts, Start entries, folders, registry) and the group it is assigned to.
- New rule set from: a shortcut on the public desktop, a Start menu entry, an installed app (uninstall key) or a web app (PWA) shortcut. AVDTune writes the rule file (hide rules for the `.lnk`, optional folders and registry) and the assignment file.
- Groups: for each rule set the user chooses an OU once (OU tree from the DC); AVDTune creates the group `<prefix>-App-<name>` there if missing (naming pattern in the settings, description "AVDTune App Masking: <name>"), reads its SID and writes the assignment by SID: everyone hidden, members of the group shown. Existing groups can be chosen instead.
- Membership is not managed in AVDTune (that stays in AD), but the page shows the member count and links the group.
- The FSLogix Apps service uses new rule files right away (no reload command is documented); AVDTune verifies after writing that both files parse and the assignment is readable. Each change goes into the change log (rule, group, OU, SID).
- Migration: the rules made today with the FSLogix Rule Editor are read and shown; unknown parts of a rule are kept as they are.
- File formats (from Microsoft Learn and Microsoft's `FSLogix.Powershell.Rules` module, reference files written by the Rule Editor): `.fxr` and `.fxa` UTF-16 LE with BOM, CRLF. `.fxr`: line 1 `1`, `##` comments, a rule line per hidden file or folder with flags (0x02 file, 0x01 folder, 0x20 persistent, 0x200 hiding). `.fxa`: (exact header and fields: see the byte format below, which corrects this first reading) one line per assignment (`<code><TAB><SID or name><TAB><DN><TAB><display name><TAB>0<TAB>0`, code bits 0x01 apply, 0x02 do not apply, 0x04 user, 0x10 group, 0x20 network, 0x40 computer, 0x80 OU); rows apply top to bottom, later rows win. "Visible only for admins and released groups" = Everyone (`S-1-1-0`) applies, then Administrators (`S-1-5-32-544`) and each released group do not apply.
- **Byte format as the FSLogix Rule Editor writes it** (checked 2026-11-15 against 32 working rule sets of a real environment that the user provided locally; the user's experience: only rule files made with the Rule Editor worked, hand-made ones did not). AVDTune writes exactly this, byte for byte; tests compare generated files with golden files:
  - Both files: UTF-16 LE with BOM `FF FE`, every line ends with CRLF, including the last one.
  - `.fxr`: line 1 is `1` (no tab). Before **every** rule line a line `##`. Rule line for a file: `<folder>` TAB `<file name>` TAB TAB TAB `0x00000222` TAB (5 tabs, a tab at the end). The public desktop is written as `%SystemDriveFolder%\Users\Public\Desktop`, not `C:\...`. Several shortcuts in one rule set = several `##` + rule line pairs. A rule set that hides nothing is just `1` CRLF (8 bytes).
  - `.fxa`: line 1 is `1` TAB (a tab, no `0`). Then one row per assignment, 6 fields separated by tabs, code as `0x%08X`:
    - Everyone: `0x00000011` TAB `S-1-1-0` TAB (empty DN) TAB `Everyone` TAB `0` TAB `0` (0x10 group + 0x01 rule applies).
    - Built-in Administrators: `0x00000012` TAB `S-1-5-32-544` TAB `<DN of the Builtin Administrators group, in the domain's language>` TAB `<localized display name, e.g. BUILTIN\Administrators>` TAB `0` TAB `0` (0x10 group + 0x02 rule does not apply).
    - Released domain group: `0x00000012` TAB `DOMAIN\Group` (by **name**, not SID) TAB `<distinguished name>` TAB `DOMAIN\Group` TAB `<Windows FILETIME of when the row was added, decimal>` TAB `0`.
  - So for "visible only for admins and released groups": Everyone applies, then Administrators and each group do not apply (rows apply top to bottom).
  - The localized names and DNs (built-in group name in the domain's language, NetBIOS name) come from the DC (section 1a); the FILETIME is the time AVDTune writes the row.
  - Likely causes of failing hand-made files (to be confirmed by the spike): missing BOM or UTF-8, LF instead of CRLF, missing final CRLF, missing trailing tab, header `1<TAB>0` instead of `1<TAB>`, group given by SID, missing `##` lines.
- The user's sample files stay outside the repo (they contain customer names and groups). The checks use synthetic golden files made with the same structure; an optional local check compares AVDTune's output with the samples when their folder is given (`AVDTUNE_FXSAMPLES`), never in CI.
- Still verified in a spike on a test VM before the build: that FSLogix applies AVDTune's files (same bytes as the Rule Editor's), and whether "Administrators do not apply" also holds for an admin with a UAC-filtered token.
- Correction by the user (2026-11-15): the master is **not** domain joined. Today the rules are made with the Rule Editor on a domain-joined pilot session host and then copied to the master. AVDTune writes them directly on the master instead: the names, DNs and the localized built-in Administrators entry come from the DC over LDAP (section 1a), so no joined machine and no copying are needed. The readiness check "no domain or Entra join" (2a) stays as it is. Rules copied in from a pilot host are read and shown like any other rule set.
- **Local groups as the switch (user request 2026-11-15)**: instead of putting a domain group into the `.fxa`, AVDTune creates a **local group** per rule set on the master (e.g. `AVDTune-App-<name>`, prefix in the settings) and assigns the rule to that local group. Which users are in it is decided on each session host: the local group gets AD groups and/or Entra groups as members. So the same image works for AD, hybrid and Entra-only environments, and the Entra-only limitation above (FSLogix cannot resolve Entra groups) is worked around, because FSLogix only has to find a local group in the user's logon token.
  - Membership on the session hosts: the master cannot hold AD or Entra members (it is not joined, and generalizing changes local SIDs). So AVDTune puts a small startup task into the image (SYSTEM, at boot, before logons are allowed by the AVD agent) that reads `C:\ProgramData\AVDTune\appgroups.json` (local group name -> AD group SIDs and Entra group object IDs/SIDs, written by AVDTune; SIDs read from the DC over LDAP or from Graph) and sets the members of the local groups (add missing, remove members AVDTune put there that are no longer listed, never touch members added by others). Result per boot in the event log. Alternative for environments that already manage it centrally: membership by Group Policy (Restricted Groups / Preferences) or Intune; AVDTune then only creates the local groups and shows what to configure.
  - **Built-in groups by well-known SID** (user decision 2026-11-15): Administrators (`S-1-5-32-544`), Users (`S-1-5-32-545`), Remote Desktop Users (`S-1-5-32-555`), Everyone (`S-1-1-0`), Authenticated Users (`S-1-5-11`) and the like are always written and chosen by their well-known SID; the display name is resolved at write time on the machine (`SecurityIdentifier.Translate`), so the right localized name (e.g. German "Administratoren") is entered automatically and a German or English image both work. Never a hard-coded name.
  - **AD groups as members** (user decision 2026-11-15): the AD group is simply made a member of the local group of the shortcut. AVDTune tries this directly on the master by the group's SID from the DC (a domain SID stays the same after generalization, so the membership would survive the imaging); whether Windows accepts a domain SID as member of a local group on a machine that is not joined is part of the spike. If it does, the startup task is not needed for AD groups (only for Entra groups); if not, the startup task adds the AD group by SID at boot on the joined session hosts.
  - AVDTune shows per rule set: local group, its intended AD/Entra groups, and on the master that the membership is applied only on session hosts.
  - Per environment selectable: "lokale Gruppe (AD oder Entra)" (default once the spike passes) or "AD-Gruppe direkt" (as today with the Rule Editor).
  - **Spike before the build** (test VM, both an AD-joined and an Entra-joined session host): (1) how a local group must be written in the `.fxa` (the Rule Editor on a host writes `<HOSTNAME>\<group>`; a captured image runs on many host names, so check `.\<group>`, `BUILTIN`-style, plain name, or the SID after generalization) and that FSLogix applies it; (2) that a user who is member only through a nested AD group, and only through a nested Entra group, gets the local group in the token and sees the shortcut; (3) that local groups and the startup task survive the imaging from a copy (Hydra) including generalization; (4) the timing: membership set before the first user logon after boot. If (1) or (2) fails, the option is not offered and the reason is documented.
- Reference for reading only: an unchecked draft in the PackTune repo (local branch `feature/desktop-masking`, `PackTune-Desktop.ps1`, `docs/plans/desktop-masking.md`) made before the work moved here.

## 5c. Public Desktop: list, hiding wizard, comfort shortcuts (user request 2026-11-15, handed over from the PackTune session)

- **List** of every file on `C:\Users\Public\Desktop` (shortcuts and other files) with target, icon and its state: covered by a hiding rule (visible for whom: everyone / administrators + released groups / named groups) or **not covered** (warning, counter on the page and on the Overview). New entries appear after every software installation (the recorded installation already compares the public desktop, 3e) and on every start.
- **Wizard "Sichtbarkeit einrichten"**: select entries (uncovered ones preselected), choose visibility "Alle" or "Administratoren + freigegebene AD-Gruppen" (a default group list in the settings, override per entry), groups created in the chosen OU if missing (5b), preview of the rule lines, apply, change log entry. With Entra only: only "Alle" or "fuer alle ausgeblendet", with the reason (5b).
- **Comfort shortcuts** for all users on the Public Desktop with a proper icon (from Windows' own icon libraries, or an `.ico` shipped with AVDTune): "Abmelden" first (`shutdown.exe /l`, no confirmation dialog, icon from `shell32.dll`); extendable list: "Passwort aendern" (Ctrl+Alt+End equivalent through the Windows security screen), Company Portal when installed, "Restart" only on single-session hosts (never on multi-session). Each comfort shortcut is a normal entry of the list (visible for everyone by default, can be restricted).

## 5d. Optimization list (handed over from the PackTune session, user decision 2026-11-15: WDOT replaces VDOT)

A selectable list (checkbox, explanation, risk, before/after, source link), with presets "AVD multi-session (empfohlen)", "Konservativ", "Alles"; nothing is applied without selection; each item is a step with Test/Apply/Undo where reversible.

Sources:
- **Windows Desktop Optimization Tool (WDOT)**, `The-Virtual-Desktop-Team/Windows-Desktop-Optimization-Tool` (successor of VDOT; checked 2026-11-15: repository licence MIT, copyright 2025 The Virtual Desktop Team; the repo also ships `EULA.txt`, Microsoft's sample-code terms: use and modify allowed, copyright notice required, "not intended to be used in a production environment", indemnity clause). Use: its configuration data (names of AppX packages, services, scheduled tasks, autologgers, registry values per Windows version) re-implemented as our own step data with attribution, both texts in `NOTICE`, no script code copied, no runtime dependency. Names of Windows services and tasks are facts; the selection and the explanations are ours. VDOT stays a reference only.
- Microsoft Learn pages per item (link in the step).
- The user's own earlier Golden Master scripts (visual effects and transparency for all profiles and the default profile, power plan, widgets/news/consumer features/web search off, Edge/Chrome sleeping tabs and efficiency mode, Defender exclusions and scan settings, Start layout), re-implemented generically. Findings in them that the list corrects, with the reason shown:
  - Windows Search service disabled: on multi-session it breaks Outlook search and Start search; the list keeps search on (per-user index is the multi-session default) and offers "disable" only with that warning.
  - Edge/Chrome `HardwareAccelerationModeEnabled` is set to 1 (on), while the change log says hardware acceleration was turned off: the list asks explicitly (off on VMs without GPU, on with GPU) and shows the current value.
  - Defender: scheduled scan, scan on idle and catch-up scans disabled: weakens protection against Microsoft's VDI guidance; replaced by the Defender VDI preset below.
  - Start layout through `StartLayoutFile` (XML): not supported for the Start menu on Windows 11 (only the taskbar); Start pins go through `ConfigureStartPins` (JSON) or the default profile.
- Risk notes from WDOT/VDOT itself, each on its item: removed AppX payloads cannot be re-provisioned without a reset or re-image; disabling the Store install service can block app updates; possible Windows Update errors; Sysprep ordering issue with OneDrive; Settings crashes related to CDPSvc; some policies break Office licensing or certificate revocation checks.

Defender for non-persistent VDI (preset, Microsoft Learn `deployment-vdi-microsoft-defender-antivirus`, page date 2026-08-20):
- Shared security intelligence location for VDI clients (`SharedSignaturesPath`; a management machine unpacks `mpam-fe.exe /x` into a GUID folder under `wdav-update` once a day, never more often than every 4 hours; share Everyone Read, NTFS Authenticated Users Read): AVDTune sets the path on the image and checks that the share is readable; the update job itself runs outside the master (documented).
- PUA block; local admin merge of lists off; exclusions visible to local admins on; randomize scheduled scans on; headless UI and notifications suppressed; cloud protection Advanced MAPS, extended cloud check 20 s, level High; CPU limit 50%; daily quick scan 12:00; scan after security intelligence update on (off only while building the image); update interval 8 hours; default actions quarantine; tamper protection on.
- Run the scheduled task "Windows Defender Cache Maintenance" before seal (seal checklist).

FSLogix antivirus exclusions (Microsoft Learn `overview-prerequisites`, page date 2026-03-09): processes `frxsvc.exe`, `frxccds.exe`; drivers `frxdrv.sys`, `frxdrvvt.sys`, `frxccd.sys`; folders `C:\Program Files\FSLogix\Apps\`, `C:\ProgramData\FSLogix\`, `C:\Users\%username%\AppData\Local\FSLogix\`, Cloud Cache `%ProgramData%\FSLogix\Cache\*` and `\Proxy\*`; `%TEMP%\*\*.VHD(X)`, `%WINDIR%\TEMP\*\*.VHD(X)`; the share `\\<share>\*\*.VHD(X)` plus `.lock`, `.meta`, `.metadata`; registry `HKLM\SOFTWARE\FSLogix\`, `HKLM\SOFTWARE\Policies\FSLogix\`. Part of 5a and of this list.

Kerberos RC4 to AES (same Learn page): the April 2026 Windows Server update changes the default Kerberos encryption from RC4 to AES-SHA1; profile shares that are not upgraded may lose access. Part of the storage check in 5a (supported encryption types of the storage account's AD object and of the SMB settings).

Still to research for the list (feature developer, with sources, before the Optimization page is built): new Teams VDI and multimedia redirection details, FSLogix profile settings beyond 5a, Edge/OneDrive per machine, SMB client and network settings, Storage Sense, power, time zone redirection, RDP Shortpath, GPU policies, Start and search, logon speed (Run keys, Active Setup, AppX on first logon).

## 6. Benchmark (complete rework, own design step)

The user wants a full rework, GPU included. Before building, the feature developer writes a short benchmark design (measures, method, score, report) for the user to approve. Fixed points so far:

When it runs (user decision 2026-11-15):
- **Baseline**: once at the very beginning, on the first run right after the snapshot gate and before AVDTune changes anything. It is the reference of the master.
- **Before every seal**: required; the seal checklist stays red until a benchmark of the current image version exists and is not older than the last change.
- Any time by hand in between (e.g. after optimization).
- Every result goes into the protocol, the change log of the version and the SharePoint list, with the comparison to the baseline and to the benchmark of the previous sealed version (better/worse per area, threshold 10%).

### 6a. Measures and scores (draft 2026-11-15, for the user's approval)

Three separate scores (user decision: GPU and FSLogix separated), never mixed, because they measure different things (the image and VM, the storage, the graphics card) and a VM without GPU or without FSLogix must still get a comparable host score:

| Score | What it says | When |
|---|---|---|
| **AVDTune Host-Score** (the overall score) | how fast this image on this VM size is for a user session | always |
| **FSLogix-Score** | how fast profiles load and work on the share of the environment | when FSLogix is used |
| **GPU-Score** | graphics and video power of the GPU | only on VMs with a GPU (otherwise "nicht vorhanden", not 0) |

Scoring method (like SPEC/Geekbench): every measure is turned into an index against fixed reference values (measured once on a reference configuration and frozen per benchmark version; reference = 1000). Times and latencies count inversely. A category is the geometric mean of its measures, a score is the weighted geometric mean of its categories. So no single extreme value dominates, a 10% faster disk is worth the same everywhere, and results of the same benchmark version are comparable across masters and VM sizes. A new benchmark version (new reference) is never compared with an old one without saying so.

Repeatability: warm-up run discarded, then 3 runs, median; the spread (coefficient of variation) is shown, above 10% the measure is marked unstable. Runs only when no other user session is active and AVDTune is not doing anything else; Windows Update, Defender scan and indexing are paused for the run and restored. Each result stores benchmark version, VM size, region, CPU model (from the processor, Azure can give different CPUs to the same size), vCPU/RAM, disk type and size, Windows build, Office build, image version, time. Modes: full (about 15 min) and quick (about 3 min, fewer repetitions, marked as quick and not used for the seal).

**Host-Score: categories, measures, weights**

| Category (weight) | Measures |
|---|---|
| CPU (25%) | single thread (compiled .NET workload: compression, hashing, JSON parse, regex), all cores (same workload in parallel), scaling factor all cores / single, sustained load 60 s (drop of performance = throttling or noisy neighbour), AES and SHA throughput (TLS, SMB encryption) |
| Memory (10%) | bandwidth (copy), latency (random pointer chase), allocation speed of .NET |
| OS disk (20%) | 4K random read and write at queue depth 1 (latency p50/p99: what a user feels), 4K random 70/30 at queue depth 32 (IOPS), 1 MB sequential throughput, small-file test (create/read/delete 5000 files: includes Defender and filter drivers) |
| Applications (30%) | cold and warm start of Word, Excel, Outlook (without profile, offline), Edge, Teams, File Explorer until the window is ready; Edge browser benchmark (Speedometer 3, open source, run offline from a local copy); PowerShell/.NET start. This is the part that shows the effect of optimizations and of software added to the image |
| Remote display (10%) | software H.264 encode of a fixed desktop and video clip (frames per second: the CPU cost of the RDP stream per session on VMs without GPU), software rendering (WARP) of a fixed 2D/3D scene |
| Network (5%) | DNS resolution time, TCP connect latency (p50/p95) to the AVD gateway and broker endpoints and to the Azure region, jitter, download throughput of a fixed Microsoft file with known size (several streams) |

User decisions 2026-11-15: weights approved; later the same day the logon test with a temporary local test user was dropped as too complicated, so there is no Session category and its 15% went to CPU (+5), OS disk (+5) and Applications (+5); logon times only come as information from real logons on session hosts; reference = a typical current AVD host (a common 8-vCPU size with Premium SSD and the plain Marketplace image Windows 11 multi-session + M365 without optimization; FSLogix reference: a Premium share with private endpoint; the exact size is chosen and named when the reference is measured).

**User activity simulation ("Kapazitaet", user request 2026-11-15)**: an additional, optional run (about 30 min, not part of the three scores, not required for the seal) that simulates knowledge workers:
- Workload of one simulated user, scripted with UI Automation in the session of the administrator who runs AVDTune (no extra user): write and format text in Word, recalculate and chart in Excel, open, search and reply to mails in Outlook (offline, local test mailbox file), browse local test pages and a video in Edge, open, scroll and zoom a PDF, copy and zip files, short idle times like a real user. Every action has a measured response time (from input to the window being ready).
- Load: the same workload as background workers (CPU, memory, disk and file patterns of the actions, without UI) for 1, 2, 4, 8 ... simulated users, raised step by step while the interactive user keeps measuring.
- Result: response time per action and in total per load level (median and p95), and the **number of users until the response time is 50% above the 1-user value** (similar to the VSImax idea of Login VSI, own method, named as an estimate). Plus CPU, memory, disk queue per level. This answers "how many users fit on this VM size with this image" and shows when an image change costs capacity.
- Stored and reported like the benchmark (change log, SharePoint), compared with the last run of the same VM size.

Shown as information without score: logon times of real user logons on session hosts (from the status script, section 5a), number of Run keys, Active Setup entries, scheduled tasks at logon, services set to automatic (they explain a worse Applications category), and an estimate "users per host" from CPU and memory per session measured during the application test.

**FSLogix-Score** (share of the environment, the test user of section 5a)

| Category (weight) | Measures |
|---|---|
| Latency (35%) | 4K random read and write at queue depth 1 on the share (p50/p99), SMB open/close per second, round-trip time to the storage endpoint (private endpoint) |
| Throughput (20%) | 4K random 70/30 at queue depth 32 (IOPS), 1 MB sequential read and write |
| Metadata (15%) | create, stat, delete of 2000 small files |
| Profile container (30%) | create a test VHDX, attach, write 200 MB of mixed files, detach, re-attach (time of each step = what a logon and logoff costs), also with 5 parallel containers to show how the share behaves when several users log on at once |

Shown as information: storage account kind, tier, provisioned size, IOPS and throughput limits (ARM), private endpoint yes/no, SMB channel encryption, so a bad score can be traced to the storage configuration.

**GPU-Score** (NV/NC and other GPU sizes)

| Category (weight) | Measures |
|---|---|
| 3D rendering (35%) | fixed Direct3D 11 scene off screen at 1920x1080 and 3840x2160 (frames per second), DirectX 12 if supported |
| Video encode (30%) | hardware H.264, HEVC and AV1 (if supported) encode of a fixed clip (frames per second: the GPU part of the RDP stream and of video conferencing) |
| Video decode (15%) | hardware decode of fixed H.264/HEVC/AV1 videos |
| Compute (20%) | DirectCompute kernel (GFLOPS), GPU memory bandwidth |

Shown as information: adapter, driver version, VRAM, vGPU profile/partition (`nvidia-smi` or AMD tools when present), whether the RDS policies use the hardware adapter, AVC444 and hardware encoding. A GPU VM whose RDS policies do not use the GPU gets a red hint: the GPU is measured but the users do not get it.

Report: the three scores large, each category with its index and the change to the baseline and to the last sealed version (green/red above 10%), every measure in a detail table, the information blocks, the run details. HTML, PDF, change log, SharePoint list (one row per run with the scores and categories as columns, so they can be charted there).

Tools: our own compiled .NET measure program (source in the repo, built by the release workflow, hash in the manifest), diskspd (Microsoft, MIT, downloaded and checked), Speedometer 3 (open source, local copy with licence), Media Foundation and Direct3D of Windows. No third-party binaries without a licence that allows redistribution.

Findings in the current script:
- The internet test downloads the start page of windows.net (a few KB) and computes as if it were 1 GB; on error it reports a fixed 150 Mbps. The value is not real.
- The SMB throughput writes 1 GB and computes with 5000 MB: 5 times too high.
- The mini-file test says 4096 files, writes 1024.
- diskspd: read only (`-w0`), 150 MB file, no latency (`-L`); results not comparable with other tools.
- CPU and "workload" measure the PowerShell interpreter on one core, not the VM; no multi-core value.
- The HTML report is cut off: the here-string is never closed and never written, so the script does not finish.
- The FSLogix share path is hard coded and names a customer storage account in a public repository; `speedtest.exe` (Ookla) is bundled although its licence does not allow redistribution.

Other points:
- The share path comes from the environment (FSLogix `VHDLocations`). No Ookla binary.
- AVD-Benchmark repo: becomes the stand-alone version of the same engine (one script for session hosts without AVDTune, e.g. to compare a running host pool with the master), same scores and report.

### 6b. Benchmark only, without setup and sign-in (user request 2026-11-15)

AVDTune can be used purely as a benchmark: for existing systems, and for systems that are to be replaced, as the baseline to compare the new AVD environment with.
- Start: on the first start the choice "Nur Benchmark" next to "Golden Master einrichten", or `Start-AVDTune.ps1 -Benchmark`. No environment wizard, no M365/Azure or domain sign-in, no snapshot gate (the benchmark changes nothing permanent), no Golden Master pages; only the Benchmark page and its results.
- Parameters entered by hand: a name for the system (e.g. "Altsystem RDS 2019"), optional notes; for the FSLogix-Score the share: UNC path and the access, either the storage account name and its key (Azure Files) or the current user / a user name and password (any SMB share). Without a share the FSLogix-Score is skipped.
- The key and password: only in memory for this run, used for one SMB connection to a test folder, the connection is removed at the end, never written to disk, settings, protocol or report; the field says that the account key gives full access to the storage account and that a test folder is used and removed.
- Works on Windows 11 multi-session, Windows 10/11 and Windows Server with Remote Desktop Services (2016 and newer) and other VDI hosts: categories that cannot run are skipped and named (e.g. no Office installed: application tests for Office skipped; no GPU: GPU-Score "nicht vorhanden"). Scores are only compared when the same categories ran; otherwise the report shows the category values side by side.
- No test user and no logon test (dropped by the user decision of 2026-11-15); the user activity simulation is optional as everywhere.
- Results: local report (HTML, PDF) and a result file (JSON, no secrets) for export. In a Golden Master environment the result file can be imported as "Vergleichssystem", then it appears in the comparison of every benchmark, in the change log and in the SharePoint list of the environment.
- Same engine, same version and reference as in the full tool and the AVD-Benchmark stand-alone script, so results are comparable.

## 7a. The real process and the "Abschliessen" step (user's process document, decision 2026-11-15)

The user's current process for every change: (1) snapshot of the master's OS disk, (2) start the master, connect through Azure Bastion (local admin today, a domain account later), make the changes, document every change in the change log (also changes outside the image, e.g. in the Defender portal), restart, log off, (3) the imaging tool (Hydra for Azure Virtual Desktop) shuts the master down, makes a temporary copy, generalizes the copy, writes the new image version to the Azure Compute Gallery and cleans up; the new version is used at the next rollout (separate documentation). Snapshots are deleted after a successful change as a regular service task. Windows updates are installed by PowerShell (the GUI is blocked) and the console output is pasted into the change log as a screenshot.

What follows for AVDTune:
- **The master is never sysprepped.** The last button is "Abschliessen": (a) healthcheck (1c) must be green or acknowledged, benchmark of the version done; (b) cleanup that keeps the master usable (temp, logs, caches, Defender cache maintenance task, DISM component cleanup only with confirmation because it removes rollback of updates, old leftovers); (c) AVDTune's tokens, sign-in caches, domain credentials and local step images removed and checked; (d) pending restart: restart first, AVDTune resumes the finish after it; (e) change log of the version closed and sent to SharePoint (queue if offline); (f) log off (default) or shut down, as chosen. Then a note: "Jetzt das Image im Imaging-Tool erstellen" with the tool's link from the environment settings (never in the repo).
- Sysprep on the master stays as an expert option (own confirmation, all checks of the old seal section: AppX per user, BitLocker, not as SYSTEM), for environments without an imaging tool.
- After the imaging: AVDTune reads the image definition in the Azure Compute Gallery (ARM, read only) at the next start, finds the new image version made after the last "Abschliessen" and records it in the change log of that version (gallery version, date, replicated regions). Starting the imaging tool from AVDTune (e.g. Hydra's API) is a possible later step, not planned now.
- **Snapshot housekeeping**: a list of the master's OS disk snapshots (AVDTune's and others, by tag and name pattern) with age and the image version they belong to; after a gallery version newer than the snapshot is found, old snapshots can be deleted from the list (confirmation, the newest N kept, setting), entry in the change log.
- **Change log entries for changes outside the image** (e.g. Defender portal, imaging tool, Group Policy, Azure settings): an entry type "Ausserhalb des Images" with system, what, why, who; same version and SharePoint list.
- **Windows updates** through AVDTune replace the manual PowerShell run: the result per update (KB, title, result code) goes into the change log automatically; no console screenshots needed.
- Connection: AVDTune runs in the admin's Bastion session; nothing in AVDTune depends on how the admin connected.

## 7. State, protocol, change log

- On the master: `C:\ProgramData\AVDTune\` (ACL Administrators/SYSTEM): `state.json` (current), `runs\` (one record per run, append only), `changelog.json`, `benchmark\`, `config\` (Office XML, redirections.xml, watermark), `logs\`. No secrets, no tokens.
- Image version `YYYY.MM.NNN` (as in the hand-written log), raised by "start new version"; capture records the gallery version as free text.
- Protocol per session as in PackTune (DE/EN, ready for a ticket), saved locally and to the library.
- Optional SharePoint list (user decision: own site per customer/environment): the site URL is a setting of the environment; the setup assistant creates the site if wanted and a list "AVDTune Change Log" with the columns Version, Date, Category, Component, Change type, Text, User, Snapshot ID, Run ID; the app registration gets `Sites.Selected` on that site (one-time grant as in PackTune). Every change log entry is written to the list too; when SharePoint is not reachable entries wait in a local queue and are sent later. The list is the shared view; the local `changelog.json` stays the source.

## 8. Library (SharePoint) on the master

- The master reads the PackTune package store with the same sign-in (Sites.Selected). Trust anchor stays Intune: the manifest hash in the app notes; AVDTune reads it with read-only Intune access. Packages that are only in the library and not in Intune need their own anchor: open question.
- Before seal every token, refresh token and cache of AVDTune and the sign-in is removed and checked; a captured image must not carry an admin session.

## 9a. Self-update and integrity against GitHub (user decision 2026-11-15)

- Releases on GitHub (public repo): a ZIP of the tool plus `manifest.json` with version, release date, and SHA256 and size of every file. Built by a GitHub Actions workflow from the tagged commit, never by hand.
- Integrity at every start: AVDTune compares its installed files with the manifest of its own version (fetched from the GitHub release over HTTPS, cached copy when offline). Missing, changed or extra files: red on the Overview with the file list, AVDTune runs read only until repaired; "Reparieren" downloads the release again and replaces the files after the same check.
- Update check at every start and on demand: newest release (stable; early access only when switched on), release notes shown. Update only on the user's click, never during a run or in maintenance mode: download ZIP and manifest, check SHA256 of the ZIP and of every file, install side by side into `C:\Program Files\AVDTune\<version>`, switch, keep the previous version for "Zurueck zur vorigen Version". Entry in the protocol and the change log (tool version is part of every change log entry).
- Limit, stated in the UI and README: the hash manifest proves that the files are the ones published on GitHub and unchanged on the master; it does not protect against a compromised GitHub account or repository. Code signing (Authenticode, e.g. Azure Trusted Signing) can be added later without changing the flow: then the publisher is pinned as well.
- Repository hygiene for the public repo: `Tests\Check-PublicContent.ps1` fails on tenant IDs, GUIDs in non-test files, storage account or host names, IP addresses outside documentation ranges, and on names from a local deny list that lives outside the repo (`%LOCALAPPDATA%\AVDTune\deny-list.txt`, never committed); run before every commit and in CI.

## 9. Security

Elevated tool on a machine that becomes the image of all users: runs from a protected copy (`C:\Program Files\AVDTune`, admin-only ACL) with a hash check of its files (section 9a); downloads only from Microsoft/known hosts over HTTPS with Authenticode or hash check; no command lines built from data; the Sicherheitspruefer reviews update block, seal, sign-in on the master and the downloader.

## 10. Checks

`Tests\Check-AVDTune.ps1` (engine against a fake machine: registry, services, tasks, WUA, ODT; idempotency, maintenance mode restored on error, change log), `Check-Benchmark.ps1` (parsers of diskspd output, score, comparison), GUI smoke with fakes. Real runs only in a throwaway Azure VM (Windows 11 multi-session), never on a developer machine.

## 11. Phases

| Phase | Content |
|---|---|
| 1 | Shell in PackTune look, elevation, engine, state, protocol and change log, Overview (incl. source image); first-run question of the identity model (stored, used by the start sequence); start sequence: M365/Azure sign-in, DC connection and discovery when a DC is used, snapshot gate with name confirmation |
| 2 | Updates page (Windows, Office, Edge/Teams/OneDrive/FSLogix/Defender, software) and update block with maintenance mode |
| 3 | Environment wizard (identity model), FSLogix setup and function test, automatic storage setup (Premium account, share, private endpoint, identity, permissions), storage check; App Masking with groups in AD (Entra only: everyone or nobody), Public Desktop list, hiding wizard and comfort shortcuts (5c); SharePoint change log list; environment document |
| 4 | Software from the library and catalog, custom software wizard with recording, list and documentation in SharePoint, web apps (PWA) with icon (spike first), printer drivers from a print server (also in maintenance), shortcuts, fonts, own steps |
| 5 | Benchmark: design for approval, then new engine incl. GPU, comparison per version, AVD-Benchmark repo stand-alone |
| 6 | Setup: Office, language, VDI components, selectable optimization list from WDOT and research with Defender VDI preset (5d), user experience, watermark |
| 7 | Cleanup & seal (last button, checklist), export, docs and demo |

Security reviews: phase 1 (sign-in, domain credentials, LDAP, snapshot rights), 2 (update block), 3 (group creation in AD, share permissions), 7 (seal, token removal).
