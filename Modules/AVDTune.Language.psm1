<#
    AVDTune language and region side (docs\plans\avdtune.md, section 11 phase 6; issue 56 part 1; docs\language.md): language packs and Language Features on a
    Windows 11 multi-session master, and the defaults for new users (display language, regional format, input, location, system locale, time zone).

      * Every access to the master goes through the machine adapter ($m: registry, tasks) and the language adapter ($L: installed languages, DISM, the
        international settings, time zone). Tests\Fakes\FakeLanguage.ps1 has the fake; New-AVDTuneLanguageAdapter is the real one and is NOT exercised by the
        checks beyond construction (no install, no setting changed on a developer machine).
      * Language packs and Features on Demand come only from a content folder the administrator names (the "LanguagesAndOptionalFeatures" content of the
        Microsoft ISO, mounted or on a share; Learn: windows-11-language-packs). AVDTune downloads nothing. DISM (full path, signature checked, started through
        the central child environment in a job object) installs from that folder with /LimitAccess, so it never goes to the internet.
      * New users: the documented way for Windows 11 is to set the values for the current user and then Copy-UserInternationalSettingsToSystem
        -WelcomeScreen $true -NewUser $true. Set values are read back from HKEY_USERS\.DEFAULT (welcome screen and system accounts); the profile of new users
        (C:\Users\Default) is not read (it would need a hive load) and is not verified until the VM test (#17).
      * Every change is a step (Invoke-AVDTune: write gate, Test before and after, run record, LastChange, change log). Language install has no undo
        (named in the confirmation). The values found before the first change are kept in config\language-undo.json (never overwritten); Undo only undoes steps
        that this tool changed (config\language-applied.json).
#>

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'AVDTune.psm1')
Import-Module (Join-Path $PSScriptRoot 'AVDTune.Updates.psm1')

$script:Learn = 'https://learn.microsoft.com'
$script:Src = @{
    Avd = "$script:Learn/en-us/azure/virtual-desktop/windows-11-language-packs"
    Copy = "$script:Learn/en-us/powershell/module/international/copy-userinternationalsettingstosystem"
    Languages = "$script:Learn/en-us/windows-hardware/manufacture/desktop/languages-overview"
    Available = "$script:Learn/en-us/windows-hardware/manufacture/desktop/available-language-packs-for-windows"
    TimeZone = "$script:Learn/en-us/powershell/module/microsoft.powershell.management/set-timezone"
    Geo = "$script:Learn/en-us/windows/win32/intl/table-of-geographical-locations"
}
$script:Def = 'Registry::HKEY_USERS\.DEFAULT'
$script:CleanupKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Control Panel\International'

#region catalog

# The common languages (same list as the Office page). Klid = default keyboard layout (hex), FontGroup = the satellite font package some languages need
# (Learn: "Some languages require additional fonts ... Japanese: Jpan"). Name is for display only.
$script:Languages = @(
    @{ Tag = 'de-DE'; Name = 'German (Germany)'; Klid = '00000407' }
    @{ Tag = 'en-US'; Name = 'English (United States)'; Klid = '00000409' }
    @{ Tag = 'en-GB'; Name = 'English (United Kingdom)'; Klid = '00000809' }
    @{ Tag = 'fr-FR'; Name = 'French (France)'; Klid = '0000040C' }
    @{ Tag = 'it-IT'; Name = 'Italian (Italy)'; Klid = '00000410' }
    @{ Tag = 'es-ES'; Name = 'Spanish (Spain)'; Klid = '0000040A' }
    @{ Tag = 'nl-NL'; Name = 'Dutch (Netherlands)'; Klid = '00000413' }
    @{ Tag = 'pl-PL'; Name = 'Polish (Poland)'; Klid = '00000415' }
    @{ Tag = 'pt-PT'; Name = 'Portuguese (Portugal)'; Klid = '00000816' }
    @{ Tag = 'pt-BR'; Name = 'Portuguese (Brazil)'; Klid = '00000416' }
    @{ Tag = 'sv-SE'; Name = 'Swedish (Sweden)'; Klid = '0000041D' }
    @{ Tag = 'da-DK'; Name = 'Danish (Denmark)'; Klid = '00000406' }
    @{ Tag = 'nb-NO'; Name = 'Norwegian Bokmal (Norway)'; Klid = '00000414' }
    @{ Tag = 'fi-FI'; Name = 'Finnish (Finland)'; Klid = '0000040B' }
    @{ Tag = 'cs-CZ'; Name = 'Czech (Czechia)'; Klid = '00000405' }
    @{ Tag = 'tr-TR'; Name = 'Turkish (Turkey)'; Klid = '0000041F' }
    @{ Tag = 'ja-JP'; Name = 'Japanese (Japan)'; Klid = '00000411'; FontGroup = 'Jpan' }
    @{ Tag = 'zh-CN'; Name = 'Chinese (Simplified, PRC)'; Klid = '00000804'; FontGroup = 'Hans' }
)
# Regional formats that need no language pack (formats only), in addition to the languages above
$script:ExtraCultures = @(
    @{ Tag = 'de-AT'; Name = 'German (Austria)' }, @{ Tag = 'de-CH'; Name = 'German (Switzerland)' }, @{ Tag = 'fr-CH'; Name = 'French (Switzerland)' }
    @{ Tag = 'fr-BE'; Name = 'French (Belgium)' }, @{ Tag = 'nl-BE'; Name = 'Dutch (Belgium)' }, @{ Tag = 'en-IE'; Name = 'English (Ireland)' }
)
# Geographical location (GeoId, Learn: table-of-geographical-locations)
$script:Regions = @(
    @{ Id = 94; Name = 'Germany' }, @{ Id = 14; Name = 'Austria' }, @{ Id = 223; Name = 'Switzerland' }, @{ Id = 244; Name = 'United States' }, @{ Id = 242; Name = 'United Kingdom' }
    @{ Id = 68; Name = 'Ireland' }, @{ Id = 84; Name = 'France' }, @{ Id = 21; Name = 'Belgium' }, @{ Id = 118; Name = 'Italy' }, @{ Id = 217; Name = 'Spain' }
    @{ Id = 176; Name = 'Netherlands' }, @{ Id = 191; Name = 'Poland' }, @{ Id = 193; Name = 'Portugal' }, @{ Id = 32; Name = 'Brazil' }, @{ Id = 221; Name = 'Sweden' }
    @{ Id = 61; Name = 'Denmark' }, @{ Id = 177; Name = 'Norway' }, @{ Id = 77; Name = 'Finland' }, @{ Id = 75; Name = 'Czechia' }, @{ Id = 235; Name = 'Turkey' }
    @{ Id = 122; Name = 'Japan' }, @{ Id = 45; Name = 'China' }
)
# Default time zone of an Azure region (Windows time zone id). Only a default: the administrator chooses. Regions not listed get no default.
$script:AzureZones = @{
    westeurope = 'W. Europe Standard Time'; northeurope = 'GMT Standard Time'; germanywestcentral = 'W. Europe Standard Time'; germanynorth = 'W. Europe Standard Time'
    switzerlandnorth = 'W. Europe Standard Time'; switzerlandwest = 'W. Europe Standard Time'; francecentral = 'Romance Standard Time'; francesouth = 'Romance Standard Time'
    italynorth = 'W. Europe Standard Time'; spaincentral = 'Romance Standard Time'; polandcentral = 'Central European Standard Time'; swedencentral = 'W. Europe Standard Time'
    norwayeast = 'W. Europe Standard Time'; norwaywest = 'W. Europe Standard Time'; uksouth = 'GMT Standard Time'; ukwest = 'GMT Standard Time'
    eastus = 'Eastern Standard Time'; eastus2 = 'Eastern Standard Time'; centralus = 'Central Standard Time'; southcentralus = 'Central Standard Time'
    westus = 'Pacific Standard Time'; westus2 = 'Pacific Standard Time'; westus3 = 'US Mountain Standard Time'; brazilsouth = 'E. South America Standard Time'
    japaneast = 'Tokyo Standard Time'; japanwest = 'Tokyo Standard Time'; turkeycentral = 'Turkey Standard Time'
}
# the version part of a Windows capability name (Language.Basic~~~de-DE~<version>)
$script:CapVersion = '0.0.1.0'   # public-content-ok: version part of a Windows capability name, not an IP address
$script:Sections = @('Languages', 'Defaults')
$script:Features = @('Basic', 'Handwriting', 'OCR', 'Speech', 'TextToSpeech')

function Get-AVDTuneLanguageCatalog { @($script:Languages | ForEach-Object { [pscustomobject]@{ Tag = $_.Tag; Name = $_.Name; Klid = $_.Klid; FontGroup = $(if ($_.ContainsKey('FontGroup')) { $_.FontGroup } else { '' }) } }) }
function Get-AVDTuneLanguageCultures { @(@($script:Languages) + @($script:ExtraCultures) | ForEach-Object { [pscustomobject]@{ Tag = $_.Tag; Name = $_.Name } }) }
function Get-AVDTuneLanguageRegions { @($script:Regions | ForEach-Object { [pscustomobject]@{ Id = [int]$_.Id; Name = $_.Name } }) }
function Get-AVDTuneLanguageInputs {
    # The default keyboard of each language as an input tip (LCID:KLID, Set-WinUserLanguageList InputMethodTips)
    @($script:Languages | ForEach-Object {
            $lcid = ([cultureinfo]$_.Tag).LCID.ToString('X4')
            [pscustomobject]@{ Tip = "${lcid}:$($_.Klid)"; Name = "$($_.Name), default keyboard"; Klid = $_.Klid; Tag = $_.Tag }
        })
}
function Get-AVDTuneLanguageSources { $script:Src.Clone() }
function Get-AVDTuneLanguageAzureZone([string]$Region) { $k = $Region.ToLowerInvariant(); if ($script:AzureZones.ContainsKey($k)) { $script:AzureZones[$k] } else { $null } }

#endregion

#region configuration (data, validated)

function Test-AVDTuneLanguageSource {
    <#
        Syntax of the content folder, anchored at both ends: a local drive path (C:\x\y) or a share path (\\server\share\x), made of plain components only. Refused: relative paths, "..", "." as a part,
        "/", device and long paths (\\.\, \\?\), alternate streams (":"), administrative shares (X$), localhost, loopback addresses, the name of this computer and every character that is not allowed in names.
    #>
    param([string]$Path, [string]$ComputerName = [Environment]::MachineName)
    if (-not $Path -or $Path.Length -gt 260 -or $Path.Contains('/') -or $Path -match '\.\.' -or $Path -match '[\x00-\x1F"<>|*?]') { return $false }
    if ($Path -match '(^|\\)\.(\\|$)') { return $false }
    $comp = '[^\\/:*?"<>|\x00-\x1F]+'
    $t = [TimeSpan]::FromMilliseconds(200)
    if ([regex]::IsMatch($Path, ('^[A-Za-z]:\\(?:COMP(?:\\COMP)*\\?)?\z').Replace('COMP', $comp), 'None', $t)) { return $true }
    $m = [regex]::Match($Path, ('^\\\\(?<h>[A-Za-z0-9][A-Za-z0-9._-]{0,62})\\(?<s>[A-Za-z0-9._ -]{1,80})(?:\\COMP)*\\?\z').Replace('COMP', $comp), 'None', $t)
    if (-not $m.Success) { return $false }
    $h = $m.Groups['h'].Value.TrimEnd('.')
    if ($h -imatch '^(localhost|127\.|0\.0\.0\.0)') { return $false }
    if ($ComputerName -and ($h -ieq $ComputerName -or $h -ilike "$ComputerName.*")) { return $false }
    $true
}

function Get-AVDTuneLanguageSourceChain {
    # The path and every folder above it up to the drive root or the share root (\\server\share): all of them are checked
    param([Parameter(Mandatory)][string]$Path)
    $chain = New-Object System.Collections.ArrayList
    $cur = $Path; if ($cur.Length -gt 3) { $cur = $cur.TrimEnd('\') } elseif ($cur -match '^[A-Za-z]:$') { $cur += '\' }
    for ($n = 0; $n -lt 64 -and $cur; $n++) {
        [void]$chain.Add($cur)
        if ($cur -match '^[A-Za-z]:\\?$' -or $cur -match '^\\\\[^\\]+\\[^\\]+$') { break }
        $idx = $cur.LastIndexOf('\'); if ($idx -lt 2) { break }
        $cur = $cur.Substring(0, $idx); if ($cur -match '^[A-Za-z]:$') { $cur += '\' }
    }
    @($chain)
}

function Get-AVDTuneLanguageSourceVerdict {
    <#
        Is this folder fit to install language packs from? The probe ($Probe: Exists, IsLink, IsSubst, DriveType, IsMountedIso, AdminOnly) is the only thing that touches the machine, so the checks can run with a fake.
        Every part of the path including the drive or share root must not be a link. A substituted drive (subst) is refused. A mapped network drive counts as a share. Only an ISO that Windows mounted itself (a CD drive that belongs to a virtual disk image) counts as read-only media and is fine; a physical optical drive is checked like a local folder. Everything else (a local folder or a share) must be admin-only in every part,
        the root included (a drive root such as C:\ lets users create folders and is refused). Returns @{ Ok; Kind (Media | Local | Share); Problem }.
    #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Probe, [string]$ComputerName = [Environment]::MachineName)
    $no = { param($Text, $Kind) @{ Ok = $false; Kind = $Kind; Problem = $Text } }
    if (-not (Test-AVDTuneLanguageSource $Path -ComputerName $ComputerName)) { return (& $no 'Not a plain local or share path (no relative parts, "/", device paths, administrative shares, this computer or a loopback address).' '') }
    if (-not (& $Probe.Exists $Path)) { return (& $no 'The folder does not exist.' '') }
    $chain = @(Get-AVDTuneLanguageSourceChain $Path)
    foreach ($c in $chain) { if (& $Probe.IsLink $c) { return (& $no "A part of the path is a link: $c" '') } }
    $kind = 'Share'
    if (-not $Path.StartsWith('\\')) {
        if (& $Probe.IsSubst $Path) { return (& $no 'The drive letter is a substituted drive (subst); name the real folder.' '') }
        $dt = & $Probe.DriveType $Path
        $kind = if ($dt -eq 'Network') { 'Share' } elseif ($dt -eq 'CDRom' -and (& $Probe.IsMountedIso $Path)) { 'Media' } else { 'Local' }
    }
    if ($kind -eq 'Media') { return @{ Ok = $true; Kind = 'Media'; Problem = '' } }
    foreach ($c in $chain) { if (-not (& $Probe.AdminOnly $c)) { return (& $no "$c can be written by users who are not administrators; use the mounted ISO or an admin-only folder." $kind) } }
    @{ Ok = $true; Kind = $kind; Problem = '' }
}

function New-AVDTuneLanguageSourceProbe {
    # The real probe: reads the file system and the permissions (read only)
    [pscustomobject]@{
        Exists = { param($p) [IO.Directory]::Exists($p) }
        IsLink = { param($p) ((New-Object IO.DirectoryInfo $p).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 }
        DriveType = { param($p) [string](New-Object IO.DriveInfo ($p.Substring(0, 1))).DriveType }
        IsSubst = {
            # a drive made with subst has a DOS device target that starts with \??\ (a mapped network drive points to the redirector, a real drive to a volume)
            param($p)
            if (-not ('AVDTuneLang.Dos' -as [type])) { Add-Type -TypeDefinition 'using System; using System.Text; using System.Runtime.InteropServices; namespace AVDTuneLang { public static class Dos { [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern uint QueryDosDevice(string name, StringBuilder buffer, int max); public static string Target(string drive) { var sb = new StringBuilder(1024); return QueryDosDevice(drive, sb, 1024) == 0 ? "" : sb.ToString(); } } }' }
            ([AVDTuneLang.Dos]::Target($p.Substring(0, 2))).StartsWith('\??\')
        }
        IsMountedIso = { param($p) try { $di = Get-Volume -DriveLetter $p.Substring(0, 1) -ErrorAction Stop | Get-DiskImage -ErrorAction Stop; [bool]$di.ImagePath } catch { $false } }   # an ISO mounted by Windows (virtual disk), not a physical drive
        AdminOnly = { param($p) Test-AVDTuneAdminOnlyPath -Path $p }   # no Base: this folder only, its permissions are read (also for a drive root)
    }
}
function Test-AVDTuneLanguageConfig {
    # Problems of a configuration as texts; empty = valid. Strict types: "94" is not 94. A missing value or $null/'' means "leave as it is".
    param($Config, [string[]]$InstalledTags = @())
    $p = New-Object System.Collections.ArrayList
    if ($null -eq $Config) { return @('There is no configuration.') }
    $get = { param($n) Get-AVDTuneProp $Config $n }
    $tags = @($script:Languages | ForEach-Object { $_.Tag }); $cultures = @(Get-AVDTuneLanguageCultures | ForEach-Object { $_.Tag })
    $langs = & $get 'Languages'
    if ($null -ne $langs) {
        if (@($langs).Count -gt 20) { [void]$p.Add('At most 20 languages.') }
        $seen = @{}
        foreach ($l in @($langs)) {
            if ($l -isnot [string] -or $l -cnotin $tags) { [void]$p.Add("'$l' is not a language of the list."); continue }
            if ($seen.ContainsKey($l)) { [void]$p.Add("Language '$l' appears twice.") }
            $seen[$l] = $true
        }
    }
    $src = & $get 'Source'
    if ($null -ne $src -and $src -ne '' -and ($src -isnot [string] -or -not (Test-AVDTuneLanguageSource $src))) { [void]$p.Add('The content folder must be a local drive path or a share path (\\server\share), without "..".') }
    $newTags = @(@($langs) | Where-Object { $_ -is [string] -and $_ -inotin $InstalledTags })
    if ($newTags.Count -gt 0 -and -not $src) { [void]$p.Add('A content folder (LanguagesAndOptionalFeatures of the Microsoft ISO) is needed to install a language.') }
    $ui = & $get 'UiLanguage'
    if ($null -ne $ui -and $ui -ne '' -and ($ui -isnot [string] -or $ui -cnotin $tags)) { [void]$p.Add("The display language '$ui' is not a language of the list.") }
    $cu = & $get 'Culture'
    if ($null -ne $cu -and $cu -ne '' -and ($cu -isnot [string] -or $cu -cnotin $cultures)) { [void]$p.Add("The regional format '$cu' is not on the list.") }
    $tip = & $get 'InputTip'
    if ($null -ne $tip -and $tip -ne '' -and ($tip -isnot [string] -or $tip -cnotin @(Get-AVDTuneLanguageInputs | ForEach-Object Tip))) { [void]$p.Add("The input '$tip' is not on the list.") }
    $geo = & $get 'GeoId'
    if ($null -ne $geo -and ($geo -isnot [int] -or $geo -notin @($script:Regions | ForEach-Object { $_.Id }))) { [void]$p.Add('The location is not on the list (a number from the list).') }
    $sl = & $get 'SystemLocale'
    if ($null -ne $sl -and $sl -ne '' -and ($sl -isnot [string] -or $sl -cnotin $cultures)) { [void]$p.Add("The system locale '$sl' is not on the list.") }
    $tz = & $get 'TimeZone'
    if ($null -ne $tz -and $tz -ne '' -and ($tz -isnot [string] -or -not [regex]::IsMatch($tz, "^[A-Za-z0-9 .,()+'-]{1,80}\z", 'None', [TimeSpan]::FromMilliseconds(200)))) { [void]$p.Add('The time zone is not a Windows time zone id.') }
    @($p)
}

function ConvertTo-AVDTuneLanguageConfig {
    param([Parameter(Mandatory)]$Config, [string[]]$InstalledTags = @())
    $problems = @(Test-AVDTuneLanguageConfig $Config -InstalledTags $InstalledTags)
    if ($problems.Count -gt 0) { throw "The language configuration is not valid: $($problems -join ' ')" }
    $s = { param($n) $v = Get-AVDTuneProp $Config $n; if ($null -eq $v -or $v -eq '') { $null } else { [string]$v } }
    $g = Get-AVDTuneProp $Config 'GeoId'
    [pscustomobject][ordered]@{
        Languages = @(@(Get-AVDTuneProp $Config 'Languages') | Where-Object { $_ } | ForEach-Object { [string]$_ })
        Source = (& $s 'Source'); UiLanguage = (& $s 'UiLanguage'); Culture = (& $s 'Culture'); InputTip = (& $s 'InputTip'); GeoId = $(if ($null -eq $g) { $null } else { [int]$g })
        SystemLocale = (& $s 'SystemLocale'); TimeZone = (& $s 'TimeZone')
    }
}

function Get-AVDTuneLanguageDefaults { [pscustomobject][ordered]@{ Languages = @(); Source = $null; UiLanguage = $null; Culture = $null; InputTip = $null; GeoId = $null; SystemLocale = $null; TimeZone = $null } }
function Get-AVDTuneLanguageConfigPath([string]$Root) { Join-Path $Root 'config\language.json' }
function Get-AVDTuneLanguageUndoPath([string]$Root) { Join-Path $Root 'config\language-undo.json' }
function Get-AVDTuneLanguageAppliedPath([string]$Root) { Join-Path $Root 'config\language-applied.json' }

function Get-AVDTuneLanguageConfig {
    # The saved configuration; a saved file that is not valid is an error (fail closed)
    param([string]$Root = (Get-AVDTuneRoot))
    $o = Read-AVDTuneJson (Get-AVDTuneLanguageConfigPath $Root)
    if ($null -eq $o) { return Get-AVDTuneLanguageDefaults }
    try { ConvertTo-AVDTuneLanguageConfig $o } catch { throw "config\language.json is not usable: $($_.Exception.Message)" }
}

function Set-AVDTuneLanguageConfig {
    # Saves the settings of the form (no change of the master, no gate needed)
    param([string]$Root = (Get-AVDTuneRoot), [Parameter(Mandatory)]$Config)
    $c = ConvertTo-AVDTuneLanguageConfig $Config
    Write-AVDTuneFile (Get-AVDTuneLanguageConfigPath $Root) ($c | ConvertTo-Json -Depth 4)
    $c
}

#endregion

#region state (read only)

function ConvertTo-AVDTuneLcidName([string]$Hex) {
    if ($Hex -notmatch '^[0-9A-Fa-f]{1,8}\z') { return $null }
    try { $n = [cultureinfo]::GetCultureInfo([Convert]::ToInt32($Hex, 16)).Name; if ($n) { $n } else { $null } } catch { $null }
}

function Get-AVDTuneLanguageNewUser {
    # What new users and the welcome screen get now: HKEY_USERS\.DEFAULT (the target of Copy-UserInternationalSettingsToSystem). The default profile (C:\Users\Default) is not read.
    param([Parameter(Mandatory)]$Machine)
    $ui = @(& $Machine.RegGet "$script:Def\Control Panel\Desktop" 'PreferredUILanguages')[0]
    $cu = & $Machine.RegGet "$script:Def\Control Panel\International" 'LocaleName'
    $klid = [string](& $Machine.RegGet "$script:Def\Keyboard Layout\Preload" '1')
    $tip = $null; if ($klid) { $m = @(Get-AVDTuneLanguageInputs | Where-Object { $_.Klid -ieq $klid }); if ($m.Count -gt 0) { $tip = $m[0].Tip } else { $tip = "?:$klid" } }
    $geo = & $Machine.RegGet "$script:Def\Control Panel\International\Geo" 'Nation'
    $geoId = $null; if ($null -ne $geo -and [string]$geo -match '^[0-9]{1,4}\z') { $geoId = [int]$geo }
    [pscustomobject]@{ Ui = $(if ($ui) { [string]$ui } else { $null }); Culture = $(if ($cu) { [string]$cu } else { $null }); InputTip = $tip; GeoId = $geoId }
}

function Get-AVDTuneLanguageState {
    param([Parameter(Mandatory)]$Machine, [Parameter(Mandatory)]$L)
    $installed = @(& $L.GetInstalled)
    $sys = ConvertTo-AVDTuneLcidName ([string](& $Machine.RegGet 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\Locale' '(default)'))
    $tz = & $Machine.RegGet 'HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation' 'TimeZoneKeyName'
    $region = ''
    try { $imds = & $Machine.Imds; $c = Get-AVDTuneProp $imds 'compute'; if ($c) { $region = [string](Get-AVDTuneProp $c 'location') } } catch { }
    [pscustomobject]@{
        Installed = $installed; NewUser = (Get-AVDTuneLanguageNewUser $Machine); SystemLocale = $sys; TimeZone = $(if ($tz) { [string]$tz } else { $null })
        AzureRegion = $region; DefaultTimeZone = $(if ($region -match '^[a-z0-9]{3,40}\z') { Get-AVDTuneLanguageAzureZone $region } else { $null }); Admin = (& $L.GetUserIntl)
    }
}

function Resolve-AVDTuneLanguageConfig {
    # The values a run sets: what the configuration names, otherwise what is there now (so a copy to new users never changes a value that was not chosen)
    param($Config, $State)
    $pick = { param($c, $cur) if ($c) { $c } else { $cur } }
    [pscustomobject]@{
        Ui = (& $pick $Config.UiLanguage $State.NewUser.Ui); Culture = (& $pick $Config.Culture $State.NewUser.Culture); InputTip = (& $pick $Config.InputTip $State.NewUser.InputTip)
        GeoId = $(if ($null -ne $Config.GeoId) { [int]$Config.GeoId } else { $State.NewUser.GeoId }); SystemLocale = (& $pick $Config.SystemLocale $State.SystemLocale); TimeZone = (& $pick $Config.TimeZone $State.TimeZone)
    }
}

function New-AVDTuneLanguageRow([string]$Id, [string]$Title, [string]$Status, [string]$Reason, [string]$Source, [bool]$Verified = $true, [string]$Note = '') {
    [pscustomobject]@{ Id = $Id; Title = $Title; Status = $Status; Reason = $Reason; Source = $Source; Verified = $Verified; Note = $Note }
}

function Get-AVDTuneLanguageRows {
    # Analysis only (nothing is changed, LastChange is not touched): one row per setting with the actual state and what the configuration wants
    param([Parameter(Mandatory)]$Machine, [Parameter(Mandatory)]$L, [Parameter(Mandatory)]$Config)
    $st = Get-AVDTuneLanguageState -Machine $Machine -L $L
    $want = Resolve-AVDTuneLanguageConfig $Config $st
    $rows = New-Object System.Collections.ArrayList
    $cmp = { param($have, $w, $text) if ($null -eq $w -or $w -eq '') { 'info' } elseif ("$have" -ieq "$w") { 'ok' } else { 'warn' } }
    $inst = @($st.Installed | ForEach-Object { $_.Tag })
    foreach ($t in @($Config.Languages)) {
        [void]$rows.Add((New-AVDTuneLanguageRow "language.add.$($t.ToLowerInvariant())" "Language $t" $(if ($t -in $inst) { 'ok' } else { 'warn' }) $(if ($t -in $inst) { 'Installed.' } else { 'Not installed: it is installed from the content folder.' }) $script:Src.Avd))
    }
    [void]$rows.Add((New-AVDTuneLanguageRow 'language.ui' 'Display language for new users and the welcome screen' (& $cmp $st.NewUser.Ui $want.Ui) "Now: $(if ($st.NewUser.Ui) { $st.NewUser.Ui } else { 'not set' })" $script:Src.Copy $false 'Read from the .DEFAULT hive; the default profile for new users is not read (VM test, #17).'))
    [void]$rows.Add((New-AVDTuneLanguageRow 'language.culture' 'Regional format (numbers, dates)' (& $cmp $st.NewUser.Culture $want.Culture) "Now: $(if ($st.NewUser.Culture) { $st.NewUser.Culture } else { 'not set' })" $script:Src.Copy $false))
    [void]$rows.Add((New-AVDTuneLanguageRow 'language.input' 'Input (keyboard)' (& $cmp $st.NewUser.InputTip $want.InputTip) "Now: $(if ($st.NewUser.InputTip) { $st.NewUser.InputTip } else { 'not set' })" $script:Src.Copy $false))
    [void]$rows.Add((New-AVDTuneLanguageRow 'language.geo' 'Location (GeoId)' (& $cmp $st.NewUser.GeoId $want.GeoId) "Now: $(if ($null -ne $st.NewUser.GeoId) { $st.NewUser.GeoId } else { 'not set' })" $script:Src.Copy $false))
    [void]$rows.Add((New-AVDTuneLanguageRow 'language.sysloc' 'System locale (programs without Unicode, restart needed)' (& $cmp $st.SystemLocale $want.SystemLocale) "Now: $(if ($st.SystemLocale) { $st.SystemLocale } else { 'not set' })" $script:Src.Languages $false))
    [void]$rows.Add((New-AVDTuneLanguageRow 'language.timezone' 'Time zone' (& $cmp $st.TimeZone $want.TimeZone) "Now: $(if ($st.TimeZone) { $st.TimeZone } else { 'not set' })$(if ($st.DefaultTimeZone) { "; default of region $($st.AzureRegion): $($st.DefaultTimeZone)" })" $script:Src.TimeZone))
    @($rows)
}

#endregion

#region install (DISM)

function Get-AVDTuneLanguageDismCalls {
    <#
        The DISM calls that install one language from the content folder, in the order of the Learn script (windows-11-language-packs): the client language pack, the five
        language features as capabilities (Basic, Handwriting, OCR, Speech, TextToSpeech) and, for languages that need one, the font package. /LimitAccess: no Windows Update, no
        internet. Tag and source are validated here (the arguments are data, never joined into a command line by hand). Optional = the .cab may be missing on the ISO.
    #>
    param([Parameter(Mandatory)][string]$Tag, [Parameter(Mandatory)][string]$Source)
    $lang = @($script:Languages | Where-Object { $_.Tag -ceq $Tag })
    if ($lang.Count -ne 1) { throw "'$Tag' is not a language of the list." }
    if (-not (Test-AVDTuneLanguageSource $Source)) { throw 'The content folder is not a plain local or share path.' }
    $src = $Source.TrimEnd('\'); $srcArg = $(if ($src -match '^[A-Za-z]:$') { "$src\" } else { $src })
    $calls = New-Object System.Collections.ArrayList
    [void]$calls.Add([pscustomobject]@{ Args = @('/Online', '/Add-Package', "/PackagePath:$($src)\Microsoft-Windows-Client-Language-Pack_x64_$Tag.cab"); Optional = $false })
    foreach ($f in $script:Features) { [void]$calls.Add([pscustomobject]@{ Args = @('/Online', '/Add-Capability', "/CapabilityName:Language.$f~~~$Tag~$($script:CapVersion)", "/Source:$srcArg", '/LimitAccess'); Optional = ($f -ne 'Basic') }) }
    if ($lang[0].ContainsKey('FontGroup')) { $g = $lang[0].FontGroup; [void]$calls.Add([pscustomobject]@{ Args = @('/Online', '/Add-Capability', "/CapabilityName:Language.Fonts.$g~~~und-$g~$($script:CapVersion)", "/Source:$srcArg", '/LimitAccess'); Optional = $false }) }
    @($calls)
}

function Invoke-AVDTuneLanguageDism {
    # Resolves DISM (full path from the system folder, Microsoft signature) and runs the calls through the update adapter's Run (central child environment, job object).
    # $U: the update adapter. Exit 0 and 3010 (restart needed) are success. An optional call that fails is noted and the run goes on.
    param([Parameter(Mandatory)]$U, [Parameter(Mandatory)][string]$Tag, [Parameter(Mandatory)][string]$Source, [int]$TimeoutSeconds = 3600)
    $path = & $U.Path 'Dism'
    if (-not $path -or -not (& $U.Exists $path)) { throw 'Dism.exe was not found.' }
    $trust = Test-AVDTuneToolTrust -Signature (& $U.VerifySignature $path) -Name 'Dism.exe'
    if (-not $trust.Ok) { throw "$($trust.Reason): it is not started." }
    $notes = New-Object System.Collections.ArrayList; $reboot = $false
    foreach ($c in @(Get-AVDTuneLanguageDismCalls -Tag $Tag -Source $Source)) {
        $r = & $U.Run $path $c.Args $TimeoutSeconds
        if ($r.ExitCode -eq 3010) { $reboot = $true; continue }
        if ($r.ExitCode -ne 0) {
            $tail = ([string]$r.Output -replace '[\x00-\x08\x0B-\x1F]', ' ').Trim(); if ($tail.Length -gt 300) { $tail = $tail.Substring($tail.Length - 300) }
            if ($c.Optional) { [void]$notes.Add("$($c.Args[1]) $($c.Args[2]) failed ($($r.ExitCode)) and was skipped"); continue }
            throw "DISM $($c.Args[1]) for $Tag failed (exit $($r.ExitCode)): $tail"
        }
    }
    [pscustomobject]@{ Reboot = $reboot; Notes = @($notes) }
}

#endregion

#region steps

function Get-AVDTuneLanguageCleanupSteps {   # -PreviousBlock: the value of BlockCleanup... found before the first change (Undo puts it back instead of deleting the value)
    # The Learn script starts with "Disable Language Pack Cleanup": three scheduled tasks off and BlockCleanupOfUnusedPreinstalledLangPacks = 1. Without it Windows removes the packs again.
    param($PreviousBlock = $null)
    $key = $script:CleanupKey; $src = $script:Src.Avd; $why = 'Windows removes language packs that no user needs; the Learn guide for language packs turns the cleanup off first.'
    $steps = New-Object System.Collections.ArrayList
    $tasks = @(@('cleanup-prestaged', '\Microsoft\Windows\AppxDeploymentClient\', 'Pre-staged app cleanup'), @('cleanup-lpremove', '\Microsoft\Windows\MUI\', 'LPRemove'), @('cleanup-uninstall', '\Microsoft\Windows\LanguageComponentsInstaller\', 'Uninstallation'))
    foreach ($t in $tasks) {
        [void]$steps.Add((New-AVDTuneStepFromData ([pscustomobject]@{ Id = "language.$($t[0])"; Section = 'Language'; Kind = 'TaskDisabled'; Title = "Language cleanup task off: $($t[2])"; Why = $why; SourceUrl = $src; TaskPath = $t[1]; TaskName = $t[2] })))
    }
    [void]$steps.Add((New-AVDTuneStepFromData ([pscustomobject]@{ Id = 'language.cleanup-block'; Section = 'Language'; Kind = 'Registry'; Title = 'BlockCleanupOfUnusedPreinstalledLangPacks = 1'; Why = $why; SourceUrl = $src; Path = $key; Name = 'BlockCleanupOfUnusedPreinstalledLangPacks'; Value = 1; Type = 'DWord'; Previous = $PreviousBlock })))
    @($steps)
}

function Get-AVDTuneLanguageSteps {
    <#
        All steps of a configuration. -Parts Languages (cleanup off + one step per language to install, no undo) or Defaults (the six settings) or All. $Want comes from
        Resolve-AVDTuneLanguageConfig. $Prev (from config\language-undo.json) is used by Undo: @{ NewUser; Admin; SystemLocale; TimeZone }.
    #>
    param([Parameter(Mandatory)]$L, [Parameter(Mandatory)]$Config, [Parameter(Mandatory)]$Want, $Prev, [string]$Parts = 'All', [string]$Source)
    $steps = New-Object System.Collections.ArrayList
    if ($Parts -in 'Languages', 'All') {
        foreach ($t in @($Config.Languages)) {
            $tag = $t; $src = $Source; $lm = $L
            $test = { param($m) $i = @(& $lm.GetInstalled | Where-Object { $_.Tag -ieq $tag }); @{ Compliant = ($i.Count -gt 0); State = $(if ($i.Count) { 'installed' } else { 'not installed' }) } }.GetNewClosure()
            $apply = { param($m) [void](& $lm.AddLanguage $tag $src) }.GetNewClosure()
            [void]$steps.Add((New-AVDTuneStep -Id "language.add-$($t.ToLowerInvariant())" -Section Language -Title "Install language $t (language pack and features)" -Why 'Users of a pooled host pool need the languages in the image (Learn: windows-11-language-packs).' -Risk Medium -Reboot $true -SourceUrl $script:Src.Avd -Test $test -Apply $apply))
        }
        if (@($Config.Languages).Count -gt 0) { foreach ($s in @(Get-AVDTuneLanguageCleanupSteps)) { [void]$steps.Add($s) } }
    }
    if ($Parts -in 'Defaults', 'All') {
        $lm = $L; $w = $Want; $pv = $Prev
        $setAll = { param($m) $inst = @(& $lm.GetInstalled | ForEach-Object { $_.Tag }); if ($w.Ui -and $w.Ui -inotin $inst) { throw "The display language $($w.Ui) is not installed. Install it first." }; $before = & $lm.GetUserIntl; try { & $lm.SetUserIntl @{ Ui = $w.Ui; Culture = $w.Culture; InputTip = $w.InputTip; GeoId = $w.GeoId }; & $lm.CopyToSystem } catch { $err = $_; try { & $lm.SetUserIntl $before } catch { }; throw $err } }.GetNewClosure()   # a failed copy puts the settings of the administrator back
        $undoAll = { param($m) if ($null -eq $pv -or $null -eq $pv.NewUser) { throw 'The earlier values of the new-user settings are not known; they cannot be restored.' }; & $lm.SetUserIntl $pv.NewUser; & $lm.CopyToSystem; if ($pv.Admin) { & $lm.SetUserIntl $pv.Admin } }.GetNewClosure()
        $defs = @(
            @{ Id = 'language.ui'; Title = 'Display language for new users and the welcome screen'; Want = $w.Ui; Read = { param($m) (Get-AVDTuneLanguageNewUser $m).Ui } }
            @{ Id = 'language.culture'; Title = 'Regional format for new users'; Want = $w.Culture; Read = { param($m) (Get-AVDTuneLanguageNewUser $m).Culture } }
            @{ Id = 'language.input'; Title = 'Input (keyboard) for new users'; Want = $w.InputTip; Read = { param($m) (Get-AVDTuneLanguageNewUser $m).InputTip } }
            @{ Id = 'language.geo'; Title = 'Location (GeoId) for new users'; Want = $w.GeoId; Read = { param($m) (Get-AVDTuneLanguageNewUser $m).GeoId } }
        )
        foreach ($d in $defs) {
            if ($null -eq $d.Want -or $d.Want -eq '') { continue }
            $want = $d.Want; $read = $d.Read
            $test = { param($m) $v = & $read $m; @{ Compliant = ("$v" -ieq "$want"); State = $v } }.GetNewClosure()
            [void]$steps.Add((New-AVDTuneStep -Id $d.Id -Section Language -Title "$($d.Title): $want" -Why 'Set for the current user, then copied to the welcome screen and new users with Copy-UserInternationalSettingsToSystem (Windows 11).' -Risk Medium -Reboot $true -SourceUrl $script:Src.Copy -Test $test -Apply $setAll -Undo $undoAll))
        }
        if ($w.SystemLocale) {
            $sl = $w.SystemLocale; $psl = $(if ($pv) { $pv.SystemLocale } else { $null })
            $test = { param($m) $v = ConvertTo-AVDTuneLcidName ([string](& $m.RegGet 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\Locale' '(default)')); @{ Compliant = ("$v" -ieq $sl); State = $v } }.GetNewClosure()
            $apply = { param($m) & $lm.SetSystemLocale $sl }.GetNewClosure()
            $undo = { param($m) if (-not $psl) { throw 'The earlier system locale is not known; it cannot be restored.' }; & $lm.SetSystemLocale $psl }.GetNewClosure()
            [void]$steps.Add((New-AVDTuneStep -Id 'language.sysloc' -Section Language -Title "System locale (programs without Unicode): $sl" -Why 'Language of non-Unicode programs; takes effect after a restart.' -Risk Medium -Reboot $true -SourceUrl $script:Src.Languages -Test $test -Apply $apply -Undo $undo))
        }
        if ($w.TimeZone) {
            $tz = $w.TimeZone; $ptz = $(if ($pv) { $pv.TimeZone } else { $null })
            $test = { param($m) $v = & $m.RegGet 'HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation' 'TimeZoneKeyName'; @{ Compliant = ("$v" -ieq $tz); State = $v } }.GetNewClosure()
            $apply = { param($m) & $lm.SetTimeZone $tz }.GetNewClosure()
            $undo = { param($m) if (-not $ptz) { throw 'The earlier time zone is not known; it cannot be restored.' }; & $lm.SetTimeZone $ptz }.GetNewClosure()
            [void]$steps.Add((New-AVDTuneStep -Id 'language.timezone' -Section Language -Title "Time zone: $tz" -Why 'The master and its hosts use one time zone; users get theirs through time zone redirection (VDI components).' -Risk Low -SourceUrl $script:Src.TimeZone -Test $test -Apply $apply -Undo $undo))
        }
    }
    @($steps)
}

function Get-AVDTuneLanguageUndoRecord {
    # Typed read of config\language-undo.json; $null when absent; a damaged file is an error and nothing is changed
    param([string]$Root)
    $u = Read-AVDTuneJson (Get-AVDTuneLanguageUndoPath $Root)
    if ($null -eq $u) { return $null }
    $bad = 'The undo record of the language settings (config\language-undo.json) is not usable. Nothing was changed.'
    $reads = {
        param($o)
        if ($null -eq $o) { return $null }
        if ($o -isnot [System.Management.Automation.PSCustomObject]) { throw $bad }
        $r = [ordered]@{}
        foreach ($n in 'Ui', 'Culture', 'InputTip') { $v = Get-AVDTuneProp $o $n; if ($null -ne $v -and $v -isnot [string]) { throw $bad }; $r[$n] = $v }
        $g = Get-AVDTuneProp $o 'GeoId'; if ($null -ne $g -and $g -isnot [int]) { throw $bad }; $r['GeoId'] = $g
        foreach ($n in 'Ui', 'Culture', 'InputTip') { if ($r[$n] -and -not [regex]::IsMatch([string]$r[$n], '^[A-Za-z0-9:?-]{1,20}\z', 'None', [TimeSpan]::FromMilliseconds(200))) { throw $bad } }
        $r
    }
    $sl = Get-AVDTuneProp $u 'SystemLocale'; $tz = Get-AVDTuneProp $u 'TimeZone'
    foreach ($v in $sl, $tz) { if ($null -ne $v -and $v -isnot [string]) { throw $bad } }
    if ($sl -and $sl -cnotin @(Get-AVDTuneLanguageCultures | ForEach-Object Tag)) { throw $bad }
    if ($tz -and -not [regex]::IsMatch($tz, "^[A-Za-z0-9 .,()+'-]{1,80}\z", 'None', [TimeSpan]::FromMilliseconds(200))) { throw $bad }
    $blk = Get-AVDTuneProp $u 'Block'; if ($null -ne $blk -and $blk -isnot [int]) { throw $bad }
    @{ NewUser = (& $reads (Get-AVDTuneProp $u 'NewUser')); Admin = (& $reads (Get-AVDTuneProp $u 'Admin')); SystemLocale = $sl; TimeZone = $tz; Block = $blk }
}

function Save-AVDTuneLanguageUndoRecord {
    <#
        Keeps the values found before AVDTune changed them. The first call writes all of them. A later call only completes a value that the record does not hold yet (it was not readable then) and
        that AVDTune has not changed since (not in config\language-applied.json): an older value is never overwritten.
    #>
    param([Parameter(Mandatory)]$Machine, [string]$Root, [Parameter(Mandatory)]$State)
    $path = Get-AVDTuneLanguageUndoPath $Root
    $blockNow = & $Machine.RegGet $script:CleanupKey 'BlockCleanupOfUnusedPreinstalledLangPacks'
    $blockNow = $(if ($null -ne $blockNow -and ([string]$blockNow) -match '^-?[0-9]{1,10}\z') { [int]$blockNow } else { $null })
    $nu = $State.NewUser; $ad = $State.Admin
    $field = { param($o, $n) if ($o -is [System.Collections.IDictionary]) { $o[$n] } else { Get-AVDTuneProp $o $n } }
    $cur = [ordered]@{
        At = (& $Machine.Now).ToString('o')
        NewUser = [ordered]@{ Ui = $nu.Ui; Culture = $nu.Culture; InputTip = $nu.InputTip; GeoId = $nu.GeoId }
        Admin = [ordered]@{ Ui = (& $field $ad 'Ui'); Culture = (& $field $ad 'Culture'); InputTip = (& $field $ad 'InputTip'); GeoId = (& $field $ad 'GeoId') }
        SystemLocale = $State.SystemLocale; TimeZone = $State.TimeZone; Block = $blockNow
    }
    $old = Read-AVDTuneJson $path
    if ($null -eq $old) { Write-AVDTuneFile $path ($cur | ConvertTo-Json -Depth 4); return }
    $applied = Read-AVDTuneJson (Get-AVDTuneLanguageAppliedPath $Root)
    $changed = @(@(Get-AVDTuneProp $applied 'Changed') | Where-Object { $_ -is [string] })
    $dirty = $false
    $fill = { param($oldVal, $curVal, $id) if ($null -eq $oldVal -and $null -ne $curVal -and $id -notin $changed) { $script:langDirty = $true; $curVal } else { $oldVal } }
    $script:langDirty = $false
    $ids = @{ Ui = 'language.ui'; Culture = 'language.culture'; InputTip = 'language.input'; GeoId = 'language.geo' }
    $merged = [ordered]@{ At = (Get-AVDTuneProp $old 'At'); NewUser = [ordered]@{}; Admin = [ordered]@{} }
    foreach ($n in 'Ui', 'Culture', 'InputTip', 'GeoId') {
        $merged.NewUser[$n] = & $fill (Get-AVDTuneProp (Get-AVDTuneProp $old 'NewUser') $n) $cur.NewUser[$n] $ids[$n]
        $merged.Admin[$n] = & $fill (Get-AVDTuneProp (Get-AVDTuneProp $old 'Admin') $n) $cur.Admin[$n] $ids[$n]
    }
    $merged.SystemLocale = & $fill (Get-AVDTuneProp $old 'SystemLocale') $cur.SystemLocale 'language.sysloc'
    $merged.TimeZone = & $fill (Get-AVDTuneProp $old 'TimeZone') $cur.TimeZone 'language.timezone'
    $merged.Block = & $fill (Get-AVDTuneProp $old 'Block') $cur.Block 'language.cleanup-block'
    if ($script:langDirty) { Write-AVDTuneFile $path ($merged | ConvertTo-Json -Depth 4) }
}
function Invoke-AVDTuneLanguage {
    <#
        Test (-WhatIf) or Apply of the languages and/or the defaults behind the write gate: Invoke-AVDTune writes the run record, LastChange and the change log. Before the first change the values
        found are kept for Undo (never overwritten). Returns the run; Source and Reboot are part of the confirmation text (Get-AVDTuneLanguageConfirmText).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Machine, [Parameter(Mandatory)]$L, [string]$Root = (Get-AVDTuneRoot), [Parameter(Mandatory)]$Config, [ValidateSet('Languages', 'Defaults', 'All')][string]$Parts = 'All', [string]$User, [string]$SnapshotId, [switch]$WhatIf)
    $st = Get-AVDTuneLanguageState -Machine $Machine -L $L
    $cfg = ConvertTo-AVDTuneLanguageConfig $Config -InstalledTags @($st.Installed | ForEach-Object { $_.Tag })
    if (-not $WhatIf -and -not (Test-AVDTuneWriteAllowed)) { throw 'The snapshot gate is not confirmed: AVDTune is read only until a snapshot newer than its last change is confirmed on the Overview.' }
    if ($cfg.Source -and $Parts -ne 'Defaults') {
        $chk = & $L.CheckSource $cfg.Source $Root
        if (-not $chk.Ok -and @($cfg.Languages | Where-Object { $_ -notin @($st.Installed | ForEach-Object { $_.Tag }) }).Count -gt 0) { throw "The content folder is not usable: $($chk.Problem)" }
    }
    $want = Resolve-AVDTuneLanguageConfig $cfg $st
    if ($want.TimeZone -and $want.TimeZone -cnotin @(& $L.GetTimeZones)) { throw "The time zone '$($want.TimeZone)' is not known to this Windows." }
    $undoPath = Get-AVDTuneLanguageUndoPath $Root
    if (-not $WhatIf) { Save-AVDTuneLanguageUndoRecord -Machine $Machine -Root $Root -State $st }
    $steps = @(Get-AVDTuneLanguageSteps -L $L -Config $cfg -Want $want -Parts $Parts -Source $cfg.Source)
    $name = switch ($Parts) { 'Languages' { 'Language packs' } 'Defaults' { 'Language defaults for new users' } default { 'Language and region' } }
    $run = Invoke-AVDTune -Plan ([pscustomobject]@{ Name = $name; Steps = @($steps | ForEach-Object { $_.Id }) }) -Catalog $steps -Machine $Machine -Root $Root -User $User -SnapshotId $SnapshotId -WhatIf:$WhatIf
    if (-not $WhatIf) {
        $changed = @($run.Results | Where-Object { $_.Status -in 'Changed', 'Failed' } | ForEach-Object { $_.Id })   # a failed step may have changed part of it
        $old = Read-AVDTuneJson (Get-AVDTuneLanguageAppliedPath $Root); $ids = @(@(Get-AVDTuneProp $old 'Changed') | Where-Object { $_ -is [string] }) + $changed | Select-Object -Unique
        if ($changed.Count -gt 0) {
            $applied = [ordered]@{ Changed = @($ids); Want = $want }
            if ($old -and (Get-AVDTuneProp $old 'Want') -and $Parts -eq 'Languages') { $applied.Want = Get-AVDTuneProp $old 'Want' }
            Write-AVDTuneFile (Get-AVDTuneLanguageAppliedPath $Root) ($applied | ConvertTo-Json -Depth 5)
        }
        if ($changed.Count -eq 0 -and $null -eq $old) { Remove-Item -LiteralPath $undoPath -Force -ErrorAction SilentlyContinue }   # this run changed nothing and nothing older exists: no record to keep
    }
    $run
}

function Undo-AVDTuneLanguage {
    # Puts back the values found before the first change, for the steps this tool changed (language packs are not removed). Typed record, gate, LastChange before the attempt, run record, change log.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Machine, [Parameter(Mandatory)]$L, [string]$Root = (Get-AVDTuneRoot), [string]$User, [string]$SnapshotId, [switch]$WhatIf, [switch]$IncludeCleanup)
    $prev = Get-AVDTuneLanguageUndoRecord -Root $Root
    $applied = Read-AVDTuneJson (Get-AVDTuneLanguageAppliedPath $Root)
    if (-not $prev -or -not $applied) { throw 'There is nothing to undo: no change of the language settings was recorded.' }
    $changedIds = @(@(Get-AVDTuneProp $applied 'Changed') | Where-Object { $_ -is [string] -and $_ -match '^language\.[a-z0-9-]+\z' })
    $w = Get-AVDTuneProp $applied 'Want'
    if ($null -eq $w) { throw 'The record of what was applied (config\language-applied.json) is not usable. Nothing was changed.' }
    $want = [pscustomobject]@{ Ui = Get-AVDTuneProp $w 'Ui'; Culture = Get-AVDTuneProp $w 'Culture'; InputTip = Get-AVDTuneProp $w 'InputTip'; GeoId = Get-AVDTuneProp $w 'GeoId'; SystemLocale = Get-AVDTuneProp $w 'SystemLocale'; TimeZone = Get-AVDTuneProp $w 'TimeZone' }
    $cfg = Get-AVDTuneLanguageDefaults
    $cleanup = $(if ($IncludeCleanup) { @(Get-AVDTuneLanguageCleanupSteps -PreviousBlock $prev.Block) } else { @() })   # the protection of installed language packs stays on unless it is asked for
    $steps = @((@(Get-AVDTuneLanguageSteps -L $L -Config $cfg -Want $want -Prev $prev -Parts Defaults) + $cleanup) | Where-Object { $_.Id -in $changedIds })
    if (-not $WhatIf) {
        if (-not (Test-AVDTuneWriteAllowed)) { throw 'The snapshot gate is not confirmed: AVDTune is read only until a snapshot newer than its last change is confirmed on the Overview.' }
        [void](Set-AVDTuneState -Root $Root -Values @{ LastChange = (& $Machine.Now).ToString('o') })
    }
    $owner = $false; if (-not $WhatIf) { $owner = Start-AVDTuneChange -Root $Root }
    try {
        $results = @(foreach ($s in $steps) { Invoke-AVDTuneStep -Step $s -Machine $Machine -Mode Undo -WhatIf:$WhatIf })
        if (-not $WhatIf) {
            # verify against the earlier values, not only against "no longer the wanted value": what cannot be put back is reported
            $nuNow = Get-AVDTuneLanguageNewUser $Machine
            $slNow = ConvertTo-AVDTuneLcidName ([string](& $Machine.RegGet 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\Locale' '(default)'))
            $tzNow = & $Machine.RegGet 'HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation' 'TimeZoneKeyName'
            $checks = @(
                @('language.ui', 'display language', $nuNow.Ui, $prev.NewUser.Ui), @('language.culture', 'regional format', $nuNow.Culture, $prev.NewUser.Culture), @('language.input', 'input', $nuNow.InputTip, $prev.NewUser.InputTip)
                @('language.geo', 'location', $nuNow.GeoId, $prev.NewUser.GeoId), @('language.sysloc', 'system locale', $slNow, $prev.SystemLocale), @('language.timezone', 'time zone', $tzNow, $prev.TimeZone))
            $bad = @(foreach ($c in $checks) {
                    $r = @($results | Where-Object { $_.Id -eq $c[0] -and $_.Status -eq 'Reverted' }); if ($r.Count -eq 0) { continue }
                    if ($null -eq $c[3]) { "$($c[1]) (the earlier value was not recorded)" } elseif ("$($c[2])" -ine "$($c[3])") { "$($c[1]) (is $($c[2]), was $($c[3]))" }
                })
            if ($bad.Count -gt 0) { $results = @($results) + [pscustomobject]@{ Id = 'language.verify'; Section = 'Language'; Title = 'Check after undo'; Mode = 'Undo'; Status = 'Failed'; Before = $null; After = $null; Message = "Not restorable: $($bad -join '; ')."; Reboot = $false; WhatIf = $false; At = (& $Machine.Now).ToString('o') } }
        }
        $run = [pscustomobject]@{ Plan = 'Language undo'; WhatIf = [bool]$WhatIf; Results = $results }
        if (-not $WhatIf) {
            $state = Get-AVDTuneState $Root; $ended = (& $Machine.Now).ToString('o')
            $saved = [pscustomobject][ordered]@{ Id = $null; Plan = 'Language undo'; Started = $ended; Ended = $ended; User = $User; SnapshotId = $SnapshotId; WhatIf = $false; ImageVersion = $state.ImageVersion; Reboot = [bool](@($results | Where-Object { $_.Reboot }).Count); Results = $results }
            [void](Add-AVDTuneRun -Root $Root -Run $saved)
            foreach ($r in @($results | Where-Object { $_.Status -eq 'Reverted' })) {
                if ($state.ImageVersion) { [void](Add-AVDTuneChangeLogEntry -Root $Root -Version $state.ImageVersion -Category 'Language' -Component $r.Id -ChangeType Changed -Text "Undo: $($r.Title)" -User $User -SnapshotId $SnapshotId -RunId ([string]$saved.Id) -Source Step) }
            }
            if (@($results | Where-Object { $_.Status -eq 'Failed' }).Count -eq 0) {
                Remove-Item -LiteralPath (Get-AVDTuneLanguageUndoPath $Root) -Force -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath (Get-AVDTuneLanguageAppliedPath $Root) -Force -ErrorAction SilentlyContinue   # language packs stay and have no undo: nothing left to record
            }
        }
        $run
    }
    finally { Stop-AVDTuneChange -Root $Root -Owner $owner }
}

function Get-AVDTuneLanguageConfirmText {
    # The text of the confirmation: what will happen (old -> new per setting), where the content comes from (by kind of folder) and, in plain words, what cannot be undone
    param([ValidateSet('Languages', 'Defaults', 'All', 'Undo')][string]$Mode, $Config, $State, [string]$SourceKind)
    switch ($Mode) {
        'Undo' { 'Put back the display language, regional format, input, location, system locale and time zone that were set before the first change? Installed language packs stay (AVDTune cannot remove them; restore a snapshot for that), and so does the protection against the Windows cleanup of language packs (three scheduled tasks off, one policy value). A restart is needed.' }
        default {
            $t = @()
            if ($Mode -in 'Languages', 'All') {
                $new = @(@($Config.Languages) | Where-Object { $_ -notin @($State.Installed | ForEach-Object { $_.Tag }) })
                if ($new.Count -gt 0) {
                    $where = switch ($SourceKind) {
                        'Share' { 'The content comes from a share: AVDTune read the permissions of the folders, but it cannot see the share permissions; only administrators may be able to write to the share.' }
                        'Media' { 'The content comes from read-only media: an ISO that you mounted yourself with Windows. AVDTune does not check where the ISO file came from; use the ISO of Microsoft.' }
                        'Local' { 'The content comes from a local folder that only administrators can write to.' }
                        default { '' }
                    }
                    $t += "Install $($new -join ', ') from $($Config.Source) with DISM (language pack, handwriting, OCR, speech, text-to-speech, fonts). $where This takes several minutes per language and a restart may follow. Installing a language pack CANNOT be undone by AVDTune: only a snapshot of the VM brings the earlier state back. After a language pack the latest cumulative update may have to be installed again (Learn). The Windows cleanup of unused language packs is turned off (3 scheduled tasks and one policy value; this stays on after Undo)."
                }
            }
            if ($Mode -in 'Defaults', 'All') {
                $want = Resolve-AVDTuneLanguageConfig $Config $State
                $nu = $State.NewUser
                $pairs = @(@('Display language', $nu.Ui, $want.Ui), @('Regional format', $nu.Culture, $want.Culture), @('Input', $nu.InputTip, $want.InputTip), @('Location (GeoId)', $nu.GeoId, $want.GeoId), @('System locale', $State.SystemLocale, $want.SystemLocale), @('Time zone', $State.TimeZone, $want.TimeZone))
                $lines = @(foreach ($p in $pairs) { if ($null -ne $p[2] -and "$($p[2])" -ne '' -and "$($p[1])" -ine "$($p[2])") { "$($p[0]): $(if ($null -ne $p[1] -and "$($p[1])" -ne '') { $p[1] } else { 'not set' }) -> $($p[2])" } })
                $list = if ($lines.Count -gt 0) { "Changes:`n" + ($lines -join "`n") } else { 'No setting differs from what is there now.' }
                $t += "Set display language, regional format, input and location for the current user and copy them to the welcome screen and new users (Copy-UserInternationalSettingsToSystem); set the system locale and the time zone as chosen. This changes the settings of the administrator who runs AVDTune as well. Display language, system locale and the copy take effect after a restart. Undo puts the earlier values back.`n$list"
            }
            ($t -join "`n`n")
        }
    }
}
#endregion

#region real adapter

function New-AVDTuneLanguageAdapter {
    <#
        The real adapter. NOT exercised by the checks beyond construction: written from the Learn pages and the cmdlet references and to be tried on a throw-away VM (docs\language.md, "not verified").
        Every writing member checks its arguments again against the fixed lists before a cmdlet or DISM is touched. DISM runs through the update adapter (full path, signature, job object, central child environment).
    #>
    param($U = (New-AVDTuneUpdateAdapter), [scriptblock]$UserListAdd, $SourceProbe)
    $tags = @($script:Languages | ForEach-Object { $_.Tag }); $cultures = @(Get-AVDTuneLanguageCultures | ForEach-Object { $_.Tag }); $tips = @(Get-AVDTuneLanguageInputs | ForEach-Object { $_.Tip }); $geos = @($script:Regions | ForEach-Object { $_.Id })
    $a = [ordered]@{ Kind = 'Real'; U = $U }
    $a.GetInstalled = {
        $out = New-Object System.Collections.ArrayList
        if (Get-Command Get-InstalledLanguage -ErrorAction SilentlyContinue) {
            foreach ($l in @(Get-InstalledLanguage -ErrorAction Stop)) { [void]$out.Add([pscustomobject]@{ Tag = [string]$l.LanguageId; Features = @(@($l.LanguagePacks) + @($l.LanguageFeatures) | ForEach-Object { [string]$_ }) }) }
            return @($out)
        }
        $by = @{}
        foreach ($c in @(Get-WindowsCapability -Online -Name 'Language.*' -ErrorAction Stop | Where-Object { $_.State -eq 'Installed' })) {
            if ([string]$c.Name -match '^Language\.([A-Za-z]+)~~~([A-Za-z]{2,3}-[A-Za-z]{2,4})~') { if (-not $by.ContainsKey($Matches[2])) { $by[$Matches[2]] = @() }; $by[$Matches[2]] += $Matches[1] }
        }
        foreach ($k in $by.Keys) { [void]$out.Add([pscustomobject]@{ Tag = $k; Features = @($by[$k]) }) }
        @($out)
    }.GetNewClosure()
    $a.GetUserIntl = {
        $ui = $null; try { $ui = [string](Get-WinUILanguageOverride -ErrorAction Stop).Name } catch { }
        $tip = $null; try { $tip = [string]@((Get-WinUserLanguageList)[0].InputMethodTips)[0] } catch { }
        $geo = $null; try { $geo = [int](Get-WinHomeLocation).GeoId } catch { }
        @{ Ui = $ui; Culture = [string](Get-Culture).Name; InputTip = $tip; GeoId = $geo }
    }
    $a.SetUserIntl = {
        param($V)
        $ui = $V['Ui']; $cu = $V['Culture']; $tip = $V['InputTip']; $geo = $V['GeoId']
        if ($ui -and $ui -cnotin $tags) { throw 'Refused: display language not on the list.' }
        if ($cu -and $cu -cnotin $cultures) { throw 'Refused: regional format not on the list.' }
        if ($tip -and ($tip -cnotin $tips)) { throw 'Refused: input not on the list.' }
        if ($null -ne $geo -and $geo -notin $geos) { throw 'Refused: location not on the list.' }
        if ($ui) { Set-WinUILanguageOverride -Language $ui -ErrorAction Stop }
        if ($cu) { Set-Culture -CultureInfo $cu -ErrorAction Stop }
        if ($tip -or $ui) {
            $list = New-WinUserLanguageList -Language $(if ($ui) { $ui } else { $cu })
            if ($tip) { $list[0].InputMethodTips.Clear(); $list[0].InputMethodTips.Add($tip) }
            Set-WinUserLanguageList -LanguageList $list -Force -ErrorAction Stop
        }
        if ($null -ne $geo) { Set-WinHomeLocation -GeoId ([int]$geo) -ErrorAction Stop }
    }.GetNewClosure()
    $a.CopyToSystem = { Copy-UserInternationalSettingsToSystem -WelcomeScreen $true -NewUser $true -ErrorAction Stop }
    $a.SetSystemLocale = { param($Tag) if ($Tag -cnotin $cultures) { throw 'Refused: system locale not on the list.' }; Set-WinSystemLocale -SystemLocale $Tag -ErrorAction Stop }.GetNewClosure()
    $a.GetTimeZones = { @([TimeZoneInfo]::GetSystemTimeZones() | ForEach-Object { $_.Id }) }
    $a.SetTimeZone = { param($Id) if ($Id -cnotin @([TimeZoneInfo]::GetSystemTimeZones() | ForEach-Object { $_.Id })) { throw 'Refused: time zone not known to Windows.' }; Set-TimeZone -Id $Id -ErrorAction Stop }
    $a.CheckSource = { param($Path, $Root) Get-AVDTuneLanguageSourceVerdict -Path $Path -Probe (New-AVDTuneLanguageSourceProbe) }
    $a.AddLanguage = {
        param($Tag, $Source)
        # checked again before every language: the folder may have changed since the check on the page (a link, a permission)
        $v = Get-AVDTuneLanguageSourceVerdict -Path $Source -Probe $(if ($SourceProbe) { $SourceProbe } else { New-AVDTuneLanguageSourceProbe })
        if (-not $v.Ok) { throw "The content folder is not usable: $($v.Problem)" }
        $r = Invoke-AVDTuneLanguageDism -U $U -Tag $Tag -Source $Source
        if ($UserListAdd) { & $UserListAdd $Tag } else { $list = Get-WinUserLanguageList; if (@($list | Where-Object { $_.LanguageTag -ieq $Tag }).Count -eq 0) { [void]$list.Add($Tag); Set-WinUserLanguageList -LanguageList $list -Force -ErrorAction Stop } }   # $UserListAdd: the checks replace the write to the language list
        $r
    }.GetNewClosure()
    [pscustomobject]$a
}

#endregion

Export-ModuleMember -Function Get-AVDTuneLanguageCatalog, Get-AVDTuneLanguageCultures, Get-AVDTuneLanguageRegions, Get-AVDTuneLanguageInputs, Get-AVDTuneLanguageSources, Get-AVDTuneLanguageAzureZone,
    Test-AVDTuneLanguageSource, Test-AVDTuneLanguageConfig, ConvertTo-AVDTuneLanguageConfig, Get-AVDTuneLanguageDefaults, Get-AVDTuneLanguageConfig, Set-AVDTuneLanguageConfig,
    Get-AVDTuneLanguageNewUser, Get-AVDTuneLanguageState, Resolve-AVDTuneLanguageConfig, Get-AVDTuneLanguageRows, Get-AVDTuneLanguageDismCalls, Invoke-AVDTuneLanguageDism,
    Get-AVDTuneLanguageCleanupSteps, Get-AVDTuneLanguageSourceVerdict, Get-AVDTuneLanguageSourceChain, New-AVDTuneLanguageSourceProbe, Save-AVDTuneLanguageUndoRecord, Get-AVDTuneLanguageSteps, Get-AVDTuneLanguageUndoRecord, Invoke-AVDTuneLanguage, Undo-AVDTuneLanguage, Get-AVDTuneLanguageConfirmText, New-AVDTuneLanguageAdapter,
    Get-AVDTuneLanguageUndoPath, Get-AVDTuneLanguageAppliedPath, Get-AVDTuneLanguageConfigPath, ConvertTo-AVDTuneLcidName
