#requires -Version 5.1
<#
.SYNOPSIS
    Checks the printer drivers from a print server (Modules\AVDTune.Printers.psm1, issue #86, plan 3b) against the fake printer adapter, the fake LDAP, the fake machine
    and a temporary state folder: validation (host name, share, INF path, version), print servers from AD, the inventory of a server with the domain account, the plan
    of distinct drivers, Apply through Invoke-AVDTune (write gate, change log with driver/version/server/printers, check), package-aware by a temporary connection,
    the others by export of only that driver with TrustedHosts appended and restored exactly (journal, repair), temporary files gone on both sides, Point and Print
    policies with undo, the maintenance comparison and source checks of the page. Nothing touches this computer.
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
$cred = [pscustomobject]@{ User = 'EXAMPLE\admin1'; Password = $pw }

try {
    $env:AVDTUNE_ROOT = $tmp
    [void](Initialize-AVDTuneState -Root $tmp)
    [void](Start-AVDTuneImageVersion -Root $tmp -Date ([datetime]'2026-11-18') -User 'admin1')
    Close-AVDTuneWriteGate
    $m = New-AVDTuneFakeMachine

    # ---------------------------------------------------------------- validation
    $goodNames = @('print1', 'print1.example.test', 'PRINT-01')
    $badNames = @('\\print1', 'print1\share', 'print1/x', 'print1:5985', 'admin@print1', 'print 1', '*', '', ('a' * 254), "print1`n")
    Test-Check 'server name: a host name only (no UNC, path, port, user, space, wildcard, control character)' (@($goodNames | Where-Object { -not (Test-AVDTunePrinterServerName $_) }).Count -eq 0 -and @($badNames | Where-Object { Test-AVDTunePrinterServerName $_ }).Count -eq 0) (@($badNames | Where-Object { Test-AVDTunePrinterServerName $_ }) -join ' | ')
    Test-Check 'share name and INF path: separators, .. and control characters refused' ((Test-AVDTunePrinterShareName 'F1-Color') -and -not (Test-AVDTunePrinterShareName 'a\b') -and -not (Test-AVDTunePrinterShareName '..') -and -not (Test-AVDTunePrinterShareName '') -and (Test-AVDTunePrinterInfPath 'C:\Windows\INF\oem5.inf') -and -not (Test-AVDTunePrinterInfPath '\\x\y\a.inf') -and -not (Test-AVDTunePrinterInfPath 'C:\a\..\b.inf') -and -not (Test-AVDTunePrinterInfPath 'C:\a\b.exe')) $null
    $u64 = ([uint64]7 -shl 48) + ([uint64]1 -shl 32) + ([uint64]0 -shl 16) + 2500
    Test-Check 'driver version: the UInt64 of Get-PrinterDriver becomes a.b.c.d, a.b.c.d stays, anything else is empty' ((ConvertTo-AVDTunePrinterVersion $u64) -eq '7.1.0.2500' -and (ConvertTo-AVDTunePrinterVersion '2.4.0.300') -eq '2.4.0.300' -and (ConvertTo-AVDTunePrinterVersion 'x') -eq '' -and (ConvertTo-AVDTunePrinterVersion $null) -eq '') (ConvertTo-AVDTunePrinterVersion $u64)
    Test-Check 'availability: a domain controller in the answers opens the page; Entra only (Dc None or no answers) means Universal Print' ((Get-AVDTunePrinterAvailability ([pscustomobject]@{ Dc = 'AdDsOnPrem' })).Domain -and (Get-AVDTunePrinterAvailability ([pscustomobject]@{ Dc = 'EntraDs' })).Domain -and -not (Get-AVDTunePrinterAvailability ([pscustomobject]@{ Dc = 'None' })).Domain -and -not (Get-AVDTunePrinterAvailability $null).Domain) $null

    # ---------------------------------------------------------------- AD and inventory (read only)
    $ldap = New-AVDTuneFakeLdap
    $found = Find-AVDTunePrintServers -Ldap $ldap -Connection 'c'
    Test-Check 'AD: the print servers of the printQueue objects with their printer count; a name that is not a host name is left out and named' (($found.Servers | ForEach-Object { "$($_.Name)=$($_.Printers)" }) -join ',' -eq 'print1.example.test=2,print2.example.test=1' -and @($found.Skipped).Count -eq 1 -and @($ldap.Log | Where-Object { $_ -like 'Search Subtree DC=example,DC=test (objectCategory=printQueue)' }).Count -eq 1) "$(($found.Servers | ForEach-Object { "$($_.Name)=$($_.Printers)" }) -join ',') / $($ldap.Log -join ' | ')"
    $p = New-AVDTuneFakePrinters
    Test-Check 'inventory: a UNC path or a path as server is refused before anything is asked' ((Get-ThrownText { Get-AVDTunePrinterInventory -P $p -Server '\\print1.example.test' -Credential $cred }) -like '*not a host name*' -and $p.Store.Log.Count -eq 0) $null
    Test-Check 'inventory: without the domain account the server refuses (the account is required)' ((Get-ThrownText { Get-AVDTunePrinterInventory -P $p -Server 'print1.example.test' }) -like '*denied*') $null
    $inv = Get-AVDTunePrinterInventory -P $p -Server 'PRINT1.example.test' -Credential $cred
    $lab = @($inv.Printers | Where-Object { $_.Name -eq 'Label Printer' })[0]; $plot = @($inv.Printers | Where-Object { $_.Name -eq 'Old Plotter' })[0]
    Test-Check 'inventory: the shared printers only, each with driver, version, architecture, package-aware; a driver without x64 version is a problem; read with the domain account' ($inv.Printers.Count -eq 4 -and $lab.Driver -eq 'Example Label Driver' -and $lab.Version -eq '2.4.0.300' -and $lab.Architecture -eq 'Windows x64' -and -not $lab.PackageAware -and $plot.Problem -like '*no Windows x64 driver*' -and $inv.Server -eq 'print1.example.test' -and @($p.Store.Credentials | Where-Object { $_ -ne 'EXAMPLE\admin1' }).Count -eq 0) (($inv.Printers | ForEach-Object { "$($_.Name)|$($_.Version)|$($_.Problem)" }) -join ' ; ')
    $plan = @(Get-AVDTunePrinterDriverPlan -Inventory $inv)
    $one = @(Get-AVDTunePrinterDriverPlan -Inventory $inv -Selected @('Label Printer'))
    Test-Check 'plan: default all shared printers, the distinct drivers each with its printers; a selection gives only its drivers; a printer with a problem is never in it' ($plan.Count -eq 2 -and (@($plan | Where-Object { $_.Name -eq 'Example Universal PCL6' })[0].Printers -join ',') -eq 'Floor 1 Color,Floor 2 Color' -and $one.Count -eq 1 -and $one[0].Name -eq 'Example Label Driver' -and @(Get-AVDTunePrinterDriverPlan -Inventory $inv -Selected @('Old Plotter')).Count -eq 0) (($plan | ForEach-Object { "$($_.Name)=$($_.Printers -join '+')" }) -join ' ; ')

    # ---------------------------------------------------------------- Apply
    Test-Check 'run: without the confirmed snapshot gate nothing is installed' ((Get-ThrownText { Invoke-AVDTunePrinterRun -Machine $m -P $p -Root $tmp -Drivers $plan -Credential $cred -Policy }) -like '*gate*' -and $p.Store.Local.Count -eq 0) $null
    Open-AVDTuneWriteGate -SnapshotId 'snap-1' -ConfirmedBy 'admin1'
    $p.Store.Registry['hklm:\software\policies\microsoft\windows nt\printers\packagepointandprint\listofservers|old.example.test'] = @{ Value = 'old.example.test'; Kind = 'String' }
    $r = Invoke-AVDTunePrinterRun -Machine $m -P $p -Root $tmp -Drivers $plan -Credential $cred -Policy -User 'admin1' -SnapshotId 'snap-1'
    $st = $p.Store
    Test-Check 'apply: both drivers installed with the version of the server, the check says so for each' ($st.Local['Example Universal PCL6'] -eq '7.1.0.2500' -and $st.Local['Example Label Driver'] -eq '2.4.0.300' -and @($r.Check | Where-Object { -not $_.Ok }).Count -eq 0 -and @($r.Check).Count -eq 2 -and @($r.Run.Results | Where-Object { $_.Status -ne 'Changed' }).Count -eq 0) (($r.Run.Results | ForEach-Object { "$($_.Id)=$($_.Status) $($_.Message)" }) -join ' | ')
    Test-Check 'apply: the package-aware driver came by a temporary connection that is gone again; no WinRM for it' (@($st.Log | Where-Object { $_ -eq 'Connect \\print1.example.test\F1-Color' }).Count -eq 1 -and @($st.Log | Where-Object { $_ -eq 'Disconnect \\print1.example.test\F1-Color' }).Count -eq 1 -and $st.Connections.Count -eq 0 -and @($st.Log | Where-Object { $_ -like 'RemoteOpen*' }).Count -eq 1) ($st.Log -join ' | ')
    Test-Check 'apply: the other driver by export of only its INF over WinRM, copied, pnputil /add-driver and Add-PrinterDriver; remote and local temporary folders and the session gone' (@($st.Log | Where-Object { $_ -eq 'RemoteExport C:\Windows\System32\DriverStore\FileRepository\exlabel.inf_amd64_2\exlabel.inf' }).Count -eq 1 -and @($st.Log | Where-Object { $_ -like 'AddDriverPackage *\exlabel.inf' }).Count -eq 1 -and @($st.Log | Where-Object { $_ -eq 'AddDriver Example Label Driver' }).Count -eq 1 -and $st.RemoteFolders.Count -eq 0 -and $st.LocalFolders.Count -eq 0 -and $st.Sessions.Count -eq 0) ($st.Log -join ' | ')
    Test-Check 'TrustedHosts: appended for the export and restored exactly afterwards (the other entry kept), no journal left' ($st.TrustedHosts -ceq 'admin1.example.test' -and ($st.TrustedHistory -join ' > ') -ceq 'admin1.example.test,print1.example.test > admin1.example.test' -and -not (Test-Path (Get-AVDTunePrinterJournalPath $tmp))) ($st.TrustedHistory -join ' > ')
    $pol = 'hklm:\software\policies\microsoft\windows nt\printers'
    Test-Check 'Point and Print: RestrictDriverInstallationToAdministrators = 1, the package list flag on and only the chosen server in the list (another entry removed)' ($st.Registry["$pol\pointandprint|restrictdriverinstallationtoadministrators"].Value -eq 1 -and $st.Registry["$pol\packagepointandprint|packagepointandprintserverlist"].Value -eq 1 -and $st.Registry["$pol\packagepointandprint\listofservers|print1.example.test"].Value -eq 'print1.example.test' -and -not $st.Registry.ContainsKey("$pol\packagepointandprint\listofservers|old.example.test")) (($st.Registry.Keys | Sort-Object) -join ', ')
    $log = @(Get-AVDTuneChangeLog -Root $tmp | Where-Object { $_.Category -eq 'Printers' })
    Test-Check 'change log: one entry per change (category Printers) naming driver, version, server and printers' ($log.Count -eq 4 -and @($log | Where-Object { $_.Text -eq 'Printer driver Example Universal PCL6 7.1.0.2500 from print1.example.test (printers: Floor 1 Color, Floor 2 Color)' }).Count -eq 1 -and @($log | Where-Object { $_.Text -like 'Printer driver Example Label Driver 2.4.0.300 from print1.example.test (printers: Label Printer)' }).Count -eq 1 -and (Get-AVDTuneState $tmp).LastChange) (($log | ForEach-Object { $_.Text }) -join ' | ')
    $saved = Get-AVDTunePrinterState -Root $tmp
    $undo = Read-AVDTunePrinterUndo $tmp
    Test-Check 'state: printers.json has the server and both drivers with version and printers; the undo record has the policies before and the two added drivers' (($saved.Servers -join ',') -eq 'print1.example.test' -and $saved.Drivers.Count -eq 2 -and $undo.Policy -and $undo.Drivers.Count -eq 2) ($saved | ConvertTo-Json -Depth 5 -Compress)
    $again = Invoke-AVDTunePrinterRun -Machine $m -P $p -Root $tmp -Drivers $plan -Credential $cred -Policy -User 'admin1' -SnapshotId 'snap-1'
    Test-Check 'apply again: everything in place, nothing changed, no new connection or export' (@($again.Run.Results | Where-Object { $_.Status -ne 'Unchanged' }).Count -eq 0 -and @($st.Log | Where-Object { $_ -like 'RemoteExport*' }).Count -eq 1) $null

    # ---------------------------------------------------------------- maintenance (skeleton)
    $st.Servers['print1.example.test'].Drivers[0].Version = '7.2.0.1000'
    $st.Servers['print1.example.test'].Printers += @{ Name = 'Floor 3'; ShareName = 'F3'; Shared = $true; DriverName = 'Example New Driver' }
    $st.Servers['print1.example.test'].Drivers += @{ Name = 'Example New Driver'; Environment = 'Windows x64'; Version = '1.0.0.300'; InfPath = 'C:\Windows\INF\oem9.inf'; PackageAware = $true }
    $cmp = @(Compare-AVDTunePrinterDrivers -Installed $saved.Drivers -Server @(Get-AVDTunePrinterDriverPlan -Inventory (Get-AVDTunePrinterInventory -P $p -Server 'print1.example.test' -Credential $cred)))
    Test-Check 'maintenance: a new version on the server is Changed, a driver of a new printer is New, the unchanged one Same' ((($cmp | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Status)" }) -join ',') -eq 'Example Label Driver=Same,Example New Driver=New,Example Universal PCL6=Changed') (($cmp | ForEach-Object { "$($_.Name)=$($_.Status)" }) -join ',')
    $st.Servers['print1.example.test'].Drivers[0].Version = '7.1.0.2500'

    # ---------------------------------------------------------------- failures and crash
    foreach ($sub in 'x', 'z') { [void](Initialize-AVDTuneState -Root (Join-Path $tmp $sub)) }
    $p2 = New-AVDTuneFakePrinters; $p2.Store.FailExport = $true
    $r2 = Invoke-AVDTunePrinterRun -Machine $m -P $p2 -Root (Join-Path $tmp 'x') -Drivers $one -Credential $cred -User 'admin1' -SnapshotId 'snap-1' -ErrorAction SilentlyContinue 2>$null
    Test-Check 'failed export: the step fails, TrustedHosts is exactly as before, the session and the local folder are gone' (@($r2.Run.Results | Where-Object { $_.Status -eq 'Failed' }).Count -eq 1 -and $p2.Store.TrustedHosts -ceq 'admin1.example.test' -and $p2.Store.Sessions.Count -eq 0 -and $p2.Store.LocalFolders.Count -eq 0 -and -not (Test-Path (Get-AVDTunePrinterJournalPath (Join-Path $tmp 'x')))) (($r2.Run.Results | ForEach-Object { "$($_.Status) $($_.Message)" }) -join ' | ')
    $p3 = New-AVDTuneFakePrinters; $p3.Store.FailRestore = $true
    $root3 = Join-Path $tmp 'y'; [void](Initialize-AVDTuneState -Root $root3)
    [void](Invoke-AVDTunePrinterRun -Machine $m -P $p3 -Root $root3 -Drivers $one -Credential $cred -User 'admin1' -SnapshotId 'snap-1')
    $kept = Test-Path (Get-AVDTunePrinterJournalPath $root3); $was = $p3.Store.TrustedHosts
    $fixed = Repair-AVDTunePrinterTrustedHosts -P $p3 -Root $root3
    Test-Check 'crash/refused restore: the journal stays with the old value, the next start (Repair) sets TrustedHosts back exactly and removes the journal' ($kept -and $was -like '*print1.example.test*' -and $fixed -and $p3.Store.TrustedHosts -ceq 'admin1.example.test' -and -not (Test-Path (Get-AVDTunePrinterJournalPath $root3)) -and -not (Repair-AVDTunePrinterTrustedHosts -P $p3 -Root $root3)) "kept=$kept was=$was now=$($p3.Store.TrustedHosts)"
    $p4 = New-AVDTuneFakePrinters; $p4.Store.TrustedHosts = '*'
    [void](Invoke-AVDTunePrinterRun -Machine $m -P $p4 -Root (Join-Path $tmp 'z') -Drivers $one -Credential $cred -User 'admin1' -SnapshotId 'snap-1')
    Test-Check 'TrustedHosts that already covers the server (*) is not touched' ($p4.Store.TrustedHistory.Count -eq 0 -and $p4.Store.Local['Example Label Driver'] -eq '2.4.0.300') $null

    # ---------------------------------------------------------------- Undo
    $u = Invoke-AVDTunePrinterRun -Machine $m -P $p -Root $tmp -Mode Undo -User 'admin1' -SnapshotId 'snap-1'
    Test-Check 'undo: the policies are as before (restriction absent, the old list entry back, the flag absent) and the drivers AVDTune added are removed; the record is empty' (-not $st.Registry.ContainsKey("$pol\pointandprint|restrictdriverinstallationtoadministrators") -and -not $st.Registry.ContainsKey("$pol\packagepointandprint|packagepointandprintserverlist") -and $st.Registry["$pol\packagepointandprint\listofservers|old.example.test"].Value -eq 'old.example.test' -and -not $st.Registry.ContainsKey("$pol\packagepointandprint\listofservers|print1.example.test") -and $st.Local.Count -eq 0 -and $null -eq (Read-AVDTunePrinterUndo $tmp).Policy -and (Read-AVDTunePrinterUndo $tmp).Drivers.Count -eq 0) (($u.Run.Results | ForEach-Object { "$($_.Id)=$($_.Status) $($_.Message)" }) -join ' | ')
    $p5 = New-AVDTuneFakePrinters; $p5.Store.Local['Example Label Driver'] = '2.0.0.300'
    $root5 = Join-Path $tmp 'w'; [void](Initialize-AVDTuneState -Root $root5)
    [void](Invoke-AVDTunePrinterRun -Machine $m -P $p5 -Root $root5 -Drivers $one -Credential $cred -User 'admin1' -SnapshotId 'snap-1')
    Test-Check 'undo record: a driver that was there before (other version) is updated but never removed by undo' ($p5.Store.Local['Example Label Driver'] -eq '2.4.0.300' -and (Read-AVDTunePrinterUndo $root5).Drivers.Count -eq 0) $null

    # ---------------------------------------------------------------- sources
    $src = [IO.File]::ReadAllText((Join-Path $repo 'Modules\AVDTune.Printers.psm1'))
    $real = New-AVDTunePrinterAdapter
    $missing = @($p.PSObject.Properties.Name | Where-Object { $_ -notin 'Kind', 'Store' -and -not $real.PSObject.Properties[$_] })
    Test-Check 'real adapter: built without touching anything, it has every member of the fake' ($real.Kind -eq 'Real' -and $missing.Count -eq 0) ($missing -join ', ')
    Test-Check 'real adapter: pnputil with its full path from System32 and its signature check, started through the update adapter (job object, child start info #47); local temp only through Remove-AVDTuneTreeSafe and an admin-only work folder' ($src -match "Get-AVDTuneSystemFolder System\) 'pnputil\.exe'" -and $src -match "Test-AVDTuneToolTrust -Signature \(& \`$u\.VerifySignature \`$exe\) -Name 'pnputil\.exe'" -and $src -match '& \$u\.Run \$exe' -and $src -match 'New-AVDTuneWorkFolder -Path \$d -Base \$Root' -and $src -match 'Remove-AVDTuneTreeSafe -Path \$Path') $null
    Test-Check 'secrets: the password never becomes a managed string (no ConvertFrom-SecureString, no -AsPlainText, no NetworkCredential .Password, no PtrToString), the unmanaged copy is zeroed' ($src -notmatch 'ConvertFrom-SecureString' -and $src -notmatch 'AsPlainText' -and $src -notmatch 'GetNetworkCredential' -and $src -notmatch 'PtrToString' -and $src -match 'ZeroFreeGlobalAllocUnicode') $null
    Test-Check 'TrustedHosts: only appended (old value + server) and set back to the exact old value in finally, the journal removed only after that worked' ($src -match '"\$old,\$Server"' -and $src -match 'finally \{\s+try \{ & \$P\.TrustedHostsSet \$old; \$restored = \$true \}' -and $src -match 'if \(\$restored\) \{ \[void\]\(Remove-AVDTuneTreeSafe -Path \$path\) \}') $null
    $page = [IO.File]::ReadAllText((Join-Path $repo 'AVDTune-Printers.ps1'))
    Test-Check 'page: texts from the language files (T), the job through New-AVDTunePowerShell, writes check the gate and Assert-NoOtherWriter, the password is cleared and disposed, the TrustedHosts repair runs' ($page -match "T 'prn\." -and $page -match 'New-AVDTunePowerShell' -and $page -match 'Assert-NoOtherWriter' -and $page -match 'Test-AVDTuneWriteAllowed' -and $page -notmatch '\[powershell\]::Create' -and $page -match '\.Password\.Dispose\(\)' -and $page -match 'PwdPrn\.Clear\(\)' -and $page -match 'Repair-AVDTunePrinterTrustedHosts') $null
}
finally {
    Close-AVDTuneWriteGate
    Remove-Item Env:\AVDTUNE_ROOT -ErrorAction SilentlyContinue
    if (Test-Path $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
if ($script:failed -gt 0) { throw "$script:failed check(s) failed." }
'Check-Printers: all checks passed.'
