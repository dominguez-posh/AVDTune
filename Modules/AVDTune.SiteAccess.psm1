<#
    AVDTune site access (issue #96, follow-up of #89): the one-time grant of the Sites.Selected role 'write' on the SharePoint site of the environment, so the
    uploads of AVDTune.SharePoint.psm1 (change log, software list, environment document) work with the Sites token of the daily sign-in.

    Sites.Selected alone gives no access: somebody who may manage the site (SharePoint Administrator, or an owner of the site) grants AVDTune's own app registration
    a role on that ONE site (Graph: POST /sites/{id}/permissions). The daily sign-in cannot do that. Like PackTune's package store, the grant uses a second, short
    sign-in through Microsoft's public client 'Microsoft Graph Command Line Tools' with the delegated permission Sites.FullControl.All. That token is used for this
    step only, lives in a variable of one function, goes only to https://graph.microsoft.com (the Graph member of the sign-in adapter: fixed host, no redirects) and
    is dropped in the finally block. The consent the administrator gives that Microsoft app for Sites.FullControl.All STAYS in the tenant afterwards
    (Get-AVDTuneSiteAccessConsentNote says where to remove it); AVDTune does not remove it, because that would need one more high permission
    (DelegatedPermissionGrant.ReadWrite.All) for this step.

    The mechanics are the ones of the environment wizard (AVDTune.Environment.psm1, docs\environment-wizard.md):
      * Plan first: Get-AVDTuneSiteAccessPlan is pure (site, app registration, role, the exact request, a hash). The confirmation names site and role.
      * Write only through Grant-AVDTuneSiteAccess: not after the finish, snapshot gate open, the plan is built again and must have the confirmed hash. The role is
        always 'write', the holder always AVDTune's own app registration (never Microsoft's setup app), the site always the one saved in config\sharepoint.json.
      * Journal config\sharepoint-access.json, written before and after the write (Started, Done, Failed; no token). A grant that exists already is not AVDTune's:
        nothing is sent and nothing recorded, so the undo never removes it.
      * Undo (Get-AVDTuneSiteAccessUndoPlan, Revoke-AVDTuneSiteAccess) works only from the journal, and the journal is input, not trust: an entry counts only with a
        site id of the host of its own site address, a GUID as client ID, a permission id of known characters and the status Done. The permission is read again
        right before the DELETE and removed only when it still is a permission of exactly that app registration; one that is gone is marked as taken back.
      * Not a change of the master (docs\security-checklist.md, clarification of issue 32): no LastChange; change log entries have the category Azure.

    The status for the readiness analysis (Get-AVDTuneSiteAccessState) uses the Sites token of the daily sign-in and only reads (GET of the site): 401/403 means the
    role is missing. Whether a role that exists is 'read' or 'write' cannot be read with Sites.Selected; AVDTune knows it only for the grant in its own journal.

    NOT exercised against a real tenant: the request shapes are written from the Graph reference (site permissions) and from PackTune's package store.
#>

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'AVDTune.psm1')
Import-Module (Join-Path $PSScriptRoot 'AVDTune.Session.psm1')
Import-Module (Join-Path $PSScriptRoot 'AVDTune.SharePoint.psm1')

$script:SetupClientId = '14d82eec-204b-4c2f-b7e8-296a70dab67e'   # Microsoft Graph Command Line Tools: only the sign-in of this step, never the holder of a site permission
$script:GrantScope = 'Sites.FullControl.All'
$script:GrantRole = 'write'
$script:GraphResource = 'https://graph.microsoft.com'
$script:GuidPattern = '\A[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\z'
$script:PermissionIdPattern = '\A[A-Za-z0-9_-]{1,400}={0,2}\z'
$script:RegexTimeout = [TimeSpan]::FromMilliseconds(500)
$script:ConsentNote = "The sign-in of this step gives Microsoft's app 'Microsoft Graph Command Line Tools' the permission Sites.FullControl.All for your account. AVDTune uses it for this one request and drops the token; the consent itself stays in the tenant. Remove it when it is not needed any more: Entra admin center > Enterprise applications > Microsoft Graph Command Line Tools > Permissions > Revoke, or take Sites.FullControl.All out of its consent with Microsoft Graph PowerShell (Update-MgOauth2PermissionGrant)."
$script:RoleText = 'Granting or removing a site permission needs the role SharePoint Administrator (or Global Administrator), or an owner of that site.'

function Get-AVDTuneSiteAccessConsentNote { $script:ConsentNote }

function Get-AVDTuneSiteAccessHash([string]$Text) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { (-join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)) | ForEach-Object { $_.ToString('x2') })).Substring(0, 24) } finally { $sha.Dispose() }
}

function Test-AVDTuneSiteAccessText([string]$Text, [string]$Pattern) { [bool]($Text -and [regex]::IsMatch($Text, $Pattern, 'None', $script:RegexTimeout)) }

#region journal

function Get-AVDTuneSiteAccessJournalPath([string]$Root) { Join-Path $Root 'config\sharepoint-access.json' }

function Get-AVDTuneSiteAccessJournal {
    param([string]$Root = (Get-AVDTuneRoot))
    $j = Read-AVDTuneJson (Get-AVDTuneSiteAccessJournalPath $Root)
    if ($null -eq $j) { return [pscustomobject]@{ Schema = 1; Grants = @() } }
    $schema = Get-AVDTuneProp $j 'Schema'
    if (($schema -is [int] -or $schema -is [long]) -and $schema -gt 1) { throw 'sharepoint-access.json is from a newer AVDTune.' }
    [pscustomobject]@{ Schema = 1; Grants = @(@(Get-AVDTuneProp $j 'Grants') | Where-Object { $null -ne $_ }) }
}

function Save-AVDTuneSiteAccessJournal([string]$Root, $Journal) { Invoke-AVDTuneStateLock { Write-AVDTuneFile (Get-AVDTuneSiteAccessJournalPath $Root) ($Journal | ConvertTo-Json -Depth 6) } }

function ConvertTo-AVDTuneSiteAccessGrant {
    <# The journal is input, not trust: one entry as typed values, or $null when it cannot be an entry of AVDTune (wrong types, a site id of another host, a client ID that is no GUID or is Microsoft's setup app, another role). #>
    param($Entry)
    $t = { param($n) $v = Get-AVDTuneProp $Entry $n; if ($v -is [string]) { $v } else { '' } }
    $site = (& $t 'SiteUrl'); $siteId = (& $t 'SiteId'); $client = (& $t 'ClientId'); $role = (& $t 'Role'); $status = (& $t 'Status'); $perm = (& $t 'PermissionId')
    if (-not (Test-AVDTuneSpSiteUrl $site)) { return $null }
    if (-not (Test-AVDTuneSiteAccessText $client $script:GuidPattern) -or $client -ieq $script:SetupClientId) { return $null }
    if ($role -cne $script:GrantRole -or $status -cnotin 'Started', 'Done', 'Failed') { return $null }
    if ($siteId -and -not (Test-AVDTuneSpSiteId -Id $siteId -SiteHost ([Uri]$site).Host)) { return $null }
    if ($perm -and -not (Test-AVDTuneSiteAccessText $perm $script:PermissionIdPattern)) { return $null }
    $undone = Get-AVDTuneProp $Entry 'Undone'
    [pscustomobject]@{
        RunId = (Remove-AVDTuneControlCharacters (& $t 'RunId') 40); SiteUrl = $site.TrimEnd('/'); SiteId = $siteId; ClientId = $client.ToLowerInvariant(); Role = $role; PermissionId = $perm; Status = $status
        Undone = [bool]($undone -is [bool] -and $undone); At = (Remove-AVDTuneControlCharacters (& $t 'At') 40)
    }
}

#endregion

#region the request

function Invoke-AVDTuneSiteAccessGraph {
    # One Graph call of this step through the sign-in adapter (fixed host, no redirects, never throws). Returns Status and Body; the text of a failure never holds the token.
    param($Auth, [string]$Token, [string]$Method, [string]$Path, $Body)
    $r = & $Auth.Graph $Method $Path $Token $Body
    $status = [int](Get-AVDTuneProp $r 'Status')
    $detail = [string](Get-AVDTuneProp (Get-AVDTuneProp (Get-AVDTuneProp $r 'Body') 'error') 'code')
    if (-not $detail -and $status -eq 0) { $detail = [string](Get-AVDTuneProp $r 'Error') }
    [pscustomobject]@{ Status = $status; Body = (Get-AVDTuneProp $r 'Body'); Detail = (Remove-AVDTuneControlCharacters (Protect-AVDTuneSpText $detail 120) 120) }
}

function Get-AVDTuneSiteAccessFailure([string]$Step, $Answer) {
    if ($Answer.Status -eq 0) { return "No connection to Microsoft Graph ($Step)$(if ($Answer.Detail) { ": $($Answer.Detail)" }). Check the network and the proxy, then try again." }
    if ($Answer.Status -in 401, 403) { return "Your account may not do this: $Step (Microsoft Graph answered $($Answer.Status)$(if ($Answer.Detail) { ", $($Answer.Detail)" })). $script:RoleText" }
    "Microsoft Graph refused: $Step ($($Answer.Status)$(if ($Answer.Detail) { ", $($Answer.Detail)" }))."
}

function Get-AVDTuneSiteAccessHolders {
    # The applications of ONE permission object of a site (grantedToIdentitiesV2, grantedToIdentities, grantedToV2), as client IDs in lower case
    param($Permission)
    @(@(Get-AVDTuneProp $Permission 'grantedToIdentitiesV2') + @(Get-AVDTuneProp $Permission 'grantedToIdentities') + @(Get-AVDTuneProp $Permission 'grantedToV2') | Where-Object { $_ } | ForEach-Object { Get-AVDTuneProp $_ 'application' } | Where-Object { $_ } |
        ForEach-Object { ([string](Get-AVDTuneProp $_ 'id')).ToLowerInvariant() } | Where-Object { $_ } | Select-Object -Unique)
}

function Get-AVDTuneSiteAccessToken {
    <# The sign-in of this step: Microsoft's setup app at the tenant of the environment with Sites.FullControl.All. The token is checked first (Graph audience, this tenant, the permission) and only then returned; the caller drops it in its finally block. #>
    param($Auth, [string]$TenantId, [string]$LoginHint, [string]$TempRoot)
    $answer = $null
    try { $answer = & $Auth.SignIn $TenantId $script:SetupClientId @("$script:GraphResource/$script:GrantScope") ([string]$LoginHint) }
    catch { throw ('Sign-in for the site permission (Microsoft Graph Command Line Tools): ' + (ConvertTo-AVDTuneAuthError -Message $_.Exception.Message)) }
    finally { if ($TempRoot) { [void](Remove-AVDTuneSignInLeftovers -TempRoot $TempRoot) } }
    $token = [string](Get-AVDTuneProp $answer 'access_token'); $answer = $null
    if (-not $token) { throw 'The sign-in for the site permission returned no access token.' }
    $claims = Get-AVDTuneTokenClaims $token
    if ([string](Get-AVDTuneProp $claims 'aud') -notin $script:GraphResource, '00000003-0000-0000-c000-000000000000') { throw 'The token of the sign-in for the site permission is for another resource.' }
    if (([string](Get-AVDTuneProp $claims 'tid')).ToLowerInvariant() -ne $TenantId.ToLowerInvariant()) { throw 'The account signed in to another tenant than the one of this environment. Sign in with an account of that tenant.' }
    if ($script:GrantScope -notin @(([string](Get-AVDTuneProp $claims 'scp')) -split ' ')) { throw "The sign-in has no consent for $script:GrantScope. Confirm it in the sign-in window. $script:RoleText" }
    [pscustomobject]@{ Token = $token; Account = [string]$(if (Get-AVDTuneProp $claims 'upn') { $claims.upn } else { Get-AVDTuneProp $claims 'preferred_username' }) }
}

function Resolve-AVDTuneSiteAccessSite {
    # The Graph id of the site address, validated against the host of that address before it goes into any path
    param($Auth, [string]$Token, [string]$SiteUrl)
    $u = [Uri]$SiteUrl
    $seg = @($u.AbsolutePath.Trim('/') -split '/')
    $a = Invoke-AVDTuneSiteAccessGraph -Auth $Auth -Token $Token -Method GET -Path "/v1.0/sites/$($u.Host):/$($seg[0])/$($seg[1])?`$select=id"
    if ($a.Status -eq 404) { throw "Microsoft Graph does not know the site $SiteUrl. Check the address on the Protocol page (SharePoint)." }
    if ($a.Status -lt 200 -or $a.Status -gt 299) { throw (Get-AVDTuneSiteAccessFailure 'read the site' $a) }
    $id = [string](Get-AVDTuneProp $a.Body 'id')
    if (-not (Test-AVDTuneSpSiteId -Id $id -SiteHost $u.Host)) { throw 'Microsoft Graph returned a site id that is not valid for this site: refused.' }
    $id
}

#endregion

#region plan and grant

function Get-AVDTuneSiteAccessPlan {
    <#
        Pure, no network: what the grant would send. Site = config\sharepoint.json, holder = AVDTune's own app registration (-ClientId, from environment.json), role write.
        Returns Ready, Problem, SiteUrl, ClientId, TenantId, Role, Scope (of the sign-in), Request (method, path pattern, body), Recorded (a grant of AVDTune for this
        site and registration is in the journal already) and Hash (over site, registration, tenant and role).
    #>
    param([string]$Root = (Get-AVDTuneRoot), [string]$ClientId, [string]$TenantId)
    $site = [string](Get-AVDTuneSpSettings -Root $Root).SiteUrl
    $ClientId = ([string]$ClientId).Trim().ToLowerInvariant(); $TenantId = ([string]$TenantId).Trim().ToLowerInvariant()
    $problem = ''
    if (-not $site) { $problem = 'No SharePoint site is set (Protocol page, SharePoint card).' }
    elseif (-not (Test-AVDTuneSiteAccessText $ClientId $script:GuidPattern) -or -not (Test-AVDTuneSiteAccessText $TenantId $script:GuidPattern)) { $problem = "AVDTune's app registration or its tenant is not known yet: sign in on the Overview first." }
    elseif ($ClientId -ieq $script:SetupClientId) { $problem = "The site permission goes to AVDTune's own app registration, never to Microsoft's setup app." }
    $recorded = $false
    if (-not $problem) { $recorded = @(Get-AVDTuneSiteAccessJournal -Root $Root | ForEach-Object { $_.Grants } | ForEach-Object { ConvertTo-AVDTuneSiteAccessGrant $_ } | Where-Object { $_ -and $_.Status -eq 'Done' -and -not $_.Undone -and $_.SiteUrl -ieq $site -and $_.ClientId -eq $ClientId }).Count -gt 0 }
    $body = [ordered]@{ roles = @($script:GrantRole); grantedToIdentities = @([ordered]@{ application = [ordered]@{ id = $ClientId; displayName = 'AVDTune' } }) }
    $hash = Get-AVDTuneSiteAccessHash ((@('site-access', '1', $site.ToLowerInvariant(), $ClientId, $TenantId, $script:GrantRole) -join '|'))
    [pscustomobject]@{
        Ready = (-not $problem); Problem = $problem; SiteUrl = $site; ClientId = $ClientId; TenantId = $TenantId; Role = $script:GrantRole; Scope = $script:GrantScope; Recorded = $recorded
        Request = [pscustomobject]@{ Method = 'POST'; Path = '/v1.0/sites/{site id}/permissions'; Body = $body }; Hash = $hash
    }
}

function Grant-AVDTuneSiteAccess {
    <#
        Grants AVDTune's app registration the role write on the site of the environment, after the confirmation of the plan (-ConfirmedHash). Refuses after the
        finish and without the snapshot gate. Sign-in (setup app, Sites.FullControl.All), site id, the permissions of the site: when the registration holds write
        (or more) already nothing is sent. Otherwise journal (Started), POST, read back (the new permission must name exactly this registration and the role),
        journal (Done with the permission id, or Failed), change log (category Azure). No LastChange. The token is dropped in finally.
        Returns Status (Changed | Unchanged | Refused | Failed), Message, SiteUrl, Role, PermissionId, Account.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Auth, [string]$Root = (Get-AVDTuneRoot), [string]$ClientId, [string]$TenantId, [string]$ConfirmedHash, [string]$LoginHint, [string]$TempRoot, [string]$User, [string]$SnapshotId)
    Assert-AVDTuneNotSealed -Root $Root
    if (-not (Test-AVDTuneWriteAllowed)) { throw 'The snapshot gate is not confirmed: AVDTune is read only until a snapshot newer than its last change is confirmed on the Overview.' }
    $plan = Get-AVDTuneSiteAccessPlan -Root $Root -ClientId $ClientId -TenantId $TenantId
    $out = { param($Status, $Message, $Perm, $Account) [pscustomobject]@{ Status = $Status; Message = $Message; SiteUrl = $plan.SiteUrl; Role = $plan.Role; PermissionId = [string]$Perm; Account = [string]$Account } }
    if (-not $plan.Ready) { return (& $out 'Refused' "Nothing was sent: $($plan.Problem)") }
    if (-not $ConfirmedHash -or $plan.Hash -cne $ConfirmedHash) { return (& $out 'Refused' 'The plan differs from the one that was confirmed (or nothing was confirmed). Nothing was sent: look at the plan and confirm it again.') }
    if ($LoginHint -and -not (Get-AVDTuneAccountDomain $LoginHint)) { $LoginHint = '' }
    $token = $null
    try {
        $signIn = Get-AVDTuneSiteAccessToken -Auth $Auth -TenantId $plan.TenantId -LoginHint $LoginHint -TempRoot $TempRoot
        $token = $signIn.Token
        $siteId = Resolve-AVDTuneSiteAccessSite -Auth $Auth -Token $token -SiteUrl $plan.SiteUrl
        $list = Invoke-AVDTuneSiteAccessGraph -Auth $Auth -Token $token -Method GET -Path "/v1.0/sites/$siteId/permissions"
        if ($list.Status -lt 200 -or $list.Status -gt 299) { throw (Get-AVDTuneSiteAccessFailure 'read the permissions of the site' $list) }
        $mine = @(@(Get-AVDTuneProp $list.Body 'value') | Where-Object { $_ -and (@(Get-AVDTuneSiteAccessHolders $_) -contains $plan.ClientId) })
        $enough = @($mine | Where-Object { @(@(Get-AVDTuneProp $_ 'roles') | Where-Object { $_ -is [string] -and $_ -cin 'write', 'manage', 'fullcontrol', 'owner' }).Count -gt 0 })
        if ($enough.Count -gt 0) { return (& $out 'Unchanged' "AVDTune's app registration already holds the role $(@(@($enough[0].roles) | Where-Object { $_ -is [string] }) -join ', ') on $($plan.SiteUrl): nothing was sent. That permission was not granted by this step and is not taken back by the undo." '' $signIn.Account) }
        $state = Get-AVDTuneState $Root
        $started = Get-Date
        $runId = $started.ToString('yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture) + '-' + [guid]::NewGuid().ToString('N').Substring(0, 4)
        $journal = Get-AVDTuneSiteAccessJournal -Root $Root
        $entry = [pscustomobject][ordered]@{ RunId = $runId; SiteUrl = $plan.SiteUrl; SiteId = $siteId; ClientId = $plan.ClientId; Role = $plan.Role; PermissionId = ''; Status = 'Started'; Message = ''; Undone = $false; At = $started.ToString('o'); User = (Remove-AVDTuneControlCharacters ([string]$User) 120); SnapshotId = [string]$SnapshotId }
        $journal.Grants = @($journal.Grants) + $entry
        Save-AVDTuneSiteAccessJournal $Root $journal   # the intent is on disk before the write
        $made = Invoke-AVDTuneSiteAccessGraph -Auth $Auth -Token $token -Method POST -Path "/v1.0/sites/$siteId/permissions" -Body $plan.Request.Body
        $problem = ''
        $permId = ''
        if ($made.Status -lt 200 -or $made.Status -gt 299) { $problem = Get-AVDTuneSiteAccessFailure 'grant the site permission' $made }
        else {
            $permId = [string](Get-AVDTuneProp $made.Body 'id')
            if (-not (Test-AVDTuneSiteAccessText $permId $script:PermissionIdPattern)) { $permId = ''; $problem = 'The permission was sent, but Microsoft Graph returned no usable id for it. Check the permissions of the site; AVDTune cannot take this one back.' }
            else {
                # read back: the new permission must be the one of exactly this app registration with the role (the grant counts only then)
                $back = Invoke-AVDTuneSiteAccessGraph -Auth $Auth -Token $token -Method GET -Path "/v1.0/sites/$siteId/permissions/$permId"
                $holders = @(if ($back.Status -ge 200 -and $back.Status -le 299) { Get-AVDTuneSiteAccessHolders $back.Body })
                $roles = @(if ($back.Status -ge 200 -and $back.Status -le 299) { @(Get-AVDTuneProp $back.Body 'roles') | Where-Object { $_ -is [string] } })
                if ($back.Status -lt 200 -or $back.Status -gt 299) { $problem = 'The permission was sent, but it could not be read back: ' + (Get-AVDTuneSiteAccessFailure 'read the new permission' $back) }
                elseif ($holders.Count -ne 1 -or $holders[0] -ne $plan.ClientId -or $roles -cnotcontains $plan.Role) { $problem = "The permission was sent, but the site does not list AVDTune's app registration with the role $($plan.Role) for it when read back. Check the permissions of the site." }
            }
        }
        $entry.PermissionId = $permId
        $entry.Status = $(if ($problem) { 'Failed' } else { 'Done' }); $entry.Message = $problem
        Save-AVDTuneSiteAccessJournal $Root $journal
        if ($problem) { return (& $out 'Failed' $problem $permId $signIn.Account) }
        if ($state.ImageVersion) { [void](Add-AVDTuneChangeLogEntry -Root $Root -Version $state.ImageVersion -Category 'Azure' -Component 'SharePoint: site access' -ChangeType 'Added' -Text "Role $($plan.Role) on the SharePoint site $($plan.SiteUrl) granted to AVDTune's app registration $($plan.ClientId) (Sites.Selected)" -User $User -SnapshotId $SnapshotId -RunId $runId -Source Step) }
        & $out 'Changed' "AVDTune's app registration holds the role $($plan.Role) on $($plan.SiteUrl), confirmed by reading the permission back." $permId $signIn.Account
    }
    finally { $token = $null }
}

#endregion

#region undo

function Get-AVDTuneSiteAccessUndoPlan {
    <# Pure, from the journal only: Delete = a grant of AVDTune that is Done, has its permission id and site id and was not taken back; Keep (with the reason) = anything else that passes the entry check. Entries that fail the check produce no step. Returns Steps, Count and Hash. #>
    param([string]$Root = (Get-AVDTuneRoot))
    $steps = New-Object System.Collections.ArrayList
    $grants = @((Get-AVDTuneSiteAccessJournal -Root $Root).Grants)
    for ($i = $grants.Count - 1; $i -ge 0; $i--) {
        $g = ConvertTo-AVDTuneSiteAccessGrant $grants[$i]
        if (-not $g -or $g.Undone) { continue }
        $title = "Role $($g.Role) of the app registration $($g.ClientId) on $($g.SiteUrl)"
        $action = 'Delete'; $reason = 'Granted by AVDTune; the permission is read again before it is removed.'
        if ($g.Status -eq 'Started') { $action = 'Keep'; $reason = 'The grant was interrupted before its result was written: AVDTune does not know which permission is its own. Check the permissions of the site.' }
        elseif ($g.Status -eq 'Failed') { $action = 'Keep'; $reason = 'The grant failed or could not be confirmed: nothing AVDTune may remove.' }
        elseif (-not $g.PermissionId -or -not $g.SiteId) { $action = 'Keep'; $reason = 'No permission id was recorded: AVDTune cannot tell its permission from another one.' }
        [void]$steps.Add([pscustomobject]@{ Index = $i; Id = "sp.access.$i"; Action = $action; Title = $title; Reason = $reason; SiteUrl = $g.SiteUrl; SiteId = $g.SiteId; ClientId = $g.ClientId; Role = $g.Role; PermissionId = $g.PermissionId })
    }
    $hash = Get-AVDTuneSiteAccessHash ((@('site-access-undo', '1') + @($steps | ForEach-Object { "$($_.Index)|$($_.Action)|$($_.SiteId)|$($_.ClientId)|$($_.PermissionId)" })) -join "`n")
    [pscustomobject]@{ Steps = @($steps); Count = @($steps | Where-Object Action -eq 'Delete').Count; Hash = $hash }
}

function Revoke-AVDTuneSiteAccess {
    <#
        Takes back the grants the undo plan lists (after the confirmation of its hash; same gate rules as the grant, no LastChange). Per grant: the permission is read
        (404: it is gone already, marked as taken back); it is removed only when it still names exactly the recorded app registration, otherwise it stays with the reason.
        Returns Status (Reverted | Unchanged | Refused | Failed), Message, Results.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Auth, [string]$Root = (Get-AVDTuneRoot), [string]$TenantId, [string]$ConfirmedHash, [string]$LoginHint, [string]$TempRoot, [string]$User, [string]$SnapshotId)
    Assert-AVDTuneNotSealed -Root $Root
    if (-not (Test-AVDTuneWriteAllowed)) { throw 'The snapshot gate is not confirmed: AVDTune is read only until a snapshot newer than its last change is confirmed on the Overview.' }
    $plan = Get-AVDTuneSiteAccessUndoPlan -Root $Root
    if (-not $ConfirmedHash -or $plan.Hash -cne $ConfirmedHash) { return [pscustomobject]@{ Status = 'Refused'; Message = 'The undo plan differs from the one that was confirmed (or nothing was confirmed). Nothing was changed.'; Results = @() } }
    $todo = @($plan.Steps | Where-Object Action -eq 'Delete')
    if ($todo.Count -eq 0) { return [pscustomobject]@{ Status = 'Unchanged'; Message = 'There is no site permission AVDTune may take back.'; Results = @() } }
    $TenantId = ([string]$TenantId).Trim().ToLowerInvariant()
    if (-not (Test-AVDTuneSiteAccessText $TenantId $script:GuidPattern)) { return [pscustomobject]@{ Status = 'Refused'; Message = 'The tenant of this environment is not known yet: sign in on the Overview first.'; Results = @() } }
    if ($LoginHint -and -not (Get-AVDTuneAccountDomain $LoginHint)) { $LoginHint = '' }
    $token = $null
    $results = New-Object System.Collections.ArrayList
    try {
        $token = (Get-AVDTuneSiteAccessToken -Auth $Auth -TenantId $TenantId -LoginHint $LoginHint -TempRoot $TempRoot).Token
        $state = Get-AVDTuneState $Root
        $journal = Get-AVDTuneSiteAccessJournal -Root $Root
        $stopped = $false
        foreach ($s in $todo) {
            if ($stopped) { [void]$results.Add([pscustomobject]@{ Id = $s.Id; Title = $s.Title; Status = 'Skipped'; Message = 'An earlier step failed.' }); continue }
            $path = "/v1.0/sites/$($s.SiteId)/permissions/$($s.PermissionId)"
            $now = Invoke-AVDTuneSiteAccessGraph -Auth $Auth -Token $token -Method GET -Path $path
            $gone = ($now.Status -eq 404)
            if (-not $gone) {
                if ($now.Status -lt 200 -or $now.Status -gt 299) { $stopped = $true; [void]$results.Add([pscustomobject]@{ Id = $s.Id; Title = $s.Title; Status = 'Failed'; Message = (Get-AVDTuneSiteAccessFailure 'read the permission' $now) }); continue }
                $holders = @(Get-AVDTuneSiteAccessHolders $now.Body)
                if ($holders.Count -ne 1 -or $holders[0] -ne $s.ClientId) { [void]$results.Add([pscustomobject]@{ Id = $s.Id; Title = $s.Title; Status = 'Unchanged'; Message = "The permission does not name only AVDTune's app registration any more: it stays." }); continue }
                $del = Invoke-AVDTuneSiteAccessGraph -Auth $Auth -Token $token -Method DELETE -Path $path
                if ($del.Status -ne 404 -and ($del.Status -lt 200 -or $del.Status -gt 299)) { $stopped = $true; [void]$results.Add([pscustomobject]@{ Id = $s.Id; Title = $s.Title; Status = 'Failed'; Message = (Get-AVDTuneSiteAccessFailure 'remove the site permission' $del) }); continue }
            }
            $entry = @($journal.Grants)[$s.Index]
            if ($entry -and [string](Get-AVDTuneProp $entry 'PermissionId') -ceq $s.PermissionId) { $entry | Add-Member -NotePropertyName Undone -NotePropertyValue $true -Force }
            Save-AVDTuneSiteAccessJournal $Root $journal
            [void]$results.Add([pscustomobject]@{ Id = $s.Id; Title = $s.Title; Status = 'Reverted'; Message = $(if ($gone) { 'The permission was gone already.' } else { '' }) })
            if ($state.ImageVersion) { [void](Add-AVDTuneChangeLogEntry -Root $Root -Version $state.ImageVersion -Category 'Azure' -Component 'SharePoint: site access' -ChangeType 'Removed' -Text "Undo: $($s.Title)$(if ($gone) { ' (it was gone already)' })" -User $User -SnapshotId $SnapshotId -Source Step) }
        }
    }
    finally { $token = $null }
    $failed = @($results | Where-Object Status -eq 'Failed').Count -gt 0
    $reverted = @($results | Where-Object Status -eq 'Reverted').Count
    [pscustomobject]@{
        Status = $(if ($failed) { 'Failed' } elseif ($reverted -gt 0) { 'Reverted' } else { 'Unchanged' })
        Message = $(if ($failed) { 'Stopped at the first failure: ' + (@($results | Where-Object Status -eq 'Failed')[0].Message) } elseif ($reverted -gt 0) { "Taken back: $reverted site permission(s)." } else { (@($results | ForEach-Object { $_.Message }) -join ' ') })
        Results = @($results)
    }
}

#endregion

#region the state for the readiness analysis

function Get-AVDTuneSiteAccessState {
    <#
        Read only, with the Sites token of the daily sign-in (-Context: a context of AVDTune.SharePoint.psm1). State:
          NoSite       no site is set (nothing to check)
          NotSignedIn  no token: not checkable (-NoTokenReason)
          Missing      Graph answers 401 or 403 to the read of the site: the app registration has no role on it
          Granted      the site can be read and AVDTune's journal has its own grant of write for this site and registration
          Readable     the site can be read; whether the role allows writing cannot be read with Sites.Selected (granted outside AVDTune)
          Unknown      the read failed for another reason (network, throttling): Detail says why
    #>
    param([string]$Root = (Get-AVDTuneRoot), $Context, [string]$ClientId, [string]$NoTokenReason)
    $site = [string](Get-AVDTuneSpSettings -Root $Root).SiteUrl
    $r = { param($State, $Detail) [pscustomobject]@{ SiteUrl = $site; State = $State; Detail = [string]$Detail } }
    if (-not $site) { return (& $r 'NoSite' '') }
    if (-not $Context -or -not $Context.Token) { return (& $r 'NotSignedIn' $NoTokenReason) }
    if ($Context.SiteUrl -ine $site) { return (& $r 'Unknown' 'The context is for another site.') }
    try { [void](Resolve-AVDTuneSpSite $Context) }
    catch {
        $m = [string]$_.Exception.Message
        if ($m -match 'answered 40[13]\b') { return (& $r 'Missing' '') }
        return (& $r 'Unknown' (Remove-AVDTuneControlCharacters (Protect-AVDTuneSpText $m 200) 200))
    }
    $ClientId = ([string]$ClientId).Trim().ToLowerInvariant()
    $own = @((Get-AVDTuneSiteAccessJournal -Root $Root).Grants | ForEach-Object { ConvertTo-AVDTuneSiteAccessGrant $_ } | Where-Object { $_ -and $_.Status -eq 'Done' -and -not $_.Undone -and $_.SiteUrl -ieq $site -and $_.ClientId -eq $ClientId })
    if ($own.Count -gt 0) { return (& $r 'Granted' '') }
    & $r 'Readable' ''
}

#endregion

Export-ModuleMember -Function Get-AVDTuneSiteAccessConsentNote, Get-AVDTuneSiteAccessJournalPath, Get-AVDTuneSiteAccessJournal, ConvertTo-AVDTuneSiteAccessGrant, Get-AVDTuneSiteAccessHolders, Get-AVDTuneSiteAccessPlan, Grant-AVDTuneSiteAccess,
    Get-AVDTuneSiteAccessUndoPlan, Revoke-AVDTuneSiteAccess, Get-AVDTuneSiteAccessState
