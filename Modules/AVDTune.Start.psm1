<#
    AVDTune start: the first-run questions (identity model) with environment.json, and the start sequence on the Overview.

    environment.json (C:\ProgramData\AVDTune\environment.json, next to state.json): the answers, the tenant and client ID of the app
    registration, the snapshot name pattern, the chosen gallery image definition (readiness), the domain controller (name, account name, pinned certificate thumbprints, summary of what was read). Never a secret:
    only fields of the table below are written, text is cleaned, and no password, token or key has a field.

    Start sequence (docs\plans\avdtune.md 1a, issue #64): Sign-in -> Domain (what the master says about its join; a DC step only for a domain member) -> first-run
    questions (prefilled from the sign-in, Azure and the domain, each answer with its source, valid only after the administrator confirmed) -> Snapshot gate.
    Every stage has a status the Overview shows: Pending, Locked (an earlier stage is open), Done, Skipped, Failed. The context ($Context) holds what lives in memory only.
    The sign-in needs no answer: tenant and client ID go into environment.json without an 'Answers' part ("not confirmed yet": Get-AVDTuneEnvironment returns $null,
    Get-AVDTuneEnvironmentFile returns the file). An environment.json of an earlier version has its answers and is confirmed as it is.
#>

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'AVDTune.psm1')
Import-Module (Join-Path $PSScriptRoot 'AVDTune.Snapshot.psm1')
Import-Module (Join-Path $PSScriptRoot 'AVDTune.Session.psm1')
Import-Module (Join-Path $PSScriptRoot 'AVDTune.Directory.psm1')

#region questions

$script:Questions = @(
    @{ Key = 'Join'; Title = 'Join of the session hosts'; Choices = @(
            @{ Value = 'EntraOnly'; Text = 'Microsoft Entra ID only (no hybrid join)' }
            @{ Value = 'Hybrid'; Text = 'Microsoft Entra hybrid join' }
            @{ Value = 'AdDs'; Text = 'AD DS join only' }) }
    @{ Key = 'Dc'; Title = 'Domain controller'; Choices = @(
            @{ Value = 'None'; Text = 'None' }
            @{ Value = 'AdDsAzure'; Text = 'AD DS in Azure (VM)' }
            @{ Value = 'AdDsOnPrem'; Text = 'AD DS on premises (VPN or ExpressRoute)' }
            @{ Value = 'EntraDs'; Text = 'Microsoft Entra Domain Services' }) }
    @{ Key = 'Identities'; Title = 'Identities of the users'; Choices = @(
            @{ Value = 'CloudOnly'; Text = 'Cloud only' }
            @{ Value = 'Synced'; Text = 'Synchronized (Entra Connect / Cloud Sync)' }) }
    @{ Key = 'Profiles'; Title = 'Profiles'; Choices = @(
            @{ Value = 'AzureFiles'; Text = 'FSLogix profile container on Azure Files' }
            @{ Value = 'OtherSmb'; Text = 'FSLogix on another SMB share (e.g. Azure NetApp Files, file server)' }
            @{ Value = 'None'; Text = 'No FSLogix' }) }
    @{ Key = 'Endpoint'; Title = 'Network: storage endpoint'; Choices = @(
            @{ Value = 'Private'; Text = 'Private endpoint (recommended)' }
            @{ Value = 'Public'; Text = 'Public endpoint with firewall' }) }
    @{ Key = 'DnsZone'; Title = 'Network: private DNS zone privatelink.file.core.windows.net'; Choices = @(
            @{ Value = 'Azure'; Text = 'In Azure (private DNS zone)' }
            @{ Value = 'OwnDns'; Text = 'On the own DNS servers' }) }
)

function Get-AVDTuneQuestions { $script:Questions }

function Get-AVDTuneEnvironmentDefaults {
    [pscustomobject][ordered]@{
        Join = 'EntraOnly'; Dc = 'None'; Identities = 'CloudOnly'; Profiles = 'AzureFiles'; AzureFilesAuth = 'Auto'
        Endpoint = 'Private'; VNet = ''; Subnet = ''; DnsZone = 'Azure'; TenantId = ''; ClientId = ''; SnapshotNamePattern = (Get-AVDTuneDefaultSnapshotNamePattern)
    }
}

function Test-AVDTuneEnvironmentAnswers {
    <# Errors (the combination cannot work) and warnings for a set of answers. The rules follow Microsoft's join and identity documentation; phase 3 verifies them again. #>
    param([Parameter(Mandatory)]$Answers)
    $errors = New-Object System.Collections.ArrayList; $warnings = New-Object System.Collections.ArrayList
    foreach ($q in $script:Questions) {
        $value = [string](Get-AVDTuneProp $Answers $q.Key)
        if ($value -notin @($q.Choices | ForEach-Object { $_.Value })) { [void]$errors.Add("Answer '$($q.Title)' is missing or unknown.") }
    }
    if ($errors.Count -gt 0) { return [pscustomobject]@{ Errors = @($errors); Warnings = @() } }
    $join = $Answers.Join; $dc = $Answers.Dc; $id = $Answers.Identities
    if ($join -in 'Hybrid', 'AdDs' -and $dc -eq 'None') { [void]$errors.Add('A hybrid or AD DS join needs a domain controller: choose where it runs.') }
    if ($join -in 'Hybrid', 'AdDs' -and $id -eq 'CloudOnly') { [void]$errors.Add('Cloud-only identities cannot sign in to hosts joined to a domain: choose synchronized identities.') }
    if ($join -eq 'Hybrid' -and $dc -eq 'EntraDs') { [void]$errors.Add('Microsoft Entra hybrid join is not available with Microsoft Entra Domain Services.') }
    if ($join -eq 'EntraOnly' -and $dc -ne 'None') { [void]$warnings.Add('Entra-only join does not need a domain controller; the domain step is only used because you named one (for Azure Files with AD DS).') }
    if ($join -eq 'EntraOnly' -and $dc -eq 'EntraDs') { [void]$warnings.Add('Microsoft Entra Domain Services with Entra-joined hosts: check the Azure Files authentication below.') }
    $choice = [string](Get-AVDTuneProp $Answers 'AzureFilesAuth')
    if ($choice -and $choice -ne 'Auto') {
        $allowed = @(Get-AVDTuneAzureFilesAuthChoices $Answers)
        # A saved choice can be stale after another answer changed: not an error, the first allowed method is used instead
        if ($choice -notin $allowed -and $allowed.Count -gt 0) { [void]$warnings.Add("Azure Files authentication '$choice' does not fit these answers; '$($allowed[0])' is used (allowed: $($allowed -join ', '))."); }
    }
    foreach ($field in 'VNet', 'Subnet') {
        $v = [string](Get-AVDTuneProp $Answers $field)
        if ($v -and $v -notmatch '^[A-Za-z0-9_./ -]{1,200}$') { [void]$errors.Add("The $field name has characters that Azure does not allow.") }
    }
    # The tenant is no question any more (it comes from the sign-in); a saved one (GUID, or a domain from an older environment.json) stays valid
    $t = [string](Get-AVDTuneProp $Answers 'TenantId')
    if ($t -and $t -notmatch '^([0-9a-fA-F-]{36}|[A-Za-z0-9][A-Za-z0-9.-]{0,250}\.[A-Za-z]{2,})$') { [void]$errors.Add('The saved tenant must be a tenant ID (GUID) or a domain name.') }
    $c = [string](Get-AVDTuneProp $Answers 'ClientId')
    if ($c -and -not (Test-AVDTuneTenantGuid $c.Trim())) { [void]$errors.Add('The client ID must be a GUID.') }
    $pattern = [string](Get-AVDTuneProp $Answers 'SnapshotNamePattern')
    if ($pattern) { $problem = Test-AVDTuneSnapshotNamePattern $pattern; if ($problem) { [void]$errors.Add($problem) } }
    if ($c -ieq '14d82eec-204b-4c2f-b7e8-296a70dab67e') { [void]$errors.Add("That is Microsoft's setup app; AVDTune needs the client ID of its own app registration (leave the field empty and AVDTune creates it at the sign-in).") }
    [pscustomobject]@{ Errors = @($errors); Warnings = @($warnings) }
}

function Get-AVDTuneAzureFilesAuthChoices {
    # Authentication methods that fit the answers (empty when there is no Azure Files)
    param([Parameter(Mandatory)]$Answers)
    if ($Answers.Profiles -ne 'AzureFiles') { return @() }
    if ($Answers.Dc -eq 'EntraDs') { return @('EntraDs') }
    $hasAd = $Answers.Dc -in 'AdDsAzure', 'AdDsOnPrem'
    if ($hasAd -and $Answers.Join -in 'Hybrid', 'AdDs') { if ($Answers.Identities -eq 'Synced') { return @('AdDs', 'EntraKerberos') } else { return @('AdDs') } }
    if ($hasAd -and $Answers.Identities -eq 'Synced') { return @('EntraKerberos', 'AdDs') }
    @('EntraKerberos')
}

function Resolve-AVDTuneEnvironmentPlan {
    <#
        What follows from the answers: whether the domain step exists, which Azure Files authentication applies, which pages are hidden and
        a short text per consequence (shown in the first-run summary).
    #>
    param([Parameter(Mandatory)]$Answers)
    $choices = @(Get-AVDTuneAzureFilesAuthChoices $Answers)
    $auth = [string](Get-AVDTuneProp $Answers 'AzureFilesAuth')
    if ($choices.Count -eq 0) { $auth = 'None' } elseif (-not $auth -or $auth -eq 'Auto' -or $auth -notin $choices) { $auth = $choices[0] }
    $usesDc = ($Answers.Dc -ne 'None')
    $hidden = @(); if ($Answers.Profiles -eq 'None') { $hidden = @('FSLogix', 'AppMasking') }
    $notes = New-Object System.Collections.ArrayList
    if ($usesDc) { [void]$notes.Add('Domain step: AVDTune connects to a domain controller (LDAPS first) and reads OUs, groups and SIDs.') }
    else { [void]$notes.Add('No domain step: groups for App Masking and FSLogix come from Microsoft Entra ID through Graph.') }
    switch ($auth) {
        'EntraKerberos' { [void]$notes.Add('Azure Files with Microsoft Entra Kerberos.') }
        'AdDs' { [void]$notes.Add('Azure Files with AD DS.') }
        'EntraDs' { [void]$notes.Add('Azure Files with Microsoft Entra Domain Services.') }
    }
    if ($Answers.Profiles -eq 'None') { [void]$notes.Add('Without FSLogix the FSLogix pages are hidden and the Finish checklist has no FSLogix test.') }
    [pscustomobject]@{ UsesDc = $usesDc; AzureFilesAuth = $auth; AzureFilesAuthChoices = $choices; HiddenPages = $hidden; Notes = @($notes) }
}

#endregion

#region environment.json

function Get-AVDTuneEnvironmentPath([string]$Root) { Join-Path $Root 'environment.json' }

function Get-AVDTuneEnvironmentFile {
    <# The file as it is: the confirmed environment, or a part that only has the sign-in target and/or the domain controller (the sign-in and the domain step come before the questions), or $null. #>
    param([string]$Root = (Get-AVDTuneRoot))
    $envObj = Read-AVDTuneJson (Get-AVDTuneEnvironmentPath $Root)
    if ($null -eq $envObj) { return $null }
    if ([int](Get-AVDTuneProp $envObj 'Schema') -gt 1) { throw 'environment.json is from a newer AVDTune.' }
    $envObj
}

function Get-AVDTuneEnvironment {
    <# The confirmed environment (the first-run questions are answered), or $null before. A file that only has the sign-in target or the domain controller is not an environment yet. #>
    param([string]$Root = (Get-AVDTuneRoot))
    $envObj = Get-AVDTuneEnvironmentFile $Root
    if ($null -eq $envObj -or $null -eq (Get-AVDTuneProp $envObj 'Answers')) { return $null }
    $envObj
}

function ConvertTo-AVDTuneEnvironmentFields {
    # Every field of the file as an ordered table (unknown fields stay), so that a writer changes one part and loses nothing of the others
    param($Environment)
    $o = [ordered]@{ Schema = 1 }
    if ($Environment) { foreach ($p in $Environment.PSObject.Properties) { if ($p.Name -ne 'Schema') { $o[$p.Name] = $p.Value } } }
    $o
}

function Write-AVDTuneEnvironmentFields {
    param([string]$Root, [Parameter(Mandatory)]$Fields, [string]$User, [switch]$KeepUser)
    $Fields['Schema'] = 1; $Fields['Updated'] = (Get-Date).ToString('o')
    if (-not ($KeepUser -and $Fields.Contains('UpdatedBy'))) { $Fields['UpdatedBy'] = (Remove-AVDTuneControlCharacters $User 80) }
    Write-AVDTuneFile (Get-AVDTuneEnvironmentPath $Root) ($Fields | ConvertTo-Json -Depth 10)
}

function Get-AVDTuneEnvironmentAnswers {
    # The answers of the saved environment as a flat object (defaults for what is not there); the sign-in target of a file without answers comes along
    param($Environment)
    $a = Get-AVDTuneEnvironmentDefaults
    if ($Environment) {
        foreach ($p in $a.PSObject.Properties) {
            $answers = Get-AVDTuneProp $Environment 'Answers'
            $v = Get-AVDTuneProp $answers $p.Name
            if ($null -eq $v) { $v = Get-AVDTuneProp (Get-AVDTuneProp $answers 'Network') $p.Name }
            if ($null -eq $v) { $v = Get-AVDTuneProp (Get-AVDTuneProp $Environment 'SignIn') $p.Name }
            if ($null -eq $v -and $p.Name -eq 'SnapshotNamePattern') { $v = Get-AVDTuneProp (Get-AVDTuneProp $Environment 'Snapshot') 'NamePattern' }
            if ($null -ne $v) { $a.($p.Name) = [string]$v }
        }
    }
    $a
}

function Get-AVDTuneAnswerSources {
    # The source of every saved answer (environment.json Sources): where the value came from and whether it was confirmed or typed; empty for a file of an earlier version
    param($Environment)
    $r = [ordered]@{}
    $s = Get-AVDTuneProp $Environment 'Sources'
    if ($s) { foreach ($p in $s.PSObject.Properties) { $r[$p.Name] = [string]$p.Value } }
    $r
}

function Save-AVDTuneEnvironment {
    <#
        Writes the answers (the administrator confirmed them). Throws when the combination is invalid. Keeps the domain controller part (pins) as it is. When an answer changed
        after an environment existed, the change goes into the change log (needs an image version; without one the diff is only returned).
        The tenant is not asked: an empty TenantId keeps the saved one; -ForgetTenant removes it (the next sign-in sets it again).
        -Sources: where each answer came from (key -> text, for example 'Confirmed: detected by dsregcmd /status'); stored with the answers.
        Returns @{ Environment; Changes = 'Name: old -> new' ... }.
    #>
    [CmdletBinding()]
    param([string]$Root = (Get-AVDTuneRoot), [Parameter(Mandatory)]$Answers, [string]$User, [switch]$ForgetTenant, [hashtable]$Sources)
    $check = Test-AVDTuneEnvironmentAnswers $Answers
    if ($check.Errors.Count -gt 0) { throw ($check.Errors -join ' ') }
    $file = Get-AVDTuneEnvironmentFile $Root
    $old = Get-AVDTuneEnvironment $Root
    $oldAnswers = if ($old) { Get-AVDTuneEnvironmentAnswers $old } else { $null }
    $tenant = [string](Get-AVDTuneProp $Answers 'TenantId')
    if ($ForgetTenant) { $tenant = '' } elseif (-not $tenant.Trim() -and $file) { $tenant = [string](Get-AVDTuneProp (Get-AVDTuneProp $file 'SignIn') 'TenantId') }
    $clean = { param($v, $n) Remove-AVDTuneControlCharacters ([string]$v) $n }
    $plan = Resolve-AVDTuneEnvironmentPlan $Answers
    $fields = ConvertTo-AVDTuneEnvironmentFields $file
    $fields['Answers'] = [ordered]@{
        Join = [string]$Answers.Join; Dc = [string]$Answers.Dc; Identities = [string]$Answers.Identities; Profiles = [string]$Answers.Profiles
        AzureFilesAuth = [string]$plan.AzureFilesAuth; Network = [ordered]@{ Endpoint = [string]$Answers.Endpoint; VNet = (& $clean $Answers.VNet 200); Subnet = (& $clean $Answers.Subnet 200); DnsZone = [string]$Answers.DnsZone }
    }
    # the client ID is never taken from the answers: only Set-AVDTuneEnvironmentSignIn sets it (after the sign-in worked); the saved one stays
    $fields['SignIn'] = [ordered]@{ TenantId = (& $clean $tenant 255).Trim(); ClientId = ([string](Get-AVDTuneProp (Get-AVDTuneProp $file 'SignIn') 'ClientId')).Trim() }
    $fields['Snapshot'] = [ordered]@{ NamePattern = $(if ([string](Get-AVDTuneProp $Answers 'SnapshotNamePattern')) { (& $clean $Answers.SnapshotNamePattern 80).Trim() } else { Get-AVDTuneDefaultSnapshotNamePattern }) }
    if (-not $fields.Contains('Dc') -or -not $fields['Dc']) { $fields['Dc'] = [ordered]@{ Server = ''; User = ''; Pins = [ordered]@{}; Discovery = $null } }
    if (-not $fields.Contains('Gallery')) { $fields['Gallery'] = $null }
    if ($PSBoundParameters.ContainsKey('Sources')) {
        $src = [ordered]@{}
        foreach ($k in @($Sources.Keys | Sort-Object)) { if ([string]$k -match '^[A-Za-z]{1,40}$') { $src[[string]$k] = (& $clean $Sources[$k] 240) } }
        $fields['Sources'] = $src
    }
    elseif ($oldAnswers) {
        # no -Sources: an answer that changed was typed by the administrator, the earlier source is not kept for it; the others keep theirs
        $newAnswers = Get-AVDTuneEnvironmentAnswers ((@{ Answers = $fields['Answers']; SignIn = $fields['SignIn']; Snapshot = $fields['Snapshot'] } | ConvertTo-Json -Depth 6) | ConvertFrom-Json)
        $src = [ordered]@{}; foreach ($kv in (Get-AVDTuneAnswerSources $file).GetEnumerator()) { $src[$kv.Key] = $kv.Value }
        foreach ($p in $newAnswers.PSObject.Properties) { if ([string]$p.Value -ne [string]$oldAnswers.($p.Name) -and $p.Name -notin 'TenantId', 'ClientId') { $src[$p.Name] = 'Typed by the administrator' } }
        $fields['Sources'] = $src
    }
    Write-AVDTuneEnvironmentFields -Root $Root -Fields $fields -User $User
    $saved = Get-AVDTuneEnvironment $Root
    $changes = @()
    if ($oldAnswers) {
        $new = Get-AVDTuneEnvironmentAnswers $saved
        foreach ($p in $new.PSObject.Properties) { if ([string]$p.Value -ne [string]$oldAnswers.($p.Name)) { $changes += "$($p.Name): $($oldAnswers.($p.Name)) -> $($p.Value)" } }
    }
    if ($changes.Count -gt 0) {
        $version = [string](Get-AVDTuneState $Root).ImageVersion
        if ($version) { [void](Add-AVDTuneChangeLogEntry -Root $Root -Version $version -Category 'Setup' -Component 'Environment' -ChangeType Changed -Text ('First-run answers changed: ' + ($changes -join '; ')) -User $User -Source Note) }
    }
    [pscustomobject]@{ Environment = $saved; Changes = $changes }
}

function Get-AVDTuneDcPins {
    # server -> sha256 hex of the pinned certificate
    param($Environment)
    $pins = @{}
    $dc = Get-AVDTuneProp $Environment 'Dc'
    $p = Get-AVDTuneProp $dc 'Pins'
    if ($p) { foreach ($prop in $p.PSObject.Properties) { $pins[$prop.Name.ToLowerInvariant()] = [string](Get-AVDTuneProp $prop.Value 'Sha256') } }
    $pins
}

function Set-AVDTuneDcPin {
    <#
        Pins the certificate of a domain controller for this environment (after the administrator saw the thumbprint). Replacing an existing
        pin needs -Replace and goes into the change log. Returns the pin record.
    #>
    [CmdletBinding()]
    param([string]$Root = (Get-AVDTuneRoot), [Parameter(Mandatory)][string]$Server, [Parameter(Mandatory)]$Certificate, [string]$User, [switch]$Replace)
    $envObj = Get-AVDTuneEnvironmentFile $Root
    $server = $Server.Trim().ToLowerInvariant()
    $sha = [string]$Certificate.Sha256
    if ($sha -notmatch '^[0-9A-Fa-f]{64}$') { throw 'The certificate has no valid SHA-256 thumbprint.' }
    $existing = Get-AVDTuneDcPins $envObj
    if ($existing.ContainsKey($server) -and $existing[$server] -ine $sha -and -not $Replace) { throw "A different certificate is pinned for $server. Replacing it needs an explicit confirmation." }
    $record = [ordered]@{ Sha256 = $sha.ToUpperInvariant(); Thumbprint = [string]$Certificate.Thumbprint; Subject = (Remove-AVDTuneControlCharacters ([string]$Certificate.Subject) 300); PinnedAt = (Get-Date).ToString('o'); PinnedBy = (Remove-AVDTuneControlCharacters $User 80) }
    $oldDc = Get-AVDTuneProp $envObj 'Dc'
    $dc = [ordered]@{ Server = [string](Get-AVDTuneProp $oldDc 'Server'); User = [string](Get-AVDTuneProp $oldDc 'User'); Pins = [ordered]@{}; Discovery = (Get-AVDTuneProp $oldDc 'Discovery') }
    $oldPins = Get-AVDTuneProp $oldDc 'Pins'
    if ($oldPins) { foreach ($p in $oldPins.PSObject.Properties) { $dc.Pins[$p.Name] = $p.Value } }
    $dc.Pins[$server] = $record
    Update-AVDTuneEnvironmentDc -Root $Root -Environment $envObj -Dc $dc
    if ($existing.ContainsKey($server) -and $existing[$server] -ine $sha) {
        $version = [string](Get-AVDTuneState $Root).ImageVersion
        if ($version) { [void](Add-AVDTuneChangeLogEntry -Root $Root -Version $version -Category 'Setup' -Component 'Domain controller' -ChangeType Changed -Text "Certificate pin of $server replaced by thumbprint $($record.Thumbprint)" -User $User -Source Note) }
    }
    [pscustomobject]$record
}

function Update-AVDTuneEnvironmentDc {
    param([string]$Root, $Environment, $Dc)
    # Only the Dc part changes; every other field of the file stays as it is (also a file that has no answers yet)
    $fields = ConvertTo-AVDTuneEnvironmentFields $Environment
    $fields['Dc'] = $Dc
    Write-AVDTuneEnvironmentFields -Root $Root -Fields $fields -KeepUser
}

function Save-AVDTuneDcDiscovery {
    <# Server, account name (no password) and a summary of what was read (domain, NetBIOS name, levels, site, counts) into environment.json. #>
    param([string]$Root = (Get-AVDTuneRoot), [Parameter(Mandatory)][string]$Server, [Parameter(Mandatory)][string]$User, [Parameter(Mandatory)]$Info)
    $envObj = Get-AVDTuneEnvironmentFile $Root
    $summary = [ordered]@{
        DnsName = $Info.DnsName; NetBiosName = $Info.NetBiosName; Site = $Info.Site; DomainLevel = $Info.DomainLevel; ForestLevel = $Info.ForestLevel
        DefaultNamingContext = $Info.DefaultNamingContext; OuCount = $Info.OuCount; GroupCount = @($Info.Groups).Count; ReadAt = (Get-Date).ToString('o')
    }
    $dc = [ordered]@{ Server = $Server.Trim().ToLowerInvariant(); User = (Remove-AVDTuneControlCharacters $User 256); Pins = $(if (Get-AVDTuneProp (Get-AVDTuneProp $envObj 'Dc') 'Pins') { $envObj.Dc.Pins } else { [ordered]@{} }); Discovery = $summary }
    Update-AVDTuneEnvironmentDc -Root $Root -Environment $envObj -Dc $dc
}

function Set-AVDTuneEnvironmentSignIn {
    <#
        Writes the tenant and/or the client ID that the sign-in found (tid of the token, AVDTune's own app registration) into environment.json.
        A value that changes goes into the change log (needs an image version) and is returned as text.
    #>
    param([string]$Root = (Get-AVDTuneRoot), [string]$TenantId, [string]$ClientId, [string]$User, [string]$Account)
    $envObj = Get-AVDTuneEnvironmentFile $Root   # the sign-in comes before the questions: a file without answers (or none yet) is fine
    $oldTenant = [string](Get-AVDTuneProp (Get-AVDTuneProp $envObj 'SignIn') 'TenantId'); $oldClient = [string](Get-AVDTuneProp (Get-AVDTuneProp $envObj 'SignIn') 'ClientId')
    $tenant = $oldTenant; $client = $oldClient; $changes = @()
    if ($TenantId) {
        if ($TenantId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') { throw 'The tenant of the sign-in is not a GUID.' }
        $tenant = $TenantId.ToLowerInvariant()
        if ($tenant -ne $oldTenant) { $changes += "Tenant taken from the sign-in: $(if ($oldTenant) { "$oldTenant -> " })$tenant$(if ($Account) { " (account $(Remove-AVDTuneControlCharacters $Account 120))" })" }
    }
    if ($ClientId) {
        if ($ClientId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' -or $ClientId -ieq '14d82eec-204b-4c2f-b7e8-296a70dab67e') { throw 'The client ID of the app registration is not usable.' }
        $client = $ClientId.ToLowerInvariant()
        if ($client -ne $oldClient) { $changes += "Client ID of AVDTune's own app registration saved: $(if ($oldClient) { "$oldClient -> " })$client" }
    }
    if ($changes.Count -eq 0) { return @() }
    $fields = ConvertTo-AVDTuneEnvironmentFields $envObj
    $fields['SignIn'] = [ordered]@{ TenantId = $tenant; ClientId = $client }
    Write-AVDTuneEnvironmentFields -Root $Root -Fields $fields -User $User
    $version = [string](Get-AVDTuneState $Root).ImageVersion
    if ($version) { foreach ($c in $changes) { [void](Add-AVDTuneChangeLogEntry -Root $Root -Version $version -Category 'Setup' -Component 'Environment' -ChangeType Changed -Text $c -User $User -Source Note) } }
    @($changes)
}

$script:GalleryDefinitionPattern = '^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[A-Za-z0-9._()-]+/providers/Microsoft\.Compute/galleries/[A-Za-z0-9._()-]+/images/[A-Za-z0-9._()-]+$'

function Get-AVDTuneEnvironmentGallery {
    # The chosen gallery image definition (environment.json Gallery.ImageDefinitionId), '' when none or not a definition ID
    param($Environment)
    $id = [string](Get-AVDTuneProp (Get-AVDTuneProp $Environment 'Gallery') 'ImageDefinitionId')
    if ($id -match $script:GalleryDefinitionPattern) { $id } else { '' }
}

function Set-AVDTuneEnvironmentGallery {
    <#
        Saves the image definition the image is captured into (chosen on the Readiness card from the definitions the gallery search found), or clears it
        with an empty -DefinitionId. Only a gallery image definition ID is accepted. A change goes into the change log (needs an image version) and is returned.
    #>
    param([string]$Root = (Get-AVDTuneRoot), [string]$DefinitionId, [string]$Label, [string]$User)
    $envObj = Get-AVDTuneEnvironment $Root
    if (-not $envObj) { throw 'Answer the first-run questions first.' }
    $id = ([string]$DefinitionId).Trim()
    if ($id -and $id -notmatch $script:GalleryDefinitionPattern) { throw 'That is not the Resource ID of a gallery image definition.' }
    $old = Get-AVDTuneEnvironmentGallery $envObj
    if ($old -ieq $id) { return '' }
    $gallery = if ($id) { [ordered]@{ ImageDefinitionId = $id; Label = (Remove-AVDTuneControlCharacters $Label 200); ChosenBy = (Remove-AVDTuneControlCharacters $User 80); ChosenAt = (Get-Date).ToString('o') } } else { $null }
    $fields = ConvertTo-AVDTuneEnvironmentFields $envObj
    $fields['Gallery'] = $gallery
    Write-AVDTuneEnvironmentFields -Root $Root -Fields $fields -User $User
    $short = { param($v) if ($v) { (($v -split '/')[-3]) + '/' + (($v -split '/')[-1]) } else { 'none' } }
    $text = "Image definition for the readiness check: $(& $short $old) -> $(& $short $id)"
    $version = [string](Get-AVDTuneState $Root).ImageVersion
    if ($version) { [void](Add-AVDTuneChangeLogEntry -Root $Root -Version $version -Category 'Setup' -Component 'Environment' -ChangeType Changed -Text $text -User $User -Source Note) }
    $text
}

#endregion

#region sign-in step

function Invoke-AVDTuneStartSignIn {
    <#
        The sign-in step of the Overview. Tenant and client ID come from environment.json; what is missing comes from the sign-in:
          -Setup         also with a saved client ID: that registration is checked (and replaced when it is not safe) and the signed-in
                         administrator is assigned and gets the consent (how another administrator is added)
          no client ID   AVDTune's own app registration is created (Install-AVDTuneAppRegistration, setup sign-in through
                         'Microsoft Graph Command Line Tools'); its tenant and client ID are saved, then the normal sign-in follows with the
                         account of the setup as login hint.
          no tenant      with an account (name@domain) the tenant of its domain (OpenID discovery); when that fails, 'organizations'.
        After the sign-in the tid of the token is saved as the tenant (change log). A saved tenant must match the sign-in (Connect-AVDTuneSession).
        Returns Info (session summary, no token), Notes (lines for the protocol), Registration, ConsentNote. Throws readable text.
    #>
    [CmdletBinding()]
    param([string]$Root = (Get-AVDTuneRoot), [Parameter(Mandatory)]$Session, [string]$Account, [string]$User, [int]$RetryDelaySeconds = 5, [switch]$Setup, [string]$ClientId)
    # The sign-in is the first step and needs no answer of the first-run questions (issue #64): tenant and client ID come from the file (it may not exist yet or have
    # no answers), from -ClientId (an existing app registration the administrator typed in the sign-in form) or from the sign-in itself.
    $envObj = Get-AVDTuneEnvironmentFile $Root
    $tenant = ([string](Get-AVDTuneProp (Get-AVDTuneProp $envObj 'SignIn') 'TenantId')).Trim()
    $client = ([string](Get-AVDTuneProp (Get-AVDTuneProp $envObj 'SignIn') 'ClientId')).Trim()
    $Account = ([string]$Account).Trim()
    if ($Account -and -not (Get-AVDTuneAccountDomain $Account)) { throw 'The account must look like name@domain.' }
    $ClientId = ([string]$ClientId).Trim()
    if ($Setup -and $ClientId) { throw 'Set up and a typed client ID exclude each other: -Setup creates a new app registration, a typed client ID uses an existing one.' }
    if ($ClientId) {
        if (-not (Test-AVDTuneTenantGuid $ClientId)) { throw 'The client ID must be a GUID.' }
        if ($ClientId -ieq '14d82eec-204b-4c2f-b7e8-296a70dab67e') { throw "That is Microsoft's setup app; AVDTune needs the client ID of its own app registration (leave the field empty and AVDTune creates it at the sign-in)." }
        $client = $ClientId.ToLowerInvariant()
    }
    $notes = New-Object System.Collections.ArrayList
    $registration = $null
    if (-not $client -or $Setup) {
        $registration = Install-AVDTuneAppRegistration -Auth $Session.Auth -TenantId $tenant -LoginHint $Account -ExistingClientId $client -TempRoot $Session.TempRoot -RetryDelaySeconds $RetryDelaySeconds
        foreach ($n in @($registration.Notes)) { [void]$notes.Add($n) }
        foreach ($c in @(Set-AVDTuneEnvironmentSignIn -Root $Root -TenantId $registration.TenantId -ClientId $registration.ClientId -User $User -Account $registration.Account)) { [void]$notes.Add($c) }
        $client = $registration.ClientId; $tenant = $registration.TenantId
        if (-not $Account) { $Account = [string]$registration.Account }
        if ($Account -and -not (Get-AVDTuneAccountDomain $Account)) { $Account = '' }
    }
    elseif (-not $tenant -and $Account) {
        $domain = Get-AVDTuneAccountDomain $Account
        try {
            $tenant = Resolve-AVDTuneTenantFromDomain -Auth $Session.Auth -Domain $domain
            [void]$notes.Add("Tenant of the domain $domain found: $tenant")
        }
        catch { [void]$notes.Add("The tenant of the domain $domain was not found ($($_.Exception.Message)); the sign-in goes through 'organizations' (needs a multi-tenant app registration).") }
    }
    $info = Connect-AVDTuneSession -Session $Session -TenantId $tenant -ClientId $client -LoginHint $Account
    # a client ID typed in the form is saved only now, after it worked
    foreach ($c in @(Set-AVDTuneEnvironmentSignIn -Root $Root -TenantId $info.TenantId -ClientId $(if ($ClientId) { $client } else { '' }) -User $User -Account $info.Account)) { [void]$notes.Add($c) }
    [pscustomobject]@{ Info = $info; Notes = @($notes); Registration = $registration; ConsentNote = $(if ($registration) { Get-AVDTuneSetupConsentNote } else { '' }) }
}

#endregion

#region start sequence

function New-AVDTuneStartContext {
    # What the start sequence keeps in memory: the session, what the master says about its join (Detection), what Azure says about the VM (AzureFacts),
    # the suggestions for the first-run questions made from both (never an answer before the administrator confirms), the directory as read, failures per stage
    [pscustomobject]@{ Session = $null; Detection = $null; AzureFacts = $null; Suggestions = $null; Directory = $null; DirectorySecurity = ''; Gate = $null; Failures = @{} }
}

function Update-AVDTuneStartDetection {
    <# Step 2 of the start sequence: read the join state of the master (read only, Get-AVDTuneJoinState) and keep it in the context. #>
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Machine)
    $Context.Detection = Get-AVDTuneJoinState -Machine $Machine
    $Context.Suggestions = $null
    $Context.Detection
}

function Update-AVDTuneStartSuggestions {
    <#
        Step 3 of the start sequence: what Azure says about this VM (only GET, Get-AVDTuneAzureFacts) and, together with the join state, the suggestions for the first-run
        questions. Without the join state it is read first. Azure not reachable or no token: the facts say so and only the domain based suggestions remain.
        Nothing is saved: a suggestion becomes an answer when the administrator confirms the questions (Save-AVDTuneEnvironment).
    #>
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Machine, $Arm)
    if (-not $Context.Detection) { [void](Update-AVDTuneStartDetection -Context $Context -Machine $Machine) }
    $vm = Get-AVDTuneVmIdentity $Machine
    $facts = $null
    $token = ''
    if ($Context.Session -and $Context.Session.Connected) { try { $token = Get-AVDTuneAccessToken -Session $Context.Session -Audience Arm } catch { $facts = [pscustomobject]@{ Reachable = $false; Problem = $_.Exception.Message; Region = ''; VNet = ''; Subnet = ''; SubnetId = ''; StorageAccounts = @(); DnsZone = $null; Problems = @() } } }
    if (-not $facts) {
        if ($Arm -and $token) { try { $facts = Get-AVDTuneAzureFacts -Arm $Arm -Token $token -Vm $vm } catch { $facts = $null } }
        if (-not $facts) { $facts = [pscustomobject]@{ Reachable = $false; Problem = $(if (-not $token) { 'Not signed in to Azure.' } else { 'Azure could not be read.' }); Region = ''; VNet = ''; Subnet = ''; SubnetId = ''; StorageAccounts = @(); DnsZone = $null; Problems = @() } }
    }
    $Context.AzureFacts = $facts
    $Context.Suggestions = Get-AVDTuneAnswerSuggestions -Detection $Context.Detection -AzureFacts $facts
    $Context.Suggestions
}

function Get-AVDTuneAnswerSuggestions {
    <#
        The suggestions for the first-run questions from the join state and the Azure facts. Items: key -> @{ Key; State = 'Detected' | 'Ambiguous'; Value; Source; Hint }.
        Detected has a value (the form preselects it and shows the source); Ambiguous has none (the question stays open and the hint says why).
        Every value is data and is checked before it is suggested: a choice must be one of the choices of its question, a network name must pass the same rule as an answer;
        a value that fails is not suggested and named in Rejected. A key without an item is not known and is simply asked.
    #>
    param($Detection, $AzureFacts)
    $items = [ordered]@{}; $rejected = New-Object System.Collections.ArrayList; $notes = New-Object System.Collections.ArrayList
    $choices = @{}; foreach ($q in $script:Questions) { $choices[$q.Key] = @($q.Choices | ForEach-Object { $_.Value }) }
    $detect = {
        param($key, $value, $source)
        $ok = if ($choices.ContainsKey($key)) { [string]$value -cin $choices[$key] } else { ([string]$value).Length -le 1024 -and [regex]::IsMatch([string]$value, '^[A-Za-z0-9_./ -]{1,200}$', [Text.RegularExpressions.RegexOptions]::None, [TimeSpan]::FromSeconds(2)) }
        if (-not $ok) { [void]$rejected.Add("$key (the value found is not valid)"); return }
        $items[$key] = [pscustomobject]@{ Key = $key; State = 'Detected'; Value = [string]$value; Source = $source; Hint = '' }
    }
    $ambiguous = { param($key, $hint) if (-not $items.Contains($key)) { $items[$key] = [pscustomobject]@{ Key = $key; State = 'Ambiguous'; Value = ''; Source = ''; Hint = $hint } } }
    if ($Detection) {
        $how = 'Win32_ComputerSystem and dsregcmd /status of this master'
        switch ($Detection.Kind) {
            'Hybrid' {
                & $detect 'Join' 'Hybrid' "$how`: joined to the domain$(if ($Detection.DomainName) { " $($Detection.DomainName)" }) and to Microsoft Entra ID"
                & $detect 'Identities' 'Synced' 'a host joined to a domain needs synchronized identities'
                & $ambiguous 'Dc' $(if ($Detection.Dc) { "A domain controller was found ($(if ($Detection.Dc.Name) { $Detection.Dc.Name } else { $Detection.Dc.Address })); whether it runs in Azure or on premises is not visible from here." } else { 'The master is joined to a domain; whether its domain controller runs in Azure or on premises is not visible from here.' })
            }
            'AdDs' {
                & $detect 'Join' 'AdDs' "$how`: joined to the domain$(if ($Detection.DomainName) { " $($Detection.DomainName)" })"
                & $detect 'Identities' 'Synced' 'a host joined to a domain needs synchronized identities'
                & $ambiguous 'Dc' $(if ($Detection.Dc) { "A domain controller was found ($(if ($Detection.Dc.Name) { $Detection.Dc.Name } else { $Detection.Dc.Address })); whether it runs in Azure or on premises is not visible from here." } else { 'The master is joined to a domain; whether its domain controller runs in Azure or on premises is not visible from here.' })
            }
            'EntraOnly' {
                & $detect 'Join' 'EntraOnly' "$how`: joined to Microsoft Entra ID only, no domain"
                & $detect 'Dc' 'None' "$how`: no domain, so no domain controller to read"
                & $ambiguous 'Identities' 'Cloud only or synchronized from a directory is not visible from here.'
            }
            default {
                & $ambiguous 'Join' 'This master is not joined (as a golden master should be), so it says nothing about how the session hosts will join.'
                & $ambiguous 'Dc' 'This master is not joined to a domain; say whether the session hosts use a domain controller and where it runs.'
            }
        }
        foreach ($p in @($Detection.Problems)) { [void]$notes.Add("Join state: $p") }
    }
    if ($AzureFacts -and $AzureFacts.Reachable) {
        $azure = 'Azure Resource Manager (read only)'
        if ($AzureFacts.VNet) { & $detect 'VNet' $AzureFacts.VNet "$azure`: virtual network of this VM's network interface" }
        if ($AzureFacts.Subnet) { & $detect 'Subnet' $AzureFacts.Subnet "$azure`: subnet of this VM's network interface" }
        $accounts = @($AzureFacts.StorageAccounts)
        if ($accounts.Count -eq 1) {
            $a = $accounts[0]
            & $detect 'Profiles' 'AzureFiles' "$azure`: the storage account $($a.Name) in the resource group of this VM"
            if ($a.PrivateEndpoints -gt 0) { & $detect 'Endpoint' 'Private' "$azure`: the storage account $($a.Name) has a private endpoint" }
            elseif ($a.PublicAccess -eq 'Enabled') { & $detect 'Endpoint' 'Public' "$azure`: the storage account $($a.Name) has no private endpoint and allows public access" }
            else { & $ambiguous 'Endpoint' "The storage account $($a.Name) has neither a private endpoint nor public access." }
        }
        elseif ($accounts.Count -gt 1) {
            & $ambiguous 'Profiles' ("More than one storage account is in the resource group of this VM ($(@($accounts | Select-Object -First 5 | ForEach-Object { $_.Name }) -join ', ')); say which profile storage is used.")
        }
        if ($AzureFacts.DnsZone -eq $true) { & $detect 'DnsZone' 'Azure' "$azure`: the private DNS zone privatelink.file.core.windows.net is in the resource group of this VM" }
        foreach ($p in @($AzureFacts.Problems)) { [void]$notes.Add("Azure: $p") }
    }
    elseif ($AzureFacts) { [void]$notes.Add("Azure: nothing could be read, the questions have no suggestion from Azure ($($AzureFacts.Problem))") }
    [pscustomobject]@{ Items = $items; Rejected = @($rejected); Notes = @($notes); Region = $(if ($AzureFacts -and $AzureFacts.Reachable) { [string]$AzureFacts.Region } else { '' }) }
}

function Resolve-AVDTuneAnswerSources {
    <#
        Where each answer came from, for environment.json (Sources): a suggestion that the administrator kept is 'Confirmed: <source>', a different value is 'Typed by the
        administrator (suggested ...)', an answer that did not change keeps its earlier source, everything else is 'Typed by the administrator'.
        -Suggestions is the result of Get-AVDTuneAnswerSuggestions (or $null), -Previous the answers and sources of the saved environment (a change of the answers later).
    #>
    param([Parameter(Mandatory)]$Answers, $Suggestions, $PreviousAnswers, $PreviousSources)
    $r = [ordered]@{}
    $keys = @($script:Questions | ForEach-Object { $_.Key }) + @('VNet', 'Subnet', 'SnapshotNamePattern')
    foreach ($k in $keys) {
        $value = [string](Get-AVDTuneProp $Answers $k)
        $sg = $null; if ($Suggestions -and $Suggestions.Items.Contains($k) -and $Suggestions.Items[$k].State -eq 'Detected') { $sg = $Suggestions.Items[$k] }
        $prev = $null; if ($PreviousAnswers) { $prev = [string](Get-AVDTuneProp $PreviousAnswers $k) }
        if ($sg -and $sg.Value -ceq $value) { $r[$k] = "Confirmed: $($sg.Source)" }
        elseif ($sg) { $r[$k] = "Typed by the administrator (suggested $($sg.Value): $($sg.Source))" }
        elseif ($null -ne $prev -and $prev -ceq $value -and $PreviousSources -and $PreviousSources.Contains($k)) { $r[$k] = [string]$PreviousSources[$k] }
        elseif ($k -eq 'SnapshotNamePattern' -and $value -ceq (Get-AVDTuneDefaultSnapshotNamePattern)) { $r[$k] = 'Default of AVDTune' }
        elseif (-not $value -and $k -in 'VNet', 'Subnet') { $r[$k] = 'Not set' }
        else { $r[$k] = 'Typed by the administrator' }
    }
    $r
}

function Get-AVDTuneStartStages {
    <#
        The four stages with Status and Detail, in order (issue #64): 1 sign-in, 2 domain (what the master says about its join: a domain member has a domain
        controller to read, everything else is 'not needed' with the reason), 3 first-run questions (suggestions with their source, valid after the confirmation),
        4 snapshot gate. A stage is Locked while an earlier one that is not Skipped is not Done.
        Done means: Sign-in connected; Domain read; Environment confirmed; Snapshot confirmed (write gate open).
        Domain: once the questions are confirmed their domain controller answer decides (an environment.json of an earlier version too); before that the join state decides.
    #>
    param([Parameter(Mandatory)]$Context, [string]$Root = (Get-AVDTuneRoot))
    $envObj = Get-AVDTuneEnvironment $Root
    $plan = $null; if ($envObj) { $plan = Resolve-AVDTuneEnvironmentPlan (Get-AVDTuneEnvironmentAnswers $envObj) }
    $stages = New-Object System.Collections.ArrayList
    $add = { param($id, $title, $status, $detail) [void]$stages.Add([pscustomobject]@{ Id = $id; Title = $title; Status = $status; Detail = $detail }) }
    $fail = { param($id) $f = $Context.Failures[$id]; if ($f) { [string]$f } else { $null } }
    $det = $Context.Detection
    $usesDc = $null   # $null: not known yet
    if ($envObj) { $usesDc = [bool]$plan.UsesDc } elseif ($det) { $usesDc = [bool]$det.NeedsDc }

    # 1 sign-in (needs no answer)
    $open = $false
    $signedIn = $Context.Session -and $Context.Session.Connected
    if ($signedIn) { & $add 'SignIn' 'Microsoft 365 and Azure sign-in' 'Done' "$($Context.Session.Account) (Graph, Sites.Selected, Azure Resource Manager)" }
    else { & $add 'SignIn' 'Microsoft 365 and Azure sign-in' $(if (& $fail 'SignIn') { 'Failed' } else { 'Pending' }) $(if (& $fail 'SignIn') { & $fail 'SignIn' } else { 'One sign-in for Graph, SharePoint and Azure. The tenant comes from it. Tokens stay in memory.' }) }
    if (-not $signedIn) { $open = $true }

    # 2 domain
    if ($Context.Directory) { & $add 'Domain' 'Domain controller' 'Done' "$($Context.Directory.DnsName) ($($Context.Directory.NetBiosName)), $($Context.Directory.OuCount) OUs, $(@($Context.Directory.Groups).Count) groups, site $($Context.Directory.Site); $($Context.DirectorySecurity)" }
    elseif ($usesDc -eq $false) {
        & $add 'Domain' 'Domain controller' 'Skipped' $(if ($envObj) { 'Not needed: no domain controller in this environment (groups come from Microsoft Entra ID).' } else { "Not needed: $($det.Reason) No domain controller to read; if the session hosts use one, say so in the questions and this step opens." })
    }
    elseif ($open) { & $add 'Domain' 'Domain controller' 'Locked' 'Sign in first.' }
    elseif ($null -eq $usesDc) { & $add 'Domain' 'Domain controller' $(if (& $fail 'Domain') { 'Failed' } else { 'Pending' }) $(if (& $fail 'Domain') { & $fail 'Domain' } else { 'Reads what this master says about its join (read only), then a domain controller if it is a domain member.' }) }
    else { & $add 'Domain' 'Domain controller' $(if (& $fail 'Domain') { 'Failed' } else { 'Pending' }) $(if (& $fail 'Domain') { & $fail 'Domain' } else { "$(if ($det -and -not $envObj) { "$($det.Reason) " })IP or name of a domain controller and a domain account. LDAPS first, certificate pinned.$(if ($det -and $det.Dc) { " The DC locator found $(if ($det.Dc.Name) { $det.Dc.Name } else { $det.Dc.Address })." })" }) }
    if ($usesDc -ne $false -and -not $Context.Directory) { $open = $true }

    # 3 first-run questions
    if ($envObj) { & $add 'Environment' 'First-run questions' 'Done' ("{0}, {1}" -f $(if ($plan.UsesDc) { 'domain controller used' } else { 'no domain controller' }), $(if ($plan.AzureFilesAuth -eq 'None') { 'no Azure Files' } else { "Azure Files: $($plan.AzureFilesAuth)" })) }
    elseif ($open) { & $add 'Environment' 'First-run questions' 'Locked' 'Finish the earlier steps first.' }
    else { & $add 'Environment' 'First-run questions' $(if (& $fail 'Environment') { 'Failed' } else { 'Pending' }) $(if (& $fail 'Environment') { & $fail 'Environment' } else { 'Only what is missing is asked: what the sign-in, Azure and the domain showed is suggested with its source and counts after you confirm it.' }) }
    if (-not $envObj) { $open = $true }

    # 4 snapshot gate
    if (Test-AVDTuneWriteAllowed) { $g = Get-AVDTuneWriteGate; & $add 'Snapshot' 'Snapshot gate' 'Done' "Confirmed by $($g.ConfirmedBy). The pages can change the master." }
    elseif ($open) { & $add 'Snapshot' 'Snapshot gate' 'Locked' 'Finish the earlier steps first.' }
    else { & $add 'Snapshot' 'Snapshot gate' $(if (& $fail 'Snapshot') { 'Failed' } else { 'Pending' }) $(if (& $fail 'Snapshot') { & $fail 'Snapshot' } else { 'A finished snapshot of the OS disk from the start of this image version (after the last change of the previous version, before the first change of this one), confirmed with your first and last name; one per version, a rollback goes back to the version start. Until then every page is read only.' }) }
    @($stages)
}

function Get-AVDTuneNextStage {
    # The stage to do next: the first that is Pending or Failed; $null when all are Done or Skipped
    param([Parameter(Mandatory)][object[]]$Stages)
    $Stages | Where-Object { $_.Status -in 'Pending', 'Failed' } | Select-Object -First 1
}

#endregion

Export-ModuleMember -Function Get-AVDTuneQuestions, Get-AVDTuneEnvironmentDefaults, Test-AVDTuneEnvironmentAnswers, Get-AVDTuneAzureFilesAuthChoices, Resolve-AVDTuneEnvironmentPlan,
    Get-AVDTuneEnvironment, Get-AVDTuneEnvironmentFile, Get-AVDTuneEnvironmentAnswers, Get-AVDTuneAnswerSources, Save-AVDTuneEnvironment, Get-AVDTuneDcPins, Set-AVDTuneDcPin, Save-AVDTuneDcDiscovery, Set-AVDTuneEnvironmentSignIn, Get-AVDTuneEnvironmentGallery, Set-AVDTuneEnvironmentGallery, Invoke-AVDTuneStartSignIn,
    New-AVDTuneStartContext, Update-AVDTuneStartDetection, Update-AVDTuneStartSuggestions, Get-AVDTuneAnswerSuggestions, Resolve-AVDTuneAnswerSources, Get-AVDTuneStartStages, Get-AVDTuneNextStage
