# The Benchmark page (dot-sourced by Start-AVDTune.ps1). Logic is in Modules\AVDTune.Benchmark.psm1; this file starts the run in a background runspace
# and polls it with the window timer, then shows the score per category and the comparison with the baseline.
# Test mode: the runspace uses the fake machine and the fake benchmark adapter (Tests\Fakes\FakeBench.ps1): no process, no download, no service is touched.

$script:BenchJob = $null
$script:BenchFakeScript = $(if ($script:TestMode) { (Get-TestScript 'FakeBench.ps1') } else { '' })
$script:BenchFakeSeed = $null   # test hook: hashtable for New-AVDTuneFakeBench
$script:BenchLast = $null       # the result shown
$script:BenchCatTitle = @{ cpu = 'CPU'; memory = 'Memory'; osdisk = 'OS disk'; display = 'Remote display'; network = 'Network'; apps = 'Applications' }

function Set-BenchBusy([bool]$Busy) {
    foreach ($b in $ui.BtnBenchQuick, $ui.BtnBenchFull, $ui.BtnBenchRepair) { $b.IsEnabled = -not $Busy }
    $ui.BarBench.Visibility = ConvertTo-Vis $Busy
    $window.Cursor = $(if ($Busy) { [System.Windows.Input.Cursors]::AppStarting } else { $null })
}

function Start-BenchJob([string]$Mode, [string]$Kind) {
    if ($script:BenchJob) { throw 'A benchmark is already running.' }
    if ($script:UpdJob) { throw 'An update operation is running. Wait until it is done.' }
    $sync = [hashtable]::Synchronized(@{ Text = ''; Percent = 0 })
    $ps = [powershell]::Create()
    [void]$ps.AddScript({
            param($AppRoot, $Fake, $FakeBench, $Root, $Mode, $Kind, $Sync, $User, $Seed, $SharedMachine)
            $ErrorActionPreference = 'Stop'
            Import-Module (Join-Path $AppRoot 'Modules\AVDTune.psm1') -Force
            Import-Module (Join-Path $AppRoot 'Modules\AVDTune.Benchmark.psm1') -Force
            $skipIdle = $false
            if ($Fake) {
                . $Fake; . $FakeBench
                $m = $SharedMachine
                if (-not $m) { $m = New-AVDTuneFakeMachine -Seed @{ Services = @(@{ Name = 'wuauserv'; StartType = 'Manual'; Status = 'Running' }, @{ Name = 'WSearch'; StartType = 'Automatic'; Status = 'Running' }) } }
                $cfg = Get-AVDTuneBenchmarkConfig; $ref = Get-AVDTuneBenchmarkReference
                $seedTable = @{}; if ($Seed) { foreach ($k in $Seed.Keys) { $seedTable[$k] = $Seed[$k] } }
                $b = New-AVDTuneFakeBench -Reference $ref -Config $cfg -Seed $seedTable
                $skipIdle = $true
            }
            else { $m = New-AVDTuneMachine; $b = New-AVDTuneBenchAdapter }
            $progress = { param($t, $p) $Sync.Text = $t; if ($null -ne $p) { $Sync.Percent = [int]$p } }
            Invoke-AVDTuneBenchmark -Machine $m -Bench $b -Root $Root -Mode $Mode -Kind $Kind -User $User -Progress $progress -SkipIdleCheck:$skipIdle
        }).AddArgument($script:AppRoot).AddArgument($(if ($script:TestMode) { $script:TestInfo.FakeScript } else { '' })).AddArgument($script:BenchFakeScript).AddArgument($script:StateRoot).AddArgument($Mode).AddArgument($Kind).AddArgument($sync).AddArgument([string]$env:USERNAME).AddArgument($script:BenchFakeSeed).AddArgument($(if ($script:TestMode) { $script:Machine } else { $null }))
    $task = Start-AVDTuneUiTask -Kind 'benchmark' -Title "Benchmark ($($Mode.ToLower()) run)" -Step 'Starting' -Percent 0   # no Retry: a run pauses Windows Update and the indexer and is started on the page after its confirmation
    $script:BenchJob = @{ PS = $ps; Handle = $ps.BeginInvoke(); Mode = $Mode; Sync = $sync; Task = $task }
    Set-ShutdownBlock $true
    Set-BenchBusy $true
}

function Complete-BenchJob {
    $job = $script:BenchJob
    if (-not $job) { return }
    if (-not $job.Handle.IsCompleted) {
        # the progress of the runspace goes into the task; the page shows the same state
        $text = [string]$job.Sync.Text
        Update-AVDTuneUiTask $job.Task -Step $text -Percent ([int]$job.Sync.Percent)
        if ($script:CurrentPage -eq 'Benchmark') { $ui.TxtBenchState.Text = [string]$job.Task.Step; $ui.BarBench.Value = [double]$job.Task.Percent }
        return
    }
    $script:BenchJob = $null
    Set-ShutdownBlock $false
    $result = $null; $err = ''
    try {
        $out = @($job.PS.EndInvoke($job.Handle))
        if ($job.PS.Streams.Error.Count -gt 0) { $err = $job.PS.Streams.Error[0].Exception.Message }
        $result = $out | Select-Object -Last 1
    }
    catch { $err = $_.Exception.Message }
    finally { $job.PS.Dispose() }
    Set-BenchBusy $false
    if ($err -and -not $result) { $ui.TxtBenchState.Text = "The benchmark stopped: $err"; Show-Error $err; Complete-AVDTuneUiTask $job.Task -Failed -Summary "The benchmark stopped: $err" }
    elseif ($result) {
        $script:BenchLast = $result.Result
        $ui.TxtBenchState.Text = "Finished: $($result.Summary)"
        Show-Toast "Benchmark finished: $($result.Summary)"
        Complete-AVDTuneUiTask $job.Task -Summary "Benchmark finished: $($result.Summary)"
        [void](Add-AVDTuneProtocolNote -Protocol $script:Protocol -Group 'benchmark' -Subject $result.Summary)
        Save-Protocol
    }
    Complete-AVDTuneUiTask $job.Task -Failed:([bool]$err) -Summary $(if ($err) { $err } else { 'Finished' })   # no-op when the branch above ended it
    Update-BenchmarkView; Start-OverviewRefresh
    if ($script:CloseWhenDone -and -not $script:BenchJob -and -not $script:UpdJob) { if ($err) { $script:CloseWhenDone = $false } else { $window.Close() } }
}
$script:Timer.Add_Tick({ try { Complete-BenchJob } catch { Show-Error $_.Exception.Message } })

function New-BenchCatRow([string]$Title, $Index, $Compare) {
    $g = New-Object System.Windows.Controls.Grid; $g.Margin = '0,4,0,4'
    foreach ($w in 200, 90, 140, '*') { $c = New-Object System.Windows.Controls.ColumnDefinition; $c.Width = $w; [void]$g.ColumnDefinitions.Add($c) }
    $t = New-Text $Title; $t.FontWeight = 'SemiBold'
    $i = New-Text ([string]$Index); $i.SetValue([System.Windows.Controls.Grid]::ColumnProperty, 1)
    $d = New-Text ''; $d.SetValue([System.Windows.Controls.Grid]::ColumnProperty, 2)
    if ($Compare) {
        if ($null -eq $Compare.DeltaPercent) { $d.Text = 'no baseline value' ; Set-Brush $d ([System.Windows.Controls.TextBlock]::ForegroundProperty) 'MutedText' }
        else {
            $d.Text = ('{0:+0.0;-0.0;0.0} % vs baseline' -f [double]$Compare.DeltaPercent)
            Set-Brush $d ([System.Windows.Controls.TextBlock]::ForegroundProperty) $(switch ($Compare.Class) { 'better' { 'Success' } 'worse' { 'Danger' } default { 'MutedText' } })
        }
    }
    foreach ($e in $t, $i, $d) { [void]$g.Children.Add($e) }
    $g
}

function Update-BenchmarkView {
    $crash = Get-AVDTuneBenchmarkCrash -Root $script:StateRoot
    $ui.BoxBenchCrash.Visibility = ConvertTo-Vis ([bool]$crash)
    if ($crash) { $ui.TxtBenchCrash.Text = "The benchmark of $(([datetime]$crash.Started).ToString('yyyy-MM-dd HH:mm')) did not end properly. Paused: $($crash.Services -join ', '). Restoring starts them again." }
    $results = @(Get-AVDTuneBenchmarkResult -Root $script:StateRoot)
    $shown = $script:BenchLast
    if (-not $shown -and $results.Count -gt 0) { $shown = $results[-1] }
    $ui.PanelBenchCats.Children.Clear()
    $ui.BoxBenchProvisional.Visibility = 'Collapsed'
    if (-not $shown) {
        $ui.TxtBenchTitle.Text = 'Result'; $ui.TxtBenchScore.Text = 'No benchmark yet'; $ui.TxtBenchMeta.Text = 'Start a full run (about 17 minutes) for a baseline, or a quick run (about 3 minutes) to try it. Quick results are not compared with full ones.'; $ui.TxtBenchNotes.Text = ''
    }
    else {
        $h = $shown.scores.host
        $ui.TxtBenchTitle.Text = "Host score ($($shown.mode) run, $(([datetime]$shown.started).ToLocalTime().ToString('yyyy-MM-dd HH:mm')))"
        $ui.TxtBenchScore.Text = $(if ($null -ne $h.value) { [string]$h.value } else { 'no score' })
        $ui.TxtBenchMeta.Text = "$($shown.benchmarkVersion), $($shown.system.vmSize), $($shown.system.cpuModel), $($shown.system.vCpu) vCPU, $($shown.system.ramGiB) GiB. 1000 = the reference host."
        if ($h.provisional) { $ui.BoxBenchProvisional.Visibility = 'Visible'; $ui.TxtBenchProvisional.Text = 'Provisional: the reference values are placeholders (not measured yet). The numbers show changes between runs of this version, they are not yet comparable with other systems.' }
        $base = Get-AVDTuneBenchmarkBaseline -Root $script:StateRoot
        $cmp = $null
        $cfg = Get-AVDTuneBenchmarkConfig
        $notes = @()
        if ($base -and $base.runId -ne $shown.runId) {
            $cmp = Compare-AVDTuneBenchmark -Current $shown -Baseline $base -Config $cfg
            if (-not $cmp.Comparable) { $notes += $cmp.Reason; $cmp = $null }
            else { $notes += @($cmp.Notes); if ($cmp.Host) { $ui.TxtBenchMeta.Text += ('  Against the baseline: {0:+0.0;-0.0;0.0} %.' -f [double]$cmp.Host.DeltaPercent) } }
        }
        elseif (-not $base) { $notes += 'No baseline yet: the first full run of the initial analysis becomes the baseline.' }
        foreach ($c in $h.categories.PSObject.Properties) {
            $title = $script:BenchCatTitle[$c.Name]; if (-not $title) { $title = $c.Name }
            $cc = $null; if ($cmp -and $cmp.Categories.Contains($c.Name)) { $cc = $cmp.Categories[$c.Name] }
            [void]$ui.PanelBenchCats.Children.Add((New-BenchCatRow $title $c.Value.index $cc))
        }
        foreach ($k in @($h.missingCategories)) { $t = $script:BenchCatTitle[[string]$k]; $notes += "$t was not measured." }
        foreach ($pair in @(@('fslogix', 'FSLogix score'), @('gpu', 'GPU score'))) {
            $sc = $shown.scores.PSObject.Properties[$pair[0]]
            if (-not $sc) { continue }
            $sc = $sc.Value
            if ($null -ne $sc.value) { $notes += ('{0}: {1}{2}.' -f $pair[1], $sc.value, $(if ($sc.partial) { ' (partial score without ' + (@($sc.missingCategories) -join ', ') + ')' } else { '' })) }
            elseif ($sc.reason) { $notes += ('{0}: {1}.' -f $pair[1], $sc.reason) }
        }
        if ($shown.capacity -and $null -ne $shown.capacity.estimatedUsers) { $notes += "Capacity: about $($shown.capacity.estimatedUsers) users (own method, an estimate)." }
        $bad = @($shown.measures | Where-Object { $_.status -ne 'ok' })
        if ($bad.Count -gt 0) { $notes += "Not measured: " + ((@($bad | ForEach-Object { "$($_.id) ($($_.reason))" })) -join '; ') }
        if ($h.unstable) { $notes += 'At least one measure varied more than 10 percent between the runs (unstable).' }
        $ui.TxtBenchNotes.Text = ($notes -join "`r`n")
    }
    $ui.PanelBenchHistory.Children.Clear()
    if ($results.Count -eq 0) { [void]$ui.PanelBenchHistory.Children.Add((New-Text 'No benchmark run yet.' 'Hint')) }
    $recent = @($results | Select-Object -Last 8); [array]::Reverse($recent)
    foreach ($r in $recent) {
        $t = New-Object System.Windows.Controls.TextBlock; $t.TextWrapping = 'Wrap'; $t.FontFamily = 'Cascadia Mono, Consolas'; $t.FontSize = 12; $t.Margin = '0,2,0,2'
        $t.Text = '{0}   {1,-5} {2,-8} Host {3}' -f ([datetime]$r.started).ToLocalTime().ToString('yyyy-MM-dd HH:mm'), $r.mode, $r.kind, $(if ($null -ne $r.scores.host.value) { $r.scores.host.value } else { '-' })
        [void]$ui.PanelBenchHistory.Children.Add($t)
    }
}

function Start-BenchRun([string]$Mode) {
    $ask = if ($Mode -eq 'Full') { 'Start a full benchmark (about 17 minutes)? Windows Update and the indexer are paused and started again. Nobody else may be signed in.' } else { 'Start a quick benchmark (about 3 minutes)? It is not compared with full runs.' }
    if (-not (Confirm-Action $ask 'Benchmark')) { return }
    $state = Get-AVDTuneState $script:StateRoot
    $kind = if (-not (Get-AVDTuneProp $state 'BaselineBenchmark') -and $Mode -eq 'Full') { 'baseline' } else { 'manual' }
    $ui.TxtBenchState.Text = 'Starting ...'; $ui.BarBench.Value = 0
    Start-BenchJob $Mode $kind
}
Add-Click $ui.BtnBenchFull { Start-BenchRun 'Full' }
Add-Click $ui.BtnBenchQuick { Start-BenchRun 'Quick' }
Add-Click $ui.BtnBenchRepair {
    $r = Invoke-UiTaskInline -Kind 'benchmark-repair' -Title 'Restoring Windows Update and the indexer' -Step 'Putting back what the benchmark paused' -Block {
        $m = $script:Machine
        $b = $(if ($script:TestMode) { . $script:BenchFakeScript; New-AVDTuneFakeBench -Reference (Get-AVDTuneBenchmarkReference) -Config (Get-AVDTuneBenchmarkConfig) } else { New-AVDTuneBenchAdapter })
        Repair-AVDTuneBenchmarkCrash -Machine $m -Bench $b -Root $script:StateRoot -User ([string]$env:USERNAME)
    }
    Show-Toast $r.Message
    Update-BenchmarkView
}
