#requires -Version 5.1
<#
.SYNOPSIS
    Checks the SharePoint uploads (Modules\AVDTune.SharePoint.psm1, issue #89) against the fake Graph (Tests\Fakes\FakeSharePoint.ps1) and a temporary state folder:
    addresses (only graph.microsoft.com), site id, secret filter, Retry-After, the change log list (created with fixed columns, idempotent through EntryId, only new
    entries, missing columns added, two lists of the name refused), paging, throttling, refusals (foreign nextLink, foreign site id, 403, redirect, answer too large),
    the software list with the files of the recordings (confirmed by the size read back), the removal of confirmed records (Remove-AVDTuneTreeSafe, not after the
    finish), the environment document (encoded, policy, no secrets) and the page and the fake.
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
foreach ($m in 'AVDTune', 'AVDTune.SharePoint') { Import-Module (Join-Path $repo "Modules\$m.psm1") -Force }
. (Join-Path $PSScriptRoot 'Fakes\FakeSharePoint.ps1')

$script:failed = 0
function Test-Check([string]$Name, [bool]$Ok, $Detail) { if ($Ok) { "PASS $Name" } else { $script:failed++; "FAIL $Name" + $(if ($null -ne $Detail) { "  -> $Detail" }) } }
function Get-ThrownText([scriptblock]$Block) { try { & $Block | Out-Null; $null } catch { $_.Exception.Message } }
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('avdtune-sp-' + [guid]::NewGuid().ToString('N'))
$jwt = 'eyJhbGciOiJSUzI1NiJ9.eyJhdWQiOiJodHRwczovL2dyYXBoIn0.c2lnbmF0dXJlLW5vdC1yZWFs'
$storageKey = ('Ab1+' * 21) + 'Ab1+=='

function New-Context($sp, [int]$MaxRetries = 5) { New-AVDTuneSpContext -Token $sp.Token -SiteUrl $sp.SiteUrl -Transport $sp.Transport -Sleep $sp.Sleep -MaxRetries $MaxRetries }
function New-Record([string]$Root, [string]$AppId, [int]$Number, [string]$Name, [string]$Version, [string]$Extra = '') {
    $dir = Join-Path $Root "software\custom\$AppId\$($Number.ToString('000'))"
    [void](New-Item -ItemType Directory -Path $dir -Force)
    [IO.File]::WriteAllText((Join-Path $dir 'record.json'), "{`"Schema`":1,`"AppId`":`"$AppId`",`"Number`":$Number,`"Note`":`"$Extra`"}")
    [IO.File]::WriteAllText((Join-Path $dir 'documentation.html'), "<html><body>$Name $Version</body></html>")
    [pscustomobject]@{ Number = $Number; Kind = 'Install'; Result = 'Changed'; App = [pscustomobject]@{ Name = $Name; Version = $Version; Vendor = 'Example Vendor' }; Detection = [pscustomobject]@{ Kind = 'Uninstall'; Key = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Example'; Version = $Version }
        Silent = 'msiexec.exe /i example.msi /qn'; Uninstall = 'msiexec.exe /x {GUID} /qn'; User = 'admin1'; Started = '2026-11-18T10:00:00'; Folder = $dir }
}

try {
    $env:AVDTUNE_ROOT = $tmp
    [void](Initialize-AVDTuneState -Root $tmp)
    [void](Start-AVDTuneImageVersion -Root $tmp -Date ([datetime]'2026-11-18') -User 'admin1')
    $ver = [string](Get-AVDTuneState $tmp).ImageVersion
    Close-AVDTuneWriteGate

    # ---------------------------------------------------------------- addresses, ids, texts (pure)
    $good = @('https://graph.microsoft.com/v1.0/sites/contoso.sharepoint.com:/sites/AVD?$select=id', 'https://graph.microsoft.com/v1.0/drives/b!abcDEF_123-x/root:/AVDTune/2026.11.001/environment.html:/content', 'https://graph.microsoft.com/v1.0/sites/contoso.sharepoint.com,11111111-2222-3333-4444-555555555555,66666666-7777-8888-9999-000000000000/lists/11111111-2222-3333-4444-555555555555/items?$expand=fields($select=EntryId)&$top=200&$skiptoken=200')
    $bad = @('http://graph.microsoft.com/v1.0/sites', 'https://graph.microsoft.com:8443/v1.0/sites', ('https://user:pw' + [char]64 + 'graph.microsoft.com/v1.0/sites'), 'https://evil.example.com/v1.0/sites', 'https://graph.microsoft.com.evil.example.com/v1.0/sites',
        'https://graph.microsoft.com/v1.0/sites#x', 'https://graph.microsoft.com/v1.0/sites?a=1?b=2', 'https://graph.microsoft.com/v1.0/sites/../me', 'https://graph.microsoft.com/v1.0/sites/%2e%2e/me', 'https://graph.microsoft.com/beta/sites', 'https://graph.microsoft.com/v1.0/sites/a b')
    Test-Check 'addresses: Graph v1.0 paths with site ids, drive ids (b!) and paging are allowed' (@($good | Where-Object { -not (Test-AVDTuneSpUrl $_).Ok }).Count -eq 0) (@($good | Where-Object { -not (Test-AVDTuneSpUrl $_).Ok }) -join ' ')
    Test-Check 'addresses (counter-tests): http, other port, credentials, other hosts, fragment, two ?, climbing, encoded dots, beta, spaces are refused' (@($bad | Where-Object { (Test-AVDTuneSpUrl $_).Ok }).Count -eq 0) (@($bad | Where-Object { (Test-AVDTuneSpUrl $_).Ok }) -join ' ')
    $sid = "contoso.sharepoint.com,$([guid]::NewGuid()),$([guid]::NewGuid())"
    Test-Check 'site id: host,guid,guid of the configured host only' ((Test-AVDTuneSpSiteId -Id $sid -SiteHost 'contoso.sharepoint.com') -and -not (Test-AVDTuneSpSiteId -Id $sid -SiteHost 'fabrikam.sharepoint.com') -and -not (Test-AVDTuneSpSiteId -Id 'contoso.sharepoint.com,x,y' -SiteHost 'contoso.sharepoint.com') -and -not (Test-AVDTuneSpSiteId -Id "$sid/../x" -SiteHost 'contoso.sharepoint.com')) $null
    $dirty = "Token $jwt; Authorization: Bearer abcdefghijklmnopqrstuv; Passwort=geheim123; key: $storageKey; https://contoso.blob.core.windows.net/c?sv=2024&sig=AbCdEf123%3D; Lizenzschluessel: ABCD1-EFGH2-IJKL3-MNOP4"
    $clean = Protect-AVDTuneSpText $dirty 2000
    Test-Check 'secret filter: token, bearer, password, storage key, SAS signature and product key are removed' ($clean -notmatch 'eyJhbGci' -and $clean -notmatch 'abcdefghijklmnopqrstuv' -and $clean -notmatch 'geheim123' -and $clean -notmatch [regex]::Escape($storageKey.Substring(0, 30)) -and $clean -notmatch 'AbCdEf123' -and $clean -notmatch 'ABCD1-EFGH2') $clean
    $keep = 'Registry key: HKLM\SOFTWARE\Example; Exit code: 0; snapshot /subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-avd/providers/Microsoft.Compute/snapshots/snap-avd-master-before-update; sha256 ' + ('ab12' * 16)
    Test-Check 'secret filter (counter-test): registry keys, exit codes, GUIDs, snapshot names with hyphens and hex hashes stay' ((Protect-AVDTuneSpText $keep 2000) -ceq $keep) (Protect-AVDTuneSpText $keep 2000)
    Test-Check 'secret check of whole files: a token, a bearer value, a password assignment or a SAS signature is found; a normal page passes' (-not (Test-AVDTuneSpSecretFree "x $jwt") -and -not (Test-AVDTuneSpSecretFree 'Bearer abcdefghijklmnopqrstuvwxyz') -and -not (Test-AVDTuneSpSecretFree '"password": "hunter22"') -and -not (Test-AVDTuneSpSecretFree '?sv=1&sig=AbCdEfGhIjKlMnOpQr') -and (Test-AVDTuneSpSecretFree '<html><td>Password policy</td><td>on</td></html>') -and (Test-AVDTuneSpSecretFree '"LicenseNotes": "server lic1, Passwort=(removed)"')) $null
    Test-Check 'Retry-After: seconds, an HTTP date, none (2, 4, ...) and the upper bound' ((Get-AVDTuneSpRetryWait '7' 0) -eq 7 -and (Get-AVDTuneSpRetryWait '' 0) -eq 2 -and (Get-AVDTuneSpRetryWait '' 1) -eq 4 -and (Get-AVDTuneSpRetryWait '99999' 0 -Max 120) -eq 120 -and (Get-AVDTuneSpRetryWait ([datetime]::UtcNow.AddSeconds(30).ToString('r')) 0) -in 29..31 -and (Get-AVDTuneSpRetryWait 'x' 0) -eq 2) $null

    # ---------------------------------------------------------------- settings
    Test-Check 'settings: without config there is no site (everything local)' ((Get-AVDTuneSpSettings -Root $tmp).SiteUrl -eq '') $null
    Test-Check 'settings (counter-test): a site that is not https://<tenant>.sharepoint.com/sites/<name> is refused' ($null -ne (Get-ThrownText { Set-AVDTuneSpSettings -Root $tmp -SiteUrl 'https://evil.example.com/sites/x' }) -and $null -ne (Get-ThrownText { Set-AVDTuneSpSettings -Root $tmp -SiteUrl 'http://contoso.sharepoint.com/sites/x' })) $null
    $s = Set-AVDTuneSpSettings -Root $tmp -SiteUrl 'https://contoso.sharepoint.com/sites/AVD-Environment/' -UploadAtFinish $true
    Test-Check 'settings: the site and the option are saved' ($s.SiteUrl -eq 'https://contoso.sharepoint.com/sites/AVD-Environment' -and $s.UploadAtFinish -and (Get-AVDTuneSpSettings -Root $tmp).UploadAtFinish) $null

    # ---------------------------------------------------------------- change log list
    foreach ($i in 1..5) { [void](Add-AVDTuneChangeLogEntry -Root $tmp -Version $ver -Category 'Software' -Component "c$i" -ChangeType Added -Text "Entry $i" -User 'admin1') }
    [void](Add-AVDTuneChangeLogEntry -Root $tmp -Version $ver -Category 'Other' -ChangeType Note -Text "Defender portal changed, password=Sommer2026! token $jwt" -User 'admin1')
    $total = @(Get-AVDTuneChangeLog -Root $tmp).Count
    Test-Check 'pending: nothing sent yet' ((Get-AVDTuneSpPending -Root $tmp).Pending -eq $total) $null
    $sp = New-AVDTuneFakeSharePoint; $sp.Store.PageSize = 2
    $ctx = New-Context $sp
    $r1 = Send-AVDTuneSpChangeLog -Context $ctx -Root $tmp -Computer 'AVD-MASTER'
    $list = @($sp.Store.Lists.Values)[0]
    Test-Check 'change log: the list "AVDTune Change Log" is created with its fixed columns and every entry is sent' ($r1.Created -and $r1.Sent -eq $total -and $list.Name -eq 'AVDTune Change Log' -and $list.Items.Count -eq $total -and @(@('EntryId', 'ImageVersion', 'EntryDate', 'Category', 'Component', 'ChangeType', 'Details', 'ChangedBy', 'SnapshotId', 'RunId') | Where-Object { $_ -notin $list.Columns }).Count -eq 0) "$($r1 | Out-String) $($list.Columns -join ',')"
    $all = (@($sp.Store.Bodies) -join ' ') + ' ' + (@($sp.Log) -join ' ')
    Test-Check 'change log: no token, password or sign-in token in any body or address sent' ($all -notmatch 'Sommer2026' -and $all -notmatch 'eyJhbGci' -and $all -notmatch 'fake-sp-token') $null
    Test-Check 'change log: every request went to Graph v1.0 and the token only in the Authorization header' (@($sp.Log | Where-Object { $_ -notmatch '^(GET|POST|PUT|PATCH) /v1\.0/' }).Count -eq 0) ($sp.Log -join ' | ')
    $before = $list.Items.Count
    $r2 = Send-AVDTuneSpChangeLog -Context $ctx -Root $tmp -Computer 'AVD-MASTER'
    Test-Check 'change log: a second upload sends nothing (idempotent through EntryId, keys read across pages)' ($r2.Sent -eq 0 -and $r2.Skipped -eq $total -and $list.Items.Count -eq $before -and -not $r2.Created) "$($r2.Sent) $($r2.Skipped)"
    [void](Add-AVDTuneChangeLogEntry -Root $tmp -Version $ver -Category 'Windows' -ChangeType Updated -Text 'KB5000001' -User 'admin1')
    Remove-Item -LiteralPath (Join-Path $tmp 'config\sharepoint-sent.json') -Force
    $r3 = Send-AVDTuneSpChangeLog -Context $ctx -Root $tmp -Computer 'AVD-MASTER'
    Test-Check 'change log: only the new entry goes up, also when the local record of the sent entries is lost (the list decides)' ($r3.Sent -eq 1 -and $list.Items.Count -eq $before + 1 -and (Get-AVDTuneSpPending -Root $tmp).Pending -eq 0) "$($r3.Sent)"
    $f = $list.Items | Where-Object { $_.Details -like 'Defender*' } | Select-Object -First 1
    Test-Check 'change log: the fields of an item (id, version, UTC date, category, user, computer) and the cleaned text' ($f.EntryId -cmatch '\A[0-9a-f]{12}\z' -and $f.ImageVersion -eq $ver -and $f.EntryDate -match '\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\z' -and $f.ChangedBy -eq 'admin1' -and $f.Computer -eq 'AVD-MASTER' -and $f.Details -match 'password=\(removed\)') "$($f | Out-String)"

    # ---------------------------------------------------------------- columns, duplicates, refusals
    $sp2 = New-AVDTuneFakeSharePoint; $lid = Add-AVDTuneFakeSpList -SharePoint $sp2 -Name 'AVDTune Change Log' -Columns @('EntryId', 'Details')
    $r = Send-AVDTuneSpChangeLog -Context (New-Context $sp2) -Root $tmp
    Test-Check 'an existing list gets the columns it lacks (and is used, not created again)' (-not $r.Created -and $sp2.Store.Lists.Count -eq 1 -and $sp2.Store.Lists[$lid].Columns.Count -eq 12 -and $r.Sent -eq $total + 1) "$($sp2.Store.Lists[$lid].Columns -join ',')"
    $sp3 = New-AVDTuneFakeSharePoint; [void](Add-AVDTuneFakeSpList -SharePoint $sp3 -Name 'AVDTune Change Log'); [void](Add-AVDTuneFakeSpList -SharePoint $sp3 -Name 'AVDTune Change Log'); $sp3.Store.DuplicateList = $true
    Test-Check 'two lists of the name are refused, nothing sent' ((Get-ThrownText { Send-AVDTuneSpChangeLog -Context (New-Context $sp3) -Root $tmp }) -like '*2 lists*' -and @($sp3.Log | Where-Object { $_ -like 'POST*' }).Count -eq 0) $null
    $sp4 = New-AVDTuneFakeSharePoint; $sp4.Store.Throttle = 2; $sp4.Store.RetryAfter = '7'
    $r = Send-AVDTuneSpChangeLog -Context (New-Context $sp4) -Root $tmp
    Test-Check 'throttling: 429 is tried again after Retry-After (7 s twice), then the upload goes through' ($r.Sent -eq $total + 1 -and (@($sp4.Store.Waits) -join ',') -eq '7,7') (@($sp4.Store.Waits) -join ',')
    $sp5 = New-AVDTuneFakeSharePoint; $sp5.Store.Throttle = 50
    $t = Get-ThrownText { Send-AVDTuneSpChangeLog -Context (New-Context $sp5 -MaxRetries 3) -Root $tmp }
    Test-Check 'throttling (counter-test): it stops after the bounded number of tries with a clear message' ($t -like '*429*4 times*' -and $sp5.Store.Log.Count -eq 4) $t
    $sp6 = New-AVDTuneFakeSharePoint; $sp6.Store.PageSize = 1; [void](Add-AVDTuneFakeSpList -SharePoint $sp6 -Name 'Other'); [void](Add-AVDTuneFakeSpList -SharePoint $sp6 -Name 'Third'); $sp6.Store.NextLinkTo = 'https://evil.example.com/v1.0/sites?$skiptoken=1'
    $t = Get-ThrownText { Send-AVDTuneSpChangeLog -Context (New-Context $sp6) -Root $tmp }
    Test-Check 'paging (counter-test): a nextLink to another host is refused before any request goes there' ($t -like '*evil.example.com*not allowed*' -and @($sp6.Log | Where-Object { $_ -like '*skiptoken*' -or $_ -like 'POST*' }).Count -eq 0) $t
    $sp7 = New-AVDTuneFakeSharePoint; $sp7.Store.BadSiteId = $true
    $t = Get-ThrownText { Send-AVDTuneSpChangeLog -Context (New-Context $sp7) -Root $tmp }
    Test-Check 'a site id of another host is refused, no list is read or created' ($t -like '*site id*' -and $sp7.Log.Count -eq 1) $t
    $sp8 = New-AVDTuneFakeSharePoint; $sp8.Store.Forbidden = $true
    $sentBefore = (Get-AVDTuneSpSent -Root $tmp).ChangeLog.Count
    $t = Get-ThrownText { Send-AVDTuneSpChangeLog -Context (New-Context $sp8) -Root $tmp }
    Test-Check '403 to the write: the message names the missing write access (Sites.Selected), no token in it' ($t -like '*403*Sites.Selected*' -and $t -notmatch 'fake-sp-token') $t
    $sp9 = New-AVDTuneFakeSharePoint; $sp9.Store.Redirect = $true
    Test-Check 'a redirect is never followed' ((Get-ThrownText { Send-AVDTuneSpChangeLog -Context (New-Context $sp9) -Root $tmp }) -like '*redirect*not followed*') $null
    $sp10 = New-AVDTuneFakeSharePoint; $sp10.Store.Huge = $true
    Test-Check 'an answer larger than 4 MB is refused' ((Get-ThrownText { Send-AVDTuneSpChangeLog -Context (New-Context $sp10) -Root $tmp }) -like '*larger than*') $null
    $sp11 = New-AVDTuneFakeSharePoint; $sp11.Store.Offline = $true
    Test-Check 'offline: the error goes back, the entries stay pending locally' ($null -ne (Get-ThrownText { Send-AVDTuneSpChangeLog -Context (New-Context $sp11) -Root $tmp })) $null
    $c0 = New-Context $sp; Close-AVDTuneSpContext $c0
    Test-Check 'a closed context has no token and sends nothing' ($null -eq $c0.Token -and (Get-ThrownText { Send-AVDTuneSpChangeLog -Context $c0 -Root $tmp }) -like '*Not signed in*') $null
    Test-Check 'an upload larger than 4 MB is not sent' ((Get-ThrownText { Send-AVDTuneSpFile -Context (New-Context $sp) -Segments @('x.bin') -Bytes (New-Object byte[] (4MB + 1)) }) -like '*larger than*') $null
    Test-Check 'a library name with .. or a separator is refused' ($null -ne (Get-ThrownText { Send-AVDTuneSpFile -Context (New-Context $sp) -Segments @('..', 'x.html') -Bytes ([byte[]]@(1)) }) -and $null -ne (Get-ThrownText { Send-AVDTuneSpFile -Context (New-Context $sp) -Segments @('a/b.html') -Bytes ([byte[]]@(1)) })) $null

    # ---------------------------------------------------------------- software list and records
    $recA = New-Record $tmp 'aaaaaaaaaaaa' 1 'Example App' '5.2'
    $recB = New-Record $tmp 'bbbbbbbbbbbb' 1 'Secret App' '1.0' ('password=' + 'hunter22')
    $apps = @([pscustomobject]@{ Id = 'aaaaaaaaaaaa'; Name = 'Example App'; Latest = $recA; Versions = @($recA) }, [pscustomobject]@{ Id = 'bbbbbbbbbbbb'; Name = 'Secret App'; Latest = $recB; Versions = @($recB) })
    $inst = @([pscustomobject]@{ Name = 'Example Viewer'; Version = '2.1'; Publisher = 'Example Vendor'; Arch = 'x64'; Key = '{11111111-2222-3333-4444-555555555555}' }, [pscustomobject]@{ Name = 'Tool'; Version = '1'; Publisher = ''; Arch = 'x86'; Key = 'Tool' })
    $sp12 = New-AVDTuneFakeSharePoint
    $sw = Send-AVDTuneSpSoftware -Context (New-Context $sp12) -Root $tmp -ImageVersion $ver -Recorded $apps -Installed $inst -Computer 'AVD-MASTER'
    $slist = @($sp12.Store.Lists.Values | Where-Object { $_.Name -eq 'AVDTune Software' })[0]
    Test-Check 'software: the list "AVDTune Software" gets the recordings and the installed programs' ($sw.Created -and $sw.Sent -eq 4 -and $slist.Items.Count -eq 4 -and @($slist.Items | Where-Object { $_.Source -like 'Custom*' }).Count -eq 2 -and @($slist.Items | Where-Object { $_.Source -like 'Installed*' }).Count -eq 2) "$($sw | Out-String)"
    Test-Check 'software: the documentation and the record of a recording go to AVDTune\<version>\software and are confirmed' ($sw.Files -eq 2 -and $sw.Confirmed -eq 1 -and $sp12.Store.Files.ContainsKey("AVDTune/$ver/software/aaaaaaaaaaaa-001.html") -and $sp12.Store.Files.ContainsKey("AVDTune/$ver/software/aaaaaaaaaaaa-001.json")) ($sp12.Store.Files.Keys -join ', ')
    Test-Check 'software (counter-test): a record that holds a password is not uploaded and named' (-not $sp12.Store.Files.ContainsKey("AVDTune/$ver/software/bbbbbbbbbbbb-001.json") -and (@($sw.Problems) -join ' ') -like '*bbbbbbbbbbbb/001*password*') ($sw.Problems -join ' ')
    $sw2 = Send-AVDTuneSpSoftware -Context (New-Context $sp12) -Root $tmp -ImageVersion $ver -Recorded $apps -Installed $inst
    Test-Check 'software: a second upload sends no row twice' ($sw2.Sent -eq 0 -and $sw2.Skipped -eq 4 -and $slist.Items.Count -eq 4) $null
    $rem = @(Get-AVDTuneSpRemovableRecords -Root $tmp -Recorded $apps)
    Test-Check 'records: only the confirmed and unchanged recording may be removed' ($rem.Count -eq 1 -and $rem[0].Key -eq 'aaaaaaaaaaaa/001') (@($rem | ForEach-Object { $_.Key }) -join ',')
    [IO.File]::AppendAllText((Join-Path $recA.Folder 'documentation.html'), 'changed')
    Test-Check 'records (counter-test): a record changed after the upload is not removable' (@(Get-AVDTuneSpRemovableRecords -Root $tmp -Recorded $apps).Count -eq 0) $null
    $sp13 = New-AVDTuneFakeSharePoint; $sp13.Store.WrongSize = $true
    $sw3 = Send-AVDTuneSpSoftware -Context (New-Context $sp13) -Root $tmp -ImageVersion $ver -Recorded @($apps[0]) -Installed @()
    Test-Check 'records (counter-test): an upload whose size read back differs is not confirmed and not removable' ($sw3.Confirmed -eq 0 -and (@($sw3.Problems) -join ' ') -like '*confirmed*' -and @(Get-AVDTuneSpRemovableRecords -Root $tmp -Recorded $apps).Count -eq 0) ($sw3.Problems -join ' ')
    $sw4 = Send-AVDTuneSpSoftware -Context (New-Context $sp12) -Root $tmp -ImageVersion $ver -Recorded @($apps[0]) -Installed @()
    Test-Check 'records: the upload again (replaces the file) confirms the changed record' ($sw4.Confirmed -eq 1 -and @(Get-AVDTuneSpRemovableRecords -Root $tmp -Recorded $apps).Count -eq 1) $null
    [void](Set-AVDTuneState -Root $tmp -Values @{ Sealed = $true })
    Test-Check 'records: not removed after the finish (Sealed)' ((Get-ThrownText { Remove-AVDTuneSpUploadedRecords -Root $tmp -Recorded $apps -User 'admin1' }) -like '*finished*' -and (Test-Path -LiteralPath $recA.Folder)) $null
    [void](Set-AVDTuneState -Root $tmp -Values @{ Sealed = $false })
    $outside = Join-Path ([IO.Path]::GetTempPath()) ('avdtune-sp-out-' + [guid]::NewGuid().ToString('N')); [void](New-Item -ItemType Directory -Path $outside); [IO.File]::WriteAllText((Join-Path $outside 'keep.txt'), 'keep')
    $link = Join-Path $recA.Folder 'link'; cmd.exe /c mklink /J "$link" "$outside" | Out-Null
    $rr = Remove-AVDTuneSpUploadedRecords -Root $tmp -Recorded $apps -User 'admin1'
    Test-Check 'records: the confirmed record is removed through Remove-AVDTuneTreeSafe (a link inside is removed as a link, its target stays), the empty app folder too, a change log entry names it' (@($rr.Removed).Count -eq 1 -and -not (Test-Path -LiteralPath (Split-Path $recA.Folder -Parent)) -and (Test-Path -LiteralPath (Join-Path $outside 'keep.txt')) -and (Test-Path -LiteralPath $recB.Folder) -and @(Get-AVDTuneChangeLog -Root $tmp | Where-Object { $_.Component -eq 'sharepoint.records' }).Count -eq 1) "$($rr | Out-String)"
    Remove-Item -LiteralPath $outside -Recurse -Force

    # ---------------------------------------------------------------- environment document
    Write-AVDTuneFile (Join-Path $tmp 'environment.json') (@{ Schema = 1; Answers = @{ IdentityModel = 'HybridAdDs'; Profiles = 'AzureFiles'; StorageAccountKey = $storageKey; Note = '<script>alert(1)</script>' } } | ConvertTo-Json -Depth 4)
    Write-AVDTuneFile (Join-Path $tmp 'config\masking.json') (@{ Rules = @(@{ Name = 'Hide Visio' }); Mode = 'Groups' } | ConvertTo-Json -Depth 4)
    $bench = @([pscustomobject]@{ ImageVersion = $ver; HostScore = 812.4; FslogixScore = 90; GpuScore = $null; CapacityUsers = 14; Mode = 'Full'; VsPrevious = [pscustomobject]@{ Host = [pscustomobject]@{ DeltaPercent = -3.25 } } })
    $data = Get-AVDTuneEnvironmentDocumentData -Root $tmp -Recorded @($apps[1]) -Benchmark $bench -Computer 'AVD-MASTER'
    $html = ConvertTo-AVDTuneEnvironmentDocument -Data $data
    $titles = @($data.Sections | ForEach-Object { $_.Title })
    Test-Check 'document: identity model, storage, FSLogix, App Masking, printers, customizations, benchmark comparison and versions' ((@('Versions', 'Identity model', 'Storage', 'FSLogix', 'App Masking', 'Printers', 'Customizations', 'Benchmark comparison') | Where-Object { $_ -notin $titles }).Count -eq 0 -and $html -like '*HybridAdDs*' -and $html -like '*Rules*1 entries*') ($titles -join ', ')
    Test-Check 'document: the benchmark row with score and change against the previous version' ($html -like "*Version $ver*" -and $html -like '*host 812.4*' -and $html -like '*-3.3 %*') $null
    Test-Check 'document: every value HTML-encoded, no script, a policy that loads nothing' ($html -notmatch '<script' -and $html -like '*&lt;script&gt;*' -and $html -like "*http-equiv=`"Content-Security-Policy`" content=`"default-src 'none'; style-src 'unsafe-inline'`"*") $null
    Test-Check 'document: a field that sounds secret is not shown, a key value never appears' ($html -notmatch [regex]::Escape($storageKey.Substring(0, 30)) -and $html -like '*StorageAccountKey*(not shown)*') $null
    $doc = Save-AVDTuneEnvironmentDocument -Root $tmp -Data $data
    Test-Check 'document: saved locally as documents\environment-<version>.html in a folder of AVDTune' ($doc.Path -eq (Join-Path $tmp "documents\environment-$ver.html") -and (Test-Path -LiteralPath $doc.Path)) $doc.Path
    $sp14 = New-AVDTuneFakeSharePoint
    $u = Send-AVDTuneSpEnvironmentDocument -Context (New-Context $sp14) -Root $tmp -Document $doc
    Test-Check 'document: uploaded to AVDTune\<version>\environment.html and confirmed' ($u.Confirmed -and $sp14.Store.Files.ContainsKey("AVDTune/$ver/environment.html") -and (Get-AVDTuneSpSent -Root $tmp).Documents.ContainsKey($doc.Name)) $null
    [IO.File]::WriteAllText($doc.Path, "<html>$jwt</html>")
    Test-Check 'document (counter-test): a document that holds a token is not uploaded' ((Get-ThrownText { Send-AVDTuneSpEnvironmentDocument -Context (New-Context $sp14) -Root $tmp -Document $doc }) -like '*not uploaded*') $null

    # ---------------------------------------------------------------- module, fake, page
    $mod = [IO.File]::ReadAllText((Join-Path $repo 'Modules\AVDTune.SharePoint.psm1'))
    Test-Check 'module: no Invoke-WebRequest/Invoke-RestMethod, no automatic redirect, TLS added with -bor, the token only in the Authorization header' ($mod -notmatch 'Invoke-WebRequest|Invoke-RestMethod|Start-Process|Invoke-Expression' -and $mod -match 'AllowAutoRedirect = \$false' -and $mod -match 'SecurityProtocol -bor' -and $mod -match 'Authorization = "Bearer \$\(\$Context\.Token\)"') $null
    Test-Check 'module: records are removed with Remove-AVDTuneTreeSafe, the document folder made with New-AVDTuneOwnFolder' ($mod -match 'Remove-AVDTuneTreeSafe -Path \$folder' -and $mod -match 'New-AVDTuneOwnFolder -Path \$dir' -and $mod -notmatch 'Remove-Item') $null
    $fakeText = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Fakes\FakeSharePoint.ps1'))
    Test-Check 'fake: loads FakeShared and the factory ends with ConvertTo-AVDTuneFakeShared (#80: shared with a runspace), its blocks are unbound' ($fakeText -match "Resolve-AVDTuneTestScript -Path \(Join-Path \`$PSScriptRoot 'FakeShared\.ps1'\)" -and $fakeText -match 'ConvertTo-AVDTuneFakeShared \(\[pscustomobject\]\$sp\)' -and $null -eq $sp.Transport.Module) $null
    $switches = @('Offline', 'Throttle', 'RetryAfter', 'PageSize', 'NextLinkTo', 'Forbidden', 'BadSiteId', 'WrongSize', 'Redirect', 'DuplicateList', 'Huge')
    $self = [IO.File]::ReadAllText($PSCommandPath)
    Test-Check 'fake: every switch is used by a check here' (@($switches | Where-Object { $self -notmatch "Store\.$_ = " }).Count -eq 0) (@($switches | Where-Object { $self -notmatch "Store\.$_ = " }) -join ', ')
    $page = [IO.File]::ReadAllText((Join-Path $repo 'AVDTune-SharePoint.ps1'))
    Test-Check 'page: worker through New-AVDTunePowerShell after Assert-NoOtherWriter -AllowSealed, a task, the removal under Enter-AVDTuneWriter, texts from the language files' ($page -match 'New-AVDTunePowerShell' -and $page -match 'Assert-NoOtherWriter -AllowSealed' -and $page -match 'Start-AVDTuneUiTask' -and $page -match "Enter-AVDTuneWriter -Kind 'sharepoint-remove'" -and $page -match "T 'sp\." -and $page -notmatch 'GetNewClosure') $null
    $tasks = [IO.File]::ReadAllText((Join-Path $repo 'AVDTune-Tasks.ps1')); $seal = [IO.File]::ReadAllText((Join-Path $repo 'AVDTune-Seal.ps1'))
    Test-Check 'page: the upload is a writer job, and the finish uploads first when the option is on' ($tasks -match "'SpJob'\)" -and $seal -match "if \(Test-SpUploadAtFinish\) \{ Start-SpJob 'ChangeLog' \{ Start-SealJob \}; return \}") $null
}
finally {
    Close-AVDTuneWriteGate
    Remove-Item Env:\AVDTUNE_ROOT -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $tmp) { try { [void](Remove-AVDTuneTreeSafe -Path $tmp) } catch { } }
}
if ($script:failed -gt 0) { "$script:failed check(s) failed."; exit 1 }
'All SharePoint checks passed.'
