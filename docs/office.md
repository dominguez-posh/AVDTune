# Office page (phase 6, issue 35)

Microsoft 365 Apps on the Golden Master with the Office Deployment Tool (ODT). Code: `Modules\AVDTune.Office.psm1`, page `AVDTune-Office.ps1`, checks `Tests\Check-Office.ps1` with `Tests\Fakes\FakeOffice.ps1`. Language and region and the VDI components follow in their own branches of the same issue.

## What it does
- Form: channel, 32/64 bit, product, languages (including `MatchOS`), excluded apps, RemoveMSI. Fixed and not changeable: `SharedComputerLicensing = 1` and `Updates Enabled = FALSE` (multi-session needs both). Defaults are the sample of the AVD article (Monthly Enterprise, 64 bit, en-US + MatchOS, Groove/Lync/OneDrive/Teams excluded). OneDrive and Teams are installed with the VDI components.
- Preview of the exact `configuration.xml`. It is built with `XmlWriter` from validated values only (strict types, language regex with timeout, app and channel allow lists); a saved `config\office.json` that is not valid is refused (fail closed).
- Test: rows for installed state, channel, bit, product, shared activation, update setting, languages, update UI policies, Windows edition. Read only.
- Install or reconfigure, remove, undo: behind the write gate; run record, `LastChange` (also on failure), change log entry (Added/Changed/Removed, failures as Note). Undo uses the state found before the first change (`config\office-undo.json`, never overwritten, and deleted only by the call that wrote it or by a successful undo; read with types, `BeforeInstalled` must be a real boolean): remove when Office was not there, the earlier configuration when AVDTune knows it, otherwise no undo (says why). `LastChange` is set only when something is about to change, not for the early analysis exits (nothing to remove, invalid configuration).
- Remove uses `<Remove All="TRUE"/>`: it takes every Click-to-Run product off the master, not only the one of the form. The confirmation names every product found (`ProductReleaseIds`). The button is "Remove all Office products".
- Limits of Undo (shown before it runs; the button is "Back to saved configuration"): it installs the saved earlier configuration (product, channel, bit) again, so the build is the current one of the channel, not the earlier build; languages that were installed but are not in the saved configuration and Office versions that RemoveMSI removed do not come back.
- "Set update policies": the two HKLM values `hideupdatenotifications` and `hideenabledisableupdates` of the AVD article as steps with Test/Apply/Undo (earlier value kept together with its registry type; the record is read with types, `LastChange` is set before the undo attempt and also when a step fails).

## Where the ODT comes from
1. Page `https://www.microsoft.com/en-us/download/details.aspx?id=49117` (host `www.microsoft.com`, no redirect followed, size limit).
2. Escaped slashes of a JSON text on the page (`https:\/\/...`, `\u002F`) are unescaped first. Then exactly one link `https://download.microsoft.com/download/<guid>/officedeploymenttool_<build>-<build>.exe` is taken from it (every candidate on download.microsoft.com is matched against the whole pattern: https, host, default port, no user info, no query, nothing behind `.exe`); none or several = stop.
3. Download into a new folder below the protected state folder (`temp\office-<guid>`, Administrators/SYSTEM only, checked before the download), `CreateNew`, size limit, no redirect.
4. Authenticode of the package (subject O and CN `Microsoft Corporation`, issuer Microsoft code signing CA, original file name `officedeploymenttool.exe` or `officedeploymenttool_<build>-<build>.exe`, nothing more), then `/quiet /extract:<folder>`.
5. The unpacked folder `odt` is checked like the work folder (admin-only). `setup.exe` by full path in it (no link) is held open with read share only from the first check until its process has ended (nobody can write to it, delete it or rename it in between); Authenticode with exact subject, issuer, original file name `setup.exe` and the product name and file description of the ODT (its own trust key `odt-setup`, not a generic `setup.exe` in the shared list), checked again directly before the start. Started without shell, no window, in a job object (timeout ends the tree). The folder is removed at the end.

## Sources (Microsoft Learn)
- Install Office on a custom image for AVD (sample XML, update policies, multi-session products): https://learn.microsoft.com/en-us/azure/virtual-desktop/install-office-on-wvd-master-image
- Shared computer activation: https://learn.microsoft.com/en-us/microsoft-365-apps/licensing-activation/overview-shared-computer-activation
- ODT overview and configuration options: https://learn.microsoft.com/en-us/microsoft-365-apps/deploy/overview-office-deployment-tool and https://learn.microsoft.com/en-us/microsoft-365-apps/deploy/office-deployment-tool-configuration-options
- Update channels: https://learn.microsoft.com/en-us/microsoft-365-apps/updates/overview-update-channels

Read for this page: the AVD article (fetched). The other Learn pages were not reachable by the tool used (HTTP 404 on two URLs) and are linked from knowledge; their content is not relied on beyond the element names that the AVD sample shows (`Add`, `Product`, `Language`, `ExcludeApp`, `RemoveMSI`, `Updates`, `Display`, `Logging`, `Property`) plus `Remove All="TRUE"` and the channel names.

## Not verified (needs the test VM, listed as check points in #17)
- Whole real flow: page parse against the live page, download, `/extract`, `setup.exe /configure`, exit codes (0, 3010, 1641 assumed success), time needed (timeout 60 minutes).
- The package accepts `/quiet /extract:<path>` (from experience, not read on Learn this session).
- Original file name of the package (`officedeploymenttool[_<build>-<build>].exe`), of `setup.exe` (`setup.exe`) and its ProductName and FileDescription (the trust key `odt-setup` expects both to start with `Microsoft Office`: read the real values from a real ODT and pin them), and the Microsoft CA names (the same Microsoft pattern as for the other tools).
- Live format of the download page: whether the package link stands plain in the HTML or escaped in JSON (`https:\/\/`), and that exactly one package link is found.
- The job object ends the whole process tree at the timeout (`Invoke-AVDTuneChildProcess`, 60 minutes for setup.exe): try the terminate with a long `setup.exe` on the VM.
- Detection: languages from `ClickToRun\ProductReleaseIDs\<product>\<culture>` and `ProductReleaseIds`; channel from the CDN GUID (the GUIDs are those of the Overview); `EditionID = ServerRdsh` as multi-session. Marked `Verified = false` in the rows.
- That `<Remove All="TRUE"/>` removes Microsoft 365 Apps cleanly and that Undo to "not installed" leaves no registry leftovers.
- Default-user hive settings of the AVD article (`InsiderSlabBehavior`, Outlook cached mode) are not done yet: they need the default user hive loaded (open question in #35, same need as #33).
- GUI: the page is covered by the smoke only as "page shows"; the smoke was not run by the developer (rule).
