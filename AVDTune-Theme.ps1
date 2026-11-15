# AVDTune theme: the shared PackTune theme (Shared\UI\Theme.xaml, never edited here) in light as it is, in dark through a color table.
# WPF freezes the brushes of a loaded theme, so a theme switch loads a different dictionary (Set-AVDTuneTheme) instead of changing colors.
# The window XAML uses DynamicResource for brushes and styles so it follows the swap.

# light color -> dark color, for every color literal of the shared theme (tokens and the literals in styles)
$script:DarkColors = [ordered]@{
    '#F3F3F3' = '#202020'; '#FAFAFA' = '#272727'; '#FFFFFF' = '#2D2D2D'; '#E5E5E5' = '#3F3F3F'; '#1B1B1B' = '#F3F3F3'; '#5F5F5F' = '#ABABAB'
    '#D1D1D1' = '#5A5A5A'; '#F0F0F0' = '#373737'; '#EAEAEA' = '#3A3A3A'; '#005FB8' = '#2F80D1'; '#003E92' = '#1F6BB8'; '#E8F1FB' = '#1F3A57'
    '#F4F8FD' = '#1D2B3B'; '#DFF6DD' = '#1E3B1E'; '#0E5C0E' = '#8FD98F'; '#0F7B0F' = '#6CCB6C'; '#FFF4CE' = '#46391A'; '#7A4A00' = '#F2C46D'
    '#FDE7E9' = '#4A2224'; '#A11D1D' = '#FF8A8A'; '#C42B1C' = '#FF99A4'; '#F5F5F5' = '#353535'; '#EDEDED' = '#383838'; '#EBEBEB' = '#404040'
    '#E9E9E9' = '#404040'; '#F8F8F8' = '#2A2A2A'; '#F7F7F7' = '#2A2A2A'; '#F0F6FC' = '#1D2B3B'; '#DDDDDD' = '#4A4A4A'; '#8A8A8A' = '#8A8A8A'
    '#A0A0A0' = '#7A7A7A'; '#6B6B6B' = '#B0B0B0'; '#3B3B3B' = '#D8D8D8'; '#00316F' = '#144F8F'; '#A32316' = '#C9473A'; '#73000000' = '#99000000'
}

function Get-AVDTuneThemeXaml {
    param([ValidateSet('Light', 'Dark')][string]$Mode = 'Light', [string]$Path = (Join-Path $PSScriptRoot 'Shared\UI\Theme.xaml'))
    $text = [IO.File]::ReadAllText($Path)
    if ($Mode -eq 'Light') { return $text }
    # White as a background or border is a surface; as a foreground (text on the blue button) it stays white
    $text = [regex]::Replace($text, '(Property="(?:Background|BorderBrush)"\s+Value=|(?<![A-Za-z])(?:Background|BorderBrush)=)"White"', '$1"#2D2D2D"')
    $text = [regex]::Replace($text, '"(#[0-9A-Fa-f]{6,8})"', {
            param($m)
            $key = $m.Groups[1].Value.ToUpperInvariant()
            if ($script:DarkColors.Contains($key)) { '"' + $script:DarkColors[$key] + '"' } else { $m.Value }
        })
    $text
}

function ConvertTo-AVDTuneResourceDictionary([string]$Xaml) {
    [xml]$xml = $Xaml
    [Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($xml))
}

function Get-AVDTuneSystemTheme {
    # Light or Dark as Windows is set (apps); Light when it cannot be read
    try {
        $v = (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction Stop).AppsUseLightTheme
        if ($v -eq 0) { 'Dark' } else { 'Light' }
    }
    catch { 'Light' }
}

function Set-AVDTuneTheme {
    # Replaces the theme dictionary of the application; elements that use DynamicResource follow at once
    param([ValidateSet('Light', 'Dark')][string]$Mode)
    $dictionary = ConvertTo-AVDTuneResourceDictionary (Get-AVDTuneThemeXaml -Mode $Mode)
    $merged = [System.Windows.Application]::Current.Resources.MergedDictionaries
    if ($merged.Count -gt 0) { $merged[0] = $dictionary } else { $merged.Add($dictionary) }
    $script:CurrentTheme = $Mode
}
