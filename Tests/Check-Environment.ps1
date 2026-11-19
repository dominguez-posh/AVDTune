#requires -Version 5.1
<#
.SYNOPSIS
    Checks the environment wizard (Modules\AVDTune.Environment.psm1, issue 32) against the fake Azure Resource Manager (Tests\Fakes\FakeEnvArm.ps1): the identity models, the
    plan (read only), the confirmation by plan hash, the write gate, every resource of the FSLogix storage setup with asynchronous operations (Azure-AsyncOperation, Location,
    polling the resource) and the answers 400, 403, 409, the journal, the change log and the undo that only takes back what AVDTune created. Counter-tests for the points of
    docs\security-checklist.md that the wizard touches (names in paths, allowlist of writes, polling links on the ARM host only, secrets, write gate and LastChange, change log
    and undo, data as data). Nothing touches this computer, a network or a tenant.
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
foreach ($mod in 'AVDTune', 'AVDTune.Updates', 'AVDTune.Snapshot', 'AVDTune.Directory', 'AVDTune.FSLogix', 'AVDTune.Storage', 'AVDTune.Environment') { Import-Module (Join-Path $repo "Modules\$mod.psm1") -Force }
. (Join-Path $PSScriptRoot 'Fakes\FakeMachine.ps1')
. (Join-Path $PSScriptRoot 'Fakes\FakeFSLogix.ps1')
. (Join-Path $PSScriptRoot 'Fakes\FakeStorage.ps1')
. (Join-Path $PSScriptRoot 'Fakes\FakeEnvArm.ps1')

$script:failed = 0
function Test-Check([string]$Name, [bool]$Ok, $Detail) { if ($Ok) { "PASS $Name" } else { $script:failed++; "FAIL $Name" + $(if ($null -ne $Detail) { "  -> $Detail" }) } }
function Test-Throws([scriptblock]$Block) { try { & $Block | Out-Null; $false } catch { $true } }
function Get-Thrown([scriptblock]$Block) { try { & $Block | Out-Null; '' } catch { $_.Exception.Message } }

$sub = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
$tok = 'tok-env-SECRET-9'
$g1 = '11111111-1111-1111-1111-111111111111'; $g2 = '22222222-2222-2222-2222-222222222222'
$subnet = "/subscriptions/$sub/resourceGroups/rg-network/providers/Microsoft.Network/virtualNetworks/vnet-avd/subnets/snet-avd"
$acc = '/subscriptions/{0}/resourceGroups/rg-example/providers/Microsoft.Storage/storageAccounts/contosoprofiles' -f $sub
function New-Spec([hashtable]$O = @{}) {
    $h = [ordered]@{ SubscriptionId = $sub; ResourceGroup = 'rg-example'; Location = 'westeurope'; AccountName = 'contosoprofiles'; Sku = 'Premium_LRS'; ShareName = 'profiles'; Users = 200; GiBPerUser = 30
        Endpoint = 'Private'; SubnetId = $subnet; PrivateEndpointName = 'pe-contosoprofiles'; DnsZone = 'Azure'; DnsZoneResourceGroup = 'rg-network'; UsersGroupId = $g1; AdminsGroupId = $g2; DomainName = ''; DomainGuid = ''; AllowedIps = @() }
    foreach ($k in $O.Keys) { $h[$k] = $O[$k] }
    [pscustomobject]$h
}
function Get-Step($Plan, [string]$Id) { @($Plan.Steps | Where-Object Id -eq $Id)[0] }
function Get-Writes($Arm) { @($Arm.Store.Writes) }
function Get-AllText($Root) { (Get-ChildItem -LiteralPath $Root -Recurse -File | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join "`n" }
function New-Root {
    $r = Join-Path ([IO.Path]::GetTempPath()) ('avdtune-env-' + [guid]::NewGuid().ToString('N'))
    $wasOpen = Get-AVDTuneWriteGate
    [void](Initialize-AVDTuneState -Root $r)
    [void](Start-AVDTuneImageVersion -Root $r -Date ([datetime]'2026-11-15') -User 'admin1')
    # a new image version closes the gate (#27); the wizard checks work with an open gate on every new root: put it back as it was
    if ($wasOpen) { Open-AVDTuneWriteGate -SnapshotId $wasOpen.SnapshotId -ConfirmedBy $wasOpen.ConfirmedBy }
    $r
}
function Invoke-Full($Arm, $Spec, [string]$Root, [string]$Identity = 'EntraKerberos', [hashtable]$Extra = @{}) {
    $p = Get-AVDTuneEnvPlan -Arm $Arm -Token $tok -Spec $Spec -Identity $Identity -User 'Test User' -ImageVersion '2026.11.001'
    $a = @{ Arm = $Arm; Token = $tok; Spec = $Spec; Identity = $Identity; ConfirmedHash = $p.Hash; Root = $Root; User = 'Test User'; SnapshotId = 'snap1'; PollSeconds = 0; MaxPolls = 20 }
    foreach ($k in $Extra.Keys) { $a[$k] = $Extra[$k] }
    Invoke-AVDTuneEnvApply @a
}

$roots = @()
try {
    $env:AVDTUNE_ROOT = $null
    Close-AVDTuneWriteGate

    # ---------------------------------------------------------------- names and the spec (checklist: path segments built from data are validated)
    $good = New-Spec
    Test-Check 'a good spec has no errors' ((Test-AVDTuneEnvSpec $good).Count -eq 0) ((Test-AVDTuneEnvSpec $good) -join '|')
    foreach ($case in @(
            @{ N = 'account name with upper case'; O = @{ AccountName = 'StProfiles' } }, @{ N = 'account name too short'; O = @{ AccountName = 'ab' } }, @{ N = 'account name with a slash'; O = @{ AccountName = 'st/../x' } },
            @{ N = 'resource group with a slash'; O = @{ ResourceGroup = 'rg/../other' } }, @{ N = 'resource group with a question mark'; O = @{ ResourceGroup = 'rg?x=1' } }, @{ N = 'resource group with a hash'; O = @{ ResourceGroup = 'rg#x' } },
            @{ N = 'share name with two hyphens'; O = @{ ShareName = 'pro--files' } }, @{ N = 'standard SKU'; O = @{ Sku = 'Standard_LRS' } }, @{ N = 'subscription not a GUID'; O = @{ SubscriptionId = 'x' } },
            @{ N = 'subnet that is a path to another type'; O = @{ SubnetId = "/subscriptions/$sub/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1" } }, @{ N = 'endpoint name with spaces'; O = @{ PrivateEndpointName = 'pe name' } },
            @{ N = 'group that is not a GUID'; O = @{ UsersGroupId = 'everyone' } }, @{ N = 'location with a slash'; O = @{ Location = 'west/europe' } }, @{ N = 'too large for one share'; O = @{ Users = 5000; GiBPerUser = 30 } },
            @{ N = 'domain name without GUID'; O = @{ DomainName = 'example.test' } }, @{ N = 'zone resource group with a slash'; O = @{ DnsZoneResourceGroup = '../x' } })) {
        Test-Check "spec refused: $($case.N)" ((Test-AVDTuneEnvSpec (New-Spec $case.O)).Count -ge 1) $null
    }
    Test-Check 'public endpoint: an IP list is checked, a name is refused' ((Test-AVDTuneEnvSpec (New-Spec @{ Endpoint = 'Public'; AllowedIps = @('203.0.113.0/24') })).Count -eq 0 -and (Test-AVDTuneEnvSpec (New-Spec @{ Endpoint = 'Public'; AllowedIps = @('*.example.test') })).Count -eq 1) $null
    $q = Get-AVDTuneEnvQuota -Users 200 -GiBPerUser 30; $q2 = Get-AVDTuneEnvQuota -Users 2 -GiBPerUser 5
    Test-Check 'quota: users x GiB, Premium minimum 100, IOPS and throughput shown' ($q.GiB -eq 6000 -and $q.Iops -eq 9000 -and $q.MiBPerSecond -eq 700 -and $q2.GiB -eq 100) ($q | ConvertTo-Json -Compress)
    Test-Check 'Entra SID from an object ID (four little endian numbers)' ((ConvertTo-AVDTuneEntraSid '00000000-0000-0000-0000-000000000000') -eq 'S-1-12-1-0-0-0-0' -and (ConvertTo-AVDTuneEntraSid '11111111-1111-1111-1111-111111111111') -eq 'S-1-12-1-286331153-286331153-286331153-286331153' -and (Test-Throws { ConvertTo-AVDTuneEntraSid 'nope' })) (ConvertTo-AVDTuneEntraSid '11111111-1111-1111-1111-111111111111')
    $c1 = ConvertTo-AVDTuneEnvCanonical @{ b = 1; a = @{ y = 'x'; x = $true } }; $c2 = ConvertTo-AVDTuneEnvCanonical ([ordered]@{ a = [ordered]@{ x = $true; y = 'x' }; b = 1 })
    Test-Check 'canonical form does not depend on the key order (the plan hash is stable)' ($c1 -eq $c2) "$c1 / $c2"
    Test-Check 'role assignment names are fixed per scope, principal and role' ((Get-AVDTuneEnvRoleName 's' 'p' 'r') -eq (Get-AVDTuneEnvRoleName 'S' 'P' 'R') -and (Get-AVDTuneEnvRoleName 's' 'p' 'r') -ne (Get-AVDTuneEnvRoleName 's' 'p2' 'r') -and (Test-AVDTuneEnvGuid (Get-AVDTuneEnvRoleName 's' 'p' 'r'))) $null

    # ---------------------------------------------------------------- identity models
    $ek = Get-AVDTuneEnvIdentityModel -Identity EntraKerberos -Identities CloudOnly
    $eh = Get-AVDTuneEnvIdentityModel -Identity EntraKerberos -Identities Synced
    $ed = Get-AVDTuneEnvIdentityModel -Identity EntraDs
    $ad = Get-AVDTuneEnvIdentityModel -Identity AdDs
    Test-Check 'Entra Kerberos: AADKERB, consent and Conditional Access by hand, the cloud-only groups tag only for cloud-only identities' ($ek.DirectoryServiceOptions -eq 'AADKERB' -and $ek.Automatic -and @($ek.Manual).Count -eq 3 -and @($eh.Manual).Count -eq 2 -and ($ek.Manual.Text -join ' ') -like '*1327*') (($ek.Manual | ForEach-Object Id) -join ',')
    Test-Check 'Entra Domain Services: AADDS, automatic; AD DS: AD, not automatic, the reason is named' ($ed.DirectoryServiceOptions -eq 'AADDS' -and $ed.Automatic -and $ad.DirectoryServiceOptions -eq 'AD' -and -not $ad.Automatic -and $ad.Manual[0].Text -like '*no write path*') $null

    # ---------------------------------------------------------------- allowlist of writes (checklist: network, ARM only through the adapter with an allowlist)
    $v = "api-version=2024-01-01"
    $okPath = "$acc`?$v"
    Test-Check 'allowlist: PUT, PATCH, DELETE of the account and the other resource types pass' (-not (Test-Throws { Assert-AVDTuneEnvArmPath $okPath 'PUT' }) -and -not (Test-Throws { Assert-AVDTuneEnvArmPath $okPath 'PATCH' }) -and -not (Test-Throws { Assert-AVDTuneEnvArmPath "$acc/fileServices/default/shares/profiles`?$v" 'DELETE' })) $null
    foreach ($bad in @(
            @{ N = 'POST (listKeys, regenerateKey) never'; P = "$acc/listKeys`?$v"; M = 'POST' }, @{ N = 'PUT of a virtual machine'; P = "/subscriptions/$sub/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1?api-version=2023-10-02"; M = 'PUT' },
            @{ N = 'DELETE of the file service'; P = "$acc/fileServices/default`?$v"; M = 'DELETE' }, @{ N = 'PUT of the storage account with another api version'; P = "$acc`?api-version=2019-06-01"; M = 'PUT' },
            @{ N = 'a second query value in a write'; P = "$acc`?$v&x=1"; M = 'PUT' }, @{ N = 'a hash'; P = "$acc`?$v#x"; M = 'GET' }, @{ N = 'dot dot'; P = "$acc/../x`?$v"; M = 'GET' },
            @{ N = 'two question marks'; P = "$acc`?$v?x"; M = 'GET' }, @{ N = 'a blank in the path'; P = "$acc x`?$v"; M = 'GET' }, @{ N = 'a path outside a subscription'; P = "/providers/Microsoft.Authorization/roleAssignments/x?$v"; M = 'GET' },
            @{ N = 'a DNS zone other than the file zone'; P = "/subscriptions/$sub/resourceGroups/rg/providers/Microsoft.Network/privateDnsZones/example.test?api-version=2020-06-01"; M = 'PUT' },
            @{ N = 'a role assignment at the subscription'; P = "/subscriptions/$sub/providers/Microsoft.Authorization/roleAssignments/$g1`?api-version=2022-04-01"; M = 'PUT' })) {
        Test-Check "allowlist refuses: $($bad.N)" (Test-Throws { Assert-AVDTuneEnvArmPath $bad.P $bad.M }) $null
    }
    $spy = New-AVDTuneFakeEnvArm
    Test-Check 'a refused path never reaches the adapter' ((Test-Throws { Invoke-AVDTuneEnvArmRaw -Arm $spy -Method POST -Path "$acc/listKeys`?$v" -Token $tok }) -and $spy.Log.Count -eq 0) $null

    # ---------------------------------------------------------------- the plan on an empty resource group (read only)
    $root = New-Root; $roots += $root
    $arm = New-AVDTuneFakeEnvArm
    $plan = Get-AVDTuneEnvPlan -Arm $arm -Token $tok -Spec $good -Identity EntraKerberos -Identities CloudOnly -User 'Test User' -ImageVersion '2026.11.001'
    Test-Check 'plan: only reads, not one write, no key, no POST' ((Get-Writes $arm).Count -eq 0 -and @($arm.Log | Where-Object { $_ -notlike 'GET *' }).Count -eq 0) ($arm.Log -join '|')
    $ids = (@($plan.Steps | Where-Object { $_.Action -in 'Create', 'Update' } | ForEach-Object Id)) -join ','
    Test-Check 'plan: account, SMB, share, zone, link, endpoint, zone group, identity, two roles in this order' ($ids -eq 'env.account,env.smb,env.share,env.dnszone,env.dnslink,env.endpoint,env.dnsgroup,env.identity,env.role-users,env.role-admins') $ids
    $b = (Get-Step $plan 'env.account').Body
    Test-Check 'plan: account is FileStorage Premium, TLS 1.2, HTTPS only, no public blob access, public network access off, tagged by AVDTune' ($b.kind -eq 'FileStorage' -and $b.sku.name -eq 'Premium_LRS' -and $b.properties.minimumTlsVersion -eq 'TLS1_2' -and $b.properties.supportsHttpsTrafficOnly -and -not $b.properties.allowBlobPublicAccess -and $b.properties.publicNetworkAccess -eq 'Disabled' -and $b.tags.CreatedWith -eq 'AVDTune' -and $b.tags.CreatedBy -eq 'Test User') ($b | ConvertTo-Json -Depth 5 -Compress)
    $sm = (Get-Step $plan 'env.smb').Body.properties.protocolSettings.smb
    Test-Check 'plan: SMB 3.1.1, Kerberos only, AES-256 ticket, AES-256-GCM' ($sm.versions -eq 'SMB3.1.1' -and $sm.authenticationMethods -eq 'Kerberos' -and $sm.kerberosTicketEncryption -eq 'AES-256' -and $sm.channelEncryption -eq 'AES-256-GCM') $null
    $shb = (Get-Step $plan 'env.share').Body.properties
    Test-Check 'plan: share is Premium SMB with the quota from users x GiB' ($shb.shareQuota -eq 6000 -and $shb.accessTier -eq 'Premium' -and $shb.enabledProtocols -eq 'SMB' -and $plan.Quota.GiB -eq 6000) $null
    $pb = (Get-Step $plan 'env.endpoint').Body
    Test-Check 'plan: private endpoint for group file in the subnet, in the region of the VNet' ($pb.properties.privateLinkServiceConnections[0].properties.groupIds[0] -eq 'file' -and $pb.properties.subnet.id -eq $subnet -and $pb.location -eq 'westeurope') $null
    Test-Check 'plan: the identity step is AADKERB' ((Get-Step $plan 'env.identity').Body.properties.azureFilesIdentityBasedAuthentication.directoryServiceOptions -eq 'AADKERB') $null
    $rb = (Get-Step $plan 'env.role-users').Body.properties
    Test-Check 'plan: share level roles for the groups, on the share only, principal type Group' ($rb.principalId -eq $g1 -and $rb.principalType -eq 'Group' -and $rb.roleDefinitionId -like '*0c867c2a-1d8c-454a-a3db-ab2ea1bdc8bb' -and (Get-Step $plan 'env.role-users').Path -like '*/fileshares/profiles/providers/Microsoft.Authorization/roleAssignments/*' -and (Get-Step $plan 'env.role-admins').Body.properties.roleDefinitionId -like '*a7264617-510b-434b-a828-9731dc254ea7') $null
    Test-Check 'plan: NTFS, master and test are shown as deferred, the manual steps of Entra Kerberos are listed' ((Get-Step $plan 'env.acl').Action -eq 'Deferred' -and (Get-Step $plan 'env.master').Action -eq 'Deferred' -and (Get-Step $plan 'env.test').Action -eq 'Deferred' -and (Get-Step $plan 'env.consent').Action -eq 'Manual' -and (Get-Step $plan 'env.ca').Action -eq 'Manual') $null
    $plan2 = Get-AVDTuneEnvPlan -Arm $arm -Token $tok -Spec $good -Identity EntraKerberos -Identities CloudOnly -User 'Test User' -ImageVersion '2026.11.001'
    $plan3 = Get-AVDTuneEnvPlan -Arm $arm -Token $tok -Spec (New-Spec @{ ShareName = 'profiles2' }) -Identity EntraKerberos -Identities CloudOnly -User 'Test User' -ImageVersion '2026.11.001'
    Test-Check 'plan hash: the same plan twice gives the same hash, another share another hash' ($plan.Hash -eq $plan2.Hash -and $plan.Hash -ne $plan3.Hash) $null
    Test-Check 'plan: the rights were checked (all given) and the token is nowhere in the plan' ($plan.Rights.Missing.Count -eq 0 -and ($plan | ConvertTo-Json -Depth 8) -notmatch 'SECRET') $null
    Test-Check 'plan refuses a spec with a bad name before any request' ((Test-Throws { Get-AVDTuneEnvPlan -Arm $spy -Token $tok -Spec (New-Spec @{ ResourceGroup = 'rg/../x' }) }) -and $spy.Log.Count -eq 0) $null

    # variants
    $pub = Get-AVDTuneEnvPlan -Arm (New-AVDTuneFakeEnvArm) -Token $tok -Spec (New-Spec @{ Endpoint = 'Public'; AllowedIps = @('203.0.113.0/24') }) -User 'u'
    $pa = (Get-Step $pub 'env.account').Body.properties
    Test-Check 'public endpoint: firewall default deny with the listed range, public access on, no endpoint or zone steps, a warning' ($pa.publicNetworkAccess -eq 'Enabled' -and $pa.networkAcls.defaultAction -eq 'Deny' -and $pa.networkAcls.ipRules[0].value -eq '203.0.113.0/24' -and $null -eq (Get-Step $pub 'env.endpoint') -and $null -eq (Get-Step $pub 'env.dnszone') -and ($pub.Warnings -join ' ') -like '*Public endpoint*') ($pub.Steps.Id -join ',')
    $own = Get-AVDTuneEnvPlan -Arm (New-AVDTuneFakeEnvArm) -Token $tok -Spec (New-Spec @{ DnsZone = 'OwnDns' }) -User 'u'
    Test-Check 'own DNS servers: endpoint yes, zone, link and zone group no, a manual DNS record step' ((Get-Step $own 'env.endpoint').Action -eq 'Create' -and $null -eq (Get-Step $own 'env.dnszone') -and $null -eq (Get-Step $own 'env.dnsgroup') -and (Get-Step $own 'env.dnsrecord').Action -eq 'Manual') $null
    $adp = Get-AVDTuneEnvPlan -Arm (New-AVDTuneFakeEnvArm) -Token $tok -Spec $good -Identity AdDs -User 'u'
    Test-Check 'AD DS: no identity request, a manual step with the reason' ($null -eq (Get-Step $adp 'env.identity') -and (Get-Step $adp 'env.adds').Action -eq 'Manual') $null
    $dsp = Get-AVDTuneEnvPlan -Arm (New-AVDTuneFakeEnvArm) -Token $tok -Spec $good -Identity EntraDs -User 'u'
    Test-Check 'Entra Domain Services: the identity step is AADDS' ((Get-Step $dsp 'env.identity').Body.properties.azureFilesIdentityBasedAuthentication.directoryServiceOptions -eq 'AADDS') $null
    $hyb = Get-AVDTuneEnvPlan -Arm (New-AVDTuneFakeEnvArm) -Token $tok -Spec (New-Spec @{ DomainName = 'example.test'; DomainGuid = '33333333-3333-3333-3333-333333333333' }) -Identity EntraKerberos -Identities Synced -User 'u'
    $hp = (Get-Step $hyb 'env.identity').Body.properties.azureFilesIdentityBasedAuthentication
    Test-Check 'Entra Kerberos for hybrid identities: domain name and GUID go into activeDirectoryProperties' ($hp.activeDirectoryProperties.domainName -eq 'example.test' -and $hp.activeDirectoryProperties.domainGuid -eq '33333333-3333-3333-3333-333333333333') $null
    $nog = Get-AVDTuneEnvPlan -Arm (New-AVDTuneFakeEnvArm) -Token $tok -Spec (New-Spec @{ UsersGroupId = ''; AdminsGroupId = '' }) -User 'u'
    Test-Check 'no groups entered: the roles are manual steps, nothing is guessed' ((Get-Step $nog 'env.role-users').Action -eq 'Manual' -and (Get-Step $nog 'env.role-admins').Action -eq 'Manual') $null

    # existing resources
    $accKey = $acc.ToLowerInvariant()
    $std = New-AVDTuneFakeEnvArm -Seed @{ Resources = @{ $accKey = @{ name = 'contosoprofiles'; kind = 'StorageV2'; sku = @{ name = 'Standard_LRS' }; location = 'westeurope'; properties = @{ supportsHttpsTrafficOnly = $true; minimumTlsVersion = 'TLS1_2'; allowBlobPublicAccess = $false; publicNetworkAccess = 'Disabled' } } } }
    $sp = Get-AVDTuneEnvPlan -Arm $std -Token $tok -Spec $good -User 'u'
    Test-Check 'existing Standard account: not recommended warning, never created again, no change to kind or SKU' ((Get-Step $sp 'env.account').Action -eq 'None' -and ($sp.Warnings -join ' ') -like '*not recommended*' -and $sp.AccountExists) ($sp.Warnings -join '|')
    $loose = New-AVDTuneFakeEnvArm -Seed @{ Resources = @{ $accKey = @{ name = 'contosoprofiles'; kind = 'FileStorage'; sku = @{ name = 'Premium_LRS' }; location = 'westeurope'; properties = @{ supportsHttpsTrafficOnly = $true; minimumTlsVersion = 'TLS1_0'; allowBlobPublicAccess = $false; publicNetworkAccess = 'Enabled' } } } }
    $lp = Get-AVDTuneEnvPlan -Arm $loose -Token $tok -Spec $good -User 'u'
    $la = Get-Step $lp 'env.account'
    Test-Check 'existing account that deviates: an update of only the deviating values, the old values kept for undo' ($la.Action -eq 'Update' -and $la.Method -eq 'PATCH' -and $la.Body.properties.minimumTlsVersion -eq 'TLS1_2' -and -not $la.Body.properties.Contains('publicNetworkAccess') -and $la.Before.minimumTlsVersion -eq 'TLS1_0' -and -not $la.Body.properties.Contains('supportsHttpsTrafficOnly')) ($la.Changes -join '|')
    $adx = New-AVDTuneFakeEnvArm -Seed @{ Resources = @{ $accKey = @{ name = 'contosoprofiles'; kind = 'FileStorage'; sku = @{ name = 'Premium_LRS' }; location = 'westeurope'; properties = @{ supportsHttpsTrafficOnly = $true; minimumTlsVersion = 'TLS1_2'; allowBlobPublicAccess = $false; publicNetworkAccess = 'Disabled'; azureFilesIdentityBasedAuthentication = @{ directoryServiceOptions = 'AD' } } } } }
    $xp = Get-AVDTuneEnvPlan -Arm $adx -Token $tok -Spec $good -User 'u'
    Test-Check 'account already uses another identity source: blocked (only one source is possible)' ((Get-Step $xp 'env.identity').Action -eq 'Blocked' -and $xp.Blocked.Count -ge 1 -and ($xp.Blocked -join ' ') -like '*only one*') ($xp.Blocked -join '|')
    $nosn = Get-AVDTuneEnvPlan -Arm (New-AVDTuneFakeEnvArm) -Token $tok -Spec (New-Spec @{ SubnetId = "/subscriptions/$sub/resourceGroups/rg-network/providers/Microsoft.Network/virtualNetworks/vnet-avd/subnets/missing" }) -User 'u'
    Test-Check 'a subnet that does not exist blocks the plan' ($nosn.Blocked.Count -eq 1 -and $nosn.Blocked[0] -like '*subnet*') ($nosn.Blocked -join '|')
    Test-Check 'a 403 while reading is a readable error, not a crash' ((Get-Thrown { Get-AVDTuneEnvPlan -Arm (New-AVDTuneFakeEnvArm -Seed @{ ForbidRead = @('account') }) -Token $tok -Spec $good -User 'u' }) -like '*403*Reader*') (Get-Thrown { Get-AVDTuneEnvPlan -Arm (New-AVDTuneFakeEnvArm -Seed @{ ForbidRead = @('account') }) -Token $tok -Spec $good -User 'u' })

    # rights
    $contrib = @(@{ actions = @('*'); notActions = @('Microsoft.Authorization/*/Delete', 'Microsoft.Authorization/*/Write', 'Microsoft.Authorization/elevateAccess/Action') })
    $cp = Get-AVDTuneEnvPlan -Arm (New-AVDTuneFakeEnvArm -Seed @{ Permissions = $contrib }) -Token $tok -Spec $good -User 'u'
    Test-Check 'rights: Contributor cannot write role assignments: named, plan blocked' ($cp.Rights.Missing.Count -eq 1 -and $cp.Rights.Missing[0].Action -eq 'Microsoft.Authorization/roleAssignments/write' -and $cp.Blocked.Count -eq 1) (($cp.Rights.Missing | ForEach-Object Action) -join ',')
    $reader = Get-AVDTuneEnvPlan -Arm (New-AVDTuneFakeEnvArm -Seed @{ Permissions = @(@{ actions = @('*/read'); notActions = @() }) }) -Token $tok -Spec $good -User 'u'
    Test-Check 'rights: a Reader misses every write' ($reader.Rights.Missing.Count -ge 8) $reader.Rights.Missing.Count
    $nop = Get-AVDTuneEnvPlan -Arm (New-AVDTuneFakeEnvArm -Seed @{ ForbidPermissions = $true }) -Token $tok -Spec $good -User 'u'
    Test-Check 'rights: permissions that cannot be read are no refusal, the plan says so' ($nop.Rights.Unknown -and $nop.Blocked.Count -eq 0 -and ($nop.Warnings -join ' ') -like '*not checked in advance*') $null

    # ---------------------------------------------------------------- apply: gate, WhatIf, confirmation (checklist: write gate, LastChange)
    $root = New-Root; $roots += $root
    $arm = New-AVDTuneFakeEnvArm
    $t1 = Get-Thrown { Invoke-Full $arm $good $root }
    Test-Check 'apply without the snapshot gate: refused, not one write' ($t1 -like '*snapshot gate*' -and (Get-Writes $arm).Count -eq 0 -and $null -eq (Get-AVDTuneLastChange -Root $root)) $t1
    Open-AVDTuneWriteGate -SnapshotId 'snap1' -ConfirmedBy 'Test User'
    $wi = Invoke-AVDTuneEnvApply -Arm $arm -Token $tok -Spec $good -Root $root -WhatIf
    Test-Check 'WhatIf: the plan, not one write, LastChange untouched' ($wi.Status -eq 'WhatIf' -and $wi.Plan.Changes -eq 10 -and (Get-Writes $arm).Count -eq 0 -and $null -eq (Get-AVDTuneLastChange -Root $root)) $null
    $nc = Invoke-AVDTuneEnvApply -Arm $arm -Token $tok -Spec $good -Root $root -PollSeconds 0
    Test-Check 'no confirmation: refused, nothing written' ($nc.Status -eq 'Refused' -and (Get-Writes $arm).Count -eq 0) $nc.Message
    $wrong = Invoke-AVDTuneEnvApply -Arm $arm -Token $tok -Spec $good -Root $root -ConfirmedHash 'deadbeef' -PollSeconds 0
    Test-Check 'a hash that is not the plan: refused, nothing written' ($wrong.Status -eq 'Refused' -and (Get-Writes $arm).Count -eq 0) $null
    $seen = Get-AVDTuneEnvPlan -Arm $arm -Token $tok -Spec $good -User 'Test User' -ImageVersion '2026.11.001'
    [void](Invoke-AVDTuneEnvWrite -Arm $arm -Token $tok -Method PUT -Path "$acc`?$v" -Body @{ location = 'westeurope'; kind = 'FileStorage'; sku = @{ name = 'Premium_LRS' }; properties = @{} } -What 'x' -PollSeconds 0 -MaxPolls 10)
    $arm.Store.Writes.Clear()
    $moved = Invoke-AVDTuneEnvApply -Arm $arm -Token $tok -Spec $good -Root $root -Identity EntraKerberos -ConfirmedHash $seen.Hash -User 'Test User' -PollSeconds 0
    Test-Check 'the world changed after the plan was shown: the plan is built again, another hash, nothing written' ($moved.Status -eq 'Refused' -and $moved.Message -like '*differs*' -and (Get-Writes $arm).Count -eq 0) $moved.Message
    $bl = Invoke-AVDTuneEnvApply -Arm (New-AVDTuneFakeEnvArm -Seed @{ Permissions = $contrib }) -Token $tok -Spec $good -Root $root -ConfirmedHash 'x' -PollSeconds 0
    Test-Check 'a blocked plan (missing permission) is refused with the reason' ($bl.Status -eq 'Refused' -and $bl.Message -like '*roleAssignments/write*') $bl.Message

    # ---------------------------------------------------------------- apply: the full run with asynchronous operations
    $root = New-Root; $roots += $root
    $arm = New-AVDTuneFakeEnvArm
    $res = Invoke-Full $arm $good $root
    Test-Check 'full apply: Changed, every step Changed' ($res.Status -eq 'Changed' -and @($res.Results | Where-Object Status -ne 'Changed').Count -eq 0 -and $res.Results.Count -eq 10) (($res.Results | ForEach-Object { "$($_.Id)=$($_.Status) $($_.Message)" }) -join '|')
    $wr = (Get-Writes $arm) -replace "^(\w+) .*/(storageaccounts|privatednszones|privateendpoints)/.*$", '$1 $2'
    Test-Check 'writes in the planned order, each only once' ((Get-Writes $arm).Count -eq 10 -and (Get-Writes $arm)[0] -like 'PUT *storageAccounts/contosoprofiles' -and (Get-Writes $arm)[1] -like '*fileServices/default' -and (Get-Writes $arm)[2] -like '*shares/profiles' -and (Get-Writes $arm)[3] -like '*privateDnsZones/privatelink.file.core.windows.net' -and (Get-Writes $arm)[5] -like '*privateEndpoints/pe-*' -and (Get-Writes $arm)[7] -like 'PATCH *storageAccounts/contosoprofiles') ((Get-Writes $arm) -join "`n")
    $ops = @($arm.Log | Where-Object { $_ -match '/(asyncoperations|operations)/op\d+' })
    Test-Check 'asynchronous operations: Location (account) and Azure-AsyncOperation (zone, link, endpoint, zone group) were polled until they finished' ($ops.Count -ge 5 * 2 -and @($ops | Where-Object { $_ -like '*Storage/locations*' }).Count -ge 3 -and @($ops | Where-Object { $_ -like '*Network/locations*' }).Count -ge 12) "$($ops.Count)"
    $stored = $arm.Store.Resources[$accKey]
    Test-Check 'the fake holds the resources AVDTune asked for, tagged' ($stored.kind -eq 'FileStorage' -and $stored.tags.CreatedWith -eq 'AVDTune' -and $stored.properties.azureFilesIdentityBasedAuthentication.directoryServiceOptions -eq 'AADKERB' -and $arm.Store.Roles.Count -eq 2) $null
    Test-Check 'Azure steps do not set LastChange; a run record and a change log entry per step exist' ($null -eq (Get-AVDTuneLastChange -Root $root) -and @(Get-AVDTuneRun -Root $root | Where-Object Kind -eq 'Environment-Azure').Count -eq 1 -and @(Get-AVDTuneChangeLog -Root $root | Where-Object { $_.Component -like 'Azure:*' -and $_.Category -eq 'Azure' }).Count -eq 10) (@(Get-AVDTuneChangeLog -Root $root).Count)
    $j = Get-AVDTuneEnvJournal -Root $root
    Test-Check 'the journal lists every step as Done, with the path and whether it can carry a tag' (@($j.Runs[0].Steps).Count -eq 10 -and @($j.Runs[0].Steps | Where-Object Status -ne 'Done').Count -eq 0 -and $j.Runs[0].Status -eq 'Done') $null
    $all = Get-AllText $root
    Test-Check 'no token anywhere on disk (journal, change log, run record, state)' ($all -notmatch 'SECRET' -and $all -notmatch 'Bearer') $null
    Test-Check 'the token never appears in the fake log of requests' (($arm.Log | Out-String) -notmatch 'SECRET') $null
    $again = Invoke-Full $arm $good $root
    Test-Check 'idempotent: the same plan again changes nothing and writes nothing' ($again.Status -eq 'Unchanged' -and (Get-Writes $arm).Count -eq 10 -and $again.Plan.Changes -eq 0) $again.Message

    # ---------------------------------------------------------------- the errors: 400, 403, 409, asynchronous failure, busy, timeout, no headers
    $cases = @(
        @{ N = '403 on the endpoint names the role'; Seed = @{ ForbidWrite = @('endpoint') }; At = 'env.endpoint'; Like = '*403*Network Contributor*' }
        @{ N = '403 on the role assignment names the role administrator'; Seed = @{ ForbidWrite = @('role') }; At = 'env.role-users'; Like = '*403*Role Based Access Control Administrator*' }
        @{ N = '409 name taken'; Seed = @{ TakenNames = @('contosoprofiles') }; At = 'env.account'; Like = '*already taken*Choose another name*' }
        @{ N = '409 another operation in progress'; Seed = @{ Busy = @('share') }; At = 'env.share'; Like = '*busy with another operation*' }
        @{ N = '400 invalid request'; Seed = @{ Invalid = @('smb') }; At = 'env.smb'; Like = '*invalid (400)*InvalidRequestContent*' }
        @{ N = 'asynchronous operation ends Failed (Azure-AsyncOperation)'; Seed = @{ FailAsync = @('endpoint') }; At = 'env.endpoint'; Like = '*failed in Azure*InternalServerError*' }
        @{ N = 'asynchronous operation ends Failed (Location)'; Seed = @{ FailAsync = @('account') }; At = 'env.account'; Like = '*400*OperationFailed*' }
        @{ N = 'asynchronous operation that never finishes: time limit, no endless loop'; Seed = @{ NeverFinish = @('dnszone') }; At = 'env.dnszone'; Like = '*did not finish within the time limit*' }
        @{ N = 'no connection'; Seed = @{ Offline = $true }; At = $null; Like = '*No connection*' })
    foreach ($c in $cases) {
        $root = New-Root; $roots += $root
        $arm = New-AVDTuneFakeEnvArm -Seed $c.Seed
        if ($c.At) {
            $r = Invoke-Full $arm $good $root
            $failedStep = @($r.Results | Where-Object Status -eq 'Failed')
            $skipped = @($r.Results | Where-Object Status -eq 'Skipped')
            $ok = $r.Status -eq 'Failed' -and $failedStep.Count -eq 1 -and $failedStep[0].Id -eq $c.At -and $failedStep[0].Message -like $c.Like -and (Test-Path -LiteralPath (Join-Path $root 'config\azure-setup.json')) -and $null -eq (Get-AVDTuneLastChange -Root $root)
            if ($c.At -ne 'env.role-admins') { $ok = $ok -and ($failedStep[0].Id -eq 'env.role-users' -or $skipped.Count -ge 1) }
            Test-Check "error: $($c.N); the rest is skipped, the journal is written, LastChange stays empty" $ok (($r.Results | ForEach-Object { "$($_.Id)=$($_.Status) $($_.Message)" }) -join '|')
            Test-Check "error: $($c.N); the token is not in the messages" (($r | ConvertTo-Json -Depth 8) -notmatch 'SECRET') $null
        }
        else {
            $t = Get-Thrown { Get-AVDTuneEnvPlan -Arm $arm -Token $tok -Spec $good -User 'u' }
            Test-Check "error: $($c.N)" ($t -like $c.Like) $t
        }
    }
    # a failed run can be repeated: what exists is kept, the rest is created
    $root = New-Root; $roots += $root
    $arm = New-AVDTuneFakeEnvArm -Seed @{ ForbidWrite = @('endpoint') }
    $r1 = Invoke-Full $arm $good $root
    $arm.Store.ForbidWrite = @()
    $r2 = Invoke-Full $arm $good $root
    Test-Check 'after a failure and a fix, a second run creates only the rest' ($r1.Status -eq 'Failed' -and $r2.Status -eq 'Changed' -and @($r2.Results | ForEach-Object Id) -notcontains 'env.account' -and @($r2.Results | ForEach-Object Id) -contains 'env.endpoint') (($r2.Results | ForEach-Object Id) -join ',')
    # no headers: the resource itself is polled
    $root = New-Root; $roots += $root
    $arm = New-AVDTuneFakeEnvArm -Seed @{ NoHeaders = $true }
    $r = Invoke-Full $arm $good $root
    Test-Check 'asynchronous answers without headers: the resource is polled instead' ($r.Status -eq 'Changed' -and @($arm.Log | Where-Object { $_ -match '/operations/|/asyncoperations/' }).Count -eq 0) $r.Message
    # role assignment that exists under another name: 409 is benign
    $arm = New-AVDTuneFakeEnvArm -Seed @{ Roles = @(@{ Scope = "$acc/fileServices/default/fileshares/profiles"; Principal = $g1; Role = '0c867c2a-1d8c-454a-a3db-ab2ea1bdc8bb'; Name = 'other-name' }) }
    $rn = Invoke-AVDTuneEnvWrite -Arm $arm -Token $tok -Method PUT -Path "$acc/fileServices/default/fileshares/profiles/providers/Microsoft.Authorization/roleAssignments/$(Get-AVDTuneEnvRoleName "$acc/fileServices/default/fileshares/profiles" $g1 '0c867c2a-1d8c-454a-a3db-ab2ea1bdc8bb')`?api-version=2022-04-01" -Body @{ properties = @{ roleDefinitionId = "/subscriptions/$sub/providers/Microsoft.Authorization/roleDefinitions/0c867c2a-1d8c-454a-a3db-ab2ea1bdc8bb"; principalId = $g1; principalType = 'Group' } } -What 'assign' -PollSeconds 0
    Test-Check 'RoleAssignmentExists (409) is no failure' ($rn.Ok -and $rn.Benign) $rn.Message

    # ---------------------------------------------------------------- polling links on the ARM host only (checklist: tokens only to their own host, no redirects followed blindly)
    $root = New-Root; $roots += $root
    $inner = New-AVDTuneFakeEnvArm
    $seenHosts = New-Object System.Collections.ArrayList
    $evil = [pscustomobject]@{ Kind = 'Evil'; Invoke = {
            param($Method, $Path, $Token, $Body)
            $r = & $inner.Invoke $Method $Path $Token $Body
            if ($r.Headers -and $r.Headers['Azure-AsyncOperation']) { $r.Headers['Azure-AsyncOperation'] = $r.Headers['Azure-AsyncOperation'] -replace 'https://management\.azure\.com', 'https://evil.example'; [void]$seenHosts.Add($r.Headers['Azure-AsyncOperation']) }
            if ($r.Headers -and $r.Headers['Location']) { $r.Headers['Location'] = 'https://evil.example/steal'; [void]$seenHosts.Add($r.Headers['Location']) }
            $r
        }.GetNewClosure() }
    $r = Invoke-Full $evil $good $root
    Test-Check 'a polling link to another host is not followed: the step fails with that reason, the token is not sent there' ($r.Status -eq 'Failed' -and (@($r.Results | Where-Object Status -eq 'Failed')[0].Message -like '*another host*' -or @($r.Results | Where-Object Status -eq 'Failed')[0].Message -like '*not followed*') -and $seenHosts.Count -ge 1 -and @($inner.Log | Where-Object { $_ -like '*evil*' }).Count -eq 0) ((@($r.Results | Where-Object Status -eq 'Failed') | ForEach-Object Message) -join '|')
    Test-Check 'polling links: a path outside a subscription is refused' ((Test-Throws { Wait-AVDTuneEnvOperation -Arm $inner -Token $tok -First ([pscustomobject]@{ Headers = @{ 'Azure-AsyncOperation' = 'https://management.azure.com/tenants/x/y?api-version=2020-01-01' } }) -ResourcePath $acc -PollSeconds 0 -MaxPolls 2 }) -or -not (Wait-AVDTuneEnvOperation -Arm $inner -Token $tok -First ([pscustomobject]@{ Headers = @{ 'Azure-AsyncOperation' = 'https://management.azure.com/subscriptions/x/..?api-version=1' } }) -ResourcePath $acc -PollSeconds 0 -MaxPolls 2).Ok) $null
    $real = New-AVDTuneArmAdapter
    $refused = & $real.Invoke 'PUT' "/subscriptions/$sub/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/x?api-version=2024-01-01#x" 't' @{}
    Test-Check 'the real ARM adapter refuses a path with a hash without a request' ($refused.Status -eq 0 -and $refused.Error -like 'Refused*') $null
    $src = [IO.File]::ReadAllText((Join-Path $repo 'Modules\AVDTune.Snapshot.psm1'))
    Test-Check 'the real adapter does not follow redirects and only talks to management.azure.com' ($src -match 'AllowAutoRedirect = \$false' -and $src -match 'https://management\.azure\.com\$Path') $null
    $envSrc = [IO.File]::ReadAllText((Join-Path $repo 'Modules\AVDTune.Environment.psm1'))
    Test-Check 'the module has no HTTP client of its own, no key call, no use of a token outside the adapter call' ($envSrc -notmatch 'HttpWebRequest|Invoke-WebRequest|Invoke-RestMethod|WebClient|listKeys|regenerateKey') $null

    # ---------------------------------------------------------------- undo: only what AVDTune created, nothing with data
    $root = New-Root; $roots += $root
    $arm = New-AVDTuneFakeEnvArm
    $res = Invoke-Full $arm $good $root
    $files = New-AVDTuneFakeFiles -Seed @{ Acls = @{ '' = 'x' }; Folders = @() }
    Close-AVDTuneWriteGate
    $tu = Get-Thrown { Invoke-AVDTuneEnvUndo -Arm $arm -Token $tok -Root $root -ConfirmedHash 'x' -PollSeconds 0 }
    Test-Check 'undo without the snapshot gate: refused' ($tu -like '*snapshot gate*') $tu
    Open-AVDTuneWriteGate -SnapshotId 'snap2' -ConfirmedBy 'Test User'
    $up = Get-AVDTuneEnvUndoPlan -Arm $arm -Token $tok -Root $root
    $byId = @{}; foreach ($s in $up.Steps) { $byId[$s.Id] = $s }
    Test-Check 'undo plan without a storage token: share and account are kept (cannot prove the share is empty), the rest is deleted in reverse order' ($byId['env.share'].Action -eq 'Keep' -and $byId['env.account'].Action -eq 'Keep' -and $byId['env.endpoint'].Action -eq 'Delete' -and $byId['env.role-users'].Action -eq 'Delete' -and $byId['env.dnszone'].Action -eq 'Delete' -and $byId['env.dnsgroup'].Action -eq 'Delete' -and $byId['env.role-admins'].Order -lt $byId['env.endpoint'].Order -and $byId['env.endpoint'].Order -lt $byId['env.dnszone'].Order) (($up.Steps | ForEach-Object { "$($_.Id)=$($_.Action)" }) -join ',')
    Test-Check 'undo plan: the reason for a kept resource is shown' ($byId['env.share'].Reason -like '*cannot verify*empty*') $null
    Test-Check 'undo plan: identity and SMB settings are restored (the account stays)' ($byId['env.identity'].Action -eq 'Restore' -and $byId['env.identity'].Body.properties.azureFilesIdentityBasedAuthentication.directoryServiceOptions -eq 'None') (($up.Steps | ForEach-Object { "$($_.Id)=$($_.Action)" }) -join ',')
    $arm.Store.Writes.Clear()
    $nc = Invoke-AVDTuneEnvUndo -Arm $arm -Token $tok -Root $root -ConfirmedHash 'bad' -PollSeconds 0
    Test-Check 'undo: another hash is refused, nothing changed' ($nc.Status -eq 'Refused' -and (Get-Writes $arm).Count -eq 0) $null
    $ur = Invoke-AVDTuneEnvUndo -Arm $arm -Token $tok -Root $root -ConfirmedHash $up.Hash -User 'Test User' -SnapshotId 'snap2' -PollSeconds 0 -MaxPolls 20
    Test-Check 'undo: reverted, the endpoint (asynchronous delete), the roles, the DNS group, link and zone are gone, the account and the share stay' ($ur.Status -eq 'Reverted' -and -not $arm.Store.Resources.ContainsKey($accKey.Replace('storageaccounts/contosoprofiles', 'storageaccounts/contosoprofiles') + '/x') -and $arm.Store.Roles.Count -eq 0 -and $arm.Store.Resources.ContainsKey($accKey) -and @($arm.Store.Resources.Keys | Where-Object { $_ -like '*privateendpoints*' -or $_ -like '*privatednszones*' }).Count -eq 0) (($ur.Results | ForEach-Object { "$($_.Id)=$($_.Status) $($_.Message)" }) -join '|')
    Test-Check 'undo: the identity is back to None, a change log entry per step, journal entries marked, a second undo has nothing left to do (except the kept ones)' ($arm.Store.Resources[$accKey].properties.azureFilesIdentityBasedAuthentication.directoryServiceOptions -eq 'None' -and @(Get-AVDTuneChangeLog -Root $root | Where-Object { $_.Text -like 'Undo:*' }).Count -ge 7 -and @((Get-AVDTuneEnvUndoPlan -Arm $arm -Token $tok -Root $root).Steps | Where-Object { $_.Action -in 'Delete', 'Restore' }).Count -eq 0) $null
    # with a storage token and an empty share the account goes
    $root = New-Root; $roots += $root
    $arm = New-AVDTuneFakeEnvArm
    $res = Invoke-Full $arm $good $root
    $up = Get-AVDTuneEnvUndoPlan -Arm $arm -Token $tok -Root $root -Files $files -StorageToken 'tok-st-SECRET'
    $byId = @{}; foreach ($s in $up.Steps) { $byId[$s.Id] = $s }
    Test-Check 'undo plan with an empty share: share and account are deleted, SMB and identity settings are covered by the account' ($byId['env.share'].Action -eq 'Delete' -and $byId['env.account'].Action -eq 'Delete' -and $byId['env.smb'].Action -eq 'Covered' -and $byId['env.identity'].Action -eq 'Covered') (($up.Steps | ForEach-Object { "$($_.Id)=$($_.Action)" }) -join ',')
    $ur = Invoke-AVDTuneEnvUndo -Arm $arm -Token $tok -Root $root -ConfirmedHash $up.Hash -Files $files -StorageToken 'tok-st-SECRET' -PollSeconds 0 -MaxPolls 20
    Test-Check 'undo with an empty share: everything AVDTune created is gone' ($ur.Status -eq 'Reverted' -and -not $arm.Store.Resources.ContainsKey($accKey) -and (Get-AllText $root) -notmatch 'SECRET') (($ur.Results | ForEach-Object { "$($_.Id)=$($_.Status) $($_.Message)" }) -join '|')
    # a share with profile data is never deleted
    $root = New-Root; $roots += $root
    $arm = New-AVDTuneFakeEnvArm
    $res = Invoke-Full $arm $good $root
    $full = New-AVDTuneFakeFiles -Seed @{ Acls = @{ '' = 'x' }; Folders = @('S-1-12-1-1-2-3-4_alice') }
    $up = Get-AVDTuneEnvUndoPlan -Arm $arm -Token $tok -Root $root -Files $full -StorageToken 'tok-st-SECRET'
    $byId = @{}; foreach ($s in $up.Steps) { $byId[$s.Id] = $s }
    Test-Check 'a share that holds profile folders is kept, with the account' ($byId['env.share'].Action -eq 'Keep' -and $byId['env.share'].Reason -like '*holds data*' -and $byId['env.account'].Action -eq 'Keep') $null
    # a resource that lost its tag is not AVDTune's
    $arm.Store.Resources["/subscriptions/$sub/resourcegroups/rg-network/providers/microsoft.network/privateendpoints".ToLowerInvariant() + '/x'] = @{}
    $peKey = "/subscriptions/$sub/resourcegroups/rg-example/providers/microsoft.network/privateendpoints/pe-contosoprofiles"
    $arm.Store.Resources[$peKey].tags = [pscustomobject]@{ Owner = 'someone' }
    $up = Get-AVDTuneEnvUndoPlan -Arm $arm -Token $tok -Root $root -Files $full -StorageToken 'x'
    Test-Check 'a resource without the tag CreatedWith=AVDTune is not deleted (it may have been replaced)' (@($up.Steps | Where-Object Id -eq 'env.endpoint')[0].Action -eq 'Keep' -and @($up.Steps | Where-Object Id -eq 'env.endpoint')[0].Reason -like '*tag*') $null
    # a shared DNS zone with other records stays
    $root = New-Root; $roots += $root
    $arm = New-AVDTuneFakeEnvArm -Seed @{ ExtraRecords = 3 }
    $res = Invoke-Full $arm $good $root
    $up = Get-AVDTuneEnvUndoPlan -Arm $arm -Token $tok -Root $root
    Test-Check 'a private DNS zone that other accounts use (more records) is kept' (@($up.Steps | Where-Object Id -eq 'env.dnszone')[0].Action -eq 'Keep' -and @($up.Steps | Where-Object Id -eq 'env.dnszone')[0].Reason -like '*record sets*') (($up.Steps | ForEach-Object { "$($_.Id)=$($_.Action)" }) -join ',')
    # what AVDTune did not create is not touched: the account existed, only the share was new
    $root = New-Root; $roots += $root
    $pre = @{ $accKey = @{ name = 'contosoprofiles'; kind = 'FileStorage'; sku = @{ name = 'Premium_LRS' }; location = 'westeurope'; tags = @{ Owner = 'team' }; properties = @{ supportsHttpsTrafficOnly = $true; minimumTlsVersion = 'TLS1_2'; allowBlobPublicAccess = $false; publicNetworkAccess = 'Disabled' } } }
    $arm = New-AVDTuneFakeEnvArm -Seed @{ Resources = $pre }
    $res = Invoke-Full $arm $good $root
    $up = Get-AVDTuneEnvUndoPlan -Arm $arm -Token $tok -Root $root -Files $files -StorageToken 'x'
    Test-Check 'an account that existed before is never in the undo plan as a delete' (@($up.Steps | Where-Object { $_.Type -eq 'account' -and $_.Action -eq 'Delete' }).Count -eq 0) (($up.Steps | ForEach-Object { "$($_.Id)=$($_.Action)" }) -join ',')
    # aligned settings of an existing account are restored
    $root = New-Root; $roots += $root
    $arm = New-AVDTuneFakeEnvArm -Seed @{ Resources = @{ $accKey = @{ name = 'contosoprofiles'; kind = 'FileStorage'; sku = @{ name = 'Premium_LRS' }; location = 'westeurope'; properties = @{ supportsHttpsTrafficOnly = $true; minimumTlsVersion = 'TLS1_0'; allowBlobPublicAccess = $false; publicNetworkAccess = 'Enabled' } } } }
    $res = Invoke-Full $arm $good $root
    $tlsNow = $arm.Store.Resources[$accKey].properties.minimumTlsVersion
    $up = Get-AVDTuneEnvUndoPlan -Arm $arm -Token $tok -Root $root
    $ur = Invoke-AVDTuneEnvUndo -Arm $arm -Token $tok -Root $root -ConfirmedHash $up.Hash -PollSeconds 0 -MaxPolls 20
    $acKeep = @($up.Steps | Where-Object { $_.Type -eq 'account' })[0]
    Test-Check 'an aligned existing account: TLS 1.2 was set; undo shows the lower recorded TLS 1.0 as kept (reason) and does not write it, public access was never touched' ($tlsNow -eq 'TLS1_2' -and $acKeep.Action -eq 'Keep' -and $acKeep.Reason -like '*lower the security*minimumTlsVersion=TLS1_0*' -and $arm.Store.Resources[$accKey].properties.minimumTlsVersion -eq 'TLS1_2' -and $arm.Store.Resources[$accKey].properties.publicNetworkAccess -eq 'Enabled') (($up.Steps | ForEach-Object { "$($_.Id)=$($_.Action) $($_.Reason)" }) -join '|')
    # N2: a journal that carries publicNetworkAccess, https off or blob access on is not restored either (journal is input)
    $root = New-Root; $roots += $root
    $arm = New-AVDTuneFakeEnvArm -Seed @{ Resources = @{ $accKey = @{ name = 'contosoprofiles'; kind = 'FileStorage'; sku = @{ name = 'Premium_LRS' }; location = 'westeurope'; properties = @{ supportsHttpsTrafficOnly = $true; minimumTlsVersion = 'TLS1_2'; allowBlobPublicAccess = $false; publicNetworkAccess = 'Disabled' } } } }
    [void](Invoke-Full $arm $good $root)
    $jp = Join-Path $root 'config\azure-setup.json'; $jj = [IO.File]::ReadAllText($jp) | ConvertFrom-Json
    $jj.Runs[0].Steps = @($jj.Runs[0].Steps) + [pscustomobject]@{ Id = 'env.account'; Type = 'account'; Path = $acc; Action = 'Update'; Taggable = $true; Before = [pscustomobject]@{ publicNetworkAccess = 'Enabled'; supportsHttpsTrafficOnly = $false; allowBlobPublicAccess = $true; minimumTlsVersion = 'TLS1_1' }; Status = 'Done'; Message = ''; Undone = $false; At = (Get-Date).AddMinutes(5).ToString('o') }
    [IO.File]::WriteAllText($jp, ($jj | ConvertTo-Json -Depth 10))
    $up = Get-AVDTuneEnvUndoPlan -Arm $arm -Token $tok -Root $root
    $pa = @($up.Steps | Where-Object { $_.Type -eq 'account' })
    Test-Check 'undo plan: a recorded publicNetworkAccess is no longer read; https off, blob access on and TLS 1.1 are shown as kept, nothing for the account is written' ($pa.Count -eq 1 -and $pa[0].Action -eq 'Keep' -and $pa[0].Reason -like '*supportsHttpsTrafficOnly=False*' -and $pa[0].Reason -like '*allowBlobPublicAccess=True*' -and $pa[0].Reason -like '*minimumTlsVersion=TLS1_1*' -and $pa[0].Reason -notlike '*publicNetworkAccess*' -and -not $pa[0].Body) (($up.Steps | ForEach-Object { "$($_.Id)=$($_.Action) $($_.Reason)" }) -join '|')
    Test-Check 'the before allowlist has no publicNetworkAccess' ((Get-Content -LiteralPath (Join-Path $repo 'Modules\AVDTune.Environment.psm1') -Raw) -notmatch "'publicNetworkAccess'\] = \$v") $null
    # the journal is data: a planted path that is not on the allowlist is never sent
    $root = New-Root; $roots += $root
    $arm = New-AVDTuneFakeEnvArm
    $jp = Join-Path $root 'config\azure-setup.json'
    New-Item -ItemType Directory -Path (Split-Path $jp) -Force | Out-Null
    $evilJournal = @{ Schema = 1; Runs = @(@{ RunId = 'x'; Steps = @(@{ Id = 'env.account'; Type = 'account'; Path = "/subscriptions/$sub/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/golden"; Action = 'Create'; Taggable = $true; Before = $null; Status = 'Done'; Undone = $false; At = (Get-Date).ToString('o') }) }) }
    [IO.File]::WriteAllText($jp, ($evilJournal | ConvertTo-Json -Depth 8))
    $up = Get-AVDTuneEnvUndoPlan -Arm $arm -Token $tok -Root $root
    Test-Check 'a journal entry that points at another resource type produces no step and no request' ($up.Steps.Count -eq 0 -and $arm.Log.Count -eq 0) $null

    # #45: a run that stopped between the two journal writes of a step (Started) is found, shown on the Overview and closed from the real state (GET only)
    $root = New-Root; $roots += $root
    $arm = New-AVDTuneFakeEnvArm
    [void](Invoke-Full $arm $good $root)
    Test-Check 'interrupted (#45): a finished run is not reported' (@(Get-AVDTuneEnvInterrupted -Root $root).Count -eq 0 -and $null -eq (Get-AVDTuneEnvHealthRow -Root $root)) $null
    $jp = Join-Path $root 'config\azure-setup.json'; $jj = [IO.File]::ReadAllText($jp) | ConvertFrom-Json
    $creates = @($jj.Runs[0].Steps | Where-Object { $_.Action -eq 'Create' -and $_.Type -notin 'smb', 'identity' -and $_.Status -eq 'Done' })
    $made = @($creates | Where-Object { $_.Type -eq 'endpoint' })[0]; $rest = @($creates | Where-Object { $_.Type -notin 'endpoint', 'account' }); $never = $rest[0]
    $made.Status = 'Started'; $made.PSObject.Properties.Remove('Identity')
    $never.Status = 'Started'; [void]$arm.Store.Resources.Remove(([string]$never.Path).ToLowerInvariant())
    $old = @($rest | Select-Object -Skip 1 | Select-Object -First 1)
    if ($old.Count -gt 0) { $old[0].Status = 'Started'; $old[0].At = (Get-Date).AddDays(1).ToString('o') }   # the resource is older than the step: someone else's
    $jj.Runs[0].Ended = $null
    [IO.File]::WriteAllText($jp, ($jj | ConvertTo-Json -Depth 10))
    $int = @(Get-AVDTuneEnvInterrupted -Root $root); $row = Get-AVDTuneEnvHealthRow -Root $root
    [AppDomain]::CurrentDomain.SetData('AVDTune.EnvApplyRun', [string]$jj.Runs[0].RunId); $whileRunning = @(Get-AVDTuneEnvInterrupted -Root $root).Count; [AppDomain]::CurrentDomain.SetData('AVDTune.EnvApplyRun', $null)
    Test-Check 'interrupted (#45): a run with Started steps and no end is found (not while this process carries it out) and the Overview shows a warning with the resources' ($int.Count -eq 1 -and $int[0].Steps.Count -eq (2 + $old.Count) -and $whileRunning -eq 0 -and $row.Status -eq 'warn' -and $row.Detail -like "*$(([string]$made.Path -split '/')[-1])*") "int=$($int.Count) steps=$($int[0].Steps.Count) running=$whileRunning"
    $writesBefore = @(Get-Writes $arm).Count
    $res = @(Resolve-AVDTuneEnvInterrupted -Arm $arm -Token $tok -Root $root -User 'admin1')
    $j2 = [IO.File]::ReadAllText($jp) | ConvertFrom-Json
    $e2 = @{}; foreach ($e in $j2.Runs[0].Steps) { $e2[[string]$e.Id] = $e }
    Test-Check 'interrupted (#45): a create that Azure made is Done with its identity, one that is missing is Failed (nothing made), only GETs were sent' ($e2[[string]$made.Id].Status -eq 'Done' -and $e2[[string]$made.Id].Identity -and $e2[[string]$never.Id].Status -eq 'Failed' -and $e2[[string]$never.Id].Message -like '*nothing was created*' -and @(Get-Writes $arm).Count -eq $writesBefore) (($res | ForEach-Object { "$($_.Id)=$($_.Status)" }) -join ', ')
    Test-Check 'interrupted (#45): a resource older than the step is not taken as AVDTune''s (Foreign, Failed); the run is closed (end, Interrupted), a change log note, nothing left to report' (($old.Count -eq 0 -or ($e2[[string]$old[0].Id].Status -eq 'Failed' -and $e2[[string]$old[0].Id].Identity.Foreign)) -and $j2.Runs[0].Ended -and $j2.Runs[0].Status -eq 'Interrupted' -and @(Get-AVDTuneChangeLog -Root $root | Where-Object { $_.Component -eq 'Azure: interrupted run' }).Count -eq 1 -and @(Get-AVDTuneEnvInterrupted -Root $root).Count -eq 0) $null
    $upI = Get-AVDTuneEnvUndoPlan -Arm $arm -Token $tok -Root $root
    Test-Check 'interrupted (#45): the undo plan can take the found resource back' (@($upI.Steps | Where-Object { $_.Id -eq $made.Id -and $_.Action -eq 'Delete' }).Count -eq 1) (($upI.Steps | ForEach-Object { "$($_.Id)=$($_.Action)" }) -join ', ')
    $envPage = [IO.File]::ReadAllText((Join-Path $repo 'AVDTune-Environment.ps1'))
    $envWorker = [regex]::Match($envPage, "(?s)\`$script:EnvWorkerText = @'\r?\n(.*?)\r?\n'@").Groups[1].Value
    Test-Check 'interrupted (#45): the plan and the undo plan of the page close an interrupted run first (in the worker, #44)' ($envWorker -match "if \(\`$Kind -in 'Plan', 'UndoPlan' -and @\(Get-AVDTuneEnvInterrupted -Root \`$Root\)\.Count -gt 0\) \{ \`$Sync\.Text = 'interrupted'; \`$closed = @\(Resolve-AVDTuneEnvInterrupted -Arm \`$arm" -and $envPage -match "T 'env\.interrupted\.closed'") $null

    # ---------------------------------------------------------------- #44: plan, create, undo plan and undo of the page run in a background runspace
    $outside = $envPage.Replace($envWorker, '')
    $onUi = @([regex]::Matches($outside, '(Get-AVDTuneEnvPlan|Invoke-AVDTuneEnvApply|Get-AVDTuneEnvUndoPlan|Invoke-AVDTuneEnvUndo|Resolve-AVDTuneEnvInterrupted|New-AVDTuneArmAdapter) ') | ForEach-Object { $_.Groups[1].Value })
    $startEnv = [regex]::Match($envPage, '(?s)function Start-EnvJob.*?\r?\n\}').Value
    $tasksText = [IO.File]::ReadAllText((Join-Path $repo 'AVDTune-Tasks.ps1'))
    Test-Check 'runspace (#44): no Azure call of the page runs on the window thread; Start-EnvJob uses New-AVDTunePowerShell, a task, the shutdown block, the write gate and Assert-NoOtherWriter for Apply and Undo; EnvJob is a writer (Plan, UndoPlan read only)' ($envWorker -and $onUi.Count -eq 0 -and $startEnv -match 'New-AVDTunePowerShell' -and $startEnv -match 'Start-AVDTuneUiTask' -and $startEnv -match 'Set-ShutdownBlock \$true' -and $startEnv -match 'Assert-NoOtherWriter' -and $startEnv -match 'Test-AVDTuneWriteAllowed' -and $startEnv -match 'Get-AVDTuneWriteGate' -and $tasksText -match "(?m)^\`$script:WriterJobVariables = @\([^\r\n]*'EnvJob'" -and $tasksText -match "EnvJob = @\('Plan', 'UndoPlan'\)" -and $envPage -match '\$job\.A\.Token = \$null') ($onUi -join ', ')
    # the worker text in a fresh runspace with exactly its own imports (no "is not recognized"), against one fake ARM, all four kinds after each other
    $rsRoot = New-Root; $roots += $rsRoot
    $rsArm = New-AVDTuneFakeEnvArm -Seed @{ Polls = 0 }
    $gateNow = Get-AVDTuneWriteGate
    $runWorker = {
        param([string]$Kind, [hashtable]$A, $Gate)
        $ps = New-AVDTunePowerShell
        try {
            $sync = [hashtable]::Synchronized(@{ Text = '' })
            [void]$ps.AddScript($envWorker).AddArgument($repo).AddArgument($rsRoot).AddArgument($Kind).AddArgument($A).AddArgument($Gate).AddArgument($sync).AddArgument($rsArm).AddArgument(([IO.Path]::Combine($PSScriptRoot, 'Fakes', 'FakeEnvArm.ps1')))
            $o = $null; $thrown = ''
            try { $o = @($ps.Invoke()) | Select-Object -Last 1 } catch { $thrown = $_.Exception.Message }
            [pscustomobject]@{ Out = $o; Err = ((@($ps.Streams.Error | ForEach-Object { $_.Exception.Message }) + $thrown) -join ' ').Trim(); Step = [string]$sync.Text }
        }
        finally { $ps.Dispose() }
    }
    $wPlan = & $runWorker 'Plan' @{ Token = $tok; Spec = $good; Identity = 'EntraKerberos'; Identities = 'CloudOnly'; User = 'Test User'; ImageVersion = '2026.11.001' } $null
    $wApply = $null; $wUndoPlan = $null; $wUndo = $null
    if ($wPlan.Out.Result.Hash) {
        $wApply = & $runWorker 'Apply' @{ Token = $tok; Spec = $good; Identity = 'EntraKerberos'; Identities = 'CloudOnly'; Hash = $wPlan.Out.Result.Hash; User = 'Test User'; SnapshotId = 'snap1' } $gateNow
        $wUndoPlan = & $runWorker 'UndoPlan' @{ Token = $tok; User = 'Test User' } $null
        if ($wUndoPlan.Out.Result.Hash) { $wUndo = & $runWorker 'Undo' @{ Token = $tok; Hash = $wUndoPlan.Out.Result.Hash; User = 'Test User'; SnapshotId = 'snap1' } $gateNow }
    }
    Test-Check 'runspace (#44): the worker runs Plan, Apply, UndoPlan and Undo in a fresh runspace with its own imports and the write gate handed over: no error, the plan has 10 changes, apply Changed, undo takes back' (-not $wPlan.Err -and $wPlan.Out.Result.Changes -eq 10 -and $wApply -and -not $wApply.Err -and $wApply.Out.Result.Status -eq 'Changed' -and $wUndoPlan -and -not $wUndoPlan.Err -and $wUndoPlan.Out.Result.Count -gt 0 -and $wUndo -and -not $wUndo.Err -and $wUndo.Out.Result.Status -notin 'Failed', 'Refused' -and $wPlan.Step -eq 'azure') "plan=$($wPlan.Err)$($wPlan.Out.Result.Changes) apply=$($wApply.Err)$($wApply.Out.Result.Status) undoplan=$($wUndoPlan.Err)$($wUndoPlan.Out.Result.Count) undo=$($wUndo.Err)$($wUndo.Out.Result.Status) $($wUndo.Out.Result.Message)"
    $wNoGate = & $runWorker 'Apply' @{ Token = $tok; Spec = $good; Identity = 'EntraKerberos'; Identities = 'CloudOnly'; Hash = 'x'; User = 'Test User'; SnapshotId = 'snap1' } $null
    Test-Check 'runspace (#44): without the gate handed over the worker''s apply is refused (the runspace has its own module state, counter-test)' (($wNoGate.Err -like '*gate*') -or ($wNoGate.Out.Result.Status -in 'Refused', 'Failed')) "$($wNoGate.Err) $($wNoGate.Out.Result.Status)"
    # #44 review: a start that fails after the runspace was made disposes it and drops the token; an end that fails releases token, runspace, shutdown block and buttons
    & {   # a child scope: the stubs below do not leak into the rest of the check
        $envAst = [Management.Automation.Language.Parser]::ParseInput($envPage, [ref]$null, [ref]$null)
        foreach ($fnName in 'Start-EnvJob', 'Complete-EnvJob') { Invoke-Expression ($envAst.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $fnName }, $true).Extent.Text) }
        $script:EnvReadKinds = @('Plan', 'UndoPlan'); $script:EnvJob = $null; $script:EnvWorkerText = '1'; $script:EnvJobText = @{ Apply = @('t', 's') }; $script:TestMode = $false
        $script:Calls = New-Object System.Collections.ArrayList
        function Test-AVDTuneWriteAllowed { $true }
        function Assert-NoOtherWriter { }
        function New-AVDTunePowerShell { $script:RevPs = [powershell]::Create(); $script:RevPs }
        function Start-AVDTuneUiTask { throw 'task list broken' }
        function Complete-AVDTuneUiTask { [void]$script:Calls.Add('task-failed') }
        function Set-ShutdownBlock([bool]$On) { [void]$script:Calls.Add("shutdown-$On") }
        function Set-EnvBusy([bool]$Busy) { [void]$script:Calls.Add("busy-$Busy") }
        function Start-OverviewRefresh { }
        $revA = @{ Token = 'tok-review' }
        $revThrown = Get-Thrown { Start-EnvJob 'Apply' $revA }
        $revDisposed = Test-Throws { [void]$script:RevPs.AddScript('1') }
        Test-Check 'review (#44): Start-EnvJob that fails at the task disposes the runspace, drops the token, sets no job and no shutdown block (counter-test)' ($revThrown -eq 'task list broken' -and $revDisposed -and $null -eq $revA.Token -and -not $script:EnvJob -and $script:Calls -notcontains 'shutdown-True') "thrown=$revThrown disposed=$revDisposed calls=$($script:Calls -join ',')"
        $script:Calls.Clear(); $script:RevDispose = 0
        $fakePs = [pscustomobject]@{}
        $fakePs | Add-Member ScriptMethod EndInvoke { param($h) throw 'runspace broken' }
        $fakePs | Add-Member ScriptMethod Dispose { $script:RevDispose++; throw 'dispose broken' }   # counter-test: a failing dispose must not keep token, block or buttons
        $ui = @{ TxtEnvResult = [pscustomobject]@{ Text = '' } }
        $revJobA = @{ Token = 'tok-review2' }
        $script:EnvJob = @{ PS = $fakePs; Handle = [pscustomobject]@{ IsCompleted = $true }; Kind = 'Apply'; Sync = @{ Text = '' }; Task = @{}; A = $revJobA }
        $revEndErr = Get-Thrown { Complete-EnvJob }
        Test-Check 'review (#44): Complete-EnvJob after a failing end releases token, runspace, shutdown block and buttons and reports the error' (-not $revEndErr -and $null -eq $revJobA.Token -and $script:RevDispose -eq 1 -and $script:Calls -contains 'shutdown-False' -and $script:Calls -contains 'busy-False' -and $script:Calls -contains 'task-failed' -and $ui.TxtEnvResult.Text -like '*runspace broken*' -and -not $script:EnvJob) "err=$revEndErr dispose=$($script:RevDispose) calls=$($script:Calls -join ',') text=$($ui.TxtEnvResult.Text)"
    }
    # #45 review: the run is closed under the state lock and not while another AVDTune process changes the master or a wizard run of this process is carried out
    $root = New-Root; $roots += $root
    $arm = New-AVDTuneFakeEnvArm
    [void](Invoke-Full $arm $good $root)
    $jp = Join-Path $root 'config\azure-setup.json'; $jj = [IO.File]::ReadAllText($jp) | ConvertFrom-Json
    @($jj.Runs[0].Steps | Where-Object { $_.Type -eq 'endpoint' })[0].Status = 'Started'; [IO.File]::WriteAllText($jp, ($jj | ConvertTo-Json -Depth 10))
    [AppDomain]::CurrentDomain.SetData('AVDTune.EnvApplyRun', 'other-run')
    $eRun = Get-Thrown { Resolve-AVDTuneEnvInterrupted -Arm $arm -Token $tok -Root $root }
    [AppDomain]::CurrentDomain.SetData('AVDTune.EnvApplyRun', $null)
    $other = Get-Process | Where-Object { $_.Id -ne $PID -and $(try { $_.StartTime } catch { $null }) } | Select-Object -First 1   # a live process that is not this one: its marker counts as another AVDTune process
    [void](Set-AVDTuneState -Root $root -Values @{ ChangeInProgress = [ordered]@{ Started = (Get-Date).ToUniversalTime().ToString('o'); Pid = $other.Id; ProcessStart = $other.StartTime.ToUniversalTime().ToString('o'); ProcessName = $other.ProcessName } })
    $eForeign = Get-Thrown { Resolve-AVDTuneEnvInterrupted -Arm $arm -Token $tok -Root $root }
    [void](Set-AVDTuneState -Root $root -Values @{ ChangeInProgress = $null })
    $stillOpen = @(Get-AVDTuneEnvInterrupted -Root $root).Count
    $closed = @(Resolve-AVDTuneEnvInterrupted -Arm $arm -Token $tok -Root $root).Count
    Test-Check 'interrupted (#45 review): refused while a wizard run is carried out or another AVDTune process holds a live marker (journal unchanged), closed once both are gone' ($eRun -like '*carried out right now*' -and $eForeign -like '*Another AVDTune process*' -and $stillOpen -eq 1 -and $closed -eq 1 -and @(Get-AVDTuneEnvInterrupted -Root $root).Count -eq 0) "run=$eRun foreign=$eForeign"
    # #50 review: apply and undo of the wizard refuse a finished version before any request
    $root = New-Root; $roots += $root
    $arm = New-AVDTuneFakeEnvArm
    [void](Set-AVDTuneState -Root $root -Values @{ Sealed = $true })
    $eApply = Get-Thrown { Invoke-Full $arm $good $root }
    $eUndo = Get-Thrown { Invoke-AVDTuneEnvUndo -Arm $arm -Token $tok -ConfirmedHash 'x' -Root $root }
    Test-Check 'sealed (#50 review): the environment apply and undo refuse a finished version, nothing is written' ($eApply -like '*is finished*' -and $eUndo -like '*is finished*' -and @(Get-Writes $arm).Count -eq 0) "apply=$eApply undo=$eUndo"

    # ---------------------------------------------------------------- review findings of #32 (Finn): share empty, per share and account, journal as input, existing accounts, create semantics
    Close-AVDTuneWriteGate; Open-AVDTuneWriteGate -SnapshotId 'snapB' -ConfirmedBy 'Test User'
    $peKey2 = "/subscriptions/$sub/resourcegroups/rg-example/providers/microsoft.network/privateendpoints/pe-contosoprofiles"
    $shareArgs = @{ Account = 'contosoprofiles'; Share = 'profiles'; Token = 'tok-st-SECRET' }
    # 1: Test-AVDTuneEnvShareEmpty: true only for a clear 2xx answer without entries and without marker
    $fe = New-AVDTuneFakeFiles -Seed @{ Acls = @{ '' = 'x' } }
    Test-Check 'share empty: a clear empty answer is $true' ((Test-AVDTuneEnvShareEmpty -Files $fe @shareArgs) -eq $true) $null
    foreach ($c in @(
            @{ N = 'a directory in it'; S = @{ Folders = @('alice') }; Not = $true }, @{ N = 'only files in it (no directory)'; S = @{ FileEntries = @('a.vhdx') }; Not = $true },
            @{ N = '403 (role not active yet)'; S = @{ Forbidden = $true } }, @{ N = 'no connection'; S = @{ Offline = $true } },
            @{ N = 'a NextMarker (more to list)'; S = @{ NextMarker = 'abc' } }, @{ N = 'XML that does not parse'; S = @{ BadXml = $true } })) {
        $seed = @{ Acls = @{ '' = 'x' } }; foreach ($k in $c.S.Keys) { $seed[$k] = $c.S[$k] }
        $v = Test-AVDTuneEnvShareEmpty -Files (New-AVDTuneFakeFiles -Seed $seed) @shareArgs
        Test-Check "share empty is not `$true: $($c.N)" ($v -ne $true) "$v"
        if (-not $c.Not) { Test-Check "share empty is `$null (cannot prove it): $($c.N)" ($null -eq $v) "$v" }
    }
    Test-Check 'share empty: a bad account or share name is refused, not asked' ($null -eq (Test-AVDTuneEnvShareEmpty -Files $fe -Account 'A/../b' -Share 'profiles' -Token 't')) $null
    # undo plan: files only, 403, marker keep the share and the account
    foreach ($c in @(@{ N = 'only files'; S = @{ FileEntries = @('a.vhdx') } }, @{ N = '403'; S = @{ Forbidden = $true } }, @{ N = 'NextMarker'; S = @{ NextMarker = 'm' } }, @{ N = 'offline'; S = @{ Offline = $true } })) {
        $root = New-Root; $roots += $root; $arm = New-AVDTuneFakeEnvArm; [void](Invoke-Full $arm $good $root)
        $seed = @{ Acls = @{ '' = 'x' } }; foreach ($k in $c.S.Keys) { $seed[$k] = $c.S[$k] }
        $up = Get-AVDTuneEnvUndoPlan -Arm $arm -Token $tok -Root $root -Files (New-AVDTuneFakeFiles -Seed $seed) -StorageToken 'tok-st-SECRET'
        $b = @{}; foreach ($s in $up.Steps) { $b[$s.Id] = $s }
        Test-Check "undo plan keeps share and account: $($c.N)" ($b['env.share'].Action -eq 'Keep' -and $b['env.account'].Action -eq 'Keep') (($up.Steps | ForEach-Object { "$($_.Id)=$($_.Action)" }) -join ',')
    }
    # the check again right before the delete: data that arrives after the plan keeps the share and the account
    $root = New-Root; $roots += $root; $arm = New-AVDTuneFakeEnvArm; [void](Invoke-Full $arm $good $root)
    $fl0 = New-AVDTuneFakeFiles -Seed @{ Acls = @{ '' = 'x' } }
    $flCalls = @{ N = 0 }
    $fl = [pscustomobject]@{ Kind = 'Fake'; Invoke = { param($m, $u, $t, $h, $b) $flCalls.N++; if ($flCalls.N -ge 3) { $fl0.Store.FileEntries = @('first-profile.vhdx') }; & $fl0.Invoke $m $u $t $h $b }.GetNewClosure() }   # a file arrives after the plan was built and confirmed, before the delete
    $up = Get-AVDTuneEnvUndoPlan -Arm $arm -Token $tok -Root $root -Files $fl -StorageToken 'tok-st-SECRET'
    $arm.Store.Writes.Clear()
    $ur = Invoke-AVDTuneEnvUndo -Arm $arm -Token $tok -Root $root -ConfirmedHash $up.Hash -Files $fl -StorageToken 'tok-st-SECRET' -PollSeconds 0 -MaxPolls 20
    Test-Check 'a file that arrives after the undo plan: the share and the account are not deleted' ($arm.Store.Resources.ContainsKey($accKey) -and @($arm.Store.Writes | Where-Object { $_ -match 'DELETE .*(storageAccounts/contosoprofiles|/shares/profiles)$' }).Count -eq 0 -and (($ur.Results | Where-Object Id -eq 'env.share').Message -like '*not verified empty*')) (($ur.Results | ForEach-Object { "$($_.Id)=$($_.Status) $($_.Message)" }) -join '|')

    # 2: per share and account, two runs
    $root = New-Root; $roots += $root; $arm = New-AVDTuneFakeEnvArm
    $specB = New-Spec @{ AccountName = 'contosoother'; ShareName = 'profilesb'; PrivateEndpointName = 'pe-contosoother' }
    $rA = Invoke-Full $arm $good $root; $rB = Invoke-Full $arm $specB $root
    $fa = New-AVDTuneFakeFiles -Seed @{ Acls = @{ '' = 'x' }; Folders = @('S-1-12-1-1-2-3-4_alice') }; $fb = New-AVDTuneFakeFiles -Seed @{ Acls = @{ '' = 'x' } }
    $two = [pscustomobject]@{ Kind = 'Fake'; Invoke = { param($m, $u, $t, $h, $b) if ($u -like '*contosoprofiles.file*') { & $fa.Invoke $m $u $t $h $b } else { & $fb.Invoke $m $u $t $h $b } }.GetNewClosure() }
    $up = Get-AVDTuneEnvUndoPlan -Arm $arm -Token $tok -Root $root -Files $two -StorageToken 'tok-st-SECRET'
    $acts = @($up.Steps | Where-Object { $_.Type -in 'account', 'share' } | ForEach-Object { "$($_.Type):$(($_.Path -split '\?')[0] -replace '.*storageAccounts/','' -replace '/fileServices.*','')=$($_.Action)" })
    Test-Check 'two runs: the account whose share holds data is kept, the other account with its empty share is deleted (no global flag)' ($rA.Status -eq 'Changed' -and $rB.Status -eq 'Changed' -and ($acts -contains 'share:contosoprofiles=Keep') -and ($acts -contains 'account:contosoprofiles=Keep') -and ($acts -contains 'share:contosoother=Delete') -and ($acts -contains 'account:contosoother=Delete')) ($acts -join ', ')
    # an account with a share AVDTune did not create is kept, even when its own share is empty
    $arm.Store.Resources["/subscriptions/$sub/resourcegroups/rg-example/providers/microsoft.storage/storageaccounts/contosoother/fileservices/default/shares/someoneelse"] = [pscustomobject]@{ name = 'someoneelse'; properties = [pscustomobject]@{ shareQuota = 100 } }
    $up = Get-AVDTuneEnvUndoPlan -Arm $arm -Token $tok -Root $root -Files $two -StorageToken 'tok-st-SECRET'
    $ao = @($up.Steps | Where-Object { $_.Type -eq 'account' -and $_.Path -like '*contosoother*' })[0]
    Test-Check 'an account with a share that AVDTune did not create is kept (ARM list is compared with the journal)' ($ao.Action -eq 'Keep' -and $ao.Reason -like '*did not create*') $ao.Reason

    # 3: the journal is input
    $root = New-Root; $roots += $root; $arm = New-AVDTuneFakeEnvArm; [void](Invoke-Full $arm $good $root)
    $jp = Join-Path $root 'config\azure-setup.json'
    $j0 = [IO.File]::ReadAllText($jp) | ConvertFrom-Json
    $run0 = $j0.Runs[0]
    $mutate = {
        param($edit)
        $jj = [IO.File]::ReadAllText($jp) | ConvertFrom-Json
        & $edit $jj.Runs[0]
        [IO.File]::WriteAllText($jp, ($jj | ConvertTo-Json -Depth 10))
        $arm.Log.Clear()
        Get-AVDTuneEnvUndoPlan -Arm $arm -Token $tok -Root $root
    }
    $orig = [IO.File]::ReadAllText($jp)
    foreach ($c in @(
            @{ N = 'another resource group than the run'; E = { param($r) foreach ($s in $r.Steps) { if ($s.Type -eq 'account') { $s.Path = $s.Path -replace 'resourceGroups/rg-example', 'resourceGroups/rg-other' } } }; Type = 'account' }
            @{ N = 'another account than the run'; E = { param($r) foreach ($s in $r.Steps) { if ($s.Type -eq 'share') { $s.Path = $s.Path -replace 'storageAccounts/contosoprofiles', 'storageAccounts/victimaccount1' } } }; Type = 'share' }
            @{ N = 'another subscription than the run'; E = { param($r) foreach ($s in $r.Steps) { if ($s.Type -eq 'endpoint') { $s.Path = $s.Path -replace 'subscriptions/aaaaaaaa', 'subscriptions/bbbbbbbb' } } }; Type = 'endpoint' }
            @{ N = 'another endpoint than the run'; E = { param($r) foreach ($s in $r.Steps) { if ($s.Type -eq 'endpoint') { $s.Path = $s.Path -replace 'pe-contosoprofiles', 'pe-someone-else' } } }; Type = 'endpoint' }
            @{ N = 'a type that does not match the path'; E = { param($r) foreach ($s in $r.Steps) { if ($s.Type -eq 'share') { $s.Type = 'account' } } }; Type = 'share' })) {
        [IO.File]::WriteAllText($jp, $orig)
        $up = & $mutate $c.E
        $hit = @($up.Steps | Where-Object { $_.Type -eq $c.Type -and $_.Id -like 'env.*' -and $_.Action -in 'Delete', 'Restore' })
        Test-Check "journal as input: an entry with $($c.N) gives no step and no request for it" ($hit.Count -eq 0 -and @($arm.Log | Where-Object { $_ -like '*victimaccount1*' -or $_ -like '*pe-someone-else*' -or $_ -like '*bbbbbbbb*' }).Count -eq 0) (($up.Steps | ForEach-Object { "$($_.Id)=$($_.Action)" }) -join ',')
    }
    [IO.File]::WriteAllText($jp, $orig)
    $arm.Store.Resources[$peKey2].tags = [pscustomobject]@{ Owner = 'someone' }
    $up = & $mutate { param($r) foreach ($s in $r.Steps) { if ($s.Type -eq 'endpoint') { $s.Taggable = $false } } }
    Test-Check 'journal as input: the entry cannot switch the tag check off (Taggable comes from the rule)' (@($up.Steps | Where-Object Id -eq 'env.endpoint')[0].Action -eq 'Keep') $null
    # the recorded old values: only known keys and values
    $root = New-Root; $roots += $root
    $arm = New-AVDTuneFakeEnvArm -Seed @{ Resources = @{ $accKey = @{ name = 'contosoprofiles'; kind = 'FileStorage'; sku = @{ name = 'Premium_LRS' }; location = 'westeurope'; properties = @{ supportsHttpsTrafficOnly = $true; minimumTlsVersion = 'TLS1_0'; allowBlobPublicAccess = $false; publicNetworkAccess = 'Disabled' } } } }
    [void](Invoke-Full $arm $good $root)
    $jp = Join-Path $root 'config\azure-setup.json'
    $jj = [IO.File]::ReadAllText($jp) | ConvertFrom-Json
    $acEntry = @($jj.Runs[0].Steps | Where-Object { $_.Type -eq 'account' })[0]
    $acEntry.Before = [pscustomobject]@{ minimumTlsVersion = 'TLS1_3'; publicNetworkAccess = 'Evil'; allowBlobPublicAccess = 'true'; allowSharedKeyAccess = $true; identity = 'x' }
    [IO.File]::WriteAllText($jp, ($jj | ConvertTo-Json -Depth 10))
    $up = Get-AVDTuneEnvUndoPlan -Arm $arm -Token $tok -Root $root
    $rs = @($up.Steps | Where-Object { $_.Id -eq 'env.account' })[0]
    Test-Check 'journal as input: the recorded old values are reduced to known keys and enum values' ($rs.Action -eq 'Restore' -and (@($rs.Body.properties.Keys) -join ',') -eq 'minimumTlsVersion' -and $rs.Body.properties.minimumTlsVersion -eq 'TLS1_3') ($rs.Body | ConvertTo-Json -Compress)
    $acEntry.Before = [pscustomobject]@{ minimumTlsVersion = 'x; drop'; publicNetworkAccess = 'Evil' }
    [IO.File]::WriteAllText($jp, ($jj | ConvertTo-Json -Depth 10))
    Test-Check 'journal as input: nothing usable left means Keep, not an empty request' (@((Get-AVDTuneEnvUndoPlan -Arm $arm -Token $tok -Root $root).Steps | Where-Object Id -eq 'env.account')[0].Action -eq 'Keep') $null

    # 4: existing accounts are only made stricter
    $mkAcc = { param($props) New-AVDTuneFakeEnvArm -Seed @{ Resources = @{ $accKey = @{ name = 'contosoprofiles'; kind = 'FileStorage'; sku = @{ name = 'Premium_LRS' }; location = 'westeurope'; properties = $props } } } }
    $pOpen = Get-AVDTuneEnvPlan -Arm (& $mkAcc @{ supportsHttpsTrafficOnly = $true; minimumTlsVersion = 'TLS1_2'; allowBlobPublicAccess = $false; publicNetworkAccess = 'Enabled' }) -Token $tok -Spec $good -User 'u'
    Test-Check 'existing account with public access on and a private endpoint: never switched, a manual step and a warning' ((Get-Step $pOpen 'env.account').Action -eq 'None' -and (Get-Step $pOpen 'env.publicaccess').Action -eq 'Manual' -and ($pOpen.Warnings -join ' ') -like '*never switches public access*') (($pOpen.Steps | ForEach-Object { "$($_.Id)=$($_.Action)" }) -join ',')
    $pTls = Get-AVDTuneEnvPlan -Arm (& $mkAcc @{ supportsHttpsTrafficOnly = $true; minimumTlsVersion = 'TLS1_3'; allowBlobPublicAccess = $false; publicNetworkAccess = 'Disabled' }) -Token $tok -Spec $good -User 'u'
    Test-Check 'TLS levels are compared in order: TLS 1.3 is not lowered to 1.2' ((Get-Step $pTls 'env.account').Action -eq 'None') $null
    $pUnk = Get-AVDTuneEnvPlan -Arm (& $mkAcc @{ supportsHttpsTrafficOnly = 'maybe'; minimumTlsVersion = 'TLS9_9'; allowBlobPublicAccess = 'perhaps'; publicNetworkAccess = 'SecuredByPerimeter' }) -Token $tok -Spec $good -User 'u'
    Test-Check 'values of a kind AVDTune does not know are not touched' ((Get-Step $pUnk 'env.account').Action -eq 'None' -and $null -eq (Get-Step $pUnk 'env.publicaccess')) $null
    $pLow = Get-AVDTuneEnvPlan -Arm (& $mkAcc @{ supportsHttpsTrafficOnly = $false; minimumTlsVersion = 'TLS1_1'; allowBlobPublicAccess = $true; publicNetworkAccess = 'Disabled' }) -Token $tok -Spec $good -User 'u'
    $lb = (Get-Step $pLow 'env.account').Body.properties
    Test-Check 'a looser account is tightened: HTTPS only, TLS 1.2, no blob public access' ($lb.supportsHttpsTrafficOnly -eq $true -and $lb.minimumTlsVersion -eq 'TLS1_2' -and $lb.allowBlobPublicAccess -eq $false -and -not $lb.Contains('publicNetworkAccess')) ($lb | ConvertTo-Json -Compress)
    $pPub = Get-AVDTuneEnvPlan -Arm (New-AVDTuneFakeEnvArm -Seed @{ Resources = @{ $accKey = @{ name = 'contosoprofiles'; kind = 'FileStorage'; sku = @{ name = 'Premium_LRS' }; location = 'westeurope'; properties = @{ supportsHttpsTrafficOnly = $true; minimumTlsVersion = 'TLS1_2'; allowBlobPublicAccess = $false; publicNetworkAccess = 'Enabled'; networkAcls = @{ defaultAction = 'Allow' } } } } }) -Token $tok -Spec (New-Spec @{ Endpoint = 'Public' }) -User 'u'
    Test-Check 'existing public account with firewall default Allow: warned, not changed' ((Get-Step $pPub 'env.account').Action -eq 'None' -and ($pPub.Warnings -join ' ') -like '*default action Allow*') ($pPub.Warnings -join '|')
    $root = New-Root; $roots += $root
    $arm = & $mkAcc @{ supportsHttpsTrafficOnly = $true; minimumTlsVersion = 'TLS1_0'; allowBlobPublicAccess = $false; publicNetworkAccess = 'Enabled' }
    [void](Invoke-Full $arm $good $root)
    Test-Check 'applied to an account with public access on: TLS tightened, public access still on' ($arm.Store.Resources[$accKey].properties.minimumTlsVersion -eq 'TLS1_2' -and $arm.Store.Resources[$accKey].properties.publicNetworkAccess -eq 'Enabled') $null

    # 5: create only with create semantics
    $root = New-Root; $roots += $root
    $inner = New-AVDTuneFakeEnvArm
    $shGets = New-Object System.Collections.ArrayList
    $race = [pscustomobject]@{ Kind = 'Race'; Store = $inner.Store; Log = $inner.Log; Invoke = {
            param($Method, $Path, $Token, $Body)
            if ($Method -eq 'GET' -and $Path -like '*/shares/profiles?*') {
                [void]$shGets.Add($Path)
                if ($shGets.Count -eq 1) { [void](& $inner.Invoke 'PUT' ($Path -replace 'api-version=.*$', 'api-version=2024-01-01') $Token @{ properties = @{ shareQuota = 777 } }) }   # someone creates the share between the plan and the create
            }
            & $inner.Invoke $Method $Path $Token $Body
        }.GetNewClosure() }
    $r = Invoke-Full $race $good $root
    $sh = $inner.Store.Resources["/subscriptions/$sub/resourcegroups/rg-example/providers/microsoft.storage/storageaccounts/contosoprofiles/fileservices/default/shares/profiles"]
    Test-Check 'a resource that appears between plan and create: nothing is sent for it, the run stops, the other share is not overwritten' ($r.Status -eq 'Failed' -and (@($r.Results | Where-Object Status -eq 'Failed')[0].Message -like '*exists now*') -and $sh.properties.shareQuota -eq 777 -and @($inner.Store.Writes | Where-Object { $_ -like 'PUT *shares/profiles' }).Count -eq 1) (($r.Results | ForEach-Object { "$($_.Id)=$($_.Status) $($_.Message)" }) -join '|')
    $root = New-Root; $roots += $root; $arm = New-AVDTuneFakeEnvArm; [void](Invoke-Full $arm $good $root)
    $jj = [IO.File]::ReadAllText((Join-Path $root 'config\azure-setup.json')) | ConvertFrom-Json
    $accE = @($jj.Runs[0].Steps | Where-Object { $_.Type -eq 'account' })[0]
    Test-Check 'the journal records what identifies each created resource (creation time or guid)' ($accE.Identity.createdAt -and @($jj.Runs[0].Steps | Where-Object { $_.Action -eq 'Create' -and -not $_.Identity }).Count -eq 0 -and $accE.Identity.createdAt) ($accE | ConvertTo-Json -Depth 4 -Compress)
    # a resource deleted and made again by someone else with the same name and the same tag is not deleted
    $arm.Store.Resources[$peKey2].systemData.createdAt = '2026-11-16T09:00:00.999Z'
    $up = Get-AVDTuneEnvUndoPlan -Arm $arm -Token $tok -Root $root
    Test-Check 'a resource made again under the same name (same tag, other creation time) is kept' (@($up.Steps | Where-Object Id -eq 'env.endpoint')[0].Action -eq 'Keep' -and @($up.Steps | Where-Object Id -eq 'env.endpoint')[0].Reason -like '*created again*') (@($up.Steps | Where-Object Id -eq 'env.endpoint')[0].Reason)

    # N1: a create entry is deleted only when it is clean (status Done) and identified (creation time or guid); else Keep with the reason
    $root = New-Root; $roots += $root; $arm = New-AVDTuneFakeEnvArm; [void](Invoke-Full $arm $good $root)
    $jp = Join-Path $root 'config\azure-setup.json'; $jj = [IO.File]::ReadAllText($jp) | ConvertFrom-Json
    foreach ($e in @($jj.Runs[0].Steps)) {
        if ($e.Id -eq 'env.endpoint') { $e.PSObject.Properties.Remove('Identity') }
        if ($e.Id -eq 'env.role-users') { $e.Status = 'Failed' }
        if ($e.Id -eq 'env.role-admins') { $e.Status = 'Started' }
        if ($e.Id -eq 'env.dnslink') { $e.Identity = [pscustomobject]@{} }
    }
    [IO.File]::WriteAllText($jp, ($jj | ConvertTo-Json -Depth 10))
    $up = Get-AVDTuneEnvUndoPlan -Arm $arm -Token $tok -Root $root; $b1 = @{}; foreach ($s in $up.Steps) { $b1[$s.Id] = $s }
    Test-Check 'N1: a create without a recorded identity (missing or empty) is only kept, with the reason' ($b1['env.endpoint'].Action -eq 'Keep' -and $b1['env.endpoint'].Reason -like '*No creation time or guid*' -and $b1['env.dnslink'].Action -eq 'Keep' -and $b1['env.dnslink'].Reason -like '*No creation time or guid*') (($up.Steps | ForEach-Object { "$($_.Id)=$($_.Action)" }) -join ',')
    Test-Check 'N1: a create with the status Failed or Started is only kept, with the reason' ($b1['env.role-users'].Action -eq 'Keep' -and $b1['env.role-users'].Reason -like '*Failed*' -and $b1['env.role-admins'].Action -eq 'Keep' -and $b1['env.role-admins'].Reason -like '*Started*') (($up.Steps | ForEach-Object { "$($_.Id)=$($_.Action)" }) -join ',')
    Test-Check 'N1: counter-check, a clean identified create of the same run is still deleted' ($b1['env.dnsgroup'].Action -eq 'Delete') (($up.Steps | ForEach-Object { "$($_.Id)=$($_.Action)" }) -join ',')
    Open-AVDTuneWriteGate -SnapshotId 'snapN1' -ConfirmedBy 'Test User'
    $urN1 = Invoke-AVDTuneEnvUndo -Arm $arm -Token $tok -Root $root -ConfirmedHash $up.Hash -PollSeconds 0 -MaxPolls 20
    Test-Check 'N1: the undo sends no DELETE for the kept entries' ($arm.Store.Resources.ContainsKey($peKey2) -and @($arm.Store.Writes | Where-Object { $_ -like 'DELETE *roleassignments*' -or $_ -like 'DELETE *virtualnetworklinks*' -or $_ -like 'DELETE *privateendpoints/pe-contosoprofiles' }).Count -eq 0) (($arm.Store.Writes) -join '|')

    # remaining window of finding 5 (GET then PUT without If-None-Match): the creation time after the PUT is older than its start -> foreign
    $root = New-Root; $roots += $root
    $inner = New-AVDTuneFakeEnvArm
    $shKey = "/subscriptions/$sub/resourcegroups/rg-example/providers/microsoft.storage/storageaccounts/contosoprofiles/fileservices/default/shares/profiles"
    $shGets2 = New-Object System.Collections.ArrayList
    $race2 = [pscustomobject]@{ Kind = 'Race2'; Store = $inner.Store; Log = $inner.Log; Invoke = {
            param($Method, $Path, $Token, $Body)
            $res = & $inner.Invoke $Method $Path $Token $Body
            if ($Method -eq 'GET' -and $Path -like '*/shares/profiles?*') {
                [void]$shGets2.Add($Path)
                if ($shGets2.Count -eq 1) {   # the plans do not read the share (the account is missing); this is the GET right before the create: someone creates the share right after it, long before our request
                    [void](& $inner.Invoke 'PUT' ($Path -replace 'api-version=.*$', 'api-version=2024-01-01') $Token @{ properties = @{ shareQuota = 777 } })
                    $inner.Store.Resources[$shKey].systemData.createdAt = '2026-01-01T08:00:00.000Z'
                }
            }
            $res
        }.GetNewClosure() }
    $r = Invoke-Full $race2 $good $root
    $jj = [IO.File]::ReadAllText((Join-Path $root 'config\azure-setup.json')) | ConvertFrom-Json
    $shE = @($jj.Runs[0].Steps | Where-Object { $_.Type -eq 'share' })[0]
    $fs = @($r.Results | Where-Object Status -eq 'Failed')[0]
    Test-Check 'foreign: a share that existed at our PUT (creation time older than the request) ends the run with a warning, marked Foreign in the journal' ($r.Status -eq 'Failed' -and $fs.Id -eq 'env.share' -and $fs.Message -like 'Warning*foreign*never deletes*' -and $shE.Identity.Foreign -eq $true -and $shE.Status -eq 'Failed' -and @($r.Results | Where-Object Status -eq 'Skipped').Count -gt 0) (($r.Results | ForEach-Object { "$($_.Id)=$($_.Status) $($_.Message)" }) -join '|')
    Open-AVDTuneWriteGate -SnapshotId 'snapN2' -ConfirmedBy 'Test User'
    $upF = Get-AVDTuneEnvUndoPlan -Arm $inner -Token $tok -Root $root -Files $files -StorageToken 'x'; $bF = @{}; foreach ($s in $upF.Steps) { $bF[$s.Id] = $s }
    $urF = Invoke-AVDTuneEnvUndo -Arm $inner -Token $tok -Root $root -ConfirmedHash $upF.Hash -Files $files -StorageToken 'x' -PollSeconds 0 -MaxPolls 20
    Test-Check 'foreign: the undo never deletes it (Keep with the reason), not even with an empty share, and the account stays with it' ($bF['env.share'].Action -eq 'Keep' -and $bF['env.share'].Reason -like '*foreign*' -and $bF['env.account'].Action -ne 'Delete' -and $inner.Store.Resources.ContainsKey($shKey) -and @($inner.Store.Writes | Where-Object { $_ -like 'DELETE *' -and ($_ -like '*shares/profiles' -or $_ -like '*storageaccounts/contosoprofiles') }).Count -eq 0) (($upF.Steps | ForEach-Object { "$($_.Id)=$($_.Action) $($_.Reason)" }) -join '|')
    Test-Check 'foreign: a clean create is not marked foreign' (@($jj.Runs[0].Steps | Where-Object { $_.Type -eq 'account' -and $_.Identity.Foreign }).Count -eq 0) $null

    # N3: no identity readable after the create: no empty catch, the journal says so, the undo keeps the resource
    $root = New-Root; $roots += $root
    $inner = New-AVDTuneFakeEnvArm; $flip = [pscustomobject]@{ On = $false }
    $deaf = [pscustomobject]@{ Kind = 'Deaf'; Store = $inner.Store; Log = $inner.Log; Invoke = {
            param($Method, $Path, $Token, $Body)
            if ($Method -eq 'PUT' -and $Path -like '*/privateEndpoints/pe-contosoprofiles?api-version=*') { $flip.On = $true }
            if ($Method -eq 'GET' -and $flip.On -and $Path -like '*/privateEndpoints/pe-contosoprofiles?api-version=*') { return [pscustomobject]@{ Status = 500; Headers = @{}; Body = [pscustomobject]@{ error = [pscustomobject]@{ code = 'InternalServerError'; message = 'fake: cannot read' } }; Error = '' } }
            & $inner.Invoke $Method $Path $Token $Body
        }.GetNewClosure() }
    $r = Invoke-Full $deaf $good $root
    $flip.On = $false
    $jj = [IO.File]::ReadAllText((Join-Path $root 'config\azure-setup.json')) | ConvertFrom-Json
    $peE = @($jj.Runs[0].Steps | Where-Object { $_.Type -eq 'endpoint' })[0]
    Test-Check 'N3: the identity could not be read: the run goes on, the journal names the missing identity' ($r.Status -eq 'Changed' -and -not $peE.Identity -and $peE.IdentityMissing -like '*fake: cannot read*' -and $peE.Status -eq 'Done') ("$($r.Status) $($r.Message) " + ($peE | ConvertTo-Json -Compress))
    $upM = Get-AVDTuneEnvUndoPlan -Arm $inner -Token $tok -Root $root
    Test-Check 'N3: undo keeps that resource (no identity, see N1)' (@($upM.Steps | Where-Object Id -eq 'env.endpoint')[0].Action -eq 'Keep' -and @($upM.Steps | Where-Object Id -eq 'env.endpoint')[0].Reason -like '*fake: cannot read*') (@($upM.Steps | Where-Object Id -eq 'env.endpoint')[0].Reason)
    Test-Check 'N3: no empty catch after reading the identity' ((Get-Content -LiteralPath (Join-Path $repo 'Modules\AVDTune.Environment.psm1') -Raw) -notmatch "read the new resource'[^\r\n]*catch \{ \}") $null

    # N4: the records of the zone are counted by what exists now, and the link is looked at again right before its delete like the zone
    $root = New-Root; $roots += $root; $arm = New-AVDTuneFakeEnvArm; [void](Invoke-Full $arm $good $root)
    $gKey = "$peKey2/privatednszonegroups/default"
    $arm.Store.Resources.Remove($gKey)   # our zone group is gone already (someone deleted it), the zone holds one record of someone else
    $arm.Store.ExtraRecords = 1
    $up = Get-AVDTuneEnvUndoPlan -Arm $arm -Token $tok -Root $root; $b4 = @{}; foreach ($s in $up.Steps) { $b4[$s.Id] = $s }
    Test-Check 'N4: the journal lists our zone group but it is gone and the zone holds another record: zone and link stay (counted by the real stock)' ($b4['env.dnszone'].Action -eq 'Keep' -and $b4['env.dnslink'].Action -eq 'Keep' -and $b4['env.dnszone'].Reason -like '*record sets*') (($up.Steps | ForEach-Object { "$($_.Id)=$($_.Action)" }) -join ',')
    $root = New-Root; $roots += $root; $arm = New-AVDTuneFakeEnvArm; [void](Invoke-Full $arm $good $root)
    $up = Get-AVDTuneEnvUndoPlan -Arm $arm -Token $tok -Root $root; $b4 = @{}; foreach ($s in $up.Steps) { $b4[$s.Id] = $s }
    Test-Check 'N4: counter-check, with our own zone group and no other record the zone and the link are deleted' ($b4['env.dnszone'].Action -eq 'Delete' -and $b4['env.dnslink'].Action -eq 'Delete') (($up.Steps | ForEach-Object { "$($_.Id)=$($_.Action)" }) -join ',')
    $lateStore = $arm.Store; $lateInner = $arm
    $late = [pscustomobject]@{ Kind = 'Late'; Store = $arm.Store; Log = $arm.Log; Invoke = {
            param($Method, $Path, $Token, $Body)
            if ($Method -eq 'DELETE') { $lateStore.ExtraRecords = 3 }   # records of other accounts arrive after the undo plan, while the undo runs
            & $lateInner.Invoke $Method $Path $Token $Body
        }.GetNewClosure() }
    Open-AVDTuneWriteGate -SnapshotId 'snapN4' -ConfirmedBy 'Test User'
    $ur4 = Invoke-AVDTuneEnvUndo -Arm $late -Token $tok -Root $root -ConfirmedHash $up.Hash -PollSeconds 0 -MaxPolls 20
    $zk = "/subscriptions/$sub/resourcegroups/rg-network/providers/microsoft.network/privatednszones/privatelink.file.core.windows.net"
    $linkKeys = @($arm.Store.Resources.Keys | Where-Object { $_ -like "$zk/virtualnetworklinks/*" })
    Test-Check 'N4: records that arrive after the undo plan: the link is looked at again like the zone, both stay' ($arm.Store.Resources.ContainsKey($zk) -and $linkKeys.Count -eq 1 -and @($arm.Store.Writes | Where-Object { $_ -like 'DELETE *virtualnetworklinks*' -or $_ -like 'DELETE *privatednszones*' }).Count -eq 0 -and @($ur4.Results | Where-Object { $_.Id -in 'env.dnslink', 'env.dnszone' -and $_.Status -eq 'Unchanged' }).Count -eq 2) (($ur4.Results | ForEach-Object { "$($_.Id)=$($_.Status) $($_.Message)" }) -join '|')

    # N5: the role assignments are read over all pages; a nextLink only on management.azure.com
    $scope5 = "$acc/fileServices/default/fileshares/profiles"
    $mkPaged = {
        param([string]$Next)
        $in = & $mkAcc @{ supportsHttpsTrafficOnly = $true; minimumTlsVersion = 'TLS1_2'; allowBlobPublicAccess = $false; publicNetworkAccess = 'Disabled' }
        $in.Store.Roles = @(@{ Scope = $scope5; Principal = $g1; Role = '0c867c2a-1d8c-454a-a3db-ab2ea1bdc8bb'; Name = 'r-one' }, @{ Scope = $scope5; Principal = $g2; Role = 'a7264617-510b-434b-a828-9731dc254ea7'; Name = 'r-two' })
        [pscustomobject]@{ Kind = 'Paged'; Store = $in.Store; Log = $in.Log; Invoke = {
                param($Method, $Path, $Token, $Body)
                if ($Method -eq 'GET' -and $Path -like '*/roleAssignments?*') {
                    if ($Path -like '*skiptoken*') { [void]$in.Log.Add("GET $Path"); return (& $in.Invoke 'GET' ($Path -replace '&%24skiptoken=[^&]*', '') $Token $null) }
                    $nl = if ($Next) { $Next } else { "https://management.azure.com$Path&%24skiptoken=abc" }
                    return [pscustomobject]@{ Status = 200; Headers = @{}; Body = [pscustomobject]@{ value = @(); nextLink = $nl }; Error = '' }
                }
                & $in.Invoke $Method $Path $Token $Body
            }.GetNewClosure() }
    }
    $pg = & $mkPaged ''
    $p5 = Get-AVDTuneEnvPlan -Arm $pg -Token $tok -Spec $good -User 'u'
    Test-Check 'N5: the assignments on the second page are found (the roles are not planned again)' ((Get-Step $p5 'env.role-users').Action -eq 'None' -and (Get-Step $p5 'env.role-admins').Action -eq 'None' -and @($pg.Log | Where-Object { $_ -like '*skiptoken*' }).Count -eq 1) (($p5.Steps | ForEach-Object { "$($_.Id)=$($_.Action)" }) -join ',')
    $pg = & $mkPaged "https://evil.example.test/subscriptions/$sub/resourceGroups/x/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&%24skiptoken=abc"
    $p5 = Get-AVDTuneEnvPlan -Arm $pg -Token $tok -Spec $good -User 'u'
    Test-Check 'N5: a nextLink to another host is not followed (no request for it, a warning)' (@($pg.Log | Where-Object { $_ -like '*evil*' -or $_ -like '*skiptoken*' }).Count -eq 0 -and ($p5.Warnings -join ' ') -like '*not followed*' -and (Get-Step $p5 'env.role-users').Action -eq 'Create') (($p5.Warnings) -join '|')

    # 6: the VNet link stays with the zone when the zone holds other records
    $root = New-Root; $roots += $root; $arm = New-AVDTuneFakeEnvArm -Seed @{ ExtraRecords = 3 }; [void](Invoke-Full $arm $good $root)
    $up = Get-AVDTuneEnvUndoPlan -Arm $arm -Token $tok -Root $root
    Test-Check 'a zone with other record sets: the zone and its VNet link both stay' (@($up.Steps | Where-Object Id -eq 'env.dnslink')[0].Action -eq 'Keep' -and @($up.Steps | Where-Object Id -eq 'env.dnszone')[0].Action -eq 'Keep') (($up.Steps | ForEach-Object { "$($_.Id)=$($_.Action)" }) -join ',')

    # 8: role assignments are checked in the writer
    $rolePath = "$acc/fileServices/default/fileshares/profiles/providers/Microsoft.Authorization/roleAssignments/$(Get-AVDTuneEnvRoleName 's' 'p' 'r')?api-version=2022-04-01"
    $okBody = @{ properties = @{ roleDefinitionId = "/subscriptions/$sub/providers/Microsoft.Authorization/roleDefinitions/0c867c2a-1d8c-454a-a3db-ab2ea1bdc8bb"; principalId = $g1; principalType = 'Group' } }
    foreach ($c in @(
            @{ N = 'the Owner role'; B = @{ properties = @{ roleDefinitionId = "/subscriptions/$sub/providers/Microsoft.Authorization/roleDefinitions/99999999-9999-9999-9999-999999999999"; principalId = $g1; principalType = 'Group' } } }
            @{ N = 'a role definition of another subscription'; B = @{ properties = @{ roleDefinitionId = "/subscriptions/bbbbbbbb-bbbb-cccc-dddd-eeeeeeeeeeee/providers/Microsoft.Authorization/roleDefinitions/0c867c2a-1d8c-454a-a3db-ab2ea1bdc8bb"; principalId = $g1; principalType = 'Group' } } }
            @{ N = 'principal type User'; B = @{ properties = @{ roleDefinitionId = $okBody.properties.roleDefinitionId; principalId = $g1; principalType = 'User' } } }
            @{ N = 'a principal that is not a GUID'; B = @{ properties = @{ roleDefinitionId = $okBody.properties.roleDefinitionId; principalId = 'everyone'; principalType = 'Group' } } })) {
        $arm = New-AVDTuneFakeEnvArm
        $w = Invoke-AVDTuneEnvWrite -Arm $arm -Token $tok -Method PUT -Path $rolePath -Body $c.B -What 'assign' -PollSeconds 0
        Test-Check "role writer refuses $($c.N), nothing is sent" (-not $w.Ok -and $w.Message -like '*not one of the two share roles*' -and $arm.Log.Count -eq 0) $w.Message
    }
    $arm = New-AVDTuneFakeEnvArm
    Test-Check 'role writer sends the two share roles for a group' ((Invoke-AVDTuneEnvWrite -Arm $arm -Token $tok -Method PUT -Path $rolePath -Body $okBody -What 'assign' -PollSeconds 0).Ok -and (Get-Writes $arm).Count -eq 1) $null
    $np = Get-AVDTuneEnvPlan -Arm (New-AVDTuneFakeEnvArm) -Token $tok -Spec (New-Spec @{ UsersGroupName = 'FSLogix Users'; AdminsGroupName = 'AVD Admins' }) -User 'u'
    Test-Check 'the plan shows the typed display name of the group next to its object ID' (((Get-Step $np 'env.role-users').Changes -join ' ') -like "*$g1 (FSLogix Users)*" -and ((Get-Step $np 'env.role-admins').Changes -join ' ') -like '*(AVD Admins)*') ((Get-Step $np 'env.role-users').Changes -join ' ')
    Test-Check 'a group name with odd characters is refused by the spec' ((Test-AVDTuneEnvSpec (New-Spec @{ UsersGroupName = 'a<script>' })).Count -ge 1) $null

    # 10: shared key off on new accounts
    $nb = (Get-Step $plan 'env.account').Body.properties
    Test-Check 'a new account has shared key access off, with the note about the emergency access' ($nb.allowSharedKeyAccess -eq $false -and ($plan.Warnings -join ' ') -like '*Shared key access is switched off*portal*') ($plan.Warnings -join '|')

    # 11: polling links of real Azure URLs
    $real = "https://management.azure.com/subscriptions/$sub/providers/Microsoft.Network/locations/westeurope/operations/33333333-3333-3333-3333-333333333333?api-version=2023-11-01&t=638700000000000000&c=MIIHhzCCBm-gAwIBAgITOgAB%2BQw%2Bx_y%2F%3D&s=abc-DEF_123~x&h=QmFzZTY0LS1oYXNo"
    Test-Check 'a real looking polling URL (signed values with base64 and percent characters) is accepted' ((Get-AVDTuneEnvPollPath $real) -like "/subscriptions/$sub/providers/Microsoft.Network/locations/westeurope/operations/*&h=QmFzZTY0LS1oYXNo") $null
    foreach ($bad in @("https://management.azure.com.evil.example/subscriptions/$sub/x?api-version=2023-11-01", "https://evil.example/subscriptions/$sub/x?api-version=2023-11-01", "https://management.azure.com/subscriptions/$sub/%2e%2e/x?api-version=2023-11-01",
            "https://management.azure.com/subscriptions/$sub/x?api-version=2023-11-01&c=a b", "https://management.azure.com/subscriptions/$sub/x?api-version=2023-11-01&c=<x>", "https://management.azure.com/subscriptions/$sub/x?api-version=2023-11-01#frag", "https://management.azure.com:8443/subscriptions/$sub/x?api-version=1")) {
        Test-Check "polling URL refused: $($bad -replace [regex]::Escape($sub), '<sub>')" (Test-Throws { Get-AVDTuneEnvPollPath $bad }) $null
    }
    Test-Check 'the relaxed query is only for polling GETs: a write with it is refused' ((Test-Throws { Assert-AVDTuneEnvArmPath "$acc`?api-version=2024-01-01&c=a%2Bb" 'PUT' -Poll }) -and (Test-Throws { Assert-AVDTuneEnvArmPath "$acc`?api-version=2024-01-01&c=a%2Bb" 'GET' })) $null
    Close-AVDTuneWriteGate

    # ---------------------------------------------------------------- the master, the ACL and the test (existing steps)
    $root = New-Root; $roots += $root
    Close-AVDTuneWriteGate
    $m = New-AVDTuneFakeMachine
    $t = Get-Thrown { Set-AVDTuneEnvMaster -Machine $m -Spec $good -Identity EntraKerberos -Root $root -User 'u' }
    Test-Check 'FSLogix on the master: refused without the gate' ($t -like '*snapshot gate*' -and @($m.Log | Where-Object { $_ -like 'RegSet*' }).Count -eq 0) $t
    Open-AVDTuneWriteGate -SnapshotId 'snap3' -ConfirmedBy 'Test User'
    $w = Set-AVDTuneEnvMaster -Machine $m -Spec $good -Identity EntraKerberos -Root $root -User 'u' -SnapshotId 'snap3' -WhatIf
    Test-Check 'FSLogix on the master: WhatIf changes nothing' (@($m.Log | Where-Object { $_ -like 'RegSet*' }).Count -eq 0) $null
    [void](Set-AVDTuneEnvMaster -Machine $m -Spec $good -Identity EntraKerberos -Root $root -User 'u' -SnapshotId 'snap3')
    Test-Check 'FSLogix on the master: Enabled, VHDLocations with the new share and the cloud Kerberos ticket value' (($m.Log -join "`n") -like '*FSLogix\Profiles|VHDLocations*contosoprofiles.file.core.windows.net\profiles*' -and ($m.Log -join "`n") -like '*Enabled=1*' -and ($m.Log -join "`n") -like '*CloudKerberosTicketRetrievalEnabled=1*') ($m.Log -join '|')
    $kr = @(Read-AVDTuneFSLogixUndo -Root $root | Where-Object Id -eq 'fslogix.kerberos.cloudticket')
    Test-Check 'FSLogix on the master (#100): the cloud Kerberos ticket value has an undo record (absent before), the FSLogix undo removes it again' ($kr.Count -eq 1 -and $null -eq $kr[0].Previous -and $kr[0].Value -eq 1 -and (Undo-AVDTuneFSLogixSettings -Machine $m -Root $root -User 'u' -SnapshotId 'snap3') -and $null -eq (& $m.RegGet 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\Kerberos\Parameters' 'CloudKerberosTicketRetrievalEnabled')) ($kr | ConvertTo-Json -Compress)
    $lcRoot = New-Root; $roots += $lcRoot
    Open-AVDTuneWriteGate -SnapshotId 'snap4' -ConfirmedBy 'Test User'
    $before = Get-AVDTuneLastChange -Root $lcRoot
    [void](Set-AVDTuneEnvMaster -Machine (New-AVDTuneFakeMachine) -Spec $good -Identity EntraKerberos -Root $lcRoot -User 'u' -SnapshotId 'snap4' -WhatIf)
    Test-Check 'the master part: WhatIf does not set LastChange' ($null -eq $before -and $null -eq (Get-AVDTuneLastChange -Root $lcRoot)) $null
    [void](Set-AVDTuneEnvMaster -Machine (New-AVDTuneFakeMachine) -Spec $good -Identity EntraKerberos -Root $lcRoot -User 'u' -SnapshotId 'snap4')
    Test-Check 'the master part sets LastChange (registry of the master)' ($null -ne (Get-AVDTuneLastChange -Root $lcRoot)) $null
    $lcRoot2 = New-Root; $roots += $lcRoot2
    $fm = New-AVDTuneFakeMachine -Seed @{ }; $fm.Store.FailWrites = @('VHDLocations')
    [void](Set-AVDTuneEnvMaster -Machine $fm -Spec $good -Identity EntraKerberos -Root $lcRoot2 -User 'u' -SnapshotId 'snap4' -ErrorAction SilentlyContinue)
    Test-Check 'the master part sets LastChange also when a registry write fails' ($null -ne (Get-AVDTuneLastChange -Root $lcRoot2)) $null
    $azRoot = New-Root; $roots += $azRoot
    $azArm = New-AVDTuneFakeEnvArm
    [void](Invoke-Full $azArm $good $azRoot)
    $az2 = New-Root; $roots += $az2
    Test-Check 'Azure steps still need the open gate and the plan hash (no LastChange does not mean no gate)' ($null -eq (Get-AVDTuneLastChange -Root $azRoot) -and (Get-Thrown { Close-AVDTuneWriteGate; Invoke-Full (New-AVDTuneFakeEnvArm) $good $az2 }) -like '*snapshot gate*') $null
    Open-AVDTuneWriteGate -SnapshotId 'snap4' -ConfirmedBy 'Test User'
    $e2 = New-AVDTuneFakeMachine
    [void](Set-AVDTuneEnvMaster -Machine $e2 -Spec $good -Identity EntraDs -Root $root -User 'u' -SnapshotId 'snap3')
    Test-Check 'the Kerberos client value is only set for Entra Kerberos' (($e2.Log -join "`n") -notlike '*CloudKerberosTicketRetrievalEnabled*') $null
    $filesAcl = New-AVDTuneFakeFiles -Seed @{ Acls = @{ '' = (New-AVDTuneFSLogixRecommendedSddl -UsersSid 'S-1-5-32-545' -AdminsSid 'S-1-5-32-544') }; Folders = @() }
    $ad = Get-AVDTuneEnvAclDiff -Files $filesAcl -StorageToken 'tok-st-SECRET' -Spec $good
    Test-Check 'ACL diff: the groups of the spec become Entra SIDs and the existing ACL logic compares them' ($ad.Ok -and $ad.Diff.Findings.Count -ge 1 -and ($ad.Diff.Recommended -like "*$(ConvertTo-AVDTuneEntraSid $g1)*") -and -not $ad.Diff.Compliant) ($ad | ConvertTo-Json -Depth 3 -Compress)
    $env:AVDTUNE_ROOT = $null
    $e3 = New-AVDTuneFakeEnvArm
    $verifyArm = $e3
    [void](Invoke-Full $e3 $good (New-Root))
    $vr = Invoke-AVDTuneEnvVerify -Machine (New-AVDTuneFakeMachine) -F (New-AVDTuneFakeFSLogix) -Spec $good -Arm $e3 -ArmToken $tok
    Test-Check 'verify: the storage check runs for the new share and finds the account that was created' ((@($vr.Rows | Where-Object Id -eq 'st.account').Count -eq 1 -and $vr.Account -eq 'contosoprofiles') -and ($vr | ConvertTo-Json -Depth 6) -notmatch 'SECRET') ((@($vr.Rows | Select-Object -First 3 | ForEach-Object { "$($_.Id)=$($_.Status) $($_.Reason)" })) -join '|')

    # ---------------------------------------------------------------- the page and its hooks (no window is opened here: the GUI smoke test is the Smoke-Tester's)
    foreach ($f in 'AVDTune-Environment.ps1', 'Start-AVDTune.ps1', 'Modules\AVDTune.Environment.psm1') {
        $errs = $null; [void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo $f), [ref]$null, [ref]$errs)
        Test-Check "syntax: $f" (@($errs).Count -eq 0) (@($errs | ForEach-Object Message) -join '|')
    }
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    [xml]$px = Get-Content (Join-Path $repo 'UI\AVDTune.Environment.xaml') -Raw -Encoding UTF8
    $pageRoot = [Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($px))
    $names = @($px.SelectNodes("//*[@*[local-name()='Name']]") | ForEach-Object { $_.Attributes | Where-Object LocalName -eq 'Name' | Select-Object -ExpandProperty Value })
    $pageScript = [IO.File]::ReadAllText((Join-Path $repo 'AVDTune-Environment.ps1'))
    $used = @([regex]::Matches($pageScript, '\$ui\.((?:Txt|Btn|Panel|Page)Env\w*)') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
    Test-Check 'the page XAML loads and every control the script uses is in it' ($pageRoot -is [System.Windows.Controls.Grid] -and $pageRoot.Visibility -eq 'Collapsed' -and @($used | Where-Object { $_ -notin $names }).Count -eq 0) ((@($used | Where-Object { $_ -notin $names })) -join ',')
    $main = [IO.File]::ReadAllText((Join-Path $repo 'Start-AVDTune.ps1'))
    Test-Check 'the hooks in Start-AVDTune.ps1: module, navigation entry, page switch, view and the page file' ($main -match "'Environment'(, '\w+')*\) \{ Import" -and $main -match "Key = 'Environment'" -and $main -match "Update-EnvView" -and $main -match "AVDTune-Environment\.ps1") $null
    Test-Check 'the page changes nothing without the plan hash: apply and undo pass the hash of the plan that was shown' ($pageScript -match 'ConfirmedHash \$A\.Hash' -and ([regex]::Matches($pageScript, 'Hash = \$p\.Hash')).Count -eq 2 -and ([regex]::Matches($pageScript, 'ConfirmedHash')).Count -eq 2 -and $pageScript -match "Confirm-Action") $null
    $masterPart = $pageScript.Substring($pageScript.IndexOf('function Get-EnvPlanned'))
    Test-Check 'the master part takes the plan that was shown (Spec and Identity), not the form, and names VHDLocations in the confirmation' ($masterPart -notmatch 'Get-EnvSpec' -and ([regex]::Matches($masterPart, '-Spec \$pl\.Spec -Identity \$pl\.Identity')).Count -eq 2 -and $masterPart -match "T 'env\.ask\.fslogix' \`$\(Get-AVDTuneEnvVhdLocation \`$pl\.Spec\)" -and (Get-Content -Raw -Encoding UTF8 (Join-Path $repo 'UI\Strings.en.json') | ConvertFrom-Json).'env.ask.fslogix' -like '*VHDLocations = {0}*' -and $masterPart -match 'Make the plan first') $null
}
finally {
    Close-AVDTuneWriteGate
    foreach ($r in $roots) { Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue }
    Remove-Item Env:\AVDTUNE_ROOT -ErrorAction SilentlyContinue
}
if ($script:failed -gt 0) { throw "$($script:failed) check(s) failed." }
