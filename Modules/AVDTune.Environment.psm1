<#
    AVDTune environment wizard, the automatic FSLogix storage setup (docs\plans\avdtune.md section 1b, issue 32; docs\environment-wizard.md).

    From the first-run answers (identity model) AVDTune plans the Azure resources for FSLogix profiles on Azure Files and, only after a confirmation, creates them:
    storage account (FileStorage, Premium), SMB settings, share, private endpoint with private DNS, identity source of the account, share level roles. Then FSLogix on the
    master and the existing storage check (AVDTune.Storage.psm1) as the test.

      * Plan first: Get-AVDTuneEnvPlan only reads (GET). Every step says Create, Update, None, Manual or Blocked, with the exact request body, and the plan has a hash.
      * Write only through Invoke-AVDTuneEnvApply: snapshot gate open (Test-AVDTuneWriteAllowed), the plan is read AGAIN and must have the confirmed hash (any difference:
        nothing is written), resource by resource, asynchronous operations awaited, stop at the first failure, LastChange set (also for a failed attempt).
      * Journal config\azure-setup.json (before and after every write, no secret, no token) is what Undo works from: only what AVDTune created (tag CreatedWith=AVDTune), in
        reverse order, the share and the account only when the share is verified empty over the data plane.
      * Azure Resource Manager only through the ARM adapter of AVDTune.Snapshot.psm1 (host fixed, no redirects). This module adds an allowlist of the resource types and methods
        it may write, validated names, and follows polling URLs only on the ARM host. The adapter may return Headers (Azure-AsyncOperation, Location, Retry-After); without
        them the resource itself is polled. The token is a parameter and never stored, logged or part of a message.
      * What Learn does not state is marked Verified=false in the plan (API shapes were written from the reference, not tried against a tenant).
#>

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'AVDTune.psm1')
Import-Module (Join-Path $PSScriptRoot 'AVDTune.Snapshot.psm1')
Import-Module (Join-Path $PSScriptRoot 'AVDTune.FSLogix.psm1')
Import-Module (Join-Path $PSScriptRoot 'AVDTune.Storage.psm1')

$script:StorageApi = '2024-01-01'
$script:NetworkApi = '2023-11-01'
$script:DnsApi = '2020-06-01'
$script:AuthApi = '2022-04-01'
$script:ZoneName = 'privatelink.file.core.windows.net'
$script:LearnFiles = 'https://learn.microsoft.com/en-us/azure/storage/files'
$script:RoleSmbContributor = '0c867c2a-1d8c-454a-a3db-ab2ea1bdc8bb'
$script:RoleSmbElevated = 'a7264617-510b-434b-a828-9731dc254ea7'
$script:Seg = '[A-Za-z0-9._()-]{1,90}'
$script:Guid = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'

#region names, spec, quota

function Test-AVDTuneEnvSegment([string]$Name) { [bool]($Name -cmatch "^$($script:Seg)$" -and -not $Name.EndsWith('.')) }
function Test-AVDTuneEnvGuid([string]$Text) { [bool]($Text -match "^$($script:Guid)$") }
function Test-AVDTuneEnvSubnetId([string]$Id) { [bool]($Id -cmatch "^/subscriptions/$($script:Guid)/resourceGroups/$($script:Seg)/providers/Microsoft\.Network/virtualNetworks/$($script:Seg)/subnets/$($script:Seg)$") }
function Get-AVDTuneEnvVNetId([string]$SubnetId) { $SubnetId -replace '/subnets/[^/]+$', '' }

function Get-AVDTuneEnvQuota {
    <# Provisioned size of the share in GiB (users x GiB per user, Premium minimum 100) and what that gives: baseline IOPS 3000 + 1 per GiB, throughput 100 + 0.1 MiB/s per GiB (Learn, understanding billing, Premium; the formula is not re-read by the check) #>
    param([int]$Users, [int]$GiBPerUser)
    $gib = [Math]::Max(100, $Users * $GiBPerUser)
    [pscustomobject]@{ GiB = [int]$gib; Iops = [int](3000 + $gib); MiBPerSecond = [int][Math]::Ceiling(100 + 0.1 * $gib) }
}

function Test-AVDTuneEnvSpec {
    <# Errors for a spec (the names that go into Azure paths and bodies). $Spec: SubscriptionId ResourceGroup Location AccountName Sku ShareName Users GiBPerUser Endpoint SubnetId PrivateEndpointName DnsZone DnsZoneResourceGroup UsersGroupId AdminsGroupId DomainName DomainGuid AllowedIps #>
    param([Parameter(Mandatory)]$Spec, [string]$Identity = 'EntraKerberos')
    $e = New-Object System.Collections.ArrayList
    $p = { param($n) [string](Get-AVDTuneProp $Spec $n) }
    if (-not (Test-AVDTuneEnvGuid (& $p 'SubscriptionId'))) { [void]$e.Add('The subscription ID must be a GUID.') }
    if (-not (Test-AVDTuneEnvSegment (& $p 'ResourceGroup'))) { [void]$e.Add('The resource group name has characters Azure does not allow (letters, digits, . _ ( ) -).') }
    if ((& $p 'Location') -cnotmatch '^[a-z0-9]{3,30}$') { [void]$e.Add('The location must be an Azure region name such as westeurope (lower case, no spaces).') }
    if (-not (Test-AVDTuneStorageAccountName (& $p 'AccountName'))) { [void]$e.Add('The storage account name must be 3 to 24 lower case letters and digits.') }
    if ((& $p 'Sku') -cnotin 'Premium_LRS', 'Premium_ZRS') { [void]$e.Add('The SKU must be Premium_LRS or Premium_ZRS (FSLogix profiles need SSD).') }
    if (-not (Test-AVDTuneShareName (& $p 'ShareName'))) { [void]$e.Add('The share name must be 3 to 63 lower case letters, digits and single hyphens.') }
    $u = Get-AVDTuneProp $Spec 'Users'; $g = Get-AVDTuneProp $Spec 'GiBPerUser'
    if ($null -eq $u -or [int]$u -lt 1 -or [int]$u -gt 100000) { [void]$e.Add('The number of users must be between 1 and 100000.') }
    if ($null -eq $g -or [int]$g -lt 1 -or [int]$g -gt 1000) { [void]$e.Add('GiB per user must be between 1 and 1000.') }
    elseif ($null -ne $u -and [int]$u -ge 1 -and [int]$u * [int]$g -gt 102400) { [void]$e.Add('A share is limited to 102400 GiB: users x GiB per user is larger.') }
    $endpoint = & $p 'Endpoint'
    if ($endpoint -cnotin 'Private', 'Public') { [void]$e.Add('Endpoint must be Private or Public.') }
    if ($endpoint -eq 'Private') {
        if (-not (Test-AVDTuneEnvSubnetId (& $p 'SubnetId'))) { [void]$e.Add('The subnet must be given as its resource ID (/subscriptions/.../virtualNetworks/<vnet>/subnets/<subnet>).') }
        if (-not (Test-AVDTuneEnvSegment (& $p 'PrivateEndpointName'))) { [void]$e.Add('The private endpoint name has characters Azure does not allow.') }
        if ((& $p 'DnsZone') -cnotin 'Azure', 'OwnDns') { [void]$e.Add('DnsZone must be Azure or OwnDns.') }
        $dz = & $p 'DnsZoneResourceGroup'; if ($dz -and -not (Test-AVDTuneEnvSegment $dz)) { [void]$e.Add('The resource group of the DNS zone has characters Azure does not allow.') }
    }
    else { foreach ($ip in @(Get-AVDTuneProp $Spec 'AllowedIps')) { if ($ip -and ([string]$ip) -notmatch '^(\d{1,3}\.){3}\d{1,3}(/(\d|[12]\d|3[0-2]))?$') { [void]$e.Add("'$ip' is not an IPv4 address or range.") } } }
    foreach ($n in 'UsersGroupId', 'AdminsGroupId') { $v = & $p $n; if ($v -and -not (Test-AVDTuneEnvGuid $v)) { [void]$e.Add("$n must be the object ID (GUID) of a group.") } }
    $dn = & $p 'DomainName'; $dg = & $p 'DomainGuid'
    if ($dn -and $dn -notmatch '^[A-Za-z0-9][A-Za-z0-9.-]{0,250}\.[A-Za-z]{2,}$') { [void]$e.Add('The domain name is not valid.') }
    if ($dg -and -not (Test-AVDTuneEnvGuid $dg)) { [void]$e.Add('The domain GUID must be a GUID.') }
    if ([bool]$dn -ne [bool]$dg) { [void]$e.Add('Domain name and domain GUID go together (hybrid identities) or both stay empty.') }
    if ($Identity -notin 'EntraKerberos', 'EntraDs', 'AdDs') { [void]$e.Add('Unknown identity model.') }
    @($e)
}

function Get-AVDTuneEnvVhdLocation($Spec) { "\\$([string]$Spec.AccountName).file.core.windows.net\$([string]$Spec.ShareName)" }

function ConvertTo-AVDTuneEntraSid {
    <# S-1-12-1-<four 32 bit numbers>: the SID of an Entra group or user from its object ID (the GUID bytes read as four little endian numbers) #>
    param([Parameter(Mandatory)][string]$ObjectId)
    if (-not (Test-AVDTuneEnvGuid $ObjectId)) { throw 'Not an object ID (GUID).' }
    $b = ([guid]$ObjectId).ToByteArray()
    'S-1-12-1-' + ((0..3 | ForEach-Object { [BitConverter]::ToUInt32($b, 4 * $_) }) -join '-')
}

#endregion

#region identity model

function Get-AVDTuneEnvIdentityModel {
    <#
        What the identity source means for the setup: the ARM value, what AVDTune can do and what stays by hand (with the reason), the rights it needs, and a status text.
        $Identity is the AzureFilesAuth of Resolve-AVDTuneEnvironmentPlan (EntraKerberos, EntraDs, AdDs).
    #>
    param([Parameter(Mandatory)][ValidateSet('EntraKerberos', 'EntraDs', 'AdDs')][string]$Identity, [string]$Identities = 'CloudOnly')
    $m = [ordered]@{ Identity = $Identity; DirectoryServiceOptions = ''; Automatic = $true; Manual = @(); Notes = @(); Rights = @(); Source = "$script:LearnFiles/storage-files-active-directory-overview" }
    switch ($Identity) {
        'EntraKerberos' {
            $m.DirectoryServiceOptions = 'AADKERB'
            $m.Source = "$script:LearnFiles/storage-files-identity-auth-hybrid-identities-enable"
            $m.Manual = @(
                [pscustomobject]@{ Id = 'manual.consent'; Title = 'Grant admin consent to the storage account app'; Text = 'Entra admin center > App registrations > All applications > "[Storage Account] <account>.file.core.windows.net" > API permissions > Grant admin consent (openid, profile, User.Read). Needs Application Administrator or Cloud Application Administrator and, for the consent, Privileged Role Administrator. With a private endpoint also add the private link FQDN to the app.'; Source = $m.Source }
                [pscustomobject]@{ Id = 'manual.ca'; Title = 'Exclude the storage account app from Conditional Access policies that require MFA'; Text = 'Entra does not support MFA for Azure Files with Entra Kerberos; without the exclusion mapping the share fails with system error 1327.'; Source = $m.Source }
            )
            if ($Identities -eq 'CloudOnly') { $m.Manual += [pscustomobject]@{ Id = 'manual.tags'; Title = 'Cloud-only groups tag in the app manifest'; Text = 'Mandatory for cloud-only identities: update the Tags in the application manifest of the storage account app (Learn: Microsoft Entra Kerberos, group SID limit). Cloud-only groups are also what App Masking cannot use.'; Source = "$script:LearnFiles/storage-files-identity-auth-hybrid-identities-enable" } }
            $m.Notes = @('Kerberos ticket encryption is always AES-256 with Entra Kerberos. Clients must be Entra joined or hybrid joined and need CloudKerberosTicketRetrievalEnabled=1 (the setup sets it on the master).', 'Cloud-only identities are supported in all public cloud regions (Learn, page of 2026-05-19); a current Windows 11 or Server 2025 build is needed.', 'Application management policies that block symmetric keys on service principals must make an exception for the Storage Resource Provider.')
            $m.Rights = @('Application Administrator (consent)')
        }
        'EntraDs' {
            $m.DirectoryServiceOptions = 'AADDS'
            $m.Source = "$script:LearnFiles/storage-files-identity-auth-domain-services-enable"
            $m.Notes = @('Microsoft Entra Domain Services: the account is enabled with one ARM property; the session hosts must be joined to that managed domain.')
        }
        'AdDs' {
            $m.DirectoryServiceOptions = 'AD'; $m.Automatic = $false
            $m.Source = "$script:LearnFiles/storage-files-identity-ad-ds-enable"
            $m.Manual = @([pscustomobject]@{ Id = 'manual.adds'; Title = 'AD DS identity of the storage account'; Text = 'Computer or service account in the chosen OU, the Kerberos key of the account as its password, the SPN cifs/<account>.file.core.windows.net and activeDirectoryProperties on the storage account. AVDTune has no write path to the domain controller yet (issue 32, open question 1); run Join-AzStorageAccount of Microsoft''s AzFilesHybrid module, then run the plan again.'; Source = $m.Source })
            $m.Rights = @('rights to create computer objects in the OU')
        }
    }
    [pscustomobject]$m
}

#endregion

#region ARM: allowlist, calls, errors, asynchronous operations

# What this module may write: method, shape of the path (after /subscriptions/<id>/resourceGroups/<rg>/providers/ or at the scope of a share) and the api version
$script:Wr = @(
    @{ Id = 'account'; Re = "^/subscriptions/$($script:Guid)/resourceGroups/$($script:Seg)/providers/Microsoft\.Storage/storageAccounts/[a-z0-9]{3,24}$"; Methods = 'PUT', 'PATCH', 'DELETE'; Api = $script:StorageApi }
    @{ Id = 'smb'; Re = "^/subscriptions/$($script:Guid)/resourceGroups/$($script:Seg)/providers/Microsoft\.Storage/storageAccounts/[a-z0-9]{3,24}/fileServices/default$"; Methods = 'PUT'; Api = $script:StorageApi }
    @{ Id = 'share'; Re = "^/subscriptions/$($script:Guid)/resourceGroups/$($script:Seg)/providers/Microsoft\.Storage/storageAccounts/[a-z0-9]{3,24}/fileServices/default/shares/[a-z0-9-]{3,63}$"; Methods = 'PUT', 'DELETE'; Api = $script:StorageApi }
    @{ Id = 'endpoint'; Re = "^/subscriptions/$($script:Guid)/resourceGroups/$($script:Seg)/providers/Microsoft\.Network/privateEndpoints/$($script:Seg)$"; Methods = 'PUT', 'DELETE'; Api = $script:NetworkApi }
    @{ Id = 'dnsgroup'; Re = "^/subscriptions/$($script:Guid)/resourceGroups/$($script:Seg)/providers/Microsoft\.Network/privateEndpoints/$($script:Seg)/privateDnsZoneGroups/default$"; Methods = 'PUT', 'DELETE'; Api = $script:NetworkApi }
    @{ Id = 'dnszone'; Re = "^/subscriptions/$($script:Guid)/resourceGroups/$($script:Seg)/providers/Microsoft\.Network/privateDnsZones/privatelink\.file\.core\.windows\.net$"; Methods = 'PUT', 'DELETE'; Api = $script:DnsApi }
    @{ Id = 'dnslink'; Re = "^/subscriptions/$($script:Guid)/resourceGroups/$($script:Seg)/providers/Microsoft\.Network/privateDnsZones/privatelink\.file\.core\.windows\.net/virtualNetworkLinks/$($script:Seg)$"; Methods = 'PUT', 'DELETE'; Api = $script:DnsApi }
    @{ Id = 'role'; Re = "^/subscriptions/$($script:Guid)/resourceGroups/$($script:Seg)/providers/Microsoft\.Storage/storageAccounts/[a-z0-9]{3,24}/fileServices/default/fileshares/[a-z0-9-]{3,63}/providers/Microsoft\.Authorization/roleAssignments/$($script:Guid)$"; Methods = 'PUT', 'DELETE'; Api = $script:AuthApi }
)

function Get-AVDTuneEnvWriteRule([string]$Path, [string]$Method) {
    foreach ($r in $script:Wr) { if ($Path -cmatch $r.Re -and $Method -in $r.Methods) { return $r } }
    $null
}

function Assert-AVDTuneEnvArmPath {
    <# GET: any resource path of one subscription. PUT, PATCH, DELETE: only the resource types of the allowlist above, with the api version of that type. POST never. #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Method)
    if ($Path -notmatch "^/subscriptions/$($script:Guid)/") { throw 'Not an ARM subscription path.' }
    if ($Path -match '[\s\x00-\x1F#]' -or $Path -match '\.\.' -or [regex]::Matches($Path, '\?').Count -ne 1) { throw 'The ARM path has characters that are not allowed.' }
    if ($Method -notin 'GET', 'PUT', 'PATCH', 'DELETE') { throw "ARM method $Method is not used by the environment setup." }
    $base, $query = $Path -split '\?', 2
    # a GET may carry the extra values of a polling link (monitor=true), nothing else than plain query characters; a write carries only the api-version of its type
    if ($query -notmatch '^[A-Za-z0-9=&_.-]+$' -or $query -notmatch '(^|&)api-version=[0-9]{4}-[0-9]{2}-[0-9]{2}(-preview)?(&|$)') { throw 'The ARM query must carry the api-version and plain characters only.' }
    if ($Method -ne 'GET') {
        $rule = Get-AVDTuneEnvWriteRule $base $Method
        if (-not $rule) { throw "The environment setup may not $Method this resource." }
        if ($query -ne "api-version=$($rule.Api)") { throw 'Unexpected api version for this resource.' }
    }
}

function Get-AVDTuneEnvHeader($Resp, [string]$Name) {
    $h = Get-AVDTuneProp $Resp 'Headers'
    if ($null -eq $h) { return '' }
    if ($h -is [System.Collections.IDictionary]) { foreach ($k in @($h.Keys)) { if ([string]$k -ieq $Name) { return [string]$h[$k] } }; return '' }
    foreach ($p in $h.PSObject.Properties) { if ($p.Name -ieq $Name) { return [string]$p.Value } }
    ''
}

function Invoke-AVDTuneEnvArmRaw {
    <# One request through the ARM adapter; never throws for a status. Returns Status, Headers, Body, Error text of the adapter, Code and Message of an Azure error body. #>
    param([Parameter(Mandatory)]$Arm, [Parameter(Mandatory)][string]$Method, [Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Token, $Body)
    Assert-AVDTuneEnvArmPath -Path $Path -Method $Method
    $r = & $Arm.Invoke $Method $Path $Token $Body
    $b = Get-AVDTuneProp $r 'Body'
    $err = Get-AVDTuneProp $b 'error'
    [pscustomobject]@{ Status = [int](Get-AVDTuneProp $r 'Status'); Headers = (Get-AVDTuneProp $r 'Headers'); Body = $b; Error = [string](Get-AVDTuneProp $r 'Error')
        Code = [string](Get-AVDTuneProp $err 'code'); Message = [string](Get-AVDTuneProp $err 'message') }
}

function ConvertTo-AVDTuneEnvArmError {
    <# A readable text for a failed answer (no token, no header). $What names the action, $Role the role to ask for on a 403. #>
    param([Parameter(Mandatory)]$Resp, [string]$What, [string]$Role = 'Contributor on the resource group')
    $detail = if ($Resp.Message) { " ($($Resp.Code): $($Resp.Message))" } elseif ($Resp.Error) { " ($($Resp.Error))" } else { '' }
    switch ($Resp.Status) {
        0 { "No connection to Azure Resource Manager while trying to $What. Check the network and the proxy.$detail" }
        401 { 'Azure rejected the sign-in token (401). Sign in again on the Overview.' }
        403 { "Azure refuses to $What (403): the signed-in account lacks the permission. Ask for $Role.$detail" }
        404 { "Azure does not know the resource needed to $What (404).$detail" }
        409 {
            switch ($Resp.Code) {
                'StorageAccountAlreadyExists' { "The storage account name is already taken (409): storage account names are unique in all of Azure. Choose another name.$detail" }
                'AccountNameInvalid' { "The storage account name is not accepted (409).$detail" }
                { $_ -in 'AnotherOperationInProgress', 'ConflictingOperation', 'OperationNotAllowed' } { "Azure is busy with another operation on this resource (409). Wait a few minutes and run the plan again.$detail" }
                'RoleAssignmentExists' { "The role assignment already exists (409).$detail" }
                default { "Azure reports a conflict while trying to $What (409).$detail" }
            }
        }
        400 { "Azure refused the request to $What as invalid (400).$detail" }
        429 { 'Azure asks to slow down (429). Wait a minute and try again.' }
        default { "Azure answered $($Resp.Status) while trying to $What.$detail" }
    }
}

function Get-AVDTuneEnvResource {
    <# GET of one resource: Exists (200), not Exists (404); anything else throws the readable text. #>
    param([Parameter(Mandatory)]$Arm, [Parameter(Mandatory)][string]$Token, [Parameter(Mandatory)][string]$Path, [string]$What = 'read a resource')
    $r = Invoke-AVDTuneEnvArmRaw -Arm $Arm -Method GET -Path $Path -Token $Token
    if ($r.Status -ge 200 -and $r.Status -lt 300) { return [pscustomobject]@{ Exists = $true; Body = $r.Body } }
    if ($r.Status -eq 404) { return [pscustomobject]@{ Exists = $false; Body = $null } }
    throw (ConvertTo-AVDTuneEnvArmError -Resp $r -What $What -Role 'Reader on the resource group')
}

function Get-AVDTuneEnvPollPath([string]$Url) {
    # A polling URL is absolute: only the ARM host and a subscription path are followed, nothing else
    $p = ConvertTo-AVDTuneArmPath $Url
    if ($p -notmatch "^/subscriptions/$($script:Guid)/" -or $p -match '[\s\x00-\x1F#]' -or $p -match '\.\.' -or [regex]::Matches($p, '\?').Count -gt 1) { throw 'Azure returned a polling link that is not followed.' }
    $p
}

function Wait-AVDTuneEnvOperation {
    <#
        Waits for an asynchronous operation. Azure-AsyncOperation first (status InProgress, Succeeded, Failed, Canceled), then Location (202 while running, 200/201/204 when done),
        else the resource itself (provisioningState; for a delete until it is gone). Retry-After is honoured up to 30 seconds. Returns @{ Ok; Message }.
    #>
    param([Parameter(Mandatory)]$Arm, [Parameter(Mandatory)][string]$Token, [Parameter(Mandatory)]$First, [Parameter(Mandatory)][string]$ResourcePath, [string]$Method = 'PUT', [int]$PollSeconds = 5, [int]$TimeoutSeconds = 900, [int]$MaxPolls = 400)
    $async = Get-AVDTuneEnvHeader $First 'Azure-AsyncOperation'
    $loc = Get-AVDTuneEnvHeader $First 'Location'
    $retry = Get-AVDTuneEnvHeader $First 'Retry-After'
    $until = (Get-Date).AddSeconds($TimeoutSeconds)
    $pause = { param($ra) if ($PollSeconds -gt 0) { $s = $PollSeconds; $n = 0; if ([int]::TryParse([string]$ra, [ref]$n) -and $n -gt 0) { $s = [Math]::Min($n, 30) }; Start-Sleep -Seconds $s } }
    for ($i = 0; $i -lt $MaxPolls; $i++) {
        if ($i -gt 0 -and (Get-Date) -gt $until) { break }
        & $pause $retry
        if ($async) {
            $r = Invoke-AVDTuneEnvArmRaw -Arm $Arm -Method GET -Path (Get-AVDTuneEnvPollPath $async) -Token $Token
            if ($r.Status -ne 200) { return [pscustomobject]@{ Ok = $false; Message = (ConvertTo-AVDTuneEnvArmError -Resp $r -What 'read the state of the operation') } }
            $st = [string](Get-AVDTuneProp $r.Body 'status')
            if ($st -eq 'Succeeded') { return [pscustomobject]@{ Ok = $true; Message = '' } }
            if ($st -in 'Failed', 'Canceled') { $oe = Get-AVDTuneProp $r.Body 'error'; return [pscustomobject]@{ Ok = $false; Message = "The operation $($st.ToLowerInvariant()) in Azure$(if ($oe) { ' (' + [string](Get-AVDTuneProp $oe 'code') + ': ' + [string](Get-AVDTuneProp $oe 'message') + ')' })." } }
            $retry = Get-AVDTuneEnvHeader $r 'Retry-After'
        }
        elseif ($loc) {
            $r = Invoke-AVDTuneEnvArmRaw -Arm $Arm -Method GET -Path (Get-AVDTuneEnvPollPath $loc) -Token $Token
            if ($r.Status -in 200, 201, 204) { return [pscustomobject]@{ Ok = $true; Message = '' } }
            if ($r.Status -ne 202) { return [pscustomobject]@{ Ok = $false; Message = (ConvertTo-AVDTuneEnvArmError -Resp $r -What 'read the state of the operation') } }
            $retry = Get-AVDTuneEnvHeader $r 'Retry-After'
        }
        else {
            $r = Invoke-AVDTuneEnvArmRaw -Arm $Arm -Method GET -Path $ResourcePath -Token $Token
            if ($Method -eq 'DELETE') { if ($r.Status -eq 404) { return [pscustomobject]@{ Ok = $true; Message = '' } } }
            elseif ($r.Status -eq 200) {
                $ps = [string](Get-AVDTuneProp (Get-AVDTuneProp $r.Body 'properties') 'provisioningState')
                if (-not $ps -or $ps -eq 'Succeeded') { return [pscustomobject]@{ Ok = $true; Message = '' } }
                if ($ps -in 'Failed', 'Canceled') { return [pscustomobject]@{ Ok = $false; Message = "The resource ended in the state $ps." } }
            }
            elseif ($r.Status -ne 404) { return [pscustomobject]@{ Ok = $false; Message = (ConvertTo-AVDTuneEnvArmError -Resp $r -What 'read the resource') } }
        }
    }
    [pscustomobject]@{ Ok = $false; Message = "Azure did not finish within the time limit ($TimeoutSeconds seconds). The operation may still complete: run the plan again to see where it stands." }
}

function Invoke-AVDTuneEnvWrite {
    <# PUT, PATCH or DELETE of one allowlisted resource, awaiting an asynchronous operation. Returns @{ Ok; Status; Message; Code; Benign } (Benign: RoleAssignmentExists). #>
    param([Parameter(Mandatory)]$Arm, [Parameter(Mandatory)][string]$Token, [Parameter(Mandatory)][string]$Method, [Parameter(Mandatory)][string]$Path, $Body, [Parameter(Mandatory)][string]$What, [string]$Role = 'Contributor on the resource group', [int]$PollSeconds = 5, [int]$TimeoutSeconds = 900, [int]$MaxPolls = 400)
    $full = $Path
    try {
    $r = Invoke-AVDTuneEnvArmRaw -Arm $Arm -Method $Method -Path $full -Token $Token -Body $Body
    $isAsync = [bool](Get-AVDTuneEnvHeader $r 'Azure-AsyncOperation') -or ($r.Status -eq 202) -or ([bool](Get-AVDTuneEnvHeader $r 'Location') -and $r.Status -in 201, 202)
    if ($r.Status -in 200, 201, 202, 204) {
        if ($isAsync) {
            $w = Wait-AVDTuneEnvOperation -Arm $Arm -Token $Token -First $r -ResourcePath $full -Method $Method -PollSeconds $PollSeconds -TimeoutSeconds $TimeoutSeconds -MaxPolls $MaxPolls
            return [pscustomobject]@{ Ok = $w.Ok; Status = $r.Status; Message = $w.Message; Code = ''; Benign = $false }
        }
        return [pscustomobject]@{ Ok = $true; Status = $r.Status; Message = ''; Code = ''; Benign = $false }
    }
    $benign = ($r.Status -eq 409 -and $r.Code -eq 'RoleAssignmentExists') -or ($Method -eq 'DELETE' -and $r.Status -eq 404)
    [pscustomobject]@{ Ok = $benign; Status = $r.Status; Message = $(if ($benign) { '' } else { ConvertTo-AVDTuneEnvArmError -Resp $r -What $What -Role $Role }); Code = $r.Code; Benign = $benign }
    }
    catch { [pscustomobject]@{ Ok = $false; Status = 0; Message = $_.Exception.Message; Code = ''; Benign = $false } }   # a refused path or link is a failed step, never a crash with the journal half written
}

#endregion

#region canonical form and hash

function ConvertTo-AVDTuneEnvCanonical($Value) {
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { return $(if ($Value) { 'true' } else { 'false' }) }
    if ($Value -is [string]) { return ('"' + ([regex]::Replace($Value, '["\\\x00-\x1F]', { param($m) '\u{0:x4}' -f [int][char]$m.Value })) + '"') }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) { return [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0}', $Value) }
    if ($Value -is [System.Collections.IDictionary]) { return ('{' + ((@($Value.Keys | Sort-Object { [string]$_ }) | ForEach-Object { (ConvertTo-AVDTuneEnvCanonical ([string]$_)) + ':' + (ConvertTo-AVDTuneEnvCanonical $Value[$_]) }) -join ',') + '}') }
    if ($Value -is [System.Collections.IEnumerable]) { return ('[' + ((@($Value) | ForEach-Object { ConvertTo-AVDTuneEnvCanonical $_ }) -join ',') + ']') }
    ('{' + ((@($Value.PSObject.Properties | Sort-Object Name) | ForEach-Object { (ConvertTo-AVDTuneEnvCanonical $_.Name) + ':' + (ConvertTo-AVDTuneEnvCanonical $_.Value) }) -join ',') + '}')
}

function Get-AVDTuneEnvHash([string]$Text) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { (-join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)) | ForEach-Object { $_.ToString('x2') })).Substring(0, 24) } finally { $sha.Dispose() }
}

function Get-AVDTuneEnvRoleName([string]$Scope, [string]$Principal, [string]$Role) {
    # A fixed name for the assignment: the same plan always gives the same GUID, so it is created once
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $b = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($Scope + '|' + $Principal + '|' + $Role).ToLowerInvariant())) } finally { $sha.Dispose() }
    ([guid]([byte[]]$b[0..15])).ToString()
}

#endregion

#region rights

function Test-AVDTuneEnvActionMatch([string]$Pattern, [string]$Action) {
    [bool]($Action -match ('^' + ([regex]::Escape($Pattern).Replace('\*', '.*')) + '$'))
}

function Get-AVDTuneEnvRights {
    <#
        What the signed-in account may do on the resource group (ARM: Microsoft.Authorization/permissions, effective actions of all roles). Missing = actions that no role allows;
        Unknown when the permissions cannot be read (that is not a refusal: the plan says so and Azure decides at the write).
    #>
    param([Parameter(Mandatory)]$Arm, [Parameter(Mandatory)][string]$Token, [Parameter(Mandatory)]$Spec, [string]$Identity = 'EntraKerberos')
    $need = New-Object System.Collections.ArrayList
    $add = { param($rg, $action, $why) [void]$need.Add([pscustomobject]@{ Rg = $rg; Action = $action; Why = $why }) }
    $sub = [string]$Spec.SubscriptionId; $rg = [string]$Spec.ResourceGroup
    & $add $rg 'Microsoft.Storage/storageAccounts/write' 'create or change the storage account'
    & $add $rg 'Microsoft.Storage/storageAccounts/fileServices/write' 'set the SMB settings'
    & $add $rg 'Microsoft.Storage/storageAccounts/fileServices/shares/write' 'create the share'
    & $add $rg 'Microsoft.Authorization/roleAssignments/write' 'assign the share level roles'
    if ([string]$Spec.Endpoint -eq 'Private') {
        & $add $rg 'Microsoft.Network/privateEndpoints/write' 'create the private endpoint'
        $subnetRg = if ([string]$Spec.SubnetId -match '/resourceGroups/([^/]+)/') { $Matches[1] } else { $rg }
        & $add $subnetRg 'Microsoft.Network/virtualNetworks/subnets/join/action' 'put the private endpoint into the subnet (Network Contributor on the subnet)'
        if ([string]$Spec.DnsZone -eq 'Azure') {
            $zrg = if ([string]$Spec.DnsZoneResourceGroup) { [string]$Spec.DnsZoneResourceGroup } else { $rg }
            & $add $zrg 'Microsoft.Network/privateDnsZones/write' 'create the private DNS zone'
            & $add $zrg 'Microsoft.Network/privateDnsZones/virtualNetworkLinks/write' 'link the zone to the VNet'
            & $add $rg 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups/write' 'register the endpoint in the DNS zone'
        }
    }
    $cache = @{}; $missing = New-Object System.Collections.ArrayList; $unknown = $false; $reason = ''
    foreach ($n in $need) {
        if (-not $cache.ContainsKey($n.Rg)) {
            $r = Invoke-AVDTuneEnvArmRaw -Arm $Arm -Method GET -Path "/subscriptions/$sub/resourceGroups/$($n.Rg)/providers/Microsoft.Authorization/permissions?api-version=$script:AuthApi" -Token $Token
            $cache[$n.Rg] = $(if ($r.Status -eq 200) { @(@(Get-AVDTuneProp $r.Body 'value') | Where-Object { $_ }) } else { $null })
            if ($null -eq $cache[$n.Rg]) { $unknown = $true; $reason = ConvertTo-AVDTuneEnvArmError -Resp $r -What 'read your permissions' -Role 'Reader on the resource group' }
        }
        $perms = $cache[$n.Rg]
        if ($null -eq $perms) { continue }
        $ok = $false
        foreach ($p in $perms) {
            $allowed = @(@(Get-AVDTuneProp $p 'actions') | Where-Object { $_ } | Where-Object { Test-AVDTuneEnvActionMatch $_ $n.Action }).Count -gt 0
            $denied = @(@(Get-AVDTuneProp $p 'notActions') | Where-Object { $_ } | Where-Object { Test-AVDTuneEnvActionMatch $_ $n.Action }).Count -gt 0
            if ($allowed -and -not $denied) { $ok = $true; break }
        }
        if (-not $ok) { [void]$missing.Add([pscustomobject]@{ ResourceGroup = $n.Rg; Action = $n.Action; Why = $n.Why }) }
    }
    [pscustomobject]@{ Missing = @($missing); Unknown = $unknown; Reason = $reason; Checked = $need.Count }
}

#endregion

#region the plan

function New-AVDTuneEnvStep {
    param([int]$Order, [string]$Id, [string]$Type, [string]$Title, [ValidateSet('Create', 'Update', 'None', 'Manual', 'Blocked', 'Deferred')][string]$Action, [string]$Method = '', [string]$Path = '', $Body = $null, $Before = $null, [string[]]$Changes = @(), [string]$Why = '', [string]$Source = $script:LearnFiles, [bool]$Verified = $true, [string]$Note = '', [bool]$Taggable = $false, [string]$Role = 'Contributor on the resource group')
    [pscustomobject]@{ Order = $Order; Id = $Id; Type = $Type; Title = $Title; Action = $Action; Method = $Method; Path = $Path; Body = $Body; Before = $Before; Changes = @($Changes); Why = $Why; Source = $Source; Verified = $Verified; Note = $Note; Taggable = $Taggable; Role = $Role }
}

function ConvertTo-AVDTuneEnvTagValue([string]$Text) { (Remove-AVDTuneControlCharacters $Text 120) -replace '[<>%&\\?/]', '_' }

function Get-AVDTuneEnvPlan {
    <#
        The plan: reads every resource (GET only), compares it with the wish and returns the steps with their action and exact request body, the rights check, warnings, the manual
        steps of the identity model and a hash of what would be sent. Nothing is changed. Throws a readable text when a read fails (no sign-in, 403 on a read).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Arm, [Parameter(Mandatory)][string]$Token, [Parameter(Mandatory)]$Spec, [ValidateSet('EntraKerberos', 'EntraDs', 'AdDs')][string]$Identity = 'EntraKerberos', [string]$Identities = 'CloudOnly', [string]$User, [string]$ImageVersion, [switch]$SkipRights)
    $errors = @(Test-AVDTuneEnvSpec -Spec $Spec -Identity $Identity)
    if ($errors.Count -gt 0) { throw ($errors -join ' ') }
    $model = Get-AVDTuneEnvIdentityModel -Identity $Identity -Identities $Identities
    $sub = [string]$Spec.SubscriptionId; $rg = [string]$Spec.ResourceGroup; $acct = [string]$Spec.AccountName; $share = [string]$Spec.ShareName
    $private = ([string]$Spec.Endpoint -eq 'Private')
    $quota = Get-AVDTuneEnvQuota -Users ([int]$Spec.Users) -GiBPerUser ([int]$Spec.GiBPerUser)
    $tags = [ordered]@{ CreatedWith = 'AVDTune'; CreatedBy = (ConvertTo-AVDTuneEnvTagValue $User) }
    if ($ImageVersion) { $tags['ImageVersion'] = (ConvertTo-AVDTuneEnvTagValue $ImageVersion) }
    $warnings = New-Object System.Collections.ArrayList
    $blocked = New-Object System.Collections.ArrayList
    $steps = New-Object System.Collections.ArrayList
    $n = 0
    $accPath = "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Storage/storageAccounts/$acct"
    $rights = $null
    if (-not $SkipRights) { $rights = Get-AVDTuneEnvRights -Arm $Arm -Token $Token -Spec $Spec -Identity $Identity }
    if ($rights) {
        foreach ($m in $rights.Missing) { [void]$blocked.Add("Missing permission $($m.Action) on resource group $($m.ResourceGroup) (needed to $($m.Why)).") }
        if ($rights.Unknown) { [void]$warnings.Add("Your permissions could not be read, so they are not checked in advance: $($rights.Reason)") }
    }

    # 1 storage account
    $cur = Get-AVDTuneEnvResource -Arm $Arm -Token $Token -Path "${accPath}?api-version=$script:StorageApi" -What 'read the storage account'
    $wantProps = [ordered]@{ supportsHttpsTrafficOnly = $true; minimumTlsVersion = 'TLS1_2'; allowBlobPublicAccess = $false; publicNetworkAccess = $(if ($private) { 'Disabled' } else { 'Enabled' }) }
    if ($cur.Exists) {
        $props = Get-AVDTuneProp $cur.Body 'properties'
        $kind = [string](Get-AVDTuneProp $cur.Body 'kind'); $sku = [string](Get-AVDTuneProp (Get-AVDTuneProp $cur.Body 'sku') 'name')
        if ($kind -ne 'FileStorage' -or $sku -notlike 'Premium_*') { [void]$warnings.Add("The existing account is ${kind} / ${sku}: not recommended for FSLogix profiles (latency, IOPS). Kind and SKU cannot be changed; create a Premium FileStorage account instead.") }
        $diff = [ordered]@{}; $before = [ordered]@{}; $changes = New-Object System.Collections.ArrayList
        foreach ($k in $wantProps.Keys) {
            $have = Get-AVDTuneProp $props $k
            if ($null -ne $have -and [string]$have -ne [string]$wantProps[$k]) { $diff[$k] = $wantProps[$k]; $before[$k] = $have; [void]$changes.Add("${k}: $have -> $($wantProps[$k])") }
        }
        if ($diff.Count -gt 0) { [void]$steps.Add((New-AVDTuneEnvStep (++$n) 'env.account' 'account' "Align the settings of the storage account $acct" 'Update' 'PATCH' "${accPath}?api-version=$script:StorageApi" @{ properties = $diff } $before $changes "Secure transfer, TLS 1.2, no public blob access$(if ($private) { ', public network access off (private endpoint)' })." "$script:LearnFiles/storage-files-planning" $true '' $false)) }
        else { [void]$steps.Add((New-AVDTuneEnvStep (++$n) 'env.account' 'account' "Storage account $acct" 'None' '' '' $null $null @() 'Exists and has the recommended settings.')) }
    }
    else {
        $acls = [ordered]@{ defaultAction = 'Deny'; bypass = 'AzureServices' }
        if (-not $private) { $acls['ipRules'] = @(@(Get-AVDTuneProp $Spec 'AllowedIps') | Where-Object { $_ } | ForEach-Object { @{ value = [string]$_; action = 'Allow' } }) }
        $props = [ordered]@{}; foreach ($k in $wantProps.Keys) { $props[$k] = $wantProps[$k] }
        $props['defaultToOAuthAuthentication'] = $true; $props['networkAcls'] = $acls
        $body = [ordered]@{ location = [string]$Spec.Location; kind = 'FileStorage'; sku = @{ name = [string]$Spec.Sku }; tags = $tags; properties = $props }
        $ch = @("Premium FileStorage, $($Spec.Sku)", 'secure transfer only, TLS 1.2, no public blob access', $(if ($private) { 'public network access off (private endpoint)' } else { 'public endpoint with firewall, default deny' }), 'OAuth as default authentication')
        [void]$steps.Add((New-AVDTuneEnvStep (++$n) 'env.account' 'account' "Create storage account $acct in $($Spec.Location)" 'Create' 'PUT' "${accPath}?api-version=$script:StorageApi" $body $null $ch 'Profiles need SSD storage (Premium FileStorage); LRS or ZRS decides what a zone failure does.' "$script:LearnFiles/storage-files-planning" $true '' $true))
        if (-not $private) { [void]$warnings.Add('Public endpoint: the firewall allows only the ranges you listed. A private endpoint is recommended.') }
    }

    # 2 SMB settings
    $smbWant = [ordered]@{ versions = 'SMB3.1.1'; authenticationMethods = 'Kerberos'; kerberosTicketEncryption = 'AES-256'; channelEncryption = 'AES-256-GCM' }
    $fsPath = "$accPath/fileServices/default"
    $fs = if ($cur.Exists) { Get-AVDTuneEnvResource -Arm $Arm -Token $Token -Path "${fsPath}?api-version=$script:StorageApi" -What 'read the file service' } else { [pscustomobject]@{ Exists = $false; Body = $null } }
    $smbHave = if ($fs.Exists) { Get-AVDTuneProp (Get-AVDTuneProp (Get-AVDTuneProp $fs.Body 'properties') 'protocolSettings') 'smb' } else { $null }
    $smbDiff = @($smbWant.Keys | Where-Object { [string](Get-AVDTuneProp $smbHave $_) -ne [string]$smbWant[$_] })
    if ($smbDiff.Count -eq 0) { [void]$steps.Add((New-AVDTuneEnvStep (++$n) 'env.smb' 'smb' 'SMB settings of the file service' 'None' '' '' $null $null @() 'Already SMB 3.1.1, Kerberos, AES-256 ticket, AES-256-GCM.')) }
    else {
        $beforeSmb = if ($smbHave) { $b = [ordered]@{}; foreach ($k in $smbWant.Keys) { $v = Get-AVDTuneProp $smbHave $k; if ($null -ne $v) { $b[$k] = $v } }; $b } else { $null }
        [void]$steps.Add((New-AVDTuneEnvStep (++$n) 'env.smb' 'smb' 'Set SMB 3.1.1, Kerberos only, AES-256 ticket, AES-256-GCM' $(if ($smbHave) { 'Update' } else { 'Create' }) 'PUT' "${fsPath}?api-version=$script:StorageApi" @{ properties = @{ protocolSettings = @{ smb = $smbWant } } } $beforeSmb @($smbDiff | ForEach-Object { "$_ -> $($smbWant[$_])" }) 'A session host must reach the share with Kerberos and AES; NTLM and older SMB versions are switched off.' "$script:LearnFiles/files-smb-protocol" $true 'PUT of the file service properties: whether values that are not sent stay unchanged is not stated on Learn; only the smb block is sent.' $false))
    }

    # 3 share
    $shPath = "$fsPath/shares/$share"
    $sh = if ($cur.Exists) { Get-AVDTuneEnvResource -Arm $Arm -Token $Token -Path "${shPath}?api-version=$script:StorageApi" -What 'read the share' } else { [pscustomobject]@{ Exists = $false; Body = $null } }
    $quotaText = "$($quota.GiB) GiB provisioned, about $($quota.Iops) IOPS and $($quota.MiBPerSecond) MiB/s baseline ($($Spec.Users) users x $($Spec.GiBPerUser) GiB, Premium minimum 100 GiB)"
    if ($sh.Exists) {
        $haveQ = [int](Get-AVDTuneProp (Get-AVDTuneProp $sh.Body 'properties') 'shareQuota')
        if ($haveQ -lt $quota.GiB) { [void]$warnings.Add("The existing share has $haveQ GiB; $($quota.GiB) GiB are needed for the planned users. AVDTune does not resize an existing share.") }
        [void]$steps.Add((New-AVDTuneEnvStep (++$n) 'env.share' 'share' "Share $share" 'None' '' '' $null $null @() "Exists ($haveQ GiB)."))
    }
    else {
        $body = [ordered]@{ properties = [ordered]@{ shareQuota = $quota.GiB; enabledProtocols = 'SMB'; accessTier = 'Premium' } }
        [void]$steps.Add((New-AVDTuneEnvStep (++$n) 'env.share' 'share' "Create share $share" 'Create' 'PUT' "${shPath}?api-version=$script:StorageApi" $body $null @($quotaText, 'profile folders are created by FSLogix at the first sign-in') 'One share for the profile containers; the quota can be raised later but costs money from the first day.' "$script:LearnFiles/storage-files-planning" $true '' $false))
    }

    # 4 to 7 network
    $zoneId = ''
    if ($private) {
        $subnetId = [string]$Spec.SubnetId; $vnetId = Get-AVDTuneEnvVNetId $subnetId
        $subnet = Get-AVDTuneEnvResource -Arm $Arm -Token $Token -Path "${subnetId}?api-version=$script:NetworkApi" -What 'read the subnet'
        $vnet = Get-AVDTuneEnvResource -Arm $Arm -Token $Token -Path "${vnetId}?api-version=$script:NetworkApi" -What 'read the virtual network'
        if (-not $subnet.Exists -or -not $vnet.Exists) { [void]$blocked.Add('The subnet or its virtual network does not exist: check the subnet resource ID.') }
        $peLocation = if ($vnet.Exists -and (Get-AVDTuneProp $vnet.Body 'location')) { [string]$vnet.Body.location } else { [string]$Spec.Location }
        if ($peLocation -ne [string]$Spec.Location) { [void]$warnings.Add("The virtual network is in $peLocation, the storage account in $($Spec.Location): the private endpoint is created in the region of the VNet.") }
        $zrg = if ([string](Get-AVDTuneProp $Spec 'DnsZoneResourceGroup')) { [string]$Spec.DnsZoneResourceGroup } else { $rg }
        $zonePath = "/subscriptions/$sub/resourceGroups/$zrg/providers/Microsoft.Network/privateDnsZones/$script:ZoneName"
        $zoneId = $zonePath
        $peName = [string]$Spec.PrivateEndpointName
        $pePath = "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Network/privateEndpoints/$peName"
        if ([string]$Spec.DnsZone -eq 'Azure') {
            $z = Get-AVDTuneEnvResource -Arm $Arm -Token $Token -Path "${zonePath}?api-version=$script:DnsApi" -What 'read the private DNS zone'
            if ($z.Exists) { [void]$steps.Add((New-AVDTuneEnvStep (++$n) 'env.dnszone' 'dnszone' "Private DNS zone $script:ZoneName" 'None' '' '' $null $null @() 'Exists (it is shared by every storage account with a private endpoint in this network).')) }
            else { [void]$steps.Add((New-AVDTuneEnvStep (++$n) 'env.dnszone' 'dnszone' "Create private DNS zone $script:ZoneName" 'Create' 'PUT' "${zonePath}?api-version=$script:DnsApi" ([ordered]@{ location = 'global'; tags = $tags }) $null @('global zone') 'The name of the storage account must resolve to the private IP inside the network.' "$script:LearnFiles/storage-files-networking-dns" $true '' $true -Role 'Private DNS Zone Contributor')) }
            $linkName = ('link-' + (($vnetId -split '/')[-1])); if ($linkName.Length -gt 80) { $linkName = $linkName.Substring(0, 80) }
            $linkPath = "$zonePath/virtualNetworkLinks/$linkName"
            $l = if ($z.Exists) { Get-AVDTuneEnvResource -Arm $Arm -Token $Token -Path "${linkPath}?api-version=$script:DnsApi" -What 'read the VNet link' } else { [pscustomobject]@{ Exists = $false } }
            if ($l.Exists) { [void]$steps.Add((New-AVDTuneEnvStep (++$n) 'env.dnslink' 'dnslink' 'VNet link of the DNS zone' 'None' '' '' $null $null @() 'Exists.')) }
            else { [void]$steps.Add((New-AVDTuneEnvStep (++$n) 'env.dnslink' 'dnslink' "Link the zone to the virtual network $(($vnetId -split '/')[-1])" 'Create' 'PUT' "${linkPath}?api-version=$script:DnsApi" ([ordered]@{ location = 'global'; tags = $tags; properties = @{ virtualNetwork = @{ id = $vnetId }; registrationEnabled = $false } }) $null @('auto registration off') 'Machines in the network use this zone.' "$script:LearnFiles/storage-files-networking-dns" $true '' $true -Role 'Private DNS Zone Contributor')) }
        }
        $pe = Get-AVDTuneEnvResource -Arm $Arm -Token $Token -Path "${pePath}?api-version=$script:NetworkApi" -What 'read the private endpoint'
        if ($pe.Exists) { [void]$steps.Add((New-AVDTuneEnvStep (++$n) 'env.endpoint' 'endpoint' "Private endpoint $peName" 'None' '' '' $null $null @() 'Exists.')) }
        else {
            $body = [ordered]@{ location = $peLocation; tags = $tags; properties = [ordered]@{ subnet = @{ id = $subnetId }; privateLinkServiceConnections = @(@{ name = "$acct-file"; properties = @{ privateLinkServiceId = $accPath; groupIds = @('file') } }) } }
            [void]$steps.Add((New-AVDTuneEnvStep (++$n) 'env.endpoint' 'endpoint' "Create private endpoint $peName for $acct" 'Create' 'PUT' "${pePath}?api-version=$script:NetworkApi" $body $null @("subnet $(($subnetId -split '/')[-1])", 'group file') 'Profiles travel over the private network; the public endpoint stays off.' "$script:LearnFiles/storage-files-networking-endpoints" $true '' $true -Role 'Network Contributor'))
        }
        if ([string]$Spec.DnsZone -eq 'Azure') {
            $gPath = "$pePath/privateDnsZoneGroups/default"
            $g = if ($pe.Exists) { Get-AVDTuneEnvResource -Arm $Arm -Token $Token -Path "${gPath}?api-version=$script:NetworkApi" -What 'read the DNS zone group' } else { [pscustomobject]@{ Exists = $false } }
            if ($g.Exists) { [void]$steps.Add((New-AVDTuneEnvStep (++$n) 'env.dnsgroup' 'dnsgroup' 'DNS zone group of the endpoint' 'None' '' '' $null $null @() 'Exists.')) }
            else { [void]$steps.Add((New-AVDTuneEnvStep (++$n) 'env.dnsgroup' 'dnsgroup' 'Register the endpoint in the private DNS zone' 'Create' 'PUT' "${gPath}?api-version=$script:NetworkApi" ([ordered]@{ properties = @{ privateDnsZoneConfigs = @(@{ name = 'privatelink-file-core-windows-net'; properties = @{ privateDnsZoneId = $zonePath } }) } }) $null @('A record for the account name') 'Creates the A record that points the account name to the private IP.' "$script:LearnFiles/storage-files-networking-dns" $true '' $false -Role 'Network Contributor')) }
        }
        else { [void]$steps.Add((New-AVDTuneEnvStep (++$n) 'env.dnsrecord' 'manual' 'DNS record on your own DNS servers' 'Manual' '' '' $null $null @("$acct.file.core.windows.net -> private IP of the endpoint (shown after the endpoint exists)") 'You chose your own DNS servers: the record (or a conditional forwarder for privatelink.file.core.windows.net) is yours to create; the storage check tests the resolution afterwards.' "$script:LearnFiles/storage-files-networking-dns")) }
    }

    # 8 identity
    $dso = $model.DirectoryServiceOptions
    if (-not $model.Automatic) {
        foreach ($mm in $model.Manual) { [void]$steps.Add((New-AVDTuneEnvStep (++$n) "env.$($mm.Id -replace '^manual\.', '')" 'manual' $mm.Title 'Manual' '' '' $null $null @() $mm.Text $mm.Source)) }
    }
    else {
        $haveAuth = if ($cur.Exists) { Get-AVDTuneProp (Get-AVDTuneProp $cur.Body 'properties') 'azureFilesIdentityBasedAuthentication' } else { $null }
        $haveDso = [string](Get-AVDTuneProp $haveAuth 'directoryServiceOptions')
        $auth = [ordered]@{ directoryServiceOptions = $dso }
        if ($Identity -eq 'EntraKerberos' -and [string](Get-AVDTuneProp $Spec 'DomainName')) { $auth['activeDirectoryProperties'] = [ordered]@{ domainName = [string]$Spec.DomainName; domainGuid = [string]$Spec.DomainGuid } }
        if ($haveDso -eq $dso) { [void]$steps.Add((New-AVDTuneEnvStep (++$n) 'env.identity' 'identity' "Identity source $dso" 'None' '' '' $null $null @() 'The account already uses this identity source.')) }
        elseif ($haveDso -and $haveDso -ne 'None') { [void]$blocked.Add("The account uses the identity source $haveDso; only one source is possible. Change it first (Learn: change the identity source) or choose another identity model."); [void]$steps.Add((New-AVDTuneEnvStep (++$n) 'env.identity' 'identity' "Identity source $dso" 'Blocked' '' '' $null $null @("now $haveDso") 'Only one identity source can be enabled on a storage account.' $model.Source)) }
        else { [void]$steps.Add((New-AVDTuneEnvStep (++$n) 'env.identity' 'identity' "Enable $dso for Azure Files" 'Update' 'PATCH' "${accPath}?api-version=$script:StorageApi" @{ properties = @{ azureFilesIdentityBasedAuthentication = $auth } } ([ordered]@{ directoryServiceOptions = $(if ($haveDso) { $haveDso } else { 'None' }) }) @("directoryServiceOptions: $(if ($haveDso) { $haveDso } else { 'None' }) -> $dso") 'The identity source decides how session hosts get a Kerberos ticket for the share.' $model.Source $true 'The ARM property shapes are from the REST reference and not tried against a tenant.' $false))
        }
        foreach ($mm in $model.Manual) { [void]$steps.Add((New-AVDTuneEnvStep (++$n) "env.$($mm.Id -replace '^manual\.', '')" 'manual' $mm.Title 'Manual' '' '' $null $null @() $mm.Text $mm.Source)) }
    }

    # 9 share level roles
    $scope = "$accPath/fileServices/default/fileshares/$share"
    $existingRoles = @()
    if ($cur.Exists) {
        $rr = Invoke-AVDTuneEnvArmRaw -Arm $Arm -Method GET -Path "$scope/providers/Microsoft.Authorization/roleAssignments?api-version=$script:AuthApi" -Token $Token
        if ($rr.Status -eq 200) { $existingRoles = @(@(Get-AVDTuneProp $rr.Body 'value') | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ Role = (([string]$_.properties.roleDefinitionId -split '/')[-1]); PrincipalId = [string]$_.properties.principalId } }) }
        elseif ($rr.Status -ne 404) { [void]$warnings.Add((ConvertTo-AVDTuneEnvArmError -Resp $rr -What 'read the role assignments' -Role 'Reader on the storage account')) }
    }
    foreach ($def in @(@{ Id = 'env.role-users'; Prop = 'UsersGroupId'; Role = $script:RoleSmbContributor; Name = 'Storage File Data SMB Share Contributor'; For = 'the user group' }, @{ Id = 'env.role-admins'; Prop = 'AdminsGroupId'; Role = $script:RoleSmbElevated; Name = 'Storage File Data SMB Share Elevated Contributor'; For = 'the admin group' })) {
        $principal = [string](Get-AVDTuneProp $Spec $def.Prop)
        if (-not $principal) { [void]$steps.Add((New-AVDTuneEnvStep (++$n) $def.Id 'manual' "Role for $($def.For)" 'Manual' '' '' $null $null @() "No group was entered: assign $($def.Name) on the share to $($def.For) yourself (the groups come from Microsoft Entra ID or the domain)." "$script:LearnFiles/storage-files-identity-assign-share-level-permissions")); continue }
        $has = @($existingRoles | Where-Object { $_.Role -ieq $def.Role -and $_.PrincipalId -ieq $principal }).Count -gt 0
        $name = Get-AVDTuneEnvRoleName $scope $principal $def.Role
        if ($has) { [void]$steps.Add((New-AVDTuneEnvStep (++$n) $def.Id 'role' "$($def.Name) for $($def.For)" 'None' '' '' $null $null @() 'Already assigned.')) }
        else { [void]$steps.Add((New-AVDTuneEnvStep (++$n) $def.Id 'role' "Assign $($def.Name) on the share to $($def.For)" 'Create' 'PUT' "$scope/providers/Microsoft.Authorization/roleAssignments/${name}?api-version=$script:AuthApi" ([ordered]@{ properties = [ordered]@{ roleDefinitionId = "/subscriptions/$sub/providers/Microsoft.Authorization/roleDefinitions/$($def.Role)"; principalId = $principal; principalType = 'Group' } }) $null @("principal $principal", 'scope: this share only') 'Share level permission; the NTFS permissions on the share decide the rest.' "$script:LearnFiles/storage-files-identity-assign-share-level-permissions" $true '' $false -Role 'User Access Administrator or Role Based Access Control Administrator')) }
    }
    # 10 ntfs, 11 master, 12 test: not ARM steps, shown so the plan is complete
    [void]$steps.Add((New-AVDTuneEnvStep (++$n) 'env.acl' 'deferred' 'NTFS permissions on the share root' 'Deferred' '' '' $null $null @("Microsoft's FSLogix recommendation, shown as a diff first") 'Needs the storage token and the role Storage File Data Privileged Contributor, which can take minutes to become active after the roles above: own button on the page (existing ACL step of the storage check).' "$script:LearnFiles/storage-files-identity-configure-file-level-permissions" $true))
    [void]$steps.Add((New-AVDTuneEnvStep (++$n) 'env.master' 'deferred' 'FSLogix on the master' 'Deferred' '' '' $null $null @("VHDLocations = $(Get-AVDTuneEnvVhdLocation $Spec)", 'Enabled = 1') 'Written through the FSLogix settings step (gate, change log, undo).' 'https://learn.microsoft.com/en-us/fslogix/reference-configuration-settings' $true))
    [void]$steps.Add((New-AVDTuneEnvStep (++$n) 'env.test' 'deferred' 'Test: function test and storage check' 'Deferred' '' '' $null $null @() 'The storage check of the FSLogix page proves the result (identity, SMB, DNS, roles, ACL).' $script:LearnFiles $true))

    $hashSource = ConvertTo-AVDTuneEnvCanonical @(@($steps | Where-Object { $_.Action -in 'Create', 'Update', 'Manual', 'Blocked' }) | ForEach-Object { @{ Id = $_.Id; Action = $_.Action; Method = $_.Method; Path = $_.Path; Body = $_.Body } })
    [pscustomobject]@{
        Spec = $Spec; Identity = $Identity; Model = $model; Steps = @($steps); Warnings = @($warnings); Blocked = @($blocked); Rights = $rights; Quota = $quota; AccountExists = [bool]$cur.Exists
        Hash = (Get-AVDTuneEnvHash $hashSource); Changes = @($steps | Where-Object { $_.Action -in 'Create', 'Update' }).Count; ZoneId = $zoneId
    }
}

#endregion

#region journal

function Get-AVDTuneEnvJournalPath([string]$Root) { Join-Path $Root 'config\azure-setup.json' }

function Get-AVDTuneEnvJournal {
    param([string]$Root = (Get-AVDTuneRoot))
    $j = Read-AVDTuneJson (Get-AVDTuneEnvJournalPath $Root)
    if ($null -eq $j) { return [pscustomobject]@{ Schema = 1; Runs = @() } }
    if ([int](Get-AVDTuneProp $j 'Schema') -gt 1) { throw 'azure-setup.json is from a newer AVDTune.' }
    $j
}

function Save-AVDTuneEnvJournal([string]$Root, $Journal) { Write-AVDTuneFile (Get-AVDTuneEnvJournalPath $Root) ($Journal | ConvertTo-Json -Depth 10) }

#endregion

#region apply

function Invoke-AVDTuneEnvApply {
    <#
        Creates what the plan says, after the confirmation. -ConfirmedHash is the hash of the plan the administrator saw: the plan is built again now and a different hash writes nothing.
        Refuses without the snapshot gate. -WhatIf returns the plan and writes nothing. Stops at the first failure (the rest is Skipped). Every attempt sets LastChange.
        Returns @{ Status Changed | Unchanged | Failed | Refused | WhatIf; Message; Results; Plan }.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Arm, [Parameter(Mandatory)][string]$Token, [Parameter(Mandatory)]$Spec, [ValidateSet('EntraKerberos', 'EntraDs', 'AdDs')][string]$Identity = 'EntraKerberos', [string]$Identities = 'CloudOnly',
        [string]$ConfirmedHash, [string]$Root = (Get-AVDTuneRoot), [string]$User, [string]$SnapshotId, [int]$PollSeconds = 5, [int]$TimeoutSeconds = 900, [int]$MaxPolls = 400, [switch]$WhatIf)
    if (-not $WhatIf -and -not (Test-AVDTuneWriteAllowed)) { throw 'The snapshot gate is not confirmed: AVDTune is read only until a snapshot newer than its last change is confirmed on the Overview.' }
    $state = Get-AVDTuneState $Root
    $plan = Get-AVDTuneEnvPlan -Arm $Arm -Token $Token -Spec $Spec -Identity $Identity -Identities $Identities -User $User -ImageVersion ([string]$state.ImageVersion)
    if ($WhatIf) { return [pscustomobject]@{ Status = 'WhatIf'; Message = "Would change $($plan.Changes) resource(s)."; Results = @(); Plan = $plan } }
    if ($plan.Blocked.Count -gt 0) { return [pscustomobject]@{ Status = 'Refused'; Message = ('Nothing was written: ' + ($plan.Blocked -join ' ')); Results = @(); Plan = $plan } }
    if (-not $ConfirmedHash -or $plan.Hash -ne $ConfirmedHash) { return [pscustomobject]@{ Status = 'Refused'; Message = 'The plan differs from the one that was confirmed (or nothing was confirmed). Nothing was written: look at the new plan and confirm it again.'; Results = @(); Plan = $plan } }
    $todo = @($plan.Steps | Where-Object { $_.Action -in 'Create', 'Update' })
    if ($todo.Count -eq 0) { return [pscustomobject]@{ Status = 'Unchanged'; Message = 'Everything the plan asks for already exists.'; Results = @(); Plan = $plan } }
    $started = Get-Date
    $runId = $started.ToString('yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture) + '-' + [guid]::NewGuid().ToString('N').Substring(0, 4)
    $journal = Get-AVDTuneEnvJournal -Root $Root
    $entries = New-Object System.Collections.ArrayList
    $run = [pscustomobject][ordered]@{ RunId = $runId; Started = $started.ToString('o'); Ended = $null; User = $User; SnapshotId = $SnapshotId; Account = [string]$Spec.AccountName; ResourceGroup = [string]$Spec.ResourceGroup; Status = 'Running'; Steps = $entries }
    $journal.Runs = @(@($journal.Runs) | Where-Object { $_ }) + $run
    [void](Set-AVDTuneState -Root $Root -Values @{ LastChange = $started.ToString('o') })   # also a failed attempt may have changed something
    $results = New-Object System.Collections.ArrayList
    $stopped = $false
    foreach ($s in $todo) {
        if ($stopped) { [void]$results.Add([pscustomobject]@{ Id = $s.Id; Title = $s.Title; Status = 'Skipped'; Message = 'An earlier step failed.' }); continue }
        $entry = [pscustomobject][ordered]@{ Id = $s.Id; Type = $s.Type; Path = ($s.Path -split '\?')[0]; Action = $s.Action; Taggable = [bool]$s.Taggable; Before = $s.Before; Status = 'Started'; Message = ''; Undone = $false; At = (Get-Date).ToString('o') }
        [void]$entries.Add($entry)
        Save-AVDTuneEnvJournal $Root $journal   # the intent is on disk before the write
        $w = Invoke-AVDTuneEnvWrite -Arm $Arm -Token $Token -Method $s.Method -Path $s.Path -Body $s.Body -What $s.Title -Role $s.Role -PollSeconds $PollSeconds -TimeoutSeconds $TimeoutSeconds -MaxPolls $MaxPolls
        if ($w.Ok) {
            $entry.Status = $(if ($w.Benign) { 'Exists' } else { 'Done' }); $entry.Message = ''
            if ($w.Benign) { $entry.Action = 'None' }
            [void]$results.Add([pscustomobject]@{ Id = $s.Id; Title = $s.Title; Status = $(if ($w.Benign) { 'Unchanged' } else { 'Changed' }); Message = '' })
        }
        else {
            $entry.Status = 'Failed'; $entry.Message = $w.Message; $stopped = $true
            [void]$results.Add([pscustomobject]@{ Id = $s.Id; Title = $s.Title; Status = 'Failed'; Message = $w.Message })
        }
        Save-AVDTuneEnvJournal $Root $journal
        if ($state.ImageVersion -and $w.Ok -and -not $w.Benign) {
            [void](Add-AVDTuneChangeLogEntry -Root $Root -Version $state.ImageVersion -Category 'FSLogix' -Component "Azure: $($s.Type)" -ChangeType $(if ($s.Action -eq 'Create') { 'Added' } else { 'Changed' }) -Text "$($s.Title) (storage account $($Spec.AccountName), resource group $($Spec.ResourceGroup)); $(@($s.Changes) -join '; ')" -User $User -SnapshotId $SnapshotId -RunId $runId -Source Step)
        }
    }
    $failed = @($results | Where-Object Status -eq 'Failed').Count -gt 0
    $run.Ended = (Get-Date).ToString('o'); $run.Status = $(if ($failed) { 'Failed' } else { 'Done' })
    Save-AVDTuneEnvJournal $Root $journal
    $slim = @($results | ForEach-Object { [pscustomobject]@{ Id = $_.Id; Section = 'FSLogix'; Title = $_.Title; Mode = 'Apply'; Status = $_.Status; Before = $null; After = $null; Message = $_.Message; Reboot = $false; WhatIf = $false; At = $run.Ended } })
    $rec = [pscustomobject][ordered]@{ Id = $runId; Plan = 'Environment-Azure'; Kind = 'Environment-Azure'; Started = $run.Started; Ended = $run.Ended; User = $User; SnapshotId = $SnapshotId; WhatIf = $false; ImageVersion = $state.ImageVersion; Reboot = $false; Results = $slim }
    [void](Add-AVDTuneRun -Root $Root -Run $rec)
    $status = if ($failed) { 'Failed' } elseif (@($results | Where-Object Status -eq 'Changed').Count -gt 0) { 'Changed' } else { 'Unchanged' }
    $msg = if ($failed) { 'Stopped at the first failure: ' + (@($results | Where-Object Status -eq 'Failed')[0].Message) } else { "Done: $(@($results | Where-Object Status -eq 'Changed').Count) resource(s) created or changed." }
    [pscustomobject]@{ Status = $status; Message = $msg; Results = @($results); Plan = $plan; RunId = $runId }
}

#endregion

#region undo

function Get-AVDTuneEnvUndoPlan {
    <#
        What can be taken back: the steps AVDTune recorded in the journal that it created (Create) or changed (Update, restored from the recorded Before), newest first. A resource
        is deleted only when it still exists and carries the tag CreatedWith=AVDTune (where Azure allows tags) or the journal says Done. The share and the storage account only
        when the share is verified empty over the data plane (-Files and -StorageToken); the private DNS zone only when it holds no other record. Everything else is Keep with the reason.
        Only GETs here.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Arm, [Parameter(Mandatory)][string]$Token, [string]$Root = (Get-AVDTuneRoot), $Files, [string]$StorageToken)
    $journal = Get-AVDTuneEnvJournal -Root $Root
    $items = New-Object System.Collections.ArrayList
    foreach ($run in @($journal.Runs)) { if (-not $run) { continue }; foreach ($e in @($run.Steps)) { if ($e -and -not $e.Undone -and $e.Status -in 'Done', 'Failed', 'Started') { [void]$items.Add([pscustomobject]@{ Run = $run; E = $e }) } } }
    $ordered = @($items | Sort-Object { [datetime]$_.E.At } -Descending)
    $accountDeleted = $false; $steps = New-Object System.Collections.ArrayList; $n = 0
    $emptyShare = $null   # $true / $false / $null = not verifiable
    $acctEntry = @($ordered | Where-Object { $_.E.Type -eq 'account' -and $_.E.Action -eq 'Create' })[0]
    if ($acctEntry -and $Files -and $StorageToken) {
        $shEntry = @($ordered | Where-Object { $_.E.Type -eq 'share' -and $_.E.Action -eq 'Create' })[0]
        if ($shEntry -and ($shEntry.E.Path -match '/storageAccounts/([a-z0-9]{3,24})/fileServices/default/shares/([a-z0-9-]{3,63})$')) {
            try { $emptyShare = (@(Get-AVDTuneStorageProfileFolders -Files $Files -Account $Matches[1] -Share $Matches[2] -Token $StorageToken -Max 1)).Count -eq 0 } catch { $emptyShare = $null }
        }
    }
    foreach ($it in $ordered) {
        $e = $it.E; $path = [string]$e.Path
        $rule = Get-AVDTuneEnvWriteRule $path 'DELETE'
        $mk = { param($action, $reason, $method, $body, $changes) [pscustomobject]@{ Order = $steps.Count + 1; Id = $e.Id; Type = $e.Type; Title = "$action $($e.Id -replace '^env\.', '')"; Action = $action; Method = $method; Path = $path; Body = $body; Reason = $reason; Changes = @($changes) } }
        if ($e.Action -eq 'Update' -or ($e.Action -eq 'Create' -and $e.Type -in 'smb', 'identity')) {
            if ($accountDeleted -and $e.Type -in 'smb', 'identity', 'account', 'share') { [void]$steps.Add((& $mk 'Covered' 'Goes away with the storage account.' '' $null @())); continue }
            if ($null -eq $e.Before) { [void]$steps.Add((& $mk 'Keep' 'No previous value was recorded, so AVDTune cannot restore it.' '' $null @())); continue }
            $body = switch ($e.Type) { 'account' { @{ properties = $e.Before } } 'identity' { @{ properties = @{ azureFilesIdentityBasedAuthentication = @{ directoryServiceOptions = [string]$e.Before.directoryServiceOptions } } } } 'smb' { @{ properties = @{ protocolSettings = @{ smb = $e.Before } } } } default { $null } }
            if (-not $body) { [void]$steps.Add((& $mk 'Keep' 'This change cannot be undone by AVDTune.' '' $null @())); continue }
            $method = if ($e.Type -eq 'smb') { 'PUT' } else { 'PATCH' }
            [void]$steps.Add((& $mk 'Restore' '' $method $body @('back to the recorded values')))
            $steps[$steps.Count - 1].Path = "${path}?api-version=$script:StorageApi"
            continue
        }
        if ($e.Action -ne 'Create' -or -not $rule) { continue }
        $cur = $null
        try { $cur = Get-AVDTuneEnvResource -Arm $Arm -Token $Token -Path "${path}?api-version=$($rule.Api)" -What 'read the resource' } catch { [void]$steps.Add((& $mk 'Keep' "Cannot be checked: $($_.Exception.Message)" '' $null @())); continue }
        if (-not $cur.Exists) { [void]$steps.Add((& $mk 'Gone' 'The resource no longer exists.' '' $null @())); if ($e.Type -eq 'account') { $accountDeleted = $true }; continue }
        if ($e.Taggable) {
            $tag = [string](Get-AVDTuneProp (Get-AVDTuneProp $cur.Body 'tags') 'CreatedWith')
            if ($tag -ne 'AVDTune') { [void]$steps.Add((& $mk 'Keep' 'The resource does not carry the tag CreatedWith=AVDTune: it is not AVDTune''s to delete.' '' $null @())); continue }
        }
        elseif ($e.Status -ne 'Done') { [void]$steps.Add((& $mk 'Keep' 'The creation did not finish cleanly and the resource has no tags to prove it is AVDTune''s.' '' $null @())); continue }
        if ($e.Type -in 'share', 'account') {
            if ($null -eq $emptyShare) { [void]$steps.Add((& $mk 'Keep' 'AVDTune cannot verify that the share is empty (no storage token): profile data would be lost. Delete it by hand when you are sure.' '' $null @())); continue }
            if (-not $emptyShare) { [void]$steps.Add((& $mk 'Keep' 'The share holds data (profile folders): it is not deleted.' '' $null @())); continue }
        }
        if ($e.Type -eq 'dnszone') {
            $recs = [int](Get-AVDTuneProp (Get-AVDTuneProp $cur.Body 'properties') 'numberOfRecordSets')
            $ours = @($ordered | Where-Object { $_.E.Type -eq 'dnsgroup' -and $_.E.Action -eq 'Create' }).Count   # the A record of our own zone group goes away before the zone is looked at again
            if ($recs -gt 1 + $ours) { [void]$steps.Add((& $mk 'Keep' "The zone holds $recs record sets: other storage accounts may use it." '' $null @())); continue }
        }
        if ($e.Type -eq 'account') { $accountDeleted = $true }
        [void]$steps.Add((& $mk 'Delete' '' 'DELETE' $null @()))
        $steps[$steps.Count - 1].Path = "${path}?api-version=$($rule.Api)"
    }
    # settings of an account that is deleted go with it (also those found before the account step in the reverse order)
    if (@($steps | Where-Object { $_.Type -eq 'account' -and $_.Action -eq 'Delete' }).Count -gt 0) {
        foreach ($st in @($steps | Where-Object { $_.Type -in 'smb', 'identity', 'account' -and $_.Action -in 'Keep', 'Restore' })) { $st.Action = 'Covered'; $st.Method = ''; $st.Body = $null; $st.Reason = 'Goes away with the storage account.'; $st.Title = "Covered $($st.Id -replace '^env\.', '')" }
    }
    [pscustomobject]@{ Steps = @($steps); Hash = (Get-AVDTuneEnvHash (ConvertTo-AVDTuneEnvCanonical @($steps | ForEach-Object { @{ Id = $_.Id; Action = $_.Action; Method = $_.Method; Path = $_.Path; Body = $_.Body } }))); Count = @($steps | Where-Object { $_.Action -in 'Delete', 'Restore' }).Count }
}

function Invoke-AVDTuneEnvUndo {
    <# Takes back what the undo plan lists, after the confirmation of its hash; same gate, LastChange and change log rules as the apply. Returns @{ Status; Message; Results }. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Arm, [Parameter(Mandatory)][string]$Token, [string]$ConfirmedHash, [string]$Root = (Get-AVDTuneRoot), $Files, [string]$StorageToken, [string]$User, [string]$SnapshotId, [int]$PollSeconds = 5, [int]$TimeoutSeconds = 900, [int]$MaxPolls = 400)
    if (-not (Test-AVDTuneWriteAllowed)) { throw 'The snapshot gate is not confirmed: AVDTune is read only until a snapshot newer than its last change is confirmed on the Overview.' }
    $plan = Get-AVDTuneEnvUndoPlan -Arm $Arm -Token $Token -Root $Root -Files $Files -StorageToken $StorageToken
    if (-not $ConfirmedHash -or $plan.Hash -ne $ConfirmedHash) { return [pscustomobject]@{ Status = 'Refused'; Message = 'The undo plan differs from the one that was confirmed (or nothing was confirmed). Nothing was changed.'; Results = @(); Plan = $plan } }
    $todo = @($plan.Steps | Where-Object { $_.Action -in 'Delete', 'Restore' })
    if ($todo.Count -eq 0) { return [pscustomobject]@{ Status = 'Unchanged'; Message = 'There is nothing AVDTune may take back.'; Results = @(); Plan = $plan } }
    [void](Set-AVDTuneState -Root $Root -Values @{ LastChange = (Get-Date).ToString('o') })
    $journal = Get-AVDTuneEnvJournal -Root $Root
    $state = Get-AVDTuneState $Root
    $results = New-Object System.Collections.ArrayList; $stopped = $false
    foreach ($s in $todo) {
        if ($stopped) { [void]$results.Add([pscustomobject]@{ Id = $s.Id; Title = $s.Title; Status = 'Skipped'; Message = 'An earlier step failed.' }); continue }
        $role = if ($s.Type -eq 'role') { 'User Access Administrator or Role Based Access Control Administrator' } else { 'Contributor on the resource group' }
        if ($s.Type -eq 'dnszone' -and $s.Action -eq 'Delete') {
            $z = Get-AVDTuneEnvResource -Arm $Arm -Token $Token -Path $s.Path -What 'read the DNS zone'   # the records of the endpoint are gone by now: only SOA may be left
            if ($z.Exists -and [int](Get-AVDTuneProp (Get-AVDTuneProp $z.Body 'properties') 'numberOfRecordSets') -gt 1) { [void]$results.Add([pscustomobject]@{ Id = $s.Id; Title = $s.Title; Status = 'Unchanged'; Message = 'The zone holds other records and stays.' }); continue }
        }
        $w = Invoke-AVDTuneEnvWrite -Arm $Arm -Token $Token -Method $s.Method -Path $s.Path -Body $s.Body -What $s.Title -Role $role -PollSeconds $PollSeconds -TimeoutSeconds $TimeoutSeconds -MaxPolls $MaxPolls
        if ($w.Ok) {
            foreach ($run in @($journal.Runs)) { foreach ($e in @($run.Steps)) { if ($e -and $e.Id -eq $s.Id -and ([string]$e.Path -eq ($s.Path -split '\?')[0])) { $e.Undone = $true } } }
            [void]$results.Add([pscustomobject]@{ Id = $s.Id; Title = $s.Title; Status = 'Reverted'; Message = '' })
            if ($state.ImageVersion) { [void](Add-AVDTuneChangeLogEntry -Root $Root -Version $state.ImageVersion -Category 'FSLogix' -Component "Azure: $($s.Type)" -ChangeType $(if ($s.Action -eq 'Delete') { 'Removed' } else { 'Changed' }) -Text "Undo: $($s.Title)" -User $User -SnapshotId $SnapshotId -Source Step) }
        }
        else { $stopped = $true; [void]$results.Add([pscustomobject]@{ Id = $s.Id; Title = $s.Title; Status = 'Failed'; Message = $w.Message }) }
        Save-AVDTuneEnvJournal $Root $journal
    }
    $failed = @($results | Where-Object Status -eq 'Failed').Count -gt 0
    $slim = @($results | ForEach-Object { [pscustomobject]@{ Id = $_.Id; Section = 'FSLogix'; Title = $_.Title; Mode = 'Undo'; Status = $_.Status; Before = $null; After = $null; Message = $_.Message; Reboot = $false; WhatIf = $false; At = (Get-Date).ToString('o') } })
    $now = (Get-Date).ToString('o')
    [void](Add-AVDTuneRun -Root $Root -Run ([pscustomobject][ordered]@{ Id = $null; Plan = 'Environment-Azure-Undo'; Kind = 'Environment-Azure'; Started = $now; Ended = $now; User = $User; SnapshotId = $SnapshotId; WhatIf = $false; ImageVersion = $state.ImageVersion; Reboot = $false; Results = $slim }))
    [pscustomobject]@{ Status = $(if ($failed) { 'Failed' } else { 'Reverted' }); Message = $(if ($failed) { 'Stopped at the first failure: ' + (@($results | Where-Object Status -eq 'Failed')[0].Message) } else { "Taken back: $(@($results | Where-Object Status -eq 'Reverted').Count) step(s)." }); Results = @($results); Plan = $plan }
}

#endregion

#region master, ACL and test: thin links to the existing steps

function Get-AVDTuneEnvMasterValues {
    <# The FSLogix settings of the master for this share (Set-AVDTuneFSLogixSettings takes them) and the registry value of Entra Kerberos clients. #>
    param([Parameter(Mandatory)]$Spec, [Parameter(Mandatory)][string]$Identity)
    $reg = @()
    if ($Identity -eq 'EntraKerberos') { $reg = @([pscustomobject]@{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\Kerberos\Parameters'; Name = 'CloudKerberosTicketRetrievalEnabled'; Value = 1; Type = 'DWord'; Source = "$script:LearnFiles/storage-files-identity-auth-hybrid-identities-enable"; Verified = $true }) }
    [pscustomobject]@{ Values = @{ 'Profile:Enabled' = 1; 'Profile:VHDLocations' = @(Get-AVDTuneEnvVhdLocation $Spec) }; Registry = $reg }
}

function Set-AVDTuneEnvMaster {
    <# FSLogix on the master through the existing steps (snapshot gate, run record, change log, LastChange). -WhatIf changes nothing. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Machine, [Parameter(Mandatory)]$Spec, [Parameter(Mandatory)][string]$Identity, [string]$Root = (Get-AVDTuneRoot), [string]$User, [string]$SnapshotId, [switch]$WhatIf)
    $v = Get-AVDTuneEnvMasterValues -Spec $Spec -Identity $Identity
    $runs = @(Set-AVDTuneFSLogixSettings -Machine $Machine -Root $Root -Values $v.Values -User $User -SnapshotId $SnapshotId -WhatIf:$WhatIf)
    foreach ($r in $v.Registry) {
        $step = New-AVDTuneFSLogixRegStep -Id 'fslogix.kerberos.cloudticket' -Path $r.Path -Name $r.Name -Value $r.Value -Type $r.Type -Title 'Allow the cloud Kerberos ticket (Entra Kerberos)' -SourceUrl $r.Source -Why 'The client asks Microsoft Entra ID for the Kerberos ticket of the share.'
        $runs += Invoke-AVDTune -Plan ([pscustomobject]@{ Name = 'Entra Kerberos client'; Steps = @($step.Id) }) -Catalog @($step) -Machine $Machine -Root $Root -User $User -SnapshotId $SnapshotId -WhatIf:$WhatIf
    }
    $runs
}

function Get-AVDTuneEnvAclDiff {
    <# The diff of the share root with Microsoft's recommendation (existing ACL logic, data plane with the storage token); groups by object ID become Entra SIDs. #>
    param([Parameter(Mandatory)]$Files, [Parameter(Mandatory)][string]$StorageToken, [Parameter(Mandatory)]$Spec)
    $cur = Get-AVDTuneStorageShareAcl -Files $Files -Account ([string]$Spec.AccountName) -Share ([string]$Spec.ShareName) -Token $StorageToken
    if (-not $cur.Ok) { return [pscustomobject]@{ Ok = $false; Message = "The ACL of the root cannot be read: $($cur.Error)"; Diff = $null } }
    $diff = Get-AVDTuneStorageAclDiff -FoundSddl $cur.Sddl -UsersSid (ConvertTo-AVDTuneEntraSid ([string]$Spec.UsersGroupId)) -AdminsSid (ConvertTo-AVDTuneEntraSid ([string]$Spec.AdminsGroupId)) -Account ([string]$Spec.AccountName) -Share ([string]$Spec.ShareName)
    [pscustomobject]@{ Ok = $true; Message = ''; Diff = $diff }
}

function Invoke-AVDTuneEnvVerify {
    <# The test of the setup: the storage check of the FSLogix page (identity, SMB, DNS, roles, ACL) for the new share. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Machine, [Parameter(Mandatory)]$F, [Parameter(Mandatory)]$Spec, $Arm, [string]$ArmToken, $Files, [string]$StorageToken, $Ldap, $LdapConnection, [string]$DefaultNamingContext, [string]$CallerOid, [string]$DomainController)
    $p = @{ Machine = $Machine; F = $F; Locations = @(Get-AVDTuneEnvVhdLocation $Spec); SubscriptionIds = @([string]$Spec.SubscriptionId) }
    foreach ($k in 'Arm', 'ArmToken', 'Files', 'StorageToken', 'Ldap', 'LdapConnection', 'DefaultNamingContext', 'CallerOid', 'DomainController') { $v = Get-Variable $k -ValueOnly; if ($v) { $p[$k] = $v } }
    Invoke-AVDTuneStorageCheck @p
}

#endregion

Export-ModuleMember -Function Test-AVDTuneEnvSegment, Test-AVDTuneEnvGuid, Test-AVDTuneEnvSubnetId, Get-AVDTuneEnvVNetId, Get-AVDTuneEnvQuota, Test-AVDTuneEnvSpec, Get-AVDTuneEnvVhdLocation, ConvertTo-AVDTuneEntraSid,
    Get-AVDTuneEnvIdentityModel, Assert-AVDTuneEnvArmPath, Invoke-AVDTuneEnvArmRaw, ConvertTo-AVDTuneEnvArmError, Get-AVDTuneEnvResource, Wait-AVDTuneEnvOperation, Invoke-AVDTuneEnvWrite,
    ConvertTo-AVDTuneEnvCanonical, Get-AVDTuneEnvRoleName, Get-AVDTuneEnvRights, Get-AVDTuneEnvPlan, Get-AVDTuneEnvJournal, Invoke-AVDTuneEnvApply, Get-AVDTuneEnvUndoPlan, Invoke-AVDTuneEnvUndo,
    Get-AVDTuneEnvMasterValues, Set-AVDTuneEnvMaster, Get-AVDTuneEnvAclDiff, Invoke-AVDTuneEnvVerify
