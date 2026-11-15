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
    and the temporary profiles of the sign-in window (PackTuneSignIn-* in %TEMP%); Test-AVDTuneSessionClear proves both (before seal).

    The identity provider is an adapter ($Auth): SignIn and Refresh script blocks. New-AVDTuneAuthAdapter is the real one,
    Tests\Fakes\FakeServices.ps1 has the fake. Without changes to the shared module (nothing here edits Shared\).
#>

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'AVDTune.psm1')
Import-Module (Join-Path $PSScriptRoot 'AVDTune.Trust.psm1')

$script:GraphResource = 'https://graph.microsoft.com'
$script:ArmResource = 'https://management.azure.com'
# Microsoft's "Microsoft Graph Command Line Tools" app is for the setup of the app registration only, never for the tool itself (same rule as PackTune)
$script:SetupClientId = '14d82eec-204b-4c2f-b7e8-296a70dab67e'

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
    if ($m -match 'AADSTS700016|AADSTS70001') { return 'The app registration (client ID) was not found in this tenant. Check the client ID in the first-run questions.' }
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
    if ($TenantId -match '^[0-9a-fA-F-]{36}$' -and [string](Get-AVDTuneProp $Claims 'tid') -ne $TenantId) { throw 'The account signed in to another tenant than the one of the environment.' }
    $expected = @(Get-AVDTuneExpectedScopes $Audience)
    @($have | Where-Object { $_ -notin $expected })
}

function Get-AVDTuneScopeWarning([string]$Audience, [string[]]$Extra) {
    "The $Audience token carries permissions AVDTune does not ask for: $($Extra -join ', '). Check the API permissions of the app registration."
}

function Connect-AVDTuneSession {
    <#
        Signs in (adapter SignIn, interactive), then fetches the token of every audience from the refresh token. Returns a summary without
        any token (Get-AVDTuneSessionInfo). Throws readable text; on any failure the session is cleared again.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][string]$TenantId, [Parameter(Mandatory)][string]$ClientId)
    if (-not $TenantId.Trim()) { throw 'The tenant is not set (first-run questions).' }
    if ($ClientId -notmatch '^[0-9a-fA-F-]{36}$') { throw 'The client ID of the app registration is not set or not a GUID (first-run questions).' }
    if ($ClientId -ieq $script:SetupClientId) { throw "Microsoft's setup app is not allowed for AVDTune. Use the client ID of the own app registration (the one PackTune uses)." }
    Disconnect-AVDTuneSession $Session
    $Session.TenantId = $TenantId; $Session.ClientId = $ClientId
    $current = ''
    try {
        $current = 'sign-in'
        # One interactive sign-in for all Graph scopes of both Graph audiences; the answer is only used for its refresh token
        $scopes = @((Get-AVDTuneAudienceScopeUrls 'Graph') + (Get-AVDTuneAudienceScopeUrls 'Sites'))
        try { $first = & $Session.Auth.SignIn $TenantId $ClientId $scopes }
        finally { [void](Remove-AVDTuneSignInLeftovers -TempRoot $Session.TempRoot) }
        $firstAccess = [string](Get-AVDTuneProp $first 'access_token')
        if (-not $firstAccess -or -not [string](Get-AVDTuneProp $first 'refresh_token')) { throw 'The sign-in returned no refresh token (offline_access missing).' }
        $claims = Get-AVDTuneTokenClaims $firstAccess
        $Session.Account = [string]$(if (Get-AVDTuneProp $claims 'upn') { $claims.upn } else { Get-AVDTuneProp $claims 'preferred_username' })
        $Session.Name = [string](Get-AVDTuneProp $claims 'name')
        $Session.Refresh = ConvertTo-AVDTuneSecure ([string]$first.refresh_token)
        $first = $null
        $warnings = New-Object System.Collections.ArrayList
        foreach ($audience in $script:Audiences.Keys) {
            $current = $audience
            $urls = @(Get-AVDTuneAudienceScopeUrls $audience)
            $response = & $Session.Auth.Refresh $TenantId $ClientId (ConvertFrom-AVDTuneSecure $Session.Refresh) $urls
            $c = Set-AVDTuneSessionToken $Session $audience $response
            $extra = @(Assert-AVDTuneTokenClaims -Claims $c -Audience $audience -TenantId $TenantId)
            if ($extra.Count -gt 0) { [void]$warnings.Add((Get-AVDTuneScopeWarning $audience $extra)) }
        }
        $Session.Warnings = @($warnings)
        $Session.Connected = $true
        Get-AVDTuneSessionInfo $Session
    }
    catch {
        $text = ConvertTo-AVDTuneAuthError -Message $_.Exception.Message -Audience $(if ($current -in $script:Audiences.Keys) { $current } else { $null })
        Disconnect-AVDTuneSession $Session
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
    # True when no token is held and no profile of the sign-in window is left (checked before seal / "Abschliessen")
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

#region real adapter

function New-AVDTuneAuthAdapter {
    <#
        The real identity provider: the normal Microsoft sign-in of the shared module (Invoke-PackTuneBrowserSignIn: embedded window, the
        administrator signs in himself; no Keevault, nothing filled in) and its refresh-token exchange (Request-PackTuneToken). Only these
        shared functions (and the log sink) are imported. Before the window loads the WebView2 DLLs, Assert-AVDTuneWebView2Cache checks the
        cache folder; afterwards Register-AVDTuneWebView2Cache records the checked files. Not used by the checks (they use the fake).
    #>
    param([object]$Owner, [Parameter(Mandatory)][string]$CacheFolder, [string]$TrustFile, [scriptblock]$Log)
    $shared = Join-Path (Split-Path $PSScriptRoot -Parent) 'Shared\Modules\PackTune.SignIn.psm1'
    Import-Module $shared -Force -Function Invoke-PackTuneBrowserSignIn, Request-PackTuneToken, Set-PackTuneSignInLog
    if ($Log) { Set-PackTuneSignInLog -Sink $Log }
    if (-not $TrustFile) { $TrustFile = Join-Path (Split-Path $CacheFolder -Parent) 'config\webview2-trust.json' }
    $script:RealSignIn = @{ Owner = $Owner; CacheFolder = $CacheFolder; TrustFile = $TrustFile; Log = $Log }
    $adapter = [ordered]@{ Kind = 'Real' }
    # No closures: the blocks run in this module and see the imported shared functions and $script:RealSignIn
    $adapter.SignIn = {
        param($TenantId, $ClientId, $Scopes)
        $c = $script:RealSignIn
        $check = Assert-AVDTuneWebView2Cache -Folder $c.CacheFolder -TrustFile $c.TrustFile
        if ($check.Status -eq 'Reset' -and $c.Log) { & $c.Log ('The WebView2 files were not trusted and are loaded again: ' + ($check.Problems -join '; ')) 'Warning' }
        try {
            Invoke-PackTuneBrowserSignIn -TenantID $TenantId -ClientID $ClientId -CacheFolder $c.CacheFolder -Scopes $Scopes -Owner $c.Owner -Prompt select_account `
                -Title 'Sign in to Microsoft 365 and Azure (AVDTune)' -Hint 'Sign in with the account that manages this Golden Master. AVDTune keeps the tokens in memory only.'
        }
        finally {
            $reg = Register-AVDTuneWebView2Cache -Folder $c.CacheFolder -TrustFile $c.TrustFile
            if ($reg.Status -eq 'Reset' -and $c.Log) { & $c.Log ('The WebView2 files failed the check after the sign-in and were deleted: ' + ($reg.Problems -join '; ')) 'Warning' }
        }
    }
    $adapter.Refresh = {
        param($TenantId, $ClientId, $RefreshToken, $Scopes)
        Request-PackTuneToken -TenantID $TenantId -ClientID $ClientId -Scopes $Scopes -Body @{ grant_type = 'refresh_token'; refresh_token = $RefreshToken }
    }
    [pscustomobject]$adapter
}

#endregion

Export-ModuleMember -Function Get-AVDTuneAudience, Get-AVDTuneAudienceScopeUrls, Get-AVDTuneExpectedScopes, Get-AVDTuneSignInLeftovers, Remove-AVDTuneSignInLeftovers, ConvertTo-AVDTuneSecure, ConvertFrom-AVDTuneSecure, Get-AVDTuneTokenClaims, ConvertTo-AVDTuneAuthError,
    New-AVDTuneSession, Connect-AVDTuneSession, Get-AVDTuneAccessToken, Get-AVDTuneSessionInfo, Disconnect-AVDTuneSession, Test-AVDTuneSessionClear, New-AVDTuneAuthAdapter
