# Dot-sourced by Start-AVDTune.ps1 when AVDTUNE_SMOKE is set (see Tests\Invoke-GuiSmoke.ps1; only in test mode: fake machine, temporary state folder).
# Puts the window off-screen and walks through the steps below on the UI thread; each step returns $true when it is done
# (or $false to be asked again on the next tick). Screenshots of every page land in the output folder (shot-NN-*.png).

$script:SmokeOut = $env:AVDTUNE_SMOKE_OUT
$script:SmokeResults = New-Object System.Collections.ArrayList
$window.WindowStartupLocation = 'Manual'
$window.Left = -20000; $window.Top = -20000
$window.ShowActivated = $false
$window.ShowInTaskbar = $false

function Complete-SmokeFslRead {
    # #72: in test mode the read of the FSLogix page waits for the overview read (both use the fake machine, Complete-FslRead); the smoke waits for it here (at most 30 s) and takes both over
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($script:OverviewJob -and -not $script:OverviewJob.Handle.IsCompleted -and $sw.ElapsedMilliseconds -lt 30000) { Start-Sleep -Milliseconds 50 }
    Complete-OverviewRefresh
    Complete-FslRead
}
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

# ---- idle wait (issues #80, #57): the fake machine's closures are not safe to call from two runspaces at once (the module state of a closure
# is not thread-safe: a second runspace calling the same closure at the same time sees $store as $null -> "method on a null-valued expression").
# A page job reads the shared fake machine in its own runspace, so no step may touch the machine (or run product code that does) while one is running.
# Wait-SmokeIdle waits on the handles of all background jobs (it does not need the dispatcher; the Complete-* handlers still run on the timer).
function Wait-SmokeIdle([int]$TimeoutSeconds = 30) {
    $until = (Get-Date).AddSeconds($TimeoutSeconds)
    foreach ($name in @('OverviewJob') + @($script:WriterJobVariables)) {
        $job = Get-Variable -Scope Script -Name $name -ValueOnly -ErrorAction SilentlyContinue
        if ($job -is [System.Collections.IDictionary] -and $job.Contains('Handle') -and $job['Handle']) {
            $left = [int][Math]::Max(0, ($until - (Get-Date)).TotalMilliseconds)
            try { [void]$job['Handle'].AsyncWaitHandle.WaitOne($left) } catch { }
        }
    }
}
# Show-Page starts the page's read job: wait for it, so the step that follows does not use the machine while the job does
$script:SmokeShowPageOriginal = ${function:Show-Page}
function Show-Page { & $script:SmokeShowPageOriginal @args; Wait-SmokeIdle }

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
        Test-Smoke 'navigation has all 18 pages in plan order (Customizations #85, Printers #86 included)' ($ui.NavList.Children.Count -eq 18 -and $ui.NavCustomizations -and $ui.NavPrinters -and $ui.NavOverview -and $ui.NavProtocol -and $ui.NavSeal -and $ui.NavList.Children[0].Name -eq 'NavOverview') $ui.NavList.Children.Count
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
            $placeholder = $page.Key -notin 'Overview', 'Protocol', 'Updates', 'UpdateBlock', 'UserExperience', 'Benchmark', 'FSLogix', 'Software', 'Office', 'VdiComponents', 'AppMasking', 'Seal', 'Environment', 'Optimization', 'Language', 'Customizations', 'Printers'
            $ok =($script:CurrentPage -eq $page.Key -and $ui["Nav$($page.Key)"].IsChecked -and $ui.PagePlaceholder.Visibility -eq (ConvertTo-Vis $placeholder))
            if ($placeholder) { $ok = $ok -and $ui.TxtPhTitle.Text -eq $page.Title -and $ui.TxtPhPhase.Text -eq "Planned for phase $($page.Phase)" -and $ui.TxtPhText.Text.Length -gt 40 }
            Test-Smoke "page $($page.Key) shows" $ok $null
            if ($page.Key -in 'Updates', 'UpdateBlock', 'Seal') { Save-SmokeShot ('{0:00}-page-{1}-dark' -f $index, $page.Key.ToLower()); $index++ }
        }
        Test-Smoke 'last page is "Cleanup and finish" (the master is never sysprepped)' ((($script:PageTable | Where-Object Key -eq 'Seal').Title -eq 'Cleanup and finish') -and -not (Find-Text $ui.NavList 'Cleanup and seal') -and (Find-Text $ui.NavList 'Cleanup and finish') -and $ui.PageSeal.Visibility -eq 'Collapsed' -and ($script:PageTable | Where-Object Key -eq 'Seal').Text -like '*never sysprepped*' -and $ui.TxtSealSubtitle.Text -like '*never sysprepped*') $ui.TxtSealSubtitle.Text
        $keepWidth = $window.Width
        foreach ($width in 1280, 960) {
            $window.Width = $width
            foreach ($head in @(@('Overview', 'TxtOverviewSubtitle', 'PanelOverviewHead'), @('Updates', 'TxtUpdSubtitle', 'PanelUpdHead'), @('UpdateBlock', 'TxtBlockSubtitle', 'PanelBlockHead'), @('UserExperience', 'TxtUxSubtitle', 'PanelUxHead'), @('UserExperience', 'TxtUxSubtitle', 'PanelUxHead'), @('Protocol', 'TxtProtocolSubtitle', 'PanelProtocolHead'), @('FSLogix', 'TxtFslSubtitle', 'PanelFslHead'))) {
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
    @{ Name = 'ui language'; Do = {
        Show-Page 'Overview'
        $window.UpdateLayout()
        Test-Smoke 'language: English at the start, the button shows EN, the texts come from the language file' ((Get-AVDTuneLanguage) -eq 'en' -and $ui.BtnLang.Content -eq 'EN' -and $ui.BtnRefresh.Content -eq 'Refresh' -and $ui.TxtOverviewSubtitle.Text -like 'This Golden Master at a glance*') "$(Get-AVDTuneLanguage) / $($ui.BtnLang.Content)"
        Test-Smoke 'language: the language files loaded without a problem, both with the same number of keys' ($script:LanguageInit.Problems.Count -eq 0 -and $script:LanguageInit.Keys.en -gt 100 -and $script:LanguageInit.Keys.en -eq $script:LanguageInit.Keys.de) ($script:LanguageInit.Problems -join '; ')
        $ui.BtnLang.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        $window.UpdateLayout()
        $saved = Get-Content (Join-Path $script:StateRoot 'config\ui.json') -Raw | ConvertFrom-Json
        Test-Smoke 'language: switch to German sets the setting, the protocol language and the saved file' ((Get-AVDTuneLanguage) -eq 'de' -and $script:Settings.Language -eq 'de' -and $script:Settings.ProtocolLanguage -eq 'de' -and $ui.BtnLang.Content -eq 'DE' -and $saved.Language -eq 'de' -and $saved.ProtocolLanguage -eq 'de') $null
        Test-Smoke 'language: navigation in German' ((Find-Text $ui.NavList ([string][char]0x00DC + 'bersicht')) -and (Find-Text $ui.NavList 'Update-Sperre') -and (Find-Text $ui.NavList 'Bereinigung und Abschluss') -and -not (Find-Text $ui.NavList 'Overview')) $null
        Test-Smoke 'language: title bar, overview head and cards in German' ($ui.BtnRefresh.Content -eq 'Aktualisieren' -and $ui.BtnNewVersion.Content -eq 'Neue Version starten' -and $ui.TxtOverviewSubtitle.Text -like '*auf einen Blick*' -and $ui.TxtChipVersion.Text -eq 'keine Image-Version' -and (Find-Text $window.Content 'Startsequenz') -and (Find-Text $window.Content 'Bereitschaft') -and (Find-Text $window.Content ('Integrit' + [string][char]0x00E4 + 't und Updates'))) $null
        Test-Smoke 'language: health, start sequence and identity rows in German' ((Find-Text $ui.PanelHealth 'Neustart ausstehend') -and (Find-Text $ui.PanelHealth 'AVD-Agent') -and (Find-Text $ui.PanelStages 'Offen') -and (Find-Text $ui.PanelStages '1. Anmeldung bei Microsoft 365 und Azure') -and (Find-Text $ui.PanelIdentity 'Image-Name') -and (Find-Text $ui.PanelIdentity 'Letzter Benchmark')) $null
        Test-Smoke 'language: task bar and tooltips in German' ((Get-AVDTuneText 'task.idle') -eq ('Keine Aufgabe l' + [string][char]0x00E4 + 'uft') -and $ui.BtnLang.ToolTip -like 'Sprache: Deutsch*' -and $ui.BtnTheme.ToolTip -eq 'Hell oder dunkel' -and $ui.BoxTaskBar.ToolTip -eq 'Die Aufgaben dieser Sitzung anzeigen' -and $ui.BtnClose.ToolTip -eq ('Schlie' + [string][char]0x00DF + 'en')) $null
        $script:LangTexts.de.Remove('title.close.tip')
        Test-Smoke 'language: an unknown key shows itself, a missing German key falls back to English' ((Get-AVDTuneText 'does.not.exist') -eq 'does.not.exist' -and (Get-AVDTuneText 'title.close.tip') -eq 'Close') $null
        $script:LangTexts.de['title.close.tip'] = 'Schlie' + [string][char]0x00DF + 'en'
        Test-Smoke 'language: a page that is not translated yet keeps its English texts' ($ui.BtnUpdScan.Content -eq 'Search') $ui.BtnUpdScan.Content
        Save-SmokeShot '03b-overview-german'
        $ui.BtnLang.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        $window.UpdateLayout()
        $saved = Get-Content (Join-Path $script:StateRoot 'config\ui.json') -Raw | ConvertFrom-Json
        Test-Smoke 'language: back to English, everything as before' ((Get-AVDTuneLanguage) -eq 'en' -and $ui.BtnRefresh.Content -eq 'Refresh' -and $ui.TxtChipVersion.Text -eq 'no image version' -and (Find-Text $ui.NavList 'Overview') -and (Find-Text $ui.PanelHealth 'AVD agent') -and (Get-AVDTuneText 'task.idle') -eq 'No task running' -and $saved.Language -eq 'en') $null
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
        # #57 (#27, #66): while a writer runs, 'Start new version' is locked and a click is refused with the busy text; nothing changes in the state
        $script:OptRun = @{ Kind = 'Run' }
        try {
            Update-Chip
            $verBusy = (Get-AVDTuneState $script:StateRoot).ImageVersion; $script:ConfirmAsked = ''
            Start-NewVersion
            Test-Smoke 'Start new version is locked while a writer runs (button disabled with a tooltip, a click asks nothing and changes no version)' (-not $ui.BtnNewVersion.IsEnabled -and $ui.BtnNewVersion.ToolTip -and -not $script:ConfirmAsked -and (Get-AVDTuneState $script:StateRoot).ImageVersion -eq $verBusy) "enabled=$($ui.BtnNewVersion.IsEnabled) asked='$script:ConfirmAsked'"
        }
        finally { $script:OptRun = $null; Update-Chip }
        Test-Smoke 'Start new version is unlocked again when the writer is gone' ($ui.BtnNewVersion.IsEnabled) $null
        $true } }
    @{ Name = 'protocol'; Do = {
        Show-Page 'Protocol'
        $window.UpdateLayout()
        $version = (Get-AVDTuneState $script:StateRoot).ImageVersion
        Test-Smoke 'session protocol: AVDTune title, image and the version action' ($ui.TxtProtocol.Text -like 'AVDTune session protocol*' -and $ui.TxtProtocol.Text -like "*Image: GM-TEST01 $version*" -and $ui.TxtProtocol.Text -like "*Image version $version started*" -and $ui.TxtProtocol.Text -notlike '*PackTune*') $ui.TxtProtocol.Text
        $ui.BtnLang.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Test-Smoke 'German protocol' ($ui.TxtProtocol.Text -like 'AVDTune-Sitzungsprotokoll*' -and $ui.TxtProtocol.Text -like '*Einrichtung*' -and $script:Settings.ProtocolLanguage -eq 'de') $null
        Save-SmokeShot '07-protocol-session'
        $ui.BtnLang.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Test-Smoke 'switch back to English: the protocol follows the same switch' ($script:Settings.ProtocolLanguage -eq 'en' -and $script:Settings.Language -eq 'en' -and $ui.TxtProtocol.Text -like 'AVDTune session protocol*') $null
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
    @{ Name = 'start: sign-in'; Do = {
        # issue #64: the sign-in is the first stage and needs no answer; the master is a domain member for the join detection that follows it (the fake machine, restored after the domain step)
        $script:Machine.Store.ComputerSystem = [pscustomobject]@{ PartOfDomain = $true; Domain = 'Example.Test'; DomainRole = 3 }
        $script:Machine.Store.DcLocate = [pscustomobject]@{ Name = ''; Address = '10.0.0.10'; Site = 'Default-First-Site-Name' }
        Test-Smoke 'first start without environment.json: the stages are in the new order (sign-in, domain, questions, snapshot), only the sign-in is to do, nothing is asked before it' (-not (Test-Path (Join-Path $script:StateRoot 'environment.json')) -and (($script:Stages | ForEach-Object Id) -join ',') -eq 'SignIn,Domain,Environment,Snapshot' -and (($script:Stages | ForEach-Object Status) -join ',') -eq 'Pending,Locked,Locked,Locked' -and $ui.PanelStages.Children.Count -eq 4) (($script:Stages | ForEach-Object Status) -join ',')
        Open-Stage 'SignIn'; $window.UpdateLayout()
        Test-Smoke 'first start: "Benchmark only" is offered next to the sign-in (plan 6b, #90), nothing is switched before the confirmation' ($ui.BtnStageAction2.Visibility -eq 'Visible' -and [string]$ui.BtnStageAction2.Content -eq (T 'stage.signin.benchonly') -and -not $script:BenchmarkOnly) ([string]$ui.BtnStageAction2.Content)
        Test-Smoke 'sign-in form lists the four tokens with their permissions' ($ui.PanelStageBody.Children.Count -ge 5 -and (Find-Text $ui.PanelStageBody 'Sites') -and (Find-Text $ui.PanelStageBody 'Azure Resource Manager (snapshot, VM size, region): user_impersonation')) $null
        Test-Smoke 'sign-in form without tenant and client ID: tenant from the sign-in, own app registration announced, account field' ((Find-Text $ui.PanelStageBody 'Taken from the sign-in (tid of the token) and saved') -and (Find-Text $ui.PanelStageBody "None yet: AVDTune creates its own app registration 'AVDTune' first") -and $script:Form.Account -and $script:Form.Account.Text -eq '' -and $script:Form.ClientId -and $script:Form.ClientId.Text -eq '' -and (Find-Text $ui.PanelStageBody 'Client ID of an existing app registration (optional)')) $null
        Save-SmokeShot '14-start-signin'
        # a wrong account is refused before any sign-in window
        $script:Form.Account.Text = 'admin'
        $ui.BtnStageAction.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Test-Smoke 'an account that is not name@domain is refused in the form, nothing signed in' ($ui.TxtStageMessage.Text -like '*name@domain*' -and @($script:Services.Auth.Log | Where-Object { $_ -like 'SignIn*' }).Count -eq 0) $ui.TxtStageMessage.Text
        # a client ID typed in the form is checked before any sign-in window: not a GUID, and Microsoft's own setup app
        $script:Form.Account.Text = ''
        $script:Form.ClientId.Text = 'abc'
        $ui.BtnStageAction.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        $msgGuid = $ui.TxtStageMessage.Text
        $script:Form.ClientId.Text = '14d82eec-204b-4c2f-b7e8-296a70dab67e'
        $ui.BtnStageAction.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Test-Smoke 'a client ID that is no GUID, and the setup app of Microsoft, are refused in the form, nothing signed in' ($msgGuid -like '*must be a GUID*' -and $ui.TxtStageMessage.Text -like '*setup app*' -and @($script:Services.Auth.Log | Where-Object { $_ -like 'SignIn*' }).Count -eq 0) "$msgGuid | $($ui.TxtStageMessage.Text)"
        $script:Form.ClientId.Text = ''
        $script:Form.Account.Text = 'admin.example@contoso.example'
        $script:ConfirmAsked = ''
        $ui.BtnStageAction.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        $envSigned = Get-AVDTuneEnvironmentFile $script:StateRoot   # no answers yet: the file only has the sign-in target
        $fakeApp = @($script:Services.Auth.Store.Apps)[0]
        Test-Smoke 'setup asked first and named the consent that stays with Microsoft Graph Command Line Tools' ($script:ConfirmAsked -like "*Microsoft Graph Command Line Tools*Application.ReadWrite.All*consent for your account only*takes these two out of your own consent*whole organization*") $script:ConfirmAsked
        Test-Smoke 'setup sign-in (fake) at organizations with the account, registration AVDTune created, then the normal sign-in with it' (@($script:Services.Auth.Log | Where-Object { $_ -like 'SignIn tenant=organizations client=setup hint=admin.example@contoso.example*' }).Count -eq 1 -and $fakeApp -and @($script:Services.Auth.Log | Where-Object { $_ -like "SignIn tenant=11111111-2222-3333-4444-555555555555 client=$($fakeApp.appId) hint=admin.example@contoso.example*" }).Count -eq 1) ($script:Services.Auth.Log -join ' | ')
        Test-Smoke 'environment.json has the tenant of the token and the client ID of the new registration; the change log says so' ($envSigned.SignIn.TenantId -eq '11111111-2222-3333-4444-555555555555' -and $envSigned.SignIn.ClientId -eq $fakeApp.appId -and @(Get-AVDTuneChangeLog -Root $script:StateRoot | Where-Object { $_.Text -like 'Tenant taken from the sign-in: 11111111-*' }).Count -eq 1 -and @(Get-AVDTuneChangeLog -Root $script:StateRoot | Where-Object { $_.Text -like "Client ID of AVDTune's own app registration saved*" }).Count -eq 1) ($envSigned.SignIn | ConvertTo-Json -Compress)
        Test-Smoke 'the protocol has the registration, the tenant and the warning about the setup consent' (@($script:Protocol.Actions | Where-Object { $_.Subject -eq 'Sign-in: tenant and app registration' -and $_.Note -like "*App registration 'AVDTune' created*" }).Count -eq 1 -and @($script:Protocol.Actions | Where-Object { $_.Subject -eq 'Setup consent of Microsoft Graph Command Line Tools' -and $_.Note -like '*whole organization stays*' }).Count -eq 1 -and @($script:Protocol.Actions | Where-Object { $_.Note -like "*taken out of your own consent for 'Microsoft Graph Command Line Tools'*" }).Count -eq 1) $null
        $fakeSp = @($script:Services.Auth.Store.ServicePrincipals | Where-Object { $_.appId -eq $fakeApp.appId })[0]
        Test-Smoke 'the enterprise app requires an assignment, the admin is assigned and consented for himself only' ($fakeSp.appRoleAssignmentRequired -eq $true -and @($fakeSp.Assigned).Count -eq 1 -and @($script:Services.Auth.Store.Grants | Where-Object { $_.clientId -eq $fakeSp.id -and $_.consentType -eq 'Principal' }).Count -eq 3 -and @($script:Services.Auth.Store.Grants | Where-Object { $_.consentType -eq 'AllPrincipals' }).Count -eq 0) $null
        $info = Get-AVDTuneSessionInfo $script:StartContext.Session
        Test-Smoke 'sign-in (fake): connected, four audiences, stage Done, the domain step is next (the master is a domain member), the questions and the snapshot wait' ($info.Connected -and $info.Audiences.Count -eq 4 -and (($script:Stages | ForEach-Object Status) -join ',') -eq 'Done,Pending,Locked,Locked' -and $script:StartContext.Detection.Kind -eq 'AdDs') (($script:Stages | ForEach-Object Status) -join ',')
        Test-Smoke 'the protocol names the account and holds no token' (@($script:Protocol.Actions | Where-Object { $_.Subject -eq 'Microsoft 365 and Azure sign-in' -and $_.Note -like 'Signed in as admin.example@*' -and $_.Note -notmatch 'eyJ' }).Count -eq 1) $null
        # the sign-in came before any answer: tenant and client ID are saved, the file has no answers, and the join state was read right after it
        Test-Smoke 'the sign-in saved tenant and client ID without any answer; the join state of the master was read (read only) and is in the protocol' ($envSigned.SignIn.TenantId -and $null -eq (Get-AVDTuneEnvironment $script:StateRoot) -and $null -eq (Get-AVDTuneProp $envSigned 'Answers') -and @($script:Protocol.Actions | Where-Object { $_.Subject -eq 'Join state of this master read' -and $_.Note -like '*joined to the domain example.test*Win32_ComputerSystem*' }).Count -eq 1) ($envSigned | ConvertTo-Json -Compress -Depth 3)
        Save-SmokeShot '14c-start-after-signin'
        $true } }
    @{ Name = 'start: domain'; Do = {
        Open-Stage 'Domain'; $window.UpdateLayout()
        Test-Smoke 'domain stage after the sign-in: the join state says domain member, the intro names it, the server of the DC locator is suggested with its source' ($script:Form.Server.Text -eq '10.0.0.10' -and $ui.TxtStageTitle.Text -eq '2. Domain controller' -and $ui.TxtStageIntro.Text -like 'This master is joined to the domain example.test.*' -and (Find-Text $ui.PanelStageBody 'Suggested by the DC locator of Windows for the domain example.test (site Default-First-Site-Name). Change it if another controller should be read.')) $script:Form.Server.Text
        $envLocator = Get-AVDTuneEnvironmentFile $script:StateRoot
        Test-Smoke 'the DC locator suggestion alone, without a click: no probe, no bind, no search, no pin, no Dc server saved (issue #64, security review)' (@($script:Services.Ldap.Log).Count -eq 0 -and @($script:Services.Ldap.Opened).Count -eq 0 -and -not (Get-AVDTuneProp $envLocator 'Dc') ) ((@($script:Services.Ldap.Log) -join ' | ') + ' ' + ($envLocator | ConvertTo-Json -Compress -Depth 5))
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
        Test-Smoke 'domain stage Done with the facts, environment.json has the pin and the account name but no password' ((($script:Stages | ForEach-Object Status) -join ',') -eq 'Done,Done,Pending,Locked' -and ((Get-Content (Join-Path $script:StateRoot 'environment.json') -Raw) -notmatch 'Not-A-Real-Password') -and (Get-AVDTuneEnvironmentFile $script:StateRoot).Dc.Pins.'10.0.0.10'.Sha256 -and (Get-AVDTuneEnvironmentFile $script:StateRoot).Dc.User -eq 'EXAMPLE\svc-avdtune' -and $null -eq (Get-AVDTuneEnvironment $script:StateRoot)) (($script:Stages | ForEach-Object Status) -join ',')
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
        # the fake master is not a domain member any more for the rest of the run (the join state was read already; the domain step is done)
        $script:Machine.Store.ComputerSystem = [pscustomobject]@{ PartOfDomain = $false; Domain = 'WORKGROUP'; DomainRole = 2 }; $script:Machine.Store.DcLocate = $null
        $true } }
    @{ Name = 'start: questions'; Do = {
        # issue #64: the questions come after the sign-in and the domain step; what Azure (GET only) and the domain showed is suggested with its source, nothing counts before the confirmation
        $script:Services.Arm.Store.StorageAccounts = @(@{ Name = 'stprofilesexample'; Kind = 'FileStorage'; Public = 'Disabled'; PrivateEndpoints = 1 }); $script:Services.Arm.Store.DnsZones = @('privatelink.file.core.windows.net')
        $armBefore = $script:Services.Arm.Log.Count
        Open-Stage 'Environment'; $window.UpdateLayout()
        $armUsed = @($script:Services.Arm.Log | Select-Object -Skip $armBefore)
        Test-Smoke 'questions open after the domain step: 6 questions and 3 fields (the client ID is entered at the sign-in), nothing is saved yet (no answers in environment.json)' ($script:OpenStage -eq 'Environment' -and $ui.BoxStage.Visibility -eq 'Visible' -and $script:Form.Combos.Count -eq 6 -and $script:Form.Texts.Count -eq 3 -and -not $script:Form.Texts.ContainsKey('ClientId') -and $script:Form.Texts['SnapshotNamePattern'].Text -eq '{OsDisk}-{DD}.{MM}.{YYYY}-{N}' -and $null -eq (Get-AVDTuneEnvironment $script:StateRoot) -and $null -eq (Get-AVDTuneProp (Get-AVDTuneEnvironmentFile $script:StateRoot) 'Answers')) $script:OpenStage
        Test-Smoke 'suggested from the domain and Azure and marked as such: join, identities, network, profiles, endpoint, DNS zone preselected, each with its source' ($script:Form.Combos['Join'].Control.SelectedItem -eq 'AD DS join only' -and $script:Form.Combos['Identities'].Control.SelectedItem -eq 'Synchronized (Entra Connect / Cloud Sync)' -and $script:Form.Combos['Profiles'].Control.SelectedItem -eq 'FSLogix profile container on Azure Files' -and $script:Form.Combos['Endpoint'].Control.SelectedItem -eq 'Private endpoint (recommended)' -and $script:Form.Combos['DnsZone'].Control.SelectedItem -eq 'In Azure (private DNS zone)' -and $script:Form.Texts['VNet'].Text -eq 'vnet-example' -and $script:Form.Texts['Subnet'].Text -eq 'snet-avd' -and $script:Form.SourceLabels['Join'].Text -like 'Suggested, counts after you confirm: *Win32_ComputerSystem*' -and $script:Form.SourceLabels['VNet'].Text -like '*Azure Resource Manager*' -and $script:Form.SourceLabels['Profiles'].Text -like '*stprofilesexample*') ($script:Form.SourceLabels.Keys | ForEach-Object { "$_=$($script:Form.SourceLabels[$_].Text)" })
        Test-Smoke 'the ambiguous question is empty and says why; the form cannot be confirmed yet' ($null -eq $script:Form.Combos['Dc'].Control.SelectedItem -and $script:Form.SourceLabels['Dc'].Text -like 'Please answer: *Azure or on premises*' -and $script:Form.Preview.Text -like 'Still to answer: Domain controller*' -and -not $ui.BtnStageAction.IsEnabled) $script:Form.Preview.Text
        Test-Smoke 'Azure was read with GET requests only, and the protocol names the suggestions' ($armUsed.Count -ge 4 -and @($armUsed | Where-Object { $_ -notlike 'GET *' }).Count -eq 0 -and @($script:Protocol.Actions | Where-Object { $_.Subject -eq 'Suggestions for the first-run questions' -and $_.Note -like '*value(s) suggested*Azure Resource Manager GET*' }).Count -eq 1) ($armUsed -join ' | ')
        Save-SmokeShot '11-start-questions'
        # an invalid combination is explained and cannot be saved
        $set = { param($key, $text) $script:Form.Combos[$key].Control.SelectedItem = $text }
        & $set 'Dc' 'None'
        Test-Smoke 'AD DS join without a domain controller: problem shown, save disabled' ($script:Form.Preview.Text -like '*Problem:*domain controller*' -and -not $ui.BtnStageAction.IsEnabled) $script:Form.Preview.Text
        Save-SmokeShot '12-start-questions-problem'
        & $set 'Dc' 'AD DS on premises (VPN or ExpressRoute)'
        & $set 'Join' 'Microsoft Entra hybrid join'   # the suggestion (AD DS only) is changed by the administrator
        Test-Smoke 'a changed suggestion says so and keeps what was suggested; the typed answer says so' ($script:Form.SourceLabels['Join'].Text -like 'Changed by you (suggested AdDs: *' -and $script:Form.SourceLabels['Dc'].Text -eq 'Typed by you.') ($script:Form.SourceLabels['Join'].Text)
        Test-Smoke 'hybrid with an on-premises DC is valid and the preview names the domain step and Azure Files with AD DS' ($ui.BtnStageAction.IsEnabled -and $script:Form.Preview.Text -like '*Domain step*' -and $script:Form.Preview.Text -like '*Azure Files with AD DS*' -and $script:Form.Preview.Text -like '*Nothing is saved before you confirm*') $script:Form.Preview.Text
        Test-Smoke 'still nothing saved while the form is filled' ($null -eq (Get-AVDTuneEnvironment $script:StateRoot)) $null
        Save-SmokeShot '13-start-questions-hybrid'
        $ui.BtnStageAction.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        $env1 = Get-AVDTuneEnvironment $script:StateRoot
        Test-Smoke 'confirming writes the answers into environment.json (no secret) with the source of each, keeps the sign-in and the DC pin, closes the form' ($env1.Answers.Join -eq 'Hybrid' -and $env1.Answers.Dc -eq 'AdDsOnPrem' -and $env1.Answers.Profiles -eq 'AzureFiles' -and $env1.Answers.Network.VNet -eq 'vnet-example' -and $env1.SignIn.TenantId -eq '11111111-2222-3333-4444-555555555555' -and $env1.SignIn.ClientId -and $env1.Dc.Pins.'10.0.0.10'.Sha256 -and $env1.Sources.Join -like 'Typed by the administrator (suggested AdDs*' -and $env1.Sources.Profiles -like 'Confirmed: *' -and $env1.Sources.Dc -eq 'Typed by the administrator' -and $ui.BoxStage.Visibility -eq 'Collapsed' -and (($script:Stages | ForEach-Object Status) -join ',') -eq 'Done,Done,Done,Pending') (($script:Stages | ForEach-Object Status) -join ',')
        Test-Smoke 'first run in a development copy: no shortcut question, the hint to install first (issue #15)' ($script:LastToast -like '*desktop shortcut can be created once AVDTune is installed*' -and $script:OpenStage -ne 'Shortcut') $script:LastToast
        Test-Smoke 'the protocol has the answered questions and how many suggestions were confirmed' (@($script:Protocol.Actions | Where-Object { $_.Subject -like 'First-run questions answered*' -and $_.Note -like '*suggestion(s) confirmed*' }).Count -eq 1) $null
        # no FSLogix: the two pages disappear from the navigation
        $none = Get-AVDTuneEnvironmentAnswers (Get-AVDTuneEnvironment $script:StateRoot); $none.Profiles = 'None'
        [void](Save-AVDTuneEnvironment -Root $script:StateRoot -Answers $none -User 'smoke'); Update-StartView
        Test-Smoke 'without FSLogix the FSLogix and App Masking pages are hidden' ($ui.NavFSLogix.Visibility -eq 'Collapsed' -and $ui.NavAppMasking.Visibility -eq 'Collapsed' -and $ui.NavUpdates.Visibility -eq 'Visible') $null
        $none.Profiles = 'AzureFiles'; [void](Save-AVDTuneEnvironment -Root $script:StateRoot -Answers $none -User 'smoke'); Update-StartView
        Test-Smoke 'with FSLogix they are back; a change after a version exists is a change log entry' ($ui.NavFSLogix.Visibility -eq 'Visible' -and @(Get-AVDTuneChangeLog -Root $script:StateRoot | Where-Object { $_.Component -eq 'Environment' -and $_.Text -like 'First-run answers changed*' }).Count -eq 2) $null
        # the saved environment is not asked again: Change shows the saved answers with their source and offers to forget the tenant
        Open-Stage 'Environment'; $window.UpdateLayout()
        Test-Smoke 'Change: the saved answers are shown with their source, no new suggestions are read, the saved tenant can only be forgotten, still no tenant field' ($script:Form.Combos['Join'].Control.SelectedItem -eq 'Microsoft Entra hybrid join' -and $script:Form.SourceLabels['Join'].Text -like 'Saved: Typed by the administrator (suggested AdDs*' -and $script:Form.SourceLabels['Profiles'].Text -like 'Saved: Typed by the administrator*' -and $null -eq $script:Form.Suggestions -and $script:Form.ForgetTenant -and -not $script:Form.ForgetTenant.IsChecked -and [string]$script:Form.ForgetTenant.Content -like '*11111111-2222-3333-4444-555555555555*' -and -not $script:Form.Texts.ContainsKey('TenantId')) $script:Form.SourceLabels['Join'].Text
        Save-SmokeShot '14b-start-questions-tenant'
        Close-Stage
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
    @{ Name = 'start: snapshot reconnect choice (#27)'; Do = {
        # Reconnect in a version that already has a change: every snapshot of the disk is listed, the ones that do not count are grey with the reason, the newest valid one is preselected, a grey one cannot be confirmed
        Close-AVDTuneWriteGate
        $t0 = (Get-Date).AddHours(-30); $first = (Get-Date).AddHours(-5)
        [void](Set-AVDTuneState -Root $script:StateRoot -Values @{ VersionBaseline = $t0.ToUniversalTime().ToString('o'); FirstChange = $null; FirstChangeSnapshotId = $null; SnapshotGate = $null })
        [void](Set-AVDTuneState -Root $script:StateRoot -Values @{ LastChange = (Get-Date).AddHours(-1).ToUniversalTime().ToString('o'); FirstChange = $first.ToUniversalTime().ToString('o') })
        $store = $script:ReadyFakeArm.Store
        foreach ($s in @(@('gm-v-before-start', $t0.AddHours(-1)), @('gm-v-start-1', $t0.AddHours(2)), @('gm-v-start-2', $first.AddHours(-1)), @('gm-v-after-change', $first.AddHours(1)))) {
            $id = "/subscriptions/$($script:FakeSubscription)/resourceGroups/$($store.ResourceGroup)/providers/Microsoft.Compute/snapshots/$($s[0])"
            $store.Snapshots[$id.ToLowerInvariant()] = @{ id = $id; name = $s[0]; location = $store.Location; tags = @{ CreatedWith = 'Someone else' }
                properties = @{ timeCreated = $s[1].ToUniversalTime().ToString('o'); provisioningState = 'Succeeded'; incremental = $true
                    creationData = @{ createOption = 'Copy'; sourceResourceId = $store.DiskId } } }
        }
        Open-Stage 'Snapshot'; $window.UpdateLayout()
        $combo = $script:Form.SnapList
        $items = @($combo.ItemsSource)
        $byName = @{}; foreach ($i in $items) { $byName[$i.Tag.Name] = $i }
        Test-Smoke 'reconnect: all snapshots are listed, the ones that do not count are grey (disabled) with the reason, the newest valid one (a version-start or a current-state snapshot, the line says which) is preselected' ($items.Count -ge 4 -and $byName['gm-v-start-2'].IsEnabled -and $byName['gm-v-start-1'].IsEnabled -and -not $byName['gm-v-before-start'].IsEnabled -and -not $byName['gm-v-after-change'].IsEnabled -and $combo.SelectedItem -eq (@($items | Where-Object IsEnabled)[0]) -and $combo.SelectedItem.Tag.Valid -and $byName['gm-v-after-change'].ToolTip -like '*Between the changes of this version*' -and $ui.BtnStageAction.IsEnabled) $ui.TxtStageMessage.Text
        Test-Smoke 'reconnect: the text says the rollback goes back to the start of the version' ($ui.TxtStageIntro.Text -like '*rollback goes back to the start of the version*' -and $ui.TxtStageMessage.Text -like '*rollback goes back to the start of the version*') $ui.TxtStageMessage.Text
        Save-SmokeShot '20b-start-snapshot-choice'
        $script:Form.NameBox.Text = 'Alex Example'
        $combo.SelectedItem = $byName['gm-v-after-change']
        $ui.BtnStageAction.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Test-Smoke 'reconnect: a grey snapshot cannot be confirmed, the gate stays closed' (-not (Test-AVDTuneWriteAllowed) -and $ui.TxtStageMessage.Text -like '*Choose one of the snapshots that count*') $ui.TxtStageMessage.Text
        $combo.SelectedItem = $byName['gm-v-start-2']
        $ui.BtnStageAction.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        $window.UpdateLayout()
        $state = Get-AVDTuneState $script:StateRoot
        Test-Smoke 'reconnect: the chosen snapshot is confirmed for the session; state.json and the change log carry it, the rollback hint names the version start' ((Test-AVDTuneWriteAllowed) -and $state.SnapshotGate.SnapshotName -eq 'gm-v-start-2' -and $state.SnapshotGate.Mode -eq 'Reconnect' -and $ui.TxtRollback.Text -like '*the start of the version*' -and @(Get-AVDTuneChangeLog -Root $script:StateRoot | Where-Object { $_.Category -eq 'Snapshot' -and $_.Text -like '*gm-v-start-2*reconnect*' }).Count -eq 1) ($state.SnapshotGate | ConvertTo-Json -Compress)
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
        if ($script:OverviewJob -or $script:ReadyJob -or ($script:RelJob -and [string]$script:RelJob.Kind -in 'Start', 'Check')) { return $false }   # #90: no start while the integrity check runs
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
        Test-Smoke 'quick run done: result stored, score and six categories shown, provisional note, history row' ($r.Count -eq 1 -and $r[0].mode -eq 'quick' -and $ui.TxtBenchScore.Text -match '^\d+$' -and $ui.PanelBenchCats.Children.Count -eq 6 -and $ui.BoxBenchProvisional.Visibility -eq 'Visible' -and $ui.PanelBenchHistory.Children.Count -eq 1 -and $ui.BtnBenchFull.IsEnabled) "$($r.Count) $($ui.TxtBenchScore.Text) | $($ui.TxtBenchState.Text)"
        Test-Smoke 'the run is in the protocol and the change log, services are back' (@($script:Protocol.Actions | Where-Object { $_.Category -eq 'benchmark' }).Count -ge 1 -and @(Get-AVDTuneChangeLog -Root $script:StateRoot | Where-Object { $_.Category -eq 'Benchmark' }).Count -ge 1) $null
        Save-SmokeShot '35-benchmark'
        $true } }
    @{ Name = 'benchmark comparison per image version (#90)'; Do = {
        if ($script:OverviewJob -or $script:ReadyJob -or $script:BenchJob) { return $false }   # the fake machine is not thread safe
        $click = { param($b) $b.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) }
        . $script:BenchFakeScript
        $keepVersion = (Get-AVDTuneState $script:StateRoot).ImageVersion
        foreach ($v in @(@('2026.11.901', 1.0), @('2026.11.902', 0.7))) {
            [void](Set-AVDTuneState -Root $script:StateRoot -Values @{ ImageVersion = $v[0] })
            [void](Invoke-AVDTuneBenchmark -Machine $script:Machine -Bench (New-AVDTuneFakeBench -Reference (Get-AVDTuneBenchmarkReference) -Config (Get-AVDTuneBenchmarkConfig) -Seed @{ Factor = $v[1] }) -Root $script:StateRoot -Mode Full -SkipIdleCheck -NoReport)
        }
        [void](Set-AVDTuneState -Root $script:StateRoot -Values @{ ImageVersion = $keepVersion })
        Show-Page 'Benchmark'; $window.UpdateLayout()
        $rows = @($ui.PanelBenchCompare.Children)
        Test-Smoke 'comparison: one row per image version, the newest on top, red with the word (not color alone) after a drop of 30 percent' ($ui.BoxBenchCompare.Visibility -eq 'Visible' -and $rows.Count -eq 2 -and (Find-Text $rows[0] '2026.11.902') -and (Find-Text $rows[0] (T 'bench.cmp.light.red')) -and (Find-Text $rows[1] '2026.11.901') -and $ui.TxtBenchCompareHint.Text -like '*10*') $rows.Count
        $script:BenchSmokeFile = Join-Path $env:AVDTUNE_SMOKE_OUT 'bench-compare.csv'
        & $click $ui.BtnBenchExportCsv
        $csvLines = @(Get-Content -LiteralPath $script:BenchSmokeFile)
        Test-Smoke 'comparison: CSV export with a header and one row per version, toast with the path' ($csvLines.Count -eq 3 -and $csvLines[0] -like 'Row,ImageVersion,*' -and $csvLines[2] -like '*"2026.11.902"*"red"' -and $script:LastToast -like '*bench-compare.csv*') ($csvLines -join ' | ')
        $script:BenchSmokeFile = Join-Path $env:AVDTUNE_SMOKE_OUT 'bench-compare.json'
        & $click $ui.BtnBenchExportJson
        $j = Get-Content -LiteralPath $script:BenchSmokeFile -Raw | ConvertFrom-Json
        Test-Smoke 'comparison: JSON export with the rows' ($j.schemaVersion -eq 1 -and @($j.rows).Count -eq 2) $null
        Save-SmokeShot '35b-benchmark-compare'
        $script:BenchSmokeFile = $null
        $true } }
    @{ Name = 'benchmark only (plan 6b, #90)'; Do = {
        if ($script:OverviewJob -or $script:ReadyJob -or ($script:RelJob -and [string]$script:RelJob.Kind -in 'Start', 'Check')) { return $false }
        $click = { param($b) $b.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) }
        if (-not $script:BenchOnlyStep) {
            $script:BenchOnlyStep = 1
            Enter-BenchmarkOnlyMode; $window.UpdateLayout()
            $shown = @($script:PageTable | Where-Object { $ui["Nav$($_.Key)"].Visibility -eq 'Visible' } | ForEach-Object { $_.Key })
            Show-Page 'Updates'
            Test-Smoke 'benchmark only: only Benchmark and Protocol in the navigation, any other page leads to the Benchmark page, no read-only banner, no version comparison, the system card' (($shown -join ',') -eq 'Benchmark,Protocol' -and $script:CurrentPage -eq 'Benchmark' -and $ui.PageBenchmark.Visibility -eq 'Visible' -and $ui.BoxReadOnly.Visibility -eq 'Collapsed' -and $ui.BoxBenchCompare.Visibility -eq 'Collapsed' -and $ui.BoxBenchOnly.Visibility -eq 'Visible') ($shown -join ',')
            # Finn (#90): no start while the integrity check runs (the release job, set here on the window thread: the timer cannot tick in between) or AVDTune is read only
            Test-Smoke 'integrity: the result of the integrity check is on the Benchmark page' ($ui.BoxBenchIntegrity.Visibility -eq 'Visible' -and $ui.TxtBenchIntegrity.Text -like ((T 'bench.rel.status' '*' '*').Split('*')[0] + '*')) $ui.TxtBenchIntegrity.Text
            $ui.TxtBenchSystemName.Text = 'Old RDS 2019'
            $keepRel = $script:RelJob; $script:RelJob = @{ Kind = 'Check' }
            try { & $click $ui.BtnBenchQuick; $refusedText = $script:LastToast; $pageText = $ui.TxtBenchIntegrity.Text } finally { $script:RelJob = $keepRel }
            Test-Smoke 'integrity: while the integrity check runs the benchmark does not start, the reason is in the toast and on the page' (-not $script:BenchJob -and $refusedText -like '*integrity check*still running*' -and $pageText -like '*still running*') "$refusedText | $pageText"
            # the desktop shortcut "AVDTune Benchmark" (like AVDTune.lnk, #15): only for an installed copy, into the test desktop
            $script:ShortcutTestMode = 'Installed'; Update-BenchShortcutRow
            & $click $ui.BtnBenchShortcut
            $bl = Get-AVDTuneDesktopShortcut -Folder (Get-ShortcutDesktop) -InstallRoot $script:RelInstallRoot -Benchmark
            Test-Smoke 'benchmark shortcut: created in the test desktop with -Benchmark, run as administrator; the button offers Remove' ($bl -and $bl.Matches -and $bl.RunAs -and $bl.Arguments.EndsWith(' -Benchmark') -and [string]$ui.BtnBenchShortcut.Content -eq (T 'bench.sc.remove') -and (Get-ShortcutDesktop) -like "$($script:StateRoot)*") ($bl | Out-String)
            & $click $ui.BtnBenchShortcut
            Test-Smoke 'benchmark shortcut: Remove deletes it again' (-not (Get-AVDTuneDesktopShortcut -Folder (Get-ShortcutDesktop) -Benchmark) -and [string]$ui.BtnBenchShortcut.Content -eq (T 'bench.sc.create')) $null
            $script:ShortcutTestMode = 'Development'; Update-BenchShortcutRow
            $ui.TxtBenchSystemName.Text = ''
            & $click $ui.BtnBenchQuick
            Test-Smoke 'benchmark only: without a system name nothing starts' (-not $script:BenchJob -and $script:LastToast -like '*name missing*') $script:LastToast
            $ui.TxtBenchSystemName.Text = 'Old RDS 2019'; $ui.TxtBenchSystemNotes.Text = 'replaced by AVD'
            & $click $ui.BtnBenchQuick
            Test-Smoke 'benchmark only: a quick run starts with the name' ([bool]$script:BenchJob) $script:LastToast
            Save-SmokeShot '35c-benchmark-only'
            return $false
        }
        if ($script:BenchJob) { return $false }
        $last = @(Get-AVDTuneBenchmarkResult -Root $script:StateRoot -Last)[0]
        Test-Smoke 'benchmark only: the result is of kind benchmark-only with the name and no image version' ($last.kind -eq 'benchmark-only' -and $last.system.name -eq 'Old RDS 2019' -and $last.system.notes -eq 'replaced by AVD' -and $last.system.imageVersion -eq '') ($last | ConvertTo-Json -Depth 2 -Compress)
        $script:BenchSmokeFile = Join-Path $env:AVDTUNE_SMOKE_OUT 'bench-old-rds.json'
        & $click $ui.BtnBenchExportResult
        Test-Smoke 'benchmark only: the result file is exported and passes the result check' ((Test-Path -LiteralPath $script:BenchSmokeFile) -and @(Test-AVDTuneBenchmarkResult -Result (Get-Content -LiteralPath $script:BenchSmokeFile -Raw | ConvertFrom-Json)).Count -eq 0) $script:LastToast
        # back to the Golden Master (only the smoke does this): the file is imported there as comparison system
        $script:BenchmarkOnly = $false; Update-NavVisibility; Show-Page 'Benchmark'; $window.UpdateLayout()
        & $click $ui.BtnBenchImport; $window.UpdateLayout()
        $sysRow = @($script:BenchCompare.Systems)
        Test-Smoke 'import: the result file is a comparison system on the master, listed below the versions' ($sysRow.Count -eq 1 -and $sysRow[0].SystemName -eq 'Old RDS 2019' -and (Find-Text $ui.PanelBenchCompare 'Old RDS 2019') -and $script:LastToast -like '*Old RDS 2019*') $script:LastToast
        & $click $ui.BtnBenchImport
        Test-Smoke 'import: the same file twice is refused' ($script:LastToast -like '*imported already*' -and @($script:BenchCompare.Systems).Count -eq 1) $script:LastToast
        $script:BenchSmokeFile = $null
        Show-Page 'Overview'
        $true } }
    @{ Name = 'language page'; Do = {
        if ($script:OverviewJob -or $script:ReadyJob) { return $false }   # the fake machine is not thread safe
        $click = { param($b) $b.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) }
        if (-not $script:LangSmoke) {
            $script:LangSmoke = 1
            Show-Page 'Language'; $window.UpdateLayout()
            $en = $script:LangChecks['en-US']; $de = $script:LangChecks['de-DE']
            Test-Smoke 'Language page: own page (no placeholder), nav entry "Language and region", 18 languages to tick' ($ui.PageLanguage.Visibility -eq 'Visible' -and $ui.PagePlaceholder.Visibility -eq 'Collapsed' -and $ui.NavLanguage.IsChecked -and $script:LangChecks.Count -eq 18 -and (Find-Text $ui.NavList 'Language and region')) $script:LangChecks.Count
            Test-Smoke 'Language page: the installed language is ticked and fixed, the others are free' ($en.IsChecked -and -not $en.IsEnabled -and $de.IsEnabled -and -not $de.IsChecked -and (Find-Text $ui.PanelLangInstalled 'en-US  English (United States)   Basic')) $null
            $sel = { param($k) $script:LangCombos[$k].SelectedItem.Tag }
            Test-Smoke 'Language page: defaults are preselected with the values of the image (en-US, US keyboard, United States, system locale en-US)' ((& $sel 'Ui') -eq 'en-US' -and (& $sel 'Culture') -eq 'en-US' -and (& $sel 'InputTip') -eq '0409:00000409' -and (& $sel 'GeoId') -eq 244 -and (& $sel 'SystemLocale') -eq 'en-US') $null
            Test-Smoke 'Language page: the time zone stays on (keep as it is); the Azure region (West Europe) is only suggested, in the list and next to it' ($null -eq (& $sel 'TimeZone') -and @($script:LangCombos.TimeZone.Items | Where-Object { $_.Tag -eq 'W. Europe Standard Time' -and "$($_.Content)" -like '*suggested*westeurope*' }).Count -eq 1 -and $ui.LangNow.TimeZone.Text -like '*westeurope*suggests W. Europe Standard Time*') $ui.LangNow.TimeZone.Text
            Test-Smoke 'Language page: the display language list offers the missing languages only with the offer to install them first' (@($script:LangCombos.Ui.Items | Where-Object { $_.Tag -eq 'de-DE' -and "$($_.Content)" -like '*not installed*install*first*' }).Count -eq 1 -and @($script:LangCombos.Ui.Items | Where-Object { $_.Tag -eq 'en-US' -and "$($_.Content)" -notlike '*not installed*' }).Count -eq 1) $null
            Save-SmokeShot '31-language'
            & $click $ui.BtnLangTest
            Test-Smoke 'Language page: Test changes nothing and says so' ($ui.TxtLangState.Text -like 'Tested*Nothing was changed*' -and @($script:LangFake.Log | Where-Object { $_ -like 'SetUserIntl*' -or $_ -like 'AddLanguage*' }).Count -eq 0) $ui.TxtLangState.Text
            # choose German for everything, not installed yet: Apply offers to install it first
            $de.IsChecked = $true
            $ui.TxtLangSource.Text = 'E:\'
            foreach ($pair in @(@('Ui', 'de-DE'), @('Culture', 'de-DE'), @('InputTip', '0407:00000407'), @('GeoId', 94), @('SystemLocale', 'de-DE'))) { $cb = $script:LangCombos[$pair[0]]; $cb.SelectedItem = @($cb.Items | Where-Object { "$($_.Tag)" -eq "$($pair[1])" })[0] }
            $script:ConfirmAsked = ''
            & $click $ui.BtnLangApply
            Test-Smoke 'Language page: Apply with a missing display language asks to install it first and names what cannot be undone, the restart, the kind of source and every change old -> new' ($script:ConfirmAsked -like '*Install*read-only media*CANNOT be undone*restart*Display language: en-US -> de-DE*Regional format: en-US -> de-DE*Location (GeoId): 244 -> 94*System locale: en-US -> de-DE*' -and $script:ConfirmAsked -notlike '*Time zone:*' -and $script:LangJob) $script:ConfirmAsked
            return $false
        }
        if ($script:LangJob) { return $false }
        if ($script:LangSmoke -eq 2) {
            Test-Smoke 'Language page: Undo puts the values of the image back; the installed language stays' ((Get-AVDTuneLanguageNewUser $script:Machine).Ui -eq 'en-US' -and $script:LangFake.Store.Installed -contains 'de-DE') $null
            return $true
        }
        $window.UpdateLayout()
        $nu = Get-AVDTuneLanguageNewUser $script:Machine
        Test-Smoke 'Language page: language installed from the folder, new users get German (display language, format, keyboard, location), time zone and system locale set' ($script:LangFake.Store.Installed -contains 'de-DE' -and $nu.Ui -eq 'de-DE' -and $nu.Culture -eq 'de-DE' -and $nu.InputTip -eq '0407:00000407' -and $nu.GeoId -eq 94 -and (Get-AVDTuneLanguageState -Machine $script:Machine -L $script:LangFake).SystemLocale -eq 'de-DE') ($nu | ConvertTo-Json -Compress)
        Test-Smoke 'Language page: the page shows the result, de-DE is now installed and fixed, the task finished' ($ui.TxtLangState.Text -like 'Language and region:*change*restart*' -and -not $script:LangChecks['de-DE'].IsEnabled -and @(Get-AVDTuneUiTasks | Where-Object { $_.Kind -eq 'language-all' -and $_.Status -eq 'succeeded' }).Count -eq 1) $ui.TxtLangState.Text
        if ($script:LangSmoke -eq 1) { $script:LangSmoke = 2; & $click $ui.BtnLangUndo; return $false }
        $true } }
    @{ Name = 'vdi page: session host cards (#77)'; Do = {
        if ($script:OverviewJob -or $script:ReadyJob -or $script:LangJob -or $script:VdiJob) { return $false }   # the fake machine is not thread safe; the VDI job completes on the window timer
        $click = { param($b) $b.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) }
        $tsKey = 'hklm:\software\policies\microsoft\windows nt\terminal services|selecttransport'
        $pillText = { param($k) [string]$script:VdiCards[$k].PillHost.Content.Child.Text }
        if (-not $script:VdiHostSmoke) {
            $script:VdiHostSmoke = 1
            $script:Machine.Store.Registry[$tsKey] = 1   # "Use only TCP"
            Show-Page 'VdiComponents'; $window.UpdateLayout()
            & $click $ui.BtnVdiTest
            $window.UpdateLayout()
            Test-Smoke 'VDI page (#77): three session host cards after the components (RDP Shortpath, time zone redirection, Defender for Endpoint); only Shortpath has buttons' ($script:VdiCards.ContainsKey('shortpath') -and $script:VdiCards.ContainsKey('timezone') -and $script:VdiCards.ContainsKey('mde') -and $script:VdiCards['shortpath'].Buttons.Count -eq 2 -and $script:VdiCards['timezone'].Buttons.Count -eq 0 -and $script:VdiCards['mde'].Buttons.Count -eq 0 -and $ui.PanelVdiCards.Children.Count -eq 7 -and (Find-Text $ui.PanelVdiCards 'Defender for Endpoint (non-persistent VDI)')) "$($ui.PanelVdiCards.Children.Count) cards"
            Test-Smoke 'VDI page (#77): Test shows Shortpath "Use only TCP" as Check open, the rows of all three cards are there, nothing was changed' ((& $pillText 'shortpath') -eq 'Check open' -and $script:VdiCards['shortpath'].Rows.Children.Count -eq 5 -and $script:VdiCards['timezone'].Rows.Children.Count -eq 2 -and $script:VdiCards['mde'].Rows.Children.Count -eq 4 -and $script:Machine.Store.Registry[$tsKey] -eq 1 -and $ui.TxtVdiState.Text -like 'Tested*') "$(& $pillText 'shortpath') / $($ui.TxtVdiState.Text)"
            Save-SmokeShot '32-vdi-host-cards'
            $script:ConfirmAsked = ''
            & $click $script:VdiCards['shortpath'].Buttons.Settings
            Test-Smoke 'VDI page (#77): Set recommended settings asks first with old -> new and the restart, then runs as a VDI task' ($script:ConfirmAsked -like '*SelectTransport: 1 -> not set*Restart*' -and $script:VdiJob -and $script:VdiJob.Kind -eq 'HostSettings') $script:ConfirmAsked
            return $false
        }
        if ($script:VdiHostSmoke -eq 1) {
            Wait-SmokeIdle
            Test-Smoke 'VDI page (#77): the setting is applied: value removed, pill As recommended, change log VDI, the task finished' (-not $script:Machine.Store.Registry.ContainsKey($tsKey) -and (& $pillText 'shortpath') -ne 'Check open' -and $ui.TxtVdiState.Text -like 'RDP Shortpath: 1 changed*Restart*' -and @(Get-AVDTuneChangeLog -Root $script:StateRoot | Where-Object { $_.Category -eq 'VDI' -and $_.Component -eq 'RDP Shortpath' }).Count -ge 1 -and @(Get-AVDTuneUiTasks | Where-Object { $_.Kind -eq 'vdi-hostsettings' -and $_.Status -eq 'succeeded' }).Count -eq 1) "$(& $pillText 'shortpath') / $($ui.TxtVdiState.Text)"
            $script:VdiHostSmoke = 2
            Wait-SmokeIdle   # the finished task starts an overview refresh; the Undo click must not read the fake machine at the same time (#80)
            $script:ConfirmAsked = ''
            & $click $script:VdiCards['shortpath'].Buttons.SettingsUndo
            Test-Smoke 'VDI page (#77): Undo settings asks first with not set -> 1' ($script:ConfirmAsked -like '*SelectTransport: not set -> 1*' -and $script:VdiJob) $script:ConfirmAsked
            return $false
        }
        Test-Smoke 'VDI page (#77): Undo puts "Use only TCP" back (the value found before) and the pill shows it again' ($script:Machine.Store.Registry[$tsKey] -eq 1 -and (& $pillText 'shortpath') -eq 'Check open' -and $ui.TxtVdiState.Text -like 'RDP Shortpath: 1 undone*') "$(& $pillText 'shortpath') / $($ui.TxtVdiState.Text)"
        $script:Machine.Store.Registry.Remove($tsKey)
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
        $reg[$pk + 'enabled'] = 1; $reg[$pk + 'vhdlocations'] = @('\\storageaccount.file.core.windows.net\profiles'); $reg[$pk + 'volumetype'] = 'vhd'; $reg[$pk + 'lockedretrycount'] = 12; $reg[$pk + 'sizeinmbs'] = 30000
        $reg[$pk + 'lockedretyinterval'] = 5   # a typo, to be found by the test
        $script:Machine.Store.Services['frxsvc'] = [pscustomobject]@{ Name = 'frxsvc'; Status = 'Running'; StartType = 'Automatic' }
        $script:Machine.Store.Native[(Join-Path (Get-AVDTuneSystemFolder System) 'fltmc.exe') + ' filters'] = @{ ExitCode = 0; Output = "Filter Name  Num Instances  Altitude  Frame`r`nfrxdrv  3  135000  0`r`nfrxdrvvt  3  135100  0`r`n" }
        $script:Machine.Store.Native['*frx.exe create-vhd *'] = @{ ExitCode = 0; Output = 'created' }; $script:Machine.Store.Native['*frx.exe begin-edit-profile *'] = @{ ExitCode = 0; Output = 'cookie: 4876' }; $script:Machine.Store.Native['*frx.exe end-edit-profile *'] = @{ ExitCode = 0; Output = 'ok' }
        $script:FslFake.F.Store.Defender = @{ Paths = @('C:\Program Files\FSLogix\Apps\', 'C:\ProgramData\FSLogix\'); Processes = @('frxsvc.exe') }
        $script:SmokeTasksSeen = @(Get-AVDTuneUiTasks)   # kept for the check of the earlier flows (the list holds the newest 100)
        $fslDone = { Complete-FslJob; Complete-SmokeFslRead; $window.UpdateLayout() }   # #72: a change runs as a job and the page reads the master again after it; in test mode both run inline and are taken over here instead of on the timer
        $fslRead = { Start-FslRead; Complete-SmokeFslRead; $window.UpdateLayout() }   # read again after the fake master was changed by the smoke (like opening the page again)
        Show-Page 'FSLogix'; $window.UpdateLayout()
        $rt = @(Get-AVDTuneUiTasks | Where-Object { $_.Kind -eq 'fslogix-read' })
        $refused = try { Assert-FslFresh; $false } catch { $_.Exception.Message -like '*still being read*' }
        Test-Smoke 'FSLogix page (#72): the page is there at once, the read of the master runs as a task with Retry, changes are locked and refused until it is done' ($script:FslReadJob -and $rt.Count -ge 1 -and $rt[-1].Status -eq 'running' -and $rt[-1].Retry.Command -eq 'Start-FslRead' -and -not $ui.BtnFslSettingsApply.IsEnabled -and -not $ui.BtnFslDefAdd.IsEnabled -and $refused) "tasks=$($rt.Count) refused=$refused"
        Complete-SmokeFslRead; $window.UpdateLayout()
        $rt = @(Get-AVDTuneUiTasks | Where-Object { $_.Kind -eq 'fslogix-read' })
        Test-Smoke 'FSLogix page (#72): after the read the task is done and the changes are open' (-not $script:FslReadJob -and $rt[-1].Status -eq 'succeeded' -and $ui.BtnFslSettingsApply.IsEnabled -and $ui.BtnFslDefAdd.IsEnabled -and $script:FslState) $rt[-1].Summary
        Test-Smoke 'FSLogix page: own page (no placeholder), the nav item is checked' ($ui.PageFSLogix.Visibility -eq 'Visible' -and $ui.PagePlaceholder.Visibility -eq 'Collapsed' -and $ui.NavFSLogix.IsChecked) $null
        Test-Smoke 'installation card: installed version, service and drivers' ($ui.TxtFslVersion.Text -like '*2.9.8884.27471*frxsvc Running*frxdrv*' -and $ui.TxtFslInstallPill.Text -eq 'Update available: 26.08') $ui.TxtFslVersion.Text
        # issue 63: the status pill against the newest release (the fake release is 26.08): older yellow, newer green, not readable grey
        $pillYellow = ($ui.TxtFslInstallPill.Text -eq 'Update available: 26.08' -and $ui.PillFslInstall.ToolTip -like '*older than the release 26.08*')
        $script:Machine.Store.Registry['hklm:\software\fslogix\apps|installversion'] = '3.27.101.12345'; $script:FslLatestResult = $null; & $fslRead
        $pillGreen = ($ui.TxtFslInstallPill.Text -eq 'Installed, up to date')
        $script:FslFake.F.Store.Latest = @{ Ok = $false; Url = ''; Error = 'fake: no connection' }; $script:FslLatestResult = $null; & $fslRead
        $pillGrey = ($ui.TxtFslInstallPill.Text -eq 'Installed, newest version unknown' -and $ui.PillFslInstall.ToolTip -like '*fake: no connection*' -and $ui.TxtFslLatest.Text -like '*fake: no connection*')
        $script:Machine.Store.Registry['hklm:\software\fslogix\apps|installversion'] = '2.9.8884.27471'
        $script:FslFake.F.Store.Latest = @{ Ok = $true; Url = 'https://download.microsoft.com/download/00000000-0000-0000-0000-000000000000/FSLogix_26.08.zip'; Error = '' }; $script:FslLatestResult = $null; & $fslRead
        Test-Smoke 'status pill (#63): older = yellow with the new version, newer = green, newest not readable = grey with the reason; no download ran' ($pillYellow -and $pillGreen -and $pillGrey -and $ui.TxtFslInstallPill.Text -eq 'Update available: 26.08' -and @($script:FslFake.F.Log | Where-Object { $_ -like 'Download*' }).Count -eq 0) "$pillYellow $pillGreen $pillGrey"
        Test-Smoke 'settings: every setting of the plan as a row with its recommendation and reason, differing values marked' ($script:FslInputs.Count -ge 19 -and (Find-Text $ui.PanelFslSettings 'LockedRetryCount') -and (Find-Text $ui.PanelFslSettings 'Differs') -and (Find-Text $ui.PanelFslSettings 'Office container (ODFC), optional')) $script:FslInputs.Count
        Save-SmokeShot '50-fslogix-top-light'
        $domSidSmoke = 'S-1-5-21-1111111111-2222222222-333333333'
        $script:FslFake.F.Store.MasterDomainSid = $domSidSmoke; & $fslRead   # the domain SID this (fake) master resolves for <NetBIOS>\Domain Admins (read again: the confirmation names what the read found)
        # fill in the recommendation, dry run first, then write behind the gate
        $ui.BtnFslFill.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        $ui.BtnFslSettingsTest.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Test-Smoke 'Test: shows what would change and writes nothing' ($ui.TxtFslSettingsState.Text -like 'Test (nothing written)*lockedretrycount*' -and (& $script:Machine.RegGet 'HKLM:\SOFTWARE\FSLogix\Profiles' 'LockedRetryCount') -eq 12 -and @(Get-AVDTuneRun -Root $script:StateRoot | Where-Object Plan -like 'FSLogix*').Count -eq 0) $ui.TxtFslSettingsState.Text
        $ui.BtnFslSettingsApply.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))); & $fslDone
        Test-Smoke 'Apply: the confirmation names the count, the registry has the recommended values, LastChange shown, change log written' ($script:ConfirmAsked -like 'Write * FSLogix setting*' -and (& $script:Machine.RegGet 'HKLM:\SOFTWARE\FSLogix\Profiles' 'LockedRetryCount') -eq 3 -and (& $script:Machine.RegGet 'HKLM:\SOFTWARE\FSLogix\Profiles' 'VolumeType') -eq 'vhdx' -and $ui.TxtFslSettingsState.Text -like 'LastChange:*' -and @(Get-AVDTuneChangeLog -Root $script:StateRoot | Where-Object Category -eq 'FSLogix').Count -ge 3) "$($script:ConfirmAsked) / $($ui.TxtFslSettingsState.Text)"
        Test-Smoke 'Apply (#62): the same confirmation names the list changes (exclude local Administrators and Domain Admins with DNS name and SID; include already has Everyone and is not mentioned)' ($script:ConfirmAsked -like 'Write * FSLogix setting*Also: Exclude + BUILTIN\Administrators (S-1-5-32-544), + *\Domain Admins (' + $domSidSmoke + '-512)*' -and $script:ConfirmAsked -notlike '*Include*' -and $script:FslFake.F.Store.Groups['FSLogix Profile Exclude List'] -contains ($domSidSmoke + '-512')) $script:ConfirmAsked
        Test-Smoke 'the change is in the protocol (category FSLogix)' (@($script:Protocol.Actions | Where-Object { $_.Category -eq 'fslogix' }).Count -ge 1) $null
        $tk = @(Get-AVDTuneUiTasks | Where-Object { $_.Kind -eq 'fslogix-settings' })
        Test-Smoke 'task bar: applying the settings is a task, ended as succeeded, no Retry (a change of the master)' ($tk.Count -eq 1 -and $tk[0].Status -eq 'succeeded' -and -not $tk[0].Retry -and $tk[0].Title -like '*FSLogix settings*') ($tk | ForEach-Object { $_.Status })
        $ui.BtnFslSettingsUndo.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))); & $fslDone
        Test-Smoke 'Undo: the previous values are back' ((& $script:Machine.RegGet 'HKLM:\SOFTWARE\FSLogix\Profiles' 'LockedRetryCount') -eq 12 -and (& $script:Machine.RegGet 'HKLM:\SOFTWARE\FSLogix\Profiles' 'VolumeType') -eq 'vhd') $null
        $ui.BtnFslFill.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        $script:ConfirmAsked = ''
        $ui.BtnFslSettingsApply.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))); & $fslDone
        Test-Smoke 'Apply (#62): the lists are already as recommended, the confirmation does not mention them' ($script:ConfirmAsked -like 'Write * FSLogix setting*' -and $script:ConfirmAsked -notlike '*Also:*') $script:ConfirmAsked
        # groups
        $ui.CmbFslList.SelectedItem = 'Exclude'
        $ui.BtnFslExcludeAdmins.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))); & $fslDone
        Test-Smoke 'groups: the local Administrators are in the exclude list; the groups of the domain controller are offered' ($script:FslFake.F.Store.Groups['FSLogix Profile Exclude List'] -contains 'S-1-5-32-544' -and $ui.TxtFslGroups.Text -like '*S-1-5-32-544*' -and @($ui.CmbFslGroup.ItemsSource) -contains 'AVD-Users') $ui.TxtFslGroupHint.Text
        # recommended lists (issue 62): one button, the contents of both lists are checked, the foreign entry stays, Undo takes only what was added
        $domAdmins = 'S-1-5-21-1111111111-2222222222-333333333-512'
        $script:FslFake.F.Store.Groups['FSLogix Profile Exclude List'] = @('S-1-5-21-9-9-9-1234')
        $script:FslFake.F.Store.Groups['FSLogix Profile Include List'] = @()
        & $fslRead; $ui.BtnFslListsApply.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))); & $fslDone
        $exl = @($script:FslFake.F.Store.Groups['FSLogix Profile Exclude List']); $inl = @($script:FslFake.F.Store.Groups['FSLogix Profile Include List'])
        Test-Smoke 'Apply recommended lists: include = Everyone; exclude = local Administrators + Domain Admins (domain SID from the DC information) + the foreign entry; the lists text shows them' ($inl.Count -eq 1 -and $inl[0] -eq 'S-1-1-0' -and $exl -contains 'S-1-5-32-544' -and $exl -contains $domAdmins -and $exl -contains 'S-1-5-21-9-9-9-1234' -and $exl.Count -eq 3 -and $ui.TxtFslGroups.Text -like "*$domAdmins*" -and $ui.TxtFslGroups.Text -like '*S-1-5-21-9-9-9-1234*' -and $script:ConfirmAsked -like '*Include + Everyone*' -and $script:ConfirmAsked -like "*Domain Admins ($domAdmins)*") "$($exl -join ',') / $($inl -join ',') / $($script:ConfirmAsked)"
        $ui.BtnFslListsUndo.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))); & $fslDone
        $exl2 = @($script:FslFake.F.Store.Groups['FSLogix Profile Exclude List'])
        Test-Smoke 'Undo recommended lists: what was added is gone, the foreign entry stays' ($exl2.Count -eq 1 -and $exl2[0] -eq 'S-1-5-21-9-9-9-1234' -and @($script:FslFake.F.Store.Groups['FSLogix Profile Include List']).Count -eq 0) ($exl2 -join ',')
        $script:FslFake.F.Store.MasterDomainSid = 'S-1-5-21-4-4-4'
        $script:FslFake.F.Store.Groups['FSLogix Profile Exclude List'] = @(); $script:FslFake.F.Store.Groups['FSLogix Profile Include List'] = @()
        $script:ConfirmAsked = ''
        & $fslRead; $ui.BtnFslListsApply.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))); & $fslDone
        $exm = @($script:FslFake.F.Store.Groups['FSLogix Profile Exclude List'])
        Test-Smoke 'Apply recommended lists, master of another domain (#62): no Domain Admins exclude, the dialog and the hint say why' ($exm.Count -eq 1 -and $exm[0] -eq 'S-1-5-32-544' -and $script:ConfirmAsked -notlike '*Domain Admins (*' -and $script:ConfirmAsked -like '*not the domain SID of this master (S-1-5-21-4-4-4)*' -and $ui.TxtFslState.Text -like '*not the domain SID of this master*') "$($exm -join ',') / $($script:ConfirmAsked)"
        $ui.BtnFslListsUndo.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))); & $fslDone
        $script:FslFake.F.Store.MasterDomainSid = $domSidSmoke
        & $fslRead; $ui.BtnFslListsApply.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))); & $fslDone
        $ui.CmbFslGroup.Text = 'not-a-group'
        $ui.BtnFslGroupAdd.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Test-Smoke 'a name that is no group and no SID is refused with the reason' ($script:LastToast -like '*neither a group of the domain nor a SID*') $script:LastToast
        # redirections.xml
        Test-Smoke 'redirections.xml (#68): the folder field is prefilled with <ProgramData>\AVDTune-Public\FSLogix\Redirections when no folder is set in the registry' ($ui.TxtFslRedirFolder.Text -ceq (Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'AVDTune-Public\FSLogix\Redirections')) $ui.TxtFslRedirFolder.Text
        $ui.TxtFslRedirFolder.Text ='\\storageaccount.file.core.windows.net\profiles'
        $ui.BtnFslRedirGenerate.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        $ui.BtnFslRedirValidate.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Test-Smoke 'redirections.xml: generated from the template (Teams ticked), valid' ($ui.TxtFslRedirXml.Text -like '*MSTeams_8wekyb3d8bbwe*' -and $ui.TxtFslRedirState.Text -like 'Valid:*') $ui.TxtFslRedirState.Text
        $good = $ui.TxtFslRedirXml.Text
        $ui.TxtFslRedirXml.Text = $good.Replace('</Excludes>', '<Exclude Copy="0">AppData\Local\Microsoft\TokenBroker\Cache</Exclude></Excludes>')
        $ui.BtnFslRedirValidate.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Test-Smoke 'the token broker is refused with the single sign-on reason' ($ui.TxtFslRedirState.Text -like 'Not valid:*single sign-on*') $ui.TxtFslRedirState.Text
        $ui.BtnFslRedirSave.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))); & $fslDone
        Test-Smoke 'saving that text is refused, nothing is written' ($script:LastToast -like '*not valid*' -and -not $script:FslFake.F.Store.Files.ContainsKey('\\storageaccount.file.core.windows.net\profiles\redirections.xml')) $script:LastToast
        $tk = @(Get-AVDTuneUiTasks | Where-Object { $_.Kind -eq 'fslogix-redirections' })
        Test-Smoke 'task bar: the refused redirections.xml is a failed task with the cause, no Retry' ($tk.Count -eq 1 -and $tk[0].Status -eq 'failed' -and $tk[0].Summary -like '*not valid*' -and -not $tk[0].Retry) ($tk | ForEach-Object { $_.Status + ' ' + $_.Summary })
        $ui.TxtFslRedirXml.Text = $good
        $ui.BtnFslRedirSave.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))); & $fslDone
        Test-Smoke 'redirections.xml saved to the folder, the folder is in the registry' ($script:FslFake.F.Store.Files['\\storageaccount.file.core.windows.net\profiles\redirections.xml'] -ceq $good -and (& $script:Machine.RegGet 'HKLM:\SOFTWARE\FSLogix\Profiles' 'RedirXMLSourceFolder') -eq '\\storageaccount.file.core.windows.net\profiles') $null
        $tk = @(Get-AVDTuneUiTasks | Where-Object { $_.Kind -eq 'fslogix-redirections' })
        Test-Smoke 'task bar: the saved redirections.xml is a second task, succeeded' ($tk.Count -eq 2 -and $tk[1].Status -eq 'succeeded') ($tk | ForEach-Object { $_.Status })
        # Defender: one exclusion unticked (a folder with a risk note) is not set; ticking it again and adding sets it
        $defKey = 'C:\Users\*\AppData\Local\FSLogix\'
        $defRow = @($ui.PanelFslDefender.Children | Where-Object { $_.Children[0].Tag -eq $defKey })
        $defRow[0].Children[0].IsChecked = $false
        $ui.BtnFslDefAdd.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))); & $fslDone
        Test-Smoke 'Defender: the unticked exclusion is not set (still Missing and unticked after the list is drawn again), the others are' ($defRow.Count -eq 1 -and $script:ConfirmAsked -like '*1 are unticked*' -and $script:FslFake.F.Store.Defender.Paths -notcontains $defKey -and $script:FslFake.F.Store.Defender.Processes -contains 'C:\Program Files\FSLogix\Apps\frxccds.exe' -and @($ui.PanelFslDefender.Children | Where-Object { $_.Children[0].Tag -eq $defKey -and $_.Children[0].IsChecked -eq $false -and $_.Children[0].IsEnabled }).Count -eq 1) "$($script:ConfirmAsked) / $($defRow.Count)"
        $tk = @(Get-AVDTuneUiTasks | Where-Object { $_.Kind -eq 'fslogix-defender' })
        Test-Smoke 'task bar: the Defender exclusions are a task, succeeded, no Retry' ($tk.Count -eq 1 -and $tk[0].Status -eq 'succeeded' -and -not $tk[0].Retry) ($tk | ForEach-Object { $_.Status })
        @($ui.PanelFslDefender.Children | Where-Object { $_.Children[0].Tag -eq $defKey })[0].Children[0].IsChecked = $true
        # Defender
        $ui.BtnFslDefAdd.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))); & $fslDone
        Test-Smoke 'Defender: the missing exclusions are added, the list says all are set' ($ui.TxtFslDefState.Text -like '* of * exclusions are set.*' -and @((Get-AVDTuneFSLogixDefenderState -F $script:FslFake.F -VhdLocations @('\\storageaccount.file.core.windows.net\profiles')).Items | Where-Object { -not $_.Present }).Count -eq 0 -and $script:FslFake.F.Store.Defender.Processes -contains 'C:\Program Files\FSLogix\Apps\frxccds.exe') $ui.TxtFslDefState.Text
        Show-Page 'FSLogix'; Complete-SmokeFslRead; $window.UpdateLayout()
        $sv = $ui.PageFSLogix.Children[0]
        $sv.ScrollToVerticalOffset(1100); $window.UpdateLayout(); Save-SmokeShot '51-fslogix-groups-redirections-light'
        $sv.ScrollToVerticalOffset(2400); $window.UpdateLayout(); Save-SmokeShot '52-fslogix-defender-light'
        $sv.ScrollToVerticalOffset(0)
        $true } }
    @{ Name = 'fslogix: function test'; Do = {
        if ($script:OverviewJob -or $script:ReadyJob -or $script:ReadyQueued -or $script:FslJob -or $script:FslReadJob) { return $false }
        if (-not $script:FslTestStep) {
            $script:FslTestStep = 1
            $script:FslFake.F.Store.Acl = @{ '\\storageaccount.file.core.windows.net\profiles' = 'O:BAG:DUD:PAI(A;OICI;FA;;;WD)(A;OICI;FA;;;BA)' }
            $ui.BtnFslTest.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
            return $false
        }
        $window.UpdateLayout()
        $r = $script:FslTest
        Test-Smoke 'function test ran: result stored in the state, run record, change log note' ($r -and (Get-AVDTuneState $script:StateRoot).FSLogixTest.Overall -eq $r.Overall -and @(Get-AVDTuneRun -Root $script:StateRoot | Where-Object Plan -eq 'FSLogix-Test').Count -eq 1 -and @(Get-AVDTuneChangeLog -Root $script:StateRoot | Where-Object Component -eq 'FSLogix-Test').Count -eq 1) $null
        $tk = @(Get-AVDTuneUiTasks | Where-Object { $_.Kind -eq 'fslogix-test' })
        Test-Smoke 'task bar: the function test is a task, succeeded; its log is clean of secrets' ($tk.Count -ge 1 -and $tk[0].Status -eq 'succeeded' -and $tk[0].Summary -like '*function test*' -and $tk[0].Title -eq 'FSLogix function test') ($tk | ForEach-Object { $_.Status + ' ' + $_.Title })
        Test-Smoke 'the typo in the registry is found (yellow); the write tests did not run (info); the real sign-in is info' ((@($r.Rows | Where-Object Id -eq 'fs.registry')[0].Status -eq 'yellow') -and (@($r.Rows | Where-Object Id -eq 'fs.loc1.rw')[0].Status -eq 'info') -and (@($r.Rows | Where-Object Id -eq 'fs.logon')[0].Status -eq 'info') -and @($script:FslFake.F.Log | Where-Object { $_ -like 'ShareWriteTest*' }).Count -eq 0) ((@($r.Rows | Where-Object Id -eq 'fs.registry')[0].Reason))
        Test-Smoke 'the card shows the pill, the counts and one row per check' ($ui.TxtFslTestSummary.Text -like '*without the write tests*' -and $ui.PanelFslTest.Children.Count -eq @($r.Rows).Count) "$($ui.TxtFslTestPill.Text) $($ui.PanelFslTest.Children.Count)"
        Test-Smoke 'the healthcheck follows: the readiness analysis has the FSLogix-Test row' ($script:Ready -and @($script:Ready.Rows | Where-Object Id -eq 'hy.fslogix-test').Count -eq 1) $null
        $sv = $ui.PageFSLogix.Children[0]; Show-Page 'FSLogix'; Complete-SmokeFslRead; $window.UpdateLayout()
        $sv.ScrollToVerticalOffset(3000); $window.UpdateLayout(); Save-SmokeShot '53-fslogix-test-light'
        $script:ConfirmAsked = ''
        $ui.BtnFslTestWrite.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Test-Smoke 'the write tests ask first and say what they create' ($script:ConfirmAsked -like '*test folder*VHDX*') $script:ConfirmAsked
        $script:FslTestStep = 2
        $true } }
    @{ Name = 'fslogix: write tests and a red result'; Do = {
        if ($script:OverviewJob -or $script:ReadyJob -or $script:ReadyQueued -or $script:FslJob -or $script:FslReadJob) { return $false }
        if ($script:FslTestStep -eq 2) {
            $script:FslTestStep = 3
            $r = $script:FslTest
            Test-Smoke 'write tests: folder test and the frx VHDX test ran (create, attach, detach)' ($r.WriteTests -and @($script:FslFake.F.Log | Where-Object { $_ -like 'ShareWriteTest*' }).Count -eq 1 -and @($script:Machine.Log | Where-Object { $_ -like '*frx.exe end-edit-profile -cookie 4876*' }).Count -ge 1) $null
            $script:FslFake.F.Store.Dns = @{ 'storageaccount.file.core.windows.net' = @{ Ok = $false; Addresses = @(); Error = 'No such host is known' } }
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
        if ($script:OverviewJob -or $script:ReadyJob -or $script:ReadyQueued -or $script:FslJob -or $script:FslReadJob) { return $false }
        if (-not $script:FslStorageStep) {
            $script:FslStorageStep = 1
            $ad = @{ domainName = 'example.test'; netBiosDomainName = 'EXAMPLE'; forestName = 'example.test'; domainGuid = '11111111-2222-3333-4444-555555555555'; domainSid = 'S-1-5-21-1-2-3'; azureStorageSid = 'S-1-5-21-1-2-3-1500'; samAccountName = 'storageaccount'; accountType = 'Computer' }
            $script:FslFake.Arm.Store.Accounts = @(@{ Name = 'storageaccount'; Rg = 'rg-example'; Kind = 'FileStorage'; Sku = 'Premium_LRS'
                    Props = @{ azureFilesIdentityBasedAuthentication = @{ directoryServiceOptions = 'AD'; defaultSharePermission = 'StorageFileDataSmbShareContributor'; activeDirectoryProperties = $ad }; privateEndpointConnections = @(@{ id = 'pe1' }); publicNetworkAccess = 'Disabled' }
                    FileService = @{ versions = 'SMB3.1.1'; authenticationMethods = 'Kerberos'; kerberosTicketEncryption = 'RC4-HMAC;AES-256'; channelEncryption = 'AES-256-GCM' } })
            $script:FslFake.Ldap.Store.Account = @{ Sam = 'storageaccount'; Sid = 'S-1-5-21-1-2-3-1500'; Spns = @('cifs/storageaccount.file.core.windows.net'); PwdLastSet = (Get-Date).AddDays(-35); Uac = 4096; EncTypes = $null }
            $script:FslFake.Files.Store.Acls = @{ '' = 'O:BAG:DUD:PAI(A;OICI;FA;;;WD)(A;OICI;FA;;;BA)' }; $script:FslFake.Files.Store.Folders = @()
            $ui.CmbFslUsersGroup.Text = 'AVD-Users'; $ui.CmbFslAdminsGroup.Text = 'AVD-Admins'; $ui.TxtFslDc.Text = '10.0.0.10'; $ui.TxtFslUser.Text = 'EXAMPLE\test.user'; $ui.PwdFslPassword.Password = 'smoke-test-password-1'
            $ui.BtnFslStorage.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
            return $false
        }
        $window.UpdateLayout()
        $r = $script:FslStorage
        $by = @{}; foreach ($x in $r.Rows) { $by[$x.Id] = $x }
        Test-Smoke 'storage check ran with the fake Azure: account found, identity AD, only GET against ARM' ($r -and $by['st.account'].Status -eq 'green' -and $by['st.identity'].Status -eq 'green' -and @($script:FslFake.Arm.Log | Where-Object { $_ -notlike 'GET *' }).Count -eq 0) (@($r.Rows | ForEach-Object { "$($_.Id)=$($_.Status)" }) -join ' ')
        $tk = @(Get-AVDTuneUiTasks | Where-Object { $_.Kind -eq 'fslogix-storage' })
        Test-Smoke 'task bar: the storage check is a task, succeeded, and the password and key never reach its texts' ($tk.Count -ge 1 -and $tk[0].Status -eq 'succeeded' -and $tk[0].Summary -like 'Storage check:*' -and -not (@(Get-AVDTuneUiTaskLog $tk[0]) | Where-Object { $_.Text -match 'fake-arm-token|fake-storage-token|Password|AccountKey' })) ($tk | ForEach-Object { $_.Status + ' ' + $_.Summary })
        Test-Smoke 'password of the AD object almost expired (7 days): yellow with the rotation hint; RC4 allowed too: yellow; the ACL deviates: red with the diff offered' ($by['st.ad.password'].Status -eq 'yellow' -and $by['st.smb.kerberos'].Status -eq 'yellow' -and $by['st.acl.root'].Status -eq 'red' -and $r.AclDiff -and $ui.BtnFslAclSet.Visibility -eq 'Visible' -and $ui.TxtFslAclDiff.Text -like '*recommendation*') ($by['st.ad.password'].Reason)
        Test-Smoke 'the access test ran as the domain user; the password field is empty again and the key was not used' ($by['st.access'].Status -eq 'green' -and $ui.PwdFslPassword.Password -eq '' -and -not $r.KeyUsed -and $script:FslFake.Arm.Store.KeyRequests -eq 0) $by['st.access'].Reason
        Test-Smoke 'the result is stored, no password or token in the state folder' ((Get-AVDTuneState $script:StateRoot).StorageCheck.Account -eq 'storageaccount' -and ((Get-ChildItem $script:StateRoot -Recurse -File | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join "`n") -notmatch 'smoke-test-password-1|fake-storage-token|fake-arm-token') $null
        $sv = $ui.PageFSLogix.Children[0]; Show-Page 'FSLogix'; Complete-SmokeFslRead; $window.UpdateLayout()
        $sv.ScrollToVerticalOffset(99999); $window.UpdateLayout(); Save-SmokeShot '55-fslogix-storage-light'
        # set the ACL after the diff
        $ui.BtnFslAclSet.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))); Complete-FslJob; Complete-SmokeFslRead
        Test-Smoke 'set the recommended ACL: the confirmation names the diff, the share got it once with attributes preserved, the change log has it' ($script:ConfirmAsked -like '*recommended ACL*diff*' -and $script:FslFake.Files.Store.Puts.Count -eq 1 -and $script:FslFake.Files.Store.Puts[0].Attributes -eq 'preserve' -and @(Get-AVDTuneChangeLog -Root $script:StateRoot | Where-Object Component -eq 'Storage ACL').Count -eq 1) $ui.TxtFslState.Text
        $true } }
    @{ Name = 'office: content, dropdowns, preselection, fix buttons (#61)'; Do = {
        if ($script:OverviewJob -or $script:ReadyJob -or $script:ReadyQueued -or $script:FslJob -or $script:OffJob) { return $false }
        $click = { param($b) $b.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) }
        $fixButtons = { $found = New-Object System.Collections.ArrayList; $walk = $null; $walk = { param($p) for ($i = 0; $i -lt [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($p); $i++) { $c = [System.Windows.Media.VisualTreeHelper]::GetChild($p, $i); if (($c -is [System.Windows.Controls.Button]) -and $c.DataContext) { [void]$found.Add($c) }; & $walk $c } }; & $walk $ui.PanelOffRows; @($found) }
        $checked = { param($panel) @($panel.Children | Where-Object { $_.IsChecked } | ForEach-Object { [string]$_.Content }) }
        $m = $script:Machine
        Show-Page 'Office'; $window.UpdateLayout()
        Test-Smoke 'Office page: own page (no placeholder), the nav item is checked' ($ui.PageOffice.Visibility -eq 'Visible' -and $ui.PagePlaceholder.Visibility -eq 'Collapsed' -and $ui.NavOffice.IsChecked) $null
        Test-Smoke 'Office dropdowns: channel (5), 32/64 bit (2), licence (2, in licence terms), Outlook (3)' ($ui.CmbOffChannel.Items.Count -eq 5 -and $ui.CmbOffEdition.Items.Count -eq 2 -and $ui.CmbOffLicense.Items.Count -eq 2 -and $ui.CmbOffLicense.Items[0].Name -like '*E3/E5*Apps for enterprise*' -and $ui.CmbOffLicense.Items[1].Name -like '*Business Premium*Apps for business*' -and $ui.CmbOffOutlook.Items.Count -eq 3) "$($ui.CmbOffLicense.Items.Count) / $($ui.CmbOffOutlook.Items.Count)"
        Test-Smoke 'Office preselection: licence E3/E5 (O365ProPlusRetail) with its sentence, Outlook both with the Microsoft recommendation, channel Monthly Enterprise, 64 bit' ((Get-OffChoiceKey $ui.CmbOffLicense) -ceq 'O365ProPlusRetail' -and $ui.TxtOffLicenseHint.Text -like '*E3*Click-to-Run*' -and (Get-OffChoiceKey $ui.CmbOffOutlook) -ceq 'both' -and $ui.TxtOffOutlookHint.Text -like '*side by side*' -and $ui.CmbOffChannel.SelectedItem -eq 'MonthlyEnterprise' -and $ui.CmbOffEdition.SelectedItem -eq '64') "$(Get-OffChoiceKey $ui.CmbOffLicense) / $(Get-OffChoiceKey $ui.CmbOffOutlook)"
        $langOn = @(& $checked $ui.PanelOffLanguages | ForEach-Object { $_ -replace ' \(.*', '' } | Sort-Object)
        Test-Smoke 'Office languages: the 19 common ones as ticks, preselected exactly MatchOS and en-US' ($ui.PanelOffLanguages.Children.Count -eq 19 -and ($langOn -join ',') -ceq 'en-US,MatchOS' -and @($ui.PanelOffLanguages.Children | Where-Object { [string]$_.Content -like 'de-DE' }).Count -eq 1) ($langOn -join ',')
        $appsOn = @(& $checked $ui.PanelOffInstall)
        $appsAll = @($ui.PanelOffInstall.Children | ForEach-Object { [string]$_.Content })
        Test-Smoke 'Office install list: Word, Excel, PowerPoint, OneNote preselected; Access, Publisher, Groove, Lync, Bing offered and off; no tick for Teams, OneDrive or Outlook, a hint instead' (($appsOn -join ',') -ceq 'Word,Excel,PowerPoint,OneNote' -and (@('Access', 'Publisher', 'Groove', 'Lync', 'Bing') | Where-Object { $_ -cnotin $appsAll }).Count -eq 0 -and -not (@('Teams', 'OneDrive', 'Outlook') | Where-Object { $_ -cin $appsAll }) -and $ui.TxtOffAppsHint.Text -like '*OneDrive and Teams*') ($appsOn -join ',')
        Test-Smoke 'Office preview: Outlook both leaves both in, the unticked apps and OneDrive/Teams are excluded, Word is not' ($ui.TxtOffPreview.Text -like '*Language ID="en-US"*' -and $ui.TxtOffPreview.Text -like '*Language ID="MatchOS"*' -and $ui.TxtOffPreview.Text -like '*ExcludeApp ID="Access"*' -and $ui.TxtOffPreview.Text -like '*ExcludeApp ID="Teams"*' -and $ui.TxtOffPreview.Text -notlike '*ExcludeApp ID="Word"*' -and $ui.TxtOffPreview.Text -notlike '*ExcludeApp ID="Outlook*') $null
        Set-OffChoice $ui.CmbOffOutlook 'classic'; $window.UpdateLayout()
        Test-Smoke 'Office Outlook classic only: the preview excludes OutlookForWindows and keeps Outlook' ($ui.TxtOffPreview.Text -like '*ExcludeApp ID="OutlookForWindows"*' -and $ui.TxtOffPreview.Text -notlike '*ExcludeApp ID="Outlook" *') $null
        Set-OffChoice $ui.CmbOffOutlook 'new'; $window.UpdateLayout()
        Test-Smoke 'Office Outlook new only: the preview excludes Outlook and keeps OutlookForWindows' ($ui.TxtOffPreview.Text -like '*ExcludeApp ID="Outlook" *' -and $ui.TxtOffPreview.Text -notlike '*ExcludeApp ID="OutlookForWindows"*') $null
        Set-OffChoice $ui.CmbOffOutlook 'both'
        Set-OffChoice $ui.CmbOffLicense 'O365BusinessRetail'; $window.UpdateLayout()
        Test-Smoke 'Office licence Business Premium: the product in the preview and its own sentence' ($ui.TxtOffPreview.Text -like '*Product ID="O365BusinessRetail"*' -and $ui.TxtOffLicenseHint.Text -like '*Business Premium*') $ui.TxtOffLicenseHint.Text
        Set-OffChoice $ui.CmbOffLicense 'O365ProPlusRetail'
        $ui.PanelOffInstall.Children[0].IsChecked = $false; [void]$ui.PanelOffInstall.Children[0].RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))); $window.UpdateLayout()
        $wordOff = $ui.TxtOffPreview.Text
        $ui.PanelOffInstall.Children[0].IsChecked = $true; [void]$ui.PanelOffInstall.Children[0].RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        Test-Smoke 'Office: unticking Word makes ExcludeApp Word in the preview (the click reaches the preview)' ($wordOff -like '*ExcludeApp ID="Word"*' -and $ui.TxtOffPreview.Text -notlike '*ExcludeApp ID="Word"*') $null
        # fix buttons: none on a master that is right, only on red rows, one per fix
        Update-OffView; $window.UpdateLayout()
        Test-Smoke 'Office state list: on a master that is right there is no Fix button' (@(& $fixButtons).Count -eq 0 -and $ui.PanelOffRows.Children.Count -ge 7) $ui.PanelOffRows.Children.Count
        $polKey = 'HKLM:\SOFTWARE\Policies\Microsoft\office\16.0\common\officeupdate'; $polWas = & $m.RegGet $polKey 'enableautomaticupdates'; $blockWas = (Get-AVDTuneUpdateBlockStatus $m).State; if ($blockWas -ne 'Off') { [void](Set-AVDTuneUpdateBlock -Machine $m -Root $script:StateRoot -Mode Off -User 'smoke') }; & $m.RegRemove $polKey 'enableautomaticupdates'   # the update block of an earlier step is switched off for this part: while it is on, Undo of the updates fix leaves the value to the block (issue 61)
        & $m.RegSet 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' 'SharedComputerLicensing' '0' 'String'; & $m.RegSet 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' 'UpdatesEnabled' 'TRUE' 'String'
        Update-OffView; $window.UpdateLayout()
        $fb = @(& $fixButtons)
        Test-Smoke 'Office state list: two red rows (shared activation, automatic updates) have a Fix button each, no other row has one' ((@($fb | ForEach-Object { [string]$_.DataContext } | Sort-Object) -join ',') -ceq 'shared,updates' -and ($fb | Where-Object { [string]$_.Content -ne 'Fix' }).Count -eq 0) (((@($fb | ForEach-Object { [string]$_.DataContext })) -join ',') + ' policy=' + [string](& $m.RegGet $polKey 'enableautomaticupdates') + ' ' + ((@(Get-AVDTuneOfficeRows -Machine $m -Config (Get-OffFormConfig)) | ForEach-Object { "$($_.Id)=$($_.Status)" }) -join ' '))
        Save-SmokeShot '60-office-red-fix-light'
        $script:ConfirmAsked = ''
        & $click ($fb | Where-Object { [string]$_.DataContext -ceq 'shared' } | Select-Object -First 1); $window.UpdateLayout()
        Test-Smoke 'Office Fix shared: asks first (value, key, restart, undo limit), writes String 1, the row is green and its button gone, the other stays' ($script:ConfirmAsked -like '*SharedComputerLicensing = 1*ClickToRun\Configuration*restart*' -and (& $m.RegGet 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' 'SharedComputerLicensing') -ceq '1' -and (@(& $fixButtons | ForEach-Object { [string]$_.DataContext }) -join ',') -ceq 'updates' -and $ui.TxtOffState.Text -like 'Fix done*') "$script:ConfirmAsked | $($ui.TxtOffState.Text)"
        Test-Smoke 'Office Fix shared: change log entry (category Office) and protocol action' (@(Get-AVDTuneChangeLog -Root $script:StateRoot | Where-Object { $_.Component -eq 'office.fix.shared' -and $_.Category -eq 'Office' }).Count -eq 1) $null
        & $click (@(& $fixButtons) | Where-Object { [string]$_.DataContext -ceq 'updates' } | Select-Object -First 1); $window.UpdateLayout()
        Test-Smoke 'Office Fix updates: policy enableautomaticupdates = 0, no Fix button left' ((& $m.RegGet 'HKLM:\SOFTWARE\Policies\Microsoft\office\16.0\common\officeupdate' 'enableautomaticupdates') -eq 0 -and @(& $fixButtons).Count -eq 0 -and $script:ConfirmAsked -like '*enableautomaticupdates = 0*') $script:ConfirmAsked
        & $click $ui.BtnOffFixUndo; $window.UpdateLayout()
        Test-Smoke 'Office Undo one-click fixes: both earlier values are back and both rows are red with their Fix button again' ((& $m.RegGet 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' 'SharedComputerLicensing') -ceq '0' -and $null -eq (& $m.RegGet 'HKLM:\SOFTWARE\Policies\Microsoft\office\16.0\common\officeupdate' 'enableautomaticupdates') -and (@(& $fixButtons | ForEach-Object { [string]$_.DataContext } | Sort-Object) -join ',') -ceq 'shared,updates') ((@(& $fixButtons | ForEach-Object { [string]$_.DataContext })) -join ',')
        Test-Smoke 'Office Undo one-click fixes: the status line reports the result per fix (Reverted), not a fixed "undone"' ($ui.TxtOffState.Text -like '*shared Reverted*' -and $ui.TxtOffState.Text -like '*updates Reverted*' -and $ui.TxtOffState.Text -notlike '*undone*') $ui.TxtOffState.Text
        # leave the fake master as it was
        if ($blockWas -and $blockWas -ne 'Off') { [void](Set-AVDTuneUpdateBlock -Machine $m -Root $script:StateRoot -Mode On -User 'smoke') }
        if ($null -ne $polWas) { & $m.RegSet $polKey 'enableautomaticupdates' $polWas 'DWord' }
        & $m.RegSet 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' 'SharedComputerLicensing' '1' 'String'; & $m.RegSet 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' 'UpdatesEnabled' 'FALSE' 'String'
        Update-OffView; $window.UpdateLayout()
        Save-SmokeShot '61-office-config-light'
        $true } }
    @{ Name = 'app masking: list (#69)'; Do = {
        if ($script:OverviewJob -or $script:ReadyJob -or $script:ReadyQueued -or $script:FslJob) { return $false }
        $click = { param($b) $b.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) }
        $dnx = 'DC=example,DC=test'; $ou = "OU=Groups,$dnx"
        $grp = @(@{ Name = 'Sales Team'; Sam = 'Sales Team'; Dn = "CN=Sales Team,$ou"; Sid = 'S-1-5-21-1-2-3-1201'; Security = $true }, @{ Name = 'Staff'; Sam = 'Staff'; Dn = "CN=Staff,$ou"; Sid = 'S-1-5-21-1-2-3-1202'; Security = $true })
        Write-AVDTuneFile (Join-Path $script:StateRoot 'config\directory.json') ([ordered]@{ ReadAt = (Get-Date).ToString('o'); Directory = [ordered]@{ DefaultNamingContext = $dnx; NetBiosName = 'EXAMPLE'; DnsName = 'example.test'; OuTree = @(); Groups = $grp } } | ConvertTo-Json -Depth 12)
        foreach ($g in $grp) { [void]$script:MaskFake.Ldap.Store.Groups.Add(@{ Name = $g.Sam; Dn = $g.Dn; Sid = $g.Sid; Description = 'x'; Members = @() }) }
        $script:SmokeMaskGateOpened = $false
        if (-not (Test-AVDTuneWriteAllowed)) { Open-AVDTuneWriteGate -SnapshotId 'snap-smoke' -ConfirmedBy 'Alex Example'; $script:SmokeMaskGateOpened = $true }
        Show-Page 'AppMasking'; $window.UpdateLayout()
        $rows = $script:MaskRowUi
        Test-Smoke 'App Masking: one row per shortcut of the Public Desktop, read as a task of the task bar' ($ui.PanelMaskList.Children.Count -eq 2 -and $rows.Count -eq 2 -and (Find-Text $ui.PanelMaskList 'Contoso App.lnk') -and (Find-Text $ui.PanelMaskList 'Notes.lnk') -and @($script:UiTasks | Where-Object { $_.Kind -eq 'appmasking-read' -and $_.Status -eq 'succeeded' }).Count -ge 1) $ui.PanelMaskList.Children.Count
        Test-Smoke 'every row has the three choices of "Visible for", the AD groups of the DC discovery and the Entra note in the group menu' ((@($rows['Notes.lnk'].Mode.ItemsSource) -join '|') -eq 'Everyone|Only members of a group|Nobody except administrators' -and $rows['Notes.lnk'].Group.Items.Count -eq 3 -and [string]$rows['Notes.lnk'].Group.Items[2].Content -like 'Microsoft Entra ID groups: not supported*' -and -not $rows['Notes.lnk'].Group.Items[2].IsEnabled -and $ui.TxtMaskEntra.Text -like '*cloud-only*learn.microsoft.com*') $null
        Test-Smoke 'the former wizard sits in a collapsed Advanced section' ($ui.ExpMaskAdvanced.Header -eq 'Advanced' -and -not $ui.ExpMaskAdvanced.IsExpanded -and $ui.ExpMaskAdvanced.Content.Children.Count -eq 2) $null
        Save-SmokeShot '56-appmasking-list-light'
        $r = $rows['Contoso App.lnk']
        $r.Mode.SelectedItem = 'Only members of a group'
        Test-Smoke 'a group needs the menu: the group menu is enabled only for "Only members of a group"' ($r.Group.IsEnabled -and -not $rows['Notes.lnk'].Group.IsEnabled) $null
        $r.Group.SelectedIndex = 0
        & $click $r.Preview
        Test-Smoke 'Preview shows old and new and writes nothing' ($ui.TxtMaskState.Text -like "Preview (nothing written): Contoso App.lnk: now 'Everyone', new 'Only members of: EXAMPLE\Sales Team'*" -and $script:MaskFake.M.Store.Files.Count -eq 0) $ui.TxtMaskState.Text
        $script:ConfirmAsked = ''
        & $click $r.Save
        Test-Smoke 'Save asked first with old and new, then wrote one rule set for this shortcut only (.fxr and .fxa)' ($script:ConfirmAsked -like "*Now: Everyone*New: Only members of: EXAMPLE\Sales Team*" -and $script:MaskFake.M.Store.Files.Count -eq 2 -and @($script:MaskFake.M.Store.Files.Keys | Where-Object { $_ -like '*Desktop-Contoso App.fxr' -or $_ -like '*Desktop-Contoso App.fxa' }).Count -eq 2) $script:ConfirmAsked
        $r = $script:MaskRowUi['Contoso App.lnk']
        Test-Smoke 'the list shows the assignment after the re-read (group menu selected, Notes still Everyone)' ($r.Mode.SelectedItem -eq 'Only members of a group' -and $r.Group.SelectedIndex -eq 0 -and $script:MaskRowUi['Notes.lnk'].Mode.SelectedItem -eq 'Everyone') $null
        $n = $script:MaskRowUi['Notes.lnk']
        $n.Mode.SelectedItem = 'Nobody except administrators'
        & $click $n.Save
        Test-Smoke 'a second row is its own rule set and its own change (4 files), not added to the first' ($script:MaskFake.M.Store.Files.Count -eq 4 -and @($script:MaskFake.M.Store.Files.Keys | Where-Object { $_ -like '*Desktop-Notes.fxr' }).Count -eq 1 -and $script:MaskRowUi['Notes.lnk'].Mode.SelectedItem -eq 'Nobody except administrators') $script:MaskFake.M.Store.Files.Count
        $script:SmokeMaskStep = 1
        $true } }
    @{ Name = 'app masking: undo (#69)'; Do = {
        if ($script:OverviewJob -or $script:ReadyJob -or $script:ReadyQueued -or $script:FslJob) { return $false }
        $click = { param($b) $b.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) }
        & $click $ui.BtnMaskUndo
        Test-Smoke 'Undo puts the last change (Notes) back; the first row keeps its group' ($script:MaskFake.M.Store.Files.Count -eq 2 -and $script:MaskRowUi['Notes.lnk'].Mode.SelectedItem -eq 'Everyone' -and $script:MaskRowUi['Contoso App.lnk'].Mode.SelectedItem -eq 'Only members of a group') $script:MaskFake.M.Store.Files.Count
        # #74: several rows in one change, one undo for all of them
        $script:MaskRowUi['Notes.lnk'].Mode.SelectedItem = 'Nobody except administrators'
        $script:MaskRowUi['Contoso App.lnk'].Mode.SelectedItem = 'Everyone'
        $script:ConfirmAsked = ''
        & $click $ui.BtnMaskSaveAll
        $mk = @($script:MaskFake.M.Store.Files.Keys)
        Test-Smoke 'Save all changes (#74): both changed rows in one change after one confirmation that names both' ($script:ConfirmAsked -like '*Save 2 row(s) in one change*Contoso App.lnk*Notes.lnk*' -and $mk.Count -eq 2 -and @($mk | Where-Object { $_ -like '*Desktop-Notes.f*' }).Count -eq 2) ($mk -join ', ')
        & $click $ui.BtnMaskUndo
        $mk = @($script:MaskFake.M.Store.Files.Keys)
        Test-Smoke 'one Undo puts both rows of "Save all changes" back (#74)' ($mk.Count -eq 2 -and @($mk | Where-Object { $_ -like '*Desktop-Contoso App.f*' }).Count -eq 2 -and $script:MaskRowUi['Notes.lnk'].Mode.SelectedItem -eq 'Everyone' -and $script:MaskRowUi['Contoso App.lnk'].Mode.SelectedItem -eq 'Only members of a group') ($mk -join ', ')
        if ($script:SmokeMaskGateOpened) { Close-AVDTuneWriteGate }
        Show-Page 'Overview'
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
    @{ Name = 'optimization page: the state is read in the background (#66)'; Do = {
        if ($script:OverviewJob -or $script:ReadyJob -or $script:ReadyQueued -or $script:OptJob -or $script:OptRun) { return $false }
        if (-not $script:OptLoadStep) {
            $script:OptLoadStep = 1
            Show-Page 'Overview'
            $script:OptStatus = $null; $ui.PanelOptList.Children.Clear()
            $sw = [Diagnostics.Stopwatch]::StartNew()
            Show-Page 'Optimization'
            $sw.Stop(); $window.UpdateLayout()
            $t = @(Get-AVDTuneUiTasks | Where-Object { $_.Kind -eq 'optimization-read' } | Select-Object -Last 1)
            Test-Smoke 'Optimization: the page returns at once, says it reads the state and shows a running task on the bar' ($sw.ElapsedMilliseconds -lt 1500 -and $script:OptJob -and $t.Count -eq 1 -and $t[0].Status -eq 'running' -and $ui.TxtOptSummary.Text -like 'Reading the state of the master*' -and $ui.PanelOptList.Children.Count -eq 0) "$($sw.ElapsedMilliseconds) ms"
            Test-Smoke 'Optimization: Apply, Undo and Refresh are locked while it reads' (-not $ui.BtnOptApply.IsEnabled -and -not $ui.BtnOptUndo.IsEnabled -and -not $ui.BtnOptRefresh.IsEnabled) $null
            Show-Page 'Overview'; Show-Page 'Optimization'
            Test-Smoke 'Optimization: leaving the page and coming back starts no second read' (@(Get-AVDTuneUiTasks | Where-Object { $_.Kind -eq 'optimization-read' -and $_.Status -eq 'running' }).Count -eq 1) $null
            return $false
        }
        $t = @(Get-AVDTuneUiTasks | Where-Object { $_.Kind -eq 'optimization-read' } | Select-Object -Last 1)
        Test-Smoke 'Optimization: after the read the task ended, the rows are there and Apply is open' ($t[0].Status -eq 'succeeded' -and $script:OptStatus -and $script:OptStatus.DataValid -and $ui.PanelOptList.Children.Count -gt 10 -and $ui.BtnOptApply.IsEnabled -and $ui.BtnOptRefresh.IsEnabled) "$($t[0].Status) rows=$($ui.PanelOptList.Children.Count)"
        Test-Smoke 'Optimization: the preset buttons show their status after the read' ($ui.OptPresets['recommended'].Content -like '*in place*') $ui.OptPresets['recommended'].Content
        $hiveRows = @($script:OptStatus.Rows | Where-Object { $_.Kind -eq 'UserHive' })
        # read behind the open write gate only (loading writes log files into the profile); with the gate closed the rows say so and nothing is loaded
        $hiveOk = if (Test-AVDTuneWriteAllowed) { @($hiveRows | Where-Object Failed).Count -eq 0 -and $script:Machine.Store.Hive.Loads -ge 1 } else { @($hiveRows | Where-Object { -not $_.Failed -or $_.Message -notlike '*write gate*' }).Count -eq 0 -and $script:Machine.Store.Hive.Loads -eq 0 }
        Test-Smoke 'Optimization: the default user profile rows (#40) are read from the simulated hive behind the write gate, which is unloaded again' ($hiveRows.Count -ge 3 -and $hiveOk -and -not $script:Machine.Store.Hive.Loaded) "rows=$($hiveRows.Count) loads=$($script:Machine.Store.Hive.Loads) loaded=$($script:Machine.Store.Hive.Loaded) gate=$(Test-AVDTuneWriteAllowed)"
        Save-SmokeShot '56-page-optimization'
        Show-Page 'Overview'
        $true } }
    @{ Name = 'customizations (#85)'; Do = {
        # the page reads in the background; every step waits until no customization job runs (the fake adapter is shared with the runspace)
        if ($script:CustJob -or $script:CustQueued) { return $false }
        $click = { param($b) $b.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) }
        $rowButton = { param($panel, [string]$text) foreach ($g in $panel.Children) { if ($g -is [System.Windows.Controls.Grid]) { foreach ($b in $g.Children[2].Children) { if ([string]$b.Content -eq $text) { return $b } } } }; $null }
        $fake = $script:CustFake.Store
        switch ([int]$script:SmokeCustStep) {
            0 {
                if (-not (Test-AVDTuneWriteAllowed)) { Open-AVDTuneWriteGate -SnapshotId 'snap-smoke' -ConfirmedBy 'Alex Example'; $script:SmokeCustGate = $true }
                $script:SmokeCustStep = 1; Show-Page 'Customizations'; if (-not $script:CustJob) { Start-CustJob 'Status' }; $window.UpdateLayout(); return $false   # a fresh read: the task list keeps only the newest tasks
            }
            1 {
                Test-Smoke 'Customizations: the page reads the items and the library (AVDTune-Assets) as a task of the task bar' ($script:CustLibrary.State -eq 'Ready' -and @($script:CustLibrary.Files).Count -eq 4 -and @(Get-AVDTuneUiTasks | Where-Object { $_.Kind -eq 'customizations-status' -and $_.Status -eq 'succeeded' }).Count -ge 1 -and [string]$ui.PanelCustSteps.Children[0].Text -eq (T 'cust.empty.steps')) "$($script:CustLibrary.State) $(@($script:CustLibrary.Files).Count) tasks=$(@(Get-AVDTuneUiTasks | Where-Object { $_.Kind -like 'customizations*' } | ForEach-Object { $_.Status }) -join ',') first=$([string]$ui.PanelCustSteps.Children[0].Text)"
                $ui.CmbCustKind.SelectedIndex = 2   # registry: HKCU is refused with the reason, nothing is saved
                $script:CustForm['Name'].Text = 'Proxy'; $script:CustForm['Path'].Text = 'HKCU:\Software\Contoso'; $script:CustForm['ValueName'].Text = 'Proxy'; $script:CustForm['ValueType'].SelectedItem = 'DWord'; $script:CustForm['Value'].Text = '1'
                & $click $ui.BtnCustSave
                Test-Smoke 'Customizations: a registry value outside HKLM is refused in the form with the reason, nothing is saved' ($ui.TxtCustErrors.Text -like '*HKLM only*' -and -not (Test-Path (Get-AVDTuneCustomPath $script:StateRoot))) $ui.TxtCustErrors.Text
                $script:CustForm['Path'].Text = 'HKLM:\SOFTWARE\Contoso'
                & $click $ui.BtnCustSave
                $ui.CmbCustKind.SelectedIndex = 1   # font from the library
                $script:CustForm['Name'].Text = 'Corp Sans'; $script:CustForm['File'].SelectedItem = 'corp-sans.ttf'
                & $click $ui.BtnCustSave
                $ui.CmbCustKind.SelectedIndex = 0   # shortcut with the icon from the library
                $script:CustForm['Name'].Text = 'CRM'; $script:CustForm['Location'].SelectedItem = 'Both'; $script:CustForm['Target'].Text = 'C:\Apps\crm.exe'; $script:CustForm['IconSource'].SelectedItem = 'Library'; $script:CustForm['IconFile'].SelectedItem = 'crm.ico'
                & $click $ui.BtnCustSave
                $saved = Get-AVDTuneCustomizations -Root $script:StateRoot
                Test-Smoke 'Customizations: three items saved from the form, the library files pinned by SHA256' ($saved.Items.Count -eq 3 -and @($saved.Items | Where-Object { $_.Kind -eq 'Font' -and $_.Sha256 -match '\A[0-9a-f]{64}\z' }).Count -eq 1 -and @($saved.Items | Where-Object { $_.Kind -eq 'Shortcut' -and $_.IconSha256 -match '\A[0-9a-f]{64}\z' }).Count -eq 1) ($ui.TxtCustErrors.Text)
                $script:SmokeCustStep = 2; return $false
            }
            2 {
                Test-Smoke 'Customizations: the lists show the shortcut, the font and the own step as missing' ($ui.PanelCustShortcuts.Children.Count -eq 1 -and $ui.PanelCustFonts.Children.Count -eq 1 -and $ui.PanelCustSteps.Children.Count -eq 1 -and @($script:CustStatus.Items | Where-Object { $_.Status -eq 'NonCompliant' }).Count -eq 3) (($script:CustStatus.Items | ForEach-Object { "$($_.Name)=$($_.Status)" }) -join ', ')
                Save-SmokeShot '57-page-customizations'
                & $click $ui.BtnCustApplyAll
                Test-Smoke 'Customizations: Apply all asks first and runs as a writer job' ($script:ConfirmAsked -like '*3*' -and $script:CustJob -and $script:CustJob.Kind -eq 'Apply' -and (Get-AVDTuneRunningWriter) -eq 'CustJob') $script:ConfirmAsked
                $script:SmokeCustStep = 3; return $false
            }
            3 {
                Test-Smoke 'Customizations: after Apply the master has the shortcuts, the font with its registration and the DWord; every row is in place' ($fake.Shortcuts.ContainsKey('c:\users\public\desktop\crm.lnk') -and $fake.Shortcuts.ContainsKey('c:\programdata\microsoft\windows\start menu\programs\crm.lnk') -and $fake.Files.ContainsKey('c:\windows\fonts\corp-sans.ttf') -and $fake.Registry.ContainsKey('hklm:\software\contoso|proxy') -and @($script:CustStatus.Items | Where-Object { $_.Status -ne 'Compliant' }).Count -eq 0) (($script:CustStatus.Items | ForEach-Object { "$($_.Name)=$($_.Status) $($_.Message)" }) -join ' | ')
                Test-Smoke 'Customizations: the change log has an entry per item (category Customizations)' (@(Get-AVDTuneChangeLog -Root $script:StateRoot | Where-Object { $_.Category -eq 'Customizations' }).Count -ge 3) $null
                $rm = & $rowButton $ui.PanelCustFonts (T 'cust.btn.remove')
                & $click $rm
                $script:SmokeCustStep = 4; return $false
            }
            4 {
                Test-Smoke 'Customizations: Remove of the font undoes it on the master and takes it out of the list' (-not $fake.Files.ContainsKey('c:\windows\fonts\corp-sans.ttf') -and @((Get-AVDTuneCustomizations -Root $script:StateRoot).Items | Where-Object { $_.Kind -eq 'Font' }).Count -eq 0 -and [string]$ui.PanelCustFonts.Children[0].Text -eq (T 'cust.empty.fonts')) $ui.TxtCustState.Text
                # web app (#88): http is refused in the form; https is saved and applied (Edge policy + shortcut with its own AppUserModelID)
                $ui.CmbCustKind.SelectedIndex = @(Get-AVDTuneCustomKinds).IndexOf('WebApp')
                $script:CustForm['Name'].Text = 'Portal'; $script:CustForm['StartUrl'].Text = 'http://portal.example.test/'; $script:CustForm['Location'].SelectedItem = 'Desktop'; $script:CustForm['IconFile'].SelectedItem = 'crm.ico'
                & $click $ui.BtnCustSave
                Test-Smoke 'Web apps (#88): a start URL without https is refused in the form with the reason, nothing is saved' ($ui.TxtCustErrors.Text -like '*https*' -and @((Get-AVDTuneCustomizations -Root $script:StateRoot).Items | Where-Object { $_.Kind -eq 'WebApp' }).Count -eq 0) $ui.TxtCustErrors.Text
                $script:CustForm['StartUrl'].Text = 'https://portal.example.test/'
                & $click $ui.BtnCustSave
                Test-Smoke 'Web apps (#88): the web app is saved with the icon pinned by SHA256' (@((Get-AVDTuneCustomizations -Root $script:StateRoot).Items | Where-Object { $_.Kind -eq 'WebApp' -and $_.IconSha256 -match '\A[0-9a-f]{64}\z' -and $_.WindowMode -eq 'Window' }).Count -eq 1) $ui.TxtCustErrors.Text
                $script:SmokeCustStep = 5; return $false
            }
            5 {
                $wa = @($script:CustStatus.Items | Where-Object { $_.Kind -eq 'WebApp' })
                Test-Smoke 'Web apps (#88): the web app is listed in its own card as missing' ($wa.Count -eq 1 -and $wa[0].Status -eq 'NonCompliant' -and $ui.PanelCustWebApps.Children.Count -eq 1 -and $ui.PanelCustWebApps.Children[0] -is [System.Windows.Controls.Grid]) "$($wa.Count) $(@($wa | ForEach-Object { $_.Status }) -join ',')"
                & $click (& $rowButton $ui.PanelCustWebApps (T 'cust.btn.apply'))
                $script:SmokeCustStep = 6; return $false
            }
            6 {
                $pol = $fake.Registry['hklm:\software\policies\microsoft\edge|webappinstallforcelist']
                $lnk = $fake.Shortcuts['c:\users\public\desktop\portal.lnk']
                Test-Smoke 'Web apps (#88): Apply writes WebAppInstallForceList (REG_SZ JSON list) and the desktop shortcut msedge.exe --app with its AppUserModelID' ($pol -and $pol.Kind -eq 'String' -and [string]$pol.Value -like '*https://portal.example.test/*' -and $lnk -and $lnk.Arguments -ceq '--app=https://portal.example.test/' -and $lnk.AppUserModelId -like 'AVDTune.WebApp.*' -and @($script:CustStatus.Items | Where-Object { $_.Kind -eq 'WebApp' -and $_.Status -eq 'Compliant' }).Count -eq 1) "pol=$(if ($pol) { $pol.Value }) lnk=$($lnk | ConvertTo-Json -Compress) rows=$(@($script:CustStatus.Items | Where-Object { $_.Kind -eq 'WebApp' } | ForEach-Object { "$($_.Status) $($_.State) $($_.Message)" }) -join ' | ') state=$($ui.TxtCustState.Text) asked=$($script:ConfirmAsked)"
                & $click (& $rowButton $ui.PanelCustWebApps (T 'cust.btn.remove'))
                $script:SmokeCustStep = 7; return $false
            }
            7 {
                Test-Smoke 'Web apps (#88): Remove undoes it (no policy value before: removed again, shortcut gone) and takes it out of the list' (-not $fake.Registry.ContainsKey('hklm:\software\policies\microsoft\edge|webappinstallforcelist') -and -not $fake.Shortcuts.ContainsKey('c:\users\public\desktop\portal.lnk') -and [string]$ui.PanelCustWebApps.Children[0].Text -eq (T 'cust.empty.webapps')) $ui.TxtCustState.Text
                if ($script:SmokeCustGate) { Close-AVDTuneWriteGate }
                Show-Page 'Overview'
                return $true
            }
        }
        $true } }
    @{ Name = 'printers (#86)'; Do = {
        # the page reads and changes in the background; every step waits until no printer job runs (the fake printer adapter is shared with the runspace)
        if ($script:PrnJob) { return $false }
        $click = { param($b) $b.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) }
        $fake = $script:PrnFake.Store
        $pol = 'hklm:\software\policies\microsoft\windows nt\printers'
        switch ([int]$script:SmokePrnStep) {
            0 {
                if (-not (Test-AVDTuneWriteAllowed)) { Open-AVDTuneWriteGate -SnapshotId 'snap-smoke' -ConfirmedBy 'Alex Example'; $script:SmokePrnGate = $true }
                Show-Page 'Printers'; $window.UpdateLayout()
                Test-Smoke 'Printers: with a domain controller in the answers the page shows the server form, not the Universal Print hint' ($ui.PagePrinters.Visibility -eq 'Visible' -and $ui.PanelPrnMain.Visibility -eq 'Visible' -and $ui.TxtPrnEntra.Visibility -eq 'Collapsed' -and [string]$ui.PanelPrnPrinters.Children[0].Text -eq (T 'prn.notread')) $null
                $ui.TxtPrnUser.Text = 'admin1@example.test'; $ui.PwdPrn.Password = 'smoke-only'
                & $click $ui.BtnPrnFind
                $script:SmokePrnStep = 1; return $false
            }
            1 {
                Test-Smoke 'Printers: Search AD lists the print servers (FQDN) of the printQueue objects as a task (a name that is not an FQDN is left out)' ((@($ui.CmbPrnServer.ItemsSource) -join ',') -eq 'print1.example.test,print2.example.test' -and @(Get-AVDTuneUiTasks | Where-Object { $_.Kind -eq 'printers-servers' -and $_.Status -eq 'succeeded' }).Count -ge 1 -and $ui.TxtPrnState.Text -like '*\\bad\share*') $ui.TxtPrnState.Text
                $ui.CmbPrnServer.Text = '\\print1.example.test'
                $refused = $null; try { Start-PrnJob 'Read' } catch { $refused = $_.Exception.Message }
                Test-Smoke 'Printers: a UNC path as server is refused before anything is read' ($refused -eq (T 'prn.err.server') -and -not $script:PrnJob) $refused
                $ui.CmbPrnServer.Text = 'other.example.test'; $ui.PwdPrn.Password = 'smoke-only'
                & $click $ui.BtnPrnRead
                Test-Smoke 'Printers: the password is cleared as soon as the read starts' ($ui.PwdPrn.SecurePassword.Length -eq 0 -and $script:PrnJob.Kind -eq 'Read') $null
                $script:SmokePrnStep = 2; return $false
            }
            2 {
                Test-Smoke 'Printers (H1): a typed server that AD does not publish is not read (no session opened)' ($ui.TxtPrnState.Text -like '*not a print server published in AD*' -and $fake.Credentials.Count -eq 0) $ui.TxtPrnState.Text
                $ui.CmbPrnServer.Text = 'print1.example.test'; $ui.PwdPrn.Password = 'smoke-only'
                & $click $ui.BtnPrnRead
                $script:SmokePrnStep = 3; return $false
            }
            3 {
                $boxes = @($ui.PanelPrnPrinters.Children | Where-Object { $_ -is [System.Windows.Controls.CheckBox] })
                Test-Smoke 'Printers: the shared printers are listed through a Kerberos session; the unsigned driver and the one without x64 driver cannot be selected' ($boxes.Count -eq 5 -and @($boxes | Where-Object { $_.IsChecked -and $_.IsEnabled }).Count -eq 3 -and @($boxes | Where-Object { -not $_.IsEnabled -and [string]$_.Tag -in 'Old Plotter', 'Front Desk' }).Count -eq 2 -and $ui.PanelPrnDrivers.Children.Count -eq 2 -and @($fake.Auth | Where-Object { $_ -ne 'Kerberos' }).Count -eq 0 -and @($fake.Credentials | Where-Object { $_ -eq 'admin1@example.test' }).Count -ge 1 -and $fake.LocalFolders.Count -eq 0) "boxes=$($boxes.Count) drivers=$($ui.PanelPrnDrivers.Children.Count) creds=$($fake.Credentials -join ',') state=$($ui.TxtPrnState.Text)"
                Save-SmokeShot '58-page-printers'
                $ui.PwdPrn.Password = 'smoke-only'
                & $click $ui.BtnPrnApply
                Test-Smoke 'Printers (H2): the vendor signer is allowed in its own confirmation (saved in config), then Install asks with the signers and runs as a writer job' ($script:ConfirmAsked -like '*Example Label Driver 2.4.0.300, *Example Labels Inc*' -and @(Get-AVDTunePrinterSigners -Root $script:StateRoot | Where-Object { $_.Thumbprint -eq ('B2' * 20) }).Count -eq 1 -and $script:PrnJob -and $script:PrnJob.Kind -eq 'Apply' -and (Get-AVDTuneRunningWriter) -eq 'PrnJob') $script:ConfirmAsked
                $script:SmokePrnStep = 4; return $false
            }
            4 {
                Test-Smoke 'Printers: both drivers installed by export with the server version, no TrustedHosts change, Point and Print policies set, every driver checked' ($fake.Local['Example Universal PCL6'] -eq '7.1.0.2500' -and $fake.Local['Example Label Driver'] -eq '2.4.0.300' -and $fake.TrustedHistory.Count -eq 0 -and $fake.Registry["$pol\pointandprint|restrictdriverinstallationtoadministrators"].Value -eq 1 -and $fake.Registry.ContainsKey("$pol\packagepointandprint\listofservers|print1.example.test") -and @($script:PrnCheck | Where-Object { -not $_.Ok }).Count -eq 0 -and @($script:PrnCheck).Count -eq 2 -and $fake.LocalFolders.Count -eq 0 -and $fake.RemoteFolders.Count -eq 0) $ui.TxtPrnState.Text
                Test-Smoke 'Printers: the change log has the drivers with version, server, signer and printers (category Printers)' (@(Get-AVDTuneChangeLog -Root $script:StateRoot | Where-Object { $_.Category -eq 'Printers' -and $_.Text -eq 'Printer driver Example Label Driver 2.4.0.300 from print1.example.test, signed by Example Labels Inc (printers: Label Printer)' }).Count -eq 1 -and @(Get-AVDTuneChangeLog -Root $script:StateRoot | Where-Object { $_.Category -eq 'Printers' }).Count -ge 4) $null
                Show-Page 'Updates'
                Test-Smoke 'Printers: the Updates page compares the drivers of the print server with the installed ones (maintenance skeleton)' ($ui.TxtUpdNotes.Text -like "*$(T 'prn.upd.same' 'print1.example.test')*") $ui.TxtUpdNotes.Text
                Show-Page 'Printers'
                & $click $ui.BtnPrnUndo
                $script:SmokePrnStep = 5; return $false
            }
            5 {
                Test-Smoke 'Printers: Undo removes the drivers AVDTune added and the policies' ($fake.Local.Count -eq 0 -and -not $fake.Registry.ContainsKey("$pol\pointandprint|restrictdriverinstallationtoadministrators") -and -not $fake.Registry.ContainsKey("$pol\packagepointandprint\listofservers|print1.example.test")) $ui.TxtPrnState.Text
                if ($script:SmokePrnGate) { Close-AVDTuneWriteGate }
                Show-Page 'Overview'
                return $true
            }
        }
        $true } }
    @{ Name = 'custom software (#87)'; Do = {
        # the card of the Software page reads and records in the background; every step waits until no custom software job runs (the fakes are shared with the runspace)
        if ($script:CswJob) { return $false }
        $click = { param($b) $b.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) }
        $fake = $script:CswFakeR.Store
        switch ([int]$script:SmokeCswStep) {
            0 {
                if (-not (Test-AVDTuneWriteAllowed)) { Open-AVDTuneWriteGate -SnapshotId 'snap-smoke' -ConfirmedBy 'Alex Example'; $script:SmokeCswGate = $true }
                $script:SmokeCswStep = 1; Show-Page 'Software'; if (-not $script:CswJob) { Start-CswJob 'Status' }; $window.UpdateLayout(); return $false   # a fresh read: the task list keeps only the newest tasks
            }
            1 {
                Test-Smoke 'Custom software: the card on the Software page reads the library installers and the (empty) list as a task' ($ui.CardCsw -and $script:CswLibrary.State -eq 'Ready' -and @(Get-CswFiles).Count -eq 2 -and @($script:CswStatus.Apps).Count -eq 0 -and [string]$ui.PanelCswApps.Children[0].Text -eq (T 'csw.empty') -and @(Get-AVDTuneUiTasks | Where-Object { $_.Kind -eq 'customsoftware-status' -and $_.Status -eq 'succeeded' }).Count -ge 1) "$($script:CswLibrary.State) $(@(Get-CswFiles).Count) apps=$(@($script:CswStatus.Apps).Count) card=$([bool]$ui.CardCsw) first=$([string]$ui.PanelCswApps.Children[0].Text) tasks=$(@(Get-AVDTuneUiTasks | Where-Object { $_.Kind -like 'customsoftware*' } | ForEach-Object { $_.Status }) -join ',')"
                $script:CswForm['Name'].Text = 'Example App'; $script:CswForm['Vendor'].Text = 'Example Vendor'; $script:CswForm['Version'].Text = '5.2'; $script:CswForm['Installer'].SelectedItem = 'example-app.msi'
                $script:CswForm['LicenseNotes'].Text = 'Licence server lic1, Passwort: geheim123'; $script:CswForm['Arguments'].Text = 'ALLUSERS=1 & calc'
                & $click $ui.BtnCswRecord
                Test-Smoke 'Custom software: arguments with & are refused in the form with the reason, nothing starts' ($ui.TxtCswErrors.Text -like '*Arguments*' -and -not $script:CswJob -and $fake.Installs.Count -eq 0) $ui.TxtCswErrors.Text
                $script:CswForm['Arguments'].Text = 'ALLUSERS=1'
                & $click $ui.BtnCswRecord
                Test-Smoke 'Custom software: the recording asks first (installer, SHA256), cleans the licence notes and runs as a writer job' ($script:ConfirmAsked -like '*example-app.msi*' -and $script:ConfirmAsked -match '[0-9a-f]{64}' -and $script:CswForm['LicenseNotes'].Text -notlike '*geheim123*' -and $script:CswJob -and $script:CswJob.Kind -eq 'Record' -and (Get-AVDTuneRunningWriter) -eq 'CswJob') $script:ConfirmAsked
                $script:SmokeCswStep = 2; return $false
            }
            2 {
                $apps = @($script:CswStatus.Apps)
                Test-Smoke 'Custom software: installed through msiexec, recorded with detection rule, listed as installed 5.2.0, change log entry' ($fake.Installs.Count -eq 1 -and $fake.Installs[0].Tool -eq 'msiexec.exe' -and $apps.Count -eq 1 -and $apps[0].Installed -eq $true -and $apps[0].InstalledVersion -eq '5.2.0' -and $apps[0].Latest.Detection.Kind -eq 'Uninstall' -and $apps[0].Latest.App.LicenseNotes -notlike '*geheim123*' -and @(Get-AVDTuneChangeLog -Root $script:StateRoot | Where-Object { $_.Component -like 'software.custom-*' }).Count -ge 1 -and $fake.Staged.Count -eq 0) $ui.TxtCswState.Text
                Save-SmokeShot '87-software-custom'
                $upd = $null; foreach ($g in $ui.PanelCswApps.Children) { if ($g -is [System.Windows.Controls.Grid]) { foreach ($b in $g.Children[2].Children) { if ([string]$b.Content -eq (T 'csw.btn.update')) { $upd = $b } } } }
                & $click $upd
                Test-Smoke 'Custom software: "Record update" fills the form with the details of the app and switches to update mode' ($script:CswMode.Kind -eq 'Update' -and $script:CswForm['Name'].Text -eq 'Example App' -and $ui.TxtCswMode.Text -eq (T 'csw.form.update' 'Example App')) $ui.TxtCswMode.Text
                $script:CswForm['Version'].Text = '5.3'; $script:CswForm['Installer'].SelectedItem = 'example-app-5.3.msi'
                & $click $ui.BtnCswRecord
                $script:SmokeCswStep = 3; return $false
            }
            3 {
                $app = @($script:CswStatus.Apps)[0]
                Test-Smoke 'Custom software: the update is the second recording, the list shows both and the installed 5.3.0' (@($script:CswStatus.Apps).Count -eq 1 -and @($app.Versions).Count -eq 2 -and $app.Latest.Kind -eq 'Update' -and $app.InstalledVersion -eq '5.3.0' -and $script:CswMode.Kind -eq 'Install') "$(@($app.Versions).Count) $($app.InstalledVersion) $($ui.TxtCswState.Text)"
                if ($script:SmokeCswGate) { Close-AVDTuneWriteGate }
                Show-Page 'Overview'
                return $true
            }
        }
        $true } }
    @{ Name = 'sharepoint (#89)'; Do = {
        # the SharePoint card of the change log: site, uploads as writer jobs against the fake Graph (shared with the runspace), document, removal of confirmed records
        if ($script:SpJob -or $script:CswJob) { return $false }
        $click = { param($b) $b.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) }
        $fake = $script:SpFake.Store
        $ver = [string](Get-AVDTuneState $script:StateRoot).ImageVersion
        switch ([int]$script:SmokeSpStep) {
            0 {
                Show-Page 'Protocol'; $ui.SegChange.IsChecked = $true; Update-ProtocolView; $window.UpdateLayout()
                Test-Smoke 'SharePoint: the card is shown with the change log and says that without a site everything stays local' ($ui.HostSp.Visibility -eq 'Visible' -and $ui.TxtSpState.Text -like ((T 'sp.nosite').Substring(0, 30) + '*') -and -not $ui.BtnSpChangeLog.IsEnabled) $ui.TxtSpState.Text
                $ui.TxtSpSite.Text = 'https://evil.example.com/sites/x'
                & $click $ui.BtnSpSave
                $refused = ((Get-AVDTuneSpSettings -Root $script:StateRoot).SiteUrl -eq '')
                $ui.TxtSpSite.Text = $script:SpFake.SiteUrl; $ui.ChkSpFinish.IsChecked = $false
                & $click $ui.BtnSpSave
                Test-Smoke 'SharePoint: the site is saved (a foreign host is refused) and the upload buttons are open' ($refused -and (Get-AVDTuneSpSettings -Root $script:StateRoot).SiteUrl -eq $script:SpFake.SiteUrl -and $ui.BtnSpChangeLog.IsEnabled -and $ui.TxtSpState.Text -like "*$($script:SpFake.SiteUrl)*") $ui.TxtSpState.Text
                & $click $ui.BtnSpChangeLog
                Test-Smoke 'SharePoint: the change log upload is a writer job with a task' ($script:SpJob -and $script:SpJob.Kind -eq 'ChangeLog' -and (Get-AVDTuneRunningWriter) -eq 'SpJob') (Get-AVDTuneRunningWriter)
                $script:SmokeSpStep = 1; return $false
            }
            1 {
                $list = @($fake.Lists.Values | Where-Object { $_.Name -eq 'AVDTune Change Log' })
                $total = @(Get-AVDTuneChangeLog -Root $script:StateRoot).Count
                $sent = (@($fake.Bodies) -join ' ')
                Test-Smoke 'SharePoint: the list "AVDTune Change Log" was created and holds every entry, nothing pending, no token in what was sent' ($list.Count -eq 1 -and $list[0].Items.Count -eq $total -and (Get-AVDTuneSpPending -Root $script:StateRoot).Pending -eq 0 -and $sent -notmatch 'fake-sp-token|eyJ[A-Za-z0-9_-]{10,}' -and @(Get-AVDTuneUiTasks | Where-Object { $_.Kind -eq 'sharepoint-changelog' -and $_.Status -eq 'succeeded' }).Count -ge 1) "$($list.Count) $(if ($list.Count) { $list[0].Items.Count }) of $total; $($ui.TxtSpState.Text)"
                $script:SmokeSpAfter = $false
                Start-SpJob 'ChangeLog' { $script:SmokeSpAfter = $true }   # the way the finish uses it (upload first, then the finish)
                $script:SmokeSpStep = 2; return $false
            }
            2 {
                Test-Smoke 'SharePoint: the upload before the finish runs its follow-up, a second upload sends nothing (idempotent)' ($script:SmokeSpAfter -and $script:SpLast -like ((T 'sp.done.changelog' 0 '*' '*').Split('*')[0] + '*')) $script:SpLast
                & $click $ui.BtnSpSoftware
                $script:SmokeSpStep = 3; return $false
            }
            3 {
                $sw = @($fake.Lists.Values | Where-Object { $_.Name -eq 'AVDTune Software' })
                $files = @($fake.Files.Keys | Where-Object { $_ -like "AVDTune/$ver/software/*" })
                Test-Smoke 'SharePoint: the software list holds the recordings and the installed programs, the documentation and records of the recordings are in the library' ($sw.Count -eq 1 -and @($sw[0].Items | Where-Object { $_.Source -like 'Custom*' }).Count -ge 1 -and $files.Count -ge 2) "$($files -join ', ') $($script:SpLast)"
                & $click $ui.BtnSpDocument
                $script:SmokeSpStep = 4; return $false
            }
            4 {
                $doc = Join-Path $script:StateRoot "documents\environment-$ver.html"
                $html = if (Test-Path -LiteralPath $doc) { [IO.File]::ReadAllText($doc) } else { '' }
                Test-Smoke 'SharePoint: the environment document is saved locally (encoded, a policy that loads nothing) and uploaded to the library' ($html -like '*Content-Security-Policy*' -and $html -notmatch '<script' -and $html -like '*Identity model*' -and $fake.Files.ContainsKey("AVDTune/$ver/environment.html")) $script:SpLast
                $script:SmokeSpBefore = @((Get-AVDTuneRecordedApps -Root $script:StateRoot).Apps).Count
                & $click $ui.BtnSpRemove
                Test-Smoke 'SharePoint: removing the uploaded records asks first and runs as the writer job (it checks the copies in SharePoint)' ($script:ConfirmAsked -like '*Example App*' -and $script:SpJob -and $script:SpJob.Kind -eq 'Remove' -and (Get-AVDTuneRunningWriter) -eq 'SpJob') $script:ConfirmAsked
                $script:SmokeSpStep = 5; return $false
            }
            5 {
                $after = @((Get-AVDTuneRecordedApps -Root $script:StateRoot).Apps).Count
                Test-Smoke 'SharePoint: the records whose copy SharePoint confirms are removed, a change log entry names them' ($script:SmokeSpBefore -ge 1 -and $after -eq 0 -and @(Get-AVDTuneChangeLog -Root $script:StateRoot | Where-Object { $_.Component -eq 'sharepoint.records' }).Count -eq 1 -and (Get-AVDTuneRunningWriter) -eq '') "$($script:SmokeSpBefore) -> $after; $($script:SpLast)"
                [void](Set-AVDTuneSpSettings -Root $script:StateRoot -SiteUrl '')
                $ui.SegSession.IsChecked = $true
                Show-Page 'Overview'
                return $true
            }
        }
        $true } }
    @{ Name = 'task bar'; Do = {
        # the flows of the earlier steps went through the one mechanism; wait (at most 30 s) until nothing runs any more
        if (-not $script:TaskStepStart) { $script:TaskStepStart = Get-Date }
        # the list keeps the newest 100 tasks; the reads and changes of the FSLogix page (#72) add many, so the tasks seen before them are kept by the smoke (same objects, merged by id)
        $seenIds = @{}; $tasks = @(@(Get-AVDTuneUiTasks) + @($script:SmokeTasksSeen) | Where-Object { $_ -and -not $seenIds.ContainsKey([string]$_.Id) -and ($seenIds[[string]$_.Id] = $true) } | Sort-Object { [int]$_.Id })
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
        Wait-SmokeIdle
        try { $done = & $step.Do $step }
        catch { Test-Smoke "step '$($step.Name)'" $false "$($_.Exception.Message) @ $($_.InvocationInfo.ScriptLineNumber) $($_.ScriptStackTrace -replace "s+", " ")"; $done = $true }
        Wait-SmokeIdle   # a failed step leaves no running read behind for the next one
        if ($done) { $script:SmokeSteps.RemoveAt(0); try { $script:SmokeResults | Set-Content (Join-Path $script:SmokeOut 'results-partial.txt') } catch { } }
    }
    catch {
        [void]$script:SmokeResults.Add("FAIL driver: $($_.Exception.Message)")
        $script:SmokeResults | Set-Content (Join-Path $script:SmokeOut 'results.txt')
        $window.Close()
    }
})
$window.Add_ContentRendered({ $script:SmokeTimer.Start() })
