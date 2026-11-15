#requires -Version 5.1
<#
.SYNOPSIS
    Checks the release path (issue #4): Tools\New-AVDTuneRelease.ps1 (clean checkout, excludes, reproducible ZIP, tag against VERSION), Modules\AVDTune.Release.psm1
    (integrity at start: ok, changed, extra, missing, link, offline with cache, no cache, re-published manifest; write block; update check stable and early
    access; install side by side with wrong ZIP hash, tampered file, extra file, Zip-Slip, maintenance mode, run; rollback; repair; launcher), the URL rules of the
    HTTP adapter, and the scanner of Tests\Check-PublicContent.ps1. Fakes and temp folders only: no network, no release, nothing under C:\ProgramData or C:\Program Files.
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'Modules\AVDTune.psm1') -Force
Import-Module (Join-Path $repo 'Modules\AVDTune.Release.psm1') -Force
. (Join-Path $PSScriptRoot 'Fakes\FakeRelease.ps1')
. (Join-Path $PSScriptRoot 'Check-PublicContent.ps1')
$powershell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"

$script:failed = 0
function Test-Check([string]$Name, [bool]$Ok, $Detail) { if ($Ok) { "PASS $Name" } else { $script:failed++; "FAIL $Name" + $(if ($null -ne $Detail) { "  -> $Detail" }) } }
function Get-ThrownText([scriptblock]$Block) { try { & $Block | Out-Null; $null } catch { $_.Exception.Message } }
function Invoke-Git([string[]]$GitArgs, [string]$In) {
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = & git -C $In -c core.autocrlf=false -c commit.gpgsign=false -c user.name=check -c user.email=check@example.invalid @GitArgs 2>&1; if ($LASTEXITCODE -ne 0) { throw "git $($GitArgs -join ' '): $out" } } finally { $ErrorActionPreference = $old }
}
function New-TestZip([string]$Path, $Entries) {
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::Open($Path, 'Create')
    try { foreach ($e in $Entries.GetEnumerator()) { $en = $zip.CreateEntry($e.Key); $s = $en.Open(); try { $b = [byte[]]$e.Value; $s.Write($b, 0, $b.Length) } finally { $s.Dispose() } } } finally { $zip.Dispose() }
}
function Get-ReleaseEntries($Release) {
    $m = Get-Content -LiteralPath $Release.Manifest -Raw | ConvertFrom-Json
    $e = [ordered]@{}; foreach ($f in $m.Files) { $e[$f.Path] = [IO.File]::ReadAllBytes((Join-Path $Release.Source ($f.Path.Replace('/', '\')))) }
    $e
}
function Publish-CraftedZip($Http, $Release, $ZipPath, $ManifestMutator) {
    # A ZIP that is not the built one, with a manifest whose ZIP entry fits it (so only the inner checks can catch it)
    $m = Get-Content -LiteralPath $Release.Manifest -Raw | ConvertFrom-Json
    $m.Zip.Size = (Get-Item $ZipPath).Length; $m.Zip.Sha256 = Get-AVDTuneFileSha256 $ZipPath
    if ($ManifestMutator) { & $ManifestMutator $m }
    $Http.Store.Text[$Release.ManifestUrl] = ($m | ConvertTo-Json -Depth 6); $Http.Store.Files[$Release.ZipUrl] = [IO.File]::ReadAllBytes($ZipPath)
    $m
}
function Get-Names($Folder) { @(Get-ChildItem -LiteralPath $Folder -Force | ForEach-Object Name) }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('avdtune-rel-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $tmp | Out-Null
    $state = Join-Path $tmp 'state'
    [void](Initialize-AVDTuneState -Root $state)
    [void](Start-AVDTuneImageVersion -Root $state -Date ([datetime]'2026-11-15') -User 'admin1')

    # ---------------------------------------------------------------- versions, URLs, paths
    Test-Check 'versions: order incl. early access (x.y.z-ea.N is before x.y.z and after the one before)' ((Compare-AVDTuneReleaseVersion '0.2.0' '0.1.9') -eq 1 -and (Compare-AVDTuneReleaseVersion '0.2.0-ea.3' '0.2.0') -eq -1 -and (Compare-AVDTuneReleaseVersion '0.2.0-ea.3' '0.1.9') -eq 1 -and (Compare-AVDTuneReleaseVersion '0.2.0-ea.10' '0.2.0-ea.9') -eq 1 -and (Compare-AVDTuneReleaseVersion '1.0.0' '1.0.0') -eq 0 -and (Compare-AVDTuneReleaseVersion '0.10.0' '0.9.0') -eq 1) $null
    Test-Check 'version text: only x.y.z and x.y.z-ea.N' ((Test-AVDTuneReleaseVersion '0.1.0') -and (Test-AVDTuneReleaseVersion '1.2.3-ea.4') -and -not (Test-AVDTuneReleaseVersion '1.2') -and -not (Test-AVDTuneReleaseVersion '..\1.0.0') -and -not (Test-AVDTuneReleaseVersion '1.0.0-beta')) $null
    $urls = @{ 'https://github.com/o/r/releases/download/v1.0.0/manifest.json' = $true; 'https://objects.githubusercontent.com/x?sig=1' = $true; 'http://github.com/o/r' = $false
        'https://github.com.evil.example/o' = $false; 'https://evil.example/github.com' = $false; 'https://user@github.com/o' = $false; 'https://github.com:8443/o' = $false; 'ftp://github.com/o' = $false; 'github.com/o' = $false
        'https://api.github.com/repos/o/r' = $false; 'file:///c:/x' = $false }
    $badUrl = @($urls.GetEnumerator() | Where-Object { (Test-AVDTuneReleaseUrl $_.Key) -ne $_.Value } | ForEach-Object Key)
    Test-Check 'URL rule: https, default port, no credentials, only github.com and its download hosts (exact host)' ($badUrl.Count -eq 0) ($badUrl -join ' ')
    $real = New-AVDTuneReleaseHttp
    Test-Check 'real HTTP adapter refuses an http address and a foreign host before any connection' ((Get-ThrownText { & $real.GetText 'http://github.com/o/r' 1000 }) -like 'Refused*' -and (Get-ThrownText { & $real.GetFile 'https://evil.example/x.zip' (Join-Path $tmp 'x.zip') 1000 }) -like 'Refused*' -and -not (Test-Path (Join-Path $tmp 'x.zip'))) $null
    Test-Check 'safe paths: plain relative names only' ((Test-AVDTuneSafeRelativePath 'Modules/AVDTune.psm1') -and -not (Test-AVDTuneSafeRelativePath '../x') -and -not (Test-AVDTuneSafeRelativePath 'a/../b') -and -not (Test-AVDTuneSafeRelativePath 'C:/x') -and -not (Test-AVDTuneSafeRelativePath '/x') -and -not (Test-AVDTuneSafeRelativePath 'a\b') -and -not (Test-AVDTuneSafeRelativePath 'a/nul.txt') -and -not (Test-AVDTuneSafeRelativePath 'a.') -and -not (Test-AVDTuneSafeRelativePath 'a:stream')) $null

    # ---------------------------------------------------------------- the release script against a real git repo
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($git) {
        $g = Join-Path $tmp 'repo'
        foreach ($f in 'Start-AVDTune.ps1', 'Modules/A.psm1', 'UI/A.xaml', 'README.md', 'Tests/Check-X.ps1', 'Tools/T.ps1', '.claude/team/RULES.md', '.github/workflows/release.yml', 'docs/plans/p.md', 'docs/guide.md', 'CLAUDE.md', '.gitignore') {
            $p = Join-Path $g $f.Replace('/', '\'); New-Item -ItemType Directory -Path (Split-Path $p -Parent) -Force | Out-Null; [IO.File]::WriteAllText($p, "content of $f`n")
        }
        [IO.File]::WriteAllText((Join-Path $g 'VERSION'), "0.1.0`n")
        Invoke-Git @('init', '-q') $g; Invoke-Git @('add', '-A') $g; Invoke-Git @('commit', '-q', '-m', 'first release content') $g
        $head = (& git -C $g rev-parse HEAD).Trim()
        $r1 = & (Join-Path $repo 'Tools\New-AVDTuneRelease.ps1') -Root $g -OutDir (Join-Path $tmp 'rel1') -ExpectTag 'v0.1.0'
        $m1 = Get-Content -LiteralPath $r1.Manifest -Raw | ConvertFrom-Json
        $paths = @($m1.Files | ForEach-Object Path)
        Test-Check 'release: only the runtime files are in (Tests, Tools, .claude, .github, docs, CLAUDE.md, dot files are not)' (($paths -join ',') -eq 'Modules/A.psm1,README.md,Start-AVDTune.ps1,UI/A.xaml,VERSION') ($paths -join ',')
        Test-Check 'release: manifest has schema, version, commit of HEAD, date, ZIP size and SHA256, and every file with size and SHA256' ($m1.Schema -eq 1 -and $m1.Version -eq '0.1.0' -and $m1.Commit -eq $head -and $m1.Date -match '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$' -and $m1.Zip.Name -eq 'AVDTune-0.1.0.zip' -and $m1.Zip.Sha256 -eq (Get-AVDTuneFileSha256 $r1.Zip) -and $m1.Zip.Size -eq (Get-Item $r1.Zip).Length -and (@($m1.Files | Where-Object { $_.Sha256 -notmatch '^[0-9a-f]{64}$' -or $_.Size -le 0 }).Count -eq 0) -and $m1.Prerelease -eq $false) ($m1 | ConvertTo-Json -Compress -Depth 4)
        Test-Check 'release: notes come from the commit subjects; the manifest passes the tool validation' ($m1.Notes -like '*first release content*' -and (Assert-AVDTuneManifest $m1 '0.1.0')) $m1.Notes
        $r1b = & (Join-Path $repo 'Tools\New-AVDTuneRelease.ps1') -Root $g -OutDir (Join-Path $tmp 'rel1b')
        Test-Check 'release: building the same commit again gives the same ZIP (reproducible)' ((Get-AVDTuneFileSha256 $r1.Zip) -eq (Get-AVDTuneFileSha256 $r1b.Zip)) $null
        [IO.File]::AppendAllText((Join-Path $g 'README.md'), 'dirty')
        Test-Check 'release: a checkout with changes is refused' ((Get-ThrownText { & (Join-Path $repo 'Tools\New-AVDTuneRelease.ps1') -Root $g -OutDir (Join-Path $tmp 'rel2') }) -like '*not clean*') $null
        Invoke-Git @('checkout', '-q', '--', 'README.md') $g
        Test-Check 'release: a tag that does not match VERSION is refused' ((Get-ThrownText { & (Join-Path $repo 'Tools\New-AVDTuneRelease.ps1') -Root $g -OutDir (Join-Path $tmp 'rel3') -ExpectTag 'v0.2.0' }) -like '*does not match VERSION*') $null
        [IO.File]::WriteAllText((Join-Path $g 'VERSION'), "0.2-beta`n"); Invoke-Git @('commit', '-q', '-am', 'bad version') $g
        Test-Check 'release: a VERSION that is not x.y.z is refused' ((Get-ThrownText { & (Join-Path $repo 'Tools\New-AVDTuneRelease.ps1') -Root $g -OutDir (Join-Path $tmp 'rel4') }) -like '*not x.y.z*') $null
    }
    else { 'NOTE git is not installed: the release script was not checked against a repo' }

    # ---------------------------------------------------------------- releases for the rest: 0.1.0, 0.2.0, 0.3.0, early access 0.4.0-ea.1
    $http = New-AVDTuneFakeReleaseHttp
    $rel = @{}
    foreach ($v in '0.1.0', '0.2.0', '0.3.0', '0.4.0-ea.1') {
        $start = if ($v -eq '0.1.0' -or $v -eq '0.2.0') { '[IO.File]::WriteAllText($env:AVDTUNE_TEST_MARK, ' + "'$v')" } else { "# start $v" }
        $rel[$v] = New-AVDTuneFakeReleaseBuild -Work $tmp -Version $v -Http $http -Notes "Notes of $v`n- something changed" -Files @{ 'Start-AVDTune.ps1' = "$start`r`n"; 'UI/Main.xaml' = "<Window/>`n"; 'README.md' = "readme $v`n" }
    }
    $http.Store.Text[(Get-AVDTuneReleaseFeedUrl)] = New-AVDTuneFakeFeed @('0.1.0', '0.2.0', '0.3.0', '0.4.0-ea.1')
    $manifestSaved = @{}; foreach ($v in $rel.Keys) { $manifestSaved[$v] = $http.Store.Text[$rel[$v].ManifestUrl] }

    # ---------------------------------------------------------------- update check
    $l1 = Get-AVDTuneLatestRelease -Http $http -CurrentVersion '0.1.0'
    Test-Check 'update check: stable only by default (the early access release is not offered), notes come with it' ($l1.Version -eq '0.3.0' -and $l1.Newer -and $l1.Notes -like '*Notes of 0.3.0*' -and -not $l1.Prerelease) ($l1 | Out-String)
    $l2 = Get-AVDTuneLatestRelease -Http $http -CurrentVersion '0.1.0' -EarlyAccess
    Test-Check 'update check: with early access the newest one, marked as early access' ($l2.Version -eq '0.4.0-ea.1' -and $l2.Prerelease -and $l2.Newer) $l2.Version
    Test-Check 'update check: up to date is not "newer"; early access setting is saved and read back' (-not (Get-AVDTuneLatestRelease -Http $http -CurrentVersion '0.3.0').Newer -and -not (Get-AVDTuneReleaseSettings $state).EarlyAccess -and (Set-AVDTuneReleaseSettings $state $true).EarlyAccess -and (Get-AVDTuneReleaseSettings $state).EarlyAccess) $null
    [void](Set-AVDTuneReleaseSettings $state $false)
    $http.Store.Offline = $true
    Test-Check 'update check: offline gives an error, not a crash of the caller' ((Get-ThrownText { Get-AVDTuneLatestRelease -Http $http -CurrentVersion '0.1.0' }) -like '*No connection*') $null
    $http.Store.Offline = $false

    # ---------------------------------------------------------------- install side by side, switch, previous kept, prune
    $inst = Join-Path $tmp 'Program Files\AVDTune'
    $i1 = Install-AVDTuneRelease -Http $http -Manifest (ConvertFrom-AVDTuneManifestText $manifestSaved['0.1.0'] '0.1.0') -InstallRoot $inst -StateRoot $state -User 'admin1'
    $cur = Get-AVDTuneInstallState $inst
    Test-Check 'install 0.1.0: folder, launcher, current.json, cached manifest, no staging left' ((Test-Path (Join-Path $inst '0.1.0\Start-AVDTune.ps1')) -and (Test-Path (Join-Path $inst 'Start-AVDTune.ps1')) -and $cur.Version -eq '0.1.0' -and $cur.Previous -eq '' -and (Test-Path (Join-Path $state 'release\manifest-0.1.0.json')) -and @(Get-Names $inst | Where-Object { $_ -like '.staging*' }).Count -eq 0) ((Get-Names $inst) -join ',')
    Test-Check 'install: a change log entry names the tool version and the update; the protocol text is returned' ($i1.ChangeLog -and (@((Get-AVDTuneChangeLog -Root $state) | Where-Object { $_.Category -eq 'Tool' -and $_.ToolVersion -eq (Get-AVDTuneToolVersion $repo) -and $_.Text -like '*0.1.0*SHA256*' }).Count -eq 1) -and $i1.Text -like '*0.1.0*') ($i1 | Out-String)
    $mark = Join-Path $tmp 'mark.txt'; $env:AVDTUNE_TEST_MARK = $mark
    & $powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $inst 'Start-AVDTune.ps1')
    Test-Check 'launcher starts the version in current.json' ((Test-Path $mark) -and [IO.File]::ReadAllText($mark) -eq '0.1.0') $null
    $i2 = Install-AVDTuneRelease -Http $http -Manifest (ConvertFrom-AVDTuneManifestText $manifestSaved['0.2.0'] '0.2.0') -InstallRoot $inst -StateRoot $state -User 'admin1'
    $cur = Get-AVDTuneInstallState $inst
    Test-Check 'install 0.2.0 side by side: switched, 0.1.0 kept as previous, both folders there' ($cur.Version -eq '0.2.0' -and $cur.Previous -eq '0.1.0' -and (Test-Path (Join-Path $inst '0.1.0')) -and (Test-Path (Join-Path $inst '0.2.0'))) ($cur | Out-String)
    $i3 = Install-AVDTuneRelease -Http $http -Manifest (ConvertFrom-AVDTuneManifestText $manifestSaved['0.3.0'] '0.3.0') -InstallRoot $inst -StateRoot $state -User 'admin1'
    $cur = Get-AVDTuneInstallState $inst
    Test-Check 'install 0.3.0: previous is 0.2.0, the older 0.1.0 is removed' ($cur.Version -eq '0.3.0' -and $cur.Previous -eq '0.2.0' -and -not (Test-Path (Join-Path $inst '0.1.0')) -and (Test-Path (Join-Path $inst '0.2.0'))) ($cur | Out-String)

    # ---------------------------------------------------------------- rollback
    $b = Undo-AVDTuneRelease -InstallRoot $inst -StateRoot $state -User 'admin1'
    $cur = Get-AVDTuneInstallState $inst
    Test-Check 'rollback: back to 0.2.0, 0.3.0 is the previous one, change log entry written' ($cur.Version -eq '0.2.0' -and $cur.Previous -eq '0.3.0' -and $b.ChangeLog -and $b.Text -like '*back from 0.3.0 to 0.2.0*') ($cur | Out-String)
    Remove-Item $mark -ErrorAction SilentlyContinue
    & $powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $inst 'Start-AVDTune.ps1')
    Test-Check 'launcher starts the version after the rollback' ((Test-Path $mark) -and [IO.File]::ReadAllText($mark) -eq '0.2.0') $null
    [IO.File]::AppendAllText((Join-Path $inst '0.3.0\README.md'), 'changed')
    Test-Check 'rollback to a version whose files were changed is refused and nothing is switched' ((Get-ThrownText { Undo-AVDTuneRelease -InstallRoot $inst -StateRoot $state }) -like '*does not match its release*' -and (Get-AVDTuneInstallState $inst).Version -eq '0.2.0') $null
    [IO.File]::WriteAllText((Join-Path $inst 'current.json'), '{"Schema":1,"Version":"0.2.0","Previous":""}')
    Test-Check 'rollback without a previous version is refused' ((Get-ThrownText { Undo-AVDTuneRelease -InstallRoot $inst -StateRoot $state }) -like '*no previous version*') $null
    [IO.File]::WriteAllText((Join-Path $inst 'current.json'), '{"Schema":1,"Version":"..\\..\\x","Previous":"0.1.0"}')
    Test-Check 'a current.json with a path in the version is not trusted (no install state)' ($null -eq (Get-AVDTuneInstallState $inst)) $null
    Test-Check 'the launcher checks the version text before it builds a path' ((Get-Content (Join-Path $inst 'Start-AVDTune.ps1') -Raw) -match "notmatch '\^\\d\+\\\.\\d\+\\\.\\d\+") $null
    Remove-Item -LiteralPath $inst -Recurse -Force

    # ---------------------------------------------------------------- install refusals: nothing is switched, nothing is left
    $inst = Join-Path $tmp 'Program Files 2\AVDTune'
    [void](Install-AVDTuneRelease -Http $http -Manifest (ConvertFrom-AVDTuneManifestText $manifestSaved['0.1.0'] '0.1.0') -InstallRoot $inst -StateRoot $state)
    $before = (Get-Content (Join-Path $inst 'current.json') -Raw)
    $r2 = $rel['0.2.0']; $m2 = ConvertFrom-AVDTuneManifestText $manifestSaved['0.2.0'] '0.2.0'
    function Assert-Untouched([string]$Name, [string]$Pattern, [scriptblock]$Do) {
        $t = Get-ThrownText $Do
        Test-Check $Name ($t -like $Pattern -and (Get-Content (Join-Path $inst 'current.json') -Raw) -eq $before -and -not (Test-Path (Join-Path $inst '0.2.0')) -and @(Get-Names $inst | Where-Object { $_ -like '.staging*' }).Count -eq 0 -and -not (Test-Path (Join-Path $tmp 'evil.txt')) -and -not (Test-Path (Join-Path $inst 'evil.txt')) -and -not (Test-Path (Join-Path (Split-Path $inst -Parent) 'evil.txt'))) $t
    }
    $zipBytes = [IO.File]::ReadAllBytes($r2.Zip); $flipped = $zipBytes.Clone(); $flipped[$flipped.Length - 40] = $flipped[$flipped.Length - 40] -bxor 0xFF
    $http.Store.Files[$r2.ZipUrl] = $flipped
    Assert-Untouched 'wrong ZIP hash: refused' '*does not match its SHA256*' { Install-AVDTuneRelease -Http $http -Manifest $m2 -InstallRoot $inst -StateRoot $state }
    $http.Store.Files[$r2.ZipUrl] = $zipBytes[0..($zipBytes.Length - 2)]
    Assert-Untouched 'ZIP of another size: refused' '*another size*' { Install-AVDTuneRelease -Http $http -Manifest $m2 -InstallRoot $inst -StateRoot $state }
    $http.Store.Files[$r2.ZipUrl] = $zipBytes
    # tampered file in a ZIP whose own hash is right in the manifest
    $e = Get-ReleaseEntries $r2; $e['Modules/Fake.psm1'] = [Text.Encoding]::UTF8.GetBytes('# modulX 0.2.0' + "`r`n")
    $z = Join-Path $tmp 'tampered.zip'; New-TestZip $z $e; $m = Publish-CraftedZip $http $r2 $z $null
    Assert-Untouched 'a file in the ZIP that differs from the manifest (same size): refused' "*does not match its SHA256 in the manifest*" { Install-AVDTuneRelease -Http $http -Manifest (ConvertFrom-AVDTuneManifestText ($http.Store.Text[$r2.ManifestUrl]) '0.2.0') -InstallRoot $inst -StateRoot $state }
    $e = Get-ReleaseEntries $r2; $e['extra.ps1'] = [Text.Encoding]::UTF8.GetBytes('Write-Host extra')
    $z = Join-Path $tmp 'extra.zip'; New-TestZip $z $e; [void](Publish-CraftedZip $http $r2 $z $null)
    Assert-Untouched 'an extra file in the ZIP that the manifest does not list: refused' '*does not list*' { Install-AVDTuneRelease -Http $http -Manifest (ConvertFrom-AVDTuneManifestText ($http.Store.Text[$r2.ManifestUrl]) '0.2.0') -InstallRoot $inst -StateRoot $state }
    $e = Get-ReleaseEntries $r2; [void]$e.Remove('Modules/Fake.psm1')
    $z = Join-Path $tmp 'missing.zip'; New-TestZip $z $e; [void](Publish-CraftedZip $http $r2 $z $null)
    Assert-Untouched 'a listed file that is not in the ZIP: refused' '*lacks*' { Install-AVDTuneRelease -Http $http -Manifest (ConvertFrom-AVDTuneManifestText ($http.Store.Text[$r2.ManifestUrl]) '0.2.0') -InstallRoot $inst -StateRoot $state }
    foreach ($evil in '../evil.txt', '..\evil.txt', '../../evil.txt', 'Modules/../../evil.txt', 'C:/evil.txt', '/evil.txt', 'Modules\..\..\evil.txt') {
        $e = Get-ReleaseEntries $r2; $e[$evil] = [Text.Encoding]::UTF8.GetBytes('evil')
        $z = Join-Path $tmp 'slip.zip'; Remove-Item $z -ErrorAction SilentlyContinue; New-TestZip $z $e; [void](Publish-CraftedZip $http $r2 $z $null)
        Assert-Untouched "Zip-Slip entry '$evil': refused, nothing written outside" '*unsafe path*' { Install-AVDTuneRelease -Http $http -Manifest (ConvertFrom-AVDTuneManifestText ($http.Store.Text[$r2.ManifestUrl]) '0.2.0') -InstallRoot $inst -StateRoot $state }
    }
    $badManifest = ($manifestSaved['0.2.0'] | ConvertFrom-Json); $badManifest.Files[0].Path = '../evil.txt'
    Test-Check 'a manifest with a path that leaves the folder is not valid' ((Get-ThrownText { Assert-AVDTuneManifest $badManifest '0.2.0' }) -like '*unsafe path*') $null
    $badManifest = ($manifestSaved['0.2.0'] | ConvertFrom-Json); $badManifest.Files[0].Sha256 = 'abc'
    Test-Check 'a manifest with a bad hash, another version, a duplicate path or a bad commit is not valid' ((Get-ThrownText { Assert-AVDTuneManifest $badManifest '0.2.0' }) -like '*bad hash*' -and (Get-ThrownText { Assert-AVDTuneManifest ($manifestSaved['0.2.0'] | ConvertFrom-Json) '0.3.0' }) -like '*not 0.3.0*' -and (Get-ThrownText { $d = ($manifestSaved['0.2.0'] | ConvertFrom-Json); $d.Files = @($d.Files) + @($d.Files[0]); Assert-AVDTuneManifest $d '0.2.0' }) -like '*twice*' -and (Get-ThrownText { $d = ($manifestSaved['0.2.0'] | ConvertFrom-Json); $d.Commit = 'xyz'; Assert-AVDTuneManifest $d '0.2.0' }) -like '*bad commit*') $null
    $http.Store.Files[$r2.ZipUrl] = $zipBytes; $http.Store.Text[$r2.ManifestUrl] = $manifestSaved['0.2.0']
    # maintenance mode and a running job
    [void](Set-AVDTuneState -Root $state -Values @{ Maintenance = [pscustomobject]@{ Active = $true; Id = 'x' }; UpdateBlock = 'Maintenance' })
    Assert-Untouched 'update during the maintenance mode: refused' '*maintenance mode*' { Install-AVDTuneRelease -Http $http -Manifest $m2 -InstallRoot $inst -StateRoot $state }
    Test-Check 'rollback and repair during the maintenance mode: refused too' ((Get-ThrownText { Undo-AVDTuneRelease -InstallRoot $inst -StateRoot $state }) -like '*maintenance mode*' -and (Get-ThrownText { Repair-AVDTuneInstall -Http $http -AppRoot (Join-Path $inst '0.1.0') -InstallRoot $inst -StateRoot $state }) -like '*maintenance mode*') $null
    [void](Set-AVDTuneState -Root $state -Values @{ Maintenance = [pscustomobject]@{ Active = $false; Id = 'x' }; UpdateBlock = 'On' })
    Assert-Untouched 'update during a run: refused' '*run is active*' { Install-AVDTuneRelease -Http $http -Manifest $m2 -InstallRoot $inst -StateRoot $state -RunActive }
    Assert-Untouched 'install without network: error, nothing switched' '*No connection*' { $http.Store.Offline = $true; try { Install-AVDTuneRelease -Http $http -Manifest $m2 -InstallRoot $inst -StateRoot $state } finally { $http.Store.Offline = $false } }
    $i = Install-AVDTuneRelease -Http $http -Manifest $m2 -InstallRoot $inst -StateRoot $state
    Test-Check 'after all the refusals the update still works (state was not damaged)' ((Get-AVDTuneInstallState $inst).Version -eq '0.2.0') $null

    # ---------------------------------------------------------------- integrity at start
    $app = Join-Path $inst '0.2.0'
    $st = Get-AVDTuneIntegrityStatus -AppRoot $app -InstallRoot $inst -StateRoot $state -Http $http
    Test-Check 'integrity: all files as released -> ok (from GitHub), the message names version and commit' ($st.Status -eq 'ok' -and $st.Source -eq 'github' -and $st.Message -like '*0.2.0*' -and $st.Mode -eq 'Installed') ($st | Out-String)
    Set-AVDTuneIntegrityBlock $st
    $http.Store.Offline = $true
    $st = Get-AVDTuneIntegrityStatus -AppRoot $app -InstallRoot $inst -StateRoot $state -Http $http
    Test-Check 'integrity offline: compared with the cached manifest, with a note' ($st.Status -eq 'ok' -and $st.Source -eq 'cache' -and @($st.Warnings).Count -eq 1) ($st | Out-String)
    $cachePath = Join-Path $state 'release\manifest-0.2.0.json'; $cacheText = [IO.File]::ReadAllText($cachePath); Remove-Item $cachePath
    $st = Get-AVDTuneIntegrityStatus -AppRoot $app -InstallRoot $inst -StateRoot $state -Http $http
    Test-Check 'integrity offline without a cached manifest: unverified (usable, said so), not red' ($st.Status -eq 'unverified' -and $st.Message -like '*could not be compared*') ($st | Out-String)
    [IO.File]::WriteAllText($cachePath, $cacheText); $http.Store.Offline = $false
    [IO.File]::WriteAllText($cachePath, '{ not json');
    $st = Get-AVDTuneIntegrityStatus -AppRoot $app -InstallRoot $inst -StateRoot $state -Http $http
    Test-Check 'integrity: a broken cache file is ignored when GitHub answers, and the cache is not used as a reference' ($st.Status -eq 'ok' -and $st.Source -eq 'github') ($st | Out-String)
    [IO.File]::WriteAllText($cachePath, $cacheText)
    # re-published manifest (other commit under the same version)
    $other = $manifestSaved['0.2.0'] | ConvertFrom-Json; $other.Commit = ('f' * 40); $http.Store.Text[$rel['0.2.0'].ManifestUrl] = ($other | ConvertTo-Json -Depth 6)
    $st = Get-AVDTuneIntegrityStatus -AppRoot $app -InstallRoot $inst -StateRoot $state -Http $http
    Test-Check 'integrity: GitHub shows another manifest for the version than at install time -> the saved one is the reference, with a warning' ($st.Status -eq 'ok' -and $st.Source -eq 'cache' -and ($st.Warnings -join ' ') -like '*published this version again*') ($st | Out-String)
    $http.Store.Text[$rel['0.2.0'].ManifestUrl] = $manifestSaved['0.2.0']

    $f = Join-Path $app 'Modules\Fake.psm1'; $orig = [IO.File]::ReadAllBytes($f)
    [IO.File]::WriteAllText($f, '# manipulated')
    $st = Get-AVDTuneIntegrityStatus -AppRoot $app -InstallRoot $inst -StateRoot $state -Http $http
    Test-Check 'integrity: a changed file -> bad with the file in the list' ($st.Status -eq 'bad' -and $st.Changed -contains 'Modules/Fake.psm1' -and $st.Missing.Count -eq 0 -and $st.Extra.Count -eq 0) ($st | Out-String)
    Set-AVDTuneIntegrityBlock $st
    [void](Set-AVDTuneState -Root $state -Values @{ LastChange = $null })
    Test-Check 'integrity bad: the write gate is shut, cannot be opened, and a gate that was open is closed' ((-not (Test-AVDTuneWriteAllowed)) -and (Get-ThrownText { Open-AVDTuneWriteGate -SnapshotId 's1' -ConfirmedBy 'admin1' }) -like '*read only*' -and (Get-AVDTuneWriteBlock)) $null
    Clear-AVDTuneWriteBlock; Open-AVDTuneWriteGate -SnapshotId 's1' -ConfirmedBy 'admin1'; $wasOpen = Test-AVDTuneWriteAllowed; Set-AVDTuneIntegrityBlock $st
    Test-Check 'integrity bad closes an open gate; an ok result lifts the block again' ($wasOpen -and -not (Test-AVDTuneWriteAllowed) -and (Set-AVDTuneIntegrityBlock ([pscustomobject]@{ Status = 'ok'; Message = '' })) -eq $null -and -not (Get-AVDTuneWriteBlock)) $null
    [IO.File]::WriteAllBytes($f, $orig)
    [IO.File]::WriteAllText((Join-Path $app 'evil.ps1'), 'evil')
    $st = Get-AVDTuneIntegrityStatus -AppRoot $app -InstallRoot $inst -StateRoot $state -Http $http
    Test-Check 'integrity: an extra file -> bad, listed under extra' ($st.Status -eq 'bad' -and $st.Extra -contains 'evil.ps1' -and $st.Changed.Count -eq 0) ($st | Out-String)
    Remove-Item (Join-Path $app 'evil.ps1')
    Remove-Item (Join-Path $app 'UI\Main.xaml')
    $st = Get-AVDTuneIntegrityStatus -AppRoot $app -InstallRoot $inst -StateRoot $state -Http $http
    Test-Check 'integrity: a missing file -> bad, listed under missing' ($st.Status -eq 'bad' -and $st.Missing -contains 'UI/Main.xaml') ($st | Out-String)
    [IO.File]::WriteAllText((Join-Path $app 'UI\Main.xaml'), "<Window/>`n")
    $other = Join-Path $tmp 'elsewhere'; New-Item -ItemType Directory -Path $other | Out-Null
    New-Item -ItemType Junction -Path (Join-Path $app 'linked') -Target $other | Out-Null
    $st = Get-AVDTuneIntegrityStatus -AppRoot $app -InstallRoot $inst -StateRoot $state -Http $http
    Test-Check 'integrity: a link (junction) in the folder -> bad, reported and not followed' ($st.Status -eq 'bad' -and $st.Extra -contains 'linked') ($st | Out-String)

    # ---------------------------------------------------------------- repair
    [IO.File]::WriteAllText($f, '# manipulated'); [IO.File]::WriteAllText((Join-Path $app 'evil.ps1'), 'evil'); Remove-Item (Join-Path $app 'README.md')
    Remove-Item $other -Recurse -Force; New-Item -ItemType Directory -Path $other | Out-Null; [IO.File]::WriteAllText((Join-Path $other 'keep.txt'), 'keep')
    $bad = $flipped
    $http.Store.Files[$rel['0.2.0'].ZipUrl] = $bad
    Test-Check 'repair with a ZIP that does not match the release: refused, folder untouched' ((Get-ThrownText { Repair-AVDTuneInstall -Http $http -AppRoot $app -InstallRoot $inst -StateRoot $state }) -like '*SHA256*' -and [IO.File]::ReadAllText($f) -eq '# manipulated' -and (Test-Path (Join-Path $app 'evil.ps1'))) $null
    $http.Store.Files[$rel['0.2.0'].ZipUrl] = $zipBytes
    $rp = Repair-AVDTuneInstall -Http $http -AppRoot $app -InstallRoot $inst -StateRoot $state -User 'admin1'
    $st = Get-AVDTuneIntegrityStatus -AppRoot $app -InstallRoot $inst -StateRoot $state -Http $http
    Test-Check 'repair: changed and missing files replaced, extra file and link removed (the link target is untouched), then ok' ($rp.Ok -and $rp.Fixed -eq 4 -and $st.Status -eq 'ok' -and -not (Test-Path (Join-Path $app 'evil.ps1')) -and -not (Test-Path (Join-Path $app 'linked')) -and (Test-Path (Join-Path $other 'keep.txt'))) (($rp | Out-String) + ($st | Out-String))
    Test-Check 'repair: logged in the change log with the tool version' (@((Get-AVDTuneChangeLog -Root $state) | Where-Object { $_.Text -like '*repaired*' -and $_.ToolVersion }).Count -eq 1) $null
    Test-Check 'repair of a development copy is refused' ((Get-ThrownText { Repair-AVDTuneInstall -Http $http -AppRoot $repo -InstallRoot $inst -StateRoot $state }) -like '*installed copy only*') $null

    # ---------------------------------------------------------------- modes without a protected install
    $dev = Get-AVDTuneIntegrityStatus -AppRoot $repo -InstallRoot $inst -StateRoot $state -Http $http
    $loose = Join-Path $tmp 'loose\0.2.0'; New-Item -ItemType Directory -Path $loose -Force | Out-Null; [IO.File]::WriteAllText((Join-Path $loose 'VERSION'), '0.2.0')
    $unp = Get-AVDTuneIntegrityStatus -AppRoot $loose -InstallRoot $inst -StateRoot $state -Http $http
    Test-Check 'a git checkout is "dev" and a copy outside the install folder is "unprotected": neither blocks, both say so' ($dev.Status -eq 'dev' -and $unp.Status -eq 'unprotected' -and $unp.Message -like '*not run from*' -or $unp.Message -like '*does not run from*') (($dev | Out-String) + ($unp | Out-String))
    Test-Check 'the check did not use the real install or state folder' ($inst -ne (Get-AVDTuneInstallRoot) -and -not (Test-AVDTuneDefaultRoot $state)) $null

    # ---------------------------------------------------------------- window parts exist
    [xml]$xaml = Get-Content (Join-Path $repo 'UI\AVDTune.xaml') -Raw -Encoding UTF8
    $names = @($xaml.SelectNodes("//*[@*[local-name()='Name']]") | ForEach-Object { $_.Attributes | Where-Object LocalName -eq 'Name' | Select-Object -ExpandProperty Value })
    $needed = 'BoxRelease', 'TxtRelStatus', 'TxtRelDetail', 'TxtRelFiles', 'TxtRelLimit', 'BtnRelCheck', 'BtnRelRepair', 'BtnRelInstall', 'BtnRelBack', 'ChkRelEarly', 'TxtRelNotes'
    Test-Check 'the Overview has the integrity and update card with its controls' (@($needed | Where-Object { $_ -notin $names }).Count -eq 0) (@($needed | Where-Object { $_ -notin $names }) -join ',')

    # ---------------------------------------------------------------- Check-PublicContent scanner
    $pc = Join-Path $tmp 'pc'; New-Item -ItemType Directory -Path (Join-Path $pc 'Tests') -Force | Out-Null
    $g1 = '3f2b8c1e-5a4d-4e6f-9b7a-1c2d3e4f5a6b'
    [IO.File]::WriteAllLines((Join-Path $pc 'a.ps1'), @("x = '$g1'", "ok = '7971F918-A847-4430-9279-4A52D1EFE18D'", 'h = contoso1.file.core.windows.net', 'h2 = realshare01.file.core.windows.net', 'h3 = privatelink.file.core.windows.net', 'ip = 192.0.2.10 and 203.0.113.7 and 10.1.2.3 and 168.63.129.16', 'v = 10.0.22631.1 and 2.9.8884.27471', "y = '$g1' # public-content-ok", 'n = Fabrikam Internal Name'))
    [IO.File]::WriteAllLines((Join-Path $pc 'Tests\t.ps1'), @("fake = '$g1'", 'dc = 10.0.0.10', 'real = 8.8.8.8'))   # public-content-ok (fixture)
    $found = @(Find-PublicContentFindings -Folder $pc -Deny @('fabrikam internal', 'secretname'))
    $by = { param($rule) , @($found | Where-Object Rule -eq $rule) }
    Test-Check 'public content: an unknown GUID outside Tests fails, an allowlisted one, one in Tests and a marked line do not' ((& $by 'guid').Count -eq 1 -and (& $by 'guid')[0].Detail -eq $g1 -and (& $by 'guid')[0].File -eq 'a.ps1' -and (& $by 'guid')[0].Line -eq 1) ($found | Out-String)
    Test-Check 'public content: a storage host with a real name fails, placeholders and privatelink do not' ((& $by 'storage-host').Count -eq 1 -and (& $by 'storage-host')[0].Detail -eq 'realshare01.file.core.windows.net') ($found | Out-String)   # public-content-ok (fixture)
    Test-Check 'public content: an IP outside the documentation ranges fails (10.x outside Tests, 8.8.8.8 in Tests), documentation and Azure fixed addresses and version numbers do not' (((& $by 'ip') | ForEach-Object Detail | Sort-Object) -join ',' -eq '10.1.2.3,8.8.8.8') ($found | Out-String)   # public-content-ok (fixture)
    Test-Check 'public content: a deny-list name is found (case does not matter) and the finding does not print the name' ((& $by 'deny-list').Count -eq 1 -and (& $by 'deny-list')[0].Detail -notlike '*fabrikam*' -and (& $by 'deny-list')[0].Detail -like '*entry 1*') ($found | Out-String)
    $none = Join-Path $tmp 'deny-missing.txt'
    $out = & $powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Check-PublicContent.ps1') -Root $pc -DenyListPath $none 2>&1 | Out-String
    Test-Check 'public content: the script fails on findings (exit code) and notes a missing deny list without failing for it' ($LASTEXITCODE -eq 1 -and $out -like '*NOTE deny list not found*' -and $out -match 'FAIL public content \(guid\)') $out
    $cleanDir = Join-Path $tmp 'pc-clean'; New-Item -ItemType Directory -Path $cleanDir | Out-Null; [IO.File]::WriteAllText((Join-Path $cleanDir 'ok.md'), "nothing here`n")
    $out = & $powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Check-PublicContent.ps1') -Root $cleanDir -DenyListPath $none 2>&1 | Out-String
    Test-Check 'public content: a clean tree passes, exit code 0' ($LASTEXITCODE -eq 0 -and $out -notlike '*FAIL*') $out
}
finally {
    Clear-AVDTuneWriteBlock; Close-AVDTuneWriteGate
    $env:AVDTUNE_TEST_MARK = $null
    # a junction is removed as a link first, so the delete never follows it
    foreach ($j in @(Get-ChildItem -LiteralPath $tmp -Recurse -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })) { try { [IO.Directory]::Delete($j.FullName) } catch { } }
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
if ($script:failed -gt 0) { throw "$script:failed check(s) failed." }
'Check-Release: all checks passed.'
