#requires -Version 5.1
<#
.SYNOPSIS
    Checks the start sequence against fakes (Tests\Fakes\FakeServices.ps1, FakeMachine.ps1): first-run questions and environment.json,
    the sign-in session (three audiences, tokens in memory), the snapshot gate (IMDS, ARM, confirmation by name, read-only until then),
    the domain controller connection (LDAPS pinning, signed fallback, never a simple bind) and discovery, including the error paths:
    no network, 403 (missing role), changed LDAPS certificate, no snapshot of today. No real sign-in, tenant, Azure or domain controller.
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
    Test-Check 'sign-in: connected, account known, three audiences; Sites and ARM tokens carry their permission' ($info.Connected -and $info.Account -like 'admin.example@*' -and $info.Audiences.Count -eq 3 -and ($info.Audiences | Where-Object Audience -eq 'Sites').Scopes -contains 'Sites.Selected' -and ($info.Audiences | Where-Object Audience -eq 'Arm').Scopes -join ',' -eq 'user_impersonation') ($info | ConvertTo-Json -Compress -Depth 4)
    Test-Check 'one interactive sign-in only; the other tokens come from the refresh token' (@($auth.Log | Where-Object { $_ -like 'SignIn*' }).Count -eq 1 -and @($auth.Log | Where-Object { $_ -like 'Refresh*hasRefreshToken=True' }).Count -eq 3) ($auth.Log -join ' | ')
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
    Test-Check 'a profile that is still locked stays and Test-AVDTuneSessionClear says so (final check before seal)' ((Test-Path $planted) -and -not (Test-AVDTuneSessionClear $sl)) $null
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
    $s3 = New-AVDTuneSession -TempRoot $signTemp -Auth (New-AVDTuneFakeAuth -Seed @{ ConsentMissing = @('Arm') })
    $e = Get-ThrownText { Connect-AVDTuneSession -Session $s3 -TenantId $tenant -ClientId $clientId }
    Test-Check 'missing consent for Azure Service Management: names the audience and the scope, no tokens kept' ($e -like '*no consent*audience Arm*user_impersonation*' -and (Test-AVDTuneSessionClear $s3)) $e
    $s4 = New-AVDTuneSession -TempRoot $signTemp -Auth (New-AVDTuneFakeAuth -Seed @{ WrongTenant = $true })
    $e = Get-ThrownText { Connect-AVDTuneSession -Session $s4 -TenantId $tenant -ClientId $clientId }
    Test-Check 'a token of another tenant is refused and nothing is kept' ($e -like '*another tenant*' -and (Test-AVDTuneSessionClear $s4)) $e
    $s5 = New-AVDTuneSession -TempRoot $signTemp -Auth (New-AVDTuneFakeAuth -Seed @{ Cancel = $true })
    Test-Check 'cancelled sign-in' ((Get-ThrownText { Connect-AVDTuneSession -Session $s5 -TenantId $tenant -ClientId $clientId }) -like 'Sign-in cancelled*') $null
    $s6 = New-AVDTuneSession -TempRoot $signTemp -Auth (New-AVDTuneFakeAuth -Seed @{ NoRefreshToken = $true })
    Test-Check 'no refresh token (offline_access missing) is an error' ($null -ne (Get-ThrownText { Connect-AVDTuneSession -Session $s6 -TenantId $tenant -ClientId $clientId })) $null
    Test-Check 'the setup app of Microsoft and a non-GUID client are refused before any sign-in' ((Get-ThrownText { Connect-AVDTuneSession -Session $s5 -TenantId $tenant -ClientId '14d82eec-204b-4c2f-b7e8-296a70dab67e' }) -like '*setup app*' -and (Get-ThrownText { Connect-AVDTuneSession -Session $s5 -TenantId $tenant -ClientId 'x' }) -like '*GUID*') $null

    # ---------------------------------------------------------------- snapshot gate
    $machine = New-AVDTuneFakeMachine
    $vm = Get-AVDTuneVmIdentity $machine
    Test-Check 'VM identity from the instance metadata: subscription, resource group, VM, managed OS disk' ($vm.Available -and $vm.VmName -eq 'gm-test01' -and $vm.ResourceGroup -eq 'rg-example' -and $vm.OsDiskId -like '/subscriptions/*/disks/gm-test01_osdisk' -and $vm.SubscriptionId -match '^[0-9a-f-]{36}$') ($vm | ConvertTo-Json -Compress)
    $noAzure = Get-AVDTuneVmIdentity (New-AVDTuneFakeMachine -Seed @{ Imds = $null })
    Test-Check 'outside Azure: not available with a reason' (-not $noAzure.Available -and $noAzure.Problem -like '*not an Azure VM*') $null
    $unmanaged = Get-AVDTuneVmIdentity (New-AVDTuneFakeMachine -Seed @{ Imds = [pscustomobject]@{ compute = [pscustomobject]@{ name = 'x'; resourceGroupName = 'rg'; subscriptionId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'; storageProfile = [pscustomobject]@{ osDisk = [pscustomobject]@{ name = 'd' } } } } })
    Test-Check 'an unmanaged OS disk is refused with a reason' (-not $unmanaged.Available -and $unmanaged.Problem -like '*managed disk*') $null
    $name = Get-AVDTuneSnapshotName -VmName 'gm-test01' -ImageVersion '2026.11.001' -At ([datetime]'2026-11-15 14:07')
    Test-Check 'snapshot name: <vm>-avdtune-<image version>-<yyyyMMdd-HHmm>' ($name -eq 'gm-test01-avdtune-2026.11.001-20261115-1407') $name
    $long = Get-AVDTuneSnapshotName -VmName ('v' * 90) -ImageVersion '2026.11.001' -At ([datetime]'2026-11-15 14:07')
    Test-Check 'a long VM name is shortened to the 80 characters Azure allows, the suffix stays' ($long.Length -le 80 -and $long -like '*-avdtune-2026.11.001-20261115-1407') $long
    Test-Check 'no image version: no snapshot name (tells to start a version)' ((Get-ThrownText { Get-AVDTuneSnapshotName -VmName 'x' -ImageVersion 'none' -At (Get-Date) }) -like '*image version*') $null

    $now = [datetime]'2026-11-15 14:30'
    $armToken = 'fake-arm-token-value'
    $arm = New-AVDTuneFakeArm -Seed @{ Snapshots = @(
            @{ Name = 'gm-test01-avdtune-2026.10.001-20261030-0900'; Created = [datetime]'2026-10-30 09:00'; Tags = @{ CreatedWith = 'AVDTune'; ImageVersion = '2026.10.001' } }
            @{ Name = 'other-disk-snap'; Created = [datetime]'2026-11-15 08:00'; Source = '/subscriptions/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/resourceGroups/rg-example/providers/Microsoft.Compute/disks/another_disk' }) }
    $list = @(Get-AVDTuneOsDiskSnapshots -Arm $arm -Token $armToken -Vm $vm -Now $now)
    Test-Check 'snapshots of this OS disk only; the one of another disk is ignored' ($list.Count -eq 1 -and $list[0].Name -like '*2026.10.001*' -and $list[0].ByAVDTune) ($list | ForEach-Object Name)
    $gate = Get-AVDTuneGateStatus -Vm $vm -Snapshots $list -Confirmed $false
    Test-Check 'no snapshot from today: status NoSnapshotToday (old snapshot does not count)' ($gate.Status -eq 'NoSnapshotToday' -and -not $gate.Chosen) $gate.Status
    Test-Check 'outside Azure: gate status NoVm' ((Get-AVDTuneGateStatus -Vm $noAzure -Snapshots @() -Confirmed $false).Status -eq 'NoVm') $null

    $started = Start-AVDTuneSnapshot -Arm $arm -Token $armToken -Vm $vm -ImageVersion '2026.11.001' -User 'Alex Example' -At $now
    $put = $arm.Store.LastPut
    Test-Check 'snapshot request: incremental, copy of the OS disk, tags image version and user, in the disk region' ($put.properties.incremental -eq $true -and $put.properties.creationData.createOption -eq 'Copy' -and $put.properties.creationData.sourceResourceId -eq $vm.OsDiskId -and $put.tags.ImageVersion -eq '2026.11.001' -and $put.tags.CreatedBy -eq 'Alex Example' -and $put.tags.CreatedWith -eq 'AVDTune' -and $put.location -eq 'westeurope') ($put | ConvertTo-Json -Compress -Depth 5)
    Test-Check 'the snapshot is named as the plan says and starts as Creating' ($started.Name -eq 'gm-test01-avdtune-2026.11.001-20261115-1430' -and $started.State -eq 'Creating') ($started | ConvertTo-Json -Compress)
    Test-Check 'a snapshot that is still being created does not unlock the gate' (@(Get-AVDTuneOsDiskSnapshots -Arm $arm -Token $armToken -Vm $vm -Now $now | Where-Object IsToday).Count -eq 0) $null
    $ready = Wait-AVDTuneSnapshot -Arm $arm -Token $armToken -Id $started.Id -PollSeconds 0
    Test-Check 'polling until Succeeded' ($ready.State -eq 'Succeeded') $ready.State
    $list = @(Get-AVDTuneOsDiskSnapshots -Arm $arm -Token $armToken -Vm $vm -Now $now)
    $gate = Get-AVDTuneGateStatus -Vm $vm -Snapshots $list -Confirmed $false
    Test-Check 'with a finished snapshot of today the gate waits for the confirmation' ($gate.Status -eq 'SnapshotToday' -and $gate.Chosen.Name -eq $started.Name -and $gate.Chosen.ByAVDTune) $gate.Status
    Test-Check 'the confirmation text is the one of the plan' ((Get-AVDTuneGateText) -eq 'Ich bestaetige, dass vor diesem Lauf ein Snapshot des Golden Masters erstellt wurde und ein Rollback moeglich ist.') $null

    # confirmation: typed full name
    Test-Check 'one word or nothing is no full name' (-not (Test-AVDTuneConfirmationName -Typed 'Alex' -Expected '').Ok -and -not (Test-AVDTuneConfirmationName -Typed '' -Expected '').Ok) $null
    Test-Check 'the name must match the signed-in account when it is known (case and spacing ignored)' ((Test-AVDTuneConfirmationName -Typed '  alex   example ' -Expected 'Alex Example').Ok -and -not (Test-AVDTuneConfirmationName -Typed 'Max Mustermann' -Expected 'Alex Example').Ok) $null
    Test-Check 'a snapshot that is not from today cannot be confirmed' ((Get-ThrownText { Confirm-AVDTuneSnapshotGate -Root $tmp -Snapshot $list[-1] -TypedName 'Alex Example' -ImageVersion '2026.11.001' -Machine $machine }) -like '*of today*') $null
    Test-Check 'a wrong name does not open the gate' ($null -ne (Get-ThrownText { Confirm-AVDTuneSnapshotGate -Root $tmp -Snapshot $gate.Chosen -TypedName 'Max Mustermann' -ExpectedName 'Alex Example' -ImageVersion '2026.11.001' -Machine $machine }) -and -not (Test-AVDTuneWriteAllowed)) $null
    $stepRan = New-AVDTuneStep -Id 'setup.gatetest' -Section Setup -Title 'Gate test' -Test { param($m) @{ Compliant = ((& $m.RegGet 'HKLM:\SOFTWARE\AVDTuneGate' 'V') -eq 1); State = $null } } -Apply { param($m) & $m.RegSet 'HKLM:\SOFTWARE\AVDTuneGate' 'V' 1 'DWord' }
    Test-Check 'read only without the confirmation: a change is refused, the machine is untouched' (($null -ne (Get-ThrownText { Invoke-AVDTuneStep -Step $stepRan -Machine $machine -Mode Apply })) -and $machine.Log.Count -eq 0) $null
    Test-Check 'a dry run still works while read only' ((Invoke-AVDTuneStep -Step $stepRan -Machine $machine -Mode Apply -WhatIf).Status -eq 'WhatIf') $null
    $logBefore = @(Get-AVDTuneChangeLog -Root $tmp).Count
    $record = Confirm-AVDTuneSnapshotGate -Root $tmp -Snapshot $gate.Chosen -TypedName 'Alex  Example' -ExpectedName 'Alex Example' -User 'admin1' -ImageVersion '2026.11.001' -Machine $machine
    Test-Check 'confirmation opens the gate in memory' ((Test-AVDTuneWriteAllowed) -and (Get-AVDTuneWriteGate).SnapshotId -eq $started.Id -and (Get-AVDTuneWriteGate).ConfirmedBy -eq 'Alex Example') $null
    $st = Get-AVDTuneState $tmp
    Test-Check 'state.json records name, time, snapshot ID, created by AVDTune, who confirmed' ($st.SnapshotGate.SnapshotName -eq $started.Name -and $st.SnapshotGate.SnapshotId -eq $started.Id -and $st.SnapshotGate.CreatedByAVDTune -eq $true -and $st.SnapshotGate.ConfirmedBy -eq 'Alex Example' -and $st.SnapshotGate.ConfirmedAt -and $st.SnapshotGate.Text -like 'Ich bestaetige*') ($st.SnapshotGate | ConvertTo-Json -Compress)
    $cl = @(Get-AVDTuneChangeLog -Root $tmp)
    $entry = $cl | Where-Object { $_.Category -eq 'Snapshot' } | Select-Object -First 1
    Test-Check 'the change log has one snapshot entry with name, time, snapshot ID and "created by AVDTune: yes"' ($cl.Count -eq $logBefore + 1 -and $entry.SnapshotId -eq $started.Id -and $entry.Text -like "*$($started.Name)*" -and $entry.Text -like '*created by AVDTune: yes*' -and $entry.Text -match '\d{4}-\d{2}-\d{2} \d{2}:\d{2}') ($entry | ConvertTo-Json -Compress)
    Test-Check 'a change works after the confirmation' ((Invoke-AVDTuneStep -Step $stepRan -Machine $machine -Mode Apply).Status -eq 'Changed') $null
    $stages = Get-AVDTuneStartStages -Context (New-AVDTuneStartContext) -Root $tmp
    Test-Check 'the snapshot stage shows Done with the name of the confirming person' (($stages | Where-Object Id -eq 'Snapshot').Status -eq 'Done' -and ($stages | Where-Object Id -eq 'Snapshot').Detail -like '*Alex Example*') $null
    Close-AVDTuneWriteGate
    Test-Check 'a new start is closed again (the gate is memory only)' (-not (Test-AVDTuneWriteAllowed)) $null

    # an existing snapshot of today made by someone else
    $armOther = New-AVDTuneFakeArm -Seed @{ Snapshots = @(@{ Name = 'manual-snap-before-patching'; Created = [datetime]'2026-11-15 09:10' }) }
    $listOther = @(Get-AVDTuneOsDiskSnapshots -Arm $armOther -Token $armToken -Vm $vm -Now $now)
    Test-Check 'an existing snapshot of today is found and counts (not made by AVDTune)' ($listOther.Count -eq 1 -and $listOther[0].IsToday -and -not $listOther[0].ByAVDTune) ($listOther | ConvertTo-Json -Compress -Depth 3)
    [void](Confirm-AVDTuneSnapshotGate -Root $tmp -Snapshot $listOther[0] -TypedName 'Alex Example' -User 'admin1' -ImageVersion '2026.11.001' -Machine $machine)
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
    Test-Check 'nextLink on the ARM host is followed' (@(Get-AVDTuneOsDiskSnapshots -Arm $armPaged -Token $armToken -Vm $vm -Now $now).Count -eq 1 -and @($armPaged.Log | Where-Object { $_ -like '*page2*' }).Count -eq 1) $null
    $armEvil = New-AVDTuneFakeArm -Seed @{}; $armEvil.Store.EvilLink = $true
    Test-Check 'a nextLink to another host is refused (the token is not sent there)' ((Get-ThrownText { Get-AVDTuneOsDiskSnapshots -Arm $armEvil -Token $armToken -Vm $vm }) -like '*another host*') $null
    Test-Check 'a snapshot ID is checked before it is used as a path' ($null -ne (Get-ThrownText { Get-AVDTuneSnapshotState -Arm $arm -Token $armToken -Id '/subscriptions/x/../../evil' })) $null
    # the real ARM adapter refuses foreign paths without a network call
    $realArm = New-AVDTuneArmAdapter
    Test-Check 'real ARM adapter refuses a path outside /subscriptions and path tricks' ((& $realArm.Invoke GET '/tenants?api-version=1' 't' $null).Status -eq 0 -and (& $realArm.Invoke GET '/subscriptions/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/../x' 't' $null).Status -eq 0) $null
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
    $r5 = Connect-AVDTuneDirectory -Ldap $ldap2 -Server 'DC2.example.test' -User 'svc@example.test' -Password $pw -Pins @{} -ConfirmWithoutLdaps
    $o2 = $ldap2.Opened[0]
    Test-Check 'DNS name, confirmed: LDAP 389 with Kerberos only (NTLM refused), signing and sealing' ($r5.Status -eq 'Connected' -and $o2.Port -eq 389 -and -not $o2.Ssl -and $o2.Signing -and $o2.Sealing -and $o2.AuthType -eq 'Kerberos' -and $o2.RiskConfirmed -and $r5.Security -like '*Kerberos*confirmed*') ($o2 | ConvertTo-Json -Compress)
    $r6n = Connect-AVDTuneDirectory -Ldap $ldap2 -Server '10.0.0.20' -User 'EXAMPLE\svc' -Password $pw -Pins @{}
    Test-Check 'IP address, 636 blocked: the warning names NTLM, relay and offline cracking; nothing sent' ($r6n.Status -eq 'NeedsConfirmation' -and $r6n.IsIp -and $r6n.Warning -like '*NTLM*relay*crack the password offline*' -and $ldap2.Opened.Count -eq 1) $r6n.Warning
    $r6 = Connect-AVDTuneDirectory -Ldap $ldap2 -Server '10.0.0.20' -User 'EXAMPLE\svc' -Password $pw -Pins @{} -ConfirmWithoutLdaps
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
    $rd = Connect-AVDTuneDirectory -Ldap $ldapDown -Server '10.9.9.9' -User 'EXAMPLE\svc' -Password $pw -ConfirmWithoutLdaps
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

    # ---------------------------------------------------------------- WebView2 DLLs (finding 2): checked before every load
    $wv = Join-Path $tmp 'WebView2'; $trustFile = Join-Path $tmp 'config\webview2-trust.json'
    $names = 'Microsoft.Web.WebView2.Core.dll', 'Microsoft.Web.WebView2.Wpf.dll', 'WebView2Loader.dll'
    $msFile = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'   # signed by Microsoft (catalog), stands in for the SDK files
    Test-Check 'signature check: a Microsoft-signed file passes (signer, chain to a Microsoft root)' ((Test-AVDTuneMicrosoftSignature -Path $msFile).Ok) (Test-AVDTuneMicrosoftSignature -Path $msFile).Reason
    Test-Check 'no cache folder: nothing to check, the shared code downloads and checks' ((Assert-AVDTuneWebView2Cache -Folder $wv -TrustFile $trustFile).Status -eq 'Empty') $null
    New-Item -ItemType Directory -Path $wv -Force | Out-Null
    foreach ($n in $names) { [IO.File]::WriteAllText((Join-Path $wv $n), 'MZ planted by a user without admin rights') }
    $r = Assert-AVDTuneWebView2Cache -Folder $wv -TrustFile $trustFile
    Test-Check 'attack: DLLs planted before the first start without a valid signature are deleted before anything loads them' ($r.Status -eq 'Reset' -and -not (Test-Path $wv)) ($r | ConvertTo-Json -Compress)
    New-Item -ItemType Directory -Path $wv -Force | Out-Null
    foreach ($n in $names) { Copy-Item $msFile (Join-Path $wv $n) }
    $r = Assert-AVDTuneWebView2Cache -Folder $wv -TrustFile $trustFile
    Test-Check 'even Microsoft-signed files without AVDTune''s trust record are not loaded (could be an old, weak version)' ($r.Status -eq 'Reset' -and -not (Test-Path $wv) -and ($r.Problems -join ' ') -like '*trust record*') ($r.Problems -join '; ')
    New-Item -ItemType Directory -Path $wv -Force | Out-Null
    foreach ($n in $names) { Copy-Item $msFile (Join-Path $wv $n) }
    $reg = Register-AVDTuneWebView2Cache -Folder $wv -TrustFile $trustFile
    $tr = Read-AVDTuneJson $trustFile
    Test-Check 'after a download that passes the check the trust record holds SHA-256, file version and signer per file' ($reg.Status -eq 'Registered' -and @($tr.Files).Count -eq 3 -and $tr.Files[0].Sha256 -match '^[0-9A-F]{64}$' -and $tr.Files[0].Version -and $tr.Files[0].Signer -like '*Microsoft Corporation*') ($reg | ConvertTo-Json -Compress)
    Test-Check 'the next sign-in loads the trusted files' ((Assert-AVDTuneWebView2Cache -Folder $wv -TrustFile $trustFile).Status -eq 'Trusted') $null
    Copy-Item (Join-Path $env:SystemRoot 'System32\cmd.exe') (Join-Path $wv 'WebView2Loader.dll') -Force
    $r = Assert-AVDTuneWebView2Cache -Folder $wv -TrustFile $trustFile
    Test-Check 'a swapped file (even one signed by Microsoft) differs from the trust record: folder deleted' ($r.Status -eq 'Reset' -and ($r.Problems -join ' ') -like '*WebView2Loader.dll*SHA-256*' -and -not (Test-Path $wv)) ($r.Problems -join '; ')
    New-Item -ItemType Directory -Path $wv -Force | Out-Null
    foreach ($n in $names) { Copy-Item $msFile (Join-Path $wv $n) }
    [IO.File]::WriteAllText((Join-Path $wv 'version.dll'), 'MZ side loaded')
    $r = Assert-AVDTuneWebView2Cache -Folder $wv -TrustFile $trustFile
    Test-Check 'an extra DLL next to the trusted ones (side loading) is refused: folder deleted' ($r.Status -eq 'Reset' -and ($r.Problems -join ' ') -like '*unexpected file version.dll*' -and -not (Test-Path $wv)) ($r.Problems -join '; ')
    New-Item -ItemType Directory -Path $wv -Force | Out-Null
    foreach ($n in $names) { [IO.File]::WriteAllText((Join-Path $wv $n), 'MZ unsigned') }
    $reg = Register-AVDTuneWebView2Cache -Folder $wv -TrustFile $trustFile
    Test-Check 'files that fail the check after a download are deleted and the trust record is removed' ($reg.Status -eq 'Reset' -and -not (Test-Path $wv) -and -not (Test-Path $trustFile)) ($reg | ConvertTo-Json -Compress)
    $target = Join-Path $tmp 'junction-target'; New-Item -ItemType Directory -Path $target -Force | Out-Null; [IO.File]::WriteAllText((Join-Path $target 'keep.txt'), 'x')
    New-Item -ItemType Junction -Path $wv -Value $target | Out-Null
    $r = Assert-AVDTuneWebView2Cache -Folder $wv -TrustFile $trustFile
    Test-Check 'a cache folder that is a link is removed as a link; the target is not touched' ($r.Status -eq 'Reset' -and -not (Test-Path $wv) -and (Test-Path (Join-Path $target 'keep.txt'))) ($r.Problems -join '; ')
    New-Item -ItemType Directory -Path $wv -Force | Out-Null
    foreach ($n in $names) { [IO.File]::WriteAllText((Join-Path $wv $n), 'MZ planted') }
    $hold = [IO.File]::Open((Join-Path $wv $names[0]), 'Open', 'Read', 'None')
    try { $e = Get-ThrownText { Assert-AVDTuneWebView2Cache -Folder $wv -TrustFile $trustFile } } finally { $hold.Dispose() }
    Test-Check 'untrusted files that cannot be deleted stop the sign-in (nothing is loaded)' ($e -like '*not trusted*sign-in is stopped*') $e
    Remove-Item $wv -Recurse -Force

    # ---------------------------------------------------------------- no Keevault (user decision 2026-11-15): normal Microsoft sign-in only
    $kvPattern = '(?i)\b(Find|Connect|Close|Send|Invoke)-Kee' + 'vaultMcp\w*|Connect-PackTuneWith' + 'Keevault|request_' + 'microsoft_login|get_' + 'totp|sign_in_with_' + 'passkey'
    $own = @(Get-ChildItem $repo -Recurse -File -Include '*.ps1', '*.psm1', '*.xaml' | Where-Object { $_.FullName -notlike (Join-Path $repo 'Shared\*') -and $_.FullName -notlike '*\.git\*' })
    $kvHits = @($own | Where-Object { [IO.File]::ReadAllText($_.FullName) -match $kvPattern } | ForEach-Object { $_.FullName.Substring($repo.Length + 1) })
    Test-Check 'no AVDTune code outside Shared\ calls a Keevault function' ($own.Count -gt 10 -and $kvHits.Count -eq 0) ($kvHits -join ', ')
    $sessCode = [IO.File]::ReadAllText((Join-Path $repo 'Modules\AVDTune.Session.psm1'))
    Test-Check 'the sign-in imports only the normal sign-in functions of the shared module and fills in nothing' ($sessCode -match 'Import-Module \$shared -Force -Function Invoke-PackTuneBrowserSignIn, Request-PackTuneToken, Set-PackTuneSignInLog\r?\n' -and $sessCode -match 'Invoke-PackTuneBrowserSignIn -TenantID' -and $sessCode -notmatch '(?i)-Fill\b|-Passkey\b|-HasOtp\b') $null

    # ---------------------------------------------------------------- nothing secret on disk, source rules
    $allText = (Get-ChildItem $tmp -Recurse -File | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join "`n"
    Test-Check 'no password, token or refresh token in any file of the state folder' ($allText -notmatch [regex]::Escape($secretPassword) -and $allText -notmatch 'eyJ[A-Za-z0-9_-]{10,}' -and $allText -notmatch 'fake-refresh' -and $allText -notmatch 'fake-arm-token') $null
    $logText = (@($ldap.Log) + @($ldap2.Log) + @($arm.Log) + @($auth.Log) | Out-String)
    Test-Check 'no password or token in the logs of the fakes' ($logText -notmatch [regex]::Escape($secretPassword) -and $logText -notmatch 'fake-arm-token-value') $null
    $dirSource = [IO.File]::ReadAllText((Join-Path $repo 'Modules\AVDTune.Directory.psm1'))
    $code = ($dirSource -split "`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
    Test-Check 'Directory module: no simple bind, anonymous bind or clear-text password in the code' ($code -notmatch '(?i)AuthType\]::(Basic|Anonymous|Ntlm|Digest|Sicily|Msn|Dpa|External)' -and $code -notmatch 'ConvertTo-SecureString|AsPlainText|SecureStringToBSTR|SecureStringToGlobalAllocUnicode|ConvertFrom-AVDTuneSecure' -and $code -match 'AuthType\]::Negotiate' -and $code -match 'AuthType\]::Kerberos') $null
    Test-Check 'real LDAP adapter: the server name is used as given (LdapDirectoryIdentifier with fullyQualifiedDnsHostName = true)' ($code -match 'LdapDirectoryIdentifier\(\$Options\.Server, \[int\]\$Options\.Port, \$true, \$false\)') $null
    $nonAscii = @('Modules\AVDTune.Start.psm1', 'Modules\AVDTune.Session.psm1', 'Modules\AVDTune.Snapshot.psm1', 'Modules\AVDTune.Directory.psm1', 'Tests\Fakes\FakeServices.ps1', 'Tests\Check-Start.ps1') | Where-Object { [IO.File]::ReadAllText((Join-Path $repo $_)) -match '[^\x00-\x7F]' }
    Test-Check 'new files are plain ASCII' ($nonAscii.Count -eq 0) ($nonAscii -join ',')
    $sessSource = [IO.File]::ReadAllText((Join-Path $repo 'Modules\AVDTune.Session.psm1'))
    Test-Check 'Session module writes nothing to disk and prints no token' ($sessSource -notmatch 'Set-Content|Out-File|WriteAllText|Write-AVDTuneFile|Write-Host|Write-Output') $null
    $sharedUntouched = & git -C $repo status --porcelain -- Shared 2>$null
    Test-Check 'Shared\ is not edited by this feature' (-not $sharedUntouched) ($sharedUntouched -join ';')
}
catch { $script:failed++; "FAIL check aborted: $($_.Exception.Message) @ $($_.InvocationInfo.ScriptLineNumber)" }
finally {
    $env:AVDTUNE_ROOT = $null; $env:AVDTUNE_FAKE = $null
    Close-AVDTuneWriteGate
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
if ($script:failed -gt 0) { "Check-Start: $($script:failed) check(s) failed."; exit 1 }
'Check-Start: all checks passed.'
