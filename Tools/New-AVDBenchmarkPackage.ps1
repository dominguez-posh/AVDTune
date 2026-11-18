#requires -Version 5.1
<#
.SYNOPSIS
    Prepares the stand-alone package of the benchmark (repo AVD-Benchmark, docs\benchmark-design.md section 7, plan 6/6b, #90): AVD-Benchmark-<version>.zip and its
    manifest.json, made from a finished AVDTune release (the output of Tools\New-AVDTuneRelease.ps1), so the package carries exactly the engine of that release.
.DESCRIPTION
    Only a preparation: the entry script of the stand-alone package (Invoke-AVDBenchmark.ps1: elevated, no sign-in, IMDS facts, result kind 'standalone') is not
    built yet, and the release workflow does not call this script yet. Both are open points of #90.
    Steps:
      1. manifest.json of the release is read with its types checked (Product AVDTune, Version x.y.z[-ea.N], Zip, Files); the ZIP must have the size and SHA256 of the manifest.
      2. Every entry of the ZIP must be listed in the manifest with a safe relative path and its SHA256 (no entry outside the list, no '..', no link).
      3. Taken: Modules/AVDTune.Benchmark.psm1 and every module it imports (Import-Module (Join-Path $PSScriptRoot '<name>.psm1'), followed through), Bench/data/*,
         Bench/bin/AVDTune.Bench.exe, LICENSE, NOTICE, VERSION. Nothing else (no window, no setup, no sign-in module).
      4. Written: AVD-Benchmark-<version>.zip (entries sorted, time stamp of the release) and manifest.json (Schema 1: Product AVD-Benchmark, Version, Source {Product,
         Version, Commit, ZipSha256}, Date, Zip {Name, Size, Sha256}, Files [{Path, Size, Sha256}]) into -OutDir (new or empty).
    diskspd is never in the package (its binary licence forbids it, design section 6); it is downloaded and checked at run time as in AVDTune.
.PARAMETER ReleaseDir
    The folder with manifest.json and AVDTune-<version>.zip of the release.
.PARAMETER OutDir
    Where the package and its manifest go (created, must be empty or new).
.PARAMETER RequireBench
    Fails when the release has no measure program (Bench/bin/AVDTune.Bench.exe).
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ReleaseDir, [Parameter(Mandatory)][string]$OutDir, [switch]$RequireBench)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$safePath = '^[A-Za-z0-9._ -]+(/[A-Za-z0-9._ -]+)*$'
function Test-SafeRelative([string]$Path) {
    # the same rule as Tools\New-AVDTuneRelease.ps1 and AVDTune.Release.psm1
    $Path -match $safePath -and $Path -notmatch '(^|/)\.{1,2}(/|$)' -and $Path -notmatch '[. ](/|$)' -and $Path -notmatch '(?i)(^|/)(con|prn|aux|nul|com\d|lpt\d)(\.[^/]*)?(/|$)'
}
function Get-StreamSha256([IO.Stream]$Stream) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($sha.ComputeHash($Stream)) -replace '-', '').ToLowerInvariant() } finally { $sha.Dispose() }
}
function Get-EntryBytes($Entry) {
    $ms = New-Object IO.MemoryStream
    $s = $Entry.Open(); try { $s.CopyTo($ms) } finally { $s.Dispose() }
    $ms.ToArray()
}

# ---- 1. the manifest of the release
$ReleaseDir = (Resolve-Path -LiteralPath $ReleaseDir).Path
$manifestPath = Join-Path $ReleaseDir 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw "No manifest.json in $ReleaseDir." }
$m = [IO.File]::ReadAllText($manifestPath).TrimStart([char]0xFEFF) | ConvertFrom-Json
if ($m.Product -isnot [string] -or $m.Product -ne 'AVDTune') { throw 'The manifest is not one of an AVDTune release.' }
if ($m.Version -isnot [string] -or $m.Version -notmatch '^\d+\.\d+\.\d+(-ea\.\d+)?$') { throw 'The version of the manifest is not x.y.z or x.y.z-ea.N.' }
if ($m.Zip.Name -isnot [string] -or $m.Zip.Name -ne "AVDTune-$($m.Version).zip") { throw 'The ZIP name of the manifest does not match its version.' }
if ($m.Zip.Sha256 -isnot [string] -or $m.Zip.Sha256 -notmatch '^[0-9a-f]{64}$') { throw 'The ZIP hash of the manifest is not a SHA256.' }
$listed = @{}
foreach ($f in @($m.Files)) {
    if ($f.Path -isnot [string] -or -not (Test-SafeRelative $f.Path)) { throw "Unsafe path in the manifest: $($f.Path)" }
    if ($f.Sha256 -isnot [string] -or $f.Sha256 -notmatch '^[0-9a-f]{64}$') { throw "No SHA256 for $($f.Path) in the manifest." }
    $listed[$f.Path] = $f.Sha256
}
$zipPath = Join-Path $ReleaseDir $m.Zip.Name
$zipItem = Get-Item -LiteralPath $zipPath -Force
if ($zipItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'The release ZIP is a link.' }
if ($zipItem.Length -ne [int64]$m.Zip.Size) { throw 'The release ZIP does not have the size of the manifest.' }
$zs = [IO.File]::Open($zipPath, 'Open', 'Read', 'Read')
try { if ((Get-StreamSha256 $zs) -ne $m.Zip.Sha256) { throw 'The release ZIP does not match the SHA256 of the manifest.' } } finally { $zs.Dispose() }

# ---- 2. every entry checked, 3. the files of the package
$content = @{}
$zip = [IO.Compression.ZipFile]::OpenRead($zipPath)
try {
    foreach ($e in $zip.Entries) {
        if ($e.FullName.EndsWith('/')) { continue }
        if (-not (Test-SafeRelative $e.FullName)) { throw "Unsafe path in the release ZIP: $($e.FullName)" }
        if (-not $listed.ContainsKey($e.FullName)) { throw "The release ZIP has a file that the manifest does not list: $($e.FullName)" }
        $bytes = Get-EntryBytes $e
        $ms = New-Object IO.MemoryStream (, $bytes)
        if ((Get-StreamSha256 $ms) -ne $listed[$e.FullName]) { throw "$($e.FullName) does not match the SHA256 of the manifest." }
        $content[$e.FullName] = $bytes
    }
}
finally { $zip.Dispose() }

$take = New-Object System.Collections.Generic.SortedSet[string] ([StringComparer]::Ordinal)
$queue = New-Object System.Collections.Queue
$queue.Enqueue('Modules/AVDTune.Benchmark.psm1')
while ($queue.Count -gt 0) {
    $mod = [string]$queue.Dequeue()
    if ($take.Contains($mod)) { continue }
    if (-not $content.ContainsKey($mod)) { throw "The release has no $mod, which the benchmark engine needs." }
    [void]$take.Add($mod)
    $text = (New-Object Text.UTF8Encoding $false).GetString($content[$mod])
    foreach ($hit in [regex]::Matches($text, "Import-Module \(Join-Path \`$PSScriptRoot '([A-Za-z0-9.]+\.psm1)'\)", [Text.RegularExpressions.RegexOptions]::None, [timespan]::FromSeconds(2))) { $queue.Enqueue('Modules/' + $hit.Groups[1].Value) }
}
foreach ($k in $content.Keys) { if ($k -like 'Bench/data/*' -or $k -eq 'Bench/bin/AVDTune.Bench.exe' -or $k -in 'LICENSE', 'NOTICE', 'VERSION') { [void]$take.Add($k) } }
if (-not $take.Contains('Bench/data/benchmark-B1.0.json')) { throw 'The release has no benchmark data (Bench/data).' }
if ($RequireBench -and -not $take.Contains('Bench/bin/AVDTune.Bench.exe')) { throw 'The release has no measure program (Bench/bin/AVDTune.Bench.exe): no package with -RequireBench.' }
if (@($take | Where-Object { $_ -match '(?i)diskspd' }).Count -gt 0) { throw 'diskspd is never put into the package (its licence forbids it).' }

# ---- 4. the package
if (Test-Path -LiteralPath $OutDir) { if (@(Get-ChildItem -LiteralPath $OutDir -Force).Count -gt 0) { throw "OutDir $OutDir is not empty." } }
else { New-Item -ItemType Directory -Path $OutDir | Out-Null }
$name = "AVD-Benchmark-$($m.Version).zip"
$outZip = Join-Path $OutDir $name
$stamp = [DateTimeOffset]::Parse([string]$m.Date, [Globalization.CultureInfo]::InvariantCulture)
if ($stamp.Year -lt 1980) { $stamp = [DateTimeOffset]'1980-01-01T00:00:00Z' }
$files = New-Object System.Collections.ArrayList
$z = [IO.Compression.ZipFile]::Open($outZip, [IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($p in $take) {
        $entry = $z.CreateEntry($p, [IO.Compression.CompressionLevel]::Optimal); $entry.LastWriteTime = $stamp
        $s = $entry.Open(); try { $s.Write($content[$p], 0, $content[$p].Length) } finally { $s.Dispose() }
        [void]$files.Add([ordered]@{ Path = $p; Size = [int64]$content[$p].Length; Sha256 = $listed[$p] })
    }
}
finally { $z.Dispose() }
$os = [IO.File]::OpenRead($outZip)
try { $zipSha = Get-StreamSha256 $os } finally { $os.Dispose() }
$manifest = [ordered]@{
    Schema = 1; Product = 'AVD-Benchmark'; Version = $m.Version
    Source = [ordered]@{ Product = 'AVDTune'; Version = $m.Version; Commit = [string]$m.Commit; ZipSha256 = $m.Zip.Sha256 }
    Date = [string]$m.Date; Entry = ''   # Invoke-AVDBenchmark.ps1 is not built yet (#90)
    Zip = [ordered]@{ Name = $name; Size = (Get-Item -LiteralPath $outZip).Length; Sha256 = $zipSha }
    Files = @($files)
}
[IO.File]::WriteAllText((Join-Path $OutDir 'manifest.json'), ($manifest | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding $false))
[pscustomobject]@{ Zip = $outZip; Manifest = (Join-Path $OutDir 'manifest.json'); Files = @($take) }
