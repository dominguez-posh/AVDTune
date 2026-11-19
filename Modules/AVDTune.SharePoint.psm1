<#
    AVDTune SharePoint (docs\plans\avdtune.md, sections 7, 8 and phase 3/4; issue #89): the environment's own SharePoint site gets
      * the list "AVDTune Change Log": the entries of the local change log (changelog.json stays the source), created with fixed columns when it is missing,
        idempotent through the column EntryId (the id of the local entry): only entries the list does not have yet are sent;
      * the list "AVDTune Software": the recorded custom software (#87, <state>\software\custom) and the installed programs of the image version, plus the
        documentation and the record of every recording as files in the default document library (folder AVDTune\<version>\software); after the upload is
        confirmed (size read back) the local records may be removed before the finish (an option with its own confirmation);
      * the environment document: a summary (identity model, storage, FSLogix, App Masking, printers, customizations, benchmark comparison, versions) as HTML,
        every value HTML-encoded, a policy that loads nothing; saved locally (<state>\documents) and uploaded into the same library.

    Microsoft Graph only: https://graph.microsoft.com, fixed host, no redirect followed (an upload or a list call is never redirected), the token only in memory
    and only to Graph, the site id validated against the site's host, list, drive and item ids validated before they go into a path, paging through
    @odata.nextLink (checked like every address, at most a fixed number of pages), throttling (429/503/504) waited out with Retry-After (bounded), answers at most
    4 MB, uploads at most 4 MB (simple upload). Every text that goes into a list passes Protect-AVDTuneSpText (tokens, passwords, keys out); a file that holds
    something that looks like a secret is not uploaded at all (Test-AVDTuneSpSecretFree). The token is the Sites token of the sign-in (Sites.Selected with write
    on the environment's site, granted once like for the package store).

    A request is $Context.Transport (default Invoke-AVDTuneSpHttp, NOT exercised by the checks, to be tried against a real test site): the checks give it the
    fake Graph of Tests\Fakes\FakeSharePoint.ps1, so the real rules (paging, throttling, limits, ids) run in the checks.
#>

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'AVDTune.psm1')

$script:GraphV1 = 'https://graph.microsoft.com/v1.0'
$script:SitePattern = '\Ahttps://[A-Za-z0-9-]+\.sharepoint\.com/(sites|teams)/[A-Za-z0-9._-]+/?\z'
$script:GuidPattern = '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}'
$script:DriveIdPattern = '\Ab![A-Za-z0-9_-]{8,200}\z'
$script:ItemIdPattern = '\A[A-Za-z0-9!_-]{1,200}\z'
$script:SegmentPattern = '\A[A-Za-z0-9][A-Za-z0-9._-]{0,79}\z'
$script:MaxAnswer = 4MB
$script:MaxUpload = 4MB
$script:ChangeLogList = 'AVDTune Change Log'
$script:SoftwareList = 'AVDTune Software'
$script:DocFolder = 'AVDTune'
$script:RegexTimeout = [TimeSpan]::FromMilliseconds(500)
$script:SpToolVersion = ''
try { $vf = Join-Path (Split-Path $PSScriptRoot -Parent) 'VERSION'; if (Test-Path -LiteralPath $vf) { $script:SpToolVersion = ([IO.File]::ReadAllText($vf)).Trim() } } catch { }

# The fixed columns of the two lists (internal name, shown name, kind). SharePoint has its own fields Version, Date and Author: the internal names avoid them.
$script:ChangeLogColumns = @(
    @{ name = 'EntryId'; displayName = 'Entry ID'; text = @{}; indexed = $true }
    @{ name = 'ImageVersion'; displayName = 'Version'; text = @{} }
    @{ name = 'EntryDate'; displayName = 'Date'; dateTime = @{ format = 'dateTime' } }
    @{ name = 'Category'; displayName = 'Category'; text = @{} }
    @{ name = 'Component'; displayName = 'Component'; text = @{} }
    @{ name = 'ChangeType'; displayName = 'Change type'; text = @{} }
    @{ name = 'Details'; displayName = 'Text'; text = @{ allowMultipleLines = $true } }
    @{ name = 'ChangedBy'; displayName = 'User'; text = @{} }
    @{ name = 'SnapshotId'; displayName = 'Snapshot ID'; text = @{} }
    @{ name = 'RunId'; displayName = 'Run ID'; text = @{} }
    @{ name = 'Computer'; displayName = 'Computer'; text = @{} }
    @{ name = 'ToolVersion'; displayName = 'AVDTune version'; text = @{} }
)
$script:SoftwareColumns = @(
    @{ name = 'ItemKey'; displayName = 'Item key'; text = @{}; indexed = $true }
    @{ name = 'ImageVersion'; displayName = 'Image version'; text = @{} }
    @{ name = 'Source'; displayName = 'Source'; text = @{} }
    @{ name = 'PackageId'; displayName = 'Package ID'; text = @{} }
    @{ name = 'PackageVersion'; displayName = 'Package version'; text = @{} }
    @{ name = 'Vendor'; displayName = 'Vendor'; text = @{} }
    @{ name = 'Detection'; displayName = 'Detection'; text = @{ allowMultipleLines = $true } }
    @{ name = 'SilentCommand'; displayName = 'Silent install'; text = @{ allowMultipleLines = $true } }
    @{ name = 'UninstallCommand'; displayName = 'Uninstall'; text = @{ allowMultipleLines = $true } }
    @{ name = 'RecordedBy'; displayName = 'Recorded by'; text = @{} }
    @{ name = 'RecordedAt'; displayName = 'Recorded'; text = @{} }
    @{ name = 'Computer'; displayName = 'Computer'; text = @{} }
    @{ name = 'Document'; displayName = 'Document'; text = @{} }
)

#region settings and local state

function Get-AVDTuneSpSettings {
    # config\sharepoint.json: the site of the environment (empty: everything stays local) and whether the finish uploads the change log first
    param([string]$Root = (Get-AVDTuneRoot))
    $s = $null; try { $s = Read-AVDTuneJson (Join-Path $Root 'config\sharepoint.json') } catch { }
    $site = ''; $v = Get-AVDTuneProp $s 'SiteUrl'; if ($v -is [string] -and (Test-AVDTuneSpSiteUrl $v)) { $site = $v.TrimEnd('/') }
    $fin = Get-AVDTuneProp $s 'UploadAtFinish'
    [pscustomobject]@{ SiteUrl = $site; UploadAtFinish = [bool]($fin -is [bool] -and $fin) }
}

function Set-AVDTuneSpSettings {
    param([string]$Root = (Get-AVDTuneRoot), [AllowEmptyString()][string]$SiteUrl = '', [bool]$UploadAtFinish = $false)
    $site = ([string]$SiteUrl).Trim()
    if ($site -and -not (Test-AVDTuneSpSiteUrl $site)) { throw 'The address of the SharePoint site must look like https://<tenant>.sharepoint.com/sites/<name>.' }
    Write-AVDTuneFile (Join-Path $Root 'config\sharepoint.json') ([ordered]@{ SiteUrl = $site.TrimEnd('/'); UploadAtFinish = $UploadAtFinish } | ConvertTo-Json)
    Get-AVDTuneSpSettings -Root $Root
}

function Test-AVDTuneSpSiteUrl([string]$Url) { [bool]($Url -and $Url.Length -le 300 -and [regex]::IsMatch($Url, $script:SitePattern, 'None', $script:RegexTimeout)) }

function Get-AVDTuneSpSent {
    # config\sharepoint-sent.json: what this master has sent (ids of change log entries, keys of software rows, confirmed record uploads with their hashes). Typed reading.
    param([string]$Root = (Get-AVDTuneRoot))
    $j = $null; try { $j = Read-AVDTuneJson (Join-Path $Root 'config\sharepoint-sent.json') } catch { }
    $ids = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($i in @(Get-AVDTuneProp $j 'ChangeLog')) { if ($i -is [string] -and $i -cmatch '\A[0-9a-f]{12}\z') { [void]$ids.Add($i) } }
    $records = @{}
    $r = Get-AVDTuneProp $j 'Records'
    if ($r) {
        foreach ($p in $r.PSObject.Properties) {
            if ($p.Name -cnotmatch '\A[0-9a-f]{12}/[0-9]{3}\z') { continue }
            $rec = Get-AVDTuneProp $p.Value 'Record'; $doc = Get-AVDTuneProp $p.Value 'Document'; $at = Get-AVDTuneProp $p.Value 'At'
            $o = [pscustomobject]@{ Record = $rec; Document = $doc; At = [string]$at }
            foreach ($k in 'Document', 'Record') {
                $item = Get-AVDTuneProp $p.Value "${k}Item"; $size = Get-AVDTuneProp $p.Value "${k}Size"; $hash = Get-AVDTuneProp $p.Value "${k}Hash"
                $o | Add-Member -NotePropertyName "${k}Item" -NotePropertyValue $(if ($item -is [string] -and $item -cmatch $script:ItemIdPattern) { $item } else { '' })
                $o | Add-Member -NotePropertyName "${k}Size" -NotePropertyValue $(if ($size -is [int] -or $size -is [long]) { [int64]$size } else { [int64]-1 })
                $o | Add-Member -NotePropertyName "${k}Hash" -NotePropertyValue $(if ($hash -is [string] -and $hash -cmatch '\A(sha256Hash|quickXorHash):[A-Za-z0-9+/=]{8,100}\z') { $hash } else { '' })
            }
            if ($rec -is [string] -and $rec -cmatch '\A[0-9a-f]{64}\z' -and $doc -is [string] -and $doc -cmatch '\A[0-9a-f]{64}\z') { $records[$p.Name] = $o }
        }
    }
    $docs = @{}
    $d = Get-AVDTuneProp $j 'Documents'
    if ($d) { foreach ($p in $d.PSObject.Properties) { if ($p.Name -cmatch '\A[A-Za-z0-9._-]{1,80}\z' -and $p.Value -is [string]) { $docs[$p.Name] = [string]$p.Value } } }
    [pscustomobject]@{ ChangeLog = $ids; Records = $records; Documents = $docs; Last = [string](Get-AVDTuneProp $j 'Last') }
}

function Save-AVDTuneSpSent {
    param([string]$Root = (Get-AVDTuneRoot), [Parameter(Mandatory)]$Sent)
    $recs = [ordered]@{}; foreach ($k in @($Sent.Records.Keys | Sort-Object)) { $recs[$k] = $Sent.Records[$k] }
    $docs = [ordered]@{}; foreach ($k in @($Sent.Documents.Keys | Sort-Object)) { $docs[$k] = $Sent.Documents[$k] }
    $o = [ordered]@{ Schema = 1; Last = (Get-Date).ToString('o'); ChangeLog = @($Sent.ChangeLog | Sort-Object); Records = $recs; Documents = $docs }
    Write-AVDTuneFile (Join-Path $Root 'config\sharepoint-sent.json') ($o | ConvertTo-Json -Depth 5)
}

function Get-AVDTuneSpPending {
    # Read only, no network: how many change log entries this master has not sent yet (all versions or one)
    param([string]$Root = (Get-AVDTuneRoot), [string]$Version)
    $sent = Get-AVDTuneSpSent -Root $Root
    $p = @{ Root = $Root }; if ($Version) { $p.Version = $Version }
    $all = @(Get-AVDTuneChangeLog @p)
    [pscustomobject]@{ Total = $all.Count; Pending = @($all | Where-Object { -not $sent.ChangeLog.Contains([string]$_.Id) }).Count; Last = $sent.Last }
}

#endregion

#region texts: nothing secret leaves the master

# The table of secret patterns lives in Modules\AVDTune.psm1 since #107 (Invoke-AVDTuneSecretRules): change log, run records, protocol, task bar, recording and
# SharePoint use the same one. Invoke-AVDTuneSpSecretRules stays as the name the SharePoint code and the export use.
function Invoke-AVDTuneSpSecretRules {
    # Pure. The text with every rule of the shared table applied; $null when a rule ran into its timeout (the caller fails closed)
    param([AllowEmptyString()][string]$Text)
    Invoke-AVDTuneSecretRules $Text
}

function Protect-AVDTuneSpText {
    <# Pure. A text for a list column: everything the secret table finds is replaced, control characters out, length limited. #>
    param([AllowEmptyString()][string]$Text, [int]$MaxLength = 255)
    if (-not $Text) { return '' }
    $t = Invoke-AVDTuneSpSecretRules $Text
    if ($null -eq $t) { return '(removed)' }
    Remove-AVDTuneControlCharacters $t $MaxLength
}

function Test-AVDTuneSpSecretFree {
    <# Pure. A file that is uploaded as it is: $true only when the secret table finds nothing in it (the same table as Protect-AVDTuneSpText; a timeout is $false). #>
    param([AllowEmptyString()][string]$Text)
    if (-not $Text) { return $true }
    $t = Invoke-AVDTuneSpSecretRules $Text
    ($null -ne $t -and $t -ceq $Text)
}

#endregion

#region Graph: addresses, the request, paging, throttling

function Test-AVDTuneSpUrl {
    <# Pure. https://graph.microsoft.com only, default port, no credentials, no fragment, at most one "?", path and query of known characters, no climbing. Returns @{ Ok; Reason }. #>
    param([string]$Url)
    $no = { param($t) @{ Ok = $false; Reason = $t } }
    if (-not $Url -or $Url.Length -gt 2000 -or $Url.Contains('#')) { return (& $no 'the address is empty, too long or has a fragment') }
    $u = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$u)) { return (& $no 'the address is not valid') }
    if ($u.Scheme -ne 'https' -or -not $u.IsDefaultPort -or $u.UserInfo) { return (& $no 'only https on the default port, without credentials') }
    if ($u.Host -ne 'graph.microsoft.com') { return (& $no "the host $($u.Host) is not allowed") }
    if (([regex]::Matches($Url, '\?')).Count -gt 1) { return (& $no 'more than one question mark') }
    $m = $null
    try { $m = [regex]::Match($Url, "\Ahttps://graph\.microsoft\.com(/v1\.0/[A-Za-z0-9._:/%,()'!-]+)(\?[A-Za-z0-9`$=,&._%()+/'!~-]*)?\z", 'None', $script:RegexTimeout) } catch { return (& $no 'the address could not be checked') }
    if (-not $m.Success) { return (& $no 'the path or query has characters that are not allowed') }
    if ($m.Groups[1].Value -match '(^|/)\.\.?(/|$)' -or $Url -match '(?i)%2e|%2f|%5c|%00') { return (& $no 'the path climbs or hides a separator') }
    @{ Ok = $true; Reason = '' }
}

function Get-AVDTuneSpErrorResponse {
    # The answer behind a failed GetResponse(): PowerShell wraps the WebException into a MethodInvocationException, so the inner exception is read first (like
    # Session.psm1), then the exception itself. Without it 429/503/504 and 401/403 would never be seen as such (review B1).
    param($Exception)
    if ($null -eq $Exception) { return $null }
    $r = Get-AVDTuneProp (Get-AVDTuneProp $Exception 'InnerException') 'Response'
    if (-not $r) { $r = Get-AVDTuneProp $Exception 'Response' }
    $r
}

function Invoke-AVDTuneSpHttp {
    <#
        The real transport: ONE request with method, headers and body bytes, no automatic redirect, TLS 1.2 added (never overwritten). Returns Status, Headers (RetryAfter),
        Stream and Close. Not sent by the checks (they use the fake transport); -GetResponse replaces only the call $req.GetResponse() so the checks can make it throw
        like .NET does (review B1). To be tried against a real test site.
    #>
    param([Parameter(Mandatory)][string]$Method, [Parameter(Mandatory)][string]$Url, [hashtable]$Headers = @{}, [byte[]]$Body, [string]$ContentType, [scriptblock]$GetResponse)
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.Method = $Method; $req.AllowAutoRedirect = $false; $req.Timeout = 60000; $req.ReadWriteTimeout = 120000
    foreach ($k in $Headers.Keys) { $req.Headers.Add([string]$k, [string]$Headers[$k]) }
    if ($null -ne $Body) {
        $req.ContentType = $(if ($ContentType) { $ContentType } else { 'application/octet-stream' }); $req.ContentLength = $Body.Length
        $s = $req.GetRequestStream(); try { $s.Write($Body, 0, $Body.Length) } finally { $s.Dispose() }
    }
    elseif ($Method -ne 'GET') { $req.ContentLength = 0 }
    try { $resp = if ($GetResponse) { & $GetResponse $req } else { $req.GetResponse() } }
    catch {
        $resp = Get-AVDTuneSpErrorResponse $_.Exception
        if (-not $resp) { throw "Microsoft Graph cannot be reached: $($_.Exception.Message)" }
    }
    $r = $resp
    @{ Status = [int]$r.StatusCode; Headers = @{ RetryAfter = [string]$r.Headers['Retry-After'] }; Stream = $r.GetResponseStream(); Close = { $r.Close() }.GetNewClosure() }
}

function Read-AVDTuneSpLimited {
    # Reads a stream in blocks and counts the real bytes: more than MaxBytes is an error (a declared length is not trusted). Returns the text (UTF-8).
    param($Stream, [Parameter(Mandatory)][int64]$MaxBytes)
    if ($null -eq $Stream) { return '' }
    $buf = New-Object byte[] 65536; $total = [int64]0; $mem = New-Object IO.MemoryStream
    while (($n = $Stream.Read($buf, 0, $buf.Length)) -gt 0) {
        $total += $n
        if ($total -gt $MaxBytes) { throw "The answer of Graph is larger than the allowed $MaxBytes bytes: stopped." }
        $mem.Write($buf, 0, $n)
    }
    [Text.Encoding]::UTF8.GetString($mem.ToArray())
}

function Get-AVDTuneSpRetryWait {
    <# Pure. Seconds to wait before the next try: Retry-After (seconds or an HTTP date), otherwise 2, 4, 8 ... ; always between 1 and $Max. #>
    param([string]$RetryAfter, [int]$Attempt, [int]$Max = 120)
    $s = -1
    $v = ([string]$RetryAfter).Trim()
    if ($v -match '\A\d{1,6}\z') { $s = [int]$v }
    elseif ($v) { $d = [datetime]::MinValue; if ([datetime]::TryParse($v, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$d)) { $s = [int][Math]::Ceiling(($d - [datetime]::UtcNow).TotalSeconds) } }
    if ($s -lt 0) { $s = [int][Math]::Pow(2, [Math]::Min($Attempt + 1, 6)) }
    [Math]::Max(1, [Math]::Min($s, $Max))
}

function New-AVDTuneSpContext {
    <# The token (a string, in memory only) and the site of one upload session. -Transport and -Sleep replace the request and the wait (the checks). Close it with Close-AVDTuneSpContext. #>
    param([string]$Token, [Parameter(Mandatory)][string]$SiteUrl, [scriptblock]$Transport, [scriptblock]$Sleep, [int]$MaxRetries = 5, [int]$MaxWaitSeconds = 120)
    if (-not (Test-AVDTuneSpSiteUrl $SiteUrl)) { throw 'The address of the SharePoint site is not valid (https://<tenant>.sharepoint.com/sites/<name>).' }
    [pscustomobject]@{ Token = $Token; SiteUrl = $SiteUrl.TrimEnd('/'); Transport = $Transport; Sleep = $Sleep; MaxRetries = $MaxRetries; MaxWaitSeconds = $MaxWaitSeconds
        SiteId = ''; DriveId = ''; Waits = (New-Object System.Collections.ArrayList); Requests = 0 }
}

function Close-AVDTuneSpContext($Context) { if ($Context) { $Context.Token = $null } }

function Invoke-AVDTuneSpRequest {
    <#
        One call to Microsoft Graph with the token. The address is checked (Test-AVDTuneSpUrl) before the token goes anywhere; a redirect is an error (never followed);
        429, 503 and 504 are tried again after Retry-After (at most MaxRetries times, each wait at most MaxWaitSeconds); the answer is JSON of at most 4 MB.
        -Body is sent as JSON, -Bytes as they are (at most 4 MB). Error texts carry the status and Graph's error code, never the token or the body.
    #>
    param([Parameter(Mandatory)]$Context, [ValidateSet('GET', 'POST', 'PATCH', 'PUT')][string]$Method = 'GET', [Parameter(Mandatory)][string]$Url, $Body, [byte[]]$Bytes, [string]$ContentType)
    $check = Test-AVDTuneSpUrl $Url
    if (-not $check.Ok) { throw "Refused request to Microsoft Graph: $($check.Reason)." }
    if (-not $Context.Token) { throw 'Not signed in for SharePoint (no token). Sign in on the Overview first.' }
    $payload = $null; $type = ''
    if ($null -ne $Body) { $payload = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 8 -Compress)); $type = 'application/json' }
    elseif ($null -ne $Bytes) { $payload = $Bytes; $type = $(if ($ContentType) { $ContentType } else { 'application/octet-stream' }) }
    if ($null -ne $payload -and $payload.Length -gt $script:MaxUpload) { throw "The upload is larger than $($script:MaxUpload) bytes: not sent." }
    $transport = if ($Context.Transport) { $Context.Transport } else { ${function:Invoke-AVDTuneSpHttp} }
    $sleep = if ($Context.Sleep) { $Context.Sleep } else { { param($s) Start-Sleep -Seconds $s } }
    for ($attempt = 0; ; $attempt++) {
        $Context.Requests++
        $resp = & $transport $Method $Url @{ Authorization = "Bearer $($Context.Token)" } $payload $type
        $retry = $false
        try {
            $code = [int]$resp.Status
            if ($code -in 429, 503, 504) {
                if ($attempt -ge $Context.MaxRetries) { throw "Microsoft Graph answered $code (busy or throttled) $($attempt + 1) times: stopped, try again later." }
                $wait = Get-AVDTuneSpRetryWait -RetryAfter ([string]$resp.Headers.RetryAfter) -Attempt $attempt -Max $Context.MaxWaitSeconds
                [void]$Context.Waits.Add($wait)
                $retry = $true
            }
            elseif ($code -ge 300 -and $code -le 399) { throw "Microsoft Graph answered $code (a redirect): not followed." }
            elseif ($code -lt 200 -or $code -gt 299) {
                $err = ''; try { $j = (Read-AVDTuneSpLimited -Stream $resp.Stream -MaxBytes 65536) | ConvertFrom-Json; $err = [string](Get-AVDTuneProp (Get-AVDTuneProp $j 'error') 'code') } catch { }
                $err = Remove-AVDTuneControlCharacters (Protect-AVDTuneSpText $err 80) 80
                throw "Microsoft Graph answered $code$(if ($err) { " ($err)" })$(if ($code -in 401, 403) { ': the sign-in has no write access to this site (Sites.Selected with write on the site is needed)' })."
            }
            else {
                $text = Read-AVDTuneSpLimited -Stream $resp.Stream -MaxBytes $script:MaxAnswer
                if (-not $text.Trim()) { return $null }
                return ($text | ConvertFrom-Json)
            }
        }
        finally { if ($resp -and $resp.Close) { & $resp.Close } }
        if ($retry) { & $sleep $wait }
    }
}

function Get-AVDTuneSpAll {
    # Every row of a collection: follows @odata.nextLink (each checked by Invoke-AVDTuneSpRequest), at most -MaxPages pages (more is an error, not a silent cut)
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Url, [int]$MaxPages = 100)
    $rows = New-Object System.Collections.ArrayList
    # a nextLink must stay on the same collection (review B4): the same path (decoded, Graph may encode the commas of a site id), only another query
    $norm = { param($u) [uri]::UnescapeDataString(($u -split '\?', 2)[0]).ToLowerInvariant() }
    $base = & $norm $Url
    $next = $Url
    for ($page = 0; $next; $page++) {
        if ($page -ge $MaxPages) { throw "The collection has more than $MaxPages pages: stopped." }
        if ($page -gt 0 -and -not (Test-AVDTuneSpUrl $next).Ok) { throw "Refused request to Microsoft Graph: $((Test-AVDTuneSpUrl $next).Reason)." }
        if ($page -gt 0 -and (& $norm $next) -cne $base) { throw 'Graph returned a nextLink to another collection: refused.' }
        $a = Invoke-AVDTuneSpRequest -Context $Context -Url $next
        foreach ($v in @(Get-AVDTuneProp $a 'value')) { if ($null -ne $v) { [void]$rows.Add($v) } }
        $next = [string](Get-AVDTuneProp $a '@odata.nextLink')
    }
    $rows.ToArray()
}

function Test-AVDTuneSpSiteId {
    # Pure. A Graph site id: <host>,<site collection guid>,<web guid>; the host must be the host of the configured site
    param([string]$Id, [Parameter(Mandatory)][string]$SiteHost)
    if (-not $Id -or $Id.Length -gt 400) { return $false }
    $m = [regex]::Match($Id, "\A([A-Za-z0-9.-]{1,253}),$($script:GuidPattern),$($script:GuidPattern)\z", 'None', $script:RegexTimeout)
    $m.Success -and $m.Groups[1].Value -eq $SiteHost.ToLowerInvariant()
}

function Resolve-AVDTuneSpSite {
    # The id of the configured site (once per context), validated before it goes into any path
    param([Parameter(Mandatory)]$Context)
    if ($Context.SiteId) { return $Context.SiteId }
    $u = [Uri]$Context.SiteUrl
    $seg = @($u.AbsolutePath.Trim('/') -split '/')
    $a = Invoke-AVDTuneSpRequest -Context $Context -Url "$($script:GraphV1)/sites/$($u.Host):/$($seg[0])/$($seg[1])?`$select=id"
    $id = [string](Get-AVDTuneProp $a 'id')
    if (-not (Test-AVDTuneSpSiteId -Id $id -SiteHost $u.Host)) { throw 'Microsoft Graph returned a site id that is not valid for this site: refused.' }
    $Context.SiteId = $id
    $id
}

function Resolve-AVDTuneSpDrive {
    # The default document library of the site (validated id)
    param([Parameter(Mandatory)]$Context)
    if ($Context.DriveId) { return $Context.DriveId }
    $site = Resolve-AVDTuneSpSite $Context
    $a = Invoke-AVDTuneSpRequest -Context $Context -Url "$($script:GraphV1)/sites/$site/drive?`$select=id"
    $id = [string](Get-AVDTuneProp $a 'id')
    if ($id -cnotmatch $script:DriveIdPattern) { throw 'Microsoft Graph returned a library id that is not valid: refused.' }
    $Context.DriveId = $id
    $id
}

#endregion

#region lists

function Initialize-AVDTuneSpList {
    <# The list -Name on the site: created with -Columns when it is missing; an existing one gets the columns it lacks. Two lists of the name: refused. Returns Id, Created, ColumnsAdded. #>
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][object[]]$Columns)
    $site = Resolve-AVDTuneSpSite $Context
    $lists = @(Get-AVDTuneSpAll -Context $Context -Url "$($script:GraphV1)/sites/$site/lists?`$select=id,displayName&`$top=100")
    $hit = @($lists | Where-Object { [string](Get-AVDTuneProp $_ 'displayName') -ceq $Name })
    if ($hit.Count -gt 1) { throw "The site has $($hit.Count) lists named '$Name': not clear which one, nothing sent." }
    if ($hit.Count -eq 1) {
        $id = [string](Get-AVDTuneProp $hit[0] 'id')
        if ($id -notmatch "\A$($script:GuidPattern)\z") { throw "Microsoft Graph returned a list id that is not valid: refused." }
        $have = @(Get-AVDTuneSpAll -Context $Context -Url "$($script:GraphV1)/sites/$site/lists/$id/columns?`$select=name&`$top=200" | ForEach-Object { [string](Get-AVDTuneProp $_ 'name') })
        $added = 0
        foreach ($c in $Columns) { if ($c.name -cnotin $have) { [void](Invoke-AVDTuneSpRequest -Context $Context -Method POST -Url "$($script:GraphV1)/sites/$site/lists/$id/columns" -Body $c); $added++ } }
        return [pscustomobject]@{ Id = $id; Created = $false; ColumnsAdded = $added }
    }
    $a = Invoke-AVDTuneSpRequest -Context $Context -Method POST -Url "$($script:GraphV1)/sites/$site/lists" -Body @{ displayName = $Name; columns = @($Columns); list = @{ template = 'genericList' } }
    $id = [string](Get-AVDTuneProp $a 'id')
    if ($id -notmatch "\A$($script:GuidPattern)\z") { throw 'Microsoft Graph returned a list id that is not valid: refused.' }
    [pscustomobject]@{ Id = $id; Created = $true; ColumnsAdded = @($Columns).Count }
}

function Get-AVDTuneSpListKeys {
    # The values of the key column of every item of the list (paged); the list is the truth, so a lost local record never sends an entry twice
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$ListId, [Parameter(Mandatory)][ValidatePattern('\A[A-Za-z]{1,40}\z')][string]$KeyColumn)
    $site = Resolve-AVDTuneSpSite $Context
    $keys = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($i in @(Get-AVDTuneSpAll -Context $Context -Url "$($script:GraphV1)/sites/$site/lists/$ListId/items?`$expand=fields(`$select=$KeyColumn)&`$top=200" -MaxPages 250)) {
        $k = [string](Get-AVDTuneProp (Get-AVDTuneProp $i 'fields') $KeyColumn)
        if ($k) { [void]$keys.Add($k) }
    }
    , $keys
}

function Add-AVDTuneSpListItem {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$ListId, [Parameter(Mandatory)][hashtable]$Fields)
    $site = Resolve-AVDTuneSpSite $Context
    $a = Invoke-AVDTuneSpRequest -Context $Context -Method POST -Url "$($script:GraphV1)/sites/$site/lists/$ListId/items" -Body @{ fields = $Fields }
    [string](Get-AVDTuneProp $a 'id')
}

function ConvertTo-AVDTuneSpChangeLogFields {
    <# Pure. One change log entry as the fields of a list item; every text through Protect-AVDTuneSpText. $null for an entry without a valid id or date. #>
    param([Parameter(Mandatory)]$Entry, [string]$Computer)
    $id = [string](Get-AVDTuneProp $Entry 'Id')
    if ($id -cnotmatch '\A[0-9a-f]{12}\z') { return $null }
    $at = [datetime]::MinValue
    if (-not [datetime]::TryParse([string](Get-AVDTuneProp $Entry 'At'), [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$at)) { return $null }
    $p = { param($n, $max) Protect-AVDTuneSpText ([string](Get-AVDTuneProp $Entry $n)) $max }
    $category = & $p 'Category' 80; $text = & $p 'Text' 2000
    @{
        Title = (Protect-AVDTuneSpText "$category`: $text" 255); EntryId = $id; ImageVersion = (& $p 'Version' 40); EntryDate = $at.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
        Category = $category; Component = (& $p 'Component' 120); ChangeType = (& $p 'ChangeType' 40); Details = $text; ChangedBy = (& $p 'User' 120)
        SnapshotId = (& $p 'SnapshotId' 255); RunId = (& $p 'RunId' 80); Computer = (Protect-AVDTuneSpText $Computer 80); ToolVersion = (& $p 'ToolVersion' 40)
    }
}

function Send-AVDTuneSpChangeLog {
    <#
        Sends the change log entries (all versions or -Version) that the list "AVDTune Change Log" does not have yet. The list is created when it is missing.
        Idempotent: the EntryId column of the list decides (read first, paged), the local record (config\sharepoint-sent.json) is only the view of the page.
        Returns List, Created, Sent, Skipped (already there), Invalid (no valid id or date), Total.
    #>
    param([Parameter(Mandatory)]$Context, [string]$Root = (Get-AVDTuneRoot), [string]$Version, [string]$Computer, [hashtable]$Progress)
    $p = @{ Root = $Root }; if ($Version) { $p.Version = $Version }
    $entries = @(Get-AVDTuneChangeLog @p)
    if ($Progress) { $Progress.Text = 'list' }
    $list = Initialize-AVDTuneSpList -Context $Context -Name $script:ChangeLogList -Columns $script:ChangeLogColumns
    $keys = Get-AVDTuneSpListKeys -Context $Context -ListId $list.Id -KeyColumn 'EntryId'
    $sent = Get-AVDTuneSpSent -Root $Root
    $n = 0; $skipped = 0; $invalid = 0
    try {
        foreach ($e in $entries) {
            $f = ConvertTo-AVDTuneSpChangeLogFields -Entry $e -Computer $Computer
            if (-not $f) { $invalid++; continue }
            if ($keys.Contains($f.EntryId)) { $skipped++; [void]$sent.ChangeLog.Add($f.EntryId); continue }
            if ($Progress) { $Progress.Text = 'entries'; $Progress.Done = $n + 1; $Progress.Total = $entries.Count }
            [void](Add-AVDTuneSpListItem -Context $Context -ListId $list.Id -Fields $f)
            [void]$keys.Add($f.EntryId); [void]$sent.ChangeLog.Add($f.EntryId); $n++
        }
    }
    finally { Save-AVDTuneSpSent -Root $Root -Sent $sent }   # what went up is recorded also when a later entry fails
    [pscustomobject]@{ List = $script:ChangeLogList; Created = $list.Created; Sent = $n; Skipped = $skipped; Invalid = $invalid; Total = $entries.Count }
}

#endregion

#region files in the library

function Send-AVDTuneSpFile {
    <#
        Uploads bytes (at most 4 MB) into the default library of the site under AVDTune\<segments> (replaces a file of the same name) and confirms it: the item is read
        back and its size must match. Every segment is checked (letters, digits . _ -, no ..). Returns Id, Path, Size, Confirmed.
    #>
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string[]]$Segments, [Parameter(Mandatory)][byte[]]$Bytes, [string]$ContentType = 'application/octet-stream')
    foreach ($s in $Segments) { if (-not $s -or $s -cnotmatch $script:SegmentPattern -or $s -match '\.\.' -or $s -match '[. ]\z') { throw "'$s' is not a valid name in the library." } }
    if ($Bytes.Length -gt $script:MaxUpload) { throw "$($Segments[-1]) is larger than $($script:MaxUpload) bytes: not uploaded." }
    $drive = Resolve-AVDTuneSpDrive $Context
    $path = (@($script:DocFolder) + $Segments | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
    $a = Invoke-AVDTuneSpRequest -Context $Context -Method PUT -Url "$($script:GraphV1)/drives/$drive/root:/${path}:/content" -Bytes $Bytes -ContentType $ContentType
    $id = [string](Get-AVDTuneProp $a 'id')
    if ($id -cnotmatch $script:ItemIdPattern) { throw 'Microsoft Graph returned an item id that is not valid: refused.' }
    $b = Get-AVDTuneSpItemState -Context $Context -ItemId $id
    [pscustomobject]@{ Id = $id; Path = ($path -replace '/', '\'); Size = $b.Size; Hash = $b.Hash; Confirmed = [bool]($b.Id -ceq $id -and $b.Size -eq $Bytes.Length) }
}

function Get-AVDTuneSpItemState {
    <# The item of the library as Graph has it now: Id, Size (-1 when missing) and Hash (quickXorHash, or sha256Hash where Graph gives it; '' when none). #>
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$ItemId)
    if ($ItemId -cnotmatch $script:ItemIdPattern) { throw 'The item id is not valid: refused.' }
    $drive = Resolve-AVDTuneSpDrive $Context
    $b = Invoke-AVDTuneSpRequest -Context $Context -Url "$($script:GraphV1)/drives/$drive/items/${ItemId}?`$select=id,size,file"
    $size = Get-AVDTuneProp $b 'size'
    $hashes = Get-AVDTuneProp (Get-AVDTuneProp $b 'file') 'hashes'
    $h = ''; foreach ($n in 'sha256Hash', 'quickXorHash') { $v = Get-AVDTuneProp $hashes $n; if ($v -is [string] -and $v -match '\A[A-Za-z0-9+/=]{8,100}\z') { $h = "${n}:$v"; break } }
    [pscustomobject]@{ Id = [string](Get-AVDTuneProp $b 'id'); Size = $(if ($size -is [int] -or $size -is [long]) { [int64]$size } else { [int64]-1 }); Hash = $h }
}

function Get-AVDTuneSpFileHash([string]$Path) {
    $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try { $sha = [Security.Cryptography.SHA256]::Create(); try { ([BitConverter]::ToString($sha.ComputeHash($fs)) -replace '-', '').ToLowerInvariant() } finally { $sha.Dispose() } } finally { $fs.Dispose() }
}

function Read-AVDTuneSpLocalFile {
    # A file of AVDTune's own state for an upload: no link, at most 4 MB, read through one handle (bytes and hash of the same content)
    param([Parameter(Mandatory)][string]$Path)
    $f = New-Object IO.FileInfo $Path
    if (-not $f.Exists) { throw "$($f.Name) is missing." }
    if (($f.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "$($f.Name) is a link: not uploaded." }
    if ($f.Length -gt $script:MaxUpload) { throw "$($f.Name) is larger than $($script:MaxUpload) bytes: not uploaded." }
    $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try { $mem = New-Object IO.MemoryStream; $fs.CopyTo($mem); $bytes = $mem.ToArray() } finally { $fs.Dispose() }
    $sha = [Security.Cryptography.SHA256]::Create(); try { $hash = ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').ToLowerInvariant() } finally { $sha.Dispose() }
    [pscustomobject]@{ Bytes = $bytes; Sha256 = $hash; Text = [Text.Encoding]::UTF8.GetString($bytes) }
}

#endregion

#region software list and records

function Get-AVDTuneSpItemKey([string]$Text) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))) -replace '-', '').Substring(0, 32).ToLowerInvariant() } finally { $sha.Dispose() }
}

function Get-AVDTuneSpSoftwareRows {
    <#
        Pure. The rows of the list "AVDTune Software" for one image version: every recording of the custom software (-Recorded: Apps of Get-AVDTuneRecordedApps) and the
        installed programs (-Installed: rows of Get-AVDTuneInstalledSoftware). ItemKey = hash of version, source, id, package version and recording number.
    #>
    param([Parameter(Mandatory)][string]$ImageVersion, $Recorded, $Installed, [string]$Computer)
    $rows = New-Object System.Collections.ArrayList
    $p = { param($v, $max) Protect-AVDTuneSpText ([string]$v) $max }
    foreach ($app in @($Recorded)) {
        if (-not $app) { continue }
        foreach ($r in @($app.Versions)) {
            $num = ([int]$r.Number).ToString('000')
            $det = if ($r.Detection) { "$($r.Detection.Kind): $($r.Detection.Key) $(Get-AVDTuneProp $r.Detection 'Version')".Trim() } else { '' }
            [void]$rows.Add(@{
                    Title = (& $p $r.App.Name 255); ItemKey = (Get-AVDTuneSpItemKey "$ImageVersion|Custom|$($app.Id)|$($r.App.Version)|$num"); ImageVersion = $ImageVersion; Source = "Custom ($($r.Kind), $($r.Result))"
                    PackageId = "$($app.Id)/$num"; PackageVersion = (& $p $r.App.Version 80); Vendor = (& $p $r.App.Vendor 120); Detection = (& $p $det 1000); SilentCommand = (& $p $r.Silent 1000)
                    UninstallCommand = (& $p $r.Uninstall 1000); RecordedBy = (& $p $r.User 120); RecordedAt = (& $p $r.Started 40); Computer = (& $p $Computer 80)
                    Document = "$($script:DocFolder)\$ImageVersion\software\$($app.Id)-$num.html"
                })
        }
    }
    foreach ($i in @($Installed)) {
        if (-not $i -or -not $i.Name) { continue }
        [void]$rows.Add(@{
                Title = (& $p $i.Name 255); ItemKey = (Get-AVDTuneSpItemKey "$ImageVersion|Installed|$($i.Key)|$($i.Version)"); ImageVersion = $ImageVersion; Source = "Installed ($($i.Arch))"
                PackageId = (& $p $i.Key 255); PackageVersion = (& $p $i.Version 80); Vendor = (& $p $i.Publisher 120); Detection = (& $p "Uninstall: $($i.Key)" 1000); SilentCommand = ''; UninstallCommand = ''
                RecordedBy = ''; RecordedAt = ''; Computer = (& $p $Computer 80); Document = ''
            })
    }
    $rows.ToArray()
}

function Send-AVDTuneSpSoftware {
    <#
        The list "AVDTune Software" (created when missing, only new ItemKeys sent) and, per recording of the custom software, documentation.html and record.json in the library
        (AVDTune\<version>\software\<app>-<nnn>.html/.json). A record whose files look like they hold a secret, are links or larger than 4 MB is not uploaded (Problems).
        A confirmed upload (both files read back with the right size) is recorded with the SHA256 of both files: only such records may be removed later.
        Returns Sent, Skipped, Files, Confirmed, Problems.
    #>
    param([Parameter(Mandatory)]$Context, [string]$Root = (Get-AVDTuneRoot), [Parameter(Mandatory)][string]$ImageVersion, $Recorded, $Installed, [string]$Computer, [hashtable]$Progress)
    if (-not (Test-AVDTuneImageVersion $ImageVersion)) { throw "Invalid image version '$ImageVersion'." }
    $rows = @(Get-AVDTuneSpSoftwareRows -ImageVersion $ImageVersion -Recorded $Recorded -Installed $Installed -Computer $Computer)
    if ($Progress) { $Progress.Text = 'list' }
    $list = Initialize-AVDTuneSpList -Context $Context -Name $script:SoftwareList -Columns $script:SoftwareColumns
    $keys = Get-AVDTuneSpListKeys -Context $Context -ListId $list.Id -KeyColumn 'ItemKey'
    $n = 0; $skipped = 0
    foreach ($r in $rows) {
        if ($keys.Contains($r.ItemKey)) { $skipped++; continue }
        if ($Progress) { $Progress.Text = 'rows'; $Progress.Done = $n + 1; $Progress.Total = $rows.Count }
        [void](Add-AVDTuneSpListItem -Context $Context -ListId $list.Id -Fields $r); [void]$keys.Add($r.ItemKey); $n++
    }
    $sent = Get-AVDTuneSpSent -Root $Root
    $problems = New-Object System.Collections.ArrayList; $files = 0; $confirmed = 0
    $base = [IO.Path]::GetFullPath((Join-Path $Root 'software\custom')).TrimEnd('\') + '\'
    try {
        foreach ($app in @($Recorded)) {
            if (-not $app) { continue }
            foreach ($r in @($app.Versions)) {
                $num = ([int]$r.Number).ToString('000'); $key = "$($app.Id)/$num"
                try {
                    $folder = [IO.Path]::GetFullPath([string]$r.Folder)
                    if (-not $folder.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) { throw 'the folder is not below the state folder' }
                    $doc = Read-AVDTuneSpLocalFile (Join-Path $folder 'documentation.html')
                    $rec = Read-AVDTuneSpLocalFile (Join-Path $folder 'record.json')
                    if (-not (Test-AVDTuneSpSecretFree $doc.Text) -or -not (Test-AVDTuneSpSecretFree $rec.Text)) { throw 'it holds something that looks like a password, key or token' }
                    if ($Progress) { $Progress.Text = 'files'; $Progress.Done = $files + 1 }
                    $u1 = Send-AVDTuneSpFile -Context $Context -Segments @($ImageVersion, 'software', "$($app.Id)-$num.html") -Bytes $doc.Bytes -ContentType 'text/html'
                    $u2 = Send-AVDTuneSpFile -Context $Context -Segments @($ImageVersion, 'software', "$($app.Id)-$num.json") -Bytes $rec.Bytes -ContentType 'application/json'
                    $files += 2
                    if ($u1.Confirmed -and $u2.Confirmed -and $u1.Hash -and $u2.Hash) { $sent.Records[$key] = [pscustomobject]@{ Record = $rec.Sha256; Document = $doc.Sha256; At = (Get-Date).ToString('o'); DocumentItem = $u1.Id; DocumentSize = [int64]$u1.Size; DocumentHash = $u1.Hash; RecordItem = $u2.Id; RecordSize = [int64]$u2.Size; RecordHash = $u2.Hash }; $confirmed++ }
                    else { [void]$problems.Add("$key`: the upload could not be confirmed (size read back differs or Graph gave no hash).") }
                }
                catch { [void]$problems.Add("$key`: not uploaded ($(Remove-AVDTuneControlCharacters $_.Exception.Message 200)).") }
            }
        }
    }
    finally { Save-AVDTuneSpSent -Root $Root -Sent $sent }
    [pscustomobject]@{ List = $script:SoftwareList; Created = $list.Created; Sent = $n; Skipped = $skipped; Files = $files; Confirmed = $confirmed; Problems = @($problems) }
}

function Get-AVDTuneSpRemovableRecords {
    <# Read only, local: the recordings whose upload was confirmed and whose files are unchanged since (SHA256 of record.json and documentation.html as uploaded). Remove-AVDTuneSpUploadedRecords asks SharePoint again. #>
    param([string]$Root = (Get-AVDTuneRoot), $Recorded)
    $sent = Get-AVDTuneSpSent -Root $Root
    $out = New-Object System.Collections.ArrayList
    foreach ($app in @($Recorded)) {
        if (-not $app) { continue }
        foreach ($r in @($app.Versions)) {
            $key = "$($app.Id)/$(([int]$r.Number).ToString('000'))"
            if (-not $sent.Records.ContainsKey($key)) { continue }
            try {
                if ((Get-AVDTuneSpFileHash (Join-Path $r.Folder 'record.json')) -cne $sent.Records[$key].Record) { continue }
                if ((Get-AVDTuneSpFileHash (Join-Path $r.Folder 'documentation.html')) -cne $sent.Records[$key].Document) { continue }
            }
            catch { continue }
            [void]$out.Add([pscustomobject]@{ Key = $key; AppId = $app.Id; Name = [string]$r.App.Name; Version = [string]$r.App.Version; Folder = [string]$r.Folder; Sent = $sent.Records[$key] })
        }
    }
    $out.ToArray()
}

function Remove-AVDTuneSpUploadedRecords {
    <#
        Removes the local records whose upload is confirmed and unchanged (Get-AVDTuneSpRemovableRecords), each folder with Remove-AVDTuneTreeSafe (links removed as links,
        never followed), the app folder too when it is empty then. Before each removal both items are read in SharePoint again: size and hash must be what Graph
        gave at the upload (review B5), otherwise the record stays. Not after the version is finished (Sealed). A change log entry names how many. Returns Removed, Failed.
        No LastChange (review B7, decided so): the records are AVDTune's own documentation in the state folder, not a setting of the master; the snapshot gate
        compares changes of the master. The removal still needs the central lock, is refused after the finish and is in the change log.
    #>
    param([Parameter(Mandatory)]$Context, [string]$Root = (Get-AVDTuneRoot), $Recorded, [string]$User)
    if (Test-AVDTuneSealed -Root $Root) { throw 'The image version is finished: start a new version first.' }
    $base = [IO.Path]::GetFullPath((Join-Path $Root 'software\custom')).TrimEnd('\') + '\'
    $removed = New-Object System.Collections.ArrayList; $failed = New-Object System.Collections.ArrayList
    foreach ($r in @(Get-AVDTuneSpRemovableRecords -Root $Root -Recorded $Recorded)) {
        $folder = [IO.Path]::GetFullPath($r.Folder)
        if (-not $folder.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) { [void]$failed.Add("$($r.Key): not below the state folder"); continue }
        try {
            $ok = $true
            foreach ($k in 'Document', 'Record') {
                $item = $r.Sent."${k}Item"
                if (-not $item -or -not $r.Sent."${k}Hash") { $ok = $false; break }
                $now = Get-AVDTuneSpItemState -Context $Context -ItemId $item
                if ($now.Id -cne $item -or $now.Size -ne $r.Sent."${k}Size" -or $now.Hash -cne $r.Sent."${k}Hash") { $ok = $false; break }
            }
            if (-not $ok) { [void]$failed.Add("$($r.Key): the copy in SharePoint is not the one uploaded (missing, other size or hash), kept"); continue }
            $res = Remove-AVDTuneTreeSafe -Path $folder
            if (-not $res.Gone) { [void]$failed.Add("$($r.Key): $($res.Left) entries left"); continue }
            [void]$removed.Add($r.Key)
            $appDir = New-Object IO.DirectoryInfo (Split-Path $folder -Parent)
            if ($appDir.Exists -and ($appDir.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0 -and @($appDir.GetFileSystemInfos()).Count -eq 0) { [void](Remove-AVDTuneTreeSafe -Path $appDir.FullName) }
        }
        catch { [void]$failed.Add("$($r.Key): $(Remove-AVDTuneControlCharacters $_.Exception.Message 200)") }
    }
    $state = Get-AVDTuneState $Root
    if ($removed.Count -gt 0 -and (Get-AVDTuneProp $state 'ImageVersion')) {
        [void](Add-AVDTuneChangeLogEntry -Root $Root -Version ([string](Get-AVDTuneProp $state 'ImageVersion')) -Category 'Software' -Component 'sharepoint.records' -ChangeType 'Removed' -Text "$($removed.Count) local record(s) of custom software removed after the confirmed upload to SharePoint: $(@($removed) -join ', ')" -User $User -Source Step)
    }
    [pscustomobject]@{ Removed = @($removed); Failed = @($failed) }
}

#endregion

#region environment document

function ConvertTo-AVDTuneSpRows {
    <# Pure. The scalar values of an object as rows (name path, value), two levels deep, at most -Max rows; names that sound secret show "(not shown)", every value through Protect-AVDTuneSpText. #>
    param($Object, [string]$Prefix = '', [int]$Depth = 0, [int]$Max = 40)
    $rows = New-Object System.Collections.ArrayList
    if ($null -eq $Object) { return }
    $props = if ($Object -is [System.Collections.IDictionary]) { @($Object.Keys | ForEach-Object { @{ Name = [string]$_; Value = $Object[$_] } }) } else { @($Object.PSObject.Properties | Where-Object { $_.MemberType -eq 'NoteProperty' } | ForEach-Object { @{ Name = $_.Name; Value = $_.Value } }) }
    foreach ($p in $props) {
        if ($rows.Count -ge $Max) { [void]$rows.Add(@('...', '(more not shown)')); break }
        $name = if ($Prefix) { "$Prefix.$($p.Name)" } else { $p.Name }
        $v = $p.Value
        if ($p.Name -match '(?i)key|secret|password|passwort|kennwort|token|sas|credential|refresh|cert') { [void]$rows.Add(@($name, '(not shown)')); continue }
        if ($null -eq $v) { continue }
        if ($v -is [string] -or $v -is [ValueType]) { [void]$rows.Add(@($name, (Protect-AVDTuneSpText ([string]$v) 300))); continue }
        if ($v -is [System.Collections.IEnumerable] -and $v -isnot [System.Collections.IDictionary]) {
            $items = @($v)
            if (@($items | Where-Object { $_ -isnot [string] -and $_ -isnot [ValueType] }).Count -eq 0) { [void]$rows.Add(@($name, (Protect-AVDTuneSpText (($items | ForEach-Object { [string]$_ }) -join ', ') 300))) }
            else { [void]$rows.Add(@($name, "$($items.Count) entries")) }
            continue
        }
        if ($Depth -lt 1) { foreach ($sub in @(ConvertTo-AVDTuneSpRows -Object $v -Prefix $name -Depth ($Depth + 1) -Max ($Max - $rows.Count))) { [void]$rows.Add($sub) } }
        else { [void]$rows.Add(@($name, '(details not shown)')) }
    }
    $rows.ToArray()
}

function Get-AVDTuneEnvironmentDocumentData {
    <#
        Read only: the summary of the environment from AVDTune's own files (state.json, environment.json, config\*.json, change log), the recorded custom software
        (-Recorded), the benchmark comparison (-Benchmark: Rows of Get-AVDTuneBenchmarkVersionComparison) and the Windows version (-Machine). A file that cannot be
        read is named in its section; nothing is asked from the network.
    #>
    param([string]$Root = (Get-AVDTuneRoot), $Machine, $Recorded, $Benchmark, [string]$Computer)
    $state = Get-AVDTuneState $Root
    $sections = New-Object System.Collections.ArrayList
    $read = { param($rel) try { Read-AVDTuneJson (Join-Path $Root $rel) } catch { [pscustomobject]@{ Problem = "$rel could not be read" } } }
    $add = { param($title, $rows, $note) [void]$sections.Add([pscustomobject]@{ Title = $title; Rows = @($rows); Note = [string]$note }) }
    $ver = New-Object System.Collections.ArrayList
    [void]$ver.Add(@('Image version', [string](Get-AVDTuneProp $state 'ImageVersion'))); [void]$ver.Add(@('Finished', $(if ([bool](Get-AVDTuneProp $state 'Sealed')) { 'yes' } else { 'no' }))); [void]$ver.Add(@('AVDTune', $script:SpToolVersion)); [void]$ver.Add(@('Computer', (Protect-AVDTuneSpText $Computer 80)))
    if ($Machine) { try { $w = Get-AVDTuneWindowsInfo -Machine $Machine; [void]$ver.Add(@('Windows', "$($w.Name) $($w.DisplayVersion) ($($w.FullBuild))")) } catch { } }
    foreach ($v in @(@(Get-AVDTuneProp $state 'Versions') | Where-Object { $_ } | Select-Object -Last 15)) { [void]$ver.Add(@("Version $([string](Get-AVDTuneProp $v 'Version'))", (Protect-AVDTuneSpText (@(foreach ($k in 'Started', 'User', 'Sealed', 'Finished') { $x = Get-AVDTuneProp $v $k; if ($null -ne $x -and "$x") { "$k $x" } }) -join ', ') 300))) }
    & $add 'Versions' $ver ''
    $envObj = & $read 'environment.json'
    & $add 'Identity model' @(ConvertTo-AVDTuneSpRows (Get-AVDTuneProp $envObj 'Answers') -Max 30) $(if (-not $envObj) { 'The environment questions are not answered yet.' })
    $storage = @(ConvertTo-AVDTuneSpRows (Get-AVDTuneProp $state 'StorageCheck') -Prefix 'Check' -Max 20) + @(ConvertTo-AVDTuneSpRows (& $read 'config\azure-setup.json') -Prefix 'Setup' -Max 20)
    & $add 'Storage' $storage $(if ($storage.Count -eq 0) { 'No storage check or setup recorded.' })
    $fsl = @(ConvertTo-AVDTuneSpRows (Get-AVDTuneProp $state 'FSLogixTest') -Max 25)
    & $add 'FSLogix' $fsl $(if ($fsl.Count -eq 0) { 'No FSLogix function test recorded.' })
    $mask = @(ConvertTo-AVDTuneSpRows (& $read 'config\masking.json') -Max 25)
    & $add 'App Masking' $mask $(if ($mask.Count -eq 0) { 'No App Masking rules saved.' })
    $prn = @(ConvertTo-AVDTuneSpRows (& $read 'config\printers.json') -Max 25)
    & $add 'Printers' $prn $(if ($prn.Count -eq 0) { 'No printer drivers saved.' })
    $cust = New-Object System.Collections.ArrayList
    if (Get-AVDTuneProp $state 'ImageVersion') { foreach ($g in @(Get-AVDTuneChangeLog -Root $Root -Version ([string](Get-AVDTuneProp $state 'ImageVersion')) | Group-Object Category | Sort-Object Name)) { [void]$cust.Add(@("Changes: $(Protect-AVDTuneSpText $g.Name 60)", [string]$g.Count)) } }
    foreach ($a in @($Recorded)) { if ($a) { [void]$cust.Add(@("Custom software: $(Protect-AVDTuneSpText $a.Name 120)", (Protect-AVDTuneSpText "$($a.Latest.App.Version) ($(@($a.Versions).Count) recording(s), last $($a.Latest.Started))" 200))) } }
    & $add 'Customizations' $cust $(if ($cust.Count -eq 0) { 'No changes recorded for this version.' })
    $bench = New-Object System.Collections.ArrayList
    foreach ($r in @($Benchmark | Where-Object { $_ })) {
        $d = ''; try { if ($r.VsPrevious -and $r.VsPrevious.Host -and $null -ne $r.VsPrevious.Host.DeltaPercent) { $d = ', ' + ([double]$r.VsPrevious.Host.DeltaPercent).ToString('+0.0;-0.0', [Globalization.CultureInfo]::InvariantCulture) + ' % against the previous version' } } catch { }
        $score = { param($x) if ($null -eq $x) { '-' } else { ([double]$x).ToString('0.#', [Globalization.CultureInfo]::InvariantCulture) } }
        [void]$bench.Add(@("Version $([string]$r.ImageVersion)", "host $(& $score $r.HostScore), FSLogix $(& $score $r.FslogixScore), GPU $(& $score $r.GpuScore), users $(& $score $r.CapacityUsers)$d ($([string]$r.Mode))"))
    }
    & $add 'Benchmark comparison' $bench $(if ($bench.Count -eq 0) { 'No benchmark result to compare yet.' })
    [pscustomobject]@{ Title = "Environment $(Protect-AVDTuneSpText $Computer 80) $([string](Get-AVDTuneProp $state 'ImageVersion'))".Trim(); Version = [string](Get-AVDTuneProp $state 'ImageVersion'); Created = (Get-Date).ToString('yyyy-MM-dd HH:mm'); Sections = @($sections) }
}

function ConvertTo-AVDTuneEnvironmentDocument {
    # Pure: the document as a self-contained HTML page. Every value HTML-encoded, no script, a policy that loads nothing (default-src 'none'), like the documentation of #87.
    param([Parameter(Mandatory)]$Data)
    $e = { param($v) [Net.WebUtility]::HtmlEncode([string]$v) }
    $sb = New-Object Text.StringBuilder
    [void]$sb.Append("<!doctype html><html lang=""en""><head><meta charset=""utf-8""><meta http-equiv=""Content-Security-Policy"" content=""default-src 'none'; style-src 'unsafe-inline'""><title>$(& $e $Data.Title)</title>")
    [void]$sb.Append('<style>body{font-family:Segoe UI,sans-serif;margin:24px;max-width:1100px;color:#1b1b1b}h2{margin-top:28px}td,th{text-align:left;padding:3px 10px;vertical-align:top;border-bottom:1px solid #e5e5e5}th{width:32%;font-weight:600}table{border-collapse:collapse;width:100%}.note{color:#616161}</style></head><body>')
    [void]$sb.Append("<h1>$(& $e $Data.Title)</h1><p class=""note"">Created $(& $e $Data.Created) by AVDTune. Values that could be secrets are not shown.</p>")
    foreach ($s in @($Data.Sections)) {
        [void]$sb.Append("<h2>$(& $e $s.Title)</h2>")
        if ($s.Note) { [void]$sb.Append("<p class=""note"">$(& $e $s.Note)</p>") }
        if (@($s.Rows).Count) {
            [void]$sb.Append('<table>')
            foreach ($r in @($s.Rows)) { [void]$sb.Append("<tr><th>$(& $e $r[0])</th><td>$(& $e $r[1])</td></tr>") }
            [void]$sb.Append('</table>')
        }
    }
    [void]$sb.Append('</body></html>')
    $sb.ToString()
}

function Save-AVDTuneEnvironmentDocument {
    # Writes <state>\documents\environment-<version>.html (the folder created as AVDTune's own folder, admin only). Returns Path and Name.
    param([string]$Root = (Get-AVDTuneRoot), [Parameter(Mandatory)]$Data)
    $dir = Join-Path $Root 'documents'
    $d = New-Object IO.DirectoryInfo $dir
    if ($d.Exists -and ($d.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "$dir is a link: not used." }
    if (-not $d.Exists) { New-AVDTuneOwnFolder -Path $dir }
    $v = if (Test-AVDTuneImageVersion $Data.Version) { $Data.Version } else { 'none' }
    $name = "environment-$v.html"
    $path = Join-Path $dir $name
    Write-AVDTuneFile $path (ConvertTo-AVDTuneEnvironmentDocument -Data $Data)
    [pscustomobject]@{ Path = $path; Name = $name; Version = $v }
}

function Send-AVDTuneSpEnvironmentDocument {
    # Uploads the saved document into the library (AVDTune\<version>\environment.html) after the secret check; records the confirmed upload. Returns the upload.
    param([Parameter(Mandatory)]$Context, [string]$Root = (Get-AVDTuneRoot), [Parameter(Mandatory)]$Document)
    $f = Read-AVDTuneSpLocalFile $Document.Path
    if (-not (Test-AVDTuneSpSecretFree $f.Text)) { throw 'The environment document holds something that looks like a password, key or token: not uploaded.' }
    $u = Send-AVDTuneSpFile -Context $Context -Segments @($Document.Version, 'environment.html') -Bytes $f.Bytes -ContentType 'text/html'
    if ($u.Confirmed) { $sent = Get-AVDTuneSpSent -Root $Root; $sent.Documents[$Document.Name] = (Get-Date).ToString('o'); Save-AVDTuneSpSent -Root $Root -Sent $sent }
    $u
}

#endregion

Export-ModuleMember -Function Get-AVDTuneSpSettings, Set-AVDTuneSpSettings, Test-AVDTuneSpSiteUrl, Get-AVDTuneSpSent, Save-AVDTuneSpSent, Get-AVDTuneSpPending, Protect-AVDTuneSpText,
Test-AVDTuneSpSecretFree, Invoke-AVDTuneSpSecretRules, Get-AVDTuneSpErrorResponse, Get-AVDTuneSpItemState, Test-AVDTuneSpUrl, Invoke-AVDTuneSpHttp, Get-AVDTuneSpRetryWait, New-AVDTuneSpContext, Close-AVDTuneSpContext, Invoke-AVDTuneSpRequest, Get-AVDTuneSpAll,
Test-AVDTuneSpSiteId, Resolve-AVDTuneSpSite, Resolve-AVDTuneSpDrive, Initialize-AVDTuneSpList, Get-AVDTuneSpListKeys, Add-AVDTuneSpListItem, ConvertTo-AVDTuneSpChangeLogFields,
Send-AVDTuneSpChangeLog, Send-AVDTuneSpFile, Get-AVDTuneSpSoftwareRows, Send-AVDTuneSpSoftware, Get-AVDTuneSpRemovableRecords, Remove-AVDTuneSpUploadedRecords, ConvertTo-AVDTuneSpRows,
Get-AVDTuneEnvironmentDocumentData, ConvertTo-AVDTuneEnvironmentDocument, Save-AVDTuneEnvironmentDocument, Send-AVDTuneSpEnvironmentDocument
