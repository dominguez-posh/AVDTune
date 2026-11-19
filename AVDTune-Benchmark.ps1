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

function Start-BenchJob([string]$Mode, [string]$Kind, [string]$SystemName = '', [string]$Notes = '') {
    if ($script:BenchJob) { throw 'A benchmark is already running.' }
    if ($script:UpdJob) { throw 'An update operation is running. Wait until it is done.' }
    if ($script:OptRun) { throw 'An optimization run is going. Wait until it is done.' }
    $block = Get-BenchStartBlock; if ($block) { throw (T 'bench.rel.refused' $block) }   # also here: every start goes through this function (Finn, #90)
    Assert-NoOtherWriter
    $sync = [hashtable]::Synchronized(@{ Text = ''; Percent = 0 })
    $ps = New-AVDTunePowerShell
    [void]$ps.AddScript({
            param($AppRoot, $Fake, $FakeBench, $Root, $Mode, $Kind, $Sync, $User, $Seed, $SharedMachine, $SystemName, $Notes)
            $ErrorActionPreference = 'Stop'
            Import-Module (Join-Path $AppRoot 'Modules\AVDTune.psm1') -Force
            Import-Module (Join-Path $AppRoot 'Modules\AVDTune.Benchmark.psm1') -Force
            # the real adapter calls Open-AVDTuneVerifiedBenchExe from closures, which only see globally imported functions (#67)
            Import-Module (Join-Path $AppRoot 'Modules\AVDTune.Release.psm1') -Force
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
            $named = @{}; if ($Kind -eq 'benchmark-only') { $named.SystemName = $SystemName; $named.Notes = $Notes }   # plan 6b: name and notes only in that mode
            Invoke-AVDTuneBenchmark -Machine $m -Bench $b -Root $Root -Mode $Mode -Kind $Kind -User $User -Progress $progress -SkipIdleCheck:$skipIdle @named
        }).AddArgument($script:AppRoot).AddArgument($(if ($script:TestMode) { $script:TestInfo.FakeScript } else { '' })).AddArgument($script:BenchFakeScript).AddArgument($script:StateRoot).AddArgument($Mode).AddArgument($Kind).AddArgument($sync).AddArgument([string]$env:USERNAME).AddArgument($script:BenchFakeSeed).AddArgument($(if ($script:TestMode) { $script:Machine } else { $null })).AddArgument($SystemName).AddArgument($Notes)
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
    if ($err -and -not $result) { $ui.TxtBenchState.Text = (T 'bench.stopped' $err); Show-Error $err; Complete-AVDTuneUiTask $job.Task -Failed -Summary "The benchmark stopped: $err" }
    elseif ($result) {
        $script:BenchLast = $result.Result
        $ui.TxtBenchState.Text = (T 'bench.finished' $($result.Summary))
        # #92 (Finn M1): a temporary benchmark user that was left behind or removed is said on the page and in the protocol
        $userWarn = @(@($result.Warnings) | Where-Object { [string]$_ -like '*Temporary benchmark user*' })
        if ($userWarn.Count -gt 0) {
            $ui.TxtBenchState.Text += (T 'bench.warning') + ($userWarn -join "`n")
            [void](Add-AVDTuneProtocolNote -Protocol $script:Protocol -Group 'benchmark' -Subject ('Warning: ' + ($userWarn -join ' ')))
        }
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
        if ($null -eq $Compare.DeltaPercent) { $d.Text = (T 'bench.nobase') ; Set-Brush $d ([System.Windows.Controls.TextBlock]::ForegroundProperty) 'MutedText' }
        else {
            $d.Text = ((T 'bench.vsbase') -f [double]$Compare.DeltaPercent)
            Set-Brush $d ([System.Windows.Controls.TextBlock]::ForegroundProperty) $(switch ($Compare.Class) { 'better' { 'Success' } 'worse' { 'Danger' } default { 'MutedText' } })
        }
    }
    foreach ($e in $t, $i, $d) { [void]$g.Children.Add($e) }
    $g
}

function Update-BenchmarkView {
    $crash = Get-AVDTuneBenchmarkCrash -Root $script:StateRoot
    $ui.BoxBenchCrash.Visibility = ConvertTo-Vis ([bool]$crash)
    if ($crash) { $ui.TxtBenchCrash.Text = (T 'bench.crash' $(([datetime]$crash.Started).ToString('yyyy-MM-dd HH:mm')) $($crash.Services -join ', ')) }
    $results = @(Get-AVDTuneBenchmarkResult -Root $script:StateRoot)
    $shown = $script:BenchLast
    if (-not $shown -and $results.Count -gt 0) { $shown = $results[-1] }
    $ui.PanelBenchCats.Children.Clear()
    $ui.BoxBenchProvisional.Visibility = 'Collapsed'
    if (-not $shown) {
        $ui.TxtBenchTitle.Text = (T 'bench.result'); $ui.TxtBenchScore.Text = (T 'bench.none'); $ui.TxtBenchMeta.Text = (T 'bench.none.text'); $ui.TxtBenchNotes.Text = ''
    }
    else {
        $h = $shown.scores.host
        $ui.TxtBenchTitle.Text = (T 'bench.hostscore' $($shown.mode) $(([datetime]$shown.started).ToLocalTime().ToString('yyyy-MM-dd HH:mm')))
        $ui.TxtBenchScore.Text = $(if ($null -ne $h.value) { [string]$h.value } else { (T 'bench.noscore') })
        $ui.TxtBenchMeta.Text = (T 'bench.meta' $($shown.benchmarkVersion) $($shown.system.vmSize) $($shown.system.cpuModel) $($shown.system.vCpu) $($shown.system.ramGiB))
        if ($h.provisional) { $ui.BoxBenchProvisional.Visibility = 'Visible'; $ui.TxtBenchProvisional.Text = (T 'bench.provisional') }
        $base = Get-AVDTuneBenchmarkBaseline -Root $script:StateRoot
        $cmp = $null
        $cfg = Get-AVDTuneBenchmarkConfig
        $notes = @()
        if ($base -and $base.runId -ne $shown.runId) {
            $cmp = Compare-AVDTuneBenchmark -Current $shown -Baseline $base -Config $cfg
            if (-not $cmp.Comparable) { $notes += $cmp.Reason; $cmp = $null }
            else { $notes += @($cmp.Notes); if ($cmp.Host) { $ui.TxtBenchMeta.Text += ((T 'bench.againstbase') -f [double]$cmp.Host.DeltaPercent) } }
        }
        elseif (-not $base -and -not $script:BenchmarkOnly) { $notes += 'No baseline yet: the first full run of the initial analysis becomes the baseline.' }
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
    if ($results.Count -eq 0) { [void]$ui.PanelBenchHistory.Children.Add((New-Text (T 'bench.norun') 'Hint')) }
    $recent = @($results | Select-Object -Last 8); [array]::Reverse($recent)
    foreach ($r in $recent) {
        $t = New-Object System.Windows.Controls.TextBlock; $t.TextWrapping = 'Wrap'; $t.FontFamily = 'Cascadia Mono, Consolas'; $t.FontSize = 12; $t.Margin = '0,2,0,2'
        $t.Text = (T 'bench.historyrow') -f ([datetime]$r.started).ToLocalTime().ToString('yyyy-MM-dd HH:mm'), $r.mode, $r.kind, $(if ($null -ne $r.scores.host.value) { $r.scores.host.value } else { '-' })
        [void]$ui.PanelBenchHistory.Children.Add($t)
    }
    $ui.BoxBenchOnly.Visibility = ConvertTo-Vis ([bool]$script:BenchmarkOnly)
    $ui.BoxBenchCompare.Visibility = ConvertTo-Vis (-not $script:BenchmarkOnly)   # the comparison per image version belongs to a Golden Master
    if (-not $script:BenchmarkOnly) { Update-BenchCompareView }
    Update-BenchIntegrity
    if ($script:BenchmarkOnly) { Update-BenchShortcutRow }
}

# ---------------------------------------------------------------- integrity of the tool (Finn, #90): no start while the check runs or AVDTune is read only
function Get-BenchStartBlock {
    Get-AVDTuneBenchStartBlock -IntegrityRunning ([bool]($script:RelJob -and [string]$script:RelJob.Kind -in 'Start', 'Check')) -WriteBlock (Get-AVDTuneWriteBlock)
}
function Update-BenchIntegrity {
    # the result of the integrity check on this page too (in benchmark-only mode the Overview is hidden), with the repair when the release offers it
    $s = $script:Rel.Status
    $key = if ($s) { [string]$s.Status } else { 'running' }
    $block = Get-BenchStartBlock
    $text = T 'bench.rel.status' (T "rel.pill.$key") $(if ($s) { [string]$s.Message } else { T 'rel.comparing' })
    if ($block) { $text += "`r`n" + (T 'bench.rel.blocked' $block) }
    $repair = $ui.BtnRelRepair.Visibility -eq 'Visible'
    if ($block -and -not $repair -and $key -ne 'running') { $text += "`r`n" + (T 'bench.rel.hint') }
    if ($ui.TxtBenchIntegrity.Text -ne $text) { $ui.TxtBenchIntegrity.Text = $text }
    Set-Brush $ui.BoxBenchIntegrity ([System.Windows.Controls.Border]::BackgroundProperty) $(if ($block) { 'WarningBg' } else { 'Card' })
    $ui.BtnBenchRelRepair.Visibility = ConvertTo-Vis $repair
}
Add-Click $ui.BtnBenchRelRepair { $ui.BtnRelRepair.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) }
$script:Timer.Add_Tick({ try { if ($script:CurrentPage -eq 'Benchmark') { Update-BenchIntegrity } } catch { } })

# ---------------------------------------------------------------- desktop shortcut "AVDTune Benchmark" (#90): the launcher with -Benchmark, like AVDTune.lnk (#15)
function Update-BenchShortcutRow {
    $installed = (Get-ShortcutMode) -eq 'Installed'
    $link = $null; try { $link = Get-AVDTuneDesktopShortcut -Folder (Get-ShortcutDesktop) -InstallRoot $script:RelInstallRoot -Benchmark } catch { }
    $ui.BtnBenchShortcut.Content = $(if ($link) { T 'bench.sc.remove' } else { T 'bench.sc.create' })
    $ui.BtnBenchShortcut.IsEnabled = ($installed -or [bool]$link)
    $ui.TxtBenchShortcut.Text = if (-not $installed -and -not $link) { T 'sc.state.notinstalled' }
    elseif ($link -and -not $link.Matches) { T 'sc.state.wrong' $script:RelInstallRoot }
    elseif ($link) { T 'bench.sc.ok' }
    else { T 'sc.state.none' }
}
function Switch-BenchShortcut {
    $folder = Get-ShortcutDesktop
    if (Get-AVDTuneDesktopShortcut -Folder $folder -Benchmark) {
        [void](Remove-AVDTuneDesktopShortcut -Folder $folder -Benchmark)
        Add-RelProtocol 'Desktop shortcut AVDTune Benchmark removed' $folder
        Show-Toast (T 'sc.toast.removed')
    }
    else {
        $link = New-AVDTuneDesktopShortcut -InstallRoot $script:RelInstallRoot -Folder $folder -Benchmark
        Add-RelProtocol 'Desktop shortcut AVDTune Benchmark created' "$($link.Path) -> $($link.Target) $($link.Arguments) (run as administrator)"
        Show-Toast (T 'sc.toast.created')
    }
    Update-BenchShortcutRow
}
Add-Click $ui.BtnBenchShortcut { Switch-BenchShortcut }

# ---------------------------------------------------------------- comparison per image version (#90), comparison systems (plan 6b)
$script:BenchCompare = $null   # the comparison shown (exported as it is)
$script:BenchSmokeFile = $null   # test hook: the path the save or open dialog would give (only honoured in the smoke run)
function Select-BenchFile([switch]$Open, [string]$Title, [string]$Filter, [string]$FileName) {
    if ($script:SmokeOn) { return $script:BenchSmokeFile }   # no dialog on the developer's desktop
    $dlg = $(if ($Open) { New-Object Microsoft.Win32.OpenFileDialog } else { New-Object Microsoft.Win32.SaveFileDialog })
    $dlg.Title = $Title; $dlg.Filter = $Filter
    if (-not $Open) { $dlg.FileName = $FileName }
    if ($dlg.ShowDialog()) { $dlg.FileName } else { $null }
}
function Format-BenchDelta($Set) {
    # "Host +18.2 %, FSLogix +5.0 %" of a delta set; the parts that could not be compared are left out
    if (-not $Set) { return '' }
    $parts = @(foreach ($k in 'Host', 'Fslogix', 'Gpu', 'Capacity') { $d = $Set.$k; if ($d -and $null -ne $d.DeltaPercent) { '{0} {1:+0.0;-0.0;0.0} %' -f $(if ($k -eq 'Fslogix') { 'FSLogix' } elseif ($k -eq 'Gpu') { 'GPU' } else { $k }), [double]$d.DeltaPercent } })
    if ($parts.Count -eq 0 -and $Set.Note) { return (T 'bench.cmp.notcomparable') }
    $parts -join ', '
}
function New-BenchCompareRow($Row, [string]$Label) {
    # one line: light (color and word, not color alone), version or system, the scores, the changes
    $g = New-Object System.Windows.Controls.Grid; $g.Margin = '0,4,0,4'
    foreach ($w in 110, 170, '*') { $c = New-Object System.Windows.Controls.ColumnDefinition; $c.Width = $w; [void]$g.ColumnDefinitions.Add($c) }
    $pill = New-Object System.Windows.Controls.Border; Set-Brush $pill ([System.Windows.Controls.Border]::StyleProperty) 'Pill'; $pill.Padding = '10,2'; $pill.VerticalAlignment = 'Top'; $pill.HorizontalAlignment = 'Left'
    $kind = switch ($Row.Light) { 'red' { @('ErrorBg', 'Danger') } 'green' { @('SuccessBg', 'Success') } default { @('Hover', 'MutedText') } }
    Set-Brush $pill ([System.Windows.Controls.Border]::BackgroundProperty) $kind[0]
    $pt = New-Object System.Windows.Controls.TextBlock; $pt.Text = T "bench.cmp.light.$($Row.Light)"; $pt.FontSize = 12; $pt.FontWeight = 'SemiBold'
    Set-Brush $pt ([System.Windows.Controls.TextBlock]::ForegroundProperty) $kind[1]
    $pill.Child = $pt
    $name = New-Text $Label; $name.FontWeight = 'SemiBold'; $name.SetValue([System.Windows.Controls.Grid]::ColumnProperty, 1); $name.TextWrapping = 'Wrap'
    $n = { param($v) if ($null -eq $v) { '-' } else { ([double]$v).ToString('0.#', [Globalization.CultureInfo]::CurrentCulture) } }
    $lines = @(T 'bench.cmp.scores' (& $n $Row.HostScore) (& $n $Row.FslogixScore) (& $n $Row.GpuScore) (& $n $Row.CapacityUsers))
    if ($Row.PSObject.Properties['NewestVsThis']) { $d = Format-BenchDelta $Row.NewestVsThis; if ($d) { $lines += T 'bench.cmp.vssys' $d } }
    else {
        $d = Format-BenchDelta $Row.VsPrevious; if ($d) { $lines += T 'bench.cmp.vsprev' $Row.PreviousImageVersion $d }
        $d = Format-BenchDelta $Row.VsBaseline; if ($d) { $lines += T 'bench.cmp.vsbase' $d }
    }
    $detail = New-Text ($lines -join "`r`n"); $detail.TextWrapping = 'Wrap'; $detail.SetValue([System.Windows.Controls.Grid]::ColumnProperty, 2)
    [System.Windows.Automation.AutomationProperties]::SetName($g, "$Label, $($pt.Text)")
    foreach ($e in $pill, $name, $detail) { [void]$g.Children.Add($e) }
    $g
}
function Update-BenchCompareView {
    $cmp = Get-AVDTuneBenchmarkVersionComparison -Root $script:StateRoot
    $script:BenchCompare = $cmp
    $ui.TxtBenchCompareHint.Text = T 'bench.cmp.hint' $cmp.ThresholdPercent
    $ui.PanelBenchCompare.Children.Clear()
    if (@($cmp.Rows).Count -eq 0) { [void]$ui.PanelBenchCompare.Children.Add((New-Text (T 'bench.cmp.none') 'Hint')) }
    foreach ($r in @($cmp.Rows | Sort-Object { Get-AVDTuneVersionSortKey $_.ImageVersion } -Descending)) {   # newest version on top
        [void]$ui.PanelBenchCompare.Children.Add((New-BenchCompareRow $r $(if ($r.IsBaseline) { "$($r.ImageVersion) ($(T 'bench.cmp.base'))" } else { $r.ImageVersion })))
    }
    if (@($cmp.Systems).Count -gt 0) {
        $h = New-Text (T 'bench.cmp.systems'); $h.FontWeight = 'SemiBold'; $h.Margin = '0,10,0,2'
        [void]$ui.PanelBenchCompare.Children.Add($h)
        foreach ($s in @($cmp.Systems)) { [void]$ui.PanelBenchCompare.Children.Add((New-BenchCompareRow $s $s.SystemName)) }
    }
    $ui.TxtBenchCompareProblems.Visibility = ConvertTo-Vis (@($cmp.Problems).Count -gt 0)
    $ui.TxtBenchCompareProblems.Text = $(if (@($cmp.Problems).Count -gt 0) { T 'bench.cmp.problems' ((@($cmp.Problems) | Select-Object -First 5) -join '; ') } else { '' })
    $has = (@($cmp.Rows).Count + @($cmp.Systems).Count) -gt 0
    $ui.BtnBenchExportCsv.IsEnabled = $has; $ui.BtnBenchExportJson.IsEnabled = $has
}
function Export-BenchCompare([ValidateSet('Csv', 'Json')][string]$Format) {
    if (-not $script:BenchCompare) { Update-BenchCompareView }
    $ext = $Format.ToLowerInvariant()
    $path = Select-BenchFile -Title (T 'bench.cmp.dlg.export') -Filter "$Format (*.$ext)|*.$ext" -FileName "AVDTune-benchmark-comparison.$ext"
    if (-not $path) { return }
    [void](Export-AVDTuneBenchmarkComparison -Comparison $script:BenchCompare -Path $path -Format $Format)
    Show-Toast (T 'bench.cmp.exported' $path)
}
function Import-BenchSystem {
    $path = Select-BenchFile -Open -Title (T 'bench.cmp.dlg.import') -Filter 'JSON (*.json)|*.json'
    if (-not $path) { return }
    $row = Import-AVDTuneBenchmarkSystem -Root $script:StateRoot -Path $path
    [void](Add-AVDTuneProtocolNote -Protocol $script:Protocol -Group 'benchmark' -Subject "Comparison system imported: $($row.SystemName) ($($row.RunId))")
    Save-Protocol
    Update-BenchCompareView
    Show-Toast (T 'bench.cmp.imported' $row.SystemName)
}
function Export-BenchResultFile {
    $last = @(Get-AVDTuneBenchmarkResult -Root $script:StateRoot -Last)
    if ($last.Count -eq 0) { throw (T 'bench.only.noresult') }
    $safe = [regex]::Replace([string]$last[0].system.name, '[^A-Za-z0-9._-]', '-', [Text.RegularExpressions.RegexOptions]::None, [timespan]::FromMilliseconds(200))
    $path = Select-BenchFile -Title (T 'bench.only.dlg') -Filter 'JSON (*.json)|*.json' -FileName "AVDTune-benchmark-$safe-$($last[0].runId).json"
    if (-not $path) { return }
    [void](Export-AVDTuneBenchmarkResultFile -Root $script:StateRoot -RunId ([string]$last[0].runId) -Path $path)
    Show-Toast (T 'bench.only.exported' $path)
}
Add-Click $ui.BtnBenchExportCsv { Export-BenchCompare 'Csv' }
Add-Click $ui.BtnBenchExportJson { Export-BenchCompare 'Json' }
Add-Click $ui.BtnBenchImport { Import-BenchSystem }
Add-Click $ui.BtnBenchExportResult { Export-BenchResultFile }

# ---------------------------------------------------------------- benchmark-only mode (plan 6b)
# Start-AVDTune.ps1 -Benchmark, or "Benchmark only" in the sign-in step of the first start: no setup, no sign-in, no snapshot gate, only the Benchmark page and the protocol.
# The benchmark needs no write gate (it changes nothing permanent; its quiet mode has its own journal and undo); every other page stays hidden (Show-Page refuses them).
function Enter-BenchmarkOnlyMode {
    $script:BenchmarkOnly = $true
    if ($script:OpenStage) { Close-Stage }
    Update-NavVisibility
    Show-Page 'Benchmark'
    $ui.NavBenchmark.IsChecked = $true
    [void](Add-AVDTuneProtocolNote -Protocol $script:Protocol -Group 'benchmark' -Subject 'Benchmark only: setup and sign-in skipped')
    Save-Protocol
}

function Start-BenchRun([string]$Mode) {
    $block = Get-BenchStartBlock
    if ($block) { Update-BenchIntegrity; throw (T 'bench.rel.refused' $block) }   # before any question (Finn, #90)
    $name = ''; $notes = ''
    if ($script:BenchmarkOnly) {
        $name = ([string]$ui.TxtBenchSystemName.Text).Trim(); $notes = ([string]$ui.TxtBenchSystemNotes.Text).Trim()
        $lp = @(Test-AVDTuneBenchmarkLabel -Name $name -Notes $notes)
        if ($lp.Count -gt 0) { throw (T 'bench.only.err.name' ($lp -join '; ')) }
    }
    $ask = if ($Mode -eq 'Full') { 'Start a full benchmark (about 17 minutes)? Windows Update and the indexer are paused and started again. Nobody else may be signed in.' } else { 'Start a quick benchmark (about 3 minutes)? It is not compared with full runs.' }
    if (-not (Confirm-Action $ask 'Benchmark')) { return }
    $state = Get-AVDTuneState $script:StateRoot
    $kind = if ($script:BenchmarkOnly) { 'benchmark-only' } elseif (-not (Get-AVDTuneProp $state 'BaselineBenchmark') -and $Mode -eq 'Full') { 'baseline' } else { 'manual' }
    $ui.TxtBenchState.Text = (T 'task.bar.starting'); $ui.BarBench.Value = 0
    Start-BenchJob $Mode $kind $name $notes
}
Add-Click $ui.BtnBenchFull { Start-BenchRun 'Full' }
Add-Click $ui.BtnBenchQuick { Start-BenchRun 'Quick' }
function Start-BenchRepair {
    Assert-NoOtherWriter -AllowSealed   # the repair (also after the finish, #50) changes the master (Windows Update, indexer): never next to another writer (#66)
    $r = Invoke-UiTaskInline -Kind 'benchmark-repair' -Title 'Restoring Windows Update and the indexer' -Step 'Putting back what the benchmark paused' -Writer -AllowSealed -Block {
        $m = $script:Machine
        $b = $(if ($script:TestMode) { . $script:BenchFakeScript; New-AVDTuneFakeBench -Reference (Get-AVDTuneBenchmarkReference) -Config (Get-AVDTuneBenchmarkConfig) } else { New-AVDTuneBenchAdapter })
        Repair-AVDTuneBenchmarkCrash -Machine $m -Bench $b -Root $script:StateRoot -User ([string]$env:USERNAME)
    }
    Show-Toast $r.Message
    Update-BenchmarkView
}
Add-Click $ui.BtnBenchRepair { Start-BenchRepair }
