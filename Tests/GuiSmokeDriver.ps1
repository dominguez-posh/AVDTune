# Dot-sourced by Start-AVDTune.ps1 when AVDTUNE_SMOKE is set (see Tests\Invoke-GuiSmoke.ps1; only in test mode: fake machine, temporary state folder).
# Puts the window off-screen and walks through the steps below on the UI thread; each step returns $true when it is done
# (or $false to be asked again on the next tick). Screenshots of every page land in the output folder (shot-NN-*.png).

$script:SmokeOut = $env:AVDTUNE_SMOKE_OUT
$script:SmokeResults = New-Object System.Collections.ArrayList
$window.WindowStartupLocation = 'Manual'
$window.Left = -20000; $window.Top = -20000
$window.ShowActivated = $false
$window.ShowInTaskbar = $false

function Test-Smoke([string]$Name, [bool]$Ok, $Detail) {
    $line = if ($Ok) { "PASS $Name" } else { "FAIL $Name" + $(if ($null -ne $Detail) { "  -> $Detail" } else { '' }) }
    [void]$script:SmokeResults.Add($line)
}
function Save-SmokeShot([string]$Name) {
    $window.UpdateLayout()
    $w = [int]$window.Content.ActualWidth; $h = [int]$window.Content.ActualHeight
    $bmp = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($w, $h, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $bmp.Render($window.Content)
    $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bmp))
    $fs = [IO.File]::Create((Join-Path $script:SmokeOut "shot-$Name.png"))
    try { $enc.Save($fs) } finally { $fs.Dispose() }
}
function Get-ThemeColor([string]$Key) { ([System.Windows.Application]::Current.Resources.MergedDictionaries[0][$Key]).Color.ToString() }
function Find-Text($Parent, [string]$Text) {
    # True when a TextBlock with this text is below $Parent
    for ($i = 0; $i -lt [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($Parent); $i++) {
        $c = [System.Windows.Media.VisualTreeHelper]::GetChild($Parent, $i)
        if (($c -is [System.Windows.Controls.TextBlock]) -and $c.Text -eq $Text) { return $true }
        if (Find-Text $c $Text) { return $true }
    }
    $false
}

$script:SmokeSteps = [System.Collections.ArrayList]@(
    @{ Name = 'overview'; Do = {
        if (-not $script:Overview) { return $false }   # read in the background
        $state = Get-AVDTuneState $script:StateRoot
        Test-Smoke 'test mode: fake machine and a state folder that is not ProgramData' ($script:TestMode -and $script:Machine.Kind -eq 'Fake' -and -not (Test-AVDTuneDefaultRoot $script:StateRoot)) $script:StateRoot
        Test-Smoke 'state folders were made in the test root' ((Test-Path (Join-Path $script:StateRoot 'runs')) -and (Test-Path (Join-Path $script:StateRoot 'state.json'))) $null
        Test-Smoke 'window title and version' ($window.Title -eq "AVDTune $script:ToolVersion" -and $ui.TxtVersion.Text -like "AVDTune *") $window.Title
        Test-Smoke 'navigation has all 14 pages in plan order' ($ui.NavList.Children.Count -eq 14 -and $ui.NavOverview -and $ui.NavProtocol -and $ui.NavSeal -and $ui.NavList.Children[0].Name -eq 'NavOverview') $ui.NavList.Children.Count
        Test-Smoke 'Overview is the first page and shown' ($script:CurrentPage -eq 'Overview' -and $ui.PageOverview.Visibility -eq 'Visible' -and $ui.NavOverview.IsChecked) $null
        Test-Smoke 'title bar chip shows image name and no version yet' ($ui.TxtChipName.Text -eq 'GM-TEST01' -and $ui.TxtChipVersion.Text -eq 'no image version') "$($ui.TxtChipName.Text) / $($ui.TxtChipVersion.Text)"
        Test-Smoke 'identity card lists image, source image, Windows build, Office' ($ui.PanelIdentity.Children.Count -ge 8 -and (Find-Text $ui.PanelIdentity 'microsoftwindowsdesktop:office-365:win11-25h2-avd-m365:latest') -and (Find-Text $ui.PanelIdentity 'Windows 11 Enterprise multi-session 25H2, build 26100.4652') -and (Find-Text $ui.PanelIdentity '16.0.19231.20138, Monthly Enterprise Channel, x64')) $ui.PanelIdentity.Children.Count
        Test-Smoke 'health card shows the 5 checks' ($ui.PanelHealth.Children.Count -eq 5) $ui.PanelHealth.Children.Count
        Test-Smoke 'second instance is refused (mutex held, checked from another thread)' (-not (Start-Job -ScriptBlock { $m = New-Object System.Threading.Mutex($false, 'Global\AVDTune-Test'); $got = $m.WaitOne(0); if ($got) { $m.ReleaseMutex() }; $got } | Wait-Job | Receive-Job)) $null
        Save-SmokeShot '01-overview-light'
        $true } }
    @{ Name = 'dirty machine'; Do = {
        $dirty = New-AVDTuneFakeMachine -Seed @{ Keys = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'); Services = @(@{ Name = 'RDAgentBootLoader' }); Native = @{ 'dsregcmd.exe /status' = @{ ExitCode = 0; Output = '    AzureAdJoined : YES' } } }
        $keep = $script:Overview
        $script:Overview = Get-AVDTuneOverview -Machine $dirty -Root $script:StateRoot
        Update-OverviewView
        Test-Smoke 'a master with pending restart, AVD agent and join shows warnings and errors' ((Find-Text $ui.PanelHealth 'Must fix') -and (Find-Text $ui.PanelHealth 'Attention') -and (Find-Text $ui.PanelHealth 'AVD agent')) $null
        Save-SmokeShot '02-overview-problems'
        $script:Overview = $keep; Update-OverviewView
        $true } }
    @{ Name = 'theme'; Do = {
        $before = Get-ThemeColor 'WindowBackground'
        $ui.BtnTheme.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        $window.UpdateLayout()
        $after = Get-ThemeColor 'WindowBackground'
        $bg = $window.Background.Color.ToString()
        Test-Smoke 'switch to dark: setting, saved file and theme dictionary' ($script:Settings.Theme -eq 'Dark' -and $before -eq '#FFF3F3F3' -and $after -eq '#FF202020' -and ((Get-Content (Join-Path $script:StateRoot 'config\ui.json') -Raw | ConvertFrom-Json).Theme -eq 'Dark')) "$before -> $after"
        Test-Smoke 'the window follows the swap (DynamicResource)' ($bg -eq '#FF202020') $bg
        Save-SmokeShot '03-overview-dark'
        $true } }
    @{ Name = 'pages'; Do = {
        $index = 4
        foreach ($page in $script:PageTable) {
            Show-Page $page.Key
            $window.UpdateLayout()
            $placeholder = $page.Key -notin 'Overview', 'Protocol'
            $ok = ($script:CurrentPage -eq $page.Key -and $ui["Nav$($page.Key)"].IsChecked -and $ui.PagePlaceholder.Visibility -eq (ConvertTo-Vis $placeholder))
            if ($placeholder) { $ok = $ok -and $ui.TxtPhTitle.Text -eq $page.Title -and $ui.TxtPhPhase.Text -eq "Planned for phase $($page.Phase)" -and $ui.TxtPhText.Text.Length -gt 40 }
            Test-Smoke "page $($page.Key) shows" $ok $null
            if ($page.Key -in 'Updates', 'Seal') { Save-SmokeShot ('{0:00}-page-{1}-dark' -f $index, $page.Key.ToLower()); $index++ }
        }
        Show-Page 'Overview'
        $ui.BtnTheme.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Test-Smoke 'switch back to light' ($script:Settings.Theme -eq 'Light' -and (Get-ThemeColor 'WindowBackground') -eq '#FFF3F3F3' -and $window.Background.Color.ToString() -eq '#FFF3F3F3') $null
        Show-Page 'Updates'; Save-SmokeShot '06-page-updates-light'; Show-Page 'Overview'
        $true } }
    @{ Name = 'new version'; Do = {
        Show-Page 'Overview'
        $expected = (Get-Date).ToString('yyyy.MM') + '.001'
        Start-NewVersion
        $state = Get-AVDTuneState $script:StateRoot
        Test-Smoke 'Start new version asks first, then raises the version in the state' ($script:ConfirmAsked -like "Start image version $expected*" -and $state.ImageVersion -eq $expected -and @($state.Versions).Count -eq 1) "asked='$script:ConfirmAsked' version=$($state.ImageVersion) versions=$(@($state.Versions).Count)"
        Test-Smoke 'the chip shows the version' ($ui.TxtChipVersion.Text -eq $expected) $ui.TxtChipVersion.Text
        $log = @(Get-AVDTuneChangeLog -Root $script:StateRoot -Version $expected)
        Test-Smoke 'a change log entry and a protocol action were written' ($log.Count -eq 1 -and $log[0].Category -eq 'Setup' -and $script:Protocol.Actions.Count -eq 1 -and (Get-ChildItem (Join-Path $script:StateRoot 'Protocols') -Filter '*.md').Count -eq 1) $log.Count
        $true } }
    @{ Name = 'protocol'; Do = {
        Show-Page 'Protocol'
        $window.UpdateLayout()
        $version = (Get-AVDTuneState $script:StateRoot).ImageVersion
        Test-Smoke 'session protocol: AVDTune title, image and the version action' ($ui.TxtProtocol.Text -like 'AVDTune session protocol*' -and $ui.TxtProtocol.Text -like "*Image: GM-TEST01 $version*" -and $ui.TxtProtocol.Text -like "*Image version $version started*" -and $ui.TxtProtocol.Text -notlike '*PackTune*') $ui.TxtProtocol.Text
        $ui.CmbProtocolLanguage.SelectedIndex = 1
        Test-Smoke 'German protocol' ($ui.TxtProtocol.Text -like 'AVDTune-Sitzungsprotokoll*' -and $ui.TxtProtocol.Text -like '*Einrichtung*' -and $script:Settings.ProtocolLanguage -eq 'de') $null
        Save-SmokeShot '07-protocol-session'
        $ui.CmbProtocolLanguage.SelectedIndex = 0
        $ui.SegChange.IsChecked = $true
        $window.UpdateLayout()
        Test-Smoke 'change log view: version selected, table with the automatic entry' ($ui.CmbVersion.SelectedItem -eq $version -and $ui.TxtProtocol.Text -like "# Change log GM-TEST01 $version*" -and $ui.TxtProtocol.Text -like "*Image version $version started*" -and $ui.PanelNote.Visibility -eq 'Visible') $ui.TxtProtocol.Text
        $ui.TxtNote.Text = 'Edge updated to a new build, token=abc123secret'
        $ui.CmbNoteCategory.SelectedItem = 'Software'; $ui.CmbNoteType.SelectedItem = 'Updated'
        Add-ChangeNote
        Test-Smoke 'a note lands in the change log, the secret is removed, the box is empty' ($ui.TxtProtocol.Text -like '*Edge updated to a new build*' -and $ui.TxtProtocol.Text -notlike '*abc123secret*' -and $ui.TxtNote.Text -eq '' -and $ui.TxtProtocol.Text -like '*| Software |*') $ui.TxtProtocol.Text
        Test-Smoke 'a note without text is refused' ($(try { Add-ChangeNote; $false } catch { $_.Exception.Message -like '*note*' })) $null
        Save-SmokeShot '08-protocol-changelog'
        $md = Join-Path $script:SmokeOut 'changelog.md'; $html = Join-Path $script:SmokeOut 'changelog.html'; $txt = Join-Path $script:SmokeOut 'protocol.txt'
        Save-ProtocolFile $md; Save-ProtocolFile $html
        $ui.SegSession.IsChecked = $true; Save-ProtocolFile $txt
        Test-Smoke 'save as file: change log as Markdown and HTML, protocol as text' ((Get-Content $md -Raw) -like '# Change log*' -and (Get-Content $html -Raw) -like '<!DOCTYPE html>*' -and (Get-Content $txt -Raw) -like 'AVDTune session protocol*') $null
        $ui.BtnProtocolCopy.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Test-Smoke 'copy hands the shown text over' ($script:LastCopied -like 'AVDTune session protocol*') $null
        Test-Smoke 'the protocol was saved after every action' ((Get-ChildItem (Join-Path $script:StateRoot 'Protocols') -Filter '*.json').Count -eq 1 -and $script:Protocol.Actions.Count -eq 2) $script:Protocol.Actions.Count
        $true } }
    @{ Name = 'step result hook'; Do = {
        Register-StepResult ([pscustomobject]@{ Id = 'optimization.x'; Section = 'Optimization'; Title = 'Widgets off'; Status = 'Changed'; Message = ''; At = (Get-Date).ToString('o') })
        Test-Smoke 'a step result becomes a protocol action in the right group' (@($script:Protocol.Actions | Where-Object { $_.Category -eq 'optimization' -and $_.Subject -eq 'Widgets off' }).Count -eq 1) $null
        $true } }
    @{ Name = 'refresh and layout'; Do = {
        Show-Page 'Overview'
        $script:Overview = $null; Start-OverviewRefresh
        $script:SmokeWait = 0
        $true } }
    @{ Name = 'refresh result'; Do = {
        if (-not $script:Overview) { return $false }
        Test-Smoke 'Refresh reads the machine again (background)' ($script:Overview.ComputerName -eq 'GM-TEST01' -and $script:Overview.ImageVersion -eq (Get-AVDTuneState $script:StateRoot).ImageVersion) $null
        # nothing was written outside the test root: the real state folder was not created or changed by this run
        Test-Smoke 'every fake write stayed in memory (no registry value written)' ($script:Machine.Log.Count -eq 0) ($script:Machine.Log -join '; ')
        Save-SmokeShot '09-overview-light-final'
        $true } }

    @{ Name = 'read only banner'; Do = {
        Show-Page 'Updates'; $window.UpdateLayout()
        Test-Smoke 'a page that could change the master shows the read-only banner while the gate is closed' ($ui.BoxReadOnly.Visibility -eq 'Visible' -and -not (Test-AVDTuneWriteAllowed)) $null
        Save-SmokeShot '10-readonly-banner'
        Show-Page 'Protocol'
        Test-Smoke 'the protocol page stays usable (no banner)' ($ui.BoxReadOnly.Visibility -eq 'Collapsed') $null
        Show-Page 'Overview'
        $refused = try { [void](Invoke-AVDTuneStep -Step (New-AVDTuneStep -Id 'setup.smoke' -Section Setup -Title 'x' -Test { $true } -Apply { }) -Machine $script:Machine -Mode Apply); $null } catch { $_.Exception.Message }
        Test-Smoke 'a change of the machine is refused through the engine while the gate is closed' ($refused -like '*snapshot gate*') $refused
        $true } }
    @{ Name = 'start: questions'; Do = {
        # the first run opened the questions by itself
        Test-Smoke 'first start without environment.json: the questions are open, 6 questions and the fields' ($script:OpenStage -eq 'Environment' -and $ui.BoxStage.Visibility -eq 'Visible' -and $script:Form.Combos.Count -eq 6 -and $script:Form.Texts.Count -eq 4 -and -not (Test-Path (Join-Path $script:StateRoot 'environment.json'))) $script:OpenStage
        Test-Smoke 'the four stages are listed: questions to do, the rest waiting' ($ui.PanelStages.Children.Count -eq 4 -and (($script:Stages | ForEach-Object Status) -join ',') -eq 'Pending,Locked,Locked,Locked') (($script:Stages | ForEach-Object Status) -join ',')
        Save-SmokeShot '11-start-questions'
        # an invalid combination is explained and cannot be saved
        $set = { param($key, $text) $script:Form.Combos[$key].Control.SelectedItem = $text }
        & $set 'Join' 'Microsoft Entra hybrid join'
        Test-Smoke 'hybrid join without a domain controller: problem shown, save disabled' ($script:Form.Preview.Text -like '*Problem:*domain controller*' -and -not $ui.BtnStageAction.IsEnabled) $script:Form.Preview.Text
        Save-SmokeShot '12-start-questions-problem'
        & $set 'Dc' 'AD DS on premises (VPN or ExpressRoute)'
        & $set 'Identities' 'Synchronized (Entra Connect / Cloud Sync)'
        $script:Form.Texts['TenantId'].Text = 'contoso.example'
        $script:Form.Texts['ClientId'].Text = '66666666-7777-8888-9999-000000000000'
        $script:Form.Texts['VNet'].Text = 'vnet-example'; $script:Form.Texts['Subnet'].Text = 'snet-avd'
        Test-Smoke 'hybrid with an on-premises DC is valid and the preview names the domain step and Azure Files with AD DS' ($ui.BtnStageAction.IsEnabled -and $script:Form.Preview.Text -like '*Domain step*' -and $script:Form.Preview.Text -like '*Azure Files with AD DS*') $script:Form.Preview.Text
        Save-SmokeShot '13-start-questions-hybrid'
        $ui.BtnStageAction.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        $env1 = Get-AVDTuneEnvironment $script:StateRoot
        Test-Smoke 'saving writes environment.json (no secret), closes the form and moves on to the sign-in' ($env1.Answers.Join -eq 'Hybrid' -and $env1.Answers.Dc -eq 'AdDsOnPrem' -and $env1.SignIn.TenantId -eq 'contoso.example' -and $ui.BoxStage.Visibility -eq 'Collapsed' -and (($script:Stages | ForEach-Object Status) -join ',') -eq 'Done,Pending,Locked,Locked') (($script:Stages | ForEach-Object Status) -join ',')
        Test-Smoke 'the protocol has the answered questions' (@($script:Protocol.Actions | Where-Object { $_.Subject -like 'First-run questions answered*' }).Count -eq 1) $null
        # no FSLogix: the two pages disappear from the navigation
        $none = Get-AVDTuneEnvironmentAnswers (Get-AVDTuneEnvironment $script:StateRoot); $none.Profiles = 'None'
        [void](Save-AVDTuneEnvironment -Root $script:StateRoot -Answers $none -User 'smoke'); Update-StartView
        Test-Smoke 'without FSLogix the FSLogix and App Masking pages are hidden' ($ui.NavFSLogix.Visibility -eq 'Collapsed' -and $ui.NavAppMasking.Visibility -eq 'Collapsed' -and $ui.NavUpdates.Visibility -eq 'Visible') $null
        $none.Profiles = 'AzureFiles'; [void](Save-AVDTuneEnvironment -Root $script:StateRoot -Answers $none -User 'smoke'); Update-StartView
        Test-Smoke 'with FSLogix they are back; a change after a version exists is a change log entry' ($ui.NavFSLogix.Visibility -eq 'Visible' -and @(Get-AVDTuneChangeLog -Root $script:StateRoot | Where-Object { $_.Component -eq 'Environment' }).Count -eq 2) $null
        $true } }
    @{ Name = 'start: sign-in'; Do = {
        Open-Stage 'SignIn'; $window.UpdateLayout()
        Test-Smoke 'sign-in form lists the three tokens with their own permissions' ($ui.PanelStageBody.Children.Count -ge 5 -and (Find-Text $ui.PanelStageBody 'Sites') -and (Find-Text $ui.PanelStageBody 'Azure Resource Manager (snapshot, VM size, region): user_impersonation')) $null
        Save-SmokeShot '14-start-signin'
        $ui.BtnStageAction.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        $info = Get-AVDTuneSessionInfo $script:StartContext.Session
        Test-Smoke 'sign-in (fake): connected, three audiences, stage Done, domain stage open' ($info.Connected -and $info.Audiences.Count -eq 3 -and (($script:Stages | ForEach-Object Status) -join ',') -eq 'Done,Done,Pending,Locked') (($script:Stages | ForEach-Object Status) -join ',')
        Test-Smoke 'the protocol names the account and holds no token' (@($script:Protocol.Actions | Where-Object { $_.Subject -eq 'Microsoft 365 and Azure sign-in' -and $_.Note -like 'Signed in as admin.example@*' -and $_.Note -notmatch 'eyJ' }).Count -eq 1) $null
        $true } }
    @{ Name = 'start: domain'; Do = {
        Open-Stage 'Domain'; $window.UpdateLayout()
        $script:Form.Server.Text = '10.0.0.10'; $script:Form.User.Text = 'EXAMPLE\svc-avdtune'
        $ui.BtnStageAction.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Test-Smoke 'connect without a password is refused with a message' ($ui.TxtStageMessage.Text -like '*password*') $ui.TxtStageMessage.Text
        $script:Form.PasswordBox.Password = 'Not-A-Real-Password-1'
        $ui.BtnStageAction.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        $window.UpdateLayout()
        Test-Smoke 'first contact: the certificate and its thumbprint are shown, nothing was bound' ($ui.TxtStageMessage.Text -like '*SHA-256: AB:AB:AB*' -and $ui.TxtStageMessage.Text -like '*Subject: CN=dc1.example.test*' -and $ui.BtnStageAction2.Visibility -eq 'Visible' -and $script:Services.Ldap.Opened.Count -eq 0) $ui.TxtStageMessage.Text
        Save-SmokeShot '15-start-domain-pin'
        $ui.BtnStageAction2.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        $window.UpdateLayout()
        $opened = $script:Services.Ldap.Opened
        Test-Smoke 'pinned, then connected over LDAPS 636 and read: domain, OUs, groups with SIDs, site' ($opened.Count -eq 1 -and $opened[0].Port -eq 636 -and $opened[0].AuthType -eq 'Negotiate' -and $script:Form.Summary.Text -like '*example.test*NetBIOS EXAMPLE*' -and $script:Form.Summary.Text -like '*Default-First-Site-Name*' -and $script:Form.Summary.Text -like '*AVD-Users  S-1-5-21-*-1104*') $script:Form.Summary.Text
        Test-Smoke 'the password is cleared after the read' ($script:Form.PasswordBox.SecurePassword.Length -eq 0) $null
        Test-Smoke 'domain stage Done with the facts, environment.json has the pin and the account name but no password' ((($script:Stages | ForEach-Object Status) -join ',') -eq 'Done,Done,Done,Pending' -and ((Get-Content (Join-Path $script:StateRoot 'environment.json') -Raw) -notmatch 'Not-A-Real-Password') -and (Get-AVDTuneEnvironment $script:StateRoot).Dc.Pins.'10.0.0.10'.Sha256 -and (Get-AVDTuneEnvironment $script:StateRoot).Dc.User -eq 'EXAMPLE\svc-avdtune') $null
        Save-SmokeShot '16-start-domain-read'
        # the certificate changes: the connection stops
        $script:Services.Ldap.Store.Servers['10.0.0.10'].Cert = @{ Sha256 = ('CD' * 32); Thumbprint = ('CD' * 20); Subject = 'CN=dc1.example.test'; Issuer = 'CN=Other CA'; NotBefore = ''; NotAfter = '' }
        Open-Stage 'Domain'
        $script:Form.PasswordBox.Password = 'Not-A-Real-Password-1'
        $ui.BtnStageAction.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        $window.UpdateLayout()
        Test-Smoke 'changed certificate: error shown with both thumbprints, no second bind, pin button offered' ($ui.TxtStageMessage.Text -like '*changed*' -and $ui.TxtStageMessage.Text -like "*$('CD' * 32)*" -and $script:Services.Ldap.Opened.Count -eq 1 -and $ui.BtnStageAction2.Visibility -eq 'Visible') $ui.TxtStageMessage.Text
        Save-SmokeShot '17-start-domain-cert-changed'
        $script:Services.Ldap.Store.Servers['10.0.0.10'].Cert = @{ Sha256 = ('AB' * 32); Thumbprint = ('AB' * 20); Subject = 'CN=dc1.example.test'; Issuer = 'CN=Example Test CA'; NotBefore = '2026-01-01T00:00:00Z'; NotAfter = '2027-01-01T00:00:00Z' }
        Close-Stage
        $true } }
    @{ Name = 'start: snapshot'; Do = {
        if (-not $script:SnapStarted) {
            Open-Stage 'Snapshot'; $window.UpdateLayout()
            Test-Smoke 'snapshot gate without a snapshot of today: says so, confirm disabled, create offered' ($ui.TxtStageMessage.Text -like '*No snapshot of the OS disk from today*' -and -not $ui.BtnStageAction.IsEnabled -and $ui.BtnStageAction2.Visibility -eq 'Visible' -and (Find-Text $ui.PanelStageBody 'gm-test01') -and (Find-Text $ui.PanelStageBody 'gm-test01_osdisk')) $ui.TxtStageMessage.Text
            Save-SmokeShot '18-start-snapshot-none'
            $ui.BtnStageAction2.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
            $put = $script:Services.Arm.Store.LastPut
            Test-Smoke 'Create snapshot now: incremental request with image version and user tags, the button waits' ($put.properties.incremental -eq $true -and $put.tags.ImageVersion -eq (Get-AVDTuneState $script:StateRoot).ImageVersion -and $put.tags.CreatedWith -eq 'AVDTune' -and $script:PendingSnapshot -and -not $ui.BtnStageAction2.IsEnabled) ($put | ConvertTo-Json -Compress -Depth 4)
            Test-Smoke 'the snapshot has the name of the plan' ($script:PendingSnapshot.Name -match ('^gm-test01-avdtune-' + [regex]::Escape((Get-AVDTuneState $script:StateRoot).ImageVersion) + '-\d{8}-\d{4}$')) $script:PendingSnapshot.Name
            Save-SmokeShot '19-start-snapshot-creating'
            $script:SnapStarted = $true
            return $false
        }
        if ($script:PendingSnapshot) { return $false }   # the timer polls Azure (fake) until the snapshot is ready
        $window.UpdateLayout()
        Test-Smoke 'when ready the snapshot is listed and can be confirmed' ($ui.BtnStageAction.IsEnabled -and $script:Form.Today.Count -eq 1 -and $script:Form.Today[0].ByAVDTune -and $script:Form.SnapList.Visibility -eq 'Visible') $ui.TxtStageMessage.Text
        Save-SmokeShot '20-start-snapshot-ready'
        $script:Form.NameBox.Text = 'Alex'
        $ui.BtnStageAction.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Test-Smoke 'one word is no full name: the gate stays closed' (-not (Test-AVDTuneWriteAllowed) -and $ui.TxtStageMessage.Text -like '*full name*') $ui.TxtStageMessage.Text
        $script:Form.NameBox.Text = 'Max Mustermann'
        $ui.BtnStageAction.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Test-Smoke 'a name that is not the signed-in account does not open the gate' (-not (Test-AVDTuneWriteAllowed) -and $ui.TxtStageMessage.Text -like '*does not match*') $ui.TxtStageMessage.Text
        $script:Form.NameBox.Text = 'Alex Example'
        $ui.BtnStageAction.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        $window.UpdateLayout()
        $state = Get-AVDTuneState $script:StateRoot
        Test-Smoke 'confirmed with the full name: gate open, state.json has the record' ((Test-AVDTuneWriteAllowed) -and $state.SnapshotGate.ConfirmedBy -eq 'Alex Example' -and $state.SnapshotGate.CreatedByAVDTune -eq $true -and $state.SnapshotGate.SnapshotId -like '*/snapshots/gm-test01-avdtune-*') ($state.SnapshotGate | ConvertTo-Json -Compress)
        $entry = @(Get-AVDTuneChangeLog -Root $script:StateRoot | Where-Object { $_.Category -eq 'Snapshot' })
        Test-Smoke 'the change log has the snapshot entry (name, time, ID, created by AVDTune: yes)' ($entry.Count -eq 1 -and $entry[0].SnapshotId -eq $state.SnapshotGate.SnapshotId -and $entry[0].Text -like '*created by AVDTune: yes*') ($entry | ConvertTo-Json -Compress)
        $act = @($script:Protocol.Actions | Where-Object { $_.Subject -eq 'Snapshot gate confirmed' })
        Test-Smoke 'the protocol has the confirmation with name, time and whether AVDTune made it' ($act.Count -eq 1 -and $act[0].Note -like '*gm-test01-avdtune-*' -and $act[0].Note -like '*by AVDTune: yes*' -and $act[0].Note -like '*confirmed by Alex Example*') ($act | ConvertTo-Json -Compress)
        Test-Smoke 'all four stages are Done, the rollback hint is on the Overview' ((($script:Stages | ForEach-Object Status) -join ',') -eq 'Done,Done,Done,Done' -and $ui.BoxRollback.Visibility -eq 'Visible' -and $ui.TxtRollback.Text -like '*Swap OS disk*') (($script:Stages | ForEach-Object Status) -join ',')
        Save-SmokeShot '21-start-done'
        Show-Page 'Updates'; $window.UpdateLayout()
        Test-Smoke 'unlocked: no read-only banner on the page any more' ($ui.BoxReadOnly.Visibility -eq 'Collapsed') $null
        Save-SmokeShot '22-page-updates-unlocked'
        Show-Page 'Overview'
        $ok = (Invoke-AVDTuneStep -Step (New-AVDTuneStep -Id 'setup.smoke' -Section Setup -Title 'x' -Test { $true } -Apply { }) -Machine $script:Machine -Mode Apply).Status
        Test-Smoke 'the engine accepts a change after the confirmation' ($ok -eq 'Unchanged') $ok
        $true } }
    @{ Name = 'start: sign-out and dark'; Do = {
        Open-Stage 'SignIn'; $window.UpdateLayout()
        $ui.BtnStageAction2.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Test-Smoke 'sign out removes every token from memory (checked as before seal)' (Test-AVDTuneSessionClear $script:StartContext.Session) $null
        $allFiles = (Get-ChildItem $script:StateRoot -Recurse -File | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join "`n"
        Test-Smoke 'no token, refresh token or password in any file of the state folder' ($allFiles -notmatch 'eyJ[A-Za-z0-9_-]{10,}' -and $allFiles -notmatch 'fake-refresh' -and $allFiles -notmatch 'Not-A-Real-Password') $null
        Test-Smoke 'every service of the start sequence was a fake (no real adapter in test mode)' ($script:Services.Auth.Kind -eq 'Fake' -and $script:Services.Arm.Kind -eq 'Fake' -and $script:Services.Ldap.Kind -eq 'Fake') $null
        if ($script:Settings.Theme -ne 'Dark') { $ui.BtnTheme.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) }
        Open-Stage 'Environment'; $window.UpdateLayout()
        Save-SmokeShot '23-start-questions-dark'
        Close-Stage
        $ui.BtnTheme.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        $true } }
)

$script:SmokeTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:SmokeTimer.Interval = [TimeSpan]::FromMilliseconds(400)
$script:SmokeTimer.Add_Tick({
    try {
        if ($script:SmokeSteps.Count -eq 0) {
            $script:SmokeTimer.Stop()
            $script:SmokeResults | Set-Content (Join-Path $script:SmokeOut 'results.txt')
            $window.Close()
            return
        }
        $step = $script:SmokeSteps[0]
        try { $done = & $step.Do $step }
        catch { Test-Smoke "step '$($step.Name)'" $false "$($_.Exception.Message) @ $($_.InvocationInfo.ScriptLineNumber)"; $done = $true }
        if ($done) { $script:SmokeSteps.RemoveAt(0) }
    }
    catch {
        [void]$script:SmokeResults.Add("FAIL driver: $($_.Exception.Message)")
        $script:SmokeResults | Set-Content (Join-Path $script:SmokeOut 'results.txt')
        $window.Close()
    }
})
$window.Add_ContentRendered({ $script:SmokeTimer.Start() })
