<#
    AVDTune "Abschliessen" (docs\plans\avdtune.md, section 7a, issues #36 and #9): the last step of an image version. The master is NOT sysprepped; the
    imaging tool makes the image afterwards.

    What it does, in this order, every step through Invoke-AVDTuneStep (write gate, Test before and after, run record, change log, LastChange):
      finish.temp          contents of C:\Windows\Temp
      finish.wer           Windows Error Reporting queue and archive
      finish.wu-cache      Windows Update download cache (SoftwareDistribution\Download); Windows Update and BITS are stopped for it
      finish.diskspd       the downloaded diskspd of the benchmark (tools\diskspd)
      finish.block         update block on and no maintenance mode left (the end state)
      finish.tokens        tokens, refresh token and the temporary profiles of the sign-in window removed and proved; no token pattern in AVDTune's own files
      finish.version       the image version is closed in state.json (Sealed, Finished)
    Cleanup removes contents only, never follows a link (a junction in a folder that users can write to is removed itself, not its target), and a file in
    use stays and is counted ("n left, in use"), it does not fail the finish.

    The gate (Test-AVDTuneFinishGate) is evaluated directly before the first write: by the window on the UI thread when the button is pressed, and again by
    Invoke-AVDTuneFinish before the journal is written. It needs the open write gate, a current healthcheck of THIS version (the run record behind it
    exists and says the same), no red item, every yellow item confirmed by name, no change of the master after the check (Get-AVDTuneFinishReadiness),
    no interrupted maintenance mode or finish, and a version that is not finished yet.

    Journal and crash: before the first step state.json gets "Finish" (Active, Phase, Steps done, Lifted). A step that lifts a protection (stops Windows
    Update and BITS to clear the cache) writes what it lifts BEFORE it lifts it and puts it back in a finally block; the finish puts back anything still
    open in its own finally block. A record that is still Active at the next start means AVDTune was closed or stopped in the middle:
    Get-AVDTuneFinishCrash finds it, Repair-AVDTuneFinishCrash puts back what was lifted (through steps, write gate) and closes the record.

    Every access to the machine goes through the machine adapter of AVDTune.psm1 and the finish adapter $Fin of this file (New-AVDTuneFinishAdapter is the
    real one, Tests\Fakes\FakeFinish.ps1 the fake). No secret is ever written: the token scan reports file names only.
#>

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'AVDTune.psm1')
Import-Module (Join-Path $PSScriptRoot 'AVDTune.Trust.psm1')
Import-Module (Join-Path $PSScriptRoot 'AVDTune.Session.psm1')
Import-Module (Join-Path $PSScriptRoot 'AVDTune.UpdateBlock.psm1')
Import-Module (Join-Path $PSScriptRoot 'AVDTune.Readiness.psm1')

# Services stopped while the Windows Update cache is cleared (restored in finally, journal for a crash)
$script:LiftServices = @('wuauserv', 'bits')
$script:TokenPatterns = @(
    'eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}'
    '"(access_token|refresh_token|id_token)"\s*:\s*"[^"]{12,}"'
    # escaped JSON (a JSON text inside a JSON string: refresh_token\":\"...) and form encoding (refresh_token=...)
    '(access_token|refresh_token|id_token)\\?"?\s*[:=]\s*\\?"?[A-Za-z0-9._+/=-]{20,}'
    # Microsoft tokens by their prefix (0.A... / 1.A...), long
    '(?<![A-Za-z0-9._-])[01]\.A[A-Za-z0-9._-]{100,}'
)
# Limits: per file and in time, never a total count (a state folder with many run records must not block the finish for ever)
$script:ScanMaxBytes = 4MB
$script:ScanMaxSeconds = 600

#region real adapter

function Test-AVDTuneNoLinkChain {
    # True when the folder and every parent folder up to the drive root are no links (junction, symlink)
    param([Parameter(Mandatory)][string]$Folder)
    $dir = New-Object IO.DirectoryInfo $Folder
    while ($dir) {
        if ($dir.Exists -and ($dir.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
        $dir = $dir.Parent
    }
    $true
}

if (-not ('AVDTune.Native.FileLinks' -as [type])) {
    Add-Type -Namespace 'AVDTune.Native' -Name 'FileLinks' -MemberDefinition @"
[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
public struct BY_HANDLE_FILE_INFORMATION { public uint FileAttributes; public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime; public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime; public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime; public uint VolumeSerialNumber; public uint FileSizeHigh; public uint FileSizeLow; public uint NumberOfLinks; public uint FileIndexHigh; public uint FileIndexLow; }
[System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)] public static extern Microsoft.Win32.SafeHandles.SafeFileHandle CreateFileW(string name, uint access, uint share, System.IntPtr security, uint disposition, uint flags, System.IntPtr template);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)] public static extern bool GetFileInformationByHandle(Microsoft.Win32.SafeHandles.SafeFileHandle handle, out BY_HANDLE_FILE_INFORMATION info);
[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
public struct FILE_BASIC_INFO { public long CreationTime; public long LastAccessTime; public long LastWriteTime; public long ChangeTime; public uint FileAttributes; public uint Padding; }
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)] public static extern bool SetFileInformationByHandle(Microsoft.Win32.SafeHandles.SafeFileHandle handle, int infoClass, ref FILE_BASIC_INFO info, uint size);
"@
}

function Get-AVDTuneFileLinkCount {
    <# Number of hard links of a file (1 = only this name), $null when it cannot be read. Opens the link itself (no follow), no access to the content. #>
    param([Parameter(Mandatory)][string]$Path)
    # FILE_READ_ATTRIBUTES, share all, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT
    $h = [AVDTune.Native.FileLinks]::CreateFileW('\\?\' + $Path, 0x80, 7, [IntPtr]::Zero, 3, 0x00200000, [IntPtr]::Zero)
    try {
        if ($h.IsInvalid) { return $null }
        $info = New-Object AVDTune.Native.FileLinks+BY_HANDLE_FILE_INFORMATION
        if (-not [AVDTune.Native.FileLinks]::GetFileInformationByHandle($h, [ref]$info)) { return $null }
        [int]$info.NumberOfLinks
    }
    finally { $h.Dispose() }
}

function Clear-AVDTuneReadOnlyMark {
    <#
        Removes the read-only mark of a file through ONE handle: the handle that proves "exactly one link, no reparse point" is the handle that sets the
        attribute (SetFileInformationByHandle, FileBasicInfo), so no other name and no replaced path can be hit in between. Times are left alone (0 = unchanged).
        Returns 'Cleared', 'NotSingle' (more than one link, or a reparse point) or 'Failed' (cannot be opened, read or written).
    #>
    param([Parameter(Mandatory)][string]$Path)
    # FILE_READ_ATTRIBUTES | FILE_WRITE_ATTRIBUTES, share all, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT
    $h = [AVDTune.Native.FileLinks]::CreateFileW('\\?\' + $Path, 0x180, 7, [IntPtr]::Zero, 3, 0x00200000, [IntPtr]::Zero)
    try {
        if ($h.IsInvalid) { return 'Failed' }
        $info = New-Object AVDTune.Native.FileLinks+BY_HANDLE_FILE_INFORMATION
        if (-not [AVDTune.Native.FileLinks]::GetFileInformationByHandle($h, [ref]$info)) { return 'Failed' }
        if ($info.NumberOfLinks -ne 1 -or ($info.FileAttributes -band 0x400) -ne 0) { return 'NotSingle' }
        $basic = New-Object AVDTune.Native.FileLinks+FILE_BASIC_INFO
        $attr = [uint32]($info.FileAttributes -band (-bnot 0x1))
        if ($attr -eq 0) { $attr = 0x80 }
        $basic.FileAttributes = $attr
        if (-not [AVDTune.Native.FileLinks]::SetFileInformationByHandle($h, 0, [ref]$basic, [uint32][Runtime.InteropServices.Marshal]::SizeOf([type]'AVDTune.Native.FileLinks+FILE_BASIC_INFO'))) { return 'Failed' }
        'Cleared'
    }
    finally { $h.Dispose() }
}

function Clear-AVDTuneFolderContents {
    <#
        Removes what is IN the folder (the folder stays), the whole tree, through handles (Remove-AVDTuneTreeSafe -ContentsOnly, #48): the folders
        users can write to (C:\Windows\Temp, WER) are safe to clear in depth, a folder swapped for a junction during the delete is removed as a link and
        never followed. A link is removed itself. A read-only file is deleted without changing its mark (POSIX delete ignores it, so a hard link elsewhere
        keeps it); only without POSIX delete is the mark removed, from a file with exactly one link, and a read-only file with more links is Skipped.
        An entry in use is counted as Left. Removed/Left count the entries directly in the folder.
    #>
    param([Parameter(Mandatory)][string]$Folder)
    $dir = New-Object IO.DirectoryInfo $Folder
    if (-not $dir.Exists) { return [pscustomobject]@{ Removed = 0; Left = 0; Skipped = 0 } }
    if ($dir.FullName.TrimEnd([char]92).Length -le 3) { throw 'A drive root is never cleared.' }
    if (-not (Test-AVDTuneNoLinkChain -Folder $dir.FullName)) { throw "The path $Folder contains a link: nothing is deleted." }
    $r = Remove-AVDTuneTreeSafe -Path $dir.FullName -ContentsOnly   # checks the path again on the open handle (a link swapped in after the check above)
    [pscustomobject]@{ Removed = $r.Removed; Left = $r.Left; Skipped = $r.Skipped }
}
function Find-AVDTuneTokenFiles {
    <#
        Files below $Root (no links followed) with a token pattern. EVERY file is scanned, whatever its extension (a binary file is read as bytes and
        goes through the same rules). Returns relative names only, never content. Limits: per file (larger than ScanMaxBytes: named with its own text) and
        in time (-MaxSeconds: the scan stops and says so); there is NO limit on the number of files. A file that cannot be read, a file that is too large
        and a stopped scan count as a hit (fail closed), each with its own text. The scan stops at the first pattern that hits in a file. Files are read
        through a buffered FileStream (never more than ScanMaxBytes in memory). -Progress gets (text) about every 250 files. Only $Root is scanned (the state folder),
        not export locations the administrator chose himself.
    #>
    param([Parameter(Mandatory)][string]$Root, [double]$MaxSeconds = $script:ScanMaxSeconds, [scriptblock]$Progress)
    $found = New-Object System.Collections.ArrayList
    if (-not (Test-Path -LiteralPath $Root)) { return @() }
    $opts = [Text.RegularExpressions.RegexOptions]::Compiled
    $rx = [Text.RegularExpressions.Regex[]]@($script:TokenPatterns | ForEach-Object { New-Object Text.RegularExpressions.Regex($_, $opts, [TimeSpan]::FromSeconds(5)) })
    $rootInfo = New-Object IO.DirectoryInfo $Root
    $prefixLen = $rootInfo.FullName.TrimEnd([char]92).Length + 1
    $stack = New-Object System.Collections.Stack
    $stack.Push($rootInfo)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $maxMb = [int]($script:ScanMaxBytes / 1MB)
    $latin = [Text.Encoding]::GetEncoding(28591)
    $buffer = New-Object byte[] ($script:ScanMaxBytes + 4)
    $count = 0
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        foreach ($item in $dir.GetFileSystemInfos()) {
            if ($clock.Elapsed.TotalSeconds -ge $MaxSeconds) { [void]$found.Add("(scan stopped: time limit of $([int]$MaxSeconds) s reached, not every file was checked)"); return @($found) }
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            if ($item -is [IO.DirectoryInfo]) { $stack.Push($item); continue }
            $rel = $item.FullName.Substring($prefixLen)
            $count++
            if ($Progress -and ($count % 250) -eq 0) { & $Progress "Checking files for tokens: $count checked" }
            if ($item.Length -gt $script:ScanMaxBytes) { [void]$found.Add("$rel (not scanned: file larger than $maxMb MB)"); continue }
            try {
                $fs = New-Object IO.FileStream($item.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete), 65536)
                try {
                    $n = 0
                    while ($n -lt $buffer.Length) { $r = $fs.Read($buffer, $n, $buffer.Length - $n); if ($r -le 0) { break }; $n += $r }
                }
                finally { $fs.Dispose() }
                if ($n -gt $script:ScanMaxBytes) { [void]$found.Add("$rel (not scanned: file larger than $maxMb MB)"); continue }
                # UTF-16 text (BOM) is decoded as such, everything else byte for byte (the tokens are ASCII)
                $enc = $latin
                if ($n -ge 2 -and $buffer[0] -eq 0xFF -and $buffer[1] -eq 0xFE) { $enc = [Text.Encoding]::Unicode }
                elseif ($n -ge 2 -and $buffer[0] -eq 0xFE -and $buffer[1] -eq 0xFF) { $enc = [Text.Encoding]::BigEndianUnicode }
                $text = $enc.GetString($buffer, 0, $n)
                foreach ($r in $rx) { if ($r.IsMatch($text)) { [void]$found.Add($rel); break } }
            }
            catch { [void]$found.Add("$rel (not scanned: could not be read or checked)") }
        }
    }
    @($found)
}
function New-AVDTuneFinishAdapter {
    <#
        The real finish adapter. CleanTargets: Id and Path of the folders whose contents are cleared. Known folders come from [Environment], never from
        environment variables or PATH.
    #>
    param([Parameter(Mandatory)][string]$Root)
    $a = [ordered]@{ Kind = 'Real' }
    $a.CleanTargets = {
        $win = [Environment]::GetFolderPath('Windows')
        $data = [Environment]::GetFolderPath('CommonApplicationData')
        @(
            [pscustomobject]@{ Id = 'temp'; Path = (Join-Path $win 'Temp') }
            [pscustomobject]@{ Id = 'wer-queue'; Path = (Join-Path $data 'Microsoft\Windows\WER\ReportQueue') }
            [pscustomobject]@{ Id = 'wer-archive'; Path = (Join-Path $data 'Microsoft\Windows\WER\ReportArchive') }
            [pscustomobject]@{ Id = 'wu-download'; Path = (Join-Path $win 'SoftwareDistribution\Download') }
        )
    }
    $a.CountItems = {
        param($Path)
        if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return 0 }
        @((New-Object IO.DirectoryInfo $Path).GetFileSystemInfos()).Count
    }
    $a.ClearFolder = { param($Path) Clear-AVDTuneFolderContents -Folder $Path }
    $a.RunningDependents = {
        # Names of the running services that depend on this one (stopping it would stop them too)
        param($Name)
        $s = Get-Service -Name $Name -ErrorAction SilentlyContinue
        if (-not $s) { return @() }
        @($s.DependentServices | Where-Object { $_.Status -ne 'Stopped' } | ForEach-Object { $_.Name })
    }
    $a.PathExists = { param($Path) Test-Path -LiteralPath $Path }
    $a.RemoveFolder = {
        param($Path)
        if (-not (Test-AVDTuneNoLinkChain -Folder (Split-Path $Path -Parent))) { throw "The path $Path has a link in it: nothing is deleted." }
        Remove-AVDTuneFolderNoFollow $Path
    }
    $a.FindTokenFiles = { param($StateRoot, $Progress) Find-AVDTuneTokenFiles -Root $StateRoot -Progress $Progress }
    [pscustomobject]$a
}

#endregion

#region journal

function Get-AVDTuneFinishRecord([string]$Root = (Get-AVDTuneRoot)) { Get-AVDTuneProp (Get-AVDTuneState $Root) 'Finish' }

function Get-AVDTuneFinishCrash {
    # The record of a finish that never ended (closed or crashed in the middle), or $null
    param([string]$Root = (Get-AVDTuneRoot))
    $r = Get-AVDTuneFinishRecord $Root
    if ($r -and (Get-AVDTuneProp $r 'Active')) { $r } else { $null }
}

function Get-AVDTuneFinishConfirmText {
    <# The text of the confirmation dialog: the version, when the healthcheck ran, and that changes made outside AVDTune are not seen by the gate. #>
    param([string]$Root = (Get-AVDTuneRoot))
    $state = Get-AVDTuneState $Root
    $rec = Get-AVDTuneReadinessRecord -Root $Root
    $when = 'at an unknown time'
    if ($rec -and $rec.At) { try { $when = 'on ' + (ConvertTo-AVDTuneFinishDate $rec.At).ToString('yyyy-MM-dd HH:mm') } catch { } }
    "Finish image version $([string]$state.ImageVersion)?`nThe last healthcheck ran $when. Changes made outside AVDTune (for example in a Bastion session, the Defender portal or by a script) are NOT detected: if you changed something there since, cancel and run the healthcheck again.`nAVDTune cleans up, puts the update block in its end state, removes every token and closes the version. You are signed out of Microsoft in AVDTune afterwards."
}

function Save-AVDTuneFinishRecord {
    param([string]$Root, $Record, [hashtable]$Extra = @{})
    $values = @{ Finish = $Record }
    foreach ($k in $Extra.Keys) { $values[$k] = $Extra[$k] }
    [void](Set-AVDTuneState -Root $Root -Values $values)
}

function New-AVDTuneFinishServiceStep {
    # "Service runs again" (the restore of a lifted protection) as a step: Test is true when it was not running before or runs now
    param([string]$Name, [bool]$WasRunning)
    $test = {
        param($m)
        $s = & $m.ServiceGet $Name
        if (-not $s) { return @{ Compliant = $true; State = 'not installed' } }
        @{ Compliant = (-not $WasRunning -or $s.Status -eq 'Running'); State = [string]$s.Status }
    }.GetNewClosure()
    $apply = { param($m) & $m.ServiceStart $Name }.GetNewClosure()
    New-AVDTuneStep -Id "finish.restore-$($Name.ToLowerInvariant())" -Section Seal -Title "Windows service $Name started again" -Why 'Stopped for the cleanup of the update cache; put back as it was.' -Test $test -Apply $apply
}

function Start-AVDTuneFinishLift {
    <#
        Writes what is lifted into the journal FIRST, then stops the services that run. Returns the names it stopped. A crash after the journal write and
        before or during the stop is repaired at the next start (a service that never stopped is simply running).
    #>
    param([Parameter(Mandatory)]$Machine, [Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string[]]$Names, $Fin)
    $record = Get-AVDTuneFinishRecord $Root
    $entries = New-Object System.Collections.ArrayList
    foreach ($n in $Names) {
        $s = & $Machine.ServiceGet $n
        if ($s -and [string]$s.Status -eq 'Running') { [void]$entries.Add([pscustomobject]@{ Name = $n; WasRunning = $true; Restored = $false }) }
    }
    if ($entries.Count -eq 0) { return @() }
    # a service with running dependents is not stopped (stopping it would stop them as well, and the journal would not know them): nothing is stopped
    if ($Fin -and $Fin.PSObject.Properties['RunningDependents']) {
        foreach ($e in $entries) {
            $dep = @(& $Fin.RunningDependents $e.Name | Where-Object { $_ -and $_ -notin $Names })
            if ($dep.Count -gt 0) { throw "The service $($e.Name) has running dependent services ($($dep -join ', ')): it is not stopped and the cache stays. Nothing was changed." }
        }
    }
    $record.Lifted = @(@($record.Lifted) | Where-Object { $_ }) + @($entries)
    $record.Phase = 'lifted'
    Save-AVDTuneFinishRecord -Root $Root -Record $record
    foreach ($e in $entries) { & $Machine.ServiceStop $e.Name }
    @($entries | ForEach-Object { $_.Name })
}

function Restore-AVDTuneFinishLift {
    <# Puts back every lifted service that is not restored yet, through steps. Returns the names that are NOT back. The record is updated either way. #>
    param([Parameter(Mandatory)]$Machine, [Parameter(Mandatory)][string]$Root)
    $record = Get-AVDTuneFinishRecord $Root
    if (-not $record) { return @() }
    $failed = New-Object System.Collections.ArrayList
    foreach ($e in @(@($record.Lifted) | Where-Object { $_ -and -not $_.Restored })) {
        $ok = $false
        try {
            $r = Invoke-AVDTuneStep -Step (New-AVDTuneFinishServiceStep -Name ([string]$e.Name) -WasRunning ([bool]$e.WasRunning)) -Machine $Machine -Mode Apply
            $ok = ($r.Status -in 'Changed', 'Unchanged')
        }
        catch { $ok = $false }
        if ($ok) { $e.Restored = $true } else { [void]$failed.Add([string]$e.Name) }
    }
    Save-AVDTuneFinishRecord -Root $Root -Record $record
    @($failed)
}

function Repair-AVDTuneFinishCrash {
    <# An earlier finish never ended: puts back what was lifted, closes the record, writes the change log entry. Needs the open write gate. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Machine, [string]$Root = (Get-AVDTuneRoot), [string]$User)
    if (-not (Test-AVDTuneWriteAllowed)) { throw 'The snapshot gate is not confirmed: AVDTune is read only until a snapshot of today is confirmed on the Overview.' }
    $record = Get-AVDTuneFinishCrash -Root $Root
    if (-not $record) { return [pscustomobject]@{ Repaired = $false; Failed = @(); Message = 'No interrupted finish.' } }
    $changeOwner = Start-AVDTuneChange -Root $Root   # marker and LastChange through the central helpers (#27)
    try {
    $failed = @(Restore-AVDTuneFinishLift -Machine $Machine -Root $Root)
    $record = Get-AVDTuneFinishRecord $Root
    $ok = ($failed.Count -eq 0)
    $record.Ended = (& $Machine.Now).ToString('o')
    if ($ok) { $record.Active = $false; $record.Phase = 'repaired'; $record.Result = 'Interrupted finish repaired: what was stopped runs again.' }
    else { $record.Phase = 'repair-failed'; $record.Result = 'Not back: ' + ($failed -join ', ') }
    Save-AVDTuneFinishRecord -Root $Root -Record $record
    }
    finally { Stop-AVDTuneChange -Root $Root -Owner $changeOwner }
    $message = "The finish of $($record.Started) (by $($record.User)) did not end properly: AVDTune was closed or stopped in the middle. " + $(if ($ok) { 'What it had stopped runs again (a restart of the master starts the services as well). The version is NOT finished: run the finish again.' } else { 'NOT everything could be put back: ' + ($failed -join ', ') })
    $state = Get-AVDTuneState $Root
    if ($state.ImageVersion) { [void](Add-AVDTuneChangeLogEntry -Root $Root -Version ([string]$state.ImageVersion) -Category 'Finish' -Component 'Finish' -ChangeType Changed -Text $message -User $User -Source Step) }
    [pscustomobject]@{ Repaired = $ok; Failed = @($failed); Message = $message }
}

#endregion

#region gate

function ConvertTo-AVDTuneFinishDate($Value) { [datetime]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) }

function Test-AVDTuneFinishGate {
    <#
        Is the finish allowed RIGHT NOW? Reads everything fresh (state.json, run records, change log): call it directly before the first write.
        Allowed + Reasons (why not) + Notes (what does not block but should be read).
    #>
    [CmdletBinding()]
    param([string]$Root = (Get-AVDTuneRoot))
    $reasons = New-Object System.Collections.ArrayList
    $notes = New-Object System.Collections.ArrayList
    $runId = ''
    if (-not (Test-AVDTuneWriteAllowed)) { [void]$reasons.Add('The snapshot gate is not confirmed: AVDTune is read only until a snapshot of today is confirmed on the Overview.') }
    $state = Get-AVDTuneState $Root
    $version = [string](Get-AVDTuneProp $state 'ImageVersion')
    if (-not $version) { [void]$reasons.Add('No image version is started.') }
    elseif ([bool](Get-AVDTuneProp $state 'Sealed')) { [void]$reasons.Add("Image version $version is already finished. Start a new version for further changes.") }
    if (Get-AVDTuneFinishCrash -Root $Root) { [void]$reasons.Add('An earlier finish did not end properly: repair it first.') }
    if (Get-AVDTuneMaintenanceCrash -Root $Root) { [void]$reasons.Add('An earlier maintenance mode did not end properly: repair the update block first.') }
    $ready = Get-AVDTuneFinishReadiness -Root $Root
    foreach ($r in @($ready.Reasons)) { [void]$reasons.Add([string]$r) }
    $rec = Get-AVDTuneReadinessRecord -Root $Root
    if ($rec) { $runId = [string]$rec.RunId }
    if ($rec -and $version) {
        # the healthcheck must be a run of THIS version, and the append-only run record behind it must say the same
        $at = $null; try { $at = ConvertTo-AVDTuneFinishDate $rec.At } catch { }
        $started = $null
        foreach ($v in @(@($state.Versions) | Where-Object { $_ -and [string]$_.Version -eq $version })) { try { $started = ConvertTo-AVDTuneFinishDate $v.Started } catch { } }
        # AVDTune's own last change (state.json, run records, change log; a snapshot confirmation, an analysis and a benchmark are no change) must not be newer than the check
        $lc = Get-AVDTuneLastChange -Root $Root
        if ($lc -and $at -and $lc.ToUniversalTime() -gt $at.ToUniversalTime() -and -not (@($ready.Reasons) -like '*changed after the check*')) { [void]$reasons.Add("AVDTune changed the master after the check (last change $($lc.ToString('yyyy-MM-dd HH:mm:ss'))): run the analysis again.") }
        if ($at -and $started -and $at.ToUniversalTime() -lt $started.ToUniversalTime()) { [void]$reasons.Add("The healthcheck is from before image version $version was started: run the analysis again.") }
        $run = @(Get-AVDTuneRun -Root $Root -Id ([string]$rec.RunId) | Where-Object { $_ })
        if ($run.Count -eq 0) { [void]$reasons.Add('The run record of the healthcheck is missing: run the analysis again.') }
        elseif ([string](Get-AVDTuneProp $run[0] 'Overall') -ne [string]$rec.Overall) { [void]$reasons.Add('The healthcheck record does not match its run record: run the analysis again.') }
        elseif ([string](Get-AVDTuneProp $run[0] 'ImageVersion') -ne $version) { [void]$reasons.Add("The healthcheck belongs to another image version: run the analysis again.") }
    }
    if ($version -and -not (Get-AVDTuneProp $state 'LastBenchmark')) { [void]$notes.Add('No benchmark is recorded yet (plan 7a asks for the benchmark of the version).') }
    [pscustomobject]@{ Allowed = ($reasons.Count -eq 0); Reasons = @($reasons); Notes = @($notes); Version = $version; RunId = $runId }
}

#endregion

function Test-AVDTuneFinishBinding {
    <#
        The parts of the gate that can still be checked from the files while the finish runs (called directly before the version is closed): the version and
        the healthcheck are the ones of the gate at the start, no new healthcheck (a red one saved during the run), no red item, every open item confirmed.
        Returns the reasons (empty = fine). The change log is NOT looked at here: the steps of the finish write their own entries.
    #>
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Version, [Parameter(Mandatory)][string]$RunId)
    $reasons = New-Object System.Collections.ArrayList
    if (-not (Test-AVDTuneWriteAllowed)) { [void]$reasons.Add('The snapshot gate is not open any more.') }
    $state = Get-AVDTuneState $Root
    if ([string](Get-AVDTuneProp $state 'ImageVersion') -ne $Version) { [void]$reasons.Add("The image version changed during the finish (it started with $Version, it is $([string](Get-AVDTuneProp $state 'ImageVersion')) now).") }
    if ([bool](Get-AVDTuneProp $state 'Sealed')) { [void]$reasons.Add('The version is already marked finished.') }
    $rec = Get-AVDTuneReadinessRecord -Root $Root
    if (-not $rec) { [void]$reasons.Add('The healthcheck record is gone.') }
    else {
        if ([string]$rec.RunId -ne $RunId) { [void]$reasons.Add("A new analysis was saved during the finish (run $([string]$rec.RunId), the finish started with run $RunId): run the finish again.") }
        if ([int]$rec.Red -gt 0) { [void]$reasons.Add("$([int]$rec.Red) red item(s) now: $(@($rec.RedIds) -join ', ').") }
        $open = @(@($rec.OpenIds) | Where-Object { $_ -notin @($rec.Acknowledged) })
        if ($open.Count -gt 0) { [void]$reasons.Add("Open items are not confirmed: $($open -join ', ').") }
    }
    @($reasons)
}

#region steps

function Get-AVDTuneFinishSteps {
    <#
        The steps in order, as @{ Step; Lifts } entries. $Fin is the finish adapter, $Machine the machine adapter. Step ids are finish.<name>.
        -SessionProvider returns the CURRENT sign-in session of the window each time it is called (a sign-in during the run replaces the session object);
        -Session is a fixed one for callers without a window ($null and no provider: nothing to remove in memory).
        -Bind (Version, RunId): the image version and the healthcheck run of the gate at the start; finish.version closes exactly this version and only while
        the files still show that healthcheck. -Report collects what the cleanup skipped. -Progress gets (text) while the token scan runs (many files take minutes).
    #>
    param(
        [Parameter(Mandatory)]$Machine, [Parameter(Mandatory)]$Fin, [Parameter(Mandatory)][string]$Root, $Session, [scriptblock]$SessionProvider, [string]$User, [string]$SnapshotId,
        [hashtable]$Bind, [hashtable]$Report = @{ Skipped = 0; Left = 0 }, [scriptblock]$Progress
    )
    $getSession = { if ($SessionProvider) { & $SessionProvider } else { $Session } }.GetNewClosure()
    $session0 = & $getSession
    if (-not $Bind) { $s0 = Get-AVDTuneState $Root; $rc = Get-AVDTuneReadinessRecord -Root $Root; $Bind = @{ Version = [string]$s0.ImageVersion; RunId = $(if ($rc) { [string]$rc.RunId } else { '' }) } }
    $steps = New-Object System.Collections.ArrayList
    $targets = @(& $Fin.CleanTargets)
    $attempted = @{}
    $liftNames = @($script:LiftServices)
    $groups = @(
        @{ Id = 'finish.temp'; Ids = @('temp'); Title = 'Windows temp folder emptied'; Why = 'Leftovers of the changes (installers, logs of setups) must not be in the image. Only the contents are removed; a file in use stays; a link is removed itself, never followed.' }
        @{ Id = 'finish.wer'; Ids = @('wer-queue', 'wer-archive'); Title = 'Windows error reports removed'; Why = 'Crash reports of this master are of no use on the session hosts.' }
    )
    foreach ($g in $groups) {
        $tgts = @($targets | Where-Object { $_.Id -in $g.Ids })
        $paths = @($tgts | ForEach-Object { $_.Path })
        $key = $g.Id
        $test = {
            param($m)
            $n = 0; foreach ($p in $paths) { $n += [int](& $Fin.CountItems $p) }
            @{ Compliant = ($n -eq 0 -or [bool]$attempted[$key]); State = "$n item(s)" }
        }.GetNewClosure()
        $apply = {
            param($m)
            foreach ($x in $tgts) { $r = & $Fin.ClearFolder $x.Path; $Report.Skipped += [int]$r.Skipped; $Report.Left += [int]$r.Left }
            $attempted[$key] = $true
        }.GetNewClosure()
        [void]$steps.Add([pscustomobject]@{ Step = (New-AVDTuneStep -Id $g.Id -Section Seal -Title $g.Title -Why $g.Why -Test $test -Apply $apply); Lifts = $false })
    }
    # Windows Update cache: needs the services stopped (a protection that is lifted: journal first, restored in finally)
    $wuPath = @($targets | Where-Object { $_.Id -eq 'wu-download' } | ForEach-Object { $_.Path })[0]
    $wuTest = { param($m) $n = [int](& $Fin.CountItems $wuPath); @{ Compliant = ($n -eq 0 -or [bool]$attempted['wu']); State = "$n item(s)" } }.GetNewClosure()
    $wuApply = {
        param($m)
        $stopped = @()
        try {
            $stopped = @(Start-AVDTuneFinishLift -Machine $m -Root $Root -Names $liftNames -Fin $Fin)
            $r = & $Fin.ClearFolder $wuPath; $Report.Skipped += [int]$r.Skipped; $Report.Left += [int]$r.Left
            $attempted['wu'] = $true
        }
        finally {
            $failed = @(Restore-AVDTuneFinishLift -Machine $m -Root $Root)
            if ($failed.Count -gt 0) { throw "These services could not be started again: $($failed -join ', '). Repair it on the Overview (next start)." }
        }
    }.GetNewClosure()
    [void]$steps.Add([pscustomobject]@{ Step = (New-AVDTuneStep -Id 'finish.wu-cache' -Section Seal -Title 'Windows Update download cache emptied' -Why 'Downloaded update files are not needed in the image (they come again from Windows Update). Windows Update and BITS are stopped for it and started again at once; a crash in between is repaired at the next start.' -Risk Medium -Test $wuTest -Apply $wuApply); Lifts = $true })
    # diskspd cache of the benchmark
    $diskspd = Join-Path (Join-Path $Root 'tools') 'diskspd'
    $dTest = { param($m) $e = [bool](& $Fin.PathExists $diskspd); @{ Compliant = (-not $e); State = $(if ($e) { 'present' } else { 'absent' }) } }.GetNewClosure()
    $dApply = { param($m) & $Fin.RemoveFolder $diskspd }.GetNewClosure()
    [void]$steps.Add([pscustomobject]@{ Step = (New-AVDTuneStep -Id 'finish.diskspd' -Section Seal -Title 'Benchmark tool cache (diskspd) removed' -Why 'The downloaded diskspd is not part of the image; the benchmark downloads and checks it again when needed.' -Test $dTest -Apply $dApply); Lifts = $false })
    # end state of the update block and the maintenance mode
    $bTest = {
        param($m)
        $s = Get-AVDTuneUpdateBlockStatus $m
        $crash = [bool](Get-AVDTuneMaintenanceCrash -Root $Root)
        @{ Compliant = ($s.State -eq 'On' -and -not $crash); State = "block $($s.State)$(if ($crash) { ', maintenance mode still active' })" }
    }.GetNewClosure()
    $bApply = {
        param($m)
        if (Get-AVDTuneMaintenanceCrash -Root $Root) { throw 'The maintenance mode did not end properly: repair the update block first.' }
        [void](Set-AVDTuneUpdateBlock -Machine $m -Root $Root -Mode On -User $User -SnapshotId $SnapshotId)
    }.GetNewClosure()
    [void]$steps.Add([pscustomobject]@{ Step = (New-AVDTuneStep -Id 'finish.block' -Section Seal -Title 'Update block on, maintenance mode ended (end state)' -Why 'Users of the image must not see or run updates; the maintenance mode is only for the own run of AVDTune.' -Test $bTest -Apply $bApply); Lifts = $false })
    # tokens
    $tTest = {
        param($m)
        $cur = & $getSession
        $clear = $true; if ($cur) { $clear = [bool](Test-AVDTuneSessionClear -Session $cur) }
        $files = @(& $Fin.FindTokenFiles $Root $Progress)
        @{ Compliant = ($clear -and $files.Count -eq 0); State = "session $(if ($clear) { 'clear' } else { 'holds tokens or sign-in profiles' }); token pattern in $($files.Count) file(s)" }
    }.GetNewClosure()
    $tApply = {
        param($m)
        # files first: a finish that stops here keeps the sign-in (it is not finished)
        $files = @(& $Fin.FindTokenFiles $Root $Progress)
        if ($files.Count -gt 0) { throw "A token pattern is in AVDTune's own state files, or they could not be checked completely (content not shown): $($files -join '; '). Remove or inspect them by hand; AVDTune does not edit its records. Only the state folder is checked, not export locations you chose yourself." }
        $cur = & $getSession
        if (-not [object]::ReferenceEquals($cur, $session0)) { throw 'Sign-in state changed during the run: the token removal is not trusted. Run the finish again.' }
        if ($cur) { Disconnect-AVDTuneSession -Session $cur }
        $cur = & $getSession
        if ($cur -and -not (Test-AVDTuneSessionClear -Session $cur)) { throw 'The sign-in could not be removed completely (tokens or temporary sign-in profiles are still there).' }
    }.GetNewClosure()
    [void]$steps.Add([pscustomobject]@{ Step = (New-AVDTuneStep -Id 'finish.tokens' -Section Seal -Title 'Tokens and sign-in caches removed and checked' -Why 'No access or refresh token, no temporary sign-in profile (Microsoft cookies) and no token in AVDTune files may reach the image.' -Test $tTest -Apply $tApply); Lifts = $false })
    # close the version
    $bVersion = [string]$Bind.Version; $bRun = [string]$Bind.RunId
    $vTest = {
        param($m)
        $s = Get-AVDTuneState $Root
        $v = @(@($s.Versions) | Where-Object { $_ -and [string]$_.Version -eq $bVersion })
        $done = ([bool](Get-AVDTuneProp $s 'Sealed')) -and [string]$s.ImageVersion -eq $bVersion -and $v.Count -gt 0 -and [bool](Get-AVDTuneProp $v[0] 'Finished')
        @{ Compliant = $done; State = $(if ($done) { 'finished' } else { 'open' }) }
    }.GetNewClosure()
    $vApply = {
        param($m)
        # the parts of the gate that live in files, once more directly before the version is closed
        $reasons = @(Test-AVDTuneFinishBinding -Root $Root -Version $bVersion -RunId $bRun)
        $cur = & $getSession
        if ($cur -and -not (Test-AVDTuneSessionClear -Session $cur)) { $reasons += 'A sign-in exists again (tokens or sign-in profiles are held).' }
        if ($reasons.Count -gt 0) { throw "The version is not closed: $($reasons -join ' ')" }
        $s = Get-AVDTuneState $Root
        $now = (& $m.Now).ToString('o')
        $list = @(@($s.Versions) | Where-Object { $_ })
        foreach ($v in $list) {
            if ([string]$v.Version -eq $bVersion) {
                if ($v.PSObject.Properties['Finished']) { $v.Finished = $now } else { Add-Member -InputObject $v -NotePropertyName Finished -NotePropertyValue $now }
                if ($v.PSObject.Properties['FinishedBy']) { $v.FinishedBy = $User } else { Add-Member -InputObject $v -NotePropertyName FinishedBy -NotePropertyValue $User }
                if ($v.PSObject.Properties['HealthcheckRunId']) { $v.HealthcheckRunId = $bRun } else { Add-Member -InputObject $v -NotePropertyName HealthcheckRunId -NotePropertyValue $bRun }
            }
        }
        [void](Set-AVDTuneState -Root $Root -Values @{ Sealed = $true; Versions = $list })
    }.GetNewClosure()
    [void]$steps.Add([pscustomobject]@{ Step = (New-AVDTuneStep -Id 'finish.version' -Section Seal -Title 'Image version closed' -Why 'The version is marked finished in state.json (with the healthcheck it was finished on); the change log of the version is complete. The image is made by the imaging tool now.' -Test $vTest -Apply $vApply); Lifts = $false })
    @($steps)
}

#endregion

#region the finish

function Invoke-AVDTuneFinish {
    <#
        Runs the finish. Without -WhatIf: evaluates the gate again (throws when it is closed, nothing written), writes the journal, runs the steps
        (stops at the first failed step; a failed finish is not finished and keeps the sign-in), puts back what was lifted in finally, writes the run
        record, the change log entries and LastChange, closes the journal. Returns Status (Finished | Failed), Results, Message, Reboot. -Progress gets
        (text, percent).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Machine, [Parameter(Mandatory)]$Fin, [string]$Root = (Get-AVDTuneRoot), [string]$User, [string]$SnapshotId, $Session, [scriptblock]$SessionProvider,
        [scriptblock]$Progress, [switch]$WhatIf
    )
    $say = { param($t, $p) if ($Progress) { & $Progress $t $p } }.GetNewClosure()
    $report = @{ Skipped = 0; Left = 0 }
    $scanSay = { param($t) & $say $t 85 }.GetNewClosure()
    if ($WhatIf) {
        $entries = @(Get-AVDTuneFinishSteps -Machine $Machine -Fin $Fin -Root $Root -Session $Session -SessionProvider $SessionProvider -User $User -SnapshotId $SnapshotId -Report $report)
        $r = @($entries | ForEach-Object { Invoke-AVDTuneStep -Step $_.Step -Machine $Machine -Mode Apply -WhatIf })
        return [pscustomobject]@{ Status = 'WhatIf'; Results = $r; Message = 'Would run these steps.'; Reboot = $false; WhatIf = $true }
    }
    # directly before the first write: the gate again, from fresh files
    $gate = Test-AVDTuneFinishGate -Root $Root
    if (-not $gate.Allowed) { throw "The finish is not allowed: $($gate.Reasons -join ' ')" }
    # the steps are bound to the version and the healthcheck run that the gate has just accepted
    $version = [string]$gate.Version
    $entries = @(Get-AVDTuneFinishSteps -Machine $Machine -Fin $Fin -Root $Root -Session $Session -SessionProvider $SessionProvider -User $User -SnapshotId $SnapshotId -Bind @{ Version = $version; RunId = [string]$gate.RunId } -Report $report -Progress $scanSay)
    $started = & $Machine.Now
    $record = [pscustomobject][ordered]@{
        Active = $true; Id = ($started.ToString('yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture) + '-' + [guid]::NewGuid().ToString('N').Substring(0, 4))
        Phase = 'running'; Started = $started.ToString('o'); Ended = $null; User = $User; SnapshotId = $SnapshotId; ImageVersion = $version; HealthcheckRunId = [string]$gate.RunId
        Steps = @(); Lifted = @(); Result = ''
    }
    # marker before the first step (central helper, #27): a crash in the middle still counts as a change and is found at the next start
    $changeOwner = Start-AVDTuneChange -Root $Root -At $started
    try {
    Save-AVDTuneFinishRecord -Root $Root -Record $record
    $results = New-Object System.Collections.ArrayList
    $failed = $false; $err = ''
    try {
        $i = 0
        foreach ($e in $entries) {
            & $say $e.Step.Title ([int](100 * $i / $entries.Count))
            $r = Invoke-AVDTuneStep -Step $e.Step -Machine $Machine -Mode Apply
            [void]$results.Add($r)
            $i++
            $rec = Get-AVDTuneFinishRecord $Root
            $rec.Steps = @(@($rec.Steps) | Where-Object { $_ }) + [string]$e.Step.Id
            Save-AVDTuneFinishRecord -Root $Root -Record $rec
            if ($r.Status -eq 'Failed') { $failed = $true; break }
        }
    }
    catch { $failed = $true; $err = $_.Exception.Message }
    finally {
        # whatever happened: what is still lifted goes back
        $notBack = @(Restore-AVDTuneFinishLift -Machine $Machine -Root $Root)
        if ($notBack.Count -gt 0) { $failed = $true; $err = (($err + " Not started again: $($notBack -join ', ').").Trim()) }
    }
    $ended = & $Machine.Now
    $record = Get-AVDTuneFinishRecord $Root
    $notBackNow = @(@($record.Lifted) | Where-Object { $_ -and -not $_.Restored })
    $failedStep = @($results | Where-Object { $_.Status -eq 'Failed' })[0]
    if ($failed -and -not $err -and $failedStep) { $err = "$($failedStep.Title): $($failedStep.Message)" }
    $skipNote = if ($report.Skipped -gt 0 -or $report.Left -gt 0) { " Not removed: $($report.Skipped) item(s) skipped (read-only files with more than one link, only on a file system without POSIX delete), $($report.Left) in use." } else { '' }
    $message = if ($failed) { "The finish stopped: $err$skipNote" } else { "Image version $version is finished.$skipNote Now create the image in the imaging tool." }
    if ($notBackNow.Count -gt 0) { $record.Phase = 'restore-failed' }   # stays Active: the next start offers the repair
    else { $record.Active = $false; $record.Phase = $(if ($failed) { 'failed' } else { 'done' }) }
    $record.Ended = $ended.ToString('o'); $record.Result = $message
    $run = [pscustomobject][ordered]@{
        Id = $null; Plan = 'Finish'; Started = $started.ToString('o'); Ended = $ended.ToString('o'); User = $User; SnapshotId = $SnapshotId; WhatIf = $false
        ImageVersion = $version; Reboot = $false; Results = @($results)
    }
    [void](Add-AVDTuneRun -Root $Root -Run $run)
    Save-AVDTuneFinishRecord -Root $Root -Record $record
    foreach ($r in @($results | Where-Object { $_.Status -eq 'Changed' })) {
        [void](Add-AVDTuneChangeLogEntry -Root $Root -Version $version -Category 'Finish' -Component $r.Id -ChangeType Changed -Text $r.Title -User $User -SnapshotId $SnapshotId -RunId $run.Id -Source Step)
    }
    foreach ($r in @($results | Where-Object { $_.Status -eq 'Failed' })) {
        [void](Add-AVDTuneChangeLogEntry -Root $Root -Version $version -Category 'Finish' -Component $r.Id -ChangeType Note -Text "$($r.Title): FAILED ($($r.Message))" -User $User -SnapshotId $SnapshotId -RunId $run.Id -Source Step)
    }
    [void](Add-AVDTuneChangeLogEntry -Root $Root -Version $version -Category 'Finish' -Component 'Finish' -ChangeType Note -Text $message -User $User -SnapshotId $SnapshotId -RunId $run.Id -Source Step)
    & $say $(if ($failed) { 'Stopped' } else { 'Finished' }) 100
    [pscustomobject]@{ Status = $(if ($failed) { 'Failed' } else { 'Finished' }); Results = @($results); Message = $message; Reboot = $false; RunId = $run.Id; WhatIf = $false }
    }
    finally { Stop-AVDTuneChange -Root $Root -Owner $changeOwner }
}

#endregion

Export-ModuleMember -Function New-AVDTuneFinishAdapter, Clear-AVDTuneFolderContents, Get-AVDTuneFileLinkCount, Clear-AVDTuneReadOnlyMark, Find-AVDTuneTokenFiles, Test-AVDTuneNoLinkChain, Get-AVDTuneFinishRecord, Get-AVDTuneFinishCrash,
    Start-AVDTuneFinishLift, Restore-AVDTuneFinishLift, Test-AVDTuneFinishBinding, Get-AVDTuneFinishConfirmText, Repair-AVDTuneFinishCrash, Test-AVDTuneFinishGate, Get-AVDTuneFinishSteps, Invoke-AVDTuneFinish
