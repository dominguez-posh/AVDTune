<#
    AVDTune start: the first-run questions (identity model) with environment.json, and the start sequence on the Overview.

    environment.json (C:\ProgramData\AVDTune\environment.json, next to state.json): the answers, the tenant and client ID of the app
    registration, the snapshot name pattern, the chosen gallery image definition (readiness), the domain controller (name, account name, pinned certificate thumbprints, summary of what was read). Never a secret:
    only fields of the table below are written, text is cleaned, and no password, token or key has a field.

    Start sequence (docs\plans\avdtune.md 1a): Environment -> Sign-in -> Domain (only with a DC) -> Snapshot gate. Every stage has a status the
    Overview shows: Pending, Locked (an earlier stage is open), Done, Skipped, Failed. The context ($Context) holds what lives in memory only.
#>

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'AVDTune.psm1')
Import-Module (Join-Path $PSScriptRoot 'AVDTune.Snapshot.psm1')
Import-Module (Join-Path $PSScriptRoot 'AVDTune.Session.psm1')

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

function Get-AVDTuneEnvironment {
    <# The saved environment, or $null before the first run. #>
    param([string]$Root = (Get-AVDTuneRoot))
    $envObj = Read-AVDTuneJson (Get-AVDTuneEnvironmentPath $Root)
    if ($null -eq $envObj) { return $null }
    if ([int](Get-AVDTuneProp $envObj 'Schema') -gt 1) { throw 'environment.json is from a newer AVDTune.' }
    $envObj
}

function Get-AVDTuneEnvironmentAnswers {
    # The answers of the saved environment as a flat object (defaults for what is not there)
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

function Save-AVDTuneEnvironment {
    <#
        Writes the answers. Throws when the combination is invalid. Keeps the domain controller part (pins) as it is. When an answer changed
        after an environment existed, the change goes into the change log (needs an image version; without one the diff is only returned).
        The tenant is not asked: an empty TenantId keeps the saved one; -ForgetTenant removes it (the next sign-in sets it again).
        Returns @{ Environment; Changes = 'Name: old -> new' ... }.
    #>
    [CmdletBinding()]
    param([string]$Root = (Get-AVDTuneRoot), [Parameter(Mandatory)]$Answers, [string]$User, [switch]$ForgetTenant)
    $check = Test-AVDTuneEnvironmentAnswers $Answers
    if ($check.Errors.Count -gt 0) { throw ($check.Errors -join ' ') }
    $old = Get-AVDTuneEnvironment $Root
    $oldAnswers = if ($old) { Get-AVDTuneEnvironmentAnswers $old } else { $null }
    $tenant = [string](Get-AVDTuneProp $Answers 'TenantId')
    if ($ForgetTenant) { $tenant = '' } elseif (-not $tenant.Trim() -and $oldAnswers) { $tenant = [string]$oldAnswers.TenantId }
    $clean = { param($v, $n) Remove-AVDTuneControlCharacters ([string]$v) $n }
    $plan = Resolve-AVDTuneEnvironmentPlan $Answers
    $envObj = [ordered]@{
        Schema = 1
        Answers = [ordered]@{
            Join = [string]$Answers.Join; Dc = [string]$Answers.Dc; Identities = [string]$Answers.Identities; Profiles = [string]$Answers.Profiles
            AzureFilesAuth = [string]$plan.AzureFilesAuth; Network = [ordered]@{ Endpoint = [string]$Answers.Endpoint; VNet = (& $clean $Answers.VNet 200); Subnet = (& $clean $Answers.Subnet 200); DnsZone = [string]$Answers.DnsZone }
        }
        SignIn = [ordered]@{ TenantId = (& $clean $tenant 255).Trim(); ClientId = (& $clean $Answers.ClientId 36).Trim() }
        Snapshot = [ordered]@{ NamePattern = $(if ([string](Get-AVDTuneProp $Answers 'SnapshotNamePattern')) { (& $clean $Answers.SnapshotNamePattern 80).Trim() } else { Get-AVDTuneDefaultSnapshotNamePattern }) }
        Dc = $(if ($old -and (Get-AVDTuneProp $old 'Dc')) { Get-AVDTuneProp $old 'Dc' } else { [ordered]@{ Server = ''; User = ''; Pins = [ordered]@{}; Discovery = $null } })
        Gallery = $(if ($old) { Get-AVDTuneProp $old 'Gallery' } else { $null })
        Updated = (Get-Date).ToString('o'); UpdatedBy = (& $clean $User 80)
    }
    Write-AVDTuneFile (Get-AVDTuneEnvironmentPath $Root) ($envObj | ConvertTo-Json -Depth 8)
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
    $envObj = Get-AVDTuneEnvironment $Root
    if (-not $envObj) { throw 'Answer the first-run questions first.' }
    $server = $Server.Trim().ToLowerInvariant()
    $sha = [string]$Certificate.Sha256
    if ($sha -notmatch '^[0-9A-Fa-f]{64}$') { throw 'The certificate has no valid SHA-256 thumbprint.' }
    $existing = Get-AVDTuneDcPins $envObj
    if ($existing.ContainsKey($server) -and $existing[$server] -ine $sha -and -not $Replace) { throw "A different certificate is pinned for $server. Replacing it needs an explicit confirmation." }
    $record = [ordered]@{ Sha256 = $sha.ToUpperInvariant(); Thumbprint = [string]$Certificate.Thumbprint; Subject = (Remove-AVDTuneControlCharacters ([string]$Certificate.Subject) 300); PinnedAt = (Get-Date).ToString('o'); PinnedBy = (Remove-AVDTuneControlCharacters $User 80) }
    $dc = [ordered]@{ Server = [string](Get-AVDTuneProp $envObj.Dc 'Server'); User = [string](Get-AVDTuneProp $envObj.Dc 'User'); Pins = [ordered]@{}; Discovery = (Get-AVDTuneProp $envObj.Dc 'Discovery') }
    $oldPins = Get-AVDTuneProp $envObj.Dc 'Pins'
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
    $copy = [ordered]@{ Schema = 1; Answers = $Environment.Answers; SignIn = $Environment.SignIn; Snapshot = (Get-AVDTuneProp $Environment 'Snapshot'); Dc = $Dc; Gallery = (Get-AVDTuneProp $Environment 'Gallery'); Updated = (Get-Date).ToString('o'); UpdatedBy = [string](Get-AVDTuneProp $Environment 'UpdatedBy') }
    Write-AVDTuneFile (Get-AVDTuneEnvironmentPath $Root) ($copy | ConvertTo-Json -Depth 10)
}

function Save-AVDTuneDcDiscovery {
    <# Server, account name (no password) and a summary of what was read (domain, NetBIOS name, levels, site, counts) into environment.json. #>
    param([string]$Root = (Get-AVDTuneRoot), [Parameter(Mandatory)][string]$Server, [Parameter(Mandatory)][string]$User, [Parameter(Mandatory)]$Info)
    $envObj = Get-AVDTuneEnvironment $Root
    if (-not $envObj) { throw 'Answer the first-run questions first.' }
    $summary = [ordered]@{
        DnsName = $Info.DnsName; NetBiosName = $Info.NetBiosName; Site = $Info.Site; DomainLevel = $Info.DomainLevel; ForestLevel = $Info.ForestLevel
        DefaultNamingContext = $Info.DefaultNamingContext; OuCount = $Info.OuCount; GroupCount = @($Info.Groups).Count; ReadAt = (Get-Date).ToString('o')
    }
    $dc = [ordered]@{ Server = $Server.Trim().ToLowerInvariant(); User = (Remove-AVDTuneControlCharacters $User 256); Pins = $(if (Get-AVDTuneProp $envObj.Dc 'Pins') { $envObj.Dc.Pins } else { [ordered]@{} }); Discovery = $summary }
    Update-AVDTuneEnvironmentDc -Root $Root -Environment $envObj -Dc $dc
}

function Set-AVDTuneEnvironmentSignIn {
    <#
        Writes the tenant and/or the client ID that the sign-in found (tid of the token, AVDTune's own app registration) into environment.json.
        A value that changes goes into the change log (needs an image version) and is returned as text.
    #>
    param([string]$Root = (Get-AVDTuneRoot), [string]$TenantId, [string]$ClientId, [string]$User, [string]$Account)
    $envObj = Get-AVDTuneEnvironment $Root
    if (-not $envObj) { throw 'Answer the first-run questions first.' }
    $oldTenant = [string](Get-AVDTuneProp $envObj.SignIn 'TenantId'); $oldClient = [string](Get-AVDTuneProp $envObj.SignIn 'ClientId')
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
    $copy = [ordered]@{ Schema = 1; Answers = $envObj.Answers; SignIn = [ordered]@{ TenantId = $tenant; ClientId = $client }; Snapshot = (Get-AVDTuneProp $envObj 'Snapshot'); Dc = (Get-AVDTuneProp $envObj 'Dc'); Gallery = (Get-AVDTuneProp $envObj 'Gallery'); Updated = (Get-Date).ToString('o'); UpdatedBy = (Remove-AVDTuneControlCharacters $User 80) }
    Write-AVDTuneFile (Get-AVDTuneEnvironmentPath $Root) ($copy | ConvertTo-Json -Depth 10)
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
    $copy = [ordered]@{ Schema = 1; Answers = $envObj.Answers; SignIn = (Get-AVDTuneProp $envObj 'SignIn'); Snapshot = (Get-AVDTuneProp $envObj 'Snapshot'); Dc = (Get-AVDTuneProp $envObj 'Dc'); Gallery = $gallery; Updated = (Get-Date).ToString('o'); UpdatedBy = (Remove-AVDTuneControlCharacters $User 80) }
    Write-AVDTuneFile (Get-AVDTuneEnvironmentPath $Root) ($copy | ConvertTo-Json -Depth 10)
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
    param([string]$Root = (Get-AVDTuneRoot), [Parameter(Mandatory)]$Session, [string]$Account, [string]$User, [int]$RetryDelaySeconds = 5, [switch]$Setup)
    $envObj = Get-AVDTuneEnvironment $Root
    if (-not $envObj) { throw 'Answer the first-run questions first.' }
    $tenant = ([string](Get-AVDTuneProp $envObj.SignIn 'TenantId')).Trim()
    $client = ([string](Get-AVDTuneProp $envObj.SignIn 'ClientId')).Trim()
    $Account = ([string]$Account).Trim()
    if ($Account -and -not (Get-AVDTuneAccountDomain $Account)) { throw 'The account must look like name@domain.' }
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
    foreach ($c in @(Set-AVDTuneEnvironmentSignIn -Root $Root -TenantId $info.TenantId -User $User -Account $info.Account)) { [void]$notes.Add($c) }
    [pscustomobject]@{ Info = $info; Notes = @($notes); Registration = $registration; ConsentNote = $(if ($registration) { Get-AVDTuneSetupConsentNote } else { '' }) }
}

#endregion

#region start sequence

function New-AVDTuneStartContext {
    # What the start sequence keeps in memory: the session, the directory as read, the gate status, failures per stage
    [pscustomobject]@{ Session = $null; Directory = $null; DirectorySecurity = ''; Gate = $null; Failures = @{} }
}

function Get-AVDTuneStartStages {
    <#
        The four stages with Status and Detail, in order. A stage is Locked while an earlier one that is not Skipped is not Done.
        Done means: Environment saved; Sign-in connected; Domain read; Snapshot confirmed (write gate open).
    #>
    param([Parameter(Mandatory)]$Context, [string]$Root = (Get-AVDTuneRoot))
    $envObj = Get-AVDTuneEnvironment $Root
    $plan = $null; if ($envObj) { $plan = Resolve-AVDTuneEnvironmentPlan (Get-AVDTuneEnvironmentAnswers $envObj) }
    $stages = New-Object System.Collections.ArrayList
    $add = { param($id, $title, $status, $detail) [void]$stages.Add([pscustomobject]@{ Id = $id; Title = $title; Status = $status; Detail = $detail }) }
    $fail = { param($id) $f = $Context.Failures[$id]; if ($f) { [string]$f } else { $null } }

    # 1 environment
    if ($envObj) { & $add 'Environment' 'First-run questions' 'Done' ("{0}, {1}" -f $(if ($plan.UsesDc) { 'domain controller used' } else { 'no domain controller' }), $(if ($plan.AzureFilesAuth -eq 'None') { 'no Azure Files' } else { "Azure Files: $($plan.AzureFilesAuth)" })) }
    else { & $add 'Environment' 'First-run questions' $(if (& $fail 'Environment') { 'Failed' } else { 'Pending' }) $(if (& $fail 'Environment') { & $fail 'Environment' } else { 'Describe the planned AVD environment.' }) }
    $open = -not $envObj

    # 2 sign-in
    $signedIn = $Context.Session -and $Context.Session.Connected
    if ($signedIn) { & $add 'SignIn' 'Microsoft 365 and Azure sign-in' 'Done' "$($Context.Session.Account) (Graph, Sites.Selected, Azure Resource Manager)" }
    elseif ($open) { & $add 'SignIn' 'Microsoft 365 and Azure sign-in' 'Locked' 'Answer the first-run questions first.' }
    else { & $add 'SignIn' 'Microsoft 365 and Azure sign-in' $(if (& $fail 'SignIn') { 'Failed' } else { 'Pending' }) $(if (& $fail 'SignIn') { & $fail 'SignIn' } else { 'One sign-in for Graph, SharePoint and Azure. Tokens stay in memory.' }) }
    if (-not $signedIn) { $open = $true }

    # 3 domain
    if ($envObj -and -not $plan.UsesDc) { & $add 'Domain' 'Domain controller' 'Skipped' 'Not needed: no domain controller in this environment (groups come from Microsoft Entra ID).' }
    elseif ($Context.Directory) { & $add 'Domain' 'Domain controller' 'Done' "$($Context.Directory.DnsName) ($($Context.Directory.NetBiosName)), $($Context.Directory.OuCount) OUs, $(@($Context.Directory.Groups).Count) groups, site $($Context.Directory.Site); $($Context.DirectorySecurity)" }
    elseif ($open) { & $add 'Domain' 'Domain controller' 'Locked' 'Finish the earlier steps first.' }
    else { & $add 'Domain' 'Domain controller' $(if (& $fail 'Domain') { 'Failed' } else { 'Pending' }) $(if (& $fail 'Domain') { & $fail 'Domain' } else { 'IP or name of a domain controller and a domain account. LDAPS first, certificate pinned.' }) }
    if ($envObj -and $plan.UsesDc -and -not $Context.Directory) { $open = $true }

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
    Get-AVDTuneEnvironment, Get-AVDTuneEnvironmentAnswers, Save-AVDTuneEnvironment, Get-AVDTuneDcPins, Set-AVDTuneDcPin, Save-AVDTuneDcDiscovery, Set-AVDTuneEnvironmentSignIn, Get-AVDTuneEnvironmentGallery, Set-AVDTuneEnvironmentGallery, Invoke-AVDTuneStartSignIn,
    New-AVDTuneStartContext, Get-AVDTuneStartStages, Get-AVDTuneNextStage
