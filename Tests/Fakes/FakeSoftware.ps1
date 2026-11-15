# Fake of the PackTune package store (SharePoint through Graph) and of the Intune app notes, for Modules\AVDTune.Software.psm1: it is the replaceable
# GET of the library context (New-AVDTuneLibraryContext -Http). No network, no tenant. Everything asked is in .Log (URL and which token was sent, never the token).
# Dot-source this file, then:
#   $lib = New-AVDTuneFakeLibrary
#   Add-AVDTuneFakeLibraryPackage $lib -App 'contoso-tool' -Version '1.0.0' -Kind msi -Product '{...}' [-Name ...] [-NoAnchor] [-AnchorPrefix] ...
#   $ctx = New-AVDTuneLibraryContext -SitesToken $lib.SitesToken -GraphToken $lib.GraphToken -SiteUrl $lib.SiteUrl -Http $lib.Http
# Switches in .Store: Offline (every request fails), IntuneOffline, Tamper = 'app/ver/file' (the bytes in the store differ from the manifest),
# WrongAnchor = 'app|ver' (Intune carries another manifest hash), Redirect (downloads answer through a redirect: not followed by the fake, the real code does that).
# All names are made up.

function New-AVDTuneFakeLibrary {
    $s = @{ Files = @{}; Notes = New-Object System.Collections.ArrayList; Offline = $false; IntuneOffline = $false; Tamper = @{}; Log = (New-Object System.Collections.ArrayList) }
    $lib = [ordered]@{ Store = $s; Log = $s.Log; SitesToken = 'fake-sites-token-AAA'; GraphToken = 'fake-graph-token-BBB'; SiteUrl = 'https://contoso.sharepoint.com/sites/PackTune'; Library = 'PackTune Packages' }
    $json = { param($o) $o | ConvertTo-Json -Depth 8 | ConvertFrom-Json }
    $lib.Http = {
        param($Url, $Token, $OutFile)
        $kind = if ($Url -match '/deviceAppManagement/') { 'graph' } else { 'sites' }
        [void]$s.Log.Add("GET $kind $Url")
        if ($s.Offline) { throw 'The remote name could not be resolved (fake)' }
        $want = if ($kind -eq 'graph') { $lib.GraphToken } else { $lib.SitesToken }
        if ($Token -ne $want) { throw "Graph answered 403 (fake: the $kind request carried the token of the other audience)" }
        $path = ($Url -replace '^https://graph\.microsoft\.com/v1\.0', '')
        $q = ''; if ($path.Contains('?')) { $q = $path.Substring($path.IndexOf('?')); $path = $path.Substring(0, $path.IndexOf('?')) }
        if ($path -match '^/deviceAppManagement/mobileApps$') {
            if ($s.IntuneOffline) { throw 'Graph answered 503 (fake)' }
            return (& $json @{ value = @($s.Notes | ForEach-Object { @{ id = [guid]::NewGuid().ToString(); displayName = $_.Name; notes = $_.Text } }) })
        }
        if ($path -match '^/sites/([^/:]+):/sites/([A-Za-z0-9._-]+)$') { if ($Matches[1] -ne 'contoso.sharepoint.com' -or $Matches[2] -ne 'PackTune') { throw 'Graph answered 404 (itemNotFound) (fake)' }; return (& $json @{ id = 'site-1'; displayName = 'PackTune'; webUrl = $lib.SiteUrl }) }
        if ($path -match '^/sites/site-1/drives$') { return (& $json @{ value = @(@{ id = 'drive-1'; name = $lib.Library; webUrl = "$($lib.SiteUrl)/lib" }) }) }
        $decode = { param($t) [uri]::UnescapeDataString($t) }
        $names = $null; $content = $false
        if ($path -match '^/drives/drive-1/root/children$') { $names = @() }
        elseif ($path -match '^/drives/drive-1/root:/(.+):/children$') { $names = @(($Matches[1] -split '/') | ForEach-Object { & $decode $_ }) }
        elseif ($path -match '^/drives/drive-1/root:/(.+):/content$') { $names = @(($Matches[1] -split '/') | ForEach-Object { & $decode $_ }); $content = $true }
        if ($null -eq $names) { throw "fake: no route for $path" }
        if ($content) {
            $key = $names -join '/'
            if (-not $s.Files.ContainsKey($key)) { throw 'Graph answered 404 (itemNotFound) (fake)' }
            $bytes = $s.Files[$key]
            if ($s.Tamper.ContainsKey($key)) { $bytes = $s.Tamper[$key] }
            [IO.File]::WriteAllBytes($OutFile, $bytes) | Out-Null
            return $null
        }
        $prefix = if ($names.Count) { ($names -join '/') + '/' } else { '' }
        $seen = @{}
        foreach ($k in $s.Files.Keys) {
            if (-not $k.StartsWith($prefix)) { continue }
            $rest = $k.Substring($prefix.Length).Split('/')
            if ($rest.Count -gt 1) { $seen[$rest[0]] = @{ name = $rest[0]; size = 0; folder = @{ childCount = 1 } } } else { $seen[$rest[0]] = @{ name = $rest[0]; size = $s.Files[$k].Length } }
        }
        if ($prefix -eq '' -and $s.Files.Count -gt 0) { $seen['Protocols'] = @{ name = 'Protocols'; size = 0; folder = @{ childCount = 0 } } }
        & $json @{ value = @($seen.Values) }
    }.GetNewClosure()
    [pscustomobject]$lib
}

function New-AVDTuneFakeZip {
    # A zip from name -> bytes (or text), made with System.IO.Compression; -RawEntries lets a test write an entry name as it is (zip slip)
    param([Parameter(Mandatory)][hashtable]$Entries)
    Add-Type -AssemblyName System.IO.Compression
    $ms = New-Object IO.MemoryStream
    $zip = New-Object IO.Compression.ZipArchive($ms, [IO.Compression.ZipArchiveMode]::Create, $true)
    foreach ($n in $Entries.Keys) {
        $e = $zip.CreateEntry($n); $bytes = if ($Entries[$n] -is [byte[]]) { $Entries[$n] } else { [Text.Encoding]::UTF8.GetBytes([string]$Entries[$n]) }
        $st = $e.Open(); try { $st.Write($bytes, 0, $bytes.Length) } finally { $st.Dispose() }
    }
    $zip.Dispose()
    , $ms.ToArray()
}

function Add-AVDTuneFakeLibraryPackage {
    <# One complete version in the store (package, installer.zip with one MSI stand-in, recipe, manifest written last) and, unless -NoAnchor, the Intune app with the notes. #>
    param(
        [Parameter(Mandatory)]$Library, [Parameter(Mandatory)][string]$App, [Parameter(Mandatory)][string]$Version, [string]$Kind = 'msi', [string]$Product = '{11111111-2222-3333-4444-555555555555}',
        [string]$Name = '', [switch]$NoAnchor, [switch]$AnchorPrefix, [hashtable]$InstallerEntries, [switch]$NoProduct, [switch]$NoManifest, [string]$EntryPoint = 'tool.msi'
    )
    $s = $Library.Store
    $entries = if ($InstallerEntries) { $InstallerEntries } else { @{ 'setup/tool.msi' = 'MSI stand-in' } }
    $files = [ordered]@{
        'package.intunewin' = [Text.Encoding]::UTF8.GetBytes("intunewin of $App $Version")
        'installer.zip' = (New-AVDTuneFakeZip $entries)
        'recipe.json' = [Text.Encoding]::UTF8.GetBytes((@{ Name = 'x'; EntryPoint = $EntryPoint } | ConvertTo-Json -Compress))
    }
    $list = @()
    foreach ($n in $files.Keys) {
        $s.Files["$App/$Version/$n"] = [byte[]]$files[$n]
        $list += [ordered]@{ name = $n; sha256 = ([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([byte[]]$files[$n])) -replace '-', ''); size = $files[$n].Length }
    }
    $manifest = [ordered]@{ format = 'PackTune.Store'; version = 1; app = $App; appVersion = $Version; kind = $Kind; created = '2026-11-15T10:00:00Z'; files = @($list) }
    $mbytes = [Text.Encoding]::UTF8.GetBytes(($manifest | ConvertTo-Json -Depth 6))
    if (-not $NoManifest) { $s.Files["$App/$Version/manifest.json"] = $mbytes }
    $hash = ([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($mbytes)) -replace '-', '').ToLowerInvariant()
    if ($NoAnchor) { return $hash }
    $anchor = if ($AnchorPrefix) { $hash.Substring(0, 16) } else { $hash }
    $text = "Packaged by PackTune. PoweredByPackTune;kind=$Kind;app=$App;ver=$Version;$(if (-not $NoProduct) { "product=$Product;" })manifest=$anchor"
    [void]$s.Notes.Add(@{ Name = $(if ($Name) { $Name } else { $App }); Text = $text })
    $hash
}
