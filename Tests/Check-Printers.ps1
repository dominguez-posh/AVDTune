#requires -Version 5.1
<#
.SYNOPSIS
    Checks the printer drivers from a print server (Modules\AVDTune.Printers.psm1, issue #86, plan 3b) against the fake printer adapter, the fake LDAP, the fake machine
    and a temporary state folder: validation (FQDN, no IP, UPN, share, driver name without wildcards, INF path, version), print servers only from AD, the Kerberos session,
    the inventory with the checked export of every driver (limits, links, INF and catalog on the top level, WHQL or an allowed signer, unsigned refused), the plan, Apply
    through Invoke-AVDTune only by export (no printer connection), the confirmed signer and plan (M1), the local check (driver store, package-aware as installed),
    Point and Print with undo and the unsafe values (N4), the repair of a TrustedHosts journal of the first version, maintenance and source checks. Nothing touches this computer.
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
foreach ($m in 'AVDTune', 'AVDTune.UpdateBlock', 'AVDTune.Updates', 'AVDTune.Directory', 'AVDTune.Custom', 'AVDTune.Printers') { Import-Module (Join-Path $repo "Modules\$m.psm1") -Force }
. (Join-Path $PSScriptRoot 'Fakes\FakeMachine.ps1')
. (Join-Path $PSScriptRoot 'Fakes\FakeServices.ps1')
. (Join-Path $PSScriptRoot 'Fakes\FakePrinters.ps1')

$script:failed = 0
function Test-Check([string]$Name, [bool]$Ok, $Detail) { if ($Ok) { "PASS $Name" } else { $script:failed++; "FAIL $Name" + $(if ($null -ne $Detail) { "  -> $Detail" }) } }
function Get-ThrownText([scriptblock]$Block) { try { & $Block | Out-Null; $null } catch { $_.Exception.Message } }
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('avdtune-printers-' + [guid]::NewGuid().ToString('N'))
$pw = New-Object Security.SecureString; foreach ($ch in 'not-a-real-secret'.ToCharArray()) { $pw.AppendChar($ch) }
$cred = [pscustomobject]@{ User = 'admin1@example.test'; Password = $pw }
$srv = 'print1.example.test'
function Read-Inventory($P, [string]$Root, [object[]]$Signers = @()) {
    Invoke-AVDTunePrinterSession -P $P -Server $srv -Credential $cred -Block { param($s) $i = Get-AVDTunePrinterInventory -P $P -Session $s -Server $srv; Add-AVDTunePrinterSignatures -P $P -Session $s -Inventory $i -Root $Root -Signers $Signers }
}
function Get-Printer1($Inv, [string]$Name) { @($Inv.Printers | Where-Object { $_.Name -eq $Name })[0] }

try {
    $env:AVDTUNE_ROOT = $tmp
    [void](Initialize-AVDTuneState -Root $tmp)
    [void](Start-AVDTuneImageVersion -Root $tmp -Date ([datetime]'2026-11-18') -User 'admin1')
    Close-AVDTuneWriteGate
    $m = New-AVDTuneFakeMachine

    # ---------------------------------------------------------------- validation
    $badNames = @('print1', '\\print1.example.test', 'print1.example.test\share', 'print1.example.test:5985', 'admin@print1.example.test', 'print 1.example.test', '*', '', '192.0.2.10', ('a' * 250 + '.test'))
    Test-Check 'server name (H1): only an FQDN (no short name, IP address, UNC, port, user, space, wildcard)' ((Test-AVDTunePrinterServerName $srv) -and @($badNames | Where-Object { Test-AVDTunePrinterServerName $_ }).Count -eq 0) (@($badNames | Where-Object { Test-AVDTunePrinterServerName $_ }) -join ' | ')
    Test-Check 'server (H1): a typed server is used only when AD publishes it; an IP address is refused' ($null -eq (Get-ThrownText { Assert-AVDTunePrinterServerAllowed -Server 'PRINT1.example.test' -Allowed @($srv) }) -and (Get-ThrownText { Assert-AVDTunePrinterServerAllowed -Server 'other.example.test' -Allowed @($srv) }) -like '*not a print server published in AD*' -and (Get-ThrownText { Assert-AVDTunePrinterServerAllowed -Server '192.0.2.10' -Allowed @('192.0.2.10') }) -like '*not the FQDN*') $null
    Test-Check 'account (H1): Kerberos gets the UPN (DOMAIN\user with the DNS domain of the directory), anything else is refused' ((ConvertTo-AVDTunePrinterUpn 'a@example.test') -eq 'a@example.test' -and (ConvertTo-AVDTunePrinterUpn 'EXAMPLE\a' -DnsDomain 'example.test') -eq 'a@example.test' -and (Get-ThrownText { ConvertTo-AVDTunePrinterUpn 'EXAMPLE\a' }) -like '*UPN*' -and (Get-ThrownText { ConvertTo-AVDTunePrinterUpn 'a b' }) -like '*UPN*') $null
    Test-Check 'driver name (N3): wildcards * ? [ ], control characters and long names refused' ((Test-AVDTunePrinterDriverName 'Example Universal PCL6') -and @(@('Bad*', 'Ba?d', 'Bad[1]', "Bad`n", ('x' * 201), ' Bad') | Where-Object { Test-AVDTunePrinterDriverName $_ }).Count -eq 0) $null
    Test-Check 'share name and INF path: separators, .. and control characters refused' ((Test-AVDTunePrinterShareName 'F1-Color') -and -not (Test-AVDTunePrinterShareName 'a\b') -and -not (Test-AVDTunePrinterShareName '..') -and (Test-AVDTunePrinterInfPath 'C:\Windows\INF\oem5.inf') -and -not (Test-AVDTunePrinterInfPath '\\x\y\a.inf') -and -not (Test-AVDTunePrinterInfPath 'C:\a\..\b.inf') -and -not (Test-AVDTunePrinterInfPath 'C:\a\b.exe')) $null
    $u64 = ([uint64]7 -shl 48) + ([uint64]1 -shl 32) + ([uint64]0 -shl 16) + 2500
    Test-Check 'driver version: the UInt64 of Get-PrinterDriver becomes a.b.c.d, anything else is empty' ((ConvertTo-AVDTunePrinterVersion $u64) -eq '7.1.0.2500' -and (ConvertTo-AVDTunePrinterVersion '2.4.0.300') -eq '2.4.0.300' -and (ConvertTo-AVDTunePrinterVersion 'x') -eq '' -and (ConvertTo-AVDTunePrinterVersion ('9' * 40)) -eq '') $null
    Test-Check 'availability: a domain controller in the answers opens the page; Entra only means Universal Print' ((Get-AVDTunePrinterAvailability ([pscustomobject]@{ Dc = 'AdDsOnPrem' })).Domain -and -not (Get-AVDTunePrinterAvailability ([pscustomobject]@{ Dc = 'None' })).Domain -and -not (Get-AVDTunePrinterAvailability $null).Domain) $null

    # ---------------------------------------------------------------- AD, session, inventory with the checked export (read only)
    $ldap = New-AVDTuneFakeLdap
    $found = Find-AVDTunePrintServers -Ldap $ldap -Connection 'c'
    Test-Check 'AD: the print servers (FQDN) of the printQueue objects with their printer count; a name that is not an FQDN is left out and named' (((@($found.Servers | ForEach-Object { "$($_.Name)=$($_.Printers)" })) -join ',') -eq 'print1.example.test=2,print2.example.test=1' -and @($found.Skipped).Count -eq 1) ((@($found.Servers | ForEach-Object { "$($_.Name)=$($_.Printers)" })) -join ',')
    $p = New-AVDTuneFakePrinters
    Test-Check 'session (H1): without the domain account no session; every session is Kerberos with the UPN' ((Get-ThrownText { Invoke-AVDTunePrinterSession -P $p -Server $srv -Credential $null -Block { } }) -like '*denied*') $null
    $inv = Read-Inventory $p $tmp
    $st = $p.Store
    $pcl = Get-Printer1 $inv 'Floor 1 Color'; $lab = Get-Printer1 $inv 'Label Printer'; $front = Get-Printer1 $inv 'Front Desk'; $plot = Get-Printer1 $inv 'Old Plotter'
    Test-Check 'inventory: the shared printers through the Kerberos session with driver, version, architecture, package-aware claim; the server is read only through WinRM' ($inv.Printers.Count -eq 5 -and $pcl.Version -eq '7.1.0.2500' -and $pcl.Architecture -eq 'Windows x64' -and $pcl.PackageAware -and @($st.Auth | Where-Object { $_ -ne 'Kerberos' }).Count -eq 0 -and @($st.Credentials | Where-Object { $_ -ne 'admin1@example.test' }).Count -eq 0 -and $st.Sessions.Count -eq 0) (($inv.Printers | ForEach-Object { "$($_.Name)|$($_.Problem)" }) -join ' ; ')
    Test-Check 'signature (H2): a WHQL driver is allowed with its signer; a vendor-signed driver is listed but not allowed (the window asks); an unsigned driver is a problem; no x64 driver is a problem' ($pcl.Allowed -and $pcl.Whql -and $pcl.Signer -like 'CN=Microsoft Windows Hardware Compatibility Publisher*' -and -not $lab.Allowed -and -not $lab.Problem -and $lab.Thumbprint -eq ('B2' * 20) -and $front.Problem -like '*no valid signature*' -and $plot.Problem -like '*no Windows x64 driver*') "$($lab.Problem) / $($front.Problem)"
    Test-Check 'export (N1/N2): every local copy and every remote folder of the read is removed, the sessions are closed' ($st.LocalFolders.Count -eq 0 -and $st.RemoteFolders.Count -eq 0 -and $st.Sessions.Count -eq 0 -and @($st.Log | Where-Object { $_ -like 'RemoteExport *' }).Count -eq 3) ($st.Log -join ' | ')
    $plan = @(Get-AVDTunePrinterDriverPlan -Inventory $inv)
    Test-Check 'plan: default all selectable printers, the distinct drivers with their printers and signers; unsigned and x86-only are never in it' ((@($plan | ForEach-Object { $_.Name }) -join ',') -eq 'Example Label Driver,Example Universal PCL6' -and (@($plan | Where-Object { $_.Name -eq 'Example Universal PCL6' })[0].Printers -join ',') -eq 'Floor 1 Color,Floor 2 Color') (@($plan | ForEach-Object { $_.Name }) -join ',')
    foreach ($case in @(@('BigExport', '*more than*'), @('EscapeExport', '*not allowed or a link*'), @('LinkInCopy', '*is a link*'), @('NestedInf', '*not on the top level*'))) {
        $px = New-AVDTuneFakePrinters; $px.Store[$case[0]] = $true
        $ix = Read-Inventory $px $tmp
        Test-Check "export (N1): $($case[0]) makes the driver a problem, nothing is left on either side" ((Get-Printer1 $ix 'Floor 1 Color').Problem -like $case[1] -and $px.Store.LocalFolders.Count -eq 0 -and $px.Store.RemoteFolders.Count -eq 0) (Get-Printer1 $ix 'Floor 1 Color').Problem
    }
    $pb = New-AVDTuneFakePrinters; $pb.Store.Servers[$srv].Printers += @{ Name = 'Wild'; ShareName = 'Wild'; Shared = $true; DriverName = 'Bad*Driver' }
    $ib = Read-Inventory $pb $tmp
    Test-Check 'inventory (N3): a driver name with a wildcard is a problem, never exported' ((Get-Printer1 $ib 'Wild').Problem -like '*driver name is not valid*' -and @($pb.Store.Log | Where-Object { $_ -like '*Bad*' }).Count -eq 0) (Get-Printer1 $ib 'Wild').Problem

    # ---------------------------------------------------------------- the catalog line as Windows reads it (M-neu) and the copy file by file (N-neu)
    $ic = { param($t) Get-AVDTunePrinterInfCatalog -Text ($t -join "`r`n") }
    $before = & $ic @('[Manufacturer]', 'CatalogFile.NTamd64=evil.cat', '[Version]', 'Signature="$Windows NT$"', 'CatalogFile=good.cat ; comment')
    $order = & $ic @('[version]', 'CatalogFile=a.cat', 'CatalogFile.NT=b.cat', 'CATALOGFILE.NTAMD64="c.cat"')
    $nt = & $ic @('[Version]', 'CatalogFile=a.cat', 'CatalogFile.NT=b.cat')
    $twice = & $ic @('[Version]', 'CatalogFile.NTamd64=a.cat', 'CatalogFile.NTamd64=b.cat')
    $token = & $ic @('[Version]', 'CatalogFile=%CatName%')
    $none = & $ic @('[Strings]', 'CatalogFile=x.cat', '[Version]', 'Signature="$Windows NT$"')
    Test-Check 'INF catalog (M-neu): only [Version] counts (a CatalogFile.NTamd64 in a section before it is ignored); NTamd64 before NT before plain; a key twice, a %token% and no catalog in [Version] are refused' ($before.Catalog -eq 'good.cat' -and $order.Catalog -eq 'c.cat' -and $nt.Catalog -eq 'b.cat' -and $twice.Error -like '*twice*' -and $token.Error -like '*not a plain .cat*' -and $none.Error -like '*no catalog file in `[Version`]*') "$($before.Catalog) $($order.Catalog) $($nt.Catalog) / $($twice.Error) / $($token.Error) / $($none.Error)"
    $p2 = New-AVDTuneFakePrinters; $d2 = $p2.Store.Servers[$srv].Drivers[0]; $d2.Cat2 = 'second.cat'; $d2.InfText = "[Version]`r`nCatalogFile.NT=second.cat`r`n"
    $i2 = Read-Inventory $p2 $tmp
    $p3 = New-AVDTuneFakePrinters; $p3.Store.Servers[$srv].Drivers[0].Cat2 = 'second.cat'
    $i3 = Read-Inventory $p3 $tmp
    $p4 = New-AVDTuneFakePrinters; $p4.Store.Servers[$srv].Drivers[0].InfText = "[Manufacturer]`r`nCatalogFile.NTamd64=exupcl6.cat`r`n[Version]`r`nSignature=`"`$Windows NT`$`"`r`n"
    $i4 = Read-Inventory $p4 $tmp
    Test-Check 'catalog (M-neu): a second catalog in the export (named by CatalogFile.NT or not named at all) and a catalog line in a section before [Version] make the driver a problem' ((Get-Printer1 $i2 'Floor 1 Color').Problem -like '*2 catalog files*' -and (Get-Printer1 $i3 'Floor 1 Color').Problem -like '*2 catalog files*' -and (Get-Printer1 $i4 'Floor 1 Color').Problem -like '*no catalog file in `[Version`]*') "$((Get-Printer1 $i2 'Floor 1 Color').Problem) / $((Get-Printer1 $i3 'Floor 1 Color').Problem) / $((Get-Printer1 $i4 'Floor 1 Color').Problem)"
    Test-Check 'copy (N-neu): file by file, only files are read, folders made one by one below the work folder' ((@($st.Reads | Sort-Object -Unique) -join ',') -eq 'amd64\driver.dll,exlabel.cat,exlabel.inf,exunsig.cat,exunsig.inf,exupcl6.cat,exupcl6.inf' -and @($st.Mkdirs | Where-Object { $_ -notlike "$tmp\temp\printers-w*\amd64" }).Count -eq 0 -and @($st.Mkdirs | Sort-Object -Unique).Count -eq 3) "reads=$($st.Reads -join ',') mkdirs=$($st.Mkdirs -join ',')"
    $pc = New-AVDTuneFakePrinters
    $wf = & $pc.WorkFolder $tmp
    $copyErr = foreach ($bad in @(@{ Path = 'amd64\..\..\x.dll'; Length = 1; Link = $false }, @{ Path = 'C:\x.dll'; Length = 1; Link = $false }, @{ Path = 'a/b.dll'; Length = 1; Link = $false }, @{ Path = 'ok.dll'; Length = 1; Link = $true }, @{ Path = 'x.'; Length = 1; Link = $false })) { Get-ThrownText { Copy-AVDTunePrinterExport -P $pc -Session 's' -Export ([pscustomobject]@{ Source = 'C:\Windows\Temp\AVDTune-x'; Files = @([pscustomobject]$bad) }) -Local $wf } }
    $readsBefore = $pc.Store.Reads.Count
    $twiceErr = Get-ThrownText { Invoke-AVDTunePrinterSession -P $pc -Server $srv -Credential $cred -Block { param($s) $e = & $pc.RemoteExport $s 'C:\Windows\System32\DriverStore\FileRepository\exupcl6.inf_amd64_1\exupcl6.inf'; $e.Files = @($e.Files) + @($e.Files[0]); Copy-AVDTunePrinterExport -P $pc -Session $s -Export $e -Local $wf } }
    Test-Check 'copy (N-neu): .., a drive, a slash, a link and a trailing dot are refused before anything is read; a file is written only new (a second write of the same name stops)' (@($copyErr | Where-Object { $_ -like '*not allowed or a link*' }).Count -eq 5 -and $readsBefore -eq 0 -and $twiceErr -like '*exists*') "$($copyErr -join ' | ') / $twiceErr"

    # ---------------------------------------------------------------- Apply
    Test-Check 'run: without the confirmed snapshot gate nothing is installed' ((Get-ThrownText { Invoke-AVDTunePrinterRun -Machine $m -P $p -Root $tmp -Drivers $plan -Credential $cred -Policy }) -like '*gate*' -and $st.Local.Count -eq 0) $null
    Open-AVDTuneWriteGate -SnapshotId 'snap-1' -ConfirmedBy 'admin1'
    $r0 = Invoke-AVDTunePrinterRun -Machine $m -P $p -Root $tmp -Drivers @($plan | Where-Object { $_.Name -eq 'Example Label Driver' }) -Credential $cred -User 'admin1' -SnapshotId 'snap-1'
    Test-Check 'signer (H2): a vendor signer the administrator did not allow stops the install of its driver' (@($r0.Run.Results | Where-Object { $_.Status -eq 'Failed' -and $_.Message -like '*not allowed by the administrator*' }).Count -eq 1 -and -not $st.Local.ContainsKey('Example Label Driver') -and $st.LocalFolders.Count -eq 0) (($r0.Run.Results | ForEach-Object { "$($_.Status) $($_.Message)" }) -join ' | ')
    Add-AVDTunePrinterSigner -Root $tmp -Thumbprint ('B2' * 20) -Subject $lab.Signer -User 'admin1'
    $signers = @(Get-AVDTunePrinterSigners -Root $tmp)
    Test-Check 'allowlist: the administrator allows a signer by thumbprint (typed in config); a wrong thumbprint is refused' ($signers.Count -eq 1 -and $signers[0].Thumbprint -eq ('B2' * 20) -and (Get-ThrownText { Add-AVDTunePrinterSigner -Root $tmp -Thumbprint 'xyz' -Subject 's' }) -like '*thumbprint*') $null
    $inv = Read-Inventory $p $tmp $signers
    $plan = @(Get-AVDTunePrinterDriverPlan -Inventory $inv)
    $p.Store.Registry['hklm:\software\policies\microsoft\windows nt\printers\packagepointandprint\listofservers|old.example.test'] = @{ Value = 'old.example.test'; Kind = 'String' }
    $r = Invoke-AVDTunePrinterRun -Machine $m -P $p -Root $tmp -Drivers $plan -Credential $cred -Policy -User 'admin1' -SnapshotId 'snap-1'
    Test-Check 'apply (H2): both drivers by export (no printer connection anywhere), installed with the server version, INF in the driver store; the check says so' ($st.Local['Example Universal PCL6'] -eq '7.1.0.2500' -and $st.Local['Example Label Driver'] -eq '2.4.0.300' -and @($r.Check | Where-Object { -not $_.Ok -or -not $_.InStore }).Count -eq 0 -and @($r.Check).Count -eq 2 -and @($st.Log | Where-Object { $_ -like 'AddDriverPackage *' }).Count -eq 2 -and -not $p.PSObject.Properties['Connect'] -and @($r.Run.Results | Where-Object { $_.Status -eq 'Failed' }).Count -eq 0) (($r.Run.Results | ForEach-Object { "$($_.Id)=$($_.Status) $($_.Message)" }) -join ' | ')
    Test-Check 'apply: local and remote temporary folders and the sessions are gone; TrustedHosts is not touched' ($st.LocalFolders.Count -eq 0 -and $st.RemoteFolders.Count -eq 0 -and $st.Sessions.Count -eq 0 -and $st.TrustedHistory.Count -eq 0) $null
    $pol = 'hklm:\software\policies\microsoft\windows nt\printers'
    Test-Check 'Point and Print: RestrictDriverInstallationToAdministrators = 1, the list flag on and only the chosen server in the list (another entry removed)' ($st.Registry["$pol\pointandprint|restrictdriverinstallationtoadministrators"].Value -eq 1 -and $st.Registry["$pol\packagepointandprint|packagepointandprintserverlist"].Value -eq 1 -and $st.Registry.ContainsKey("$pol\packagepointandprint\listofservers|$srv") -and -not $st.Registry.ContainsKey("$pol\packagepointandprint\listofservers|old.example.test")) $null
    $log = @(Get-AVDTuneChangeLog -Root $tmp | Where-Object { $_.Category -eq 'Printers' })
    Test-Check 'change log: driver, version, server, signer and printers per driver (category Printers)' (@($log | Where-Object { $_.Text -eq "Printer driver Example Universal PCL6 7.1.0.2500 from $srv, signed by Microsoft Windows Hardware Compatibility Publisher (printers: Floor 1 Color, Floor 2 Color)" }).Count -eq 1 -and @($log | Where-Object { $_.Text -eq "Printer driver Example Label Driver 2.4.0.300 from $srv, signed by Example Labels Inc (printers: Label Printer)" }).Count -eq 1 -and $log.Count -eq 4) (($log | ForEach-Object { $_.Text }) -join ' | ')
    $saved = Get-AVDTunePrinterState -Root $tmp; $undo = Read-AVDTunePrinterUndo $tmp
    Test-Check 'state: printers.json has the server and both drivers with signer; the undo record has the policies before and the two added drivers' (($saved.Servers -join ',') -eq $srv -and $saved.Drivers.Count -eq 2 -and @($saved.Drivers | Where-Object { $_.Signer }).Count -eq 2 -and $undo.Policy -and $undo.Drivers.Count -eq 2) $null

    # ---------------------------------------------------------------- M1, lying server, swapped signer, N4
    $fresh = @($plan | ForEach-Object { $c = $_.PSObject.Copy(); $c })
    $fresh[0].Version = '9.9.9.999'
    Test-Check 'plan (M1): a fresh read that differs from the confirmed plan (version, INF, package-aware, server) is named; the same plan gives nothing' (@(Compare-AVDTunePrinterPlan -Confirmed $plan -Fresh $plan).Count -eq 0 -and @(Compare-AVDTunePrinterPlan -Confirmed $plan -Fresh $fresh) -like '*Version is now*' -and @(Compare-AVDTunePrinterPlan -Confirmed $plan -Fresh @($fresh[1])) -like '*no longer on the server*') $null
    $pl = New-AVDTuneFakePrinters; $pl.Store.Servers[$srv].Drivers[0].LocalPackageAware = $false
    $rootL = Join-Path $tmp 'lie'; [void](Initialize-AVDTuneState -Root $rootL)
    $il = Read-Inventory $pl $rootL
    $rl = Invoke-AVDTunePrinterRun -Machine $m -P $pl -Root $rootL -Drivers @(Get-AVDTunePrinterDriverPlan -Inventory $il -Selected @('Floor 1 Color')) -Credential $cred -User 'admin1' -SnapshotId 'snap-1'
    Test-Check 'lying server (H2): the server says package-aware, the driver still comes by the checked export, and the check names that the installed driver is not package-aware' (@($pl.Store.Log | Where-Object { $_ -like 'AddDriverPackage *exupcl6.inf' }).Count -eq 1 -and @($rl.Check)[0].Ok -and -not @($rl.Check)[0].PackageAware -and @($rl.Check)[0].Warning -like '*says package-aware*') (@($rl.Check) | ConvertTo-Json -Compress)
    $ps = New-AVDTuneFakePrinters; $ps.Store.SwapSigner['Example Universal PCL6'] = $ps.Store.Vendor
    $rootS = Join-Path $tmp 'swap'; [void](Initialize-AVDTuneState -Root $rootS)
    Add-AVDTunePrinterSigner -Root $rootS -Thumbprint ('B2' * 20) -Subject 'CN=Example Labels Inc' -User 'admin1'
    $is = Read-Inventory $ps $rootS
    $rs = Invoke-AVDTunePrinterRun -Machine $m -P $ps -Root $rootS -Drivers @(Get-AVDTunePrinterDriverPlan -Inventory $is -Selected @('Floor 1 Color')) -Credential $cred -User 'admin1' -SnapshotId 'snap-1'
    Test-Check 'signer (M1/H2): a catalog signed by another (even allowed) signer than the confirmed one at Apply stops the install' (@($rs.Run.Results | Where-Object { $_.Status -eq 'Failed' -and $_.Message -like '*not by the confirmed signer*' }).Count -eq 1 -and $ps.Store.Local.Count -eq 0) (($rs.Run.Results | ForEach-Object { "$($_.Status) $($_.Message)" }) -join ' | ')
    Test-Check 'run: a driver without a confirmed signer is refused before anything runs' ((Get-ThrownText { Invoke-AVDTunePrinterRun -Machine $m -P $ps -Root $rootS -Drivers @([pscustomobject]@{ Name = 'Example Universal PCL6'; Server = $srv; Thumbprint = ''; Version = '1.0.0.300'; InfPath = 'C:\x\a.inf' }) -Credential $cred }) -like '*no confirmed signer*') $null
    $pw4 = New-AVDTuneFakePrinters; $pw4.Store.Registry["$pol\pointandprint|nowarningnoelevationoninstall"] = @{ Value = 1; Kind = 'DWord' }; $pw4.Store.Registry["$pol\pointandprint|updatepromptsettings"] = @{ Value = 2; Kind = 'DWord' }
    $w = @(Get-AVDTunePrinterPolicyWarnings -P $pw4)
    Test-Check 'Point and Print (N4): unsafe values on the master are named; none on a clean master' ($w.Count -eq 2 -and $w[0] -like 'NoWarningNoElevationOnInstall = 1*' -and @(Get-AVDTunePrinterPolicyWarnings -P (New-AVDTuneFakePrinters)).Count -eq 0) ($w -join ' | ')

    # ---------------------------------------------------------------- maintenance, journal of the first version, undo
    $st.Servers[$srv].Drivers[0].Version = '7.2.0.1000'
    $cmp = @(Compare-AVDTunePrinterDrivers -Installed $saved.Drivers -Server @(Get-AVDTunePrinterDriverPlan -Inventory (Read-Inventory $p $tmp $signers)))
    Test-Check 'maintenance: a new version on the server is Changed, the unchanged one Same' ((($cmp | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Status)" }) -join ',') -eq 'Example Label Driver=Same,Example Universal PCL6=Changed') (($cmp | ForEach-Object { "$($_.Name)=$($_.Status)" }) -join ',')
    $st.Servers[$srv].Drivers[0].Version = '7.1.0.2500'

    # ---------------------------------------------------------------- maintenance of the Updates page (#86): last read, rows, update in maintenance mode, removal
    $pcl6 = 'Example Universal PCL6'; $label = 'Example Label Driver'
    Test-Check 'maintenance: versions are compared by their numbers (10 is newer than 9), anything that is not a.b.c.d gives no answer' ((Compare-AVDTunePrinterVersion '7.1.0.2500' '7.2.0.1000') -eq -1 -and (Compare-AVDTunePrinterVersion '10.0.0.300' '9.0.0.300') -eq 1 -and (Compare-AVDTunePrinterVersion '2.4.0.300' '2.4.0.300') -eq 0 -and $null -eq (Compare-AVDTunePrinterVersion 'x' '2.4.0.300') -and $null -eq (Compare-AVDTunePrinterVersion ('1' * 40) '2.4.0.300')) $null
    $lagNone = Get-AVDTunePrinterDriverLag -Root $tmp
    Save-AVDTunePrinterLastRead -Root $tmp -Inventory (Read-Inventory $p $tmp $signers)
    $lagSame = Get-AVDTunePrinterDriverLag -Root $tmp
    $st.Servers[$srv].Drivers[0].Version = '7.2.0.1000'
    $invNew = Read-Inventory $p $tmp $signers
    Save-AVDTunePrinterLastRead -Root $tmp -Inventory $invNew
    $lagOld = Get-AVDTunePrinterDriverLag -Root $tmp
    $lastRead = @(Get-AVDTunePrinterLastRead -Root $tmp)
    Test-Check 'last read (readiness): nothing to say before the server was read or without installed drivers; after a read the installed drivers that are older are named, one entry per server (the newest read)' ($null -eq $lagNone -and $null -eq (Get-AVDTunePrinterDriverLag -Root (Join-Path $tmp 'nothing')) -and $lagSame -and @($lagSame.Older).Count -eq 0 -and @($lagOld.Older).Count -eq 1 -and $lagOld.Older[0].Name -eq $pcl6 -and $lagOld.Older[0].Installed -eq '7.1.0.2500' -and $lagOld.Older[0].ServerVersion -eq '7.2.0.1000' -and ($lagOld.Servers -join ',') -eq $srv -and $lastRead.Count -eq 1 -and 'Example Unsigned Driver' -in $lastRead[0].InUse -and 'Example Unsigned Driver' -notin @($lastRead[0].Drivers | ForEach-Object { $_.Name })) ($lagOld | ConvertTo-Json -Depth 4 -Compress)
    $rowsNewer = @(Get-AVDTunePrinterMaintenance -Installed @([pscustomobject]@{ Name = $pcl6; Version = '7.3.0.1000'; Server = $srv }) -Server @(Get-AVDTunePrinterDriverPlan -Inventory $invNew) -ReadServer $srv)
    Test-Check 'maintenance rows: an installed driver that is newer than the one of the server is Changed but not older; a driver of the server AVDTune did not install is New' ((@($rowsNewer | Where-Object { $_.Name -eq $pcl6 })[0].Status -eq 'Changed') -and -not @($rowsNewer | Where-Object { $_.Name -eq $pcl6 })[0].Older -and @($rowsNewer | Where-Object { $_.Name -eq $label })[0].Status -eq 'New') (($rowsNewer | ForEach-Object { "$($_.Name)=$($_.Status)/$($_.Older)" }) -join ',')
    $rootT = Join-Path $tmp 'tamper'; [void](Initialize-AVDTuneState -Root $rootT)
    Write-AVDTuneFile (Get-AVDTunePrinterLastReadPath $rootT) '{"Schema":1,"Reads":[{"Server":"print1","At":"2026-11-18T10:00:00","Drivers":[]},{"Server":"print1.example.test","At":"not a date","Drivers":[]},{"Server":"print1.example.test","At":"2026-11-18T10:00:00","Drivers":[{"Name":"Bad*Driver","Version":"1.0.0.300"},{"Name":"Good Driver","Version":"latest"},{"Name":"Fine Driver","Version":"1.0.0.300"},{"Name":7,"Version":"1.0.0.300"}],"InUse":["Bad[1]","Fine Driver",5]}]}'
    $tampered = @(Get-AVDTunePrinterLastRead -Root $rootT)
    Test-Check 'last read (untrusted file): a server that is not an FQDN, a time that is none, driver names with wildcards, versions that are none and wrong types are dropped' ($tampered.Count -eq 1 -and (@($tampered[0].Drivers | ForEach-Object { "$($_.Name)=$($_.Version)" }) -join ',') -eq 'Fine Driver=1.0.0.300' -and ($tampered[0].InUse -join ',') -eq 'Fine Driver') ($tampered | ConvertTo-Json -Depth 4 -Compress)

    [void](Set-AVDTuneUpdateBlock -Machine $m -Root $tmp -Mode On -User 'admin1' -SnapshotId 'snap-1')
    $planM = @(Get-AVDTunePrinterDriverPlan -Inventory $invNew | Where-Object { $_.Name -eq $pcl6 })
    Close-AVDTuneWriteGate
    $gateM = Get-ThrownText { Invoke-AVDTunePrinterMaintenance -Machine $m -P $p -Root $tmp -Drivers $planM -Remove @($label) -Inventory $invNew -Credential $cred }
    Open-AVDTuneWriteGate -SnapshotId 'snap-1' -ConfirmedBy 'admin1'
    Test-Check 'maintenance: without the confirmed snapshot gate nothing is installed or removed' ($gateM -like '*gate*' -and $st.Local[$pcl6] -eq '7.1.0.2500' -and $st.Local.ContainsKey($label)) $gateM
    $otherM = Get-ThrownText { Invoke-AVDTunePrinterMaintenance -Machine $m -P $p -Root $tmp -Drivers @([pscustomobject]@{ Name = $pcl6; Version = '7.2.0.1000'; Server = 'print2.example.test'; Thumbprint = ('A1' * 20); InfPath = $planM[0].InfPath }) -Inventory $invNew -Credential $cred }
    Test-Check 'maintenance: a driver of another server than the one that was read is refused' ($otherM -like '*not to the server that was read*' -and $st.Local[$pcl6] -eq '7.1.0.2500') $otherM
    $st.SwapSigner[$pcl6] = $st.Vendor
    $rSwap = Invoke-AVDTunePrinterMaintenance -Machine $m -P $p -Root $tmp -Drivers $planM -Inventory $invNew -Credential $cred -User 'admin1' -SnapshotId 'snap-1'
    Test-Check 'maintenance (same checks as the first install): an update whose catalog is now signed by another signer than the confirmed one is not installed; the update block is back' (@($rSwap.Results | Where-Object { $_.Status -eq 'Failed' -and $_.Message -like '*not by the confirmed signer*' }).Count -eq 1 -and $st.Local[$pcl6] -eq '7.1.0.2500' -and (Get-AVDTuneUpdateBlockStatus $m).State -eq 'On' -and -not (Get-AVDTuneMaintenanceCrash -Root $tmp)) (($rSwap.Results | ForEach-Object { "$($_.Status) $($_.Message)" }) -join ' | ')
    $st.SwapSigner.Remove($pcl6)
    $noSigner = Get-ThrownText { Invoke-AVDTunePrinterMaintenance -Machine $m -P $p -Root $tmp -Drivers @([pscustomobject]@{ Name = $pcl6; Version = '7.2.0.1000'; Server = $srv; Thumbprint = ''; InfPath = $planM[0].InfPath }) -Inventory $invNew -Credential $cred }
    Test-Check 'maintenance (same checks): a driver without a confirmed signer stops the run, the maintenance mode ends properly' ($noSigner -like '*no confirmed signer*' -and (Get-AVDTuneUpdateBlockStatus $m).State -eq 'On' -and -not (Get-AVDTuneMaintenanceCrash -Root $tmp)) $noSigner
    $before = (Get-AVDTuneState $tmp).Maintenance.Id
    $rM = Invoke-AVDTunePrinterMaintenance -Machine $m -P $p -Root $tmp -Drivers $planM -Inventory $invNew -Credential $cred -User 'admin1' -SnapshotId 'snap-1'
    $maint = (Get-AVDTuneState $tmp).Maintenance
    $savedM = Get-AVDTunePrinterState -Root $tmp
    Test-Check 'maintenance: the changed driver is updated by the checked export to the version of the server and checked; printers.json has the new version; the readiness lag is gone' ($st.Local[$pcl6] -eq '7.2.0.1000' -and @($rM.Check).Count -eq 1 -and $rM.Check[0].Ok -and @($rM.Results | Where-Object { $_.Status -eq 'Changed' }).Count -eq 1 -and @($savedM.Drivers | Where-Object { $_.Name -eq $pcl6 })[0].Version -eq '7.2.0.1000' -and @((Get-AVDTunePrinterDriverLag -Root $tmp).Older).Count -eq 0 -and $st.LocalFolders.Count -eq 0 -and $st.RemoteFolders.Count -eq 0 -and $st.Sessions.Count -eq 0) (($rM.Results | ForEach-Object { "$($_.Status) $($_.Message)" }) -join ' | ')
    $undoM = Read-AVDTunePrinterUndo $tmp
    Test-Check 'maintenance: the undo record of a driver AVDTune added follows the update (the new version), so Undo still removes it' ([string]$undoM.Drivers[$pcl6.ToLowerInvariant()].Version -eq '7.2.0.1000' -and -not [bool]$undoM.Drivers[$pcl6.ToLowerInvariant()].Existed -and [string]$undoM.Drivers[$label.ToLowerInvariant()].Version -eq '2.4.0.300') ($undoM.Drivers | ConvertTo-Json -Depth 4 -Compress)
    Test-Check 'maintenance mode: the run has its own maintenance record (the update block was lifted for it) and the block is back on afterwards' ($maint.Id -ne $before -and $maint.Phase -eq 'restored' -and -not $maint.Active -and @($maint.BlockBefore).Count -gt 0 -and (Get-AVDTuneUpdateBlockStatus $m).State -eq 'On' -and -not (Get-AVDTuneMaintenanceCrash -Root $tmp)) ($maint | ConvertTo-Json -Compress)
    Test-Check 'maintenance: the change log has the update with version, server and signer (category Printers)' (@(Get-AVDTuneChangeLog -Root $tmp | Where-Object { $_.Category -eq 'Printers' -and $_.Text -eq "Printer driver $pcl6 7.2.0.1000 from $srv, signed by Microsoft Windows Hardware Compatibility Publisher (printers: Floor 1 Color, Floor 2 Color)" }).Count -eq 1) $null

    # gone drivers: only what AVDTune installed from this server and added itself, and what no shared printer uses (also not one with a problem)
    $st.Servers[$srv].Printers = @($st.Servers[$srv].Printers | Where-Object { $_.Name -ne 'Label Printer' })
    $st.Local['Example Old Driver'] = '1.0.0.300'
    $stateG = Get-AVDTunePrinterState -Root $tmp
    Save-AVDTunePrinterState -Root $tmp -State ([pscustomobject]@{ Servers = @($stateG.Servers); Drivers = @($stateG.Drivers) + @([pscustomobject]@{ Name = 'Example Old Driver'; Version = '1.0.0.300'; Server = $srv; Signer = ''; Printers = @(); At = '' }, [pscustomobject]@{ Name = 'Example Unsigned Driver'; Version = '1.0.0.300'; Server = $srv; Signer = ''; Printers = @(); At = '' }) })
    $invGone = Read-Inventory $p $tmp $signers
    $rowsG = @(Get-AVDTunePrinterMaintenance -Installed (Get-AVDTunePrinterState -Root $tmp).Drivers -Server @(Get-AVDTunePrinterDriverPlan -Inventory $invGone) -ReadServer $srv -InUse @(Get-AVDTunePrinterInUse -Inventory $invGone) -Added @(Get-AVDTunePrinterAdded -Root $tmp))
    Test-Check 'gone: a driver no shared printer uses any more is Gone and removable when AVDTune added it; one that was there before AVDTune is Gone but stays; one a printer with a problem still uses is not gone' ((@($rowsG | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Status)/$($_.Removable)" }) -join ',') -eq "$label=Gone/True,Example Old Driver=Gone/False,$pcl6=Same/False") ((@($rowsG | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Status)/$($_.Removable)" }) -join ','))
    $removeLog = { @($st.Log | Where-Object { $_ -like 'RemoveDriver *' }).Count }
    $r0count = & $removeLog
    $refused = @(
        (Get-ThrownText { Invoke-AVDTunePrinterMaintenance -Machine $m -P $p -Root $tmp -Remove @($pcl6) -Inventory $invGone -Credential $cred })
        (Get-ThrownText { Invoke-AVDTunePrinterMaintenance -Machine $m -P $p -Root $tmp -Remove @('Example Unsigned Driver') -Inventory $invGone -Credential $cred })
        (Get-ThrownText { Invoke-AVDTunePrinterMaintenance -Machine $m -P $p -Root $tmp -Remove @('Some Other Driver') -Inventory $invGone -Credential $cred })
        (Get-ThrownText { Invoke-AVDTunePrinterMaintenance -Machine $m -P $p -Root $tmp -Remove @($label, 'Example Old Driver') -Inventory $invGone -Credential $cred })
        (Get-ThrownText { Invoke-AVDTunePrinterMaintenance -Machine $m -P $p -Root $tmp -Remove @('Example*') -Inventory $invGone -Credential $cred })
        (Get-ThrownText { Invoke-AVDTunePrinterMaintenance -Machine $m -P $p -Root $tmp -Remove @($label) -Inventory $invNew -Credential $cred }))
    Test-Check 'remove: a driver still in use, one a problem printer uses, one AVDTune never installed, one that was there before AVDTune (also next to a removable one), a wildcard, and a driver the given read still shows in use are refused before anything changes' ($refused[0] -like '*not a driver AVDTune installed*' -and $refused[1] -like '*not a driver AVDTune installed*' -and $refused[2] -like '*not a driver AVDTune installed*' -and $refused[3] -like '*before AVDTune*' -and $refused[4] -like '*not valid*' -and $refused[5] -like '*not a driver AVDTune installed*' -and (& $removeLog) -eq $r0count -and $st.Local.Count -eq 3 -and (Get-AVDTunePrinterState -Root $tmp).Drivers.Count -eq 4) ($refused -join ' | ')
    $rR = Invoke-AVDTunePrinterMaintenance -Machine $m -P $p -Root $tmp -Remove @($label) -Inventory $invGone -Credential $cred -User 'admin1' -SnapshotId 'snap-1'
    $undoR = Read-AVDTunePrinterUndo $tmp
    Test-Check 'remove: the gone driver AVDTune added is removed (one Remove-PrinterDriver, by its exact name) in maintenance mode; it leaves printers.json and the undo record; the others stay' ((& $removeLog) -eq ($r0count + 1) -and 'RemoveDriver Example Label Driver' -in $st.Log -and -not $st.Local.ContainsKey($label) -and $st.Local.ContainsKey($pcl6) -and $st.Local.ContainsKey('Example Old Driver') -and ($rR.Removed -join ',') -eq $label.ToLowerInvariant() -and @((Get-AVDTunePrinterState -Root $tmp).Drivers | Where-Object { $_.Name -eq $label }).Count -eq 0 -and -not $undoR.Drivers.ContainsKey($label.ToLowerInvariant()) -and $undoR.Drivers.ContainsKey($pcl6.ToLowerInvariant()) -and (Get-AVDTuneState $tmp).Maintenance.Phase -eq 'restored' -and (Get-AVDTuneState $tmp).Maintenance.Id -ne $maint.Id) (($rR.Results | ForEach-Object { "$($_.Status) $($_.Message)" }) -join ' | ')
    Test-Check 'remove: the change log says which driver was removed, why, and that there is no undo' (@(Get-AVDTuneChangeLog -Root $tmp | Where-Object { $_.Category -eq 'Printers' -and $_.Text -eq "Printer driver $label 2.4.0.300 removed: no printer of $srv uses it any more (no undo, only a new install)" }).Count -eq 1) ((Get-AVDTuneChangeLog -Root $tmp | Select-Object -Last 1).Text)
    # back to what the checks below expect: the driver that was "there before" is not AVDTune's
    $st.Local.Remove('Example Old Driver')
    $stateG = Get-AVDTunePrinterState -Root $tmp
    Save-AVDTunePrinterState -Root $tmp -State ([pscustomobject]@{ Servers = @($stateG.Servers); Drivers = @($stateG.Drivers | Where-Object { $_.Name -eq $pcl6 }) })
    [void](Set-AVDTuneUpdateBlock -Machine $m -Root $tmp -Mode Off -User 'admin1' -SnapshotId 'snap-1')

    $rootJ = Join-Path $tmp 'j'; [void](Initialize-AVDTuneState -Root $rootJ)
    Write-AVDTuneFile (Get-AVDTunePrinterJournalPath $rootJ) '{"Schema":1,"Old":"admin1.example.test","Server":"print1.example.test"}'
    $pj = New-AVDTuneFakePrinters; $pj.Store.TrustedHosts = 'admin1.example.test,print1.example.test'
    Test-Check 'TrustedHosts journal of the first version: the start sets TrustedHosts back exactly and removes the journal; without a journal nothing happens' ((Repair-AVDTunePrinterTrustedHosts -P $pj -Root $rootJ) -and $pj.Store.TrustedHosts -ceq 'admin1.example.test' -and -not (Test-Path (Get-AVDTunePrinterJournalPath $rootJ)) -and -not (Repair-AVDTunePrinterTrustedHosts -P $pj -Root $rootJ)) $pj.Store.TrustedHosts
    $u = Invoke-AVDTunePrinterRun -Machine $m -P $p -Root $tmp -Mode Undo -User 'admin1' -SnapshotId 'snap-1'
    Test-Check 'undo: the policies as before (restriction absent, the old list entry back) and the drivers AVDTune added removed; the record is empty' (-not $st.Registry.ContainsKey("$pol\pointandprint|restrictdriverinstallationtoadministrators") -and $st.Registry["$pol\packagepointandprint\listofservers|old.example.test"].Value -eq 'old.example.test' -and -not $st.Registry.ContainsKey("$pol\packagepointandprint\listofservers|$srv") -and $st.Local.Count -eq 0 -and $null -eq (Read-AVDTunePrinterUndo $tmp).Policy -and (Read-AVDTunePrinterUndo $tmp).Drivers.Count -eq 0) (($u.Run.Results | ForEach-Object { "$($_.Id)=$($_.Status) $($_.Message)" }) -join ' | ')

    # ---------------------------------------------------------------- sources and the real adapter
    $src = [IO.File]::ReadAllText((Join-Path $repo 'Modules\AVDTune.Printers.psm1'))
    $real = New-AVDTunePrinterAdapter
    $missing = @($p.PSObject.Properties.Name | Where-Object { $_ -notin 'Kind', 'Store' -and -not $real.PSObject.Properties[$_] })
    Test-Check 'real adapter: built without touching anything, it has every member of the fake and no printer connection member' ($real.Kind -eq 'Real' -and $missing.Count -eq 0 -and -not $real.PSObject.Properties['Connect']) ($missing -join ', ')
    # M2: every command the real adapter calls on this computer resolves in the scope of the module (blocks that run on the server through Invoke-Command are not counted)
    $resolve = {
        param([string]$Source)
        $ast = [Management.Automation.Language.Parser]::ParseInput($Source, [ref]$null, [ref]$null)
        $fn = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'New-AVDTunePrinterAdapter' }, $true)
        $remote = @($fn.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Invoke-Command' }, $true) | ForEach-Object { $_.FindAll({ param($x) $x -is [Management.Automation.Language.ScriptBlockExpressionAst] }, $true) })
        $names = @($fn.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true) | Where-Object { $c = $_; -not @($remote | Where-Object { $_.Extent.StartOffset -le $c.Extent.StartOffset -and $_.Extent.EndOffset -ge $c.Extent.EndOffset }).Count } | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ } | Select-Object -Unique)
        $mod = Get-Module AVDTune.Printers
        @($names | Where-Object { -not (& $mod { param($n) Get-Command $n -ErrorAction SilentlyContinue } $_) })
    }
    $unresolved = @(& $resolve $src)
    $sample = @(& $resolve "function New-AVDTunePrinterAdapter { `$a = @{}; `$a.W = { New-AVDTuneWorkFolder -Path 1 -Base 2 }; `$a.R = { Invoke-Command -ScriptBlock { Get-WindowsDriverNotHere } } }")
    Test-Check 'real adapter (M2): every command it calls here resolves in the module (counter-test: New-AVDTuneWorkFolder of AVDTune.Software does not; a block on the server is not counted)' ($unresolved.Count -eq 0 -and ($sample -join ',') -eq 'New-AVDTuneWorkFolder') "unresolved: $($unresolved -join ', ') / sample: $($sample -join ',')"
    Test-Check 'sources (H1): WinRM only with Kerberos, no Negotiate/NTLM/Basic, no TrustedHosts change except the repair of the old journal, no spooler RPC to the server' ($src -match 'New-PSSession -ComputerName \$Server -Credential \$pc -Authentication Kerberos' -and $src -notmatch '-Authentication (Negotiate|Default|Basic|Credssp)' -and $src -notmatch '-ComputerName \$\w+ -ErrorAction' -and ([regex]::Matches($src, 'TrustedHostsSet')).Count -eq 2 -and $src -notmatch 'TrustedHostsGet') $null
    Test-Check 'sources (H2/N2): no printer connection (Add-Printer -ConnectionName), pnputil through Invoke-AVDTuneProgram, the server folder admin-only and deleted only below Windows\Temp by name' ($src -notmatch 'Add-Printer\s' -and $src -notmatch 'ConnectionName' -and $src -notmatch 'Copy-Item' -and $src -match 'IO\.FileMode\]::CreateNew' -and $src -match "Invoke-AVDTuneProgram -File \(Join-Path \(Get-AVDTuneSystemFolder System\) 'pnputil\.exe'\)" -and $src -match "SetAccessRuleProtection\(\`$true, \`$false\)" -and $src -match "AVDTune-\[0-9a-f\]\{12\}" -and $src -match 'New-AVDTuneDownloadFolder -Root \$Root -Prefix ''printers''') $null
    Test-Check 'secrets: the password never becomes a managed string (no ConvertFrom-SecureString, no -AsPlainText, no GetNetworkCredential, no PtrToString)' ($src -notmatch 'ConvertFrom-SecureString' -and $src -notmatch 'AsPlainText' -and $src -notmatch 'GetNetworkCredential' -and $src -notmatch 'PtrToString') $null
    $page = [IO.File]::ReadAllText((Join-Path $repo 'AVDTune-Printers.ps1'))
    $pageAst = [Management.Automation.Language.Parser]::ParseInput($page, [ref]$null, [ref]$null)
    $fnText = { param([string]$n) $f = $pageAst.Find({ param($x) $x -is [Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq $n }, $true); if ($f) { $f.Extent.Text } else { '' } }
    $acct = & $fnText 'New-PrnUpdAccount'; $upd = & $fnText 'Invoke-PrnUpdUpdate'; $rem = & $fnText 'Invoke-PrnUpdRemove'; $done = & $fnText 'Complete-PrnJob'
    $worker = $page.Substring($page.IndexOf("`$script:PrnWorkerText = @'")); $worker = $worker.Substring(0, $worker.IndexOf("`n'@"))
    $maintain = $worker.Substring($worker.IndexOf("'Maintain' {")); $maintain = $maintain.Substring(0, $maintain.IndexOf("'Undo' {"))
    Test-Check 'Updates page (account, #75): the typed password box is cleared; an empty one takes the kept account of the start sequence only with the pins of the environment; the copy is disposed with the job; a kept account that did not get to a read of the server is forgotten' ($acct.Contains('$ui.PwdUpdPrn.Clear()') -and $acct.Contains('Get-AVDTuneSessionDcAccount -Pins (Get-AVDTuneDcPins (Get-AVDTuneEnvironment $script:StateRoot))') -and $acct.Contains("throw (T 'prn.upd.err.password')") -and $acct -notmatch 'ConvertFrom-SecureString|AsPlainText|GetNetworkCredential|PtrToString' -and $done.Contains('$job.Account.Password.Dispose()') -and $done.Contains("if (`$err -and `$job.FromSession -and [string]`$job.Sync.Auth -ne 'ok') { Clear-AVDTuneSessionDcAccount }")) $null
    Test-Check 'Updates page (writer): update and remove ask the write gate and Assert-NoOtherWriter, confirm first, and run as the writer kind Maintain of PrnJob (not a read kind); the job asks AD for the server, compares the confirmed plan with a fresh read and goes through Invoke-AVDTunePrinterMaintenance' ($upd.Contains('Test-AVDTuneWriteAllowed') -and $upd.Contains('Assert-NoOtherWriter') -and $upd.Contains('Confirm-PrnSigners') -and $upd.IndexOf('Confirm-Action') -lt $upd.IndexOf("Start-PrnJob 'Maintain'") -and $rem.Contains('Test-AVDTuneWriteAllowed') -and $rem.Contains('Assert-NoOtherWriter') -and $rem.IndexOf("Confirm-Action (T 'prn.upd.ask.remove'") -gt 0 -and $rem.IndexOf('Confirm-Action') -lt $rem.IndexOf("Start-PrnJob 'Maintain'") -and 'Maintain' -notin @('Servers', 'Read') -and $page.Contains("`$script:PrnReadKinds = @('Servers', 'Read')") -and $maintain.Contains('Assert-AVDTunePrinterServerAllowed -Server $Server -Allowed $allowed') -and $maintain.IndexOf('Compare-AVDTunePrinterPlan') -gt 0 -and $maintain.IndexOf('Compare-AVDTunePrinterPlan') -lt $maintain.IndexOf('$r = Invoke-AVDTunePrinterMaintenance') -and $maintain -notmatch 'RemoveDriver|Remove-PrinterDriver') $null
    Test-Check 'sources (remove): Remove-PrinterDriver only in the adapter; the module calls RemoveDriver only in the undo of a driver AVDTune added and in the remove step, each after the name check' (([regex]::Matches($src, 'Remove-PrinterDriver -Name \$Name')).Count -eq 1 -and ([regex]::Matches($src, '& \$pp\.RemoveDriver \$d\.Name')).Count -eq 2 -and ([regex]::Matches($src, "if \(-not \(Test-AVDTunePrinterDriverName \`$d\.Name\)\) \{ throw 'The driver name is not valid\.' \}; & \`$pp\.RemoveDriver \`$d\.Name")).Count -eq 2 -and ([regex]::Matches($src, 'RemoveDriver')).Count -eq 3) "$(([regex]::Matches($src, 'RemoveDriver')).Count)"
    Test-Check 'page: texts from T, the job through New-AVDTunePowerShell, writes check the gate and Assert-NoOtherWriter, the password is cleared and disposed, the confirmed plan goes to the job and is compared (M1), servers only from AD' ($page -match "T 'prn\." -and $page -match 'New-AVDTunePowerShell' -and $page -match 'Assert-NoOtherWriter' -and $page -match 'Test-AVDTuneWriteAllowed' -and $page -notmatch '\[powershell\]::Create' -and $page -match '\.Password\.Dispose\(\)' -and $page -match 'PwdPrn\.Clear\(\)' -and $page -match 'Compare-AVDTunePrinterPlan' -and $page -match 'Assert-AVDTunePrinterServerAllowed' -and $page -match 'Repair-AVDTunePrinterTrustedHosts') $null
}
finally {
    Close-AVDTuneWriteGate
    Remove-Item Env:\AVDTUNE_ROOT -ErrorAction SilentlyContinue
    if (Test-Path $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
if ($script:failed -gt 0) { throw "$script:failed check(s) failed." }
'Check-Printers: all checks passed.'
