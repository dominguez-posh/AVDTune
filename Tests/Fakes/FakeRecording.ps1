# A fake recording adapter (Modules\AVDTune.Recording.psm1, $R) for the checks and the GUI smoke test: the areas of a snapshot (Programs, Files, Registry, Services,
# Shortcuts) in memory, a staging folder per run, and installers whose effect is seeded per SHA256. Nothing here touches the computer it runs on.
# Dot-source this file, then: $r = New-AVDTuneFakeRecording [-Seed @{ ... }]
# Seed keys (all optional): Programs (key -> @{ DisplayName; DisplayVersion; Publisher; UninstallString; QuietUninstallString }), Files, Registry, Services, Shortcuts
# (key -> text), Effects (sha256 -> @{ ExitCode; Output; Programs; Files; Registry; Services; Shortcuts (added or changed, same shapes); Remove (keys of any area) }).
# Switches on .Store: Signature (sha256 -> @{ Status; Subject }; default Valid, CN=Example Vendor), Mismatch (sha256 -> $true: the held file does not match the pin),
# Truncate (an area name: every snapshot reports it as cut). Logged: Installs (Path, Tool, Arguments, Timeout, TempDir), Staged (open folders), Unstaged, Holds, Releases.
# The closures use language constructs only (no ForEach-Object, Where-Object, Join-Path): the GUI smoke calls them from a runspace.

function New-AVDTuneFakeRecording {
    param([hashtable]$Seed = @{})
    $areas = @('Programs', 'Files', 'Registry', 'Services', 'Shortcuts')
    $store = @{ Effects = @{}; Signature = @{}; Mismatch = @{}; Truncate = ''; Installs = (New-Object System.Collections.ArrayList); Staged = @{}; StagedSha = @{}; Unstaged = 0; Holds = 0; Releases = 0; Snapshots = 0 }
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
    $r.Unstage = { param($Folder) if ($store.Staged.ContainsKey($Folder)) { $store.Staged.Remove($Folder); $store.Unstaged++ } }.GetNewClosure()
    $r.ReadProgram = { param($Key) if ($store.Programs.ContainsKey($Key)) { $store.Programs[$Key] } else { $null } }.GetNewClosure()
    $r.FileExists = { param($Path) $store.Files.ContainsKey($Path) }.GetNewClosure()
    [pscustomobject]$r
}
