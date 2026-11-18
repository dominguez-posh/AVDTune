# A fake printer adapter (Modules\AVDTune.Printers.psm1, $P) for the checks and the GUI smoke test: print servers with shared printers and drivers, the drivers of the
# master, the registry, TrustedHosts, WinRM sessions with their remote folders and the local work folders, all in memory. Nothing here touches the computer it runs on.
# Dot-source this file, then: $p = New-AVDTuneFakePrinters [-Seed @{ ... }]
# Seed keys (all optional): Servers (name -> @{ Printers = array of @{ Name; ShareName; Shared; DriverName }; Drivers = array of @{ Name; Environment; Version; InfPath; PackageAware } }),
# Local (driver name -> version), Registry ('path|name' -> @{ Value; Kind }), TrustedHosts (text).
# Switches on .Store: FailExport (the export on the server throws), FailRestore (setting TrustedHosts back throws once), Unreachable (server name: every RPC throws),
# NeedAccount (a read without credential throws). Log, Credentials (user names seen), Sessions, RemoteFolders, LocalFolders, Connections, Packages are recorded.

function New-AVDTuneFakePrinters {
    param([hashtable]$Seed = @{})
    $store = @{
        Servers = @{
            'print1.example.test' = @{
                Printers = @(
                    @{ Name = 'Floor 1 Color'; ShareName = 'F1-Color'; Shared = $true; DriverName = 'Example Universal PCL6' }
                    @{ Name = 'Floor 2 Color'; ShareName = 'F2-Color'; Shared = $true; DriverName = 'Example Universal PCL6' }
                    @{ Name = 'Label Printer'; ShareName = 'Labels'; Shared = $true; DriverName = 'Example Label Driver' }
                    @{ Name = 'Old Plotter'; ShareName = 'Plotter'; Shared = $true; DriverName = 'Example Plotter x86' }
                    @{ Name = 'Not Shared'; ShareName = ''; Shared = $false; DriverName = 'Example Universal PCL6' })
                Drivers = @(
                    @{ Name = 'Example Universal PCL6'; Environment = 'Windows x64'; Version = '7.1.0.2500'; InfPath = 'C:\Windows\System32\DriverStore\FileRepository\exupcl6.inf_amd64_1\exupcl6.inf'; PackageAware = $true }
                    @{ Name = 'Example Universal PCL6'; Environment = 'Windows NT x86'; Version = '7.1.0.2500'; InfPath = 'C:\Windows\System32\DriverStore\FileRepository\exupcl6.inf_x86_1\exupcl6.inf'; PackageAware = $true }
                    @{ Name = 'Example Label Driver'; Environment = 'Windows x64'; Version = '2.4.0.300'; InfPath = 'C:\Windows\System32\DriverStore\FileRepository\exlabel.inf_amd64_2\exlabel.inf'; PackageAware = $false }
                    @{ Name = 'Example Plotter x86'; Environment = 'Windows NT x86'; Version = '1.0.0.300'; InfPath = 'C:\Windows\System32\DriverStore\FileRepository\explot.inf_x86_3\explot.inf'; PackageAware = $false })
            }
        }
        Local = @{}; Registry = @{}; TrustedHosts = 'admin1.example.test'
        Log = (New-Object System.Collections.ArrayList); Credentials = (New-Object System.Collections.ArrayList)
        Sessions = @{}; RemoteFolders = @{}; LocalFolders = @{}; Connections = @{}; Packages = @{}; TrustedHistory = (New-Object System.Collections.ArrayList)
        FailExport = $false; FailRestore = $false; Unreachable = ''; NeedAccount = $true; Next = 0
    }
    foreach ($k in $Seed.Keys) { $store[$k] = $Seed[$k] }
    $log = { param($t) [void]$store.Log.Add($t) }.GetNewClosure()
    $srv = {
        param($Server, $Credential)
        if ($store.Unreachable -and $Server -ieq $store.Unreachable) { throw "The RPC server is unavailable ($Server)." }
        if ($store.NeedAccount -and -not $Credential) { throw 'Access is denied.' }
        if ($Credential) { [void]$store.Credentials.Add([string]$Credential.User) }
        $s = $store.Servers[$Server.ToLowerInvariant()]; if (-not $s) { throw "The RPC server is unavailable ($Server)." }
        $s
    }.GetNewClosure()
    $p = [ordered]@{ Kind = 'Fake'; Store = $store }
    $p.ServerPrinters = { param($Server, $Credential) $s = & $srv $Server $Credential; & $log "ServerPrinters $Server"; @($s.Printers | ForEach-Object { [pscustomobject]$_ }) }.GetNewClosure()
    $p.ServerDrivers = { param($Server, $Credential) $s = & $srv $Server $Credential; & $log "ServerDrivers $Server"; @($s.Drivers | ForEach-Object { [pscustomobject]$_ }) }.GetNewClosure()
    $p.LocalDrivers = { @($store.Local.Keys | ForEach-Object { [pscustomobject]@{ Name = $_; Environment = 'Windows x64'; Version = $store.Local[$_]; InfPath = ''; PackageAware = $true } }) }.GetNewClosure()
    $p.Connect = {
        # a connection downloads exactly the package of the server's driver of that printer (package-aware only)
        param($Server, $Share, $Credential)
        $s = & $srv $Server $Credential
        $pr = @($s.Printers | Where-Object { $_.ShareName -eq $Share })[0]; if (-not $pr) { throw "The printer \\$Server\$Share does not exist." }
        $d = @($s.Drivers | Where-Object { $_.Name -eq $pr.DriverName -and $_.Environment -eq 'Windows x64' })[0]
        if (-not $d.PackageAware) { throw 'The driver is not package-aware: Point and Print refuses it.' }
        $store.Connections["\\$Server\$Share".ToLowerInvariant()] = $true; $store.Local[$d.Name] = $d.Version; & $log "Connect \\$Server\$Share"
    }.GetNewClosure()
    $p.Disconnect = { param($Server, $Share) $store.Connections.Remove("\\$Server\$Share".ToLowerInvariant()); & $log "Disconnect \\$Server\$Share" }.GetNewClosure()
    $p.AddDriver = {
        param($Name)
        $pkg = @($store.Packages.Values | Where-Object { $_.Name -eq $Name })[0]
        if (-not $pkg) { throw "The driver $Name is not in the driver store." }
        $store.Local[$Name] = $pkg.Version; & $log "AddDriver $Name"
    }.GetNewClosure()
    $p.RemoveDriver = { param($Name) $store.Local.Remove($Name); & $log "RemoveDriver $Name" }.GetNewClosure()
    # no Select-Object -First in these closures: its pipeline stop hangs when the page job's runspace calls a closure of the window's runspace
    $p.AddDriverPackage = { param($Inf) $f = @(@($store.LocalFolders.Values) | Where-Object { $_.Inf -eq $Inf })[0]; if (-not $f) { throw "pnputil: $Inf not found." }; $store.Packages[$Inf] = @{ Name = $f.Driver; Version = $f.Version }; & $log "AddDriverPackage $Inf" }.GetNewClosure()
    $p.TrustedHostsGet = { $store.TrustedHosts }.GetNewClosure()
    $p.TrustedHostsSet = { param($Value) if ($store.FailRestore -and $Value -eq $store.TrustedHosts.Split(',')[0] -and $store.TrustedHosts.Contains(',')) { $store.FailRestore = $false; throw 'WinRM refused the change (fake).' }; [void]$store.TrustedHistory.Add($Value); $store.TrustedHosts = $Value }.GetNewClosure()
    $p.RemoteOpen = {
        param($Server, $Credential)
        $th = @($store.TrustedHosts -split ',' | ForEach-Object { $_.Trim() })
        if (-not ($th -icontains $Server -or $th -contains '*')) { throw "WinRM: $Server is not in TrustedHosts." }
        [void](& $srv $Server $Credential); $store.Next++; $id = "s$($store.Next)"; $store.Sessions[$id] = $Server; & $log "RemoteOpen $Server"; $id
    }.GetNewClosure()
    $p.RemoteExport = {
        param($Session, $InfPath)
        if ($store.FailExport) { throw 'pnputil /export-driver ended with 5.' }
        $s = $store.Servers[$store.Sessions[$Session]]
        $d = @($s.Drivers | Where-Object { $_.InfPath -eq $InfPath })[0]; if (-not $d) { throw 'The driver package of this INF is not in the driver store of the server.' }
        $store.Next++; $f = "C:\Windows\Temp\AVDTune-$($store.Next)"; $store.RemoteFolders[$f] = @{ Driver = $d.Name; Version = $d.Version; Inf = (Split-Path $InfPath -Leaf) }; & $log "RemoteExport $InfPath"; $f
    }.GetNewClosure()
    $p.RemoteCopy = { param($Session, $Folder, $Local) $r = $store.RemoteFolders[$Folder]; $l = $store.LocalFolders[$Local]; $l.Driver = $r.Driver; $l.Version = $r.Version; $l.Inf = Join-Path $Local $r.Inf; & $log "RemoteCopy $Folder" }.GetNewClosure()
    $p.RemoteRemove = { param($Session, $Folder) $store.RemoteFolders.Remove($Folder); & $log "RemoteRemove $Folder" }.GetNewClosure()
    $p.RemoteClose = { param($Session) $store.Sessions.Remove($Session); & $log 'RemoteClose' }.GetNewClosure()
    $p.WorkFolder = { param($Root) $store.Next++; $d = Join-Path $Root "temp\printers\w$($store.Next)"; $store.LocalFolders[$d] = @{ Driver = ''; Version = ''; Inf = '' }; $d }.GetNewClosure()
    $p.FindInf = { param($Folder, $Leaf) $l = $store.LocalFolders[$Folder]; if ($l -and $l.Inf -and (Split-Path $l.Inf -Leaf) -eq $Leaf) { $l.Inf } else { $null } }.GetNewClosure()
    $p.RemoveTree = { param($Path) $store.LocalFolders.Remove($Path); & $log "RemoveTree $Path" }.GetNewClosure()
    $p.RegGet = { param($Path, $Name) $k = "$Path|$Name".ToLowerInvariant(); if ($store.Registry.ContainsKey($k)) { $store.Registry[$k] } else { $null } }.GetNewClosure()
    $p.RegSet = { param($Path, $Name, $Value, $Type) $store.Registry["$Path|$Name".ToLowerInvariant()] = @{ Value = $Value; Kind = [string]$Type }; & $log "RegSet $Path|$Name" }.GetNewClosure()
    $p.RegRemove = { param($Path, $Name) $store.Registry.Remove("$Path|$Name".ToLowerInvariant()); & $log "RegRemove $Path|$Name" }.GetNewClosure()
    $p.RegValues = { param($Path) $pre = "$Path|".ToLowerInvariant(); @($store.Registry.Keys | Where-Object { $_.StartsWith($pre) } | ForEach-Object { $_.Substring($pre.Length) }) }.GetNewClosure()
    [pscustomobject]$p
}
