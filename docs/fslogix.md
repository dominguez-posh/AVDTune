# FSLogix side: sources, what is not verified, real test

Issue 10, plan sections 5a and 5d. Code: `Modules\AVDTune.FSLogix.psm1`, `Modules\AVDTune.Storage.psm1`, page `AVDTune-FSLogix.ps1`. Checks: `Tests\Check-FSLogix.ps1`, `Tests\Check-Storage.ps1`, GUI smoke (screenshots 50 to 55). Every row of the function test and of the storage check carries its Learn source and a Verified flag in the tool itself (tooltip); this page is the overview. Read on 2026-11-15.

## Sources (Microsoft Learn)

| What | Page | Used for |
|---|---|---|
| Install, unattended switches | fslogix/install-ht | `FSLogixAppsSetup.exe /install /quiet /norestart`; reboot after the install |
| Download | `https://aka.ms/fslogix_download` (redirect to `download.microsoft.com/.../FSLogix_<yy.mm>.zip`) | newest release; only that host over https is accepted |
| Settings reference | fslogix/reference-configuration-settings | names, types, defaults, meaning of every value |
| Recommended values | fslogix/tutorial-configure-profile-containers | `DeleteLocalProfileWhenVHDShouldApply=1`, `FlipFlopProfileDirectoryName=1`, `LockedRetryCount=3`, `LockedRetryInterval=15`, `ReAttachRetryCount=3`, `ReAttachIntervalSeconds=15`, `ProfileType=0`, `SizeInMBs=30000`, `VolumeType=vhdx` |
| Include/exclude lists | fslogix/concepts-include-exclude-groups | exclude list empty by default, include list holds Everyone |
| Well-known SIDs | windows-server/identity/ad-ds/manage/understand-security-identifiers | Everyone `S-1-1-0`, BUILTIN\Administrators `S-1-5-32-544`, Domain Admins `<domain SID>-512` |
| redirections.xml | fslogix/concepts-redirections-xml, fslogix/tutorial-redirections-xml | elements, `ExcludeCommonFolders` bitmask, `Copy` 0 to 3, `RedirXMLSourceFolder` (folder only), the Teams folders |
| Antivirus exclusions | fslogix/overview-prerequisites (page date 2026-03-30) | the Defender list, RC4 to AES-SHA1 notice (April 2026) |
| Services and drivers | fslogix/reference-service-drivers-components | frxsvc, frxccds, frxdrv, frxdrvvt, frxccd |
| frx | fslogix/utilities/frx/frx | `create-vhd -filename -size-mbs -dynamic -label`, `begin-edit-profile -filename`, `end-edit-profile -cookie -filename` |
| NTFS recommendation | fslogix/how-to-configure-storage-permissions | CREATOR OWNER modify (subfolders and files only), admins full, users modify (this folder only) |
| Get Permission, Get Directory Properties, Set Directory Properties | rest/api/storageservices/... | ACL over REST, `x-ms-file-request-intent: backup`, `x-ms-file-permission-key`, `x-ms-file-permission`, `preserve` |
| Storage account, file service | rest/api/storagerp/... | `azureFilesIdentityBasedAuthentication`, `activeDirectoryProperties`, `defaultSharePermission`, `protocolSettings.smb` (versions, authenticationMethods, kerberosTicketEncryption RC4-HMAC/AES-256, channelEncryption) |
| Role assignments | rest/api/authorization/role-assignments/list-for-scope | share level roles; role ids from the built-in roles page (Storage File Data SMB Share Contributor, Elevated Contributor, Privileged Contributor, Privileged Reader) |
| AD object password | azure/storage/files/storage-files-identity-ad-ds-update-password | the password is a Kerberos key; `Update-AzStorageAccountADObjectPassword` (explained, never run) |
| Entra Kerberos | azure/storage/files/storage-files-identity-auth-hybrid-identities-enable | `CloudKerberosTicketRetrievalEnabled`, admin consent, Conditional Access exclusion |

## Not verified (marked Verified=false in the tool, with the reason)

- Group names `FSLogix Profile Include List` and `FSLogix Profile Exclude List`: the Learn page names four local groups but prints no names. Adding a domain SID to a local group works through the WinNT provider (`WinNT://<SID>`); to be tried on the VM.
- `IsDynamic`, `PreventLoginWithFailure`, `PreventLoginWithTempProfile`: Learn gives the default, no recommendation.
- The cache folders of Edge, Chrome, Windows and Office in the redirections template: usual folders, not on Learn. Only Teams is from Learn. The rule "WAM and the token broker are never excluded" is AVDTune's own (from a real build log where SSO broke), not a Learn statement.
- Defender: `%TEMP%` and `%username%` are mapped to wildcards (`C:\Users\*\AppData\Local\Temp\*\*.VHDX`). Whether Defender reads these wildcards like that is not on Learn. Registry keys and mount points of the Learn list are not Defender exclusion types.
- `frx begin-edit-profile` prints a cookie: the format of the output is not documented; AVDTune reads `cookie ... <digits>`. Writing inside the attached volume is not tested (the page does not say how the volume is addressed). The original file name of `frx.exe` for the signature check is assumed to be `frx.exe`.
- Get Permission with an OAuth token: the intent header and the Privileged roles are documented, but the authorization section of the Get Permission page still names only the account owner and SAS. To be proven on the VM.
- `msDS-SupportedEncryptionTypes` bits (AES128 8, AES256 16) are from the Active Directory documentation, not from the FSLogix page. SMB 3.1.1, AES-256-GCM, premium storage, private endpoint, `pwdLastSet` thresholds (14 days) are the plan's recommendations.
- Logon as a domain user (LogonUser with new credentials, impersonation) and the key fallback mapping (WNetAddConnection2) are written from the API documentation. The VHDX test as that user is not done (frx runs as the administrator).
- The Storage audience (issue 18) is built but not tried on a real tenant: scope `https://storage.azure.com/user_impersonation`, token audience `https://storage.azure.com`. Whether Get Permission accepts that user token (see the line above) is still to be proven on the VM. Without the token the ACL rows say "not checkable" with the reason.
- Not built: reading Entra applications (admin consent, Conditional Access exclusion) and Entra groups: shown as a by-hand hint. Subscriptions: the one of this VM plus ids you enter (the ARM adapter allows only paths below a subscription id).

## Recommended include and exclude lists (issue 62)

On the FSLogix page, "Apply recommended lists" (and "Apply" of the settings, which calls the same step) sets the two local groups `FSLogix Profile Include List` and `FSLogix Profile Exclude List`:

| List | Members (by SID, never by name) |
|---|---|
| Include | Everyone `S-1-1-0`, only while the include list is empty (or already has Everyone). A list restricted to other members is left alone and a notice names them ("Include list is restricted to ...; Everyone not added") |
| Exclude | BUILTIN\Administrators `S-1-5-32-544` and, with a domain, Domain Admins = domain SID + `-512` |

- The domain SID comes only from the domain controller information (`config\directory.json`, field `DomainSid`, the `objectSid` of the domain object read over LDAPS in the start sequence). It must have exactly the form `S-1-5-21-x-y-z` (`\A...\z` pattern); anything else is not used (ASCII digits `[0-9]` only, never `\d`). It is never derived from a group SID or guessed. It is checked against the domain of the master (the SID Windows resolves for `<NetBIOS>\Domain Admins`): a different domain SID is not used, no Domain Admins exclude, a notice. A master that is not domain joined cannot resolve it: the SID of the pinned domain controller is used and the notice says it could not be checked.
- Without a domain (Entra only) or without a known domain SID only the local administrators are excluded, and the page says so (notice under the buttons, in the confirmation).
- The "Apply" of the settings names the list changes in its own confirmation ("Also: Include + Everyone; Exclude + BUILTIN\Administrators (S-1-5-32-544), + <DnsName>\Domain Admins (<SID>)"); when the lists stay as they are, nothing is said. "Apply recommended lists" uses the same text.
- Members that are already there stay; foreign entries stay and are shown in the list text. More exclude groups stay optional (pick a group or type a SID).
- Test (WhatIf), Apply and Undo run through `Invoke-AVDTune` (write gate, change log, `LastChange`). "Undo recommended lists" removes exactly the members the last Apply really changed (a stack in `config\fslogix-lists-undo.json`, written after the run from the steps with the status Changed: older entries are never overwritten); members that were there before, members added by hand after the Apply, and foreign members stay, and Undo reports them.
- Source: the include/exclude groups concept page above (exclude groups, the include list for Everyone, why administrators are excluded) and the well-known SID table. Not verified offline: the exact wording of the Learn recommendation to exclude administrators (the page names the groups but not their names, see "Not verified"); the group names and adding a domain SID through the WinNT provider are tried on the VM (F3, F9).

## redirections.xml: folder prefilled (issue 68)

The field "Folder of the file (RedirXMLSourceFolder)" opens with the value set in `HKLM\SOFTWARE\FSLogix\Profiles`, otherwise with `<ProgramData>\AVDTune-Public\FSLogix\Redirections` (the folder AVDTune already makes for the watermark settings copy: Users read only, Administrators and SYSTEM write, created and checked with the same functions; `ProgramData\FSLogix` is not proposed because the FSLogix installer makes it with a Users write right) (`[Environment]::GetFolderPath('CommonApplicationData')`, never the environment variable). It is only filled while the field is empty and not being typed in.

- Who reads the file: FSLogix copies `redirections.xml` from the source folder into the profile container at sign-in, as the signing-in user (the profile log shows `Attempting to copy: "<folder>\Redirections.xml" to: "C:\Users\%username%\AppData\Local\FSLogix\Redirections.xml"`). Sources, read 2026-11-17: fslogix/tutorial-redirections-xml (page date 2023-03-31, updated 2026-03-30): "Users require read access to the file share where the .xml file is stored. Users without read access can't copy the .xml file during sign-in."; "The path could also be a local path if the .xml file is part of a gold image."; fslogix/concepts-redirections-xml (page date 2025-12-11): "be sure users only have read permissions to the XML file".
- So the folder is created on save, when it is missing, in one step with a protected ACL (`New-AVDTuneUsersReadSecurity`, the same as the watermark settings copy): no inheritance, owner Administrators, Administrators and SYSTEM full control, Users read and execute only. Folders that AVDTune has to create above it get the same ACL.
- A folder that is there is used only when it passes the rule of issue 10: no link on the way, owner Administrators or SYSTEM, no write access for anyone else (`Get-AVDTuneAclProblems`). Only `C:\ProgramData` itself is exempt (users may create folders there); every existing folder between it and the target (e.g. `ProgramData\FSLogix`) must pass the full check too, because a user who made that folder beforehand owns it and could rename or replace the protected folder below it (CTO decision). A missing intermediate folder is created protected in the same step. That is why the default lives under `AVDTune-Public` (the folder AVDTune controls, made by the watermark settings copy with the same `New-AVDTuneUsersReadSecurity` ACL) and not under `ProgramData\FSLogix`, which the FSLogix installer makes with the inherited Users write right and which the check would refuse. An `AVDTune-Public` that a user made beforehand is refused as well. Every other local folder must be admin-only up to the drive root (`Test-AVDTuneAdminOnlyPath`). A folder with foreign rights, a foreign owner or a link is not used: the save stops before anything is changed and the message names the reason. Shares stay the administrator's choice.
- Undo restores the file only; a folder that was created stays (empty).
- Not tried on a real VM: the creation with the real ACL (the check run is not elevated; the check only tests the refusal path there). To do in the F4 step: save with an empty registry value and read the folder's ACL.

## Status pill of the installation (issue 63)

The pill of the "Installation" card compares the installed version with the newest release. The newest release is read when the page opens, in the background, with the same function as the Updates page (`Get-AVDTuneFSLogixLatest`: HEAD request to `https://aka.ms/fslogix_download`, no redirect followed, only `download.microsoft.com` over https accepted, 15 second limit, no download). The result is cached for 60 minutes (5 minutes when it failed, then it is asked again).

| Pill | When |
|---|---|
| red "Not installed" | no `InstallVersion` |
| yellow "Update available: <yy.mm>" | the installed version is older than the newest release |
| green "Installed, up to date" | the installed version is not older than the newest release |
| grey "Installed, newest version unknown" + reason (tooltip and the line below) | the lookup failed or timed out, the file name has no `<yy>.<mm>`, the installed version does not fit the pattern, or the case below |

How the versions are compared (source: FSLogix release notes, `https://learn.microsoft.com/en-us/fslogix/overview-release-notes`, page date 2026-09-01, read 2026-11-17). The notes state for 25.02: release name 25.02, build version `3.25.202.4223` = `3.YY.MMDD.HHMMS`, "single digit months don't have a leading 0" (so 3.26.826 = 26-08-26, 3.25.1128 = 25-11-28). Before that the numbering was 2.9.x (2210 hotfix 4 = 2.9.8884.27471).

| Release (name) | Build version | third part |
|---|---|---|
| 25.02 | 3.25.202.4223 | 202 |
| 25.04 | 3.25.401.15305 | 401 |
| 25.06 | 3.25.626.21064 | 626 |
| 25.09 | 3.25.822.19044 | 822 |
| 26.01 | 3.26.102.18413 (CU1: 3.26.126.19110) | 102 |
| 26.08 | 3.26.826.17182 | 826 |

The release name is therefore not always the build month (25.09 was built on August 22), so "release yy.mm always equals build month" does not hold. The rules (`Get-AVDTuneFSLogixVersionState`, table in the module):
- 2.x: yellow. A build part that is no date, a major other than 2 or 3, or a version not of the form `a.b.c.d`: grey.
- Older year than the release: yellow; later year: green.
- A release in the table above: exact compare of the third part (month and day): equal or newer green, older yellow.
- A release not in the table (a future one; the table is extended when the notes list it): build month not before the release month green; two or more months before yellow; exactly one month before grey (can be that release, as 25.09 is build 822). "Two or more months" is an observation from the six releases above (build in the release month or one month before), not stated by Learn.

Example: 3.26.826 against 26.08 green, against 26.11 yellow, against 26.09 grey; 3.25.1128 against 26.02 yellow.
## Storage token for the NTFS rows (issue 18)

The ACL rows of the storage check read the NTFS rights over the Azure Files REST API with the signed-in user's token (OAuth, header `x-ms-file-request-intent: backup`, never a key). That is the fourth audience of the sign-in (`AVDTune.Session.psm1`):

| | |
|---|---|
| Resource | Azure Storage (`e406a681-f3d4-42a8-90b6-c2b029497af1`), token audience `https://storage.azure.com` |
| Scope | `https://storage.azure.com/user_impersonation`, delegated, consent for the signed-in administrator only (`consentType` `Principal`) |
| Token | fetched from the refresh token like the others, claims checked (exact `aud`, `tid` of the sign-in, `scp` contains `user_impersonation`), in memory only (SecureString), removed by sign out and Finish |
| Sent to | only `https://<account>.file.core.windows.net` of the checked storage account (account and share names validated, https, default port, no userinfo, no redirects); never to ARM, Graph or any other host. The ARM token never goes to the share |

The Storage token is optional. An app registration made before issue 18 has no consent for it: the sign-in still works with the other three tokens, the protocol and the FSLogix page say "No Storage token ..." with the reason, and the ACL rows stay "not checkable" (or the key fallback that you confirm for a run). Nothing is changed silently. To retrofit: Overview, sign-in step, "Set up again (authorize this administrator)": the setup (after its confirmation) adds Azure Storage `user_impersonation` to the registration, adds the Azure Storage service principal to the tenant if it is missing, and grants your consent for it (the same path as for Azure Service Management). Other administrators do the same with their own account. Without the roles for that (Application Administrator, Privileged Role Administrator) an administrator does it in the Entra admin center: API permissions > Azure Storage > `user_impersonation`, then grant consent.

## Real test on the throwaway VM (after docs\test-vm.md steps 1 to 4)

| # | Step | Expected |
|---|---|---|
| F1 | FSLogix page: "Install or update FSLogix" | The newest release is downloaded to a folder below `C:\ProgramData\AVDTune\temp`, the signature is checked, FSLogix installs, `InstallVersion` appears, the folder is gone. Updates page shows FSLogix as updatable before. |
| F2 | Fill in recommended, Test, Apply, Undo | Registry values under `HKLM\SOFTWARE\FSLogix\Profiles` as shown; Undo puts the old ones back; change log and LastChange. |
| F3 | Exclude local administrators | `FSLogix Profile Exclude List` contains Administrators (check with `lusrmgr`). |
| F9 | FSLogix page: "Apply recommended lists" in a domain, then Undo | Exclude contains Administrators and Domain Admins (SID ends in `-512`), include contains Everyone, existing foreign members stay; Undo removes only what was added; without a domain only Administrators and a notice. |
| F4 | redirections.xml: generate, save | File on the share; the `RedirXMLSourceFolder` value set; a hand-written TokenBroker exclusion is refused. |
| F5 | Defender: add the missing exclusions, Undo | `Get-MpPreference` shows them; Undo removes only those AVDTune added. |
| F6 | Run test; run test with write tests (needs a share) | Rows as in the screenshots; write test folder gone from the share; no VHDX left; if the master has no access (not joined): yellow, not red. |
| F7 | Storage check with a domain account | Identity, SMB, DNS, roles; ACL rows need the storage token (sign-in with the Storage audience); with a confirmed key fallback the key use is named in the change log. |
| F8 | Sign in with a registration made before issue 18, then "Set up again" | First: sign-in works, warning "No Storage token", ACL rows not checkable with the hint. After the setup: Storage token present, ACL rows are read. |
| F10 | Storage check with a deviating root ACL, "Set the recommended ACL", then "Undo the ACL" (issue 24) | Role Storage File Data Privileged Contributor; the confirmation shows the diff; `icacls` on the mapped share shows the recommendation; the undo record `config\storage-acl-undo.json` holds the ACL before and the one Azure keeps; Undo puts the old one back only when the root still has the set one; both in the change log. Not tried on a real share yet: whether Set Directory Properties takes `x-ms-file-permission-format: sddl` with the user token. |
