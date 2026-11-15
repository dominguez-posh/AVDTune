# The User experience page (dot-sourced by Start-AVDTune.ps1). Now: the watermark (Modules\AVDTune.Watermark.psm1, Watermark\*.ps1).
# Saving the settings only writes AVDTune's own state (config\watermark.json). Install, Remove and the removal of the old overlay change the master:
# they need the open write gate and a confirmation. They are short, so they run on the window thread (no background job).

$script:WmSourceRoot = Join-Path $script:AppRoot 'Watermark'
$script:WmLoading = $false
$script:WmFormLoaded = $false
$script:WmSaved = $null
$script:WmPreviewScale = 0.5   # the preview shows a 960 x 540 screen section at 50 %
$ui.CmbWmCorner.ItemsSource = @('BottomRight', 'BottomLeft', 'TopRight', 'TopLeft')

function Get-WmFormRaw {
    # What the form says, as raw values (text for the numbers: the validation names what is wrong). The Microsoft values that have no field stay as saved.
    $ms = @{ Enabled = [bool]$ui.ChkWmMs.IsChecked }
    if ($script:WmSaved) { $s = $script:WmSaved.Microsoft; $ms.QrScale = $s.QrScale; $ms.Opacity = $s.Opacity; $ms.WidthFactor = $s.WidthFactor; $ms.HeightFactor = $s.HeightFactor }
    @{
        Pattern = [string]$ui.TxtWmPattern.Text; Text = [string]$ui.TxtWmText.Text; Color = [string]$ui.TxtWmColor.Text; Opacity = [string]$ui.TxtWmOpacity.Text
        FontSize = [string]$ui.TxtWmSize.Text; Corner = [string]$ui.CmbWmCorner.SelectedItem; Margin = [string]$ui.TxtWmMargin.Text
        ConsoleMode = $(if ($ui.ChkWmHeadless.IsChecked) { 'Headless' } else { 'Hidden' }); Microsoft = $ms
    }
}
function Set-WmForm($Settings) {
    $script:WmLoading = $true
    try {
        $ui.TxtWmPattern.Text = [string]$Settings.Pattern; $ui.TxtWmText.Text = [string]$Settings.Text; $ui.TxtWmColor.Text = [string]$Settings.Color
        $ui.TxtWmOpacity.Text = [string]$Settings.Opacity; $ui.TxtWmSize.Text = [string]$Settings.FontSize; $ui.TxtWmMargin.Text = [string]$Settings.Margin
        $ui.CmbWmCorner.SelectedItem = [string]$Settings.Corner
        $ui.ChkWmHeadless.IsChecked = ([string]$Settings.ConsoleMode -eq 'Headless'); $ui.ChkWmMs.IsChecked = [bool]$Settings.Microsoft.Enabled
        if (-not $ui.TxtWmTryName.Text) { $ui.TxtWmTryName.Text = [string](& $script:Machine.ComputerName) }
    }
    finally { $script:WmLoading = $false }
}
function ConvertTo-WmBrush([string]$Hex) {
    $c = ConvertTo-WmRgb $Hex
    New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb($c.R, $c.G, $c.B))
}

function Update-WmPreview {
    # Live: validation, the name preview ("would appear on this host: yes/no") and the picture. Does not touch the master.
    $r = ConvertTo-AVDTuneWatermarkSettings (Get-WmFormRaw)
    $s = $r.Settings
    $ui.TxtWmErrors.Text = (@($r.Errors) -join "`r`n")
    $ui.BtnWmSave.IsEnabled = $r.Valid
    $hostName = [string](& $script:Machine.ComputerName)
    $try = [string]$ui.TxtWmTryName.Text
    $yn = { param($b) if ($b) { 'yes' } else { 'no' } }
    $pv = Test-AVDTuneWatermarkPattern $s.Pattern
    if (-not $pv.Valid) { $ui.TxtWmMatch.Text = $pv.Error }
    else {
        $ui.TxtWmMatch.Text = "This host ($hostName) would show the watermark: $(& $yn (Test-AVDTuneWatermarkName $s.Pattern $hostName))." + $(if ($try -and $try -ne $hostName) { " '$try': $(& $yn (Test-AVDTuneWatermarkName $s.Pattern $try))." } else { '' }) + ' The match ignores case and may match anywhere in the name; start with ^ to match the beginning.'
    }
    $ui.BoxWmSwatch.Background = ConvertTo-WmBrush $s.Color
    $k = $script:WmPreviewScale
    $tb = $ui.TxtWmPreview
    $tb.Text = $s.Text; $tb.FontSize = [Math]::Max(3.0, $s.FontSize * $k); $tb.Foreground = ConvertTo-WmBrush $s.Color; $tb.Opacity = $s.Opacity / 100.0
    $tb.Measure((New-Object System.Windows.Size ([double]::PositiveInfinity), ([double]::PositiveInfinity)))
    $taskbar = 40 * $k
    $ui.RectWmTaskbar.Height = $taskbar; [System.Windows.Controls.Canvas]::SetTop($ui.RectWmTaskbar, 270 - $taskbar)
    $pos = Get-AVDTuneWatermarkPlacement -WorkArea @{ X = 0; Y = 0; Width = 480; Height = (270 - $taskbar) } -Width ([int][Math]::Ceiling($tb.DesiredSize.Width)) -Height ([int][Math]::Ceiling($tb.DesiredSize.Height)) -Corner $s.Corner -Margin ([int][Math]::Round($s.Margin * $k))
    [System.Windows.Controls.Canvas]::SetLeft($tb, $pos.X); [System.Windows.Controls.Canvas]::SetTop($tb, $pos.Y)
    $ui.TxtWmPreviewNote.Text = 'Scaled preview (50 %) of a 960 x 540 screen with the taskbar at the bottom. The label sits in the work area, so the taskbar stays free. On several monitors every one gets its own label.'
}

function Update-WatermarkView {
    $st = Get-AVDTuneWatermarkStatus -Machine $script:Machine -Root $script:StateRoot -SourceRoot $script:WmSourceRoot
    $script:WmSaved = $st.Settings
    if (-not $script:WmFormLoaded) { Set-WmForm $st.Settings; $script:WmFormLoaded = $true }
    $map = @{ Installed = @('SuccessBg', 'Success', 'Installed'); Partial = @('WarningBg', 'Warning', 'Partly'); NotInstalled = @('Hover', 'MutedText', 'Not installed') }
    $pair = $map[[string]$st.State]
    Set-Brush $ui.PillWm ([System.Windows.Controls.Border]::BackgroundProperty) $pair[0]
    $ui.TxtWmPill.Text = $pair[2]; Set-Brush $ui.TxtWmPill ([System.Windows.Controls.TextBlock]::ForegroundProperty) $pair[1]
    $core = @($st.Items | Where-Object { $_.Group -eq 'Overlay' })
    $ui.TxtWmSummary.Text = "$(@($core | Where-Object Compliant).Count) of $($core.Count) parts are in place on this master."
    $yn = if ($st.HostMatch) { 'yes' } else { 'no' }
    $ui.TxtWmHost.Text = "This host is $($st.HostName); with the saved pattern the watermark would appear here: $yn.$(if (-not $st.SettingsSaved) { ' No settings are saved yet: these are the defaults.' })"
    if ($st.SettingsErrors.Count -gt 0) { $ui.TxtWmHost.Text += ' The saved settings are not valid and are replaced by the defaults: ' + ($st.SettingsErrors -join ' ') }
    $ui.BoxWmLegacy.Visibility = ConvertTo-Vis ([bool]$st.Legacy.Present)
    if ($st.Legacy.Present) {
        $parts = @(); if ($st.Legacy.Task) { $parts += "the scheduled task $($st.Legacy.TaskName)" }; if ($st.Legacy.Vbs) { $parts += "the launcher $($st.Legacy.VbsPath)" }
        $ui.TxtWmLegacy.Text = "Found: $($parts -join ' and '). Both can run next to the new watermark, so users would see two labels. Removing them keeps a backup of the task definition and the launcher in AVDTune's state folder and can be undone. Overlays that are running right now are not stopped; they end when the user signs out."
    }
    $ui.PanelWmItems.Children.Clear()
    $last = ''
    foreach ($i in $st.Items) {
        if ($i.Group -ne $last) { [void]$ui.PanelWmItems.Children.Add((New-UpdGroupHead $i.Group)); $last = $i.Group }
        $g = New-Object System.Windows.Controls.Grid; $g.Margin = '0,4,0,4'
        foreach ($w in 110, '*', 240) { $c = New-Object System.Windows.Controls.ColumnDefinition; $c.Width = $w; [void]$g.ColumnDefinitions.Add($c) }
        $k = if ($i.Group -eq 'Old overlay') { if ($i.Compliant) { @('SuccessBg', 'Success', 'None found') } else { @('WarningBg', 'Warning', 'Found') } }
        elseif (-not $i.Applicable) { @('Hover', 'MutedText', 'Off') }
        elseif ($i.Compliant) { @('SuccessBg', 'Success', 'In place') } else { @('WarningBg', 'Warning', 'Missing') }
        $pill = New-Object System.Windows.Controls.Border; Set-Brush $pill ([System.Windows.Controls.Border]::StyleProperty) 'Pill'; $pill.Padding = '10,2'; $pill.HorizontalAlignment = 'Left'; $pill.VerticalAlignment = 'Center'
        Set-Brush $pill ([System.Windows.Controls.Border]::BackgroundProperty) $k[0]
        $pt = New-Object System.Windows.Controls.TextBlock; $pt.Text = $k[2]; $pt.FontSize = 12; $pt.FontWeight = 'SemiBold'; Set-Brush $pt ([System.Windows.Controls.TextBlock]::ForegroundProperty) $k[1]; $pill.Child = $pt
        $t = New-Object System.Windows.Controls.TextBlock; $t.Text = [string]$i.Title; $t.TextWrapping = 'Wrap'; $t.VerticalAlignment = 'Center'; $t.SetValue([System.Windows.Controls.Grid]::ColumnProperty, 1); $t.Margin = '0,0,10,0'; $t.ToolTip = "$($i.Why)`r`nSource: $($i.Source)"
        $s = New-Object System.Windows.Controls.TextBlock; $s.Text = [string]$i.State; $s.TextWrapping = 'Wrap'; $s.VerticalAlignment = 'Center'; $s.SetValue([System.Windows.Controls.Grid]::ColumnProperty, 2); Set-Brush $s ([System.Windows.Controls.TextBlock]::ForegroundProperty) 'MutedText'
        foreach ($e in $pill, $t, $s) { [void]$g.Children.Add($e) }
        [void]$ui.PanelWmItems.Children.Add($g)
    }
    $ui.TxtWmNotes.Text = 'The label appears at the next sign-in of a user (the task starts at logon, one overlay per session); changed settings are read then too. It is not verified on a multi-session host yet, and a console window can flash briefly at logon unless the headless start is switched on. Hover a row for the reason and the source.'
    Update-WmPreview
}

foreach ($box in $ui.TxtWmPattern, $ui.TxtWmTryName, $ui.TxtWmText, $ui.TxtWmColor, $ui.TxtWmOpacity, $ui.TxtWmSize, $ui.TxtWmMargin) { $box.Add_TextChanged({ if (-not $script:WmLoading) { Update-WmPreview } }) }
$ui.CmbWmCorner.Add_SelectionChanged({ if (-not $script:WmLoading) { Update-WmPreview } })

function Save-WatermarkForm {
    $saved = Save-AVDTuneWatermarkSettings -Root $script:StateRoot -Settings (Get-WmFormRaw)
    $script:WmSaved = $saved
    [void](Add-AVDTuneProtocolNote -Protocol $script:Protocol -Group 'userexperience' -Subject "Watermark settings saved (pattern $($saved.Pattern), text $($saved.Text))")
    Save-Protocol
    $saved
}
function Test-WmFormChanged {
    $r = ConvertTo-AVDTuneWatermarkSettings (Get-WmFormRaw)
    (($r.Settings | ConvertTo-Json -Compress -Depth 5) -ne ($script:WmSaved | ConvertTo-Json -Compress -Depth 5))
}
function Start-WatermarkChange([string]$Mode) {
    if (-not (Test-AVDTuneWriteAllowed)) { throw 'Read only: confirm a snapshot of today on the Overview first.' }
    $st = Get-AVDTuneWatermarkStatus -Machine $script:Machine -Root $script:StateRoot -SourceRoot $script:WmSourceRoot
    $ask = switch ($Mode) {
        'On' {
            $r = ConvertTo-AVDTuneWatermarkSettings (Get-WmFormRaw)
            if (-not $r.Valid) { throw ('The settings are not valid: ' + ($r.Errors -join ' ')) }
            "Install the watermark on this master?`nProgram files in C:\Program Files\AVDTune\Watermark, a settings copy for users in C:\ProgramData\AVDTune-Public and the scheduled task 'AVDTune Watermark' at logon for all users." +
            $(if (Test-WmFormChanged) { "`nThe changed settings are saved first." } else { '' }) +
            $(if ($r.Settings.Microsoft.Enabled) { "`nThe Microsoft QR code watermark is switched on: afterwards only clients that support watermarking can connect." } else { '' }) +
            $(if ($st.Legacy.Present) { "`nThe old overlay is not touched (own button)." } else { '' })
        }
        'Off' { "Remove the watermark from this master?`nThe scheduled task, the program files, the settings copy and the Microsoft policy are removed. The saved settings in AVDTune stay." }
        'LegacyRemove' { "Remove the old overlay?`nThe scheduled task $($st.Legacy.TaskName) and the launcher PilotOverlayLauncher.vbs are removed. A backup is kept so this can be undone. Overlays that are running are not stopped." }
    }
    if (-not (Confirm-Action $ask 'Watermark')) { return }
    $window.Cursor = [System.Windows.Input.Cursors]::Wait
    try {
        if ($Mode -eq 'On' -and (Test-WmFormChanged)) { [void](Save-WatermarkForm) }
        $user = [string]$env:USERNAME
        $gate = Get-AVDTuneWriteGate
        $wmTitle = @{ On = 'Installing the watermark'; Off = 'Removing the watermark'; LegacyRemove = 'Removing the old overlay' }[$Mode]
        $result = Invoke-UiTaskInline -Kind 'watermark' -Title $wmTitle -Step 'Changing the master' -Block { Set-AVDTuneWatermark -Machine $script:Machine -Root $script:StateRoot -SourceRoot $script:WmSourceRoot -Mode $Mode -User $user -SnapshotId $gate.SnapshotId }
    }
    finally { $window.Cursor = $null }
    foreach ($r in $result.Results) { Register-StepResult $r }
    $what = @{ On = 'installed'; Off = 'removed'; LegacyRemove = 'old overlay removed' }[$Mode]
    $text = "Watermark $what`: $($result.Changed) change(s)$(if ($result.Failed -gt 0) { ", $($result.Failed) failed" }), state $($result.State)."
    Show-Toast $text
    [void](Add-AVDTuneProtocolNote -Protocol $script:Protocol -Group 'userexperience' -Subject $text)
    Save-Protocol
    Update-WatermarkView; Start-OverviewRefresh
}
Add-Click $ui.BtnWmSave {
    $s = Save-WatermarkForm
    Show-Toast 'Watermark settings saved. Install on this master to apply them.'
    Update-WatermarkView
}
Add-Click $ui.BtnWmInstall { Start-WatermarkChange 'On' }
Add-Click $ui.BtnWmRemove { Start-WatermarkChange 'Off' }
Add-Click $ui.BtnWmLegacy { Start-WatermarkChange 'LegacyRemove' }
