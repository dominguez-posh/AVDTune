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
    Test-Check 'stages before the first run (#64: sign-in, domain, questions, snapshot): the sign-in is pending and needs no answer, the rest waits' (($stages | ForEach-Object { $_.Status }) -join ',' -eq 'Pending,Locked,Locked,Locked' -and ($stages | ForEach-Object { $_.Id }) -join ',' -eq 'SignIn,Domain,Environment,Snapshot') (($stages | ForEach-Object { $_.Status }) -join ',')
    $tenant = '11111111-2222-3333-4444-555555555555'
    $clientId = '66666666-7777-8888-9999-000000000000'
    $answers = Get-AVDTuneEnvironmentDefaults; $answers.TenantId = $tenant; $answers.ClientId = $clientId; $answers.VNet = 'vnet-example'; $answers.Subnet = 'snet-avd'
    $saved = Save-AVDTuneEnvironment -Root $tmp -Answers $answers -User 'admin1'
    Test-Check 'issue #64 finding 2: Save-AVDTuneEnvironment takes no client ID from the answers (only Set-AVDTuneEnvironmentSignIn sets it)' ($saved.Environment.SignIn.ClientId -eq '' -and $saved.Environment.SignIn.TenantId -eq $tenant) ($saved.Environment.SignIn | ConvertTo-Json -Compress)
    [void](Set-AVDTuneEnvironmentSignIn -Root $tmp -ClientId $clientId -User 'admin1')
    $saved = [pscustomobject]@{ Environment = (Get-AVDTuneEnvironment $tmp) }
    $emptyClient = Get-AVDTuneEnvironmentDefaults; $emptyClient.VNet = 'vnet-example'; $emptyClient.Subnet = 'snet-avd'; $emptyClient.ClientId = ''
    [void](Save-AVDTuneEnvironment -Root $tmp -Answers $emptyClient -User 'admin1')
    $foreignClient = Get-AVDTuneEnvironmentDefaults; $foreignClient.VNet = 'vnet-example'; $foreignClient.Subnet = 'snet-avd'; $foreignClient.ClientId = '99999999-7777-8888-9999-000000000000'
    [void](Save-AVDTuneEnvironment -Root $tmp -Answers $foreignClient -User 'admin1')
    Test-Check 'a save with an empty or another client ID in the answers keeps the saved client ID' ((Get-AVDTuneEnvironment $tmp).SignIn.ClientId -eq $clientId) ((Get-AVDTuneEnvironment $tmp).SignIn | ConvertTo-Json -Compress)
    $envPath = Join-Path $tmp 'environment.json'
    Test-Check 'environment.json is written with the answers and the sign-in target' ((Test-Path $envPath) -and $saved.Environment.Answers.Join -eq 'EntraOnly' -and $saved.Environment.SignIn.ClientId -eq $clientId -and $saved.Environment.Answers.Network.VNet -eq 'vnet-example') $null
    Test-Check 'environment.json has no field for a secret' ((Get-Content $envPath -Raw) -notmatch '(?i)password|secret|token|key') $null
    Test-Check 'invalid answers are not saved' ($null -ne (Get-ThrownText { $x = Get-AVDTuneEnvironmentDefaults; $x.Join = 'AdDs'; Save-AVDTuneEnvironment -Root $tmp -Answers $x })) $null
    Test-Check 'the saved file was not changed by the refused save' ((Get-AVDTuneEnvironment $tmp).Answers.Join -eq 'EntraOnly') $null
    $stages = Get-AVDTuneStartStages -Context $ctx -Root $tmp
    Test-Check 'with the answers of an earlier version: sign-in pending, domain skipped (Entra only), questions done (not asked again), snapshot locked' (($stages | ForEach-Object { $_.Status }) -join ',' -eq 'Pending,Skipped,Done,Locked') (($stages | ForEach-Object { $_.Status }) -join ',')
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
    # counter-tests: only a missing consent makes the storage token "not available"; everything else ends the sign-in like for the other audiences
    $cc = New-AVDTuneSession -TempRoot $signTemp -Auth (New-AVDTuneFakeAuth -Seed @{ ConsentMissing = @('Storage') })
    $cci = Connect-AVDTuneSession -Session $cc -TenantId $tenant -ClientId $clientId
    $why = Get-ThrownText { Get-AVDTuneAccessToken -Session $cc -Audience Storage }
    Test-Check 'storage, no consent (AADSTS65001): the sign-in works with three tokens, no storage token, the reason names the consent and the fix (Set up again), in the warnings too' ($cci.Connected -and -not $cc.Tokens.ContainsKey('Storage') -and @($cci.Audiences).Count -eq 3 -and $why -like '*no consent*Storage*user_impersonation*' -and $why -like '*Set up again (authorize this administrator)*' -and @($cci.Unavailable).Count -eq 1 -and (@($cci.Warnings) -join ' ') -like '*No Storage token*') "$why"
    Disconnect-AVDTuneSession $cc
    foreach ($case in @(
            @{ Name = 'the audience of another resource (ARM)'; Seed = @{ StorageAud = 'https://management.azure.com' }; Like = '*another resource*' },
            @{ Name = 'a look-alike host as audience (prefix of the real one)'; Seed = @{ StorageAud = 'https://storage.azure.com.evil.example' }; Like = '*another resource*' },
            @{ Name = 'the audience in GUID form'; Seed = @{ StorageAud = 'e406a681-f3d4-42a8-90b6-c2b029497af1' }; Like = '*another resource*' },
            @{ Name = 'a token without the scope user_impersonation'; Seed = @{ StorageScopes = @('Other.Scope') }; Like = '*lacks the permission user_impersonation*' },
            @{ Name = 'a roles claim instead of scp (application permission, not the delegated one)'; Seed = @{ StorageUseRoles = $true }; Like = '*lacks the permission user_impersonation*' },
            @{ Name = 'a tid of another tenant on the storage token only'; Seed = @{ StorageWrongTenant = $true }; Like = '*tenant*' })) {
        $cs = New-AVDTuneSession -TempRoot $signTemp -Auth (New-AVDTuneFakeAuth -Seed $case.Seed)
        $why = Get-ThrownText { Connect-AVDTuneSession -Session $cs -TenantId $tenant -ClientId $clientId }
        Test-Check "storage: $($case.Name): the whole sign-in fails, nothing kept, no 'Set up again' hint" ($why -like $case.Like -and $why -notlike '*Set up again*' -and (Test-AVDTuneSessionClear $cs)) "$why"
    }
    # check first, keep afterwards: a refresh with a wrong audience keeps the old access token AND the old refresh token; the second call fails again
    $rAuth = New-AVDTuneFakeAuth
    $rs = New-AVDTuneSession -TempRoot $signTemp -Auth $rAuth
    [void](Connect-AVDTuneSession -Session $rs -TenantId $tenant -ClientId $clientId)
    $refreshBefore = ConvertFrom-AVDTuneSecure $rs.Refresh
    $accessBefore = ConvertFrom-AVDTuneSecure $rs.Tokens.Storage.Access
    $rAuth.Store.StorageAud = 'https://storage.azure.com.evil.example'
    $rs.Tokens.Storage.ExpiresOn = (Get-Date).ToUniversalTime().AddMinutes(1)
    $w1 = Get-ThrownText { Get-AVDTuneAccessToken -Session $rs -Audience Storage }
    $w2 = Get-ThrownText { Get-AVDTuneAccessToken -Session $rs -Audience Storage }
    Test-Check 'a refresh with a wrong audience throws, also the second call; the checked token and the refresh token are not replaced by the bad answer' ($w1 -like '*another resource*' -and $w2 -like '*another resource*' -and (ConvertFrom-AVDTuneSecure $rs.Refresh) -eq $refreshBefore -and (ConvertFrom-AVDTuneSecure $rs.Tokens.Storage.Access) -eq $accessBefore) "$w1 | $w2"
    $rAuth.Store.StorageAud = ''
    Test-Check 'with a good answer again the refresh works' ((Get-AVDTuneTokenClaims (Get-AVDTuneAccessToken -Session $rs -Audience Storage)).aud -eq 'https://storage.azure.com') $null
    $rAuth.Store.ConsentMissing = @('Storage'); $rs.Tokens.Storage.ExpiresOn = (Get-Date).ToUniversalTime().AddMinutes(1)
    $w3 = Get-ThrownText { Get-AVDTuneAccessToken -Session $rs -Audience Storage }
    Test-Check 'consent withdrawn later: the refresh says so and gives the Set up again hint; any other refresh error has no hint' ($w3 -like '*Set up again*' -and (Get-ThrownText { $rAuth.Store.ConsentMissing = @(); $rAuth.Store.Offline = $true; $rs.Tokens.Storage.ExpiresOn = (Get-Date).ToUniversalTime().AddMinutes(1); Get-AVDTuneAccessToken -Session $rs -Audience Storage }) -notlike '*Set up again*') "$w3"
    Disconnect-AVDTuneSession $rs
    # ARM: both known audience forms exactly, nothing else
    foreach ($armAud in @('https://management.azure.com', 'https://management.azure.com/', 'https://management.core.windows.net', 'https://management.core.windows.net/')) {
        $ra = New-AVDTuneFakeAuth; $ra.Store.ExpiresIn = 3600
        $raS = New-AVDTuneSession -TempRoot $signTemp -Auth $ra
        [void](Connect-AVDTuneSession -Session $raS -TenantId $tenant -ClientId $clientId)
        $ra.Store.ArmAud = $armAud; $raS.Tokens.Arm.ExpiresOn = (Get-Date).ToUniversalTime().AddMinutes(1)
        $armOk = Get-ThrownText { [void](Get-AVDTuneAccessToken -Session $raS -Audience Arm) }
        Test-Check "ARM audience $armAud is accepted" ($null -eq $armOk) $armOk
        Disconnect-AVDTuneSession $raS
    }
    $ra = New-AVDTuneFakeAuth; $raS = New-AVDTuneSession -TempRoot $signTemp -Auth $ra
    [void](Connect-AVDTuneSession -Session $raS -TenantId $tenant -ClientId $clientId)
    foreach ($badAud in @('https://management.azure.com.evil.example', 'https://management.core.windows.net.evil.example', 'https://storage.azure.com')) {
        $ra.Store.ArmAud = $badAud; $raS.Tokens.Arm.ExpiresOn = (Get-Date).ToUniversalTime().AddMinutes(1)
        Test-Check "ARM audience $badAud is refused" ((Get-ThrownText { [void](Get-AVDTuneAccessToken -Session $raS -Audience Arm) }) -like '*another resource*') $null
    }
    Disconnect-AVDTuneSession $raS
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
        $x = Get-AVDTuneEnvironmentDefaults; $x.TenantId = $Tenant
        [void](Save-AVDTuneEnvironment -Root $r -Answers $x -User 'admin1')
        if ($Client) { [void](Set-AVDTuneEnvironmentSignIn -Root $r -ClientId $Client -User 'admin1') }
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
    Test-Check 'an environment.json with a typed-in tenant stays valid' ((Test-AVDTuneEnvironmentAnswers $old6).Errors.Count -eq 0 -and $old6.TenantId -eq 'contoso.example' -and (Get-AVDTuneStartStages -Context (New-AVDTuneStartContext) -Root $r6)[2].Status -eq 'Done') $null
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
    # the saved client ID is removed from the file itself (Save-AVDTuneEnvironment no longer takes it from the answers)
    $r7File = Get-AVDTuneEnvironmentFile $r7; $r7Path = Join-Path $r7 'environment.json'
    [IO.File]::WriteAllText($r7Path, (($r7File | ConvertTo-Json -Depth 10) -replace '"ClientId":\s*"[^"]*"', '"ClientId": ""'))
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
    $a12 = New-AVDTuneFakeAuth -Seed @{ StorageSpMissing = $true }
    $res12 = Invoke-AVDTuneStartSignIn -Root (& $newRoot '' '') -Session (New-AVDTuneSession -TempRoot $signTemp -Auth $a12) -User 'admin1' -RetryDelaySeconds 0
    Test-Check 'Azure Storage is added to the tenant when its service principal is missing (named in the notes), then consented and the storage token works' ($res12.Info.Connected -and @($res12.Info.Audiences | Where-Object Audience -eq 'Storage').Count -eq 1 -and (@($res12.Notes) -join ' ') -like '*Azure Storage was added to the tenant*' -and @($a12.Log | Where-Object { $_ -eq 'Graph POST /v1.0/servicePrincipals' }).Count -ge 2 -and @($a12.Store.ServicePrincipals | Where-Object { $_.appId -eq 'e406a681-f3d4-42a8-90b6-c2b029497af1' }).Count -eq 1) (@($res12.Notes) -join ' | ')
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
    Test-Check 'the session module talks to graph.microsoft.com, login.microsoftonline.com and names management.azure.com, management.core.windows.net and storage.azure.com only; no Invoke-RestMethod or WebRequest of its own' (@($hosts | Where-Object { $_ -notin 'graph.microsoft.com', 'login.microsoftonline.com', 'management.azure.com', 'storage.azure.com', 'management.core.windows.net', 'localhost' }).Count -eq 0 -and $sessSrc -notmatch 'Invoke-RestMethod|Invoke-WebRequest|WebClient') ($hosts -join ',')
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
    Test-Check 'no change by AVDTune recorded yet: no last change, no first change' ($null -eq (Get-AVDTuneLastChange -Root $tmp) -and -not (Get-AVDTuneState $tmp).FirstChange) (Get-AVDTuneLastChange -Root $tmp)
    $w0 = Get-AVDTuneSnapshotWindow -Root $tmp
    Test-Check 'window at the start of a version without any change: VersionStart, no lower and no upper bound' ($w0.Mode -eq 'VersionStart' -and -not $w0.Lower -and -not $w0.FirstChange) ($w0 | ConvertTo-Json -Compress)
    $list = @(Get-AVDTuneOsDiskSnapshots -Arm $arm -Token $armToken -Vm $vm -Window $w0)
    Test-Check 'snapshots of this OS disk only; the one of another disk is ignored' ($list.Count -eq 1 -and $list[0].Name -like '*30.10.2026*' -and $list[0].ByAVDTune) ($list | ForEach-Object Name)
    $gate = Get-AVDTuneGateStatus -Vm $vm -Snapshots $list -Confirmed $false -Window $w0
    Test-Check 'without a recorded change any finished snapshot counts, also an old one ("from today" is gone)' ($gate.Status -eq 'SnapshotReady' -and $gate.Mode -eq 'VersionStart' -and $gate.Chosen.Name -like '*30.10.2026*') $gate.Status
    Test-Check 'outside Azure: gate status NoVm' ((Get-AVDTuneGateStatus -Vm $noAzure -Snapshots @() -Confirmed $false).Status -eq 'NoVm') $null

    $started = Start-AVDTuneSnapshot -Arm $arm -Token $armToken -Vm $vm -ImageVersion '2026.11.001' -User 'Alex Example' -At $now -NamePattern (Get-AVDTuneEnvironmentAnswers (Get-AVDTuneEnvironment $tmp)).SnapshotNamePattern -ExistingNames @($list | ForEach-Object Name)
    $put = $arm.Store.LastPut
    Test-Check 'snapshot request: incremental, copy of the OS disk, tags image version and user, in the disk region' ($put.properties.incremental -eq $true -and $put.properties.creationData.createOption -eq 'Copy' -and $put.properties.creationData.sourceResourceId -eq $vm.OsDiskId -and $put.tags.ImageVersion -eq '2026.11.001' -and $put.tags.CreatedBy -eq 'Alex Example' -and $put.tags.CreatedWith -eq 'AVDTune' -and $put.location -eq 'westeurope') ($put | ConvertTo-Json -Compress -Depth 5)
    Test-Check 'the snapshot is named by the pattern of the environment and starts as Creating' ($started.Name -eq 'gm-test01_osdisk-15.11.2026-1' -and $started.State -eq 'Creating') ($started | ConvertTo-Json -Compress)
    Test-Check 'snapshot SKU: Standard_LRS when the disk has no incremental snapshot of another SKU' ([string]$put.sku.name -eq 'Standard_LRS') ([string]$put.sku.name)

    # Real finding on the test VM (#60): Azure refuses an incremental snapshot whose SKU differs from the existing incremental snapshots of the disk
    $armZrs = New-AVDTuneFakeArm -Seed @{ Snapshots = @(@{ Name = 'portal-zrs'; Created = $now.AddDays(-1); Sku = 'Standard_ZRS' }) }
    $zrsList = @(Get-AVDTuneOsDiskSnapshots -Arm $armZrs -Token $armToken -Vm $vm)
    Test-Check 'the snapshot list carries the SKU of each snapshot' ($zrsList.Count -eq 1 -and $zrsList[0].Sku -eq 'Standard_ZRS') ($zrsList | ForEach-Object Sku)
    $zrsErr = Get-ThrownText { Start-AVDTuneSnapshot -Arm $armZrs -Token $armToken -Vm $vm -ImageVersion '2026.11.001' -User 'x' -At $now }
    Test-Check 'the fake answers like Azure: an LRS snapshot next to a ZRS one is refused with the Azure text (400)' ($zrsErr -like "*400*Standard_LRS*does not match*Standard_ZRS*") $zrsErr
    $zrsStarted = Start-AVDTuneSnapshot -Arm $armZrs -Token $armToken -Vm $vm -ImageVersion '2026.11.001' -User 'x' -At $now -ExistingSnapshots $zrsList
    Test-Check 'Create snapshot now keeps the SKU of the existing incremental snapshots (Standard_ZRS) and is accepted' ([string]$armZrs.Store.LastPut.sku.name -eq 'Standard_ZRS' -and $zrsStarted.State -eq 'Creating') ([string]$armZrs.Store.LastPut.sku.name)
    $mixed = @([pscustomobject]@{ Incremental = $true; Sku = 'Premium_LRS'; Created = $now }, [pscustomobject]@{ Incremental = $false; Sku = 'Standard_ZRS'; Created = $now.AddHours(1) }, [pscustomobject]@{ Incremental = $true; Sku = 'Standard_ZRS'; Created = $now.AddDays(-2) })
    Test-Check 'snapshot SKU: only Standard_LRS/Standard_ZRS of incremental snapshots count, newest first; otherwise Standard_LRS' ((Get-AVDTuneIncrementalSnapshotSku $mixed) -eq 'Standard_ZRS' -and (Get-AVDTuneIncrementalSnapshotSku @()) -eq 'Standard_LRS' -and (Get-AVDTuneIncrementalSnapshotSku @([pscustomobject]@{ Incremental = $true; Sku = 'standard_zrs'; Created = $now })) -eq 'Standard_LRS') $null
    $guiSource = Get-Content -Raw (Join-Path $repo 'AVDTune-Start.ps1')
    Test-Check 'the window passes the listed snapshots to Start-AVDTuneSnapshot (SKU of the disk kept)' ($guiSource -match 'Start-AVDTuneSnapshot [^\r\n]*-ExistingSnapshots') $null
    Test-Check 'a snapshot that is still being created does not unlock the gate and says why' (@(Get-AVDTuneOsDiskSnapshots -Arm $arm -Token $armToken -Vm $vm -Window $w0 | Where-Object { $_.Name -eq $started.Name -and -not $_.Valid -and $_.Reason -like 'Not finished*' }).Count -eq 1) $null
    $ready = Wait-AVDTuneSnapshot -Arm $arm -Token $armToken -Id $started.Id -PollSeconds 0
    Test-Check 'polling until Succeeded' ($ready.State -eq 'Succeeded') $ready.State
    $list = @(Get-AVDTuneOsDiskSnapshots -Arm $arm -Token $armToken -Vm $vm -Window $w0)
    $gate = Get-AVDTuneGateStatus -Vm $vm -Snapshots $list -Confirmed $false -Window $w0
    Test-Check 'with a finished snapshot the gate waits for the confirmation; the newest one is chosen' ($gate.Status -eq 'SnapshotReady' -and $gate.Chosen.Name -eq $started.Name -and $gate.Chosen.ByAVDTune) $gate.Status
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
    Test-Check 'state.json records typed name, Microsoft account, Windows account, time, snapshot ID, created by AVDTune' ($st.SnapshotGate.SnapshotName -eq $started.Name -and $st.SnapshotGate.SnapshotId -eq $started.Id -and $st.SnapshotGate.CreatedByAVDTune -eq $true -and $st.SnapshotGate.ConfirmedBy -eq 'Max Mustermann' -and $st.SnapshotGate.SignedInAccount -eq 'admin.shared@contoso.example' -and $st.SnapshotGate.WindowsAccount -eq 'GM-TEST01\localadmin' -and $st.SnapshotGate.ConfirmedAt -and $st.SnapshotGate.Text -like 'Ich bestaetige*' -and $st.SnapshotGate.Mode -eq 'VersionStart') ($st.SnapshotGate | ConvertTo-Json -Compress)
    $cl = @(Get-AVDTuneChangeLog -Root $tmp)
    $entry = $cl | Where-Object { $_.Category -eq 'Snapshot' } | Select-Object -First 1
    Test-Check 'the change log entry has the typed name with both accounts, time, snapshot ID, "created by AVDTune: yes" and the start of the version' ($cl.Count -eq $logBefore + 1 -and $entry.SnapshotId -eq $started.Id -and $entry.Text -like "*$($started.Name)*" -and $entry.Text -like '*confirmed by Max Mustermann (Microsoft account admin.shared@contoso.example, Windows account GM-TEST01\localadmin)*' -and $entry.User -eq 'Max Mustermann' -and $entry.Text -like '*created by AVDTune: yes*' -and $entry.Text -like '*start of version 2026.11.001*' -and $entry.Text -match '\d{4}-\d{2}-\d{2} \d{2}:\d{2}') ($entry | ConvertTo-Json -Compress)
    Test-Check 'the confirmation itself is no change of the master (no last change, no first change)' ($null -eq (Get-AVDTuneLastChange -Root $tmp) -and -not (Get-AVDTuneState $tmp).FirstChange) (Get-AVDTuneLastChange -Root $tmp)
    $run = Invoke-AVDTune -Plan ([pscustomobject]@{ Name = 'gate'; Steps = @('setup.gatetest') }) -Catalog @($stepRan) -Machine $machine -Root $tmp -User 'admin1' -SnapshotId $started.Id
    Test-Check 'a change works after the confirmation' ($run.Results[0].Status -eq 'Changed') $run.Results[0].Status
    $st = Get-AVDTuneState $tmp
    Test-Check 'the first change of the version is kept in state.json (start of the run) with the snapshot that was confirmed then' ($st.FirstChange -and ([datetime]$st.FirstChange).ToUniversalTime() -eq ([datetime]$run.Started).ToUniversalTime() -and $st.FirstChangeSnapshotId -eq $started.Id -and $st.PSObject.Properties['VersionBaseline'] -and $null -eq $st.VersionBaseline) ($st | ConvertTo-Json -Compress -Depth 3)
    $firstSeen = $st.FirstChange
    [void](Set-AVDTuneState -Root $tmp -Values @{ LastChange = (Get-Date).AddMinutes(5).ToString('o') })
    $w1 = Get-AVDTuneSnapshotWindow -Root $tmp
    Test-Check 'a later change does not move the first change; the window is Reconnect now' ((Get-AVDTuneState $tmp).FirstChange -eq $firstSeen -and $w1.Mode -eq 'Reconnect' -and $w1.FirstChange) ($w1 | ConvertTo-Json -Compress)
    $listRc = @(Get-AVDTuneOsDiskSnapshots -Arm $arm -Token $armToken -Vm $vm -Window $w1)
    Test-Check 'reconnect: the confirmed snapshot of the version start still counts after the change (no new snapshot per change), also when made less than 10 minutes before the first change' (@($listRc | Where-Object { $_.Id -eq $started.Id -and $_.Valid }).Count -eq 1) ($listRc | ConvertTo-Json -Compress -Depth 2)
    $stages = Get-AVDTuneStartStages -Context (New-AVDTuneStartContext) -Root $tmp
    Test-Check 'the snapshot stage shows Done with the name of the confirming person' (($stages | Where-Object Id -eq 'Snapshot').Status -eq 'Done' -and ($stages | Where-Object Id -eq 'Snapshot').Detail -like '*Max Mustermann*') $null
    Close-AVDTuneWriteGate
    Test-Check 'a new start is closed again (the gate is memory only): read only until a snapshot is confirmed again' (-not (Test-AVDTuneWriteAllowed) -and $null -ne (Get-ThrownText { Invoke-AVDTuneStep -Step $stepRan -Machine $machine -Mode Apply })) $null
    Test-Check 'Get-AVDTuneLastChange also reads run records and automatic change log entries' (@(Get-AVDTuneRun -Root $tmp | Where-Object { $_.Results[0].Status -eq 'Changed' }).Count -ge 1) $null

    # ---------------------------------------------------------------- one snapshot per image version (#27)
    # root rc: version 1 had a change at T0, version 2 started afterwards and made its first change at F; a reconnect in version 2
    $rc = Join-Path $tmp 'issue27-reconnect'; [void](Initialize-AVDTuneState -Root $rc)
    [void](Start-AVDTuneImageVersion -Root $rc -Date ([datetime]'2026-11-01') -User 'admin1')
    $T0 = [datetime]'2026-11-01 10:00'; $F = [datetime]'2026-11-02 09:00'
    [void](Set-AVDTuneState -Root $rc -Values @{ LastChange = $T0.ToString('o') })
    $v2 = Start-AVDTuneImageVersion -Root $rc -Date ([datetime]'2026-11-02') -User 'admin1'
    $wStart = Get-AVDTuneSnapshotWindow -Root $rc
    Test-Check 'new version: the last change of the previous version is the lower bound, no first change yet (VersionStart)' ($v2 -eq '2026.11.002' -and $wStart.Mode -eq 'VersionStart' -and $wStart.Lower -eq $T0 -and -not $wStart.FirstChange -and -not (Get-AVDTuneState $rc).FirstChange) ($wStart | ConvertTo-Json -Compress)
    $armV = New-AVDTuneFakeArm -Seed @{ Snapshots = @(
            @{ Name = 'snap-before-v1-end'; Created = $T0.AddHours(-1) }
            @{ Name = 'snap-5min-after-v1-end'; Created = $T0.AddMinutes(5) }) }
    $listV = @(Get-AVDTuneOsDiskSnapshots -Arm $armV -Token $armToken -Vm $vm -Window $wStart)
    $gateV = Get-AVDTuneGateStatus -Vm $vm -Snapshots $listV -Confirmed $false -Window $wStart
    Test-Check 'counter-test: a new version without a new snapshot does not go (before the end of the previous version, or only 5 minutes after it: VM clock may run behind Azure)' (@($listV | Where-Object Valid).Count -eq 0 -and $gateV.Status -eq 'NoValidSnapshot' -and $gateV.Mode -eq 'VersionStart' -and $gateV.Detail -like '*at least 10 minutes after the last change*clock*' -and $listV[0].Reason -like '*plus 10 minutes*') ($listV | ConvertTo-Json -Compress -Depth 2)
    $forgedV = $listV[0].PSObject.Copy(); $forgedV.Valid = $true
    Test-Check 'attack: a snapshot from before the end of the previous version cannot be confirmed, even when the caller says it is valid; the gate stays shut' ((Get-ThrownText { Confirm-AVDTuneSnapshotGate -Root $rc -Snapshot $forgedV -TypedName 'Alex Example' -ImageVersion $v2 -Machine $machine }) -like '*plus 10 minutes*' -and -not (Test-AVDTuneWriteAllowed)) $null
    $armV2 = New-AVDTuneFakeArm -Seed @{ Snapshots = @(@{ Name = 'snap-after-v1-end'; Created = $T0.AddMinutes(11) }) }
    $listV2 = @(Get-AVDTuneOsDiskSnapshots -Arm $armV2 -Token $armToken -Vm $vm -Window $wStart)
    Test-Check 'a new version with a snapshot after the last change of the previous version goes (10 minutes margin kept)' ($listV2[0].Valid -and (Get-AVDTuneGateStatus -Vm $vm -Snapshots $listV2 -Confirmed $false -Window $wStart).Status -eq 'SnapshotReady') $null
    # first change of version 2 (gate closed: no snapshot id), later snapshots
    [void](Set-AVDTuneState -Root $rc -Values @{ LastChange = $F.AddHours(1).ToString('o'); FirstChange = $F.ToString('o') })
    [void](Set-AVDTuneState -Root $rc -Values @{ LastChange = $F.AddHours(3).ToString('o') })
    $stRc = Get-AVDTuneState $rc
    Test-Check 'the first change of the version is kept once (a later change does not move it); the baseline is the last change of version 1' (([datetime]$stRc.FirstChange) -eq $F -and ([datetime]$stRc.VersionBaseline) -eq $T0 -and -not $stRc.FirstChangeSnapshotId) ($stRc | ConvertTo-Json -Compress -Depth 3)
    $armR = New-AVDTuneFakeArm -Seed @{ Snapshots = @(
            @{ Name = 'snap-a-before-v1-end'; Created = $T0.AddHours(-1) }
            @{ Name = 'snap-b-5min-after-v1-end'; Created = $T0.AddMinutes(5) }
            @{ Name = 'snap-c-v1-end-plus-1h'; Created = $T0.AddHours(1) }
            @{ Name = 'snap-d-2h-before-first-change'; Created = $F.AddHours(-2) }
            @{ Name = 'snap-e-5min-before-first-change'; Created = $F.AddMinutes(-5) }
            @{ Name = 'snap-f-after-first-change'; Created = $F.AddHours(1) }
            @{ Name = 'snap-g-creating'; Created = $F.AddHours(-3); State = 'Creating' }
            @{ Name = 'snap-h-after-last-change'; Created = $F.AddHours(3).AddMinutes(11) }) }
    $wRc = Get-AVDTuneSnapshotWindow -Root $rc
    $listR = @(Get-AVDTuneOsDiskSnapshots -Arm $armR -Token $armToken -Vm $vm -Window $wRc)
    $byName = @{}; foreach ($s in $listR) { $byName[$s.Name] = $s }
    Test-Check 'reconnect list: all snapshots of the disk with name, time, status; newest first' ($listR.Count -eq 8 -and $listR[0].Name -eq 'snap-h-after-last-change' -and $listR[-1].Name -eq 'snap-a-before-v1-end' -and $byName['snap-d-2h-before-first-change'].State -eq 'Succeeded' -and $byName['snap-g-creating'].State -eq 'Creating') (($listR | ForEach-Object Name) -join ',')
    Test-Check 'valid: the start of the version (c and d: after the last change of the previous version, before the first change of this one) or the current state (h: after the last change plus margin; Kind says which); everything else is invalid with a reason' ((@($listR | Where-Object Valid | ForEach-Object Name) -join ',') -eq 'snap-h-after-last-change,snap-d-2h-before-first-change,snap-c-v1-end-plus-1h') (@($listR | Where-Object Valid | ForEach-Object Name) -join ',')
    Test-Check 'counter-test: a snapshot between the changes of the version (an intermediate state) is invalid, with the reason (a rollback would lose changes)' (-not $byName['snap-f-after-first-change'].Valid -and $byName['snap-f-after-first-change'].Reason -like '*Between the changes of this version*first change*lose changes*' -and $byName['snap-h-after-last-change'].Kind -eq 'CurrentState' -and $byName['snap-d-2h-before-first-change'].Kind -eq 'VersionStart') $byName['snap-f-after-first-change'].Reason
    Test-Check 'counter-test: a snapshot from before the end of the previous version is invalid (also 5 minutes after it: clock margin)' (-not $byName['snap-a-before-v1-end'].Valid -and -not $byName['snap-b-5min-after-v1-end'].Valid -and $byName['snap-a-before-v1-end'].Reason -like '*last change before this version*plus 10 minutes*') $byName['snap-a-before-v1-end'].Reason
    Test-Check 'a snapshot less than 10 minutes before the first change is invalid (a VM clock that runs ahead cannot make a later one count); one that is not finished is invalid and says so' (-not $byName['snap-e-5min-before-first-change'].Valid -and $byName['snap-e-5min-before-first-change'].Reason -like '*less than 10 minutes before the first change*' -and -not $byName['snap-g-creating'].Valid -and $byName['snap-g-creating'].Reason -like 'Not finished*') $byName['snap-e-5min-before-first-change'].Reason
    $gateR = Get-AVDTuneGateStatus -Vm $vm -Snapshots $listR -Confirmed $false -Window $wRc
    Test-Check 'reconnect without a new snapshot goes: the newest valid snapshot is preselected, the text names both cases (version start or current state)' ($gateR.Status -eq 'SnapshotReady' -and $gateR.Mode -eq 'Reconnect' -and $gateR.Chosen.Name -eq 'snap-h-after-last-change' -and $gateR.Detail -like '*rollback goes back to the start of the version or to the current state*') $gateR.Detail
    foreach ($bad in 'snap-f-after-first-change', 'snap-a-before-v1-end', 'snap-b-5min-after-v1-end', 'snap-e-5min-before-first-change', 'snap-g-creating') {
        $forgedR = $byName[$bad].PSObject.Copy(); $forgedR.Valid = $true
        $err = Get-ThrownText { Confirm-AVDTuneSnapshotGate -Root $rc -Snapshot $forgedR -TypedName 'Alex Example' -ImageVersion $v2 -Machine $machine }
        Test-Check "attack: $bad cannot be confirmed even when the caller says it is valid; the write gate stays shut" ($err -and -not (Test-AVDTuneWriteAllowed)) $err
    }
    Test-Check 'no confirmed valid snapshot: everything stays read only' (-not (Test-AVDTuneWriteAllowed) -and $null -ne (Get-ThrownText { Invoke-AVDTuneStep -Step $stepRan -Machine $machine -Mode Apply })) $null
    $recordR = Confirm-AVDTuneSnapshotGate -Root $rc -Snapshot $byName['snap-d-2h-before-first-change'] -TypedName 'Max Mustermann' -SignedInAccount 'admin.shared@contoso.example' -WindowsAccount 'GM-TEST01\localadmin' -ImageVersion $v2 -Machine $machine
    $entryR = @(Get-AVDTuneChangeLog -Root $rc | Where-Object { $_.Category -eq 'Snapshot' }) | Select-Object -Last 1
    Test-Check 'reconnect confirmed: gate open, the chosen snapshot and the confirmation are in state.json and in the change log of the version (reconnect, first change, rollback to the version start)' ((Test-AVDTuneWriteAllowed) -and $recordR.SnapshotName -eq 'snap-d-2h-before-first-change' -and $recordR.Mode -eq 'Reconnect' -and (Get-AVDTuneState $rc).SnapshotGate.FirstChange -and $entryR.Text -like '*reconnect in version 2026.11.002*rollback goes back to the start of the version*' -and $entryR.Text -like '*confirmed by Max Mustermann*' -and $entryR.Version -eq $v2) ($entryR | ConvertTo-Json -Compress)
    Test-Check 'the choice itself is no change (last change and first change stay)' (([datetime](Get-AVDTuneState $rc).FirstChange) -eq $F -and (Get-AVDTuneLastChange -Root $rc) -eq $F.AddHours(3)) (Get-AVDTuneLastChange -Root $rc)
    # (b) a snapshot of the current state (after the last change) is valid too, confirms with its kind, and is invalid again after a further change
    $recordH = Confirm-AVDTuneSnapshotGate -Root $rc -Snapshot $byName['snap-h-after-last-change'] -TypedName 'Max Mustermann' -ImageVersion $v2 -Machine $machine
    $entryH = @(Get-AVDTuneChangeLog -Root $rc | Where-Object { $_.Category -eq 'Snapshot' }) | Select-Object -Last 1
    Test-Check 'a snapshot after the last change (current state) can be confirmed; kind and rollback to the current state are in state.json and the change log' ($recordH.SnapshotKind -eq 'CurrentState' -and $recordR.SnapshotKind -eq 'VersionStart' -and (Test-AVDTuneWriteAllowed) -and $entryH.Text -like '*snapshot of the current state*rollback goes back to this current state*') ($entryH | ConvertTo-Json -Compress)
    Close-AVDTuneWriteGate
    [void](Set-AVDTuneState -Root $rc -Values @{ LastChange = $F.AddHours(4).ToString('o') })
    $listH = @(Get-AVDTuneOsDiskSnapshots -Arm $armR -Token $armToken -Vm $vm -Window (Get-AVDTuneSnapshotWindow -Root $rc))
    $hAfter = $listH | Where-Object Name -eq 'snap-h-after-last-change'
    $forgedH = $hAfter.PSObject.Copy(); $forgedH.Valid = $true
    Test-Check 'counter-test: after a further change the current-state snapshot is invalid again (intermediate state); Confirm checks that itself; the version-start ones stay valid' (-not $hAfter.Valid -and $hAfter.Reason -like '*Between the changes*' -and (Get-ThrownText { Confirm-AVDTuneSnapshotGate -Root $rc -Snapshot $forgedH -TypedName 'Alex Example' -ImageVersion $v2 -Machine $machine }) -like '*lose changes*' -and -not (Test-AVDTuneWriteAllowed) -and (@($listH | Where-Object Valid | ForEach-Object Name) -join ',') -eq 'snap-d-2h-before-first-change,snap-c-v1-end-plus-1h') (($listH | ForEach-Object { "$($_.Name)=$($_.Valid)" }) -join ',')
    [void](Confirm-AVDTuneSnapshotGate -Root $rc -Snapshot ($listH | Where-Object Name -eq 'snap-d-2h-before-first-change') -TypedName 'Max Mustermann' -ImageVersion $v2 -Machine $machine)
    # a new version closes the gate when its snapshot is not valid for the new version; keeps it when it is
    [void](Start-AVDTuneImageVersion -Root $rc -Date ([datetime]'2026-11-03') -User 'admin1')
    Test-Check 'a new version closes the open gate: the confirmed snapshot is from before the last change of the previous version (new snapshot needed)' (-not (Test-AVDTuneWriteAllowed) -and ([datetime](Get-AVDTuneState $rc).VersionBaseline) -eq $F.AddHours(4) -and -not (Get-AVDTuneState $rc).FirstChange) $null
    $keep = Join-Path $tmp 'issue27-keep'; [void](Initialize-AVDTuneState -Root $keep); [void](Start-AVDTuneImageVersion -Root $keep -Date ([datetime]'2026-11-01') -User 'admin1')
    [void](Set-AVDTuneState -Root $keep -Values @{ LastChange = $T0.ToString('o') })
    [void](Set-AVDTuneState -Root $keep -Values @{ SnapshotGate = [pscustomobject]@{ SnapshotId = 'x'; SnapshotCreated = $T0.AddHours(1).ToString('o') } })
    Open-AVDTuneWriteGate -SnapshotId 'x' -ConfirmedBy 'Max Mustermann'
    [void](Start-AVDTuneImageVersion -Root $keep -Date ([datetime]'2026-11-02') -User 'admin1')
    Test-Check 'a new version keeps the gate open when the confirmed snapshot is already after the last change of the old version' (Test-AVDTuneWriteAllowed) $null
    Close-AVDTuneWriteGate
    # the snapshot that was confirmed when the first change was made counts in the reconnect list even when it is less than 10 minutes older (id is kept)
    $rg = Join-Path $tmp 'issue27-gateid'; [void](Initialize-AVDTuneState -Root $rg); [void](Start-AVDTuneImageVersion -Root $rg -Date ([datetime]'2026-11-01') -User 'admin1')
    $closeSnap = New-AVDTuneFakeArm -Seed @{ Snapshots = @(@{ Name = 'snap-confirmed-3min-before'; Created = $F.AddMinutes(-3) }; @{ Name = 'snap-other-5min-before'; Created = $F.AddMinutes(-5) }) }
    $closeId = '/subscriptions/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/resourceGroups/rg-example/providers/Microsoft.Compute/snapshots/snap-confirmed-3min-before'
    Open-AVDTuneWriteGate -SnapshotId $closeId -ConfirmedBy 'Max Mustermann' -SnapshotCreated $F.AddMinutes(-3).ToString('o')
    [void](Set-AVDTuneState -Root $rg -Values @{ LastChange = $F.ToString('o') })
    Close-AVDTuneWriteGate
    $listG = @(Get-AVDTuneOsDiskSnapshots -Arm $closeSnap -Token $armToken -Vm $vm -Window (Get-AVDTuneSnapshotWindow -Root $rg))
    Test-Check 'the snapshot that was confirmed at the first change stays valid for the reconnect, another one that close to the change does not' ((@($listG | Where-Object Valid | ForEach-Object Name) -join ',') -eq 'snap-confirmed-3min-before') (($listG | ForEach-Object { "$($_.Name)=$($_.Valid)" }) -join ',')
    # older state.json (before #27): no VersionBaseline, no FirstChange; LastChange counts as the start of the version, so no old snapshot becomes valid
    $ro = Join-Path $tmp 'issue27-old'; [void](Initialize-AVDTuneState -Root $ro); [void](Start-AVDTuneImageVersion -Root $ro -Date ([datetime]'2026-11-01') -User 'admin1')
    $oldState = Get-AVDTuneState $ro
    foreach ($drop in 'VersionBaseline', 'FirstChange', 'FirstChangeSnapshotId') { $oldState.PSObject.Properties.Remove($drop) }
    $oldState | Add-Member -NotePropertyName LastChange -NotePropertyValue $T0.ToString('o') -Force
    [IO.File]::WriteAllText((Join-Path $ro 'state.json'), ($oldState | ConvertTo-Json -Depth 6))
    $wOld = Get-AVDTuneSnapshotWindow -Root $ro
    $armO = New-AVDTuneFakeArm -Seed @{ Snapshots = @(@{ Name = 'old-before-last-change'; Created = $T0.AddHours(-2) }; @{ Name = 'old-5min-after'; Created = $T0.AddMinutes(5) }; @{ Name = 'old-after-last-change'; Created = $T0.AddMinutes(30) }) }
    $listO = @(Get-AVDTuneOsDiskSnapshots -Arm $armO -Token $armToken -Vm $vm -Window $wOld)
    Test-Check 'older state.json without the new fields: LastChange is the start of the version; snapshots before it (or only 5 minutes after it) are invalid, one after it is valid' ($wOld.Mode -eq 'VersionStart' -and $wOld.Lower -eq $T0 -and (@($listO | Where-Object Valid | ForEach-Object Name) -join ',') -eq 'old-after-last-change') (($listO | ForEach-Object { "$($_.Name)=$($_.Valid)" }) -join ',')
    [void](Set-AVDTuneState -Root $ro -Values @{ LastChange = $T0.AddHours(2).ToString('o') })
    $stOld = Get-AVDTuneState $ro
    Test-Check 'older state.json, first change with the new code: the old LastChange becomes the baseline (nothing before it becomes valid), the new change the first change' (([datetime]$stOld.VersionBaseline) -eq $T0 -and ([datetime]$stOld.FirstChange) -eq $T0.AddHours(2)) ($stOld | ConvertTo-Json -Compress -Depth 3)
    # a change that only the change log knows (not state.json) still keeps the lower bound strict
    $rx = Join-Path $tmp 'issue27-unrecorded'; [void](Initialize-AVDTuneState -Root $rx); [void](Start-AVDTuneImageVersion -Root $rx -Date ([datetime]'2026-11-01') -User 'admin1')
    [void](Add-AVDTuneChangeLogEntry -Root $rx -Version '2026.11.001' -Category 'Setup' -Component 'x' -ChangeType Changed -Text 'a change without state.json' -User 'admin1' -Source Step -At $T0)
    Test-Check 'a change that only the change log knows keeps the strict rule (lower bound = that change, no first change)' ((Get-AVDTuneSnapshotWindow -Root $rx).Lower -eq $T0 -and -not (Get-AVDTuneSnapshotWindow -Root $rx).FirstChange) $null

    # ---------------------------------------------------------------- findings of the security review of #27
    # 1: a change in progress (marker): first change = its start, no new version, no snapshot as the current state meanwhile
    $rp = Join-Path $tmp 'issue27-progress'; [void](Initialize-AVDTuneState -Root $rp); [void](Start-AVDTuneImageVersion -Root $rp -Date ([datetime]'2026-11-01') -User 'admin1')
    $tStart = (Get-Date).AddHours(-2)
    $owner = Start-AVDTuneChange -Root $rp -At $tStart
    Test-Check 'change in progress: the marker is set (owner, live) and nothing counts as a change yet' ($owner -and (Test-AVDTuneChangeInProgress -Root $rp) -and -not (Get-AVDTuneState $rp).FirstChange) $null
    Test-Check 'a second start in the same process does not take the marker over (nested operation)' (-not (Start-AVDTuneChange -Root $rp)) $null
    Test-Check 'counter-test: a new image version is refused while a change runs; the version stays' ((Get-ThrownText { Start-AVDTuneImageVersion -Root $rp -Date ([datetime]'2026-11-02') -User 'admin1' }) -like '*changing the master right now*' -and (Get-AVDTuneState $rp).ImageVersion -eq '2026.11.001') $null
    [void](Set-AVDTuneState -Root $rp -Values @{ LastChange = (Get-Date).ToString('o') })
    $stP = Get-AVDTuneState $rp
    Test-Check 'the first change of the version is the START of the operation, not the moment its end is written' (([datetime]$stP.FirstChange).ToUniversalTime() -eq $tStart.ToUniversalTime()) ($stP | ConvertTo-Json -Compress -Depth 3)
    $wP = Get-AVDTuneSnapshotWindow -Root $rp
    $armP = New-AVDTuneFakeArm -Seed @{ Snapshots = @(@{ Name = 'snap-before-start'; Created = $tStart.AddMinutes(-30) }; @{ Name = 'snap-during-change'; Created = (Get-Date).AddMinutes(30) }) }
    $listP = @(Get-AVDTuneOsDiskSnapshots -Arm $armP -Token $armToken -Vm $vm -Window $wP); $bP = @{}; foreach ($s in $listP) { $bP[$s.Name] = $s }
    Test-Check 'counter-test: a snapshot made while a change runs is neither version start nor current state; one from before the start still is valid' ($wP.InProgress -and -not $bP['snap-during-change'].Valid -and $bP['snap-during-change'].Reason -like '*changing the master right now*' -and $bP['snap-before-start'].Valid -and $bP['snap-before-start'].Kind -eq 'VersionStart') (($listP | ForEach-Object { "$($_.Name)=$($_.Valid)" }) -join ',')
    Stop-AVDTuneChange -Root $rp -Owner $true
    Test-Check 'after the change the marker is gone and a new version may start' (-not (Test-AVDTuneChangeInProgress -Root $rp) -and (Start-AVDTuneImageVersion -Root $rp -Date ([datetime]'2026-11-02') -User 'admin1') -eq '2026.11.002') $null
    $listP2 = @(Get-AVDTuneOsDiskSnapshots -Arm $armP -Token $armToken -Vm $vm -Window (Get-AVDTuneSnapshotWindow -Root $rp))
    Test-Check 'the snapshot made during the change of the old version does not count for the new one (it is before its end plus margin)' (@($listP2 | Where-Object { $_.Name -eq 'snap-before-start' -and $_.Valid }).Count -eq 0) (($listP2 | ForEach-Object { "$($_.Name)=$($_.Valid)" }) -join ',')
    # a marker of a process that is gone (crash): resolved as a change that ended when it is found, nothing is blocked for ever
    $rs = Join-Path $tmp 'issue27-stale'; [void](Initialize-AVDTuneState -Root $rs); [void](Start-AVDTuneImageVersion -Root $rs -Date ([datetime]'2026-11-01') -User 'admin1')
    [void](Set-AVDTuneState -Root $rs -Values @{ ChangeInProgress = [ordered]@{ Started = (Get-Date).AddHours(-1).ToUniversalTime().ToString('o'); Pid = 2147480000 } })
    Test-Check 'a marker of a dead process is no running change; a new version may start and the marker is turned into a last change' (-not (Test-AVDTuneChangeInProgress -Root $rs) -and (Start-AVDTuneImageVersion -Root $rs -Date ([datetime]'2026-11-02') -User 'admin1') -eq '2026.11.002' -and -not (Get-AVDTuneChangeMarker -Root $rs) -and (Get-AVDTuneLastChange -Root $rs) -gt (Get-Date).AddMinutes(-2)) $null

    # 2: older state.json without LastChange but with run records: the baseline comes from the evidence, the lower bound is not lifted
    $rm = Join-Path $tmp 'issue27-migrate'; [void](Initialize-AVDTuneState -Root $rm); [void](Start-AVDTuneImageVersion -Root $rm -Date ([datetime]'2026-11-01') -User 'admin1')
    [void](Add-AVDTuneRun -Root $rm -Run ([pscustomobject]@{ Id = 'old-run'; Plan = 'old'; Started = $T0.AddMinutes(-5).ToString('o'); Ended = $T0.ToString('o'); WhatIf = $false; Results = @([pscustomobject]@{ Id = 'a'; Mode = 'Apply'; Status = 'Changed' }) }))
    $stM = Get-AVDTuneState $rm; foreach ($drop in 'VersionBaseline', 'FirstChange', 'FirstChangeSnapshotId', 'LastChange') { $stM.PSObject.Properties.Remove($drop) }
    [IO.File]::WriteAllText((Join-Path $rm 'state.json'), ($stM | ConvertTo-Json -Depth 6))
    Test-Check 'older state.json without LastChange but a run record: the lower bound is that run (not lifted)' ((Get-AVDTuneSnapshotWindow -Root $rm).Lower -eq $T0) ((Get-AVDTuneSnapshotWindow -Root $rm).Lower)
    [void](Set-AVDTuneState -Root $rm -Values @{ LastChange = $T0.AddHours(3).ToString('o') })
    $wM = Get-AVDTuneSnapshotWindow -Root $rm
    $armM = New-AVDTuneFakeArm -Seed @{ Snapshots = @(@{ Name = 'm-before-run'; Created = $T0.AddHours(-1) }; @{ Name = 'm-after-run'; Created = $T0.AddHours(1) }) }
    $listM = @(Get-AVDTuneOsDiskSnapshots -Arm $armM -Token $armToken -Vm $vm -Window $wM)
    Test-Check 'counter-test: after the first change with the new code the baseline is the run record, a snapshot from before that run is invalid, one after it is valid' (([datetime](Get-AVDTuneState $rm).VersionBaseline) -eq $T0 -and $wM.Lower -eq $T0 -and (@($listM | Where-Object Valid | ForEach-Object Name) -join ',') -eq 'm-after-run') (($listM | ForEach-Object { "$($_.Name)=$($_.Valid)" }) -join ',')
    # no evidence at all: nothing ever changed, no lower bound
    $rn = Join-Path $tmp 'issue27-never'; [void](Initialize-AVDTuneState -Root $rn); [void](Start-AVDTuneImageVersion -Root $rn -Date ([datetime]'2026-11-01') -User 'admin1')
    Test-Check 'no change anywhere: no lower bound (proof that nothing ever changed)' (-not (Get-AVDTuneSnapshotWindow -Root $rn).Lower) $null

    # a first change is recorded, VersionBaseline is empty, but the run records know an earlier change: the lower bound is that change
    $rl = Join-Path $tmp 'issue27-lowerevidence'; [void](Initialize-AVDTuneState -Root $rl); [void](Start-AVDTuneImageVersion -Root $rl -Date ([datetime]'2026-11-01') -User 'admin1')
    [void](Add-AVDTuneRun -Root $rl -Run ([pscustomobject]@{ Id = 'earlier-run'; Plan = 'x'; Started = $T0.AddMinutes(-5).ToString('o'); Ended = $T0.ToString('o'); WhatIf = $false; Results = @([pscustomobject]@{ Id = 'a'; Mode = 'Apply'; Status = 'Changed' }) }))
    [void](Set-AVDTuneState -Root $rl -Values @{ VersionBaseline = $null; FirstChange = $F.ToString('o'); LastChange = $F.AddHours(1).ToString('o') })
    $wL = Get-AVDTuneSnapshotWindow -Root $rl
    $armL = New-AVDTuneFakeArm -Seed @{ Snapshots = @(@{ Name = 'l-before-earlier-run'; Created = $T0.AddHours(-1) }; @{ Name = 'l-after-earlier-run'; Created = $T0.AddHours(1) }) }
    $listL = @(Get-AVDTuneOsDiskSnapshots -Arm $armL -Token $armToken -Vm $vm -Window $wL)
    Test-Check 'counter-test: the lower bound is not only the baseline: an earlier change in the run records lifts it (a snapshot from before it is invalid)' ($wL.Lower -eq $T0 -and (@($listL | Where-Object Valid | ForEach-Object Name) -join ',') -eq 'l-after-earlier-run') (($listL | ForEach-Object { "$($_.Name)=$($_.Valid)" }) -join ',')
    # 3: the exception for the snapshot confirmed at the first change needs the same ID AND creation time, and obeys the lower bound
    $re = Join-Path $tmp 'issue27-reuse'; [void](Initialize-AVDTuneState -Root $re); [void](Start-AVDTuneImageVersion -Root $re -Date ([datetime]'2026-11-01') -User 'admin1')
    $idX = '/subscriptions/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/resourceGroups/rg-example/providers/Microsoft.Compute/snapshots/snap-reused'
    Open-AVDTuneWriteGate -SnapshotId $idX -ConfirmedBy 'Max Mustermann' -SnapshotCreated $F.AddMinutes(-3).ToString('o')
    [void](Set-AVDTuneState -Root $re -Values @{ LastChange = $F.AddHours(1).ToString('o'); FirstChange = $F.ToString('o') })
    Close-AVDTuneWriteGate
    $armRe = New-AVDTuneFakeArm -Seed @{ Snapshots = @(@{ Name = 'snap-reused'; Created = $F.AddMinutes(-3) }) }
    Test-Check 'the confirmed snapshot (same ID, same creation time) stays valid between 10 minutes and the first change' ((@(Get-AVDTuneOsDiskSnapshots -Arm $armRe -Token $armToken -Vm $vm -Window (Get-AVDTuneSnapshotWindow -Root $re) | Where-Object Valid).Count) -eq 1) $null
    $armRe2 = New-AVDTuneFakeArm -Seed @{ Snapshots = @(@{ Name = 'snap-reused'; Created = $F.AddMinutes(-2) }) }
    $listRe2 = @(Get-AVDTuneOsDiskSnapshots -Arm $armRe2 -Token $armToken -Vm $vm -Window (Get-AVDTuneSnapshotWindow -Root $re))
    Test-Check 'counter-test: a snapshot that was deleted and made again under the same name (other creation time) does not inherit the exception' (-not $listRe2[0].Valid -and $listRe2[0].Reason -like '*less than 10 minutes before the first change*') $listRe2[0].Reason
    [void](Set-AVDTuneState -Root $re -Values @{ VersionBaseline = $F.AddMinutes(-5).ToString('o') })
    Test-Check 'counter-test: the exception obeys the lower bound (the previous version ended after that snapshot)' (-not @(Get-AVDTuneOsDiskSnapshots -Arm $armRe -Token $armToken -Vm $vm -Window (Get-AVDTuneSnapshotWindow -Root $re))[0].Valid) $null

    # 4: a failed step counts as a change (a failed Apply can leave changes behind); the marker is gone afterwards
    $rf = Join-Path $tmp 'issue27-failed'; [void](Initialize-AVDTuneState -Root $rf); [void](Start-AVDTuneImageVersion -Root $rf -Date ([datetime]'2026-11-01') -User 'admin1')
    Open-AVDTuneWriteGate -SnapshotId $idX -ConfirmedBy 'Max Mustermann' -SnapshotCreated (Get-Date).AddHours(-1).ToString('o')
    $badStep = New-AVDTuneStep -Id 'setup.failing' -Section Setup -Title 'Fails' -Test { param($m) @{ Compliant = $false; State = $null } } -Apply { param($m) throw 'half done' }
    $runF = Invoke-AVDTune -Plan ([pscustomobject]@{ Name = 'failing'; Steps = @('setup.failing') }) -Catalog @($badStep) -Machine $machine -Root $rf -User 'admin1' -SnapshotId $idX
    $stF = Get-AVDTuneState $rf
    Test-Check 'counter-test: a plan whose step failed still sets LastChange and FirstChange (start of the run), and the marker is cleared' ($runF.Results[0].Status -eq 'Failed' -and $stF.LastChange -and $stF.FirstChange -and ([datetime]$stF.FirstChange).ToUniversalTime() -le ([datetime]$stF.LastChange).ToUniversalTime() -and $null -eq $stF.ChangeInProgress -and (Get-AVDTuneLastChange -Root $rf)) ($stF | ConvertTo-Json -Compress -Depth 3)
    $rf2 = Join-Path $tmp 'issue27-failed2'; [void](Initialize-AVDTuneState -Root $rf2); [void](Start-AVDTuneImageVersion -Root $rf2 -Date ([datetime]'2026-11-01') -User 'admin1')
    [void](Add-AVDTuneRun -Root $rf2 -Run ([pscustomobject]@{ Id = 'failed-run'; Plan = 'x'; Started = $T0.ToString('o'); Ended = $T0.ToString('o'); WhatIf = $false; Results = @([pscustomobject]@{ Id = 'a'; Mode = 'Apply'; Status = 'Failed' }) }))
    [void](Add-AVDTuneRun -Root $rf2 -Run ([pscustomobject]@{ Id = 'dry-run'; Plan = 'x'; Started = $T0.AddHours(1).ToString('o'); Ended = $T0.AddHours(1).ToString('o'); WhatIf = $true; Results = @([pscustomobject]@{ Id = 'a'; Mode = 'Apply'; Status = 'Changed' }) }))
    Test-Check 'a failed run record is a change (LastChange), a dry run is not' ((Get-AVDTuneLastChange -Root $rf2) -eq $T0) (Get-AVDTuneLastChange -Root $rf2)
    Close-AVDTuneWriteGate

    # 5: Confirm reads the snapshot again; the caller's word about time, state and source does not count
    $rv = Join-Path $tmp 'issue27-verify'; [void](Initialize-AVDTuneState -Root $rv); [void](Start-AVDTuneImageVersion -Root $rv -Date ([datetime]'2026-11-01') -User 'admin1')
    $armV5 = New-AVDTuneFakeArm -Seed @{ DiskUniqueId = 'disk-unique-1'; Snapshots = @(
            @{ Name = 'v5-good'; Created = (Get-Date).AddHours(-1); SourceUniqueId = 'disk-unique-1' }
            @{ Name = 'v5-other-disk'; Created = (Get-Date).AddHours(-1); Source = '/subscriptions/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/resourceGroups/rg-example/providers/Microsoft.Compute/disks/another_disk' }
            @{ Name = 'v5-recreated-disk'; Created = (Get-Date).AddHours(-1); SourceUniqueId = 'disk-unique-OTHER' }
            @{ Name = 'v5-creating'; Created = (Get-Date).AddHours(-1); State = 'Creating' }) }
    $infoV5 = @{}; foreach ($s in @(Get-AVDTuneOsDiskSnapshots -Arm $armV5 -Token $armToken -Vm $vm)) { $infoV5[$s.Name] = $s }
    foreach ($n in 'v5-other-disk', 'v5-recreated-disk', 'v5-creating') {
        $f5 = $(if ($infoV5.ContainsKey($n)) { $infoV5[$n] } else { $infoV5['v5-good'] }).PSObject.Copy(); $f5.State = 'Succeeded'; $f5.Finished = $true; $f5.Valid = $true; $f5.Created = (Get-Date).AddHours(-1)
        if ($n -eq 'v5-other-disk') { $f5.Id = '/subscriptions/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/resourceGroups/rg-example/providers/Microsoft.Compute/snapshots/v5-other-disk' }
        $err = Get-ThrownText { Confirm-AVDTuneSnapshotGate -Root $rv -Snapshot $f5 -TypedName 'Alex Example' -ImageVersion '2026.11.001' -Machine $machine -Arm $armV5 -Token $armToken -Vm $vm }
        Test-Check "counter-test: $n cannot be confirmed although the caller says it is finished and valid (Azure is asked again); the gate stays shut" ($err -and -not (Test-AVDTuneWriteAllowed)) $err
    }
    $liar = $infoV5['v5-good'].PSObject.Copy(); $liar.Created = (Get-Date).AddDays(-30)
    $recV5 = Confirm-AVDTuneSnapshotGate -Root $rv -Snapshot $liar -TypedName 'Alex Example' -ImageVersion '2026.11.001' -Machine $machine -Arm $armV5 -Token $armToken -Vm $vm
    Test-Check 'the creation time in the record is the one from Azure, not the one the caller passed; the gate remembers it' ((([datetime]$recV5.SnapshotCreated) - $infoV5['v5-good'].Created).TotalSeconds -lt 1 -and (Test-AVDTuneWriteAllowed) -and (Get-AVDTuneWriteGate).SnapshotCreated) $recV5.SnapshotCreated
    Close-AVDTuneWriteGate

    # 6: a new version keeps an open gate only for the snapshot the gate was opened with (state.json says which one and when)
    $rk = Join-Path $tmp 'issue27-gateswap'; [void](Initialize-AVDTuneState -Root $rk); [void](Start-AVDTuneImageVersion -Root $rk -Date ([datetime]'2026-11-01') -User 'admin1')
    [void](Set-AVDTuneState -Root $rk -Values @{ LastChange = $T0.ToString('o') })
    [void](Set-AVDTuneState -Root $rk -Values @{ SnapshotGate = [pscustomobject]@{ SnapshotId = 'confirmed-in-state'; SnapshotCreated = $T0.AddHours(1).ToString('o') } })
    Open-AVDTuneWriteGate -SnapshotId 'another-one-in-memory' -ConfirmedBy 'Max Mustermann'
    [void](Start-AVDTuneImageVersion -Root $rk -Date ([datetime]'2026-11-02') -User 'admin1')
    Test-Check 'counter-test: the open gate belongs to another snapshot than state.json says: the new version closes it' (-not (Test-AVDTuneWriteAllowed)) $null

    # ---------------------------------------------------------------- second review of #27: the end is stamped, the marker is tied to its process
    # the end is stamped by Stop (also after an abort, before any LastChange was written); FirstChange comes from the marker
    $r2 = Join-Path $tmp 'issue27-stop'; [void](Initialize-AVDTuneState -Root $r2); [void](Start-AVDTuneImageVersion -Root $r2 -Date ([datetime]'2026-11-01') -User 'admin1')
    $t2 = (Get-Date).AddHours(-2)
    $o2 = Start-AVDTuneChange -Root $r2 -At $t2
    Stop-AVDTuneChange -Root $r2 -Owner $o2
    $st2 = Get-AVDTuneState $r2
    $w2 = Get-AVDTuneSnapshotWindow -Root $r2
    Test-Check 'counter-test: start, abort, stop: LastChange is the end (now), FirstChange the start, the marker is gone; a snapshot made mid-change is invalid' ($st2.LastChange -and ([datetime]$st2.LastChange) -gt (Get-Date).AddMinutes(-2) -and ([datetime]$st2.FirstChange).ToUniversalTime() -eq $t2.ToUniversalTime() -and $null -eq $st2.ChangeInProgress -and -not (Test-AVDTuneSnapshotInWindow -Created $t2.AddMinutes(30) -Id 'x' -Window $w2).Valid) ($st2 | ConvertTo-Json -Compress -Depth 3)
    $r3 = Join-Path $tmp 'issue27-stop2'; [void](Initialize-AVDTuneState -Root $r3); [void](Start-AVDTuneImageVersion -Root $r3 -Date ([datetime]'2026-11-01') -User 'admin1')
    $o3 = Start-AVDTuneChange -Root $r3 -At $t2
    [void](Set-AVDTuneState -Root $r3 -Values @{ LastChange = $t2.ToString('o') })   # the Updates pattern: LastChange at the start, then the run
    Stop-AVDTuneChange -Root $r3 -Owner $o3
    Test-Check 'counter-test: LastChange at the start and a long run: Stop moves it to the end, so a snapshot from the middle of the run is invalid' (([datetime](Get-AVDTuneState $r3).LastChange) -gt (Get-Date).AddMinutes(-2) -and -not (Test-AVDTuneSnapshotInWindow -Created $t2.AddMinutes(30) -Id 'x' -Window (Get-AVDTuneSnapshotWindow -Root $r3)).Valid) $null

    # the marker is tied to its process (PID, start time, name) and to 12 hours; a foreign live one stops a second writer
    $child = Start-Process -FilePath (Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell\v1.0\powershell.exe') -ArgumentList '-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 120' -WindowStyle Hidden -PassThru
    try {
        Start-Sleep -Milliseconds 800
        $r4 = Join-Path $tmp 'issue27-pid'; [void](Initialize-AVDTuneState -Root $r4); [void](Start-AVDTuneImageVersion -Root $r4 -Date ([datetime]'2026-11-01') -User 'admin1')
        $cs = $child.StartTime.ToUniversalTime().ToString('o'); $cn = $child.ProcessName
        $setMarker = { param($started, $pidv, $pstart, $pname) [void](Set-AVDTuneState -Root $r4 -Values @{ ChangeInProgress = [ordered]@{ Started = $started; Pid = $pidv; ProcessStart = $pstart; ProcessName = $pname } }) }
        & $setMarker (Get-Date).AddMinutes(-5).ToUniversalTime().ToString('o') $child.Id $cs $cn
        Test-Check 'a marker of a live foreign process (PID, start time and name match) is running' ((Get-AVDTuneChangeMarker -Root $r4).Live -and (Test-AVDTuneChangeInProgress -Root $r4)) $null
        Test-Check 'counter-test: a second writer does not start while a foreign process holds the marker (it throws); the new version is refused too' ((Get-ThrownText { Start-AVDTuneChange -Root $r4 }) -like '*Another AVDTune process*' -and (Get-ThrownText { Start-AVDTuneImageVersion -Root $r4 -Date ([datetime]'2026-11-02') -User 'admin1' }) -like '*changing the master right now*') $null
        & $setMarker (Get-Date).AddDays(-3).ToUniversalTime().ToString('o') $child.Id (Get-Date).AddDays(-3).ToUniversalTime().ToString('o') $cn
        Test-Check 'counter-test: a reused PID (same PID and name, other start time) is not the process of the marker' (-not (Get-AVDTuneChangeMarker -Root $r4).Live) $null
        & $setMarker (Get-Date).AddMinutes(-5).ToUniversalTime().ToString('o') $child.Id $cs 'notepad'
        Test-Check 'counter-test: another process name is not the process of the marker' (-not (Get-AVDTuneChangeMarker -Root $r4).Live) $null
        & $setMarker (Get-Date).AddHours(-13).ToUniversalTime().ToString('o') $child.Id $cs $cn
        Test-Check 'counter-test: a marker older than 12 hours counts as gone even when PID, start time and name match' (-not (Get-AVDTuneChangeMarker -Root $r4).Live) $null
        & $setMarker (Get-Date).AddMinutes(-5).ToUniversalTime().ToString('o') $child.Id $null $null
        Test-Check 'a marker without process start (not written by this version) counts as gone' (-not (Get-AVDTuneChangeMarker -Root $r4).Live) $null
        & $setMarker (Get-Date).AddDays(-3).ToUniversalTime().ToString('o') $child.Id (Get-Date).AddDays(-3).ToUniversalTime().ToString('o') $cn
        Test-Check 'after a reused PID the new version and the next change are not blocked for ever' ((Start-AVDTuneChange -Root $r4) -and (Test-AVDTuneChangeInProgress -Root $r4)) $null
        Stop-AVDTuneChange -Root $r4
    }
    finally { if ($child -and -not $child.HasExited) { $child.Kill() } }

    # Confirm without Azure (-Arm) only in the test mode (Test-AVDTuneTestMode), not by an environment variable alone
    $rt = Join-Path $tmp 'issue27-notestmode'; [void](Initialize-AVDTuneState -Root $rt); [void](Start-AVDTuneImageVersion -Root $rt -Date ([datetime]'2026-11-01') -User 'admin1')
    $snapT = (Get-AVDTuneOsDiskSnapshots -Arm (New-AVDTuneFakeArm -Seed @{ Snapshots = @(@{ Name = 't-snap'; Created = (Get-Date).AddHours(-1) }) }) -Token $armToken -Vm $vm)[0]
    $savedFake = $env:AVDTUNE_FAKE; $savedRoot = $env:AVDTUNE_ROOT
    try {
        $env:AVDTUNE_FAKE = $null; $env:AVDTUNE_ROOT = $null
        $errT = Get-ThrownText { Confirm-AVDTuneSnapshotGate -Root $rt -Snapshot $snapT -TypedName 'Alex Example' -ImageVersion '2026.11.001' -Machine $machine }
    }
    finally { $env:AVDTUNE_FAKE = $savedFake; $env:AVDTUNE_ROOT = $savedRoot }
    Test-Check 'counter-test: no test mode and no -Arm: Confirm is refused, the gate stays shut' ($errT -like '*only the test mode*' -and -not (Test-AVDTuneWriteAllowed)) $errT
    Test-Check 'in the test mode Confirm without -Arm still works (the checks above)' ((Test-AVDTuneTestMode).Enabled) $null
    Close-AVDTuneWriteGate

    # 9: a snapshot that is Succeeded but not complete (Premium SSD v2 / Ultra) is not finished
    $armU = New-AVDTuneFakeArm -Seed @{ Snapshots = @(@{ Name = 'u-half'; Created = (Get-Date).AddHours(-1); Percent = 40 }; @{ Name = 'u-full'; Created = (Get-Date).AddHours(-1); Percent = 100; AccessState = 'Available' }; @{ Name = 'u-pending'; Created = (Get-Date).AddHours(-1); AccessState = 'Pending' }; @{ Name = 'u-plain'; Created = (Get-Date).AddHours(-1) }) }
    $lu = @{}; foreach ($s in @(Get-AVDTuneOsDiskSnapshots -Arm $armU -Token $armToken -Vm $vm)) { $lu[$s.Name] = $s }
    Test-Check 'completionPercent below 100 or an access state other than Available is not finished; a snapshot without these fields counts as before' (-not $lu['u-half'].Valid -and $lu['u-half'].Reason -like 'Not finished (40 percent)*' -and -not $lu['u-pending'].Valid -and $lu['u-pending'].Reason -like 'Not usable yet*' -and $lu['u-full'].Valid -and $lu['u-plain'].Valid) (($lu.Values | ForEach-Object { "$($_.Name)=$($_.Valid)" }) -join ',')
    Close-AVDTuneWriteGate
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
    Test-Check 'with a DC: sign-in pending, domain locked, questions done, snapshot locked' (($st | ForEach-Object Status) -join ',' -eq 'Pending,Locked,Done,Locked') (($st | ForEach-Object Status) -join ',')
    $s7 = New-AVDTuneSession -TempRoot $signTemp -Auth (New-AVDTuneFakeAuth); [void](Connect-AVDTuneSession -Session $s7 -TenantId $tenant -ClientId $clientId); $ctx2.Session = $s7
    $st = Get-AVDTuneStartStages -Context $ctx2 -Root $tmp
    Test-Check 'after the sign-in the domain stage is pending' (($st | ForEach-Object Status) -join ',' -eq 'Done,Pending,Done,Locked') (($st | ForEach-Object Status) -join ',')
    $ctx2.Directory = $info; $ctx2.DirectorySecurity = 'LDAPS 636, certificate pinned'
    $st2 = Get-AVDTuneStartStages -Context $ctx2 -Root $tmp
    Test-Check 'after the domain is read: done with the facts, snapshot pending' ((($st2 | ForEach-Object Status) -join ',' -eq 'Done,Done,Done,Pending') -and ($st2[1].Detail -like '*example.test*EXAMPLE*4 OUs*3 groups*Default-First-Site-Name*pinned*')) $st2[1].Detail
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

    # ---------------------------------------------------------------- start order (#64): sign-in, domain, questions (suggested, confirmed), snapshot
    $seedJoined = { param([bool]$Domain, [bool]$Entra, [string]$Name = 'Example.Test', $Dc = $null)
        New-AVDTuneFakeMachine -Seed @{
            ComputerSystem = [pscustomobject]@{ PartOfDomain = $Domain; Domain = $(if ($Domain) { $Name } else { 'WORKGROUP' }); DomainRole = $(if ($Domain) { 3 } else { 2 }) }
            DcLocate = $Dc
            Native = @{ 'dsregcmd.exe /status' = @{ ExitCode = 0; Output = "| Device State |`r`n    AzureAdJoined : $(if ($Entra) { 'YES' } else { 'NO' })`r`n  EnterpriseJoined : NO`r`n    DomainJoined : $(if ($Domain) { 'YES' } else { 'NO' })`r`n" } } } }
    $dcFound = [pscustomobject]@{ Name = 'DC1.Example.Test.'; Address = '10.0.0.10'; Site = 'Default-First-Site-Name' }

    # join detection: joined, Entra only, not joined, unreadable
    $mj = & $seedJoined $true $true 'Example.Test' $dcFound
    $jHybrid = Get-AVDTuneJoinState -Machine $mj
    Test-Check 'join state, domain member (hybrid): Hybrid, the domain, the DC from the locator, a DC step is needed' ($jHybrid.Kind -eq 'Hybrid' -and $jHybrid.NeedsDc -and $jHybrid.DomainName -eq 'example.test' -and $jHybrid.Dc.Name -eq 'dc1.example.test' -and $jHybrid.Dc.Address -eq '10.0.0.10' -and $jHybrid.Dc.Site -eq 'Default-First-Site-Name' -and @($mj.Log) -contains 'DcLocate example.test') ($jHybrid | ConvertTo-Json -Compress -Depth 3)
    $jAd = Get-AVDTuneJoinState -Machine (& $seedJoined $true $false 'Example.Test' $dcFound)
    Test-Check 'join state, domain member without Entra: AdDs' ($jAd.Kind -eq 'AdDs' -and $jAd.NeedsDc -and -not $jAd.EntraJoined) $jAd.Kind
    $mE = & $seedJoined $false $true
    $jEntra = Get-AVDTuneJoinState -Machine $mE
    Test-Check 'join state, Entra only: no DC step, the reason says so, the DC locator is not asked' ($jEntra.Kind -eq 'EntraOnly' -and -not $jEntra.NeedsDc -and $jEntra.Reason -like '*Microsoft Entra ID only*' -and $null -eq $jEntra.Dc -and @($mE.Log | Where-Object { $_ -like 'DcLocate*' }).Count -eq 0) $jEntra.Reason
    $jNone = Get-AVDTuneJoinState -Machine (& $seedJoined $false $false)
    Test-Check 'join state, not joined: no DC step, the reason says so' ($jNone.Kind -eq 'NotJoined' -and -not $jNone.NeedsDc -and $jNone.Reason -like '*not joined*') $jNone.Reason
    $mU = New-AVDTuneFakeMachine -Seed @{ ComputerSystem = $null; Native = @{ 'dsregcmd.exe /status' = @{ ExitCode = 1; Output = '' } } }
    $jUnk = Get-AVDTuneJoinState -Machine $mU
    Test-Check 'join state, nothing readable: Unknown, no DC step, the problems are named' ($jUnk.Kind -eq 'Unknown' -and -not $jUnk.NeedsDc -and @($jUnk.Problems).Count -ge 2) ($jUnk.Problems -join ' | ')
    $jNoLoc = Get-AVDTuneJoinState -Machine (& $seedJoined $true $false 'Example.Test' $null)
    Test-Check 'join state, domain member but the DC locator finds nothing: a DC step without a suggested server, the problem is named' ($jNoLoc.NeedsDc -and $null -eq $jNoLoc.Dc -and (@($jNoLoc.Problems) -join ' ') -like '*DC locator found no domain controller*') ($jNoLoc.Problems -join ' | ')
    # detected values are data: a name that is no DNS name, an address that is no IPv4 address are dropped
    $badDomainM = & $seedJoined $true $false 'ex ample;calc' $dcFound
    $jBadDomain = Get-AVDTuneJoinState -Machine $badDomainM
    Test-Check 'a detected domain name that is not a DNS name is dropped (no DC locator call with it)' ($jBadDomain.DomainName -eq '' -and $null -eq $jBadDomain.Dc -and @($badDomainM.Log | Where-Object { $_ -like 'DcLocate*' }).Count -eq 0 -and (@($jBadDomain.Problems) -join ' ') -like '*not a valid DNS name*') ($jBadDomain.Problems -join ' | ')
    $jBadDc = Get-AVDTuneJoinState -Machine (& $seedJoined $true $false 'Example.Test' ([pscustomobject]@{ Name = 'dc1 example;x'; Address = '999.1.1.1'; Site = 'Site;x' }))
    Test-Check 'a DC name and an address from the locator that are not valid are dropped' ($null -eq $jBadDc.Dc -and (@($jBadDc.Problems) -join ' ') -like '*name of the DC locator is not valid*address of the DC locator is not valid*') ($jBadDc.Problems -join ' | ')
    $jIpDomain = Get-AVDTuneJoinState -Machine (& $seedJoined $true $false '10.1.2.3' $dcFound)
    Test-Check 'an IP address is not accepted as a domain name' ($jIpDomain.DomainName -eq '') $jIpDomain.DomainName
    # read only: dsregcmd through the central start path with its full path; nothing else is touched
    $mSeen = New-AVDTuneFakeMachine -Seed @{ ComputerSystem = [pscustomobject]@{ PartOfDomain = $false; Domain = 'WORKGROUP'; DomainRole = 2 } }
    $script:dsregFile = $null; $script:dsregArgs = $null
    $mSeen.Run = { param($File, [string[]]$Arguments, [int]$TimeoutSeconds = 120) $script:dsregFile = $File; $script:dsregArgs = @($Arguments); [pscustomobject]@{ ExitCode = 0; Output = '    AzureAdJoined : NO' } }
    [void](Get-AVDTuneJoinState -Machine $mSeen)
    Test-Check 'dsregcmd /status is started with the full path in the system folder (through the machine, i.e. New-AVDTuneChildStartInfo), never by name' ($script:dsregFile -eq (Join-Path ([Environment]::GetFolderPath('System')) 'dsregcmd.exe') -and ($script:dsregArgs -join ' ') -eq '/status') $script:dsregFile
    Test-Check 'the join detection writes nothing: no registry value, service or task change, no file in the state folder' (@($mj.Log | Where-Object { $_ -match '^(RegSet|RegRemove|ServiceSetStartup|ServiceStop|ServiceStart|TaskSetEnabled|WriteFile)' }).Count -eq 0 -and -not (Test-Path (Join-Path $tmp 'start64-probe'))) ($mj.Log -join ' | ')
    $dirCode = [IO.File]::ReadAllText((Join-Path $repo 'Modules\AVDTune.Directory.psm1'))
    $joinCode = $dirCode.Substring($dirCode.IndexOf('#region join state'), $dirCode.IndexOf('#region real adapter') - $dirCode.IndexOf('#region join state'))
    Test-Check 'join detection code: the full system path of dsregcmd, no process start of its own, no write, no Start-Process' ($joinCode -match "Join-Path \(Get-AVDTuneSystemFolder System\) 'dsregcmd\.exe'" -and $joinCode -notmatch '(?i)Start-Process|Process\]::Start|ProcessStartInfo|Set-Item|New-Item|Out-File|Set-Content|WriteAllText|Write-AVDTuneFile|RegSet|RegRemove') $null
    $realMachine = New-AVDTuneMachine
    $locText = $realMachine.DcLocate.ToString() + [string](Get-Command Get-AVDTuneDcFromNtDomain).ScriptBlock
    $bs2 = [string][char]92 * 2
    $ntRows = @(
        [pscustomobject]@{ DomainControllerName = ''; DomainControllerAddress = ''; DcSiteName = ''; ClientSiteName = ''; DnsForestName = 'example.test'; DomainName = 'EXAMPLE' }
        [pscustomobject]@{ DomainControllerName = "${bs2}dc.example.test"; DomainControllerAddress = "${bs2}10.0.0.4"; DcSiteName = 'Default-First-Site-Name'; ClientSiteName = 'Client-Site'; DnsForestName = 'example.test'; DomainName = 'EXAMPLE' }
    )
    $ntDc = Get-AVDTuneDcFromNtDomain -Rows $ntRows -Domain 'example.test'
    Test-Check 'issue #64 finding 7: WMI gives \\host and \\ip; the locator cuts the two backslashes (name, address, site), a row of another domain gives nothing' ($ntDc.Name -eq 'dc.example.test' -and $ntDc.Address -eq '10.0.0.4' -and $ntDc.Site -eq 'Default-First-Site-Name' -and $null -eq (Get-AVDTuneDcFromNtDomain -Rows $ntRows -Domain 'other.test')) ($ntDc | ConvertTo-Json -Compress)
    Test-Check 'the validation would refuse the uncut WMI form (why the backslashes must go)' (-not (Test-AVDTuneDcServer "${bs2}dc.example.test") -and (Test-AVDTuneDcServer $ntDc.Name) -and (Test-AVDTuneDcServer $ntDc.Address))  $null
    $viaFake = & (New-AVDTuneFakeMachine -Seed @{ DcLocate = [pscustomobject]@{ Name = 'dc1.example.test'; Address = '10.0.0.10'; Site = 'Default-First-Site-Name' } }).DcLocate 'example.test'
    Test-Check 'the fake DC locator answers like WMI (names with two backslashes, same mapping) and the join state still gets the DC' ($viaFake.Name -eq 'dc1.example.test' -and $viaFake.Address -eq '10.0.0.10') ($viaFake | ConvertTo-Json -Compress)
    # issue #64 (8): the join state is read in the background runspace of the page; a fresh runspace with exactly the imports of that block must find every command it uses (#55, #67)
    $startSrc = [IO.File]::ReadAllText((Join-Path $repo 'AVDTune-Start.ps1'))
    $joinBlock = $startSrc.Substring($startSrc.IndexOf('function Read-JoinState'), $startSrc.IndexOf('function Complete-JoinJob') - $startSrc.IndexOf('function Read-JoinState'))
    $joinImports = @([regex]::Matches($joinBlock, "Import-Module \(Join-Path \`$AppRoot '([^']+)'\)") | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
    $runJoinRs = {
        param($Imports)
        $rs = [powershell]::Create()
        $keepFake = $env:AVDTUNE_FAKE; $keepRoot = $env:AVDTUNE_ROOT
        try {
            $env:AVDTUNE_FAKE = $null; $env:AVDTUNE_ROOT = $null   # the REAL machine adapter in the runspace, as the page does
            [void]$rs.AddScript({
                    param($Repo, $Imports)
                    $ErrorActionPreference = 'Stop'
                    foreach ($i in $Imports) { Import-Module (Join-Path $Repo $i) -Force }
                    Get-AVDTuneJoinState -Machine (New-AVDTuneMachine)
                }).AddArgument($repo).AddArgument($Imports)
            $out = $null; $thrown = ''
            try { $out = $rs.Invoke() | Select-Object -Last 1 } catch { $thrown = $_.Exception.Message }
            [pscustomobject]@{ Result = $out; Err = ((@($rs.Streams.Error | ForEach-Object { $_.ToString() }) + $thrown) -join '; ').Trim('; ') }
        }
        finally { $rs.Dispose(); $env:AVDTUNE_FAKE = $keepFake; $env:AVDTUNE_ROOT = $keepRoot }
    }
    $joinOk = & $runJoinRs $joinImports
    Test-Check 'join state page (#64): the real read works in a runspace with exactly the page''s imports (a Kind comes back, no unknown command)' ($joinImports.Count -ge 2 -and $joinOk.Result -and $joinOk.Result.Kind -and -not $joinOk.Err -and $startSrc -match 'function Read-JoinState[\s\S]*?\[powershell\]::Create\(\)') "imports=$($joinImports -join ','); kind=$($joinOk.Result.Kind); err=$($joinOk.Err)"
    $joinMissing = & $runJoinRs @($joinImports | Select-Object -First ($joinImports.Count - 1))   # counter-test: without the last import the runspace must fail
    Test-Check 'join state page (#64) counter-test: without the Directory import the same runspace fails with an unknown command' ($joinMissing.Err -match 'is not recognized|nicht erkannt|not recognized' -or -not $joinMissing.Result) "err=$($joinMissing.Err)"
    Test-Check 'issue #64 finding 1: the DcLocate member binds to nothing: no DomainController FindOne, no DirectoryEntry, no DirectoryContext, no DirectoryServices, no ADSI' ($locText -match 'Win32_NTDomain' -and $locText -notmatch '(?i)DomainController\]::FindOne|DirectoryEntry|DirectoryContext|DirectoryServices|\.SiteName|\.IPAddress|\[adsi|LDAP:') $locText
    Test-Check 'the real machine has the two read members of the join detection, the fake has them too' ($realMachine.PSObject.Properties['ComputerSystem'] -and $realMachine.PSObject.Properties['DcLocate'] -and $mj.PSObject.Properties['ComputerSystem'] -and $mj.PSObject.Properties['DcLocate']) $null

    # Azure facts: only GET, validated, and the cases without Azure
    $factsVm = Get-AVDTuneVmIdentity (New-AVDTuneFakeMachine)
    $armOk = New-AVDTuneFakeArm -Seed @{ Net = @{ VNet = 'vnet-corp'; Subnet = 'snet-avd' }; StorageAccounts = @(@{ Name = 'stprofilesexample'; Kind = 'FileStorage'; Public = 'Disabled'; PrivateEndpoints = 1 }); DnsZones = @('privatelink.file.core.windows.net') }
    $facts = Get-AVDTuneAzureFacts -Arm $armOk -Token 'fake-arm-token-value' -Vm $factsVm
    Test-Check 'Azure facts: region, virtual network and subnet of the primary NIC, the storage account, the private DNS zone' ($facts.Reachable -and $facts.Region -eq 'westeurope' -and $facts.VNet -eq 'vnet-corp' -and $facts.Subnet -eq 'snet-avd' -and $facts.StorageAccounts.Count -eq 1 -and $facts.StorageAccounts[0].Name -eq 'stprofilesexample' -and $facts.StorageAccounts[0].PrivateEndpoints -eq 1 -and $facts.DnsZone -eq $true -and @($facts.Problems).Count -eq 0) ($facts | ConvertTo-Json -Compress -Depth 4)
    Test-Check 'Azure facts: every request is a GET (nothing is written to Azure before the snapshot is confirmed)' (@($armOk.Log).Count -ge 4 -and @($armOk.Log | Where-Object { $_ -notlike 'GET *' }).Count -eq 0) ($armOk.Log -join ' | ')
    $roArm = New-AVDTuneReadOnlyArm -Arm $armOk
    $armOk.Log.Clear()
    $roResults = @(@('PUT', 'POST', 'DELETE', 'PATCH') | ForEach-Object { & $roArm.Invoke $_ "/subscriptions/$script:FakeSubscription/resourceGroups/rg-example/providers/Microsoft.Compute/snapshots/x?api-version=2023-10-02" 'fake-arm-token-value' @{ a = 1 } })
    $roBody = & $roArm.Invoke 'GET' "/subscriptions/$script:FakeSubscription/resourceGroups/rg-example/providers/Microsoft.Compute/snapshots?api-version=2023-10-02" 'fake-arm-token-value' @{ a = 1 }
    Test-Check 'the read-only ARM adapter refuses PUT, POST, DELETE, PATCH and a GET with a body without calling Azure' (@($roResults | Where-Object { $_.Status -ne 0 -or $_.Error -notlike 'Refused*' }).Count -eq 0 -and $roBody.Status -eq 0 -and $armOk.Log.Count -eq 0) ($armOk.Log -join ' | ')
    $armOk.Log.Clear()
    $roLower = @(@('get', 'Get', 'gET') | ForEach-Object { & $roArm.Invoke $_ "/subscriptions/$script:FakeSubscription/resourceGroups/rg-example/providers/Microsoft.Compute/snapshots?api-version=2023-10-02" 'fake-arm-token-value' $null })
    Test-Check 'the read-only ARM adapter compares the method case sensitively: get, Get, gET are refused without calling Azure' (@($roLower | Where-Object { $_.Status -ne 0 -or $_.Error -notlike 'Refused*' }).Count -eq 0 -and $armOk.Log.Count -eq 0) ($armOk.Log -join ' | ')
    $factsSrc = [IO.File]::ReadAllText((Join-Path $repo 'Modules\AVDTune.Snapshot.psm1'))
    $factsCode = $factsSrc.Substring($factsSrc.IndexOf('function Get-AVDTuneAzureFacts'), $factsSrc.IndexOf('#region real adapter') - $factsSrc.IndexOf('function Get-AVDTuneAzureFacts'))
    Test-Check 'Azure facts code: only through the read-only adapter and only GET' ($factsCode -match 'New-AVDTuneReadOnlyArm' -and @([regex]::Matches($factsCode, '-Method (\w+)') | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -ne 'GET' }).Count -eq 0 -and $factsCode -notmatch 'Invoke-AVDTuneArm -Arm \$Arm\b') $null
    $armOff = New-AVDTuneFakeArm; $armOff.Store.Offline = $true
    $factsOff = Get-AVDTuneAzureFacts -Arm $armOff -Token 'fake-arm-token-value' -Vm $factsVm
    Test-Check 'Azure facts: Azure not reachable: Reachable is false, nothing is known, the reason is readable' (-not $factsOff.Reachable -and $factsOff.Problem -like 'No connection to Azure Resource Manager*' -and $factsOff.VNet -eq '' -and @($factsOff.StorageAccounts).Count -eq 0) $factsOff.Problem
    $armNoStorage = New-AVDTuneFakeArm; $armNoStorage.Store.StorageForbidden = $true; $armNoStorage.Store.DnsForbidden = $true
    $factsPart = Get-AVDTuneAzureFacts -Arm $armNoStorage -Token 'fake-arm-token-value' -Vm $factsVm
    Test-Check 'Azure facts: a part that is forbidden (storage accounts, DNS zones) stays empty and is named, the network is still known' ($factsPart.Reachable -and $factsPart.VNet -eq 'vnet-example' -and @($factsPart.StorageAccounts).Count -eq 0 -and $null -eq $factsPart.DnsZone -and (@($factsPart.Problems) -join ' ') -like '*Storage accounts*403*Private DNS zones*') ($factsPart.Problems -join ' | ')
    $armEvil = New-AVDTuneFakeArm -Seed @{ Net = @{ VNet = 'vnet;evil'; Subnet = 'snet-avd' } }
    $factsEvil = Get-AVDTuneAzureFacts -Arm $armEvil -Token 'fake-arm-token-value' -Vm $factsVm
    Test-Check 'Azure facts: a subnet ID with characters that are not allowed in a name is not used' ($factsEvil.VNet -eq '' -and $factsEvil.Subnet -eq '' -and (@($factsEvil.Problems) -join ' ') -like '*unexpected form*') ($factsEvil.Problems -join ' | ')
    $factsNoVm = Get-AVDTuneAzureFacts -Arm $armOk -Token 'fake-arm-token-value' -Vm (Get-AVDTuneVmIdentity (New-AVDTuneFakeMachine -Seed @{ Imds = $null }))
    Test-Check 'Azure facts: outside Azure (no instance metadata) nothing is known' (-not $factsNoVm.Reachable -and $factsNoVm.Problem -like '*not an Azure VM*') $factsNoVm.Problem

    # suggestions: values with their source, ambiguous questions stay open, nothing without Azure from Azure
    $sgHybrid = Get-AVDTuneAnswerSuggestions -Detection $jHybrid -AzureFacts $facts
    $it = $sgHybrid.Items
    Test-Check 'suggestions, domain member with Azure: join, identities, network, profiles, endpoint, DNS zone with a source each; the DC question stays open (Azure or on premises)' ($it.Join.Value -eq 'Hybrid' -and $it.Identities.Value -eq 'Synced' -and $it.VNet.Value -eq 'vnet-corp' -and $it.Subnet.Value -eq 'snet-avd' -and $it.Profiles.Value -eq 'AzureFiles' -and $it.Endpoint.Value -eq 'Private' -and $it.DnsZone.Value -eq 'Azure' -and $it.Dc.State -eq 'Ambiguous' -and $it.Dc.Value -eq '' -and $it.Dc.Hint -like '*dc1.example.test*Azure or on premises*' -and @($it.Values | Where-Object { $_.State -eq 'Detected' -and -not $_.Source }).Count -eq 0) ($it.Keys -join ',')
    Test-Check 'suggestions: the source names where the value came from' ($it.Join.Source -like '*Win32_ComputerSystem*dsregcmd*example.test*' -and $it.VNet.Source -like '*Azure Resource Manager*' -and $it.Profiles.Source -like '*stprofilesexample*') ($it.Join.Source + ' | ' + $it.VNet.Source)
    $sgEntra = Get-AVDTuneAnswerSuggestions -Detection $jEntra -AzureFacts $facts
    Test-Check 'suggestions, Entra only: join Entra only, no domain controller, the identities stay open' ($sgEntra.Items.Join.Value -eq 'EntraOnly' -and $sgEntra.Items.Dc.Value -eq 'None' -and $sgEntra.Items.Identities.State -eq 'Ambiguous') ($sgEntra.Items.Keys -join ',')
    $sgNone = Get-AVDTuneAnswerSuggestions -Detection $jNone -AzureFacts $facts
    Test-Check 'suggestions, not joined: join and domain controller stay open (the master says nothing about the session hosts)' ($sgNone.Items.Join.State -eq 'Ambiguous' -and $sgNone.Items.Join.Value -eq '' -and $sgNone.Items.Dc.State -eq 'Ambiguous') ($sgNone.Items.Keys -join ',')
    $sgOff = Get-AVDTuneAnswerSuggestions -Detection $jHybrid -AzureFacts $factsOff
    Test-Check 'suggestions, Azure not reachable: no value from Azure (network, profiles, endpoint, DNS zone are asked), the note says why; the join stays known from the master' (-not $sgOff.Items.Contains('VNet') -and -not $sgOff.Items.Contains('Subnet') -and -not $sgOff.Items.Contains('Profiles') -and -not $sgOff.Items.Contains('Endpoint') -and -not $sgOff.Items.Contains('DnsZone') -and (@($sgOff.Notes) -join ' ') -like '*Azure: nothing could be read*No connection*' -and $sgOff.Items.Join.Value -eq 'Hybrid') (@($sgOff.Notes) -join ' | ')
    $sgNoDetect = Get-AVDTuneAnswerSuggestions -Detection $null -AzureFacts $factsOff
    Test-Check 'suggestions, neither join state nor Azure: nothing is suggested, every question is asked' ($sgNoDetect.Items.Count -eq 0) ($sgNoDetect.Items.Keys -join ',')
    $armTwo = New-AVDTuneFakeArm -Seed @{ StorageAccounts = @(@{ Name = 'stone'; PrivateEndpoints = 0 }, @{ Name = 'sttwo'; PrivateEndpoints = 1 }) }
    $sgTwo = Get-AVDTuneAnswerSuggestions -Detection $jEntra -AzureFacts (Get-AVDTuneAzureFacts -Arm $armTwo -Token 'fake-arm-token-value' -Vm $factsVm)
    Test-Check 'suggestions: more than one storage account is ambiguous (asked, the accounts named), no endpoint is guessed' ($sgTwo.Items.Profiles.State -eq 'Ambiguous' -and $sgTwo.Items.Profiles.Hint -like '*stone*sttwo*' -and -not $sgTwo.Items.Contains('Endpoint')) ($sgTwo.Items.Keys -join ',')
    $armPub = New-AVDTuneFakeArm -Seed @{ StorageAccounts = @(@{ Name = 'stpublic'; Public = 'Enabled'; PrivateEndpoints = 0 }) }
    $sgPub = Get-AVDTuneAnswerSuggestions -Detection $jEntra -AzureFacts (Get-AVDTuneAzureFacts -Arm $armPub -Token 'fake-arm-token-value' -Vm $factsVm)
    Test-Check 'suggestions: a storage account without a private endpoint and with public access suggests the public endpoint; no DNS zone found suggests nothing for it' ($sgPub.Items.Endpoint.Value -eq 'Public' -and -not $sgPub.Items.Contains('DnsZone')) ($sgPub.Items.Keys -join ',')
    $armParen = New-AVDTuneFakeArm -Seed @{ Net = @{ VNet = 'vnet(x)'; Subnet = 'snet-avd' } }
    $sgParen = Get-AVDTuneAnswerSuggestions -Detection $jEntra -AzureFacts (Get-AVDTuneAzureFacts -Arm $armParen -Token 'fake-arm-token-value' -Vm $factsVm)
    Test-Check 'suggestions: a detected network name that does not pass the answer rule is not suggested and named as rejected' (-not $sgParen.Items.Contains('VNet') -and $sgParen.Items.Subnet.Value -eq 'snet-avd' -and (@($sgParen.Rejected) -join ' ') -like 'VNet*') (@($sgParen.Rejected) -join ' | ')
    $allChoices = @{}; foreach ($q in (Get-AVDTuneQuestions)) { $allChoices[$q.Key] = @($q.Choices | ForEach-Object { $_.Value }) }
    $badChoice = @($sgHybrid.Items.Values + $sgEntra.Items.Values + $sgPub.Items.Values | Where-Object { $_.State -eq 'Detected' -and $allChoices.ContainsKey($_.Key) -and $_.Value -cnotin $allChoices[$_.Key] })
    Test-Check 'every suggested choice is one of the choices of its question' ($badChoice.Count -eq 0) ($badChoice | ForEach-Object { "$($_.Key)=$($_.Value)" })

    # the whole order in one root: sign-in without any answer, domain, suggestions, confirmation
    $o1 = Join-Path $tmp 'order1'; [void](Initialize-AVDTuneState -Root $o1)
    $ctxO = New-AVDTuneStartContext
    $stO = Get-AVDTuneStartStages -Context $ctxO -Root $o1
    Test-Check 'order: nothing is asked before the sign-in (no environment.json, no answers)' (-not (Test-Path (Join-Path $o1 'environment.json')) -and ($stO | ForEach-Object Status) -join ',' -eq 'Pending,Locked,Locked,Locked' -and ($stO | ForEach-Object Id) -join ',' -eq 'SignIn,Domain,Environment,Snapshot') (($stO | ForEach-Object Status) -join ',')
    $aO = New-AVDTuneFakeAuth
    $sO = New-AVDTuneSession -TempRoot $signTemp -Auth $aO
    $resO = Invoke-AVDTuneStartSignIn -Root $o1 -Session $sO -User 'admin1' -RetryDelaySeconds 0
    $fileO = Get-AVDTuneEnvironmentFile $o1
    Test-Check 'order: the sign-in works without an answer: its own app registration is made, tenant and client ID are saved, but no answer exists' ($resO.Info.Connected -and $fileO.SignIn.TenantId -eq $tenant -and $fileO.SignIn.ClientId -eq @($aO.Store.Apps)[0].appId -and $null -eq (Get-AVDTuneEnvironment $o1) -and $null -eq (Get-AVDTuneProp $fileO 'Answers')) ($fileO | ConvertTo-Json -Compress -Depth 3)
    $ctxO.Session = $sO
    $stO = Get-AVDTuneStartStages -Context $ctxO -Root $o1
    Test-Check 'order: after the sign-in the domain stage waits for the join detection, the questions and the snapshot wait' (($stO | ForEach-Object Status) -join ',' -eq 'Done,Pending,Locked,Locked') (($stO | ForEach-Object Status) -join ',')
    # Entra only: the domain step is not needed, with the reason; the questions open
    [void](Update-AVDTuneStartDetection -Context $ctxO -Machine $mE)
    $stO = Get-AVDTuneStartStages -Context $ctxO -Root $o1
    Test-Check 'order: Entra only: the domain step is skipped with the reason, the questions are next, the snapshot waits' (($stO | ForEach-Object Status) -join ',' -eq 'Done,Skipped,Pending,Locked' -and $stO[1].Detail -like 'Not needed: This master is joined to Microsoft Entra ID only*' -and (Get-AVDTuneNextStage $stO).Id -eq 'Environment') (($stO | ForEach-Object Status) -join ',' + ' ' + $stO[1].Detail)
    # a domain member: the DC step opens first, the questions wait for it
    $ctxJ = New-AVDTuneStartContext; $ctxJ.Session = $sO
    [void](Update-AVDTuneStartDetection -Context $ctxJ -Machine $mj)
    $stJ = Get-AVDTuneStartStages -Context $ctxJ -Root $o1
    Test-Check 'order: domain member: the DC step is pending (the locator found the DC), the questions and the snapshot wait' (($stJ | ForEach-Object Status) -join ',' -eq 'Done,Pending,Locked,Locked' -and $stJ[1].Detail -like '*dc1.example.test*' -and (Get-AVDTuneNextStage $stJ).Id -eq 'Domain') (($stJ | ForEach-Object Status) -join ',' + ' ' + $stJ[1].Detail)
    # the domain step before any answer: pin and discovery go into the file next to the sign-in, nothing is lost
    [void](Set-AVDTuneDcPin -Root $o1 -Server 'dc1.example.test' -Certificate ([pscustomobject]@{ Sha256 = ('AB' * 32); Thumbprint = ('CD' * 20); Subject = 'CN=dc1.example.test' }) -User 'admin1')
    Save-AVDTuneDcDiscovery -Root $o1 -Server 'dc1.example.test' -User 'EXAMPLE\svc' -Info $info
    $fileD = Get-AVDTuneEnvironmentFile $o1
    Test-Check 'order: the DC pin and what was read are saved before the questions; the sign-in part stays; still no answers' ($fileD.Dc.Server -eq 'dc1.example.test' -and $fileD.Dc.Pins.'dc1.example.test'.Sha256 -eq ('AB' * 32) -and $fileD.Dc.Discovery.NetBiosName -eq 'EXAMPLE' -and $fileD.SignIn.TenantId -eq $tenant -and $null -eq (Get-AVDTuneEnvironment $o1)) ($fileD | ConvertTo-Json -Compress -Depth 4)
    $ctxJ.Directory = $info; $ctxJ.DirectorySecurity = 'LDAPS 636, certificate pinned'
    $stJ = Get-AVDTuneStartStages -Context $ctxJ -Root $o1
    Test-Check 'order: after the DC is read the questions are pending (the snapshot waits)' (($stJ | ForEach-Object Status) -join ',' -eq 'Done,Done,Pending,Locked') (($stJ | ForEach-Object Status) -join ',')

    # a suggestion is no answer until the administrator confirms
    $ctxJ.AzureFacts = $facts; $ctxJ.Suggestions = Get-AVDTuneAnswerSuggestions -Detection $ctxJ.Detection -AzureFacts $facts
    $stJ = Get-AVDTuneStartStages -Context $ctxJ -Root $o1
    Test-Check 'a suggestion is not an answer: with all suggestions known there is still no environment, the questions are pending, environment.json has no answers' ($null -eq (Get-AVDTuneEnvironment $o1) -and $stJ[2].Status -eq 'Pending' -and $null -eq (Get-AVDTuneProp (Get-AVDTuneEnvironmentFile $o1) 'Answers') -and -not (Test-AVDTuneWriteAllowed)) ($stJ | ForEach-Object Status)
    $confirm = Get-AVDTuneEnvironmentAnswers (Get-AVDTuneEnvironmentFile $o1)
    foreach ($k in 'Join', 'Identities', 'VNet', 'Subnet', 'Profiles', 'Endpoint', 'DnsZone') { $confirm.$k = [string]$ctxJ.Suggestions.Items[$k].Value }
    $confirm.Dc = 'AdDsOnPrem'   # the question the administrator had to answer himself
    $confirm.Profiles = 'OtherSmb'   # and a suggestion he changed
    $srcO = Resolve-AVDTuneAnswerSources -Answers $confirm -Suggestions $ctxJ.Suggestions
    Test-Check 'sources: a kept suggestion is confirmed with its source, a changed one and a typed one say so' ($srcO.Join -like 'Confirmed: *Win32_ComputerSystem*' -and $srcO.VNet -like 'Confirmed: Azure Resource Manager*' -and $srcO.Profiles -like 'Typed by the administrator (suggested AzureFiles: *' -and $srcO.Dc -eq 'Typed by the administrator' -and $srcO.SnapshotNamePattern -eq 'Default of AVDTune') ($srcO | ConvertTo-Json -Compress)
    $savedO = Save-AVDTuneEnvironment -Root $o1 -Answers $confirm -User 'admin1' -Sources $srcO
    $stJ = Get-AVDTuneStartStages -Context $ctxJ -Root $o1
    $envO = Get-AVDTuneEnvironment $o1
    Test-Check 'after the confirmation the suggestion values are the answers; the file keeps the sign-in, the DC pin and the sources' ($envO.Answers.Join -eq 'Hybrid' -and $envO.Answers.Network.VNet -eq 'vnet-corp' -and $envO.Answers.Profiles -eq 'OtherSmb' -and $envO.SignIn.TenantId -eq $tenant -and $envO.SignIn.ClientId -eq $fileO.SignIn.ClientId -and $envO.Dc.Pins.'dc1.example.test'.Sha256 -eq ('AB' * 32) -and $envO.Sources.Join -like 'Confirmed: *' -and $envO.Sources.Dc -eq 'Typed by the administrator' -and ($stJ | ForEach-Object Status) -join ',' -eq 'Done,Done,Done,Pending') ($envO | ConvertTo-Json -Compress -Depth 4)
    Test-Check 'the sources in environment.json hold no secret and are read back' ((Get-Content (Join-Path $o1 'environment.json') -Raw) -notmatch '(?i)password|secret|token|key|eyJ' -and (Get-AVDTuneAnswerSources $envO).Contains('Join')) $null
    # the other writers keep the sources and the rest of the file
    [void](Set-AVDTuneEnvironmentSignIn -Root $o1 -TenantId $tenant -ClientId '66666666-7777-8888-9999-000000000000' -User 'admin1')
    $afterSignIn = Get-AVDTuneEnvironment $o1
    Test-Check 'a later sign-in change keeps answers, sources, DC and pins' ($afterSignIn.SignIn.ClientId -eq '66666666-7777-8888-9999-000000000000' -and $afterSignIn.Sources.Join -like 'Confirmed: *' -and $afterSignIn.Dc.Pins.'dc1.example.test'.Sha256 -eq ('AB' * 32) -and $afterSignIn.Answers.Join -eq 'Hybrid') ($afterSignIn | ConvertTo-Json -Compress -Depth 4)
    [void](Set-AVDTuneDcPin -Root $o1 -Server 'dc2.example.test' -Certificate ([pscustomobject]@{ Sha256 = ('EF' * 32); Thumbprint = ('01' * 20); Subject = 'CN=dc2.example.test' }) -User 'admin1')
    $afterPin = Get-AVDTuneEnvironment $o1
    $noSrc = Get-AVDTuneEnvironmentAnswers (Get-AVDTuneEnvironment $o1); $noSrc.VNet = 'vnet-typed-later'
    [void](Save-AVDTuneEnvironment -Root $o1 -Answers $noSrc -User 'admin1')
    $afterNoSrc = Get-AVDTuneEnvironment $o1
    Test-Check 'issue #64 finding 3: a save without -Sources marks the changed answer as typed by the administrator, the others keep their source' ($afterNoSrc.Answers.Network.VNet -eq 'vnet-typed-later' -and $afterNoSrc.Sources.VNet -eq 'Typed by the administrator' -and $afterNoSrc.Sources.Join -like 'Confirmed: *' -and $afterNoSrc.Sources.Profiles -like 'Typed by the administrator (suggested*') ($afterNoSrc.Sources | ConvertTo-Json -Compress)
    $startPs = [IO.File]::ReadAllText((Join-Path $repo 'AVDTune-Start.ps1'))
    Test-Check 'issue #64 finding 5: Azure data is matched with a length limit and a timeout (facts, suggestions, site of the RootDSE)' (([IO.File]::ReadAllText((Join-Path $repo 'Modules\AVDTune.Snapshot.psm1')) -notmatch '(?m)(-match|-notmatch) \$script:Facts') -and ([IO.File]::ReadAllText((Join-Path $repo 'Modules\AVDTune.Start.psm1')) -match 'Length -le 1024 -and \[regex\]::IsMatch') -and $dirCode -notmatch "-match '\(\?i\),CN=Servers") $null
    Test-Check 'issue #64 finding 6/8: the join detection runs in a background runspace with a task on the task bar (inline only in test mode) and dsregcmd has a 30 s timeout' ($startPs -match 'function Read-JoinState[\s\S]*?Start-AVDTuneUiTask[\s\S]*?\[powershell\]::Create\(\)[\s\S]*?BeginInvoke' -and $startPs -match 'function Complete-JoinJob' -and $startPs -match 'Timer.Add_Tick\(\{[^\r\n]*Complete-JoinJob' -and $joinCode -match "'/status'\) 30 ") $null
    Test-Check 'a client ID typed together with -Setup is refused before any sign-in' ($null -ne ($e4 = Get-ThrownText { Invoke-AVDTuneStartSignIn -Root $tmp -Session (New-AVDTuneSession -TempRoot $tmp -Auth (New-AVDTuneFakeAuth)) -User 'admin1' -Setup -ClientId '66666666-7777-8888-9999-000000000000' }) -and $e4 -like '*exclude each other*') $e4
    Test-Check 'a later DC pin keeps answers, sources and the sign-in' ($afterPin.Answers.Profiles -eq 'OtherSmb' -and $afterPin.Sources.Profiles -like 'Typed by the administrator (suggested*' -and $afterPin.SignIn.TenantId -eq $tenant -and $afterPin.Dc.Pins.'dc2.example.test') $null

    # not joined at the master but the questions say there is a domain controller: the domain step opens after the questions
    $ctxN = New-AVDTuneStartContext; $ctxN.Session = $sO
    $o2 = Join-Path $tmp 'order2'; [void](Initialize-AVDTuneState -Root $o2)
    [void](Set-AVDTuneEnvironmentSignIn -Root $o2 -TenantId $tenant -User 'admin1')
    [void](Update-AVDTuneStartDetection -Context $ctxN -Machine (& $seedJoined $false $false))
    $stN = Get-AVDTuneStartStages -Context $ctxN -Root $o2
    Test-Check 'order: not joined: the domain step is skipped with the reason and points to the questions' (($stN | ForEach-Object Status) -join ',' -eq 'Done,Skipped,Pending,Locked' -and $stN[1].Detail -like '*not joined*if the session hosts use one, say so in the questions*') $stN[1].Detail
    $ansN = Get-AVDTuneEnvironmentDefaults; $ansN.Join = 'AdDs'; $ansN.Dc = 'AdDsOnPrem'; $ansN.Identities = 'Synced'
    [void](Save-AVDTuneEnvironment -Root $o2 -Answers $ansN -User 'admin1')
    $stN = Get-AVDTuneStartStages -Context $ctxN -Root $o2
    Test-Check 'order: the confirmed answer "domain controller on premises" opens the domain step after the questions and keeps the snapshot locked' (($stN | ForEach-Object Status) -join ',' -eq 'Done,Pending,Done,Locked') (($stN | ForEach-Object Status) -join ',')
    # Azure not reachable: the questions are asked without suggestion from Azure, the answers can still be given and saved
    $ctxA = New-AVDTuneStartContext; $ctxA.Session = $sO
    [void](Update-AVDTuneStartDetection -Context $ctxA -Machine $mE)
    $armDown = New-AVDTuneFakeArm; $armDown.Store.Offline = $true
    $sgDown = Update-AVDTuneStartSuggestions -Context $ctxA -Machine $mE -Arm $armDown
    Test-Check 'Azure not reachable: the suggestions have nothing from Azure, the facts say so, only GET was tried' ($ctxA.AzureFacts.Reachable -eq $false -and -not $sgDown.Items.Contains('VNet') -and -not $sgDown.Items.Contains('Profiles') -and $sgDown.Items.Join.Value -eq 'EntraOnly' -and @($armDown.Log | Where-Object { $_ -notlike 'GET *' }).Count -eq 0) (@($armDown.Log) -join ' | ')
    $ctxNo = New-AVDTuneStartContext
    $sgNoSession = Update-AVDTuneStartSuggestions -Context $ctxNo -Machine $mE -Arm $armOk
    Test-Check 'without a sign-in no Azure request is made and nothing is suggested from Azure' ($ctxNo.AzureFacts.Reachable -eq $false -and $ctxNo.AzureFacts.Problem -like 'Not signed in*' -and -not $sgNoSession.Items.Contains('VNet')) $ctxNo.AzureFacts.Problem
    $armOk.Log.Clear()
    $sgWith = Update-AVDTuneStartSuggestions -Context $ctxA -Machine $mE -Arm $armOk
    Test-Check 'with the sign-in the ARM token comes from the session and Azure is read with GET only' ($ctxA.AzureFacts.Reachable -and $sgWith.Items.VNet.Value -eq 'vnet-corp' -and @($armOk.Log).Count -ge 3 -and @($armOk.Log | Where-Object { $_ -notlike 'GET *' }).Count -eq 0) (@($armOk.Log) -join ' | ')
    # a client ID typed in the sign-in form: validated, saved only after it worked
    $o3 = Join-Path $tmp 'order3'; [void](Initialize-AVDTuneState -Root $o3)
    $e3a = Get-ThrownText { Invoke-AVDTuneStartSignIn -Root $o3 -Session (New-AVDTuneSession -TempRoot $signTemp -Auth (New-AVDTuneFakeAuth)) -ClientId '14d82eec-204b-4c2f-b7e8-296a70dab67e' }
    $e3b = Get-ThrownText { Invoke-AVDTuneStartSignIn -Root $o3 -Session (New-AVDTuneSession -TempRoot $signTemp -Auth (New-AVDTuneFakeAuth)) -ClientId 'not-a-guid' }
    $a3c = New-AVDTuneFakeAuth -Seed @{ Offline = $true }
    $e3c = Get-ThrownText { Invoke-AVDTuneStartSignIn -Root $o3 -Session (New-AVDTuneSession -TempRoot $signTemp -Auth $a3c) -ClientId $clientId -Account 'admin.example@contoso.example' }
    Test-Check 'sign-in form client ID: the setup app and a non-GUID are refused, a failed sign-in saves nothing' ($e3a -like '*setup app*' -and $e3b -like '*must be a GUID*' -and $e3c -like 'No connection*' -and -not (Test-Path (Join-Path $o3 'environment.json'))) "$e3a | $e3b | $e3c"
    $a3d = New-AVDTuneFakeAuth
    $res3d = Invoke-AVDTuneStartSignIn -Root $o3 -Session (New-AVDTuneSession -TempRoot $signTemp -Auth $a3d) -ClientId $clientId -Account 'admin.example@contoso.example' -User 'admin1'
    Test-Check 'sign-in form client ID: used for the sign-in (no app registration is made), saved after it worked, still no answers' ($res3d.Info.Connected -and @($a3d.Log | Where-Object { $_ -like "SignIn tenant=$tenant client=$clientId*" }).Count -eq 1 -and $a3d.Store.Apps.Count -eq 0 -and (Get-AVDTuneEnvironmentFile $o3).SignIn.ClientId -eq $clientId -and $null -eq (Get-AVDTuneEnvironment $o3)) ($a3d.Log -join ' | ')
    # an environment.json of an earlier version: confirmed as it is, not asked again, nothing rewritten by reading, saving keeps what it has
    $oldFile = Join-Path $tmp 'order-old'; [void](Initialize-AVDTuneState -Root $oldFile)
    $oldJson = (@{ Schema = 1; Answers = @{ Join = 'Hybrid'; Dc = 'AdDsOnPrem'; Identities = 'Synced'; Profiles = 'AzureFiles'; AzureFilesAuth = 'AdDs'; Network = @{ Endpoint = 'Private'; VNet = 'vnet-old'; Subnet = 'snet-old'; DnsZone = 'Azure' } }; SignIn = @{ TenantId = $tenant; ClientId = $clientId }; Snapshot = @{ NamePattern = '{OsDisk}-{N}' }; Dc = @{ Server = '10.0.0.10'; User = 'EXAMPLE\svc'; Pins = @{ '10.0.0.10' = @{ Sha256 = ('AB' * 32) } }; Discovery = $null }; Gallery = $null; Updated = '2026-11-01T00:00:00Z'; UpdatedBy = 'admin1' } | ConvertTo-Json -Depth 6)
    [IO.File]::WriteAllText((Join-Path $oldFile 'environment.json'), $oldJson)
    $ctxOld = New-AVDTuneStartContext
    $stOld = Get-AVDTuneStartStages -Context $ctxOld -Root $oldFile
    $oldBefore = Get-Content (Join-Path $oldFile 'environment.json') -Raw
    Test-Check 'an earlier environment.json: the questions are Done at once (not asked again), the sign-in and the DC step (its own answer) follow, no source recorded' ((Get-AVDTuneEnvironment $oldFile).Answers.Join -eq 'Hybrid' -and ($stOld | ForEach-Object Status) -join ',' -eq 'Pending,Locked,Done,Locked' -and (Get-AVDTuneAnswerSources (Get-AVDTuneEnvironment $oldFile)).Count -eq 0 -and $oldBefore -eq (Get-Content (Join-Path $oldFile 'environment.json') -Raw)) (($stOld | ForEach-Object Status) -join ',')
    $oldCtxSigned = New-AVDTuneStartContext; $oldCtxSigned.Session = $sO; [void](Update-AVDTuneStartDetection -Context $oldCtxSigned -Machine $mE)
    Test-Check 'an earlier environment.json: the join detection does not override its answer (a DC step stays because the saved answer says so)' (((Get-AVDTuneStartStages -Context $oldCtxSigned -Root $oldFile) | ForEach-Object Status) -join ',' -eq 'Done,Pending,Done,Locked') $null
    $oldAns = Get-AVDTuneEnvironmentAnswers (Get-AVDTuneEnvironment $oldFile); $oldAns.VNet = 'vnet-new'
    $oldSaved = Save-AVDTuneEnvironment -Root $oldFile -Answers $oldAns -User 'admin1'
    Test-Check 'an earlier environment.json: saving a change keeps the DC, its pin and the client ID' ($oldSaved.Environment.Dc.Server -eq '10.0.0.10' -and $oldSaved.Environment.Dc.Pins.'10.0.0.10'.Sha256 -eq ('AB' * 32) -and $oldSaved.Environment.SignIn.ClientId -eq $clientId -and $oldSaved.Environment.Answers.Network.VNet -eq 'vnet-new') ($oldSaved.Environment | ConvertTo-Json -Compress -Depth 4)

    # read only until the snapshot: no change record, no write gate, no Azure write from the whole detection and suggestion path
    Test-Check 'nothing before the snapshot gate changed the master: the write gate is closed and no state.json change was recorded' (-not (Test-AVDTuneWriteAllowed) -and -not (Get-AVDTuneProp (Get-AVDTuneState $o1) 'LastChange')) $null

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
