# Fake Microsoft Graph for the SharePoint uploads of Modules\AVDTune.SharePoint.psm1 (#89). It is the TRANSPORT of the upload context (one request: method, url,
# headers, body; it answers status, headers and a stream), so the real rules of Invoke-AVDTuneSpRequest run in the checks: token only to Graph, paging, throttling,
# limits, validated ids. It behaves like the real Graph where that matters: a site by host and path, lists by display name, columns, items with fields, the default
# document library, a simple upload (PUT .../content) that replaces a file of the same name, item metadata with the size.
# No network, no tenant: the site ids are made at the start. Every request is in .Log ("METHOD path", never a token); every body that came in is in .Bodies (text).
# Dot-source this file, then:
#   $sp = New-AVDTuneFakeSharePoint
#   $ctx = New-AVDTuneSpContext -Token $sp.Token -SiteUrl $sp.SiteUrl -Transport $sp.Transport -Sleep $sp.Sleep
# Switches in .Store: Offline (throws like a missing network), Throttle (the next n requests answer 429 with RetryAfter), RetryAfter (text of the header),
# PageSize (collections answer in pages with @odata.nextLink), NextLinkTo (the first nextLink points there instead), Forbidden (403 to every write),
# BadSiteId (the site lookup answers an id of another host), WrongSize (the read back size of an upload is one byte more), Redirect (a write answers 302),
# DuplicateList (a second list of the change log name exists), Huge (an answer larger than 4 MB).
# All names are made up.

. $(if (Get-Command Resolve-AVDTuneTestScript -ErrorAction Ignore) { $fakeShared = Resolve-AVDTuneTestScript -Path (Join-Path $PSScriptRoot 'FakeShared.ps1') -AppRoot (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent); if (-not $fakeShared) { throw 'FakeShared.ps1 is not a file below the Tests folder of this copy.' }; $fakeShared } else { Join-Path $PSScriptRoot 'FakeShared.ps1' })   # fakes that several runspaces use at once (#80)
function New-AVDTuneFakeSharePoint {
    param([string]$SiteUrl = 'https://contoso.sharepoint.com/sites/AVD-Environment')
    $siteHost = ([Uri]$SiteUrl).Host
    $siteName = ([Uri]$SiteUrl).AbsolutePath.Trim('/').Split('/')[1]
    $s = @{ Lists = [ordered]@{}; Files = @{}; Items = @{}; Log = (New-Object System.Collections.ArrayList); Bodies = (New-Object System.Collections.ArrayList); Waits = (New-Object System.Collections.ArrayList)
        Offline = $false; Throttle = 0; RetryAfter = '7'; PageSize = 0; NextLinkTo = ''; Forbidden = $false; BadSiteId = $false; WrongSize = $false; Redirect = $false; DuplicateList = $false; Huge = $false
        SiteId = "$siteHost,$([guid]::NewGuid()),$([guid]::NewGuid())"; DriveId = 'b!fakeDrive0001AVDTune'; NextItem = 1 }
    $sp = [ordered]@{ Store = $s; Log = $s.Log; Token = 'fake-sp-token-CCC'; SiteUrl = $SiteUrl }
    $answer = { param($status, $obj, $retry) $bytes = New-Object byte[] 0; if ($null -ne $obj) { $bytes = [Text.Encoding]::UTF8.GetBytes(($obj | ConvertTo-Json -Depth 10 -Compress)) }; @{ Status = $status; Headers = @{ RetryAfter = [string]$retry }; Stream = (New-Object IO.MemoryStream (, [byte[]]$bytes)); Close = { } } }
    $page = {
        # one page of a collection: $skiptoken=<n> in the query; PageSize 0 = everything at once
        param($uri, $rows)
        $skip = 0; if ($uri.Query -match 'skiptoken=(\d+)') { $skip = [int]$Matches[1] }
        $all = @($rows)
        if ($s.PageSize -le 0) { return @{ value = $all } }
        $body = @{ value = @($all | Select-Object -Skip $skip -First $s.PageSize) }
        if (($skip + $s.PageSize) -lt $all.Count) {
            $q = ($uri.Query.TrimStart('?') -replace '&?\$skiptoken=\d+', '')
            $next = "https://graph.microsoft.com$($uri.AbsolutePath)?$q&`$skiptoken=$($skip + $s.PageSize)"
            if ($s.NextLinkTo) { $next = $s.NextLinkTo; $s.NextLinkTo = '' }
            $body['@odata.nextLink'] = $next
        }
        $body
    }
    $sp.Sleep = { param($Seconds) [void]$s.Waits.Add([int]$Seconds) }.GetNewClosure()
    $sp.Transport = {
        param($Method, $Url, $Headers, $Body, $ContentType)
        $uri = [Uri]$Url
        [void]$s.Log.Add("$Method $($uri.AbsolutePath)")
        if ($null -ne $Body) { [void]$s.Bodies.Add([Text.Encoding]::UTF8.GetString([byte[]]$Body)) }
        if ($s.Offline) { throw 'The remote name could not be resolved (fake)' }
        if ($uri.Host -ne 'graph.microsoft.com') { return (& $answer 404 $null '') }
        if ([string]$Headers['Authorization'] -ne "Bearer $($sp.Token)") { return (& $answer 401 @{ error = @{ code = 'InvalidAuthenticationToken' } } '') }
        if ($s.Throttle -gt 0) { $s.Throttle--; return (& $answer 429 @{ error = @{ code = 'TooManyRequests' } } $s.RetryAfter) }
        if ($Method -ne 'GET' -and $s.Forbidden) { return (& $answer 403 @{ error = @{ code = 'accessDenied' } } '') }
        if ($Method -ne 'GET' -and $s.Redirect) { $r = & $answer 302 $null ''; return $r }
        if ($s.Huge) { $r = & $answer 200 $null ''; $r.Stream = New-Object IO.MemoryStream (, (New-Object byte[] (4MB + 10))); return $r }
        $path = [uri]::UnescapeDataString($uri.AbsolutePath) -replace '^/v1\.0', ''
        $json = $null; if ($null -ne $Body -and $ContentType -eq 'application/json') { $json = [Text.Encoding]::UTF8.GetString([byte[]]$Body) | ConvertFrom-Json }
        $sid = [regex]::Escape($s.SiteId)
        if ($Method -eq 'GET' -and $path -match '^/sites/([^/:]+):/(sites|teams)/([^/]+)$') {
            if ($Matches[1] -ne $siteHost -or $Matches[3] -ne $siteName) { return (& $answer 404 @{ error = @{ code = 'itemNotFound' } } '') }
            $id = if ($s.BadSiteId) { "fabrikam.sharepoint.com,$([guid]::NewGuid()),$([guid]::NewGuid())" } else { $s.SiteId }
            return (& $answer 200 @{ id = $id } '')
        }
        if ($Method -eq 'GET' -and $path -match "^/sites/$sid/drive$") { return (& $answer 200 @{ id = $s.DriveId } '') }
        if ($path -match "^/sites/$sid/lists$") {
            if ($Method -eq 'GET') {
                $rows = @($s.Lists.Keys | ForEach-Object { @{ id = $_; displayName = $s.Lists[$_].Name } })
                return (& $answer 200 (& $page $uri $rows) '')
            }
            if ($Method -eq 'POST') {
                $id = [guid]::NewGuid().ToString()
                $s.Lists[$id] = @{ Name = [string]$json.displayName; Columns = (New-Object System.Collections.ArrayList); Items = (New-Object System.Collections.ArrayList) }
                foreach ($c in @($json.columns)) { [void]$s.Lists[$id].Columns.Add([string]$c.name) }
                return (& $answer 201 @{ id = $id; displayName = [string]$json.displayName } '')
            }
        }
        if ($path -match "^/sites/$sid/lists/([0-9a-f-]{36})/(columns|items)$") {
            $l = $s.Lists[$Matches[1]]; $what = $Matches[2]
            if (-not $l) { return (& $answer 404 @{ error = @{ code = 'itemNotFound' } } '') }
            if ($what -eq 'columns' -and $Method -eq 'GET') { return (& $answer 200 (& $page $uri @(@('Title', 'Created', 'Modified') + @($l.Columns) | ForEach-Object { @{ name = $_ } })) '') }
            if ($what -eq 'columns' -and $Method -eq 'POST') { [void]$l.Columns.Add([string]$json.name); return (& $answer 201 @{ name = [string]$json.name } '') }
            if ($what -eq 'items' -and $Method -eq 'GET') {
                # like the real Graph: $expand=fields($select=...) gives only the named fields
                $sel = @(); if ($uri.Query -match 'fields\(\$select=([A-Za-z,]+)\)') { $sel = $Matches[1] -split ',' }
                $rows = @(for ($i = 0; $i -lt $l.Items.Count; $i++) { $f = @{}; foreach ($k in $l.Items[$i].Keys) { if (-not $sel -or $k -in $sel) { $f[$k] = $l.Items[$i][$k] } }; @{ id = [string]($i + 1); fields = $f } })
                return (& $answer 200 (& $page $uri $rows) '')
            }
            if ($what -eq 'items' -and $Method -eq 'POST') {
                $f = @{}; foreach ($p in $json.fields.PSObject.Properties) { if ($p.Name -notin @($l.Columns) -and $p.Name -ne 'Title') { return (& $answer 400 @{ error = @{ code = 'invalidRequest' } } '') }; $f[$p.Name] = $p.Value }
                [void]$l.Items.Add($f)
                return (& $answer 201 @{ id = [string]$l.Items.Count } '')
            }
        }
        $drv = [regex]::Escape($s.DriveId)
        if ($Method -eq 'PUT' -and $path -match "^/drives/$drv/root:/(.+):/content$") {
            $key = $Matches[1]
            $id = if ($s.Items.ContainsKey("path:$key")) { $s.Items["path:$key"] } else { 'FAKEITEM' + ($s.NextItem++).ToString('0000') }
            $s.Files[$key] = [byte[]]$Body; $s.Items["path:$key"] = $id; $s.Items[$id] = $key
            return (& $answer 201 @{ id = $id; name = ($key -split '/')[-1]; size = $Body.Length } '')
        }
        if ($Method -eq 'GET' -and $path -match "^/drives/$drv/items/([A-Za-z0-9]+)$") {
            $id = $Matches[1]
            if (-not $s.Items.ContainsKey($id)) { return (& $answer 404 @{ error = @{ code = 'itemNotFound' } } '') }
            $size = $s.Files[$s.Items[$id]].Length; if ($s.WrongSize) { $size++ }
            return (& $answer 200 @{ id = $id; size = $size } '')
        }
        & $answer 404 @{ error = @{ code = 'itemNotFound' } } ''
    }.GetNewClosure()
    ConvertTo-AVDTuneFakeShared ([pscustomobject]$sp)
}

function Add-AVDTuneFakeSpList {
    # A list that exists already (e.g. with fewer columns, or a second one of the same name)
    param([Parameter(Mandatory)]$SharePoint, [Parameter(Mandatory)][string]$Name, [string[]]$Columns = @())
    $id = [guid]::NewGuid().ToString()
    $SharePoint.Store.Lists[$id] = @{ Name = $Name; Columns = (New-Object System.Collections.ArrayList (, [object[]]$Columns)); Items = (New-Object System.Collections.ArrayList) }
    $id
}
