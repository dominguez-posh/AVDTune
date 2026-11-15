# AVDTune watermark: the pure functions (no UI, no machine access). Dot-sourced by Modules\AVDTune.Watermark.psm1 (settings page, steps) and by
# Show-AVDTuneWatermark.ps1 (the overlay program on the master), so both validate and place the label the same way. Plain ASCII, Windows PowerShell 5.1.

$script:WmCorners = @('BottomRight', 'BottomLeft', 'TopRight', 'TopLeft')
$script:WmConsoleModes = @('Hidden', 'Headless')

function Get-WmProp($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { if ($Object.Contains($Name)) { return $Object[$Name] } else { return $null } }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { $p.Value } else { $null }
}

function Get-AVDTuneWatermarkDefaults {
    [pscustomobject][ordered]@{
        Schema = 1; Pattern = '^avd-pilot-'; Text = 'PILOTUMGEBUNG'; Color = '#D32F2F'; Opacity = 60; FontSize = 20; Corner = 'BottomRight'; Margin = 16
        ConsoleMode = 'Hidden'
        Microsoft = [pscustomobject][ordered]@{ Enabled = $false; QrScale = 4; Opacity = 2000; WidthFactor = 320; HeightFactor = 180 }
    }
}

function Test-AVDTuneWatermarkPattern {
    # The name pattern is a regular expression: compiled with a match timeout so a bad pattern cannot hang the overlay. Returns @{ Valid; Error }
    param([string]$Pattern)
    if ([string]::IsNullOrWhiteSpace($Pattern)) { return [pscustomobject]@{ Valid = $false; Error = 'The name pattern is empty.' } }
    if ($Pattern.Length -gt 200) { return [pscustomobject]@{ Valid = $false; Error = 'The name pattern is longer than 200 characters.' } }
    if ($Pattern -match '[\x00-\x1F\x7F]') { return [pscustomobject]@{ Valid = $false; Error = 'The name pattern contains control characters.' } }
    try { [void](New-Object System.Text.RegularExpressions.Regex($Pattern, 'IgnoreCase, CultureInvariant', [TimeSpan]::FromMilliseconds(250))) }
    catch { return [pscustomobject]@{ Valid = $false; Error = "Not a valid regular expression: $($_.Exception.Message)" } }
    [pscustomobject]@{ Valid = $true; Error = '' }
}

function Test-AVDTuneWatermarkName {
    # True when the computer name matches the pattern (case-insensitive, 250 ms limit). An invalid pattern or a timeout never matches.
    param([string]$Pattern, [string]$Name)
    if (-not (Test-AVDTuneWatermarkPattern $Pattern).Valid -or [string]::IsNullOrEmpty($Name)) { return $false }
    try {
        $re = New-Object System.Text.RegularExpressions.Regex($Pattern, 'IgnoreCase, CultureInvariant', [TimeSpan]::FromMilliseconds(250))
        return [bool]$re.IsMatch($Name)
    }
    catch { return $false }
}

function ConvertTo-WmInt($Value, [string]$Label, [int]$Min, [int]$Max, [System.Collections.ArrayList]$Errors) {
    $n = 0
    if ($null -eq $Value -or "$Value" -notmatch '^\s*-?\d{1,9}\s*$') { [void]$Errors.Add("$Label must be a whole number from $Min to $Max."); return $Min }
    $n = [int]("$Value".Trim())
    if ($n -lt $Min -or $n -gt $Max) { [void]$Errors.Add("$Label must be from $Min to $Max (is $n)."); return [Math]::Min($Max, [Math]::Max($Min, $n)) }
    $n
}

function ConvertTo-AVDTuneWatermarkSettings {
    <#
        Validates settings from json or from the page (any object or hashtable; missing values take the defaults) and returns
        @{ Settings = normalized object; Errors = [text]; Valid }. Nothing is clamped silently: a value out of range is an error (the normalized
        object then carries the nearest allowed value so a page can still show it).
    #>
    param($Raw)
    $d = Get-AVDTuneWatermarkDefaults
    $errors = New-Object System.Collections.ArrayList
    $pick = { param($name, $default) $v = Get-WmProp $Raw $name; if ($null -eq $v) { $default } else { $v } }
    $pattern = [string](& $pick 'Pattern' $d.Pattern)
    $pv = Test-AVDTuneWatermarkPattern $pattern
    if (-not $pv.Valid) { [void]$errors.Add($pv.Error) }
    $text = [string](& $pick 'Text' $d.Text)
    if ($text.Trim().Length -lt 1 -or $text.Length -gt 60) { [void]$errors.Add('The text must have 1 to 60 characters.') }
    if ($text -match '[\x00-\x1F\x7F]') { [void]$errors.Add('The text must not contain control characters (one line only).') }
    $color = ([string](& $pick 'Color' $d.Color)).Trim()
    if ($color -notmatch '^#[0-9A-Fa-f]{6}$') { [void]$errors.Add('The colour must look like #RRGGBB.'); $color = $d.Color }
    $corner = [string](& $pick 'Corner' $d.Corner)
    if ($corner -notin $script:WmCorners) { [void]$errors.Add("The corner must be one of: $($script:WmCorners -join ', ')."); $corner = $d.Corner }
    $mode = [string](& $pick 'ConsoleMode' $d.ConsoleMode)
    if ($mode -notin $script:WmConsoleModes) { [void]$errors.Add("The console mode must be one of: $($script:WmConsoleModes -join ', ')."); $mode = $d.ConsoleMode }
    $ms = & $pick 'Microsoft' $null
    $msEnabled = [bool](Get-WmProp $ms 'Enabled')
    $msPick = { param($name, $default) $v = Get-WmProp $ms $name; if ($null -eq $v) { $default } else { $v } }
    $settings = [pscustomobject][ordered]@{
        Schema = 1; Pattern = $pattern; Text = $text.Trim(); Color = $color.ToUpperInvariant()
        Opacity = (ConvertTo-WmInt (& $pick 'Opacity' $d.Opacity) 'The opacity (percent)' 10 100 $errors)
        FontSize = (ConvertTo-WmInt (& $pick 'FontSize' $d.FontSize) 'The font size' 8 96 $errors)
        Corner = $corner
        Margin = (ConvertTo-WmInt (& $pick 'Margin' $d.Margin) 'The distance from the edge' 0 500 $errors)
        ConsoleMode = $mode
        Microsoft = [pscustomobject][ordered]@{
            Enabled = $msEnabled
            QrScale = (ConvertTo-WmInt (& $msPick 'QrScale' $d.Microsoft.QrScale) 'QR code scale' 1 10 $errors)
            Opacity = (ConvertTo-WmInt (& $msPick 'Opacity' $d.Microsoft.Opacity) 'QR code opacity' 100 9999 $errors)
            WidthFactor = (ConvertTo-WmInt (& $msPick 'WidthFactor' $d.Microsoft.WidthFactor) 'QR code grid width' 100 1000 $errors)
            HeightFactor = (ConvertTo-WmInt (& $msPick 'HeightFactor' $d.Microsoft.HeightFactor) 'QR code grid height' 100 1000 $errors)
        }
    }
    [pscustomobject]@{ Settings = $settings; Errors = @($errors); Valid = ($errors.Count -eq 0) }
}

function Get-AVDTuneWatermarkPublicSettings {
    # The part the overlay reads (the copy that users may read): no Microsoft policy values, no console mode
    param($Settings)
    [pscustomobject][ordered]@{ Schema = 1; Pattern = $Settings.Pattern; Text = $Settings.Text; Color = $Settings.Color; Opacity = $Settings.Opacity; FontSize = $Settings.FontSize; Corner = $Settings.Corner; Margin = $Settings.Margin }
}

function Get-AVDTuneWatermarkPlacement {
    # Top left corner (pixels) of a label of Width x Height inside a work area, for the chosen corner and distance
    param([Parameter(Mandatory)]$WorkArea, [Parameter(Mandatory)][int]$Width, [Parameter(Mandatory)][int]$Height, [string]$Corner = 'BottomRight', [int]$Margin = 16)
    $left = [int]$WorkArea.X; $top = [int]$WorkArea.Y; $right = $left + [int]$WorkArea.Width; $bottom = $top + [int]$WorkArea.Height
    $x = if ($Corner -like '*Right') { $right - $Margin - $Width } else { $left + $Margin }
    $y = if ($Corner -like 'Bottom*') { $bottom - $Margin - $Height } else { $top + $Margin }
    [pscustomobject]@{ X = [Math]::Max($left, $x); Y = [Math]::Max($top, $y) }
}

function ConvertTo-WmRgb([string]$Hex) {
    [pscustomobject]@{ R = [Convert]::ToInt32($Hex.Substring(1, 2), 16); G = [Convert]::ToInt32($Hex.Substring(3, 2), 16); B = [Convert]::ToInt32($Hex.Substring(5, 2), 16) }
}
