#requires -Version 5.1
<#
.SYNOPSIS
    Builds a release of AVDTune from a clean checkout: AVDTune-<version>.zip and manifest.json (docs\plans\avdtune.md, section 9a).
    Run by the release workflow (.github\workflows\release.yml) on a tag, never by hand for a published release.
.DESCRIPTION
    Files: the tracked files of the checkout (git ls-files), without what only the team needs. Not in the ZIP:
        .claude/      team, agents and memory of the development team
        .github/      workflows
        Tests/        checks and fakes (they only run in the repo; the master has no use for them and every file in the ZIP is one more to verify)
        Tools/        scripts of the team (this one, the sync from PackTune)
        docs/         plans and test guides (the README stays: it carries the limit statement and the user guide)
        CLAUDE.md, .gitignore, .gitattributes
    The version comes from the file VERSION (x.y.z, or x.y.z-ea.N for early access). The ZIP is reproducible: entries sorted, fixed time stamp (commit
    time), so the same commit gives the same ZIP.
    manifest.json (Schema 1): Product, Version, Commit, Date (UTC, commit time), Prerelease, Notes, Zip {Name, Size, Sha256}, Files [{Path, Size, Sha256}]
    with forward slashes in the paths. The ZIP does not contain the manifest; the manifest lists the ZIP and every file in it.
.PARAMETER Root
    The checkout (default: the repo of this script). With git it must be clean; without git (a test tree) -Commit is required.
.PARAMETER OutDir
    Where the ZIP and manifest.json go (created, must be empty or new).
.PARAMETER ExpectTag
    Fails when the tag does not match the VERSION file (v<version>).
.PARAMETER NotesPath
    Release notes (text file). Default: the commit subjects since the last tag.
.PARAMETER BenchExe
    The measure program AVDTune.Bench.exe as built by Bench\build.ps1 (the release workflow builds it). It goes into the ZIP as Bench/bin/AVDTune.Bench.exe and its
    size and SHA256 are in the manifest twice: in Files (checked at every start of AVDTune) and as Bench {Path, Size, Sha256}, the entry AVDTune checks before every
    start of the program (issue #19).
.PARAMETER RequireBench
    Fails when -BenchExe is missing (the workflow sets it: a release without the measure program is not published).
#>
[CmdletBinding()]
param([string]$Root, [Parameter(Mandatory)][string]$OutDir, [string]$ExpectTag, [string]$NotesPath, [string]$Commit, [datetime]$CommitDate, [switch]$AllowDirty, [string]$BenchExe, [switch]$RequireBench)

$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = Split-Path $PSScriptRoot -Parent }
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$Root = (Resolve-Path -LiteralPath $Root).Path.TrimEnd('\')

$excluded = @('.claude/*', '.github/*', 'Tests/*', 'Tools/*', 'docs/*', 'CLAUDE.md', '.gitignore', '.gitattributes')
$versionPattern = '^\d+\.\d+\.\d+(-ea\.\d+)?$'

function Get-GitText([string[]]$GitArgs) {
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'   # git writes warnings to stderr; only the exit code counts
    try { $out = & git -C $Root @GitArgs 2>&1; $code = $LASTEXITCODE } finally { $ErrorActionPreference = $old }
    $text = ($out | ForEach-Object { [string]$_ }) -join "`n"
    if ($code -ne 0) { throw "git $($GitArgs -join ' ') failed: $text" }
    ($out | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] } | ForEach-Object { [string]$_ }) -join "`n"
}
function Get-Sha256([string]$Path) {
    $sha = [Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::OpenRead($Path)
    try { ([BitConverter]::ToString($sha.ComputeHash($stream)) -replace '-', '').ToLowerInvariant() } finally { $stream.Dispose(); $sha.Dispose() }
}

$versionFile = Join-Path $Root 'VERSION'
if (-not (Test-Path -LiteralPath $versionFile)) { throw 'The file VERSION is missing.' }
$version = ([IO.File]::ReadAllText($versionFile)).Trim()
if ($version -notmatch $versionPattern) { throw "VERSION '$version' is not x.y.z or x.y.z-ea.N." }
if ($ExpectTag -and $ExpectTag -ne "v$version") { throw "The tag $ExpectTag does not match VERSION $version (expected v$version)." }

$isGit = Test-Path -LiteralPath (Join-Path $Root '.git')
$notes = ''
if ($isGit) {
    if (-not $AllowDirty -and (Get-GitText @('status', '--porcelain'))) { throw 'The checkout is not clean (git status --porcelain shows changes). A release is built from a clean checkout.' }
    $Commit = (Get-GitText @('rev-parse', 'HEAD')).Trim()
    $CommitDate = [datetime]::Parse((Get-GitText @('log', '-1', '--format=%cI', 'HEAD')).Trim(), [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal)
    $listed = & git -C $Root ls-files -z
    if ($LASTEXITCODE -ne 0) { throw 'git ls-files failed.' }
    $all = @(($listed -join '') -split "`0" | Where-Object { $_ })
    if (-not $NotesPath) {
        $last = ''; try { $last = (Get-GitText @('describe', '--tags', '--abbrev=0', 'HEAD^')).Trim() } catch { }
        $range = if ($last) { "$last..HEAD" } else { 'HEAD' }
        $subjects = @((Get-GitText @('log', $range, '--no-merges', '--format=- %s', '-n', '40')) -split "`n" | Where-Object { $_ })
        $notes = $subjects -join "`n"
    }
}
else {
    if ($Commit -notmatch '^[0-9a-f]{40}$') { throw 'Without git, -Commit (40 hex characters) is required.' }
    if (-not $CommitDate) { $CommitDate = [datetime]'2026-01-01T00:00:00Z' }
    $CommitDate = $CommitDate.ToUniversalTime()
    $all = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force | ForEach-Object { $_.FullName.Substring($Root.Length + 1).Replace('\', '/') })
}
if ($NotesPath) { $notes = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $NotesPath).Path).Trim() }
if ($notes.Length -gt 8000) { $notes = $notes.Substring(0, 8000) }

$files = @($all | Where-Object { $rel = $_; -not ($excluded | Where-Object { $rel -like $_ }) } | Sort-Object { $_ } -CaseSensitive)
if ($files.Count -eq 0) { throw 'No files to release.' }

# The measure program (issue #19): built by the workflow from Bench\, never committed. Same path as in Modules\AVDTune.Release.psm1 ($script:BenchExePath).
$benchPath = 'Bench/bin/AVDTune.Bench.exe'
$extraSources = @{}
if ($RequireBench -and -not $BenchExe) { throw 'The measure program is required (-RequireBench) but -BenchExe was not given: a release without AVDTune.Bench.exe is not built.' }
if ($BenchExe) {
    $benchFull = (Resolve-Path -LiteralPath $BenchExe).Path
    $benchItem = Get-Item -LiteralPath $benchFull -Force
    if ($benchItem.PSIsContainer -or ($benchItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "-BenchExe is not a plain file: $benchFull" }
    if ($benchItem.Length -le 0 -or $benchItem.Length -gt 150MB) { throw "-BenchExe has an implausible size ($($benchItem.Length) bytes): $benchFull" }
    if (@($all | Where-Object { $_ -ieq $benchPath }).Count -gt 0) { throw "$benchPath is tracked in git; the measure program is built by the workflow and never committed." }
    $extraSources[$benchPath] = $benchFull
    $files = @(@($files) + $benchPath | Sort-Object { $_ } -CaseSensitive)
}
function Get-SourcePath([string]$Rel) { if ($extraSources.ContainsKey($Rel)) { $extraSources[$Rel] } else { Join-Path $Root $Rel.Replace('/', '\') } }
foreach ($f in $files) {
    # the same rule as AVDTune.Release.psm1 (Test-AVDTuneSafeRelativePath): the tool refuses any other path in a manifest
    if ($f -notmatch '^[A-Za-z0-9._ -]+(/[A-Za-z0-9._ -]+)*$' -or $f -match '(^|/)\.{1,2}(/|$)' -or $f -match '[. ](/|$)' -or $f -match '(?i)(^|/)(con|prn|aux|nul|com\d|lpt\d)(\.[^/]*)?(/|$)') { throw "Unsafe path in the file list: $f" }
    $full = Get-SourcePath $f
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "Listed file does not exist: $f" }
    if ((Get-Item -LiteralPath $full -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "A link is not released: $f" }
}

if (Test-Path -LiteralPath $OutDir) { if (@(Get-ChildItem -LiteralPath $OutDir -Force).Count -gt 0) { throw "OutDir $OutDir is not empty." } }
else { New-Item -ItemType Directory -Path $OutDir | Out-Null }
$zipName = "AVDTune-$version.zip"
$zipPath = Join-Path $OutDir $zipName
$stamp = [DateTimeOffset]$CommitDate
if ($stamp.Year -lt 1980) { $stamp = [DateTimeOffset]'1980-01-01T00:00:00Z' }

$entries = New-Object System.Collections.ArrayList
$zip = [IO.Compression.ZipFile]::Open($zipPath, [IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($f in $files) {
        $full = Get-SourcePath $f
        $entry = $zip.CreateEntry($f, [IO.Compression.CompressionLevel]::Optimal)
        $entry.LastWriteTime = $stamp
        # size and SHA256 of exactly the bytes that go into the ZIP (one read, no gap between copying and hashing)
        $sha = [Security.Cryptography.SHA256]::Create(); $size = [int64]0
        $in = [IO.File]::Open($full, 'Open', 'Read', 'Read'); $out = $entry.Open()
        try {
            $buffer = New-Object byte[] 81920
            while ($n = $in.Read($buffer, 0, $buffer.Length)) { $out.Write($buffer, 0, $n); [void]$sha.TransformBlock($buffer, 0, $n, $null, 0); $size += $n }
            [void]$sha.TransformFinalBlock((New-Object byte[] 0), 0, 0)
        }
        finally { $out.Dispose(); $in.Dispose() }
        [void]$entries.Add([ordered]@{ Path = $f; Size = $size; Sha256 = ([BitConverter]::ToString($sha.Hash) -replace '-', '').ToLowerInvariant() }); $sha.Dispose()
    }
}
finally { $zip.Dispose() }

$manifest = [ordered]@{
    Schema = 1; Product = 'AVDTune'; Version = $version; Commit = $Commit
    Date = $CommitDate.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
    Prerelease = $version.Contains('-'); Notes = $notes
    Zip = [ordered]@{ Name = $zipName; Size = (Get-Item -LiteralPath $zipPath).Length; Sha256 = (Get-Sha256 $zipPath) }
    Files = @($entries)
}
if ($BenchExe) {
    $be = @($entries | Where-Object { $_.Path -ceq $benchPath })[0]
    $manifest.Bench = [ordered]@{ Path = $benchPath; Size = $be.Size; Sha256 = $be.Sha256 }
}
$manifestPath = Join-Path $OutDir 'manifest.json'
[IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding $false))
[pscustomobject]@{ Version = $version; Commit = $Commit; Zip = $zipPath; Manifest = $manifestPath; Files = $files.Count; Prerelease = [bool]$manifest.Prerelease }
