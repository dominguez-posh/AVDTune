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
    [void](Initialize-AVDTuneState -Root $r)
    [void](Start-AVDTuneImageVersion -Root $r -Date ([datetime]'2026-11-15') -User 'admin1')
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
    Test-Check 'existing account that deviates: an update of only the deviating values, the old values kept for undo' ($la.Action -eq 'Update' -and $la.Method -eq 'PATCH' -and $la.Body.properties.minimumTlsVersion -eq 'TLS1_2' -and $la.Body.properties.publicNetworkAccess -eq 'Disabled' -and $la.Before.minimumTlsVersion -eq 'TLS1_0' -and -not $la.Body.properties.Contains('supportsHttpsTrafficOnly')) ($la.Changes -join '|')
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
    Test-Check 'an aligned existing account: TLS 1.2 was set, undo restores the recorded TLS 1.0 and public access' ($tlsNow -eq 'TLS1_2' -and $arm.Store.Resources[$accKey].properties.minimumTlsVersion -eq 'TLS1_0' -and $arm.Store.Resources[$accKey].properties.publicNetworkAccess -eq 'Enabled') ($ur.Results | ConvertTo-Json -Compress)
    # the journal is data: a planted path that is not on the allowlist is never sent
    $root = New-Root; $roots += $root
    $arm = New-AVDTuneFakeEnvArm
    $jp = Join-Path $root 'config\azure-setup.json'
    New-Item -ItemType Directory -Path (Split-Path $jp) -Force | Out-Null
    $evilJournal = @{ Schema = 1; Runs = @(@{ RunId = 'x'; Steps = @(@{ Id = 'env.account'; Type = 'account'; Path = "/subscriptions/$sub/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/golden"; Action = 'Create'; Taggable = $true; Before = $null; Status = 'Done'; Undone = $false; At = (Get-Date).ToString('o') }) }) }
    [IO.File]::WriteAllText($jp, ($evilJournal | ConvertTo-Json -Depth 8))
    $up = Get-AVDTuneEnvUndoPlan -Arm $arm -Token $tok -Root $root
    Test-Check 'a journal entry that points at another resource type produces no step and no request' ($up.Steps.Count -eq 0 -and $arm.Log.Count -eq 0) $null

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
    Test-Check 'the hooks in Start-AVDTune.ps1: module, navigation entry, page switch, view and the page file' ($main -match "'Storage', 'Environment'\) \{ Import" -and $main -match "Key = 'Environment'" -and $main -match "Update-EnvView" -and $main -match "AVDTune-Environment\.ps1") $null
    Test-Check 'the page changes nothing without the plan hash: apply and undo pass the hash of the plan that was shown' ($pageScript -match 'ConfirmedHash \$p\.Hash' -and ([regex]::Matches($pageScript, 'ConfirmedHash')).Count -eq 2 -and $pageScript -match "Confirm-Action") $null
}
finally {
    Close-AVDTuneWriteGate
    foreach ($r in $roots) { Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue }
    Remove-Item Env:\AVDTUNE_ROOT -ErrorAction SilentlyContinue
}
if ($script:failed -gt 0) { throw "$($script:failed) check(s) failed." }
