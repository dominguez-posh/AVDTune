<#
    AVDTune printer drivers from a print server (docs\plans\avdtune.md, section 3b; issue #86). Only for identity models with a domain; with Entra only the page
    points to Universal Print.

      * Print servers come from AD (printQueue objects, read over the existing LDAP connection of the start sequence) or are typed (a host name only, no UNC, no path).
      * The shared printers of the server with driver name, version, architecture and package-aware are read over the spooler RPC (Get-Printer/Get-PrinterDriver
        -ComputerName) with the domain account of the start sequence; no WinRM for reading.
      * The administrator picks printers (default: all shared); the needed drivers are the distinct x64 drivers of those printers.
      * Install per driver: package-aware by a temporary printer connection (Add-Printer -ConnectionName), which is removed again (the driver stays). Not
        package-aware: only this driver is exported on the server (pnputil /export-driver <oem>.inf over WinRM; TrustedHosts is appended and restored exactly,
        with a journal that the next start repairs), copied into an admin-only work folder, added with pnputil /add-driver and Add-PrinterDriver; temporary
        files are removed on both sides.
      * Point and Print: RestrictDriverInstallationToAdministrators = 1 and the package Point and Print server list limited to the chosen servers, with undo.
      * Every change is a step (New-AVDTuneStep) run through Invoke-AVDTune (write gate, change marker, run record, LastChange, change log). The test of a driver
        step is the check: the driver is installed with the version of the server. The change log text names driver, version, server and printers.
      * Maintenance (skeleton): Compare-AVDTunePrinterDrivers compares the server's versions with what AVDTune installed (config\printers.json): New, Changed, Same.
      * Every access to the server and the master goes through the printer adapter ($P): New-AVDTunePrinterAdapter is the real one (NOT exercised by the checks
        beyond construction, to be tried on a throw-away VM); Tests\Fakes\FakePrinters.ps1 is the fake. The password is a SecureString in memory only.
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

#region validation (pure)

function Test-AVDTunePrinterServerName([string]$Name) {
    # A host name (DNS or NetBIOS) only: no backslash, slash, colon, at sign, space or wildcard reaches a UNC path or WinRM
    if (-not $Name -or $Name.Length -gt 253) { return $false }
    Test-AVDTuneCustomHostName $Name
}

function Test-AVDTunePrinterShareName([string]$Name) { [bool]($Name -and $Name.Length -le 80 -and [regex]::IsMatch($Name, '\A[^\\/:*?"<>|\x00-\x1F]+\z', 'None', [TimeSpan]::FromMilliseconds(200)) -and $Name.Trim() -eq $Name -and $Name -notmatch '\A\.+\z') }

function Test-AVDTunePrinterInfPath([string]$Path) {
    # The INF path the server names for a driver: a local path on the server ending in .inf; it is only handed to the fixed remote block as data
    [bool]($Path -and $Path.Length -le 260 -and [regex]::IsMatch($Path, '\A[A-Za-z]:\\[^<>"|?*\x00-\x1F]+\.inf\z', 'IgnoreCase', [TimeSpan]::FromMilliseconds(200)) -and $Path -notmatch '\\\.\.(\\|\z)')
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

#endregion

#region reading

function Get-AVDTunePrinterAttr($Entry, [string]$Name) { $v = $Entry.Attributes[$Name]; if ($null -eq $v) { $null } else { @($v)[0] } }

function Find-AVDTunePrintServers {
    <# Read only: the print servers published in AD (printQueue objects) with the number of their printers. A name that is not a plain host name is left out and named. #>
    param([Parameter(Mandatory)]$Ldap, [Parameter(Mandatory)]$Connection)
    $root = @(& $Ldap.Search $Connection '' '(objectClass=*)' 'Base' @('defaultNamingContext'))
    $nc = if ($root.Count) { [string](Get-AVDTunePrinterAttr $root[0] 'defaultNamingContext') } else { '' }
    if (-not $nc) { throw 'The domain controller returned no defaultNamingContext.' }
    $queues = @(& $Ldap.Search $Connection $nc '(objectCategory=printQueue)' 'Subtree' @('serverName', 'shortServerName', 'printerName'))
    if ($queues.Count -gt $script:MaxQueues) { $queues = $queues[0..($script:MaxQueues - 1)] }
    $count = @{}; $skipped = New-Object System.Collections.ArrayList
    foreach ($q in $queues) {
        $s = [string](Get-AVDTunePrinterAttr $q 'serverName'); if (-not $s) { $s = [string](Get-AVDTunePrinterAttr $q 'shortServerName') }
        if (-not (Test-AVDTunePrinterServerName $s)) { if ($s) { [void]$skipped.Add((Remove-AVDTuneControlCharacters $s 80)) }; continue }
        $k = $s.ToLowerInvariant(); if ($count.ContainsKey($k)) { $count[$k]++ } else { $count[$k] = 1 }
    }
    [pscustomobject]@{ Servers = @($count.Keys | Sort-Object | ForEach-Object { [pscustomobject]@{ Name = $_; Printers = $count[$_] } }); Skipped = @($skipped | Select-Object -Unique) }
}

function Get-AVDTunePrinterInventory {
    <#
        Read only: the shared printers of the server with their x64 driver (name, version, architecture, package-aware, INF path) over the spooler RPC of the adapter.
        A printer whose driver has no x64 version on the server, or whose names are not valid, gets a Problem and is never installed.
    #>
    param([Parameter(Mandatory)]$P, [Parameter(Mandatory)][string]$Server, $Credential)
    if (-not (Test-AVDTunePrinterServerName $Server)) { throw "'$(Remove-AVDTuneControlCharacters $Server 80)' is not a host name of a print server (no UNC path, no path)." }
    $drivers = @{}
    foreach ($d in @(& $P.ServerDrivers $Server $Credential)) {
        $env = [string]$d.Environment
        $drivers["$([string]$d.Name)|$env".ToLowerInvariant()] = $d
    }
    $rows = foreach ($p in @(& $P.ServerPrinters $Server $Credential | Where-Object { $_.Shared })) {
        $name = Remove-AVDTuneControlCharacters ([string]$p.Name) 200; $drv = [string]$p.DriverName
        $d = $drivers["$drv|$($script:Arch)".ToLowerInvariant()]
        $problem = ''
        if (-not (Test-AVDTunePrinterShareName ([string]$p.ShareName))) { $problem = 'The share name is not valid.' }
        elseif (-not $drv -or $drv -ne (Remove-AVDTuneControlCharacters $drv 200)) { $problem = 'The driver name is not valid.' }
        elseif (-not $d) { $problem = "The server has no $($script:Arch) driver $drv." }
        $pa = if ($d) { [bool]$d.PackageAware } else { $false }
        $inf = if ($d) { [string]$d.InfPath } else { '' }
        if (-not $problem -and -not $pa -and -not (Test-AVDTunePrinterInfPath $inf)) { $problem = 'The server names no valid INF path for this driver.' }
        [pscustomobject]@{ Name = $name; ShareName = [string]$p.ShareName; Driver = $drv; Version = $(if ($d) { ConvertTo-AVDTunePrinterVersion $d.Version } else { '' })
            Architecture = $(if ($d) { $script:Arch } else { '' }); PackageAware = $pa; InfPath = $inf; Server = $Server.ToLowerInvariant(); Problem = $problem }
    }
    [pscustomobject]@{ Server = $Server.ToLowerInvariant(); Printers = @($rows | Sort-Object Name); At = (Get-Date).ToString('o') }
}

function Get-AVDTunePrinterDriverPlan {
    <# The distinct drivers of the selected printers (-Selected: printer names; empty = all shared printers without a problem), each with the printers that use it. #>
    param([Parameter(Mandatory)]$Inventory, [string[]]$Selected = @())
    $use = @($Inventory.Printers | Where-Object { -not $_.Problem -and ($Selected.Count -eq 0 -or $_.Name -in $Selected) })
    @($use | Group-Object Driver | Sort-Object Name | ForEach-Object {
            $f = $_.Group[0]
            [pscustomobject]@{ Name = $f.Driver; Version = $f.Version; Architecture = $f.Architecture; PackageAware = $f.PackageAware; InfPath = $f.InfPath; Server = $f.Server; Share = $f.ShareName; Printers = @($_.Group | ForEach-Object { $_.Name }) }
        })
}

function Get-AVDTunePrinterLocalVersion {
    # The installed x64 driver of that name on the master: its version, or '' when it is not there
    param([Parameter(Mandatory)]$P, [Parameter(Mandatory)][string]$Name)
    $d = @(& $P.LocalDrivers | Where-Object { [string]$_.Name -eq $Name -and [string]$_.Environment -eq 'Windows x64' })[0]
    if ($d) { ConvertTo-AVDTunePrinterVersion $d.Version } else { '' }
}

function Get-AVDTunePrinterDriverStatus {
    # Read only: each driver of the plan with the installed version and whether it matches the server (the check after the install)
    param([Parameter(Mandatory)]$P, [object[]]$Drivers)
    @($Drivers | ForEach-Object { $have = Get-AVDTunePrinterLocalVersion -P $P -Name $_.Name; [pscustomobject]@{ Name = $_.Name; Server = $_.Server; Version = $_.Version; Installed = $have; Ok = [bool]($have -and $have -eq $_.Version) } })
}

#endregion

#region state

function Get-AVDTunePrinterStatePath([string]$Root) { Join-Path $Root 'config\printers.json' }
function Get-AVDTunePrinterUndoPath([string]$Root) { Join-Path $Root 'config\printers-undo.json' }
function Get-AVDTunePrinterJournalPath([string]$Root) { Join-Path $Root 'config\printers-trustedhosts.json' }

function Get-AVDTunePrinterState {
    # config\printers.json: the chosen servers and the drivers AVDTune installed (name, version, server, printers, time); types checked, anything else is dropped
    param([string]$Root = (Get-AVDTuneRoot))
    $j = $null; try { $j = Read-AVDTuneJson (Get-AVDTunePrinterStatePath $Root) } catch { }
    $servers = @(@(Get-AVDTuneProp $j 'Servers') | Where-Object { $_ -is [string] -and (Test-AVDTunePrinterServerName $_) } | ForEach-Object { $_.ToLowerInvariant() } | Select-Object -Unique)
    $drivers = @(@(Get-AVDTuneProp $j 'Drivers') | Where-Object { $_ -and (Get-AVDTuneProp $_ 'Name') -is [string] -and (Get-AVDTuneProp $_ 'Version') -is [string] -and (Test-AVDTunePrinterServerName ([string](Get-AVDTuneProp $_ 'Server'))) } |
            ForEach-Object { [pscustomobject]@{ Name = $_.Name; Version = $_.Version; Server = ([string]$_.Server).ToLowerInvariant(); Printers = @(@(Get-AVDTuneProp $_ 'Printers') | Where-Object { $_ -is [string] }); At = [string](Get-AVDTuneProp $_ 'At') } })
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

#endregion

#region TrustedHosts (append, restore exactly, journal)

function Test-AVDTunePrinterTrustedHost([string]$List, [string]$Server) { @($List -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -eq '*' -or $_ -ieq $Server }).Count -gt 0 }

function Repair-AVDTunePrinterTrustedHosts {
    <# A journal left by a crash: TrustedHosts is set back to the value it had before AVDTune appended the server, then the journal goes. Returns $true when it repaired. #>
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

function Invoke-AVDTunePrinterTrustedHost {
    <#
        Runs -Block with the server in TrustedHosts: when it is not covered yet (exact name or *), the old value goes into a journal first, the server is appended,
        and in finally the old value is written back exactly; the journal goes only after that worked (else the next start repairs it).
    #>
    param([Parameter(Mandatory)]$P, [string]$Root = (Get-AVDTuneRoot), [Parameter(Mandatory)][string]$Server, [Parameter(Mandatory)][scriptblock]$Block)
    if (-not (Test-AVDTunePrinterServerName $Server)) { throw 'Not a host name.' }
    [void](Repair-AVDTunePrinterTrustedHosts -P $P -Root $Root)
    $old = [string](& $P.TrustedHostsGet)
    if (Test-AVDTunePrinterTrustedHost $old $Server) { return (& $Block) }
    $path = Get-AVDTunePrinterJournalPath $Root
    Write-AVDTuneFile $path ([ordered]@{ Schema = 1; Old = $old; Server = $Server; At = (Get-Date).ToString('o') } | ConvertTo-Json)
    $restored = $false
    try {
        & $P.TrustedHostsSet $(if ($old.Trim()) { "$old,$Server" } else { $Server })
        & $Block
    }
    finally {
        try { & $P.TrustedHostsSet $old; $restored = $true } catch { }
        if ($restored) { [void](Remove-AVDTuneTreeSafe -Path $path) }
    }
}

#endregion

#region install and steps

function Install-AVDTunePrinterDriverExport {
    <#
        A driver that is not package-aware: only its own INF and files are exported on the server (WinRM session of the adapter, TrustedHosts appended and restored),
        copied into an admin-only work folder below the state folder, added to the driver store (pnputil /add-driver) and installed as printer driver. The remote
        and the local temporary folder are removed in finally.
    #>
    param([Parameter(Mandatory)]$P, [Parameter(Mandatory)]$Driver, $Credential, [string]$Root = (Get-AVDTuneRoot))
    if (-not (Test-AVDTunePrinterInfPath $Driver.InfPath)) { throw "The server names no valid INF path for $($Driver.Name)." }
    $local = & $P.WorkFolder $Root
    try {
        $p = $P; $d = $Driver; $cred = $Credential; $dest = $local
        Invoke-AVDTunePrinterTrustedHost -P $P -Root $Root -Server $Driver.Server -Block {
            $s = & $p.RemoteOpen $d.Server $cred
            try {
                $folder = & $p.RemoteExport $s $d.InfPath
                try { & $p.RemoteCopy $s $folder $dest } finally { & $p.RemoteRemove $s $folder }
            }
            finally { & $p.RemoteClose $s }
        }.GetNewClosure()
        $inf = & $P.FindInf $local (Split-Path $Driver.InfPath -Leaf)
        if (-not $inf) { throw "The export of $($Driver.Name) has no $(Split-Path $Driver.InfPath -Leaf)." }
        & $P.AddDriverPackage $inf
        & $P.AddDriver $Driver.Name
    }
    finally { & $P.RemoveTree $local }
}

function Get-AVDTunePrinterStepId([string]$Name) {
    $h = [Security.Cryptography.SHA256]::Create()
    try { 'printers.driver-' + (([BitConverter]::ToString($h.ComputeHash([Text.Encoding]::UTF8.GetBytes($Name.ToLowerInvariant()))) -replace '-', '').Substring(0, 12).ToLowerInvariant()) } finally { $h.Dispose() }
}

function Get-AVDTunePrinterDriverTitle($Driver) {
    $pr = @($Driver.Printers); $list = $(if ($pr.Count) { @($pr[0..([Math]::Min(8, $pr.Count) - 1)]) -join ', ' } else { '-' }) + $(if ($pr.Count -gt 8) { ", +$($pr.Count - 8)" } else { '' })
    "Printer driver $($Driver.Name) $($Driver.Version) from $($Driver.Server) (printers: $list)"
}

function New-AVDTunePrinterDriverStep {
    <# The step of one driver: Test = installed with the version of the server (also the check after Apply); Apply = connection or export; Undo only for a driver AVDTune added. #>
    param([Parameter(Mandatory)]$Driver, [Parameter(Mandatory)]$P, $Credential, [string]$Root = (Get-AVDTuneRoot), $Before)
    $d = $Driver; $cred = $Credential; $r = $Root; $pp = $P
    $test = { param($m) $v = Get-AVDTunePrinterLocalVersion -P $pp -Name $d.Name; @{ Compliant = [bool]($v -and $v -eq $d.Version); State = $(if ($v) { $v } else { 'absent' }) } }.GetNewClosure()
    $apply = {
        param($m)
        if ($d.PackageAware) {
            if (-not (Test-AVDTunePrinterShareName $d.Share)) { throw 'The share name is not valid.' }
            & $pp.Connect $d.Server $d.Share $cred
            & $pp.Disconnect $d.Server $d.Share
        }
        else { Install-AVDTunePrinterDriverExport -P $pp -Driver $d -Credential $cred -Root $r }
    }.GetNewClosure()
    $undo = $null
    if ($Before -and -not [bool](Get-AVDTuneProp $Before 'Existed')) { $undo = { param($m) & $pp.RemoveDriver $d.Name }.GetNewClosure() }
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
        Apply: the drivers of -Drivers (Get-AVDTunePrinterDriverPlan) and, with -Policy, the Point and Print policies for the chosen servers (saved ones plus these), through
        Invoke-AVDTune. The state before is recorded for undo (an older record stays); config\printers.json gets every driver that is in place afterwards; Check lists
        each driver with the installed and the server version. Undo: the policies back to the record, drivers AVDTune added removed.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Machine, [Parameter(Mandatory)]$P, [string]$Root = (Get-AVDTuneRoot), [ValidateSet('Apply', 'Undo')][string]$Mode = 'Apply', [object[]]$Drivers = @(),
        $Credential, [switch]$Policy, [string]$User, [string]$SnapshotId)
    if (-not (Test-AVDTuneWriteAllowed)) { throw 'The snapshot gate is not confirmed: nothing is installed.' }
    $state = Get-AVDTunePrinterState -Root $Root
    $undo = Read-AVDTunePrinterUndo $Root
    $steps = New-Object System.Collections.ArrayList; $byStep = @{}
    if ($Mode -eq 'Apply') {
        foreach ($d in @($Drivers)) {
            if (-not (Test-AVDTunePrinterServerName $d.Server)) { throw "Not a host name: $($d.Server)." }
            $s = New-AVDTunePrinterDriverStep -Driver $d -P $P -Credential $Credential -Root $Root
            [void]$steps.Add($s); $byStep[$s.Id] = @{ Driver = $d; Existed = [bool](Get-AVDTunePrinterLocalVersion -P $P -Name $d.Name) }
        }
        $servers = @(@($state.Servers) + @($Drivers | ForEach-Object { $_.Server }) | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() } | Select-Object -Unique)
        $policyBefore = $null
        if ($Policy) { $policyBefore = Get-AVDTunePrinterPolicyBefore -P $P; foreach ($s in (New-AVDTunePrinterPolicySteps -P $P -Servers $servers)) { [void]$steps.Add($s) } }
    }
    else {
        if ($undo.Policy) { foreach ($s in (New-AVDTunePrinterPolicyUndoSteps -P $P -Before $undo.Policy)) { [void]$steps.Add($s) } }
        foreach ($k in @($undo.Drivers.Keys)) {
            $rec = $undo.Drivers[$k]
            $d = [pscustomobject]@{ Name = [string]$rec.Name; Version = [string]$rec.Version; Server = [string]$rec.Server; Share = ''; PackageAware = $true; InfPath = ''; Printers = @() }
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
            if ($r.Status -in 'Changed', 'Unchanged') { $list["$($d.Server)|$($d.Name)".ToLowerInvariant()] = [pscustomobject]@{ Name = $d.Name; Version = $d.Version; Server = $d.Server; Printers = @($d.Printers); At = $now } }
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
        The real adapter. NOT exercised by the checks beyond construction: written from the documentation, to be tried on a throw-away VM (the master is not domain joined:
        the domain account is used through LogonUser LOGON32_LOGON_NEW_CREDENTIALS, so the spooler RPC and the connection authenticate as that account; the password
        goes from the SecureString into unmanaged memory only for that call and is zeroed).
    #>
    $u = New-AVDTuneUpdateAdapter
    $c = New-AVDTuneCustomAdapter
    $a = [ordered]@{ Kind = 'Real' }
    $a.RegGet = $c.RegGet; $a.RegSet = $c.RegSet; $a.RegRemove = $c.RegRemove
    $a.RegValues = {
        param($Path)
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
        try { $k = $base.OpenSubKey(($Path -replace '^HKLM:\\', ''), $false); if (-not $k) { return @() }; try { @($k.GetValueNames() | Where-Object { $_ }) } finally { $k.Dispose() } } finally { $base.Dispose() }
    }
    $as = {
        # runs Block as the domain account for the network (LOGON32_LOGON_NEW_CREDENTIALS = 9, provider WINNT50 = 3); local rights stay the administrator's
        param($Credential, [scriptblock]$Block, [object[]]$ArgList = @())
        if (-not $Credential) { return (& $Block @ArgList) }
        Initialize-AVDTunePrinterLogon
        $parts = ([string]$Credential.User).Split([char]92, 2)
        $dom = if ($parts.Count -eq 2) { $parts[0] } else { '' }; $usr = $parts[-1]
        $ptr = [Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($Credential.Password)
        $token = [IntPtr]::Zero
        try { if (-not [AVDTune.PrinterLogon]::LogonUser($usr, $dom, $ptr, 9, 3, [ref]$token)) { throw "The domain account was refused (Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))." } }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocUnicode($ptr) }
        try {
            $ctx = [Security.Principal.WindowsIdentity]::Impersonate($token)
            try { & $Block @ArgList } finally { $ctx.Undo(); $ctx.Dispose() }
        }
        finally { [void][AVDTune.PrinterLogon]::CloseHandle($token) }
    }
    $map = { param($d) [pscustomobject]@{ Name = [string]$d.Name; Environment = [string]$d.PrinterEnvironment; Version = $d.DriverVersion; InfPath = [string]$d.InfPath; PackageAware = $(if ($d.PSObject.Properties['IsPackageAware']) { [bool]$d.IsPackageAware } else { $false }) } }
    $a.ServerPrinters = { param($Server, $Credential) & $as $Credential { param($s) @(Get-Printer -ComputerName $s -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ Name = [string]$_.Name; ShareName = [string]$_.ShareName; Shared = [bool]$_.Shared; DriverName = [string]$_.DriverName } }) } @($Server) }.GetNewClosure()
    $a.ServerDrivers = { param($Server, $Credential) & $as $Credential { param($s, $mp) @(Get-PrinterDriver -ComputerName $s -ErrorAction Stop | ForEach-Object { & $mp $_ }) } @($Server, $map) }.GetNewClosure()
    $a.LocalDrivers = { @(Get-PrinterDriver -ErrorAction Stop | ForEach-Object { & $map $_ }) }.GetNewClosure()
    $a.Connect = { param($Server, $Share, $Credential) & $as $Credential { param($n) Add-Printer -ConnectionName $n -ErrorAction Stop } @("\\$Server\$Share") }.GetNewClosure()
    $a.Disconnect = { param($Server, $Share) Remove-Printer -Name "\\$Server\$Share" -ErrorAction Stop }
    $a.AddDriver = { param($Name) Add-PrinterDriver -Name $Name -ErrorAction Stop }
    $a.RemoveDriver = { param($Name) Remove-PrinterDriver -Name $Name -ErrorAction Stop }
    $a.AddDriverPackage = {
        param($Inf)
        $exe = Join-Path (Get-AVDTuneSystemFolder System) 'pnputil.exe'
        $trust = Test-AVDTuneToolTrust -Signature (& $u.VerifySignature $exe) -Name 'pnputil.exe'
        if (-not $trust.Ok) { throw "pnputil is not trusted: $($trust.Reason)" }
        $r = & $u.Run $exe @('/add-driver', $Inf) 300
        if ([int]$r.ExitCode -notin 0, 259, 3010) { throw "pnputil /add-driver ended with $($r.ExitCode): $(Remove-AVDTuneControlCharacters ([string]$r.Output) 300)" }
    }.GetNewClosure()
    $a.TrustedHostsGet = { [string](Get-Item -LiteralPath 'WSMan:\localhost\Client\TrustedHosts' -ErrorAction Stop).Value }
    $a.TrustedHostsSet = { param($Value) Set-Item -LiteralPath 'WSMan:\localhost\Client\TrustedHosts' -Value $Value -Force -ErrorAction Stop }
    $a.RemoteOpen = {
        # WinRM with Negotiate (message encryption of the session); the PSCredential lives in memory only
        param($Server, $Credential)
        $pc = New-Object Management.Automation.PSCredential([string]$Credential.User, $Credential.Password)
        New-PSSession -ComputerName $Server -Credential $pc -Authentication Negotiate -ErrorAction Stop
    }
    $a.RemoteExport = {
        # a fixed block on the server: the oem<n>.inf of exactly this driver (by its INF path in the driver store) exported into a new folder below the Windows temp folder
        param($Session, $InfPath)
        Invoke-Command -Session $Session -ArgumentList $InfPath -ErrorAction Stop -ScriptBlock {
            param($Inf)
            $oem = @(Get-WindowsDriver -Online -ErrorAction Stop | Where-Object { $_.OriginalFileName -eq $Inf })[0]
            if (-not $oem) { throw 'The driver package of this INF is not in the driver store of the server.' }
            $win = [Environment]::GetFolderPath('Windows')
            $dir = Join-Path $win ('Temp\AVDTune-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
            [void](New-Item -ItemType Directory -Path $dir -ErrorAction Stop)
            $r = & (Join-Path ([Environment]::GetFolderPath('System')) 'pnputil.exe') /export-driver $oem.Driver $dir
            if ($LASTEXITCODE -ne 0) { throw "pnputil /export-driver ended with $LASTEXITCODE." }
            $dir
        }
    }
    $a.RemoteCopy = { param($Session, $Folder, $Local) Copy-Item -FromSession $Session -Path "$Folder\*" -Destination $Local -Recurse -ErrorAction Stop }
    $a.RemoteRemove = { param($Session, $Folder) Invoke-Command -Session $Session -ArgumentList $Folder -ErrorAction Stop -ScriptBlock { param($f) if ($f -like (Join-Path ([Environment]::GetFolderPath('Windows')) 'Temp\AVDTune-*')) { [IO.Directory]::Delete($f, $true) } } }   # on the server; .NET deletes a link inside as a link and does not follow it
    $a.RemoteClose = { param($Session) if ($Session) { Remove-PSSession -Session $Session -ErrorAction SilentlyContinue } }
    $a.WorkFolder = { param($Root) $d = Join-Path $Root ('temp\printers\' + [guid]::NewGuid().ToString('N').Substring(0, 12)); New-AVDTuneWorkFolder -Path $d -Base $Root; $d }
    $a.FindInf = {
        param($Folder, $Leaf)
        $hit = @(Get-ChildItem -LiteralPath $Folder -Recurse -File -Filter $Leaf -Attributes !ReparsePoint -ErrorAction Stop)[0]
        if ($hit) { $hit.FullName } else { $null }
    }
    $a.RemoveTree = { param($Path) if ($Path -and (Test-Path -LiteralPath $Path)) { [void](Remove-AVDTuneTreeSafe -Path $Path) } }
    [pscustomobject]$a
}

function Initialize-AVDTunePrinterLogon {
    if ('AVDTune.PrinterLogon' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace AVDTune {
    public static class PrinterLogon {
        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern bool LogonUser(string user, string domain, IntPtr password, int logonType, int provider, out IntPtr token);
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool CloseHandle(IntPtr handle);
    }
}
'@
}

#endregion
