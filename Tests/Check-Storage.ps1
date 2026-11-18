#requires -Version 5.1
<#
.SYNOPSIS
    Checks the storage check through the Azure sign-in (Modules\AVDTune.Storage.psm1, issue 10) against the fake ARM, fake file share data plane, fake LDAP and fake
    FSLogix adapter: finding the account, the identity (AD DS, Entra Kerberos) compared with the domain controller, SMB settings and the RC4 to AES change, private
    endpoint and DNS, roles, NTFS ACLs over REST with the diff and the confirmed set, the access test as a domain user, and the account key only as a confirmed
    fallback (never stored). The error paths: no network, 403 (role missing), private DNS wrong, password of the AD object almost expired or expired, ACL deviates,
    domain controller not reachable, key fallback refused or failing. Only GET against ARM (except the one listKeys of the confirmed fallback). Nothing touches this
    computer, a network or a tenant.
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
foreach ($mod in 'AVDTune', 'AVDTune.Updates', 'AVDTune.Snapshot', 'AVDTune.Directory', 'AVDTune.FSLogix', 'AVDTune.Storage') { Import-Module (Join-Path $repo "Modules\$mod.psm1") -Force }
. (Join-Path $PSScriptRoot 'Fakes\FakeMachine.ps1')
. (Join-Path $PSScriptRoot 'Fakes\FakeFSLogix.ps1')
. (Join-Path $PSScriptRoot 'Fakes\FakeStorage.ps1')

$script:failed = 0
function Test-Check([string]$Name, [bool]$Ok, $Detail) { if ($Ok) { "PASS $Name" } else { $script:failed++; "FAIL $Name" + $(if ($null -ne $Detail) { "  -> $Detail" }) } }
function Test-Throws([scriptblock]$Block) { try { & $Block | Out-Null; $false } catch { $true } }
function Get-Row($Result, [string]$Id) { @($Result.Rows | Where-Object Id -eq $Id)[0] }
function New-TestSecure([string]$t) { $s = New-Object System.Security.SecureString; foreach ($c in $t.ToCharArray()) { $s.AppendChar($c) }; $s.MakeReadOnly(); $s }

$sub = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
$share = '\\storageaccount.file.core.windows.net\profiles'
$usersSid = 'S-1-5-21-1-2-3-513'; $adminsSid = 'S-1-5-21-1-2-3-512'
$goodSddl = New-AVDTuneFSLogixRecommendedSddl -UsersSid $usersSid -AdminsSid $adminsSid
$now = [datetime]'2026-11-15 10:00'
$armTok = 'tok-arm-SECRET-1'; $stTok = 'tok-storage-SECRET-2'
$ad = @{ domainName = 'example.test'; netBiosDomainName = 'EXAMPLE'; forestName = 'example.test'; domainGuid = '11111111-2222-3333-4444-555555555555'; domainSid = 'S-1-5-21-1-2-3'; azureStorageSid = 'S-1-5-21-1-2-3-1500'; samAccountName = 'storageaccount'; accountType = 'Computer' }
function New-Account([hashtable]$Props = @{}, $FileService = $null, $Roles = $null, [string]$Sku = 'Premium_LRS', [string]$Kind = 'FileStorage') {
    $p = @{ azureFilesIdentityBasedAuthentication = @{ directoryServiceOptions = 'AD'; defaultSharePermission = 'StorageFileDataSmbShareContributor'; activeDirectoryProperties = $ad }
        privateEndpointConnections = @(@{ id = 'pe1' }); publicNetworkAccess = 'Disabled' }
    foreach ($k in $Props.Keys) { $p[$k] = $Props[$k] }
    $a = @{ Name = 'storageaccount'; Rg = 'rg-example'; Kind = $Kind; Sku = $Sku; Props = $p }
    if ($FileService) { $a.FileService = $FileService }
    if ($Roles) { $a.Roles = $Roles }
    $a
}
$goodSmb = @{ versions = 'SMB3.1.1'; authenticationMethods = 'Kerberos'; kerberosTicketEncryption = 'AES-256'; channelEncryption = 'AES-256-GCM' }
function New-Env([hashtable]$Account = (New-Account -FileService $goodSmb), [hashtable]$ArmSeed = @{}, [hashtable]$FilesSeed = @{}, [hashtable]$LdapSeed = @{}, [hashtable]$FslSeed = @{}) {
    $armS = @{ Accounts = @($Account) }; foreach ($k in $ArmSeed.Keys) { $armS[$k] = $ArmSeed[$k] }
    $filesS = @{ Acls = @{ '' = $goodSddl; 'S-1-5-21-1-2-3-1600_alice' = 'O:S-1-5-21-1-2-3-1600G:DUD:PAI(A;OICI;FA;;;S-1-5-21-1-2-3-1600)(A;OICI;FA;;;S-1-5-21-1-2-3-512)' }; Folders = @('S-1-5-21-1-2-3-1600_alice') }; foreach ($k in $FilesSeed.Keys) { $filesS[$k] = $FilesSeed[$k] }
    @{ Arm = (New-AVDTuneFakeStorageArm -Seed $armS); Files = (New-AVDTuneFakeFiles -Seed $filesS); Ldap = (New-AVDTuneFakeStorageLdap -Seed $LdapSeed); F = (New-AVDTuneFakeFSLogix -Seed $FslSeed); M = (New-AVDTuneFakeMachine -Seed @{ Registry = @{ 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\Kerberos\Parameters|CloudKerberosTicketRetrievalEnabled' = 1 } }) }
}
function Invoke-Check($E, [hashtable]$Extra = @{}) {
    $p = @{ Machine = $E.M; F = $E.F; Arm = $E.Arm; ArmToken = $armTok; Files = $E.Files; StorageToken = $stTok; Ldap = $E.Ldap; LdapConnection = [pscustomobject]@{ Open = $true }; DefaultNamingContext = 'DC=example,DC=test'
        Locations = @($share); SubscriptionIds = @($sub); UsersSids = @($usersSid); AdminsSids = @($adminsSid); Now = $now }
    foreach ($k in $Extra.Keys) { if ($null -eq $Extra[$k]) { $p.Remove($k) } else { $p[$k] = $Extra[$k] } }
    Invoke-AVDTuneStorageCheck @p
}
function Not-Green($R) { @($R.Rows | Where-Object { $_.Status -notin 'green', 'info' } | ForEach-Object { "$($_.Id)=$($_.Status): $($_.Reason)" }) -join ' | ' }
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('avdtune-stor-' + [guid]::NewGuid().ToString('N'))
try {
    $env:AVDTUNE_ROOT = $tmp
    [void](Initialize-AVDTuneState -Root $tmp)
    [void](Start-AVDTuneImageVersion -Root $tmp -Date ([datetime]'2026-11-15') -User 'admin1')
    Close-AVDTuneWriteGate

    # ---------------------------------------------------------------- helpers
    $u = Split-AVDTuneUncShare $share
    Test-Check 'UNC split: host, account, share, path; a file server is not Azure Files' ($u.Account -eq 'storageaccount' -and $u.Share -eq 'profiles' -and $u.IsAzureFiles -and -not (Split-AVDTuneUncShare '\\fs01.example.test\profiles\x').IsAzureFiles -and (Split-AVDTuneUncShare '\\storageaccount.file.core.windows.net\profiles\a\b').Path -eq 'a\b' -and $null -eq (Split-AVDTuneUncShare 'C:\x')) $null
    Test-Check 'names: account and share rules' ((Test-AVDTuneStorageAccountName 'storageaccount') -and -not (Test-AVDTuneStorageAccountName 'ST') -and -not (Test-AVDTuneStorageAccountName 'a/b') -and (Test-AVDTuneShareName 'profiles') -and -not (Test-AVDTuneShareName 'Pro files') -and -not (Test-AVDTuneShareName 'a--b')) $null
    Test-Check 'private addresses: 10, 172.16-31, 192.168 yes; public and documentation ranges no' ((Test-AVDTunePrivateIp '10.1.2.3') -and (Test-AVDTunePrivateIp '172.20.0.4') -and (Test-AVDTunePrivateIp '192.168.1.1') -and -not (Test-AVDTunePrivateIp ('172.32.' + '0.1')) -and -not (Test-AVDTunePrivateIp '203.0.113.7') -and -not (Test-AVDTunePrivateIp 'x')) $null
    Test-Check 'ARM guard: only GET, and POST only for listKeys of a storage account' ((Test-Throws { Assert-AVDTuneStorageArmPath "/subscriptions/$sub/resourceGroups/r/providers/Microsoft.Storage/storageAccounts/storageaccount?api-version=2024-01-01" 'PUT' }) -and (Test-Throws { Assert-AVDTuneStorageArmPath "/subscriptions/$sub/resourceGroups/r/providers/Microsoft.Storage/storageAccounts/storageaccount/regenerateKey?api-version=2024-01-01" 'POST' }) -and -not (Test-Throws { Assert-AVDTuneStorageArmPath "/subscriptions/$sub/resourceGroups/r/providers/Microsoft.Storage/storageAccounts/storageaccount/listKeys?api-version=2024-01-01" 'POST' }) -and (Test-Throws { Assert-AVDTuneStorageArmPath '/tenants/x' 'GET' }) -and (Test-Throws { Assert-AVDTuneStorageArmPath "/subscriptions/$sub/../x" 'GET' })) $null
    $files0 = New-AVDTuneFakeFiles
    Test-Check 'data plane guard: bad account, share, path and query are refused before a request' ((Test-Throws { Invoke-AVDTuneStorageFiles -Files $files0 -Method GET -Account 'EVIL.example' -Share 'profiles' -Query 'restype=directory' -Token t }) -and (Test-Throws { Invoke-AVDTuneStorageFiles -Files $files0 -Method GET -Account 'storageaccount' -Share 'a b' -Query 'restype=directory' -Token t }) -and (Test-Throws { Invoke-AVDTuneStorageFiles -Files $files0 -Method GET -Account 'storageaccount' -Share 'profiles' -Path '..\x' -Query 'restype=directory' -Token t }) -and (Test-Throws { Invoke-AVDTuneStorageFiles -Files $files0 -Method GET -Account 'storageaccount' -Share 'profiles' -Query 'x=1;y' -Token t }) -and $files0.Log.Count -eq 0) $null
    $real = New-AVDTuneFilesAdapter
    $bad1 = & $real.Invoke 'GET' 'https://evil.example/x?restype=directory' 't' @{} $null
    $bad2 = & $real.Invoke 'GET' 'https://storageaccount.file.core.windows.net.evil.example/p?restype=directory' 't' @{} $null
    $bad3 = & $real.Invoke 'DELETE' 'https://storageaccount.file.core.windows.net/p?restype=directory' 't' @{} $null
    Test-Check 'the real data plane adapter refuses other hosts, look-alike hosts and other methods without a request' ($bad1.Status -eq 0 -and $bad2.Status -eq 0 -and $bad3.Status -eq 0 -and $bad1.Error -like 'Refused*') "$($bad1.Error) $($bad2.Error) $($bad3.Error)"

    # the storage token (issue 18, Storage audience of the sign-in): only to <account>.file.core.windows.net, no redirects, never in errors
    $stSecretUrl = 'tok-storage-SECRET-2'
    $badUrls = @('https://storageaccount.file.core.windows.net:444/p?restype=directory', ('https://user' + [char]64 + 'storageaccount.file.core.windows.net/p?restype=directory'), 'http://storageaccount.file.core.windows.net/p?restype=directory', 'https://storageaccount.blob.core.windows.net/p?restype=directory', 'https://storageaccount.file.core.windows.net/../x?restype=directory', 'https://storageaccount.file.core.windows.net@evil.example/p?restype=directory', 'https://management.azure.com/p?restype=directory')
    $badRes = @($badUrls | ForEach-Object { & $real.Invoke 'GET' $_ $stSecretUrl @{} $null })
    Test-Check 'the real data plane adapter never sends the storage token to a port, userinfo, http, another storage service, a path with .. or another host; no token in the answer' (@($badRes | Where-Object { $_.Status -ne 0 -or $_.Error -notlike 'Refused*' -or $_.Error -match 'SECRET' }).Count -eq 0) (($badRes | ForEach-Object { "$($_.Status) $($_.Error)" }) -join ' | ')
    $srcStorage = Get-Content -LiteralPath (Join-Path $repo 'Modules\AVDTune.Storage.psm1') -Raw
    Test-Check 'the real data plane adapter does not follow redirects and speaks TLS 1.2 (extended with -bor, not overwritten)' ($srcStorage -match 'AllowAutoRedirect = \$false' -and $srcStorage -match 'SecurityProtocol -bor') $null
    $spyEnv = New-Env
    $spy = New-Object System.Collections.ArrayList
    $realFiles = $spyEnv.Files; $realArm = $spyEnv.Arm
    $spyFiles = [pscustomobject]@{ Invoke = { param($Method, $Url, $Token, $Headers, $Body) [void]$spy.Add("FILES|$Token|$Url|$($Headers['x-ms-file-request-intent'])"); & $realFiles.Invoke $Method $Url $Token $Headers $Body }.GetNewClosure() }
    $spyArm = [pscustomobject]@{ Invoke = { param($Method, $Path, $Token, $Body) [void]$spy.Add("ARM|$Token|$Path"); & $realArm.Invoke $Method $Path $Token $Body }.GetNewClosure() }
    $spyEnv.Files = $spyFiles; $spyEnv.Arm = $spyArm
    $spyRes = Invoke-Check $spyEnv
    $fileCalls = @($spy | Where-Object { $_ -like 'FILES|*' }); $armCalls = @($spy | Where-Object { $_ -like 'ARM|*' })
    Test-Check 'the storage token goes only to https://storageaccount.file.core.windows.net (with the intent header backup), the ARM token only to ARM; neither to the other' ($spyRes.Overall -eq 'green' -and $fileCalls.Count -ge 3 -and @($fileCalls | Where-Object { $_ -notlike "FILES|$stTok|https://storageaccount.file.core.windows.net/*|backup" }).Count -eq 0 -and $armCalls.Count -ge 3 -and @($armCalls | Where-Object { $_ -notlike "ARM|$armTok|/subscriptions/*" }).Count -eq 0) (($fileCalls | Select-Object -First 2) -join ' ; ')
    $noTok = New-Env
    $noTokRes = Invoke-Check $noTok @{ StorageToken = $null; NoStorageReason = 'no token for Azure Storage (https://storage.azure.com/): No Storage token: ... Set up again (authorize this administrator)' }
    Test-Check 'without a storage token (old app registration): the ACL rows say why and how to fix it, no request goes to the share, nothing green' ((Get-Row $noTokRes 'st.acl.root').Status -eq 'unknown' -and (Get-Row $noTokRes 'st.acl.root').Reason -like '*Set up again*' -and $noTok.Files.Log.Count -eq 0 -and @($noTokRes.Rows | Where-Object Status -eq 'green').Count -lt @((Invoke-Check (New-Env)).Rows | Where-Object Status -eq 'green').Count) (Not-Green $noTokRes)

    # ---------------------------------------------------------------- finding the account
    $e = New-Env
    $f1 = Find-AVDTuneStorageAccount -Arm $e.Arm -Token $armTok -AccountName 'storageaccount' -SubscriptionIds @($sub)
    Test-Check 'find: account, resource group and id from the list of the subscription' ($f1.Found -and $f1.ResourceGroup -eq 'rg-example' -and $f1.Id -like "*/storageAccounts/storageaccount") $null
    $e2 = New-Env -ArmSeed @{ Pages = $true }
    Test-Check 'find: follows nextLink on the ARM host' ((Find-AVDTuneStorageAccount -Arm $e2.Arm -Token $armTok -AccountName 'storageaccount' -SubscriptionIds @($sub)).Found -and @($e2.Arm.Log | Where-Object { $_ -like '*page2*' }).Count -eq 1) $null
    $nf = Find-AVDTuneStorageAccount -Arm $e.Arm -Token $armTok -AccountName 'nothere01' -SubscriptionIds @($sub, 'not-a-guid')
    Test-Check 'find: not there is Found=false with the problems named (bad subscription id)' (-not $nf.Found -and ($nf.Problems -join ' ') -like '*not a subscription id*') $null

    # ---------------------------------------------------------------- the green path
    $e = New-Env
    $r = Invoke-Check $e @{ TestUser = 'EXAMPLE\test.user'; TestPassword = (New-TestSecure 'not-a-real-password'); DomainController = '10.0.0.10'; CallerOid = 'oid-1' }
    Test-Check 'all green: account, identity, AD object (SID, SPN, domain, password, AES), SMB, network, roles, ACL, folders, access test' ($r.Overall -eq 'green' -and @($r.Rows | Where-Object Status -in 'red', 'yellow', 'unknown').Count -eq 0) (Not-Green $r)
    $ids = @($r.Rows | ForEach-Object Id)
    Test-Check 'the rows of plan 5a points 1 to 6 are all there' (-not (@('st.account', 'st.identity', 'st.ad.sid', 'st.ad.spn', 'st.ad.domain', 'st.ad.password', 'st.ad.enctype', 'st.smb.kerberos', 'st.smb.versions', 'st.smb.auth', 'st.smb.channel', 'st.network', 'st.roles', 'st.acl.root', 'st.acl.folders', 'st.access' | Where-Object { $_ -notin $ids }).Count)) (($ids) -join ',')
    Test-Check 'every row has a Learn source, says whether Learn states it, and an unverified one carries its reason' (-not (@($r.Rows | Where-Object { $_.Source -notmatch '^https://learn\.microsoft\.com/' -or $_.Verified -isnot [bool] -or (-not $_.Verified -and -not $_.Note) }).Count)) (@($r.Rows | Where-Object { $_.Source -notmatch '^https://learn\.microsoft\.com/' -or (-not $_.Verified -and -not $_.Note) } | ForEach-Object Id) -join ',')
    Test-Check 'ARM: only GET (no key, no change); data plane: only GET; the user token, the intent header, no key' (@($e.Arm.Log | Where-Object { $_ -notlike 'GET *' }).Count -eq 0 -and @($e.Files.Log | Where-Object { $_ -notlike 'GET *' }).Count -eq 0 -and $e.Arm.Store.KeyRequests -eq 0 -and $e.F.Store.Mapped -eq $false -and @($e.F.Log | Where-Object { $_ -like 'KeyMap*' }).Count -eq 0) $null
    $json = $r | ConvertTo-Json -Depth 8
    Test-Check 'the result holds no token, no password and no SDDL text' ($json -notmatch 'SECRET' -and $json -notmatch 'not-a-real-password' -and ($e.Arm.Log + $e.Files.Log + $e.F.Log + $e.Ldap.Log | Out-String) -notmatch 'SECRET|not-a-real-password') $null
    Test-Check 'the access test got the account, the domain controller and the share' (@($e.F.Log | Where-Object { $_ -eq "ShareTestAsUser $share as EXAMPLE\test.user via 10.0.0.10" }).Count -eq 1) $null
    $e3 = New-Env -Account (New-Account -FileService $goodSmb -Roles @(@{ Role = 'b8eda974-7b85-4f76-af95-65846b26df6d'; Principal = 'oid-1' }))
    Test-Check 'the roles of the signed-in user are read from the assignments (Privileged Reader named by id)' ((Invoke-Check $e3 @{ CallerOid = 'oid-1' }).CallerRoles -contains 'Storage File Data Privileged Reader' -and @((Invoke-Check $e3 @{ CallerOid = 'someone-else' }).CallerRoles).Count -eq 0) $null

    # ---------------------------------------------------------------- not signed in, no network, 403
    $none = Invoke-Check (New-Env) @{ Arm = $null; ArmToken = $null; Files = $null; StorageToken = $null; Ldap = $null; LdapConnection = $null }
    Test-Check 'no Azure sign-in: every Azure row is not checkable, never green, nothing crashes' ($none.Overall -eq 'yellow' -and @($none.Rows | Where-Object Status -eq 'unknown').Count -ge 5 -and @($none.Rows | Where-Object Status -eq 'green').Count -eq 0) (Not-Green $none)
    Test-Check 'the reason says to sign in; the missing storage audience is named' ((Get-Row $none 'st.account').Reason -like '*sign in*' -and (Get-Row $none 'st.acl.root').Reason -like '*storage.azure.com*') $null
    $off = Invoke-Check (New-Env -ArmSeed @{ Offline = $true })
    Test-Check 'ARM offline: the account row is not checkable with the network reason, the ACL part still works' ((Get-Row $off 'st.account').Status -eq 'unknown' -and (Get-Row $off 'st.account').Reason -like '*No connection*' -and (Get-Row $off 'st.acl.root').Status -eq 'green') (Get-Row $off 'st.account').Reason
    $lf = Invoke-Check (New-Env -ArmSeed @{ ListForbidden = $true })
    Test-Check '403 on the account list: not checkable with the missing role named (Reader)' ((Get-Row $lf 'st.account').Status -eq 'red' -or (Get-Row $lf 'st.account').Status -eq 'unknown') (Get-Row $lf 'st.account').Reason
    $ghost = Invoke-Check (New-Env -Account (@{ Name = 'contosoother'; Rg = 'rg'; Props = @{} }))
    Test-Check 'the account is in no readable subscription: red with the fix' ((Get-Row $ghost 'st.account').Status -eq 'red' -and (Get-Row $ghost 'st.account').Fix -like '*Reader*') $null
    $nosub = Invoke-Check (New-Env) @{ SubscriptionIds = @() }
    Test-Check 'no subscription known (not an Azure VM): not checkable, asks for the id' ((Get-Row $nosub 'st.account').Status -eq 'unknown' -and (Get-Row $nosub 'st.account').Reason -like '*subscription*') $null
    $nonaz = Invoke-Check (New-Env) @{ Locations = @('\\fs01.example.test\profiles') }
    Test-Check 'a file server share: the Azure checks are skipped with an info row' ($nonaz.Rows.Count -eq 1 -and $nonaz.Rows[0].Status -eq 'info') $null
    Test-Check 'no VHDLocations: info, nothing asked' ((Invoke-Check (New-Env) @{ Locations = @() }).Rows[0].Status -eq 'info') $null

    # ---------------------------------------------------------------- identity and the domain controller
    $none2 = Invoke-Check (New-Env -Account (New-Account -Props @{ azureFilesIdentityBasedAuthentication = @{ directoryServiceOptions = 'None' } } -FileService $goodSmb))
    Test-Check 'no identity based authentication: red' ((Get-Row $none2 'st.identity').Status -eq 'red') $null
    $miss = Invoke-Check (New-Env -LdapSeed @{ Missing = $true })
    Test-Check 'AD object gone: red, nothing else of the object is compared' ((Get-Row $miss 'st.ad.object').Status -eq 'red' -and $null -eq (Get-Row $miss 'st.ad.sid')) $null
    $sidx = Invoke-Check (New-Env -LdapSeed @{ Account = @{ Sam = 'storageaccount'; Sid = 'S-1-5-21-1-2-3-9999'; Spns = @('cifs/storageaccount.file.core.windows.net'); PwdLastSet = [datetime]'2026-11-01'; Uac = 4096; EncTypes = 24 } })
    Test-Check 'SID of the AD object differs from azureStorageSid: red' ((Get-Row $sidx 'st.ad.sid').Status -eq 'red' -and (Get-Row $sidx 'st.ad.sid').Fix -like '*join*') $null
    $spnx = Invoke-Check (New-Env -LdapSeed @{ Account = @{ Sam = 'storageaccount'; Sid = 'S-1-5-21-1-2-3-1500'; Spns = @('HOST/storageaccount'); PwdLastSet = [datetime]'2026-11-01'; Uac = 4096; EncTypes = 24 } })
    Test-Check 'SPN cifs/<account>.file.core.windows.net missing: red' ((Get-Row $spnx 'st.ad.spn').Status -eq 'red' -and (Get-Row $spnx 'st.ad.spn').Reason -like '*cifs/storageaccount.file.core.windows.net*') $null
    $domx = Invoke-Check (New-Env -LdapSeed @{ Domain = @{ Sid = 'S-1-5-21-9-9-9'; Guid = '99999999-2222-3333-4444-555555555555'; MaxPwdAgeDays = 42 } })
    Test-Check 'domain SID or GUID differ: red' ((Get-Row $domx 'st.ad.domain').Status -eq 'red') $null
    $pw1 = Invoke-Check (New-Env -LdapSeed @{ Account = @{ Sam = 'storageaccount'; Sid = 'S-1-5-21-1-2-3-1500'; Spns = @('cifs/storageaccount.file.core.windows.net'); PwdLastSet = [datetime]'2026-10-12'; Uac = 4096; EncTypes = 24 } })
    Test-Check 'password set 34 days ago, maximum 42: yellow with 7 days left, the rotation is explained, AVDTune does not rotate' ((Get-Row $pw1 'st.ad.password').Status -eq 'yellow' -and (Get-Row $pw1 'st.ad.password').Reason -like '*7 day(s)*' -and (Get-Row $pw1 'st.ad.password').Fix -like '*Update-AzStorageAccountADObjectPassword*' -and (Get-Row $pw1 'st.ad.password').Fix -like '*does not rotate*') (Get-Row $pw1 'st.ad.password').Reason
    $pw2 = Invoke-Check (New-Env -LdapSeed @{ Account = @{ Sam = 'storageaccount'; Sid = 'S-1-5-21-1-2-3-1500'; Spns = @('cifs/storageaccount.file.core.windows.net'); PwdLastSet = [datetime]'2026-09-01'; Uac = 4096; EncTypes = 24 } })
    Test-Check 'password older than the maximum age: red, expired days named' ((Get-Row $pw2 'st.ad.password').Status -eq 'red' -and (Get-Row $pw2 'st.ad.password').Reason -like '*expired*') (Get-Row $pw2 'st.ad.password').Reason
    $pw3 = Invoke-Check (New-Env -LdapSeed @{ Account = @{ Sam = 'storageaccount'; Sid = 'S-1-5-21-1-2-3-1500'; Spns = @('cifs/storageaccount.file.core.windows.net'); PwdLastSet = [datetime]'2020-01-01'; Uac = (4096 -bor 0x10000); EncTypes = 24 } })
    $pw4 = Invoke-Check (New-Env -LdapSeed @{ Domain = @{ Sid = 'S-1-5-21-1-2-3'; Guid = '11111111-2222-3333-4444-555555555555'; MaxPwdAgeDays = 0 }; Account = @{ Sam = 'storageaccount'; Sid = 'S-1-5-21-1-2-3-1500'; Spns = @('cifs/storageaccount.file.core.windows.net'); PwdLastSet = [datetime]'2020-01-01'; Uac = 4096; EncTypes = 24 } })
    Test-Check 'password never expires (flag or no maximum age in the domain): green' ((Get-Row $pw3 'st.ad.password').Status -eq 'green' -and (Get-Row $pw4 'st.ad.password').Status -eq 'green') $null
    $enc = Invoke-Check (New-Env -LdapSeed @{ Account = @{ Sam = 'storageaccount'; Sid = 'S-1-5-21-1-2-3-1500'; Spns = @('cifs/storageaccount.file.core.windows.net'); PwdLastSet = [datetime]'2026-11-01'; Uac = 4096; EncTypes = $null } })
    Test-Check 'no msDS-SupportedEncryptionTypes: yellow with the April 2026 RC4 to AES hint and the Learn page' ((Get-Row $enc 'st.ad.enctype').Status -eq 'yellow' -and (Get-Row $enc 'st.ad.enctype').Reason -like '*April 2026*' -and (Get-Row $enc 'st.ad.enctype').Source -like '*overview-prerequisites') $null
    $dup = Invoke-Check (New-Env -LdapSeed @{ Duplicate = $true })
    Test-Check 'two AD objects with the name: yellow, the first is compared' ((Get-Row $dup 'st.ad.object').Status -eq 'yellow' -and (Get-Row $dup 'st.ad.sid').Status -eq 'green') $null
    $nol = Invoke-Check (New-Env) @{ Ldap = $null; LdapConnection = $null }
    Test-Check 'no domain controller connection: the AD comparison is not checkable (never green)' ((Get-Row $nol 'st.ad').Status -eq 'unknown' -and (Get-Row $nol 'st.ad').Reason -like '*domain controller*') $null
    $lf2 = Invoke-Check (New-Env -LdapSeed @{ Fail = $true })
    Test-Check 'the domain controller throws: not checkable with the reason, the rest still runs' ((Get-Row $lf2 'st.ad').Status -eq 'unknown' -and (Get-Row $lf2 'st.smb.kerberos').Status -eq 'green') $null
    $ent = Invoke-Check (New-Env -Account (New-Account -Props @{ azureFilesIdentityBasedAuthentication = @{ directoryServiceOptions = 'AADKERB'; defaultSharePermission = 'StorageFileDataSmbShareContributor' } } -FileService $goodSmb)) @{ Ldap = $null; LdapConnection = $null }
    Test-Check 'Entra Kerberos: CloudKerberosTicketRetrievalEnabled read from the master (green); consent and Conditional Access are a by-hand hint, never green' ((Get-Row $ent 'st.entra.cloudkerb').Status -eq 'green' -and (Get-Row $ent 'st.entra.consent').Status -eq 'info' -and (Get-Row $ent 'st.entra.consent').Reason -like '*Conditional Access*') $null
    $entm = New-Env -Account (New-Account -Props @{ azureFilesIdentityBasedAuthentication = @{ directoryServiceOptions = 'AADKERB'; defaultSharePermission = 'StorageFileDataSmbShareContributor' } } -FileService $goodSmb)
    $entm.M = New-AVDTuneFakeMachine
    Test-Check 'Entra Kerberos without CloudKerberosTicketRetrievalEnabled on the master: yellow with the value to set' ((Get-Row (Invoke-Check $entm) 'st.entra.cloudkerb').Status -eq 'yellow') $null

    # ---------------------------------------------------------------- SMB settings, RC4 to AES
    $smbCase = { param($smb) Invoke-Check (New-Env -Account (New-Account -FileService $smb)) }
    $k0 = & $smbCase @{ versions = 'SMB3.1.1'; authenticationMethods = 'Kerberos'; kerberosTicketEncryption = 'RC4-HMAC'; channelEncryption = 'AES-256-GCM' }
    $k1 = & $smbCase @{ versions = 'SMB3.1.1'; authenticationMethods = 'Kerberos'; kerberosTicketEncryption = 'RC4-HMAC;AES-256'; channelEncryption = 'AES-256-GCM' }
    $k2 = & $smbCase @{ versions = 'SMB3.1.1'; authenticationMethods = 'Kerberos'; kerberosTicketEncryption = ''; channelEncryption = 'AES-256-GCM' }
    Test-Check 'Kerberos ticket encryption: RC4 only red (April 2026), AES and RC4 yellow, not set yellow, AES only green' ((Get-Row $k0 'st.smb.kerberos').Status -eq 'red' -and (Get-Row $k0 'st.smb.kerberos').Reason -like '*April 2026*' -and (Get-Row $k1 'st.smb.kerberos').Status -eq 'yellow' -and (Get-Row $k2 'st.smb.kerberos').Status -eq 'yellow' -and (Get-Row $r 'st.smb.kerberos').Status -eq 'green') $null
    $v0 = & $smbCase @{ versions = 'SMB2.1;SMB3.0'; authenticationMethods = 'NTLMv2'; kerberosTicketEncryption = 'AES-256'; channelEncryption = 'AES-128-CCM' }
    Test-Check 'SMB: no 3.1.1 yellow, NTLMv2 only with identity authentication red, channel encryption without AES-256-GCM yellow' ((Get-Row $v0 'st.smb.versions').Status -eq 'yellow' -and (Get-Row $v0 'st.smb.auth').Status -eq 'red' -and (Get-Row $v0 'st.smb.channel').Status -eq 'yellow') $null
    $fsf = Invoke-Check (New-Env -ArmSeed @{ FileServiceForbidden = $true })
    Test-Check 'file service 403: the SMB rows are not checkable with the role hint; the other rows run' ((Get-Row $fsf 'st.smb').Status -eq 'unknown' -and (Get-Row $fsf 'st.smb').Fix -like '*Reader*' -and (Get-Row $fsf 'st.roles').Status -eq 'green') $null

    # ---------------------------------------------------------------- network and DNS
    $pubdns = Invoke-Check (New-Env -FslSeed @{ Dns = @{ 'storageaccount.file.core.windows.net' = @{ Ok = $true; Addresses = @('203.0.113.7'); Error = '' } } })
    Test-Check 'private endpoint but the name resolves to a public IP (private DNS wrong): red with the zone to link' ((Get-Row $pubdns 'st.network').Status -eq 'red' -and (Get-Row $pubdns 'st.network').Fix -like '*privatelink.file.core.windows.net*') (Get-Row $pubdns 'st.network').Reason
    $nodns = Invoke-Check (New-Env -FslSeed @{ Dns = @{ 'storageaccount.file.core.windows.net' = @{ Ok = $false; Addresses = @(); Error = 'No such host' } } })
    Test-Check 'private endpoint but no DNS answer: red' ((Get-Row $nodns 'st.network').Status -eq 'red') $null
    $nope = Invoke-Check (New-Env -Account (New-Account -Props @{ privateEndpointConnections = @(); publicNetworkAccess = 'Enabled' } -FileService $goodSmb) -FslSeed @{ Dns = @{ 'storageaccount.file.core.windows.net' = @{ Ok = $true; Addresses = @('203.0.113.7'); Error = '' } } })
    $nope2 = Invoke-Check (New-Env -Account (New-Account -Props @{ privateEndpointConnections = @(); publicNetworkAccess = 'Disabled' } -FileService $goodSmb))
    Test-Check 'no private endpoint: yellow when public, red when public access is off too (unreachable)' ((Get-Row $nope 'st.network').Status -eq 'yellow' -and (Get-Row $nope2 'st.network').Status -eq 'red') $null
    $pe2 = Invoke-Check (New-Env -Account (New-Account -Props @{ publicNetworkAccess = 'Enabled' } -FileService $goodSmb))
    Test-Check 'private endpoint with public access still enabled: yellow hint' ((Get-Row $pe2 'st.network.public').Status -eq 'yellow') $null
    $std = Invoke-Check (New-Env -Account (New-Account -FileService $goodSmb -Sku 'Standard_LRS' -Kind 'StorageV2'))
    Test-Check 'a standard account: yellow, not recommended for FSLogix' ((Get-Row $std 'st.sku').Status -eq 'yellow') $null

    # ---------------------------------------------------------------- roles
    $noperm = Invoke-Check (New-Env -Account (New-Account -Props @{ azureFilesIdentityBasedAuthentication = @{ directoryServiceOptions = 'AD'; activeDirectoryProperties = $ad } } -FileService $goodSmb))
    Test-Check 'no default share permission and no assignment: red' ((Get-Row $noperm 'st.roles').Status -eq 'red' -and (Get-Row $noperm 'st.roles').Fix -like '*SMB Share Contributor*') $null
    $withrole = Invoke-Check (New-Env -Account (New-Account -Props @{ azureFilesIdentityBasedAuthentication = @{ directoryServiceOptions = 'AD'; activeDirectoryProperties = $ad } } -FileService $goodSmb -Roles @(@{ Role = '0c867c2a-1d8c-454a-a3db-ab2ea1bdc8bb'; Principal = 'g1' })))
    Test-Check 'an assignment of SMB Share Contributor instead: green' ((Get-Row $withrole 'st.roles').Status -eq 'green') $null
    $rf = Invoke-Check (New-Env -ArmSeed @{ RolesForbidden = $true })
    Test-Check 'role assignments 403: not checkable' ((Get-Row $rf 'st.roles').Status -eq 'unknown') $null

    # ---------------------------------------------------------------- NTFS ACL over REST
    $nt = Invoke-Check (New-Env) @{ StorageToken = $null; Files = $null }
    Test-Check 'no storage token: the ACL rows are not checkable, never green' ((Get-Row $nt 'st.acl.root').Status -eq 'unknown') $null
    $ev = New-Env -FilesSeed @{ Acls = @{ '' = 'O:BAG:DUD:PAI(A;OICI;FA;;;WD)(A;OICI;FA;;;BA)' }; Folders = @() }
    $evr = Invoke-Check $ev
    Test-Check 'the ACL deviates (Everyone full control): red, the diff is offered with the recommended SDDL' ((Get-Row $evr 'st.acl.root').Status -eq 'red' -and $evr.AclDiff.Recommended -eq $goodSddl -and -not $evr.AclDiff.Compliant -and $evr.AclDiff.Hash.Length -eq 16) $null
    $nog = Invoke-Check $ev @{ UsersSids = @(); AdminsSids = @() }
    Test-Check 'without the group SIDs the diff is not offered (the groups must be known)' ($null -eq $nog.AclDiff -and (Get-Row $nog 'st.acl.root').Fix -like '*users and administrators group*') $null
    $broad = New-Env -FilesSeed @{ Acls = @{ '' = $goodSddl; 'S-1-5-21-1-2-3-1600_alice' = "O:BAG:DUD:PAI(A;OICI;FA;;;S-1-5-21-1-2-3-512)(A;OICI;0x1301bf;;;$usersSid)" }; Folders = @('S-1-5-21-1-2-3-1600_alice') }
    Test-Check 'a profile folder that the users group can open: red' ((Get-Row (Invoke-Check $broad) 'st.acl.folders').Status -eq 'red') $null
    # #83: Domain Computers of another domain and a callback entry for Everyone on a profile folder are broad too
    $dcF = New-Env -FilesSeed @{ Acls = @{ '' = $goodSddl; 'S-1-5-21-1-2-3-1600_alice' = "O:BAG:DUD:PAI(A;OICI;FA;;;S-1-5-21-1-2-3-512)(A;OICI;0x1200a9;;;S-1-5-21-7-8-9-515)" }; Folders = @('S-1-5-21-1-2-3-1600_alice') }
    $xaF = New-Env -FilesSeed @{ Acls = @{ '' = $goodSddl; 'S-1-5-21-1-2-3-1600_alice' = "O:BAG:DUD:PAI(A;OICI;FA;;;S-1-5-21-1-2-3-512)(XA;OICI;0x1200a9;;;WD;(Member_of {SID(BA)}))" }; Folders = @('S-1-5-21-1-2-3-1600_alice') }
    $okF = New-Env -FilesSeed @{ Acls = @{ '' = $goodSddl; 'S-1-5-21-1-2-3-1600_alice' = "O:BAG:DUD:PAI(A;OICI;FA;;;S-1-5-21-1-2-3-512)(A;OICI;FA;;;S-1-5-21-1-2-3-1600)" }; Folders = @('S-1-5-21-1-2-3-1600_alice') }
    $junkF = New-Env -FilesSeed @{ Acls = @{ '' = $goodSddl; 'S-1-5-21-1-2-3-1600_alice' = 'not an sddl'; 'S-1-5-21-1-2-3-1601_bob' = "O:BAG:DUD:PAI(A;OICI;FA;;;S-1-5-21-1-2-3-512)" }; Folders = @('S-1-5-21-1-2-3-1600_alice', 'S-1-5-21-1-2-3-1601_bob') }
    $junkR = Invoke-Check $junkF
    $nullF = New-Env -FilesSeed @{ Acls = @{ '' = $goodSddl; 'S-1-5-21-1-2-3-1600_alice' = 'O:BAG:SYD:NO_ACCESS_CONTROL' }; Folders = @('S-1-5-21-1-2-3-1600_alice') }
    $nullR = Get-Row (Invoke-Check $nullF) 'st.acl.folders'
    Test-Check 'profile folders (#83): a folder whose rights cannot be read is named as not checkable (the root row stays), a NULL DACL folder is red with the reason' ((Get-Row $junkR 'st.acl.folders').Status -eq 'unknown' -and (Get-Row $junkR 'st.acl.folders').Reason -like '*1600_alice*' -and (Get-Row $junkR 'st.acl.root').Status -ne 'unknown' -and $nullR.Status -eq 'red' -and $nullR.Reason -like '*NULL DACL = Everyone Full*') "$((Get-Row $junkR 'st.acl.folders').Status) $((Get-Row $junkR 'st.acl.folders').Reason) | $($nullR.Status) $($nullR.Reason)"
    Test-Check 'profile folders (#83): Domain Computers of any domain and a callback entry for Everyone are red, the owner and the admins alone green' ((Get-Row (Invoke-Check $dcF) 'st.acl.folders').Status -eq 'red' -and (Get-Row (Invoke-Check $xaF) 'st.acl.folders').Status -eq 'red' -and (Get-Row (Invoke-Check $okF) 'st.acl.folders').Status -eq 'green') $null
    $fb = Invoke-Check (New-Env -FilesSeed @{ Forbidden = $true })
    Test-Check '403 on the ACL read: yellow row names the role (Privileged Reader), the key is NOT used without confirmation' ((Get-Row $fb 'st.acl.role').Status -eq 'yellow' -and (Get-Row $fb 'st.acl.role').Reason -like '*403*' -and (Get-Row $fb 'st.acl.role').Fix -like '*Privileged Reader*' -and (Get-Row $fb 'st.acl.key').Status -eq 'info' -and $fb.KeyUsed -eq $false -and $fb.Overall -eq 'yellow') $null
    $efb = New-Env -FilesSeed @{ Forbidden = $true }
    $kr = Invoke-Check $efb @{ AllowKeyFallback = $true }
    Test-Check 'confirmed key fallback: listKeys once (the only POST), mapping added and removed, ACL read through SMB, flagged in the result' ($kr.KeyUsed -and $efb.Arm.Store.KeyRequests -eq 1 -and @($efb.Arm.Log | Where-Object { $_ -like 'POST *listKeys*' }).Count -eq 1 -and @($efb.Arm.Log | Where-Object { $_ -like 'POST *' }).Count -eq 1 -and @($efb.F.Log | Where-Object { $_ -like 'KeyMapRemove*' }).Count -eq 1 -and $efb.F.Store.Mapped -eq $false -and (Get-Row $kr 'st.acl.key').Status -in 'yellow', 'red') (Get-Row $kr 'st.acl.key').Reason
    $efb.F.Store.Acl = @{ $share = $goodSddl }
    $efb2 = New-Env -FilesSeed @{ Forbidden = $true } -FslSeed @{ Acl = @{ $share = $goodSddl } }
    $kr2 = Invoke-Check $efb2 @{ AllowKeyFallback = $true }
    Test-Check 'key fallback with a readable ACL: the ACL row is evaluated, the key row says it was used in memory only' ($kr2.KeyUsed -and (Get-Row $kr2 'st.acl.key').Status -eq 'yellow' -and (Get-Row $kr2 'st.acl.root').Status -eq 'green') (Not-Green $kr2)
    $keyLeak = ($kr2 | ConvertTo-Json -Depth 8) + ($efb2.Arm.Log + $efb2.Files.Log + $efb2.F.Log | Out-String)
    Test-Check 'the account key is in no result and no log (it reached only the mapping call)' ($keyLeak -notmatch [regex]::Escape($efb2.Arm.Store.FakeKey) -and $efb2.F.Store.KeySeen -ne $null -and $efb2.F.Store.KeySeen -eq $efb2.Arm.Store.FakeKey) $null
    $kd = New-Env -FilesSeed @{ Forbidden = $true } -ArmSeed @{ KeysForbidden = $true }
    $krd = Invoke-Check $kd @{ AllowKeyFallback = $true }
    Test-Check 'key fallback refused by Azure (listKeys 403): red with the reason, no mapping, no key used' ((Get-Row $krd 'st.acl.key').Status -eq 'red' -and (Get-Row $krd 'st.acl.key').Reason -like '*403*' -and @($kd.F.Log | Where-Object { $_ -like 'KeyMapAdd*' }).Count -eq 0 -and $krd.KeyUsed -eq $false) (Get-Row $krd 'st.acl.key').Reason
    $kf = New-Env -FilesSeed @{ Forbidden = $true } -FslSeed @{ KeyMapFails = $true }
    $krf = Invoke-Check $kf @{ AllowKeyFallback = $true }
    Test-Check 'the SMB mapping with the key fails: red, the mapping is removed anyway, the key was still not logged' ((Get-Row $krf 'st.acl.key').Status -eq 'red' -and @($kf.F.Log | Where-Object { $_ -like 'KeyMapRemove*' }).Count -eq 1 -and (($krf | ConvertTo-Json -Depth 8) + ($kf.F.Log | Out-String)) -notmatch [regex]::Escape($kf.Arm.Store.FakeKey)) $null
    $fo = Invoke-Check (New-Env -FilesSeed @{ Offline = $true })
    Test-Check 'file share endpoint not reachable: the ACL is not checkable with the reason' ((Get-Row $fo 'st.acl.root').Status -eq 'unknown' -and (Get-Row $fo 'st.acl.root').Reason -like '*resolved*') (Get-Row $fo 'st.acl.root').Reason
    $nk = Invoke-Check (New-Env -FilesSeed @{ NoKeyHeader = $true })
    Test-Check 'an answer without the permission key header: not checkable' ((Get-Row $nk 'st.acl.root').Status -eq 'unknown') $null

    # ---------------------------------------------------------------- setting the ACL (diff and confirmation)
    $setE = New-Env -FilesSeed @{ Acls = @{ '' = 'O:BAG:DUD:PAI(A;OICI;FA;;;WD)(A;OICI;FA;;;BA)' }; Folders = @() }
    $diff = (Invoke-Check $setE).AclDiff
    Test-Check 'the diff names what is there and what is expected' ($diff.Found.Count -ge 1 -and $diff.Expected.Count -eq 4 -and @($diff.Findings | Where-Object Status -eq 'red').Count -ge 1) $null
    $gateHash = (Get-AVDTuneStorageAclDiff -FoundSddl 'O:BAG:DUD:PAI(A;OICI;FA;;;WD)(A;OICI;FA;;;BA)' -UsersSid $usersSid -AdminsSid $adminsSid -Account 'storageaccount' -Share 'profiles').Hash
    $closed = Set-AVDTuneStorageRootAcl -Files $setE.Files -Account 'storageaccount' -Share 'profiles' -Token $stTok -UsersSid $usersSid -AdminsSid $adminsSid -ConfirmedHash $gateHash -Root $tmp -User 'admin1' -SnapshotId 'snap'
    Test-Check 'setting the ACL without the write gate: refused, nothing set (counter-test L3)' ($closed.Status -eq 'Failed' -and $closed.Message -like '*Read only*' -and $setE.Files.Store.Puts.Count -eq 0) $closed.Message
    Open-AVDTuneWriteGate -SnapshotId 'snap-check' -ConfirmedBy 'Check Runner'
    $call = { param($E, $Hash) Set-AVDTuneStorageRootAcl -Files $E.Files -Account 'storageaccount' -Share 'profiles' -Token $stTok -UsersSid $usersSid -AdminsSid $adminsSid -ConfirmedHash $Hash -Root $tmp -User 'admin1' -SnapshotId 'snap' }
    Test-Check 'setting needs the confirmed hash (a mandatory parameter); a wrong hash sets nothing' ((Test-Throws { Set-AVDTuneStorageRootAcl -Files $setE.Files -Account 'storageaccount' -Share 'profiles' -Token $stTok -UsersSid $usersSid -AdminsSid $adminsSid }) -and (& $call $setE 'deadbeefdeadbeef').Status -eq 'Failed' -and $setE.Files.Store.Puts.Count -eq 0) $null
    $changed = New-Env -FilesSeed @{ Acls = @{ '' = 'O:BAG:DUD:PAI(A;OICI;FA;;;WD)(A;OICI;FA;;;BA)' }; Folders = @(); ChangeOnRead = 'O:BAG:DUD:PAI(A;OICI;FA;;;BA)' }
    [void](Get-AVDTuneStorageShareAcl -Files $changed.Files -Account 'storageaccount' -Share 'profiles' -Token $stTok)
    $diff2 = Get-AVDTuneStorageAclDiff -FoundSddl 'O:BAG:DUD:PAI(A;OICI;FA;;;WD)(A;OICI;FA;;;BA)' -UsersSid $usersSid -AdminsSid $adminsSid -Account 'storageaccount' -Share 'profiles'
    $rc = & $call $changed $diff2.Hash
    Test-Check 'the ACL changed after the diff was shown: nothing is set, the administrator must look again' ($rc.Status -eq 'Failed' -and $rc.Message -like '*changed after the diff*' -and $changed.Files.Store.Puts.Count -eq 0) $null
    $ok = & $call $setE $diff.Hash
    Test-Check 'confirmed diff: the recommended SDDL is set once, attributes and times preserved, the root now matches' ($ok.Status -eq 'Changed' -and $setE.Files.Store.Puts.Count -eq 1 -and $setE.Files.Store.Puts[0].Sddl -eq $goodSddl -and $setE.Files.Store.Puts[0].Attributes -eq 'preserve' -and $setE.Files.Store.Puts[0].Created -eq 'preserve' -and (Get-Row (Invoke-Check $setE) 'st.acl.root').Status -eq 'green') $ok.Message
    Test-Check 'the change is in the change log (no SDDL text in it)' ((@(Get-AVDTuneChangeLog -Root $tmp | Where-Object { $_.Component -eq 'Storage ACL' }).Count -eq 1) -and (@(Get-AVDTuneChangeLog -Root $tmp | Where-Object { $_.Component -eq 'Storage ACL' })[0].Text -notmatch 'O:BA')) $null
    $same = & $call $setE (Get-AVDTuneStorageAclDiff -FoundSddl $goodSddl -UsersSid $usersSid -AdminsSid $adminsSid -Account 'storageaccount' -Share 'profiles').Hash
    Test-Check 'an ACL that already matches: Unchanged, no second write' ($same.Status -eq 'Unchanged' -and $setE.Files.Store.Puts.Count -eq 1) $null
    $pf = New-Env -FilesSeed @{ Acls = @{ '' = 'O:BAG:DUD:PAI(A;OICI;FA;;;WD)' }; Folders = @(); PutForbidden = $true }
    $rp = & $call $pf (Get-AVDTuneStorageAclDiff -FoundSddl 'O:BAG:DUD:PAI(A;OICI;FA;;;WD)' -UsersSid $usersSid -AdminsSid $adminsSid -Account 'storageaccount' -Share 'profiles').Hash
    Test-Check 'the role to change the ACL is missing (403 on the PUT): Failed with the role named' ($rp.Status -eq 'Failed' -and $rp.Message -like '*Privileged Contributor*') $rp.Message
    $otherShare = Get-AVDTuneStorageAclDiff -FoundSddl 'O:BAG:DUD:PAI(A;OICI;FA;;;WD)(A;OICI;FA;;;BA)' -UsersSid $usersSid -AdminsSid $adminsSid -Account 'storageaccount' -Share 'other'
    $otherAcct = Get-AVDTuneStorageAclDiff -FoundSddl 'O:BAG:DUD:PAI(A;OICI;FA;;;WD)(A;OICI;FA;;;BA)' -UsersSid $usersSid -AdminsSid $adminsSid -Account 'otheraccount' -Share 'profiles'
    Test-Check 'the hash covers account and share: another share or account gives another hash, the diff names the share it was made for (counter-test L3)' ($otherShare.Hash -ne $diff.Hash -and $otherAcct.Hash -ne $diff.Hash -and $diff.Account -eq 'storageaccount' -and $diff.Share -eq 'profiles') $null
    $wrongShare = New-Env -FilesSeed @{ Acls = @{ '' = 'O:BAG:DUD:PAI(A;OICI;FA;;;WD)(A;OICI;FA;;;BA)' }; Folders = @() }
    $rw = Set-AVDTuneStorageRootAcl -Files $wrongShare.Files -Account 'storageaccount' -Share 'other' -Token $stTok -UsersSid $usersSid -AdminsSid $adminsSid -ConfirmedHash $diff.Hash -Root $tmp -User 'admin1' -SnapshotId 'snap'
    Test-Check 'a hash confirmed for one share does not set another share (counter-test L3)' ($rw.Status -eq 'Failed' -and $wrongShare.Files.Store.Puts.Count -eq 0) $rw.Message
    Test-Check 'a set ACL (or attempt) sets LastChange (checklist: every write)' ($null -ne (Get-AVDTuneState $tmp).LastChange) $null
    $srcSt = Get-Content -LiteralPath (Join-Path $repo 'Modules\AVDTune.Storage.psm1') -Raw
    Test-Check 'the key list is cleared in finally, like the key (counter-test L1)' ($srcSt -match 'finally \{ \$key = \$null; \$keys = \$null;') $null
    $rr = & $call (New-Env -FilesSeed @{ Forbidden = $true }) 'x'
    Test-Check 'the current ACL cannot be read: nothing is set' ($rr.Status -eq 'Failed' -and $rr.Message -like '*nothing is set*') $null

    # ---------------------------------------------------------------- undo of the set ACL (#24)
    $badSddl = 'O:BAG:DUD:PAI(A;OICI;FA;;;WD)(A;OICI;FA;;;BA)'
    $ue = New-Env -FilesSeed @{ Acls = @{ '' = $badSddl }; Folders = @() }
    $us = & $call $ue (Get-AVDTuneStorageAclDiff -FoundSddl $badSddl -UsersSid $usersSid -AdminsSid $adminsSid -Account 'storageaccount' -Share 'profiles').Hash
    $rec = Get-AVDTuneStorageAclUndo -Root $tmp
    Test-Check 'setting the ACL keeps an undo record: the ACL before and the one Azure keeps now (counter-test #24)' ($us.Status -eq 'Changed' -and $rec -and $rec.Before -eq $badSddl -and $rec.After -eq $goodSddl -and $rec.Account -eq 'storageaccount' -and $rec.Share -eq 'profiles') $null
    Close-AVDTuneWriteGate
    $ug = Undo-AVDTuneStorageRootAcl -Files $ue.Files -Token $stTok -Root $tmp -User 'admin1' -SnapshotId 'snap'
    Test-Check 'undo without the write gate: refused, nothing set (#24)' ($ug.Status -eq 'Failed' -and $ug.Message -like '*Read only*' -and $ue.Files.Store.Puts.Count -eq 1) $ug.Message
    Open-AVDTuneWriteGate -SnapshotId 'snap-check' -ConfirmedBy 'Check Runner'
    $logBefore = @(Get-AVDTuneChangeLog -Root $tmp | Where-Object { $_.Component -eq 'Storage ACL' }).Count
    $uo = Undo-AVDTuneStorageRootAcl -Files $ue.Files -Token $stTok -Root $tmp -User 'admin1' -SnapshotId 'snap'
    $ulog = @(Get-AVDTuneChangeLog -Root $tmp | Where-Object { $_.Component -eq 'Storage ACL' })
    Test-Check 'undo puts the ACL from before back once (attributes and times preserved), with a change log entry without SDDL text (#24)' ($uo.Status -eq 'Changed' -and $ue.Files.Store.Puts.Count -eq 2 -and $ue.Files.Store.Puts[1].Sddl -eq $badSddl -and $ue.Files.Store.Puts[1].Attributes -eq 'preserve' -and $ue.Files.Store.Acls[''] -eq $badSddl -and $ulog.Count -eq $logBefore + 1 -and $ulog[-1].Text -like 'Undo:*' -and $ulog[-1].Text -notmatch 'O:BA') $uo.Message
    $uo2 = Undo-AVDTuneStorageRootAcl -Files $ue.Files -Token $stTok -Root $tmp -User 'admin1' -SnapshotId 'snap'
    Test-Check 'a second undo sets nothing (the root has the ACL from before)' ($uo2.Status -eq 'Failed' -and $ue.Files.Store.Puts.Count -eq 2) $uo2.Message
    $uc = New-Env -FilesSeed @{ Acls = @{ '' = $badSddl }; Folders = @() }
    [void](& $call $uc (Get-AVDTuneStorageAclDiff -FoundSddl $badSddl -UsersSid $usersSid -AdminsSid $adminsSid -Account 'storageaccount' -Share 'profiles').Hash)
    $uc.Files.Store.Acls[''] = 'O:BAG:DUD:PAI(A;OICI;FA;;;BA)'   # someone changed the root after AVDTune set it
    $ucr = Undo-AVDTuneStorageRootAcl -Files $uc.Files -Token $stTok -Root $tmp -User 'admin1' -SnapshotId 'snap'
    Test-Check 'the root changed after AVDTune set it: undo sets nothing (counter-test #24)' ($ucr.Status -eq 'Failed' -and $ucr.Message -like '*changed after AVDTune set it*' -and $uc.Files.Store.Puts.Count -eq 1) $ucr.Message
    $undoFile = Join-Path $tmp 'config\storage-acl-undo.json'
    Test-Check 'older undo records are kept, not overwritten (checklist)' (@(Get-ChildItem -LiteralPath (Join-Path $tmp 'config') -Filter 'storage-acl-undo*.json').Count -ge 2) $null
    foreach ($bad in @(@{ Before = "O:BAG:DUD:PAI(A;OICI;FA;;;WD)`r`nx-ms-evil: 1" }, @{ Before = 'not an sddl' }, @{ Before = 7 }, @{ Account = 'Bad..Account' })) {
        $r0 = [ordered]@{ Account = 'storageaccount'; Share = 'profiles'; Before = $badSddl; Set = $goodSddl; After = $goodSddl }
        foreach ($k in $bad.Keys) { $r0[$k] = $bad[$k] }
        Write-AVDTuneFile $undoFile ($r0 | ConvertTo-Json)
        $ux = Undo-AVDTuneStorageRootAcl -Files $uc.Files -Token $stTok -Root $tmp -User 'admin1' -SnapshotId 'snap'
        Test-Check "an undo record that is not valid is data, not used ($(@($bad.Keys)[0]) = $(@($bad.Values)[0] -replace '[\r\n]', ' '))" ($null -eq (Get-AVDTuneStorageAclUndo -Root $tmp) -and $ux.Status -eq 'Failed' -and $ux.Message -like '*nothing to undo*' -and $uc.Files.Store.Puts.Count -eq 1) $null
    }

    # ---------------------------------------------------------------- access test as a domain user
    $sec = New-TestSecure 'pw'
    Test-Check 'no test user: info, nothing run' ((Get-Row (Invoke-Check (New-Env)) 'st.access').Status -eq 'info') $null
    Test-Check 'a test user without a password: not checkable' ((Get-Row (Invoke-Check (New-Env) @{ TestUser = 'EXAMPLE\t' }) 'st.access').Status -eq 'unknown') $null
    $lg = Invoke-Check (New-Env -FslSeed @{ AsUser = @{ LogonFailed = $true; Error = 'Windows error 1326'; Steps = @() } }) @{ TestUser = 'EXAMPLE\t'; TestPassword = $sec }
    $sf = Invoke-Check (New-Env -FslSeed @{ AsUser = @{ LogonFailed = $false; Error = ''; Steps = @(@{ Name = 'create folder'; Ok = $false; Error = 'Access is denied' }) } }) @{ TestUser = 'EXAMPLE\t'; TestPassword = $sec }
    Test-Check 'logon of the test user fails: red; a step fails (share permission or NTFS): red naming the step' ((Get-Row $lg 'st.access').Status -eq 'red' -and (Get-Row $lg 'st.access').Reason -like '*1326*' -and (Get-Row $sf 'st.access').Status -eq 'red' -and (Get-Row $sf 'st.access').Reason -like '*create folder*') $null

    $okU = Invoke-Check (New-Env) @{ TestUser = 'EXAMPLE\t'; TestPassword = $sec }
    Test-Check 'the green access test says the password is only checked when the share is accessed (counter-test L2)' ((Get-Row $okU 'st.access').Status -eq 'green' -and (Get-Row $okU 'st.access').Reason -like '*password*only checked when the share was accessed*') (Get-Row $okU 'st.access').Reason

    # ---------------------------------------------------------------- storing
    $savedKey = Save-AVDTuneStorageCheckRun -Root $tmp -Result $kr2 -User 'admin1' -SnapshotId 'snap'
    $savedPlain = Save-AVDTuneStorageCheckRun -Root $tmp -Result $r -User 'admin1' -SnapshotId 'snap'
    $log = @(Get-AVDTuneChangeLog -Root $tmp | Where-Object Component -eq 'Storage check')
    Test-Check 'stored: state record, run records, change log notes; the key use is named in the log, the key never' ($log.Count -eq 2 -and @($log | Where-Object { $_.Text -like '*key WAS used*' }).Count -eq 1 -and (Get-AVDTuneState $tmp).StorageCheck.Overall -eq 'green' -and @(Get-AVDTuneRun -Root $tmp | Where-Object Plan -eq 'FSLogix-Storage').Count -eq 2) "$($log.Count) $((Get-AVDTuneState $tmp).StorageCheck.Overall) $(@(Get-AVDTuneRun -Root $tmp | Where-Object Plan -eq 'FSLogix-Storage').Count) $(@($log | ForEach-Object Text) -join ' / ')"
    $leak = (Get-Content -LiteralPath (Join-Path $tmp 'state.json') -Raw) + (Get-Content -LiteralPath (Join-Path $tmp 'changelog.json') -Raw) + (Get-ChildItem (Join-Path $tmp 'runs') -File | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw })
    Test-Check 'no key, token or SDDL in the stored files' ($leak -notmatch [regex]::Escape($efb2.Arm.Store.FakeKey) -and $leak -notmatch 'SECRET' -and $leak -notmatch 'O:BAG') $null
    Test-Check 'the real Files adapter is built without a request' ((New-AVDTuneFilesAdapter).Kind -eq 'Real') $null
}
finally {
    Remove-Item Env:\AVDTUNE_ROOT -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
if ($script:failed -gt 0) { throw "$script:failed check(s) failed." }
