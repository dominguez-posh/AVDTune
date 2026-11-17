<#
    AVDTune domain controller connection (only for identity models with a DC) and discovery.

    The master is not domain joined, so the administrator enters the IP or name of a DC and a domain account. Everything else is read
    from the DC over LDAP (System.DirectoryServices.Protocols):
      * LDAPS 636 first. The certificate of the DC is probed WITHOUT sending credentials and shown (thumbprint); the administrator pins it
        for this environment. Later connections accept exactly that certificate (no chain, no name check: the pin is the trust).
        A changed certificate stops the connection (no bind, no fallback); re-pinning is a separate, logged action.
      * LDAP 389 never silently: only when 636 does not answer, only when this DC was never seen with LDAPS (no downgrade of a pinned DC),
        only with signing and sealing, and only after the administrator confirmed the risk in the window (status NeedsConfirmation first,
        nothing is sent before; the confirmation goes into the protocol). With a DNS name the bind is Kerberos only (Kerberos authenticates
        the DC, NTLM is refused); with an IP address Kerberos cannot work, so it is Negotiate (NTLM), which does not authenticate the server:
        relay of the login and offline cracking are possible, the warning says so. A simple bind (clear text) and anonymous binds do not exist
        in this code: Assert-AVDTuneLdapOptions refuses every other option set, and the checks scan this file.
      * The password is a SecureString in memory (NetworkCredential takes it as is), never in a file, log, protocol or error text.

    LDAP is an adapter ($Ldap): Probe, Open, Search, Close. New-AVDTuneLdapAdapter is the real one, Tests\Fakes\FakeServices.ps1 has the fake.
#>

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'AVDTune.psm1')

$script:FunctionalLevels = @{ 0 = 'Windows 2000'; 1 = 'Windows Server 2003 interim'; 2 = 'Windows Server 2003'; 3 = 'Windows Server 2008'; 4 = 'Windows Server 2008 R2'
    5 = 'Windows Server 2012'; 6 = 'Windows Server 2012 R2'; 7 = 'Windows Server 2016'; 10 = 'Windows Server 2025' }
$script:MaxEntries = 20000

#region options and validation

function Test-AVDTuneDcServer([string]$Server) {
    # An IPv4 address or a DNS name; nothing else reaches a socket or a filter
    $Server = $Server.Trim()
    if ($Server.Length -gt 253) { return $false }
    if ($Server -match '^(\d{1,3}\.){3}\d{1,3}$') { return -not (@($Server.Split('.') | Where-Object { [int]$_ -gt 255 }).Count) }
    $Server -match '^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$'
}

function Test-AVDTuneDomainUser([string]$User) {
    # DOMAIN\user or user@domain.example
    $User = $User.Trim()
    ($User.Length -le 256) -and ($User -match '^[A-Za-z0-9._ -]{1,64}\\[^\\/:*?"<>|\x00-\x1F]{1,104}$' -or $User -match '^[^@\\/:*?"<>|\s\x00-\x1F]{1,64}@[A-Za-z0-9.-]{1,190}$')
}

function Test-AVDTuneIpAddress([string]$Server) { $Server -match '^(\d{1,3}\.){3}\d{1,3}$' }

function New-AVDTuneLdapOptions {
    <#
        The only way to describe a connection. Mode Ldaps: SSL on 636, certificate pinned, Negotiate. Mode Signed: 389 with signing and sealing,
        Kerberos for a DNS name, Negotiate for an IP address; needs -RiskConfirmed (the administrator confirmed the warning).
    #>
    param([Parameter(Mandatory)][string]$Server, [Parameter(Mandatory)][ValidateSet('Ldaps', 'Signed')][string]$Mode, [string]$PinnedSha256, [switch]$RiskConfirmed)
    if ($Mode -eq 'Ldaps') { [pscustomobject]@{ Server = $Server; Port = 636; Ssl = $true; Signing = $false; Sealing = $false; AuthType = 'Negotiate'; PinnedSha256 = $PinnedSha256; Mode = $Mode; RiskConfirmed = $false } }
    else { [pscustomobject]@{ Server = $Server; Port = 389; Ssl = $false; Signing = $true; Sealing = $true; AuthType = $(if (Test-AVDTuneIpAddress $Server) { 'Negotiate' } else { 'Kerberos' }); PinnedSha256 = ''; Mode = $Mode; RiskConfirmed = [bool]$RiskConfirmed } }
}

function Assert-AVDTuneLdapOptions {
    # Called by every adapter before a bind. Throws for anything that would put the password on the wire unprotected.
    param([Parameter(Mandatory)]$Options)
    if ($Options.AuthType -notin 'Negotiate', 'Kerberos') { throw "LDAP authentication '$($Options.AuthType)' is not allowed (Negotiate or Kerberos only; never a simple bind)." }
    if ($Options.Port -eq 636) {
        if (-not $Options.Ssl) { throw 'Port 636 needs SSL.' }
        if (-not $Options.PinnedSha256) { throw 'LDAPS needs a pinned certificate (confirm the thumbprint first).' }
    }
    elseif ($Options.Port -eq 389) {
        if ($Options.Ssl) { throw 'Port 389 is plain LDAP here (signing and sealing); LDAPS is 636.' }
        if (-not ($Options.Signing -and $Options.Sealing)) { throw 'LDAP on port 389 is only allowed with signing and sealing.' }
        $confirmed = $Options.PSObject.Properties['RiskConfirmed'] -and [bool]$Options.RiskConfirmed
        if (-not $confirmed) { throw 'LDAP on port 389 needs the confirmation of the administrator (LDAPS did not answer).' }
        if (-not (Test-AVDTuneIpAddress ([string]$Options.Server)) -and $Options.AuthType -ne 'Kerberos') { throw 'LDAP on port 389 with a DNS name is Kerberos only (NTLM does not authenticate the server).' }
    }
    else { throw "Port $($Options.Port) is not allowed (636 or 389)." }
    $true
}

function ConvertTo-AVDTuneLdapFilterValue([string]$Value) {
    # RFC 4515 escaping for a value inside a filter
    $sb = New-Object System.Text.StringBuilder
    foreach ($c in $Value.ToCharArray()) {
        if ($c -in '\', '*', '(', ')', [char]0) { [void]$sb.AppendFormat('\{0:x2}', [int]$c) } else { [void]$sb.Append($c) }
    }
    $sb.ToString()
}

#endregion

#region connect

function Connect-AVDTuneDirectory {
    <#
        Status of the result
          NeedsPin            first contact over LDAPS: Certificate is shown (with chain status and name match as extra facts), nothing was sent.
                              Pin it (Set-AVDTuneDcPin in AVDTune.Start.psm1), connect again.
          NeedsConfirmation   636 does not answer: Warning names the risk, nothing was sent. Connect again with -ConfirmedServer <that server> after the
                              administrator confirmed it (the window logs the confirmation).
          CertificateChanged  the certificate differs from the pin: no bind, no fallback (Expected, Certificate).
          Connected           Connection (adapter handle), Security (text for the protocol), Port.
          Failed              Message (no password, no certificate details beyond the thumbprint).
        Pins: hashtable server (lower case) -> sha256 thumbprint (hex).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Ldap, [Parameter(Mandatory)][string]$Server, [Parameter(Mandatory)][string]$User, [Parameter(Mandatory)][System.Security.SecureString]$Password, [hashtable]$Pins = @{},
        # The server for which the administrator read the warning of NeedsConfirmation and accepted LDAP 389; only valid for exactly that server
        [string]$ConfirmedServer)
    $Server = $Server.Trim().ToLowerInvariant()
    if (-not (Test-AVDTuneDcServer $Server)) { return [pscustomobject]@{ Status = 'Failed'; Message = 'The domain controller must be an IP address or a DNS name.' } }
    if (-not (Test-AVDTuneDomainUser $User)) { return [pscustomobject]@{ Status = 'Failed'; Message = 'The domain account must look like DOMAIN\user or user@domain.example.' } }
    if ($Password.Length -eq 0) { return [pscustomobject]@{ Status = 'Failed'; Message = 'Enter the password of the domain account.' } }
    $pin = [string]$Pins[$Server]
    $probe = & $Ldap.Probe $Server 636
    if ($probe.Ok) {
        $found = [string]$probe.Certificate.Sha256
        if (-not $pin) { return [pscustomobject]@{ Status = 'NeedsPin'; Server = $Server; Certificate = $probe.Certificate; Message = 'First contact: check the thumbprint of the certificate and pin it.' } }
        if ($found -ine $pin) {
            return [pscustomobject]@{ Status = 'CertificateChanged'; Server = $Server; Expected = $pin; Certificate = $probe.Certificate; Message = "The certificate of $Server changed (pinned $pin, now $found). Nothing was sent. If the change is expected, pin the new certificate; otherwise stop: someone may be intercepting the connection." }
        }
        return (Open-AVDTuneConnection -Ldap $Ldap -Options (New-AVDTuneLdapOptions -Server $Server -Mode Ldaps -PinnedSha256 $pin) -User $User -Password $Password -Security 'LDAPS 636, certificate pinned')
    }
    if ($pin) {
        return [pscustomobject]@{ Status = 'Failed'; Message = "$Server answered over LDAPS before but not now ($($probe.Error)). AVDTune does not fall back to a weaker connection for a pinned domain controller." }
    }
    # No LDAPS at all (and never seen with it): LDAP 389 only after the confirmation; Kerberos for a DNS name, Negotiate (NTLM) for an IP address
    $ip = Test-AVDTuneIpAddress $Server
    $confirmed = $ConfirmedServer -and ($ConfirmedServer.Trim().ToLowerInvariant() -eq $Server)
    if (-not $confirmed) {
        return [pscustomobject]@{ Status = 'NeedsConfirmation'; Server = $Server; IsIp = $ip; Reason = [string]$probe.Error; Warning = (Get-AVDTuneLdapRiskText -Server $Server); Message = "LDAPS (636) on $Server does not answer ($($probe.Error)). Nothing was sent." }
    }
    $security = if ($ip) { 'LDAP 389 with Negotiate (NTLM) signing and sealing, no LDAPS, server not authenticated: confirmed by the administrator' } else { 'LDAP 389 with Kerberos signing and sealing (NTLM refused), no LDAPS: confirmed by the administrator' }
    Open-AVDTuneConnection -Ldap $Ldap -Options (New-AVDTuneLdapOptions -Server $Server -Mode Signed -RiskConfirmed) -User $User -Password $Password -Security $security -Note "LDAPS 636 did not answer: $($probe.Error)"
}

function Get-AVDTuneLdapRiskText {
    # The warning the window shows before LDAP 389 is used
    param([Parameter(Mandatory)][string]$Server)
    if (Test-AVDTuneIpAddress $Server) {
        return "LDAPS (636) does not answer. Without LDAPS and with an IP address AVDTune can only sign in with NTLM over LDAP 389. NTLM does not prove that $Server is your domain controller: a machine in the network path can pass the login on to another server (relay) or record it and try to crack the password offline. Signing and sealing protect the content, not against this. Better: enable LDAPS on the domain controller, or enter its DNS name (then Kerberos is used). Continue only if the network path to $Server is trusted."
    }
    "LDAPS (636) does not answer. AVDTune would use LDAP 389 with Kerberos only (NTLM is refused): Kerberos proves the identity of the domain controller and signing and sealing protect the content, but there is no pinned certificate. Better: enable LDAPS on the domain controller. Continue only if this is expected."
}

function Open-AVDTuneConnection {
    param($Ldap, $Options, [string]$User, [System.Security.SecureString]$Password, [string]$Security, [string]$Note)
    [void](Assert-AVDTuneLdapOptions $Options)
    try {
        $conn = & $Ldap.Open $Options $User $Password
        [pscustomobject]@{ Status = 'Connected'; Connection = $conn; Security = $Security; Port = $Options.Port; Server = $Options.Server; Message = $Note }
    }
    catch {
        $m = $_.Exception.Message
        if ($m -match 'credential|logon|invalid|49') { $m = 'The domain account or password was refused.' }
        [pscustomobject]@{ Status = 'Failed'; Message = "Bind to $($Options.Server) failed: $m" }
    }
}

function Disconnect-AVDTuneDirectory { param($Ldap, $Connection) if ($Connection) { try { & $Ldap.Close $Connection } catch { } } }

#endregion

#region discovery

function ConvertTo-AVDTuneSid($Value) {
    if ($Value -is [byte[]]) { return (New-Object System.Security.Principal.SecurityIdentifier($Value, 0)).Value }
    [string]$Value
}

function Get-AVDTuneDnFromNc([string]$Dn) {
    # DC=example,DC=com -> example.com
    (@(([regex]::Matches($Dn, '(?i)(?:^|,)DC=([^,]+)') | ForEach-Object { $_.Groups[1].Value })) -join '.')
}

function Get-AVDTuneLevelName($Level) {
    if ($null -eq $Level -or [string]$Level -eq '') { return '' }
    $n = [int]$Level
    if ($script:FunctionalLevels.ContainsKey($n)) { $script:FunctionalLevels[$n] } else { "level $n" }
}

function Get-AVDTuneAttr($Entry, [string]$Name) {
    # First value of an attribute of a search entry (attribute names are case-insensitive in the adapter's tables)
    $v = $Entry.Attributes[$Name]
    if ($null -eq $v) { return $null }
    , (@($v)[0])   # the comma keeps a byte array (objectSid) in one piece
}

function Get-AVDTuneOuTree {
    # Flat list of OUs -> tree (children by distinguished name)
    param([object[]]$OuList)
    $nodes = @{}
    foreach ($ou in $OuList) { $nodes[$ou.Dn.ToLowerInvariant()] = [pscustomobject]@{ Name = $ou.Name; Dn = $ou.Dn; Children = (New-Object System.Collections.ArrayList) } }
    $roots = New-Object System.Collections.ArrayList
    foreach ($node in ($nodes.Values | Sort-Object Dn)) {
        $parent = if ($node.Dn -match '^(?:OU|CN)=(?:[^,\\]|\\.)+,(.+)$') { $Matches[1].ToLowerInvariant() } else { '' }
        if ($parent -and $nodes.ContainsKey($parent)) { [void]$nodes[$parent].Children.Add($node) } else { [void]$roots.Add($node) }
    }
    foreach ($node in $nodes.Values) { $node.Children = @($node.Children | Sort-Object Name) }
    @($roots | Sort-Object Name)
}

function Get-AVDTuneDirectoryInfo {
    <#
        Reads RootDSE (DNS name, NetBIOS name, naming contexts, functional levels), the site of the DC, the OU tree and the groups with their SIDs.
        Read only. A part that cannot be read is named in Warnings; the rest is still returned.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Ldap, [Parameter(Mandatory)]$Connection)
    $warnings = New-Object System.Collections.ArrayList
    $root = @(& $Ldap.Search $Connection '' '(objectClass=*)' 'Base' @('defaultNamingContext', 'rootDomainNamingContext', 'configurationNamingContext', 'schemaNamingContext', 'dnsHostName', 'serverName', 'domainFunctionality', 'forestFunctionality', 'domainControllerFunctionality', 'namingContexts'))
    if ($root.Count -eq 0) { throw 'The domain controller returned no RootDSE.' }
    $r = $root[0]
    $defaultNc = [string](Get-AVDTuneAttr $r 'defaultNamingContext')
    $configNc = [string](Get-AVDTuneAttr $r 'configurationNamingContext')
    if (-not $defaultNc) { throw 'The RootDSE has no defaultNamingContext.' }
    $serverName = [string](Get-AVDTuneAttr $r 'serverName')
    $site = if ($serverName -match '(?i),CN=Servers,CN=([^,]+),CN=Sites,') { $Matches[1] } else { '' }

    $netbios = ''
    if ($configNc) {
        try {
            $part = @(& $Ldap.Search $Connection "CN=Partitions,$configNc" "(&(objectClass=crossRef)(nCName=$(ConvertTo-AVDTuneLdapFilterValue $defaultNc)))" 'OneLevel' @('nETBIOSName'))
            if ($part.Count -gt 0) { $netbios = [string](Get-AVDTuneAttr $part[0] 'nETBIOSName') }
        }
        catch { [void]$warnings.Add("NetBIOS name not read: $($_.Exception.Message)") }
    }
    # The SID of the domain itself (objectSid of the domain object), read, never guessed. Only the strict form S-1-5-21-x-y-z is kept.
    $domainSid = ''
    try {
        $dom = @(& $Ldap.Search $Connection $defaultNc '(objectClass=*)' 'Base' @('objectSid'))
        if ($dom.Count -gt 0) { $cand = ConvertTo-AVDTuneSid (Get-AVDTuneAttr $dom[0] 'objectSid'); if ($cand -match '\AS-1-5-21-[0-9]{1,10}-[0-9]{1,10}-[0-9]{1,10}\z') { $domainSid = $cand } else { [void]$warnings.Add('The domain SID has an unexpected format and is not used.') } }
        else { [void]$warnings.Add('The domain SID was not returned.') }
    }
    catch { [void]$warnings.Add("Domain SID not read: $($_.Exception.Message)") }
    $ous = @()
    try {
        $ous = @(& $Ldap.Search $Connection $defaultNc '(objectClass=organizationalUnit)' 'Subtree' @('name', 'distinguishedName') | ForEach-Object {
                [pscustomobject]@{ Name = [string](Get-AVDTuneAttr $_ 'name'); Dn = [string]$(if (Get-AVDTuneAttr $_ 'distinguishedName') { Get-AVDTuneAttr $_ 'distinguishedName' } else { $_.Dn }) }
            })
    }
    catch { [void]$warnings.Add("OU tree not read: $($_.Exception.Message)") }
    $groups = @()
    try {
        $groups = @(& $Ldap.Search $Connection $defaultNc '(objectClass=group)' 'Subtree' @('name', 'distinguishedName', 'sAMAccountName', 'objectSid', 'groupType', 'description') | ForEach-Object {
                $gt = Get-AVDTuneAttr $_ 'groupType'
                [pscustomobject]@{
                    Name = [string](Get-AVDTuneAttr $_ 'name'); Dn = [string]$(if (Get-AVDTuneAttr $_ 'distinguishedName') { Get-AVDTuneAttr $_ 'distinguishedName' } else { $_.Dn })
                    Sid = (ConvertTo-AVDTuneSid (Get-AVDTuneAttr $_ 'objectSid')); Security = $(if ($null -ne $gt) { ([int]$gt) -lt 0 } else { $true })
                    Description = [string](Get-AVDTuneAttr $_ 'description'); Sam = $(if (Get-AVDTuneAttr $_ 'sAMAccountName') { [string](Get-AVDTuneAttr $_ 'sAMAccountName') } else { [string](Get-AVDTuneAttr $_ 'name') })
                }
            } | Where-Object { $_.Sid })
    }
    catch { [void]$warnings.Add("Groups not read: $($_.Exception.Message)") }
    $dl = Get-AVDTuneAttr $r 'domainFunctionality'; $fl = Get-AVDTuneAttr $r 'forestFunctionality'; $cl = Get-AVDTuneAttr $r 'domainControllerFunctionality'
    [pscustomobject]@{
        DnsName = (Get-AVDTuneDnFromNc $defaultNc); NetBiosName = $netbios; DcDnsName = [string](Get-AVDTuneAttr $r 'dnsHostName'); Site = $site
        DefaultNamingContext = $defaultNc; DomainSid = $domainSid; RootDomainNamingContext = [string](Get-AVDTuneAttr $r 'rootDomainNamingContext'); ConfigurationNamingContext = $configNc
        SchemaNamingContext = [string](Get-AVDTuneAttr $r 'schemaNamingContext')
        DomainLevel = (Get-AVDTuneLevelName $dl); ForestLevel = (Get-AVDTuneLevelName $fl); DcLevel = (Get-AVDTuneLevelName $cl)
        OuCount = $ous.Count; OuTree = @(Get-AVDTuneOuTree $ous); Groups = @($groups | Sort-Object Name); Warnings = @($warnings)
    }
}

function Save-AVDTuneDirectoryInfo {
    # The directory as read (OU tree, groups with SIDs) for later phases: config\directory.json in the protected state folder. No credentials.
    param([string]$Root = (Get-AVDTuneRoot), [Parameter(Mandatory)]$Info)
    Write-AVDTuneFile (Join-Path $Root 'config\directory.json') (([ordered]@{ ReadAt = (Get-Date).ToString('o'); Directory = $Info }) | ConvertTo-Json -Depth 12)
}

#endregion

#region real adapter

function New-AVDTuneLdapAdapter {
    <#
        The real LDAP adapter (System.DirectoryServices.Protocols). Probe sends no credentials: a TLS handshake only, to read the certificate.
        Open binds with Negotiate and the credential (the password stays a SecureString inside NetworkCredential); LDAPS verifies the pinned
        certificate in VerifyServerCertificate, 389 sets Signing and Sealing. Not used by the checks (they use the fake).
    #>
    Add-Type -AssemblyName System.DirectoryServices.Protocols
    $adapter = [ordered]@{ Kind = 'Real' }
    $adapter.Probe = {
        param($Server, $Port)
        $tcp = New-Object System.Net.Sockets.TcpClient
        try {
            $wait = $tcp.BeginConnect($Server, $Port, $null, $null)
            if (-not $wait.AsyncWaitHandle.WaitOne(5000)) { return [pscustomobject]@{ Ok = $false; Error = 'timeout'; Certificate = $null } }
            $tcp.EndConnect($wait)
            $captured = $null
            # The probe accepts every certificate (the pin is the trust), but keeps what Windows says about it: chain and name, shown on first contact
            $callback = [System.Net.Security.RemoteCertificateValidationCallback] {
                param($s, $cert, $chain, $errors)
                $script:AVDTuneProbeCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $cert
                $script:AVDTuneProbeErrors = $errors
                $script:AVDTuneProbeChain = @(if ($chain) { $chain.ChainStatus | ForEach-Object { [string]$_.Status } })
                $true
            }
            $ssl = New-Object System.Net.Security.SslStream($tcp.GetStream(), $false, $callback)
            $ssl.ReadTimeout = 5000; $ssl.WriteTimeout = 5000
            $script:AVDTuneProbeCert = $null; $script:AVDTuneProbeErrors = 0; $script:AVDTuneProbeChain = @()
            try { $ssl.AuthenticateAsClient($Server) } finally { $ssl.Dispose() }
            $cert = $script:AVDTuneProbeCert
            if (-not $cert) { return [pscustomobject]@{ Ok = $false; Error = 'no certificate'; Certificate = $null } }
            $sha = [Security.Cryptography.SHA256]::Create()
            try { $hash = ($sha.ComputeHash($cert.RawData) | ForEach-Object { $_.ToString('X2') }) -join '' } finally { $sha.Dispose() }
            $errors = [System.Net.Security.SslPolicyErrors]$script:AVDTuneProbeErrors
            $chainOk = -not ($errors -band [System.Net.Security.SslPolicyErrors]::RemoteCertificateChainErrors)
            $nameOk = -not ($errors -band [System.Net.Security.SslPolicyErrors]::RemoteCertificateNameMismatch)
            $chainText = if ($chainOk) { 'trusted by this computer' } else { 'not trusted by this computer: ' + ((@($script:AVDTuneProbeChain) | Where-Object { $_ -and $_ -ne 'NoError' } | Select-Object -Unique) -join ', ') }
            [pscustomobject]@{ Ok = $true; Error = ''; Certificate = [pscustomobject]@{
                    Thumbprint = $cert.Thumbprint; Sha256 = $hash; Subject = $cert.Subject; Issuer = $cert.Issuer
                    NotBefore = $cert.NotBefore.ToString('o'); NotAfter = $cert.NotAfter.ToString('o')
                    ChainOk = [bool]$chainOk; ChainStatus = $chainText; NameMatches = [bool]$nameOk } }
        }
        catch { [pscustomobject]@{ Ok = $false; Error = $_.Exception.Message; Certificate = $null } }
        finally { $tcp.Close() }
    }
    $adapter.Open = {
        param($Options, $User, $Password)
        [void](Assert-AVDTuneLdapOptions $Options)
        # fullyQualifiedDnsHostName = $true: the name is used as given (no short-name lookup that another host could answer)
        $id = New-Object System.DirectoryServices.Protocols.LdapDirectoryIdentifier($Options.Server, [int]$Options.Port, $true, $false)
        $cred = if ($User -match '^([^\\]+)\\(.+)$') { New-Object System.Net.NetworkCredential($Matches[2], $Password, $Matches[1]) } else { New-Object System.Net.NetworkCredential($User, $Password) }
        $authType = if ($Options.AuthType -eq 'Kerberos') { [System.DirectoryServices.Protocols.AuthType]::Kerberos } else { [System.DirectoryServices.Protocols.AuthType]::Negotiate }
        $conn = New-Object System.DirectoryServices.Protocols.LdapConnection($id, $cred, $authType)
        $conn.SessionOptions.ProtocolVersion = 3
        $conn.SessionOptions.ReferralChasing = [System.DirectoryServices.Protocols.ReferralChasingOptions]::None
        $conn.Timeout = [TimeSpan]::FromSeconds(60)
        if ($Options.Ssl) {
            $conn.SessionOptions.SecureSocketLayer = $true
            $pin = [string]$Options.PinnedSha256
            $conn.SessionOptions.VerifyServerCertificate = [System.DirectoryServices.Protocols.VerifyServerCertificateCallback] {
                param($c, $cert)
                $x = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $cert
                $sha = [Security.Cryptography.SHA256]::Create()
                try { $h = ($sha.ComputeHash($x.RawData) | ForEach-Object { $_.ToString('X2') }) -join '' } finally { $sha.Dispose() }
                $h -ieq $pin
            }.GetNewClosure()
        }
        else {
            $conn.SessionOptions.Signing = $true
            $conn.SessionOptions.Sealing = $true
        }
        $conn.Bind()
        $conn
    }
    $adapter.Search = {
        param($Conn, $BaseDn, $Filter, $Scope, $Attributes)
        $scopeValue = [System.DirectoryServices.Protocols.SearchScope]$Scope
        $request = New-Object System.DirectoryServices.Protocols.SearchRequest($BaseDn, $Filter, $scopeValue, [string[]]$Attributes)
        $request.TimeLimit = [TimeSpan]::FromSeconds(60)
        $pager = New-Object System.DirectoryServices.Protocols.PageResultRequestControl(500)
        [void]$request.Controls.Add($pager)
        $out = New-Object System.Collections.ArrayList
        do {
            $response = [System.DirectoryServices.Protocols.SearchResponse]$Conn.SendRequest($request)
            foreach ($e in $response.Entries) {
                $attrs = @{}
                foreach ($name in $e.Attributes.AttributeNames) {
                    $values = $e.Attributes[$name]
                    $list = @(); for ($i = 0; $i -lt $values.Count; $i++) { $list += , $values[$i] }
                    $attrs[[string]$name] = $list
                }
                [void]$out.Add([pscustomobject]@{ Dn = $e.DistinguishedName; Attributes = (New-Object 'System.Collections.Hashtable' $attrs, ([StringComparer]::OrdinalIgnoreCase)) })
                if ($out.Count -ge 20000) { throw 'More than 20000 entries; narrow the search.' }
            }
            $control = $response.Controls | Where-Object { $_ -is [System.DirectoryServices.Protocols.PageResultResponseControl] } | Select-Object -First 1
            $pager.Cookie = if ($control) { $control.Cookie } else { $null }
        } while ($pager.Cookie -and $pager.Cookie.Length -gt 0)
        @($out)
    }
    $adapter.Close = { param($Conn) $Conn.Dispose() }
    [pscustomobject]$adapter
}

#endregion

Export-ModuleMember -Function Test-AVDTuneIpAddress, Get-AVDTuneLdapRiskText, Test-AVDTuneDcServer, Test-AVDTuneDomainUser, New-AVDTuneLdapOptions, Assert-AVDTuneLdapOptions, ConvertTo-AVDTuneLdapFilterValue, Connect-AVDTuneDirectory,
    Disconnect-AVDTuneDirectory, Get-AVDTuneDirectoryInfo, Save-AVDTuneDirectoryInfo, ConvertTo-AVDTuneSid, Get-AVDTuneOuTree, Get-AVDTuneLevelName, New-AVDTuneLdapAdapter
