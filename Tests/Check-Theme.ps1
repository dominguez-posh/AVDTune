#requires -Version 5.1
<#
.SYNOPSIS
    Checks AVDTune-Theme.ps1: the dark theme made from the shared theme is valid XAML, has no light color left over, keeps white
    text on the blue button, and both modes load as WPF resource dictionaries with the same keys. No window is shown.
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
. (Join-Path $repo 'AVDTune-Theme.ps1')
$script:failed = 0
function Test-Check([string]$Name, [bool]$Ok, $Detail) { if ($Ok) { "PASS $Name" } else { $script:failed++; "FAIL $Name" + $(if ($null -ne $Detail) { "  -> $Detail" }) } }

$light = Get-AVDTuneThemeXaml -Mode Light
$dark = Get-AVDTuneThemeXaml -Mode Dark
Test-Check 'light mode is the shared file, byte for byte' ($light -eq [IO.File]::ReadAllText((Join-Path $repo 'Shared\UI\Theme.xaml'))) $null
$literals = @([regex]::Matches($light, '"(#[0-9A-Fa-f]{6,8})"') | ForEach-Object { $_.Groups[1].Value.ToUpperInvariant() } | Sort-Object -Unique)
$unmapped = @($literals | Where-Object { -not $script:DarkColors.Contains($_) })
Test-Check 'every color literal of the shared theme has a dark counterpart (theme changed in PackTune? extend the table)' ($unmapped.Count -eq 0) ($unmapped -join ', ')
Test-Check 'dark mode: white backgrounds and borders are gone, white text stays' (($dark -notmatch '(Background|BorderBrush)(=|"\s+Value=)"White"') -and ($dark -match 'Property="Foreground" Value="White"')) $null
$token = [regex]::Match($dark, '<SolidColorBrush x:Key="WindowBackground" Color="(#[0-9A-F]+)"').Groups[1].Value
Test-Check 'dark mode: window background token is dark' ($token -eq '#202020') $token
$ld = ConvertTo-AVDTuneResourceDictionary $light
$dd = ConvertTo-AVDTuneResourceDictionary $dark
Test-Check 'both modes load as WPF dictionaries with the same keys' ($ld.Count -gt 50 -and $ld.Count -eq $dd.Count -and (@($ld.Keys | Where-Object { -not $dd.Contains($_) }).Count -eq 0)) "$($ld.Count) / $($dd.Count)"
Test-Check 'dark tokens differ from light tokens' ($dd['Text'].Color -ne $ld['Text'].Color -and $dd['Surface'].Color -ne $ld['Surface'].Color) $null

# contrast of the main pairs in dark (WCAG)
function Get-Lum($c) {
    $f = { param($v) $x = $v / 255.0; if ($x -le 0.03928) { $x / 12.92 } else { [math]::Pow(($x + 0.055) / 1.055, 2.4) } }
    0.2126 * (& $f $c.R) + 0.7152 * (& $f $c.G) + 0.0722 * (& $f $c.B)
}
function Get-Contrast($a, $b) { $l1 = Get-Lum $a; $l2 = Get-Lum $b; ([math]::Max($l1, $l2) + 0.05) / ([math]::Min($l1, $l2) + 0.05) }
$pairs = @(@('Text', 'Surface', 7), @('Text', 'Card', 7), @('MutedText', 'Surface', 4.5), @('Warning', 'WarningBg', 4.5), @('Success', 'SuccessBg', 4.5), @('Danger', 'ErrorBg', 4.5), @('Primary', 'Surface', 3))
foreach ($p in $pairs) {
    $ratio = Get-Contrast $dd[$p[0]].Color $dd[$p[1]].Color
    Test-Check ("dark contrast {0} on {1} is at least {2}" -f $p[0], $p[1], $p[2]) ($ratio -ge $p[2]) ([math]::Round($ratio, 2))
}
$white = Get-Contrast ([System.Windows.Media.Colors]::White) $dd['Primary'].Color
Test-Check 'dark contrast white on Primary (button text) is at least 3.5' ($white -ge 3.5) ([math]::Round($white, 2))
Test-Check 'system theme is Light or Dark' ((Get-AVDTuneSystemTheme) -in 'Light', 'Dark') $null
if ($script:failed -gt 0) { throw "$script:failed check(s) failed." }
'Check-Theme: all checks passed.'
