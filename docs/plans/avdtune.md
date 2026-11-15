# Plan: AVDTune, Golden Master management for Azure Virtual Desktop

Status: PLAN, no product code yet. Lead: AVDTune CTO. Private repo `dominguez-posh/AVDTune`. Replaces the "Golden Master mode inside PackTune" idea of PackTune's `docs/plans/golden-master.md`: same engine ideas (step contract, Test/Apply/Undo, state file, dry run), but as its own tool in PackTune's look, for AVD only.

Decisions of the user (2026-11-15): own repository (private); shared code copied from PackTune by a sync script; first phase is Updates plus the update block for users; watermark stays bound to a machine name pattern; the benchmark engine lives in AVDTune and the AVD-Benchmark repo stays as its stand-alone version.

Sources: a real change log of a Golden Master build (Windows 11 multi-session 25H2 + M365, mid 2026, customer parts left out), the benchmark script `dominguez-posh/AVD-Benchmark`, Microsoft Learn (links per step in the step catalog).

## 1. Goal

AVDTune runs locally and elevated on the Golden Master VM and takes over its whole life: first setup (language, Office, optimizations, VDI components, software), regular maintenance (one update page for Windows, Office and all software), measurement (benchmark per image version), cleanup and seal for capture. Like PackTune it keeps a protocol of everything an administrator did, ready for a ticket, and a change log per image version (the document that is written by hand today).

Not in scope: customer specific software and shortcuts (they come as packages from the library), host pool management in Azure, Citrix/Horizon.

## 1a. Start: sign-in, domain, snapshot gate (added 2026-11-15)

Nothing changes the master before these three steps are done; the Overview shows them as a short start sequence.

1. **Microsoft 365 / Azure sign-in.** One sign-in with three token audiences: Microsoft Graph (SharePoint site of the environment, read of Intune app notes for the package trust anchor), Azure Resource Manager (snapshot of the OS disk, VM size and region for the benchmark), and the PackTune package store (Sites.Selected). The app registration needs `user_impersonation` on Azure Service Management in addition to PackTune's permissions; the setup assistant adds it. Tokens live in memory only and are removed and checked before seal.
2. **Domain** (only for the identity models with a domain controller, section 1b; with Entra only this step is skipped and groups come from Entra ID through Graph). The master is not domain joined (it must not be, because of sysprep), so the user enters the IP (or name) of a domain controller and a domain account with the rights to create groups in an OU. AVDTune reads everything else itself from the DC: RootDSE (domain DNS name, NetBIOS name, naming contexts, functional level), the OU tree, existing groups and their SIDs, the site, optionally the DNS servers. Connection: LDAPS 636 first; fallback LDAP 389 only with Negotiate signing and sealing; never a simple bind in clear text. The certificate of the DC is shown on first contact (thumbprint) and pinned per environment. The password stays in a SecureString in memory, never on disk, never in the protocol.
3. **Snapshot gate.** AVDTune finds its own VM through the Azure Instance Metadata Service (subscription, resource group, VM, OS disk) and offers "Create snapshot now" (incremental snapshot of the OS disk, name `<vm>-avdtune-<image version>-<yyyyMMdd-HHmm>`, tags with image version and user). It then checks that a snapshot of the OS disk from today exists, and the user confirms by typing their full name: "Ich bestaetige, dass vor diesem Lauf ein Snapshot des Golden Masters erstellt wurde und ein Rollback moeglich ist." Name, time, snapshot resource ID and whether AVDTune made it go into the protocol and the change log. Without the confirmation every page is read only. Rollback hint on the Overview: how to create a disk from the snapshot and swap the OS disk.

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
- **Entra ID only**: no DC step; groups for App Masking and the FSLogix include/exclude lists are Entra groups created through Graph (`Group.ReadWrite.All` only during that action), referenced by their SID (`S-1-12-1-...`); Azure Files with Microsoft Entra Kerberos; session hosts need `CloudKerberosTicketRetrievalEnabled=1` and `LoadCredKeyFromProfile=1` (set in the image); the Entra app of the storage account needs admin consent and must be excluded from Conditional Access policies that require MFA (AVDTune checks both). Support for cloud-only identities in Azure Files and for Entra group SIDs in FSLogix App Masking is verified against Microsoft Learn in phase 0 of this part and shown on the page with its status; if a combination is not supported, the wizard says so instead of building it.
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
- Shared with PackTune: Theme, sign-in (`Modules/Keevault.psm1`), package store (`PackTune-Store.ps1`), protocol (`PackTune-Protocol.ps1`, new category set), winget/Chocolatey helpers. They live in `Shared/` as copies: `Tools\Sync-FromPackTune.ps1` copies them from a PackTune clone and writes `Shared/SOURCE.json` (PackTune commit, SHA256 per file); `Tests\Check-Shared.ps1` fails when a file in `Shared/` differs from its recorded hash. Changes to shared code are made in PackTune first, then synced.

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
| Optimization | VDOT data re-implemented with attribution (AppX, services, tasks, autologgers), visual effects and transparency off for all users, power plan, widgets/news/consumer features/Copilot off, Edge/Chrome (no hardware acceleration, sleeping tabs, no background run), Storage Sense off, telemetry Required, hibernation off, scheduled defrag off, Xbox/gaming removed |
| FSLogix | setup, settings, `redirections.xml`, function test (section 5a) |
| App Masking | FSLogix hiding rules for icons and apps, groups in the domain (section 5b) |
| VDI components | Defender onboarding for non-persistent VDI (package from the library), new Teams for VDI (`teamsbootstrapper -p`, `IsWVDEnvironment`, SlimCore plugin / WebRTC redirector per Microsoft Learn), MMR, RDP Shortpath, time zone redirection, OneDrive per machine |
| User experience | wallpaper (replace `img0.jpg` with ownership handling), watermark (section 5), Start/taskbar layout and default apps for new profiles, public desktop shortcuts and web apps (PWA) with FSLogix App Masking rules per group |
| Update block for users | everything that offers or runs updates is hidden and off for users (section 4) |
| Benchmark | section 6 |
| Cleanup & seal | the last button of a version: a checklist that must be green (no pending reboot, update block on, FSLogix test passed, no AVD agent, no join, no tokens), then DISM component cleanup, temp/logs/caches, default profile check, AppX-per-user check (sysprep blocker), BitLocker off, tokens and sign-in caches of AVDTune removed, snapshot reminder, sysprep `/generalize /oobe /shutdown /mode:vm` as the interactive admin (never SYSTEM), typed confirmation |
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
| VDOT | Optimization (data re-implemented) |
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
- Changes are applied with `frxcontext`/the FSLogix Apps service reload and verified (rule compiled, assignment readable). Each change goes into the change log (rule, group, OU, SID).
- Migration: the rules made today with the FSLogix Rule Editor are read and shown; unknown parts of a rule are kept as they are.

## 6. Benchmark (complete rework, own design step)

The user wants a full rework, GPU included. Before building, the feature developer writes a short benchmark design (measures, method, score, report) for the user to approve. Fixed points so far:

When it runs (user decision 2026-11-15):
- **Baseline**: once at the very beginning, on the first run right after the snapshot gate and before AVDTune changes anything. It is the reference of the master.
- **Before every seal**: required; the seal checklist stays red until a benchmark of the current image version exists and is not older than the last change.
- Any time by hand in between (e.g. after optimization).
- Every result goes into the protocol, the change log of the version and the SharePoint list, with the comparison to the baseline and to the benchmark of the previous sealed version (better/worse per area, threshold 10%).

GPU (for NV/NC VMs, skipped with a note on VMs without GPU):
- Detect: adapter, driver version, VRAM, vGPU partition (`Get-CimInstance Win32_VideoController`, `nvidia-smi`/AMD tools when present), whether the RDS policies use the hardware adapter, H.264/AVC444 and hardware encoding.
- Render: a fixed off-screen Direct3D scene (WPF/D3D11 through a small included .NET program) with frames per second at a fixed resolution, and the same scene through the software renderer as a reference.
- Encode/decode: Media Foundation hardware H.264/HEVC encode of a fixed clip (frames per second), hardware decode of a fixed video.
- Compute: optional OpenCL/DirectCompute kernel time.

Findings in the current script:

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
- Optional SharePoint list (user decision: own site per customer/environment): the site URL is a setting of the environment; the setup assistant creates the site if wanted and a list "AVDTune Change Log" with the columns Version, Date, Category, Component, Change type, Text, User, Snapshot ID, Run ID; the app registration gets `Sites.Selected` on that site (one-time grant as in PackTune). Every change log entry is written to the list too; when SharePoint is not reachable entries wait in a local queue and are sent later. The list is the shared view; the local `changelog.json` stays the source.

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
| 1 | Shell in PackTune look, elevation, engine, state, protocol and change log, Overview (incl. source image); first-run question of the identity model (stored, used by the start sequence); start sequence: M365/Azure sign-in, DC connection and discovery when a DC is used, snapshot gate with name confirmation |
| 2 | Updates page (Windows, Office, Edge/Teams/OneDrive/FSLogix/Defender, software) and update block with maintenance mode |
| 3 | Environment wizard (identity model), FSLogix setup and function test, automatic storage setup (Premium account, share, private endpoint, identity, permissions), storage check; App Masking with groups in AD or Entra; SharePoint change log list; environment document |
| 4 | Software from the library and catalog, custom software wizard with recording, list and documentation in SharePoint, web apps (PWA) with icon (spike first), printer drivers from a print server (also in maintenance), shortcuts, fonts, own steps |
| 5 | Benchmark: design for approval, then new engine incl. GPU, comparison per version, AVD-Benchmark repo stand-alone |
| 6 | Setup: Office, language, VDI components, optimizations, user experience, watermark |
| 7 | Cleanup & seal (last button, checklist), export, docs and demo |

Security reviews: phase 1 (sign-in, domain credentials, LDAP, snapshot rights), 2 (update block), 3 (group creation in AD, share permissions), 7 (seal, token removal).
