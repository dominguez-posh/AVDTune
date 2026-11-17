# AVDTune language: the texts of the window live in UI\Strings.en.json and UI\Strings.de.json (data, never code).
# English is the base: a key that the chosen language lacks falls back to English, a key that English lacks shows the key itself (and the check
# Tests\Check-UiText.ps1 reports both). Dot-sourced by Start-AVDTune.ps1; no WPF needed for the lookup, so the check runs it without a window.
#
# In XAML an element gets its texts through its Uid (Uid="nav.overview"): the Uid is the key of Text/Content, "<uid>.tip" is the ToolTip and
# "<uid>.name" the AutomationProperties.Name. Register-AVDTuneLocalized collects those elements once after the window is loaded;
# Update-AVDTuneLocalized sets the texts again after a switch. In code: Get-AVDTuneText 'key' [format arguments] (alias T).

$script:LangKeyPattern = '\A[a-z0-9.]+\z'
$script:LangMaxFileBytes = 512KB
$script:LangMaxKeyLength = 100
$script:LangMaxValueLength = 4000
$script:LangTexts = @{ en = @{}; de = @{} }
$script:LangCurrent = 'en'
$script:LangLocalized = @()
$script:LangDisplayName = @{ en = 'English'; de = 'Deutsch' }
# Messages that must never fall back to a bare key: if both language files are missing or broken, these English texts still reach the administrator.
$script:LangHard = @{
    'shell.err.admin' = "AVDTune changes the Golden Master and must run as administrator.`nStart it again with 'Run as administrator'."
    'shell.err.running' = 'AVDTune is already running on this computer (one instance at a time).'
    'shell.readonly' = 'Read only: confirm a snapshot of today on the Overview first. Nothing on this page changes the master until then.'
    'shell.aside' = 'The state folder {0} had been prepared by someone else ({1}). It was set aside unread as {2} and a new one was created: the first-run questions, the domain controller pin and the sign-in start again. Check who prepared it, then delete the set-aside folder.'
    'shell.crash.finish' = 'The last finish did not end properly: Windows Update or BITS may still be stopped. Open Cleanup and finish and repair it.'
    'shell.crash.maint' = 'The last maintenance mode did not end properly: the update block may be lifted. Open Update block and repair it.'
    'shell.sessionend' = 'Log off or shut down was held back: an operation (update or benchmark) is still running. Try again when it is done.'
    'rel.toast.bad' = 'The files of AVDTune do not match the release. AVDTune is read only until you repair it on the Overview.'
    'rel.banner.block' = 'Read only: {0} (see the card Integrity and updates on the Overview)'
}

function Test-AVDTuneTextKey {
    param([AllowNull()][string]$Key)
    if ([string]::IsNullOrEmpty($Key) -or $Key.Length -gt $script:LangMaxKeyLength) { return $false }
    try { [regex]::IsMatch($Key, $script:LangKeyPattern, [Text.RegularExpressions.RegexOptions]::None, [timespan]::FromMilliseconds(200)) } catch { $false }
}

function Read-AVDTuneStringFile {
    <# A language file as a hashtable key -> text. Data only: a flat JSON object, every key a lower case dotted name, every value a string.
       Anything else (nested object, number, boolean, null, array, other key) refuses the whole file. #>
    param([Parameter(Mandatory)][string]$Path)
    $file = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($file.PSIsContainer -or $file.Length -gt $script:LangMaxFileBytes) { throw "Language file $($file.Name) is not a small file." }
    $obj = [IO.File]::ReadAllText($file.FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json
    if ($obj -isnot [pscustomobject]) { throw "Language file $($file.Name) must be one JSON object." }
    $texts = @{}
    foreach ($p in $obj.PSObject.Properties) {
        if (-not (Test-AVDTuneTextKey $p.Name)) { throw "Language file $($file.Name): the key '$($p.Name)' is not a lower case dotted name." }
        if ($p.Value -isnot [string]) { throw "Language file $($file.Name): the value of '$($p.Name)' is not a string." }
        if ($p.Value.Length -gt $script:LangMaxValueLength) { throw "Language file $($file.Name): the text of '$($p.Name)' is too long." }
        $texts[$p.Name] = [string]$p.Value
    }
    $texts
}

function Initialize-AVDTuneLanguage {
    # Loads both files from the UI folder. A file that is not valid is not used (English alone remains); the reason is returned in Problems.
    param([string]$Folder = (Join-Path $PSScriptRoot 'UI'))
    $problems = New-Object System.Collections.Generic.List[string]
    foreach ($lang in 'en', 'de') {
        try { $script:LangTexts[$lang] = Read-AVDTuneStringFile (Join-Path $Folder "Strings.$lang.json") }
        catch { $script:LangTexts[$lang] = @{}; $problems.Add($_.Exception.Message) }
    }
    [pscustomobject]@{ Problems = @($problems); Keys = @{ en = $script:LangTexts.en.Count; de = $script:LangTexts.de.Count } }
}

function Get-AVDTuneLanguage { $script:LangCurrent }
function Set-AVDTuneLanguage {
    param([Parameter(Mandatory)][ValidateSet('en', 'de')][string]$Language)
    $script:LangCurrent = $Language
}
function Get-AVDTuneLanguageName([string]$Language = $script:LangCurrent) { $script:LangDisplayName[$Language] }

function Get-AVDTuneTextTable([ValidateSet('en', 'de')][string]$Language) { $script:LangTexts[$Language] }

function Get-AVDTuneText {
    <# The text of a key in the chosen language, English when it lacks the key, the key itself when English lacks it too.
       With arguments the text is a .NET format string ({0}, {1}); without, braces stay as they are. #>
    param([Parameter(Mandatory, Position = 0)][string]$Key, [Parameter(Position = 1, ValueFromRemainingArguments)][object[]]$FormatArgs)
    $text = $script:LangTexts[$script:LangCurrent][$Key]
    if ($null -eq $text) { $text = $script:LangTexts.en[$Key] }
    if ($null -eq $text) { $text = $script:LangHard[$Key] }   # both files missing or broken: a hard English text for the messages that matter
    if ($null -eq $text) { return $Key }
    if ($FormatArgs -and $FormatArgs.Count -gt 0) { try { return [string]::Format($text, [object[]]$FormatArgs) } catch [System.FormatException] { return $text } }
    $text
}
Set-Alias -Name T -Value Get-AVDTuneText -Scope Script

function Get-AVDTuneEngineText {
    <# Text that an engine module made in English: shown in the chosen language when it is exactly the English text of the key (a fixed message),
       as it is otherwise (a message with data in it). #>
    param([Parameter(Mandatory)][string]$Key, [AllowNull()][string]$EngineText)
    if ($script:LangCurrent -ne 'en' -and $EngineText -ceq $script:LangTexts.en[$Key]) { return (Get-AVDTuneText $Key) }
    $EngineText
}

function Convert-AVDTuneEngineText {
    <# Same idea for a text that may be one of several fixed messages: when it is exactly the English text of a key that starts with $Prefix,
       the text of that key in the chosen language; otherwise (a message with data in it) the text as it is. #>
    param([Parameter(Mandatory)][string]$Prefix, [AllowNull()][string]$EngineText)
    if ($script:LangCurrent -eq 'en' -or [string]::IsNullOrEmpty($EngineText)) { return $EngineText }
    foreach ($entry in $script:LangTexts.en.GetEnumerator()) {
        if ($entry.Key.StartsWith($Prefix, [StringComparison]::Ordinal) -and $EngineText -ceq $entry.Value) { return (Get-AVDTuneText $entry.Key) }
    }
    $EngineText
}

function Get-AVDTuneMissingTexts {
    # What the check wants to be empty: keys of English that German lacks and the other way round
    [pscustomobject]@{
        MissingInGerman = @($script:LangTexts.en.Keys | Where-Object { -not $script:LangTexts.de.ContainsKey($_) } | Sort-Object)
        MissingInEnglish = @($script:LangTexts.de.Keys | Where-Object { -not $script:LangTexts.en.ContainsKey($_) } | Sort-Object)
    }
}

# ---------------------------------------------------------------- XAML elements
function Register-AVDTuneLocalized {
    # Walks the logical tree once and keeps the elements that have a Uid in the key pattern with a dot ("nav.overview"); elements made later in code are not in it.
    param([Parameter(Mandatory)]$Root)
    $found = New-Object System.Collections.Generic.List[object]
    $walk = {
        param($node)
        if ($node -isnot [System.Windows.DependencyObject]) { return }
        if ($node -is [System.Windows.UIElement] -and $node.Uid -and $node.Uid.Contains('.') -and (Test-AVDTuneTextKey $node.Uid)) { $found.Add(@{ Element = $node; Uid = [string]$node.Uid }) }
        foreach ($child in [System.Windows.LogicalTreeHelper]::GetChildren($node)) { & $walk $child }
    }
    & $walk $Root
    $script:LangLocalized = $found.ToArray()
    $script:LangLocalized.Count
}

function Test-AVDTuneHasText([string]$Key) { $script:LangTexts[$script:LangCurrent].ContainsKey($Key) -or $script:LangTexts.en.ContainsKey($Key) -or $script:LangHard.ContainsKey($Key) }

function Update-AVDTuneLocalized {
    foreach ($entry in $script:LangLocalized) {
        $el = $entry.Element; $uid = $entry.Uid
        if (Test-AVDTuneHasText $uid) {
            $text = Get-AVDTuneText $uid
            if ($el -is [System.Windows.Controls.TextBlock]) { $el.Text = $text }
            elseif ($el -is [System.Windows.Controls.ContentControl]) { $el.Content = $text }
        }
        if (Test-AVDTuneHasText "$uid.tip") { $el.ToolTip = Get-AVDTuneText "$uid.tip" }
        if (Test-AVDTuneHasText "$uid.name") { [System.Windows.Automation.AutomationProperties]::SetName($el, (Get-AVDTuneText "$uid.name")) }
    }
}
