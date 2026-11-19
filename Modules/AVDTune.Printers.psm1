<#
    AVDTune printer drivers from a print server (docs\plans\avdtune.md, section 3b; issue #86). Only for identity models with a domain; with Entra only the page
    points to Universal Print.

      * Print servers come from AD only (printQueue objects over the pinned LDAPS connection of the start sequence). A typed name is taken only when it is in that list;
        IP addresses and short names are refused (Kerberos needs the FQDN).
      * Everything on the server goes through one WinRM session with Kerberos (FQDN, the account as UPN): the server is authenticated, no NTLM, no TrustedHosts.
        Read: the shared printers with their driver (name, version, architecture, package-aware as the server says), and per driver the export of only its INF
        (pnputil /export-driver <oem>.inf into an admin-only folder below the server's Windows\Temp), copied with limits (count, size, no links, all below the local
        folder, INF and catalog on the top level) and checked: the catalog (.cat named by the INF) has a valid Authenticode signature with chain; WHQL ("Microsoft
        Windows Hardware Compatibility Publisher") is allowed, another publisher only when the administrator confirmed it (config\printers-signers.json).
      * The administrator confirms the plan (driver, version, INF, signer). Apply reads the server again and stops when anything differs from the confirmed plan,
        exports again and stops when the signer differs; then pnputil /add-driver and Add-PrinterDriver. There is no install by printer connection (Point and Print
        would take whatever the server sends). Temporary folders are removed on both sides.
      * Check after the install (the test of each step): the driver is installed locally with the version of the server and its INF in the driver store; package-aware
        is read from the installed driver (the server's claim is only compared).
      * Point and Print: RestrictDriverInstallationToAdministrators = 1 and the package Point and Print list limited to the chosen servers, with undo. Unsafe values
        found on the master (NoWarningNoElevationOnInstall = 1, UpdatePromptSettings = 2) are shown.
      * TrustedHosts is not touched any more; a journal of the first version (#86, d63e941) is still repaired at the start.
      * Every access goes through the printer adapter ($P): New-AVDTunePrinterAdapter is the real one (NOT exercised by the checks beyond construction and command
        resolution, to be tried on a throw-away VM); Tests\Fakes\FakePrinters.ps1 is the fake.
#>

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'AVDTune.psm1')
Import-Module (Join-Path $PSScriptRoot 'AVDTune.Updates.psm1')
Import-Module (Join-Path $PSScriptRoot 'AVDTune.Directory.psm1')
Import-Module (Join-Path $PSScriptRoot 'AVDTune.Custom.psm1')   # registry adapter and the host name rule

$script:PolicyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers\PointAndPrint'
$script:PackageKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers\PackagePointAndPrint'
$script:ListKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers\PackagePointAndPrint\ListofServers'
$script:Arch = 'Windows x64'
$script:MaxQueues = 5000
$script:MaxFiles = 2000
$script:MaxBytes = 500MB
$script:Whql = 'Microsoft Windows Hardware Compatibility Publisher'
$script:Rx = [TimeSpan]::FromMilliseconds(200)

#region validation (pure)

function Test-AVDTunePrinterServerName([string]$Name) {
    # The FQDN of a print server (Kerberos needs it): a host name with at least one dot, not an IP address; no backslash, slash, colon, at sign, space or wildcard
    if (-not $Name -or $Name.Length -gt 253 -or $Name.IndexOf('.') -lt 1) { return $false }
    if ([regex]::IsMatch($Name, '\A[0-9.]+\z', 'None', $script:Rx)) { return $false }
    Test-AVDTuneCustomHostName $Name
}

function Test-AVDTunePrinterShareName([string]$Name) { [bool]($Name -and $Name.Length -le 80 -and [regex]::IsMatch($Name, '\A[^\\/:*?"<>|\x00-\x1F]+\z', 'None', $script:Rx) -and $Name.Trim() -eq $Name -and $Name -notmatch '\A\.+\z') }

function Test-AVDTunePrinterDriverName([string]$Name) {
    # N3: the driver name goes to Add-PrinterDriver/Remove-PrinterDriver -Name: no wildcard (* ? [ ]), no control character, limited length
    [bool]($Name -and $Name.Length -le 200 -and $Name.Trim() -eq $Name -and [regex]::IsMatch($Name, '\A[^*?\[\]\x00-\x1F]+\z', 'None', $script:Rx))
}

function Test-AVDTunePrinterInfPath([string]$Path) {
    # The INF path the server names for a driver: a local path on the server ending in .inf; it is only handed to the fixed remote block as data
    [bool]($Path -and $Path.Length -le 260 -and [regex]::IsMatch($Path, '\A[A-Za-z]:\\[^<>"|?*\x00-\x1F]+\.inf\z', 'IgnoreCase', $script:Rx) -and $Path -notmatch '\\\.\.(\\|\z)')
}

function ConvertTo-AVDTunePrinterVersion($Value) {
    # DriverVersion of Get-PrinterDriver is a UInt64 with four 16-bit parts; a version text is taken as it is when it is a.b.c.d
    if ($null -eq $Value) { return '' }
    if ($Value -is [string]) { if ($Value.Length -gt 30) { return '' }; if ($Value -match '\A\d{1,5}(\.\d{1,5}){3}\z') { return $Value }; $n = 0; if (-not [uint64]::TryParse($Value, [ref]$n)) { return '' }; $Value = $n }
    $v = [uint64]$Value
    '{0}.{1}.{2}.{3}' -f (($v -shr 48) -band 0xFFFF), (($v -shr 32) -band 0xFFFF), (($v -shr 16) -band 0xFFFF), ($v -band 0xFFFF)
}

function Get-AVDTunePrinterAvailability {
    # The page works only with a domain controller in the identity model; Entra only means Universal Print
    param($Answers)
    $dc = [string](Get-AVDTuneProp $Answers 'Dc')
    [pscustomobject]@{ Domain = [bool]($dc -and $dc -ne 'None'); Dc = $dc }
}

function ConvertTo-AVDTunePrinterUpn {
    # The account for Kerberos as UPN: user@domain stays, DOMAIN\user becomes user@<DNS domain> (from the directory read in the start sequence); anything else is refused
    param([Parameter(Mandatory)][string]$User, [string]$DnsDomain)
    if ([regex]::IsMatch($User, '\A[^\\@\s]{1,104}@[A-Za-z0-9.-]{1,253}\z', 'None', $script:Rx)) { return $User }
    $m = [regex]::Match($User, '\A[^\\@\s]{1,15}\\([^\\@\s]{1,104})\z', 'None', $script:Rx)
    if ($m.Success -and $DnsDomain -and (Test-AVDTuneCustomHostName $DnsDomain)) { return "$($m.Groups[1].Value)@$DnsDomain" }
    throw 'The domain account must be user@domain (Kerberos needs the UPN).'
}

function Assert-AVDTunePrinterServerAllowed {
    # H1: a server is used only when AD publishes it (printQueue list of the pinned LDAPS connection); compared case-insensitively
    param([Parameter(Mandatory)][string]$Server, [string[]]$Allowed = @())
    if (-not (Test-AVDTunePrinterServerName $Server)) { throw "'$(Remove-AVDTuneControlCharacters $Server 80)' is not the FQDN of a print server (no IP address, no short name, no UNC path)." }
    if (@($Allowed | Where-Object { $_ -ieq $Server }).Count -eq 0) { throw "$Server is not a print server published in AD (printQueue): it is not used." }
}

#endregion

#region reading

function Get-AVDTunePrinterAttr($Entry, [string]$Name) { $v = $Entry.Attributes[$Name]; if ($null -eq $v) { $null } else { @($v)[0] } }

function Find-AVDTunePrintServers {
    <# Read only: the print servers published in AD (printQueue objects, serverName = FQDN) with the number of their printers. A name that is not an FQDN is left out and named. #>
    param([Parameter(Mandatory)]$Ldap, [Parameter(Mandatory)]$Connection)
    $root = @(& $Ldap.Search $Connection '' '(objectClass=*)' 'Base' @('defaultNamingContext'))
    $nc = if ($root.Count) { [string](Get-AVDTunePrinterAttr $root[0] 'defaultNamingContext') } else { '' }
    if (-not $nc) { throw 'The domain controller returned no defaultNamingContext.' }
    $queues = @(& $Ldap.Search $Connection $nc '(objectCategory=printQueue)' 'Subtree' @('serverName', 'printerName'))
    if ($queues.Count -gt $script:MaxQueues) { $queues = $queues[0..($script:MaxQueues - 1)] }
    $count = @{}; $skipped = New-Object System.Collections.ArrayList
    foreach ($q in $queues) {
        $s = [string](Get-AVDTunePrinterAttr $q 'serverName')
        if (-not (Test-AVDTunePrinterServerName $s)) { if ($s) { [void]$skipped.Add((Remove-AVDTuneControlCharacters $s 80)) }; continue }
        $k = $s.ToLowerInvariant(); if ($count.ContainsKey($k)) { $count[$k]++ } else { $count[$k] = 1 }
    }
    [pscustomobject]@{ Servers = @($count.Keys | Sort-Object | ForEach-Object { [pscustomobject]@{ Name = $_; Printers = $count[$_] } }); Skipped = @($skipped | Select-Object -Unique) }
}

function Invoke-AVDTunePrinterSession {
    # One Kerberos WinRM session to the server for -Block (param($Session)); closed in finally
    param([Parameter(Mandatory)]$P, [Parameter(Mandatory)][string]$Server, $Credential, [Parameter(Mandatory)][scriptblock]$Block)
    $s = & $P.RemoteOpen $Server $Credential
    try { & $Block $s } finally { & $P.RemoteClose $s }
}

function Get-AVDTunePrinterInventory {
    <#
        Read only on the master: the shared printers of the server with their x64 driver (name, version, architecture, package-aware as the server says, INF path), read
        through the session. A printer whose driver has no x64 version on the server, or whose names are not valid, gets a Problem and is never installed.
    #>
    param([Parameter(Mandatory)]$P, [Parameter(Mandatory)]$Session, [Parameter(Mandatory)][string]$Server)
    $drivers = @{}
    foreach ($d in @(& $P.RemoteDrivers $Session)) { $drivers["$([string]$d.Name)|$([string]$d.Environment)".ToLowerInvariant()] = $d }
    $rows = foreach ($p in @(& $P.RemotePrinters $Session | Where-Object { $_.Shared })) {
        $name = Remove-AVDTuneControlCharacters ([string]$p.Name) 200; $drv = [string]$p.DriverName
        $d = $drivers["$drv|$($script:Arch)".ToLowerInvariant()]
        $problem = ''
        if (-not (Test-AVDTunePrinterShareName ([string]$p.ShareName))) { $problem = 'The share name is not valid.' }
        elseif (-not (Test-AVDTunePrinterDriverName $drv)) { $problem = 'The driver name is not valid (wildcards, control characters or too long).' }
        elseif (-not $d) { $problem = "The server has no $($script:Arch) driver $drv." }
        elseif (-not (Test-AVDTunePrinterInfPath ([string]$d.InfPath))) { $problem = 'The server names no valid INF path for this driver.' }
        [pscustomobject]@{ Name = $name; ShareName = [string]$p.ShareName; Driver = $drv; Version = $(if ($d) { ConvertTo-AVDTunePrinterVersion $d.Version } else { '' })
            Architecture = $(if ($d) { $script:Arch } else { '' }); PackageAware = $(if ($d) { [bool]$d.PackageAware } else { $false }); InfPath = $(if ($d) { [string]$d.InfPath } else { '' })
            Server = $Server.ToLowerInvariant(); Problem = $problem; Signer = ''; Thumbprint = ''; Whql = $false; Allowed = $false }
    }
    [pscustomobject]@{ Server = $Server.ToLowerInvariant(); Printers = @($rows | Sort-Object Name); Warnings = @(); At = (Get-Date).ToString('o') }
}

function Get-AVDTunePrinterDriverPlan {
    <# The distinct drivers of the selected printers (-Selected: printer names; empty = all shared printers without a problem), each with the printers that use it. #>
    param([Parameter(Mandatory)]$Inventory, [string[]]$Selected = @())
    $use = @($Inventory.Printers | Where-Object { -not $_.Problem -and ($Selected.Count -eq 0 -or $_.Name -in $Selected) })
    @($use | Group-Object Driver | Sort-Object Name | ForEach-Object {
            $f = $_.Group[0]
            [pscustomobject]@{ Name = $f.Driver; Version = $f.Version; Architecture = $f.Architecture; PackageAware = $f.PackageAware; InfPath = $f.InfPath; Server = $f.Server
                Signer = $f.Signer; Thumbprint = $f.Thumbprint; Whql = $f.Whql; Allowed = $f.Allowed; Printers = @($_.Group | ForEach-Object { $_.Name }) }
        })
}

function Compare-AVDTunePrinterPlan {
    <# M1: the confirmed plan against a fresh read of the server. Returns the differences (empty: the same drivers with the same version, INF, package-aware claim and server). #>
    param([object[]]$Confirmed, [object[]]$Fresh)
    $byName = @{}; foreach ($f in @($Fresh)) { if ($f) { $byName[$f.Name] = $f } }
    @(foreach ($c in @($Confirmed)) {
            if (-not $c) { continue }
            $f = $byName[[string]$c.Name]
            if (-not $f) { "$($c.Name): no longer on the server"; continue }
            foreach ($k in 'Version', 'InfPath', 'PackageAware', 'Server') { if ([string]$f.$k -ne [string]$c.$k) { "$($c.Name): $k is now '$($f.$k)', confirmed was '$($c.$k)'" } }
        })
}

function Get-AVDTunePrinterLocal {
    # The installed x64 driver of that name on the master (version, INF path, package-aware as installed), or $null
    param([Parameter(Mandatory)]$P, [Parameter(Mandatory)][string]$Name)
    $d = @(& $P.LocalDrivers | Where-Object { [string]$_.Name -eq $Name -and [string]$_.Environment -eq 'Windows x64' })[0]
    if (-not $d) { return $null }
    [pscustomobject]@{ Version = (ConvertTo-AVDTunePrinterVersion $d.Version); InfPath = [string]$d.InfPath; PackageAware = [bool]$d.PackageAware
        InStore = [regex]::IsMatch([string]$d.InfPath, '\A[A-Za-z]:\\Windows\\System32\\DriverStore\\FileRepository\\[^\\]+\\[^\\]+\.inf\z', 'IgnoreCase', $script:Rx) }
}

function Get-AVDTunePrinterDriverStatus {
    # Read only: each driver of the plan with the installed version, driver store and package-aware as installed; Warning when the server claimed package-aware and the installed driver is not
    param([Parameter(Mandatory)]$P, [object[]]$Drivers)
    @($Drivers | Where-Object { $_ } | ForEach-Object {
            $l = Get-AVDTunePrinterLocal -P $P -Name $_.Name
            [pscustomobject]@{ Name = $_.Name; Server = $_.Server; Version = $_.Version; Installed = $(if ($l) { $l.Version } else { '' }); InStore = [bool]($l -and $l.InStore); PackageAware = [bool]($l -and $l.PackageAware)
                Ok = [bool]($l -and $l.Version -eq $_.Version -and $l.InStore)
                Warning = $(if ($l -and $_.PackageAware -and -not $l.PackageAware) { 'The server says package-aware; the installed driver is not.' } else { '' }) }
        })
}

function Get-AVDTunePrinterPolicyWarnings {
    # N4: Point and Print values on the master that switch the PrintNightmare protection off
    param([Parameter(Mandatory)]$P)
    $w = @()
    $a = & $P.RegGet $script:PolicyKey 'NoWarningNoElevationOnInstall'; if ($a -and [string]$a.Value -eq '1') { $w += 'NoWarningNoElevationOnInstall = 1: users install drivers without a prompt.' }
    $b = & $P.RegGet $script:PolicyKey 'UpdatePromptSettings'; if ($b -and [string]$b.Value -eq '2') { $w += 'UpdatePromptSettings = 2: driver updates without warning or elevation.' }
    $c = & $P.RegGet $script:PolicyKey 'NoWarningNoElevationOnUpdate'; if ($c -and [string]$c.Value -eq '1') { $w += 'NoWarningNoElevationOnUpdate = 1: driver updates without a prompt.' }
    @($w)
}

#endregion

#region signers (allowlist) and the checked export

function Get-AVDTunePrinterSignerPath([string]$Root) { Join-Path $Root 'config\printers-signers.json' }

function Get-AVDTunePrinterSigners {
    # config\printers-signers.json: publishers the administrator allowed besides WHQL (thumbprint 40 hex + subject); types checked, anything else is dropped
    param([string]$Root = (Get-AVDTuneRoot))
    $j = $null; try { $j = Read-AVDTuneJson (Get-AVDTunePrinterSignerPath $Root) } catch { }
    @(@(Get-AVDTuneProp $j 'Signers') | Where-Object { $_ -and (Get-AVDTuneProp $_ 'Thumbprint') -is [string] -and (Get-AVDTuneProp $_ 'Subject') -is [string] -and [regex]::IsMatch($_.Thumbprint, '\A[0-9A-F]{40}\z', 'None', $script:Rx) } |
            ForEach-Object { [pscustomobject]@{ Thumbprint = $_.Thumbprint; Subject = $_.Subject; AddedBy = [string](Get-AVDTuneProp $_ 'AddedBy'); At = [string](Get-AVDTuneProp $_ 'At') } })
}

function Add-AVDTunePrinterSigner {
    # The administrator allows a publisher (after a confirmation in the window): thumbprint and subject of the catalog signer
    param([string]$Root = (Get-AVDTuneRoot), [Parameter(Mandatory)][string]$Thumbprint, [Parameter(Mandatory)][string]$Subject, [string]$User)
    if (-not [regex]::IsMatch($Thumbprint, '\A[0-9A-F]{40}\z', 'None', $script:Rx)) { throw 'Not a certificate thumbprint.' }
    $list = @(Get-AVDTunePrinterSigners -Root $Root | Where-Object { $_.Thumbprint -ne $Thumbprint })
    $list += [pscustomobject]@{ Thumbprint = $Thumbprint; Subject = (Remove-AVDTuneControlCharacters $Subject 300); AddedBy = (Remove-AVDTuneControlCharacters $User 80); At = (Get-Date).ToString('o') }
    Write-AVDTuneFile (Get-AVDTunePrinterSignerPath $Root) ([ordered]@{ Schema = 1; Signers = @($list) } | ConvertTo-Json -Depth 4)
}

function Get-AVDTunePrinterDnPart([string]$Dn, [string]$Key) {
    if (-not $Dn) { return '' }
    try { $lines = (New-Object System.Security.Cryptography.X509Certificates.X500DistinguishedName($Dn)).Decode([System.Security.Cryptography.X509Certificates.X500DistinguishedNameFlags]::UseNewLines) -split "\r?\n" } catch { return '' }
    $v = @(foreach ($l in $lines) { $i = $l.IndexOf('='); if ($i -gt 0 -and $l.Substring(0, $i).Trim() -ceq $Key) { $l.Substring($i + 1).Trim() } })
    if ($v.Count -eq 1) { $v[0] } else { '' }
}

function Test-AVDTunePrinterExportFiles {
    # N1 before the copy: the list of the export on the server (relative paths, sizes) within the limits, no path that leaves the folder, no link
    param([object[]]$Files)
    $f = @($Files | Where-Object { $_ })
    if ($f.Count -eq 0) { return 'The export is empty.' }
    if ($f.Count -gt $script:MaxFiles) { return "The export has $($f.Count) entries (more than $($script:MaxFiles))." }
    $sum = 0L; foreach ($x in $f) { $sum += [int64]$x.Length }
    if ($sum -gt $script:MaxBytes) { return "The export is $sum bytes (more than $($script:MaxBytes))." }
    $bad = @($f | Where-Object { -not (Test-AVDTunePrinterRelPath ([string]$_.Path)) -or [bool]$_.Link })
    if ($bad.Count) { return "The export has a path that is not allowed or a link: $($bad[0].Path)." }
    ''
}

function Test-AVDTunePrinterRelPath([string]$Path) {
    # A relative path of the export: at most 8 segments joined by \, each one plain name (no . or .., no / : * ? " < > |, no control character, no trailing dot or space)
    if (-not $Path -or $Path.Length -gt 200) { return $false }
    $seg = $Path.Split([char]92)
    if ($seg.Count -gt 8) { return $false }
    foreach ($s in $seg) {
        if (-not $s -or $s -eq '.' -or $s -eq '..' -or $s.TrimEnd('. ') -ne $s) { return $false }
        if (-not [regex]::IsMatch($s, '\A[^/:*?"<>|\x00-\x1F]{1,120}\z', 'None', $script:Rx)) { return $false }
    }
    $true
}

function Copy-AVDTunePrinterExport {
    <#
        N1: the export file by file (no copy of a whole tree): each relative path is checked here (Test-AVDTunePrinterRelPath), the target must stay below $Local after
        GetFullPath, folders are made one by one as own folders, each file is written new (CreateNew: nothing existing is overwritten). The bytes come from the session.
    #>
    param([Parameter(Mandatory)]$P, [Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$Export, [Parameter(Mandatory)][string]$Local)
    $base = [IO.Path]::GetFullPath($Local).TrimEnd([char]92) + '\'
    $sum = 0L
    foreach ($e in @($Export.Files)) {
        $rel = [string]$e.Path
        if (-not (Test-AVDTunePrinterRelPath $rel) -or [bool]$e.Link) { throw "The export has a path that is not allowed or a link: $rel." }
        $target = [IO.Path]::GetFullPath($base + $rel)
        if (-not $target.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) { throw "$rel leaves the work folder." }
        $seg = $rel.Split([char]92); $dir = $base.TrimEnd([char]92)
        $last = if ([bool](Get-AVDTuneProp $e 'Dir')) { $seg.Count } else { $seg.Count - 1 }
        for ($i = 0; $i -lt $last; $i++) { $dir = "$dir\$($seg[$i])"; & $P.LocalMkdir $dir }
        if (-not [bool](Get-AVDTuneProp $e 'Dir')) {
            # #108 N2: the limits hold before anything is written, per file against the length of the list, in sum against MaxBytes
            $bytes = [byte[]](& $P.RemoteReadFile $Session ([string]$Export.Source + '\' + $rel))
            if ([int64]$bytes.Length -ne [int64]$e.Length) { throw "$rel has $($bytes.Length) bytes, the list of the export said $([int64]$e.Length): not copied." }
            $sum += $bytes.Length; if ($sum -gt $script:MaxBytes) { throw "The export is larger than $($script:MaxBytes) bytes: not copied." }
            & $P.LocalWriteNew $target $bytes
        }
    }
}

function Get-AVDTunePrinterInfCatalog {
    <#
        M-neu: the catalog an INF names, read like Windows: only the [Version] section (case-insensitive, comments after ; removed), CatalogFile.NTamd64 before CatalogFile.NT
        before CatalogFile; a key that is there twice is refused, a value with a string token (%...%) or a path is refused. Returns Catalog or Error.
    #>
    param([string]$Text)
    $vals = @{}; $section = ''
    foreach ($raw in ($Text -split "`r?`n")) {
        $line = $raw; $c = $line.IndexOf(';'); if ($c -ge 0) { $line = $line.Substring(0, $c) }
        $line = $line.Trim()
        if (-not $line) { continue }
        if ($line.StartsWith('[')) { $section = $line.Trim('[', ']', ' ').ToLowerInvariant(); continue }
        if ($section -ne 'version') { continue }
        $eq = $line.IndexOf('='); if ($eq -lt 1) { continue }
        $k = $line.Substring(0, $eq).Trim().ToLowerInvariant()
        if ($k -notin 'catalogfile.ntamd64', 'catalogfile.nt', 'catalogfile') { continue }
        if ($vals.ContainsKey($k)) { return [pscustomobject]@{ Catalog = ''; Error = "The INF names $k twice in [Version]." } }
        $vals[$k] = $line.Substring($eq + 1).Trim().Trim('"')
    }
    foreach ($k in 'catalogfile.ntamd64', 'catalogfile.nt', 'catalogfile') {
        if ($vals.ContainsKey($k)) {
            $v = $vals[$k]
            if (-not [regex]::IsMatch($v, '\A[^\\/:*?"<>|%\x00-\x1F]{1,200}\.cat\z', 'IgnoreCase', $script:Rx)) { return [pscustomobject]@{ Catalog = ''; Error = "The catalog name of $k is not a plain .cat file name." } }
            return [pscustomobject]@{ Catalog = $v; Error = '' }
        }
    }
    [pscustomobject]@{ Catalog = ''; Error = 'The INF names no catalog file in [Version]: an unsigned driver is not installed.' }
}

function Test-AVDTunePrinterLocalTree {
    # N1 after the copy: every entry below the local folder (walked without following links), no link, within the limits
    param([Parameter(Mandatory)]$P, [Parameter(Mandatory)][string]$Folder)
    $t = @(& $P.LocalTree $Folder)
    $base = $Folder.TrimEnd('\') + '\'
    $out = @($t | Where-Object { -not ([string]$_.Path).StartsWith($base, [StringComparison]::OrdinalIgnoreCase) })
    if ($out.Count) { return "$($out[0].Path) is not below the work folder." }
    $links = @($t | Where-Object { $_.Link }); if ($links.Count) { return "$($links[0].Path) is a link." }
    if ($t.Count -gt $script:MaxFiles) { return 'Too many entries in the copy.' }
    $sum = 0L; foreach ($x in $t) { $sum += [int64]$x.Length }; if ($sum -gt $script:MaxBytes) { return 'The copy is too large.' }
    ''
}

function Test-AVDTunePrinterCatalog {
    <#
        H2: the INF (top level of the copy) names its catalog (CatalogFile.NTamd64, else CatalogFile; a plain file name on the top level); the catalog must have a valid
        Authenticode signature with chain. WHQL (signer CN "Microsoft Windows Hardware Compatibility Publisher", O Microsoft Corporation, issuer O Microsoft Corporation) is
        allowed; another signer only when its thumbprint is in -Signers. Returns Ok, Reason, Signer (subject), Thumbprint, Whql.
    #>
    param([Parameter(Mandatory)]$P, [Parameter(Mandatory)][string]$Folder, [Parameter(Mandatory)][string]$InfLeaf, [object[]]$Signers = @())
    $r = [ordered]@{ Ok = $false; Reason = ''; Signer = ''; Thumbprint = ''; Whql = $false }
    $top = @(& $P.LocalTree $Folder | Where-Object { -not $_.Link -and (Split-Path ([string]$_.Path) -Parent).TrimEnd('\') -ieq $Folder.TrimEnd('\') } | ForEach-Object { Split-Path ([string]$_.Path) -Leaf })
    if ($InfLeaf -notin $top) { $r.Reason = "The INF $InfLeaf is not on the top level of the export."; return [pscustomobject]$r }
    $text = [string](& $P.ReadInf (Join-Path $Folder $InfLeaf))
    if ($text.Length -gt 1MB) { $r.Reason = 'The INF is larger than 1 MB.'; return [pscustomobject]$r }
    $ic = Get-AVDTunePrinterInfCatalog -Text $text
    if ($ic.Error) { $r.Reason = $ic.Error; return [pscustomobject]$r }
    $cat = $ic.Catalog
    # exactly one catalog in the whole export, and it is the one the INF names (a second catalog could be the one Windows takes)
    $cats = @(& $P.LocalTree $Folder | Where-Object { ([string]$_.Path) -like '*.cat' })
    if ($cats.Count -ne 1) { $r.Reason = "The export has $($cats.Count) catalog files; exactly one is allowed."; return [pscustomobject]$r }
    if ($cat -notin $top -or (Split-Path ([string]$cats[0].Path) -Leaf) -ine $cat) { $r.Reason = "The catalog $cat is not the one catalog on the top level of the export."; return [pscustomobject]$r }
    $s = & $P.CatalogSignature (Join-Path $Folder $cat)
    $r.Signer = [string]$s.Subject; $r.Thumbprint = ([string]$s.Thumbprint).ToUpperInvariant()
    if ([string]$s.Status -ne 'Valid' -or -not [bool]$s.ChainOk) { $r.Reason = "The catalog $cat has no valid signature ($($s.Status))."; return [pscustomobject]$r }
    $r.Whql = (Get-AVDTunePrinterDnPart $s.Subject 'CN') -ceq $script:Whql -and (Get-AVDTunePrinterDnPart $s.Subject 'O') -ceq 'Microsoft Corporation' -and (Get-AVDTunePrinterDnPart $s.Issuer 'O') -ceq 'Microsoft Corporation'
    if (-not $r.Whql -and @($Signers | Where-Object { $_.Thumbprint -eq $r.Thumbprint }).Count -eq 0) { $r.Reason = "Signed by $($r.Signer), not WHQL and not allowed by the administrator."; return [pscustomobject]$r }
    $r.Ok = $true
    [pscustomobject]$r
}

function Get-AVDTunePrinterCheckedExport {
    <#
        The export of exactly one driver (its INF on the server) into a new admin-only local folder, checked (limits, links, catalog signature). The remote folder is removed
        in finally. Returns Folder (the caller removes it), Inf (top-level path) and Catalog (Test-AVDTunePrinterCatalog). Throws when the export or the copy is not allowed.
    #>
    param([Parameter(Mandatory)]$P, [Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$Driver, [string]$Root = (Get-AVDTuneRoot), [object[]]$Signers = @())
    if (-not (Test-AVDTunePrinterInfPath $Driver.InfPath)) { throw "The server names no valid INF path for $($Driver.Name)." }
    $local = & $P.WorkFolder $Root
    $ok = $false
    try {
        $exp = & $P.RemoteExport $Session $Driver.InfPath
        try {
            $bad = Test-AVDTunePrinterExportFiles $exp.Files
            if ($bad) { throw $bad }
            Copy-AVDTunePrinterExport -P $P -Session $Session -Export $exp -Local $local
        }
        finally { & $P.RemoteRemove $Session $exp.Folder }
        $bad = Test-AVDTunePrinterLocalTree -P $P -Folder $local
        if ($bad) { throw $bad }
        $leaf = Split-Path $Driver.InfPath -Leaf
        $cat = Test-AVDTunePrinterCatalog -P $P -Folder $local -InfLeaf $leaf -Signers $Signers
        $ok = $true
        [pscustomobject]@{ Folder = $local; Inf = (Join-Path $local $leaf); Catalog = $cat }
    }
    finally { if (-not $ok) { & $P.RemoveTree $local } }
}

function Add-AVDTunePrinterSignatures {
    <#
        Read (no change of the master): every driver of the inventory is exported and checked once; the printers get Signer, Thumbprint, Whql and Allowed. A driver without
        a valid signature becomes a Problem of its printers; one signed by a publisher that is not allowed stays selectable (the window asks the administrator). The local
        copies are removed again.
    #>
    param([Parameter(Mandatory)]$P, [Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$Inventory, [string]$Root = (Get-AVDTuneRoot), [object[]]$Signers = @())
    $seen = @{}
    foreach ($pr in @($Inventory.Printers | Where-Object { -not $_.Problem })) {
        if (-not $seen.ContainsKey($pr.Driver)) {
            $res = $null
            try { $x = Get-AVDTunePrinterCheckedExport -P $P -Session $Session -Driver ([pscustomobject]@{ Name = $pr.Driver; InfPath = $pr.InfPath }) -Root $Root -Signers $Signers; $res = $x.Catalog; & $P.RemoveTree $x.Folder }
            catch { $res = [pscustomobject]@{ Ok = $false; Reason = $_.Exception.Message; Signer = ''; Thumbprint = ''; Whql = $false } }
            $seen[$pr.Driver] = $res
        }
        $c = $seen[$pr.Driver]
        $pr.Signer = $c.Signer; $pr.Thumbprint = $c.Thumbprint; $pr.Whql = $c.Whql; $pr.Allowed = [bool]$c.Ok
        if (-not $c.Ok -and -not ($c.Thumbprint -and $c.Reason -like '*not allowed by the administrator*')) { $pr.Problem = $c.Reason }
    }
    $Inventory
}

#endregion

#region state

function Get-AVDTunePrinterStatePath([string]$Root) { Join-Path $Root 'config\printers.json' }
function Get-AVDTunePrinterUndoPath([string]$Root) { Join-Path $Root 'config\printers-undo.json' }
function Get-AVDTunePrinterJournalPath([string]$Root) { Join-Path $Root 'config\printers-trustedhosts.json' }

function Get-AVDTunePrinterState {
    # config\printers.json: the chosen servers and the drivers AVDTune installed (name, version, server, signer, printers, time); types checked, anything else is dropped
    param([string]$Root = (Get-AVDTuneRoot))
    $j = $null; try { $j = Read-AVDTuneJson (Get-AVDTunePrinterStatePath $Root) } catch { }
    $servers = @(@(Get-AVDTuneProp $j 'Servers') | Where-Object { $_ -is [string] -and (Test-AVDTunePrinterServerName $_) } | ForEach-Object { $_.ToLowerInvariant() } | Select-Object -Unique)
    $drivers = @(@(Get-AVDTuneProp $j 'Drivers') | Where-Object { $_ -and (Get-AVDTuneProp $_ 'Name') -is [string] -and (Get-AVDTuneProp $_ 'Version') -is [string] -and (Test-AVDTunePrinterServerName ([string](Get-AVDTuneProp $_ 'Server'))) } |
            ForEach-Object { [pscustomobject]@{ Name = $_.Name; Version = $_.Version; Server = ([string]$_.Server).ToLowerInvariant(); Signer = [string](Get-AVDTuneProp $_ 'Signer'); Printers = @(@(Get-AVDTuneProp $_ 'Printers') | Where-Object { $_ -is [string] }); At = [string](Get-AVDTuneProp $_ 'At') } })
    [pscustomobject]@{ Servers = $servers; Drivers = $drivers }
}

function Save-AVDTunePrinterState {
    param([string]$Root = (Get-AVDTuneRoot), [Parameter(Mandatory)]$State)
    Write-AVDTuneFile (Get-AVDTunePrinterStatePath $Root) ([ordered]@{ Schema = 1; Servers = @($State.Servers); Drivers = @($State.Drivers) } | ConvertTo-Json -Depth 6)
}

function Read-AVDTunePrinterUndo([string]$Root) {
    $u = @{ Policy = $null; Drivers = @{} }
    $j = $null; try { $j = Read-AVDTuneJson (Get-AVDTunePrinterUndoPath $Root) } catch { }
    if ($j) {
        $u.Policy = Get-AVDTuneProp $j 'Policy'
        $d = Get-AVDTuneProp $j 'Drivers'; if ($d) { foreach ($p in $d.PSObject.Properties) { $u.Drivers[$p.Name] = $p.Value } }
    }
    $u
}

function Write-AVDTunePrinterUndo([string]$Root, [hashtable]$Undo) { Write-AVDTuneFile (Get-AVDTunePrinterUndoPath $Root) ([ordered]@{ Schema = 1; Policy = $Undo.Policy; Drivers = $Undo.Drivers } | ConvertTo-Json -Depth 8) }

function Compare-AVDTunePrinterDrivers {
    <#
        Maintenance (skeleton, plan 3b): the drivers of the server (a plan of Get-AVDTunePrinterDriverPlan) against what AVDTune installed from that server.
        New: on the server, not installed by AVDTune; Changed: another version on the server; Same. Gone (installed, no printer of the server uses it) is listed, not removed.
    #>
    param([object[]]$Installed, [object[]]$Server)
    $have = @{}; foreach ($i in @($Installed)) { if ($i) { $have["$($i.Server)|$($i.Name)".ToLowerInvariant()] = $i } }
    $rows = New-Object System.Collections.ArrayList; $seen = @{}
    foreach ($d in @($Server)) {
        if (-not $d) { continue }
        $k = "$($d.Server)|$($d.Name)".ToLowerInvariant(); $seen[$k] = $true
        $i = $have[$k]
        $st = if (-not $i) { 'New' } elseif ($i.Version -ne $d.Version) { 'Changed' } else { 'Same' }
        [void]$rows.Add([pscustomobject]@{ Name = $d.Name; Server = $d.Server; Installed = $(if ($i) { $i.Version } else { '' }); ServerVersion = $d.Version; Status = $st })
    }
    $servers = @(@($Server) | Where-Object { $_ } | ForEach-Object { $_.Server } | Select-Object -Unique)
    foreach ($k in $have.Keys) { $i = $have[$k]; if ($i.Server -in $servers -and -not $seen.ContainsKey($k)) { [void]$rows.Add([pscustomobject]@{ Name = $i.Name; Server = $i.Server; Installed = $i.Version; ServerVersion = ''; Status = 'Gone' }) } }
    @($rows)
}

function Repair-AVDTunePrinterTrustedHosts {
    <# A journal of the first version (it appended the server to TrustedHosts): TrustedHosts is set back to the value before, then the journal goes. Returns $true when it repaired. #>
    param([Parameter(Mandatory)]$P, [string]$Root = (Get-AVDTuneRoot))
    $path = Get-AVDTunePrinterJournalPath $Root
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
    $j = Read-AVDTuneJson $path
    $old = Get-AVDTuneProp $j 'Old'
    if ($old -isnot [string]) { throw "The TrustedHosts journal $path has no previous value: check TrustedHosts by hand and delete the journal." }
    & $P.TrustedHostsSet $old
    [void](Remove-AVDTuneTreeSafe -Path $path)
    $true
}

#endregion

#region install and steps

function Install-AVDTunePrinterDriver {
    <#
        H2: one driver of the confirmed plan: export of only its INF over the Kerberos session, checked copy, the catalog signed by the confirmed signer (thumbprint) and
        allowed, then pnputil /add-driver and Add-PrinterDriver. The local folder is removed in finally. No install by a printer connection.
    #>
    param([Parameter(Mandatory)]$P, [Parameter(Mandatory)]$Driver, $Credential, [string]$Root = (Get-AVDTuneRoot), [object[]]$Signers = @())
    if (-not (Test-AVDTunePrinterDriverName $Driver.Name)) { throw 'The driver name is not valid.' }
    $p = $P; $d = $Driver; $r = $Root; $sg = $Signers
    $x = Invoke-AVDTunePrinterSession -P $P -Server $Driver.Server -Credential $Credential -Block { param($s) Get-AVDTunePrinterCheckedExport -P $p -Session $s -Driver $d -Root $r -Signers $sg }.GetNewClosure()
    try {
        if (-not $x.Catalog.Ok) { throw $x.Catalog.Reason }
        if ($x.Catalog.Thumbprint -ne [string]$Driver.Thumbprint) { throw "The catalog of $($Driver.Name) is now signed by $($x.Catalog.Signer) ($($x.Catalog.Thumbprint)), not by the confirmed signer: not installed." }
        & $P.AddDriverPackage $x.Inf
        & $P.AddDriver $Driver.Name
    }
    finally { & $P.RemoveTree $x.Folder }
}

function Get-AVDTunePrinterStepId([string]$Name) {
    $h = [Security.Cryptography.SHA256]::Create()
    try { 'printers.driver-' + (([BitConverter]::ToString($h.ComputeHash([Text.Encoding]::UTF8.GetBytes($Name.ToLowerInvariant()))) -replace '-', '').Substring(0, 12).ToLowerInvariant()) } finally { $h.Dispose() }
}

function Get-AVDTunePrinterDriverTitle($Driver) {
    $pr = @($Driver.Printers); $list = $(if ($pr.Count) { @($pr[0..([Math]::Min(8, $pr.Count) - 1)]) -join ', ' } else { '-' }) + $(if ($pr.Count -gt 8) { ", +$($pr.Count - 8)" } else { '' })
    $who = Get-AVDTunePrinterDnPart ([string]$Driver.Signer) 'CN'; if (-not $who) { $who = [string]$Driver.Signer }
    "Printer driver $($Driver.Name) $($Driver.Version) from $($Driver.Server), signed by $who (printers: $list)"
}

function New-AVDTunePrinterDriverStep {
    <# The step of one driver: Test = installed with the version of the server and its INF in the driver store (also the check after Apply); Apply = checked export; Undo only for a driver AVDTune added. #>
    param([Parameter(Mandatory)]$Driver, [Parameter(Mandatory)]$P, $Credential, [string]$Root = (Get-AVDTuneRoot), $Before, [object[]]$Signers = @())
    $d = $Driver; $cred = $Credential; $r = $Root; $pp = $P; $sg = $Signers
    $test = { param($m) $l = Get-AVDTunePrinterLocal -P $pp -Name $d.Name; @{ Compliant = [bool]($l -and $l.Version -eq $d.Version -and $l.InStore); State = $(if ($l) { "$($l.Version)$(if (-not $l.InStore) { ' (INF not in the driver store)' }), package-aware: $($l.PackageAware)" } else { 'absent' }) } }.GetNewClosure()
    $apply = { param($m) Install-AVDTunePrinterDriver -P $pp -Driver $d -Credential $cred -Root $r -Signers $sg }.GetNewClosure()
    $undo = $null
    if ($Before -and -not [bool](Get-AVDTuneProp $Before 'Existed')) { $undo = { param($m) if (-not (Test-AVDTunePrinterDriverName $d.Name)) { throw 'The driver name is not valid.' }; & $pp.RemoveDriver $d.Name }.GetNewClosure() }
    New-AVDTuneStep -Id (Get-AVDTunePrinterStepId $d.Name) -Section Printers -Title (Get-AVDTunePrinterDriverTitle $d) -Why 'Users must not install printer drivers (Point and Print restriction): every driver of the print server is in the image.' -Risk Medium -Test $test -Apply $apply -Undo $undo
}

function Get-AVDTunePrinterPolicyBefore {
    param([Parameter(Mandatory)]$P)
    $list = [ordered]@{}; foreach ($n in @(& $P.RegValues $script:ListKey)) { $v = & $P.RegGet $script:ListKey $n; if ($v) { $list[[string]$n] = [string]$v.Value } }
    $g = { param($k, $n) $v = & $P.RegGet $k $n; if ($v) { [ordered]@{ Exists = $true; Value = $v.Value; Kind = [string]$v.Kind } } else { [ordered]@{ Exists = $false } } }
    [ordered]@{ Restrict = (& $g $script:PolicyKey 'RestrictDriverInstallationToAdministrators'); ListFlag = (& $g $script:PackageKey 'PackagePointAndPrintServerList'); List = $list }
}

function New-AVDTunePrinterPolicySteps {
    <# Point and Print: drivers only by administrators, package Point and Print only from the chosen servers (other entries of the list are removed; the undo record keeps them). #>
    param([Parameter(Mandatory)]$P, [Parameter(Mandatory)][string[]]$Servers)
    $pp = $P; $pk = $script:PolicyKey; $kk = $script:PackageKey; $lk = $script:ListKey
    $want = @($Servers | Where-Object { Test-AVDTunePrinterServerName $_ } | ForEach-Object { $_.ToLowerInvariant() } | Select-Object -Unique | Sort-Object)
    if ($want.Count -eq 0) { throw 'No valid print server for the Point and Print list.' }
    $t1 = { param($m) $v = & $pp.RegGet $pk 'RestrictDriverInstallationToAdministrators'; @{ Compliant = [bool]($v -and $v.Kind -eq 'DWord' -and [int]$v.Value -eq 1); State = $(if ($v) { "$($v.Kind) $($v.Value)" } else { 'absent' }) } }.GetNewClosure()
    $a1 = { param($m) & $pp.RegSet $pk 'RestrictDriverInstallationToAdministrators' 1 'DWord' }.GetNewClosure()
    $t2 = {
        param($m)
        $f = & $pp.RegGet $kk 'PackagePointAndPrintServerList'
        $have = @(@(& $pp.RegValues $lk) | ForEach-Object { $v = & $pp.RegGet $lk $_; if ($v) { ([string]$v.Value).ToLowerInvariant() } } | Sort-Object -Unique)
        @{ Compliant = [bool]($f -and [int]$f.Value -eq 1 -and ($have -join ',') -eq ($want -join ',')); State = $(if ($have.Count) { $have -join ', ' } else { 'no list' }) }
    }.GetNewClosure()
    $a2 = {
        param($m)
        & $pp.RegSet $kk 'PackagePointAndPrintServerList' 1 'DWord'
        foreach ($n in @(& $pp.RegValues $lk)) { $v = & $pp.RegGet $lk $n; if (-not $v -or ([string]$v.Value).ToLowerInvariant() -notin $want -or [string]$n -ne ([string]$v.Value).ToLowerInvariant()) { & $pp.RegRemove $lk $n } }
        foreach ($s in $want) { & $pp.RegSet $lk $s $s 'String' }
    }.GetNewClosure()
    @(
        (New-AVDTuneStep -Id 'printers.policy-restrict' -Section Printers -Title 'Point and Print: printer drivers only by administrators (RestrictDriverInstallationToAdministrators = 1)' -Why 'Since PrintNightmare users cannot install drivers; the drivers come with the image.' -Risk Medium -SourceUrl 'https://support.microsoft.com/topic/kb5005652' -Test $t1 -Apply $a1)
        (New-AVDTuneStep -Id 'printers.policy-serverlist' -Section Printers -Title "Package Point and Print only from: $($want -join ', ')" -Why 'Users connect printers of the chosen servers without prompts and without driver installs.' -Risk Medium -Test $t2 -Apply $a2)
    )
}

function Test-AVDTunePrinterRegMatch($Current, $Record) {
    # the value now against the record of the undo: both absent, or the same kind and value
    $had = $Record -and [bool](Get-AVDTuneProp $Record 'Exists')
    if (-not $had) { return ($null -eq $Current) }
    [bool]($Current -and [string]$Current.Kind -eq [string]$Record.Kind -and [string]$Current.Value -eq [string]$Record.Value)
}

function New-AVDTunePrinterPolicyUndoSteps {
    <# Undo of the policies: in place when the values equal the record taken before AVDTune changed them; Apply writes the record back (removes what was absent). #>
    param([Parameter(Mandatory)]$P, [Parameter(Mandatory)]$Before)
    $pp = $P; $pk = $script:PolicyKey; $kk = $script:PackageKey; $lk = $script:ListKey; $b = $Before
    $rRec = Get-AVDTuneProp $b 'Restrict'; $fRec = Get-AVDTuneProp $b 'ListFlag'
    $want = @(); $old = Get-AVDTuneProp $b 'List'; if ($old) { $want = @($old.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)".ToLowerInvariant() } | Sort-Object) }
    $restoreOne = { param($k, $n, $rec) if ($rec -and [bool](Get-AVDTuneProp $rec 'Exists')) { & $pp.RegSet $k $n $rec.Value $rec.Kind } else { & $pp.RegRemove $k $n } }.GetNewClosure()
    $t1 = { param($m) $v = & $pp.RegGet $pk 'RestrictDriverInstallationToAdministrators'; @{ Compliant = (Test-AVDTunePrinterRegMatch $v $rRec); State = $(if ($v) { "$($v.Kind) $($v.Value)" } else { 'absent' }) } }.GetNewClosure()
    $a1 = { param($m) & $restoreOne $pk 'RestrictDriverInstallationToAdministrators' $rRec }.GetNewClosure()
    $t2 = {
        param($m)
        $have = @(@(& $pp.RegValues $lk) | ForEach-Object { $v = & $pp.RegGet $lk $_; "$_=$(if ($v) { $v.Value })".ToLowerInvariant() } | Sort-Object)
        @{ Compliant = ((Test-AVDTunePrinterRegMatch (& $pp.RegGet $kk 'PackagePointAndPrintServerList') $fRec) -and ($have -join ',') -eq ($want -join ',')); State = $(if ($have.Count) { $have -join ', ' } else { 'no list' }) }
    }.GetNewClosure()
    $a2 = {
        param($m)
        & $restoreOne $kk 'PackagePointAndPrintServerList' $fRec
        foreach ($n in @(& $pp.RegValues $lk)) { & $pp.RegRemove $lk $n }
        if ($old) { foreach ($p in $old.PSObject.Properties) { & $pp.RegSet $lk $p.Name ([string]$p.Value) 'String' } }
    }.GetNewClosure()
    @(
        (New-AVDTuneStep -Id 'printers.undo-policy-restrict' -Section Printers -Title 'Undo: Point and Print driver restriction as before AVDTune' -Why 'Puts back what AVDTune changed for printers.' -Risk Medium -Test $t1 -Apply $a1)
        (New-AVDTuneStep -Id 'printers.undo-policy-serverlist' -Section Printers -Title 'Undo: package Point and Print server list as before AVDTune' -Why 'Puts back what AVDTune changed for printers.' -Risk Medium -Test $t2 -Apply $a2)
    )
}

function New-AVDTunePrinterUndoStep {
    # Undo as a step Invoke-AVDTune can apply: in place when the original step does NOT test as in place any more
    param([Parameter(Mandatory)]$Step)
    $s = $Step
    $test = { param($m) $r = & $s.Test $m; $c = if ($r -is [System.Collections.IDictionary]) { [bool]$r['Compliant'] } else { [bool]$r }; $st = if ($r -is [System.Collections.IDictionary]) { $r['State'] } else { $null }; @{ Compliant = (-not $c); State = $st } }.GetNewClosure()
    $apply = { param($m) & $s.Undo $m }.GetNewClosure()
    New-AVDTuneStep -Id ($s.Id -replace '^printers\.', 'printers.undo-') -Section Printers -Title "Undo: $($s.Title)" -Why 'Puts back what AVDTune changed for printers.' -Risk Medium -Test $test -Apply $apply
}

function Invoke-AVDTunePrinterRun {
    <#
        Apply: the drivers of -Drivers (the confirmed plan: Name, Version, InfPath, PackageAware, Server, Signer, Thumbprint, Printers) and, with -Policy, the Point and Print
        policies for the chosen servers (saved ones plus these), through Invoke-AVDTune. The state before is recorded for undo (an older record stays); config\printers.json
        gets every driver that is in place afterwards; Check lists each driver as installed. Undo: the policies back to the record, drivers AVDTune added removed.
        The caller compares the plan with a fresh read first (Compare-AVDTunePrinterPlan).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Machine, [Parameter(Mandatory)]$P, [string]$Root = (Get-AVDTuneRoot), [ValidateSet('Apply', 'Undo')][string]$Mode = 'Apply', [object[]]$Drivers = @(),
        $Credential, [switch]$Policy, [string]$User, [string]$SnapshotId)
    if (-not (Test-AVDTuneWriteAllowed)) { throw 'The snapshot gate is not confirmed: nothing is installed.' }
    $state = Get-AVDTunePrinterState -Root $Root
    $undo = Read-AVDTunePrinterUndo $Root
    $signers = @(Get-AVDTunePrinterSigners -Root $Root)
    $steps = New-Object System.Collections.ArrayList; $byStep = @{}
    if ($Mode -eq 'Apply') {
        foreach ($d in @($Drivers)) {
            if (-not (Test-AVDTunePrinterServerName $d.Server)) { throw "Not the FQDN of a print server: $($d.Server)." }
            if (-not (Test-AVDTunePrinterDriverName $d.Name)) { throw "Not a valid driver name: $($d.Name)." }
            if (-not [regex]::IsMatch([string]$d.Thumbprint, '\A[0-9A-F]{40}\z', 'None', $script:Rx)) { throw "$($d.Name) has no confirmed signer." }
            $s = New-AVDTunePrinterDriverStep -Driver $d -P $P -Credential $Credential -Root $Root -Signers $signers
            [void]$steps.Add($s); $byStep[$s.Id] = @{ Driver = $d; Existed = [bool](Get-AVDTunePrinterLocal -P $P -Name $d.Name) }
        }
        $servers = @(@($state.Servers) + @($Drivers | ForEach-Object { $_.Server }) | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() } | Select-Object -Unique)
        $policyBefore = $null
        if ($Policy) { $policyBefore = Get-AVDTunePrinterPolicyBefore -P $P; foreach ($s in (New-AVDTunePrinterPolicySteps -P $P -Servers $servers)) { [void]$steps.Add($s) } }
    }
    else {
        if ($undo.Policy) { foreach ($s in (New-AVDTunePrinterPolicyUndoSteps -P $P -Before $undo.Policy)) { [void]$steps.Add($s) } }
        foreach ($k in @($undo.Drivers.Keys)) {
            $rec = $undo.Drivers[$k]
            $d = [pscustomobject]@{ Name = [string]$rec.Name; Version = [string]$rec.Version; Server = [string]$rec.Server; InfPath = ''; PackageAware = $false; Signer = ''; Thumbprint = ''; Printers = @() }
            $orig = New-AVDTunePrinterDriverStep -Driver $d -P $P -Root $Root -Before $rec
            if ($orig.Undo) { $s = New-AVDTunePrinterUndoStep -Step $orig; [void]$steps.Add($s); $byStep[$s.Id] = @{ Key = $k } }
        }
    }
    if ($steps.Count -eq 0) { return [pscustomobject]@{ Run = $null; Check = @() } }
    $run = Invoke-AVDTune -Plan ([pscustomobject]@{ Name = "Printers $($Mode.ToLower())"; Steps = @($steps | ForEach-Object { $_.Id }) }) -Catalog @($steps) -Machine $Machine -Root $Root -User $User -SnapshotId $SnapshotId
    $changed = $false; $check = @()
    if ($Mode -eq 'Apply') {
        $now = (& $Machine.Now).ToString('o')
        $list = @{}; foreach ($i in @($state.Drivers)) { $list["$($i.Server)|$($i.Name)".ToLowerInvariant()] = $i }
        foreach ($r in @($run.Results)) {
            $info = $byStep[$r.Id]
            if ($r.Id -like 'printers.policy-*' -and $r.Status -eq 'Changed' -and -not $undo.Policy) { $undo.Policy = $policyBefore; $changed = $true }
            if (-not $info) { continue }
            $d = $info.Driver
            if ($r.Status -eq 'Changed' -and -not $info.Existed -and -not $undo.Drivers.ContainsKey($d.Name.ToLowerInvariant())) { $undo.Drivers[$d.Name.ToLowerInvariant()] = [ordered]@{ Name = $d.Name; Version = $d.Version; Server = $d.Server; Existed = $false }; $changed = $true }
            if ($r.Status -in 'Changed', 'Unchanged') { $list["$($d.Server)|$($d.Name)".ToLowerInvariant()] = [pscustomobject]@{ Name = $d.Name; Version = $d.Version; Server = $d.Server; Signer = [string]$d.Signer; Printers = @($d.Printers); At = $now } }
        }
        Save-AVDTunePrinterState -Root $Root -State ([pscustomobject]@{ Servers = $servers; Drivers = @($list.Values | Sort-Object Server, Name) })
        $check = @(Get-AVDTunePrinterDriverStatus -P $P -Drivers $Drivers)
    }
    else {
        foreach ($r in @($run.Results | Where-Object { $_.Status -in 'Changed', 'Unchanged' })) {
            if ($r.Id -like 'printers.undo-policy-*') { $undo.Policy = $null; $changed = $true }
            $info = $byStep[$r.Id]; if ($info) { $undo.Drivers.Remove($info.Key); $changed = $true }
        }
        if (@($run.Results | Where-Object { $_.Id -like 'printers.undo-policy-*' -and $_.Status -notin 'Changed', 'Unchanged' }).Count -gt 0 -and $null -eq $undo.Policy) { $undo.Policy = (Read-AVDTunePrinterUndo $Root).Policy }
    }
    if ($changed) { Write-AVDTunePrinterUndo $Root $undo }
    [pscustomobject]@{ Run = $run; Check = $check }
}

#endregion

#region real adapter

function New-AVDTunePrinterAdapter {
    <#
        The real adapter. NOT exercised by the checks beyond construction and command resolution: written from the documentation, to be tried on a throw-away VM.
        WinRM with Kerberos only (FQDN, UPN, -Authentication Kerberos): the server is authenticated by the KDC, no NTLM, no TrustedHosts. The PSCredential lives in memory only.
    #>
    $c = New-AVDTuneCustomAdapter
    $a = [ordered]@{ Kind = 'Real' }
    $a.RegGet = $c.RegGet; $a.RegSet = $c.RegSet; $a.RegRemove = $c.RegRemove
    $a.RegValues = {
        param($Path)
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
        try { $k = $base.OpenSubKey(($Path -replace '^HKLM:\\', ''), $false); if (-not $k) { return @() }; try { @($k.GetValueNames() | Where-Object { $_ }) } finally { $k.Dispose() } } finally { $base.Dispose() }
    }
    $map = { param($d) [pscustomobject]@{ Name = [string]$d.Name; Environment = [string]$d.PrinterEnvironment; Version = $d.DriverVersion; InfPath = [string]$d.InfPath; PackageAware = $(if ($d.PSObject.Properties['IsPackageAware']) { [bool]$d.IsPackageAware } else { $false }) } }
    $a.RemoteOpen = {
        param($Server, $Credential)
        if (-not $Credential) { throw 'The domain account is needed for the print server.' }
        $pc = New-Object Management.Automation.PSCredential([string]$Credential.User, $Credential.Password)
        New-PSSession -ComputerName $Server -Credential $pc -Authentication Kerberos -ErrorAction Stop
    }
    $a.RemoteClose = { param($Session) if ($Session) { Remove-PSSession -Session $Session -ErrorAction SilentlyContinue } }
    $a.RemotePrinters = { param($Session) @(Invoke-Command -Session $Session -ErrorAction Stop -ScriptBlock { @(Get-Printer -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ Name = [string]$_.Name; ShareName = [string]$_.ShareName; Shared = [bool]$_.Shared; DriverName = [string]$_.DriverName } }) }) }
    $a.RemoteDrivers = { param($Session) @(Invoke-Command -Session $Session -ErrorAction Stop -ScriptBlock { @(Get-PrinterDriver -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ Name = [string]$_.Name; PrinterEnvironment = [string]$_.PrinterEnvironment; DriverVersion = $_.DriverVersion; InfPath = [string]$_.InfPath; IsPackageAware = $(if ($_.PSObject.Properties['IsPackageAware']) { [bool]$_.IsPackageAware } else { $false }) } }) }) | ForEach-Object { & $map $_ } }.GetNewClosure()
    $a.LocalDrivers = { @(Get-PrinterDriver -ErrorAction Stop | ForEach-Object { & $map $_ }) }.GetNewClosure()
    $a.RemoteExport = {
        # a fixed block on the server: a new folder below Windows\Temp with an ACL for Administrators and SYSTEM only (N2), the oem<n>.inf of exactly this driver exported into it;
        # returns the folder, the folder that holds the INF (the copy source: INF and catalog on its top level) and its entries (relative path, size, link). A failure removes the folder.
        param($Session, $InfPath)
        Invoke-Command -Session $Session -ArgumentList $InfPath -ErrorAction Stop -ScriptBlock {
            param($Inf)
            $win = [Environment]::GetFolderPath('Windows')
            $dir = Join-Path $win ('Temp\AVDTune-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
            $sec = New-Object Security.AccessControl.DirectorySecurity
            $sec.SetAccessRuleProtection($true, $false)
            foreach ($sid in 'S-1-5-32-544', 'S-1-5-18') { $sec.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier $sid), 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow'))) }
            if ([IO.Directory]::Exists($dir)) { throw "$dir exists already." }
            [void][IO.Directory]::CreateDirectory($dir, $sec)
            try {
                $oem = @(Get-WindowsDriver -Online -ErrorAction Stop | Where-Object { $_.OriginalFileName -eq $Inf })[0]
                if (-not $oem) { throw 'The driver package of this INF is not in the driver store of the server.' }
                $null = & (Join-Path ([Environment]::GetFolderPath('System')) 'pnputil.exe') /export-driver $oem.Driver $dir
                if ($LASTEXITCODE -ne 0) { throw "pnputil /export-driver ended with $LASTEXITCODE." }
                $leaf = Split-Path $Inf -Leaf
                $hit = @(Get-ChildItem -LiteralPath $dir -Recurse -File -Filter $leaf -ErrorAction Stop)[0]
                if (-not $hit) { throw "The export has no $leaf." }
                $src = $hit.DirectoryName
                $files = @(Get-ChildItem -LiteralPath $src -Recurse -Force -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ Path = $_.FullName.Substring($src.Length).TrimStart('\'); Dir = [bool]$_.PSIsContainer; Length = $(if ($_.PSIsContainer) { 0 } else { $_.Length }); Link = (($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) } })
                [pscustomobject]@{ Folder = $dir; Source = $src; Files = $files }
            }
            catch { [IO.Directory]::Delete($dir, $true); throw }
        } | ForEach-Object { [pscustomobject]@{ Folder = [string]$_.Folder; Source = [string]$_.Source; Files = @($_.Files) } }
    }
    $a.RemoteReadFile = {
        # one file of the export (the path is built by Copy-AVDTunePrinterExport from the checked relative path); the server side refuses a link and anything over 100 MB
        param($Session, $Path)
        , [byte[]](Invoke-Command -Session $Session -ArgumentList $Path -ErrorAction Stop -ScriptBlock {
                param($f)
                $i = New-Object IO.FileInfo $f
                if (($i.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "$f is a link." }
                if ($i.Length -gt 100MB) { throw "$f is larger than 100 MB." }
                , [IO.File]::ReadAllBytes($f)
            })
    }
    $a.LocalMkdir = { param($Path) if (-not [IO.Directory]::Exists($Path)) { New-AVDTuneOwnFolder -Path $Path } elseif (([IO.File]::GetAttributes($Path) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "$Path is a link." } }
    $a.LocalWriteNew = {
        # a new file (CreateNew: an existing one, also a link put there, is never written through), inheriting the admin-only ACL of the work folder
        param($Path, [byte[]]$Bytes)
        $s = New-Object IO.FileStream($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $s.Write($Bytes, 0, $Bytes.Length); $s.Flush($true) } finally { $s.Dispose() }
    }
    $a.RemoteRemove = {
        # N2: only a folder AVDTune made: full path, parent exactly Windows\Temp, name AVDTune-<12 hex>; .NET deletes a link inside as a link and does not follow it
        param($Session, $Folder)
        Invoke-Command -Session $Session -ArgumentList $Folder -ErrorAction Stop -ScriptBlock {
            param($f)
            $full = [IO.Path]::GetFullPath($f)
            $parent = [IO.Path]::GetDirectoryName($full)
            if ($parent -ne (Join-Path ([Environment]::GetFolderPath('Windows')) 'Temp') -or [IO.Path]::GetFileName($full) -cnotmatch '\AAVDTune-[0-9a-f]{12}\z') { throw "$full is not a folder of AVDTune: not deleted." }
            if ([IO.Directory]::Exists($full)) { [IO.Directory]::Delete($full, $true) }
        }
    }
    $a.WorkFolder = { param($Root) New-AVDTuneDownloadFolder -Root $Root -Prefix 'printers' }
    $a.LocalTree = {
        # every entry below the folder, walked without following links (a link is listed and not entered)
        param($Folder)
        $out = New-Object System.Collections.ArrayList
        $todo = New-Object System.Collections.Stack; $todo.Push((New-Object IO.DirectoryInfo $Folder))
        while ($todo.Count -gt 0 -and $out.Count -le 5000) {
            foreach ($e in $todo.Pop().GetFileSystemInfos()) {
                $link = ($e.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
                [void]$out.Add([pscustomobject]@{ Path = $e.FullName; Length = $(if ($e -is [IO.FileInfo]) { $e.Length } else { 0 }); Link = $link })
                if ($e -is [IO.DirectoryInfo] -and -not $link) { $todo.Push($e) }
            }
        }
        @($out)
    }
    $a.ReadInf = { param($Path) $f = New-Object IO.FileInfo $Path; if ($f.Length -gt 1MB) { throw 'The INF is larger than 1 MB.' }; [IO.File]::ReadAllText($Path) }
    $a.CatalogSignature = {
        param($Path)
        $s = Get-AuthenticodeSignature -LiteralPath $Path
        $chainOk = $false
        if ($s.SignerCertificate) { $ch = New-Object Security.Cryptography.X509Certificates.X509Chain; try { $chainOk = $ch.Build($s.SignerCertificate) } finally { $ch.Dispose() } }
        [pscustomobject]@{ Status = [string]$s.Status; ChainOk = $chainOk; Subject = $(if ($s.SignerCertificate) { [string]$s.SignerCertificate.Subject } else { '' }); Issuer = $(if ($s.SignerCertificate) { [string]$s.SignerCertificate.Issuer } else { '' }); Thumbprint = $(if ($s.SignerCertificate) { [string]$s.SignerCertificate.Thumbprint } else { '' }) }
    }
    $a.AddDriverPackage = {
        # pnputil of the Windows folder through the central start (Open-AVDTuneSystemProgram: Windows signature, held while it runs; job object, timeout)
        param($Inf)
        $r = Invoke-AVDTuneProgram -File (Join-Path (Get-AVDTuneSystemFolder System) 'pnputil.exe') -Arguments @('/add-driver', $Inf) -TimeoutSeconds 300
        if ([int]$r.ExitCode -notin 0, 259, 3010) { throw "pnputil /add-driver ended with $($r.ExitCode): $(Remove-AVDTuneControlCharacters ([string]$r.Output) 300)" }
    }
    $a.AddDriver = { param($Name) Add-PrinterDriver -Name $Name -ErrorAction Stop }
    $a.RemoveDriver = { param($Name) Remove-PrinterDriver -Name $Name -ErrorAction Stop }
    $a.TrustedHostsSet = { param($Value) Set-Item -LiteralPath 'WSMan:\localhost\Client\TrustedHosts' -Value $Value -Force -ErrorAction Stop }
    $a.RemoveTree = { param($Path) if ($Path -and (Test-Path -LiteralPath $Path)) { [void](Remove-AVDTuneTreeSafe -Path $Path) } }
    [pscustomobject]$a
}

#endregion
