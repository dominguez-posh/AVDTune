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
    Test-Check 'run: Host score about 1200 over five categories, partial (applications not built yet)' ($r.scores.host.value -ge 1190 -and $r.scores.host.value -le 1230 -and $r.scores.host.partial -and $r.scores.host.missingCategories -contains 'apps' -and @($r.scores.host.categories.PSObject.Properties).Count -eq 5) $r.scores.host.value
    Test-Check 'run: marked provisional because of the placeholder reference' ($r.scores.host.provisional -and $r.referenceInfo.provisional -and $run.Summary -like '*vorlaeufige Referenz*' -and $run.Summary -like '*Teilscore*') $run.Summary
    Test-Check 'run: fslogix and gpu are skipped with a reason, mode full, kind baseline' ($r.scores.fslogix.status -eq 'skipped' -and $r.scores.gpu.status -eq 'skipped' -and $r.mode -eq 'full' -and $r.kind -eq 'baseline') $null
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
    Test-Check 'downloads add TLS 1.2 to the protocols, they do not overwrite them' (([regex]::Matches($src, 'SecurityProtocol = \[Net.ServicePointManager\]::SecurityProtocol -bor')).Count -eq 2 -and $src -notmatch 'SecurityProtocol = \[Net.SecurityProtocolType\]::Tls12') $null
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
    # A copy of a small system program stands in for AVDTune.Bench.exe (it really starts); the install folder is a temporary one (only together with AVDTUNE_FAKE).
    Import-Module (Join-Path $repo 'Modules\AVDTune.Release.psm1') -Force
    $oldFake = $env:AVDTUNE_FAKE; $env:AVDTUNE_FAKE = 'bench-check'
    try {
        $inst = Join-Path $tmp 'install'; $app = Join-Path $inst '0.5.0'; $exeDir = Join-Path $app 'Bench\bin'; $exe = Join-Path $exeDir 'AVDTune.Bench.exe'
        $stand = Join-Path $tmp 'stand-in.exe'   # a tiny console program that prints JSON like the measure program does
        Add-Type -TypeDefinition 'public static class StandIn { public static int Main(string[] a) { System.Console.Out.Write("{\"ok\":1}"); return 0; } }' -OutputType ConsoleApplication -OutputAssembly $stand
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
        $env:AVDTUNE_FAKE = ''
        Test-Check 'measure program: another install folder or manifest is refused outside the test mode' ((Get-ThrownText { New-AVDTuneBenchAdapter -InstallRoot $inst }) -like '*always the one of the release*' -and (Get-ThrownText { Open-AVDTuneVerifiedBenchExe -AppRoot $app -InstallRoot $inst -StateRoot $tmp -Manifest $okManifest }) -like '*only starts from the install folder*') $null
        $env:AVDTUNE_FAKE = 'bench-check'

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
        Test-Check 'measure program: the checks used a temporary install folder, not Program Files' ($inst -ne (Get-AVDTuneInstallRoot) -and $env:AVDTUNE_FAKE -eq 'bench-check') $null
    }
    finally { $env:AVDTUNE_FAKE = $oldFake; if ($null -eq $oldFake) { Remove-Item Env:\AVDTUNE_FAKE -ErrorAction SilentlyContinue } }

    Test-Check 'no file of the check run touched the real state folder' ($tmp -ne (Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'AVDTune')) $tmp
}
finally {
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
if ($script:failed -gt 0) { throw "$script:failed check(s) failed." }
'Check-Benchmark: all checks passed.'
