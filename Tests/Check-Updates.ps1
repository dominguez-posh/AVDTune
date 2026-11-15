#requires -Version 5.1
<#
.SYNOPSIS
    Checks the Updates engine (Modules\AVDTune.Updates.psm1) against the fake machine and the fake update adapter (Tests\Fakes\FakeUpdates.ps1):
    the list (Windows with drivers/previews/KB exclusions, Office, Edge, Teams, OneDrive, FSLogix detect-only, Defender, winget/choco inside the lock),
    the run in maintenance mode, result codes with explanations, retry, repair offer, DISM/sfc, history, and the error paths: update fails with a code,
    no network, lock held or foreign, crash inside the run (block restored). No real update, no process, nothing of this computer is changed.
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'Modules\AVDTune.psm1') -Force
Import-Module (Join-Path $repo 'Modules\AVDTune.UpdateBlock.psm1') -Force
Import-Module (Join-Path $repo 'Modules\AVDTune.Updates.psm1') -Force
. (Join-Path $PSScriptRoot 'Fakes\FakeMachine.ps1')
. (Join-Path $PSScriptRoot 'Fakes\FakeUpdates.ps1')

$script:failed = 0
function Test-Check([string]$Name, [bool]$Ok, $Detail) { if ($Ok) { "PASS $Name" } else { $script:failed++; "FAIL $Name" + $(if ($null -ne $Detail) { "  -> $Detail" }) } }
function Get-ThrownText([scriptblock]$Block) { try { & $Block | Out-Null; $null } catch { $_.Exception.Message } }

$wingetTable = @"
Name                 Id                   Version   Available Source
-------------------------------------------------------------------
7-Zip                7zip.7zip            23.01     24.08     winget
Notepad++            Notepad++.Notepad++  8.6       8.7.1     winget
2 upgrades available.
"@
$native = @{
    '* upgrade --source winget *' = @{ ExitCode = 0; Output = $wingetTable }
    '* outdated -r *' = @{ ExitCode = 0; Output = "git|2.40.0|2.45.0|false`r`nvlc|3.0.1|3.0.2|true`r`n" }
    '*OfficeC2RClient*' = @{ ExitCode = 0; Output = '' }
    '*teamsbootstrapper*' = @{ ExitCode = 0; Output = '' }
    '*MicrosoftEdgeUpdate*' = @{ ExitCode = 0; Output = '' }
    '* upgrade --id *' = @{ ExitCode = 0; Output = 'ok' }
    '* upgrade git *' = @{ ExitCode = 0; Output = 'ok' }
    '*\Dism.exe *' = @{ ExitCode = 0; Output = 'The restore operation completed successfully.' }
    '*\sfc.exe *' = @{ ExitCode = 0; Output = 'Windows Resource Protection did not find any integrity violations.' }
}
$wua = @(
    @{ Id = 'u1'; Title = '2026-11 Cumulative Update for Windows 11 (KB5050001)'; Kbs = @('5050001'); IsDriver = $false; SizeMB = 600; Reboot = $true }
    @{ Id = 'u2'; Title = '.NET 9.0 Security Update (KB5050002)'; Kbs = @('5050002'); IsDriver = $false; SizeMB = 80; Reboot = $false }
    @{ Id = 'u3'; Title = 'Contoso Display driver 1.2'; Kbs = @(); IsDriver = $true; SizeMB = 20; Reboot = $false }
    @{ Id = 'u4'; Title = '2026-11 Cumulative Update Preview (KB5050003)'; Kbs = @('5050003'); IsDriver = $false; SizeMB = 600; Reboot = $true }
    @{ Id = 'u5'; Title = 'Servicing Stack Update (KB5050004)'; Kbs = @('5050004'); IsDriver = $false; SizeMB = 30; Reboot = $false }
)
function New-Env([hashtable]$UExtra = @{}, [hashtable]$MExtra = @{}) {
    $ms = @{ Registry = @{ 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}|pv' = '130.0.1'; 'HKLM:\SOFTWARE\FSLogix\Apps|InstallVersion' = '2.9.8884.27471' } }
    foreach ($e in $MExtra.GetEnumerator()) { $ms[$e.Key] = $e.Value }
    $us = @{ Wua = $wua; Native = $native }
    foreach ($e in $UExtra.GetEnumerator()) { $us[$e.Key] = $e.Value }
    @{ M = (New-AVDTuneFakeMachine -Seed $ms); U = (New-AVDTuneFakeUpdates -Seed $us) }
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('avdtune-upd-' + [guid]::NewGuid().ToString('N'))
try {
    $env:AVDTUNE_ROOT = $tmp
    [void](Initialize-AVDTuneState -Root $tmp)
    [void](Start-AVDTuneImageVersion -Root $tmp -Date ([datetime]'2026-11-15') -User 'admin1')
    Close-AVDTuneWriteGate

    # ---------------------------------------------------------------- settings, parsers, explanations
    $s0 = Get-AVDTuneUpdateSettings $tmp
    Test-Check 'settings default: drivers off, previews off, no exclusions, 1 retry, Microsoft Update on' (-not $s0.IncludeDrivers -and -not $s0.IncludePreviews -and $s0.ExcludedKbs.Count -eq 0 -and $s0.Retries -eq 1 -and $s0.MicrosoftUpdate) $null
    Test-Check 'KB list: numbers get KB, duplicates dropped, free text is refused' ((ConvertTo-AVDTuneKbList 'kb5050001, 5050002;KB5050001') -join ',' -eq 'KB5050001,KB5050002' -and (Get-ThrownText { ConvertTo-AVDTuneKbList 'KB1; rm -rf' }) -like '*not a KB number*') $null
    $s1 = Set-AVDTuneUpdateSettings -Root $tmp -ExcludedKbs @('5050004') -Retries 9
    Test-Check 'settings are saved (retries capped at 3) and read back' ($s1.ExcludedKbs -contains 'KB5050004' -and $s1.Retries -eq 3 -and (Get-AVDTuneUpdateSettings $tmp).ExcludedKbs[0] -eq 'KB5050004') $null
    [void](Set-AVDTuneUpdateSettings -Root $tmp -Retries 1)
    $w = ConvertFrom-AVDTuneWingetUpgrade $wingetTable
    Test-Check 'winget table is parsed (name, id, installed, available), the summary line is not a row' ($w.Count -eq 2 -and $w[0].Id -eq '7zip.7zip' -and $w[1].Name -eq 'Notepad++' -and $w[1].Available -eq '8.7.1') ($w | ConvertTo-Json -Compress)
    Test-Check 'winget: nothing to upgrade and garbage give an empty list' ((ConvertFrom-AVDTuneWingetUpgrade 'No installed package found').Count -eq 0 -and (ConvertFrom-AVDTuneWingetUpgrade '').Count -eq 0) $null
    $c = @(ConvertFrom-AVDTuneChocoOutdated "git|2.40.0|2.45.0|false`r`nvlc|3.0.1|3.0.2|true`r`nChocolatey v2.0`r`n")
    Test-Check 'choco outdated: pinned and noise lines are skipped' ($c.Count -eq 1 -and $c[0].Id -eq 'git') ($c | ConvertTo-Json -Compress)
    $e1 = Resolve-AVDTuneWuaError ([int]0x80073712) 4
    Test-Check 'WUA code 0x80073712 is explained and offers the repair' ($e1.Code -eq '0x80073712' -and $e1.Repair -and $e1.Text -like '*component store*' -and $e1.Fix -like '*DISM*') ($e1 | ConvertTo-Json -Compress)
    $e2 = Resolve-AVDTuneWuaError (-2147012889) 4
    Test-Check 'a network code is transient (retry) and needs no repair' ($e2.Code -eq '0x80072EE7' -and $e2.Transient -and -not $e2.Repair) ($e2 | ConvertTo-Json -Compress)
    $e3 = Resolve-AVDTuneWuaError 0x7FFF1234 4
    Test-Check 'an unknown code still gets a readable text with the code' ($e3.Code -eq '0x7FFF1234' -and $e3.Text -like '*0x7FFF1234*not know*') $e3.Text

    # ---------------------------------------------------------------- the list
    $x = New-Env
    $list = Get-AVDTuneUpdateList -Machine $x.M -U $x.U -Root $tmp
    $by = @{}; foreach ($i in $list.Items) { $by[$i.Id] = $i }
    Test-Check 'list: Windows updates; drivers and previews are excluded by default, KB shown' ($by['windows:u1'].Status -eq 'Available' -and $by['windows:u1'].Kb -eq 'KB5050001' -and $by['windows:u2'].Status -eq 'Available' -and $by['windows:u3'].Status -eq 'Excluded' -and $by['windows:u3'].Detail -like 'Driver*' -and $by['windows:u4'].Status -eq 'Excluded' -and $by['windows:u4'].Detail -like 'Preview*') (($list.Items | ForEach-Object { "$($_.Id)=$($_.Status)" }) -join ' ')
    Test-Check 'list: the Microsoft Update note is shown while the service is not registered' (@($list.Notes | Where-Object { $_ -like '*Microsoft Update is not registered*' }).Count -eq 1) ($list.Notes -join '|')
    Test-Check 'list: Office build, Edge, Teams, OneDrive, FSLogix (detect only), Defender' ($by['m365'].Installed -eq '16.0.19231.20138' -and $by['edge'].Installed -eq '130.0.1' -and $by['teams'].Installed -eq '25000.1.1.0' -and $by['onedrive'].Installed -eq '25.100.0' -and $by['fslogix'].Status -eq 'DetectOnly' -and -not $by['fslogix'].Selectable -and $by['defender'].Status -eq 'UpToDate') $null
    Test-Check 'list: winget and choco apps (pinned choco app left out)' ($by['winget:7zip.7zip'].Available -eq '24.08' -and $by['choco:git'].Available -eq '2.45.0' -and -not $by.ContainsKey('choco:vlc')) $null
    Test-Check 'list: winget and choco were read inside the lock, nothing unlocked' (@($x.U.Log | Where-Object { $_ -like 'UNLOCKED*' }).Count -eq 0 -and $x.U.Log -contains 'LockEnter' -and $x.U.Log -contains 'LockExit' -and -not $x.U.Store.LockHeld) ($x.U.Log -join '|')
    Test-Check 'list reads only: no registration, no install' (-not ($x.U.Log -contains 'WuaRegisterMicrosoftUpdate') -and @($x.U.Log | Where-Object { $_ -like 'WuaInstall*' }).Count -eq 0 -and $x.M.Log.Count -eq 0) $null
    [void](Set-AVDTuneUpdateSettings -Root $tmp -IncludeDrivers $true -IncludePreviews $true -ExcludedKbs @('KB5050002'))
    $l2 = Get-AVDTuneUpdateList -Machine $x.M -U $x.U -Root $tmp
    $b2 = @{}; foreach ($i in $l2.Items) { $b2[$i.Id] = $i }
    Test-Check 'settings: drivers and previews on, KB exclude list wins' ($b2['windows:u3'].Status -eq 'Available' -and $b2['windows:u4'].Status -eq 'Available' -and $b2['windows:u2'].Status -eq 'Excluded' -and $b2['windows:u2'].Detail -like '*KB5050002*') $null
    [void](Set-AVDTuneUpdateSettings -Root $tmp)
    # error paths of the list
    $xn = New-Env -UExtra @{ WuaSearchFails = (-2147012889); LockError = 'the lock Global\PackTune belongs to someone else (owner ''S-1-5-21-1'')' }
    $ln = Get-AVDTuneUpdateList -Machine $xn.M -U $xn.U -Root $tmp
    $bn = @{}; foreach ($i in $ln.Items) { $bn[$i.Id] = $i }
    Test-Check 'no network: Windows shows an Error item with the explanation and the fix, the rest of the list still works' ($bn['windows:error'].Status -eq 'Error' -and $bn['windows:error'].Detail -like '*resolved*network*0x80072EE7*' -and $bn['m365'].Status -eq 'Check') $bn['windows:error'].Detail
    Test-Check 'a foreign lock: software is not read (no winget/choco call), the Error item names the lock' ($bn['software:error'].Detail -like '*belongs to someone else*' -and @($xn.U.Log | Where-Object { $_ -like 'Run *' }).Count -eq 0) $null
    $xm = New-Env -UExtra @{ Tools = @() } -MExtra @{ Registry = @{ 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration|VersionToReport' = $null } }
    $lm = Get-AVDTuneUpdateList -Machine $xm.M -U $xm.U -Root $tmp
    Test-Check 'nothing installed: Missing items and notes, no exception' (@($lm.Items | Where-Object { $_.Id -eq 'm365' })[0].Status -eq 'Missing' -and $lm.Notes.Count -ge 2) $null

    # ---------------------------------------------------------------- the run: gate, dry run
    [void](Set-AVDTuneUpdateBlock -Machine $x.M -Root $tmp -Mode On -WhatIf)
    $sel = @($list.Items | Where-Object { $_.Id -in 'windows:u1', 'windows:u2', 'm365', 'winget:7zip.7zip' })
    Test-Check 'a run without the snapshot gate is refused, nothing happens' ((Get-ThrownText { Invoke-AVDTuneUpdateRun -Machine $x.M -U $x.U -Root $tmp -Items $sel }) -like '*snapshot gate*' -and @($x.U.Log | Where-Object { $_ -like 'WuaInstall*' }).Count -eq 0) $null
    $dry = Invoke-AVDTuneUpdateRun -Machine $x.M -U $x.U -Root $tmp -Items $sel -WhatIf
    Test-Check 'dry run lists the items and does not touch anything (no maintenance record, no run)' ($dry.WhatIf -and $dry.Results.Count -eq 4 -and -not (Get-AVDTuneMaintenanceCrash -Root $tmp) -and @(Get-AVDTuneRun -Root $tmp).Count -eq 0) $null
    Test-Check 'excluded and detect-only items are not selectable' (-not $by['windows:u3'].Selectable -and -not $by['fslogix'].Selectable -and $by['windows:u1'].Selectable) $null

    # ---------------------------------------------------------------- the run: success
    Open-AVDTuneWriteGate -SnapshotId 'snap-check' -ConfirmedBy 'Check Runner'
    [void](Set-AVDTuneUpdateBlock -Machine $x.M -Root $tmp -Mode On -User 'admin1')
    $m365Builds = @('16.0.19231.20138')
    $r = Invoke-AVDTuneUpdateRun -Machine $x.M -U $x.U -Root $tmp -Items $sel -User 'admin1' -SnapshotId 'snap-check' -Settings (Get-AVDTuneUpdateSettings $tmp)
    $res = @{}; foreach ($i in $r.Results) { $res[$i.Id] = $i }
    Test-Check 'run: Microsoft Update registered first, both Windows updates installed, winget app updated' ($res['windows:microsoft-update'].Status -eq 'Changed' -and $res['windows:u1'].Status -eq 'Changed' -and $res['windows:u2'].Status -eq 'Changed' -and $res['winget:7zip.7zip'].Status -eq 'Changed') (($r.Results | ForEach-Object { "$($_.Id)=$($_.Status)" }) -join ' ')
    Test-Check 'run: M365 with no new build is Unchanged with a clear text (not a failure)' ($res['m365'].Status -eq 'Unchanged' -and $res['m365'].Message -like '*No newer build*') $res['m365'].Message
    Test-Check 'run: the block was lifted during the run and is back afterwards (state, record, status)' ((Get-AVDTuneUpdateBlockStatus $x.M).State -eq 'On' -and (Get-AVDTuneState $tmp).Maintenance.Phase -eq 'restored' -and -not (Get-AVDTuneMaintenanceCrash -Root $tmp)) $null
    Test-Check 'run: run record Updates and LastUpdate in the state' ($r.Run.Plan -eq 'Updates' -and (Get-AVDTuneState $tmp).LastUpdate -like '2026-*') $null
    $cl = @(Get-AVDTuneChangeLog -Root $tmp | Where-Object { $_.ChangeType -eq 'Updated' })
    Test-Check 'change log: one Updated entry per updated item with the KB, categories Windows/Software' ($cl.Count -ge 4 -and @($cl | Where-Object { $_.Text -like '*KB5050001*' -and $_.Category -eq 'Windows' }).Count -eq 1 -and @($cl | Where-Object { $_.Category -eq 'Software' }).Count -ge 1) ($cl | ForEach-Object Text) -join ' | '
    Test-Check 'winget ran inside the lock, with an exact id and no free text' (@($x.U.Log | Where-Object { $_ -like 'UNLOCKED*' }).Count -eq 0 -and @($x.U.Log | Where-Object { $_ -like 'Run C:\fake\winget.exe upgrade --id 7zip.7zip --exact*' }).Count -eq 1) ($x.U.Log -join '|')

    # ---------------------------------------------------------------- failure with a code, retry, repair
    $y = New-Env -UExtra @{ WuaResults = @{
                'u1' = @(@{ Ok = $true; ResultCode = 4; HResult = (-2147012889); RebootRequired = $false }, @{ Ok = $true; ResultCode = 2; HResult = 0; RebootRequired = $true })
                'u2' = @(@{ Ok = $true; ResultCode = 4; HResult = ([int]0x80073712); RebootRequired = $false })
            }; MicrosoftUpdate = $true }
    [void](Set-AVDTuneUpdateBlock -Machine $y.M -Root $tmp -Mode On -User 'admin1')
    $ry = Invoke-AVDTuneUpdateRun -Machine $y.M -U $y.U -Root $tmp -Items @($list.Items | Where-Object { $_.Id -in 'windows:u1', 'windows:u2' }) -User 'admin1' -SnapshotId 'snap-check'
    $rr = @{}; foreach ($i in $ry.Results) { $rr[$i.Id] = $i }
    Test-Check 'a transient failure is retried and then succeeds (2 attempts)' ($rr['windows:u1'].Status -eq 'Changed' -and $rr['windows:u1'].Attempts -eq 2 -and $rr['windows:u1'].Reboot) "$($rr['windows:u1'].Status) $($rr['windows:u1'].Attempts)"
    Test-Check 'a hard failure: Failed after 2 attempts, code, explanation and fix in the result, repair offered' ($rr['windows:u2'].Status -eq 'Failed' -and $rr['windows:u2'].Attempts -eq 2 -and $rr['windows:u2'].Code -eq '0x80073712' -and $rr['windows:u2'].Message -like '*component store*DISM*' -and $ry.RepairOffered) ($rr['windows:u2'] | ConvertTo-Json -Compress)
    Test-Check 'Microsoft Update was already registered: no second registration' (-not ($y.U.Log -contains 'WuaRegisterMicrosoftUpdate')) $null
    Test-Check 'the failure is in the change log (Note with code) and the block is back' (@(Get-AVDTuneChangeLog -Root $tmp | Where-Object { $_.Text -like '*FAILED (0x80073712)*' }).Count -eq 1 -and (Get-AVDTuneUpdateBlockStatus $y.M).State -eq 'On') $null
    $d = Invoke-AVDTuneRepair -Machine $y.M -U $y.U -Root $tmp -Kind Dism -User 'admin1' -SnapshotId 'snap-check'
    $sf = Invoke-AVDTuneRepair -Machine $y.M -U $y.U -Root $tmp -Kind Sfc -User 'admin1'
    Test-Check 'repair: DISM /RestoreHealth and sfc /scannow with exact arguments, results and change log' ($d.Status -eq 'Changed' -and $sf.Status -eq 'Changed' -and @($y.U.Log | Where-Object { $_ -eq 'Run C:\fake\System32\Dism.exe /Online /Cleanup-Image /RestoreHealth' }).Count -eq 1 -and @($y.U.Log | Where-Object { $_ -eq 'Run C:\fake\System32\sfc.exe /scannow' }).Count -eq 1 -and @(Get-AVDTuneChangeLog -Root $tmp | Where-Object { $_.Component -eq 'Repair' }).Count -eq 2) $null
    $y.U.Store.Native['*\Dism.exe *'] = @{ ExitCode = 1726; Output = 'The remote procedure call failed.' }
    $df = Invoke-AVDTuneRepair -Machine $y.M -U $y.U -Root $tmp -Kind Dism
    Test-Check 'a failing repair is reported with its exit code' ($df.Status -eq 'Failed' -and $df.Message -like '*1726*') $df.Message
    Close-AVDTuneWriteGate
    Test-Check 'repair needs the open gate' ((Get-ThrownText { Invoke-AVDTuneRepair -Machine $y.M -U $y.U -Root $tmp -Kind Sfc }) -like '*snapshot gate*') $null
    Open-AVDTuneWriteGate -SnapshotId 'snap-check' -ConfirmedBy 'Check Runner'

    # ---------------------------------------------------------------- other failures
    $z = New-Env -UExtra @{ Defender = @{ Version = '1.0'; LastUpdated = [datetime]'2020-01-01' }; RegisterFails = $true; DefenderFails = $true; Signatures = @{ 'teamsbootstrapper.exe' = @{ Valid = $true; Subject = 'CN=Microsoft Corporation, O=Microsoft Corporation Evil Ltd, C=US'; Issuer = 'CN=Microsoft Code Signing PCA 2024, O=Microsoft Corporation, C=US' } }
            Native = @{ '*OfficeC2RClient*' = @{ ExitCode = 17002; Output = 'failed' }; '* upgrade --id *' = @{ ExitCode = -1978335215; Output = 'hash' }; '* upgrade git *' = @{ ExitCode = 1618; Output = '' }; '*MicrosoftEdgeUpdate*' = @{ ExitCode = 0; Output = '' }; '* upgrade --source *' = @{ ExitCode = 0; Output = '' }; '* outdated *' = @{ ExitCode = 0; Output = '' } } }
    [void](Set-AVDTuneUpdateBlock -Machine $z.M -Root $tmp -Mode On -User 'admin1')
    $zl = Get-AVDTuneUpdateList -Machine $z.M -U $z.U -Root $tmp
    $zi = @($zl.Items | Where-Object { $_.Id -in 'windows:u1', 'm365', 'teams', 'defender' })
    $zi += [pscustomobject]@{ Id = 'winget:7zip.7zip'; Group = 'Software'; Title = '7-Zip'; Installed = '1'; Kb = ''; Selectable = $true }
    $zi += [pscustomobject]@{ Id = 'choco:git'; Group = 'Software'; Title = 'git'; Installed = '1'; Kb = ''; Selectable = $true }
    $zr = Invoke-AVDTuneUpdateRun -Machine $z.M -U $z.U -Root $tmp -Items $zi -User 'admin1'
    $q = @{}; foreach ($i in $zr.Results) { $q[$i.Id] = $i }
    Test-Check 'Microsoft Update cannot be registered: reported, the Windows updates still run' ($q['windows:microsoft-update'].Status -eq 'Failed' -and $q['windows:u1'].Status -eq 'Changed') $null
    Test-Check 'M365 with an error code: Failed with the code' ($q['m365'].Status -eq 'Failed' -and $q['m365'].Code -eq '17002') $null
    Test-Check 'Teams: a file signed by "O=Microsoft Corporation Evil Ltd" is never run, the checked copy is removed' ($q['teams'].Status -eq 'Failed' -and $q['teams'].Code -eq 'BadSignature' -and @($z.U.Log | Where-Object { $_ -like 'Run *teamsbootstrapper*' }).Count -eq 0 -and @($z.U.Log | Where-Object { $_ -like 'Unstage *teamsbootstrapper*' }).Count -eq 1) $q['teams'].Message
    Test-Check 'Defender offline: Failed with the reason' ($q['defender'].Status -eq 'Failed' -and $q['defender'].Message -like '*offline*') $null
    Test-Check 'winget hash mismatch and choco 1618 get readable texts' ($q['winget:7zip.7zip'].Message -like '*hash*' -and $q['choco:git'].Message -like '*Another installation*') "$($q['winget:7zip.7zip'].Message) | $($q['choco:git'].Message)"
    Test-Check 'after all that failing the block is back on' ((Get-AVDTuneUpdateBlockStatus $z.M).State -eq 'On' -and -not (Get-AVDTuneMaintenanceCrash -Root $tmp)) $null
    $zl2 = New-Env -UExtra @{ LockError = 'lock held' }
    [void](Set-AVDTuneUpdateBlock -Machine $zl2.M -Root $tmp -Mode On -User 'admin1')
    $lr = Invoke-AVDTuneUpdateRun -Machine $zl2.M -U $zl2.U -Root $tmp -Items @([pscustomobject]@{ Id = 'winget:7zip.7zip'; Group = 'Software'; Title = '7-Zip'; Installed = '1'; Kb = ''; Selectable = $true })
    Test-Check 'lock not available: nothing installed, the result says why' ($lr.Results[0].Status -eq 'Failed' -and $lr.Results[0].Code -eq 'Lock' -and @($zl2.U.Log | Where-Object { $_ -like 'Run *' }).Count -eq 0) $null

    # ---------------------------------------------------------------- crash inside the run
    $k = New-Env
    [void](Set-AVDTuneUpdateBlock -Machine $k.M -Root $tmp -Mode On -User 'admin1')
    $k.U.Store.WuaResults['u1'] = $null
    $k.U.WuaInstall = { param($Id) throw 'process died' }
    $kr = Invoke-AVDTuneUpdateRun -Machine $k.M -U $k.U -Root $tmp -Items @($list.Items | Where-Object { $_.Id -eq 'windows:u1' }) -User 'admin1'
    Test-Check 'an exception inside an item is a Failed result, the run goes on and the block is restored' ($kr.Results[-1].Status -eq 'Failed' -and $kr.Results[-1].Code -eq 'Exception' -and (Get-AVDTuneUpdateBlockStatus $k.M).State -eq 'On') $null

    # ---------------------------------------------------------------- LastChange for the snapshot gate (with the block off, the maintenance mode changes nothing)
    $old = '2000-01-01T00:00:00.0000000Z'
    $lc = New-Env
    [void](Set-AVDTuneUpdateBlock -Machine $lc.M -Root $tmp -Mode Off -User 'admin1')
    [void](Set-AVDTuneState -Root $tmp -Values @{ LastChange = $old })
    [void](Invoke-AVDTuneUpdateRun -Machine $lc.M -U $lc.U -Root $tmp -Items @([pscustomobject]@{ Id = 'winget:7zip.7zip'; Group = 'Software'; Title = '7-Zip'; Installed = '1'; Kb = ''; Selectable = $true }) -User 'admin1')
    $lcRun = [string](Get-AVDTuneState $tmp).LastChange
    [void](Set-AVDTuneState -Root $tmp -Values @{ LastChange = $old })
    [void](Invoke-AVDTuneRepair -Machine $lc.M -U $lc.U -Root $tmp -Kind Sfc -User 'admin1')
    $lcRep = [string](Get-AVDTuneState $tmp).LastChange
    $lcSeen = @{}
    $lcOrigRun = $lc.U.Run
    $lc.U.Run = { param($File, $Arguments, $Timeout) $lcSeen.AtFirstItem = [string](Get-AVDTuneState $tmp).LastChange; & $lcOrigRun $File $Arguments $Timeout }.GetNewClosure()
    [void](Set-AVDTuneState -Root $tmp -Values @{ LastChange = $old })
    [void](Invoke-AVDTuneUpdateRun -Machine $lc.M -U $lc.U -Root $tmp -Items @([pscustomobject]@{ Id = 'winget:7zip.7zip'; Group = 'Software'; Title = '7-Zip'; Installed = '1'; Kb = ''; Selectable = $true }) -User 'admin1')
    Test-Check 'LastChange is set before the first item of a run, also with the block already off' ($lcSeen.AtFirstItem -and $lcSeen.AtFirstItem -ne $old) $lcSeen.AtFirstItem
    Test-Check 'LastChange in state.json is set by an update run and by a repair (snapshot gate)'  ($lcRun -and $lcRun -ne $old -and $lcRep -and $lcRep -ne $old) "$lcRun | $lcRep"

    # ---------------------------------------------------------------- trusted tools (security review of #6)
    $ms = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'; $msCa = 'CN=Microsoft Code Signing PCA 2024, O=Microsoft Corporation, C=US'
    $sig = { param($Subject, $Issuer, $Orig, $Valid = $true) [pscustomobject]@{ Valid = $Valid; Status = $(if ($Valid) { 'Valid' } else { 'HashMismatch' }); Subject = $Subject; Issuer = $Issuer; OriginalFilename = $Orig } }
    $trustCases = @(
        @{ N = 'Microsoft winget'; Name = 'winget.exe'; S = (& $sig $ms $msCa 'winget.exe'); Ok = $true }
        @{ N = 'Windows Dism (.mui name, production CA)'; Name = 'Dism.exe'; S = (& $sig 'CN=Microsoft Windows, O=Microsoft Corporation, L=Redmond, C=US' 'CN=Microsoft Windows Production PCA 2026 RSA2048-SHA256, O=Microsoft Corporation, C=US' 'DISM.EXE.MUI'); Ok = $true }
        @{ N = 'Chocolatey choco'; Name = 'choco.exe'; S = (& $sig 'CN="Chocolatey Software, Inc", O="Chocolatey Software, Inc", L=Topeka, C=US' 'CN=DigiCert Trusted G4 Code Signing RSA4096 SHA384 2021 CA1, O="DigiCert, Inc.", C=US' 'choco.exe'); Ok = $true }
        @{ N = 'O=Microsoft Corporation Evil Ltd'; Name = 'teamsbootstrapper.exe'; S = (& $sig 'CN=Microsoft Corporation, O=Microsoft Corporation Evil Ltd, C=US' $msCa 'teamsbootstrapper.exe'); Ok = $false }
        @{ N = 'O= only inside another part'; Name = 'teamsbootstrapper.exe'; S = (& $sig 'CN=Evil, OU=O=Microsoft Corporation, O=Evil' $msCa 'teamsbootstrapper.exe'); Ok = $false }
        @{ N = 'issuer that is not a Microsoft CA'; Name = 'winget.exe'; S = (& $sig $ms 'CN=Microsoft Code Signing PCA 2024, O=Evil CA, C=US' 'winget.exe'); Ok = $false }
        @{ N = 'other original file name (a signed Microsoft tool renamed)'; Name = 'teamsbootstrapper.exe'; S = (& $sig $ms $msCa 'cmd.exe'); Ok = $false }
        @{ N = 'choco.exe signed by Microsoft'; Name = 'choco.exe'; S = (& $sig $ms $msCa 'choco.exe'); Ok = $false }
        @{ N = 'not valid'; Name = 'winget.exe'; S = (& $sig $ms $msCa 'winget.exe' $false); Ok = $false }
        @{ N = 'two O= parts'; Name = 'winget.exe'; S = (& $sig 'CN=Microsoft Corporation, O=Evil, O=Microsoft Corporation' $msCa 'winget.exe'); Ok = $false }
        @{ N = 'a name that cannot be parsed'; Name = 'winget.exe'; S = (& $sig 'garbage ,,=' $msCa 'winget.exe'); Ok = $false }
        @{ N = 'unknown tool'; Name = 'evil.exe'; S = (& $sig $ms $msCa 'evil.exe'); Ok = $false })
    $wrong = @($trustCases | Where-Object { (Test-AVDTuneToolTrust -Signature $_.S -Name $_.Name).Ok -ne $_.Ok } | ForEach-Object N)
    Test-Check 'tool signatures: publisher O and CN exact, issuer a CA of the publisher, original file name; everything else refused' ($wrong.Count -eq 0) ($wrong -join ', ')

    $t = New-Env
    [void](Set-AVDTuneUpdateBlock -Machine $t.M -Root $tmp -Mode On -User 'admin1')
    $tr = Invoke-AVDTuneUpdateRun -Machine $t.M -U $t.U -Root $tmp -Items @([pscustomobject]@{ Id = 'teams'; Group = 'Teams'; Title = 'Teams'; Installed = '1'; Kb = ''; Selectable = $true }) -User 'admin1'
    $tl = @($t.U.Log | Where-Object { $_ -like '*teamsbootstrapper*' })
    Test-Check 'Teams runs as a checked copy: stage, check the copy, run the copy, remove it' ($tr.Results[-1].Status -ne 'Failed' -and ($tl -join '|') -eq 'Stage C:\fake\teamsbootstrapper.exe|VerifySignature C:\fake\staged\teamsbootstrapper.exe|Run C:\fake\staged\teamsbootstrapper.exe -p|Unstage C:\fake\staged\teamsbootstrapper.exe') ($tl -join '|')
    $bw = New-Env -UExtra @{ Signatures = @{ 'winget.exe' = @{ Valid = $true; Subject = 'CN=Someone, O=Someone'; Issuer = 'CN=Someone CA' } } }
    $bl = Get-AVDTuneUpdateList -Machine $bw.M -U $bw.U -Root $tmp
    Test-Check 'a winget.exe that is not signed by Microsoft is not used: note, no winget call, Chocolatey still read' (@($bl.Notes | Where-Object { $_ -like 'winget is not used*not signed by Microsoft*' }).Count -eq 1 -and @($bw.U.Log | Where-Object { $_ -like 'Run *winget*' }).Count -eq 0 -and @($bw.U.Log | Where-Object { $_ -like 'Run *choco.exe outdated*' }).Count -eq 1) ($bl.Notes -join ' | ')
    $mo = New-Env -UExtra @{ Signatures = @{ 'OfficeC2RClient.exe' = @{ Valid = $false; Subject = '' } } }
    [void](Set-AVDTuneUpdateBlock -Machine $mo.M -Root $tmp -Mode On -User 'admin1')
    $mr = Invoke-AVDTuneUpdateRun -Machine $mo.M -U $mo.U -Root $tmp -Items @([pscustomobject]@{ Id = 'm365'; Group = 'Microsoft 365 Apps'; Title = 'Microsoft 365 Apps'; Installed = '1'; Kb = ''; Selectable = $true }) -User 'admin1'
    Test-Check 'an OfficeC2RClient.exe without a valid signature is not started' ($mr.Results[-1].Status -eq 'Failed' -and $mr.Results[-1].Code -eq 'BadSignature' -and @($mo.U.Log | Where-Object { $_ -like 'Run *OfficeC2RClient*' }).Count -eq 0) $mr.Results[-1].Message

    $folders = @('Microsoft.DesktopAppInstaller_1.9.25200.0_x64__8wekyb3d8bbwe', 'Microsoft.DesktopAppInstaller_1.29.380.0_x64__8wekyb3d8bbwe', 'Microsoft.DesktopAppInstaller_1.3.2091.0_x64__8wekyb3d8bbwe', 'Microsoft.DesktopAppInstaller_bad_x64__8wekyb3d8bbwe')
    $newest = Select-AVDTuneNewestPackageFolder $folders
    Test-Check 'winget: the newest DesktopAppInstaller by version (1.29 over 1.9 and 1.3), not by text' ($newest -eq $folders[1]) $newest

    $adm = 'S-1-5-32-544'; $usr = 'S-1-5-32-545'
    $aclCases = @(
        @{ N = 'admins full, users read and execute'; O = $adm; R = @(@{ Sid = $adm; Allow = $true; Rights = 0x1f01ff; InheritOnly = $false }, @{ Sid = $usr; Allow = $true; Rights = 0x1200a9; InheritOnly = $false }); Ok = $true }
        @{ N = 'creator owner generic all (inherit only)'; O = 'S-1-5-18'; R = @(@{ Sid = 'S-1-3-0'; Allow = $true; Rights = 0x10000000; InheritOnly = $true }); Ok = $true }
        @{ N = 'users may write'; O = $adm; R = @(@{ Sid = $usr; Allow = $true; Rights = 0x1201bf; InheritOnly = $false }); Ok = $false }
        @{ N = 'users may add files (ProgramData style)'; O = $adm; R = @(@{ Sid = $usr; Allow = $true; Rights = 0x2; InheritOnly = $false }); Ok = $false }
        @{ N = 'owned by a user'; O = 'S-1-5-21-1-2-3-1001'; R = @(@{ Sid = $adm; Allow = $true; Rights = 0x1f01ff; InheritOnly = $false }); Ok = $false })
    $wrongAcl = @($aclCases | Where-Object { (Test-AVDTuneAdminOnlyAcl -Owner $_.O -Rules $_.R) -ne $_.Ok } | ForEach-Object N)
    Test-Check 'admin-only permissions: only SYSTEM, Administrators and TrustedInstaller own and may write' ($wrongAcl.Count -eq 0) ($wrongAcl -join ', ')

    # the real adapter, read only: environment variables and PATH of this process are set to a folder the user owns; nothing may come from there
    $evil = Join-Path $tmp 'evil'
    [void](New-Item -ItemType Directory -Path (Join-Path $evil 'bin') -Force)
    Copy-Item (Join-Path $repo 'README.md') (Join-Path $evil 'bin\choco.exe'); Copy-Item (Join-Path $repo 'README.md') (Join-Path $evil 'teamsbootstrapper.exe'); Copy-Item (Join-Path $repo 'README.md') (Join-Path $evil 'avdtune-path-tool.exe')
    $keepEnv = @{}; foreach ($n in 'ProgramFiles', 'ProgramFiles(x86)', 'CommonProgramFiles', 'SystemRoot', 'windir', 'ChocolateyInstall', 'PATH') { $keepEnv[$n] = [Environment]::GetEnvironmentVariable($n, 'Process') }
    try {
        foreach ($n in 'ProgramFiles', 'ProgramFiles(x86)', 'CommonProgramFiles', 'SystemRoot', 'windir', 'ChocolateyInstall') { [Environment]::SetEnvironmentVariable($n, $evil, 'Process') }
        [Environment]::SetEnvironmentVariable('PATH', "$evil;$($keepEnv['PATH'])", 'Process')
        $real = New-AVDTuneUpdateAdapter
        $paths = @('C2R', 'EdgeUpdate', 'OneDrive', 'Dism', 'Sfc') | ForEach-Object { & $real.Path $_ }
        $sys = [Environment]::GetFolderPath('System')
        Test-Check 'real adapter: tool paths come from the system folders, not from environment variables; Dism and sfc with full path' (@($paths | Where-Object { $_ -like "$evil*" }).Count -eq 0 -and (& $real.Path 'Dism') -eq (Join-Path $sys 'Dism.exe') -and (& $real.Path 'Sfc') -eq (Join-Path $sys 'sfc.exe') -and (& $real.Path 'C2R') -eq (Join-Path ([Environment]::GetFolderPath('CommonProgramFiles')) 'Microsoft Shared\ClickToRun\OfficeC2RClient.exe')) ($paths -join ' | ')
        $pathHit = & $real.FindTool 'avdtune-path-tool.exe'; $chocoHit = & $real.FindTool 'choco.exe'
        Test-Check 'real adapter: no tool from PATH or from ChocolateyInstall of the process' ($null -eq $pathHit -and $null -eq (& $real.FindTool 'notepad.exe') -and ($null -eq $chocoHit -or $chocoHit -notlike "$evil*")) "$pathHit | $chocoHit"
        Test-Check 'real adapter: a tool in a folder this user can change is not used (config\tools must be admin-only)' ($null -eq (& $real.FindTool 'teamsbootstrapper.exe' $evil)) $null
        Test-Check 'real adapter: Dism.exe in System32 counts as admin-only (no false alarm on the real system folder)' (Test-AVDTuneAdminOnlyPath -Path (Join-Path $sys 'Dism.exe') -Base ([Environment]::GetFolderPath('Windows'))) $null
    }
    finally { foreach ($n in $keepEnv.Keys) { [Environment]::SetEnvironmentVariable($n, $keepEnv[$n], 'Process') } }
    $real = New-AVDTuneUpdateAdapter
    $staged = & $real.Stage (Join-Path $repo 'README.md') $tmp
    $sacl = Get-Acl -LiteralPath (Split-Path $staged -Parent)
    $own = @($sacl.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier]))
    $stagedThere = Test-Path -LiteralPath $staged
    & $real.Unstage $staged
    Test-Check 'real adapter: the staged copy lies under <root>\temp in a folder without rules of its own (it inherits the protected state folder: no user entry) and is removed afterwards' ($stagedThere -and $staged -like "$tmp\temp\*\README.md" -and $own.Count -eq 0 -and -not $sacl.AreAccessRulesProtected -and -not (Test-Path -LiteralPath (Split-Path $staged -Parent))) "$staged | own rules: $(@($own | ForEach-Object { $_.IdentityReference.Value }) -join ',')"
    # a copy still in use (the tool has just ended) is removed by the retry
    $busy = & $real.Stage (Join-Path $repo 'README.md') $tmp
    $flag = Join-Path $tmp 'busy.flag'
    $holder = Start-Job -ScriptBlock { param($f, $flag) $s = [IO.File]::Open($f, 'Open', 'Read', 'None'); Set-Content -LiteralPath $flag -Value 1; Start-Sleep -Milliseconds 1500; $s.Dispose() } -ArgumentList $busy, $flag
    try {
        $until = (Get-Date).AddSeconds(30); while (-not (Test-Path -LiteralPath $flag) -and (Get-Date) -lt $until) { Start-Sleep -Milliseconds 100 }
        & $real.Unstage $busy
        Test-Check 'real adapter: Unstage tries again while the copy is still in use' ((Test-Path -LiteralPath $flag) -and -not (Test-Path -LiteralPath (Split-Path $busy -Parent))) $busy
    }
    finally { $holder | Wait-Job -Timeout 30 | Out-Null; $holder | Remove-Job -Force }
    # leftovers of a crash are removed at the start; a link in there is removed as a link, its target is untouched
    $left = & $real.Stage (Join-Path $repo 'README.md') $tmp
    $outside = Join-Path $tmp 'outside'; [void](New-Item -ItemType Directory -Path $outside -Force); Set-Content -LiteralPath (Join-Path $outside 'keep.txt') -Value 'keep'
    $link = Join-Path $tmp ('temp\' + [guid]::NewGuid().ToString('N'))
    $cmd = Join-Path ([Environment]::GetFolderPath('System')) 'cmd.exe'
    [void](& $cmd /c mklink /J $link $outside)
    $cleared = Clear-AVDTuneStageFolder -Root $tmp
    Test-Check 'start: staging folders left behind are removed, a junction only as a link (its target keeps its file)' ($cleared -eq 2 -and -not (Test-Path -LiteralPath (Split-Path $left -Parent)) -and -not (Test-Path -LiteralPath $link) -and (Test-Path -LiteralPath (Join-Path $outside 'keep.txt'))) "cleared $cleared"

    # the real Run with harmless processes this check starts itself (powershell.exe and ping.exe on 127.0.0.1); their PIDs are tracked and only they are stopped
    $ps = Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell\v1.0\powershell.exe'
    $pidFile = Join-Path $tmp 'child.pid'
    $enc = { param($Text) [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Text)) }
    $startChild = "`$c = [Diagnostics.Process]::Start((Join-Path ([Environment]::GetFolderPath('System')) 'PING.EXE'), '-n {0} 127.0.0.1'); Set-Content -LiteralPath '$pidFile' -Value `$c.Id; Start-Sleep -Seconds {1}"
    $childPids = @()
    try {
        $t0 = Get-Date
        $rt = & $real.Run $ps @('-NoProfile', '-NonInteractive', '-EncodedCommand', (& $enc ($startChild -f 60, 60))) 4
        $kid = [int](Get-Content -LiteralPath $pidFile); $childPids += $kid
        Start-Sleep -Milliseconds 500
        $alive = [bool](Get-Process -Id $kid -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -eq 'PING' })
        Test-Check 'real Run: a timeout ends the whole tree (the child of the tool too), so the lock is not freed while an installer still runs' ($rt.Output -eq 'timeout' -and -not $alive -and ((Get-Date) - $t0).TotalSeconds -lt 40) "alive=$alive"
        Remove-Item -LiteralPath $pidFile -ErrorAction SilentlyContinue
        $t1 = Get-Date
        $rn = & $real.Run $ps @('-NoProfile', '-NonInteractive', '-EncodedCommand', (& $enc ($startChild -f 4, 0))) 60
        $took = ((Get-Date) - $t1).TotalSeconds
        $kid2 = [int](Get-Content -LiteralPath $pidFile); $childPids += $kid2
        $alive2 = [bool](Get-Process -Id $kid2 -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -eq 'PING' })
        Test-Check 'real Run: returns only when the child the tool left behind has ended (the lock is held until then)' ($rn.ExitCode -eq 0 -and -not $alive2 -and $took -ge 2.5) "took $took s, alive=$alive2"
    }
    finally { foreach ($k in $childPids) { Get-Process -Id $k -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -eq 'PING' } | Stop-Process -Force -ErrorAction SilentlyContinue } }

    # ---------------------------------------------------------------- history
    $h = @(Get-AVDTuneUpdateHistory -Root $tmp)
    Test-Check 'history: runs and repairs, newest first, with code and text' ($h.Count -ge 15 -and @($h | Where-Object { $_.Code -eq '0x80073712' }).Count -ge 1 -and @($h | Where-Object { $_.Group -eq 'Windows' }).Count -ge 5) $h.Count
    Test-Check 'the check never used the real state folder' ($tmp -ne (Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'AVDTune')) $tmp
    # the real adapter exposes the same members as the fake (read only, nothing is called)
    $real = New-AVDTuneUpdateAdapter; $fake = New-AVDTuneFakeUpdates
    $missing = @($real.PSObject.Properties.Name | Where-Object { $_ -notin 'Kind', 'State' -and $_ -notin $fake.PSObject.Properties.Name })
    Test-Check 'real and fake adapter have the same members' ($missing.Count -eq 0 -and $real.Kind -eq 'Real') ($missing -join ',')
    Test-Check 'real adapter, read only: a missing tool is null, a signature check of a plain file is not Valid and not trusted' ($null -eq (& $real.FindTool 'avdtune-no-such-tool.exe') -and -not (& $real.VerifySignature (Join-Path $repo 'README.md')).Valid -and -not (Test-AVDTuneToolTrust -Signature (& $real.VerifySignature (Join-Path $repo 'README.md')) -Name 'winget.exe').Ok) $null
}
finally {
    Close-AVDTuneWriteGate
    $env:AVDTUNE_ROOT = $null
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
if ($script:failed -gt 0) { throw "$script:failed check(s) failed." }
'Check-Updates: all checks passed.'
