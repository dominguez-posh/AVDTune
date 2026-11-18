#requires -Version 5.1
<#
.SYNOPSIS
    Checks the web apps (Modules\AVDTune.WebApp.psm1 and the kind 'WebApp' of Modules\AVDTune.Custom.psm1, issue #88, plan 3a) against the fake machine, the fake
    customization adapter and a temporary state folder: URL rules (https only, no user info, nothing a command line reads differently), the Edge policy
    WebAppInstallForceList (only the own entries, foreign ones and their order stay, undo puts back the old value exactly), the launch of the shortcut
    (msedge_proxy.exe with a known app id, else msedge.exe --app with an own AppUserModelID), icons pinned by SHA256, App Masking request, write gate and
    source checks of the page. Nothing touches this computer.
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
foreach ($m in 'AVDTune', 'AVDTune.Updates', 'AVDTune.Software', 'AVDTune.FSLogix', 'AVDTune.Directory', 'AVDTune.Masking', 'AVDTune.Custom') { Import-Module (Join-Path $repo "Modules\$m.psm1") -Force }
. (Join-Path $PSScriptRoot 'Fakes\FakeMachine.ps1')
. (Join-Path $PSScriptRoot 'Fakes\FakeCustom.ps1')

$script:failed = 0
function Test-Check([string]$Name, [bool]$Ok, $Detail) { if ($Ok) { "PASS $Name" } else { $script:failed++; "FAIL $Name" + $(if ($null -ne $Detail) { "  -> $Detail" }) } }
function Get-ThrownText([scriptblock]$Block) { try { & $Block | Out-Null; $null } catch { $_.Exception.Message } }
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('avdtune-webapp-' + [guid]::NewGuid().ToString('N'))
$forbidden = @{ Exact = @('C:', 'C:\Program Files', 'C:\Program Files (x86)', 'C:\ProgramData', 'C:\Users'); Below = @('C:\Windows', $tmp); Programs = @('C:\Program Files', 'C:\Program Files (x86)', 'C:\ProgramData') }
$key = 'hklm:\software\policies\microsoft\edge|webappinstallforcelist'

try {
    $env:AVDTUNE_ROOT = $tmp
    [void](Initialize-AVDTuneState -Root $tmp)
    [void](Start-AVDTuneImageVersion -Root $tmp -Date ([datetime]'2026-11-18') -User 'admin1')
    Close-AVDTuneWriteGate
    Test-Check 'AVDTune.Custom brings the web app functions into the global scope (the GetNewClosure steps resolve them there, also in a job runspace; smoke #88)' ([bool](Get-Command Test-AVDTuneWebAppPolicyHas -ErrorAction Ignore) -and (Get-Module AVDTune.WebApp)) $null

    # ---------------------------------------------------------------- URL rules and validation
    $badUrls = @('http://app.example.test/', 'https://user:pw@app.example.test/', 'https://app.example.test/a b', 'https://app.example.test/"x', 'javascript:alert(1)', 'https:///x', 'file:///C:/x', "https://app.example.test/`n", 'https://app.example.test/\x', ('https://app.example.test/' + ('a' * 2048)), ('https://' + [char]0xE4 + '.example.test/'))
    $through = @($badUrls | Where-Object { -not (Test-AVDTuneWebAppUrl $_) })
    Test-Check 'URL: http, user info, space, quote, backslash, control and non-ASCII characters, other schemes and too long URLs are refused' ($through.Count -eq 0) ($through -join ' | ')
    Test-Check 'URL: https with path, query, port and fragment is taken' (-not (Test-AVDTuneWebAppUrl 'https://app.example.test:8443/start?src=pwa#home')) (Test-AVDTuneWebAppUrl 'https://app.example.test:8443/start?src=pwa#home')
    $lib = @([pscustomobject]@{ Name = 'crm.ico'; Sha256 = ('a' * 64); Size = 4; Extension = '.ico' }, [pscustomobject]@{ Name = 'crm.png'; Sha256 = ('b' * 64); Size = 4; Extension = '.png' }, [pscustomobject]@{ Name = 'crm.svg'; Sha256 = ('c' * 64); Size = 4; Extension = '.svg' })
    $ok = ConvertTo-AVDTuneCustomItem -Raw @{ Kind = 'WebApp'; Name = 'CRM Web'; StartUrl = ' https://crm.example.test/app '; ManifestId = 'https://crm.example.test/app/'; WindowMode = 'Window'; Location = 'Both'; IconFile = 'crm.ico'; Visibility = 'Admins' } -FromForm -Library $lib -Forbidden $forbidden
    Test-Check 'a web app from the form: trimmed, icon pinned by the SHA256 of the manifest, id made' ($ok.Valid -and $ok.Item.StartUrl -ceq 'https://crm.example.test/app' -and $ok.Item.IconSha256 -eq ('a' * 64) -and $ok.Item.Id -cmatch '\A[0-9a-f]{12}\z') ($ok.Errors -join ' ')
    $bad = @(
        @('http start URL', @{ StartUrl = 'http://crm.example.test/' }),
        @('manifest id of another origin', @{ ManifestId = 'https://other.example.test/app' }),
        @('app id not in the Edge form', @{ AppId = 'ABCDEFGHIJKLMNOPABCDEFGHIJKLMNOP' }),
        @('app id too short', @{ AppId = 'abcdefgh' }),
        @('unknown window mode', @{ WindowMode = 'Fullscreen' }),
        @('no location', @{ Location = '' }),
        @('svg icon', @{ IconFile = 'crm.svg' }),
        @('icon not in the library', @{ IconFile = 'other.ico' }),
        @('name with a slash', @{ Name = 'CRM/Web' }),
        @('visibility on the Start menu only', @{ Location = 'StartMenu'; Visibility = 'Admins' })
    )
    foreach ($b in $bad) {
        $raw = @{ Kind = 'WebApp'; Name = 'CRM Web'; StartUrl = 'https://crm.example.test/app'; WindowMode = 'Window'; Location = 'Desktop' }
        foreach ($k in $b[1].Keys) { $raw[$k] = $b[1][$k] }
        $r = ConvertTo-AVDTuneCustomItem -Raw $raw -FromForm -Library $lib -Forbidden $forbidden
        Test-Check "web app refused: $($b[0])" (-not $r.Valid) ($r.Item | ConvertTo-Json -Compress)
    }
    $typed = ConvertTo-AVDTuneCustomItem -Raw ([pscustomobject]@{ Id = 'abcdef012345'; Kind = 'WebApp'; Name = 'X'; StartUrl = 'https://x.example.test/'; ManifestId = ''; AppId = ''; WindowMode = 'Window'; Location = 'Desktop'; IconFile = ''; IconSha256 = ''; Visibility = $false }) -Forbidden $forbidden
    Test-Check 'state is read typed: a visibility that is not text is refused' (-not $typed.Valid) $null

    # ---------------------------------------------------------------- app id and launch
    $g1 = Get-AVDTuneWebAppIdGuess -StartUrl 'https://crm.example.test/app'
    $g2 = Get-AVDTuneWebAppIdGuess -StartUrl 'https://crm.example.test/app' -ManifestId 'https://crm.example.test/id'
    Test-Check 'app id guess: 32 letters a-p, from the manifest id when there is one' ($g1 -cmatch '\A[a-p]{32}\z' -and $g2 -cmatch '\A[a-p]{32}\z' -and $g1 -ne $g2) "$g1 $g2"
    $sp = Get-AVDTuneWebAppSpike
    Test-Check 'spike: nothing is marked verified yet (app id scheme, custom_name, custom_icon, AppUserModelID of the proxy)' (-not $sp.AppIdSchemeVerified -and -not $sp.CustomName -and -not $sp.CustomIcon -and -not $sp.ProxyAumid) ($sp | ConvertTo-Json -Compress)
    $edge = 'C:\Program Files (x86)\Microsoft\Edge\Application'
    $i0 = $ok.Item
    $l0 = Get-AVDTuneWebAppLaunch -Item $i0 -EdgeFolder $edge
    Test-Check 'launch without an app id: msedge.exe --app=<url> with an own AppUserModelID (the guess is not used while not verified)' ($l0.Target -eq "$edge\msedge.exe" -and $l0.Arguments -ceq '--app=https://crm.example.test/app' -and $l0.AppUserModelId -ceq "AVDTune.WebApp.$($i0.Id)" -and -not $l0.Installed) ($l0 | ConvertTo-Json -Compress)
    $i1 = $i0.PSObject.Copy(); $i1.AppId = 'abcdefghijklmnopabcdefghijklmnop'
    $l1 = Get-AVDTuneWebAppLaunch -Item $i1 -EdgeFolder $edge
    Test-Check 'launch with a known app id: msedge_proxy.exe --profile-directory=Default --app-id=<id>' ($l1.Target -eq "$edge\msedge_proxy.exe" -and $l1.Arguments -ceq '--profile-directory=Default --app-id=abcdefghijklmnopabcdefghijklmnop' -and $l1.Installed) ($l1 | ConvertTo-Json -Compress)
    $i2 = $i0.PSObject.Copy(); $i2.WindowMode = 'Tab'
    $l2 = Get-AVDTuneWebAppLaunch -Item $i2 -EdgeFolder $edge
    $e2 = New-AVDTuneWebAppPolicyEntry -Item $i2
    Test-Check 'tab mode: the URL in a tab, no AppUserModelID; the policy says tab' ($l2.Arguments -ceq 'https://crm.example.test/app' -and -not $l2.AppUserModelId -and $e2.default_launch_container -eq 'tab') ($l2 | ConvertTo-Json -Compress)
    $e0 = New-AVDTuneWebAppPolicyEntry -Item $i0 -IconPath 'C:\x.png'
    Test-Check 'policy entry: url, window, no Edge desktop shortcut, fallback name; custom_name/custom_icon only after the spike' ($e0.url -ceq $i0.StartUrl -and $e0.default_launch_container -eq 'window' -and $e0.create_desktop_shortcut -eq $false -and $e0.fallback_app_name -eq 'CRM Web' -and -not $e0.PSObject.Properties['custom_name'] -and -not $e0.PSObject.Properties['custom_icon']) ($e0 | ConvertTo-Json -Compress)

    # ---------------------------------------------------------------- the policy list (pure)
    $foreign = '[ {"url":"https://other.example.test/","default_launch_container":"tab"} ]'
    $m1 = Merge-AVDTuneWebAppPolicy -Current $foreign -Entry $e0
    $p1 = ConvertFrom-AVDTuneWebAppPolicy $m1
    Test-Check 'merge: the foreign entry stays first, the own one is added' ($p1.Count -eq 2 -and $p1[0].url -eq 'https://other.example.test/' -and $p1[1].url -eq $i0.StartUrl) $m1
    $m2 = Merge-AVDTuneWebAppPolicy -Current $m1 -Entry $e2
    $p2 = ConvertFrom-AVDTuneWebAppPolicy $m2
    Test-Check 'merge: the entry of the same URL is replaced in place, not added twice' ($p2.Count -eq 2 -and $p2[1].default_launch_container -eq 'tab') $m2
    Test-Check 'merge of a single entry gives a JSON list (not an object)' ((Merge-AVDTuneWebAppPolicy -Current '' -Entry $e0).StartsWith('[')) $null
    $notList = @('{"url":"https://x.example.test/"}', 'not json', '[1,2]', '[{"name":"x"}]', '[{"url":5}]')
    $acc = @($notList | Where-Object { -not (Get-ThrownText { ConvertFrom-AVDTuneWebAppPolicy $_ }) })
    Test-Check 'a value that is not a JSON list of entries with a url is not changed (throws)' ($acc.Count -eq 0) ($acc -join ' | ')

    # ---------------------------------------------------------------- Apply and Undo through the customizations (fakes)
    $c = New-AVDTuneFakeCustom -Seed @{ Library = @{ 'crm.ico' = 'ICONBYTES'; 'crm.png' = 'PNGBYTES' }; Registry = @{ $key = @{ Value = $foreign; Kind = 'String' } } }
    $mach = New-AVDTuneFakeMachine -Seed @{ Now = [datetime]'2026-11-18T10:00:00' }
    $libRows = Get-AVDTuneFakeCustomLibrary -C $c
    foreach ($f in @(
            @{ Kind = 'WebApp'; Name = 'CRM Web'; StartUrl = 'https://crm.example.test/app'; WindowMode = 'Window'; Location = 'Both'; IconFile = 'crm.ico'; Visibility = 'Admins' },
            @{ Kind = 'WebApp'; Name = 'Wiki'; StartUrl = 'https://wiki.example.test/'; AppId = 'abcdefghijklmnopabcdefghijklmnop'; WindowMode = 'Window'; Location = 'StartMenu'; IconFile = 'crm.png' })) {
        $r = Add-AVDTuneCustomItem -Root $tmp -Raw $f -Library $libRows; if (-not $r.Valid) { throw "fixture $($f.Name): $($r.Errors -join ' ')" }
    }
    $saved = Get-AVDTuneCustomizations -Root $tmp -Forbidden $forbidden
    Test-Check 'two web apps saved in the customizations (typed) and read back valid' ($saved.Items.Count -eq 2 -and $saved.Invalid.Count -eq 0 -and @($saved.Items | Where-Object { $_.Kind -eq 'WebApp' }).Count -eq 2) ($saved.Invalid | ConvertTo-Json -Compress)
    $ids = @{}; foreach ($i in $saved.Items) { $ids[$i.Name] = $i.Id }
    $st = Get-AVDTuneCustomStatus -Machine $mach -C $c -Root $tmp
    Test-Check 'status: before Apply both web apps test as missing (Edge policy and shortcuts)' (@($st.Items | Where-Object { $_.Status -eq 'NonCompliant' -and $_.State -like '*Edge policy*' }).Count -eq 2) (($st.Items | ForEach-Object { "$($_.Name)=$($_.Status) $($_.State)" }) -join ' | ')
    $gateText = Get-ThrownText { Invoke-AVDTuneCustomRun -Machine $mach -C $c -Root $tmp -Mode Apply }
    Test-Check 'Apply without the snapshot gate changes nothing' ($c.Store.Log.Count -eq 0 -and [string]$c.Store.Registry[$key].Value -ceq $foreign) "$gateText $($c.Store.Log -join ',')"
    Open-AVDTuneWriteGate -SnapshotId 'snap-1' -ConfirmedBy 'Alex Example'
    $run = Invoke-AVDTuneCustomRun -Machine $mach -C $c -Root $tmp -Mode Apply -Context @{ Fake = $true } -User 'admin1' -SnapshotId 'snap-1'
    Test-Check 'Apply: both web apps changed' (@($run.Run.Results | Where-Object { $_.Status -eq 'Changed' }).Count -eq 2) (($run.Run.Results | ForEach-Object { "$($_.Title)=$($_.Status) $($_.Message)" }) -join ' | ')
    $pol = ConvertFrom-AVDTuneWebAppPolicy ([string]$c.Store.Registry[$key].Value)
    Test-Check 'Apply: WebAppInstallForceList keeps the foreign entry first and has both own entries (REG_SZ)' ($c.Store.Registry[$key].Kind -eq 'String' -and $pol.Count -eq 3 -and $pol[0].url -eq 'https://other.example.test/' -and @($pol | Where-Object { $_.url -eq 'https://wiki.example.test/' }).Count -eq 1) ([string]$c.Store.Registry[$key].Value)
    $crmDesk = $c.Store.Shortcuts['c:\users\public\desktop\crm web.lnk']; $crmStart = $c.Store.Shortcuts['c:\programdata\microsoft\windows\start menu\programs\crm web.lnk']
    Test-Check 'Apply: CRM Web on Public Desktop and Start menu, msedge.exe --app with its AppUserModelID and the library icon' ($crmDesk -and $crmStart -and $crmDesk.Target -like '*\msedge.exe' -and $crmDesk.Arguments -ceq '--app=https://crm.example.test/app' -and $crmDesk.AppUserModelId -ceq "AVDTune.WebApp.$($ids['CRM Web'])" -and $crmDesk.Icon -like 'C:\ProgramData\AVDTune-Public\Icons\*.ico,0' -and $crmDesk.WorkingDirectory -eq '') ($crmDesk | ConvertTo-Json -Compress)
    $wiki = $c.Store.Shortcuts['c:\programdata\microsoft\windows\start menu\programs\wiki.lnk']
    Test-Check 'Apply: Wiki (app id known) starts msedge_proxy.exe, no Public Desktop shortcut; the .png is not copied while custom_icon is not verified' ($wiki -and $wiki.Target -like '*\msedge_proxy.exe' -and $wiki.Arguments -ceq '--profile-directory=Default --app-id=abcdefghijklmnopabcdefghijklmnop' -and $wiki.Icon -like '*\msedge_proxy.exe,0' -and -not $c.Store.Shortcuts.ContainsKey('c:\users\public\desktop\wiki.lnk') -and @($c.Store.Files.Keys | Where-Object { $_ -like 'c:\programdata\avdtune-public\icons\*.png' }).Count -eq 0) ($wiki | ConvertTo-Json -Compress)
    Test-Check 'Apply: Edge startup boost and background mode are not switched on' (@($c.Store.Log | Where-Object { $_ -match 'StartupBoost|BackgroundMode' }).Count -eq 0) $null
    $st2 = Get-AVDTuneCustomStatus -Machine $mach -C $c -Root $tmp
    Test-Check 'status after Apply: both in place, the state says installed app or app window' (@($st2.Items | Where-Object { $_.Status -eq 'Compliant' }).Count -eq 2 -and @($st2.Items | Where-Object { $_.State -like '*installed app*' }).Count -eq 1) (($st2.Items | ForEach-Object { "$($_.Name)=$($_.Status) $($_.State)" }) -join ' | ')
    Test-Check 'change log: an entry per web app (category Customizations)' (@(Get-AVDTuneChangeLog -Root $tmp | Where-Object { $_.Category -eq 'Customizations' }).Count -ge 2) $null
    $req = Get-AVDTuneCustomMaskingRequest -Item @($saved.Items | Where-Object { $_.Name -eq 'CRM Web' })[0]
    Test-Check 'App Masking: a web app on the Public Desktop with "Visible for" asks the masking mechanism for its .lnk' ($req -and $req.FileName -eq 'CRM Web.lnk' -and $req.Mode -eq 'Nobody except administrators') ($req | ConvertTo-Json -Compress)

    # someone else changes the list after Apply: undo keeps that change
    $c.Store.Registry[$key] = @{ Value = (Merge-AVDTuneWebAppPolicy -Current ([string]$c.Store.Registry[$key].Value) -Entry ([pscustomobject]@{ url = 'https://late.example.test/' })); Kind = 'String' }
    $u1 = Invoke-AVDTuneCustomRun -Machine $mach -C $c -Root $tmp -Mode Undo -Ids @($ids['Wiki'])
    $pu = ConvertFrom-AVDTuneWebAppPolicy ([string]$c.Store.Registry[$key].Value)
    Test-Check 'Undo of one web app: only its entry and shortcut go, the other web app, the foreign and the later entry stay' ($u1.Run.Results[0].Status -eq 'Changed' -and $pu.Count -eq 3 -and @($pu | Where-Object { $_.url -eq 'https://wiki.example.test/' }).Count -eq 0 -and @($pu | Where-Object { $_.url -eq 'https://late.example.test/' }).Count -eq 1 -and -not $c.Store.Shortcuts.ContainsKey('c:\programdata\microsoft\windows\start menu\programs\wiki.lnk') -and $c.Store.Shortcuts.ContainsKey('c:\users\public\desktop\crm web.lnk')) ([string]$c.Store.Registry[$key].Value)
    $c.Store.Registry[$key] = @{ Value = (Get-AVDTuneWebAppPolicyUndo -Current ([string]$c.Store.Registry[$key].Value) -Url 'https://late.example.test/' -OldExisted $true -OldText '').Text; Kind = 'String' }
    $u2 = Invoke-AVDTuneCustomRun -Machine $mach -C $c -Root $tmp -Mode Undo -Ids @($ids['CRM Web'])
    Test-Check 'Undo of the last own web app: the value is exactly the old text again (same spacing), the shortcuts are gone' ($u2.Run.Results[0].Status -eq 'Changed' -and [string]$c.Store.Registry[$key].Value -ceq $foreign -and $c.Store.Shortcuts.Count -eq 0) ([string]$c.Store.Registry[$key].Value)
    Test-Check 'Undo removes the undo records' ((Read-AVDTuneCustomUndo $tmp).Count -eq 0) $null

    # no value before: undo removes it; a foreign entry of the same URL comes back as it was
    $c.Store.Registry.Remove($key)
    [void](Invoke-AVDTuneCustomRun -Machine $mach -C $c -Root $tmp -Mode Apply -Ids @($ids['Wiki']) -Context @{ Fake = $true })
    $had = $c.Store.Registry.ContainsKey($key)
    [void](Invoke-AVDTuneCustomRun -Machine $mach -C $c -Root $tmp -Mode Undo -Ids @($ids['Wiki']))
    Test-Check 'no value before Apply: Undo removes WebAppInstallForceList again' ($had -and -not $c.Store.Registry.ContainsKey($key)) $null
    $sameUrl = '[{"url":"https://wiki.example.test/","default_launch_container":"tab","custom_name":"Theirs"}]'
    $c.Store.Registry[$key] = @{ Value = $sameUrl; Kind = 'String' }
    [void](Invoke-AVDTuneCustomRun -Machine $mach -C $c -Root $tmp -Mode Apply -Ids @($ids['Wiki']) -Context @{ Fake = $true })
    $mid = ConvertFrom-AVDTuneWebAppPolicy ([string]$c.Store.Registry[$key].Value)
    [void](Invoke-AVDTuneCustomRun -Machine $mach -C $c -Root $tmp -Mode Undo -Ids @($ids['Wiki']))
    Test-Check 'an entry of the same URL from before is replaced by Apply and comes back exactly by Undo' ($mid.Count -eq 1 -and $mid[0].default_launch_container -eq 'window' -and [string]$c.Store.Registry[$key].Value -ceq $sameUrl) ([string]$c.Store.Registry[$key].Value)

    # a value that is not a JSON list or not REG_SZ is not touched
    foreach ($case in @(@{ Value = 'garbage'; Kind = 'String' }, @{ Value = 1; Kind = 'DWord' })) {
        $c.Store.Registry[$key] = $case; $n = $c.Store.Log.Count
        $rr = Invoke-AVDTuneCustomRun -Machine $mach -C $c -Root $tmp -Mode Apply -Ids @($ids['Wiki']) -Context @{ Fake = $true }
        Test-Check "a WebAppInstallForceList that is $($case.Kind) '$($case.Value)' is not changed; the step fails with the reason" ($rr.Run.Results[0].Status -eq 'Failed' -and $c.Store.Registry[$key].Value -eq $case.Value -and @($c.Store.Log | Select-Object -Skip $n | Where-Object { $_ -like 'RegSet*' -or $_ -like 'ShortcutWrite*' }).Count -eq 0) $rr.Run.Results[0].Message
    }
    $c.Store.Registry.Remove($key)
    $c.Store.Shortcuts['c:\programdata\microsoft\windows\start menu\programs\wiki.lnk'] = [pscustomobject]@{ Target = 'C:\x.exe'; Arguments = ''; Icon = ''; WorkingDirectory = ''; Description = 'theirs' }
    $fr = Invoke-AVDTuneCustomRun -Machine $mach -C $c -Root $tmp -Mode Apply -Ids @($ids['Wiki']) -Context @{ Fake = $true }
    Test-Check 'a shortcut of the same name that AVDTune did not make is not replaced (and the policy is not written)' ($fr.Run.Results[0].Status -eq 'Failed' -and $fr.Run.Results[0].Message -like '*not replaced*' -and -not $c.Store.Registry.ContainsKey($key)) $fr.Run.Results[0].Message
    Close-AVDTuneWriteGate

    # ---------------------------------------------------------------- sources
    $mod = Get-Content -Raw (Join-Path $repo 'Modules\AVDTune.WebApp.psm1')
    $cust = Get-Content -Raw (Join-Path $repo 'Modules\AVDTune.Custom.psm1')
    $page = Get-Content -Raw (Join-Path $repo 'AVDTune-Custom.ps1')
    Test-Check 'sources: no StartupBoost/BackgroundMode value is written, Edge comes from ProgramFilesX86 (never PATH), the AUMID is set on the temp link before the move' ($mod -notmatch 'StartupBoostEnabled|BackgroundModeEnabled' -and $cust -notmatch 'StartupBoostEnabled|BackgroundModeEnabled' -and $cust -match "GetFolderPath\('ProgramFilesX86'\)\) 'Microsoft\\Edge\\Application'" -and $cust -match 'Set-AVDTuneLinkAumid \$temp') $null
    Test-Check 'page: web apps have their own list and the window mode and icon (.ico/.png) in the form, texts through T' ($page -match "'WebApps'" -and $page -match 'PanelCustWebApps' -and $page -match "'WindowMode'" -and $page -match "'\.ico', '\.png'") $null
    foreach ($lang in 'en', 'de') {
        $s = Get-Content -Raw -Encoding UTF8 (Join-Path $repo "UI\Strings.$lang.json") | ConvertFrom-Json
        $miss = @('cust.card.webapps', 'cust.card.webapps.hint', 'cust.empty.webapps', 'cust.kind.webapp', 'cust.field.starturl', 'cust.field.manifestid', 'cust.field.appid', 'cust.field.windowmode' | Where-Object { -not $s.PSObject.Properties[$_] })
        Test-Check "texts ($lang): every web app text is there" ($miss.Count -eq 0) ($miss -join ', ')
    }
    $type = Get-ThrownText { Initialize-AVDTuneLinkPropertyType }
    Test-Check 'the IPropertyStore helper for the AppUserModelID compiles (it is only used by the real adapter)' ($null -eq $type -and ('AVDTune.Native.LinkAumid' -as [type])) $type
}
finally {
    Close-AVDTuneWriteGate
    Remove-Item Env:\AVDTUNE_ROOT -ErrorAction SilentlyContinue
    if (Test-Path $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
if ($script:failed -gt 0) { throw "$script:failed check(s) failed." }
'Check-WebApp: all checks passed.'
