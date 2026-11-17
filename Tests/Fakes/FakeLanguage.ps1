# Fake of the language adapter (Modules\AVDTune.Language.psm1, New-AVDTuneLanguageAdapter): installed languages, DISM (through the fake update adapter, so the real call
# list and the signature check run), the international settings of the administrator, the copy to new users, system locale and time zone, in memory. The copy
# and the setters write the registry values of the fake machine that the real ones write (HKEY_USERS\.DEFAULT, Nls\Locale, TimeZoneInformation). Nothing of this
# computer is touched. Everything asked is in .Log. Switches live in .Store:
#   Installed (tags), User (@{ Ui; Culture; InputTip; GeoId } of the administrator), TimeZones, SourceKind ('Media'|'Local'|'Share'), SourceProblem (text: the folder is refused),
#   CopyWritesGeo (a GeoId the copy writes instead of the user's, to test the check after undo), DismFails (exit code of the DISM call that names this text in its arguments, e.g. 'Handwriting' or 'Client-Language-Pack'), CopyFails, TzFails, Unsigned ($true = DISM signature wrong).
# All names are made up.
if (-not (Get-Command New-AVDTuneFakeUpdates -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'FakeUpdates.ps1') }   # the DISM calls run through the fake update adapter
function New-AVDTuneFakeLanguage {
    param([Parameter(Mandatory)]$Machine, [hashtable]$Seed = @{})
    $s = @{
        Installed = @('en-US'); User = @{ Ui = 'en-US'; Culture = 'en-US'; InputTip = '0409:00000409'; GeoId = 244 }; TimeZones = @('UTC', 'W. Europe Standard Time', 'GMT Standard Time', 'Eastern Standard Time', 'Romance Standard Time')
        SourceKind = 'Media'; SourceProblem = ''; DismFails = @{}; CopyFails = $false; CopyWritesGeo = $null; TzFails = $false; Unsigned = $false; Log = (New-Object System.Collections.ArrayList)
    }
    foreach ($e in $Seed.GetEnumerator()) { $s[$e.Key] = $e.Value }
    $m = $Machine
    $def = 'Registry::HKEY_USERS\.DEFAULT'
    $native = @{ '*Dism.exe *' = @{ ExitCode = 0; Output = 'The operation completed successfully.' } }
    $sig = @{}; if ($s.Unsigned) { $sig['Dism.exe'] = @{ Valid = $false; Subject = ''; Issuer = '' } }
    $u = New-AVDTuneFakeUpdates -Seed @{ Native = $native; Tools = @('Dism.exe'); Signatures = $sig }
    $a = [ordered]@{ Kind = 'Fake'; Store = $s; Log = $s.Log; U = $u }
    $a.GetInstalled = { [void]$s.Log.Add('GetInstalled'); @($s.Installed | ForEach-Object { [pscustomobject]@{ Tag = $_; Features = @('Basic') } }) }.GetNewClosure()
    $a.GetUserIntl = { @{ Ui = $s.User.Ui; Culture = $s.User.Culture; InputTip = $s.User.InputTip; GeoId = $s.User.GeoId } }.GetNewClosure()
    $a.SetUserIntl = {
        param($V)
        [void]$s.Log.Add("SetUserIntl ui=$($V['Ui']) culture=$($V['Culture']) tip=$($V['InputTip']) geo=$($V['GeoId'])")
        foreach ($n in 'Ui', 'Culture', 'InputTip', 'GeoId') { if ($null -ne $V[$n] -and $V[$n] -ne '') { $s.User[$n] = $V[$n] } }
    }.GetNewClosure()
    $a.CopyToSystem = {
        [void]$s.Log.Add('CopyToSystem')
        if ($s.CopyFails) { throw 'fake: Copy-UserInternationalSettingsToSystem failed' }
        & $m.RegSet "$def\Control Panel\Desktop" 'PreferredUILanguages' $s.User.Ui 'String'
        & $m.RegSet "$def\Control Panel\International" 'LocaleName' $s.User.Culture 'String'
        $klid = ([string]$s.User.InputTip).Split(':')[1]
        & $m.RegSet "$def\Keyboard Layout\Preload" '1' $klid 'String'
        & $m.RegSet "$def\Control Panel\International\Geo" 'Nation' ([string]$(if ($null -ne $s.CopyWritesGeo) { $s.CopyWritesGeo } else { $s.User.GeoId })) 'String'
    }.GetNewClosure()
    $a.SetSystemLocale = {
        param($Tag)
        [void]$s.Log.Add("SetSystemLocale $Tag")
        & $m.RegSet 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\Locale' '(default)' (([cultureinfo]$Tag).LCID.ToString('X8')) 'String'
    }.GetNewClosure()
    $a.GetTimeZones = { @($s.TimeZones) }.GetNewClosure()
    $a.SetTimeZone = {
        param($Id)
        [void]$s.Log.Add("SetTimeZone $Id")
        if ($s.TzFails) { throw 'fake: Set-TimeZone failed' }
        & $m.RegSet 'HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation' 'TimeZoneKeyName' $Id 'String'
    }.GetNewClosure()
    $a.CheckSource = {
        param($Path, $Root)
        [void]$s.Log.Add("CheckSource $Path")
        if ($s.SourceProblem) { return @{ Ok = $false; Kind = $s.SourceKind; Problem = $s.SourceProblem } }
        @{ Ok = $true; Kind = $s.SourceKind; Problem = '' }
    }.GetNewClosure()
    $a.AddLanguage = {
        param($Tag, $Source)
        [void]$s.Log.Add("AddLanguage $Tag from $Source")
        [void]$s.Log.Add("CheckSource $Source")
        if ($s.SourceProblem) { throw "The content folder is not usable: $($s.SourceProblem)" }   # like the real adapter: checked again before every language
        $n = [ordered]@{}   # failing calls first: the first match answers
        foreach ($k in @($s.DismFails.Keys)) { $n["*Dism.exe *$k*"] = @{ ExitCode = [int]$s.DismFails[$k]; Output = "Error: $k" } }
        $n['*Dism.exe *'] = @{ ExitCode = 0; Output = 'The operation completed successfully.' }
        $u.Store.Native = $n
        $r = Invoke-AVDTuneLanguageDism -U $u -Tag $Tag -Source $Source
        if ($Tag -notin $s.Installed) { $s.Installed += $Tag }
        $r
    }.GetNewClosure()
    [pscustomobject]$a
}

# Seeds the registry values of the new-user side of the fake machine (HKEY_USERS\.DEFAULT, system locale, time zone) like a fresh Azure image in English
function Set-AVDTuneFakeLanguageRegistry {
    # Seeds the store directly (not through RegSet): a seed is not a write of the product and must not show in the log of the write checks
    param([Parameter(Mandatory)]$Machine, [string]$Ui = 'en-US', [string]$Culture = 'en-US', [string]$Klid = '00000409', [string]$Geo = '244', [string]$SystemLocaleHex = '00000409', [string]$TimeZone = 'UTC')
    $def = 'Registry::HKEY_USERS\.DEFAULT'
    $r = $Machine.Store.Registry
    $r[("$def\Control Panel\Desktop|PreferredUILanguages").ToLowerInvariant()] = $Ui
    $r[("$def\Control Panel\International|LocaleName").ToLowerInvariant()] = $Culture
    $r[("$def\Keyboard Layout\Preload|1").ToLowerInvariant()] = $Klid
    $r[("$def\Control Panel\International\Geo|Nation").ToLowerInvariant()] = $Geo
    $r['hklm:\system\currentcontrolset\control\nls\locale|(default)'] = $SystemLocaleHex
    $r['hklm:\system\currentcontrolset\control\timezoneinformation|timezonekeyname'] = $TimeZone
}