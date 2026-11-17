<#
    AVDTune Software: what is on the master, the winget / Chocolatey catalog and the PackTune library, and the runs that install, update and remove
    (docs\plans\avdtune.md, sections 3, 3c, 8; issue 31).

      Installed        Uninstall keys of HKLM (64 and 32 bit), read through the machine adapter; no program is started for it.
      Catalog          winget and Chocolatey: search, install, update, remove. Package ids, versions and search words are checked before they get
                       anywhere near a command line, and every argument is its own array element (never a string that is built and split).
      Library          the PackTune package store (SharePoint, Shared\PackTune-Store.ps1, never edited here) read with the Sites.Selected token of the
                       sign-in. READ ONLY: this module refuses every request that is not a GET. The trust anchor is Intune: the manifest hash in the
                       notes of the app (read with the Graph token); a package without an anchor is not installed. Only MSI packages are installed
                       here (msiexec with fixed switches); the recipe is never run.

    Every program (winget, choco, msiexec) is started with its full path from a fixed system place, inside the lock Global\PackTune (and, in the
    transition, Global\IntuneChocoDeployment, the name PackTune and its device scripts use), from a file that is held open without write/delete sharing while its Authenticode signature is
    checked and while it runs. A run needs the open write gate, sets LastChange (also when it fails), writes a run record (Plan 'Software') and a
    change log entry per package. The adapters are the update adapter $U of AVDTune.Updates.psm1 (tools, lock, process tree) and the machine adapter;
    the library has a context object with a replaceable GET (Tests\Check-Software.ps1 uses a fake SharePoint and a fake Intune).
#>

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'AVDTune.psm1')
Import-Module (Join-Path $PSScriptRoot 'AVDTune.Updates.psm1')
Import-Module (Join-Path $PSScriptRoot 'AVDTune.Trust.psm1')

$script:PackageIdPattern = '\A[A-Za-z0-9][A-Za-z0-9._+-]{0,127}\z'
$script:PackageVersionPattern = '\A[A-Za-z0-9][A-Za-z0-9._+-]{0,63}\z'
$script:SearchPattern = '\A[\p{L}\p{N}][\p{L}\p{N} ._+-]{0,63}\z'
$script:LibrarySitePattern = '\Ahttps://[A-Za-z0-9-]+\.sharepoint\.com/(sites|teams)/[A-Za-z0-9._-]+/?\z'
$script:LibraryNamePattern = '\A[A-Za-z0-9][A-Za-z0-9 ._-]{0,60}\z'
$script:SegmentPattern = '\A[A-Za-z0-9][A-Za-z0-9._-]{0,79}\z'   # the shared StoreSegment ends with $, which also lets a trailing line feed pass
$script:DefaultLibrary = 'PackTune Packages'
$script:GraphV1 = 'https://graph.microsoft.com/v1.0'
$script:MaxSearchRows = 30
$script:WingetNoUpgrade = -1978335189       # 0x8A15002B
$script:WingetAlreadyInstalled = -1978335135  # 0x8A150061
$script:WingetNotFound = -1978335212          # 0x8A150014 (no installed package matches)
$script:UninstallKeys = @(
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'; Arch = 'x64' }
    @{ Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'; Arch = 'x86' }
)

#region the package store of PackTune (shared code, loaded as it is)

# What Shared\PackTune-Store.ps1 reads from its host program: the library name and the folder of the protocols. Nothing else of PackTune-Main is used.
$script:Settings = @{ StoreLibrary = $script:DefaultLibrary; StoreSiteUrl = $null; StoreSiteName = $null; TenantID = ''; ClientID = '' }
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'Shared\PackTune-Store.ps1')
$script:ProtocolFolderName = 'Protocols'
$script:LibraryContext = $null

function Invoke-PackTuneStoreGraph {
    <#
        Replaces the store's own request function for AVDTune (the shared one is "replaceable": its comment says so). AVDTune only reads the library:
        GET, the Graph host, a checked path, no body. Downloads (-OutFile) follow the redirect to SharePoint by hand (Invoke-AVDTuneLibraryGet).
    #>
    param([string]$Method = 'GET', [string]$Path, [string]$Absolute, $Body, [string]$InFile, [byte[]]$Bytes, [string]$OutFile, [hashtable]$Headers = @{})
    if ($Method -ne 'GET' -or $null -ne $Body -or $InFile -or $Bytes -or $Absolute) { throw 'AVDTune reads the package store only: a request that writes or uploads is refused.' }
    if (-not $script:LibraryContext) { throw 'The package store is not open (internal: no library context).' }
    $max = 4MB
    if ($OutFile) {
        # downloads: manifest.json at most 1 MB; every other file at most the size the (already checked) manifest names; a file the manifest does not name gets 1 MB
        $leaf = ''; if ($Path -match '/([^/:]+):/content\z') { $leaf = [uri]::UnescapeDataString($Matches[1]) }
        $max = 1MB
        if ($leaf -ne 'manifest.json' -and $script:LibraryContext.Sizes.ContainsKey($leaf)) { $max = [int64]$script:LibraryContext.Sizes[$leaf] }
        if ($max -gt 2GB) { throw "The manifest names $leaf with more than 2 GB: refused." }
    }
    $answer = Invoke-AVDTuneLibraryGet -Url ($script:GraphV1 + $Path) -Audience Sites -OutFile $OutFile -MaxBytes $max
    if ($OutFile -and $leaf -eq 'manifest.json') {
        $m = $null; try { $m = [IO.File]::ReadAllText($OutFile) | ConvertFrom-Json } catch { }
        $script:LibraryContext.Sizes = @{}
        foreach ($e in @(Get-AVDTuneProp $m 'files')) { $n = [string](Get-AVDTuneProp $e 'name'); $s = Get-AVDTuneProp $e 'size'; if ($n -and ($s -is [int] -or $s -is [int64] -or $s -is [long])) { $script:LibraryContext.Sizes[$n] = [int64]$s } }
    }
    # The shared code asks every item for .folder, which Graph only sends for folders; this module runs in strict mode, so the property is always there
    if ($answer -and $answer.PSObject.Properties['value']) { foreach ($item in @($answer.value)) { if ($item -and -not $item.PSObject.Properties['folder']) { $item | Add-Member -NotePropertyName folder -NotePropertyValue $null } } }
    $answer
}

function Expand-PackTuneZip {
    <#
        Stand-in for the function of PackTune's Modules\PackTune.Sandbox.psm1 that Save-PackTuneStoreVersion calls (it is not part of Shared\ yet):
        unpacks a zip into an EMPTY new folder and refuses every entry that would land outside it (zip slip), a name with a colon or a reserved
        device name, and an archive with too many entries or too much content (zip bomb).
    #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Destination, [int]$MaxEntries = 20000, [int64]$MaxBytes = 4GB)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $root = [IO.Path]::GetFullPath($Destination).TrimEnd('\') + '\'
    if (Test-Path -LiteralPath $Destination) { if (@(Get-ChildItem -LiteralPath $Destination -Force).Count -gt 0) { throw "The folder $Destination is not empty." } }
    else { [void][IO.Directory]::CreateDirectory($Destination) }
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        if ($zip.Entries.Count -gt $MaxEntries) { throw "The archive has more than $MaxEntries entries." }
        $total = [int64]0
        foreach ($e in $zip.Entries) { $total += $e.Length }
        if ($total -gt $MaxBytes) { throw 'The archive is larger than allowed when unpacked.' }
        foreach ($e in $zip.Entries) {
            $name = $e.FullName
            if ($name -match '(^|[\\/])\.\.([\\/]|$)' -or $name -match '^[\\/]' -or $name -match '[:*?"<>|]' -or $name -match '(^|[\\/])(CON|PRN|AUX|NUL|COM\d|LPT\d)(\.|[\\/]|$)') { throw "The archive has an entry that is not allowed: $name" }
            $target = [IO.Path]::GetFullPath((Join-Path $Destination ($name -replace '/', '\')))
            if (-not $target.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { throw "The archive has an entry outside the target folder: $name" }
            if ($name.EndsWith('/') -or $name.EndsWith('\')) { [void][IO.Directory]::CreateDirectory($target); continue }
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
            $in = $e.Open()
            try {
                $out = [IO.File]::Open($target, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
                try {
                    $buf = New-Object byte[] 81920; $entryBytes = [int64]0
                    while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
                        $entryBytes += $n
                        if ($entryBytes -gt [int64]$e.Length) { throw "The archive holds more data than it declares (entry $name): stopped." }   # the declared sizes are not trusted
                        $out.Write($buf, 0, $n)
                    }
                }
                finally { $out.Dispose() }
            }
            finally { $in.Dispose() }
        }
    }
    finally { $zip.Dispose() }
}

#endregion

#region settings

function Get-AVDTuneSoftwareSettings {
    # config\software.json: the SharePoint site and the library of the PackTune package store (empty site: the library is not used)
    param([string]$Root = (Get-AVDTuneRoot))
    $s = $null
    try { $s = Read-AVDTuneJson (Join-Path $Root 'config\software.json') } catch { }
    $site = ''; if ($s) { $v = Get-AVDTuneProp $s 'StoreSiteUrl'; if ($v -is [string] -and $v -match $script:LibrarySitePattern) { $site = $v.TrimEnd('/') } }
    $lib = $script:DefaultLibrary; if ($s) { $v = Get-AVDTuneProp $s 'StoreLibrary'; if ($v -is [string] -and $v -match $script:LibraryNamePattern) { $lib = $v } }
    [pscustomobject]@{ StoreSiteUrl = $site; StoreLibrary = $lib }
}

function Set-AVDTuneSoftwareSettings {
    param([string]$Root = (Get-AVDTuneRoot), [string]$StoreSiteUrl = '', [string]$StoreLibrary = $script:DefaultLibrary)
    $site = ([string]$StoreSiteUrl).Trim()
    if ($site -and $site -notmatch $script:LibrarySitePattern) { throw 'The address of the SharePoint site must look like https://<tenant>.sharepoint.com/sites/<name>.' }
    $lib = ([string]$StoreLibrary).Trim(); if (-not $lib) { $lib = $script:DefaultLibrary }
    if ($lib -notmatch $script:LibraryNamePattern) { throw 'The name of the library may contain letters, digits, spaces, . _ -' }
    Write-AVDTuneFile (Join-Path $Root 'config\software.json') ([ordered]@{ StoreSiteUrl = $site.TrimEnd('/'); StoreLibrary = $lib } | ConvertTo-Json)
    Get-AVDTuneSoftwareSettings $Root
}

#endregion

#region checks of input (pure)

function Test-AVDTunePackageId([string]$Id) { [bool]($Id -cmatch $script:PackageIdPattern) -and $Id -notmatch '\.\.' }
function Test-AVDTunePackageVersion([string]$Version) { [bool]($Version -cmatch $script:PackageVersionPattern) -and $Version -notmatch '\.\.' }
function Test-AVDTuneSearchText([string]$Text) { [bool]($Text -match $script:SearchPattern) }

function Compare-AVDTuneVersion {
    # -1, 0, 1. Numeric parts are compared as numbers (1.10 > 1.9); a leading v and a text tail ("-beta") are looked at last, a version with a tail is older.
    param([string]$A, [string]$B)
    $parse = {
        param($t)
        $t = ([string]$t).Trim() -replace '^[vV]', ''
        $m = [regex]::Match($t, '^(\d+(?:\.\d+){0,5})(.*)$')
        if (-not $m.Success) { return @{ Nums = @(); Tail = $t } }
        @{ Nums = @($m.Groups[1].Value -split '\.' | ForEach-Object { [int64]$_ }); Tail = $m.Groups[2].Value }
    }
    $x = & $parse $A; $y = & $parse $B
    $n = [Math]::Max($x.Nums.Count, $y.Nums.Count)
    for ($i = 0; $i -lt $n; $i++) {
        $p = if ($i -lt $x.Nums.Count) { $x.Nums[$i] } else { 0 }; $q = if ($i -lt $y.Nums.Count) { $y.Nums[$i] } else { 0 }
        if ($p -lt $q) { return -1 }; if ($p -gt $q) { return 1 }
    }
    if ($x.Tail -eq $y.Tail) { return 0 }
    if (-not $x.Tail) { return 1 }; if (-not $y.Tail) { return -1 }
    [Math]::Sign([string]::CompareOrdinal($x.Tail, $y.Tail))
}

#endregion

#region parsers (pure)

function ConvertFrom-AVDTuneWingetTable {
    <#
        The text table of "winget search" and "winget list": a header with Name, Id, Version (and Available, Match, Source in any mix), a dashed line, then
        the rows. Columns by the positions of the header. Rows whose id is not a package id are dropped. (winget pads by characters; a name with wide
        characters can shift a column, then the row is dropped by the id check rather than shown wrong.)
    #>
    param([string]$Text)
    $lines = @($Text -split "`r?`n")
    $h = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^\s*Name\s+Id\s+Version(\s|$)') { $h = $i; break } }
    if ($h -lt 0) { return @() }
    $head = $lines[$h]
    $cols = @()
    foreach ($n in 'Name', 'Id', 'Version', 'Available', 'Match', 'Source') { $p = [regex]::Match($head, "(?<![A-Za-z])$n(?![A-Za-z])").Index; if ($head -match "(?<![A-Za-z])$n(?![A-Za-z])") { $cols += @{ Name = $n; Pos = $p } } }
    $cols = @($cols | Sort-Object { $_.Pos })
    $rows = New-Object System.Collections.ArrayList
    for ($i = $h + 1; $i -lt $lines.Count; $i++) {
        $l = $lines[$i]
        if ($l -match '^\s*-{5,}\s*$') { continue }
        if (-not $l.Trim()) { continue }
        if ($l.Length -le $cols[1].Pos) { continue }
        $v = @{ Name = ''; Id = ''; Version = ''; Available = ''; Match = ''; Source = '' }
        for ($c = 0; $c -lt $cols.Count; $c++) {
            $start = $cols[$c].Pos; $end = if ($c + 1 -lt $cols.Count) { $cols[$c + 1].Pos } else { $l.Length }
            if ($start -ge $l.Length) { continue }
            $v[$cols[$c].Name] = $l.Substring($start, [Math]::Min($end, $l.Length) - $start).Trim()
        }
        if ($v.Id -cmatch $script:PackageIdPattern) {
            [void]$rows.Add([pscustomobject]@{ Name = (Remove-AVDTuneControlCharacters $v.Name 120); Id = $v.Id; Version = ($v.Version -replace '^[<>~]\s*', ''); Available = $v.Available; Source = $v.Source })
        }
    }
    @($rows)
}

function ConvertFrom-AVDTuneChocoPackages {
    # "choco search -r" and "choco list -r": id|version per line
    param([string]$Text)
    $rows = New-Object System.Collections.ArrayList
    foreach ($l in ($Text -split "`r?`n")) {
        $p = $l.Trim() -split '\|'
        if ($p.Count -ge 2 -and $p[0] -cmatch $script:PackageIdPattern -and $p[1] -match '^\d') { [void]$rows.Add([pscustomobject]@{ Name = $p[0]; Id = $p[0]; Version = $p[1]; Available = ''; Source = 'chocolatey' }) }
    }
    @($rows)
}

function ConvertFrom-AVDTuneIntuneNote {
    <#
        The notes of a PackTune custom application in Intune: "PoweredByPackTune;kind=msi;app=<id>;ver=<version>;product=<guid>;manifest=<sha256>" (the
        recorded format of PackTune's custom applications). Returns $null for anything else. Every value is checked; the manifest must be the full SHA256
        (the 16 character prefix of the first release is not accepted here). Data only.
    #>
    param([string]$Notes)
    if ([string]::IsNullOrEmpty($Notes) -or $Notes.Length -gt 4000) { return $null }
    $m = [regex]::Match($Notes, '(?<![A-Za-z0-9])PoweredByPackTune;([^\r\n]*)', 'None', [TimeSpan]::FromSeconds(1))
    if (-not $m.Success) { return $null }
    $kv = @{}
    foreach ($part in ($m.Groups[1].Value -split ';')) { $i = $part.IndexOf('='); if ($i -gt 0) { $kv[$part.Substring(0, $i).Trim().ToLowerInvariant()] = $part.Substring($i + 1).Trim() } }
    foreach ($k in 'kind', 'app', 'ver', 'manifest') { if (-not $kv.ContainsKey($k)) { return $null } }
    if ($kv.kind -cnotin 'msi', 'msix') { return $null }
    if ($kv.app -cnotmatch $script:SegmentPattern -or $kv.app -match '\.\.') { return $null }
    if ($kv.ver -cnotmatch $script:SegmentPattern -or $kv.ver -match '\.\.') { return $null }
    if ($kv.manifest.ToLowerInvariant() -notmatch '\A[0-9a-f]{64}\z') { return $null }
    $product = ''
    if ($kv.ContainsKey('product')) { if ($kv.product -match '\A\{?([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})\}?\z') { $product = '{' + $Matches[1].ToUpperInvariant() + '}' } else { return $null } }
    [pscustomobject]@{ Kind = [string]$kv.kind; AppId = [string]$kv.app; Version = [string]$kv.ver; Product = $product; Manifest = $kv.manifest.ToLowerInvariant() }
}

#endregion

#region installed software

function Get-AVDTuneInstalledSoftware {
    <# What the master has installed, from the Uninstall keys (no program is started): Name, Version, Publisher, Arch, Key, Msi (product code or ''). Updates, components and entries without a name are left out. #>
    param([Parameter(Mandatory)]$Machine)
    $rows = New-Object System.Collections.ArrayList
    foreach ($u in $script:UninstallKeys) {
        foreach ($sub in @(& $Machine.RegSubKeys $u.Path)) {
            $key = "$($u.Path)\$sub"
            $name = [string](& $Machine.RegGet $key 'DisplayName')
            if (-not $name.Trim()) { continue }
            if ([int](& $Machine.RegGet $key 'SystemComponent') -eq 1) { continue }
            if ([string](& $Machine.RegGet $key 'ParentKeyName')) { continue }
            $rel = [string](& $Machine.RegGet $key 'ReleaseType'); if ($rel -match '(?i)update|hotfix|security') { continue }
            $isMsi = ($sub -match '\A\{[0-9A-Fa-f-]{36}\}\z') -and ([int](& $Machine.RegGet $key 'WindowsInstaller') -eq 1)
            [void]$rows.Add([pscustomobject]@{
                    Name = (Remove-AVDTuneControlCharacters $name 160); Version = (Remove-AVDTuneControlCharacters ([string](& $Machine.RegGet $key 'DisplayVersion')) 60)
                    Publisher = (Remove-AVDTuneControlCharacters ([string](& $Machine.RegGet $key 'Publisher')) 100); Arch = $u.Arch; Key = $sub
                    Msi = $(if ($isMsi) { $sub.ToUpperInvariant() } else { '' }); Managed = ''
                })
        }
    }
    @($rows | Sort-Object Name, Version)
}

#endregion

#region running programs

function Test-AVDTuneMsiexecTrust {
    # Pure: msiexec.exe signed by Microsoft (Windows) with its own original file name. Same rule as Test-AVDTuneToolTrust for the Microsoft tools.
    param($Signature)
    if (-not $Signature -or -not $Signature.Valid) { return @{ Ok = $false; Reason = "msiexec.exe has no valid signature ($(if ($Signature) { $Signature.Status } else { 'none' }))" } }
    $part = {
        param($Dn, $Key)
        if (-not $Dn) { return '' }
        try { $lines = (New-Object System.Security.Cryptography.X509Certificates.X500DistinguishedName($Dn)).Decode([System.Security.Cryptography.X509Certificates.X500DistinguishedNameFlags]::UseNewLines) -split "\r?\n" } catch { return '' }
        $vals = @(foreach ($l in $lines) { $i = $l.IndexOf('='); if ($i -gt 0 -and $l.Substring(0, $i).Trim() -ceq $Key) { $v = $l.Substring($i + 1).Trim(); if ($v.Length -ge 2 -and $v.StartsWith('"') -and $v.EndsWith('"')) { $v = $v.Substring(1, $v.Length - 2) }; $v } })
        if ($vals.Count -ne 1) { '' } else { $vals[0] }
    }
    $sO = & $part $Signature.Subject 'O'; $sCN = & $part $Signature.Subject 'CN'
    $iO = & $part (Get-AVDTuneProp $Signature 'Issuer') 'O'; $iCN = & $part (Get-AVDTuneProp $Signature 'Issuer') 'CN'
    if (-not ($sO -ceq 'Microsoft Corporation' -and $sCN -cin 'Microsoft Corporation', 'Microsoft Windows' -and $iO -ceq 'Microsoft Corporation' -and $iCN -cmatch '^Microsoft (Windows )?(Code Signing|Production) PCA( [0-9]{4})?\z')) {
        return @{ Ok = $false; Reason = "msiexec.exe is not signed by Microsoft (signer '$($Signature.Subject)')" }
    }
    $orig = ([string](Get-AVDTuneProp $Signature 'OriginalFilename')) -replace '(?i)\.mui$', ''
    if ($orig -ne 'msiexec.exe') { return @{ Ok = $false; Reason = "msiexec.exe carries the original file name '$orig'" } }
    @{ Ok = $true; Reason = '' }
}

function Open-AVDTuneToolHold {
    <#
        Keeps a program file open for reading without write or delete sharing, so nothing can swap it between the signature check and the end of
        the run (the TOCTOU gap). Returns the stream, or $null for the fake adapter (its files do not exist). Throws when the file cannot be held.
    #>
    param([Parameter(Mandatory)]$U, [Parameter(Mandatory)][string]$Path)
    if ([string](Get-AVDTuneProp $U 'Kind') -eq 'Fake') { return $null }
    [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
}

function Invoke-AVDTuneSoftwareTool {
    <#
        One winget, choco or msiexec call. Inside the lock Global\PackTune; the tool is found in a fixed admin-only place (winget in WindowsApps, choco in the
        machine's Chocolatey folder, msiexec in the system folder; never PATH), held open without write/delete sharing, its signature checked on the held
        file, then started through the adapter (no window, job object, the lock is kept until the whole tree has ended). Returns
        @{ Ok; Code (Lock | ToolMissing | BadSignature | HoldFailed | ''); Error; ExitCode; Output }.
    #>
    param([Parameter(Mandatory)]$U, [Parameter(Mandatory)][ValidateSet('winget.exe', 'choco.exe', 'msiexec.exe')][string]$Tool, [Parameter(Mandatory)][string[]]$Arguments, [int]$TimeoutSeconds = 3600)
    $fail = { param($code, $text) [pscustomobject]@{ Ok = $false; Code = $code; Error = $text; ExitCode = $null; Output = '' } }
    $got = Invoke-AVDTuneLocked -U $U -Script {
        $path = if ($Tool -eq 'msiexec.exe') { Join-Path (Get-AVDTuneSystemFolder System) 'msiexec.exe' } else { & $U.FindTool $Tool $null }
        if (-not $path -or -not (& $U.Exists $path)) { return (& $fail 'ToolMissing' "$($Tool -replace '\.exe$', '') was not found.") }
        $hold = $null
        try {
            try { $hold = Open-AVDTuneToolHold -U $U -Path $path } catch { return (& $fail 'HoldFailed' "$Tool cannot be held for the check: $($_.Exception.Message)") }
            $sig = & $U.VerifySignature $path
            $trust = if ($Tool -eq 'msiexec.exe') { Test-AVDTuneMsiexecTrust -Signature $sig } else { Test-AVDTuneToolTrust -Signature $sig -Name $Tool }
            if (-not $trust.Ok) { return (& $fail 'BadSignature' "$($trust.Reason): it is not started.") }
            $r = & $U.Run $path $Arguments $TimeoutSeconds
            [pscustomobject]@{ Ok = $true; Code = ''; Error = ''; ExitCode = [int]$r.ExitCode; Output = [string]$r.Output }
        }
        finally { if ($hold) { $hold.Dispose() } }
    }
    if (-not $got.Ok) { return (& $fail 'Lock' "Not started: $($got.Error)") }
    $got.Value
}

#endregion

#region catalog: search and what is installed or outdated

function Search-AVDTuneCatalog {
    <# Searches winget and/or Chocolatey. Returns @{ Items; Notes }; Items have Source (winget | chocolatey), Id, Name, Version, Available (''), at most 30 per source. #>
    param([Parameter(Mandatory)]$U, [Parameter(Mandatory)][string]$Query, [ValidateSet('Both', 'winget', 'chocolatey')][string]$Source = 'Both')
    $q = $Query.Trim()
    if (-not (Test-AVDTuneSearchText $q)) { throw 'The search text may contain letters, digits, space and . _ + - (at most 64, starting with a letter or digit).' }
    $items = New-Object System.Collections.ArrayList; $notes = New-Object System.Collections.ArrayList
    if ($Source -in 'Both', 'winget') {
        $r = Invoke-AVDTuneSoftwareTool -U $U -Tool 'winget.exe' -Arguments @('search', '--query', $q, '--source', 'winget', '--count', [string]$script:MaxSearchRows, '--accept-source-agreements', '--disable-interactivity') -TimeoutSeconds 300
        if (-not $r.Ok) { [void]$notes.Add("winget: $($r.Error)") }
        elseif ($r.ExitCode -ne 0 -and $r.ExitCode -ne $script:WingetNotFound) { [void]$notes.Add("winget: $(Resolve-AVDTuneSoftwareError 'winget' $r.ExitCode $r.Output)") }
        else { foreach ($p in @(ConvertFrom-AVDTuneWingetTable $r.Output | Select-Object -First $script:MaxSearchRows)) { [void]$items.Add([pscustomobject]@{ Source = 'winget'; Id = $p.Id; Name = $p.Name; Version = $p.Version; Available = '' }) } }
    }
    if ($Source -in 'Both', 'chocolatey') {
        $r = Invoke-AVDTuneSoftwareTool -U $U -Tool 'choco.exe' -Arguments @('search', $q, '--limit-output') -TimeoutSeconds 300
        if (-not $r.Ok) { [void]$notes.Add("Chocolatey: $($r.Error)") }
        elseif ($r.ExitCode -ne 0) { [void]$notes.Add("Chocolatey: $(Resolve-AVDTuneSoftwareError 'choco' $r.ExitCode $r.Output)") }
        else { foreach ($p in @(ConvertFrom-AVDTuneChocoPackages $r.Output | Select-Object -First $script:MaxSearchRows)) { [void]$items.Add([pscustomobject]@{ Source = 'chocolatey'; Id = $p.Id; Name = $p.Name; Version = $p.Version; Available = '' }) } }
    }
    [pscustomobject]@{ Items = @($items); Notes = @($notes) }
}

function Get-AVDTuneManagedSoftware {
    <# Packages that winget and Chocolatey manage on this master (list) and the newer versions they know (upgrade / outdated). Returns @{ Items; Notes }; Items: Source, Id, Name, Version, Available. #>
    param([Parameter(Mandatory)]$U)
    $items = New-Object System.Collections.ArrayList; $notes = New-Object System.Collections.ArrayList
    $w = Invoke-AVDTuneSoftwareTool -U $U -Tool 'winget.exe' -Arguments @('list', '--source', 'winget', '--accept-source-agreements', '--disable-interactivity') -TimeoutSeconds 300
    if (-not $w.Ok) { [void]$notes.Add("winget: $($w.Error)") }
    elseif ($w.ExitCode -ne 0 -and $w.ExitCode -ne $script:WingetNotFound) { [void]$notes.Add("winget: $(Resolve-AVDTuneSoftwareError 'winget' $w.ExitCode $w.Output)") }
    else {
        $up = @{}
        $u1 = Invoke-AVDTuneSoftwareTool -U $U -Tool 'winget.exe' -Arguments @('upgrade', '--source', 'winget', '--accept-source-agreements', '--disable-interactivity') -TimeoutSeconds 300
        if ($u1.Ok -and $u1.ExitCode -in 0, $script:WingetNoUpgrade) { foreach ($p in @(ConvertFrom-AVDTuneWingetUpgrade $u1.Output)) { if (-not $p.Source -or $p.Source -eq 'winget') { $up[$p.Id] = $p.Available } } }
        foreach ($p in @(ConvertFrom-AVDTuneWingetTable $w.Output)) { if ($p.Source -and $p.Source -ne 'winget') { continue }; [void]$items.Add([pscustomobject]@{ Source = 'winget'; Id = $p.Id; Name = $p.Name; Version = $p.Version; Available = $(if ($up.ContainsKey($p.Id)) { [string]$up[$p.Id] } else { '' }) }) }
    }
    $c = Invoke-AVDTuneSoftwareTool -U $U -Tool 'choco.exe' -Arguments @('list', '--limit-output') -TimeoutSeconds 300
    if (-not $c.Ok) { [void]$notes.Add("Chocolatey: $($c.Error)") }
    elseif ($c.ExitCode -ne 0) { [void]$notes.Add("Chocolatey: $(Resolve-AVDTuneSoftwareError 'choco' $c.ExitCode $c.Output)") }
    else {
        $out = @{}
        $o1 = Invoke-AVDTuneSoftwareTool -U $U -Tool 'choco.exe' -Arguments @('outdated', '--limit-output', '--ignore-unfound') -TimeoutSeconds 300
        if ($o1.Ok -and $o1.ExitCode -eq 0) { foreach ($p in @(ConvertFrom-AVDTuneChocoOutdated $o1.Output)) { $out[$p.Id.ToLowerInvariant()] = $p.Available } }
        foreach ($p in @(ConvertFrom-AVDTuneChocoPackages $c.Output)) { [void]$items.Add([pscustomobject]@{ Source = 'chocolatey'; Id = $p.Id; Name = $p.Name; Version = $p.Version; Available = $(if ($out.ContainsKey($p.Id.ToLowerInvariant())) { [string]$out[$p.Id.ToLowerInvariant()] } else { '' }) }) }
    }
    [pscustomobject]@{ Items = @($items); Notes = @($notes) }
}

#endregion

#region the library (PackTune package store, read only)

function Test-AVDTuneLibraryUrl {
    <# Pure. Is this request URL allowed? https, graph.microsoft.com only, default port, no credentials, no fragment, at most one "?", path and query of known characters. Returns @{ Ok; Reason }. #>
    param([string]$Url)
    $no = { param($t) @{ Ok = $false; Reason = $t } }
    if (-not $Url -or $Url.Length -gt 2000 -or $Url.Contains('#')) { return (& $no 'the address is empty, too long or has a fragment') }
    $u = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$u)) { return (& $no 'the address is not valid') }
    if ($u.Scheme -ne 'https' -or -not $u.IsDefaultPort -or $u.UserInfo) { return (& $no 'only https on the default port, without credentials') }
    if ($u.Host -ne 'graph.microsoft.com') { return (& $no "the host $($u.Host) is not allowed") }
    if (([regex]::Matches($Url, '\?')).Count -gt 1) { return (& $no 'more than one question mark') }
    $raw = $Url.Substring(0, [Math]::Min($Url.Length, 2000))
    $m = [regex]::Match($raw, "\Ahttps://graph\.microsoft\.com(/[A-Za-z0-9._:/%,()'-]+)(\?[A-Za-z0-9`$=,&._%()+/'-]*)?\z", 'None', [TimeSpan]::FromSeconds(1))
    if (-not $m.Success) { return (& $no 'the path or query has characters that are not allowed') }
    if ($m.Groups[1].Value -match '(^|/)\.\.?(/|$)' -or $raw -match '(?i)%2e|%2f|%5c|%00') { return (& $no 'the path climbs or hides a separator') }
    @{ Ok = $true; Reason = '' }
}

function Get-AVDTuneRedirectHosts {
    # The hosts a download may be redirected to: the SharePoint host of the site and its -my variant (OneDrive for Business storage of the same tenant)
    param([Parameter(Mandatory)][string]$SiteUrl)
    $h = ([Uri]$SiteUrl).Host.ToLowerInvariant()
    $tenant = $h.Substring(0, $h.IndexOf('.'))
    @($h, ($tenant + "-my" + $h.Substring($h.IndexOf("."))))
}

function Test-AVDTuneDownloadUrl {
    # Pure: the redirect of a Graph download: https on one of the allowed SharePoint hosts (Get-AVDTuneRedirectHosts), default port, no credentials, no fragment. No token goes there.
    param([string]$Url, [string[]]$AllowedHost)
    $u = $null
    if (-not $Url -or $Url.Length -gt 4000 -or $Url.Contains('#') -or -not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$u)) { return $false }
    if (-not $AllowedHost) { return $false }
    ($u.Scheme -eq 'https' -and $u.IsDefaultPort -and -not $u.UserInfo -and $u.Host.ToLowerInvariant() -in @($AllowedHost | ForEach-Object { $_.ToLowerInvariant() }))
}

function Invoke-AVDTuneHttpRequest {
    <#
        The real transport: ONE GET, no automatic redirect, no proxy surprises beyond the system default. Returns Status, Headers (Location only), Stream and Close.
        The loop around it (Invoke-AVDTuneLibraryGet) is the part with the rules; the checks replace this function through the Transport member of the context
        with a fake that answers status, headers and a stream, so the real loop runs.
    #>
    param([Parameter(Mandatory)][string]$Url, [hashtable]$Headers = @{})
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.Method = 'GET'; $req.AllowAutoRedirect = $false; $req.Timeout = 60000; $req.ReadWriteTimeout = 120000
    foreach ($k in $Headers.Keys) { $req.Headers.Add([string]$k, [string]$Headers[$k]) }
    try { $resp = $req.GetResponse() }
    catch {
        $resp = Get-AVDTuneProp $_.Exception 'Response'
        if (-not $resp) { throw "SharePoint or Graph cannot be reached: $($_.Exception.Message)" }
    }
    $r = $resp
    @{ Status = [int]$r.StatusCode; Headers = @{ Location = [string]$r.Headers['Location'] }; Stream = $r.GetResponseStream(); Close = { $r.Close() }.GetNewClosure() }
}

function Read-AVDTuneLimited {
    # Copies a stream in blocks and counts the real bytes: more than MaxBytes is an error (the declared length is not trusted). To a new file (-OutFile, removed on an error) or into memory (text).
    param([Parameter(Mandatory)]$Stream, [Parameter(Mandatory)][int64]$MaxBytes, [string]$OutFile, [datetime]$Deadline = [datetime]::MaxValue)
    $buf = New-Object byte[] 81920
    $total = [int64]0
    $mem = $null; $out = $null
    try {
        if ($OutFile) { $out = [IO.File]::Open($OutFile, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write) } else { $mem = New-Object IO.MemoryStream }
        while (($n = $Stream.Read($buf, 0, $buf.Length)) -gt 0) {
            if ([datetime]::UtcNow -gt $Deadline) { throw 'The download took longer than the allowed time: stopped.' }
            $total += $n
            if ($total -gt $MaxBytes) { throw "The answer is larger than the allowed $MaxBytes bytes: stopped." }
            if ($out) { $out.Write($buf, 0, $n) } else { $mem.Write($buf, 0, $n) }
        }
        if ($mem) { return [Text.Encoding]::UTF8.GetString($mem.ToArray()) }
    }
    catch { if ($out) { $out.Dispose(); $out = $null; Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue }; throw }
    finally { if ($out) { $out.Dispose() } }
}

function Invoke-AVDTuneLibraryGet {
    <#
        One GET to Microsoft Graph with the token of the audience (Sites for the package store, Graph for the Intune notes). Redirects are never followed
        automatically: this loop follows them by hand, at most 5, every hop checked (graph.microsoft.com, or the SharePoint host of the site and its -my variant);
        the token goes only to graph.microsoft.com, never to SharePoint. -OutFile saves the content into a new file (CreateNew), at most -MaxBytes; otherwise the
        answer is parsed JSON of at most 4 MB. The whole request (redirects and reading) may take at most $ctx.DownloadSeconds (30 minutes). The request itself is $ctx.Transport (default Invoke-AVDTuneHttpRequest): the checks give it a fake.
    #>
    param([Parameter(Mandatory)][string]$Url, [ValidateSet('Sites', 'Graph')][string]$Audience = 'Sites', [string]$OutFile, [int64]$MaxBytes = 4MB)
    $ctx = $script:LibraryContext
    $deadline = [datetime]::UtcNow.AddSeconds([double]$ctx.DownloadSeconds)   # one limit for the whole request: redirects and reading together
    if (-not $ctx) { throw 'The package store is not open (internal: no library context).' }
    $check = Test-AVDTuneLibraryUrl $Url
    if (-not $check.Ok) { throw "Refused request to the library: $($check.Reason)." }
    $token = if ($Audience -eq 'Graph') { [string]$ctx.GraphToken } else { [string]$ctx.SitesToken }
    if (-not $token) { throw "Not signed in for $Audience (no token). Sign in on the Overview first." }
    $transport = if ($ctx.Transport) { $ctx.Transport } else { ${function:Invoke-AVDTuneHttpRequest} }
    $allowed = Get-AVDTuneRedirectHosts $ctx.SiteUrl
    $current = $Url; $redirects = 0
    while ($true) {
        if ([datetime]::UtcNow -ge $deadline) { throw 'The download took longer than the allowed time: stopped.' }
        $isGraph = ([Uri]$current).Host -eq 'graph.microsoft.com'
        $headers = @{}; if ($isGraph) { $headers['Authorization'] = "Bearer $token" }
        $resp = & $transport $current $headers
        try {
            $code = [int]$resp.Status
            if ($code -in 301, 302, 303, 307, 308) {
                if (++$redirects -gt 5) { throw 'Too many redirects.' }
                $loc = [string]$resp.Headers.Location
                if (-not $loc.Trim()) { throw 'A redirect without an address was refused.' }
                $abs = $null; if (-not [Uri]::TryCreate([Uri]$current, $loc, [ref]$abs)) { throw 'A redirect with an address that is not valid was refused.' }
                if (-not (Test-AVDTuneDownloadUrl $abs.AbsoluteUri -AllowedHost $allowed) -and -not ((Test-AVDTuneLibraryUrl $abs.AbsoluteUri).Ok)) { throw "A redirect to $($abs.Host) was refused (only graph.microsoft.com and the SharePoint host of the site are allowed)." }
                $current = $abs.AbsoluteUri
                continue
            }
            if ($code -lt 200 -or $code -gt 299) { throw "Graph answered $code." }
            if ($OutFile) { Read-AVDTuneLimited -Stream $resp.Stream -MaxBytes $MaxBytes -OutFile $OutFile -Deadline $deadline; return $null }
            $text = Read-AVDTuneLimited -Stream $resp.Stream -MaxBytes $MaxBytes -Deadline $deadline
            if (-not $text.Trim()) { return $null }
            return ($text | ConvertFrom-Json)
        }
        finally { if ($resp.Close) { & $resp.Close } }
    }
}

function New-AVDTuneLibraryContext {
    <# The tokens (strings, kept in memory only) and the site of one library session. -Transport replaces the single request (status, headers, stream; the checks). Close it with Close-AVDTuneLibraryContext. #>
    param([string]$SitesToken, [string]$GraphToken, [Parameter(Mandatory)][string]$SiteUrl, [string]$Library = $script:DefaultLibrary, [scriptblock]$Transport)
    if ($SiteUrl -notmatch $script:LibrarySitePattern) { throw 'The address of the SharePoint site is not valid (https://<tenant>.sharepoint.com/sites/<name>).' }
    if ($Library -notmatch $script:LibraryNamePattern) { throw 'The name of the library is not valid.' }
    [pscustomobject]@{ SitesToken = $SitesToken; GraphToken = $GraphToken; SiteUrl = $SiteUrl.TrimEnd('/'); Library = $Library; Transport = $Transport; Sizes = @{}; DownloadSeconds = 1800 }
}

function Close-AVDTuneLibraryContext($Context) { if ($Context) { $Context.SitesToken = $null; $Context.GraphToken = $null } }

function Get-AVDTuneIntuneAnchors {
    # Reads the notes of the Intune apps (read only, Graph token), follows the pages and keeps the ones of PackTune custom apps. Filtered locally, not with $filter.
    $anchors = @{}
    $url = "$($script:GraphV1)/deviceAppManagement/mobileApps?`$select=id,displayName,notes&`$top=200"
    for ($page = 0; $url -and $page -lt 50; $page++) {
        $answer = Invoke-AVDTuneLibraryGet -Url $url -Audience Graph
        if (-not $answer) { break }
        foreach ($app in @(Get-AVDTuneProp $answer 'value')) {
            if (-not $app) { continue }
            $a = ConvertFrom-AVDTuneIntuneNote ([string](Get-AVDTuneProp $app 'notes'))
            if (-not $a) { continue }
            $key = "$($a.AppId)|$($a.Version)"
            if ($anchors.ContainsKey($key)) { $anchors[$key] = $null; continue }   # two Intune apps claim the same package and version: ambiguous, no anchor
            $a | Add-Member -NotePropertyName IntuneName -NotePropertyValue (Remove-AVDTuneControlCharacters ([string](Get-AVDTuneProp $app 'displayName')) 120)
            $anchors[$key] = $a
        }
        $next = [string](Get-AVDTuneProp $answer '@odata.nextLink')
        $url = $next
    }
    $anchors
}

function Get-AVDTuneStoreVersions {
    <#
        The versions of one app in the store, like Get-PackTuneStoreVersions (Complete = has a manifest), but a folder whose name is not a valid version segment
        is skipped on its own (with a note) before anything is asked about it: the shared function would throw for the name and hide every other version of the app.
    #>
    param([Parameter(Mandatory)][string]$AppId, [Parameter(Mandatory)]$Store, $Notes)
    if (-not $Store.DriveId) { return }
    try { $folders = @(Get-PackTuneStoreChildren -DriveId $Store.DriveId -Segments @($AppId) | Where-Object { $_.folder }) } catch { return }
    foreach ($f in $folders) {
        $name = [string]$f.name
        if ($name -cnotmatch $script:SegmentPattern -or $name -match '\.\.') { if ($null -ne $Notes) { [void]$Notes.Add("A version folder of $AppId with an invalid name was skipped.") }; continue }
        $files = @(Get-PackTuneStoreChildren -DriveId $Store.DriveId -Segments @($AppId, $name))
        [pscustomobject]@{ AppId = $AppId; Version = $name; Complete = [bool](@($files | Where-Object { $_.name -eq 'manifest.json' }).Count); Files = @($files.name) }
    }
}

function Get-AVDTuneLibraryItems {
    <#
        The packages of the library: every complete version in the store, with the anchor from Intune. Returns @{ State; Message; Items; Notes }.
        State: Ready | NoSite | NoAccess | NoLibrary. Item: AppId, Version, Kind, Name, Anchored, Product, Manifest, Installable (MSI with anchor and product code), Why.
        A package that Intune does not know (no anchor) is listed but cannot be installed.
    #>
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Machine)
    $previousContext = $script:LibraryContext; $script:LibraryContext = $Context
    try {
        $state = Get-PackTuneStoreState -SiteUrl $Context.SiteUrl -Library $Context.Library
        if ($state.State -ne 'Ready') { return [pscustomobject]@{ State = [string]$state.State; Message = [string]$state.Message; Items = @(); Notes = @() } }
        $notes = New-Object System.Collections.ArrayList
        $anchors = @{}
        try { $anchors = Get-AVDTuneIntuneAnchors } catch { [void]$notes.Add("Intune could not be read, so no package can be trusted: $($_.Exception.Message)") }
        $items = New-Object System.Collections.ArrayList
        foreach ($app in @(Get-PackTuneStoreApps -Store $state.Store)) {
            if ($app -notmatch $script:SegmentPattern) { continue }
            foreach ($v in @(Get-AVDTuneStoreVersions -AppId $app -Store $state.Store -Notes $notes)) {
                if (-not $v.Complete) { continue }
                $a = $null; $key = "$app|$($v.Version)"; if ($anchors.ContainsKey($key)) { $a = $anchors[$key] }
                $why = ''
                if (-not $a) { $why = 'Intune has no app with the manifest of this version (no trust anchor).' }
                elseif ($a.Kind -ne 'msi') { $why = 'Only MSI packages are installed here (MSIX needs its certificate: later).' }
                elseif (-not $a.Product) { $why = 'The Intune notes carry no product code, so the package cannot be detected or removed.' }
                $inst = ''
                if ($a -and $a.Product) { $iv = & $Machine.RegGet "$($script:UninstallKeys[0].Path)\$($a.Product)" 'DisplayVersion'; if ($null -eq $iv) { $iv = & $Machine.RegGet "$($script:UninstallKeys[1].Path)\$($a.Product)" 'DisplayVersion' }; if ($null -ne $iv) { $inst = [string]$iv; if (-not $inst) { $inst = '?' } } }
                [void]$items.Add([pscustomobject]@{
                        AppId = $app; Version = [string]$v.Version; Kind = $(if ($a) { [string]$a.Kind } else { '' }); Name = $(if ($a) { [string]$a.IntuneName } else { $app })
                        Anchored = [bool]$a; Product = $(if ($a) { [string]$a.Product } else { '' }); Manifest = $(if ($a) { [string]$a.Manifest } else { '' })
                        Installable = [bool]($a -and $a.Kind -eq 'msi' -and $a.Product); Why = $why; Installed = $inst
                    })
            }
        }
        [pscustomobject]@{ State = 'Ready'; Message = $state.Message; Items = @($items); Notes = @($notes) }
    }
    finally { $script:LibraryContext = $previousContext }
}

function Get-AVDTuneStreamHash($Stream) {
    $Stream.Position = 0
    $sha = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($sha.ComputeHash($Stream)) -replace '-', '').ToLowerInvariant() } finally { $sha.Dispose(); $Stream.Position = 0 }
}

$script:BeforeMsiHold = $null
$script:WorkSecurity = $null   # a check may set a scriptblock that returns the ACL (a developer run without elevation cannot write into a folder that only Administrators may write); it counts only inside the test mode
function Get-AVDTuneWorkSecurity {
    # The ACL for a new work folder level: always the protected admin-only one; the override of the checks only inside the test mode (Test-AVDTuneTestMode)
    if ($script:WorkSecurity -and (Test-AVDTuneTestMode).Enabled) { return (& $script:WorkSecurity) }
    New-AVDTuneStateSecurity
}

function Test-AVDTuneWorkLevelAcl {
    # An existing level below the state folder must be AVDTune's own: owner Administrators or SYSTEM (or the elevated administrator running AVDTune), protected, allow rules for Administrators and SYSTEM only.
    # Returns the problem as text, '' when it is fine. Inside the test mode with an override of the ACL the current user counts as trusted too.
    param([Parameter(Mandatory)][string]$Path)
    $trusted = @('S-1-5-32-544', 'S-1-5-18')
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $overridden = [bool]($script:WorkSecurity -and (Test-AVDTuneTestMode).Enabled)
    $owners = @($trusted); if ((Test-AVDTuneElevated) -or $overridden) { $owners += $me }
    $rules = @($trusted); if ($overridden) { $rules += $me }
    try { $acl = Read-AVDTuneAclInfo -Path $Path -IsDirectory $true } catch { return "the ACL cannot be read ($($_.Exception.Message))" }
    if ($acl.Owner -notin $owners) { return "owner $($acl.Owner)" }
    if (-not $acl.Protected) { return 'it inherits rules from its parent' }
    $foreign = @($acl.Rules | Where-Object { $_.Sid -notin $rules -or $_.Inherited } | ForEach-Object { $_.Sid } | Sort-Object -Unique)
    if ($foreign.Count -gt 0) { return "access for $($foreign -join ', ')" }
    ''
}

function New-AVDTuneWorkFolder {
    # Creates Path below Base level by level; each new folder is created in one step with the protected ACL (Administrators and SYSTEM only). A level that is a link is refused,
    # and so is an existing level whose owner or ACL is not AVDTune's own (someone else prepared it).
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Base)
    $baseFull = [IO.Path]::GetFullPath($Base).TrimEnd('\'); $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if (-not $full.StartsWith($baseFull + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'The work folder is not below the state folder.' }
    $parts = $full.Substring($baseFull.Length + 1) -split '[\\/]'
    $cur = $baseFull
    foreach ($p in $parts) {
        $cur = Join-Path $cur $p
        $d = New-Object IO.DirectoryInfo $cur
        if ($d.Exists) {
            if (($d.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "$cur is a link." }
            $problem = Test-AVDTuneWorkLevelAcl -Path $cur
            if ($problem) { throw "$cur was not prepared by AVDTune ($problem): not used." }
            continue
        }
        $d.Create((Get-AVDTuneWorkSecurity))
    }
}

function Clear-AVDTuneSoftwareWork {
    # Only inside a run, after the write gate: work folders that a crash left behind in <root>\software\work are removed (links as links, 'software' and 'work' themselves too). Returns the number removed.
    param([Parameter(Mandatory)][string]$Root)
    $soft = New-Object IO.DirectoryInfo (Join-Path $Root 'software')
    if (-not $soft.Exists) { return 0 }
    if (($soft.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $soft.Delete(); return 0 }
    $work = New-Object IO.DirectoryInfo (Join-Path $soft.FullName 'work')
    if (-not $work.Exists) { return 0 }
    if (($work.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $work.Delete(); return 0 }
    $n = 0
    foreach ($c in $work.GetDirectories()) { try { Remove-AVDTuneFolderNoFollow $c.FullName; $n++ } catch { } }
    $n
}

function Get-AVDTuneLibraryMsi {
    # The MSI of a downloaded package: the only .msi in the unpacked installer folder (links are not followed); otherwise the one the recipe names by file name
    param([Parameter(Mandatory)][string]$InstallerFolder, [string]$RecipePath)
    $root = [IO.Path]::GetFullPath($InstallerFolder).TrimEnd('\') + '\'
    $all = @(Get-ChildItem -LiteralPath $InstallerFolder -Recurse -File -Filter '*.msi' -ErrorAction SilentlyContinue | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0 -and $_.FullName.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) -and $_.Extension -ieq '.msi' })
    if ($all.Count -eq 1) { return $all[0].FullName }
    if ($all.Count -gt 1 -and $RecipePath -and (Test-Path -LiteralPath $RecipePath)) {
        $r = $null; try { $r = [IO.File]::ReadAllText($RecipePath) | ConvertFrom-Json } catch { }
        $entry = Get-AVDTuneProp $r 'EntryPoint'
        if ($entry -is [string] -and $entry -match '\A[A-Za-z0-9._ +()-]{1,120}\.msi\z') {
            $hit = @($all | Where-Object { $_.Name -ieq $entry })
            if ($hit.Count -eq 1) { return $hit[0].FullName }
        }
    }
    $null
}

#endregion

#region result, run, history

function New-AVDTuneSoftwareResult {
    # Same shape as a step result (the window's protocol hook reads Id, Section, Title, Status, Message) plus Group, Code, Source, Action
    param($Item, [string]$Status, [string]$Message = '', [string]$Code = '', [bool]$Reboot = $false, [string]$After = '', [string]$Fix = '', $Machine)
    [pscustomobject][ordered]@{
        Id = "$($Item.Source):$($Item.Id)"; Section = 'Software'; Title = [string]$Item.Title; Mode = 'Apply'; Status = $Status; Before = [string]$Item.Installed; After = $After; Message = $Message
        Reboot = $Reboot; WhatIf = ($Status -eq 'WhatIf'); At = (& $Machine.Now).ToString('o'); Group = 'Software'; Code = $Code; Fix = $Fix; Source = [string]$Item.Source; Action = [string]$Item.Action
    }
}

function New-AVDTuneSoftwareItem {
    # One wish: Action Install | Update | Remove, Source winget | chocolatey | library; Id (the package id, for the library the app id), Version (optional for the catalog, needed for the library)
    param([Parameter(Mandatory)][ValidateSet('Install', 'Update', 'Remove')][string]$Action, [Parameter(Mandatory)][ValidateSet('winget', 'chocolatey', 'library')][string]$Source, [Parameter(Mandatory)][string]$Id, [string]$Version = '', [string]$Title = '', [string]$Installed = '')
    [pscustomobject]@{ Action = $Action; Source = $Source; Id = $Id; Version = $Version; Title = $(if ($Title) { $Title } else { $Id }); Installed = $Installed }
}

function Test-AVDTuneSoftwareItem {
    # Throws before anything is started when a field is not what it must be
    param($Item)
    if ($Item.Source -eq 'library') {
        if ($Item.Id -cnotmatch $script:SegmentPattern -or $Item.Id -match '\.\.') { throw "'$($Item.Id)' is not a valid library package name." }
        if ($Item.Version -cnotmatch $script:SegmentPattern -or $Item.Version -match '\.\.') { throw "'$($Item.Version)' is not a valid library package version." }
        return
    }
    if (-not (Test-AVDTunePackageId $Item.Id)) { throw "'$($Item.Id)' is not a valid package id." }
    if ($Item.Version -and -not (Test-AVDTunePackageVersion $Item.Version)) { throw "'$($Item.Version)' is not a valid version." }
}

function Get-AVDTuneCatalogArguments {
    # The argument list of one catalog action: separate elements, fixed switches, only validated id and version
    param($Item)
    if ($Item.Source -eq 'winget') {
        $a = switch ($Item.Action) {
            'Install' { @('install', '--id', $Item.Id, '--exact', '--source', 'winget', '--silent', '--scope', 'machine', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity') }
            'Update' { @('upgrade', '--id', $Item.Id, '--exact', '--source', 'winget', '--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity') }
            'Remove' { @('uninstall', '--id', $Item.Id, '--exact', '--source', 'winget', '--silent', '--disable-interactivity') }
        }
        if ($Item.Version -and $Item.Action -ne 'Remove') { $a += @('--version', $Item.Version) }
        return , $a
    }
    $a = switch ($Item.Action) {
        'Install' { @('install', $Item.Id, '-y', '--no-progress') }
        'Update' { @('upgrade', $Item.Id, '-y', '--no-progress') }
        'Remove' { @('uninstall', $Item.Id, '-y', '--no-progress') }
    }
    if ($Item.Version -and $Item.Action -ne 'Remove') { $a += @('--version', $Item.Version) }
    , $a
}

function Invoke-AVDTuneCatalogItem {
    param($Machine, $U, $Item, [scriptblock]$Progress)
    $say = { param($t) if ($Progress) { & $Progress $t } }
    $new = { param($status, $msg, $code, $reboot, $after) New-AVDTuneSoftwareResult -Machine $Machine -Item $Item -Status $status -Message $msg -Code ([string]$code) -Reboot ([bool]$reboot) -After ([string]$after) }
    & $say "$($Item.Action): $($Item.Title) ($($Item.Source)) ..."
    $tool = if ($Item.Source -eq 'winget') { 'winget.exe' } else { 'choco.exe' }
    $r = Invoke-AVDTuneSoftwareTool -U $U -Tool $tool -Arguments (Get-AVDTuneCatalogArguments $Item) -TimeoutSeconds 3600
    if (-not $r.Ok) { return & $new 'Failed' $r.Error $r.Code $false '' }
    $past = switch ($Item.Action) { 'Install' { 'installed' } 'Update' { 'updated' } 'Remove' { 'removed' } }
    if ($r.ExitCode -in 0, 3010, 1641) { return & $new 'Changed' $(if ($r.ExitCode -eq 0) { "Package $past." } else { "Package $past, a restart is needed." }) '' ($r.ExitCode -ne 0) $past }
    if ($Item.Source -eq 'winget') {
        if ($Item.Action -eq 'Update' -and $r.ExitCode -eq $script:WingetNoUpgrade) { return & $new 'Unchanged' 'No newer version applies.' $r.ExitCode $false '' }
        if ($Item.Action -eq 'Install' -and $r.ExitCode -eq $script:WingetAlreadyInstalled) { return & $new 'Unchanged' 'The package is already installed.' $r.ExitCode $false '' }
        if ($Item.Action -eq 'Remove' -and $r.ExitCode -eq $script:WingetNotFound) { return & $new 'Unchanged' 'The package is not installed.' $r.ExitCode $false '' }
    }
    & $new 'Failed' (Resolve-AVDTuneSoftwareError $(if ($Item.Source -eq 'winget') { 'winget' } else { 'choco' }) $r.ExitCode $r.Output) $r.ExitCode $false ''
}

function Invoke-AVDTuneLibraryItem {
    <# Library package: download and verify against the Intune anchor into a new protected work folder, install or update with msiexec /i, or remove with msiexec /x {product}. The work folder is removed in every case. #>
    param($Machine, $U, $Item, $Context, [string]$Root, [scriptblock]$Progress)
    $say = { param($t) if ($Progress) { & $Progress $t } }
    $new = { param($status, $msg, $code, $reboot, $after) New-AVDTuneSoftwareResult -Machine $Machine -Item $Item -Status $status -Message $msg -Code ([string]$code) -Reboot ([bool]$reboot) -After ([string]$after) }
    if (-not $Context) { return & $new 'Failed' 'The library is not open (no site or not signed in).' 'NoLibrary' $false '' }
    $script:LibraryContext = $Context
    $work = $null
    try {
        & $say "Reading the library and the Intune anchor for $($Item.Title) ..."
        $lib = Get-AVDTuneLibraryItems -Context $Context -Machine $Machine
        $pkg = @($lib.Items | Where-Object { $_.AppId -ceq $Item.Id -and $_.Version -ceq $Item.Version }) | Select-Object -First 1
        if ($lib.State -ne 'Ready') { return & $new 'Failed' "The library is not ready: $($lib.Message)" $lib.State $false '' }
        if (-not $pkg) { return & $new 'Failed' "$($Item.Id) $($Item.Version) is not in the library (complete version)." 'NotFound' $false '' }
        if (-not $pkg.Installable) { return & $new 'Failed' $pkg.Why 'NoAnchor' $false '' }
        $log = Join-Path (Join-Path $Root 'logs') ("software-$($pkg.AppId)-$($pkg.Version)-$([guid]::NewGuid().ToString('N').Substring(0, 6)).log")
        if ($Item.Action -eq 'Remove') {
            $msiArgs = @('/x', $pkg.Product, '/qn', '/norestart', '/l*v', $log)
            & $say "Removing $($pkg.Name) ..."
            $r = Invoke-AVDTuneSoftwareTool -U $U -Tool 'msiexec.exe' -Arguments $msiArgs -TimeoutSeconds 3600
            if (-not $r.Ok) { return & $new 'Failed' $r.Error $r.Code $false '' }
            if ($r.ExitCode -in 0, 3010, 1641) { return & $new 'Changed' 'Package removed.' '' ($r.ExitCode -ne 0) 'removed' }
            if ($r.ExitCode -eq 1605) { return & $new 'Unchanged' 'The package is not installed.' $r.ExitCode $false '' }
            return & $new 'Failed' $(if ($r.ExitCode -eq 1618) { 'Another installation is running on this computer.' } else { "msiexec returned the exit code $($r.ExitCode)." }) $r.ExitCode $false ''
        }
        # download and check: the manifest against Intune, every file against the manifest; nothing is unpacked when something differs
        $softRoot = Join-Path $Root 'software'
        foreach ($d in $Root, $softRoot) { if (Test-Path -LiteralPath $d) { if (((Get-Item -LiteralPath $d -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return & $new 'Failed' "$d is a link: the library is not used." 'Link' $false '' } } }
        $work = Join-Path (Join-Path $softRoot 'work') ([guid]::NewGuid().ToString('N'))
        New-AVDTuneWorkFolder -Path $work -Base $Root   # every level made in one step with its own admin-only ACL (no moment without it, nothing inherited by chance)
        & $say "Downloading $($pkg.Name) $($pkg.Version) and checking it against Intune ..."
        $saved = Save-PackTuneStoreVersion -AppId $pkg.AppId -Version $pkg.Version -Destination (Join-Path $work 'package') -ExpectedManifest $pkg.Manifest -Store (Resolve-PackTuneStore -SiteUrl $Context.SiteUrl -Library $Context.Library)
        if (-not $saved.InstallerFolder) { return & $new 'Failed' 'The package has no installer.zip.' 'NoInstaller' $false '' }
        $msi = Get-AVDTuneLibraryMsi -InstallerFolder $saved.InstallerFolder -RecipePath (Join-Path $saved.Destination 'recipe.json')
        if (-not $msi) { return & $new 'Failed' 'The installer folder has no single MSI (and the recipe names none): this package cannot be installed here.' 'NoMsi' $false '' }
        # the MSI is hashed right after unpacking, then held open (read sharing only: nobody can change or replace it) and compared through the held handle;
        # a file that was replaced between unpacking and holding stops the install. (Whether msiexec can open a file held like this: issue 17.)
        $pre = [IO.File]::Open($msi, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try { $h1 = Get-AVDTuneStreamHash $pre } finally { $pre.Dispose() }
        if ($script:BeforeMsiHold -and (Test-AVDTuneTestMode).Enabled) { & $script:BeforeMsiHold $msi }   # a seam for the checks (the gap between hash and hold), only inside the test mode
        $hold = [IO.File]::Open($msi, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            if ((Get-AVDTuneStreamHash $hold) -ne $h1) { return & $new 'Failed' 'The installer changed after unpacking: not started.' 'Changed' $false '' }
            & $say "Installing $($pkg.Name) $($pkg.Version) ..."
            $r = Invoke-AVDTuneSoftwareTool -U $U -Tool 'msiexec.exe' -Arguments @('/i', $msi, '/qn', '/norestart', '/l*v', $log) -TimeoutSeconds 3600
        }
        finally { $hold.Dispose() }
        if (-not $r.Ok) { return & $new 'Failed' $r.Error $r.Code $false '' }
        if ($r.ExitCode -in 0, 3010, 1641) { return & $new 'Changed' $(if ($r.ExitCode -eq 0) { "Package $($Item.Action.ToLower())d." } else { "Package $($Item.Action.ToLower())d, a restart is needed." }) '' ($r.ExitCode -ne 0) $pkg.Version }
        & $new 'Failed' $(if ($r.ExitCode -eq 1618) { 'Another installation is running on this computer.' } else { "msiexec returned the exit code $($r.ExitCode); the log is $log." }) $r.ExitCode $false ''
    }
    catch { & $new 'Failed' $_.Exception.Message 'Exception' $false '' }
    finally {
        $script:LibraryContext = $null
        if ($work) { try { Remove-AVDTuneFolderNoFollow $work } catch { } }
    }
}

function Invoke-AVDTuneSoftwareRun {
    <#
        Runs the wishes (New-AVDTuneSoftwareItem) one after the other. Needs the open write gate (thrown otherwise), sets LastChange before the first one
        (so the snapshot gate sees it even when a run fails), writes one run record (Plan 'Software') and a change log entry per package that changed or
        failed, and LastUpdate when something was updated. -WhatIf lists what would run and changes nothing. Every item is checked before any starts.
        Returns @{ WhatIf; Results; Run; Reboot }.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Machine, [Parameter(Mandatory)]$U, [string]$Root = (Get-AVDTuneRoot), [Parameter(Mandatory)][object[]]$Items, $LibraryContext, [string]$User, [string]$SnapshotId, [scriptblock]$Progress, [switch]$WhatIf)
    $list = @($Items | Where-Object { $_ })
    foreach ($i in $list) { Test-AVDTuneSoftwareItem $i }
    if ($WhatIf) { return [pscustomobject]@{ WhatIf = $true; Results = @($list | ForEach-Object { New-AVDTuneSoftwareResult -Machine $Machine -Item $_ -Status 'WhatIf' -Message 'Would run.' }); Run = $null; Reboot = $false } }
    if (-not (Test-AVDTuneWriteAllowed)) { throw 'The snapshot gate is not confirmed: AVDTune is read only until a snapshot of today is confirmed on the Overview.' }
    if ($list.Count -eq 0) { return [pscustomobject]@{ WhatIf = $false; Results = @(); Run = $null; Reboot = $false } }
    $started = & $Machine.Now
    $changeOwner = Start-AVDTuneChange -Root $Root   # marker while the master is written (snapshot gate, #27/#81), cleared in finally (Stop stamps LastChange, also after an abort)
    try {
    [void](Clear-AVDTuneSoftwareWork -Root $Root)   # the cleanup of left work folders is a write too: under the marker (#81)
    [void](Set-AVDTuneState -Root $Root -Values @{ LastChange = $started.ToString('o') })
    $results = New-Object System.Collections.ArrayList
    foreach ($item in $list) {
        try {
            if ($item.Source -eq 'library') { [void]$results.Add((Invoke-AVDTuneLibraryItem -Machine $Machine -U $U -Item $item -Context $LibraryContext -Root $Root -Progress $Progress)) }
            else { [void]$results.Add((Invoke-AVDTuneCatalogItem -Machine $Machine -U $U -Item $item -Progress $Progress)) }
        }
        catch { [void]$results.Add((New-AVDTuneSoftwareResult -Machine $Machine -Item $item -Status 'Failed' -Message "Unexpected error: $($_.Exception.Message)" -Code 'Exception')) }
    }
    $state = Get-AVDTuneState $Root
    $run = [pscustomobject][ordered]@{
        Id = $null; Plan = 'Software'; Started = $started.ToString('o'); Ended = (& $Machine.Now).ToString('o'); User = $User; SnapshotId = $SnapshotId; WhatIf = $false
        ImageVersion = $state.ImageVersion; Reboot = [bool](@($results | Where-Object { $_.Reboot }).Count); Results = @($results)
    }
    [void](Add-AVDTuneRun -Root $Root -Run $run)
    if (@($results | Where-Object { $_.Status -eq 'Changed' -and $_.Action -eq 'Update' }).Count -gt 0) { [void](Set-AVDTuneState -Root $Root -Values @{ LastUpdate = $started.ToString('yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture) }) }
    if (@($results | Where-Object { $_.Status -in 'Changed', 'Failed' }).Count -gt 0) { [void](Set-AVDTuneState -Root $Root -Values @{ LastChange = (& $Machine.Now).ToString('o') }) }
    if ($state.ImageVersion) {
        foreach ($r in $results) {
            if ($r.Status -notin 'Changed', 'Failed') { continue }
            $type = if ($r.Status -eq 'Failed') { 'Note' } else { switch ($r.Action) { 'Install' { 'Added' } 'Update' { 'Updated' } default { 'Removed' } } }
            $src = switch ($r.Source) { 'winget' { 'winget' } 'chocolatey' { 'Chocolatey' } default { 'PackTune library' } }
            $text = if ($r.Status -eq 'Changed') { "$($r.Title) ($src): $($r.Action.ToLower()) done$(if ($r.After -and $r.After -notin 'installed', 'updated', 'removed') { ", version $($r.After)" })" } else { "$($r.Title) ($src): $($r.Action.ToLower()) FAILED$(if ($r.Code) { " ($($r.Code))" }) - $($r.Message)" }
            [void](Add-AVDTuneChangeLogEntry -Root $Root -Version $state.ImageVersion -Category 'Software' -Component $src -ChangeType $type -Text $text -User $User -SnapshotId $SnapshotId -RunId $run.Id -Source Step)
        }
    }
    [pscustomobject]@{ WhatIf = $false; Results = @($results); Run = $run; Reboot = $run.Reboot }
    }
    finally { Stop-AVDTuneChange -Root $Root -Owner $changeOwner }
}

function Get-AVDTuneSoftwareHistory {
    # The results of all software runs, newest first
    param([string]$Root = (Get-AVDTuneRoot), [int]$Last = 50)
    $rows = New-Object System.Collections.ArrayList
    foreach ($run in @(Get-AVDTuneRun -Root $Root)) {
        if (-not $run -or [string](Get-AVDTuneProp $run 'Plan') -ne 'Software') { continue }
        foreach ($r in @($run.Results)) { if ($r) { [void]$rows.Add([pscustomobject]@{ At = [string]$r.At; Title = [string]$r.Title; Action = [string](Get-AVDTuneProp $r 'Action'); Status = [string]$r.Status; Code = [string](Get-AVDTuneProp $r 'Code'); Message = [string]$r.Message; RunId = [string]$run.Id }) } }
    }
    @($rows | Sort-Object { [datetime]$_.At } -Descending | Select-Object -First $Last)
}

#endregion

Export-ModuleMember -Function Get-AVDTuneSoftwareSettings, Set-AVDTuneSoftwareSettings, Test-AVDTunePackageId, Test-AVDTunePackageVersion, Test-AVDTuneSearchText, Compare-AVDTuneVersion,
    ConvertFrom-AVDTuneWingetTable, ConvertFrom-AVDTuneChocoPackages, ConvertFrom-AVDTuneIntuneNote, Get-AVDTuneInstalledSoftware, Test-AVDTuneMsiexecTrust, Invoke-AVDTuneSoftwareTool,
    Search-AVDTuneCatalog, Get-AVDTuneManagedSoftware, Test-AVDTuneLibraryUrl, Test-AVDTuneDownloadUrl, New-AVDTuneLibraryContext, Close-AVDTuneLibraryContext, Get-AVDTuneLibraryItems,
    New-AVDTuneSoftwareItem, Get-AVDTuneCatalogArguments, Invoke-AVDTuneSoftwareRun, Get-AVDTuneSoftwareHistory, Expand-PackTuneZip, Get-AVDTuneRedirectHosts, Invoke-AVDTuneLibraryGet, Read-AVDTuneLimited, Clear-AVDTuneSoftwareWork, New-AVDTuneWorkFolder
