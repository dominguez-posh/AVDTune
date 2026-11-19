# Test plan for the throwaway VM (#17)

Everything in AVDTune is checked against fakes first. This plan is the real run on a throwaway VM, in the order of a real session. Never run it on a real Golden Master or a developer machine. Everything merged after v0.1.0-ea.4 has never been seen on a real machine.

How to use it:
- Tick a point when it behaves as expected. If not, do not try to fix it: note the point number and what "Report" asks for, and go on with the next point unless it says "stop".
- Results go into issue #17 (one comment per section is enough). The repo is public: no tenant or customer names, no IDs, no host names, no user names in the comment; replace them (`<dc>`, `<share>`, `<site>`).
- Times are estimates for one person who knows the tool. Whole plan: about 11 to 13 hours, best split over two days (day 1: A to F, day 2: G to S). Sections can be skipped when their prerequisite is missing; note that in #17.

## Prerequisites

Have these ready before the first start. What is missing costs the section named behind it.

| # | What | Needed for |
|---|---|---|
| P1 | Azure test subscription and resource group. VM: Windows 11 Enterprise multi-session + Microsoft 365 Apps from the Marketplace (current `win11-...-avd-m365` SKU), Generation 2, Trusted Launch, a v6 or v7 size with NVMe if the region has one. Access through Azure Bastion. | all |
| P2 | The VM is **not** joined at the start (like a real master). One snapshot of the OS disk right after the deployment, taken in the portal, to reset the VM. | all, reset for A9, S7 |
| P3 | A local administrator account on the VM (the one of the deployment). All work runs as this account. **Not a Domain Admin**: the benchmark starts programs as a throwaway local user and denies domain groups; with a Domain Admin the app starts and their traces are not what a customer sees (#84, #92). | all, N |
| P4 | An Entra account for the sign-in in AVDTune: may create an app registration and grant admin consent (first sign-in), and has on the resource group a role with snapshot read/write and disk read (e.g. Disk Snapshot Contributor plus Reader). For section D also Contributor and User Access Administrator on a second, empty resource group. | B, C, D |
| P5 | A reachable domain controller with LDAPS on 636 (a self-signed certificate is fine) and a domain account (UPN and password, no Domain Admin) that may read the directory and create groups in one test OU. A few test groups in that OU, among them one with a blank and brackets in the name, one ending in `$`, one with an umlaut, one longer than 64 characters. | B, G, H, J |
| P6 | An Azure Files share for FSLogix (Premium, identity based access) or the willingness to let section D create one; the role Storage File Data Privileged Contributor for the P4 account; a domain test user with a share level role. | D, G |
| P7 | A Windows print server in the domain with at least two shared printers (one with a WHQL signed driver, if possible one with a vendor signed driver), WinRM enabled, reachable by its full name. An account that is administrator on that server (UPN). | J |
| P8 | A SharePoint site for the test and the site grant `Sites.Selected` with role **write** for the AVDTune app registration on that site (#96; without it section P is read only). In the site a document library with one small MSI or setup and one script as package store. | I, K, P |
| P9 | The Microsoft "Languages and Optional Features" ISO that matches the Windows build of the VM, downloaded to the VM (not from a third party). | L |
| P10 | A public test web site with a web app manifest for the web app points, and the Microsoft Defender for Endpoint VDI onboarding package if you have one (optional). | I, M |
| P11 | The early access ZIP of the version under test, from the GitHub release page (pre-release `vX.Y.Z-ea.N`). | A |

Not on the VM: `AVDTUNE_FAKE`, `AVDTUNE_ROOT`, a git checkout, the `Tests` folder.

## A. Install from the early access ZIP (30 min)

- [ ] **A1** Download `AVDTune-<version>.zip` from the release page on the VM, Properties > Unblock, unpack to a folder of the admin (e.g. Downloads). Open Windows PowerShell 5.1 **as administrator** and run `powershell -NoProfile -ExecutionPolicy Bypass -File "<folder>\Start-AVDTune.ps1"`.
  Expected: the window opens; the integrity card says the copy is not protected and offers "Install"; everything else is read only.
  Report: the text of the card, and the full error if the window does not open (also the last lines of the console).
- [ ] **A2** Click "Install", start again through `C:\Program Files\AVDTune\Start-AVDTune.ps1` (the launcher).
  Expected: `C:\Program Files\AVDTune\<version>` and `current.json` exist; owner Administrators, no write for Users (`icacls`); the card is green and names version and commit.
  Report: `icacls "C:\Program Files\AVDTune"` output, card text.
- [ ] **A3** Start time: stop the time from Enter to the window, three starts.
  Expected: under about 20 seconds; no module from `Documents\WindowsPowerShell\Modules` is loaded (#73).
  Report: the three times; any text "module path" at the start.
- [ ] **A4** In the card switch on early access and click "Check for updates".
  Expected: the newest release and its notes; nothing is installed without a click. Behind a proxy: note whether the check works at all (#106).
  Report: error text; whether the VM uses a proxy and whether it asks for authentication.
- [ ] **A5** Change one file below `C:\Program Files\AVDTune\<version>` (add a blank line to a `.ps1`), start again.
  Expected: card red with the file name, AVDTune read only, "Repair" downloads the release, after the next start green.
  Report: the file list of the card, the error of "Repair".
- [ ] **A6** After the first-run questions (section B): the question for the desktop shortcut.
  Expected: `AVDTune.lnk` only on the desktop of the admin, never on the Public Desktop; it starts the launcher with `-NoProfile`.
  Report: the target line of the shortcut (Properties).
- [ ] **A7** Folders: `C:\ProgramData\AVDTune` exists, owner Administrators, rights only for Administrators and SYSTEM; `temp\host` below it exists while AVDTune runs.
  Report: `icacls C:\ProgramData\AVDTune` output.
- [ ] **A8** Elevated console in `C:\Program Files\AVDTune\<version>\Bench\bin`: `AVDTune.Bench.exe selftest-launcher` (#14 N1).
  Expected: only `PASS` lines, last line `selftest-launcher: ALL n CHECKS PASSED`, exit code 0 (`echo $LASTEXITCODE`).
  Report: the whole output and the exit code. Exit 3 means it did not run elevated; repeat elevated.
- [ ] **A9** Optional, after a VM reset: as a normal user create `C:\ProgramData\AVDTune` before the first start.
  Expected: AVDTune sets it aside as `AVDTune.untrusted-...`, says so, and starts fresh.
  Report: the message; content of `C:\ProgramData`.

## B. Start, sign-in, domain (45 min)

- [ ] **B1** First start: the sign-in opens by itself. Sign in with the P4 account.
  Expected: Microsoft sign-in window, nothing filled in by a tool. The app registration `AVDTune` is created (or found). Afterwards no `PackTuneSignIn-*` folder in `%TEMP%` of the admin; `C:\ProgramData\AVDTune\WebView2` holds only the three DLLs and `webview2-sdk.json`.
  Report: the AADSTS code and text when the sign-in fails; which folder was left where.
- [ ] **B2** Tokens: the start page lists Graph, Sites, Arm and Storage as present.
  Expected: all four. With a registration made before the Storage scope: sign-in works with the warning "No Storage token"; "Set up again" adds it (F8).
  Report: which token is missing and the text next to it; for an old registration the AADSTS code (65001 is expected).
- [ ] **B3** Domain step on the non-joined VM.
  Expected: "skipped" with the reason; the DC field is empty or suggested.
  Report: the text of the step.
- [ ] **B4** Enter the DC (full name), connect with the P5 account.
  Expected: with a self-signed certificate AVDTune shows subject and thumbprint and asks; compare the thumbprint on the DC, confirm; domain, OUs, groups and site are read. The password is asked each time and stored nowhere.
  Report: the warning text; which of domain, OU, groups, site is missing.
- [ ] **B5** Enter the DC as IP address with 636 blocked (or a DC without LDAPS), if you can.
  Expected: a warning that names NTLM, relay and offline cracking; nothing is sent before the confirmation.
  Report: the warning text; whether anything was read before the confirmation.
- [ ] **B6** Optional, at the end of the day: join the VM to the domain, restart, start AVDTune.
  Expected: the DC is suggested from the machine (format `\\host` is turned into the name), the join state appears after a moment without freezing the window.
  Report: the suggested value exactly as shown.
- [ ] **B7** First-run questions.
  Expected: join type, network (VNet, subnet), storage account, endpoint and DNS zone are suggested from the VM and Azure with their source; nothing is saved before "Confirm the answers". `config\environment.json` then has the answers, no secret.
  Report: which suggestion is wrong or empty and what the right value kind would be (no real names).
- [ ] **B8** Switch the language EN/DE (#70).
  Expected: every page changes; no key names (`stage.xyz`) and no mixed pages.
  Report: page and the text that stayed in the other language or showed a key. Proofread the German texts of the start sequence and note wrong wording.

## C. Snapshot gate and image version (30 min)

- [ ] **C1** "Create snapshot now".
  Expected: a snapshot `<OS disk>-DD.MM.YYYY-1` in the resource group with the tags; the SKU matches existing incremental snapshots of the disk (#60).
  Report: Azure's answer (status and message without IDs).
- [ ] **C2** Confirm with first and last name.
  Expected: the first image version starts (with a question), the pages unlock; protocol and change log show typed name, Microsoft account and Windows account.
  Report: error text, e.g. a parameter binding error.
- [ ] **C3** Alternative path after a reset: do not create one, confirm the snapshot from P2 that AVDTune finds.
  Expected: accepted when it is newer than the last change.
  Report: why it was refused.
- [ ] **C4** After any change of section F or later: try to confirm with the snapshot of C1.
  Expected: refused (older than the last change). A new snapshot is accepted.
  Report: the two times AVDTune shows (last change, snapshot).
- [ ] **C5** While a long run of another page is active (e.g. Office install, K): look at the Overview.
  Expected: "Start new version" and the snapshot confirmation are locked with the reason; closing the window asks or waits (#49, #81).
  Report: which button was still active, which run was going.

## D. Environment wizard (optional, 60 min, needs P4 on an empty resource group)

- [ ] **D1** Fill in the fields, "Make the plan".
  Expected: rows account, SMB, share, zone, link, endpoint, zone group, identity, two roles; nothing exists in the portal yet; missing rights are named.
  Report: the row that differs.
- [ ] **D2** "Create the resources".
  Expected: account (Premium FileStorage, TLS 1.2, tag `CreatedWith=AVDTune`), SMB 3.1.1 settings, share with quota, zone, link, endpoint with A record, identity, role assignments; change log entries (category Azure); a second plan shows only "Exists"; `LastChange` untouched. The window stays usable while Azure works (#44).
  Report: the step that failed with Azure's status and message. For "polling link that is not followed": the link with host and IDs replaced, so the unknown character is visible.
- [ ] **D3** Other file service settings (e.g. soft delete of shares) before and after D2.
  Expected: unchanged.
  Report: which setting changed.
- [ ] **D4** Error cases: a name that is taken, a subnet in another region.
  Expected: one readable message each, nothing half written without a journal entry.
  Report: message text.
- [ ] **D5** "Show what can be taken back", "Take it back".
  Expected: endpoint, link, roles, zone group and (empty share) share and account are gone; a share with a folder stays, with the reason.
  Report: what stayed and the reason shown.
- [ ] **D6** End AVDTune in Task Manager during D2, start again.
  Expected: the run is reported as interrupted and can be repaired or taken back (#45).
  Report: what the page shows.

## E. Readiness and Overview (20 min)

- [ ] **E1** Overview.
  Expected: source image, VM size, region, Windows build, Office build are right.
  Report: field, shown value, real value (kind only).
- [ ] **E2** Readiness run.
  Expected: NVMe, MANA, temp disk, Trusted Launch, Generation 2 match the VM; the AVD agent is not red on a master without agent; "not checkable" only with a reason.
  Report: row ID (`hy.*`), colour, text, and what is true on the VM.
- [ ] **E3** One "Fix" on a red or yellow row, then run again.
  Expected: the row turns green; change log entry.
  Report: row ID and error.
- [ ] **E4** Open every page once and watch the task bar at the bottom.
  Expected: every page appears at once with "Reading ..." and fills in; no page freezes the window (#66, #72).
  Report: page and seconds until it could be used.

## F. Update block and updates (90 min)

- [ ] **F1** Update block on.
  Expected: Settings > Windows Update shows no update page for a normal user; Office shows no update options; Edge update tasks disabled; Overview "Update block: on".
  Report: what is still reachable.
- [ ] **F2** Updates: "Search".
  Expected: Windows, Office, Edge, Teams, OneDrive, Defender, FSLogix with current and new version. "Register Microsoft Update" works.
  Report (#59): the exact error text of "Register Microsoft Update"; codes like `0x80248007` with the update title; `C:\Windows\Logs\WindowsUpdate` turned into a log with `Get-WindowsUpdateLog` (check it for names before sending).
- [ ] **F3** "Update all".
  Expected: results with KB and code in the change log; closing the window and signing out are blocked with a reason during the run; afterwards the update block is on again. Defender signatures and the Teams bootstrapper update.
  Report: per failed update the title, code and the result text.
- [ ] **F4** Software page: search one winget and one choco package, install, update, remove.
  Expected: works; a package name with wide characters does not shift the columns (the row is dropped instead of shown wrong).
  Report: the command result text; the name kind that broke the table.
- [ ] **F5** Lock: start a long `winget` install in PackTune or hold the mutex, then start an install in AVDTune.
  Expected: AVDTune waits and says for what (up to 30 minutes).
  Report: whether both ran at the same time.
- [ ] **F6** Crash: start an update run, end the PowerShell process in Task Manager, start AVDTune.
  Expected: the open maintenance mode is reported and the update block repaired.
  Report: the message; state of the update block.
- [ ] **F7** After F3 look into `C:\ProgramData\AVDTune\temp`.
  Expected: only the tool folders, no installers left, no `*.untrusted-*` folder; the state folder was not set aside (#65).
  Report: the folder names; lines of `logs\security.log` that say "set aside".

## G. FSLogix, storage check and share ACL (90 min, needs P5 and P6)

Steps F1 to F10 of `docs\fslogix.md` ("Real test"), here with what to report:

- [ ] **G1** "Install or update FSLogix".
  Expected: download below `C:\ProgramData\AVDTune\temp`, signature checked, installed, folder gone; pill yellow before when outdated, green after.
  Report: error text; file name and signer shown.
- [ ] **G2** Fill in recommended, Test, Apply, Undo.
  Expected: values under `HKLM\SOFTWARE\FSLogix\Profiles` as shown; Undo puts the old ones back; change log.
  Report: value name, expected, found.
- [ ] **G3** "Apply recommended lists", then Undo.
  Expected: Exclude list has Administrators and (in a domain) Domain Admins, Include has Everyone, foreign members stay; Undo removes only what was added. Check with `lusrmgr.msc`. On the non-joined master: whether the domain SID could be added at all.
  Report: the real names of the two local groups; the error when adding a SID.
- [ ] **G4** redirections.xml: generate and save to the share.
  Expected: the folder is prefilled; the file is on the share; `RedirXMLSourceFolder` set; a hand-written TokenBroker exclusion is refused.
  Report: path kind (UNC, local), error text.
- [ ] **G5** Defender: add the missing exclusions, Undo.
  Expected: `Get-MpPreference` shows them, Undo removes only those of AVDTune.
  Report: the exclusion that is missing or stayed.
- [ ] **G6** Function test, then with write tests.
  Expected: the write test folder and the VHDX are gone from the share afterwards; without access yellow, not red. `frx` output is read.
  Report: the row and its text; what stayed on the share; the line `frx` printed for the cookie.
- [ ] **G7** Storage check with the domain account.
  Expected: identity, SMB, DNS, roles rows; the ACL rows are read with the Storage token.
  Report: for "not checkable" the reason text; HTTP status of the permission read. This answers whether Azure Files accepts the user token (open since #18).
- [ ] **G8** Share root with a deviating ACL: "Set the recommended ACL", then "Undo the ACL" (#24).
  Expected: the confirmation shows the diff; `icacls` on the mapped share shows the recommendation; Undo puts the old ACL back only while the root still has the set one; both in the change log.
  Report: HTTP status and message of the write; `icacls` before and after with names replaced.
- [ ] **G9** ACL check with a share whose root gives Domain Users or Domain Computers write access, and one whose owner is a normal user (#83).
  Expected: not green: named as broad access or foreign owner.
  Report: the row and its colour.
- [ ] **G10** Sign in a domain test user on the VM (or a session host from the image later).
  Expected: a profile container is created on the share; SSO to Microsoft 365 works with the redirections.
  Report: FSLogix log lines with the error (`C:\ProgramData\FSLogix\Logs`).

## H. App Masking and Public Desktop (60 min, needs P5)

- [ ] **H1** List per shortcut: choose "visible for" and a group for two shortcuts, save both at once (#69, #74).
  Expected: one confirmation with all rows; rule files below `C:\Program Files\FSLogix\Apps\Rules`; the DC account of the start sequence is reused (#75).
  Report: error text; file names created.
- [ ] **H2** Sign in a test user inside and one outside the group.
  Expected: the shortcut is visible only for the member, without a restart of the service.
  Report: who sees what; whether a restart of `frxsvc` changed it.
- [ ] **H3** An administrator signs in.
  Expected: sees everything ("Administrators do not apply"), also with a UAC-filtered token.
  Report: what the administrator does not see.
- [ ] **H4** Groups with special names (P5): blank and brackets, `$` at the end, umlaut, longer than 64 characters.
  Expected: the assignment applies. Compare with a rule the FSLogix Rule Editor writes for the same group.
  Report: the `.fxa` row of AVDTune and of the Rule Editor for the same group (names replaced by same-shape placeholders).
- [ ] **H5** "Create group" in the test OU, then Undo.
  Expected: the group exists in the OU, its SID is shown at once; Undo deletes it.
  Report: LDAP error code and text.
- [ ] **H6** Local group in the assignment; nested membership through an AD group.
  Expected: applies to a user who is a member only through the nested group.
  Report: which form (`HOST\group`, SID) ended up in the `.fxa` and whether it applied.
- [ ] **H7** Logoff shortcut on the Public Desktop.
  Expected: the icon is a fitting one; a click signs out without a question; the shortcut is not refused because of the ACL of `C:\Users\Public\Desktop`.
  Report: the icon you see; the refusal text.
- [ ] **H8** Change an existing assignment and confirm; then change the rule file by hand between preview and confirmation.
  Expected: the second case is refused ("changed since it was read").
  Report: whether it was written anyway.

## I. Customizations and web apps (60 min, P8 for library files, P10 for web apps)

- [ ] **I1** One entry of each kind: shortcut, font, registry value, folder right, file copy from the library, own step (script from the library).
  Expected: before a library file is saved its size, SHA256 and first lines are shown; each entry is applied and listed in the change log; Undo takes each back.
  Report: entry kind, error text.
- [ ] **I2** A target as UNC path.
  Expected: it is not asked on its own; only after "check" by hand (the logon of the admin goes to that host).
  Report: whether the page contacted the host when it opened (firewall log or a wrong name that would time out).
- [ ] **I3** Refusals: a path with `C:\PROGRA~1\...`, a write right for Users in a program folder, a file in an autostart folder.
  Expected: refused with the reason.
  Report: what was accepted.
- [ ] **I4** Web app: add the P10 site, apply, sign in a test user.
  Expected: Edge installs the app at the first logon; the policy is one `WebAppInstallForceList` value under `HKLM\SOFTWARE\Policies\Microsoft\Edge`.
  Report: `edge://policy` status of the policy and its error text.
- [ ] **I5** Spike values for the developers (they go into `$script:Spike` of the WebApp module):
  - the app ID Edge shows in `edge://apps` for the app, and its start URL and manifest `id`;
  - whether `custom_name` and `custom_icon` are honoured (name and icon in Start menu);
  - the AppUserModelID of the running app window (PowerShell: `Get-StartApps` name and AppID);
  - pinned icon, running window and Start menu entry with an FSLogix profile, for both launch forms.
  Report: these four values and observations.
- [ ] **I6** Undo of the web app.
  Expected: the policy entry is gone; a policy key written by another tool stays as it was.
  Report: registry state under the Edge policy key.

## J. Printers (45 min, needs P5, P7)

- [ ] **J1** Open the page on the non-joined master, DC connected.
  Expected: print servers from AD; a typed IP address or short name is refused.
  Report: the list is empty: the text shown.
- [ ] **J2** Choose the server, enter the P7 account (UPN).
  Expected: shared printers with driver name, version, architecture. Kerberos from a non-joined master is the open question here.
  Report: the full error text of the connection (it tells Kerberos, DNS and WinRM apart); whether the VM resolves the server name and reaches port 5985/5986.
- [ ] **J3** Plan for the WHQL driver, confirm, apply.
  Expected: driver installed with the version of the server; `Get-PrinterDriver` shows it; no printer connection was made; temp folders gone on both sides (server: `C:\Windows\Temp`).
  Report: step and error; signer shown in the plan.
- [ ] **J4** The vendor signed driver.
  Expected: refused until the signer is confirmed, then installed.
  Report: signer text; what happened without confirmation.
- [ ] **J5** Point and Print policy: apply, Undo.
  Expected: `RestrictDriverInstallationToAdministrators = 1`, server list limited to the chosen server; foreign entries of the list are back after Undo.
  Report: registry values before, after apply, after undo (server names replaced).
- [ ] **J6** `winrm get winrm/config/client` before and after the section.
  Expected: TrustedHosts unchanged.
  Report: both values.

## K. Software, Office and custom software (120 min)

- [ ] **K1** Office page: detection.
  Expected: product, channel, installed languages, multi-session (`ServerRdsh`) are right.
  Report: for "could not be read": the sub keys below `HKLM\SOFTWARE\Microsoft\Office\ClickToRun\ProductReleaseIDs` and the `Uninstall` entries named `<product> - <culture>` (names only).
- [ ] **K2** Choose licence (E3/E5 or Business Premium), Outlook classic or new, languages, apps; look at the preview; install or reconfigure.
  Expected: download of the Office Deployment Tool, signature check, `/extract`, `setup.exe /configure`; exit code 0, 3010 or 1641; duration under 60 minutes.
  Report: the step that stopped and its text. If the signature check refuses: Properties > Details of the package and of `setup.exe` (Original filename, Product name, File description) and the signer. If the page parse fails: say so (the download page changed).
- [ ] **K3** The 1-click fixes on red rows; update policies apply and Undo.
  Expected: rows turn green; with the update block on, Undo of the Office policy does not fail and leaves the value of the update block (#101, known open).
  Report: order of the clicks and the final value of `hideenabledisableupdates`.
- [ ] **K4** Optional: "Remove", then Undo to "not installed".
  Expected: Microsoft 365 Apps gone without leftovers under `ClickToRun`.
  Report: what stayed.
- [ ] **K5** Software page, library: install the MSI from the SharePoint library (P8).
  Expected: the download follows the redirect only to Graph and SharePoint hosts; SHA256 checked; installed.
  Report: the error text. "The address is not allowed" with the shape of the address (IDs replaced, but keep special characters such as `!`), see #95.
- [ ] **K6** Custom software with recording (#87): start a recording, install a small program by hand, stop.
  Expected: programs, files, registry, services and shortcuts that changed are listed; licence notes with a key are cleaned ("(key removed)"); the recipe is saved.
  Report: what is missing in the list; duration of the before/after scan.
- [ ] **K7** End AVDTune during a recording, start again.
  Expected: the open recording is reported and can be discarded.
  Report: what the page shows.

## L. Language and region (60 min, needs P9)

- [ ] **L1** Mount the ISO by double click, choose the drive as source.
  Expected: recognised as a mounted Microsoft ISO; a `subst` drive or a share with write access for users is refused or warned.
  Report: the text for the source.
- [ ] **L2** Add one language (e.g. de-DE) with its features.
  Expected: DISM runs with a progress in the task bar; exit 0 or 3010; `Get-InstalledLanguage` shows it.
  Report: duration; DISM exit code; the capability name that was not found (for ja-JP or zh-CN also the font capability).
- [ ] **L3** Set display language, format, keyboard, location, time zone and system locale for new users; restart.
  Expected: a new local user gets all of them at the first sign-in; the welcome screen too.
  Report: which of the five is wrong for the new user and what it shows.
- [ ] **L4** A user with an existing profile and one whose FSLogix profile is created afterwards.
  Expected: the existing one keeps its language, the new one gets the new language.
  Report: what each sees.
- [ ] **L5** Undo.
  Expected: the values of the admin and of new users are back; the installed language stays (said so).
  Report: what was not restored. Note also: after a language pack the latest cumulative update must be installed again; check that the Updates page offers it.

## M. VDI components (60 min)

- [ ] **M1** Detection of Teams, WebRTC Redirector, multimedia redirection, OneDrive.
  Expected: matches what is installed. On the Marketplace image some are present.
  Report: for a false "not installed" the DisplayName from `Programs and Features`.
- [ ] **M2** Install or update each.
  Expected: download from Microsoft, signature check, install; exit 0, 3010 or 1641.
  Report: for "leads to <host>": the host name (this is the open decision for the Teams bootstrapper). Signature refusal: Original filename and signer. For the MSIs: file name (with or without version).
- [ ] **M3** Teams after `-p`: `Get-AppxProvisionedPackage -Online | ? DisplayName -like '*Teams*'`; a test user starts Teams.
  Expected: provisioned; Teams shows "AVD Media Optimized" (About > Version).
  Report: what the user sees.
- [ ] **M4** OneDrive per machine.
  Expected: in `C:\Program Files\Microsoft OneDrive`; the Updates page finds it.
  Report: install path found.
- [ ] **M5** Recommended registry settings, Undo; multimedia redirection extension in Edge.
  Expected: Edge installs the extension by policy.
  Report: `edge://policy` status.
- [ ] **M6** Remove WebRTC and multimedia redirection.
  Expected: gone from Programs and Features.
  Report: msiexec exit code.
- [ ] **M7** Session host cards (#77): RDP Shortpath setting and Undo, UDP listener, firewall, Defender onboarding state, time zone redirection.
  Expected: the cards match the master; a master that never was onboarded shows "not onboarded".
  Report: card, shown value, real value: `SelectTransport` in the registry, whether UDP 3390 listens, the state of the service `Sense`, the value below `Windows Advanced Threat Protection\Status`.

## N. Optimization and default profile (60 min)

- [ ] **N1** Open the page.
  Expected: appears at once, about 150 rows fill in with a progress in the task bar.
  Report: seconds until usable.
- [ ] **N2** Apply one preset.
  Expected: the preset is green only when every entry is really fulfilled; services, tasks, Appx removals and Defender settings are applied; missing tasks are skipped as "not present".
  Report: entry ID, expected, found; the task paths that do not exist on this build.
- [ ] **N3** Undo of the preset.
  Expected: service start types, tasks and Defender values are back (removed Appx packages stay, said so).
  Report: what was not restored.
- [ ] **N4** Defender on a master where it is absent or stopped (if you have one).
  Expected: gray "not checkable", not red.
  Report: the text.
- [ ] **N5** Defender shared signatures path (#41): enter a share by short name, by a public address, then by full name in the domain.
  Expected: the first two are refused with the reason; the third is checked only after the click.
  Report: what was accepted.
- [ ] **N6** Default profile settings (#40): classic context menu, search suggestions off, menu delay, taskbar animations. Apply, then sign in a **new** local user.
  Expected: the new user has them; an existing user is unchanged; `HKEY_USERS` has no loaded default hive left afterwards (`reg query HKU`).
  Report: which setting is missing for the new user; a leftover hive name.
- [ ] **N7** End AVDTune in Task Manager while N6 applies, start again.
  Expected: the hive left loaded is reported (readiness `hy.default-hive`) and the fix unloads it.
  Report: the readiness row.

## O. Benchmark (120 min; run as the local admin of P3)

- [ ] **O1** Quick run.
  Expected: starts (no "term is not recognized", #67), finishes in about 10 minutes, scores for CPU, memory, disk; diskspd is downloaded and its hash checked.
  Report: the error text; the measure that is empty.
- [ ] **O2** Full run with the application starts.
  Expected: Word, Excel, Edge, Explorer and PowerShell start as a throwaway local user `avdtb-*`; each program is started once unmeasured, then cold and warm; Speedometer runs in Edge InPrivate; "server busy" does not appear. Outlook and Teams are "skipped" with the reason.
  Report: the program that did not get "ready" and its text; first-run or licence dialogs you see (screenshot); the detail `isolatedUser` of the result.
- [ ] **O3** After the run: `Get-LocalUser avdtb-*`, `C:\Users`, and the admin's profile.
  Expected: no `avdtb-*` user and no profile folder left; no new entries in the admin's recent files, jump lists or Office accounts.
  Report: what is left.
- [ ] **O4** End AVDTune in Task Manager during a full run; start again without opening the Benchmark page first; run Readiness and look at "Cleanup and finish".
  Expected: the leftovers are reported and removed with the fix; Finish refuses while they are there. Known open (#98): an interrupted run may only be seen on the Benchmark page.
  Report: what Readiness and the finish gate say; whether a scheduled task `AVDTune*` and `C:\ProgramData\AVDTune\benchmark\restore.*` exist.
- [ ] **O5** FSLogix score with the share of G, GPU score on a GPU size (optional), capacity.
  Expected: scores or "unsupported" with the reason, never zero.
  Report: the measure and its text.
- [ ] **O6** Second image version (after S7) with a second full run: comparison per version, export CSV and JSON.
  Expected: red only for a drop over 10 %; the CSV opens in a spreadsheet without running anything.
  Report: the comparison row that looks wrong with both scores.
- [ ] **O7** Benchmark only: `Start-AVDTune.ps1 -Benchmark` on a fresh VM (or after a reset), and "Nur Benchmark" next to the sign-in.
  Expected: no sign-in, no snapshot gate; only the Benchmark page and the protocol; system name and notes are asked; a note that looks like a password is refused; "Ergebnisdatei exportieren" writes the file.
  Report: which other page could be opened; error text.
- [ ] **O8** Run the benchmark once signed in as a Domain Admin (after B6), only to see the message.
  Expected: the app starts still run as the throwaway user; domain groups are deny-only.
  Report: the texts AVDTune shows and whether Office or Edge asked for an account.

## P. SharePoint (30 min, needs P8)

- [ ] **P1** Protocol page, SharePoint card: enter the site, "Upload the change log".
  Expected: the list "AVDTune Change Log" is created with its columns; only new entries go up; a second upload adds nothing.
  Report: HTTP status and message. 403 means the site grant is not "write" (#96).
- [ ] **P2** Software list and environment document.
  Expected: created in the site; no secret, no password, no key in any column or file (search the list for "password", "key", "token").
  Report: the column and the kind of value that should not be there.
- [ ] **P3** A change log note that contains `net use \\<server>\<share> <password> /user:<name>` (use a made-up password), then upload and export the change log as HTML.
  Expected: the password is "(removed)" in SharePoint. Known open (#107): the local change log and its export may still show it.
  Report: where it is readable (list, HTML export, Markdown export, `changelog.json`).
- [ ] **P4** More than 200 change log entries (after the whole plan this is the case).
  Expected: all are compared, no duplicates after a second upload.
  Report: counts local and in the list.
- [ ] **P5** "Remove" the records of this master from the site.
  Expected: asks, checks the site again, removes only its own entries.
  Report: what stayed or what else went.

## Q. Watermark and user experience (15 min, optional)

- [ ] **Q1** Switch the watermark on, sign in a test user.
  Expected: visible for the user, not changeable by the user; off again removes it.
  Report: what the user sees.

## R. Protocol and change log (15 min)

- [ ] **R1** Export protocol and change log.
  Expected: every change of this plan is there with time, typed name, accounts and tool version; no token, password or key.
  Report: the missing change; a secret-like value (kind only).
- [ ] **R2** `C:\ProgramData\AVDTune\logs`.
  Expected: no secrets; `security.log` has no "set aside" line you cannot explain.
  Report: the line.

## S. Cleanup and finish (45 min)

- [ ] **S1** Healthcheck.
  Expected: green or yellow with reasons; red rows name their fix.
  Report: row ID and text.
- [ ] **S2** "Cleanup and finish" with a restart waiting (right after L or K without restart).
  Expected: `C:\Windows\Temp` is not emptied, said so.
  Report: the result text.
- [ ] **S3** After a restart: "Cleanup and finish", closing action "sign out" or "shut down" (#46).
  Expected: every step green; the image version is closed; the chosen action runs.
  Report: the step that failed and its text.
- [ ] **S4** Look at what stays in the image: `C:\ProgramData\AVDTune\temp` (known open #97), `Get-LocalUser avdtb-*`, `Get-ScheduledTask AVDTune*`, `C:\Windows\Temp`, WER folders, `config\*.json` (which files, known open #103).
  Report: the list of folder and file names that are left.
- [ ] **S5** After the finish: try one change on any page, a self-update, and a new sign-in.
  Expected: changes and self-update are refused with the clear text; only the SharePoint upload still works. Known open (#99): the sign-in is still possible.
  Report: what was still possible.
- [ ] **S6** Close AVDTune and look at `C:\ProgramData\AVDTune\temp\host`.
  Expected: no WebView2 profile with cookies left.
  Report: folder names left.
- [ ] **S7** Start AVDTune, "Start new version".
  Expected: asks for a new snapshot; the pages unlock after the confirmation; the old version stays in the history with its report.
  Report: error text.
- [ ] **S8** Optional, the real proof: capture the VM as an image (or clone the disk), deploy one session host, sign in a test user.
  Expected: language, FSLogix profile, masking, web apps, printers' drivers, Teams optimisation and the watermark behave as on the master; no AVDTune task runs on the host; no `avdtb-*` user exists.
  Report: per function works / does not work with the text.

## What to send back

- Per section a comment in #17: point number, "ok" or the values that "Report" asks for.
- Export of the protocol and the change log, and `C:\ProgramData\AVDTune\logs\` (read them first; replace names).
- Screenshots of anything unexpected, with the point number (no tenant names in the picture).

After the test: delete the VM, its disks and snapshots, the test resource group of section D, the test groups, the SharePoint lists and the app registration if it was made only for the test.

## Not covered by this plan

- Hydra hand-off, snapshot cleanup and the stand-alone benchmark package (#91, #90): not built yet.
- AD DS identity of the storage account (#43) and further Defender VDI settings (#42): not built yet.
- Custom software part 2 (#93), web app import and manifest icons (#88 follow-ups), printer maintenance on the Updates page (#86 follow-up).
- Local Experience Packs and Inbox Apps ISO (`docs\language.md`), Entra groups for App Masking, rule types other than hidden shortcuts (`docs\app-masking.md`).
