# App Masking and Public Desktop: spike result, sources, what is not verified

Issue 29, plan sections 5b and 5c. Code: `Modules\AVDTune.Masking.psm1`, page `AVDTune-AppMasking.ps1`. Checks: `Tests\Check-Masking.ps1` (fakes in `Tests\Fakes\FakeMasking.ps1`). The spike was a desk study (Microsoft Learn plus the byte format of the plan); nothing was run against FSLogix, a domain controller or a VM. What a VM still has to confirm is listed at the end.

## Result in three sentences

FSLogix reads rule sets as two files, `.fxr` (hiding rules) and `.fxa` (assignments), from `C:\Program Files\FSLogix\Apps\Rules` and uses them immediately; Microsoft does not document the byte format, so AVDTune writes exactly the format the Rule Editor produced in the plan's samples (UTF-16 LE with BOM, CRLF) and reads unknown lines back unchanged. Assignments resolve AD groups, which needs a domain controller and synced identities: Microsoft states that assignments do not support Entra ID cloud-only accounts, so Entra only environments get "hidden for everyone" at most (and the local group option, unverified). Groups in AD are created with an LDAP add over the existing pinned LDAPS connection (objectClass group, sAMAccountName, groupType `-2147483646` = global security), only after the administrator confirmed, and the SID is read back with a search.

## Sources (Microsoft Learn)

| What | Page | Used for |
|---|---|---|
| Rule sets, assignments | fslogix/concepts-fslogix-apps-rule-editor-rule-sets (page date 2025-02-10, updated 2026-03-30) | hiding rules (files, folders, registry, printers, fonts); assignment types: user, group, process, network location, computer, directory container (DN), environment variable; "Newly created rules automatically have the Everyone group assigned with the Applies setting configured to No"; the rule set is applied top to bottom (Everyone at top then `CONTOSO\Domain Users` applies = applies to Domain Users only; Everyone at the bottom = applies to nobody); "assignments don't support Microsoft Entra ID cloud-only accounts ... you must sync the users and groups from an Active Directory domain controller ... the virtual machines must have line-of-sight to a domain controller to resolve SIDs" |
| Create and deploy a rule set | fslogix/tutorial-application-rule-sets (2023-03-31, updated 2026-03-30) | two files per rule set, `.fxa` assignment and `.fxr` rule; "copy the files to `C:\Program Files\FSLogix\Apps\Rules`. Once the files are copied to this location, the FSLogix Apps Services uses them **immediately**" (so AVDTune needs no reload); the group assignment in the editor shows `Everyone` Applies No and `CONTOSO\Domain Users` Applies Yes |
| Known issues | fslogix/troubleshooting-known-issues (updated 2026-11-04) | Entra only joined devices log Event ID 26 ("Failed to get computer's group SIDs"): rule sets query a domain controller by LDAP; expected, harmless; fixed in 25.02: "FSLogix Rules don't apply to users as expected" (the page shows the installed FSLogix version) |
| groupType | learn.microsoft.com/en-us/windows/win32/adschema/a-grouptype | 0x2 global, 0x4 domain local, 0x8 universal, 0x80000000 security; global security = `0x80000002` = `-2147483646` as signed 32 bit |
| LDAP add | System.DirectoryServices.Protocols.AddRequest / DeleteRequest (.NET), RFC 4511 sections 4.7 and 4.8 | creating and removing the group object; read from the API documentation, not run |
| Include/exclude lists | fslogix/concepts-include-exclude-groups | not used here (see `docs\fslogix.md`) |

The byte format (header lines, `##` before every rule, flags `0x00000222`, `%SystemDriveFolder%\Users\Public\Desktop`, group by name with DN and FILETIME, built-in Administrators with the DN of the domain's language) comes from 32 working rule sets that the user provided in plan section 5b, not from Microsoft. Those samples stay outside the repo; the checks use synthetic golden files with the same structure.

## Group kinds

| Kind | Works for the .fxa? | AVDTune |
|---|---|---|
| AD group (global or universal security group), domain joined or hybrid session hosts | Yes, the documented case. Needs a DC in line of sight on the session host and synced users | Chosen from the DC (OU tree, groups with SIDs from `config\directory.json`) or created in a chosen OU after confirmation. The `.fxa` row uses `NETBIOS\Name`, the DN and the FILETIME of the write |
| Domain local group | Not excluded by Learn, but domain local groups only resolve in their own domain | Created groups are global; existing domain local groups are shown with a note |
| Distribution group | Not usable for access tokens | Not offered (groupType without the security bit is filtered out) |
| Local group of the master | Not documented. The plan assumes the Rule Editor writes `HOST\group`; a captured image runs under other host names | Offered with the label "not verified on a VM", written as `<COMPUTERNAME>\<group>`; membership is not managed (AD or Entra groups become members per session host, see plan 5b) |
| Entra only (cloud-only) | No: Learn says assignments do not support Entra cloud-only accounts | Only "hidden for everyone" (Everyone applies, Administrators do not) or no rule; groups are not offered, with this reason on the page |

## Writing safely

- Rule files: `C:\Program Files\FSLogix\Apps\Rules` and every folder above must pass `Get-AVDTuneAclProblems` (owner Administrators/SYSTEM/TrustedInstaller, no write for others, no link). Files are created with `CreateNew` under a temp name with the explicit protected ACL (Administrators and SYSTEM full, Users read, because the service and the sessions read them), then moved into place; an old file is never replaced in place. The result is checked again and removed when unsafe.
- Public Desktop is the one place users see AVDTune output on purpose: comfort shortcuts are created with the same file ACL (users read only), the folder must not be a link.
- Group names: `^[A-Za-z0-9][A-Za-z0-9 ._-]{0,62}[A-Za-z0-9]$`; rule set names: letters, digits, space, `._-`, max 64, no device names. The OU must be one of the OUs read from the DC (exact DN), the group DN is built from a validated name only, never from free text. Paths of rules: no `..`, no wildcards, no control characters.
- Undo: `config\masking-undo.json` holds the files as they were (absent = delete again) and the groups AVDTune created; older records are kept under a versioned name (`Write-AVDTuneUndoFile`).

## Not verified (to be tried on a throw-away VM)

1. That frxsvc applies AVDTune's files exactly like the Rule Editor's (same bytes): the hand-made-files failure causes in the plan (BOM, CRLF, trailing tab, header, SID instead of name, `##` lines) are all covered by the writer, but no file was ever loaded by frxsvc here.
2. Whether "Administrators do not apply" holds for an administrator with a UAC-filtered token.
3. The local group form in the `.fxa` and whether a user who is a member only through a nested AD or Entra group gets it in the logon token; whether a local group survives imaging.
4. Whether a domain SID can be added to a local group of a machine that is not joined (plan 5b).
5. LDAP add: that the account of the start sequence may create groups in the chosen OU (delegation), the real `AddRequest` and `DeleteRequest` (only the fake ran), and that `objectSid` is returned by the search right after the add.
6. The icon index of the logoff shortcut in `shell32.dll` (not documented; `shell32.dll,44` was chosen from common use) and `shutdown.exe /l` without a confirmation dialog.
7. FILETIME in the `.fxa` row: the plan says "time the row was added"; whether FSLogix reads it is unknown.
8. The built-in Administrators DN on a non-English domain: read from the DC by SID at write time; fake only.
9. Rule types other than file hiding (folders, registry, printers, fonts) are read and kept, not created: the first version hides files (shortcuts) on the Public Desktop, plan 5b's Start menu, app and PWA sources are not built yet.

## Hardening after the first security review (#29)

- Undo of an AD group: the group is found by its object GUID (read back after the add together with the SID, saved in the undo record only when the step really changed something) and deleted by the `<GUID=...>` form of the DN, so a move or rename does not matter. Before the delete, description, recorded SID and members are checked; members are asked by the filter `(member=*)` because AD returns big groups as `member;range=0-1499` and a count of the plain attribute would be 0. Remaining gap that LDAP cannot close: a member added between that check and the delete. The `<GUID=...>` delete form and the byte order of the GUID in it are written from the documentation and not verified on a real DC.
- Local group: an existing one is refused (never taken over); the SID is saved; undo checks description, SID and members.
- The undo record is written after the run and only holds steps with status Changed; files carry the SHA256 of what was written. Undo refuses a file that differs (`-Force` overrides) and saves the current content to `config\masking-backups` before it overwrites or deletes.
- Rule sets: only a rule line with the flags `0x00000222` counts as a file rule that AVDTune understands. A set with other rule lines (registry, folders, printers ...) or with parse problems is not changed, because a new assignment would apply to those rules too. An existing assignment that would mean something else is shown with old and new meaning and needs an explicit accept.
- Existing AD groups are bound by sAMAccountName and SID: the discovery reads `sAMAccountName`, the choice goes by SID, and when writing the account and DN are taken from the domain controller after the SID matched.
- The real writer checks every component from the drive root (no link; admin-only below the root) and replaces files with `Move-AVDTuneFileReplace` (MoveFileEx). The comfort shortcut is made in the admin-only state folder, its ACL is checked, then moved onto the Public Desktop; the Public Desktop folder itself must not be writable by users and no part of the path may be a link. Whether the default ACL of the Public Desktop passes that check is not verified (VM): if it does not, the shortcut is refused with the reason.
- Not touched here: `LastChange` for a failed step that changed something (central in `Invoke-AVDTune`, #27). After that merge a check is needed that a failed write step (partial write) still moves `LastChange`.
- Suspected, only clearable on a VM: the SID strings (`S-1-1-0`, `S-1-5-32-544`) in the name field of the Everyone and Administrators rows (`Masking.psm1`, `ConvertTo-AVDTuneFxaRows`) copy the plan's samples; whether FSLogix reads the SID there or wants a name is not verified.
