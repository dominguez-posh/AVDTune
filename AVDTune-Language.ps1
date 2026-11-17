# The Language and region page (dot-sourced by Start-AVDTune.ps1; issue 56). Logic is in Modules\AVDTune.Language.psm1 (docs\language.md). The page is built in code and put next to
# the other pages, so UI\AVDTune.xaml stays untouched. Install of languages and the defaults for new users run in a background runspace (DISM takes minutes per language) and are
# polled by the window timer; a task shows on the task bar. Test (dry run) and reading run on the UI thread. Everything that changes the master is behind the write gate.
# Test mode: the fake machine and the fake language adapter run inline; no DISM, no setting of this computer is touched.
# Helpers of the FSLogix page (user, gate snapshot, Assert-FslWrite) and of the other pages (New-Text, New-UpdGroupHead, Register-StepResult) are resolved when a button is pressed.

$script:LangFake = $null
if ($script:TestMode) {
    . (Get-TestScript 'FakeLanguage.ps1')
    Set-AVDTuneFakeLanguageRegistry -Machine $script:Machine
    $script:LangFake = New-AVDTuneFakeLanguage -Machine $script:Machine
}
$script:LangReal = $null
$script:LangJob = $null
$script:LangState = $null
$script:LangChecks = [ordered]@{}
$script:LangCombos = [ordered]@{}
$script:LangLoaded = $false
$script:LangBuilding = $false

function Get-LangAdapter { if ($script:TestMode) { $script:LangFake } else { if (-not $script:LangReal) { $script:LangReal = New-AVDTuneLanguageAdapter }; $script:LangReal } }

function Initialize-LangPage {
    $pageHost = $ui.PagePlaceholder.Parent
    $page = New-Object System.Windows.Controls.Grid
    $page.Name = 'PageLanguage'; $page.Visibility = 'Collapsed'
    $scroll = New-Object System.Windows.Controls.ScrollViewer; Set-Brush $scroll ([System.Windows.Controls.ScrollViewer]::StyleProperty) 'PageScroll'
    $stack = New-Object System.Windows.Controls.StackPanel; $stack.Margin = '40,32,40,28'; $stack.MaxWidth = 1000; $stack.HorizontalAlignment = 'Left'
    [void]$stack.Children.Add((New-Text 'Language and region' 'PageTitle'))
    [void]$stack.Children.Add((New-Text 'Language packs and features for a Windows 11 multi-session master, and the defaults new users get at their first sign-in. Languages come from a content folder you name (the LanguagesAndOptionalFeatures content of the Microsoft ISO, mounted or on a share): AVDTune downloads nothing. Nothing is changed until you press a button and confirm.' 'Subtitle'))
    $state = New-Text '' 'Hint' '0,10,0,0'; [void]$stack.Children.Add($state)

    $newCard = {
        param($Title)
        $c = New-Object System.Windows.Controls.Border; Set-Brush $c ([System.Windows.Controls.Border]::StyleProperty) 'CardBox'; Set-Brush $c ([System.Windows.Controls.Border]::BackgroundProperty) 'Card'; $c.Padding = '20,16'; $c.Margin = '0,16,0,0'
        $s = New-Object System.Windows.Controls.StackPanel; [void]$s.Children.Add((New-Text $Title 'CardTitle')); $c.Child = $s
        [void]$stack.Children.Add($c); $s
    }
    $btn = { param($Text, $Name, [bool]$Primary) $b = New-Object System.Windows.Controls.Button; $b.Content = $Text; $b.Margin = '0,0,8,0'; if ($Primary) { Set-Brush $b ([System.Windows.Controls.Button]::StyleProperty) 'PrimaryButton' }; [System.Windows.Automation.AutomationProperties]::SetName($b, $Name); $b }

    # installed languages
    $c1 = & $newCard 'Installed languages and features'
    $installed = New-Object System.Windows.Controls.StackPanel; $installed.Margin = '0,8,0,0'; [void]$c1.Children.Add($installed)
    $refresh = & $btn 'Refresh' 'Read the installed languages again' $false; $refresh.Margin = '0,8,0,0'; $refresh.HorizontalAlignment = 'Left'; [void]$c1.Children.Add($refresh)

    # add languages
    $c2 = & $newCard 'Add languages'
    [void]$c2.Children.Add((New-Text 'Tick the languages to install. Each one is installed with its language pack, handwriting, OCR, speech, text-to-speech and (where needed) font features, from the content folder. Installing a language pack cannot be undone by AVDTune (restore a snapshot).' 'Hint' '0,6,0,0'))
    $checks = New-Object System.Windows.Controls.WrapPanel; $checks.Margin = '0,10,0,0'; [void]$c2.Children.Add($checks)
    $row = New-Object System.Windows.Controls.StackPanel; $row.Orientation = 'Horizontal'; $row.Margin = '0,12,0,0'
    $lab = New-Text 'Content folder' $null '0,0,10,0'; $lab.VerticalAlignment = 'Center'
    $src = New-Object System.Windows.Controls.TextBox; $src.Width = 520; $src.Padding = '6,4'; $src.ToolTip = 'A mounted ISO (drive letter), an admin-only folder or a share (\\server\share) with the LanguagesAndOptionalFeatures content'; [System.Windows.Automation.AutomationProperties]::SetName($src, 'Content folder with the language packs')
    [void]$row.Children.Add($lab); [void]$row.Children.Add($src); [void]$c2.Children.Add($row)
    $b2 = New-Object System.Windows.Controls.StackPanel; $b2.Orientation = 'Horizontal'; $b2.Margin = '0,12,0,0'
    $install = & $btn 'Install selected languages' 'Install the ticked languages from the content folder' $true
    [void]$b2.Children.Add($install); [void]$c2.Children.Add($b2)

    # defaults for new users
    $c3 = & $newCard 'Defaults for new users'
    [void]$c3.Children.Add((New-Text 'What new users and the sign-in screen get at the first sign-in. The values are set for the account that runs AVDTune and then copied to the welcome screen and new users (Copy-UserInternationalSettingsToSystem). Display language, system locale and the copy take effect after a restart; users who already have a profile keep their settings. The display language list holds the installed languages; a language that is missing is offered for installation first.' 'Hint' '0,6,0,10'))
    $grid = New-Object System.Windows.Controls.Grid
    foreach ($w in 250, 330, '*') { $cd = New-Object System.Windows.Controls.ColumnDefinition; $cd.Width = $w; [void]$grid.ColumnDefinitions.Add($cd) }
    $labels = [ordered]@{ Ui = 'Display language (UI) and sign-in screen'; Culture = 'Regional format (numbers, dates)'; InputTip = 'Input (keyboard)'; GeoId = 'Location (GeoId)'; SystemLocale = 'System locale (programs without Unicode, restart needed)'; TimeZone = 'Time zone (default from the Azure region)' }
    $nowTexts = @{}; $i = 0
    foreach ($k in $labels.Keys) {
        $rd = New-Object System.Windows.Controls.RowDefinition; $rd.Height = 'Auto'; [void]$grid.RowDefinitions.Add($rd)
        $l = New-Text $labels[$k] $null '0,6,12,6'; $l.VerticalAlignment = 'Center'; $l.TextWrapping = 'Wrap'; $l.SetValue([System.Windows.Controls.Grid]::RowProperty, $i)
        $cb = New-Object System.Windows.Controls.ComboBox; $cb.Margin = '0,4,12,4'; $cb.Padding = '6,4'; $cb.SetValue([System.Windows.Controls.Grid]::RowProperty, $i); $cb.SetValue([System.Windows.Controls.Grid]::ColumnProperty, 1)
        [System.Windows.Automation.AutomationProperties]::SetName($cb, $labels[$k])
        $n = New-Text '' 'Hint' '0,6,0,6'; $n.VerticalAlignment = 'Center'; $n.TextWrapping = 'Wrap'; $n.SetValue([System.Windows.Controls.Grid]::RowProperty, $i); $n.SetValue([System.Windows.Controls.Grid]::ColumnProperty, 2)
        foreach ($e in $l, $cb, $n) { [void]$grid.Children.Add($e) }
        $script:LangCombos[$k] = $cb; $nowTexts[$k] = $n; $i++
    }
    [void]$c3.Children.Add($grid)
    $b3 = New-Object System.Windows.Controls.StackPanel; $b3.Orientation = 'Horizontal'; $b3.Margin = '0,12,0,0'
    $test = & $btn 'Test (change nothing)' 'Test what the settings would change, without changing anything' $false
    $apply = & $btn 'Apply defaults' 'Apply the defaults for new users to this master' $true
    $undo = & $btn 'Undo defaults' 'Put back the values found before the first change' $false
    foreach ($b in $test, $apply, $undo) { [void]$b3.Children.Add($b) }
    [void]$c3.Children.Add($b3)
    $notes = New-Text '' 'Hint' '0,12,0,0'; [void]$c3.Children.Add($notes)

    $scroll.Content = $stack; $page.Children.Add($scroll) | Out-Null
    [void]$pageHost.Children.Add($page)
    $ui.PageLanguage = $page; $ui.TxtLangState = $state; $ui.PanelLangInstalled = $installed; $ui.PanelLangChecks = $checks; $ui.TxtLangSource = $src; $ui.TxtLangNotes = $notes
    $ui.BtnLangRefresh = $refresh; $ui.BtnLangInstall = $install; $ui.BtnLangTest = $test; $ui.BtnLangApply = $apply; $ui.BtnLangUndo = $undo; $ui.LangNow = $nowTexts
}
Initialize-LangPage

function Get-LangCatalogIndex([string]$Tag) { $i = 0; foreach ($c in (Get-AVDTuneLanguageCatalog)) { if ($c.Tag -eq $Tag) { return $i }; $i++ }; 99 }

function Get-LangFormConfig {
    $sel = { param($k) $it = $script:LangCombos[$k].SelectedItem; if ($it -and $null -ne $it.Tag -and "$($it.Tag)" -ne '') { $it.Tag } else { $null } }
    $langs = @($script:LangChecks.Keys | Where-Object { $script:LangChecks[$_].IsChecked -and $script:LangChecks[$_].IsEnabled } | Sort-Object { Get-LangCatalogIndex $_ })
    $geo = & $sel 'GeoId'
    [pscustomobject]@{
        Languages = $langs; Source = $(if ($ui.TxtLangSource.Text.Trim()) { $ui.TxtLangSource.Text.Trim() } else { $null })
        UiLanguage = (& $sel 'Ui'); Culture = (& $sel 'Culture'); InputTip = (& $sel 'InputTip'); GeoId = $(if ($null -ne $geo) { [int]$geo } else { $null }); SystemLocale = (& $sel 'SystemLocale'); TimeZone = (& $sel 'TimeZone')
    }
}

function Set-LangCombo([string]$Key, $Items, $Want) {
    # Items: objects with Label and Value. Keep-as-is first; the item with the wanted value is selected (otherwise Keep as is)
    $cb = $script:LangCombos[$Key]
    $cb.Items.Clear()
    $keep = New-Object System.Windows.Controls.ComboBoxItem; $keep.Content = '(keep as it is)'; $keep.Tag = $null; [void]$cb.Items.Add($keep)
    $pick = $keep
    foreach ($it in $Items) {
        $ci = New-Object System.Windows.Controls.ComboBoxItem; $ci.Content = [string]$it.Label; $ci.Tag = $it.Value; [void]$cb.Items.Add($ci)
        if ($null -ne $Want -and "$($it.Value)" -ieq "$Want") { $pick = $ci }
    }
    $cb.SelectedItem = $pick
}

function Update-LangView {
    $adapter = Get-LangAdapter
    $window.Cursor = [System.Windows.Input.Cursors]::Wait
    try { $st = Get-AVDTuneLanguageState -Machine $script:Machine -L $adapter } finally { $window.Cursor = $null }
    $script:LangState = $st
    $saved = $null; try { $saved = Get-AVDTuneLanguageConfig -Root $script:StateRoot } catch { $ui.TxtLangState.Text = $_.Exception.Message }
    if (-not $saved) { $saved = Get-AVDTuneLanguageDefaults }
    $instTags = @($st.Installed | ForEach-Object { $_.Tag })
    $script:LangBuilding = $true
    try {
        # installed
        $ui.PanelLangInstalled.Children.Clear()
        foreach ($l in @($st.Installed | Sort-Object Tag)) {
            $name = @(Get-AVDTuneLanguageCatalog | Where-Object { $_.Tag -ieq $l.Tag }); $nm = if ($name.Count) { $name[0].Name } else { '' }
            [void]$ui.PanelLangInstalled.Children.Add((New-Text "$($l.Tag)  $nm   $(@($l.Features) -join ', ')" $null '0,2,0,2'))
        }
        if ($st.Installed.Count -eq 0) { [void]$ui.PanelLangInstalled.Children.Add((New-Text 'No language is reported as installed.' 'Hint')) }
        # add: checkboxes once, state every time
        if (-not $script:LangLoaded) {
            foreach ($c in (Get-AVDTuneLanguageCatalog)) {
                $cb = New-Object System.Windows.Controls.CheckBox; $cb.Margin = '0,0,16,6'; $cb.Content = "$($c.Tag)  $($c.Name)"; $cb.DataContext = $c.Tag
                [System.Windows.Automation.AutomationProperties]::SetName($cb, "Install $($c.Tag)")
                $script:LangChecks[$c.Tag] = $cb; [void]$ui.PanelLangChecks.Children.Add($cb)
            }
            $ui.TxtLangSource.Text = [string]$saved.Source
        }
        foreach ($t in @($script:LangChecks.Keys)) {
            $cb = $script:LangChecks[$t]; $isIn = ($t -in $instTags)
            if ($isIn) { $cb.IsChecked = $true; $cb.IsEnabled = $false; $cb.Content = "$t  $((Get-AVDTuneLanguageCatalog | Where-Object Tag -eq $t).Name)  (installed)" }
            else { if (-not $script:LangLoaded) { $cb.IsChecked = [bool]($t -in @($saved.Languages)) }; $cb.IsEnabled = $true; $cb.Content = "$t  $((Get-AVDTuneLanguageCatalog | Where-Object Tag -eq $t).Name)" }
        }
        # defaults: previous choice, else saved, else the actual value (the time zone: the default of the Azure region)
        $first = -not $script:LangLoaded
        $prev = if ($first) { @{} } else { @{ Ui = $script:LangCombos.Ui.SelectedItem.Tag; Culture = $script:LangCombos.Culture.SelectedItem.Tag; InputTip = $script:LangCombos.InputTip.SelectedItem.Tag; GeoId = $script:LangCombos.GeoId.SelectedItem.Tag; SystemLocale = $script:LangCombos.SystemLocale.SelectedItem.Tag; TimeZone = $script:LangCombos.TimeZone.SelectedItem.Tag } }
        $want = { param($k, $cur) if (-not $first -and $prev[$k]) { $prev[$k] } elseif ($first -and $saved.$k) { $saved.$k } else { $cur } }
        $cat = @(Get-AVDTuneLanguageCatalog)
        $uiItems = @(@($cat | Where-Object { $_.Tag -in $instTags } | ForEach-Object { [pscustomobject]@{ Label = "$($_.Tag)  $($_.Name)"; Value = $_.Tag } }) + @($cat | Where-Object { $_.Tag -notin $instTags } | ForEach-Object { [pscustomobject]@{ Label = "$($_.Tag)  $($_.Name)  - not installed, offered for installation first"; Value = $_.Tag } }))
        Set-LangCombo 'Ui' $uiItems (& $want 'Ui' $st.NewUser.Ui)
        Set-LangCombo 'Culture' @(Get-AVDTuneLanguageCultures | ForEach-Object { [pscustomobject]@{ Label = "$($_.Tag)  $($_.Name)"; Value = $_.Tag } }) (& $want 'Culture' $st.NewUser.Culture)
        Set-LangCombo 'InputTip' @(Get-AVDTuneLanguageInputs | ForEach-Object { [pscustomobject]@{ Label = "$($_.Name)  ($($_.Tip))"; Value = $_.Tip } }) (& $want 'InputTip' $st.NewUser.InputTip)
        Set-LangCombo 'GeoId' @(Get-AVDTuneLanguageRegions | ForEach-Object { [pscustomobject]@{ Label = "$($_.Name)  ($($_.Id))"; Value = $_.Id } }) (& $want 'GeoId' $st.NewUser.GeoId)
        Set-LangCombo 'SystemLocale' @(Get-AVDTuneLanguageCultures | ForEach-Object { [pscustomobject]@{ Label = "$($_.Tag)  $($_.Name)"; Value = $_.Tag } }) (& $want 'SystemLocale' $st.SystemLocale)
        $zones = @(& $adapter.GetTimeZones | Sort-Object)
        # the Azure region only suggests a zone (marked in the list); the default stays "(keep as it is)"
        $zoneWant = if ($first) { $saved.TimeZone } elseif ($prev.TimeZone) { $prev.TimeZone } else { $null }
        Set-LangCombo 'TimeZone' @($zones | ForEach-Object { [pscustomobject]@{ Label = $(if ($st.DefaultTimeZone -and $_ -eq $st.DefaultTimeZone) { "$_  (suggested for the Azure region $($st.AzureRegion))" } else { [string]$_ }); Value = [string]$_ } }) $zoneWant
        $now = $ui.LangNow
        $now.Ui.Text = "Now for new users: $(if ($st.NewUser.Ui) { $st.NewUser.Ui } else { 'not set' })"
        $now.Culture.Text = "Now: $(if ($st.NewUser.Culture) { $st.NewUser.Culture } else { 'not set' })"
        $now.InputTip.Text = "Now: $(if ($st.NewUser.InputTip) { $st.NewUser.InputTip } else { 'not set' })"
        $now.GeoId.Text = "Now: $(if ($null -ne $st.NewUser.GeoId) { $st.NewUser.GeoId } else { 'not set' })"
        $now.SystemLocale.Text = "Now: $(if ($st.SystemLocale) { $st.SystemLocale } else { 'not set' })"
        $now.TimeZone.Text = "Now: $(if ($st.TimeZone) { $st.TimeZone } else { 'not set' })$(if ($st.AzureRegion) { "; Azure region $($st.AzureRegion)$(if ($st.DefaultTimeZone) { " suggests $($st.DefaultTimeZone)" })" })"
        $script:LangLoaded = $true
    }
    finally { $script:LangBuilding = $false }
    $ui.TxtLangNotes.Text = 'Sources: Learn "Install language packs on Windows 11 Enterprise VMs in Azure Virtual Desktop" and "Copy-UserInternationalSettingsToSystem". The state of new users is read from the .DEFAULT registry hive (the welcome screen and system accounts); the default profile itself is checked on the test VM. Undo puts back the display language, format, input, location, system locale and time zone found before the first change; installed language packs stay.'
}

function Set-LangBusy([bool]$Busy) {
    foreach ($b in $ui.BtnLangRefresh, $ui.BtnLangInstall, $ui.BtnLangTest, $ui.BtnLangApply, $ui.BtnLangUndo) { $b.IsEnabled = -not $Busy }
    $window.Cursor = $(if ($Busy -and $script:CurrentPage -eq 'Language') { [System.Windows.Input.Cursors]::AppStarting } else { $null })
}

$script:LangWorkerText = @'
param($Kind, $C)
switch ($Kind) {
    'Languages' { Invoke-AVDTuneLanguage -Machine $C.Machine -L $C.L -Root $C.Root -Config $C.Config -Parts Languages -User $C.User -SnapshotId $C.SnapshotId }
    'Defaults' { Invoke-AVDTuneLanguage -Machine $C.Machine -L $C.L -Root $C.Root -Config $C.Config -Parts Defaults -User $C.User -SnapshotId $C.SnapshotId }
    'All' { Invoke-AVDTuneLanguage -Machine $C.Machine -L $C.L -Root $C.Root -Config $C.Config -Parts All -User $C.User -SnapshotId $C.SnapshotId }
    'Undo' { Undo-AVDTuneLanguage -Machine $C.Machine -L $C.L -Root $C.Root -User $C.User -SnapshotId $C.SnapshotId }
}
'@
function Start-LangJob([string]$Kind, $Config) {
    if ($script:LangJob) { throw 'Another language operation is still running.' }
    $gate = Get-AVDTuneWriteGate
    $common = @{ Root = $script:StateRoot; User = (Get-FslUser); SnapshotId = (Get-FslGateSnapshot); Config = $Config }
    $title = switch ($Kind) { 'Languages' { 'Installing languages' } 'Undo' { 'Undoing the language defaults' } 'All' { 'Installing languages and setting the defaults for new users' } default { 'Setting the defaults for new users' } }
    $task = Start-AVDTuneUiTask -Kind "language-$($Kind.ToLower())" -Title $title -Step 'Preparing'
    if ($script:TestMode) {
        $c = $common.Clone(); $c.Machine = $script:Machine; $c.L = $script:LangFake
        $res = $null; $err = ''
        try { $res = & ([scriptblock]::Create($script:LangWorkerText)) $Kind $c } catch { $err = $_.Exception.Message }
        $script:LangJob = @{ Inline = $true; Result = $res; Err = $err; Kind = $Kind; Task = $task }
    }
    else {
        $ps = [powershell]::Create()
        [void]$ps.AddScript({
                param($AppRoot, $Kind, $Common, $Gate, $WorkerText)
                $ErrorActionPreference = 'Stop'
                Import-Module (Join-Path $AppRoot 'Modules\AVDTune.psm1') -Force
                foreach ($part in 'Updates', 'Language') { Import-Module (Join-Path $AppRoot "Modules\AVDTune.$part.psm1") -Force }
                $c = $Common.Clone(); $c.Machine = New-AVDTuneMachine; $c.L = New-AVDTuneLanguageAdapter
                if ($Gate) { Open-AVDTuneWriteGate -SnapshotId $Gate.SnapshotId -ConfirmedBy $Gate.ConfirmedBy }
                & ([scriptblock]::Create($WorkerText)) $Kind $c
            }).AddArgument($script:AppRoot).AddArgument($Kind).AddArgument($common).AddArgument($gate).AddArgument($script:LangWorkerText)
        $script:LangJob = @{ PS = $ps; Handle = $ps.BeginInvoke(); Kind = $Kind; Task = $task }
    }
    Set-ShutdownBlock $true
    Set-LangBusy $true
}
function Complete-LangJob {
    $job = $script:LangJob
    if (-not $job) { return }
    if (-not $job.Inline -and -not $job.Handle.IsCompleted) { return }
    $script:LangJob = $null
    Set-ShutdownBlock $false
    $run = $null; $err = ''
    if ($job.Inline) { $run = $job.Result; $err = [string]$job.Err }
    else {
        try { $out = @($job.PS.EndInvoke($job.Handle)); if ($job.PS.Streams.Error.Count -gt 0) { $err = $job.PS.Streams.Error[0].Exception.Message }; $run = $out | Select-Object -Last 1 }
        catch { $err = $_.Exception.Message }
        finally { $job.PS.Dispose() }
    }
    Set-LangBusy $false
    if ($err -or -not $run) { $msg = "Language and region failed: $err"; Complete-AVDTuneUiTask $job.Task -Failed -Summary $msg; $ui.TxtLangState.Text = $msg; Show-Error $msg; Update-LangView; return }
    foreach ($r in @($run.Results)) { Register-StepResult $r }
    $n = @($run.Results | Where-Object { $_.Status -in 'Changed', 'Reverted' }).Count; $f = @($run.Results | Where-Object { $_.Status -eq 'Failed' })
    $text = "Language and region: $n change(s)$(if ($f.Count -gt 0) { ", $($f.Count) failed: $($f[0].Message)" })$(if ($run.Reboot) { '. Restart the master before you go on' })."
    $ui.TxtLangState.Text = $text
    Complete-AVDTuneUiTask $job.Task -Failed:([bool]($f.Count -gt 0)) -Summary $text
    Show-Toast $text
    [void](Add-AVDTuneProtocolNote -Protocol $script:Protocol -Group 'language' -Subject $text)
    Save-Protocol
    Start-OverviewRefresh
    Update-LangView
}
$script:Timer.Add_Tick({ try { Complete-LangJob } catch { Show-Error $_.Exception.Message } })

function Save-LangConfig($Cfg) { [void](Set-AVDTuneLanguageConfig -Root $script:StateRoot -Config $Cfg) }

Add-Click $ui.BtnLangRefresh { Update-LangView; $ui.TxtLangState.Text = 'Read again: nothing was changed.' }
Add-Click $ui.BtnLangTest {
    $cfg = Get-LangFormConfig
    $problems = @(Test-AVDTuneLanguageConfig $cfg -InstalledTags @($script:LangState.Installed | ForEach-Object { $_.Tag })); if ($problems.Count -gt 0) { throw ($problems -join ' ') }
    $run = Invoke-AVDTuneLanguage -Machine $script:Machine -L (Get-LangAdapter) -Root $script:StateRoot -Config $cfg -Parts All -WhatIf
    $n = @($run.Results | Where-Object { $_.Status -eq 'WhatIf' }).Count; $f = @($run.Results | Where-Object { $_.Status -eq 'Failed' })
    $ui.TxtLangState.Text = "Tested: $n step(s) would change something$(if ($f.Count -gt 0) { "; $($f.Count) would fail: $($f[0].Message)" }). Nothing was changed."
}
Add-Click $ui.BtnLangInstall {
    Assert-FslWrite
    $cfg = Get-LangFormConfig
    $inst = @($script:LangState.Installed | ForEach-Object { $_.Tag })
    $new = @($cfg.Languages | Where-Object { $_ -notin $inst })
    if ($new.Count -eq 0) { throw 'Tick at least one language that is not installed yet.' }
    $problems = @(Test-AVDTuneLanguageConfig $cfg -InstalledTags $inst); if ($problems.Count -gt 0) { throw ($problems -join ' ') }
    $chk = & (Get-LangAdapter).CheckSource $cfg.Source $script:StateRoot
    if (-not $chk.Ok) { throw "The content folder is not usable: $($chk.Problem)" }
    if (-not (Confirm-Action (Get-AVDTuneLanguageConfirmText -Mode Languages -Config $cfg -State $script:LangState -SourceKind $chk.Kind) 'Language and region: cannot be undone')) { return }
    Save-LangConfig $cfg
    Start-LangJob 'Languages' $cfg; $ui.TxtLangState.Text = 'Installing languages ...'
}
Add-Click $ui.BtnLangApply {
    Assert-FslWrite
    $cfg = Get-LangFormConfig
    $inst = @($script:LangState.Installed | ForEach-Object { $_.Tag })
    $kind = 'Defaults'
    if ($cfg.UiLanguage -and $cfg.UiLanguage -inotin $inst) {
        if (-not $cfg.Source) { throw "The display language $($cfg.UiLanguage) is not installed. Enter the content folder to install it first, or choose an installed language." }
        if (-not (Confirm-Action "The display language $($cfg.UiLanguage) is not installed yet. Install it first from $($cfg.Source), then set the defaults?" 'Language and region')) { return }
        $cfg.Languages = @(@($cfg.Languages) + $cfg.UiLanguage | Select-Object -Unique); $kind = 'All'
    }
    elseif (@($cfg.Languages | Where-Object { $_ -notin $inst }).Count -gt 0) { $kind = 'All' }
    $problems = @(Test-AVDTuneLanguageConfig $cfg -InstalledTags $inst); if ($problems.Count -gt 0) { throw ($problems -join ' ') }
    $mode = if ($kind -eq 'All') { 'All' } else { 'Defaults' }
    $srcKind = ''
    if ($kind -eq 'All') { $chk = & (Get-LangAdapter).CheckSource $cfg.Source $script:StateRoot; if (-not $chk.Ok) { throw "The content folder is not usable: $($chk.Problem)" }; $srcKind = $chk.Kind }
    if (-not (Confirm-Action (Get-AVDTuneLanguageConfirmText -Mode $mode -Config $cfg -State $script:LangState -SourceKind $srcKind) $(if ($kind -eq 'All') { 'Language and region: cannot be undone' } else { 'Language and region' }))) { return }
    Save-LangConfig $cfg
    Start-LangJob $kind $cfg; $ui.TxtLangState.Text = 'Setting the defaults for new users ...'
}
Add-Click $ui.BtnLangUndo {
    Assert-FslWrite
    if (-not (Confirm-Action (Get-AVDTuneLanguageConfirmText -Mode Undo) 'Language and region')) { return }
    Start-LangJob 'Undo' $null; $ui.TxtLangState.Text = 'Undoing the language defaults ...'
}
