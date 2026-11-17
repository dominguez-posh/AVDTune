# The start sequence in the window (dot-sourced by Start-AVDTune.ps1 after the Overview and the protocol are set up).
# Four stages on the Overview, each with a status and a form that opens below the list, in this order (issue #64): Microsoft sign-in (needs no answer),
# domain controller (the master's join state is read first; a DC step only for a domain member), first-run questions (suggested from the sign-in, Azure and the
# domain with the source of every value, valid after the confirmation), snapshot gate. The logic is in Modules\AVDTune.Start/Session/Snapshot/Directory.psm1; this file only
# builds the forms, calls the engine and writes the protocol. External services come from $script:Services (real adapters, or the fakes
# of Tests\Fakes\FakeServices.ps1 in test mode). Secrets: the password stays in the PasswordBox / a SecureString and is cleared after use.

$script:StartContext = New-AVDTuneStartContext
$script:OpenStage = ''
$script:Form = @{}
$script:StageKinds = @{ Done = @('SuccessBg', 'Success'); Pending = @('AccentSubtle', 'Primary'); Locked = @('Hover', 'MutedText'); Skipped = @('Hover', 'MutedText'); Failed = @('ErrorBg', 'Danger') }   # the text of a pill: stage.pill.<status>
# the buttons of the stages: stage.btn.<id>.todo and stage.btn.<id>.done
$script:SnapTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:SnapTimer.Interval = [TimeSpan]::FromMilliseconds($(if ($script:SmokeOn) { 300 } else { 4000 }))
$script:PendingSnapshot = $null

# ---------------------------------------------------------------- services
function Get-StartAuth {
    if ($script:TestMode) { return $script:Services.Auth }
    New-AVDTuneAuthAdapter -Owner $window -CacheFolder (Join-Path $script:StateRoot 'WebView2') -Log {
        param($Text, $Level) if ($Level -eq 'Warning') { Add-StartProtocol 'Warning: sign-in window' $Text } }
}
# Where the sign-in window leaves its temporary profiles: the temp folder of this user (a folder of the test state in test mode)
function Get-StartTempRoot { if ($script:TestMode) { Join-Path $script:StateRoot 'signin-temp' } else { [IO.Path]::GetTempPath() } }
function Get-StartArm { if ($script:TestMode) { $script:Services.Arm } else { if (-not $script:RealArm) { $script:RealArm = New-AVDTuneArmAdapter }; $script:RealArm } }
function Get-StartLdap { if ($script:TestMode) { $script:Services.Ldap } else { New-AVDTuneLdapAdapter } }

# ---------------------------------------------------------------- helpers
function Add-StartProtocol([string]$Subject, [string]$Note, [string]$Result = 'ok') {
    [void](Add-PackTuneProtocolAction -Protocol $script:Protocol -Category 'setup' -Subject $Subject -Result $Result -Note (Remove-PackTuneProtocolSecrets $Note 200))
    Save-Protocol
}
function Set-StageMessage([string]$Text, [string]$Kind = 'info') {
    $ui.TxtStageMessage.Text = $Text
    $key = switch ($Kind) { 'ok' { 'Success' } 'error' { 'Danger' } 'warn' { 'Warning' } default { 'MutedText' } }
    Set-Brush $ui.TxtStageMessage ([System.Windows.Controls.TextBlock]::ForegroundProperty) $key
}
function Invoke-Busy([string]$Text, [scriptblock]$Block, [string]$TaskTitle = '', [string]$Done = '') {
    # A call to a service from the window thread: the message shows first, the wait cursor while it runs (every call has its own timeout).
    # With -TaskTitle it is also a task of the task bar (running, then done or failed with the cause).
    Set-StageMessage $Text 'info'
    $window.Cursor = [System.Windows.Input.Cursors]::Wait
    try {
        $window.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Render)
        if ($TaskTitle) { Invoke-UiTaskInline -Kind 'stage' -Title $TaskTitle -Step $Text -Done $Done -Block $Block } else { & $Block }
    }
    finally { $window.Cursor = $null }
}
function New-FormRow([string]$Label, $Control, [string]$AutomationName) {
    $grid = New-Object System.Windows.Controls.Grid
    $grid.Margin = '0,4,0,4'
    $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = 250
    $c2 = New-Object System.Windows.Controls.ColumnDefinition; $c2.Width = '*'
    [void]$grid.ColumnDefinitions.Add($c1); [void]$grid.ColumnDefinitions.Add($c2)
    $l = New-Object System.Windows.Controls.TextBlock; $l.Text = $Label; $l.VerticalAlignment = 'Center'; $l.TextWrapping = 'Wrap'; $l.Margin = '0,0,12,0'
    $Control.SetValue([System.Windows.Controls.Grid]::ColumnProperty, 1)
    $Control.HorizontalAlignment = 'Left'
    [System.Windows.Automation.AutomationProperties]::SetName($Control, $(if ($AutomationName) { $AutomationName } else { $Label }))
    [void]$grid.Children.Add($l); [void]$grid.Children.Add($Control)
    $grid
}
function New-Text([string]$Text, [string]$Style, [string]$Margin = '0,0,0,0') {
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $Text; $t.TextWrapping = 'Wrap'; $t.Margin = $Margin
    if ($Style) { Set-Brush $t ([System.Windows.Controls.TextBlock]::StyleProperty) $Style }
    $t
}
function New-MonoBox([string]$Text, [int]$Height = 160) {
    $b = New-Object System.Windows.Controls.TextBox
    Set-Brush $b ([System.Windows.Controls.Control]::StyleProperty) 'SelectableText'
    $b.Text = $Text; $b.Height = $Height; $b.AcceptsReturn = $true; $b.VerticalScrollBarVisibility = 'Auto'; $b.FontFamily = 'Cascadia Mono, Consolas'; $b.FontSize = 12; $b.Padding = '10,8'
    Set-Brush $b ([System.Windows.Controls.Control]::ForegroundProperty) 'Text'
    $b.Background = [System.Windows.Media.Brushes]::Transparent
    $b
}
function Reset-StageButtons {
    foreach ($b in $ui.BtnStageAction, $ui.BtnStageAction2) { $b.IsEnabled = $true }
    $ui.BtnStageAction2.Visibility = 'Collapsed'
    $ui.BtnStageAction.Visibility = 'Visible'
    $script:StageAction = $null; $script:StageAction2 = $null
}
Add-Click $ui.BtnStageAction { if ($script:StageAction) { & $script:StageAction } }
Add-Click $ui.BtnStageAction2 { if ($script:StageAction2) { & $script:StageAction2 } }
Add-Click $ui.BtnStageClose { Close-Stage }
Add-Click $ui.BtnReadOnlyGo { Show-Page 'Overview' }

function Close-Stage {
    $script:OpenStage = ''
    $script:SnapTimer.Stop()
    if ($script:Form.PasswordBox) { $script:Form.PasswordBox.Clear() }
    $script:Form = @{}
    $ui.PanelStageBody.Children.Clear()
    $ui.BoxStage.Visibility = 'Collapsed'
}

# ---------------------------------------------------------------- stage list
function Update-StartView {
    $stages = @(Get-AVDTuneStartStages -Context $script:StartContext -Root $script:StateRoot)
    $script:Stages = $stages
    $ui.PanelStages.Children.Clear()
    $number = 0
    foreach ($stage in $stages) {
        $number++
        $grid = New-Object System.Windows.Controls.Grid
        $grid.Margin = '0,8,0,8'
        foreach ($w in 110, 230, '*', 'Auto') { $c = New-Object System.Windows.Controls.ColumnDefinition; $c.Width = $w; [void]$grid.ColumnDefinitions.Add($c) }
        $kind = $script:StageKinds[[string]$stage.Status]
        $pill = New-Object System.Windows.Controls.Border
        Set-Brush $pill ([System.Windows.Controls.Border]::StyleProperty) 'Pill'
        $pill.Padding = '10,2'; $pill.VerticalAlignment = 'Center'
        Set-Brush $pill ([System.Windows.Controls.Border]::BackgroundProperty) $kind[0]
        $pt = New-Object System.Windows.Controls.TextBlock; $pt.Text = T "stage.pill.$(([string]$stage.Status).ToLowerInvariant())"; $pt.FontSize = 12; $pt.FontWeight = 'SemiBold'
        Set-Brush $pt ([System.Windows.Controls.TextBlock]::ForegroundProperty) $kind[1]
        $pill.Child = $pt
        $title = New-Object System.Windows.Controls.TextBlock; $title.Text = "$number. $(Convert-AVDTuneEngineText 'stage.title.' ([string]$stage.Title))"; $title.FontWeight = 'SemiBold'; $title.VerticalAlignment = 'Center'; $title.SetValue([System.Windows.Controls.Grid]::ColumnProperty, 1)
        $detail = New-Object System.Windows.Controls.TextBlock; $detail.Text = Convert-AVDTuneEngineText 'stage.detail.' ([string]$stage.Detail); $detail.TextWrapping = 'Wrap'; $detail.VerticalAlignment = 'Center'; $detail.SetValue([System.Windows.Controls.Grid]::ColumnProperty, 2)
        $detail.Margin = '0,0,12,0'
        Set-Brush $detail ([System.Windows.Controls.TextBlock]::ForegroundProperty) $(if ($stage.Status -eq 'Failed') { 'Danger' } else { 'MutedText' })
        [void]$grid.Children.Add($pill); [void]$grid.Children.Add($title); [void]$grid.Children.Add($detail)
        if ($stage.Status -ne 'Skipped') {
            $btn = New-Object System.Windows.Controls.Button
            $btn.Content = T "stage.btn.$(([string]$stage.Id).ToLowerInvariant()).$(if ($stage.Status -eq 'Done') { 'done' } else { 'todo' })"
            $btn.DataContext = [string]$stage.Id; $btn.Name = "BtnStage$($stage.Id)"; $btn.VerticalAlignment = 'Center'; $btn.SetValue([System.Windows.Controls.Grid]::ColumnProperty, 3)
            if ($stage.Status -eq 'Pending' -or $stage.Status -eq 'Failed') { Set-Brush $btn ([System.Windows.Controls.Control]::StyleProperty) 'PrimaryButton' }
            $btn.IsEnabled = ($stage.Status -ne 'Locked')
            [System.Windows.Automation.AutomationProperties]::SetName($btn, "$($btn.Content): $($stage.Title)")
            $btn.Add_Click({ param($src) try { Open-Stage ([string]$src.DataContext) } catch { Show-Error $_.Exception.Message } })
            [void]$grid.Children.Add($btn)
            $ui[$btn.Name] = $btn
        }
        [void]$ui.PanelStages.Children.Add($grid)
    }
    Update-ReadOnlyBanner
    Update-RollbackCard
    Update-NavVisibility
}

function Update-ReadOnlyBanner {
    $locked = -not (Test-AVDTuneWriteAllowed)
    $ui.BoxReadOnly.Visibility = ConvertTo-Vis ($locked -and $script:CurrentPage -notin 'Overview', 'Protocol')
}
function Update-NavVisibility {
    # FSLogix and App Masking disappear when the answers say there is no FSLogix
    $e = Get-AVDTuneEnvironment $script:StateRoot
    $hidden = @(); if ($e) { $hidden = @((Resolve-AVDTuneEnvironmentPlan (Get-AVDTuneEnvironmentAnswers $e)).HiddenPages) }
    foreach ($page in $script:PageTable) { $ui["Nav$($page.Key)"].Visibility = ConvertTo-Vis ($page.Key -notin $hidden) }
}
function Update-RollbackCard {
    $gate = (Get-AVDTuneState $script:StateRoot).PSObject.Properties['SnapshotGate']
    $show = (Test-AVDTuneWriteAllowed) -and $gate -and $gate.Value
    $ui.BoxRollback.Visibility = ConvertTo-Vis ([bool]$show)
    if ($show) {
        $ui.TxtRollback.Text = T 'start.rollback' $gate.Value.SnapshotName
    }
}

function Open-Stage([string]$Id) {
    $stage = $script:Stages | Where-Object Id -eq $Id | Select-Object -First 1
    if (-not $stage -or $stage.Status -eq 'Locked' -or $stage.Status -eq 'Skipped') { return }
    Close-Stage
    $script:OpenStage = $Id
    Reset-StageButtons
    $ui.BoxStage.Visibility = 'Visible'
    $ui.TxtStageMessage.Text = ''
    switch ($Id) {
        'Environment' { Build-EnvironmentForm }
        'SignIn' { Build-SignInForm }
        'Domain' { if (-not $script:StartContext.Detection) { Read-JoinState }; if ($script:JoinJob) { Close-Stage; Show-Toast 'Still reading how this master is joined; the step can be opened when that is done.'; return }; Build-DomainForm }
        'Snapshot' { Build-SnapshotForm }
    }
    $ui.BoxStage.BringIntoView()
}

# ---------------------------------------------------------------- 3. first-run questions
# Asked after the sign-in and the domain step (issue #64). What the sign-in, Azure (GET only) and the domain showed is suggested with its source and is only a
# suggestion: nothing is saved and nothing counts as an answer until the administrator presses the confirm button. A question that is missing or ambiguous stays empty.
function Build-EnvironmentForm {
    $ui.TxtStageTitle.Text = T 'stage.env.title'
    $ui.TxtStageIntro.Text = T 'stage.env.intro'
    $existing = Get-AVDTuneEnvironment $script:StateRoot
    $file = Get-AVDTuneEnvironmentFile $script:StateRoot
    $answers = Get-AVDTuneEnvironmentAnswers $(if ($existing) { $existing } else { $file })
    $f = $script:Form; $f.Combos = @{}; $f.Texts = @{}; $f.SourceLabels = @{}
    $f.KeepClient = [string]$answers.ClientId; $f.KeepTenant = [string]$answers.TenantId
    $f.PrevAnswers = $(if ($existing) { $answers } else { $null }); $f.PrevSources = $(if ($existing) { Get-AVDTuneAnswerSources $existing } else { $null })
    # What the sign-in and Azure showed, once per start of the questions (the Region and the notes are information only)
    $f.Suggestions = $null
    if (-not $existing) {
        if (-not $script:StartContext.Detection) { Read-JoinState }
        if ($script:JoinJob) { Close-Stage; Show-Toast 'Still reading how this master is joined; the questions can be opened when that is done.'; return }
        try {
            $sg = Invoke-Busy 'Reading what Azure says about this VM (read only) ...' { Update-AVDTuneStartSuggestions -Context $script:StartContext -Machine $script:Machine -Arm (Get-StartArm) } -TaskTitle 'Reading the VM from Azure' -Done 'Read'
            $f.Suggestions = $sg
        }
        catch { Add-StartProtocol 'Suggestions for the first-run questions' $_.Exception.Message 'failed' }
        if ($f.Suggestions) {
            $count = @($f.Suggestions.Items.Values | Where-Object { $_.State -eq 'Detected' }).Count
            Add-StartProtocol 'Suggestions for the first-run questions' ("$count value(s) suggested (read only: Win32_ComputerSystem, dsregcmd /status, Azure Resource Manager GET)" + $(if (@($f.Suggestions.Notes).Count -gt 0) { '. ' + (@($f.Suggestions.Notes) -join '; ') }) + $(if (@($f.Suggestions.Rejected).Count -gt 0) { '. Not suggested, not valid: ' + (@($f.Suggestions.Rejected) -join '; ') }))
        }
        $facts = $script:StartContext.AzureFacts
        if ($f.Suggestions -and $f.Suggestions.Region) { [void]$ui.PanelStageBody.Children.Add((New-InfoRow 'Region of this VM' "$($f.Suggestions.Region) (Azure Resource Manager)")) }
        if ($facts -and -not $facts.Reachable) { $ui.PanelStageBody.Children.Add((New-Text "Azure could not be read ($($facts.Problem)). The questions below have no suggestion from Azure; answer them yourself." 'Hint' '0,0,0,6')) | Out-Null }
    }
    foreach ($q in (Get-AVDTuneQuestions)) {
        $cmb = New-Object System.Windows.Controls.ComboBox
        $cmb.Width = 430
        $cmb.ItemsSource = @($q.Choices | ForEach-Object { $_.Text })
        $current = $null
        if ($existing) { $current = @($q.Choices | Where-Object { $_.Value -eq $answers.($q.Key) })[0] }
        elseif ($f.Suggestions -and $f.Suggestions.Items.Contains($q.Key) -and $f.Suggestions.Items[$q.Key].State -eq 'Detected') { $current = @($q.Choices | Where-Object { $_.Value -ceq $f.Suggestions.Items[$q.Key].Value })[0] }
        if ($current) { $cmb.SelectedItem = $current.Text }   # no suggestion and no saved answer: nothing selected, the question is open
        $cmb.Name = "Q$($q.Key)"
        $f.Combos[$q.Key] = @{ Control = $cmb; Question = $q }
        $cmb.Add_SelectionChanged({ try { Update-EnvironmentPreview } catch { } })
        [void]$ui.PanelStageBody.Children.Add((New-FormRow $q.Title $cmb))
        $f.SourceLabels[$q.Key] = New-Text '' 'Hint' '250,0,0,4'
        [void]$ui.PanelStageBody.Children.Add($f.SourceLabels[$q.Key])
    }
    $auth = New-Object System.Windows.Controls.ComboBox; $auth.Width = 430; $auth.Name = 'QAzureFilesAuth'
    $auth.Add_SelectionChanged({ try { Update-EnvironmentPreview } catch { } })
    $f.AuthCombo = $auth; $f.AuthWanted = [string]$answers.AzureFilesAuth
    [void]$ui.PanelStageBody.Children.Add((New-FormRow (T 'stage.env.azurefiles') $auth))
    # No tenant field: the tenant comes from the sign-in (issue #11). The client ID is entered in the sign-in form (#64).
    foreach ($t in @(@('VNet', (T 'stage.env.vnet')), @('Subnet', (T 'stage.env.subnet')), @('SnapshotNamePattern', (T 'stage.env.snapname')))) {
        $tb = New-Object System.Windows.Controls.TextBox; $tb.Width = 430; $tb.Text = [string]$answers.($t[0]); $tb.MaxLength = 255; $tb.Name = "T$($t[0])"
        if (-not $existing -and $t[0] -in 'VNet', 'Subnet') { $tb.Text = $(if ($f.Suggestions -and $f.Suggestions.Items.Contains($t[0]) -and $f.Suggestions.Items[$t[0]].State -eq 'Detected') { [string]$f.Suggestions.Items[$t[0]].Value } else { '' }) }
        $tb.Add_TextChanged({ try { Update-EnvironmentPreview } catch { } })
        $f.Texts[$t[0]] = $tb
        [void]$ui.PanelStageBody.Children.Add((New-FormRow $t[1] $tb))
        $f.SourceLabels[$t[0]] = New-Text '' 'Hint' '250,0,0,4'
        [void]$ui.PanelStageBody.Children.Add($f.SourceLabels[$t[0]])
    }
    $f.ForgetTenant = $null
    if ([string]$answers.TenantId) {
        # The saved tenant is shown, not edited; forgetting it is the only way to change it (the next sign-in sets it again, change log)
        $forget = New-Object System.Windows.Controls.CheckBox; $forget.Name = 'ChkForgetTenant'; $forget.VerticalAlignment = 'Center'
        $forget.Content = T 'stage.env.forget' $answers.TenantId
        $f.ForgetTenant = $forget
        [void]$ui.PanelStageBody.Children.Add((New-FormRow (T 'stage.env.tenant') $forget (T 'stage.env.forget.name')))
    }
    $f.Preview = New-Text '' 'Hint' '0,10,0,0'
    [void]$ui.PanelStageBody.Children.Add($f.Preview)
    $ui.BtnStageAction.Content = T 'stage.env.save'
    $script:StageAction = { Save-EnvironmentForm }
    Update-EnvironmentPreview
}
function Get-EnvironmentFormAnswers {
    $f = $script:Form
    $a = Get-AVDTuneEnvironmentDefaults
    foreach ($key in $f.Combos.Keys) {
        $q = $f.Combos[$key].Question
        $text = [string]$f.Combos[$key].Control.SelectedItem
        $a.$key = [string](@($q.Choices | Where-Object { $_.Text -eq $text })[0]).Value   # nothing selected: '' (the question is missing)
    }
    foreach ($key in $f.Texts.Keys) { $a.$key = [string]$f.Texts[$key].Text }
    $a.ClientId = [string]$f.KeepClient; $a.TenantId = [string]$f.KeepTenant
    $choices = @(Get-AVDTuneAzureFilesAuthChoices $a)
    $sel = [string]$f.AuthCombo.SelectedItem
    $a.AzureFilesAuth = if ($sel -and $sel -notlike 'Automatic*' -and $sel -in $choices) { $sel } else { 'Auto' }
    $a
}
function Update-EnvironmentSourceLabels($Answers) {
    # The source next to every answer: a suggestion that is kept, a changed one, an open question (with the reason it is ambiguous), a saved answer
    $f = $script:Form
    $sources = Resolve-AVDTuneAnswerSources -Answers $Answers -Suggestions $f.Suggestions -PreviousAnswers $f.PrevAnswers -PreviousSources $f.PrevSources
    foreach ($key in $f.SourceLabels.Keys) {
        $value = [string](Get-AVDTuneProp $Answers $key)
        $sg = $null; if ($f.Suggestions -and $f.Suggestions.Items.Contains($key)) { $sg = $f.Suggestions.Items[$key] }
        $text = if ($f.Combos.ContainsKey($key) -and -not $value) { $(if ($sg -and $sg.Hint) { "Please answer: $($sg.Hint)" } else { 'Please answer.' }) }
        elseif ($sg -and $sg.State -eq 'Detected' -and $sg.Value -ceq $value) { "Suggested, counts after you confirm: $($sg.Source)" }
        elseif ($f.PrevAnswers -and $f.PrevSources -and [string](Get-AVDTuneProp $f.PrevAnswers $key) -ceq $value -and $f.PrevSources.Contains($key)) { "Saved: $($f.PrevSources[$key])" }
        elseif ($f.PrevAnswers -and [string](Get-AVDTuneProp $f.PrevAnswers $key) -ceq $value) { 'Saved answer (from an earlier version, no source recorded)' }
        elseif ($sg -and $sg.State -eq 'Detected') { "Changed by you (suggested $($sg.Value): $($sg.Source))" }
        elseif (-not $value) { 'Not set (optional).' }
        else { 'Typed by you.' }
        $f.SourceLabels[$key].Text = $text
    }
    $sources
}
function Update-EnvironmentPreview {
    $f = $script:Form
    if (-not $f.Combos -or $f.Updating) { return }
    $f.Updating = $true
    try {
        $a = Get-EnvironmentFormAnswers
        $choices = @(Get-AVDTuneAzureFilesAuthChoices $a)
        $keep = if ($f.AuthWanted) { $f.AuthWanted } else { [string]$f.AuthCombo.SelectedItem }
        $plan = Resolve-AVDTuneEnvironmentPlan $a
        $items = if ($choices.Count -eq 0) { @('Not needed (no Azure Files)') } else { @("Automatic ($($plan.AzureFilesAuth))") + @($choices) }
        $f.AuthCombo.ItemsSource = $items
        $f.AuthCombo.SelectedItem = if ($keep -and $keep -in $choices -and $keep -ne $choices[0]) { $keep } else { $items[0] }
        $f.AuthWanted = $null
        $a = Get-EnvironmentFormAnswers
        $check = Test-AVDTuneEnvironmentAnswers $a
        $plan = Resolve-AVDTuneEnvironmentPlan $a
        [void](Update-EnvironmentSourceLabels $a)
        $open = @($f.Combos.Keys | Where-Object { -not [string](Get-AVDTuneProp $a $_) } | ForEach-Object { $f.Combos[$_].Question.Title })
        $errors = @($check.Errors | Where-Object { $_ -notlike '*is missing or unknown.' })
        $lines = @(); if ($open.Count -gt 0) { $lines += "Still to answer: $($open -join '; ')." } else { $lines += @($plan.Notes) }
        $lines += @($check.Warnings | ForEach-Object { (T 'stage.env.note' $_) }) + @($errors | ForEach-Object { (T 'stage.env.problem' $_) })
        $lines += T 'stage.env.notenant'
        $f.Preview.Text = $lines -join "`n"
        Set-Brush $f.Preview ([System.Windows.Controls.TextBlock]::ForegroundProperty) $(if ($errors.Count -gt 0) { 'Danger' } else { 'MutedText' })
        $ui.BtnStageAction.IsEnabled = ($check.Errors.Count -eq 0)
    }
    finally { $f.Updating = $false }
}
function Save-EnvironmentForm {
    $f = $script:Form
    $a = Get-EnvironmentFormAnswers
    $firstRun = -not (Get-AVDTuneEnvironment $script:StateRoot)
    $forget = [bool]($f.ForgetTenant -and $f.ForgetTenant.IsChecked)
    $sources = Resolve-AVDTuneAnswerSources -Answers $a -Suggestions $f.Suggestions -PreviousAnswers $f.PrevAnswers -PreviousSources $f.PrevSources
    $result = Save-AVDTuneEnvironment -Root $script:StateRoot -Answers $a -User ([string]$env:USERNAME) -ForgetTenant:$forget -Sources $sources
    if ($forget -and $script:StartContext.Session) { Disconnect-AVDTuneSession $script:StartContext.Session }   # a session of the old tenant does not stay
    $confirmed = @($sources.Values | Where-Object { $_ -like 'Confirmed: *' }).Count
    $note = $(if ($result.Changes.Count -gt 0) { 'changed: ' + ($result.Changes -join '; ') } else { 'saved' }) + $(if ($confirmed -gt 0) { "; $confirmed suggestion(s) confirmed" })
    Add-StartProtocol 'First-run questions answered (identity model)' $note
    Show-Toast (T 'stage.env.saved')
    Close-Stage
    Update-StartView
    if ($script:CurrentPage -eq 'Protocol') { Update-ProtocolView }
    # First run: the small question about the desktop shortcut (installed copy only; otherwise the hint to install first)
    if ($firstRun -and -not (Show-ShortcutQuestion) -and (Get-AVDTuneShortcutOffer -Root $script:StateRoot -Mode (Get-ShortcutMode)) -eq 'Install') { Show-Toast (T 'stage.env.saved.shortcut') }
}

# ---------------------------------------------------------------- 1. sign-in
function Build-SignInForm {
    $ui.TxtStageTitle.Text = T 'stage.signin.title'
    $ui.TxtStageIntro.Text = T 'stage.signin.intro'
    $session = $script:StartContext.Session
    foreach ($key in (Get-AVDTuneAudience).Keys) {
        $a = (Get-AVDTuneAudience)[$key]
        [void]$ui.PanelStageBody.Children.Add((New-InfoRow $key ("$($a.Purpose): " + ($a.Scopes -join ', '))))
    }
    $e = Get-AVDTuneEnvironmentFile $script:StateRoot   # the sign-in needs no answer of the first-run questions: the file may not exist yet
    $tenant = if ($e) { [string](Get-AVDTuneProp (Get-AVDTuneProp $e 'SignIn') 'TenantId') } else { '' }
    $client = if ($e) { [string](Get-AVDTuneProp (Get-AVDTuneProp $e 'SignIn') 'ClientId') } else { '' }
    [void]$ui.PanelStageBody.Children.Add((New-InfoRow (T 'stage.signin.tenant') $(if ($tenant) { $tenant } else { T 'stage.signin.tenant.none' })))
    [void]$ui.PanelStageBody.Children.Add((New-InfoRow (T 'stage.signin.app') $(if ($client) { $client } else { T 'stage.signin.app.none' })))
    $f = $script:Form
    $f.Account = New-Object System.Windows.Controls.TextBox; $f.Account.Width = 320; $f.Account.MaxLength = 254; $f.Account.Name = 'TxtSignInAccount'
    $f.Account.Text = if ($session -and $session.Account) { [string]$session.Account } else { '' }
    [void]$ui.PanelStageBody.Children.Add((New-FormRow (T 'stage.signin.account') $f.Account (T 'stage.signin.account.name')))
    if (-not $client) {
        # An existing app registration of AVDTune can be entered here (moved from the first-run questions: the sign-in comes first and needs no answer)
        $f.ClientId = New-Object System.Windows.Controls.TextBox; $f.ClientId.Width = 320; $f.ClientId.MaxLength = 36; $f.ClientId.Name = 'TxtSignInClientId'
        [void]$ui.PanelStageBody.Children.Add((New-FormRow 'Client ID of an existing app registration (optional)' $f.ClientId 'Client ID of an existing app registration'))
    }
    $hint = if (-not $client) {
        T 'stage.signin.hint.first'
    }
    elseif (-not $tenant) { T 'stage.signin.hint.tenant' }
    else { T 'stage.signin.hint.ok' }
    $ui.PanelStageBody.Children.Add((New-Text $hint 'Hint' '0,8,0,0')) | Out-Null
    if ($session -and $session.Connected) {
        $info = Get-AVDTuneSessionInfo $session
        Set-StageMessage (T 'stage.signin.signedin' $info.Account $(if ($info.Name) { " ($($info.Name))" } else { '' }) (($info.Audiences | ForEach-Object { T 'stage.signin.until' $_.Audience (([datetime]$_.ExpiresOn).ToLocalTime().ToString('HH:mm')) }) -join ', ')) 'ok'
        $ui.BtnStageAction.Content = T 'stage.btn.signin.done'
        $ui.BtnStageAction2.Content = T 'stage.signin.signout'; $ui.BtnStageAction2.Visibility = 'Visible'
        $script:StageAction2 = { Invoke-SignOut }
    }
    else {
        $ui.BtnStageAction.Content = T 'stage.btn.signin.todo'
        $f = $script:StartContext.Failures['SignIn']; if ($f) { Set-StageMessage ([string]$f) 'error' }
        if ($client) {
            # Another administrator: runs the setup with his account (assignment + his own consent); also checks the saved registration
            $ui.BtnStageAction2.Content = T 'stage.signin.setup'; $ui.BtnStageAction2.Visibility = 'Visible'
            $script:StageAction2 = { Invoke-SignIn -Setup }
        }
    }
    $script:StageAction = { Invoke-SignIn }
}
function Invoke-SignIn([switch]$Setup) {
    $e = Get-AVDTuneEnvironmentFile $script:StateRoot
    $savedClient = if ($e) { [string](Get-AVDTuneProp (Get-AVDTuneProp $e 'SignIn') 'ClientId') } else { '' }
    $account = if ($script:Form.Account) { ([string]$script:Form.Account.Text).Trim() } else { '' }
    if ($account -and -not (Get-AVDTuneAccountDomain $account)) { Set-StageMessage (T 'stage.signin.badaccount') 'error'; return }
    $typedClient = if ($script:Form.ClientId) { ([string]$script:Form.ClientId.Text).Trim() } else { '' }
    if ($typedClient -and -not (Test-AVDTuneTenantGuid $typedClient)) { Set-StageMessage 'The client ID must be a GUID (or leave it empty).' 'error'; return }
    if ($typedClient -ieq '14d82eec-204b-4c2f-b7e8-296a70dab67e') { Set-StageMessage "That is Microsoft's setup app; AVDTune needs the client ID of its own app registration (leave the field empty and AVDTune creates it at the sign-in)." 'error'; return }
    $setup = $Setup -or (-not $savedClient -and -not $typedClient)
    if ($setup -and -not (Confirm-Action (T 'stage.signin.confirm' $(if ($savedClient) { T 'stage.signin.confirm.check' $savedClient } else { T 'stage.signin.confirm.create' }) (Get-AVDTuneSetupConsentNote)) (T 'stage.signin.confirm.title'))) { return }
    $session = New-AVDTuneSession -Auth (Get-StartAuth) -TempRoot (Get-StartTempRoot)
    try {
        $result = Invoke-Busy $(if ($setup) { T 'stage.signin.busy.setup' } else { T 'stage.signin.busy' }) {
            Invoke-AVDTuneStartSignIn -Root $script:StateRoot -Session $session -Account $account -User ([string]$env:USERNAME) -RetryDelaySeconds $(if ($script:TestMode) { 0 } else { 5 }) -Setup:$setup -ClientId $typedClient } -TaskTitle (T 'stage.signin.task') -Done (T 'stage.signin.done')
        $info = $result.Info
        foreach ($n in @($result.Notes)) { Add-StartProtocol $(if ($n -like 'Warning:*' -or $n -like 'Note:*') { 'Warning: app registration' } else { 'Sign-in: tenant and app registration' }) $n }
        # The full text was in the confirmation; the protocol keeps the short form (notes are cut at 200 characters)
        if ($result.ConsentNote) { Add-StartProtocol 'Setup consent of Microsoft Graph Command Line Tools' "Your own consent loses the two setup permissions again. A consent for the whole organization stays: Entra admin center > Enterprise applications > Microsoft Graph Command Line Tools > Permissions." }
    }
    catch {
        $script:StartContext.Failures['SignIn'] = $_.Exception.Message
        Add-StartProtocol 'Microsoft 365 and Azure sign-in' $_.Exception.Message 'failed'
        Set-StageMessage $_.Exception.Message 'error'
        Update-StartView
        return
    }
    if ($script:StartContext.Session) { Disconnect-AVDTuneSession $script:StartContext.Session }
    $script:StartContext.Session = $session
    $script:StartContext.Failures.Remove('SignIn')
    Add-StartProtocol 'Microsoft 365 and Azure sign-in' ("Signed in as $($info.Account): " + (($info.Audiences | ForEach-Object { "$($_.Audience) ($($_.Scopes -join ', '))" }) -join '; '))
    $missing = @($info.Unavailable | ForEach-Object { $_.Reason })
    foreach ($w in @($info.Warnings)) { Add-StartProtocol $(if ($w -in $missing) { 'Warning: sign-in without the Storage token' } else { 'Warning: sign-in token with extra permissions' }) $w }
    # Step 2 follows the sign-in at once: what this master says about its join (read only; nothing is asked, nothing is changed)
    Read-JoinState
    Show-Toast (T 'stage.signin.toast' $info.Account)
    Close-Stage
    Update-StartView
    Start-ReadyJob 'Start' ''   # the Azure checks of the readiness analysis can read now
}
function Set-JoinStateResult($Detection) {
    # on the window thread: keep what the master said about its join and write it to the protocol
    $script:StartContext.Detection = $Detection; $script:StartContext.Suggestions = $null
    $det = $Detection
    Add-StartProtocol 'Join state of this master read' ($det.Reason + $(if (@($det.Facts).Count -gt 0) { ' (' + (@($det.Facts) -join '; ') + ')' }) + $(if (@($det.Problems).Count -gt 0) { ' Not read: ' + (@($det.Problems) -join '; ') }))
}
function Read-JoinState {
    # dsregcmd (30 s timeout) and the DC locator can take a while: the real read runs in a background runspace with a task on the task bar, the window stays usable.
    # Test mode runs inline (the fake machine is a closure of this runspace). Whatever needs the result waits for Complete-JoinJob (it refreshes the view).
    if ($script:JoinJob) { return }
    if ($script:TestMode) {
        try {
            $det = Invoke-Busy 'Reading how this master is joined (read only) ...' { Get-AVDTuneJoinState -Machine $script:Machine } -TaskTitle 'Reading the join state of this master' -Done 'Read'
            Set-JoinStateResult $det
        }
        catch { Add-StartProtocol 'Join state of this master read' $_.Exception.Message 'failed' }
        return
    }
    $task = Start-AVDTuneUiTask -Kind 'join-state' -Title 'Reading the join state of this master' -Step 'Win32_ComputerSystem, dsregcmd /status, DC locator (read only)' -Retry @{ Command = 'Read-JoinState'; Arguments = @() }
    $ps = [powershell]::Create()
    [void]$ps.AddScript({
            param($AppRoot)
            $ErrorActionPreference = 'Stop'
            Import-Module (Join-Path $AppRoot 'Modules\AVDTune.psm1') -Force
            Import-Module (Join-Path $AppRoot 'Modules\AVDTune.Directory.psm1') -Force
            Get-AVDTuneJoinState -Machine (New-AVDTuneMachine)
        }).AddArgument($script:AppRoot)
    $script:JoinJob = @{ PS = $ps; Handle = $ps.BeginInvoke(); Task = $task }
    Set-StageMessage 'Reading how this master is joined (read only) ...' 'info'
}
function Complete-JoinJob {
    $job = $script:JoinJob
    if (-not $job -or -not $job.Handle.IsCompleted) { return }
    $script:JoinJob = $null
    $det = $null; $err = ''
    try {
        $out = @($job.PS.EndInvoke($job.Handle))
        if ($job.PS.Streams.Error.Count -gt 0) { $err = $job.PS.Streams.Error[0].Exception.Message }
        $det = $out | Select-Object -Last 1
    }
    catch { $err = $_.Exception.Message }
    finally { $job.PS.Dispose() }
    if ($err -or -not $det) {
        Complete-AVDTuneUiTask $job.Task -Failed -Summary "The join state could not be read: $err"
        Add-StartProtocol 'Join state of this master read' $err 'failed'
    }
    else { Complete-AVDTuneUiTask $job.Task -Summary 'Read'; Set-JoinStateResult $det }
    Update-StartView
}
$script:JoinJob = $null
$script:Timer.Add_Tick({ try { Complete-JoinJob } catch { Show-Error $_.Exception.Message } })
function Invoke-SignOut {
    if ($script:StartContext.Session) { Disconnect-AVDTuneSession $script:StartContext.Session }
    $left = @(Get-AVDTuneSignInLeftovers -TempRoot (Get-StartTempRoot))
    Add-StartProtocol 'Tokens removed' ('Sign-in tokens removed from memory' + $(if ($left.Count -gt 0) { "; $($left.Count) profile folder(s) of the sign-in window could not be deleted yet" } else { '; profiles of the sign-in window deleted' })) $(if ($left.Count -gt 0) { 'failed' } else { 'ok' })
    Show-Toast (T 'stage.signin.signedout')
    Close-Stage
    Update-StartView
}

# ---------------------------------------------------------------- 2. domain controller
function Build-DomainForm {
    $ui.TxtStageTitle.Text = T 'stage.dom.title'
    $det = $script:StartContext.Detection
    $ui.TxtStageIntro.Text = "$(if ($det) { "$($det.Reason) " })$(T 'stage.dom.intro')"
    $f = $script:Form
    $e = Get-AVDTuneEnvironmentFile $script:StateRoot
    $dc = Get-AVDTuneProp $e 'Dc'
    $f.Server = New-Object System.Windows.Controls.TextBox; $f.Server.Width = 320; $f.Server.Text = [string](Get-AVDTuneProp $dc 'Server'); $f.Server.Name = 'TxtDcServer'
    # No server saved yet: the one the DC locator of Windows found (validated, read only) is suggested; it is only used when the administrator connects
    $suggested = ''
    if (-not $f.Server.Text -and $det -and $det.Dc) { $suggested = $(if ($det.Dc.Name) { $det.Dc.Name } else { $det.Dc.Address }); $f.Server.Text = $suggested }
    # A pending confirmation (LDAP 389, pin) belongs to the server it was shown for: a changed name drops it
    $f.Server.Add_TextChanged({ try { Clear-DomainPending } catch { } })
    $f.User = New-Object System.Windows.Controls.TextBox; $f.User.Width = 320; $f.User.Text = [string](Get-AVDTuneProp $dc 'User'); $f.User.Name = 'TxtDcUser'
    $f.SuggestedServer = $suggested
    $f.PasswordBox = New-Object System.Windows.Controls.PasswordBox; $f.PasswordBox.Width = 320; $f.PasswordBox.Name = 'PwdDc'; $f.PasswordBox.MaxLength = 256
    [void]$ui.PanelStageBody.Children.Add((New-FormRow (T 'stage.dom.server') $f.Server))
    if ($suggested) { $ui.PanelStageBody.Children.Add((New-Text "Suggested by the DC locator of Windows for the domain $($det.DomainName)$(if ($det.Dc.Site) { " (site $($det.Dc.Site))" }). Change it if another controller should be read." 'Hint' '250,0,0,4')) | Out-Null }
    [void]$ui.PanelStageBody.Children.Add((New-FormRow (T 'stage.dom.user') $f.User))
    [void]$ui.PanelStageBody.Children.Add((New-FormRow (T 'stage.dom.password') $f.PasswordBox))
    $ui.PanelStageBody.Children.Add((New-Text (T 'stage.dom.hint') 'Hint' '0,6,0,0')) | Out-Null
    $f.Summary = New-MonoBox '' 170; $f.Summary.Visibility = 'Collapsed'
    [void]$ui.PanelStageBody.Children.Add($f.Summary)
    if ($script:StartContext.Directory) { Show-DirectorySummary $script:StartContext.Directory $script:StartContext.DirectorySecurity }
    $ui.BtnStageAction.Content = T 'stage.dom.connect'
    $script:StageAction = { Invoke-DomainConnect }
}
function Show-DirectorySummary($Info, [string]$Security) {
    $f = $script:Form
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add((T 'stage.dom.sum.domain' $Info.DnsName $Info.NetBiosName))
    $lines.Add((T 'stage.dom.sum.dc' $Info.DcDnsName $Info.Site))
    $lines.Add((T 'stage.dom.sum.levels' $Info.DomainLevel $Info.ForestLevel))
    $lines.Add((T 'stage.dom.sum.connection' $Security))
    $lines.Add((T 'stage.dom.sum.naming' $Info.DefaultNamingContext))
    $lines.Add((T 'stage.dom.sum.ous' $Info.OuCount))
    $walk = { param($nodes, $depth) foreach ($n in $nodes) { if ($lines.Count -lt 40) { $lines.Add(('  ' * $depth) + '  ' + $n.Name) }; & $walk $n.Children ($depth + 1) } }
    & $walk $Info.OuTree 0
    $lines.Add((T 'stage.dom.sum.groups' (@($Info.Groups).Count)))
    foreach ($g in @($Info.Groups | Select-Object -First 12)) { $lines.Add("  $($g.Name)  $($g.Sid)") }
    if (@($Info.Warnings).Count -gt 0) { $lines.Add((T 'stage.dom.sum.notread') + (@($Info.Warnings) -join '; ')) }
    $f.Summary.Text = $lines -join "`r`n"; $f.Summary.Visibility = 'Visible'
}
function Format-Thumbprint([string]$Hex) { (($Hex -split '(?<=\G.{2})' | Where-Object { $_ }) -join ':') }
function Clear-DomainPending {
    $f = $script:Form
    if (-not $f.PendingServer -and -not $f.PendingCert) { return }
    $f.PendingServer = $null; $f.PendingCert = $null
    $script:StageAction2 = $null
    $ui.BtnStageAction2.Visibility = 'Collapsed'
}
function Invoke-DomainConnect {
    # -ConfirmedServer: the server whose LDAP 389 warning was accepted; it must still be the one in the form, otherwise nothing is confirmed
    param([string]$ConfirmedServer)
    $f = $script:Form
    if ($f.PasswordBox.SecurePassword.Length -eq 0) { Set-StageMessage (T 'stage.dom.nopassword') 'error'; return }
    $e = Get-AVDTuneEnvironmentFile $script:StateRoot
    $server = $f.Server.Text.Trim(); $user = $f.User.Text.Trim()
    $f.Secure = $f.PasswordBox.SecurePassword
    $ldap = Get-StartLdap
    $pins = Get-AVDTuneDcPins $e
    $r = Invoke-Busy (T 'stage.dom.busy' $server) { Connect-AVDTuneDirectory -Ldap $ldap -Server $server -User $user -Password $f.Secure -Pins $pins -ConfirmedServer $(if ($ConfirmedServer -and $ConfirmedServer -ieq $server) { $ConfirmedServer } else { '' }) } -TaskTitle (T 'stage.dom.task') -Done (T 'stage.dom.task.done')
    switch ($r.Status) {
        'NeedsConfirmation' {
            # LDAPS does not answer: no bind until the administrator accepts the named risk; the acceptance goes into the protocol
            Set-StageMessage ("$($r.Message)`n$($r.Warning)") 'warn'
            Add-StartProtocol "Domain controller without LDAPS ($server)" "LDAPS 636 does not answer ($($r.Reason)); nothing sent, waiting for the confirmation" 'skipped'
            $f.PendingServer = $server
            $ui.BtnStageAction2.Content = T 'stage.dom.accept'; $ui.BtnStageAction2.Visibility = 'Visible'
            $script:StageAction2 = {
                $srv = $script:Form.PendingServer
                if (-not $srv -or $srv -ine $script:Form.Server.Text.Trim()) { Clear-DomainPending; Set-StageMessage (T 'stage.dom.namechanged') 'error'; return }
                if (-not (Confirm-Action ((Get-AVDTuneLdapRiskText -Server $srv) + "`n`n" + (T 'stage.dom.confirm.ldap' $srv)) (T 'stage.dom.confirm.ldap.title'))) { return }
                Add-StartProtocol "Domain controller without LDAPS confirmed ($srv)" ("Confirmed by $env:USERDOMAIN\$env:USERNAME" + $(if ($script:StartContext.Session -and $script:StartContext.Session.Account) { " (signed in as $($script:StartContext.Session.Account))" }) + ': ' + $(if (Test-AVDTuneIpAddress $srv) { 'NTLM over 389, server not authenticated' } else { 'Kerberos over 389, no certificate pin' }))
                $ui.BtnStageAction2.Visibility = 'Collapsed'
                Invoke-DomainConnect -ConfirmedServer $srv
            }
        }
        'NeedsPin' {
            $c = $r.Certificate
            Set-StageMessage (T 'stage.dom.pin' $server $c.Subject $c.Issuer (([string]$c.NotBefore).Substring(0, [Math]::Min(10, ([string]$c.NotBefore).Length))) (([string]$c.NotAfter).Substring(0, [Math]::Min(10, ([string]$c.NotAfter).Length))) (Format-Thumbprint ([string]$c.Sha256)) (Format-Thumbprint ([string]$c.Thumbprint)) $(if ($c.PSObject.Properties['ChainStatus']) { $c.ChainStatus } else { T 'stage.dom.unknown' }) $(if ($c.PSObject.Properties['NameMatches']) { if ($c.NameMatches) { T 'stage.dom.name.match' $server } else { T 'stage.dom.name.nomatch' $server } } else { T 'stage.dom.unknown' })) 'warn'
            $f.PendingCert = $c; $f.PendingServer = $server
            $ui.BtnStageAction.Content = T 'stage.dom.connect'
            $ui.BtnStageAction2.Content = T 'stage.dom.pinbtn'; $ui.BtnStageAction2.Visibility = 'Visible'
            $script:StageAction2 = {
                [void](Set-AVDTuneDcPin -Root $script:StateRoot -Server $script:Form.PendingServer -Certificate $script:Form.PendingCert -User ([string]$env:USERNAME))
                Add-StartProtocol "Domain controller certificate pinned ($($script:Form.PendingServer))" "SHA-256 $((Format-Thumbprint ([string]$script:Form.PendingCert.Sha256)))"
                $ui.BtnStageAction2.Visibility = 'Collapsed'
                Invoke-DomainConnect
            }
        }
        'CertificateChanged' {
            Set-StageMessage $r.Message 'error'
            Add-StartProtocol "Domain controller certificate changed ($server)" 'Connection stopped, nothing was sent' 'failed'
            $f.PendingCert = $r.Certificate; $f.PendingServer = $server
            $ui.BtnStageAction2.Content = T 'stage.dom.repinbtn'; $ui.BtnStageAction2.Visibility = 'Visible'
            $script:StageAction2 = {
                if (-not (Confirm-Action (T 'stage.dom.confirm.repin' $script:Form.PendingServer (Format-Thumbprint ([string]$script:Form.PendingCert.Sha256))) (T 'stage.dom.confirm.repin.title'))) { return }
                [void](Set-AVDTuneDcPin -Root $script:StateRoot -Server $script:Form.PendingServer -Certificate $script:Form.PendingCert -User ([string]$env:USERNAME) -Replace)
                Add-StartProtocol "Domain controller certificate re-pinned ($($script:Form.PendingServer))" "new SHA-256 $((Format-Thumbprint ([string]$script:Form.PendingCert.Sha256)))"
                $ui.BtnStageAction2.Visibility = 'Collapsed'
                Invoke-DomainConnect
            }
        }
        'Failed' {
            Set-StageMessage $r.Message 'error'
            $script:StartContext.Failures['Domain'] = $r.Message
            Add-StartProtocol "Domain controller connection ($server)" $r.Message 'failed'
        }
        'Connected' {
            try {
                $info = Invoke-Busy (T 'stage.dom.reading') { Get-AVDTuneDirectoryInfo -Ldap $ldap -Connection $r.Connection } -TaskTitle (T 'stage.dom.reading.task') -Done (T 'stage.dom.reading.done')
            }
            catch {
                Disconnect-AVDTuneDirectory -Ldap $ldap -Connection $r.Connection
                $script:StartContext.Failures['Domain'] = $_.Exception.Message
                Add-StartProtocol "Domain controller read ($server)" $_.Exception.Message 'failed'
                Set-StageMessage $_.Exception.Message 'error'
                Update-StartView
                return
            }
            Disconnect-AVDTuneDirectory -Ldap $ldap -Connection $r.Connection
            Save-AVDTuneDcDiscovery -Root $script:StateRoot -Server $server -User $user -Info $info
            Save-AVDTuneDirectoryInfo -Root $script:StateRoot -Info $info
            $script:StartContext.Directory = $info; $script:StartContext.DirectorySecurity = $r.Security
            $script:StartContext.Failures.Remove('Domain')
            Add-StartProtocol "Domain controller read ($server)" "$($info.DnsName) ($($info.NetBiosName)), $($info.OuCount) OUs, $(@($info.Groups).Count) groups, site $($info.Site); $($r.Security)"
            $f.PasswordBox.Clear(); $f.Secure.Dispose(); $f.Secure = $null
            Show-DirectorySummary $info $r.Security
            Set-StageMessage (T 'stage.dom.read') 'ok'
            $ui.BtnStageAction.Visibility = 'Collapsed'
            Update-StartView
            return
        }
    }
    if ($f.Secure) { $f.Secure.Dispose() }
    $f.Secure = $null
}

# ---------------------------------------------------------------- 4. snapshot gate
function Build-SnapshotForm {
    $ui.TxtStageTitle.Text = T 'stage.snap.title'
    $ui.TxtStageIntro.Text = T 'stage.snap.intro'
    $f = $script:Form
    $f.Info = New-Object System.Windows.Controls.StackPanel
    [void]$ui.PanelStageBody.Children.Add($f.Info)
    $f.SnapList = New-Object System.Windows.Controls.ComboBox; $f.SnapList.Width = 620; $f.SnapList.Name = 'CmbSnapshot'
    [void]$ui.PanelStageBody.Children.Add((New-FormRow (T 'stage.snap.toconfirm') $f.SnapList))
    $f.SnapList.Visibility = 'Collapsed'
    $f.Phrase = New-Text (Get-AVDTuneGateText) $null '0,10,0,6'; $f.Phrase.FontWeight = 'SemiBold'
    [void]$ui.PanelStageBody.Children.Add($f.Phrase)
    $f.NameBox = New-Object System.Windows.Controls.TextBox; $f.NameBox.Width = 320; $f.NameBox.Name = 'TxtConfirmName'; $f.NameBox.MaxLength = 100
    [void]$ui.PanelStageBody.Children.Add((New-FormRow (T 'stage.snap.name') $f.NameBox (T 'stage.snap.name.aut')))
    $ui.PanelStageBody.Children.Add((New-Text (T 'stage.snap.hint') 'Hint' '0,4,0,0')) | Out-Null
    $ui.BtnStageAction.Content = T 'stage.snap.confirm'
    $ui.BtnStageAction2.Content = T 'stage.snap.create'; $ui.BtnStageAction2.Visibility = 'Visible'
    $script:StageAction = { Invoke-SnapshotConfirm }
    $script:StageAction2 = { Invoke-SnapshotCreate }
    Update-SnapshotForm
}
function Get-ArmToken { Get-AVDTuneAccessToken -Session $script:StartContext.Session -Audience Arm }
function Update-SnapshotForm {
    $f = $script:Form
    $f.Info.Children.Clear()
    $vm = Get-AVDTuneVmIdentity $script:Machine
    $f.Vm = $vm
    $state = Get-AVDTuneState $script:StateRoot
    $f.ImageVersion = [string]$state.ImageVersion
    if (-not $vm.Available) {
        $f.SnapList.Visibility = 'Collapsed'
        Set-StageMessage $vm.Problem 'error'
        $ui.BtnStageAction.IsEnabled = $false; $ui.BtnStageAction2.IsEnabled = $false
        return
    }
    $f.Window = Get-AVDTuneSnapshotWindow -Root $script:StateRoot
    $f.LastChange = $f.Window.LastChange
    $e = Get-AVDTuneEnvironment $script:StateRoot
    $f.NamePattern = [string](Get-AVDTuneEnvironmentAnswers $e).SnapshotNamePattern
    foreach ($row in @(@('stage.snap.row.vm', $vm.VmName), @('stage.snap.row.rg', $vm.ResourceGroup), @('stage.snap.row.disk', $vm.OsDiskName), @('stage.snap.row.version', $(if ($f.ImageVersion) { $f.ImageVersion } else { T 'stage.snap.val.noversion' })),
            @('stage.snap.row.last', $(if ($f.LastChange) { $f.LastChange.ToString('yyyy-MM-dd HH:mm') } else { T 'stage.snap.val.nolast' })),
            @('stage.snap.row.first', $(if ($f.Window.FirstChange) { T 'stage.snap.val.first' $f.Window.FirstChange.ToString('yyyy-MM-dd HH:mm') } else { T 'stage.snap.val.nofirst' })), @('stage.snap.row.pattern', $f.NamePattern))) {
        [void]$f.Info.Children.Add((New-InfoRow (T $row[0]) ([string]$row[1])))
    }
    try {
        $list = Invoke-Busy (T 'stage.snap.looking') { @(Get-AVDTuneOsDiskSnapshots -Arm (Get-StartArm) -Token (Get-ArmToken) -Vm $vm -Window $f.Window) } -TaskTitle (T 'stage.snap.looking.task') -Done (T 'stage.snap.looking.done')
    }
    catch {
        $script:StartContext.Failures['Snapshot'] = $_.Exception.Message
        Set-StageMessage $_.Exception.Message 'error'
        $ui.BtnStageAction.IsEnabled = $false
        $ui.BtnStageAction2.IsEnabled = $true
        return
    }
    $script:StartContext.Failures.Remove('Snapshot')
    $f.Snapshots = $list
    $valid = @($list | Where-Object Valid)
    $gate = Get-AVDTuneGateStatus -Vm $vm -Snapshots $list -Window $f.Window
    # Every snapshot of the OS disk is listed (name, time, status); one that does not count is grey, cannot be chosen and says why. The newest valid one is preselected.
    $items = New-Object System.Collections.ArrayList
    foreach ($s in $list) {
        $item = New-Object System.Windows.Controls.ComboBoxItem
        $when = if ($s.Created) { $s.Created.ToString('yyyy-MM-dd HH:mm') } else { T 'stage.snap.timeunknown' }
        $text = T 'stage.snap.item' $s.Name $when $s.State $(if ($s.ByAVDTune) { T 'stage.snap.byus' } else { T 'stage.snap.byother' })
        if ($s.Valid) { $text += $(if ($s.Kind -eq 'CurrentState') { T 'stage.snap.current' } else { T 'stage.snap.start' }) } else { $text += T 'stage.snap.nocount' $s.Reason }
        $tb = New-Text $text $null; $tb.MaxWidth = 700
        $item.Content = $tb; $item.Tag = $s; $item.IsEnabled = [bool]$s.Valid
        if (-not $s.Valid) { Set-Brush $tb ([System.Windows.Controls.TextBlock]::ForegroundProperty) 'MutedText'; $item.ToolTip = $s.Reason }
        [void]$items.Add($item)
    }
    $f.SnapList.ItemsSource = $items.ToArray()
    $firstValid = 0; while ($firstValid -lt $items.Count -and -not $items[$firstValid].IsEnabled) { $firstValid++ }
    if ($firstValid -lt $items.Count) { $f.SnapList.SelectedIndex = $firstValid }
    $f.SnapList.Visibility = ConvertTo-Vis ($items.Count -gt 0)
    $f.Valid = $valid
    $ui.BtnStageAction.IsEnabled = ($valid.Count -gt 0)
    $ui.BtnStageAction2.IsEnabled = $true
    $others = @($list | Where-Object { -not $_.Valid }).Count
    $kind = if ($valid.Count -gt 0) { 'ok' } else { 'warn' }
    Set-StageMessage ($gate.Detail + $(if ($others -gt 0) { ' ' + (T 'stage.snap.grey' $others) })) $kind
}
function Invoke-SnapshotCreate {
    $f = $script:Form
    if (-not $f.ImageVersion) {
        # the snapshot name and tags carry the image version: start the first one here (asks first)
        Start-NewVersion
        $f.ImageVersion = [string](Get-AVDTuneState $script:StateRoot).ImageVersion
        if (-not $f.ImageVersion) { Set-StageMessage (T 'stage.snap.needversion') 'error'; return }
        Update-SnapshotForm
    }
    if ($script:PendingSnapshot) { return }
    $vm = $f.Vm
    try {
        $started = Invoke-Busy (T 'stage.snap.asking') { Start-AVDTuneSnapshot -Arm (Get-StartArm) -Token (Get-ArmToken) -Vm $vm -ImageVersion $f.ImageVersion -User ([string]$script:StartContext.Session.Account) -At (& $script:Machine.Now) -NamePattern $f.NamePattern -ExistingNames @(@($f.Snapshots) | Where-Object { $_ } | ForEach-Object { $_.Name }) -ExistingSnapshots @(@($f.Snapshots) | Where-Object { $_ }) } -TaskTitle (T 'stage.snap.asking.task') -Done (T 'stage.snap.asking.done')
    }
    catch {
        $script:StartContext.Failures['Snapshot'] = $_.Exception.Message
        Add-StartProtocol 'Snapshot of the OS disk' $_.Exception.Message 'failed'
        Set-StageMessage $_.Exception.Message 'error'
        Update-StartView
        return
    }
    $script:PendingSnapshot = $started
    $script:SnapTask = Start-AVDTuneUiTask -Kind 'snapshot' -Title (T 'stage.snap.task' $started.Name) -Step (T 'stage.snap.task.step')   # runs until the timer below sees it ready or failed
    $ui.BtnStageAction2.IsEnabled = $false; $ui.BtnStageAction.IsEnabled = $false
    Set-StageMessage (T 'stage.snap.creating' $started.Name) 'info'
    $script:SnapTimer.Start()
}
$script:SnapTimer.Add_Tick({
        try {
            $p = $script:PendingSnapshot
            if (-not $p) { $script:SnapTimer.Stop(); return }
            $s = Get-AVDTuneSnapshotState -Arm (Get-StartArm) -Token (Get-ArmToken) -Id $p.Id
            if ($s.State -eq 'Succeeded') {
                $script:SnapTimer.Stop(); $script:PendingSnapshot = $null
                Add-StartProtocol 'Snapshot of the OS disk created' "$($p.Name) (incremental)"
                Complete-AVDTuneUiTask $script:SnapTask -Summary (T 'stage.snap.ready' $p.Name)
                if ($script:OpenStage -eq 'Snapshot') { Update-SnapshotForm }
                Show-Toast (T 'stage.snap.ready.toast' $p.Name)
            }
            elseif ($s.State -in 'Failed', 'Canceled') {
                $script:SnapTimer.Stop(); $script:PendingSnapshot = $null
                $script:StartContext.Failures['Snapshot'] = T 'stage.snap.failed' $p.Name
                Add-StartProtocol 'Snapshot of the OS disk' "$($p.Name) failed in Azure" 'failed'
                Complete-AVDTuneUiTask $script:SnapTask -Failed -Summary (T 'stage.snap.failed' $p.Name)
                Set-StageMessage $script:StartContext.Failures['Snapshot'] 'error'
                $ui.BtnStageAction2.IsEnabled = $true
                Update-StartView
            }
            elseif ($s.Percent -ne $null) { Set-StageMessage (T 'stage.snap.percent' $p.Name ([int]$s.Percent)) 'info'; Update-AVDTuneUiTask $script:SnapTask -Step (T 'stage.snap.task.percent' ([int]$s.Percent)) -Percent ([int]$s.Percent) }
        }
        catch {
            $script:SnapTimer.Stop(); $script:PendingSnapshot = $null
            Complete-AVDTuneUiTask $script:SnapTask -Failed -Summary $_.Exception.Message
            Set-StageMessage $_.Exception.Message 'error'
            $ui.BtnStageAction2.IsEnabled = $true
        }
    })
function Invoke-SnapshotConfirm {
    $f = $script:Form
    if (-not $f.Valid -or $f.Valid.Count -eq 0) { Set-StageMessage (T 'stage.snap.novalid') 'error'; return }
    $snapshot = if ($f.SnapList.SelectedItem -and $f.SnapList.SelectedItem.Tag) { $f.SnapList.SelectedItem.Tag } else { $null }
    if (-not $snapshot -or -not $snapshot.Valid) { Set-StageMessage (T 'stage.snap.choose') 'error'; return }
    $session = $script:StartContext.Session
    if (-not $f.ImageVersion) {
        # Confirming an existing snapshot before any image version (found on the test VM): check the name first,
        # then start the first image version (asks first), as "Create snapshot now" does
        $check = Test-AVDTuneConfirmationName -Typed $f.NameBox.Text
        if (-not $check.Ok) { Set-StageMessage $check.Message 'error'; return }
        Start-NewVersion
        $f.ImageVersion = [string](Get-AVDTuneState $script:StateRoot).ImageVersion
        if (-not $f.ImageVersion) { Set-StageMessage (T 'stage.snap.needversion2') 'error'; return }
    }
    try {
        $record = Confirm-AVDTuneSnapshotGate -Root $script:StateRoot -Snapshot $snapshot -TypedName $f.NameBox.Text -SignedInAccount $(if ($session) { [string]$session.Account } else { '' }) -WindowsAccount "$env:USERDOMAIN\$env:USERNAME" -ImageVersion $f.ImageVersion -Machine $script:Machine -Arm (Get-StartArm) -Token (Get-ArmToken) -Vm $f.Vm
    }
    catch { Set-StageMessage $_.Exception.Message 'error'; return }
    $made = if ($record.CreatedByAVDTune) { 'yes' } else { 'no' }
    Add-StartProtocol 'Snapshot gate confirmed' "$($record.SnapshotName), created $(([datetime]$record.SnapshotCreated).ToString('yyyy-MM-dd HH:mm')), by AVDTune: $made, confirmed by $($record.ConfirmedBy) (Microsoft account $($record.SignedInAccount), Windows account $($record.WindowsAccount)), ID $($record.SnapshotId); $($record.Mode) in version $($record.ImageVersion), snapshot kind $($record.SnapshotKind)$(if ($record.FirstChange) { ", first change of the version $(([datetime]$record.FirstChange).ToString('yyyy-MM-dd HH:mm'))" })"
    $script:StartContext.Failures.Remove('Snapshot')
    Show-Toast (T 'stage.snap.confirmed')
    Close-Stage
    Update-StartView
    if ($script:CurrentPage -eq 'Protocol') { Update-ProtocolView }
}
