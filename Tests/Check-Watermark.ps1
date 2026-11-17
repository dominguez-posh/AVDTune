#requires -Version 5.1
<#
.SYNOPSIS
    Checks the watermark (Watermark\*.ps1, Modules\AVDTune.Watermark.psm1) against the fake machine and a temporary state folder: name pattern and
    settings validation, placement, the task definition, the steps (Test/Apply/Undo, write gate, idempotency, unsafe folders, Microsoft policy), the
    old overlay (detect, remove with backup, restore), change log and LastChange. The overlay script runs in child processes: exits at once for a
    name that does not match, exit code 2 for bad settings, and -DryRun creates the windows without showing them (click-through styles checked).
    Nothing here touches a real scheduled task, the registry, Program Files or ProgramData; the fake machine keeps everything in memory.
#>
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'Modules\AVDTune.psm1') -Force
Import-Module (Join-Path $repo 'Modules\AVDTune.Watermark.psm1') -Force
. (Join-Path $PSScriptRoot 'Fakes\FakeMachine.ps1')

$script:failed = 0
function Test-Check([string]$Name, [bool]$Ok, $Detail) { if ($Ok) { "PASS $Name" } else { $script:failed++; "FAIL $Name" + $(if ($null -ne $Detail) { "  -> $Detail" }) } }
function Test-Throws([scriptblock]$Block) { try { & $Block | Out-Null; $false } catch { $true } }
function Get-StepResult($Summary, [string]$Id) { @($Summary.Results | Where-Object { $_.Id -eq $Id })[0] }

$sourceRoot = Join-Path $repo 'Watermark'
$legacyXml = @'
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <Triggers><LogonTrigger><Enabled>true</Enabled></LogonTrigger></Triggers>
  <Principals><Principal id="Author"><GroupId>S-1-5-32-545</GroupId></Principal></Principals>
  <Settings><Enabled>true</Enabled></Settings>
  <Actions Context="Author"><Exec><Command>wscript.exe</Command><Arguments>"C:\ProgramData\PilotOverlayLauncher.vbs"</Arguments></Exec></Actions>
</Task>
'@

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('avdtune-wm-' + [guid]::NewGuid().ToString('N'))
try {
    $env:AVDTUNE_ROOT = $tmp
    [void](Initialize-AVDTuneState -Root $tmp)
    [void](Start-AVDTuneImageVersion -Root $tmp -Date ([datetime]'2026-11-15') -User 'admin1')
    Close-AVDTuneWriteGate

    # ---------------------------------------------------------------- name pattern
    Test-Check 'pattern: a normal pattern is valid' ((Test-AVDTuneWatermarkPattern '^avd-pilot-').Valid) $null
    Test-Check 'pattern: empty, too long and control characters are refused' (-not (Test-AVDTuneWatermarkPattern '').Valid -and -not (Test-AVDTuneWatermarkPattern ('a' * 201)).Valid -and -not (Test-AVDTuneWatermarkPattern "a`tb").Valid) $null
    $bad = Test-AVDTuneWatermarkPattern '(unclosed'
    Test-Check 'pattern: an invalid regular expression is refused with the reason' (-not $bad.Valid -and $bad.Error -like 'Not a valid regular expression*') $bad.Error
    Test-Check 'name: match, case-insensitive, anchored' ((Test-AVDTuneWatermarkName '^avd-pilot-' 'AVD-PILOT-03') -and -not (Test-AVDTuneWatermarkName '^avd-pilot-' 'x-avd-pilot-03') -and -not (Test-AVDTuneWatermarkName '^avd-pilot-' 'AVD-PROD-01')) $null
    Test-Check 'name: an invalid pattern or an empty name never matches' (-not (Test-AVDTuneWatermarkName '(' 'a') -and -not (Test-AVDTuneWatermarkName '^a' '')) $null
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $slow = Test-AVDTuneWatermarkName '^(a+)+$' (('a' * 40) + '!')
    $sw.Stop()
    Test-Check 'name: a catastrophic pattern ends at the 250 ms limit and does not match' (-not $slow -and $sw.ElapsedMilliseconds -lt 3000) "$($sw.ElapsedMilliseconds) ms"

    # ---------------------------------------------------------------- settings validation
    $d = ConvertTo-AVDTuneWatermarkSettings $null
    Test-Check 'settings: nothing given gives valid defaults (PILOTUMGEBUNG, generic pattern, bottom right)' ($d.Valid -and $d.Settings.Text -eq 'PILOTUMGEBUNG' -and $d.Settings.Pattern -eq '^avd-pilot-' -and $d.Settings.Corner -eq 'BottomRight' -and -not $d.Settings.Microsoft.Enabled) ($d.Errors -join '; ')
    $ok = ConvertTo-AVDTuneWatermarkSettings ('{"Pattern":"^x-","Text":"TEST","Color":"#00ff00","Opacity":"40","FontSize":30,"Corner":"TopLeft","Margin":0}' | ConvertFrom-Json)
    Test-Check 'settings: json values are taken, colour upper-cased, numbers as text accepted' ($ok.Valid -and $ok.Settings.Color -eq '#00FF00' -and $ok.Settings.Opacity -eq 40 -and $ok.Settings.Corner -eq 'TopLeft' -and $ok.Settings.Margin -eq 0) ($ok.Errors -join '; ')
    foreach ($case in @(
            @('pattern', @{ Pattern = '(' }), @('empty text', @{ Text = '  ' }), @('text over 60', @{ Text = ('x' * 61) }), @('text with a line break', @{ Text = "a`r`nb" }),
            @('colour name', @{ Color = 'red' }), @('colour without #', @{ Color = 'FF0000' }), @('opacity 9', @{ Opacity = 9 }), @('opacity 101', @{ Opacity = 101 }), @('opacity text', @{ Opacity = 'high' }),
            @('font 7', @{ FontSize = 7 }), @('font 97', @{ FontSize = 97 }), @('corner', @{ Corner = 'Middle' }), @('margin -1', @{ Margin = -1 }), @('margin 501', @{ Margin = 501 }),
            @('console mode', @{ ConsoleMode = 'Visible' }), @('Microsoft switch as text', @{ Microsoft = @{ Enabled = 'false' } }), @('Microsoft switch as number', @{ Microsoft = @{ Enabled = 1 } }), @('QR scale 11', @{ Microsoft = @{ QrScale = 11 } }), @('QR opacity 99', @{ Microsoft = @{ Opacity = 99 } }), @('QR width 99', @{ Microsoft = @{ WidthFactor = 99 } }), @('QR height 1001', @{ Microsoft = @{ HeightFactor = 1001 } })
        )) {
        $r = ConvertTo-AVDTuneWatermarkSettings $case[1]
        Test-Check "settings: $($case[0]) is refused" (-not $r.Valid -and $r.Errors.Count -ge 1) ($r.Errors -join '; ')
    }
    $edge = ConvertTo-AVDTuneWatermarkSettings @{ Opacity = 10; FontSize = 96; Margin = 500; Microsoft = @{ Enabled = $true; QrScale = 10; Opacity = 9999; WidthFactor = 1000; HeightFactor = 100 } }
    Test-Check 'settings: the limits themselves are valid' ($edge.Valid -and $edge.Settings.Microsoft.Enabled) ($edge.Errors -join '; ')
    $pub = Get-AVDTuneWatermarkPublicSettings $edge.Settings
    Test-Check 'public copy: only what the overlay needs (no Microsoft values, no console mode)' ((@($pub.PSObject.Properties.Name) -join ',') -eq 'Schema,Pattern,Text,Color,Opacity,FontSize,Corner,Margin') ($pub.PSObject.Properties.Name -join ',')

    # ---------------------------------------------------------------- placement
    $wa = @{ X = 0; Y = 0; Width = 1920; Height = 1040 }
    $br = Get-AVDTuneWatermarkPlacement -WorkArea $wa -Width 170 -Height 28 -Corner BottomRight -Margin 16
    $tl = Get-AVDTuneWatermarkPlacement -WorkArea $wa -Width 170 -Height 28 -Corner TopLeft -Margin 16
    $tr = Get-AVDTuneWatermarkPlacement -WorkArea $wa -Width 170 -Height 28 -Corner TopRight -Margin 0
    $bl = Get-AVDTuneWatermarkPlacement -WorkArea $wa -Width 170 -Height 28 -Corner BottomLeft -Margin 16
    Test-Check 'placement: the four corners sit inside the work area (above the taskbar)' ($br.X -eq 1734 -and $br.Y -eq 996 -and $tl.X -eq 16 -and $tl.Y -eq 16 -and $tr.X -eq 1750 -and $tr.Y -eq 0 -and $bl.X -eq 16 -and $bl.Y -eq 996) "$($br.X),$($br.Y) $($tl.X),$($tl.Y) $($tr.X),$($tr.Y) $($bl.X),$($bl.Y)"
    $second = Get-AVDTuneWatermarkPlacement -WorkArea @{ X = 1920; Y = -120; Width = 2560; Height = 1440 } -Width 200 -Height 30 -Corner BottomRight -Margin 20
    Test-Check 'placement: a second monitor with an offset and a negative origin' ($second.X -eq 4260 -and $second.Y -eq 1270) "$($second.X),$($second.Y)"
    $tiny = Get-AVDTuneWatermarkPlacement -WorkArea @{ X = 0; Y = 0; Width = 100; Height = 20 } -Width 170 -Height 28 -Corner BottomRight -Margin 16
    Test-Check 'placement: a label larger than the area is kept at the corner of the area' ($tiny.X -eq 0 -and $tiny.Y -eq 0) $null

    # ---------------------------------------------------------------- saved settings
    $g = Get-AVDTuneWatermarkSettings -Root $tmp
    Test-Check 'saved settings: none yet gives the defaults, not saved' (-not $g.Saved -and $g.Settings.Text -eq 'PILOTUMGEBUNG' -and $g.Errors.Count -eq 0) $null
    Test-Check 'saved settings: invalid settings are refused and no file is written' ((Test-Throws { Save-AVDTuneWatermarkSettings -Root $tmp -Settings @{ Pattern = '(' } }) -and -not (Test-Path (Join-Path $tmp 'config\watermark.json'))) $null
    $saved = Save-AVDTuneWatermarkSettings -Root $tmp -Settings @{ Pattern = '^avd-pilot-'; Text = 'PILOTUMGEBUNG'; Color = '#C62828'; Opacity = 55; FontSize = 22; Corner = 'BottomRight'; Margin = 12 }
    $g = Get-AVDTuneWatermarkSettings -Root $tmp
    Test-Check 'saved settings: saved to config\watermark.json of the state root and read back' ($g.Saved -and $g.Settings.Color -eq '#C62828' -and $g.Settings.FontSize -eq 22 -and (Test-Path (Join-Path $tmp 'config\watermark.json'))) $null
    [IO.File]::WriteAllText((Join-Path $tmp 'config\watermark.json'), '{"Pattern":"(","Opacity":500}')
    $g = Get-AVDTuneWatermarkSettings -Root $tmp
    Test-Check 'saved settings: a damaged file gives the defaults and the reasons' ($g.Errors.Count -ge 2 -and $g.Settings.Pattern -eq '^avd-pilot-') ($g.Errors -join '; ')
    [void](Save-AVDTuneWatermarkSettings -Root $tmp -Settings $saved)

    # ---------------------------------------------------------------- task definition
    $paths = Get-AVDTuneWatermarkPaths (New-AVDTuneFakeMachine)
    $xml = New-AVDTuneWatermarkTaskXml -Paths $paths
    $info = Get-AVDTuneTaskInfoFromXml $xml
    Test-Check 'task xml: logon trigger, principal is the group Users by SID, no user, enabled' ($info.Logon -and $info.GroupSid -eq 'S-1-5-32-545' -and -not $info.UserSid -and $info.Enabled -and $xml -like '*<GroupId>S-1-5-32-545</GroupId>*') $null
    Test-Check 'task xml: powershell.exe -WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File <program folder script>' ($info.Execute -like '*\powershell.exe' -and $info.Arguments -like '-WindowStyle Hidden -NoProfile *-ExecutionPolicy Bypass -File "X:\Fake\Program Files\AVDTune\Watermark\Show-AVDTuneWatermark.ps1"') $info.Arguments
    Test-Check 'task xml: least privilege, no time limit, one instance' ($xml -like '*<RunLevel>LeastPrivilege</RunLevel>*' -and $xml -like '*<ExecutionTimeLimit>PT0S</ExecutionTimeLimit>*' -and $xml -like '*<MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>*') $null
    $head = Get-AVDTuneTaskInfoFromXml (New-AVDTuneWatermarkTaskXml -Paths $paths -ConsoleMode Headless)
    Test-Check 'task xml: console mode Headless puts conhost --headless (full path) in front of the quoted full path of powershell.exe' ($head.Execute -eq 'X:\Fake\Windows\System32\conhost.exe' -and $head.Arguments -like '--headless "X:\Fake\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" -WindowStyle Hidden *') $head.Arguments
    $odd = [pscustomobject]@{ Script = 'C:\A & B\<x>.ps1'; PowerShell = 'C:\ps.exe'; Conhost = 'C:\conhost.exe' }
    $oddXml = New-AVDTuneWatermarkTaskXml -Paths $odd
    Test-Check 'task xml: special characters in a path are escaped (still well-formed)' ((Get-AVDTuneTaskInfoFromXml $oddXml).Arguments -like '*A & B\<x>.ps1*') $null
    Test-Check 'task info: a group given by name is translated to its SID' ((Get-AVDTuneTaskInfoFromXml ($legacyXml.Replace('S-1-5-32-545', 'BUILTIN\Users'))).GroupSid -eq 'S-1-5-32-545') $null

    # ---------------------------------------------------------------- steps, clean master
    $m = New-AVDTuneFakeMachine
    $st = Get-AVDTuneWatermarkStatus -Machine $m -Root $tmp
    Test-Check 'status of a clean master: not installed, no old overlay, Microsoft policy off, name preview' ($st.State -eq 'NotInstalled' -and -not $st.Legacy.Present -and -not $st.Microsoft -and $st.HostName -eq 'GM-TEST01' -and -not $st.HostMatch) "$($st.State) $($st.HostName)"
    Test-Check 'status reads only: nothing was written' ($m.Log.Count -eq 0) $m.Log.Count
    $cat = @(Get-AVDTuneWatermarkCatalog -Settings $saved -SourceRoot $sourceRoot -Root $tmp)
    Test-Check 'catalog: unique ids, section UserExperience, Test/Apply/Undo and an https source on every step' ((@($cat | ForEach-Object Id | Sort-Object -Unique).Count -eq $cat.Count) -and -not (@($cat | Where-Object { $_.Step.Section -ne 'UserExperience' -or -not $_.Step.Undo -or $_.Step.SourceUrl -notlike 'https://*' }).Count)) $cat.Count
    Test-Check 'On without the snapshot gate is refused and nothing is written' ((Test-Throws { Set-AVDTuneWatermark -Machine $m -Root $tmp -Mode On }) -and $m.Log.Count -eq 0) $null
    $dry = Set-AVDTuneWatermark -Machine $m -Root $tmp -Mode On -WhatIf
    Test-Check 'dry run: shows what would change, writes nothing (no run, no state)' ($dry.WhatIf -and @($dry.Results | Where-Object Status -eq 'WhatIf').Count -eq 3 -and $m.Log.Count -eq 0 -and @(Get-AVDTuneRun -Root $tmp).Count -eq 0 -and $null -eq (Get-AVDTuneProp (Get-AVDTuneState $tmp) 'Watermark')) $null

    Open-AVDTuneWriteGate -SnapshotId 'snap-1' -ConfirmedBy 'admin1'
    $on = Set-AVDTuneWatermark -Machine $m -Root $tmp -Mode On -User 'admin1' -SnapshotId 'snap-1'
    Test-Check 'On: program files, settings copy and task installed, state Installed' ($on.Changed -eq 3 -and $on.Failed -eq 0 -and $on.State -eq 'Installed') ($on.Results | ForEach-Object { "$($_.Id)=$($_.Status)" })
    $wr = @($m.Log | Where-Object { $_ -like 'FileWrite*' })
    Test-Check 'On: the program files go to Program Files\AVDTune\Watermark (Admin), the settings copy to AVDTune-Public (UsersRead), nothing under ProgramData\AVDTune' (($wr -join '|') -like '*Program Files\AVDTune\Watermark\Show-AVDTuneWatermark.ps1 (Admin)*' -and ($wr -join '|') -like '*ProgramData\AVDTune-Public\watermark.json (UsersRead)*' -and -not (@($m.Log | Where-Object { $_ -match 'ProgramData\\AVDTune[\\ ]' }).Count)) ($wr -join '|')
    Test-Check 'On: the task is registered at the root folder as "AVDTune Watermark"' (@($m.Log | Where-Object { $_ -eq 'TaskRegisterXml \AVDTune Watermark' }).Count -eq 1) $null
    Test-Check 'On: the copied overlay files are identical to the ones of the tool' (($m.FileText.Invoke('X:\Fake\Program Files\AVDTune\Watermark\Show-AVDTuneWatermark.ps1') -ceq [IO.File]::ReadAllText((Join-Path $sourceRoot 'Show-AVDTuneWatermark.ps1'))) -and ($m.FileText.Invoke('X:\Fake\Program Files\AVDTune\Watermark\AVDTune-WatermarkCore.ps1') -ceq [IO.File]::ReadAllText((Join-Path $sourceRoot 'AVDTune-WatermarkCore.ps1')))) $null
    $copy = ($m.FileText.Invoke('X:\Fake\ProgramData\AVDTune-Public\watermark.json') | ConvertFrom-Json)
    Test-Check 'On: the public copy carries the display settings only' ($copy.Pattern -eq '^avd-pilot-' -and $copy.Color -eq '#C62828' -and -not (Get-AVDTuneProp $copy 'Microsoft') -and -not (Get-AVDTuneProp $copy 'ConsoleMode')) $null
    $state = Get-AVDTuneState $tmp
    Test-Check 'On: LastChange (snapshot gate) and Watermark state are written' ($state.LastChange -and $state.Watermark -eq 'Installed') $null
    $log = @(Get-AVDTuneChangeLog -Root $tmp | Where-Object { $_.Component -eq 'Watermark' })
    Test-Check 'On: one change log entry (User experience, Added, with snapshot and run)' ($log.Count -eq 1 -and $log[0].Category -eq 'User experience' -and $log[0].ChangeType -eq 'Added' -and $log[0].SnapshotId -eq 'snap-1' -and $log[0].RunId -and $log[0].Source -eq 'Step') ($log | ConvertTo-Json -Compress)
    $runs = @(Get-AVDTuneRun -Root $tmp)
    Test-Check 'On: one run record with the three results' ($runs.Count -eq 1 -and @($runs[0].Results).Count -eq 3) $runs.Count

    $before = $m.Log.Count
    $again = Set-AVDTuneWatermark -Machine $m -Root $tmp -Mode On -User 'admin1' -SnapshotId 'snap-1'
    Test-Check 'On again: nothing changes (idempotent), no write, no change log entry' ($again.Changed -eq 0 -and $m.Log.Count -eq $before -and @(Get-AVDTuneChangeLog -Root $tmp | Where-Object { $_.Component -eq 'Watermark' }).Count -eq 1) $m.Log.Count

    # a name that matches: the preview says yes
    $mm = New-AVDTuneFakeMachine -Seed @{ ComputerName = 'AVD-PILOT-07' }
    Test-Check 'name preview: AVD-PILOT-07 would show the label' ((Get-AVDTuneWatermarkStatus -Machine $mm -Root $tmp).HostMatch) $null

    # ---------------------------------------------------------------- changed settings
    $new = Save-AVDTuneWatermarkSettings -Root $tmp -Settings @{ Pattern = '^avd-pilot-'; Text = 'PILOT'; Color = '#1565C0'; Opacity = 70; FontSize = 24; Corner = 'TopRight'; Margin = 8 }
    $st = Get-AVDTuneWatermarkStatus -Machine $m -Root $tmp
    $row = $st.Items | Where-Object Id -eq 'userexperience.watermark-settings'
    Test-Check 'changed settings: the settings copy is reported as differing, the rest stays' ($st.State -eq 'Partial' -and -not $row.Compliant -and $row.State -eq 'differs from the settings') "$($st.State) $($row.State)"
    $up = Set-AVDTuneWatermark -Machine $m -Root $tmp -Mode On -User 'admin1' -SnapshotId 'snap-1'
    Test-Check 'changed settings: On rewrites only the settings copy' ($up.Changed -eq 1 -and (Get-StepResult $up 'userexperience.watermark-settings').Status -eq 'Changed' -and (($m.FileText.Invoke('X:\Fake\ProgramData\AVDTune-Public\watermark.json') | ConvertFrom-Json).Text -eq 'PILOT')) $null
    $mode = Save-AVDTuneWatermarkSettings -Root $tmp -Settings @{ Pattern = '^avd-pilot-'; Text = 'PILOT'; Color = '#1565C0'; Opacity = 70; FontSize = 24; Corner = 'TopRight'; Margin = 8; ConsoleMode = 'Headless' }
    $st = Get-AVDTuneWatermarkStatus -Machine $m -Root $tmp
    Test-Check 'console mode Headless: the task is reported as another command until On is run' (($st.Items | Where-Object Id -eq 'userexperience.watermark-task').State -like '*other command*') (($st.Items | Where-Object Id -eq 'userexperience.watermark-task').State)
    [void](Set-AVDTuneWatermark -Machine $m -Root $tmp -Mode On -User 'admin1' -SnapshotId 'snap-1')
    Test-Check 'console mode Headless: On re-registers the task with conhost --headless' ((& $m.TaskDetail '\' 'AVDTune Watermark').Execute -eq 'X:\Fake\Windows\System32\conhost.exe' -and (Get-AVDTuneWatermarkStatus -Machine $m -Root $tmp).State -eq 'Installed') $null
    [void](Save-AVDTuneWatermarkSettings -Root $tmp -Settings @{ Pattern = '^avd-pilot-'; Text = 'PILOT'; Color = '#1565C0'; Opacity = 70; FontSize = 24; Corner = 'TopRight'; Margin = 8 })
    [void](Set-AVDTuneWatermark -Machine $m -Root $tmp -Mode On -User 'admin1' -SnapshotId 'snap-1')

    # a task changed from outside
    $t = & $m.TaskDetail '\' 'AVDTune Watermark'
    & $m.TaskRegisterXml '\' 'AVDTune Watermark' ($t.Xml.Replace('S-1-5-32-545', 'S-1-5-32-544'))
    $st = Get-AVDTuneWatermarkStatus -Machine $m -Root $tmp
    Test-Check 'a task for another group (changed from outside) is reported' (($st.Items | Where-Object Id -eq 'userexperience.watermark-task').State -like '*not for the group Users*') $null
    [void](Set-AVDTuneWatermark -Machine $m -Root $tmp -Mode On -User 'admin1' -SnapshotId 'snap-1')
    & $m.TaskSetEnabled '\' 'AVDTune Watermark' $false
    Test-Check 'a disabled task is reported' (((Get-AVDTuneWatermarkStatus -Machine $m -Root $tmp).Items | Where-Object Id -eq 'userexperience.watermark-task').State -like '*disabled*') $null
    [void](Set-AVDTuneWatermark -Machine $m -Root $tmp -Mode On -User 'admin1' -SnapshotId 'snap-1')

    # ---------------------------------------------------------------- unsafe folders
    $m2 = New-AVDTuneFakeMachine -Seed @{ Acl = @{ 'x:\fake\programdata\avdtune-public' = @{ Problems = @('write access for S-1-5-32-545') } } }
    $bad = Set-AVDTuneWatermark -Machine $m2 -Root $tmp -Mode On -User 'admin1' -SnapshotId 'snap-1'
    $r = Get-StepResult $bad 'userexperience.watermark-settings'
    Test-Check 'a settings folder that users can write to (prepared by someone else): nothing is written, the step fails' ($r.Status -eq 'Failed' -and $r.Message -like '*not safe*' -and -not (@($m2.Log | Where-Object { $_ -like 'FileWrite*AVDTune-Public*' }).Count)) $r.Message
    $m3 = New-AVDTuneFakeMachine -Seed @{
        Files = @{ 'X:\Fake\Program Files\AVDTune\Watermark\Show-AVDTuneWatermark.ps1' = 'x' }
        Acl = @{ 'x:\fake\program files\avdtune\watermark' = @{ Problems = @('write access for S-1-5-32-545') } }
    }
    $st3 = Get-AVDTuneWatermarkStatus -Machine $m3 -Root $tmp
    Test-Check 'a program folder with write access for others is reported as not safe' (($st3.Items | Where-Object Id -eq 'userexperience.watermark-program').State -like 'not safe*') $null

    # ---------------------------------------------------------------- failed write
    $m4 = New-AVDTuneFakeMachine
    $m4.Store.FailWrites = @('show-avdtunewatermark')
    $f4 = Set-AVDTuneWatermark -Machine $m4 -Root $tmp -Mode On -User 'admin1' -SnapshotId 'snap-1'
    Test-Check 'a refused write: the step fails with the reason, the others still run, LastChange and the change log say it failed' ($f4.Failed -ge 1 -and (Get-StepResult $f4 'userexperience.watermark-program').Status -eq 'Failed' -and @(Get-AVDTuneChangeLog -Root $tmp | Where-Object { $_.Text -like '*failed*' }).Count -ge 1) ($f4.Results | ForEach-Object { "$($_.Id)=$($_.Status)" })

    # ---------------------------------------------------------------- Microsoft policy
    $ms = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
    [void](Save-AVDTuneWatermarkSettings -Root $tmp -Settings @{ Pattern = '^avd-pilot-'; Text = 'PILOT'; Color = '#1565C0'; Opacity = 70; FontSize = 24; Corner = 'TopRight'; Margin = 8; Microsoft = @{ Enabled = $true; QrScale = 5; Opacity = 1500; WidthFactor = 320; HeightFactor = 180 } })
    $mo = Set-AVDTuneWatermark -Machine $m -Root $tmp -Mode On -User 'admin1' -SnapshotId 'snap-1'
    Test-Check 'Microsoft watermark on: fEnableWatermarking=1 and the four values are set' ((& $m.RegGet $ms 'fEnableWatermarking') -eq 1 -and (& $m.RegGet $ms 'WatermarkingQrScale') -eq 5 -and (& $m.RegGet $ms 'WatermarkingOpacity') -eq 1500 -and (& $m.RegGet $ms 'WatermarkingWidthFactor') -eq 320 -and (& $m.RegGet $ms 'WatermarkingHeightFactor') -eq 180 -and (Get-StepResult $mo 'userexperience.watermark-microsoft').Status -eq 'Changed') $null
    $msStep = (Get-AVDTuneWatermarkCatalog -Settings (Get-AVDTuneWatermarkSettings -Root $tmp).Settings -SourceRoot $sourceRoot -Root $tmp | Where-Object Id -eq 'userexperience.watermark-microsoft').Step
    Test-Check 'Microsoft watermark: medium risk, the reason names the client limits and what is not verified' ($msStep.Risk -eq 'Medium' -and $msStep.Why -like '*only clients that support watermarking*' -and $msStep.Why -like '*not verified*' -and $msStep.SourceUrl -like 'https://learn.microsoft.com/*') $null
    [void](Save-AVDTuneWatermarkSettings -Root $tmp -Settings @{ Pattern = '^avd-pilot-'; Text = 'PILOT'; Color = '#1565C0'; Opacity = 70; FontSize = 24; Corner = 'TopRight'; Margin = 8; Microsoft = @{ Enabled = $false } })
    $st = Get-AVDTuneWatermarkStatus -Machine $m -Root $tmp
    Test-Check 'Microsoft watermark switched off in the settings: still set on the master, reported, not part of the state' (($st.Items | Where-Object Id -eq 'userexperience.watermark-microsoft').State -like 'set, but switched off*' -and $st.State -eq 'Installed') $null
    $mo = Set-AVDTuneWatermark -Machine $m -Root $tmp -Mode On -User 'admin1' -SnapshotId 'snap-1'
    Test-Check 'Microsoft watermark: On with the switch off removes the policy' ($null -eq (& $m.RegGet $ms 'fEnableWatermarking') -and $null -eq (& $m.RegGet $ms 'WatermarkingQrScale') -and (Get-StepResult $mo 'userexperience.watermark-microsoft').Status -eq 'Reverted') $null
    $quiet = $m.Log.Count
    [void](Set-AVDTuneWatermark -Machine $m -Root $tmp -Mode On -User 'admin1' -SnapshotId 'snap-1')
    Test-Check 'Microsoft watermark: off and not set is not touched' ($m.Log.Count -eq $quiet) $null

    # ---------------------------------------------------------------- Off
    [void](Save-AVDTuneWatermarkSettings -Root $tmp -Settings @{ Pattern = '^avd-pilot-'; Text = 'PILOT'; Color = '#1565C0'; Opacity = 70; FontSize = 24; Corner = 'TopRight'; Margin = 8; Microsoft = @{ Enabled = $true } })
    [void](Set-AVDTuneWatermark -Machine $m -Root $tmp -Mode On -User 'admin1' -SnapshotId 'snap-1')
    # an older version of the files and other settings must not stop the removal
    $m.Store.Files['x:\fake\program files\avdtune\watermark\show-avdtunewatermark.ps1'].Text = 'older version'
    $off = Set-AVDTuneWatermark -Machine $m -Root $tmp -Mode Off -User 'admin1' -SnapshotId 'snap-1'
    Test-Check 'Off: task, both folders content and the Microsoft policy are removed (also an older version of the files)' ($off.Changed -eq 4 -and $off.State -eq 'NotInstalled' -and $null -eq (& $m.TaskDetail '\' 'AVDTune Watermark') -and $null -eq (& $m.FileText 'X:\Fake\ProgramData\AVDTune-Public\watermark.json') -and $null -eq (& $m.FileText 'X:\Fake\Program Files\AVDTune\Watermark\Show-AVDTuneWatermark.ps1') -and $null -eq (& $m.RegGet $ms 'fEnableWatermarking')) ($off.Results | ForEach-Object { "$($_.Id)=$($_.Status)" })
    Test-Check 'Off: the empty folders are removed too' (-not $m.Store.Folders.ContainsKey('x:\fake\programdata\avdtune-public') -and -not $m.Store.Folders.ContainsKey('x:\fake\program files\avdtune\watermark')) (@($m.Store.Folders.Keys) -join ', ')
    $log = @(Get-AVDTuneChangeLog -Root $tmp | Where-Object { $_.Component -eq 'Watermark' -and $_.ChangeType -eq 'Removed' })
    Test-Check 'Off: change log entry Removed' ($log.Count -eq 1 -and $log[0].Category -eq 'User experience') $null
    Test-Check 'Off again changes nothing' ((Set-AVDTuneWatermark -Machine $m -Root $tmp -Mode Off -User 'admin1' -SnapshotId 'snap-1').Changed -eq 0) $null

    # ---------------------------------------------------------------- old overlay
    $old = New-AVDTuneFakeMachine -Seed @{
        Tasks = @(@{ Path = '\'; Name = 'PilotOverlay'; Enabled = $true; Xml = $legacyXml }, @{ Path = '\'; Name = 'SomethingElse'; Enabled = $true })
        Files = @{ 'X:\Fake\ProgramData\PilotOverlayLauncher.vbs' = 'WScript.Echo "old"' }
    }
    $st = Get-AVDTuneWatermarkStatus -Machine $old -Root $tmp
    Test-Check 'old overlay: the task PilotOverlay and the VBS launcher are detected and shown as not in order' ($st.Legacy.Present -and $st.Legacy.Task.Name -eq 'PilotOverlay' -and $st.Legacy.Vbs -and (($st.Items | Where-Object Id -eq 'userexperience.watermark-legacy').State -eq 'task PilotOverlay + PilotOverlayLauncher.vbs')) (($st.Items | Where-Object Id -eq 'userexperience.watermark-legacy').State)
    $quiet = $old.Log.Count
    $viaOn = Set-AVDTuneWatermark -Machine $old -Root $tmp -Mode On -User 'admin1' -SnapshotId 'snap-1'
    Test-Check 'old overlay: Install alone never removes it (own confirmation)' ($null -ne (& $old.TaskDetail '\' 'PilotOverlay') -and -not (@($old.Log | Where-Object { $_ -like 'TaskRemove*' -or $_ -like 'FileRemove*' }).Count)) $null
    Test-Check 'old overlay: without the snapshot gate the removal is refused' ((Test-Throws { Close-AVDTuneWriteGate; Set-AVDTuneWatermark -Machine $old -Root $tmp -Mode LegacyRemove }) -and $null -ne (& $old.TaskDetail '\' 'PilotOverlay')) $null
    Open-AVDTuneWriteGate -SnapshotId 'snap-1' -ConfirmedBy 'admin1'
    $rm = Set-AVDTuneWatermark -Machine $old -Root $tmp -Mode LegacyRemove -User 'admin1' -SnapshotId 'snap-1'
    Test-Check 'old overlay: removed (task and VBS), other tasks stay' ($rm.Changed -eq 1 -and $null -eq (& $old.TaskDetail '\' 'PilotOverlay') -and $null -eq (& $old.FileText 'X:\Fake\ProgramData\PilotOverlayLauncher.vbs') -and $null -ne (& $old.TaskDetail '\' 'SomethingElse')) $null
    $bk = Read-AVDTuneJson @(Get-ChildItem (Join-Path $tmp 'config') -Filter 'watermark-legacy-*.json')[-1].FullName
    Test-Check 'old overlay: backup of the task definition and the launcher in the state folder' ($bk.Task.Xml -like '*PilotOverlayLauncher.vbs*' -and $bk.Vbs.Text -eq 'WScript.Echo "old"') $null
    $log = @(Get-AVDTuneChangeLog -Root $tmp | Where-Object { $_.Component -eq 'Watermark (old overlay)' })
    Test-Check 'old overlay: change log entry Removed' ($log.Count -eq 1 -and $log[0].ChangeType -eq 'Removed') $null
    $back = Set-AVDTuneWatermark -Machine $old -Root $tmp -Mode LegacyRestore -User 'admin1' -SnapshotId 'snap-1'
    Test-Check 'old overlay: restore puts the task and the launcher back' ($back.Changed -eq 1 -and (& $old.TaskDetail '\' 'PilotOverlay').Arguments -like '*PilotOverlayLauncher.vbs*' -and (& $old.FileText 'X:\Fake\ProgramData\PilotOverlayLauncher.vbs') -eq 'WScript.Echo "old"') $null
    $none = New-AVDTuneFakeMachine -Seed @{ Tasks = @(@{ Path = '\'; Name = 'PilotOverlay'; Enabled = $true; Xml = $legacyXml }) }
    Get-ChildItem (Join-Path $tmp 'config') -Filter 'watermark-legacy-*.json' | Remove-Item -Force
    $r = Get-StepResult (Set-AVDTuneWatermark -Machine $none -Root $tmp -Mode LegacyRestore -User 'admin1' -SnapshotId 'snap-1') 'userexperience.watermark-legacy'
    Test-Check 'old overlay: restore without a backup does nothing (the old task is simply there)' ($r.Status -eq 'Unchanged') $r.Status

    # ---------------------------------------------------------------- Finn M1: unsafe program folders and files, task only when ready
    Open-AVDTuneWriteGate -SnapshotId 'snap-1' -ConfirmedBy 'admin1'
    $ua = New-AVDTuneFakeMachine -Seed @{ Acl = @{ 'x:\fake\program files\avdtune' = @{ Problems = @('write access for S-1-5-32-545') } } }
    $r = Set-AVDTuneWatermark -Machine $ua -Root $tmp -Mode On -User 'admin1' -SnapshotId 'snap-1'
    Test-Check 'C:\Program Files\AVDTune with write access for users: nothing is written there, the program step fails with the reason' ((Get-StepResult $r 'userexperience.watermark-program').Status -eq 'Failed' -and (Get-StepResult $r 'userexperience.watermark-program').Message -like '*not safe*' -and -not (@($ua.Log | Where-Object { $_ -like 'FileWrite*Program Files*' }).Count)) ((Get-StepResult $r 'userexperience.watermark-program').Message)
    Test-Check 'program step failed: the task is not registered (Skipped with the reason)' ((Get-StepResult $r 'userexperience.watermark-task').Status -eq 'Skipped' -and -not (@($ua.Log | Where-Object { $_ -like 'TaskRegisterXml*' }).Count) -and $null -eq (& $ua.TaskDetail '\' 'AVDTune Watermark')) $null
    $uf = New-AVDTuneFakeMachine -Seed @{
        Files = @{ 'X:\Fake\Program Files\AVDTune\Watermark\Show-AVDTuneWatermark.ps1' = 'old' }
        Acl = @{ 'x:\fake\program files\avdtune\watermark\show-avdtunewatermark.ps1' = @{ Problems = @('write access for S-1-5-32-545') } }
    }
    $r = Set-AVDTuneWatermark -Machine $uf -Root $tmp -Mode On -User 'admin1' -SnapshotId 'snap-1'
    Test-Check 'an existing script file that users can write to is not overwritten and the task stays away' ((Get-StepResult $r 'userexperience.watermark-program').Status -eq 'Failed' -and $uf.FileText.Invoke('X:\Fake\Program Files\AVDTune\Watermark\Show-AVDTuneWatermark.ps1') -eq 'old' -and (Get-StepResult $r 'userexperience.watermark-task').Status -eq 'Skipped') $null
    $us = New-AVDTuneFakeMachine -Seed @{ Acl = @{ 'x:\fake\programdata\avdtune-public' = @{ Problems = @('write access for S-1-5-32-545') } } }
    $r = Set-AVDTuneWatermark -Machine $us -Root $tmp -Mode On -User 'admin1' -SnapshotId 'snap-1'
    Test-Check 'settings copy failed (unsafe folder): the task is not registered either' ((Get-StepResult $r 'userexperience.watermark-settings').Status -eq 'Failed' -and (Get-StepResult $r 'userexperience.watermark-task').Status -eq 'Skipped' -and -not (@($us.Log | Where-Object { $_ -like 'TaskRegisterXml*' }).Count)) $null
    $st = Get-AVDTuneWatermarkStatus -Machine $ua -Root $tmp
    Test-Check 'the status names the unsafe AVDTune folder' ((($st.Items | Where-Object Id -eq 'userexperience.watermark-program').State) -like '*Program Files\AVDTune: write access for S-1-5-32-545*') (($st.Items | Where-Object Id -eq 'userexperience.watermark-program').State)
    $dryTask = Set-AVDTuneWatermark -Machine (New-AVDTuneFakeMachine) -Root $tmp -Mode On -WhatIf
    Test-Check 'dry run still lists the task as it would change' ((Get-StepResult $dryTask 'userexperience.watermark-task').Status -eq 'WhatIf') $null

    # ---------------------------------------------------------------- Finn M1/N1/N2: the real writer in a temp folder (explicit protected ACL, no File.Replace, checks first)
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $wdir = Join-Path $tmp 'wacl\prog'; [void](New-Item -ItemType Directory -Path $wdir -Force)
    $wfile = Join-Path $wdir 'a.ps1'
    $sidsOf = { param($p) @((Read-AVDTuneAclReport $p).Rules | ForEach-Object { $_.Sid } | Sort-Object -Unique) -join ',' }
    [IO.File]::WriteAllText($wfile, 'old')   # inherits the ACL of the temp folder, like an existing file with an older ACL
    Write-AVDTuneAccessFile -Path $wfile -Text 'v1' -Access Admin -ExtraTrusted @($me)
    $rep = Read-AVDTuneAclReport $wfile
    Test-Check 'real writer: an existing file is replaced by one with the explicit protected ACL (Administrators, SYSTEM full, Users read only)' ([IO.File]::ReadAllText($wfile) -eq 'v1' -and $rep.Protected -and (& $sidsOf $wfile) -eq 'S-1-5-18,S-1-5-32-544,S-1-5-32-545' -and -not (@($rep.Rules | Where-Object { $_.Sid -eq 'S-1-5-32-545' -and $_.Write }).Count)) (& $sidsOf $wfile)
    $fsec = New-AVDTuneFileSecurity
    Test-Check 'real writer: the security object has no inheritance and no write for users' ($fsec.AreAccessRulesProtected -and -not (@($fsec.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]) | Where-Object { $_.IdentityReference.Value -eq 'S-1-5-32-545' -and (([int]$_.FileSystemRights) -band 0x40000006) }).Count)) $null
    $fi = New-Object IO.FileInfo $wfile
    $acl = $fi.GetAccessControl()
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-545'), 'Modify', 'Allow')))
    $fi.SetAccessControl($acl)
    $why = $null; try { Write-AVDTuneAccessFile -Path $wfile -Text 'v2' -Access Admin -ExtraTrusted @($me) } catch { $why = $_.Exception.Message }
    Test-Check 'real writer: a file that users can write to is not touched (checked before the write)' ($why -like '*not safe*write access for S-1-5-32-545*' -and [IO.File]::ReadAllText($wfile) -eq 'v1') $why
    $acl = $fi.GetAccessControl(); foreach ($r in @($acl.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]) | Where-Object { $_.IdentityReference.Value -eq 'S-1-5-32-545' })) { [void]$acl.RemoveAccessRule($r) }
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-545'), 'ReadAndExecute', 'Allow')))
    $fi.SetAccessControl($acl)
    $pfile = Join-Path $wdir 'post.ps1'
    if (-not (Test-AVDTuneElevated)) {
        # not elevated: the new file belongs to the current user, a foreign owner for the check after the write
        $why = $null; try { Write-AVDTuneAccessFile -Path $pfile -Text 'v1' -Access AdminNew } catch { $why = $_.Exception.Message }
        Test-Check 'real writer: the result is checked afterwards (without a trusted owner it is removed again and the call throws)' ($why -like '*unsafe ACL*owner is*' -and -not (Test-Path $pfile)) $why
    }
    else {
        # elevated (a CI runner): the new file belongs to Administrators, so the real result is safe; the check after the write is driven by a report with a foreign owner for this one file
        $ofile = Join-Path $wdir 'owner.ps1'
        Write-AVDTuneAccessFile -Path $ofile -Text 'v1' -Access AdminNew
        Test-Check 'real writer (elevated): the new file is owned by Administrators' ((Read-AVDTuneAclReport $ofile).Owner -eq 'S-1-5-32-544') (Read-AVDTuneAclReport $ofile).Owner
        $psmAVDTune = Get-Module AVDTune
        $origReport = & $psmAVDTune { ${function:script:Read-AVDTuneAclReport} }
        $why = $null
        try {
            & $psmAVDTune { param($Target, $Orig) Set-Item -Path function:script:Read-AVDTuneAclReport -Value ({ param([string]$Path) $r = & $Orig $Path; if ($Path -eq $Target -and $r.Exists) { $r.Owner = 'S-1-5-21-1-2-3-1001' }; $r }.GetNewClosure()) } $pfile $origReport
            try { Write-AVDTuneAccessFile -Path $pfile -Text 'v1' -Access AdminNew } catch { $why = $_.Exception.Message }
        }
        finally { & $psmAVDTune { param($Orig) Set-Item -Path function:script:Read-AVDTuneAclReport -Value $Orig } $origReport }
        Test-Check 'real writer: the result is checked afterwards (without a trusted owner it is removed again and the call throws)' ($why -like '*unsafe ACL*owner is*' -and -not (Test-Path $pfile)) $why
    }
    $nfile = Join-Path $wdir 'launcher.vbs'
    Write-AVDTuneAccessFile -Path $nfile -Text 'x' -Access AdminNew -ExtraTrusted @($me)
    $why = $null; try { Write-AVDTuneAccessFile -Path $nfile -Text 'y' -Access AdminNew -ExtraTrusted @($me) } catch { $why = $_.Exception.Message }
    Test-Check 'real writer: AdminNew creates the file and never replaces an existing one' ($why -like '*exists already*' -and [IO.File]::ReadAllText($nfile) -eq 'x') $why
    $fn = & (Get-Module AVDTune) { (Get-Item function:Write-AVDTuneAccessFile).ScriptBlock.ToString() }
    Test-Check 'real writer: does not use File.Replace (it keeps the old ACL)' ($fn -notmatch 'File\]::Replace' -and $fn -match 'CreateNew') $null
    $mapped = & (Get-Module AVDTune) { (Get-Item function:Read-AVDTuneAclReport).ScriptBlock.ToString() }
    Test-Check 'ACL report counts GENERIC_WRITE (0x40000000) and GENERIC_ALL (0x10000000) as write' ($mapped -like '*0x40000000*' -and $mapped -like '*0x10000000*') $null

    # ---------------------------------------------------------------- Finn N1/N4: old overlay restore, versioned backups
    $o2 = New-AVDTuneFakeMachine -Seed @{
        Tasks = @(@{ Path = '\'; Name = 'PilotOverlay'; Enabled = $true; Xml = $legacyXml })
        Files = @{ 'X:\Fake\ProgramData\PilotOverlayLauncher.vbs' = 'first' }
    }
    Set-AVDTuneWatermark -Machine $o2 -Root $tmp -Mode LegacyRemove -User 'admin1' -SnapshotId 'snap-1' | Out-Null
    $b1 = @(Get-ChildItem (Join-Path $tmp 'config') -Filter 'watermark-legacy-*.json')
    $first = [IO.File]::ReadAllText($b1[0].FullName)
    Set-AVDTuneWatermark -Machine $o2 -Root $tmp -Mode LegacyRestore -User 'admin1' -SnapshotId 'snap-1' | Out-Null
    & $o2.FileWrite 'X:\Fake\ProgramData\PilotOverlayLauncher.vbs' 'second' 'Admin'
    Set-AVDTuneWatermark -Machine $o2 -Root $tmp -Mode LegacyRemove -User 'admin1' -SnapshotId 'snap-1' | Out-Null
    $b2 = @(Get-ChildItem (Join-Path $tmp 'config') -Filter 'watermark-legacy-*.json')
    Test-Check 'a second removal makes a second backup file, the first one is not overwritten' ($b2.Count -eq $b1.Count + 1 -and [IO.File]::ReadAllText($b1[0].FullName) -eq $first) "$($b1.Count) -> $($b2.Count)"
    # tamper with the newest backup: another path, another task name
    $newest = @($b2 | Sort-Object Name)[-1]
    $j = Read-AVDTuneJson $newest.FullName
    $j.Vbs.Path = 'X:\Fake\Elsewhere\evil.vbs'; $j.Task.Name = 'EvilTask'
    [IO.File]::WriteAllText($newest.FullName, ($j | ConvertTo-Json -Depth 5))
    Set-AVDTuneWatermark -Machine $o2 -Root $tmp -Mode LegacyRestore -User 'admin1' -SnapshotId 'snap-1' | Out-Null
    Test-Check 'restore: the newest backup is used, only the fixed launcher path and the task name PilotOverlay (paths and names in the file are ignored), created as new' ((& $o2.FileText 'X:\Fake\ProgramData\PilotOverlayLauncher.vbs') -eq 'second' -and $null -eq (& $o2.FileText 'X:\Fake\Elsewhere\evil.vbs') -and $null -ne (& $o2.TaskDetail '\' 'PilotOverlay') -and $null -eq (& $o2.TaskDetail '\' 'EvilTask') -and (@($o2.Log | Where-Object { $_ -like '*PilotOverlayLauncher.vbs (AdminNew)' }).Count -eq 2)) ($o2.Log -join '|')
    # a launcher that is there again is not replaced
    $o3 = New-AVDTuneFakeMachine -Seed @{ Tasks = @(@{ Path = '\'; Name = 'PilotOverlay'; Enabled = $true; Xml = $legacyXml }); Files = @{ 'X:\Fake\ProgramData\PilotOverlayLauncher.vbs' = 'orig' } }
    Set-AVDTuneWatermark -Machine $o3 -Root $tmp -Mode LegacyRemove -User 'admin1' -SnapshotId 'snap-1' | Out-Null
    & $o3.FileWrite 'X:\Fake\ProgramData\PilotOverlayLauncher.vbs' 'someone else' 'Admin'
    $legStep = (Get-AVDTuneWatermarkCatalog -Settings (Get-AVDTuneWatermarkSettings -Root $tmp).Settings -SourceRoot $sourceRoot -Root $tmp | Where-Object Id -eq 'userexperience.watermark-legacy').Step
    $why = $null; try { & $legStep.Undo $o3 } catch { $why = $_.Exception.Message }
    Test-Check 'restore: a launcher that is there again is never replaced (the restore throws, the file stays)' ($why -like '*exists already*' -and (& $o3.FileText 'X:\Fake\ProgramData\PilotOverlayLauncher.vbs') -eq 'someone else' -and $null -eq (& $o3.TaskDetail '\' 'PilotOverlay')) $why
    # ---------------------------------------------------------------- real helpers (read only)
    $folder = Join-Path $tmp 'acl'; [void](New-Item -ItemType Directory -Path $folder)
    $rep = Read-AVDTuneAclReport $folder
    Test-Check 'real ACL report: a folder made by the current user is reported (owner is not Administrators unless elevated)' ($rep.Exists -and $rep.Owner -and $rep.Rules.Count -ge 1) $rep.Owner
    Test-Check 'ACL problems: write access of a user group, a foreign owner and a link are named' ((Get-AVDTuneAclProblems ([pscustomobject]@{ Exists = $true; Link = $false; Owner = 'S-1-5-32-544'; Rules = @([pscustomobject]@{ Sid = 'S-1-5-32-545'; Write = $true }, [pscustomobject]@{ Sid = 'S-1-5-32-545'; Write = $false }) })) -contains 'write access for S-1-5-32-545' -and (Get-AVDTuneAclProblems ([pscustomobject]@{ Exists = $true; Link = $true; Owner = 'S-1-5-21-1-2-3-1000'; Rules = @() })).Count -eq 2 -and @(Get-AVDTuneAclProblems ([pscustomobject]@{ Exists = $true; Link = $false; Owner = 'S-1-5-18'; Rules = @([pscustomobject]@{ Sid = 'S-1-5-32-544'; Write = $true }, [pscustomobject]@{ Sid = 'S-1-5-32-545'; Write = $false }) })).Count -eq 0) $null
    $sec = New-AVDTuneUsersReadSecurity
    $rules = @($sec.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]))
    $usersRule = $rules | Where-Object { $_.IdentityReference.Value -eq 'S-1-5-32-545' }
    Test-Check 'folder security for the settings copy: protected, Users read and execute only, Administrators and SYSTEM full' ($sec.AreAccessRulesProtected -and $usersRule.FileSystemRights -eq 'ReadAndExecute, Synchronize' -and @($rules | Where-Object { $_.FileSystemRights -eq 'FullControl' }).Count -eq 2 -and $rules.Count -eq 3) ($rules | ForEach-Object { "$($_.IdentityReference.Value)=$($_.FileSystemRights)" })

    # ---------------------------------------------------------------- the overlay script (child processes, nothing is shown)
    $ps = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $clean = "$env:USERPROFILE\Documents\WindowsPowerShell\Modules;$env:ProgramFiles\WindowsPowerShell\Modules;$env:SystemRoot\System32\WindowsPowerShell\v1.0\Modules"
    function Invoke-Overlay([string[]]$Arguments) {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $ps; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        $psi.EnvironmentVariables['PSModulePath'] = $clean
        $psi.Arguments = '-NoProfile -STA -ExecutionPolicy Bypass -File "' + (Join-Path $sourceRoot 'Show-AVDTuneWatermark.ps1') + '" ' + (($Arguments | ForEach-Object { ConvertTo-AVDTuneArgument $_ }) -join ' ')
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $p = [Diagnostics.Process]::Start($psi)
        $out = $p.StandardOutput.ReadToEndAsync(); $err = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit(60000)) { try { $p.Kill() } catch { }; return [pscustomobject]@{ Exit = -1; Out = 'timeout'; Err = ''; Ms = 60000 } }
        [pscustomobject]@{ Exit = $p.ExitCode; Out = $out.Result; Err = $err.Result; Ms = $sw.ElapsedMilliseconds }
    }
    $json = Join-Path $tmp 'public-watermark.json'
    [IO.File]::WriteAllText($json, ((Get-AVDTuneWatermarkPublicSettings (Get-AVDTuneWatermarkSettings -Root $tmp).Settings) | ConvertTo-Json))
    $no = Invoke-Overlay @('-SettingsPath', $json, '-ComputerName', 'AVD-PROD-01')
    Test-Check 'overlay: a name that does not match exits at once with 0 and shows nothing' ($no.Exit -eq 0 -and -not $no.Out.Trim() -and -not $no.Err.Trim()) "exit $($no.Exit) $($no.Ms) ms $($no.Err)"
    $none = Invoke-Overlay @('-SettingsPath', (Join-Path $tmp 'missing.json'), '-ComputerName', 'AVD-PILOT-01', '-DryRun')
    Test-Check 'overlay: missing settings exit with code 2' ($none.Exit -eq 2) "exit $($none.Exit)"
    [IO.File]::WriteAllText($json + '.bad', '{"Pattern":"(","Text":"x"}')
    $bad = Invoke-Overlay @('-SettingsPath', ($json + '.bad'), '-ComputerName', 'AVD-PILOT-01', '-DryRun')
    Test-Check 'overlay: invalid settings exit with code 2' ($bad.Exit -eq 2) "exit $($bad.Exit)"
    $dry = Invoke-Overlay @('-SettingsPath', $json, '-ComputerName', 'AVD-PILOT-01', '-DryRun')
    $lines = @($dry.Out -split "`r?`n" | Where-Object { $_ -like 'window *' })
    $count = @([System.Windows.Forms.Screen]::AllScreens).Count
    Test-Check 'overlay: -DryRun creates one window per monitor, sized to the text (nothing is shown)' ($dry.Exit -eq 0 -and $lines.Count -eq $count -and -not (@($lines | Where-Object { $_ -match 'w=0 ' -or $_ -match 'h=0 ' }).Count)) "exit $($dry.Exit) lines=$($lines.Count) screens=$count $($dry.Err)"
    $styles = @($lines | ForEach-Object { if ($_ -match 'exstyle=0x([0-9A-F]+)') { [Convert]::ToInt64($Matches[1], 16) } })
    $want = 0x20 -bor 0x80000 -bor 0x80 -bor 0x08000000   # TRANSPARENT (click-through), LAYERED, TOOLWINDOW (no taskbar button), NOACTIVATE
    Test-Check 'overlay: every window is click-through, layered, a tool window and never activated' ($styles.Count -eq $count -and -not (@($styles | Where-Object { ($_ -band $want) -ne $want }).Count)) (($styles | ForEach-Object { '0x{0:X}' -f $_ }) -join ',')

    # display change without a timer: the hidden host window reacts to the messages
    $hook = Join-Path $tmp 'hook.ps1'
    @"
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms
. '$((Join-Path $sourceRoot 'Show-AVDTuneWatermark.ps1'))'
Add-Type -Namespace T -Name N -MemberDefinition '[DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, IntPtr l);'
`$script:count = 0
`$script:WmOnChange = { `$script:count++ }
`$h = New-WmHostHook
[void][T.N]::SendMessage(`$h.Handle, 0x7E, [IntPtr]32, [IntPtr]0)
[void][T.N]::SendMessage(`$h.Handle, 0x1A, [IntPtr]0x2F, [IntPtr]0)
[void][T.N]::SendMessage(`$h.Handle, 0x1A, [IntPtr]0x01, [IntPtr]0)
Write-Host "count=`$script:count"
"@ | Set-Content -LiteralPath $hook -Encoding ASCII
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $ps; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.EnvironmentVariables['PSModulePath'] = $clean
    $psi.Arguments = '-NoProfile -STA -ExecutionPolicy Bypass -File "' + $hook + '"'
    $p = [Diagnostics.Process]::Start($psi); $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync(); [void]$p.WaitForExit(60000)
    Test-Check 'overlay: WM_DISPLAYCHANGE and a changed work area trigger the redraw, other setting changes do not (no timer polling)' ($o.Result -like '*count=2*') "$($o.Result) $($e.Result)"
    $src = Get-Content -LiteralPath (Join-Path $sourceRoot 'Show-AVDTuneWatermark.ps1') -Raw
    Test-Check 'overlay: single instance per session (Local\ mutex), no Global\ mutex, no polling loop' ($src -like "*'Local\AVDTune-Watermark'*" -and $src -notlike '*Global\*' -and $src -notmatch 'Start-Sleep') $null

    # ---------------------------------------------------------------- hygiene
    foreach ($f in 'Watermark\AVDTune-WatermarkCore.ps1', 'Watermark\Show-AVDTuneWatermark.ps1', 'Modules\AVDTune.Watermark.psm1') {
        $bytes = [IO.File]::ReadAllBytes((Join-Path $repo $f))
        Test-Check "$f is plain ASCII" (-not (@($bytes | Where-Object { $_ -gt 127 }).Count)) $null
    }
}
finally {
    Remove-Item Env:\AVDTUNE_ROOT -ErrorAction SilentlyContinue
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
if ($script:failed -gt 0) { throw "$script:failed check(s) failed." }
