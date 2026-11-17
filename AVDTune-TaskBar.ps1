# The task bar at the bottom of the window and the list of the tasks of this session (dot-sourced by Start-AVDTune.ps1; the state is in AVDTune-Tasks.ps1).
# Look and behaviour as in PackTune: a slim bar with the running task (title, step, progress bar - determinate or indeterminate), a counter when several run,
# the result for a few seconds after the end; a click opens the list with status pill, duration, log that unfolds and Retry for what is safe to run again.
# All colors are theme resources (SetResourceReference), so the bar follows the light/dark switch. Runspaces never touch a control: the window timer reads the state.

$script:TaskRows = @{}            # task id -> the controls of its row in the list
$script:TaskListOpen = $false
$script:TaskBarSeen = -1          # version of the task list the list shows
$script:TaskStatusStyle = @{ running = @('AccentSubtle', 'Primary'); succeeded = @('SuccessBg', 'Success'); failed = @('ErrorBg', 'Danger') }
$script:TaskDot = [string][char]0x00B7

function Set-TaskPill($Pill, $Text, [string]$Status) {
    $pair = $script:TaskStatusStyle[$Status]
    Set-Brush $Pill ([System.Windows.Controls.Border]::BackgroundProperty) $pair[0]
    Set-Brush $Text ([System.Windows.Controls.TextBlock]::ForegroundProperty) $pair[1]
}
function Set-TaskProgress($Bar, $Percent, [string]$Mode) {
    # Known progress: the thin bar of the theme; unknown: the standard bar in its indeterminate animation
    if ($Mode -eq 'hidden') { $Bar.Visibility = 'Hidden'; return }
    $Bar.Visibility = 'Visible'
    if ($null -eq $Percent) {
        if (-not $Bar.IsIndeterminate) { $Bar.IsIndeterminate = $true }
    }
    else {
        if ($Bar.IsIndeterminate) { $Bar.IsIndeterminate = $false }
        $Bar.Value = [double]$Percent
    }
}

function New-TaskRow($Task) {
    $row = @{ Id = [int]$Task.Id; LogOpen = $false; LogCount = -1; Status = ''; BarKind = '' }
    $border = New-Object System.Windows.Controls.Border
    $border.BorderThickness = '0,0,0,1'; $border.Padding = '18,12'
    Set-Brush $border ([System.Windows.Controls.Border]::BorderBrushProperty) 'Divider'
    $stack = New-Object System.Windows.Controls.StackPanel
    $grid = New-Object System.Windows.Controls.Grid
    foreach ($w in '*', 'Auto', 'Auto', 'Auto') { $c = New-Object System.Windows.Controls.ColumnDefinition; $c.Width = $w; [void]$grid.ColumnDefinitions.Add($c) }
    $texts = New-Object System.Windows.Controls.StackPanel
    $texts.VerticalAlignment = 'Center'
    $title = New-Object System.Windows.Controls.TextBlock
    $title.FontWeight = 'SemiBold'; $title.TextTrimming = 'CharacterEllipsis'
    $sub = New-Object System.Windows.Controls.TextBlock
    $sub.FontSize = 12; $sub.TextWrapping = 'Wrap'
    Set-Brush $sub ([System.Windows.Controls.TextBlock]::ForegroundProperty) 'MutedText'
    [void]$texts.Children.Add($title); [void]$texts.Children.Add($sub)
    $logBtn = New-Object System.Windows.Controls.Button
    Set-Brush $logBtn ([System.Windows.Controls.Control]::StyleProperty) 'LinkButton'
    $logBtn.FontSize = 13; $logBtn.Margin = '8,0'; $logBtn.VerticalAlignment = 'Center'; $logBtn.Uid = [string][int]$Task.Id; $logBtn.Visibility = 'Collapsed'   # Uid carries the id (Tag is the icon glyph of the theme's buttons)
    [System.Windows.Controls.Grid]::SetColumn($logBtn, 1)
    $retryBtn = New-Object System.Windows.Controls.Button
    Set-Brush $retryBtn ([System.Windows.Controls.Control]::StyleProperty) 'SmallButton'
    $retryBtn.Margin = '4,0,12,0'; $retryBtn.Uid = [string][int]$Task.Id; $retryBtn.Visibility = 'Collapsed'   # texts: Update-TaskRow (also after a switch of the language)
    [System.Windows.Controls.Grid]::SetColumn($retryBtn, 2)
    $pill = New-Object System.Windows.Controls.Border
    Set-Brush $pill ([System.Windows.Controls.Border]::StyleProperty) 'Pill'
    $pill.Padding = '10,2'; $pill.VerticalAlignment = 'Center'
    $pillText = New-Object System.Windows.Controls.TextBlock
    $pillText.FontSize = 12; $pillText.FontWeight = 'SemiBold'
    $pill.Child = $pillText
    [System.Windows.Controls.Grid]::SetColumn($pill, 3)
    foreach ($el in $texts, $logBtn, $retryBtn, $pill) { [void]$grid.Children.Add($el) }
    $bar = New-Object System.Windows.Controls.ProgressBar
    $bar.Minimum = 0; $bar.Maximum = 100; $bar.Margin = '0,8,0,0'; $bar.Height = 4; $bar.BorderThickness = 0
    Set-Brush $bar ([System.Windows.Controls.Control]::StyleProperty) 'ThinProgress'
    $logBorder = New-Object System.Windows.Controls.Border
    $logBorder.CornerRadius = 6; $logBorder.Padding = '12,10'; $logBorder.Margin = '0,10,0,0'; $logBorder.Visibility = 'Collapsed'
    Set-Brush $logBorder ([System.Windows.Controls.Border]::BackgroundProperty) 'Surface'
    $logBox = New-Object System.Windows.Controls.TextBox
    Set-Brush $logBox ([System.Windows.Controls.Control]::StyleProperty) 'SelectableText'
    Set-Brush $logBox ([System.Windows.Controls.Control]::FontFamilyProperty) 'MonoFont'
    Set-Brush $logBox ([System.Windows.Controls.Control]::ForegroundProperty) 'Text'
    $logBox.FontSize = 12; $logBox.MaxHeight = 170; $logBox.VerticalScrollBarVisibility = 'Auto'
    $logBorder.Child = $logBox
    foreach ($el in $grid, $bar, $logBorder) { [void]$stack.Children.Add($el) }
    $border.Child = $stack
    $logBtn.Add_Click({ param($src) try { Switch-TaskLog ([int]$src.Uid) } catch { Show-Error $_.Exception.Message } })
    $retryBtn.Add_Click({ param($src) try { Invoke-TaskRetry ([int]$src.Uid) } catch { Show-Error $_.Exception.Message } })
    $row.Border = $border; $row.Title = $title; $row.Sub = $sub; $row.Pill = $pill; $row.PillText = $pillText; $row.Bar = $bar
    $row.LogBtn = $logBtn; $row.RetryBtn = $retryBtn; $row.LogBorder = $logBorder; $row.LogBox = $logBox
    $row
}

function Update-TaskRow($Row, $Task) {
    $status = [string]$Task.Status
    $Row.Title.Text = [string]$Task.Title
    $took = Format-AVDTuneUiTaskDuration $Task.Started $Task.Finished
    $detail = switch ($status) {
        'running' { if ($Task.Step) { [string]$Task.Step } else { T 'task.starting' } }
        default { [string]$Task.Summary }
    }
    $Row.Sub.Text = (@($detail, $took) | Where-Object { $_ }) -join "  $script:TaskDot  "
    Set-Brush $Row.Sub ([System.Windows.Controls.TextBlock]::ForegroundProperty) $(if ($status -eq 'failed') { 'Danger' } else { 'MutedText' })
    $Row.PillText.Text = T "task.status.$status"
    $Row.RetryBtn.Content = T 'task.retry'
    [System.Windows.Automation.AutomationProperties]::SetName($Row.RetryBtn, (T 'task.retry.name' $Task.Title))
    [System.Windows.Automation.AutomationProperties]::SetName($Row.LogBox, (T 'task.log.name' $Task.Title))
    Set-TaskPill $Row.Pill $Row.PillText $status
    if ($status -eq 'running') {
        $kind = if ($null -eq $Task.Percent) { 'indeterminate' } else { 'determinate' }
        if ($Row.BarKind -ne $kind) {
            $Row.BarKind = $kind
            if ($kind -eq 'indeterminate') { $Row.Bar.ClearValue([System.Windows.Controls.Control]::StyleProperty); $Row.Bar.Height = 4; $Row.Bar.Background = [System.Windows.Media.Brushes]::Transparent; Set-Brush $Row.Bar ([System.Windows.Controls.Control]::ForegroundProperty) 'Primary' }
            else { $Row.Bar.ClearValue([System.Windows.Controls.Control]::BackgroundProperty); $Row.Bar.ClearValue([System.Windows.Controls.Control]::ForegroundProperty); Set-Brush $Row.Bar ([System.Windows.Controls.Control]::StyleProperty) 'ThinProgress' }
        }
        Set-TaskProgress $Row.Bar $Task.Percent 'show'
    }
    else { $Row.Bar.Visibility = 'Collapsed' }
    $Row.RetryBtn.Visibility = ConvertTo-Vis ($status -eq 'failed' -and [bool]$Task.Retry)
    $log = @(Get-AVDTuneUiTaskLog $Task)
    $Row.LogBtn.Visibility = ConvertTo-Vis ($log.Count -gt 0)
    $Row.LogBtn.Content = $(if ($Row.LogOpen) { T 'task.hidelog' } else { T 'task.showlog' })
    $Row.LogBorder.Visibility = ConvertTo-Vis ($Row.LogOpen -and $log.Count -gt 0)
    if ($Row.LogOpen -and $Row.LogCount -ne $log.Count) {
        $Row.LogCount = $log.Count
        $Row.LogBox.Text = (@($log | ForEach-Object { '{0}  {1}' -f $_.Time, $_.Text }) -join "`n")
    }
    $Row.Status = $status
}

function Switch-TaskLog([int]$Id) {
    $row = $script:TaskRows[$Id]
    if (-not $row) { return }
    $row.LogOpen = -not $row.LogOpen; $row.LogCount = -1
    $task = @(Get-AVDTuneUiTasks | Where-Object { [int]$_.Id -eq $Id })[0]
    if ($task) { Update-TaskRow $row $task }
}

function Invoke-TaskRetry([int]$Id) {
    # Runs the start function of the task again (only what the owner of the task named as safe: reads and checks, never a change of the master)
    $task = @(Get-AVDTuneUiTasks | Where-Object { [int]$_.Id -eq $Id })[0]
    if (-not $task -or $task.Status -ne 'failed' -or -not $task.Retry) { return }
    $retry = $task.Retry
    $name = [string]$retry.Command
    if ($name -notmatch '^[A-Za-z]+-[A-Za-z]+$' -or -not (Get-Command -Name $name -CommandType Function -ErrorAction SilentlyContinue)) { throw (T 'task.err.noretry') }
    $task.Retry = $null   # one retry per failed task: the new run is a task of its own
    Step-UiTaskVersion    # the row redraws without its button
    $arguments = @($retry.Arguments)
    & $name @arguments
    Update-TaskBar
}

function Update-TaskList([bool]$Force) {
    $tasks = @(Get-AVDTuneUiTasks)
    $version = Get-AVDTuneUiTaskVersion
    $changed = $Force -or $version -ne $script:TaskBarSeen
    $running = @($tasks | Where-Object { $_.Status -eq 'running' })
    if (-not $changed -and $running.Count -eq 0) { return }
    foreach ($t in $tasks) {
        $id = [int]$t.Id
        if (-not $script:TaskRows.ContainsKey($id)) {
            $row = New-TaskRow $t
            $script:TaskRows[$id] = $row
            $ui.PanelTaskList.Children.Insert(0, $row.Border)   # the newest on top
            Update-TaskRow $row $t
        }
        elseif ($changed -or $t.Status -eq 'running') { Update-TaskRow $script:TaskRows[$id] $t }
    }
    foreach ($id in @($script:TaskRows.Keys)) {
        if (-not ($tasks | Where-Object { [int]$_.Id -eq $id })) { $ui.PanelTaskList.Children.Remove($script:TaskRows[$id].Border); $script:TaskRows.Remove($id) }
    }
    $failed = @($tasks | Where-Object { $_.Status -eq 'failed' }).Count
    $ui.TxtTaskEmpty.Visibility = ConvertTo-Vis ($tasks.Count -eq 0)
    $ui.TxtTaskSummary.Text = $(if ($tasks.Count) { T 'task.summary' (T $(if ($tasks.Count -eq 1) { 'task.count.one' } else { 'task.count.many' }) $tasks.Count) $running.Count $(if ($failed) { T 'task.summary.failed' $failed } else { '' }) } else { '' })
    $script:TaskBarSeen = $version
}

function Update-TaskBar {
    # One call per tick of the window timer: the bar, and the list when it is open
    $bar = Get-AVDTuneUiTaskBar
    switch ($bar.Kind) {
        'Running' {
            Set-TaskProgress $ui.PbTask $bar.Percent 'show'
            Set-Brush $ui.DotTask ([System.Windows.Shapes.Shape]::FillProperty) 'Primary'
            $ui.TxtTaskTitle.Text = $bar.Title
            $ui.TxtTaskStep.Text = $(if ($bar.Step) { $bar.Step } else { T 'task.bar.starting' })
            Set-Brush $ui.TxtTaskStep ([System.Windows.Controls.TextBlock]::ForegroundProperty) 'MutedText'
            $ui.PillTaskCount.Visibility = ConvertTo-Vis ($bar.Running -gt 1)
            $ui.TxtTaskCount.Text = T 'task.more' ($bar.Running - 1)
            $ui.PillTaskCount.ToolTip = T 'task.running.tip' $bar.Running
            $ui.PillTaskResult.Visibility = 'Collapsed'
        }
        'Result' {
            Set-TaskProgress $ui.PbTask $null 'hidden'
            Set-Brush $ui.DotTask ([System.Windows.Shapes.Shape]::FillProperty) $(if ($bar.Ok) { 'SuccessDot' } else { 'Danger' })
            $ui.TxtTaskTitle.Text = $bar.Title
            $ui.TxtTaskStep.Text = Get-AVDTuneEngineText $(if ($bar.Ok) { 'task.status.succeeded' } else { 'task.status.failed' }) $bar.Result
            Set-Brush $ui.TxtTaskStep ([System.Windows.Controls.TextBlock]::ForegroundProperty) $(if ($bar.Ok) { 'MutedText' } else { 'Danger' })
            $ui.PillTaskCount.Visibility = 'Collapsed'
            $ui.TxtTaskResult.Text = $(if ($bar.Ok) { T 'task.status.succeeded' } else { T 'task.status.failed' })
            Set-TaskPill $ui.PillTaskResult $ui.TxtTaskResult $(if ($bar.Ok) { 'succeeded' } else { 'failed' })
            $ui.PillTaskResult.Visibility = 'Visible'
        }
        default {
            Set-TaskProgress $ui.PbTask $null 'hidden'
            Set-Brush $ui.DotTask ([System.Windows.Shapes.Shape]::FillProperty) 'MutedText'
            $ui.TxtTaskTitle.Text = T 'task.idle'
            $ui.TxtTaskStep.Text = $(if ($bar.Count) { T 'task.insession' $bar.Count $(if ($bar.Count -ne 1) { T 'task.plural' } else { '' }) } else { '' })
            Set-Brush $ui.TxtTaskStep ([System.Windows.Controls.TextBlock]::ForegroundProperty) 'MutedText'
            $ui.PillTaskCount.Visibility = 'Collapsed'
            $ui.TxtTaskResult.Text = T 'task.failedcount' $bar.Failed
            Set-TaskPill $ui.PillTaskResult $ui.TxtTaskResult 'failed'
            $ui.PillTaskResult.Visibility = ConvertTo-Vis ($bar.Failed -gt 0)
        }
    }
    $ui.TxtTaskTitle.FontWeight = $(if ($bar.Kind -eq 'Idle') { 'Normal' } else { 'SemiBold' })
    if ($script:TaskListOpen) { Update-TaskList $false }
}

function Show-TaskList([bool]$Open) {
    $script:TaskListOpen = $Open
    $ui.BoxTaskList.Visibility = ConvertTo-Vis $Open
    $ui.TxtTaskChevron.Text = [string][char]$(if ($Open) { 0xE70D } else { 0xE70E })
    $ui.BoxTaskBar.ToolTip = $(if ($Open) { T 'task.bar.hide' } else { T 'task.bar.show' })
    if ($Open) { Update-TaskList $true }
}
$ui.BoxTaskBar.Add_MouseLeftButtonUp({ try { Show-TaskList (-not $script:TaskListOpen) } catch { } })
$ui.BoxTaskBar.Add_KeyDown({ param($s, $e) try { if ($e.Key -in 'Enter', 'Space') { $e.Handled = $true; Show-TaskList (-not $script:TaskListOpen) } } catch { } })
$ui.BoxTaskList.Add_KeyDown({ param($s, $e) try { if ($e.Key -eq 'Escape') { $e.Handled = $true; Show-TaskList $false } } catch { } })
Add-Click $ui.BtnTaskClose { Show-TaskList $false }
$script:Timer.Add_Tick({ try { Update-TaskBar } catch { } })

function Invoke-UiTaskInline {
    # A call that runs on the window thread (sign-in, a request to Azure, an install): the task shows first, the bar is painted before the call blocks the thread
    param([Parameter(Mandatory)][string]$Kind, [Parameter(Mandatory)][string]$Title, [Parameter(Mandatory)][scriptblock]$Block, [string]$Step = '', [string]$Done = '', [hashtable]$Retry)
    # the names here are unlikely on purpose: the block of the caller runs below this function and sees its variables
    $inlineTask = Start-AVDTuneUiTask -Kind $Kind -Title $Title -Step $Step -Retry $Retry
    try { Update-TaskBar; $window.Dispatcher.Invoke([Action] {}, [System.Windows.Threading.DispatcherPriority]::Render) } catch { }
    try { $inlineOut = & $Block }
    catch { Complete-AVDTuneUiTask $inlineTask -Failed -Summary $_.Exception.Message; throw }
    Complete-AVDTuneUiTask $inlineTask -Summary $Done
    $inlineOut
}

Show-TaskList $false   # the tooltip of the bar in the chosen language
Update-TaskBar
