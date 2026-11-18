#requires -Version 5.1
<#
.SYNOPSIS
    AVDTune - Golden Master management for Azure Virtual Desktop. Graphical interface (WPF) in the look of PackTune.
.DESCRIPTION
    Runs locally and elevated on the Golden Master. This is the shell of phase 1: own title bar, navigation, light and dark theme,
    Overview (image identity, source image, builds, health, readiness analysis), protocol of the session and change log per image version. The other
    pages are placeholders until their phase (docs\plans\avdtune.md, section 11).
    State lives in C:\ProgramData\AVDTune (Modules\AVDTune.psm1). One instance at a time (mutex Global\AVDTune).
    Test hooks (all only honoured together, so they cannot be used to run the real tool unelevated):
      AVDTUNE_FAKE   script that defines New-AVDTuneFakeMachine (Tests\Fakes\FakeMachine.ps1): no real machine access
      AVDTUNE_ROOT   state folder other than ProgramData (ignored with a warning without AVDTUNE_FAKE)
      Both count only when set in the process environment (not in the User or Machine environment), outside an installed copy, with the fake script below Tests (Test-AVDTuneTestMode).
      AVDTUNE_SMOKE  script that drives the window off-screen (Tests\GuiSmokeDriver.ps1)
.PARAMETER HideConsole
    Hides the console window of this process.
.PARAMETER Benchmark
    Benchmark only (plan 6b, #90): no setup, no sign-in, no snapshot gate, no Golden Master pages; only the Benchmark page and the protocol.
#>
[CmdletBinding()]
param([switch]$HideConsole, [Alias('BenchmarkOnly')][switch]$Benchmark)

# First statement, before any cmdlet (#73): modules only from the system folders, never from the admin's Documents or HKCU\Environment. Even Join-Path or
# New-Object would be autoloaded through the inherited path, from any module there that exports that name. Same value as Get-AVDTuneSystemModulePath.
[Environment]::SetEnvironmentVariable('PSModulePath', [IO.Path]::Combine([Environment]::GetFolderPath('Windows'), 'System32\WindowsPowerShell\v1.0\Modules') + ';' + [IO.Path]::Combine([Environment]::GetFolderPath('ProgramFiles'), 'WindowsPowerShell\Modules'), 'Process')
$ErrorActionPreference = 'Stop'
# Then TEMP/TMP of this process (#54), also before any cmdlet and before the first Add-Type: they come from HKCU\Environment, which a non-elevated process of the same
# administrator can set, and csc writes and loads the compiled DLL there. Until the state folder is verified: a new folder below the Windows TEMP folder (users may create
# items there but not delete or change ours), Administrators and SYSTEM only (a check run, not elevated, also its own user); then <state>\temp\host (Set-AVDTuneProcessTemp).
$script:BootTemp = [IO.Path]::Combine([Environment]::GetFolderPath('Windows'), 'Temp', 'AVDTune-' + [guid]::NewGuid().ToString('N'))
$bootAcl = [System.Security.AccessControl.DirectorySecurity]::new(); $bootAcl.SetAccessRuleProtection($true, $false)
$bootElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$bootOwner = $(if ($bootElevated) { 'S-1-5-32-544' } else { [Security.Principal.WindowsIdentity]::GetCurrent().User.Value })
$bootSids = @('S-1-5-32-544', 'S-1-5-18'); if (-not $bootElevated) { $bootSids += $bootOwner }
if ($bootElevated) { $bootAcl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')) }
foreach ($sid in $bootSids) { $bootAcl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid), [System.Security.AccessControl.FileSystemRights]::FullControl, [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit', [System.Security.AccessControl.PropagationFlags]::None, [System.Security.AccessControl.AccessControlType]::Allow)) }
[void][IO.Directory]::CreateDirectory($script:BootTemp, $bootAcl)
# the folder is ours only when it has exactly what was asked for (#54 review B5): no link, owner, protected, only these accounts; someone who made it first does not pass
$bootGot = [IO.Directory]::GetAccessControl($script:BootTemp)
$bootRules = @($bootGot.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
if ((([IO.File]::GetAttributes($script:BootTemp) -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or -not $bootGot.AreAccessRulesProtected -or $bootGot.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne $bootOwner -or @($bootRules | Where-Object { $_.IsInherited -or $_.AccessControlType -ne 'Allow' -or $bootSids -notcontains $_.IdentityReference.Value }).Count -gt 0) { throw "AVDTune: the start folder $($script:BootTemp) is not AVDTune's own (owner, rules or a link): AVDTune does not start." }
foreach ($n in 'TEMP', 'TMP') { [Environment]::SetEnvironmentVariable($n, $script:BootTemp, 'Process') }
if ($PSVersionTable.PSEdition -ne 'Desktop') {
    throw "This WPF tool requires Windows PowerShell 5.1: powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
}
Import-Module ([IO.Path]::Combine($PSScriptRoot, 'Modules', 'AVDTune.psm1')) -Force
[void](Set-AVDTuneSafeModulePath)   # the same value; every worker gets it through New-AVDTunePowerShell / New-AVDTuneRunspacePool
# The module folders are checked before anything else is loaded (the message follows once the texts are there): a module someone without admin rights
# could have changed, or a path that Windows PowerShell would change when a runspace opens, stops the start
$script:ModulePathProblems = @(Get-AVDTuneModulePathProblems)
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

$script:AppRoot = $PSScriptRoot
$script:BenchmarkOnly = [bool]$Benchmark   # plan 6b: set here or by "Benchmark only" in the sign-in step of the first start (Enter-BenchmarkOnlyMode)
$script:ToolVersion = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'VERSION') -Raw -Encoding UTF8).Trim()   # the file VERSION is also the version of the release
. (Join-Path $PSScriptRoot 'AVDTune-Theme.ps1')
. (Join-Path $PSScriptRoot 'AVDTune-UiText.ps1')   # the texts of the window (UI\Strings.en.json, UI\Strings.de.json)
$script:LanguageInit = Initialize-AVDTuneLanguage -Folder (Join-Path $PSScriptRoot 'UI')
foreach ($problem in $script:LanguageInit.Problems) { [Console]::Error.WriteLine("AVDTune: $problem") }
Set-AVDTuneLanguage $(if ([System.Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName -eq 'de') { 'de' } else { 'en' })   # until the settings are read: the language of Windows

# ---------------------------------------------------------------- test mode, elevation, one instance
$script:StateRoot = Get-AVDTuneRoot
# Test mode needs the fake machine AND a state folder that is not the real one: nothing real can be touched
# One decision for the whole process (Modules\AVDTune.psm1): process-only variables, not installed, fake script below Tests\; otherwise a warning and the normal start
$script:TestInfo = Test-AVDTuneTestMode -AppRoot $script:AppRoot
$script:TestMode = [bool]($script:TestInfo.Enabled -and -not (Test-AVDTuneDefaultRoot $script:StateRoot))
$script:SmokeOn = [bool]($script:TestMode -and $script:TestInfo.Smoke)   # AVDTUNE_SMOKE counts only inside the test mode (no dialog skipped, no clipboard or timer change otherwise)
function Get-TestScript([string]$Name) {
    # A script of the test mode next to the fake machine, through the same gate (below Tests\, no links)
    $p = Resolve-AVDTuneTestScript -Path (Join-Path $script:TestInfo.FakeDir $Name) -AppRoot $script:AppRoot
    if (-not $p) { throw "Test script $Name is not a file below the Tests folder of this copy." }
    $p
}
function Stop-WithMessage([string]$Text) {
    # In test mode never a dialog: it would appear on the developer's desktop and block an unattended run
    try { [IO.Directory]::Delete($script:BootTemp) } catch { }   # the start folder below the Windows TEMP (#54), when still there and empty (not recursive)
    if ($script:TestMode) { [Console]::Error.WriteLine("AVDTune: $Text"); exit 1 }
    [void][System.Windows.MessageBox]::Show($Text, 'AVDTune', 'OK', 'Error')
    exit 1
}
if (-not $script:TestMode -and -not (Test-AVDTuneElevated)) {
    Stop-WithMessage (T 'shell.err.admin')
}
# A module folder that is not admin-only, or a module path that Windows PowerShell would change (#73): AVDTune does not start (checked above, before the other modules load)
if ($script:ModulePathProblems.Count -gt 0) {
    $shown = @($script:ModulePathProblems | Select-Object -First 8) + @($(if ($script:ModulePathProblems.Count -gt 8) { "... ($($script:ModulePathProblems.Count - 8) more)" }))
    Stop-WithMessage (T 'shell.err.modulepath' ($shown -join "`n"))
}
foreach ($part in 'Trust', 'Session', 'Snapshot', 'Directory', 'Start', 'UpdateBlock', 'Updates', 'Readiness', 'Watermark', 'Benchmark', 'Shortcut', 'FSLogix', 'Storage', 'Software', 'Office', 'Vdi', 'Masking', 'Finish', 'Environment', 'Optimization', 'Language') { Import-Module (Join-Path $PSScriptRoot "Modules\AVDTune.$part.psm1") -Force }
Import-Module (Join-Path $PSScriptRoot 'Modules\AVDTune.Custom.psm1') -Force   # customizations (#85): after Software and Masking, which it uses
Import-Module (Join-Path $PSScriptRoot 'Modules\AVDTune.Recording.psm1') -Force   # custom software with recording (#87): after Custom, whose library fetch it uses
Import-Module (Join-Path $PSScriptRoot 'Modules\AVDTune.Printers.psm1') -Force   # printer drivers from a print server (#86): after Custom, whose registry adapter it uses
Import-Module (Join-Path $PSScriptRoot 'Modules\AVDTune.Release.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Modules\AVDTune.SharePoint.psm1') -Force   # change log, software list and environment document to SharePoint (#89)
# Test runs of several checkouts can run at the same time: one test mutex per test state folder
$mutexName = if ($script:TestMode) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $h = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(([string]$script:StateRoot).ToLowerInvariant())) | Select-Object -First 8 | ForEach-Object { $_.ToString('x2') }) } finally { $sha.Dispose() }
    "Global\AVDTune-Test-$h"
} else { 'Global\AVDTune' }
$script:MutexName = $mutexName
$script:Mutex = New-Object System.Threading.Mutex($false, $mutexName)
$script:MutexOwned = $false
try { $script:MutexOwned = $script:Mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $script:MutexOwned = $true }
if (-not $script:MutexOwned) { Stop-WithMessage (T 'shell.err.running') }

if ($script:TestMode) {
    . $script:TestInfo.FakeScript; $script:Machine = New-AVDTuneFakeMachine
    # sign-in, Azure Resource Manager and LDAP are fakes in test mode (Tests\Fakes\FakeServices.ps1 next to the fake machine): no real sign-in, tenant or domain controller
    . (Get-TestScript 'FakeServices.ps1')
    $script:Services = @{ Auth = (New-AVDTuneFakeAuth); Arm = (New-AVDTuneFakeArm); Ldap = (New-AVDTuneFakeLdap) }
}
else { $script:Machine = New-AVDTuneMachine }
# The state folder is checked before it is trusted (owner, explicit rules, links; repaired when possible, Modules\AVDTune.psm1)
try { [void](Initialize-AVDTuneState -Root $script:StateRoot) } catch { Stop-WithMessage $_.Exception.Message }
# TEMP/TMP of this process now in the verified state folder (#54): <state>\temp\host, admin-only, fresh per start; the start folder below the Windows TEMP folder goes
try { [void](Set-AVDTuneProcessTemp -StateRoot $script:StateRoot) } catch { Stop-WithMessage $_.Exception.Message }
try { [void](Remove-AVDTuneTreeSafe -Path $script:BootTemp) } catch { }   # through handles, a link inside removed as a link
# Staging folders of a Teams update that a crash left behind (Modules\AVDTune.Updates.psm1); after the check, links are never followed
try { [void](Clear-AVDTuneStageFolder -Root $script:StateRoot) } catch { }
$script:WorkRoot = $script:StateRoot
. (Join-Path $PSScriptRoot 'AVDTune-Protocol.ps1')
. (Join-Path $PSScriptRoot 'AVDTune-Tasks.ps1')   # the tasks of this session (state; the bar is AVDTune-TaskBar.ps1)

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
        # one switch for the window and the protocol: an older file has only ProtocolLanguage; without any choice the language of Windows (as the theme follows Windows)
        Language = $(if ($s -and (Get-AVDTuneProp $s 'Language') -in 'en', 'de') { [string]$s.Language } elseif ($s -and (Get-AVDTuneProp $s 'ProtocolLanguage') -in 'en', 'de') { [string]$s.ProtocolLanguage } else { Get-AVDTuneLanguage })
        ProtocolLanguage = 'en'
    }
}
function Save-UiSettings {
    try { Write-AVDTuneFile $script:SettingsPath ([ordered]@{ Theme = $script:Settings.Theme; Language = $script:Settings.Language; ProtocolLanguage = $script:Settings.Language } | ConvertTo-Json) } catch { }
}
$script:Settings = Get-UiSettings
$script:Settings.ProtocolLanguage = $script:Settings.Language   # the protocol follows the switch of the window
Set-AVDTuneLanguage $script:Settings.Language

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
[void](Register-AVDTuneLocalized $window)   # elements with a Uid get their texts from the language files (again after every switch)
Update-AVDTuneLocalized
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
    if ($script:SmokeOn) { $script:ConfirmAsked = $Text }
    Confirm-AVDTuneAction -Text $Text -Title $Title -Auto $script:SmokeOn -Dialog { param($t, $ti) [System.Windows.MessageBox]::Show($t, $ti, 'YesNo', 'Question') -eq 'Yes' }
}

# ---------------------------------------------------------------- pages
# Key, title, glyph, phase of the plan (docs\plans\avdtune.md, section 11), what the page will do
$script:PageTable = @(
    @{ Key = 'Overview'; Title = 'Overview'; Glyph = 0xE80F }
    @{ Key = 'Setup'; Title = 'Setup'; Glyph = 0xE7C3; Phase = 6; Text = 'Guided first setup in a fixed order: language and region for all users, Office, VDI components, optimizations, software and user experience. Each block shows what is done and what is left.' }
    @{ Key = 'Language'; Title = 'Language and region'; Glyph = 0xF2B7; Phase = 6; Text = 'Language packs and Language Features, system locale, display language, regional format, input, location and time zone for new users.' }
    @{ Key = 'Updates'; Title = 'Updates'; Glyph = 0xE895; Phase = 2 }
    @{ Key = 'Software'; Title = 'Software'; Glyph = 0xE71D; Phase = 4; Text = 'Packages of the PackTune library and the winget and Chocolatey catalog: install, update and remove, and detection of what is already on the master.' }
    @{ Key = 'Office'; Title = 'Office'; Glyph = 0xE8A5; Phase = 6; Text = 'Office Deployment Tool configuration (channel, 64 bit, languages, excluded apps, shared computer licensing, updates off), preview of configuration.xml, install, update and remove, build info.' }
    @{ Key = 'Optimization'; Title = 'Optimization'; Glyph = 0xE9D9; Phase = 6; Text = 'Optimizations for multi-session hosts: AppX, services, tasks and autologgers, visual effects, power plan, widgets and consumer features off, browser settings, Storage Sense, telemetry, hibernation, defrag. Each step with its reason and source.' }
    @{ Key = 'FSLogix'; Title = 'FSLogix'; Glyph = 0xE8B7; Phase = 3 }
    @{ Key = 'Environment'; Title = 'Environment'; Glyph = 0xE774; Phase = 3 }
    @{ Key = 'AppMasking'; Title = 'App Masking'; Glyph = 0xE7B3; Phase = 3; Text = 'FSLogix hiding rules for icons and apps, with groups from the domain or Microsoft Entra ID.' }
    @{ Key = 'VdiComponents'; Title = 'VDI components'; Glyph = 0xE7F4; Phase = 6; Text = 'New Teams for VDI, the WebRTC Redirector Service, multimedia redirection and OneDrive per machine: detection, install, update, remove, undo and the recommended settings. Defender onboarding, RDP Shortpath and time zone redirection follow later.' }
    @{ Key = 'UserExperience'; Title = 'User experience'; Glyph = 0xE771; Phase = 6; Text = 'Wallpaper, watermark, Start and taskbar layout and default apps for new profiles, public desktop shortcuts and web apps with App Masking rules per group.' }
    @{ Key = 'Customizations'; Title = 'Customizations'; Glyph = 0xE70F; Phase = 4 }
    @{ Key = 'Printers'; Title = 'Printers'; Glyph = 0xE749; Phase = 4 }
    @{ Key = 'UpdateBlock'; Title = 'Update block'; Glyph = 0xE72E; Phase = 2 }
    @{ Key = 'Benchmark'; Title = 'Benchmark'; Glyph = 0xE9D2; Phase = 5; Text = 'Measures CPU, memory, disk, remote display and network and compares with the baseline.' }
    @{ Key = 'Seal'; Title = 'Cleanup and finish'; Glyph = 0xE74D; Phase = 7; Text = 'The last button of a version, Finish: the health check must be green or acknowledged and the benchmark done; cleanup that keeps the master usable; tokens, sign-in caches and local step images removed; a pending restart first; the change log of the version closed and sent to SharePoint; then log off or shut down. The master is never sysprepped: the image is made by your imaging tool afterwards (sysprep only as an expert option without one).' }
    @{ Key = 'Protocol'; Title = 'Protocol and change log'; Glyph = 0xE8A5 }
)
$script:PageKeys = @($script:PageTable | ForEach-Object { $_.Key })
$script:CurrentPage = 'Overview'
$script:NavLabels = @{}
# The title of a page in the chosen language (nav.<key>); the English title of the table when the language files have no key for a new page yet
function Get-PageTitle($Page) { $k = "nav.$($Page.Key.ToLowerInvariant())"; if (Test-AVDTuneHasText $k) { T $k } else { [string]$Page.Title } }

foreach ($page in $script:PageTable) {
    $rb = New-Object System.Windows.Controls.RadioButton
    Set-Brush $rb ([System.Windows.Controls.Control]::StyleProperty) 'NavItem'
    $rb.GroupName = 'Nav'
    $rb.Name = "Nav$($page.Key)"
    [System.Windows.Automation.AutomationProperties]::SetName($rb, (Get-PageTitle $page))
    $row = New-Object System.Windows.Controls.StackPanel
    $row.Orientation = 'Horizontal'
    $glyph = New-Object System.Windows.Controls.TextBlock
    $glyph.Style = $window.Resources['NavGlyph']
    $glyph.Text = [string][char]$page.Glyph
    $label = New-Object System.Windows.Controls.TextBlock
    $label.Text = Get-PageTitle $page
    $script:NavLabels[$page.Key] = @{ Radio = $rb; Label = $label }
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
    if ($script:BenchmarkOnly -and $Key -notin 'Benchmark', 'Protocol') { $Key = 'Benchmark' }   # benchmark only: no other page, whatever asks for it
    $script:CurrentPage = $Key
    $isPlaceholder = $Key -notin 'Overview', 'Protocol', 'Updates', 'UpdateBlock', 'UserExperience', 'Benchmark', 'FSLogix', 'Software', 'Office', 'VdiComponents', 'AppMasking', 'Seal', 'Environment', 'Optimization', 'Language', 'Customizations', 'Printers'
    $ui.PageOverview.Visibility = ConvertTo-Vis ($Key -eq 'Overview')
    $ui.PageProtocol.Visibility = ConvertTo-Vis ($Key -eq 'Protocol')
    $ui.PageUpdates.Visibility = ConvertTo-Vis ($Key -eq 'Updates')
    $ui.PageUpdateBlock.Visibility = ConvertTo-Vis ($Key -eq 'UpdateBlock')
    $ui.PageUserExperience.Visibility = ConvertTo-Vis ($Key -eq 'UserExperience')
    $ui.PageBenchmark.Visibility = ConvertTo-Vis ($Key -eq 'Benchmark')
    $ui.PageFSLogix.Visibility = ConvertTo-Vis ($Key -eq 'FSLogix')
    $ui.PageSoftware.Visibility = ConvertTo-Vis ($Key -eq 'Software')
    $ui.PageOffice.Visibility = ConvertTo-Vis ($Key -eq 'Office')
    if ($ui.ContainsKey('PageVdiComponents')) { $ui.PageVdiComponents.Visibility = ConvertTo-Vis ($Key -eq 'VdiComponents') }
    if ($ui.PageAppMasking) { $ui.PageAppMasking.Visibility = ConvertTo-Vis ($Key -eq 'AppMasking') }
    $ui.PageSeal.Visibility = ConvertTo-Vis ($Key -eq 'Seal')
    if ($ui.PageEnvironment) { $ui.PageEnvironment.Visibility = ConvertTo-Vis ($Key -eq 'Environment') }
    if ($ui.ContainsKey('PageLanguage')) { $ui.PageLanguage.Visibility = ConvertTo-Vis ($Key -eq 'Language') }
    if ($ui.ContainsKey('PageOptimization')) { $ui.PageOptimization.Visibility = ConvertTo-Vis ($Key -eq 'Optimization') }
    if ($Key -eq 'Customizations') { Build-CustPage }
    if ($ui.ContainsKey('PageCustomizations')) { $ui.PageCustomizations.Visibility = ConvertTo-Vis ($Key -eq 'Customizations') }
    if ($Key -eq 'Printers') { Build-PrnPage }
    if ($ui.ContainsKey('PagePrinters')) { $ui.PagePrinters.Visibility = ConvertTo-Vis ($Key -eq 'Printers') }
    $ui.PagePlaceholder.Visibility = ConvertTo-Vis $isPlaceholder
    $ui["Nav$Key"].IsChecked = $true
    Update-ReadOnlyBanner
    if ($isPlaceholder) {
        $page = $script:PageTable | Where-Object { $_.Key -eq $Key } | Select-Object -First 1
        $ui.TxtPhTitle.Text = Get-PageTitle $page
        $ui.TxtPhPhase.Text = T 'shell.phase' $page.Phase
        $ui.TxtPhText.Text = $page.Text
    }
    elseif ($Key -eq 'Overview') { Update-OverviewView; Update-StartView; Update-ReadyView }
    elseif ($Key -eq 'Protocol') { Update-ProtocolView }
    elseif ($Key -eq 'Updates') { Update-UpdatesView }
    elseif ($Key -eq 'UpdateBlock') { Update-UpdateBlockView }
    elseif ($Key -eq 'UserExperience') { Update-WatermarkView }
    elseif ($Key -eq 'Benchmark') { Update-BenchmarkView }
    elseif ($Key -eq 'FSLogix') { Update-FslView }
    elseif ($Key -eq 'Software') { Show-SoftwarePage; Show-CswCard }
    elseif ($Key -eq 'Office') { Update-OffView }
    elseif ($Key -eq 'VdiComponents') { Update-VdiView }
    elseif ($Key -eq 'AppMasking') { Update-MaskView }
    elseif ($Key -eq 'Seal') { Update-SealView }
    elseif ($Key -eq 'Environment') { Update-EnvView }
    elseif ($Key -eq 'Optimization') { Update-OptView }
    elseif ($Key -eq 'Language') { Update-LangView }
    elseif ($Key -eq 'Customizations') { Update-CustPage }
    elseif ($Key -eq 'Printers') { Update-PrnPage }
}

# ---------------------------------------------------------------- Overview
$script:Overview = $null
$script:OverviewJob = $null
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
    $pt = New-Object System.Windows.Controls.TextBlock; $pt.Text = T "status.$([string]$Item.Status)"; $pt.FontSize = 12; $pt.FontWeight = 'SemiBold'
    Set-Brush $pt ([System.Windows.Controls.TextBlock]::ForegroundProperty) $pair[1]
    $pill.Child = $pt
    $title = New-Object System.Windows.Controls.TextBlock; $title.Text = Convert-AVDTuneEngineText 'health.title.' ([string]$Item.Title); $title.FontWeight = 'SemiBold'; $title.VerticalAlignment = 'Center'; $title.SetValue([System.Windows.Controls.Grid]::ColumnProperty, 1)
    $detail = New-Object System.Windows.Controls.TextBlock; $detail.Text = Convert-AVDTuneEngineText 'health.detail.' ([string]$Item.Detail); $detail.TextWrapping = 'Wrap'; $detail.VerticalAlignment = 'Center'; $detail.SetValue([System.Windows.Controls.Grid]::ColumnProperty, 2)
    Set-Brush $detail ([System.Windows.Controls.TextBlock]::ForegroundProperty) 'MutedText'
    [void]$grid.Children.Add($pill); [void]$grid.Children.Add($title); [void]$grid.Children.Add($detail)
    $grid
}
# the master is busy while a change is marked in state.json or a job of this window that changes it runs (a job may not have marked it yet)
function Test-MasterBusy { [bool]((Test-AVDTuneChangeInProgress -Root $script:StateRoot) -or (Get-AVDTuneRunningWriter)) }
function Update-Chip {
    $state = Get-AVDTuneState $script:StateRoot
    $ui.TxtChipName.Text = $(if ($script:Overview) { [string]$script:Overview.ComputerName } else { [string](& $script:Machine.ComputerName) })
    $ui.TxtChipVersion.Text = $(if ($state.ImageVersion) { [string]$state.ImageVersion } else { T 'ov.chip.noversion' })
    # no new version while AVDTune changes the master: the first change of a version and its snapshot must not overlap (#27)
    $busy = Test-MasterBusy
    $ui.BtnNewVersion.IsEnabled = -not $busy
    $ui.BtnNewVersion.ToolTip = $(if ($busy) { T 'ov.busy.tip' } else { $null })
}
function Update-OverviewView {
    Update-Chip
    $ov = $script:Overview
    $ui.PanelIdentity.Children.Clear(); $ui.PanelHealth.Children.Clear()
    if (-not $ov) { $ui.TxtOverviewState.Text = T 'ov.reading'; return }
    $ui.TxtOverviewState.Text = T 'ov.readat' (Get-Date).ToString('HH:mm:ss')
    $src = $ov.SourceImage
    $sourceText = if ($src.Available -and $src.Text) { $src.Text } elseif ($src.Available) { T 'ov.val.noimageref' } else { T 'ov.val.notazure' }
    $azure = if ($src.Available) { (@($src.VmName, $src.Location, $src.VmSize) | Where-Object { $_ }) -join ', ' } else { '' }
    $office = if ($ov.Office.Installed) { "$($ov.Office.Build), $($ov.Office.Channel)" + $(if ($ov.Office.Platform) { ", $($ov.Office.Platform)" }) } else { T 'ov.val.notinstalled' }
    $windows = $ov.Windows.Name + $(if ($ov.Windows.DisplayVersion) { " $($ov.Windows.DisplayVersion)" }) + $(if ($ov.Windows.FullBuild) { T 'ov.val.build' $ov.Windows.FullBuild })
    $rows = @(
        @('imagename', $ov.ComputerName), @('imageversion', $(if ($ov.ImageVersion) { $ov.ImageVersion } else { T 'ov.val.noversion' })),
        @('source', $sourceText), @('azurevm', $azure), @('windows', $windows), @('m365', $office),
        @('lastupdate', $(if ($ov.LastUpdate) { $ov.LastUpdate } else { T 'ov.val.norecord' })), @('lastbenchmark', $(if ($ov.LastBenchmark) { $ov.LastBenchmark } else { T 'ov.val.norecord' }))
    )
    foreach ($r in $rows) { if ($r[0] -eq 'azurevm' -and -not $r[1]) { continue }; [void]$ui.PanelIdentity.Children.Add((New-InfoRow (T "ov.row.$($r[0])") ([string]$r[1]))) }
    foreach ($h in $ov.Health) { [void]$ui.PanelHealth.Children.Add((New-HealthRow $h)) }
}
function Start-OverviewRefresh {
    if ($script:OverviewJob) { return }
    $ui.TxtOverviewState.Text = T 'ov.reading'
    $ps = New-AVDTunePowerShell
    [void]$ps.AddScript({
            param($Module, $FakeScript, $Root, $SharedMachine)
            $ErrorActionPreference = 'Stop'
            Import-Module $Module -Force
            Import-Module (Join-Path (Split-Path $Module -Parent) 'AVDTune.UpdateBlock.psm1') -Force
            if ($FakeScript) { . $FakeScript; $m = $SharedMachine; if (-not $m) { $m = New-AVDTuneFakeMachine } } else { $m = New-AVDTuneMachine }
            Get-AVDTuneOverview -Machine $m -Root $Root -UpdateBlock (Get-AVDTuneUpdateBlockStatus $m)
        }).AddArgument((Join-Path $script:AppRoot 'Modules\AVDTune.psm1')).AddArgument($(if ($script:TestMode) { $script:TestInfo.FakeScript } else { '' })).AddArgument($script:StateRoot).AddArgument($(if ($script:TestMode) { $script:Machine } else { $null }))
    $task = Start-AVDTuneUiTask -Kind 'overview' -Title (T 'task.ov.title') -Step (T 'task.ov.step') -Retry @{ Command = 'Start-OverviewRefresh'; Arguments = @() }
    $script:OverviewJob = @{ PS = $ps; Handle = $ps.BeginInvoke(); Task = $task }
}
function Complete-OverviewRefresh {
    $job = $script:OverviewJob
    if (-not $job -or -not $job.Handle.IsCompleted) { return }
    $script:OverviewJob = $null
    try {
        $result = @($job.PS.EndInvoke($job.Handle))
        if ($job.PS.HadErrors -and $job.PS.Streams.Error.Count -gt 0) { throw $job.PS.Streams.Error[0].Exception.Message }
        $script:Overview = $result | Select-Object -Last 1
        Complete-AVDTuneUiTask $job.Task -Summary (T 'task.ov.done')
    }
    catch { $why = T 'task.ov.failed' $_.Exception.Message; Complete-AVDTuneUiTask $job.Task -Failed -Summary $why; Show-Error $why }
    finally { $job.PS.Dispose() }
    if ($script:CurrentPage -eq 'Overview') { Update-OverviewView } else { Update-Chip }
}
$script:Timer = New-Object System.Windows.Threading.DispatcherTimer
$script:Timer.Interval = [TimeSpan]::FromMilliseconds(250)
# one handler: the refresh, then the error of a stop that could not get the state lock (Stop-AVDTuneChange never replaces a result with it; read once, so it is shown once)
$script:Timer.Add_Tick({
    try { Complete-OverviewRefresh } catch { Show-Error $_.Exception.Message }
    try { $stopError = Get-AVDTuneChangeStopError; if ($stopError) { Show-Error $stopError; [void](Add-AVDTuneProtocolNote -Protocol $script:Protocol -Group 'other' -Subject $stopError); Save-Protocol } } catch { }   # #58: in the protocol too
})

Add-Click $ui.BtnRefresh { Start-OverviewRefresh }
function Start-NewVersion {
    if (Test-MasterBusy) { Show-Error (T 'ov.newversion.busy'); return }
    $state = Get-AVDTuneState $script:StateRoot
    $next = Get-AVDTuneNextImageVersion -Root $script:StateRoot
    $ask = if ($state.ImageVersion) { T 'ov.newversion.ask.next' $next $state.ImageVersion } else { T 'ov.newversion.ask.first' $next }
    if (-not (Confirm-Action $ask (T 'ov.newversion'))) { return }
    $user = [string]$env:USERNAME
    $hold = $null
    try { $hold = Enter-AVDTuneWriter -Kind 'new-version' -Title (T 'ov.newversion') -AllowSealed; $version = Start-AVDTuneImageVersion -Root $script:StateRoot -User $user }   # the central lock (#49); a new version ends Sealed
    catch { Show-Error $_.Exception.Message; return }
    finally { Exit-AVDTuneWriter $hold }
    [void](Add-AVDTuneChangeLogEntry -Root $script:StateRoot -Version $version -Category 'Setup' -Component 'Image version' -ChangeType Note -Text "Image version $version started" -User $user)
    [void](Add-AVDTuneProtocolNote -Protocol $script:Protocol -Group 'setup' -Subject "Image version $version started")
    Save-Protocol
    Set-ProtocolImage
    Show-Toast (T 'ov.newversion.done' $version)
    Start-OverviewRefresh
    Update-Chip
    if ($script:CurrentPage -eq 'Protocol') { Update-ProtocolView }
}
Add-Click $ui.BtnNewVersion { Start-NewVersion }

# ---------------------------------------------------------------- protocol and change log
# One journal for the whole session (Shared\PackTune-Protocol.ps1 with AVDTune groups), saved after every action to <state>\Protocols
$script:Protocol = New-PackTuneProtocol -Admin ([string]$env:USERNAME) -Account ([string]$env:USERNAME) -Tenant ''
# A default user profile left loaded by a crash of an optimization run (#40) is unloaded at once and noted; the readiness analysis shows it red until it is gone
try {
    $hiveStart = Invoke-AVDTuneDefaultHiveUnload -Machine $script:Machine
    if ($hiveStart.WasLoaded) { [void](Add-AVDTuneProtocolNote -Protocol $script:Protocol -Group 'other' -Subject $(if ($hiveStart.Unloaded) { 'Default user profile was still loaded (HKU\AVDTune_DefaultUser) and was unloaded at the start' } else { 'Default user profile is still loaded (HKU\AVDTune_DefaultUser) and could not be unloaded at the start: unload it on the readiness page or restart the master' })) }
}
catch { [void](Add-AVDTuneProtocolNote -Protocol $script:Protocol -Group 'other' -Subject "Default user profile could not be checked at the start: $($_.Exception.Message)") }
foreach ($refused in (Get-AVDTuneTestModeRefusal)) { [void](Add-AVDTuneProtocolNote -Protocol $script:Protocol -Group 'other' -Subject "Test mode refused ($($refused.Time)): $($refused.Reason)") }
# #52: old readiness analysis records in runs are removed (the newest 200 of the last 180 days stay; records with changes and those the state names always stay)
try { $oldRuns = Remove-AVDTuneOldRuns -Root $script:StateRoot -User ([string]$env:USERNAME); if ($oldRuns -gt 0) { [void](Add-AVDTuneProtocolNote -Protocol $script:Protocol -Group 'other' -Subject "$oldRuns old readiness analysis record(s) removed from runs") } }
catch { [void](Add-AVDTuneProtocolNote -Protocol $script:Protocol -Group 'other' -Subject "Old run records could not be removed: $($_.Exception.Message)") }
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
        if (-not $version) { return (T 'prot.noversion') + "`r`n" }
        return ConvertTo-AVDTuneChangeLogDocument -Root $script:StateRoot -Version $version -Format Markdown -ImageName ([string](& $script:Machine.ComputerName))
    }
    ConvertTo-PackTuneProtocolText -Protocol $script:Protocol -Language $script:Settings.ProtocolLanguage -Format Text -End (Get-Date)
}
function Update-ProtocolView {
    $change = [bool]$ui.SegChange.IsChecked
    $ui.CmbVersion.Visibility = ConvertTo-Vis $change
    $ui.PanelNote.Visibility = ConvertTo-Vis $change
    if (Get-Variable -Scope Script -Name SpReady -ValueOnly -ErrorAction SilentlyContinue) { Show-SpCard $change }   # the SharePoint card (#89)
    if ($change) {
        $keep = Get-ChangeLogVersion
        $versions = @(Get-AVDTuneChangeLogVersions -Root $script:StateRoot)
        $ui.CmbVersion.ItemsSource = $versions
        $state = Get-AVDTuneState $script:StateRoot
        $want = if ($keep -and $keep -in $versions) { $keep } elseif ($state.ImageVersion) { [string]$state.ImageVersion } else { $null }
        if ($want) { $ui.CmbVersion.SelectedItem = $want }
        $ui.TxtProtocolSubtitle.Text = T 'prot.sub.change'
        $ui.TxtProtocolState.Text = T 'prot.state.change' (Join-Path $script:StateRoot 'changelog.json')
    }
    else {
        $ui.TxtProtocolSubtitle.Text = T 'prot.sub.session'
        $ui.TxtProtocolState.Text = T 'prot.state.session' (Get-PackTuneProtocolFolder)
    }
    $ui.TxtProtocol.Text = Get-ProtocolShownText
}
$ui.CmbNoteCategory.ItemsSource = @('Windows', 'Office', 'Software', 'Optimization', 'FSLogix', 'Language', 'VDI', 'User experience', 'Update block', 'Benchmark', 'Finish', 'Other')
$ui.CmbNoteCategory.SelectedIndex = 10
$ui.CmbNoteType.ItemsSource = @('Note', 'Added', 'Changed', 'Updated', 'Removed')
$ui.CmbNoteType.SelectedIndex = 0
$ui.CmbVersion.Add_SelectionChanged({ if ($script:CurrentPage -eq 'Protocol' -and $ui.SegChange.IsChecked) { $ui.TxtProtocol.Text = Get-ProtocolShownText } })
$ui.SegSession.Add_Checked({ if ($script:CurrentPage -eq 'Protocol') { Update-ProtocolView } })
$ui.SegChange.Add_Checked({ if ($script:CurrentPage -eq 'Protocol') { Update-ProtocolView } })
function Add-ChangeNote {
    $version = Get-ChangeLogVersion
    if (-not $version) { throw (T 'prot.err.noversion') }
    $text = Remove-PackTuneProtocolSecrets ([string]$ui.TxtNote.Text) 500
    if (-not $text) { throw (T 'prot.err.nonote') }
    $category = [string]$ui.CmbNoteCategory.SelectedItem
    [void](Add-AVDTuneChangeLogEntry -Root $script:StateRoot -Version $version -Category $category -ChangeType ([string]$ui.CmbNoteType.SelectedItem) -Text $text -User ([string]$env:USERNAME) -Source Note)
    [void](Add-AVDTuneProtocolNote -Protocol $script:Protocol -Group 'other' -Subject "Change log note ($category)" -Note $text)
    Save-Protocol
    $ui.TxtNote.Text = ''
    Update-ProtocolView
    Show-Toast (T 'prot.noteadded')
}
Add-Click $ui.BtnAddNote { Add-ChangeNote }
function Save-ProtocolFile([string]$Path) {
    if ($ui.SegChange.IsChecked) {
        $version = Get-ChangeLogVersion
        if (-not $version) { throw (T 'prot.err.noexport') }
        [void](Export-AVDTuneChangeLog -Root $script:StateRoot -Version $version -Path $Path -ImageName ([string](& $script:Machine.ComputerName)))
    }
    else {
        $format = if ($Path -match '\.md$') { 'Markdown' } else { 'Text' }
        [IO.File]::WriteAllText($Path, (ConvertTo-PackTuneProtocolText -Protocol $script:Protocol -Language $script:Settings.ProtocolLanguage -Format $format -End (Get-Date)), (New-Object Text.UTF8Encoding $true))
    }
}
Add-Click $ui.BtnProtocolSave {
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    if ($ui.SegChange.IsChecked) { $dlg.Title = T 'prot.dlg.export'; $dlg.Filter = 'Markdown (*.md)|*.md|HTML (*.html)|*.html'; $dlg.FileName = "AVDTune-changelog-$(Get-ChangeLogVersion).md" }
    else { $dlg.Title = T 'prot.dlg.save'; $dlg.Filter = 'Text (*.txt)|*.txt|Markdown (*.md)|*.md'; $dlg.FileName = "AVDTune-protocol-$($script:Protocol.Id).txt" }
    if ($dlg.ShowDialog()) { Save-ProtocolFile $dlg.FileName; Show-Toast (T 'prot.saved' $dlg.FileName) }
}
Add-Click $ui.BtnProtocolCopy {
    $text = Get-ProtocolShownText
    if ($script:SmokeOn) { $script:LastCopied = $text } else { [System.Windows.Clipboard]::SetText($text) }
    Show-Toast (T 'prot.copied')
}

. (Join-Path $PSScriptRoot 'AVDTune-TaskBar.ps1')   # the bar at the bottom and the list of tasks; the pages below start and finish their tasks through AVDTune-Tasks.ps1
. (Join-Path $PSScriptRoot 'AVDTune-Start.ps1')
. (Join-Path $PSScriptRoot 'AVDTune-Updates.ps1')
$script:ReadyFakeArm = $(if ($script:TestMode) { $script:Services.Arm } else { $null })
. (Join-Path $PSScriptRoot 'AVDTune-Readiness.ps1')
. (Join-Path $PSScriptRoot 'AVDTune-UserExperience.ps1')
. (Join-Path $PSScriptRoot 'AVDTune-Release.ps1')
. (Join-Path $PSScriptRoot 'AVDTune-Benchmark.ps1')
. (Join-Path $PSScriptRoot 'AVDTune-FSLogix.ps1')
. (Join-Path $PSScriptRoot 'AVDTune-Software.ps1')   # the Software page (issue 31): its own XAML, module and task handling
. (Join-Path $PSScriptRoot 'AVDTune-Office.ps1')
. (Join-Path $PSScriptRoot 'AVDTune-Vdi.ps1')   # the VDI components page (issue 56): its own XAML and module
. (Join-Path $PSScriptRoot 'AVDTune-AppMasking.ps1')
. (Join-Path $PSScriptRoot 'AVDTune-Custom.ps1')   # the Customizations page (#85): shortcuts, fonts, own steps; uses the Software and App Masking pages
. (Join-Path $PSScriptRoot 'AVDTune-CustomSoftware.ps1')   # the custom software card of the Software page (#87); uses the Customizations and App Masking helpers
. (Join-Path $PSScriptRoot 'AVDTune-Printers.ps1')   # the Printers page (#86): printer drivers from a print server; uses the App Masking and Software helpers
. (Join-Path $PSScriptRoot 'AVDTune-Seal.ps1')
. (Join-Path $PSScriptRoot 'AVDTune-SharePoint.ps1')   # the SharePoint card of the change log (#89); the finish uses its upload
. (Join-Path $PSScriptRoot 'AVDTune-Environment.ps1')
. (Join-Path $PSScriptRoot 'AVDTune-Optimization.ps1')
. (Join-Path $PSScriptRoot 'AVDTune-Language.ps1')   # the Language and region page (issue 56)

# ---------------------------------------------------------------- theme switch
function Update-ThemeButton { $ui.BtnTheme.Content = [string][char]$(if ($script:Settings.Theme -eq 'Dark') { 0xE706 } else { 0xE708 }) }
function Update-LangButton { $ui.BtnLang.Content = (Get-AVDTuneLanguage).ToUpperInvariant() }
function Update-Localized {
    # Everything of the shell that is made in code is made again in the chosen language; pages that are not translated yet keep their texts
    Update-AVDTuneLocalized
    Update-LangButton
    foreach ($page in $script:PageTable) {
        $nav = $script:NavLabels[$page.Key]
        if ($nav) { $nav.Label.Text = Get-PageTitle $page; [System.Windows.Automation.AutomationProperties]::SetName($nav.Radio, (Get-PageTitle $page)) }
    }
    Update-WindowState
    Show-TaskList $script:TaskListOpen
    Update-TaskBar
    Update-ReleaseView; Update-ShortcutRow
    Update-StartView; Update-ReadyView
    Update-Chip
    if ($script:CurrentPage -eq 'Overview') { Update-OverviewView }
    elseif ($script:CurrentPage -eq 'Protocol') { Update-ProtocolView }
    elseif ($ui.PagePlaceholder.Visibility -eq 'Visible') { Show-Page $script:CurrentPage }
}
function Switch-Language {
    $script:Settings.Language = if ((Get-AVDTuneLanguage) -eq 'de') { 'en' } else { 'de' }
    $script:Settings.ProtocolLanguage = $script:Settings.Language
    Set-AVDTuneLanguage $script:Settings.Language
    Save-UiSettings
    Update-Localized
}
function Switch-Theme {
    $script:Settings.Theme = if ($script:Settings.Theme -eq 'Dark') { 'Light' } else { 'Dark' }
    Set-AVDTuneTheme -Mode $script:Settings.Theme
    Update-ThemeButton
    Save-UiSettings
}
Add-Click $ui.BtnTheme { Switch-Theme }
Update-ThemeButton
Add-Click $ui.BtnLang { Switch-Language }
Update-LangButton

# ---------------------------------------------------------------- own title bar (WindowChrome)
function Update-WindowState {
    $max = $window.WindowState -eq 'Maximized'
    $ui.BtnMaximize.Content = [string]$(if ($max) { [char]0xE923 } else { [char]0xE922 })
    $ui.BtnMaximize.ToolTip = if ($max) { T 'title.restore.tip' } else { T 'title.maximize.tip' }
    # A maximized chrome window reaches over the screen edge by the size of its resize frame: keep the content inside
    $ui.RootGrid.Margin = if ($max) { [System.Windows.SystemParameters]::WindowResizeBorderThickness } else { New-Object System.Windows.Thickness 0 }
}
$window.Add_StateChanged({ Update-WindowState })
Add-Click $ui.BtnMinimize { $window.WindowState = 'Minimized' }
Add-Click $ui.BtnMaximize { $window.WindowState = if ($window.WindowState -eq 'Maximized') { 'Normal' } else { 'Maximized' } }
Add-Click $ui.BtnClose { $window.Close() }

# Closing during an update operation would end the process in the middle of it: the finally block of the maintenance mode would not run and the
# update block would stay lifted. So the window stays open; it closes by itself when the operation is done (Complete-UpdJob).
# #49 review: the same for every writer (each job of WriterJobVariables that changes the master, and a held Enter-AVDTuneWriter lock); the window timer closes it
# when none is left, unless a task failed after the close was asked for (the administrator sees the error first).
$script:CloseWhenDone = $false
$script:CloseAskedAt = $null
function Get-CloseHoldReason {
    # what keeps the window open, '' when nothing does
    if ($script:SealJob) { return (T 'shell.close.finish') }
    if ($script:BenchJob) { return (T 'shell.close.bench') }
    if ($script:UpdJob) { if ($script:UpdJob.Kind -eq 'Scan') { return (T 'shell.close.scan') } else { return (T 'shell.close.update') } }
    $w = Get-AVDTuneRunningWriter
    if ($w) { return (T 'shell.close.writer' $w) }
    ''
}
$window.Add_Closing({
    param($src, $e)
    $what = Get-CloseHoldReason
    if (-not $what) { return }
    $e.Cancel = $true
    if (-not $script:CloseWhenDone) { $script:CloseAskedAt = Get-Date }
    $script:CloseWhenDone = $true
    Show-Toast (T 'shell.close.toast' $what)
})
function Invoke-CloseWhenDone {
    # one tick of the window timer: close when the close was held and no writer is left; a task that failed since then stops the close
    if (-not $script:CloseWhenDone -or (Get-CloseHoldReason)) { return }
    $failedSince = @(Get-AVDTuneUiTasks | Where-Object { $_.Status -eq 'failed' -and $_.Finished -and $script:CloseAskedAt -and [datetime]$_.Finished -ge $script:CloseAskedAt })
    $script:CloseWhenDone = $false
    if ($failedSince.Count -gt 0) { Show-Error (T 'shell.close.failed' $failedSince[0].Title); return }
    $window.Close()
}
$script:Timer.Add_Tick({ try { Invoke-CloseWhenDone } catch { } })

# Log off or shut down during an update operation would end it the same way: Windows is asked to wait (SessionEnding is cancelled) and shows
# the reason (ShutdownBlockReasonCreate) while an operation runs. Start-UpdJob and Complete-UpdJob switch the reason on and off.
if (-not ('AVDTune.ShutdownBlock' -as [type])) {
    Add-Type -Namespace AVDTune -Name ShutdownBlock -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern bool ShutdownBlockReasonCreate(IntPtr hWnd, string reason);
[DllImport("user32.dll")] public static extern bool ShutdownBlockReasonDestroy(IntPtr hWnd);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern bool ShutdownBlockReasonQuery(IntPtr hWnd, System.Text.StringBuilder buffer, ref uint size);
'@
}
function Get-ShutdownReasonText { T 'shell.shutdownreason' }
function Get-WindowHandle { (New-Object System.Windows.Interop.WindowInteropHelper $window).Handle }
function Set-ShutdownBlock([bool]$On) {
    # Off only when no job is left: an ending search must not take the block away from a run that still goes (#66)
    if (-not $On) { foreach ($jobName in $script:WriterJobVariables) { $j = $(if ($jobName -ne 'ReadyJob') { Get-Variable -Scope Script -Name $jobName -ValueOnly -ErrorAction SilentlyContinue }); if ($j -and -not ($jobName -eq 'RelJob' -and [string]$j.Kind -in $script:WriterReadOnlyKinds.RelJob)) { return } } }   # a release check (Start, Check) does not hold the block, an install does (#49)
    try {
        $h = Get-WindowHandle
        if ($h -eq [IntPtr]::Zero) { return }
        if ($On) { [void][AVDTune.ShutdownBlock]::ShutdownBlockReasonCreate($h, (Get-ShutdownReasonText)) } else { [void][AVDTune.ShutdownBlock]::ShutdownBlockReasonDestroy($h) }
    }
    catch { }
}
function Get-ShutdownBlockReason {
    $h = Get-WindowHandle
    $sb = New-Object System.Text.StringBuilder 1024
    [uint32]$size = 1024
    if ($h -ne [IntPtr]::Zero -and [AVDTune.ShutdownBlock]::ShutdownBlockReasonQuery($h, $sb, [ref]$size)) { $sb.ToString() } else { '' }
}
function Invoke-SessionEnding($EventArgs) {
    if (-not $script:UpdJob -and -not $script:BenchJob -and -not $script:SealJob) { return }
    $EventArgs.Cancel = $true
    Show-Toast (T 'shell.sessionend')
}
$script:SessionEndingHandler = [System.Windows.SessionEndingCancelEventHandler]{ param($src, $e) Invoke-SessionEnding $e }
[System.Windows.Application]::Current.add_SessionEnding($script:SessionEndingHandler)

$window.Add_Closed({
    try { [System.Windows.Application]::Current.remove_SessionEnding($script:SessionEndingHandler) } catch { }   # a handler left on the application keeps the process from ending
    try { if ($script:OptSessionEnding) { [System.Windows.Application]::Current.remove_SessionEnding($script:OptSessionEnding) } } catch { }
    try { if ($script:SwSessionEnding) { [System.Windows.Application]::Current.remove_SessionEnding($script:SwSessionEnding) } } catch { }   # the handlers of the pages too: a handler left on the application keeps the process from ending
    $script:Timer.Stop()
    try { $script:SnapTimer.Stop() } catch { }
    try { if ($script:StartContext.Session) { Disconnect-AVDTuneSession $script:StartContext.Session } } catch { }   # tokens leave the memory with the window
    try { Clear-AVDTuneSessionDcAccount } catch { }   # the domain account of the start sequence too (#75)
    if ($script:OverviewJob) { try { [void]$script:OverviewJob.PS.BeginStop($null, $null) } catch { } }
    if ($script:ReadyJob) { try { [void]$script:ReadyJob.PS.BeginStop($null, $null) } catch { } }
    try { Close-FslLatestLookup } catch { }   # the FSLogix page's background lookup of the newest release
    if ($script:OptJob -and $script:OptJob.PS) { try { [void]$script:OptJob.PS.BeginStop($null, $null) } catch { } }   # a read does not hold the window back
    try { if ($script:MutexOwned) { $script:Mutex.ReleaseMutex() } } catch { }
    [System.Windows.Application]::Current.Shutdown()
})

# ---------------------------------------------------------------- start
Set-ProtocolImage
$stateRepair = Get-AVDTuneStateSecurityReport
if ($stateRepair -and @($stateRepair.Quarantined).Count -gt 0) {
    # N2: a prepared state folder was set aside unread; the first run starts again. The administrator is told in the protocol and in a dialog.
    $asideText = T 'shell.aside' $script:StateRoot (@($stateRepair.Problems | Select-Object -First 3 | ForEach-Object { $_.Problem }) -join '; ') (@($stateRepair.Quarantined) -join ', ')
    Add-StartProtocol 'Warning: manipulated state folder set aside' $asideText 'failed'
    if (-not $script:SmokeOn) { [void][System.Windows.MessageBox]::Show($asideText, 'AVDTune', 'OK', 'Warning') } else { $script:StateAsideNotice = $asideText }
}
Update-Chip
Show-Page 'Overview'
# First start: the sign-in opens by itself (it needs no answer; the domain step and the questions follow, issue #64)
if ($script:BenchmarkOnly) { try { Enter-BenchmarkOnlyMode } catch { Show-Error $_.Exception.Message } }   # plan 6b: no sign-in, no setup
elseif (-not (Get-AVDTuneEnvironment $script:StateRoot)) { try { Open-Stage 'SignIn' } catch { Show-Error $_.Exception.Message } }
$script:Timer.Start()
Start-OverviewRefresh
Update-ReleaseView; Start-RelJob 'Start'   # integrity of the tool against its release and the update check, at every start (AVDTune-Release.ps1)
if (-not $script:BenchmarkOnly) { Start-ReadyJob 'Start' '' }   # the readiness analysis runs at every start (read only; Azure checks need the sign-in and run again after it)
# A maintenance mode that never ended (closed or crashed in the middle) is reported at once; the repair is on the Update block page
if (Get-AVDTuneFinishCrash -Root $script:StateRoot) { Show-Toast (T 'shell.crash.finish') }
if (Get-AVDTuneMaintenanceCrash -Root $script:StateRoot) { Show-Toast (T 'shell.crash.maint') }
# Test hook: AVDTUNE_SMOKE names a script that drives the window off-screen and renders every page (only in test mode).
if ($script:SmokeOn) { . $script:TestInfo.SmokeScript }
$window.Show()
[void]$window.Activate()
[void][System.Windows.Application]::Current.Run()
