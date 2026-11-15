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
$script:SnapTimer.Interval = [TimeSpan]::FromMilliseconds($(if ($env:AVDTUNE_SMOKE) { 300 } else { 4000 }))
$script:PendingSnapshot = $null

# ---------------------------------------------------------------- services
function Get-StartAuth {
    if ($script:TestMode) { return $script:Services.Auth }
    New-AVDTuneAuthAdapter -Owner $window -CacheFolder (Join-Path $script:StateRoot 'WebView2') -TrustFile (Get-AVDTuneWebView2TrustFile $script:StateRoot) -Log {
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
function Invoke-Busy([string]$Text, [scriptblock]$Block) {
    # A call to a service from the window thread: the message shows first, the wait cursor while it runs (every call has its own timeout)
    Set-StageMessage $Text 'info'
    $window.Cursor = [System.Windows.Input.Cursors]::Wait
    try {
        $window.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Render)
        & $Block
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
        $ui.TxtRollback.Text = "If a run goes wrong, go back to the snapshot $($gate.Value.SnapshotName): create a managed disk from it (Azure portal: the snapshot > Create disk; or az disk create --source), stop (deallocate) this VM, swap the OS disk (VM > Disks > Swap OS disk) and start it again. Everything after the snapshot is gone, so note what was done in the protocol first."
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
    foreach ($t in @(@('VNet', 'Network: virtual network of the session hosts'), @('Subnet', 'Network: subnet of the session hosts'), @('TenantId', 'Tenant (domain or ID)'), @('ClientId', 'Client ID of the app registration'))) {
        $tb = New-Object System.Windows.Controls.TextBox; $tb.Width = 430; $tb.Text = [string]$answers.($t[0]); $tb.MaxLength = 255; $tb.Name = "T$($t[0])"
        $tb.Add_TextChanged({ try { Update-EnvironmentPreview } catch { } })
        $f.Texts[$t[0]] = $tb
        [void]$ui.PanelStageBody.Children.Add((New-FormRow $t[1] $tb))
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
        $f.Preview.Text = $lines -join "`n"
        Set-Brush $f.Preview ([System.Windows.Controls.TextBlock]::ForegroundProperty) $(if ($check.Errors.Count -gt 0) { 'Danger' } else { 'MutedText' })
        $ui.BtnStageAction.IsEnabled = ($check.Errors.Count -eq 0)
    }
    finally { $f.Updating = $false }
}
function Save-EnvironmentForm {
    $a = Get-EnvironmentFormAnswers
    $result = Save-AVDTuneEnvironment -Root $script:StateRoot -Answers $a -User ([string]$env:USERNAME)
    $note = if ($result.Changes.Count -gt 0) { 'changed: ' + ($result.Changes -join '; ') } else { 'saved' }
    Add-StartProtocol 'First-run questions answered (identity model)' $note
    Show-Toast 'The answers are saved.'
    Close-Stage
    Update-StartView
    if ($script:CurrentPage -eq 'Protocol') { Update-ProtocolView }
}

# ---------------------------------------------------------------- 2. sign-in
function Build-SignInForm {
    $ui.TxtStageTitle.Text = '2. Microsoft 365 and Azure sign-in'
    $ui.TxtStageIntro.Text = 'One normal Microsoft sign-in in an embedded window: you sign in yourself. AVDTune gets three tokens from it, one for Microsoft Graph, one for the SharePoint site and one for Azure Resource Manager. Microsoft puts every consented permission of a resource into its token, so both Graph tokens carry all Graph permissions listed here; extra permissions are reported as a warning. The tokens live in memory only and are removed on closing, on sign out and before seal.'
    $session = $script:StartContext.Session
    foreach ($key in (Get-AVDTuneAudience).Keys) {
        $a = (Get-AVDTuneAudience)[$key]
        [void]$ui.PanelStageBody.Children.Add((New-InfoRow $key ("$($a.Purpose): " + ($a.Scopes -join ', '))))
    }
    $e = Get-AVDTuneEnvironment $script:StateRoot
    [void]$ui.PanelStageBody.Children.Add((New-InfoRow 'Tenant' $(if ($e) { [string]$e.SignIn.TenantId } else { '' })))
    [void]$ui.PanelStageBody.Children.Add((New-InfoRow 'App registration' $(if ($e) { [string]$e.SignIn.ClientId } else { '' })))
    $ui.PanelStageBody.Children.Add((New-Text 'The app registration needs these permissions with admin consent, Azure Service Management user_impersonation included: see docs\start-sequence.md.' 'Hint' '0,8,0,0')) | Out-Null
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
    }
    $script:StageAction = { Invoke-SignIn }
}
function Invoke-SignIn {
    $e = Get-AVDTuneEnvironment $script:StateRoot
    if (-not $e) { throw 'Answer the first-run questions first.' }
    $session = New-AVDTuneSession -Auth (Get-StartAuth) -TempRoot (Get-StartTempRoot)
    try {
        $info = Invoke-Busy 'The sign-in window is open: sign in with the account that manages this master ...' { Connect-AVDTuneSession -Session $session -TenantId ([string]$e.SignIn.TenantId) -ClientId ([string]$e.SignIn.ClientId) }
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
    foreach ($w in @($info.Warnings)) { Add-StartProtocol 'Warning: sign-in token with extra permissions' $w }
    Show-Toast "Signed in as $($info.Account)."
    Close-Stage
    Update-StartView
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
function Invoke-DomainConnect {
    $f = $script:Form
    if ($f.PasswordBox.SecurePassword.Length -eq 0) { Set-StageMessage 'Enter the password of the domain account.' 'error'; return }
    $e = Get-AVDTuneEnvironment $script:StateRoot
    $server = $f.Server.Text.Trim(); $user = $f.User.Text.Trim()
    $f.Secure = $f.PasswordBox.SecurePassword
    $ldap = Get-StartLdap
    $pins = Get-AVDTuneDcPins $e
    $r = Invoke-Busy "Connecting to $server ..." { Connect-AVDTuneDirectory -Ldap $ldap -Server $server -User $user -Password $f.Secure -Pins $pins }
    switch ($r.Status) {
        'NeedsPin' {
            $c = $r.Certificate
            Set-StageMessage ("First contact with $server over LDAPS. Nothing was sent yet. Check that this is your domain controller's certificate:`nSubject: $($c.Subject)`nIssuer: $($c.Issuer)`nValid: $(([string]$c.NotBefore).Substring(0, [Math]::Min(10, ([string]$c.NotBefore).Length))) to $(([string]$c.NotAfter).Substring(0, [Math]::Min(10, ([string]$c.NotAfter).Length)))`nSHA-256: $(Format-Thumbprint ([string]$c.Sha256))`nSHA-1 thumbprint: $(Format-Thumbprint ([string]$c.Thumbprint))") 'warn'
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
                $info = Invoke-Busy 'Reading the domain, OUs and groups ...' { Get-AVDTuneDirectoryInfo -Ldap $ldap -Connection $r.Connection }
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
    $ui.TxtStageIntro.Text = 'Before AVDTune changes the master there must be a snapshot of its OS disk from today, so a rollback is possible. Create one here (incremental) or use an existing one, then confirm it with your full name. Until then every page is read only.'
    $f = $script:Form
    $f.Info = New-Object System.Windows.Controls.StackPanel
    [void]$ui.PanelStageBody.Children.Add($f.Info)
    $f.SnapList = New-Object System.Windows.Controls.ComboBox; $f.SnapList.Width = 520; $f.SnapList.Name = 'CmbSnapshot'
    [void]$ui.PanelStageBody.Children.Add((New-FormRow 'Snapshot of today to confirm' $f.SnapList))
    $f.SnapList.Visibility = 'Collapsed'
    $f.Phrase = New-Text (Get-AVDTuneGateText) $null '0,10,0,6'; $f.Phrase.FontWeight = 'SemiBold'
    [void]$ui.PanelStageBody.Children.Add($f.Phrase)
    $f.NameBox = New-Object System.Windows.Controls.TextBox; $f.NameBox.Width = 320; $f.NameBox.Name = 'TxtConfirmName'; $f.NameBox.MaxLength = 100
    [void]$ui.PanelStageBody.Children.Add((New-FormRow 'Your full name' $f.NameBox 'Your full name to confirm the snapshot'))
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
    foreach ($row in @(@('VM', $vm.VmName), @('Resource group', $vm.ResourceGroup), @('OS disk', $vm.OsDiskName), @('Image version', $(if ($f.ImageVersion) { $f.ImageVersion } else { 'none yet: Create snapshot starts the first one' })))) {
        [void]$f.Info.Children.Add((New-InfoRow $row[0] ([string]$row[1])))
    }
    try {
        $list = Invoke-Busy 'Looking for snapshots of the OS disk ...' { @(Get-AVDTuneOsDiskSnapshots -Arm (Get-StartArm) -Token (Get-ArmToken) -Vm $vm -Now (& $script:Machine.Now)) }
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
    $today = @($list | Where-Object IsToday)
    $gate = Get-AVDTuneGateStatus -Vm $vm -Snapshots $list
    $f.SnapList.ItemsSource = @($today | ForEach-Object { "$($_.Name)  ($($_.Created.ToString('HH:mm')), $(if ($_.ByAVDTune) { 'made by AVDTune' } else { 'made by someone else' }))" })
    if ($today.Count -gt 0) { $f.SnapList.SelectedIndex = 0 }
    $f.SnapList.Visibility = ConvertTo-Vis ($today.Count -gt 0)
    $f.Today = $today
    $ui.BtnStageAction.IsEnabled = ($today.Count -gt 0)
    $ui.BtnStageAction2.IsEnabled = $true
    $others = @($list | Where-Object { -not $_.IsToday }).Count
    $kind = if ($today.Count -gt 0) { 'ok' } else { 'warn' }
    Set-StageMessage ($gate.Detail + $(if ($others -gt 0) { " ($others older snapshot(s) of this disk do not count.)" })) $kind
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
        $started = Invoke-Busy 'Asking Azure to create the incremental snapshot ...' { Start-AVDTuneSnapshot -Arm (Get-StartArm) -Token (Get-ArmToken) -Vm $vm -ImageVersion $f.ImageVersion -User ([string]$script:StartContext.Session.Account) -At (& $script:Machine.Now) }
    }
    catch {
        $script:StartContext.Failures['Snapshot'] = $_.Exception.Message
        Add-StartProtocol 'Snapshot of the OS disk' $_.Exception.Message 'failed'
        Set-StageMessage $_.Exception.Message 'error'
        Update-StartView
        return
    }
    $script:PendingSnapshot = $started
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
                if ($script:OpenStage -eq 'Snapshot') { Update-SnapshotForm }
                Show-Toast "Snapshot $($p.Name) is ready."
            }
            elseif ($s.State -in 'Failed', 'Canceled') {
                $script:SnapTimer.Stop(); $script:PendingSnapshot = $null
                $script:StartContext.Failures['Snapshot'] = "The snapshot $($p.Name) failed in Azure."
                Add-StartProtocol 'Snapshot of the OS disk' "$($p.Name) failed in Azure" 'failed'
                Set-StageMessage $script:StartContext.Failures['Snapshot'] 'error'
                $ui.BtnStageAction2.IsEnabled = $true
                Update-StartView
            }
            elseif ($s.Percent -ne $null) { Set-StageMessage "Snapshot $($p.Name): $([int]$s.Percent) percent ..." 'info' }
        }
        catch {
            $script:SnapTimer.Stop(); $script:PendingSnapshot = $null
            Set-StageMessage $_.Exception.Message 'error'
            $ui.BtnStageAction2.IsEnabled = $true
        }
    })
function Invoke-SnapshotConfirm {
    $f = $script:Form
    if (-not $f.Today -or $f.Today.Count -eq 0) { Set-StageMessage 'There is no finished snapshot of today to confirm.' 'error'; return }
    $snapshot = $f.Today[[Math]::Max(0, $f.SnapList.SelectedIndex)]
    $session = $script:StartContext.Session
    try {
        $record = Confirm-AVDTuneSnapshotGate -Root $script:StateRoot -Snapshot $snapshot -TypedName $f.NameBox.Text -ExpectedName ([string]$session.Name) -User ([string]$env:USERNAME) -ImageVersion $f.ImageVersion -Machine $script:Machine
    }
    catch { Set-StageMessage $_.Exception.Message 'error'; return }
    $made = if ($record.CreatedByAVDTune) { 'yes' } else { 'no' }
    Add-StartProtocol 'Snapshot gate confirmed' "$($record.SnapshotName), created $(([datetime]$record.SnapshotCreated).ToString('yyyy-MM-dd HH:mm')), by AVDTune: $made, confirmed by $($record.ConfirmedBy), ID $($record.SnapshotId)"
    $script:StartContext.Failures.Remove('Snapshot')
    Show-Toast 'Snapshot confirmed. The pages can change the master now.'
    Close-Stage
    Update-StartView
    if ($script:CurrentPage -eq 'Protocol') { Update-ProtocolView }
}
