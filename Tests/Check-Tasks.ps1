#requires -Version 5.1
<#
.SYNOPSIS
    Checks AVDTune-Tasks.ps1, the one mechanism behind the task bar: start, update and complete a task, determinate and indeterminate progress,
    the bar state (running, several, result for a few seconds, idle), durations, the limits of log and list, secrets removed from every text,
    updates from several runspaces at the same time, and that the pages use it. No window is shown, nothing is written.
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$script:WorkRoot = Join-Path ([IO.Path]::GetTempPath()) ('avdtune-tasks-' + [guid]::NewGuid().ToString('N'))   # the protocol code wants a work root; nothing is written there
. (Join-Path $repo 'AVDTune-Protocol.ps1')
. (Join-Path $repo 'AVDTune-Tasks.ps1')

$script:failed = 0
function Test-Check([string]$Name, [bool]$Ok, $Detail) { if ($Ok) { "PASS $Name" } else { $script:failed++; "FAIL $Name" + $(if ($null -ne $Detail) { "  -> $Detail" }) } }

# ---------------------------------------------------------------- life of a task
$v0 = Get-AVDTuneUiTaskVersion
$t = Start-AVDTuneUiTask -Kind 'demo' -Title 'Demo task' -Step 'Starting'
Test-Check 'a new task is running, has an id, a start time, no finish and the step as first log line' ($t.Status -eq 'running' -and $t.Id -ge 1 -and $t.Started -and -not $t.Finished -and $t.Log.Count -eq 1 -and $t.Log[0].Text -eq 'Starting') $null
Test-Check 'the progress is unknown (indeterminate) until a percent is set' ($null -eq $t.Percent) $t.Percent
Test-Check 'every change raises the version counter (the window redraws on it)' ((Get-AVDTuneUiTaskVersion) -gt $v0) $null
Update-AVDTuneUiTask $t -Step 'Step two' -Percent 40
Test-Check 'update: step and percent are taken, the new step is a log line' ($t.Step -eq 'Step two' -and $t.Percent -eq 40 -and $t.Log.Count -eq 2) "$($t.Step) $($t.Percent) $($t.Log.Count)"
$v1 = Get-AVDTuneUiTaskVersion
Update-AVDTuneUiTask $t -Step 'Step two' -Percent 40
Test-Check 'the same step and percent again change nothing (no log spam from a polling timer, no redraw)' ($t.Log.Count -eq 2 -and (Get-AVDTuneUiTaskVersion) -eq $v1) $t.Log.Count
Update-AVDTuneUiTask $t -Percent 250
Test-Check 'a percent outside 0-100 is clamped' ($t.Percent -eq 100) $t.Percent
Update-AVDTuneUiTask $t -Indeterminate
Test-Check '-Indeterminate clears the percent again' ($null -eq $t.Percent) $t.Percent
Update-AVDTuneUiTask $null -Step 'nothing'
Complete-AVDTuneUiTask $null
Test-Check 'a task that is not there ($null) is ignored by update and complete' $true $null
Complete-AVDTuneUiTask $t -Summary 'All done'
Test-Check 'complete: succeeded, finish time, summary, 100 percent, summary in the log' ($t.Status -eq 'succeeded' -and $t.Finished -and $t.Summary -eq 'All done' -and $t.Percent -eq 100 -and $t.Log[-1].Text -eq 'All done') $t.Status
Update-AVDTuneUiTask $t -Step 'late' -Percent 5
Complete-AVDTuneUiTask $t -Failed -Summary 'too late'
Test-Check 'an ended task stays as it ended (a late update or a second complete does nothing)' ($t.Status -eq 'succeeded' -and $t.Summary -eq 'All done' -and $t.Step -eq '') $t.Status
$f = Start-AVDTuneUiTask -Kind 'demo' -Title 'Failing task' -Step 'Working' -Retry @{ Command = 'Start-Demo'; Arguments = @('a') }
Complete-AVDTuneUiTask $f -Failed -Summary 'It broke'
Test-Check 'failed: status, cause in the summary, error level in the log, the retry command is kept' ($f.Status -eq 'failed' -and $f.Summary -eq 'It broke' -and $f.Log[-1].Level -eq 'Error' -and $f.Retry.Command -eq 'Start-Demo' -and $f.Percent -ne 100) $f.Status
Test-Check 'the label of a status for the list' ((Get-AVDTuneUiTaskLabel 'running') -eq 'Running' -and (Get-AVDTuneUiTaskLabel 'succeeded') -eq 'Done' -and (Get-AVDTuneUiTaskLabel 'failed') -eq 'Failed') $null

# ---------------------------------------------------------------- the bar
$now = Get-Date
$mk = { param($Id, $Status, $Title, $Pct, $Finished, $Summary) @{ Id = $Id; Status = $Status; Title = $Title; Step = "step $Id"; Percent = $Pct; Finished = $Finished; Summary = $Summary } }
$idle = Get-AVDTuneUiTaskBar -Tasks @() -Now $now
Test-Check 'no task: idle, nothing shown' ($idle.Kind -eq 'Idle' -and $idle.Count -eq 0 -and $idle.Running -eq 0) $idle.Kind
$one = Get-AVDTuneUiTaskBar -Tasks @((& $mk 1 'running' 'Alpha' 30 $null '')) -Now $now
Test-Check 'one running task: its title, step and percent' ($one.Kind -eq 'Running' -and $one.Title -eq 'Alpha' -and $one.Step -eq 'step 1' -and $one.Percent -eq 30 -and $one.Running -eq 1) $one.Kind
$unk = Get-AVDTuneUiTaskBar -Tasks @((& $mk 1 'running' 'Alpha' $null $null '')) -Now $now
Test-Check 'a running task without a percent shows the bar indeterminate (percent $null)' ($unk.Kind -eq 'Running' -and $null -eq $unk.Percent) $null
$many = Get-AVDTuneUiTaskBar -Tasks @((& $mk 3 'running' 'Gamma' $null $null ''), (& $mk 1 'running' 'Alpha' 10 $null ''), (& $mk 2 'succeeded' 'Beta' 100 $now 'ok')) -Now $now
Test-Check 'several running: the oldest is shown and the count says how many run' ($many.Kind -eq 'Running' -and $many.Title -eq 'Alpha' -and $many.Running -eq 2 -and $many.Count -eq 3) "$($many.Title) $($many.Running)"
$res = Get-AVDTuneUiTaskBar -Tasks @((& $mk 1 'succeeded' 'Alpha' 100 $now.AddSeconds(-3) 'Finished well')) -Now $now
Test-Check 'a task that ended 3 seconds ago: its result is shown' ($res.Kind -eq 'Result' -and $res.Ok -and $res.Result -eq 'Finished well' -and $res.Title -eq 'Alpha') $res.Kind
$bad = Get-AVDTuneUiTaskBar -Tasks @((& $mk 1 'failed' 'Alpha' $null $now.AddSeconds(-1) 'It broke')) -Now $now
Test-Check 'a failed task shows as a failed result with the cause' ($bad.Kind -eq 'Result' -and -not $bad.Ok -and $bad.Result -eq 'It broke' -and $bad.Failed -eq 1) $bad.Kind
$old = Get-AVDTuneUiTaskBar -Tasks @((& $mk 1 'failed' 'Alpha' $null $now.AddSeconds(-30) 'It broke')) -Now $now
Test-Check 'after the result time the bar is idle again but still counts the failed task' ($old.Kind -eq 'Idle' -and $old.Failed -eq 1 -and $old.Count -eq 1) $old.Kind
$both = Get-AVDTuneUiTaskBar -Tasks @((& $mk 1 'succeeded' 'Alpha' 100 $now 'ok'), (& $mk 2 'running' 'Beta' 5 $null '')) -Now $now
Test-Check 'a running task wins over a fresh result' ($both.Kind -eq 'Running' -and $both.Title -eq 'Beta') $both.Kind
Test-Check 'durations: seconds, minutes, hours, never negative' ((Format-AVDTuneUiTaskDuration $now.AddSeconds(-42) $now) -eq '42 s' -and (Format-AVDTuneUiTaskDuration $now.AddSeconds(-125) $now) -eq '2 min 5 s' -and (Format-AVDTuneUiTaskDuration $now.AddMinutes(-135) $now) -eq '2 h 15 min' -and (Format-AVDTuneUiTaskDuration $now.AddSeconds(10) $now) -eq '0 s') $null

# ---------------------------------------------------------------- secrets and limits
$jwt = 'eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4ifQ.c2lnbmF0dXJlLXNpZ25hdHVyZQ'
$s = Start-AVDTuneUiTask -Kind 'secret' -Title "Sign in token=abc123secret" -Step "Using Bearer $jwt now"
Add-AVDTuneUiTaskLog $s 'password: Zq9-Not-A-Real-Password and https://x.example/a?sig=SECRETSIG&code=987654'
Add-AVDTuneUiTaskLog $s "client_secret=topsecretvalue1234 key AbCdEfGhIjKlMnOpQrStUvWxYz0123456789AbCdEfGh"
Update-AVDTuneUiTask $s -Step 'Account 11111111-2222-3333-4444-555555555555 reached'
Complete-AVDTuneUiTask $s -Failed -Summary 'Failed: access_token=ey12345678secret and refresh_token: rrrrrrrrrr'
$all = ($s.Title, $s.Step, $s.Summary, (@($s.Log | ForEach-Object { $_.Text }) -join ' ')) -join ' '
Test-Check 'no token, password, secret, signature or key stays in title, step, summary or log' ($all -notmatch 'abc123secret|eyJ|Zq9-Not|SECRETSIG|987654|topsecretvalue|AbCdEfGhIjKl|ey12345678secret|rrrrrrrrrr') $all
Test-Check 'ids (GUIDs) are not kept either, the readable text around them is' ($all -notmatch '11111111-2222' -and $all -like '*reached*') $all
$long = Start-AVDTuneUiTask -Kind 'long' -Title ('T' * 500) -Step ('S' * 500)
Test-Check 'title and step are cut to a short length' ($long.Title.Length -le 120 -and $long.Step.Length -le 200) "$($long.Title.Length) / $($long.Step.Length)"
for ($i = 1; $i -le ($script:UiTaskMaxLog + 50); $i++) { Add-AVDTuneUiTaskLog $long "line $i" }
Test-Check 'the log of a task is limited, the newest lines stay' ($long.Log.Count -eq $script:UiTaskMaxLog -and $long.Log[-1].Text -eq "line $($script:UiTaskMaxLog + 50)") $long.Log.Count
Add-AVDTuneUiTaskLog $long ''
Test-Check 'an empty text is no log line' ($long.Log.Count -eq $script:UiTaskMaxLog) $null
Complete-AVDTuneUiTask $long

# the list is limited: finished tasks go first, running ones stay
$running = Start-AVDTuneUiTask -Kind 'keep' -Title 'Stays'
for ($i = 1; $i -le ($script:UiTaskMaxTasks + 20); $i++) { $x = Start-AVDTuneUiTask -Kind 'fill' -Title "Fill $i"; Complete-AVDTuneUiTask $x }
$list = @(Get-AVDTuneUiTasks)
Test-Check 'the list of tasks is limited to the maximum' ($list.Count -le $script:UiTaskMaxTasks) $list.Count
Test-Check 'the oldest finished tasks were dropped, a running task is never dropped' (@($list | Where-Object { $_.Id -eq $running.Id }).Count -eq 1 -and @($list | Where-Object { $_.Id -eq $t.Id }).Count -eq 0) $null
Complete-AVDTuneUiTask $running

# ---------------------------------------------------------------- threads
# Four runspaces write into the same task at the same time (like the background jobs of the window do through their progress): nothing is lost or torn
$shared = Start-AVDTuneUiTask -Kind 'threads' -Title 'From runspaces'
$pool = [runspacefactory]::CreateRunspacePool(1, 4); $pool.Open()
$jobs = foreach ($n in 1..4) {
    $ps = [powershell]::Create(); $ps.RunspacePool = $pool
    [void]$ps.AddScript({
            param($Repo, $Task, $Root, $N)
            $script:WorkRoot = $Root
            . (Join-Path $Repo 'AVDTune-Protocol.ps1')
            . (Join-Path $Repo 'AVDTune-Tasks.ps1')
            for ($i = 1; $i -le 60; $i++) { Add-AVDTuneUiTaskLog $Task "runspace $N line $i"; Update-AVDTuneUiTask $Task -Percent ([int]($i * 100 / 60)) }
        }).AddArgument($repo).AddArgument($shared).AddArgument($script:WorkRoot).AddArgument($n)
    @{ PS = $ps; Handle = $ps.BeginInvoke() }
}
foreach ($j in $jobs) { [void]$j.PS.EndInvoke($j.Handle); $j.PS.Dispose() }
$pool.Close()
$lines = @($shared.Log | ForEach-Object { $_.Text } | Where-Object { $_ -like 'runspace*' })
Test-Check 'four runspaces wrote 240 log lines into one task, none lost, none twice' ($lines.Count -eq 240 -and @($lines | Select-Object -Unique).Count -eq 240) $lines.Count
Test-Check 'the percent ended at 100 and the task is still intact' ($shared.Percent -eq 100 -and $shared.Status -eq 'running') $shared.Percent
Complete-AVDTuneUiTask $shared

# ---------------------------------------------------------------- the pages use it
$use = @{
    'AVDTune-Updates.ps1' = 'Start-AVDTuneUiTask', 'Update-AVDTuneUiTask', 'Complete-AVDTuneUiTask'
    'AVDTune-Benchmark.ps1' = 'Start-AVDTuneUiTask', 'Update-AVDTuneUiTask', 'Complete-AVDTuneUiTask', 'Invoke-UiTaskInline'
    'AVDTune-Readiness.ps1' = 'Start-AVDTuneUiTask', 'Complete-AVDTuneUiTask'
    'AVDTune-Release.ps1' = 'Start-AVDTuneUiTask', 'Complete-AVDTuneUiTask'
    'AVDTune-Start.ps1' = 'Start-AVDTuneUiTask', 'Update-AVDTuneUiTask', 'Complete-AVDTuneUiTask', 'Invoke-UiTaskInline', '-TaskTitle'
    'AVDTune-UserExperience.ps1' = 'Invoke-UiTaskInline'
    'AVDTune-Custom.ps1' = 'Start-AVDTuneUiTask', 'Update-AVDTuneUiTask', 'Complete-AVDTuneUiTask'
    'AVDTune-Printers.ps1' = 'Start-AVDTuneUiTask', 'Update-AVDTuneUiTask', 'Complete-AVDTuneUiTask'
    'AVDTune-CustomSoftware.ps1' = 'Start-AVDTuneUiTask', 'Update-AVDTuneUiTask', 'Complete-AVDTuneUiTask'
    'Start-AVDTune.ps1' = 'Start-AVDTuneUiTask', 'Complete-AVDTuneUiTask', 'AVDTune-Tasks.ps1', 'AVDTune-TaskBar.ps1'
}
foreach ($file in $use.Keys) {
    $text = [IO.File]::ReadAllText((Join-Path $repo $file))
    $missing = @($use[$file] | Where-Object { $text -notlike "*$_*" })
    Test-Check "$file uses the task mechanism ($($use[$file] -join ', '))" ($missing.Count -eq 0) ($missing -join ', ')
}
# the FSLogix page (#10): every operation is a task; Retry only for what reads (function test without write tests, storage check), never for a change of the master or the share
$fsl = [IO.File]::ReadAllText((Join-Path $repo 'AVDTune-FSLogix.ps1'))
$fslNew = $fsl.Substring($fsl.IndexOf('function New-FslTask'), $fsl.IndexOf('function Start-FslJob') - $fsl.IndexOf('function New-FslTask'))
Test-Check 'FSLogix: install, settings, lists, groups, redirections.xml, Defender, ACL, function test, storage check and the read of the page are tasks (counter-test)' ((@('fslogix-settings', 'fslogix-lists', 'fslogix-groups', 'fslogix-redirections', 'fslogix-defender', 'fslogix-acl') | Where-Object { $fslNew -notlike "*'$_'*" }).Count -eq 0 -and $fsl -like '*function New-FslTask*' -and $fsl -like '*Complete-AVDTuneUiTask $job.Task*' -and $fsl -like '*Update-AVDTuneUiTask $job.Task*' -and $fsl -like "*Start-AVDTuneUiTask -Kind 'fslogix-read'*" -and $fsl -notlike '*function Invoke-FslChange*') $null
# #72: the window thread changes nothing and reads nothing slow: every module call that changes the master or the share and the slow reads (fltmc, local groups,
# the domain SID, redirections.xml, Defender) are only in the worker texts that the runspaces run; the dry run of the settings (-WhatIf, registry only) stays
$fslUi = [regex]::Replace($fsl, "(?s)@'.*?'@", '')
$onUi = @([regex]::Matches($fslUi, '(?m)^.*$') | ForEach-Object { $_.Value } | Where-Object { $_ -notmatch '^\s*#' -and $_ -notmatch '-WhatIf' } | ForEach-Object { [regex]::Matches($_, '\b((?:Set|Undo)-AVDTuneFSLogix\w+|(?:Save|Undo)-AVDTuneRedirections|Set-AVDTuneStorageRootAcl|Get-AVDTuneFSLogix(?:Info|Groups|ListPlan|DefenderState|SettingsState)|Get-AVDTuneRedirectionsTarget)\b|\.ReadText\b') | ForEach-Object { $_.Value } })
Test-Check 'FSLogix (#72): no change of the master or the share and no slow read runs on the window thread (only in the worker texts of the runspaces)' ($onUi.Count -eq 0 -and $fsl -match "\`$script:FslReadText = @'" -and $fsl -match "\`$script:FslWorkerText = @'") ($onUi -join ', ')
Test-Check 'FSLogix: Retry only for the function test without write tests and for the storage check, not for the install (counter-test)' ($fslNew.Contains('$Kind -eq ''Test'' -and -not $Write') -and $fslNew.Contains('$Kind -eq ''Storage''') -and $fslNew -notmatch '''Install''.*Retry' -and ([regex]::Matches($fslNew, 'Command = ')).Count -eq 2) $null
$bar = [IO.File]::ReadAllText((Join-Path $repo 'AVDTune-TaskBar.ps1'))
Test-Check 'the bar colors are theme resources (no color literal in the bar code)' ($bar -notmatch '#[0-9A-Fa-f]{6}' -and $bar -notmatch 'ConvertTo-Brush') $null
$xaml = [IO.File]::ReadAllText((Join-Path $repo 'UI\AVDTune.xaml'))
$barXaml = $xaml.Substring($xaml.IndexOf('x:Name="BoxTaskBar"'))
Test-Check 'the bar XAML uses DynamicResource only (follows the light/dark switch)' ($barXaml -notmatch 'StaticResource' -and $barXaml -notmatch '"#[0-9A-Fa-f]{6}"') $null

# #66: one writer at a time. Every start of an operation that changes the master (job or inline) asks the central check first; a start that lacks it is a finding.
$writerStarts = @(
    @('AVDTune-Optimization.ps1', 'Start-OptChange'), @('AVDTune-FSLogix.ps1', 'Start-FslJob'), @('AVDTune-FSLogix.ps1', 'Assert-FslWrite'), @('AVDTune-Office.ps1', 'Start-OffJob'),
    @('AVDTune-Readiness.ps1', 'Start-ReadyJob'), @('AVDTune-Readiness.ps1', 'Start-ReadyFix'), @('AVDTune-UserExperience.ps1', 'Start-WatermarkChange'), @('AVDTune-AppMasking.ps1', 'Assert-MaskWrite'),
    @('AVDTune-Updates.ps1', 'Start-UpdateRun'), @('AVDTune-Updates.ps1', 'Start-BlockChange'), @('AVDTune-Software.ps1', 'Start-SwRun'), @('AVDTune-Seal.ps1', 'Start-SealJob'), @('AVDTune-Benchmark.ps1', 'Start-BenchJob'), @('AVDTune-Benchmark.ps1', 'Start-BenchRepair'), @('AVDTune-Language.ps1', 'Start-LangJob'), @('AVDTune-Vdi.ps1', 'Start-VdiJob'), @('AVDTune-Release.ps1', 'Start-RelJob'), @('AVDTune-Custom.ps1', 'Start-CustJob'), @('AVDTune-Printers.ps1', 'Start-PrnJob'), @('AVDTune-CustomSoftware.ps1', 'Start-CswJob'))
$missingGuard = @()
foreach ($w in $writerStarts) {
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repo $w[0]), [ref]$null, [ref]$null)
    $fn = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $w[1] }, $true)
    $body = if ($fn) { $fn.Extent.Text } else { '' }
    if ($body -notmatch 'Assert-NoOtherWriter' -and $body -notmatch "foreach \(\`$other in 'SealJob'") { $missingGuard += "$($w[0]):$($w[1])" }
}
Test-Check 'writers (#66): every start of an operation that changes the master calls the central Assert-NoOtherWriter' ($missingGuard.Count -eq 0) ($missingGuard -join ', ')
# #66 (round 4c): every background job variable of a page is either a writer (in the list of Assert-NoOtherWriter) or named here as read only; a new page that forgets the list is a finding
$readOnlyJobs = @('OptJob', 'FslReadJob', 'MaskReadJob', 'JoinJob', 'OverviewJob', 'SwLastRun', 'UpdLastRun')
$jobVars = @(Get-ChildItem -LiteralPath $repo -Filter '*.ps1' | Where-Object { $_.Name -like 'AVDTune-*.ps1' -or $_.Name -eq 'Start-AVDTune.ps1' } | ForEach-Object { [regex]::Matches([IO.File]::ReadAllText($_.FullName), '(?m)^\$script:(\w+(?:Job|Run)) = \$null') | ForEach-Object { $_.Groups[1].Value } } | Select-Object -Unique)
$unlisted = @($jobVars | Where-Object { $_ -notin $script:WriterJobVariables -and $_ -notin $readOnlyJobs })
Test-Check 'writers (#66): every job variable of a page is in WriterJobVariables or named as read only (Language, VDI included)' ($unlisted.Count -eq 0 -and 'LangJob' -in $script:WriterJobVariables -and 'VdiJob' -in $script:WriterJobVariables -and 'Latest' -in $script:WriterReadOnlyKinds.VdiJob -and 'CustJob' -in $script:WriterJobVariables -and (@($script:WriterReadOnlyKinds.CustJob) -join ',') -eq 'Status,Reach,Preview' -and 'PrnJob' -in $script:WriterJobVariables -and (@($script:WriterReadOnlyKinds.PrnJob) -join ',') -eq 'Servers,Read' -and 'CswJob' -in $script:WriterJobVariables -and (@($script:WriterReadOnlyKinds.CswJob) -join ',') -eq 'Status') ($unlisted -join ', ')

# #66 (re-review): a new image version must not start while a job of the window changes the master (it may not have set the marker yet); the shutdown block goes only when no job is left
$startText = Get-Content -Raw (Join-Path $repo 'Start-AVDTune.ps1')
$startAst = [Management.Automation.Language.Parser]::ParseInput($startText, [ref]$null, [ref]$null)
$getFn = { param($n) $startAst.Find({ param($x) $x -is [Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq $n }, $true) }
Test-Check 'new version (#66): the busy state of the button and Start-NewVersion ask Test-MasterBusy (marker or a running writer)' ((& $getFn 'Update-Chip').Extent.Text -match 'Test-MasterBusy' -and (& $getFn 'Start-NewVersion').Extent.Text -match 'Test-MasterBusy') $null
$script:StateRoot = 'x'
function Test-AVDTuneChangeInProgress { param($Root) $false }
Invoke-Expression (& $getFn 'Test-MasterBusy').Extent.Text
$free = -not (Test-MasterBusy)
$script:OptRun = @{ Mode = 'Apply' }; $busyRun = Test-MasterBusy; $script:OptRun = $null
Test-Check 'new version (#66): a running writer without any marker makes the master busy, nothing running does not' ($free -and $busyRun) "free=$free busy=$busyRun"
$script:DestroyCount = 0; $script:CreateCount = 0
function Get-WindowHandle { [IntPtr]1 }
Invoke-Expression ((& $getFn 'Set-ShutdownBlock').Extent.Text.Replace('[void][AVDTune.ShutdownBlock]::ShutdownBlockReasonDestroy($h)', '$script:DestroyCount++').Replace('[void][AVDTune.ShutdownBlock]::ShutdownBlockReasonCreate($h, $script:ShutdownReason)', '$script:CreateCount++'))
$script:UpdJob = @{ Kind = 'Scan' }; $script:OptRun = @{ Mode = 'Apply' }
Set-ShutdownBlock $false; $keptWhileRun = ($script:DestroyCount -eq 0)
$script:OptRun = $null
Set-ShutdownBlock $false; $keptWhileScan = ($script:DestroyCount -eq 0)
$script:UpdJob = $null
Set-ShutdownBlock $false
Test-Check 'shutdown block (#66): switching it off does nothing while any job still runs (an ending search must not release the block of a run) and releases it when none is left' ($keptWhileRun -and $keptWhileScan -and $script:DestroyCount -eq 1) "kept=$keptWhileRun/$keptWhileScan destroy=$($script:DestroyCount)"

# #49: the release job (check at every start, also install) does not hold the shutdown block of the window: the end of the last other job releases it
$script:CreateCount = 0; Set-ShutdownBlock $true; $d0 = $script:DestroyCount
$script:RelJob = @{ Kind = 'Install' }; Set-ShutdownBlock $false; $relKept = ($script:DestroyCount -eq $d0)
$script:RelJob = @{ Kind = 'Start' }; Set-ShutdownBlock $false; $relReleased = ($script:DestroyCount -eq $d0 + 1); $script:RelJob = $null
Test-Check 'shutdown block (#49): a running release check does not keep the block of an ended run' ($relKept -and $relReleased -and 'RelJob' -in $script:WriterJobVariables) "released=$relReleased"

# #50: after the finish every write start of a page is refused with the clear text; the crash repairs pass -AllowSealed (and only they)
$script:FakeSealed = $true
function Test-AVDTuneSealed { param($Root) $script:FakeSealed }
function T([string]$Key) { $Key }
$sealErr = $null; try { Assert-NoOtherWriter } catch { $sealErr = $_.Exception.Message }
$sealRepair = $true; try { Assert-NoOtherWriter -AllowSealed } catch { $sealRepair = $false }
$script:FakeSealed = $false; $sealOpen = $true; try { Assert-NoOtherWriter } catch { $sealOpen = $false }
$allowUsers = @(Get-ChildItem -LiteralPath $repo -Filter 'AVDTune-*.ps1' | Select-String -Pattern 'Assert-NoOtherWriter -AllowSealed' | ForEach-Object { $_.Filename } | Sort-Object -Unique)
Test-Check 'sealed (#50): a write start is refused while the version is finished (text shell.sealed), the crash repairs (finish, benchmark, maintenance mode) pass, an open version passes' ($sealErr -eq 'shell.sealed' -and $sealRepair -and $sealOpen -and ($allowUsers -join ',') -eq 'AVDTune-Benchmark.ps1,AVDTune-Seal.ps1,AVDTune-Updates.ps1' -and [IO.File]::ReadAllText((Join-Path $repo 'AVDTune-Updates.ps1')).Contains("Assert-NoOtherWriter -AllowSealed:(`$Kind -eq 'Block-Repair')")) "err=$sealErr users=$($allowUsers -join ',')"
# #50/#66 review: every function of a page that starts a writer job (assigns one of WriterJobVariables) asks Assert-NoOtherWriter itself, not only some of its callers
$unguarded = @()
foreach ($pf in Get-ChildItem -LiteralPath $repo -Filter 'AVDTune-*.ps1') {
    $pAst = [Management.Automation.Language.Parser]::ParseFile($pf.FullName, [ref]$null, [ref]$null)
    foreach ($fnAst in $pAst.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        $fnText = $fnAst.Extent.Text
        foreach ($wv in $script:WriterJobVariables) { if ($fnText.Contains("`$script:$wv = @{") -and -not $fnText.Contains('Assert-NoOtherWriter')) { $unguarded += "$($pf.Name):$($fnAst.Name)" } }
    }
}
Test-Check 'writers (#50 review): every page function that starts a writer job calls Assert-NoOtherWriter (Start-OptRun, Start-SwJob, Start-UpdJob included)' ($unguarded.Count -eq 0) ($unguarded -join ', ')
# #50 review: the module writers outside Start-AVDTuneChange refuse a finished version themselves (masking, benchmark quiet mode, environment apply and undo)
$guardFns = @(@('AVDTune.Masking.psm1', 'Save-AVDTuneRuleSet'), @('AVDTune.Masking.psm1', 'Remove-AVDTuneRuleSet'), @('AVDTune.Masking.psm1', 'Undo-AVDTuneMaskingChange'), @('AVDTune.Masking.psm1', 'Add-AVDTuneComfortShortcut'),
    @('AVDTune.Benchmark.psm1', 'Start-AVDTuneBenchmarkQuiet'), @('AVDTune.Environment.psm1', 'Invoke-AVDTuneEnvApply'), @('AVDTune.Environment.psm1', 'Invoke-AVDTuneEnvUndo'))
$noGuard = @(foreach ($g in $guardFns) {
        $mAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repo "Modules\$($g[0])"), [ref]$null, [ref]$null)
        $mFn = $mAst.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $g[1] }, $true)
        if (-not $mFn -or $mFn.Body.Extent.Text -notmatch 'Assert-AVDTuneNotSealed -Root \$Root') { $g[1] }
    })
Test-Check 'sealed (#50 review): masking, benchmark quiet mode and environment apply/undo refuse a finished version in the module' ($noGuard.Count -eq 0) ($noGuard -join ', ')

# #49 (4): the global lock of the write buttons (one command, WPF disables the button while a writer job runs and gives the page its own state back)
Add-Type -AssemblyName PresentationFramework
$cmd49 = New-AVDTuneWriterLockCommand
$b1 = New-Object System.Windows.Controls.Button; $b2 = New-Object System.Windows.Controls.Button; $b2.IsEnabled = $false
$ui49 = @{ BtnSealRun = $b1; BtnUpdAll = $b2; BtnRefresh = (New-Object System.Windows.Controls.Button) }
Update-AVDTuneWriterLock -Command $cmd49 -Ui $ui49; $idle = ($b1.IsEnabled -and -not $b2.IsEnabled -and $ui49.BtnRefresh.IsEnabled)
$script:SwJob = @{ Kind = 'Run' }; Update-AVDTuneWriterLock -Command $cmd49 -Ui $ui49; $locked = (-not $b1.IsEnabled -and -not $b2.IsEnabled -and $ui49.BtnRefresh.IsEnabled)
$b2.IsEnabled = $true; $stillLocked = -not $b2.IsEnabled   # a page that enables its button meanwhile does not lift the lock
$script:SwJob = @{ Kind = 'Scan' }; Update-AVDTuneWriterLock -Command $cmd49 -Ui $ui49; $scanFree = $b1.IsEnabled
$script:SwJob = $null; $b2.IsEnabled = $false; Update-AVDTuneWriterLock -Command $cmd49 -Ui $ui49; $back = ($b1.IsEnabled -and -not $b2.IsEnabled)
Test-Check 'writer lock (#49.4): listed write buttons are disabled while a writer job runs (not a read-only kind, not other buttons); the page state comes back afterwards' ($idle -and $locked -and $stillLocked -and $scanFree -and $back -and [object]::ReferenceEquals($b1.Command, $cmd49)) "idle=$idle locked=$locked still=$stillLocked scan=$scanFree back=$back"
$xamlText = (Get-ChildItem -LiteralPath (Join-Path $repo 'UI') -Filter '*.xaml' | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join "`n"
$codeText = (Get-ChildItem -LiteralPath $repo -Filter 'AVDTune-*.ps1' | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join "`n"
$unknownButtons = @($script:WriterButtons | Where-Object { -not $xamlText.Contains("x:Name=""$_""") -and -not $codeText.Contains("`$ui.$_ = ") })
$taskBarText = [IO.File]::ReadAllText((Join-Path $repo 'AVDTune-TaskBar.ps1'))
Test-Check 'writer lock (#49.4): every listed button exists (XAML or built by its page) and the window timer runs the lock' ($unknownButtons.Count -eq 0 -and $taskBarText -match '\$script:Timer\.Add_Tick\(\{ try \{ Update-AVDTuneWriterLock -Command \$script:WriterLock -Ui \$ui \}') ($unknownButtons -join ', ')

if ($script:failed -gt 0) { throw "$script:failed check(s) failed." }
'Check-Tasks: all checks passed.'
