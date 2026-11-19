# A fake recording adapter (Modules\AVDTune.Recording.psm1, $R) for the checks and the GUI smoke test: the areas of a snapshot (Programs, Files, Registry, Services,
# Shortcuts) in memory, a staging folder per run, and installers whose effect is seeded per SHA256. Nothing here touches the computer it runs on.
# Dot-source this file, then: $r = New-AVDTuneFakeRecording [-Seed @{ ... }]
# Seed keys (all optional): Programs (key -> @{ DisplayName; DisplayVersion; Publisher; UninstallString; QuietUninstallString }), Files, Registry, Services, Shortcuts
# (key -> text), Tasks, Firewall, Odbc, Environment, Hosts, Fonts (key -> text, #93), Shots (@{ Bytes; Title; Process } per step image the capture 'sees'), Effects (sha256 -> @{ ExitCode; Output; Programs; Files; Registry; Services; Shortcuts (added or changed, same shapes); Remove (keys of any area) }).
# Switches on .Store: Signature (sha256 -> @{ Status; Subject }; default Valid, CN=Example Vendor), Mismatch (sha256 -> $true: the held file does not match the pin),
# Truncate (an area name: every snapshot reports it as cut), CaptureFails ($true: the capture of the step images cannot start). Logged: Installs (Path, Tool, Arguments, Timeout, TempDir), Staged (open folders), Unstaged, Holds, Releases.
# The factory ends with ConvertTo-AVDTuneFakeShared (#80): the GUI smoke calls the blocks from a background runspace.

. $(if (Get-Command Resolve-AVDTuneTestScript -ErrorAction Ignore) { $fakeShared = Resolve-AVDTuneTestScript -Path (Join-Path $PSScriptRoot 'FakeShared.ps1') -AppRoot (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent); if (-not $fakeShared) { throw 'FakeShared.ps1 is not a file below the Tests folder of this copy.' }; $fakeShared } else { Join-Path $PSScriptRoot 'FakeShared.ps1' })   # fakes that several runspaces use at once (#80), through the test script gate when the module is loaded
function New-AVDTuneFakeRecording {
    param([hashtable]$Seed = @{})
    $areas = @('Programs', 'Files', 'Registry', 'Services', 'Shortcuts', 'Tasks', 'Firewall', 'Odbc', 'Environment', 'Hosts', 'Fonts')
    $store = @{ Effects = @{}; Signature = @{}; Mismatch = @{}; Truncate = ''; Installs = (New-Object System.Collections.ArrayList); Staged = @{}; StagedSha = @{}; Unstaged = 0; Holds = 0; Releases = 0; Snapshots = 0; Shots = @(); CaptureFails = $false; Captures = 0; CaptureFolders = @{}; CapturesRemoved = 0 }
    if ($Seed.Shots) { $store.Shots = @($Seed.Shots) }
    foreach ($a in $areas) { $store[$a] = @{} }
    foreach ($a in $areas) { if ($Seed[$a]) { foreach ($k in $Seed[$a].Keys) { $v = $Seed[$a][$k]; if ($v -is [hashtable]) { $v = [pscustomobject]$v }; $store[$a][[string]$k] = $v } } }
    if ($Seed.Effects) { foreach ($k in $Seed.Effects.Keys) { $store.Effects[[string]$k] = $Seed.Effects[$k] } }
    $r = [ordered]@{ Kind = 'Fake'; Store = $store }
    $r.Snapshot = {
        param($Limits)
        $store.Snapshots++
        $s = @{ Truncated = @() }
        foreach ($a in $areas) { $s[$a] = $store[$a].Clone() }
        if ($store.Truncate) { $s.Truncated = @($store.Truncate) }
        $s
    }.GetNewClosure()
    $r.Stage = {
        param($Cached, $Name, $Sha256, $Root)
        $n = $store.Staged.Count + $store.Unstaged + 1
        $folder = "$Root\temp\rec-fake$n"
        $path = "$folder\$Name"
        $store.Staged[$folder] = $true; $store.StagedSha[$path] = $Sha256
        @{ Path = $path; Folder = $folder; TempDir = "$folder\tmp" }
    }.GetNewClosure()
    $r.Hold = {
        param($Path, $Sha256)
        if ($store.StagedSha[$Path] -ne $Sha256 -or $store.Mismatch.ContainsKey($Sha256)) { throw 'The installer does not match its pinned SHA256: not started.' }
        $store.Holds++
        $sig = if ($store.Signature.ContainsKey($Sha256)) { $store.Signature[$Sha256] } else { @{ Status = 'Valid'; Subject = 'CN=Example Vendor, O=Example Vendor' } }
        @{ Stream = $null; Signature = $sig }
    }.GetNewClosure()
    $r.Release = { param($Hold) $store.Releases++ }.GetNewClosure()
    $r.Install = {
        param($Path, $Command, $TimeoutSeconds, $TempDir)
        $sha = $store.StagedSha[$Path]
        [void]$store.Installs.Add([pscustomobject]@{ Path = $Path; Tool = $Command.Tool; Arguments = @($Command.Arguments); Timeout = $TimeoutSeconds; TempDir = $TempDir })
        $e = if ($sha -and $store.Effects.ContainsKey($sha)) { $store.Effects[$sha] } else { @{ ExitCode = 0 } }
        $code = if ($null -ne $e['ExitCode']) { [int]$e['ExitCode'] } else { 0 }
        foreach ($a in $areas) { if ($e[$a]) { foreach ($k in $e[$a].Keys) { $v = $e[$a][$k]; if ($v -is [hashtable]) { $v = [pscustomobject]$v }; $store[$a][[string]$k] = $v } } }
        foreach ($k in @($e['Remove'])) { if ($k) { foreach ($a in $areas) { $store[$a].Remove([string]$k) } } }
        [pscustomobject]@{ ExitCode = $code; Output = $(if ($e['Output']) { [string]$e['Output'] } else { "fake installer $code" }) }
    }.GetNewClosure()
    $r.Unstage = {
        param($Folder)
        if ($store.Staged.ContainsKey($Folder)) { $store.Staged.Remove($Folder); $store.Unstaged++ }
        elseif ($store.CaptureFolders.ContainsKey($Folder)) { $store.CaptureFolders.Remove($Folder); $store.CapturesRemoved++; if (Test-Path -LiteralPath $Folder) { [void](Remove-AVDTuneTreeSafe -Path $Folder) } }
    }.GetNewClosure()
    $r.StartCapture = {
        # the step images (#93): the seeded pictures (Shots) as files in a new download folder of the given state folder, like the real capture leaves them
        param($Root, $Limits, $Progress)
        if ($store.CaptureFails) { throw 'fake: the capture cannot start' }
        $store.Captures++
        $dir = New-AVDTuneDownloadFolder -Root $Root -Prefix 'shots'
        $store.CaptureFolders[$dir] = $true
        $shots = New-Object System.Collections.ArrayList; $n = 0
        foreach ($s in @($store.Shots)) {
            $n++; $path = Join-Path $dir ('shot-' + $n.ToString('000') + '.png')
            $out = New-AVDTuneAdminFile -Path $path
            try { $b = [byte[]]$s.Bytes; $out.Write($b, 0, $b.Length) } finally { $out.Dispose() }
            [void]$shots.Add(@{ Path = $path; Title = [string]$s.Title; At = '2026-11-18T10:00:00Z'; Process = [string]$s.Process })
            if ($Progress) { $Progress['Steps'] = $n }
        }
        @{ Folder = $dir; Shots = $shots.ToArray() }
    }.GetNewClosure()
    $r.StopCapture = { param($Capture) @{ Shots = @($Capture.Shots); Note = '' } }.GetNewClosure()
    $r.ReadProgram = { param($Key) if ($store.Programs.ContainsKey($Key)) { $store.Programs[$Key] } else { $null } }.GetNewClosure()
    $r.FileExists = { param($Path) $store.Files.ContainsKey($Path) }.GetNewClosure()
    ConvertTo-AVDTuneFakeShared ([pscustomobject]$r)
}
