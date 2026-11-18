# A fake benchmark adapter for the checks and the GUI smoke test: the same members as New-AVDTuneBenchAdapter (Modules\AVDTune.Benchmark.psm1), kept in memory.
# Nothing here starts a process, downloads, runs diskspd or touches the services, tasks or network of this computer.
# Dot-source this file, then: $b = New-AVDTuneFakeBench -Reference $ref -Config $config [-Seed @{ ... }]
# Values: every measure gets the value of the reference times Factor (or divided by it for "lower is better"), so every index is about 1000 x Factor.
# Seed keys (all optional): Factor (default 1.2), CategoryFactor (hashtable 'cpu' ... -> factor), Values (hashtable id -> absolute value), RunNoise (array of factors per run,
# default 1.0, 1.01, 0.99, 1.02), FailCommands ('cpu', 'mem', 'disp', 'files'), SkipMeasures (ids left out), Offline ($true: DNS and TCP fail), NoExe, Elevated, Sessions (array of @{ Id; User } or $null),
# UptimeMinutes, CpuLoad, FreeGiB, PendingReboot, OnBattery, UpdateBusyCalls (busy for the first N asks), LockBusy, ZipSha256, ExeSha256, ZipBytes, SigStatus, SigSubject, DownloadFails,
# DiskspdExitCode, DiskspdXml (a fixed answer), TaskRegisterFails, Throttle (cpu.sustained value).
# Round 2: Gpu ($true: a hardware GPU is listed), SkipApps (app keys that are 'not installed'), NoSite (the Speedometer copy is missing; default $true), ShareFails ($true: the share folder cannot be made),
# VhdFails, VhdParallelFails, CapacityFails, CapacityBlock (the info.capacity object), RefusedPrograms (names the adapter would refuse). .Store.ShareFolders = test folders that exist now (the checks look for leftovers).
# Round 2 fixes: Volumes and WorkLeftovers (what the leftover scan reports).
# .Store holds the state, .Log what was asked (never a secret).

. $(if (Get-Command Resolve-AVDTuneTestScript -ErrorAction Ignore) { $fakeShared = Resolve-AVDTuneTestScript -Path (Join-Path $PSScriptRoot 'FakeShared.ps1') -AppRoot (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent); if (-not $fakeShared) { throw 'FakeShared.ps1 is not a file below the Tests folder of this copy.' }; $fakeShared } else { Join-Path $PSScriptRoot 'FakeShared.ps1' })   # fakes that several runspaces use at once (#80), through the test script gate when the module is loaded
function New-FakeDiskspdXml {
    # XML of the documented diskspd -Rxml layout: TimeSpan with TestTimeSeconds, the Latency buckets, and Thread/Target totals (made up; not captured from a real run)
    param([double]$Seconds = 12, [double]$ReadP50 = 0.1, [double]$ReadP99 = 0.3, [double]$WriteP50 = 0.5, [double]$WriteP99 = 1.5, [long]$ReadCount = 0, [long]$WriteCount = 0, [long]$ReadBytes = 0, [long]$WriteBytes = 0, [int]$Threads = 1)
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $f = { param($v) ([double]$v).ToString('0.######', $inv) }
    $bucket = { param($p, $r, $w) "      <Bucket><Percentile>$p</Percentile><ReadMilliseconds>$(& $f $r)</ReadMilliseconds><WriteMilliseconds>$(& $f $w)</WriteMilliseconds><TotalMilliseconds>$(& $f (($r + $w) / 2))</TotalMilliseconds></Bucket>" }
    $targets = for ($i = 0; $i -lt $Threads; $i++) {
        "    <Thread><Id>$i</Id><Target><Path>C:\fake\disk.dat</Path><BytesCount>$([long][math]::Floor(($ReadBytes + $WriteBytes) / $Threads))</BytesCount><FileSize>4294967296</FileSize><IOCount>$([long][math]::Floor(($ReadCount + $WriteCount) / $Threads))</IOCount><ReadBytes>$([long][math]::Floor($ReadBytes / $Threads))</ReadBytes><ReadCount>$([long][math]::Floor($ReadCount / $Threads))</ReadCount><WriteBytes>$([long][math]::Floor($WriteBytes / $Threads))</WriteBytes><WriteCount>$([long][math]::Floor($WriteCount / $Threads))</WriteCount></Target></Thread>"
    }
    @(
        '<Results>'
        '  <System><ComputerName>FAKE</ComputerName><Tool><Version>2.3.0</Version></Tool></System>'
        '  <TimeSpan>'
        "    <TestTimeSeconds>$(& $f $Seconds)</TestTimeSeconds><ThreadCount>$Threads</ThreadCount>"
        '    <Latency>'
        "      <AverageReadMilliseconds>$(& $f $ReadP50)</AverageReadMilliseconds><AverageWriteMilliseconds>$(& $f $WriteP50)</AverageWriteMilliseconds>"
        (& $bucket 0 ($ReadP50 / 2) ($WriteP50 / 2))
        (& $bucket 50 $ReadP50 $WriteP50)
        (& $bucket 90 ($ReadP50 * 1.5) ($WriteP50 * 1.5))
        (& $bucket 99 $ReadP99 $WriteP99)
        (& $bucket 99.9 ($ReadP99 * 2) ($WriteP99 * 2))
        (& $bucket 100 ($ReadP99 * 4) ($WriteP99 * 4))
        '    </Latency>'
        $targets
        '  </TimeSpan>'
        '</Results>'
    ) -join "`r`n"
}

function New-AVDTuneFakeBench {
    param([Parameter(Mandatory)]$Reference, [Parameter(Mandatory)]$Config, [hashtable]$Seed = @{})
    $store = @{
        Factor = 1.2; CategoryFactor = @{}; Values = @{}; RunNoise = @(1.0, 1.01, 0.99, 1.02); FailCommands = @(); SkipMeasures = @(); Offline = $false; NoExe = $false; Elevated = $true
        Sessions = @(); UptimeMinutes = 120; CpuLoad = 2.0; FreeGiB = 100.0; PendingReboot = $false; OnBattery = $false; UpdateBusyCalls = 0; LockBusy = $false
        ZipSha256 = [string]$Config.diskspd.zipSha256; ExeSha256 = [string]$Config.diskspd.exeSha256; ZipBytes = [long]$Config.diskspd.zipBytes; SigStatus = 'Valid'; SigSubject = 'CN=Microsoft Windows, O=Microsoft Corporation'
        DownloadFails = $false; DiskspdExitCode = 0; DiskspdXml = $null; TaskRegisterFails = $false; Throttle = 0.98
        Gpu = $false; SkipApps = @(); NoSite = $true; ShareFails = $false; VhdFails = $false; VhdParallelFails = $false; CapacityFails = $false; CapacityBlock = $null; RefusedPrograms = @(); ShareFolders = @{}; Volumes = @(); WorkLeftovers = @()
        Tasks = @{}; Counts = @{}; Log = (New-Object System.Collections.ArrayList); BusyAsked = 0; LockHeld = $false; Sleeps = 0
        Reference = $Reference; Config = $Config
    }
    foreach ($k in $Seed.Keys) { $store[$k] = $Seed[$k] }
    $inv = [Globalization.CultureInfo]::InvariantCulture

    $count = { param($key) if (-not $store.Counts.ContainsKey($key)) { $store.Counts[$key] = 0 }; $store.Counts[$key]++; $store.Counts[$key] }.GetNewClosure()
    $value = {
        # the fake value of a measure id: reference x factor, per run a little noise; overrides win
        param($Id, $Run)
        if ($store.Values.ContainsKey($Id)) { return [double]$store.Values[$Id] }
        $ref = $store.Reference.Measures.PSObject.Properties[$Id]
        if (-not $ref) { return $null }
        $factor = [double]$store.Factor
        $catKey = Get-AVDTuneBenchCategoryKey $store.Config $Id
        if ($catKey -and $store.CategoryFactor.ContainsKey($catKey)) { $factor = [double]$store.CategoryFactor[$catKey] }
        $noise = [double]$store.RunNoise[($Run - 1) % @($store.RunNoise).Count]
        $good = $factor * $noise
        if ($Id -eq 'host.cpu.sustained') { return [double]$store.Throttle }
        if ($ref.Value.better -eq 'lower') { [double]$ref.Value.value / $good } else { [double]$ref.Value.value * $good }
    }.GetNewClosure()
    $measure = {
        param($Id, $Run)
        $r = $store.Reference.Measures.PSObject.Properties[$Id]
        [pscustomobject]@{ id = $Id; unit = [string]$r.Value.unit; better = [string]$r.Value.better; value = (& $value $Id $Run); status = 'ok' }
    }.GetNewClosure()

    $b = [ordered]@{ Kind = 'Fake'; Store = $store; Log = $store.Log }
    $b.Elevated = { $store.Elevated }.GetNewClosure()
    $b.OtherSessions = { , @($store.Sessions) }.GetNewClosure()
    $b.UptimeMinutes = { $store.UptimeMinutes }.GetNewClosure()
    $b.CpuLoad = { param($Seconds) [void]$store.Log.Add("CpuLoad $Seconds"); $store.CpuLoad }.GetNewClosure()
    $b.FreeGiB = { param($Path) $store.FreeGiB }.GetNewClosure()
    $b.PendingReboot = { $store.PendingReboot }.GetNewClosure()
    $b.OnBattery = { $store.OnBattery }.GetNewClosure()
    $b.UpdateInstallerBusy = { $store.BusyAsked++; $store.BusyAsked -le [int]$store.UpdateBusyCalls }.GetNewClosure()
    $b.Sleep = { param($Milliseconds) $store.Sleeps++ }.GetNewClosure()
    $b.Lock = { if ($store.LockBusy -or $store.LockHeld) { return $null }; $store.LockHeld = $true; [void]$store.Log.Add('Lock'); 'fake-lock' }.GetNewClosure()
    $b.Unlock = { param($Handle) $store.LockHeld = $false; [void]$store.Log.Add('Unlock') }.GetNewClosure()
    $b.EngineInfo = { if ($store.NoExe) { $null } else { [pscustomobject]@{ Path = 'C:\fake\AVDTune.Bench.exe'; Version = '1.0.0'; Sha256 = ('ab' * 32) } } }.GetNewClosure()
    $b.RunBench = {
        param([string]$Command, [string[]]$Arguments)
        [void]$store.Log.Add("RunBench $Command $(@($Arguments) -join ' ')")
        if ($store.FailCommands -contains $Command) { throw "AVDTune.Bench $Command failed (exit 1): fake failure" }
        $run = & $count "run-$Command"
        $ids = switch ($Command) {
            'cpu' { @('host.cpu.single', 'host.cpu.multi', 'host.cpu.aes', 'host.cpu.sha') + $(if (@($Arguments) -contains '--sustained') { @('host.cpu.sustained') } else { @() }) }
            'mem' { @('host.mem.bandwidth', 'host.mem.latency', 'host.mem.alloc') }
            'disp' { @('host.disp.h264.desktop', 'host.disp.h264.video', 'host.disp.warp.3d', 'host.disp.warp.2d') }
            'files' { @('host.disk.smallfiles') }
            'share' { @('fsl.openclose', 'fsl.rtt', 'fsl.meta.create', 'fsl.meta.stat', 'fsl.meta.delete') }
            'gpu' { @('gpu.d3d11.1080', 'gpu.d3d11.2160', 'gpu.cs.gflops', 'gpu.cs.bandwidth', 'gpu.enc.h264', 'gpu.enc.hevc', 'gpu.enc.av1', 'gpu.dec.h264', 'gpu.dec.hevc', 'gpu.dec.av1') }
            'gpuinfo' { @() }
            default { throw "unknown command $Command" }
        }
        if ($Command -eq 'files') {
            $dir = $Arguments[([array]::IndexOf(@($Arguments), '--dir') + 1)]
            if (-not (Test-Path -LiteralPath $dir)) { throw 'the work folder does not exist' }
        }
        if ($Command -eq 'gpuinfo') { return [pscustomobject]@{ schemaVersion = 1; command = 'gpuinfo'; measures = @(); info = [pscustomobject]@{ hardware = [bool]$store.Gpu; adapter = 'Fake GPU 8Q'; driver = '537.58'; vramMiB = 8192 } } }
        if ($Command -eq 'share') { $shareDir = $Arguments[([array]::IndexOf(@($Arguments), '--dir') + 1)]; if (-not $store.ShareFolders.ContainsKey($shareDir)) { throw 'the test folder on the share does not exist' } }
        $list = @()
        foreach ($id in @($ids | Where-Object { $store.SkipMeasures -notcontains $_ })) {
            $m = & $measure $id $run
            if ($id -match '^gpu\.(enc|dec)\.') { $m.status = 'unsupported'; $m.value = $null; $m | Add-Member reason 'not part of this version' }
            if ($id -eq 'host.disp.h264.video' -and $store.ContainsKey('NoEncoder') -and $store.NoEncoder) { $m.status = 'skipped'; $m.value = $null; $m | Add-Member reason 'no encoder' }
            $list += $m
        }
        [pscustomobject]@{ schemaVersion = 1; command = $Command; measures = @($list) }
    }.GetNewClosure()
    $b.RunApps = {
        param([string]$Command, [string[]]$Arguments, [string[]]$Programs = @('word', 'excel', 'edge', 'explorer', 'powershell'))
        [void]$store.Log.Add("RunApps $Command $(@($Arguments) -join ' ')")
        if ($store.FailCommands -contains $Command) { throw "AVDTune.Bench $Command failed (exit 1): fake failure" }
        if ($Command -eq 'capacity') {
            if ($store.CapacityFails) { throw 'AVDTune.Bench capacity did not finish in time and was ended with everything it had started.' }
            $blk = $store.CapacityBlock
            if (-not $blk) {
                $blk = [pscustomobject]@{
                    levels = @([pscustomobject]@{ users = 0; cycles = 3; totalMedianMs = 900.0; totalP95Ms = 950.0 }, [pscustomobject]@{ users = 1; cycles = 2; totalMedianMs = 1000.0; totalP95Ms = 1100.0; cpuPercent = 12.5; availableMemoryMB = 24000; commitPercent = 20.0; diskQueue = 0.2 }, [pscustomobject]@{ users = 8; cycles = 2; totalMedianMs = 1700.0; totalP95Ms = 1900.0; cpuPercent = 80.0; availableMemoryMB = 12000; commitPercent = 45.0; diskQueue = 1.4 })
                    estimatedUsers = 5.9; thresholdReached = $true; atLeastUsers = $null; stopReason = 'the threshold was passed by two levels'; thresholdFactor = 1.5; method = 'own method, similar to the VSImax idea, not a Login VSI result'
                }
            }
            return [pscustomobject]@{ schemaVersion = 1; command = 'capacity'; measures = @(); info = [pscustomobject]@{ capacity = $blk } }
        }
        $args2 = @($Arguments)
        $noCold = $args2 -contains '--no-cold'; $noSpeed = $args2 -contains '--no-speedometer'
        $run = & $count 'run-apps'
        $list = @()
        foreach ($key in 'word', 'excel', 'edge', 'explorer') {
            foreach ($phase in 'cold', 'warm') {
                if ($phase -eq 'cold' -and $noCold) { continue }
                $id = "host.app.$key.$phase"
                if ($store.SkipApps -contains $key) { $list += [pscustomobject]@{ id = $id; unit = 'ms'; better = 'lower'; value = $null; status = 'skipped'; reason = 'not installed (AVDTune gave no path)' }; continue }
                $list += & $measure $id $run
            }
        }
        $list += $(if ($store.SkipApps -contains 'powershell') { [pscustomobject]@{ id = 'host.app.powershell.warm'; unit = 'ms'; better = 'lower'; value = $null; status = 'skipped'; reason = 'not installed (AVDTune gave no path)' } } else { & $measure 'host.app.powershell.warm' $run })
        foreach ($id in 'host.app.outlook.cold', 'host.app.outlook.warm', 'host.app.teams.cold', 'host.app.teams.warm') { if (-not ($noCold -and $id -like '*.cold')) { $list += [pscustomobject]@{ id = $id; unit = 'ms'; better = 'lower'; value = $null; status = 'skipped'; reason = 'not part of this version of the benchmark' } } }
        if (-not $noSpeed) {
            if (($args2 -notcontains '--site') -or $store.NoSite) { $list += [pscustomobject]@{ id = 'host.app.speedometer'; unit = 'runs/min'; better = 'higher'; value = $null; status = 'skipped'; reason = 'no Speedometer copy (--site)' } }
            else { $list += & $measure 'host.app.speedometer' $run }
        }
        $list = @($list | Where-Object { $store.SkipMeasures -notcontains $_.id })
        $o = [pscustomobject]@{ schemaVersion = 1; command = 'apps'; measures = @($list) }
        if (@($store.RefusedPrograms).Count -gt 0) { $o | Add-Member refusedPrograms @($store.RefusedPrograms) }
        $o
    }.GetNewClosure()
    $b.ShareMakeFolder = {
        param([string]$Unc)
        [void]$store.Log.Add("ShareMakeFolder $Unc")
        if ($store.ShareFails) { throw 'fake: access to the share was denied' }
        $dir = $Unc.TrimEnd('\') + '\AVDTune-Bench-' + [guid]::NewGuid().ToString('N')
        $store.ShareFolders[$dir] = $true
        $dir
    }.GetNewClosure()
    $b.ShareRemoveFolder = { param([string]$Dir) [void]$store.Log.Add("ShareRemoveFolder $Dir"); $store.ShareFolders.Remove($Dir) }.GetNewClosure()
    $b.VhdCycle = {
        param([string]$ShareFolder, [string]$MountRoot, [int]$Index, [int]$SizeGiB, [int]$WriteMB)
        [void]$store.Log.Add("VhdCycle $Index $SizeGiB $WriteMB")
        if (-not $store.ShareFolders.ContainsKey($ShareFolder)) { throw 'fake: the container goes only into a test folder' }
        if ($store.VhdFails) { throw 'fake: the virtual disk could not be attached' }
        $run = & $count 'run-vhd'
        $f = [double]$store.Factor * [double]$store.RunNoise[($run - 1) % @($store.RunNoise).Count]
        $ref = $store.Reference.Measures
        [pscustomobject]@{ Create = [double]$ref.'fsl.vhd.create'.value / $f; Attach = [double]$ref.'fsl.vhd.attach'.value / $f; WriteMBps = [double]$ref.'fsl.vhd.write'.value * $f; Detach = [double]$ref.'fsl.vhd.detach'.value / $f; Reattach = [double]$ref.'fsl.vhd.reattach'.value / $f }
    }.GetNewClosure()
    $b.VhdParallel = {
        param([string]$ShareFolder, [string]$MountRoot, [int]$Count, [int]$SizeGiB, [int]$WriteMB)
        [void]$store.Log.Add("VhdParallel $Count")
        if ($store.VhdParallelFails) { throw 'fake: one of the parallel containers failed' }
        $f = [double]$store.Factor
        [pscustomobject]@{ WallSeconds = [double]$store.Reference.Measures.'fsl.vhd.parallel5'.value / $f; AttachP95 = 4.0 }
    }.GetNewClosure()
    $b.Download = {
        param([string]$Url, [string]$Path)
        [void]$store.Log.Add("Download $Url")
        if ($store.DownloadFails) { throw 'fake: no connection' }
        Set-Content -LiteralPath $Path -Value 'fake zip' -Encoding ASCII
    }.GetNewClosure()
    $b.HashFile = { param($Path) if ($Path -like '*.ZIP') { [string]$store.ZipSha256 } else { [string]$store.ExeSha256 } }.GetNewClosure()
    $b.FileLength = { param($Path) [long]$store.ZipBytes }.GetNewClosure()
    $b.Signature = { param($Path) [pscustomobject]@{ Status = [string]$store.SigStatus; Subject = [string]$store.SigSubject } }.GetNewClosure()
    $b.Expand = {
        param($Zip, $Destination)
        [void]$store.Log.Add('Expand')
        $dir = Join-Path $Destination 'amd64'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'diskspd.exe') -Value 'fake exe' -Encoding ASCII
    }.GetNewClosure()
    $b.DiskspdRun = {
        param([string]$Exe, [string[]]$Arguments)
        $line = @($Arguments) -join ' '
        [void]$store.Log.Add("Diskspd $line")
        if ($store.DiskspdExitCode -ne 0) { return [pscustomobject]@{ ExitCode = [int]$store.DiskspdExitCode; Output = ''; Error = 'fake failure' } }
        if ($store.DiskspdXml) { return [pscustomobject]@{ ExitCode = 0; Output = [string]$store.DiskspdXml; Error = '' } }
        $run = & $count 'run-disk'
        $key = if ($line -match '-b1M' -and $line -match '-w0') { 'seq.read' } elseif ($line -match '-b1M') { 'seq.write' } elseif ($line -match '-w100') { 'rw.qd1' } elseif ($line -match '-w30') { 'mix.qd32' } else { 'rr.qd1' }
        $seconds = 12.0
        if ($line -match '-d(\d+)') { $seconds = [double]$Matches[1] }
        $v = {
            param($id) if ($line -cmatch 'AVDTune-Bench-[0-9a-f]{32}') { $id = $id -replace '^host\.disk\.', 'fsl.' }; $x = & $value $id ([math]::Max(1, [math]::Floor(($run - 1) / 5) + 1)); $x
        }
        switch ($key) {
            'rr.qd1' { $xml = New-FakeDiskspdXml -Seconds $seconds -ReadP50 (& $v 'host.disk.rr.qd1.p50') -ReadP99 (& $v 'host.disk.rr.qd1.p99') -ReadCount 100000 -ReadBytes (100000 * 4096) }
            'rw.qd1' { $xml = New-FakeDiskspdXml -Seconds $seconds -WriteP50 (& $v 'host.disk.rw.qd1.p50') -WriteP99 (& $v 'host.disk.rw.qd1.p99') -WriteCount 20000 -WriteBytes (20000 * 4096) }
            'mix.qd32' { $iops = & $v 'host.disk.mix.qd32'; $xml = New-FakeDiskspdXml -Seconds $seconds -ReadCount ([long]($iops * $seconds * 0.7)) -WriteCount ([long]($iops * $seconds * 0.3)) -ReadBytes ([long]($iops * $seconds * 0.7 * 4096)) -WriteBytes ([long]($iops * $seconds * 0.3 * 4096)) -Threads 4 }
            'seq.read' { $mb = & $v 'host.disk.seq.read'; $xml = New-FakeDiskspdXml -Seconds $seconds -ReadCount ([long]($mb * $seconds)) -ReadBytes ([long]($mb * $seconds * 1MB)) }
            'seq.write' { $mb = & $v 'host.disk.seq.write'; $xml = New-FakeDiskspdXml -Seconds $seconds -WriteCount ([long]($mb * $seconds)) -WriteBytes ([long]($mb * $seconds * 1MB)) }
        }
        [pscustomobject]@{ ExitCode = 0; Output = $xml; Error = '' }
    }.GetNewClosure()
    $b.RestoreTaskRegister = {
        param([string]$ScriptPath)
        if ($store.TaskRegisterFails) { throw 'fake: task scheduler refused' }
        if (-not (Test-Path -LiteralPath $ScriptPath)) { throw "fake: the restore script is not there: $ScriptPath" }
        $store.Tasks['AVDTune-BenchmarkRestore'] = $ScriptPath; [void]$store.Log.Add("TaskRegister $ScriptPath")
    }.GetNewClosure()
    $b.RestoreTaskRemove = { $store.Tasks.Remove('AVDTune-BenchmarkRestore'); [void]$store.Log.Add('TaskRemove') }.GetNewClosure()
    $b.RestoreTaskExists = { $store.Tasks.ContainsKey('AVDTune-BenchmarkRestore') }.GetNewClosure()
    $b.LeftoverScan = {
        # like the real scan: share test folders that still exist, attached containers (Volumes with the label), mount points and Edge/Office leftovers of the work folder
        param([string]$Root)
        $l = @()
        foreach ($d in @($store.ShareFolders.Keys)) { $l += "share test folder $d" }
        foreach ($v in @($store.Volumes)) { $l += 'attached container (volume label AVDTuneBench)' }
        foreach ($m in @($store.WorkLeftovers)) { $l += "work leftover $m" }
        $l
    }.GetNewClosure()
    $b.NetDns = { param([string]$Name) [void]$store.Log.Add("Dns $Name"); if ($store.Offline) { $null } else { 14.0 + ($store.Log.Count % 3) } }.GetNewClosure()
    $b.NetTcp = { param([string]$Name, [int]$Port, [int]$TimeoutMs) [void]$store.Log.Add("Tcp $Name $Port"); if ($store.Offline) { $null } else { 10.0 + ($store.Log.Count % 5) } }.GetNewClosure()
    $b.NetDownload = {
        param([string]$Url, [int]$Streams, [int]$Seconds, [long]$TotalBytes)
        [void]$store.Log.Add("NetDownload $Url $Streams $Seconds")
        if ($store.Offline) { return [pscustomobject]@{ Bytes = 0; Seconds = $Seconds; Errors = $Streams } }
        [pscustomobject]@{ Bytes = [long](800e6 / 8 * $Seconds * 1.2); Seconds = [double]$Seconds; Errors = 0 }
    }.GetNewClosure()
    $b.SystemFacts = { [pscustomobject]@{ CpuModel = 'Fake CPU 3.0 GHz'; VCpu = 8; RamGiB = 32.0; OsDiskSizeGiB = 128; Controller = 'SCSI'; MediaType = 'SSD' } }.GetNewClosure()
    ConvertTo-AVDTuneFakeShared ([pscustomobject]$b)
}
