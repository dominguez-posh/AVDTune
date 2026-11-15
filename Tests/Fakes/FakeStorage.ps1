# Fakes for the storage check (Modules\AVDTune.Storage.psm1): Azure Resource Manager routes of Microsoft.Storage and role assignments (New-AVDTuneFakeStorageArm), the file
# share data plane (New-AVDTuneFakeFiles) and an LDAP adapter that answers the storage account's AD object and the domain (New-AVDTuneFakeStorageLdap). In memory, no network,
# no tenant. Every call is in .Log (method and URL, never a token or a key). All names are made up (stfake01, example.test, contoso).

$script:StSub = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
function ConvertTo-StJson($Object) { $Object | ConvertTo-Json -Depth 12 | ConvertFrom-Json }

# Seed: Accounts (array of @{ Name; Rg; Kind; Sku; Props = hashtable merged into properties; FileService = @{ Smb = @{ versions; authenticationMethods; kerberosTicketEncryption; channelEncryption } };
#   Roles = array of @{ Role (guid); Principal } }), Sub. Switches in .Store: Offline, ListForbidden, FileServiceForbidden, RolesForbidden, KeysForbidden, Pages (nextLink on the list), FakeKey
function New-AVDTuneFakeStorageArm {
    param([hashtable]$Seed = @{})
    $s = @{ Offline = $false; ListForbidden = $false; FileServiceForbidden = $false; RolesForbidden = $false; KeysForbidden = $false; Pages = $false; FakeKey = 'ZmFrZS1rZXktdmFsdWUtZm9yLXRlc3Rz'; Sub = $script:StSub
        Accounts = @(); Log = (New-Object System.Collections.ArrayList); KeyRequests = 0 }
    foreach ($e in $Seed.GetEnumerator()) { $s[$e.Key] = $e.Value }
    $a = [ordered]@{ Kind = 'Fake'; Store = $s; Log = $s.Log }
    $a.Invoke = {
        param($Method, $Path, $Token, $Body)
        [void]$s.Log.Add("$Method $Path")
        if (-not $Token) { return [pscustomobject]@{ Status = 401; Body = $null; Error = 'no token' } }
        if ($s.Offline) { return [pscustomobject]@{ Status = 0; Body = $null; Error = 'The remote name could not be resolved: management.azure.com' } }
        $p = $Path.Split('?')[0]; $lower = $p.ToLowerInvariant()
        $forbid = { [pscustomobject]@{ Status = 403; Body = (ConvertTo-StJson @{ error = @{ code = 'AuthorizationFailed'; message = 'does not have authorization to perform action' } }); Error = '' } }
        if ($Method -eq 'GET' -and $lower -eq "/subscriptions/$($s.Sub)/providers/microsoft.storage/storageaccounts") {
            if ($s.ListForbidden) { return (& $forbid) }
            $list = @($s.Accounts | ForEach-Object {
                    $props = @{ primaryEndpoints = @{ file = "https://$($_.Name).file.core.windows.net/" } }
                    if ($_.Props) { foreach ($k in $_.Props.Keys) { $props[$k] = $_.Props[$k] } }
                    @{ id = "/subscriptions/$($s.Sub)/resourceGroups/$($_.Rg)/providers/Microsoft.Storage/storageAccounts/$($_.Name)"; name = $_.Name; kind = $(if ($_.Kind) { $_.Kind } else { 'FileStorage' }); sku = @{ name = $(if ($_.Sku) { $_.Sku } else { 'Premium_LRS' }) }; properties = $props } })
            if ($s.Pages -and $Path -notlike '*page2*') { return [pscustomobject]@{ Status = 200; Body = (ConvertTo-StJson @{ value = @(); nextLink = "https://management.azure.com$p`?api-version=2024-01-01&page2=1" }); Error = '' } }
            return [pscustomobject]@{ Status = 200; Body = (ConvertTo-StJson @{ value = $list }); Error = '' }
        }
        if ($lower -match '/providers/microsoft\.storage/storageaccounts/([a-z0-9]+)/(fileservices/default|providers/microsoft\.authorization/roleassignments|listkeys)$') {
            $name = $Matches[1]; $kind = $Matches[2]
            $acc = @($s.Accounts | Where-Object { $_.Name -eq $name })
            if ($acc.Count -eq 0) { return [pscustomobject]@{ Status = 404; Body = $null; Error = 'not found' } }
            if ($kind -eq 'fileservices/default' -and $Method -eq 'GET') {
                if ($s.FileServiceForbidden) { return (& $forbid) }
                $smb = if ($acc[0].FileService) { $acc[0].FileService } else { @{ versions = 'SMB3.0;SMB3.1.1'; authenticationMethods = 'NTLMv2;Kerberos'; kerberosTicketEncryption = 'AES-256'; channelEncryption = 'AES-128-GCM;AES-256-GCM' } }
                return [pscustomobject]@{ Status = 200; Body = (ConvertTo-StJson @{ properties = @{ protocolSettings = @{ smb = $smb } } }); Error = '' }
            }
            if ($kind -like '*roleassignments' -and $Method -eq 'GET') {
                if ($s.RolesForbidden) { return (& $forbid) }
                $ra = @(@($acc[0].Roles) | Where-Object { $_ } | ForEach-Object { @{ properties = @{ roleDefinitionId = "/providers/Microsoft.Authorization/roleDefinitions/$($_.Role)"; principalId = $_.Principal; scope = $p } } })
                return [pscustomobject]@{ Status = 200; Body = (ConvertTo-StJson @{ value = $ra }); Error = '' }
            }
            if ($kind -eq 'listkeys' -and $Method -eq 'POST') {
                $s.KeyRequests++
                if ($s.KeysForbidden) { return (& $forbid) }
                return [pscustomobject]@{ Status = 200; Body = (ConvertTo-StJson @{ keys = @(@{ keyName = 'key1'; value = $s.FakeKey; permissions = 'FULL' }) }); Error = '' }
            }
        }
        [pscustomobject]@{ Status = 404; Body = $null; Error = "fake: no route for $Method $p" }
    }.GetNewClosure()
    [pscustomobject]$a
}

# Seed: Acls (hashtable path ('' = root) -> SDDL), Folders (array of names). Switches in .Store: Offline, Forbidden (403 on the data plane), PutForbidden, ChangeOnRead (the root ACL changes after the first read: tests the confirmed diff), NoKeyHeader
function New-AVDTuneFakeFiles {
    param([hashtable]$Seed = @{})
    $s = @{ Offline = $false; Forbidden = $false; PutForbidden = $false; ChangeOnRead = $null; NoKeyHeader = $false; Acls = @{}; Folders = @(); Log = (New-Object System.Collections.ArrayList); Puts = (New-Object System.Collections.ArrayList); Reads = 0 }
    foreach ($e in $Seed.GetEnumerator()) { $s[$e.Key] = $e.Value }
    $a = [ordered]@{ Kind = 'Fake'; Store = $s; Log = $s.Log }
    $a.Invoke = {
        param($Method, $Url, $Token, $Headers, $Body)
        [void]$s.Log.Add("$Method $Url")
        $ok = { param($body, $headers) [pscustomobject]@{ Status = 200; Headers = $headers; Body = $body; Error = '' } }
        if ($s.Offline) { return [pscustomobject]@{ Status = 0; Headers = @{}; Body = ''; Error = 'The remote name could not be resolved' } }
        if (-not $Token) { return [pscustomobject]@{ Status = 401; Headers = @{}; Body = ''; Error = 'no token' } }
        if ($Headers['x-ms-file-request-intent'] -ne 'backup') { return [pscustomobject]@{ Status = 400; Headers = @{}; Body = ''; Error = 'x-ms-file-request-intent: backup is required with OAuth' } }
        if ($s.Forbidden) { return [pscustomobject]@{ Status = 403; Headers = @{}; Body = ''; Error = 'AuthorizationPermissionMismatch' } }
        if ($Url -notmatch '^https://([a-z0-9]+)\.file\.core\.windows\.net/([^/?]+)(?:/([^?]*))?\?(.*)$') { return [pscustomobject]@{ Status = 400; Headers = @{}; Body = ''; Error = 'fake: bad url' } }
        $path = if ($Matches.Count -gt 3 -and $Matches[3]) { $Matches[3] } else { '' }; $query = $Matches[4]
        if ($Method -eq 'GET' -and $query -eq 'restype=directory') {
            if ($path -and -not ($path -in @($s.Folders)) -and -not $s.Acls.ContainsKey($path)) { return [pscustomobject]@{ Status = 404; Headers = @{}; Body = ''; Error = 'ResourceNotFound' } }
            $hs = @{ 'x-ms-request-id' = 'req1' }; if (-not $s.NoKeyHeader) { $hs['x-ms-file-permission-key'] = "key-$path" }
            return (& $ok '' $hs)
        }
        if ($Method -eq 'GET' -and $query -eq 'restype=share&comp=filepermission') {
            $key = [string]$Headers['x-ms-file-permission-key']; $p = $key -replace '^key-', ''
            if (-not $s.Acls.ContainsKey($p)) { return [pscustomobject]@{ Status = 404; Headers = @{}; Body = ''; Error = 'PermissionNotFound' } }
            $s.Reads++
            $sddl = $s.Acls[$p]
            if ($s.ChangeOnRead -and $p -eq '' -and $s.Reads -ge 2) { $sddl = $s.ChangeOnRead }
            return (& $ok (@{ format = 'sddl'; permission = $sddl } | ConvertTo-Json -Compress) @{})
        }
        if ($Method -eq 'GET' -and $query -like 'restype=directory&comp=list*') {
            $x = '<?xml version="1.0" encoding="utf-8"?><EnumerationResults><Entries>' + ((@($s.Folders) | ForEach-Object { "<Directory><Name>$_</Name></Directory>" }) -join '') + '</Entries></EnumerationResults>'
            return (& $ok $x @{})
        }
        if ($Method -eq 'PUT' -and $query -eq 'restype=directory&comp=properties') {
            if ($s.PutForbidden) { return [pscustomobject]@{ Status = 403; Headers = @{}; Body = ''; Error = 'AuthorizationPermissionMismatch' } }
            [void]$s.Puts.Add(@{ Path = $path; Sddl = $Headers['x-ms-file-permission']; Attributes = $Headers['x-ms-file-attributes']; Created = $Headers['x-ms-file-creation-time'] })
            $s.Acls[$path] = [string]$Headers['x-ms-file-permission']
            return (& $ok '' @{})
        }
        [pscustomobject]@{ Status = 404; Headers = @{}; Body = ''; Error = "fake: no route for $Method $query" }
    }.GetNewClosure()
    [pscustomobject]$a
}

# Seed: Account (@{ Sam; Sid; Spns; PwdLastSet (datetime); Uac; EncTypes; Count }), Domain (@{ Sid; Guid; MaxPwdAgeDays }), Missing ($true: the object does not exist), Fail ($true: the search throws)
function New-AVDTuneFakeStorageLdap {
    param([hashtable]$Seed = @{})
    $sidBytes = { param($t) $b = New-Object byte[] 28; (New-Object Security.Principal.SecurityIdentifier $t).GetBinaryForm($b, 0); , $b }
    $s = @{ Account = @{ Sam = 'stfake01'; Sid = 'S-1-5-21-1-2-3-1500'; Spns = @('cifs/stfake01.file.core.windows.net'); PwdLastSet = [datetime]'2026-11-01'; Uac = 4096; EncTypes = 24 }
        Domain = @{ Sid = 'S-1-5-21-1-2-3'; Guid = '11111111-2222-3333-4444-555555555555'; MaxPwdAgeDays = 42 }; Missing = $false; Fail = $false; Duplicate = $false; Log = (New-Object System.Collections.ArrayList) }
    foreach ($e in $Seed.GetEnumerator()) { $s[$e.Key] = $e.Value }
    $a = [ordered]@{ Kind = 'Fake'; Store = $s; Log = $s.Log }
    $a.Search = {
        param($Conn, $BaseDn, $Filter, $Scope, $Attributes)
        [void]$s.Log.Add("Search $Scope $BaseDn $Filter")
        if ($s.Fail) { throw 'The server returned an error.' }
        $mk = { param($attrs) $t = New-Object 'System.Collections.Hashtable' $attrs, ([StringComparer]::OrdinalIgnoreCase); [pscustomobject]@{ Dn = 'x'; Attributes = $t } }
        if ($Filter -like '*sAMAccountName*') {
            if ($s.Missing) { return @() }
            $acc = $s.Account
            $attrs = @{ distinguishedName = @("CN=$($acc.Sam),OU=Storage,DC=example,DC=test"); objectSid = @(, (& $sidBytes $acc.Sid)); servicePrincipalName = @($acc.Spns); pwdLastSet = @([string]$acc.PwdLastSet.ToFileTimeUtc()); userAccountControl = @([string]$acc.Uac) }
            if ($null -ne $acc.EncTypes) { $attrs['msDS-SupportedEncryptionTypes'] = @([string]$acc.EncTypes) }
            $one = & $mk $attrs
            return $(if ($s.Duplicate) { @($one, $one) } else { @($one) })
        }
        if ($Filter -like '*domainDNS*') {
            $d = $s.Domain
            return @(& $mk @{ objectSid = @(, (& $sidBytes $d.Sid)); objectGUID = @(, ([guid]$d.Guid).ToByteArray()); maxPwdAge = @([string](-[int64]$d.MaxPwdAgeDays * 864000000000)) })
        }
        @()
    }.GetNewClosure()
    [pscustomobject]$a
}
