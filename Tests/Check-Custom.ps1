#requires -Version 5.1
<#
.SYNOPSIS
    Checks the customizations (Modules\AVDTune.Custom.psm1, issue #85, plan 3d) against the fake machine, the fake customization adapter, the fake package store and a
    temporary state folder: validation of every kind (paths, UNC, HKLM only, control characters, regex with limits), typed reading of the state, ini and hosts text,
    Test/Apply/Undo of every kind through Invoke-AVDTune (write gate, run record, change log, undo record that keeps the oldest state), re-apply after a "rollback",
    library files pinned by SHA256 (tampered download refused, scripts only when they match), fonts listed and removable, shortcuts with reachability and the
    request to App Masking, and source checks of the page. Nothing touches this computer.
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
foreach ($m in 'AVDTune', 'AVDTune.Updates', 'AVDTune.Software', 'AVDTune.FSLogix', 'AVDTune.Directory', 'AVDTune.Masking', 'AVDTune.Custom') { Import-Module (Join-Path $repo "Modules\$m.psm1") -Force }
. (Join-Path $PSScriptRoot 'Fakes\FakeMachine.ps1')
. (Join-Path $PSScriptRoot 'Fakes\FakeCustom.ps1')
. (Join-Path $PSScriptRoot 'Fakes\FakeSoftware.ps1')

$script:failed = 0
function Test-Check([string]$Name, [bool]$Ok, $Detail) { if ($Ok) { "PASS $Name" } else { $script:failed++; "FAIL $Name" + $(if ($null -ne $Detail) { "  -> $Detail" }) } }
function Get-ThrownText([scriptblock]$Block) { try { & $Block | Out-Null; $null } catch { $_.Exception.Message } }
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('avdtune-custom-' + [guid]::NewGuid().ToString('N'))
$forbidden = @{ Exact = @('C:', 'C:\Program Files', 'C:\Program Files (x86)', 'C:\ProgramData', 'C:\Users'); Below = @('C:\Windows', $tmp); Programs = @('C:\Program Files', 'C:\Program Files (x86)', 'C:\ProgramData') }
function Test-Item([hashtable]$Raw, [switch]$FromForm, [object[]]$Library) { ConvertTo-AVDTuneCustomItem -Raw $Raw -FromForm:$FromForm -Library $Library -Forbidden $forbidden }

try {
    $env:AVDTUNE_ROOT = $tmp
    [void](Initialize-AVDTuneState -Root $tmp)
    [void](Start-AVDTuneImageVersion -Root $tmp -Date ([datetime]'2026-11-17') -User 'admin1')
    Close-AVDTuneWriteGate

    # ---------------------------------------------------------------- validation
    $ok = Test-Item @{ Kind = 'Registry'; Name = 'Proxy off'; Path = 'HKEY_LOCAL_MACHINE\SOFTWARE\Contoso'; ValueName = 'Proxy'; ValueType = 'DWord'; Value = '0x1' } -FromForm
    Test-Check 'registry: HKEY_LOCAL_MACHINE\ becomes HKLM:\, a hex DWord is taken, an id is made' ($ok.Valid -and $ok.Item.Path -eq 'HKLM:\SOFTWARE\Contoso' -and $ok.Item.Id -cmatch '\A[0-9a-f]{12}\z') ($ok.Errors -join ' ')
    $bad = @(
        @('HKCU', @{ Kind = 'Registry'; Name = 'x'; Path = 'HKCU:\Software\X'; ValueName = 'a'; ValueType = 'String'; Value = 'b' }),
        @('HKLM\SAM', @{ Kind = 'Registry'; Name = 'x'; Path = 'HKLM:\SAM\X'; ValueName = 'a'; ValueType = 'String'; Value = 'b' }),
        @('wildcard in a key', @{ Kind = 'Registry'; Name = 'x'; Path = 'HKLM:\SOFTWARE\*'; ValueName = 'a'; ValueType = 'String'; Value = 'b' }),
        @('DWord too big', @{ Kind = 'Registry'; Name = 'x'; Path = 'HKLM:\SOFTWARE\X'; ValueName = 'a'; ValueType = 'DWord'; Value = '4294967296' }),
        @('unknown type', @{ Kind = 'Registry'; Name = 'x'; Path = 'HKLM:\SOFTWARE\X'; ValueName = 'a'; ValueType = 'Binary'; Value = '00' }),
        @('control character in a value', @{ Kind = 'Registry'; Name = 'x'; Path = 'HKLM:\SOFTWARE\X'; ValueName = 'a'; ValueType = 'String'; Value = "b`nc" }),
        @('control character in the name', @{ Kind = 'Hosts'; Name = "a`tb"; Address = '10.0.0.5'; HostName = 'app.example.test' }),
        @('bad IP', @{ Kind = 'Hosts'; Name = 'x'; Address = '10.0.0.300'; HostName = 'app.example.test' }),
        @('bad host name', @{ Kind = 'Hosts'; Name = 'x'; Address = '10.0.0.5'; HostName = 'app_example..test' }),
        @('relative ini path', @{ Kind = 'Ini'; Name = 'x'; Path = 'app\app.ini'; Section = 's'; Key = 'k'; Value = 'v' }),
        @('ini path with ..', @{ Kind = 'Ini'; Name = 'x'; Path = 'C:\Apps\..\Windows\win.ini'; Section = 's'; Key = 'k'; Value = 'v' }),
        @('ini in the Windows folder', @{ Kind = 'Ini'; Name = 'x'; Path = 'C:\Windows\app.ini'; Section = 's'; Key = 'k'; Value = 'v' }),
        @('ini key with =', @{ Kind = 'Ini'; Name = 'x'; Path = 'C:\Apps\app.ini'; Section = 's'; Key = 'k=1'; Value = 'v' }),
        @('stream in a path', @{ Kind = 'Ini'; Name = 'x'; Path = 'C:\Apps\app.ini:evil'; Section = 's'; Key = 'k'; Value = 'v' }),
        @('device name', @{ Kind = 'Ini'; Name = 'x'; Path = 'C:\Apps\CON.ini'; Section = 's'; Key = 'k'; Value = 'v' }),
        @('folder = drive root', @{ Kind = 'Folder'; Name = 'x'; Path = 'C:\'; Principal = 'Users'; Rights = 'Modify' }),
        @('folder in Windows', @{ Kind = 'Folder'; Name = 'x'; Path = 'C:\Windows\Temp\x'; Principal = 'Users'; Rights = 'Modify' }),
        @('folder = Program Files', @{ Kind = 'Folder'; Name = 'x'; Path = 'C:\Program Files'; Principal = 'Users'; Rights = 'Modify' }),
        @('folder in the state folder', @{ Kind = 'Folder'; Name = 'x'; Path = "$tmp\config"; Principal = 'Users'; Rights = 'Modify' }),
        @('Everyone', @{ Kind = 'Folder'; Name = 'x'; Path = 'C:\Data\Scans'; Principal = 'S-1-1-0'; Rights = 'Modify' }),
        @('a group name instead of a SID', @{ Kind = 'Folder'; Name = 'x'; Path = 'C:\Data\Scans'; Principal = 'EXAMPLE\Sales'; Rights = 'Modify' }),
        @('unknown rights', @{ Kind = 'Folder'; Name = 'x'; Path = 'C:\Data\Scans'; Principal = 'Users'; Rights = 'Write' }),
        @('shortcut target relative', @{ Kind = 'Shortcut'; Name = 'App'; Location = 'Desktop'; Target = 'app.exe'; IconSource = 'Target' }),
        @('shortcut name with a slash', @{ Kind = 'Shortcut'; Name = 'A/B'; Location = 'Desktop'; Target = 'C:\Apps\app.exe'; IconSource = 'Target' }),
        @('shortcut visibility on the Start menu only', @{ Kind = 'Shortcut'; Name = 'App'; Location = 'StartMenu'; Target = 'C:\Apps\app.exe'; IconSource = 'Target'; Visibility = 'Admins' }),
        @('UNC server with ..', @{ Kind = 'Shortcut'; Name = 'App'; Location = 'Desktop'; Target = '\\srv..x\share\app.exe'; IconSource = 'Target' }),
        @('library icon without a manifest', @{ Kind = 'Shortcut'; Name = 'App'; Location = 'Desktop'; Target = 'C:\Apps\app.exe'; IconSource = 'Library'; IconFile = 'app.ico' }),
        @('font of the wrong type', @{ Kind = 'Font'; Name = 'Corp'; File = 'corp.woff' }),
        @('script timeout too long', @{ Kind = 'Script'; Name = 'S'; File = 'setup.ps1'; Sha256 = ('a' * 64); TimeoutSeconds = '99999' }),
        @('file copy of an exe', @{ Kind = 'FileCopy'; Name = 'F'; File = 'tool.exe'; Sha256 = ('a' * 64); Destination = 'C:\Apps\tool.exe' }),
        @('unknown kind', @{ Kind = 'Run'; Name = 'x' })
    )
    $wrong = @(foreach ($b in $bad) { $r = Test-Item $b[1] -FromForm; if ($r.Valid) { $b[0] } })
    Test-Check "validation refuses every bad input ($($bad.Count) cases: HKCU, SAM, wildcards, ranges, control characters, IP, DNS, relative, .., system folders, streams, devices, Everyone, names instead of SIDs, kinds)" ($wrong.Count -eq 0) ($wrong -join ', ')
    $unc = Test-Item @{ Kind = 'Shortcut'; Name = 'Share app'; Location = 'Both'; Target = '\\fs01.example.test\apps$\tool\tool.exe'; Arguments = '/quiet "x y"'; WorkingDirectory = '\\fs01.example.test\apps$\tool'; IconSource = 'Target'; IconIndex = '2'; Visibility = 'S-1-5-21-1-2-3-1105' } -FromForm
    Test-Check 'shortcut: a UNC target and working folder, arguments with quotes, a group SID for the visibility are valid; the icon index is a number' ($unc.Valid -and $unc.Item.IconIndex -is [int] -and $unc.Item.IconIndex -eq 2) ($unc.Errors -join ' ')
    $lib = @([pscustomobject]@{ Name = 'corp.ttf'; Sha256 = ('B' * 64); Size = 10; Extension = '.ttf' })
    $font = Test-Item @{ Kind = 'Font'; Name = 'Corp Sans'; File = 'corp.ttf' } -FromForm -Library $lib
    Test-Check 'font: the SHA256 is pinned from the manifest (lower case)' ($font.Valid -and $font.Item.Sha256 -eq ('b' * 64)) ($font.Errors -join ' ')
    $long = 'a' * 5000
    Test-Check 'the regex helper refuses text over its limit before matching (no long input reaches a regex)' (-not (Test-AVDTuneCustomMatch $long 'a+' 1024) -and (Test-AVDTuneCustomMatch 'aaa' 'a+' 10)) $null
    $typed = ConvertTo-AVDTuneCustomItem -Raw ([pscustomobject]@{ Id = 'abcdef012345'; Kind = 'Script'; Name = 'S'; File = 's.ps1'; Sha256 = ('a' * 64); TimeoutSeconds = '600'; Undo = 'false' }) -Forbidden $forbidden
    Test-Check 'from the state the types must be exact: "600" is not a number and "false" is not a boolean' (-not $typed.Valid -and ($typed.Errors -join ' ') -like '*TimeoutSeconds must be a whole number*' -and ($typed.Errors -join ' ') -like '*Undo must be yes or no*') ($typed.Errors -join ' ')

    # ---------------------------------------------------------------- ini and hosts text
    $ini = "[General]`r`nLang=en`r`n`r`n[Other]`r`nx=1`r`n"
    $t1 = Set-AVDTuneIniValue -Text $ini -Section 'general' -Key 'lang' -Value 'de'
    $t2 = Set-AVDTuneIniValue -Text $ini -Section 'General' -Key 'Server' -Value 'srv01'
    $t3 = Set-AVDTuneIniValue -Text $ini -Section 'New' -Key 'A' -Value 'B'
    $t4 = Set-AVDTuneIniValue -Text $ini -Section 'General' -Key 'Lang' -Remove
    Test-Check 'ini: replace (case-insensitive), add to the end of the section, add a new section, remove; other lines stay' ((Get-AVDTuneIniValue $t1 'General' 'Lang') -eq 'de' -and $t2.Contains("Lang=en`r`nServer=srv01`r`n`r`n[Other]") -and (Get-AVDTuneIniValue $t3 'New' 'A') -eq 'B' -and $null -eq (Get-AVDTuneIniValue $t4 'General' 'Lang') -and (Get-AVDTuneIniValue $t4 'Other' 'x') -eq '1') $t2
    Test-Check 'ini: a commented key is no value' ($null -eq (Get-AVDTuneIniValue ";Lang=x`r`n[General]`r`n;Lang=y" 'General' 'Lang')) $null
    $h = "127.0.0.1 localhost`r`n10.0.0.5 app.example.test # theirs`r`n"
    $h1 = Set-AVDTuneHostsEntry -Text $h -Address '10.0.0.9' -HostName 'crm.example.test'
    $h2 = Set-AVDTuneHostsEntry -Text $h1 -Address '10.0.0.5' -HostName 'app.example.test' -Remove
    Test-Check 'hosts: the entry is found in any form, AVDTune adds its marked line and removes only that line (a line of someone else stays)' ((Test-AVDTuneHostsEntry $h '10.0.0.5' 'APP.example.test') -and (Test-AVDTuneHostsEntry $h1 '10.0.0.9' 'crm.example.test') -and $h2 -like '*10.0.0.5 app.example.test # theirs*' -and -not (Test-AVDTuneHostsEntry "# 10.0.0.9 crm.example.test" '10.0.0.9' 'crm.example.test')) $h2

    # ---------------------------------------------------------------- a full set of items against the fakes
    $script1 = "param(`$AVDTuneMode) exit 0"
    $c = New-AVDTuneFakeCustom -Seed @{ Library = @{ 'corp.ttf' = 'FONTBYTES'; 'app.ico' = 'ICONBYTES'; 'readme.txt' = 'Hello'; 'setup.ps1' = $script1 }; Files = @{ 'C:\Apps\app.exe' = 'exe'; 'C:\Apps\app.ini' = "[General]`r`nLang=en`r`n" }; Reachable = @('\\fs01.example.test\apps$\tool\tool.exe') }
    $m = New-AVDTuneFakeMachine -Seed @{ Now = [datetime]'2026-11-17T10:00:00' }
    $libRows = Get-AVDTuneFakeCustomLibrary -C $c
    $forms = @(
        @{ Kind = 'Shortcut'; Name = 'Contoso App'; Location = 'Both'; Target = 'C:\Apps\app.exe'; Arguments = '/x'; WorkingDirectory = 'C:\Apps'; IconSource = 'Library'; IconFile = 'app.ico'; IconIndex = '0'; Visibility = 'Admins' },
        @{ Kind = 'Shortcut'; Name = 'Share tool'; Location = 'Desktop'; Target = '\\fs01.example.test\apps$\tool\tool.exe'; IconSource = 'Target' },
        @{ Kind = 'Shortcut'; Name = 'Gone'; Location = 'StartMenu'; Target = '\\fs02.example.test\x\gone.exe'; IconSource = 'Target' },
        @{ Kind = 'Font'; Name = 'Corp Sans'; File = 'corp.ttf' },
        @{ Kind = 'Registry'; Name = 'Proxy'; Path = 'HKLM:\SOFTWARE\Contoso'; ValueName = 'Proxy'; ValueType = 'DWord'; Value = '1' },
        @{ Kind = 'Ini'; Name = 'Language'; Path = 'C:\Apps\app.ini'; Section = 'General'; Key = 'Lang'; Value = 'de' },
        @{ Kind = 'Hosts'; Name = 'CRM'; Address = '10.0.0.9'; HostName = 'crm.example.test' },
        @{ Kind = 'Folder'; Name = 'Scans'; Path = 'C:\Data\Scans'; Principal = 'Users'; Rights = 'Modify' },
        @{ Kind = 'FileCopy'; Name = 'Readme'; File = 'readme.txt'; Destination = 'C:\Apps\readme.txt' },
        @{ Kind = 'Script'; Name = 'Setup'; File = 'setup.ps1'; TimeoutSeconds = '60'; Undo = 'Yes' }
    )
    foreach ($f in $forms) { $r = Add-AVDTuneCustomItem -Root $tmp -Raw $f -Library $libRows; if (-not $r.Valid) { throw "fixture $($f.Name): $($r.Errors -join ' ')" } }
    $dupe = Add-AVDTuneCustomItem -Root $tmp -Raw @{ Kind = 'Hosts'; Name = 'crm'; Address = '10.0.0.8'; HostName = 'x.example.test' } -Library $libRows
    Test-Check 'a second item of the same kind and name is refused' (-not $dupe.Valid -and ($dupe.Errors -join ' ') -like '*already*') $null
    $saved = Get-AVDTuneCustomizations -Root $tmp -Forbidden $forbidden
    Test-Check 'ten items saved, read back typed and valid' ($saved.Items.Count -eq 10 -and $saved.Invalid.Count -eq 0 -and -not $saved.Problem) ($saved.Invalid | ConvertTo-Json -Compress)
    $ids = @{}; foreach ($i in $saved.Items) { $ids[$i.Name] = $i.Id }

    $st = Get-AVDTuneCustomStatus -Machine $m -C $c -Root $tmp
    $byName = @{}; foreach ($r in $st.Items) { $byName[$r.Name] = $r }
    Test-Check 'status: before Apply every item tests as missing (the script says it cannot be tested without its file)' (@($st.Items | Where-Object { $_.Status -eq 'NonCompliant' }).Count -eq 9 -and $byName['Setup'].Status -eq 'Failed' -and $byName['Setup'].Message -like '*not in the cache*') (($st.Items | ForEach-Object { "$($_.Name)=$($_.Status)" }) -join ', ')
    Test-Check 'reachability: a local target is checked, UNC paths are NOT asked automatically (NTLM to foreign hosts, review L2), the library icon is not cached yet' (@($byName['Contoso App'].Reach | Where-Object { $_.What -eq 'Target' -and $_.Ok -eq $true }).Count -eq 1 -and @($byName['Share tool'].Reach | Where-Object { $_.What -eq 'Target' -and $null -eq $_.Ok }).Count -eq 1 -and @($byName['Gone'].Reach | Where-Object { $_.What -eq 'Target' -and $null -eq $_.Ok }).Count -eq 1 -and @($byName['Contoso App'].Reach | Where-Object { $_.What -eq 'Icon' -and $_.Ok -eq $false }).Count -eq 1) $null
    $stu = Get-AVDTuneCustomStatus -Machine $m -C $c -Root $tmp -NoScripts -CheckUnc
    $bu = @{}; foreach ($r in $stu.Items) { $bu[$r.Name] = $r }
    Test-Check 'reachability on request (-CheckUnc): a UNC target that answers is reachable, an unknown one is not' (@($bu['Share tool'].Reach | Where-Object { $_.What -eq 'Target' -and $_.Ok -eq $true }).Count -eq 1 -and @($bu['Gone'].Reach | Where-Object { $_.What -eq 'Target' -and $_.Ok -eq $false }).Count -eq 1) $null

    $gateText = Get-ThrownText { Invoke-AVDTuneCustomRun -Machine $m -C $c -Root $tmp -Mode Apply -Context @{ Fake = $true } }
    Test-Check 'Apply without the snapshot gate changes nothing (every step fails at the gate)' (($c.Store.Log.Count -eq 0) -and ($null -eq $gateText -or $gateText -like '*snapshot*')) $c.Store.Log.Count
    Open-AVDTuneWriteGate -SnapshotId 'snap-1' -ConfirmedBy 'Alex Example'
    $noLib = Invoke-AVDTuneCustomRun -Machine $m -C $c -Root $tmp -Mode Apply -Ids @($ids['Readme'])
    Test-Check 'a library file that is not cached needs the library: the step fails with the reason, nothing is copied' ($noLib.Run.Results[0].Status -eq 'Failed' -and $noLib.Run.Results[0].Message -like '*not in the cache*' -and -not $c.Store.Files.ContainsKey('c:\apps\readme.txt')) $noLib.Run.Results[0].Message
    $c.Store.Tamper['readme.txt'] = [Text.Encoding]::UTF8.GetBytes('evil')
    $tam = Invoke-AVDTuneCustomRun -Machine $m -C $c -Root $tmp -Mode Apply -Ids @($ids['Readme']) -Context @{ Fake = $true }
    Test-Check 'a download that does not match the pinned SHA256 is refused and not used' ($tam.Run.Results[0].Status -eq 'Failed' -and $tam.Run.Results[0].Message -like '*SHA256*' -and -not $c.Store.Files.ContainsKey('c:\apps\readme.txt')) $tam.Run.Results[0].Message
    $c.Store.Tamper.Clear()
    $run = Invoke-AVDTuneCustomRun -Machine $m -C $c -Root $tmp -Mode Apply -Context @{ Fake = $true } -User 'admin1' -SnapshotId 'snap-1'
    $res = @{}; foreach ($r in $run.Run.Results) { $res[$r.Title] = $r.Status }
    $changed = @($run.Run.Results | Where-Object { $_.Status -eq 'Changed' }).Count
    Test-Check 'Apply all: every item is changed and tests as in place afterwards (the shortcut to an unreachable UNC target is still written)' ($changed -eq 10) (($run.Run.Results | ForEach-Object { "$($_.Title)=$($_.Status) $($_.Message)" }) -join ' | ')
    Test-Check 'the master got: shortcuts on the Public Desktop and in the Start menu with the marker, the icon read only for users, the font file and its registration, the DWord, the ini value, the hosts line, the folder with Modify for Users, the file, the script run' (
        $c.Store.Shortcuts.ContainsKey('c:\users\public\desktop\contoso app.lnk') -and $c.Store.Shortcuts.ContainsKey('c:\programdata\microsoft\windows\start menu\programs\contoso app.lnk') -and
        $c.Store.Shortcuts['c:\users\public\desktop\contoso app.lnk'].Description -like 'AVDTune shortcut *' -and @($c.Store.Log | Where-Object { $_ -like 'CopyFile C:\ProgramData\AVDTune-Public\Icons\*.ico (UsersRead)' }).Count -eq 1 -and
        $c.Store.Files.ContainsKey('c:\windows\fonts\corp.ttf') -and (& $c.RegGet 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts' 'Corp Sans (TrueType)').Value -eq 'corp.ttf' -and
        (& $c.RegGet 'HKLM:\SOFTWARE\Contoso' 'Proxy').Value -eq 1 -and (& $c.RegGet 'HKLM:\SOFTWARE\Contoso' 'Proxy').Kind -eq 'DWord' -and
        (Get-AVDTuneIniValue (& $c.ReadText 'C:\Apps\app.ini').Text 'General' 'Lang') -eq 'de' -and (& $c.ReadText 'C:\Windows\System32\drivers\etc\hosts').Text -like '*10.0.0.9 crm.example.test # AVDTune*' -and
        @((& $c.DirInfo 'C:\Data\Scans').Rules | Where-Object { $_.Sid -eq 'S-1-5-32-545' -and $_.Rights -eq 197055 }).Count -eq 1 -and $c.Store.Files.ContainsKey('c:\apps\readme.txt') -and $c.Store.ScriptState.Count -eq 1) ($c.Store.Log -join ' | ')
    $log = @(Get-AVDTuneChangeLog -Root $tmp)
    Test-Check 'change log: one automatic entry per changed item, category Customizations' (@($log | Where-Object { $_.Category -eq 'Customizations' -and $_.Source -eq 'Step' }).Count -eq 10) $log.Count
    $state = Get-AVDTuneState $tmp
    Test-Check 'the run sets LastChange and leaves no change marker behind' ($state.LastChange -and -not (Test-AVDTuneChangeInProgress -Root $tmp)) $state.LastChange
    $undoRec = Read-AVDTuneCustomUndo $tmp
    Test-Check 'undo record: one per changed item, with the state before (the ini value en, the folder did not exist)' ($undoRec.Count -eq 10 -and [string]$undoRec[$ids['Language']].Before.Value -eq 'en' -and -not $undoRec[$ids['Scans']].Before.Existed) $undoRec.Count
    $again = Invoke-AVDTuneCustomRun -Machine $m -C $c -Root $tmp -Mode Apply -Context @{ Fake = $true }
    Test-Check 'a second Apply changes nothing (all Unchanged) and keeps the oldest undo record' (@($again.Run.Results | Where-Object { $_.Status -ne 'Unchanged' }).Count -eq 0 -and [string](Read-AVDTuneCustomUndo $tmp)[$ids['Language']].Before.Value -eq 'en') $null
    $st2 = Get-AVDTuneCustomStatus -Machine $m -C $c -Root $tmp
    Test-Check 'status after Apply: everything in place, the script is tested from the cache, the library icon is reachable now' (@($st2.Items | Where-Object { $_.Status -ne 'Compliant' }).Count -eq 0 -and @(@($st2.Items | Where-Object { $_.Name -eq 'Contoso App' })[0].Reach | Where-Object { -not $_.Ok }).Count -eq 0) (($st2.Items | Where-Object { $_.Status -ne 'Compliant' } | ForEach-Object { "$($_.Name)=$($_.Status) $($_.Message)" }) -join ' | ')

    # ---------------------------------------------------------------- "rollback": the master loses the changes, the steps put them back
    $c.Store.Registry.Remove('hklm:\software\contoso|proxy'); $c.Store.Shortcuts.Remove('c:\users\public\desktop\contoso app.lnk'); $c.Store.ScriptState.Clear()
    $re = Invoke-AVDTuneCustomRun -Machine $m -C $c -Root $tmp -Mode Apply -Context @{ Fake = $true }
    Test-Check 'after a rollback the missing parts are found and applied again (registry, shortcut, script), the rest is unchanged' (@($re.Run.Results | Where-Object { $_.Status -eq 'Changed' }).Count -eq 3 -and @($re.Run.Results | Where-Object { $_.Status -eq 'Failed' }).Count -eq 0) (($re.Run.Results | ForEach-Object { "$($_.Title)=$($_.Status)" }) -join ' | ')

    # ---------------------------------------------------------------- foreign things are never replaced or removed
    $c2 = New-AVDTuneFakeCustom -Seed @{ Library = @{ 'readme.txt' = 'Hello'; 'corp.ttf' = 'FONTBYTES' }; Files = @{ 'C:\Apps\readme.txt' = 'theirs'; 'C:\Windows\Fonts\corp.ttf' = 'other font' }; Shortcuts = @{ 'C:\Users\Public\Desktop\Contoso App.lnk' = @{ Target = 'C:\x.exe'; Arguments = ''; Icon = ''; WorkingDirectory = ''; Description = 'made by someone' } } }
    $foreign = @($saved.Items | Where-Object { $_.Name -in 'Readme', 'Corp Sans', 'Contoso App' })
    $fr = foreach ($i in $foreign) { Invoke-AVDTuneStep -Step (New-AVDTuneCustomStep -Item $i -C $c2 -Fetch (New-AVDTuneCustomFetch -C $c2 -Root $tmp -Context @{ Fake = $true })) -Machine $m -Mode Apply }
    Test-Check 'an existing file, font file or shortcut that is not ours is not overwritten (the step fails with the reason)' (@($fr | Where-Object { $_.Status -eq 'Failed' -and $_.Message -match 'not overwritten|not replaced' }).Count -eq 3 -and [Text.Encoding]::UTF8.GetString($c2.Store.Files['c:\apps\readme.txt']) -eq 'theirs') (($fr | ForEach-Object { "$($_.Status) $($_.Message)" }) -join ' | ')

    # ---------------------------------------------------------------- fake switches: a failing write, a link in the path, a script without effect
    $c3 = New-AVDTuneFakeCustom -Seed @{ Library = @{ 'setup.ps1' = $script1 }; Files = @{ 'C:\Apps\app.ini' = "[General]`r`nLang=en`r`n" }; Links = @('C:\Apps\app.ini') }
    $iniItem = @($saved.Items | Where-Object { $_.Name -eq 'Language' })[0]; $regItem = @($saved.Items | Where-Object { $_.Name -eq 'Proxy' })[0]; $scrItem = @($saved.Items | Where-Object { $_.Name -eq 'Setup' })[0]
    $f3 = New-AVDTuneCustomFetch -C $c3 -Root $tmp -Context @{ Fake = $true }
    $lk = Invoke-AVDTuneStep -Step (New-AVDTuneCustomStep -Item $iniItem -C $c3 -Fetch $f3) -Machine $m -Mode Apply
    $c3.Store.FailWrite = 'contoso'
    $fw = Invoke-AVDTuneStep -Step (New-AVDTuneCustomStep -Item $regItem -C $c3 -Fetch $f3) -Machine $m -Mode Apply
    $c3.Store.FailWrite = ''
    $c3.Store.ScriptMode[$scrItem.Sha256] = 'NoChange'
    $nc = Invoke-AVDTuneStep -Step (New-AVDTuneCustomStep -Item $scrItem -C $c3 -Fetch $f3) -Machine $m -Mode Apply
    Test-Check 'an ini file that is a link is not read or written, a refused registry write and a script that changes nothing are failed steps with the reason' ($lk.Status -eq 'Failed' -and $lk.Message -like '*link*' -and $fw.Status -eq 'Failed' -and $fw.Message -like '*refused*' -and $nc.Status -eq 'Failed' -and $nc.Message -like '*still fails*') "$($lk.Message) / $($fw.Message) / $($nc.Message)"

    # ---------------------------------------------------------------- review #85 (Finn): M1-M4, L2-L5, I1
    $m1 = @(
        @('8.3 short name', @{ Kind = 'Folder'; Name = 'x'; Path = 'C:\PROGRA~1\Contoso'; Principal = 'Users'; Rights = 'ReadAndExecute' }),
        @('8.3 short name in a file copy', @{ Kind = 'FileCopy'; Name = 'x'; File = 'readme.txt'; Sha256 = ('a' * 64); Destination = 'C:\Apps\SUBFOL~2\readme.txt' }),
        @('Users Modify in Program Files', @{ Kind = 'Folder'; Name = 'x'; Path = 'C:\Program Files\Contoso\Data'; Principal = 'Users'; Rights = 'Modify' }),
        @('Domain Users FullControl in ProgramData', @{ Kind = 'Folder'; Name = 'x'; Path = 'C:\ProgramData\Contoso'; Principal = 'S-1-5-21-1-2-3-513'; Rights = 'FullControl' }),
        @('INTERACTIVE Modify in Program Files (x86)', @{ Kind = 'Folder'; Name = 'x'; Path = 'C:\Program Files (x86)\Contoso'; Principal = 'S-1-5-4'; Rights = 'Modify' }),
        @('ALL APPLICATION PACKAGES Modify in Program Files', @{ Kind = 'Folder'; Name = 'x'; Path = 'C:\Program Files\Contoso'; Principal = 'S-1-15-2-1'; Rights = 'Modify' }),
        @('Users Modify in the Default user autostart', @{ Kind = 'Folder'; Name = 'x'; Path = 'C:\Users\Default\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup'; Principal = 'Users'; Rights = 'Modify' }),
        @('Remote Desktop Users is no choice any more', @{ Kind = 'Folder'; Name = 'x'; Path = 'C:\Data\Scans'; Principal = 'Remote Desktop Users'; Rights = 'Modify' }),
        @('Remote Desktop Users by SID Modify in Program Files', @{ Kind = 'Folder'; Name = 'x'; Path = 'C:\Program Files\Contoso'; Principal = 'S-1-5-32-555'; Rights = 'Modify' }),
        @('file into the all-users autostart', @{ Kind = 'FileCopy'; Name = 'x'; File = 'readme.txt'; Sha256 = ('a' * 64); Destination = 'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp\readme.txt' }),
        @('file into the Default user autostart', @{ Kind = 'FileCopy'; Name = 'x'; File = 'link.url'; Sha256 = ('a' * 64); Destination = 'C:\Users\Default\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup\link.url' }),
        @('.exe.config in Program Files', @{ Kind = 'FileCopy'; Name = 'x'; File = 'app.config'; Sha256 = ('a' * 64); Destination = 'C:\Program Files\Contoso\app.exe.config' }),
        @('.dll.config in ProgramData', @{ Kind = 'FileCopy'; Name = 'x'; File = 'lib.config'; Sha256 = ('a' * 64); Destination = 'C:\ProgramData\Contoso\lib.dll.config' }),
        @('Lsa', @{ Kind = 'Registry'; Name = 'x'; Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'; ValueName = 'Security Packages'; ValueType = 'String'; Value = 'x' }),
        @('SecurityProviders', @{ Kind = 'Registry'; Name = 'x'; Path = 'HKLM:\SYSTEM\ControlSet001\Control\SecurityProviders\WDigest'; ValueName = 'UseLogonCredential'; ValueType = 'DWord'; Value = '1' })
    )
    $wrong2 = @(foreach ($b in $m1) { $r = Test-Item $b[1] -FromForm; if ($r.Valid) { $b[0] } })
    Test-Check "review M1/M2/M3/I1: refused ($($m1.Count) cases: 8.3 names, broad groups with write rights in program and autostart folders, Remote Desktop Users, autostart files, .exe/.dll.config, Lsa, SecurityProviders)" ($wrong2.Count -eq 0) ($wrong2 -join ', ')
    $okRx = Test-Item @{ Kind = 'Folder'; Name = 'x'; Path = 'C:\Program Files\Contoso'; Principal = 'Users'; Rights = 'ReadAndExecute' } -FromForm
    $okAdm = Test-Item @{ Kind = 'Folder'; Name = 'x'; Path = 'C:\Program Files\Contoso'; Principal = 'S-1-5-21-1-2-3-1105'; Rights = 'Modify' } -FromForm
    $okCfg = Test-Item @{ Kind = 'FileCopy'; Name = 'x'; File = 'app.config'; Sha256 = ('a' * 64); Destination = 'C:\Apps\app.exe.config' } -FromForm
    Test-Check 'review M2/M3: ReadAndExecute for Users in Program Files, Modify for a named group there, and an .exe.config outside the program folders stay allowed' ($okRx.Valid -and $okAdm.Valid -and $okCfg.Valid) ((@($okRx.Errors) + @($okAdm.Errors) + @($okCfg.Errors)) -join ' ')
    $shortPf = ConvertTo-AVDTuneCustomLong 'C:\PROGRA~1'
    if ($shortPf -ne 'C:\PROGRA~1') { Test-Check 'review M1: the long form of C:\PROGRA~1 is compared with the forbidden folders (8.3 names on this drive)' (Test-AVDTuneCustomForbidden 'C:\PROGRA~1' (Get-AVDTuneCustomForbiddenFolders -Root $tmp)) $shortPf }
    else { 'SKIP review M1 long form: this drive has no 8.3 names (the segment rule ~N still refuses them)' }
    $runRisk = Test-Item @{ Kind = 'Registry'; Name = 'Agent'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; ValueName = 'Agent'; ValueType = 'String'; Value = 'C:\Apps\agent.exe' } -FromForm
    $polRisk = Test-Item @{ Kind = 'Registry'; Name = 'Pol'; Path = 'HKLM:\SOFTWARE\Policies\Contoso'; ValueName = 'X'; ValueType = 'DWord'; Value = '1' } -FromForm
    $plain = Test-Item @{ Kind = 'Registry'; Name = 'Plain'; Path = 'HKLM:\SOFTWARE\Contoso'; ValueName = 'X'; ValueType = 'DWord'; Value = '1' } -FromForm
    Test-Check 'review I1: Run and Policies are allowed with a visible RISK note in the title (confirmation and change log), a plain key has none; AppInit_DLLs and services are named' ($runRisk.Valid -and (Get-AVDTuneCustomTitle $runRisk.Item) -like '*RISK: autostart*' -and (Get-AVDTuneCustomTitle $polRisk.Item) -like '*RISK: policies*' -and (Get-AVDTuneCustomTitle $plain.Item) -notlike '*RISK*' -and (Get-AVDTuneCustomRegRisk 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Windows' 'AppInit_DLLs') -like '*AppInit_DLLs*' -and (Get-AVDTuneCustomRegRisk 'HKLM:\SYSTEM\CurrentControlSet\Services\Foo' 'Start') -like '*services*') (Get-AVDTuneCustomTitle $runRisk.Item)
    # M1: checked again directly before Apply: a folder that became forbidden since the item was saved
    $tight = @{ Exact = $forbidden.Exact; Below = @($forbidden.Below) + 'C:\Data'; Programs = $forbidden.Programs }
    $scans = @($saved.Items | Where-Object { $_.Name -eq 'Scans' })[0]
    $cG = New-AVDTuneFakeCustom
    $gd = Invoke-AVDTuneStep -Step (New-AVDTuneCustomStep -Item $scans -C $cG -Forbidden $tight) -Machine $m -Mode Apply
    Test-Check 'review M1: the item is validated again directly before Apply (now forbidden: refused, nothing written)' ($gd.Status -eq 'Failed' -and $gd.Message -like 'Refused before Apply*' -and $cG.Store.Log.Count -eq 0) $gd.Message
    # M3/L1: preview of a file and a script before saving
    $pv = Get-AVDTuneCustomPreview -C $c -Root $tmp -Context @{ Fake = $true } -Name 'setup.ps1' -Sha256 (@($libRows | Where-Object Name -eq 'setup.ps1')[0].Sha256)
    Test-Check 'review M3/L1: before a library script or file is saved its size, SHA256 and first lines are shown' ($pv.Size -eq ([Text.Encoding]::UTF8.GetBytes($script1)).Length -and $pv.Sha256 -match '\A[0-9a-f]{64}\z' -and $pv.Lines[0] -like 'param(*') ($pv | ConvertTo-Json -Compress)
    # M4: fonts keep what was there
    $fontItem = (Test-Item @{ Kind = 'Font'; Name = 'Corp Sans'; File = 'corp.ttf' } -FromForm -Library $libRows).Item
    $fk = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts|Corp Sans (TrueType)'
    $cF1 = New-AVDTuneFakeCustom -Seed @{ Library = @{ 'corp.ttf' = 'FONTBYTES' }; Registry = @{ $fk = @{ Value = 'other.ttf'; Kind = 'String' } } }
    $f1 = Invoke-AVDTuneStep -Step (New-AVDTuneCustomStep -Item $fontItem -C $cF1 -Fetch (New-AVDTuneCustomFetch -C $cF1 -Root $tmp -Context @{ Fake = $true }) -Forbidden $forbidden) -Machine $m -Mode Apply
    Test-Check 'review M4: a font registration that points to another file is not replaced (Apply refused, no file copied)' ($f1.Status -eq 'Failed' -and $f1.Message -like '*points to other.ttf*' -and -not $cF1.Store.Files.ContainsKey('c:\windows\fonts\corp.ttf')) $f1.Message
    $cF2 = New-AVDTuneFakeCustom -Seed @{ Library = @{ 'corp.ttf' = 'FONTBYTES' }; Files = @{ 'C:\Windows\Fonts\corp.ttf' = 'FONTBYTES' } }
    $b2 = Get-AVDTuneCustomBefore -Item $fontItem -C $cF2
    $fe2 = New-AVDTuneCustomFetch -C $cF2 -Root $tmp -Context @{ Fake = $true }
    [void](Invoke-AVDTuneStep -Step (New-AVDTuneCustomStep -Item $fontItem -C $cF2 -Fetch $fe2 -Forbidden $forbidden) -Machine $m -Mode Apply)
    $u2f = Invoke-AVDTuneStep -Step (New-AVDTuneCustomStep -Item $fontItem -C $cF2 -Fetch $fe2 -Before $b2 -Forbidden $forbidden) -Machine $m -Mode Undo
    Test-Check 'review M4: a font file that was there before stays after Undo, only the registration AVDTune added is removed' ($b2.FileExisted -and $u2f.Status -eq 'Reverted' -and $cF2.Store.Files.ContainsKey('c:\windows\fonts\corp.ttf') -and $null -eq (& $cF2.RegGet 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts' 'Corp Sans (TrueType)')) "$($u2f.Status) $($u2f.Message)"
    $cF3 = New-AVDTuneFakeCustom -Seed @{ Library = @{ 'corp.ttf' = 'FONTBYTES' }; Registry = @{ $fk = @{ Value = 'CORP.TTF'; Kind = 'String' } } }
    $b3 = Get-AVDTuneCustomBefore -Item $fontItem -C $cF3
    $fe3 = New-AVDTuneCustomFetch -C $cF3 -Root $tmp -Context @{ Fake = $true }
    [void](Invoke-AVDTuneStep -Step (New-AVDTuneCustomStep -Item $fontItem -C $cF3 -Fetch $fe3 -Forbidden $forbidden) -Machine $m -Mode Apply)
    $u3f = Invoke-AVDTuneStep -Step (New-AVDTuneCustomStep -Item $fontItem -C $cF3 -Fetch $fe3 -Before $b3 -Forbidden $forbidden) -Machine $m -Mode Undo
    Test-Check 'review M4: a registration that was there before keeps its old value after Undo, the file AVDTune copied is deleted' ($b3.ValueExisted -and $u3f.Status -eq 'Reverted' -and (& $cF3.RegGet 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts' 'Corp Sans (TrueType)').Value -ceq 'CORP.TTF' -and -not $cF3.Store.Files.ContainsKey('c:\windows\fonts\corp.ttf')) "$($u3f.Status) $($u3f.Message)"
    # L3: the rules of the SID from before come back after Undo
    $cL3 = New-AVDTuneFakeCustom -Seed @{ Folders = @('C:\Data\Scans'); Rules = @{ 'C:\Data\Scans' = @(@{ Sid = 'S-1-5-32-545'; Rights = 131241; Inherited = $false; Inherit = 3; Propagate = 0 }) } }
    $bL3 = Get-AVDTuneCustomBefore -Item $scans -C $cL3
    [void](Invoke-AVDTuneStep -Step (New-AVDTuneCustomStep -Item $scans -C $cL3 -Forbidden $forbidden) -Machine $m -Mode Apply)
    $uL3 = Invoke-AVDTuneStep -Step (New-AVDTuneCustomStep -Item $scans -C $cL3 -Before $bL3 -Forbidden $forbidden) -Machine $m -Mode Undo
    $rulesL3 = @((& $cL3.DirInfo 'C:\Data\Scans').Rules)
    Test-Check 'review L3: Undo removes the added Modify rule and puts back the explicit ReadAndExecute rule the group had before; the existing folder stays' ($uL3.Status -eq 'Reverted' -and $rulesL3.Count -eq 1 -and $rulesL3[0].Rights -eq 131241 -and (& $cL3.DirInfo 'C:\Data\Scans').Exists) ($rulesL3 | ConvertTo-Json -Compress)
    # L5: the script test is a change of the master
    Close-AVDTuneWriteGate
    $noGate = Get-ThrownText { Invoke-AVDTuneCustomScriptTest -Machine $m -C $c -Root $tmp }
    Open-AVDTuneWriteGate -SnapshotId 'snap-1' -ConfirmedBy 'Alex Example'
    [void](Set-AVDTuneState -Root $tmp -Values @{ LastChange = '2026-11-17T09:00:00' })
    $runsBefore = @(Get-ChildItem -LiteralPath (Join-Path $tmp 'runs') -File -ErrorAction SilentlyContinue).Count
    $sts = Invoke-AVDTuneCustomScriptTest -Machine $m -C $c -Root $tmp
    $runsAfter = @(Get-ChildItem -LiteralPath (Join-Path $tmp 'runs') -File -ErrorAction SilentlyContinue).Count
    Test-Check 'review L5: testing the scripts needs the write gate, sets LastChange, writes a run record and leaves no marker' ($noGate -like '*snapshot gate*' -and [string](Get-AVDTuneState $tmp).LastChange -ne '2026-11-17T09:00:00' -and $runsAfter -eq $runsBefore + 1 -and -not (Test-AVDTuneChangeInProgress -Root $tmp) -and @($sts.Items | Where-Object { $_.Kind -eq 'Script' -and $_.Status -ne 'Unknown' }).Count -eq 1) "$noGate / $((Get-AVDTuneState $tmp).LastChange) / $runsBefore -> $runsAfter"

    # ---------------------------------------------------------------- scripts
    $sItem = @($saved.Items | Where-Object { $_.Name -eq 'Setup' })[0]
    $c.Store.ScriptMode[$sItem.Sha256] = 'Broken'
    $sb = Invoke-AVDTuneStep -Step (New-AVDTuneCustomStep -Item $sItem -C $c -Fetch (New-AVDTuneCustomFetch -C $c -Root $tmp)) -Machine $m -Mode Test
    Test-Check 'a script that answers the test with another exit code than 0/1 is a failed test with the reason' ($sb.Status -eq 'Failed' -and $sb.Message -like '*exit code 7*') $sb.Message
    $c.Store.ScriptMode[$sItem.Sha256] = 'Ok'
    $cache = Join-Path $tmp ("custom\files\$($sItem.Sha256).ps1")
    $c.Store.Files[$cache.ToLowerInvariant()] = [Text.Encoding]::UTF8.GetBytes('changed in the cache')
    $c.Store.Library['setup.ps1'] = [Text.Encoding]::UTF8.GetBytes('changed in the library')
    $sc = Invoke-AVDTuneStep -Step (New-AVDTuneCustomStep -Item $sItem -C $c -Fetch (New-AVDTuneCustomFetch -C $c -Root $tmp -Context @{ Fake = $true })) -Machine $m -Mode Test
    Test-Check 'a script whose cached copy and library file changed after it was pinned is not run (cache copy dropped, download refused)' ($sc.Status -eq 'Failed' -and $sc.Message -like '*SHA256*' -and -not $c.Store.Files.ContainsKey($cache.ToLowerInvariant())) $sc.Message
    $c.Store.Library['setup.ps1'] = [Text.Encoding]::UTF8.GetBytes($script1)

    # ---------------------------------------------------------------- undo and remove (fonts listed and removable)
    $u1 = Invoke-AVDTuneCustomRun -Machine $m -C $c -Root $tmp -Mode Undo -Ids @($ids['Corp Sans'], $ids['Language'], $ids['Scans'], $ids['CRM'], $ids['Proxy']) -Context @{ Fake = $true }
    Test-Check 'Undo: font file and registration gone, ini back to en, rule and new folder gone, our hosts line gone, the DWord removed (it did not exist)' (@($u1.Run.Results | Where-Object { $_.Status -ne 'Changed' }).Count -eq 0 -and -not $c.Store.Files.ContainsKey('c:\windows\fonts\corp.ttf') -and $null -eq (& $c.RegGet 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts' 'Corp Sans (TrueType)') -and (Get-AVDTuneIniValue (& $c.ReadText 'C:\Apps\app.ini').Text 'General' 'Lang') -eq 'en' -and -not (& $c.DirInfo 'C:\Data\Scans').Exists -and (& $c.ReadText 'C:\Windows\System32\drivers\etc\hosts').Text -notlike '*crm.example.test*' -and $null -eq (& $c.RegGet 'HKLM:\SOFTWARE\Contoso' 'Proxy')) (($u1.Run.Results | ForEach-Object { "$($_.Title)=$($_.Status) $($_.Message)" }) -join ' | ')
    Test-Check 'Undo writes change log entries and removes the undo records of the reverted items' (@(Get-AVDTuneChangeLog -Root $tmp | Where-Object { $_.Text -like 'Undo: *' }).Count -eq 5 -and -not (Read-AVDTuneCustomUndo $tmp).ContainsKey($ids['Corp Sans'])) $null
    $u2 = Invoke-AVDTuneCustomRun -Machine $m -C $c -Root $tmp -Mode Undo -Ids @($ids['Corp Sans'])
    Test-Check 'a second Undo has nothing to undo (skipped with the reason, no run)' ($null -eq $u2.Run -and $u2.Skipped[0].Message -like 'Nothing to undo*') $null
    $refuse = Get-ThrownText { Remove-AVDTuneCustomItem -Root $tmp -Id $ids['Readme'] }
    Remove-AVDTuneCustomItem -Root $tmp -Id $ids['Corp Sans']
    Test-Check 'remove: an item that is still applied is refused (undo first), an undone font is taken out of the list' ($refuse -like '*undo it first*' -and @((Get-AVDTuneCustomizations -Root $tmp -Forbidden $forbidden).Items | Where-Object { $_.Name -eq 'Corp Sans' }).Count -eq 0) $refuse
    $su = Invoke-AVDTuneCustomRun -Machine $m -C $c -Root $tmp -Mode Undo -Ids @($ids['Setup'], $ids['Contoso App']) -Context @{ Fake = $true }
    Test-Check 'Undo of a script runs its undo part; Undo of a shortcut removes only our shortcuts' (@($su.Run.Results | Where-Object { $_.Status -eq 'Changed' }).Count -eq 2 -and -not $c.Store.ScriptState[$sItem.Sha256] -and -not $c.Store.Shortcuts.ContainsKey('c:\programdata\microsoft\windows\start menu\programs\contoso app.lnk')) (($su.Run.Results | ForEach-Object { "$($_.Title)=$($_.Status) $($_.Message)" }) -join ' | ')
    Close-AVDTuneWriteGate

    # ---------------------------------------------------------------- state file: tampered items are listed as invalid, never run
    $path = Get-AVDTuneCustomPath $tmp
    $j = Get-Content -Raw $path | ConvertFrom-Json
    @($j.Items | Where-Object { $_.Kind -eq 'Registry' })[0].Path = 'HKCU:\Software\Evil'
    Write-AVDTuneFile $path ($j | ConvertTo-Json -Depth 5)
    $after = Get-AVDTuneCustomizations -Root $tmp -Forbidden $forbidden
    Test-Check 'a changed state file: the item with a HKCU path is listed as invalid with the reason and is not among the items that run' ($after.Invalid.Count -eq 1 -and ($after.Invalid[0].Errors -join ' ') -like '*HKLM only*') ($after.Invalid | ConvertTo-Json -Compress)

    # ---------------------------------------------------------------- App Masking request (#69 mechanism)
    $mr = Get-AVDTuneCustomMaskingRequest -Item (Test-Item @{ Kind = 'Shortcut'; Name = 'App'; Location = 'Both'; Target = 'C:\Apps\app.exe'; IconSource = 'Target'; Visibility = 'S-1-5-21-1-2-3-1105' } -FromForm).Item
    $ma = Get-AVDTuneCustomMaskingRequest -Item (Test-Item @{ Kind = 'Shortcut'; Name = 'App'; Location = 'Desktop'; Target = 'C:\Apps\app.exe'; IconSource = 'Target'; Visibility = 'Admins' } -FromForm).Item
    $mn = Get-AVDTuneCustomMaskingRequest -Item (Test-Item @{ Kind = 'Shortcut'; Name = 'App'; Location = 'Desktop'; Target = 'C:\Apps\app.exe'; IconSource = 'Target' } -FromForm).Item
    Test-Check 'masking request: a group SID asks the mode "Only members of a group", Admins asks "Nobody except administrators", none asks nothing' ($mr.FileName -eq 'App.lnk' -and $mr.Mode -eq 'Only members of a group' -and $mr.GroupSid -eq 'S-1-5-21-1-2-3-1105' -and $ma.Mode -eq 'Nobody except administrators' -and $null -eq $mn) $null

    # ---------------------------------------------------------------- library manifest and download through the real GET loop (fake transport)
    $flib = New-AVDTuneFakeLibrary
    Add-AVDTuneFakeLibraryAsset -Library $flib -Name 'corp.ttf' -Content 'FONT'
    Add-AVDTuneFakeLibraryAsset -Library $flib -Name 'setup.ps1' -Content 'exit 0'
    $ctx = New-AVDTuneLibraryContext -SitesToken $flib.SitesToken -GraphToken $flib.GraphToken -SiteUrl $flib.SiteUrl -Library $flib.Library -Transport $flib.Transport
    $man = Get-AVDTuneAssetManifest -Context $ctx
    Test-Check 'library: the manifest of AVDTune-Assets is read with the Sites token, two files with SHA256 and size' ($man.State -eq 'Ready' -and $man.Files.Count -eq 2 -and @($man.Files | Where-Object { $_.Sha256 -cmatch '\A[0-9a-f]{64}\z' }).Count -eq 2) ($man | ConvertTo-Json -Compress -Depth 4)
    $dst = Join-Path $tmp 'dl-font.bin'
    [void](Save-AVDTuneAssetFile -Context $ctx -Name 'corp.ttf' -Sha256 (@($man.Files | Where-Object Name -eq 'corp.ttf')[0].Sha256) -Destination $dst)
    $flib.Store.Tamper['AVDTune-Assets/setup.ps1'] = [Text.Encoding]::UTF8.GetBytes('evil')
    $dst2 = Join-Path $tmp 'dl-script.bin'
    $tt = Get-ThrownText { Save-AVDTuneAssetFile -Context $ctx -Name 'setup.ps1' -Sha256 (@($man.Files | Where-Object Name -eq 'setup.ps1')[0].Sha256) -Destination $dst2 }
    Test-Check 'library: a download is checked against the pinned SHA256; a changed file is deleted and refused' ((Get-Content -Raw $dst) -eq 'FONT' -and $tt -like '*does not match*' -and -not (Test-Path $dst2)) $tt
    Add-AVDTuneFakeLibraryAsset -Library $flib -ManifestRows @(@{ Name = '..\evil.ps1'; Sha256 = ('a' * 64); Size = 5 }, @{ Name = 'ok.ps1'; Sha256 = 'nothex'; Size = 5 }, @{ Name = 'big.ps1'; Sha256 = ('a' * 64); Size = '5' }, @{ Name = 'fine.ps1'; Sha256 = ('A' * 64); Size = 5 })
    $man2 = Get-AVDTuneAssetManifest -Context $ctx
    Test-Check 'library: manifest rows with a bad name, hash or size (size as text) are left out with a note' ($man2.Files.Count -eq 1 -and $man2.Files[0].Name -eq 'fine.ps1' -and $man2.Notes.Count -eq 3) ($man2.Notes -join ' | ')
    $flib.Store.Files.Remove('AVDTune-Assets/manifest.json')
    Test-Check 'library: without AVDTune-Assets the state says so (NoAssets)' ((Get-AVDTuneAssetManifest -Context $ctx).State -eq 'NoAssets') $null
    $items = Get-AVDTuneLibraryItems -Context $ctx -Machine $m
    Test-Check 'the package list of the Software page does not take AVDTune-Assets for a package' (@($items.Items | Where-Object { $_.AppId -eq 'AVDTune-Assets' }).Count -eq 0) $null
    Close-AVDTuneLibraryContext $ctx

    # ---------------------------------------------------------------- the real adapter and the page (source checks)
    $real = New-AVDTuneCustomAdapter
    $need = 'Folder', 'RegGet', 'RegSet', 'RegRemove', 'FileHash', 'ReadText', 'WriteText', 'FileDelete', 'FileMove', 'CopyFile', 'DirInfo', 'DirCreate', 'DirAddRule', 'DirRemoveRule', 'DirRemoveEmpty', 'ShortcutRead', 'ShortcutWrite', 'ShortcutDelete', 'Reachable', 'CacheFolder', 'Download', 'RunScript'
    Test-Check 'the real adapter has every member of the fake (constructed only, not run)' (@($need | Where-Object { -not $real.PSObject.Properties[$_] -or -not $c.PSObject.Properties[$_] }).Count -eq 0) $null
    $src = [IO.File]::ReadAllText((Join-Path $repo 'Modules\AVDTune.Custom.psm1'))
    $runSrc = $src.Substring($src.IndexOf('$a.RunScript = {'))
    Test-Check 'real script start: Windows PowerShell from System32 with its trust check, held open and hashed through the handle, broken signature stops, job object run with timeout' ($runSrc -match "Get-AVDTuneSystemFolder System\) 'WindowsPowerShell" -and $runSrc -match "Test-AVDTuneToolTrust -Signature" -and $runSrc -match 'FileShare\]::Read\)' -and $runSrc -match 'Get-AVDTuneStreamHash \$hold' -and $runSrc -match 'HashMismatch' -and $runSrc -match '& \$u\.Run \$ps') $null
    $wt = $src.Substring($src.IndexOf('$a.WriteText = {'), $src.IndexOf('$a.FileSize = {') - $src.IndexOf('$a.WriteText = {'))
    $dar = $src.Substring($src.IndexOf('$a.DirAddRule = {'), 600)
    Test-Check 'review L4/M2: the real WriteText writes a temp file with the ACL and owner of the target and moves it with Move-AVDTuneFileReplace; the real DirAddRule checks the broad groups again' ($wt.Contains("GetAccessControl([Security.AccessControl.AccessControlSections]'Access, Owner')") -and $wt.Contains('Move-AVDTuneFileReplace $temp $Path') -and -not $wt.Contains('SetLength(0)') -and $dar.Contains('Get-AVDTuneCustomRuleProblem')) $null
    Test-Check 'real writes: no link in the path (WriteText, CopyFile, DirCreate, DirAddRule), shortcuts through the state folder and the Public Desktop check, deletes through Remove-AVDTuneTreeSafe' (([regex]::Matches($src, 'Assert-AVDTuneCustomNoLink \$')).Count -ge 6 -and $src -match 'Get-AVDTunePublicDesktopFindings -Path \$Path' -and ([regex]::Matches($src, 'Remove-AVDTuneTreeSafe -Path')).Count -ge 2 -and $src -notmatch 'Remove-Item -Recurse') $null
    $page = [IO.File]::ReadAllText((Join-Path $repo 'AVDTune-Custom.ps1'))
    Test-Check 'page: the texts come from the language files (T), the job uses New-AVDTunePowerShell, Apply/Undo check the gate and Assert-NoOtherWriter, the masking goes through Get-AVDTuneShortcutChange and Save-AVDTuneRuleSet' ($page -match "T 'cust\." -and $page -match 'New-AVDTunePowerShell' -and $page -match 'Assert-NoOtherWriter' -and $page -match 'Test-AVDTuneWriteAllowed' -and $page -match 'Get-AVDTuneShortcutChange' -and $page -match 'Save-AVDTuneRuleSet' -and $page -notmatch '\[powershell\]::Create') $null
}
finally {
    Close-AVDTuneWriteGate
    Remove-Item Env:\AVDTUNE_ROOT -ErrorAction SilentlyContinue
    if (Test-Path $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
if ($script:failed -gt 0) { throw "$script:failed check(s) failed." }
'Check-Custom: all checks passed.'
