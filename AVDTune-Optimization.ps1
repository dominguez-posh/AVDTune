# The Optimization page (dot-sourced by Start-AVDTune.ps1): the selectable optimization list of docs\plans\avdtune.md, section 5d.
# Logic and data: Modules\AVDTune.Optimization.psm1 and data\optimization.json. This file only draws the list and starts Apply and Undo.
# The page is built in code and put next to the other pages, so UI\AVDTune.xaml stays untouched. Reading the state changes nothing; Apply and Undo need the open
# write gate and a confirmation, and an AppX removal (cannot be undone) needs its own second confirmation. They run on the window thread (short; the bar shows the task).

if ($script:TestMode) {
    # Test mode: the fake machine gets the AppX, Defender and registry detail members of the list (the real ones are added by the module, only to a real machine)
    . (Get-TestScript 'FakeOptimization.ps1')
    if ($null -eq $script:Machine.PSObject.Properties['AppxState']) { Add-AVDTuneOptimizationFakeMembers -Machine $script:Machine -Appx @('Microsoft.BingNews') }
}

$script:OptStatus = $null
$script:OptChecked = @{}        # id -> $true / $false; filled from the defaults of the data file at the first view
$script:OptInputs = @{}         # id -> text the administrator entered for an entry with an input (#41: the UNC path of the shared security intelligence); memory only
$script:OptInitDone = $false
$script:OptOnlyOpen = $false
$script:OptBuilding = $false
$script:OptStale = $false         # the last read failed: the list is older than the master
$script:OptRun = $null           # the background Apply or Undo (one at a time)
$script:OptJob = $null           # the background read of the state (one at a time)

function New-OptPill([string]$Text, [string]$Back, [string]$Fore) {
    $pill = New-Object System.Windows.Controls.Border
    Set-Brush $pill ([System.Windows.Controls.Border]::StyleProperty) 'Pill'; $pill.Padding = '8,1'; $pill.Margin = '8,0,0,0'; $pill.VerticalAlignment = 'Center'
    Set-Brush $pill ([System.Windows.Controls.Border]::BackgroundProperty) $Back
    $t = New-Object System.Windows.Controls.TextBlock; $t.Text = $Text; $t.FontSize = 11; $t.FontWeight = 'SemiBold'; Set-Brush $t ([System.Windows.Controls.TextBlock]::ForegroundProperty) $Fore
    $pill.Child = $t; $pill
}

function Initialize-OptPage {
    $pageHost = $ui.PagePlaceholder.Parent
    $page = New-Object System.Windows.Controls.Grid
    $page.Name = 'PageOptimization'; $page.Visibility = 'Collapsed'
    $scroll = New-Object System.Windows.Controls.ScrollViewer; Set-Brush $scroll ([System.Windows.Controls.ScrollViewer]::StyleProperty) 'PageScroll'
    $stack = New-Object System.Windows.Controls.StackPanel; $stack.Margin = '40,32,40,28'; $stack.MaxWidth = 1000; $stack.HorizontalAlignment = 'Left'
    # head: title, subtitle and the two buttons
    $head = New-Object System.Windows.Controls.Grid
    foreach ($h in 'Auto', 'Auto') { $r = New-Object System.Windows.Controls.RowDefinition; $r.Height = $h; [void]$head.RowDefinitions.Add($r) }
    foreach ($w in '*', 'Auto') { $c = New-Object System.Windows.Controls.ColumnDefinition; $c.Width = $w; [void]$head.ColumnDefinitions.Add($c) }
    $title = New-Text 'Optimization' 'PageTitle'
    $sub = New-Text 'Settings for a multi-session master, from the data of the Windows Desktop Optimization Tool (WDOT) and the Microsoft Defender preset for VDI. Nothing is applied until you select entries and press Apply. Each entry has its reason, risk and source; changes can be undone, except AppX removal.' 'Subtitle'
    $sub.SetValue([System.Windows.Controls.Grid]::RowProperty, 1); $sub.SetValue([System.Windows.Controls.Grid]::ColumnSpanProperty, 2)
    $btns = New-Object System.Windows.Controls.StackPanel; $btns.Orientation = 'Horizontal'; $btns.VerticalAlignment = 'Center'; $btns.Margin = '24,0,0,0'; $btns.SetValue([System.Windows.Controls.Grid]::ColumnProperty, 1)
    $undo = New-Object System.Windows.Controls.Button; $undo.Content = 'Undo selected'; $undo.Margin = '0,0,8,0'; [System.Windows.Automation.AutomationProperties]::SetName($undo, 'Undo the selected optimizations')
    $apply = New-Object System.Windows.Controls.Button; $apply.Content = 'Apply selected'; Set-Brush $apply ([System.Windows.Controls.Button]::StyleProperty) 'PrimaryButton'; [System.Windows.Automation.AutomationProperties]::SetName($apply, 'Apply the selected optimizations to this master')
    foreach ($b in $undo, $apply) { [void]$btns.Children.Add($b) }
    foreach ($e in $title, $sub, $btns) { [void]$head.Children.Add($e) }
    [void]$stack.Children.Add($head)
    # data problems (the whole file is refused on any error)
    $errBox = New-Object System.Windows.Controls.Border; Set-Brush $errBox ([System.Windows.Controls.Border]::StyleProperty) 'CardBox'; Set-Brush $errBox ([System.Windows.Controls.Border]::BackgroundProperty) 'ErrorBg'; $errBox.Padding = '20,12'; $errBox.Margin = '0,16,0,0'; $errBox.Visibility = 'Collapsed'
    $errText = New-Text '' $null; Set-Brush $errText ([System.Windows.Controls.TextBlock]::ForegroundProperty) 'Danger'; $errBox.Child = $errText
    [void]$stack.Children.Add($errBox)
    # card: presets, filter, summary
    $card = New-Object System.Windows.Controls.Border; Set-Brush $card ([System.Windows.Controls.Border]::StyleProperty) 'CardBox'; Set-Brush $card ([System.Windows.Controls.Border]::BackgroundProperty) 'Card'; $card.Padding = '20,16'; $card.Margin = '0,16,0,0'
    $cardStack = New-Object System.Windows.Controls.StackPanel
    [void]$cardStack.Children.Add((New-Text 'Selection' 'CardTitle'))
    $presetRow = New-Object System.Windows.Controls.WrapPanel; $presetRow.Margin = '0,10,0,0'
    $presetButtons = @{}
    foreach ($p in @(@('recommended', 'AVD multi-session (recommended)'), @('conservative', 'Conservative'), @('all', 'Everything'), @('none', 'Nothing'))) {
        $b = New-Object System.Windows.Controls.Button; $b.Content = $p[1]; $b.Margin = '0,0,8,6'; $b.DataContext = $p[0]; [System.Windows.Automation.AutomationProperties]::SetName($b, "Select the preset $($p[1])")
        $b.Tag = [string]$p[1]; [void]$presetRow.Children.Add($b); $presetButtons[$p[0]] = $b   # Tag: the label without the status
    }
    $refresh = New-Object System.Windows.Controls.Button; $refresh.Content = 'Refresh state'; $refresh.Margin = '16,0,8,6'; [System.Windows.Automation.AutomationProperties]::SetName($refresh, 'Read the state of the list again')
    [void]$presetRow.Children.Add($refresh)
    [void]$cardStack.Children.Add($presetRow)
    $only = New-Object System.Windows.Controls.CheckBox; $only.Content = 'Show only entries that are not in place yet'; $only.Margin = '0,4,0,0'
    [void]$cardStack.Children.Add($only)
    $summary = New-Text '' 'Hint' '0,10,0,0'
    [void]$cardStack.Children.Add($summary)
    $card.Child = $cardStack; [void]$stack.Children.Add($card)
    # the list
    $listCard = New-Object System.Windows.Controls.Border; Set-Brush $listCard ([System.Windows.Controls.Border]::StyleProperty) 'CardBox'; Set-Brush $listCard ([System.Windows.Controls.Border]::BackgroundProperty) 'Card'; $listCard.Padding = '20,16'; $listCard.Margin = '0,16,0,0'
    $listStack = New-Object System.Windows.Controls.StackPanel
    $list = New-Object System.Windows.Controls.StackPanel; $list.Margin = '0,6,0,0'
    [void]$listStack.Children.Add((New-Text 'Entries' 'CardTitle')); [void]$listStack.Children.Add($list)
    $notes = New-Text '' 'Hint' '0,12,0,0'; [void]$listStack.Children.Add($notes)
    $listCard.Child = $listStack; [void]$stack.Children.Add($listCard)
    $scroll.Content = $stack; $page.Children.Add($scroll) | Out-Null
    [void]$pageHost.Children.Add($page)
    $ui.PageOptimization = $page; $ui.PanelOptList = $list; $ui.TxtOptSummary = $summary; $ui.TxtOptNotes = $notes; $ui.BoxOptErrors = $errBox; $ui.TxtOptErrors = $errText
    $ui.BtnOptApply = $apply; $ui.BtnOptUndo = $undo; $ui.BtnOptRefresh = $refresh; $ui.ChkOptOnlyOpen = $only; $ui.OptPresets = $presetButtons
}
Initialize-OptPage

function Set-OptBusy([bool]$Busy) {
    # while the state is read: no Apply, no Undo, no second read (the buttons follow the data again in Show-OptList)
    $ui.BtnOptRefresh.IsEnabled = -not $Busy
    Update-OptPresetStatus
    if ($Busy) { $ui.BtnOptApply.IsEnabled = $false; $ui.BtnOptUndo.IsEnabled = $false }
}
function Start-OptRead {
    # Reads the state of the list in the background (services, tasks, Defender and AppX of all users take long on a real master; on the window thread the
    # page looked frozen). Read only. One read at a time: a new request while one runs does nothing. The window does not wait for it when it closes.
    if ($script:OptJob -or $script:OptRun) { return }
    $task = Start-AVDTuneUiTask -Kind 'optimization-read' -Title 'Reading the optimization state' -Step 'Reading services, tasks, Defender, AppX and registry values of the master' -Retry @{ Command = 'Start-OptRead'; Arguments = @() }
    if ($script:TestMode) {
        # Test mode runs on the window thread at the next timer tick: the fake machine is a closure of this runspace and must not run on a second thread while this one executes script
        $script:OptJob = @{ Inline = $true; Task = $task }
    }
    else {
        $ps = New-AVDTunePowerShell
        [void]$ps.AddScript({
                param($AppRoot, $Root)
                $ErrorActionPreference = 'Stop'
                Import-Module (Join-Path $AppRoot 'Modules\AVDTune.psm1') -Force
                Import-Module (Join-Path $AppRoot 'Modules\AVDTune.Optimization.psm1') -Force
                Get-AVDTuneOptimizationStatus -Machine (New-AVDTuneMachine) -Root $Root
            }).AddArgument($script:AppRoot).AddArgument($script:StateRoot)
        $script:OptJob = @{ PS = $ps; Handle = $ps.BeginInvoke(); Task = $task }
    }
    Set-OptBusy $true
    if ($script:CurrentPage -eq 'Optimization') { Show-OptList }
}
function Complete-OptRead {
    $job = $script:OptJob
    if (-not $job) { return }
    if ($job.Inline) { if ($script:OverviewJob) { return } }   # test mode: not while the overview reads the same fake machine on its own thread
    elseif (-not $job.Handle.IsCompleted) { return }
    $script:OptJob = $null
    $status = $null; $err = ''; $streamErr = ''
    if ($job.Inline) {
        try { $status = Get-AVDTuneOptimizationStatus -Machine $script:Machine -Root $script:StateRoot } catch { $err = $_.Exception.Message }
    }
    else {
        try {
            $status = @($job.PS.EndInvoke($job.Handle)) | Select-Object -Last 1
            if ($job.PS.Streams.Error.Count -gt 0) { $streamErr = $job.PS.Streams.Error[0].Exception.Message }
        }
        catch { $err = $_.Exception.Message }
        finally { $job.PS.Dispose() }
    }
    if (-not $status -and -not $err) { $err = $(if ($streamErr) { $streamErr } else { 'No result.' }) }
    if (-not $err) {
        $script:OptStatus = $status; $script:OptStale = $false
        if ($status.DataValid -and -not $script:OptInitDone) {
            foreach ($r in $status.Rows) { $script:OptChecked[$r.Id] = [bool]$r.Default }
            $script:OptInitDone = $true
        }
        Complete-AVDTuneUiTask $job.Task -Summary $(if ($status.DataValid) { "$($status.Rows.Count) entries read" } else { 'The optimization data is not valid' })
    }
    else { Complete-AVDTuneUiTask $job.Task -Failed -Summary "The state could not be read: $err"; if ($script:OptStatus) { $script:OptStale = $true } }   # the list on screen is older than the master: nothing can be applied from it
    Set-OptBusy $false
    if ($script:CurrentPage -eq 'Optimization') {
        Show-OptList
        if ($err) { $ui.TxtOptSummary.Text = "The state could not be read: $err $(if ($script:OptStatus) { 'The list shows the earlier state; Apply and Undo wait for a successful read.' }) Press Refresh state to try again."; Show-Error "The optimization state could not be read: $err" }
    }
}
$script:Timer.Add_Tick({ try { Complete-OptRead } catch { Show-Error $_.Exception.Message } })

function Set-OptPreset([string]$Name) {
    if (-not $script:OptStatus -or -not $script:OptStatus.DataValid) { return }
    $ids = if ($Name -eq 'none') { @() } else { @(Get-AVDTuneOptimizationPresetIds -Entries $script:OptStatus.Rows -Preset $Name) }
    foreach ($r in $script:OptStatus.Rows) { $script:OptChecked[$r.Id] = ($r.Id -in $ids) }
    Show-OptList
}

function Get-OptSelectedRows {
    if (-not $script:OptStatus -or -not $script:OptStatus.DataValid) { return @() }
    @($script:OptStatus.Rows | Where-Object { $script:OptChecked[$_.Id] -and $_.Present })
}

function Update-OptPresetStatus {
    # The three presets say whether their set is in place on this host: green with a check when every entry of the set is in place (entries that are not on this host count
    # as in place), otherwise neutral with "x of y in place". Nothing while the state is being read or run, or when the data is not valid. "Nothing" has no status.
    $st = $script:OptStatus
    $show = [bool]($st -and $st.DataValid -and -not $script:OptJob -and -not $script:OptRun -and -not $script:OptStale)
    foreach ($name in 'recommended', 'conservative', 'all') {
        $b = $ui.OptPresets[$name]; $label = [string]$b.Tag
        $b.ClearValue([System.Windows.Controls.Button]::ForegroundProperty)
        if (-not $show) { $b.Content = $label; $b.ToolTip = $null; continue }
        $ids = @(Get-AVDTuneOptimizationPresetIds -Entries $st.Rows -Preset $name)
        $rows = @($st.Rows | Where-Object { $_.Id -in $ids })
        $here = @($rows | Where-Object { $_.Present })
        $away = $rows.Count - $here.Count
        $done = @($here | Where-Object { $_.Compliant }).Count + $away   # entries that are not on this host count as in place
        $awayText = $(if ($away -gt 0) { " $away of them $(if ($away -eq 1) { 'is' } else { 'are' }) not on this host (counted as in place)." } else { '' })
        # green only when at least one entry of the set is on this host and every entry that is, is in place (a set that is all "not on this host" says nothing)
        if ($here.Count -gt 0 -and $done -eq $rows.Count) {
            $b.Content = "$label  $([char]0x2713) in place"; Set-Brush $b ([System.Windows.Controls.Button]::ForegroundProperty) 'Success'
            $b.ToolTip = "All $($rows.Count) entries of this set are in place.$awayText"
        }
        else {
            $b.Content = "$label  ($done of $($rows.Count) in place)"
            $b.ToolTip = "$done of $($rows.Count) entries of this set are in place.$awayText"
        }
    }
}

function Show-OptList {
    $st = $script:OptStatus
    Update-OptPresetStatus
    $script:OptBuilding = $true
    try {
        $ui.PanelOptList.Children.Clear(); $ui.OptInputBoxes = @{}
        $ui.BoxOptErrors.Visibility = ConvertTo-Vis ($st -and -not $st.DataValid)
        if (-not $st) { $ui.TxtOptSummary.Text = $(if ($script:OptJob) { 'Reading the state of the master ...' } else { '' }); $ui.BtnOptApply.IsEnabled = $false; $ui.BtnOptUndo.IsEnabled = $false; return }
        if (-not $st.DataValid) {
            $ui.TxtOptErrors.Text = "The optimization data is not valid, so nothing can be applied. " + (@($st.DataErrors | Select-Object -First 6) -join "`r`n")
            $ui.TxtOptSummary.Text = ''; $ui.BtnOptApply.IsEnabled = $false; $ui.BtnOptUndo.IsEnabled = $false
            return
        }
        $ui.BtnOptApply.IsEnabled = -not ($script:OptJob -or $script:OptRun -or $script:OptStale); $ui.BtnOptUndo.IsEnabled = -not ($script:OptJob -or $script:OptRun -or $script:OptStale)
        $pillStyle = @{ Low = @('SuccessBg', 'Success'); Medium = @('WarningBg', 'Warning'); High = @('ErrorBg', 'Danger') }
        foreach ($cat in (Get-AVDTuneOptimizationCategoryOrder)) {
            $rows = @($st.Rows | Where-Object { $_.Category -eq $cat })
            if ($rows.Count -eq 0) { continue }
            $open = @($rows | Where-Object { $_.Present -and -not $_.Compliant })
            $shown = if ($script:OptOnlyOpen) { $open } else { $rows }
            if ($shown.Count -eq 0) { continue }
            [void]$ui.PanelOptList.Children.Add((New-UpdGroupHead "$(Get-AVDTuneOptimizationCategoryLabel $cat)  ($($open.Count) of $($rows.Count) not in place)"))
            foreach ($r in $shown) {
                $g = New-Object System.Windows.Controls.Grid; $g.Margin = '0,5,0,5'
                foreach ($w in 28, '*', 190) { $c = New-Object System.Windows.Controls.ColumnDefinition; $c.Width = $w; [void]$g.ColumnDefinitions.Add($c) }
                $chk = New-Object System.Windows.Controls.CheckBox; $chk.VerticalAlignment = 'Top'; $chk.Margin = '0,3,0,0'; $chk.DataContext = [string]$r.Id
                $chk.IsEnabled = [bool]$r.Present; $chk.IsChecked = [bool]($r.Present -and $script:OptChecked[$r.Id])
                [System.Windows.Automation.AutomationProperties]::SetName($chk, "Select $($r.Title)")
                $chk.Add_Click({ param($s) $script:OptChecked[[string]$s.DataContext] = [bool]$s.IsChecked; Update-OptSummary })
                $mid = New-Object System.Windows.Controls.StackPanel; $mid.SetValue([System.Windows.Controls.Grid]::ColumnProperty, 1); $mid.Margin = '0,0,12,0'
                $line = New-Object System.Windows.Controls.WrapPanel
                $t = New-Object System.Windows.Controls.TextBlock; $t.Text = [string]$r.Title; $t.FontWeight = 'SemiBold'; $t.TextWrapping = 'Wrap'; $t.VerticalAlignment = 'Center'
                [void]$line.Children.Add($t)
                $rp = $pillStyle[[string]$r.Risk]
                [void]$line.Children.Add((New-OptPill "Risk: $($r.Risk)" $rp[0] $rp[1]))
                if ($r.Irreversible) { [void]$line.Children.Add((New-OptPill 'Cannot be undone' 'ErrorBg' 'Danger')) }
                if ($r.Reboot) { [void]$line.Children.Add((New-OptPill 'Needs restart' 'Hover' 'MutedText')) }
                if ($r.Default) { [void]$line.Children.Add((New-OptPill 'Default on' 'AccentSubtle' 'Primary')) }
                [void]$mid.Children.Add($line)
                [void]$mid.Children.Add((New-Text ([string]$r.Why) 'Hint' '0,3,0,0'))
                if ([string]$r.Input -eq 'UncPath') {
                    # #41: the share is an input; prefilled with the path that is set now; checked (format here, readability in the run) when Apply is pressed
                    if (-not $script:OptInputs.ContainsKey([string]$r.Id) -and (Test-AVDTuneUncPath ([string]$r.State))) { $script:OptInputs[[string]$r.Id] = [string]$r.State }
                    $inLine = New-Object System.Windows.Controls.StackPanel; $inLine.Orientation = 'Horizontal'; $inLine.Margin = '0,6,0,0'
                    $inLbl = New-Text 'Share (UNC):' $null '0,0,8,0'; $inLbl.VerticalAlignment = 'Center'
                    $tb = New-Object System.Windows.Controls.TextBox; $tb.Width = 380; $tb.MaxLength = 260; $tb.DataContext = [string]$r.Id; $tb.Text = [string]$script:OptInputs[[string]$r.Id]
                    [System.Windows.Automation.AutomationProperties]::SetName($tb, "UNC path for $($r.Title)"); $tb.ToolTip = '\\server\share\folder - no user name or password: the share is read with the logon of this session'
                    $tb.Add_TextChanged({ param($s) $script:OptInputs[[string]$s.DataContext] = [string]$s.Text.Trim() })
                    $ui.OptInputBoxes[[string]$r.Id] = $tb
                    foreach ($x in $inLbl, $tb) { [void]$inLine.Children.Add($x) }
                    [void]$mid.Children.Add($inLine)
                }
                $src = New-Text "Source: $($r.Source)" 'Hint' '0,2,0,0'; [void]$mid.Children.Add($src)
                $stateText = if ($r.Failed) { "Cannot be read: $($r.Message)" } else { [string]$r.State }
                $sp = New-Object System.Windows.Controls.StackPanel; $sp.SetValue([System.Windows.Controls.Grid]::ColumnProperty, 2)
                $k = if (-not $r.Present) { @('Hover', 'MutedText', 'Not on this host') } elseif ($r.Failed) { @('ErrorBg', 'Danger', 'Problem') } elseif ($r.Compliant) { @('SuccessBg', 'Success', 'In place') } else { @('WarningBg', 'Warning', 'Not in place') }
                $pill = New-OptPill $k[2] $k[0] $k[1]; $pill.Margin = '0'; $pill.HorizontalAlignment = 'Left'
                [void]$sp.Children.Add($pill)
                $stT = New-Text $stateText $null '0,3,0,0'; Set-Brush $stT ([System.Windows.Controls.TextBlock]::ForegroundProperty) 'MutedText'; [void]$sp.Children.Add($stT)
                if ($r.HasBackup) { [void]$sp.Children.Add((New-Text 'Undo is possible' 'Hint' '0,2,0,0')) }
                foreach ($e in $chk, $mid, $sp) { [void]$g.Children.Add($e) }
                [void]$ui.PanelOptList.Children.Add($g)
            }
        }
        $ui.TxtOptNotes.Text = 'The state is read from this master (Refresh state reads it again). An entry that is not on this host, such as a service or task that does not exist on this build, cannot be selected. Undo is offered where AVDTune saved the value that was there before; it restores that value and does not turn back anything AVDTune did not set. A service that was set to "Automatic (delayed start)" comes back as "Automatic". Apply and Undo run on the window thread and can take a while with many entries.'
    }
    finally { $script:OptBuilding = $false }
    Update-OptSummary
}

function Update-OptSummary {
    $st = $script:OptStatus
    if (-not $st -or -not $st.DataValid) { return }
    if ($script:OptJob -or $script:OptRun) { $ui.TxtOptSummary.Text = $(if ($script:OptRun) { 'Running ...' } else { 'Reading the state of the master ...' }); return }
    $sel = @(Get-OptSelectedRows)
    $open = @($sel | Where-Object { -not $_.Compliant })
    $irr = @($open | Where-Object { $_.Irreversible })
    $src = @($st.Sources | Where-Object { $_.Id -eq 'wdot' })[0]
    $ui.TxtOptSummary.Text = "$($st.Rows.Count) entries; $(@($st.Rows | Where-Object { $_.Present -and $_.Compliant }).Count) already in place. Selected: $($sel.Count), of which $($open.Count) would change something$(if ($irr.Count -gt 0) { " ($($irr.Count) AppX removal(s) that cannot be undone)" })." +
        $(if ($src) { " Data based on $($src.Name), $($src.License) licence, $($src.Copyright)." } else { '' }) + $(if ($st.BackupError) { " $($st.BackupError)" } else { '' })
}

function Update-OptView {
    $ui.ChkOptOnlyOpen.IsChecked = $script:OptOnlyOpen
    if ((-not $script:OptStatus -or $script:OptStale) -and -not $script:OptJob -and -not $script:OptRun) { Start-OptRead }   # the page is there at once; the rows follow when the read is done
    Show-OptList
}

function Start-OptChange([string]$Mode) {
    if ($script:OptJob) { throw 'The state of the master is still being read. Wait until it is done.' }
    if ($script:OptRun) { throw 'Another optimization run is still running.' }
    if ($script:OptStale) { throw 'The last read of the state failed, so the list may be out of date. Press Refresh state first.' }
    Assert-NoOtherWriter
    if (-not (Test-AVDTuneWriteAllowed)) { throw 'Read only: confirm a snapshot of today on the Overview first.' }
    $st = $script:OptStatus
    if (-not $st -or -not $st.DataValid) { throw 'The optimization data is not valid; nothing can be applied.' }
    $sel = @(Get-OptSelectedRows)
    if ($Mode -eq 'Undo') {
        $skip = @($sel | Where-Object { $_.Irreversible })
        $sel = @($sel | Where-Object { -not $_.Irreversible })
    }
    else { $sel = @($sel | Where-Object { -not $_.Compliant -or ([string]$_.Input -eq 'UncPath' -and (ConvertTo-OptUncCompare ([string]$script:OptInputs[[string]$_.Id])) -ne (ConvertTo-OptUncCompare ([string]$_.State))) }); $skip = @() }
    # #41: the value of an entry with an input; its format is checked here, whether the share can be read in the run
    $inputs = @{}
    if ($Mode -eq 'Apply') {
        foreach ($r in @($sel | Where-Object { [string]$_.Input -eq 'UncPath' })) {
            $v = [string]$script:OptInputs[[string]$r.Id]
            if (-not (Test-AVDTuneUncPath $v)) { throw "Enter the share for '$($r.Title)' as a UNC path like \\server\share\folder (no user name or password). Nothing was changed." }
            $inputs[[string]$r.Id] = $v
        }
    }
    if ($sel.Count -eq 0) { Show-Toast $(if ($Mode -eq 'Undo') { 'Nothing selected that can be undone.' } else { 'Nothing selected that is not in place yet.' }); return }
    $irr = @($sel | Where-Object { $_.Irreversible })
    $reboot = @($sel | Where-Object { $_.Reboot }).Count
    $high = @($sel | Where-Object { $_.Risk -eq 'High' })
    $ask = "$(if ($Mode -eq 'Undo') { 'Undo' } else { 'Apply' }) $($sel.Count) optimization(s) on this master?" +
        $(if ($high.Count -gt 0) { "`n$($high.Count) of them have risk High: " + (@($high | Select-Object -First 3 | ForEach-Object { $_.Title }) -join '; ') }) +
        $(if ($reboot -gt 0 -and $Mode -eq 'Apply') { "`n$reboot need a restart to take effect." }) +
        $(if ($skip.Count -gt 0) { "`n$($skip.Count) AppX removal(s) in the selection cannot be undone and are left out." }) +
        $(if ($inputs.Count -gt 0) { "`nShare for the Defender updates: " + (@($inputs.Values) -join ', ') + ' (checked for readability first; nothing is set if it cannot be read).' }) +
        "`nThe value that is there now is saved first so each entry can be undone (not AppX)."
    if (-not (Confirm-Action $ask 'Optimization')) { return }
    $confirmIrr = $false
    if ($irr.Count -gt 0) {
        $names = (@($irr | Select-Object -First 6 | ForEach-Object { $_.Title -replace '^Remove app: ', '' }) -join ', ') + $(if ($irr.Count -gt 6) { ", and $($irr.Count - 6) more" })
        if (-not (Confirm-Action "$($irr.Count) AppX package(s) will be REMOVED for all users and from the provisioning list: $names.`n`nThis cannot be undone. They come back only with a reset, a new image or a re-install from the Store. Remove them?" 'Optimization: cannot be undone')) { return }
        $confirmIrr = $true
    }
    $ids = @($sel | ForEach-Object { $_.Id })
    $user = [string]$env:USERNAME
    $gate = Get-AVDTuneWriteGate
    Start-OptRun $Mode $ids $confirmIrr $user $gate $inputs
}

function Start-OptRun([string]$Mode, [string[]]$Ids, [bool]$ConfirmIrr, [string]$User, $Gate, [hashtable]$Inputs = @{}) {
    # Apply or Undo as a task in the background (the work of an entry, Defender and AppX removal included, no longer blocks the window). The confirmations are
    # done before. The window stays open until the run is done (closing handler below), like for the other operations that change the master.
    Assert-NoOtherWriter   # every start of a writer job asks the central check (#50/#66 review)
    if ($script:OptRun) { throw 'Another optimization run is still running.' }
    $label = if ($Mode -eq 'Undo') { 'Undoing optimizations' } else { 'Applying optimizations' }
    $task = Start-AVDTuneUiTask -Kind 'optimization' -Title $label -Step "$($Ids.Count) entries"   # no Retry: it changes the master and starts only after its confirmation
    if ($script:TestMode) { $script:OptRun = @{ Inline = $true; Task = $task; Mode = $Mode; Ids = $Ids; ConfirmIrr = $ConfirmIrr; User = $User; Gate = $Gate; Inputs = $Inputs } }
    else {
        $ps = New-AVDTunePowerShell
        [void]$ps.AddScript({
                param($AppRoot, $Root, $Ids, $Mode, $ConfirmIrr, $User, $Gate, $Inputs)
                $ErrorActionPreference = 'Stop'
                Import-Module (Join-Path $AppRoot 'Modules\AVDTune.psm1') -Force
                Import-Module (Join-Path $AppRoot 'Modules\AVDTune.Optimization.psm1') -Force
                if ($Gate) { Open-AVDTuneWriteGate -SnapshotId $Gate.SnapshotId -ConfirmedBy $Gate.ConfirmedBy }
                Invoke-AVDTuneOptimization -Machine (New-AVDTuneMachine) -Root $Root -Ids $Ids -Mode $Mode -ConfirmIrreversible:$ConfirmIrr -User $User -SnapshotId $Gate.SnapshotId -Inputs $Inputs
            }).AddArgument($script:AppRoot).AddArgument($script:StateRoot).AddArgument($Ids).AddArgument($Mode).AddArgument($ConfirmIrr).AddArgument($User).AddArgument($Gate).AddArgument($Inputs)
        $script:OptRun = @{ PS = $ps; Handle = $ps.BeginInvoke(); Task = $task; Mode = $Mode }
    }
    Set-OptBusy $true
    Set-ShutdownBlock $true   # log off and shut down wait for the run, like for the other operations
    Show-OptList
}
function Complete-OptRun {
    $job = $script:OptRun
    if (-not $job) { return }
    if ($job.Inline) { if ($script:OverviewJob) { return } }
    elseif (-not $job.Handle.IsCompleted) { return }
    $script:OptRun = $null
    $result = $null; $err = ''; $streamErr = ''
    if ($job.Inline) {
        try { $result = Invoke-AVDTuneOptimization -Machine $script:Machine -Root $script:StateRoot -Ids $job.Ids -Mode $job.Mode -ConfirmIrreversible:$job.ConfirmIrr -User $job.User -SnapshotId $job.Gate.SnapshotId -Inputs $(if ($job.Inputs) { $job.Inputs } else { @{} }) } catch { $err = $_.Exception.Message }
    }
    else {
        try {
            $result = @($job.PS.EndInvoke($job.Handle)) | Select-Object -Last 1
            if ($job.PS.Streams.Error.Count -gt 0) { $streamErr = $job.PS.Streams.Error[0].Exception.Message }
        }
        catch { $err = $_.Exception.Message }
        finally { $job.PS.Dispose() }
    }
    # a result that is there is always evaluated (the run may have changed things); an error of the stream is reported in addition (#66)
    if (-not $result -and -not $err) { $err = $(if ($streamErr) { $streamErr } else { 'No result.' }) }
    Set-OptBusy $false
    Set-ShutdownBlock $false
    if ($err -and $result) { $streamErr = $err; $err = '' }
    if ($err) {
        Complete-AVDTuneUiTask $job.Task -Failed -Summary "Optimization $($job.Mode.ToLowerInvariant()) failed: $err"
        Show-Error "Optimization $($job.Mode.ToLowerInvariant()) failed: $err"
    }
    else {
        foreach ($r in $result.Results) { Register-StepResult $r }
        $text = "Optimization $($job.Mode.ToLowerInvariant()): $($result.Changed) change(s)$(if ($result.Failed -gt 0) { ", $($result.Failed) failed" })$(if ($result.Skipped -gt 0) { ", $($result.Skipped) not on this host" })$(if ($result.Reboot) { '; restart needed' })."
        Complete-AVDTuneUiTask $job.Task -Failed:([bool]($result.Failed -gt 0)) -Summary $text
        Show-Toast $text
        [void](Add-AVDTuneProtocolNote -Protocol $script:Protocol -Group 'optimization' -Subject $text)
        Save-Protocol
        Start-OverviewRefresh
        if ($streamErr) { Show-Error "The optimization run also reported an error: $streamErr" }
    }
    if ($script:CloseWhenDone -and -not $script:UpdJob -and -not $script:BenchJob -and -not $script:SealJob -and -not $script:SwJob) { if ($err) { $script:CloseWhenDone = $false } else { $window.Close(); return } }
    Start-OptRead   # the state after the run (also after a failed one); Apply stays locked until it is read
}
$script:Timer.Add_Tick({ try { Complete-OptRun } catch { Show-Error $_.Exception.Message } })
# Closing and signing out during a run would end it in the middle of a change: the window waits and closes by itself when it is done
$window.Add_Closing({
        param($src, $e)
        if (-not $script:OptRun) { return }
        $e.Cancel = $true; $script:CloseWhenDone = $true
        Show-Toast 'An optimization run is still going. AVDTune closes by itself when it is done.'
    })
$script:OptSessionEnding = [System.Windows.SessionEndingCancelEventHandler]{ param($src, $e) if ($script:OptRun) { $e.Cancel = $true; Show-Toast 'Log off or shut down was held back: an optimization run is still going. Try again when it is done.' } }
if ([System.Windows.Application]::Current) { [System.Windows.Application]::Current.add_SessionEnding($script:OptSessionEnding) }

Add-Click $ui.OptPresets['recommended'] { Set-OptPreset 'recommended' }
Add-Click $ui.OptPresets['conservative'] { Set-OptPreset 'conservative' }
Add-Click $ui.OptPresets['all'] { Set-OptPreset 'all' }
Add-Click $ui.OptPresets['none'] { Set-OptPreset 'none' }
Add-Click $ui.BtnOptRefresh { Start-OptRead; Show-OptList }
Add-Click $ui.BtnOptApply { Start-OptChange 'Apply' }
Add-Click $ui.BtnOptUndo { Start-OptChange 'Undo' }
$ui.ChkOptOnlyOpen.Add_Click({ $script:OptOnlyOpen = [bool]$ui.ChkOptOnlyOpen.IsChecked; Show-OptList })
