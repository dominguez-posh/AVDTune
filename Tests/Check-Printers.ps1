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
foreach ($m in 'AVDTune', 'AVDTune.Updates', 'AVDTune.Directory', 'AVDTune.Custom', 'AVDTune.Printers') { Import-Module (Join-Path $repo "Modules\$m.psm1") -Force }
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
    $rootJ = Join-Path $tmp 'j'; [void](Initialize-AVDTuneState -Root $rootJ)
    Write-AVDTuneFile (Get-AVDTunePrinterJournalPath $rootJ) '{"Schema":1,"Old":"admin1.example.test","Server":"print1.example.test"}'
    $pj = New-AVDTuneFakePrinters; $pj.Store.TrustedHosts = 'admin1.example.test,print1.example.test'
    Test-Check 'TrustedHosts journal of the first version: the start sets TrustedHosts back exactly and removes the journal; without a journal nothing happens' ((Repair-AVDTunePrinterTrustedHosts -P $pj -Root $rootJ) -and $pj.Store.TrustedHosts -ceq 'admin1.example.test' -and -not (Test-Path (Get-AVDTunePrinterJournalPath $rootJ)) -and -not (Repair-AVDTunePrinterTrustedHosts -P $pj -Root $rootJ)) $pj.Store.TrustedHosts
    # audit #102: the undo record is written before the first write; the server list step fails after it removed the foreign entry: the origin is still known and the
    # undo brings the foreign entry back
    $rootF = Join-Path $tmp 'fail102'; [void](Initialize-AVDTuneState -Root $rootF)
    Save-AVDTunePrinterState -Root $rootF -State ([pscustomobject]@{ Servers = @($srv); Drivers = @() })
    $pf = New-AVDTuneFakePrinters
    $pf.Store.Registry['hklm:\software\policies\microsoft\windows nt\printers\packagepointandprint\listofservers|foreign.example.test'] = @{ Value = 'foreign.example.test'; Kind = 'String' }
    $pf.Store.Registry['hklm:\software\policies\microsoft\windows nt\printers\pointandprint|restrictdriverinstallationtoadministrators'] = @{ Value = 1; Kind = 'DWord' }   # already set: only the list step writes (no Changed step to record after the run)
    $origSet = $pf.RegSet
    $pf.RegSet = { param($Path, $Name, $Value, $Type) if ($Path -like '*ListOfServers') { throw 'fake: write refused' }; & $origSet $Path $Name $Value $Type }.GetNewClosure()
    $rf = Invoke-AVDTunePrinterRun -Machine $m -P $pf -Root $rootF -Drivers @() -Policy -User 'admin1' -SnapshotId 'snap-1'
    $uf = Read-AVDTunePrinterUndo $rootF
    Test-Check 'undo record (#102): the server list step failed after removing the foreign entry; the record written before the run keeps it' (@($rf.Run.Results | Where-Object { $_.Id -eq 'printers.policy-serverlist' -and $_.Status -eq 'Failed' }).Count -eq 1 -and -not $pf.Store.Registry.ContainsKey('hklm:\software\policies\microsoft\windows nt\printers\packagepointandprint\listofservers|foreign.example.test') -and [string]$uf.Policy.List.'foreign.example.test' -eq 'foreign.example.test') $(try { Get-Content (Get-AVDTunePrinterUndoPath $rootF) -Raw -ErrorAction Stop } catch { "no undo record" })
    $pf.RegSet = $origSet
    [void](Invoke-AVDTunePrinterRun -Machine $m -P $pf -Root $rootF -Mode Undo -User 'admin1' -SnapshotId 'snap-1')
    Test-Check 'undo (#102): after the failed run the foreign entry is back' ($pf.Store.Registry.ContainsKey('hklm:\software\policies\microsoft\windows nt\printers\packagepointandprint\listofservers|foreign.example.test')) $null
    # a value someone else changed after AVDTune is not overwritten by the undo; the record stays
    $rootO = Join-Path $tmp 'other102'; [void](Initialize-AVDTuneState -Root $rootO)
    Save-AVDTunePrinterState -Root $rootO -State ([pscustomobject]@{ Servers = @($srv); Drivers = @() })
    $po = New-AVDTuneFakePrinters
    [void](Invoke-AVDTunePrinterRun -Machine $m -P $po -Root $rootO -Drivers @() -Policy -User 'admin1' -SnapshotId 'snap-1')
    $po.Store.Registry['hklm:\software\policies\microsoft\windows nt\printers\pointandprint|restrictdriverinstallationtoadministrators'] = @{ Value = 0; Kind = 'DWord' }
    $po.Store.Registry['hklm:\software\policies\microsoft\windows nt\printers\packagepointandprint\listofservers|gpo.example.test'] = @{ Value = 'gpo.example.test'; Kind = 'String' }
    $ro = Invoke-AVDTunePrinterRun -Machine $m -P $po -Root $rootO -Mode Undo -User 'admin1' -SnapshotId 'snap-1'
    Test-Check 'undo (#102): a restriction and a list someone else changed since are not overwritten (failed with the reason), the record stays' (@($ro.Run.Results | Where-Object { $_.Status -eq 'Failed' -and $_.Message -like '*someone else*' }).Count -eq 1 -and $po.Store.Registry['hklm:\software\policies\microsoft\windows nt\printers\pointandprint|restrictdriverinstallationtoadministrators'].Value -eq 0 -and $po.Store.Registry.ContainsKey('hklm:\software\policies\microsoft\windows nt\printers\packagepointandprint\listofservers|gpo.example.test') -and $null -ne (Read-AVDTunePrinterUndo $rootO).Policy) (($ro.Run.Results | ForEach-Object { "$($_.Id)=$($_.Status):$($_.Message)" }) -join ' | ')
    # typed read: "false" is not false, a list entry that is not a host name, a driver without a valid name
    $typedBad = 0
    foreach ($bad in '{"Schema":1,"Policy":{"Restrict":{"Exists":"false"},"ListFlag":{"Exists":false},"List":{}},"Drivers":{}}', '{"Schema":1,"Policy":{"Restrict":{"Exists":false},"ListFlag":{"Exists":false},"List":{"a b":"x;y"}},"Drivers":{}}', '{"Schema":1,"Policy":null,"Drivers":{"x*":{"Name":"x*","Version":"1","Server":"print1.example.test","Existed":false}}}') {
        Write-AVDTuneFile (Get-AVDTunePrinterUndoPath $rootO) $bad
        $logN = $po.Store.Log.Count
        if ((Get-ThrownText { Invoke-AVDTunePrinterRun -Machine $m -P $po -Root $rootO -Mode Undo -User 'admin1' -SnapshotId 'snap-1' }) -like '*not usable*' -and $po.Store.Log.Count -eq $logN) { $typedBad++ }
    }
    Test-Check 'undo record (#102): read typed: "false" for Exists, a list entry that is not a host name and a driver name with a wildcard are refused, nothing is written' ($typedBad -eq 3) "$typedBad of 3"
    # audit #103: the repair is a change of the master: not with a closed write gate (journal and TrustedHosts stay), else under the marker with LastChange and a change log entry
    $rootJ2 = Join-Path $tmp 'j103'; [void](Initialize-AVDTuneState -Root $rootJ2); [void](Start-AVDTuneImageVersion -Root $rootJ2 -Date (Get-Date) -User 'admin1')
    Write-AVDTuneFile (Get-AVDTunePrinterJournalPath $rootJ2) '{"Schema":1,"Old":"admin1.example.test","Server":"print1.example.test"}'
    $pj2 = New-AVDTuneFakePrinters; $pj2.Store.TrustedHosts = 'admin1.example.test,print1.example.test'
    Close-AVDTuneWriteGate
    $closed103 = Repair-AVDTunePrinterTrustedHosts -P $pj2 -Root $rootJ2
    Open-AVDTuneWriteGate -SnapshotId 'snap-1' -ConfirmedBy 'admin1'
    $closedOk = (-not $closed103 -and $pj2.Store.TrustedHosts -ceq 'admin1.example.test,print1.example.test' -and (Test-Path (Get-AVDTunePrinterJournalPath $rootJ2)))
    $open103 = Repair-AVDTunePrinterTrustedHosts -P $pj2 -Root $rootJ2 -User 'admin1'
    Test-Check 'TrustedHosts repair (#103): nothing with a closed write gate; with the gate: put back, LastChange set, a change log entry' ($closedOk -and $open103 -and $pj2.Store.TrustedHosts -ceq 'admin1.example.test' -and $null -ne (Get-AVDTuneLastChange -Root $rootJ2) -and @(Get-AVDTuneChangeLog -Root $rootJ2 | Where-Object { $_.Component -eq 'printers.trustedhosts' }).Count -eq 1) "closed ok $closedOk, open $open103"
    $twice = @($plan[0], $plan[0])
    $rootT = Join-Path $tmp 'twice104'; [void](Initialize-AVDTuneState -Root $rootT)
    $twiceText = Get-ThrownText { Invoke-AVDTunePrinterRun -Machine $m -P $p -Root $rootT -Drivers $twice -Credential $cred -User 'admin1' -SnapshotId 'snap-1' }
    Test-Check 'run (#104 N7): a driver twice in the plan is refused before anything runs' ($twiceText -like '*in the plan twice*') $twiceText
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
    Test-Check 'page: texts from T, the job through New-AVDTunePowerShell, writes check the gate and Assert-NoOtherWriter, the password is cleared and disposed, the confirmed plan goes to the job and is compared (M1), servers only from AD' ($page -match "T 'prn\." -and $page -match 'New-AVDTunePowerShell' -and $page -match 'Assert-NoOtherWriter' -and $page -match 'Test-AVDTuneWriteAllowed' -and $page -notmatch '\[powershell\]::Create' -and $page -match '\.Password\.Dispose\(\)' -and $page -match 'PwdPrn\.Clear\(\)' -and $page -match 'Compare-AVDTunePrinterPlan' -and $page -match 'Assert-AVDTunePrinterServerAllowed' -and $page -match 'Repair-AVDTunePrinterTrustedHosts') $null
}
finally {
    Close-AVDTuneWriteGate
    Remove-Item Env:\AVDTUNE_ROOT -ErrorAction SilentlyContinue
    if (Test-Path $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
if ($script:failed -gt 0) { throw "$script:failed check(s) failed." }
'Check-Printers: all checks passed.'
