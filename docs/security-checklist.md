# Security checklist (work through it before you hand in)

AVDTune runs elevated on a machine that becomes the image of every user. These are the findings the security review found again and again (#2, #4, #6, #10, #11, #12, #14) and the rules that later issues refer to by number (#47 to #108). Where it exists, a point names the function to use and the check that enforces it; "open" marks a rule whose fix is not merged yet, "no check yet" a rule only the review enforces. Check every point that your change touches and say in your report which ones you checked. A point you did not check is a finding in the review.

## Files, folders, links
- [ ] Every folder AVDTune writes to or loads from is admin-only (owner Administrators or SYSTEM, no write for others, no links): `Get-AVDTuneAclProblems` / `Test-AVDTuneAdminOnlyPath`. Check the parent folders too, not only the leaf.
- [ ] New folders are created in one step with their protected ACL (`DirectoryInfo.Create(DirectorySecurity)`), files with `CreateNew` and an explicit ACL. Never `File.Replace` over an existing file (it keeps the old ACL).
- [ ] A folder AVDTune makes for itself (tool TEMP, `<state>\temp`, download and work folders) goes through `New-AVDTuneOwnFolder` / `New-AVDTuneDownloadFolder`: created with the protected ACL and read back (owner, no inherited rule, no foreign rule); a folder someone made first is refused. Downloaded files through `New-AVDTuneAdminFile`. No `CreateDirectory`, no `File.Create` (#54, #79; `Check-Updates.ps1` "own folder", "work folder").
- [ ] Never repair or delete recursively in a tree someone else controls: `icacls /T` and `Remove-Item -Recurse` follow junctions. Use `Remove-AVDTuneFolderNoFollow`; check every path component for reparse points before writing.
- [ ] Every delete in a tree others can write to (`C:\Windows\Temp`, WER, the admin's `%TEMP%`, ProgramData root) goes through `Remove-AVDTuneTreeSafe`: entries are opened relative to the handle of their folder and deleted through that handle, a link is removed and never entered, no attribute is changed. Never check a path and then delete by name (#48, `docs/safe-delete.md`; `Check-SafeDelete.ps1`).
- [ ] A folder or file someone prepared (foreign owner, links) is set aside, not trusted and not repaired in place.
- [ ] Nothing of AVDTune lands in a user-writable place (`%TEMP%` of the admin, `C:\ProgramData` root, the Public Desktop) except where it is meant for users and then read-only for them.

- [ ] Path rules compare the long form (`Get-AVDTuneLongPath`): an 8.3 short name (`C:\PROGRA~1`) is Program Files; input with `~<digit>` is refused where a folder rule decides. Names from data refuse the device names (CON, PRN, AUX, NUL, COM1-9, LPT1-9, also with an extension), `.` and `..` segments, trailing dots and blanks (`Check-AVDTune.ps1` "8.3", `Check-Custom.ps1` M1, `Check-Masking.ps1` "names", `Check-Benchmark.ps1` "run id").

## Programs started by AVDTune
- [ ] Full path from `[Environment]::GetFolderPath(...)` or HKLM, never through PATH, `Get-Command` or environment variables (HKCU\Environment can override them in an elevated process). Also inside scheduled tasks (`powershell.exe`, `conhost.exe`).
- [ ] Before every start: Authenticode with exact subject (O and CN), issuer and OriginalFilename, or a pinned SHA256. Close the TOCTOU gap: start from an admin-only copy or keep the file open without delete/write share.
- [ ] Processes start with `UseShellExecute = $false` and `CreateNoWindow = $true` (also in tests: no window on the developer's desktop).
- [ ] Long runs: timeouts end the whole process tree (job object), locks are held until the tree is gone.

- [ ] One way to start a program: `Invoke-AVDTuneChildProcess` (start info from `New-AVDTuneChildStartInfo`, job object from the first instruction, timeout over the tree) or `Invoke-AVDTuneProgram` for Windows programs. No `&` on an .exe, no `Start-Process`, no own `ProcessStartInfo` or job object in a module (#53, #76; AST guard "child start" in `Check-Updates.ps1`, exceptions are listed there with a reason).
- [ ] The child never inherits the environment of the elevated process: `Get-AVDTuneChildEnvironment` builds an allowlist per tool profile from `[Environment]::GetFolderPath` and HKLM (raw, not expanded), never from `$env:`; TEMP/TMP is an own folder below `<state>\temp`; choco gets `ChocolateyInstall` from HKLM and `--cache-location` (#47; `Check-Updates.ps1` "real Run", "child env").
- [ ] Programs of the Windows folder (dsregcmd, sc, reg, klist, fltmc, icacls ...) start only through `Invoke-AVDTuneProgram` / `Open-AVDTuneSystemProgram`: an .exe below the Windows folder, catalog signature "Microsoft Windows", the file held without write sharing until the run ends; fail closed with a clear message (#71; `Check-Updates.ps1` "Windows signature").
- [ ] TEMP/TMP of the AVDTune process itself: set at the start before the first module import and before any `Add-Type`, then `<state>\temp\host`. No `[IO.Path]::GetTempPath()` for anything that is loaded or run (#54; `Check-Updates.ps1` "process TEMP").
- [ ] Module path: the first statement of `Start-AVDTune.ps1` and of the launcher sets `PSModulePath` to the system folders (`Get-AVDTuneSystemModulePath`), with .NET only and no command before it. Start with `-NoProfile` (#73; `Check-AVDTune.ps1` "module path").
- [ ] Runspaces and PowerShell instances only through `New-AVDTunePowerShell` / `New-AVDTuneRunspacePool` (they carry the module path and the imports); no `[powershell]::Create()` or `[runspacefactory]` anywhere else (#73; source check in `Check-AVDTune.ps1`).
- [ ] winget and choco run only inside the mutexes `Global\PackTune` and `Global\IntuneChocoDeployment`; an empty name list fails closed (#78; `Check-Updates.ps1`, `Check-Software.ps1`).

## Closures and background workers
- [ ] A `{...}.GetNewClosure()` block sees neither `$script:` variables nor functions the module does not export: no `$script:`, no `$using:`, no `*-Variable -Scope Script`, no private function inside. Copy values into locals first, export or inline the function (#55, #78; AST check "GetNewClosure" in `Check-AVDTune.ps1`).
- [ ] Every real adapter has a counter-test that builds it in a fresh runspace with exactly the imports of its page and makes one harmless read. Fakes hide a dead adapter (#55, #67).
- [ ] A worker text (here-string run by a runspace) calls only module functions that hold the gate and the marker themselves; the AST checks do not look into here-strings (#81 F4).

## Network and tokens
- [ ] Fixed hosts (allowlist), HTTPS, no automatic redirects (follow by hand and check every hop), no credentials in URLs. Tokens only to their own host.
- [ ] Path segments built from data (IMDS, ARM, user input) are validated (`[A-Za-z0-9._()-]+`), `?` at most once, `#` never. OData filters only with validated GUIDs; the real Graph refuses combined filters on some collections (`oauth2PermissionGrants`), so filter by one property and check the rest locally.
- [ ] `[Net.ServicePointManager]::SecurityProtocol` is extended with `-bor`, never overwritten.
- [ ] A token (and a rotated refresh token) is checked first (aud, tid, scp) and stored only afterwards; a failing check changes nothing, also on the second call.
- [ ] Optional paths catch only the expected error class (e.g. missing consent); everything else ends the operation like for the required paths.
- [ ] Secrets (tokens, passwords, storage keys) live only in memory (SecureString where possible), are cleared in `finally`, never reach the protocol, change log, run records, error texts or files. Keys only after a confirmation for this run.

- [ ] Asking a UNC path or another Windows-authenticated host sends the administrator's logon to it. Never automatically (page load, reachability check): only after the administrator asked for it, and only to a full name inside the known domains or a private IPv4 address (`Get-OptUncHostProblem`, `Test-AVDTunePrivateIp`); single-label names, localhost and public addresses are refused. WinRM with Kerberos only (FQDN), no TrustedHosts (#41, #85, #86; `Check-Custom.ps1` "reachability", `Check-Optimization.ps1`, `Check-Printers.ps1` "sources (H1)").
- [ ] No default credentials for a proxy: never `Proxy.Credentials = DefaultCredentials` / `UseDefaultCredentials`. The system proxy comes from user settings or WPAD and would get the administrator's NTLM/Kerberos (#106 open; no check yet).
- [ ] Downloads and answers have a host check per hop, a size limit and a time limit, also when a hash is pinned afterwards (#108 N3/N7 open; no check yet).
- [ ] An HTTP error is read from `InnerException.Response` first, then `Response`: PowerShell wraps the `WebException`, the outer exception has no response and a 4xx would look like "no connection" (#28, #89; `Check-AVDTune.ps1` "a 400 answer", `Check-SharePoint.ps1` "transport (B1)").
- [ ] One secret filter: a single pattern table (regex timeout, fail closed: a timeout gives "(removed)" or refuses the upload) is applied before every export and upload and by the functions that store text themselves (change log, run records, protocol, task bar, recording, SharePoint). No second table next to it. Today the complete table is `Invoke-AVDTuneSpSecretRules` (`AVDTune.SharePoint.psm1`, used by `Protect-AVDTuneSpText` and `Test-AVDTuneSpSecretFree`); the other filters still differ (#107 open; `Check-SharePoint.ps1`, `Check-Tasks.ps1` "secrets and limits").

## Changes to the master
- [ ] Every write goes through the write gate (`Invoke-AVDTuneStep` or an explicit gate check) and sets `LastChange` (also undo, repair, maintenance mode, failed attempts). Pure analysis does not set it.
  - Clarification (user go, issue 32): `LastChange` applies to changes of the master. Azure resources that AVDTune creates (storage account, share, DNS, private endpoint, roles of the environment wizard) are not in the OS disk snapshot and have their own journal undo (`config\azure-setup.json`); they do not set `LastChange`, but still need the open write gate, the confirmed plan hash, a change log entry (category Azure) and a journal entry. The master part (FSLogix registry values) sets `LastChange`, also when it fails.
- [ ] Every change has a change log entry and, where it can be undone, an undo that does not overwrite older backups.
- [ ] Anything that lifts a protection (update block, Defender, services) is restored in `finally`, survives a crash (journal + repair at the next start) and blocks closing the window and signing out while it runs.
- [ ] Defender exclusions: only what Microsoft documents, processes with full path, never folders users can write to without a visible risk note.

- [ ] Every write of the master runs under the change marker: `Start-AVDTuneChange` before it, the write inside the `try` whose `finally` calls `Stop-AVDTuneChange` (or through `Invoke-AVDTune`). `LastChange` alone is not enough: the snapshot confirmation and a second process read the marker. The gate check comes before the marker (#27, #58, #81, #104 N10; AST check "change marker" in `Check-AVDTune.ps1`, exemptions listed there with a reason).
- [ ] One writer at a time: every start of an operation that changes the master asks `Assert-NoOtherWriter` itself (not only its caller) and holds the central lock (`Enter-AVDTuneWriter` / `Exit-AVDTuneWriter`, inline through `Invoke-UiTaskInline -Writer`). Every background job variable of a page is in `$script:WriterJobVariables` or in the read-only list of the check. Closing the window, signing out and "new version" wait for every writer (#49, #66, #104 N1/N2; `Check-Tasks.ps1`).
- [ ] The window thread changes nothing and reads nothing slow; that is in the worker of the page (#44, #66, #72; `Check-Tasks.ps1`).
- [ ] Sealed: after the finish every writer refuses with the clear text, also module writers outside `Start-AVDTuneChange` (`Assert-AVDTuneNotSealed`), and before anything is written (also undo files). `-AllowSealed` only for the crash repairs, the new version and the SharePoint upload (#50, #104 N5/N6; `Check-Tasks.ps1`).
- [ ] A confirmation is bound to what the administrator saw: the write gets the hash or the old/new pair of the preview (`-ConfirmedHash`, `-ExpectedHash`, `-ExpectedChange`, `ExpectedSha`), reads again and refuses when it differs. Never "confirmed = true" alone (#32, #72, #74; `Check-Environment.ps1`, `Check-FSLogix.ps1`, `Check-Masking.ps1`).
- [ ] The undo record is written before the first write (provisional, cleaned up after the run), keeps the first value found per target and is never replaced by a later run. Undo reads it typed, checks it against the catalog of allowed targets and checks that the current value is still the one AVDTune set (#100, #102 open; model: the provisional record in `AVDTune.Masking.psm1`).
- [ ] One owner per registry value (and per file or setting): two pages never set and undo the same value, two entries of one page never target the same value. A record is written only when something changed (#101, #104 N7 open; no check yet).
- [ ] The finish gate knows every leftover: whatever a run can leave behind (journal, undo or restore file, scheduled task, temp or work folder, throwaway user, interrupted setup, open session) is a red readiness item with a fix and a reason in `Test-AVDTuneFinishGate`. A feature that can leave something adds both in the same commit (#84, #97, #98, #99, #103 open; `Check-Finish.ps1`).
- [ ] A repair that runs by itself (page load, start) is a writer like any other: gate, Sealed check, marker, `LastChange`, change log (#103 open).

## Input and data
- [ ] Regex with a timeout and length limit; JSON/XML parsed with types checked (`"false"` is not `$false`), XML without DTD and resolver.
- [ ] A regex that validates a whole value starts with `\A` and ends with `\z`, never `$`: `$` also matches before a final line break. Digits as `[0-9]`, not `\d` (`\d` matches every Unicode digit). (#108 N6; `Check-Benchmark.ps1` "run id", "stand-alone package".)
- [ ] Names, SIDs, hashes and keys of allow lists are compared case-sensitive where the value is exact (`-ceq`, `-cmatch`, `-cnotcontains`, `[StringComparison]::Ordinal`): PowerShell's `-eq`, `-contains`, `-match` and hashtable keys ignore case. Where Windows ignores case (paths, host names), normalise once and say so.
- [ ] IDs from real services are not what fakes invent: a Graph drive ID starts with `b!`. A validator for IDs or URLs gets a counter-test with a realistic value (#95 open).
- [ ] Anything read from a file, Azure or a user is data, never code; no command line is built from it.
- [ ] Public repo: no customer names, hosts, tenant or object IDs, private IPs outside tests (`Tests\Check-PublicContent.ps1`).

## Tests
- [ ] Every point above that the change touches has a counter-test that fails without the fix.
- [ ] Fakes behave like the real service where we learned the difference (e.g. Graph filters).
- [ ] Every switch of a fake has a check that uses it.
- [ ] Expectations of the GUI smoke (counts, texts) are adjusted with the change, even if the smoke runs later.
- [ ] Fakes are shared by runspaces: the factory returns its object through `ConvertTo-AVDTuneFakeShared` (`TestsFakesFakeShared.ps1`), no member is a closure bound to the runspace that made it; a new factory is named `New-AVDTuneFake*` so the check finds it (#80, #94; `Check-AVDTune.ps1` "fakes (#80)").
- [ ] A fake fails with a clear message, never with a null call, and uses realistic values (IDs like `b!...`, wrapped error answers, paging).
- [ ] Checks run on a machine outside a domain and in an elevated process (the CI runner) as well as unelevated on a domain member: no SDDL domain aliases (DU, DA, DD), no `Join-Path` on a drive that may not exist, no assumption about the own rights or the HKLM Path (#82; `.github/workflows/checks.yml`).
- [ ] Checks start no window, stop only the processes they started (PIDs tracked) and never use a real tenant, a real vault or the real Documents folder.
