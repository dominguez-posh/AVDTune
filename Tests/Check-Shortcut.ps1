#requires -Version 5.1
<#
.SYNOPSIS
    Checks the desktop shortcut (issue #15) in temporary folders only: target, arguments, working folder, icon, "run as administrator" in the
    .lnk header, refusal of the Public Desktop, removal, the stored answer per account. Real .lnk files are written and read, but only below
    %TEMP%; the desktop of this computer is never touched.
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'Modules\AVDTune.psm1') -Force
Import-Module (Join-Path $repo 'Modules\AVDTune.Shortcut.psm1') -Force

$script:failed = 0
function Test-Check([string]$Name, [bool]$Ok, $Detail) { if ($Ok) { "PASS $Name" } else { $script:failed++; "FAIL $Name" + $(if ($null -ne $Detail) { "  -> $Detail" }) } }
function Get-ThrownText([scriptblock]$Block) { try { & $Block | Out-Null; $null } catch { $_.Exception.Message } }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('avdtune-shortcut-' + [guid]::NewGuid().ToString('N'))
try {
    $env:AVDTUNE_ROOT = Join-Path $tmp 'state'
    $env:AVDTUNE_FAKE = Join-Path $PSScriptRoot 'Fakes\FakeMachine.ps1'
    [void](Initialize-AVDTuneState -Root $env:AVDTUNE_ROOT)
    $desk = Join-Path $tmp 'Desktop'; New-Item -ItemType Directory -Path $desk -Force | Out-Null
    $install = Join-Path $tmp 'Program Files\AVDTune'; New-Item -ItemType Directory -Path $install -Force | Out-Null
    $realDesk = [Environment]::GetFolderPath('DesktopDirectory')
    $realBefore = Test-Path -LiteralPath (Join-Path $realDesk 'AVDTune.lnk')

    # ---------------------------------------------------------------- spec
    $ps = Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell\v1.0\powershell.exe'
    $spec = Get-AVDTuneShortcutSpec $install
    Test-Check 'target: the full path of Windows PowerShell 5.1 from the System folder' ($spec.Target -eq $ps -and (Test-Path -LiteralPath $spec.Target)) $spec.Target
    Test-Check 'arguments: -NoProfile -ExecutionPolicy Bypass -File "<install folder>\Start-AVDTune.ps1" (quoted, path with spaces)' ($spec.Arguments -ceq "-NoProfile -ExecutionPolicy Bypass -File `"$install\Start-AVDTune.ps1`"") $spec.Arguments
    Test-Check 'the default folder is the desktop of the current account, not the Public Desktop' ((Get-AVDTuneUserDesktop) -eq $realDesk -and -not (Test-AVDTunePublicDesktop $realDesk)) $realDesk

    # ---------------------------------------------------------------- create, read back
    $link = New-AVDTuneDesktopShortcut -InstallRoot $install -Folder $desk
    $file = Join-Path $desk 'AVDTune.lnk'
    Test-Check 'the .lnk is written to the given folder and reads back with target, arguments, working folder' ((Test-Path $file) -and $link.Target -ieq $ps -and $link.Arguments -ceq $spec.Arguments -and $link.WorkingDirectory.TrimEnd('\') -ieq $install -and $link.Matches) ($link | Out-String)
    Test-Check 'icon: powershell.exe when the install folder has no AVDTune.ico' ($link.Icon -ieq "$ps,0") $link.Icon
    $bytes = [IO.File]::ReadAllBytes($file)
    Test-Check 'run as administrator: LinkFlags bit 0x2000 (byte 0x15 bit 0x20) is set in the header' (($bytes[0x15] -band 0x20) -ne 0 -and [BitConverter]::ToUInt32($bytes, 0x14) -band 0x2000 -and $link.RunAs) ('{0:X8}' -f [BitConverter]::ToUInt32($bytes, 0x14))
    # the same .lnk without the patch differs only in that bit
    $plain = Join-Path $tmp 'plain.lnk'
    $sh = New-Object -ComObject WScript.Shell; $l = $sh.CreateShortcut($plain); $l.TargetPath = $spec.Target; $l.Arguments = $spec.Arguments; $l.WorkingDirectory = $spec.WorkingDirectory; $l.IconLocation = $spec.Icon; $l.Description = $spec.Description; $l.WindowStyle = 1; $l.Save()
    $pf = [BitConverter]::ToUInt32([IO.File]::ReadAllBytes($plain), 0x14); $lf = [BitConverter]::ToUInt32($bytes, 0x14)
    Test-Check 'the patch changes only the RunAsUser flag (all other link flags as Windows wrote them)' (($pf -bor 0x2000) -eq $lf -and ($pf -band 0x2000) -eq 0 -and -not (Test-AVDTuneLnkRunAs $plain)) ('{0:X8} / {1:X8}' -f $pf, $lf)
    [IO.File]::WriteAllBytes((Join-Path $install 'AVDTune.ico'), [byte[]](0, 0, 1, 0))
    $link2 = New-AVDTuneDesktopShortcut -InstallRoot $install -Folder $desk
    Test-Check 'icon: AVDTune.ico of the install folder when it exists; a second create replaces the shortcut' ($link2.Icon -ieq "$install\AVDTune.ico,0" -and @(Get-ChildItem $desk -Filter '*.lnk').Count -eq 1) $link2.Icon
    $txt = Join-Path $tmp 'not-a-link.lnk'; [IO.File]::WriteAllText($txt, 'hello world, this is not a shell link header at all; nothing to patch here........')
    $before = [IO.File]::ReadAllText($txt)
    Test-Check 'a file without the shell link header is refused and left as it was' ((Get-ThrownText { Set-AVDTuneLnkRunAs $txt }) -like '*not a shell link*' -and [IO.File]::ReadAllText($txt) -eq $before) $null
    $other = Get-AVDTuneDesktopShortcut -Folder $desk -InstallRoot (Join-Path $tmp 'elsewhere')
    Test-Check 'a shortcut that points to another install folder does not match' (-not $other.Matches) $null

    # ---------------------------------------------------------------- the second shortcut "AVDTune Benchmark" (#90): the launcher with -Benchmark
    $bspec = Get-AVDTuneShortcutSpec $install -Benchmark
    $blink = New-AVDTuneDesktopShortcut -InstallRoot $install -Folder $desk -Benchmark
    Test-Check 'benchmark shortcut: AVDTune Benchmark.lnk next to AVDTune.lnk, same launcher with -Benchmark at the end, run as administrator, matches only its own spec' ((Test-Path -LiteralPath (Join-Path $desk 'AVDTune Benchmark.lnk')) -and (Get-AVDTuneShortcutName -Benchmark) -eq 'AVDTune Benchmark.lnk' -and $bspec.Arguments -ceq ($spec.Arguments + ' -Benchmark') -and $blink.Arguments -ceq $bspec.Arguments -and $blink.RunAs -and $blink.Matches -and -not (Get-AVDTuneDesktopShortcut -Folder $desk -InstallRoot $install).Arguments.EndsWith('-Benchmark')) $blink.Arguments
    Test-Check 'benchmark shortcut: removing it leaves AVDTune.lnk; the Public Desktop is refused for it too' ((Remove-AVDTuneDesktopShortcut -Folder $desk -Benchmark) -and -not (Test-Path -LiteralPath (Join-Path $desk 'AVDTune Benchmark.lnk')) -and (Test-Path -LiteralPath (Join-Path $desk 'AVDTune.lnk')) -and (Get-ThrownText { New-AVDTuneDesktopShortcut -InstallRoot $install -Folder ([Environment]::GetFolderPath('CommonDesktopDirectory')) -Benchmark }) -like '*never puts a shortcut on the Public Desktop*') $null

    # ---------------------------------------------------------------- never the Public Desktop
    $public = @([Environment]::GetFolderPath('CommonDesktopDirectory'), (Join-Path $env:PUBLIC 'Desktop'), (Join-Path $env:SystemDrive 'Users\Public\Desktop\sub'), (Join-Path $env:SystemDrive 'Users\Default\Desktop'), 'C:\Users\All Users\Desktop')
    $pubBefore = @($public | ForEach-Object { Test-Path -LiteralPath (Join-Path $_ 'AVDTune.lnk') })
    $notRefused = @($public | Where-Object { (Get-ThrownText { New-AVDTuneDesktopShortcut -InstallRoot $install -Folder $_ }) -notlike '*never puts a shortcut on the Public Desktop*' })
    $pubAfter = @($public | ForEach-Object { Test-Path -LiteralPath (Join-Path $_ 'AVDTune.lnk') })
    Test-Check 'the Public Desktop and the Public/Default profiles are refused before anything is written' ($notRefused.Count -eq 0 -and (($pubBefore -join ',') -eq ($pubAfter -join ','))) ($notRefused -join ' | ')
    Test-Check 'removing from the Public Desktop is refused too' ((Get-ThrownText { Remove-AVDTuneDesktopShortcut -Folder ([Environment]::GetFolderPath('CommonDesktopDirectory')) }) -like '*does not change the Public Desktop*') $null

    # ---------------------------------------------------------------- remove
    Test-Check 'remove deletes AVDTune.lnk only; a second remove finds nothing' ((Remove-AVDTuneDesktopShortcut -Folder $desk) -and -not (Test-Path $file) -and -not (Remove-AVDTuneDesktopShortcut -Folder $desk) -and $null -eq (Get-AVDTuneDesktopShortcut -Folder $desk)) $null

    # ---------------------------------------------------------------- answer, offer
    $root = $env:AVDTUNE_ROOT
    Test-Check 'not answered: installed copy asks, any other copy gets the hint to install first' ((Get-AVDTuneShortcutOffer -Root $root -UserKey 'S-1-5-21-1-2-3-1001' -Mode Installed) -eq 'Ask' -and (Get-AVDTuneShortcutOffer -Root $root -UserKey 'S-1-5-21-1-2-3-1001' -Mode Development) -eq 'Install' -and (Get-AVDTuneShortcutOffer -Root $root -UserKey 'S-1-5-21-1-2-3-1001' -Mode Unprotected) -eq 'Install') $null
    Set-AVDTuneShortcutAnswer -Root $root -UserKey 'S-1-5-21-1-2-3-1001' -Answer No
    Test-Check 'the answer is kept per account in state.json and not asked again; another account is still asked' ((Get-AVDTuneShortcutAnswer -Root $root -UserKey 'S-1-5-21-1-2-3-1001') -eq 'No' -and (Get-AVDTuneShortcutOffer -Root $root -UserKey 'S-1-5-21-1-2-3-1001' -Mode Installed) -eq 'None' -and (Get-AVDTuneShortcutOffer -Root $root -UserKey 'S-1-5-21-1-2-3-1002' -Mode Installed) -eq 'Ask' -and (Get-AVDTuneState $root).DesktopShortcut.'S-1-5-21-1-2-3-1001'.Answer -eq 'No') $null
    Set-AVDTuneShortcutAnswer -Root $root -UserKey 'S-1-5-21-1-2-3-1002' -Answer Yes
    Test-Check 'a second account keeps the first answer' ((Get-AVDTuneShortcutAnswer -Root $root -UserKey 'S-1-5-21-1-2-3-1001') -eq 'No' -and (Get-AVDTuneShortcutAnswer -Root $root -UserKey 'S-1-5-21-1-2-3-1002') -eq 'Yes') $null
    Test-Check 'an account key with odd characters is refused' ($null -ne (Get-ThrownText { Set-AVDTuneShortcutAnswer -Root $root -UserKey 'a.b"c' -Answer Yes })) $null
    Test-Check 'the key of the current account is its SID' ((Get-AVDTuneUserKey) -match '^S-1-5-') (Get-AVDTuneUserKey)

    # ---------------------------------------------------------------- the benchmark shortcut on the Overview (#90 follow-up)
    [xml]$win = Get-Content (Join-Path $repo 'UI\AVDTune.xaml') -Raw -Encoding UTF8
    $named = { param($n) $win.SelectSingleNode("//*[@*[local-name()='Name' and .='$n']]") }
    $card = { param($node) $p = $node; while ($p -and -not ($p.LocalName -eq 'Border' -and ($p.Attributes | Where-Object { $_.LocalName -eq 'Name' }))) { $p = $p.ParentNode }; if ($p) { [string]($p.Attributes | Where-Object { $_.LocalName -eq 'Name' }).Value } }
    $relBtn = & $named 'BtnRelBenchShortcut'; $relTxt = & $named 'TxtRelBenchShortcut'
    Test-Check 'the Integrity and updates card of the Overview has the AVDTune Benchmark shortcut button next to the AVDTune one, with a key for its name' ($relBtn -and $relTxt -and (& $card $relBtn) -and (& $card $relBtn) -eq (& $card (& $named 'BtnRelShortcut')) -and $relBtn.GetAttribute('Uid') -eq 'rel.benchshortcut') $null
    $relCode = [IO.File]::ReadAllText((Join-Path $repo 'AVDTune-Release.ps1')); $benchCode = [IO.File]::ReadAllText((Join-Path $repo 'AVDTune-Benchmark.ps1'))
    $sw = [regex]::Match($relCode, '(?s)function Switch-BenchShortcut \{.*?\r?\n\}').Value
    Test-Check 'both buttons use the one switch, which creates only with -Benchmark and only for the installed copy, on the desktop of the account' ($relCode -match 'Add-Click \$ui\.BtnRelBenchShortcut \{ Switch-BenchShortcut \}' -and $benchCode -match 'Add-Click \$ui\.BtnBenchShortcut \{ Switch-BenchShortcut \}' -and $benchCode -notmatch 'function Switch-BenchShortcut' -and $sw -match "elseif \(\(Get-ShortcutMode\) -eq 'Installed'\)" -and $sw -match 'New-AVDTuneDesktopShortcut -InstallRoot \$script:RelInstallRoot -Folder \$folder -Benchmark' -and $sw -match '\$folder = Get-ShortcutDesktop' -and $sw -notmatch 'CommonDesktop|Public') $sw

    $realAfter = Test-Path -LiteralPath (Join-Path $realDesk 'AVDTune.lnk')
    Test-Check 'the desktop of this computer was not touched' ($realBefore -eq $realAfter) $null
    $nonAscii = @('Modules\AVDTune.Shortcut.psm1', 'Tests\Check-Shortcut.ps1') | Where-Object { [IO.File]::ReadAllText((Join-Path $repo $_)) -match '[^\x00-\x7F]' }
    Test-Check 'plain ASCII' ($nonAscii.Count -eq 0) ($nonAscii -join ', ')
}
finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:AVDTUNE_ROOT, Env:AVDTUNE_FAKE -ErrorAction SilentlyContinue
}
if ($script:failed -gt 0) { "Check-Shortcut: $script:failed check(s) failed."; exit 1 }
'Check-Shortcut: all checks passed.'
