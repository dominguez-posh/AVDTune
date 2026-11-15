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
