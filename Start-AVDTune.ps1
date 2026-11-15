#requires -Version 5.1
<#
.SYNOPSIS
    AVDTune - Golden Master management for Azure Virtual Desktop. Graphical interface (WPF) in the look of PackTune.
.DESCRIPTION
    Runs locally and elevated on the Golden Master. This is the shell of phase 1: own title bar, navigation, light and dark theme,
    Overview (image identity, source image, builds, health), protocol of the session and change log per image version. The other
    pages are placeholders until their phase (docs\plans\avdtune.md, section 11).
    State lives in C:\ProgramData\AVDTune (Modules\AVDTune.psm1). One instance at a time (mutex Global\AVDTune).
    Test hooks (all only honoured together, so they cannot be used to run the real tool unelevated):
      AVDTUNE_FAKE   script that defines New-AVDTuneFakeMachine (Tests\Fakes\FakeMachine.ps1): no real machine access
      AVDTUNE_ROOT   state folder other than ProgramData (ignored with a warning without AVDTUNE_FAKE)
      AVDTUNE_SMOKE  script that drives the window off-screen (Tests\GuiSmokeDriver.ps1)
.PARAMETER HideConsole
    Hides the console window of this process.
#>
[CmdletBinding()]
param([switch]$HideConsole)

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSEdition -ne 'Desktop') {
    throw "This WPF tool requires Windows PowerShell 5.1: powershell.exe -ExecutionPolicy Bypass -File `"$PSCommandPath`""
}
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

$script:AppRoot = $PSScriptRoot
$script:ToolVersion = '0.1.0'
Import-Module (Join-Path $PSScriptRoot 'Modules\AVDTune.psm1') -Force
foreach ($part in 'Trust', 'Session', 'Snapshot', 'Directory', 'Start', 'UpdateBlock', 'Updates') { Import-Module (Join-Path $PSScriptRoot "Modules\AVDTune.$part.psm1") -Force }
. (Join-Path $PSScriptRoot 'AVDTune-Theme.ps1')

# ---------------------------------------------------------------- test mode, elevation, one instance
$script:StateRoot = Get-AVDTuneRoot
# Test mode needs the fake machine AND a state folder that is not the real one: nothing real can be touched
$script:TestMode = [bool]($env:AVDTUNE_FAKE -and $env:AVDTUNE_ROOT -and -not (Test-AVDTuneDefaultRoot $script:StateRoot))
function Stop-WithMessage([string]$Text) {
    [void][System.Windows.MessageBox]::Show($Text, 'AVDTune', 'OK', 'Error')
    exit 1
}
if (-not $script:TestMode -and -not (Test-AVDTuneElevated)) {
    Stop-WithMessage "AVDTune changes the Golden Master and must run as administrator.`nStart it again with 'Run as administrator'."
}
$mutexName = if ($script:TestMode) { 'Global\AVDTune-Test' } else { 'Global\AVDTune' }
$script:Mutex = New-Object System.Threading.Mutex($false, $mutexName)
$script:MutexOwned = $false
try { $script:MutexOwned = $script:Mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $script:MutexOwned = $true }
if (-not $script:MutexOwned) { Stop-WithMessage 'AVDTune is already running on this computer (one instance at a time).' }

if ($script:TestMode) {
    . $env:AVDTUNE_FAKE; $script:Machine = New-AVDTuneFakeMachine
    # sign-in, Azure Resource Manager and LDAP are fakes in test mode (Tests\Fakes\FakeServices.ps1 next to the fake machine): no real sign-in, tenant or domain controller
    . (Join-Path (Split-Path $env:AVDTUNE_FAKE -Parent) 'FakeServices.ps1')
    $script:Services = @{ Auth = (New-AVDTuneFakeAuth); Arm = (New-AVDTuneFakeArm); Ldap = (New-AVDTuneFakeLdap) }
}
else { $script:Machine = New-AVDTuneMachine }
# The state folder is checked before it is trusted (owner, explicit rules, links; repaired when possible, Modules\AVDTune.psm1)
try { [void](Initialize-AVDTuneState -Root $script:StateRoot) } catch { Stop-WithMessage $_.Exception.Message }
$script:WorkRoot = $script:StateRoot
. (Join-Path $PSScriptRoot 'AVDTune-Protocol.ps1')

# ---------------------------------------------------------------- console window
if (-not ('AVDTune.NativeWindow' -as [type])) {
    Add-Type -Namespace AVDTune -Name NativeWindow -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr hWnd, uint flags);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int command);
'@
}
if ($HideConsole) {
    $native = [AVDTune.NativeWindow]
    $console = $native::GetAncestor($native::GetConsoleWindow(), 3)
    if ($console -ne [IntPtr]::Zero) { [void]$native::ShowWindow($console, 0) }
}

# ---------------------------------------------------------------- settings (theme, language), kept next to the state
$script:SettingsPath = Join-Path $script:StateRoot 'config\ui.json'
function Get-UiSettings {
    $s = $null
    try { $s = Read-AVDTuneJson $script:SettingsPath } catch { }
    [pscustomobject]@{
        Theme = $(if ($s -and (Get-AVDTuneProp $s 'Theme') -in 'Light', 'Dark') { [string]$s.Theme } else { Get-AVDTuneSystemTheme })
        ProtocolLanguage = $(if ($s -and (Get-AVDTuneProp $s 'ProtocolLanguage') -eq 'de') { 'de' } else { 'en' })
    }
}
function Save-UiSettings {
    try { Write-AVDTuneFile $script:SettingsPath ([ordered]@{ Theme = $script:Settings.Theme; ProtocolLanguage = $script:Settings.ProtocolLanguage } | ConvertTo-Json) } catch { }
}
$script:Settings = Get-UiSettings

# ---------------------------------------------------------------- window
if (-not [System.Windows.Application]::Current) { [void](New-Object System.Windows.Application) }
[System.Windows.Application]::Current.ShutdownMode = 'OnExplicitShutdown'
Set-AVDTuneTheme -Mode $script:Settings.Theme
[xml]$xaml = Get-Content (Join-Path $PSScriptRoot 'UI\AVDTune.xaml') -Raw -Encoding UTF8
$window = [Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($xaml))
$ui = @{}
foreach ($node in $xaml.SelectNodes("//*[@*[local-name()='Name']]")) {
    $name = $node.Attributes | Where-Object LocalName -eq 'Name' | Select-Object -ExpandProperty Value
    $ui[$name] = $window.FindName($name)
}
$window.Title = "AVDTune $script:ToolVersion"
$ui.TxtVersion.Text = "AVDTune $script:ToolVersion"

$script:ClickActions = @{}
function Add-Click($Control, [scriptblock]$Action) {
    # Looked up by sender (no GetNewClosure: that would hide this script's functions and variables from the handler)
    $script:ClickActions[$Control] = $Action
    $Control.Add_Click({
            param($src)
            try { & $script:ClickActions[$src] } catch { Show-Error $_.Exception.Message }
        })
}
function Set-Brush($Element, $Property, [string]$Key) { $Element.SetResourceReference($Property, $Key) }
function ConvertTo-Vis([bool]$On) { if ($On) { 'Visible' } else { 'Collapsed' } }

# ---------------------------------------------------------------- toast and errors
$script:ToastTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:ToastTimer.Interval = [TimeSpan]::FromSeconds(5)
$script:ToastTimer.Add_Tick({ $script:ToastTimer.Stop(); $ui.BoxToast.Visibility = 'Collapsed' })
$script:LastToast = ''
function Show-Toast([string]$Text) {
    $script:LastToast = $Text
    $ui.TxtToast.Text = $Text
    $ui.BoxToast.Visibility = 'Visible'
    $script:ToastTimer.Stop(); $script:ToastTimer.Start()
}
function Show-Error([string]$Text) { Show-Toast $Text }
function Confirm-Action([string]$Text, [string]$Title = 'AVDTune') {
    if ($env:AVDTUNE_SMOKE) { $script:ConfirmAsked = $Text; return $true }
    [System.Windows.MessageBox]::Show($Text, $Title, 'YesNo', 'Question') -eq 'Yes'
}

# ---------------------------------------------------------------- pages
# Key, title, glyph, phase of the plan (docs\plans\avdtune.md, section 11), what the page will do
$script:PageTable = @(
    @{ Key = 'Overview'; Title = 'Overview'; Glyph = 0xE80F }
    @{ Key = 'Setup'; Title = 'Setup'; Glyph = 0xE7C3; Phase = 6; Text = 'Guided first setup in a fixed order: language and region for all users, Office, VDI components, optimizations, software and user experience. Each block shows what is done and what is left.' }
    @{ Key = 'Updates'; Title = 'Updates'; Glyph = 0xE895; Phase = 2 }
    @{ Key = 'Software'; Title = 'Software'; Glyph = 0xE71D; Phase = 4; Text = 'Packages of the PackTune library and the winget and Chocolatey catalog: install, update and remove, and detection of what is already on the master.' }
    @{ Key = 'Office'; Title = 'Office'; Glyph = 0xE8A5; Phase = 6; Text = 'Office Deployment Tool configuration (channel, 64 bit, languages, excluded apps, shared computer licensing, updates off), preview of configuration.xml, install, update and remove, build info.' }
    @{ Key = 'Optimization'; Title = 'Optimization'; Glyph = 0xE9D9; Phase = 6; Text = 'Optimizations for multi-session hosts: AppX, services, tasks and autologgers, visual effects, power plan, widgets and consumer features off, browser settings, Storage Sense, telemetry, hibernation, defrag. Each step with its reason and source.' }
    @{ Key = 'FSLogix'; Title = 'FSLogix'; Glyph = 0xE8B7; Phase = 3; Text = 'FSLogix setup, settings, redirections.xml and a function test of the profile container.' }
    @{ Key = 'AppMasking'; Title = 'App Masking'; Glyph = 0xE7B3; Phase = 3; Text = 'FSLogix hiding rules for icons and apps, with groups from the domain or Microsoft Entra ID.' }
    @{ Key = 'VdiComponents'; Title = 'VDI components'; Glyph = 0xE7F4; Phase = 6; Text = 'Defender onboarding for non-persistent VDI, new Teams for VDI, multimedia redirection, RDP Shortpath, time zone redirection and OneDrive per machine.' }
    @{ Key = 'UserExperience'; Title = 'User experience'; Glyph = 0xE771; Phase = 6; Text = 'Wallpaper, watermark, Start and taskbar layout and default apps for new profiles, public desktop shortcuts and web apps with App Masking rules per group.' }
    @{ Key = 'UpdateBlock'; Title = 'Update block'; Glyph = 0xE72E; Phase = 2 }
    @{ Key = 'Benchmark'; Title = 'Benchmark'; Glyph = 0xE9D2; Phase = 5; Text = 'Measures CPU, memory, disk and GPU per image version and compares versions.' }
    @{ Key = 'Seal'; Title = 'Cleanup and finish'; Glyph = 0xE74D; Phase = 7; Text = 'The last button of a version, Finish: the health check must be green or acknowledged and the benchmark done; cleanup that keeps the master usable; tokens, sign-in caches and local step images removed; a pending restart first; the change log of the version closed and sent to SharePoint; then log off or shut down. The master is never sysprepped: the image is made by your imaging tool afterwards (sysprep only as an expert option without one).' }
    @{ Key = 'Protocol'; Title = 'Protocol and change log'; Glyph = 0xE8A5 }
)
$script:PageKeys = @($script:PageTable | ForEach-Object { $_.Key })
$script:CurrentPage = 'Overview'

foreach ($page in $script:PageTable) {
    $rb = New-Object System.Windows.Controls.RadioButton
    Set-Brush $rb ([System.Windows.Controls.Control]::StyleProperty) 'NavItem'
    $rb.GroupName = 'Nav'
    $rb.Name = "Nav$($page.Key)"
    [System.Windows.Automation.AutomationProperties]::SetName($rb, $page.Title)
    $row = New-Object System.Windows.Controls.StackPanel
    $row.Orientation = 'Horizontal'
    $glyph = New-Object System.Windows.Controls.TextBlock
    $glyph.Style = $window.Resources['NavGlyph']
    $glyph.Text = [string][char]$page.Glyph
    $label = New-Object System.Windows.Controls.TextBlock
    $label.Text = $page.Title
    [void]$row.Children.Add($glyph); [void]$row.Children.Add($label)
    $rb.Content = $row
    [void]$ui.NavList.Children.Add($rb)
    $ui["Nav$($page.Key)"] = $rb
    $rb.Add_Checked({
            param($src)
            $key = $src.Name -replace '^Nav', ''
            if ($script:CurrentPage -ne $key) { try { Show-Page $key } catch { Show-Error $_.Exception.Message } }
        })
}

function Show-Page([string]$Key) {
    $script:CurrentPage = $Key
    $isPlaceholder = $Key -notin 'Overview', 'Protocol', 'Updates', 'UpdateBlock'
    $ui.PageOverview.Visibility = ConvertTo-Vis ($Key -eq 'Overview')
    $ui.PageProtocol.Visibility = ConvertTo-Vis ($Key -eq 'Protocol')
    $ui.PageUpdates.Visibility = ConvertTo-Vis ($Key -eq 'Updates')
    $ui.PageUpdateBlock.Visibility = ConvertTo-Vis ($Key -eq 'UpdateBlock')
    $ui.PagePlaceholder.Visibility = ConvertTo-Vis $isPlaceholder
    $ui["Nav$Key"].IsChecked = $true
    Update-ReadOnlyBanner
    if ($isPlaceholder) {
        $page = $script:PageTable | Where-Object { $_.Key -eq $Key } | Select-Object -First 1
        $ui.TxtPhTitle.Text = $page.Title
        $ui.TxtPhPhase.Text = "Planned for phase $($page.Phase)"
        $ui.TxtPhText.Text = $page.Text
    }
    elseif ($Key -eq 'Overview') { Update-OverviewView; Update-StartView }
    elseif ($Key -eq 'Protocol') { Update-ProtocolView }
    elseif ($Key -eq 'Updates') { Update-UpdatesView }
    elseif ($Key -eq 'UpdateBlock') { Update-UpdateBlockView }
}

# ---------------------------------------------------------------- Overview
$script:Overview = $null
$script:OverviewJob = $null
$script:StatusLabel = @{ ok = 'OK'; warn = 'Attention'; bad = 'Must fix'; info = 'Info' }
$script:StatusBrush = @{ ok = @('SuccessBg', 'Success'); warn = @('WarningBg', 'Warning'); bad = @('ErrorBg', 'Danger'); info = @('Hover', 'Text') }

function New-InfoRow([string]$Label, [string]$Value) {
    $grid = New-Object System.Windows.Controls.Grid
    $grid.Margin = '0,3,0,3'
    $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = 170
    $c2 = New-Object System.Windows.Controls.ColumnDefinition; $c2.Width = '*'
    [void]$grid.ColumnDefinitions.Add($c1); [void]$grid.ColumnDefinitions.Add($c2)
    $l = New-Object System.Windows.Controls.TextBlock; $l.Text = $Label
    Set-Brush $l ([System.Windows.Controls.TextBlock]::ForegroundProperty) 'MutedText'
    $v = New-Object System.Windows.Controls.TextBlock
    $v.Text = $(if ($Value) { $Value } else { '-' }); $v.TextWrapping = 'Wrap'; $v.SetValue([System.Windows.Controls.Grid]::ColumnProperty, 1)
    $v.Name = 'Value'
    [void]$grid.Children.Add($l); [void]$grid.Children.Add($v)
    $grid
}
function New-HealthRow($Item) {
    $grid = New-Object System.Windows.Controls.Grid
    $grid.Margin = '0,8,0,8'
    foreach ($w in 110, 190, '*') { $c = New-Object System.Windows.Controls.ColumnDefinition; $c.Width = $w; [void]$grid.ColumnDefinitions.Add($c) }
    $pill = New-Object System.Windows.Controls.Border
    Set-Brush $pill ([System.Windows.Controls.Border]::StyleProperty) 'Pill'
    $pill.Padding = '10,2'; $pill.VerticalAlignment = 'Center'
    $pair = $script:StatusBrush[[string]$Item.Status]
    Set-Brush $pill ([System.Windows.Controls.Border]::BackgroundProperty) $pair[0]
    $pt = New-Object System.Windows.Controls.TextBlock; $pt.Text = $script:StatusLabel[[string]$Item.Status]; $pt.FontSize = 12; $pt.FontWeight = 'SemiBold'
    Set-Brush $pt ([System.Windows.Controls.TextBlock]::ForegroundProperty) $pair[1]
    $pill.Child = $pt
    $title = New-Object System.Windows.Controls.TextBlock; $title.Text = [string]$Item.Title; $title.FontWeight = 'SemiBold'; $title.VerticalAlignment = 'Center'; $title.SetValue([System.Windows.Controls.Grid]::ColumnProperty, 1)
    $detail = New-Object System.Windows.Controls.TextBlock; $detail.Text = [string]$Item.Detail; $detail.TextWrapping = 'Wrap'; $detail.VerticalAlignment = 'Center'; $detail.SetValue([System.Windows.Controls.Grid]::ColumnProperty, 2)
    Set-Brush $detail ([System.Windows.Controls.TextBlock]::ForegroundProperty) 'MutedText'
    [void]$grid.Children.Add($pill); [void]$grid.Children.Add($title); [void]$grid.Children.Add($detail)
    $grid
}
function Update-Chip {
    $state = Get-AVDTuneState $script:StateRoot
    $ui.TxtChipName.Text = $(if ($script:Overview) { [string]$script:Overview.ComputerName } else { [string](& $script:Machine.ComputerName) })
    $ui.TxtChipVersion.Text = $(if ($state.ImageVersion) { [string]$state.ImageVersion } else { 'no image version' })
}
function Update-OverviewView {
    Update-Chip
    $ov = $script:Overview
    $ui.PanelIdentity.Children.Clear(); $ui.PanelHealth.Children.Clear()
    if (-not $ov) { $ui.TxtOverviewState.Text = 'Reading the machine ...'; return }
    $ui.TxtOverviewState.Text = "Read at $((Get-Date).ToString('HH:mm:ss'))."
    $src = $ov.SourceImage
    $sourceText = if ($src.Available -and $src.Text) { $src.Text } elseif ($src.Available) { 'Azure VM without image reference' } else { 'Not an Azure VM (no instance metadata)' }
    $azure = if ($src.Available) { (@($src.VmName, $src.Location, $src.VmSize) | Where-Object { $_ }) -join ', ' } else { '' }
    $office = if ($ov.Office.Installed) { "$($ov.Office.Build), $($ov.Office.Channel)" + $(if ($ov.Office.Platform) { ", $($ov.Office.Platform)" }) } else { 'Not installed' }
    $windows = $ov.Windows.Name + $(if ($ov.Windows.DisplayVersion) { " $($ov.Windows.DisplayVersion)" }) + $(if ($ov.Windows.FullBuild) { ", build $($ov.Windows.FullBuild)" })
    $rows = @(
        @('Image name', $ov.ComputerName), @('Image version', $(if ($ov.ImageVersion) { $ov.ImageVersion } else { 'none yet (Start new version)' })),
        @('Source image', $sourceText), @('Azure VM', $azure), @('Windows', $windows), @('Microsoft 365 Apps', $office),
        @('Last update', $(if ($ov.LastUpdate) { $ov.LastUpdate } else { 'none recorded' })), @('Last benchmark', $(if ($ov.LastBenchmark) { $ov.LastBenchmark } else { 'none recorded' }))
    )
    foreach ($r in $rows) { if ($r[0] -eq 'Azure VM' -and -not $r[1]) { continue }; [void]$ui.PanelIdentity.Children.Add((New-InfoRow $r[0] ([string]$r[1]))) }
    foreach ($h in $ov.Health) { [void]$ui.PanelHealth.Children.Add((New-HealthRow $h)) }
}
function Start-OverviewRefresh {
    if ($script:OverviewJob) { return }
    $ui.TxtOverviewState.Text = 'Reading the machine ...'
    $ps = [powershell]::Create()
    [void]$ps.AddScript({
            param($Module, $FakeScript, $Root, $SharedMachine)
            $ErrorActionPreference = 'Stop'
            Import-Module $Module -Force
            Import-Module (Join-Path (Split-Path $Module -Parent) 'AVDTune.UpdateBlock.psm1') -Force
            if ($FakeScript) { . $FakeScript; $m = $SharedMachine; if (-not $m) { $m = New-AVDTuneFakeMachine } } else { $m = New-AVDTuneMachine }
            Get-AVDTuneOverview -Machine $m -Root $Root -UpdateBlock (Get-AVDTuneUpdateBlockStatus $m)
        }).AddArgument((Join-Path $script:AppRoot 'Modules\AVDTune.psm1')).AddArgument($(if ($script:TestMode) { $env:AVDTUNE_FAKE } else { '' })).AddArgument($script:StateRoot).AddArgument($(if ($script:TestMode) { $script:Machine } else { $null }))
    $script:OverviewJob = @{ PS = $ps; Handle = $ps.BeginInvoke() }
}
function Complete-OverviewRefresh {
    $job = $script:OverviewJob
    if (-not $job -or -not $job.Handle.IsCompleted) { return }
    $script:OverviewJob = $null
    try {
        $result = @($job.PS.EndInvoke($job.Handle))
        if ($job.PS.HadErrors -and $job.PS.Streams.Error.Count -gt 0) { throw $job.PS.Streams.Error[0].Exception.Message }
        $script:Overview = $result | Select-Object -Last 1
    }
    catch { Show-Error "The machine could not be read: $($_.Exception.Message)" }
    finally { $job.PS.Dispose() }
    if ($script:CurrentPage -eq 'Overview') { Update-OverviewView } else { Update-Chip }
}
$script:Timer = New-Object System.Windows.Threading.DispatcherTimer
$script:Timer.Interval = [TimeSpan]::FromMilliseconds(250)
$script:Timer.Add_Tick({ try { Complete-OverviewRefresh } catch { Show-Error $_.Exception.Message } })

Add-Click $ui.BtnRefresh { Start-OverviewRefresh }
function Start-NewVersion {
    $state = Get-AVDTuneState $script:StateRoot
    $next = Get-AVDTuneNextImageVersion -Root $script:StateRoot
    $ask = if ($state.ImageVersion) { "Start image version $($next)? The current version $($state.ImageVersion) stays in the change log." } else { "Start image version $($next)?" }
    if (-not (Confirm-Action $ask 'Start new version')) { return }
    $user = [string]$env:USERNAME
    $version = Start-AVDTuneImageVersion -Root $script:StateRoot -User $user
    [void](Add-AVDTuneChangeLogEntry -Root $script:StateRoot -Version $version -Category 'Setup' -Component 'Image version' -ChangeType Note -Text "Image version $version started" -User $user)
    [void](Add-AVDTuneProtocolNote -Protocol $script:Protocol -Group 'setup' -Subject "Image version $version started")
    Save-Protocol
    Set-ProtocolImage
    Show-Toast "Image version $version started."
    Start-OverviewRefresh
    Update-Chip
    if ($script:CurrentPage -eq 'Protocol') { Update-ProtocolView }
}
Add-Click $ui.BtnNewVersion { Start-NewVersion }

# ---------------------------------------------------------------- protocol and change log
# One journal for the whole session (Shared\PackTune-Protocol.ps1 with AVDTune groups), saved after every action to <state>\Protocols
$script:Protocol = New-PackTuneProtocol -Admin ([string]$env:USERNAME) -Account ([string]$env:USERNAME) -Tenant ''
$script:LastCopied = ''
function Set-ProtocolImage {
    $state = Get-AVDTuneState $script:StateRoot
    $script:Protocol.Tenant = Remove-PackTuneProtocolSecrets ("$(& $script:Machine.ComputerName) $($state.ImageVersion)".Trim()) 120
}
function Save-Protocol { if ($script:Protocol.Actions.Count -gt 0) { [void](Save-PackTuneProtocol -Protocol $script:Protocol -Language $script:Settings.ProtocolLanguage) } }
function Register-StepResult($Result) {
    # The hook for later phases: a step result becomes a protocol action
    if (Add-AVDTuneProtocolFromResult -Protocol $script:Protocol -Result $Result) { Save-Protocol }
}
function Get-ChangeLogVersion { if ($ui.CmbVersion.SelectedItem) { [string]$ui.CmbVersion.SelectedItem } else { $null } }
function Get-ProtocolShownText {
    if ($ui.SegChange.IsChecked) {
        $version = Get-ChangeLogVersion
        if (-not $version) { return "No image version yet. Start a new version on the Overview.`r`n" }
        return ConvertTo-AVDTuneChangeLogDocument -Root $script:StateRoot -Version $version -Format Markdown -ImageName ([string](& $script:Machine.ComputerName))
    }
    ConvertTo-PackTuneProtocolText -Protocol $script:Protocol -Language $script:Settings.ProtocolLanguage -Format Text -End (Get-Date)
}
function Update-ProtocolView {
    $change = [bool]$ui.SegChange.IsChecked
    $ui.CmbVersion.Visibility = ConvertTo-Vis $change
    $ui.PanelNote.Visibility = ConvertTo-Vis $change
    $ui.CmbProtocolLanguage.Visibility = ConvertTo-Vis (-not $change)
    if ($change) {
        $keep = Get-ChangeLogVersion
        $versions = @(Get-AVDTuneChangeLogVersions -Root $script:StateRoot)
        $ui.CmbVersion.ItemsSource = $versions
        $state = Get-AVDTuneState $script:StateRoot
        $want = if ($keep -and $keep -in $versions) { $keep } elseif ($state.ImageVersion) { [string]$state.ImageVersion } else { $null }
        if ($want) { $ui.CmbVersion.SelectedItem = $want }
        $ui.TxtProtocolSubtitle.Text = 'Every change of an image version: written automatically by the steps, plus your own notes. Exports as Markdown or HTML.'
        $ui.TxtProtocolState.Text = "Kept in $(Join-Path $script:StateRoot 'changelog.json')."
    }
    else {
        $ui.TxtProtocolSubtitle.Text = 'Everything you did since AVDTune started, ready to paste into a ticket or a time sheet.'
        $ui.TxtProtocolState.Text = "Saved after every action in $(Get-PackTuneProtocolFolder)."
    }
    $ui.TxtProtocol.Text = Get-ProtocolShownText
}
$ui.CmbProtocolLanguage.ItemsSource = @('English', 'Deutsch')
$ui.CmbProtocolLanguage.SelectedIndex = $(if ($script:Settings.ProtocolLanguage -eq 'de') { 1 } else { 0 })
$ui.CmbProtocolLanguage.Add_SelectionChanged({
        $script:Settings.ProtocolLanguage = $(if ($ui.CmbProtocolLanguage.SelectedIndex -eq 1) { 'de' } else { 'en' })
        Save-UiSettings
        if ($script:CurrentPage -eq 'Protocol') { Update-ProtocolView }
    })
$ui.CmbNoteCategory.ItemsSource = @('Windows', 'Office', 'Software', 'Optimization', 'FSLogix', 'VDI', 'User experience', 'Update block', 'Benchmark', 'Seal', 'Other')
$ui.CmbNoteCategory.SelectedIndex = 10
$ui.CmbNoteType.ItemsSource = @('Note', 'Added', 'Changed', 'Updated', 'Removed')
$ui.CmbNoteType.SelectedIndex = 0
$ui.CmbVersion.Add_SelectionChanged({ if ($script:CurrentPage -eq 'Protocol' -and $ui.SegChange.IsChecked) { $ui.TxtProtocol.Text = Get-ProtocolShownText } })
$ui.SegSession.Add_Checked({ if ($script:CurrentPage -eq 'Protocol') { Update-ProtocolView } })
$ui.SegChange.Add_Checked({ if ($script:CurrentPage -eq 'Protocol') { Update-ProtocolView } })
function Add-ChangeNote {
    $version = Get-ChangeLogVersion
    if (-not $version) { throw 'Start an image version first (Overview, Start new version).' }
    $text = Remove-PackTuneProtocolSecrets ([string]$ui.TxtNote.Text) 500
    if (-not $text) { throw 'Write the note first.' }
    $category = [string]$ui.CmbNoteCategory.SelectedItem
    [void](Add-AVDTuneChangeLogEntry -Root $script:StateRoot -Version $version -Category $category -ChangeType ([string]$ui.CmbNoteType.SelectedItem) -Text $text -User ([string]$env:USERNAME) -Source Note)
    [void](Add-AVDTuneProtocolNote -Protocol $script:Protocol -Group 'other' -Subject "Change log note ($category)" -Note $text)
    Save-Protocol
    $ui.TxtNote.Text = ''
    Update-ProtocolView
    Show-Toast 'Note added to the change log.'
}
Add-Click $ui.BtnAddNote { Add-ChangeNote }
function Save-ProtocolFile([string]$Path) {
    if ($ui.SegChange.IsChecked) {
        $version = Get-ChangeLogVersion
        if (-not $version) { throw 'No image version to export.' }
        [void](Export-AVDTuneChangeLog -Root $script:StateRoot -Version $version -Path $Path -ImageName ([string](& $script:Machine.ComputerName)))
    }
    else {
        $format = if ($Path -match '\.md$') { 'Markdown' } else { 'Text' }
        [IO.File]::WriteAllText($Path, (ConvertTo-PackTuneProtocolText -Protocol $script:Protocol -Language $script:Settings.ProtocolLanguage -Format $format -End (Get-Date)), (New-Object Text.UTF8Encoding $true))
    }
}
Add-Click $ui.BtnProtocolSave {
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    if ($ui.SegChange.IsChecked) { $dlg.Title = 'Export the change log'; $dlg.Filter = 'Markdown (*.md)|*.md|HTML (*.html)|*.html'; $dlg.FileName = "AVDTune-changelog-$(Get-ChangeLogVersion).md" }
    else { $dlg.Title = 'Save the protocol'; $dlg.Filter = 'Text (*.txt)|*.txt|Markdown (*.md)|*.md'; $dlg.FileName = "AVDTune-protocol-$($script:Protocol.Id).txt" }
    if ($dlg.ShowDialog()) { Save-ProtocolFile $dlg.FileName; Show-Toast "Saved: $($dlg.FileName)" }
}
Add-Click $ui.BtnProtocolCopy {
    $text = Get-ProtocolShownText
    if ($env:AVDTUNE_SMOKE) { $script:LastCopied = $text } else { [System.Windows.Clipboard]::SetText($text) }
    Show-Toast 'Copied.'
}

. (Join-Path $PSScriptRoot 'AVDTune-Start.ps1')
. (Join-Path $PSScriptRoot 'AVDTune-Updates.ps1')

# ---------------------------------------------------------------- theme switch
function Update-ThemeButton { $ui.BtnTheme.Content = [string][char]$(if ($script:Settings.Theme -eq 'Dark') { 0xE706 } else { 0xE708 }) }
function Switch-Theme {
    $script:Settings.Theme = if ($script:Settings.Theme -eq 'Dark') { 'Light' } else { 'Dark' }
    Set-AVDTuneTheme -Mode $script:Settings.Theme
    Update-ThemeButton
    Save-UiSettings
}
Add-Click $ui.BtnTheme { Switch-Theme }
Update-ThemeButton

# ---------------------------------------------------------------- own title bar (WindowChrome)
function Update-WindowState {
    $max = $window.WindowState -eq 'Maximized'
    $ui.BtnMaximize.Content = [string]$(if ($max) { [char]0xE923 } else { [char]0xE922 })
    $ui.BtnMaximize.ToolTip = if ($max) { 'Restore' } else { 'Maximize' }
    # A maximized chrome window reaches over the screen edge by the size of its resize frame: keep the content inside
    $ui.RootGrid.Margin = if ($max) { [System.Windows.SystemParameters]::WindowResizeBorderThickness } else { New-Object System.Windows.Thickness 0 }
}
$window.Add_StateChanged({ Update-WindowState })
Add-Click $ui.BtnMinimize { $window.WindowState = 'Minimized' }
Add-Click $ui.BtnMaximize { $window.WindowState = if ($window.WindowState -eq 'Maximized') { 'Normal' } else { 'Maximized' } }
Add-Click $ui.BtnClose { $window.Close() }

# Closing during an update operation would end the process in the middle of it: the finally block of the maintenance mode would not run and the
# update block would stay lifted. So the window stays open; it closes by itself when the operation is done (Complete-UpdJob).
$script:CloseWhenDone = $false
$window.Add_Closing({
    param($src, $e)
    if (-not $script:UpdJob) { return }
    $e.Cancel = $true
    $script:CloseWhenDone = $true
    $what = if ($script:UpdJob.Kind -eq 'Scan') { 'The update search is still running' } else { 'An update operation is still running' }
    Show-Toast "$what. AVDTune closes by itself when it is done (the update block is restored first)."
})

$window.Add_Closed({
    $script:Timer.Stop()
    try { $script:SnapTimer.Stop() } catch { }
    try { if ($script:StartContext.Session) { Disconnect-AVDTuneSession $script:StartContext.Session } } catch { }   # tokens leave the memory with the window
    if ($script:OverviewJob) { try { [void]$script:OverviewJob.PS.BeginStop($null, $null) } catch { } }
    try { if ($script:MutexOwned) { $script:Mutex.ReleaseMutex() } } catch { }
    [System.Windows.Application]::Current.Shutdown()
})

# ---------------------------------------------------------------- start
Set-ProtocolImage
$stateRepair = Get-AVDTuneStateSecurityReport
if ($stateRepair -and @($stateRepair.Quarantined).Count -gt 0) {
    # N2: a prepared state folder was set aside unread; the first run starts again. The administrator is told in the protocol and in a dialog.
    $asideText = "The state folder $($script:StateRoot) had been prepared by someone else ($(@($stateRepair.Problems | Select-Object -First 3 | ForEach-Object { $_.Problem }) -join '; ')). It was set aside unread as $(@($stateRepair.Quarantined) -join ', ') and a new one was created: the first-run questions, the domain controller pin and the sign-in start again. Check who prepared it, then delete the set-aside folder."
    Add-StartProtocol 'Warning: manipulated state folder set aside' $asideText 'failed'
    if (-not $env:AVDTUNE_SMOKE) { [void][System.Windows.MessageBox]::Show($asideText, 'AVDTune', 'OK', 'Warning') } else { $script:StateAsideNotice = $asideText }
}
Update-Chip
Show-Page 'Overview'
# First run: the questions open by themselves
if (-not (Get-AVDTuneEnvironment $script:StateRoot)) { try { Open-Stage 'Environment' } catch { Show-Error $_.Exception.Message } }
$script:Timer.Start()
Start-OverviewRefresh
# A maintenance mode that never ended (closed or crashed in the middle) is reported at once; the repair is on the Update block page
if (Get-AVDTuneMaintenanceCrash -Root $script:StateRoot) { Show-Toast 'The last maintenance mode did not end properly: the update block may be lifted. Open Update block and repair it.' }
# Test hook: AVDTUNE_SMOKE names a script that drives the window off-screen and renders every page (only in test mode).
if ($env:AVDTUNE_SMOKE -and $script:TestMode) { . $env:AVDTUNE_SMOKE }
$window.Show()
[void]$window.Activate()
[void][System.Windows.Application]::Current.Run()
