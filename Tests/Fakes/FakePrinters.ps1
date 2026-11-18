# A fake printer adapter (Modules\AVDTune.Printers.psm1, $P) for the checks and the GUI smoke test: print servers reached by a (Kerberos) WinRM session with shared printers,
# drivers, their exports (files, catalog, signer), the drivers of the master, the registry and the local work folders, all in memory. Nothing here touches the computer.
# Dot-source this file, then: $p = New-AVDTuneFakePrinters [-Seed @{ ... }]
# Seed keys (all optional): Servers (FQDN -> @{ Printers = array of @{ Name; ShareName; Shared; DriverName }; Drivers = array of @{ Name; Environment; Version; InfPath;
# PackageAware; LocalPackageAware; Cat; Cat2 (a second catalog in the export); InfText (the INF as text); Signer = @{ Status; ChainOk; Subject; Issuer; Thumbprint } } }), Local (driver name -> version), Registry ('path|name' -> @{ Value; Kind }).
# Switches on .Store: FailExport, Unreachable (server: every session fails), BigExport (the export lists more bytes than allowed), EscapeExport (an entry '..\x'),
# LinkInCopy (the local copy has a link), NestedInf (the INF is not on the top level of the copy), SwapSigner (driver name -> other signer from the second export on).
# Log, Credentials (user names of the sessions), Auth (authentication of the sessions), Sessions, RemoteFolders, LocalFolders, Packages, TrustedHistory are recorded.
. $(if (Get-Command Resolve-AVDTuneTestScript -ErrorAction Ignore) { $fakeShared = Resolve-AVDTuneTestScript -Path (Join-Path $PSScriptRoot 'FakeShared.ps1') -AppRoot (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent); if (-not $fakeShared) { throw 'FakeShared.ps1 is not a file below the Tests folder of this copy.' }; $fakeShared } else { Join-Path $PSScriptRoot 'FakeShared.ps1' })   # fakes that several runspaces use at once (#80), through the test script gate when the module is loaded

function New-AVDTuneFakePrinters {
    param([hashtable]$Seed = @{})
    $whql = @{ Status = 'Valid'; ChainOk = $true; Subject = 'CN=Microsoft Windows Hardware Compatibility Publisher, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'; Issuer = 'CN=Microsoft Windows Third Party Component CA 2014, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'; Thumbprint = ('A1' * 20) }
    $vendor = @{ Status = 'Valid'; ChainOk = $true; Subject = 'CN=Example Labels Inc, O=Example Labels Inc, C=US'; Issuer = 'CN=Example Code Signing CA, O=Example CA'; Thumbprint = ('B2' * 20) }
    $store = @{
        Servers = @{
            'print1.example.test' = @{
                Printers = @(
                    @{ Name = 'Floor 1 Color'; ShareName = 'F1-Color'; Shared = $true; DriverName = 'Example Universal PCL6' }
                    @{ Name = 'Floor 2 Color'; ShareName = 'F2-Color'; Shared = $true; DriverName = 'Example Universal PCL6' }
                    @{ Name = 'Label Printer'; ShareName = 'Labels'; Shared = $true; DriverName = 'Example Label Driver' }
                    @{ Name = 'Front Desk'; ShareName = 'Front'; Shared = $true; DriverName = 'Example Unsigned Driver' }
                    @{ Name = 'Old Plotter'; ShareName = 'Plotter'; Shared = $true; DriverName = 'Example Plotter x86' }
                    @{ Name = 'Not Shared'; ShareName = ''; Shared = $false; DriverName = 'Example Universal PCL6' })
                Drivers = @(
                    @{ Name = 'Example Universal PCL6'; Environment = 'Windows x64'; Version = '7.1.0.2500'; InfPath = 'C:\Windows\System32\DriverStore\FileRepository\exupcl6.inf_amd64_1\exupcl6.inf'; PackageAware = $true; Cat = 'exupcl6.cat'; Signer = $whql }
                    @{ Name = 'Example Universal PCL6'; Environment = 'Windows NT x86'; Version = '7.1.0.2500'; InfPath = 'C:\Windows\System32\DriverStore\FileRepository\exupcl6.inf_x86_1\exupcl6.inf'; PackageAware = $true; Cat = 'exupcl6.cat'; Signer = $whql }
                    @{ Name = 'Example Label Driver'; Environment = 'Windows x64'; Version = '2.4.0.300'; InfPath = 'C:\Windows\System32\DriverStore\FileRepository\exlabel.inf_amd64_2\exlabel.inf'; PackageAware = $false; Cat = 'exlabel.cat'; Signer = $vendor }
                    @{ Name = 'Example Unsigned Driver'; Environment = 'Windows x64'; Version = '1.0.0.300'; InfPath = 'C:\Windows\System32\DriverStore\FileRepository\exunsig.inf_amd64_4\exunsig.inf'; PackageAware = $false; Cat = 'exunsig.cat'; Signer = @{ Status = 'NotSigned'; ChainOk = $false; Subject = ''; Issuer = ''; Thumbprint = '' } }
                    @{ Name = 'Example Plotter x86'; Environment = 'Windows NT x86'; Version = '1.0.0.300'; InfPath = 'C:\Windows\System32\DriverStore\FileRepository\explot.inf_x86_3\explot.inf'; PackageAware = $false; Cat = 'explot.cat'; Signer = $whql })
            }
        }
        Local = @{}; LocalPA = @{}; Registry = @{}; TrustedHosts = 'admin1.example.test'
        Log = (New-Object System.Collections.ArrayList); Credentials = (New-Object System.Collections.ArrayList); Auth = (New-Object System.Collections.ArrayList)
        Sessions = @{}; RemoteFolders = @{}; LocalFolders = @{}; Packages = @{}; TrustedHistory = (New-Object System.Collections.ArrayList)
        FailExport = $false; Unreachable = ''; BigExport = $false; EscapeExport = $false; LinkInCopy = $false; NestedInf = $false; SwapSigner = @{}; Exports = @{}; Next = 0
        Reads = (New-Object System.Collections.ArrayList); Mkdirs = (New-Object System.Collections.ArrayList); ReadDriver = $null; ReadLength = 0
        Whql = $whql; Vendor = $vendor
    }
    foreach ($k in $Seed.Keys) { $store[$k] = $Seed[$k] }
    $log = { param($t) [void]$store.Log.Add($t) }.GetNewClosure()
    $drvOf = { param($srv, $inf) foreach ($d in @($store.Servers[$srv].Drivers)) { if ($d.InfPath -eq $inf) { return $d } }; $null }.GetNewClosure()
    $folderOf = { param($path) foreach ($l in @($store.LocalFolders.Values)) { if ($l.Driver) { foreach ($f in @($l.Files)) { if ($f.Path -eq $path) { return $l } } } }; $null }.GetNewClosure()
    $p = [ordered]@{ Kind = 'Fake'; Store = $store }
    $p.RemoteOpen = {
        param($Server, $Credential)
        if (-not $Credential) { throw 'Access is denied.' }
        if ($store.Unreachable -and $Server -ieq $store.Unreachable) { throw "WinRM cannot reach $Server." }
        if (-not $store.Servers.ContainsKey($Server.ToLowerInvariant())) { throw "WinRM: Kerberos found no service principal for $Server." }
        [void]$store.Credentials.Add([string]$Credential.User); [void]$store.Auth.Add('Kerberos')
        $store.Next++; $id = "s$($store.Next)"; $store.Sessions[$id] = $Server.ToLowerInvariant(); & $log "RemoteOpen $Server"; $id
    }.GetNewClosure()
    $p.RemoteClose = { param($Session) $store.Sessions.Remove($Session); & $log 'RemoteClose' }.GetNewClosure()
    $p.RemotePrinters = { param($Session) & $log 'RemotePrinters'; $o = @(); foreach ($x in @($store.Servers[$store.Sessions[$Session]].Printers)) { $o += [pscustomobject]$x }; $o }.GetNewClosure()
    $p.RemoteDrivers = { param($Session) & $log 'RemoteDrivers'; $o = @(); foreach ($x in @($store.Servers[$store.Sessions[$Session]].Drivers)) { $o += [pscustomobject]@{ Name = $x.Name; Environment = $x.Environment; Version = $x.Version; InfPath = $x.InfPath; PackageAware = $x.PackageAware } }; $o }.GetNewClosure()
    $p.RemoteExport = {
        param($Session, $InfPath)
        if ($store.FailExport) { throw 'pnputil /export-driver ended with 5.' }
        $d = & $drvOf $store.Sessions[$Session] $InfPath
        if (-not $d) { throw 'The driver package of this INF is not in the driver store of the server.' }
        $inf = $InfPath.Substring($InfPath.LastIndexOf([char]92) + 1); if ($store.NestedInf) { $inf = "sub\$inf" }
        $files = @(@{ Path = $inf; Length = 4000; Link = $false }, @{ Path = $d.Cat; Length = 9000; Link = $false }, @{ Path = 'amd64'; Dir = $true; Length = 0; Link = $false }, @{ Path = 'amd64\driver.dll'; Length = 300000; Link = $false })
        if ($store.NestedInf) { $files += @{ Path = 'sub'; Dir = $true; Length = 0; Link = $false } }
        if ($d.ContainsKey('Cat2')) { $files += @{ Path = $d.Cat2; Length = 9000; Link = $false } }
        if ($store.BigExport) { $files += @{ Path = 'amd64\huge.bin'; Length = 600MB; Link = $false } }
        if ($store.EscapeExport) { $files += @{ Path = '..\evil.dll'; Length = 10; Link = $false } }
        $store.Next++; $f = "C:\Windows\Temp\AVDTune-$('{0:x12}' -f $store.Next)"; $store.RemoteFolders[$f] = @{ Driver = $d; Files = $files }
        $n = 0; if ($store.Exports.ContainsKey($d.Name)) { $n = $store.Exports[$d.Name] }; $store.Exports[$d.Name] = $n + 1
        & $log "RemoteExport $InfPath"
        $o = @(); foreach ($x in $files) { $o += [pscustomobject]$x }
        [pscustomobject]@{ Folder = $f; Source = $f; Files = $o }
    }.GetNewClosure()
    $p.RemoteReadFile = {
        param($Session, $Path)
        foreach ($k in @($store.RemoteFolders.Keys)) {
            if ($Path.StartsWith($k + '\')) {
                $r = $store.RemoteFolders[$k]; $rel = $Path.Substring($k.Length + 1)
                foreach ($x in @($r.Files)) { if ($x.Path -eq $rel) { $store.ReadDriver = $r.Driver; $store.ReadLength = $x.Length; [void]$store.Reads.Add($rel); return , (New-Object byte[] 4) } }
            }
        }
        throw "No file $Path in an export."
    }.GetNewClosure()
    $p.LocalMkdir = { param($Path) [void]$store.Mkdirs.Add($Path) }.GetNewClosure()
    $p.LocalWriteNew = {
        param($Path, [byte[]]$Bytes)
        foreach ($k in @($store.LocalFolders.Keys)) {
            if ($Path.StartsWith($k + '\')) {
                $l = $store.LocalFolders[$k]
                foreach ($x in @($l.Files)) { if ($x.Path -eq $Path) { throw "The file '$Path' exists." } }
                $l.Driver = $store.ReadDriver; $l.Files += @{ Path = $Path; Length = $store.ReadLength; Link = $false }; return
            }
        }
        throw "$Path is not in a work folder."
    }.GetNewClosure()
    $p.RemoteRemove = { param($Session, $Folder) $store.RemoteFolders.Remove($Folder); & $log "RemoteRemove $Folder" }.GetNewClosure()
    $p.WorkFolder = { param($Root) $store.Next++; $d = $Root.TrimEnd([char]92) + "\temp\printers-w$($store.Next)"; $store.LocalFolders[$d] = @{ Driver = $null; Files = @() }; $d }.GetNewClosure()
    $p.LocalTree = { param($Folder) $l = $store.LocalFolders[$Folder]; if (-not $l) { return @() }; $o = @(); foreach ($x in @($l.Files)) { $o += [pscustomobject]$x }; if ($store.LinkInCopy) { $o += [pscustomobject]@{ Path = ($Folder.TrimEnd([char]92) + '\amd64\link'); Length = 0; Link = $true } }; $o }.GetNewClosure()
    $p.ReadInf = { param($Path) $l = & $folderOf $Path; if (-not $l) { throw "No INF $Path." }; if ($l.Driver.ContainsKey('InfText')) { return $l.Driver.InfText }; "[Version]`r`nSignature=`"`$Windows NT`$`"`r`nCatalogFile.NTamd64=$($l.Driver.Cat)`r`n" }.GetNewClosure()
    $p.CatalogSignature = {
        param($Path)
        $l = & $folderOf $Path; if (-not $l) { throw "No catalog $Path." }
        $d = $l.Driver; $s = $d.Signer
        if ($store.SwapSigner.ContainsKey($d.Name) -and $store.Exports[$d.Name] -gt 1) { $s = $store.SwapSigner[$d.Name] }
        [pscustomobject]$s
    }.GetNewClosure()
    $p.AddDriverPackage = { param($Inf) $l = & $folderOf $Inf; if (-not $l) { throw "pnputil: $Inf not found." }; $store.Packages[$l.Driver.Name] = $l.Driver; & $log "AddDriverPackage $Inf" }.GetNewClosure()
    $p.AddDriver = {
        param($Name)
        $d = $store.Packages[$Name]; if (-not $d) { throw "The driver $Name is not in the driver store." }
        $store.Local[$Name] = $d.Version
        $store.LocalPA[$Name] = $(if ($d.ContainsKey('LocalPackageAware')) { [bool]$d.LocalPackageAware } else { [bool]$d.PackageAware })
        & $log "AddDriver $Name"
    }.GetNewClosure()
    $p.RemoveDriver = { param($Name) $store.Local.Remove($Name); & $log "RemoveDriver $Name" }.GetNewClosure()
    $p.LocalDrivers = {
        $o = @()
        foreach ($n in @($store.Local.Keys)) {
            $leaf = ($n -replace '[^A-Za-z0-9]', '').ToLowerInvariant()
            $o += [pscustomobject]@{ Name = $n; Environment = 'Windows x64'; Version = $store.Local[$n]; InfPath = "C:\Windows\System32\DriverStore\FileRepository\$leaf.inf_amd64_9\$leaf.inf"; PackageAware = [bool]$store.LocalPA[$n] }
        }
        $o
    }.GetNewClosure()
    $p.TrustedHostsSet = { param($Value) [void]$store.TrustedHistory.Add($Value); $store.TrustedHosts = $Value }.GetNewClosure()
    $p.RemoveTree = { param($Path) $store.LocalFolders.Remove($Path); & $log "RemoveTree $Path" }.GetNewClosure()
    $p.RegGet = { param($Path, $Name) $k = "$Path|$Name".ToLowerInvariant(); if ($store.Registry.ContainsKey($k)) { $store.Registry[$k] } else { $null } }.GetNewClosure()
    $p.RegSet = { param($Path, $Name, $Value, $Type) $store.Registry["$Path|$Name".ToLowerInvariant()] = @{ Value = $Value; Kind = [string]$Type }; & $log "RegSet $Path|$Name" }.GetNewClosure()
    $p.RegRemove = { param($Path, $Name) $store.Registry.Remove("$Path|$Name".ToLowerInvariant()); & $log "RegRemove $Path|$Name" }.GetNewClosure()
    $p.RegValues = { param($Path) $pre = "$Path|".ToLowerInvariant(); $o = @(); foreach ($k in @($store.Registry.Keys)) { if ($k.StartsWith($pre)) { $o += $k.Substring($pre.Length) } }; $o }.GetNewClosure()
    ConvertTo-AVDTuneFakeShared ([pscustomobject]$p)
}
