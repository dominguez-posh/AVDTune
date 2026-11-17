# VDI components page (phase 6, issue 56 part 2)

Page "VDI components": new Microsoft Teams, the Remote Desktop WebRTC Redirector Service, multimedia redirection (MMR) and OneDrive per machine on a Windows 11 multi-session master. Code: `Modules/AVDTune.Vdi.psm1` (logic), `AVDTune-Vdi.ps1` and `UI/Vdi.xaml` (page), `Tests/Fakes/FakeVdi.ps1`, `Tests/Check-Vdi.ps1`. Not done here (still planned for this page): Defender onboarding for non-persistent VDI, RDP Shortpath, time zone redirection.

## What it does
Per component a card with a pill (green = installed and current, yellow = an update or a setting is open, red = not installed, gray = cannot be told), rows with the reason and the fix (tooltip: Learn source and whether Learn states it), and buttons: Install or update, Remove, Undo the change, Set recommended settings, Undo settings. "Test" reads everything and changes nothing. "Check for updates" follows the entry links of the two MSIs by hand (nothing is downloaded) and compares the version in the file name with the installed one; Teams and OneDrive have no readable "newest" version (Teams: `-p` always fetches the latest client; OneDrive: winget), so their pill is gray when installed.

| Component | Detection | Install / update | Remove / undo | Settings (registry, Test/Apply/Undo) |
| --- | --- | --- | --- | --- |
| Teams (new) | Appx `MSTeams` (registered or provisioned), VC++ runtime, FSLogix >= 2.9.8716.30241, WebRTC service present, `disableAutoUpdate` (read only) | `teamsbootstrapper.exe -p` (downloaded, checked, held) | `teamsbootstrapper.exe -x` (deletes the Teams profile data too; the confirmation says so). Undo = remove when Teams was not there | `HKLM\SOFTWARE\Microsoft\Teams\IsWVDEnvironment` = 1 (DWORD) |
| WebRTC Redirector Service | Uninstall entry with the exact DisplayName, version from DisplayVersion | `msiexec /i <msi> /qn /norestart` (replaces an installed older one) | `msiexec /x <product code>`; Undo = remove when it was not there | none |
| Multimedia redirection | Uninstall entry (DisplayName), VC++ >= 14.32.31332, Edge/Chrome closed (checked before the start), policy rows | `msiexec /i <msi> /qn /norestart` | `msiexec /x`; Undo as above | machine policy `ExtensionSettings` (REG_SZ JSON): extension force installed for Edge, optionally Chrome. An existing policy is merged (other entries stay), a broken one is never overwritten |
| OneDrive per machine | `OneDrive.exe` in Program Files (file version), registry `Version` as fallback | `winget install --id Microsoft.OneDrive --exact --scope machine` inside the `Global\PackTune` lock (the Updates page updates it with winget as before) | `winget uninstall ... --scope machine`; Undo = remove when it was not there | HKLM Run value `"<OneDrive.exe>" /background`, policy `FilesOnDemandEnabled` = 1, optional `SilentAccountConfig` = 1 (only for a Microsoft Entra joined master) |

Teams `disableAutoUpdate` is owned by the update block (Update block page, which sets and restores it): the Teams card only shows it, so nothing is done twice.
No Undo for a component that was installed before AVDTune changed it: Microsoft offers no older builds. The undo text says so.

## Where the files come from
- Entry links (Learn): `https://go.microsoft.com/fwlink/?linkid=2243204` (Teams bootstrapper), `https://aka.ms/msrdcwebrtcsvc/msi`, `https://aka.ms/avdmmr/msi`. Only these two hosts are asked first.
- Every redirect is followed by hand (`AllowAutoRedirect = false`, at most 5 hops); every hop must be https on `aka.ms`, `go.microsoft.com` or `download.microsoft.com`, without port or user info; the last hop must be `download.microsoft.com`, path under `/download/`, no query, no `..`, the file type of the component (.exe / .msi). The file name on disk is fixed (`teamsbootstrapper.exe`, `webrtc-redirector.msi`, `mmr-host.msi`), never taken from the address.
- Download into a new folder below the protected state folder (Administrators and SYSTEM only), at most 60 or 100 MB, https only from `download.microsoft.com`.
- Checks before the start: MSI header (OLE compound file); Authenticode: signer O and CN `Microsoft Corporation`, issuer a Microsoft code signing CA; original file name exact (`teamsbootstrapper.exe`; an MSI carries none and the check requires exactly that, so a renamed exe is refused); for MSI also `msiexec.exe` by full path (Windows signer, original file name). The file is held open without write/delete share from the first check until its process ended and is checked again right before the start. The program starts through the central child environment (issue 47) in a job object.
- OneDrive does not use its own download host: winget (checked like everywhere) installs it.

## Changes, record, undo
Every change is behind the write gate, sets `LastChange` (also on failure, not for analysis exits), writes a run record (Plan `VDI <component> install|remove`, settings `... settings`) and a change log entry (category VDI). Undo records: `config\vdi-<key>-undo.json` (state before the first change, never overwritten), `config\vdi-<key>-settings-undo.json` (typed values found before the first apply, never overwritten, new ids are added; a record that is not exactly typed is refused). Long runs are tasks on the task bar in a background runspace and block closing the window and sign-out while they run.

The Updates page: the Teams update no longer ends in `ToolMissing` (#59) when `teamsbootstrapper.exe` is not in `config\tools`: it calls the same download-and-check flow of this module (`Invoke-AVDTuneVdiPackage`). A file in `config\tools` is still preferred.

## Sources (Microsoft Learn, read 2026-11-16)
- Use Microsoft Teams on Azure Virtual Desktop (`IsWVDEnvironment`, WebRTC Redirector MSI `https://aka.ms/msrdcwebrtcsvc/msi`, FSLogix 2.9.8716.30241, VC++): https://learn.microsoft.com/en-us/azure/virtual-desktop/teams-on-avd (page date 2026-06-18)
- Teams for VDI, new Teams (`teamsbootstrapper.exe -p`, `-p -o <msix>`, `-x`, `disableAutoUpdate`, bootstrapper link): https://learn.microsoft.com/en-us/microsoftteams/teams-client-vdi-requirements-deploy (2026-08-25)
- Multimedia redirection (MSI `https://aka.ms/avdmmr/msi`, `msiexec /i ... /qn`, browsers closed, extension ids and `ExtensionSettings` JSON, VC++ 14.32.31332.0): https://learn.microsoft.com/en-us/azure/virtual-desktop/multimedia-redirection-video-playback-calls (2026-11-11)
- OneDrive per machine (`OneDriveSetup.exe /allusers`, detection by `Version` in the 32-bit view): https://learn.microsoft.com/en-us/sharepoint/per-machine-installation (2024-11-05)
- OneDrive on virtual desktops (Run value `/background`, `SilentAccountConfig`, FSLogix, per machine is required for non-persistent): https://learn.microsoft.com/en-us/sharepoint/sync-vdi-support (2025-08-10)

## Not verified (needs the test VM, listed as check points in #17)
- The whole real flow of the real adapter: following the three entry links live (do `aka.ms` and `go.microsoft.com` answer 301/302 with an absolute `Location`?), the download, the start of the bootstrapper and of msiexec, exit codes (0, 3010, 1641 assumed success; 1618 = another installation).
- Where `https://go.microsoft.com/fwlink/?linkid=2243204` (Teams bootstrapper) really ends. If it ends on a host other than `download.microsoft.com` (the Teams CDN is the likely one) the install fails closed with "leads to <host>". Allowing that second host is a security decision for the CTO (open question).
- Original file name of the real `teamsbootstrapper.exe` (expected `teamsbootstrapper.exe`, compared case-insensitively) and that a Microsoft-signed MSI has an empty original file name; Authenticode on an `.msi` through `Get-AuthenticodeSignature`.
- Display names in the Uninstall registry: `Remote Desktop WebRTC Redirector Service` and `Remote Desktop Multimedia Redirection Service` (from the Learn text, not read from a machine); product codes are taken from the key names. A different DisplayName shows "not installed" (a false red).
- That the version appears in the MSI file names (the WebRTC name is assumed to carry `1.xx.yyyy.zzzzz`); without it "Check for updates" stays gray. The two MSIs do not update themselves (Learn), so there is no "newest" source other than the file name.
- `Get-AppxProvisionedPackage -Online` showing `MSTeams` after `-p` before a user signed in, and the `-x` removing the provisioned package.
- Removal of the WebRTC service and MMR with `msiexec /x <product code>` and a clean registry afterwards (Learn documents only the install). Removal of OneDrive per machine with `winget uninstall --scope machine`.
- That winget's `Microsoft.OneDrive` machine-scope installer runs `OneDriveSetup.exe /allusers` and ends up in `C:\Program Files\Microsoft OneDrive` (the path of the Updates page).
- Machine policy `ExtensionSettings` stored as REG_SZ JSON under `HKLM\SOFTWARE\Policies\Microsoft\Edge` and `...\Google\Chrome` (the standard Chromium policy layout; the MMR article shows the JSON but not the registry location), and that Edge force-installs the extension from it.
- `HKLM\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64` (`Installed`, `Major`, `Minor`, `Bld`) for the VC++ runtime: from experience.
- `FilesOnDemandEnabled` (OneDrive policy, not on the two Learn pages named above); OneDrive registry `Version` under `WOW6432Node`.
- The registered/provisioned Teams does not start on its own for users before the first launch (Learn note about MSIX autostart); not handled.
- GUI: covered by the smoke (page, install with fake adapter, settings, browser running, lookup, failed redirect); the real page was not seen by a person.

## Out of scope here
Teams optimized only for SlimCore on the client; hardware encode and RemoteApp screen sharing registry keys of the Teams article (per client or per RemoteApp, not for the master image); MMR site allow lists (`AllowedVideoRedirectionSites`, `AllowedCallRedirectionSites`) and `HideAdvancedSettings`; installing the Visual C++ Redistributable (only detected).
