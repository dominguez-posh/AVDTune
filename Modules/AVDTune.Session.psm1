<#
    AVDTune sign-in session: one Microsoft sign-in, three token audiences, tokens in memory only.

      Graph   Microsoft Graph, read only (Entra groups, Intune app notes for the package trust anchor)
      Sites   Microsoft Graph, Sites.Selected (the SharePoint site of the environment / package store)
      Arm     Azure Resource Manager (snapshot of the OS disk, VM size and region), delegated user_impersonation

    The interactive sign-in is the normal Microsoft sign-in of the shared module (Shared\Modules\PackTune.SignIn.psm1: Invoke-PackTuneBrowserSignIn,
    embedded sign-in window, authorization code with PKCE; the administrator signs in himself). Keevault is not used (user decision
    2026-11-15): no Keevault function is called and no password is filled in. The sign-in returns one refresh token; every audience gets
    its own access token from it (Request-PackTuneToken, grant refresh_token).
    Limit: Microsoft's v2 tokens carry ALL consented scopes of their resource, so the Graph and the Sites token both carry Group.Read.All,
    DeviceManagementApps.Read.All and Sites.Selected; the separation is by resource (Graph versus Azure Resource Manager), not by scope.
    A token with a scope beyond what AVDTune asks for on its resource is kept but named in Warnings (session info, protocol).
    Nothing here is written to disk: access and refresh tokens are SecureStrings in this process. Disconnect-AVDTuneSession removes them
    and the temporary profiles of the sign-in window (PackTuneSignIn-* in %TEMP%); Test-AVDTuneSessionClear proves both (before Finish).

    The tenant comes from the sign-in (issue #11): without a saved tenant the sign-in goes to the tenant found for the account's domain
    (OpenID discovery, Resolve-AVDTuneTenantFromDomain) or to 'organizations', and the tid of the token is the tenant. With a saved tenant
    the token must carry that tid. Without a client ID AVDTune creates its own app registration 'AVDTune' (Install-AVDTuneAppRegistration):
    a setup sign-in through Microsoft's public client 'Microsoft Graph Command Line Tools' at 'organizations' (its tid is the tenant),
    then Microsoft Graph creates or updates the registration, its service principal and the admin consent.

    The identity provider is an adapter ($Auth): SignIn (tenant, client, scopes, login hint), Refresh, Discover (OpenID configuration of
    a domain on login.microsoftonline.com) and Graph (calls to https://graph.microsoft.com/v1.0 for the setup). New-AVDTuneAuthAdapter is
    the real one, Tests\Fakes\FakeServices.ps1 has the fake. Without changes to the shared module (nothing here edits Shared\).
#>

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'AVDTune.psm1')
Import-Module (Join-Path $PSScriptRoot 'AVDTune.Trust.psm1')

$script:GraphResource = 'https://graph.microsoft.com'
$script:ArmResource = 'https://management.azure.com'
# Microsoft's "Microsoft Graph Command Line Tools" app is for the setup of the app registration only, never for the tool itself (same rule as PackTune)
$script:SetupClientId = '14d82eec-204b-4c2f-b7e8-296a70dab67e'
# What the setup sign-in asks for: only for creating the app registration and its admin consent, never for the daily work
$script:SetupScopes = @('Application.ReadWrite.All', 'DelegatedPermissionGrant.ReadWrite.All', 'User.Read')
$script:GraphAppId = '00000003-0000-0000-c000-000000000000'
$script:ArmAppId = '797f4846-ba00-4fd7-ba43-dac1f8f63013'   # Windows Azure Service Management API
$script:AppName = 'AVDTune'
$script:AppTag = 'AVDTune'
$script:AppNote = 'Created by AVDTune for its own sign-in (public client, http://localhost, delegated permissions only). Not used by PackTune.'
# Delegated permissions of AVDTune's own registration per resource (openid and profile: the shared sign-in asks for them every time)
$script:AppPermissions = [ordered]@{
    '00000003-0000-0000-c000-000000000000' = @('Group.Read.All', 'DeviceManagementApps.Read.All', 'Sites.Selected', 'offline_access', 'openid', 'profile')
    '797f4846-ba00-4fd7-ba43-dac1f8f63013' = @('user_impersonation')
}
$script:SetupConsentNote = "The consent for Application.ReadWrite.All and DelegatedPermissionGrant.ReadWrite.All that the setup sign-in gives Microsoft's app 'Microsoft Graph Command Line Tools' stays in the tenant afterwards; AVDTune used it only to create its own app registration. Remove it when it is not needed any more: Entra admin center > Enterprise applications > Microsoft Graph Command Line Tools > Permissions (Admin consent and User consent) > Revoke, or with Microsoft Graph PowerShell remove its oauth2PermissionGrant (Remove-MgOauth2PermissionGrant) or take these two permissions out of its scope (Update-MgOauth2PermissionGrant)."
$script:RoleText = 'Creating the app registration needs the role Application Administrator or Cloud Application Administrator; the admin consent for Microsoft Graph needs Privileged Role Administrator (or Global Administrator).'

function Get-AVDTuneSetupConsentNote { $script:SetupConsentNote }

$script:Audiences = [ordered]@{
    Graph = @{ Scopes = @('Group.Read.All', 'DeviceManagementApps.Read.All'); Resource = $script:GraphResource; Purpose = 'Microsoft Graph (read: groups, Intune app notes)' }
    Sites = @{ Scopes = @('Sites.Selected'); Resource = $script:GraphResource; Purpose = 'SharePoint site of the environment (Sites.Selected)' }
    Arm   = @{ Scopes = @('user_impersonation'); Resource = $script:ArmResource; Purpose = 'Azure Resource Manager (snapshot, VM size, region)' }
}

function Get-AVDTuneAudience { $script:Audiences }

function Get-AVDTuneAudienceScopeUrls([string]$Audience) {
    $a = $script:Audiences[$Audience]
    @($a.Scopes | ForEach-Object { "$($a.Resource)/$_" })
}

function Get-AVDTuneExpectedScopes([string]$Audience) {
    # What a v2 token of this audience may carry: every scope AVDTune asks for on the same resource (a token holds all consented scopes of its resource)
    $resource = $script:Audiences[$Audience].Resource
    @($script:Audiences.Values | Where-Object { $_.Resource -eq $resource } | ForEach-Object { $_.Scopes } | Sort-Object -Unique)
}

#region secure strings, claims

function ConvertTo-AVDTuneSecure([string]$Text) {
    $s = New-Object System.Security.SecureString
    foreach ($c in $Text.ToCharArray()) { $s.AppendChar($c) }
    $s.MakeReadOnly()
    $s
}

function ConvertFrom-AVDTuneSecure([System.Security.SecureString]$Secure) {
    # Only for the moment of a request; the plain text is not kept
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Get-AVDTuneTokenClaims([string]$AccessToken) {
    # The claims of a JWT (not verified here: they only describe the token for display and for the tenant/scope checks; the resource verifies it)
    $parts = $AccessToken.Split('.')
    if ($parts.Count -lt 2) { throw 'The token is not a JWT.' }
    $payload = $parts[1].Replace('-', '+').Replace('_', '/')
    $payload = $payload.PadRight($payload.Length + (4 - $payload.Length % 4) % 4, '=')
    [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
}

#endregion

#region errors

function ConvertTo-AVDTuneAuthError {
    # Readable text for the failures of a sign-in; never includes a token
    param([string]$Message, [string]$Audience)
    $m = [string]$Message
    if ($m -match 'remote name could not be resolved|unable to connect|timed out|timeout|No such host|network|actively refused|connection.*(closed|reset)') {
        return 'No connection to Microsoft sign-in. Check the network and the proxy, then try again.'
    }
    if ($m -match 'AADSTS(65001|70011|90094|90008|650056)|consent|admin approval|administrator must') {
        $need = if ($Audience) { " (audience ${Audience}: " + ((Get-AVDTuneAudienceScopeUrls $Audience) -join ', ') + ')' } else { '' }
        return "The app registration has no consent for this permission$need. An administrator must grant it: docs\start-sequence.md lists the permissions."
    }
    if ($m -match 'AADSTS50076|AADSTS50079|AADSTS53003|AADSTS50158') { return 'Conditional Access or multi-factor authentication blocks this sign-in. Sign in again and complete the request.' }
    if ($m -match 'AADSTS700016|AADSTS70001') { return 'The app registration (client ID) was not found in this tenant. Check the client ID in the first-run questions; a registration that was just created can take a minute until the sign-in finds it.' }
    if ($m -match 'AADSTS50194') { return "The app registration is limited to its own tenant, so AVDTune cannot sign in through 'organizations'. Enter your account (name@domain) in the sign-in step so AVDTune finds the tenant, or leave the client ID in the first-run questions empty so AVDTune creates its own app registration." }
    if ($m -match 'AADSTS90002|AADSTS50128|AADSTS50059') { return 'Microsoft knows no tenant for this account or domain. Check the account (name@domain).' }
    if ($m -match 'cancel') { return 'Sign-in cancelled.' }
    $m
}

#endregion

#region session

function New-AVDTuneSession {
    # Empty session; Connect-AVDTuneSession fills it
    # TempRoot: where the sign-in window leaves its temporary profiles (the temp folder of this user; a test folder in the checks)
    param([Parameter(Mandatory)]$Auth, [string]$TempRoot = [IO.Path]::GetTempPath())
    [pscustomobject]@{ Auth = $Auth; TempRoot = $TempRoot; TenantId = ''; ClientId = ''; Account = ''; Name = ''; Tokens = @{}; Refresh = $null; Connected = $false; Warnings = @() }
}

function Set-AVDTuneSessionToken($Session, [string]$Audience, $Response) {
    $access = [string](Get-AVDTuneProp $Response 'access_token')
    if (-not $access) { throw "The sign-in returned no access token for $Audience." }
    $claims = Get-AVDTuneTokenClaims $access
    $expires = (Get-Date).AddSeconds([int](Get-AVDTuneProp $Response 'expires_in')).ToUniversalTime()
    $scopes = @(([string](Get-AVDTuneProp $claims 'scp')) -split ' ' | Where-Object { $_ })
    $old = $Session.Tokens[$Audience]
    if ($old -and $old.Access) { $old.Access.Dispose() }
    $Session.Tokens[$Audience] = @{
        Access = (ConvertTo-AVDTuneSecure $access); ExpiresOn = $expires; Scopes = $scopes; Audience = [string](Get-AVDTuneProp $claims 'aud')
    }
    $refresh = [string](Get-AVDTuneProp $Response 'refresh_token')
    if ($refresh) { if ($Session.Refresh) { $Session.Refresh.Dispose() }; $Session.Refresh = ConvertTo-AVDTuneSecure $refresh }
    $claims
}

function Assert-AVDTuneTokenClaims {
    # What a token must say before it is kept: right audience, the scopes of its purpose, the expected tenant. Returns the scopes beyond
    # what AVDTune asks for on this resource (kept, because Microsoft adds every consented scope, but reported as a warning).
    param($Claims, [string]$Audience, [string]$TenantId)
    $a = $script:Audiences[$Audience]
    $aud = [string](Get-AVDTuneProp $Claims 'aud')
    $okAud = if ($a.Resource -eq $script:GraphResource) { $aud -in @($script:GraphResource, '00000003-0000-0000-c000-000000000000') } else { $aud -like "$($a.Resource)*" }
    if (-not $okAud) { throw "The token for $Audience is for another resource ($aud)." }
    $have = @(([string](Get-AVDTuneProp $Claims 'scp')) -split ' ' | Where-Object { $_ })
    foreach ($need in $a.Scopes) { if ($need -notin $have) { throw "The token for $Audience lacks the permission $need (granted: $($have -join ', '))." } }
    $tid = ([string](Get-AVDTuneProp $Claims 'tid')).ToLowerInvariant()
    if ($TenantId -match '^[0-9a-fA-F-]{36}$' -and $tid -ne $TenantId.ToLowerInvariant()) { throw (Get-AVDTuneTenantMismatchText $TenantId $tid) }
    $expected = @(Get-AVDTuneExpectedScopes $Audience)
    @($have | Where-Object { $_ -notin $expected })
}

function Get-AVDTuneScopeWarning([string]$Audience, [string[]]$Extra) {
    "The $Audience token carries permissions AVDTune does not ask for: $($Extra -join ', '). Check the API permissions of the app registration."
}

function Get-AVDTuneTenantMismatchText([string]$Expected, [string]$Actual) {
    "The account signed in to tenant $Actual, but this environment belongs to tenant $Expected. Sign in with an account of that tenant, or change the first-run questions (Change > forget the saved tenant; the next sign-in sets it again)."
}

function Test-AVDTuneTenantGuid([string]$Text) { $Text -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' }

function Get-AVDTuneAccountDomain {
    # The domain of an account (name@domain), lower case; $null when the account or the domain is not valid
    param([string]$Account)
    $a = ([string]$Account).Trim()
    if ($a -notmatch '^[^@\s"<>\\/]{1,64}@([^@\s]+)$') { return $null }
    $d = $Matches[1].ToLowerInvariant()
    if (-not (Test-AVDTuneDomainName $d)) { return $null }
    $d
}

function Test-AVDTuneDomainName {
    # Strict DNS name: labels of letters, digits and inner hyphens, at least two labels, a top-level label of letters; nothing else
    # (no IP address, no port, no path, no percent sign), at most 253 characters
    param([string]$Domain)
    if (-not $Domain -or $Domain.Length -gt 253) { return $false }
    $Domain -cmatch '^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$'
}

function Connect-AVDTuneSession {
    <#
        Signs in (adapter SignIn, interactive), then fetches the token of every audience from the refresh token. Returns a summary without
        any token (Get-AVDTuneSessionInfo). Throws readable text; on any failure the session is cleared again.
        TenantId: the saved tenant (GUID or, from an older environment.json, a domain) or empty. Empty: the sign-in goes to 'organizations'
        (only a multi-tenant registration can do that). The tenant of the session is always the tid of the token (Session.TenantId); with
        a saved GUID the tid must be the same. LoginHint: the account, filled in on Microsoft's page.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session, [string]$TenantId, [Parameter(Mandatory)][string]$ClientId, [string]$LoginHint)
    $TenantId = ([string]$TenantId).Trim()
    if ($TenantId -and -not (Test-AVDTuneTenantGuid $TenantId) -and -not (Test-AVDTuneDomainName $TenantId.ToLowerInvariant())) { throw 'The saved tenant is neither a tenant ID nor a domain name (first-run questions).' }
    if ($ClientId -notmatch '^[0-9a-fA-F-]{36}$') { throw 'The client ID of the app registration is not set or not a GUID (first-run questions).' }
    if ($ClientId -ieq $script:SetupClientId) { throw "Microsoft's setup app is not allowed for AVDTune. Use the client ID of AVDTune's own app registration." }
    if ($LoginHint -and -not (Get-AVDTuneAccountDomain $LoginHint)) { throw 'The account must look like name@domain.' }
    Disconnect-AVDTuneSession $Session
    $authority = if ($TenantId) { $TenantId } else { 'organizations' }
    $Session.TenantId = $TenantId; $Session.ClientId = $ClientId
    $current = ''
    try {
        $current = 'sign-in'
        # One interactive sign-in for all Graph scopes of both Graph audiences; the answer is only used for its refresh token
        $scopes = @((Get-AVDTuneAudienceScopeUrls 'Graph') + (Get-AVDTuneAudienceScopeUrls 'Sites'))
        try { $first = & $Session.Auth.SignIn $authority $ClientId $scopes ([string]$LoginHint) }
        finally { [void](Remove-AVDTuneSignInLeftovers -TempRoot $Session.TempRoot) }
        $firstAccess = [string](Get-AVDTuneProp $first 'access_token')
        if (-not $firstAccess -or -not [string](Get-AVDTuneProp $first 'refresh_token')) { throw 'The sign-in returned no refresh token (offline_access missing).' }
        $claims = Get-AVDTuneTokenClaims $firstAccess
        # The tenant of the sign-in is the tid of the token; a saved tenant ID must be the same
        $tid = ([string](Get-AVDTuneProp $claims 'tid')).ToLowerInvariant()
        if (-not (Test-AVDTuneTenantGuid $tid)) { throw 'The token of the sign-in names no tenant (tid).' }
        if ((Test-AVDTuneTenantGuid $TenantId) -and $tid -ne $TenantId.ToLowerInvariant()) { throw (Get-AVDTuneTenantMismatchText $TenantId $tid) }
        $Session.TenantId = $tid
        $Session.Account = [string]$(if (Get-AVDTuneProp $claims 'upn') { $claims.upn } else { Get-AVDTuneProp $claims 'preferred_username' })
        $Session.Name = [string](Get-AVDTuneProp $claims 'name')
        $Session.Refresh = ConvertTo-AVDTuneSecure ([string]$first.refresh_token)
        $first = $null
        $warnings = New-Object System.Collections.ArrayList
        foreach ($audience in $script:Audiences.Keys) {
            $current = $audience
            $urls = @(Get-AVDTuneAudienceScopeUrls $audience)
            $response = & $Session.Auth.Refresh $tid $ClientId (ConvertFrom-AVDTuneSecure $Session.Refresh) $urls
            $c = Set-AVDTuneSessionToken $Session $audience $response
            $extra = @(Assert-AVDTuneTokenClaims -Claims $c -Audience $audience -TenantId $tid)
            if ($extra.Count -gt 0) { [void]$warnings.Add((Get-AVDTuneScopeWarning $audience $extra)) }
        }
        $Session.Warnings = @($warnings)
        $Session.Connected = $true
        Get-AVDTuneSessionInfo $Session
    }
    catch {
        $text = ConvertTo-AVDTuneAuthError -Message $_.Exception.Message -Audience $(if ($current -in $script:Audiences.Keys) { $current } else { $null })
        Disconnect-AVDTuneSession $Session
        $Session.TenantId = $TenantId
        throw $text
    }
}

function Get-AVDTuneAccessToken {
    # The plain access token of an audience, for one request. Refreshed when it expires within 3 minutes.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][ValidateSet('Graph', 'Sites', 'Arm')][string]$Audience)
    $t = $Session.Tokens[$Audience]
    if (-not $Session.Connected -or -not $t) { throw "Not signed in (no $Audience token). Sign in first on the Overview." }
    if ($t.ExpiresOn -lt (Get-Date).ToUniversalTime().AddMinutes(3)) {
        try {
            $urls = @(Get-AVDTuneAudienceScopeUrls $Audience)
            $response = & $Session.Auth.Refresh $Session.TenantId $Session.ClientId (ConvertFrom-AVDTuneSecure $Session.Refresh) $urls
            $c = Set-AVDTuneSessionToken $Session $Audience $response
            $extra = @(Assert-AVDTuneTokenClaims -Claims $c -Audience $Audience -TenantId $Session.TenantId)
            if ($extra.Count -gt 0) { $Session.Warnings = @(@($Session.Warnings) + (Get-AVDTuneScopeWarning $Audience $extra) | Select-Object -Unique) }
        }
        catch { throw (ConvertTo-AVDTuneAuthError -Message $_.Exception.Message -Audience $Audience) }
        $t = $Session.Tokens[$Audience]
    }
    ConvertFrom-AVDTuneSecure $t.Access
}

function Get-AVDTuneSessionInfo {
    # What may be shown and logged: account, tenant, audiences with scopes and expiry. Never a token.
    param([Parameter(Mandatory)]$Session)
    [pscustomobject]@{
        Connected = [bool]$Session.Connected; Account = $Session.Account; Name = $Session.Name; TenantId = $Session.TenantId; Warnings = @($Session.Warnings)
        Audiences = @($script:Audiences.Keys | Where-Object { $Session.Tokens[$_] } | ForEach-Object {
                $t = $Session.Tokens[$_]
                [pscustomobject]@{ Audience = $_; Purpose = $script:Audiences[$_].Purpose; Scopes = @($t.Scopes); ExpiresOn = $t.ExpiresOn.ToString('o') }
            })
    }
}

function Disconnect-AVDTuneSession {
    # Removes every token from memory (SecureStrings disposed, tables emptied) and the temporary profiles of the sign-in window
    param([Parameter(Mandatory)]$Session)
    foreach ($key in @($Session.Tokens.Keys)) { $t = $Session.Tokens[$key]; if ($t -and $t.Access) { $t.Access.Dispose() } }
    $Session.Tokens.Clear()
    if ($Session.Refresh) { $Session.Refresh.Dispose() }
    $Session.Refresh = $null; $Session.Connected = $false; $Session.Account = ''; $Session.Name = ''; $Session.Warnings = @()
    [void](Remove-AVDTuneSignInLeftovers -TempRoot $Session.TempRoot)
}

function Test-AVDTuneSessionClear {
    # True when no token is held and no profile of the sign-in window is left (checked before Finish / "Abschliessen")
    param([Parameter(Mandatory)]$Session)
    ($Session.Tokens.Count -eq 0) -and ($null -eq $Session.Refresh) -and (-not $Session.Connected) -and (@(Get-AVDTuneSignInLeftovers -TempRoot $Session.TempRoot).Count -eq 0)
}

#endregion

#region profiles of the sign-in window

function Get-AVDTuneSignInLeftovers {
    # The temporary WebView2 profiles of the shared sign-in window (PackTuneSignIn-<guid>) in a temp folder; they hold Microsoft cookies
    param([string]$TempRoot = [IO.Path]::GetTempPath())
    if (-not $TempRoot -or -not (Test-Path -LiteralPath $TempRoot)) { return @() }
    @(Get-ChildItem -LiteralPath $TempRoot -Directory -Force -Filter 'PackTuneSignIn-*' -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^PackTuneSignIn-[0-9a-f]{32}$' } | ForEach-Object { $_.FullName })
}

function Remove-AVDTuneSignInLeftovers {
    <# Deletes those profiles with retries (the browser process may hold files for a moment). Returns the folders that are still there. #>
    param([string]$TempRoot = [IO.Path]::GetTempPath(), [int]$Tries = 10, [int]$DelayMilliseconds = 300)
    for ($i = 0; $i -lt $Tries; $i++) {
        $left = @(Get-AVDTuneSignInLeftovers -TempRoot $TempRoot)
        if ($left.Count -eq 0) { return @() }
        foreach ($folder in $left) { try { Remove-AVDTuneFolderNoFollow $folder } catch { } }
        if (@(Get-AVDTuneSignInLeftovers -TempRoot $TempRoot).Count -gt 0 -and $DelayMilliseconds -gt 0) { Start-Sleep -Milliseconds $DelayMilliseconds }
    }
    @(Get-AVDTuneSignInLeftovers -TempRoot $TempRoot)
}

#endregion

#region tenant discovery

function Resolve-AVDTuneTenantFromDomain {
    <#
        The tenant ID of a domain from Microsoft's OpenID configuration (adapter Discover: GET
        https://login.microsoftonline.com/<domain>/v2.0/.well-known/openid-configuration). The tenant is the GUID in 'issuer'; an issuer that
        is not https://login.microsoftonline.com/<guid>/v2.0 is refused. Throws readable text.
    #>
    param([Parameter(Mandatory)]$Auth, [Parameter(Mandatory)][AllowEmptyString()][string]$Domain)
    $d = ([string]$Domain).Trim().ToLowerInvariant()
    if (-not (Test-AVDTuneDomainName $d)) { throw "'$(Remove-AVDTuneControlCharacters $Domain 80)' is not a valid domain name." }
    $r = & $Auth.Discover $d
    $status = [int](Get-AVDTuneProp $r 'Status')
    if ($status -eq 0) { throw "No connection to Microsoft sign-in (tenant of $d). Check the network and the proxy, then try again." }
    if ($status -eq 400 -or $status -eq 404) { throw "Microsoft knows no tenant for the domain $d. Check the account (name@domain)." }
    if ($status -ne 200) { throw "Microsoft sign-in answered $status for the tenant of $d." }
    $issuer = [string](Get-AVDTuneProp (Get-AVDTuneProp $r 'Body') 'issuer')
    if ($issuer -notmatch '^https://login\.microsoftonline\.com/([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})/v2\.0$') { throw "The OpenID configuration of $d names no tenant AVDTune accepts." }
    $Matches[1].ToLowerInvariant()
}

#endregion

#region own app registration

function Invoke-AVDTuneSetupGraph {
    # One Graph call of the setup through the adapter; throws readable text (403: the missing role), never the token
    param($Auth, [string]$Token, [string]$Method, [string]$Path, $Body, [string]$Step)
    $r = & $Auth.Graph $Method $Path $Token $Body
    $status = [int](Get-AVDTuneProp $r 'Status')
    if ($status -ge 200 -and $status -lt 300) { return (Get-AVDTuneProp $r 'Body') }
    $detail = [string](Get-AVDTuneProp (Get-AVDTuneProp (Get-AVDTuneProp $r 'Body') 'error') 'message')
    if (-not $detail) { $detail = [string](Get-AVDTuneProp $r 'Error') }
    $detail = Remove-AVDTuneControlCharacters $detail 300
    if ($status -eq 0) { throw "No connection to Microsoft Graph ($Step). Check the network and the proxy, then try again." }
    if ($status -eq 401 -or $status -eq 403) { throw "Your account may not do this: $Step (Microsoft Graph answered $status$(if ($detail) { ": $detail" })). $script:RoleText" }
    throw "Microsoft Graph refused: $Step ($status$(if ($detail) { ": $detail" }))."
}

function Get-AVDTuneGraphFilterPath([string]$Collection, [string]$Filter, [string]$Select) {
    "/v1.0/$Collection`?`$filter=" + [Uri]::EscapeDataString($Filter) + $(if ($Select) { "&`$select=$Select" } else { '' })
}

function Install-AVDTuneAppRegistration {
    <#
        Creates (or finds and updates) AVDTune's own app registration 'AVDTune' in the tenant of the administrator and grants the admin
        consent. Setup sign-in: Microsoft's public client 'Microsoft Graph Command Line Tools' at 'organizations' (or the saved tenant) with
        Application.ReadWrite.All and DelegatedPermissionGrant.ReadWrite.All; the tid of that token is the tenant. Then through Graph:
        registration (public client, redirect http://localhost, tag and note 'AVDTune', delegated permissions of $script:AppPermissions,
        single tenant), service principal, oauth2PermissionGrant AllPrincipals per resource. A registration found by name is reused only
        when it carries the tag, the redirect and the signed-in account is its only owner (anyone may name an app 'AVDTune').
        No secret, no certificate. The setup token is dropped at the end. Returns TenantId (GUID), ClientId, Account, Created, Notes.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Auth, [string]$TenantId, [string]$LoginHint, [string]$TempRoot = [IO.Path]::GetTempPath(), [int]$RetryDelaySeconds = 5)
    $TenantId = ([string]$TenantId).Trim()
    if ($LoginHint -and -not (Get-AVDTuneAccountDomain $LoginHint)) { throw 'The account must look like name@domain.' }
    $notes = New-Object System.Collections.ArrayList
    $setupUrls = @($script:SetupScopes | ForEach-Object { "$script:GraphResource/$_" })
    try { $answer = & $Auth.SignIn $(if ($TenantId) { $TenantId } else { 'organizations' }) $script:SetupClientId $setupUrls ([string]$LoginHint) }
    catch { throw ('Setup sign-in (Microsoft Graph Command Line Tools): ' + (ConvertTo-AVDTuneAuthError -Message $_.Exception.Message)) }
    finally { [void](Remove-AVDTuneSignInLeftovers -TempRoot $TempRoot) }
    $token = [string](Get-AVDTuneProp $answer 'access_token'); $answer = $null
    if (-not $token) { throw 'The setup sign-in returned no access token.' }
    try {
        $claims = Get-AVDTuneTokenClaims $token
        $tid = ([string](Get-AVDTuneProp $claims 'tid')).ToLowerInvariant()
        if (-not (Test-AVDTuneTenantGuid $tid)) { throw 'The token of the setup sign-in names no tenant (tid).' }
        if ((Test-AVDTuneTenantGuid $TenantId) -and $tid -ne $TenantId.ToLowerInvariant()) { throw (Get-AVDTuneTenantMismatchText $TenantId $tid) }
        $have = @(([string](Get-AVDTuneProp $claims 'scp')) -split ' ' | Where-Object { $_ })
        foreach ($need in 'Application.ReadWrite.All', 'DelegatedPermissionGrant.ReadWrite.All') {
            if ($need -notin $have) { throw "The setup sign-in has no consent for $need. An administrator must confirm it in the sign-in window. $script:RoleText" }
        }
        $me = [string](Get-AVDTuneProp $claims 'oid')
        $account = [string]$(if (Get-AVDTuneProp $claims 'upn') { $claims.upn } else { Get-AVDTuneProp $claims 'preferred_username' })
        $g = { param($Method, $Path, $Body, $Step) Invoke-AVDTuneSetupGraph -Auth $Auth -Token $token -Method $Method -Path $Path -Body $Body -Step $Step }
        $list = { param($Path, $Step) $b = & $g GET $Path $null $Step; @(Get-AVDTuneProp $b 'value') | Where-Object { $null -ne $_ } }

        # The service principals of the resources and the IDs of the permissions
        $access = @(); $resourceSp = @{}
        foreach ($resApp in $script:AppPermissions.Keys) {
            $sp = @(& $list (Get-AVDTuneGraphFilterPath 'servicePrincipals' "appId eq '$resApp'" 'id,appId,oauth2PermissionScopes') 'read the service principal of a resource') | Select-Object -First 1
            if (-not $sp -and $resApp -eq $script:ArmAppId) {
                # Azure Service Management has no service principal in a tenant that never used Azure: it is added (Microsoft's own app)
                $sp = & $g POST '/v1.0/servicePrincipals' @{ appId = $resApp } 'add Azure Service Management to the tenant'
                [void]$notes.Add('Azure Service Management was added to the tenant (service principal of Microsoft''s app).')
            }
            if (-not $sp) { throw "The resource $resApp was not found in the tenant." }
            $resourceSp[$resApp] = [string]$sp.id
            $ids = foreach ($name in $script:AppPermissions[$resApp]) {
                $scope = @($sp.oauth2PermissionScopes | Where-Object { $_.value -eq $name }) | Select-Object -First 1
                if (-not $scope) { throw "The permission $name was not found at the resource $resApp." }
                @{ id = [string]$scope.id; type = 'Scope' }
            }
            $access += @{ resourceAppId = $resApp; resourceAccess = @($ids) }
        }

        # An earlier registration of AVDTune: name, tag, redirect and the signed-in account as its only owner
        $app = $null
        foreach ($c in @(& $list (Get-AVDTuneGraphFilterPath 'applications' "displayName eq '$script:AppName'" 'id,appId,displayName,publicClient,tags') 'search the app registration')) {
            if (-not $c) { continue }
            $tagged = @($c.tags) -contains $script:AppTag
            $redirect = @(Get-AVDTuneProp (Get-AVDTuneProp $c 'publicClient') 'redirectUris') -contains 'http://localhost'
            $owners = @(@(& $list "/v1.0/applications/$($c.id)/owners?`$select=id" 'read the owners of the app registration') | ForEach-Object { [string]$_.id })
            $mine = $me -and $owners.Count -gt 0 -and @($owners | Where-Object { $_ -ne $me }).Count -eq 0
            if ($tagged -and $redirect -and $mine) { $app = $c; break }
            [void]$notes.Add("The app registration '$($c.displayName)' ($($c.appId)) is not reused: $(if (-not $tagged) { 'it has no AVDTune tag' } elseif (-not $redirect) { 'it has no redirect http://localhost' } else { 'you are not its only owner' }).")
        }
        $definition = @{
            displayName = $script:AppName; isFallbackPublicClient = $false; publicClient = @{ redirectUris = @('http://localhost') }
            requiredResourceAccess = @($access); tags = @($script:AppTag); notes = $script:AppNote
        }
        $created = $false
        if ($app) {
            [void](& $g PATCH "/v1.0/applications/$($app.id)" $definition 'update the app registration')
            [void]$notes.Add("App registration 'AVDTune' found ($($app.appId)); its permissions were set again.")
        }
        else {
            $definition.signInAudience = 'AzureADMyOrg'
            $app = & $g POST '/v1.0/applications' $definition 'create the app registration'
            $created = $true
            [void]$notes.Add("App registration 'AVDTune' created ($($app.appId)).")
        }
        $clientId = [string]$app.appId
        if (-not (Test-AVDTuneTenantGuid $clientId) -or $clientId -ieq $script:SetupClientId) { throw "The app registration came back without a usable client ID; nothing was saved." }

        # Service principal (enterprise app); Graph may not know a new registration for some seconds
        $sp = $null
        for ($try = 1; -not $sp; $try++) {
            $sp = @(& $list (Get-AVDTuneGraphFilterPath 'servicePrincipals' "appId eq '$clientId'" 'id') 'read the enterprise app') | Select-Object -First 1
            if ($sp) { break }
            try { $sp = & $g POST '/v1.0/servicePrincipals' @{ appId = $clientId; tags = @($script:AppTag) } 'create the enterprise app' }
            catch { if ($try -ge 6 -or $_.Exception.Message -like 'Your account may not*') { throw }; if ($RetryDelaySeconds -gt 0) { Start-Sleep -Seconds ($RetryDelaySeconds * $try) } }
        }

        # Admin consent for the whole organization, per resource
        foreach ($resApp in $script:AppPermissions.Keys) {
            $scopeText = ($script:AppPermissions[$resApp] -join ' ')
            $grant = @(& $list (Get-AVDTuneGraphFilterPath 'oauth2PermissionGrants' "clientId eq '$($sp.id)' and consentType eq 'AllPrincipals' and resourceId eq '$($resourceSp[$resApp])'" '') 'read the admin consent') | Select-Object -First 1
            if ($grant) { [void](& $g PATCH "/v1.0/oauth2PermissionGrants/$($grant.id)" @{ scope = $scopeText } 'grant the admin consent') }
            else { [void](& $g POST '/v1.0/oauth2PermissionGrants' @{ clientId = [string]$sp.id; consentType = 'AllPrincipals'; resourceId = $resourceSp[$resApp]; scope = $scopeText } 'grant the admin consent') }
        }
        [void]$notes.Add('Admin consent granted: ' + (@($script:AppPermissions.Keys | ForEach-Object { $script:AppPermissions[$_] -join ', ' }) -join '; ') + '.')
        [pscustomobject]@{ TenantId = $tid; ClientId = $clientId.ToLowerInvariant(); Account = $account; Created = $created; Notes = @($notes) }
    }
    finally { $token = $null }
}

#endregion

#region real adapter

function Invoke-AVDTuneHttps {
    # One HTTPS request to a fixed Microsoft host (the callers build the URL from constants); no redirects, 30 s timeout, never throws
    param([string]$Url, [string]$Method, [string]$Token, $Body)
    $uri = [Uri]$Url
    if ($uri.Scheme -ne 'https' -or $uri.Host -notin 'login.microsoftonline.com', 'graph.microsoft.com' -or -not $uri.IsDefaultPort) { return [pscustomobject]@{ Status = 0; Body = $null; Error = 'Refused: not an allowed host.' } }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    try {
        $request = [System.Net.HttpWebRequest]::Create($uri)
        $request.Method = $Method; $request.Timeout = 30000; $request.AllowAutoRedirect = $false
        if ($Token) { $request.Headers.Add('Authorization', "Bearer $Token") }
        $request.Accept = 'application/json'
        if ($null -ne $Body) {
            $bytes = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 8 -Compress))
            $request.ContentType = 'application/json'; $request.ContentLength = $bytes.Length
            $stream = $request.GetRequestStream(); try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
        }
        $response = $request.GetResponse()
    }
    catch {
        $response = Get-AVDTuneProp $_.Exception.InnerException 'Response'
        if (-not $response) { $response = Get-AVDTuneProp $_.Exception 'Response' }
        if (-not $response) { return [pscustomobject]@{ Status = 0; Body = $null; Error = $_.Exception.Message } }
    }
    try {
        $text = (New-Object IO.StreamReader($response.GetResponseStream())).ReadToEnd()
        $parsed = $null; if ($text.Trim()) { try { $parsed = $text | ConvertFrom-Json } catch { } }
        [pscustomobject]@{ Status = [int]$response.StatusCode; Body = $parsed; Error = '' }
    }
    finally { $response.Close() }
}

function New-AVDTuneAuthAdapter {
    <#
        The real identity provider: the normal Microsoft sign-in of the shared module (Invoke-PackTuneBrowserSignIn: embedded window, the
        administrator signs in himself; no Keevault, nothing filled in) and its refresh-token exchange (Request-PackTuneToken). Only these
        shared functions (and the log sink) are imported. Before the window loads the WebView2 DLLs, Assert-AVDTuneWebView2Cache checks the
        cache folder for foreign entries (the shared module checks signature and pinned hashes itself). Not used by the checks (they use the fake).
    #>
    param([object]$Owner, [Parameter(Mandatory)][string]$CacheFolder, [scriptblock]$Log)
    $shared = Join-Path (Split-Path $PSScriptRoot -Parent) 'Shared\Modules\PackTune.SignIn.psm1'
    Import-Module $shared -Force -Function Invoke-PackTuneBrowserSignIn, Request-PackTuneToken, Set-PackTuneSignInLog
    if ($Log) { Set-PackTuneSignInLog -Sink $Log }
    $script:RealSignIn = @{ Owner = $Owner; CacheFolder = $CacheFolder; Log = $Log }
    $adapter = [ordered]@{ Kind = 'Real' }
    # No closures: the blocks run in this module and see the imported shared functions and $script:RealSignIn
    $adapter.SignIn = {
        param($TenantId, $ClientId, $Scopes, $LoginHint)
        $c = $script:RealSignIn
        $check = Assert-AVDTuneWebView2Cache -Folder $c.CacheFolder
        if ($check.Status -eq 'Reset' -and $c.Log) { & $c.Log ('The WebView2 folder had unexpected content and was deleted, the pinned SDK is downloaded again: ' + ($check.Problems -join '; ')) 'Warning' }
        $setup = ($ClientId -ieq $script:SetupClientId)
        $hint = if ($setup) { "Setup: sign in with an administrator account. Microsoft's app 'Microsoft Graph Command Line Tools' creates AVDTune's own app registration and grants its admin consent; it is not used for anything else." } else { 'Sign in with the account that manages this Golden Master. AVDTune keeps the tokens in memory only.' }
        $params = @{ TenantID = $TenantId; ClientID = $ClientId; CacheFolder = $c.CacheFolder; Scopes = $Scopes; Owner = $c.Owner; Prompt = 'select_account'; Title = $(if ($setup) { 'Set up the AVDTune app registration' } else { 'Sign in to Microsoft 365 and Azure (AVDTune)' }); Hint = $hint }
        if ($LoginHint) { $params.LoginHint = [string]$LoginHint }
        Invoke-PackTuneBrowserSignIn @params
    }
    $adapter.Discover = {
        # GET of the OpenID configuration of a domain: HTTPS to login.microsoftonline.com only, no redirects, never throws (Status 0 = no connection)
        param($Domain)
        if (-not (Test-AVDTuneDomainName ([string]$Domain))) { return [pscustomobject]@{ Status = 0; Body = $null; Error = 'Refused: not a domain name.' } }
        Invoke-AVDTuneHttps -Url "https://login.microsoftonline.com/$Domain/v2.0/.well-known/openid-configuration" -Method GET -Token '' -Body $null
    }
    $adapter.Graph = {
        # A Graph call of the setup: HTTPS to graph.microsoft.com, path below /v1.0/ only, no redirects, never throws
        param($Method, $Path, $Token, $Body)
        if ($Method -notin 'GET', 'POST', 'PATCH' -or $Path -notmatch '^/v1\.0/[A-Za-z]' -or $Path -match '\.\.|#|@|\\' -or $Path -match '[\s\x00-\x1F]' -or [regex]::Matches($Path, '\?').Count -gt 1) { return [pscustomobject]@{ Status = 0; Body = $null; Error = 'Refused: not a Graph v1.0 path.' } }
        Invoke-AVDTuneHttps -Url "https://graph.microsoft.com$Path" -Method $Method -Token $Token -Body $Body
    }
    $adapter.Refresh = {
        param($TenantId, $ClientId, $RefreshToken, $Scopes)
        Request-PackTuneToken -TenantID $TenantId -ClientID $ClientId -Scopes $Scopes -Body @{ grant_type = 'refresh_token'; refresh_token = $RefreshToken }
    }
    [pscustomobject]$adapter
}

#endregion

Export-ModuleMember -Function Get-AVDTuneAudience, Get-AVDTuneAudienceScopeUrls, Get-AVDTuneExpectedScopes, Get-AVDTuneSignInLeftovers, Remove-AVDTuneSignInLeftovers, ConvertTo-AVDTuneSecure, ConvertFrom-AVDTuneSecure, Get-AVDTuneTokenClaims, ConvertTo-AVDTuneAuthError,
    New-AVDTuneSession, Connect-AVDTuneSession, Get-AVDTuneAccessToken, Get-AVDTuneSessionInfo, Disconnect-AVDTuneSession, Test-AVDTuneSessionClear, New-AVDTuneAuthAdapter,
    Test-AVDTuneTenantGuid, Test-AVDTuneDomainName, Get-AVDTuneAccountDomain, Resolve-AVDTuneTenantFromDomain, Install-AVDTuneAppRegistration, Get-AVDTuneSetupConsentNote
