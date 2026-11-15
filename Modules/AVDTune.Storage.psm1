<#
    AVDTune storage check through the Azure sign-in (docs\plans\avdtune.md, section 5a "Storage account check", points 1 to 7; issue 10).

    Finds the storage account behind VHDLocations and checks what a session host needs: the identity of the account (AD DS or Microsoft Entra Kerberos) against
    the domain controller, the SMB settings (Kerberos AES, the RC4 to AES change of April 2026), the private endpoint and the DNS name, the share level
    permission and role assignments, the NTFS rights of the share root against Microsoft's FSLogix recommendation (with a diff; setting only after a
    confirmation of exactly that diff), an access test as a domain user, and the account key only as a fallback after a confirmation for this run.

      * Azure Resource Manager is the ARM adapter of AVDTune.Snapshot.psm1 (host fixed, paths validated). Everything here is GET. The only exception is
        listKeys (POST) of the key fallback, which needs -AllowKeyFallback (the administrator confirmed it for this run) and is named in the result.
      * The data plane (the share's ACL) is the Files adapter ($Files): Invoke = { param($Method, $Url, $Token, $Headers, $Body) } returns
        @{ Status; Headers; Body; Error }. New-AVDTuneFilesAdapter is the real one (only https://<account>.file.core.windows.net, no redirects), the fake is
        Tests\Fakes\FakeStorage.ps1. OAuth (the user's token, x-ms-file-request-intent: backup), never a key.
      * The tokens are parameters of the caller and never stored. The storage token is the optional Storage audience of AVDTune.Session.psm1 (issue 18):
        without it the ACL rows say so. It goes only to https://<account>.file.core.windows.net of the checked account (names validated here, the adapter allows only that host, no redirects).
      * The account key lives in memory for one call: it goes to the Files/SMB mapping adapter members and is removed at the end. It is never written to a file,
        the protocol or the change log, and no result contains it (the checks scan for it).
      * Every row has a source and a Verified flag. What Learn does not state is Verified=false with the reason.
#>

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'AVDTune.psm1')
Import-Module (Join-Path $PSScriptRoot 'AVDTune.Snapshot.psm1')
Import-Module (Join-Path $PSScriptRoot 'AVDTune.Directory.psm1')
Import-Module (Join-Path $PSScriptRoot 'AVDTune.Updates.psm1')
Import-Module (Join-Path $PSScriptRoot 'AVDTune.FSLogix.psm1')

$script:StorageApi = '2024-01-01'
$script:FilesVersion = '2024-11-04'
$script:RoleApi = '2022-04-01'
$script:LearnFiles = 'https://learn.microsoft.com/en-us/azure/storage/files'
$script:LearnRest = 'https://learn.microsoft.com/en-us/rest/api/storageservices'
$script:LearnFsl = 'https://learn.microsoft.com/en-us/fslogix'
# Built-in role ids (Microsoft Learn, built-in roles, Storage section, read 2026-11-15)
$script:Roles = @{
    '0c867c2a-1d8c-454a-a3db-ab2ea1bdc8bb' = 'Storage File Data SMB Share Contributor'
    'a7264617-510b-434b-a828-9731dc254ea7' = 'Storage File Data SMB Share Elevated Contributor'
    '69566ab7-960f-475b-8e7c-b3118f30c6bd' = 'Storage File Data Privileged Contributor'
    'b8eda974-7b85-4f76-af95-65846b26df6d' = 'Storage File Data Privileged Reader'
}

#region names and paths

function Test-AVDTuneStorageAccountName([string]$Name) { $Name -cmatch '^[a-z0-9]{3,24}$' }
function Test-AVDTuneShareName([string]$Name) { $Name -cmatch '^[a-z0-9]([a-z0-9]|-(?!-)){1,61}[a-z0-9]$' }

function Split-AVDTuneUncShare {
    <# '\\account.file.core.windows.net\share\folder' -> @{ Host; Account; Share; Path; IsAzureFiles }; $null when it is not a UNC path #>
    param([string]$Unc)
    if ($Unc -notmatch '^\\\\([^\\]+)\\([^\\]+)(?:\\(.*))?$') { return $null }
    $h = $Matches[1].ToLowerInvariant(); $share = $Matches[2]; $path = if ($Matches.Count -gt 3) { [string]$Matches[3] } else { '' }
    $acct = ''; $az = $false
    if ($h -match '^([a-z0-9]{3,24})\.file\.core\.windows\.net$') { $acct = $Matches[1]; $az = $true }
    [pscustomobject]@{ Host = $h; Account = $acct; Share = $share; Path = $path.Trim('\'); IsAzureFiles = $az }
}

function Test-AVDTunePrivateIp([string]$Ip) {
    # RFC 1918 and the shared address space; what a private endpoint gets
    if ($Ip -notmatch '^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$') { return $false }
    $a = [int]$Matches[1]; $b = [int]$Matches[2]
    ($a -eq 10) -or ($a -eq 172 -and $b -ge 16 -and $b -le 31) -or ($a -eq 192 -and $b -eq 168)
}

function Assert-AVDTuneStorageArmPath {
    param([string]$Path, [string]$Method)
    if ($Path -notmatch '^/subscriptions/[0-9a-fA-F-]{36}/') { throw 'Not an ARM subscription path.' }
    if ($Path -match '[\s\x00-\x1F#]' -or $Path -match '\.\.') { throw 'The ARM path has characters that are not allowed.' }
    if ($Method -notin 'GET', 'POST') { throw "ARM method $Method is not used by the storage check." }
    if ($Method -eq 'POST' -and $Path -notmatch '/providers/Microsoft\.Storage/storageAccounts/[a-z0-9]{3,24}/listKeys\?api-version=[0-9-]+$') { throw 'The only POST of the storage check is listKeys.' }
}

function ConvertTo-AVDTuneStorageNextPath([string]$Link) {
    # A nextLink is an absolute URL: only the ARM host is followed, only as a subscription path
    if ($Link -like 'https://management.azure.com/subscriptions/*') { return $Link.Substring('https://management.azure.com'.Length) }
    throw 'Azure returned a link to another host; it is not followed.'
}

function Invoke-AVDTuneStorageArm {
    <# One ARM call of the storage check: GET (and the listKeys POST of the key fallback). Throws the readable text of Invoke-AVDTuneArm. #>
    param([Parameter(Mandatory)]$Arm, [Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Token, [string]$Method = 'GET', [string]$Action, [string]$Scope)
    Assert-AVDTuneStorageArmPath -Path $Path -Method $Method
    Invoke-AVDTuneArm -Arm $Arm -Method $Method -Path $Path -Token $Token -Action $Action -Scope $Scope
}

function Invoke-AVDTuneStorageFiles {
    <# One data plane call through the Files adapter; the URL is checked here as well (account and share names, https, the file endpoint only). Returns the answer; never throws for a status. #>
    param([Parameter(Mandatory)]$Files, [Parameter(Mandatory)][string]$Method, [Parameter(Mandatory)][string]$Account, [Parameter(Mandatory)][string]$Share, [string]$Path = '', [Parameter(Mandatory)][string]$Query, [Parameter(Mandatory)][string]$Token, [hashtable]$Headers = @{}, [string]$Body)
    if (-not (Test-AVDTuneStorageAccountName $Account)) { throw 'The storage account name is not valid.' }
    if (-not (Test-AVDTuneShareName $Share)) { throw 'The share name is not valid.' }
    if ($Path -and $Path -notmatch '^[^<>:"|?*\\\x00-\x1F]+(/[^<>:"|?*\\\x00-\x1F]+)*$') { throw 'The path is not valid.' }
    if ($Query -notmatch '^[A-Za-z0-9=&_.-]+$') { throw 'The query is not valid.' }
    $url = "https://$Account.file.core.windows.net/$Share" + $(if ($Path) { "/$Path" } else { '' }) + "?$Query"
    $h = @{ 'x-ms-version' = $script:FilesVersion; 'x-ms-file-request-intent' = 'backup' }
    foreach ($k in $Headers.Keys) { $h[$k] = $Headers[$k] }
    & $Files.Invoke $Method $url $Token $h $Body
}

#endregion

#region reading the account

function Find-AVDTuneStorageAccount {
    <# Looks for the account of the share host in the given subscriptions (the one of this VM plus the ones the administrator names). @{ Found; Account (ARM object); Id; ResourceGroup; SubscriptionId; Problems } #>
    param([Parameter(Mandatory)]$Arm, [Parameter(Mandatory)][string]$Token, [Parameter(Mandatory)][string]$AccountName, [Parameter(Mandatory)][string[]]$SubscriptionIds)
    $problems = New-Object System.Collections.ArrayList
    foreach ($sub in $SubscriptionIds) {
        if ($sub -notmatch '^[0-9a-fA-F-]{36}$') { [void]$problems.Add("'$sub' is not a subscription id."); continue }
        try {
            $path = "/subscriptions/$sub/providers/Microsoft.Storage/storageAccounts?api-version=$script:StorageApi"
            $guard = 0
            while ($path -and $guard -lt 20) {
                $guard++
                $r = Invoke-AVDTuneStorageArm -Arm $Arm -Path $path -Token $Token -Action 'Microsoft.Storage/storageAccounts/read' -Scope "subscription $sub"
                $hit = @(@(Get-AVDTuneProp $r 'value') | Where-Object { $_ -and [string]$_.name -ceq $AccountName })
                if ($hit.Count -gt 0) {
                    $id = [string]$hit[0].id
                    $rg = if ($id -match '(?i)/resourceGroups/([^/]+)/') { $Matches[1] } else { '' }
                    return [pscustomobject]@{ Found = $true; Account = $hit[0]; Id = $id; ResourceGroup = $rg; SubscriptionId = $sub; Problems = @($problems) }
                }
                $next = [string](Get-AVDTuneProp $r 'nextLink')
                $path = if ($next) { ConvertTo-AVDTuneStorageNextPath $next } else { $null }
            }
        }
        catch { [void]$problems.Add($_.Exception.Message) }
    }
    [pscustomobject]@{ Found = $false; Account = $null; Id = ''; ResourceGroup = ''; SubscriptionId = ''; Problems = @($problems); Failed = ($problems.Count -ge @($SubscriptionIds).Count) }
}

#endregion

#region domain controller comparison

function Get-AVDTuneLdapValue($Entry, [string]$Name) {
    $v = $Entry.Attributes[$Name]
    if ($null -eq $v) { return $null }
    , (@($v)[0])
}

function ConvertTo-AVDTuneGuid($Value) {
    if ($null -eq $Value) { return '' }
    if ($Value -is [byte[]] -and $Value.Length -eq 16) { return (New-Object Guid (, $Value)).ToString() }
    $g = [guid]::Empty; if ([guid]::TryParse([string]$Value, [ref]$g)) { $g.ToString() } else { '' }
}

function Get-AVDTuneStorageAdCompare {
    <#
        The AD object of a storage account (AD DS authentication) against what Azure says (activeDirectoryProperties) and against the domain. Read only (LDAP).
        Returns @{ Rows (id, status, text, fix) ; Object (dn, sid, spns, pwdLastSet, daysLeft, encryption) }. -Now: the clock (a fixed one in checks).
    #>
    param([Parameter(Mandatory)]$Ldap, [Parameter(Mandatory)]$Connection, [Parameter(Mandatory)]$Ad, [Parameter(Mandatory)][string]$AccountName, [Parameter(Mandatory)][string]$DefaultNamingContext, [datetime]$Now = (Get-Date))
    $rows = New-Object System.Collections.ArrayList
    $row = { param($id, $status, $text, $fix) [void]$rows.Add([pscustomobject]@{ Id = $id; Status = $status; Text = $text; Fix = $fix }) }
    $sam = [string](Get-AVDTuneProp $Ad 'samAccountName')
    if (-not $sam) { $sam = $AccountName }
    $obj = $null
    $entries = @(& $Ldap.Search $Connection $DefaultNamingContext "(|(sAMAccountName=$(ConvertTo-AVDTuneLdapFilterValue $sam))(sAMAccountName=$(ConvertTo-AVDTuneLdapFilterValue ($sam + '$'))))" 'Subtree' @('distinguishedName', 'objectSid', 'servicePrincipalName', 'pwdLastSet', 'userAccountControl', 'msDS-SupportedEncryptionTypes', 'objectClass'))
    if ($entries.Count -eq 0) {
        & $row 'ad.object' 'red' "The AD object '$sam' of the storage account does not exist in the domain. Azure says the account is domain joined, but the object is gone: Kerberos cannot work." "Recreate the object (domain join of the storage account again) or fix samAccountName in Azure."
        return [pscustomobject]@{ Rows = @($rows); Object = $null }
    }
    if ($entries.Count -gt 1) { & $row 'ad.object' 'yellow' "$($entries.Count) AD objects match '$sam'; the first one is compared." 'Remove the duplicates.' }
    $e = $entries[0]
    $sid = ConvertTo-AVDTuneSid (Get-AVDTuneLdapValue $e 'objectSid')
    $wantSid = [string](Get-AVDTuneProp $Ad 'azureStorageSid')
    if ($wantSid -and $sid -and $sid -ne $wantSid) { & $row 'ad.sid' 'red' "The SID of the AD object ($sid) differs from azureStorageSid in Azure ($wantSid): the object was recreated and Azure still points to the old one." 'Domain join the storage account again (AzFilesHybrid or the AVDTune setup).' }
    elseif ($sid) { & $row 'ad.sid' 'green' 'The SID of the AD object matches azureStorageSid.' '' }
    else { & $row 'ad.sid' 'yellow' 'The SID of the AD object could not be read.' '' }
    $spns = @(@($e.Attributes['servicePrincipalName']) | Where-Object { $_ } | ForEach-Object { [string]$_ })
    $wantSpn = "cifs/$AccountName.file.core.windows.net"
    if ($spns | Where-Object { $_ -ieq $wantSpn }) { & $row 'ad.spn' 'green' "The SPN $wantSpn is set." '' }
    else { & $row 'ad.spn' 'red' "The SPN $wantSpn is not set on the AD object: clients get no Kerberos ticket for the share." "Set the SPN (setspn -S $wantSpn <object>) or domain join the storage account again." }
    # the domain: SID and GUID against Azure, maximum password age
    $dom = @(& $Ldap.Search $Connection $DefaultNamingContext '(objectClass=domainDNS)' 'Base' @('objectSid', 'objectGUID', 'maxPwdAge'))
    $maxAgeDays = 0
    if ($dom.Count -gt 0) {
        $d = $dom[0]
        $dsid = ConvertTo-AVDTuneSid (Get-AVDTuneLdapValue $d 'objectSid'); $dguid = ConvertTo-AVDTuneGuid (Get-AVDTuneLdapValue $d 'objectGUID')
        $wantDomSid = [string](Get-AVDTuneProp $Ad 'domainSid'); $wantGuid = [string](Get-AVDTuneProp $Ad 'domainGuid')
        if (($wantDomSid -and $dsid -and $wantDomSid -ne $dsid) -or ($wantGuid -and $dguid -and $wantGuid -ne $dguid)) { & $row 'ad.domain' 'red' 'domainSid or domainGuid in Azure differ from this domain: the storage account is joined to another domain.' 'Check that the domain controller and the storage account belong together; join again if needed.' }
        else { & $row 'ad.domain' 'green' 'domainSid and domainGuid match the domain.' '' }
        $ma = Get-AVDTuneLdapValue $d 'maxPwdAge'
        if ($null -ne $ma -and [string]$ma -match '^-?\d+$') { $ticks = [int64][string]$ma; if ($ticks -lt 0) { $maxAgeDays = [math]::Floor(([double](-$ticks)) / 864000000000) } }
    }
    # password of the object (it is one of the Kerberos keys of the storage account)
    $uac = Get-AVDTuneLdapValue $e 'userAccountControl'
    $pls = Get-AVDTuneLdapValue $e 'pwdLastSet'
    $daysLeft = $null
    $neverExpires = ($null -ne $uac -and [string]$uac -match '^\d+$' -and (([int64][string]$uac) -band 0x10000) -ne 0)
    if ($neverExpires) { & $row 'ad.password' 'green' 'The password of the AD object does not expire (DONT_EXPIRE_PASSWORD).' '' }
    elseif ($null -eq $pls -or [string]$pls -notmatch '^\d+$' -or [int64][string]$pls -le 0) { & $row 'ad.password' 'yellow' 'pwdLastSet is not set or 0; the password age cannot be judged.' '' }
    elseif ($maxAgeDays -le 0) { & $row 'ad.password' 'green' 'The domain has no maximum password age: the password of the AD object does not expire.' '' }
    else {
        $set = [datetime]::FromFileTimeUtc([int64][string]$pls)
        $daysLeft = [math]::Floor(($set.AddDays($maxAgeDays) - $Now.ToUniversalTime()).TotalDays)
        if ($daysLeft -lt 0) { & $row 'ad.password' 'red' "The password of the AD object expired $(-$daysLeft) day(s) ago (set $($set.ToString('yyyy-MM-dd')), maximum age $maxAgeDays days). Logons to the share fail with Kerberos errors." 'Rotate the password to a Kerberos key of the storage account (Update-AzStorageAccountADObjectPassword, from a domain joined client; it changes the key, so AVDTune only explains it) or move the object to an OU without password expiry.' }
        elseif ($daysLeft -lt 14) { & $row 'ad.password' 'yellow' "The password of the AD object expires in $daysLeft day(s) (set $($set.ToString('yyyy-MM-dd')), maximum age $maxAgeDays days). An expired password is a common cause of FSLogix logon failures." 'Rotate the password before it expires (Update-AzStorageAccountADObjectPassword from a domain joined client; AVDTune does not rotate keys) or move the object to an OU without password expiry.' }
        else { & $row 'ad.password' 'green' "The password of the AD object expires in $daysLeft day(s)." '' }
    }
    # Kerberos encryption types of the object (RC4 to AES, April 2026)
    $enc = Get-AVDTuneLdapValue $e 'msDS-SupportedEncryptionTypes'
    $encInt = if ($null -ne $enc -and [string]$enc -match '^\d+$') { [int][string]$enc } else { 0 }
    if (($encInt -band 0x18) -ne 0) { & $row 'ad.enctype' 'green' "msDS-SupportedEncryptionTypes ($encInt) allows AES." '' }
    else { & $row 'ad.enctype' 'yellow' "msDS-SupportedEncryptionTypes is $(if ($null -eq $enc) { 'not set' } else { $encInt }): the object does not say that AES is supported. The April 2026 Windows update changes the default Kerberos encryption from RC4 to AES-SHA1; a share that is not upgraded may lose access." 'Set msDS-SupportedEncryptionTypes on the object to include AES256 (value 16, or 24 for AES128 and AES256) and rotate the password afterwards so the AES keys exist; see the Learn page and the FSLogix blog.' }
    [pscustomobject]@{ Rows = @($rows); Object = [pscustomobject]@{ Dn = [string](Get-AVDTuneLdapValue $e 'distinguishedName'); Sid = $sid; Spns = $spns; DaysLeft = $daysLeft; MaxPasswordAgeDays = $maxAgeDays; EncryptionTypes = $encInt } }
}

#endregion

#region NTFS ACL over REST

function Get-AVDTuneStorageShareAcl {
    <#
        SDDL of the root (or of a folder) of a share, with the user's token (no key): the properties of the directory give the permission key, Get Permission gives the SDDL.
        Returns @{ Ok; Sddl; Status; Error; Kind (Ok | Forbidden | NotFound | Failed) }.
    #>
    param([Parameter(Mandatory)]$Files, [Parameter(Mandatory)][string]$Account, [Parameter(Mandatory)][string]$Share, [string]$Path = '', [Parameter(Mandatory)][string]$Token)
    $h = @{ 'x-ms-date' = [DateTime]::UtcNow.ToString('R', [Globalization.CultureInfo]::InvariantCulture) }
    $r = Invoke-AVDTuneStorageFiles -Files $Files -Method GET -Account $Account -Share $Share -Path $Path -Query 'restype=directory' -Token $Token -Headers $h
    $fail = { param($r, $what) $k = switch ([int]$r.Status) { 403 { 'Forbidden' } 401 { 'Forbidden' } 404 { 'NotFound' } default { 'Failed' } }; [pscustomobject]@{ Ok = $false; Sddl = ''; Status = [int]$r.Status; Kind = $k; Error = "$what answered $($r.Status)$(if ($r.Error) { ': ' + $r.Error })" } }
    if ([int]$r.Status -lt 200 -or [int]$r.Status -ge 300) { return (& $fail $r 'Get Directory Properties') }
    $key = ''
    foreach ($k in @($r.Headers.Keys)) { if ([string]$k -ieq 'x-ms-file-permission-key') { $key = [string]$r.Headers[$k] } }
    if (-not $key) { return [pscustomobject]@{ Ok = $false; Sddl = ''; Status = [int]$r.Status; Kind = 'Failed'; Error = 'The answer has no x-ms-file-permission-key.' } }
    if ($key -notmatch '^[A-Za-z0-9*+/=_.-]{1,200}$') { return [pscustomobject]@{ Ok = $false; Sddl = ''; Status = [int]$r.Status; Kind = 'Failed'; Error = 'The permission key has an unexpected format.' } }
    $h2 = @{ 'x-ms-date' = [DateTime]::UtcNow.ToString('R', [Globalization.CultureInfo]::InvariantCulture); 'x-ms-file-permission-key' = $key; 'x-ms-file-permission-format' = 'sddl' }
    $r2 = Invoke-AVDTuneStorageFiles -Files $Files -Method GET -Account $Account -Share $Share -Query 'restype=share&comp=filepermission' -Token $Token -Headers $h2
    if ([int]$r2.Status -lt 200 -or [int]$r2.Status -ge 300) { return (& $fail $r2 'Get Permission') }
    $body = $null; try { $body = [string]$r2.Body | ConvertFrom-Json } catch { }
    $sddl = [string](Get-AVDTuneProp $body 'permission')
    if (-not $sddl) { return [pscustomobject]@{ Ok = $false; Sddl = ''; Status = [int]$r2.Status; Kind = 'Failed'; Error = 'The answer has no permission.' } }
    [pscustomobject]@{ Ok = $true; Sddl = $sddl; Status = [int]$r2.Status; Kind = 'Ok'; Error = '' }
}

function Get-AVDTuneStorageProfileFolders {
    <# Names of the first folders in the share root (List Directories and Files), at most $Max; empty on any problem #>
    param([Parameter(Mandatory)]$Files, [Parameter(Mandatory)][string]$Account, [Parameter(Mandatory)][string]$Share, [Parameter(Mandatory)][string]$Token, [int]$Max = 5)
    $h = @{ 'x-ms-date' = [DateTime]::UtcNow.ToString('R', [Globalization.CultureInfo]::InvariantCulture) }
    $r = Invoke-AVDTuneStorageFiles -Files $Files -Method GET -Account $Account -Share $Share -Query "restype=directory&comp=list&maxresults=$Max" -Token $Token -Headers $h
    if ([int]$r.Status -lt 200 -or [int]$r.Status -ge 300 -or -not $r.Body) { return @() }
    $settings = New-Object System.Xml.XmlReaderSettings; $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit; $settings.XmlResolver = $null
    try {
        $doc = New-Object System.Xml.XmlDocument; $doc.XmlResolver = $null
        $rd = [System.Xml.XmlReader]::Create((New-Object IO.StringReader ([string]$r.Body).TrimStart([char]0xFEFF)), $settings); try { $doc.Load($rd) } finally { $rd.Close() }
        @($doc.SelectNodes('//Directory/Name') | ForEach-Object { [string]$_.InnerText } | Where-Object { $_ -and $_ -match '^[^<>:"|?*\\/\x00-\x1F]+$' } | Select-Object -First $Max)
    }
    catch { @() }
}

function Get-AVDTuneStorageAclDiff {
    <# The shown diff before the ACL is set: what is there, what the recommendation is, the findings. Returns @{ Sddl (found); Recommended (SDDL); Findings; Found; Expected; Hash (of account, share, recommended and found SDDL, to confirm exactly this), Account, Share } #>
    param([Parameter(Mandatory)][string]$FoundSddl, [Parameter(Mandatory)][string]$UsersSid, [Parameter(Mandatory)][string]$AdminsSid, [Parameter(Mandatory)][string]$Account, [Parameter(Mandatory)][string]$Share)
    $rec = New-AVDTuneFSLogixRecommendedSddl -UsersSid $UsersSid -AdminsSid $AdminsSid
    $cmp = Compare-AVDTuneFSLogixAcl -Sddl $FoundSddl -UsersSids @($UsersSid) -AdminsSids @($AdminsSid)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Account.ToLowerInvariant() + '|' + $Share.ToLowerInvariant() + '|' + $rec + '|' + $FoundSddl))) -replace '-', '').Substring(0, 16) } finally { $sha.Dispose() }
    [pscustomobject]@{ Sddl = $FoundSddl; Recommended = $rec; Findings = @($cmp.Findings); Found = @($cmp.Found); Expected = @((ConvertFrom-AVDTuneSddl $rec).Aces | ForEach-Object { Format-AVDTuneAce $_ }); Compliant = [bool]$cmp.Compliant; Hash = $hash; Account = $Account; Share = $Share }
}

function Set-AVDTuneStorageRootAcl {
    <#
        Sets the recommended ACL on the share root (Set Directory Properties, x-ms-file-permission, attributes and times preserved), with the user's token (role: Storage File Data
        Privileged Contributor). Only with -ConfirmedHash: the hash of the diff the administrator saw (Get-AVDTuneStorageAclDiff); the ACL is read again first and when it changed
        since, nothing is set. The change goes into the change log. Returns @{ Status Changed | Unchanged | Failed; Message }.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Files, [Parameter(Mandatory)][string]$Account, [Parameter(Mandatory)][string]$Share, [Parameter(Mandatory)][string]$Token, [Parameter(Mandatory)][string]$UsersSid, [Parameter(Mandatory)][string]$AdminsSid,
        [Parameter(Mandatory)][string]$ConfirmedHash, [string]$Root = (Get-AVDTuneRoot), [string]$User, [string]$SnapshotId)
    if (-not (Test-AVDTuneWriteAllowed)) { return [pscustomobject]@{ Status = 'Failed'; Message = 'Read only: confirm a snapshot of today on the Overview first. Nothing was set.' } }
    $changeOwner = $false; if ($true) { $changeOwner = Start-AVDTuneChange -Root $Root }   # marker: the first change of the version starts here, no new version or snapshot counts while it runs (#27)
    try {
    $now = Get-AVDTuneStorageShareAcl -Files $Files -Account $Account -Share $Share -Token $Token
    if (-not $now.Ok) { return [pscustomobject]@{ Status = 'Failed'; Message = "The current ACL cannot be read, so nothing is set: $($now.Error)" } }
    $diff = Get-AVDTuneStorageAclDiff -FoundSddl $now.Sddl -UsersSid $UsersSid -AdminsSid $AdminsSid -Account $Account -Share $Share
    if ($diff.Hash -ne $ConfirmedHash) { return [pscustomobject]@{ Status = 'Failed'; Message = 'The ACL on the share changed after the diff was shown (or the diff is not the confirmed one). Nothing was set: look at the new diff and confirm it again.' } }
    if ($diff.Compliant) { return [pscustomobject]@{ Status = 'Unchanged'; Message = 'The root already matches the recommendation.' } }
    $h = @{ 'x-ms-date' = [DateTime]::UtcNow.ToString('R', [Globalization.CultureInfo]::InvariantCulture); 'x-ms-file-permission' = $diff.Recommended; 'x-ms-file-permission-format' = 'sddl'
        'x-ms-file-attributes' = 'preserve'; 'x-ms-file-creation-time' = 'preserve'; 'x-ms-file-last-write-time' = 'preserve' }
    $r = Invoke-AVDTuneStorageFiles -Files $Files -Method PUT -Account $Account -Share $Share -Query 'restype=directory&comp=properties' -Token $Token -Headers $h
    [void](Set-AVDTuneState -Root $Root -Values @{ LastChange = [DateTime]::UtcNow.ToString('o') })   # also a failed attempt may have changed part of it
    if ([int]$r.Status -lt 200 -or [int]$r.Status -ge 300) {
        $why = if ([int]$r.Status -in 401, 403) { 'The signed-in account lacks the role Storage File Data Privileged Contributor (or SMB Share Elevated Contributor does not apply to the REST call).' } else { "Azure answered $($r.Status)." }
        return [pscustomobject]@{ Status = 'Failed'; Message = "The ACL was not set. $why$(if ($r.Error) { ' (' + $r.Error + ')' })" }
    }
    $state = Get-AVDTuneState $Root
    if ($state.ImageVersion) { [void](Add-AVDTuneChangeLogEntry -Root $Root -Version $state.ImageVersion -Category 'FSLogix' -Component 'Storage ACL' -ChangeType Changed -Text "NTFS ACL of the root of share $Share on storage account $Account set to Microsoft's FSLogix recommendation ($(@($diff.Findings).Count) finding(s) fixed)" -User $User -SnapshotId $SnapshotId -Source Step) }
    [pscustomobject]@{ Status = 'Changed'; Message = "The recommended ACL was set on the root of $Share." }
    }
    finally { Stop-AVDTuneChange -Root $Root -Owner $changeOwner }
}

#endregion

#region the check

function New-AVDTuneStRow {
    param([string]$Id, [int]$Step, [string]$Title, [ValidateSet('green', 'yellow', 'red', 'info', 'unknown')][string]$Status, [string]$Reason, [string]$Fix = '', [string]$Source = $script:LearnFiles, [bool]$Verified = $true, [string]$Note = '')
    if (-not $Verified -and -not $Note) { $Note = 'Not stated on Microsoft Learn: the check, the threshold or the recommendation is AVDTune''s own (the source is the nearest Learn page).' }
    [pscustomobject]@{ Id = $Id; Step = $Step; Title = $Title; Status = $Status; Reason = $Reason; Fix = $Fix; Source = $Source; Verified = $Verified; Note = $Note }
}

function Get-AVDTuneStorageRoleNames {
    param($Assignments)
    @(@($Assignments) | Where-Object { $_ } | ForEach-Object { $id = ([string]$_.properties.roleDefinitionId -split '/')[-1].ToLowerInvariant(); if ($script:Roles.ContainsKey($id)) { [pscustomobject]@{ Role = $script:Roles[$id]; PrincipalId = [string]$_.properties.principalId; Scope = [string]$_.properties.scope } } })
}

function Invoke-AVDTuneStorageCheck {
    <#
        The storage check (plan 5a, points 1 to 6, 7 as the fallback). Needs the ARM adapter and token for the account side; the Files adapter and a storage token for the ACL;
        an LDAP adapter and connection for the comparison with the domain controller. What is missing makes the rows 'unknown' (not checkable) with the reason, never green.
        -Locations: the VHDLocations of the master. -SubscriptionIds: where to look (the subscription of this VM first). -CallerOid: object id of the signed-in user (his direct role assignments).
        -AllowKeyFallback: the administrator confirmed for THIS run that the account key may be used (only when the token path to the ACL fails with 403): listKeys, in memory, mapping removed at
        the end, never stored. -TestUser/-TestPassword/-DomainController: the access test as a domain user.
        Returns Rows, Counts, Overall, Account (name, resource id), KeyUsed, AclDiff (when the ACL deviates and the groups are known), At.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Machine, [Parameter(Mandatory)]$F, $Arm, [string]$ArmToken, $Files, [string]$StorageToken, $Ldap, $LdapConnection, [string]$DefaultNamingContext,
        [string[]]$Locations = @(), [string[]]$SubscriptionIds = @(), [string]$CallerOid, [string[]]$UsersSids = @(), [string[]]$AdminsSids = @(),
        [switch]$AllowKeyFallback, [string]$TestUser, [System.Security.SecureString]$TestPassword, [string]$DomainController, [string]$NoArmReason, [string]$NoStorageReason, [datetime]$Now = (Get-Date)
    )
    $rows = New-Object System.Collections.ArrayList
    function Add([object]$r) { [void]$rows.Add($r) }
    $ctx = @{ KeyUsed = $false; AclDiff = $null; AccountName = ''; AccountId = '' }
    $share = $null
    foreach ($l in $Locations) { $p = Split-AVDTuneUncShare $l; if ($p -and $p.IsAzureFiles) { $share = $p; break } }
    $first = @($Locations)[0]
    if (-not $first) { Add (New-AVDTuneStRow 'st.account' 1 'Storage account' 'info' 'No VHDLocations on this master: nothing to check.'); return (Get-AVDTuneStorageResult $rows $ctx $Now) }
    if (-not $share) { Add (New-AVDTuneStRow 'st.account' 1 'Storage account' 'info' "VHDLocations ($first) is not an Azure Files share (<account>.file.core.windows.net): the Azure checks do not apply. The function test checks the share from the master." -Verified $false); return (Get-AVDTuneStorageResult $rows $ctx $Now) }
    $ctx.AccountName = $share.Account
    $unknown = { param($id, $step, $title, $why, $src) Add (New-AVDTuneStRow $id $step $title 'unknown' "Not checkable: $why" '' $src) }
    $acc = $null; $props = $null
    # 1 the account
    if (-not $Arm -or -not $ArmToken) {
        $why = if ($NoArmReason) { $NoArmReason } else { 'not signed in to Azure: sign in on the Overview.' }
        foreach ($id in 'st.account', 'st.identity', 'st.smb', 'st.network', 'st.roles') { & $unknown $id 1 $id $why $script:LearnFiles }
    }
    else {
        $subs = @(@($SubscriptionIds) | Where-Object { $_ } | Select-Object -Unique)
        try {
            if ($subs.Count -eq 0) { throw 'No subscription is known: this VM is not in Azure or its metadata is not reachable. Enter a subscription id.' }
            $acc = Find-AVDTuneStorageAccount -Arm $Arm -Token $ArmToken -AccountName $share.Account -SubscriptionIds $subs
            if ($acc.Found) { $props = Get-AVDTuneProp $acc.Account 'properties'; $ctx.AccountId = $acc.Id; Add (New-AVDTuneStRow 'st.account' 1 'Storage account' 'green' "Found $($share.Account) in subscription $($acc.SubscriptionId), resource group $($acc.ResourceGroup)." -Source "$script:LearnFiles/storage-files-introduction" -Verified $false) }
            elseif ($acc.Failed) { Add (New-AVDTuneStRow 'st.account' 1 'Storage account' 'unknown' "Not checkable: $($acc.Problems -join ' ')" 'Reader on the storage account (or the subscription) and a working connection to Azure are needed.' -Source "$script:LearnFiles/storage-files-introduction" -Verified $false) }
            else { Add (New-AVDTuneStRow 'st.account' 1 'Storage account' 'red' "The storage account $($share.Account) is not in the subscription(s) the signed-in user can read ($($subs -join ', ')).$(if ($acc.Problems.Count -gt 0) { ' ' + ($acc.Problems -join ' ') })" 'Sign in with an account that has Reader on the account, or add the subscription of the account.' -Source "$script:LearnFiles/storage-files-introduction" -Verified $false) }
        }
        catch { Add (New-AVDTuneStRow 'st.account' 1 'Storage account' 'unknown' "Not checkable: $($_.Exception.Message)" 'Reader on the storage account (or the subscription) is needed.' -Source "$script:LearnFiles/storage-files-introduction" -Verified $false) }
        if ($props) {
            $sku = [string](Get-AVDTuneProp (Get-AVDTuneProp $acc.Account 'sku') 'name'); $kind = [string](Get-AVDTuneProp $acc.Account 'kind')
            if ($kind -eq 'FileStorage' -or $sku -like 'Premium*') { Add (New-AVDTuneStRow 'st.sku' 1 'Account type' 'green' "${kind}, ${sku} (premium file storage)." -Source "$script:LearnFiles/understanding-billing" -Verified $false -Note 'Premium for FSLogix is the recommendation of the plan (latency, IOPS); Learn is not quoted for it here.') }
            else { Add (New-AVDTuneStRow 'st.sku' 1 'Account type' 'yellow' "${kind}, ${sku}: a standard account is not recommended for FSLogix profiles (latency, IOPS)." 'Use a premium FileStorage account for profiles.' -Source "$script:LearnFiles/understanding-billing" -Verified $false -Note 'The recommendation is the plan''s; Learn is not quoted for it here.') }
            # 2 identity
            $ia = Get-AVDTuneProp $props 'azureFilesIdentityBasedAuthentication'
            $dso = [string](Get-AVDTuneProp $ia 'directoryServiceOptions')
            $adp = Get-AVDTuneProp $ia 'activeDirectoryProperties'
            switch ($dso) {
                'AD' {
                    Add (New-AVDTuneStRow 'st.identity' 2 'Identity of the account' 'green' 'Authentication: Active Directory Domain Services (AD DS).' -Source "$script:LearnFiles/storage-files-identity-ad-ds-overview" -Verified $false)
                    if (-not $adp) { Add (New-AVDTuneStRow 'st.ad' 2 'AD object of the account' 'red' 'directoryServiceOptions is AD but activeDirectoryProperties is empty.' 'Domain join the storage account again.') }
                    elseif (-not $Ldap -or -not $LdapConnection -or -not $DefaultNamingContext) { Add (New-AVDTuneStRow 'st.ad' 2 'AD object of the account' 'unknown' 'Not checkable: no domain controller connection (the start sequence connects it). SID, SPN and password age of the AD object are compared with it.' 'Connect to the domain controller on the Overview.' -Source "$script:LearnFiles/storage-files-identity-ad-ds-update-password" -Verified $false) }
                    else {
                        try {
                            $c = Get-AVDTuneStorageAdCompare -Ldap $Ldap -Connection $LdapConnection -Ad $adp -AccountName $share.Account -DefaultNamingContext $DefaultNamingContext -Now $Now
                            foreach ($r in $c.Rows) { Add (New-AVDTuneStRow "st.$($r.Id)" 2 "AD object: $($r.Id -replace '^ad\.', '')" $r.Status $r.Text $r.Fix -Source $(if ($r.Id -eq 'ad.enctype') { "$script:LearnFsl/overview-prerequisites" } else { "$script:LearnFiles/storage-files-identity-ad-ds-update-password" }) -Verified ($r.Id -notin 'ad.enctype', 'ad.spn', 'ad.sid', 'ad.domain') -Note $(if ($r.Id -eq 'ad.enctype') { 'Learn announces the RC4 to AES-SHA1 change; the attribute and its values come from the Active Directory documentation, not from that page.' } elseif ($r.Id -in 'ad.spn', 'ad.sid', 'ad.domain') { 'The comparison is AVDTune''s own, built from the activeDirectoryProperties fields of the ARM reference.' } else { '' })) }
                        }
                        catch { Add (New-AVDTuneStRow 'st.ad' 2 'AD object of the account' 'unknown' "Not checkable: the domain controller could not be read ($($_.Exception.Message))." '' ) }
                    }
                }
                'AADKERB' {
                    Add (New-AVDTuneStRow 'st.identity' 2 'Identity of the account' 'green' 'Authentication: Microsoft Entra Kerberos.' -Source "$script:LearnFiles/storage-files-identity-auth-hybrid-identities-enable")
                    $ck = & $Machine.RegGet 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\Kerberos\Parameters' 'CloudKerberosTicketRetrievalEnabled'
                    if ([string]$ck -eq '1') { Add (New-AVDTuneStRow 'st.entra.cloudkerb' 2 'Master: CloudKerberosTicketRetrievalEnabled' 'green' 'CloudKerberosTicketRetrievalEnabled is 1 on this master.' -Source "$script:LearnFiles/storage-files-identity-auth-hybrid-identities-enable") }
                    else { Add (New-AVDTuneStRow 'st.entra.cloudkerb' 2 'Master: CloudKerberosTicketRetrievalEnabled' 'yellow' "CloudKerberosTicketRetrievalEnabled is '$ck' on this master (it must be 1 on the session hosts; Learn: use the Intune settings catalog, the OMA-URI method does not work on multi-session)." 'Set HKLM\SYSTEM\CurrentControlSet\Control\Lsa\Kerberos\Parameters\CloudKerberosTicketRetrievalEnabled=1 in the image or by policy.' -Source "$script:LearnFiles/storage-files-identity-auth-hybrid-identities-enable") }
                    Add (New-AVDTuneStRow 'st.entra.consent' 2 'Entra app: admin consent and Conditional Access' 'info' 'Check by hand: the storage account app (name: [Storage Account] <account>.file.core.windows.net) needs admin consent (openid, profile, User.Read) and must be excluded from Conditional Access policies that require MFA. AVDTune does not read Entra applications in this version.' 'Entra admin center: Enterprise applications / Conditional Access.' -Source "$script:LearnFiles/storage-files-identity-auth-hybrid-identities-enable" -Note 'Reading this needs Microsoft Graph application permissions that AVDTune does not request yet.')
                }
                'AADDS' { Add (New-AVDTuneStRow 'st.identity' 2 'Identity of the account' 'green' 'Authentication: Microsoft Entra Domain Services.' -Source "$script:LearnFiles/storage-files-identity-auth-domain-services-enable" -Verified $false) }
                default { Add (New-AVDTuneStRow 'st.identity' 2 'Identity of the account' 'red' "No identity based authentication is enabled on the account (directoryServiceOptions '$dso'): users cannot sign in to the share with their identity." 'Enable AD DS, Entra Kerberos or Entra Domain Services authentication on the storage account.' -Source "$script:LearnFiles/storage-files-active-directory-overview" -Verified $false) }
            }
            # 3 SMB settings (file service) and network
            try {
                $fs = Invoke-AVDTuneStorageArm -Arm $Arm -Token $ArmToken -Path "/subscriptions/$($acc.SubscriptionId)/resourceGroups/$($acc.ResourceGroup)/providers/Microsoft.Storage/storageAccounts/$($share.Account)/fileServices/default?api-version=$script:StorageApi" -Action 'Microsoft.Storage/storageAccounts/fileServices/read' -Scope $share.Account
                $smb = Get-AVDTuneProp (Get-AVDTuneProp (Get-AVDTuneProp $fs 'properties') 'protocolSettings') 'smb'
                $src = "https://learn.microsoft.com/en-us/rest/api/storagerp/file-services/get-service-properties"
                $split = { param($t) @(([string]$t -split ';') | Where-Object { $_ }) }
                $kte = @(& $split (Get-AVDTuneProp $smb 'kerberosTicketEncryption')); $vers = @(& $split (Get-AVDTuneProp $smb 'versions')); $auth = @(& $split (Get-AVDTuneProp $smb 'authenticationMethods')); $chan = @(& $split (Get-AVDTuneProp $smb 'channelEncryption'))
                if ($kte.Count -eq 0) { Add (New-AVDTuneStRow 'st.smb.kerberos' 3 'SMB: Kerberos ticket encryption' 'yellow' 'No Kerberos ticket encryption is configured on the file service: all algorithms (RC4-HMAC and AES-256) are allowed. The April 2026 Windows change from RC4 to AES-SHA1 may break shares that rely on RC4.' 'Set the file service to AES-256 only once the AD object (or Entra Kerberos) supports AES.' -Source "$script:LearnFsl/overview-prerequisites" -Note 'The setting itself is in the ARM reference (file services); the RC4 to AES change is the notice on the FSLogix prerequisites page.') }
                elseif ($kte -notcontains 'AES-256') { Add (New-AVDTuneStRow 'st.smb.kerberos' 3 'SMB: Kerberos ticket encryption' 'red' "Only $($kte -join ', ') is allowed: AES-256 is missing. After the April 2026 Windows update (default Kerberos encryption RC4 to AES-SHA1) session hosts can no longer get a ticket." 'Allow AES-256 in the SMB security settings of the file service.' -Source "$script:LearnFsl/overview-prerequisites") }
                elseif ($kte -contains 'RC4-HMAC') { Add (New-AVDTuneStRow 'st.smb.kerberos' 3 'SMB: Kerberos ticket encryption' 'yellow' 'AES-256 and RC4-HMAC are both allowed. That works, but RC4 is going away; once every client and the AD object use AES, allow AES-256 only.' 'Remove RC4-HMAC when no client needs it.' -Source "$script:LearnFsl/overview-prerequisites" -Verified $false -Note 'That removing RC4 is the end state is AVDTune''s reading of the notice; Learn only asks to complete the upgrade to AES-SHA1.') }
                else { Add (New-AVDTuneStRow 'st.smb.kerberos' 3 'SMB: Kerberos ticket encryption' 'green' 'Kerberos ticket encryption is AES-256 only.' -Source "$script:LearnFsl/overview-prerequisites") }
                if ($vers.Count -gt 0 -and $vers -notcontains 'SMB3.1.1') { Add (New-AVDTuneStRow 'st.smb.versions' 3 'SMB versions' 'yellow' "SMB 3.1.1 is not allowed (allowed: $($vers -join ', ')): the best encryption and integrity of Windows 11 cannot be used." 'Allow SMB 3.1.1.' -Source $src -Verified $false -Note 'Recommendation of the plan (section 1b); not a statement of the reference.') }
                elseif ($vers -contains 'SMB2.1') { Add (New-AVDTuneStRow 'st.smb.versions' 3 'SMB versions' 'yellow' 'SMB 2.1 is allowed: it has no encryption in transit.' 'Remove SMB 2.1 unless an old client needs it.' -Source $src -Verified $false) }
                else { Add (New-AVDTuneStRow 'st.smb.versions' 3 'SMB versions' 'green' "SMB versions: $(if ($vers.Count -gt 0) { $vers -join ', ' } else { 'all (default)' })." -Source $src -Verified $false) }
                if ($dso -in 'AD', 'AADKERB' -and $auth.Count -gt 0 -and $auth -notcontains 'Kerberos') { Add (New-AVDTuneStRow 'st.smb.auth' 3 'SMB: authentication methods' 'red' "Kerberos is not an allowed authentication method ($($auth -join ', ')): identity based access cannot work." 'Allow Kerberos in the SMB security settings.' -Source $src) }
                else { Add (New-AVDTuneStRow 'st.smb.auth' 3 'SMB: authentication methods' 'green' "Authentication methods: $(if ($auth.Count -gt 0) { $auth -join ', ' } else { 'all (default)' })." -Source $src) }
                if ($chan.Count -gt 0 -and $chan -notcontains 'AES-256-GCM') { Add (New-AVDTuneStRow 'st.smb.channel' 3 'SMB: channel encryption' 'yellow' "AES-256-GCM is not allowed ($($chan -join ', ')); the plan asks for AES-256-GCM." 'Allow AES-256-GCM.' -Source $src -Verified $false -Note 'Recommendation of the plan; not a statement of the reference.') }
                else { Add (New-AVDTuneStRow 'st.smb.channel' 3 'SMB: channel encryption' 'green' "Channel encryption: $(if ($chan.Count -gt 0) { $chan -join ', ' } else { 'all (default)' })." -Source $src -Verified $false) }
            }
            catch { Add (New-AVDTuneStRow 'st.smb' 3 'SMB settings' 'unknown' "Not checkable: $($_.Exception.Message)" 'Reader on the storage account is needed.' -Source 'https://learn.microsoft.com/en-us/rest/api/storagerp/file-services/get-service-properties') }
            # network: private endpoint, public access, DNS from the master
            $pe = @(@(Get-AVDTuneProp $props 'privateEndpointConnections') | Where-Object { $_ })
            $pna = [string](Get-AVDTuneProp $props 'publicNetworkAccess')
            $dns = & $F.Dns $share.Host
            $ips = @(@($dns.Addresses) | Where-Object { $_ })
            $netSrc = "$script:LearnFiles/storage-files-networking-endpoints"
            if ($pe.Count -gt 0) {
                if (-not $dns.Ok -or $ips.Count -eq 0) { Add (New-AVDTuneStRow 'st.network' 3 'Private endpoint and DNS' 'red' "The account has a private endpoint but $($share.Host) does not resolve from this master ($($dns.Error))." 'Link the private DNS zone privatelink.file.core.windows.net to the VNet (or add the record on your DNS servers).' -Source $netSrc) }
                elseif (-not ($ips | Where-Object { Test-AVDTunePrivateIp $_ })) { Add (New-AVDTuneStRow 'st.network' 3 'Private endpoint and DNS' 'red' "The account has a private endpoint, but $($share.Host) resolves to the public address $($ips -join ', '): the traffic does not use the private endpoint (and fails when public access is off)." 'Link the private DNS zone privatelink.file.core.windows.net to the VNet of the session hosts, or forward the zone on your DNS servers.' -Source $netSrc) }
                else { Add (New-AVDTuneStRow 'st.network' 3 'Private endpoint and DNS' 'green' "A private endpoint exists and $($share.Host) resolves to the private address $($ips -join ', ')." -Source $netSrc) }
                if ($pna -eq 'Enabled') { Add (New-AVDTuneStRow 'st.network.public' 3 'Public network access' 'yellow' 'Public network access is enabled although a private endpoint exists.' 'Disable public network access (or restrict it with the firewall) when only the private endpoint is needed.' -Source $netSrc -Verified $false -Note 'Recommendation (plan 1b); Learn describes the options.') }
            }
            else {
                if ($pna -eq 'Disabled') { Add (New-AVDTuneStRow 'st.network' 3 'Private endpoint and DNS' 'red' 'Public network access is off and there is no private endpoint: nobody can reach the share.' 'Create a private endpoint or enable access from the VNet.' -Source $netSrc) }
                else { Add (New-AVDTuneStRow 'st.network' 3 'Private endpoint and DNS' 'yellow' "No private endpoint; the share is reached over the public endpoint ($($ips -join ', ')). A private endpoint is recommended." 'Create a private endpoint and the private DNS zone.' -Source $netSrc -Verified $false -Note 'The recommendation is the plan''s (section 1b).') }
            }
            # 4 share level permissions and roles
            try {
                $ra = Invoke-AVDTuneStorageArm -Arm $Arm -Token $ArmToken -Path "$($acc.Id)/providers/Microsoft.Authorization/roleAssignments?api-version=$script:RoleApi" -Action 'Microsoft.Authorization/roleAssignments/read' -Scope $share.Account
                $named = @(Get-AVDTuneStorageRoleNames (Get-AVDTuneProp $ra 'value'))
                $dsp = [string](Get-AVDTuneProp $ia 'defaultSharePermission')
                $smbContrib = @($named | Where-Object Role -eq 'Storage File Data SMB Share Contributor').Count
                $elev = @($named | Where-Object Role -eq 'Storage File Data SMB Share Elevated Contributor').Count
                $roleSrc = "$script:LearnFsl/how-to-configure-storage-permissions"
                if ($dso -eq 'None' -or -not $dso) { Add (New-AVDTuneStRow 'st.roles' 4 'Share level permissions' 'info' 'No identity based authentication: share level roles do not apply.' -Source $roleSrc) }
                elseif ($dsp -and $dsp -ne 'None') { Add (New-AVDTuneStRow 'st.roles' 4 'Share level permissions' 'green' "The default share level permission is $dsp$(if ($elev -gt 0) { "; $elev Elevated Contributor assignment(s) for administrators" }). Learn recommends the default share level permission Storage File Data SMB Share Contributor." -Source $roleSrc) }
                elseif ($smbContrib -gt 0) { Add (New-AVDTuneStRow 'st.roles' 4 'Share level permissions' 'green' "$smbContrib assignment(s) of Storage File Data SMB Share Contributor on the account or above." -Source $roleSrc) }
                else { Add (New-AVDTuneStRow 'st.roles' 4 'Share level permissions' 'red' 'No default share level permission and no assignment of Storage File Data SMB Share Contributor: users get "access denied" at the share level.' 'Set the default share level permission to Storage File Data SMB Share Contributor, or assign the role to the users group (and Elevated Contributor to the administrators).' -Source $roleSrc -Note 'Assignments through groups are not resolved here; only the assignment list of the account is read.' -Verified $true) }
                $mine = @($named | Where-Object { $CallerOid -and $_.PrincipalId -eq $CallerOid })
                $ctx.CallerRoles = @($mine | ForEach-Object Role)
            }
            catch { Add (New-AVDTuneStRow 'st.roles' 4 'Share level permissions' 'unknown' "Not checkable: $($_.Exception.Message)" 'Reader on the storage account (role assignments are part of it) is needed.' -Source "$script:LearnFsl/how-to-configure-storage-permissions") }
        }
    }

    # 5 NTFS ACLs of the root (data plane, OAuth, no key)
    $aclSource = "$script:LearnFsl/how-to-configure-storage-permissions"
    $aclNote = 'Get Permission with an OAuth token: the intent header and the roles are on the Learn pages; the authorization section of the Get Permission page still names only the account owner and SAS. To be proven on the test VM.'
    $sddl = $null; $aclFail = $null
    if (-not $Files -or -not $StorageToken) {
        $why = if ($NoStorageReason) { $NoStorageReason } else { 'no token for Azure Storage (https://storage.azure.com/): the sign-in has no Storage token.' }
        Add (New-AVDTuneStRow 'st.acl.root' 5 'NTFS rights of the share root' 'unknown' "Not checkable: $why" 'Sign in with the storage audience, or confirm the key fallback for this run.' -Source $aclSource -Verified $false -Note $aclNote)
    }
    else {
        try {
            $res = Get-AVDTuneStorageShareAcl -Files $Files -Account $share.Account -Share $share.Share -Token $StorageToken
            if ($res.Ok) { $sddl = $res.Sddl } else { $aclFail = $res }
        }
        catch { $aclFail = [pscustomobject]@{ Kind = 'Failed'; Error = $_.Exception.Message } }
    }
    # 7 fallback: only after the confirmation for this run, only when the role is missing
    if (-not $sddl -and $aclFail -and $aclFail.Kind -eq 'Forbidden') {
        Add (New-AVDTuneStRow 'st.acl.role' 5 'Role for reading the ACL' 'yellow' 'Azure refuses the ACL read (403): the signed-in account has no Storage File Data Privileged Reader (or Contributor) on the share.' 'Assign Storage File Data Privileged Reader to the administrator on the storage account.' -Source "$script:LearnFiles/authorize-data-operations-portal" -Verified $false -Note 'Role names and ids: Learn, built-in roles.')
        if ($AllowKeyFallback -and $Arm -and $ArmToken -and $acc -and $acc.Found) {
            $key = $null
            try {
                $keys = Invoke-AVDTuneStorageArm -Arm $Arm -Token $ArmToken -Method POST -Path "$($acc.Id)/listKeys?api-version=$script:StorageApi" -Action 'Microsoft.Storage/storageAccounts/listKeys/action' -Scope $share.Account
                $key = [string]@(Get-AVDTuneProp $keys 'keys')[0].value
                $ctx.KeyUsed = $true
                & $F.KeyMapAdd "\\$($share.Host)\$($share.Share)" "Azure\$($share.Account)" $key
                $key = $null
                $sddl = & $F.ShareAcl "\\$($share.Host)\$($share.Share)"
                if (-not $sddl) { Add (New-AVDTuneStRow 'st.acl.key' 5 'ACL through the account key' 'red' 'The key fallback was used (confirmed for this run) but the ACL could not be read through the SMB mapping.' 'Check port 445 and the share.' -Source $aclSource -Verified $false) }
                else { Add (New-AVDTuneStRow 'st.acl.key' 5 'ACL through the account key' 'yellow' 'The ACL was read with the account key (fallback, confirmed for this run). The key was used in memory only and the mapping was removed; the change log says so.' 'Give the administrator Storage File Data Privileged Reader so the key is not needed.' -Source $aclSource -Verified $false) }
            }
            catch { Add (New-AVDTuneStRow 'st.acl.key' 5 'ACL through the account key' 'red' "The key fallback failed: $($_.Exception.Message)" '' -Source $aclSource -Verified $false) }
            finally { $key = $null; $keys = $null; try { & $F.KeyMapRemove "\\$($share.Host)\$($share.Share)" } catch { } }
        }
        else { Add (New-AVDTuneStRow 'st.acl.key' 5 'ACL through the account key' 'info' 'The account key is not used: it gives full access and is only a fallback, after you confirm it for this run.' -Source $aclSource -Verified $false) }
    }
    elseif (-not $sddl -and $aclFail) { Add (New-AVDTuneStRow 'st.acl.root' 5 'NTFS rights of the share root' 'unknown' "Not checkable: $($aclFail.Error)" '' -Source $aclSource -Verified $false -Note $aclNote) }
    if ($sddl) {
        try {
            $cmp = Compare-AVDTuneFSLogixAcl -Sddl $sddl -UsersSids $UsersSids -AdminsSids $AdminsSids
            if ($cmp.Compliant) { Add (New-AVDTuneStRow 'st.acl.root' 5 'NTFS rights of the share root' 'green' 'The root matches Microsoft''s FSLogix recommendation.' -Source $aclSource -Verified $false -Note $aclNote) }
            else {
                $worst = if (@($cmp.Findings | Where-Object Status -eq 'red').Count -gt 0) { 'red' } else { 'yellow' }
                Add (New-AVDTuneStRow 'st.acl.root' 5 'NTFS rights of the share root' $worst (($cmp.Findings | ForEach-Object { $_.Text }) -join ' ') $(if ($UsersSids.Count -gt 0 -and $AdminsSids.Count -gt 0) { 'Set the recommended ACL (shown as a diff first, only after your confirmation).' } else { 'Name the users and administrators group (domain information) to get the diff.' }) -Source $aclSource -Verified $false -Note $aclNote)
                if ($UsersSids.Count -gt 0 -and $AdminsSids.Count -gt 0) { $ctx.AclDiff = Get-AVDTuneStorageAclDiff -FoundSddl $sddl -UsersSid $UsersSids[0] -AdminsSid $AdminsSids[0] -Account $share.Account -Share $share.Share }
            }
            if ($StorageToken -and $Files -and -not $ctx.KeyUsed -and $UsersSids.Count -gt 0) {
                $broadFolders = New-Object System.Collections.ArrayList
                foreach ($fo in (Get-AVDTuneStorageProfileFolders -Files $Files -Account $share.Account -Share $share.Share -Token $StorageToken)) {
                    $fr = Get-AVDTuneStorageShareAcl -Files $Files -Account $share.Account -Share $share.Share -Path $fo -Token $StorageToken
                    if (-not $fr.Ok) { continue }
                    $acl = ConvertFrom-AVDTuneSddl $fr.Sddl
                    $bad = @($acl.Aces | Where-Object { $_.Type -eq 'AccessAllowed' -and ($_.Sid -in (@('S-1-1-0', 'S-1-5-11', 'S-1-5-32-545') + @($UsersSids))) })
                    if ($bad.Count -gt 0) { [void]$broadFolders.Add($fo) }
                }
                if ($broadFolders.Count -gt 0) { Add (New-AVDTuneStRow 'st.acl.folders' 5 'NTFS rights of the profile folders' 'red' "Users or Everyone have access to the profile folder(s) $($broadFolders -join ', '): other users could open them." 'Remove the broad entries from the folders; each folder belongs to its owner (CREATOR OWNER) and the administrators only.' -Source $aclSource -Verified $false -Note 'A sample of at most 5 folders is read.') }
                else { Add (New-AVDTuneStRow 'st.acl.folders' 5 'NTFS rights of the profile folders' 'green' 'A sample of the profile folders has no access for the users group or Everyone.' -Source $aclSource -Verified $false -Note 'A sample of at most 5 folders is read.') }
            }
        }
        catch { Add (New-AVDTuneStRow 'st.acl.root' 5 'NTFS rights of the share root' 'unknown' "Not checkable: the ACL could not be compared ($($_.Exception.Message))." '' -Source $aclSource -Verified $false) }
    }

    # 6 access as a domain user
    if (-not $TestUser) { Add (New-AVDTuneStRow 'st.access' 6 'Access test as a domain user' 'info' 'Not run: enter a domain account (or a test user) to prove Kerberos, share permission and NTFS together.' -Source $aclSource -Verified $false) }
    elseif (-not $TestPassword -or $TestPassword.Length -eq 0) { Add (New-AVDTuneStRow 'st.access' 6 'Access test as a domain user' 'unknown' 'Not checkable: no password for the test account.' -Source $aclSource -Verified $false) }
    else {
        try {
            $t = & $F.ShareTestAsUser $first $TestUser $TestPassword $DomainController
            $failed = @($t.Steps | Where-Object { -not $_.Ok })
            if ($t.LogonFailed) { Add (New-AVDTuneStRow 'st.access' 6 'Access test as a domain user' 'red' "The logon of $TestUser failed: $($t.Error)" 'Check the account name and that the domain controller is reachable (the password is only checked when the share is accessed).' -Source $aclSource -Verified $false) }
            elseif ($failed.Count -eq 0) { Add (New-AVDTuneStRow 'st.access' 6 'Access test as a domain user' 'green' "As $TestUser (Kerberos, new credentials for the network only): create folder, write, read, delete worked. This proves Kerberos, share permission and NTFS together. Windows takes the password for these network-only credentials without checking it: it was only checked when the share was accessed." -Source $aclSource -Verified $false -Note 'The VHDX test as that user is not done (frx runs as the administrator): see the function test.') }
            else { Add (New-AVDTuneStRow 'st.access' 6 'Access test as a domain user' 'red' "As $TestUser the step '$($failed[0].Name)' failed: $($failed[0].Error)" 'Check the share level role, the NTFS rights and the Kerberos setup (SPN, ticket encryption); a wrong password also shows up here, not at the logon.' -Source $aclSource -Verified $false) }
        }
        catch { Add (New-AVDTuneStRow 'st.access' 6 'Access test as a domain user' 'red' "The test could not run: $($_.Exception.Message)" '' -Source $aclSource -Verified $false) }
    }
    Get-AVDTuneStorageResult $rows $ctx $Now
}

function Get-AVDTuneStorageResult($Rows, $Ctx, [datetime]$Now) {
    $arr = @($Rows)
    $c = [pscustomobject]@{ Green = @($arr | Where-Object Status -eq 'green').Count; Yellow = @($arr | Where-Object Status -eq 'yellow').Count; Red = @($arr | Where-Object Status -eq 'red').Count; Unknown = @($arr | Where-Object Status -eq 'unknown').Count; Info = @($arr | Where-Object Status -eq 'info').Count }
    $overall = if ($c.Red -gt 0) { 'red' } elseif ($c.Yellow -gt 0 -or $c.Unknown -gt 0) { 'yellow' } else { 'green' }
    [pscustomobject]@{ At = $Now.ToString('o'); Overall = $overall; Counts = $c; Rows = $arr; Account = [string]$Ctx.AccountName; AccountId = [string]$Ctx.AccountId; KeyUsed = [bool]$Ctx.KeyUsed; AclDiff = $Ctx.AclDiff; CallerRoles = @($(if ($Ctx.ContainsKey('CallerRoles')) { $Ctx.CallerRoles })) }
}

function Save-AVDTuneStorageCheckRun {
    <# Stores the result: run record (Plan 'FSLogix-Storage'), state.json (StorageCheck) and a change log note (naming that the key was used, when it was). No key, no token, no SDDL in the record. #>
    [CmdletBinding()]
    param([string]$Root = (Get-AVDTuneRoot), [Parameter(Mandatory)]$Result, [string]$User, [string]$SnapshotId)
    $state = Get-AVDTuneState $Root
    $slim = @($Result.Rows | ForEach-Object { [pscustomobject]@{ Id = $_.Id; Section = 'FSLogix'; Title = $_.Title; Mode = 'Test'; Status = $(switch ($_.Status) { 'green' { 'Compliant' } 'info' { 'Compliant' } default { 'NonCompliant' } }); Before = $_.Status; After = $null; Message = $_.Reason; Reboot = $false; WhatIf = $false; At = $Result.At } })
    $run = [pscustomobject][ordered]@{ Id = $null; Plan = 'FSLogix-Storage'; Kind = 'FSLogix-Storage'; Started = $Result.At; Ended = $Result.At; User = $User; SnapshotId = $SnapshotId; WhatIf = $false; ImageVersion = $state.ImageVersion; Reboot = $false; Results = $slim; Overall = $Result.Overall; KeyUsed = [bool]$Result.KeyUsed }
    [void](Add-AVDTuneRun -Root $Root -Run $run)
    $rec = [ordered]@{ At = $Result.At; Overall = $Result.Overall; Red = $Result.Counts.Red; Yellow = $Result.Counts.Yellow; Unknown = $Result.Counts.Unknown; Green = $Result.Counts.Green; RunId = [string]$run.Id; User = $User; Account = $Result.Account; KeyUsed = [bool]$Result.KeyUsed }
    [void](Set-AVDTuneState -Root $Root -Values @{ StorageCheck = $rec })
    if ($state.ImageVersion) {
        $text = "Storage check of $($Result.Account): $($Result.Overall) ($($Result.Counts.Red) red, $($Result.Counts.Yellow) yellow, $($Result.Counts.Unknown) not checkable, $($Result.Counts.Green) green)"
        if ($Result.KeyUsed) { $text += '. The storage account key WAS used for this run (fallback confirmed by the administrator); it was kept in memory only.' }
        [void](Add-AVDTuneChangeLogEntry -Root $Root -Version $state.ImageVersion -Category 'FSLogix' -Component 'Storage check' -ChangeType Note -Text $text -User $User -SnapshotId $SnapshotId -RunId ([string]$run.Id) -Source Note)
    }
    [pscustomobject]$rec
}

#endregion

#region real Files adapter

function New-AVDTuneFilesAdapter {
    <#
        The real data plane adapter: HTTPS to <account>.file.core.windows.net only, bearer token, no redirects, never throws (Status 0 = no connection).
        Not used by the checks (they use the fake); the REST calls are written from the Learn reference and have to be tried on the test VM.
    #>
    $a = [ordered]@{ Kind = 'Real' }
    $a.Invoke = {
        param($Method, $Url, $Token, $Headers, $Body)
        if ($Url -notmatch '^https://[a-z0-9]{3,24}\.file\.core\.windows\.net/[A-Za-z0-9._~%/-]*\?[A-Za-z0-9=&_.-]+$' -or $Url -match '\.\.') { return [pscustomobject]@{ Status = 0; Headers = @{}; Body = ''; Error = 'Refused: not a file share URL.' } }
        if ($Method -notin 'GET', 'PUT', 'HEAD') { return [pscustomobject]@{ Status = 0; Headers = @{}; Body = ''; Error = 'Refused: method.' } }
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        try {
            $req = [System.Net.HttpWebRequest]::Create($Url)
            $req.Method = $Method; $req.Timeout = 60000; $req.AllowAutoRedirect = $false
            $req.Headers.Add('Authorization', "Bearer $Token")
            foreach ($k in $Headers.Keys) { $req.Headers.Add([string]$k, [string]$Headers[$k]) }
            if ($Method -eq 'PUT') { $req.ContentLength = 0 }
            $resp = $req.GetResponse()
        }
        catch {
            # An HTTP error answer (400/403/404...) is a response on the inner WebException, not "no connection"
            $resp = Get-AVDTuneWebResponse $_.Exception
            if (-not $resp) { return [pscustomobject]@{ Status = 0; Headers = @{}; Body = ''; Error = $_.Exception.Message } }
        }
        try {
            $text = (New-Object IO.StreamReader($resp.GetResponseStream())).ReadToEnd()
            $hs = @{}; foreach ($k in $resp.Headers.AllKeys) { $hs[[string]$k] = [string]$resp.Headers[$k] }
            [pscustomobject]@{ Status = [int]$resp.StatusCode; Headers = $hs; Body = $text; Error = '' }
        }
        finally { $resp.Close() }
    }
    [pscustomobject]$a
}

#endregion

Export-ModuleMember -Function Test-AVDTuneStorageAccountName, Test-AVDTuneShareName, Split-AVDTuneUncShare, Test-AVDTunePrivateIp, Assert-AVDTuneStorageArmPath, Invoke-AVDTuneStorageArm, Invoke-AVDTuneStorageFiles,
    Find-AVDTuneStorageAccount, Get-AVDTuneStorageAdCompare, Get-AVDTuneStorageShareAcl, Get-AVDTuneStorageProfileFolders, Get-AVDTuneStorageAclDiff, Set-AVDTuneStorageRootAcl,
    Invoke-AVDTuneStorageCheck, Get-AVDTuneStorageResult, Save-AVDTuneStorageCheckRun, New-AVDTuneFilesAdapter
