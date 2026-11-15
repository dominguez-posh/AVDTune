#requires -Version 5.1
<#
.SYNOPSIS
    Checks "Abschliessen" (Modules\AVDTune.Finish.psm1, issues #36 and #9) against the fake machine, the fake finish adapter and temporary folders:
    the gate is evaluated directly before the first write (a change between display and click blocks, red blocks, an unconfirmed yellow blocks, a
    closed write gate blocks, nothing is written when it is closed), the steps, cleanup without following links (also with real folders and a real
    junction), what is in use stays, the tokens are gone after the finish (and the finish stops while a token pattern is in AVDTune's own files),
    a protection that is lifted for the cleanup is put back in finally and, after a real process crash, by the repair at the next start, the end
    state of the update block and the closed version. Nothing touches the registry, services or tasks of this computer.
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'Modules\AVDTune.psm1') -Force
Import-Module (Join-Path $repo 'Modules\AVDTune.Session.psm1') -Force
Import-Module (Join-Path $repo 'Modules\AVDTune.Snapshot.psm1') -Force
Import-Module (Join-Path $repo 'Modules\AVDTune.UpdateBlock.psm1') -Force
Import-Module (Join-Path $repo 'Modules\AVDTune.Readiness.psm1') -Force
Import-Module (Join-Path $repo 'Modules\AVDTune.Finish.psm1') -Force
. (Join-Path $PSScriptRoot 'Fakes\FakeMachine.ps1')
. (Join-Path $PSScriptRoot 'Fakes\FakeFinish.ps1')

$script:failed = 0
function Test-Check([string]$Name, [bool]$Ok, $Detail) { if ($Ok) { "PASS $Name" } else { $script:failed++; "FAIL $Name" + $(if ($null -ne $Detail) { "  -> $Detail" }) } }
function Test-Throws([scriptblock]$Block) { try { & $Block | Out-Null; $false } catch { $true } }
function Get-ThrownText([scriptblock]$Block) { try { & $Block | Out-Null; $null } catch { $_.Exception.Message } }

$base = Join-Path ([IO.Path]::GetTempPath()) ('avdtune-finish-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $base | Out-Null
$script:n = 0

function New-Root {
    # A state root with a started image version and an open write gate
    $script:n++
    $root = Join-Path $base "root$($script:n)"
    [void](Initialize-AVDTuneState -Root $root)
    [void](Start-AVDTuneImageVersion -Root $root -Date (Get-Date).AddDays(-1) -User 'admin1')
    Open-AVDTuneWriteGate -SnapshotId 'snap-check' -ConfirmedBy 'Check Runner'
    $root
}
function Save-Healthcheck([string]$Root, [string[]]$Red = @(), [string[]]$Open = @()) {
    $overall = if ($Red.Count -gt 0) { 'red' } elseif ($Open.Count -gt 0) { 'yellow' } else { 'green' }
    $res = [pscustomobject]@{
        At = (Get-Date).ToString('o'); Stand = 'check'; Overall = $overall; Counts = [pscustomobject]@{ Green = 1; Yellow = $Open.Count; Red = $Red.Count; Unknown = 0; Info = 0 }
        Rows = @(); OpenIds = @($Open); RedIds = @($Red); Families = @()
    }
    Save-AVDTuneReadinessRun -Root $Root -Result $res -Kind Healthcheck -User 'admin1'
}
function New-Master {
    New-AVDTuneFakeMachine -Seed @{ Services = @(@{ Name = 'wuauserv'; StartType = 'Manual'; Status = 'Running' }, @{ Name = 'bits'; StartType = 'Manual'; Status = 'Running' }) }
}
function New-TokenSession([string]$TempRoot) {
    $s = New-AVDTuneSession -Auth ([pscustomobject]@{}) -TempRoot $TempRoot
    $s.Tokens['Arm'] = @{ Access = (ConvertTo-AVDTuneSecure 'fake-access'); ExpiresOn = (Get-Date); Scopes = @(); Audience = 'x' }
    $s.Refresh = ConvertTo-AVDTuneSecure 'fake-refresh'; $s.Connected = $true
    [void](New-Item -ItemType Directory -Path (Join-Path $TempRoot ('PackTuneSignIn-' + [guid]::NewGuid().ToString('N'))))
    $s
}
function Get-Fake([string]$Root) {
    @{
        Items = @{
            'temp' = @('setup.log', 'old.tmp', @{ Name = 'inuse.dat'; Locked = $true }, @{ Name = 'lnk'; Link = $true; Target = 'outside' })
            'wer-queue' = @('Report1'); 'wu-download' = @('KB1.cab', 'KB2.cab')
        }
        LinkTargets = @{ outside = @('precious1.txt', 'precious2.txt') }
        Present = @((Join-Path (Join-Path $Root 'tools') 'diskspd'))
    }
}

try {
    # ---------------------------------------------------------------- the gate, evaluated directly before the first write
    $root = New-Root
    $m = New-Master; $f = New-AVDTuneFakeFinish -Seed (Get-Fake $root)
    $g = Test-AVDTuneFinishGate -Root $root
    Test-Check 'gate: no healthcheck yet blocks' (-not $g.Allowed -and ($g.Reasons -join ' ') -like '*No healthcheck yet*') ($g.Reasons -join '|')
    Test-Check 'gate closed: Invoke throws and writes nothing (no journal, no machine or adapter call)' ((Test-Throws { Invoke-AVDTuneFinish -Machine $m -Fin $f -Root $root -User 'admin1' }) -and $null -eq (Get-AVDTuneFinishRecord $root) -and $m.Log.Count -eq 0 -and $f.Log.Count -eq 0) $null

    [void](Save-Healthcheck -Root $root -Red @('hy.avd-agent'))
    $g = Test-AVDTuneFinishGate -Root $root
    $text = Get-ThrownText { Invoke-AVDTuneFinish -Machine $m -Fin $f -Root $root -User 'admin1' }
    Test-Check 'gate: red blocks, names the item, nothing written' (-not $g.Allowed -and ($g.Reasons -join ' ') -like '*1 red item(s)*hy.avd-agent*' -and $text -like '*not allowed*red*' -and $null -eq (Get-AVDTuneFinishRecord $root) -and $m.Log.Count -eq 0 -and $f.Log.Count -eq 0) ($g.Reasons -join '|')

    [void](Save-Healthcheck -Root $root -Open @('hy.reboot'))
    $g = Test-AVDTuneFinishGate -Root $root
    $text = Get-ThrownText { Invoke-AVDTuneFinish -Machine $m -Fin $f -Root $root -User 'admin1' }
    Test-Check 'gate: an unconfirmed yellow blocks, nothing written' (-not $g.Allowed -and ($g.Reasons -join ' ') -like '*not confirmed by name*hy.reboot*' -and $text -like '*not allowed*' -and $null -eq (Get-AVDTuneFinishRecord $root) -and $m.Log.Count -eq 0 -and $f.Log.Count -eq 0) ($g.Reasons -join '|')
    [void](Confirm-AVDTuneReadinessAcknowledgement -Root $root -Typed 'hy.reboot' -User 'admin1')
    $g = Test-AVDTuneFinishGate -Root $root
    Test-Check 'gate: a confirmed yellow opens it' ($g.Allowed -and $g.Reasons.Count -eq 0) ($g.Reasons -join '|')
    Test-Check 'gate: no benchmark is only a note, not a block' ($g.Allowed -and ($g.Notes -join ' ') -like '*No benchmark*') ($g.Notes -join '|')

    # a change between the display (the gate said Allowed) and the click
    Start-Sleep -Milliseconds 50
    [void](Add-AVDTuneChangeLogEntry -Root $root -Version (Get-AVDTuneState $root).ImageVersion -Category 'Software' -ChangeType Changed -Text 'Contoso Tool installed' -User 'admin1' -Source Step)
    $text = Get-ThrownText { Invoke-AVDTuneFinish -Machine $m -Fin $f -Root $root -User 'admin1' }
    Test-Check 'a change between display and click blocks: Invoke evaluates the gate again, nothing is written' ($text -like '*not allowed*changed after the check*' -and $null -eq (Get-AVDTuneFinishRecord $root) -and $m.Log.Count -eq 0 -and $f.Log.Count -eq 0 -and -not (Get-AVDTuneState $root).Sealed) $text
    [void](Save-Healthcheck -Root $root)
    Close-AVDTuneWriteGate
    $g = Test-AVDTuneFinishGate -Root $root
    Test-Check 'gate: a closed write gate (snapshot not confirmed) blocks' (-not $g.Allowed -and ($g.Reasons -join ' ') -like '*snapshot gate is not confirmed*' -and (Test-Throws { Invoke-AVDTuneFinish -Machine $m -Fin $f -Root $root }) -and $f.Log.Count -eq 0) ($g.Reasons -join '|')
    Open-AVDTuneWriteGate -SnapshotId 'snap-check' -ConfirmedBy 'Check Runner'
    # the run record behind the healthcheck must be there and say the same
    $rec = Get-AVDTuneReadinessRecord -Root $root
    Remove-Item -LiteralPath (Join-Path (Join-Path $root 'runs') "$($rec.RunId).json") -Force
    $g = Test-AVDTuneFinishGate -Root $root
    Test-Check 'gate: a healthcheck whose run record is missing blocks' (-not $g.Allowed -and ($g.Reasons -join ' ') -like '*run record of the healthcheck is missing*') ($g.Reasons -join '|')
    [void](Save-Healthcheck -Root $root)
    Test-Check 'gate: a fresh green healthcheck opens it again' ((Test-AVDTuneFinishGate -Root $root).Allowed) ((Test-AVDTuneFinishGate -Root $root).Reasons -join '|')
    $old = New-Root
    [void](Save-Healthcheck -Root $old)
    $s = Get-AVDTuneState $old
    $s.Versions[0].Started = (Get-Date).AddHours(1).ToString('o'); Write-AVDTuneFile (Join-Path $old 'state.json') ($s | ConvertTo-Json -Depth 6)
    Test-Check 'gate: a healthcheck from before the version was started blocks' ((Test-AVDTuneFinishGate -Root $old).Reasons -join ' ' -like '*from before image version*') ((Test-AVDTuneFinishGate -Root $old).Reasons -join '|')

    # ---------------------------------------------------------------- dry run
    $dry = Invoke-AVDTuneFinish -Machine $m -Fin $f -Root $root -WhatIf
    Test-Check 'dry run lists the steps and writes nothing' ($dry.WhatIf -and @($dry.Results).Count -eq 7 -and @($dry.Results | Where-Object { $_.Status -notin 'WhatIf', 'Unchanged' }).Count -eq 0 -and $m.Log.Count -eq 0 -and -not ($f.Log -like 'ClearFolder*') -and -not ($f.Log -like 'RemoveFolder*') -and $null -eq (Get-AVDTuneFinishRecord $root)) ((@($dry.Results | ForEach-Object Status)) -join ',')

    # ---------------------------------------------------------------- the finish
    $signTemp = Join-Path $base 'signtemp'; New-Item -ItemType Directory -Path $signTemp | Out-Null
    $session = New-TokenSession $signTemp
    Test-Check 'precondition: the session holds a token and a sign-in profile' (-not (Test-AVDTuneSessionClear -Session $session)) $null
    $progress = New-Object System.Collections.ArrayList
    $r = Invoke-AVDTuneFinish -Machine $m -Fin $f -Root $root -User 'admin1' -SnapshotId 'snap-check' -Session $session -Progress { param($t, $p) [void]$progress.Add("$p $t") }
    Test-Check 'finish: Finished, seven steps in order, none failed' ($r.Status -eq 'Finished' -and (@($r.Results | ForEach-Object Id) -join ',') -eq 'finish.temp,finish.wer,finish.wu-cache,finish.diskspd,finish.block,finish.tokens,finish.version' -and @($r.Results | Where-Object Status -eq 'Failed').Count -eq 0) ((@($r.Results | ForEach-Object { "$($_.Id)=$($_.Status):$($_.Message)" })) -join '; ')
    Test-Check 'finish: every step ran through the step engine (Section Seal, Mode Apply)' (@($r.Results | Where-Object { $_.Section -ne 'Seal' -or $_.Mode -ne 'Apply' }).Count -eq 0) $null
    $temp = $f.Store.Items['C:\Windows\Temp']
    Test-Check 'cleanup: the temp folder is empty except the file in use, which stays' ($temp.Count -eq 1 -and $temp[0].Name -eq 'inuse.dat') (@($temp | ForEach-Object Name) -join ',')
    Test-Check 'cleanup: a link in the temp folder is removed itself, its target is untouched' (($f.Log -contains 'LinkRemoved lnk') -and @($f.Store.LinkTargets['outside']).Count -eq 2) (@($f.Store.LinkTargets['outside']) -join ',')
    Test-Check 'cleanup: error reports, update cache and the diskspd cache are gone' ($f.Store.Items['C:\ProgramData\Microsoft\Windows\WER\ReportQueue'].Count -eq 0 -and $f.Store.Items['C:\Windows\SoftwareDistribution\Download'].Count -eq 0 -and -not (& $f.PathExists (Join-Path (Join-Path $root 'tools') 'diskspd'))) $null
    $stop = $m.Log.IndexOf('ServiceStop wuauserv'); $start = $m.Log.IndexOf('ServiceStart wuauserv')
    Test-Check 'update cache: Windows Update and BITS were stopped for it and run again afterwards' ($stop -ge 0 -and $start -gt $stop -and $m.Log.IndexOf('ServiceStart bits') -gt $m.Log.IndexOf('ServiceStop bits') -and (& $m.ServiceGet 'wuauserv').Status -eq 'Running' -and (& $m.ServiceGet 'bits').Status -eq 'Running') ($m.Log -join '; ')
    $st = Get-AVDTuneUpdateBlockStatus $m
    Test-Check 'end state: update block on, no maintenance mode' ($st.State -eq 'On' -and -not (Get-AVDTuneMaintenanceCrash -Root $root)) $st.State
    Test-Check 'tokens: after the finish no token, no refresh token and no sign-in profile is left' (Test-AVDTuneSessionClear -Session $session) $null
    Test-Check 'tokens: not in any file of the state folder (real scan of the real records)' (@(Find-AVDTuneTokenFiles -Root $root).Count -eq 0) (@(Find-AVDTuneTokenFiles -Root $root) -join ',')
    $state = Get-AVDTuneState $root
    Test-Check 'version closed: Sealed, Finished and FinishedBy in state.json' ($state.Sealed -eq $true -and $state.Versions[0].Finished -and $state.Versions[0].FinishedBy -eq 'admin1') ($state | ConvertTo-Json -Compress)
    $journal = Get-AVDTuneFinishRecord $root
    Test-Check 'journal: closed (done), seven steps recorded, nothing lifted is open' (-not $journal.Active -and $journal.Phase -eq 'done' -and @($journal.Steps).Count -eq 7 -and @(@($journal.Lifted) | Where-Object { -not $_.Restored }).Count -eq 0) ($journal | ConvertTo-Json -Compress)
    $cl = @(Get-AVDTuneChangeLog -Root $root | Where-Object Category -eq 'Finish')
    Test-Check 'change log: one entry per changed step and the summary; run record "Finish"; LastChange set' ($cl.Count -ge 7 -and (@($cl | Where-Object Component -eq 'Finish')[0].Text -like '*is finished*imaging tool*') -and @(Get-AVDTuneRun -Root $root | Where-Object Plan -eq 'Finish').Count -eq 1 -and (Get-AVDTuneState $root).LastChange) ($cl.Count)
    Test-Check 'progress: reported per step' ($progress.Count -ge 7 -and $progress[0] -like '0 *') ($progress -join '|')
    $g = Test-AVDTuneFinishGate -Root $root
    Test-Check 'gate after the finish: the version is finished, a second finish is refused' (-not $g.Allowed -and ($g.Reasons -join ' ') -like '*already finished*' -and (Test-Throws { Invoke-AVDTuneFinish -Machine $m -Fin $f -Root $root })) ($g.Reasons -join '|')
    $again = Invoke-AVDTuneStep -Step (Get-AVDTuneFinishSteps -Machine $m -Fin $f -Root $root -Session $session -User 'admin1' -SnapshotId 'x')[5].Step -Machine $m -Mode Test
    Test-Check 'the token step tests compliant afterwards' ($again.Status -eq 'Compliant') $again.Status

    # ---------------------------------------------------------------- tokens: the finish stops while a token pattern is in AVDTune files and keeps the sign-in
    $root2 = New-Root; [void](Save-Healthcheck -Root $root2)
    $m2 = New-Master; $f2 = New-AVDTuneFakeFinish -Seed (@{ TokenFiles = @('config\leftover.json'); Present = @() })
    $sess2 = New-TokenSession $signTemp
    $r2 = Invoke-AVDTuneFinish -Machine $m2 -Fin $f2 -Root $root2 -User 'admin1' -Session $sess2
    $tokStep = @($r2.Results | Where-Object Id -eq 'finish.tokens')[0]
    Test-Check 'a token pattern in an own file: the token step fails with the file name (no content), the finish is not finished, the sign-in is kept' ($r2.Status -eq 'Failed' -and $tokStep.Status -eq 'Failed' -and $tokStep.Message -like '*content not shown*config\leftover.json*' -and -not (Get-AVDTuneState $root2).Sealed -and $sess2.Connected -and @($r2.Results | Where-Object Id -eq 'finish.version').Count -eq 0) ($r2.Message)
    $j2 = Get-AVDTuneFinishRecord $root2
    Test-Check 'a failed finish: journal closed as failed, the failure is in the change log' (-not $j2.Active -and $j2.Phase -eq 'failed' -and @(Get-AVDTuneChangeLog -Root $root2 | Where-Object { $_.Category -eq 'Finish' -and $_.Text -like '*FAILED*' }).Count -ge 1) ($j2 | ConvertTo-Json -Compress)

    # ---------------------------------------------------------------- the real helpers on real folders
    $real = Join-Path $base 'real'; New-Item -ItemType Directory -Path $real | Out-Null
    $clear = Join-Path $real 'clear'; $target = Join-Path $real 'target'
    New-Item -ItemType Directory -Path $clear, $target, (Join-Path $clear 'sub') | Out-Null
    Set-Content -LiteralPath (Join-Path $target 'keep.txt') -Value 'keep'
    Set-Content -LiteralPath (Join-Path $clear 'file.txt') -Value 'x'; Set-Content -LiteralPath (Join-Path $clear 'sub\y.txt') -Value 'y'
    $junction = Join-Path $clear 'lnk'
    cmd.exe /c mklink /J "$junction" "$target" | Out-Null
    $c = Clear-AVDTuneFolderContents -Folder $clear
    Test-Check 'real cleanup: contents and a junction removed, the junction target is untouched, the folder stays' ($c.Removed -eq 3 -and $c.Left -eq 0 -and @(Get-ChildItem -LiteralPath $clear -Force).Count -eq 0 -and (Test-Path -LiteralPath (Join-Path $target 'keep.txt'))) "$($c.Removed)/$($c.Left)"
    $jl = Join-Path $real 'jl'; cmd.exe /c mklink /J "$jl" "$target" | Out-Null
    Test-Check 'real cleanup: a folder that is a link is refused, nothing deleted' ((Test-Throws { Clear-AVDTuneFolderContents -Folder $jl }) -and (Test-Path -LiteralPath (Join-Path $target 'keep.txt'))) $null
    New-Item -ItemType Directory -Path (Join-Path $target 'inner') | Out-Null; Set-Content -LiteralPath (Join-Path $target 'inner\z.txt') -Value 'z'
    Test-Check 'real cleanup: a folder below a link is refused too (the parent chain is checked)' ((Test-Throws { Clear-AVDTuneFolderContents -Folder (Join-Path $jl 'inner') }) -and (Test-Path -LiteralPath (Join-Path $target 'inner\z.txt'))) $null
    Test-Check 'real cleanup: a drive root is never cleared' (Test-Throws { Clear-AVDTuneFolderContents -Folder ([IO.Path]::GetPathRoot($base)) }) $null
    $locked = Join-Path $real 'locked'; New-Item -ItemType Directory -Path $locked | Out-Null
    Set-Content -LiteralPath (Join-Path $locked 'free.txt') -Value 'a'; Set-Content -LiteralPath (Join-Path $locked 'busy.txt') -Value 'b'
    $fs = [IO.File]::Open((Join-Path $locked 'busy.txt'), 'Open', 'Read', 'None')
    try { $lc = Clear-AVDTuneFolderContents -Folder $locked } finally { $fs.Dispose() }
    Test-Check 'real cleanup: a file in use stays and is counted, the others go' ($lc.Removed -eq 1 -and $lc.Left -eq 1 -and (Test-Path -LiteralPath (Join-Path $locked 'busy.txt')) -and -not (Test-Path -LiteralPath (Join-Path $locked 'free.txt'))) "$($lc.Removed)/$($lc.Left)"
    $scan = Join-Path $real 'scan'; $outside = Join-Path $real 'outside'
    New-Item -ItemType Directory -Path (Join-Path $scan 'config'), $outside | Out-Null
    Set-Content -LiteralPath (Join-Path $scan 'config\clean.json') -Value '{ "Schema": 1, "Text": "nothing here" }'
    Set-Content -LiteralPath (Join-Path $scan 'config\jwt.json') -Value '{ "x": "eyJhbGciOiJub25lIn0.eyJzdWIiOiJ0ZXN0In0.c2lnbmF0dXJlMTIz" }'
    Set-Content -LiteralPath (Join-Path $scan 'refresh.log') -Value '{"refresh_token": "0.AAAAverylongfakevalue1234"}'
    Set-Content -LiteralPath (Join-Path $outside 'jwt.json') -Value 'eyJhbGciOiJub25lIn0.eyJzdWIiOiJ0ZXN0In0.c2lnbmF0dXJlMTIz'
    cmd.exe /c mklink /J "$(Join-Path $scan 'linkout')" "$outside" | Out-Null
    $hits = @(Find-AVDTuneTokenFiles -Root $scan | Sort-Object)
    Test-Check 'real token scan: finds a JWT and a refresh token by name, never shows content, does not follow a junction, no false hit on a clean file' (($hits -join ',') -eq 'config\jwt.json,refresh.log') ($hits -join ',')

    # ---------------------------------------------------------------- a protection that is lifted is put back
    # (a) an error in the middle: the finally block restores, the finish is failed and not finished
    $root3 = New-Root; [void](Save-Healthcheck -Root $root3)
    $m3 = New-Master; $f3 = New-AVDTuneFakeFinish -Seed (@{ Items = @{ 'wu-download' = @('a.cab') }; FailClear = @('wu-download') })
    $r3 = Invoke-AVDTuneFinish -Machine $m3 -Fin $f3 -Root $root3 -User 'admin1'
    $wu3 = @($r3.Results | Where-Object Id -eq 'finish.wu-cache')[0]
    Test-Check 'error while lifted: the cache step fails, Windows Update and BITS run again (finally)' ($r3.Status -eq 'Failed' -and $wu3.Status -eq 'Failed' -and (& $m3.ServiceGet 'wuauserv').Status -eq 'Running' -and (& $m3.ServiceGet 'bits').Status -eq 'Running' -and $m3.Log -contains 'ServiceStop wuauserv' -and $m3.Log -contains 'ServiceStart wuauserv') ($m3.Log -join '; ')
    $j3 = Get-AVDTuneFinishRecord $root3
    Test-Check 'error while lifted: the journal says restored and is closed; the later steps did not run' (-not $j3.Active -and @(@($j3.Lifted) | Where-Object { -not $_.Restored }).Count -eq 0 -and @($r3.Results | Where-Object Id -in 'finish.block', 'finish.tokens', 'finish.version').Count -eq 0 -and -not (Get-AVDTuneState $root3).Sealed) ($j3 | ConvertTo-Json -Compress)
    # (b) the restore itself fails: the record stays Active and the next start finds it
    $root4 = New-Root; [void](Save-Healthcheck -Root $root4)
    $m4 = New-Master; $m4.ServiceStart = { param($Name) throw 'fake: the service does not start' }
    $f4 = New-AVDTuneFakeFinish -Seed (@{ Items = @{ 'wu-download' = @('a.cab') } })
    $r4 = Invoke-AVDTuneFinish -Machine $m4 -Fin $f4 -Root $root4 -User 'admin1'
    $crash4 = Get-AVDTuneFinishCrash -Root $root4
    Test-Check 'restore fails: the finish is failed, the record stays Active (restore-failed) and is found as a crash' ($r4.Status -eq 'Failed' -and $crash4 -and $crash4.Phase -eq 'restore-failed' -and (& $m4.ServiceGet 'wuauserv').Status -eq 'Stopped') ($r4.Message)
    $g4 = Test-AVDTuneFinishGate -Root $root4
    Test-Check 'a crashed finish blocks the next finish until it is repaired' (-not $g4.Allowed -and ($g4.Reasons -join ' ') -like '*earlier finish did not end properly*') ($g4.Reasons -join '|')
    $m4b = New-AVDTuneFakeMachine -Seed @{ Services = @(@{ Name = 'wuauserv'; StartType = 'Manual'; Status = 'Stopped' }, @{ Name = 'bits'; StartType = 'Manual'; Status = 'Stopped' }) }
    Close-AVDTuneWriteGate
    Test-Check 'repair needs the open write gate' ((Test-Throws { Repair-AVDTuneFinishCrash -Machine $m4b -Root $root4 -User 'admin1' }) -and $m4b.Log.Count -eq 0) $null
    Open-AVDTuneWriteGate -SnapshotId 'snap-check' -ConfirmedBy 'Check Runner'
    $rep = Repair-AVDTuneFinishCrash -Machine $m4b -Root $root4 -User 'admin1'
    Test-Check 'repair: stopped services run again, record closed (repaired), change log entry, the finish can be run again' ($rep.Repaired -and (& $m4b.ServiceGet 'wuauserv').Status -eq 'Running' -and (& $m4b.ServiceGet 'bits').Status -eq 'Running' -and -not (Get-AVDTuneFinishCrash -Root $root4) -and (Get-AVDTuneFinishRecord $root4).Phase -eq 'repaired' -and @(Get-AVDTuneChangeLog -Root $root4 | Where-Object { $_.Category -eq 'Finish' -and $_.Text -like '*did not end properly*' }).Count -eq 1) $rep.Message

    # (c) a real process crash in the middle (the process ends while the services are stopped: no finally block runs)
    $root5 = New-Root; [void](Save-Healthcheck -Root $root5)
    $child = Join-Path $base 'crash-child.ps1'
    $childText = @'
param([string]$Repo, [string]$Root)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $Repo 'Modules\AVDTune.psm1') -Force
foreach ($mod in 'Session', 'Snapshot', 'UpdateBlock', 'Readiness', 'Finish') { Import-Module (Join-Path $Repo "Modules\AVDTune.$mod.psm1") -Force }
. (Join-Path $Repo 'Tests\Fakes\FakeMachine.ps1'); . (Join-Path $Repo 'Tests\Fakes\FakeFinish.ps1')
Open-AVDTuneWriteGate -SnapshotId 'snap-check' -ConfirmedBy 'Check Runner'
$m = New-AVDTuneFakeMachine -Seed @{ Services = @(@{ Name = 'wuauserv'; StartType = 'Manual'; Status = 'Running' }, @{ Name = 'bits'; StartType = 'Manual'; Status = 'Running' }) }
$f = New-AVDTuneFakeFinish -Seed @{ Items = @{ 'wu-download' = @('a.cab') } }
$f.ClearFolder = { param($Path) if ($Path -like '*SoftwareDistribution*') { [Environment]::Exit(99) } else { [pscustomobject]@{ Removed = 0; Left = 0 } } }
Invoke-AVDTuneFinish -Machine $m -Fin $f -Root $Root -User 'admin1'
exit 0
'@
    [IO.File]::WriteAllText($child, $childText)
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $p = Start-Process -FilePath $psExe -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', "`"$child`"", '-Repo', "`"$repo`"", '-Root', "`"$root5`"") -PassThru -Wait -WindowStyle Hidden -RedirectStandardError "$child.err" -RedirectStandardOutput "$child.out"
    $crash5 = Get-AVDTuneFinishCrash -Root $root5
    Test-Check 'process crash while lifted: exit code 99, no finally block ran, the journal is Active with both services listed as lifted and not restored' ($p.ExitCode -eq 99 -and $crash5 -and $crash5.Phase -eq 'lifted' -and @(@($crash5.Lifted) | Where-Object { -not $_.Restored }).Count -eq 2) (($crash5 | ConvertTo-Json -Compress) + ' ' + (Get-Content -LiteralPath "$child.err" -Raw))
    Test-Check 'process crash: LastChange was written before the first step (the snapshot gate counts it)' ((Get-AVDTuneState $root5).LastChange -and @($crash5.Steps).Count -eq 2) (@($crash5.Steps) -join ',')
    $m5 = New-AVDTuneFakeMachine -Seed @{ Services = @(@{ Name = 'wuauserv'; StartType = 'Manual'; Status = 'Stopped' }, @{ Name = 'bits'; StartType = 'Manual'; Status = 'Stopped' }) }
    $rep5 = Repair-AVDTuneFinishCrash -Machine $m5 -Root $root5 -User 'admin1'
    Test-Check 'the repair at the next start puts back what the crashed run had stopped' ($rep5.Repaired -and (& $m5.ServiceGet 'wuauserv').Status -eq 'Running' -and (& $m5.ServiceGet 'bits').Status -eq 'Running' -and -not (Get-AVDTuneFinishCrash -Root $root5) -and -not (Get-AVDTuneState $root5).Sealed) $rep5.Message
    $root6 = New-Root; [void](Save-Healthcheck -Root $root6)
    $m6 = New-AVDTuneFakeMachine -Seed @{ Services = @(@{ Name = 'wuauserv'; StartType = 'Manual'; Status = 'Stopped' }, @{ Name = 'bits'; StartType = 'Manual'; Status = 'Stopped' }) }
    $f6 = New-AVDTuneFakeFinish -Seed (@{ Items = @{ 'wu-download' = @('a.cab') } })
    $r6 = Invoke-AVDTuneFinish -Machine $m6 -Fin $f6 -Root $root6 -User 'admin1'
    Test-Check 'a service that was stopped before is not started by the finish' ($r6.Status -eq 'Finished' -and -not ($m6.Log -like 'ServiceStart*') -and -not ($m6.Log -like 'ServiceStop*')) ($m6.Log -join '; ')

    # ---------------------------------------------------------------- end state of the block with a partly lifted block; maintenance crash blocks
    $root7 = New-Root; [void](Save-Healthcheck -Root $root7)
    $m7 = New-Master
    [void](Set-AVDTuneUpdateBlock -Machine $m7 -Root $root7 -Mode On)
    [void](Save-Healthcheck -Root $root7)
    [void](Set-AVDTuneState -Root $root7 -Values @{ Maintenance = [pscustomobject]@{ Active = $true; Id = 'x'; Phase = 'lifted'; Started = (Get-Date).ToString('o'); User = 'admin1'; BlockBefore = @() } })
    $g7 = Test-AVDTuneFinishGate -Root $root7
    Test-Check 'an interrupted maintenance mode blocks the finish' (-not $g7.Allowed -and ($g7.Reasons -join ' ') -like '*maintenance mode did not end properly*') ($g7.Reasons -join '|')
    [void](Set-AVDTuneState -Root $root7 -Values @{ Maintenance = $null })
    & $m7.RegRemove 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'NoAutoUpdate'
    [void](Save-Healthcheck -Root $root7 -Open @('hy.update-block')); [void](Confirm-AVDTuneReadinessAcknowledgement -Root $root7 -Typed 'hy.update-block' -User 'admin1')
    $f7 = New-AVDTuneFakeFinish
    $r7 = Invoke-AVDTuneFinish -Machine $m7 -Fin $f7 -Root $root7 -User 'admin1'
    Test-Check 'a partly lifted block (confirmed yellow) is brought to On by the finish' ($r7.Status -eq 'Finished' -and (Get-AVDTuneUpdateBlockStatus $m7).State -eq 'On' -and @($r7.Results | Where-Object Id -eq 'finish.block')[0].Status -eq 'Changed') ($r7.Message)

    # ---------------------------------------------------------------- the module never writes a secret
    $src = [IO.File]::ReadAllText((Join-Path $repo 'Modules\AVDTune.Finish.psm1'))
    Test-Check 'security: no start of a program, no environment variable, no Get-Command in the finish module' ($src -notmatch '(?m)^\s*[^#\r\n]*(Start-Process|Invoke-Expression|\$env:|Get-Command|\[Diagnostics\.Process\])') $null
}
finally {
    Close-AVDTuneWriteGate
    if (Test-Path -LiteralPath $base) {
        foreach ($j in Get-ChildItem -LiteralPath $base -Recurse -Force -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }) { try { $j.Delete() } catch { } }
        Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
    }
}
if ($script:failed -gt 0) { throw "$script:failed check(s) failed." }
'Check-Finish: all checks passed.'
