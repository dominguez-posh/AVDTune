#requires -Version 5.1
<#
.SYNOPSIS
    Checks the AVDTune engine (Modules\AVDTune.psm1) against a fake machine and a temporary state folder: state, atomic writes,
    image versions, append-only runs, the step contract (Test/Apply/Undo, WhatIf, idempotency), declarative steps, plans,
    change log and export, Overview data and health checks. Nothing touches the registry, services or C:\ProgramData of this computer.
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'Modules\AVDTune.psm1') -Force
. (Join-Path $PSScriptRoot 'Fakes\FakeMachine.ps1')

$script:failed = 0
function Test-Check([string]$Name, [bool]$Ok, $Detail) { if ($Ok) { "PASS $Name" } else { $script:failed++; "FAIL $Name" + $(if ($null -ne $Detail) { "  -> $Detail" }) } }
function Test-Throws([scriptblock]$Block) { try { & $Block | Out-Null; $false } catch { $true } }
function Join-Pairs($Table) { (($Table.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' ') }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('avdtune-check-' + [guid]::NewGuid().ToString('N'))
try {
    # ---------------------------------------------------------------- helpers
    Test-Check 'arguments are quoted per argument' ((ConvertTo-AVDTuneArgument 'a b') -eq '"a b"' -and (ConvertTo-AVDTuneArgument 'x') -eq 'x' -and (ConvertTo-AVDTuneArgument 'say "hi"') -eq '"say \"hi\""' -and (ConvertTo-AVDTuneArgument '') -eq '""' -and (ConvertTo-AVDTuneArgument 'C:\a b\') -eq '"C:\a b\\"')
    Test-Check 'elevation test returns a bool' ((Test-AVDTuneElevated) -is [bool]) $null
    $env:AVDTUNE_ROOT = $null
    $realRoot = Get-AVDTuneRoot
    Test-Check 'default root is ProgramData\AVDTune and counts as the real one' ($realRoot -like '*\AVDTune' -and (Test-AVDTuneDefaultRoot $realRoot) -and -not (Test-AVDTuneDefaultRoot $tmp)) $realRoot
    $env:AVDTUNE_ROOT = $tmp
    Test-Check 'AVDTUNE_ROOT overrides the root' ((Get-AVDTuneRoot) -eq $tmp) $null

    # ---------------------------------------------------------------- state
    [void](Initialize-AVDTuneState -Root $tmp)
    Test-Check 'state folders exist' ((@('runs', 'protocols', 'config', 'benchmark', 'logs') | Where-Object { -not (Test-Path (Join-Path $tmp $_)) }).Count -eq 0) $null
    $state = Get-AVDTuneState $tmp
    Test-Check 'state.json starts empty with schema 1' ($state.Schema -eq 1 -and -not $state.ImageVersion -and $state.Sealed -eq $false) $null
    [void](Set-AVDTuneState -Root $tmp -Values @{ LastUpdate = '2026-11-01'; Extra = 'x' })
    [void](Initialize-AVDTuneState -Root $tmp)
    $state = Get-AVDTuneState $tmp
    Test-Check 'Initialize keeps existing state; Set-AVDTuneState adds unknown keys' ($state.LastUpdate -eq '2026-11-01' -and $state.Extra -eq 'x') $null
    Test-Check 'atomic write leaves no temp file' (@(Get-ChildItem $tmp -Recurse -Filter '*.tmp').Count -eq 0) $null
    $acl = New-AVDTuneStateSecurity
    $rules = @($acl.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]))
    Test-Check 'state ACL: Administrators and SYSTEM only, inheritance off' ($acl.AreAccessRulesProtected -and $rules.Count -eq 2 -and (@($rules | ForEach-Object { $_.IdentityReference.Value } | Sort-Object) -join ',') -eq 'S-1-5-18,S-1-5-32-544' -and -not (@($rules | Where-Object { $_.FileSystemRights -ne 'FullControl' }).Count)) (@($rules | ForEach-Object { $_.IdentityReference.Value }) -join ',')
    Write-AVDTuneFile (Join-Path $tmp 'state.json') '{"Schema":99}'
    Test-Check 'a newer state schema is refused' (Test-Throws { Get-AVDTuneState $tmp }) $null
    Write-AVDTuneFile (Join-Path $tmp 'state.json') ([ordered]@{ Schema = 1; ImageVersion = $null; Versions = @(); LastUpdate = $null; LastBenchmark = $null; UpdateBlock = $null; Sealed = $false; Identity = $null; LastRunId = $null } | ConvertTo-Json)

    # ---------------------------------------------------------------- image version
    Test-Check 'image version pattern' ((Test-AVDTuneImageVersion '2026.11.001') -and -not (Test-AVDTuneImageVersion '2026.13.001') -and -not (Test-AVDTuneImageVersion '2026.11.1') -and -not (Test-AVDTuneImageVersion 'x')) $null
    $v1 = Start-AVDTuneImageVersion -Root $tmp -Date ([datetime]'2026-11-15') -User 'admin1'
    $v2 = Start-AVDTuneImageVersion -Root $tmp -Date ([datetime]'2026-11-20') -User 'admin1'
    $v3 = Start-AVDTuneImageVersion -Root $tmp -Date ([datetime]'2026-12-02') -User 'admin1'
    Test-Check 'versions count per month: 2026.11.001, 2026.11.002, 2026.12.001' ($v1 -eq '2026.11.001' -and $v2 -eq '2026.11.002' -and $v3 -eq '2026.12.001') "$v1 $v2 $v3"
    $state = Get-AVDTuneState $tmp
    Test-Check 'current version and the list are in the state' ($state.ImageVersion -eq '2026.12.001' -and @($state.Versions).Count -eq 3) $null
    $startedAgain = Start-AVDTuneImageVersion -Root $tmp -Date ([datetime]'2026-11-25')
    Test-Check 'a version started late for an earlier month continues its count' ($startedAgain -eq '2026.11.003') $startedAgain

    # ---------------------------------------------------------------- runs (append only)
    $runPath = Add-AVDTuneRun -Root $tmp -Run ([pscustomobject]@{ Id = 'r-1'; Started = 'x'; Results = @() })
    Test-Check 'a run is written as runs\<id>.json and noted in the state' ((Test-Path $runPath) -and (Get-AVDTuneState $tmp).LastRunId -eq 'r-1') $runPath
    Test-Check 'a run record is never replaced' (Test-Throws { Add-AVDTuneRun -Root $tmp -Run ([pscustomobject]@{ Id = 'r-1'; Results = @() }) }) $null
    Test-Check 'a run id with a path in it is refused' (Test-Throws { Add-AVDTuneRun -Root $tmp -Run ([pscustomobject]@{ Id = '..\x'; Results = @() }) }) $null
    $auto = [pscustomobject]@{ Id = $null; Results = @() }
    [void](Add-AVDTuneRun -Root $tmp -Run $auto)
    Test-Check 'a missing run id is made' ($auto.Id -match '^\d{8}-\d{6}-[0-9a-f]{4}$' -and @(Get-AVDTuneRun -Root $tmp).Count -eq 2) $auto.Id

    # ---------------------------------------------------------------- step contract
    $m = New-AVDTuneFakeMachine
    $reg = 'HKLM:\SOFTWARE\AVDTuneTest'
    $step = New-AVDTuneStep -Id 'optimization.flag' -Section Optimization -Title 'Flag is 1' -Reboot $true `
        -Test { param($m) $v = & $m.RegGet 'HKLM:\SOFTWARE\AVDTuneTest' 'Flag'; @{ Compliant = ($v -eq 1); State = $v } } `
        -Apply { param($m) & $m.RegSet 'HKLM:\SOFTWARE\AVDTuneTest' 'Flag' 1 'DWord' } `
        -Undo { param($m) & $m.RegRemove 'HKLM:\SOFTWARE\AVDTuneTest' 'Flag' }
    $t = Invoke-AVDTuneStep -Step $step -Machine $m -Mode Test
    Test-Check 'Test: NonCompliant, nothing written' ($t.Status -eq 'NonCompliant' -and $m.Log.Count -eq 0) $t.Status
    $w = Invoke-AVDTuneStep -Step $step -Machine $m -Mode Apply -WhatIf
    Test-Check 'Apply -WhatIf: WhatIf, nothing written' ($w.Status -eq 'WhatIf' -and $m.Log.Count -eq 0 -and $w.WhatIf) $w.Status
    Test-Check 'Apply without the snapshot gate is refused, nothing written (read only)' (-not (Test-AVDTuneWriteAllowed) -and (Test-Throws { Invoke-AVDTuneStep -Step $step -Machine $m -Mode Apply }) -and (Test-Throws { Invoke-AVDTuneStep -Step $step -Machine $m -Mode Undo }) -and $m.Log.Count -eq 0) $null
    Open-AVDTuneWriteGate -SnapshotId 'snap-check' -ConfirmedBy 'Check Runner'
    $a = Invoke-AVDTuneStep -Step $step -Machine $m -Mode Apply
    Test-Check 'Apply: Changed with before and after, reboot flag from the step' ($a.Status -eq 'Changed' -and $null -eq $a.Before -and $a.After -eq 1 -and $a.Reboot -and $m.Log.Count -eq 1) "$($a.Status) $($a.After)"
    $a2 = Invoke-AVDTuneStep -Step $step -Machine $m -Mode Apply
    Test-Check 'Apply again: Unchanged and nothing written (idempotent)' ($a2.Status -eq 'Unchanged' -and $m.Log.Count -eq 1 -and -not $a2.Reboot) $a2.Status
    $uw = Invoke-AVDTuneStep -Step $step -Machine $m -Mode Undo -WhatIf
    $u = Invoke-AVDTuneStep -Step $step -Machine $m -Mode Undo
    $u2 = Invoke-AVDTuneStep -Step $step -Machine $m -Mode Undo
    Test-Check 'Undo: WhatIf, Reverted, then Unchanged' ($uw.Status -eq 'WhatIf' -and $u.Status -eq 'Reverted' -and $u2.Status -eq 'Unchanged') "$($uw.Status) $($u.Status) $($u2.Status)"
    $noUndo = New-AVDTuneStep -Id 'optimization.noundo' -Section Optimization -Title 'x' -Test { $true } -Apply { }
    Test-Check 'a step without Undo says NoUndo' ((Invoke-AVDTuneStep -Step $noUndo -Machine $m -Mode Undo).Status -eq 'NoUndo') $null
    $lazy = New-AVDTuneStep -Id 'optimization.lazy' -Section Optimization -Title 'Apply does nothing' -Test { $false } -Apply { }
    $lz = Invoke-AVDTuneStep -Step $lazy -Machine $m -Mode Apply
    Test-Check 'Failed when the test still fails after Apply' ($lz.Status -eq 'Failed' -and $lz.Message -like '*still fails*') $lz.Message
    $boom = New-AVDTuneStep -Id 'optimization.boom' -Section Optimization -Title 'Throws' -Test { $false } -Apply { throw 'nope' }
    $bm = Invoke-AVDTuneStep -Step $boom -Machine $m -Mode Apply
    Test-Check 'an exception becomes Failed with the message' ($bm.Status -eq 'Failed' -and $bm.Message -eq 'nope') $bm.Message
    $badTest = New-AVDTuneStep -Id 'optimization.badtest' -Section Optimization -Title 'x' -Test { 'text' } -Apply { }
    Test-Check 'a test that returns something else is Failed' ((Invoke-AVDTuneStep -Step $badTest -Machine $m -Mode Test).Status -eq 'Failed') $null
    Test-Check 'step contract validation (id, section, https source)' ((Test-Throws { New-AVDTuneStep -Id 'Bad Id' -Section Optimization -Title 'x' -Test { $true } -Apply { } }) -and (Test-Throws { New-AVDTuneStep -Id 'a.b' -Section Nope -Title 'x' -Test { $true } -Apply { } }) -and (Test-Throws { New-AVDTuneStep -Id 'a.b' -Section Setup -Title 'x' -SourceUrl 'http://x' -Test { $true } -Apply { } })) $null

    # ---------------------------------------------------------------- declarative steps
    $catalog = @(Get-AVDTuneStepCatalog -Path (Join-Path $PSScriptRoot 'Fixtures\steps'))
    Test-Check 'catalog reads the json steps' ($catalog.Count -eq 3 -and $catalog[0].Id -eq 'optimization.test-registry' -and $catalog[0].Reboot -eq $true) $catalog.Count
    Test-Check 'duplicate step ids are an error' (Test-Throws { Get-AVDTuneStepCatalog -Path (Join-Path $PSScriptRoot 'Fixtures\steps-duplicate') }) $null
    Test-Check 'an unknown kind and a bad registry path are refused' ((Test-Throws { New-AVDTuneStepFromData ([pscustomobject]@{ Id = 'a.b'; Section = 'Setup'; Title = 't'; Kind = 'Nope' }) }) -and (Test-Throws { New-AVDTuneStepFromData ([pscustomobject]@{ Id = 'a.b'; Section = 'Setup'; Title = 't'; Kind = 'Registry'; Path = 'C:\x'; Name = 'n'; Value = 1 }) })) $null
    $fm = New-AVDTuneFakeMachine -Seed @{ Services = @(@{ Name = 'AvdTuneTestSvc'; StartType = 'Automatic' }); Tasks = @(@{ Path = '\AVDTuneTest\'; Name = 'Nightly'; Enabled = $true }) }
    $res = @($catalog | ForEach-Object { Invoke-AVDTuneStep -Step $_ -Machine $fm -Mode Apply })
    Test-Check 'registry, service and task steps change the fake machine' ((($res | ForEach-Object { $_.Status }) -join ',') -eq 'Changed,Changed,Changed' -and (& $fm.RegGet $reg 'Flag') -eq 1 -and (& $fm.ServiceGet 'AvdTuneTestSvc').StartType -eq 'Disabled' -and -not (& $fm.TaskGet '\AVDTuneTest\' 'Nightly').Enabled) (($res | ForEach-Object { $_.Status }) -join ',')
    $res2 = @($catalog | ForEach-Object { Invoke-AVDTuneStep -Step $_ -Machine $fm -Mode Apply })
    Test-Check 'declarative steps are idempotent' ((($res2 | ForEach-Object { $_.Status }) -join ',') -eq 'Unchanged,Unchanged,Unchanged') (($res2 | ForEach-Object { $_.Status }) -join ',')
    $und = @($catalog | ForEach-Object { Invoke-AVDTuneStep -Step $_ -Machine $fm -Mode Undo })
    Test-Check 'declarative undo restores service and task and removes the value' ((($und | ForEach-Object { $_.Status }) -join ',') -eq 'Reverted,Reverted,Reverted' -and $null -eq (& $fm.RegGet $reg 'Flag') -and (& $fm.ServiceGet 'AvdTuneTestSvc').StartType -eq 'Automatic' -and (& $fm.TaskGet '\AVDTuneTest\' 'Nightly').Enabled) (($und | ForEach-Object { $_.Status }) -join ',')
    $absent = New-AVDTuneFakeMachine
    Test-Check 'a service or task that is not there counts as compliant' ((Invoke-AVDTuneStep -Step $catalog[1] -Machine $absent -Mode Apply).Status -eq 'Unchanged' -and (Invoke-AVDTuneStep -Step $catalog[2] -Machine $absent -Mode Apply).Status -eq 'Unchanged') $null

    # ---------------------------------------------------------------- plans
    $pm = New-AVDTuneFakeMachine -Seed @{ Services = @(@{ Name = 'AvdTuneTestSvc'; StartType = 'Automatic' }); Tasks = @(@{ Path = '\AVDTuneTest\'; Name = 'Nightly'; Enabled = $true }); Now = [datetime]'2026-11-20T10:00:00' }
    $plan = [pscustomobject]@{ Name = 'check plan'; Steps = @('optimization.test-registry', 'optimization.test-service') }
    $runsBefore = @(Get-AVDTuneRun -Root $tmp).Count
    $dry = Invoke-AVDTune -Plan $plan -Catalog $catalog -Machine $pm -Root $tmp -WhatIf
    Test-Check 'plan -WhatIf: nothing changed, no run, no change log entry' ((($dry.Results | ForEach-Object { $_.Status }) -join ',') -eq 'WhatIf,WhatIf' -and $pm.Log.Count -eq 0 -and @(Get-AVDTuneRun -Root $tmp).Count -eq $runsBefore -and @(Get-AVDTuneChangeLog -Root $tmp).Count -eq 0) (($dry.Results | ForEach-Object { $_.Status }) -join ',')
    $run = Invoke-AVDTune -Plan $plan -Catalog $catalog -Machine $pm -Root $tmp -User 'admin1' -SnapshotId 'snap-1'
    $log = @(Get-AVDTuneChangeLog -Root $tmp)
    Test-Check 'plan: both steps changed, one run record, reboot noted' ((($run.Results | ForEach-Object { $_.Status }) -join ',') -eq 'Changed,Changed' -and $run.Reboot -and @(Get-AVDTuneRun -Root $tmp).Count -eq $runsBefore + 1 -and (Get-AVDTuneState $tmp).LastRunId -eq $run.Id) (($run.Results | ForEach-Object { $_.Status }) -join ',')
    Test-Check 'plan: an automatic change log entry per change, with version, run, user and snapshot' ($log.Count -eq 2 -and $log[0].Source -eq 'Step' -and $log[0].Version -eq '2026.11.003' -and $log[0].RunId -eq $run.Id -and $log[0].User -eq 'admin1' -and $log[0].SnapshotId -eq 'snap-1' -and $log[0].Category -eq 'Optimization') ($log.Count)
    $run2 = Invoke-AVDTune -Plan $plan -Catalog $catalog -Machine $pm -Root $tmp -User 'admin1'
    Test-Check 'plan again: all unchanged, no new change log entry' ((($run2.Results | ForEach-Object { $_.Status }) -join ',') -eq 'Unchanged,Unchanged' -and @(Get-AVDTuneChangeLog -Root $tmp).Count -eq 2) (($run2.Results | ForEach-Object { $_.Status }) -join ',')
    $failCatalog = @($lazy, $step, $catalog[0])
    $stopRun = Invoke-AVDTune -Plan ([pscustomobject]@{ Name = 'stop'; Steps = @('optimization.lazy', 'optimization.flag') }) -Catalog $failCatalog -Machine (New-AVDTuneFakeMachine) -Root $tmp
    Test-Check 'plan stops at the first failed step, the rest is Skipped' ((($stopRun.Results | ForEach-Object { $_.Status }) -join ',') -eq 'Failed,Skipped') (($stopRun.Results | ForEach-Object { $_.Status }) -join ',')
    Test-Check 'a plan with an unknown step is refused before anything runs' (Test-Throws { Invoke-AVDTune -Plan ([pscustomobject]@{ Name = 'x'; Steps = @('nope.nope') }) -Catalog $catalog -Machine $pm -Root $tmp }) $null
    $planFile = Join-Path $tmp 'plan.json'
    [IO.File]::WriteAllText($planFile, '{ "Name": "from file", "Steps": ["optimization.test-task"] }')
    $fileRun = Invoke-AVDTune -Plan $planFile -Catalog $catalog -Machine $pm -Root $tmp -WhatIf
    Test-Check 'a plan can be a json file' ($fileRun.Plan -eq 'from file' -and @($fileRun.Results).Count -eq 1) $null

    # ---------------------------------------------------------------- change log
    $note = Add-AVDTuneChangeLogEntry -Root $tmp -Version '2026.11.003' -Category 'Software' -Component "Edge`r`n" -ChangeType Updated -Text "Edge updated`tto 141`nsecond line" -User 'admin1'
    Test-Check 'a free note is one line without control characters' ($note.Source -eq 'Note' -and $note.Text -eq 'Edge updated to 141 second line' -and $note.Component -eq 'Edge') $note.Text
    Test-Check 'unknown change type and invalid version are refused' ((Test-Throws { Add-AVDTuneChangeLogEntry -Root $tmp -Version '2026.11.003' -Category 'x' -ChangeType Nope -Text 'x' }) -and (Test-Throws { Add-AVDTuneChangeLogEntry -Root $tmp -Version 'v1' -Category 'x' -ChangeType Note -Text 'x' })) $null
    $long = Add-AVDTuneChangeLogEntry -Root $tmp -Version '2026.12.001' -Category 'Other' -ChangeType Note -Text ('y' * 900)
    Test-Check 'a long text is cut at 500 characters' ($long.Text.Length -eq 500 -and $long.Text.EndsWith('...')) $long.Text.Length
    Test-Check 'entries are filtered per version' (@(Get-AVDTuneChangeLog -Root $tmp -Version '2026.11.003').Count -eq 3 -and @(Get-AVDTuneChangeLog -Root $tmp -Version '2026.12.001').Count -eq 1) $null
    Test-Check 'versions list: newest first, with started versions' ((@(Get-AVDTuneChangeLogVersions -Root $tmp) -join ',') -eq '2026.12.001,2026.11.003,2026.11.002,2026.11.001') (@(Get-AVDTuneChangeLogVersions -Root $tmp) -join ',')
    [void](Add-AVDTuneChangeLogEntry -Root $tmp -Version '2026.12.001' -Category 'Other' -Component '<script>alert(1)</script>' -ChangeType Note -Text 'a | b & c')
    $md = ConvertTo-AVDTuneChangeLogDocument -Root $tmp -Version '2026.12.001' -Format Markdown -ImageName 'GM-TEST01'
    Test-Check 'markdown export: title, header, escaped pipe' ($md -like '# Change log GM-TEST01 2026.12.001*' -and $md -like '*| Date | Category | Component | Change | Text | User |*' -and $md -like '*a \| b & c*') $null
    $html = ConvertTo-AVDTuneChangeLogDocument -Root $tmp -Version '2026.12.001' -Format Html
    Test-Check 'html export encodes all text' ($html -like '*&lt;script&gt;alert(1)&lt;/script&gt;*' -and $html -notlike '*<script>*' -and $html -like '*a | b &amp; c*') $null
    Test-Check 'an empty version exports "No entries."' ((ConvertTo-AVDTuneChangeLogDocument -Root $tmp -Version '2030.01.001') -like '*No entries.*') $null
    $exp = Export-AVDTuneChangeLog -Root $tmp -Version '2026.11.003' -Path (Join-Path $tmp 'out\log.html')
    $expMd = Export-AVDTuneChangeLog -Root $tmp -Version '2026.11.003' -Path (Join-Path $tmp 'out\log.md')
    Test-Check 'export picks the format from the extension and writes files' ((Get-Content $exp -Raw) -like '<!DOCTYPE html>*' -and (Get-Content $expMd -Raw) -like '# Change log*') $null

    # ---------------------------------------------------------------- overview and health
    [void](Set-AVDTuneState -Root $tmp -Values @{ LastUpdate = '2026-11-14 22:10'; UpdateBlock = 'On' })
    $ov = Get-AVDTuneOverview -Machine (New-AVDTuneFakeMachine) -Root $tmp
    Test-Check 'overview: identity from the state and the machine' ($ov.ComputerName -eq 'GM-TEST01' -and $ov.ImageVersion -eq '2026.11.003' -and $ov.LastUpdate -eq '2026-11-14 22:10' -and $ov.LastBenchmark -eq '') $ov.ImageVersion
    Test-Check 'overview: source image from the instance metadata' ($ov.SourceImage.Available -and $ov.SourceImage.Text -eq 'microsoftwindowsdesktop:office-365:win11-25h2-avd-m365:latest' -and $ov.SourceImage.ResourceGroup -eq 'rg-example' -and $ov.SourceImage.OsDisk -eq 'gm-test01_osdisk') $ov.SourceImage.Text
    Test-Check 'overview: Windows 11 multi-session build with UBR (ProductName says Windows 10)' ($ov.Windows.Name -eq 'Windows 11 Enterprise multi-session' -and $ov.Windows.FullBuild -eq '26100.4652' -and $ov.Windows.DisplayVersion -eq '25H2' -and $ov.Windows.MultiSession) $ov.Windows.Name
    Test-Check 'overview: Office build, channel from the CDN, shared licensing, updates off' ($ov.Office.Installed -and $ov.Office.Build -eq '16.0.19231.20138' -and $ov.Office.Channel -eq 'Monthly Enterprise Channel' -and $ov.Office.SharedLicensing -and $ov.Office.UpdatesEnabled -eq $false -and $ov.Office.Platform -eq 'x64') $ov.Office.Channel
    $health = @{}; foreach ($h in $ov.Health) { $health[$h.Id] = $h.Status }
    Test-Check 'health: clean master is ok (no restart, block on, no agent, no join)' ($health.reboot -eq 'ok' -and $health.updateblock -eq 'ok' -and $health.avdagent -eq 'ok' -and $health.join -eq 'ok' -and $health.sealed -eq 'info') (Join-Pairs $health)
    $dirty = New-AVDTuneFakeMachine -Seed @{
        Keys = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'); Services = @(@{ Name = 'RDAgentBootLoader' })
        Native = @{ 'dsregcmd.exe /status' = @{ ExitCode = 0; Output = "    AzureAdJoined : YES`r`n    DomainJoined : YES`r`n" } }
    }
    $ovd = Get-AVDTuneOverview -Machine $dirty -Root $tmp
    $hd = @{}; foreach ($h in $ovd.Health) { $hd[$h.Id] = $h }
    Test-Check 'health: pending restart is a warning' ($hd.reboot.Status -eq 'warn' -and $hd.reboot.Detail -like '*servicing*') $hd.reboot.Detail
    Test-Check 'health: AVD agent and joins are bad' ($hd.avdagent.Status -eq 'bad' -and $hd.join.Status -eq 'bad' -and $hd.join.Detail -like '*Microsoft Entra ID and a domain*') $hd.join.Detail
    $rename = New-AVDTuneFakeMachine -Seed @{ Registry = @{ 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager|PendingFileRenameOperations' = @('a', 'b') }; Keys = @('HKLM:\SOFTWARE\Microsoft\RDInfraAgent'); Native = @{ 'dsregcmd.exe /status' = @{ ExitCode = 1; Output = '' } } }
    $hr = @{}; foreach ($h in (Get-AVDTuneOverview -Machine $rename -Root $tmp).Health) { $hr[$h.Id] = $h.Status }
    Test-Check 'health: pending file operations, agent key only, unreadable join state' ($hr.reboot -eq 'warn' -and $hr.avdagent -eq 'bad' -and $hr.join -eq 'warn') (Join-Pairs $hr)
    [void](Set-AVDTuneState -Root $tmp -Values @{ UpdateBlock = 'Off'; Sealed = $true })
    $hs = @{}; foreach ($h in (Get-AVDTuneOverview -Machine (New-AVDTuneFakeMachine) -Root $tmp).Health) { $hs[$h.Id] = $h }
    Test-Check 'health: block off is a warning, sealed is shown' ($hs.updateblock.Status -eq 'warn' -and $hs.sealed.Detail -like 'Sealed*') $null
    $gallery = New-AVDTuneFakeMachine -Seed @{ Imds = [pscustomobject]@{ compute = [pscustomobject]@{ name = 'vm1'; storageProfile = [pscustomobject]@{ imageReference = [pscustomobject]@{ id = '/subscriptions/s/resourceGroups/g/providers/Microsoft.Compute/galleries/gal/images/win11-avd/versions/2026.11.1' } } } } }
    Test-Check 'source image: a gallery image shows its version name' ((Get-AVDTuneSourceImage $gallery).Text -eq '2026.11.1') (Get-AVDTuneSourceImage $gallery).Text
    $noAzure = New-AVDTuneFakeMachine -Seed @{ Imds = $null; Registry = @{ 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration|VersionToReport' = $null } }
    $ovn = Get-AVDTuneOverview -Machine $noAzure -Root $tmp
    Test-Check 'outside Azure and without Office the overview still works' (-not $ovn.SourceImage.Available -and -not $ovn.Office.Installed) $null

    # ---------------------------------------------------------------- the real machine, read only
    $real = New-AVDTuneMachine
    $rw = Get-AVDTuneWindowsInfo $real
    Test-Check 'real adapter (read only): Windows build is readable' ($rw.Build -match '^\d+$' -and $rw.Name) $rw.Name
    Test-Check 'real adapter: a missing key and a missing service are null' ($null -eq (& $real.RegGet 'HKLM:\SOFTWARE\AVDTune-does-not-exist' 'x') -and $null -eq (& $real.ServiceGet 'AVDTune-no-such-service') -and -not (& $real.RegKeyExists 'HKLM:\SOFTWARE\AVDTune-does-not-exist')) $null
}
finally {
    $env:AVDTUNE_ROOT = $null
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
if ($script:failed -gt 0) { throw "$script:failed check(s) failed." }
'Check-AVDTune: all checks passed.'
