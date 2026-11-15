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
function Get-SmokeBounds($Element) { $Element.TransformToAncestor($window).TransformBounds((New-Object System.Windows.Rect(0, 0, $Element.ActualWidth, $Element.ActualHeight))) }
function Test-HeadClear($Subtitle, $Buttons) {
    # The intro text of a page must not reach under or against the buttons of the head: below them, or at least 16 px to the left
    $s = Get-SmokeBounds $Subtitle; $b = Get-SmokeBounds $Buttons
    ($s.Top -ge $b.Bottom) -or ($s.Bottom -le $b.Top) -or ($s.Right + 16 -le $b.Left)
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

# ---- task bar (issue #22): one scene per theme with the states running, several, failed result and the opened list
$script:SmokeRetryCalls = 0
function Start-SmokeRetry { $script:SmokeRetryCalls++ }
function Reset-TaskScene {
    $script:UiTasks.Clear()
    foreach ($r in @($script:TaskRows.Values)) { $ui.PanelTaskList.Children.Remove($r.Border) }
    $script:TaskRows.Clear()
    Show-TaskList $false
    Update-TaskBar
}
function Get-ThemeBrushColor([string]$Key) { ([System.Windows.Application]::Current.Resources.MergedDictionaries[0][$Key]).Color.ToString() }
function Invoke-TaskScene([string]$Suffix) {
    Reset-TaskScene
    $window.UpdateLayout()
    Test-Smoke "task bar $Suffix`: idle with no task: says so, no bar, no pills" ($ui.TxtTaskTitle.Text -eq 'No task running' -and $ui.PbTask.Visibility -eq 'Hidden' -and $ui.PillTaskCount.Visibility -eq 'Collapsed' -and $ui.PillTaskResult.Visibility -eq 'Collapsed') $ui.TxtTaskTitle.Text
    Test-Smoke "task bar $Suffix`: the bar follows the theme (background token of the theme)" ($ui.BoxTaskBar.Background.Color.ToString() -eq (Get-ThemeBrushColor 'AccentFaint')) "$($ui.BoxTaskBar.Background.Color) / $(Get-ThemeBrushColor 'AccentFaint')"
    $a = Start-AVDTuneUiTask -Kind 'benchmark' -Title 'Benchmark (full run)' -Step 'Disk: sequential read' -Percent 45
    $a.Started = (Get-Date).AddSeconds(-95)
    Update-TaskBar; $window.UpdateLayout()
    Test-Smoke "task bar $Suffix`: one running task: title, step, determinate bar at 45 percent, no counter" ($ui.TxtTaskTitle.Text -eq 'Benchmark (full run)' -and $ui.TxtTaskStep.Text -eq 'Disk: sequential read' -and $ui.PbTask.Visibility -eq 'Visible' -and -not $ui.PbTask.IsIndeterminate -and $ui.PbTask.Value -eq 45 -and $ui.PillTaskCount.Visibility -eq 'Collapsed') "$($ui.TxtTaskTitle.Text) / $($ui.PbTask.Value)"
    Save-SmokeShot "task-1-running-$Suffix"
    $b = Start-AVDTuneUiTask -Kind 'update-scan' -Title 'Searching for updates' -Step 'Asking Windows Update' -Retry @{ Command = 'Start-SmokeRetry'; Arguments = @() }
    $c = Start-AVDTuneUiTask -Kind 'release-check' -Title 'Checking for a new AVDTune version' -Step 'Asking GitHub'
    $b.Started = (Get-Date).AddSeconds(-20); $c.Started = (Get-Date).AddSeconds(-12)
    Add-AVDTuneUiTaskLog $b 'Windows Update: 3 results'
    Add-AVDTuneUiTaskLog $b 'winget upgrade: could not start, token=abc123secret' 'Warning'
    Update-TaskBar; $window.UpdateLayout()
    Test-Smoke "task bar $Suffix`: several running: the oldest is shown and the counter says +2 more" ($ui.TxtTaskTitle.Text -eq 'Benchmark (full run)' -and $ui.PillTaskCount.Visibility -eq 'Visible' -and $ui.TxtTaskCount.Text -eq '+2 more') $ui.TxtTaskCount.Text
    Save-SmokeShot "task-2-several-$Suffix"
    Complete-AVDTuneUiTask $a -Summary 'Benchmark finished: host score 1020'
    Update-TaskBar
    Test-Smoke "task bar $Suffix`: when the first one ends, the next one is shown, without a percent the bar runs indeterminate" ($ui.TxtTaskTitle.Text -eq 'Searching for updates' -and $ui.PbTask.IsIndeterminate -and $ui.TxtTaskCount.Text -eq '+1 more') "$($ui.TxtTaskTitle.Text) / $($ui.PbTask.IsIndeterminate)"
    Save-SmokeShot "task-2b-indeterminate-$Suffix"
    Complete-AVDTuneUiTask $c -Summary 'AVDTune is up to date'
    Complete-AVDTuneUiTask $b -Failed -Summary 'The search failed: Windows Update could not be reached.'
    Update-TaskBar; $window.UpdateLayout()
    Test-Smoke "task bar $Suffix`: right after the end the result is shown: failed pill, the cause, red dot, no bar" ($ui.PillTaskResult.Visibility -eq 'Visible' -and $ui.TxtTaskResult.Text -eq 'Failed' -and $ui.TxtTaskStep.Text -like 'The search failed*' -and $ui.PbTask.Visibility -eq 'Hidden' -and $ui.DotTask.Fill -eq [System.Windows.Application]::Current.Resources.MergedDictionaries[0]['Danger']) "$($ui.TxtTaskResult.Text) / $($ui.TxtTaskStep.Text)"
    Save-SmokeShot "task-3-failed-$Suffix"
    $d = Start-AVDTuneUiTask -Kind 'readiness-manual' -Title 'Readiness analysis' -Step 'Checking the master against the readiness list' -Percent 70
    $d.Started = (Get-Date).AddSeconds(-8)
    Show-TaskList $true
    Update-TaskBar; $window.UpdateLayout()
    Test-Smoke "task bar $Suffix`: a click opens the list: one row per task, the newest on top" ($ui.BoxTaskList.Visibility -eq 'Visible' -and $ui.PanelTaskList.Children.Count -eq 4 -and $script:TaskRows[[int]$d.Id].Border -eq $ui.PanelTaskList.Children[0] -and $script:TaskRows[[int]$a.Id].Border -eq $ui.PanelTaskList.Children[3]) $ui.PanelTaskList.Children.Count
    $rowB = $script:TaskRows[[int]$b.Id]; $rowA = $script:TaskRows[[int]$a.Id]; $rowD = $script:TaskRows[[int]$d.Id]
    Test-Smoke "task bar $Suffix`: rows show status pills (Running, Done, Failed), duration and the summary or step" ($rowD.PillText.Text -eq 'Running' -and $rowA.PillText.Text -eq 'Done' -and $rowB.PillText.Text -eq 'Failed' -and $rowA.Sub.Text -like 'Benchmark finished: host score 1020*1 min 35 s*' -and $rowB.Sub.Text -like 'The search failed*' -and $rowD.Sub.Text -like 'Checking the master*s') "$($rowA.Sub.Text) | $($rowB.Sub.Text) | $($rowD.Sub.Text)"
    Test-Smoke "task bar $Suffix`: only the failed row with a retry command has Retry, a running row has its progress bar, an ended row has none" ($rowB.RetryBtn.Visibility -eq 'Visible' -and $rowA.RetryBtn.Visibility -eq 'Collapsed' -and $rowD.RetryBtn.Visibility -eq 'Collapsed' -and $rowD.Bar.Visibility -eq 'Visible' -and $rowD.Bar.Value -eq 70 -and $rowA.Bar.Visibility -eq 'Collapsed') $null
    $rowB.LogBtn.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    $window.UpdateLayout()
    Test-Smoke "task bar $Suffix`: Show log unfolds the log of the row, the secret is not in it, the button says Hide log" ($rowB.LogBorder.Visibility -eq 'Visible' -and $rowB.LogBox.Text -like '*Windows Update: 3 results*' -and $rowB.LogBox.Text -like '*could not start*' -and $rowB.LogBox.Text -notlike '*abc123secret*' -and [string]$rowB.LogBtn.Content -eq 'Hide log') $rowB.LogBox.Text
    Save-SmokeShot "task-4-list-$Suffix"
    return @{ A = $a; B = $b; C = $c; D = $d }
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
        Test-Smoke 'second instance is refused (mutex held, checked from another thread)' (-not (Start-Job -ArgumentList $script:MutexName -ScriptBlock { param($Name) $m = New-Object System.Threading.Mutex($false, $Name); $got = $m.WaitOne(0); if ($got) { $m.ReleaseMutex() }; $got } | Wait-Job | Receive-Job)) $null
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
            $placeholder = $page.Key -notin 'Overview', 'Protocol', 'Updates', 'UpdateBlock', 'UserExperience', 'Benchmark', 'FSLogix'
            $ok = ($script:CurrentPage -eq $page.Key -and $ui["Nav$($page.Key)"].IsChecked -and $ui.PagePlaceholder.Visibility -eq (ConvertTo-Vis $placeholder))
            if ($placeholder) { $ok = $ok -and $ui.TxtPhTitle.Text -eq $page.Title -and $ui.TxtPhPhase.Text -eq "Planned for phase $($page.Phase)" -and $ui.TxtPhText.Text.Length -gt 40 }
            Test-Smoke "page $($page.Key) shows" $ok $null
            if ($page.Key -in 'Updates', 'UpdateBlock', 'Seal') { Save-SmokeShot ('{0:00}-page-{1}-dark' -f $index, $page.Key.ToLower()); $index++ }
        }
        Test-Smoke 'last page is "Cleanup and finish" (the master is never sysprepped)' ((($script:PageTable | Where-Object Key -eq 'Seal').Title -eq 'Cleanup and finish') -and -not (Find-Text $ui.NavList 'Cleanup and seal') -and (Find-Text $ui.NavList 'Cleanup and finish') -and $ui.TxtPhText.Text -like '*never sysprepped*') $ui.TxtPhText.Text
        $keepWidth = $window.Width
        foreach ($width in 1280, 960) {
            $window.Width = $width
            foreach ($head in @(@('Overview', 'TxtOverviewSubtitle', 'PanelOverviewHead'), @('Updates', 'TxtUpdSubtitle', 'PanelUpdHead'), @('UpdateBlock', 'TxtBlockSubtitle', 'PanelBlockHead'), @('UserExperience', 'FSLogix', 'TxtUxSubtitle', 'PanelUxHead'), @('UserExperience', 'TxtUxSubtitle', 'PanelUxHead'), @('Protocol', 'TxtProtocolSubtitle', 'PanelProtocolHead'), @('FSLogix', 'TxtFslSubtitle', 'PanelFslHead'))) {
                Show-Page $head[0]; $window.UpdateLayout()
                Test-Smoke "page $($head[0]) at $width px: the intro text does not run under the buttons" (Test-HeadClear $ui[$head[1]] $ui[$head[2]]) "$(Get-SmokeBounds $ui[$head[1]]) / $(Get-SmokeBounds $ui[$head[2]])"
            }
            if ($width -eq 960) { Show-Page 'Updates'; Save-SmokeShot '06-page-updates-narrow' }
        }
        $window.Width = $keepWidth
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
        Test-Smoke 'every fake write stayed in memory (no registry value written)' (@($script:Machine.Log | Where-Object { $_ -notlike 'Run *' }).Count -eq 0) ($script:Machine.Log -join '; ')
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
        Test-Smoke 'first start without environment.json: the questions are open, 6 questions and the fields (snapshot name pattern with its default)' ($script:OpenStage -eq 'Environment' -and $ui.BoxStage.Visibility -eq 'Visible' -and $script:Form.Combos.Count -eq 6 -and $script:Form.Texts.Count -eq 4 -and $script:Form.Texts['SnapshotNamePattern'].Text -eq '{OsDisk}-{DD}.{MM}.{YYYY}-{N}' -and -not (Test-Path (Join-Path $script:StateRoot 'environment.json'))) $script:OpenStage
        Test-Smoke 'the four stages are listed: questions to do, the rest waiting' ($ui.PanelStages.Children.Count -eq 4 -and (($script:Stages | ForEach-Object Status) -join ',') -eq 'Pending,Locked,Locked,Locked') (($script:Stages | ForEach-Object Status) -join ',')
        Test-Smoke 'no tenant in the questions (issue #11): no tenant field, no forget box before a tenant exists, the client ID is optional' (-not $script:Form.Texts.ContainsKey('TenantId') -and $null -eq $script:Form.ForgetTenant -and -not (Find-Text $ui.PanelStageBody 'Tenant (domain or ID)') -and (Find-Text $ui.PanelStageBody 'Client ID of the app registration (optional)') -and $script:Form.Texts['ClientId'].Text -eq '' -and $script:Form.Preview.Text -like "*No client ID: at the sign-in AVDTune creates*" -and $script:Form.Preview.Text -like '*tenant is not asked*') (@($script:Form.Texts.Keys) -join ',')
        Save-SmokeShot '11-start-questions'
        # an invalid combination is explained and cannot be saved
        $set = { param($key, $text) $script:Form.Combos[$key].Control.SelectedItem = $text }
        & $set 'Join' 'Microsoft Entra hybrid join'
        Test-Smoke 'hybrid join without a domain controller: problem shown, save disabled' ($script:Form.Preview.Text -like '*Problem:*domain controller*' -and -not $ui.BtnStageAction.IsEnabled) $script:Form.Preview.Text
        Save-SmokeShot '12-start-questions-problem'
        & $set 'Dc' 'AD DS on premises (VPN or ExpressRoute)'
        & $set 'Identities' 'Synchronized (Entra Connect / Cloud Sync)'
        # the client ID stays empty: the sign-in creates AVDTune's own app registration (fake Graph)
        $script:Form.Texts['VNet'].Text = 'vnet-example'; $script:Form.Texts['Subnet'].Text = 'snet-avd'
        Test-Smoke 'hybrid with an on-premises DC is valid and the preview names the domain step and Azure Files with AD DS' ($ui.BtnStageAction.IsEnabled -and $script:Form.Preview.Text -like '*Domain step*' -and $script:Form.Preview.Text -like '*Azure Files with AD DS*') $script:Form.Preview.Text
        Save-SmokeShot '13-start-questions-hybrid'
        $ui.BtnStageAction.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        $env1 = Get-AVDTuneEnvironment $script:StateRoot
        Test-Smoke 'saving writes environment.json (no secret), closes the form and moves on to the sign-in' ($env1.Answers.Join -eq 'Hybrid' -and $env1.Answers.Dc -eq 'AdDsOnPrem' -and $env1.SignIn.TenantId -eq '' -and $env1.SignIn.ClientId -eq '' -and $ui.BoxStage.Visibility -eq 'Collapsed' -and (($script:Stages | ForEach-Object Status) -join ',') -eq 'Done,Pending,Locked,Locked') (($script:Stages | ForEach-Object Status) -join ',')
        Test-Smoke 'first run in a development copy: no shortcut question, the hint to install first (issue #15)' ($script:LastToast -like '*desktop shortcut can be created once AVDTune is installed*' -and $script:OpenStage -ne 'Shortcut') $script:LastToast
        Test-Smoke 'the protocol has the answered questions' (@($script:Protocol.Actions | Where-Object { $_.Subject -like 'First-run questions answered*' }).Count -eq 1) $null
        # no FSLogix: the two pages disappear from the navigation
        $none = Get-AVDTuneEnvironmentAnswers (Get-AVDTuneEnvironment $script:StateRoot); $none.Profiles = 'None'
        [void](Save-AVDTuneEnvironment -Root $script:StateRoot -Answers $none -User 'smoke'); Update-StartView
        Test-Smoke 'without FSLogix the FSLogix and App Masking pages are hidden' ($ui.NavFSLogix.Visibility -eq 'Collapsed' -and $ui.NavAppMasking.Visibility -eq 'Collapsed' -and $ui.NavUpdates.Visibility -eq 'Visible') $null
        $none.Profiles = 'AzureFiles'; [void](Save-AVDTuneEnvironment -Root $script:StateRoot -Answers $none -User 'smoke'); Update-StartView
        Test-Smoke 'with FSLogix they are back; a change after a version exists is a change log entry' ($ui.NavFSLogix.Visibility -eq 'Visible' -and @(Get-AVDTuneChangeLog -Root $script:StateRoot | Where-Object { $_.Component -eq 'Environment' }).Count -eq 2) $null
        $true } }
    @{ Name = 'shortcut question'; Do = {
        # issue #15: the installed copy asks once; the shortcut goes into the desktop folder of the test state, never the real desktop
        $script:ShortcutTestMode = 'Installed'
        $desk = Join-Path $script:StateRoot 'desktop-test'
        Test-Smoke 'installed copy, not answered: the question opens below the stages' ((Show-ShortcutQuestion) -and $script:OpenStage -eq 'Shortcut' -and $ui.BoxStage.Visibility -eq 'Visible' -and $ui.TxtStageTitle.Text -eq 'Desktop shortcut' -and $ui.BtnStageAction2.Visibility -eq 'Visible' -and (Find-Text $ui.PanelStageBody 'as administrator (Windows asks for confirmation)')) $script:OpenStage
        $window.UpdateLayout(); $ui.BoxStage.BringIntoView(); $window.UpdateLayout()
        Save-SmokeShot '13b-shortcut-question'
        $ui.BtnStageAction.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        $link = Get-AVDTuneDesktopShortcut -Folder $desk -InstallRoot $script:RelInstallRoot
        Test-Smoke 'Create: AVDTune.lnk in the test desktop, runs as administrator, points to the launcher; the answer is stored and the card closes' ($link -and $link.Matches -and $link.RunAs -and (Get-AVDTuneShortcutAnswer -Root $script:StateRoot) -eq 'Yes' -and $ui.BoxStage.Visibility -eq 'Collapsed' -and $desk -like "$($script:StateRoot)*") ($link | Out-String)
        Test-Smoke 'answered: not asked again' (-not (Show-ShortcutQuestion) -and $script:OpenStage -ne 'Shortcut') $null
        Test-Smoke 'the Integrity and updates card offers Remove' ([string]$ui.BtnRelShortcut.Content -eq 'Remove desktop shortcut' -and $ui.TxtRelShortcut.Text -like 'Desktop shortcut on your desktop*') $ui.TxtRelShortcut.Text
        $ui.BtnRelShortcut.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Test-Smoke 'Remove deletes it; the card offers Create again' (-not (Test-Path (Join-Path $desk 'AVDTune.lnk')) -and [string]$ui.BtnRelShortcut.Content -eq 'Create desktop shortcut') $null
        $script:ShortcutTestMode = 'Development'; Update-ShortcutRow
        Test-Smoke 'not installed: Create is off and the card says to install first' (-not $ui.BtnRelShortcut.IsEnabled -and $ui.TxtRelShortcut.Text -like '*install AVDTune first*') $ui.TxtRelShortcut.Text
        $script:ShortcutTestMode = ''; Update-ShortcutRow
        Test-Smoke 'the protocol has the shortcut created and removed' (@($script:Protocol.Actions | Where-Object { $_.Subject -eq 'Desktop shortcut created' }).Count -eq 1 -and @($script:Protocol.Actions | Where-Object { $_.Subject -eq 'Desktop shortcut removed' }).Count -eq 1) $null
        $true } }
    @{ Name = 'start: sign-in'; Do = {
        Open-Stage 'SignIn'; $window.UpdateLayout()
        Test-Smoke 'sign-in form lists the three tokens with their permissions' ($ui.PanelStageBody.Children.Count -ge 5 -and (Find-Text $ui.PanelStageBody 'Sites') -and (Find-Text $ui.PanelStageBody 'Azure Resource Manager (snapshot, VM size, region): user_impersonation')) $null
        Test-Smoke 'sign-in form without tenant and client ID: tenant from the sign-in, own app registration announced, account field' ((Find-Text $ui.PanelStageBody 'Taken from the sign-in (tid of the token) and saved') -and (Find-Text $ui.PanelStageBody "None yet: AVDTune creates its own app registration 'AVDTune' first") -and $script:Form.Account -and $script:Form.Account.Text -eq '') $null
        Save-SmokeShot '14-start-signin'
        # a wrong account is refused before any sign-in window
        $script:Form.Account.Text = 'admin'
        $ui.BtnStageAction.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Test-Smoke 'an account that is not name@domain is refused in the form, nothing signed in' ($ui.TxtStageMessage.Text -like '*name@domain*' -and @($script:Services.Auth.Log | Where-Object { $_ -like 'SignIn*' }).Count -eq 0) $ui.TxtStageMessage.Text
        $script:Form.Account.Text = 'admin.example@contoso.example'
        $script:ConfirmAsked = ''
        $ui.BtnStageAction.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        $envSigned = Get-AVDTuneEnvironment $script:StateRoot
        $fakeApp = @($script:Services.Auth.Store.Apps)[0]
        Test-Smoke 'setup asked first and named the consent that stays with Microsoft Graph Command Line Tools' ($script:ConfirmAsked -like "*Microsoft Graph Command Line Tools*Application.ReadWrite.All*consent for your account only*takes these two out of your own consent*whole organization*") $script:ConfirmAsked
        Test-Smoke 'setup sign-in (fake) at organizations with the account, registration AVDTune created, then the normal sign-in with it' (@($script:Services.Auth.Log | Where-Object { $_ -like 'SignIn tenant=organizations client=setup hint=admin.example@contoso.example*' }).Count -eq 1 -and $fakeApp -and @($script:Services.Auth.Log | Where-Object { $_ -like "SignIn tenant=11111111-2222-3333-4444-555555555555 client=$($fakeApp.appId) hint=admin.example@contoso.example*" }).Count -eq 1) ($script:Services.Auth.Log -join ' | ')
        Test-Smoke 'environment.json has the tenant of the token and the client ID of the new registration; the change log says so' ($envSigned.SignIn.TenantId -eq '11111111-2222-3333-4444-555555555555' -and $envSigned.SignIn.ClientId -eq $fakeApp.appId -and @(Get-AVDTuneChangeLog -Root $script:StateRoot | Where-Object { $_.Text -like 'Tenant taken from the sign-in: 11111111-*' }).Count -eq 1 -and @(Get-AVDTuneChangeLog -Root $script:StateRoot | Where-Object { $_.Text -like "Client ID of AVDTune's own app registration saved*" }).Count -eq 1) ($envSigned.SignIn | ConvertTo-Json -Compress)
        Test-Smoke 'the protocol has the registration, the tenant and the warning about the setup consent' (@($script:Protocol.Actions | Where-Object { $_.Subject -eq 'Sign-in: tenant and app registration' -and $_.Note -like "*App registration 'AVDTune' created*" }).Count -eq 1 -and @($script:Protocol.Actions | Where-Object { $_.Subject -eq 'Setup consent of Microsoft Graph Command Line Tools' -and $_.Note -like '*whole organization stays*' }).Count -eq 1 -and @($script:Protocol.Actions | Where-Object { $_.Note -like "*taken out of your own consent for 'Microsoft Graph Command Line Tools'*" }).Count -eq 1) $null
        $fakeSp = @($script:Services.Auth.Store.ServicePrincipals | Where-Object { $_.appId -eq $fakeApp.appId })[0]
        Test-Smoke 'the enterprise app requires an assignment, the admin is assigned and consented for himself only' ($fakeSp.appRoleAssignmentRequired -eq $true -and @($fakeSp.Assigned).Count -eq 1 -and @($script:Services.Auth.Store.Grants | Where-Object { $_.clientId -eq $fakeSp.id -and $_.consentType -eq 'Principal' }).Count -eq 2 -and @($script:Services.Auth.Store.Grants | Where-Object { $_.consentType -eq 'AllPrincipals' }).Count -eq 0) $null
        $info = Get-AVDTuneSessionInfo $script:StartContext.Session
        Test-Smoke 'sign-in (fake): connected, three audiences, stage Done, domain stage open' ($info.Connected -and $info.Audiences.Count -eq 3 -and (($script:Stages | ForEach-Object Status) -join ',') -eq 'Done,Done,Pending,Locked') (($script:Stages | ForEach-Object Status) -join ',')
        Test-Smoke 'the protocol names the account and holds no token' (@($script:Protocol.Actions | Where-Object { $_.Subject -eq 'Microsoft 365 and Azure sign-in' -and $_.Note -like 'Signed in as admin.example@*' -and $_.Note -notmatch 'eyJ' }).Count -eq 1) $null
        # the questions now show the saved tenant only as "forget"
        Open-Stage 'Environment'; $window.UpdateLayout()
        Test-Smoke 'with a saved tenant the questions offer only to forget it, still no tenant field' ($script:Form.ForgetTenant -and -not $script:Form.ForgetTenant.IsChecked -and [string]$script:Form.ForgetTenant.Content -like '*11111111-2222-3333-4444-555555555555*' -and -not $script:Form.Texts.ContainsKey('TenantId')) $null
        Save-SmokeShot '14b-start-questions-tenant'
        Close-Stage
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
        # a DC without LDAPS: warning first, no bind; only the confirmation (logged) connects, Kerberos for a DNS name
        $script:Services.Ldap.Store.Servers['dc9.example.test'] = @{ Ldaps = $false; Ldap389 = $true; Cert = $null; BadPassword = $false }
        Open-Stage 'Domain'
        $script:Form.Server.Text = 'dc9.example.test'; $script:Form.PasswordBox.Password = 'Not-A-Real-Password-1'
        $opened = $script:Services.Ldap.Opened.Count
        $ui.BtnStageAction.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        $window.UpdateLayout()
        Test-Smoke 'DC without LDAPS: warning shown, no bind before the confirmation' ($ui.TxtStageMessage.Text -like '*does not answer*Kerberos*' -and $script:Services.Ldap.Opened.Count -eq $opened -and $ui.BtnStageAction2.Visibility -eq 'Visible') $ui.TxtStageMessage.Text
        Save-SmokeShot '17b-start-domain-no-ldaps'
        # N3: the warning was for dc9; after the name changes the confirmation is gone
        $script:Form.Server.Text = 'dc8.example.test'
        Test-Smoke 'a changed server name drops the pending LDAP 389 confirmation' ($ui.BtnStageAction2.Visibility -eq 'Collapsed' -and -not $script:Form.PendingServer -and -not $script:StageAction2) $null
        $script:Form.Server.Text = 'dc9.example.test'
        $ui.BtnStageAction.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        $ui.BtnStageAction2.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        $last = $script:Services.Ldap.Opened[$script:Services.Ldap.Opened.Count - 1]
        Test-Smoke 'after the confirmation: 389 with Kerberos, the confirmation is in the protocol' ($script:Services.Ldap.Opened.Count -eq $opened + 1 -and $last.Port -eq 389 -and $last.AuthType -eq 'Kerberos' -and @($script:Protocol.Actions | Where-Object { $_.Subject -like 'Domain controller without LDAPS confirmed*' -and $_.Note -like 'Confirmed by *' }).Count -eq 1) ($last | ConvertTo-Json -Compress)
        Close-Stage
        $true } }
    @{ Name = 'start: snapshot'; Do = {
        if (-not $script:SnapStarted) {
            Open-Stage 'Snapshot'; $window.UpdateLayout()
            Test-Smoke 'snapshot gate without a snapshot: says so, confirm disabled, create offered' ($ui.TxtStageMessage.Text -like '*No snapshot of the OS disk that is finished*' -and -not $ui.BtnStageAction.IsEnabled -and $ui.BtnStageAction2.Visibility -eq 'Visible' -and (Find-Text $ui.PanelStageBody 'gm-test01') -and (Find-Text $ui.PanelStageBody 'gm-test01_osdisk')) $ui.TxtStageMessage.Text
            Save-SmokeShot '18-start-snapshot-none'
            $ui.BtnStageAction2.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
            $put = $script:Services.Arm.Store.LastPut
            Test-Smoke 'Create snapshot now: incremental request with image version and user tags, the button waits' ($put.properties.incremental -eq $true -and $put.tags.ImageVersion -eq (Get-AVDTuneState $script:StateRoot).ImageVersion -and $put.tags.CreatedWith -eq 'AVDTune' -and $script:PendingSnapshot -and -not $ui.BtnStageAction2.IsEnabled) ($put | ConvertTo-Json -Compress -Depth 4)
            Test-Smoke 'the snapshot is named by the default pattern <OS disk>-DD.MM.YYYY-N' ($script:PendingSnapshot.Name -match '^gm-test01_osdisk-\d{2}\.\d{2}\.\d{4}-1$') $script:PendingSnapshot.Name
            Save-SmokeShot '19-start-snapshot-creating'
            $script:SnapStarted = $true
            return $false
        }
        if ($script:PendingSnapshot) { return $false }   # the timer polls Azure (fake) until the snapshot is ready
        $window.UpdateLayout()
        Test-Smoke 'when ready the snapshot is listed and can be confirmed' ($ui.BtnStageAction.IsEnabled -and $script:Form.Valid.Count -eq 1 -and $script:Form.Valid[0].ByAVDTune -and $script:Form.SnapList.Visibility -eq 'Visible') $ui.TxtStageMessage.Text
        Save-SmokeShot '20-start-snapshot-ready'
        $script:Form.NameBox.Text = 'Alex'
        $ui.BtnStageAction.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Test-Smoke 'one word is no first and last name: the gate stays closed' (-not (Test-AVDTuneWriteAllowed) -and $ui.TxtStageMessage.Text -like '*first and last name*') $ui.TxtStageMessage.Text
        $script:Form.NameBox.Text = 'A. E.'
        $ui.BtnStageAction.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Test-Smoke 'initials only do not open the gate' (-not (Test-AVDTuneWriteAllowed) -and $ui.TxtStageMessage.Text -like '*first and last name*') $ui.TxtStageMessage.Text
        $script:Form.NameBox.Text = 'Alex Example'
        $ui.BtnStageAction.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        $window.UpdateLayout()
        $state = Get-AVDTuneState $script:StateRoot
        Test-Smoke 'confirmed with the full name: gate open, state.json has the record' ((Test-AVDTuneWriteAllowed) -and $state.SnapshotGate.ConfirmedBy -eq 'Alex Example' -and $state.SnapshotGate.CreatedByAVDTune -eq $true -and $state.SnapshotGate.SnapshotId -like '*/snapshots/gm-test01_osdisk-*' -and $state.SnapshotGate.SignedInAccount -like 'admin.example@*' -and $state.SnapshotGate.WindowsAccount -like '*\*') ($state.SnapshotGate | ConvertTo-Json -Compress)
        $entry = @(Get-AVDTuneChangeLog -Root $script:StateRoot | Where-Object { $_.Category -eq 'Snapshot' })
        Test-Smoke 'the change log has the snapshot entry (name, time, ID, created by AVDTune: yes)' ($entry.Count -eq 1 -and $entry[0].SnapshotId -eq $state.SnapshotGate.SnapshotId -and $entry[0].Text -like '*created by AVDTune: yes*') ($entry | ConvertTo-Json -Compress)
        $act = @($script:Protocol.Actions | Where-Object { $_.Subject -eq 'Snapshot gate confirmed' })
        Test-Smoke 'the protocol has the confirmation with typed name, both accounts, time and whether AVDTune made it' ($act.Count -eq 1 -and $act[0].Note -like '*gm-test01_osdisk-*' -and $act[0].Note -like '*by AVDTune: yes*' -and $act[0].Note -like '*confirmed by Alex Example (Microsoft account admin.example@*, Windows account *') ($act | ConvertTo-Json -Compress)
        Test-Smoke 'all four stages are Done, the rollback hint is on the Overview' ((($script:Stages | ForEach-Object Status) -join ',') -eq 'Done,Done,Done,Done' -and $ui.BoxRollback.Visibility -eq 'Visible' -and $ui.TxtRollback.Text -like '*Swap OS disk*') (($script:Stages | ForEach-Object Status) -join ',')
        Save-SmokeShot '21-start-done'
        Show-Page 'Updates'; $window.UpdateLayout()
        Test-Smoke 'unlocked: no read-only banner on the page any more' ($ui.BoxReadOnly.Visibility -eq 'Collapsed') $null
        Save-SmokeShot '22-page-updates-unlocked'
        Show-Page 'Overview'
        $ok = (Invoke-AVDTuneStep -Step (New-AVDTuneStep -Id 'setup.smoke' -Section Setup -Title 'x' -Test { $true } -Apply { }) -Machine $script:Machine -Mode Apply).Status
        Test-Smoke 'the engine accepts a change after the confirmation' ($ok -eq 'Unchanged') $ok
        $true } }
    @{ Name = 'start: snapshot found before any image version'; Do = {
        # An existing finished snapshot, no image version yet (seen on the test VM, #20): Confirm starts the first version and confirms
        Close-AVDTuneWriteGate
        [void](Set-AVDTuneState -Root $script:StateRoot -Values @{ ImageVersion = ''; Versions = @(); SnapshotGate = $null })
        $store = $script:ReadyFakeArm.Store
        $name = 'gm-test01_osdisk-found-1'
        $id = "/subscriptions/$($script:FakeSubscription)/resourceGroups/$($store.ResourceGroup)/providers/Microsoft.Compute/snapshots/$name"
        $store.Snapshots[$id.ToLowerInvariant()] = @{ id = $id; name = $name; location = $store.Location; tags = @{ CreatedWith = 'Someone else' }
            properties = @{ timeCreated = (Get-Date).AddSeconds(5).ToUniversalTime().ToString('o'); provisioningState = 'Succeeded'; incremental = $true
                creationData = @{ createOption = 'Copy'; sourceResourceId = $store.DiskId } } }
        $script:ConfirmAsked = ''
        Open-Stage 'Snapshot'; $window.UpdateLayout()
        Test-Smoke 'a finished snapshot and no image version: it is listed and can be confirmed' ($script:Form.Valid.Count -ge 1 -and $ui.BtnStageAction.IsEnabled -and -not $script:Form.ImageVersion -and -not (Test-AVDTuneWriteAllowed)) $ui.TxtStageMessage.Text
        $script:Form.NameBox.Text = 'Alex Example'
        $ui.BtnStageAction.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        $window.UpdateLayout()
        $state = Get-AVDTuneState $script:StateRoot
        $expected = (Get-Date).ToString('yyyy.MM') + '.001'
        Test-Smoke 'Confirm asks for the first image version, starts it and confirms the snapshot in it (no ImageVersion binding error)' ($script:ConfirmAsked -like "Start image version $expected*" -and $state.ImageVersion -eq $expected -and (Test-AVDTuneWriteAllowed) -and $state.SnapshotGate.SnapshotName -like 'gm-test01_osdisk-*' -and $script:OpenStage -ne 'Snapshot') "asked='$script:ConfirmAsked' version=$($state.ImageVersion) gate=$($state.SnapshotGate | ConvertTo-Json -Compress) msg=$($ui.TxtStageMessage.Text)"
        $true } }
    @{ Name = 'updates page'; Do = {
        # the page is read only until the gate is open (it is open here: the start sequence ran). Search runs in a background runspace with the fake adapter.
        if (-not $script:UpdStep) {
            $script:UpdStep = 1
            $script:Machine.Store.Registry['hklm:\software\fslogix\apps|installversion'] = '2.9.8884.27471'
            $script:Machine.Store.Registry['hklm:\software\wow6432node\microsoft\edgeupdate\clients\{56eb18f8-b008-4cbd-b6d2-8c97fe7e9062}|pv'] = '130.0.1'
            $script:Machine.Store.Registry['hklm:\softwareslogixpps|installversion'] = '2.9.8884.27471'
            $script:Machine.Store.Registry['hklm:\software\wow6432node\microsoft\edgeupdate\clients\{56eb18f8-b008-4cbd-b6d2-8c97fe7e9062}|pv'] = '130.0.1'
            Show-Page 'Updates'; $window.UpdateLayout()
            Test-Smoke 'Updates page: own page (no placeholder), buttons, empty list hint' ($ui.PageUpdates.Visibility -eq 'Visible' -and $ui.PagePlaceholder.Visibility -eq 'Collapsed' -and $ui.TxtUpdState.Text -like 'Nothing searched*') $ui.TxtUpdState.Text
            $ui.BtnUpdScan.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
            # closing while an operation runs would end the process before the maintenance mode restores the block: the window stays open
            $window.Close()
            Test-Smoke 'closing during an update operation is refused with a hint, the window closes after it' ($window.IsVisible -and $script:UpdJob -and $script:CloseWhenDone -and $script:LastToast -like '*closes by itself when it is done*') $script:LastToast
            $script:CloseWhenDone = $false   # the smoke goes on
            $sessionEnd = [pscustomobject]@{ Cancel = $false }
            Invoke-SessionEnding $sessionEnd
            Test-Smoke 'log off or shut down during an update operation is held back, Windows shows the reason' ($sessionEnd.Cancel -and (Get-ShutdownBlockReason) -like 'AVDTune runs an operation*') (Get-ShutdownBlockReason)
            return $false
        }
        if ($script:UpdJob) { return $false }
        $sessionIdle = [pscustomobject]@{ Cancel = $false }; Invoke-SessionEnding $sessionIdle
        Test-Smoke 'after the operation log off is not held back and the reason is gone' (-not $sessionIdle.Cancel -and -not (Get-ShutdownBlockReason)) (Get-ShutdownBlockReason)
        $window.UpdateLayout()
        $ids = @($script:UpdItems | ForEach-Object Id)
        Test-Smoke 'search: Windows (driver excluded), M365, Edge, Teams, OneDrive, FSLogix detect-only, Defender, winget and choco apps' ($ids -contains 'windows:u1' -and (@($script:UpdItems | Where-Object Id -eq 'windows:u3')[0].Status -eq 'Excluded') -and $ids -contains 'm365' -and $ids -contains 'edge' -and $ids -contains 'teams' -and $ids -contains 'onedrive' -and (@($script:UpdItems | Where-Object Id -eq 'fslogix')[0].Status -eq 'DetectOnly') -and $ids -contains 'defender' -and $ids -contains 'winget:7zip.7zip' -and $ids -contains 'choco:git') (@($script:UpdItems | ForEach-Object { "$($_.Id)=$($_.Status)" }) -join ',')
        Test-Smoke 'list shows group headings, rows and the Microsoft Update note' ((Find-Text $ui.PanelUpdItems 'Windows') -and (Find-Text $ui.PanelUpdItems 'Software') -and $ui.PanelUpdItems.Children.Count -ge 12 -and $ui.TxtUpdNotes.Text -like '*Microsoft Update*') $ui.PanelUpdItems.Children.Count
        Save-SmokeShot '30-updates-list'
        $true } }
    @{ Name = 'updates run'; Do = {
        if ($script:OverviewJob -or $script:ReadyJob) { return $false }   # the fake machine is not thread safe: never change it while the overview job reads it
        if (-not $script:UpdRunStep) {
            $script:UpdRunStep = 1
            [void](Set-AVDTuneUpdateBlock -Machine $script:Machine -Root $script:StateRoot -Mode On -User 'smoke')
            $script:UpdChecked['windows:u1'] = $true
            $ui.BtnUpdSelected.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
            Test-Smoke 'update selected: the confirmation says the block is lifted for the run' ($script:ConfirmAsked -like '*update block is lifted*') $script:ConfirmAsked
            return $false
        }
        if ($script:UpdJob) { return $false }   # the run, then the new search
        $window.UpdateLayout()
        $state = Get-AVDTuneState $script:StateRoot
        Test-Smoke 'run done: LastUpdate set, block restored (record closed), history has rows' ($state.LastUpdate -and $state.Maintenance.Phase -eq 'restored' -and -not (Get-AVDTuneMaintenanceCrash -Root $script:StateRoot) -and $ui.PanelUpdHistory.Children.Count -ge 1) "$($state.Maintenance.Phase) / $($ui.TxtUpdState.Text)"
        Test-Smoke 'the run is in the protocol and the change log' (@($script:Protocol.Actions | Where-Object { $_.Category -eq 'update' }).Count -ge 1 -and @(Get-AVDTuneChangeLog -Root $script:StateRoot | Where-Object { $_.ChangeType -eq 'Updated' }).Count -ge 1) $null
        Save-SmokeShot '31-updates-history'
        $script:UpdLastRun = [pscustomobject]@{ Results = @([pscustomobject]@{ Status = 'Failed'; Repair = $true; Id = 'x' }) }
        Update-UpdatesView; $window.UpdateLayout()
        Test-Smoke 'a failed update with a repairable cause offers DISM and sfc' ($ui.BoxUpdRepair.Visibility -eq 'Visible') $null
        Save-SmokeShot '32-updates-repair-offer'
        $script:UpdLastRun = $null; Update-UpdatesView
        $true } }
    @{ Name = 'benchmark page'; Do = {
        if ($script:OverviewJob -or $script:ReadyJob) { return $false }
        if (-not $script:BenchStep) {
            $script:BenchStep = 1
            Show-Page 'Benchmark'; $window.UpdateLayout()
            Test-Smoke 'Benchmark page: no result yet, both start buttons there, no placeholder' ($ui.PageBenchmark.Visibility -eq 'Visible' -and $ui.PagePlaceholder.Visibility -eq 'Collapsed' -and $ui.TxtBenchScore.Text -like 'No benchmark yet*' -and $ui.BtnBenchFull.IsEnabled -and $ui.BtnBenchQuick.IsEnabled) $ui.TxtBenchScore.Text
            $ui.BtnBenchQuick.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
            Test-Smoke 'quick run: asks first, runs in the background, buttons locked meanwhile' ($script:ConfirmAsked -like '*quick benchmark*' -and $script:BenchJob -and -not $ui.BtnBenchFull.IsEnabled) $script:ConfirmAsked
            $window.Close()
            Test-Smoke 'closing during a benchmark is refused with a hint' ($window.IsVisible -and $script:BenchJob -and $script:CloseWhenDone -and $script:LastToast -like '*benchmark is still running*') $script:LastToast
            $script:CloseWhenDone = $false
            $sessionEnd = [pscustomobject]@{ Cancel = $false }
            Invoke-SessionEnding $sessionEnd
            Test-Smoke 'log off or shut down during a benchmark is held back, Windows shows the general reason' ($sessionEnd.Cancel -and (Get-ShutdownBlockReason) -like 'AVDTune runs an operation*') (Get-ShutdownBlockReason)
            $blocked = $null; try { Start-UpdJob 'Scan' $null } catch { $blocked = $_.Exception.Message }
            Test-Smoke 'an update operation cannot start while the benchmark runs' ($blocked -like '*benchmark is running*') $blocked
            return $false
        }
        if ($script:BenchJob) { return $false }
        $window.UpdateLayout()
        $r = @(Get-AVDTuneBenchmarkResult -Root $script:StateRoot)
        Test-Smoke 'quick run done: result stored, score and five categories shown, provisional note, history row' ($r.Count -eq 1 -and $r[0].mode -eq 'quick' -and $ui.TxtBenchScore.Text -match '^\d+$' -and $ui.PanelBenchCats.Children.Count -eq 5 -and $ui.BoxBenchProvisional.Visibility -eq 'Visible' -and $ui.PanelBenchHistory.Children.Count -eq 1 -and $ui.BtnBenchFull.IsEnabled) "$($r.Count) $($ui.TxtBenchScore.Text) | $($ui.TxtBenchState.Text)"
        Test-Smoke 'the run is in the protocol and the change log, services are back' (@($script:Protocol.Actions | Where-Object { $_.Category -eq 'benchmark' }).Count -ge 1 -and @(Get-AVDTuneChangeLog -Root $script:StateRoot | Where-Object { $_.Category -eq 'Benchmark' }).Count -ge 1) $null
        Save-SmokeShot '35-benchmark'
        $true } }
    @{ Name = 'update block page'; Do = {
        if ($script:OverviewJob -or $script:ReadyJob) { return $false }   # the fake machine is not thread safe: never change it while the overview job reads it
        if (-not $script:BlkStep) {
            $script:BlkStep = 1
            Show-Page 'UpdateBlock'; $window.UpdateLayout()
            Test-Smoke 'Update block page: status Blocked, settings listed by product' ($ui.TxtBlockPill.Text -eq 'Blocked' -and $ui.PanelBlockItems.Children.Count -ge 10 -and (Find-Text $ui.PanelBlockItems 'Edge') -and $ui.BoxBlockCrash.Visibility -eq 'Collapsed') $ui.TxtBlockPill.Text
            Save-SmokeShot '33-update-block-on'
            & $script:Machine.RegRemove 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'NoAutoUpdate'
            Update-UpdateBlockView; $window.UpdateLayout()
            Test-Smoke 'reset from outside: status Partly and the missing group is named' ($ui.TxtBlockPill.Text -eq 'Partly' -and $ui.TxtBlockSummary.Text -like '*Missing: Windows*') $ui.TxtBlockSummary.Text
            Save-SmokeShot '34-update-block-partial'
            $ui.BtnBlockOn.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
            return $false
        }
        if ($script:UpdJob) { return $false }
        if ($script:BlkStep -eq 1) {
            $script:BlkStep = 2
            Test-Smoke 'switch on again from the page: back to Blocked' ($ui.TxtBlockPill.Text -eq 'Blocked') $ui.TxtBlockPill.Text
            $null = Start-AVDTuneMaintenance -Machine $script:Machine -Root $script:StateRoot -User 'smoke'
            Update-UpdateBlockView; $window.UpdateLayout()
            Test-Smoke 'interrupted maintenance mode: the page says so and offers the repair' ($ui.BoxBlockCrash.Visibility -eq 'Visible' -and $ui.TxtBlockPill.Text -eq 'Interrupted' -and $ui.TxtBlockCrash.Text -like '*did not end properly*') $ui.TxtBlockPill.Text
            Save-SmokeShot '35-update-block-crash'
            $ui.BtnBlockRepair.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
            return $false
        }
        Test-Smoke 'repair from the page: block back, no record Active, change log entry' ($ui.TxtBlockPill.Text -eq 'Blocked' -and -not (Get-AVDTuneMaintenanceCrash -Root $script:StateRoot) -and @(Get-AVDTuneChangeLog -Root $script:StateRoot | Where-Object { $_.Text -like '*did not end properly*' }).Count -eq 1) $ui.TxtBlockPill.Text
        $true } }
    @{ Name = 'watermark page'; Do = {
        if ($script:OverviewJob -or $script:ReadyJob) { return $false }   # the fake machine is not thread safe
        $click = { param($b) $b.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) }
        $keepName = & $script:Machine.ComputerName
        Show-Page 'UserExperience'; $window.UpdateLayout()
        Test-Smoke 'User experience page: own page, not installed, defaults in the form, name preview says no for this host' ($ui.PageUserExperience.Visibility -eq 'Visible' -and $ui.PagePlaceholder.Visibility -eq 'Collapsed' -and $ui.TxtWmPill.Text -eq 'Not installed' -and $ui.TxtWmPattern.Text -eq '^avd-pilot-' -and $ui.TxtWmText.Text -eq 'PILOTUMGEBUNG' -and $ui.TxtWmMatch.Text -like '*would show the watermark: no*') "$($ui.TxtWmPill.Text) / $($ui.TxtWmMatch.Text)"
        $ui.TxtWmTryName.Text = 'avd-pilot-04'; $window.UpdateLayout()
        Test-Smoke 'a name to try: the preview says yes for it' ($ui.TxtWmMatch.Text -like "*'avd-pilot-04': yes*") $ui.TxtWmMatch.Text
        $ui.TxtWmPattern.Text = '('; $window.UpdateLayout()
        Test-Smoke 'an invalid pattern: the reason is shown and Save is off' ($ui.TxtWmErrors.Text -like '*regular expression*' -and -not $ui.BtnWmSave.IsEnabled -and $ui.TxtWmMatch.Text -like 'Not a valid*') $ui.TxtWmErrors.Text
        $ui.TxtWmPattern.Text = '^avd-pilot-'; $ui.TxtWmOpacity.Text = '5'; $window.UpdateLayout()
        Test-Smoke 'opacity out of range: the reason is shown' ($ui.TxtWmErrors.Text -like '*opacity*10 to 100*') $ui.TxtWmErrors.Text
        $ui.TxtWmOpacity.Text = '60'
        $ui.CmbWmCorner.SelectedItem = 'TopLeft'; $window.UpdateLayout()
        $left = [System.Windows.Controls.Canvas]::GetLeft($ui.TxtWmPreview); $top = [System.Windows.Controls.Canvas]::GetTop($ui.TxtWmPreview)
        Test-Smoke 'preview: the label moves to the chosen corner (top left, 16 px at 30 percent)' ($left -eq 8 -and $top -eq 8 -and $ui.TxtWmErrors.Text -eq '') "$left,$top"
        $ui.CmbWmCorner.SelectedItem = 'BottomRight'; $ui.TxtWmColor.Text = '#C62828'; $window.UpdateLayout()
        $left = [System.Windows.Controls.Canvas]::GetLeft($ui.TxtWmPreview); $top = [System.Windows.Controls.Canvas]::GetTop($ui.TxtWmPreview)
        Test-Smoke 'preview: bottom right sits inside the work area above the taskbar strip' (($left + $ui.TxtWmPreview.DesiredSize.Width) -le 480 -and ($top + $ui.TxtWmPreview.DesiredSize.Height) -le (270 - 20) -and $left -gt 240 -and $top -gt 130) "$left,$top"
        & $click $ui.BtnWmSave
        $saved = Read-AVDTuneJson (Join-Path $script:StateRoot 'config\watermark.json')
        Test-Smoke 'Save writes config\watermark.json of the state folder' ($saved.Color -eq '#C62828' -and $saved.Corner -eq 'BottomRight') $null
        $script:Machine.Store.ComputerName = 'AVD-PILOT-02'
        Update-WatermarkView; $ui.TxtWmTryName.Text = 'AVD-PILOT-02'; $window.UpdateLayout()
        Test-Smoke 'a host that matches: the page says the watermark would appear here' ($ui.TxtWmHost.Text -like '*would appear here: yes*') $ui.TxtWmHost.Text
        # an old overlay on the master
        $script:Machine.Store.Tasks['\pilotoverlay'] = [pscustomobject]@{ Path = '\'; Name = 'PilotOverlay'; Enabled = $true; Xml = '<Task xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"><Triggers><LogonTrigger/></Triggers><Principals><Principal><GroupId>S-1-5-32-545</GroupId></Principal></Principals><Actions><Exec><Command>wscript.exe</Command><Arguments>x</Arguments></Exec></Actions></Task>' }
        & $script:Machine.FileWrite 'X:\Fake\ProgramData\PilotOverlayLauncher.vbs' 'old' 'Admin'
        Update-WatermarkView; $window.UpdateLayout()
        Test-Smoke 'old overlay found: warning card with the task and the launcher, items marked Found' ($ui.BoxWmLegacy.Visibility -eq 'Visible' -and $ui.TxtWmLegacy.Text -like '*PilotOverlay*PilotOverlayLauncher.vbs*' -and (Find-Text $ui.PanelWmItems 'Found')) $ui.TxtWmLegacy.Text
        Save-SmokeShot '40-watermark-settings'
        $script:ConfirmAsked = ''
        & $click $ui.BtnWmInstall
        $st = Get-AVDTuneWatermarkStatus -Machine $script:Machine -Root $script:StateRoot -SourceRoot $script:WmSourceRoot
        Test-Smoke 'Install asks first, then installs: pill Installed, task and files on the (fake) master, old overlay untouched' ($script:ConfirmAsked -like 'Install the watermark*old overlay is not touched*' -and $ui.TxtWmPill.Text -eq 'Installed' -and $st.State -eq 'Installed' -and $st.Legacy.Present) "$($ui.TxtWmPill.Text) / $script:ConfirmAsked"
        Test-Smoke 'Install: change log entry and state' (@(Get-AVDTuneChangeLog -Root $script:StateRoot | Where-Object { $_.Component -eq 'Watermark' -and $_.ChangeType -eq 'Added' }).Count -eq 1 -and (Get-AVDTuneProp (Get-AVDTuneState $script:StateRoot) 'Watermark') -eq 'Installed') $null
        Test-Smoke 'nothing under C:\ProgramData\AVDTune was written by the fake machine' (-not (@($script:Machine.Log | Where-Object { $_ -match 'ProgramData\\AVDTune[\\ ]' }).Count)) $null
        $script:ConfirmAsked = ''
        & $click $ui.BtnWmLegacy
        Test-Smoke 'Remove the old overlay asks first and removes task and launcher' ($script:ConfirmAsked -like 'Remove the old overlay*' -and $ui.BoxWmLegacy.Visibility -eq 'Collapsed' -and -not (& $script:Machine.TaskDetail '\' 'PilotOverlay')) $script:ConfirmAsked
        Save-SmokeShot '41-watermark-installed'
        $script:ConfirmAsked = ''
        & $click $ui.BtnWmRemove
        Test-Smoke 'Remove asks first and takes everything away again' ($script:ConfirmAsked -like 'Remove the watermark*' -and $ui.TxtWmPill.Text -eq 'Not installed' -and -not (& $script:Machine.TaskDetail '\' 'AVDTune Watermark')) $ui.TxtWmPill.Text
        $script:Machine.Store.ComputerName = $keepName
        Show-Page 'Overview'
        $true } }
    @{ Name = 'overview shows the block'; Do = {
        if (-not $script:OvStep) { $script:OvStep = 1; Show-Page 'Overview'; Start-OverviewRefresh; return $false }
        if ($script:OverviewJob) { return $false }
        $window.UpdateLayout()
        $h = @($script:Overview.Health | Where-Object { $_.Id -eq 'updateblock' })[0]
        Test-Smoke 'Overview health: Update block for users is ok with the number of settings' ($h.Status -eq 'ok' -and $h.Detail -like 'On: *settings*' -and (Find-Text $ui.PanelHealth 'Update block for users')) $h.Detail
        Save-SmokeShot '36-overview-block'
        $true } }
    @{ Name = 'readiness: first analysis'; Do = {
        if ($script:OverviewJob -or $script:ReadyJob -or $script:ReadyQueued -or $script:UpdJob) { return $false }   # the fake machine is not thread safe
        $defId = '/subscriptions/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/resourceGroups/rg-example/providers/Microsoft.Compute/galleries/gal1/images/def1'
        $script:ReadyFakeArm.Store.Galleries['def1'] = @{ Features = @(@{ name = 'SecurityType'; value = 'TrustedLaunchSupported' }); Architecture = 'x64'; HyperV = 'V2' }
        $script:ReadyFakeArm.Store.VmSeed['DiskControllerType'] = 'SCSI'
        $reg = $script:Machine.Store.Registry
        $reg['hklm:\system\currentcontrolset\services\stornvme|start'] = 3
        $reg['hklm:\system\currentcontrolset\control\session manager\memory management|pagingfiles'] = @('D:\pagefile.sys 0 0')
        $script:Machine.Store.Native['sc.exe config stornvme start=boot'] = @{ ExitCode = 0; Output = '[SC] ChangeServiceConfig SUCCESS'; Registry = @{ 'HKLM:\SYSTEM\CurrentControlSet\Services\stornvme|Start' = 0 } }
        Write-AVDTuneFile $script:ReadySettingsPath ([ordered]@{ GalleryImageId = $defId } | ConvertTo-Json)
        Show-Page 'Overview'
        $script:ReadyKindUsed = Get-ReadyKind
        $script:ReadyWritesBefore = @($script:Machine.Log | Where-Object { $_ -notlike 'Run *' }).Count; $script:ReadyArmBefore = $script:ReadyFakeArm.Log.Count
        $ui.BtnReadyRun.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Test-Smoke 'Run analysis: the pill says Running and the button waits' ($script:ReadyJob -and -not $ui.BtnReadyRun.IsEnabled -and $ui.TxtReadyPill.Text -eq 'Running') $ui.TxtReadyPill.Text
        $true } }
    @{ Name = 'readiness: first result'; Do = {
        if ($script:ReadyJob -or $script:ReadyQueued) { return $false }
        Show-Page 'Overview'; $window.UpdateLayout()
        $r = $script:Ready
        $state = Get-AVDTuneState $script:StateRoot
        $rows = @{}; foreach ($x in $r.Rows) { $rows[$x.Id] = $x }
        Test-Smoke 'the first analysis is the Erstanalyse and ends red (stornvme, page file on D:, gallery definition without NVMe)' ($script:ReadyKindUsed -eq 'Erstanalyse' -and $r.Overall -eq 'red' -and $rows['hw.stornvme'].Status -eq 'red' -and $rows['hw.pagefile-d'].Status -eq 'red' -and $rows['hw.gallery'].Status -eq 'red') (($r.Rows | Where-Object Status -eq 'red' | ForEach-Object Id) -join ',')
        Test-Smoke 'Azure was read through the sign-in: VM on SCSI is yellow, accelerated networking on is green' ($r.Arm.Ok -and $rows['hw.disk-controller'].Status -eq 'yellow' -and $rows['hw.accelnet'].Status -eq 'green') $r.Arm.Problem
        Test-Smoke 'the card shows the red pill, the counts and the criteria date' ($ui.TxtReadyPill.Text -eq 'Red' -and $ui.TxtReadySummary.Text -like '*red*yellow*not checkable*green*Criteria of 2026-11-15*Azure was read*') $ui.TxtReadySummary.Text
        Test-Smoke 'rows are grouped (Hardware generation, Image hygiene), one row per check' ($ui.PanelReadyRows.Children.Count -ge 28 -and (Find-Text $ui.PanelReadyRows 'Hardware generation') -and (Find-Text $ui.PanelReadyRows 'Image hygiene') -and (Find-Text $ui.PanelReadyRows 'Windows NVMe driver (stornvme) starts at boot')) $ui.PanelReadyRows.Children.Count
        Test-Smoke 'the family list says what is ready, what needs fixes and what is not possible (Arm64)' ($ui.TxtReadyFamilies.Text -like '*After fixing the items above*Ddsv6*Not possible with this master (6): 6 x needs an Arm64 image*') $ui.TxtReadyFamilies.Text
        Test-Smoke 'Finish is locked and says why' ($ui.TxtReadyGate.Text -like 'Finish: locked*red item(s)*') $ui.TxtReadyGate.Text
        $rec = $state.Readiness
        $log = @(Get-AVDTuneChangeLog -Root $script:StateRoot | Where-Object { $_.Category -eq 'Readiness' })
        Test-Smoke 'the result is stored: run record (Erstanalyse), state.json and a change log entry; the start run wrote none' (@(Get-AVDTuneRun -Root $script:StateRoot | Where-Object { $_.PSObject.Properties['Kind'] -and $_.Kind -eq 'Erstanalyse' }).Count -eq 1 -and $rec.Kind -eq 'Erstanalyse' -and $rec.Overall -eq 'red' -and $log.Count -eq 1 -and $log[0].Text -like 'Erstanalyse: overall red*') ($log | ForEach-Object Text)
        Test-Smoke 'nothing in the analysis wrote to the machine or to Azure' (@($script:Machine.Log | Where-Object { $_ -notlike 'Run *' }).Count -eq $script:ReadyWritesBefore -and $script:ReadyFakeArm.Log.Count -gt $script:ReadyArmBefore -and -not (@($script:ReadyFakeArm.Log | Select-Object -Skip $script:ReadyArmBefore | Where-Object { $_ -notlike 'GET *' }))) (($script:Machine.Log | Where-Object { $_ -notlike 'Run *' }) -join '; ')
        $ui.BoxReady.BringIntoView(); $window.UpdateLayout()
        Save-SmokeShot '40-readiness-red-light'
        $ui.BtnReadyMore_hw_stornvme.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        $window.UpdateLayout()
        Test-Smoke 'Details shows what was found, what to do, the Learn source with its date and whether Learn states it' ($ui.TxtReadyDetail_hw_stornvme.Text -like '*Found: 3*What to do:*Source: https://learn.microsoft.com/*(read 2026-11-15)*Learn states this criterion.*') $ui.TxtReadyDetail_hw_stornvme.Text
        $ui.BtnReadyMore_hy_bitlocker.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        $window.UpdateLayout()
        Test-Smoke 'a criterion that Learn does not state says so' ($ui.TxtReadyDetail_hy_bitlocker.Text -like '*NOT verified on Microsoft Learn.*') $ui.TxtReadyDetail_hy_bitlocker.Text
        $ui.BoxReady.BringIntoView(); $window.UpdateLayout()
        Save-SmokeShot '41-readiness-details-light'
        $true } }
    @{ Name = 'readiness: fix'; Do = {
        if ($script:OverviewJob -or $script:ReadyJob -or $script:ReadyQueued) { return $false }
        if (-not $script:ReadyFixStarted) {
            $script:ReadyFixStarted = $true
            Test-Smoke 'a row with a fix offers the button, enabled because the snapshot is confirmed' ($ui.BtnReadyFix_hw_stornvme -and $ui.BtnReadyFix_hw_stornvme.IsEnabled -and -not $ui.BtnReadyFix_hw_pagefile_d) $null
            $script:ConfirmAsked = ''
            $ui.BtnReadyFix_hw_stornvme.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
            Test-Smoke 'Fix asks first and says it takes effect after the next restart' ($script:ConfirmAsked -like '*NVMe driver*next restart*' -and $script:ReadyJob) $script:ConfirmAsked
            return $false
        }
        $window.UpdateLayout()
        $reg = $script:Machine.Store.Registry['hklm:\system\currentcontrolset\services\stornvme|start']
        $entry = @(Get-AVDTuneChangeLog -Root $script:StateRoot | Where-Object { $_.Category -eq 'Readiness fix' })
        Test-Smoke 'the fix ran with the documented command, the value is 0, the change log and the protocol have it' ($reg -eq 0 -and (@($script:Machine.Log | Where-Object { $_ -eq 'Run sc.exe config stornvme start=boot' }).Count -eq 1) -and $entry.Count -eq 1 -and $entry[0].Text -like '*restart needed*' -and @($script:Protocol.Actions | Where-Object { $_.Subject -eq 'Readiness fix' }).Count -eq 1) ($entry | ForEach-Object Text)
        $rows = @{}; foreach ($x in $script:Ready.Rows) { $rows[$x.Id] = $x }
        Test-Smoke 'the analysis ran again by itself: stornvme is green now, the page file is still red' ($rows['hw.stornvme'].Status -eq 'green' -and $rows['hw.pagefile-d'].Status -eq 'red') $rows['hw.stornvme'].Status
        Test-Smoke 'Finish is still locked (red left)' ($ui.TxtReadyGate.Text -like 'Finish: locked*') $ui.TxtReadyGate.Text
        $true } }
    @{ Name = 'readiness: confirm by name'; Do = {
        if ($script:OverviewJob -or $script:ReadyJob -or $script:ReadyQueued) { return $false }
        if (-not $script:ReadyConfStarted) {
            $script:ReadyConfStarted = $true
            $script:Machine.Store.Registry['hklm:\system\currentcontrolset\control\session manager\memory management|pagingfiles'] = @('C:\pagefile.sys 0 0')
            $script:ReadyFakeArm.Store.Galleries['def1'] = @{ Features = @(@{ name = 'DiskControllerTypes'; value = 'SCSI, NVMe' }, @{ name = 'SecurityType'; value = 'TrustedLaunchSupported' }, @{ name = 'IsAcceleratedNetworkSupported'; value = 'True' }); Architecture = 'x64'; HyperV = 'V2' }
            $ui.BtnReadyRun.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
            return $false
        }
        $window.UpdateLayout()
        $r = $script:Ready
        $rec = (Get-AVDTuneState $script:StateRoot).Readiness
        Test-Smoke 'second run is the Healthcheck: nothing red, yellow and not checkable left, overall yellow' ($rec.Kind -eq 'Healthcheck' -and $r.Overall -eq 'yellow' -and $r.Counts.Red -eq 0 -and $r.Counts.Yellow -ge 1 -and $ui.TxtReadyPill.Text -eq 'Yellow') (($r.Rows | Where-Object { $_.Status -in 'red', 'yellow', 'unknown' } | ForEach-Object { "$($_.Id)=$($_.Status)" }) -join ',')
        Test-Smoke 'the confirmation box is there and names the open items; Finish is locked for them' ($ui.PanelReadyAck.Visibility -eq 'Visible' -and $ui.TxtReadyAckHint.Text -like '*hw.disk-controller*' -and $ui.TxtReadyGate.Text -like 'Finish: locked*not confirmed by name*') "$($ui.TxtReadyAckHint.Text) / $($ui.TxtReadyGate.Text)"
        $ui.BoxReady.BringIntoView(); $window.UpdateLayout()
        Save-SmokeShot '42-readiness-yellow-light'
        $ui.TxtReadyAck.Text = 'ok'
        $ui.BtnReadyAck.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Test-Smoke 'a general ok is refused and names what is missing' ($script:LastToast -like '*Type the name of every open item*Missing*' -and $ui.TxtReadyGate.Text -like 'Finish: locked*') $script:LastToast
        $ui.TxtReadyAck.Text = (@($rec.OpenIds) -join ' ')
        $ui.BtnReadyAck.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        $window.UpdateLayout()
        $g = Get-AVDTuneFinishReadiness -Root $script:StateRoot
        Test-Smoke 'every open item named: Finish is allowed, who confirmed it is stored, the protocol and the change log have it' ($g.Allowed -and $ui.TxtReadyGate.Text -like 'Finish: allowed*' -and $ui.PanelReadyAck.Visibility -eq 'Collapsed' -and (Get-AVDTuneState $script:StateRoot).Readiness.AcknowledgedBy -eq $env:USERNAME -and @($script:Protocol.Actions | Where-Object { $_.Subject -like 'Readiness: open items confirmed' }).Count -eq 1 -and @(Get-AVDTuneChangeLog -Root $script:StateRoot | Where-Object Component -eq 'Confirmation').Count -eq 1) $ui.TxtReadyGate.Text
        $wasLight = ($script:Settings.Theme -eq 'Light')
        if ($wasLight) { $ui.BtnTheme.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) }
        $window.UpdateLayout(); $ui.BoxReady.BringIntoView(); $window.UpdateLayout(); $ui.BoxReady.BringIntoView(); $window.UpdateLayout()
        Save-SmokeShot '43-readiness-confirmed-dark'
        if ($wasLight) { $ui.BtnTheme.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) }
        [void](Add-AVDTuneChangeLogEntry -Root $script:StateRoot -Version (Get-AVDTuneState $script:StateRoot).ImageVersion -Category 'Updates' -ChangeType Updated -Text 'smoke change' -User 'smoke' -Source Step)
        Update-ReadyView
        Test-Smoke 'a change after the check locks Finish again' ($ui.TxtReadyGate.Text -like 'Finish: locked*changed after the check*') $ui.TxtReadyGate.Text
        $true } }
    @{ Name = 'readiness: image definition to choose (#16)'; Do = {
        if ($script:OverviewJob -or $script:ReadyJob -or $script:ReadyQueued) { return $false }
        $sub = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
        $avdId = "/subscriptions/$sub/resourceGroups/rg-images/providers/Microsoft.Compute/galleries/galA/images/win11-avd"
        if (-not $script:GalStep) {
            # no saved choice; the galleries hold two Windows Gen2 definitions, no version from this VM yet (Hydra captures later)
            $script:GalStep = 1; $script:GalArmBefore = $script:ReadyFakeArm.Log.Count
            Write-AVDTuneFile $script:ReadySettingsPath ([ordered]@{ GalleryImageId = '' } | ConvertTo-Json)
            $good = @(@{ name = 'DiskControllerTypes'; value = 'SCSI, NVMe' }, @{ name = 'SecurityType'; value = 'TrustedLaunchSupported' }, @{ name = 'IsAcceleratedNetworkSupported'; value = 'True' })
            $script:ReadyFakeArm.Store.Search = @{ Paging = $true; Subscriptions = @(@{ Id = $sub; Name = 'Example subscription' })
                Galleries = @(@{ Sub = $sub; Rg = 'rg-images'; Name = 'galA'; Images = @(@{ Name = 'win11-avd'; Features = $good; Versions = @() }, @{ Name = 'win11-scsi'; Features = @(@{ name = 'DiskControllerTypes'; value = 'SCSI' }) }) }) }
            Show-Page 'Overview'
            $ui.BtnReadyRun.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
            return $false
        }
        if ($script:GalStep -eq 1) {
            $window.UpdateLayout()
            $row = @($script:Ready.Rows | Where-Object Id -eq 'hw.gallery')[0]
            Test-Smoke '#16: no definition known: the row is yellow (not "not checkable") and asks to choose' ($row.Status -eq 'yellow' -and $row.Reason -like '*2 Windows Generation 2 definition(s) fit*choose*') $row.Reason
            Test-Smoke '#16: the card lists the definitions found to click, the fitting one first, no free text' (@($ui.CmbReadyGallery.ItemsSource).Count -eq 2 -and ([string]$ui.CmbReadyGallery.SelectedItem) -like 'galA / win11-avd (NVMe, Trusted Launch*' -and (Get-ReadyGallerySelection) -eq $avdId -and $ui.BtnReadyGallery.IsEnabled -and $ui.TxtReadyGalleryState.Text -like 'Choose the definition*') "$(@($ui.CmbReadyGallery.ItemsSource).Count) / $($ui.CmbReadyGallery.SelectedItem) / $($ui.TxtReadyGalleryState.Text)"
            $ui.BoxReady.BringIntoView(); $window.UpdateLayout(); $ui.TxtReadyGalleryState.BringIntoView(); $window.UpdateLayout()
            $ui.BoxToast.Visibility = 'Collapsed'; Save-SmokeShot '45-readiness-gallery-choose-light'
            $script:GalStep = 2
            $ui.BtnReadyGallery.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
            return $false
        }
        $window.UpdateLayout()
        $row = @($script:Ready.Rows | Where-Object Id -eq 'hw.gallery')[0]
        $envG = Get-AVDTuneEnvironmentGallery (Get-AVDTuneEnvironment $script:StateRoot)
        Test-Smoke '#16: Use saves the choice in environment.json with a change log entry and runs again: green, named as chosen' ($envG -eq $avdId -and $row.Status -eq 'green' -and $row.Reason -like '*galA/win11-avd, chosen*' -and @(Get-AVDTuneChangeLog -Root $script:StateRoot | Where-Object { $_.Text -like 'Image definition for the readiness check*' }).Count -eq 1 -and $ui.BtnReadyGalleryClear.Visibility -eq 'Visible') "$envG / $($row.Status): $($row.Reason)"
        Test-Smoke '#16: the gallery search read only (GET)' ($script:ReadyFakeArm.Log.Count -gt $script:GalArmBefore -and -not @($script:ReadyFakeArm.Log | Select-Object -Skip $script:GalArmBefore | Where-Object { $_ -notlike "GET *" })) $null
        $ui.BoxReady.BringIntoView(); $window.UpdateLayout(); $ui.TxtReadyGalleryState.BringIntoView(); $window.UpdateLayout()
        $ui.BoxToast.Visibility = 'Collapsed'; Save-SmokeShot '46-readiness-gallery-chosen-light'
        $true } }
    @{ Name = 'fslogix: page, settings, groups, redirections, Defender'; Do = {
        if ($script:OverviewJob -or $script:ReadyJob -or $script:ReadyQueued) { return $false }
        $reg = $script:Machine.Store.Registry
        $pk = 'hklm:\software\fslogix\profiles|'
        $reg['hklm:\software\fslogix\apps|installversion'] = '2.9.8884.27471'
        $reg[$pk + 'enabled'] = 1; $reg[$pk + 'vhdlocations'] = @('\\stfake01.file.core.windows.net\profiles'); $reg[$pk + 'volumetype'] = 'vhd'; $reg[$pk + 'lockedretrycount'] = 12; $reg[$pk + 'sizeinmbs'] = 30000
        $reg[$pk + 'lockedretyinterval'] = 5   # a typo, to be found by the test
        $script:Machine.Store.Services['frxsvc'] = [pscustomobject]@{ Name = 'frxsvc'; Status = 'Running'; StartType = 'Automatic' }
        $script:Machine.Store.Native[(Join-Path (Get-AVDTuneSystemFolder System) 'fltmc.exe') + ' filters'] = @{ ExitCode = 0; Output = "Filter Name  Num Instances  Altitude  Frame`r`nfrxdrv  3  135000  0`r`nfrxdrvvt  3  135100  0`r`n" }
        $script:Machine.Store.Native['*frx.exe create-vhd *'] = @{ ExitCode = 0; Output = 'created' }; $script:Machine.Store.Native['*frx.exe begin-edit-profile *'] = @{ ExitCode = 0; Output = 'cookie: 4876' }; $script:Machine.Store.Native['*frx.exe end-edit-profile *'] = @{ ExitCode = 0; Output = 'ok' }
        $script:FslFake.F.Store.Defender = @{ Paths = @('C:\Program Files\FSLogix\Apps\', 'C:\ProgramData\FSLogix\'); Processes = @('frxsvc.exe') }
        Show-Page 'FSLogix'; $window.UpdateLayout()
        Test-Smoke 'FSLogix page: own page (no placeholder), the nav item is checked' ($ui.PageFSLogix.Visibility -eq 'Visible' -and $ui.PagePlaceholder.Visibility -eq 'Collapsed' -and $ui.NavFSLogix.IsChecked) $null
        Test-Smoke 'installation card: installed version, service and drivers' ($ui.TxtFslVersion.Text -like '*2.9.8884.27471*frxsvc Running*frxdrv*' -and $ui.TxtFslInstallPill.Text -eq 'Installed') $ui.TxtFslVersion.Text
        Test-Smoke 'settings: every setting of the plan as a row with its recommendation and reason, differing values marked' ($script:FslInputs.Count -ge 19 -and (Find-Text $ui.PanelFslSettings 'LockedRetryCount') -and (Find-Text $ui.PanelFslSettings 'Differs') -and (Find-Text $ui.PanelFslSettings 'Office container (ODFC), optional')) $script:FslInputs.Count
        Save-SmokeShot '50-fslogix-top-light'
        # fill in the recommendation, dry run first, then write behind the gate
        $ui.BtnFslFill.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        $ui.BtnFslSettingsTest.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Test-Smoke 'Test: shows what would change and writes nothing' ($ui.TxtFslSettingsState.Text -like 'Test (nothing written)*lockedretrycount*' -and (& $script:Machine.RegGet 'HKLM:\SOFTWARE\FSLogix\Profiles' 'LockedRetryCount') -eq 12 -and @(Get-AVDTuneRun -Root $script:StateRoot | Where-Object Plan -like 'FSLogix*').Count -eq 0) $ui.TxtFslSettingsState.Text
        $ui.BtnFslSettingsApply.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Test-Smoke 'Apply: the confirmation names the count, the registry has the recommended values, LastChange shown, change log written' ($script:ConfirmAsked -like 'Write * FSLogix setting*' -and (& $script:Machine.RegGet 'HKLM:\SOFTWARE\FSLogix\Profiles' 'LockedRetryCount') -eq 3 -and (& $script:Machine.RegGet 'HKLM:\SOFTWARE\FSLogix\Profiles' 'VolumeType') -eq 'vhdx' -and $ui.TxtFslSettingsState.Text -like 'LastChange:*' -and @(Get-AVDTuneChangeLog -Root $script:StateRoot | Where-Object Category -eq 'FSLogix').Count -ge 3) "$($script:ConfirmAsked) / $($ui.TxtFslSettingsState.Text)"
        Test-Smoke 'the change is in the protocol (category FSLogix)' (@($script:Protocol.Actions | Where-Object { $_.Category -eq 'fslogix' }).Count -ge 1) $null
        $ui.BtnFslSettingsUndo.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Test-Smoke 'Undo: the previous values are back' ((& $script:Machine.RegGet 'HKLM:\SOFTWARE\FSLogix\Profiles' 'LockedRetryCount') -eq 12 -and (& $script:Machine.RegGet 'HKLM:\SOFTWARE\FSLogix\Profiles' 'VolumeType') -eq 'vhd') $null
        $ui.BtnFslFill.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        $ui.BtnFslSettingsApply.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        # groups
        $ui.CmbFslList.SelectedItem = 'Exclude'
        $ui.BtnFslExcludeAdmins.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Test-Smoke 'groups: the local Administrators are in the exclude list; the groups of the domain controller are offered' ($script:FslFake.F.Store.Groups['FSLogix Profile Exclude List'] -contains 'S-1-5-32-544' -and $ui.TxtFslGroups.Text -like '*S-1-5-32-544*' -and @($ui.CmbFslGroup.ItemsSource) -contains 'AVD-Users') $ui.TxtFslGroupHint.Text
        $ui.CmbFslGroup.Text = 'not-a-group'
        $ui.BtnFslGroupAdd.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Test-Smoke 'a name that is no group and no SID is refused with the reason' ($script:LastToast -like '*neither a group of the domain nor a SID*') $script:LastToast
        # redirections.xml
        $ui.TxtFslRedirFolder.Text = '\\stfake01.file.core.windows.net\profiles'
        $ui.BtnFslRedirGenerate.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        $ui.BtnFslRedirValidate.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Test-Smoke 'redirections.xml: generated from the template (Teams ticked), valid' ($ui.TxtFslRedirXml.Text -like '*MSTeams_8wekyb3d8bbwe*' -and $ui.TxtFslRedirState.Text -like 'Valid:*') $ui.TxtFslRedirState.Text
        $good = $ui.TxtFslRedirXml.Text
        $ui.TxtFslRedirXml.Text = $good.Replace('</Excludes>', '<Exclude Copy="0">AppData\Local\Microsoft\TokenBroker\Cache</Exclude></Excludes>')
        $ui.BtnFslRedirValidate.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Test-Smoke 'the token broker is refused with the single sign-on reason' ($ui.TxtFslRedirState.Text -like 'Not valid:*single sign-on*') $ui.TxtFslRedirState.Text
        $ui.BtnFslRedirSave.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Test-Smoke 'saving that text is refused, nothing is written' ($script:LastToast -like '*not valid*' -and -not $script:FslFake.F.Store.Files.ContainsKey('\\stfake01.file.core.windows.net\profiles\redirections.xml')) $script:LastToast
        $ui.TxtFslRedirXml.Text = $good
        $ui.BtnFslRedirSave.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Test-Smoke 'redirections.xml saved to the folder, the folder is in the registry' ($script:FslFake.F.Store.Files['\\stfake01.file.core.windows.net\profiles\redirections.xml'] -ceq $good -and (& $script:Machine.RegGet 'HKLM:\SOFTWARE\FSLogix\Profiles' 'RedirXMLSourceFolder') -eq '\\stfake01.file.core.windows.net\profiles') $null
        # Defender
        $ui.BtnFslDefAdd.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Test-Smoke 'Defender: the missing exclusions are added, the list says all are set' ($ui.TxtFslDefState.Text -like '* of * exclusions are set.*' -and @((Get-AVDTuneFSLogixDefenderState -F $script:FslFake.F -VhdLocations @('\\stfake01.file.core.windows.net\profiles')).Items | Where-Object { -not $_.Present }).Count -eq 0 -and $script:FslFake.F.Store.Defender.Processes -contains 'frxccds.exe') $ui.TxtFslDefState.Text
        Show-Page 'FSLogix'; $window.UpdateLayout()
        $sv = $ui.PageFSLogix.Children[0]
        $sv.ScrollToVerticalOffset(1100); $window.UpdateLayout(); Save-SmokeShot '51-fslogix-groups-redirections-light'
        $sv.ScrollToVerticalOffset(2400); $window.UpdateLayout(); Save-SmokeShot '52-fslogix-defender-light'
        $sv.ScrollToVerticalOffset(0)
        $true } }
    @{ Name = 'fslogix: function test'; Do = {
        if ($script:OverviewJob -or $script:ReadyJob -or $script:ReadyQueued -or $script:FslJob) { return $false }
        if (-not $script:FslTestStep) {
            $script:FslTestStep = 1
            $script:FslFake.F.Store.Acl = @{ '\\stfake01.file.core.windows.net\profiles' = 'O:BAG:DUD:PAI(A;OICI;FA;;;WD)(A;OICI;FA;;;BA)' }
            $ui.BtnFslTest.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
            return $false
        }
        $window.UpdateLayout()
        $r = $script:FslTest
        Test-Smoke 'function test ran: result stored in the state, run record, change log note' ($r -and (Get-AVDTuneState $script:StateRoot).FSLogixTest.Overall -eq $r.Overall -and @(Get-AVDTuneRun -Root $script:StateRoot | Where-Object Plan -eq 'FSLogix-Test').Count -eq 1 -and @(Get-AVDTuneChangeLog -Root $script:StateRoot | Where-Object Component -eq 'FSLogix-Test').Count -eq 1) $null
        Test-Smoke 'the typo in the registry is found (yellow); the write tests did not run (info); the real sign-in is info' ((@($r.Rows | Where-Object Id -eq 'fs.registry')[0].Status -eq 'yellow') -and (@($r.Rows | Where-Object Id -eq 'fs.loc1.rw')[0].Status -eq 'info') -and (@($r.Rows | Where-Object Id -eq 'fs.logon')[0].Status -eq 'info') -and @($script:FslFake.F.Log | Where-Object { $_ -like 'ShareWriteTest*' }).Count -eq 0) ((@($r.Rows | Where-Object Id -eq 'fs.registry')[0].Reason))
        Test-Smoke 'the card shows the pill, the counts and one row per check' ($ui.TxtFslTestSummary.Text -like '*without the write tests*' -and $ui.PanelFslTest.Children.Count -eq @($r.Rows).Count) "$($ui.TxtFslTestPill.Text) $($ui.PanelFslTest.Children.Count)"
        Test-Smoke 'the healthcheck follows: the readiness analysis has the FSLogix-Test row' ($script:Ready -and @($script:Ready.Rows | Where-Object Id -eq 'hy.fslogix-test').Count -eq 1) $null
        $sv = $ui.PageFSLogix.Children[0]; Show-Page 'FSLogix'; $window.UpdateLayout()
        $sv.ScrollToVerticalOffset(3000); $window.UpdateLayout(); Save-SmokeShot '53-fslogix-test-light'
        $script:ConfirmAsked = ''
        $ui.BtnFslTestWrite.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Test-Smoke 'the write tests ask first and say what they create' ($script:ConfirmAsked -like '*test folder*VHDX*') $script:ConfirmAsked
        $script:FslTestStep = 2
        $true } }
    @{ Name = 'fslogix: write tests and a red result'; Do = {
        if ($script:OverviewJob -or $script:ReadyJob -or $script:ReadyQueued -or $script:FslJob) { return $false }
        if ($script:FslTestStep -eq 2) {
            $script:FslTestStep = 3
            $r = $script:FslTest
            Test-Smoke 'write tests: folder test and the frx VHDX test ran (create, attach, detach)' ($r.WriteTests -and @($script:FslFake.F.Log | Where-Object { $_ -like 'ShareWriteTest*' }).Count -eq 1 -and @($script:Machine.Log | Where-Object { $_ -like '*frx.exe end-edit-profile -cookie 4876*' }).Count -ge 1) $null
            $script:FslFake.F.Store.Dns = @{ 'stfake01.file.core.windows.net' = @{ Ok = $false; Addresses = @(); Error = 'No such host is known' } }
            $ui.BtnFslTest.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
            return $false
        }
        $window.UpdateLayout()
        $r = $script:FslTest
        $dns = @($r.Rows | Where-Object Id -eq 'fs.loc1.dns')[0]
        Test-Smoke 'DNS does not resolve (private DNS missing): red with the privatelink fix; the test is red' ($dns.Status -eq 'red' -and $dns.Fix -like '*privatelink*' -and $r.Overall -eq 'red') $r.Overall
        Test-Smoke 'the readiness row is red and Finish is blocked by it' (@($script:Ready.Rows | Where-Object Id -eq 'hy.fslogix-test')[0].Status -eq 'red' -and $script:Ready.RedIds -contains 'hy.fslogix-test') $null
        $ui.BoxReady.BringIntoView(); Show-Page 'Overview'; $window.UpdateLayout(); $ui.BoxReady.BringIntoView(); $window.UpdateLayout()
        Save-SmokeShot '54-overview-fslogix-red-light'
        $script:FslFake.F.Store.Dns = @{}
        $true } }
    @{ Name = 'fslogix: storage check'; Do = {
        if ($script:OverviewJob -or $script:ReadyJob -or $script:ReadyQueued -or $script:FslJob) { return $false }
        if (-not $script:FslStorageStep) {
            $script:FslStorageStep = 1
            $ad = @{ domainName = 'example.test'; netBiosDomainName = 'EXAMPLE'; forestName = 'example.test'; domainGuid = '11111111-2222-3333-4444-555555555555'; domainSid = 'S-1-5-21-1-2-3'; azureStorageSid = 'S-1-5-21-1-2-3-1500'; samAccountName = 'stfake01'; accountType = 'Computer' }
            $script:FslFake.Arm.Store.Accounts = @(@{ Name = 'stfake01'; Rg = 'rg-example'; Kind = 'FileStorage'; Sku = 'Premium_LRS'
                    Props = @{ azureFilesIdentityBasedAuthentication = @{ directoryServiceOptions = 'AD'; defaultSharePermission = 'StorageFileDataSmbShareContributor'; activeDirectoryProperties = $ad }; privateEndpointConnections = @(@{ id = 'pe1' }); publicNetworkAccess = 'Disabled' }
                    FileService = @{ versions = 'SMB3.1.1'; authenticationMethods = 'Kerberos'; kerberosTicketEncryption = 'RC4-HMAC;AES-256'; channelEncryption = 'AES-256-GCM' } })
            $script:FslFake.Ldap.Store.Account = @{ Sam = 'stfake01'; Sid = 'S-1-5-21-1-2-3-1500'; Spns = @('cifs/stfake01.file.core.windows.net'); PwdLastSet = (Get-Date).AddDays(-35); Uac = 4096; EncTypes = $null }
            $script:FslFake.Files.Store.Acls = @{ '' = 'O:BAG:DUD:PAI(A;OICI;FA;;;WD)(A;OICI;FA;;;BA)' }; $script:FslFake.Files.Store.Folders = @()
            $ui.CmbFslUsersGroup.Text = 'AVD-Users'; $ui.CmbFslAdminsGroup.Text = 'AVD-Admins'; $ui.TxtFslDc.Text = '10.0.0.10'; $ui.TxtFslUser.Text = 'EXAMPLE\test.user'; $ui.PwdFslPassword.Password = 'smoke-test-password-1'
            $ui.BtnFslStorage.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
            return $false
        }
        $window.UpdateLayout()
        $r = $script:FslStorage
        $by = @{}; foreach ($x in $r.Rows) { $by[$x.Id] = $x }
        Test-Smoke 'storage check ran with the fake Azure: account found, identity AD, only GET against ARM' ($r -and $by['st.account'].Status -eq 'green' -and $by['st.identity'].Status -eq 'green' -and @($script:FslFake.Arm.Log | Where-Object { $_ -notlike 'GET *' }).Count -eq 0) (@($r.Rows | ForEach-Object { "$($_.Id)=$($_.Status)" }) -join ' ')
        Test-Smoke 'password of the AD object almost expired (7 days): yellow with the rotation hint; RC4 allowed too: yellow; the ACL deviates: red with the diff offered' ($by['st.ad.password'].Status -eq 'yellow' -and $by['st.smb.kerberos'].Status -eq 'yellow' -and $by['st.acl.root'].Status -eq 'red' -and $r.AclDiff -and $ui.BtnFslAclSet.Visibility -eq 'Visible' -and $ui.TxtFslAclDiff.Text -like '*recommendation*') ($by['st.ad.password'].Reason)
        Test-Smoke 'the access test ran as the domain user; the password field is empty again and the key was not used' ($by['st.access'].Status -eq 'green' -and $ui.PwdFslPassword.Password -eq '' -and -not $r.KeyUsed -and $script:FslFake.Arm.Store.KeyRequests -eq 0) $by['st.access'].Reason
        Test-Smoke 'the result is stored, no password or token in the state folder' ((Get-AVDTuneState $script:StateRoot).StorageCheck.Account -eq 'stfake01' -and ((Get-ChildItem $script:StateRoot -Recurse -File | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join "`n") -notmatch 'smoke-test-password-1|fake-storage-token|fake-arm-token') $null
        $sv = $ui.PageFSLogix.Children[0]; Show-Page 'FSLogix'; $window.UpdateLayout()
        $sv.ScrollToVerticalOffset(99999); $window.UpdateLayout(); Save-SmokeShot '55-fslogix-storage-light'
        # set the ACL after the diff
        $ui.BtnFslAclSet.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Test-Smoke 'set the recommended ACL: the confirmation names the diff, the share got it once with attributes preserved, the change log has it' ($script:ConfirmAsked -like '*recommended ACL*diff*' -and $script:FslFake.Files.Store.Puts.Count -eq 1 -and $script:FslFake.Files.Store.Puts[0].Attributes -eq 'preserve' -and @(Get-AVDTuneChangeLog -Root $script:StateRoot | Where-Object Component -eq 'Storage ACL').Count -eq 1) $ui.TxtFslState.Text
        $true } }
    @{ Name = 'start: sign-out and dark'; Do = {
        Open-Stage 'SignIn'; $window.UpdateLayout()
        $ui.BtnStageAction2.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Test-Smoke 'sign out removes every token from memory (checked before Finish)' (Test-AVDTuneSessionClear $script:StartContext.Session) $null
        Open-Stage 'SignIn'; $window.UpdateLayout()
        Test-Smoke 'signed out with a saved registration: the sign-in offers to set up again for another administrator' ($ui.BtnStageAction2.Visibility -eq 'Visible' -and [string]$ui.BtnStageAction2.Content -eq 'Set up again (authorize this administrator)') ([string]$ui.BtnStageAction2.Content)
        Close-Stage
        $allFiles = (Get-ChildItem $script:StateRoot -Recurse -File | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join "`n"
        Test-Smoke 'no token, refresh token or password in any file of the state folder' ($allFiles -notmatch 'eyJ[A-Za-z0-9_-]{10,}' -and $allFiles -notmatch 'fake-refresh' -and $allFiles -notmatch 'Not-A-Real-Password') $null
        Test-Smoke 'every service of the start sequence was a fake (no real adapter in test mode)' ($script:Services.Auth.Kind -eq 'Fake' -and $script:Services.Arm.Kind -eq 'Fake' -and $script:Services.Ldap.Kind -eq 'Fake') $null
        if ($script:Settings.Theme -ne 'Dark') { $ui.BtnTheme.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) }
        Open-Stage 'Environment'; $window.UpdateLayout()
        Save-SmokeShot '23-start-questions-dark'
        Close-Stage
        $ui.BtnTheme.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        $true } }
    @{ Name = 'readiness: signed out'; Do = {
        if ($script:OverviewJob -or $script:ReadyJob -or $script:ReadyQueued) { return $false }
        if (-not $script:ReadyOutStarted) {
            $script:ReadyOutStarted = $true
            Show-Page 'Overview'
            Test-Smoke 'signed out: no Azure token for the analysis' (-not $script:StartContext.Session.Connected -and (Get-ReadyToken).Token -eq '' -and (Get-ReadyToken).Reason -like 'Not signed in*') $null
            $ui.BtnReadyRun.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
            return $false
        }
        $window.UpdateLayout()
        $rows = @{}; foreach ($x in $script:Ready.Rows) { $rows[$x.Id] = $x }
        Test-Smoke 'without the sign-in the Azure checks are not checkable, with the reason; the others still ran' (-not $script:Ready.Arm.Ok -and $rows['hw.disk-controller'].Status -eq 'unknown' -and $rows['hw.disk-controller'].Reason -like 'Not checkable: Not signed in*' -and $rows['hw.accelnet'].Status -eq 'unknown' -and $rows['hw.gallery'].Status -eq 'unknown' -and $rows['hw.stornvme'].Status -eq 'green') $rows['hw.disk-controller'].Reason
        Test-Smoke 'the card says Azure was not read and why' ($ui.TxtReadySummary.Text -like '*Azure was not read: Not signed in*') $ui.TxtReadySummary.Text
        $ui.BoxReady.BringIntoView(); $window.UpdateLayout()
        Save-SmokeShot '44-readiness-signed-out-light'
        $true } }
    @{ Name = 'task bar'; Do = {
        # the flows of the earlier steps went through the one mechanism; wait (at most 30 s) until nothing runs any more
        if (-not $script:TaskStepStart) { $script:TaskStepStart = Get-Date }
        $tasks = @(Get-AVDTuneUiTasks)
        if (@($tasks | Where-Object { $_.Status -eq 'running' }).Count -gt 0 -and ((Get-Date) - $script:TaskStepStart).TotalSeconds -lt 30) { return $false }
        $kinds = @($tasks | ForEach-Object { $_.Kind } | Select-Object -Unique)
        $need = 'overview', 'release-start', 'readiness-start', 'stage', 'snapshot', 'update-scan', 'update-run', 'benchmark', 'watermark'
        Test-Smoke 'the flows of the earlier steps are tasks: machine read, integrity check, readiness analysis, sign-in and other calls of the start sequence, snapshot, update search and run, benchmark, watermark' (@($need | Where-Object { $_ -notin $kinds }).Count -eq 0) ("missing: " + (($need | Where-Object { $_ -notin $kinds }) -join ', ') + " / have: " + ($kinds -join ', '))
        Test-Smoke 'no task is stuck on running after the flows ended' (@($tasks | Where-Object { $_.Status -eq 'running' }).Count -eq 0) ((@($tasks | Where-Object { $_.Status -eq 'running' } | ForEach-Object { $_.Title })) -join '; ')
        $signIn = @($tasks | Where-Object { $_.Title -eq 'Signing in to Microsoft 365 and Azure' })
        Test-Smoke 'the sign-in is a task and succeeded' ($signIn.Count -ge 1 -and $signIn[0].Status -eq 'succeeded' -and $signIn[0].Summary -eq 'Signed in') (($signIn | ForEach-Object { $_.Status }) -join ',')
        $snap = @($tasks | Where-Object { $_.Kind -eq 'snapshot' })
        Test-Smoke 'the snapshot is a task that ran until Azure had it ready' ($snap.Count -ge 1 -and $snap[0].Status -eq 'succeeded' -and $snap[0].Summary -like '*is ready') (($snap | ForEach-Object { "$($_.Status) $($_.Summary)" }) -join ',')
        $run = @($tasks | Where-Object { $_.Kind -eq 'update-run' })
        Test-Smoke 'the update run is a task with the steps of the run in its log and its result as summary' ($run.Count -ge 1 -and $run[0].Summary -like 'Run finished*' -and $run[0].Log.Count -ge 2) (($run | ForEach-Object { "$($_.Status) $($_.Summary) $($_.Log.Count)" }) -join ',')
        $scan = @($tasks | Where-Object { $_.Kind -eq 'update-scan' })
        Test-Smoke 'the update search is a task and offers Retry' ($scan.Count -ge 1 -and $scan[0].Retry.Command -eq 'Start-UpdJob') $null
        $bench = @($tasks | Where-Object { $_.Kind -eq 'benchmark' })
        Test-Smoke 'the benchmark is a task (a run is never offered as Retry: it asks first)' ($bench.Count -ge 1 -and $bench[0].Summary -like 'Benchmark finished*' -and -not $bench[0].Retry) (($bench | ForEach-Object { "$($_.Status) $($_.Summary)" }) -join ',')
        $writes = @($tasks | Where-Object { $_.Kind -in 'update-run', 'update-block-on', 'update-block-off', 'update-repair-sfc', 'update-repair-dism', 'watermark', 'benchmark' -and $_.Retry })
        Test-Smoke 'no task that changes the master offers Retry (it would skip the confirmation)' ($writes.Count -eq 0) (($writes | ForEach-Object { $_.Kind }) -join ',')
        $secrets = (@($tasks | ForEach-Object { $_.Title; $_.Summary; $_.Step; @($_.Log | ForEach-Object { $_.Text }) }) -join ' ')
        Test-Smoke 'no token, password or sign-in secret in any task of the session' ($secrets -notmatch 'eyJ[A-Za-z0-9_-]{10,}' -and $secrets -notmatch 'Not-A-Real-Password' -and $secrets -notmatch 'fake-refresh') $null

        # the scenes, light then dark (the theme is put back at the end)
        $first = $script:Settings.Theme
        $light = Invoke-TaskScene $(if ($first -eq 'Dark') { 'dark' } else { 'light' })
        $window.UpdateLayout()
        # Retry: runs the start function once, the failed row loses its button
        $row = $script:TaskRows[[int]$light.B.Id]
        $row.RetryBtn.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Test-Smoke 'Retry runs the named start function once and the failed row loses the button' ($script:SmokeRetryCalls -eq 1 -and $row.RetryBtn.Visibility -eq 'Collapsed' -and -not $light.B.Retry) $script:SmokeRetryCalls
        # the result goes away after its time: the bar is idle again but remembers the failed one
        Complete-AVDTuneUiTask $light.D -Summary 'Done'
        foreach ($t in @($light.A, $light.B, $light.C, $light.D)) { $t.Finished = (Get-Date).AddSeconds(-60) }
        Update-TaskBar
        Test-Smoke 'after the result time the bar is idle: no task running, 4 tasks in this session, one failed' ($ui.TxtTaskTitle.Text -eq 'No task running' -and $ui.TxtTaskStep.Text -eq '4 tasks in this session' -and $ui.TxtTaskResult.Text -eq '1 failed' -and $ui.PillTaskResult.Visibility -eq 'Visible') "$($ui.TxtTaskStep.Text) / $($ui.TxtTaskResult.Text)"
        # a click on the bar closes the list again
        $click = New-Object System.Windows.Input.MouseButtonEventArgs([System.Windows.Input.Mouse]::PrimaryDevice, 0, [System.Windows.Input.MouseButton]::Left)
        $click.RoutedEvent = [System.Windows.UIElement]::MouseLeftButtonUpEvent
        $ui.BoxTaskBar.RaiseEvent($click)
        Test-Smoke 'a click on the bar closes the list' (-not $script:TaskListOpen -and $ui.BoxTaskList.Visibility -eq 'Collapsed') $null
        Switch-Theme
        [void](Invoke-TaskScene $(if ($first -eq 'Dark') { 'light' } else { 'dark' }))
        Reset-TaskScene
        Switch-Theme
        Test-Smoke 'the theme is back as it was' ($script:Settings.Theme -eq $first) $script:Settings.Theme
        $script:TaskStepStart = $null
        $true } }
    @{ Name = 'close after the operation'; Do = {
        # last step: closing during a search is held back and the window closes by itself when the search is done (the Closed handler below records it)
        if (-not $script:CloseStepStarted) {
            $script:CloseStepStarted = Get-Date
            Show-Page 'Updates'
            Start-UpdJob 'Scan' $null
            $window.Close()
            Test-Smoke 'closing during the search is held back' ($window.IsVisible -and $script:CloseWhenDone) $null
            $script:SmokeAwaitAutoClose = $true
            $script:SmokeResults | Set-Content (Join-Path $script:SmokeOut 'results.txt')
            return $false
        }
        if (((Get-Date) - $script:CloseStepStarted).TotalSeconds -lt 60) { return $false }
        $script:SmokeAwaitAutoClose = $false; $script:CloseWhenDone = $false
        Test-Smoke 'the window closes by itself after the operation' $false 'still open after 60 s'
        $true } }
)
$window.Add_Closed({
    if (-not $script:SmokeAwaitAutoClose) { return }
    Test-Smoke 'the window closes by itself after the operation' (-not $script:UpdJob) $null
    $script:SmokeResults | Set-Content (Join-Path $script:SmokeOut 'results.txt')
})

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
        try { Set-Content (Join-Path $script:SmokeOut 'current-step.txt') ([string]$step.Name) } catch { }
        try { $done = & $step.Do $step }
        catch { Test-Smoke "step '$($step.Name)'" $false "$($_.Exception.Message) @ $($_.InvocationInfo.ScriptLineNumber) $($_.ScriptStackTrace -replace "s+", " ")"; $done = $true }
        if ($done) { $script:SmokeSteps.RemoveAt(0); try { $script:SmokeResults | Set-Content (Join-Path $script:SmokeOut 'results-partial.txt') } catch { } }
    }
    catch {
        [void]$script:SmokeResults.Add("FAIL driver: $($_.Exception.Message)")
        $script:SmokeResults | Set-Content (Join-Path $script:SmokeOut 'results.txt')
        $window.Close()
    }
})
$window.Add_ContentRendered({ $script:SmokeTimer.Start() })
