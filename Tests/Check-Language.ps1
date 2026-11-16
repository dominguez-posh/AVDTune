#requires -Version 5.1
<#
.SYNOPSIS
    Checks the language and region side (Modules\AVDTune.Language.psm1, docs\language.md) against the fake machine, the fake language adapter and a temporary state folder:
    catalog, configuration (counter-tests for every wrong value), the DISM call list and its refusals, reading the state for new users, Test/Apply/Undo of the defaults,
    language install without undo, the saved earlier values (never overwritten, damaged ones refused), write gate, change log, LastChange and run records.
    Nothing here touches the languages, registry, time zone or processes of this computer.
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'Modules\AVDTune.psm1') -Force
Import-Module (Join-Path $repo 'Modules\AVDTune.Updates.psm1') -Force
Import-Module (Join-Path $repo 'Modules\AVDTune.Language.psm1') -Force
. (Join-Path $PSScriptRoot 'Fakes\FakeMachine.ps1')
. (Join-Path $PSScriptRoot 'Fakes\FakeUpdates.ps1')
. (Join-Path $PSScriptRoot 'Fakes\FakeLanguage.ps1')

$script:failed = 0
function Test-Check([string]$Name, [bool]$Ok, $Detail) { if ($Ok) { "PASS $Name" } else { $script:failed++; "FAIL $Name" + $(if ($null -ne $Detail) { "  -> $Detail" }) } }
function Test-Throws([scriptblock]$Block) { try { & $Block | Out-Null; $false } catch { $true } }
function Get-R($Run, [string]$Id) { @($Run.Results | Where-Object { $_.Id -eq $Id })[0] }
function New-Cfg([hashtable]$Over = @{}) { $c = @{ Languages = @(); Source = $null; UiLanguage = $null; Culture = $null; InputTip = $null; GeoId = $null; SystemLocale = $null; TimeZone = $null }; foreach ($k in $Over.Keys) { $c[$k] = $Over[$k] }; [pscustomobject]$c }
function New-World([hashtable]$MachineSeed = @{}, [hashtable]$LangSeed = @{}) {
    $tasks = @(@{ Path = '\Microsoft\Windows\AppxDeploymentClient\'; Name = 'Pre-staged app cleanup'; Enabled = $true }, @{ Path = '\Microsoft\Windows\MUI\'; Name = 'LPRemove'; Enabled = $true }, @{ Path = '\Microsoft\Windows\LanguageComponentsInstaller\'; Name = 'Uninstallation'; Enabled = $true })
    $ms = @{ Tasks = $tasks; Now = [datetime]'2026-11-16T10:00:00' }; foreach ($k in $MachineSeed.Keys) { $ms[$k] = $MachineSeed[$k] }
    $m = New-AVDTuneFakeMachine -Seed $ms
    Set-AVDTuneFakeLanguageRegistry -Machine $m
    $l = New-AVDTuneFakeLanguage -Machine $m -Seed $LangSeed
    [pscustomobject]@{ M = $m; L = $l }
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('avdtune-lang-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    $env:AVDTUNE_ROOT = $tmp
    $state = Join-Path $tmp 'state'
    [void](Initialize-AVDTuneState -Root $state)
    [void](Start-AVDTuneImageVersion -Root $state -Date ([datetime]'2026-11-16') -User 'admin1')
    Close-AVDTuneWriteGate

    # ---------------------------------------------------------------- catalog
    $cat = @(Get-AVDTuneLanguageCatalog)
    $want18 = 'de-DE', 'en-US', 'en-GB', 'fr-FR', 'it-IT', 'es-ES', 'nl-NL', 'pl-PL', 'pt-PT', 'pt-BR', 'sv-SE', 'da-DK', 'nb-NO', 'fi-FI', 'cs-CZ', 'tr-TR', 'ja-JP', 'zh-CN'
    Test-Check 'catalog: the 18 languages of the Office page, in that order' (($cat.Tag -join ',') -eq ($want18 -join ',')) ($cat.Tag -join ',')
    Test-Check 'catalog: every language has a default keyboard (8 hex digits) and an input tip LCID:KLID' ((@($cat | Where-Object { $_.Klid -notmatch '^[0-9A-F]{8}\z' }).Count -eq 0) -and (@(Get-AVDTuneLanguageInputs | Where-Object { $_.Tip -notmatch '^[0-9A-F]{4}:[0-9A-F]{8}\z' }).Count -eq 0)) $null
    Test-Check 'catalog: Japanese and Chinese carry their font package, the others none' ((@($cat | Where-Object FontGroup)).Count -eq 2 -and ($cat | Where-Object Tag -eq 'ja-JP').FontGroup -eq 'Jpan' -and ($cat | Where-Object Tag -eq 'zh-CN').FontGroup -eq 'Hans') $null
    Test-Check 'catalog: the input tip of German is 0407:00000407' ((Get-AVDTuneLanguageInputs | Where-Object Tag -eq 'de-DE').Tip -eq '0407:00000407') $null
    Test-Check 'catalog: regions have unique GeoIds, formats include languages and the DACH/Benelux extras' ((@(Get-AVDTuneLanguageRegions | Select-Object -ExpandProperty Id -Unique).Count -eq @(Get-AVDTuneLanguageRegions).Count) -and (@(Get-AVDTuneLanguageCultures | Where-Object Tag -in 'de-AT', 'de-CH', 'en-US').Count -eq 3)) $null
    Test-Check 'catalog: Azure region default: westeurope gives W. Europe Standard Time, an unknown region none' ((Get-AVDTuneLanguageAzureZone 'westeurope') -eq 'W. Europe Standard Time' -and $null -eq (Get-AVDTuneLanguageAzureZone 'mars1')) $null
    Test-Check 'sources: every source is an https Microsoft Learn address' (@((Get-AVDTuneLanguageSources).Values | Where-Object { $_ -notmatch '^https://learn\.microsoft\.com/' }).Count -eq 0) $null

    # ---------------------------------------------------------------- configuration
    Test-Check 'source: local drive root, folder and share are plain' ((Test-AVDTuneLanguageSource 'E:\') -and (Test-AVDTuneLanguageSource 'D:\Lang\LanguagesAndOptionalFeatures') -and (Test-AVDTuneLanguageSource '\\fs01\lang$')) $null
    Test-Check 'source: counter-tests: relative, parent part, quotes, pipe, empty, URL are refused' (-not ((Test-AVDTuneLanguageSource 'lang\x') -or (Test-AVDTuneLanguageSource 'E:\a\..\b') -or (Test-AVDTuneLanguageSource 'E:\a"b') -or (Test-AVDTuneLanguageSource 'E:\a|b') -or (Test-AVDTuneLanguageSource '') -or (Test-AVDTuneLanguageSource 'https://example.invalid/x'))) $null
    Test-Check 'config: empty configuration is valid' (@(Test-AVDTuneLanguageConfig (Get-AVDTuneLanguageDefaults)).Count -eq 0) $null
    Test-Check 'config: a full valid configuration is accepted' (@(Test-AVDTuneLanguageConfig (New-Cfg @{ Languages = @('de-DE', 'fr-FR'); Source = 'E:\'; UiLanguage = 'de-DE'; Culture = 'de-CH'; InputTip = '0407:00000407'; GeoId = 223; SystemLocale = 'de-DE'; TimeZone = 'W. Europe Standard Time' })).Count -eq 0) $null
    foreach ($case in @(
            @('a language that is not on the list', @{ Languages = @('xx-XX') }), @('lower case tag', @{ Languages = @('de-de') }), @('a language twice', @{ Languages = @('de-DE', 'de-DE'); Source = 'E:\' }),
            @('a command in a tag', @{ Languages = @('de-DE; calc'); Source = 'E:\' }), @('a language that is a number', @{ Languages = @(5) }),
            @('a new language without a content folder', @{ Languages = @('de-DE') }), @('a content folder with ..', @{ Languages = @('de-DE'); Source = 'E:\..\x' }),
            @('a display language not on the list', @{ UiLanguage = 'klingon' }), @('a format not on the list', @{ Culture = 'xx-YY' }), @('an input not on the list', @{ InputTip = '0407:0000ZZZZ' }),
            @('a GeoId as text', @{ GeoId = '94' }), @('a GeoId not on the list', @{ GeoId = 99999 }), @('a system locale not on the list', @{ SystemLocale = 'de' }),
            @('a time zone with a pipe', @{ TimeZone = 'UTC|calc' }), @('a time zone that is not text', @{ TimeZone = 5 }))) {
        Test-Check "config: counter-test: $($case[0]) is refused" (@(Test-AVDTuneLanguageConfig (New-Cfg $case[1])).Count -gt 0) $null
    }
    Test-Check 'config: an installed language needs no content folder' (@(Test-AVDTuneLanguageConfig (New-Cfg @{ Languages = @('en-US') }) -InstalledTags @('en-US')).Count -eq 0) $null
    Test-Check 'config: ConvertTo throws on a bad value, normalizes a good one' ((Test-Throws { ConvertTo-AVDTuneLanguageConfig (New-Cfg @{ GeoId = '94' }) }) -and (ConvertTo-AVDTuneLanguageConfig (New-Cfg @{ GeoId = 94; TimeZone = '' })).TimeZone -eq $null) $null
    $saved = Set-AVDTuneLanguageConfig -Root $state -Config (New-Cfg @{ Languages = @('de-DE'); Source = 'E:\'; GeoId = 94 })
    Test-Check 'config: saved and read back; a damaged saved file is refused (fail closed)' ((@(Get-AVDTuneLanguageConfig -Root $state).Count -eq 1) -and (Get-AVDTuneLanguageConfig -Root $state).GeoId -eq 94) $null
    [IO.File]::WriteAllText((Get-AVDTuneLanguageConfigPath $state), '{"GeoId":"94","Languages":["de-DE"],"Source":"E:\\"}')
    Test-Check 'config: a saved GeoId as text is refused' (Test-Throws { Get-AVDTuneLanguageConfig -Root $state }) $null
    Remove-Item (Get-AVDTuneLanguageConfigPath $state) -Force

    # ---------------------------------------------------------------- DISM call list
    $calls = @(Get-AVDTuneLanguageDismCalls -Tag 'de-DE' -Source 'E:\')
    Test-Check 'dism: German = the client pack plus five features, nothing else' ($calls.Count -eq 6 -and $calls[0].Args[1] -eq '/Add-Package' -and @($calls[1..5] | Where-Object { $_.Args[1] -ne '/Add-Capability' }).Count -eq 0) $calls.Count
    Test-Check 'dism: every capability call has /LimitAccess and a /Source (no Windows Update, no internet)' (@($calls[1..5] | Where-Object { $_.Args -notcontains '/LimitAccess' -or -not ($_.Args | Where-Object { $_ -like '/Source:*' }) }).Count -eq 0) $null
    Test-Check 'dism: the root of a drive keeps its backslash (E: alone means the current folder of drive E)' (($calls[1].Args -contains '/Source:E:\') -and ($calls[0].Args[2] -eq '/PackagePath:E:\Microsoft-Windows-Client-Language-Pack_x64_de-DE.cab')) ($calls[1].Args -join ' ')
    $ja = @(Get-AVDTuneLanguageDismCalls -Tag 'ja-JP' -Source 'D:\LOF\')
    Test-Check 'dism: Japanese gets the font package; a folder source is trimmed' ($ja.Count -eq 7 -and ($ja[6].Args -contains '/CapabilityName:Language.Fonts.Jpan~~~und-Jpan~0.0.1.0') -and ($ja[0].Args[2] -eq '/PackagePath:D:\LOF\Microsoft-Windows-Client-Language-Pack_x64_ja-JP.cab')) $ja.Count
    Test-Check 'dism: counter-tests: a tag that is not on the list and a source with a quote throw before anything is built' ((Test-Throws { Get-AVDTuneLanguageDismCalls -Tag 'de-DE /x' -Source 'E:\' }) -and (Test-Throws { Get-AVDTuneLanguageDismCalls -Tag 'de-DE' -Source 'E:\a"b' })) $null

    # ---------------------------------------------------------------- DISM run (fake update adapter)
    $w = New-World
    $r = Invoke-AVDTuneLanguageDism -U $w.L.U -Tag 'de-DE' -Source 'E:\'
    $runs = @($w.L.U.Log | Where-Object { $_ -like 'Run *' })
    Test-Check 'dism run: six calls with the full path of Dism.exe, signature checked first' ($runs.Count -eq 6 -and @($runs | Where-Object { $_ -notlike 'Run C:\fake\System32\Dism.exe *' }).Count -eq 0 -and ($w.L.U.Log | Where-Object { $_ -like 'VerifySignature*' }).Count -ge 1) ($runs -join ' | ')
    $w = New-World -LangSeed @{ Unsigned = $true }
    Test-Check 'dism run: counter-test: a DISM that is not signed by Microsoft is not started' ((Test-Throws { Invoke-AVDTuneLanguageDism -U $w.L.U -Tag 'de-DE' -Source 'E:\' }) -and @($w.L.U.Log | Where-Object { $_ -like 'Run *' }).Count -eq 0) $null
    $w = New-World -LangSeed @{ DismFails = @{ 'Client-Language-Pack' = 50 } }
    $thrown = ''; try { & $w.L.AddLanguage 'de-DE' 'E:\' | Out-Null } catch { $thrown = $_.Exception.Message }
    Test-Check 'dism run: a failing required call ends the run with the exit code' ($thrown -like '*exit 50*') $thrown
    $w = New-World -LangSeed @{ DismFails = @{ 'Handwriting' = 87 } }
    $r = & $w.L.AddLanguage 'de-DE' 'E:\'
    Test-Check 'dism run: an optional feature that is not on the ISO is noted and skipped' ($r.Notes.Count -eq 1 -and $r.Notes[0] -like '*Handwriting*87*') ($r.Notes -join ';')
    $w = New-World -LangSeed @{ DismFails = @{ 'Basic' = 3010 } }
    Test-Check 'dism run: 3010 is success and asks for a restart' ((& $w.L.AddLanguage 'de-DE' 'E:\').Reboot) $null

    # ---------------------------------------------------------------- state and rows
    $w = New-World; & $w.M.RegSet 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\Locale' '(default)' '00000407' 'String'
    $st = Get-AVDTuneLanguageState -Machine $w.M -L $w.L
    Test-Check 'state: new-user values are read from .DEFAULT, system locale from its LCID, time zone and Azure region default' ($st.NewUser.Ui -eq 'en-US' -and $st.NewUser.Culture -eq 'en-US' -and $st.NewUser.InputTip -eq '0409:00000409' -and $st.NewUser.GeoId -eq 244 -and $st.SystemLocale -eq 'de-DE' -and $st.TimeZone -eq 'UTC' -and $st.AzureRegion -eq 'westeurope' -and $st.DefaultTimeZone -eq 'W. Europe Standard Time') ($st | ConvertTo-Json -Depth 3 -Compress)
    $w2 = New-World; $n0 = @($w2.M.Log).Count; Test-Check 'state: reading changes nothing (no write in the log, LastChange untouched)' ((Get-AVDTuneLanguageRows -Machine $w2.M -L $w2.L -Config (New-Cfg @{ Languages = @('de-DE'); Source = 'E:\'; UiLanguage = 'de-DE' }) | Measure-Object).Count -ge 7 -and @($w2.M.Log).Count -eq $n0 -and -not (Get-AVDTuneState $state).LastChange) $null
    $rows = Get-AVDTuneLanguageRows -Machine $w2.M -L $w2.L -Config (New-Cfg @{ Languages = @('de-DE'); UiLanguage = 'de-DE'; TimeZone = 'W. Europe Standard Time' })
    Test-Check 'rows: the wanted display language and time zone are marked as differing, the language as not installed' ((@($rows | Where-Object { $_.Id -eq 'language.ui' }).Status -eq 'warn') -and (@($rows | Where-Object { $_.Id -eq 'language.timezone' }).Status -eq 'warn') -and (@($rows | Where-Object { $_.Id -eq 'language.add.de-de' }).Status -eq 'warn') -and (@($rows | Where-Object { $_.Id -eq 'language.geo' }).Status -eq 'ok')) $null
    Test-Check 'rows: the unverified settings say so (hive of new users, Copy)' (@($rows | Where-Object { $_.Id -in 'language.ui', 'language.culture', 'language.input', 'language.geo', 'language.sysloc' -and $_.Verified }).Count -eq 0) $null

    # ---------------------------------------------------------------- Apply: gate, WhatIf
    $w = New-World
    $cfg = New-Cfg @{ Languages = @('de-DE'); Source = 'E:\'; UiLanguage = 'de-DE'; Culture = 'de-DE'; InputTip = '0407:00000407'; GeoId = 94; SystemLocale = 'de-DE'; TimeZone = 'W. Europe Standard Time' }
    Close-AVDTuneWriteGate
    Test-Check 'apply: counter-test: the closed gate refuses (nothing installed, nothing set, no undo record)' ((Test-Throws { Invoke-AVDTuneLanguage -Machine $w.M -L $w.L -Root $state -Config $cfg }) -and @($w.L.Log | Where-Object { $_ -like 'AddLanguage*' -or $_ -like 'SetUserIntl*' }).Count -eq 0 -and -not (Test-Path (Get-AVDTuneLanguageUndoPath $state))) $null
    $dry = Invoke-AVDTuneLanguage -Machine $w.M -L $w.L -Root $state -Config $cfg -WhatIf
    Test-Check 'apply: a dry run works without the gate, says what would change and writes nothing' ((@($dry.Results | Where-Object Status -eq 'WhatIf').Count -ge 8) -and @($w.L.Log | Where-Object { $_ -like 'AddLanguage*' -or $_ -like 'SetUserIntl*' -or $_ -like 'CopyToSystem' }).Count -eq 0 -and -not (Test-Path (Get-AVDTuneLanguageUndoPath $state)) -and (@(Get-AVDTuneRun -Root $state).Count -eq 0)) ($dry.Results.Status -join ',')
    Test-Check 'apply: the source of the content folder is asked (CheckSource) before installing' (@($w.L.Log | Where-Object { $_ -eq 'CheckSource E:\' }).Count -ge 1) $null

    # ---------------------------------------------------------------- Apply everything
    Open-AVDTuneWriteGate -SnapshotId 'snap-1' -ConfirmedBy 'admin1'
    $run = Invoke-AVDTuneLanguage -Machine $w.M -L $w.L -Root $state -Config $cfg -User 'admin1' -SnapshotId 'snap-1'
    Test-Check 'apply: every step changed or was already fine, none failed' (@($run.Results | Where-Object Status -eq 'Failed').Count -eq 0 -and (Get-R $run 'language.add-de-de').Status -eq 'Changed' -and (Get-R $run 'language.ui').Status -eq 'Changed' -and (Get-R $run 'language.sysloc').Status -eq 'Changed' -and (Get-R $run 'language.timezone').Status -eq 'Changed') ($run.Results | ForEach-Object { "$($_.Id)=$($_.Status)" }) -join ' '
    Test-Check 'apply: the language was installed from the folder (DISM through the update adapter), the cleanup of language packs is off' (@($w.L.Log | Where-Object { $_ -eq 'AddLanguage de-DE from E:\' }).Count -eq 1 -and (& $w.M.TaskGet '\Microsoft\Windows\MUI\' 'LPRemove').Enabled -eq $false -and (& $w.M.RegGet 'HKLM:\SOFTWARE\Policies\Microsoft\Control Panel\International' 'BlockCleanupOfUnusedPreinstalledLangPacks') -eq 1) $null
    $nu = Get-AVDTuneLanguageNewUser $w.M
    Test-Check 'apply: new users now get German: display language, format, keyboard, location (.DEFAULT) and the system locale and time zone' ($nu.Ui -eq 'de-DE' -and $nu.Culture -eq 'de-DE' -and $nu.InputTip -eq '0407:00000407' -and $nu.GeoId -eq 94 -and (Get-AVDTuneLanguageState -Machine $w.M -L $w.L).SystemLocale -eq 'de-DE' -and (& $w.M.RegGet 'HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation' 'TimeZoneKeyName') -eq 'W. Europe Standard Time') ($nu | ConvertTo-Json -Compress)
    Test-Check 'apply: the settings are set on the current user first, then copied once to the welcome screen and new users' (@($w.L.Log | Where-Object { $_ -eq 'CopyToSystem' }).Count -eq 1 -and (@($w.L.Log) -join '|') -match 'SetUserIntl ui=de-DE.*CopyToSystem') (@($w.L.Log) -join '|')
    $runs = @(Get-AVDTuneRun -Root $state); $cl = @(Get-AVDTuneChangeLog -Root $state | Where-Object { $_.Category -eq 'Language' })
    Test-Check 'apply: one run record, a change log entry per change (category Language) and LastChange set' ($runs.Count -eq 1 -and $runs[0].Plan -eq 'Language and region' -and $cl.Count -ge 8 -and $runs[0].Reboot -and (Get-AVDTuneState $state).LastChange) ($cl.Count)
    $u1 = Read-AVDTuneJson (Get-AVDTuneLanguageUndoPath $state)
    Test-Check 'apply: the values found before are kept for undo (new users, administrator, system locale, time zone)' ($u1.NewUser.Ui -eq 'en-US' -and $u1.NewUser.GeoId -eq 244 -and $u1.Admin.Culture -eq 'en-US' -and $u1.SystemLocale -eq 'en-US' -and $u1.TimeZone -eq 'UTC') ($u1 | ConvertTo-Json -Compress)
    $run2 = Invoke-AVDTuneLanguage -Machine $w.M -L $w.L -Root $state -Config $cfg -User 'admin1' -SnapshotId 'snap-1'
    Test-Check 'apply: a second run changes nothing (Unchanged everywhere) and does not copy again' (@($run2.Results | Where-Object Status -ne 'Unchanged').Count -eq 0 -and @($w.L.Log | Where-Object { $_ -eq 'CopyToSystem' }).Count -eq 1) ($run2.Results.Status -join ',')
    Test-Check 'apply: the earlier values are never overwritten by a later run' ((Read-AVDTuneJson (Get-AVDTuneLanguageUndoPath $state)).NewUser.Ui -eq 'en-US') $null

    # ---------------------------------------------------------------- Undo
    Close-AVDTuneWriteGate
    Test-Check 'undo: counter-test: the closed gate refuses' (Test-Throws { Undo-AVDTuneLanguage -Machine $w.M -L $w.L -Root $state }) $null
    Open-AVDTuneWriteGate -SnapshotId 'snap-2' -ConfirmedBy 'admin1'
    [IO.File]::WriteAllText((Get-AVDTuneLanguageUndoPath $state), '{"NewUser":{"Ui":"en-US","Culture":"en-US","InputTip":"0409:00000409","GeoId":"244"},"SystemLocale":"en-US","TimeZone":"UTC"}')
    $logBefore = @($w.L.Log).Count
    Test-Check 'undo: counter-test: a record with a typed value that is text (GeoId "244") is refused and nothing is changed' ((Test-Throws { Undo-AVDTuneLanguage -Machine $w.M -L $w.L -Root $state }) -and @($w.L.Log).Count -eq $logBefore -and (Get-AVDTuneLanguageNewUser $w.M).Ui -eq 'de-DE') $null
    [IO.File]::WriteAllText((Get-AVDTuneLanguageUndoPath $state), ($u1 | ConvertTo-Json -Depth 5))
    $ur = Undo-AVDTuneLanguage -Machine $w.M -L $w.L -Root $state -User 'admin1' -SnapshotId 'snap-2'
    $nu = Get-AVDTuneLanguageNewUser $w.M
    Test-Check 'undo: new users, system locale, time zone and the cleanup settings are back as found' ($nu.Ui -eq 'en-US' -and $nu.Culture -eq 'en-US' -and $nu.GeoId -eq 244 -and (Get-AVDTuneLanguageState -Machine $w.M -L $w.L).SystemLocale -eq 'en-US' -and (& $w.M.RegGet 'HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation' 'TimeZoneKeyName') -eq 'UTC' -and (& $w.M.TaskGet '\Microsoft\Windows\MUI\' 'LPRemove').Enabled -eq $true -and $null -eq (& $w.M.RegGet 'HKLM:\SYSTEM\CurrentControlSet\Control\International' 'x')) ($ur.Results | ForEach-Object { "$($_.Id)=$($_.Status)" }) -join ' '
    Test-Check 'undo: the administrator own settings are put back last (the copy had to use the new values)' ($w.L.Store.User.Ui -eq 'en-US' -and $w.L.Store.User.GeoId -eq 244 -and @($w.L.Log | Where-Object { $_ -like 'SetUserIntl*' })[-1] -like 'SetUserIntl ui=en-US*') (@($w.L.Log | Where-Object { $_ -like 'SetUserIntl*' })[-1])
    Test-Check 'undo: the installed language pack stays (no step removes it), the run is recorded and the record is gone' ($w.L.Store.Installed -contains 'de-DE' -and @($ur.Results | Where-Object Id -like 'language.add-*').Count -eq 0 -and @(Get-AVDTuneRun -Root $state).Count -eq 3 -and -not (Test-Path (Get-AVDTuneLanguageUndoPath $state)) -and -not (Test-Path (Get-AVDTuneLanguageAppliedPath $state))) "$($w.L.Store.Installed -contains 'de-DE') $(@(Get-AVDTuneRun -Root $state).Count) $(Test-Path (Get-AVDTuneLanguageUndoPath $state)) $(Test-Path (Get-AVDTuneLanguageAppliedPath $state)) $($ur.Results.Id -join ',')"
    Test-Check 'undo: counter-test: undo again has nothing to undo' (Test-Throws { Undo-AVDTuneLanguage -Machine $w.M -L $w.L -Root $state }) $null
    $cl2 = @(Get-AVDTuneChangeLog -Root $state | Where-Object { $_.Category -eq 'Language' -and $_.Text -like 'Undo:*' })
    Test-Check 'undo: the change log names every undone setting' ($cl2.Count -ge 6) $cl2.Count

    # ---------------------------------------------------------------- only what this tool changed is undone
    $w = New-World
    $cfgB = New-Cfg @{ UiLanguage = 'en-US'; GeoId = 244; Culture = 'de-DE' }   # UI and geo equal the image: only the format changes
    $rb = Invoke-AVDTuneLanguage -Machine $w.M -L $w.L -Root $state -Config $cfgB -Parts Defaults -User 'admin1' -SnapshotId 'snap-2'
    Test-Check 'partial: only the differing setting is changed, the others stay Unchanged' ((Get-R $rb 'language.culture').Status -eq 'Changed' -and (Get-R $rb 'language.ui').Status -eq 'Unchanged' -and (Get-R $rb 'language.geo').Status -eq 'Unchanged') ($rb.Results | ForEach-Object { "$($_.Id)=$($_.Status)" }) -join ' '
    [void](Undo-AVDTuneLanguage -Machine $w.M -L $w.L -Root $state -User 'admin1' -SnapshotId 'snap-2')
    Test-Check 'partial: undo reverts the changed one and does not touch what it never set' ((Get-AVDTuneLanguageNewUser $w.M).Culture -eq 'en-US') $null

    # ---------------------------------------------------------------- refusals and failures
    $w = New-World
    $r1 = Invoke-AVDTuneLanguage -Machine $w.M -L $w.L -Root $state -Config (New-Cfg @{ UiLanguage = 'de-DE' }) -Parts Defaults -User 'admin1' -SnapshotId 'snap-2'
    Test-Check 'ui language: counter-test: a display language that is not installed fails with the hint to install it first, nothing is copied' ((Get-R $r1 'language.ui').Status -eq 'Failed' -and (Get-R $r1 'language.ui').Message -like '*not installed*Install it first*' -and @($w.L.Log | Where-Object { $_ -eq 'CopyToSystem' }).Count -eq 0) ((Get-R $r1 'language.ui').Message)
    Test-Check 'ui language: a failed attempt still sets LastChange and writes a run' ((Get-AVDTuneState $state).LastChange -and @(Get-AVDTuneRun -Root $state).Count -ge 3) $null
    $w = New-World -LangSeed @{ SourceProblem = 'The folder can be written by users who are not administrators.'; SourceKind = 'Local' }
    Test-Check 'source: counter-test: a content folder the adapter refuses stops the install before DISM' ((Test-Throws { Invoke-AVDTuneLanguage -Machine $w.M -L $w.L -Root $state -Config (New-Cfg @{ Languages = @('de-DE'); Source = 'D:\x' }) -Parts Languages }) -and @($w.L.Log | Where-Object { $_ -like 'AddLanguage*' }).Count -eq 0) $null
    $w = New-World
    Test-Check 'time zone: counter-test: a zone Windows does not know is refused before anything changes' ((Test-Throws { Invoke-AVDTuneLanguage -Machine $w.M -L $w.L -Root $state -Config (New-Cfg @{ TimeZone = 'Mars Standard Time' }) -Parts Defaults }) -and @($w.L.Log | Where-Object { $_ -like 'SetTimeZone*' -or $_ -like 'SetUserIntl*' }).Count -eq 0) $null
    $w = New-World -LangSeed @{ CopyFails = $true }
    $r3 = Invoke-AVDTuneLanguage -Machine $w.M -L $w.L -Root $state -Config (New-Cfg @{ Culture = 'de-DE' }) -Parts Defaults -User 'admin1' -SnapshotId 'snap-2'
    Test-Check 'copy: a failing Copy-UserInternationalSettingsToSystem is a failed step with its message, later steps are skipped, the record is kept for undo' ((Get-R $r3 'language.culture').Status -eq 'Failed' -and (Get-R $r3 'language.culture').Message -like '*Copy-UserInternationalSettingsToSystem failed*' -and (Test-Path (Get-AVDTuneLanguageUndoPath $state))) ((Get-R $r3 'language.culture').Message)
    Test-Check 'copy: a failed copy puts the settings of the administrator back' ($w.L.Store.User.Culture -eq 'en-US') $null
    $w = New-World -LangSeed @{ TzFails = $true }
    $r4 = Invoke-AVDTuneLanguage -Machine $w.M -L $w.L -Root $state -Config (New-Cfg @{ TimeZone = 'Eastern Standard Time' }) -Parts Defaults -User 'admin1' -SnapshotId 'snap-2'
    Test-Check 'time zone: a failing Set-TimeZone is a failed step' ((Get-R $r4 'language.timezone').Status -eq 'Failed') $null
    $w = New-World -LangSeed @{ DismFails = @{ 'Client-Language-Pack' = 50 } }
    $r5 = Invoke-AVDTuneLanguage -Machine $w.M -L $w.L -Root $state -Config (New-Cfg @{ Languages = @('fr-FR'); Source = 'E:\' }) -Parts Languages -User 'admin1' -SnapshotId 'snap-2'
    Test-Check 'install: a failing DISM is a failed step with the exit code; the language is not marked as installed' ((Get-R $r5 'language.add-fr-fr').Status -eq 'Failed' -and (Get-R $r5 'language.add-fr-fr').Message -like '*exit 50*' -and $w.L.Store.Installed -notcontains 'fr-FR') ((Get-R $r5 'language.add-fr-fr').Message)
    $ids = @(Get-AVDTuneLanguageSteps -L $w.L -Config (New-Cfg @{ Languages = @('fr-FR') }) -Want (Resolve-AVDTuneLanguageConfig (New-Cfg) (Get-AVDTuneLanguageState -Machine $w.M -L $w.L)) -Parts Languages -Source 'E:\')
    $addStep = $ids | Where-Object Id -eq 'language.add-fr-fr'
    Test-Check 'install: a language step has no undo (the confirmation says so)' ($null -eq $addStep.Undo) $null

    # ---------------------------------------------------------------- confirmation texts
    $stN = Get-AVDTuneLanguageState -Machine $w.M -L $w.L
    $txt = Get-AVDTuneLanguageConfirmText -Mode All -Config (New-Cfg @{ Languages = @('de-DE', 'en-US'); Source = 'E:\' }) -State $stN
    Test-Check 'confirm: names the new language, the folder, that install CANNOT be undone and the restart; an installed language is not named' (($txt -like '*de-DE*') -and ($txt -notlike '*en-US from*') -and ($txt -like '*CANNOT be undone*') -and ($txt -like '*restart*') -and ($txt -like '*E:\*') -and ($txt -like '*snapshot*')) $txt
    Test-Check 'confirm: defaults only does not talk about installing; undo says packs stay' ((Get-AVDTuneLanguageConfirmText -Mode Defaults -Config (New-Cfg) -State $stN) -notlike '*Install*' -and (Get-AVDTuneLanguageConfirmText -Mode Undo -Config (New-Cfg) -State $stN) -like '*stay*') $null

    # ---------------------------------------------------------------- the module itself
    $modText = Get-Content (Join-Path $repo 'Modules\AVDTune.Language.psm1') -Raw
    Test-Check 'module: never downloads or runs from text: no web request, no Invoke-Expression, no Start-Process, no script block from data, no direct DISM or reg.exe call' ($modText -notmatch 'Invoke-WebRequest|Invoke-RestMethod|Net\.WebClient|HttpWebRequest|Invoke-Expression|\biex\b|Start-Process|\[scriptblock\]::Create|reg\.exe|cmd\.exe') $null
    Test-Check 'module: DISM is only started through the update adapter (full path, signature, job object, central child environment)' (($modText -match 'Test-AVDTuneToolTrust' ) -and ($modText -match "\& \`$U\.Path 'Dism'") -and ($modText -match '\& \$U\.Run')) $null
    Test-Check 'module: no personal or tenant data (public content)' ($modText -notmatch '@[a-z0-9-]+\.(de|com)\b' -and $modText -notmatch '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}') $null
    $real = New-AVDTuneLanguageAdapter
    Test-Check 'real adapter: it can be built without touching anything and has every member the module uses' (@('GetInstalled', 'GetUserIntl', 'SetUserIntl', 'CopyToSystem', 'SetSystemLocale', 'GetTimeZones', 'SetTimeZone', 'CheckSource', 'AddLanguage' | Where-Object { -not $real.PSObject.Properties[$_] }).Count -eq 0) $null
    Test-Check 'real adapter: counter-test: a value that is not on the list is refused before a cmdlet runs' ((Test-Throws { & $real.SetUserIntl @{ Ui = 'xx-XX' } }) -and (Test-Throws { & $real.SetSystemLocale 'de-DE; calc' }) -and (Test-Throws { & $real.SetUserIntl @{ GeoId = 1 } }) -and (Test-Throws { & $real.SetUserIntl @{ InputTip = '0407:0000ZZZZ' } })) $null
    $fakeMembers = @($w.L.PSObject.Properties | Where-Object { $_.Value -is [scriptblock] } | ForEach-Object Name | Sort-Object)
    $realMembers = @($real.PSObject.Properties | Where-Object { $_.Value -is [scriptblock] } | ForEach-Object Name | Sort-Object)
    Test-Check 'fake and real adapter have the same members' (($fakeMembers -join ',') -eq ($realMembers -join ',')) "$($fakeMembers -join ',') <> $($realMembers -join ',')"
    foreach ($f in 'Modules\AVDTune.Language.psm1', 'AVDTune-Language.ps1', 'Tests\Fakes\FakeLanguage.ps1', 'Tests\Check-Language.ps1') {
        $p = Join-Path $repo $f
        if (Test-Path $p) { Test-Check "$f is plain ASCII" (-not (@([IO.File]::ReadAllBytes($p) | Where-Object { $_ -gt 127 }).Count)) $null }
    }
    $startText = Get-Content (Join-Path $repo 'Start-AVDTune.ps1') -Raw
    Test-Check 'hooks: Start-AVDTune.ps1 loads the module and the page and shows the page' (($startText -match "'Language'") -and ($startText -match 'AVDTune-Language\.ps1') -and ($startText -match 'Update-LangView')) $null
    Test-Check 'docs: docs\language.md has sources and the not verified list' ((Test-Path (Join-Path $repo 'docs\language.md')) -and ((Get-Content (Join-Path $repo 'docs\language.md') -Raw) -match '(?i)not verified') -and ((Get-Content (Join-Path $repo 'docs\language.md') -Raw) -match 'windows-11-language-packs')) $null
}
finally {
    Close-AVDTuneWriteGate
    Remove-Item Env:\AVDTUNE_ROOT -ErrorAction SilentlyContinue
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
if ($script:failed -gt 0) { throw "$script:failed check(s) failed." }
