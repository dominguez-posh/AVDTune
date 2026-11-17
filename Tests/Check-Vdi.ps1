#requires -Version 5.1
<#
.SYNOPSIS
    Checks the VDI components (Modules\AVDTune.Vdi.psm1, issue 56) against the fake machine, the fake component adapter and a temporary state folder: the redirect rules (fixed hosts, every
    hop, final host, no port/user info/query), the signature checks (Teams bootstrapper, MSI without original file name, msiexec, again right before the start, a swap after the first check),
    the file held until the start, install, update, remove and undo behind the write gate with run record, LastChange and change log, every failure path, detection and the pills, the
    registry settings with Test/Apply/Undo (typed undo record, merge of an existing ExtensionSettings policy), OneDrive through winget in the lock, and the Teams update of the Updates
    page that now downloads the bootstrapper. Nothing is downloaded, installed or changed on this computer.
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'Modules\AVDTune.psm1') -Force
foreach ($part in 'Updates', 'Trust', 'Benchmark', 'Office', 'Vdi') { Import-Module (Join-Path $repo "Modules\AVDTune.$part.psm1") -Force }
. (Join-Path $PSScriptRoot 'Fakes\FakeMachine.ps1')
. (Join-Path $PSScriptRoot 'Fakes\FakeVdi.ps1')

$script:failed = 0
function Test-Check([string]$Name, [bool]$Ok, $Detail) { if ($Ok) { "PASS $Name" } else { $script:failed++; "FAIL $Name" + $(if ($null -ne $Detail) { "  -> $Detail" }) } }
function Test-Throws([scriptblock]$Block) { try { & $Block | Out-Null; $false } catch { $true } }
function Get-ThrownText([scriptblock]$Block) { try { & $Block | Out-Null; $null } catch { $_.Exception.Message } }
function Get-Row($Rows, [string]$Id) { @($Rows | Where-Object Id -eq $Id)[0] }
function Get-Log($V, [string]$Pattern) { @($V.Log | Where-Object { $_ -like $Pattern }) }
function New-Env([hashtable]$Seed = @{}, [hashtable]$MSeed = @{}) { $m = New-AVDTuneFakeMachine -Seed $MSeed; @{ M = $m; V = (New-AVDTuneFakeVdi -Machine $m -Seed $Seed) } }

$uni = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
$teamsKey = 'HKLM:\SOFTWARE\Microsoft\Teams'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('avdtune-vdi-' + [guid]::NewGuid().ToString('N'))
try {
    $env:AVDTUNE_ROOT = $tmp
    [void](Initialize-AVDTuneState -Root $tmp)
    [void](Start-AVDTuneImageVersion -Root $tmp -Date ([datetime]'2026-11-15') -User 'admin1')
    function Reset-Files { Get-ChildItem -LiteralPath (Join-Path $tmp 'config') -Filter 'vdi-*.json' -ErrorAction SilentlyContinue | Remove-Item -Force }
    function Open-Gate { Open-AVDTuneWriteGate -SnapshotId 'snap-1' -ConfirmedBy 'admin1' }
    Close-AVDTuneWriteGate

    # ---------------------------------------------------------------- redirect rules (pure)
    $cur = 'https://aka.ms/avdmmr/msi'
    $dl = 'https://download.microsoft.com/download/aaaaaaaa-0000-1111-2222-333333333333/Mmr_1.0.2410.0.msi'
    $n = Get-AVDTuneVdiNextUrl -Current $cur -Location $dl -Kind Msi
    Test-Check 'redirect: aka.ms to download.microsoft.com ends the chain with the file address' ($n.Ok -and $n.Final -and $n.Url -eq $dl) $n.Error
    $n = Get-AVDTuneVdiNextUrl -Current $cur -Location 'https://go.microsoft.com/fwlink/?linkid=1' -Kind Msi
    Test-Check 'redirect: an intermediate hop on go.microsoft.com is followed (not final)' ($n.Ok -and -not $n.Final) $n.Error
    $n = Get-AVDTuneVdiNextUrl -Current 'https://go.microsoft.com/fwlink/?linkid=1' -Location '/download/aaaaaaaa-0000-1111-2222-333333333333/x.msi' -Kind Msi
    Test-Check 'redirect: a relative Location is resolved against the address that was asked (same host, not final)' ($n.Ok -and $n.Url -eq 'https://go.microsoft.com/download/aaaaaaaa-0000-1111-2222-333333333333/x.msi' -and -not $n.Final) "$($n.Url) $($n.Error)"
    $refused = [ordered]@{
        'another host' = 'https://download.microsoft.com.evil.example/download/a/x.msi'; 'look-alike host' = 'https://evil.example/download/a/x.msi'; 'http' = 'http://download.microsoft.com/download/a/x.msi'
        'user info' = ('https://user:pw' + [char]64 + 'download.microsoft.com/download/a/x.msi'); 'port' = 'https://download.microsoft.com:8443/download/a/x.msi'; 'query on the final file' = 'https://download.microsoft.com/download/a/x.msi?sig=1'
        'dots-dots' = 'https://download.microsoft.com/download/a/../../x.msi'; 'wrong extension' = 'https://download.microsoft.com/download/a/x.exe'; 'outside /download/' = 'https://download.microsoft.com/other/x.msi'
        'ftp' = 'ftp://download.microsoft.com/download/a/x.msi'; 'empty' = ''; 'fragment' = 'https://aka.ms/x#y'; 'other microsoft host' = 'https://www.microsoft.com/download/a/x.msi'
    }
    $wrong = @($refused.Keys | Where-Object { (Get-AVDTuneVdiNextUrl -Current $cur -Location $refused[$_] -Kind Msi).Ok })
    Test-Check 'redirect: every other host, scheme, port, user info, query, ".." and a wrong file type is refused' ($wrong.Count -eq 0) ($wrong -join ', ')
    Test-Check 'redirect: the Teams bootstrapper must be an .exe, an MSI must not' ((Get-AVDTuneVdiNextUrl -Current $cur -Location 'https://download.microsoft.com/download/a/teamsbootstrapper.exe' -Kind Exe).Ok -and -not (Get-AVDTuneVdiNextUrl -Current $cur -Location 'https://download.microsoft.com/download/a/teamsbootstrapper.exe' -Kind Msi).Ok) $null
    Test-Check 'links: Test-AVDTuneVdiUrl allows only https on the listed hosts' ((Test-AVDTuneVdiUrl -Url 'https://aka.ms/x') -and -not (Test-AVDTuneVdiUrl -Url 'https://aka.ms/x' -Hosts @('download.microsoft.com')) -and -not (Test-AVDTuneVdiUrl -Url 'https://AKA.ms.evil/x')) $null
    Test-Check 'version from a file name, and comparison' ((Get-AVDTuneVdiVersionFromUrl 'https://download.microsoft.com/download/a/MsRdcWebRTCSvc_HostSetup_1.54.2408.19001_x64.msi') -eq '1.54.2408.19001' -and (Get-AVDTuneVdiVersionFromUrl 'https://download.microsoft.com/download/a/x.msi') -eq '' -and (Compare-AVDTuneVdiVersion '1.54.2408.19001' '1.55.0.10001') -eq -1 -and (Compare-AVDTuneVdiVersion '1.0' 'abc') -eq $null) $null

    # ---------------------------------------------------------------- the signature rules (pure)
    $msSub = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'; $msCa = 'CN=Microsoft Code Signing PCA 2024, O=Microsoft Corporation, C=US'
    $exe = Get-AVDTuneVdiComponent 'teams'; $msi = Get-AVDTuneVdiComponent 'mmr'
    function Sig($Sub, $Iss, $Orig) { [pscustomobject]@{ Valid = $true; Status = 'Valid'; Subject = $Sub; Issuer = $Iss; OriginalFilename = $Orig } }
    $cases = @(
        @{ N = 'exe ok'; C = $exe; S = (Sig $msSub $msCa 'teamsbootstrapper.exe'); Ok = $true }
        @{ N = 'exe other original name'; C = $exe; S = (Sig $msSub $msCa 'cmd.exe'); Ok = $false }
        @{ N = 'exe Evil Ltd'; C = $exe; S = (Sig 'CN=Microsoft Corporation, O=Microsoft Corporation Evil Ltd, C=US' $msCa 'teamsbootstrapper.exe'); Ok = $false }
        @{ N = 'exe not valid'; C = $exe; S = [pscustomobject]@{ Valid = $false; Status = 'NotSigned'; Subject = ''; Issuer = ''; OriginalFilename = '' }; Ok = $false }
        @{ N = 'msi ok (no original file name)'; C = $msi; S = (Sig $msSub $msCa ''); Ok = $true }
        @{ N = 'msi that carries an original file name (an exe renamed)'; C = $msi; S = (Sig $msSub $msCa 'setup.exe'); Ok = $false }
        @{ N = 'msi other signer'; C = $msi; S = (Sig 'CN=Evil, O=Evil, C=US' $msCa ''); Ok = $false }
        @{ N = 'msi issuer not Microsoft'; C = $msi; S = (Sig $msSub 'CN=Evil CA, O=Evil' ''); Ok = $false }
    )
    $wrong = @($cases | Where-Object { (Test-AVDTuneVdiPackageTrust -Signature $_.S -Component $_.C).Ok -ne $_.Ok } | ForEach-Object N)
    Test-Check 'trust: Teams bootstrapper by exact signer and original file name, MSI by exact signer and NO original file name' ($wrong.Count -eq 0) ($wrong -join ', ')
    $win = Sig 'CN=Microsoft Windows, O=Microsoft Corporation, L=Redmond, S=Washington, C=US' 'CN=Microsoft Windows Production PCA 2011, O=Microsoft Corporation, C=US' 'msiexec.exe'
    Test-Check 'trust: msiexec.exe is the Windows file (signer, issuer, original file name)' ((Test-AVDTuneToolTrust -Signature $win -Name 'msiexec.exe').Ok -and -not (Test-AVDTuneToolTrust -Signature (Sig $msSub $msCa 'evil.exe') -Name 'msiexec.exe').Ok) $null
    Test-Check 'MSI header: only an OLE compound file' ((Test-AVDTuneMsiHeader -Bytes ([byte[]](0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1))) -and -not (Test-AVDTuneMsiHeader -Bytes ([byte[]](0x4D, 0x5A, 0, 0, 0, 0, 0, 0))) -and -not (Test-AVDTuneMsiHeader -Bytes ([byte[]]@())) -and -not (Test-AVDTuneMsiHeader -Bytes $null)) $null

    # ---------------------------------------------------------------- ExtensionSettings policy (pure)
    $id = 'joeclbldhdmoijbaagobkhlpfjglcihd'; $url = 'https://edge.microsoft.com/extensionwebstorebase/v1/crx'
    $a = Add-AVDTuneVdiExtensionEntry -Existing '' -ExtensionId $id -UpdateUrl $url
    Test-Check 'policy: an empty ExtensionSettings gets the entry of the Learn article (force_installed, update_url)' ($a.Ok -and (Test-AVDTuneVdiExtensionEntry -Existing $a.Text -ExtensionId $id -UpdateUrl $url) -and $a.Text -match 'force_installed') $a.Text
    $other = '{"*":{"installation_mode":"blocked"},"abcdefghijklmnopabcdefghijklmnop":{"installation_mode":"allowed","toolbar_state":"force_shown"},"' + $id + '":{"runtime_blocked_hosts":["*://*.contoso.example"],"toolbar_state":"default_shown"}}'
    $m2 = Add-AVDTuneVdiExtensionEntry -Existing $other -ExtensionId $id -UpdateUrl $url
    $back = (Get-AVDTuneVdiJsonSerializer).DeserializeObject($m2.Text)
    Test-Check 'policy: other entries and the other fields of our entry stay, ours becomes force_installed' ($m2.Ok -and $back['*']['installation_mode'] -eq 'blocked' -and $back['abcdefghijklmnopabcdefghijklmnop']['toolbar_state'] -eq 'force_shown' -and $back[$id]['runtime_blocked_hosts'][0] -eq '*://*.contoso.example' -and $back[$id]['toolbar_state'] -eq 'default_shown' -and (Test-AVDTuneVdiExtensionEntry -Existing $m2.Text -ExtensionId $id -UpdateUrl $url)) $m2.Text
    Test-Check 'policy: invalid JSON, a JSON array, a blocked or removed extension and a bad id or address are refused, nothing is built' (
        -not (Add-AVDTuneVdiExtensionEntry -Existing '{not json' -ExtensionId $id -UpdateUrl $url).Ok -and -not (Add-AVDTuneVdiExtensionEntry -Existing '[1,2]' -ExtensionId $id -UpdateUrl $url).Ok -and
        -not (Add-AVDTuneVdiExtensionEntry -Existing ('{"' + $id + '":{"installation_mode":"blocked"}}') -ExtensionId $id -UpdateUrl $url).Ok -and -not (Add-AVDTuneVdiExtensionEntry -Existing ('{"' + $id + '":{"installation_mode":"removed"}}') -ExtensionId $id -UpdateUrl $url).Ok -and
        -not (Add-AVDTuneVdiExtensionEntry -Existing '' -ExtensionId 'evil' -UpdateUrl $url).Ok -and -not (Add-AVDTuneVdiExtensionEntry -Existing '' -ExtensionId $id -UpdateUrl 'https://evil.example/crx').Ok -and -not (Add-AVDTuneVdiExtensionEntry -Existing ('{"' + $id + '":"x"}') -ExtensionId $id -UpdateUrl $url).Ok) $null
    Test-Check 'policy: the test needs force_installed AND our update address; "normal_installed" or another address is not compliant' (
        -not (Test-AVDTuneVdiExtensionEntry -Existing ('{"' + $id + '":{"installation_mode":"normal_installed","update_url":"' + $url + '"}}') -ExtensionId $id -UpdateUrl $url) -and
        -not (Test-AVDTuneVdiExtensionEntry -Existing ('{"' + $id + '":{"installation_mode":"force_installed","update_url":"https://other.example/crx"}}') -ExtensionId $id -UpdateUrl $url) -and -not (Test-AVDTuneVdiExtensionEntry -Existing 'nonsense' -ExtensionId $id -UpdateUrl $url) -and -not (Test-AVDTuneVdiExtensionEntry -Existing '' -ExtensionId $id -UpdateUrl $url)) $null

    # ---------------------------------------------------------------- detection and the pills
    $e = New-Env
    $r = Get-AVDTuneVdiRows -Machine $e.M -V $e.V -Key 'teams'
    Test-Check 'rows: nothing installed is red, with the IsWVDEnvironment and auto update rows open (yellow)' ((Get-AVDTuneVdiSummaryStatus $r) -eq 'red' -and (Get-Row $r 'teams.installed').Status -eq 'red' -and (Get-Row $r 'vdi.teams.iswvdenvironment').Status -eq 'yellow' -and (Get-Row $r 'teams.autoupdate').Status -eq 'yellow' -and (Get-Row $r 'teams.autoupdate').Fix -like '*update block*' -and (Get-Row $r 'teams.webrtc').Status -eq 'yellow') ($r | ForEach-Object { "$($_.Id)=$($_.Status)" }) -join ','
    $e = New-Env -Seed @{ Teams = '26000.1.1.0' } -MSeed @{ Registry = @{ 'HKLM:\SOFTWARE\FSLogix\Apps|InstallVersion' = '2.9.8884.27471'; "$teamsKey|IsWVDEnvironment" = 1; "$teamsKey|disableAutoUpdate" = 1; "$uni\{AAAAAAAA-0000-0000-0000-000000000001}|DisplayName" = 'Remote Desktop WebRTC Redirector Service'; "$uni\{AAAAAAAA-0000-0000-0000-000000000001}|DisplayVersion" = '1.54.2408.19001'
            'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64|Installed' = 1; 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64|Major' = 14; 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64|Minor' = 40; 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64|Bld' = 33810 } }
    $r = Get-AVDTuneVdiRows -Machine $e.M -V $e.V -Key 'teams'
    Test-Check 'rows: Teams installed with both values, WebRTC there, VC++ and FSLogix known: no yellow, the installed row is gray (the newest Teams is not readable)' ((Get-Row $r 'teams.installed').Status -eq 'info' -and (Get-Row $r 'teams.webrtc').Status -eq 'green' -and (Get-Row $r 'teams.vcredist').Status -eq 'green' -and (Get-Row $r 'teams.fslogix').Status -eq 'green' -and (Get-Row $r 'vdi.teams.iswvdenvironment').Status -eq 'green' -and (Get-Row $r 'teams.autoupdate').Status -eq 'green' -and (Get-AVDTuneVdiSummaryStatus $r) -eq 'info') ($r | ForEach-Object { "$($_.Id)=$($_.Status)" }) -join ','
    $e.M.Store.Registry['hklm:\software\fslogix\apps|installversion'] = '2.9.7000.1'
    Test-Check 'rows: FSLogix older than 2.9.8716.30241 is yellow for new Teams' ((Get-Row (Get-AVDTuneVdiRows -Machine $e.M -V $e.V -Key 'teams') 'teams.fslogix').Status -eq 'yellow') $null
    $w = Get-AVDTuneVdiRows -Machine $e.M -V $e.V -Key 'webrtc'
    Test-Check 'rows: an MSI component without a lookup is gray ("only known after Check for updates")' ((Get-Row $w 'webrtc.installed').Status -eq 'info' -and (Get-Row $w 'webrtc.installed').Reason -like '*Check for updates*') (Get-Row $w 'webrtc.installed').Reason
    $latest = Get-AVDTuneVdiLatest -V $e.V -Key 'webrtc'
    Test-Check 'latest: the address Microsoft names now, followed by hand, and the version in its file name; nothing downloaded' ($latest.Ok -and $latest.Version -eq '1.54.2408.19001' -and (Get-Log $e.V 'Download*').Count -eq 0 -and (Get-Log $e.V 'Resolve https://aka.ms/msrdcwebrtcsvc/msi').Count -eq 1) $latest.Error
    Test-Check 'rows: installed version equal to the latest is green' ((Get-Row (Get-AVDTuneVdiRows -Machine $e.M -V $e.V -Key 'webrtc' -Latest $latest) 'webrtc.installed').Status -eq 'green') $null
    $newer = [pscustomobject]@{ Ok = $true; Url = 'x'; Version = '1.60.0.10001'; Error = '' }
    $wy = Get-AVDTuneVdiRows -Machine $e.M -V $e.V -Key 'webrtc' -Latest $newer
    Test-Check 'rows: a newer version at Microsoft is yellow with both versions named, and the card is yellow' ((Get-Row $wy 'webrtc.installed').Status -eq 'yellow' -and (Get-Row $wy 'webrtc.installed').Reason -like '*1.54.2408.19001*1.60.0.10001*' -and (Get-AVDTuneVdiSummaryStatus $wy) -eq 'yellow') (Get-Row $wy 'webrtc.installed').Reason
    $e.V.Store.Redirects['https://aka.ms/msrdcwebrtcsvc/msi'] = @{ Ok = $false; Url = ''; Error = 'HTTP 503' }
    Test-Check 'latest: a failing lookup is a gray row, not an error' (-not (Get-AVDTuneVdiLatest -V $e.V -Key 'webrtc').Ok -and (Get-Row (Get-AVDTuneVdiRows -Machine $e.M -V $e.V -Key 'webrtc' -Latest (Get-AVDTuneVdiLatest -V $e.V -Key 'webrtc')) 'webrtc.installed').Status -eq 'info') $null
    $e.V.Store.Redirects['https://aka.ms/msrdcwebrtcsvc/msi'] = @{ Ok = $true; Url = 'https://evil.example/x.msi'; Error = '' }
    Test-Check 'latest: an adapter that hands back an address outside download.microsoft.com is refused' (-not (Get-AVDTuneVdiLatest -V $e.V -Key 'webrtc').Ok) $null
    Test-Check 'latest: not applicable to Teams and OneDrive' (-not (Get-AVDTuneVdiLatest -V $e.V -Key 'teams').Ok -and -not (Get-AVDTuneVdiLatest -V $e.V -Key 'onedrive').Ok) $null
    Test-Check 'an unknown component key throws' (Test-Throws { Get-AVDTuneVdiComponent 'evil' }) $null

    # ---------------------------------------------------------------- install: Teams
    Open-Gate
    $e = New-Env
    $res = Invoke-AVDTuneVdiRecorded -Machine $e.M -V $e.V -Key 'teams' -Root $tmp -Mode Install -User 'admin1' -SnapshotId 'snap-1'
    $log = @($e.V.Log)
    $iHold = [array]::IndexOf($log, ($log | Where-Object { $_ -like 'HoldFile*' } | Select-Object -First 1)); $iRun = [array]::IndexOf($log, ($log | Where-Object { $_ -like 'Run *teamsbootstrapper.exe -p' } | Select-Object -First 1)); $iRel = [array]::IndexOf($log, ($log | Where-Object { $_ -like 'ReleaseFile*' } | Select-Object -First 1))
    Test-Check 'Teams install: resolved by hand, downloaded from download.microsoft.com into a protected folder, held, checked, run with -p, released, folder removed' ($res.Setup.Status -eq 'Changed' -and $res.Setup.After.Version -eq '26000.1.1.0' -and (Get-Log $e.V 'Download https://download.microsoft.com/*teamsbootstrapper.exe').Count -eq 1 -and $iHold -ge 0 -and $iRun -gt $iHold -and $iRel -gt $iRun -and (Get-Log $e.V 'RemoveFolder*').Count -eq 1 -and (Get-Log $e.V 'IsProtectedFolder*').Count -ge 1) ($log -join ' | ')
    $sigIdx = @(for ($i = 0; $i -lt $log.Count; $i++) { if ($log[$i] -like 'VerifySignature teamsbootstrapper.exe') { $i } })
    Test-Check 'Teams install: the signature is checked twice, the second time after the hold and directly before the start' ($sigIdx.Count -eq 2 -and $sigIdx[0] -gt $iHold -and $sigIdx[1] -lt $iRun -and $sigIdx[1] -gt $sigIdx[0]) ($sigIdx -join ',')
    Test-Check 'Teams install: run record, change log entry (category VDI, Added), LastChange set, undo record written' ((@(Get-AVDTuneRun -Root $tmp | Where-Object Plan -like 'VDI Microsoft Teams*install').Count -eq 1) -and ((Get-AVDTuneChangeLog -Root $tmp | Where-Object { $_.Category -eq 'VDI' -and $_.ChangeType -eq 'Added' }) -ne $null) -and (Get-AVDTuneState $tmp).LastChange -and (Test-Path (Join-Path $tmp 'config\vdi-teams-undo.json'))) $null
    $res2 = Invoke-AVDTuneVdiRecorded -Machine $e.M -V $e.V -Key 'teams' -Root $tmp -Mode Install
    Test-Check 'Teams update with the same version: Unchanged ("up to date"), the earlier undo record stays' ($res2.Setup.Status -eq 'Unchanged' -and (Test-Path (Join-Path $tmp 'config\vdi-teams-undo.json'))) $res2.Setup.Message
    $e.V.Store.TeamsVersion = '26100.2.2.0'
    $res3 = Invoke-AVDTuneVdiRecorded -Machine $e.M -V $e.V -Key 'teams' -Root $tmp -Mode Install
    Test-Check 'Teams update to a newer version: Changed, change type Updated, the version before and after' ($res3.Setup.Status -eq 'Changed' -and $res3.Setup.Message -like '*26000.1.1.0*26100.2.2.0*' -and ((Get-AVDTuneChangeLog -Root $tmp | Where-Object { $_.ChangeType -eq 'Updated' }) -ne $null)) $res3.Setup.Message
    $res4 = Invoke-AVDTuneVdiRecorded -Machine $e.M -V $e.V -Key 'teams' -Root $tmp -Mode Remove
    Test-Check 'Teams remove runs -x and the package is gone' ($res4.Setup.Status -eq 'Changed' -and (Get-Log $e.V 'Run *teamsbootstrapper.exe -x').Count -eq 1 -and -not (& $e.V.AppxVersion 'MSTeams')) $res4.Setup.Message
    $dlBefore = (Get-Log $e.V 'Download*').Count
    $res5 = Invoke-AVDTuneVdiRecorded -Machine $e.M -V $e.V -Key 'teams' -Root $tmp -Mode Remove
    Test-Check 'removing what is not there is Unchanged and downloads nothing' ($res5.Setup.Status -eq 'Unchanged' -and (Get-Log $e.V 'Download*').Count -eq $dlBefore) $res5.Setup.Message
    Reset-Files

    # ---------------------------------------------------------------- install: failure paths (nothing started, nothing left)
    $paths = @(
        @{ N = 'redirect refused'; S = @{ Redirects = @{ 'https://go.microsoft.com/fwlink/?linkid=2243204' = @{ Ok = $false; Url = ''; Error = 'The redirect leads to evil' } } }; Code = 'NoLink'; Dl = $false }
        @{ N = 'adapter hands back a foreign address'; S = @{ Redirects = @{ 'https://go.microsoft.com/fwlink/?linkid=2243204' = @{ Ok = $true; Url = 'https://evil.example/teamsbootstrapper.exe'; Error = '' } } }; Code = 'NoLink'; Dl = $false }
        @{ N = 'download folder not protected'; S = @{ Protected = $false }; Code = 'NotProtected'; Dl = $false }
        @{ N = 'download fails'; S = @{ DownloadFails = $true }; Code = 'Download'; Dl = $true }
        @{ N = 'file cannot be held'; S = @{ HoldFails = $true }; Code = 'NoHold'; Dl = $true }
        @{ N = 'file signed by someone else'; S = @{ Signatures = @{ 'teamsbootstrapper.exe' = @{ Valid = $true; Subject = 'CN=Evil Corp, O=Evil Corp, C=US'; Issuer = 'CN=Microsoft Code Signing PCA 2024, O=Microsoft Corporation, C=US' } } }; Code = 'BadSignature'; Dl = $true }
        @{ N = 'file not signed'; S = @{ Signatures = @{ 'teamsbootstrapper.exe' = @{ Valid = $false; Subject = ''; Issuer = '' } } }; Code = 'BadSignature'; Dl = $true }
        @{ N = 'file swapped after the first check'; S = @{ SwapAfterCheck = $true }; Code = 'BadSignature'; Dl = $true }
    )
    foreach ($p in $paths) {
        $e = New-Env -Seed $p.S
        $x = Invoke-AVDTuneVdiRecorded -Machine $e.M -V $e.V -Key 'teams' -Root $tmp -Mode Install
        $dlOk = if ($p.Dl) { (Get-Log $e.V 'Download*').Count -eq 1 } else { (Get-Log $e.V 'Download*').Count -eq 0 }
        Test-Check "Teams install, $($p.N): Failed ($($p.Code)), the program is never started, the folder is removed, the file is not held afterwards" ($x.Setup.Status -eq 'Failed' -and $x.Setup.Code -eq $p.Code -and (Get-Log $e.V 'Run *').Count -eq 0 -and $dlOk -and @($e.V.Store.Held).Count -eq 0 -and ((Get-Log $e.V 'NewTempFolder*').Count -eq (Get-Log $e.V 'RemoveFolder*').Count)) "$($x.Setup.Status) $($x.Setup.Code) $($x.Setup.Message)"
        Reset-Files
    }
    $e = New-Env -Seed @{ Exit = @{ 'teamsbootstrapper.exe' = -2147023728 } }
    $x = Invoke-AVDTuneVdiRecorded -Machine $e.M -V $e.V -Key 'teams' -Root $tmp -Mode Install
    Test-Check 'Teams install: an exit code other than 0 is Failed with the code, change log note, and no Teams' ($x.Setup.Status -eq 'Failed' -and $x.Setup.Code -eq 'Exit-2147023728' -and -not (& $e.V.AppxVersion 'MSTeams') -and ((Get-AVDTuneChangeLog -Root $tmp | Where-Object { $_.ChangeType -eq 'Note' -and $_.Text -like '*FAILED*' }) -ne $null)) $x.Setup.Message
    Reset-Files
    $e = New-Env -Seed @{ NoEffect = $true }
    $x = Invoke-AVDTuneVdiRecorded -Machine $e.M -V $e.V -Key 'teams' -Root $tmp -Mode Install
    Test-Check 'Teams install: the program exits 0 but nothing is found afterwards is Failed (NotRegistered)' ($x.Setup.Status -eq 'Failed' -and $x.Setup.Code -eq 'NotRegistered') $x.Setup.Message
    Reset-Files

    # ---------------------------------------------------------------- install: MSI components
    $e = New-Env
    $x = Invoke-AVDTuneVdiRecorded -Machine $e.M -V $e.V -Key 'webrtc' -Root $tmp -Mode Install -User 'admin1' -SnapshotId 'snap-1'
    $runs = @(Get-Log $e.V 'Run *')
    Test-Check 'WebRTC install: MSI downloaded, header and signature checked, msiexec /i with the full path of the held file, no UI, log in the protected folder' ($x.Setup.Status -eq 'Changed' -and $x.Setup.After.Version -eq '1.54.2408.19001' -and $runs.Count -eq 1 -and $runs[0] -like 'Run C:\fake\System32\msiexec.exe /i C:\fake\temp\vdi-0\webrtc-redirector.msi /qn /norestart /l*v C:\fake\temp\vdi-0\msi.log' -and (Get-Log $e.V 'ReadHeader*').Count -eq 1 -and (Get-Log $e.V 'VerifySignature msiexec.exe').Count -eq 2) ($runs -join ' | ')
    $r = Get-AVDTuneVdiRows -Machine $e.M -V $e.V -Key 'webrtc'
    Test-Check 'WebRTC: the Uninstall entry is detected (version) after the install' ((Get-Row $r 'webrtc.installed').Reason -like '*1.54.2408.19001*') (Get-Row $r 'webrtc.installed').Reason
    $x = Invoke-AVDTuneVdiRecorded -Machine $e.M -V $e.V -Key 'webrtc' -Root $tmp -Mode Remove
    $rm = Get-Log $e.V 'Run *' | Select-Object -Last 1
    Test-Check 'WebRTC remove: msiexec /x with the product code read from the registry, the component is gone' ($x.Setup.Status -eq 'Changed' -and $rm -like 'Run C:\fake\System32\msiexec.exe /x {11111111-1111-1111-1111-111111111111} /qn /norestart*' -and -not (Get-AVDTuneVdiState -Machine $e.M -V $e.V -Key 'webrtc').Installed) $rm
    Reset-Files
    $bad = New-Env -Seed @{ Header = [byte[]](0x4D, 0x5A, 0, 0, 0, 0, 0, 0) }
    $x = Invoke-AVDTuneVdiRecorded -Machine $bad.M -V $bad.V -Key 'webrtc' -Root $tmp -Mode Install
    Test-Check 'MSI install: a file that is no MSI is never started' ($x.Setup.Status -eq 'Failed' -and $x.Setup.Code -eq 'BadPackage' -and (Get-Log $bad.V 'Run *').Count -eq 0) $x.Setup.Message
    Reset-Files
    $bad = New-Env -Seed @{ Signatures = @{ 'webrtc-redirector.msi' = @{ Valid = $true; Subject = $msSub; Issuer = $msCa; OriginalFilename = 'evil.exe' } } }
    $x = Invoke-AVDTuneVdiRecorded -Machine $bad.M -V $bad.V -Key 'webrtc' -Root $tmp -Mode Install
    Test-Check 'MSI install: a file that carries an original file name (an exe) is refused' ($x.Setup.Code -eq 'BadSignature' -and (Get-Log $bad.V 'Run *').Count -eq 0) $x.Setup.Message
    Reset-Files
    $bad = New-Env -Seed @{ Signatures = @{ 'msiexec.exe' = @{ Valid = $true; Subject = 'CN=Evil, O=Evil'; Issuer = 'CN=Evil CA' } } }
    $x = Invoke-AVDTuneVdiRecorded -Machine $bad.M -V $bad.V -Key 'webrtc' -Root $tmp -Mode Install
    Test-Check 'MSI install: an msiexec.exe that is not the Windows file is not started' ($x.Setup.Code -eq 'BadSignature' -and (Get-Log $bad.V 'Run *').Count -eq 0) $x.Setup.Message
    Reset-Files
    $bad = New-Env -Seed @{ Exit = @{ 'webrtc-redirector.msi' = 1618 } }
    $x = Invoke-AVDTuneVdiRecorded -Machine $bad.M -V $bad.V -Key 'webrtc' -Root $tmp -Mode Install
    Test-Check 'MSI install: 1618 says another installation is running' ($x.Setup.Status -eq 'Failed' -and $x.Setup.Message -like '*Another installation*') $x.Setup.Message
    Reset-Files
    $bad = New-Env -Seed @{ Exit = @{ 'webrtc-redirector.msi' = 3010 } }
    $x = Invoke-AVDTuneVdiRecorded -Machine $bad.M -V $bad.V -Key 'webrtc' -Root $tmp -Mode Install
    Test-Check 'MSI install: 3010 is a success that asks for a restart (the result carries Reboot)' ($x.Setup.Status -eq 'Changed' -and $x.Result.Reboot) $x.Setup.Message
    Reset-Files
    $e = New-Env -Seed @{ Running = @('chrome') }
    $before = (Get-AVDTuneState $tmp).LastChange
    $x = Invoke-AVDTuneVdiRecorded -Machine $e.M -V $e.V -Key 'mmr' -Root $tmp -Mode Install
    Test-Check 'MMR install: a running Chrome stops it before anything is downloaded; that is an analysis exit (no LastChange, no undo record)' ($x.Setup.Code -eq 'BrowserRunning' -and (Get-Log $e.V 'Download*').Count -eq 0 -and (Get-Log $e.V 'Resolve*').Count -eq 0 -and (Get-AVDTuneState $tmp).LastChange -eq $before -and -not (Test-Path (Join-Path $tmp 'config\vdi-mmr-undo.json'))) $x.Setup.Message
    $e.V.Store.Running = @()
    $x = Invoke-AVDTuneVdiRecorded -Machine $e.M -V $e.V -Key 'mmr' -Root $tmp -Mode Install
    Test-Check 'MMR install with the browsers closed: installed from aka.ms/avdmmr/msi' ($x.Setup.Status -eq 'Changed' -and (Get-Log $e.V 'Resolve https://aka.ms/avdmmr/msi').Count -eq 1) $x.Setup.Message
    Reset-Files
    $e = New-Env
    $x = Invoke-AVDTuneVdiRecorded -Machine $e.M -V $e.V -Key 'webrtc' -Root $tmp -Mode Remove
    Test-Check 'removing an MSI component that is not installed is Unchanged' ($x.Setup.Status -eq 'Unchanged') $x.Setup.Message
    $e = New-Env -MSeed @{ Registry = @{ "$uni\NoGuidName|DisplayName" = 'Remote Desktop WebRTC Redirector Service'; "$uni\NoGuidName|DisplayVersion" = '1.0' } }
    $x = Invoke-AVDTuneVdiRecorded -Machine $e.M -V $e.V -Key 'webrtc' -Root $tmp -Mode Remove
    Test-Check 'removing: an Uninstall entry whose key is no product code is not passed to msiexec' ($x.Setup.Code -eq 'NoProductCode' -and (Get-Log $e.V 'Run *').Count -eq 0) $x.Setup.Message
    Reset-Files

    # ---------------------------------------------------------------- the gate, LastChange and undo
    Close-AVDTuneWriteGate
    $e = New-Env
    Test-Check 'install: with the gate closed nothing happens (throws before any lookup)' ((Get-ThrownText { Invoke-AVDTuneVdiRecorded -Machine $e.M -V $e.V -Key 'teams' -Root $tmp }) -like '*snapshot gate*' -and $e.V.Log.Count -eq 0) $null
    Test-Check 'settings: with the gate closed nothing is written (but WhatIf works)' ((Get-ThrownText { Invoke-AVDTuneVdiSettings -Machine $e.M -V $e.V -Key 'teams' -Root $tmp }) -like '*snapshot gate*' -and $e.M.Log.Count -eq 0 -and (Invoke-AVDTuneVdiSettings -Machine $e.M -V $e.V -Key 'teams' -Root $tmp -WhatIf).WhatIf) $null
    Open-Gate
    [void](Set-AVDTuneState -Root $tmp -Values @{ LastChange = '2020-01-01T00:00:00.0000000' })
    $e = New-Env -Seed @{ Redirects = @{ 'https://go.microsoft.com/fwlink/?linkid=2243204' = @{ Ok = $false; Url = ''; Error = 'down' } } }
    $x = Invoke-AVDTuneVdiRecorded -Machine $e.M -V $e.V -Key 'teams' -Root $tmp
    Test-Check 'a failure before anything was changed (the address cannot be followed) is Failed and the undo record of this call is removed again' ($x.Setup.Status -eq 'Failed' -and -not (Test-Path (Join-Path $tmp 'config\vdi-teams-undo.json'))) $null
    Reset-Files
    $e = New-Env
    [void](Invoke-AVDTuneVdiRecorded -Machine $e.M -V $e.V -Key 'webrtc' -Root $tmp -User 'admin1' -SnapshotId 'snap-1')
    Test-Check 'undo text names removal when the component was not there' ((Get-AVDTuneVdiUndoText -Root $tmp -Key 'webrtc') -like '*is removed again*') (Get-AVDTuneVdiUndoText -Root $tmp -Key 'webrtc')
    $x = Invoke-AVDTuneVdiUndo -Machine $e.M -V $e.V -Key 'webrtc' -Root $tmp -User 'admin1' -SnapshotId 'snap-1'
    Test-Check 'undo: removes what AVDTune installed, plan "Undo: ...", the undo record is gone' ($x.Setup.Status -eq 'Changed' -and -not (Get-AVDTuneVdiState -Machine $e.M -V $e.V -Key 'webrtc').Installed -and -not (Test-Path (Join-Path $tmp 'config\vdi-webrtc-undo.json')) -and @(Get-AVDTuneRun -Root $tmp | Where-Object Plan -like 'VDI Remote Desktop WebRTC*remove').Count -ge 1) $null
    Test-Check 'undo: nothing recorded is an error' ((Get-ThrownText { Invoke-AVDTuneVdiUndo -Machine $e.M -V $e.V -Key 'webrtc' -Root $tmp }) -like '*nothing to undo*') $null
    $e = New-Env -MSeed @{ Registry = @{ "$uni\{AAAAAAAA-0000-0000-0000-000000000001}|DisplayName" = 'Remote Desktop WebRTC Redirector Service'; "$uni\{AAAAAAAA-0000-0000-0000-000000000001}|DisplayVersion" = '1.0.0.10001' } }
    $e.V.Store.WebrtcVersion = '1.54.2408.19001'
    [void](Invoke-AVDTuneVdiRecorded -Machine $e.M -V $e.V -Key 'webrtc' -Root $tmp)
    Test-Check 'undo: a component that was there before has no undo (older builds are not offered), the text says so and nothing is removed' ((Get-ThrownText { Invoke-AVDTuneVdiUndo -Machine $e.M -V $e.V -Key 'webrtc' -Root $tmp }) -like '*no undo*older builds*' -and (Get-AVDTuneVdiUndoText -Root $tmp -Key 'webrtc') -like '*no undo*' -and (Get-AVDTuneVdiState -Machine $e.M -V $e.V -Key 'webrtc').Installed) $null
    [IO.File]::WriteAllText((Join-Path $tmp 'config\vdi-webrtc-undo.json'), '{"BeforeInstalled":"false"}')
    Test-Check 'undo: a record with "false" as text is refused, nothing is changed' ((Get-ThrownText { Invoke-AVDTuneVdiUndo -Machine $e.M -V $e.V -Key 'webrtc' -Root $tmp }) -like '*not usable*') $null
    Reset-Files

    # ---------------------------------------------------------------- settings
    $e = New-Env
    $dry = Invoke-AVDTuneVdiSettings -Machine $e.M -V $e.V -Key 'teams' -Root $tmp -WhatIf
    Test-Check 'settings: WhatIf names the one Teams value (IsWVDEnvironment; disableAutoUpdate belongs to the update block) and writes nothing, no undo record' (@($dry.Results | Where-Object Status -eq 'WhatIf').Count -eq 1 -and @($e.M.Log | Where-Object { $_ -like 'RegSet*' }).Count -eq 0 -and -not (Test-Path (Join-Path $tmp 'config\vdi-teams-settings-undo.json'))) $null
    $run = Invoke-AVDTuneVdiSettings -Machine $e.M -V $e.V -Key 'teams' -Root $tmp -User 'admin1' -SnapshotId 'snap-1'
    Test-Check 'settings: IsWVDEnvironment is DWORD 1 (Learn), disableAutoUpdate is NOT touched, run record and change log entry (VDI), LastChange set' (@($run.Results | Where-Object Status -eq 'Changed').Count -eq 1 -and (& $e.M.RegGet $teamsKey 'IsWVDEnvironment') -eq 1 -and (& $e.M.RegGetRaw $teamsKey 'IsWVDEnvironment').Kind -eq 'DWord' -and $null -eq (& $e.M.RegGet $teamsKey 'disableAutoUpdate') -and @(Get-AVDTuneChangeLog -Root $tmp | Where-Object { $_.Category -eq 'VDI' -and $_.Text -like '*IsWVDEnvironment*' }).Count -eq 1 -and (Get-AVDTuneState $tmp).LastChange) ($run.Results | ForEach-Object { "$($_.Id)=$($_.Status) $($_.Message)" }) -join ','
    $again = Invoke-AVDTuneVdiSettings -Machine $e.M -V $e.V -Key 'teams' -Root $tmp
    Test-Check 'settings: a second apply changes nothing' (@($again.Results | Where-Object Status -eq 'Unchanged').Count -eq 1) $null
    $und = Invoke-AVDTuneVdiSettings -Machine $e.M -V $e.V -Key 'teams' -Mode Undo -Root $tmp -User 'admin1' -SnapshotId 'snap-1'
    Test-Check 'settings: undo removes the values that were not there before, and the undo record goes away' (@($und.Results | Where-Object Status -eq 'Reverted').Count -eq 1 -and $null -eq (& $e.M.RegGet $teamsKey 'IsWVDEnvironment') -and -not (Test-Path (Join-Path $tmp 'config\vdi-teams-settings-undo.json'))) ($und.Results | ForEach-Object { "$($_.Id)=$($_.Status)" }) -join ','
    $e = New-Env -MSeed @{ Registry = @{ "$teamsKey|IsWVDEnvironment" = 0 } }
    [void](Invoke-AVDTuneVdiSettings -Machine $e.M -V $e.V -Key 'teams' -Root $tmp)
    $first = Get-Content -LiteralPath (Join-Path $tmp 'config\vdi-teams-settings-undo.json') -Raw
    [void](Invoke-AVDTuneVdiSettings -Machine $e.M -V $e.V -Key 'teams' -Root $tmp)
    Test-Check 'settings: a second apply never overwrites the first record (older values stay the way back)' ((Get-Content -LiteralPath (Join-Path $tmp 'config\vdi-teams-settings-undo.json') -Raw) -ceq $first) $first
    [void](Invoke-AVDTuneVdiSettings -Machine $e.M -V $e.V -Key 'teams' -Mode Undo -Root $tmp)
    Test-Check 'settings: undo puts back the earlier value with its type (DWORD 0)' ((& $e.M.RegGet $teamsKey 'IsWVDEnvironment') -eq 0 -and (& $e.M.RegGetRaw $teamsKey 'IsWVDEnvironment').Kind -eq 'DWord') $null
    $runKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
    Reset-Files
    $e3 = New-Env -MSeed @{ Registry = @{ "$runKey|OneDrive" = 'C:\old\OneDrive.exe' } }
    [void](Invoke-AVDTuneVdiSettings -Machine $e3.M -V $e3.V -Key 'onedrive' -Root $tmp); [void](Invoke-AVDTuneVdiSettings -Machine $e3.M -V $e3.V -Key 'onedrive' -Mode Undo -Root $tmp)
    Test-Check 'settings: undo puts back an earlier string value (the Run value of OneDrive)' ((& $e3.M.RegGet $runKey 'OneDrive') -ceq 'C:\old\OneDrive.exe' -and (& $e3.M.RegGetRaw $runKey 'OneDrive').Kind -eq 'String') $null
    Reset-Files
    Test-Check 'settings: undo with no record is an error' ((Get-ThrownText { Invoke-AVDTuneVdiSettings -Machine $e.M -V $e.V -Key 'teams' -Mode Undo -Root $tmp }) -like '*nothing to undo*') $null
    $typed = @{
        'a number as text' = '{"Previous":{"vdi.teams.iswvdenvironment":{"Exists":true,"Type":"DWord","Value":"1"}}}'
        'Exists as text' = '{"Previous":{"vdi.teams.iswvdenvironment":{"Exists":"true","Type":"DWord","Value":1}}}'
        'an unknown value name' = '{"Previous":{"vdi.teams.evil":{"Exists":false}}}'
        'an unknown type' = '{"Previous":{"vdi.teams.iswvdenvironment":{"Exists":true,"Type":"Binary","Value":1}}}'
        'Previous not an object' = '{"Previous":"x"}'
    }
    foreach ($k in $typed.Keys) {
        [IO.File]::WriteAllText((Join-Path $tmp 'config\vdi-teams-settings-undo.json'), $typed[$k])
        $e2 = New-Env -MSeed @{ Registry = @{ "$teamsKey|IsWVDEnvironment" = 1; "$teamsKey|disableAutoUpdate" = 1 } }
        $thrown = Get-ThrownText { Invoke-AVDTuneVdiSettings -Machine $e2.M -V $e2.V -Key 'teams' -Mode Undo -Root $tmp }
        Test-Check "settings undo record, $k : refused, nothing written" ($thrown -like '*not usable*' -and @($e2.M.Log | Where-Object { $_ -like 'RegSet*' -or $_ -like 'RegRemove*' }).Count -eq 0) $thrown
    }
    Reset-Files
    $e = New-Env -MSeed @{ Registry = @{ "$teamsKey|IsWVDEnvironment" = 0 } }; $e.M.Store.Kinds["$teamsKey|IsWVDEnvironment".ToLowerInvariant()] = 'Binary'
    Test-Check 'settings: an earlier value of a type that cannot be put back stops the apply before it writes' ((Get-ThrownText { Invoke-AVDTuneVdiSettings -Machine $e.M -V $e.V -Key 'teams' -Root $tmp }) -like '*cannot put back*' -and @($e.M.Log | Where-Object { $_ -like 'RegSet*' }).Count -eq 0) $null
    $e = New-Env
    Test-Check 'settings: an optional id that does not exist is refused; a component without settings (webrtc) has none' ((Get-ThrownText { Invoke-AVDTuneVdiSettings -Machine $e.M -V $e.V -Key 'onedrive' -Root $tmp -Optional @('vdi.onedrive.evil') }) -like '*not a setting*' -and (Get-ThrownText { Invoke-AVDTuneVdiSettings -Machine $e.M -V $e.V -Key 'webrtc' -Root $tmp }) -like '*no settings*') $null
    # OneDrive: Run key, policy; the optional silent sign-in only when asked
    $run = Invoke-AVDTuneVdiSettings -Machine $e.M -V $e.V -Key 'onedrive' -Root $tmp
    $odRun = & $e.M.RegGet 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' 'OneDrive'
    Test-Check 'OneDrive settings: Run value "<OneDrive.exe> /background" and FilesOnDemandEnabled; SilentAccountConfig is NOT set without asking' ($odRun -ceq '"C:\fake\Program Files\Microsoft OneDrive\OneDrive.exe" /background' -and (& $e.M.RegGet 'HKLM:\SOFTWARE\Policies\Microsoft\OneDrive' 'FilesOnDemandEnabled') -eq 1 -and $null -eq (& $e.M.RegGet 'HKLM:\SOFTWARE\Policies\Microsoft\OneDrive' 'SilentAccountConfig')) $odRun
    $run = Invoke-AVDTuneVdiSettings -Machine $e.M -V $e.V -Key 'onedrive' -Root $tmp -Optional @('vdi.onedrive.silent')
    Test-Check 'OneDrive settings: the optional silent sign-in is set when asked for, and the undo record keeps the first values and adds the new one' ((& $e.M.RegGet 'HKLM:\SOFTWARE\Policies\Microsoft\OneDrive' 'SilentAccountConfig') -eq 1 -and (Get-Content (Join-Path $tmp 'config\vdi-onedrive-settings-undo.json') -Raw) -like '*vdi.onedrive.silent*') $null
    [void](Invoke-AVDTuneVdiSettings -Machine $e.M -V $e.V -Key 'onedrive' -Mode Undo -Root $tmp)
    Test-Check 'OneDrive settings undo: all three values are gone again' ($null -eq (& $e.M.RegGet 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' 'OneDrive') -and $null -eq (& $e.M.RegGet 'HKLM:\SOFTWARE\Policies\Microsoft\OneDrive' 'SilentAccountConfig')) $null
    Reset-Files
    # MMR extension policy through the steps: merge, refuse, undo restores the exact earlier text
    $edge = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
    $e = New-Env -MSeed @{ Registry = @{ "$edge|ExtensionSettings" = $other } }
    $run = Invoke-AVDTuneVdiSettings -Machine $e.M -V $e.V -Key 'mmr' -Root $tmp
    $nowText = [string](& $e.M.RegGet $edge 'ExtensionSettings')
    Test-Check 'MMR policy: an existing ExtensionSettings is merged (the other entries stay), Chrome is not touched without asking' ((Test-AVDTuneVdiExtensionEntry -Existing $nowText -ExtensionId $id -UpdateUrl $url) -and $nowText -like '*abcdefghijklmnopabcdefghijklmnop*' -and $null -eq (& $e.M.RegGet 'HKLM:\SOFTWARE\Policies\Google\Chrome' 'ExtensionSettings')) $nowText
    [void](Invoke-AVDTuneVdiSettings -Machine $e.M -V $e.V -Key 'mmr' -Mode Undo -Root $tmp)
    Test-Check 'MMR policy undo: the exact earlier text is back' ((& $e.M.RegGet $edge 'ExtensionSettings') -ceq $other) $null
    Reset-Files
    $e = New-Env -MSeed @{ Registry = @{ "$edge|ExtensionSettings" = '{broken' } }
    $run = Invoke-AVDTuneVdiSettings -Machine $e.M -V $e.V -Key 'mmr' -Root $tmp
    Test-Check 'MMR policy: a broken existing policy is not overwritten (step Failed with the reason, value untouched, change log note)' (@($run.Results | Where-Object Status -eq 'Failed').Count -eq 1 -and (& $e.M.RegGet $edge 'ExtensionSettings') -ceq '{broken' -and @(Get-AVDTuneChangeLog -Root $tmp | Where-Object { $_.ChangeType -eq 'Note' -and $_.Text -like '*not valid JSON*' }).Count -ge 1) ($run.Results | ForEach-Object Message) -join ','
    Reset-Files
    $e = New-Env
    $run = Invoke-AVDTuneVdiSettings -Machine $e.M -V $e.V -Key 'mmr' -Root $tmp -Optional @('vdi.mmr.chrome')
    Test-Check 'MMR policy: Chrome with its own extension id and update address when asked for' ((Test-AVDTuneVdiExtensionEntry -Existing ([string](& $e.M.RegGet 'HKLM:\SOFTWARE\Policies\Google\Chrome' 'ExtensionSettings')) -ExtensionId 'lfmemoeeciijgkjkgbgikoonlkabmlno' -UpdateUrl 'https://clients2.google.com/service/update2/crx')) $null
    Reset-Files

    # ---------------------------------------------------------------- review findings (M1, N1, N2, N3)
    # M1: undo of the ExtensionSettings policy only at our own entry
    $foreign = 'zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz'
    $e = New-Env -MSeed @{ Registry = @{ "$edge|ExtensionSettings" = $other } }
    [void](Invoke-AVDTuneVdiSettings -Machine $e.M -V $e.V -Key 'mmr' -Root $tmp)
    $mid = (Get-AVDTuneVdiJsonSerializer).DeserializeObject([string](& $e.M.RegGet $edge 'ExtensionSettings')); $mid[$foreign] = @{ installation_mode = 'force_installed' }
    & $e.M.RegSet $edge 'ExtensionSettings' ((Get-AVDTuneVdiJsonSerializer).Serialize($mid)) 'String'
    $ur = Invoke-AVDTuneVdiSettings -Machine $e.M -V $e.V -Key 'mmr' -Mode Undo -Root $tmp
    $after = (Get-AVDTuneVdiJsonSerializer).DeserializeObject([string](& $e.M.RegGet $edge 'ExtensionSettings'))
    Test-Check 'MMR policy undo: an entry that came after the apply stays, our entry goes back to its earlier fields, the others are untouched' (@($ur.Results | Where-Object Status -eq 'Reverted').Count -eq 1 -and @($after.Keys) -ccontains $foreign -and @($after.Keys) -ccontains 'abcdefghijklmnopabcdefghijklmnop' -and $after['*']['installation_mode'] -eq 'blocked' -and $after[$id]['toolbar_state'] -eq 'default_shown' -and -not ($after[$id].ContainsKey('installation_mode'))) ((& $e.M.RegGet $edge 'ExtensionSettings'))
    Reset-Files
    $e = New-Env
    [void](Invoke-AVDTuneVdiSettings -Machine $e.M -V $e.V -Key 'mmr' -Root $tmp)
    $mid = (Get-AVDTuneVdiJsonSerializer).DeserializeObject([string](& $e.M.RegGet $edge 'ExtensionSettings')); $mid[$foreign] = @{ installation_mode = 'allowed' }
    & $e.M.RegSet $edge 'ExtensionSettings' ((Get-AVDTuneVdiJsonSerializer).Serialize($mid)) 'String'
    [void](Invoke-AVDTuneVdiSettings -Machine $e.M -V $e.V -Key 'mmr' -Mode Undo -Root $tmp)
    $after = (Get-AVDTuneVdiJsonSerializer).DeserializeObject([string](& $e.M.RegGet $edge 'ExtensionSettings'))
    Test-Check 'MMR policy undo: the value did not exist before and a foreign entry was added: the value stays with the foreign entry only (not deleted)' (@($after.Keys).Count -eq 1 -and @($after.Keys) -ccontains $foreign) ((& $e.M.RegGet $edge 'ExtensionSettings'))
    Reset-Files
    $e = New-Env
    [void](Invoke-AVDTuneVdiSettings -Machine $e.M -V $e.V -Key 'mmr' -Root $tmp)
    [void](Invoke-AVDTuneVdiSettings -Machine $e.M -V $e.V -Key 'mmr' -Mode Undo -Root $tmp)
    Test-Check 'MMR policy undo: the value did not exist before and only our entry is left: the value is removed' ($null -eq (& $e.M.RegGet $edge 'ExtensionSettings')) $null
    Reset-Files
    $e = New-Env
    [void](Invoke-AVDTuneVdiSettings -Machine $e.M -V $e.V -Key 'mmr' -Root $tmp)
    & $e.M.RegSet $edge 'ExtensionSettings' '{broken' 'String'
    $logN = $e.M.Log.Count
    $ur = Invoke-AVDTuneVdiSettings -Machine $e.M -V $e.V -Key 'mmr' -Mode Undo -Root $tmp
    Test-Check 'MMR policy undo: invalid JSON now changes nothing and the step is Failed with the reason' (@($ur.Results | Where-Object Status -eq 'Failed').Count -eq 1 -and (& $e.M.RegGet $edge 'ExtensionSettings') -ceq '{broken' -and @($e.M.Log | Select-Object -Skip $logN | Where-Object { $_ -like 'RegSet*' -or $_ -like 'RegRemove*' }).Count -eq 0) (@($ur.Results | ForEach-Object Message) -join ',')
    Reset-Files

    # N1: the Property table of the held MSI is pinned per component
    $webC = Get-AVDTuneVdiComponent 'webrtc'
    $okP = @{ ProductName = 'Remote Desktop WebRTC Redirector Service'; Manufacturer = 'Microsoft Corporation'; ProductVersion = '1.54.2408.19001' }
    function With-Prop([hashtable]$Over) { $h = @{}; foreach ($k in $okP.Keys) { $h[$k] = $okP[$k] }; foreach ($k in $Over.Keys) { $h[$k] = $Over[$k] }; $h }
    $pc = @(
        @{ N = 'right product'; P = $okP; I = ''; Ok = $true }
        @{ N = 'the MMR product for the WebRTC component'; P = (With-Prop @{ ProductName = 'Remote Desktop Multimedia Redirection Service' }); I = ''; Ok = $false }
        @{ N = 'other manufacturer'; P = (With-Prop @{ Manufacturer = 'Evil Corp' }); I = ''; Ok = $false }
        @{ N = 'lower case product name'; P = (With-Prop @{ ProductName = 'remote desktop webrtc redirector service' }); I = ''; Ok = $false }
        @{ N = 'older than installed'; P = (With-Prop @{ ProductVersion = '1.40.0.10001' }); I = '1.54.2408.19001'; Ok = $false }
        @{ N = 'same as installed'; P = $okP; I = '1.54.2408.19001'; Ok = $true }
        @{ N = 'version not readable while something is installed'; P = (With-Prop @{ ProductVersion = 'x' }); I = '1.0.0.10001'; Ok = $false }
        @{ N = 'no properties'; P = $null; I = ''; Ok = $false }
        @{ N = 'same version, installed one written with 3 parts'; P = (With-Prop @{ ProductVersion = '1.54.2408.0' }); I = '1.54.2408'; Ok = $true }
        @{ N = 'newer, installed one with 3 parts'; P = (With-Prop @{ ProductVersion = '1.54.2409.0' }); I = '1.54.2408'; Ok = $true }
    )
    $wrong = @($pc | Where-Object { (Test-AVDTuneMsiIdentity -Properties $_.P -Component $webC -Installed ([bool]$_.I) -InstalledVersion ([string]$_.I)).Ok -ne $_.Ok } | ForEach-Object N)
    Test-Check 'MSI identity: product name and manufacturer exact per component, nothing older than installed' ($wrong.Count -eq 0) ($wrong -join ', ')
    $e = New-Env -Seed @{ MsiProps = @{ 'webrtc-redirector.msi' = @{ ProductName = 'Remote Desktop Multimedia Redirection Service'; Manufacturer = 'Microsoft Corporation'; ProductVersion = '1.0.2410.0' } } }
    $x = Invoke-AVDTuneVdiRecorded -Machine $e.M -V $e.V -Key 'webrtc' -Root $tmp
    Test-Check 'WebRTC install with the MMR MSI behind the address: refused, never started, folder removed, the file is released' ($x.Setup.Code -eq 'BadPackage' -and (Get-Log $e.V 'Run *').Count -eq 0 -and (Get-Log $e.V 'RemoveFolder*').Count -eq 1 -and @($e.V.Store.Held).Count -eq 0) $x.Setup.Message
    Reset-Files
    $e = New-Env -MSeed @{ Registry = @{ "$uni\{AAAAAAAA-0000-0000-0000-000000000001}|DisplayName" = 'Remote Desktop WebRTC Redirector Service'; "$uni\{AAAAAAAA-0000-0000-0000-000000000001}|DisplayVersion" = '1.99.0.10001' } }
    $x = Invoke-AVDTuneVdiRecorded -Machine $e.M -V $e.V -Key 'webrtc' -Root $tmp
    Test-Check 'WebRTC install of an older MSI than the installed version: Downgrade, never started, no undo record left by this call' ($x.Setup.Code -eq 'Downgrade' -and (Get-Log $e.V 'Run *').Count -eq 0 -and -not (Test-Path (Join-Path $tmp 'config\vdi-webrtc-undo.json'))) $x.Setup.Message
    Reset-Files
    Test-Check 'MSI identity: installed but with an empty version is refused (no downgrade check can be made), not installed with an empty version is fine' (-not (Test-AVDTuneMsiIdentity -Properties $okP -Component $webC -Installed $true -InstalledVersion '').Ok -and (Test-AVDTuneMsiIdentity -Properties $okP -Component $webC -Installed $false -InstalledVersion '').Ok) $null
    $e = New-Env -MSeed @{ Registry = @{ "$uni\{11111111-1111-1111-1111-111111111111}|DisplayName" = 'Remote Desktop WebRTC Redirector Service' } }
    $x = Invoke-AVDTuneVdiRecorded -Machine $e.M -V $e.V -Key 'webrtc' -Root $tmp
    Test-Check 'WebRTC install over an entry without DisplayVersion: refused, never started' ($x.Setup.Code -eq 'BadPackage' -and (Get-Log $e.V 'Run *').Count -eq 0) $x.Setup.Message
    Reset-Files
    Test-Check 'version compare: 3 and 4 parts are padded to 4 (1.2.3 equals 1.2.3000.0, 1.2.3 is lower than 1.2.3000.1, 1.2 equals 1.2000.0.0)' ((Compare-AVDTuneVdiVersion '1.2.3000' '1.2.3000.0') -eq 0 -and (Compare-AVDTuneVdiVersion '1.2.3000.0' '1.2.3000') -eq 0 -and (Compare-AVDTuneVdiVersion '1.2.3000' '1.2.3000.1') -eq -1 -and (Compare-AVDTuneVdiVersion '1.2000' '1.2000.0.0') -eq 0 -and (Compare-AVDTuneVdiVersion '2.0.0' '1.999.9.9') -eq 1) $null
    $e = New-Env -Seed @{ MsiProps = @{ 'webrtc-redirector.msi' = $null } }
    Test-Check 'WebRTC install: a Property table that cannot be read is refused' ((Invoke-AVDTuneVdiRecorded -Machine $e.M -V $e.V -Key 'webrtc' -Root $tmp).Setup.Code -eq 'BadPackage' -and (Get-Log $e.V 'Run *').Count -eq 0) $null
    Reset-Files

    # N2: removing an MSI component needs no download, no hold and no resolve
    $e = New-Env
    [void](Invoke-AVDTuneVdiRecorded -Machine $e.M -V $e.V -Key 'mmr' -Root $tmp)
    $logN = $e.V.Log.Count
    $x = Invoke-AVDTuneVdiRecorded -Machine $e.M -V $e.V -Key 'mmr' -Root $tmp -Mode Remove
    $new = @($e.V.Log | Select-Object -Skip $logN)
    Test-Check 'MMR remove: only msiexec.exe is checked and started with /x; no resolve, folder, download, header or hold' ($x.Setup.Status -eq 'Changed' -and @($new | Where-Object { $_ -like 'Resolve*' -or $_ -like 'NewTempFolder*' -or $_ -like 'Download*' -or $_ -like 'ReadHeader*' -or $_ -like 'HoldFile*' -or $_ -like 'ReadMsiProperties*' }).Count -eq 0 -and @($new | Where-Object { $_ -like 'Run C:\fake\System32\msiexec.exe /x {22222222-2222-2222-2222-222222222222} /qn /norestart' }).Count -eq 1 -and @($new | Where-Object { $_ -eq 'VerifySignature msiexec.exe' }).Count -eq 2) ($new -join ' | ')
    Reset-Files
    $e = New-Env
    [void](Invoke-AVDTuneVdiRecorded -Machine $e.M -V $e.V -Key 'mmr' -Root $tmp)
    $e.V.Store.Signatures = @{ 'msiexec.exe' = @{ Valid = $true; Subject = 'CN=Evil, O=Evil'; Issuer = 'CN=Evil CA' } }
    $logN = $e.V.Log.Count
    $x = Invoke-AVDTuneVdiRecorded -Machine $e.M -V $e.V -Key 'mmr' -Root $tmp -Mode Remove
    Test-Check 'MMR remove: an msiexec.exe that is not the Windows file is not started' ($x.Setup.Code -eq 'BadSignature' -and @($e.V.Log | Select-Object -Skip $logN | Where-Object { $_ -like 'Run *' }).Count -eq 0) $x.Setup.Message
    Reset-Files

    # N3: after a timeout the folder is kept (the installation can still run in the Windows Installer service)
    $e = New-Env -Seed @{ Exit = @{ 'webrtc-redirector.msi' = -1 } }
    $x = Invoke-AVDTuneVdiRecorded -Machine $e.M -V $e.V -Key 'webrtc' -Root $tmp
    Test-Check 'MSI install: a timeout keeps the folder (no RemoveFolder), releases the file, says the install can still run, and counts as a change (LastChange, undo record stay)' ($x.Setup.Status -eq 'Failed' -and $x.Setup.Code -eq 'Timeout' -and (Get-Log $e.V 'RemoveFolder*').Count -eq 0 -and @($e.V.Store.Held).Count -eq 0 -and $x.Setup.Message -like '*can still be running*C:\fake\temp\vdi-0*' -and (Test-Path (Join-Path $tmp 'config\vdi-webrtc-undo.json'))) $x.Setup.Message
    Reset-Files
    $e = New-Env -Seed @{ Exit = @{ 'teamsbootstrapper.exe' = -1 } }
    $x = Invoke-AVDTuneVdiRecorded -Machine $e.M -V $e.V -Key 'teams' -Root $tmp
    Test-Check 'Teams install: a timeout keeps the folder as well' ($x.Setup.Code -eq 'Timeout' -and (Get-Log $e.V 'RemoveFolder*').Count -eq 0) $x.Setup.Message
    Reset-Files
    Test-Check 'no tab characters in the Updates module comments (N5)' ((Get-Content -LiteralPath (Join-Path $repo 'Modules\AVDTune.Updates.psm1') -Raw) -notmatch "`t") $null

    # ---------------------------------------------------------------- OneDrive per machine through winget
    $e = New-Env
    $x = Invoke-AVDTuneVdiRecorded -Machine $e.M -V $e.V -Key 'onedrive' -Root $tmp -User 'admin1' -SnapshotId 'snap-1'
    $ul = @($e.V.U.Log)
    $iLock = [array]::IndexOf($ul, 'LockEnter'); $iRun = [array]::IndexOf($ul, ($ul | Where-Object { $_ -like 'Run *winget.exe install *' } | Select-Object -First 1)); $iExit = [array]::IndexOf($ul, 'LockExit')
    Test-Check 'OneDrive install: winget install with machine scope, exact id, inside the lock (enter before, exit after), per machine afterwards' ($x.Setup.Status -eq 'Changed' -and $iLock -ge 0 -and $iRun -gt $iLock -and $iExit -gt $iRun -and ($ul -join '|') -like '*--id Microsoft.OneDrive --exact --scope machine*' -and $x.Setup.After.PerMachine) ($ul -join ' | ')
    $e.V.Store.Exit['winget'] = 1
    $x = Invoke-AVDTuneVdiRecorded -Machine $e.M -V $e.V -Key 'onedrive' -Root $tmp -Mode Remove
    Test-Check 'OneDrive remove: winget failing is Failed and OneDrive is still there' ($x.Setup.Status -eq 'Failed' -and (Get-AVDTuneVdiState -Machine $e.M -V $e.V -Key 'onedrive').Installed) $x.Setup.Message
    $e.V.Store.Exit.Remove('winget')
    $x = Invoke-AVDTuneVdiRecorded -Machine $e.M -V $e.V -Key 'onedrive' -Root $tmp -Mode Remove
    Test-Check 'OneDrive remove: winget uninstall with machine scope removes it' ($x.Setup.Status -eq 'Changed' -and (Get-Log $e.V.U 'Run *winget.exe uninstall --id Microsoft.OneDrive --exact --scope machine*').Count -ge 1 -and -not (Get-AVDTuneVdiState -Machine $e.M -V $e.V -Key 'onedrive').Installed) $x.Setup.Message
    Reset-Files
    $e = New-Env; $e.V.U.Store.LockError = 'the lock is held'
    $x = Invoke-AVDTuneVdiRecorded -Machine $e.M -V $e.V -Key 'onedrive' -Root $tmp
    Test-Check 'OneDrive install: a held lock stops it before winget runs' ($x.Setup.Code -eq 'Lock' -and (Get-Log $e.V.U 'Run *winget*install*').Count -eq 0) $x.Setup.Message
    Reset-Files
    $e = New-Env; $e.V.U.Store.Tools = @('choco.exe')
    Test-Check 'OneDrive install: no winget is ToolMissing' ((Invoke-AVDTuneVdiRecorded -Machine $e.M -V $e.V -Key 'onedrive' -Root $tmp).Setup.Code -eq 'ToolMissing') $null
    Reset-Files
    $e = New-Env; $e.V.U.Store.Signatures = @{ 'winget.exe' = @{ Valid = $true; Subject = 'CN=Someone, O=Someone'; Issuer = 'CN=Someone CA' } }
    $x = Invoke-AVDTuneVdiRecorded -Machine $e.M -V $e.V -Key 'onedrive' -Root $tmp
    Test-Check 'OneDrive install: a winget.exe that is not signed by Microsoft is not started' ($x.Setup.Status -eq 'Failed' -and (Get-Log $e.V.U 'Run *winget*').Count -eq 0) $x.Setup.Message
    Reset-Files
    $e = New-Env; $e.V.Store.NoEffect = $true
    Test-Check 'OneDrive install: winget exits 0 but OneDrive is not in Program Files is Failed' ((Invoke-AVDTuneVdiRecorded -Machine $e.M -V $e.V -Key 'onedrive' -Root $tmp).Setup.Code -eq 'NotRegistered') $null
    Reset-Files

    # ---------------------------------------------------------------- the Teams update of the Updates page downloads the bootstrapper (#59)
    function New-UpdEnv([bool]$WithVdi) {
        $ms = New-AVDTuneFakeMachine
        $vd = New-AVDTuneFakeVdi -Machine $ms -Seed @{ Teams = '25000.1.1.0' }
        $seed = @{ Tools = @('winget.exe', 'choco.exe'); Appx = @{ MSTeams = '25000.1.1.0' } }
        if ($WithVdi) { $seed.Vdi = $vd }
        @{ M = $ms; V = $vd; U = (New-AVDTuneFakeUpdates -Seed $seed) }
    }
    $u1 = New-UpdEnv $true
    $r1 = Invoke-AVDTuneUpdateRun -Machine $u1.M -U $u1.U -Root $tmp -Items @([pscustomobject]@{ Id = 'teams'; Group = 'Teams'; Title = 'Teams'; Installed = '25000.1.1.0'; Kb = ''; Selectable = $true }) -User 'admin1'
    Test-Check 'Updates page: a missing teamsbootstrapper.exe is downloaded (fixed host, signature, held file) and Teams is updated instead of ToolMissing' ($r1.Results[-1].Status -eq 'Changed' -and (Get-Log $u1.V 'Download https://download.microsoft.com/*teamsbootstrapper.exe').Count -eq 1 -and (Get-Log $u1.V 'Run *teamsbootstrapper.exe -p').Count -eq 1 -and (& $u1.V.AppxVersion 'MSTeams') -eq '26000.1.1.0') ($r1.Results[-1] | ConvertTo-Json -Compress)
    $u2 = New-UpdEnv $true; $u2.V.Store.Signatures = @{ 'teamsbootstrapper.exe' = @{ Valid = $true; Subject = 'CN=Evil Corp, O=Evil Corp, C=US'; Issuer = $msCa } }
    $r2 = Invoke-AVDTuneUpdateRun -Machine $u2.M -U $u2.U -Root $tmp -Items @([pscustomobject]@{ Id = 'teams'; Group = 'Teams'; Title = 'Teams'; Installed = '1'; Kb = ''; Selectable = $true }) -User 'admin1'
    Test-Check 'Updates page: a downloaded bootstrapper with the wrong signer is never run' ($r2.Results[-1].Status -eq 'Failed' -and (Get-Log $u2.V 'Run *').Count -eq 0) ($r2.Results[-1] | ConvertTo-Json -Compress)
    $u3 = New-UpdEnv $false
    $r3 = Invoke-AVDTuneUpdateRun -Machine $u3.M -U $u3.U -Root $tmp -Items @([pscustomobject]@{ Id = 'teams'; Group = 'Teams'; Title = 'Teams'; Installed = '1'; Kb = ''; Selectable = $true }) -User 'admin1'
    Test-Check 'Updates page: without the component adapter the old message stays (ToolMissing)' ($r3.Results[-1].Status -eq 'Failed' -and $r3.Results[-1].Code -eq 'ToolMissing') ($r3.Results[-1] | ConvertTo-Json -Compress)

    # ---------------------------------------------------------------- session host cards (issue 77): RDP Shortpath, time zone redirection, Defender for Endpoint
    $tsp = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
    $atp = 'HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection'
    $startup = Join-Path (Get-AVDTuneSystemFolder System) 'GroupPolicy\Machine\Scripts\Startup'
    function Get-HostRows($E, [string]$Key) { @(Get-AVDTuneVdiHostRows -Machine $E.M -V $E.V -Key $Key) }
    function Get-Writes($E) { @($E.M.Log | Where-Object { $_ -like 'RegSet*' -or $_ -like 'RegRemove*' }) }
    Test-Check 'host cards: shortpath, timezone, mde in this order; only Shortpath has a setting, time zone and Defender are status only' (((Get-AVDTuneVdiHostCards | ForEach-Object Key) -join ',') -eq 'shortpath,timezone,mde' -and @(Get-AVDTuneVdiHostSettingDefs -Key 'shortpath').Count -eq 1 -and @(Get-AVDTuneVdiHostSettingDefs -Key 'timezone').Count -eq 0 -and @(Get-AVDTuneVdiHostSettingDefs -Key 'mde').Count -eq 0 -and (Test-Throws { Get-AVDTuneVdiHostCard 'teams' })) $null
    $portCases = [ordered]@{ '3390' = $true; '3000-4000' = $true; '80, 3390' = $true; '*' = $true; 'Any' = $true; '3391' = $false; '' = $false; '4000-3000' = $false; 'abc' = $false; '33900' = $false; '1-3389,3391-9999' = $false }
    $wrong = @($portCases.Keys | Where-Object { (Test-AVDTuneVdiPortList -List $_ -Port 3390) -ne $portCases[$_] })
    Test-Check 'firewall port list: single port, range, list, any; other ports, inverted ranges and text are not the port' ($wrong.Count -eq 0) ($wrong -join ' | ')

    # Shortpath (read only rows)
    $e = New-Env
    $rows = Get-HostRows $e 'shortpath'
    Test-Check 'Shortpath: default master (no policy, no listener, no rule): UDP green, managed networks and port info (optional), public networks info, pill green, nothing written' ((Get-Row $rows 'shortpath.udp').Status -eq 'green' -and (Get-Row $rows 'shortpath.managed').Status -eq 'info' -and (Get-Row $rows 'shortpath.firewall').Status -eq 'info' -and (Get-Row $rows 'shortpath.public').Status -eq 'info' -and (Get-Row $rows 'shortpath.public').Reason -like '*51.5.0.0/16*3478*' -and (Get-AVDTuneVdiHostSummary $rows) -eq 'green' -and (Get-Writes $e).Count -eq 0 -and (Get-Log $e.V 'UdpListener 3390').Count -eq 1) (($rows | ForEach-Object { "$($_.Id)=$($_.Status)" }) -join ',')
    $e = New-Env -MSeed @{ Registry = @{ "$tsp|SelectTransport" = 1 } }
    $rows = Get-HostRows $e 'shortpath'
    Test-Check 'Shortpath: SelectTransport = 1 (Use only TCP) is yellow with the fix, the pill yellow' ((Get-Row $rows 'shortpath.udp').Status -eq 'yellow' -and (Get-Row $rows 'shortpath.udp').Fix -like '*Set recommended settings*' -and (Get-AVDTuneVdiHostSummary $rows) -eq 'yellow') $null
    $e = New-Env -MSeed @{ Registry = @{ "$tsp|SelectTransport" = 2 } }
    Test-Check 'Shortpath: SelectTransport = 2 (UDP or TCP) is green; an undescribed value is info' ((Get-Row (Get-HostRows $e 'shortpath') 'shortpath.udp').Status -eq 'green' -and (Get-Row (Get-HostRows (New-Env -MSeed @{ Registry = @{ "$tsp|SelectTransport" = 7 } }) 'shortpath') 'shortpath.udp').Status -eq 'info') $null
    $e = New-Env -Seed @{ UdpListening = $true; FirewallUdp = $false }
    $rows = Get-HostRows $e 'shortpath'
    Test-Check 'Shortpath: listener on but no inbound rule for UDP 3390 is yellow (Learn: allow the port inbound)' ((Get-Row $rows 'shortpath.managed').Status -eq 'green' -and (Get-Row $rows 'shortpath.firewall').Status -eq 'yellow' -and (Get-AVDTuneVdiHostSummary $rows) -eq 'yellow') $null
    $e = New-Env -Seed @{ UdpListening = $true; FirewallUdp = $true }
    $rows = Get-HostRows $e 'shortpath'
    Test-Check 'Shortpath: listener and inbound rule are green' ((Get-Row $rows 'shortpath.firewall').Status -eq 'green' -and (Get-AVDTuneVdiHostSummary $rows) -eq 'green') $null
    $e = New-Env -Seed @{ UdpListening = $null; FirewallUdp = $null; TeredoType = $null }
    $rows = Get-HostRows $e 'shortpath'
    Test-Check 'Shortpath: probes that cannot be read are info "could not be read", never green' ((Get-Row $rows 'shortpath.managed').Reason -like '*could not be read*' -and (Get-Row $rows 'shortpath.firewall').Status -eq 'info' -and (Get-Row $rows 'shortpath.firewall').Reason -like '*could not be read*' -and (Get-Row $rows 'shortpath.teredo').Reason -like '*could not be read*') $null
    $e = New-Env; $e.V.UdpListener = { throw 'boom' }
    Test-Check 'Shortpath: a probe that throws is "could not be read" (the test does not fail)' ((Get-Row (Get-HostRows $e 'shortpath') 'shortpath.managed').Reason -like '*could not be read*') $null

    # time zone (read only; the Optimization page owns the value)
    $e = New-Env -MSeed @{ Registry = @{ "$tsp|fEnableTimeZoneRedirection" = 1; 'HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation|TimeZoneKeyName' = 'W. Europe Standard Time' } }
    $rows = Get-HostRows $e 'timezone'
    Test-Check 'time zone: fEnableTimeZoneRedirection = 1 is green, the time zone of the master is shown, pill green' ((Get-Row $rows 'timezone.redirect').Status -eq 'green' -and (Get-Row $rows 'timezone.host').Reason -like 'W. Europe Standard Time*' -and (Get-AVDTuneVdiHostSummary $rows) -eq 'green') $null
    $e = New-Env
    $rows = Get-HostRows $e 'timezone'
    Test-Check 'time zone: off is yellow and the fix names the Optimization page (owner of the value and its undo); the card has no setting and Invoke refuses' ((Get-Row $rows 'timezone.redirect').Status -eq 'yellow' -and (Get-Row $rows 'timezone.redirect').Fix -like '*Optimization page*' -and (Get-ThrownText { Invoke-AVDTuneVdiHostSettings -Machine $e.M -Key 'timezone' -Root $tmp -WhatIf }) -like '*only shows the state*' -and (Get-Writes $e).Count -eq 0) $null
    Test-Check 'time zone: the Optimization data still has the entry the card points to (optimization.timezone-redirection, fEnableTimeZoneRedirection = 1)' ((Get-Content -LiteralPath (Join-Path $repo 'data\optimization.json') -Raw) -match '"Id":\s+"optimization\.timezone-redirection"[\s\S]{0,900}?"Name":\s+"fEnableTimeZoneRedirection"[\s\S]{0,120}?"Value":\s+1') $null

    # Defender for Endpoint (status only)
    $e = New-Env -MSeed @{ Registry = @{ "$atp|senseGuid" = '11111111-2222-3333-4444-555555555555' }; Services = @(@{ Name = 'Sense'; Status = 'Running' }) }
    $rows = Get-HostRows $e 'mde'
    Test-Check 'Defender: a master with senseGuid is red (clones carry the same id), pill red, nothing written' ((Get-Row $rows 'mde.master').Status -eq 'red' -and (Get-Row $rows 'mde.master').Fix -like '*Offboard*' -and (Get-AVDTuneVdiHostSummary $rows) -eq 'red' -and (Get-Writes $e).Count -eq 0) $null
    $e = New-Env -MSeed @{ Registry = @{ "$atp\Status|OnboardingState" = 1 }; Services = @(@{ Name = 'Sense'; Status = 'Running' }) }
    Test-Check 'Defender: OnboardingState = 1 is red as well' ((Get-Row (Get-HostRows $e 'mde') 'mde.master').Status -eq 'red') $null
    $e = New-Env -MSeed @{ Services = @(@{ Name = 'Sense'; Status = 'Running' }) }
    Test-Check 'Defender: Sense running without onboarding data is yellow (onboarding right now?)' ((Get-Row (Get-HostRows $e 'mde') 'mde.master').Status -eq 'yellow') $null
    $e = New-Env -MSeed @{ Services = @(@{ Name = 'Sense'; Status = 'Stopped'; StartType = 'Manual' }) }
    $rows = Get-HostRows $e 'mde'
    Test-Check 'Defender: not onboarded and Sense stopped is green, Sense shown as info, no script is info, the device tag is info (legacy MMA only), pill green' ((Get-Row $rows 'mde.master').Status -eq 'green' -and (Get-Row $rows 'mde.sense').Status -eq 'info' -and (Get-Row $rows 'mde.sense').Reason -like '*Stopped*Manual*' -and (Get-Row $rows 'mde.script').Status -eq 'info' -and (Get-Row $rows 'mde.tag').Reason -like '*legacy MMA*' -and (Get-AVDTuneVdiHostSummary $rows) -eq 'green') (($rows | ForEach-Object { "$($_.Id)=$($_.Status)" }) -join ',')
    $e = New-Env
    Test-Check 'Defender: no Sense service is yellow (the Feature on Demand is missing; the onboarding script could not start it)' ((Get-Row (Get-HostRows $e 'mde') 'mde.sense').Status -eq 'yellow') $null
    $e = New-Env -Seed @{ Files = @((Join-Path $startup 'Onboard-NonPersistentMachine.ps1'), (Join-Path $startup 'WindowsDefenderATPOnboardingScript.cmd')) } -MSeed @{ Services = @(@{ Name = 'Sense'; Status = 'Stopped' }) }
    $r1 = Get-Row (Get-HostRows $e 'mde') 'mde.script'
    $e = New-Env -Seed @{ Files = @((Join-Path $startup 'WindowsDefenderATPOnboardingScript.cmd')) } -MSeed @{ Services = @(@{ Name = 'Sense'; Status = 'Stopped' }) }
    $r2 = Get-Row (Get-HostRows $e 'mde') 'mde.script'
    Test-Check 'Defender: the VDI onboarding scripts in the startup folder are green and name the model (single entry with Onboard-NonPersistentMachine.ps1, multiple entries with the .cmd only)' ($r1.Status -eq 'green' -and $r1.Reason -like '*single entry*' -and $r2.Status -eq 'green' -and $r2.Reason -like '*multiple entries*') "$($r1.Reason) | $($r2.Reason)"
    Test-Check 'Defender: no onboarding package or tenant data in the repository (no .onboarding blob, no WindowsDefenderATPOnboardingPackage file)' (@(Get-ChildItem -LiteralPath $repo -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notlike '*\.git\*' -and ($_.Name -like 'WindowsDefenderATP*' -or $_.Name -like 'Onboard-NonPersistentMachine*' -or $_.Extension -eq '.onboarding') }).Count -eq 0) $null

    # the Shortpath setting: gate, confirmation old -> new, undo record never overwritten, marker and LastChange, run record, change log VDI
    Reset-Files
    Close-AVDTuneWriteGate
    $e = New-Env -MSeed @{ Registry = @{ "$tsp|SelectTransport" = 1 } }
    Test-Check 'Shortpath setting: with the gate closed nothing is written (WhatIf works without the gate)' ((Get-ThrownText { Invoke-AVDTuneVdiHostSettings -Machine $e.M -Key 'shortpath' -Root $tmp }) -like '*snapshot gate*' -and (Get-Writes $e).Count -eq 0 -and @((Invoke-AVDTuneVdiHostSettings -Machine $e.M -Key 'shortpath' -Root $tmp -WhatIf).Results | Where-Object Status -eq 'WhatIf').Count -eq 1 -and (Get-Writes $e).Count -eq 0 -and -not (Test-Path (Join-Path $tmp 'config\vdi-shortpath-settings-undo.json'))) $null
    Open-Gate
    $txt = Get-AVDTuneVdiHostConfirmText -Machine $e.M -Key 'shortpath' -Mode Apply -Root $tmp
    Test-Check 'Shortpath setting: the confirmation names the value old -> new, the restart and the Group Policy that can set it again' ($txt -like '*SelectTransport: 1 -> not set*Restart*Group Policy*') $txt
    [void](Set-AVDTuneState -Root $tmp -Values @{ LastChange = '2020-01-01T00:00:00.0000000' })
    $runsBefore = @(Get-AVDTuneRun -Root $tmp).Count
    $run = Invoke-AVDTuneVdiHostSettings -Machine $e.M -Key 'shortpath' -Root $tmp -User 'admin1' -SnapshotId 'snap-1'
    $u = Get-Content -LiteralPath (Join-Path $tmp 'config\vdi-shortpath-settings-undo.json') -Raw | ConvertFrom-Json
    $st = Get-AVDTuneState $tmp
    Test-Check 'Shortpath setting: Apply removes SelectTransport (= Not configured), restart flagged, undo record typed (DWord 1), run record, change log VDI, LastChange set, marker gone' (@($run.Results | Where-Object Status -eq 'Changed').Count -eq 1 -and $null -eq (& $e.M.RegGet $tsp 'SelectTransport') -and $run.Results[0].Reboot -and $u.Previous.'vdi.shortpath.udp'.Exists -eq $true -and $u.Previous.'vdi.shortpath.udp'.Value -eq 1 -and $u.Previous.'vdi.shortpath.udp'.Type -eq 'DWord' -and @(Get-AVDTuneRun -Root $tmp).Count -eq $runsBefore + 1 -and @(Get-AVDTuneRun -Root $tmp | Where-Object Plan -eq 'VDI RDP Shortpath settings').Count -eq 1 -and @(Get-AVDTuneChangeLog -Root $tmp | Where-Object { $_.Category -eq 'VDI' -and $_.Component -eq 'RDP Shortpath' -and $_.ChangeType -eq 'Changed' }).Count -eq 1 -and [string]$st.LastChange -ne '2020-01-01T00:00:00.0000000' -and -not (Get-AVDTuneChangeMarker -Root $tmp)) ($run.Results | ForEach-Object { "$($_.Id)=$($_.Status) $($_.Message)" }) -join ','
    $before = (Get-AVDTuneState $tmp).LastChange; $runsBefore = @(Get-AVDTuneRun -Root $tmp).Count; $logN = $e.M.Log.Count
    $run = Invoke-AVDTuneVdiHostSettings -Machine $e.M -Key 'shortpath' -Root $tmp -User 'admin1'
    Test-Check 'Shortpath setting: Apply when it is already set changes nothing and writes nothing (no LastChange, no run record); the confirmation text is empty' ($run.Results[0].Status -eq 'Unchanged' -and (Get-AVDTuneState $tmp).LastChange -eq $before -and @(Get-AVDTuneRun -Root $tmp).Count -eq $runsBefore -and @($e.M.Log | Select-Object -Skip $logN | Where-Object { $_ -like 'RegSet*' -or $_ -like 'RegRemove*' }).Count -eq 0 -and -not (Get-AVDTuneVdiHostConfirmText -Machine $e.M -Key 'shortpath' -Root $tmp)) $null
    $at = $u.At
    & $e.M.RegSet $tsp 'SelectTransport' 1 'DWord'   # a policy refresh sets it again
    [void](Invoke-AVDTuneVdiHostSettings -Machine $e.M -Key 'shortpath' -Root $tmp)
    $u2 = Get-Content -LiteralPath (Join-Path $tmp 'config\vdi-shortpath-settings-undo.json') -Raw | ConvertFrom-Json
    Test-Check 'Shortpath setting: a second Apply keeps the undo record as it was (never overwritten)' ($u2.At -eq $at -and $u2.Previous.'vdi.shortpath.udp'.Value -eq 1) ($u2 | ConvertTo-Json -Compress)
    $txt = Get-AVDTuneVdiHostConfirmText -Machine $e.M -Key 'shortpath' -Mode Undo -Root $tmp
    $run = Invoke-AVDTuneVdiHostSettings -Machine $e.M -Key 'shortpath' -Mode Undo -Root $tmp -User 'admin1'
    Test-Check 'Shortpath setting: Undo confirmation names not set -> 1; Undo puts DWord 1 back, change log "Undo:", the record is removed; a second Undo has nothing to undo' ($txt -like '*SelectTransport: not set -> 1*' -and $run.Results[0].Status -eq 'Reverted' -and (& $e.M.RegGet $tsp 'SelectTransport') -eq 1 -and (& $e.M.RegGetRaw $tsp 'SelectTransport').Kind -eq 'DWord' -and @(Get-AVDTuneChangeLog -Root $tmp | Where-Object { $_.Category -eq 'VDI' -and $_.Text -like 'Undo: RDP transport*' }).Count -eq 1 -and -not (Test-Path (Join-Path $tmp 'config\vdi-shortpath-settings-undo.json')) -and (Get-ThrownText { Invoke-AVDTuneVdiHostSettings -Machine $e.M -Key 'shortpath' -Mode Undo -Root $tmp }) -like '*nothing to undo*') "$txt / $($run.Results[0].Status)"
    # a record that is not exactly typed is refused before anything is changed
    Write-AVDTuneFile (Join-Path $tmp 'config\vdi-shortpath-settings-undo.json') '{ "At": "x", "Previous": { "vdi.shortpath.udp": { "Exists": true, "Value": "1", "Type": "DWord" } } }'
    $logN = $e.M.Log.Count
    Test-Check 'Shortpath setting: an undo record with an untyped value is refused by Apply and Undo, nothing is written' ((Get-ThrownText { Invoke-AVDTuneVdiHostSettings -Machine $e.M -Key 'shortpath' -Mode Undo -Root $tmp }) -like '*not usable*' -and (Get-ThrownText { Invoke-AVDTuneVdiHostSettings -Machine $e.M -Key 'shortpath' -Root $tmp }) -like '*not usable*' -and @($e.M.Log | Select-Object -Skip $logN | Where-Object { $_ -like 'RegSet*' -or $_ -like 'RegRemove*' }).Count -eq 0 -and (& $e.M.RegGet $tsp 'SelectTransport') -eq 1) $null
    Write-AVDTuneFile (Join-Path $tmp 'config\vdi-shortpath-settings-undo.json') '{ "At": "x", "Previous": { "vdi.other": { "Exists": false } } }'
    Test-Check 'Shortpath setting: an undo record with an unknown id is refused' ((Get-ThrownText { Invoke-AVDTuneVdiHostSettings -Machine $e.M -Key 'shortpath' -Mode Undo -Root $tmp }) -like '*not usable*') $null
    Reset-Files
    # a failing undo keeps the record and is a change (LastChange) with a change log note
    [void](Invoke-AVDTuneVdiHostSettings -Machine $e.M -Key 'shortpath' -Root $tmp)
    $e.M.Store.FailWrites = @('Terminal Services|SelectTransport')
    [void](Set-AVDTuneState -Root $tmp -Values @{ LastChange = '2020-01-01T00:00:00.0000000' })
    $run = Invoke-AVDTuneVdiHostSettings -Machine $e.M -Key 'shortpath' -Mode Undo -Root $tmp
    Test-Check 'Shortpath setting: a failing Undo is Failed, keeps the undo record, sets LastChange and writes a change log note; the marker is gone' ($run.Results[0].Status -eq 'Failed' -and (Test-Path (Join-Path $tmp 'config\vdi-shortpath-settings-undo.json')) -and [string](Get-AVDTuneState $tmp).LastChange -ne '2020-01-01T00:00:00.0000000' -and @(Get-AVDTuneChangeLog -Root $tmp | Where-Object { $_.Category -eq 'VDI' -and $_.ChangeType -eq 'Note' -and $_.Text -like '*FAILED*' }).Count -ge 1 -and -not (Get-AVDTuneChangeMarker -Root $tmp)) $run.Results[0].Message
    $e.M.Store.FailWrites = @()
    Reset-Files
    $src77 = Get-Content -LiteralPath (Join-Path $repo 'Modules\AVDTune.Vdi.psm1') -Raw
    $fn = [regex]::Match($src77, '(?s)function Invoke-AVDTuneVdiHostSettings \{.*?\r?\n\}\r?\n').Value
    Test-Check 'Shortpath setting: the write path uses Start-/Stop-AVDTuneChange (stop in finally) and the step engine, no direct registry call' ($fn -match 'Start-AVDTuneChange -Root \$Root' -and $fn -match 'finally \{ Stop-AVDTuneChange -Root \$Root -Owner \$owner \}' -and $fn -match 'Invoke-AVDTuneStep' -and $fn -notmatch 'RegSet|RegRemove|Set-ItemProperty|New-ItemProperty') $null
    $page = Get-Content -LiteralPath (Join-Path $repo 'AVDTune-Vdi.ps1') -Raw
    Test-Check 'page: the host settings run as a VDI job (background task, writer VdiJob) after the write gate, the writer check and a confirmation' ($page -match "'HostSettings' \{ Invoke-AVDTuneVdiHostSettings" -and $page -match "'HostUndo' \{ Invoke-AVDTuneVdiHostSettings" -and $page -match '(?s)function Invoke-VdiHostAction.*?Assert-FslWrite.*?Confirm-Action.*?Start-VdiJob \$Act \$Key') $null

    # ---------------------------------------------------------------- the real adapter (source and construction; never run here)
    $src = Get-Content -LiteralPath (Join-Path $repo 'Modules\AVDTune.Vdi.psm1') -Raw
    $real = New-AVDTuneVdiAdapter
    Test-Check 'real adapter: redirects are followed by hand (AllowAutoRedirect false), https and fixed hosts only, no PATH lookup, no shell, no Invoke-WebRequest' ($src -match 'AllowAutoRedirect = \$false' -and $src -notmatch 'AllowAutoRedirect = \$true' -and $src -notmatch 'Get-Command (?!Resolve-AVDTuneSoftwareError)|Invoke-WebRequest|Invoke-Expression|Start-Process|cmd\.exe|UseShellExecute = \$true') $null
    $rp = [regex]::Match($src, '(?s)\$a\.ReadMsiProperties = \{.*?\r?\n    \}\r?\n').Value
    Test-Check 'real adapter: the MSI Property table is read with the direct COM calls, every record is released at once and the view is closed (the file is not held until the garbage collection)' ($rp -match 'OpenDatabase\(\$Path, 0\)' -and $rp -match 'ReleaseComObject\(\$rec\)' -and $rp -match '\$view\.Close\(\)' -and $rp -notmatch 'InvokeMember') $null
    Test-Check 'real adapter: constructs and has every member the flow uses' ((@('Resolve', 'NewTempFolder', 'IsProtectedFolder', 'Download', 'HoldFile', 'RemoveFolder', 'VerifySignature', 'Run', 'ReadHeader', 'RunningProcesses', 'MsiexecPath', 'AppxVersion', 'FileVersion', 'Exists', 'OneDrivePath', 'U', 'UdpListener', 'FirewallUdpIn', 'TeredoType') | Where-Object { $null -eq $real.$_ }).Count -eq 0) $null
    Test-Check 'the fake has every member of the real adapter (the fake stays in step)' ((@($real.PSObject.Properties.Name | Where-Object { $_ -ne 'Kind' }) | Where-Object { $null -eq (New-AVDTuneFakeVdi -Machine (New-AVDTuneFakeMachine)).$_ }).Count -eq 0) $null
    $probeSrc = [regex]::Match($src, '(?s)\$a\.UdpListener = .*?\$a\.TeredoType = [^\r\n]*').Value
    Test-Check 'real adapter (#77): the session host probes only read (open UDP ports, firewall rules through HNetCfg.FwPolicy2, Teredo type), nothing is set, the COM object is released' ($probeSrc -match 'GetActiveUdpListeners' -and $probeSrc -match 'HNetCfg\.FwPolicy2' -and $probeSrc -match 'ReleaseComObject\(\$fw\)' -and $probeSrc -match 'Get-NetTeredoConfiguration' -and $probeSrc -notmatch 'Set-Net|New-NetFirewallRule|Rules\.Add|Rules\.Remove|netsh') $null
    $pl = & $real.UdpListener 3390; $pf = & $real.FirewallUdpIn 3390
    Test-Check 'real adapter (#77): the two read-only probes answer true, false or $null on this computer (no error)' (($pl -is [bool] -or $null -eq $pl) -and ($pf -is [bool] -or $null -eq $pf)) "$pl / $pf"
    $rr = & $real.Resolve 'https://evil.example/x' 'Msi'
    $rr2 = & $real.Resolve 'http://aka.ms/avdmmr/msi' 'Msi'
    Test-Check 'real adapter: an entry link outside aka.ms and go.microsoft.com, or over http, is refused before any request' (-not $rr.Ok -and -not $rr2.Ok -and $rr.Error -like '*not on aka.ms*') $rr.Error
    $dlr = & $real.Download 'https://evil.example/x.msi' (Join-Path $tmp 'nope.msi') 1MB
    Test-Check 'real adapter: the download refuses every host but download.microsoft.com' (-not $dlr.Ok -and $dlr.Error -like '*download.microsoft.com*' -and -not (Test-Path (Join-Path $tmp 'nope.msi'))) $dlr.Error
    Test-Check 'the downloaded file names are fixed (never from the address) and the entry links are on aka.ms or go.microsoft.com' ((@(Get-AVDTuneVdiComponents | Where-Object { $_.Kind -ne 'Winget' } | Where-Object { $_.File -notmatch '^[a-z0-9.-]+\.(msi|exe)\z' -or -not (Test-AVDTuneVdiUrl -Url $_.Entry -Hosts @('aka.ms', 'go.microsoft.com')) })).Count -eq 0) $null
    Test-Check 'the new files are plain ASCII (the scripts run in Windows PowerShell 5.1 without a BOM)' ((@('Modules\AVDTune.Vdi.psm1', 'AVDTune-Vdi.ps1', 'UI\Vdi.xaml', 'Tests\Fakes\FakeVdi.ps1', 'Tests\Check-Vdi.ps1') | Where-Object { [IO.File]::ReadAllBytes((Join-Path $repo $_)) | Where-Object { $_ -gt 127 } | Select-Object -First 1 }).Count -eq 0) $null
}
finally {
    Remove-Item Env:\AVDTUNE_ROOT -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
if ($script:failed -gt 0) { throw "$script:failed check(s) failed." }
