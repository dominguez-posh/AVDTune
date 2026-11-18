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
        Effects = @{ ($sha['example-app.msi']) = @{ ExitCode = 0; Programs = @{ $ukey = @{ DisplayName = 'Example App <script>alert(1)</script>'; DisplayVersion = '5.2.0' } }; Files = @{ 'C:\Program Files\Example\app.exe' = 'f|9|9' }; Services = @{ 'ExampleSvc' = 'Start=2;Type=16;ImagePath=C:\Program Files\Example\svc.exe' }; Shortcuts = @{ 'C:\Users\Public\Desktop\Example.lnk' = 'C:\Program Files\Example\app.exe' } }
            ($sha['example-app-2.msi']) = @{ ExitCode = 3010; Programs = @{ $ukey = @{ DisplayName = 'Example App'; DisplayVersion = '5.3.0' } }; Remove = @('C:\Program Files\Old\old.exe') }
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
    $listed = Get-AVDTuneRecordingStatus -R $r -Root $tmp
    $mine = @($listed.Apps | Where-Object { $_.Id -eq $app.Id })
    Test-Check 'update: a second install of the same app is refused; the update (3010 = done, restart pending) is number 002 and the list shows both, newest first, with the installed version; a removed file is listed' ($again -like '*record an update*' -and $u.Record.Result -eq 'Changed' -and (Split-Path $u.Folder -Leaf) -eq '002' -and $mine.Count -eq 1 -and @($mine[0].Versions).Count -eq 2 -and $mine[0].Latest.Number -eq 2 -and $mine[0].Installed -eq $true -and $mine[0].InstalledVersion -eq '5.3.0' -and $u.Record.Changes.Programs.Counts.Changed -eq 1 -and $u.Record.Changes.Files.Removed[0].Key -eq 'C:\Program Files\Old\old.exe') "$again / $($mine[0].InstalledVersion)"

    # refusals at run time: exit code, broken signature, a held file that does not match the pin, a timeout
    $exeRec = Invoke-AVDTuneRecording -Machine $mach -R $r -C $c -App $exeApp -Root $tmp -Context $ctx
    Test-Check 'refusal: an installer that ends with 1603 is a failed step and a failed record, the folder is unstaged' ($exeRec.Run.Results[0].Status -eq 'Failed' -and $exeRec.Run.Results[0].Message -like '*1603*' -and $exeRec.Record.Result -eq 'Failed' -and $r.Store.Staged.Count -eq 0) $exeRec.Run.Results[0].Message
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
    Test-Check 'real adapter: built with every block of the fake' (@(@('Snapshot', 'Stage', 'Hold', 'Release', 'Install', 'Unstage', 'ReadProgram', 'FileExists') | Where-Object { $real.$_ -isnot [scriptblock] -or $r.$_ -isnot [scriptblock] }).Count -eq 0) $null
    $modText = [IO.File]::ReadAllText((Join-Path $repo 'Modules\AVDTune.Recording.psm1'))
    Test-Check 'real adapter: msiexec through Invoke-AVDTuneSoftwareTool (lock, signature, hold), an .exe through Invoke-AVDTuneProgram in the lock, staged with New-AVDTuneDownloadFolder, removed with Remove-AVDTuneTreeSafe, held with read sharing only' ($modText -match "Invoke-AVDTuneSoftwareTool -U \`$u -Tool 'msiexec.exe'" -and $modText -match 'Invoke-AVDTuneLocked -U \$u -Script \{ Invoke-AVDTuneProgram -File \$Path' -and $modText -match "New-AVDTuneDownloadFolder -Root \`$Root -Prefix 'rec'" -and $modText -match 'Remove-AVDTuneTreeSafe -Path \$Folder' -and $modText -match '\[IO\.FileShare\]::Read\)' -and $modText -notmatch 'Start-Process|Invoke-Expression') $null
    $fakeText = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Fakes\FakeRecording.ps1'))
    $fakeCode = ($fakeText -split "`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
    Test-Check 'fake: the closures use language constructs only (no ForEach-Object, Where-Object, Join-Path: called from a runspace)' ($fakeCode -notmatch 'ForEach-Object|Where-Object|Join-Path') $null
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
