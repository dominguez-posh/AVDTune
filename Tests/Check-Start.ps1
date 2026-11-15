#requires -Version 5.1
<#
.SYNOPSIS
    Checks the start sequence against fakes (Tests\Fakes\FakeServices.ps1, FakeMachine.ps1): first-run questions and environment.json,
    the sign-in session (four audiences, tokens in memory), the snapshot gate (IMDS, ARM, confirmation by name, read-only until then),
    the domain controller connection (LDAPS pinning, signed fallback, never a simple bind) and discovery, including the error paths:
    no network, 403 (missing role), changed LDAPS certificate, LDAPS blocked, snapshot older than the last change, one-word name. No real sign-in, tenant, Azure or domain controller.
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'Modules\AVDTune.psm1') -Force
foreach ($m in 'Trust', 'Session', 'Snapshot', 'Directory', 'Start') { Import-Module (Join-Path $repo "Modules\AVDTune.$m.psm1") -Force }
. (Join-Path $PSScriptRoot 'Fakes\FakeMachine.ps1')
. (Join-Path $PSScriptRoot 'Fakes\FakeServices.ps1')

$script:failed = 0
function Test-Check([string]$Name, [bool]$Ok, $Detail) { if ($Ok) { "PASS $Name" } else { $script:failed++; "FAIL $Name" + $(if ($null -ne $Detail) { "  -> $Detail" }) } }
function Get-ThrownText([scriptblock]$Block) { try { & $Block | Out-Null; $null } catch { $_.Exception.Message } }
function New-Secret([string]$Text) { ConvertTo-AVDTuneSecure $Text }
$secretPassword = 'Zq9-Check-Password-Not-Real'

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('avdtune-start-' + [guid]::NewGuid().ToString('N'))
try {
    $env:AVDTUNE_ROOT = $tmp
    $env:AVDTUNE_FAKE = Join-Path $PSScriptRoot 'Fakes\FakeMachine.ps1'
    [void](Initialize-AVDTuneState -Root $tmp)
    Close-AVDTuneWriteGate
    $signTemp = Join-Path $tmp 'signin-temp'; New-Item -ItemType Directory -Path $signTemp -Force | Out-Null

    # ---------------------------------------------------------------- first-run questions
    $a = Get-AVDTuneEnvironmentDefaults
    Test-Check 'defaults are valid (Entra only, no DC, Azure Files)' ((Test-AVDTuneEnvironmentAnswers $a).Errors.Count -eq 0) $null
    $plan = Resolve-AVDTuneEnvironmentPlan $a
    Test-Check 'Entra only, cloud only: no DC step, Entra Kerberos' (-not $plan.UsesDc -and $plan.AzureFilesAuth -eq 'EntraKerberos' -and $plan.HiddenPages.Count -eq 0) ($plan | ConvertTo-Json -Compress)
    $h = Get-AVDTuneEnvironmentDefaults; $h.Join = 'Hybrid'
    Test-Check 'hybrid join without a DC is refused' ((Test-AVDTuneEnvironmentAnswers $h).Errors.Count -ge 1) $null
    $h.Dc = 'AdDsOnPrem'
    Test-Check 'hybrid join with cloud-only identities is refused' ((Test-AVDTuneEnvironmentAnswers $h).Errors -join ' ' -like '*synchronized*') $null
    $h.Identities = 'Synced'
    $hp = Resolve-AVDTuneEnvironmentPlan $h
    Test-Check 'hybrid with an on-premises DC: DC step, AD DS first, Entra Kerberos possible' ((Test-AVDTuneEnvironmentAnswers $h).Errors.Count -eq 0 -and $hp.UsesDc -and $hp.AzureFilesAuth -eq 'AdDs' -and $hp.AzureFilesAuthChoices -contains 'EntraKerberos') ($hp | ConvertTo-Json -Compress)
    $h.Dc = 'EntraDs'
    Test-Check 'hybrid join with Entra Domain Services is refused' ((Test-AVDTuneEnvironmentAnswers $h).Errors -join ' ' -like '*hybrid*') $null
    $n = Get-AVDTuneEnvironmentDefaults; $n.Profiles = 'None'
    Test-Check 'without FSLogix: FSLogix and App Masking pages hidden, no Azure Files auth' ((Resolve-AVDTuneEnvironmentPlan $n).HiddenPages -join ',' -eq 'FSLogix,AppMasking' -and (Resolve-AVDTuneEnvironmentPlan $n).AzureFilesAuth -eq 'None') $null
    $bad = Get-AVDTuneEnvironmentDefaults; $bad.ClientId = '14d82eec-204b-4c2f-b7e8-296a70dab67e'
    Test-Check 'the setup app of Microsoft is refused as client ID' ((Test-AVDTuneEnvironmentAnswers $bad).Errors -join ' ' -like "*setup app*") $null
    $bad = Get-AVDTuneEnvironmentDefaults; $bad.Subnet = 'x;rm -rf'
    Test-Check 'a subnet name with odd characters is refused' ((Test-AVDTuneEnvironmentAnswers $bad).Errors.Count -eq 1) $null
    $bad = Get-AVDTuneEnvironmentDefaults; $bad.AzureFilesAuth = 'AdDs'
    Test-Check 'an Azure Files auth that does not fit only warns and the first fitting method is used' ((Test-AVDTuneEnvironmentAnswers $bad).Warnings.Count -eq 1 -and (Resolve-AVDTuneEnvironmentPlan $bad).AzureFilesAuth -eq 'EntraKerberos') $null

    Test-Check 'no environment.json before the first run' ($null -eq (Get-AVDTuneEnvironment $tmp)) $null
    $ctx = New-AVDTuneStartContext
    $stages = Get-AVDTuneStartStages -Context $ctx -Root $tmp
    Test-Check 'stages before the first run: questions pending, the rest locked' (($stages | ForEach-Object { $_.Status }) -join ',' -eq 'Pending,Locked,Locked,Locked') (($stages | ForEach-Object { $_.Status }) -join ',')
    $tenant = '11111111-2222-3333-4444-555555555555'
    $clientId = '66666666-7777-8888-9999-000000000000'
    $answers = Get-AVDTuneEnvironmentDefaults; $answers.TenantId = $tenant; $answers.ClientId = $clientId; $answers.VNet = 'vnet-example'; $answers.Subnet = 'snet-avd'
    $saved = Save-AVDTuneEnvironment -Root $tmp -Answers $answers -User 'admin1'
    $envPath = Join-Path $tmp 'environment.json'
    Test-Check 'environment.json is written with the answers and the sign-in target' ((Test-Path $envPath) -and $saved.Environment.Answers.Join -eq 'EntraOnly' -and $saved.Environment.SignIn.ClientId -eq $clientId -and $saved.Environment.Answers.Network.VNet -eq 'vnet-example') $null
    Test-Check 'environment.json has no field for a secret' ((Get-Content $envPath -Raw) -notmatch '(?i)password|secret|token|key') $null
    Test-Check 'invalid answers are not saved' ($null -ne (Get-ThrownText { $x = Get-AVDTuneEnvironmentDefaults; $x.Join = 'AdDs'; Save-AVDTuneEnvironment -Root $tmp -Answers $x })) $null
    Test-Check 'the saved file was not changed by the refused save' ((Get-AVDTuneEnvironment $tmp).Answers.Join -eq 'EntraOnly') $null
    $stages = Get-AVDTuneStartStages -Context $ctx -Root $tmp
    Test-Check 'with the answers: questions done, sign-in pending, domain skipped (Entra only)' (($stages | ForEach-Object { $_.Status }) -join ',' -eq 'Done,Pending,Skipped,Locked') (($stages | ForEach-Object { $_.Status }) -join ',')
    [void](Start-AVDTuneImageVersion -Root $tmp -Date ([datetime]'2026-11-15') -User 'admin1')
    $answers2 = Get-AVDTuneEnvironmentAnswers (Get-AVDTuneEnvironment $tmp); $answers2.Profiles = 'OtherSmb'
    $changed = Save-AVDTuneEnvironment -Root $tmp -Answers $answers2 -User 'admin1'
    $log = @(Get-AVDTuneChangeLog -Root $tmp)
    Test-Check 'a later change of an answer is a change log entry (old -> new)' ($changed.Changes.Count -ge 1 -and $log.Count -eq 1 -and $log[0].Text -like '*Profiles: AzureFiles -> OtherSmb*') ($log | ConvertTo-Json -Compress)

    # ---------------------------------------------------------------- sign-in session
    $auth = New-AVDTuneFakeAuth
    $session = New-AVDTuneSession -TempRoot $signTemp -Auth $auth
    $info = Connect-AVDTuneSession -Session $session -TenantId $tenant -ClientId $clientId
    Test-Check 'sign-in: connected, account known, four audiences; Sites, ARM and Storage tokens carry their permission' ($info.Connected -and $info.Account -like 'admin.example@*' -and $info.Audiences.Count -eq 4 -and ($info.Audiences | Where-Object Audience -eq 'Sites').Scopes -contains 'Sites.Selected' -and ($info.Audiences | Where-Object Audience -eq 'Arm').Scopes -join ',' -eq 'user_impersonation') ($info | ConvertTo-Json -Compress -Depth 4)
    Test-Check 'one interactive sign-in only; the other tokens come from the refresh token' (@($auth.Log | Where-Object { $_ -like 'SignIn*' }).Count -eq 1 -and @($auth.Log | Where-Object { $_ -like 'Refresh*hasRefreshToken=True' }).Count -eq 4) ($auth.Log -join ' | ')
    $graphScopes = ($info.Audiences | Where-Object Audience -eq 'Graph').Scopes
    # v2 tokens carry every consented scope of their resource: the two Graph tokens are not separated by scope (finding 5), only Graph and ARM are
    Test-Check 'honest separation: both Graph tokens carry all Graph permissions, the ARM token none of them' ((@($graphScopes | Sort-Object) -join ',') -eq (@(($info.Audiences | Where-Object Audience -eq 'Sites').Scopes | Sort-Object) -join ',') -and $graphScopes -contains 'Sites.Selected' -and @(($info.Audiences | Where-Object Audience -eq 'Arm').Scopes | Where-Object { $_ -in $graphScopes }).Count -eq 0) ($graphScopes -join ',')
    Test-Check 'the consented AVDTune permissions alone give no warning' (@($info.Warnings).Count -eq 0) (@($info.Warnings) -join ' | ')
    $authExtra = New-AVDTuneFakeAuth -Seed @{ ExtraScopes = @{ 'https://graph.microsoft.com' = @('Mail.ReadWrite') } }
    $sx = New-AVDTuneSession -TempRoot $signTemp -Auth $authExtra
    $ix = Connect-AVDTuneSession -Session $sx -TenantId $tenant -ClientId $clientId
    Test-Check 'a token with a permission AVDTune does not ask for: kept, but a warning names it (for the protocol)' ($ix.Connected -and @($ix.Warnings).Count -eq 2 -and (@($ix.Warnings) -join ' ') -like '*Graph token*Mail.ReadWrite*' -and (@($ix.Warnings) -join ' ') -like '*Sites token*Mail.ReadWrite*' -and (@($ix.Warnings) -join ' ') -notlike '*Arm token*') (@($ix.Warnings) -join ' | ')
    Disconnect-AVDTuneSession $sx
    Test-Check 'disconnect clears the warnings too' (@($sx.Warnings).Count -eq 0) $null
    # temporary profiles of the sign-in window (finding 6)
    $authLeft = New-AVDTuneFakeAuth -Seed @{ LeaveProfileIn = $signTemp }
    $sl = New-AVDTuneSession -TempRoot $signTemp -Auth $authLeft
    [void](Connect-AVDTuneSession -Session $sl -TenantId $tenant -ClientId $clientId)
    Test-Check 'the profile the sign-in window left in TEMP is deleted right after the sign-in' (@(Get-AVDTuneSignInLeftovers -TempRoot $signTemp).Count -eq 0 -and @($authLeft.Log | Where-Object { $_ -like 'SignIn*' }).Count -eq 1) (@(Get-ChildItem $signTemp -Name) -join ',')
    $planted = Join-Path $signTemp ('PackTuneSignIn-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $planted -Force | Out-Null
    $lockedFile = Join-Path $planted 'Cookies'; [IO.File]::WriteAllText($lockedFile, 'x')
    $lock = [IO.File]::Open($lockedFile, 'Open', 'Read', 'None')
    Disconnect-AVDTuneSession $sl
    Test-Check 'a profile that is still locked stays and Test-AVDTuneSessionClear says so (final check before Finish)' ((Test-Path $planted) -and -not (Test-AVDTuneSessionClear $sl)) $null
    $releaser = [powershell]::Create(); [void]$releaser.AddScript({ param($h) Start-Sleep -Milliseconds 700; $h.Dispose() }).AddArgument($lock); $rh = $releaser.BeginInvoke()
    $left = @(Remove-AVDTuneSignInLeftovers -TempRoot $signTemp -Tries 20 -DelayMilliseconds 200)
    [void]$releaser.EndInvoke($rh); $releaser.Dispose()
    Test-Check 'the removal retries until the browser lets go of the profile; then the session counts as clear' ($left.Count -eq 0 -and -not (Test-Path $planted) -and (Test-AVDTuneSessionClear $sl)) ($left -join ',')
    $other = Join-Path $signTemp 'PackTuneSignIn-not-a-guid'; New-Item -ItemType Directory -Path $other -Force | Out-Null
    Test-Check 'only profile folders of the sign-in window (PackTuneSignIn-<32 hex>) are touched' ((@(Remove-AVDTuneSignInLeftovers -TempRoot $signTemp).Count -eq 0) -and (Test-Path $other)) $null
    Remove-Item $other -Force
    $armToken = Get-AVDTuneAccessToken -Session $session -Audience Arm
    Test-Check 'the ARM token has the Azure audience; tokens are SecureStrings in the session' ((Get-AVDTuneTokenClaims $armToken).aud -eq 'https://management.azure.com' -and $session.Tokens.Arm.Access -is [System.Security.SecureString] -and $session.Refresh -is [System.Security.SecureString]) $null
    Test-Check 'the session info and the fake log hold no token' (($info | ConvertTo-Json -Depth 5) -notmatch 'eyJ|fake-refresh|fakesignature' -and ($auth.Log -join ' ') -notmatch 'eyJ|fake-refresh-\d') $null
    $before = $auth.Log.Count
    $session.Tokens.Arm.ExpiresOn = (Get-Date).ToUniversalTime().AddMinutes(1)
    $t2 = Get-AVDTuneAccessToken -Session $session -Audience Arm
    Test-Check 'a token that expires within 3 minutes is refreshed' ($auth.Log.Count -eq $before + 1 -and $t2 -ne $armToken) $null
    Disconnect-AVDTuneSession $session
    Test-Check 'disconnect removes every token and the check proves it' ((Test-AVDTuneSessionClear $session) -and ($null -ne (Get-ThrownText { Get-AVDTuneAccessToken -Session $session -Audience Arm }))) $null
    # ---------------------------------------------------------------- sign-in error paths
    $s2 = New-AVDTuneSession -TempRoot $signTemp -Auth (New-AVDTuneFakeAuth -Seed @{ Offline = $true })
    $e = Get-ThrownText { Connect-AVDTuneSession -Session $s2 -TenantId $tenant -ClientId $clientId }
    Test-Check 'sign-in without network: readable text, session stays empty' ($e -like 'No connection to Microsoft sign-in*' -and (Test-AVDTuneSessionClear $s2)) $e
    # ---------------------------------------------------------------- storage audience (issue 18)
    $sAuth = New-AVDTuneFakeAuth
    $sSession = New-AVDTuneSession -TempRoot $signTemp -Auth $sAuth
    $sInfo = Connect-AVDTuneSession -Session $sSession -TenantId $tenant -ClientId $clientId
    $stTok = Get-AVDTuneAccessToken -Session $sSession -Audience Storage
    $stClaims = Get-AVDTuneTokenClaims $stTok
    Test-Check 'storage token: audience https://storage.azure.com, scope user_impersonation, the tenant of the sign-in, a SecureString in the session' ($stClaims.aud -eq 'https://storage.azure.com' -and $stClaims.scp -eq 'user_impersonation' -and $stClaims.tid -eq $tenant -and $sSession.Tokens.Storage.Access -is [System.Security.SecureString] -and @($sInfo.Unavailable).Count -eq 0) ($sInfo | ConvertTo-Json -Compress -Depth 4)
    Test-Check 'the storage token is fetched with the Storage scope from the refresh token (no second interactive sign-in)' (@($sAuth.Log | Where-Object { $_ -like 'SignIn*' }).Count -eq 1 -and @($sAuth.Log | Where-Object { $_ -eq 'Refresh tenant=' + $tenant + ' scopes=https://storage.azure.com/user_impersonation hasRefreshToken=True' }).Count -eq 1) ($sAuth.Log -join ' | ')
    Test-Check 'the session info and the log hold no storage token' ((($sInfo | ConvertTo-Json -Depth 5) + ($sAuth.Log -join ' ')) -notmatch 'eyJ|fake-refresh-\d|fakesignature') $null
    $sSession.Tokens.Storage.ExpiresOn = (Get-Date).ToUniversalTime().AddMinutes(1)
    $stTok2 = Get-AVDTuneAccessToken -Session $sSession -Audience Storage
    Test-Check 'an expiring storage token is refreshed like the others' ($stTok2 -ne $stTok -and (Get-AVDTuneTokenClaims $stTok2).aud -eq 'https://storage.azure.com') $null
    Disconnect-AVDTuneSession $sSession
    Test-Check 'disconnect removes the storage token too' ((Test-AVDTuneSessionClear $sSession) -and $sSession.Unavailable.Count -eq 0 -and $null -ne (Get-ThrownText { Get-AVDTuneAccessToken -Session $sSession -Audience Storage })) $null
    # counter-tests: a wrong audience, a foreign host as audience, a missing scope and a missing consent never give a storage token
    foreach ($case in @(
            @{ Name = 'the audience of another resource (ARM)'; Seed = @{ StorageAud = 'https://management.azure.com' }; Like = '*another resource*' },
            @{ Name = 'a look-alike host as audience (prefix of the real one)'; Seed = @{ StorageAud = 'https://storage.azure.com.evil.example' }; Like = '*another resource*' },
            @{ Name = 'a token without the scope user_impersonation'; Seed = @{ StorageScopes = @('Other.Scope') }; Like = '*lacks the permission user_impersonation*' },
            @{ Name = 'no consent for the storage permission (AADSTS65001)'; Seed = @{ ConsentMissing = @('Storage') }; Like = '*no consent*Storage*user_impersonation*' })) {
        $cs = New-AVDTuneSession -TempRoot $signTemp -Auth (New-AVDTuneFakeAuth -Seed $case.Seed)
        $ci = Connect-AVDTuneSession -Session $cs -TenantId $tenant -ClientId $clientId
        $why = Get-ThrownText { Get-AVDTuneAccessToken -Session $cs -Audience Storage }
        Test-Check "storage: $($case.Name): sign-in still works, no storage token kept, reason names the fix (set up again)" ($ci.Connected -and -not $cs.Tokens.ContainsKey('Storage') -and @($ci.Audiences).Count -eq 3 -and $why -like $case.Like -and $why -like "*Set up again (authorize this administrator)*" -and @($ci.Unavailable).Count -eq 1 -and (@($ci.Warnings) -join ' ') -like '*No Storage token*') "$why"
        Disconnect-AVDTuneSession $cs
    }
    $wrongTid = New-AVDTuneSession -TempRoot $signTemp -Auth (New-AVDTuneFakeAuth -Seed @{ WrongTenant = $true })
    Test-Check 'a token of another tenant still fails the whole sign-in (the optional audience does not relax the tenant check)' ($null -ne (Get-ThrownText { Connect-AVDTuneSession -Session $wrongTid -TenantId $tenant -ClientId $clientId }) -and (Test-AVDTuneSessionClear $wrongTid)) $null
    $silentAuth = New-AVDTuneFakeAuth -Seed @{ ConsentMissing = @('Storage') }
    $silent = New-AVDTuneSession -TempRoot $signTemp -Auth $silentAuth
    [void](Connect-AVDTuneSession -Session $silent -TenantId $tenant -ClientId $clientId)
    Test-Check 'an old registration without the scope: the sign-in changes nothing in the tenant (no Graph call, no consent, no registration change)' (@($silentAuth.Log | Where-Object { $_ -like 'Graph *' }).Count -eq 0 -and $silentAuth.Store.Apps.Count -eq 0 -and $silentAuth.Store.Grants.Count -eq 1) ($silentAuth.Log -join ' | ')
    Disconnect-AVDTuneSession $silent

    $s3 = New-AVDTuneSession -TempRoot $signTemp -Auth (New-AVDTuneFakeAuth -Seed @{ ConsentMissing = @('Arm') })
    $e = Get-ThrownText { Connect-AVDTuneSession -Session $s3 -TenantId $tenant -ClientId $clientId }
    Test-Check 'missing consent for Azure Service Management: names the audience and the scope, no tokens kept' ($e -like '*no consent*audience Arm*user_impersonation*' -and (Test-AVDTuneSessionClear $s3)) $e
    $s4 = New-AVDTuneSession -TempRoot $signTemp -Auth (New-AVDTuneFakeAuth -Seed @{ WrongTenant = $true })
    $e = Get-ThrownText { Connect-AVDTuneSession -Session $s4 -TenantId $tenant -ClientId $clientId }
    Test-Check 'a token of another tenant is refused, the message points to the first-run questions, nothing is kept' ($e -like '*signed in to tenant 99999999-*belongs to tenant*' -and $e -like '*first-run questions*' -and (Test-AVDTuneSessionClear $s4)) $e
    $s5 = New-AVDTuneSession -TempRoot $signTemp -Auth (New-AVDTuneFakeAuth -Seed @{ Cancel = $true })
    Test-Check 'cancelled sign-in' ((Get-ThrownText { Connect-AVDTuneSession -Session $s5 -TenantId $tenant -ClientId $clientId }) -like 'Sign-in cancelled*') $null
    $s6 = New-AVDTuneSession -TempRoot $signTemp -Auth (New-AVDTuneFakeAuth -Seed @{ NoRefreshToken = $true })
    Test-Check 'no refresh token (offline_access missing) is an error' ($null -ne (Get-ThrownText { Connect-AVDTuneSession -Session $s6 -TenantId $tenant -ClientId $clientId })) $null
    Test-Check 'the setup app of Microsoft and a non-GUID client are refused before any sign-in' ((Get-ThrownText { Connect-AVDTuneSession -Session $s5 -TenantId $tenant -ClientId '14d82eec-204b-4c2f-b7e8-296a70dab67e' }) -like '*setup app*' -and (Get-ThrownText { Connect-AVDTuneSession -Session $s5 -TenantId $tenant -ClientId 'x' }) -like '*GUID*') $null

    # ---------------------------------------------------------------- tenant from the sign-in, own app registration (issue #11)
    $otherTenant = '22222222-3333-4444-5555-666666666666'
    $n11 = 0
    $newRoot = {
        param([string]$Tenant, [string]$Client)
        $script:n11++
        $r = Join-Path $tmp "issue11-$script:n11"; [void](Initialize-AVDTuneState -Root $r)
        $x = Get-AVDTuneEnvironmentDefaults; $x.TenantId = $Tenant; $x.ClientId = $Client
        [void](Save-AVDTuneEnvironment -Root $r -Answers $x -User 'admin1')
        [void](Start-AVDTuneImageVersion -Root $r -Date ([datetime]'2026-11-15') -User 'admin1')
        $r
    }
    $q = Get-AVDTuneEnvironmentDefaults
    Test-Check 'the tenant is no first-run question and no default answer has one' (@(Get-AVDTuneQuestions | Where-Object { $_.Key -like '*Tenant*' }).Count -eq 0 -and $q.TenantId -eq '' -and (Test-AVDTuneEnvironmentAnswers $q).Errors.Count -eq 0) $null
    # discovery
    $ad = New-AVDTuneFakeAuth
    $found = Resolve-AVDTuneTenantFromDomain -Auth $ad -Domain 'Contoso.Example'
    Test-Check 'discovery: the tenant GUID comes from the issuer of the OpenID configuration of the domain' ($found -eq $tenant -and @($ad.Log) -contains 'Discover contoso.example') ($ad.Log -join ' | ')
    $badDomains = @('contoso', 'evil.example/x', 'a@b.example', '10.0.0.1', 'host.example:443', 'x..example', '-x.example', 'x.example%2f', 'login.microsoftonline.com#.example', '', ' ', ('a' * 64 + '.example'), 'x.example?y=1', 'x.example\y', 'x_y.example')
    $badOk = @($badDomains | Where-Object { (Get-ThrownText { Resolve-AVDTuneTenantFromDomain -Auth $ad -Domain $_ }) -notlike '*not a valid domain name*' })
    Test-Check 'discovery: an invalid domain is refused before any request (path, port, IP, @, %, #, ?, backslash, long label)' ($badOk.Count -eq 0 -and @($ad.Log | Where-Object { $_ -like 'Discover*' }).Count -eq 1) ($badOk -join ' | ')
    $e = Get-ThrownText { Resolve-AVDTuneTenantFromDomain -Auth (New-AVDTuneFakeAuth -Seed @{ DiscoveryOffline = $true }) -Domain 'contoso.example' }
    Test-Check 'discovery without network: readable text' ($e -like 'No connection to Microsoft sign-in*contoso.example*') $e
    $e = Get-ThrownText { Resolve-AVDTuneTenantFromDomain -Auth $ad -Domain 'unknown.example' }
    Test-Check 'discovery of a domain Microsoft does not know: readable text' ($e -like '*knows no tenant for the domain unknown.example*') $e
    $badIssuers = @('https://evil.example/11111111-2222-3333-4444-555555555555/v2.0', 'http://login.microsoftonline.com/11111111-2222-3333-4444-555555555555/v2.0', 'https://login.microsoftonline.com/common/v2.0', 'https://login.microsoftonline.com/11111111-2222-3333-4444-555555555555/v2.0/x')
    $issOk = @($badIssuers | Where-Object { (Get-ThrownText { Resolve-AVDTuneTenantFromDomain -Auth (New-AVDTuneFakeAuth -Seed @{ DiscoveryIssuer = $_ }) -Domain 'contoso.example' }) -notlike '*names no tenant AVDTune accepts*' })
    Test-Check 'discovery: an issuer that is not https://login.microsoftonline.com/<guid>/v2.0 is refused' ($issOk.Count -eq 0) ($issOk -join ' | ')

    # client ID given, no tenant: account -> discovery -> sign-in at that tenant with the login hint -> tid saved
    $r1 = & $newRoot '' $clientId
    $a1 = New-AVDTuneFakeAuth
    $res1 = Invoke-AVDTuneStartSignIn -Root $r1 -Session (New-AVDTuneSession -TempRoot $signTemp -Auth $a1) -Account 'admin.example@contoso.example' -User 'admin1'
    $e1 = Get-AVDTuneEnvironment $r1
    Test-Check 'no saved tenant: the tenant of the account domain is used, with the account as login hint' (@($a1.Log | Where-Object { $_ -like "SignIn tenant=$tenant client=$clientId hint=admin.example@contoso.example*" }).Count -eq 1 -and @($a1.Log | Where-Object { $_ -like "Refresh tenant=$tenant*" }).Count -eq 4) ($a1.Log -join ' | ')
    Test-Check 'the tid of the token is saved in environment.json with a change log entry' ($e1.SignIn.TenantId -eq $tenant -and $e1.SignIn.ClientId -eq $clientId -and @(Get-AVDTuneChangeLog -Root $r1 | Where-Object { $_.Text -like "Tenant taken from the sign-in: $tenant (account admin.example@contoso.example)" }).Count -eq 1 -and $res1.Info.TenantId -eq $tenant) (Get-AVDTuneChangeLog -Root $r1 | ConvertTo-Json -Compress)
    # tid differs from the discovery
    $r2 = & $newRoot '' $clientId
    $a2 = New-AVDTuneFakeAuth -Seed @{ Domains = @{ 'contoso.example' = $otherTenant } }
    $s2b = New-AVDTuneSession -TempRoot $signTemp -Auth $a2
    $e = Get-ThrownText { Invoke-AVDTuneStartSignIn -Root $r2 -Session $s2b -Account 'admin.example@contoso.example' -User 'admin1' }
    Test-Check 'the tid of the token must match the tenant of the discovery; nothing is saved, no token kept' ($e -like "*signed in to tenant $tenant*belongs to tenant $otherTenant*" -and (Get-AVDTuneEnvironment $r2).SignIn.TenantId -eq '' -and (Test-AVDTuneSessionClear $s2b)) $e
    # discovery fails: 'organizations'; single-tenant registration gives a readable message
    $r3 = & $newRoot '' $clientId
    $a3 = New-AVDTuneFakeAuth -Seed @{ DiscoveryOffline = $true }
    $res3 = Invoke-AVDTuneStartSignIn -Root $r3 -Session (New-AVDTuneSession -TempRoot $signTemp -Auth $a3) -Account 'admin.example@contoso.example' -User 'admin1'
    Test-Check 'discovery network error: the sign-in goes through organizations, the note says why, the tid is saved' (@($a3.Log | Where-Object { $_ -like 'SignIn tenant=organizations*' }).Count -eq 1 -and (@($res3.Notes) -join ' ') -like '*not found (No connection*organizations*' -and (Get-AVDTuneEnvironment $r3).SignIn.TenantId -eq $tenant) (@($res3.Notes) -join ' | ')
    $r4 = & $newRoot '' $clientId
    $e = Get-ThrownText { Invoke-AVDTuneStartSignIn -Root $r4 -Session (New-AVDTuneSession -TempRoot $signTemp -Auth (New-AVDTuneFakeAuth -Seed @{ SingleTenant = $true })) -User 'admin1' }
    Test-Check 'no tenant, no account, single-tenant registration: the message says to enter the account or let AVDTune create its registration' ($e -like '*limited to its own tenant*name@domain*' -and (Get-AVDTuneEnvironment $r4).SignIn.TenantId -eq '') $e
    Test-Check 'an account that is not name@domain is refused before any sign-in' ((Get-ThrownText { Invoke-AVDTuneStartSignIn -Root $r4 -Session (New-AVDTuneSession -TempRoot $signTemp -Auth $a3) -Account 'admin' }) -like '*name@domain*' -and (Get-ThrownText { Invoke-AVDTuneStartSignIn -Root $r4 -Session (New-AVDTuneSession -TempRoot $signTemp -Auth $a3) -Account 'a@evil.example/x' }) -like '*name@domain*') $null
    # saved tenant (older environment.json): GUID must match; a domain is replaced by the GUID of the sign-in
    $r5 = & $newRoot $tenant $clientId
    $a5 = New-AVDTuneFakeAuth -Seed @{ WrongTenant = $true }
    $e = Get-ThrownText { Invoke-AVDTuneStartSignIn -Root $r5 -Session (New-AVDTuneSession -TempRoot $signTemp -Auth $a5) -Account 'admin.example@contoso.example' -User 'admin1' }
    Test-Check 'saved tenant: an account of another tenant is refused with the hint to change the first-run questions; no discovery, file unchanged' ($e -like '*belongs to tenant*first-run questions*' -and @($a5.Log | Where-Object { $_ -like 'Discover*' }).Count -eq 0 -and (Get-AVDTuneEnvironment $r5).SignIn.TenantId -eq $tenant) $e
    $a5b = New-AVDTuneFakeAuth
    $res5 = Invoke-AVDTuneStartSignIn -Root $r5 -Session (New-AVDTuneSession -TempRoot $signTemp -Auth $a5b) -User 'admin1'
    Test-Check 'saved tenant that matches: sign-in at that tenant, no change log entry' ($res5.Info.Connected -and @($a5b.Log | Where-Object { $_ -like "SignIn tenant=$tenant *" }).Count -eq 1 -and @(Get-AVDTuneChangeLog -Root $r5 | Where-Object { $_.Text -like 'Tenant taken*' }).Count -eq 0) ($a5b.Log -join ' | ')
    $r6 = Join-Path $tmp 'issue11-old'; [void](Initialize-AVDTuneState -Root $r6); [void](Start-AVDTuneImageVersion -Root $r6 -Date ([datetime]'2026-11-15') -User 'admin1')
    # an environment.json of the version before #11 (tenant typed in as a domain)
    [IO.File]::WriteAllText((Join-Path $r6 'environment.json'), (@{ Schema = 1; Answers = @{ Join = 'EntraOnly'; Dc = 'None'; Identities = 'CloudOnly'; Profiles = 'AzureFiles'; AzureFilesAuth = 'EntraKerberos'; Network = @{ Endpoint = 'Private'; VNet = ''; Subnet = ''; DnsZone = 'Azure' } }; SignIn = @{ TenantId = 'contoso.example'; ClientId = $clientId }; Snapshot = @{ NamePattern = '{OsDisk}-{DD}.{MM}.{YYYY}-{N}' }; Dc = @{ Server = ''; User = ''; Pins = @{}; Discovery = $null }; Updated = '2026-11-01T00:00:00Z'; UpdatedBy = 'admin1' } | ConvertTo-Json -Depth 6))
    $old6 = Get-AVDTuneEnvironmentAnswers (Get-AVDTuneEnvironment $r6)
    Test-Check 'an environment.json with a typed-in tenant stays valid' ((Test-AVDTuneEnvironmentAnswers $old6).Errors.Count -eq 0 -and $old6.TenantId -eq 'contoso.example' -and (Get-AVDTuneStartStages -Context (New-AVDTuneStartContext) -Root $r6)[0].Status -eq 'Done') $null
    $a6 = New-AVDTuneFakeAuth
    [void](Invoke-AVDTuneStartSignIn -Root $r6 -Session (New-AVDTuneSession -TempRoot $signTemp -Auth $a6) -User 'admin1')
    Test-Check 'a saved domain: sign-in at that domain, then the tenant GUID of the token is saved (change log old -> new)' (@($a6.Log | Where-Object { $_ -like 'SignIn tenant=contoso.example *' }).Count -eq 1 -and (Get-AVDTuneEnvironment $r6).SignIn.TenantId -eq $tenant -and @(Get-AVDTuneChangeLog -Root $r6 | Where-Object { $_.Text -like "Tenant taken from the sign-in: contoso.example -> $tenant*" }).Count -eq 1) ($a6.Log -join ' | ')
    # the questions keep the tenant; only "forget" removes it
    $keep = Get-AVDTuneEnvironmentAnswers (Get-AVDTuneEnvironment $r5); $keep.TenantId = ''; $keep.VNet = 'vnet-2'
    [void](Save-AVDTuneEnvironment -Root $r5 -Answers $keep -User 'admin1')
    $kept = (Get-AVDTuneEnvironment $r5).SignIn.TenantId
    $forgot = Save-AVDTuneEnvironment -Root $r5 -Answers $keep -User 'admin1' -ForgetTenant
    Test-Check 'saving the questions keeps the saved tenant; forgetting it is a change log entry' ($kept -eq $tenant -and $forgot.Environment.SignIn.TenantId -eq '' -and @($forgot.Changes) -contains "TenantId: $tenant -> ") (@($forgot.Changes) -join ' | ')

    # no client ID: AVDTune's own app registration through the setup sign-in
    $r7 = & $newRoot '' ''
    $a7 = New-AVDTuneFakeAuth
    $res7 = Invoke-AVDTuneStartSignIn -Root $r7 -Session (New-AVDTuneSession -TempRoot $signTemp -Auth $a7) -User 'admin1' -RetryDelaySeconds 0
    $e7 = Get-AVDTuneEnvironment $r7
    $app7 = @($a7.Store.Apps)[0]
    $setupLine = @($a7.Log | Where-Object { $_ -like 'SignIn*client=setup*' })
    Test-Check 'setup sign-in: Microsoft Graph Command Line Tools at organizations with Application.ReadWrite.All and DelegatedPermissionGrant.ReadWrite.All' ($setupLine.Count -eq 1 -and $setupLine[0] -like 'SignIn tenant=organizations client=setup*' -and $setupLine[0] -like '*Application.ReadWrite.All*DelegatedPermissionGrant.ReadWrite.All*' -and $a7.Log.IndexOf($setupLine[0]) -eq 0) ($a7.Log -join ' | ')
    $def = $app7.Definition
    $graphAccess = @($def.requiredResourceAccess | Where-Object { $_.resourceAppId -eq '00000003-0000-0000-c000-000000000000' })[0]
    $armAccess = @($def.requiredResourceAccess | Where-Object { $_.resourceAppId -eq '797f4846-ba00-4fd7-ba43-dac1f8f63013' })[0]
    Test-Check "registration 'AVDTune' created: public client, redirect http://localhost only, single tenant, tag, note with date, computer and account, no secret or certificate" ($a7.Store.Apps.Count -eq 1 -and $def.displayName -eq 'AVDTune' -and (@($def.publicClient.redirectUris) -join ',') -eq 'http://localhost' -and $def.signInAudience -eq 'AzureADMyOrg' -and $def.isFallbackPublicClient -eq $false -and @($def.tags) -contains 'AVDTune' -and $def.notes -like "Created by AVDTune*Created on ????-??-?? on $env:COMPUTERNAME by admin.example@contoso.example." -and -not $def.ContainsKey('passwordCredentials') -and -not $def.ContainsKey('keyCredentials') -and -not $def.ContainsKey('web') -and -not $def.ContainsKey('spa') -and -not $def.ContainsKey('identifierUris')) ($def | ConvertTo-Json -Depth 6 -Compress)
    Test-Check 'its permissions: Graph Group.Read.All, DeviceManagementApps.Read.All, Sites.Selected, offline_access (+ openid, profile); Azure Service Management user_impersonation; Azure Storage user_impersonation; delegated only' ((@($graphAccess.resourceAccess | ForEach-Object { $_.id }) -join ',') -eq 'scope-Group.Read.All,scope-DeviceManagementApps.Read.All,scope-Sites.Selected,scope-offline_access,scope-openid,scope-profile' -and (@($armAccess.resourceAccess | ForEach-Object { $_.id }) -join ',') -eq 'scope-user_impersonation' -and @($def.requiredResourceAccess | ForEach-Object { $_.resourceAccess } | Where-Object { $_.type -ne 'Scope' }).Count -eq 0 -and @($def.requiredResourceAccess).Count -eq 3 -and (@(@($def.requiredResourceAccess | Where-Object { $_.resourceAppId -eq 'e406a681-f3d4-42a8-90b6-c2b029497af1' })[0].resourceAccess | ForEach-Object { $_.id }) -join ',') -eq 'scope-storage-user_impersonation') ($def.requiredResourceAccess | ConvertTo-Json -Depth 5 -Compress)
    $sp7 = @($a7.Store.ServicePrincipals | Where-Object { $_.appId -eq $app7.appId })
    $grants7 = @($a7.Store.Grants | Where-Object { $_.clientId -eq $sp7[0].id })
    Test-Check 'enterprise app requires an assignment; the signed-in admin (oid) is assigned with the default role' ($sp7.Count -eq 1 -and $sp7[0].appRoleAssignmentRequired -eq $true -and @($sp7[0].Assigned).Count -eq 1 -and $sp7[0].Assigned[0].principalId -eq 'oid-fake' -and $sp7[0].Assigned[0].appRoleId -eq '00000000-0000-0000-0000-000000000000' -and $sp7[0].Assigned[0].resourceId -eq $sp7[0].id) ($sp7 | ConvertTo-Json -Depth 4 -Compress)
    Test-Check 'consent only for the signed-in admin (Principal) for Graph, Azure Service Management and Azure Storage; none for the whole organization' ($grants7.Count -eq 3 -and @($grants7 | Where-Object { $_.resourceId -eq 'sp-storage-0001' -and $_.scope -eq 'user_impersonation' }).Count -eq 1 -and @($grants7 | Where-Object { $_.consentType -ne 'Principal' -or $_.principalId -ne 'oid-fake' }).Count -eq 0 -and @($grants7 | Where-Object { $_.resourceId -eq 'sp-graph-0001' -and $_.scope -eq 'Group.Read.All DeviceManagementApps.Read.All Sites.Selected offline_access openid profile' }).Count -eq 1 -and @($grants7 | Where-Object { $_.resourceId -eq 'sp-arm-0001' -and $_.scope -eq 'user_impersonation' }).Count -eq 1 -and @($a7.Store.Grants | Where-Object { $_.consentType -eq 'AllPrincipals' }).Count -eq 0) ($grants7 | ConvertTo-Json -Compress)
    $cliGrant = @($a7.Store.Grants | Where-Object { $_.id -eq 'grant-cli-own' })[0]
    Test-Check "the setup permissions are taken out of the admin's own consent for Graph CLI Tools again; the rest and the grant stay" ($cliGrant -and $cliGrant.scope -eq 'openid profile User.Read' -and (@($res7.Notes) -join ' ') -like "*taken out of your own consent for 'Microsoft Graph Command Line Tools'*") $cliGrant.scope
    $normal7 = @($a7.Log | Where-Object { $_ -like "SignIn tenant=$tenant client=$($app7.appId) hint=admin.example@contoso.example*" })
    Test-Check 'client ID and tenant (tid of the setup token) saved, then the normal sign-in with the new app at that tenant and the setup account as hint' ($e7.SignIn.ClientId -eq $app7.appId -and $e7.SignIn.TenantId -eq $tenant -and $normal7.Count -eq 1 -and $res7.Info.Connected -and @(Get-AVDTuneChangeLog -Root $r7 | Where-Object { $_.Text -like "Client ID of AVDTune's own app registration saved: $($app7.appId)" }).Count -eq 1 -and @(Get-AVDTuneChangeLog -Root $r7 | Where-Object { $_.Text -like "Tenant taken from the sign-in: $tenant*" }).Count -eq 1) ($a7.Log -join ' | ')
    Test-Check "the note on the setup consent says what AVDTune removes and what stays (organization-wide consent)" ($res7.ConsentNote -like "*Microsoft Graph Command Line Tools*takes these two out of your own consent*grant itself stay*whole organization*Update-MgOauth2PermissionGrant*" -and $res7.ConsentNote -notlike '*Remove-MgOauth2PermissionGrant*' -and (@($res7.Notes) -join ' ') -like "*App registration 'AVDTune' created*") $res7.ConsentNote
    Test-Check 'the setup token is nowhere in the log, the notes or environment.json' (($a7.Log -join ' ') -notmatch 'eyJ|fake-refresh' -and (@($res7.Notes) -join ' ') -notmatch 'eyJ' -and [IO.File]::ReadAllText((Join-Path $r7 'environment.json')) -notmatch 'eyJ|refresh') $null
    # no reuse by name: without a saved client ID a new registration is always created, existing ones are only named
    $again = Get-AVDTuneEnvironmentAnswers (Get-AVDTuneEnvironment $r7); $again.ClientId = ''
    [void](Save-AVDTuneEnvironment -Root $r7 -Answers $again -User 'admin1')
    $a7.Log.Clear()
    $res7b = Invoke-AVDTuneStartSignIn -Root $r7 -Session (New-AVDTuneSession -TempRoot $signTemp -Auth $a7) -User 'admin1' -RetryDelaySeconds 0
    Test-Check "without a saved client ID a registration named 'AVDTune' is never taken over (even the admin's own): a new one, the old one named in a note" ($a7.Store.Apps.Count -eq 2 -and -not $app7.ContainsKey('Patched') -and (Get-AVDTuneEnvironment $r7).SignIn.ClientId -ne $app7.appId -and (@($res7b.Notes) -join ' ') -like "*1 other app registration(s) named 'AVDTune'*$($app7.appId)*not use them*") (@($res7b.Notes) -join ' | ')
    # consent phishing: an attacker's 'AVDTune' with a secret, web redirect, multi-tenant, admin as only owner
    $evil = @{ id = 'app-evil'; appId = '77777777-0000-0000-0000-000000000001'; displayName = 'AVDTune'; tags = @('AVDTune'); publicClient = @{ redirectUris = @('http://localhost') }; signInAudience = 'AzureADMultipleOrgs'
        passwordCredentials = @(@{ keyId = 'k1' }); keyCredentials = @(); identifierUris = @(); web = @{ redirectUris = @('https://evil.example/cb') }; spa = @{ redirectUris = @() }; owners = @('oid-fake'); Federated = @() }
    $a8 = New-AVDTuneFakeAuth -Seed @{ Apps = [System.Collections.ArrayList]@($evil) }
    $r8 = & $newRoot '' ''
    $res8 = Invoke-AVDTuneStartSignIn -Root $r8 -Session (New-AVDTuneSession -TempRoot $signTemp -Auth $a8) -User 'admin1' -RetryDelaySeconds 0
    $evilSp = @($a8.Store.ServicePrincipals | Where-Object { $_.appId -eq $evil.appId })
    Test-Check "an attacker's 'AVDTune' (secret, web redirect, multi-tenant, admin as only owner) gets nothing: not patched, no consent, no assignment; a new one is created and the other one named" ($a8.Store.Apps.Count -eq 2 -and -not $evil.ContainsKey('Patched') -and $evilSp.Count -eq 0 -and @($a8.Log | Where-Object { $_ -like "*app-evil*" -and $_ -notlike 'Graph GET*' }).Count -eq 0 -and (Get-AVDTuneEnvironment $r8).SignIn.ClientId -ne $evil.appId -and (@($res8.Notes) -join ' ') -like "*$($evil.appId)*may be an attempt to collect your consent*") (@($res8.Notes) -join ' | ')
    # a saved client ID: checked before it is used again (-Setup), replaced when it is not safe
    $badApps = [ordered]@{
        'client secret'           = @{ passwordCredentials = @(@{ keyId = 'k' }) }
        'certificate'             = @{ keyCredentials = @(@{ keyId = 'c' }) }
        'federated credential'    = @{ Federated = @(@{ name = 'gh' }) }
        'web redirects'           = @{ web = @{ redirectUris = @('https://evil.example/cb') } }
        'single-page-app'         = @{ spa = @{ redirectUris = @('https://evil.example/spa') } }
        'not limited to this'     = @{ signInAudience = 'AzureADandPersonalMicrosoftAccount' }
        'public client redirects' = @{ publicClient = @{ redirectUris = @('http://localhost', 'ms-appx-web://x') } }
        'exposes an API'          = @{ identifierUris = @('api://x') }
    }
    $badOk = @()
    foreach ($why in $badApps.Keys) {
        $saved = @{ id = 'app-saved'; appId = '88888888-0000-0000-0000-000000000001'; displayName = 'AVDTune'; tags = @('AVDTune'); publicClient = @{ redirectUris = @('http://localhost') }; signInAudience = 'AzureADMyOrg'
            passwordCredentials = @(); keyCredentials = @(); identifierUris = @(); web = @{ redirectUris = @() }; spa = @{ redirectUris = @() }; owners = @('oid-fake'); Federated = @() }
        foreach ($k in $badApps[$why].Keys) { $saved[$k] = $badApps[$why][$k] }
        $ab = New-AVDTuneFakeAuth -Seed @{ Apps = [System.Collections.ArrayList]@($saved) }
        $rb = & $newRoot '' $saved.appId
        $resb = Invoke-AVDTuneStartSignIn -Root $rb -Session (New-AVDTuneSession -TempRoot $signTemp -Auth $ab) -User 'admin1' -RetryDelaySeconds 0 -Setup
        if (-not ((Get-AVDTuneEnvironment $rb).SignIn.ClientId -ne $saved.appId -and $ab.Store.Apps.Count -eq 2 -and -not $saved.ContainsKey('Patched') -and (@($resb.Notes) -join ' ') -like "*saved app registration $($saved.appId) is not used*$why*")) { $badOk += $why }
    }
    Test-Check 'a saved client ID with a secret, certificate, federated credential, web/SPA redirect, other audience, other public redirect or an API is not used: warning and a new registration' ($badOk.Count -eq 0) ($badOk -join ', ')
    # a clean saved registration: reused by -Setup (another administrator authorizes himself), nothing doubled
    $clean = @{ id = 'app-clean'; appId = '88888888-0000-0000-0000-000000000002'; displayName = 'AVDTune'; tags = @('AVDTune'); publicClient = @{ redirectUris = @('http://localhost') }; signInAudience = 'AzureADMyOrg'
        passwordCredentials = @(); keyCredentials = @(); identifierUris = @(); web = @{ redirectUris = @() }; spa = @{ redirectUris = @() }; owners = @('oid-other'); Federated = @() }
    $ac = New-AVDTuneFakeAuth -Seed @{ Apps = [System.Collections.ArrayList]@($clean) }
    $rc = & $newRoot $tenant $clean.appId
    $resc = Invoke-AVDTuneStartSignIn -Root $rc -Session (New-AVDTuneSession -TempRoot $signTemp -Auth $ac) -User 'admin1' -RetryDelaySeconds 0 -Setup
    $spc = @($ac.Store.ServicePrincipals | Where-Object { $_.appId -eq $clean.appId })[0]
    Test-Check 'set up again with a clean saved registration: checked, kept, the signed-in admin assigned and consented (Principal), no new registration' ($ac.Store.Apps.Count -eq 1 -and $clean.Patched -and (Get-AVDTuneEnvironment $rc).SignIn.ClientId -eq $clean.appId -and $spc.appRoleAssignmentRequired -eq $true -and @($spc.Assigned | Where-Object { $_.principalId -eq 'oid-fake' }).Count -eq 1 -and @($ac.Store.Grants | Where-Object { $_.clientId -eq $spc.id -and $_.consentType -eq 'Principal' -and $_.principalId -eq 'oid-fake' }).Count -eq 3 -and (@($resc.Notes) -join ' ') -like '*was checked*is used*' -and $resc.Info.Connected) (@($resc.Notes) -join ' | ')
    Test-Check 'set up again retrofits an older registration (saved without the Storage permission): the permission is added to it and the admin consents to it; the sign-in then has a storage token' (@($clean.Definition.requiredResourceAccess | Where-Object { $_.resourceAppId -eq 'e406a681-f3d4-42a8-90b6-c2b029497af1' }).Count -eq 1 -and @($ac.Store.Grants | Where-Object { $_.clientId -eq $spc.id -and $_.resourceId -eq 'sp-storage-0001' -and $_.scope -eq 'user_impersonation' }).Count -eq 1 -and @($resc.Info.Audiences | Where-Object Audience -eq 'Storage').Count -eq 1) (@($resc.Notes) -join ' | ')
    $ac.Log.Clear()
    [void](Invoke-AVDTuneStartSignIn -Root $rc -Session (New-AVDTuneSession -TempRoot $signTemp -Auth $ac) -User 'admin1' -RetryDelaySeconds 0 -Setup)
    Test-Check 'a second setup run assigns and grants nothing twice' (@($spc.Assigned).Count -eq 1 -and @($ac.Store.Grants | Where-Object { $_.clientId -eq $spc.id }).Count -eq 3 -and @($ac.Log | Where-Object { $_ -like 'Graph POST*' }).Count -eq 0) ($ac.Log -join ' | ')
    # Graph CLI Tools consented for the whole organization: not changed, named
    $ao = New-AVDTuneFakeAuth -Seed @{ CliOrgGrant = $true }
    $ro = & $newRoot '' ''
    $reso = Invoke-AVDTuneStartSignIn -Root $ro -Session (New-AVDTuneSession -TempRoot $signTemp -Auth $ao) -User 'admin1' -RetryDelaySeconds 0
    Test-Check 'an organization-wide consent of Graph CLI Tools is not changed (never a whole grant deleted), but named' (@($ao.Store.Grants | Where-Object { $_.id -eq 'grant-cli-org' })[0].scope -eq 'User.Read Application.ReadWrite.All' -and (@($reso.Notes) -join ' ') -like '*for the whole organization. AVDTune does not change that consent*' -and @($ao.Log | Where-Object { $_ -like 'Graph PATCH /v1.0/oauth2PermissionGrants/grant-cli-org*' }).Count -eq 0) (@($reso.Notes) -join ' | ')
    # missing roles, missing consent, retries, Azure Service Management missing
    $r9 = & $newRoot '' ''
    $e = Get-ThrownText { Invoke-AVDTuneStartSignIn -Root $r9 -Session (New-AVDTuneSession -TempRoot $signTemp -Auth (New-AVDTuneFakeAuth -Seed @{ AppForbidden = $true })) -User 'admin1' -RetryDelaySeconds 0 }
    Test-Check 'no right to create app registrations: the message names the step and the roles; nothing saved' ($e -like 'Your account may not do this: create the app registration*403*Application Administrator or Cloud Application Administrator*' -and (Get-AVDTuneEnvironment $r9).SignIn.ClientId -eq '') $e
    $af = New-AVDTuneFakeAuth -Seed @{ GrantForbidden = $true }
    $e = Get-ThrownText { Invoke-AVDTuneStartSignIn -Root $r9 -Session (New-AVDTuneSession -TempRoot $signTemp -Auth $af) -User 'admin1' -RetryDelaySeconds 0 }
    Test-Check 'no right to grant the consent: the message names Privileged Role Administrator; nothing saved; the Graph CLI scopes are still taken out' ($e -like '*grant the consent*Privileged Role Administrator*' -and (Get-AVDTuneEnvironment $r9).SignIn.ClientId -eq '' -and @($af.Store.Grants | Where-Object { $_.id -eq 'grant-cli-own' })[0].scope -eq 'openid profile User.Read') $e
    $e = Get-ThrownText { Invoke-AVDTuneStartSignIn -Root $r9 -Session (New-AVDTuneSession -TempRoot $signTemp -Auth (New-AVDTuneFakeAuth -Seed @{ AssignForbidden = $true })) -User 'admin1' -RetryDelaySeconds 0 }
    Test-Check 'no right to assign the account: readable text with the roles' ($e -like 'Your account may not do this: assign your account to the enterprise app*Application Administrator*') $e
    $e = Get-ThrownText { Invoke-AVDTuneStartSignIn -Root $r9 -Session (New-AVDTuneSession -TempRoot $signTemp -Auth (New-AVDTuneFakeAuth -Seed @{ SetupNoConsent = $true })) -User 'admin1' -RetryDelaySeconds 0 }
    Test-Check 'setup sign-in without the consent for Application.ReadWrite.All: readable text, no Graph call' ($e -like '*no consent for Application.ReadWrite.All*' -and (Get-AVDTuneEnvironment $r9).SignIn.ClientId -eq '') $e
    $e = Get-ThrownText { Invoke-AVDTuneStartSignIn -Root $r9 -Session (New-AVDTuneSession -TempRoot $signTemp -Auth (New-AVDTuneFakeAuth -Seed @{ GraphOffline = $true })) -User 'admin1' -RetryDelaySeconds 0 }
    Test-Check 'setup without a connection to Graph: readable text' ($e -like 'No connection to Microsoft Graph*') $e
    $e = Get-ThrownText { Invoke-AVDTuneStartSignIn -Root $r9 -Session (New-AVDTuneSession -TempRoot $signTemp -Auth (New-AVDTuneFakeAuth -Seed @{ Cancel = $true })) -User 'admin1' }
    Test-Check 'setup sign-in cancelled: readable text' ($e -like 'Setup sign-in (Microsoft Graph Command Line Tools): Sign-in cancelled*') $e
    $a10 = New-AVDTuneFakeAuth -Seed @{ SpCreateFailures = 2; ArmSpMissing = $true }
    $res10 = Invoke-AVDTuneStartSignIn -Root $r9 -Session (New-AVDTuneSession -TempRoot $signTemp -Auth $a10) -User 'admin1' -RetryDelaySeconds 0
    Test-Check 'the new enterprise app is retried while Graph does not know the registration yet; Azure Service Management is added when missing' ($res10.Info.Connected -and @($a10.Log | Where-Object { $_ -eq 'Graph POST /v1.0/servicePrincipals' }).Count -eq 4 -and (@($res10.Notes) -join ' ') -like '*Azure Service Management was added*') ($a10.Log -join ' | ')
    $r11 = & $newRoot $tenant ''
    $e = Get-ThrownText { Invoke-AVDTuneStartSignIn -Root $r11 -Session (New-AVDTuneSession -TempRoot $signTemp -Auth (New-AVDTuneFakeAuth -Seed @{ WrongTenant = $true })) -User 'admin1' -RetryDelaySeconds 0 }
    Test-Check 'setup with a saved tenant: an admin of another tenant is refused before any Graph call' ($e -like '*belongs to tenant*' -and (Get-AVDTuneEnvironment $r11).SignIn.ClientId -eq '') $e
    # client ID: a strict GUID (review #11, point 4)
    $looseOk = @('------------------------------------', 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', '66666666-7777-8888-9999-00000000000-', '6666666677778888-9999-000000000000--' | Where-Object { $x = Get-AVDTuneEnvironmentDefaults; $x.ClientId = $_; (Test-AVDTuneEnvironmentAnswers $x).Errors -notcontains 'The client ID must be a GUID.' })
    Test-Check 'the client ID of the questions must be a real GUID (36 hyphens or hex without the 8-4-4-4-12 form are refused)' ($looseOk.Count -eq 0) ($looseOk -join ', ')
    $ag = New-AVDTuneFakeAuth
    $e = Get-ThrownText { Install-AVDTuneAppRegistration -Auth $ag -ExistingClientId "x' or appId ne '0" -TempRoot $signTemp -RetryDelaySeconds 0 }
    Test-Check 'a saved client ID that is not a GUID stops the setup before any sign-in or Graph call (it would go into an OData filter)' ($e -like '*saved client ID is not a GUID*' -and $ag.Log.Count -eq 0) "$e | $($ag.Log -join ' | ')"
    $e = ConvertTo-AVDTuneAuthError -Message "Sign-in failed: AADSTS50105: Your administrator has configured the application AVDTune to block users unless they are specifically granted ('assigned') access."
    Test-Check 'not assigned (AADSTS50105): readable text with the way to get assigned (Set up again, or an administrator assigns)' ($e -like "Your account is not assigned to AVDTune's app registration*'Set up again (authorize this administrator)'*Users and groups*") $e
    # Graph only through the adapter, only graph.microsoft.com
    $sessSrc = [IO.File]::ReadAllText((Join-Path $repo 'Modules\AVDTune.Session.psm1'))
    $hosts = @([regex]::Matches($sessSrc, 'https?://(?>([A-Za-z0-9.-]+))(?!\\)') | ForEach-Object { $_.Groups[1].Value.TrimEnd('.') } | Sort-Object -Unique)
    Test-Check 'the session module talks to graph.microsoft.com, login.microsoftonline.com and names management.azure.com and storage.azure.com only; no Invoke-RestMethod or WebRequest of its own' (@($hosts | Where-Object { $_ -notin 'graph.microsoft.com', 'login.microsoftonline.com', 'management.azure.com', 'storage.azure.com', 'localhost' }).Count -eq 0 -and $sessSrc -notmatch 'Invoke-RestMethod|Invoke-WebRequest|WebClient') ($hosts -join ',')
    $real = New-AVDTuneAuthAdapter -CacheFolder (Join-Path $tmp 'wv2-unused')
    $refused = @(
        (& $real.Graph 'GET' '/beta/applications' 'x' $null), (& $real.Graph 'DELETE' '/v1.0/applications/x' 'x' $null), (& $real.Graph 'GET' '/v1.0/../x' 'x' $null),
        (& $real.Graph 'GET' '/v1.0/x#y' 'x' $null), (& $real.Graph 'GET' '//evil.example/v1.0/x' 'x' $null), (& $real.Graph 'GET' '/v1.0/x@evil.example' 'x' $null),
        (& $real.Discover 'evil.example/x'), (& $real.Discover 'evil.example:8443'), (& $real.Discover '10.0.0.1'))
    Test-Check 'real adapter: Graph paths outside /v1.0, other methods and odd domains are refused without a request' (@($refused | Where-Object { $_.Status -ne 0 -or $_.Error -notlike 'Refused*' }).Count -eq 0) ($refused | ConvertTo-Json -Compress)

    # ---------------------------------------------------------------- snapshot gate
    $machine = New-AVDTuneFakeMachine
    $vm = Get-AVDTuneVmIdentity $machine
    Test-Check 'VM identity from the instance metadata: subscription, resource group, VM, managed OS disk' ($vm.Available -and $vm.VmName -eq 'gm-test01' -and $vm.ResourceGroup -eq 'rg-example' -and $vm.OsDiskId -like '/subscriptions/*/disks/gm-test01_osdisk' -and $vm.SubscriptionId -match '^[0-9a-f-]{36}$') ($vm | ConvertTo-Json -Compress)
    $noAzure = Get-AVDTuneVmIdentity (New-AVDTuneFakeMachine -Seed @{ Imds = $null })
    Test-Check 'outside Azure: not available with a reason' (-not $noAzure.Available -and $noAzure.Problem -like '*not an Azure VM*') $null
    $unmanaged = Get-AVDTuneVmIdentity (New-AVDTuneFakeMachine -Seed @{ Imds = [pscustomobject]@{ compute = [pscustomobject]@{ name = 'x'; resourceGroupName = 'rg'; subscriptionId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'; storageProfile = [pscustomobject]@{ osDisk = [pscustomobject]@{ name = 'd' } } } } })
    Test-Check 'an unmanaged OS disk is refused with a reason' (-not $unmanaged.Available -and $unmanaged.Problem -like '*managed disk*') $null
    # snapshot name pattern per environment (user decision): default <OS disk>-DD.MM.YYYY-N, N = next free number of that day
    $day = [datetime]'2026-11-15 14:07'
    Test-Check 'default pattern is {OsDisk}-{DD}.{MM}.{YYYY}-{N}' ((Get-AVDTuneDefaultSnapshotNamePattern) -eq '{OsDisk}-{DD}.{MM}.{YYYY}-{N}') $null
    $name = Get-AVDTuneSnapshotName -OsDiskName 'gm-test01_osdisk' -At $day
    Test-Check 'snapshot name without snapshots of that day: <OS disk>-15.11.2026-1' ($name -eq 'gm-test01_osdisk-15.11.2026-1') $name
    $name = Get-AVDTuneSnapshotName -OsDiskName 'gm-test01_osdisk' -At $day -ExistingNames @('gm-test01_osdisk-15.11.2026-1', 'GM-TEST01_OSDISK-15.11.2026-3', 'gm-test01_osdisk-14.11.2026-7', 'other-15.11.2026-9')
    Test-Check 'the counter is the next free number of that day (other days and disks do not count)' ($name -eq 'gm-test01_osdisk-15.11.2026-4') $name
    $name = Get-AVDTuneSnapshotName -Pattern '{VM}-{ImageVersion}-{YYYY}{MM}{DD}-{N}' -OsDiskName 'd' -VmName 'gm-test01' -ImageVersion '2026.11.001' -At $day
    Test-Check 'an own pattern with VM and image version' ($name -eq 'gm-test01-2026.11.001-20261115-1') $name
    Test-Check 'patterns without {N}, with characters Azure does not allow or unknown tokens are refused' ((Test-AVDTuneSnapshotNamePattern '{OsDisk}-{DD}') -like '*{N}*' -and (Test-AVDTuneSnapshotNamePattern '{OsDisk} {N}') -like '*not allow*' -and (Test-AVDTuneSnapshotNamePattern '{Disk}-{N}') -like '*not allow*' -and -not (Test-AVDTuneSnapshotNamePattern '{OsDisk}-{DD}.{MM}.{YYYY}-{N}')) $null
    Test-Check 'a name longer than 80 characters is refused with a readable text' ((Get-ThrownText { Get-AVDTuneSnapshotName -OsDiskName ('d' * 75) -At $day }) -like '*80 characters*') $null
    Test-Check 'a pattern with {ImageVersion} needs an image version' ((Get-ThrownText { Get-AVDTuneSnapshotName -Pattern '{ImageVersion}-{N}' -OsDiskName 'x' -ImageVersion 'none' -At $day }) -like '*image version*') $null
    $pa = Get-AVDTuneEnvironmentAnswers (Get-AVDTuneEnvironment $tmp); $pa.SnapshotNamePattern = 'snap {N}'
    Test-Check 'the first-run questions refuse a bad name pattern' (@((Test-AVDTuneEnvironmentAnswers $pa).Errors | Where-Object { $_ -like '*pattern*' }).Count -eq 1) $null
    $pa.SnapshotNamePattern = '{OsDisk}-before-{YYYY}{MM}{DD}-{N}'
    [void](Save-AVDTuneEnvironment -Root $tmp -Answers $pa -User 'admin1')
    Test-Check 'the name pattern is saved per environment in environment.json (Snapshot.NamePattern)' ((Get-AVDTuneEnvironment $tmp).Snapshot.NamePattern -eq '{OsDisk}-before-{YYYY}{MM}{DD}-{N}' -and (Get-AVDTuneEnvironmentAnswers (Get-AVDTuneEnvironment $tmp)).SnapshotNamePattern -eq '{OsDisk}-before-{YYYY}{MM}{DD}-{N}') $null
    $pa.SnapshotNamePattern = Get-AVDTuneDefaultSnapshotNamePattern
    [void](Save-AVDTuneEnvironment -Root $tmp -Answers $pa -User 'admin1')

    $now = [datetime]'2026-11-15 14:30'
    $armToken = 'fake-arm-token-value'
    $arm = New-AVDTuneFakeArm -Seed @{ Snapshots = @(
            @{ Name = 'gm-test01_osdisk-30.10.2026-1'; Created = [datetime]'2026-10-30 09:00'; Tags = @{ CreatedWith = 'AVDTune'; ImageVersion = '2026.10.001' } }
            @{ Name = 'other-disk-snap'; Created = [datetime]'2026-11-15 08:00'; Source = '/subscriptions/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/resourceGroups/rg-example/providers/Microsoft.Compute/disks/another_disk' }) }
    Test-Check 'no change by AVDTune recorded yet: no last change' ($null -eq (Get-AVDTuneLastChange -Root $tmp)) (Get-AVDTuneLastChange -Root $tmp)
    $list = @(Get-AVDTuneOsDiskSnapshots -Arm $arm -Token $armToken -Vm $vm -LastChange (Get-AVDTuneLastChange -Root $tmp))
    Test-Check 'snapshots of this OS disk only; the one of another disk is ignored' ($list.Count -eq 1 -and $list[0].Name -like '*30.10.2026*' -and $list[0].ByAVDTune) ($list | ForEach-Object Name)
    $gate = Get-AVDTuneGateStatus -Vm $vm -Snapshots $list -Confirmed $false
    Test-Check 'without a recorded change any finished snapshot counts, also an old one ("from today" is gone)' ($gate.Status -eq 'SnapshotReady' -and $gate.Chosen.Name -like '*30.10.2026*') $gate.Status
    [void](Set-AVDTuneState -Root $tmp -Values @{ LastChange = ([datetime]'2026-11-01 10:00').ToString('o') })
    $last = Get-AVDTuneLastChange -Root $tmp
    $list = @(Get-AVDTuneOsDiskSnapshots -Arm $arm -Token $armToken -Vm $vm -LastChange $last)
    $gate = Get-AVDTuneGateStatus -Vm $vm -Snapshots $list -Confirmed $false -LastChange $last
    Test-Check 'a snapshot older than the last change of AVDTune does not count: NoValidSnapshot' ($last -eq [datetime]'2026-11-01 10:00' -and -not $list[0].Valid -and $gate.Status -eq 'NoValidSnapshot' -and -not $gate.Chosen -and $gate.Detail -like '*2026-11-01 10:00*') "$last $($gate.Status) $($gate.Detail)"
    $forged = $list[0].PSObject.Copy(); $forged.Valid = $true
    Test-Check 'attack: a snapshot older than the last change cannot be confirmed, even when the caller says it is valid' ((Get-ThrownText { Confirm-AVDTuneSnapshotGate -Root $tmp -Snapshot $forged -TypedName 'Alex Example' -ImageVersion '2026.11.001' -Machine $machine }) -like '*older than the last change*' -and -not (Test-AVDTuneWriteAllowed)) $null
    Test-Check 'outside Azure: gate status NoVm' ((Get-AVDTuneGateStatus -Vm $noAzure -Snapshots @() -Confirmed $false).Status -eq 'NoVm') $null

    $started = Start-AVDTuneSnapshot -Arm $arm -Token $armToken -Vm $vm -ImageVersion '2026.11.001' -User 'Alex Example' -At $now -NamePattern (Get-AVDTuneEnvironmentAnswers (Get-AVDTuneEnvironment $tmp)).SnapshotNamePattern -ExistingNames @($list | ForEach-Object Name)
    $put = $arm.Store.LastPut
    Test-Check 'snapshot request: incremental, copy of the OS disk, tags image version and user, in the disk region' ($put.properties.incremental -eq $true -and $put.properties.creationData.createOption -eq 'Copy' -and $put.properties.creationData.sourceResourceId -eq $vm.OsDiskId -and $put.tags.ImageVersion -eq '2026.11.001' -and $put.tags.CreatedBy -eq 'Alex Example' -and $put.tags.CreatedWith -eq 'AVDTune' -and $put.location -eq 'westeurope') ($put | ConvertTo-Json -Compress -Depth 5)
    Test-Check 'the snapshot is named by the pattern of the environment and starts as Creating' ($started.Name -eq 'gm-test01_osdisk-15.11.2026-1' -and $started.State -eq 'Creating') ($started | ConvertTo-Json -Compress)
    Test-Check 'a snapshot that is still being created does not unlock the gate' (@(Get-AVDTuneOsDiskSnapshots -Arm $arm -Token $armToken -Vm $vm -LastChange $last | Where-Object Valid).Count -eq 0) $null
    $ready = Wait-AVDTuneSnapshot -Arm $arm -Token $armToken -Id $started.Id -PollSeconds 0
    Test-Check 'polling until Succeeded' ($ready.State -eq 'Succeeded') $ready.State
    $list = @(Get-AVDTuneOsDiskSnapshots -Arm $arm -Token $armToken -Vm $vm -LastChange $last)
    $gate = Get-AVDTuneGateStatus -Vm $vm -Snapshots $list -Confirmed $false -LastChange $last
    Test-Check 'with a finished snapshot newer than the last change the gate waits for the confirmation' ($gate.Status -eq 'SnapshotReady' -and $gate.Chosen.Name -eq $started.Name -and $gate.Chosen.ByAVDTune) $gate.Status
    Test-Check 'the next snapshot of the same day gets number 2' ((Get-AVDTuneSnapshotName -OsDiskName 'gm-test01_osdisk' -At $now -ExistingNames @($list | ForEach-Object Name)) -eq 'gm-test01_osdisk-15.11.2026-2') $null
    Test-Check 'the confirmation text is the one of the plan' ((Get-AVDTuneGateText) -eq 'Ich bestaetige, dass vor diesem Lauf ein Snapshot des Golden Masters erstellt wurde und ein Rollback moeglich ist.') $null

    # confirmation: first and last name, not matched against the sign-in (shared admin accounts)
    Test-Check 'attack: a name with one word (or nothing, or initials) does not count' (-not (Test-AVDTuneConfirmationName -Typed 'Alex').Ok -and -not (Test-AVDTuneConfirmationName -Typed '').Ok -and -not (Test-AVDTuneConfirmationName -Typed 'A. E.').Ok) $null
    Test-Check 'first and last name count, whatever account is signed in (also with accents and a double name)' ((Test-AVDTuneConfirmationName -Typed '  max   mustermann ').Ok -and (Test-AVDTuneConfirmationName -Typed ('Ren' + [char]0xE9 + ' M' + [char]0xFC + 'ller-Lang')).Ok) $null
    Test-Check 'one word does not open the gate' ($null -ne (Get-ThrownText { Confirm-AVDTuneSnapshotGate -Root $tmp -Snapshot $gate.Chosen -TypedName 'Alex' -ImageVersion '2026.11.001' -Machine $machine }) -and -not (Test-AVDTuneWriteAllowed)) $null
    $stepRan = New-AVDTuneStep -Id 'setup.gatetest' -Section Setup -Title 'Gate test' -Test { param($m) @{ Compliant = ((& $m.RegGet 'HKLM:\SOFTWARE\AVDTuneGate' 'V') -eq 1); State = $null } } -Apply { param($m) & $m.RegSet 'HKLM:\SOFTWARE\AVDTuneGate' 'V' 1 'DWord' }
    Test-Check 'read only without the confirmation: a change is refused, the machine is untouched' (($null -ne (Get-ThrownText { Invoke-AVDTuneStep -Step $stepRan -Machine $machine -Mode Apply })) -and $machine.Log.Count -eq 0) $null
    Test-Check 'a dry run still works while read only' ((Invoke-AVDTuneStep -Step $stepRan -Machine $machine -Mode Apply -WhatIf).Status -eq 'WhatIf') $null
    $logBefore = @(Get-AVDTuneChangeLog -Root $tmp).Count
    $record = Confirm-AVDTuneSnapshotGate -Root $tmp -Snapshot $gate.Chosen -TypedName 'Max  Mustermann' -SignedInAccount 'admin.shared@contoso.example' -WindowsAccount 'GM-TEST01\localadmin' -ImageVersion '2026.11.001' -Machine $machine
    Test-Check 'confirmation opens the gate in memory' ((Test-AVDTuneWriteAllowed) -and (Get-AVDTuneWriteGate).SnapshotId -eq $started.Id -and (Get-AVDTuneWriteGate).ConfirmedBy -eq 'Max Mustermann') $null
    $st = Get-AVDTuneState $tmp
    Test-Check 'state.json records typed name, Microsoft account, Windows account, time, snapshot ID, created by AVDTune' ($st.SnapshotGate.SnapshotName -eq $started.Name -and $st.SnapshotGate.SnapshotId -eq $started.Id -and $st.SnapshotGate.CreatedByAVDTune -eq $true -and $st.SnapshotGate.ConfirmedBy -eq 'Max Mustermann' -and $st.SnapshotGate.SignedInAccount -eq 'admin.shared@contoso.example' -and $st.SnapshotGate.WindowsAccount -eq 'GM-TEST01\localadmin' -and $st.SnapshotGate.ConfirmedAt -and $st.SnapshotGate.Text -like 'Ich bestaetige*') ($st.SnapshotGate | ConvertTo-Json -Compress)
    $cl = @(Get-AVDTuneChangeLog -Root $tmp)
    $entry = $cl | Where-Object { $_.Category -eq 'Snapshot' } | Select-Object -First 1
    Test-Check 'the change log entry has the typed name with both accounts, time, snapshot ID and "created by AVDTune: yes"' ($cl.Count -eq $logBefore + 1 -and $entry.SnapshotId -eq $started.Id -and $entry.Text -like "*$($started.Name)*" -and $entry.Text -like '*confirmed by Max Mustermann (Microsoft account admin.shared@contoso.example, Windows account GM-TEST01\localadmin)*' -and $entry.User -eq 'Max Mustermann' -and $entry.Text -like '*created by AVDTune: yes*' -and $entry.Text -match '\d{4}-\d{2}-\d{2} \d{2}:\d{2}') ($entry | ConvertTo-Json -Compress)
    Test-Check 'the confirmation itself is no change of the master (last change unchanged)' ((Get-AVDTuneLastChange -Root $tmp) -eq $last) (Get-AVDTuneLastChange -Root $tmp)
    $catalog = @($stepRan)
    $run = Invoke-AVDTune -Plan ([pscustomobject]@{ Name = 'gate'; Steps = @('setup.gatetest') }) -Catalog $catalog -Machine $machine -Root $tmp -User 'admin1' -SnapshotId $started.Id
    Test-Check 'a change works after the confirmation' ($run.Results[0].Status -eq 'Changed') $run.Results[0].Status
    $last2 = Get-AVDTuneLastChange -Root $tmp
    $list2 = @(Get-AVDTuneOsDiskSnapshots -Arm $arm -Token $armToken -Vm $vm -LastChange $last2)
    Test-Check 'after a change by AVDTune the confirmed snapshot no longer counts for the next start (state.json LastChange)' ($last2 -gt $last -and (Get-AVDTuneState $tmp).LastChange -and @($list2 | Where-Object Valid).Count -eq 0) "$last2"
    $stages = Get-AVDTuneStartStages -Context (New-AVDTuneStartContext) -Root $tmp
    Test-Check 'the snapshot stage shows Done with the name of the confirming person' (($stages | Where-Object Id -eq 'Snapshot').Status -eq 'Done' -and ($stages | Where-Object Id -eq 'Snapshot').Detail -like '*Max Mustermann*') $null
    Close-AVDTuneWriteGate
    Test-Check 'a new start is closed again (the gate is memory only)' (-not (Test-AVDTuneWriteAllowed)) $null
    Test-Check 'Get-AVDTuneLastChange also reads run records and automatic change log entries' (@(Get-AVDTuneRun -Root $tmp | Where-Object { $_.Results[0].Status -eq 'Changed' }).Count -eq 1) $null

    # an existing snapshot made by someone else after the last change
    $armClock = New-AVDTuneFakeArm -Seed @{ Snapshots = @(@{ Name = 'just-after-the-change'; Created = $last2.AddMinutes(5) }) }
    $listClock = @(Get-AVDTuneOsDiskSnapshots -Arm $armClock -Token $armToken -Vm $vm -LastChange $last2)
    Test-Check 'clock margin: a snapshot only 5 minutes after the last change (VM clock may run behind Azure) does not count, 10 minutes are explained' ((Get-AVDTuneSnapshotClockBuffer) -eq 10 -and -not $listClock[0].Valid -and (Get-AVDTuneGateStatus -Vm $vm -Snapshots $listClock -Confirmed $false -LastChange $last2).Detail -like '*at least 10 minutes after the last change*clock*' -and (Get-ThrownText { Confirm-AVDTuneSnapshotGate -Root $tmp -Snapshot $listClock[0] -TypedName 'Alex Example' -ImageVersion '2026.11.001' -Machine $machine }) -like '*plus 10 minutes*') $null
    $armOther = New-AVDTuneFakeArm -Seed @{ Snapshots = @(@{ Name = 'manual-snap-before-patching'; Created = $last2.AddMinutes(11) }) }
    $listOther = @(Get-AVDTuneOsDiskSnapshots -Arm $armOther -Token $armToken -Vm $vm -LastChange $last2)
    Test-Check 'an existing snapshot newer than the last change is found and counts (not made by AVDTune)' ($listOther.Count -eq 1 -and $listOther[0].Valid -and -not $listOther[0].ByAVDTune) ($listOther | ConvertTo-Json -Compress -Depth 3)
    [void](Confirm-AVDTuneSnapshotGate -Root $tmp -Snapshot $listOther[0] -TypedName 'Alex Example' -SignedInAccount 'admin.example@contoso.example' -ImageVersion '2026.11.001' -Machine $machine)
    $entry2 = @(Get-AVDTuneChangeLog -Root $tmp | Where-Object { $_.Category -eq 'Snapshot' }) | Select-Object -Last 1
    Test-Check 'the change log says created by AVDTune: no' ($entry2.Text -like '*created by AVDTune: no*' -and (Get-AVDTuneState $tmp).SnapshotGate.CreatedByAVDTune -eq $false) $entry2.Text
    Close-AVDTuneWriteGate

    # snapshot error paths
    $armOff = New-AVDTuneFakeArm -Seed @{}; $armOff.Store.Offline = $true
    $e = Get-ThrownText { Get-AVDTuneOsDiskSnapshots -Arm $armOff -Token $armToken -Vm $vm }
    Test-Check 'no network to Azure: readable error' ($e -like 'No connection to Azure Resource Manager*') $e
    $armRo = New-AVDTuneFakeArm -Seed @{}; $armRo.Store.WriteForbidden = $true
    $e = Get-ThrownText { Start-AVDTuneSnapshot -Arm $armRo -Token $armToken -Vm $vm -ImageVersion '2026.11.001' -User 'x' -At $now }
    Test-Check '403 on creating the snapshot: names the missing permission, the role and the resource group' ($e -like '*403*Microsoft.Compute/snapshots/write*rg-example*Disk Snapshot Contributor*') $e
    $armRd = New-AVDTuneFakeArm -Seed @{}; $armRd.Store.ReadForbidden = $true
    $e = Get-ThrownText { Get-AVDTuneOsDiskSnapshots -Arm $armRd -Token $armToken -Vm $vm }
    Test-Check '403 on reading the snapshots: names the read permission' ($e -like '*403*snapshots/read*') $e
    $armNoDisk = New-AVDTuneFakeArm -Seed @{}; $armNoDisk.Store.DiskMissing = $true
    Test-Check 'the OS disk does not exist (404): readable error' ((Get-ThrownText { Start-AVDTuneSnapshot -Arm $armNoDisk -Token $armToken -Vm $vm -ImageVersion '2026.11.001' -User 'x' -At $now }) -like '*404*') $null
    $armFail = New-AVDTuneFakeArm -Seed @{}; $armFail.Store.CreateFails = $true
    $f = Start-AVDTuneSnapshot -Arm $armFail -Token $armToken -Vm $vm -ImageVersion '2026.11.001' -User 'x' -At $now
    Test-Check 'a snapshot that fails in Azure is an error, not a confirmation' ((Get-ThrownText { Wait-AVDTuneSnapshot -Arm $armFail -Token $armToken -Id $f.Id -PollSeconds 0 }) -like '*failed in Azure*') $null
    $armSlow = New-AVDTuneFakeArm -Seed @{}; $armSlow.Store.PollsUntilReady = 1000
    $sl = Start-AVDTuneSnapshot -Arm $armSlow -Token $armToken -Vm $vm -ImageVersion '2026.11.001' -User 'x' -At $now
    Test-Check 'a snapshot that does not finish in time says so' ((Get-ThrownText { Wait-AVDTuneSnapshot -Arm $armSlow -Token $armToken -Id $sl.Id -TimeoutSeconds 0 -PollSeconds 0 }) -like '*not ready*') $null
    $armUn = New-AVDTuneFakeArm -Seed @{}; $armUn.Store.Unauthorized = $true
    Test-Check '401: sign in again' ((Get-ThrownText { Get-AVDTuneOsDiskSnapshots -Arm $armUn -Token $armToken -Vm $vm }) -like '*Sign in again*') $null
    $armPaged = New-AVDTuneFakeArm -Seed @{ Snapshots = @(@{ Name = 'p1'; Created = [datetime]'2026-11-15 09:10' }) }; $armPaged.Store.NextLinkPage = $true
    Test-Check 'nextLink on the ARM host is followed' (@(Get-AVDTuneOsDiskSnapshots -Arm $armPaged -Token $armToken -Vm $vm).Count -eq 1 -and @($armPaged.Log | Where-Object { $_ -like '*page2*' }).Count -eq 1) $null
    $armEvil = New-AVDTuneFakeArm -Seed @{}; $armEvil.Store.EvilLink = $true
    Test-Check 'a nextLink to another host is refused (the token is not sent there)' ((Get-ThrownText { Get-AVDTuneOsDiskSnapshots -Arm $armEvil -Token $armToken -Vm $vm }) -like '*another host*') $null
    Test-Check 'a snapshot ID is checked before it is used as a path' ($null -ne (Get-ThrownText { Get-AVDTuneSnapshotState -Arm $arm -Token $armToken -Id '/subscriptions/x/../../evil' })) $null
    # the real ARM adapter refuses foreign paths without a network call
    $realArm = New-AVDTuneArmAdapter
    Test-Check 'real ARM adapter refuses a path outside /subscriptions and path tricks' ((& $realArm.Invoke GET '/tenants?api-version=1' 't' $null).Status -eq 0 -and (& $realArm.Invoke GET '/subscriptions/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/../x' 't' $null).Status -eq 0) $null
    $sub0 = '/subscriptions/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1'
    Test-Check 'real ARM adapter refuses a fragment (#) and a second question mark (no network call)' ((& $realArm.Invoke GET "$sub0#x" 't' $null).Status -eq 0 -and (& $realArm.Invoke GET "$sub0?api-version=1?x=2" 't' $null).Status -eq 0 -and (& $realArm.Invoke GET "$sub0#x" 't' $null).Error -like 'Refused*' -and (& $realArm.Invoke GET "$sub0?a=1?b=2" 't' $null).Error -like 'Refused*') $null
    foreach ($badName in @('rg/../x', 'rg?x', 'rg#x', 'rg 1', 'r%2fg')) {
        $evil = Get-AVDTuneVmIdentity (New-AVDTuneFakeMachine -Seed @{ Imds = [pscustomobject]@{ compute = [pscustomobject]@{ name = 'vm1'; resourceGroupName = $badName; subscriptionId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'; storageProfile = [pscustomobject]@{ osDisk = [pscustomobject]@{ name = 'd'; managedDisk = [pscustomobject]@{ id = '/subscriptions/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/resourceGroups/rg/providers/Microsoft.Compute/disks/d' } } } } } })
        $evilVm = Get-AVDTuneVmIdentity (New-AVDTuneFakeMachine -Seed @{ Imds = [pscustomobject]@{ compute = [pscustomobject]@{ name = $badName; resourceGroupName = 'rg'; subscriptionId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'; storageProfile = [pscustomobject]@{ osDisk = [pscustomobject]@{ name = 'd'; managedDisk = [pscustomobject]@{ id = '/subscriptions/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/resourceGroups/rg/providers/Microsoft.Compute/disks/d' } } } } } })
        Test-Check "instance metadata with the odd name '$badName' as resource group or VM name is refused" (-not $evil.Available -and -not $evilVm.Available) $null
    }
    $armCode = [IO.File]::ReadAllText((Join-Path $repo 'Modules\AVDTune.Snapshot.psm1'))
    $armBlock = $armCode.Substring($armCode.IndexOf('function New-AVDTuneArmAdapter'))
    Test-Check 'real ARM adapter asks for TLS 1.2 explicitly before the request (finding: TLS)' ($armBlock -match 'SecurityProtocol -bor \[Net\.SecurityProtocolType\]::Tls12' -and $armBlock.IndexOf('Tls12') -lt $armBlock.IndexOf('HttpWebRequest]::Create')) $null

    # ---------------------------------------------------------------- domain controller
    $ldap = New-AVDTuneFakeLdap
    $pw = New-Secret $secretPassword
    $r1 = Connect-AVDTuneDirectory -Ldap $ldap -Server '10.0.0.10' -User 'EXAMPLE\svc-avdtune' -Password $pw -Pins @{}
    Test-Check 'first contact over LDAPS: certificate shown, nothing sent (no bind), status NeedsPin' ($r1.Status -eq 'NeedsPin' -and $r1.Certificate.Thumbprint -eq ('AB' * 20) -and $ldap.Opened.Count -eq 0) ($r1 | ConvertTo-Json -Compress -Depth 3)
    $pin = Set-AVDTuneDcPin -Root $tmp -Server '10.0.0.10' -Certificate $r1.Certificate -User 'admin1'
    $pins = Get-AVDTuneDcPins (Get-AVDTuneEnvironment $tmp)
    Test-Check 'the pin is saved per environment in environment.json' ($pins['10.0.0.10'] -ieq ('AB' * 32) -and (Get-AVDTuneEnvironment $tmp).Dc.Pins.'10.0.0.10'.PinnedBy -eq 'admin1') ($pins | ConvertTo-Json -Compress)
    $r2 = Connect-AVDTuneDirectory -Ldap $ldap -Server '10.0.0.10' -User 'EXAMPLE\svc-avdtune' -Password $pw -Pins $pins
    $o = $ldap.Opened[0]
    Test-Check 'pinned: LDAPS 636 with SSL, Negotiate, the pin is passed to the bind' ($r2.Status -eq 'Connected' -and $o.Port -eq 636 -and $o.Ssl -and $o.AuthType -eq 'Negotiate' -and $o.PinnedSha256 -ieq ('AB' * 32) -and $r2.Security -like 'LDAPS 636*') ($o | ConvertTo-Json -Compress)
    $ldap.Store.Servers['10.0.0.10'].Cert = @{ Sha256 = ('CD' * 32); Thumbprint = ('CD' * 20); Subject = 'CN=dc1.example.test'; Issuer = 'CN=Other CA'; NotBefore = ''; NotAfter = '' }
    $opened = $ldap.Opened.Count
    $r3 = Connect-AVDTuneDirectory -Ldap $ldap -Server '10.0.0.10' -User 'EXAMPLE\svc-avdtune' -Password $pw -Pins $pins
    Test-Check 'changed certificate: stop, no bind, no fallback to 389, both thumbprints named' ($r3.Status -eq 'CertificateChanged' -and $ldap.Opened.Count -eq $opened -and $r3.Message -like "*$('AB' * 32)*" -and $r3.Message -like "*$('CD' * 32)*" -and @($ldap.Log | Where-Object { $_ -like 'Open*:389*' }).Count -eq 0) $r3.Message
    Test-Check 're-pinning a changed certificate needs the explicit switch and is logged' (($null -ne (Get-ThrownText { Set-AVDTuneDcPin -Root $tmp -Server '10.0.0.10' -Certificate $r3.Certificate -User 'admin1' })) -and (Set-AVDTuneDcPin -Root $tmp -Server '10.0.0.10' -Certificate $r3.Certificate -User 'admin1' -Replace).Thumbprint -eq ('CD' * 20) -and (@(Get-AVDTuneChangeLog -Root $tmp | Where-Object { $_.Component -eq 'Domain controller' }).Count -eq 1)) $null
    # LDAPS gone for a pinned DC: no downgrade
    $ldap.Store.Servers['10.0.0.10'].Ldaps = $false
    $pins = Get-AVDTuneDcPins (Get-AVDTuneEnvironment $tmp)
    $opened = $ldap.Opened.Count
    $r4 = Connect-AVDTuneDirectory -Ldap $ldap -Server '10.0.0.10' -User 'EXAMPLE\svc-avdtune' -Password $pw -Pins $pins
    Test-Check 'a pinned DC that stops answering over LDAPS is not downgraded to 389' ($r4.Status -eq 'Failed' -and $ldap.Opened.Count -eq $opened -and $r4.Message -like '*does not fall back*') $r4.Message
    # never seen with LDAPS (finding 3): no silent fallback, the administrator confirms first
    $ldap2 = New-AVDTuneFakeLdap -Seed @{ Servers = @{ 'dc2.example.test' = @{ Ldaps = $false; Ldap389 = $true; Cert = $null; BadPassword = $false }; '10.0.0.20' = @{ Ldaps = $false; Ldap389 = $true; Cert = $null; BadPassword = $false } } }
    $r5n = Connect-AVDTuneDirectory -Ldap $ldap2 -Server 'DC2.example.test' -User 'svc@example.test' -Password $pw -Pins @{}
    Test-Check 'attack: 636 blocked, no confirmation: NeedsConfirmation with a warning, no bind at all' ($r5n.Status -eq 'NeedsConfirmation' -and $ldap2.Opened.Count -eq 0 -and $r5n.Warning -like '*Kerberos*') ($r5n | ConvertTo-Json -Compress)
    $r5 = Connect-AVDTuneDirectory -Ldap $ldap2 -Server 'DC2.example.test' -User 'svc@example.test' -Password $pw -Pins @{} -ConfirmedServer 'dc2.example.test'
    $o2 = $ldap2.Opened[0]
    Test-Check 'DNS name, confirmed: LDAP 389 with Kerberos only (NTLM refused), signing and sealing' ($r5.Status -eq 'Connected' -and $o2.Port -eq 389 -and -not $o2.Ssl -and $o2.Signing -and $o2.Sealing -and $o2.AuthType -eq 'Kerberos' -and $o2.RiskConfirmed -and $r5.Security -like '*Kerberos*confirmed*') ($o2 | ConvertTo-Json -Compress)
    $r6n = Connect-AVDTuneDirectory -Ldap $ldap2 -Server '10.0.0.20' -User 'EXAMPLE\svc' -Password $pw -Pins @{}
    Test-Check 'IP address, 636 blocked: the warning names NTLM, relay and offline cracking; nothing sent' ($r6n.Status -eq 'NeedsConfirmation' -and $r6n.IsIp -and $r6n.Warning -like '*NTLM*relay*crack the password offline*' -and $ldap2.Opened.Count -eq 1) $r6n.Warning
    $r6x = Connect-AVDTuneDirectory -Ldap $ldap2 -Server '10.0.0.20' -User 'EXAMPLE\svc' -Password $pw -Pins @{} -ConfirmedServer 'dc2.example.test'
    Test-Check 'N3: a confirmation given for another server does not count: warning again, no bind' ($r6x.Status -eq 'NeedsConfirmation' -and $ldap2.Opened.Count -eq 1) $r6x.Status
    $r6 = Connect-AVDTuneDirectory -Ldap $ldap2 -Server '10.0.0.20' -User 'EXAMPLE\svc' -Password $pw -Pins @{} -ConfirmedServer '10.0.0.20'
    Test-Check 'IP address, confirmed: Negotiate over 389 with signing and sealing, marked as not authenticated' ($r6.Status -eq 'Connected' -and $ldap2.Opened[1].AuthType -eq 'Negotiate' -and $r6.Security -like '*NTLM*not authenticated*confirmed*') $r6.Security
    Disconnect-AVDTuneDirectory -Ldap $ldap2 -Connection $r6.Connection
    # option validator: nothing weaker exists
    $badOptions = @(
        @{ Name = 'simple bind'; O = [pscustomobject]@{ Port = 389; Ssl = $false; Signing = $true; Sealing = $true; AuthType = 'Basic'; PinnedSha256 = '' } }
        @{ Name = 'anonymous'; O = [pscustomobject]@{ Port = 389; Ssl = $false; Signing = $true; Sealing = $true; AuthType = 'Anonymous'; PinnedSha256 = '' } }
        @{ Name = '389 without sealing'; O = [pscustomobject]@{ Port = 389; Ssl = $false; Signing = $true; Sealing = $false; AuthType = 'Negotiate'; PinnedSha256 = '' } }
        @{ Name = '389 without signing'; O = [pscustomobject]@{ Port = 389; Ssl = $false; Signing = $false; Sealing = $true; AuthType = 'Negotiate'; PinnedSha256 = '' } }
        @{ Name = '636 without a pin'; O = [pscustomobject]@{ Port = 636; Ssl = $true; Signing = $false; Sealing = $false; AuthType = 'Negotiate'; PinnedSha256 = '' } }
        @{ Name = '636 without SSL'; O = [pscustomobject]@{ Port = 636; Ssl = $false; Signing = $false; Sealing = $false; AuthType = 'Negotiate'; PinnedSha256 = 'AB' } }
        @{ Name = 'another port'; O = [pscustomobject]@{ Port = 3268; Ssl = $false; Signing = $true; Sealing = $true; AuthType = 'Negotiate'; PinnedSha256 = '' } }
        @{ Name = '389 without the confirmation'; O = [pscustomobject]@{ Server = '10.0.0.20'; Port = 389; Ssl = $false; Signing = $true; Sealing = $true; AuthType = 'Negotiate'; PinnedSha256 = ''; RiskConfirmed = $false } }
        @{ Name = '389 with a DNS name and NTLM (Negotiate)'; O = [pscustomobject]@{ Server = 'dc2.example.test'; Port = 389; Ssl = $false; Signing = $true; Sealing = $true; AuthType = 'Negotiate'; PinnedSha256 = ''; RiskConfirmed = $true } })
    foreach ($b in $badOptions) { Test-Check "option set refused: $($b.Name)" ($null -ne (Get-ThrownText { Assert-AVDTuneLdapOptions $b.O })) $null }
    Test-Check 'the options the code builds are the two allowed ones' ((Assert-AVDTuneLdapOptions (New-AVDTuneLdapOptions -Server 'a' -Mode Ldaps -PinnedSha256 'AB')) -and (Assert-AVDTuneLdapOptions (New-AVDTuneLdapOptions -Server 'a.example.test' -Mode Signed -RiskConfirmed)) -and (Assert-AVDTuneLdapOptions (New-AVDTuneLdapOptions -Server '10.0.0.20' -Mode Signed -RiskConfirmed))) $null
    # input
    Test-Check 'server and account are validated before any socket or filter' ((Test-AVDTuneDcServer '10.0.0.10') -and (Test-AVDTuneDcServer 'dc1.example.test') -and -not (Test-AVDTuneDcServer '999.1.1.1') -and -not (Test-AVDTuneDcServer 'dc1;calc') -and -not (Test-AVDTuneDcServer '') -and (Test-AVDTuneDomainUser 'EXAMPLE\svc') -and (Test-AVDTuneDomainUser 'svc@example.test') -and -not (Test-AVDTuneDomainUser 'svc') -and -not (Test-AVDTuneDomainUser "a`nb@x.y")) $null
    Test-Check 'a bad server or account is a Failed result without any contact' ((Connect-AVDTuneDirectory -Ldap $ldap -Server 'x;y' -User 'EXAMPLE\a' -Password $pw).Status -eq 'Failed' -and (Connect-AVDTuneDirectory -Ldap $ldap -Server '10.0.0.10' -User 'nobody' -Password $pw).Status -eq 'Failed') $null
    Test-Check 'an empty password is refused before any contact' ((Connect-AVDTuneDirectory -Ldap $ldap2 -Server 'dc2.example.test' -User 'svc@example.test' -Password (New-Secret '')).Message -like '*password*') $null
    Test-Check 'LDAP filter values are escaped' ((ConvertTo-AVDTuneLdapFilterValue 'DC=a)(objectClass=*') -eq 'DC=a\29\28objectClass=\2a' -and (ConvertTo-AVDTuneLdapFilterValue 'a\b') -eq 'a\5cb') (ConvertTo-AVDTuneLdapFilterValue 'DC=a)(objectClass=*')
    $ldapBad = New-AVDTuneFakeLdap; $ldapBad.Store.Servers['10.0.0.10'].BadPassword = $true
    $rb = Connect-AVDTuneDirectory -Ldap $ldapBad -Server '10.0.0.10' -User 'EXAMPLE\svc' -Password $pw -Pins @{ '10.0.0.10' = ('AB' * 32) }
    Test-Check 'a refused account or password: readable text without the password' ($rb.Status -eq 'Failed' -and $rb.Message -like '*refused*' -and $rb.Message -notlike "*$secretPassword*") $rb.Message
    $ldapDown = New-AVDTuneFakeLdap -Seed @{ Servers = @{} }
    $rd0 = Connect-AVDTuneDirectory -Ldap $ldapDown -Server '10.9.9.9' -User 'EXAMPLE\svc' -Password $pw
    $rd = Connect-AVDTuneDirectory -Ldap $ldapDown -Server '10.9.9.9' -User 'EXAMPLE\svc' -Password $pw -ConfirmedServer '10.9.9.9'
    Test-Check 'an unreachable DC: first the LDAPS question, after the confirmation Failed with a readable message' ($rd0.Status -eq 'NeedsConfirmation' -and $rd.Status -eq 'Failed' -and $rd.Message -like '*10.9.9.9*') $rd.Message

    # discovery
    $info = Get-AVDTuneDirectoryInfo -Ldap $ldap2 -Connection $r5.Connection
    Test-Check 'RootDSE: DNS name, NetBIOS name, naming contexts, functional levels, DC name' ($info.DnsName -eq 'example.test' -and $info.NetBiosName -eq 'EXAMPLE' -and $info.DefaultNamingContext -eq 'DC=example,DC=test' -and $info.ConfigurationNamingContext -like 'CN=Configuration,*' -and $info.DomainLevel -eq 'Windows Server 2016' -and $info.ForestLevel -eq 'Windows Server 2016' -and $info.DcDnsName -eq 'dc1.example.test') ($info | ConvertTo-Json -Compress -Depth 2)
    Test-Check 'site of the DC from its server name' ($info.Site -eq 'Default-First-Site-Name') $info.Site
    Test-Check 'OU tree: Corp > AVD > Groups and Servers, 4 OUs' ($info.OuCount -eq 4 -and $info.OuTree.Count -eq 2 -and ($info.OuTree | Where-Object Name -eq 'Corp').Children[0].Name -eq 'AVD' -and ($info.OuTree | Where-Object Name -eq 'Corp').Children[0].Children[0].Name -eq 'Groups') ($info.OuTree | ConvertTo-Json -Compress -Depth 6)
    $g = $info.Groups | Where-Object Name -eq 'AVD-Users'
    Test-Check 'groups with their SIDs; security and distribution groups told apart' ($info.Groups.Count -eq 3 -and $g.Sid -match '^S-1-5-21-1111111111-2222222222-333333333-1104$' -and $g.Security -and -not ($info.Groups | Where-Object Name -eq 'Mail-List').Security) ($info.Groups | ForEach-Object { "$($_.Name)=$($_.Sid)" })
    $ldapPartial = New-AVDTuneFakeLdap; $ldapPartial.Store.Entries.Fail = 'group'
    $ip = Get-AVDTuneDirectoryInfo -Ldap $ldapPartial -Connection $r2.Connection
    Test-Check 'a part that cannot be read becomes a warning, the rest is still returned' ($ip.Warnings.Count -eq 1 -and $ip.Warnings[0] -like 'Groups not read*' -and $ip.OuCount -eq 4) ($ip.Warnings -join ';')
    Save-AVDTuneDcDiscovery -Root $tmp -Server '10.0.0.10' -User 'EXAMPLE\svc-avdtune' -Info $info
    Save-AVDTuneDirectoryInfo -Root $tmp -Info $info
    $envDc = (Get-AVDTuneEnvironment $tmp).Dc
    Test-Check 'environment.json keeps the DC, the account name, the pins and a summary of what was read' ($envDc.Server -eq '10.0.0.10' -and $envDc.User -eq 'EXAMPLE\svc-avdtune' -and $envDc.Discovery.NetBiosName -eq 'EXAMPLE' -and $envDc.Discovery.GroupCount -eq 3 -and $envDc.Pins.'10.0.0.10'.Sha256) ($envDc | ConvertTo-Json -Compress -Depth 4)
    Test-Check 'the answers survive the DC update' ((Get-AVDTuneEnvironment $tmp).Answers.Profiles -eq 'OtherSmb') $null
    Disconnect-AVDTuneDirectory -Ldap $ldap2 -Connection $r5.Connection
    Test-Check 'the connection is closed' ($ldap2.Log -contains 'Close') $null

    # start stages with a DC
    $hy = Get-AVDTuneEnvironmentAnswers (Get-AVDTuneEnvironment $tmp); $hy.Join = 'Hybrid'; $hy.Dc = 'AdDsOnPrem'; $hy.Identities = 'Synced'
    [void](Save-AVDTuneEnvironment -Root $tmp -Answers $hy -User 'admin1')
    $ctx2 = New-AVDTuneStartContext
    $st = Get-AVDTuneStartStages -Context $ctx2 -Root $tmp
    Test-Check 'with a DC: questions done, sign-in pending, domain and snapshot locked' (($st | ForEach-Object Status) -join ',' -eq 'Done,Pending,Locked,Locked') (($st | ForEach-Object Status) -join ',')
    $s7 = New-AVDTuneSession -TempRoot $signTemp -Auth (New-AVDTuneFakeAuth); [void](Connect-AVDTuneSession -Session $s7 -TenantId $tenant -ClientId $clientId); $ctx2.Session = $s7
    $st = Get-AVDTuneStartStages -Context $ctx2 -Root $tmp
    Test-Check 'after the sign-in the domain stage is pending' (($st | ForEach-Object Status) -join ',' -eq 'Done,Done,Pending,Locked') (($st | ForEach-Object Status) -join ',')
    $ctx2.Directory = $info; $ctx2.DirectorySecurity = 'LDAPS 636, certificate pinned'
    $st2 = Get-AVDTuneStartStages -Context $ctx2 -Root $tmp
    Test-Check 'after the domain is read: done with the facts, snapshot pending' ((($st2 | ForEach-Object Status) -join ',' -eq 'Done,Done,Done,Pending') -and ($st2[2].Detail -like '*example.test*EXAMPLE*4 OUs*3 groups*Default-First-Site-Name*pinned*')) $st2[2].Detail
    $ctx2.Failures['Snapshot'] = 'No connection to Azure Resource Manager.'
    $st = Get-AVDTuneStartStages -Context $ctx2 -Root $tmp
    Test-Check 'a failure of a stage is shown on that stage' ($st[3].Status -eq 'Failed' -and $st[3].Detail -like 'No connection*' -and (Get-AVDTuneNextStage $st).Id -eq 'Snapshot') $null
    Disconnect-AVDTuneSession $s7

    # the real probe against a TLS listener on this computer's loopback (a made-up self-signed certificate; no external host, no credentials)
    $rsa = [Security.Cryptography.RSA]::Create(2048)
    $req = New-Object Security.Cryptography.X509Certificates.CertificateRequest('CN=localhost', $rsa, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $pfx = $req.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddDays(30)).Export('Pfx', 'x')
    $serverCert = New-Object Security.Cryptography.X509Certificates.X509Certificate2($pfx, 'x', [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable)
    $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0); $listener.Start()
    $port = $listener.LocalEndpoint.Port
    $serverPs = [powershell]::Create()
    [void]$serverPs.AddScript({ param($l, $c) $cl = $l.AcceptTcpClient(); $ssl = New-Object Net.Security.SslStream($cl.GetStream(), $false); $ssl.AuthenticateAsServer($c, $false, [Security.Authentication.SslProtocols]::Tls12, $false); Start-Sleep -Milliseconds 300; $ssl.Dispose(); $cl.Close() }).AddArgument($listener).AddArgument($serverCert)
    $serverHandle = $serverPs.BeginInvoke()
    try {
        $realLdap = New-AVDTuneLdapAdapter
        $probe = & $realLdap.Probe '127.0.0.1' $port
        $shaAlg = [Security.Cryptography.SHA256]::Create()
        $expectedSha = ($shaAlg.ComputeHash($serverCert.RawData) | ForEach-Object { $_.ToString('X2') }) -join ''
        Test-Check 'real LDAP probe: reads the certificate (thumbprint, SHA-256, subject) without sending credentials' ($probe.Ok -and $probe.Certificate.Sha256 -eq $expectedSha -and $probe.Certificate.Thumbprint -eq $serverCert.Thumbprint -and $probe.Certificate.Subject -eq 'CN=localhost') ($probe | ConvertTo-Json -Compress -Depth 3)
    Test-Check 'real LDAP probe: chain status and name match as extra facts (self-signed for localhost, asked as 127.0.0.1: neither)' ($probe.Certificate.ChainOk -eq $false -and $probe.Certificate.ChainStatus -like 'not trusted*' -and $probe.Certificate.NameMatches -eq $false) ($probe.Certificate | ConvertTo-Json -Compress)
    }
    finally { $listener.Stop(); $serverPs.Dispose() }
    Test-Check 'real LDAP probe: a closed port is a readable failure, not an exception' (-not (& $realLdap.Probe '127.0.0.1' 1).Ok) $null
    Test-Check 'real LDAP adapter refuses an option set that is not allowed before any connection' ($null -ne (Get-ThrownText { & $realLdap.Open ([pscustomobject]@{ Server = '127.0.0.1'; Port = 389; Ssl = $false; Signing = $false; Sealing = $false; AuthType = 'Negotiate'; PinnedSha256 = '' }) 'EXAMPLE' (New-Secret 'x') })) $null

    # ---------------------------------------------------------------- WebView2 cache folder: what the shared code does not check (it pins version and hashes, checks the signature on every load)
    $wv = Join-Path $tmp 'WebView2'
    $names = 'Microsoft.Web.WebView2.Core.dll', 'Microsoft.Web.WebView2.Wpf.dll', 'WebView2Loader.dll', 'webview2-sdk.json'
    $trustCode = [IO.File]::ReadAllText((Join-Path $repo 'Modules\AVDTune.Trust.psm1'))
    Test-Check 'no duplicate of the shared WebView2 checks left in AVDTune (no own signature, hash or trust record)' ($trustCode -notmatch 'Get-AuthenticodeSignature|Sha256|SHA256|webview2-trust|Register-AVDTuneWebView2Cache') $null
    Test-Check 'no cache folder: nothing to check, the shared code downloads the pinned SDK' ((Assert-AVDTuneWebView2Cache -Folder $wv).Status -eq 'Empty') $null
    New-Item -ItemType Directory -Path $wv -Force | Out-Null
    foreach ($n in $names) { [IO.File]::WriteAllText((Join-Path $wv $n), 'x') }
    Test-Check 'only the three DLLs and the marker of the shared module: left for the shared code to check' ((Assert-AVDTuneWebView2Cache -Folder $wv).Status -eq 'Clean' -and (Test-Path (Join-Path $wv 'WebView2Loader.dll'))) $null
    [IO.File]::WriteAllText((Join-Path $wv 'version.dll'), 'MZ side loaded')
    $r = Assert-AVDTuneWebView2Cache -Folder $wv
    Test-Check 'an extra DLL next to the SDK files (side loading) is refused: folder deleted' ($r.Status -eq 'Reset' -and ($r.Problems -join ' ') -like '*unexpected file version.dll*' -and -not (Test-Path $wv)) ($r.Problems -join '; ')
    New-Item -ItemType Directory -Path (Join-Path $wv 'sub') -Force | Out-Null
    $r = Assert-AVDTuneWebView2Cache -Folder $wv
    Test-Check 'a sub folder is refused: folder deleted' ($r.Status -eq 'Reset' -and ($r.Problems -join ' ') -like '*unexpected folder sub*' -and -not (Test-Path $wv)) ($r.Problems -join '; ')
    $target = Join-Path $tmp 'junction-target'; New-Item -ItemType Directory -Path $target -Force | Out-Null; [IO.File]::WriteAllText((Join-Path $target 'keep.txt'), 'x')
    New-Item -ItemType Junction -Path $wv -Value $target | Out-Null
    $r = Assert-AVDTuneWebView2Cache -Folder $wv
    Test-Check 'a cache folder that is a link is removed as a link; the target is not touched' ($r.Status -eq 'Reset' -and -not (Test-Path $wv) -and (Test-Path (Join-Path $target 'keep.txt'))) ($r.Problems -join '; ')
    New-Item -ItemType Directory -Path $wv -Force | Out-Null
    New-Item -ItemType Junction -Path (Join-Path $wv 'WebView2Loader.dll') -Value $target | Out-Null
    $r = Assert-AVDTuneWebView2Cache -Folder $wv
    Test-Check 'a link inside the folder is refused; its target is not touched' ($r.Status -eq 'Reset' -and -not (Test-Path $wv) -and (Test-Path (Join-Path $target 'keep.txt'))) ($r.Problems -join '; ')
    New-Item -ItemType Directory -Path $wv -Force | Out-Null
    foreach ($n in $names) { [IO.File]::WriteAllText((Join-Path $wv $n), 'x') }
    [IO.File]::WriteAllText((Join-Path $wv 'planted.dll'), 'MZ planted')
    $hold = [IO.File]::Open((Join-Path $wv $names[0]), 'Open', 'Read', 'None')
    try { $e = Get-ThrownText { Assert-AVDTuneWebView2Cache -Folder $wv } } finally { $hold.Dispose() }
    Test-Check 'foreign content that cannot be deleted stops the sign-in (nothing is loaded)' ($e -like '*unexpected content*sign-in is stopped*') $e
    Remove-Item $wv -Recurse -Force
    # ---------------------------------------------------------------- no Keevault (user decision 2026-11-15): normal Microsoft sign-in only
    $kvPattern = '(?i)\b(Find|Connect|Close|Send|Invoke)-Kee' + 'vaultMcp\w*|Connect-PackTuneWith' + 'Keevault|request_' + 'microsoft_login|get_' + 'totp|sign_in_with_' + 'passkey'
    $own = @(Get-ChildItem $repo -Recurse -File -Include '*.ps1', '*.psm1', '*.xaml' | Where-Object { $_.FullName -notlike (Join-Path $repo 'Shared\*') -and $_.FullName -notlike '*\.git\*' })
    $kvHits = @($own | Where-Object { [IO.File]::ReadAllText($_.FullName) -match $kvPattern } | ForEach-Object { $_.FullName.Substring($repo.Length + 1) })
    Test-Check 'no AVDTune code outside Shared\ calls a Keevault function' ($own.Count -gt 10 -and $kvHits.Count -eq 0) ($kvHits -join ', ')
    $sessCode = [IO.File]::ReadAllText((Join-Path $repo 'Modules\AVDTune.Session.psm1'))
    Test-Check 'the sign-in imports only the normal sign-in functions of the shared module and fills in nothing' ($sessCode -match 'Import-Module \$shared -Force -Function Invoke-PackTuneBrowserSignIn, Request-PackTuneToken, Set-PackTuneSignInLog\r?\n' -and $sessCode -match 'Invoke-PackTuneBrowserSignIn @params' -and $sessCode -match '\$params = @\{ TenantID = \$TenantId; ClientID = \$ClientId; CacheFolder' -and $sessCode -notmatch '(?i)-Fill\b|-Passkey\b|-HasOtp\b|\b(Fill|Passkey|HasOtp)\s*=|params\.(Fill|Passkey|HasOtp)') $null

    # ---------------------------------------------------------------- nothing secret on disk, source rules
    $allText = (Get-ChildItem $tmp -Recurse -File | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join "`n"
    Test-Check 'no password, token or refresh token in any file of the state folder' ($allText -notmatch [regex]::Escape($secretPassword) -and $allText -notmatch 'eyJ[A-Za-z0-9_-]{10,}' -and $allText -notmatch 'fake-refresh' -and $allText -notmatch 'fake-arm-token') $null
    $logText = (@($ldap.Log) + @($ldap2.Log) + @($arm.Log) + @($auth.Log) | Out-String)
    Test-Check 'no password or token in the logs of the fakes' ($logText -notmatch [regex]::Escape($secretPassword) -and $logText -notmatch 'fake-arm-token-value') $null
    $dirSource = [IO.File]::ReadAllText((Join-Path $repo 'Modules\AVDTune.Directory.psm1'))
    $code = ($dirSource -split "`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
    Test-Check 'Directory module: no simple bind, anonymous bind or clear-text password in the code' ($code -notmatch '(?i)AuthType\]::(Basic|Anonymous|Ntlm|Digest|Sicily|Msn|Dpa|External)' -and $code -notmatch 'ConvertTo-SecureString|AsPlainText|SecureStringToBSTR|SecureStringToGlobalAllocUnicode|ConvertFrom-AVDTuneSecure' -and $code -match 'AuthType\]::Negotiate' -and $code -match 'AuthType\]::Kerberos') $null
    Test-Check 'real LDAP adapter: the server name is used as given (LdapDirectoryIdentifier with fullyQualifiedDnsHostName = true)' ($code -match 'LdapDirectoryIdentifier\(\$Options\.Server, \[int\]\$Options\.Port, \$true, \$false\)') $null
    $nonAscii = @('Modules\AVDTune.Trust.psm1', 'Modules\AVDTune.Start.psm1', 'Modules\AVDTune.Session.psm1', 'Modules\AVDTune.Snapshot.psm1', 'Modules\AVDTune.Directory.psm1', 'Tests\Fakes\FakeServices.ps1', 'Tests\Check-Start.ps1') | Where-Object { [IO.File]::ReadAllText((Join-Path $repo $_)) -match '[^\x00-\x7F]' }
    Test-Check 'new files are plain ASCII' ($nonAscii.Count -eq 0) ($nonAscii -join ',')
    $sessSource = [IO.File]::ReadAllText((Join-Path $repo 'Modules\AVDTune.Session.psm1'))
    Test-Check 'Session module writes nothing to disk and prints no token' ($sessSource -notmatch 'Set-Content|Out-File|WriteAllText|Write-AVDTuneFile|Write-Host|Write-Output') $null
    $kvFiles = @(Get-ChildItem (Join-Path $repo 'Shared') -Recurse -File | Where-Object { $_.Name -match ('(?i)kee' + 'vault') } | ForEach-Object { $_.FullName.Substring($repo.Length + 1) })
    Test-Check 'no Keevault file in Shared\ (the sign-in module is PackTune.SignIn.psm1; Check-Shared proves the copies are unedited)' ($kvFiles.Count -eq 0 -and (Test-Path (Join-Path $repo 'Shared\Modules\PackTune.SignIn.psm1'))) ($kvFiles -join ', ')
}
catch { $script:failed++; "FAIL check aborted: $($_.Exception.Message) @ $($_.InvocationInfo.ScriptLineNumber)" }
finally {
    $env:AVDTUNE_ROOT = $null; $env:AVDTUNE_FAKE = $null
    Close-AVDTuneWriteGate
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
if ($script:failed -gt 0) { "Check-Start: $($script:failed) check(s) failed."; exit 1 }
'Check-Start: all checks passed.'
