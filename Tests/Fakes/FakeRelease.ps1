# Fakes for Modules\AVDTune.Release.psm1: the HTTP adapter (GetText, GetFile) answers from memory, and a builder makes real releases (ZIP and manifest.json,
# with Tools\New-AVDTuneRelease.ps1) from a few files in a temp folder. No network, nothing outside the folders given.
#   New-AVDTuneFakeReleaseHttp -Seed @{ Text = @{ url = 'text' }; Files = @{ url = bytes }; Offline = $false }   .Store holds the maps, .Log every request
#   New-AVDTuneFakeReleaseBuild -Work <folder> -Version <v> -Files @{ 'path' = 'text' } -Http <adapter>          builds a release and publishes it into the adapter

function New-AVDTuneFakeReleaseHttp {
    param([hashtable]$Seed = @{})
    $s = @{ Text = @{}; Files = @{}; Offline = $false; Log = (New-Object System.Collections.ArrayList) }
    foreach ($e in $Seed.GetEnumerator()) { $s[$e.Key] = $e.Value }
    $h = [ordered]@{ Kind = 'Fake'; Store = $s; Log = $s.Log }
    $h.GetText = {
        param($Url, $MaxBytes)
        [void]$s.Log.Add("GetText $Url")
        if ($s.Offline) { throw 'No connection to github.com: the remote name could not be resolved.' }
        if (-not $s.Text.ContainsKey($Url)) { throw 'GitHub answered 404 (github.com).' }
        [string]$s.Text[$Url]
    }.GetNewClosure()
    $h.GetFile = {
        param($Url, $Path, $MaxBytes)
        [void]$s.Log.Add("GetFile $Url")
        if ($s.Offline) { throw 'No connection to github.com: the remote name could not be resolved.' }
        if (-not $s.Files.ContainsKey($Url)) { throw 'GitHub answered 404 (github.com).' }
        [IO.File]::WriteAllBytes($Path, [byte[]]$s.Files[$Url])
    }.GetNewClosure()
    $h
}

function New-AVDTuneFakeReleaseBuild {
    param([Parameter(Mandatory)][string]$Work, [Parameter(Mandatory)][string]$Version, [hashtable]$Files = @{}, $Http, [string]$Notes = '', [string]$Repo = 'dominguez-posh/AVDTune')
    $repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $src = Join-Path $Work "src-$Version"; $out = Join-Path $Work "out-$Version"
    New-Item -ItemType Directory -Path $src -Force | Out-Null
    $all = @{ 'Start-AVDTune.ps1' = "# fake start $Version`r`n"; 'VERSION' = "$Version`n"; 'Modules/Fake.psm1' = "# module $Version`r`n" }
    foreach ($e in $Files.GetEnumerator()) { $all[$e.Key] = $e.Value }
    foreach ($e in $all.GetEnumerator()) {
        $p = Join-Path $src ($e.Key.Replace('/', '\')); New-Item -ItemType Directory -Path (Split-Path $p -Parent) -Force | Out-Null
        [IO.File]::WriteAllText($p, [string]$e.Value, (New-Object Text.UTF8Encoding $false))
    }
    $notesPath = $null
    if ($Notes) { $notesPath = Join-Path $Work "notes-$Version.txt"; [IO.File]::WriteAllText($notesPath, $Notes) }
    $buildArgs = @{ Root = $src; OutDir = $out; Commit = (('{0:x40}' -f ([int]($Version -replace '\D', '') + 1))); CommitDate = [datetime]'2026-11-15T10:00:00Z' }
    if ($notesPath) { $buildArgs.NotesPath = $notesPath }
    $r = & (Join-Path $repoRoot 'Tools\New-AVDTuneRelease.ps1') @buildArgs
    $release = [pscustomobject]@{ Version = $Version; Zip = $r.Zip; Manifest = $r.Manifest; Source = $src; ZipUrl = "https://github.com/$Repo/releases/download/v$Version/AVDTune-$Version.zip"; ManifestUrl = "https://github.com/$Repo/releases/download/v$Version/manifest.json" }
    if ($Http) { $Http.Store.Text[$release.ManifestUrl] = [IO.File]::ReadAllText($r.Manifest); $Http.Store.Files[$release.ZipUrl] = [IO.File]::ReadAllBytes($r.Zip) }
    $release
}

function New-AVDTuneFakeFeed([string[]]$Versions, [string]$Repo = 'dominguez-posh/AVDTune') {
    # The releases feed of a repository, reduced to what the tool reads
    $entries = foreach ($v in $Versions) { "<entry><id>tag:github.com,2008:Repository/1/v$v</id><link rel=`"alternate`" type=`"text/html`" href=`"https://github.com/$Repo/releases/tag/v$v`"/><title>v$v</title></entry>" }
    "<?xml version=`"1.0`" encoding=`"UTF-8`"?><feed xmlns=`"http://www.w3.org/2005/Atom`">" + ($entries -join '') + '</feed>'
}
