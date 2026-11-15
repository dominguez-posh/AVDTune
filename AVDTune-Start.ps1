# The start sequence in the window (dot-sourced by Start-AVDTune.ps1 after the Overview and the protocol are set up).
# Four stages on the Overview, each with a status and a form that opens below the list: first-run questions, Microsoft sign-in,
# domain controller (only with a DC), snapshot gate. The logic is in Modules\AVDTune.Start/Session/Snapshot/Directory.psm1; this file only
# builds the forms, calls the engine and writes the protocol. External services come from $script:Services (real adapters, or the fakes
# of Tests\Fakes\FakeServices.ps1 in test mode). Secrets: the password stays in the PasswordBox / a SecureString and is cleared after use.

$script:StartContext = New-AVDTuneStartContext
$script:OpenStage = ''
$script:Form = @{}
$script:StageKinds = @{ Done = @('SuccessBg', 'Success', 'Done'); Pending = @('AccentSubtle', 'Primary', 'To do'); Locked = @('Hover', 'MutedText', 'Waiting'); Skipped = @('Hover', 'MutedText', 'Skipped'); Failed = @('ErrorBg', 'Danger', 'Failed') }
$script:StageButton = @{ Environment = @('Answer', 'Change'); SignIn = @('Sign in', 'Sign in again'); Domain = @('Connect', 'Show'); Snapshot = @('Open', 'Open') }
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
        $pt = New-Object System.Windows.Controls.TextBlock; $pt.Text = $kind[2]; $pt.FontSize = 12; $pt.FontWeight = 'SemiBold'
        Set-Brush $pt ([System.Windows.Controls.TextBlock]::ForegroundProperty) $kind[1]
        $pill.Child = $pt
        $title = New-Object System.Windows.Controls.TextBlock; $title.Text = "$number. $($stage.Title)"; $title.FontWeight = 'SemiBold'; $title.VerticalAlignment = 'Center'; $title.SetValue([System.Windows.Controls.Grid]::ColumnProperty, 1)
        $detail = New-Object System.Windows.Controls.TextBlock; $detail.Text = [string]$stage.Detail; $detail.TextWrapping = 'Wrap'; $detail.VerticalAlignment = 'Center'; $detail.SetValue([System.Windows.Controls.Grid]::ColumnProperty, 2)
        $detail.Margin = '0,0,12,0'
        Set-Brush $detail ([System.Windows.Controls.TextBlock]::ForegroundProperty) $(if ($stage.Status -eq 'Failed') { 'Danger' } else { 'MutedText' })
        [void]$grid.Children.Add($pill); [void]$grid.Children.Add($title); [void]$grid.Children.Add($detail)
        if ($stage.Status -ne 'Skipped') {
            $btn = New-Object System.Windows.Controls.Button
            $label = $script:StageButton[$stage.Id]
            $btn.Content = $(if ($stage.Status -eq 'Done') { $label[1] } else { $label[0] })
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
        $ui.TxtRollback.Text = "If a run goes wrong, go back to the snapshot $($gate.Value.SnapshotName): create a managed disk from it (Azure portal: the snapshot > Create disk; or az disk create --source), stop (deallocate) this VM, swap the OS disk (VM > Disks > Swap OS disk) and start it again. The rollback goes back to the state of the snapshot: the start of the version (everything done in this version since then is gone) or, for a snapshot of the current state, to that state, so note what was done in the protocol first."
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
        'Domain' { Build-DomainForm }
        'Snapshot' { Build-SnapshotForm }
    }
    $ui.BoxStage.BringIntoView()
}

# ---------------------------------------------------------------- 1. first-run questions
function Build-EnvironmentForm {
    $ui.TxtStageTitle.Text = '1. First-run questions: the planned AVD environment'
    $ui.TxtStageIntro.Text = 'The answers decide which steps and pages exist (for example no domain step with Microsoft Entra ID only). They are saved in environment.json without secrets and can be changed later; a change goes into the change log.'
    $existing = Get-AVDTuneEnvironment $script:StateRoot
    $answers = Get-AVDTuneEnvironmentAnswers $existing
    $f = $script:Form; $f.Combos = @{}; $f.Texts = @{}
    foreach ($q in (Get-AVDTuneQuestions)) {
        $cmb = New-Object System.Windows.Controls.ComboBox
        $cmb.Width = 430
        $cmb.ItemsSource = @($q.Choices | ForEach-Object { $_.Text })
        $current = @($q.Choices | Where-Object { $_.Value -eq $answers.($q.Key) })[0]
        $cmb.SelectedItem = $current.Text
        $cmb.Name = "Q$($q.Key)"
        $f.Combos[$q.Key] = @{ Control = $cmb; Question = $q }
        $cmb.Add_SelectionChanged({ try { Update-EnvironmentPreview } catch { } })
        [void]$ui.PanelStageBody.Children.Add((New-FormRow $q.Title $cmb))
    }
    $auth = New-Object System.Windows.Controls.ComboBox; $auth.Width = 430; $auth.Name = 'QAzureFilesAuth'
    $auth.Add_SelectionChanged({ try { Update-EnvironmentPreview } catch { } })
    $f.AuthCombo = $auth; $f.AuthWanted = [string]$answers.AzureFilesAuth
    [void]$ui.PanelStageBody.Children.Add((New-FormRow 'Azure Files authentication' $auth))
    # No tenant field: the tenant comes from the sign-in (issue #11). The client ID is optional: empty means AVDTune creates its own app registration.
    foreach ($t in @(@('VNet', 'Network: virtual network of the session hosts'), @('Subnet', 'Network: subnet of the session hosts'), @('ClientId', 'Client ID of the app registration (optional)'), @('SnapshotNamePattern', 'Snapshot name: {OsDisk} {VM} {ImageVersion} {DD} {MM} {YYYY}, {N} = number of the day'))) {
        $tb = New-Object System.Windows.Controls.TextBox; $tb.Width = 430; $tb.Text = [string]$answers.($t[0]); $tb.MaxLength = 255; $tb.Name = "T$($t[0])"
        $tb.Add_TextChanged({ try { Update-EnvironmentPreview } catch { } })
        $f.Texts[$t[0]] = $tb
        [void]$ui.PanelStageBody.Children.Add((New-FormRow $t[1] $tb))
    }
    $f.ForgetTenant = $null
    if ([string]$answers.TenantId) {
        # The saved tenant is shown, not edited; forgetting it is the only way to change it (the next sign-in sets it again, change log)
        $forget = New-Object System.Windows.Controls.CheckBox; $forget.Name = 'ChkForgetTenant'; $forget.VerticalAlignment = 'Center'
        $forget.Content = "Forget the saved tenant $($answers.TenantId) (the next sign-in sets it again)"
        $f.ForgetTenant = $forget
        [void]$ui.PanelStageBody.Children.Add((New-FormRow 'Tenant (from the sign-in)' $forget 'Forget the saved tenant'))
    }
    $f.Preview = New-Text '' 'Hint' '0,10,0,0'
    [void]$ui.PanelStageBody.Children.Add($f.Preview)
    $ui.BtnStageAction.Content = 'Save the answers'
    $script:StageAction = { Save-EnvironmentForm }
    Update-EnvironmentPreview
}
function Get-EnvironmentFormAnswers {
    $f = $script:Form
    $a = Get-AVDTuneEnvironmentDefaults
    foreach ($key in $f.Combos.Keys) {
        $q = $f.Combos[$key].Question
        $text = [string]$f.Combos[$key].Control.SelectedItem
        $a.$key = [string](@($q.Choices | Where-Object { $_.Text -eq $text })[0]).Value
    }
    foreach ($key in $f.Texts.Keys) { $a.$key = [string]$f.Texts[$key].Text }
    $choices = @(Get-AVDTuneAzureFilesAuthChoices $a)
    $sel = [string]$f.AuthCombo.SelectedItem
    $a.AzureFilesAuth = if ($sel -and $sel -notlike 'Automatic*' -and $sel -in $choices) { $sel } else { 'Auto' }
    $a
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
        $lines = @($plan.Notes) + @($check.Warnings | ForEach-Object { "Note: $_" }) + @($check.Errors | ForEach-Object { "Problem: $_" })
        if (-not ([string]$a.ClientId).Trim()) { $lines += "No client ID: at the sign-in AVDTune creates (or finds) its own app registration 'AVDTune' with admin consent; an administrator signs in for that once." }
        $lines += 'The tenant is not asked: it comes from the sign-in and is saved.'
        $f.Preview.Text = $lines -join "`n"
        Set-Brush $f.Preview ([System.Windows.Controls.TextBlock]::ForegroundProperty) $(if ($check.Errors.Count -gt 0) { 'Danger' } else { 'MutedText' })
        $ui.BtnStageAction.IsEnabled = ($check.Errors.Count -eq 0)
    }
    finally { $f.Updating = $false }
}
function Save-EnvironmentForm {
    $a = Get-EnvironmentFormAnswers
    $firstRun = -not (Get-AVDTuneEnvironment $script:StateRoot)
    $forget = [bool]($script:Form.ForgetTenant -and $script:Form.ForgetTenant.IsChecked)
    $result = Save-AVDTuneEnvironment -Root $script:StateRoot -Answers $a -User ([string]$env:USERNAME) -ForgetTenant:$forget
    if ($forget -and $script:StartContext.Session) { Disconnect-AVDTuneSession $script:StartContext.Session }   # a session of the old tenant does not stay
    $note = if ($result.Changes.Count -gt 0) { 'changed: ' + ($result.Changes -join '; ') } else { 'saved' }
    Add-StartProtocol 'First-run questions answered (identity model)' $note
    Show-Toast 'The answers are saved.'
    Close-Stage
    Update-StartView
    if ($script:CurrentPage -eq 'Protocol') { Update-ProtocolView }
    # First run: the small question about the desktop shortcut (installed copy only; otherwise the hint to install first)
    if ($firstRun -and -not (Show-ShortcutQuestion) -and (Get-AVDTuneShortcutOffer -Root $script:StateRoot -Mode (Get-ShortcutMode)) -eq 'Install') { Show-Toast 'The answers are saved. A desktop shortcut can be created once AVDTune is installed (Integrity and updates).' }
}

# ---------------------------------------------------------------- 2. sign-in
function Build-SignInForm {
    $ui.TxtStageTitle.Text = '2. Microsoft 365 and Azure sign-in'
    $ui.TxtStageIntro.Text = 'One normal Microsoft sign-in in an embedded window: you sign in yourself. AVDTune gets four tokens from it, one for Microsoft Graph, one for the SharePoint site, one for Azure Resource Manager and one for Azure Storage (the NTFS rows of the FSLogix check; optional, an older app registration without it signs in without that token and says so). Microsoft puts every consented permission of a resource into its token, so both Graph tokens carry all Graph permissions listed here; extra permissions are reported as a warning. The tokens live in memory only and are removed on closing, on sign out and by Finish.'
    $session = $script:StartContext.Session
    foreach ($key in (Get-AVDTuneAudience).Keys) {
        $a = (Get-AVDTuneAudience)[$key]
        [void]$ui.PanelStageBody.Children.Add((New-InfoRow $key ("$($a.Purpose): " + ($a.Scopes -join ', '))))
    }
    $e = Get-AVDTuneEnvironment $script:StateRoot
    $tenant = if ($e) { [string]$e.SignIn.TenantId } else { '' }
    $client = if ($e) { [string]$e.SignIn.ClientId } else { '' }
    [void]$ui.PanelStageBody.Children.Add((New-InfoRow 'Tenant' $(if ($tenant) { $tenant } else { 'Taken from the sign-in (tid of the token) and saved' })))
    [void]$ui.PanelStageBody.Children.Add((New-InfoRow 'App registration' $(if ($client) { $client } else { "None yet: AVDTune creates its own app registration 'AVDTune' first" })))
    $f = $script:Form
    $f.Account = New-Object System.Windows.Controls.TextBox; $f.Account.Width = 320; $f.Account.MaxLength = 254; $f.Account.Name = 'TxtSignInAccount'
    $f.Account.Text = if ($session -and $session.Account) { [string]$session.Account } else { '' }
    [void]$ui.PanelStageBody.Children.Add((New-FormRow 'Account (name@domain, optional)' $f.Account 'Account for the sign-in'))
    $hint = if (-not $client) {
        "First sign-in: you sign in with an administrator account through Microsoft's app 'Microsoft Graph Command Line Tools' (Application.ReadWrite.All, DelegatedPermissionGrant.ReadWrite.All). AVDTune creates its own app registration 'AVDTune' (or reuses the one it created and saved before, after checking it) (public client, http://localhost, no secret), grants the admin consent for the permissions above and then signs you in with it. Needs Application Administrator or Cloud Application Administrator, and Privileged Role Administrator (or Global Administrator) for the consent."
    }
    elseif (-not $tenant) { 'With the account AVDTune finds the tenant of its domain; without it the sign-in goes through organizations (only for a multi-tenant app registration). The tenant of the sign-in is saved.' }
    else { 'The app registration needs these permissions with admin consent, Azure Service Management and Azure Storage user_impersonation included: see docs\start-sequence.md.' }
    $ui.PanelStageBody.Children.Add((New-Text $hint 'Hint' '0,8,0,0')) | Out-Null
    if ($session -and $session.Connected) {
        $info = Get-AVDTuneSessionInfo $session
        Set-StageMessage ("Signed in as $($info.Account)" + $(if ($info.Name) { " ($($info.Name))" }) + '. Tokens: ' + (($info.Audiences | ForEach-Object { "$($_.Audience) until $(([datetime]$_.ExpiresOn).ToLocalTime().ToString('HH:mm'))" }) -join ', ') + '.') 'ok'
        $ui.BtnStageAction.Content = 'Sign in again'
        $ui.BtnStageAction2.Content = 'Sign out (remove the tokens)'; $ui.BtnStageAction2.Visibility = 'Visible'
        $script:StageAction2 = { Invoke-SignOut }
    }
    else {
        $ui.BtnStageAction.Content = 'Sign in'
        $f = $script:StartContext.Failures['SignIn']; if ($f) { Set-StageMessage ([string]$f) 'error' }
        if ($client) {
            # Another administrator: runs the setup with his account (assignment + his own consent); also checks the saved registration
            $ui.BtnStageAction2.Content = 'Set up again (authorize this administrator)'; $ui.BtnStageAction2.Visibility = 'Visible'
            $script:StageAction2 = { Invoke-SignIn -Setup }
        }
    }
    $script:StageAction = { Invoke-SignIn }
}
function Invoke-SignIn([switch]$Setup) {
    $e = Get-AVDTuneEnvironment $script:StateRoot
    if (-not $e) { throw 'Answer the first-run questions first.' }
    $account = if ($script:Form.Account) { ([string]$script:Form.Account.Text).Trim() } else { '' }
    if ($account -and -not (Get-AVDTuneAccountDomain $account)) { Set-StageMessage 'The account must look like name@domain (or leave it empty).' 'error'; return }
    $setup = $Setup -or -not [string]$e.SignIn.ClientId
    if ($setup -and -not (Confirm-Action "An administrator signs in with Microsoft's app 'Microsoft Graph Command Line Tools' and the permissions Application.ReadWrite.All and DelegatedPermissionGrant.ReadWrite.All. The setup adds the permissions of AVDTune's registration, among them Azure Service Management user_impersonation and Azure Storage user_impersonation (NTFS rows of the FSLogix check), and creates the service principals of Microsoft's apps Azure Service Management and Azure Storage in your tenant when they are missing. AVDTune uses the setup permissions only to $(if ($e.SignIn.ClientId) { "check its saved app registration $($e.SignIn.ClientId) (a new one replaces it when it is not safe)" } else { "create its own app registration 'AVDTune'" }), to assign your account to it and to grant the consent for your account only.`n`n$(Get-AVDTuneSetupConsentNote)`n`nContinue?" 'Set up the AVDTune app registration')) { return }
    $session = New-AVDTuneSession -Auth (Get-StartAuth) -TempRoot (Get-StartTempRoot)
    try {
        $result = Invoke-Busy $(if ($setup) { 'The setup sign-in window is open: sign in with an administrator account ...' } else { 'The sign-in window is open: sign in with the account that manages this master ...' }) {
            Invoke-AVDTuneStartSignIn -Root $script:StateRoot -Session $session -Account $account -User ([string]$env:USERNAME) -RetryDelaySeconds $(if ($script:TestMode) { 0 } else { 5 }) -Setup:$setup } -TaskTitle 'Signing in to Microsoft 365 and Azure' -Done 'Signed in'
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
    Show-Toast "Signed in as $($info.Account)."
    Close-Stage
    Update-StartView
    Start-ReadyJob 'Start' ''   # the Azure checks of the readiness analysis can read now
}
function Invoke-SignOut {
    if ($script:StartContext.Session) { Disconnect-AVDTuneSession $script:StartContext.Session }
    $left = @(Get-AVDTuneSignInLeftovers -TempRoot (Get-StartTempRoot))
    Add-StartProtocol 'Tokens removed' ('Sign-in tokens removed from memory' + $(if ($left.Count -gt 0) { "; $($left.Count) profile folder(s) of the sign-in window could not be deleted yet" } else { '; profiles of the sign-in window deleted' })) $(if ($left.Count -gt 0) { 'failed' } else { 'ok' })
    Show-Toast 'The tokens are removed from memory.'
    Close-Stage
    Update-StartView
}

# ---------------------------------------------------------------- 3. domain controller
function Build-DomainForm {
    $ui.TxtStageTitle.Text = '3. Domain controller'
    $ui.TxtStageIntro.Text = 'This master is not domain joined, so enter a domain controller and a domain account. AVDTune connects over LDAPS (certificate pinned) and reads the domain, OUs, groups with their SIDs and the site. The password is only kept in memory while you work here.'
    $f = $script:Form
    $e = Get-AVDTuneEnvironment $script:StateRoot
    $dc = Get-AVDTuneProp $e 'Dc'
    $f.Server = New-Object System.Windows.Controls.TextBox; $f.Server.Width = 320; $f.Server.Text = [string](Get-AVDTuneProp $dc 'Server'); $f.Server.Name = 'TxtDcServer'
    # A pending confirmation (LDAP 389, pin) belongs to the server it was shown for: a changed name drops it
    $f.Server.Add_TextChanged({ try { Clear-DomainPending } catch { } })
    $f.User = New-Object System.Windows.Controls.TextBox; $f.User.Width = 320; $f.User.Text = [string](Get-AVDTuneProp $dc 'User'); $f.User.Name = 'TxtDcUser'
    $f.PasswordBox = New-Object System.Windows.Controls.PasswordBox; $f.PasswordBox.Width = 320; $f.PasswordBox.Name = 'PwdDc'; $f.PasswordBox.MaxLength = 256
    [void]$ui.PanelStageBody.Children.Add((New-FormRow 'Domain controller (IP or name)' $f.Server))
    [void]$ui.PanelStageBody.Children.Add((New-FormRow 'Domain account (DOMAIN\user or UPN)' $f.User))
    [void]$ui.PanelStageBody.Children.Add((New-FormRow 'Password' $f.PasswordBox))
    $ui.PanelStageBody.Children.Add((New-Text 'The account needs the right to read the directory and, in phase 3, to create groups in an OU. A simple bind in clear text is never used.' 'Hint' '0,6,0,0')) | Out-Null
    $f.Summary = New-MonoBox '' 170; $f.Summary.Visibility = 'Collapsed'
    [void]$ui.PanelStageBody.Children.Add($f.Summary)
    if ($script:StartContext.Directory) { Show-DirectorySummary $script:StartContext.Directory $script:StartContext.DirectorySecurity }
    $ui.BtnStageAction.Content = 'Connect and read'
    $script:StageAction = { Invoke-DomainConnect }
}
function Show-DirectorySummary($Info, [string]$Security) {
    $f = $script:Form
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("Domain:        $($Info.DnsName)  (NetBIOS $($Info.NetBiosName))")
    $lines.Add("Domain controller: $($Info.DcDnsName)  site $($Info.Site)")
    $lines.Add("Levels:        domain $($Info.DomainLevel), forest $($Info.ForestLevel)")
    $lines.Add("Connection:    $Security")
    $lines.Add("Naming context: $($Info.DefaultNamingContext)")
    $lines.Add("OUs ($($Info.OuCount)):")
    $walk = { param($nodes, $depth) foreach ($n in $nodes) { if ($lines.Count -lt 40) { $lines.Add(('  ' * $depth) + '  ' + $n.Name) }; & $walk $n.Children ($depth + 1) } }
    & $walk $Info.OuTree 0
    $lines.Add("Groups ($(@($Info.Groups).Count)):")
    foreach ($g in @($Info.Groups | Select-Object -First 12)) { $lines.Add("  $($g.Name)  $($g.Sid)") }
    if (@($Info.Warnings).Count -gt 0) { $lines.Add('Not read: ' + (@($Info.Warnings) -join '; ')) }
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
    if ($f.PasswordBox.SecurePassword.Length -eq 0) { Set-StageMessage 'Enter the password of the domain account.' 'error'; return }
    $e = Get-AVDTuneEnvironment $script:StateRoot
    $server = $f.Server.Text.Trim(); $user = $f.User.Text.Trim()
    $f.Secure = $f.PasswordBox.SecurePassword
    $ldap = Get-StartLdap
    $pins = Get-AVDTuneDcPins $e
    $r = Invoke-Busy "Connecting to $server ..." { Connect-AVDTuneDirectory -Ldap $ldap -Server $server -User $user -Password $f.Secure -Pins $pins -ConfirmedServer $(if ($ConfirmedServer -and $ConfirmedServer -ieq $server) { $ConfirmedServer } else { '' }) } -TaskTitle 'Connecting to the domain controller' -Done 'Connected'
    switch ($r.Status) {
        'NeedsConfirmation' {
            # LDAPS does not answer: no bind until the administrator accepts the named risk; the acceptance goes into the protocol
            Set-StageMessage ("$($r.Message)`n$($r.Warning)") 'warn'
            Add-StartProtocol "Domain controller without LDAPS ($server)" "LDAPS 636 does not answer ($($r.Reason)); nothing sent, waiting for the confirmation" 'skipped'
            $f.PendingServer = $server
            $ui.BtnStageAction2.Content = 'I accept the risk: connect over LDAP 389'; $ui.BtnStageAction2.Visibility = 'Visible'
            $script:StageAction2 = {
                $srv = $script:Form.PendingServer
                if (-not $srv -or $srv -ine $script:Form.Server.Text.Trim()) { Clear-DomainPending; Set-StageMessage 'The server name changed after the warning. Connect again to see the warning for this server.' 'error'; return }
                if (-not (Confirm-Action ((Get-AVDTuneLdapRiskText -Server $srv) + "`n`nConnect to $srv over LDAP 389 anyway?") 'Connect without LDAPS')) { return }
                Add-StartProtocol "Domain controller without LDAPS confirmed ($srv)" ("Confirmed by $env:USERDOMAIN\$env:USERNAME" + $(if ($script:StartContext.Session -and $script:StartContext.Session.Account) { " (signed in as $($script:StartContext.Session.Account))" }) + ': ' + $(if (Test-AVDTuneIpAddress $srv) { 'NTLM over 389, server not authenticated' } else { 'Kerberos over 389, no certificate pin' }))
                $ui.BtnStageAction2.Visibility = 'Collapsed'
                Invoke-DomainConnect -ConfirmedServer $srv
            }
        }
        'NeedsPin' {
            $c = $r.Certificate
            Set-StageMessage ("First contact with $server over LDAPS. Nothing was sent yet. Check that this is your domain controller's certificate:`nSubject: $($c.Subject)`nIssuer: $($c.Issuer)`nValid: $(([string]$c.NotBefore).Substring(0, [Math]::Min(10, ([string]$c.NotBefore).Length))) to $(([string]$c.NotAfter).Substring(0, [Math]::Min(10, ([string]$c.NotAfter).Length)))`nSHA-256: $(Format-Thumbprint ([string]$c.Sha256))`nSHA-1 thumbprint: $(Format-Thumbprint ([string]$c.Thumbprint))`nChain (extra information, the pin is the trust): $(if ($c.PSObject.Properties['ChainStatus']) { $c.ChainStatus } else { 'unknown' })`nName: $(if ($c.PSObject.Properties['NameMatches']) { if ($c.NameMatches) { "matches $server" } else { "does not match $server" } } else { 'unknown' })") 'warn'
            $f.PendingCert = $c; $f.PendingServer = $server
            $ui.BtnStageAction.Content = 'Connect and read'
            $ui.BtnStageAction2.Content = 'Pin this certificate and continue'; $ui.BtnStageAction2.Visibility = 'Visible'
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
            $ui.BtnStageAction2.Content = 'The change is expected: pin the new certificate'; $ui.BtnStageAction2.Visibility = 'Visible'
            $script:StageAction2 = {
                if (-not (Confirm-Action "Replace the pinned certificate of $($script:Form.PendingServer) by the one with SHA-256 $((Format-Thumbprint ([string]$script:Form.PendingCert.Sha256)))? Only do this if the certificate of the domain controller was renewed on purpose." 'Replace the pinned certificate')) { return }
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
                $info = Invoke-Busy 'Reading the domain, OUs and groups ...' { Get-AVDTuneDirectoryInfo -Ldap $ldap -Connection $r.Connection } -TaskTitle 'Reading the domain, OUs and groups' -Done 'Read'
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
            Set-StageMessage 'The domain is read. The password is cleared.' 'ok'
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
    $ui.TxtStageTitle.Text = '4. Snapshot gate'
    $ui.TxtStageIntro.Text = 'One snapshot per image version: before AVDTune changes the master there must be a finished snapshot of its OS disk from after the last change of the previous version and before the first change of this one. A snapshot made after the last change (the current state) counts too, so Create snapshot now is always usable; a rollback goes back to the start of the version or to that current state. Create one here (incremental, named by the pattern of this environment) or choose an existing one, then confirm it with your first and last name. When AVDTune already changed the master in this version, choose a snapshot from the start of the version or one made after the last change; snapshots that do not count are grey with the reason. Until then every page is read only.'
    $f = $script:Form
    $f.Info = New-Object System.Windows.Controls.StackPanel
    [void]$ui.PanelStageBody.Children.Add($f.Info)
    $f.SnapList = New-Object System.Windows.Controls.ComboBox; $f.SnapList.Width = 620; $f.SnapList.Name = 'CmbSnapshot'
    [void]$ui.PanelStageBody.Children.Add((New-FormRow 'Snapshot to confirm' $f.SnapList))
    $f.SnapList.Visibility = 'Collapsed'
    $f.Phrase = New-Text (Get-AVDTuneGateText) $null '0,10,0,6'; $f.Phrase.FontWeight = 'SemiBold'
    [void]$ui.PanelStageBody.Children.Add($f.Phrase)
    $f.NameBox = New-Object System.Windows.Controls.TextBox; $f.NameBox.Width = 320; $f.NameBox.Name = 'TxtConfirmName'; $f.NameBox.MaxLength = 100
    [void]$ui.PanelStageBody.Children.Add((New-FormRow 'Your first and last name' $f.NameBox 'Your first and last name to confirm the snapshot'))
    $ui.PanelStageBody.Children.Add((New-Text 'Shared admin accounts are fine: the protocol and the change log record the typed name together with the signed-in Microsoft account and the Windows account.' 'Hint' '0,4,0,0')) | Out-Null
    $ui.BtnStageAction.Content = 'Confirm'
    $ui.BtnStageAction2.Content = 'Create snapshot now'; $ui.BtnStageAction2.Visibility = 'Visible'
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
    foreach ($row in @(@('VM', $vm.VmName), @('Resource group', $vm.ResourceGroup), @('OS disk', $vm.OsDiskName), @('Image version', $(if ($f.ImageVersion) { $f.ImageVersion } else { 'none yet: Create snapshot starts the first one' })),
            @('Last change by AVDTune', $(if ($f.LastChange) { $f.LastChange.ToString('yyyy-MM-dd HH:mm') } else { 'none yet: every finished snapshot counts' })),
            @('First change in this version', $(if ($f.Window.FirstChange) { "$($f.Window.FirstChange.ToString('yyyy-MM-dd HH:mm')): choose a snapshot from the start of the version (before it) or one made after the last change (the current state)" } else { 'none yet: this is the start of the version' })), @('Name pattern', $f.NamePattern))) {
        [void]$f.Info.Children.Add((New-InfoRow $row[0] ([string]$row[1])))
    }
    try {
        $list = Invoke-Busy 'Looking for snapshots of the OS disk ...' { @(Get-AVDTuneOsDiskSnapshots -Arm (Get-StartArm) -Token (Get-ArmToken) -Vm $vm -Window $f.Window) } -TaskTitle 'Looking for snapshots of the OS disk' -Done 'Looked'
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
        $when = if ($s.Created) { $s.Created.ToString('yyyy-MM-dd HH:mm') } else { 'time unknown' }
        $text = "$($s.Name)  ($when, $($s.State), $(if ($s.ByAVDTune) { 'made by AVDTune' } else { 'made by someone else' }))"
        if ($s.Valid) { $text += $(if ($s.Kind -eq 'CurrentState') { ' - current state (after the last change)' } else { ' - start of the version' }) } else { $text += " - does not count: $($s.Reason)" }
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
    Set-StageMessage ($gate.Detail + $(if ($others -gt 0) { " ($others snapshot(s) of this disk are grey: they do not count, the reason is shown.)" })) $kind
}
function Invoke-SnapshotCreate {
    $f = $script:Form
    if (-not $f.ImageVersion) {
        # the snapshot name and tags carry the image version: start the first one here (asks first)
        Start-NewVersion
        $f.ImageVersion = [string](Get-AVDTuneState $script:StateRoot).ImageVersion
        if (-not $f.ImageVersion) { Set-StageMessage 'The snapshot needs an image version: start a new version first.' 'error'; return }
        Update-SnapshotForm
    }
    if ($script:PendingSnapshot) { return }
    $vm = $f.Vm
    try {
        $started = Invoke-Busy 'Asking Azure to create the incremental snapshot ...' { Start-AVDTuneSnapshot -Arm (Get-StartArm) -Token (Get-ArmToken) -Vm $vm -ImageVersion $f.ImageVersion -User ([string]$script:StartContext.Session.Account) -At (& $script:Machine.Now) -NamePattern $f.NamePattern -ExistingNames @(@($f.Snapshots) | Where-Object { $_ } | ForEach-Object { $_.Name }) } -TaskTitle 'Asking Azure to create the snapshot' -Done 'Request accepted'
    }
    catch {
        $script:StartContext.Failures['Snapshot'] = $_.Exception.Message
        Add-StartProtocol 'Snapshot of the OS disk' $_.Exception.Message 'failed'
        Set-StageMessage $_.Exception.Message 'error'
        Update-StartView
        return
    }
    $script:PendingSnapshot = $started
    $script:SnapTask = Start-AVDTuneUiTask -Kind 'snapshot' -Title "Snapshot $($started.Name)" -Step 'Being created in Azure'   # runs until the timer below sees it ready or failed
    $ui.BtnStageAction2.IsEnabled = $false; $ui.BtnStageAction.IsEnabled = $false
    Set-StageMessage "Snapshot $($started.Name) is being created in Azure. This can take a few minutes; the window stays usable." 'info'
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
                Complete-AVDTuneUiTask $script:SnapTask -Summary "Snapshot $($p.Name) is ready"
                if ($script:OpenStage -eq 'Snapshot') { Update-SnapshotForm }
                Show-Toast "Snapshot $($p.Name) is ready."
            }
            elseif ($s.State -in 'Failed', 'Canceled') {
                $script:SnapTimer.Stop(); $script:PendingSnapshot = $null
                $script:StartContext.Failures['Snapshot'] = "The snapshot $($p.Name) failed in Azure."
                Add-StartProtocol 'Snapshot of the OS disk' "$($p.Name) failed in Azure" 'failed'
                Complete-AVDTuneUiTask $script:SnapTask -Failed -Summary "The snapshot $($p.Name) failed in Azure."
                Set-StageMessage $script:StartContext.Failures['Snapshot'] 'error'
                $ui.BtnStageAction2.IsEnabled = $true
                Update-StartView
            }
            elseif ($s.Percent -ne $null) { Set-StageMessage "Snapshot $($p.Name): $([int]$s.Percent) percent ..." 'info'; Update-AVDTuneUiTask $script:SnapTask -Step "Being created in Azure: $([int]$s.Percent) percent" -Percent ([int]$s.Percent) }
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
    if (-not $f.Valid -or $f.Valid.Count -eq 0) { Set-StageMessage 'There is no valid snapshot to confirm (after the last change of the previous version and before the first change of this one).' 'error'; return }
    $snapshot = if ($f.SnapList.SelectedItem -and $f.SnapList.SelectedItem.Tag) { $f.SnapList.SelectedItem.Tag } else { $null }
    if (-not $snapshot -or -not $snapshot.Valid) { Set-StageMessage 'Choose one of the snapshots that count (the grey ones cannot be confirmed).' 'error'; return }
    $session = $script:StartContext.Session
    if (-not $f.ImageVersion) {
        # Confirming an existing snapshot before any image version (found on the test VM): check the name first,
        # then start the first image version (asks first), as "Create snapshot now" does
        $check = Test-AVDTuneConfirmationName -Typed $f.NameBox.Text
        if (-not $check.Ok) { Set-StageMessage $check.Message 'error'; return }
        Start-NewVersion
        $f.ImageVersion = [string](Get-AVDTuneState $script:StateRoot).ImageVersion
        if (-not $f.ImageVersion) { Set-StageMessage 'The confirmation is recorded in an image version: start a new version first.' 'error'; return }
    }
    try {
        $record = Confirm-AVDTuneSnapshotGate -Root $script:StateRoot -Snapshot $snapshot -TypedName $f.NameBox.Text -SignedInAccount $(if ($session) { [string]$session.Account } else { '' }) -WindowsAccount "$env:USERDOMAIN\$env:USERNAME" -ImageVersion $f.ImageVersion -Machine $script:Machine
    }
    catch { Set-StageMessage $_.Exception.Message 'error'; return }
    $made = if ($record.CreatedByAVDTune) { 'yes' } else { 'no' }
    Add-StartProtocol 'Snapshot gate confirmed' "$($record.SnapshotName), created $(([datetime]$record.SnapshotCreated).ToString('yyyy-MM-dd HH:mm')), by AVDTune: $made, confirmed by $($record.ConfirmedBy) (Microsoft account $($record.SignedInAccount), Windows account $($record.WindowsAccount)), ID $($record.SnapshotId)"
    $script:StartContext.Failures.Remove('Snapshot')
    Show-Toast 'Snapshot confirmed. The pages can change the master now.'
    Close-Stage
    Update-StartView
    if ($script:CurrentPage -eq 'Protocol') { Update-ProtocolView }
}
