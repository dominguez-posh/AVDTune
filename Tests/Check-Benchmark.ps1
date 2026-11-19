#requires -Version 5.1
<#
.SYNOPSIS
    Checks the benchmark module (Modules\AVDTune.Benchmark.psm1) against the fake adapter and a temporary state folder: evaluation maths with the examples of
    docs\benchmark-design.md 2.2, the diskspd XML parser (fixture and made-up answers), diskspd download checks, preconditions, quiet mode with restore journal and
    crash repair, a complete fake run (score, result, state, change log), comparison rules, result checks (no secrets, integrity).
    Nothing starts a process, downloads or touches services of this computer.
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'Modules\AVDTune.psm1') -Force
Import-Module (Join-Path $repo 'Modules\AVDTune.Benchmark.psm1') -Force
. (Join-Path $PSScriptRoot 'Fakes\FakeMachine.ps1')
. (Join-Path $PSScriptRoot 'Fakes\FakeBench.ps1')

$script:failed = 0
function Test-Check([string]$Name, [bool]$Ok, $Detail) { if ($Ok) { "PASS $Name" } else { $script:failed++; "FAIL $Name" + $(if ($null -ne $Detail) { "  -> $Detail" }) } }
function Test-Throws([scriptblock]$Block) { try { & $Block | Out-Null; $false } catch { $true } }
function Get-ThrownText([scriptblock]$Block) { try { & $Block | Out-Null; $null } catch { $_.Exception.Message } }
function Get-Leftover($Bench, $Root) { @(Test-AVDTuneBenchmarkClean -Bench $Bench -Root $Root | Where-Object { $_ -notlike 'diskspd cache*' }) }
function Near([double]$a, [double]$b, [double]$tol) { [math]::Abs($a - $b) -le $tol }

$config = Get-AVDTuneBenchmarkConfig
$ref = Get-AVDTuneBenchmarkReference
function New-Master { New-AVDTuneFakeMachine -Seed @{ Services = @(@{ Name = 'wuauserv'; StartType = 'Manual'; Status = 'Running' }, @{ Name = 'UsoSvc'; StartType = 'Automatic'; Status = 'Running' }, @{ Name = 'WSearch'; StartType = 'Automatic'; Status = 'Running' }) } }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('avdtune-bench-' + [guid]::NewGuid().ToString('N'))
try {
    [void](Initialize-AVDTuneState -Root $tmp)
    [void](Start-AVDTuneImageVersion -Root $tmp -Date ([datetime]'2026-11-15') -User 'admin1')

    # ---------------------------------------------------------------- data
    Test-Check 'config: six categories, weights 30/25/20/10/10/5' ((@($config.categories.PSObject.Properties | ForEach-Object { $_.Value.weight }) -join ',') -eq '30,25,20,10,10,5') $null
    Test-Check 'reference is marked provisional (placeholder, not measured)' ($ref.Provisional -and $ref.Status -like '*nicht gemessen*') $ref.Status
    $missingRef = @($config.diskspd.tests | ForEach-Object { $_.measures } | ForEach-Object { $_.id } | Where-Object { -not $ref.Measures.PSObject.Properties[$_] })
    Test-Check 'every diskspd measure has a reference value' ($missingRef.Count -eq 0) ($missingRef -join ',')
    Test-Check 'diskspd pins: size, sha256 of zip and exe, version 2.3' ($config.diskspd.version -eq '2.3' -and $config.diskspd.zipSha256.Length -eq 64 -and $config.diskspd.exeSha256.Length -eq 64 -and $config.diskspd.zipBytes -eq 3606329) $null
    Test-Check 'invalid reference names are refused' (Test-Throws { Get-AVDTuneBenchmarkReference -Name '..\x' }) $null
    Test-Check 'category of an id by prefix' ((Get-AVDTuneBenchCategoryKey $config 'host.disk.rr.qd1.p50') -eq 'osdisk' -and (Get-AVDTuneBenchCategoryKey $config 'host.net.dns') -eq 'network' -and $null -eq (Get-AVDTuneBenchCategoryKey $config 'x.y')) $null

    # ---------------------------------------------------------------- maths (design 2.2, 3)
    Test-Check 'median odd, even' ((Get-AVDTuneBenchMedian @(3, 1, 2)) -eq 2 -and (Get-AVDTuneBenchMedian @(4, 1, 3, 2)) -eq 2.5) $null
    Test-Check 'CV of 1180, 1175, 1210 is 1.6 percent' (Near (Get-AVDTuneBenchCv @(1180, 1175, 1210)) 1.6 0.05) (Get-AVDTuneBenchCv @(1180, 1175, 1210))
    Test-Check 'CV of one value is 0' ((Get-AVDTuneBenchCv @(5)) -eq 0) $null
    Test-Check 'index higher/lower, reference is 1000' ((Near (Get-AVDTuneBenchIndex 18500 12000 higher) 1541.67 0.01) -and (Near (Get-AVDTuneBenchIndex 0.080 0.105 lower) 1312.5 0.001) -and (Get-AVDTuneBenchIndex 7 7 lower) -eq 1000) $null
    Test-Check 'index of zero or negative is refused' ((Test-Throws { Get-AVDTuneBenchIndex 0 1 higher }) -and (Test-Throws { Get-AVDTuneBenchIndex 1 -1 lower })) $null
    $disk = @((Get-AVDTuneBenchRound (Get-AVDTuneBenchIndex 0.080 0.105 lower)), (Get-AVDTuneBenchRound (Get-AVDTuneBenchIndex 18500 12000 higher)), (Get-AVDTuneBenchRound (Get-AVDTuneBenchIndex 250 200 higher)), (Get-AVDTuneBenchRound (Get-AVDTuneBenchIndex 2400 1900 higher)))
    Test-Check 'design example: indexes 1313, 1542, 1250, 1263' (($disk -join ',') -eq '1313,1542,1250,1263') ($disk -join ',')
    Test-Check 'design example: OS disk category 1337' ((Get-AVDTuneBenchRound (Get-AVDTuneBenchGeometricMean $disk)) -eq 1337) $null
    $hostScore = Get-AVDTuneBenchWeightedGeometricMean @(1180, 960, 1420, 1050, 1000, 880) @(25, 10, 20, 30, 10, 5)
    Test-Check 'design example: Host score 1123' ((Get-AVDTuneBenchRound $hostScore) -eq 1123) $hostScore
    Test-Check 'weights are relative, mismatched lengths are refused' ((Near (Get-AVDTuneBenchWeightedGeometricMean @(1180, 960, 1420, 1050, 1000, 880) @(175, 70, 140, 210, 70, 35)) $hostScore 1e-9) -and (Test-Throws { Get-AVDTuneBenchWeightedGeometricMean @(1) @(1, 2) })) $null
    Test-Check 'percentile (nearest rank)' ((Get-AVDTuneBenchPercentile @(1..20) 50) -eq 10 -and (Get-AVDTuneBenchPercentile @(1..20) 95) -eq 19) $null
    $ms = @(
        [pscustomobject]@{ Id = 'host.cpu.single'; Status = 'ok'; Index = 1180 }, [pscustomobject]@{ Id = 'host.mem.alloc'; Status = 'ok'; Index = 960 },
        [pscustomobject]@{ Id = 'host.disk.mix.qd32'; Status = 'ok'; Index = 1420 }, [pscustomobject]@{ Id = 'host.disp.warp.2d'; Status = 'ok'; Index = 1000 },
        [pscustomobject]@{ Id = 'host.net.dns'; Status = 'ok'; Index = 880 }, [pscustomobject]@{ Id = 'host.net.tcp.p50'; Status = 'failed'; Index = $null })
    $sc = Get-AVDTuneBenchmarkScores -Measures $ms -Config $config
    Test-Check 'score without applications: partial, missing apps, failed measure left out' ($sc.Partial -and $sc.Missing -contains 'apps' -and $sc.Categories['network'].measures -eq 1 -and $null -ne $sc.Host) ($sc.Missing -join ',')
    $sc0 = Get-AVDTuneBenchmarkScores -Measures @() -Config $config
    Test-Check 'no measure at all: no score' ($null -eq $sc0.Host -and $sc0.Missing.Count -eq 6) $null

    # ---------------------------------------------------------------- diskspd XML
    $fx = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Fixtures\diskspd\mixed-4threads.xml') -Raw
    $p = ConvertFrom-AVDTuneDiskspdXml -Xml $fx
    Test-Check 'diskspd fixture: seconds, IOPS (sum of threads / seconds), MiB/s' ((Near $p.Seconds 12 0.001) -and (Near $p.Iops (4 * 51856 / 12.0) 0.01) -and (Near $p.ReadMiBps (4 * 148717568 / 1MB / 12.0) 0.001)) "$($p.Iops) $($p.ReadMiBps)"
    Test-Check 'diskspd fixture: latency percentiles p50/p99 read and write' ((Near $p.ReadLatencyP50 1.502 1e-9) -and (Near $p.ReadLatencyP99 4.12 1e-9) -and (Near $p.WriteLatencyP50 1.87 1e-9) -and (Near $p.WriteLatencyP99 5.4 1e-9)) $null
    Test-Check 'diskspd (#108 N5): XML with a DOCTYPE is refused (no DTD, no resolver)' (Test-Throws { ConvertFrom-AVDTuneDiskspdXml -Xml ('<?xml version="1.0"?><!DOCTYPE Results [<!ENTITY x SYSTEM "file:///c:/windows/win.ini">]>' + $fx.Substring($fx.IndexOf('<Results'))) }) $null
    Test-Check 'diskspd: not XML, no TimeSpan, no targets are errors' ((Test-Throws { ConvertFrom-AVDTuneDiskspdXml -Xml 'nope' }) -and (Test-Throws { ConvertFrom-AVDTuneDiskspdXml -Xml '<Results/>' }) -and (Test-Throws { ConvertFrom-AVDTuneDiskspdXml -Xml '<Results><TimeSpan><TestTimeSeconds>5</TestTimeSeconds></TimeSpan></Results>' })) $null
    Test-Check 'diskspd: a missing percentile is $null, not a guess' ($null -eq (ConvertFrom-AVDTuneDiskspdXml -Xml ($fx -replace '<Percentile>99</Percentile>', '<Percentile>98</Percentile>')).ReadLatencyP99) $null
    Test-Check 'diskspd: decimal numbers parse the same in any culture' ((& { $old = [Threading.Thread]::CurrentThread.CurrentCulture; try { [Threading.Thread]::CurrentThread.CurrentCulture = 'de-DE'; (ConvertFrom-AVDTuneDiskspdXml -Xml $fx).ReadLatencyP50 } finally { [Threading.Thread]::CurrentThread.CurrentCulture = $old } }) -eq 1.502) $null

    # ---------------------------------------------------------------- diskspd download and checks
    $b = New-AVDTuneFakeBench -Reference $ref -Config $config
    $exe = Get-AVDTuneDiskspd -Bench $b -Root $tmp -Config $config
    Test-Check 'diskspd: downloaded, checked, copied to tools\diskspd' ((Test-Path -LiteralPath $exe) -and $exe -like '*tools\diskspd\diskspd.exe' -and ($b.Log -join '|') -like '*Download https://github.com/microsoft/diskspd/releases/download/v2.3/DiskSpd.ZIP*') $exe
    $b.Log.Clear()
    [void](Get-AVDTuneDiskspd -Bench $b -Root $tmp -Config $config)
    Test-Check 'diskspd: a checked exe is reused, no second download' (-not (($b.Log -join '|') -like '*Download*')) $null
    Remove-Item (Join-Path $tmp 'tools') -Recurse -Force
    $bad = New-AVDTuneFakeBench -Reference $ref -Config $config -Seed @{ ZipSha256 = ('00' * 32) }
    Test-Check 'diskspd: wrong ZIP hash stops the run and removes the file' ((Test-Throws { Get-AVDTuneDiskspd -Bench $bad -Root $tmp -Config $config }) -and -not (Test-Path (Join-Path $tmp 'tools\diskspd\DiskSpd.ZIP'))) $null
    $bad = New-AVDTuneFakeBench -Reference $ref -Config $config -Seed @{ ZipBytes = 123 }
    Test-Check 'diskspd: wrong ZIP size stops the run' (Test-Throws { Get-AVDTuneDiskspd -Bench $bad -Root $tmp -Config $config }) $null
    Remove-Item (Join-Path $tmp 'tools') -Recurse -Force -ErrorAction SilentlyContinue
    $bad = New-AVDTuneFakeBench -Reference $ref -Config $config -Seed @{ ExeSha256 = ('11' * 32) }
    Test-Check 'diskspd: wrong exe hash stops the run, no exe is left' ((Test-Throws { Get-AVDTuneDiskspd -Bench $bad -Root $tmp -Config $config }) -and -not (Test-Path (Join-Path $tmp 'tools\diskspd\diskspd.exe'))) $null
    Remove-Item (Join-Path $tmp 'tools') -Recurse -Force -ErrorAction SilentlyContinue
    $bad = New-AVDTuneFakeBench -Reference $ref -Config $config -Seed @{ SigStatus = 'NotSigned' }
    Test-Check 'diskspd: an invalid signature stops the run' ((Get-ThrownText { Get-AVDTuneDiskspd -Bench $bad -Root $tmp -Config $config }) -like '*signature*') $null
    Remove-Item (Join-Path $tmp 'tools') -Recurse -Force -ErrorAction SilentlyContinue
    $bad = New-AVDTuneFakeBench -Reference $ref -Config $config -Seed @{ SigSubject = 'CN=Someone Else' }
    Test-Check 'diskspd: a signature of another publisher stops the run' ((Get-ThrownText { Get-AVDTuneDiskspd -Bench $bad -Root $tmp -Config $config }) -like '*not signed by*') $null
    Remove-Item (Join-Path $tmp 'tools') -Recurse -Force -ErrorAction SilentlyContinue
    $bad = New-AVDTuneFakeBench -Reference $ref -Config $config -Seed @{ DownloadFails = $true }
    Test-Check 'diskspd: offline gives the hint to place the ZIP by hand' ((Get-ThrownText { Get-AVDTuneDiskspd -Bench $bad -Root $tmp -Config $config }) -like '*by hand*') $null
    Remove-Item (Join-Path $tmp 'tools') -Recurse -Force -ErrorAction SilentlyContinue

    # ---------------------------------------------------------------- preconditions
    $pre = Test-AVDTuneBenchmarkPreconditions -Bench $b -Root $tmp -Config $config
    Test-Check 'preconditions: all fine on a quiet fake' (@($pre | Where-Object { -not $_.Ok }).Count -eq 0) (($pre | Where-Object { -not $_.Ok } | ForEach-Object Text) -join ' ')
    $cases = @(
        @{ n = 'not elevated'; s = @{ Elevated = $false }; id = 'elevated' }, @{ n = 'another user session'; s = @{ Sessions = @(@{ Id = 3; User = 'CONTOSO\other' }) }; id = 'sessions' },
        @{ n = 'uptime 2 minutes'; s = @{ UptimeMinutes = 2 }; id = 'uptime' }, @{ n = 'CPU busy'; s = @{ CpuLoad = 45 }; id = 'idle' }, @{ n = 'little free space'; s = @{ FreeGiB = 3 }; id = 'space' },
        @{ n = 'no measure program'; s = @{ NoExe = $true }; id = 'engine' })
    foreach ($c in $cases) {
        $bb = New-AVDTuneFakeBench -Reference $ref -Config $config -Seed $c.s
        $all = @(Test-AVDTuneBenchmarkPreconditions -Bench $bb -Root $tmp -Config $config)
        $r = @($all | Where-Object { $_.Id -eq $c.id })[0]
        Test-Check "preconditions: $($c.n) blocks" (-not $r.Ok -and $r.Level -eq 'Blocker') $r.Text
    }
    $bb = New-AVDTuneFakeBench -Reference $ref -Config $config -Seed @{ Sessions = @(@{ Id = 3; User = 'CONTOSO\other' }) }
    Test-Check 'preconditions: the blocking session is named' ((@(Test-AVDTuneBenchmarkPreconditions -Bench $bb -Root $tmp -Config $config | Where-Object { $_.Id -eq 'sessions' })[0].Text) -like '*CONTOSO\other*') $null
    $bb = New-AVDTuneFakeBench -Reference $ref -Config $config -Seed @{ PendingReboot = $true; OnBattery = $true }
    $w = @(Test-AVDTuneBenchmarkPreconditions -Bench $bb -Root $tmp -Config $config | Where-Object { $_.Level -eq 'Warning' -and -not $_.Ok })
    Test-Check 'preconditions: pending reboot and battery are warnings only' ($w.Count -eq 2) $null
    $bb = New-AVDTuneFakeBench -Reference $ref -Config $config -Seed @{ UpdateBusyCalls = 3 }
    Test-Check 'update installation: waits until it ends' ((Wait-AVDTuneUpdateIdle -Bench $bb -Config $config) -and $bb.Store.Sleeps -eq 3) $null
    $bb = New-AVDTuneFakeBench -Reference $ref -Config $config -Seed @{ UpdateBusyCalls = 100000 }
    Test-Check 'update installation: gives up after the wait time' ((-not (Wait-AVDTuneUpdateIdle -Bench $bb -Config $config)) -and $bb.Store.Sleeps -eq 60) $bb.Store.Sleeps

    # ---------------------------------------------------------------- quiet mode, journal, crash
    $m = New-Master
    $b = New-AVDTuneFakeBench -Reference $ref -Config $config
    $q = Start-AVDTuneBenchmarkQuiet -Machine $m -Bench $b -Root $tmp -RunId 'r1'
    $svc = { param($n) (& $m.ServiceGet $n).Status }
    Test-Check 'quiet: Windows Update and indexer stopped, start types unchanged' ((& $svc 'wuauserv') -eq 'Stopped' -and (& $svc 'UsoSvc') -eq 'Stopped' -and (& $svc 'WSearch') -eq 'Stopped' -and (& $m.ServiceGet 'wuauserv').StartType -eq 'Manual' -and (& $m.ServiceGet 'UsoSvc').StartType -eq 'Automatic' -and -not ($m.Log -join '|' -like '*ServiceSetStartup*')) ($m.Log -join '|')
    Test-Check 'quiet: journal and restore task exist, journal written before the stops' ((Test-Path (Get-AVDTuneBenchmarkJournalPath $tmp)) -and $b.Store.Tasks.ContainsKey('AVDTune-BenchmarkRestore')) $null
    $script = Get-Content -LiteralPath (Get-AVDTuneBenchmarkRestoreScriptPath $tmp) -Raw
    Test-Check 'restore script: ASCII, only the three service names, removes journal and task' (($script -notmatch '[^\x00-\x7F]') -and $script -like "*'wuauserv', 'UsoSvc', 'WSearch'*" -and $script -like '*Unregister-ScheduledTask*AVDTune-BenchmarkRestore*') $null
    Test-Check 'restore script: a bad service name is refused' ((Test-Throws { New-AVDTuneBenchmarkRestoreScript -Root $tmp -Services @("x'; calc; '") })) $null
    Test-Check 'a second quiet start with a journal is refused' (Test-Throws { Start-AVDTuneBenchmarkQuiet -Machine $m -Bench $b -Root $tmp -RunId 'r2' }) $null
    $crash = Get-AVDTuneBenchmarkCrash -Root $tmp
    Test-Check 'crash: a journal at the next start is found (run id, services)' ($crash.RunId -eq 'r1' -and $crash.Services.Count -eq 3) $null
    Test-Check 'cleanliness check names the leftovers' ((Get-Leftover -Bench $b -Root $tmp).Count -ge 2) $null
    # #49: another live AVDTune process holds the change marker (a short sleeping process of this check stands in for it): the repair refuses and changes nothing
    $psiF = New-Object System.Diagnostics.ProcessStartInfo (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'); $psiF.Arguments = '-NoProfile -NonInteractive -Command Start-Sleep -Seconds 60'; $psiF.UseShellExecute = $false; $psiF.CreateNoWindow = $true
    $foreign = [Diagnostics.Process]::Start($psiF)
    try {
        Start-Sleep -Milliseconds 500
        [void](Set-AVDTuneState -Root $tmp -Values @{ ChangeInProgress = [ordered]@{ Started = [datetime]::UtcNow.ToString('o'); Pid = $foreign.Id; ProcessStart = $foreign.StartTime.ToUniversalTime().ToString('o'); ProcessName = $foreign.ProcessName } })
        $tForeign = $(try { [void](Repair-AVDTuneBenchmarkCrash -Machine $m -Bench $b -Root $tmp -User 'admin1'); '' } catch { $_.Exception.Message })
        Test-Check 'repair (#49): while another AVDTune process holds the change marker the repair is refused, services stay stopped, the journal stays' ($tForeign -like '*Another AVDTune process*' -and (& $svc 'wuauserv') -eq 'Stopped' -and (Test-Path (Get-AVDTuneBenchmarkJournalPath $tmp))) $tForeign
    }
    finally { [void](Set-AVDTuneState -Root $tmp -Values @{ ChangeInProgress = $null }); try { if (-not $foreign.HasExited) { $foreign.Kill() } } catch { } }
    $fix = Repair-AVDTuneBenchmarkCrash -Machine $m -Bench $b -Root $tmp -User 'admin1'
    Test-Check 'repair: services running again, journal, script and task gone, change log note' ($fix.Repaired -and (& $svc 'wuauserv') -eq 'Running' -and (& $svc 'WSearch') -eq 'Running' -and -not (Test-Path (Get-AVDTuneBenchmarkJournalPath $tmp)) -and -not $b.Store.Tasks.ContainsKey('AVDTune-BenchmarkRestore') -and @(Get-AVDTuneChangeLog -Root $tmp | Where-Object { $_.Category -eq 'Benchmark' -and $_.Text -like 'Restored*' }).Count -eq 1) $fix.Message
    Test-Check 'repair without a journal does nothing' (-not (Repair-AVDTuneBenchmarkCrash -Machine $m -Bench $b -Root $tmp).Repaired) $null
    Test-Check 'clean again after the repair' ((Get-Leftover -Bench $b -Root $tmp).Count -eq 0) $null
    # a service that was already stopped is not started; one that is Disabled stays off
    $m2 = New-AVDTuneFakeMachine -Seed @{ Services = @(@{ Name = 'wuauserv'; StartType = 'Manual'; Status = 'Stopped' }, @{ Name = 'UsoSvc'; StartType = 'Automatic'; Status = 'Running' }) }
    $q2 = Start-AVDTuneBenchmarkQuiet -Machine $m2 -Bench $b -Root $tmp -RunId 'r3'
    Test-Check 'quiet: only running services are planned, missing ones are ignored' (($q2.Planned -join ',') -eq 'UsoSvc') ($q2.Planned -join ',')
    $m2.Store.Services['usosvc'].StartType = 'Disabled'
    [void](Stop-AVDTuneBenchmarkQuiet -Machine $m2 -Bench $b -Root $tmp)
    Test-Check 'restore: a service that is Disabled now is not started, a stopped one is not touched' ((& $m2.ServiceGet 'UsoSvc').Status -eq 'Stopped' -and (& $m2.ServiceGet 'wuauserv').Status -eq 'Stopped') $null
    $m0 = New-AVDTuneFakeMachine -Seed @{}
    $q0 = Start-AVDTuneBenchmarkQuiet -Machine $m0 -Bench $b -Root $tmp -RunId 'r0'
    Test-Check 'quiet: nothing running to pause works (empty list), and is cleaned up' (@($q0.Planned).Count -eq 0 -and (Stop-AVDTuneBenchmarkQuiet -Machine $m0 -Bench $b -Root $tmp).Clean -and (Get-Leftover -Bench $b -Root $tmp).Count -eq 0) $null
    $m3 = New-Master; $m3.Store.FailWrites = @()
    [void](Start-AVDTuneBenchmarkQuiet -Machine $m3 -Bench $b -Root $tmp -RunId 'r4')
    $m3.ServiceStart = { param($n) throw 'fake: cannot start' }
    $back = Stop-AVDTuneBenchmarkQuiet -Machine $m3 -Bench $b -Root $tmp
    Test-Check 'restore failure keeps the journal and the task for the next try' ((-not $back.Clean) -and (Test-Path (Get-AVDTuneBenchmarkJournalPath $tmp)) -and $b.Store.Tasks.ContainsKey('AVDTune-BenchmarkRestore')) $null
    $m3.ServiceStart = { param($n) $m3.Store.Services[$n.ToLowerInvariant()].Status = 'Running' }.GetNewClosure()
    [void](Stop-AVDTuneBenchmarkQuiet -Machine $m3 -Bench $b -Root $tmp)
    Test-Check 'second try cleans up' ((Get-Leftover -Bench $b -Root $tmp).Count -eq 0) $null
    $bt = New-AVDTuneFakeBench -Reference $ref -Config $config -Seed @{ TaskRegisterFails = $true }
    Test-Check 'quiet: the restore task could not be made, nothing is stopped' ((Test-Throws { Start-AVDTuneBenchmarkQuiet -Machine (New-Master) -Bench $bt -Root $tmp -RunId 'r5' }) -and (Test-Path (Get-AVDTuneBenchmarkJournalPath $tmp))) $null
    Remove-Item (Get-AVDTuneBenchmarkJournalPath $tmp), (Get-AVDTuneBenchmarkRestoreScriptPath $tmp) -Force -ErrorAction SilentlyContinue

    # ---------------------------------------------------------------- full fake run
    $m = New-Master
    $b = New-AVDTuneFakeBench -Reference $ref -Config $config -Seed @{ Factor = 1.2 }
    $seen = New-Object System.Collections.ArrayList
    # #92 (Finn M1): what the measure program says about the temporary standard user becomes a warning of the run
    $iw = @(Get-AVDTuneBenchIsolatedWarnings ([pscustomobject]@{ info = [pscustomobject]@{ isolatedUser = [pscustomobject]@{ used = $true; leftoversRemoved = @('avdtb-0123456789ab: removed'); cleanupProblem = 'the profile could not be deleted (error 32)' } } }))
    $iwNone = @(Get-AVDTuneBenchIsolatedWarnings ([pscustomobject]@{ info = [pscustomobject]@{ isolatedUser = [pscustomobject]@{ used = $true; leftoversRemoved = @(); cleanupProblem = $null } } }))
    $iwOld = @(Get-AVDTuneBenchIsolatedWarnings ([pscustomobject]@{ measures = @() }))
    Test-Check 'temporary user (#92 M1): a clean-up problem and removed leftovers become warnings; a clean run and an older result give none' ($iw.Count -eq 2 -and $iw[0] -like '*not removed completely*error 32*Finish refuses*' -and $iw[1] -like '*earlier run*avdtb-0123456789ab*' -and $iwNone.Count -eq 0 -and $iwOld.Count -eq 0) ($iw -join ' | ')
    $bIso = New-AVDTuneFakeBench -Reference $ref -Config $config -Seed @{ IsolatedInfo = [pscustomobject]@{ used = $true; leftoversRemoved = @(); cleanupProblem = 'the account could not be deleted (error 5)' } }
    $isoWarn = New-Object System.Collections.ArrayList
    [void](Invoke-AVDTuneBenchApps -Bench $bIso -WorkDir $tmp -Mode Quick -Warnings $isoWarn)
    $benchPage = [IO.File]::ReadAllText((Join-Path $repo 'AVDTune-Benchmark.ps1'))
    Test-Check 'temporary user (#92 M1): the warning of an apps run reaches the run (Warnings of Invoke-AVDTuneBenchRun into the result) and the page shows it and notes it in the protocol' ($isoWarn.Count -eq 1 -and $isoWarn[0] -like '*error 5*' -and $benchPage.Contains("Where-Object { [string]`$_ -like '*Temporary benchmark user*' }") -and $benchPage.Contains("-Subject ('Warning: ' + (`$userWarn -join ' '))")) ($isoWarn -join ' | ')
    $run = Invoke-AVDTuneBenchmark -Machine $m -Bench $b -Root $tmp -Mode Full -Kind baseline -User 'admin1' -SkipIdleCheck -Progress { param($t, $p) [void]$seen.Add($t) }
    $r = $run.Result
    Test-Check 'run: result stored under runs\benchmark, validates, no problems' ((Test-Path $run.Path) -and $run.Path -like '*runs\benchmark\*' -and (@(Test-AVDTuneBenchmarkResult -Result (Get-AVDTuneBenchmarkResult -Root $tmp -RunId $run.RunId)[0]).Count -eq 0)) (@(Test-AVDTuneBenchmarkResult -Result $r) -join ';')
    $diskCalls = @($b.Log | Where-Object { $_ -like 'Diskspd *' })
    Test-Check 'run: warm-up plus 3 runs, 5 diskspd tests each (20 calls), warm-up with the short duration' ($diskCalls.Count -eq 20 -and @($diskCalls | Where-Object { $_ -like '* -d5 *' }).Count -eq 5 -and @($diskCalls | Where-Object { $_ -like '* -d12 *' }).Count -eq 15) $diskCalls.Count
    Test-Check 'run: diskspd arguments come from the fixed templates and a work folder file' (@($diskCalls | Where-Object { $_ -match '-c4G .*benchmark\\work\\[\w-]+\\disk\.dat$' }).Count -eq 20 -and @($diskCalls | Where-Object { $_ -like '*-Sh*' -and $_ -like '*-Rxml*' }).Count -eq 20) $diskCalls[0]
    Test-Check 'run: sustained only in the first measured run' (@($b.Log | Where-Object { $_ -like 'RunBench cpu*--sustained*' }).Count -eq 1) $null
    $dl = @($r.measures | Where-Object id -eq 'host.cpu.single')[0]
    Test-Check 'run: a measure has 3 runs, median, CV, reference, index near 1200' (@($dl.runs).Count -eq 3 -and $dl.median -gt 0 -and $dl.cv -lt 5 -and $dl.reference -eq 0.30 -and $dl.index -ge 1190 -and $dl.index -le 1230) "$($dl.index)"
    Test-Check 'run: the median is the middle of the three noisy runs' ((Near $dl.median (Get-AVDTuneBenchMedian ([double[]]@($dl.runs))) 1e-12)) $null
    Test-Check 'run: lower-is-better measure is inverted (latency 1.2x better gives index about 1200)' ((@($r.measures | Where-Object id -eq 'host.disk.rr.qd1.p50')[0].index) -ge 1190 -and (@($r.measures | Where-Object id -eq 'host.disk.rr.qd1.p50')[0].index) -le 1230) $null
    Test-Check 'run: Host score about 1200 over six categories (applications included), not partial' ($r.scores.host.value -ge 1190 -and $r.scores.host.value -le 1230 -and -not $r.scores.host.partial -and @($r.scores.host.missingCategories).Count -eq 0 -and @($r.scores.host.categories.PSObject.Properties).Count -eq 6) $r.scores.host.value
    Test-Check 'run: marked provisional and nicht kalibriert because of the placeholder reference' ($r.scores.host.provisional -and $r.scores.host.uncalibrated -and $r.referenceInfo.provisional -and $run.Summary -like '*vorlaeufige Referenz*' -and $run.Summary -like '*nicht kalibriert*') $run.Summary
    Test-Check 'run: fslogix skipped (no share), gpu nicht vorhanden, mode full, kind baseline' ($r.scores.fslogix.status -eq 'skipped' -and $r.scores.fslogix.reason -like '*no FSLogix share*' -and $r.scores.gpu.status -eq 'unsupported' -and $r.scores.gpu.reason -eq 'nicht vorhanden' -and -not $r.share.used -and $r.mode -eq 'full' -and $r.kind -eq 'baseline') $null
    Test-Check 'run: system block from the adapter and the machine' ($r.system.vCpu -eq 8 -and $r.system.cpuModel -eq 'Fake CPU 3.0 GHz' -and $r.system.vmSize -eq 'Standard_D4s_v5' -and $r.system.imageVersion -eq '2026.11.001' -and $r.system.windows.build -eq 26100) $null
    Test-Check 'run: state has the summary, run id and (baseline, full) the baseline' ((Get-AVDTuneState $tmp).LastBenchmark -eq $run.Summary -and (Get-AVDTuneBenchmarkBaseline -Root $tmp).runId -eq $run.RunId) $null
    $log = @(Get-AVDTuneChangeLog -Root $tmp | Where-Object { $_.Category -eq 'Benchmark' -and $_.RunId -eq $run.RunId })
    Test-Check 'run: one change log entry with the scores' ($log.Count -eq 1 -and $log[0].Text -like 'Benchmark B1.0: Host*') $null
    Test-Check 'run: a benchmark is no change of the master (LastChange unaffected)' ($null -eq (Get-AVDTuneLastChange -Root $tmp) -or (Get-AVDTuneLastChange -Root $tmp) -lt (Get-Date).AddMinutes(-1) -or @(Get-AVDTuneChangeLog -Root $tmp | Where-Object { $_.Category -eq 'Benchmark' }).Count -ge 1) $null
    Test-Check 'run: services running again, nothing left behind, lock released' (((& $m.ServiceGet 'wuauserv').Status -eq 'Running') -and (Get-Leftover -Bench $b -Root $tmp).Count -eq 0 -and -not $b.Store.LockHeld) ((Get-Leftover -Bench $b -Root $tmp) -join ',')
    Test-Check 'run: progress was reported' ($seen.Count -gt 10 -and ($seen -join '|') -like '*Warm-up*') $seen.Count
    $text = Get-Content -LiteralPath $run.Path -Raw
    Test-Check 'run: no secret-like names or values in the file' ($text -notmatch '(?i)password|secret|token|accountkey|sas') $null
    $tampered = $text -replace '"value":\s+\d+', '"value": 1'
    Test-Check 'integrity: an edited file is detected' ((@(Test-AVDTuneBenchmarkResult -Result ($tampered | ConvertFrom-Json)).Count -ge 1)) $null
    $leak = Get-AVDTuneBenchmarkResult -Root $tmp -RunId $run.RunId | Select-Object -First 1
    $leak | Add-Member -NotePropertyName accountKey -NotePropertyValue 'abc' -Force
    Test-Check 'validation: a secret-like field name is reported' ((@(Test-AVDTuneBenchmarkResult -Result $leak) -join ' ') -like '*secret-like field name*') $null

    # ---------------------------------------------------------------- the run refuses
    $bb = New-AVDTuneFakeBench -Reference $ref -Config $config -Seed @{ Sessions = @(@{ Id = 4; User = 'x' }) }
    Test-Check 'a blocked run does not start: no quiet mode, no journal' ((Test-Throws { Invoke-AVDTuneBenchmark -Machine (New-Master) -Bench $bb -Root $tmp -SkipIdleCheck }) -and -not (Test-Path (Get-AVDTuneBenchmarkJournalPath $tmp)) -and -not ($bb.Log -join '|' -like '*Diskspd*')) $null
    $bb = New-AVDTuneFakeBench -Reference $ref -Config $config -Seed @{ LockBusy = $true }
    Test-Check 'another benchmark running: refused' ((Get-ThrownText { Invoke-AVDTuneBenchmark -Machine (New-Master) -Bench $bb -Root $tmp -SkipIdleCheck }) -like '*another benchmark*') $null
    Remove-Item (Join-Path $tmp 'tools') -Recurse -Force -ErrorAction SilentlyContinue
    $bb = New-AVDTuneFakeBench -Reference $ref -Config $config -Seed @{ ZipSha256 = ('00' * 32) }
    $m = New-Master
    Test-Check 'a diskspd mismatch stops before anything is paused' ((Test-Throws { Invoke-AVDTuneBenchmark -Machine $m -Bench $bb -Root $tmp -SkipIdleCheck }) -and (& $m.ServiceGet 'wuauserv').Status -eq 'Running' -and -not $bb.Store.LockHeld -and (Get-Leftover -Bench $bb -Root $tmp).Count -eq 0) $null
    Remove-Item (Join-Path $tmp 'tools') -Recurse -Force -ErrorAction SilentlyContinue

    # a group fails: the rest still counts, the error is in the result
    $bb = New-AVDTuneFakeBench -Reference $ref -Config $config -Seed @{ FailCommands = @('disp'); Offline = $true }
    $run2 = Invoke-AVDTuneBenchmark -Machine (New-Master) -Bench $bb -Root $tmp -Mode Quick -Kind manual -SkipIdleCheck
    Test-Check 'a failing group and no network: the other categories are scored, errors and failed measures say why' ($run2.Result.scores.host.missingCategories -contains 'display' -and $run2.Result.scores.host.missingCategories -contains 'network' -and @($run2.Result.info.errors).Count -ge 1 -and @($run2.Result.measures | Where-Object { $_.id -eq 'host.net.dns' -and $_.status -eq 'failed' -and $_.reason }).Count -eq 1 -and $null -ne $run2.Result.scores.host.value) ($run2.Result.info.errors -join ';')
    Test-Check 'quick mode: 1 run, marked quick, not the baseline' ($run2.Result.mode -eq 'quick' -and @($run2.Result.measures[0].runs).Count -eq 1 -and (Get-AVDTuneBenchmarkBaseline -Root $tmp).runId -eq $run.RunId) $null
    Test-Check 'a quick result cannot be set as the baseline' (Test-Throws { Set-AVDTuneBenchmarkBaseline -Root $tmp -RunId $run2.RunId }) $null

    # unstable measure
    $bb = New-AVDTuneFakeBench -Reference $ref -Config $config -Seed @{ RunNoise = @(1.0, 1.0, 1.4, 0.7) }
    $run3 = Invoke-AVDTuneBenchmark -Machine (New-Master) -Bench $bb -Root $tmp -Mode Full -Kind manual -SkipIdleCheck
    $u = @($run3.Result.measures | Where-Object id -eq 'host.cpu.single')[0]
    Test-Check 'unstable: CV above 10 percent is flagged, the score says unstable' ($u.unstable -and $u.cv -gt 10 -and $run3.Result.scores.host.unstable -and $run3.Summary -like '*instabil*') "$($u.cv)"

    # ---------------------------------------------------------------- comparison
    $prev = Get-AVDTuneBenchmarkResult -Root $tmp -RunId $run.RunId | Select-Object -First 1
    $same = Compare-AVDTuneBenchmark -Current $prev -Baseline $prev -Config $config
    Test-Check 'compare with itself: 0 percent everywhere, class same' ($same.Comparable -and $same.Host.DeltaPercent -eq 0 -and $same.Host.Class -eq 'same' -and @($same.Categories.Values | Where-Object { $_.DeltaPercent -ne 0 }).Count -eq 0) $null
    $b2 = New-AVDTuneFakeBench -Reference $ref -Config $config -Seed @{ Factor = 1.2; CategoryFactor = @{ osdisk = 1.5; cpu = 0.9 } }
    $run4 = Invoke-AVDTuneBenchmark -Machine (New-Master) -Bench $b2 -Root $tmp -Mode Full -Kind healthcheck -SkipIdleCheck
    $cmp = Compare-AVDTuneBenchmark -Current $run4.Result -Baseline $prev -Config $config
    Test-Check 'compare: disk better (+25 percent, over the 10 percent threshold), CPU worse (-25), memory same' ($cmp.Categories['osdisk'].Class -eq 'better' -and $cmp.Categories['cpu'].Class -eq 'worse' -and $cmp.Categories['memory'].Class -eq 'same' -and (Near $cmp.Categories['osdisk'].DeltaPercent 25 1.5) -and ($cmp.Categories['cpu'].DeltaPercent -lt -15 -and $cmp.Categories['cpu'].DeltaPercent -gt -26)) "$($cmp.Categories['osdisk'].DeltaPercent) $($cmp.Categories['cpu'].DeltaPercent)"
    Test-Check 'compare: a provisional reference is noted' (($cmp.Notes -join ' ') -like '*provisional*') $null
    Test-Check 'compare: quick against full is refused' ((-not (Compare-AVDTuneBenchmark -Current $run2.Result -Baseline $prev -Config $config).Comparable)) $null
    $other = $prev | ConvertTo-Json -Depth 12 | ConvertFrom-Json; $other.benchmarkVersion = 'B2.0'
    Test-Check 'compare: another major version is refused with the reason' ((-not (Compare-AVDTuneBenchmark -Current $prev -Baseline $other -Config $config).Comparable) -and (Compare-AVDTuneBenchmark -Current $prev -Baseline $other -Config $config).Reason -like '*not compared*') $null
    $minor = $prev | ConvertTo-Json -Depth 12 | ConvertFrom-Json; $minor.benchmarkVersion = 'B1.1'
    Test-Check 'compare: a minor version is comparable' ((Compare-AVDTuneBenchmark -Current $prev -Baseline $minor -Config $config).Comparable) $null
    $fewer = $prev | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $fewer.measures = @($fewer.measures | Where-Object { $_.id -ne 'host.disp.h264.video' })
    $cm = Compare-AVDTuneBenchmark -Current $prev -Baseline $fewer -Config $config
    Test-Check 'compare: a measure missing on one side gives "common measures" and a note' ($cm.CommonOnly -and ($cm.Notes -join ' ') -like '*common measures*') $null
    $nocat = $prev | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $nocat.measures = @($nocat.measures | Where-Object { $_.id -notlike 'host.net.*' })
    $cn = Compare-AVDTuneBenchmark -Current $prev -Baseline $nocat -Config $config
    Test-Check 'compare: a category on one side only is shown side by side without a delta' ($cn.Categories['network'].Class -eq 'side-by-side' -and $null -eq $cn.Categories['network'].DeltaPercent -and $null -ne $cn.Host) $null


    # ---------------------------------------------------------------- review follow-ups (Finn)
    $act = Get-AVDTuneBenchRestoreAction -ScriptPath 'C:\x\restore.ps1' -SystemFolder 'C:\Windows\System32'
    Test-Check 'restore task: Windows PowerShell by its full path, not a lookup through PATH' ($act.Execute -eq 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -and $act.Argument -like '*-File "C:\x\restore.ps1"') $act.Execute
    Test-Check 'restore task: the real system folder gives an existing powershell.exe' (Test-Path -LiteralPath (Get-AVDTuneBenchRestoreAction -ScriptPath 'x').Execute) $null
    $src = Get-Content -LiteralPath (Join-Path $repo 'Modules\AVDTune.Benchmark.psm1') -Raw
    $httpsGet = & (Get-Module AVDTune) { (Get-Command Invoke-AVDTuneHttpsGet).ScriptBlock.ToString() }
    Test-Check 'downloads go through Invoke-AVDTuneHttpsGet (#108 N3), which adds TLS 1.2 to the protocols and does not overwrite them' (([regex]::Matches($src, 'Invoke-AVDTuneHttpsGet -Url \$Url -AllowedHosts \$script:DownloadHosts')).Count -eq 2 -and $src -notmatch 'WebClient|SecurityProtocol = \[Net.SecurityProtocolType\]::Tls12' -and $httpsGet -match 'SecurityProtocol = \[Net.ServicePointManager\]::SecurityProtocol -bor') $null
    Test-Check 'the restore task uses no bare powershell.exe' ($src -notmatch "-Execute 'powershell.exe'") $null
    $b = New-AVDTuneFakeBench -Reference $ref -Config $config
    [void](Get-AVDTuneDiskspd -Bench $b -Root $tmp -Config $config)
    Test-Check 'cleanliness check names the diskspd cache, Remove-AVDTuneDiskspdCache clears it' ((@(Test-AVDTuneBenchmarkClean -Bench $b -Root $tmp) -join ',') -like '*diskspd cache*' -and (& { Remove-AVDTuneDiskspdCache -Root $tmp; @(Test-AVDTuneBenchmarkClean -Bench $b -Root $tmp).Count -eq 0 })) $null
    $before = @(Get-AVDTuneBenchmarkResult -Root $tmp).Count
    $mx = New-Master
    $msg = Get-ThrownText { Invoke-AVDTuneBenchmark -Machine $mx -Bench (New-AVDTuneFakeBench -Reference $ref -Config $config) -Root $tmp -Mode Quick -User 'x password=abc' -SkipIdleCheck }
    Test-Check 'a result with a secret-like value is not written, the run says why' ($msg -like '*not stored*secret-like*' -and @(Get-AVDTuneBenchmarkResult -Root $tmp).Count -eq $before) $msg
    Test-Check 'after that refusal the services are back and nothing is left behind' ((& $mx.ServiceGet 'wuauserv').Status -eq 'Running' -and (Get-Leftover -Bench $b -Root $tmp).Count -eq 0) $null
    $ov = New-AVDTuneFakeMachine -Seed @{}
    $row0 = @((Get-AVDTuneOverview -Machine $ov -Root $tmp).Health | Where-Object Id -eq 'benchmark')
    Write-AVDTuneFile (Get-AVDTuneBenchmarkJournalPath $tmp) '{"Schema":1,"RunId":"x","Started":"2026-11-15T10:00:00","Services":[],"Stopped":[]}'
    $row1 = @((Get-AVDTuneOverview -Machine $ov -Root $tmp).Health | Where-Object Id -eq 'benchmark')
    Test-Check 'Overview: an open restore journal shows a red Benchmark row, none without a journal' ($row0.Count -eq 0 -and $row1.Count -eq 1 -and $row1[0].Status -eq 'bad' -and $row1[0].Detail -like '*Benchmark page*') $null
    Remove-Item (Get-AVDTuneBenchmarkJournalPath $tmp) -Force

    # ---------------------------------------------------------------- the measure program: manifest entry, protected folder, hash before every start, no gap (issue #19)
    # A copy of a small system program stands in for AVDTune.Bench.exe (it really starts); the install folder is a temporary one (only inside the test mode: AVDTUNE_FAKE = a script below Tests plus AVDTUNE_ROOT, Test-AVDTuneTestMode).
    Import-Module (Join-Path $repo 'Modules\AVDTune.Release.psm1') -Force
    $oldFake = $env:AVDTUNE_FAKE; $oldRoot = $env:AVDTUNE_ROOT
    $fakeScript = Join-Path $PSScriptRoot 'Fakes\FakeMachine.ps1'
    $env:AVDTUNE_FAKE = $fakeScript; $env:AVDTUNE_ROOT = $tmp
    try {
        $inst = Join-Path $tmp 'install'; $app = Join-Path $inst '0.5.0'; $exeDir = Join-Path $app 'Bench\bin'; $exe = Join-Path $exeDir 'AVDTune.Bench.exe'
        $stand = Join-Path $tmp 'stand-in.exe'   # a tiny console program that prints JSON like the measure program does
        $standSrc = @"
using System; using System.Threading;
public static class StandIn { public static int Main(string[] a) {
  if (a.Length > 1 && a[0] == "env") { Console.Out.Write("{\"v\":\"" + (Environment.GetEnvironmentVariable(a[1]) ?? "<none>").Replace("\\", "\\\\") + "\"}"); return 0; }
  if (a.Length > 0 && a[0] == "hang") { var c = System.Diagnostics.Process.Start(System.Reflection.Assembly.GetExecutingAssembly().Location, "sleep"); Console.Out.Write("child:" + c.Id + "\n"); Console.Out.Flush(); Thread.Sleep(600000); return 0; }
  if (a.Length > 0 && a[0] == "sleep") { Thread.Sleep(600000); return 0; }
  if (a.Length > 0 && a[0] == "noisy") { for (int i = 0; i < 20000; i++) Console.Error.WriteLine("0123456789012345678901234567890123456789"); Console.Out.Write("{\"ok\":2}"); return 0; }
  Console.Out.Write("{\"ok\":1}"); return 0; } }
"@
        Add-Type -TypeDefinition $standSrc -OutputType ConsoleApplication -OutputAssembly $stand
        New-Item -ItemType Directory -Path $exeDir -Force | Out-Null
        Copy-Item -LiteralPath $stand -Destination $exe
        [IO.File]::WriteAllText((Join-Path $app 'VERSION'), '0.5.0'); [IO.File]::WriteAllText((Join-Path $app 'Start-AVDTune.ps1'), '# stand-in')
        $goodHash = Get-AVDTuneFileSha256 $exe; $goodSize = (Get-Item -LiteralPath $exe).Length
        function New-BenchManifest([string]$Hash, [bool]$WithBench = $true, [string]$Version = '0.5.0') {
            $files = @([ordered]@{ Path = 'Bench/bin/AVDTune.Bench.exe'; Size = $goodSize; Sha256 = $goodHash }, [ordered]@{ Path = 'Start-AVDTune.ps1'; Size = 10; Sha256 = ('c' * 64) }, [ordered]@{ Path = 'VERSION'; Size = 5; Sha256 = ('d' * 64) })
            $m = [ordered]@{ Schema = 1; Product = 'AVDTune'; Version = $Version; Commit = ('a' * 40); Date = '2026-11-20T10:00:00Z'; Prerelease = $false; Notes = ''; Zip = [ordered]@{ Name = "AVDTune-$Version.zip"; Size = 1000; Sha256 = ('b' * 64) }; Files = $files }
            if ($WithBench) { $m.Files[0].Sha256 = $Hash; $m.Bench = [ordered]@{ Path = 'Bench/bin/AVDTune.Bench.exe'; Size = $goodSize; Sha256 = $Hash } }
            ($m | ConvertTo-Json -Depth 6 | ConvertFrom-Json)
        }
        function Get-EnginePre($Adapter) { @(Test-AVDTuneBenchmarkPreconditions -Bench $Adapter -Root $tmp -Config $config -SkipIdleCheck | Where-Object { $_.Id -eq 'engine' })[0] }
        $okManifest = New-BenchManifest $goodHash
        $realAdapter = New-AVDTuneBenchAdapter -AppRoot $app -InstallRoot $inst -StateRoot $tmp -Manifest $okManifest
        # the checks run unelevated: a fake ACL reader stands in for the owner check of the bench TEMP folder (the real one wants Administrators as owner)
        $mod2 = Get-Module AVDTune.Benchmark
        $trustAll = { param($Path, $IsDirectory) [pscustomobject]@{ Owner = 'S-1-5-32-544'; Protected = $true; Rules = @([pscustomobject]@{ Sid = 'S-1-5-32-544'; Inherited = $false }) } }
        & $mod2 { $script:Hooks.AclReader = $args[0] } $trustAll
        $info = & $realAdapter.EngineInfo
        Test-Check 'measure program: in the install folder with the hash of the manifest it is accepted, the result carries the checked hash' ($info -and $info.Sha256 -ceq $goodHash -and $info.Verified -and $info.Path -ceq $exe -and (& $realAdapter.EngineProblem) -eq '') ($info | Out-String)
        $run = & $realAdapter.RunBench 'cpu' @('--quick')
        Test-Check 'measure program: RunBench starts the checked program and reads its JSON' ($run.ok -eq 1 -and (& { [IO.File]::AppendAllText($exe, ''); $true }) -eq $true) ($run | Out-String)
        $pre = Get-EnginePre $realAdapter
        Test-Check 'measure program: the precondition says it matches the release manifest' ($pre.Ok -and $pre.Text -like '*matches the release manifest*') $pre.Text

        # no gap between check and start: while the verified file is held it cannot be written, deleted, renamed or replaced, and it still starts
        $v = Open-AVDTuneVerifiedBenchExe -AppRoot $app -InstallRoot $inst -StateRoot $tmp -Manifest $okManifest
        try {
            $w = Get-ThrownText { $s = [IO.File]::Open($exe, 'Open', 'Write', 'ReadWrite'); $s.Dispose() }
            $d = Get-ThrownText { [IO.File]::Delete($exe) }
            $mv = Get-ThrownText { [IO.File]::Move($exe, "$exe.old") }
            $mvDir = Get-ThrownText { [IO.Directory]::Move($exeDir, "$exeDir-old") }
            $ov = Get-ThrownText { [IO.File]::Copy((Join-Path $env:SystemRoot 'System32\whoami.exe'), $exe, $true) }
            Test-Check 'measure program: held open, it cannot be written, deleted, renamed or overwritten, nor its folder renamed (no gap after the check)' ($w -and $d -and $mv -and $mvDir -and $ov) "$w | $d | $mv | $mvDir | $ov"
            $psi = New-Object System.Diagnostics.ProcessStartInfo; $psi.FileName = $v.Path; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardOutput = $true
            $pr = [System.Diagnostics.Process]::Start($psi); $null = $pr.StandardOutput.ReadToEnd(); [void]$pr.WaitForExit(20000); $code = $pr.ExitCode; $pr.Dispose()
            Test-Check 'measure program: the held file starts (read and execute stay shared)' ($code -eq 0) $code
        }
        finally { $v.Stream.Dispose() }
        Test-Check 'measure program: after the start the hold is released again' ((& { [IO.File]::AppendAllText($exe, 'x'); $true }) -eq $true) $null
        [IO.File]::WriteAllBytes($exe, [IO.File]::ReadAllBytes($stand))   # the original bytes again

        # wrong hash: nothing starts, the message names the manifest
        $badHash = New-BenchManifest ('9' * 64)
        $msg = Get-ThrownText { Open-AVDTuneVerifiedBenchExe -AppRoot $app -InstallRoot $inst -StateRoot $tmp -Manifest $badHash }
        Test-Check 'measure program: a hash that is not the one of the manifest is refused with a clear message' ($msg -like '*does not match the SHA256 in the release manifest*not started*') $msg
        $adBad = New-AVDTuneBenchAdapter -AppRoot $app -InstallRoot $inst -StateRoot $tmp -Manifest $badHash
        $runMsg = Get-ThrownText { & $adBad.RunBench 'cpu' @('--quick') }
        $preBad = Get-EnginePre $adBad
        Test-Check 'measure program: RunBench with a wrong hash starts nothing; the engine precondition is a blocker with the reason' ($runMsg -like '*does not match the SHA256*' -and $null -eq (& $adBad.EngineInfo) -and -not $preBad.Ok -and $preBad.Level -eq 'Blocker' -and $preBad.Text -like '*does not match*') $runMsg
        # the file is changed after the manifest was made: same size (hash differs) and a different size
        $orig = [IO.File]::ReadAllBytes($exe); $flip = $orig.Clone(); $flip[$flip.Length - 1] = [byte](($flip[$flip.Length - 1] + 1) % 256); [IO.File]::WriteAllBytes($exe, $flip)
        $m1 = Get-ThrownText { Open-AVDTuneVerifiedBenchExe -AppRoot $app -InstallRoot $inst -StateRoot $tmp -Manifest $okManifest }
        [IO.File]::WriteAllBytes($exe, $orig + [byte[]](1, 2, 3))
        $m2 = Get-ThrownText { Open-AVDTuneVerifiedBenchExe -AppRoot $app -InstallRoot $inst -StateRoot $tmp -Manifest $okManifest }
        [IO.File]::WriteAllBytes($exe, $orig)
        Test-Check 'measure program: a changed file (same size, other size) is refused, and nothing stays open afterwards' ($m1 -like '*does not match the SHA256*' -and $m2 -like '*size*not started*' -and (& { [IO.File]::AppendAllText($exe, ''); $true }) -eq $true) "$m1 | $m2"

        # child process of the measure program (issue #19): clean environment, TEMP in an administrators-only folder, async pipes, timeout ends the tree, extra files stop the start
        $env:DOTNET_AVDTUNE_TEST = 'evil'; $env:COMPlus_AVDTUNE_TEST = 'evil'; $env:AVDTUNE_KEEP_ME = 'kept'
        try {
            $e1 = & $realAdapter.RunBench 'env' @('DOTNET_AVDTUNE_TEST'); $e2 = & $realAdapter.RunBench 'env' @('COMPlus_AVDTUNE_TEST'); $e3 = & $realAdapter.RunBench 'env' @('AVDTUNE_KEEP_ME')
            Test-Check 'child process: DOTNET_ and COMPlus_ variables are not in the environment of the measure program (and no other variable of the caller is either)' ($e1.v -eq '<none>' -and $e2.v -eq '<none>' -and $e3.v -eq '<none>') "$($e1.v) $($e2.v) $($e3.v)"
        }
        finally { Remove-Item Env:\DOTNET_AVDTUNE_TEST, Env:\COMPlus_AVDTUNE_TEST, Env:\AVDTUNE_KEEP_ME -ErrorAction SilentlyContinue }
        $pv = (& $realAdapter.RunBench 'env' @('PATH')).v; $tv = (& $realAdapter.RunBench 'env' @('TEMP')).v; $tm = (& $realAdapter.RunBench 'env' @('TMP')).v
        Test-Check 'child process: PATH is System32 only, TEMP and TMP are the folder below the state folder' ($pv -ieq (Join-Path $env:SystemRoot 'System32') -and $tv -ieq (Join-Path $tmp 'temp\bench') -and $tm -ieq $tv -and (Test-Path -LiteralPath $tv)) "$pv | $tv | $tm"
        $keepSys = @{}; foreach ($k in 'windir', 'TEMP', 'TMP', 'ChocolateyInstall') { $keepSys[$k] = [Environment]::GetEnvironmentVariable($k, 'Process') }
        try {
            foreach ($k in $keepSys.Keys) { [Environment]::SetEnvironmentVariable($k, 'evil', 'Process') }
            $sysSeen = @('windir', 'SystemRoot', 'TEMP', 'TMP', 'ChocolateyInstall' | ForEach-Object { "$_=$((& $realAdapter.RunBench 'env' @($_)).v)" })
        }
        finally { foreach ($k in $keepSys.Keys) { [Environment]::SetEnvironmentVariable($k, $keepSys[$k], 'Process') } }
        Test-Check 'child process (#47): windir, TEMP and TMP set to evil in the caller (SystemRoot cannot be: it breaks this process) are the fixed values for the measure program (ChocolateyInstall is gone)' ($sysSeen -contains "windir=$([Environment]::GetFolderPath('Windows'))" -and $sysSeen -contains "SystemRoot=$([Environment]::GetFolderPath('Windows'))" -and $sysSeen -contains "TEMP=$(Join-Path $tmp 'temp\bench')" -and $sysSeen -contains "TMP=$(Join-Path $tmp 'temp\bench')" -and $sysSeen -contains 'ChocolateyInstall=<none>') ($sysSeen -join ' ')
        $evil = @('DOTNET_AVDTUNE_T', 'COREHOST_AVDTUNE_T', 'CORECLR_AVDTUNE_T', 'COMPlus_AVDTUNE_T', 'COR_AVDTUNE_T', '__COMPAT_LAYER', 'AVDTUNE_HKCU_LIKE', 'USERPROFILE_FAKE_AVDTUNE')
        foreach ($k in $evil) { [Environment]::SetEnvironmentVariable($k, 'evil') }
        try {
            $seen = @($evil | ForEach-Object { "$_=$((& $realAdapter.RunBench 'env' @($_)).v)" })
            Test-Check 'child process: environment allowlist: all five prefixes, __COMPAT_LAYER and any other variable are gone' (@($seen | Where-Object { $_ -notlike '*=<none>' }).Count -eq 0) ($seen -join ' ')
            $sr = (& $realAdapter.RunBench 'env' @('SystemRoot')).v; $np = (& $realAdapter.RunBench 'env' @('NUMBER_OF_PROCESSORS')).v; $pa = (& $realAdapter.RunBench 'env' @('PROCESSOR_ARCHITECTURE')).v
            Test-Check 'child process: the allowlisted variables (SystemRoot, NUMBER_OF_PROCESSORS, PROCESSOR_*) are passed on' ($sr -ieq $env:SystemRoot -and $np -eq $env:NUMBER_OF_PROCESSORS -and $pa -eq $env:PROCESSOR_ARCHITECTURE) "$sr $np $pa"
        }
        finally { foreach ($k in $evil) { [Environment]::SetEnvironmentVariable($k, $null) } }
        # TEMP folder (checklist: no links, no foreign rules, set aside, created in one step with its ACL)
        $benchTemp = Join-Path $tmp 'temp\bench'
        $first = & $mod2 { Initialize-AVDTuneBenchTemp -StateRoot $args[0] } $tmp
        Test-Check 'bench TEMP: created below the state folder; a second call reuses it' ($first -ieq $benchTemp -and (Test-Path -LiteralPath $benchTemp) -and (& $mod2 { Initialize-AVDTuneBenchTemp -StateRoot $args[0] } $tmp) -ieq $benchTemp -and @(Get-ChildItem (Join-Path $tmp 'temp') -Filter 'bench.untrusted-*').Count -eq 0) $first
        $acl = (New-Object IO.DirectoryInfo $benchTemp).GetAccessControl()
        $allowedSids = @('S-1-5-32-544', 'S-1-5-18') + $(if (-not (Test-AVDTuneElevated)) { [Security.Principal.WindowsIdentity]::GetCurrent().User.Value })
        Test-Check 'bench TEMP: created with a protected ACL (no inheritance; Administrators and SYSTEM only, plus the current user only when the check itself is not elevated)' ($acl.AreAccessRulesProtected -and @($acl.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]) | Where-Object { $_.IdentityReference.Value -notin $allowedSids }).Count -eq 0) $null
        $tempMark = Join-Path $benchTemp 'mark.txt'; [IO.File]::WriteAllText($tempMark, 'x')
        $tgt = Join-Path $tmp 'temp-link-target'; New-Item -ItemType Directory -Path $tgt | Out-Null; [IO.File]::WriteAllText((Join-Path $tgt 'keep.txt'), 'keep')
        Remove-Item -LiteralPath $benchTemp -Recurse -Force
        [void](New-Item -ItemType Junction -Path $benchTemp -Target $tgt)
        $viaJ = & $mod2 { Initialize-AVDTuneBenchTemp -StateRoot $args[0] } $tmp
        $aside = @(Get-ChildItem (Join-Path $tmp 'temp') -Filter 'bench.untrusted-*' -Force)
        Test-Check 'bench TEMP: a junction in its place is set aside as a link, the target is untouched, a new real folder is made' ($aside.Count -eq 1 -and (Test-Path (Join-Path $tgt 'keep.txt')) -and -not ((Get-Item -LiteralPath $viaJ -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) ($aside.Name -join ',')
        [IO.Directory]::Delete($aside[0].FullName)
        $mod2hooks = { $script:Hooks.AclReader = $args[0] }
        & $mod2 $mod2hooks ({ param($Path, $IsDirectory) $r = @([pscustomobject]@{ Sid = 'S-1-5-32-544'; Inherited = $false }); if ($Path -like '*\bench') { $r += [pscustomobject]@{ Sid = 'S-1-5-32-545'; Inherited = $false } }; [pscustomobject]@{ Owner = 'S-1-5-32-544'; Protected = $true; Rules = $r } })
        try {
            [IO.File]::WriteAllText((Join-Path $benchTemp 'prepared.txt'), 'x')
            $viaP = & $mod2 { Initialize-AVDTuneBenchTemp -StateRoot $args[0] } $tmp
            $aside = @(Get-ChildItem (Join-Path $tmp 'temp') -Filter 'bench.untrusted-*' -Force)
            Test-Check 'bench TEMP: a prepared folder (rule for users) is set aside with its content, not repaired' ($aside.Count -eq 1 -and (Test-Path (Join-Path $aside[0].FullName 'prepared.txt')) -and -not (Test-Path (Join-Path $viaP 'prepared.txt'))) ($aside.Name -join ',')
        }
        finally { & $mod2 $mod2hooks $trustAll }
        $srcBuild = Get-Content -LiteralPath (Join-Path $repo 'Bench\build.ps1') -Raw; $gj = Get-Content -LiteralPath (Join-Path $repo 'Bench\global.json') -Raw | ConvertFrom-Json
        Test-Check 'Bench build: runs from the Bench folder (Push-Location, Pop in finally) and stops when dotnet is not the SDK of global.json' ($srcBuild -match 'Push-Location \$PSScriptRoot' -and $srcBuild -match 'finally \{ Pop-Location \}' -and $srcBuild -match '\$sdk -ne \$want' -and $gj.sdk.version -match '^\d+\.\d+\.\d+$' -and $gj.sdk.rollForward -eq 'disable') $null
        $nc = Get-Content -LiteralPath (Join-Path $repo 'Bench\nuget.config') -Raw
        Test-Check 'Bench build: nuget.config has nuget.org as the only source with a package source mapping' ($nc -match '<clear />' -and $nc -match 'packageSourceMapping' -and ([regex]::Matches($nc, '<add key=')).Count -eq 1 -and $nc -match 'https://api.nuget.org/') $null
        $noisy = & $realAdapter.RunBench 'noisy' @()
        Test-Check 'child process: a program that writes a lot to stderr does not block (stderr is read at the same time)' ($noisy.ok -eq 2) $null
        $mod = Get-Module AVDTune.Benchmark; $mod2 = $mod
        & $mod { $script:Limits.BenchMs = 3000 }
        try {
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $hm = Get-ThrownText { & $realAdapter.RunBench 'hang' @() }
            $sw.Stop()
        }
        finally { & $mod { $script:Limits.BenchMs = 600000 } }
        Test-Check 'child process: a program that hangs is ended after the timeout with a clear message' ($hm -like '*did not finish in time*' -and $sw.Elapsed.TotalSeconds -lt 30) "$hm $($sw.Elapsed.TotalSeconds)"
        $hr = & $mod { Invoke-AVDTuneChildProcess -FileName $args[0] -Arguments 'hang' -TimeoutMs 40000 } $exe   # the program starts a child and prints its id first; process starts can take 5 s each on a loaded or scanned machine, so the timeout is generous
        $childId = [int](([regex]::Match($hr.Output, 'child:(\d+)')).Groups[1].Value)
        for ($w = 0; $w -lt 150 -and $childId -gt 0 -and (Get-Process -Id $childId -ErrorAction SilentlyContinue); $w++) { Start-Sleep -Milliseconds 100 }   # wait for the end of the process (the job ends it asynchronously), not a fixed time
        Test-Check 'child process: on a timeout the whole tree is ended, also the process it started' ($hr.TimedOut -and $childId -gt 0 -and $null -eq (Get-Process -Id $childId -ErrorAction SilentlyContinue)) ($hr | Out-String)
        $extra = Join-Path $exeDir 'evil.dll'; [IO.File]::WriteAllBytes($extra, [byte[]](1, 2, 3))
        $msg = Get-ThrownText { Open-AVDTuneVerifiedBenchExe -AppRoot $app -InstallRoot $inst -StateRoot $tmp -Manifest $okManifest }
        Remove-Item -LiteralPath $extra -Force
        Test-Check 'measure program: an extra DLL next to the exe stops the start' ($msg -like '*holds more than the exe*evil.dll*not started*') $msg
        $okAgain = Open-AVDTuneVerifiedBenchExe -AppRoot $app -InstallRoot $inst -StateRoot $tmp -Manifest $okManifest; $okAgain.Stream.Dispose()
        $bad64 = New-BenchManifest ($goodHash.ToUpperInvariant())
        Test-Check 'manifest validation: an upper-case or longer hash is not a hash' ((Get-ThrownText { Assert-AVDTuneManifest $bad64 '0.5.0' }) -like '*bad hash*' -and (Get-ThrownText { Assert-AVDTuneManifest (New-BenchManifest ($goodHash + "`n")) '0.5.0' }) -like '*bad hash*') $null
        # no manifest entry
        $noEntry = New-BenchManifest $goodHash $false
        $msg = Get-ThrownText { Open-AVDTuneVerifiedBenchExe -AppRoot $app -InstallRoot $inst -StateRoot $tmp -Manifest $noEntry }
        $adNo = New-AVDTuneBenchAdapter -AppRoot $app -InstallRoot $inst -StateRoot $tmp -Manifest $noEntry
        $preNo = Get-EnginePre $adNo
        Test-Check 'measure program: a manifest without a Bench entry means no start, with a clear message and a blocking precondition' ($msg -like '*no entry for AVDTune.Bench.exe*does not start*' -and $null -eq (& $adNo.EngineInfo) -and (Get-ThrownText { & $adNo.RunBench 'mem' @() }) -like '*no entry*' -and -not $preNo.Ok -and $preNo.Text -like '*no entry*') $msg
        # manifest of another version
        $msg = Get-ThrownText { Open-AVDTuneVerifiedBenchExe -AppRoot $app -InstallRoot $inst -StateRoot $tmp -Manifest (New-BenchManifest $goodHash $true '0.6.0') }
        Test-Check 'measure program: the manifest of another version is not used' ($msg -like '*not valid*0.6.0*') $msg
        # no manifest anywhere: none saved
        $msg = Get-ThrownText { Open-AVDTuneVerifiedBenchExe -AppRoot $app -InstallRoot $inst -StateRoot (Join-Path $tmp 'empty-state') }
        Test-Check 'measure program: without a saved manifest it is not started' ($msg -like '*No release manifest of version 0.5.0*not started*') $msg
        # the saved manifest (written at install time) is what a normal start uses
        New-Item -ItemType Directory -Path (Join-Path $tmp 'release') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $tmp 'release\manifest-0.5.0.json'), ($okManifest | ConvertTo-Json -Depth 6))
        $viaCache = Open-AVDTuneVerifiedBenchExe -AppRoot $app -InstallRoot $inst -StateRoot $tmp
        $viaCache.Stream.Dispose()
        Test-Check 'measure program: with the manifest saved at install time it is accepted without -Manifest' ($viaCache.Sha256 -ceq $goodHash) $null

        # outside the install folder: a development checkout with Bench\out and tools\, a version-named folder somewhere else
        $dev = Join-Path $tmp 'checkout'; $devOut = Join-Path $dev 'Bench\out'; New-Item -ItemType Directory -Path $devOut -Force | Out-Null
        Copy-Item -LiteralPath $exe -Destination (Join-Path $devOut 'AVDTune.Bench.exe'); New-Item -ItemType Directory -Path (Join-Path $dev 'tools') -Force | Out-Null; Copy-Item -LiteralPath $exe -Destination (Join-Path $dev 'tools\AVDTune.Bench.exe')
        [IO.File]::WriteAllText((Join-Path $dev 'VERSION'), '0.5.0')
        $msg = Get-ThrownText { Open-AVDTuneVerifiedBenchExe -AppRoot $dev -InstallRoot $inst -StateRoot $tmp -Manifest $okManifest }
        $adDev = New-AVDTuneBenchAdapter -AppRoot $dev -InstallRoot $inst -StateRoot $tmp -Manifest $okManifest
        Test-Check 'measure program: from a checkout (Bench\out, tools\) it is not started, even with the right hash' ($msg -like '*only starts from the protected install folder*' -and $null -eq (& $adDev.EngineInfo) -and (Get-ThrownText { & $adDev.RunBench 'cpu' @() }) -like '*protected install folder*') $msg
        $srcAdapter = Get-Content -LiteralPath (Join-Path $repo 'Modules\AVDTune.Benchmark.psm1') -Raw
        Test-Check 'measure program: the adapter no longer looks in Bench\out or tools\ and has no ExePath parameter' ($srcAdapter -notmatch 'Bench\\out' -and $srcAdapter -notmatch '\$ExePath' -and -not (Get-Command New-AVDTuneBenchAdapter).Parameters.ContainsKey('ExePath')) $null
        $other = Join-Path $tmp 'elsewhere\0.5.0'; New-Item -ItemType Directory -Path (Join-Path $other 'Bench\bin') -Force | Out-Null; Copy-Item -LiteralPath $exe -Destination (Join-Path $other 'Bench\bin\AVDTune.Bench.exe')
        Test-Check 'measure program: a version-named folder outside the install folder is not an install' ((Get-ThrownText { Open-AVDTuneVerifiedBenchExe -AppRoot $other -InstallRoot $inst -StateRoot $tmp -Manifest $okManifest }) -like '*only starts from the protected install folder*') $null
        # the test parameters of the adapter only work in the test mode; the real install folder is the only one otherwise
        foreach ($case in @(@{ N = 'no variables'; F = ''; R = '' }, @{ N = 'AVDTUNE_FAKE without AVDTUNE_ROOT'; F = $fakeScript; R = '' }, @{ N = 'AVDTUNE_ROOT without AVDTUNE_FAKE'; F = ''; R = $tmp }, @{ N = 'AVDTUNE_FAKE that is no script below Tests'; F = 'bench-check'; R = $tmp })) {
            $env:AVDTUNE_FAKE = $case.F; $env:AVDTUNE_ROOT = $case.R
            Test-Check "measure program: another install folder or manifest is refused outside the test mode ($($case.N))" ((Get-ThrownText { New-AVDTuneBenchAdapter -InstallRoot $inst -WarningAction SilentlyContinue }) -like '*always the one of the release*' -and (Get-ThrownText { Open-AVDTuneVerifiedBenchExe -AppRoot $app -InstallRoot $inst -StateRoot $tmp -Manifest $okManifest -WarningAction SilentlyContinue }) -like '*only starts from the install folder*') $null
        }
        $env:AVDTUNE_FAKE = $fakeScript; $env:AVDTUNE_ROOT = $tmp

        # the folder is not admin-only: a rule for users, a foreign owner, a link above the file
        $aclCase = @{ Mode = 'ok' }
        Set-AVDTuneReleaseAclReader ({ param($Path, $IsDirectory)
                $owner = 'S-1-5-32-544'; $rules = @([pscustomobject]@{ Sid = 'S-1-5-32-544'; Inherited = $false })
                if ($aclCase.Mode -eq 'users-folder' -and $Path -like '*Bench\bin') { $rules += [pscustomobject]@{ Sid = 'S-1-5-32-545'; Inherited = $false } }
                if ($aclCase.Mode -eq 'foreign-owner' -and $Path -like '*0.5.0') { $owner = 'S-1-5-21-1-2-3-1001' }
                if ($aclCase.Mode -eq 'users-file' -and $Path -like '*AVDTune.Bench.exe') { $rules += [pscustomobject]@{ Sid = 'S-1-1-0'; Inherited = $false } }
                [pscustomobject]@{ Owner = $owner; Protected = $true; Rules = $rules } }.GetNewClosure())
        try {
            $okChain = Open-AVDTuneVerifiedBenchExe -AppRoot $app -InstallRoot $inst -StateRoot $tmp -Manifest $okManifest; $okChain.Stream.Dispose()
            Test-Check 'measure program: with administrator-only folders the ACL check passes' ($okChain.Sha256 -ceq $goodHash) $null
            foreach ($mode in 'users-folder', 'foreign-owner', 'users-file') {
                $aclCase.Mode = $mode
                $msg = Get-ThrownText { Open-AVDTuneVerifiedBenchExe -AppRoot $app -InstallRoot $inst -StateRoot $tmp -Manifest $okManifest }
                Test-Check "measure program: folder not administrator-only ($mode) is refused" ($msg -like '*not in a protected folder*not started*') $msg
            }
            $aclCase.Mode = 'ok'
            # a junction as Bench in the version folder: refused, and the target is never opened
            $target = Join-Path $tmp 'junction-target'; New-Item -ItemType Directory -Path (Join-Path $target 'bin') -Force | Out-Null; Copy-Item -LiteralPath $exe -Destination (Join-Path $target 'bin\AVDTune.Bench.exe')
            $app2 = Join-Path $inst '0.5.1'; New-Item -ItemType Directory -Path $app2 | Out-Null; [IO.File]::WriteAllText((Join-Path $app2 'VERSION'), '0.5.1')
            [void](New-Item -ItemType Junction -Path (Join-Path $app2 'Bench') -Target $target)
            $msg = Get-ThrownText { Open-AVDTuneVerifiedBenchExe -AppRoot $app2 -InstallRoot $inst -StateRoot $tmp -Manifest (New-BenchManifest $goodHash $true '0.5.1') }
            Test-Check 'measure program: a link in the path (junction as Bench) is refused' ($msg -like '*link*') $msg
            [IO.Directory]::Delete((Join-Path $app2 'Bench'))
        }
        finally { Set-AVDTuneReleaseAclReader $null }
        & $mod2 { $script:Hooks.AclReader = $null }
        Test-Check 'measure program: the checks used a temporary install folder, not Program Files' ($inst -ne (Get-AVDTuneInstallRoot) -and (Test-AVDTuneTestMode).Enabled) $null
    }
    finally { $env:AVDTUNE_FAKE = $oldFake; if ($null -eq $oldFake) { Remove-Item Env:\AVDTUNE_FAKE -ErrorAction SilentlyContinue }; $env:AVDTUNE_ROOT = $oldRoot; if ($null -eq $oldRoot) { Remove-Item Env:\AVDTUNE_ROOT -ErrorAction SilentlyContinue } }


    # ================================================================ round 2 (issue #14): applications, FSLogix, GPU, capacity, report per image version
    $r2 = Join-Path ([IO.Path]::GetTempPath()) ('avdtune-bench-r2-' + [guid]::NewGuid().ToString('N'))
    try {
        [void](Initialize-AVDTuneState -Root $r2)
        [void](Start-AVDTuneImageVersion -Root $r2 -Date ([datetime]'2026-11-15') -User 'admin1')
        $share = '\\fakehost\profiles'

        # ---- environment allowlist: extended only for the applications, values from Windows, not from the inherited variables
        $base = Get-AVDTuneChildEnvironment -Tool base -TempDir 'C:\x'
        $names = @('USERPROFILE', 'APPDATA', 'LOCALAPPDATA', 'USERNAME', 'USERDOMAIN', 'COMPUTERNAME', 'HOMEDRIVE', 'HOMEPATH')
        Test-Check 'environment: the plain allowlist has no user variables' (@($names | Where-Object { $base.Contains($_) }).Count -eq 0) (($base.Keys) -join ',')
        $oldUp = $env:USERPROFILE; $oldAd = $env:APPDATA; $oldHook = $env:DOTNET_STARTUP_HOOKS
        try {
            $env:USERPROFILE = 'C:\evil-profile'; $env:APPDATA = 'C:\evil-appdata'; $env:DOTNET_STARTUP_HOOKS = 'C:\evil.dll'
            $ext = Get-AVDTuneChildEnvironment -Tool apps -TempDir 'C:\x'
        }
        finally { $env:USERPROFILE = $oldUp; $env:APPDATA = $oldAd; if ($null -eq $oldHook) { Remove-Item Env:\DOTNET_STARTUP_HOOKS -ErrorAction SilentlyContinue } else { $env:DOTNET_STARTUP_HOOKS = $oldHook } }
        Test-Check 'environment: -Tool apps adds exactly the eight variables, from the folder API (an inherited USERPROFILE/APPDATA is not used)' (@($names | Where-Object { -not $ext.Contains($_) }).Count -eq 0 -and $ext['USERPROFILE'] -eq [Environment]::GetFolderPath('UserProfile') -and $ext['APPDATA'] -eq (Join-Path $ext['USERPROFILE'] 'AppData\Roaming') -and $ext['LOCALAPPDATA'] -eq (Join-Path $ext['USERPROFILE'] 'AppData\Local') -and $ext['USERPROFILE'] -ne 'C:\evil-profile' -and $ext['COMPUTERNAME'] -eq [Environment]::MachineName) "$($ext['USERPROFILE']) $($ext['APPDATA'])"
        Test-Check 'environment: -Tool apps still has no DOTNET_*, COR*, __COMPAT_LAYER and keeps TEMP/TMP/PATH fixed' (@($ext.Keys | Where-Object { $_ -like 'DOTNET_*' -or $_ -like 'COR*' -or $_ -eq '__COMPAT_LAYER' }).Count -eq 0 -and $ext['TEMP'] -eq 'C:\x' -and $ext['PATH'] -eq [Environment]::GetFolderPath('System') -and @($ext.Keys).Count -eq (@($base.Keys).Count + 12)) $null
        $benchSrc = Get-Content -LiteralPath (Join-Path $repo 'Modules\AVDTune.Benchmark.psm1') -Raw
        Test-Check 'environment: only the application starts use the extended list, the capacity run does not (source)' ($benchSrc -match '\$b\.RunBench = \{ param\(\[string\]\$Command, \[string\[\]\]\$Arguments\) & \$runner \$Command \$Arguments \$limits\.BenchMs \$false \}' -and $benchSrc.Contains('& $runner $Command $args2 $timeout ($Command -eq ''apps'')')) $null
        $profPath = Get-AVDTuneProfilePath; $coreSrc = Get-Content -LiteralPath (Join-Path $repo 'Modules\AVDTune.psm1') -Raw
        Test-Check 'environment: the profile comes from ProfileList in HKLM (by SID), not from HKCU; APPDATA and LOCALAPPDATA are derived from it' ($ext['USERPROFILE'] -ieq $profPath -and ([regex]::Match($coreSrc, '(?s)function Get-AVDTuneProfilePath \{.*?\n\}').Value) -match 'HKLM:.*ProfileList' -and ([regex]::Match($coreSrc, '(?s)function Get-AVDTuneProfilePath \{.*?\n\}').Value) -notmatch 'HKCU') $profPath
        Test-Check 'environment: ProgramW6432, CommonProgramW6432, ALLUSERSPROFILE and PUBLIC are set in the application profile, not in the plain list' ($ext['ProgramW6432'] -and $ext['CommonProgramW6432'] -and $ext['ALLUSERSPROFILE'] -and $ext['PUBLIC'] -and -not $base.Contains('PUBLIC') -and -not $base.Contains('ProgramW6432') -and $ext['ALLUSERSPROFILE'] -ieq [Environment]::GetFolderPath('CommonApplicationData')) "$($ext['PUBLIC']) $($ext['ProgramW6432'])"

        Import-Module (Join-Path $repo 'Modules/AVDTune.Updates.psm1')
        # ---- programs: trust entries for the applications, paths from Windows folders
        $sigOk = [pscustomobject]@{ Valid = $true; Status = 'Valid'; Subject = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'; Issuer = 'CN=Microsoft Code Signing PCA 2011, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'; OriginalFilename = 'WinWord.exe' }
        Test-Check 'trust: WINWORD.EXE of Microsoft with the right original file name is accepted' ((Test-AVDTuneToolTrust -Signature $sigOk -Name 'WINWORD.EXE').Ok) $null
        Test-Check 'trust: a wrong subject, a wrong original file name or no signature is refused' (-not (Test-AVDTuneToolTrust -Signature ($sigOk | Select-Object *) -Name 'EXCEL.EXE').Ok -and -not (Test-AVDTuneToolTrust -Signature ([pscustomobject]@{ Valid = $true; Status = 'Valid'; Subject = 'CN=Evil Corp, O=Evil Corp'; Issuer = $sigOk.Issuer; OriginalFilename = 'WinWord.exe' }) -Name 'WINWORD.EXE').Ok -and -not (Test-AVDTuneToolTrust -Signature ([pscustomobject]@{ Valid = $false; Status = 'NotSigned'; Subject = ''; Issuer = ''; OriginalFilename = '' }) -Name 'msedge.exe').Ok) $null
        $ps5 = Get-AVDTuneAppProgramPath -Key powershell; $ex = Get-AVDTuneAppProgramPath -Key explorer
        Test-Check 'programs: powershell.exe and explorer.exe come from the System and Windows folders (known folders, no PATH)' ($ps5 -ieq (Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell\v1.0\powershell.exe') -and $ex -ieq (Join-Path ([Environment]::GetFolderPath('Windows')) 'explorer.exe')) "$ps5 $ex"
        $adapterSrc = Get-Content -LiteralPath (Join-Path $repo 'Modules\AVDTune.Benchmark.psm1') -Raw
        $runAppsText = [regex]::Match($adapterSrc, '(?s)\$b\.RunApps = \{.*?\}\.GetNewClosure\(\)').Value
        Test-Check 'RunApps (source): admin-only path, held open with FileShare.Read, Authenticode of Microsoft, UseShellExecute never off the checked list, no PATH lookup' ($runAppsText -match 'Test-AVDTuneAdminOnlyPath' -and $runAppsText -match 'FileShare\]::Read' -and $runAppsText -match 'Test-AVDTuneToolTrust' -and $runAppsText -notmatch 'Get-Command' -and $runAppsText -notmatch '\$env:') $null
        $appPathText = [regex]::Match($adapterSrc, '(?s)function Get-AVDTuneAppProgramPath \{.*?\n\}').Value
        Test-Check 'programs (source): the path function reads HKLM and known folders only, no environment variable, no Get-Command' ($appPathText -match 'HKLM:' -and $appPathText -notmatch 'Get-Command' -and $appPathText -notmatch '\$env:' -and $appPathText -notmatch 'HKCU') $null

        # ---- applications in a fake run: warm-up and quick shortcuts, not installed programs, no Speedometer copy
        $b = New-AVDTuneFakeBench -Reference $ref -Config $config -Seed @{ SkipApps = @('word') }
        $res = Invoke-AVDTuneBenchmark -Machine (New-Master) -Bench $b -Root $r2 -Mode Full -Kind manual -SkipIdleCheck -NoReport
        $appCalls = @($b.Log | Where-Object { $_ -like 'RunApps apps*' })
        Test-Check 'apps: warm-up has no cold start and no Speedometer; the three runs do the cold starts' ($appCalls.Count -eq 4 -and $appCalls[0] -like '*--no-cold*--no-speedometer*' -and @($appCalls[1..3] | Where-Object { $_ -notlike '*--no-cold*' -and $_ -notlike '*--no-speedometer*' }).Count -eq 3) ($appCalls -join ' | ')
        $word = @($res.Result.measures | Where-Object { $_.id -like 'host.app.word.*' })
        Test-Check 'apps: a program that is not installed is skipped with the reason, the others count' (@($word | Where-Object { $_.status -eq 'skipped' -and $_.reason -like 'not installed*' }).Count -eq 2 -and @($res.Result.measures | Where-Object { $_.id -eq 'host.app.edge.cold' -and $_.status -eq 'ok' }).Count -eq 1 -and $res.Result.scores.host.categories.PSObject.Properties.Name -contains 'apps') $null
        $spd = @($res.Result.measures | Where-Object id -eq 'host.app.speedometer')[0]
        Test-Check 'apps: without the Speedometer copy the measure is skipped with the reason; Outlook and Teams are skipped' ($spd.status -eq 'skipped' -and $spd.reason -like '*Speedometer copy*' -and @($res.Result.measures | Where-Object { $_.id -like 'host.app.outlook.*' -and $_.status -eq 'skipped' }).Count -eq 2 -and @($res.Result.measures | Where-Object { $_.id -like 'host.app.teams.*' -and $_.status -eq 'skipped' }).Count -eq 2) $spd.status
        $quick = New-AVDTuneFakeBench -Reference $ref -Config $config
        [void](Invoke-AVDTuneBenchmark -Machine (New-Master) -Bench $quick -Root $r2 -Mode Quick -SkipIdleCheck -NoReport)
        $qCalls = @($quick.Log | Where-Object { $_ -like 'RunApps apps*' })
        Test-Check 'apps: a quick run has no cold start and one Speedometer iteration' ($qCalls.Count -eq 2 -and @($qCalls | Where-Object { $_ -like '*--no-cold*' -and $_ -like '*--speed-iterations 1*' }).Count -eq 2 -and $qCalls[0] -like '*--no-speedometer*' -and $qCalls[1] -notlike '*--no-speedometer*') ($qCalls -join ' | ')
        Test-Check 'apps: the work folder of the apps is the work folder of the run (removed afterwards)' (@($qCalls | Where-Object { $_ -match '--dir .*benchmark\\work\\' }).Count -eq 2 -and (Get-Leftover -Bench $quick -Root $r2).Count -eq 0) $null
        $keys = @($res.Result.measures | Where-Object { $_.id -like 'host.app.*' -and $_.status -eq 'ok' })
        Test-Check 'references: every application measure carries calibrated=false and is labelled nicht kalibriert in the result' (@($keys | Where-Object { $_.calibrated -ne $false }).Count -eq 0 -and $res.Result.scores.host.uncalibrated -and $res.Result.scores.host.categories.apps.uncalibrated) $null
        Test-Check 'references: the file says nicht kalibriert and every new measure id has a reference value' ($ref.Status -like '*nicht kalibriert*' -and @(@('fsl.rr.qd1.p50', 'fsl.vhd.parallel5', 'gpu.cs.gflops', 'gpu.dec.av1', 'host.app.speedometer', 'host.app.powershell.warm') | Where-Object { -not $ref.Measures.PSObject.Properties[$_] }).Count -eq 0) $null

        # ---- FSLogix score
        $m = New-Master
        $b = New-AVDTuneFakeBench -Reference $ref -Config $config -Seed @{ Factor = 1.2 }
        $res = Invoke-AVDTuneBenchmark -Machine $m -Bench $b -Root $r2 -Mode Full -Kind manual -SkipIdleCheck -Share $share -NoReport
        $f = $res.Result.scores.fslogix
        Test-Check 'fslogix: score about 1200 over four categories, uncalibrated, provisional, no partial' ($f.value -ge 1190 -and $f.value -le 1230 -and @($f.categories.PSObject.Properties).Count -eq 4 -and -not $f.partial -and $f.uncalibrated -and $f.provisional -and $res.Result.share.used -and $res.Result.share.auth -eq 'kerberos') "$($f.value)"
        Test-Check 'fslogix: the host score is not influenced by the fsl.* and gpu.* measures (six host categories)' (@($res.Result.scores.host.categories.PSObject.Properties).Count -eq 6 -and $res.Result.scores.host.value -ge 1190 -and $res.Result.scores.host.value -le 1230) $res.Result.scores.host.value
        $fslDisk = @($b.Log | Where-Object { $_ -cmatch '^Diskspd .*AVDTune-Bench-[0-9a-f]{32}' })
        Test-Check 'fslogix: diskspd goes only to a file in the GUID test folder on the share, fixed templates with -c2G, 20 calls' ($fslDisk.Count -eq 20 -and @($fslDisk | Where-Object { $_ -cmatch '-c2G \\\\fakehost\\profiles\\AVDTune-Bench-[0-9a-f]{32}\\disk\.dat$' -and $_ -like '*-Sh*' -and $_ -like '*-Rxml*' }).Count -eq 20) $fslDisk[0]
        Test-Check 'fslogix: the share test, the container cycle and five parallel containers ran each time' (@($b.Log | Where-Object { $_ -like 'RunBench share*--host fakehost*' }).Count -eq 4 -and @($b.Log | Where-Object { $_ -like 'VhdCycle 1 2 200' }).Count -eq 3 -and @($b.Log | Where-Object { $_ -like 'VhdParallel 5' }).Count -eq 4 -and @($b.Log | Where-Object { $_ -like 'VhdCycle 1 2 50' }).Count -eq 1) $null
        Test-Check 'fslogix: the test folder is removed after every run and the store holds none' ($b.Store.ShareFolders.Count -eq 0 -and @($b.Log | Where-Object { $_ -like 'ShareMakeFolder*' }).Count -eq 4 -and @($b.Log | Where-Object { $_ -like 'ShareRemoveFolder*' }).Count -eq 4) $b.Store.ShareFolders.Count
        Test-Check 'fslogix: summary names the FSLogix score and nicht kalibriert' ($res.Summary -like '*FSLogix 1*' -and $res.Summary -like '*nicht kalibriert*') $res.Summary
        foreach ($case in @(@{ N = 'the container cannot be attached'; S = @{ VhdFails = $true }; Gone = 'fsl.vhd.create' }, @{ N = 'the parallel test fails'; S = @{ VhdParallelFails = $true }; Gone = 'fsl.vhd.parallel5' }, @{ N = 'the share test program fails'; S = @{ FailCommands = @('share') }; Gone = 'fsl.meta.create' })) {
            $bf = New-AVDTuneFakeBench -Reference $ref -Config $config -Seed $case.S
            $rf = Invoke-AVDTuneBenchmark -Machine (New-Master) -Bench $bf -Root $r2 -Mode Quick -SkipIdleCheck -Share $share -NoReport
            $mm = @($rf.Result.measures | Where-Object id -eq $case.Gone)[0]
            Test-Check "fslogix: $($case.N): that measure fails with a reason, the rest is scored, the test folder is removed" ($mm.status -eq 'failed' -and $mm.reason -and $null -ne $rf.Result.scores.fslogix.value -and $bf.Store.ShareFolders.Count -eq 0) "$($mm.status) $($mm.reason)"
        }
        $bn = New-AVDTuneFakeBench -Reference $ref -Config $config -Seed @{ ShareFails = $true }
        $rn = Invoke-AVDTuneBenchmark -Machine (New-Master) -Bench $bn -Root $r2 -Mode Quick -SkipIdleCheck -Share $share -NoReport
        Test-Check 'fslogix: a share that cannot be used gives a failed FSLogix score with the error, the host score still comes' ($rn.Result.scores.fslogix.status -eq 'failed' -and (@($rn.Errors) -join ' ') -like '*fslogix*denied*' -and $null -ne $rn.Result.scores.host.value -and (Get-Leftover -Bench $bn -Root $r2).Count -eq 0) ($rn.Errors -join ';')
        $shareSrc = [regex]::Match($adapterSrc, '(?s)\$b\.ShareMakeFolder = \{.*?\n    \}').Value
        Test-Check 'share (source): a plain UNC pattern is required, the test folder gets a GUID name, a link is refused, removal is no-follow and only for AVDTune-Bench-<guid>' ($shareSrc -match 'plain UNC' -and $shareSrc -match 'NewGuid' -and $shareSrc -match 'ReparsePoint' -and $adapterSrc -match 'AVDTune-Bench-\[0-9a-f\]\{32\}\$.\) \{ throw .Not a test folder' -and $adapterSrc -match 'Remove-AVDTuneFolderNoFollow \$Dir') $null
        $mu = New-Master
        foreach ($case in @(@{ V = '\\files.contoso.test\profiles'; W = '\\files.contoso.test\profiles' }, @{ V = @('C:\local', '\\a.test\one;\\b.test\two'); W = '\\a.test\one' }, @{ V = '\\host\share\sub\'; W = '\\host\share\sub' }, @{ V = 'http://x/y'; W = '' }, @{ V = '\\host\sha"re'; W = '' }, @{ V = '\\ho st\share'; W = '' }, @{ V = '\\host\share\a\..\..\x'; W = '' })) {
            $mu.Store.Registry['hklm:\software\fslogix\profiles|vhdlocations'] = $case.V
            Test-Check "share: VHDLocations '$(@($case.V) -join ' & ')' gives '$($case.W)'" ((Get-AVDTuneBenchShare -Machine $mu) -eq $case.W) (Get-AVDTuneBenchShare -Machine $mu)
        }
        Test-Check 'share: the host of a UNC path' ((Get-AVDTuneBenchShareHost '\\account.file.core.windows.net\profiles') -eq 'account.file.core.windows.net' -and (Get-AVDTuneBenchShareHost 'C:\x') -eq '') $null
        $mnoShare = New-Master
        $rs = New-AVDTuneFakeBench -Reference $ref -Config $config
        [void](Invoke-AVDTuneBenchmark -Machine $mnoShare -Bench $rs -Root $r2 -Mode Quick -SkipIdleCheck -NoReport)
        Test-Check 'share: without VHDLocations nothing touches a share' (@($rs.Log | Where-Object { $_ -like 'ShareMakeFolder*' -or $_ -like 'VhdCycle*' }).Count -eq 0) $null

        # ---- GPU score
        $bg = New-AVDTuneFakeBench -Reference $ref -Config $config -Seed @{ Gpu = $true }
        $rg = Invoke-AVDTuneBenchmark -Machine (New-Master) -Bench $bg -Root $r2 -Mode Full -SkipIdleCheck -NoReport
        $g = $rg.Result.scores.gpu
        Test-Check 'gpu: with a hardware GPU the score is a partial score (encode and decode not built), render and compute counted, adapter in the system block' ($null -ne $g.value -and $g.partial -and $g.missingCategories -contains 'encode' -and $g.missingCategories -contains 'decode' -and @($g.categories.PSObject.Properties).Count -eq 2 -and $g.uncalibrated -and $rg.Result.system.gpu.adapter -eq 'Fake GPU 8Q' -and $rg.Summary -like '*GPU 1*') "$($g.value) $($g.missingCategories -join ',')"
        $enc = @($rg.Result.measures | Where-Object id -eq 'gpu.enc.h264')[0]
        Test-Check 'gpu: a codec that is not measured is unsupported with the reason, not zero' ($enc.status -eq 'unsupported' -and $enc.reason -like '*not part*') $enc.status
        Test-Check 'gpu: without a GPU the score is nicht vorhanden (not 0) and no GPU measure is asked' ($res.Result.scores.gpu.reason -eq 'nicht vorhanden' -and $null -eq $res.Result.scores.gpu.value -and @($b.Log | Where-Object { $_ -match '^RunBench gpu --quiet' }).Count -eq 0 -and $null -eq $res.Result.system.gpu) $null
        $gSet = Get-AVDTuneBenchmarkScores -Measures @([pscustomobject]@{ Id = 'gpu.d3d11.1080'; Status = 'ok'; Index = 1000 }, [pscustomobject]@{ Id = 'gpu.cs.gflops'; Status = 'ok'; Index = 1000 }, [pscustomobject]@{ Id = 'host.cpu.single'; Status = 'ok'; Index = 5 }) -Config $config -Set gpu
        Test-Check 'gpu: the category set only takes gpu.* ids (weights 35/30/15/20), a host id is ignored' ($gSet.Host -eq 1000 -and $gSet.Categories.Count -eq 2 -and (@((Get-AVDTuneBenchCategorySet $config gpu).PSObject.Properties | ForEach-Object { $_.Value.weight }) -join ',') -eq '35,30,15,20' -and (@((Get-AVDTuneBenchCategorySet $config fslogix).PSObject.Properties | ForEach-Object { $_.Value.weight }) -join ',') -eq '35,20,15,30') $null

        # ---- capacity simulation
        Test-Check 'capacity: not available in a quick run' ((Get-ThrownText { Invoke-AVDTuneBenchmark -Machine (New-Master) -Bench (New-AVDTuneFakeBench -Reference $ref -Config $config) -Root $r2 -Mode Quick -SkipIdleCheck -Capacity }) -like '*not available in a quick run*') $null
        $bc = New-AVDTuneFakeBench -Reference $ref -Config $config
        $rc = Invoke-AVDTuneBenchmark -Machine (New-Master) -Bench $bc -Root $r2 -Mode Full -SkipIdleCheck -Capacity -NoReport
        $capCall = @($bc.Log | Where-Object { $_ -like 'RunApps capacity*' })
        Test-Check 'capacity: runs once after the measured runs, with the work folder; the result carries the levels and the estimate; it is not part of the scores' ($capCall.Count -eq 1 -and $capCall[0] -like '*--dir *benchmark\work\*' -and $rc.Result.capacity.estimatedUsers -eq 5.9 -and @($rc.Result.capacity.levels).Count -eq 3 -and $rc.Result.scores.host.value -ge 1190 -and $rc.Summary -like '*capacity about 5.9 users*' -and (Test-Path -LiteralPath $rc.Path)) ($capCall -join ' ')
        Test-Check 'capacity: the method is named an estimate of our own, not a Login VSI result' ($rc.Result.capacity.method -like '*not a Login VSI result*') $null
        Test-Check 'capacity: the work folder (probe files, workers) is gone and the quiet mode is restored' ((Get-Leftover -Bench $bc -Root $r2).Count -eq 0) $null
        $bc2 = New-AVDTuneFakeBench -Reference $ref -Config $config -Seed @{ CapacityBlock = [pscustomobject]@{ levels = @(); estimatedUsers = 7.0; thresholdReached = $true; stopReason = 'x'; method = 'own method, not a Login VSI result' } }
        $rc2 = Invoke-AVDTuneBenchmark -Machine (New-Master) -Bench $bc2 -Root $r2 -Mode Full -SkipIdleCheck -Capacity -NoReport
        Test-Check 'capacity: compared with the last run of the same VM size (5.9 to 7.0 is +18.6 percent, better)' ($rc2.Result.capacityCompare.DeltaPercent -eq 18.6 -and $rc2.Result.capacityCompare.Class -eq 'better') ($rc2.Result.capacityCompare | Out-String)
        $bc3 = New-AVDTuneFakeBench -Reference $ref -Config $config -Seed @{ CapacityFails = $true }
        $rc3 = Invoke-AVDTuneBenchmark -Machine (New-Master) -Bench $bc3 -Root $r2 -Mode Full -SkipIdleCheck -Capacity -NoReport
        Test-Check 'capacity: a failed simulation is an error text, the benchmark is still stored, quiet mode restored' ((@($rc3.Errors) -join ' ') -like '*capacity*' -and $null -eq $rc3.Result.capacity -and (Test-Path -LiteralPath $rc3.Path) -and (Get-Leftover -Bench $bc3 -Root $r2).Count -eq 0) ($rc3.Errors -join ';')
        Test-Check 'capacity: compare helper (no previous gives nothing, one side without number is side by side)' ($null -eq (Compare-AVDTuneCapacity -Current ([pscustomobject]@{ estimatedUsers = 5 }) -Previous $null) -and (Compare-AVDTuneCapacity -Current ([pscustomobject]@{ estimatedUsers = $null }) -Previous ([pscustomobject]@{ estimatedUsers = 5 })).Class -eq 'side-by-side' -and (Compare-AVDTuneCapacity -Current ([pscustomobject]@{ estimatedUsers = 4 }) -Previous ([pscustomobject]@{ estimatedUsers = 5 })).Class -eq 'worse') $null

        # ---- report per image version
        $rr = Join-Path ([IO.Path]::GetTempPath()) ('avdtune-bench-rep-' + [guid]::NewGuid().ToString('N'))
        try {
            [void](Initialize-AVDTuneState -Root $rr)
            $made = @{}
            foreach ($v in @(@('2026.11.002', 1.0, 'Standard_D8s_v5'), @('2026.11.010', 1.3, 'Standard_D8s_v5'), @('2026.11.003', 1.1, 'Standard_D8s_v5'))) {
                Set-AVDTuneState -Root $rr -Values @{ ImageVersion = $v[0] } | Out-Null
                $bv = New-AVDTuneFakeBench -Reference $ref -Config $config -Seed @{ Factor = $v[1] }
                $made[$v[0]] = Invoke-AVDTuneBenchmark -Machine (New-Master) -Bench $bv -Root $rr -Mode Full -SkipIdleCheck -Share $share
                Start-Sleep -Milliseconds 1100
            }
            $rep010 = $made['2026.11.010']
            Test-Check 'report: written for a full run of a version, next to the results, named by the version' ($rep010.ReportPath -and (Test-Path -LiteralPath $rep010.ReportPath) -and $rep010.ReportPath -like '*runs\benchmark\report-2026.11.010.html') $rep010.ReportPath
            [void](Save-AVDTuneBenchmarkReport -Root $rr -ImageVersion '2026.11.010')   # the later versions exist now: written again
            $html = Get-Content -LiteralPath $rep010.ReportPath -Raw
            Test-Check 'report: self-contained (no external resource, no script, no link, no image)' ($html -notmatch '(?i)https?://' -and $html -notmatch '(?i)<script' -and $html -notmatch '(?i)<link' -and $html -notmatch '(?i)<img' -and $html -notmatch '(?i)\bsrc=' -and $html -notmatch '(?i)\bhref=' -and $html -notmatch '(?i)url\(' -and $html -notmatch '(?i)@import') $null
            Test-Check 'report: three scores, categories of the three sets, every measure, nicht kalibriert' ($html -like '*Host score*' -and $html -like '*FSLogix score*' -and $html -like '*GPU score*' -and $html -like '*Profile container*' -and $html -like '*host.app.word.cold*' -and $html -like '*fsl.vhd.parallel5*' -and $html -like '*nicht kalibriert*' -and $html -like '*nicht vorhanden*') $null
            $prevOf010 = Get-AVDTunePreviousVersionResult -Root $rr -ImageVersion '2026.11.010'
            Test-Check 'report: the previous version is the closest earlier one by number (2026.11.003 for 2026.11.010, not 002 or 011), 2026.11.002 has none' ($prevOf010.system.imageVersion -eq '2026.11.003' -and $null -eq (Get-AVDTunePreviousVersionResult -Root $rr -ImageVersion '2026.11.002') -and (Get-AVDTunePreviousVersionResult -Root $rr -ImageVersion '2026.11.003').system.imageVersion -eq '2026.11.002') $prevOf010.system.imageVersion
            $expect = [math]::Round(($made['2026.11.010'].Result.scores.host.value / $made['2026.11.003'].Result.scores.host.value - 1) * 100, 1)
            Test-Check 'report: the host score delta against the previous version is in the page (about +18 percent, green)' ($html -like "*previous image version <b>2026.11.003</b>*" -and $html -like ('*' + ('{0:+0.0;-0.0;0.0}' -f $expect) + ' % vs previous version*') -and $expect -gt 10) "$expect"
            $html2 = Get-Content -LiteralPath $made['2026.11.002'].ReportPath -Raw
            Test-Check 'report: the first version says that there is nothing to compare with' ($html2 -like '*No earlier image version*') $null
            # the HTML is made from data that may come from outside: every value is encoded
            $evil = Get-AVDTuneBenchmarkResult -Root $rr -RunId $made['2026.11.010'].RunId | Select-Object -First 1
            $evil.system.vmSize = '<script>alert(1)</script>'; $evil.system.cpuModel = '"><img src=x onerror=alert(1)>'; $evil.measures[0].id = '<b>x</b>'; $evil.measures[1].reason = '<i>r</i>'; $evil.measures[1].status = 'failed'
            $evilHtml = New-AVDTuneBenchmarkReport -Current $evil -Previous $null -Baseline $null -Config $config
            Test-Check 'report: markup in a result file is shown as text (script, img, b, i are all escaped)' ($evilHtml -notmatch '<script' -and $evilHtml -notmatch '<img' -and $evilHtml -notmatch '<b>x</b>' -and $evilHtml -notmatch '<i>r</i>' -and $evilHtml -like '*&lt;script&gt;alert(1)&lt;/script&gt;*' -and $evilHtml -like '*&lt;img src=x*') $null
            Test-Check 'report: an image version that cannot be a file name is refused' ((Get-ThrownText { Save-AVDTuneBenchmarkReport -Root $rr -ImageVersion '..\..\x' }) -like '*cannot be used in a file name*' -and (Get-ThrownText { Save-AVDTuneBenchmarkReport -Root $rr -ImageVersion '9.9.9' }) -like '*No full benchmark result*') $null
            # benchmark major version of the previous version differs: raw values only
            $majorPrev = Get-AVDTuneBenchmarkResult -Root $rr -RunId $made['2026.11.003'].RunId | Select-Object -First 1
            $majorPrev.benchmarkVersion = 'B2.0'
            $mHtml = New-AVDTuneBenchmarkReport -Current $evil -Previous $majorPrev -Baseline $null -Config $config
            Test-Check 'report: another benchmark major version is never compared as a score (a note, no delta)' ($mHtml -like '*another benchmark version or mode*' -and $mHtml -notlike '*% vs previous version*') $null
            # quick runs and runs without an image version write no report
            $bq = New-AVDTuneFakeBench -Reference $ref -Config $config
            $rq = Invoke-AVDTuneBenchmark -Machine (New-Master) -Bench $bq -Root $rr -Mode Quick -SkipIdleCheck
            Test-Check 'report: a quick run writes no report and the quick result is not used as a previous version' (-not $rq.ReportPath -and (Get-AVDTuneBenchmarkVersionResults -Root $rr | Where-Object { $_.mode -ne 'full' }).Count -eq 0) $null
            Test-Check 'report: the result file with the report and the capacity stays free of secret-like names' ((Get-Content -LiteralPath $rep010.Path -Raw) -notmatch '(?i)password|secret|token|accountkey|sas=') $null

            # ---- comparison per image version (#90)
            Set-AVDTuneBenchmarkBaseline -Root $rr -RunId $made['2026.11.002'].RunId
            Set-AVDTuneState -Root $rr -Values @{ ImageVersion = '2026.11.011' } | Out-Null
            $made['2026.11.011'] = Invoke-AVDTuneBenchmark -Machine (New-Master) -Bench (New-AVDTuneFakeBench -Reference $ref -Config $config -Seed @{ Factor = 0.8 }) -Root $rr -Mode Full -SkipIdleCheck -Share $share -NoReport
            $cmp = Get-AVDTuneBenchmarkVersionComparison -Root $rr -Config $config
            $vers = @($cmp.Rows | ForEach-Object { $_.ImageVersion })
            Test-Check 'comparison: one row per image version, oldest first, the quick run left out' (($vers -join ',') -eq '2026.11.002,2026.11.003,2026.11.010,2026.11.011' -and $cmp.Problems.Count -eq 0) "$($vers -join ',') | $($cmp.Problems -join '; ')"
            $r010 = @($cmp.Rows | Where-Object { $_.ImageVersion -eq '2026.11.010' })[0]; $r011 = @($cmp.Rows | Where-Object { $_.ImageVersion -eq '2026.11.011' })[0]; $r002 = $cmp.Rows[0]
            Test-Check 'comparison: rows are typed (AVDTune.BenchmarkRow, scores [double], Started a UTC [datetime])' ($r010.PSObject.TypeNames[0] -eq 'AVDTune.BenchmarkRow' -and $r010.HostScore -is [double] -and $r010.FslogixScore -is [double] -and $r010.Started -is [datetime] -and $r010.Started.Kind -eq 'Utc' -and $null -eq $r010.GpuScore) "$($r010.HostScore.GetType().Name) $($r010.Started.Kind)"
            Test-Check 'comparison: 2026.11.010 against its previous version 2026.11.003 (host and FSLogix delta, green)' ($r010.PreviousImageVersion -eq '2026.11.003' -and $r010.VsPrevious.Host.DeltaPercent -eq $expect -and $r010.VsPrevious.Host.Class -eq 'better' -and $null -ne $r010.VsPrevious.Fslogix.DeltaPercent -and $r010.Light -eq 'green') "$($r010.VsPrevious.Host.DeltaPercent) $($r010.Light)"
            Test-Check 'comparison: the baseline row says so and has no delta against itself; the others are compared with it' ($r002.IsBaseline -and $null -eq $r002.VsBaseline -and $null -eq $r002.VsPrevious -and $r002.Light -eq 'grey' -and $cmp.BaselineRunId -eq $made['2026.11.002'].RunId -and $r010.VsBaseline.Host.Class -eq 'better') "$($r002.Light) $($r010.VsBaseline.Host.DeltaPercent)"
            Test-Check 'comparison: a worse version (factor 0.8 after 1.3) is red and names what got worse' ($r011.Light -eq 'red' -and $r011.VsPrevious.Host.Class -eq 'worse' -and $r011.VsPrevious.Host.DeltaPercent -lt -10 -and (@($r011.Worse) -join ' ') -like '*Host -*% vs previous*') (@($r011.Worse) -join '; ')
            # numbers only as JSON numbers; a changed file is left out and named
            Test-Check 'comparison: only JSON numbers are scores ("1200", true, 0, NaN, infinity are none)' ((ConvertTo-AVDTuneBenchNumber 1200) -eq 1200 -and (ConvertTo-AVDTuneBenchNumber 5.9) -eq 5.9 -and $null -eq (ConvertTo-AVDTuneBenchNumber '1200') -and $null -eq (ConvertTo-AVDTuneBenchNumber $true) -and $null -eq (ConvertTo-AVDTuneBenchNumber 0) -and $null -eq (ConvertTo-AVDTuneBenchNumber ([double]::NaN)) -and $null -eq (ConvertTo-AVDTuneBenchNumber ([double]::PositiveInfinity))) $null
            $strScore = Get-AVDTuneBenchmarkResult -Root $rr -RunId $made['2026.11.003'].RunId | Select-Object -First 1
            $strScore.scores.host.value = '9999'
            Test-Check 'comparison: a score written as text gives no score in the typed row' ($null -eq (ConvertTo-AVDTuneBenchmarkRow $strScore).HostScore) $null
            $tampered = Get-Content -LiteralPath $made['2026.11.003'].Path -Raw | ConvertFrom-Json
            $tampered.runId = '20991231-000000-dead'; $tampered.system.imageVersion = '2026.11.099'; $tampered.scores.host.value = 99999
            Write-AVDTuneFile (Join-Path (Get-AVDTuneBenchmarkResultFolder $rr) '20991231-000000-dead.json') ($tampered | ConvertTo-Json -Depth 12)
            $cmpT = Get-AVDTuneBenchmarkVersionComparison -Root $rr -Config $config
            Test-Check 'comparison: a changed result file (integrity hash) is left out and named, never a version row' (@($cmpT.Rows | Where-Object { $_.ImageVersion -eq '2026.11.099' }).Count -eq 0 -and (@($cmpT.Problems) -join ' ') -like '*20991231-000000-dead*integrity*') (@($cmpT.Problems) -join '; ')
            # export
            $csv = ConvertTo-AVDTuneBenchmarkComparisonText -Comparison $cmp -Format Csv
            $lines = @($csv -split "`r`n" | Where-Object { $_ })
            Test-Check 'export CSV: header and one line per version, scores and deltas as plain numbers' ($lines.Count -eq 5 -and $lines[0] -like 'Row,ImageVersion,System,*,HostScore,*HostVsPreviousPct,HostVsBaselinePct,*,Light' -and $lines[4] -like ('"version","2026.11.011",*,' + ([double]$r011.VsPrevious.Host.DeltaPercent).ToString('0.0', [Globalization.CultureInfo]::InvariantCulture) + ',*"red"')) $lines[4]
            $keepCulture = [Threading.Thread]::CurrentThread.CurrentCulture
            try { [Threading.Thread]::CurrentThread.CurrentCulture = 'de-DE'; $csvDe = ConvertTo-AVDTuneBenchmarkComparisonText -Comparison $cmp -Format Csv } finally { [Threading.Thread]::CurrentThread.CurrentCulture = $keepCulture }
            Test-Check 'export CSV: numbers are invariant (a German Windows gives the same file)' ($csvDe -ceq $csv) $null
            $evilCmp = Get-AVDTuneBenchmarkVersionComparison -Root $rr -Config $config
            $evilCmp.Rows[0].VmSize = '=HYPERLINK("http://x","y")'; $evilCmp.Rows[1].VmSize = '+1'; $evilCmp.Rows[2].VmSize = '@SUM(A1)'; $evilCmp.Rows[3].VmSize = '-2+3'
            $evilCsv = ConvertTo-AVDTuneBenchmarkComparisonText -Comparison $evilCmp -Format Csv
            Test-Check 'export CSV: text cells that a spreadsheet reads as a formula (= + - @) start with an apostrophe, quotes doubled' ($evilCsv -like '*"''=HYPERLINK(""http://x"",""y"")"*' -and $evilCsv -like '*"''+1"*' -and $evilCsv -like '*"''@SUM(A1)"*' -and $evilCsv -like '*"''-2+3"*' -and $evilCsv -notmatch ',"=') $null
            Test-Check 'export CSV: a cell helper without danger stays as it is' ((ConvertTo-AVDTuneCsvCell 'Standard_D8s_v5') -ceq '"Standard_D8s_v5"' -and (ConvertTo-AVDTuneCsvCell $null) -ceq '""') $null
            $json = ConvertTo-AVDTuneBenchmarkComparisonText -Comparison $cmp -Format Json | ConvertFrom-Json
            Test-Check 'export JSON: schema 1, threshold, baseline and the rows with the deltas' ($json.schemaVersion -eq 1 -and $json.thresholdPercent -eq 10 -and $json.baselineRunId -eq $cmp.BaselineRunId -and @($json.rows).Count -eq 4 -and $json.rows[3].Light -eq 'red' -and $json.rows[0].Baseline -eq 'yes') $null
            $exp = Join-Path $rr 'export'; [void](New-Item -ItemType Directory -Path $exp)
            $csvFile = Export-AVDTuneBenchmarkComparison -Comparison $cmp -Path (Join-Path $exp 'c.csv') -Format Csv
            $jsonFile = Export-AVDTuneBenchmarkComparison -Comparison $cmp -Path (Join-Path $exp 'c.json') -Format Json
            $csvBytes = [IO.File]::ReadAllBytes($csvFile); $jsonBytes = [IO.File]::ReadAllBytes($jsonFile)
            Test-Check 'export: CSV with BOM (spreadsheet programs), JSON without, no secret-like text' ($csvBytes[0] -eq 0xEF -and $csvBytes[1] -eq 0xBB -and $jsonBytes[0] -eq [byte][char]'{' -and ([IO.File]::ReadAllText($csvFile) + [IO.File]::ReadAllText($jsonFile)) -notmatch '(?i)password|secret|token|accountkey') $null

            # ---- benchmark-only mode (plan 6b)
            Test-Check 'benchmark-only: a name is required, secret-like or overlong text is refused before anything starts' ((Get-ThrownText { Invoke-AVDTuneBenchmark -Machine (New-Master) -Bench (New-AVDTuneFakeBench -Reference $ref -Config $config) -Root $rr -Mode Quick -Kind 'benchmark-only' -SkipIdleCheck }) -like '*name missing*' -and (Get-ThrownText { Invoke-AVDTuneBenchmark -Machine (New-Master) -Bench (New-AVDTuneFakeBench -Reference $ref -Config $config) -Root $rr -Mode Quick -Kind 'benchmark-only' -SystemName 'Old RDS' -Notes 'admin password=abc' -SkipIdleCheck }) -like '*look like a secret*' -and @(Test-AVDTuneBenchmarkLabel -Name ('x' * 81) -Notes '').Count -eq 1 -and @(Test-AVDTuneBenchmarkLabel -Name 'x' -Notes ('password=' * 60)).Count -eq 1 -and @(Test-AVDTuneBenchmarkLabel -Name "a`tb" -Notes '').Count -eq 1 -and @(Test-AVDTuneBenchmarkLabel -Name 'Old RDS' -Notes "line 1`r`nline 2").Count -eq 0) $null
            Test-Check 'benchmark-only: a system name outside that mode is refused' ((Get-ThrownText { Invoke-AVDTuneBenchmark -Machine (New-Master) -Bench (New-AVDTuneFakeBench -Reference $ref -Config $config) -Root $rr -Mode Quick -Kind manual -SystemName 'x' -SkipIdleCheck }) -like '*only for the benchmark-only mode*') $null
            $logBefore = @(Get-AVDTuneChangeLog -Root $rr).Count
            $bOnly = New-AVDTuneFakeBench -Reference $ref -Config $config -Seed @{ Factor = 0.9 }
            $only = Invoke-AVDTuneBenchmark -Machine (New-Master) -Bench $bOnly -Root $rr -Mode Full -Kind 'benchmark-only' -SystemName 'Altsystem RDS 2019' -Notes 'to be replaced' -SkipIdleCheck -Share $share
            $cmpO = Get-AVDTuneBenchmarkVersionComparison -Root $rr -Config $config
            Test-Check 'benchmark-only: the result names the system, belongs to no image version, writes no change log, report or baseline and is no version row' ($only.Result.kind -eq 'benchmark-only' -and $only.Result.system.name -eq 'Altsystem RDS 2019' -and $only.Result.system.notes -eq 'to be replaced' -and $only.Result.system.imageVersion -eq '' -and -not $only.ChangeLogged -and -not $only.ReportPath -and @(Get-AVDTuneChangeLog -Root $rr).Count -eq $logBefore -and (Get-AVDTuneState $rr).BaselineBenchmark -eq $made['2026.11.002'].RunId -and @($cmpO.Rows).Count -eq 4 -and (Get-Leftover -Bench $bOnly -Root $rr).Count -eq 0) "$($only.Result.system.imageVersion) $($only.ChangeLogged)"
            # result file and import as comparison system
            $resFile = Export-AVDTuneBenchmarkResultFile -Root $rr -RunId $only.RunId -Path (Join-Path $exp 'old-rds.json')
            Test-Check 'result file: exported, passes the result check, no secret-like text' (@(Test-AVDTuneBenchmarkResult -Result (Get-Content -LiteralPath $resFile -Raw | ConvertFrom-Json)).Count -eq 0 -and (Get-Content -LiteralPath $resFile -Raw) -notmatch '(?i)password|accountkey|token') $null
            Test-Check 'result file: an invalid run id is refused' ((Get-ThrownText { Export-AVDTuneBenchmarkResultFile -Root $rr -RunId '..\x' -Path (Join-Path $exp 'x.json') }) -like '*Invalid run id*') $null
            $imp = Import-AVDTuneBenchmarkSystem -Root $rr -Path $resFile
            $sysFolder = Get-AVDTuneBenchmarkSystemFolder $rr
            $sysAcl = Get-Acl -LiteralPath $sysFolder
            Test-Check 'import: stored as comparison system in its own protected folder (no inherited rule, Administrators and SYSTEM)' ($imp.SystemName -eq 'Altsystem RDS 2019' -and (Test-Path -LiteralPath (Join-Path $sysFolder "$($only.RunId).json")) -and $sysAcl.AreAccessRulesProtected -and @($sysAcl.Access | Where-Object { $_.IsInherited }).Count -eq 0 -and @($sysAcl.Access | Where-Object { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -eq 'S-1-5-18' }).Count -ge 1) $sysFolder
            $cmpS = Get-AVDTuneBenchmarkVersionComparison -Root $rr -Config $config
            Test-Check 'import: the comparison system is listed with the change of the newest version against it, the versions stay 4' (@($cmpS.Systems).Count -eq 1 -and $cmpS.Systems[0].SystemName -eq 'Altsystem RDS 2019' -and $null -ne $cmpS.Systems[0].NewestVsThis.Host.DeltaPercent -and @($cmpS.Rows).Count -eq 4 -and (ConvertTo-AVDTuneBenchmarkComparisonText -Comparison $cmpS -Format Csv) -like '*"system",*"Altsystem RDS 2019"*') $null
            Test-Check 'import: the same run twice is refused' ((Get-ThrownText { Import-AVDTuneBenchmarkSystem -Root $rr -Path $resFile }) -like '*imported already*') $null
            Test-Check 'import: a result of a master (kind manual) is no comparison system' ((Get-ThrownText { Import-AVDTuneBenchmarkSystem -Root $rr -Path $made['2026.11.010'].Path }) -like '*Only results of the benchmark-only mode*') $null
            $bad = Get-Content -LiteralPath $resFile -Raw | ConvertFrom-Json; $bad.runId = 'other-1'; $bad.scores.host.value = 50000
            [IO.File]::WriteAllText((Join-Path $exp 'changed.json'), ($bad | ConvertTo-Json -Depth 12))
            $bad.integrity.sha256 = Get-AVDTuneBenchmarkIntegrityHash $bad; $bad.runId = '..\..\evil'; $bad.integrity.sha256 = Get-AVDTuneBenchmarkIntegrityHash $bad
            [IO.File]::WriteAllText((Join-Path $exp 'evil-id.json'), ($bad | ConvertTo-Json -Depth 12))
            $bad.runId = 'text-score-1'; $bad.scores.host.value = '50000'; $bad.integrity.sha256 = Get-AVDTuneBenchmarkIntegrityHash $bad
            [IO.File]::WriteAllText((Join-Path $exp 'text-score.json'), ($bad | ConvertTo-Json -Depth 12))
            $bad.runId = 'secret-1'; $bad.scores.host.value = 1000; $bad.system.notes = 'AccountKey=abc'; $bad.integrity.sha256 = Get-AVDTuneBenchmarkIntegrityHash $bad
            [IO.File]::WriteAllText((Join-Path $exp 'secret.json'), ($bad | ConvertTo-Json -Depth 12))
            [IO.File]::WriteAllText((Join-Path $exp 'not-json.json'), 'this is no json')
            $big = [IO.File]::Open((Join-Path $exp 'big.json'), 'CreateNew'); try { $big.SetLength(6MB) } finally { $big.Dispose() }
            Test-Check 'import: a changed file, a run id with a path, a score as text, secret-like content, no JSON and a 6 MB file are all refused, nothing stored' ((Get-ThrownText { Import-AVDTuneBenchmarkSystem -Root $rr -Path (Join-Path $exp 'changed.json') }) -like '*integrity*' -and (Get-ThrownText { Import-AVDTuneBenchmarkSystem -Root $rr -Path (Join-Path $exp 'evil-id.json') }) -like '*run id*' -and (Get-ThrownText { Import-AVDTuneBenchmarkSystem -Root $rr -Path (Join-Path $exp 'text-score.json') }) -like '*not a number*' -and (Get-ThrownText { Import-AVDTuneBenchmarkSystem -Root $rr -Path (Join-Path $exp 'secret.json') }) -like '*secret-like*' -and (Get-ThrownText { Import-AVDTuneBenchmarkSystem -Root $rr -Path (Join-Path $exp 'not-json.json') }) -like '*not a JSON*' -and (Get-ThrownText { Import-AVDTuneBenchmarkSystem -Root $rr -Path (Join-Path $exp 'big.json') }) -like '*larger than 5 MB*' -and @(Get-ChildItem -LiteralPath $sysFolder -File).Count -eq 1) $null
            Copy-Item -LiteralPath (Join-Path $exp 'changed.json') -Destination (Join-Path $sysFolder 'other-1.json')
            $cmpX = Get-AVDTuneBenchmarkVersionComparison -Root $rr -Config $config
            Test-Check 'import: a changed file put into the systems folder by hand is left out and named' (@($cmpX.Systems).Count -eq 1 -and (@($cmpX.Problems) -join ' ') -like '*other-1.json*integrity*') (@($cmpX.Problems) -join '; ')

            # ---- Finn's review of 3365b39 (#90)
            Test-Check 'run id: the whole string (\z, a line break at the end is refused), 1-64 characters, no device name' ((Test-AVDTuneBenchRunId '20261118-090116-aeb1') -and -not (Test-AVDTuneBenchRunId "20261118-090116-aeb1`n") -and -not (Test-AVDTuneBenchRunId 'CON') -and -not (Test-AVDTuneBenchRunId 'nul') -and -not (Test-AVDTuneBenchRunId 'COM1') -and -not (Test-AVDTuneBenchRunId 'lpt9') -and -not (Test-AVDTuneBenchRunId 'Aux') -and -not (Test-AVDTuneBenchRunId ('a' * 65)) -and -not (Test-AVDTuneBenchRunId 5) -and (Test-AVDTuneBenchRunId 'COM10')) $null
            $bad.runId = 'CON'; $bad.system.notes = ''; $bad.integrity.sha256 = Get-AVDTuneBenchmarkIntegrityHash $bad
            [IO.File]::WriteAllText((Join-Path $exp 'con-id.json'), ($bad | ConvertTo-Json -Depth 12))
            Test-Check 'import: a device name as run id (CON) is refused, export too' ((Get-ThrownText { Import-AVDTuneBenchmarkSystem -Root $rr -Path (Join-Path $exp 'con-id.json') }) -like '*run id*' -and (Get-ThrownText { Export-AVDTuneBenchmarkResultFile -Root $rr -RunId 'NUL' -Path (Join-Path $exp 'n.json') }) -like '*Invalid run id*') $null
            Test-Check 'export CSV: a cell that starts with | (DDE) gets the apostrophe too' ((ConvertTo-AVDTuneCsvCell '|cmd /c calc') -ceq '"''|cmd /c calc"') (ConvertTo-AVDTuneCsvCell '|cmd /c calc')
            # the systems folder is read only while it is admin-only; files above 5 MB are left out
            Remove-Item -LiteralPath (Join-Path $sysFolder 'other-1.json') -Force
            $sysSec = [IO.Directory]::GetAccessControl($sysFolder, 'Access'); $keepSec = $sysSec.GetSecurityDescriptorSddlForm('Access')
            $sysSec.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier 'S-1-1-0'), 'Modify', 'ContainerInherit, ObjectInherit', 'None', 'Allow'))); [IO.Directory]::SetAccessControl($sysFolder, $sysSec)
            $open = Get-AVDTuneBenchmarkSystems -Root $rr
            $sysSec = [IO.Directory]::GetAccessControl($sysFolder, 'Access'); $sysSec.SetSecurityDescriptorSddlForm($keepSec, 'Access'); [IO.Directory]::SetAccessControl($sysFolder, $sysSec)
            Test-Check 'systems folder: writable for Everyone = nothing of it is read, the folder is named; with its own rules again it is read' (@($open.Results).Count -eq 0 -and (@($open.Problems) -join ' ') -like '*not an admin-only folder*' -and @((Get-AVDTuneBenchmarkSystems -Root $rr).Results).Count -eq 1) (@($open.Problems) -join '; ')
            Test-Check 'systems folder: the strict test (what the elevated AVDTune runs) refuses a folder that a standard account owns; a folder outside the state folder is refused' (((Test-AVDTuneElevated) -or -not (Test-AVDTuneBenchSystemFolder -Folder $sysFolder -Root $rr -Strict)) -and -not (Test-AVDTuneBenchSystemFolder -Folder $exp -Root $sysFolder) -and (Test-AVDTuneBenchSystemFolder -Folder $sysFolder -Root $rr)) $null
            $bigSys = [IO.File]::Open((Join-Path $sysFolder 'big-1.json'), 'CreateNew'); try { $bigSys.SetLength(6MB) } finally { $bigSys.Dispose() }
            $withBig = Get-AVDTuneBenchmarkSystems -Root $rr
            Remove-Item -LiteralPath (Join-Path $sysFolder 'big-1.json') -Force
            Test-Check 'systems folder: a file above 5 MB is not read, it is named' (@($withBig.Results).Count -eq 1 -and (@($withBig.Problems) -join ' ') -like '*big-1.json: larger than 5 MB*') (@($withBig.Problems) -join '; ')
            # exports: no link as target or folder, written next to it and moved in one step
            $jx = Join-Path $rr 'junction-out'; [void](New-Item -ItemType Junction -Path $jx -Value $exp)
            Test-Check 'export: a folder that is a link (junction) is refused, nothing written through it' ((Get-ThrownText { Export-AVDTuneBenchmarkComparison -Comparison $cmp -Path (Join-Path $jx 'x.csv') -Format Csv }) -like '*is a link*' -and -not (Test-Path -LiteralPath (Join-Path $exp 'x.csv'))) $null
            [IO.Directory]::Delete($jx)
            $over = Join-Path $exp 'over.csv'; [IO.File]::WriteAllText($over, 'old')
            [void](Export-AVDTuneBenchmarkComparison -Comparison $cmp -Path $over -Format Csv)
            Test-Check 'export: an existing file is replaced in one step (temp file next to it, moved), no temp file stays' ((Get-Content -LiteralPath $over -Raw) -like '*Row,ImageVersion*' -and @(Get-ChildItem -LiteralPath $exp -Force -Filter '*.tmp').Count -eq 0) $null
            $exportSrc = [regex]::Match((Get-Content -LiteralPath (Join-Path $repo 'Modules\AVDTune.Benchmark.psm1') -Raw), '(?s)function Export-AVDTuneBenchmarkComparison \{.*?function Test-AVDTuneBenchmarkLabel').Value
            Test-Check 'export (source): no WriteAllText to the chosen path, the export goes through Write-AVDTuneExportFile' ($exportSrc -notmatch 'WriteAllText' -and $exportSrc -match 'Write-AVDTuneExportFile') $null
            # benchmark start: never while the integrity check runs or AVDTune is read only (normal mode and benchmark only)
            Test-Check 'start block: integrity check running or a write block stop the start, nothing else does' ((Get-AVDTuneBenchStartBlock -IntegrityRunning $true -WriteBlock '') -like '*integrity check*still running*' -and (Get-AVDTuneBenchStartBlock -IntegrityRunning $false -WriteBlock 'files changed') -like '*read only: files changed*' -and (Get-AVDTuneBenchStartBlock -IntegrityRunning $false -WriteBlock $null) -eq '') $null
            $pageSrc = Get-Content -LiteralPath (Join-Path $repo 'AVDTune-Benchmark.ps1') -Raw
            Test-Check 'start block (source): Start-BenchRun and Start-BenchJob both ask Get-BenchStartBlock first, which reads the release job and Get-AVDTuneWriteBlock' ([regex]::Match($pageSrc, '(?s)function Start-BenchRun.*?\n\}').Value -match '(?s)\A[^\n]*\n\s*\$block = Get-BenchStartBlock' -and [regex]::Match($pageSrc, '(?s)function Start-BenchJob.*?Assert-NoOtherWriter').Value -match 'Get-BenchStartBlock' -and [regex]::Match($pageSrc, '(?s)function Get-BenchStartBlock.*?\n\}').Value -match 'RelJob.*Get-AVDTuneWriteBlock') $null
        # ---- security review fixes (finding 4, 5, 8, 9, 11)
        $shareText = [regex]::Match($adapterSrc, '(?s)\$b\.ShareMakeFolder = \{.*?\n    \}').Value
        Test-Check 'share folder (source): created in one step with a protected DACL (current admin, SYSTEM, Administrators), owner and foreign rules and the link flag checked afterwards' ($shareText -match 'SetAccessRuleProtection\(\$true' -and $shareText -match '\.Create\(\$sec\)' -and $shareText -match 'S-1-5-18' -and $shareText -match 'S-1-5-32-544' -and $shareText -match 'GetOwner' -and $shareText -match 'foreign owner or rule' -and $shareText -match 'ReparsePoint' -and $shareText -notmatch 'CreateDirectory\(') $null
        $vhdText = [regex]::Match($adapterSrc, '(?s)function Invoke-AVDTuneVhdCycle \{.*?\r?\n\r?\n#endregion').Value
        Test-Check 'container (source): no default drive letter before the format and checked afterwards' ($vhdText -match 'NoDefaultDriveLetter \$true' -and $vhdText.IndexOf('NoDefaultDriveLetter') -lt $vhdText.IndexOf('Format-Volume') -and $vhdText -match 'got a drive letter') $null
        $detachAt = $vhdText.IndexOf('$out.Detach ='); $reAt = $vhdText.IndexOf('$out.Reattach =')
        $gap = $vhdText.Substring($detachAt, $reAt - $detachAt)
        Test-Check 'container (source): the VirtDisk handle stays open between detach and attach (no Close and no Open in the gap)' ($gap -notmatch '::Close\(' -and $gap -notmatch '::Open\(' -and $gap -match '::Detach\(\$st\.h\)' -and $gap -match '::Attach\(\$st\.h\)') $null
        Test-Check 'run work folder (source): removed with Remove-AVDTuneFolderNoFollow, no Remove-Item -Recurse on it' ($adapterSrc -match 'Remove-AVDTuneFolderNoFollow \$work' -and $adapterSrc -notmatch 'Remove-Item -LiteralPath \$work ') $null
        Test-Check 'report: a Content-Security-Policy meta tag forbids everything but inline style' ($adapterSrc.Contains("http-equiv=`"Content-Security-Policy`" content=`"default-src ''none''; style-src ''unsafe-inline''`"")) $null
        $lb = New-AVDTuneFakeBench -Reference $ref -Config $config
        Test-Check 'cleanliness: a clean state is clean' (@(Test-AVDTuneBenchmarkClean -Bench $lb -Root $r2 | Where-Object { $_ -notlike 'diskspd cache*' }).Count -eq 0) $null
        $lb.Store.ShareFolders['\\fakehost\profiles\AVDTune-Bench-' + ('a' * 32)] = $true
        $lb.Store.Volumes = @('x'); $lb.Store.WorkLeftovers = @('C:\w\mnt1', 'C:\w\edge-1234', 'C:\w\apps-0f')
        $lc = (@(Test-AVDTuneBenchmarkClean -Bench $lb -Root $r2) -join ' | ')
        Test-Check 'cleanliness: a share test folder, an attached container (label AVDTuneBench), a mount point and Edge or Office leftovers are reported' ($lc -like '*share test folder*AVDTune-Bench-*' -and $lc -like '*attached container*AVDTuneBench*' -and $lc -like '*work leftover*mnt1*' -and $lc -like '*work leftover*edge-1234*' -and $lc -like '*apps-0f*') $lc
        Test-Check 'cleanliness (source): the real scan looks for AVDTune-Bench-<guid> on VHDLocations, volumes labelled AVDTuneBench, mnt/edge/apps folders' ($adapterSrc -match 'LeftoverScan' -and $adapterSrc -match "FileSystemLabel -eq 'AVDTuneBench'" -and $adapterSrc -match 'AVDTune-Bench-\[0-9a-f\]\{32\}\$' -and $adapterSrc -match 'mnt\\d\+\|edge-') $null
        # audit #98: the real machine member that the readiness item and the finish gate read (Test-AVDTuneBenchmarkClean with the real adapter, without the diskspd line)
        $r98 = Join-Path ([IO.Path]::GetTempPath()) ('avdtune-bench-98-' + [guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path (Join-Path $r98 'benchmark\work\run-1') -Force); [void](New-Item -ItemType Directory -Path (Join-Path $r98 'tools\diskspd') -Force)
        Set-Content -LiteralPath (Get-AVDTuneBenchmarkJournalPath $r98) -Value '{}'
        $real98 = @(& (New-AVDTuneMachine).BenchLeftovers $r98 (New-AVDTuneFakeBench -Reference $ref -Config $config))   # #111: a fake bench, nothing of the check machine is read
        Remove-Item -LiteralPath $r98 -Recurse -Force
        Test-Check 'leftovers (#98): the real machine member names the work folder and the restore journal of an interrupted run, not the diskspd cache' (($real98 -join '|') -like '*work folder run-1*' -and ($real98 -join '|') -like '*restore journal*' -and -not (($real98 -join '|') -like '*diskspd*')) ($real98 -join '|')
        # plausibility band against the reference (N4)
        $refO = [pscustomobject]@{ Measures = [pscustomobject]@{ 'host.app.speedometer' = [pscustomobject]@{ value = 20.0 }; 'host.app.edge.warm' = [pscustomobject]@{ value = 300.0 } } }
        $mk = { param($id, $v) [pscustomobject]@{ id = $id; unit = 'x'; better = 'higher'; value = $v; status = 'ok'; reason = $null } }
        $aggO = ConvertTo-AVDTuneBenchAggregate -Runs @(, @((& $mk 'host.app.speedometer' 150.0), (& $mk 'host.app.edge.warm' 310.0))) -Reference $refO -Config $config
        $aggLow = ConvertTo-AVDTuneBenchAggregate -Runs @(, @((& $mk 'host.app.speedometer' 2.0))) -Reference $refO -Config $config
        Test-Check 'plausibility: a value more than 5 times above or below the reference is marked as an outlier, a normal one is not' ($aggO[0].outlier -eq $true -and $aggO[1].outlier -eq $false -and $aggLow[0].outlier -eq $true) "$($aggO[0].outlier) $($aggO[1].outlier) $($aggLow[0].outlier)"
        $outCur = Get-AVDTuneBenchmarkResult -Root $rr -RunId $made['2026.11.010'].RunId | Select-Object -First 1
        $outCur.measures[0] | Add-Member -NotePropertyName outlier -NotePropertyValue $true -Force
        Test-Check 'plausibility: the report shows the outlier' ((New-AVDTuneBenchmarkReport -Current $outCur -Previous $null -Baseline $null -Config $config) -like '*Ausreisser*') $null
        # markup in imageVersion, GPU and capacity values of a result file is shown as text
        $evil2 = Get-AVDTuneBenchmarkResult -Root $rr -RunId $made['2026.11.010'].RunId | Select-Object -First 1
        $evil2.system.imageVersion = '<script>alert(2)</script>'
        $evil2.system | Add-Member -NotePropertyName gpu -NotePropertyValue ([pscustomobject]@{ adapter = '<img src=x onerror=alert(3)>'; driver = '"><svg onload=alert(4)>'; vramMiB = '<b>9</b>' }) -Force
        $evil2.capacity = [pscustomobject]@{ estimatedUsers = '<u>7</u>'; atLeastUsers = '<i>3</i>'; stopReason = '<script>alert(5)</script>'; levels = @([pscustomobject]@{ users = '<b>1</b>'; totalMedianMs = '<s>1</s>'; totalP95Ms = 2; cpuPercent = '<em>3</em>'; availableMemoryMB = 4; diskQueue = 5 }) }
        $evil2Html = New-AVDTuneBenchmarkReport -Current $evil2 -Previous $null -Baseline $null -Config $config
        Test-Check 'report: markup in imageVersion, the GPU block and the capacity block is escaped, not interpreted' ($evil2Html -notmatch '<script' -and $evil2Html -notmatch '<img' -and $evil2Html -notmatch '<svg' -and $evil2Html -notmatch '<b>9' -and $evil2Html -notmatch '<u>7' -and $evil2Html -notmatch '<i>3' -and $evil2Html -notmatch '<s>1' -and $evil2Html -notmatch '<em>' -and $evil2Html -like '*&lt;script&gt;alert(2)*' -and $evil2Html -like '*&lt;img src=x*' -and $evil2Html -like '*&lt;svg onload*' -and $evil2Html -like '*&lt;u&gt;7*') $null
        }
        finally { Remove-Item -LiteralPath $rr -Recurse -Force -ErrorAction SilentlyContinue }
        Test-Check 'run records: the state folder of the round 2 checks has no leftovers of the fake share or work folders' ((Get-Leftover -Bench (New-AVDTuneFakeBench -Reference $ref -Config $config) -Root $r2).Count -eq 0) $null
    }
    finally { Remove-Item -LiteralPath $r2 -Recurse -Force -ErrorAction SilentlyContinue }


    $direct = @(Get-ChildItem -LiteralPath $repo -Recurse -Include *.ps1, *.psm1, *.cs, *.xaml -File | Where-Object { $_.FullName -notlike (Join-Path $repo 'Tests\*') -and $_.FullName -notlike '*\Bench\*in\*' -and $_.FullName -notlike '*\Bench\*\obj\*' } | Select-String -Pattern 'env:AVDTUNE_(FAKE|ROOT|SMOKE)|GetEnvironmentVariable\(.AVDTUNE_(FAKE|ROOT|SMOKE)' | Where-Object { $_.Line -notmatch '^\s*#' -and $_.Line -notmatch '\$fake = \[string\]\$env:AVDTUNE_FAKE' })
    Test-Check 'no code outside Tests reads AVDTUNE_FAKE/ROOT/SMOKE directly (only Test-AVDTuneTestMode)' ($direct.Count -eq 0) (($direct | ForEach-Object { "$($_.Path):$($_.LineNumber)" }) -join '; ')

    # Real finding on the test VM (#67): the real adapter ran in the page's background runspace without AVDTune.Release.psm1 ("Open-AVDTuneVerifiedBenchExe is not recognized").
    # A fresh runspace with exactly the imports of the page's script block builds the REAL adapter and asks EngineInfo: any reason is fine, an unknown command is not.
    $pageSrc = Get-Content -Raw (Join-Path $repo 'AVDTune-Benchmark.ps1')
    $pageImports = @([regex]::Matches($pageSrc, "Import-Module \(Join-Path \`$AppRoot '([^']+)'\)") | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
    $rs = [powershell]::Create()
    $keepFake = $env:AVDTUNE_FAKE; $keepRoot = $env:AVDTUNE_ROOT
    $env:AVDTUNE_FAKE = $fakeScript; $env:AVDTUNE_ROOT = $tmp   # test mode only for -StateRoot (the adapter itself is the real one)
    try {
        [void]$rs.AddScript({
                param($Repo, $Imports, $State)
                $ErrorActionPreference = 'Stop'
                foreach ($i in $Imports) { Import-Module (Join-Path $Repo $i) -Force }
                $b = New-AVDTuneBenchAdapter -StateRoot $State
                $info = & $b.EngineInfo
                [pscustomobject]@{ Info = $info; Problem = [string](& $b.EngineProblem) }
            }).AddArgument($repo).AddArgument($pageImports).AddArgument($tmp)
        $engine = $rs.Invoke() | Select-Object -Last 1
        $rsErr = @($rs.Streams.Error | ForEach-Object { $_.ToString() }) -join '; '
    }
    catch { $engine = $null; $rsErr = $_.Exception.Message }
    finally { $rs.Dispose(); $env:AVDTUNE_FAKE = $keepFake; $env:AVDTUNE_ROOT = $keepRoot }
    Test-Check 'benchmark page (#67): the real adapter works in a runspace with exactly the page''s imports (EngineInfo gives a reason, never an unknown command)' ($engine -and $pageImports.Count -ge 3 -and $engine.Problem -notmatch 'is not recognized|nicht erkannt' -and -not $rsErr) "imports=$($pageImports -join ','); problem=$($engine.Problem); err=$rsErr"

    # ---------------------------------------------------------------- stand-alone package (prepared, #90): Tools\New-AVDBenchmarkPackage.ps1 from a release
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    function Get-AVDTuneFileSha256Local([string]$Path) { $s = [Security.Cryptography.SHA256]::Create(); $f = [IO.File]::OpenRead($Path); try { ([BitConverter]::ToString($s.ComputeHash($f)) -replace '-', '').ToLowerInvariant() } finally { $f.Dispose(); $s.Dispose() } }
    $pk = Join-Path $tmp 'pkg'
    $tree = Join-Path $pk 'tree'
    foreach ($rel in @(@(Get-ChildItem -LiteralPath (Join-Path $repo 'Modules') -Filter '*.psm1' | ForEach-Object { "Modules\$($_.Name)" }) + @(Get-ChildItem -LiteralPath (Join-Path $repo 'Bench\data') -File | ForEach-Object { "Bench\data\$($_.Name)" }) + 'VERSION', 'LICENSE', 'NOTICE', 'Start-AVDTune.ps1')) {
        $dst = Join-Path $tree $rel; [void](New-Item -ItemType Directory -Path (Split-Path $dst -Parent) -Force); Copy-Item -LiteralPath (Join-Path $repo $rel) -Destination $dst
    }
    $fakeExe = Join-Path $pk 'AVDTune.Bench.exe'; [IO.File]::WriteAllBytes($fakeExe, [byte[]](1..64))
    $relOut = Join-Path $pk 'release'
    [void](& (Join-Path $repo 'Tools\New-AVDTuneRelease.ps1') -Root $tree -OutDir $relOut -Commit ('a' * 40) -CommitDate ([datetime]'2026-11-18T10:00:00Z') -BenchExe $fakeExe -RequireBench)
    $pkg = & (Join-Path $repo 'Tools\New-AVDBenchmarkPackage.ps1') -ReleaseDir $relOut -OutDir (Join-Path $pk 'out') -RequireBench
    $pm = Get-Content -LiteralPath $pkg.Manifest -Raw | ConvertFrom-Json
    $pz = [IO.Compression.ZipFile]::OpenRead($pkg.Zip); try { $pNames = @($pz.Entries | ForEach-Object FullName) } finally { $pz.Dispose() }
    $needMods = 'Modules/AVDTune.Benchmark.psm1', 'Modules/AVDTune.psm1', 'Modules/AVDTune.Release.psm1', 'Modules/AVDTune.Trust.psm1', 'Modules/AVDTune.Updates.psm1', 'Modules/AVDTune.UpdateBlock.psm1'
    Test-Check 'stand-alone package: the engine and the modules it imports, the benchmark data, the measure program, licence; no window, no other page module' (@($needMods | Where-Object { $_ -notin $pNames }).Count -eq 0 -and $pNames -contains 'Bench/data/benchmark-B1.0.json' -and $pNames -contains 'Bench/bin/AVDTune.Bench.exe' -and $pNames -contains 'LICENSE' -and $pNames -notcontains 'Start-AVDTune.ps1' -and $pNames -notcontains 'Modules/AVDTune.Software.psm1' -and @($pNames | Where-Object { $_ -match '(?i)diskspd' }).Count -eq 0) ($pNames -join ',')
    $relM = Get-Content -LiteralPath (Join-Path $relOut 'manifest.json') -Raw | ConvertFrom-Json
    $hashOk = @($pm.Files | Where-Object { $f = $_; @($relM.Files | Where-Object { $_.Path -ceq $f.Path -and $_.Sha256 -ceq $f.Sha256 }).Count -ne 1 }).Count -eq 0
    Test-Check 'stand-alone package: manifest names the source release (version, commit, ZIP hash), every file has the hash of the release, the entry script is still open' ($pm.Product -eq 'AVD-Benchmark' -and $pm.Source.Commit -eq ('a' * 40) -and $pm.Source.ZipSha256 -eq $relM.Zip.Sha256 -and $hashOk -and @($pm.Files).Count -eq $pNames.Count -and $pm.Entry -eq '' -and $pm.Zip.Sha256 -eq (Get-AVDTuneFileSha256Local $pkg.Zip)) $null
    # counter-tests: a changed release ZIP, a manifest hash that does not fit an entry, an entry outside the manifest
    $badRel = Join-Path $pk 'bad1'; Copy-Item -LiteralPath $relOut -Destination $badRel -Recurse
    $bz = Join-Path $badRel $relM.Zip.Name; $bytes = [IO.File]::ReadAllBytes($bz); $bytes[$bytes.Length - 30] = $bytes[$bytes.Length - 30] -bxor 0xFF; [IO.File]::WriteAllBytes($bz, $bytes)
    Test-Check 'stand-alone package: a changed release ZIP is refused' ((Get-ThrownText { & (Join-Path $repo 'Tools\New-AVDBenchmarkPackage.ps1') -ReleaseDir $badRel -OutDir (Join-Path $pk 'o1') }) -like '*does not match the SHA256*') $null
    $badRel2 = Join-Path $pk 'bad2'; Copy-Item -LiteralPath $relOut -Destination $badRel2 -Recurse
    $m2 = Get-Content -LiteralPath (Join-Path $badRel2 'manifest.json') -Raw | ConvertFrom-Json
    @($m2.Files | Where-Object { $_.Path -eq 'Modules/AVDTune.Benchmark.psm1' })[0].Sha256 = ('0' * 64)
    [IO.File]::WriteAllText((Join-Path $badRel2 'manifest.json'), ($m2 | ConvertTo-Json -Depth 5))
    Test-Check 'stand-alone package: a file whose bytes do not fit the manifest is refused' ((Get-ThrownText { & (Join-Path $repo 'Tools\New-AVDBenchmarkPackage.ps1') -ReleaseDir $badRel2 -OutDir (Join-Path $pk 'o2') }) -like '*Modules/AVDTune.Benchmark.psm1 does not match*') $null
    $badRel3 = Join-Path $pk 'bad3'; [void](New-Item -ItemType Directory -Path $badRel3)
    $z3 = Join-Path $badRel3 $relM.Zip.Name; Copy-Item -LiteralPath (Join-Path $relOut $relM.Zip.Name) -Destination $z3
    $za = [IO.Compression.ZipFile]::Open($z3, 'Update'); try { $ne = $za.CreateEntry('Modules/Extra.psm1'); $s = $ne.Open(); try { $s.WriteByte(65) } finally { $s.Dispose() } } finally { $za.Dispose() }
    $m3 = Get-Content -LiteralPath (Join-Path $relOut 'manifest.json') -Raw | ConvertFrom-Json; $m3.Zip.Size = (Get-Item -LiteralPath $z3).Length; $m3.Zip.Sha256 = Get-AVDTuneFileSha256Local $z3
    [IO.File]::WriteAllText((Join-Path $badRel3 'manifest.json'), ($m3 | ConvertTo-Json -Depth 5))
    Test-Check 'stand-alone package: a file in the release ZIP that the manifest does not list is refused' ((Get-ThrownText { & (Join-Path $repo 'Tools\New-AVDBenchmarkPackage.ps1') -ReleaseDir $badRel3 -OutDir (Join-Path $pk 'o3') }) -like '*does not list*Modules/Extra.psm1*') $null
    Test-Check 'stand-alone package: OutDir must be new or empty' ((Get-ThrownText { & (Join-Path $repo 'Tools\New-AVDBenchmarkPackage.ps1') -ReleaseDir $relOut -OutDir (Join-Path $pk 'out') }) -like '*not empty*') $null
    $devRefused = @(foreach ($bp in @('CON', 'Modules/NUL.psm1', 'Bench/COM1', "Modules/AVDTune.psm1`n", 'a/../b')) {
            $d = Join-Path $pk ('bad-' + [guid]::NewGuid().ToString('N').Substring(0, 6)); Copy-Item -LiteralPath $relOut -Destination $d -Recurse
            $mm = Get-Content -LiteralPath (Join-Path $d 'manifest.json') -Raw | ConvertFrom-Json
            $mm.Files = @($mm.Files) + [pscustomobject]@{ Path = $bp; Size = 1; Sha256 = ('0' * 64) }
            [IO.File]::WriteAllText((Join-Path $d 'manifest.json'), ($mm | ConvertTo-Json -Depth 5))
            if ((Get-ThrownText { & (Join-Path $repo 'Tools\New-AVDBenchmarkPackage.ps1') -ReleaseDir $d -OutDir (Join-Path $d 'o') }) -like '*Unsafe path in the manifest*') { $bp }
        })
    Test-Check 'stand-alone package: device names (CON, NUL, COM1), a line break at the end (\z) and .. in a manifest path are refused' ($devRefused.Count -eq 5) ($devRefused -join ',')

    Test-Check 'no file of the check run touched the real state folder' ($tmp -ne (Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'AVDTune')) $tmp
}
finally {
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
if ($script:failed -gt 0) { throw "$script:failed check(s) failed." }
'Check-Benchmark: all checks passed.'
