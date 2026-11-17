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
    'Start-AVDTune.ps1' = 'Start-AVDTuneUiTask', 'Complete-AVDTuneUiTask', 'AVDTune-Tasks.ps1', 'AVDTune-TaskBar.ps1'
}
foreach ($file in $use.Keys) {
    $text = [IO.File]::ReadAllText((Join-Path $repo $file))
    $missing = @($use[$file] | Where-Object { $text -notlike "*$_*" })
    Test-Check "$file uses the task mechanism ($($use[$file] -join ', '))" ($missing.Count -eq 0) ($missing -join ', ')
}
# the FSLogix page (#10): every operation is a task; Retry only for what reads (function test without write tests, storage check), never for a change of the master or the share
$fsl = [IO.File]::ReadAllText((Join-Path $repo 'AVDTune-FSLogix.ps1'))
Test-Check 'FSLogix: install, settings, redirections.xml, Defender, ACL, function test and storage check are tasks (counter-test)' ((@('fslogix-settings', 'fslogix-redirections', 'fslogix-defender', 'fslogix-acl') | Where-Object { $fsl -notlike "*Invoke-FslChange -Kind '$_'*" }).Count -eq 0 -and $fsl -like '*function New-FslTask*' -and $fsl -like '*Complete-AVDTuneUiTask $job.Task*' -and $fsl -like '*Update-AVDTuneUiTask $job.Task*') $null
$fslChange = $fsl.Substring($fsl.IndexOf('function Invoke-FslChange'), $fsl.IndexOf('function Show-FslRun') - $fsl.IndexOf('function Invoke-FslChange'))
Test-Check 'FSLogix: the changes of the master and the share offer no Retry (counter-test)' ($fslChange -notmatch '-Retry|Retry =') $null
$fslNew = $fsl.Substring($fsl.IndexOf('function New-FslTask'), $fsl.IndexOf('function Start-FslJob') - $fsl.IndexOf('function New-FslTask'))
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
    @('AVDTune-Updates.ps1', 'Start-UpdateRun'), @('AVDTune-Updates.ps1', 'Start-BlockChange'), @('AVDTune-Software.ps1', 'Start-SwRun'), @('AVDTune-Seal.ps1', 'Start-SealJob'))
$missingGuard = @()
foreach ($w in $writerStarts) {
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repo $w[0]), [ref]$null, [ref]$null)
    $fn = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $w[1] }, $true)
    $body = if ($fn) { $fn.Extent.Text } else { '' }
    if ($body -notmatch 'Assert-NoOtherWriter' -and $body -notmatch "foreach \(\`$other in 'SealJob'") { $missingGuard += "$($w[0]):$($w[1])" }
}
Test-Check 'writers (#66): every start of an operation that changes the master calls the central Assert-NoOtherWriter' ($missingGuard.Count -eq 0) ($missingGuard -join ', ')

if ($script:failed -gt 0) { throw "$script:failed check(s) failed." }
'Check-Tasks: all checks passed.'
