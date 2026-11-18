# Web apps (PWA): how AVDTune installs them, what is not verified

Issue 88, plan section 3a. Code: `Modules\AVDTune.WebApp.psm1` (URL rules, Edge policy list, launch, AppUserModelID of a link) and the kind `WebApp` of `Modules\AVDTune.Custom.psm1`; list and form on the Customizations page (`AVDTune-Custom.ps1`, card "Web apps"). Checks: `Tests\Check-WebApp.ps1` (fakes in `Tests\Fakes\FakeCustom.ps1`). Nothing of this has run against Edge on a VM yet.

## Why the Customizations page

A web app is a policy entry plus shortcuts with an icon and an optional App Masking rule. All of that already exists there (shortcut writer, icons from the library pinned by SHA256, "Visible for", desired-state steps with undo records, write gate, change log), so the web app is one more kind of item with its own list. It moves to the Software page as a fourth software source once PackTune has a package kind `webapp`.

## Entry and storage

`config\customizations.json` (typed, validated when saved and when read): `Name`, `StartUrl` (https only, no user info, no space, quote, backslash or non-ASCII character, at most 2048 characters), `ManifestId` (optional, https, same origin as the start URL), `AppId` (optional, the 32 letters a to p that `edge://apps` shows), `WindowMode` (`Window` or `Tab`), `Location` (`Desktop`, `StartMenu`, `Both`), `IconFile` + `IconSha256` (optional, `.ico` or `.png` from `AVDTune-Assets`, SHA256 from the manifest), `Visibility` (everyone, administrators, a group SID: App Masking for the Public Desktop shortcut).

Those fields are meant to become the manifest of a PackTune package of the kind `webapp` (icon as a file with SHA256). The store format is changed in PackTune first and then synced (follow-up).

## What Apply does

1. `HKLM\SOFTWARE\Policies\Microsoft\Edge`, value `WebAppInstallForceList` (REG_SZ, a JSON list as Microsoft documents it for Edge): the entry of the start URL is replaced in place or added at the end (`url`, `default_launch_container`, `create_desktop_shortcut: false`, `fallback_app_name`). Every other entry stays as it is, in its order. A value that is not a JSON list of entries with a `url`, or not REG_SZ, is not touched (the step fails with the reason).
2. Icon: an `.ico` is copied to `C:\ProgramData\AVDTune-Public\Icons\<sha>.ico` (read only for users) and used by the shortcut. A `.png` is only kept for `custom_icon` once that is verified; until then the shortcut shows the Edge icon.
3. Shortcuts (Public Desktop and/or Start menu, marked with the item id; a foreign shortcut of the same name is not replaced):
   - app id known (entered, or computed once the scheme is verified): `msedge_proxy.exe --profile-directory=Default --app-id=<id>` from the Edge folder under Program Files (x86) (never PATH). This starts the installed app.
   - otherwise: `msedge.exe --app=<url>` with the AppUserModelID `AVDTune.WebApp.<id>` on the shortcut (Tab: `msedge.exe <url>` without one). That window is not the installed app: the taskbar may still group it under Edge with the Edge icon, so the icon problem of plan 3a stays in this case.
4. Edge startup boost and background mode are not switched on.

Undo takes out the entry of the start URL and puts back the entry of that URL from before (if there was one). When the result is the list from before, the old value comes back exactly (same text; no value when there was none). Entries others added in between stay.

## Not verified (spike on a Windows 11 multi-session VM)

The results go into `$script:Spike` at the top of `Modules\AVDTune.WebApp.psm1` and nowhere else; `Check-WebApp.ps1` then needs its expectations adjusted.

1. That Edge reads `WebAppInstallForceList` as one REG_SZ JSON value under `HKLM\SOFTWARE\Policies\Microsoft\Edge` (Microsoft's documented form) on the multi-session build, and installs the apps for every user at the first logon, also with FSLogix profiles. (The customer script of plan 3a wrote a key with values `[string]1`, `[string]2`; such a key is left as it is.)
2. The app id scheme (`AppIdSchemeVerified`): SHA256 of the manifest id (or start URL), first 32 hex digits mapped 0-f to a-p, as in Chromium. Until then the id is entered by hand from `edge://apps`.
3. `custom_name` and `custom_icon` (`CustomName`, `CustomIcon`): whether Edge on Windows honours them, and whether `custom_icon` takes a `file:///` URL of the icon copy with its SHA256.
4. The AppUserModelID of the window of an installed app (`ProxyAumid`, with `{0}` for the app id): with it the shortcut, the pinned entry and the running window show the same icon.
5. Pinned icon, running window, Start menu and the shortcut after a logon with FSLogix, for both launch forms.
6. The IPropertyStore code that sets the AppUserModelID on a link (compiles in the check; only the real adapter uses it).

## Follow-ups (not built)

- Read the web manifest of the site and pick the largest icon, multi-size `.ico` 16 to 256 px with a taskbar preview (plan 3a).
- Import an existing list (names, URLs, base64 icons) from a script like the one in plan 3a.
- Package kind `webapp` in the PackTune store, then the Software page as the fourth source.
