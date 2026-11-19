# Fakes for the external services of the start sequence: sign-in (Auth), Azure Resource Manager (Arm), LDAP (Ldap). Same members as the real
# adapters (Modules\AVDTune.Session.psm1, AVDTune.Snapshot.psm1, AVDTune.Directory.psm1), kept in memory. No network, no tenant, no domain controller.
# Dot-source this file, then: $auth = New-AVDTuneFakeAuth; $arm = New-AVDTuneFakeArm; $ldap = New-AVDTuneFakeLdap
# Every fake has .Store (state, switches for the error paths) and .Log (what was asked; never tokens or passwords).
# All names, IDs and addresses below are made up.

. $(if (Get-Command Resolve-AVDTuneTestScript -ErrorAction Ignore) { $fakeShared = Resolve-AVDTuneTestScript -Path (Join-Path $PSScriptRoot 'FakeShared.ps1') -AppRoot (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent); if (-not $fakeShared) { throw 'FakeShared.ps1 is not a file below the Tests folder of this copy.' }; $fakeShared } else { Join-Path $PSScriptRoot 'FakeShared.ps1' })   # fakes that several runspaces use at once (#80), through the test script gate when the module is loaded
$script:FakeTenant = '11111111-2222-3333-4444-555555555555'
$script:FakeSubscription = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'

function ConvertTo-FakeBase64Url([string]$Text) { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text)).TrimEnd('=').Replace('+', '-').Replace('/', '_') }

function ConvertTo-FakeJson($Object) { $Object | ConvertTo-Json -Depth 10 | ConvertFrom-Json }   # what a real answer looks like: parsed JSON

function New-FakeJwt([hashtable]$Claims) { (ConvertTo-FakeBase64Url '{"alg":"none"}') + '.' + (ConvertTo-FakeBase64Url ($Claims | ConvertTo-Json -Compress)) + '.fakesignature' }

# ------------------------------------------------------------------ sign-in, tenant discovery, Graph of the setup
# Switches in .Store: Offline, Cancel, ConsentMissing (array of audiences: 'Arm', 'Sites', 'Graph', 'Storage'), StorageScopes (scp of the storage token, default user_impersonation),
# StorageAud (aud of the storage token instead of https://storage.azure.com), StorageSpMissing (no Azure Storage service principal in the tenant),
# ArmAud (aud of the ARM token instead of https://management.azure.com), StorageWrongTenant (tid of another tenant on the storage token only), StorageUseRoles (the storage token has a roles claim instead of scp), WrongTenant, ExpiresIn (seconds), NoRefreshToken,
# Consented (resource -> consented scopes, all of them go into every token of that resource), ExtraScopes (resource -> scopes beyond AVDTune's),
# SingleTenant (a sign-in of AVDTune's app at 'organizations' fails with AADSTS50194, like a single-tenant registration), SetupNoConsent (the setup
# token lacks Application.ReadWrite.All), Domains (domain -> tenant ID of the OpenID discovery; others: 400), DiscoveryOffline, DiscoveryIssuer (issuer
# override). Graph: AppForbidden, GrantForbidden, GraphOffline, ArmSpMissing, SpCreateFailures (POSTs of the new service principal that fail first),
# AssignForbidden, NoCliGrant (no own consent for Graph CLI Tools), CliOrgGrant (Graph CLI Tools with setup scopes for the organization),
# Apps (applications in the tenant: @{ id; appId; displayName; tags; publicClient; signInAudience; passwordCredentials; keyCredentials; web; spa;
# identifierUris; owners; Federated }), Grants, ServicePrincipals
# Site permissions (issue #96, AVDTune.SiteAccess.psm1): Sites (table 'host:/sites/name' in lower case -> site id; one made-up site is there), SitePermissions (list of
# @{ id; SiteId; roles; AppId }), SiteSetupNoConsent (the sign-in for the site permission lacks Sites.FullControl.All), SiteGrantForbidden (403 to POST and DELETE of
# a site permission, like an account without the SharePoint role), SiteReadBackOther (the new permission names another application when read back). Like the real
# Graph, the site permission calls need a token with Sites.FullControl.All (the daily token with Sites.Selected gets 403).
function New-AVDTuneFakeAuth {
    param([hashtable]$Seed = @{})
    $graphSp = @{ id = 'sp-graph-0001'; appId = '00000003-0000-0000-c000-000000000000'; oauth2PermissionScopes = @(
            'Group.Read.All', 'DeviceManagementApps.Read.All', 'Sites.Selected', 'offline_access', 'openid', 'profile', 'User.Read' | ForEach-Object { @{ id = "scope-$_"; value = $_ } }) }
    $armSp = @{ id = 'sp-arm-0001'; appId = '797f4846-ba00-4fd7-ba43-dac1f8f63013'; oauth2PermissionScopes = @(@{ id = 'scope-user_impersonation'; value = 'user_impersonation' }) }
    $storageSp = @{ id = 'sp-storage-0001'; appId = 'e406a681-f3d4-42a8-90b6-c2b029497af1'; oauth2PermissionScopes = @(@{ id = 'scope-storage-user_impersonation'; value = 'user_impersonation' }) }
    $store = @{ ArmAud = ''; StorageWrongTenant = $false; StorageUseRoles = $false; StorageScopes = @('user_impersonation'); StorageAud = ''; StorageSpMissing = $false; Offline = $false; Cancel = $false; ConsentMissing = @(); WrongTenant = $false; ExpiresIn = 3600; NoRefreshToken = $false; SingleTenant = $false; SetupNoConsent = $false
        Upn = 'admin.example@contoso.example'; Name = 'Alex Example'; Tenant = $script:FakeTenant; Log = (New-Object System.Collections.ArrayList); Counter = 0
        Consented = @{ 'https://graph.microsoft.com' = @('Group.Read.All', 'DeviceManagementApps.Read.All', 'Sites.Selected'); 'https://management.azure.com' = @('user_impersonation') }
        ExtraScopes = @{}; Domains = @{ 'contoso.example' = $script:FakeTenant }; DiscoveryOffline = $false; DiscoveryIssuer = ''
        AppForbidden = $false; GrantForbidden = $false; GraphOffline = $false; ArmSpMissing = $false; SpCreateFailures = 0; AssignForbidden = $false; NoCliGrant = $false; CliOrgGrant = $false
        Sites = @{ 'contoso.sharepoint.com:/sites/avd-environment' = 'contoso.sharepoint.com,0a0a0a0a-1111-2222-3333-444444444444,0b0b0b0b-5555-6666-7777-888888888888' }; SitePermissions = (New-Object System.Collections.ArrayList); SiteSetupNoConsent = $false; SiteGrantForbidden = $false; SiteReadBackOther = $false
        Apps = (New-Object System.Collections.ArrayList); Grants = (New-Object System.Collections.ArrayList); ServicePrincipals = (New-Object System.Collections.ArrayList); NextId = 0 }
    foreach ($k in $Seed.Keys) { $store[$k] = $Seed[$k] }
    [void]$store.ServicePrincipals.Add($graphSp)
    [void]$store.ServicePrincipals.Add(@{ id = 'sp-cli-0001'; appId = '14d82eec-204b-4c2f-b7e8-296a70dab67e'; oauth2PermissionScopes = @() })
    # the admin's own consent for Graph CLI Tools as the setup sign-in leaves it; CliOrgGrant: one for the whole organization with the setup scopes
    if (-not $store.NoCliGrant) { [void]$store.Grants.Add(@{ id = 'grant-cli-own'; clientId = 'sp-cli-0001'; consentType = 'Principal'; principalId = 'oid-fake'; resourceId = 'sp-graph-0001'; scope = 'openid profile User.Read Application.ReadWrite.All DelegatedPermissionGrant.ReadWrite.All' }) }
    if ($store.CliOrgGrant) { [void]$store.Grants.Add(@{ id = 'grant-cli-org'; clientId = 'sp-cli-0001'; consentType = 'AllPrincipals'; principalId = $null; resourceId = 'sp-graph-0001'; scope = 'User.Read Application.ReadWrite.All' }) }
    if (-not $store.ArmSpMissing) { [void]$store.ServicePrincipals.Add($armSp) }
    if (-not $store.StorageSpMissing) { [void]$store.ServicePrincipals.Add($storageSp) }
    $make = {
        param($Scopes)
        $urls = @($Scopes)
        $resource = ($urls[0] -replace '^(https://[^/]+)/.*$', '$1')
        # Like Microsoft's v2 endpoint: a token carries every consented scope of its resource, not only the ones asked for
        $names = @(@($store.Consented[$resource]) + @($store.ExtraScopes[$resource]) | Where-Object { $_ } | Select-Object -Unique)
        if ($names.Count -eq 0) { $names = @($urls | ForEach-Object { $_ -replace '^https://[^/]+/', '' }) }
        $audience = if ($resource -eq 'https://graph.microsoft.com') { 'https://graph.microsoft.com' } else { $resource }
        if ($resource -eq 'https://management.azure.com' -and $store.ArmAud) { $audience = $store.ArmAud }
        if ($resource -eq 'https://storage.azure.com') { $names = @($store.StorageScopes); if ($store.StorageAud) { $audience = $store.StorageAud } }
        $store.Counter++
        $claims = @{ aud = $audience; tid = $(if ($store.WrongTenant) { '99999999-0000-0000-0000-000000000000' } else { $store.Tenant }); upn = $store.Upn; name = $store.Name; oid = 'oid-fake'; scp = ($names -join ' '); n = $store.Counter }
        if ($resource -eq 'https://storage.azure.com') {
            if ($store.StorageWrongTenant) { $claims.tid = '99999999-0000-0000-0000-000000000000' }
            if ($store.StorageUseRoles) { $claims.Remove('scp'); $claims.roles = @($names) }
        }
        [pscustomobject]@{ access_token = (New-FakeJwt $claims); refresh_token = $(if ($store.NoRefreshToken) { $null } else { "fake-refresh-$($store.Counter)" }); expires_in = $store.ExpiresIn; scope = ($names -join ' ') }
    }.GetNewClosure()
    $a = [ordered]@{ Kind = 'Fake'; Store = $store; Log = $store.Log }
    $a.SignIn = {
        param($TenantId, $ClientId, $Scopes, $LoginHint)
        $setup = ($ClientId -eq '14d82eec-204b-4c2f-b7e8-296a70dab67e')
        [void]$store.Log.Add("SignIn tenant=$TenantId client=$(if ($setup) { 'setup' } else { $ClientId }) hint=$LoginHint scopes=$(@($Scopes) -join ',')")
        # LeaveProfileIn: like the shared sign-in window, leaves a temporary profile folder behind (a cookie file in it)
        if ($store.ContainsKey('LeaveProfileIn') -and $store.LeaveProfileIn) {
            $profileDir = Join-Path $store.LeaveProfileIn ('PackTuneSignIn-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path (Join-Path $profileDir 'EBWebView\Default') -Force | Out-Null
            [IO.File]::WriteAllText((Join-Path $profileDir 'EBWebView\Default\Cookies'), 'fake cookie store')
        }
        if ($store.Offline) { throw 'The remote name could not be resolved: login.microsoftonline.com' }
        if ($store.Cancel) { throw 'Sign-in cancelled.' }
        if ($setup) {
            $store.Counter++
            $scp = if ($store.SetupNoConsent) { 'User.Read' } else { 'Application.ReadWrite.All DelegatedPermissionGrant.ReadWrite.All User.Read' }
            # the sign-in for the site permission (issue #96) asks for Sites.FullControl.All only
            if (@($Scopes) -contains 'https://graph.microsoft.com/Sites.FullControl.All') { $scp = if ($store.SiteSetupNoConsent) { 'User.Read' } else { 'Sites.FullControl.All User.Read' } }
            $claims = @{ aud = 'https://graph.microsoft.com'; tid = $(if ($store.WrongTenant) { '99999999-0000-0000-0000-000000000000' } else { $store.Tenant }); upn = $store.Upn; name = $store.Name; oid = 'oid-fake'; scp = $scp; n = $store.Counter }
            return [pscustomobject]@{ access_token = (New-FakeJwt $claims); refresh_token = 'fake-refresh-setup'; expires_in = 3600; scope = $scp }
        }
        if ($TenantId -eq 'organizations' -and $store.SingleTenant) { throw "Sign-in failed: AADSTS50194: Application '$ClientId' is not configured as a multi-tenant application." }
        & $make $Scopes
    }.GetNewClosure()
    $a.Refresh = {
        param($TenantId, $ClientId, $RefreshToken, $Scopes)
        [void]$store.Log.Add("Refresh tenant=$TenantId scopes=$(@($Scopes) -join ',') hasRefreshToken=$([bool]$RefreshToken)")
        if ($store.Offline) { throw 'Unable to connect to the remote server' }
        $res = ($Scopes[0] -replace '^https://([^/]+)/.*$', '$1')
        $audience = if ($res -like 'graph*') { if ($Scopes[0] -like '*Sites.Selected') { 'Sites' } else { 'Graph' } } elseif ($res -like 'storage.azure.com*') { 'Storage' } else { 'Arm' }
        if ($audience -in @($store.ConsentMissing)) { throw "Token request failed: AADSTS65001: The user or administrator has not consented to use the application (audience $audience)." }
        & $make $Scopes
    }.GetNewClosure()
    $a.Discover = {
        param($Domain)
        [void]$store.Log.Add("Discover $Domain")
        if ($store.DiscoveryOffline) { return [pscustomobject]@{ Status = 0; Body = $null; Error = 'The remote name could not be resolved: login.microsoftonline.com' } }
        if (-not $store.Domains.ContainsKey([string]$Domain)) { return [pscustomobject]@{ Status = 400; Body = (ConvertTo-FakeJson @{ error = 'invalid_tenant'; error_description = 'AADSTS90002: Tenant not found.' }); Error = '' } }
        $issuer = if ($store.DiscoveryIssuer) { $store.DiscoveryIssuer } else { "https://login.microsoftonline.com/$($store.Domains[[string]$Domain])/v2.0" }
        [pscustomobject]@{ Status = 200; Body = (ConvertTo-FakeJson @{ issuer = $issuer; token_endpoint = 'https://login.microsoftonline.com/x/oauth2/v2.0/token' }); Error = '' }
    }.GetNewClosure()
    $a.Graph = {
        param($Method, $Path, $Token, $Body)
        [void]$store.Log.Add("Graph $Method $Path")
        $ok = { param($b, $status = 200) [pscustomobject]@{ Status = $status; Body = (ConvertTo-FakeJson $b); Error = '' } }
        $none = [pscustomobject]@{ Status = 204; Body = $null; Error = '' }
        $deny = [pscustomobject]@{ Status = 403; Body = (ConvertTo-FakeJson @{ error = @{ code = 'Authorization_RequestDenied'; message = 'Insufficient privileges to complete the operation.' } }); Error = '' }
        if (-not $Token) { return [pscustomobject]@{ Status = 401; Body = $null; Error = 'no token' } }
        if ($store.GraphOffline) { return [pscustomobject]@{ Status = 0; Body = $null; Error = 'The remote name could not be resolved: graph.microsoft.com' } }
        $p = $Path.Split('?')[0]
        # $filter: every "<property> eq '<value>'" must match (enough for the filters of the setup)
        $conds = @{}
        if ($Path -match '\$filter=([^&]*)') { foreach ($m in [regex]::Matches([Uri]::UnescapeDataString($Matches[1]), "(\w+) eq '([^']*)'")) { $conds[$m.Groups[1].Value] = $m.Groups[2].Value } }
        $match = { param($o) foreach ($k in $conds.Keys) { if ([string]$o[$k] -ne $conds[$k]) { return $false } }; $true }
        $newId = { $store.NextId++; '{0:d8}-aaaa-bbbb-cccc-{1:d12}' -f $store.NextId, $store.NextId }
        if ($p -eq '/v1.0/servicePrincipals') {
            if ($Method -eq 'GET') { return (& $ok @{ value = @($store.ServicePrincipals | Where-Object { & $match $_ }) }) }
            if ($store.SpCreateFailures -gt 0 -and $Body.appId -notin '797f4846-ba00-4fd7-ba43-dac1f8f63013', 'e406a681-f3d4-42a8-90b6-c2b029497af1') { $store.SpCreateFailures--; return [pscustomobject]@{ Status = 400; Body = (ConvertTo-FakeJson @{ error = @{ message = 'The appId of the service principal does not reference a valid application object.' } }); Error = '' } }
            $sp = @{ id = "sp-$(& $newId)"; appId = $Body.appId; oauth2PermissionScopes = @(); appRoleAssignmentRequired = [bool]$Body.appRoleAssignmentRequired; Assigned = (New-Object System.Collections.ArrayList) }
            if ($Body.appId -eq '797f4846-ba00-4fd7-ba43-dac1f8f63013') { $sp.oauth2PermissionScopes = @(@{ id = 'scope-user_impersonation'; value = 'user_impersonation' }) }
            if ($Body.appId -eq 'e406a681-f3d4-42a8-90b6-c2b029497af1') { $sp.oauth2PermissionScopes = @(@{ id = 'scope-storage-user_impersonation'; value = 'user_impersonation' }) }
            [void]$store.ServicePrincipals.Add($sp); return (& $ok $sp 201)
        }
        if ($p -match '^/v1\.0/servicePrincipals/([^/]+)/appRoleAssignedTo$') {
            $sp = @($store.ServicePrincipals | Where-Object { $_.id -eq $Matches[1] })[0]
            if (-not $sp.ContainsKey('Assigned')) { $sp.Assigned = New-Object System.Collections.ArrayList }
            if ($Method -eq 'GET') { return (& $ok @{ value = @($sp.Assigned) }) }
            if ($store.AssignForbidden) { return $deny }
            $as = @{ id = "assign-$(& $newId)"; principalId = $Body.principalId; resourceId = $Body.resourceId; appRoleId = $Body.appRoleId }
            [void]$sp.Assigned.Add($as); return (& $ok $as 201)
        }
        if ($p -match '^/v1\.0/servicePrincipals/([^/]+)$' -and $Method -eq 'PATCH') {
            $sp = @($store.ServicePrincipals | Where-Object { $_.id -eq $Matches[1] })[0]
            foreach ($k in $Body.Keys) { $sp[$k] = $Body[$k] }
            return $none
        }
        if ($p -eq '/v1.0/applications') {
            if ($Method -eq 'GET') { return (& $ok @{ value = @($store.Apps | Where-Object { & $match $_ } | ForEach-Object { $x = @{}; foreach ($k in $_.Keys) { if ($k -notin 'owners', 'Definition', 'Federated', 'Patched') { $x[$k] = $_[$k] } }; $x }) }) }
            if ($store.AppForbidden) { return $deny }
            $id = & $newId
            $app = @{ id = "app-$id"; appId = $id; displayName = $Body.displayName; tags = @($Body.tags); publicClient = $Body.publicClient; signInAudience = $Body.signInAudience
                passwordCredentials = @(); keyCredentials = @(); identifierUris = @(); web = @{ redirectUris = @() }; spa = @{ redirectUris = @() }; owners = @('oid-fake'); Definition = $Body; Federated = @() }
            [void]$store.Apps.Add($app); return (& $ok @{ id = $app.id; appId = $app.appId; displayName = $app.displayName } 201)
        }
        if ($p -match '^/v1\.0/applications/([^/]+)/federatedIdentityCredentials$') { $id = $Matches[1]; $app = @($store.Apps | Where-Object { $_.id -eq $id })[0]; return (& $ok @{ value = @($app.Federated) }) }
        if ($p -match '^/v1\.0/applications/([^/]+)$' -and $Method -eq 'PATCH') {
            if ($store.AppForbidden) { return $deny }
            $id = $Matches[1]; $app = @($store.Apps | Where-Object { $_.id -eq $id })[0]
            $app.Definition = $Body; $app.tags = @($Body.tags); $app.publicClient = $Body.publicClient; $app.Patched = $true
            return $none
        }
        if ($p -eq '/v1.0/oauth2PermissionGrants') {
            # Like the real Graph (seen on a real tenant): oauth2PermissionGrants refuses a $filter that combines conditions with 'and'
            if ($Method -eq 'GET' -and $Path -match '\$filter=([^&]*)' -and [Uri]::UnescapeDataString($Matches[1]) -match '\sand\s') { return [pscustomobject]@{ Status = 400; Body = (ConvertTo-FakeJson @{ error = @{ code = 'Request_UnsupportedQuery'; message = 'Query filter is not supported.' } }); Error = '' } }
            if ($Method -eq 'GET') { return (& $ok @{ value = @($store.Grants | Where-Object { & $match $_ }) }) }
            if ($store.GrantForbidden) { return $deny }
            $g = @{ id = "grant-$(& $newId)"; clientId = $Body.clientId; consentType = $Body.consentType; principalId = $Body.principalId; resourceId = $Body.resourceId; scope = $Body.scope }
            [void]$store.Grants.Add($g); return (& $ok $g 201)
        }
        if ($p -match '^/v1\.0/oauth2PermissionGrants/([^/]+)$' -and $Method -eq 'PATCH') {
            $id = $Matches[1]; $g = @($store.Grants | Where-Object { $_.id -eq $id })[0]
            if ($store.GrantForbidden -and $g.clientId -ne 'sp-cli-0001') { return $deny }
            $g.scope = $Body.scope
            return $none
        }
        if ($p -match '^/v1\.0/sites/') {
            # site permissions (issue #96): only a token with Sites.FullControl.All may read or change them
            $scpNow = ''; try { $part = $Token.Split('.')[1].Replace('-', '+').Replace('_', '/'); $part = $part.PadRight($part.Length + (4 - $part.Length % 4) % 4, '='); $scpNow = [string]([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($part)) | ConvertFrom-Json).scp } catch { }
            $missing = [pscustomobject]@{ Status = 404; Body = (ConvertTo-FakeJson @{ error = @{ code = 'itemNotFound'; message = 'The resource could not be found.' } }); Error = '' }
            $denySite = [pscustomobject]@{ Status = 403; Body = (ConvertTo-FakeJson @{ error = @{ code = 'accessDenied'; message = 'Access denied' } }); Error = '' }
            if (@($scpNow -split ' ') -notcontains 'Sites.FullControl.All') { return $denySite }
            if ($p -match '^/v1\.0/sites/([^/:]+):/(sites|teams)/([^/]+)$' -and $Method -eq 'GET') {
                $key = ("$($Matches[1]):/$($Matches[2])/$($Matches[3])").ToLowerInvariant()
                if (-not $store.Sites.ContainsKey($key)) { return $missing }
                return (& $ok @{ id = $store.Sites[$key] })
            }
            $shape = { param($x) @{ id = $x.id; roles = @($x.roles); grantedToIdentitiesV2 = @(@{ application = @{ id = $x.AppId; displayName = 'AVDTune' } }); grantedToIdentities = @(@{ application = @{ id = $x.AppId; displayName = 'AVDTune' } }) } }
            if ($p -match '^/v1\.0/sites/([^/]+)/permissions$') {
                $siteId = $Matches[1]
                if (@($store.Sites.Values) -notcontains $siteId) { return $missing }
                if ($Method -eq 'GET') { return (& $ok @{ value = @($store.SitePermissions | Where-Object { $_.SiteId -eq $siteId } | ForEach-Object { & $shape $_ }) }) }
                if ($Method -eq 'POST') {
                    if ($store.SiteGrantForbidden) { return $denySite }
                    $store.NextId++
                    $new = @{ id = ('aTowaS50fG1zLnNwLmV4dHxmYWtl{0:d4}' -f $store.NextId); SiteId = $siteId; roles = @($Body.roles); AppId = [string]$Body.grantedToIdentities[0].application.id }
                    [void]$store.SitePermissions.Add($new); return (& $ok (& $shape $new) 201)
                }
            }
            if ($p -match '^/v1\.0/sites/([^/]+)/permissions/([^/]+)$') {
                $siteId = $Matches[1]; $permId = $Matches[2]
                $one = @($store.SitePermissions | Where-Object { $_.SiteId -eq $siteId -and $_.id -ceq $permId })
                if ($one.Count -eq 0) { return $missing }
                if ($Method -eq 'GET') { $o = & $shape $one[0]; if ($store.SiteReadBackOther) { $o.grantedToIdentitiesV2 = @(@{ application = @{ id = '99999999-8888-7777-6666-555555555555'; displayName = 'Other' } }); $o.grantedToIdentities = $o.grantedToIdentitiesV2 }; return (& $ok $o) }
                if ($Method -eq 'DELETE') { if ($store.SiteGrantForbidden) { return $denySite }; $store.SitePermissions.Remove($one[0]); return $none }
            }
        }
        [pscustomobject]@{ Status = 404; Body = $null; Error = "fake: no route for $Method $Path" }
    }.GetNewClosure()
    ConvertTo-AVDTuneFakeShared ([pscustomobject]$a)
}

# ------------------------------------------------------------------ Azure Resource Manager
# Seed: VmName, ResourceGroup, Snapshots (array of @{ Name; Created (datetime, local); Tags; State }), and for the readiness analysis Vm (hashtable: VmSize, DiskControllerType (omitted when empty), SecurityType, SecureBoot, VTpm,
#   HyperV (instanceView.hyperVGeneration, omitted when not given, as the real answer often has it), DiskHyperV (properties.hyperVGeneration of the OS disk, default V2, '' omits it),
#   ImageRefId, Nics = array of @{ Name; AccelNet }) and Galleries (hashtable image definition name -> @{ Features = array of @{ name; value }; Architecture; HyperV })
#   and Search for the gallery search: @{ Subscriptions = array of @{ Id; Name; State; Forbidden }; Galleries = array of @{ Sub; Rg; Name; Images = array of
#   @{ Name; Features; Architecture; HyperV; OsType; Versions = array of @{ Name; SourceVm; SourceId; OsDiskSourceId; Published } } }; ManagedImages = hashtable
#   image id -> source VM id; Paging = $true (every list comes in two pages) }. Without Search only this subscription and no gallery are listed.
# Issue #64 (what Azure knows about the VM): Net (@{ VNet; Subnet }, the subnet of the NICs; default vnet-example/snet-avd), StorageAccounts (array of @{ Name; Kind; Public; PrivateEndpoints; Auth }), DnsZones (array of zone names).
# Switches in .Store: Offline, ReadForbidden, WriteForbidden, DiskMissing, PollsUntilReady (GETs of a new snapshot that say Creating), CreateFails, Unauthorized, VmForbidden, NicForbidden, GalleryForbidden, StorageForbidden, DnsForbidden
# Issue #91 (snapshot housekeeping): DeleteForbidden (403 on DELETE of a snapshot); .Store.Deleted lists the IDs that were deleted (Azure answers 202, the snapshot is gone). Gallery versions may carry Regions (target regions).
# TamperGet ('Source', 'Name' or 'UniqueId'): the GET of ONE snapshot by ID (not the list) answers with another source disk, another name or another sourceUniqueId (#91 N2).
function New-AVDTuneFakeArm {
    param([hashtable]$Seed = @{})
    $rg = if ($Seed.ResourceGroup) { $Seed.ResourceGroup } else { 'rg-example' }
    $vm = if ($Seed.VmName) { $Seed.VmName } else { 'gm-test01' }
    $subId = $script:FakeSubscription
    $diskId = "/subscriptions/$script:FakeSubscription/resourceGroups/$rg/providers/Microsoft.Compute/disks/$vm`_osdisk"
    $store = @{ Offline = $false; ReadForbidden = $false; WriteForbidden = $false; DiskMissing = $false; PollsUntilReady = 1; CreateFails = $false; Unauthorized = $false
        DiskId = $diskId; ResourceGroup = $rg; Snapshots = @{}; DeleteForbidden = $false; Deleted = (New-Object System.Collections.ArrayList); TamperGet = ''; Polls = @{}; Log = (New-Object System.Collections.ArrayList); LastPut = $null; Location = 'westeurope'; NextLinkPage = $false; EvilLink = $false
        DiskUniqueId = $(if ($Seed.DiskUniqueId) { $Seed.DiskUniqueId } else { '' }); VmForbidden = $false; NicForbidden = $false; GalleryForbidden = $false; StorageForbidden = $false; DnsForbidden = $false
        Net = $(if ($Seed.Net) { $Seed.Net } else { @{ VNet = 'vnet-example'; Subnet = 'snet-avd' } }); StorageAccounts = @(@($Seed.StorageAccounts) | Where-Object { $_ }); DnsZones = @(@($Seed.DnsZones) | Where-Object { $_ }); VmSeed = $(if ($Seed.Vm) { $Seed.Vm } else { @{} }); Galleries = $(if ($Seed.Galleries) { $Seed.Galleries } else { @{} })
        Search = $(if ($Seed.Search) { $Seed.Search } else { @{ Subscriptions = @(@{ Id = $script:FakeSubscription; Name = 'Example subscription' }); Galleries = @() } }) }
    foreach ($s in @($Seed.Snapshots)) {
        if (-not $s) { continue }
        $id = "/subscriptions/$script:FakeSubscription/resourceGroups/$rg/providers/Microsoft.Compute/snapshots/$($s.Name)"
        $store.Snapshots[$id.ToLowerInvariant()] = @{ id = $id; name = $s.Name; location = $store.Location; tags = $s.Tags; sku = @{ name = $(if ($s.Sku) { $s.Sku } else { 'Standard_LRS' }) }
            properties =@{ timeCreated = ([datetime]$s.Created).ToUniversalTime().ToString('o'); provisioningState = $(if ($s.State) { $s.State } else { 'Succeeded' }); incremental = $true
                creationData = @{ createOption = 'Copy'; sourceResourceId = $(if ($s.Source) { $s.Source } else { $diskId }) } } }
        if ($s.SourceUniqueId) { $store.Snapshots[$id.ToLowerInvariant()].properties.creationData.sourceUniqueId = $s.SourceUniqueId }
        if ($null -ne $s.Percent) { $store.Snapshots[$id.ToLowerInvariant()].properties.completionPercent = $s.Percent }
        if ($s.AccessState) { $store.Snapshots[$id.ToLowerInvariant()].properties.snapshotAccessState = $s.AccessState }
    }
    $a = [ordered]@{ Kind = 'Fake'; Store = $store; Log = $store.Log }
    $a.Invoke = {
        param($Method, $Path, $Token, $Body)
        [void]$store.Log.Add("$Method $Path")
        if (-not $Token) { return [pscustomobject]@{ Status = 401; Body = $null; Error = 'no token' } }
        if ($store.Offline) { return [pscustomobject]@{ Status = 0; Body = $null; Error = 'The remote name could not be resolved: management.azure.com' } }
        if ($store.Unauthorized) { return [pscustomobject]@{ Status = 401; Body = $null; Error = 'expired' } }
        $p = $Path.Split('?')[0]
        $lower = $p.ToLowerInvariant()
        if ($Method -eq 'GET' -and $lower -eq $store.DiskId.ToLowerInvariant()) {
            if ($store.ReadForbidden) { return [pscustomobject]@{ Status = 403; Body = (ConvertTo-FakeJson @{ error = @{ code = 'AuthorizationFailed'; message = 'does not have authorization to perform action' } }); Error = '' } }
            if ($store.DiskMissing) { return [pscustomobject]@{ Status = 404; Body = $null; Error = 'not found' } }
            $dv = $store.VmSeed
            $diskProps = @{ securityProfile = @{ securityType = $(if ($dv.ContainsKey('SecurityType')) { $dv.SecurityType } else { 'TrustedLaunch' }) } }
            if ($store.ContainsKey('DiskUniqueId') -and $store.DiskUniqueId) { $diskProps.uniqueId = $store.DiskUniqueId }
            if ($dv.ContainsKey('DiskHyperV')) { if ($dv.DiskHyperV) { $diskProps.hyperVGeneration = $dv.DiskHyperV } } else { $diskProps.hyperVGeneration = 'V2' }
            return [pscustomobject]@{ Status = 200; Body = (ConvertTo-FakeJson @{ id = $store.DiskId; name = "$vm`_osdisk"; location = $store.Location; properties = $diskProps }); Error = '' }
        }
        if ($Method -eq 'GET' -and $lower -eq "/subscriptions/$subId/resourcegroups/$rg/providers/microsoft.compute/virtualmachines/$vm".ToLowerInvariant()) {
            if ($store.ReadForbidden -or $store.VmForbidden) { return [pscustomobject]@{ Status = 403; Body = (ConvertTo-FakeJson @{ error = @{ code = 'AuthorizationFailed'; message = 'does not have authorization to perform action Microsoft.Compute/virtualMachines/read' } }); Error = '' } }
            $s = $store.VmSeed
            $nics = @(if ($s.Nics) { $s.Nics } else { @(@{ Name = 'nic1'; AccelNet = $true }) })
            $storage = @{ imageReference = @{ id = $(if ($s.ImageRefId) { $s.ImageRefId } else { '' }) } }
            if ($s.ContainsKey('DiskControllerType')) { if ($s.DiskControllerType) { $storage.diskControllerType = $s.DiskControllerType } } else { $storage.diskControllerType = 'NVMe' }
            $security = @{ securityType = $(if ($s.ContainsKey('SecurityType')) { $s.SecurityType } else { 'TrustedLaunch' }); uefiSettings = @{ secureBootEnabled = $(if ($s.ContainsKey('SecureBoot')) { $s.SecureBoot } else { $true }); vTpmEnabled = $(if ($s.ContainsKey('VTpm')) { $s.VTpm } else { $true }) } }
            $body = @{ id = $p; name = $vm; location = $store.Location; properties = @{
                    hardwareProfile = @{ vmSize = $(if ($s.VmSize) { $s.VmSize } else { 'Standard_D4s_v6' }) }; storageProfile = $storage; securityProfile = $security
                    networkProfile = @{ networkInterfaces = @($nics | ForEach-Object { @{ id = "/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.Network/networkInterfaces/$($_.Name)" } }) }
                    instanceView = $(if ($s.HyperV) { @{ hyperVGeneration = $s.HyperV } } else { @{ computerName = $vm } }) } }
            return [pscustomobject]@{ Status = 200; Body = (ConvertTo-FakeJson $body); Error = '' }
        }
        if ($Method -eq 'GET' -and $lower -like '*/providers/microsoft.network/networkinterfaces/*') {
            if ($store.ReadForbidden -or $store.NicForbidden) { return [pscustomobject]@{ Status = 403; Body = $null; Error = 'forbidden' } }
            $nicName = $p.Substring($p.LastIndexOf('/') + 1)
            $s = $store.VmSeed
            $nics = @(if ($s.Nics) { $s.Nics } else { @(@{ Name = 'nic1'; AccelNet = $true }) })
            $hit = @($nics | Where-Object { $_.Name -eq $nicName })
            if ($hit.Count -eq 0) { return [pscustomobject]@{ Status = 404; Body = $null; Error = 'not found' } }
            $subnetId = "/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.Network/virtualNetworks/$($store.Net.VNet)/subnets/$($store.Net.Subnet)"
            return [pscustomobject]@{ Status = 200; Body = (ConvertTo-FakeJson @{ id = $p; name = $nicName; properties = @{ enableAcceleratedNetworking = [bool]$hit[0].AccelNet; ipConfigurations = @(@{ name = 'ipconfig1'; properties = @{ primary = $true; subnet = @{ id = $subnetId } } }) } }); Error = '' }
        }
        if ($Method -eq 'GET' -and $lower -eq "/subscriptions/$subId/resourcegroups/$rg/providers/microsoft.storage/storageaccounts") {
            if ($store.ReadForbidden -or $store.StorageForbidden) { return [pscustomobject]@{ Status = 403; Body = (ConvertTo-FakeJson @{ error = @{ code = 'AuthorizationFailed'; message = 'does not have authorization to perform action Microsoft.Storage/storageAccounts/read' } }); Error = '' } }
            $items = @(foreach ($acct in $store.StorageAccounts) {
                    $pecs = @(for ($i = 0; $i -lt [int]$acct.PrivateEndpoints; $i++) { @{ id = "pec$i" } })
                    $props = @{ publicNetworkAccess = $(if ($acct.Public) { $acct.Public } else { 'Enabled' }); privateEndpointConnections = $pecs }
                    if ($acct.Auth) { $props.azureFilesIdentityBasedAuthentication = @{ directoryServiceOptions = $acct.Auth } }
                    @{ id = "$p/$($acct.Name)"; name = $acct.Name; kind = $(if ($acct.Kind) { $acct.Kind } else { 'FileStorage' }); properties = $props } })
            return [pscustomobject]@{ Status = 200; Body = (ConvertTo-FakeJson @{ value = $items }); Error = '' }
        }
        if ($Method -eq 'GET' -and $lower -eq "/subscriptions/$subId/resourcegroups/$rg/providers/microsoft.network/privatednszones") {
            if ($store.ReadForbidden -or $store.DnsForbidden) { return [pscustomobject]@{ Status = 403; Body = $null; Error = 'forbidden' } }
            return [pscustomobject]@{ Status = 200; Body = (ConvertTo-FakeJson @{ value = @($store.DnsZones | ForEach-Object { @{ id = "$p/$_"; name = $_ } }) }); Error = '' }
        }
        # ---- gallery search (Search seed): subscriptions, galleries, image definitions, versions, managed images; Paging splits every list in two pages
        $search = $store.Search
        $page = {
            param($items)
            $all = @($items | Where-Object { $_ })
            if (-not $search.Paging -or $all.Count -lt 2) { return @{ value = $all } }
            if ($Path -like '*fakepage=2*') { return @{ value = @($all | Select-Object -Skip 1) } }
            @{ value = @($all | Select-Object -First 1); nextLink = "https://management.azure.com$Path&fakepage=2" }
        }
        $galleryOf = { param($g) "/subscriptions/$($g.Sub)/resourceGroups/$($g.Rg)/providers/Microsoft.Compute/galleries/$($g.Name)" }
        $searchImage = { param($galleryPath, $imageName) foreach ($g in @($search.Galleries)) { if ((& $galleryOf $g).ToLowerInvariant() -eq $galleryPath) { foreach ($im in @($g.Images)) { if ($im -and (-not $imageName -or ([string]$im.Name).ToLowerInvariant() -eq $imageName)) { $im } } } } }
        $imageBody = { param($id, $im) @{ id = $id; name = $im.Name; properties = @{ features = @($im.Features | Where-Object { $_ }); architecture = $(if ($im.Architecture) { $im.Architecture } else { 'x64' }); hyperVGeneration = $(if ($im.HyperV) { $im.HyperV } else { 'V2' }); osType = $(if ($im.OsType) { $im.OsType } else { 'Windows' }) } } }
        $forbidden = { param($action) [pscustomobject]@{ Status = 403; Body = (ConvertTo-FakeJson @{ error = @{ code = 'AuthorizationFailed'; message = "does not have authorization to perform action $action" } }); Error = '' } }
        if ($Method -eq 'GET' -and $lower -eq '/subscriptions') {
            if ($store.ReadForbidden) { return (& $forbidden 'Microsoft.Resources/subscriptions/read') }
            $subs = @($search.Subscriptions | Where-Object { $_ } | ForEach-Object { @{ id = "/subscriptions/$($_.Id)"; subscriptionId = $_.Id; displayName = $_.Name; state = $(if ($_.State) { $_.State } else { 'Enabled' }) } })
            return [pscustomobject]@{ Status = 200; Body = (ConvertTo-FakeJson (& $page $subs)); Error = '' }
        }
        if ($Method -eq 'GET' -and $lower -match '^/subscriptions/([0-9a-f-]{36})/providers/microsoft\.compute/galleries$') {
            $sid = $Matches[1]
            $one = @($search.Subscriptions | Where-Object { $_ -and ([string]$_.Id).ToLowerInvariant() -eq $sid })
            if ($store.ReadForbidden -or $store.GalleryForbidden -or ($one.Count -gt 0 -and $one[0].Forbidden)) { return (& $forbidden 'Microsoft.Compute/galleries/read') }
            $gs = @(@($search.Galleries) | Where-Object { $_ -and ([string]$_.Sub).ToLowerInvariant() -eq $sid } | ForEach-Object { @{ id = (& $galleryOf $_); name = $_.Name; location = $store.Location } })
            return [pscustomobject]@{ Status = 200; Body = (ConvertTo-FakeJson (& $page $gs)); Error = '' }
        }
        if ($Method -eq 'GET' -and $lower -match '^(/subscriptions/[^/]+/resourcegroups/[^/]+/providers/microsoft\.compute/galleries/[^/]+)/images$') {
            $gp = $Matches[1]
            if ($store.ReadForbidden -or $store.GalleryForbidden) { return (& $forbidden 'Microsoft.Compute/galleries/images/read') }
            $real = @(@($search.Galleries) | Where-Object { $_ -and (& $galleryOf $_).ToLowerInvariant() -eq $gp })
            if ($real.Count -eq 0) { return [pscustomobject]@{ Status = 404; Body = $null; Error = 'not found' } }
            $ims = @(& $searchImage $gp '' | ForEach-Object { & $imageBody "$(& $galleryOf $real[0])/images/$($_.Name)" $_ })
            return [pscustomobject]@{ Status = 200; Body = (ConvertTo-FakeJson (& $page $ims)); Error = '' }
        }
        if ($Method -eq 'GET' -and $lower -match '^(/subscriptions/[^/]+/resourcegroups/[^/]+/providers/microsoft\.compute/galleries/[^/]+)/images/([^/]+)/versions$') {
            $gp = $Matches[1]; $in = $Matches[2]
            if ($store.ReadForbidden -or $store.GalleryForbidden) { return (& $forbidden 'Microsoft.Compute/galleries/images/versions/read') }
            $im = @(& $searchImage $gp $in)
            if ($im.Count -eq 0) { return [pscustomobject]@{ Status = 404; Body = $null; Error = 'not found' } }
            $vs = @(@($im[0].Versions) | Where-Object { $_ } | ForEach-Object {
                    $src = @{}; if ($_.SourceVm) { $src.virtualMachineId = $_.SourceVm }; if ($_.SourceId) { $src.id = $_.SourceId }
                    $sp = @{ source = $src }; if ($_.OsDiskSourceId) { $sp.osDiskImage = @{ source = @{ id = $_.OsDiskSourceId } } }
                    $published = if ($_.Published) { ([datetime]$_.Published).ToUniversalTime().ToString('o') } else { '2026-11-01T00:00:00Z' }
                    $pp = @{ publishedDate = $published }; if ($_.Regions) { $pp.targetRegions = @($_.Regions | ForEach-Object { @{ name = $_ } }) }
                    @{ id = "$p/$($_.Name)"; name = $_.Name; properties = @{ provisioningState = 'Succeeded'; storageProfile = $sp; publishingProfile = $pp } } })
            return [pscustomobject]@{ Status = 200; Body = (ConvertTo-FakeJson (& $page $vs)); Error = '' }
        }
        if ($Method -eq 'GET' -and $lower -match '^/subscriptions/[^/]+/resourcegroups/[^/]+/providers/microsoft\.compute/images/[^/]+$') {
            $hit = $null
            if ($search.ManagedImages) { foreach ($k in @($search.ManagedImages.Keys)) { if (([string]$k).ToLowerInvariant() -eq $lower) { $hit = $search.ManagedImages[$k] } } }
            if (-not $hit) { return [pscustomobject]@{ Status = 404; Body = $null; Error = 'not found' } }
            return [pscustomobject]@{ Status = 200; Body = (ConvertTo-FakeJson @{ id = $p; name = $p.Substring($p.LastIndexOf('/') + 1); properties = @{ sourceVirtualMachine = @{ id = $hit } } }); Error = '' }
        }
        if ($Method -eq 'GET' -and $lower -match '^(/subscriptions/[^/]+/resourcegroups/[^/]+/providers/microsoft\.compute/galleries/[^/]+)/images/([^/]+)$') {
            $im = @(& $searchImage $Matches[1] $Matches[2])
            if ($im.Count -gt 0) {
                if ($store.ReadForbidden -or $store.GalleryForbidden) { return (& $forbidden 'Microsoft.Compute/galleries/images/read') }
                return [pscustomobject]@{ Status = 200; Body = (ConvertTo-FakeJson (& $imageBody $p $im[0])); Error = '' }
            }
        }
        if ($Method -eq 'GET' -and $lower -like '*/providers/microsoft.compute/galleries/*/images/*') {
            if ($store.ReadForbidden -or $store.GalleryForbidden) { return [pscustomobject]@{ Status = 403; Body = $null; Error = 'forbidden' } }
            $defName = $p.Substring($p.LastIndexOf('/') + 1)
            if (-not $store.Galleries.ContainsKey($defName)) { return [pscustomobject]@{ Status = 404; Body = $null; Error = 'not found' } }
            $g = $store.Galleries[$defName]
            return [pscustomobject]@{ Status = 200; Body = (ConvertTo-FakeJson @{ id = $p; name = $defName; properties = @{ features = @($g.Features); architecture = $(if ($g.Architecture) { $g.Architecture } else { 'x64' }); hyperVGeneration = $(if ($g.HyperV) { $g.HyperV } else { 'V2' }); osType = 'Windows' } }); Error = '' }
        }
        if ($Method -eq 'GET' -and $lower -like '*/providers/microsoft.compute/snapshots') {
            if ($store.ReadForbidden) { return [pscustomobject]@{ Status = 403; Body = $null; Error = 'forbidden' } }
            $all = @($store.Snapshots.Values | ForEach-Object { $_ })
            # nextLink: followed on the ARM host only (a link to another host must be refused)
            if ($store.EvilLink -and $Path -notlike '*page2*') { return [pscustomobject]@{ Status = 200; Body = (ConvertTo-FakeJson @{ value = @(); nextLink = 'https://evil.example/x' }); Error = '' } }
            if ($store.NextLinkPage -and $Path -notlike '*page2*') { return [pscustomobject]@{ Status = 200; Body = (ConvertTo-FakeJson @{ value = @(); nextLink = "https://management.azure.com$p`?api-version=2023-10-02&page2=1" }); Error = '' } }
            return [pscustomobject]@{ Status = 200; Body = (ConvertTo-FakeJson @{ value = $all }); Error = '' }
        }
        if ($lower -like '*/providers/microsoft.compute/snapshots/*') {
            if ($Method -eq 'DELETE') {
                if ($store.DeleteForbidden) { return [pscustomobject]@{ Status = 403; Body = (ConvertTo-FakeJson @{ error = @{ code = 'AuthorizationFailed'; message = 'does not have authorization to perform action Microsoft.Compute/snapshots/delete' } }); Error = '' } }
                if ($store.Snapshots.ContainsKey($lower)) { $store.Snapshots.Remove($lower); [void]$store.Deleted.Add($p); return [pscustomobject]@{ Status = 202; Body = $null; Error = '' } }
                return [pscustomobject]@{ Status = 204; Body = $null; Error = '' }
            }
            if ($Method -eq 'PUT') {
                if ($store.WriteForbidden) { return [pscustomobject]@{ Status = 403; Body = (ConvertTo-FakeJson @{ error = @{ code = 'AuthorizationFailed'; message = 'does not have authorization to perform action Microsoft.Compute/snapshots/write' } }); Error = '' } }
                $store.LastPut = $Body
                # Like Azure: an incremental snapshot must have the SKU of the existing incremental snapshots of the same disk (400 otherwise)
                $wantSku = [string]$Body.sku.name; $src = [string]$Body.properties.creationData.sourceResourceId
                $other = @($store.Snapshots.Values | Where-Object { $_.properties.incremental -and [string]$_.properties.creationData.sourceResourceId -ieq $src -and $_.sku -and [string]$_.sku.name -ne $wantSku } | Select-Object -First 1)
                if ($Body.properties.incremental -and $other.Count -gt 0) {
                    return [pscustomobject]@{ Status = 400; Body = (ConvertTo-FakeJson @{ error = @{ code = 'BadRequest'; message = "Requested Sku '$wantSku' for incremental snapshot of disk '$src' does not match the Sku '$($other[0].sku.name)' for existing incremental snapshots of the disk." } }); Error = '' }
                }
                $name = $p.Substring($p.LastIndexOf('/') + 1)
                $entry = @{ id = $p; name = $name; location = $Body.location; tags = $Body.tags; sku = @{ name = $wantSku }; properties =@{ timeCreated = (Get-Date).ToUniversalTime().ToString('o'); provisioningState = 'Creating'; incremental = [bool]$Body.properties.incremental; creationData = $Body.properties.creationData; completionPercent = 0 } }
                $store.Snapshots[$lower] = $entry; $store.Polls[$lower] = 0
                return [pscustomobject]@{ Status = 201; Body = (ConvertTo-FakeJson $entry); Error = '' }
            }
            if ($Method -eq 'GET') {
                if ($store.ReadForbidden) { return [pscustomobject]@{ Status = 403; Body = $null; Error = 'forbidden' } }
                if (-not $store.Snapshots.ContainsKey($lower)) { return [pscustomobject]@{ Status = 404; Body = $null; Error = 'not found' } }
                $e = $store.Snapshots[$lower]
                if ($e.properties.provisioningState -eq 'Creating') {
                    $store.Polls[$lower]++
                    if ($store.CreateFails) { $e.properties.provisioningState = 'Failed' }
                    elseif ($store.Polls[$lower] -gt $store.PollsUntilReady) { $e.properties.provisioningState = 'Succeeded'; $e.properties.completionPercent = 100 } else { $e.properties.completionPercent = 40 }
                }
                $out = ConvertTo-FakeJson $e
                switch ([string]$store.TamperGet) {
                    'Source' { $out.properties.creationData.sourceResourceId = $store.DiskId + '-other' }
                    'Name' { $out.name = "$($out.name)-other" }
                    'UniqueId' { $out.properties.creationData | Add-Member -NotePropertyName sourceUniqueId -NotePropertyValue '99999999-0000-0000-0000-000000000001' -Force }
                }
                return [pscustomobject]@{ Status = 200; Body = $out; Error = '' }
            }
        }
        [pscustomobject]@{ Status = 404; Body = $null; Error = "fake: no route for $Method $p" }
    }.GetNewClosure()
    ConvertTo-AVDTuneFakeShared ([pscustomobject]$a)
}

# ------------------------------------------------------------------ LDAP
# Switches in .Store: Servers (hashtable name -> @{ Ldaps = $true/$false; Ldap389 = $true/$false; Cert = @{ Sha256; Thumbprint; Subject; Issuer }; BadPassword = $false })
# .Opened records the options of every bind (the checks assert on them); .Log has probes, binds and searches (never the password)
function New-AVDTuneFakeLdap {
    param([hashtable]$Seed = @{})
    $sid = {
        param([int]$Rid)
        $bytes = New-Object byte[] 28
        $bytes[0] = 1; $bytes[1] = 5; $bytes[7] = 5
        [BitConverter]::GetBytes([int]21).CopyTo($bytes, 8)
        [BitConverter]::GetBytes([uint32]1111111111).CopyTo($bytes, 12); [BitConverter]::GetBytes([uint32]2222222222).CopyTo($bytes, 16)
        [BitConverter]::GetBytes([uint32]333333333).CopyTo($bytes, 20); [BitConverter]::GetBytes($Rid).CopyTo($bytes, 24)
        , $bytes
    }
    $domSid = { $b = New-Object byte[] 24; $b[0] = 1; $b[1] = 4; $b[7] = 5; [BitConverter]::GetBytes([int]21).CopyTo($b, 8); [BitConverter]::GetBytes([uint32]1111111111).CopyTo($b, 12); [BitConverter]::GetBytes([uint32]2222222222).CopyTo($b, 16); [BitConverter]::GetBytes([uint32]333333333).CopyTo($b, 20); , $b }
    $cert = { param($n) @{ Sha256 = ('{0:X2}' -f $n) * 32; Thumbprint = ('{0:X2}' -f $n) * 20; Subject = 'CN=dc1.example.test'; Issuer = 'CN=Example Test CA'; NotBefore = '2026-01-01T00:00:00Z'; NotAfter = '2027-01-01T00:00:00Z'; ChainOk = $true; ChainStatus = 'trusted by this computer'; NameMatches = $false } }
    $dn = 'DC=example,DC=test'
    $cfg = "CN=Configuration,$dn"
    $entry = { param($dnName, $attrs) $t = New-Object 'System.Collections.Hashtable' $attrs, ([StringComparer]::OrdinalIgnoreCase); [pscustomobject]@{ Dn = $dnName; Attributes = $t } }
    $store = @{
        Servers = @{ '10.0.0.10' = @{ Ldaps = $true; Ldap389 = $true; Cert = (& $cert ([int]0xAB)); BadPassword = $false } }
        Opened = (New-Object System.Collections.ArrayList); Log = (New-Object System.Collections.ArrayList)
        Entries = @{
            root = (& $entry '' @{ defaultNamingContext = @($dn); rootDomainNamingContext = @($dn); configurationNamingContext = @($cfg); schemaNamingContext = @("CN=Schema,$cfg"); dnsHostName = @('dc1.example.test')
                    serverName = @("CN=DC1,CN=Servers,CN=Default-First-Site-Name,CN=Sites,$cfg"); domainFunctionality = @('7'); forestFunctionality = @('7'); domainControllerFunctionality = @('7') })
            domain = (& $entry $dn @{ objectSid = @(, (& $domSid)) })
            netbios = (& $entry "CN=EXAMPLE,CN=Partitions,$cfg" @{ nETBIOSName = @('EXAMPLE') })
            ous = @(
                (& $entry "OU=Corp,$dn" @{ name = @('Corp'); distinguishedName = @("OU=Corp,$dn") })
                (& $entry "OU=AVD,OU=Corp,$dn" @{ name = @('AVD'); distinguishedName = @("OU=AVD,OU=Corp,$dn") })
                (& $entry "OU=Groups,OU=AVD,OU=Corp,$dn" @{ name = @('Groups'); distinguishedName = @("OU=Groups,OU=AVD,OU=Corp,$dn") })
                (& $entry "OU=Servers,$dn" @{ name = @('Servers'); distinguishedName = @("OU=Servers,$dn") }))
            groups = @(
                (& $entry "CN=AVD-Users,OU=Groups,OU=AVD,OU=Corp,$dn" @{ name = @('AVD-Users'); distinguishedName = @("CN=AVD-Users,OU=Groups,OU=AVD,OU=Corp,$dn"); objectSid = @(, (& $sid 1104)); groupType = @('-2147483646'); description = @('AVD users') })
                (& $entry "CN=AVD-Admins,OU=Groups,OU=AVD,OU=Corp,$dn" @{ name = @('AVD-Admins'); distinguishedName = @("CN=AVD-Admins,OU=Groups,OU=AVD,OU=Corp,$dn"); objectSid = @(, (& $sid 1105)); groupType = @('-2147483646') })
                (& $entry "CN=Mail-List,OU=Groups,OU=AVD,OU=Corp,$dn" @{ name = @('Mail-List'); distinguishedName = @("CN=Mail-List,OU=Groups,OU=AVD,OU=Corp,$dn"); objectSid = @(, (& $sid 1200)); groupType = @('2') }))
            # print queues published in AD (printers page, #86): two of print1, one of print2, one with a name that is not a host name (left out)
            printQueues = @(
                (& $entry "CN=PRINT1-F1-Color,CN=PRINT1,OU=Servers,$dn" @{ serverName = @('print1.example.test'); shortServerName = @('PRINT1'); printerName = @('Floor 1 Color') })
                (& $entry "CN=PRINT1-Labels,CN=PRINT1,OU=Servers,$dn" @{ serverName = @('print1.example.test'); shortServerName = @('PRINT1'); printerName = @('Label Printer') })
                (& $entry "CN=PRINT2-A,CN=PRINT2,OU=Servers,$dn" @{ serverName = @('print2.example.test'); shortServerName = @('PRINT2'); printerName = @('A') })
                (& $entry "CN=BAD-Q,CN=BAD,OU=Servers,$dn" @{ serverName = @('\\bad\share'); printerName = @('Q') }))
        }
    }
    foreach ($k in $Seed.Keys) { $store[$k] = $Seed[$k] }
    $a = [ordered]@{ Kind = 'Fake'; Store = $store; Log = $store.Log; Opened = $store.Opened }
    $a.Probe = {
        param($Server, $Port)
        [void]$store.Log.Add("Probe $Server`:$Port")
        $s = $store.Servers[$Server]
        if (-not $s -or $Port -ne 636 -or -not $s.Ldaps) { return [pscustomobject]@{ Ok = $false; Error = 'connection refused'; Certificate = $null } }
        [pscustomobject]@{ Ok = $true; Error = ''; Certificate = [pscustomobject]$s.Cert }
    }.GetNewClosure()
    $a.Open = {
        param($Options, $User, $Password)
        # The real adapter asserts too; the fake records exactly what it was given so the checks can assert on it
        [void]$store.Opened.Add($Options)
        [void]$store.Log.Add("Open $($Options.Server):$($Options.Port) as $User")
        $s = $store.Servers[$Options.Server]
        if (-not $s) { throw 'The LDAP server is unavailable.' }
        if ($Options.Port -eq 389 -and -not $s.Ldap389) { throw 'The LDAP server is unavailable.' }
        if ($s.BadPassword) { throw 'The supplied credential is invalid.' }
        [pscustomobject]@{ Server = $Options.Server; Open = $true }
    }.GetNewClosure()
    $a.Search = {
        param($Conn, $BaseDn, $Filter, $Scope, $Attributes)
        [void]$store.Log.Add("Search $Scope $BaseDn $Filter")
        if ($store.Entries.ContainsKey('Fail') -and $Filter -like "*$($store.Entries.Fail)*") { throw 'The server returned an error.' }
        if ($BaseDn -eq '' -and $Scope -eq 'Base') { return @($store.Entries.root) }
        if ($BaseDn -eq $dn -and $Scope -eq 'Base') { if ($store.Entries.ContainsKey('DomainSidMissing')) { return @() }; return @($store.Entries.domain) }
        if ($Filter -like '*crossRef*') { return @($store.Entries.netbios) }
        if ($Filter -like '*organizationalUnit*') { return @($store.Entries.ous) }
        if ($Filter -like '*objectClass=group*') { return @($store.Entries.groups) }
        if ($Filter -like '*printQueue*') { return @($store.Entries.printQueues) }
        @()
    }.GetNewClosure()
    $a.Close = { param($Conn) [void]$store.Log.Add('Close') }.GetNewClosure()
    ConvertTo-AVDTuneFakeShared ([pscustomobject]$a)
}
