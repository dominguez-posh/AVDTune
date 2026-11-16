#requires -Version 5.1
<#
.SYNOPSIS
    Checks the update block for users and maintenance mode (Modules\AVDTune.UpdateBlock.psm1) against the fake machine and a temporary state
    folder: the catalog, status, On/Off, idempotency, products that are not installed, the maintenance mode (lifted inside, restored in the
    finally block, restore failure), a crash in the middle (found and repaired at the next start), a block that was reset from outside, and
    the write gate. Nothing touches the registry, services or tasks of this computer.
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'Modules\AVDTune.psm1') -Force
Import-Module (Join-Path $repo 'Modules\AVDTune.UpdateBlock.psm1') -Force
. (Join-Path $PSScriptRoot 'Fakes\FakeMachine.ps1')

$script:failed = 0
function Test-Check([string]$Name, [bool]$Ok, $Detail) { if ($Ok) { "PASS $Name" } else { $script:failed++; "FAIL $Name" + $(if ($null -ne $Detail) { "  -> $Detail" }) } }
function Test-Throws([scriptblock]$Block) { try { & $Block | Out-Null; $false } catch { $true } }
function Get-ThrownText([scriptblock]$Block) { try { & $Block | Out-Null; $null } catch { $_.Exception.Message } }
function New-Master([hashtable]$Extra = @{}) {
    $seed = @{
        Tasks = @(
            @{ Path = '\'; Name = 'MicrosoftEdgeUpdateTaskMachineCore{11111111-2222-3333-4444-555555555555}'; Enabled = $true }
            @{ Path = '\'; Name = 'MicrosoftEdgeUpdateTaskMachineUA{66666666-7777-8888-9999-000000000000}'; Enabled = $true }
            @{ Path = '\'; Name = 'SomethingElse'; Enabled = $true }
        )
        Services = @(@{ Name = 'wuauserv'; StartType = 'Manual'; Status = 'Stopped' }, @{ Name = 'UsoSvc'; StartType = 'Automatic' }, @{ Name = 'WaaSMedicSvc'; StartType = 'Manual' })
    }
    foreach ($e in $Extra.GetEnumerator()) { $seed[$e.Key] = $e.Value }
    New-AVDTuneFakeMachine -Seed $seed
}
$wu = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('avdtune-block-' + [guid]::NewGuid().ToString('N'))
try {
    $env:AVDTUNE_ROOT = $tmp
    [void](Initialize-AVDTuneState -Root $tmp)
    [void](Start-AVDTuneImageVersion -Root $tmp -Date ([datetime]'2026-11-15') -User 'admin1')
    Close-AVDTuneWriteGate

    # ---------------------------------------------------------------- catalog
    $catalog = @(Get-AVDTuneUpdateBlockCatalog)
    $ids = @($catalog | ForEach-Object Id)
    Test-Check 'catalog: unique ids, every step has Test/Apply/Undo and an https source' (($ids | Sort-Object -Unique).Count -eq $ids.Count -and -not (@($catalog | Where-Object { -not $_.Step.Undo -or -not $_.Step.SourceUrl -or $_.Step.Section -ne 'UpdateBlock' }).Count)) $ids.Count
    $groups = @($catalog | ForEach-Object Group | Sort-Object -Unique)
    Test-Check 'catalog covers Windows, Office, Edge, Chrome, Teams, Adobe, Store (section 4)' (('Adobe,Chrome,Edge,Microsoft 365 Apps,Store,Teams,Windows') -eq ($groups -join ',')) ($groups -join ',')
    $win = @($catalog | Where-Object { $_.Group -eq 'Windows' })
    Test-Check 'Windows: the three policies, no service is touched' ($win.Count -eq 3 -and ($win.Registry -join ' ') -like '*SetDisableUXWUAccess = 1*NoAutoUpdate = 1*NoAutoRebootWithLoggedOnUsers = 1*' -and -not (@($catalog | Where-Object { $_.Registry -like 'service wuauserv*' -or $_.Registry -like 'service UsoSvc*' -or $_.Registry -like 'service WaaSMedicSvc*' }).Count)) $null
    Test-Check 'the reason of the Windows steps says why services stay' (($win[0].Step.Why -like '*WaaSMedic*')) $null

    # ---------------------------------------------------------------- status of a clean master
    $m = New-Master
    $st = Get-AVDTuneUpdateBlockStatus $m
    Test-Check 'clean master: block Off, 10 applicable (Chrome and Adobe are not installed)' ($st.State -eq 'Off' -and $st.Applicable -eq 10 -and $st.Compliant -eq 0 -and @($st.Items | Where-Object { -not $_.Applicable }).Count -eq 6) "$($st.State) $($st.Applicable)"
    Test-Check 'status reads only: nothing was written' ($m.Log.Count -eq 0) $m.Log.Count

    # ---------------------------------------------------------------- write gate
    Test-Check 'On without the snapshot gate is refused, nothing written' ((Test-Throws { Set-AVDTuneUpdateBlock -Machine $m -Root $tmp -Mode On }) -and $m.Log.Count -eq 0) $null
    Test-Check 'maintenance mode without the gate is refused, no record written' ((Test-Throws { Start-AVDTuneMaintenance -Machine $m -Root $tmp }) -and -not (Get-AVDTuneMaintenanceCrash -Root $tmp) -and $m.Log.Count -eq 0) $null
    $dry = Set-AVDTuneUpdateBlock -Machine $m -Root $tmp -Mode On -WhatIf
    Test-Check 'dry run shows what would change and writes nothing (no run, no state)' ($dry.WhatIf -and @($dry.Results | Where-Object Status -eq 'WhatIf').Count -eq 10 -and $m.Log.Count -eq 0 -and @(Get-AVDTuneRun -Root $tmp).Count -eq 0 -and $null -eq (Get-AVDTuneState $tmp).UpdateBlock) $null

    # ---------------------------------------------------------------- On
    Open-AVDTuneWriteGate -SnapshotId 'snap-check' -ConfirmedBy 'Check Runner'
    $on = Set-AVDTuneUpdateBlock -Machine $m -Root $tmp -Mode On -User 'admin1' -SnapshotId 'snap-check'
    Test-Check 'On: 10 settings changed, status On, state On' ($on.Changed -eq 10 -and $on.Failed -eq 0 -and $on.State -eq 'On' -and (Get-AVDTuneState $tmp).UpdateBlock -eq 'On') "$($on.Changed) $($on.State)"
    Test-Check 'Windows values in the policy keys' ((& $m.RegGet $wu 'SetDisableUXWUAccess') -eq 1 -and (& $m.RegGet "$wu\AU" 'NoAutoUpdate') -eq 1 -and (& $m.RegGet "$wu\AU" 'NoAutoRebootWithLoggedOnUsers') -eq 1) $null
    Test-Check 'Office, Edge, Teams, Store values' ((& $m.RegGet 'HKLM:\SOFTWARE\Policies\Microsoft\office\16.0\common\officeupdate' 'enableautomaticupdates') -eq 0 -and (& $m.RegGet 'HKLM:\SOFTWARE\Policies\Microsoft\office\16.0\common\officeupdate' 'hideenabledisableupdates') -eq 1 -and (& $m.RegGet 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate' 'UpdateDefault') -eq 0 -and (& $m.RegGet 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate' 'AutoUpdateCheckPeriodMinutes') -eq 0 -and (& $m.RegGet 'HKLM:\SOFTWARE\Microsoft\Teams' 'disableAutoUpdate') -eq 1 -and (& $m.RegGet 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore' 'AutoDownload') -eq 2) $null
    $t1 = & $m.TaskGet '\' 'MicrosoftEdgeUpdateTaskMachineCore{11111111-2222-3333-4444-555555555555}'
    $t2 = & $m.TaskGet '\' 'SomethingElse'
    Test-Check 'Edge update tasks (found by name pattern) are disabled, other tasks stay' (-not $t1.Enabled -and $t2.Enabled) $null
    Test-Check 'no Windows service was changed (WaaSMedic would revert it)' (-not (@($m.Log | Where-Object { $_ -like 'Service*' }).Count)) (($m.Log | Where-Object { $_ -like 'Service*' }) -join ';')
    $cl = @(Get-AVDTuneChangeLog -Root $tmp | Where-Object { $_.Category -eq 'Update block' })
    Test-Check 'change log: one entry for the switch (category Update block)' ($cl.Count -eq 1 -and $cl[0].Text -like '*switched on*10 setting*' -and $cl[0].SnapshotId -eq 'snap-check') ($cl | ConvertTo-Json -Compress)
    $logCount = $m.Log.Count
    $again = Set-AVDTuneUpdateBlock -Machine $m -Root $tmp -Mode On -User 'admin1'
    Test-Check 'On is idempotent: nothing changed, nothing written, no new change log entry' ($again.Changed -eq 0 -and $m.Log.Count -eq $logCount -and @(Get-AVDTuneChangeLog -Root $tmp | Where-Object Category -eq 'Update block').Count -eq 1) $null

    # ---------------------------------------------------------------- health, drift from outside
    $health = { param($mach) $s = Get-AVDTuneUpdateBlockStatus $mach; $h = @{}; foreach ($x in (Get-AVDTuneHealth $mach (Get-AVDTuneState $tmp) $s)) { $h[$x.Id] = $x }; $h.updateblock }
    $h1 = & $health $m
    Test-Check 'health: block on is ok and says how many settings' ($h1.Status -eq 'ok' -and $h1.Detail -like 'On: 10 of 10*') $h1.Detail
    & $m.RegRemove "$wu\AU" 'NoAutoUpdate'
    & $m.TaskSetEnabled '\' 'MicrosoftEdgeUpdateTaskMachineUA{66666666-7777-8888-9999-000000000000}' $true
    $st2 = Get-AVDTuneUpdateBlockStatus $m
    $h2 = & $health $m
    Test-Check 'reset from outside: status Partial, health is bad ("changed from outside") with the groups' ($st2.State -eq 'Partial' -and $st2.Compliant -eq 8 -and $h2.Status -eq 'bad' -and $h2.Detail -like 'Changed from outside*Windows*Edge*') $h2.Detail
    $fix = Set-AVDTuneUpdateBlock -Machine $m -Root $tmp -Mode On -User 'admin1'
    Test-Check 'switching on again puts back exactly the two settings' ($fix.Changed -eq 2 -and $fix.State -eq 'On' -and (& $health $m).Status -eq 'ok') $fix.Changed

    # ---------------------------------------------------------------- findings
    $m2 = New-Master -Extra @{ Services = @(@{ Name = 'wuauserv'; StartType = 'Disabled'; Status = 'Stopped' }); Registry = @{ 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration|UpdatesEnabled' = 'TRUE' } }
    $f = (Get-AVDTuneUpdateBlockStatus $m2).Findings
    Test-Check 'findings: a disabled Windows Update service and Office Updates Enabled TRUE are reported' ($f.Count -eq 2 -and $f[0] -like '*wuauserv*disabled*WaaSMedic*' -and $f[1] -like '*Updates Enabled is TRUE*') ($f -join ' | ')
    Test-Check 'no findings on a normal master' (@((Get-AVDTuneUpdateBlockStatus $m).Findings).Count -eq 0) $null

    # ---------------------------------------------------------------- products that are installed
    $m3 = New-Master -Extra @{ Keys = @('HKLM:\SOFTWARE\WOW6432Node\Google\Update'); Services = @(@{ Name = 'AdobeARMservice'; StartType = 'Automatic'; Status = 'Running' }, @{ Name = 'wuauserv'; StartType = 'Manual' }); Tasks = @(@{ Path = '\'; Name = 'GoogleUpdateTaskMachineCore{aaaaaaaa}'; Enabled = $true }) }
    $on3 = Set-AVDTuneUpdateBlock -Machine $m3 -Root $tmp -Mode On -User 'admin1'
    $svc = & $m3.ServiceGet 'AdobeARMservice'
    Test-Check 'Chrome and Adobe installed: both are part of the block (15 settings)' ($on3.State -eq 'On' -and (Get-AVDTuneUpdateBlockStatus $m3).Applicable -eq 15) "$($on3.State) $((Get-AVDTuneUpdateBlockStatus $m3).Applicable)"
    Test-Check 'Google and Adobe policy values are set' ((& $m3.RegGet 'HKLM:\SOFTWARE\Policies\Google\Update' 'UpdateDefault') -eq 0 -and (& $m3.RegGet 'HKLM:\SOFTWARE\Policies\Adobe\Adobe Acrobat\DC\FeatureLockDown' 'bUpdater') -eq 0 -and (& $m3.RegGet 'HKLM:\SOFTWARE\Policies\Adobe\Acrobat Reader\DC\FeatureLockDown' 'bUpdater') -eq 0) $null
    $gtask = & $m3.TaskGet '\' 'GoogleUpdateTaskMachineCore{aaaaaaaa}'
    Test-Check 'Adobe service is disabled and stopped, the Google task is disabled' ($svc.StartType -eq 'Disabled' -and $svc.Status -eq 'Stopped' -and -not $gtask.Enabled) "$($svc.StartType) $($svc.Status) $($gtask.Enabled)"
    $off3 = Set-AVDTuneUpdateBlock -Machine $m3 -Root $tmp -Mode Off -User 'admin1'
    $gtask = & $m3.TaskGet '\' 'GoogleUpdateTaskMachineCore{aaaaaaaa}'
    Test-Check 'Off removes the policy values, enables the tasks and sets the Adobe service to Manual' ($off3.State -eq 'Off' -and $null -eq (& $m3.RegGet "$wu\AU" 'NoAutoUpdate') -and $gtask.Enabled -and (& $m3.ServiceGet 'AdobeARMservice').StartType -eq 'Manual' -and (Get-AVDTuneState $tmp).UpdateBlock -eq 'Off') "$($off3.State) $($gtask.Enabled)"

    # ---------------------------------------------------------------- maintenance mode
    $seen = @{}
    $r = Invoke-AVDTuneMaintenance -Machine $m -Root $tmp -User 'admin1' -SnapshotId 'snap-check' -Script {
        param($ctx)
        $seen.Status = (Get-AVDTuneUpdateBlockStatus $m).State
        $seen.Record = Get-AVDTuneMaintenanceCrash -Root $tmp
        $seen.Tasks = (& $m.TaskGet '\' 'MicrosoftEdgeUpdateTaskMachineCore{11111111-2222-3333-4444-555555555555}').Enabled
        'script result'
    }
    Test-Check 'inside the maintenance mode the block is lifted and the record is Active with BlockBefore' ($seen.Status -eq 'Off' -and $seen.Tasks -and $seen.Record.Active -and @($seen.Record.BlockBefore).Count -eq 10 -and $seen.Record.Phase -eq 'lifted') ($seen.Status)
    $stateAfter = Get-AVDTuneState $tmp
    Test-Check 'afterwards the block is back (10 of 10), the record is closed with before and after, the script result is returned' ((Get-AVDTuneUpdateBlockStatus $m).State -eq 'On' -and $stateAfter.Maintenance.Active -eq $false -and $stateAfter.Maintenance.Phase -eq 'restored' -and @($stateAfter.Maintenance.BlockAfter).Count -eq 10 -and $stateAfter.UpdateBlock -eq 'On' -and $r.Output -eq 'script result' -and $r.Restore.Restored) $stateAfter.Maintenance.Phase
    Test-Check 'the change log has the maintenance entry' (@(Get-AVDTuneChangeLog -Root $tmp | Where-Object { $_.Component -eq 'Maintenance mode' -and $_.Text -like '*restored*' }).Count -eq 1) $null

    $thrown = Get-ThrownText { Invoke-AVDTuneMaintenance -Machine $m -Root $tmp -Script { param($c) throw 'update exploded' } }
    Test-Check 'a script that fails: the error comes back, the block is back in the finally block' ($thrown -eq 'update exploded' -and (Get-AVDTuneUpdateBlockStatus $m).State -eq 'On' -and -not (Get-AVDTuneMaintenanceCrash -Root $tmp)) $thrown

    $partial = New-Master
    [void](Set-AVDTuneUpdateBlock -Machine $partial -Root $tmp -Mode On -User 'admin1')
    & $partial.RegRemove 'HKLM:\SOFTWARE\Microsoft\Teams' 'disableAutoUpdate'
    $r2 = Invoke-AVDTuneMaintenance -Machine $partial -Root $tmp -Script { param($c) 1 }
    Test-Check 'only what was on before is restored: a setting that was already off stays off' ($r2.Restore.Count -eq 9 -and $null -eq (& $partial.RegGet 'HKLM:\SOFTWARE\Microsoft\Teams' 'disableAutoUpdate') -and (Get-AVDTuneUpdateBlockStatus $partial).Compliant -eq 9) $r2.Restore.Count

    # a restore that fails: the record stays Active so the next start finds it
    $bad = New-Master
    [void](Set-AVDTuneUpdateBlock -Machine $bad -Root $tmp -Mode On -User 'admin1')
    $msg = Get-ThrownText { Invoke-AVDTuneMaintenance -Machine $bad -Root $tmp -User 'admin1' -Script { param($c) $bad.Store.FailWrites = @('edgeupdate') } }
    $rec = Get-AVDTuneMaintenanceCrash -Root $tmp
    Test-Check 'a restore that fails: error text, record stays Active (restore-failed) with the settings that are not back' ($msg -like '*not fully back*' -and $rec.Phase -eq 'restore-failed' -and $rec.Result -like '*updateblock.edge-default*') "$msg | $($rec.Phase)"
    $bad.Store.FailWrites = @()
    Test-Check 'while that record is Active a new maintenance mode is refused' ((Get-ThrownText { Start-AVDTuneMaintenance -Machine $bad -Root $tmp }) -like '*did not end properly*') $null
    $fixed = Repair-AVDTuneMaintenanceCrash -Machine $bad -Root $tmp -User 'admin1'
    Test-Check 'repair after the cause is gone: block On again, record closed' ($fixed.Repaired -and $fixed.State -eq 'On' -and -not (Get-AVDTuneMaintenanceCrash -Root $tmp)) $fixed.Message

    # an error after the block is lifted but before the try/finally of Invoke-AVDTuneMaintenance (the state write after lifting fails):
    # the block is put back at once, the script never runs
    $gap = New-Master
    [void](Set-AVDTuneUpdateBlock -Machine $gap -Root $tmp -Mode On -User 'admin1')
    $ubMod = Get-Module AVDTune.UpdateBlock
    # a stand-in for Set-AVDTuneState inside the module (it passes through once the switch is off again)
    & $ubMod { $script:CheckFailLiftedWrite = $true; function script:Set-AVDTuneState { param([string]$Root, [hashtable]$Values) if ($script:CheckFailLiftedWrite -and $Values.ContainsKey('Maintenance') -and $Values['Maintenance'] -and $Values['Maintenance'].Phase -eq 'lifted') { throw 'disk full' }; AVDTune\Set-AVDTuneState -Root $Root -Values $Values } }
    $ran = $false
    try { $gapMsg = Get-ThrownText { Invoke-AVDTuneMaintenance -Machine $gap -Root $tmp -User 'admin1' -Script { param($c) $script:ran = $true } } }
    finally { & $ubMod { $script:CheckFailLiftedWrite = $false } }
    $gapState = Get-AVDTuneState $tmp
    Test-Check 'an error right after lifting: the block is back at once, record closed (start-failed), the script did not run' ($gapMsg -like '*did not start: disk full*put back*' -and (Get-AVDTuneUpdateBlockStatus $gap).State -eq 'On' -and -not (Get-AVDTuneMaintenanceCrash -Root $tmp) -and $gapState.Maintenance.Phase -eq 'start-failed' -and $gapState.UpdateBlock -eq 'On' -and -not $ran) "$gapMsg | $($gapState.Maintenance.Phase) | $((Get-AVDTuneUpdateBlockStatus $gap).State)"

    # ---------------------------------------------------------------- crash in the middle (process gone: no finally ran)
    $c = New-Master
    [void](Set-AVDTuneUpdateBlock -Machine $c -Root $tmp -Mode On -User 'admin1')
    $ctx = Start-AVDTuneMaintenance -Machine $c -Root $tmp -User 'admin1' -SnapshotId 'snap-check'
    # ... AVDTune is killed here: no Stop-AVDTuneMaintenance ...
    Close-AVDTuneWriteGate   # a new start of AVDTune starts closed
    $crash = Get-AVDTuneMaintenanceCrash -Root $tmp
    Test-Check 'next start: the interrupted maintenance mode is found (user, time, what was on)' ($crash -and $crash.Active -and $crash.User -eq 'admin1' -and @($crash.BlockBefore).Count -eq 10 -and (Get-AVDTuneUpdateBlockStatus $c).State -eq 'Off') $null
    $hc = @{}; foreach ($x in (Get-AVDTuneHealth $c (Get-AVDTuneState $tmp) (Get-AVDTuneUpdateBlockStatus $c))) { $hc[$x.Id] = $x }
    Test-Check 'health says maintenance mode was interrupted (bad)' ($hc.updateblock.Status -eq 'bad' -and $hc.updateblock.Detail -like '*interrupted*') $hc.updateblock.Detail
    Test-Check 'repair needs the open gate; nothing changes before' ((Test-Throws { Repair-AVDTuneMaintenanceCrash -Machine $c -Root $tmp }) -and (Get-AVDTuneUpdateBlockStatus $c).State -eq 'Off' -and (Get-AVDTuneMaintenanceCrash -Root $tmp)) $null
    Open-AVDTuneWriteGate -SnapshotId 'snap-check2' -ConfirmedBy 'Check Runner'
    $rep = Repair-AVDTuneMaintenanceCrash -Machine $c -Root $tmp -User 'admin1'
    $entry = @(Get-AVDTuneChangeLog -Root $tmp | Where-Object { $_.Component -eq 'Maintenance mode' -and $_.Text -like "*$($crash.Started)*" })
    Test-Check 'repair: block back (10 of 10), record closed (repaired), change log entry with the hint' ($rep.Repaired -and $rep.Count -eq 10 -and (Get-AVDTuneUpdateBlockStatus $c).State -eq 'On' -and -not (Get-AVDTuneMaintenanceCrash -Root $tmp) -and (Get-AVDTuneState $tmp).Maintenance.Phase -eq 'repaired' -and $entry.Count -eq 1) $rep.Message
    Test-Check 'repair without an interrupted record does nothing' (-not (Repair-AVDTuneMaintenanceCrash -Machine $c -Root $tmp).Repaired) $null

    # a crash while the block was off before: nothing to put back, record is just closed
    $o = New-Master
    $ctx2 = Start-AVDTuneMaintenance -Machine $o -Root $tmp -User 'admin1'
    $rep2 = Repair-AVDTuneMaintenanceCrash -Machine $o -Root $tmp -User 'admin1'
    Test-Check 'a crash when the block was off before: nothing is switched on that was not on' ($rep2.Repaired -and $rep2.Count -eq 0 -and (Get-AVDTuneUpdateBlockStatus $o).State -eq 'Off') $rep2.Message

    # ---------------------------------------------------------------- LastChange for the snapshot gate: every way that writes to the master sets it
    $old = '2000-01-01T00:00:00.0000000Z'
    $mark = { [void](Set-AVDTuneState -Root $tmp -Values @{ LastChange = $old }) }
    $moved = { $v = [string](Get-AVDTuneState $tmp).LastChange; $v -and $v -ne $old }
    $lc = New-Master; $lcSeen = [ordered]@{}
    & $mark; [void](Set-AVDTuneUpdateBlock -Machine $lc -Root $tmp -Mode On -User 'admin1'); $lcSeen['block on'] = & $moved
    & $mark; [void](Set-AVDTuneUpdateBlock -Machine $lc -Root $tmp -Mode On -User 'admin1'); $lcSeen['block on again (nothing changed) stamps the end of the attempt: Stop-AVDTuneChange, #27'] = $moved
    & $mark; $lcCtx = Start-AVDTuneMaintenance -Machine $lc -Root $tmp -User 'admin1'; $lcSeen['maintenance lifts'] = & $moved
    & $mark; [void](Stop-AVDTuneMaintenance -Machine $lc -Root $tmp -Context $lcCtx); $lcSeen['maintenance restores'] = & $moved
    [void](Start-AVDTuneMaintenance -Machine $lc -Root $tmp -User 'admin1')   # ... crash ...
    & $mark; [void](Repair-AVDTuneMaintenanceCrash -Machine $lc -Root $tmp -User 'admin1'); $lcSeen['repair after a crash'] = & $moved
    & $mark; [void](Set-AVDTuneUpdateBlock -Machine $lc -Root $tmp -Mode Off -User 'admin1'); $lcSeen['block off'] = & $moved
    $lcBad = @($lcSeen.Keys | Where-Object { -not $lcSeen[$_] })
    Test-Check 'LastChange in state.json is set by block on/off, maintenance lift/restore and the repair; every attempt stamps its end (Stop-AVDTuneChange, #27)' ($lcBad.Count -eq 0 -and (Get-AVDTuneLastChange -Root $tmp) -gt (Get-Date).AddMinutes(-5)) ($lcBad -join ', ')

    # ---------------------------------------------------------------- legacy health (no live status): state only
    [void](Set-AVDTuneState -Root $tmp -Values @{ UpdateBlock = 'On'; Maintenance = $null })
    $hl = @{}; foreach ($x in (Get-AVDTuneHealth (New-Master) (Get-AVDTuneState $tmp))) { $hl[$x.Id] = $x }
    Test-Check 'health without live status falls back to the state' ($hl.updateblock.Status -eq 'ok') $null
    Test-Check 'no file of the check run touched the real state folder' (-not ($tmp -eq (Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'AVDTune'))) $tmp
}
finally {
    Close-AVDTuneWriteGate
    $env:AVDTUNE_ROOT = $null
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
if ($script:failed -gt 0) { throw "$script:failed check(s) failed." }
'Check-UpdateBlock: all checks passed.'
