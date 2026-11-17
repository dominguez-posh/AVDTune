# Deleting in trees others can write to (#48)

AVDTune runs elevated. Some folders it empties or removes can be written by users: `C:\Windows\Temp`, the WER report folders, the admin's own `%TEMP%` (WebView2 profiles of the sign-in), the ProgramData root, folders a tool left with rules for users. A delete by path checks "no link" and then deletes by name; between the two a user can swap a folder for a junction and turn the delete onto any file. So every delete in such a tree goes through `Remove-AVDTuneTreeSafe` (`Modules\AVDTune.psm1`, C# `AVDTune.Native.SafeTree`), also behind `Remove-AVDTuneFolderNoFollow`, `Remove-AVDTuneTreeNoFollow` and `Clear-AVDTuneFolderContents`.

How it works:
- The root is opened once with `FILE_OPEN_REPARSE_POINT`; `GetFinalPathNameByHandle` must give the same long path, so a link further up refuses the call.
- Every entry is opened relative to the handle of its folder (`NtCreateFile` with `RootDirectory`, one name, `FILE_OPEN_REPARSE_POINT`, `FILE_COMPLETE_IF_OPLOCKED`). Kind, link and link count come from the opened handle; children are listed through the handle.
- The delete goes through the same handle: `FileDispositionInfoEx` with POSIX semantics and "ignore read-only", so no attribute is changed.
- A link is removed itself and never entered. A folder being deleted is held without `FILE_SHARE_DELETE`.
- Limits: 256 levels and 200 000 entries per folder (the rest is left and counted); an entry in use or under someone's oplock is left and counted, nothing waits for it.

Known gap of the fallback without POSIX delete (older Windows, file systems without it): a read-only file is deleted only after its mark is removed, and only when it has exactly one link (otherwise it is skipped). The link count is read when the file is opened; a hard link added after that is not seen. Adding a hard link needs write access to that very file, so the cleared mark then reaches only a file its creator could change anyway. With POSIX delete (Windows 10 1809 and later on NTFS, which is every AVD master) no attribute is changed at all.

While a restart is waiting (servicing, Windows Update or pending file renames, the same signs as the healthcheck item `hy.reboot`), "Abschliessen" does not empty `C:\Windows\Temp`: the renames of an installer often take their source from there at the restart. The result says so.

Checks: `Tests\Check-SafeDelete.ps1` (swaps between listing, opening and deleting, a red test against the old path variant, in use, oplock, deep trees, limits, the fallback), `Tests\Check-Finish.ps1` (restart waiting).
