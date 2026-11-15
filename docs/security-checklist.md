# Security checklist (work through it before you hand in)

AVDTune runs elevated on a machine that becomes the image of every user. These are the findings the security review found again and again (#2, #4, #6, #10, #11, #12, #14). Check every point that your change touches and say in your report which ones you checked. A point you did not check is a finding in the review.

## Files, folders, links
- [ ] Every folder AVDTune writes to or loads from is admin-only (owner Administrators or SYSTEM, no write for others, no links): `Get-AVDTuneAclProblems` / `Test-AVDTuneAdminOnlyPath`. Check the parent folders too, not only the leaf.
- [ ] New folders are created in one step with their protected ACL (`DirectoryInfo.Create(DirectorySecurity)`), files with `CreateNew` and an explicit ACL. Never `File.Replace` over an existing file (it keeps the old ACL).
- [ ] Never repair or delete recursively in a tree someone else controls: `icacls /T` and `Remove-Item -Recurse` follow junctions. Use `Remove-AVDTuneFolderNoFollow`; check every path component for reparse points before writing.
- [ ] A folder or file someone prepared (foreign owner, links) is set aside, not trusted and not repaired in place.
- [ ] Nothing of AVDTune lands in a user-writable place (`%TEMP%` of the admin, `C:\ProgramData` root, the Public Desktop) except where it is meant for users and then read-only for them.

## Programs started by AVDTune
- [ ] Full path from `[Environment]::GetFolderPath(...)` or HKLM, never through PATH, `Get-Command` or environment variables (HKCU\Environment can override them in an elevated process). Also inside scheduled tasks (`powershell.exe`, `conhost.exe`).
- [ ] Before every start: Authenticode with exact subject (O and CN), issuer and OriginalFilename, or a pinned SHA256. Close the TOCTOU gap: start from an admin-only copy or keep the file open without delete/write share.
- [ ] Processes start with `UseShellExecute = $false` and `CreateNoWindow = $true` (also in tests: no window on the developer's desktop).
- [ ] Long runs: timeouts end the whole process tree (job object), locks are held until the tree is gone.

## Network and tokens
- [ ] Fixed hosts (allowlist), HTTPS, no automatic redirects (follow by hand and check every hop), no credentials in URLs. Tokens only to their own host.
- [ ] Path segments built from data (IMDS, ARM, user input) are validated (`[A-Za-z0-9._()-]+`), `?` at most once, `#` never. OData filters only with validated GUIDs; the real Graph refuses combined filters on some collections (`oauth2PermissionGrants`), so filter by one property and check the rest locally.
- [ ] `[Net.ServicePointManager]::SecurityProtocol` is extended with `-bor`, never overwritten.
- [ ] Secrets (tokens, passwords, storage keys) live only in memory (SecureString where possible), are cleared in `finally`, never reach the protocol, change log, run records, error texts or files. Keys only after a confirmation for this run.

## Changes to the master
- [ ] Every write goes through the write gate (`Invoke-AVDTuneStep` or an explicit gate check) and sets `LastChange` (also undo, repair, maintenance mode, failed attempts). Pure analysis does not set it.
- [ ] Every change has a change log entry and, where it can be undone, an undo that does not overwrite older backups.
- [ ] Anything that lifts a protection (update block, Defender, services) is restored in `finally`, survives a crash (journal + repair at the next start) and blocks closing the window and signing out while it runs.
- [ ] Defender exclusions: only what Microsoft documents, processes with full path, never folders users can write to without a visible risk note.

## Input and data
- [ ] Regex with a timeout and length limit; JSON/XML parsed with types checked (`"false"` is not `$false`), XML without DTD and resolver.
- [ ] Anything read from a file, Azure or a user is data, never code; no command line is built from it.
- [ ] Public repo: no customer names, hosts, tenant or object IDs, private IPs outside tests (`Tests\Check-PublicContent.ps1`).

## Tests
- [ ] Every point above that the change touches has a counter-test that fails without the fix.
- [ ] Fakes behave like the real service where we learned the difference (e.g. Graph filters).
