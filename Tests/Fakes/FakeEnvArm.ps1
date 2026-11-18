# Fake Azure Resource Manager for the environment wizard (Modules\AVDTune.Environment.psm1): a small stateful resource store with the routes the setup uses
# (storage account, file service, share, private endpoint with zone group, private DNS zone and VNet link, role assignments, permissions, subnet and VNet) and the answers
# Azure really gives: 201/202 with Azure-AsyncOperation or Location headers and a status URL that says InProgress a few times before Succeeded or Failed, Retry-After, and
# the errors 400 (invalid body), 403 (AuthorizationFailed), 404, 409 (name taken, role assignment exists, another operation in progress). In memory, no network, no tenant.
# Every call is in .Log (method and path, never a token). All names and IDs are made up.
#
# Seed keys: Sub, Resources (hashtable lower case path -> body), Permissions (array of @{ actions; notActions }), Roles (array of @{ Scope; Principal; Role; Name }),
#   TakenNames (storage account names that exist elsewhere), Polls (how many InProgress answers an operation gives), Offline, ForbidWrite (array of type ids: account smb share endpoint dnsgroup dnszone dnslink role),
#   FailAsync (array of type ids whose operation ends Failed), NeverFinish (type ids whose operation stays InProgress), Busy (type ids that answer 409 AnotherOperationInProgress),
#   Invalid (type ids that answer 400), NoHeaders ($true: asynchronous answers without headers, the caller has to poll the resource), ExtraRecords (record sets of the DNS zone besides SOA and ours),
#   ForbidPermissions, ForbidRead (type ids whose GET answers 403)
. $(if (Get-Command Resolve-AVDTuneTestScript -ErrorAction Ignore) { $fakeShared = Resolve-AVDTuneTestScript -Path (Join-Path $PSScriptRoot 'FakeShared.ps1') -AppRoot (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent); if (-not $fakeShared) { throw 'FakeShared.ps1 is not a file below the Tests folder of this copy.' }; $fakeShared } else { Join-Path $PSScriptRoot 'FakeShared.ps1' })   # fakes that several runspaces use at once (#80), through the test script gate when the module is loaded
$script:EnvSub = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
function ConvertTo-EnvJson($Object) { if ($null -eq $Object) { return $null }; $Object | ConvertTo-Json -Depth 12 | ConvertFrom-Json }

function New-AVDTuneFakeEnvArm {
    param([hashtable]$Seed = @{})
    $s = @{ Sub = $script:EnvSub; Resources = @{}; Permissions = @(@{ actions = @('*'); notActions = @() }); Roles = @(); TakenNames = @(); Polls = 2; Offline = $false; ForbidWrite = @(); FailAsync = @(); NeverFinish = @(); Busy = @(); Invalid = @()
        NoHeaders = $false; ExtraRecords = 0; ForbidPermissions = $false; ForbidRead = @(); Ops = @{}; Log = (New-Object System.Collections.ArrayList); Writes = (New-Object System.Collections.ArrayList); Seq = 0 }
    foreach ($e in $Seed.GetEnumerator()) { $s[$e.Key] = $e.Value }
    # a default network: one VNet with one subnet
    $vnet = "/subscriptions/$($s.Sub)/resourcegroups/rg-network/providers/microsoft.network/virtualnetworks/vnet-avd"
    if (-not $s.Resources.ContainsKey($vnet)) { $s.Resources[$vnet] = @{ name = 'vnet-avd'; location = 'westeurope'; properties = @{ provisioningState = 'Succeeded' } } }
    if (-not $s.Resources.ContainsKey("$vnet/subnets/snet-avd")) { $s.Resources["$vnet/subnets/snet-avd"] = @{ name = 'snet-avd'; properties = @{ provisioningState = 'Succeeded' } } }
    $a = [ordered]@{ Kind = 'Fake'; Store = $s; Log = $s.Log }
    $a.Invoke = {
        param($Method, $Path, $Token, $Body)
        [void]$s.Log.Add("$Method $Path")
        $resp = { param($status, $body, $headers, $err) [pscustomobject]@{ Status = $status; Headers = $(if ($headers) { $headers } else { @{} }); Body = (ConvertTo-EnvJson $body); Error = $(if ($err) { $err } else { '' }) } }
        $fail = { param($status, $code, $msg) & $resp $status @{ error = @{ code = $code; message = $msg } } $null '' }
        if (-not $Token) { return (& $resp 401 $null $null 'no token') }
        if ($s.Offline) { return (& $resp 0 $null $null 'The remote name could not be resolved: management.azure.com') }
        $p = $Path.Split('?')[0]; $lower = $p.ToLowerInvariant()
        $type = if ($lower -match '/storageaccounts/[a-z0-9]+/fileservices/default/fileshares/[^/]+/providers/microsoft\.authorization/roleassignments/') { 'role' }
        elseif ($lower -match '/storageaccounts/[a-z0-9]+/fileservices/default/shares/') { 'share' }
        elseif ($lower -match '/storageaccounts/[a-z0-9]+/fileservices/default$') { 'smb' }
        elseif ($lower -match '/storageaccounts/[a-z0-9]+$') { 'account' }
        elseif ($lower -match '/privateendpoints/[^/]+/privatednszonegroups/') { 'dnsgroup' }
        elseif ($lower -match '/privateendpoints/[^/]+$') { 'endpoint' }
        elseif ($lower -match '/virtualnetworklinks/') { 'dnslink' }
        elseif ($lower -match '/privatednszones/[^/]+$') { 'dnszone' }
        else { '' }
        # status URLs of asynchronous operations
        if ($Method -eq 'GET' -and $lower -match '/(asyncoperations|operations)/(op[0-9]+)$') {
            $op = $s.Ops[$Matches[2]]
            if (-not $op) { return (& $fail 404 'NotFound' 'operation not found') }
            if ($op.Left -gt 0 -or $op.Never) { if (-not $op.Never) { $op.Left-- }; $h = @{ 'Retry-After' = '1' }
                if ($op.Mode -eq 'Location') { return (& $resp 202 $null $h '') }
                return (& $resp 200 @{ status = 'InProgress' } $h '') }
            if ($op.Fail) { return $(if ($op.Mode -eq 'Location') { & $fail 400 'OperationFailed' 'The operation failed in the fake.' } else { & $resp 200 @{ status = 'Failed'; error = @{ code = 'InternalServerError'; message = 'The operation failed in the fake.' } } $null '' }) }
            return $(if ($op.Mode -eq 'Location') { & $resp 200 @{ name = 'done' } $null '' } else { & $resp 200 @{ status = 'Succeeded' } $null '' })
        }
        if ($Method -eq 'GET' -and $lower -like '*/providers/microsoft.authorization/permissions') {
            if ($s.ForbidPermissions) { return (& $fail 403 'AuthorizationFailed' 'does not have authorization to perform action Microsoft.Authorization/permissions/read') }
            return (& $resp 200 @{ value = @($s.Permissions) } $null '')
        }
        if ($Method -eq 'GET' -and $lower -eq "/subscriptions/$($s.Sub)/providers/microsoft.storage/storageaccounts") {
            $list = @($s.Resources.Keys | Where-Object { $_ -match '/storageaccounts/[a-z0-9]+$' } | ForEach-Object { $o = ConvertTo-EnvJson $s.Resources[$_]; Add-Member -InputObject $o -NotePropertyName id -NotePropertyValue $_ -Force; $o })
            return (& $resp 200 @{ value = $list } $null '')
        }
        if ($Method -eq 'GET' -and $lower -match '^(.*/storageaccounts/[a-z0-9]+)/fileservices/default/shares$') {
            $pre = $Matches[1] + '/fileservices/default/shares/'
            $list = @($s.Resources.Keys | Where-Object { $_.StartsWith($pre) -and $_.Substring($pre.Length) -notmatch '/' } | ForEach-Object { @{ name = $_.Substring($pre.Length); properties = @{ shareQuota = 100 } } })
            return (& $resp 200 @{ value = $list } $null '')
        }
        if ($Method -eq 'GET' -and $lower -match '/providers/microsoft\.authorization/roleassignments$') {
            $scope = $lower -replace '/providers/microsoft\.authorization/roleassignments$', ''
            $list = @($s.Roles | Where-Object { ([string]$_.Scope).ToLowerInvariant() -eq $scope } | ForEach-Object { @{ name = $_.Name; properties = @{ roleDefinitionId = "/subscriptions/$($s.Sub)/providers/Microsoft.Authorization/roleDefinitions/$($_.Role)"; principalId = $_.Principal; scope = $_.Scope } } })
            return (& $resp 200 @{ value = $list } $null '')
        }
        if ($Method -eq 'GET') {
            if ($type -in @($s.ForbidRead)) { return (& $fail 403 'AuthorizationFailed' "does not have authorization to read this $type") }
            if ($s.Resources.ContainsKey($lower)) {
                $r = $s.Resources[$lower]
                if ($type -eq 'dnszone') { $r = ConvertTo-EnvJson $r; Add-Member -InputObject $r.properties -NotePropertyName numberOfRecordSets -NotePropertyValue (1 + $s.ExtraRecords + @($s.Resources.Keys | Where-Object { $_ -like '*/privatednszonegroups/default' }).Count) -Force }
                return (& $resp 200 $r $null '')
            }
            return (& $fail 404 'ResourceNotFound' 'The resource was not found.')
        }
        # writes
        [void]$s.Writes.Add("$Method $p")
        if ($type -in @($s.ForbidWrite)) { return (& $fail 403 'AuthorizationFailed' "The client does not have authorization to perform action on scope $p (fake)") }
        if ($type -in @($s.Busy)) { return (& $fail 409 'AnotherOperationInProgress' 'Another operation on this resource is in progress.') }
        if ($Method -eq 'DELETE') {
            if (-not $s.Resources.ContainsKey($lower)) { if ($type -eq 'role') { return (& $resp 204 $null $null '') }; return (& $resp 204 $null $null '') }
            foreach ($k in @($s.Resources.Keys | Where-Object { $_ -eq $lower -or $_.StartsWith($lower + '/') })) { $s.Resources.Remove($k) }
            foreach ($rl in @($s.Roles | Where-Object { ([string]$_.Name) -and $lower.EndsWith(([string]$_.Name).ToLowerInvariant()) })) { $s.Roles = @($s.Roles | Where-Object { $_ -ne $rl }) }
            if ($type -eq 'endpoint') { $s.Seq++; $id = "op$($s.Seq)"; $s.Ops[$id] = @{ Left = $s.Polls; Mode = 'Location'; Fail = $false; Never = $false }; return (& $resp 202 $null @{ Location = "https://management.azure.com/subscriptions/$($s.Sub)/providers/Microsoft.Network/locations/westeurope/operations/$id`?api-version=2023-11-01" } '') }
            return (& $resp 200 $null $null '')
        }
        if ($type -in @($s.Invalid)) { return (& $fail 400 'InvalidRequestContent' 'The request content was invalid and could not be deserialized (fake).') }
        $b = ConvertTo-EnvJson $Body
        if ($type -eq 'account') {
            $name = ($lower -split '/')[-1]
            if (-not $s.Resources.ContainsKey($lower) -and $name -in @($s.TakenNames)) { return (& $fail 409 'StorageAccountAlreadyExists' "The storage account named $name is already taken.") }
            if ($Method -eq 'PUT') {
                if ($b.kind -eq 'FileStorage' -and $b.sku.name -notlike 'Premium_*') { return (& $fail 400 'SkuNameInvalid' 'The sku name is not valid for kind FileStorage (fake).') }
                if ($b.location -notmatch '^[a-z0-9]+$') { return (& $fail 400 'LocationNotAvailableForResourceType' 'The location is not available (fake).') }
            }
        }
        if ($type -eq 'role') {
            $scope = $lower -replace '/providers/microsoft\.authorization/roleassignments/.*$', ''
            $role = ([string]$b.properties.roleDefinitionId -split '/')[-1]
            $dup = @($s.Roles | Where-Object { ([string]$_.Scope).ToLowerInvariant() -eq $scope -and $_.Principal -eq $b.properties.principalId -and $_.Role -eq $role -and ([string]$_.Name) -ne ($lower -split '/')[-1] })
            if ($dup.Count -gt 0) { return (& $fail 409 'RoleAssignmentExists' 'The role assignment already exists.') }
            $s.Roles = @($s.Roles) + @{ Scope = ($p -replace '/providers/Microsoft\.Authorization/roleAssignments/.*$', ''); Principal = [string]$b.properties.principalId; Role = $role; Name = ($lower -split '/')[-1] }
            $s.Seq++; $s.Resources[$lower] = @{ name = ($lower -split '/')[-1]; properties = $b.properties; systemData = @{ createdAt = [DateTime]::UtcNow.ToString('o') } }
            return (& $resp 201 @{ name = ($lower -split '/')[-1]; properties = $b.properties } $null '')
        }
        # PUT or PATCH of a resource: merge for PATCH, replace for PUT
        $existing = if ($s.Resources.ContainsKey($lower)) { ConvertTo-EnvJson $s.Resources[$lower] } else { $null }
        $name = ($p -split '/')[-1]
        $new = if ($Method -eq 'PATCH' -and $existing) {
            $m = $existing
            foreach ($prop in $b.PSObject.Properties) {
                if ($prop.Name -eq 'properties' -and $m.PSObject.Properties['properties']) { foreach ($pp in $prop.Value.PSObject.Properties) { if ($m.properties.PSObject.Properties[$pp.Name]) { $m.properties.($pp.Name) = $pp.Value } else { Add-Member -InputObject $m.properties -NotePropertyName $pp.Name -NotePropertyValue $pp.Value } } }
                elseif ($m.PSObject.Properties[$prop.Name]) { $m.($prop.Name) = $prop.Value } else { Add-Member -InputObject $m -NotePropertyName $prop.Name -NotePropertyValue $prop.Value }
            }
            $m
        } else { $b }
        if ($new.PSObject.Properties['name'] -eq $null) { Add-Member -InputObject $new -NotePropertyName name -NotePropertyValue $name }
        if (-not $new.PSObject.Properties['properties']) { Add-Member -InputObject $new -NotePropertyName properties -NotePropertyValue ([pscustomobject]@{}) }
        if (-not $new.properties.PSObject.Properties['provisioningState']) { Add-Member -InputObject $new.properties -NotePropertyName provisioningState -NotePropertyValue 'Succeeded' }
        if ($type -eq 'account' -and -not $new.properties.PSObject.Properties['primaryEndpoints']) { Add-Member -InputObject $new.properties -NotePropertyName primaryEndpoints -NotePropertyValue ([pscustomobject]@{ file = "https://$name.file.core.windows.net/" }) }
        # what identifies the resource over its life: kept on every later PUT or PATCH, new on a create (the real time now: the module compares it with the start of its own PUT)
        if ($existing -and $existing.PSObject.Properties['systemData']) { Add-Member -InputObject $new -NotePropertyName systemData -NotePropertyValue $existing.systemData -Force }
        else { $s.Seq++; Add-Member -InputObject $new -NotePropertyName systemData -NotePropertyValue ([pscustomobject]@{ createdAt = [DateTime]::UtcNow.ToString('o') }) -Force }
        $s.Resources[$lower] = $new
        $status = if ($existing) { 200 } else { 201 }
        $async = $null
        if ($type -in 'account', 'dnszone', 'dnslink') { $status = 202; $async = if ($type -eq 'account') { 'Location' } else { 'AzureAsyncOperation' } }
        if ($type -eq 'endpoint' -or $type -eq 'dnsgroup') { $async = 'AzureAsyncOperation' }
        if ($existing -and $type -in 'smb', 'share') { $async = $null }
        if ($async) {
            $s.Seq++; $id = "op$($s.Seq)"
            $fail1 = $type -in @($s.FailAsync)
            $s.Ops[$id] = @{ Left = $s.Polls; Mode = $async; Fail = $fail1; Never = ($type -in @($s.NeverFinish)) }
            if ($fail1) { $s.Resources.Remove($lower) }
            if ($s.NoHeaders) { return (& $resp $(if ($status -eq 200) { 202 } else { $status }) $null $null '') }
            $host_ = "https://management.azure.com/subscriptions/$($s.Sub)/providers"
            $h = if ($async -eq 'Location') { @{ Location = "$host_/Microsoft.Storage/locations/westeurope/asyncoperations/$id`?monitor=true&api-version=2024-01-01"; 'Retry-After' = '1' } } else { @{ 'Azure-AsyncOperation' = "$host_/Microsoft.Network/locations/westeurope/operations/$id`?api-version=2023-11-01" } }
            return (& $resp $status $(if ($status -eq 201) { $new } else { $null }) $h '')
        }
        (& $resp $status $new $null '')
    }.GetNewClosure()
    ConvertTo-AVDTuneFakeShared ([pscustomobject]$a)
}
