# The Optimization page (dot-sourced by Start-AVDTune.ps1): the selectable optimization list of docs\plans\avdtune.md, section 5d.
# Logic and data: Modules\AVDTune.Optimization.psm1 and data\optimization.json. This file only draws the list and starts Apply and Undo.
# The page is built in code and put next to the other pages, so UI\AVDTune.xaml stays untouched. Reading the state changes nothing; Apply and Undo need the open
# write gate and a confirmation, and an AppX removal (cannot be undone) needs its own second confirmation. They run on the window thread (short; the bar shows the task).

$script:OptStatus = $null
$script:OptChecked = @{}        # id -> $true / $false; filled from the defaults of the data file at the first view
$script:OptInitDone = $false
$script:OptOnlyOpen = $false
$script:OptBuilding = $false

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
        [void]$presetRow.Children.Add($b); $presetButtons[$p[0]] = $b
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

function Read-OptStatus {
    $window.Cursor = [System.Windows.Input.Cursors]::Wait
    try { $script:OptStatus = Get-AVDTuneOptimizationStatus -Machine $script:Machine -Root $script:StateRoot }
    finally { $window.Cursor = $null }
    if ($script:OptStatus.DataValid -and -not $script:OptInitDone) {
        foreach ($r in $script:OptStatus.Rows) { $script:OptChecked[$r.Id] = [bool]$r.Default }
        $script:OptInitDone = $true
    }
}

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

function Show-OptList {
    $st = $script:OptStatus
    $script:OptBuilding = $true
    try {
        $ui.PanelOptList.Children.Clear()
        $ui.BoxOptErrors.Visibility = ConvertTo-Vis ($st -and -not $st.DataValid)
        if (-not $st) { return }
        if (-not $st.DataValid) {
            $ui.TxtOptErrors.Text = "The optimization data is not valid, so nothing can be applied. " + (@($st.DataErrors | Select-Object -First 6) -join "`r`n")
            $ui.TxtOptSummary.Text = ''; $ui.BtnOptApply.IsEnabled = $false; $ui.BtnOptUndo.IsEnabled = $false
            return
        }
        $ui.BtnOptApply.IsEnabled = $true; $ui.BtnOptUndo.IsEnabled = $true
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
    $sel = @(Get-OptSelectedRows)
    $open = @($sel | Where-Object { -not $_.Compliant })
    $irr = @($open | Where-Object { $_.Irreversible })
    $src = @($st.Sources | Where-Object { $_.Id -eq 'wdot' })[0]
    $ui.TxtOptSummary.Text = "$($st.Rows.Count) entries; $(@($st.Rows | Where-Object { $_.Present -and $_.Compliant }).Count) already in place. Selected: $($sel.Count), of which $($open.Count) would change something$(if ($irr.Count -gt 0) { " ($($irr.Count) AppX removal(s) that cannot be undone)" })." +
        $(if ($src) { " Data based on $($src.Name), $($src.License) licence, $($src.Copyright)." } else { '' }) + $(if ($st.BackupError) { " $($st.BackupError)" } else { '' })
}

function Update-OptView {
    if (-not $script:OptStatus) { Read-OptStatus }
    $ui.ChkOptOnlyOpen.IsChecked = $script:OptOnlyOpen
    Show-OptList
}

function Start-OptChange([string]$Mode) {
    if (-not (Test-AVDTuneWriteAllowed)) { throw 'Read only: confirm a snapshot of today on the Overview first.' }
    $st = $script:OptStatus
    if (-not $st -or -not $st.DataValid) { throw 'The optimization data is not valid; nothing can be applied.' }
    $sel = @(Get-OptSelectedRows)
    if ($Mode -eq 'Undo') {
        $skip = @($sel | Where-Object { $_.Irreversible })
        $sel = @($sel | Where-Object { -not $_.Irreversible })
    }
    else { $sel = @($sel | Where-Object { -not $_.Compliant }); $skip = @() }
    if ($sel.Count -eq 0) { Show-Toast $(if ($Mode -eq 'Undo') { 'Nothing selected that can be undone.' } else { 'Nothing selected that is not in place yet.' }); return }
    $irr = @($sel | Where-Object { $_.Irreversible })
    $reboot = @($sel | Where-Object { $_.Reboot }).Count
    $high = @($sel | Where-Object { $_.Risk -eq 'High' })
    $ask = "$(if ($Mode -eq 'Undo') { 'Undo' } else { 'Apply' }) $($sel.Count) optimization(s) on this master?" +
        $(if ($high.Count -gt 0) { "`n$($high.Count) of them have risk High: " + (@($high | Select-Object -First 3 | ForEach-Object { $_.Title }) -join '; ') }) +
        $(if ($reboot -gt 0 -and $Mode -eq 'Apply') { "`n$reboot need a restart to take effect." }) +
        $(if ($skip.Count -gt 0) { "`n$($skip.Count) AppX removal(s) in the selection cannot be undone and are left out." }) +
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
    $window.Cursor = [System.Windows.Input.Cursors]::Wait
    try {
        $label = if ($Mode -eq 'Undo') { 'Undoing optimizations' } else { 'Applying optimizations' }
        $result = Invoke-UiTaskInline -Kind 'optimization' -Title $label -Step "$($ids.Count) entries" -Block { Invoke-AVDTuneOptimization -Machine $script:Machine -Root $script:StateRoot -Ids $ids -Mode $Mode -ConfirmIrreversible:$confirmIrr -User $user -SnapshotId $gate.SnapshotId }
    }
    finally { $window.Cursor = $null }
    foreach ($r in $result.Results) { Register-StepResult $r }
    $text = "Optimization $($Mode.ToLowerInvariant()): $($result.Changed) change(s)$(if ($result.Failed -gt 0) { ", $($result.Failed) failed" })$(if ($result.Skipped -gt 0) { ", $($result.Skipped) not on this host" })$(if ($result.Reboot) { '; restart needed' })."
    Show-Toast $text
    [void](Add-AVDTuneProtocolNote -Protocol $script:Protocol -Group 'optimization' -Subject $text)
    Save-Protocol
    Read-OptStatus; Show-OptList; Start-OverviewRefresh
}

Add-Click $ui.OptPresets['recommended'] { Set-OptPreset 'recommended' }
Add-Click $ui.OptPresets['conservative'] { Set-OptPreset 'conservative' }
Add-Click $ui.OptPresets['all'] { Set-OptPreset 'all' }
Add-Click $ui.OptPresets['none'] { Set-OptPreset 'none' }
Add-Click $ui.BtnOptRefresh { Read-OptStatus; Show-OptList }
Add-Click $ui.BtnOptApply { Start-OptChange 'Apply' }
Add-Click $ui.BtnOptUndo { Start-OptChange 'Undo' }
$ui.ChkOptOnlyOpen.Add_Click({ $script:OptOnlyOpen = [bool]$ui.ChkOptOnlyOpen.IsChecked; Show-OptList })
