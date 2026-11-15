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
- The storage audience (`https://storage.azure.com/`) is not one of the three audiences of the sign-in (`AVDTune.Session.psm1`, issue 11): without a storage token the ACL rows say "not checkable".
- Not built: reading Entra applications (admin consent, Conditional Access exclusion) and Entra groups: shown as a by-hand hint. Subscriptions: the one of this VM plus ids you enter (the ARM adapter allows only paths below a subscription id).

## Real test on the throwaway VM (after docs\test-vm.md steps 1 to 4)

| # | Step | Expected |
|---|---|---|
| F1 | FSLogix page: "Install or update FSLogix" | The newest release is downloaded to a folder below `C:\ProgramData\AVDTune\temp`, the signature is checked, FSLogix installs, `InstallVersion` appears, the folder is gone. Updates page shows FSLogix as updatable before. |
| F2 | Fill in recommended, Test, Apply, Undo | Registry values under `HKLM\SOFTWARE\FSLogix\Profiles` as shown; Undo puts the old ones back; change log and LastChange. |
| F3 | Exclude local administrators | `FSLogix Profile Exclude List` contains Administrators (check with `lusrmgr`). |
| F4 | redirections.xml: generate, save | File on the share; the `RedirXMLSourceFolder` value set; a hand-written TokenBroker exclusion is refused. |
| F5 | Defender: add the missing exclusions, Undo | `Get-MpPreference` shows them; Undo removes only those AVDTune added. |
| F6 | Run test; run test with write tests (needs a share) | Rows as in the screenshots; write test folder gone from the share; no VHDX left; if the master has no access (not joined): yellow, not red. |
| F7 | Storage check with a domain account | Identity, SMB, DNS, roles; ACL rows need the storage audience; with a confirmed key fallback the key use is named in the change log. |
