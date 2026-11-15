#requires -Version 5.1
<#
.SYNOPSIS
    The AVDTune watermark overlay: a click-through label ("PILOTUMGEBUNG" or any text) in a corner of every monitor, shown only when the
    computer name matches the pattern of the settings. Started at logon by the scheduled task "AVDTune Watermark" (group Users), one per session.
.DESCRIPTION
    Lives in the program folder (C:\Program Files\AVDTune\Watermark, writable for administrators only) and only READS its settings from the
    copy that users may read (C:\ProgramData\AVDTune-Public\watermark.json). Order: read settings, check the name (no match: exit at once,
    nothing else is loaded), mutex Local\AVDTune-Watermark (per session, so every user of a multi-session host gets the label), then WPF.
    No timer: the windows are laid out again when Windows reports a display change or a work area change (taskbar moved or hidden).
    Exit codes: 0 shown or not needed (name does not match, already running), 2 settings missing or invalid.
    -DryRun creates the windows without showing them and prints their placement (used by the checks).
#>
[CmdletBinding()]
param(
    [string]$SettingsPath = (Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'AVDTune-Public\watermark.json'),
    [string]$ComputerName = [Environment]::MachineName,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'AVDTune-WatermarkCore.ps1')

function Read-WmSettings([string]$Path) {
    # Read only; $null when the file is missing, not readable or not valid (the overlay then does nothing)
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
        $text = [IO.File]::ReadAllText($Path).TrimStart([char]0xFEFF)
        $r = ConvertTo-AVDTuneWatermarkSettings ($text | ConvertFrom-Json)
        if ($r.Valid) { return $r.Settings }
    }
    catch { }
    $null
}

function Initialize-WmNative {
    if (-not ('AVDTune.WmNative' -as [type])) {
        Add-Type -Namespace AVDTune -Name WmNative -MemberDefinition @'
[DllImport("user32.dll", EntryPoint = "GetWindowLongW")] public static extern int GetWindowLong(IntPtr hWnd, int index);
[DllImport("user32.dll", EntryPoint = "SetWindowLongW")] public static extern int SetWindowLong(IntPtr hWnd, int index, int value);
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
'@
    }
}

# click-through (TRANSPARENT), layered, no taskbar button (TOOLWINDOW), never takes the focus (NOACTIVATE)
$script:WmExStyle = 0x20 -bor 0x80000 -bor 0x80 -bor 0x08000000

function New-WmWindow {
    <#
        One label window for one screen, created but not shown. Returns @{ Window; Handle; X; Y; Width; Height } (pixels). The window is
        sized to its text; the position comes from the work area of the screen (the taskbar stays free).
    #>
    param($Settings, $Screen)
    $w = New-Object System.Windows.Window
    $w.WindowStyle = 'None'; $w.AllowsTransparency = $true; $w.Background = [System.Windows.Media.Brushes]::Transparent
    $w.ShowInTaskbar = $false; $w.Topmost = $true; $w.ShowActivated = $false; $w.ResizeMode = 'NoResize'; $w.Focusable = $false
    $w.SizeToContent = 'WidthAndHeight'; $w.WindowStartupLocation = 'Manual'; $w.Left = -10000; $w.Top = -10000
    $rgb = ConvertTo-WmRgb $Settings.Color
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $Settings.Text; $tb.FontSize = $Settings.FontSize; $tb.FontWeight = 'Bold'; $tb.IsHitTestVisible = $false
    $tb.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb($rgb.R, $rgb.G, $rgb.B))
    $tb.Opacity = $Settings.Opacity / 100.0
    $w.Content = $tb
    $helper = New-Object System.Windows.Interop.WindowInteropHelper $w
    $hwnd = $helper.EnsureHandle()
    $current = [AVDTune.WmNative]::GetWindowLong($hwnd, -20)
    [void][AVDTune.WmNative]::SetWindowLong($hwnd, -20, ($current -bor $script:WmExStyle))
    $tb.Measure((New-Object System.Windows.Size ([double]::PositiveInfinity), ([double]::PositiveInfinity)))
    $scale = 1.0
    try { $src = [System.Windows.PresentationSource]::FromVisual($w); if ($src -and $src.CompositionTarget) { $scale = $src.CompositionTarget.TransformToDevice.M11 } } catch { }
    $pw = [int][Math]::Ceiling($tb.DesiredSize.Width * $scale); $ph = [int][Math]::Ceiling($tb.DesiredSize.Height * $scale)
    $area = $Screen.WorkingArea
    $pos = Get-AVDTuneWatermarkPlacement -WorkArea @{ X = $area.X; Y = $area.Y; Width = $area.Width; Height = $area.Height } -Width $pw -Height $ph -Corner $Settings.Corner -Margin $Settings.Margin
    [pscustomobject]@{ Window = $w; Handle = $hwnd; X = $pos.X; Y = $pos.Y; Width = $pw; Height = $ph; Device = $Screen.DeviceName }
}

function Show-WmWindow($Item) {
    $Item.Window.Show()
    # HWND_TOPMOST = -1, SWP_NOACTIVATE = 0x10, SWP_SHOWWINDOW = 0x40
    [void][AVDTune.WmNative]::SetWindowPos($Item.Handle, [IntPtr](-1), $Item.X, $Item.Y, $Item.Width, $Item.Height, (0x10 -bor 0x40))
}

function Close-WmWindows {
    foreach ($i in @($script:WmItems)) { try { $i.Window.Close() } catch { } }
    $script:WmItems = @()
}

function Update-WmWindows($Settings, [bool]$Show) {
    # All screens of the moment, one label each; the old windows are closed first
    Close-WmWindows
    $items = New-Object System.Collections.ArrayList
    foreach ($screen in [System.Windows.Forms.Screen]::AllScreens) {
        $item = New-WmWindow $Settings $screen
        if ($Show) { Show-WmWindow $item }
        [void]$items.Add($item)
    }
    $script:WmItems = @($items)
}

function New-WmHostHook {
    <#
        A hidden top-level window that only listens: Windows sends WM_DISPLAYCHANGE (0x7E) and, for a changed work area, WM_SETTINGCHANGE (0x1A)
        with SPI_SETWORKAREA (0x2F) to every top-level window. The hook runs on the UI thread, so the handler may use the engine. No timer.
    #>
    $p = New-Object System.Windows.Interop.HwndSourceParameters 'AVDTuneWatermarkHost'
    $p.WindowStyle = 0x80000000   # WS_POPUP, never shown
    $p.Width = 0; $p.Height = 0
    $src = New-Object System.Windows.Interop.HwndSource $p
    $hook = [System.Windows.Interop.HwndSourceHook]{
        param($hwnd, $msg, $wParam, $lParam, [ref]$handled)
        if ($msg -eq 0x7E -or ($msg -eq 0x1A -and $wParam.ToInt64() -eq 0x2F)) { & $script:WmOnChange }
        [IntPtr]::Zero
    }
    $src.AddHook($hook)
    [pscustomobject]@{ Source = $src; Hook = $hook; Handle = $src.Handle }
}

function Invoke-WmMain {
    $settings = Read-WmSettings $SettingsPath
    if (-not $settings) { return 2 }
    if (-not (Test-AVDTuneWatermarkName $settings.Pattern $ComputerName)) { return 0 }   # not a pilot host: nothing else is loaded
    $mutex = $null
    if (-not $DryRun) {
        $mutex = New-Object System.Threading.Mutex($false, 'Local\AVDTune-Watermark')
        $owned = $false
        try { $owned = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
        if (-not $owned) { return 0 }   # this session already has its label
    }
    try {
        Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms
        Initialize-WmNative
        $script:WmItems = @()
        if ($DryRun) {
            Update-WmWindows $settings $false
            foreach ($i in $script:WmItems) { Write-Host ('window {0} x={1} y={2} w={3} h={4} exstyle=0x{5:X}' -f $i.Device, $i.X, $i.Y, $i.Width, $i.Height, [AVDTune.WmNative]::GetWindowLong($i.Handle, -20)) }
            Close-WmWindows
            return 0
        }
        $app = New-Object System.Windows.Application
        $app.ShutdownMode = 'OnExplicitShutdown'
        Update-WmWindows $settings $true
        # redraw after a display or work area change, 400 ms after the last message (several arrive together)
        $script:WmSettings = $settings
        $script:WmTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:WmTimer.Interval = [TimeSpan]::FromMilliseconds(400)
        $script:WmTimer.Add_Tick({ $script:WmTimer.Stop(); try { Update-WmWindows $script:WmSettings $true } catch { } })
        $script:WmOnChange = { $script:WmTimer.Stop(); $script:WmTimer.Start() }
        $script:WmHostHook = New-WmHostHook
        [void]$app.Run()
        return 0
    }
    finally { if ($mutex) { try { $mutex.ReleaseMutex() } catch { }; $mutex.Dispose() } }
}

if ($MyInvocation.InvocationName -ne '.') { exit (Invoke-WmMain) }
