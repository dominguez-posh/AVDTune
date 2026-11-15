# Fakes for the external services of the start sequence: sign-in (Auth), Azure Resource Manager (Arm), LDAP (Ldap). Same members as the real
# adapters (Modules\AVDTune.Session.psm1, AVDTune.Snapshot.psm1, AVDTune.Directory.psm1), kept in memory. No network, no tenant, no domain controller.
# Dot-source this file, then: $auth = New-AVDTuneFakeAuth; $arm = New-AVDTuneFakeArm; $ldap = New-AVDTuneFakeLdap
# Every fake has .Store (state, switches for the error paths) and .Log (what was asked; never tokens or passwords).
# All names, IDs and addresses below are made up.

$script:FakeTenant = '11111111-2222-3333-4444-555555555555'
$script:FakeSubscription = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'

function ConvertTo-FakeBase64Url([string]$Text) { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text)).TrimEnd('=').Replace('+', '-').Replace('/', '_') }

function ConvertTo-FakeJson($Object) { $Object | ConvertTo-Json -Depth 10 | ConvertFrom-Json }   # what a real answer looks like: parsed JSON

function New-FakeJwt([hashtable]$Claims) { (ConvertTo-FakeBase64Url '{"alg":"none"}') + '.' + (ConvertTo-FakeBase64Url ($Claims | ConvertTo-Json -Compress)) + '.fakesignature' }

# ------------------------------------------------------------------ sign-in
# Switches in .Store: Offline, Cancel, ConsentMissing (array of audiences: 'Arm', 'Sites', 'Graph'), WrongTenant, ExpiresIn (seconds), NoRefreshToken
function New-AVDTuneFakeAuth {
    param([hashtable]$Seed = @{})
    $store = @{ Offline = $false; Cancel = $false; ConsentMissing = @(); WrongTenant = $false; ExpiresIn = 3600; NoRefreshToken = $false
        Upn = 'admin.example@contoso.example'; Name = 'Alex Example'; Tenant = $script:FakeTenant; Log = (New-Object System.Collections.ArrayList); Counter = 0 }
    foreach ($k in $Seed.Keys) { $store[$k] = $Seed[$k] }
    $make = {
        param($Scopes)
        $urls = @($Scopes)
        $resource = ($urls[0] -replace '^(https://[^/]+)/.*$', '$1')
        $names = @($urls | ForEach-Object { $_ -replace '^https://[^/]+/', '' })
        $audience = if ($resource -eq 'https://graph.microsoft.com') { 'https://graph.microsoft.com' } else { $resource }
        $store.Counter++
        $claims = @{ aud = $audience; tid = $(if ($store.WrongTenant) { '99999999-0000-0000-0000-000000000000' } else { $store.Tenant }); upn = $store.Upn; name = $store.Name; oid = 'oid-fake'; scp = ($names -join ' '); n = $store.Counter }
        [pscustomobject]@{ access_token = (New-FakeJwt $claims); refresh_token = $(if ($store.NoRefreshToken) { $null } else { "fake-refresh-$($store.Counter)" }); expires_in = $store.ExpiresIn; scope = ($names -join ' ') }
    }.GetNewClosure()
    $a = [ordered]@{ Kind = 'Fake'; Store = $store; Log = $store.Log }
    $a.SignIn = {
        param($TenantId, $ClientId, $Scopes)
        [void]$store.Log.Add("SignIn tenant=$TenantId scopes=$(@($Scopes) -join ',')")
        if ($store.Offline) { throw 'The remote name could not be resolved: login.microsoftonline.com' }
        if ($store.Cancel) { throw 'Sign-in cancelled.' }
        & $make $Scopes
    }.GetNewClosure()
    $a.Refresh = {
        param($TenantId, $ClientId, $RefreshToken, $Scopes)
        [void]$store.Log.Add("Refresh scopes=$(@($Scopes) -join ',') hasRefreshToken=$([bool]$RefreshToken)")
        if ($store.Offline) { throw 'Unable to connect to the remote server' }
        $res = ($Scopes[0] -replace '^https://([^/]+)/.*$', '$1')
        $audience = if ($res -like 'graph*') { if ($Scopes[0] -like '*Sites.Selected') { 'Sites' } else { 'Graph' } } else { 'Arm' }
        if ($audience -in @($store.ConsentMissing)) { throw "Token request failed: AADSTS65001: The user or administrator has not consented to use the application (audience $audience)." }
        & $make $Scopes
    }.GetNewClosure()
    [pscustomobject]$a
}

# ------------------------------------------------------------------ Azure Resource Manager
# Seed: VmName, ResourceGroup, Snapshots (array of @{ Name; Created (datetime, local); Tags; State })
# Switches in .Store: Offline, ReadForbidden, WriteForbidden, DiskMissing, PollsUntilReady (GETs of a new snapshot that say Creating), CreateFails, Unauthorized
function New-AVDTuneFakeArm {
    param([hashtable]$Seed = @{})
    $rg = if ($Seed.ResourceGroup) { $Seed.ResourceGroup } else { 'rg-example' }
    $vm = if ($Seed.VmName) { $Seed.VmName } else { 'gm-test01' }
    $diskId = "/subscriptions/$script:FakeSubscription/resourceGroups/$rg/providers/Microsoft.Compute/disks/$vm`_osdisk"
    $store = @{ Offline = $false; ReadForbidden = $false; WriteForbidden = $false; DiskMissing = $false; PollsUntilReady = 1; CreateFails = $false; Unauthorized = $false
        DiskId = $diskId; ResourceGroup = $rg; Snapshots = @{}; Polls = @{}; Log = (New-Object System.Collections.ArrayList); LastPut = $null; Location = 'westeurope'; NextLinkPage = $false; EvilLink = $false }
    foreach ($s in @($Seed.Snapshots)) {
        if (-not $s) { continue }
        $id = "/subscriptions/$script:FakeSubscription/resourceGroups/$rg/providers/Microsoft.Compute/snapshots/$($s.Name)"
        $store.Snapshots[$id.ToLowerInvariant()] = @{ id = $id; name = $s.Name; location = $store.Location; tags = $s.Tags
            properties = @{ timeCreated = ([datetime]$s.Created).ToUniversalTime().ToString('o'); provisioningState = $(if ($s.State) { $s.State } else { 'Succeeded' }); incremental = $true
                creationData = @{ createOption = 'Copy'; sourceResourceId = $(if ($s.Source) { $s.Source } else { $diskId }) } } }
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
            return [pscustomobject]@{ Status = 200; Body = (ConvertTo-FakeJson @{ id = $store.DiskId; name = "$vm`_osdisk"; location = $store.Location }); Error = '' }
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
            if ($Method -eq 'PUT') {
                if ($store.WriteForbidden) { return [pscustomobject]@{ Status = 403; Body = (ConvertTo-FakeJson @{ error = @{ code = 'AuthorizationFailed'; message = 'does not have authorization to perform action Microsoft.Compute/snapshots/write' } }); Error = '' } }
                $store.LastPut = $Body
                $name = $p.Substring($p.LastIndexOf('/') + 1)
                $entry = @{ id = $p; name = $name; location = $Body.location; tags = $Body.tags; properties = @{ timeCreated = (Get-Date).ToUniversalTime().ToString('o'); provisioningState = 'Creating'; incremental = [bool]$Body.properties.incremental; creationData = $Body.properties.creationData; completionPercent = 0 } }
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
                return [pscustomobject]@{ Status = 200; Body = (ConvertTo-FakeJson $e); Error = '' }
            }
        }
        [pscustomobject]@{ Status = 404; Body = $null; Error = "fake: no route for $Method $p" }
    }.GetNewClosure()
    [pscustomobject]$a
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
    $cert = { param($n) @{ Sha256 = ('{0:X2}' -f $n) * 32; Thumbprint = ('{0:X2}' -f $n) * 20; Subject = 'CN=dc1.example.test'; Issuer = 'CN=Example Test CA'; NotBefore = '2026-01-01T00:00:00Z'; NotAfter = '2027-01-01T00:00:00Z' } }
    $dn = 'DC=example,DC=test'
    $cfg = "CN=Configuration,$dn"
    $entry = { param($dnName, $attrs) $t = New-Object 'System.Collections.Hashtable' $attrs, ([StringComparer]::OrdinalIgnoreCase); [pscustomobject]@{ Dn = $dnName; Attributes = $t } }
    $store = @{
        Servers = @{ '10.0.0.10' = @{ Ldaps = $true; Ldap389 = $true; Cert = (& $cert ([int]0xAB)); BadPassword = $false } }
        Opened = (New-Object System.Collections.ArrayList); Log = (New-Object System.Collections.ArrayList)
        Entries = @{
            root = (& $entry '' @{ defaultNamingContext = @($dn); rootDomainNamingContext = @($dn); configurationNamingContext = @($cfg); schemaNamingContext = @("CN=Schema,$cfg"); dnsHostName = @('dc1.example.test')
                    serverName = @("CN=DC1,CN=Servers,CN=Default-First-Site-Name,CN=Sites,$cfg"); domainFunctionality = @('7'); forestFunctionality = @('7'); domainControllerFunctionality = @('7') })
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
        if ($Filter -like '*crossRef*') { return @($store.Entries.netbios) }
        if ($Filter -like '*organizationalUnit*') { return @($store.Entries.ous) }
        if ($Filter -like '*objectClass=group*') { return @($store.Entries.groups) }
        @()
    }.GetNewClosure()
    $a.Close = { param($Conn) [void]$store.Log.Add('Close') }.GetNewClosure()
    [pscustomobject]$a
}
