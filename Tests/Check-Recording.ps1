#requires -Version 5.1
<#
.SYNOPSIS
    Checks the custom software recording (Modules\AVDTune.Recording.psm1, issue #87, plan 3e) against the fake machine, the fake customization adapter (library and
    cache), the fake recording adapter and a temporary state folder: validation of the details (installer only from the library with its pinned SHA256, arguments
    as data, licence notes without keys or passwords, typed reading), the command, the signature rule, the bounded comparison, the proposal (detection, silent,
    uninstall), the documentation (encoded, no script), the recording through Invoke-AVDTune (write gate, marker, run record, change log, LastChange), every refusal
    (tampered download, held file that does not match, broken signature, exit code, timeout), update mode, the typed list, links in the record folder, and the page.
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
foreach ($m in 'AVDTune', 'AVDTune.Updates', 'AVDTune.Software', 'AVDTune.FSLogix', 'AVDTune.Directory', 'AVDTune.Masking', 'AVDTune.Custom', 'AVDTune.Recording') { Import-Module (Join-Path $repo "Modules\$m.psm1") -Force }
. (Join-Path $PSScriptRoot 'Fakes\FakeMachine.ps1')
. (Join-Path $PSScriptRoot 'Fakes\FakeCustom.ps1')
. (Join-Path $PSScriptRoot 'Fakes\FakeRecording.ps1')

$script:failed = 0
function Test-Check([string]$Name, [bool]$Ok, $Detail) { if ($Ok) { "PASS $Name" } else { $script:failed++; "FAIL $Name" + $(if ($null -ne $Detail) { "  -> $Detail" }) } }
function Get-ThrownText([scriptblock]$Block) { try { & $Block | Out-Null; $null } catch { $_.Exception.Message } }
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('avdtune-rec-' + [guid]::NewGuid().ToString('N'))
$outside = Join-Path ([IO.Path]::GetTempPath()) ('avdtune-rec-out-' + [guid]::NewGuid().ToString('N'))

try {
    $env:AVDTUNE_ROOT = $tmp
    [void](Initialize-AVDTuneState -Root $tmp)
    [void](Start-AVDTuneImageVersion -Root $tmp -Date ([datetime]'2026-11-18') -User 'admin1')
    Close-AVDTuneWriteGate
    $c = New-AVDTuneFakeCustom -Seed @{ Library = @{ 'example-app.msi' = 'MSI v1'; 'example-app-2.msi' = 'MSI v2'; 'vendor-setup.exe' = 'EXE'; 'notes.txt' = 'x' } }
    $sha = @{}; foreach ($k in @($c.Store.Library.Keys)) { $sha[$k] = & $c.Sha $c.Store.Library[$k] }
    $lib = @(foreach ($k in $sha.Keys) { [pscustomobject]@{ Name = $k; Sha256 = $sha[$k]; Size = 10; Extension = [IO.Path]::GetExtension($k) } })
    $form = @{ Name = 'Example App'; Vendor = 'Example Vendor'; Version = '5.2'; Contact = 'Ticket 4711'; Installer = 'example-app.msi'; Arguments = 'ALLUSERS=1'; Dependencies = 'VC++ 2015-2022'; LicenseNotes = 'Licence server lic1, port 27000'; TimeoutSeconds = '900' }

    # ---------------------------------------------------------------- details
    $ok = ConvertTo-AVDTuneRecordingApp -Raw $form -FromForm -Library $lib
    Test-Check 'details: a valid form gets an id, the timeout as a number and the SHA256 of the library file pinned' ($ok.Valid -and $ok.App.Id -cmatch '\A[0-9a-f]{12}\z' -and $ok.App.TimeoutSeconds -eq 900 -and $ok.App.Sha256 -eq $sha['example-app.msi'] -and -not $ok.Cleaned) ($ok.Errors -join ' ')
    $bad = @(
        @('no name', @{ Name = '' }), @('a script as installer', @{ Installer = 'notes.txt' }), @('a path as installer', @{ Installer = 'C:\Temp\setup.exe' }),
        @('& in the arguments', @{ Arguments = '/S & calc' }), @('% in the arguments', @{ Arguments = '/D=%TEMP%' }), @('an open quote', @{ Arguments = '/D="C:\Program Files' }),
        @('a line break in the contact', @{ Contact = "a`nb" }), @('a timeout of 10 s', @{ TimeoutSeconds = '10' }), @('a timeout of a day', @{ TimeoutSeconds = '86400' }), @('a version with a slash', @{ Version = '5/2' })
    )
    $wrong = @(foreach ($b in $bad) { $f = $form.Clone(); foreach ($k in $b[1].Keys) { $f[$k] = $b[1][$k] }; if ((ConvertTo-AVDTuneRecordingApp -Raw $f -FromForm -Library $lib).Valid) { $b[0] } })
    Test-Check 'details: refused (counter-tests): no name, a non-installer or a path, & % and open quotes in the arguments, control characters, timeouts out of 60..14400, a bad version' ($wrong.Count -eq 0) ($wrong -join ', ')
    $nolib = ConvertTo-AVDTuneRecordingApp -Raw $form -FromForm
    Test-Check 'details: without the library manifest there is no SHA256, so nothing can be recorded' (-not $nolib.Valid -and ($nolib.Errors -join ' ') -like '*SHA256*') ($nolib.Errors -join ' ')
    $f = $form.Clone(); $f.LicenseNotes = 'Lizenzschluessel: ABCD1-EFGH2-IJKL3-MNOP4, Passwort=geheim123 bei Fragen Herrn Muster'
    $cl = ConvertTo-AVDTuneRecordingApp -Raw $f -FromForm -Library $lib
    Test-Check 'details: keys and passwords in the licence notes are cleaned and the form says so' ($cl.Valid -and $cl.Cleaned -and $cl.App.LicenseNotes -notmatch 'geheim123|ABCD1-EFGH2' -and $cl.App.LicenseNotes -like '*Herrn Muster*') $cl.App.LicenseNotes
    $typed = $ok.App | ConvertTo-Json | ConvertFrom-Json; $typed.TimeoutSeconds = '900'
    $typed2 = $ok.App | ConvertTo-Json | ConvertFrom-Json; $typed2.LicenseNotes = 'Passwort: geheim'
    Test-Check 'details: from the state types are exact ("900" is not a number) and a stored note with a password is not taken' (-not (ConvertTo-AVDTuneRecordingApp -Raw $typed).Valid -and -not (ConvertTo-AVDTuneRecordingApp -Raw $typed2).Valid -and (ConvertTo-AVDTuneRecordingApp -Raw ($ok.App | ConvertTo-Json | ConvertFrom-Json)).Valid) $null

    # ---------------------------------------------------------------- command and signature (pure)
    $tok = @(Split-AVDTuneRecordingArguments '/S /D="C:\Program Files\Example" INSTALLDIR="C:\A B"')
    Test-Check 'arguments: split into tokens, a quoted part stays in its token without the quotes' ($tok.Count -eq 3 -and $tok[0] -ceq '/S' -and $tok[1] -ceq '/D=C:\Program Files\Example' -and $tok[2] -ceq 'INSTALLDIR=C:\A B') ($tok -join ' | ')
    $msi = Get-AVDTuneRecordingCommand -App $ok.App -Path 'C:\x\example-app.msi'
    $exeApp = (ConvertTo-AVDTuneRecordingApp -Raw (@{ Name = 'Vendor Tool'; Installer = 'vendor-setup.exe'; Arguments = '/S' }) -FromForm -Library $lib).App
    $exe = Get-AVDTuneRecordingCommand -App $exeApp -Path 'C:\x\vendor-setup.exe'
    Test-Check 'command: an .msi runs through msiexec /i <file> with the arguments, an .exe itself with its arguments' ($msi.Tool -eq 'msiexec.exe' -and ($msi.Arguments -join ' ') -ceq '/i C:\x\example-app.msi ALLUSERS=1' -and $exe.Tool -eq 'installer' -and ($exe.Arguments -join ' ') -ceq '/S') "$($msi.Arguments -join ' ') / $($exe.Arguments -join ' ')"
    $sigs = @{ Valid = $true; NotSigned = $true; NotTrusted = $true; UnknownError = $true; HashMismatch = $false; NotSupportedFileFormat = $false; Incompatible = $false; '' = $false }
    $sigWrong = @(foreach ($k in $sigs.Keys) { if ((Test-AVDTuneRecordingSignature @{ Status = $k; Subject = 'CN=X' }).Ok -ne $sigs[$k]) { $k } })
    Test-Check 'signature: a broken or unreadable signature stops the installer; unsigned or not trusted is allowed with a note (the pin is the anchor)' ($sigWrong.Count -eq 0 -and (Test-AVDTuneRecordingSignature @{ Status = 'NotSigned' }).Text -like '*SHA256*') ($sigWrong -join ', ')

    # ---------------------------------------------------------------- what the arguments may do (review #87, 1 and 2)
    $pf = @('C:\Program Files', 'C:\Program Files (x86)')
    $argOk = { param($inst, $text) $x = Test-AVDTuneRecordingArguments -Installer $inst -Arguments $text -ProgramFolders $pf; $x.Errors.Count -eq 0 }
    $goodMsi = '/qn /qb- /passive /norestart ALLUSERS=1 INSTALLDIR="C:\Program Files\Example App" SERVER_PORT=27000'
    $badMsi = @('TRANSFORMS=custom.mst', 'PATCH=fix.msp', '/p fix.msp', '/a', '/x', '/y', '/z', '/j', '/fa', '/l*v C:\Program Files\x.log', '/update fix.msp', '/uninstall', '/package x.msi', 'INSTALLDIR=\\srv\share\app', 'INSTALLDIR=C:\Data\App', 'installdir=C:\Program Files\x', 'INSTALLDIR=C:\Program Files\..\Windows', 'INSTALLDIR=C:\PROGRA~1\x', 'SETUP.EXE')
    $msiWrong = @(foreach ($t in $badMsi) { if (& $argOk 'a.msi' $t) { $t } })
    Test-Check 'msi arguments: only /qn /qb /qb- /quiet /passive /norestart and PROPERTY=value; TRANSFORMS, PATCH, /p /a /x /y /z /j /f /l* /update /uninstall /package, UNC values, paths outside Program Files and lower-case properties are refused (counter-tests)' ((& $argOk 'a.msi' $goodMsi) -and $msiWrong.Count -eq 0) ($msiWrong -join ' | ')
    $exeUnc = Test-AVDTuneRecordingArguments -Installer 'a.exe' -Arguments '/D=\\srv\share\app' -ProgramFolders $pf
    $exeOut = Test-AVDTuneRecordingArguments -Installer 'a.exe' -Arguments '/S /D=C:\Data\App' -ProgramFolders $pf
    $exeIn = Test-AVDTuneRecordingArguments -Installer 'a.exe' -Arguments '/S "/D=C:\Program Files\App"' -ProgramFolders $pf
    Test-Check 'exe arguments: a UNC path is refused, a path outside Program Files is a warning, one inside is fine' ($exeUnc.Errors.Count -eq 1 -and $exeOut.Errors.Count -eq 0 -and $exeOut.Warnings.Count -eq 1 -and $exeIn.Errors.Count -eq 0 -and $exeIn.Warnings.Count -eq 0) "$($exeUnc.Errors) / $($exeOut.Warnings)"
    $secretArgs = @(@('a.msi', 'PIDKEY=ABCDE-12345-FGHIJ-67890-KLMNO'), @('a.msi', 'SERIALNUMBER=123456'), @('a.msi', 'LICENSEKEY=abc'), @('a.msi', 'PASSWORD=geheim'), @('a.exe', '/password=geheim'), @('a.exe', '--token=abc'), @('a.exe', '/S /K=ABCDE-12345-FGHIJ-67890-KLMNO'), @('a.exe', '/S eyJhbGciOiJIUzI1NiJ9abcdefghijklmnopqrstuvwxyz0123'))
    $secWrong = @(foreach ($s in $secretArgs) { $x = Test-AVDTuneRecordingArguments -Installer $s[0] -Arguments $s[1] -ProgramFolders $pf; if (-not (@($x.Errors) -like '*vault*')) { $s[1] } })
    $fs = $form.Clone(); $fs.Arguments = 'PIDKEY=ABCDE-12345-FGHIJ-67890-KLMNO'
    $fsr = ConvertTo-AVDTuneRecordingApp -Raw $fs -FromForm -Library $lib
    Test-Check 'arguments with a key or password (PIDKEY, SERIALNUMBER, LICENSEKEY, PASSWORD, /password=, tokens) are refused with the vault hint, not cleaned' ($secWrong.Count -eq 0 -and -not $fsr.Valid -and $fsr.App.Arguments -ceq $fs.Arguments) ($secWrong -join ' | ')
    $sm = @{ Parse = @(@('S-1-5-32-544', 'S-1-5-18'), @('S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')); Name = @(@('S-1-5-32-544', 'S-1-5-21-1-2-3-1001'), @('S-1-5-11'), @(''), @()) }
    $smWrong = @(foreach ($k in $sm.Keys) { foreach ($o in $sm[$k]) { if ((Get-AVDTuneRecordingShortcutMode -Owners $o) -ne $k) { "$k<-$($o -join ',')" } } })
    Test-Check 'shortcuts (review #87, 4): opened only when folder and file belong to Administrators, SYSTEM or TrustedInstaller; otherwise only the name' ($smWrong.Count -eq 0) ($smWrong -join ' | ')

    # ---------------------------------------------------------------- comparison and proposal (pure)
    $b = @{ Programs = @{ 'k1' = [pscustomobject]@{ DisplayName = 'A'; DisplayVersion = '1' } }; Files = @{ 'C:\a' = 'f|1|1'; 'C:\b' = 'f|1|1' }; Registry = @{}; Services = @{}; Shortcuts = @{}; Truncated = @() }
    $a = @{ Programs = @{ 'k1' = [pscustomobject]@{ DisplayName = 'A'; DisplayVersion = '2' } }; Files = @{ 'C:\a' = 'f|2|2'; 'C:\c' = 'f|1|1' }; Registry = @{}; Services = @{ 'svc' = 'Start=2' }; Shortcuts = @{}; Truncated = @('Registry') }
    $d = Compare-AVDTuneRecordingSnapshot -Before $b -After $a
    Test-Check 'compare: added, removed and changed per area (a program by its version), cut areas of a snapshot are named' ($d.Files.Counts.Added -eq 1 -and $d.Files.Counts.Removed -eq 1 -and $d.Files.Counts.Changed -eq 1 -and $d.Programs.Counts.Changed -eq 1 -and $d.Services.Added[0].Key -eq 'svc' -and @($d.Truncated) -contains 'Registry') ($d.Truncated -join ',')
    $many = @{}; for ($i = 0; $i -lt 30; $i++) { $many["C:\f$i"] = 'f|1|1' }
    $dm = Compare-AVDTuneRecordingSnapshot -Before @{ Files = @{} } -After @{ Files = $many } -Max 10
    Test-Check 'compare: a list is cut at the limit, the count stays the full number and the area is named as cut' (@($dm.Files.Added).Count -eq 10 -and $dm.Files.Counts.Added -eq 30 -and @($dm.Truncated) -contains 'Files') "$(@($dm.Files.Added).Count) $($dm.Files.Counts.Added)"
    $guid = '{11111111-2222-3333-4444-555555555555}'
    $ukey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$guid"
    $pd = Compare-AVDTuneRecordingSnapshot -Before @{} -After @{ Programs = @{ 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Other' = [pscustomobject]@{ DisplayName = 'Runtime'; DisplayVersion = '14' }; $ukey = [pscustomobject]@{ DisplayName = 'Example App 5.2'; DisplayVersion = '5.2.0'; UninstallString = 'MsiExec.exe /X{x}' } } }
    $p = Get-AVDTuneRecordingProposal -App $ok.App -Changes $pd
    Test-Check 'proposal: the uninstall key whose name holds the app name is the detection rule; uninstall by product code, silent with /qn' ($p.Detection.Kind -eq 'Uninstall' -and $p.Detection.Key -eq $ukey -and $p.Detection.Version -eq '5.2.0' -and $p.Uninstall -ceq "msiexec.exe /x $guid /qn /norestart" -and $p.Silent -ceq 'msiexec.exe /i example-app.msi /qn /norestart') "$($p.Detection.Key) / $($p.Uninstall)"
    $pf = Get-AVDTuneRecordingProposal -App $exeApp -Changes (Compare-AVDTuneRecordingSnapshot -Before @{} -After @{ Files = @{ 'C:\Program Files\Vendor\tool.exe' = 'f|1|1' } })
    $pn = Get-AVDTuneRecordingProposal -App (ConvertTo-AVDTuneRecordingApp -Raw (@{ Name = 'Vendor Tool'; Installer = 'vendor-setup.exe' }) -FromForm -Library $lib).App -Changes (Compare-AVDTuneRecordingSnapshot -Before @{} -After @{})
    Test-Check 'proposal: without an uninstall key a new .exe in Program Files; without anything no rule; an .exe is silent only with the given arguments' ($pf.Detection.Kind -eq 'File' -and $pf.Detection.Key -eq 'C:\Program Files\Vendor\tool.exe' -and $pf.Silent -ceq 'vendor-setup.exe /S' -and $null -eq $pn.Detection -and $pn.Silent -eq '') $null

    # ---------------------------------------------------------------- the recording
    $mach = New-AVDTuneFakeMachine
    $r = New-AVDTuneFakeRecording -Seed @{ Programs = @{ 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Old' = @{ DisplayName = 'Old'; DisplayVersion = '1' } }; Files = @{ 'C:\Program Files\Old\old.exe' = 'f|1|1' }
        Effects = @{ ($sha['example-app.msi']) = @{ ExitCode = 0; Programs = @{ $ukey = @{ DisplayName = 'Example App <script>alert(1)</script>'; DisplayVersion = '5.2.0' } }; Files = @{ 'C:\Program Files\Example\app.exe' = 'f|9|9' }; Services = @{ 'ExampleSvc' = 'Start=2;Type=16;ImagePath=C:\Program Files\Example\svc.exe /password=svcSecret77' }; Shortcuts = @{ 'C:\Users\Public\Desktop\Example.lnk' = 'C:\Program Files\Example\app.exe --token=lnkSecret88' }; Output = 'installed, licence key: AAAAA-BBBBB-CCCCC-DDDDD-EEEEE' }
            ($sha['example-app-2.msi']) = @{ ExitCode = 3010; Programs = @{ $ukey = @{ DisplayName = 'Example App'; DisplayVersion = '5.3.0'; UninstallString = "MsiExec.exe /X$guid"; QuietUninstallString = 'setup.exe /uninstall /key=QQQQQ-WWWWW-EEEEE-RRRRR-TTTTT' } }; Remove = @('C:\Program Files\Old\old.exe') }
            ($sha['vendor-setup.exe']) = @{ ExitCode = 1603 } } }
    $ctx = @{ Fake = $true }
    $gateText = Get-ThrownText { Invoke-AVDTuneRecording -Machine $mach -R $r -C $c -App $ok.App -Root $tmp -Context $ctx }
    Test-Check 'recording: with the snapshot gate closed nothing is installed, staged or recorded' ($gateText -like '*snapshot gate*' -and $r.Store.Installs.Count -eq 0 -and $r.Store.Snapshots -eq 0 -and -not (Test-Path (Get-AVDTuneRecordingRoot $tmp))) $gateText
    Open-AVDTuneWriteGate -SnapshotId 'snap-1' -ConfirmedBy 'admin1'
    $notPinned = $ok.App.PSObject.Copy(); $notPinned.Sha256 = 'a' * 64
    $np = Get-ThrownText { Invoke-AVDTuneRecording -Machine $mach -R $r -C $c -App $notPinned -Root $tmp -Context $ctx }
    $npRun = (Get-AVDTuneRecordedApps -Root $tmp).Apps
    Test-Check 'recording: an installer whose library file does not match the pinned SHA256 is not run (download refused); the failed attempt is recorded' ($r.Store.Installs.Count -eq 0 -and @($npRun).Count -eq 1 -and $npRun[0].Latest.Result -eq 'Failed') "$np / $(@($npRun).Count)"
    # a new app id for the real install (the failed attempt above holds the first one)
    $app = (ConvertTo-AVDTuneRecordingApp -Raw $form -FromForm -Library $lib).App
    $sync = [hashtable]::Synchronized(@{ Text = '' })
    $res = Invoke-AVDTuneRecording -Machine $mach -R $r -C $c -App $app -Root $tmp -Context $ctx -User 'admin1' -SnapshotId 'snap-1' -Progress $sync
    $rec = $res.Record
    Test-Check 'recording: the .msi is installed through msiexec /i with the arguments, staged and unstaged, held and released' ($r.Store.Installs.Count -eq 1 -and $r.Store.Installs[0].Tool -eq 'msiexec.exe' -and $r.Store.Installs[0].Arguments[0] -eq '/i' -and $r.Store.Installs[0].Arguments[-1] -eq 'ALLUSERS=1' -and $r.Store.Installs[0].Timeout -eq 900 -and $r.Store.Staged.Count -eq 0 -and $r.Store.Holds -eq $r.Store.Releases) "$($r.Store.Installs[0].Arguments -join ' ')"
    Test-Check 'recording: the changes of every area, the detection rule and the uninstall command are in the record' ($rec.Result -eq 'Changed' -and $rec.Changes.Programs.Counts.Added -eq 1 -and $rec.Changes.Files.Counts.Added -eq 1 -and $rec.Changes.Services.Counts.Added -eq 1 -and $rec.Changes.Shortcuts.Counts.Added -eq 1 -and $rec.Detection.Key -eq $ukey -and $rec.Uninstall -like "msiexec.exe /x $guid*" -and $rec.Signature -like 'Signed:*' -and $sync.Text -eq 'compare') "$($rec.Result) $($rec.Message)"
    $st = Get-AVDTuneState $tmp
    $log = @(Get-AVDTuneChangeLog -Root $tmp | Where-Object { $_.Category -eq 'Software' -and $_.Component -eq "software.custom-$($app.Id)" })
    Test-Check 'recording: through Invoke-AVDTune (run record, change log entry, LastChange) and the change marker is gone afterwards' ($log.Count -eq 1 -and $st.LastChange -and $rec.RunId -and -not (Test-AVDTuneChangeInProgress -Root $tmp)) $log.Count
    $doc = [IO.File]::ReadAllText((Join-Path $res.Folder 'documentation.html'))
    Test-Check 'documentation: saved next to record.json, every value encoded, no script, nothing loaded' ((Test-Path (Join-Path $res.Folder 'record.json')) -and $doc -notmatch '<script' -and $doc -like '*&lt;script&gt;*' -and $doc -like "*default-src 'none'*" -and (Split-Path $res.Folder -Leaf) -eq '001') (Split-Path $res.Folder -Leaf)
    $again = Get-ThrownText { Invoke-AVDTuneRecording -Machine $mach -R $r -C $c -App $app -Root $tmp -Context $ctx }
    $upd = $app.PSObject.Copy(); $upd.Installer = 'example-app-2.msi'; $upd.Sha256 = $sha['example-app-2.msi']; $upd.Version = '5.3'
    $u = Invoke-AVDTuneRecording -Machine $mach -R $r -C $c -App $upd -Root $tmp -Context $ctx -Kind Update -User 'admin1'
    $json1 = [IO.File]::ReadAllText((Join-Path $res.Folder 'record.json')) + [IO.File]::ReadAllText((Join-Path $u.Folder 'record.json')) + [IO.File]::ReadAllText((Join-Path $u.Folder 'documentation.html'))
    $prog = @($u.Record.Changes.Programs.Changed)[0].After
    Test-Check 'secrets (review #87, 3): service command lines, shortcut targets, uninstall strings and the installer output lose keys and passwords before they are stored; a product code (GUID) stays' ($json1 -notmatch 'svcSecret77|lnkSecret88|AAAAA-BBBBB|QQQQQ-WWWWW' -and $rec.Output -notlike '*AAAAA*' -and $prog.UninstallString -ceq "MsiExec.exe /X$guid" -and $prog.QuietUninstallString -like 'setup.exe /uninstall /key=(removed)*') "$($prog.UninstallString) | $($prog.QuietUninstallString) | $($rec.Output)"
    $bad2 = $app.PSObject.Copy(); $bad2.Installer = 'example-app-2.msi'; $bad2.Sha256 = $sha['example-app-2.msi']; $bad2.Arguments = 'TRANSFORMS=a.mst'
    $n1 = $r.Store.Installs.Count
    $reTxt = Get-ThrownText { Invoke-AVDTuneRecording -Machine $mach -R $r -C $c -App $bad2 -Root $tmp -Context $ctx -Kind Update }
    $storedOld = ConvertFrom-AVDTuneRecordingRecord -Json ((Get-Content -LiteralPath (Join-Path $res.Folder 'record.json') -Raw | ConvertFrom-Json) | ForEach-Object { $_.App.Arguments = 'TRANSFORMS=a.mst'; $_ }) -AppId $app.Id -Number 1
    Test-Check 'update (review #87, 1): arguments taken over are checked again (TRANSFORMS refused, nothing installed); a stored record keeps its arguments as history' ($reTxt -like '*TRANSFORMS*' -and $r.Store.Installs.Count -eq $n1 -and $storedOld.App.Arguments -eq 'TRANSFORMS=a.mst') $reTxt
    $listed = Get-AVDTuneRecordingStatus -R $r -Root $tmp
    $mine = @($listed.Apps | Where-Object { $_.Id -eq $app.Id })
    Test-Check 'update: a second install of the same app is refused; the update (3010 = done, restart pending) is number 002 and the list shows both, newest first, with the installed version; a removed file is listed' ($again -like '*record an update*' -and $u.Record.Result -eq 'Changed' -and (Split-Path $u.Folder -Leaf) -eq '002' -and $mine.Count -eq 1 -and @($mine[0].Versions).Count -eq 2 -and $mine[0].Latest.Number -eq 2 -and $mine[0].Installed -eq $true -and $mine[0].InstalledVersion -eq '5.3.0' -and $u.Record.Changes.Programs.Counts.Changed -eq 1 -and $u.Record.Changes.Files.Removed[0].Key -eq 'C:\Program Files\Old\old.exe') "$again / $($mine[0].InstalledVersion)"

    # refusals at run time: exit code, broken signature, a held file that does not match the pin, a timeout
    $exeRec = Invoke-AVDTuneRecording -Machine $mach -R $r -C $c -App $exeApp -Root $tmp -Context $ctx
    Test-Check 'refusal: an installer that ends with 1603 is a failed step and a failed record, the folder is unstaged' ($exeRec.Run.Results[0].Status -eq 'Failed' -and $exeRec.Run.Results[0].Message -like '*1603*' -and $exeRec.Record.Result -eq 'Failed' -and $r.Store.Staged.Count -eq 0) $exeRec.Run.Results[0].Message
    $exe2 = (ConvertTo-AVDTuneRecordingApp -Raw (@{ Name = 'Vendor Tool Two'; Installer = 'vendor-setup.exe'; Arguments = '/S' }) -FromForm -Library $lib).App
    [void](Invoke-AVDTuneRecording -Machine $mach -R $r -C $c -App $exe2 -Root $tmp -Context $ctx)
    $exeRuns = @($r.Store.Installs | Where-Object { $_.Tool -eq 'installer' })
    Test-Check 'TEMP (review #87, 5): every .exe recording gets its own TEMP folder inside its own download folder' ($exeRuns.Count -eq 2 -and $exeRuns[0].TempDir -like "$tmp\temp\rec-*\tmp" -and $exeRuns[0].TempDir -ne $exeRuns[1].TempDir -and $exeRuns[0].TempDir.StartsWith((Split-Path $exeRuns[0].Path -Parent) + '\')) (($exeRuns | ForEach-Object { $_.TempDir }) -join ' | ')
    $n0 = $r.Store.Installs.Count
    $r.Store.Signature[$sha['vendor-setup.exe']] = @{ Status = 'HashMismatch'; Subject = '' }
    $s2 = (ConvertTo-AVDTuneRecordingApp -Raw (@{ Name = 'Signed Tool'; Installer = 'vendor-setup.exe' }) -FromForm -Library $lib).App
    $sr = Invoke-AVDTuneRecording -Machine $mach -R $r -C $c -App $s2 -Root $tmp -Context $ctx
    $r.Store.Signature.Remove($sha['vendor-setup.exe']); $r.Store.Mismatch[$sha['vendor-setup.exe']] = $true
    $s3 = (ConvertTo-AVDTuneRecordingApp -Raw (@{ Name = 'Held Tool'; Installer = 'vendor-setup.exe' }) -FromForm -Library $lib).App
    $hr = Invoke-AVDTuneRecording -Machine $mach -R $r -C $c -App $s3 -Root $tmp -Context $ctx
    $r.Store.Mismatch.Clear(); $r.Store.Effects[$sha['vendor-setup.exe']] = @{ ExitCode = -1 }
    $s4 = (ConvertTo-AVDTuneRecordingApp -Raw (@{ Name = 'Slow Tool'; Installer = 'vendor-setup.exe' }) -FromForm -Library $lib).App
    $tr = Invoke-AVDTuneRecording -Machine $mach -R $r -C $c -App $s4 -Root $tmp -Context $ctx
    Test-Check 'refusal: a broken signature and a held file that does not match the pin start nothing; a timeout is named; every staged folder is removed' ($sr.Run.Results[0].Message -like '*broken*' -and $hr.Run.Results[0].Message -like '*pinned SHA256*' -and $r.Store.Installs.Count -eq $n0 + 1 -and $tr.Run.Results[0].Message -like '*did not end within*' -and $r.Store.Staged.Count -eq 0 -and $r.Store.Holds -eq $r.Store.Releases) "$($sr.Run.Results[0].Message) | $($hr.Run.Results[0].Message) | $($tr.Run.Results[0].Message)"
    $r.Store.Truncate = 'Files'
    $s5 = (ConvertTo-AVDTuneRecordingApp -Raw (@{ Name = 'Cut Tool'; Installer = 'example-app.msi' }) -FromForm -Library $lib).App
    $cr = Invoke-AVDTuneRecording -Machine $mach -R $r -C $c -App $s5 -Root $tmp -Context $ctx -Limits @{ ListPerArea = 5 }
    $r.Store.Truncate = ''
    Test-Check 'limits: an area the snapshot cut is named in the record and in the documentation' (@($cr.Record.Changes.Truncated) -contains 'Files' -and [IO.File]::ReadAllText((Join-Path $cr.Folder 'documentation.html')) -like '*Cut areas*Files*') ($cr.Record.Changes.Truncated -join ',')

    # ---------------------------------------------------------------- #93: more areas, notes, step images, reinstall
    $areas = @(Get-AVDTuneRecordingAreas)
    $newAreas = @('Tasks', 'Firewall', 'Odbc', 'Environment', 'Hosts', 'Fonts')
    Test-Check 'areas (#93): scheduled tasks, firewall rules, ODBC data sources, machine environment, hosts entries and fonts are areas of the comparison, each with a limit' (@($newAreas | Where-Object { $areas -notcontains $_ -or -not ((Get-AVDTuneRecordingLimits)[$_] -gt 0) }).Count -eq 0 -and $areas.Count -eq 11) ($areas -join ',')
    $hostsText = "# comment`r`n192.0.2.10   lic1.example  LIC1   # the licence server`r`n2001:db8::1`tdb.example`r`nnot-an-address broken.example`r`n192.0.2.11 bad_name! other.example`r`n192.0.2.12 lic1.example`r`n"
    $h = ConvertFrom-AVDTuneRecordingHosts -Text $hostsText
    $hCut = ConvertFrom-AVDTuneRecordingHosts -Text $hostsText -Limit 2
    Test-Check 'hosts: name -> address, comments and lines without a valid address or name left out, a second address of a name joined, cut at the limit (counter-tests)' ($h.Map.Count -eq 4 -and $h.Map['lic1.example'] -ceq '192.0.2.10, 192.0.2.12' -and $h.Map['lic1'] -ceq '192.0.2.10' -and $h.Map['db.example'] -ceq '2001:db8::1' -and $h.Map['other.example'] -ceq '192.0.2.11' -and -not $h.Map.ContainsKey('broken.example') -and -not $h.Truncated -and $hCut.Map.Count -eq 2 -and $hCut.Truncated) (($h.Map.Keys | Sort-Object) -join ',')
    $taskXml = '<?xml version="1.0" encoding="UTF-16"?><Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"><Principals><Principal id="Author"><UserId>S-1-5-18</UserId></Principal></Principals><Actions Context="Author"><Exec><Command>C:\Program Files\Example\update.exe</Command><Arguments>/silent /check</Arguments></Exec><Exec><Command>C:\Program Files\Example\second.exe</Command></Exec></Actions></Task>'
    $tx = ConvertFrom-AVDTuneRecordingTaskXml $taskXml
    $dtd = ConvertFrom-AVDTuneRecordingTaskXml ('<?xml version="1.0"?><!DOCTYPE Task [<!ENTITY x SYSTEM "file:///C:/Windows/win.ini">]><Task><Actions><Exec><Command>&x;</Command></Exec></Actions></Task>')
    Test-Check 'tasks: the definition gives the account and every program with its arguments; a definition with a DTD, broken XML or more than 512 KB is not read (counter-tests)' ($tx -ceq 'as S-1-5-18: C:\Program Files\Example\update.exe /silent /check ; C:\Program Files\Example\second.exe' -and $dtd -ceq '(not readable)' -and (ConvertFrom-AVDTuneRecordingTaskXml '<Task><Actions>') -ceq '(not readable)' -and (ConvertFrom-AVDTuneRecordingTaskXml ('<Task>' + ('x' * 524288) + '</Task>')) -ceq '(not readable)' -and (ConvertFrom-AVDTuneRecordingTaskXml '<Task><Actions><ComHandler><ClassId>x</ClassId></ComHandler></Actions></Task>') -ceq '(ComHandler)') "$tx | $dtd"
    $long = Get-AVDTuneRecordingLongValue ('C:\a;' * 400) 600; $long2 = Get-AVDTuneRecordingLongValue (('C:\a;' * 400) + 'C:\new') 600
    Test-Check 'long values (PATH): cut at the limit with the length and a hash, so a change behind the cut is still a change; a short value stays as it is' ($long.Length -lt 700 -and $long -cne $long2 -and $long.Substring(0, 600) -ceq $long2.Substring(0, 600) -and (Get-AVDTuneRecordingLongValue "a`tb" 600) -ceq 'a b') $long.Length
    $prot = Protect-AVDTuneRecordingSnapshot @{ Tasks = @{ '\Vendor\Sync' = 'as S-1-5-18: C:\x\sync.exe /password=taskSecret11' }; Firewall = @{ 'r1' = 'v2.31|Action=Allow|App=C:\x\a.exe|Name=Vendor|' }; Odbc = @{ '64-bit\Vendor' = 'Driver=SQL Server;Server=db.example;pwd=odbcSecret22' }
        Environment = @{ 'VENDOR_API_KEY' = 'plainvalue33'; 'VENDOR_LICENSE' = 'x'; 'VENDOR_HOME' = 'C:\Program Files\Vendor'; 'CONN' = 'server=db.example;password=envSecret44' }; Hosts = @{ 'lic1.example' = '192.0.2.10' }; Fonts = @{ 'Vendor Sans (TrueType)' = 'vendorsans.ttf' } }
    $protText = ($prot | ConvertTo-Json -Depth 4)
    Test-Check 'secrets (#93): command lines of tasks, ODBC values and environment values lose keys and passwords; an environment variable with a secret name loses its value whatever it is; the rest stays (counter-tests)' ($protText -notmatch 'taskSecret11|odbcSecret22|plainvalue33|envSecret44' -and $prot.Environment['VENDOR_API_KEY'] -ceq '(removed)' -and $prot.Environment['VENDOR_LICENSE'] -ceq '(removed)' -and $prot.Environment['VENDOR_HOME'] -ceq 'C:\Program Files\Vendor' -and $prot.Hosts['lic1.example'] -ceq '192.0.2.10' -and $prot.Fonts.Count -eq 1 -and $prot.Firewall['r1'] -like '*Name=Vendor*' -and $prot.Tasks['\Vendor\Sync'] -like 'as S-1-5-18: C:\x\sync.exe*') $protText
    $na = Compare-AVDTuneRecordingSnapshot -Before @{ Tasks = @{}; Hosts = @{ 'a.example' = '192.0.2.1' }; Fonts = @{ 'Old (TrueType)' = 'old.ttf' }; Environment = @{ 'Path' = 'C:\a' } } -After @{ Tasks = @{ '\Vendor\Sync' = 'x' }; Hosts = @{ 'a.example' = '192.0.2.2' }; Fonts = @{}; Environment = @{ 'Path' = 'C:\a;C:\b' }; Firewall = @{ 'r1' = 'x' }; Odbc = @{ '64-bit\V' = 'x' } }
    Test-Check 'compare (#93): the new areas are compared like the others (added, changed, removed)' ($na.Tasks.Counts.Added -eq 1 -and $na.Hosts.Counts.Changed -eq 1 -and $na.Fonts.Counts.Removed -eq 1 -and $na.Environment.Counts.Changed -eq 1 -and $na.Firewall.Counts.Added -eq 1 -and $na.Odbc.Counts.Added -eq 1) $null
    $live = @(foreach ($ar in 'Firewall', 'Environment', 'Hosts', 'Fonts', 'Odbc') { try { $g = Get-AVDTuneRecordingSystemArea -Area $ar -Limit 3; if ($g.Map -isnot [hashtable] -or $g.Map.Count -gt 3 -or @($g.Map.Values | Where-Object { $_ -isnot [string] -or $_.Length -gt 700 }).Count) { "${ar}: shape" } } catch { "${ar}: $($_.Exception.Message)" } })
    Test-Check 'real reading (#93, read only, on this computer): firewall rules, environment, hosts, fonts and ODBC come back as bounded text maps (limit 3 kept)' ($live.Count -eq 0) ($live -join ' | ')

    # notes (pure)
    $manyNotes = @(for ($i = 1; $i -le 60; $i++) { @{ Text = "note $i"; At = '2026-11-18T10:00:00.0000000+01:00'; Step = 2 } })
    $nn = ConvertTo-AVDTuneRecordingNotes -Notes $manyNotes
    $nv = ConvertTo-AVDTuneRecordingNotes -Notes @(@{ Text = "agreed with the vendor:`r`nport 27000, Passwort: noteSecret55"; At = 'yesterday'; Step = 5000 }, @{ Text = ('word ' * 180) }, @{ Text = 42 }, @{ Text = "  `t " }, $null)
    Test-Check 'notes: at most 50, each one line of at most 500 characters, secrets out, a wrong time or step dropped to empty/0, no text or empty text left out (counter-tests)' (@($nn.Notes).Count -eq 50 -and $nn.Dropped -eq 10 -and $nn.Notes[0].Step -eq 2 -and $nn.Notes[0].At -like '2026-11-18T10:00*' -and @($nv.Notes).Count -eq 2 -and $nv.Notes[0].Text -notmatch "noteSecret55|`n" -and $nv.Notes[0].Text -like 'agreed with the vendor: port 27000*' -and $nv.Notes[0].At -eq '' -and $nv.Notes[0].Step -eq 0 -and $nv.Notes[1].Text.Length -eq 500 -and $nv.Cleaned -eq 1 -and $nv.Dropped -eq 2) "$(@($nn.Notes).Count) $($nn.Dropped) $(@($nv.Notes).Count) $($nv.Dropped)"
    $ns = [hashtable]::Synchronized(@{ Text = ''; Steps = 1 })
    $add1 = Add-AVDTuneRecordingNote -Progress $ns -Text 'Option "Client only" chosen <b>as agreed</b>'
    $add2 = Add-AVDTuneRecordingNote -Progress $ns -Text 'Serial: ABCD1-EFGH2-IJKL3-MNOP4'
    $add3 = Add-AVDTuneRecordingNote -Progress $ns -Text '   '
    Test-Check 'notes: a note goes into the shared table with the current step, cleaned; an empty one is refused' ($add1.Accepted -and $add2.Accepted -and $add2.Cleaned -and $add2.Text -notmatch 'ABCD1' -and -not $add3.Accepted -and $add3.Reason -eq 'empty' -and $ns.Notes.Count -eq 2 -and $ns.Notes[0].Step -eq 1) "$($add2.Text) $($ns.Notes.Count)"
    $nf = [hashtable]::Synchronized(@{}); for ($i = 0; $i -lt 50; $i++) { [void](Add-AVDTuneRecordingNote -Progress $nf -Text "n$i") }
    Test-Check 'notes: the 51st note is refused (full)' ((Add-AVDTuneRecordingNote -Progress $nf -Text 'one more').Reason -eq 'full' -and $nf.Notes.Count -eq 50) $nf.Notes.Count

    # step images (pure)
    Add-Type -AssemblyName System.Drawing
    $newPng = { param([int]$w, [int]$h) $bmp = New-Object Drawing.Bitmap $w, $h; try { $ms = New-Object IO.MemoryStream; $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png); , $ms.ToArray() } finally { $bmp.Dispose() } }
    $png = & $newPng 8 8
    Test-Check 'step images: only bytes that start like a PNG are an image (counter-tests: empty, text, a cut signature)' ((Test-AVDTuneRecordingPng $png) -and -not (Test-AVDTuneRecordingPng ([byte[]]@())) -and -not (Test-AVDTuneRecordingPng ([Text.Encoding]::ASCII.GetBytes('<html><script>alert(1)</script></html> padding padding'))) -and -not (Test-AVDTuneRecordingPng ([byte[]]($png[0..20])))) $png.Length
    $procs = @(@{ Id = 100; Parent = 1; Start = 1000L }, @{ Id = 200; Parent = 100; Start = 2000L }, @{ Id = 300; Parent = 200; Start = 3000L }, @{ Id = 400; Parent = 100; Start = 500L }, @{ Id = 500; Parent = 100; Start = $null }, @{ Id = 600; Parent = 999; Start = 4000L }, @{ Id = 700; Parent = 400; Start = 5000L })
    $tree = @(Select-AVDTuneRecordingProcessTree -RootId 100 -Processes $procs)
    Test-Check 'step images: only windows of processes started by this AVDTune process (children and their children); never AVDTune itself, a process older than its "parent" (reused id), one without a start time, or a stranger (counter-tests)' (($tree -join ',') -ceq '200,300' -and @(Select-AVDTuneRecordingProcessTree -RootId 42 -Processes $procs).Count -eq 0) ($tree -join ',')
    $stp = @(ConvertTo-AVDTuneRecordingSteps -AppId 'aaaaaaaaaaaa' -Number 3 -Steps @(@{ Number = 1; File = 'aaaaaaaaaaaa-003-step-001.png'; Title = "Setup - Example`r`n/password=titleSecret66"; At = '2026-11-18T10:00:00Z'; Process = 'setup' }, @{ Number = 2; File = '..\..\x.png' }, @{ Number = 3; File = 'bbbbbbbbbbbb-003-step-003.png' }, @{ Number = 4; File = 'aaaaaaaaaaaa-002-step-004.png' }, @{ Number = '5'; File = 'aaaaaaaaaaaa-003-step-005.png' }, @{ Number = 6; File = 'aaaaaaaaaaaa-003-step-006.png" onerror="x' }))
    Test-Check 'step images: a stored step is used only with a file name of this app and recording (no path, no other app, no markup); its title is one line without secrets (counter-tests)' ($stp.Count -eq 1 -and $stp[0].File -ceq 'aaaaaaaaaaaa-003-step-001.png' -and $stp[0].Title -notmatch "titleSecret66|`n") ($stp | ForEach-Object { $_.File })

    # one recording with everything: the new areas, notes written while it runs, step images
    $r.Store.Effects[$sha['example-app.msi']] = @{ ExitCode = 0; Tasks = @{ '\Vendor\Sync' = 'as S-1-5-18: C:\Program Files\Vendor\sync.exe /password=taskSecret11' }; Firewall = @{ 'VendorIn' = 'v2.31|Action=Allow|Dir=In|App=C:\Program Files\Vendor\app.exe|' }
        Odbc = @{ '64-bit\Vendor' = 'Driver=SQL Server;Server=db.example;pwd=odbcSecret22' }; Environment = @{ 'VENDOR_API_KEY' = 'plainvalue33'; 'VENDOR_HOME' = 'C:\Program Files\Vendor' }; Hosts = @{ 'lic1.example' = '192.0.2.10' }; Fonts = @{ 'Vendor Sans (TrueType)' = 'vendorsans.ttf' } }
    $big = New-Object byte[] 5000; [Array]::Copy($png, $big, $png.Length)
    $r.Store.Shots = @(@{ Bytes = $png; Title = 'Setup - Example App <script>alert(2)</script>'; Process = 'msiexec' }, @{ Bytes = [Text.Encoding]::ASCII.GetBytes('<html>this is no picture, only text that says so</html>'); Title = 'not a png'; Process = 'x' }, @{ Bytes = $big; Title = 'too large'; Process = 'x' }, @{ Bytes = (& $newPng 16 16); Title = 'Setup - Finish'; Process = 'msiexec' })
    $s6 = (ConvertTo-AVDTuneRecordingApp -Raw (@{ Name = 'Area Tool'; Installer = 'example-app.msi' }) -FromForm -Library $lib).App
    $ar = Invoke-AVDTuneRecording -Machine $mach -R $r -C $c -App $s6 -Root $tmp -Context $ctx -Progress $ns -StepImages -Limits @{ StepImageBytes = 4000 }
    $arJson = [IO.File]::ReadAllText((Join-Path $ar.Folder 'record.json')); $arDoc = [IO.File]::ReadAllText((Join-Path $ar.Folder 'documentation.html'))
    Test-Check 'recording (#93): the changes of the new areas are in the record and the documentation, without the secrets' ($ar.Record.Result -eq 'Changed' -and @($newAreas | Where-Object { $ar.Record.Changes.$_.Counts.Added -ne $(if ($_ -eq 'Environment') { 2 } else { 1 }) -or $ar.Record.Counts.$_.Added -ne $ar.Record.Changes.$_.Counts.Added }).Count -eq 0 -and "$arJson$arDoc" -notmatch 'taskSecret11|odbcSecret22|plainvalue33' -and $arDoc -like '*<h2>Tasks: 1 added*' -and $arDoc -like '*<h2>Hosts: 1 added*' -and $arDoc -like '*lic1.example*') ($newAreas | ForEach-Object { "$_=$($ar.Record.Changes.$_.Counts.Added)" })
    $late = Add-AVDTuneRecordingNote -Progress $ns -Text 'too late'
    Test-Check 'notes: what was written while the recording ran is in record.json and (encoded) in the documentation; a note after the record was saved is refused (closed), not lost silently' (@($ar.Record.Notes).Count -eq 2 -and $arJson -like '*Client only*' -and $arJson -notmatch 'ABCD1' -and $arDoc -like '*Notes of the administrator (2)*' -and $arDoc -like '*&lt;b&gt;as agreed&lt;/b&gt;*' -and $arDoc -notlike '*<b>as agreed*' -and -not $late.Accepted -and $late.Reason -eq 'closed') "$(@($ar.Record.Notes).Count) $($late.Reason)"
    $stepDir = Join-Path $ar.Folder 'steps'; $stepFiles = @(Get-ChildItem -LiteralPath $stepDir -ErrorAction SilentlyContinue | ForEach-Object { $_.Name } | Sort-Object)
    $want = @("$($s6.Id)-001-step-001.png", "$($s6.Id)-001-step-002.png")
    Test-Check 'step images: the captured windows that are PNG files within the size limit are in <record>\steps under fixed names; the text file and the too large one are left out and counted (counter-tests)' (($stepFiles -join ',') -ceq ($want -join ',') -and @($ar.Record.Steps).Count -eq 2 -and $ar.Record.Steps[1].Title -ceq 'Setup - Finish' -and $ar.Record.StepNote -like '2 captured window(s) were not taken*' -and [IO.Directory]::GetAccessControl($stepDir).AreAccessRulesProtected) "$($stepFiles -join ',') | $($ar.Record.StepNote)"
    Test-Check 'step images: the documentation shows them as local <img> below steps/ (policy: img-src ''self'' data:, still no script and nothing else loaded), the window title encoded; the capture folder is removed' ($arDoc -like "*<img src=""steps/$($want[0])"" alt=""Step 1"">*" -and $arDoc -like "*default-src 'none'; style-src 'unsafe-inline'; img-src 'self' data:*" -and $arDoc -notmatch '<script|https?://' -and $arDoc -like '*Example App &lt;script&gt;*' -and $r.Store.Captures -eq 1 -and $r.Store.CapturesRemoved -eq 1 -and @(Get-ChildItem -LiteralPath (Join-Path $tmp 'temp') -Filter 'shots-*' -ErrorAction SilentlyContinue).Count -eq 0) "$($r.Store.Captures)/$($r.Store.CapturesRemoved)"
    $back = @((Get-AVDTuneRecordedApps -Root $tmp).Apps | Where-Object { $_.Id -eq $s6.Id })[0].Latest
    Test-Check 'list (#93): notes and steps come back typed from record.json' (@($back.Notes).Count -eq 2 -and @($back.Steps).Count -eq 2 -and $back.Steps[0].File -ceq $want[0] -and $back.Notes[0].Step -eq 1) "$(@($back.Notes).Count) $(@($back.Steps).Count)"
    $s7 = (ConvertTo-AVDTuneRecordingApp -Raw (@{ Name = 'No Image Tool'; Installer = 'example-app.msi' }) -FromForm -Library $lib).App
    $noImg = Invoke-AVDTuneRecording -Machine $mach -R $r -C $c -App $s7 -Root $tmp -Context $ctx
    $r.Store.CaptureFails = $true
    $s8 = (ConvertTo-AVDTuneRecordingApp -Raw (@{ Name = 'Capture Fails Tool'; Installer = 'example-app.msi' }) -FromForm -Library $lib).App
    $capFail = Invoke-AVDTuneRecording -Machine $mach -R $r -C $c -App $s8 -Root $tmp -Context $ctx -StepImages
    $r.Store.CaptureFails = $false; $r.Store.Shots = @()
    Test-Check 'step images: only when asked for (without -StepImages nothing is captured); a capture that cannot start does not stop the install, the record says why there are no images' ($r.Store.Captures -eq 1 -and @($noImg.Record.Steps).Count -eq 0 -and -not (Test-Path (Join-Path $noImg.Folder 'steps')) -and $capFail.Record.Result -eq 'Changed' -and $capFail.Record.StepNote -like 'No step images: the capture did not start*' -and [IO.File]::ReadAllText((Join-Path $capFail.Folder 'documentation.html')) -like '*No step images*') "$($r.Store.Captures) $($capFail.Record.StepNote)"

    # reinstall from the recipe
    $recipe = Get-AVDTuneRecordingRecipe -Root $tmp -AppId $app.Id
    $nRe = $r.Store.Installs.Count
    $failedOnly = Get-AVDTuneRecordingRecipe -Root $tmp -AppId $exeApp.Id
    $reNone = Get-ThrownText { Invoke-AVDTuneRecording -Machine $mach -R $r -C $c -App $exeApp -Root $tmp -Context $ctx -Kind Reinstall }
    $reArgs = $recipe.App.PSObject.Copy(); $reArgs.Arguments = 'ALLUSERS=1 /qn'
    $reFile = $recipe.App.PSObject.Copy(); $reFile.Installer = 'example-app.msi'; $reFile.Sha256 = $sha['example-app.msi']
    $reArgsText = Get-ThrownText { Invoke-AVDTuneRecording -Machine $mach -R $r -C $c -App $reArgs -Root $tmp -Context $ctx -Kind Reinstall }
    $reFileText = Get-ThrownText { Invoke-AVDTuneRecording -Machine $mach -R $r -C $c -App $reFile -Root $tmp -Context $ctx -Kind Reinstall }
    Close-AVDTuneWriteGate
    $reGate = Get-ThrownText { Invoke-AVDTuneRecording -Machine $mach -R $r -C $c -App $recipe.App -Root $tmp -Context $ctx -Kind Reinstall }
    Open-AVDTuneWriteGate -SnapshotId 'snap-1' -ConfirmedBy 'admin1'
    Test-Check 'reinstall: the recipe is the newest successful recording; refused without one, with other arguments, with another file and with the gate closed; nothing is installed then (counter-tests)' ($recipe.Number -eq 2 -and $recipe.App.Sha256 -eq $sha['example-app-2.msi'] -and $null -eq $failedOnly -and $reNone -like '*there is none*' -and $reArgsText -like '*Arguments is not the one of recording 002*' -and $reFileText -like '*is not the one of recording 002*' -and $reGate -like '*snapshot gate*' -and $r.Store.Installs.Count -eq $nRe) "$reNone | $reArgsText | $reFileText | $reGate"
    $h0 = $r.Store.Holds
    $re = Invoke-AVDTuneRecording -Machine $mach -R $r -C $c -App $recipe.App -Root $tmp -Context $ctx -Kind Reinstall -User 'admin1' -SnapshotId 'snap-1'
    $reRun = $r.Store.Installs[$r.Store.Installs.Count - 1]
    $reLog = @(Get-AVDTuneChangeLog -Root $tmp | Where-Object { $_.Component -eq "software.custom-$($app.Id)" })
    Test-Check 'reinstall: the same pinned file with the same arguments runs again through the same step (staged, held against the pin, signature read, change log, marker gone) and is recording 003 of the kind Reinstall' ($r.Store.Installs.Count -eq $nRe + 1 -and $reRun.Path -like '*\example-app-2.msi' -and $reRun.Arguments[-1] -ceq 'ALLUSERS=1' -and $reRun.Timeout -eq 900 -and $r.Store.Holds -eq $h0 + 1 -and $r.Store.Holds -eq $r.Store.Releases -and $r.Store.Staged.Count -eq 0 -and $re.Record.Kind -eq 'Reinstall' -and $re.Record.Number -eq 3 -and $re.Record.Result -eq 'Changed' -and $re.Record.Signature -like 'Signed:*' -and $reLog.Count -eq 3 -and -not (Test-AVDTuneChangeInProgress -Root $tmp) -and (Get-AVDTuneRecordingRecipe -Root $tmp -AppId $app.Id).Number -eq 3) "$($re.Record.Kind) $($re.Record.Number) $($reLog.Count)"
    $r.Store.Mismatch[$sha['example-app-2.msi']] = $true
    $reBad = Invoke-AVDTuneRecording -Machine $mach -R $r -C $c -App $recipe.App -Root $tmp -Context $ctx -Kind Reinstall
    $r.Store.Mismatch.Clear()
    Test-Check 'reinstall: a file that does not match the pin any more is not started (failed record, the recipe stays the last successful one)' ($reBad.Record.Result -eq 'Failed' -and $reBad.Run.Results[0].Message -like '*pinned SHA256*' -and $r.Store.Installs.Count -eq $nRe + 1 -and (Get-AVDTuneRecordingRecipe -Root $tmp -AppId $app.Id).Number -eq 3) $reBad.Run.Results[0].Message

    # ---------------------------------------------------------------- the stored list: typed, links not followed
    $first = Join-Path (Get-AVDTuneRecordingRoot $tmp) "$($app.Id)\001\record.json"
    $j = Get-Content -LiteralPath $first -Raw | ConvertFrom-Json; $j.App.TimeoutSeconds = '900'
    $badId = 'abcdefabcdef'; $badDir = Join-Path (Get-AVDTuneRecordingRoot $tmp) "$badId\001"
    New-AVDTuneRecordingFolder -Root $tmp -Parts @($badId, '001') | Out-Null
    Write-AVDTuneFile (Join-Path $badDir 'record.json') (($j | ConvertTo-Json -Depth 8) -replace $app.Id, $badId)
    $junk = Get-AVDTuneRecordedApps -Root $tmp
    Test-Check 'list: a stored record with a wrong type is not used and named in the notes' (@($junk.Apps | Where-Object { $_.Id -eq $badId }).Count -eq 0 -and @($junk.Notes | Where-Object { $_ -like "$badId*" }).Count -eq 1) ($junk.Notes -join ' | ')
    New-Item -ItemType Directory -Path $outside | Out-Null
    $linkId = '0123456789ab'
    New-Item -ItemType Junction -Path (Join-Path (Get-AVDTuneRecordingRoot $tmp) $linkId) -Value $outside | Out-Null
    $linkSave = Get-ThrownText { New-AVDTuneRecordingFolder -Root $tmp -Parts @($linkId, '001') }
    Test-Check 'storage: a record folder that is a link is refused (nothing written through it) and not listed' ($linkSave -and @(Get-ChildItem -LiteralPath $outside).Count -eq 0 -and @((Get-AVDTuneRecordedApps -Root $tmp).Apps | Where-Object { $_.Id -eq $linkId }).Count -eq 0) $linkSave
    Close-AVDTuneWriteGate

    # ---------------------------------------------------------------- the adapters and the page (source)
    $real = New-AVDTuneRecordingAdapter
    Test-Check 'real adapter: built with every block of the fake' (@(@('Snapshot', 'Stage', 'Hold', 'Release', 'Install', 'Unstage', 'ReadProgram', 'FileExists', 'StartCapture', 'StopCapture') | Where-Object { $real.$_ -isnot [scriptblock] -or $r.$_ -isnot [scriptblock] }).Count -eq 0) $null
    $modText = [IO.File]::ReadAllText((Join-Path $repo 'Modules\AVDTune.Recording.psm1'))
    Test-Check 'real adapter: msiexec through Invoke-AVDTuneSoftwareTool (lock, signature, hold), an .exe through Invoke-AVDTuneChildProcess in the lock with its own TEMP, a foreign .lnk only by name, staged with New-AVDTuneDownloadFolder, removed with Remove-AVDTuneTreeSafe, held with read sharing only' ($modText -match "Invoke-AVDTuneSoftwareTool -U \`$u -Tool 'msiexec.exe'" -and $modText -match 'Invoke-AVDTuneLocked -U \$u -Script \{ Invoke-AVDTuneChildProcess -FileName \$Path -Arguments \$line -TimeoutMs \(\$TimeoutSeconds \* 1000\) -CleanEnvironment -TempDir \$TempDir -Tool apps -WaitForTree' -and $modText -match "New-AVDTuneOwnFolder -Path \`$temp" -and $modText -match 'Get-AVDTuneRecordingShortcutMode -Owners \$own\) -ne ''Parse''\) \{ \$s\.Shortcuts\[\$p\] = "\(not opened' -and $modText -match "New-AVDTuneDownloadFolder -Root \`$Root -Prefix 'rec'" -and $modText -match 'Remove-AVDTuneTreeSafe -Path \$Folder' -and $modText -match '\[IO\.FileShare\]::Read\)' -and $modText -notmatch 'Start-Process|Invoke-Expression') $null
    Initialize-AVDTuneRecordingCapture
    $plist = @([AVDTune.Native.StepShot]::Processes())
    $me = @($plist | Where-Object { $_[0] -eq $PID })
    $wins = @([AVDTune.Native.StepShot]::Windows([int[]]@(0)))
    Test-Check 'step images, native part (compiled here, no window made or captured): the process list holds this process with its parent; no window belongs to process 0' ($plist.Count -gt 5 -and $me.Count -eq 1 -and $me[0][1] -gt 0 -and $wins.Count -eq 0) "$($plist.Count) $($me.Count)"
    Test-Check 'step images (source): the worker comes from New-AVDTunePowerShell, takes only windows of the process tree, leaves out windows with a password field (edit style and UI Automation IsPassword; a window that cannot be asked is left out), uses PrintWindow and never copies the screen, writes with New-AVDTuneAdminFile into a download folder' ($modText -match 'Select-AVDTuneRecordingProcessTree -RootId \$RootId' -and $modText -match 'HasPasswordEdit\(\$h\)\) \{ \$Sync\.Skipped' -and $modText -match 'IsPasswordProperty' -and $modText -match 'FindFirst\(\[System\.Windows\.Automation\.TreeScope\]::Descendants, \$isPassword\)\) \{ \$Sync\.Skipped = \[int\]\$Sync\.Skipped \+ 1; continue \} \} catch \{ continue \}' -and $modText -match 'PrintWindow\(hwnd, dc, 2\)' -and $modText -notmatch 'CopyFromScreen|BitBlt|GetDesktopWindow' -and $modText -match "New-AVDTuneDownloadFolder -Root \`$Root -Prefix 'shots'" -and $modText -match '\$ps = New-AVDTunePowerShell\s+\[void\]\$ps\.AddScript\(\$script:CaptureLoop\)' -and $modText -match '\$out = New-AVDTuneAdminFile -Path \$path') $null
    $fakeText = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Fakes\FakeRecording.ps1'))
    Test-Check 'fake: loads FakeShared and the factory ends with ConvertTo-AVDTuneFakeShared (#80: shared with a runspace), its blocks are unbound' ($fakeText -match "Resolve-AVDTuneTestScript -Path \(Join-Path \`$PSScriptRoot 'FakeShared\.ps1'\)" -and $fakeText -match 'ConvertTo-AVDTuneFakeShared \(\[pscustomobject\]\$r\)\s*\}\s*\z' -and $null -eq $r.Install.Module) $null
    $page = [IO.File]::ReadAllText((Join-Path $repo 'AVDTune-CustomSoftware.ps1'))
    Test-Check 'page: background runspace (New-AVDTunePowerShell), writer job behind the gate (Assert-NoOtherWriter), tasks, texts from the language files' ($page -match 'New-AVDTunePowerShell' -and $page -match 'Assert-NoOtherWriter' -and $page -match 'Test-AVDTuneWriteAllowed' -and $page -match 'Start-AVDTuneUiTask' -and $page -match "T 'csw\." -and $page -match 'Invoke-AVDTuneRecording') $null
}
finally {
    Close-AVDTuneWriteGate
    Remove-Item Env:\AVDTUNE_ROOT -ErrorAction SilentlyContinue
    foreach ($p in $tmp, $outside) { if (Test-Path -LiteralPath $p) { try { [void](Remove-AVDTuneTreeSafe -Path $p) } catch { } } }
}
if ($script:failed -gt 0) { "$script:failed check(s) failed."; exit 1 }
'All recording checks passed.'
