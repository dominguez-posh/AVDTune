# Fake of the PackTune package store (SharePoint through Graph) and of the Intune app notes, for Modules\AVDTune.Software.psm1. It is the TRANSPORT of the library
# context (one request: status, headers, stream), so the real loop of Invoke-AVDTuneLibraryGet runs in the checks: redirects, the token only to Graph, limits, paging.
# No network, no tenant. Everything asked is in .Log ("GET host auth=True|False path", never a token).
# Dot-source this file, then:
#   $lib = New-AVDTuneFakeLibrary
#   Add-AVDTuneFakeLibraryPackage $lib -App 'contoso-tool' -Version '1.0.0' -Kind msi -Product '{...}' [-Name ...] [-NoAnchor] [-AnchorPrefix] [-WrongAnchor] ...
#   $ctx = New-AVDTuneLibraryContext -SitesToken $lib.SitesToken -GraphToken $lib.GraphToken -SiteUrl $lib.SiteUrl -Transport $lib.Transport
# Switches in .Store: Offline, IntuneOffline, Tamper = hashtable 'app/ver/file' -> bytes (the store sends other bytes than the manifest names, also more of them),
# Redirect (downloads answer 302 to SharePoint, which refuses a bearer token), RedirectTo (url of the first redirect instead, e.g. a foreign host),
# RedirectEmpty (the first redirect has an empty Location), RedirectRelative (the hops of RedirectHops carry a relative Location),
# RedirectHops (chain of n redirects before the content), PageSize (Intune answers in pages with @odata.nextLink).
# All names are made up.

function New-AVDTuneFakeLibrary {
    $s = @{ Files = @{}; Notes = New-Object System.Collections.ArrayList; Offline = $false; IntuneOffline = $false; Tamper = @{}; Log = (New-Object System.Collections.ArrayList)
        Redirect = $false; RedirectTo = ''; RedirectEmpty = $false; RedirectRelative = $false; RedirectHops = 0; PageSize = 0; HopKey = '' }
    $lib = [ordered]@{ Store = $s; Log = $s.Log; SitesToken = 'fake-sites-token-AAA'; GraphToken = 'fake-graph-token-BBB'; SiteUrl = 'https://contoso.sharepoint.com/sites/PackTune'; Library = 'PackTune Packages' }
    $answer = { param($status, $bytes, $location) @{ Status = $status; Headers = @{ Location = $location }; Stream = (New-Object IO.MemoryStream (, [byte[]]$bytes)); Close = { } } }
    $enc = { param($o) , [Text.Encoding]::UTF8.GetBytes(($o | ConvertTo-Json -Depth 8 -Compress)) }
    $empty = [byte[]]@()
    $lib.Transport = {
        param($Url, $Headers)
        $uri = [Uri]$Url
        $hasAuth = $Headers.ContainsKey('Authorization')
        [void]$s.Log.Add("GET $($uri.Host) auth=$hasAuth $($uri.PathAndQuery)")
        if ($s.Offline) { throw 'The remote name could not be resolved (fake)' }
        if ($uri.Host -ne 'graph.microsoft.com') {
            # a SharePoint download address: asked WITH the token it answers 401, like the real one to a foreign bearer token
            if ($hasAuth) { return (& $answer 401 $empty '') }
            if ($uri.AbsolutePath -match '^/hop/(\d+)$') {
                $n = [int]$Matches[1]
                if ($n -lt $s.RedirectHops) { return (& $answer 302 $empty $(if ($s.RedirectRelative) { "/hop/$($n + 1)" } else { "https://$($uri.Host)/hop/$($n + 1)" })) }
                $bytes = $s.Files[[string]$s.HopKey]; return (& $answer 200 $bytes '')
            }
            if ($uri.AbsolutePath -match '^/dl/(.+)$') { $key = [uri]::UnescapeDataString($Matches[1]); $bytes = $s.Files[$key]; if ($s.Tamper.ContainsKey($key)) { $bytes = $s.Tamper[$key] }; return (& $answer 200 $bytes '') }
            return (& $answer 404 $empty '')
        }
        if (-not $hasAuth) { return (& $answer 401 $empty '') }
        $bearer = $Headers['Authorization'] -replace '^Bearer ', ''
        $isIntune = $uri.AbsolutePath -match '/deviceAppManagement/'
        $want = if ($isIntune) { $lib.GraphToken } else { $lib.SitesToken }
        if ($bearer -ne $want) { return (& $answer 403 $empty '') }   # the token of the other audience
        $path = $uri.AbsolutePath -replace '^/v1\.0', ''
        if ($path -eq '/deviceAppManagement/mobileApps') {
            if ($s.IntuneOffline) { return (& $answer 503 $empty '') }
            $skip = 0; if ($uri.Query -match 'skip=(\d+)') { $skip = [int]$Matches[1] }
            $all = @($s.Notes | ForEach-Object { @{ id = [guid]::NewGuid().ToString(); displayName = $_.Name; notes = $_.Text } })
            $page = if ($s.PageSize -gt 0) { @($all | Select-Object -Skip $skip -First $s.PageSize) } else { $all }
            $body = @{ value = @($page) }
            if ($s.PageSize -gt 0 -and ($skip + $s.PageSize) -lt $all.Count) { $body['@odata.nextLink'] = "https://graph.microsoft.com/v1.0/deviceAppManagement/mobileApps?`$skip=$($skip + $s.PageSize)" }
            return (& $answer 200 (& $enc $body) '')
        }
        if ($path -match '^/sites/([^/:]+):/sites/([A-Za-z0-9._-]+)$') { if ($Matches[1] -ne 'contoso.sharepoint.com' -or $Matches[2] -ne 'PackTune') { return (& $answer 404 $empty '') }; return (& $answer 200 (& $enc @{ id = 'site-1'; displayName = 'PackTune'; webUrl = $lib.SiteUrl }) '') }
        if ($path -match '^/sites/site-1/drives$') { return (& $answer 200 (& $enc @{ value = @(@{ id = 'drive-1'; name = $lib.Library; webUrl = "$($lib.SiteUrl)/lib" }) }) '') }
        $decode = { param($t) [uri]::UnescapeDataString($t) }
        $names = $null; $content = $false
        if ($path -match '^/drives/drive-1/root/children$') { $names = @() }
        elseif ($path -match '^/drives/drive-1/root:/(.+):/children$') { $names = @(($Matches[1] -split '/') | ForEach-Object { & $decode $_ }) }
        elseif ($path -match '^/drives/drive-1/root:/(.+):/content$') { $names = @(($Matches[1] -split '/') | ForEach-Object { & $decode $_ }); $content = $true }
        if ($null -eq $names) { return (& $answer 404 $empty '') }
        if ($content) {
            $key = $names -join '/'
            if (-not $s.Files.ContainsKey($key)) { return (& $answer 404 $empty '') }
            if ($s.Redirect -and $key -notlike '*manifest.json') {
                if ($s.RedirectEmpty) { return (& $answer 302 $empty '') }
                if ($s.RedirectTo) { return (& $answer 302 $empty $s.RedirectTo) }
                $s.HopKey = $key
                $target = if ($s.RedirectHops -gt 0) { 'https://contoso.sharepoint.com/hop/1' } else { "https://contoso.sharepoint.com/dl/$([uri]::EscapeDataString($key))" }
                return (& $answer 302 $empty $target)
            }
            $bytes = $s.Files[$key]; if ($s.Tamper.ContainsKey($key)) { $bytes = $s.Tamper[$key] }
            return (& $answer 200 $bytes '')
        }
        $prefix = if ($names.Count) { ($names -join '/') + '/' } else { '' }
        $seen = @{}
        foreach ($k in $s.Files.Keys) {
            if (-not $k.StartsWith($prefix)) { continue }
            $rest = $k.Substring($prefix.Length).Split('/')
            if ($rest.Count -gt 1) { $seen[$rest[0]] = @{ name = $rest[0]; size = 0; folder = @{ childCount = 1 } } } else { $seen[$rest[0]] = @{ name = $rest[0]; size = $s.Files[$k].Length } }
        }
        if ($prefix -eq '' -and $s.Files.Count -gt 0) { $seen['Protocols'] = @{ name = 'Protocols'; size = 0; folder = @{ childCount = 0 } } }
        & $answer 200 (& $enc @{ value = @($seen.Values) }) ''
    }.GetNewClosure()
    [pscustomobject]$lib
}

function New-AVDTuneFakeZip {
    # A zip from name -> bytes (or text), made with System.IO.Compression
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
    <# One complete version in the store (package, installer.zip with one MSI stand-in, recipe, manifest written last) and, unless -NoAnchor, the Intune app with the notes. -WrongAnchor: Intune carries another manifest hash. #>
    param(
        [Parameter(Mandatory)]$Library, [Parameter(Mandatory)][string]$App, [Parameter(Mandatory)][string]$Version, [string]$Kind = 'msi', [string]$Product = '{11111111-2222-3333-4444-555555555555}',
        [string]$Name = '', [switch]$NoAnchor, [switch]$AnchorPrefix, [hashtable]$InstallerEntries, [switch]$NoProduct, [switch]$NoManifest, [switch]$WrongAnchor, [string]$EntryPoint = 'tool.msi'
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
    $anchor = if ($WrongAnchor) { '0' * 64 } elseif ($AnchorPrefix) { $hash.Substring(0, 16) } else { $hash }
    $text = "Packaged by PackTune. PoweredByPackTune;kind=$Kind;app=$App;ver=$Version;$(if (-not $NoProduct) { "product=$Product;" })manifest=$anchor"
    [void]$s.Notes.Add(@{ Name = $(if ($Name) { $Name } else { $App }); Text = $text })
    $hash
}
