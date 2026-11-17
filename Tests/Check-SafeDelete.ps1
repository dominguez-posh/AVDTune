#requires -Version 5.1
<#
.SYNOPSIS
    Checks the delete through handles (Remove-AVDTuneTreeSafe, AVDTune.Native.SafeTree in Modules\AVDTune.psm1, issue #48) on real folders below
    %TEMP% only: a link is removed itself and never followed, a link further up the path refuses the call, a folder swapped for a junction while the
    delete runs (test hook between listing and opening, and between opening and deleting) never redirects it, the target outside stays untouched,
    a file in use stays and is counted, deep trees and the depth limit, read-only files and hard links. A red test runs the same swap against the old
    path variant (check "no link", then delete by path) and shows that it deletes outside the tree.
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'Modules\AVDTune.psm1') -Force
Import-Module (Join-Path $repo 'Modules\AVDTune.Trust.psm1') -Force

$script:failed = 0
function Test-Check([string]$Name, [bool]$Ok, $Detail) { if ($Ok) { "PASS $Name" } else { $script:failed++; "FAIL $Name" + $(if ($null -ne $Detail) { "  -> $Detail" }) } }
function Get-ThrownText([scriptblock]$Block) { try { & $Block | Out-Null; $null } catch { $_.Exception.Message } }

$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$base = Join-Path $tempRoot ('avdtune-safedelete-' + [guid]::NewGuid().ToString('N'))
if (-not $base.StartsWith($tempRoot.TrimEnd([char]92) + [char]92, [StringComparison]::OrdinalIgnoreCase)) { throw "The test folder $base is not below %TEMP%: stopped." }   # temp folders only
New-Item -ItemType Directory -Path $base | Out-Null
$script:n = 0
function New-Case {
    # A fresh case folder below $base with a tree to delete (t) and a folder outside it (out) that must survive
    $script:n++
    $c = Join-Path $base "c$($script:n)"
    New-Item -ItemType Directory -Path (Join-Path $c 't\sub\deeper'), (Join-Path $c 'out') | Out-Null
    Set-Content -LiteralPath (Join-Path $c 't\sub\deeper\d.txt') -Value 'd'
    Set-Content -LiteralPath (Join-Path $c 't\sub\s.txt') -Value 's'
    Set-Content -LiteralPath (Join-Path $c 't\f.txt') -Value 'f'
    Set-Content -LiteralPath (Join-Path $c 'out\victim.txt') -Value 'precious'
    [pscustomobject]@{ Dir = $c; Tree = (Join-Path $c 't'); Out = (Join-Path $c 'out'); Victim = (Join-Path $c 'out\victim.txt') }
}
function Swap-Move([string]$From, [string]$To, [bool]$IsDir) {
    # The attacker's rename. Returns $true when it worked. A sharing violation that stays (some Windows builds refuse to rename the entries of a folder that is held open
    # as the delete does: the CI runner) means the swap cannot be staged, which keeps the attacker out just as well: $script:swapError says so and the check accepts it.
    for ($i = 0; ; $i++) {
        try { if ($IsDir) { [IO.Directory]::Move($From, $To) } else { [IO.File]::Move($From, $To) }; return $true }
        catch [IO.IOException] {
            if ($i -lt 4) { Start-Sleep -Milliseconds 250; continue }
            $script:swapError = ('{0:X8} {1}' -f $_.Exception.HResult, $_.Exception.Message)
            if ($_.Exception.HResult -ne -2147024864) { throw }
            return $false
        }
    }
}
$script:fsInfo = "fs=$(([IO.DriveInfo]::new([IO.Path]::GetPathRoot($base))).DriveFormat) base=$base"
function New-Junction([string]$Path, [string]$Target) { [void](New-Item -ItemType Junction -Path $Path -Value $Target) }

function Remove-OldPathVariant([string]$Folder, [scriptblock]$AfterCheck) {
    # The delete before #48 (Remove-AVDTuneFolderNoFollow): "is it a link?" by path, then list and delete by path. $AfterCheck runs between the check and
    # the listing, where an attacker with an oplock gets his moment.
    $dir = New-Object IO.DirectoryInfo $Folder
    if (-not $dir.Exists) { return }
    if (($dir.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $dir.Delete(); return }
    if ($AfterCheck) { & $AfterCheck $Folder }
    foreach ($item in $dir.GetFileSystemInfos()) {
        if ($item -is [IO.DirectoryInfo]) { Remove-OldPathVariant $item.FullName $AfterCheck }
        else { $item.Attributes = [IO.FileAttributes]::Normal; $item.Delete() }
    }
    try { $dir.Delete() } catch { }
}

[void](Remove-AVDTuneTreeSafe -Path (Join-Path $base 'not-there'))   # loads AVDTune.Native.SafeTree (the hook is set on it)
try {
    # ---------------------------------------------------------------- plain trees, links, read-only, hard links
    $c = New-Case
    New-Junction (Join-Path $c.Tree 'jout') $c.Out
    Set-Content -LiteralPath (Join-Path $c.Out 'shared.txt') -Value 'shared'; (Get-Item -LiteralPath (Join-Path $c.Out 'shared.txt')).Attributes = 'ReadOnly'
    [void](New-Item -ItemType HardLink -Path (Join-Path $c.Tree 'hard.txt') -Value (Join-Path $c.Out 'shared.txt'))
    Set-Content -LiteralPath (Join-Path $c.Tree 'ro.txt') -Value 'r'; (Get-Item -LiteralPath (Join-Path $c.Tree 'ro.txt')).Attributes = 'ReadOnly, Hidden'
    $r = Remove-AVDTuneTreeSafe -Path $c.Tree
    Test-Check 'tree: gone with its sub folders, a read-only and a hidden file, a hard link and a junction' ($r.Gone -and $r.Left -eq 0 -and -not (Test-Path -LiteralPath $c.Tree)) "$($r.Removed)/$($r.Left)/$($r.Skipped)/$($r.Gone)"
    $sharedAttr = (Get-Item -LiteralPath (Join-Path $c.Out 'shared.txt')).Attributes
    Test-Check 'tree: the junction target is untouched, the other name of the hard link is there and keeps its read-only mark' ((Test-Path -LiteralPath $c.Victim) -and ($sharedAttr -band [IO.FileAttributes]::ReadOnly) -ne 0) "$sharedAttr"

    $c = New-Case
    New-Junction (Join-Path $c.Dir 'jroot') $c.Out
    $r = Remove-AVDTuneTreeSafe -Path (Join-Path $c.Dir 'jroot')
    Test-Check 'a root that is a junction: the link alone is removed, its target is untouched' ($r.Gone -and -not (Test-Path -LiteralPath (Join-Path $c.Dir 'jroot')) -and (Test-Path -LiteralPath $c.Victim)) $null
    New-Junction (Join-Path $c.Dir 'jpath') $c.Tree
    $t = Get-ThrownText { Remove-AVDTuneTreeSafe -Path (Join-Path $c.Dir 'jpath\sub') }
    Test-Check 'a link further up the path refuses the whole call, nothing is deleted' ($t -like '*has a link in it*nothing is deleted*' -and (Test-Path -LiteralPath (Join-Path $c.Tree 'sub\deeper\d.txt'))) $t
    $t = Get-ThrownText { Remove-AVDTuneTreeSafe -Path (Join-Path $c.Dir 'jpath') -ContentsOnly }
    Test-Check 'contents only: a folder that is a link is refused' ($t -like '*is a link*' -and (Test-Path -LiteralPath (Join-Path $c.Tree 'f.txt'))) $t
    $t = Get-ThrownText { Remove-AVDTuneTreeSafe -Path (Join-Path $c.Tree 'f.txt') -ContentsOnly }
    Test-Check 'contents only: a file is refused' ($t -like '*is not a folder*') $t
    Test-Check 'a drive root and a device path are refused' ((Get-ThrownText { Remove-AVDTuneTreeSafe -Path ([IO.Path]::GetPathRoot($base)) }) -like '*drive root*' -and (Get-ThrownText { Remove-AVDTuneTreeSafe -Path ('\\?\' + $c.Tree) }) -like '*Device paths*') $null
    $r = Remove-AVDTuneTreeSafe -Path (Join-Path $c.Dir 'not-there')
    Test-Check 'a path that is not there: Gone, no error' ($r.Gone) $null
    $r = Remove-AVDTuneTreeSafe -Path (Join-Path $c.Tree 'f.txt')
    Test-Check 'a single file is removed' ($r.Gone -and -not (Test-Path -LiteralPath (Join-Path $c.Tree 'f.txt')) -and (Test-Path -LiteralPath (Join-Path $c.Tree 'sub\s.txt'))) $null
    $r = Remove-AVDTuneTreeSafe -Path $c.Tree -ContentsOnly
    Test-Check 'contents only: everything inside goes, the folder stays, Removed counts the direct entries' ($r.Removed -eq 1 -and $r.Left -eq 0 -and -not $r.Gone -and (Test-Path -LiteralPath $c.Tree) -and @(Get-ChildItem -LiteralPath $c.Tree -Force).Count -eq 0) "$($r.Removed)/$($r.Left)"
    $sym = Join-Path $c.Tree 'sym.txt'; $symOk = $false
    try { [void](New-Item -ItemType SymbolicLink -Path $sym -Value $c.Victim -ErrorAction Stop); $symOk = $true } catch { }
    if ($symOk) {
        $r = Remove-AVDTuneTreeSafe -Path $c.Tree
        Test-Check 'a file symlink in the tree: removed itself, the file it points to stays' ($r.Gone -and (Test-Path -LiteralPath $c.Victim) -and (Get-Content -LiteralPath $c.Victim) -eq 'precious') $null
    }
    else { 'SKIP a file symlink in the tree (this account may not create symbolic links)' }

    # ---------------------------------------------------------------- red test: the old path variant follows a swap
    $c = New-Case
    $script:swapped = $false; $script:caseErr = $null; $script:swapError = ''
    $swapSub = {
        param($Folder)
        if ($script:swapped -or (Split-Path $Folder -Leaf) -ne 'sub') { return }
        [IO.Directory]::Move($Folder, "$Folder.moved"); New-Junction $Folder $c.Out; $script:swapped = $true
    }
    Remove-OldPathVariant $c.Tree $swapSub
    Test-Check 'red: the old path variant (check by path, then delete by path) follows the folder swapped for a junction and deletes outside the tree' ($script:swapped -and -not (Test-Path -LiteralPath $c.Victim)) "swapped=$($script:swapped)"

    # the same attacker against the delete through handles: after the check the folder is held without FILE_SHARE_DELETE, the swap is refused
    $c = New-Case
    $script:swapped = $false; $script:swapError = ''; $script:stages = New-Object System.Collections.ArrayList
    [AVDTune.Native.SafeTree]::Hook = [Action[string, string]] {
        param($Stage, $Path)
        [void]$script:stages.Add("$Stage $(Split-Path $Path -Leaf)")
        if ($Stage -ne 'opened' -or $script:swapped -or (Split-Path $Path -Leaf) -ne 'sub') { return }
        try { [IO.Directory]::Move($Path, "$Path.moved"); New-Junction $Path $c.Out; $script:swapped = $true } catch { $e = $_.Exception; if ($e.InnerException) { $e = $e.InnerException }; $script:swapError = ("{0:X8} {1}" -f $e.HResult, $e.Message) }
    }
    try { $r = Remove-AVDTuneTreeSafe -Path $c.Tree } catch { $script:caseErr += " | " + $_.Exception.Message } finally { [AVDTune.Native.SafeTree]::Hook = $null }
    Test-Check 'handles, swap between opening and deleting: the held folder cannot be renamed (sharing violation), the tree is gone, the target outside is untouched' (-not $script:swapped -and $script:swapError -like "80070020*" -and $r.Gone -and (Test-Path -LiteralPath $c.Victim) -and -not (Test-Path -LiteralPath $c.Tree)) "swapped=$($script:swapped) gone=$($r.Gone) $($script:swapError)"
    Test-Check 'handles: the hook saw listing and opening in order (the root listed before its entries were opened)' ($script:stages.IndexOf('listed t') -ge 0 -and $script:stages.IndexOf('opened sub') -gt $script:stages.IndexOf('listed t')) ($script:stages -join ', ')

    # an attacker who is faster: the folder is swapped after the listing and before it is opened
    $c = New-Case
    $script:swapped = $false; $script:caseErr = $null; $script:swapError = ''
    [AVDTune.Native.SafeTree]::Hook = [Action[string, string]] {
        param($Stage, $Path)
        if ($Stage -ne 'listed' -or $script:swapped -or (Split-Path $Path -Leaf) -ne 't') { return }
        $sub = Join-Path $Path 'sub'
        if (-not (Swap-Move $sub "$sub.moved" $true)) { return }; New-Junction $sub $c.Out; $script:swapped = $true
    }
    try { $r = Remove-AVDTuneTreeSafe -Path $c.Tree } catch { $script:caseErr += " | " + $_.Exception.Message } finally { [AVDTune.Native.SafeTree]::Hook = $null }
    Test-Check 'handles, swap between listing and opening: the junction is opened itself and removed as a link, the moved folder goes too, the target is untouched' (($script:swapped -or $script:swapError -like '80070020*') -and $r.Gone -and (Test-Path -LiteralPath $c.Victim) -and -not (Test-Path -LiteralPath $c.Tree)) "swapped=$($script:swapped) gone=$($r.Gone) $($script:caseErr) [$($script:fsInfo)]"

    # a file swapped after it was opened: the opened file is deleted (wherever it is now), the junction put in its place is removed as a link
    $c = New-Case
    $script:swapped = $false; $script:caseErr = $null; $script:swapError = ''
    [AVDTune.Native.SafeTree]::Hook = [Action[string, string]] {
        param($Stage, $Path)
        if ($Stage -ne 'opened' -or $script:swapped -or (Split-Path $Path -Leaf) -ne 'f.txt') { return }
        if (-not (Swap-Move $Path "$Path.moved" $false)) { return }; New-Junction $Path $c.Out; $script:swapped = $true
    }
    try { $r = Remove-AVDTuneTreeSafe -Path $c.Tree } catch { $script:caseErr += " | " + $_.Exception.Message } finally { [AVDTune.Native.SafeTree]::Hook = $null }
    Test-Check 'handles, a file swapped for a junction after opening: the target outside is untouched, the tree is gone' (($script:swapped -or $script:swapError -like '80070020*') -and $r.Gone -and (Test-Path -LiteralPath $c.Victim) -and -not (Test-Path -LiteralPath $c.Tree)) "swapped=$($script:swapped) gone=$($r.Gone) $($script:caseErr) [$($script:fsInfo)]"

    # the wrappers the callers use take the same path
    $c = New-Case
    $script:swapped = $false; $script:caseErr = $null; $script:swapError = ''
    [AVDTune.Native.SafeTree]::Hook = [Action[string, string]] {
        param($Stage, $Path)
        if ($Stage -ne 'listed' -or $script:swapped -or (Split-Path $Path -Leaf) -ne 't') { return }
        $sub = Join-Path $Path 'sub'
        if (-not (Swap-Move $sub "$sub.moved" $true)) { return }; New-Junction $sub $c.Out; $script:swapped = $true
    }
    try { Remove-AVDTuneFolderNoFollow $c.Tree } catch { $script:caseErr += " | " + $_.Exception.Message } finally { [AVDTune.Native.SafeTree]::Hook = $null }
    Test-Check 'Remove-AVDTuneFolderNoFollow (all callers: Office, VDI, FSLogix, release, sign-in profiles, software work, benchmark) goes through the handles' (($script:swapped -or $script:swapError -like '80070020*') -and (Test-Path -LiteralPath $c.Victim) -and -not (Test-Path -LiteralPath $c.Tree)) $script:caseErr

    # ---------------------------------------------------------------- in use
    $c = New-Case
    $busy = Join-Path $c.Tree 'sub\busy.txt'; Set-Content -LiteralPath $busy -Value 'b'
    $fs = [IO.File]::Open($busy, 'Open', 'Read', 'None')
    try {
        $r = Remove-AVDTuneTreeSafe -Path $c.Tree
        $t = Get-ThrownText { Remove-AVDTuneFolderNoFollow $c.Tree }
    }
    finally { $fs.Dispose() }
    Test-Check 'a file in use: no error, it stays and is counted (Left), the others go, the tree is not Gone' (-not $r.Gone -and $r.Left -eq 1 -and (Test-Path -LiteralPath $busy) -and -not (Test-Path -LiteralPath (Join-Path $c.Tree 'f.txt')) -and -not (Test-Path -LiteralPath (Join-Path $c.Tree 'sub\deeper'))) "$($r.Removed)/$($r.Left)/$($r.Gone)"
    Test-Check 'a file in use: Remove-AVDTuneFolderNoFollow throws and says how many are left' ($t -like '*could not be removed completely*1 item(s) left*') $t
    $r = Remove-AVDTuneTreeSafe -Path $c.Tree
    Test-Check 'a file in use: after it is closed the tree goes' ($r.Gone -and -not (Test-Path -LiteralPath $c.Tree)) $null
    $c = New-Case
    $shared = Join-Path $c.Tree 'shared-open.txt'; Set-Content -LiteralPath $shared -Value 'x'
    $fs = New-Object IO.FileStream($shared, 'Open', 'Read', ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try { $r = Remove-AVDTuneTreeSafe -Path $c.Tree; $goneWhileOpen = -not (Test-Path -LiteralPath $shared) } finally { $fs.Dispose() }
    Test-Check 'a file open by someone who allows delete: removed at once (POSIX delete), the tree is gone' ($r.Gone -and $goneWhileOpen) "$($r.Left)/$($r.Gone)"

    # ---------------------------------------------------------------- deep trees and the depth limit
    $c = New-Case
    $deep = $c.Tree
    for ($i = 0; $i -lt 70; $i++) { $deep = Join-Path $deep ('level-{0:00}' -f $i) }
    [void][IO.Directory]::CreateDirectory('\\?\' + $deep)
    [IO.File]::WriteAllText('\\?\' + (Join-Path $deep 'bottom.txt'), 'b')
    Test-Check 'precondition: the deep path is longer than 260 characters' ($deep.Length -gt 600) $deep.Length
    $r = Remove-AVDTuneTreeSafe -Path $c.Tree
    Test-Check 'a tree 70 levels deep (path longer than 600 characters) is removed' ($r.Gone -and -not [IO.Directory]::Exists('\\?\' + $c.Tree)) "$($r.Left)/$($r.Gone)"
    $c = New-Case
    [AVDTune.Native.SafeTree]::MaxDepth = 1
    try { $r = Remove-AVDTuneTreeSafe -Path $c.Tree } finally { [AVDTune.Native.SafeTree]::MaxDepth = 256 }
    Test-Check 'deeper than the limit: no error, the deep part is left (no stack exhaustion by a prepared tree), the rest goes' (-not $r.Gone -and (Test-Path -LiteralPath (Join-Path $c.Tree 'sub\deeper\d.txt')) -and -not (Test-Path -LiteralPath (Join-Path $c.Tree 'f.txt'))) "$($r.Removed)/$($r.Left)"

    # ---------------------------------------------------------------- too many entries in one folder
    $c = New-Case
    $wide = Join-Path $c.Tree 'wide'; New-Item -ItemType Directory -Path $wide | Out-Null
    1..8 | ForEach-Object { [IO.File]::WriteAllText((Join-Path $wide "w$_.txt"), 'w') }
    [AVDTune.Native.SafeTree]::MaxEntries = 5
    try { $r = Remove-AVDTuneTreeSafe -Path $c.Tree } finally { [AVDTune.Native.SafeTree]::MaxEntries = 200000 }
    Test-Check 'more entries than the limit in a folder: no error, the folder is left (TooMany), what was listed goes, the rest of the tree goes' (-not $r.Gone -and $r.TooMany -ge 1 -and @(Get-ChildItem -LiteralPath $wide).Count -eq 3 -and -not (Test-Path -LiteralPath (Join-Path $c.Tree 'sub'))) "$($r.TooMany)/$($r.Left) left in wide: $(@(Get-ChildItem -LiteralPath $wide).Count)"
    $r = Remove-AVDTuneTreeSafe -Path $c.Tree
    Test-Check 'with the normal limit the same tree goes' ($r.Gone -and $r.TooMany -eq 0) $null

    # ---------------------------------------------------------------- without POSIX delete (the fallback, forced by the test switch)
    $c = New-Case
    Set-Content -LiteralPath (Join-Path $c.Tree 'ro-single.txt') -Value 'r'; (Get-Item -LiteralPath (Join-Path $c.Tree 'ro-single.txt')).Attributes = 'ReadOnly'
    Set-Content -LiteralPath (Join-Path $c.Out 'ro-shared.txt') -Value 's'; (Get-Item -LiteralPath (Join-Path $c.Out 'ro-shared.txt')).Attributes = 'ReadOnly'
    [void](New-Item -ItemType HardLink -Path (Join-Path $c.Tree 'sub\ro-hard.txt') -Value (Join-Path $c.Out 'ro-shared.txt'))
    New-Junction (Join-Path $c.Tree 'jout') $c.Out
    [AVDTune.Native.SafeTree]::TestNoPosixDelete = $true
    try { $r = Remove-AVDTuneTreeSafe -Path $c.Tree } finally { [AVDTune.Native.SafeTree]::TestNoPosixDelete = $false }
    $sharedAttr = (Get-Item -LiteralPath (Join-Path $c.Out 'ro-shared.txt')).Attributes
    Test-Check 'fallback: the read-only file with one link goes (mark cleared through a reopened handle), plain files and the junction go, the target is untouched' (-not (Test-Path -LiteralPath (Join-Path $c.Tree 'ro-single.txt')) -and -not (Test-Path -LiteralPath (Join-Path $c.Tree 'f.txt')) -and -not (Test-Path -LiteralPath (Join-Path $c.Tree 'jout')) -and (Test-Path -LiteralPath $c.Victim)) "$($r.Removed)/$($r.Left)/$($r.Skipped)"
    Test-Check 'fallback: the read-only hard link is skipped (counted), its other name keeps the mark, so its folder stays' ($r.Skipped -eq 1 -and -not $r.Gone -and (Test-Path -LiteralPath (Join-Path $c.Tree 'sub\ro-hard.txt')) -and ($sharedAttr -band [IO.FileAttributes]::ReadOnly) -ne 0) "$($r.Skipped) $sharedAttr"
    $r = Remove-AVDTuneTreeSafe -Path $c.Tree
    Test-Check 'with POSIX delete the hard link goes without touching the mark' ($r.Gone -and ((Get-Item -LiteralPath (Join-Path $c.Out 'ro-shared.txt')).Attributes -band [IO.FileAttributes]::ReadOnly) -ne 0) $null

    # ---------------------------------------------------------------- an oplock someone holds is not waited for
    if (-not ('AVDTuneTest.Oplock' -as [type])) {
        Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices; using Microsoft.Win32.SafeHandles; using System.Threading;
namespace AVDTuneTest {
    public sealed class Oplock : IDisposable {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr sec, uint disp, uint flags, IntPtr tmpl);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool DeviceIoControl(SafeFileHandle h, uint code, IntPtr inBuf, uint inSize, IntPtr outBuf, uint outSize, out uint ret, IntPtr overlapped);
        SafeFileHandle h; IntPtr ov; ManualResetEvent ev;
        public bool Granted;
        // A level 1 oplock (FSCTL_REQUEST_OPLOCK_LEVEL_1) that is never acknowledged: an open that breaks it would wait until the holder lets go
        public Oplock(string path) {
            h = CreateFileW(path, 0x80000000, 7, IntPtr.Zero, 3, 0x40000000, IntPtr.Zero);
            if (h.IsInvalid) throw new System.ComponentModel.Win32Exception();
            ev = new ManualResetEvent(false);
            ov = Marshal.AllocHGlobal(IntPtr.Size * 3 + 8);
            for (int i = 0; i < IntPtr.Size * 3 + 8; i++) Marshal.WriteByte(ov, i, 0);
            Marshal.WriteIntPtr(ov, IntPtr.Size * 2 + 8, ev.SafeWaitHandle.DangerousGetHandle());
            uint ret;
            Granted = !DeviceIoControl(h, 0x00090000, IntPtr.Zero, 0, IntPtr.Zero, 0, out ret, ov) && Marshal.GetLastWin32Error() == 997;
        }
        public void Dispose() { h.Dispose(); ev.WaitOne(2000); Marshal.FreeHGlobal(ov); ev.Dispose(); }
    }
}
'@
    }
    $c = New-Case
    $held = Join-Path $c.Tree 'held.txt'; Set-Content -LiteralPath $held -Value 'h'
    $op = New-Object AVDTuneTest.Oplock $held
    try {
        $ps = [powershell]::Create()
        [void]$ps.AddScript({ param($m, $p) Import-Module $m -Force; Remove-AVDTuneTreeSafe -Path $p }).AddArgument((Join-Path $repo 'Modules\AVDTune.psm1')).AddArgument($c.Tree)
        $ar = $ps.BeginInvoke()
        $done = $ar.AsyncWaitHandle.WaitOne(30000)
        $or = if ($done) { @($ps.EndInvoke($ar))[0] } else { $null }
    }
    finally { $op.Dispose(); if ($done) { $ps.Dispose() } else { [void]$ps.EndInvoke($ar); $ps.Dispose() } }
    Test-Check 'an entry under an oplock: the delete does not wait for the holder, the entry counts as left, the rest goes' ($op.Granted -and $done -and $or -and -not $or.Gone -and $or.Left -eq 1 -and (Test-Path -LiteralPath $held) -and -not (Test-Path -LiteralPath (Join-Path $c.Tree 'sub'))) "granted=$($op.Granted) done=$done left=$($or.Left)"
    $r = Remove-AVDTuneTreeSafe -Path $c.Tree
    Test-Check 'an entry under an oplock: after the holder let go the tree goes' ($r.Gone) $null

    # ---------------------------------------------------------------- the callers in the core module
    $c = New-Case
    New-Junction (Join-Path $c.Tree 'jout') $c.Out
    Test-Check 'Remove-AVDTuneTreeNoFollow (temp leftovers of the tools): $true and gone, the target is untouched' ((& (Get-Module AVDTune) { Remove-AVDTuneTreeNoFollow -Path $args[0] } $c.Tree) -and -not (Test-Path -LiteralPath $c.Tree) -and (Test-Path -LiteralPath $c.Victim)) $null

    # ---------------------------------------------------------------- the code itself
    $src = [IO.File]::ReadAllText((Join-Path $repo 'Modules\AVDTune.psm1'))
    Test-Check 'code: entries are opened relative to the folder handle with FILE_OPEN_REPARSE_POINT and deleted by handle (POSIX semantics, read-only ignored)' ($src -match 'oa\.RootDirectory = root == null \? IntPtr\.Zero : root\.DangerousGetHandle\(\)' -and $src -match 'OPT_OPEN_REPARSE = 0x00200000' -and $src -match 'OPT_SYNC \| OPT_OPEN_REPARSE \| OPT_COMPLETE_IF_OPLOCKED \| \(dir \?' -and $src -match 'uint flags = 0x1 \| 0x2 \| 0x10;' -and $src -match 'SetFileInformationByHandle\(h, 21, ref flags, 4\)') $null
    Test-Check 'code: a folder that is deleted is held without FILE_SHARE_DELETE' ($src -match '\(dir && withDelete\) \? \(SHARE_READ \| SHARE_WRITE\) :') $null
    Test-Check 'code: the first open asks for no FILE_WRITE_ATTRIBUTES; only the reopen of the read-only fallback does' ($src -match 'int st = OpenRaw\(root, name, READ_ATTRIBUTES \| SYNCHRONIZE \| \(withDelete' -and ([regex]::Matches($src, 'WRITE_ATTRIBUTES \| SYNCHRONIZE')).Count -eq 1 -and $src -match 'ReopenForAttributes\(SafeFileHandle h, out SafeFileHandle w\) \{\s+return OpenRaw\(h, "", READ_ATTRIBUTES \| WRITE_ATTRIBUTES') $null
    # every script of the product (modules, pages, the start script, the watermark scripts, the shared copies); Tools and Bench are developer scripts
    $mods = @(Get-ChildItem -LiteralPath (Join-Path $repo 'Modules') -Filter '*.psm1') + @(Get-ChildItem -LiteralPath $repo -Filter '*.ps1') + @(Get-ChildItem -LiteralPath (Join-Path $repo 'Watermark') -Filter '*.ps1') + @(Get-ChildItem -LiteralPath (Join-Path $repo 'Shared') -Recurse -File -Include '*.ps1', '*.psm1')
    Test-Check 'code: the scan sees Start-AVDTune.ps1, every page, the watermark scripts and the shared copies' ((@($mods | Where-Object Name -eq 'Start-AVDTune.ps1').Count -eq 1) -and @($mods | Where-Object Name -like 'AVDTune-*.ps1').Count -ge 20 -and @($mods | Where-Object Name -eq 'Show-AVDTuneWatermark.ps1').Count -eq 1) ($mods.Count)
    $recurse = @(foreach ($mf in $mods) { $i = 0; foreach ($line in [IO.File]::ReadAllLines($mf.FullName)) { $i++; if ($line -match 'Remove-Item\b[^#]*-Recurse' -and $line -notmatch '^\s*#') { "$($mf.Name):$i" } } })
    # Known, outside AVDTune's hands: the shared PackTune copy (Send-PackTuneProtocolToStore, its own temp folder; AVDTune never calls it). Shared code is
    # changed in PackTune first and synced; exactly this one line is allowed, any other or a second one fails.
    $known = @($recurse | Where-Object { $_ -like 'PackTune-Protocol.ps1:*' })
    $sharedLine = @([IO.File]::ReadAllLines((Join-Path $repo 'Shared\PackTune-Protocol.ps1')) | Where-Object { $_ -match 'Remove-Item\b[^#]*-Recurse' })
    $calls = @(foreach ($mf in $mods) { if ($mf.Name -ne 'PackTune-Protocol.ps1' -and ([IO.File]::ReadAllText($mf.FullName) -match 'Send-PackTuneProtocolToStore')) { $mf.Name } })
    Test-Check 'code: no Remove-Item -Recurse in the product scripts (it follows links; use Remove-AVDTuneTreeSafe), apart from the one known line of the shared PackTune copy that AVDTune never calls' ($recurse.Count -eq $known.Count -and $known.Count -le 1 -and ($known.Count -eq 0 -or ($sharedLine.Count -eq 1 -and $sharedLine[0] -match 'Remove-Item -LiteralPath \$Temp -Recurse')) -and $calls.Count -eq 0) "$($recurse -join ', ') / callers: $($calls -join ', ')"
}
finally {
    [AVDTune.Native.SafeTree]::Hook = $null
    if (Test-Path -LiteralPath $base) {
        foreach ($j in Get-ChildItem -LiteralPath $base -Recurse -Force -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }) { try { $j.Delete() } catch { } }
        Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
    }
}
if ($script:failed -gt 0) { throw "$script:failed check(s) failed." }
'Check-SafeDelete: all checks passed.'
