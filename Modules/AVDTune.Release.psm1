<#
    AVDTune Release: integrity check at every start, update check, update, repair and rollback against GitHub releases (docs\plans\avdtune.md, section 9a).

    A release (Tools\New-AVDTuneRelease.ps1, built by .github\workflows\release.yml on a tag) is AVDTune-<version>.zip and manifest.json (version, commit, date,
    notes, SHA256 and size of the ZIP and of every file). Where the tool lives:

      C:\Program Files\AVDTune\<version>\     one folder per version (admin-only ACL of Program Files), the running tool is one of them
      C:\Program Files\AVDTune\current.json   {Version, Previous}: which version the launcher starts, and the one before it
      C:\Program Files\AVDTune\Start-AVDTune.ps1   launcher (written by this module, not part of a release): reads current.json and starts that version
      <state>\release\manifest-<version>.json     cached manifest of every installed version (state folder: administrators only)
      <state>\config\release.json                 {EarlyAccess}

    Why a pointer file plus launcher for the switch: one atomic write (Write-AVDTuneFile) switches and one atomic write switches back; shortcuts and the
    scheduled start keep pointing at the launcher; nothing is renamed or deleted under a running version. The launcher checks the version text against the
    version pattern before it builds a path from it.

    Rules
      - Network: HTTPS, TLS 1.2, only github.com and the hosts GitHub redirects release downloads to (Test-AVDTuneReleaseUrl, checked on every redirect hop).
        Releases are found through the releases feed of the repository (github.com, no API); early access releases are tags x.y.z-ea.N.
      - Every access goes through the HTTP adapter ($Http: GetText, GetFile); the real one is New-AVDTuneReleaseHttp, the fake is Tests\Fakes\FakeRelease.ps1.
        The install folder and the state folder are parameters, so the checks work in a temp folder.
      - A manifest is validated before use (schema, version, commit, safe relative paths, hashes, sizes). A ZIP is checked against the manifest (size and SHA256),
        every entry against the manifest (nothing missing, nothing extra, size and SHA256, no path leaves the target: Zip-Slip), and the extracted tree once more.
      - Update, repair and rollback are refused during a run and in maintenance mode, and run only on the administrator's click (the window decides, not this module).
      - Limit (shown in the window and in the README): the manifest proves that the files are the ones published on GitHub for that version. It does not protect
        against a compromised GitHub account or repository, and the integrity check runs inside the tool it checks (the code that starts the check is not covered
        by the check before it ran). Authenticode signing can be added later without changing the flow.
#>

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'AVDTune.psm1')
Import-Module (Join-Path $PSScriptRoot 'AVDTune.Trust.psm1')   # Remove-AVDTuneFolderNoFollow

$script:Repo = 'dominguez-posh/AVDTune'
$script:AllowedHosts = @('github.com', 'objects.githubusercontent.com', 'release-assets.githubusercontent.com')
$script:VersionPattern = '^\d+\.\d+\.\d+(-ea\.\d+)?\z'
$script:AclReader = $null   # test hook (Set-AVDTuneReleaseAclReader): replaces the real ACL reader of the folder checks
$script:MaxManifestBytes = 4MB
$script:MaxZipBytes = 200MB
$script:MaxFiles = 2000
$script:BenchExePath = 'Bench/bin/AVDTune.Bench.exe'   # the measure program inside a release (Tools\New-AVDTuneRelease.ps1 -BenchExe puts it there)

#region versions, URLs, paths (pure)

function Test-AVDTuneReleaseVersion([string]$Version) { [bool]($Version -match $script:VersionPattern) }

function Compare-AVDTuneReleaseVersion {
    # -1, 0, 1. x.y.z-ea.N is older than x.y.z and newer than every earlier x.y.z
    param([Parameter(Mandatory)][string]$A, [Parameter(Mandatory)][string]$B)
    function Split([string]$v) {
        $core, $ea = $v -split '-ea\.', 2
        $p = $core -split '\.' | ForEach-Object { [int]$_ }
        [pscustomobject]@{ P = $p; Ea = $(if ($ea) { [int]$ea } else { [int]::MaxValue }) }
    }
    $x = Split $A; $y = Split $B
    for ($i = 0; $i -lt 3; $i++) { if ($x.P[$i] -ne $y.P[$i]) { return [Math]::Sign($x.P[$i] - $y.P[$i]) } }
    if ($x.Ea -ne $y.Ea) { return $(if ($x.Ea -gt $y.Ea) { 1 } else { -1 }) }
    0
}

function Test-AVDTuneReleaseUrl([string]$Url) {
    # HTTPS, no credentials, default port, host on the list (exact match, so github.com.evil.example does not pass)
    $uri = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri)) { return $false }
    $uri.Scheme -eq 'https' -and -not $uri.UserInfo -and $uri.Port -eq 443 -and ($script:AllowedHosts -contains $uri.Host.ToLowerInvariant())
}

function Get-AVDTuneReleaseUrl {
    param([Parameter(Mandatory)][string]$Version, [Parameter(Mandatory)][string]$Name)
    if (-not (Test-AVDTuneReleaseVersion $Version)) { throw "Invalid version '$Version'." }
    "https://github.com/$($script:Repo)/releases/download/v$Version/$Name"
}
function Get-AVDTuneReleaseFeedUrl { "https://github.com/$($script:Repo)/releases.atom" }

function Test-AVDTuneSafeRelativePath([string]$Path) {
    # Forward slashes, plain names only: no drive, no stream, no "..", no trailing dot or space, no device names. The release script uses the same rule.
    if ($Path -notmatch '^[A-Za-z0-9._ -]+(/[A-Za-z0-9._ -]+)*$') { return $false }
    if ($Path -match '(^|/)\.{1,2}(/|$)' -or $Path -match '[. ](/|$)') { return $false }
    if ($Path -match '(?i)(^|/)(con|prn|aux|nul|com\d|lpt\d)(\.[^/]*)?(/|$)') { return $false }
    $true
}

function Get-AVDTuneFileSha256([string]$Path) {
    $sha = [Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    try { ([BitConverter]::ToString($sha.ComputeHash($stream)) -replace '-', '').ToLowerInvariant() } finally { $stream.Dispose(); $sha.Dispose() }
}

function Get-AVDTuneToolVersion([string]$AppRoot) {
    $file = Join-Path $AppRoot 'VERSION'
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return '' }
    $v = ([IO.File]::ReadAllText($file)).Trim()
    if (Test-AVDTuneReleaseVersion $v) { $v } else { '' }
}

#endregion

#region manifest

function Assert-AVDTuneManifest {
    # Throws with the reason when the manifest cannot be trusted as a description of a release; returns it otherwise
    param([Parameter(Mandatory)]$Manifest, [string]$Version)
    function Need($ok, [string]$Why) { if (-not $ok) { throw "The manifest is not valid: $Why" } }
    Need ($null -ne $Manifest) 'it is empty.'
    Need ((Get-AVDTuneProp $Manifest 'Schema') -eq 1) 'unknown schema.'
    Need ((Get-AVDTuneProp $Manifest 'Product') -eq 'AVDTune') 'wrong product.'
    $v = [string](Get-AVDTuneProp $Manifest 'Version')
    Need (Test-AVDTuneReleaseVersion $v) 'bad version.'
    if ($Version) { Need ($v -eq $Version) "it is for version $v, not $Version." }
    Need (([string](Get-AVDTuneProp $Manifest 'Commit')) -match '^[0-9a-f]{40}$') 'bad commit.'
    $d = [datetime]::MinValue
    Need ([datetime]::TryParse([string](Get-AVDTuneProp $Manifest 'Date'), [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$d)) 'bad date.'
    $zip = Get-AVDTuneProp $Manifest 'Zip'
    Need ($null -ne $zip) 'no ZIP entry.'
    Need (([string](Get-AVDTuneProp $zip 'Name')) -ceq "AVDTune-$v.zip") 'bad ZIP name.'
    Need (([string](Get-AVDTuneProp $zip 'Sha256')) -cmatch '^[0-9a-f]{64}\z') 'bad ZIP hash.'
    $zs = [int64](Get-AVDTuneProp $zip 'Size')
    Need ($zs -gt 0 -and $zs -le $script:MaxZipBytes) 'bad ZIP size.'
    $files = @(Get-AVDTuneProp $Manifest 'Files')
    Need ($files.Count -gt 0 -and $files.Count -le $script:MaxFiles) 'bad file count.'
    $seen = @{}; $byPath = @{}; $total = [int64]0
    foreach ($f in $files) {
        $p = [string](Get-AVDTuneProp $f 'Path')
        Need (Test-AVDTuneSafeRelativePath $p) "unsafe path '$p'."
        Need (-not $seen.ContainsKey($p.ToLowerInvariant())) "path '$p' twice."
        $seen[$p.ToLowerInvariant()] = $true; $byPath[$p.ToLowerInvariant()] = $f
        $sz = [int64](Get-AVDTuneProp $f 'Size')
        Need ($sz -ge 0 -and $sz -le $script:MaxZipBytes) "bad size of '$p'."
        $total += $sz
        Need (([string](Get-AVDTuneProp $f 'Sha256')) -cmatch '^[0-9a-f]{64}\z') "bad hash of '$p'."
    }
    Need ($total -le 400MB) 'the files are too large together.'
    Need ($seen.ContainsKey('start-avdtune.ps1') -and $seen.ContainsKey('version')) 'Start-AVDTune.ps1 or VERSION is missing in the list.'
    # The measure program (issue #19): optional (releases before it have none), but when there it is one of the listed files and says the same about it
    $bench = Get-AVDTuneProp $Manifest 'Bench'
    if ($null -ne $bench) {
        $bp = [string](Get-AVDTuneProp $bench 'Path')
        Need ($bp -ceq $script:BenchExePath) 'bad path of the measure program.'
        Need ($byPath.ContainsKey($bp.ToLowerInvariant())) 'the measure program is not in the file list.'
        $bf = $byPath[$bp.ToLowerInvariant()]
        Need (([string](Get-AVDTuneProp $bench 'Sha256')) -cmatch '^[0-9a-f]{64}\z') 'bad hash of the measure program.'
        Need (([string](Get-AVDTuneProp $bench 'Sha256')) -ceq ([string](Get-AVDTuneProp $bf 'Sha256')) -and [int64](Get-AVDTuneProp $bench 'Size') -eq [int64](Get-AVDTuneProp $bf 'Size')) 'the measure program entry differs from its entry in the file list.'
    }
    $Manifest
}

function ConvertFrom-AVDTuneManifestText([string]$Text, [string]$Version) {
    $m = $null
    try { $m = $Text.TrimStart([char]0xFEFF) | ConvertFrom-Json } catch { throw 'The manifest is not valid JSON.' }
    Assert-AVDTuneManifest -Manifest $m -Version $Version
}

function Get-AVDTuneManifestCachePath([string]$StateRoot, [string]$Version) { Join-Path $StateRoot "release\manifest-$Version.json" }

function Get-AVDTuneReleaseManifest {
    <#
        The manifest of a version: from GitHub (and then cached), or the cached copy when GitHub cannot be reached.
        Source is 'github' or 'cache'; Cached is the cached one (when there is one) so the caller can compare. Returns $null Manifest and the Error when neither works.
    #>
    param($Http, [Parameter(Mandatory)][string]$Version, [Parameter(Mandatory)][string]$StateRoot, [switch]$CacheOnly)
    $cachePath = Get-AVDTuneManifestCachePath $StateRoot $Version
    $cached = $null
    if (Test-Path -LiteralPath $cachePath) { try { $cached = ConvertFrom-AVDTuneManifestText ([IO.File]::ReadAllText($cachePath)) $Version } catch { $cached = $null } }
    if ($CacheOnly) { return [pscustomobject]@{ Manifest = $cached; Source = $(if ($cached) { 'cache' } else { '' }); Cached = $cached; Error = $(if ($cached) { '' } else { 'No cached manifest.' }) } }
    $err = ''
    try {
        $url = Get-AVDTuneReleaseUrl -Version $Version -Name 'manifest.json'
        $text = Invoke-AVDTuneHttp { & $Http.GetText $url $script:MaxManifestBytes } $url
        $online = ConvertFrom-AVDTuneManifestText $text $Version
        return [pscustomobject]@{ Manifest = $online; Source = 'github'; Cached = $cached; Error = '' }
    }
    catch { $err = $_.Exception.Message }
    if ($cached) { return [pscustomobject]@{ Manifest = $cached; Source = 'cache'; Cached = $cached; Error = $err } }
    [pscustomobject]@{ Manifest = $null; Source = ''; Cached = $null; Error = $err }
}

function Save-AVDTuneManifestCache([string]$StateRoot, $Manifest) {
    Write-AVDTuneFile (Get-AVDTuneManifestCachePath $StateRoot ([string]$Manifest.Version)) ($Manifest | ConvertTo-Json -Depth 6)
}

#endregion

#region HTTP

function Invoke-AVDTuneHttp([scriptblock]$Call, [string]$Url) {
    # Every request goes through here: the URL is checked before the adapter sees it
    if (-not (Test-AVDTuneReleaseUrl $Url)) { throw "Refused: the address is not an https address on an allowed GitHub host." }
    & $Call
}

function Invoke-AVDTuneHttpDownload {
    # Real download: HTTPS, TLS 1.2, redirects followed by hand (at most 5) and every hop checked against the host list, size capped, timeouts
    param([Parameter(Mandatory)][string]$Url, [Parameter(Mandatory)][long]$MaxBytes, [string]$Path)
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $current = $Url
    for ($hop = 0; $hop -le 5; $hop++) {
        if (-not (Test-AVDTuneReleaseUrl $current)) { throw 'Refused: a redirect leads to an address that is not https on an allowed GitHub host.' }
        $req = [Net.HttpWebRequest]::Create($current)
        $req.AllowAutoRedirect = $false; $req.Method = 'GET'; $req.Timeout = 30000; $req.ReadWriteTimeout = 30000; $req.UserAgent = 'AVDTune'
        $req.Proxy = [Net.WebRequest]::GetSystemWebProxy(); $req.Proxy.Credentials = [Net.CredentialCache]::DefaultCredentials
        $resp = $null
        try { $resp = $req.GetResponse() } catch [Net.WebException] { $resp = $_.Exception.Response; if (-not $resp) { throw "No connection to $(([Uri]$current).Host): $($_.Exception.Message)" } }
        try {
            $code = [int]$resp.StatusCode
            if ($code -in 301, 302, 303, 307, 308) {
                $loc = [string]$resp.Headers['Location']
                if (-not $loc) { throw 'Redirect without a target.' }
                $current = (New-Object Uri ([Uri]$current), $loc).AbsoluteUri
                continue
            }
            if ($code -ne 200) { throw "GitHub answered $code ($(([Uri]$current).Host))." }
            if ($resp.ContentLength -gt $MaxBytes) { throw 'The download is larger than allowed.' }
            $in = $resp.GetResponseStream()
            $out = if ($Path) { [IO.File]::Open($Path, 'Create', 'Write', 'None') } else { New-Object IO.MemoryStream }
            try {
                $buffer = New-Object byte[] 81920; $total = [int64]0
                while (($n = $in.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $total += $n; if ($total -gt $MaxBytes) { throw 'The download is larger than allowed.' }
                    $out.Write($buffer, 0, $n)
                }
                if (-not $Path) { return [Text.Encoding]::UTF8.GetString($out.ToArray()) }
                return
            }
            finally { $out.Dispose(); $in.Dispose() }
        }
        finally { $resp.Close() }
    }
    throw 'Too many redirects.'
}

function New-AVDTuneReleaseHttp {
    # The real HTTP adapter. GetText(url, maxBytes) -> string; GetFile(url, path, maxBytes)
    $h = [ordered]@{ Kind = 'Real' }
    $h.GetText = { param($Url, $MaxBytes) Invoke-AVDTuneHttpDownload -Url $Url -MaxBytes $MaxBytes }
    $h.GetFile = { param($Url, $Path, $MaxBytes) Invoke-AVDTuneHttpDownload -Url $Url -MaxBytes $MaxBytes -Path $Path }
    $h
}

#endregion

#region install layout

function Get-AVDTuneInstallRoot { Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'AVDTune' }

function Get-AVDTuneInstallState {
    # current.json of the install folder: Version, Previous ('' when none). $null when there is none yet.
    param([Parameter(Mandatory)][string]$InstallRoot)
    $cur = $null
    try { $cur = Read-AVDTuneJson (Join-Path $InstallRoot 'current.json') } catch { return $null }
    if (-not $cur) { return $null }
    $v = [string](Get-AVDTuneProp $cur 'Version'); $p = [string](Get-AVDTuneProp $cur 'Previous')
    if (-not (Test-AVDTuneReleaseVersion $v)) { return $null }
    if ($p -and -not (Test-AVDTuneReleaseVersion $p)) { $p = '' }
    [pscustomobject]@{ Version = $v; Previous = $p }
}

function Set-AVDTuneInstallState([string]$InstallRoot, [string]$Version, [string]$Previous) {
    Write-AVDTuneFile (Join-Path $InstallRoot 'current.json') ([ordered]@{ Schema = 1; Version = $Version; Previous = $Previous } | ConvertTo-Json)
}

$script:LauncherText = @'
# AVDTune launcher. Written by AVDTune, not part of a release: starts the version named in current.json (one level up from the version folders).
$ErrorActionPreference = 'Stop'
$current = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'current.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]$current.Version -notmatch '^\d+\.\d+\.\d+(-ea\.\d+)?\z') { throw 'current.json does not name a valid version.' }
& (Join-Path $PSScriptRoot "$($current.Version)\Start-AVDTune.ps1") @args
'@

function Write-AVDTuneLauncher([string]$InstallRoot) {
    $path = Join-Path $InstallRoot 'Start-AVDTune.ps1'
    if ((Test-Path -LiteralPath $path) -and ([IO.File]::ReadAllText($path) -ceq $script:LauncherText)) { return }
    Write-AVDTuneFile $path $script:LauncherText
}

function Get-AVDTuneInstallInfo {
    <#
        Where is this copy running? A folder directly below the install folder is always Installed, and its version is the name of the folder (whatever a
        VERSION file or a .git inside says is checked against the manifest as a changed or extra file). Anything else is Unprotected (a copy elsewhere), or
        Development (a git checkout) when the caller allows it: only the test mode with the fake machine does.
    #>
    param([Parameter(Mandatory)][string]$AppRoot, [Parameter(Mandatory)][string]$InstallRoot, [switch]$AllowDevelopment)
    $app = [IO.Path]::GetFullPath($AppRoot).TrimEnd('\')
    $parent = (Split-Path $app -Parent).TrimEnd('\')
    $installRoot = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
    $leaf = Split-Path $app -Leaf
    if ([string]::Equals($parent, $installRoot, [StringComparison]::OrdinalIgnoreCase)) {
        $mode = 'Installed'; $version = $(if (Test-AVDTuneReleaseVersion $leaf) { $leaf } else { '' })
    }
    else {
        $version = Get-AVDTuneToolVersion $app
        $mode = $(if ($AllowDevelopment -and (Test-Path -LiteralPath (Join-Path $app '.git'))) { 'Development' } else { 'Unprotected' })
    }
    [pscustomobject]@{ Mode = $mode; Version = $version; AppRoot = $app; InstallRoot = $installRoot }
}

function Set-AVDTuneReleaseAclReader([scriptblock]$Reader) { $script:AclReader = $Reader }

function Test-AVDTuneRealInstallRoot([string]$InstallRoot) {
    [string]::Equals([IO.Path]::GetFullPath($InstallRoot).TrimEnd('\'), (Get-AVDTuneInstallRoot).TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)
}

function Get-AVDTuneAclProblems {
    # What a user without administrator rights could have prepared in a folder (owner, explicit allow rules for others, links; same rules as the state folder)
    param([Parameter(Mandatory)][string]$Folder, [switch]$Enforce)
    if (-not ($Enforce -or $script:AclReader)) { return @() }
    $p = @{ Root = $Folder }
    if ($script:AclReader) { $p.ReadAcl = $script:AclReader; $p.AdminSid = '' }
    @(Get-AVDTuneStateSecurityProblems @p)
}

function New-AVDTuneInstallFolder([string]$Path, [string]$InstallRoot) {
    # A new folder below the install folder: with the protected ACL (administrators and SYSTEM only) in one step in the real install folder
    if (Test-AVDTuneRealInstallRoot $InstallRoot) { (New-Object IO.DirectoryInfo $Path).Create((New-AVDTuneStateSecurity -WithOwner)) }
    else { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
}

function Remove-AVDTuneLink([string]$Path) {
    # A link is removed as a link (never what it points to)
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.PSIsContainer) { [IO.Directory]::Delete($Path) } else { $item.Delete() }
}

function Assert-AVDTuneNoLinkInPath {
    # Every component of Base\Rel that exists must not be a link
    param([Parameter(Mandatory)][string]$Base, [Parameter(Mandatory)][string]$Rel)
    $cur = $Base
    foreach ($part in ($Rel -split '/')) {
        $cur = Join-Path $cur $part
        $attr = $null; try { $attr = [IO.File]::GetAttributes($cur) } catch { continue }
        if ($attr -band [IO.FileAttributes]::ReparsePoint) { throw "A part of the path $Rel is a link: stopped." }
    }
}

#endregion

#region integrity

function Get-AVDTuneTreeFiles {
    # Every file and folder below a folder (relative path with /), links are reported and not followed. Returns Files, Dirs and Links.
    param([Parameter(Mandatory)][string]$Folder)
    $files = New-Object System.Collections.ArrayList; $links = New-Object System.Collections.ArrayList; $dirs = New-Object System.Collections.ArrayList
    $base = [IO.Path]::GetFullPath($Folder).TrimEnd('\')
    $stack = New-Object System.Collections.Stack; $stack.Push($base)
    while ($stack.Count -gt 0) {
        $dir = [string]$stack.Pop()
        foreach ($e in (New-Object IO.DirectoryInfo $dir).EnumerateFileSystemInfos()) {
            $rel = $e.FullName.Substring($base.Length + 1).Replace('\', '/')
            if ($e.Attributes -band [IO.FileAttributes]::ReparsePoint) { [void]$links.Add($rel); continue }
            if ($e.Attributes -band [IO.FileAttributes]::Directory) { [void]$dirs.Add($rel); $stack.Push($e.FullName) } else { [void]$files.Add($rel) }
        }
    }
    [pscustomobject]@{ Files = @($files); Dirs = @($dirs); Links = @($links) }
}

function Test-AVDTuneIntegrity {
    # The folder against the manifest: Missing, Changed (size or SHA256, or a link in the place of a file), Extra (not in the manifest, links included)
    param([Parameter(Mandatory)][string]$AppRoot, [Parameter(Mandatory)]$Manifest)
    $tree = Get-AVDTuneTreeFiles $AppRoot
    $actual = @{}; foreach ($f in $tree.Files) { $actual[$f.ToLowerInvariant()] = $f }
    $linkSet = @{}; foreach ($l in $tree.Links) { $linkSet[$l.ToLowerInvariant()] = $l }
    $missing = New-Object System.Collections.ArrayList; $changed = New-Object System.Collections.ArrayList; $expected = @{}
    foreach ($f in @($Manifest.Files)) {
        $key = ([string]$f.Path).ToLowerInvariant(); $expected[$key] = $true
        if ($linkSet.ContainsKey($key)) { [void]$changed.Add([string]$f.Path); continue }
        if (-not $actual.ContainsKey($key)) { [void]$missing.Add([string]$f.Path); continue }
        $full = Join-Path ([IO.Path]::GetFullPath($AppRoot)) ($actual[$key].Replace('/', '\'))
        $item = New-Object IO.FileInfo $full
        if ($item.Length -ne [int64]$f.Size) { [void]$changed.Add([string]$f.Path); continue }
        try { if ((Get-AVDTuneFileSha256 $full) -ne [string]$f.Sha256) { [void]$changed.Add([string]$f.Path) } } catch { [void]$changed.Add([string]$f.Path) }
    }
    $extra = @($tree.Files + $tree.Links | Where-Object { -not $expected.ContainsKey($_.ToLowerInvariant()) } | Sort-Object)
    [pscustomobject]@{ Ok = ($missing.Count -eq 0 -and $changed.Count -eq 0 -and $extra.Count -eq 0); Missing = @($missing); Changed = @($changed); Extra = @($extra) }
}

function Get-AVDTuneIntegrityStatus {
    <#
        The check at every start. Status: ok (all files as released), bad (missing, changed or extra files, a changed launcher, or an install folder that others
        could write to), unverified (Installed, but no manifest from GitHub and none cached), unprotected (a copy outside the install folder), dev (git checkout,
        only with -AllowDevelopment), failed (set by the caller). Blocked is true when AVDTune must stay read only: bad, unverified, and an unprotected copy that
        users without administrator rights can change. Does not change anything.
    #>
    param([Parameter(Mandatory)][string]$AppRoot, [Parameter(Mandatory)][string]$InstallRoot, [Parameter(Mandatory)][string]$StateRoot, [Parameter(Mandatory)]$Http, [switch]$AllowDevelopment)
    $info = Get-AVDTuneInstallInfo -AppRoot $AppRoot -InstallRoot $InstallRoot -AllowDevelopment:$AllowDevelopment
    $r = [ordered]@{ Status = ''; Mode = $info.Mode; Version = $info.Version; Commit = ''; Source = ''; Missing = @(); Changed = @(); Extra = @(); Acl = @(); Warnings = @(); Blocked = $false; Message = '' }
    if ($info.Mode -eq 'Development') { $r.Status = 'dev'; $r.Message = 'Development copy (git checkout, test mode): the files are not checked against a release.'; return [pscustomobject]$r }
    if ($info.Mode -eq 'Unprotected') {
        $problems = @(Get-AVDTuneAclProblems -Folder $info.AppRoot -Enforce)
        $r.Status = 'unprotected'; $r.Acl = @($problems | ForEach-Object { "$($_.Path): $($_.Problem)" })
        if ($problems.Count -gt 0) {
            $r.Blocked = $true
            $r.Message = "AVDTune runs from a copy outside the install folder ($($info.InstallRoot)\<version>) that users without administrator rights can change ($($r.Acl[0])). It stays read only: install the release into the protected folder."
        }
        else { $r.Message = "AVDTune does not run from the protected install folder ($($info.InstallRoot)\<version>): the files are not checked against a release. The folder is administrators only, so it may run; install the release to get the check." }
        return [pscustomobject]$r
    }
    # Installed
    $acl = @(Get-AVDTuneAclProblems -Folder $info.InstallRoot -Enforce:(Test-AVDTuneRealInstallRoot $info.InstallRoot) | ForEach-Object { "$($_.Path): $($_.Problem)" })
    $r.Acl = $acl
    if (-not $info.Version) {
        $r.Status = 'bad'; $r.Blocked = $true; $r.Message = "The folder $(Split-Path $info.AppRoot -Leaf) is not named like a version: AVDTune cannot tell which release to compare with. It stays read only."
        return [pscustomobject]$r
    }
    $m = Get-AVDTuneReleaseManifest -Http $Http -Version $info.Version -StateRoot $StateRoot
    if (-not $m.Manifest) {
        if ($acl.Count -gt 0) { $r.Status = 'bad'; $r.Blocked = $true; $r.Message = "The install folder is not protected ($($acl[0])). AVDTune stays read only."; return [pscustomobject]$r }
        $r.Status = 'unverified'; $r.Blocked = $true
        $r.Message = "The files of version $($info.Version) could not be compared: no manifest from GitHub and none cached ($($m.Error)) AVDTune is read only until the manifest can be loaded."
        return [pscustomobject]$r
    }
    $warn = New-Object System.Collections.ArrayList
    $use = $m.Manifest
    if ($m.Source -eq 'github' -and $m.Cached -and ([string]$m.Cached.Commit -ne [string]$m.Manifest.Commit -or [string]$m.Cached.Zip.Sha256 -ne [string]$m.Manifest.Zip.Sha256)) {
        # The release was published again under the same version: the manifest from the time of the install stays the reference
        $use = $m.Cached; $r.Source = 'cache'
        [void]$warn.Add("The manifest on GitHub for version $($info.Version) differs from the one saved at install time (other commit or ZIP). The saved one is used. Somebody published this version again.")
    }
    else {
        $r.Source = $m.Source
        if ($m.Source -eq 'cache') { [void]$warn.Add("GitHub could not be reached ($($m.Error)): compared with the saved manifest.") }
        elseif (-not $m.Cached) { try { Save-AVDTuneManifestCache $StateRoot $m.Manifest } catch { } }
    }
    $r.Commit = [string]$use.Commit
    $t = Test-AVDTuneIntegrity -AppRoot $info.AppRoot -Manifest $use
    $changed = New-Object System.Collections.ArrayList; foreach ($c in $t.Changed) { [void]$changed.Add($c) }
    # the launcher in the install folder is not part of a release: it is written by AVDTune and must be exactly what AVDTune writes
    $launcher = Join-Path $info.InstallRoot 'Start-AVDTune.ps1'
    if (Test-Path -LiteralPath $launcher -PathType Leaf) { if ([IO.File]::ReadAllText($launcher) -cne $script:LauncherText) { [void]$changed.Add('../Start-AVDTune.ps1 (launcher)') } }
    elseif (Test-Path -LiteralPath $launcher) { [void]$changed.Add('../Start-AVDTune.ps1 (launcher)') }
    $r.Missing = @($t.Missing); $r.Changed = @($changed); $r.Extra = @($t.Extra); $r.Warnings = @($warn)
    if ($t.Ok -and $changed.Count -eq 0 -and $acl.Count -eq 0) { $r.Status = 'ok'; $r.Message = "All $(@($use.Files).Count) files are as released in version $($info.Version) (commit $(([string]$use.Commit).Substring(0, 7)))." }
    else {
        $r.Status = 'bad'; $r.Blocked = $true
        $r.Message = "The files of AVDTune do not match release $($info.Version): $($r.Missing.Count) missing, $($r.Changed.Count) changed, $($r.Extra.Count) extra" + $(if ($acl.Count -gt 0) { "; the install folder is not protected ($($acl[0]))" }) + '. AVDTune is read only until it is repaired.'
    }
    [pscustomobject]$r
}

function Set-AVDTuneIntegrityBlock {
    # Applies a status to this process: a blocked or failed one keeps the write gate shut; anything else lifts the "check running" block of the start
    param([Parameter(Mandatory)]$Status)
    if ($Status.Status -in 'bad', 'failed' -or (Get-AVDTuneProp $Status 'Blocked')) { Set-AVDTuneWriteBlock ([string]$Status.Message) } else { Clear-AVDTuneWriteBlock }
}

function Confirm-AVDTuneUnverified {
    # "Continue without the check": only with the typed name of this computer; written to the change log (when there is an image version), the caller writes the protocol
    param([Parameter(Mandatory)][string]$StateRoot, [string]$Name, [Parameter(Mandatory)][string]$Expected, [string]$User)
    if (-not $Name -or ([string]$Name).Trim() -cne $Expected) { throw "Type the name of this computer ($Expected) to continue without the check." }
    $text = 'AVDTune continued without the integrity check of its files (no manifest from GitHub and none cached); confirmed by typing the computer name.'
    $logged = Write-AVDTuneReleaseLog -StateRoot $StateRoot -Text $text -User $User -ChangeType Note
    Clear-AVDTuneWriteBlock
    [pscustomobject]@{ Text = $text; ChangeLog = $logged }
}

#endregion

#region measure program (issue #19)

function Get-AVDTuneChainAclProblems {
    # The file and every folder above it up to the install folder: not a link, owner Administrators or SYSTEM (below the install folder also the elevated administrator
    # running AVDTune), no explicit allow rule for anyone else. Same standard as the install folder check (Get-AVDTuneAclProblems). Empty = fine.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$InstallRoot)
    $reader = $script:AclReader
    if (-not $reader) { $reader = { param($P, $IsDirectory) Read-AVDTuneAclInfo -Path $P -IsDirectory $IsDirectory } }
    $trusted = @('S-1-5-32-544', 'S-1-5-18')
    $adminSid = ''
    if (-not $script:AclReader -and (Test-AVDTuneElevated)) { $adminSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
    $root = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
    $cur = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $problems = New-Object System.Collections.ArrayList
    $isDir = $false
    while ($true) {
        $attr = $null; try { $attr = [IO.File]::GetAttributes($cur) } catch { [void]$problems.Add("$cur cannot be read: $($_.Exception.Message)") }
        if ($null -ne $attr -and ($attr -band [IO.FileAttributes]::ReparsePoint)) { [void]$problems.Add("$cur is a link") }
        $acl = $null
        try { $acl = & $reader $cur $isDir } catch { [void]$problems.Add("ACL of $cur cannot be read: $($_.Exception.Message)") }
        if ($acl) {
            $owners = @($trusted); if ($adminSid -and $cur -ine $root) { $owners += $adminSid }
            if ([string]$acl.Owner -notin $owners) { [void]$problems.Add("owner of $cur is $($acl.Owner)") }
            $foreign = @($acl.Rules | Where-Object { $_.Sid -notin $trusted -and -not $_.Inherited } | ForEach-Object { $_.Sid } | Sort-Object -Unique)
            if ($foreign.Count -gt 0) { [void]$problems.Add("access for $($foreign -join ', ') on $cur") }
        }
        if ($cur -ieq $root) { break }
        $parent = [IO.Path]::GetDirectoryName($cur)
        if (-not $parent -or $parent -ieq $cur) { [void]$problems.Add("$Path is not below the install folder"); break }
        $cur = $parent; $isDir = $true
    }
    @($problems)
}

function Open-AVDTuneVerifiedBenchExe {
    <#
        The only way to get at AVDTune.Bench.exe (issue #19, plan 9a). Returns Path, Version, Size, Sha256 and Stream: the file held open for reading with
        FileShare.Read (nobody can write to it, delete it or rename it, nor the folders above it, while it is held). The caller starts the process while the
        stream is open and disposes it afterwards; Windows still loads the program (read and execute are shared). Everything is checked on the held file:
          * the copy of AVDTune runs from <install folder>\<version> (not a development checkout, not an unprotected copy);
          * the manifest of this version (saved at install time, or -Manifest) has a Bench entry; no entry = no start;
          * the file and every folder up to the install folder are administrators only, no links;
          * size and SHA256 of the held file equal the manifest entry. No match = no start.
        Throws with a plain reason; there is no fallback to a program found elsewhere. The checks use a temporary install folder only together with AVDTUNE_FAKE
        (the test mode) and a fake ACL reader (Set-AVDTuneReleaseAclReader).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$AppRoot, [Parameter(Mandatory)][string]$InstallRoot, [Parameter(Mandatory)][string]$StateRoot, $Manifest)
    $real = Test-AVDTuneRealInstallRoot $InstallRoot
    if (-not $real -and -not $env:AVDTUNE_FAKE) { throw 'AVDTune.Bench.exe only starts from the install folder of AVDTune.' }
    $info = Get-AVDTuneInstallInfo -AppRoot $AppRoot -InstallRoot $InstallRoot
    if ($info.Mode -ne 'Installed' -or -not $info.Version) {
        throw "AVDTune.Bench.exe only starts from the protected install folder ($($info.InstallRoot)\<version>), and this copy of AVDTune runs from $($info.AppRoot). Install a release; a development checkout or a copy elsewhere cannot run the measure program."
    }
    if (-not $Manifest) { $Manifest = (Get-AVDTuneReleaseManifest -Version $info.Version -StateRoot $StateRoot -CacheOnly).Manifest }
    if (-not $Manifest) { throw "No release manifest of version $($info.Version) is saved on this computer, so AVDTune.Bench.exe cannot be checked and is not started. Start AVDTune once with access to GitHub (or repair the install)." }
    $Manifest = Assert-AVDTuneManifest -Manifest $Manifest -Version $info.Version
    $entry = Get-AVDTuneProp $Manifest 'Bench'
    if ($null -eq $entry) { throw "The release manifest of version $($info.Version) has no entry for AVDTune.Bench.exe: this release does not carry a checked measure program, so the benchmark does not start. Update AVDTune to a release that has one." }
    $rel = [string]$entry.Path
    Assert-AVDTuneNoLinkInPath -Base $info.AppRoot -Rel $rel
    $full = Join-Path $info.AppRoot $rel.Replace('/', '\')
    $stream = $null
    try {
        try { $stream = [IO.File]::Open($full, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read) }
        catch { throw "AVDTune.Bench.exe cannot be opened ($full): $($_.Exception.Message)" }
        if ($real -or $script:AclReader) {
            $problems = @(Get-AVDTuneChainAclProblems -Path $full -InstallRoot $info.InstallRoot)
            if ($problems.Count -gt 0) { throw "AVDTune.Bench.exe is not in a protected folder ($($problems[0])). It is not started." }
        }
        # nothing but the exe next to it (no DLL to side-load); checked while the exe is held, so the folder cannot be refilled between check and start
        $binDir = New-Object IO.DirectoryInfo (Split-Path $full -Parent)
        $others = @($binDir.GetFileSystemInfos() | Where-Object { $_.Name -ine (Split-Path $full -Leaf) } | ForEach-Object Name)
        if ($others.Count -gt 0) { throw "The folder of AVDTune.Bench.exe holds more than the exe ($($others -join ', ')). It is not started." }
        if ($stream.Length -ne [int64]$entry.Size) { throw "AVDTune.Bench.exe does not have the size in the release manifest of version $($info.Version) ($($stream.Length) instead of $($entry.Size) bytes). It is not started." }
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $hash = ([BitConverter]::ToString($sha.ComputeHash($stream)) -replace '-', '').ToLowerInvariant() } finally { $sha.Dispose() }
        if ($hash -cne [string]$entry.Sha256) { throw "AVDTune.Bench.exe does not match the SHA256 in the release manifest of version $($info.Version) (expected $(([string]$entry.Sha256).Substring(0, 12)) ..., found $($hash.Substring(0, 12)) ...). It is not started." }
        $stream.Position = 0
        [pscustomobject]@{ Path = $full; Version = $info.Version; Size = $stream.Length; Sha256 = $hash; Stream = $stream }
    }
    catch { if ($stream) { $stream.Dispose() }; throw }
}

#endregion

#region settings and update check

function Get-AVDTuneReleaseSettings([string]$StateRoot) {
    $s = $null; try { $s = Read-AVDTuneJson (Join-Path $StateRoot 'config\release.json') } catch { }
    [pscustomobject]@{ EarlyAccess = [bool]($s -and (Get-AVDTuneProp $s 'EarlyAccess')) }
}
function Set-AVDTuneReleaseSettings([string]$StateRoot, [bool]$EarlyAccess) {
    Write-AVDTuneFile (Join-Path $StateRoot 'config\release.json') ([ordered]@{ EarlyAccess = $EarlyAccess } | ConvertTo-Json)
    Get-AVDTuneReleaseSettings $StateRoot
}

function Get-AVDTuneLatestRelease {
    <#
        Newest release: stable only, or with early access (x.y.z-ea.N). Found through the releases feed (github.com), then its manifest (release notes in it).
        Returns Version, Manifest, Notes, Date, Prerelease, Newer (newer than CurrentVersion); $null when there is no release.
    #>
    param([Parameter(Mandatory)]$Http, [Parameter(Mandatory)][string]$CurrentVersion, [switch]$EarlyAccess)
    $url = Get-AVDTuneReleaseFeedUrl
    $feed = Invoke-AVDTuneHttp { & $Http.GetText $url $script:MaxManifestBytes } $url
    $versions = @([regex]::Matches($feed, '/releases/tag/v(\d+\.\d+\.\d+(?:-ea\.\d+)?)["<]') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique |
            Where-Object { $EarlyAccess -or -not $_.Contains('-') })
    if ($versions.Count -eq 0) { return $null }
    $best = $versions[0]
    foreach ($v in $versions) { if ((Compare-AVDTuneReleaseVersion $v $best) -gt 0) { $best = $v } }
    $murl = Get-AVDTuneReleaseUrl -Version $best -Name 'manifest.json'
    $manifest = ConvertFrom-AVDTuneManifestText (Invoke-AVDTuneHttp { & $Http.GetText $murl $script:MaxManifestBytes } $murl) $best
    [pscustomobject]@{
        Version = $best; Manifest = $manifest; Notes = [string](Get-AVDTuneProp $manifest 'Notes'); Date = [string]$manifest.Date
        Prerelease = $best.Contains('-'); Newer = ((Compare-AVDTuneReleaseVersion $best $CurrentVersion) -gt 0)
    }
}

#endregion

#region install, repair, rollback

function Assert-AVDTuneUpdateAllowed {
    # Never during a run, never in maintenance mode (also when the state cannot be read: then nobody can tell)
    param([Parameter(Mandatory)][string]$StateRoot, [switch]$RunActive)
    if ($RunActive) { throw 'A run is active. Wait until it is done.' }
    $state = $null
    try { $state = Get-AVDTuneState $StateRoot } catch { throw "The state could not be read, so it is not known whether a run or the maintenance mode is active: $($_.Exception.Message)" }
    $maint = Get-AVDTuneProp $state 'Maintenance'
    if (($maint -and (Get-AVDTuneProp $maint 'Active')) -or [string](Get-AVDTuneProp $state 'UpdateBlock') -eq 'Maintenance') {
        throw 'The maintenance mode is active (or did not end properly). Finish or repair it first; the tool is not changed during it.'
    }
}

function Assert-AVDTuneInstallRootSafe([string]$InstallRoot) {
    # The install folder is AVDTune's own: not a link, administrators only (owner, no write access for others, no links inside), created protected when missing
    $real = Test-AVDTuneRealInstallRoot $InstallRoot
    if ($real -and -not (Test-AVDTuneElevated)) { throw 'The install folder can only be changed as administrator.' }
    if (-not (Test-Path -LiteralPath $InstallRoot -PathType Container)) {
        if ($real) { (New-Object IO.DirectoryInfo $InstallRoot).Create((New-AVDTuneStateSecurity -WithOwner)) } else { New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null }
    }
    $item = Get-Item -LiteralPath $InstallRoot -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "The install folder $InstallRoot is a link." }
    $problems = @(Get-AVDTuneAclProblems -Folder $InstallRoot -Enforce:$real)
    if ($problems.Count -gt 0) { throw "The install folder is not protected ($(@($problems | Select-Object -First 3 | ForEach-Object { "$($_.Path): $($_.Problem)" }) -join '; ')). Set the owner to Administrators, remove the access of others and links, then try again." }
}

function Expand-AVDTuneReleaseZip {
    <#
        Extracts a ZIP into an empty target, entry by entry, only what the manifest lists: an entry that is not listed, listed twice, a path that leaves the
        target (Zip-Slip: "..", drive, rooted, backslash), a size or SHA256 that differs, or a listed file that is missing stops everything.
    #>
    param([Parameter(Mandatory)][string]$ZipPath, [Parameter(Mandatory)]$Manifest, [Parameter(Mandatory)][string]$Target)
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $expected = @{}; foreach ($f in @($Manifest.Files)) { $expected[([string]$f.Path).ToLowerInvariant()] = $f }
    $targetFull = [IO.Path]::GetFullPath($Target).TrimEnd('\') + '\'
    if (-not (Test-Path -LiteralPath $Target)) { New-Item -ItemType Directory -Path $Target | Out-Null }
    $seen = @{}
    $zip = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        foreach ($entry in $zip.Entries) {
            $name = [string]$entry.FullName
            if ($name.EndsWith('/') -and $entry.Length -eq 0) { continue }   # a folder entry
            if (-not (Test-AVDTuneSafeRelativePath $name)) { throw "The ZIP contains an unsafe path ('$name'): refused (path outside the target)." }
            $dest = [IO.Path]::GetFullPath((Join-Path $targetFull $name.Replace('/', '\')))
            if (-not $dest.StartsWith($targetFull, [StringComparison]::OrdinalIgnoreCase)) { throw "The ZIP contains a path that leaves the target ('$name'): refused." }
            $key = $name.ToLowerInvariant()
            if (-not $expected.ContainsKey($key)) { throw "The ZIP contains a file that the manifest does not list ('$name')." }
            if ($seen.ContainsKey($key)) { throw "The ZIP contains '$name' twice." }
            $seen[$key] = $true
            $want = $expected[$key]
            if ($entry.Length -ne [int64]$want.Size) { throw "'$name' in the ZIP has another size than the manifest says." }
            $folder = Split-Path $dest -Parent
            if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
            $sha = [Security.Cryptography.SHA256]::Create()
            $in = $entry.Open(); $out = [IO.File]::Open($dest, 'CreateNew', 'Write', 'None')
            try {
                $buffer = New-Object byte[] 81920; $total = [int64]0
                while (($n = $in.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $total += $n; if ($total -gt [int64]$want.Size) { throw "'$name' in the ZIP is larger than the manifest says." }
                    $out.Write($buffer, 0, $n); [void]$sha.TransformBlock($buffer, 0, $n, $null, 0)
                }
                [void]$sha.TransformFinalBlock((New-Object byte[] 0), 0, 0)
            }
            finally { $out.Dispose(); $in.Dispose() }
            $hash = ([BitConverter]::ToString($sha.Hash) -replace '-', '').ToLowerInvariant(); $sha.Dispose()
            if ($hash -ne [string]$want.Sha256) { throw "'$name' in the ZIP does not match its SHA256 in the manifest." }
        }
    }
    finally { $zip.Dispose() }
    $absent = @($expected.Keys | Where-Object { -not $seen.ContainsKey($_) })
    if ($absent.Count -gt 0) { throw "The ZIP lacks $($absent.Count) file(s) of the manifest (for example '$($absent[0])')." }
    $seen.Count
}

function Get-AVDTuneVerifiedZip {
    # Downloads the ZIP of the manifest into a staging folder and checks size and SHA256 of the ZIP; returns the extracted, verified tree folder
    param([Parameter(Mandatory)]$Http, [Parameter(Mandatory)]$Manifest, [Parameter(Mandatory)][string]$Staging)
    $zipPath = Join-Path $Staging 'release.zip'
    $url = Get-AVDTuneReleaseUrl -Version ([string]$Manifest.Version) -Name ([string]$Manifest.Zip.Name)
    Invoke-AVDTuneHttp { & $Http.GetFile $url $zipPath $script:MaxZipBytes } $url
    $info = New-Object IO.FileInfo $zipPath
    if (-not $info.Exists -or $info.Length -ne [int64]$Manifest.Zip.Size) { throw 'The downloaded ZIP has another size than the manifest says.' }
    if ((Get-AVDTuneFileSha256 $zipPath) -ne [string]$Manifest.Zip.Sha256) { throw 'The downloaded ZIP does not match its SHA256 in the manifest.' }
    $tree = Join-Path $Staging 'files'
    [void](Expand-AVDTuneReleaseZip -ZipPath $zipPath -Manifest $Manifest -Target $tree)
    $check = Test-AVDTuneIntegrity -AppRoot $tree -Manifest $Manifest
    if (-not $check.Ok) { throw "The extracted files do not match the manifest ($($check.Missing.Count) missing, $($check.Changed.Count) changed, $($check.Extra.Count) extra)." }
    $tree
}

function Write-AVDTuneReleaseLog {
    # One change log entry (tool version is part of every entry) when there is an image version; the protocol text goes back to the caller
    param([string]$StateRoot, [string]$Text, [string]$User, [string]$ChangeType = 'Updated')
    $logged = $false
    try {
        $state = Get-AVDTuneState $StateRoot
        $iv = [string](Get-AVDTuneProp $state 'ImageVersion')
        if ($iv) { [void](Add-AVDTuneChangeLogEntry -Root $StateRoot -Version $iv -Category 'Tool' -Component 'AVDTune' -ChangeType $ChangeType -Text $Text -User $User -Source Step); $logged = $true }
    }
    catch { }
    $logged
}

function Install-AVDTuneRelease {
    <#
        Side by side into <InstallRoot>\<version>, then switch (current.json), the previous version stays. Nothing is switched unless every check passed.
        Returns Version, Previous, ChangeLog (written or not), Text (for the protocol).
    #>
    param([Parameter(Mandatory)]$Http, [Parameter(Mandatory)]$Manifest, [Parameter(Mandatory)][string]$InstallRoot, [Parameter(Mandatory)][string]$StateRoot,
        [string]$User, [switch]$RunActive, [string]$RunningVersion)
    Assert-AVDTuneUpdateAllowed -StateRoot $StateRoot -RunActive:$RunActive
    $manifest = Assert-AVDTuneManifest -Manifest $Manifest
    $version = [string]$manifest.Version
    Assert-AVDTuneInstallRootSafe $InstallRoot
    $target = Join-Path $InstallRoot $version
    $staging = Join-Path $InstallRoot ('.staging-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $createdTarget = $false; $switched = $false
    try {
        New-AVDTuneInstallFolder $staging $InstallRoot
        $targetDir = New-Object IO.DirectoryInfo $target
        if ($targetDir.Exists -and ($targetDir.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "The folder $target is a link." }
        if (Test-Path -LiteralPath $target) {
            $existing = Test-AVDTuneIntegrity -AppRoot $target -Manifest $manifest
            if (-not $existing.Ok) { throw "The folder $target exists and does not match the release. Repair it from the running version or remove it, then try again." }
        }
        else {
            $tree = Get-AVDTuneVerifiedZip -Http $Http -Manifest $manifest -Staging $staging
            [IO.Directory]::Move($tree, $target); $createdTarget = $true
        }
        Save-AVDTuneManifestCache $StateRoot $manifest
        Write-AVDTuneLauncher $InstallRoot
        $cur = Get-AVDTuneInstallState $InstallRoot
        $previous = ''
        if ($cur -and $cur.Version -ne $version) { $previous = $cur.Version }
        elseif ($cur) { $previous = $cur.Previous }
        elseif ($RunningVersion -and $RunningVersion -ne $version -and (Test-Path -LiteralPath (Join-Path $InstallRoot $RunningVersion))) { $previous = $RunningVersion }
        Set-AVDTuneInstallState $InstallRoot $version $previous
        $switched = $true
    }
    finally {
        try { Remove-AVDTuneFolderNoFollow $staging } catch { }
        if ($createdTarget -and -not $switched) { try { Remove-AVDTuneFolderNoFollow $target } catch { } }
    }
    # keep the new and the previous version, remove older ones (only folders that are named like a version)
    foreach ($d in @(Get-ChildItem -LiteralPath $InstallRoot -Directory -Force | Where-Object { (Test-AVDTuneReleaseVersion $_.Name) -and $_.Name -ne $version -and $_.Name -ne $previous })) {
        try { Remove-AVDTuneFolderNoFollow $d.FullName } catch { }   # a link is removed as a link, nothing is followed
    }
    $short = ([string]$manifest.Commit).Substring(0, 7)
    $text = "AVDTune $version installed side by side" + $(if ($previous) { " (previous version $previous kept)" }) + ", commit $short, ZIP and every file checked against the SHA256 of the release manifest. Takes effect at the next start of AVDTune."
    $logged = Write-AVDTuneReleaseLog -StateRoot $StateRoot -Text $text -User $User
    [pscustomobject]@{ Version = $version; Previous = $previous; ChangeLog = $logged; Text = $text }
}

function Undo-AVDTuneRelease {
    # "Back to the previous version": checks the previous folder against its saved manifest, then switches; the version left stays as the next "previous"
    param([Parameter(Mandatory)][string]$InstallRoot, [Parameter(Mandatory)][string]$StateRoot, [string]$User, [switch]$RunActive)
    Assert-AVDTuneUpdateAllowed -StateRoot $StateRoot -RunActive:$RunActive
    $cur = Get-AVDTuneInstallState $InstallRoot
    if (-not $cur -or -not $cur.Previous) { throw 'There is no previous version to go back to.' }
    $dir = Join-Path $InstallRoot $cur.Previous
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { throw "The folder of the previous version $($cur.Previous) is gone." }
    $m = Get-AVDTuneReleaseManifest -Http $null -Version $cur.Previous -StateRoot $StateRoot -CacheOnly
    if (-not $m.Manifest) { throw "No saved manifest for version $($cur.Previous): it cannot be checked, so AVDTune does not switch to it." }
    $t = Test-AVDTuneIntegrity -AppRoot $dir -Manifest $m.Manifest
    if (-not $t.Ok) { throw "The previous version $($cur.Previous) does not match its release ($($t.Missing.Count) missing, $($t.Changed.Count) changed, $($t.Extra.Count) extra): not switched." }
    Set-AVDTuneInstallState $InstallRoot $cur.Previous $cur.Version
    $text = "AVDTune switched back from $($cur.Version) to $($cur.Previous) (files checked against the saved manifest). Takes effect at the next start of AVDTune."
    $logged = Write-AVDTuneReleaseLog -StateRoot $StateRoot -Text $text -User $User
    [pscustomobject]@{ Version = $cur.Previous; Previous = $cur.Version; ChangeLog = $logged; Text = $text }
}

function Repair-AVDTuneInstall {
    <#
        Loads the release of the version again, checks ZIP and files, then puts the files right in the running folder: links are removed first (as links), wrong
        or missing files are replaced (no path component may be a link), extra files removed. A file that is in use stays and is reported: restart AVDTune and
        repair again. The caller keeps AVDTune read only until it is started again, because the code that runs now was loaded from the files that were wrong.
    #>
    param([Parameter(Mandatory)]$Http, [Parameter(Mandatory)][string]$AppRoot, [Parameter(Mandatory)][string]$InstallRoot, [Parameter(Mandatory)][string]$StateRoot,
        [string]$User, [switch]$RunActive)
    Assert-AVDTuneUpdateAllowed -StateRoot $StateRoot -RunActive:$RunActive
    $info = Get-AVDTuneInstallInfo -AppRoot $AppRoot -InstallRoot $InstallRoot
    if ($info.Mode -ne 'Installed' -or -not $info.Version) { throw 'Repair works on the installed copy only (this copy is not in the install folder).' }
    Assert-AVDTuneInstallRootSafe $InstallRoot
    $appDir = New-Object IO.DirectoryInfo $info.AppRoot
    if (-not $appDir.Exists -or ($appDir.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "The program folder $($info.AppRoot) is missing or a link: it cannot be repaired in place." }
    $m = Get-AVDTuneReleaseManifest -Http $Http -Version $info.Version -StateRoot $StateRoot
    if (-not $m.Manifest) { throw "No manifest for version $($info.Version) ($($m.Error))." }
    $manifest = $m.Manifest
    if ($m.Source -eq 'github' -and $m.Cached -and [string]$m.Cached.Zip.Sha256 -ne [string]$manifest.Zip.Sha256) { $manifest = $m.Cached }   # the one of the install stays the reference
    $staging = Join-Path $InstallRoot ('.staging-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $failed = New-Object System.Collections.ArrayList; $fixed = 0
    try {
        New-AVDTuneInstallFolder $staging $InstallRoot
        $tree = Get-AVDTuneVerifiedZip -Http $Http -Manifest $manifest -Staging $staging
        # 1. links first (a link in the place of a folder hides what is below it)
        foreach ($rel in @((Get-AVDTuneTreeFiles $info.AppRoot).Links)) {
            try { Remove-AVDTuneLink (Join-Path $info.AppRoot $rel.Replace('/', '\')); $fixed++ } catch { [void]$failed.Add("$rel ($($_.Exception.Message))") }
        }
        $before = Test-AVDTuneIntegrity -AppRoot $info.AppRoot -Manifest $manifest
        # 2. wrong and missing files from the verified copy
        foreach ($rel in @($before.Missing) + @($before.Changed)) {
            $dest = Join-Path $info.AppRoot $rel.Replace('/', '\')
            try {
                Assert-AVDTuneNoLinkInPath -Base $info.AppRoot -Rel $rel
                $folder = Split-Path $dest -Parent; if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
                [IO.File]::Copy((Join-Path $tree $rel.Replace('/', '\')), $dest, $true); $fixed++
            }
            catch { [void]$failed.Add("$rel ($($_.Exception.Message))") }
        }
        # 3. extra files
        foreach ($rel in @($before.Extra)) {
            $path = Join-Path $info.AppRoot $rel.Replace('/', '\')
            try { Assert-AVDTuneNoLinkInPath -Base $info.AppRoot -Rel $rel; if (Test-Path -LiteralPath $path -PathType Leaf) { (Get-Item -LiteralPath $path -Force).Delete(); $fixed++ } }
            catch { [void]$failed.Add("$rel ($($_.Exception.Message))") }
        }
        # 4. folders that are empty now (own walk: links are not followed)
        foreach ($rel in @((Get-AVDTuneTreeFiles $info.AppRoot).Dirs | Sort-Object { $_.Length } -Descending)) {
            $d = New-Object IO.DirectoryInfo (Join-Path $info.AppRoot $rel.Replace('/', '\'))
            try { if ($d.Exists -and -not ($d.Attributes -band [IO.FileAttributes]::ReparsePoint) -and @($d.GetFileSystemInfos()).Count -eq 0) { $d.Delete() } } catch { }
        }
        Write-AVDTuneLauncher $InstallRoot
    }
    finally { try { Remove-AVDTuneFolderNoFollow $staging } catch { } }
    $after = Test-AVDTuneIntegrity -AppRoot $info.AppRoot -Manifest $manifest
    try { Save-AVDTuneManifestCache $StateRoot $manifest } catch { }
    $text = "AVDTune $($info.Version) repaired: $fixed file(s) put right from the release" + $(if (-not $after.Ok) { "; still wrong: $($after.Missing.Count + $after.Changed.Count + $after.Extra.Count) (restart AVDTune and repair again)" } else { ', all files match the release now' }) + '. Restart AVDTune.'
    $logged = Write-AVDTuneReleaseLog -StateRoot $StateRoot -Text $text -User $User
    [pscustomobject]@{ Ok = $after.Ok; Fixed = $fixed; Failed = @($failed); Remaining = $after; ChangeLog = $logged; Text = $text }
}

#endregion

Export-ModuleMember -Function Test-AVDTuneReleaseVersion, Compare-AVDTuneReleaseVersion, Test-AVDTuneReleaseUrl, Get-AVDTuneReleaseUrl, Get-AVDTuneReleaseFeedUrl,
    Test-AVDTuneSafeRelativePath, Get-AVDTuneFileSha256, Get-AVDTuneToolVersion, Assert-AVDTuneManifest, ConvertFrom-AVDTuneManifestText, Get-AVDTuneReleaseManifest,
    New-AVDTuneReleaseHttp, Get-AVDTuneInstallRoot, Get-AVDTuneInstallState, Get-AVDTuneInstallInfo, Test-AVDTuneIntegrity, Get-AVDTuneIntegrityStatus,
    Set-AVDTuneIntegrityBlock, Get-AVDTuneReleaseSettings, Set-AVDTuneReleaseSettings, Get-AVDTuneLatestRelease, Assert-AVDTuneUpdateAllowed,
    Expand-AVDTuneReleaseZip, Install-AVDTuneRelease, Undo-AVDTuneRelease, Repair-AVDTuneInstall, Write-AVDTuneLauncher, Set-AVDTuneReleaseAclReader, Confirm-AVDTuneUnverified, Assert-AVDTuneNoLinkInPath, Open-AVDTuneVerifiedBenchExe
