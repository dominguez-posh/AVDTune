<#
    AVDTune benchmark orchestration (docs\benchmark-design.md, plan section 6). No UI: the GUI, Start-AVDTune.ps1 -Benchmark and the stand-alone
    script use this code.

    This round (issue #14, part 1): host categories CPU, memory, OS disk (diskspd), remote display and network; warm-up run, 3 runs, median, CV;
    index and score against a reference file; result file without secrets; storing in the state; change log entry; quiet mode with restore journal
    and crash repair; comparison with the baseline.
    Round 2 (issue #14): application starts and Speedometer (measure program command apps), FSLogix score (diskspd on the share, share test, VirtDisk
    profile container), GPU score (partial: no hardware encode/decode yet), capacity simulation (optional), HTML report per image version with the
    comparison to the previous version. Reference values of the new measures are placeholders marked "nicht kalibriert".
    NOT yet: PDF export, SharePoint, benchmark-only mode (#5), stand-alone script, Outlook and Teams starts, UI Automation, disturber watch, automatic
    repeat of unstable measures.

    All access to the machine goes through adapters, so the checks run against fakes (Tests\Fakes\FakeMachine.ps1, Tests\Fakes\FakeBench.ps1):
      Machine  = New-AVDTuneMachine (registry, services; Modules\AVDTune.psm1)
      Bench    = New-AVDTuneBenchAdapter (this file): measure program, diskspd, downloads, network, sessions, scheduled task, lock.
    The reference file Bench\data\references-B1.0.json holds PLACEHOLDER values until the reference VMs are measured: every result says so
    ("vorlaeufig, nicht gemessen").
#>

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'AVDTune.psm1')
Import-Module (Join-Path $PSScriptRoot 'AVDTune.Updates.psm1')   # Test-AVDTuneToolTrust, Get-AVDTuneSystemFolder, Test-AVDTuneAdminOnlyPath
Import-Module (Join-Path $PSScriptRoot 'AVDTune.Trust.psm1')   # Remove-AVDTuneFolderNoFollow
Import-Module (Join-Path $PSScriptRoot 'AVDTune.Release.psm1')   # Open-AVDTuneVerifiedBenchExe: the measure program is only started after the check against the release manifest (issue #19)

$script:DataDefault = Join-Path (Split-Path $PSScriptRoot -Parent) 'Bench\data'
$script:RestoreTaskName = 'AVDTune-BenchmarkRestore'
$script:QuietServices = @('wuauserv', 'UsoSvc', 'WSearch')
$script:SecretPattern = '(?i)password|passwd|secret|token|credential|apikey|accountkey|sastoken|connectionstring'

#region data

function Get-AVDTuneBenchmarkConfig {
    param([string]$DataPath = $script:DataDefault)
    $file = Join-Path $DataPath 'benchmark-B1.0.json'
    if (-not (Test-Path -LiteralPath $file)) { throw "Benchmark data not found: $file" }
    Read-AVDTuneJson $file
}

function Get-AVDTuneBenchmarkReference {
    # The frozen reference values of the benchmark version. Provisional = placeholder, not measured (see the file)
    param([string]$DataPath = $script:DataDefault, [string]$Name = 'references-B1.0')
    if ($Name -notmatch '^references-B\d+\.\d+$') { throw "Invalid reference name '$Name'." }
    $file = Join-Path $DataPath "$Name.json"
    if (-not (Test-Path -LiteralPath $file)) { throw "Reference file not found: $file" }
    $ref = Read-AVDTuneJson $file
    [pscustomobject]@{
        Name = $Name; BenchmarkVersion = [string]$ref.benchmarkVersion; Provisional = [bool](Get-AVDTuneProp $ref 'provisional')
        Status = [string](Get-AVDTuneProp $ref 'status'); Measures = $ref.measures
    }
}

function Get-AVDTuneBenchCategorySet {
    # The categories of one of the three scores: host (Config.categories), fslogix, gpu
    param([Parameter(Mandatory)]$Config, [ValidateSet('host', 'fslogix', 'gpu')][string]$Set = 'host')
    switch ($Set) { 'host' { $Config.categories } 'fslogix' { $Config.fslogixCategories } 'gpu' { $Config.gpuCategories } }
}

function Get-AVDTuneBenchCategoryKey {
    # Category of a measure id by its prefix, or $null
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Id, [ValidateSet('host', 'fslogix', 'gpu')][string]$Set = 'host')
    foreach ($c in (Get-AVDTuneBenchCategorySet $Config $Set).PSObject.Properties) {
        foreach ($p in @($c.Value.prefixes)) { if ($Id.StartsWith($p, [StringComparison]::Ordinal)) { return $c.Name } }
    }
    $null
}

#endregion

#region evaluation maths (same as Bench\src\Evaluation.cs, checked against the design example in both)

function Get-AVDTuneBenchRound([double]$Value) {
    # Indexes and scores are shown as whole numbers, half away from zero like the design example (1312.5 is 1313); [math]::Round alone rounds half to even
    [math]::Round($Value, 0, [MidpointRounding]::AwayFromZero)
}

function Get-AVDTuneBenchMedian([double[]]$Values) {
    if (@($Values).Count -eq 0) { throw 'No values.' }
    $s = @($Values | Sort-Object)
    $n = $s.Count
    if ($n % 2 -eq 1) { [double]$s[[int](($n - 1) / 2)] } else { ([double]$s[$n / 2 - 1] + [double]$s[$n / 2]) / 2.0 }
}

function Get-AVDTuneBenchCv([double[]]$Values) {
    # Coefficient of variation in percent: sample standard deviation / mean x 100; 0 for one value
    $v = @($Values)
    if ($v.Count -lt 2) { return 0.0 }
    $mean = ($v | Measure-Object -Average).Average
    if ($mean -eq 0) { return 0.0 }
    $ss = 0.0; foreach ($x in $v) { $ss += ($x - $mean) * ($x - $mean) }
    [math]::Sqrt($ss / ($v.Count - 1)) / [math]::Abs($mean) * 100.0
}

function Get-AVDTuneBenchIndex {
    # 1000 x value / reference (higher is better), 1000 x reference / value (lower is better)
    param([Parameter(Mandatory)][double]$Value, [Parameter(Mandatory)][double]$Reference, [Parameter(Mandatory)][ValidateSet('higher', 'lower')][string]$Better)
    if ($Value -le 0 -or $Reference -le 0) { throw 'Value and reference must be positive.' }
    if ($Better -eq 'higher') { 1000.0 * $Value / $Reference } else { 1000.0 * $Reference / $Value }
}

function Get-AVDTuneBenchGeometricMean([double[]]$Values) {
    $v = @($Values)
    if ($v.Count -eq 0) { throw 'No values.' }
    $sum = 0.0; foreach ($x in $v) { $sum += [math]::Log($x) }
    [math]::Exp($sum / $v.Count)
}

function Get-AVDTuneBenchWeightedGeometricMean([double[]]$Values, [double[]]$Weights) {
    $v = @($Values); $w = @($Weights)
    if ($v.Count -eq 0 -or $v.Count -ne $w.Count) { throw 'Values and weights must have the same, non-zero length.' }
    $sw = ($w | Measure-Object -Sum).Sum
    if ($sw -le 0) { throw 'Weights must sum to a positive number.' }
    $s = 0.0; for ($i = 0; $i -lt $v.Count; $i++) { $s += $w[$i] * [math]::Log($v[$i]) }
    [math]::Exp($s / $sw)
}

function Get-AVDTuneBenchPercentile([double[]]$Values, [double]$Percent) {
    # nearest rank
    $s = @($Values | Sort-Object)
    if ($s.Count -eq 0) { throw 'No values.' }
    $rank = [int][math]::Ceiling($Percent / 100.0 * $s.Count)
    [double]$s[[math]::Max(0, [math]::Min($s.Count - 1, $rank - 1))]
}

function Get-AVDTuneBenchmarkScores {
    <#
        Category indexes and the Host score from aggregated measures (objects with Id, Status, Index). A category is the geometric mean of the indexes of its
        measures, the score the weighted geometric mean of the categories that ran (design 2.2). Categories that did not run, or are not built yet, are listed
        in Missing: the score is then a partial score and says so.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Measures, [Parameter(Mandatory)]$Config, [double]$UnstableCv = 10, [ValidateSet('host', 'fslogix', 'gpu')][string]$Set = 'host')
    $cats = [ordered]@{}
    $missing = @()
    $unstableAny = $false
    $uncalAny = $false
    foreach ($c in (Get-AVDTuneBenchCategorySet $Config $Set).PSObject.Properties) {
        $mine = @($Measures | Where-Object { (Get-AVDTuneBenchCategoryKey $Config $_.Id -Set $Set) -eq $c.Name -and $_.Status -eq 'ok' -and $null -ne (Get-AVDTuneProp $_ 'Index') })
        if ($mine.Count -eq 0) { $missing += $c.Name; continue }
        $idx = Get-AVDTuneBenchGeometricMean ([double[]]@($mine | ForEach-Object { [double]$_.Index }))
        $unstable = @($mine | Where-Object { Get-AVDTuneProp $_ 'Unstable' }).Count -gt 0
        if ($unstable) { $unstableAny = $true }
        $uncal = @($mine | Where-Object { (Get-AVDTuneProp $_ 'Calibrated') -eq $false }).Count -gt 0
        if ($uncal) { $uncalAny = $true }
        $cats[$c.Name] = [ordered]@{ index = (Get-AVDTuneBenchRound $idx); weight = [double]$c.Value.weight; measures = $mine.Count; unstable = $unstable; uncalibrated = $uncal; title = [string]$c.Value.title }
    }
    $hostScore = $null
    if ($cats.Count -gt 0) {
        $values = [double[]]@($cats.Values | ForEach-Object { [double]$_.index })
        $weights = [double[]]@($cats.Values | ForEach-Object { [double]$_.weight })
        $hostScore = Get-AVDTuneBenchRound (Get-AVDTuneBenchWeightedGeometricMean $values $weights)
    }
    [pscustomobject]@{ Host = $hostScore; Categories = $cats; Missing = @($missing); Partial = ($missing.Count -gt 0); Unstable = $unstableAny; Uncalibrated = $uncalAny }
}

#endregion

#region diskspd output

function ConvertFrom-AVDTuneDiskspdXml {
    <#
        Parses the XML of diskspd -Rxml: seconds, IOPS, MiB/s and the latency percentiles. Totals come from the Thread/Target elements (summed);
        percentiles from TimeSpan/Latency/Bucket. A missing field is an error, never a guess: the measure then fails with the reason.
    #>
    param([Parameter(Mandatory)][string]$Xml)
    $inv = [Globalization.CultureInfo]::InvariantCulture
    try { $doc = [xml]$Xml } catch { throw "diskspd output is not XML: $($_.Exception.Message)" }
    $span = $doc.SelectSingleNode('//Results/TimeSpan')
    if (-not $span) { throw 'diskspd XML: no TimeSpan element.' }
    $secNode = $span.SelectSingleNode('TestTimeSeconds')
    if (-not $secNode) { throw 'diskspd XML: no TestTimeSeconds.' }
    $seconds = [double]::Parse($secNode.InnerText, $inv)
    if ($seconds -le 0) { throw 'diskspd XML: TestTimeSeconds is not positive.' }
    $targets = @($span.SelectNodes('Thread/Target'))
    if ($targets.Count -eq 0) { throw 'diskspd XML: no Thread/Target elements.' }
    $sum = { param($name) $t = 0.0; foreach ($n in $targets) { $c = $n.SelectSingleNode($name); if (-not $c) { throw "diskspd XML: a target has no $name." }; $t += [double]::Parse($c.InnerText, $inv) }; $t }
    $readBytes = & $sum 'ReadBytes'; $readCount = & $sum 'ReadCount'; $writeBytes = & $sum 'WriteBytes'; $writeCount = & $sum 'WriteCount'
    $buckets = @($span.SelectNodes('Latency/Bucket'))
    $percentile = {
        param($which, $p)
        foreach ($b in $buckets) {
            $pn = $b.SelectSingleNode('Percentile')
            if ($pn -and [math]::Abs([double]::Parse($pn.InnerText, $inv) - $p) -lt 0.0001) {
                $vn = $b.SelectSingleNode($which)
                if (-not $vn) { throw "diskspd XML: bucket $p has no $which." }
                return [double]::Parse($vn.InnerText, $inv)
            }
        }
        $null
    }
    [pscustomobject]@{
        Seconds = $seconds; ReadCount = $readCount; WriteCount = $writeCount; ReadBytes = $readBytes; WriteBytes = $writeBytes
        Iops = ($readCount + $writeCount) / $seconds
        ReadMiBps = $readBytes / 1MB / $seconds; WriteMiBps = $writeBytes / 1MB / $seconds
        ReadLatencyP50 = (& $percentile 'ReadMilliseconds' 50); ReadLatencyP99 = (& $percentile 'ReadMilliseconds' 99)
        WriteLatencyP50 = (& $percentile 'WriteMilliseconds' 50); WriteLatencyP99 = (& $percentile 'WriteMilliseconds' 99)
    }
}

#endregion

#region child processes (issue #19)

$script:Limits = @{ BenchMs = 600000; DiskspdMs = 900000; AppsMs = 1800000; CapacityMs = 3300000 }      # timeouts; the checks lower them in module scope
$script:Hooks = @{ AclReader = $null }   # test hook: a fake ACL reader for the TEMP folder check

function Initialize-AVDTuneBenchTemp {
    # TEMP of the measure program: <state>\temp\bench, administrators only (the folder logic is Initialize-AVDTuneToolTemp in AVDTune.psm1, issue #47)
    param([Parameter(Mandatory)][string]$StateRoot)
    Initialize-AVDTuneToolTemp -Tool bench -StateRoot $StateRoot -ReadAcl $script:Hooks.AclReader
}

#endregion
#region adapter (real)

function New-AVDTuneBenchAdapter {
    <#
        The real benchmark adapter. Reading members change nothing. Writing members: Download (a file under the tool folder), Expand, RestoreTaskRegister /
        RestoreTaskRemove (one scheduled task), Lock (a named mutex), DiskspdRun and RunBench (load on this computer). Tests use New-AVDTuneFakeBench.
        The measure program (issue #19) is never searched for: it is the file of the release this copy of AVDTune runs from (<install folder>\<version>\Bench\bin),
        and before every start Open-AVDTuneVerifiedBenchExe checks it against the release manifest of that version and holds it open while the process starts.
        A development checkout or a copy outside the install folder cannot run it. -InstallRoot, -StateRoot and -Manifest exist for the checks and only work
        inside the test mode (Test-AVDTuneTestMode).
    #>
    param([string]$AppRoot, [string]$InstallRoot, [string]$StateRoot, $Manifest)
    if (-not $AppRoot) { $AppRoot = Split-Path $PSScriptRoot -Parent }
    if (-not $InstallRoot) { $InstallRoot = Get-AVDTuneInstallRoot }
    if (-not $StateRoot) { $StateRoot = Get-AVDTuneRoot }
    if (($PSBoundParameters.ContainsKey('AppRoot') -or $PSBoundParameters.ContainsKey('Manifest') -or $PSBoundParameters.ContainsKey('StateRoot') -or $PSBoundParameters.ContainsKey('InstallRoot')) -and -not (Test-AVDTuneTestMode).Enabled) { throw 'The measure program is always the one of the release this copy runs from (the parameters are for the checks).' }
    $engineState = @{ Problem = '' }
    $limits = $script:Limits
    $b = [ordered]@{ Kind = 'Real' }
    $b.Elevated = { Test-AVDTuneElevated }
    $b.OtherSessions = {
        # interactive sessions of other users (active or disconnected): the processes sihost/explorer in another session. $null when it cannot be asked
        try {
            $me = (Get-Process -Id $PID).SessionId
            $seen = @{}
            foreach ($p in @(Get-Process -Name sihost, explorer -IncludeUserName -ErrorAction Stop)) {
                if ($p.SessionId -ne $me -and $p.SessionId -ne 0 -and -not $seen.ContainsKey($p.SessionId)) { $seen[$p.SessionId] = [string]$p.UserName }
            }
            @($seen.Keys | ForEach-Object { [pscustomobject]@{ Id = $_; User = $seen[$_] } })
        }
        catch { $null }
    }
    $b.UptimeMinutes = { ((Get-Date) - (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime).TotalMinutes }
    $b.CpuLoad = {
        # average total CPU percent over N seconds (CIM, so it does not depend on the language of the counter names)
        param([int]$Seconds)
        $vals = @()
        for ($i = 0; $i -lt [math]::Max(1, $Seconds); $i++) {
            $p = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'"
            $vals += [double]$p.PercentProcessorTime
            Start-Sleep -Seconds 1
        }
        ($vals | Measure-Object -Average).Average
    }
    $b.FreeGiB = { param($Path) $d = New-Object System.IO.DriveInfo ([IO.Path]::GetPathRoot($Path)); $d.AvailableFreeSpace / 1GB }
    $b.PendingReboot = {
        (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
        (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or
        ($null -ne (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue))
    }
    $b.OnBattery = { $bat = @(Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue); ($bat.Count -gt 0 -and $bat[0].BatteryStatus -eq 1) }
    $b.UpdateInstallerBusy = {
        # not verified against IUpdateInstaller.IsBusy (per instance); the servicing process is the visible sign
        [bool](Get-Process -Name TiWorker -ErrorAction SilentlyContinue)
    }
    $b.Sleep = { param([int]$Milliseconds) Start-Sleep -Milliseconds $Milliseconds }
    $b.Lock = {
        # one benchmark at a time: a named mutex that only SYSTEM and Administrators can open. Returns a handle (Release it with Unlock) or $null when busy
        $created = $false
        $sec = New-Object System.Security.AccessControl.MutexSecurity
        foreach ($sid in 'S-1-5-18', 'S-1-5-32-544') { $sec.AddAccessRule((New-Object System.Security.AccessControl.MutexAccessRule((New-Object System.Security.Principal.SecurityIdentifier $sid), [System.Security.AccessControl.MutexRights]::FullControl, [System.Security.AccessControl.AccessControlType]::Allow))) }
        try { $mx = [System.Threading.Mutex]::new($false, 'Global\AVDTune.Benchmark', [ref]$created, $sec) } catch { return $null }
        $got = $false
        try { $got = $mx.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $got = $true }
        if ($got) { $mx } else { $mx.Dispose(); $null }
    }
    $b.Unlock = { param($Handle) if ($Handle) { try { $Handle.ReleaseMutex() } catch { }; $Handle.Dispose() } }
    $b.EngineInfo = {
        # $null when the measure program cannot be started (EngineProblem says why); otherwise its SHA256 is the one the release manifest names (checked just now)
        $v = $null
        try {
            $v = Open-AVDTuneVerifiedBenchExe -AppRoot $AppRoot -InstallRoot $InstallRoot -StateRoot $StateRoot -Manifest $Manifest
            $engineState.Problem = ''
            [pscustomobject]@{ Path = $v.Path; Version = $v.Version; Sha256 = $v.Sha256; Verified = $true }
        }
        catch { $engineState.Problem = $_.Exception.Message; $null }
        finally { if ($v) { $v.Stream.Dispose() } }
    }.GetNewClosure()
    $b.EngineProblem = { [string]$engineState.Problem }.GetNewClosure()
    $runner = {
        # Runs the measure program and parses its JSON. Arguments are fixed words and numbers made by this module, never user text
        param([string]$Command, [string[]]$Arguments, [int]$TimeoutMs, [bool]$Extended)
        if ($Command -notmatch '^[a-z]+$') { throw "Invalid command '$Command'." }
        # checked against the release manifest right before this start, and held open (no write, delete or rename) until the process has started
        $verified = Open-AVDTuneVerifiedBenchExe -AppRoot $AppRoot -InstallRoot $InstallRoot -StateRoot $StateRoot -Manifest $Manifest
        $cmdLine = (@($Command) + @($Arguments) | ForEach-Object { ConvertTo-AVDTuneArgument ([string]$_) }) -join ' '
        # environment allowlist, TEMP in an administrators-only folder, timeout with the whole tree ended, kill on close
        # the verified file stays held (no write, delete, rename) until the process has ended
        try { $r = Invoke-AVDTuneChildProcess -FileName $verified.Path -Arguments $cmdLine -TimeoutMs $TimeoutMs -CleanEnvironment -TempDir (Initialize-AVDTuneBenchTemp -StateRoot $StateRoot) -Tool $(if ($Extended) { 'apps' } else { 'bench' }) }
        finally { $verified.Stream.Dispose() }
        if ($r.TimedOut) { throw "AVDTune.Bench $Command did not finish in time and was ended with everything it had started." }
        if ($r.ExitCode -ne 0) { throw "AVDTune.Bench $Command failed (exit $($r.ExitCode)): $($r.Error.Trim())" }
        $r.Output | ConvertFrom-Json
    }.GetNewClosure()
    $b.RunBench = { param([string]$Command, [string[]]$Arguments) & $runner $Command $Arguments $limits.BenchMs $false }.GetNewClosure()
    $b.RunApps = {
        # The programs of the application starts (checklist "Programs started"): the full path from HKLM (App Paths) or the Windows folders (never PATH or the environment),
        # the file in an administrator-only place, Authenticode of Microsoft (exact subject, issuer and original file name, Test-AVDTuneToolTrust), and every checked file is
        # HELD OPEN (no write, delete, rename) until the run is over, so it cannot be swapped between check and start. Returns the parsed JSON; programs that are not
        # installed or not trusted are not passed, the measure program then marks their measures as skipped.
        param([string]$Command, [string[]]$Arguments, [string[]]$Programs = @('word', 'excel', 'edge', 'explorer', 'powershell'))
        if ($Command -notin 'apps', 'capacity') { throw "Invalid command '$Command'." }
        $held = @(); $args2 = @($Arguments); $refused = @()
        try {
            foreach ($key in $Programs) {
                $path = Get-AVDTuneAppProgramPath -Key $key
                if (-not $path) { continue }
                $file = [IO.Path]::GetFileName($path)
                $parent = [IO.Path]::GetDirectoryName($path)
                $base = [IO.Path]::GetDirectoryName($parent)
                $okAcl = $false
                foreach ($rootName in 'ProgramFiles', 'ProgramFilesX86', 'Windows') { $r0 = Get-AVDTuneSystemFolder $rootName; if ($path.StartsWith($r0.TrimEnd([char]92) + [char]92, [StringComparison]::OrdinalIgnoreCase)) { $okAcl = Test-AVDTuneAdminOnlyPath -Path $path -Base (Split-Path $r0 -Parent); break } }
                if (-not $okAcl) { $refused += "$key (not in an administrator-only folder)"; continue }
                $stream = $null
                try { $stream = New-Object IO.FileStream($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read) } catch { $refused += "$key (cannot be held open: $($_.Exception.Message))"; continue }
                $held += $stream
                $s = Get-AuthenticodeSignature -LiteralPath $path
                $orig = ''; try { $orig = [string](Get-Item -LiteralPath $path).VersionInfo.OriginalFilename } catch { }
                $sig = [pscustomobject]@{ Valid = ($s.Status -eq 'Valid'); Status = [string]$s.Status; Subject = $(if ($s.SignerCertificate) { [string]$s.SignerCertificate.Subject } else { '' }); Issuer = $(if ($s.SignerCertificate) { [string]$s.SignerCertificate.Issuer } else { '' }); OriginalFilename = $orig }
                $t = Test-AVDTuneToolTrust -Signature $sig -Name $file
                if (-not $t.Ok) { $stream.Dispose(); $held = @($held | Where-Object { $_ -ne $stream }); $refused += "$key ($($t.Reason))"; continue }
                $args2 += @('--app', "$key=$path")
            }
            $timeout = if ($Command -eq 'capacity') { $limits.CapacityMs } else { $limits.AppsMs }
            $json = & $runner $Command $args2 $timeout ($Command -eq 'apps')
            if ($refused.Count -gt 0 -and $json.PSObject.Properties['info'] -eq $null) { $json | Add-Member -NotePropertyName info -NotePropertyValue ([pscustomobject]@{}) }
            if ($refused.Count -gt 0) { $json | Add-Member -NotePropertyName refusedPrograms -NotePropertyValue @($refused) -Force }
            $json
        }
        finally { foreach ($h in $held) { $h.Dispose() } }
    }.GetNewClosure()
    $b.ShareMakeFolder = {
        # a new test folder below the share (a GUID name made by this module); never an existing one, never a link
        param([string]$Unc)
        if ($Unc -notmatch '^\\\\[A-Za-z0-9][A-Za-z0-9.-]{0,200}\\[A-Za-z0-9._$ -]{1,80}(\\[A-Za-z0-9._ -]{1,80}){0,4}$') { throw 'The share path is not a plain UNC path.' }
        if ($Unc -match '(^|\\)\.+(\\|$)') { throw 'The share path is not a plain UNC path.' }
        $dir = Join-Path $Unc ('AVDTune-Bench-' + [guid]::NewGuid().ToString('N'))
        # created in ONE step with a protected DACL (current administrator, SYSTEM, Administrators; no inheritance from the share): nobody else can prepare or swap what is inside
        $sec = New-Object System.Security.AccessControl.DirectorySecurity
        $sec.SetAccessRuleProtection($true, $false)
        $me = [Security.Principal.WindowsIdentity]::GetCurrent().User
        foreach ($sid in @($me, (New-Object Security.Principal.SecurityIdentifier 'S-1-5-18'), (New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544'))) {
            $sec.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow')))
        }
        $info = New-Object IO.DirectoryInfo $dir
        $info.Create($sec)
        $info.Refresh()
        if (($info.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'The test folder on the share is a link.' }
        # afterwards: the owner is us, Administrators or SYSTEM, and there is no rule for anyone else
        $acl = $info.GetAccessControl()
        $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
        $allowed = @($me.Value, 'S-1-5-18', 'S-1-5-32-544')
        $foreign = @($acl.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]) | Where-Object { $_.IdentityReference.Value -notin $allowed })
        if ($owner -notin $allowed -or $foreign.Count -gt 0) { throw 'The test folder on the share has a foreign owner or rule; it is not used.' }
        $dir
    }
    $b.ShareRemoveFolder = { param([string]$Dir) if ($Dir -notmatch 'AVDTune-Bench-[0-9a-f]{32}$') { throw 'Not a test folder of AVDTune.' }; if (Test-Path -LiteralPath $Dir) { Remove-AVDTuneFolderNoFollow $Dir } }
    $b.VhdCycle = {
        param([string]$ShareFolder, [string]$MountRoot, [int]$Index, [int]$SizeGiB, [int]$WriteMB)
        Invoke-AVDTuneVhdCycle -ShareFolder $ShareFolder -MountRoot $MountRoot -Index $Index -SizeGiB $SizeGiB -WriteMB $WriteMB
    }
    $b.VhdParallel = {
        # N containers at the same time (users logging on together): wall time of all cycles. Each cycle runs in its own runspace (the function text is passed on)
        param([string]$ShareFolder, [string]$MountRoot, [int]$Count, [int]$SizeGiB, [int]$WriteMB)
        $text = (Get-Command Invoke-AVDTuneVhdCycle).ScriptBlock.ToString()
        $pool = (New-AVDTuneRunspacePool -Min 1 -Max $Count); $pool.Open()
        $jobs = @(); $sw = [Diagnostics.Stopwatch]::StartNew()
        try {
            for ($i = 2; $i -lt 2 + $Count; $i++) {
                $ps = New-AVDTunePowerShell; $ps.RunspacePool = $pool
                [void]$ps.AddScript($text).AddParameter('ShareFolder', $ShareFolder).AddParameter('MountRoot', $MountRoot).AddParameter('Index', $i).AddParameter('SizeGiB', $SizeGiB).AddParameter('WriteMB', $WriteMB)
                $jobs += [pscustomobject]@{ PS = $ps; Handle = $ps.BeginInvoke() }
            }
            $attach = @()
            foreach ($j in $jobs) { $r = @($j.PS.EndInvoke($j.Handle)); if ($j.PS.Streams.Error.Count -gt 0) { throw $j.PS.Streams.Error[0].Exception.Message }; $attach += [double]$r[-1].Attach }
            $sw.Stop()
            [pscustomobject]@{ WallSeconds = $sw.Elapsed.TotalSeconds; AttachP95 = (Get-AVDTuneBenchPercentile ([double[]]$attach) 95) }
        }
        finally { foreach ($j in $jobs) { $j.PS.Dispose() }; $pool.Close() }
    }
    $b.Download = {
        param([string]$Url, [string]$Path)
        if ($Url -notmatch '^https://') { throw 'Only https downloads are allowed.' }
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $wc = New-Object System.Net.WebClient
        try { $wc.DownloadFile($Url, $Path) } finally { $wc.Dispose() }
    }
    $b.HashFile = { param($Path) (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
    $b.FileLength = { param($Path) (Get-Item -LiteralPath $Path).Length }
    $b.Signature = {
        param($Path)
        $s = Get-AuthenticodeSignature -LiteralPath $Path
        [pscustomobject]@{ Status = [string]$s.Status; Subject = $(if ($s.SignerCertificate) { [string]$s.SignerCertificate.Subject } else { '' }) }
    }
    $b.Expand = {
        param($Zip, $Destination)
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($Zip, $Destination)
    }
    $b.DiskspdRun = {
        param([string]$Exe, [string[]]$Arguments)
        $r = Invoke-AVDTuneChildProcess -FileName $Exe -Arguments (($Arguments | ForEach-Object { ConvertTo-AVDTuneArgument ([string]$_) }) -join ' ') -TimeoutMs $limits.DiskspdMs -CleanEnvironment -TempDir (Initialize-AVDTuneBenchTemp -StateRoot $StateRoot)
        if ($r.TimedOut) { throw 'diskspd did not finish in time and was ended with everything it had started.' }
        [pscustomobject]@{ ExitCode = $r.ExitCode; Output = $r.Output; Error = $r.Error }
    }
    $b.RestoreTaskRegister = {
        # A SYSTEM task at start-up that runs the restore script from the protected state folder (never a script of the application folder)
        param([string]$ScriptPath)
        $a = Get-AVDTuneBenchRestoreAction -ScriptPath $ScriptPath
        $action = New-ScheduledTaskAction -Execute $a.Execute -Argument $a.Argument
        $trigger = New-ScheduledTaskTrigger -AtStartup
        $principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
        [void](Register-ScheduledTask -TaskName $script:RestoreTaskName -Action $action -Trigger $trigger -Principal $principal -Force)
    }
    $b.RestoreTaskRemove = { Unregister-ScheduledTask -TaskName $script:RestoreTaskName -Confirm:$false -ErrorAction SilentlyContinue }
    $b.RestoreTaskExists = { [bool](Get-ScheduledTask -TaskName $script:RestoreTaskName -ErrorAction SilentlyContinue) }
    $b.LeftoverScan = {
        # leftovers of round 2 that live outside the state folder: test folders AVDTune-Bench-<guid> on the FSLogix share, attached containers (volume label AVDTuneBench), mount points
        # (mnt<n> folders that are still mount points) and Edge or Office leftovers in a work folder. Reads only.
        param([string]$Root)
        $found = @()
        try {
            $vl = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\FSLogix\Profiles' -ErrorAction Stop).VHDLocations
            foreach ($loc in @($vl)) { if ([string]$loc -match '^\\\\') { foreach ($d in @(Get-ChildItem -LiteralPath ([string]$loc) -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^AVDTune-Bench-[0-9a-f]{32}$' })) { $found += "share test folder $($d.FullName)" } } }
        } catch { }
        try { foreach ($v in @(Get-Volume -ErrorAction Stop | Where-Object { $_.FileSystemLabel -eq 'AVDTuneBench' })) { $found += 'attached container (volume label AVDTuneBench)' } } catch { }
        $work = Join-Path $Root 'benchmark\work'
        if (Test-Path -LiteralPath $work) {
            foreach ($d in @(Get-ChildItem -LiteralPath $work -Recurse -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(mnt\d+|edge-.*|apps-.*|cap-.*)$' })) {
                $found += $(if ($d.Name -like 'mnt*') { "mount point $($d.FullName)" } else { "work leftover $($d.FullName)" })
            }
        }
        $found
    }
    $b.NetDns = {
        # one uncached DNS lookup, milliseconds, or $null on failure (DnsQuery_W with DNS_QUERY_BYPASS_CACHE)
        param([string]$Name)
        if (-not ('AVDTuneBenchNative.Dns' -as [type])) {
            Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices;
namespace AVDTuneBenchNative {
  public static class Dns {
    [DllImport("dnsapi.dll", CharSet = CharSet.Unicode)] static extern int DnsQuery_W(string name, ushort type, uint options, IntPtr extra, out IntPtr result, IntPtr reserved);
    [DllImport("dnsapi.dll")] static extern void DnsRecordListFree(IntPtr list, int freeType);
    public static double Query(string name) {
      var sw = System.Diagnostics.Stopwatch.StartNew(); IntPtr r;
      int rc = DnsQuery_W(name, 1, 0x8, IntPtr.Zero, out r, IntPtr.Zero);   // A record, DNS_QUERY_BYPASS_CACHE (0x8)
      sw.Stop();
      if (r != IntPtr.Zero) DnsRecordListFree(r, 1);
      return rc == 0 ? sw.Elapsed.TotalMilliseconds : -1;
    }
  }
}
"@
        }
        $ms = [AVDTuneBenchNative.Dns]::Query($Name)
        if ($ms -lt 0) { $null } else { $ms }
    }
    $b.NetTcp = {
        # one TCP connect, milliseconds, or $null on failure or timeout
        param([string]$Name, [int]$Port, [int]$TimeoutMs)
        $c = New-Object System.Net.Sockets.TcpClient
        try {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $ar = $c.BeginConnect($Name, $Port, $null, $null)
            if (-not $ar.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $null }
            $c.EndConnect($ar); $sw.Stop()
            $sw.Elapsed.TotalMilliseconds
        }
        catch { $null }
        finally { $c.Close() }
    }
    $b.NetDownload = {
        # N parallel HTTP range streams, data discarded (never written), stops after the seconds; returns bytes and seconds
        param([string]$Url, [int]$Streams, [int]$Seconds, [long]$TotalBytes)
        if ($Url -notmatch '^https://') { throw 'Only https downloads are allowed.' }
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        [Net.ServicePointManager]::DefaultConnectionLimit = [math]::Max(16, $Streams * 2)
        $bytes = New-Object long[] 1
        $errs = New-Object int[] 1
        $stop = [DateTime]::UtcNow.AddSeconds($Seconds)
        $part = [long][math]::Floor($TotalBytes / $Streams)
        $work = {
            param($Url, $From, $To, $Bytes, $Errs, $Stop)
            # every stream asks for its range again until the time is up (a fast link finishes one range in under a second)
            while ([DateTime]::UtcNow -lt $Stop) {
                try {
                    $req = [System.Net.HttpWebRequest]::Create($Url)
                    $req.AddRange([long]$From, [long]$To); $req.Timeout = 15000; $req.ReadWriteTimeout = 15000
                    $resp = $req.GetResponse(); $s = $resp.GetResponseStream()
                    $buf = New-Object byte[] 65536
                    while ([DateTime]::UtcNow -lt $Stop) { $n = $s.Read($buf, 0, $buf.Length); if ($n -le 0) { break }; [void][System.Threading.Interlocked]::Add([ref]$Bytes[0], [long]$n) }
                    $s.Close(); $resp.Close()
                }
                catch { [void][System.Threading.Interlocked]::Increment([ref]$Errs[0]); break }
            }
        }
        $pool = (New-AVDTuneRunspacePool -Min 1 -Max $Streams); $pool.Open()
        $jobs = @()
        $t0 = [DateTime]::UtcNow
        for ($i = 0; $i -lt $Streams; $i++) {
            $ps = New-AVDTunePowerShell; $ps.RunspacePool = $pool
            [void]$ps.AddScript($work).AddArgument($Url).AddArgument($i * $part).AddArgument(($i + 1) * $part - 1).AddArgument($bytes).AddArgument($errs).AddArgument($stop)
            $jobs += [pscustomobject]@{ PS = $ps; Handle = $ps.BeginInvoke() }
        }
        foreach ($j in $jobs) { [void]$j.PS.EndInvoke($j.Handle); $j.PS.Dispose() }
        $pool.Close()
        [pscustomobject]@{ Bytes = [long]$bytes[0]; Seconds = ([DateTime]::UtcNow - $t0).TotalSeconds; Errors = [int]$errs[0] }
    }
    $b.SystemFacts = {
        $cpu = @(Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1)
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem
        $facts = [ordered]@{ CpuModel = ([regex]::Replace([string]$cpu[0].Name, '\s+', ' ')).Trim(); VCpu = [int]$cs.NumberOfLogicalProcessors; RamGiB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1); OsDiskSizeGiB = $null; Controller = ''; MediaType = '' }
        try {
            $letter = $env:SystemDrive.TrimEnd(':')
            $part = Get-Partition -DriveLetter $letter -ErrorAction Stop
            $disk = Get-Disk -Number $part.DiskNumber -ErrorAction Stop
            $facts.OsDiskSizeGiB = [math]::Round($disk.Size / 1GB, 0); $facts.Controller = [string]$disk.BusType
            $pd = @(Get-PhysicalDisk -ErrorAction SilentlyContinue | Where-Object { $_.DeviceId -eq [string]$part.DiskNumber })
            if ($pd.Count -gt 0) { $facts.MediaType = [string]$pd[0].MediaType }
        }
        catch { }
        [pscustomobject]$facts
    }
    [pscustomobject]$b
}

#endregion

#region application programs and profile container (round 2)

function Get-AVDTuneAppProgramPath {
    <#
        Full path of a program of the application starts, or $null when it is not installed. From HKLM (App Paths) or the Windows folders, never through the search path or
        the process environment. Keys: word, excel, edge (App Paths), explorer, powershell (Windows folders). The checks of the file itself are in the adapter (RunApps).
    #>
    param([Parameter(Mandatory)][ValidateSet('word', 'excel', 'edge', 'explorer', 'powershell')][string]$Key)
    $bs = [string][char]92
    if ($Key -eq 'explorer') { $p = Join-Path (Get-AVDTuneSystemFolder Windows) 'explorer.exe'; return $(if (Test-Path -LiteralPath $p -PathType Leaf) { $p } else { $null }) }
    if ($Key -eq 'powershell') { $p = Join-Path (Get-AVDTuneSystemFolder System) ('WindowsPowerShell' + $bs + 'v1.0' + $bs + 'powershell.exe'); return $(if (Test-Path -LiteralPath $p -PathType Leaf) { $p } else { $null }) }
    $exe = @{ word = 'winword.exe'; excel = 'excel.exe'; edge = 'msedge.exe' }[$Key]
    foreach ($hive in 'HKLM:' + $bs + 'SOFTWARE' + $bs + 'Microsoft' + $bs + 'Windows' + $bs + 'CurrentVersion' + $bs + 'App Paths' + $bs + $exe, 'HKLM:' + $bs + 'SOFTWARE' + $bs + 'WOW6432Node' + $bs + 'Microsoft' + $bs + 'Windows' + $bs + 'CurrentVersion' + $bs + 'App Paths' + $bs + $exe) {
        try {
            $v = [string](Get-ItemProperty -LiteralPath $hive -ErrorAction Stop).'(default)'
            $v = $v.Trim().Trim('"')
            if ($v -and [IO.Path]::IsPathRooted($v) -and $v -notlike ($bs + $bs + '*') -and (Test-Path -LiteralPath $v -PathType Leaf) -and [IO.Path]::GetFileName($v) -ieq $exe) { return [IO.Path]::GetFullPath($v) }
        }
        catch { }
    }
    $null
}

function Invoke-AVDTuneVhdCycle {
    <#
        One profile container like a logon and logoff of a user (design 1.2, VirtDisk API, no FSLogix needed): create a dynamic VHDX on the share and format it NTFS (create), attach it
        and mount it to a folder below the work folder, no drive letter (attach), write mixed files like a profile (write), flush and detach (detach), attach again and read all
        files (reattach). Seconds per step and MiB/s of the write. NOT verified on a real VM yet. The container is detached and deleted at the end, also on an error.
        Self-contained (own Add-Type), so it can run in a runspace for the parallel test.
    #>
    param([Parameter(Mandatory)][string]$ShareFolder, [Parameter(Mandatory)][string]$MountRoot, [int]$Index = 1, [int]$SizeGiB = 2, [int]$WriteMB = 200)
    if (-not ('AVDTuneBenchNative.Vhd' -as [type])) {
        Add-Type -TypeDefinition @"
using System; using System.ComponentModel; using System.Runtime.InteropServices; using System.Text;
namespace AVDTuneBenchNative {
  public static class Vhd {
    [StructLayout(LayoutKind.Sequential)] struct StorageType { public uint DeviceId; public Guid VendorId; }
    [StructLayout(LayoutKind.Sequential)] struct CreateParams { public uint Version; public Guid UniqueId; public ulong MaximumSize; public uint BlockSizeInBytes; public uint SectorSizeInBytes; public IntPtr ParentPath; public IntPtr SourcePath; }
    [DllImport("virtdisk.dll", CharSet = CharSet.Unicode)] static extern int CreateVirtualDisk(ref StorageType t, string path, uint access, IntPtr sd, uint flags, uint providerFlags, ref CreateParams p, IntPtr overlapped, out IntPtr handle);
    [DllImport("virtdisk.dll", CharSet = CharSet.Unicode)] static extern int OpenVirtualDisk(ref StorageType t, string path, uint access, uint flags, IntPtr p, out IntPtr handle);
    [DllImport("virtdisk.dll")] static extern int AttachVirtualDisk(IntPtr h, IntPtr sd, uint flags, uint providerFlags, IntPtr p, IntPtr overlapped);
    [DllImport("virtdisk.dll")] static extern int DetachVirtualDisk(IntPtr h, uint flags, uint providerFlags);
    [DllImport("virtdisk.dll", CharSet = CharSet.Unicode)] static extern int GetVirtualDiskPhysicalPath(IntPtr h, ref uint size, StringBuilder path);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    static StorageType Type() { StorageType t = new StorageType(); t.DeviceId = 3; t.VendorId = new Guid("ec984aec-a0f9-47e9-901f-71415a66345b"); return t; }
    static void Check(int rc, string what) { if (rc != 0) throw new Win32Exception(rc, what + " failed"); }
    public static void Create(string path, ulong bytes) {
      StorageType t = Type(); CreateParams p = new CreateParams(); p.Version = 1; p.MaximumSize = bytes; IntPtr h;
      Check(CreateVirtualDisk(ref t, path, 0, IntPtr.Zero, 0, 0, ref p, IntPtr.Zero, out h), "CreateVirtualDisk"); CloseHandle(h);
    }
    public static IntPtr Open(string path) { StorageType t = Type(); IntPtr h; Check(OpenVirtualDisk(ref t, path, 0x003f0000, 0, IntPtr.Zero, out h), "OpenVirtualDisk"); return h; }
    public static void Attach(IntPtr h) { Check(AttachVirtualDisk(h, IntPtr.Zero, 0x2, 0, IntPtr.Zero, IntPtr.Zero), "AttachVirtualDisk"); }   // ATTACH_VIRTUAL_DISK_FLAG_NO_DRIVE_LETTER
    public static void Detach(IntPtr h) { Check(DetachVirtualDisk(h, 0, 0), "DetachVirtualDisk"); }
    public static string PhysicalPath(IntPtr h) { uint size = 1024; StringBuilder sb = new StringBuilder(512); Check(GetVirtualDiskPhysicalPath(h, ref size, sb), "GetVirtualDiskPhysicalPath"); return sb.ToString(); }
    public static void Close(IntPtr h) { if (h != IntPtr.Zero) CloseHandle(h); }
  }
}
"@
    }
    $bs = [string][char]92
    if ($ShareFolder -notmatch 'AVDTune-Bench-[0-9a-f]{32}$') { throw 'The container goes only into a test folder of AVDTune.' }
    $vhd = Join-Path $ShareFolder "profile$Index.vhdx"
    $mnt = Join-Path $MountRoot "mnt$Index"
    if (Test-Path -LiteralPath $mnt) { throw "The mount folder $mnt exists already." }
    [void][IO.Directory]::CreateDirectory($mnt)
    $st = @{ h = [IntPtr]::Zero; disk = -1; part = -1 }
    $out = [ordered]@{ Create = $null; Attach = $null; WriteMBps = $null; Detach = $null; Reattach = $null }
    $time = { param($block) $sw = [Diagnostics.Stopwatch]::StartNew(); & $block; $sw.Stop(); $sw.Elapsed.TotalSeconds }
    $mount = {
        $deadline = [DateTime]::UtcNow.AddSeconds(60)
        $p = $null
        while ([DateTime]::UtcNow -lt $deadline -and -not $p) { $p = @(Get-Partition -DiskNumber $st.disk -ErrorAction SilentlyContinue | Where-Object { $_.Type -eq 'Basic' -or $_.Type -eq 'IFS' } | Select-Object -First 1)[0]; if (-not $p) { Start-Sleep -Milliseconds 100 } }
        if (-not $p) { throw 'The volume of the container did not come up.' }
        $st.part = $p.PartitionNumber
        Add-PartitionAccessPath -DiskNumber $st.disk -PartitionNumber $p.PartitionNumber -AccessPath $mnt -ErrorAction Stop
    }
    $unmount = { try { Remove-PartitionAccessPath -DiskNumber $st.disk -PartitionNumber $st.part -AccessPath $mnt -ErrorAction Stop } catch { } }
    try {
        $out.Create = & $time {
            [AVDTuneBenchNative.Vhd]::Create($vhd, [uint64]$SizeGiB * 1GB)
            $st.h = [AVDTuneBenchNative.Vhd]::Open($vhd); [AVDTuneBenchNative.Vhd]::Attach($st.h)
            $st.disk = [int]([regex]::Match([AVDTuneBenchNative.Vhd]::PhysicalPath($st.h), '(\d+)$').Groups[1].Value)
            Initialize-Disk -Number $st.disk -PartitionStyle GPT -ErrorAction Stop
            [void](New-Partition -DiskNumber $st.disk -UseMaximumSize -ErrorAction Stop)
            # no drive letter before the format (nothing may show up in Explorer or be indexed), checked again after the mount
            foreach ($pp in @(Get-Partition -DiskNumber $st.disk | Where-Object { $_.Type -eq 'Basic' })) { Set-Partition -DiskNumber $st.disk -PartitionNumber $pp.PartitionNumber -NoDefaultDriveLetter $true -ErrorAction Stop }
            [void](Get-Partition -DiskNumber $st.disk | Where-Object { $_.Type -eq 'Basic' } | Format-Volume -FileSystem NTFS -NewFileSystemLabel 'AVDTuneBench' -Confirm:$false -ErrorAction Stop)
            & $mount
            if (@(Get-Partition -DiskNumber $st.disk -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter -and [int]$_.DriveLetter -ne 0 }).Count -gt 0) { throw 'The container got a drive letter; it is not used.' }
        }
        $rng = New-Object Random 4242
        $buf = New-Object byte[] (4MB); $rng.NextBytes($buf)
        $files = New-Object System.Collections.ArrayList
        $writeSeconds = & $time {
            $total = [long]$WriteMB * 1MB; $done = 0L; $n = 0
            while ($done -lt $total) {
                $size = [int][math]::Min([math]::Min(4MB, $total - $done), [math]::Pow(2, 10 + $rng.NextDouble() * 12))
                $f = Join-Path $mnt ('f' + $n++ + '.dat')
                $fs = New-Object IO.FileStream($f, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None, 65536)
                try { $fs.Write($buf, 0, $size); $fs.Flush($true) } finally { $fs.Dispose() }
                [void]$files.Add($f); $done += $size
            }
        }
        $out.WriteMBps = $WriteMB / [math]::Max($writeSeconds, 0.001)
        # the handle stays open between detach and attach: nobody can swap the file in the gap, and the same object is attached again
        $out.Detach = & $time { & $unmount; [AVDTuneBenchNative.Vhd]::Detach($st.h) }
        $out.Attach = & $time { [AVDTuneBenchNative.Vhd]::Attach($st.h); & $mount }
        $reSeconds = & $time { foreach ($f in $files) { [void][IO.File]::ReadAllBytes($f) } }
        $out.Reattach = $out.Attach + $reSeconds
        & $unmount; [AVDTuneBenchNative.Vhd]::Detach($st.h); [AVDTuneBenchNative.Vhd]::Close($st.h); $st.h = [IntPtr]::Zero
        [pscustomobject]$out
    }
    finally {
        if ($st.h -ne [IntPtr]::Zero) { & $unmount; try { [AVDTuneBenchNative.Vhd]::Detach($st.h) } catch { }; [AVDTuneBenchNative.Vhd]::Close($st.h) }
        if (Test-Path -LiteralPath $mnt) { try { [IO.Directory]::Delete($mnt) } catch { } }
        if (Test-Path -LiteralPath $vhd) { try { [IO.File]::Delete($vhd) } catch { } }
    }
}

#endregion

#region diskspd download and checks

function Get-AVDTuneDiskspd {
    <#
        Path of a checked diskspd.exe. Downloaded at run time from Microsoft (design 6, decision D5), never shipped: the ZIP must have the pinned size and
        SHA256, the exe in it the pinned SHA256 and a valid Authenticode signature of Microsoft. Everything lands in <Root>\tools\diskspd (the state folder is
        Administrators and SYSTEM only). A mismatch stops the run; offline, the ZIP can be placed there by hand, same checks.
    #>
    param([Parameter(Mandatory)]$Bench, [Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)]$Config)
    $d = $Config.diskspd
    $dir = Join-Path $Root 'tools\diskspd'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $exe = Join-Path $dir 'diskspd.exe'
    $check = {
        param($Path)
        if ((& $Bench.HashFile $Path) -ne ([string]$d.exeSha256).ToLowerInvariant()) { throw "diskspd.exe does not have the expected SHA256 (pinned for version $($d.version))." }
        $sig = & $Bench.Signature $Path
        if ($sig.Status -ne 'Valid') { throw "diskspd.exe has no valid signature (status $($sig.Status))." }
        if ($sig.Subject -notlike "*$($d.signerSubjectContains)*") { throw "diskspd.exe is not signed by $($d.signerSubjectContains) (signer: $($sig.Subject))." }
    }
    if (Test-Path -LiteralPath $exe) {
        try { & $check $exe; return $exe } catch { Remove-Item -LiteralPath $exe -Force -ErrorAction SilentlyContinue }
    }
    $zip = Join-Path $dir 'DiskSpd.ZIP'
    if (-not (Test-Path -LiteralPath $zip)) {
        try { & $Bench.Download ([string]$d.url) $zip } catch { throw "diskspd could not be downloaded ($($_.Exception.Message)). Place DiskSpd.ZIP version $($d.version) from Microsoft in $dir by hand; the same checks apply." }
    }
    if ([long](& $Bench.FileLength $zip) -ne [long]$d.zipBytes -or (& $Bench.HashFile $zip) -ne ([string]$d.zipSha256).ToLowerInvariant()) {
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
        throw "DiskSpd.ZIP does not have the pinned size and SHA256 for version $($d.version); it was removed. The benchmark did not start."
    }
    $x = Join-Path $dir ('x-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    try {
        & $Bench.Expand $zip $x
        $src = Join-Path $x (([string]$d.exeInZip) -replace '/', '\')
        if (-not (Test-Path -LiteralPath $src)) { throw "$($d.exeInZip) is not in the ZIP." }
        & $check $src
        Copy-Item -LiteralPath $src -Destination $exe -Force
    }
    finally { try { Remove-AVDTuneFolderNoFollow $x } catch { } }   # through handles, links not followed (#48)
    $exe
}

#endregion

#region preconditions

function Test-AVDTuneBenchmarkPreconditions {
    <#
        What must be true before a run (design 3). Blocker: the run does not start. Warning: shown, the run may start. Each item: Id, Level, Ok, Text.
    #>
    param([Parameter(Mandatory)]$Bench, [Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)]$Config, [ValidateSet('Full', 'Quick')][string]$Mode = 'Full', [switch]$SkipIdleCheck)
    $p = $Config.run.preconditions
    $items = New-Object System.Collections.ArrayList
    $add = { param($Id, $Level, $Ok, $Text) [void]$items.Add([pscustomobject]@{ Id = $Id; Level = $Level; Ok = [bool]$Ok; Text = $Text }) }
    $engine = & $Bench.EngineInfo
    $engineWhy = $(if ($Bench.PSObject.Properties['EngineProblem']) { [string](& $Bench.PSObject.Properties['EngineProblem'].Value) } else { '' })
    & $add 'engine' 'Blocker' ($null -ne $engine) $(if ($engine) { 'The measure program is there and matches the release manifest.' } elseif ($engineWhy) { $engineWhy } else { 'AVDTune.Bench.exe was not found or is not checked (install a release of AVDTune that carries it).' })
    $elev = & $Bench.Elevated
    & $add 'elevated' 'Blocker' $elev $(if ($elev) { 'Running as administrator.' } else { 'The benchmark needs an administrator session.' })
    $sessions = & $Bench.OtherSessions
    if ($null -eq $sessions) { & $add 'sessions' 'Warning' $false 'The other sessions could not be listed. Make sure nobody else is signed in.' }
    else {
        $names = (@($sessions) | ForEach-Object { if ($_.User) { "$($_.User) (session $($_.Id))" } else { "session $($_.Id)" } }) -join ', '
        & $add 'sessions' 'Blocker' (@($sessions).Count -eq 0) $(if (@($sessions).Count -eq 0) { 'No other user is signed in.' } else { "Other sessions are open: $names. Sign them off first." })
    }
    $up = [double](& $Bench.UptimeMinutes)
    & $add 'uptime' 'Blocker' ($up -ge [double]$p.minUptimeMinutes) $(if ($up -ge [double]$p.minUptimeMinutes) { 'The computer has been up long enough.' } else { "The computer started $([math]::Round($up, 1)) minutes ago; wait until it is up $($p.minUptimeMinutes) minutes." })
    $free = [double](& $Bench.FreeGiB $Root)
    & $add 'space' 'Blocker' ($free -ge [double]$p.minFreeGiB) $(if ($free -ge [double]$p.minFreeGiB) { "$([math]::Round($free, 0)) GiB free." } else { "Only $([math]::Round($free, 1)) GiB free on the system drive; $($p.minFreeGiB) GiB are needed for the test file." })
    if (-not $SkipIdleCheck) {
        $secs = if ($Mode -eq 'Quick') { [int]$p.idleSecondsQuick } else { [int]$p.idleSecondsFull }
        $load = [double](& $Bench.CpuLoad $secs)
        & $add 'idle' 'Blocker' ($load -lt [double]$p.maxCpuPercent) $(if ($load -lt [double]$p.maxCpuPercent) { "The computer is idle (CPU $([math]::Round($load, 1)) percent over $secs s)." } else { "The computer is busy (CPU $([math]::Round($load, 1)) percent over $secs s); wait until it is below $($p.maxCpuPercent) percent." })
    }
    $reboot = [bool](& $Bench.PendingReboot)
    & $add 'reboot' 'Warning' (-not $reboot) $(if ($reboot) { 'A restart is pending. Restart before the benchmark for comparable values.' } else { 'No restart pending.' })
    $bat = [bool](& $Bench.OnBattery)
    & $add 'power' 'Warning' (-not $bat) $(if ($bat) { 'The computer runs on battery; values are not comparable.' } else { 'On mains power.' })
    $items.ToArray()
}

function Wait-AVDTuneUpdateIdle {
    # Waits (in 10 s steps, up to the configured minutes) while a Windows servicing installation runs; $false when it is still busy
    param([Parameter(Mandatory)]$Bench, [Parameter(Mandatory)]$Config, [scriptblock]$Progress)
    $steps = [int]([double]$Config.run.preconditions.updateWaitMinutes * 6)
    for ($i = 0; $i -le $steps; $i++) {
        if (-not (& $Bench.UpdateInstallerBusy)) { return $true }
        if ($i -lt $steps) { if ($Progress) { & $Progress 'Waiting for a Windows installation to end ...' $null }; & $Bench.Sleep 10000 }
    }
    $false
}

#endregion

#region quiet mode and restore journal

function Get-AVDTuneBenchRestoreAction {
    # What the SYSTEM task runs: Windows PowerShell by its full path (never a lookup through PATH as SYSTEM) with the restore script
    param([Parameter(Mandatory)][string]$ScriptPath, [string]$SystemFolder = [Environment]::GetFolderPath('System'))
    [pscustomobject]@{ Execute = (Join-Path $SystemFolder 'WindowsPowerShell\v1.0\powershell.exe'); Argument = ('-NoProfile -ExecutionPolicy Bypass -File "' + $ScriptPath + '"') }
}

function Get-AVDTuneBenchmarkJournalPath([string]$Root) { Join-Path $Root 'benchmark\restore.json' }
function Get-AVDTuneBenchmarkRestoreScriptPath([string]$Root) { Join-Path $Root 'benchmark\restore.ps1' }

function New-AVDTuneBenchmarkRestoreScript {
    # The script the restore task runs as SYSTEM. It only holds service names (checked against a strict pattern) and the paths of the journal and itself
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Services)
    foreach ($s in $Services) { if ($s -notmatch '^[A-Za-z0-9_.-]{1,64}$') { throw "Invalid service name '$s'." } }
    if ($Root -match "[`"'`$`r`n``%]") { throw 'The state folder path has characters that are not allowed in the restore script.' }
    $names = (@($Services) | ForEach-Object { "'$_'" }) -join ', '
    $journal = Get-AVDTuneBenchmarkJournalPath $Root
    @(
        '# AVDTune benchmark restore (made by AVDTune, runs once at start-up and removes itself). Services it starts again: ' + ($Services -join ', ')
        '$ErrorActionPreference = ''Continue'''
        "foreach (`$n in @($names)) {"
        '    $s = Get-Service -Name $n -ErrorAction SilentlyContinue'
        '    if ($s -and $s.StartType -ne ''Disabled'' -and $s.Status -ne ''Running'') { Start-Service -Name $n -ErrorAction SilentlyContinue }'
        '}'
        "Remove-Item -LiteralPath '$journal' -Force -ErrorAction SilentlyContinue"
        "Unregister-ScheduledTask -TaskName '$script:RestoreTaskName' -Confirm:`$false -ErrorAction SilentlyContinue"
    ) -join "`r`n"
}

function Start-AVDTuneBenchmarkQuiet {
    <#
        Quiet mode for a run (design 3): Windows Update (wuauserv, UsoSvc) and the indexer (WSearch) are stopped when they run, start type unchanged.
        Order: journal first (what will be stopped), then the restore task, then the stops. Defender is never touched.
    #>
    param([Parameter(Mandatory)]$Machine, [Parameter(Mandatory)]$Bench, [Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$RunId)
    Assert-AVDTuneNotSealed -Root $Root   # #50: no quiet mode (services stopped) on a finished version; Stop and the crash repair stay allowed
    $journal = Get-AVDTuneBenchmarkJournalPath $Root
    if (Test-Path -LiteralPath $journal) { throw 'A restore journal of an interrupted benchmark exists. Repair it first (Repair-AVDTuneBenchmarkCrash).' }
    $planned = @()
    foreach ($name in $script:QuietServices) {
        $s = & $Machine.ServiceGet $name
        if ($s -and [string]$s.Status -eq 'Running') { $planned += [pscustomobject]@{ Name = $name; StartType = [string]$s.StartType } }
    }
    $record = [ordered]@{ Schema = 1; RunId = $RunId; Started = (Get-Date).ToString('o'); Task = $script:RestoreTaskName; Services = $planned; Stopped = @() }
    Write-AVDTuneFile $journal ($record | ConvertTo-Json -Depth 5)
    $planNames = @($planned | ForEach-Object { $_.Name })
    Write-AVDTuneFile (Get-AVDTuneBenchmarkRestoreScriptPath $Root) (New-AVDTuneBenchmarkRestoreScript -Root $Root -Services $planNames)
    & $Bench.RestoreTaskRegister (Get-AVDTuneBenchmarkRestoreScriptPath $Root)
    $stopped = @(); $failed = @()
    foreach ($p in $planned) {
        try { & $Machine.ServiceStop $p.Name; $stopped += $p.Name } catch { $failed += "$($p.Name): $($_.Exception.Message)" }
    }
    $record.Stopped = $stopped
    Write-AVDTuneFile $journal ($record | ConvertTo-Json -Depth 5)
    [pscustomobject]@{ Planned = $planNames; Stopped = $stopped; Failed = $failed }
}

function Stop-AVDTuneBenchmarkQuiet {
    <#
        Puts back what the journal says (services that were running are started again, unless their start type is Disabled), removes the restore task, the
        restore script and the journal. When a service cannot be started the journal stays, so the next start (or the restore task) tries again.
    #>
    param([Parameter(Mandatory)]$Machine, [Parameter(Mandatory)]$Bench, [Parameter(Mandatory)][string]$Root)
    $journal = Get-AVDTuneBenchmarkJournalPath $Root
    $rec = Read-AVDTuneJson $journal
    $restored = @(); $failed = @()
    if ($rec) {
        foreach ($s in @($rec.Services | Where-Object { $_ })) {
            $now = & $Machine.ServiceGet $s.Name
            if (-not $now) { continue }
            if ([string]$now.Status -eq 'Running') { $restored += $s.Name; continue }
            if ([string]$now.StartType -eq 'Disabled') { continue }
            try { & $Machine.ServiceStart $s.Name; $restored += $s.Name } catch { $failed += "$($s.Name): $($_.Exception.Message)" }
        }
    }
    if ($failed.Count -eq 0) {
        try { & $Bench.RestoreTaskRemove } catch { }
        foreach ($f in $journal, (Get-AVDTuneBenchmarkRestoreScriptPath $Root)) { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force } }
    }
    [pscustomobject]@{ Restored = $restored; Failed = $failed; Clean = ($failed.Count -eq 0) }
}

function Get-AVDTuneBenchmarkCrash {
    # A journal that is still there at the start of AVDTune: a benchmark was interrupted (crash, power loss, closed in the middle)
    param([Parameter(Mandatory)][string]$Root)
    $rec = Read-AVDTuneJson (Get-AVDTuneBenchmarkJournalPath $Root)
    if (-not $rec) { return $null }
    [pscustomobject]@{ RunId = [string]$rec.RunId; Started = [string]$rec.Started; Services = @($rec.Services | Where-Object { $_ } | ForEach-Object { $_.Name }) }
}

function Repair-AVDTuneBenchmarkCrash {
    param([Parameter(Mandatory)]$Machine, [Parameter(Mandatory)]$Bench, [Parameter(Mandatory)][string]$Root, [string]$User)
    Assert-AVDTuneNoForeignChange -Root $Root   # a benchmark of another AVDTune process still runs: no crash (#49)
    $crash = Get-AVDTuneBenchmarkCrash -Root $Root
    if (-not $crash) { return [pscustomobject]@{ Repaired = $false; Message = 'Nothing to repair.' } }
    $r = Stop-AVDTuneBenchmarkQuiet -Machine $Machine -Bench $Bench -Root $Root
    $msg = if ($r.Clean) { "Restored after an interrupted benchmark: $((@($r.Restored) -join ', '))." } else { "Not everything could be restored: $($r.Failed -join '; ')" }
    $state = Get-AVDTuneState $Root
    if ($state.ImageVersion) { [void](Add-AVDTuneChangeLogEntry -Root $Root -Version ([string]$state.ImageVersion) -Category 'Benchmark' -Component 'Quiet mode' -ChangeType Note -Text $msg -User $User -Source Step) }
    [pscustomobject]@{ Repaired = $r.Clean; Message = $msg }
}

function Remove-AVDTuneDiskspdCache {
    # At Finish (plan 7a): the downloaded diskspd is not part of the image
    param([Parameter(Mandatory)][string]$Root)
    $dir = Join-Path $Root 'tools\diskspd'
    Remove-AVDTuneFolderNoFollow $dir   # through handles, links not followed (#48); nothing there: nothing to do
}

function Test-AVDTuneBenchmarkClean {
    # Leftovers of a benchmark (design 6): work folders, restore journal, restore task, restore script. Empty list = clean
    param([Parameter(Mandatory)]$Bench, [Parameter(Mandatory)][string]$Root)
    $left = @()
    $work = Join-Path $Root 'benchmark\work'
    if (Test-Path -LiteralPath (Join-Path $Root 'tools\diskspd')) { $left += 'diskspd cache (tools\diskspd, removed at Finish)' }
    if (Test-Path -LiteralPath $work) { foreach ($d in @(Get-ChildItem -LiteralPath $work -Force)) { $left += "work folder $($d.Name)" } }
    if (Test-Path -LiteralPath (Get-AVDTuneBenchmarkJournalPath $Root)) { $left += 'restore journal' }
    if (Test-Path -LiteralPath (Get-AVDTuneBenchmarkRestoreScriptPath $Root)) { $left += 'restore script' }
    if (& $Bench.RestoreTaskExists) { $left += "scheduled task $script:RestoreTaskName" }
    # round 2 artefacts: test folders on the share, attached containers (label AVDTuneBench) and mount points, Edge/Office leftovers in the work folder
    if ($Bench.PSObject.Properties['LeftoverScan']) { foreach ($l in @(& $Bench.LeftoverScan $Root)) { $left += $l } }
    $left
}

#endregion

#region measuring

function Invoke-AVDTuneBenchDisk {
    # OS disk measures: the five diskspd tests (fixed templates) and the small-file test of the measure program. Returns raw measures
    param([Parameter(Mandatory)]$Bench, [Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$WorkDir, [Parameter(Mandatory)][string]$DiskspdPath, [int]$Seconds, [double]$Scale, [scriptblock]$Progress)
    $d = $Config.diskspd
    $out = @()
    $file = Join-Path $WorkDir 'disk.dat'
    $workRoot = Join-Path $Root 'benchmark\work'
    if (-not $file.StartsWith($workRoot + '\', [StringComparison]::OrdinalIgnoreCase) -or $file -match '[^A-Za-z0-9 _.:~()\\-]') { throw 'The test file path is not an AVDTune work folder.' }
    foreach ($t in @($d.tests)) {
        if ($Progress) { & $Progress "OS disk: $($t.key)" $null }
        $cliArgs = @(([string]$t.args).Replace('{d}', [string]$Seconds).Split(' ', [StringSplitOptions]::RemoveEmptyEntries)) + @("-c$($d.fileSizeGiB)G", $file)
        try {
            $r = & $Bench.DiskspdRun $DiskspdPath $cliArgs
            if ($r.ExitCode -ne 0) { throw "diskspd exit code $($r.ExitCode)" }
            $parsed = ConvertFrom-AVDTuneDiskspdXml -Xml ([string]$r.Output)
            foreach ($m in @($t.measures)) {
                $prop = $parsed.PSObject.Properties[[string]$m.metric]
                $val = if ($prop) { $prop.Value } else { $null }
                if ($null -eq $val) { $out += [pscustomobject]@{ id = $m.id; unit = $m.unit; better = $m.better; value = $null; status = 'failed'; reason = "diskspd XML: no value for $($m.metric)" } }
                else { $out += [pscustomobject]@{ id = $m.id; unit = $m.unit; better = $m.better; value = [double]$val; status = 'ok'; reason = $null } }
            }
        }
        catch {
            foreach ($m in @($t.measures)) { $out += [pscustomobject]@{ id = $m.id; unit = $m.unit; better = $m.better; value = $null; status = 'failed'; reason = $_.Exception.Message } }
        }
    }
    if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
    if ($Progress) { & $Progress 'OS disk: small files' $null }
    try {
        $r = & $Bench.RunBench 'files' @('--quiet', '--dir', $WorkDir)
        foreach ($m in @($r.measures)) { $out += [pscustomobject]@{ id = $m.id; unit = $m.unit; better = $m.better; value = $m.value; status = $m.status; reason = (Get-AVDTuneProp $m 'reason') } }
    }
    catch { $out += [pscustomobject]@{ id = 'host.disk.smallfiles'; unit = 'files/s'; better = 'higher'; value = $null; status = 'failed'; reason = $_.Exception.Message } }
    $out
}

function Invoke-AVDTuneBenchNetwork {
    # Network measures (design 1.1): DNS, TCP connect p50/p95, jitter, download. Quick mode uses fewer repeats and a shorter download
    param([Parameter(Mandatory)]$Bench, [Parameter(Mandatory)]$Config, [ValidateSet('Full', 'Quick')][string]$Mode = 'Full', [scriptblock]$Progress)
    $n = $Config.network
    $quick = $Mode -eq 'Quick'
    $dnsReps = if ($quick) { [math]::Max(2, [int]($n.dnsRepeats / 3)) } else { [int]$n.dnsRepeats }
    $tcpReps = if ($quick) { [math]::Max(5, [int]($n.tcpRepeats / 2)) } else { [int]$n.tcpRepeats }
    $seconds = if ($quick) { 10 } else { [int]$n.download.seconds }
    $out = @()
    $mk = { param($id, $unit, $better, $value, $status, $reason) [pscustomobject]@{ id = $id; unit = $unit; better = $better; value = $value; status = $status; reason = $reason } }
    if ($Progress) { & $Progress 'Network: DNS' $null }
    $dns = @()
    foreach ($name in @($n.dnsNames)) { for ($i = 0; $i -lt $dnsReps; $i++) { $v = & $Bench.NetDns $name; if ($null -ne $v) { $dns += [double]$v } } }
    $dnsTotal = @($n.dnsNames).Count * $dnsReps
    if ($dns.Count -ge [math]::Ceiling($dnsTotal / 2)) { $out += & $mk 'host.net.dns' 'ms' 'lower' (Get-AVDTuneBenchMedian ([double[]]$dns)) 'ok' $null }
    else { $out += & $mk 'host.net.dns' 'ms' 'lower' $null 'failed' "only $($dns.Count) of $dnsTotal lookups worked (no network or DNS?)" }
    if ($Progress) { & $Progress 'Network: TCP connect' $null }
    $tcp = @(); $diffs = @(); $tcpTotal = 0
    foreach ($name in @($n.dnsNames)) {
        $last = $null
        for ($i = 0; $i -lt $tcpReps; $i++) {
            $tcpTotal++
            $v = & $Bench.NetTcp $name ([int]$n.tcpPort) ([int]$n.tcpTimeoutMs)
            if ($null -ne $v) { $tcp += [double]$v; if ($null -ne $last) { $diffs += [math]::Abs([double]$v - $last) }; $last = [double]$v }
            if ($i + 1 -lt $tcpReps) { & $Bench.Sleep ([int]$n.tcpIntervalMs) }
        }
    }
    if ($tcp.Count -ge [math]::Ceiling($tcpTotal / 2) -and $tcp.Count -ge 2) {
        $out += & $mk 'host.net.tcp.p50' 'ms' 'lower' (Get-AVDTuneBenchPercentile ([double[]]$tcp) 50) 'ok' $null
        $out += & $mk 'host.net.tcp.p95' 'ms' 'lower' (Get-AVDTuneBenchPercentile ([double[]]$tcp) 95) 'ok' $null
        if ($diffs.Count -gt 0) { $out += & $mk 'host.net.jitter' 'ms' 'lower' (($diffs | Measure-Object -Average).Average) 'ok' $null }
        else { $out += & $mk 'host.net.jitter' 'ms' 'lower' $null 'failed' 'not enough consecutive connects' }
    }
    else {
        $why = "only $($tcp.Count) of $tcpTotal connects worked (no network or port $($n.tcpPort) blocked?)"
        foreach ($id in 'host.net.tcp.p50', 'host.net.tcp.p95', 'host.net.jitter') { $out += & $mk $id 'ms' 'lower' $null 'failed' $why }
    }
    if ($Progress) { & $Progress 'Network: download' $null }
    try {
        $r = & $Bench.NetDownload ([string]$n.download.url) ([int]$n.download.streams) $seconds ([long]$n.download.bytes)
        if ($r.Bytes -gt 0 -and $r.Seconds -gt 0) { $out += & $mk 'host.net.download' 'Mbit/s' 'higher' ($r.Bytes * 8.0 / 1e6 / $r.Seconds) 'ok' $null }
        else { $out += & $mk 'host.net.download' 'Mbit/s' 'higher' $null 'failed' "no data received ($($r.Errors) stream error(s))" }
    }
    catch { $out += & $mk 'host.net.download' 'Mbit/s' 'higher' $null 'failed' $_.Exception.Message }
    $out
}

function Get-AVDTuneBenchShare {
    # The FSLogix share of the environment: the first UNC path of VHDLocations (HKLM FSLogix Profiles), or '' when there is none. Only a plain UNC path is accepted
    param([Parameter(Mandatory)]$Machine)
    $v = & $Machine.RegGet 'HKLM:\SOFTWARE\FSLogix\Profiles' 'VHDLocations'
    foreach ($item in @($v)) {
        foreach ($part in ([string]$item -split ';')) {
            $t = $part.Trim().TrimEnd([char]92)
            if ($t -match '(^|\\)\.+(\\|$)') { continue }   # no dot segments
            if ($t -match '^\\\\[A-Za-z0-9][A-Za-z0-9.-]{0,200}\\[A-Za-z0-9._$ -]{1,80}(\\[A-Za-z0-9._ -]{1,80}){0,4}$') { return $t.TrimEnd('\') }
        }
    }
    ''
}

function Get-AVDTuneBenchShareHost([string]$Unc) { if ($Unc -match '^\\\\([^\\]+)\\') { $Matches[1] } else { '' } }

function Invoke-AVDTuneBenchApps {
    # Application starts and Speedometer (design 1.1). Warm-up: no cold start, no Speedometer; quick: no cold start, one Speedometer iteration. The program paths are checked by the adapter
    param([Parameter(Mandatory)]$Bench, [Parameter(Mandatory)][string]$WorkDir, [ValidateSet('Full', 'Quick')][string]$Mode = 'Full', [switch]$WarmUp, [string]$SiteDir, [scriptblock]$Progress)
    if ($Progress) { & $Progress 'Applications: starts' $null }
    $cliArgs = @('--quiet', '--dir', $WorkDir)
    if ($WarmUp -or $Mode -eq 'Quick') { $cliArgs += '--no-cold' }
    if ($WarmUp) { $cliArgs += '--no-speedometer' }
    if ($Mode -eq 'Quick') { $cliArgs += @('--speed-iterations', '1') }
    if ($SiteDir -and (Test-Path -LiteralPath (Join-Path $SiteDir 'index.html'))) { $cliArgs += @('--site', $SiteDir) }
    ConvertFrom-AVDTuneBenchOutput (& $Bench.RunApps 'apps' $cliArgs)
}

function Invoke-AVDTuneBenchGpu {
    # GPU measures (design 1.3): only when DXGI lists a hardware adapter. Returns Present, Measures, Info (adapter, driver, memory)
    param([Parameter(Mandatory)]$Bench, [double]$Scale = 1.0, [scriptblock]$Progress)
    if ($Progress) { & $Progress 'GPU: looking for an adapter' $null }
    $info = & $Bench.RunBench 'gpuinfo' @('--quiet')
    $gi = Get-AVDTuneProp $info 'info'
    if (-not [bool](Get-AVDTuneProp $gi 'hardware')) { return [pscustomobject]@{ Present = $false; Measures = @(); Info = $gi } }
    if ($Progress) { & $Progress 'GPU: measuring' $null }
    $r = & $Bench.RunBench 'gpu' @('--quiet', '--scale', ([string]$Scale).Replace(',', '.'))
    [pscustomobject]@{ Present = $true; Measures = @(ConvertFrom-AVDTuneBenchOutput $r); Info = $gi }
}

function Invoke-AVDTuneBenchFslogix {
    <#
        FSLogix measures (design 1.2) in a new test folder AVDTune-Bench-<guid> on the share: diskspd (fixed templates, file in that folder), the share test of the measure program
        (open/close, round trip, metadata), and the profile container (VirtDisk): one cycle, then five at the same time. The folder is removed in a finally block.
    #>
    param([Parameter(Mandatory)]$Bench, [Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Share, [Parameter(Mandatory)][string]$WorkDir, [Parameter(Mandatory)][string]$DiskspdPath,
        [ValidateSet('Full', 'Quick')][string]$Mode = 'Full', [switch]$WarmUp, [scriptblock]$Progress)
    $f = $Config.fslogix
    $quick = $WarmUp -or $Mode -eq 'Quick'
    $seconds = if ($quick) { [int]$Config.diskspd.secondsShort } else { [int]$Config.diskspd.seconds }
    $scale = if ($WarmUp) { 0.4 } elseif ($Mode -eq 'Quick') { 0.5 } else { 1.0 }
    $out = @()
    $mk = { param($id, $unit, $better, $value, $status, $reason) [pscustomobject]@{ id = $id; unit = $unit; better = $better; value = $value; status = $status; reason = $reason } }
    $folder = & $Bench.ShareMakeFolder $Share
    try {
        $file = Join-Path $folder 'disk.dat'
        foreach ($t in @($f.tests)) {
            if ($Progress) { & $Progress "FSLogix: $($t.key)" $null }
            $cliArgs = @(([string]$t.args).Replace('{d}', [string]$seconds).Split(' ', [StringSplitOptions]::RemoveEmptyEntries)) + @("-c$($f.fileSizeGiB)G", $file)
            try {
                $r = & $Bench.DiskspdRun $DiskspdPath $cliArgs
                if ($r.ExitCode -ne 0) { throw "diskspd exit code $($r.ExitCode)" }
                $parsed = ConvertFrom-AVDTuneDiskspdXml -Xml ([string]$r.Output)
                foreach ($m in @($t.measures)) {
                    $prop = $parsed.PSObject.Properties[[string]$m.metric]
                    if ($prop -and $null -ne $prop.Value) { $out += & $mk $m.id $m.unit $m.better ([double]$prop.Value) 'ok' $null }
                    else { $out += & $mk $m.id $m.unit $m.better $null 'failed' "diskspd XML: no value for $($m.metric)" }
                }
            }
            catch { foreach ($m in @($t.measures)) { $out += & $mk $m.id $m.unit $m.better $null 'failed' $_.Exception.Message } }
        }
        if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
        if ($Progress) { & $Progress 'FSLogix: open/close, round trip, metadata' $null }
        try {
            $shareArgs = @('--quiet', '--dir', $folder, '--scale', ([string]$scale).Replace(',', '.'))
            $hostName = Get-AVDTuneBenchShareHost $Share
            if ($hostName) { $shareArgs += @('--host', $hostName) }
            $out += @(ConvertFrom-AVDTuneBenchOutput (& $Bench.RunBench 'share' $shareArgs))
        }
        catch { foreach ($id in 'fsl.openclose', 'fsl.rtt', 'fsl.meta.create', 'fsl.meta.stat', 'fsl.meta.delete') { $out += & $mk $id '' 'higher' $null 'failed' $_.Exception.Message } }
        if ($Progress) { & $Progress 'FSLogix: profile container' $null }
        $writeMB = if ($quick) { [int]$f.vhd.writeMBQuick } else { [int]$f.vhd.writeMB }
        try {
            $c = & $Bench.VhdCycle $folder $WorkDir 1 ([int]$f.vhd.sizeGiB) $writeMB
            $out += & $mk 'fsl.vhd.create' 's' 'lower' ([double]$c.Create) 'ok' $null
            $out += & $mk 'fsl.vhd.attach' 's' 'lower' ([double]$c.Attach) 'ok' $null
            $out += & $mk 'fsl.vhd.write' 'MiB/s' 'higher' ([double]$c.WriteMBps) 'ok' $null
            $out += & $mk 'fsl.vhd.detach' 's' 'lower' ([double]$c.Detach) 'ok' $null
            $out += & $mk 'fsl.vhd.reattach' 's' 'lower' ([double]$c.Reattach) 'ok' $null
        }
        catch { foreach ($id in 'fsl.vhd.create', 'fsl.vhd.attach', 'fsl.vhd.write', 'fsl.vhd.detach', 'fsl.vhd.reattach') { $out += & $mk $id 's' 'lower' $null 'failed' $_.Exception.Message } }
        try {
            $p = & $Bench.VhdParallel $folder $WorkDir ([int]$f.vhd.parallel) ([int]$f.vhd.sizeGiB) $writeMB
            $out += & $mk 'fsl.vhd.parallel5' 's' 'lower' ([double]$p.WallSeconds) 'ok' $null
        }
        catch { $out += & $mk 'fsl.vhd.parallel5' 's' 'lower' $null 'failed' $_.Exception.Message }
    }
    finally { try { & $Bench.ShareRemoveFolder $folder } catch { } }
    $out
}

function Invoke-AVDTuneBenchCapacity {
    # Capacity simulation (design 4): the measure program runs the probe and the load workers; returns the capacity block (levels, estimate) or throws
    param([Parameter(Mandatory)]$Bench, [Parameter(Mandatory)][string]$WorkDir, [scriptblock]$Progress)
    if ($Progress) { & $Progress 'Capacity simulation (about 30 minutes)' $null }
    $r = & $Bench.RunApps 'capacity' @('--quiet', '--dir', $WorkDir) @('powershell')
    $cap = Get-AVDTuneProp (Get-AVDTuneProp $r 'info') 'capacity'
    if (-not $cap) { throw 'The capacity simulation gave no result.' }
    $cap
}

function Compare-AVDTuneCapacity {
    # Estimated users now against the last run of the same VM size (a number above the threshold of the benchmark: delta in percent)
    param($Current, $Previous, [double]$ThresholdPercent = 10)
    if (-not $Current -or -not $Previous) { return $null }
    $c = Get-AVDTuneProp $Current 'estimatedUsers'; $p = Get-AVDTuneProp $Previous 'estimatedUsers'
    if ($null -eq $c -or $null -eq $p -or [double]$p -le 0) { return [pscustomobject]@{ Current = $c; Previous = $p; DeltaPercent = $null; Class = 'side-by-side' } }
    $d = [math]::Round(([double]$c / [double]$p - 1.0) * 100.0, 1)
    [pscustomobject]@{ Current = $c; Previous = $p; DeltaPercent = $d; Class = $(if ($d -gt $ThresholdPercent) { 'better' } elseif ($d -lt -$ThresholdPercent) { 'worse' } else { 'same' }) }
}

#region report per image version (design 5.2)

function Get-AVDTuneVersionSortKey([string]$Version) {
    # 2026.11.001 sorts before 2026.11.002 and 2026.12.001: the digit groups padded
    (@([regex]::Matches($Version, '\d+') | ForEach-Object { $_.Value.PadLeft(10, '0') }) -join '.') + '|' + $Version
}

function Get-AVDTuneBenchmarkVersionResults {
    # Per image version the newest full result; oldest version first. -Results: use these (already checked) results instead of reading the folder
    param([Parameter(Mandatory)][string]$Root, [object[]]$Results)
    $by = @{}
    $all = $(if ($PSBoundParameters.ContainsKey('Results')) { @($Results) } else { @(Get-AVDTuneBenchmarkResult -Root $Root) })
    foreach ($r in $all) {
        if ($r.mode -ne 'full') { continue }
        $v = [string](Get-AVDTuneProp (Get-AVDTuneProp $r 'system') 'imageVersion')
        if (-not $v) { continue }
        if (-not $by.ContainsKey($v) -or ([datetime]$r.started) -ge ([datetime]$by[$v].started)) { $by[$v] = $r }
    }
    @($by.Keys | Sort-Object { Get-AVDTuneVersionSortKey $_ } | ForEach-Object { $by[$_] })
}

function Get-AVDTunePreviousVersionResult {
    # The result of the closest earlier image version with the same benchmark major version, or $null
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$ImageVersion, [object[]]$Results)
    $all = $(if ($PSBoundParameters.ContainsKey('Results')) { @($Results) } else { @(Get-AVDTuneBenchmarkVersionResults -Root $Root) })
    $key = Get-AVDTuneVersionSortKey $ImageVersion
    $cur = @($all | Where-Object { $_.system.imageVersion -ceq $ImageVersion } | Select-Object -First 1)
    $before = @($all | Where-Object { [string]::CompareOrdinal((Get-AVDTuneVersionSortKey ([string]$_.system.imageVersion)), $key) -lt 0 } | Where-Object { -not $cur -or $cur.Count -eq 0 -or ([string]$_.benchmarkVersion -split '\.')[0] -eq ([string]$cur[0].benchmarkVersion -split '\.')[0] })
    if ($before.Count -gt 0) { $before[-1] } else { $null }
}

function Get-AVDTuneBenchDelta {
    # Percent change of a score (higher is better) and its class against the threshold; $null when a side is missing
    param($Current, $Previous, [double]$Threshold = 10)
    if ($null -eq $Current -or $null -eq $Previous -or [double]$Previous -le 0) { return $null }
    $d = [math]::Round(([double]$Current / [double]$Previous - 1.0) * 100.0, 1)
    [pscustomobject]@{ DeltaPercent = $d; Class = $(if ($d -gt $Threshold) { 'better' } elseif ($d -lt -$Threshold) { 'worse' } else { 'same' }) }
}

function ConvertTo-AVDTuneHtml([string]$Text) { [Net.WebUtility]::HtmlEncode($Text) }

function New-AVDTuneBenchmarkReport {
    <#
        One self-contained HTML page (no external resource, no script): the three scores with the change against the previous image version and the baseline, categories,
        every measure with its previous value, capacity, run details. Every value from a result file is HTML-encoded (a result file can come from outside). Scores against
        reference values that were not calibrated are labelled "nicht kalibriert".
    #>
    param([Parameter(Mandatory)]$Current, $Previous, $Baseline, [Parameter(Mandatory)]$Config)
    $e = { param($t) ConvertTo-AVDTuneHtml ([string]$t) }
    $thr = [double]$Config.run.deltaThresholdPercent
    $deltaCell = {
        param($d)
        if (-not $d) { return '<td class="mute">no value</td>' }
        $cls = switch ($d.Class) { 'better' { 'good' } 'worse' { 'bad' } default { 'mute' } }
        '<td class="' + $cls + '">' + ('{0:+0.0;-0.0;0.0} %' -f [double]$d.DeltaPercent) + '</td>'
    }
    $sys = $Current.system
    $ver = [string](Get-AVDTuneProp $sys 'imageVersion')
    $prevVer = if ($Previous) { [string](Get-AVDTuneProp (Get-AVDTuneProp $Previous 'system') 'imageVersion') } else { '' }
    $same = { param($a, $b) $a -and $b -and ([string]$a.benchmarkVersion -split '\.')[0] -eq ([string]$b.benchmarkVersion -split '\.')[0] -and $a.mode -eq $b.mode }
    $usePrev = & $same $Current $Previous
    $useBase = $Baseline -and $Baseline.runId -ne $Current.runId -and (& $same $Current $Baseline)
    $h = New-Object System.Text.StringBuilder
    [void]$h.AppendLine('<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta http-equiv="Content-Security-Policy" content="default-src ''none''; style-src ''unsafe-inline''">')
    [void]$h.AppendLine("<title>AVDTune benchmark $(& $e $ver)</title>")
    [void]$h.AppendLine('<style>:root{--bg:#fff;--fg:#1b1b1f;--mute:#6b6b76;--line:#d8d8e0;--good:#0f7b3f;--bad:#b3261e;--warn:#fff4d6}@media (prefers-color-scheme:dark){:root{--bg:#16161a;--fg:#ececf1;--mute:#a0a0ad;--line:#33333c;--good:#58c98b;--bad:#ff8a80;--warn:#3a3217}}body{background:var(--bg);color:var(--fg);font:15px/1.5 "Segoe UI",sans-serif;margin:0;padding:16px;max-width:1000px}h1{font-size:22px}h2{font-size:17px;margin-top:28px}table{border-collapse:collapse;width:100%}th,td{border-bottom:1px solid var(--line);padding:5px 8px;text-align:left}td.n,th.n{text-align:right}.big{font-size:34px;font-weight:600}.cards{display:flex;flex-wrap:wrap;gap:12px}.card{border:1px solid var(--line);border-radius:8px;padding:12px 16px;min-width:200px;flex:1}.mute{color:var(--mute)}.good{color:var(--good)}.bad{color:var(--bad)}.note{background:var(--warn);padding:8px 12px;border-radius:6px}</style></head><body>')
    [void]$h.AppendLine("<h1>AVDTune benchmark, image version $(& $e $(if ($ver) { $ver } else { 'unknown' }))</h1>")
    [void]$h.AppendLine("<p class=""mute"">$(& $e $Current.benchmarkVersion), $(& $e $Current.mode) run, $(& $e $Current.started), $(& $e $sys.vmSize), $(& $e $sys.cpuModel), $(& $e $sys.vCpu) vCPU, $(& $e $sys.ramGiB) GiB. 1000 = the reference host.</p>")
    $refInfo = Get-AVDTuneProp $Current 'referenceInfo'
    if ($Current.scores.host.provisional -or (Get-AVDTuneProp $Current.scores.host 'uncalibrated')) { [void]$h.AppendLine('<p class="note">Reference values: vorlaeufig, nicht gemessen, nicht kalibriert. The numbers show changes between runs of this version of the benchmark; they are not yet comparable with other systems.</p>') }
    if ($usePrev) { [void]$h.AppendLine("<p>Compared with the previous image version <b>$(& $e $prevVer)</b> (run $(& $e $Previous.started)).</p>") }
    elseif ($Previous) { [void]$h.AppendLine('<p class="mute">The previous image version was measured with another benchmark version or mode: no score comparison, the raw values are in the table.</p>') }
    else { [void]$h.AppendLine('<p class="mute">No earlier image version has a full benchmark: nothing to compare with.</p>') }
    [void]$h.AppendLine('<h2>Scores</h2><div class="cards">')
    foreach ($s in @(@('host', 'Host score'), @('fslogix', 'FSLogix score'), @('gpu', 'GPU score'))) {
        $sc = Get-AVDTuneProp $Current.scores $s[0]
        $val = Get-AVDTuneProp $sc 'value'
        $txt = if ($null -ne $val) { [string]$val } elseif ((Get-AVDTuneProp $sc 'reason')) { [string]$sc.reason } else { 'no score' }
        $line = ''
        $flags = @()
        if ($sc -and (Get-AVDTuneProp $sc 'partial')) { $flags += 'Teilscore ohne ' + (@($sc.missingCategories) -join '/') }
        if ($sc -and (Get-AVDTuneProp $sc 'uncalibrated')) { $flags += 'nicht kalibriert' }
        if ($sc -and (Get-AVDTuneProp $sc 'unstable')) { $flags += 'instabil' }
        $cells = ''
        foreach ($pair in @(@($Previous, $usePrev, 'previous version'), @($Baseline, $useBase, 'baseline'))) {
            if (-not $pair[1]) { continue }
            $ov = Get-AVDTuneProp (Get-AVDTuneProp $pair[0].scores $s[0]) 'value'
            $d = Get-AVDTuneBenchDelta $val $ov $thr
            if ($d) { $cls = switch ($d.Class) { 'better' { 'good' } 'worse' { 'bad' } default { 'mute' } }; $cells += "<div class=""$cls"">$('{0:+0.0;-0.0;0.0} %' -f [double]$d.DeltaPercent) vs $(& $e $pair[2])</div>" }
        }
        [void]$h.AppendLine("<div class=""card""><div class=""mute"">$(& $e $s[1])</div><div class=""big"">$(& $e $txt)</div>$cells<div class=""mute"">$(& $e ($flags -join ', '))</div></div>")
    }
    [void]$h.AppendLine('</div>')
    foreach ($set in @(@('host', 'Host score by category'), @('fslogix', 'FSLogix score by category'), @('gpu', 'GPU score by category'))) {
        $sc = Get-AVDTuneProp $Current.scores $set[0]
        $cats = Get-AVDTuneProp $sc 'categories'
        if (-not $cats -or @($cats.PSObject.Properties).Count -eq 0) { continue }
        $titles = Get-AVDTuneBenchCategorySet $Config $set[0]
        [void]$h.AppendLine("<h2>$(& $e $set[1])</h2><table><tr><th>Category</th><th class=""n"">Index</th><th class=""n"">Weight</th><th>vs previous version</th><th>vs baseline</th></tr>")
        foreach ($c in $cats.PSObject.Properties) {
            $title = [string](Get-AVDTuneProp (Get-AVDTuneProp $titles $c.Name) 'title'); if (-not $title) { $title = $c.Name }
            $cols = ''
            foreach ($pair in @(@($Previous, $usePrev), @($Baseline, $useBase))) {
                $d = $null
                if ($pair[1]) { $oc = Get-AVDTuneProp (Get-AVDTuneProp (Get-AVDTuneProp $pair[0].scores $set[0]) 'categories') $c.Name; if ($oc) { $d = Get-AVDTuneBenchDelta $c.Value.index $oc.index $thr } }
                $cols += & $deltaCell $d
            }
            [void]$h.AppendLine("<tr><td>$(& $e $title)</td><td class=""n"">$(& $e $c.Value.index)</td><td class=""n"">$(& $e $c.Value.weight)</td>$cols</tr>")
        }
        [void]$h.AppendLine('</table>')
    }
    [void]$h.AppendLine('<h2>Measures</h2><table><tr><th>Measure</th><th>Status</th><th class="n">Median</th><th>Unit</th><th class="n">CV %</th><th class="n">Reference</th><th class="n">Index</th><th class="n">Previous version</th><th>Change</th></tr>')
    foreach ($m in @($Current.measures)) {
        $pm = $null
        if ($usePrev) { $pm = @($Previous.measures | Where-Object { $_.id -eq $m.id -and $_.status -eq 'ok' } | Select-Object -First 1)[0] }
        $chg = $null
        if ($pm -and $m.status -eq 'ok' -and $null -ne (Get-AVDTuneProp $m 'median') -and [double]$m.median -gt 0 -and [double]$pm.median -gt 0) {
            $chg = if ($m.better -eq 'lower') { Get-AVDTuneBenchDelta $pm.median $m.median $thr } else { Get-AVDTuneBenchDelta $m.median $pm.median $thr }
        }
        $status = [string]$m.status; if ($m.status -ne 'ok' -and (Get-AVDTuneProp $m 'reason')) { $status += ': ' + [string]$m.reason }
        if ((Get-AVDTuneProp $m 'unstable')) { $status += ' (instabil)' }
        if ((Get-AVDTuneProp $m 'outlier')) { $status += ' (Ausreisser: weit ausserhalb des Referenzbereichs)' }
        if ($m.status -eq 'ok' -and (Get-AVDTuneProp $m 'calibrated') -eq $false) { $status += ' (nicht kalibriert)' }
        $med = if ($null -ne (Get-AVDTuneProp $m 'median')) { '{0:0.###}' -f [double]$m.median } else { '' }
        $pmed = if ($pm) { '{0:0.###}' -f [double]$pm.median } else { '' }
        [void]$h.AppendLine("<tr><td>$(& $e $m.id)</td><td>$(& $e $status)</td><td class=""n"">$(& $e $med)</td><td>$(& $e $m.unit)</td><td class=""n"">$(& $e (Get-AVDTuneProp $m 'cv'))</td><td class=""n"">$(& $e (Get-AVDTuneProp $m 'reference'))</td><td class=""n"">$(& $e (Get-AVDTuneProp $m 'index'))</td><td class=""n"">$(& $e $pmed)</td>$(& $deltaCell $chg)</tr>")
    }
    [void]$h.AppendLine('</table>')
    $cap = Get-AVDTuneProp $Current 'capacity'
    if ($cap) {
        [void]$h.AppendLine('<h2>Capacity simulation</h2>')
        $est = Get-AVDTuneProp $cap 'estimatedUsers'
        $line = if ($null -ne $est) { "geschaetzte Nutzer (eigene Methode, an VSImax angelehnt, kein Login VSI Ergebnis): $est" } else { "Threshold not reached; at least $(Get-AVDTuneProp $cap 'atLeastUsers') users (own method, not a Login VSI result)" }
        [void]$h.AppendLine("<p class=""big"">$(& $e $est)</p><p>$(& $e $line). Stopped: $(& $e (Get-AVDTuneProp $cap 'stopReason')).</p>")
        $cc = Get-AVDTuneProp $Current 'capacityCompare'
        if ($cc -and $null -ne (Get-AVDTuneProp $cc 'DeltaPercent')) { [void]$h.AppendLine("<p>Against the last run of the same VM size: $('{0:+0.0;-0.0;0.0} %' -f [double]$cc.DeltaPercent).</p>") }
        [void]$h.AppendLine('<table><tr><th class="n">Users</th><th class="n">Median ms</th><th class="n">p95 ms</th><th class="n">CPU %</th><th class="n">Free MB</th><th class="n">Disk queue</th></tr>')
        foreach ($l in @($cap.levels)) { [void]$h.AppendLine("<tr><td class=""n"">$(& $e $l.users)</td><td class=""n"">$(& $e $l.totalMedianMs)</td><td class=""n"">$(& $e $l.totalP95Ms)</td><td class=""n"">$(& $e (Get-AVDTuneProp $l 'cpuPercent'))</td><td class=""n"">$(& $e (Get-AVDTuneProp $l 'availableMemoryMB'))</td><td class=""n"">$(& $e (Get-AVDTuneProp $l 'diskQueue'))</td></tr>") }
        [void]$h.AppendLine('</table>')
    }
    $gpu = Get-AVDTuneProp $sys 'gpu'
    if ($gpu) { [void]$h.AppendLine("<h2>GPU</h2><p>$(& $e (Get-AVDTuneProp $gpu 'adapter')), driver $(& $e (Get-AVDTuneProp $gpu 'driver')), $(& $e (Get-AVDTuneProp $gpu 'vramMiB')) MiB.</p>") }
    [void]$h.AppendLine('<h2>Run details</h2>')
    $inf = Get-AVDTuneProp $Current 'info'
    $errs = @((Get-AVDTuneProp $inf 'errors')); $warns = @((Get-AVDTuneProp $inf 'warnings'))
    [void]$h.AppendLine("<p>Run $(& $e $Current.runId), kind $(& $e $Current.kind), $(& $e $Current.durationSec) s. Windows build $(& $e (Get-AVDTuneProp (Get-AVDTuneProp $sys 'windows') 'build')), Office $(& $e (Get-AVDTuneProp (Get-AVDTuneProp $sys 'office') 'build')). Warnings: $(& $e ($warns -join '; ')). Errors: $(& $e ($errs -join '; ')).</p>")
    [void]$h.AppendLine('</body></html>')
    $h.ToString()
}

function Save-AVDTuneBenchmarkReport {
    # The report of an image version (its newest full result) with the comparison to the previous version; written like every file of AVDTune (admin-only, atomic)
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$ImageVersion, [string]$DataPath = $script:DataDefault)
    if ($ImageVersion -notmatch '^[A-Za-z0-9._-]{1,40}$') { throw "The image version '$ImageVersion' cannot be used in a file name." }
    $config = Get-AVDTuneBenchmarkConfig -DataPath $DataPath
    $cur = @(Get-AVDTuneBenchmarkVersionResults -Root $Root | Where-Object { $_.system.imageVersion -ceq $ImageVersion })
    if ($cur.Count -eq 0) { throw "No full benchmark result for image version $ImageVersion." }
    $prev = Get-AVDTunePreviousVersionResult -Root $Root -ImageVersion $ImageVersion
    $base = Get-AVDTuneBenchmarkBaseline -Root $Root
    $cmp = $null
    $html = New-AVDTuneBenchmarkReport -Current $cur[0] -Previous $prev -Baseline $base -Config $config
    $path = Join-Path (Get-AVDTuneBenchmarkResultFolder $Root) "report-$ImageVersion.html"
    Write-AVDTuneFile $path $html
    $path
}

#endregion

function ConvertFrom-AVDTuneBenchOutput {
    # Raw measures of a measure program command (parsed JSON) as plain objects
    param($Result)
    @($Result.measures | ForEach-Object { [pscustomobject]@{ id = [string]$_.id; unit = [string]$_.unit; better = [string]$_.better; value = $_.value; status = [string]$_.status; reason = (Get-AVDTuneProp $_ 'reason') } })
}

function Invoke-AVDTuneBenchRun {
    # One run: disk, CPU, memory, display, network, each group on its own so a failing group does not stop the rest. Returns @{ Measures; Errors }
    param([Parameter(Mandatory)]$Bench, [Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$WorkDir, [Parameter(Mandatory)][string]$DiskspdPath,
        [ValidateSet('Full', 'Quick')][string]$Mode = 'Full', [switch]$WarmUp, [switch]$Sustained, [scriptblock]$Progress, [string]$Share, [string]$SiteDir)
    $scale = if ($WarmUp) { 0.4 } else { 1.0 }
    $diskSeconds = if ($WarmUp -or $Mode -eq 'Quick') { [int]$Config.diskspd.secondsShort } else { [int]$Config.diskspd.seconds }
    $all = @(); $errors = @()
    try { $all += @(Invoke-AVDTuneBenchDisk -Bench $Bench -Config $Config -Root $Root -WorkDir $WorkDir -DiskspdPath $DiskspdPath -Seconds $diskSeconds -Scale $scale -Progress $Progress) } catch { $errors += "disk: $($_.Exception.Message)" }
    $cpuArgs = @('--quiet', '--scale', ([string]$scale).Replace(',', '.'))
    if ($Sustained -and -not $WarmUp -and $Mode -eq 'Full') { $cpuArgs += '--sustained' }
    foreach ($cmd in 'cpu', 'mem', 'disp') {
        if ($Progress) { & $Progress "Measuring: $cmd" $null }
        try {
            $cliArgs = $cpuArgs
            if ($cmd -ne 'cpu') { $cliArgs = @('--quiet', '--scale', ([string]$scale).Replace(',', '.')) }
            $all += @(ConvertFrom-AVDTuneBenchOutput (& $Bench.RunBench $cmd $cliArgs))
        }
        catch { $errors += "${cmd}: $($_.Exception.Message)" }
    }
    try { $all += @(Invoke-AVDTuneBenchNetwork -Bench $Bench -Config $Config -Mode $(if ($WarmUp) { 'Quick' } else { $Mode }) -Progress $Progress) } catch { $errors += "network: $($_.Exception.Message)" }
    try { $all += @(Invoke-AVDTuneBenchApps -Bench $Bench -WorkDir $WorkDir -Mode $Mode -WarmUp:$WarmUp -SiteDir $SiteDir -Progress $Progress) } catch { $errors += "applications: $($_.Exception.Message)" }
    $gpuInfo = $null; $gpuPresent = $false
    try { $g = Invoke-AVDTuneBenchGpu -Bench $Bench -Scale $(if ($WarmUp -or $Mode -eq 'Quick') { 0.4 } else { 1.0 }) -Progress $Progress; $gpuInfo = $g.Info; $gpuPresent = $g.Present; $all += @($g.Measures) } catch { $errors += "gpu: $($_.Exception.Message)" }
    if ($Share) {
        try { $all += @(Invoke-AVDTuneBenchFslogix -Bench $Bench -Config $Config -Share $Share -WorkDir $WorkDir -DiskspdPath $DiskspdPath -Mode $Mode -WarmUp:$WarmUp -Progress $Progress) } catch { $errors += "fslogix: $($_.Exception.Message)" }
    }
    [pscustomobject]@{ Measures = @($all); Errors = @($errors); GpuInfo = $gpuInfo; GpuPresent = $gpuPresent }
}

#endregion

#region aggregation, result

function ConvertTo-AVDTuneBenchAggregate {
    # Per measure id over the runs: values, median, CV, instability, reference, index. Only runs where the measure was ok count
    param([Parameter(Mandatory)][object[]]$Runs, [Parameter(Mandatory)]$Reference, [Parameter(Mandatory)]$Config)
    $ids = [ordered]@{}
    foreach ($run in $Runs) { foreach ($m in @($run)) { if (-not $ids.Contains($m.id)) { $ids[$m.id] = $m } } }
    $threshold = [double]$Config.run.unstableCvPercent
    $out = @()
    foreach ($id in $ids.Keys) {
        $first = $ids[$id]
        $vals = @()
        $status = $null; $reason = $null
        foreach ($run in $Runs) {
            $m = @($run | Where-Object { $_.id -eq $id }) | Select-Object -First 1
            if (-not $m) { continue }
            if ($m.status -eq 'ok' -and $null -ne $m.value) { $vals += [double]$m.value } elseif (-not $status) { $status = [string]$m.status; $reason = $m.reason }
        }
        $ref = Get-AVDTuneProp $Reference.Measures $id
        $entry = [ordered]@{ id = $id; unit = [string]$first.unit; better = [string]$first.better; runs = @($vals); reason = $null }
        if ($vals.Count -gt 0) {
            $med = Get-AVDTuneBenchMedian ([double[]]$vals)
            $cv = [math]::Round((Get-AVDTuneBenchCv ([double[]]$vals)), 2)
            $entry.median = $med; $entry.cv = $cv; $entry.unstable = ($vals.Count -ge 2 -and $cv -gt $threshold)
            $entry.status = 'ok'
            $entry.calibrated = -not ($ref -and (Get-AVDTuneProp $ref 'calibrated') -eq $false)
            if ($ref -and $med -gt 0) { $entry.reference = [double]$ref.value; $entry.index = Get-AVDTuneBenchRound (Get-AVDTuneBenchIndex $med ([double]$ref.value) ([string]$first.better)) }
            else { $entry.reference = $null; $entry.index = $null }
            # plausibility band: a value more than 5 times above or below the reference is marked as an outlier (a measurement that did not run what it says; it still counts, but the report shows it)
            $entry.outlier = [bool]($ref -and $med -gt 0 -and [double]$ref.value -gt 0 -and ($med / [double]$ref.value -gt 5 -or $med / [double]$ref.value -lt 0.2))
        }
        else {
            $entry.median = $null; $entry.cv = $null; $entry.unstable = $false; $entry.reference = $null; $entry.index = $null; $entry.outlier = $false
            $entry.status = $(if ($status) { $status } else { 'failed' }); $entry.reason = $reason
        }
        $entry.disturbedBy = @()
        $out += [pscustomobject]$entry
    }
    ,@($out)
}

function Get-AVDTuneBenchmarkSystem {
    param([Parameter(Mandatory)]$Machine, [Parameter(Mandatory)]$Bench, [string]$Root)
    $facts = & $Bench.SystemFacts
    $imds = & $Machine.Imds
    $compute = Get-AVDTuneProp $imds 'compute'
    $win = Get-AVDTuneWindowsInfo $Machine
    $office = Get-AVDTuneOfficeInfo $Machine
    $storageType = ''
    $sp = Get-AVDTuneProp $compute 'storageProfile'
    $od = Get-AVDTuneProp $sp 'osDisk'
    $md = Get-AVDTuneProp $od 'managedDisk'
    $t = Get-AVDTuneProp $md 'storageAccountType'
    if ($t) { $storageType = [string]$t } elseif ($facts.MediaType) { $storageType = [string]$facts.MediaType }
    $state = Read-AVDTuneJson (Join-Path $Root 'state.json')
    [ordered]@{
        name = [string](& $Machine.ComputerName)
        imageVersion = $(if ($state -and (Get-AVDTuneProp $state 'ImageVersion')) { [string]$state.ImageVersion } else { '' })
        vmSize = $(if ($compute) { [string](Get-AVDTuneProp $compute 'vmSize') } else { 'unknown' })
        region = $(if ($compute) { [string](Get-AVDTuneProp $compute 'location') } else { 'unknown' })
        cpuModel = [string]$facts.CpuModel; vCpu = [int]$facts.VCpu; ramGiB = [double]$facts.RamGiB
        osDisk = [ordered]@{ type = $storageType; sizeGiB = $facts.OsDiskSizeGiB; controller = [string]$facts.Controller }
        windows = [ordered]@{ edition = [string]$win.Edition; build = $(if ($win.Build -match '^\d+$') { [int]$win.Build } else { 0 }); ubr = $(if ($win.Ubr -match '^\d+$') { [int]$win.Ubr } else { 0 }) }
        office = [ordered]@{ build = [string]$office.Build; channel = [string]$office.Channel }
        fslogix = [string](& $Machine.RegGet 'HKLM:\SOFTWARE\FSLogix\Apps' 'InstallVersion')
        gpu = $null
    }
}

function Get-AVDTuneBenchmarkIntegrityHash {
    # SHA256 over the compact JSON of the result without the integrity field. Shows accidental edits only; it is not a signature
    param([Parameter(Mandatory)]$Result)
    $copy = [ordered]@{}
    foreach ($p in $Result.PSObject.Properties) { if ($p.Name -ne 'integrity') { $copy[$p.Name] = $p.Value } }
    $json = [pscustomobject]$copy | ConvertTo-Json -Depth 12 -Compress
    $bytes = (New-Object Text.UTF8Encoding $false).GetBytes($json)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { -join ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) } finally { $sha.Dispose() }
}

function Test-AVDTuneBenchmarkResult {
    # Problems of a result (empty = fine): schema, required fields, no secret-like names or values, integrity hash
    param([Parameter(Mandatory)]$Result)
    $problems = @()
    foreach ($f in 'schemaVersion', 'benchmarkVersion', 'reference', 'runId', 'kind', 'mode', 'started', 'durationSec', 'system', 'scores', 'measures', 'tools', 'integrity') {
        if ($null -eq (Get-AVDTuneProp $Result $f)) { $problems += "missing field $f" }
    }
    $walk = $null
    $walk = {
        param($o, $path)
        if ($null -eq $o) { return }
        if ($o -is [ValueType]) { return }
        if ($o -is [string]) { if ($o -match '(?i)(password|passwd|pwd|secret|accountkey|sig)=') { $script:__p += "secret-like value at $path" }; return }
        if ($o -is [System.Collections.IDictionary]) {
            foreach ($k in @($o.Keys)) { if ([string]$k -match $script:SecretPattern) { $script:__p += "secret-like field name $path.$k" }; & $walk $o[$k] "$path.$k" }
            return
        }
        if ($o -is [System.Collections.IEnumerable] -and $o -isnot [string]) { $i = 0; foreach ($x in $o) { & $walk $x "$path[$i]"; $i++ }; return }
        if ($o -isnot [ValueType]) {
            foreach ($p in $o.PSObject.Properties) {
                if ($p.Name -match $script:SecretPattern) { $script:__p += "secret-like field name $path.$($p.Name)" }
                & $walk $p.Value "$path.$($p.Name)"
            }
        }
    }
    $script:__p = @()
    & $walk $Result '$'
    $problems += @($script:__p)
    $integrity = Get-AVDTuneProp $Result 'integrity'
    if ($integrity) {
        $want = [string](Get-AVDTuneProp $integrity 'sha256')
        if ($want -ne (Get-AVDTuneBenchmarkIntegrityHash $Result)) { $problems += 'the integrity hash does not match (the file was changed)' }
    }
    $problems
}

function Get-AVDTuneBenchmarkResultFolder([string]$Root) { Join-Path $Root 'runs\benchmark' }

function Get-AVDTuneBenchmarkResult {
    # Stored results, oldest first; -RunId one; -Last the newest
    param([Parameter(Mandatory)][string]$Root, [string]$RunId, [switch]$Last)
    $folder = Get-AVDTuneBenchmarkResultFolder $Root
    if (-not (Test-Path -LiteralPath $folder)) { return @() }
    $files = @(Get-ChildItem -LiteralPath $folder -Filter '*.json' -File | Sort-Object Name)
    if ($RunId) { $files = @($files | Where-Object { $_.BaseName -eq $RunId }) }
    $res = @($files | ForEach-Object { Read-AVDTuneJson $_.FullName })
    if ($Last -and $res.Count -gt 0) { return @($res[-1]) }
    $res
}

function Set-AVDTuneBenchmarkBaseline {
    # The user chooses which full run stays the baseline (plan 1c). Quick results cannot be a baseline
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$RunId)
    $r = @(Get-AVDTuneBenchmarkResult -Root $Root -RunId $RunId)
    if ($r.Count -eq 0) { throw "No benchmark result $RunId." }
    if ($r[0].mode -ne 'full') { throw 'A quick result cannot be the baseline.' }
    [void](Set-AVDTuneState -Root $Root -Values @{ BaselineBenchmark = $RunId })
}

function Get-AVDTuneBenchmarkBaseline {
    param([Parameter(Mandatory)][string]$Root)
    $state = Get-AVDTuneState $Root
    $id = Get-AVDTuneProp $state 'BaselineBenchmark'
    if (-not $id) { return $null }
    $r = @(Get-AVDTuneBenchmarkResult -Root $Root -RunId ([string]$id))
    if ($r.Count -gt 0) { $r[0] } else { $null }
}

#endregion

#region comparison

function Compare-AVDTuneBenchmark {
    <#
        Current against a baseline (design 2.3). Not comparable across benchmark major versions or between quick and full. When a measure is missing on one
        side, the categories and the score are recomputed for both on the common measures ("gemeinsame Messungen"); a category missing on one side is shown
        without a delta. Delta in percent, green above +10, red below -10.
    #>
    param([Parameter(Mandatory)]$Current, [Parameter(Mandatory)]$Baseline, [Parameter(Mandatory)]$Config)
    $threshold = [double]$Config.run.deltaThresholdPercent
    $major = { param($v) if ([string]$v -match '^B(\d+)\.') { [int]$Matches[1] } else { -1 } }
    $cmp = [ordered]@{ Comparable = $true; Reason = ''; CommonOnly = $false; Notes = @(); Host = $null; Categories = [ordered]@{} }
    if ((& $major $Current.benchmarkVersion) -ne (& $major $Baseline.benchmarkVersion)) {
        $cmp.Comparable = $false; $cmp.Reason = "Different benchmark versions ($($Baseline.benchmarkVersion) and $($Current.benchmarkVersion)): the scores are not compared; look at the raw values."
        return [pscustomobject]$cmp
    }
    if ($Current.mode -ne $Baseline.mode) {
        $cmp.Comparable = $false; $cmp.Reason = "A $($Current.mode) result is not compared with a $($Baseline.mode) result."
        return [pscustomobject]$cmp
    }
    $notes = @()
    $curRef = Get-AVDTuneProp $Current 'referenceInfo'; $baseRef = Get-AVDTuneProp $Baseline 'referenceInfo'
    if ((Get-AVDTuneProp $curRef 'provisional') -or (Get-AVDTuneProp $baseRef 'provisional')) { $notes += 'At least one result was scored against the provisional reference (placeholder values, not measured).' }
    $okIds = { param($r) @($r.measures | Where-Object { $_.status -eq 'ok' -and $null -ne (Get-AVDTuneProp $_ 'index') } | ForEach-Object { $_.id }) }
    $curIds = & $okIds $Current; $baseIds = & $okIds $Baseline
    $common = @($curIds | Where-Object { $_ -in $baseIds })
    if ($common.Count -ne $curIds.Count -or $common.Count -ne $baseIds.Count) { $cmp.CommonOnly = $true; $notes += 'Not every measure ran on both sides: the scores are calculated on the common measures.' }
    $catScore = {
        param($r)
        $subset = @($r.measures | Where-Object { $_.id -in $common } | ForEach-Object { [pscustomobject]@{ Id = $_.id; Status = 'ok'; Index = [double]$_.index } })
        Get-AVDTuneBenchmarkScores -Measures $subset -Config $Config
    }
    $cs = & $catScore $Current; $bs = & $catScore $Baseline
    # categories that one side did not run at all: the full measures of the other side, shown side by side
    $allScore = { param($r) Get-AVDTuneBenchmarkScores -Measures @($r.measures | Where-Object { $_.status -eq 'ok' -and $null -ne (Get-AVDTuneProp $_ 'index') } | ForEach-Object { [pscustomobject]@{ Id = $_.id; Status = 'ok'; Index = [double]$_.index } }) -Config $Config }
    $csAll = & $allScore $Current; $bsAll = & $allScore $Baseline
    $delta = {
        param($c, $b)
        $d = [math]::Round(([double]$c / [double]$b - 1.0) * 100.0, 1)
        [pscustomobject]@{ Current = $c; Baseline = $b; DeltaPercent = $d; Class = $(if ($d -gt $threshold) { 'better' } elseif ($d -lt -$threshold) { 'worse' } else { 'same' }) }
    }
    foreach ($k in $Config.categories.PSObject.Properties.Name) {
        $inC = $cs.Categories.Contains($k); $inB = $bs.Categories.Contains($k)
        $anyC = $csAll.Categories.Contains($k); $anyB = $bsAll.Categories.Contains($k)
        if ($inC -and $inB) { $cmp.Categories[$k] = & $delta $cs.Categories[$k].index $bs.Categories[$k].index }
        elseif ($anyC -or $anyB) { $cmp.Categories[$k] = [pscustomobject]@{ Current = $(if ($anyC) { $csAll.Categories[$k].index } else { $null }); Baseline = $(if ($anyB) { $bsAll.Categories[$k].index } else { $null }); DeltaPercent = $null; Class = 'side-by-side' }; $notes += "Category $k ran on one side only: shown side by side, no delta."; $cmp.CommonOnly = $true }
    }
    # the score of the categories both sides have
    $both = @($cmp.Categories.Keys | Where-Object { $cmp.Categories[$_].Class -ne 'side-by-side' })
    if ($both.Count -gt 0) {
        $w = [double[]]@($both | ForEach-Object { [double]$Config.categories.$_.weight })
        $cur = Get-AVDTuneBenchRound (Get-AVDTuneBenchWeightedGeometricMean ([double[]]@($both | ForEach-Object { [double]$cs.Categories[$_].index })) $w)
        $base = Get-AVDTuneBenchRound (Get-AVDTuneBenchWeightedGeometricMean ([double[]]@($both | ForEach-Object { [double]$bs.Categories[$_].index })) $w)
        $cmp.Host = & $delta $cur $base
        if ($both.Count -ne $cs.Categories.Count -or $both.Count -ne $bs.Categories.Count) { $cmp.CommonOnly = $true }
    }
    $cmp.Notes = @($notes | Select-Object -Unique)
    [pscustomobject]$cmp
}

#endregion

#region comparison per image version (#90) and comparison systems (plan 6b)

function ConvertTo-AVDTuneBenchNumber {
    # A score from a result file as [double], or $null: only JSON numbers count, finite and above 0 ("1200" as text, true, NaN or 0 are no score; a file can come from outside)
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal] -or $Value -is [single]) {
        $d = [double]$Value
        if ([double]::IsNaN($d) -or [double]::IsInfinity($d) -or $d -le 0) { return $null }
        return $d
    }
    $null
}

function ConvertTo-AVDTuneBenchText {
    # A text field of a result file for display and export: a string only, control characters removed, cut to $Max
    param($Value, [int]$Max = 100)
    if ($Value -isnot [string]) { return '' }
    $t = [regex]::Replace($Value, '[\x00-\x1F\x7F]', ' ', [Text.RegularExpressions.RegexOptions]::None, [timespan]::FromMilliseconds(200)).Trim()
    if ($t.Length -gt $Max) { $t = $t.Substring(0, $Max) }
    $t
}

function ConvertTo-AVDTuneBenchmarkRow {
    <# The typed row of one result (AVDTune.BenchmarkRow): texts are strings, scores [double] or $null, Started a UTC [datetime]. Only what the comparison and the export need. #>
    param([Parameter(Mandatory)]$Result)
    $sys = Get-AVDTuneProp $Result 'system'; $sc = Get-AVDTuneProp $Result 'scores'
    $started = [datetime]::MinValue
    [void][datetime]::TryParse([string](Get-AVDTuneProp $Result 'started'), [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]'AdjustToUniversal, AssumeUniversal', [ref]$started)
    $hostBlock = Get-AVDTuneProp $sc 'host'
    [pscustomobject]@{
        PSTypeName = 'AVDTune.BenchmarkRow'
        RunId = ConvertTo-AVDTuneBenchText (Get-AVDTuneProp $Result 'runId') 64
        ImageVersion = ConvertTo-AVDTuneBenchText (Get-AVDTuneProp $sys 'imageVersion') 40
        SystemName = ConvertTo-AVDTuneBenchText (Get-AVDTuneProp $sys 'name') 80
        Notes = ConvertTo-AVDTuneBenchText (Get-AVDTuneProp $sys 'notes') 500
        Kind = ConvertTo-AVDTuneBenchText (Get-AVDTuneProp $Result 'kind') 20
        Mode = ConvertTo-AVDTuneBenchText (Get-AVDTuneProp $Result 'mode') 10
        BenchmarkVersion = ConvertTo-AVDTuneBenchText (Get-AVDTuneProp $Result 'benchmarkVersion') 12
        VmSize = ConvertTo-AVDTuneBenchText (Get-AVDTuneProp $sys 'vmSize') 64
        Started = [datetime]$started
        HostScore = ConvertTo-AVDTuneBenchNumber (Get-AVDTuneProp $hostBlock 'value')
        HostPartial = ((Get-AVDTuneProp $hostBlock 'partial') -eq $true)
        FslogixScore = ConvertTo-AVDTuneBenchNumber (Get-AVDTuneProp (Get-AVDTuneProp $sc 'fslogix') 'value')
        GpuScore = ConvertTo-AVDTuneBenchNumber (Get-AVDTuneProp (Get-AVDTuneProp $sc 'gpu') 'value')
        CapacityUsers = ConvertTo-AVDTuneBenchNumber (Get-AVDTuneProp (Get-AVDTuneProp $Result 'capacity') 'estimatedUsers')
    }
}

function Get-AVDTuneBenchmarkSystemFolder([string]$Root) { Join-Path (Get-AVDTuneBenchmarkResultFolder $Root) 'systems' }

function Get-AVDTuneBenchmarkSystems {
    # The imported comparison systems (benchmark-only and stand-alone results, plan 6b), oldest first; a file that fails the result check is left out and named in Problems
    param([Parameter(Mandatory)][string]$Root)
    $folder = Get-AVDTuneBenchmarkSystemFolder $Root
    $ok = @(); $problems = @()
    if (Test-Path -LiteralPath $folder) {
        foreach ($f in @(Get-ChildItem -LiteralPath $folder -Filter '*.json' -File | Sort-Object Name)) {
            $r = $null
            try { $r = Read-AVDTuneJson $f.FullName } catch { $problems += "$($f.Name): not readable"; continue }
            $p = @(Test-AVDTuneBenchmarkResult -Result $r)
            if ($p.Count -gt 0) { $problems += "$($f.Name): $($p -join '; ')" } else { $ok += $r }
        }
    }
    [pscustomobject]@{ Results = @($ok); Problems = @($problems) }
}

function Get-AVDTuneBenchmarkVersionComparison {
    <#
        Comparison per image version (#90): per version the newest full result as a typed row (oldest version first), each with the change against the previous version
        (Get-AVDTunePreviousVersionResult: closest earlier version, same benchmark major version) and against the baseline. Host score through Compare-AVDTuneBenchmark
        (common measures, never across major versions or quick/full); FSLogix and GPU score only with the same major version and mode; capacity only on the same VM size.
        Light: 'red' when one of them got worse by more than the threshold, 'green' when something was compared and nothing got worse, 'grey' when nothing could be compared.
        Results that fail Test-AVDTuneBenchmarkResult (changed file, secret-like content, missing fields) are left out and named in Problems.
        Systems: the imported comparison systems, each with the change of the newest version against it.
    #>
    param([Parameter(Mandatory)][string]$Root, $Config)
    if (-not $Config) { $Config = Get-AVDTuneBenchmarkConfig }
    $thr = [double]$Config.run.deltaThresholdPercent
    $problems = @()
    $valid = @()
    foreach ($r in @(Get-AVDTuneBenchmarkResult -Root $Root)) {
        $p = @(Test-AVDTuneBenchmarkResult -Result $r)
        if ($p.Count -gt 0) { $problems += "$(ConvertTo-AVDTuneBenchText (Get-AVDTuneProp $r 'runId') 64): $($p -join '; ')" } else { $valid += $r }
    }
    $versions = @(Get-AVDTuneBenchmarkVersionResults -Root $Root -Results @($valid | Where-Object { $_.kind -notin 'benchmark-only', 'standalone' }))
    $base = Get-AVDTuneBenchmarkBaseline -Root $Root
    if ($base -and @($valid | Where-Object { $_.runId -ceq $base.runId }).Count -eq 0) { $base = $null }   # a baseline that failed the check is no baseline
    $major = { param($v) if ([string]$v -match '^B(\d+)\.') { [int]$Matches[1] } else { -1 } }
    $same = { param($a, $b) (& $major $a.benchmarkVersion) -eq (& $major $b.benchmarkVersion) -and (& $major $a.benchmarkVersion) -ge 0 -and [string]$a.mode -ceq [string]$b.mode }
    $against = {
        param($cur, $other)
        $out = [ordered]@{ Host = $null; Fslogix = $null; Gpu = $null; Capacity = $null; Note = '' }
        if (-not $other -or [string]$other.runId -ceq [string]$cur.runId) { return $null }
        $c = Compare-AVDTuneBenchmark -Current $cur -Baseline $other -Config $Config
        if (-not $c.Comparable) { $out.Note = [string]$c.Reason; return [pscustomobject]$out }
        if ($c.Host) { $out.Host = [pscustomobject]@{ DeltaPercent = [double]$c.Host.DeltaPercent; Class = [string]$c.Host.Class } }
        if ($c.CommonOnly) { $out.Note = 'gemeinsame Messungen' }
        $rc = ConvertTo-AVDTuneBenchmarkRow $cur; $ro = ConvertTo-AVDTuneBenchmarkRow $other
        if (& $same $cur $other) {
            $out.Fslogix = Get-AVDTuneBenchDelta -Current $rc.FslogixScore -Previous $ro.FslogixScore -Threshold $thr
            $out.Gpu = Get-AVDTuneBenchDelta -Current $rc.GpuScore -Previous $ro.GpuScore -Threshold $thr
        }
        if ($rc.VmSize -and $rc.VmSize -ceq $ro.VmSize) { $out.Capacity = Get-AVDTuneBenchDelta -Current $rc.CapacityUsers -Previous $ro.CapacityUsers -Threshold $thr }
        [pscustomobject]$out
    }
    $lightOf = {
        param([object[]]$Sets)
        $ds = @(foreach ($s in $Sets) { if ($s) { foreach ($k in 'Host', 'Fslogix', 'Gpu', 'Capacity') { if ($s.$k) { $s.$k } } } })
        if (@($ds | Where-Object { $_.Class -eq 'worse' }).Count -gt 0) { 'red' } elseif ($ds.Count -gt 0) { 'green' } else { 'grey' }
    }
    $rows = @()
    $newest = $null
    foreach ($v in $versions) {
        $row = ConvertTo-AVDTuneBenchmarkRow $v
        $prev = Get-AVDTunePreviousVersionResult -Root $Root -ImageVersion $row.ImageVersion -Results $versions
        $vsPrev = & $against $v $prev
        $vsBase = & $against $v $base
        $worse = @()
        foreach ($pair in @(@('previous', $vsPrev), @('baseline', $vsBase))) {
            if (-not $pair[1]) { continue }
            foreach ($k in 'Host', 'Fslogix', 'Gpu', 'Capacity') { $d = $pair[1].$k; if ($d -and $d.Class -eq 'worse') { $worse += ('{0} {1:0.0} % vs {2}' -f $k, [double]$d.DeltaPercent, $pair[0]) } }
        }
        $row | Add-Member -NotePropertyMembers ([ordered]@{
                PreviousImageVersion = $(if ($prev) { ConvertTo-AVDTuneBenchText $prev.system.imageVersion 40 } else { '' })
                IsBaseline = [bool]($base -and [string]$base.runId -ceq $row.RunId)
                VsPrevious = $vsPrev; VsBaseline = $vsBase
                Light = (& $lightOf @($vsPrev, $vsBase)); Worse = @($worse)
            })
        $rows += $row
        $newest = $v
    }
    $sys = Get-AVDTuneBenchmarkSystems -Root $Root
    $problems += @($sys.Problems)
    $systems = @()
    foreach ($s in $sys.Results) {
        $row = ConvertTo-AVDTuneBenchmarkRow $s
        $vs = $(if ($newest) { & $against $newest $s } else { $null })
        $row | Add-Member -NotePropertyMembers ([ordered]@{ NewestVsThis = $vs; Light = (& $lightOf @($vs)) })
        $systems += $row
    }
    [pscustomobject]@{ ThresholdPercent = $thr; BaselineRunId = $(if ($base) { [string]$base.runId } else { '' }); Rows = @($rows); Systems = @($systems); Problems = @($problems) }
}

function ConvertTo-AVDTuneCsvCell {
    # One CSV text cell: quoted, quotes doubled; a cell that a spreadsheet would read as a formula (= + - @, tab, CR at the start) gets a leading apostrophe
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { $Text = '' }
    if ($Text -match '^[=+\-@\t\r]') { $Text = "'" + $Text }
    '"' + $Text.Replace('"', '""') + '"'
}

function ConvertTo-AVDTuneBenchmarkComparisonText {
    <# The comparison as CSV (RFC 4180, comma, invariant numbers, one row per version and per comparison system) or JSON (schemaVersion 1). No secrets: only typed rows. #>
    param([Parameter(Mandatory)]$Comparison, [ValidateSet('Csv', 'Json')][string]$Format = 'Csv')
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $num = { param($v) if ($null -eq $v) { '' } else { ([double]$v).ToString('0.###', $inv) } }
    $pct = { param($set, $k) if ($set -and $set.$k -and $null -ne $set.$k.DeltaPercent) { ([double]$set.$k.DeltaPercent).ToString('0.0', $inv) } else { '' } }
    $flat = @()
    foreach ($r in @($Comparison.Rows) + @($Comparison.Systems)) {
        $isSys = $null -ne $r.PSObject.Properties['NewestVsThis']
        $o = [ordered]@{
            Row = $(if ($isSys) { 'system' } else { 'version' }); ImageVersion = $r.ImageVersion; System = $r.SystemName; Kind = $r.Kind; Mode = $r.Mode; BenchmarkVersion = $r.BenchmarkVersion
            RunId = $r.RunId; Started = $(if ($r.Started -gt [datetime]::MinValue) { $r.Started.ToString('yyyy-MM-ddTHH:mm:ssZ', $inv) } else { '' }); VmSize = $r.VmSize
            HostScore = & $num $r.HostScore; FSLogixScore = & $num $r.FslogixScore; GPUScore = & $num $r.GpuScore; CapacityUsers = & $num $r.CapacityUsers
            PreviousImageVersion = $(if ($isSys) { '' } else { $r.PreviousImageVersion }); Baseline = $(if ($isSys) { '' } elseif ($r.IsBaseline) { 'yes' } else { 'no' })
        }
        foreach ($k in 'Host', 'Fslogix', 'Gpu', 'Capacity') {
            $n = $k.Replace('Fslogix', 'FSLogix').Replace('Gpu', 'GPU')
            $o["${n}VsPreviousPct"] = $(if ($isSys) { '' } else { & $pct $r.VsPrevious $k })
            $o["${n}VsBaselinePct"] = $(if ($isSys) { '' } else { & $pct $r.VsBaseline $k })
        }
        $o['HostNewestVsSystemPct'] = $(if ($isSys) { & $pct $r.NewestVsThis 'Host' } else { '' })
        $o['Light'] = $r.Light
        $flat += [pscustomobject]$o
    }
    if ($Format -eq 'Json') {
        return ([ordered]@{ schemaVersion = 1; product = 'AVDTune'; exported = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', $inv); thresholdPercent = $Comparison.ThresholdPercent; baselineRunId = $Comparison.BaselineRunId; rows = @($flat) } | ConvertTo-Json -Depth 5)
    }
    $numeric = '^(HostScore|FSLogixScore|GPUScore|CapacityUsers|.*Pct)$'
    $cols = @('Row', 'ImageVersion', 'System', 'Kind', 'Mode', 'BenchmarkVersion', 'RunId', 'Started', 'VmSize', 'HostScore', 'FSLogixScore', 'GPUScore', 'CapacityUsers', 'PreviousImageVersion', 'Baseline',
        'HostVsPreviousPct', 'HostVsBaselinePct', 'FSLogixVsPreviousPct', 'FSLogixVsBaselinePct', 'GPUVsPreviousPct', 'GPUVsBaselinePct', 'CapacityVsPreviousPct', 'CapacityVsBaselinePct', 'HostNewestVsSystemPct', 'Light')
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append(($cols -join ',')).Append("`r`n")
    foreach ($o in $flat) {
        $cells = foreach ($c in $cols) { $v = [string]$o.$c; if ($c -match $numeric) { $v } else { ConvertTo-AVDTuneCsvCell $v } }
        [void]$sb.Append(($cells -join ',')).Append("`r`n")
    }
    $sb.ToString()
}

function Export-AVDTuneBenchmarkComparison {
    # Writes the comparison to a file the administrator chose (save dialog), like the change log export; CSV with BOM (spreadsheet programs), JSON without
    param([Parameter(Mandatory)]$Comparison, [Parameter(Mandatory)][string]$Path, [ValidateSet('Csv', 'Json')][string]$Format = 'Csv')
    $text = ConvertTo-AVDTuneBenchmarkComparisonText -Comparison $Comparison -Format $Format
    [IO.File]::WriteAllText($Path, $text, (New-Object Text.UTF8Encoding ($Format -eq 'Csv')))
    $Path
}

function Test-AVDTuneBenchmarkLabel {
    <# Name and notes of a system in benchmark-only mode (plan 6b): name 1-80 characters, notes up to 500, no control characters (notes may have line breaks) and nothing
       that looks like a secret (they go into the result file and its export). Returns the problems, empty when fine. #>
    param([AllowEmptyString()][string]$Name, [AllowEmptyString()][string]$Notes)
    $p = @()
    # length first: no pattern runs on long input
    if ($Name.Length -gt 80) { $p += 'name longer than 80 characters' }
    if ($Notes.Length -gt 500) { $p += 'notes longer than 500 characters' }
    if ($p.Count -gt 0) { return $p }
    if ([string]::IsNullOrWhiteSpace($Name)) { $p += 'name missing' }
    elseif ($Name -match '[\x00-\x1F\x7F]') { $p += 'name has control characters' }
    if ($Notes -and $Notes -match '[\x00-\x09\x0B\x0C\x0E-\x1F\x7F]') { $p += 'notes have control characters' }
    foreach ($t in @($Name, $Notes)) {
        if ($t -and ($t -match $script:SecretPattern -or $t -match '(?i)(password|passwd|pwd|secret|accountkey|sig)=')) { $p += 'name or notes look like a secret (password, key, token): leave them out'; break }
    }
    $p
}

function Import-AVDTuneBenchmarkSystem {
    <#
        Imports a result file of a benchmark-only or stand-alone run as comparison system (plan 6b). The file is untrusted data: at most 5 MB, no link, it must pass
        Test-AVDTuneBenchmarkResult (fields, no secret-like content, integrity hash), kind benchmark-only or standalone, a run id of [A-Za-z0-9-] and a host score that is a number.
        Stored as <results>\systems\<runId>.json (admin-only folder created in one step, file written like every state file); a run id that is there already is refused.
    #>
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Path)
    $fi = New-Object IO.FileInfo $Path
    if (-not $fi.Exists) { throw "The file $Path does not exist." }
    if (($fi.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'The file is a link: not imported.' }
    if ($fi.Length -gt 5MB) { throw 'The file is larger than 5 MB: not a benchmark result.' }
    $text = [IO.File]::ReadAllText($fi.FullName).TrimStart([char]0xFEFF)
    $obj = $null
    try { $obj = $text | ConvertFrom-Json } catch { throw 'The file is not a JSON benchmark result.' }
    if ($null -eq $obj -or $obj -isnot [pscustomobject]) { throw 'The file is not a JSON benchmark result.' }
    $p = @(Test-AVDTuneBenchmarkResult -Result $obj)
    if ($p.Count -gt 0) { throw "Not imported: $($p -join '; ')" }
    if ($obj.kind -isnot [string] -or $obj.kind -notin 'benchmark-only', 'standalone') { throw 'Only results of the benchmark-only mode or the stand-alone script can be a comparison system.' }
    if ($obj.runId -isnot [string] -or $obj.runId -notmatch '^[A-Za-z0-9-]{1,64}$') { throw 'The run id of the file is not valid.' }
    $hv = Get-AVDTuneProp (Get-AVDTuneProp $obj.scores 'host') 'value'
    if ($null -ne $hv -and $null -eq (ConvertTo-AVDTuneBenchNumber $hv)) { throw 'The host score of the file is not a number.' }
    $results = Get-AVDTuneBenchmarkResultFolder $Root
    if (-not (Test-Path -LiteralPath $results)) { New-AVDTuneOwnFolder -Path $results }
    $folder = Get-AVDTuneBenchmarkSystemFolder $Root
    New-AVDTuneOwnFolder -Path $folder   # creates it with its protected ACL, or checks the one that is there (throws when it is not ours)
    $dest = Join-Path $folder "$($obj.runId).json"
    if (Test-Path -LiteralPath $dest) { throw "The comparison system $($obj.runId) is imported already." }
    Write-AVDTuneFile $dest ($obj | ConvertTo-Json -Depth 12)
    ConvertTo-AVDTuneBenchmarkRow $obj
}

function Export-AVDTuneBenchmarkResultFile {
    # Copies a stored result (checked first) to a file the administrator chose: the result file of plan 6b for the import as comparison system elsewhere. Never a secret.
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$RunId, [Parameter(Mandatory)][string]$Path)
    if ($RunId -notmatch '^[A-Za-z0-9-]{1,64}$') { throw 'Invalid run id.' }
    $r = @(Get-AVDTuneBenchmarkResult -Root $Root -RunId $RunId)
    if ($r.Count -eq 0) { throw "No benchmark result $RunId." }
    $p = @(Test-AVDTuneBenchmarkResult -Result $r[0])
    if ($p.Count -gt 0) { throw "The result is not exported: $($p -join '; ')" }
    [IO.File]::WriteAllText($Path, ($r[0] | ConvertTo-Json -Depth 12), (New-Object Text.UTF8Encoding $false))
    $Path
}

#endregion

#region run

function New-AVDTuneBenchmarkRunId { (Get-Date).ToString('yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture) + '-' + [guid]::NewGuid().ToString('N').Substring(0, 4) }

function Invoke-AVDTuneBenchmark {
    <#
        A full benchmark: preconditions, quiet mode, diskspd check, warm-up run (discarded), 3 runs (quick: 1), median, score, result file, state, change log.
        Mode Quick is marked as quick and not used for the finish. Everything that was changed (services) is put back in a finally block; if the process dies, the
        restore task or the next start of AVDTune does it (Repair-AVDTuneBenchmarkCrash). Progress is called with a text and a percentage (or $null).
        No write gate: the benchmark changes nothing permanent. It does pause Windows Update and the indexer for the run; that is written to a journal first
        and put back in the finally block (and by the restore task or the next start after a crash).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Machine, [Parameter(Mandatory)]$Bench, [string]$Root = (Get-AVDTuneRoot),
        [ValidateSet('Full', 'Quick')][string]$Mode = 'Full', [ValidateSet('baseline', 'healthcheck', 'manual', 'benchmark-only')][string]$Kind = 'manual',
        [string]$User, [scriptblock]$Progress, [string]$DataPath = $script:DataDefault, [switch]$SkipIdleCheck,
        [string]$Share, [switch]$Capacity, [switch]$NoReport, [string]$SystemName, [string]$Notes
    )
    if ($Capacity -and $Mode -eq 'Quick') { throw 'The capacity simulation is not available in a quick run.' }
    # benchmark-only (plan 6b): the system is named by hand; the result belongs to no image version, sets no baseline and writes no change log or version report
    $only = $Kind -eq 'benchmark-only'
    if ($only) { $lp = @(Test-AVDTuneBenchmarkLabel -Name $SystemName -Notes $Notes); if ($lp.Count -gt 0) { throw "The benchmark did not start: $($lp -join '; ')." } }
    elseif ($SystemName -or $Notes) { throw 'A system name and notes are only for the benchmark-only mode.' }
    if (-not $PSBoundParameters.ContainsKey('Share')) { $Share = Get-AVDTuneBenchShare -Machine $Machine }
    $siteDir = Join-Path $DataPath 'speedometer-3.1'
    $config = Get-AVDTuneBenchmarkConfig -DataPath $DataPath
    $reference = Get-AVDTuneBenchmarkReference -DataPath $DataPath -Name ([string]$config.reference)
    $userProgress = $Progress
    $say = { param($t, $p) if ($userProgress) { & $userProgress $t $p } }.GetNewClosure()
    & $say 'Checking the preconditions ...' 2
    $pre = Test-AVDTuneBenchmarkPreconditions -Bench $Bench -Root $Root -Config $config -Mode $Mode -SkipIdleCheck:$SkipIdleCheck
    $blockers = @($pre | Where-Object { $_.Level -eq 'Blocker' -and -not $_.Ok })
    if ($blockers.Count -gt 0) { throw "The benchmark did not start: $(($blockers | ForEach-Object { $_.Text }) -join ' ')" }
    $warnings = @($pre | Where-Object { $_.Level -eq 'Warning' -and -not $_.Ok } | ForEach-Object { $_.Text })
    if (-not (Wait-AVDTuneUpdateIdle -Bench $Bench -Config $config -Progress $say)) { throw 'The benchmark did not start: a Windows installation is still running.' }
    $lock = & $Bench.Lock
    if (-not $lock) { throw 'The benchmark did not start: another benchmark is running.' }
    $runId = New-AVDTuneBenchmarkRunId
    $work = Join-Path $Root "benchmark\work\$runId"
    $started = Get-Date
    $quiet = $null
    $errors = @()
    $result = $null
    try {
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        & $say 'Checking diskspd ...' 5
        $diskspd = Get-AVDTuneDiskspd -Bench $Bench -Root $Root -Config $config
        & $say 'Quiet mode: pausing Windows Update and the indexer ...' 8
        $quiet = Start-AVDTuneBenchmarkQuiet -Machine $Machine -Bench $Bench -Root $Root -RunId $runId
        $runs = if ($Mode -eq 'Quick') { 1 } else { [int]$config.run.runs }
        $total = $runs + 1
        $done = 0
        & $say 'Warm-up run (not counted) ...' 10
        $warm = Invoke-AVDTuneBenchRun -Bench $Bench -Config $config -Root $Root -WorkDir $work -DiskspdPath $diskspd -Mode $Mode -WarmUp -Share $Share -SiteDir $siteDir -Progress ({ param($t, $p) & $say "Warm-up: $t" $null }.GetNewClosure())
        $errors += @($warm.Errors | ForEach-Object { "warm-up $_" })
        $results = @()
        $gpuInfo = $null
        for ($r = 1; $r -le $runs; $r++) {
            $pct = [int](12 + 80 * ($r - 1) / $runs)
            & $say "Run $r of $runs ..." $pct
            $run = Invoke-AVDTuneBenchRun -Bench $Bench -Config $config -Root $Root -WorkDir $work -DiskspdPath $diskspd -Mode $Mode -Sustained:($r -eq 1) -Share $Share -SiteDir $siteDir -Progress ({ param($t, $p) & $say "Run ${r} of ${runs}: $t" $pct }.GetNewClosure())
            $results += , @($run.Measures)
            if ($run.GpuPresent) { $gpuInfo = $run.GpuInfo }
            $errors += @($run.Errors | ForEach-Object { "run $r $_" })
        }
        $capacityBlock = $null
        if ($Capacity) {
            try { $capacityBlock = Invoke-AVDTuneBenchCapacity -Bench $Bench -WorkDir $work -Progress ({ param($t, $p) & $say $t 93 }.GetNewClosure()) }
            catch { $errors += "capacity: $($_.Exception.Message)" }
        }
        & $say 'Calculating the score ...' 94
        $measures = ConvertTo-AVDTuneBenchAggregate -Runs $results -Reference $reference -Config $config
        $forScore = @($measures | ForEach-Object { [pscustomobject]@{ Id = $_.id; Status = $_.status; Index = (Get-AVDTuneProp $_ 'index'); Unstable = $_.unstable; Calibrated = (Get-AVDTuneProp $_ 'calibrated') } })
        $scores = Get-AVDTuneBenchmarkScores -Measures $forScore -Config $config
        $toBlock = {
            param($sc)
            $cats = [ordered]@{}
            foreach ($k in $sc.Categories.Keys) { $c = $sc.Categories[$k]; $cats[$k] = [ordered]@{ index = $c.index; weight = $c.weight; measures = $c.measures; unstable = $c.unstable; uncalibrated = $c.uncalibrated } }
            [ordered]@{ value = $sc.Host; unstable = $sc.Unstable; partial = $sc.Partial; missingCategories = @($sc.Missing); categories = $cats; provisional = $reference.Provisional; uncalibrated = $sc.Uncalibrated }
        }.GetNewClosure()
        $categories = [ordered]@{}
        foreach ($k in $scores.Categories.Keys) { $c = $scores.Categories[$k]; $categories[$k] = [ordered]@{ index = $c.index; weight = $c.weight; measures = $c.measures; unstable = $c.unstable; uncalibrated = $c.uncalibrated } }
        $fslScore = [ordered]@{ value = $null; status = 'skipped'; reason = 'no FSLogix share found (VHDLocations)' }
        if ($Share) {
            $fs = Get-AVDTuneBenchmarkScores -Measures $forScore -Config $config -Set fslogix
            $fslScore = $(if ($null -ne $fs.Host) { & $toBlock $fs } else { [ordered]@{ value = $null; status = 'failed'; reason = 'no FSLogix measure worked' } })
        }
        $gpuScore = [ordered]@{ value = $null; status = 'unsupported'; reason = 'nicht vorhanden' }
        if ($gpuInfo) {
            $gs = Get-AVDTuneBenchmarkScores -Measures $forScore -Config $config -Set gpu
            $gpuScore = $(if ($null -ne $gs.Host) { & $toBlock $gs } else { [ordered]@{ value = $null; status = 'failed'; reason = 'no GPU measure worked' } })
        }
        $engine = & $Bench.EngineInfo
        $result = [ordered]@{
            schemaVersion = 1
            benchmarkVersion = [string]$config.benchmarkVersion
            reference = [string]$reference.Name
            referenceInfo = [ordered]@{ name = [string]$reference.Name; provisional = $reference.Provisional; status = $reference.Status }
            runId = $runId
            kind = $Kind
            mode = $Mode.ToLowerInvariant()
            started = $started.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
            durationSec = [int]((Get-Date) - $started).TotalSeconds
            system = Get-AVDTuneBenchmarkSystem -Machine $Machine -Bench $Bench -Root $Root
            share = [ordered]@{ used = [bool]$Share; auth = $(if ($Share) { 'kerberos' } else { '' }) }
            scores = [ordered]@{
                host = [ordered]@{ value = $scores.Host; unstable = $scores.Unstable; partial = $scores.Partial; missingCategories = @($scores.Missing); categories = $categories; provisional = $reference.Provisional; uncalibrated = $scores.Uncalibrated }
                fslogix = $fslScore
                gpu = $gpuScore
            }
            measures = @($measures)
            info = [ordered]@{ warnings = @($warnings); errors = @($errors); quiet = [ordered]@{ stopped = @($quiet.Stopped); failed = @($quiet.Failed) }; user = $User }
            tools = [ordered]@{ engine = $(if ($engine) { [ordered]@{ version = [string]$engine.Version; sha256 = [string]$engine.Sha256 } } else { $null }); diskspd = [ordered]@{ version = [string]$config.diskspd.version; sha256 = [string]$config.diskspd.exeSha256 } }
            capacity = $capacityBlock
        }
        if ($only) { $result.system.name = $SystemName.Trim(); $result.system.imageVersion = ''; $result.system.notes = $(if ($Notes) { $Notes.Trim() } else { '' }) }
        if ($gpuInfo -and $gpuInfo.hardware) { $result.system.gpu = [ordered]@{ adapter = [string]$gpuInfo.adapter; driver = [string]$gpuInfo.driver; vramMiB = $gpuInfo.vramMiB } }
        if ($capacityBlock) {
            $prevCap = @(Get-AVDTuneBenchmarkResult -Root $Root | Where-Object { (Get-AVDTuneProp $_ 'capacity') -and $_.system.vmSize -ceq $result.system.vmSize } | Select-Object -Last 1)
            if ($prevCap.Count -gt 0) { $result.capacityCompare = Compare-AVDTuneCapacity -Current $capacityBlock -Previous $prevCap[0].capacity -ThresholdPercent ([double]$config.run.deltaThresholdPercent) }
        }
        $result.integrity = [ordered]@{ sha256 = '' }
    }
    finally {
        if ($quiet) {
            try { $back = Stop-AVDTuneBenchmarkQuiet -Machine $Machine -Bench $Bench -Root $Root; if ($result -and @($back.Failed).Count -gt 0) { $result.info.warnings = @($result.info.warnings) + "Quiet mode could not be fully restored: $($back.Failed -join '; ')" } } catch { $errors += "restore: $($_.Exception.Message)"; if ($result) { $result.info.errors = @($result.info.errors) + "restore: $($_.Exception.Message)" } }
        }
        if (Test-Path -LiteralPath $work) { try { Remove-AVDTuneFolderNoFollow $work } catch { $errors += "work folder: $($_.Exception.Message)" } }
        & $Bench.Unlock $lock
    }
    # store (append only), state, change log
    & $say 'Storing the result ...' 97
    $folder = Get-AVDTuneBenchmarkResultFolder $Root
    if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
    $path = Join-Path $folder "$runId.json"
    if (Test-Path -LiteralPath $path) { throw "Result $runId already exists." }
    # the hash is taken over the parsed form, which is what a later reader sees (a fixpoint of write and read)
    $obj = ([pscustomobject]$result | ConvertTo-Json -Depth 12) | ConvertFrom-Json
    $obj.integrity.sha256 = Get-AVDTuneBenchmarkIntegrityHash $obj
    # Own results are checked before they are written (no secret-like names or values, all fields). NOTE: a JSON file that comes from outside (a stand-alone or
    # benchmark-only result imported later as "Vergleichssystem") is NOT trusted by its integrity hash: it must pass this same check on import and its values are untrusted data.
    $problems = @(Test-AVDTuneBenchmarkResult -Result $obj)
    if ($problems.Count -gt 0) { throw "The result was not stored: $($problems -join '; ')" }
    Write-AVDTuneFile $path ($obj | ConvertTo-Json -Depth 12)
    $label = Get-AVDTuneBenchmarkSummaryText $obj
    $state = Get-AVDTuneState $Root
    $values = @{ LastBenchmark = $label; LastBenchmarkRunId = $runId }
    if ($Kind -eq 'baseline' -and $Mode -eq 'Full' -and -not (Get-AVDTuneProp $state 'BaselineBenchmark')) { $values.BaselineBenchmark = $runId }
    [void](Set-AVDTuneState -Root $Root -Values $values)
    $logged = $false
    $reportPath = $null
    if ($only) {
        & $say 'Done.' 100
        return [pscustomobject]@{ RunId = $runId; Path = $path; Result = $obj; Summary = $label; ChangeLogged = $false; ReportPath = $null; Errors = @($errors); Warnings = @($warnings) }
    }
    if ($state.ImageVersion -and -not $NoReport -and $Mode -eq 'Full') {
        try { $reportPath = Save-AVDTuneBenchmarkReport -Root $Root -ImageVersion ([string]$state.ImageVersion) -DataPath $DataPath } catch { $warnings += "The report was not written: $($_.Exception.Message)" }
    }
    if ($state.ImageVersion) {
        [void](Add-AVDTuneChangeLogEntry -Root $Root -Version ([string]$state.ImageVersion) -Category 'Benchmark' -Component 'Host' -ChangeType Note -Text $label -User $User -RunId $runId -Source Step)
        $logged = $true
    }
    & $say 'Done.' 100
    [pscustomobject]@{ RunId = $runId; Path = $path; Result = $obj; Summary = $label; ChangeLogged = $logged; ReportPath = $reportPath; Errors = @($errors); Warnings = @($warnings) }
}

function Get-AVDTuneBenchmarkSummaryText {
    # One line for the overview, the change log and the protocol
    param([Parameter(Mandatory)]$Result)
    $h = $Result.scores.host
    $cats = @($h.categories.PSObject.Properties | ForEach-Object { "$($_.Name) $($_.Value.index)" }) -join ', '
    $flags = @($Result.mode)
    if ($h.provisional) { $flags += 'vorlaeufige Referenz' }
    if (Get-AVDTuneProp $h 'uncalibrated') { $flags += 'nicht kalibriert' }
    if ($h.partial) { $flags += 'Teilscore ohne ' + (@($h.missingCategories) -join '/') }
    if ($h.unstable) { $flags += 'instabil' }
    $val = if ($null -ne $h.value) { [string]$h.value } else { 'no score' }
    $extra = ''
    $fsl = Get-AVDTuneProp $Result.scores 'fslogix'; $gpu = Get-AVDTuneProp $Result.scores 'gpu'
    if ($null -ne (Get-AVDTuneProp $fsl 'value')) { $extra += "; FSLogix $($fsl.value)" }
    if ($null -ne (Get-AVDTuneProp $gpu 'value')) { $extra += "; GPU $($gpu.value)" }
    $cap = Get-AVDTuneProp $Result 'capacity'
    if ($cap -and $null -ne (Get-AVDTuneProp $cap 'estimatedUsers')) { $extra += "; capacity about $($cap.estimatedUsers) users" }
    "Benchmark $($Result.benchmarkVersion): Host $val ($(($flags) -join ', ')); $cats$extra"
}

#endregion

Export-ModuleMember -Function Get-AVDTuneBenchShare, Get-AVDTuneBenchShareHost, Invoke-AVDTuneBenchApps, Invoke-AVDTuneBenchGpu, Invoke-AVDTuneBenchFslogix, Invoke-AVDTuneBenchCapacity, Compare-AVDTuneCapacity, Get-AVDTuneVersionSortKey, Get-AVDTuneBenchmarkVersionResults, Get-AVDTunePreviousVersionResult, Get-AVDTuneBenchDelta, New-AVDTuneBenchmarkReport, Save-AVDTuneBenchmarkReport, Get-AVDTuneAppProgramPath, Invoke-AVDTuneVhdCycle, Get-AVDTuneBenchCategorySet, Get-AVDTuneBenchRound, Get-AVDTuneBenchmarkConfig, Initialize-AVDTuneBenchTemp, Get-AVDTuneBenchmarkReference, Get-AVDTuneBenchCategoryKey, Get-AVDTuneBenchMedian, Get-AVDTuneBenchCv, Get-AVDTuneBenchIndex,
    Get-AVDTuneBenchGeometricMean, Get-AVDTuneBenchWeightedGeometricMean, Get-AVDTuneBenchPercentile, Get-AVDTuneBenchmarkScores, ConvertFrom-AVDTuneDiskspdXml, New-AVDTuneBenchAdapter,
    Get-AVDTuneDiskspd, Test-AVDTuneBenchmarkPreconditions, Wait-AVDTuneUpdateIdle, Get-AVDTuneBenchmarkJournalPath, Get-AVDTuneBenchmarkRestoreScriptPath, New-AVDTuneBenchmarkRestoreScript,
    Start-AVDTuneBenchmarkQuiet, Stop-AVDTuneBenchmarkQuiet, Get-AVDTuneBenchmarkCrash, Repair-AVDTuneBenchmarkCrash, Test-AVDTuneBenchmarkClean, Get-AVDTuneBenchRestoreAction, Remove-AVDTuneDiskspdCache, Invoke-AVDTuneBenchDisk, Invoke-AVDTuneBenchNetwork,
    Invoke-AVDTuneBenchRun, ConvertTo-AVDTuneBenchAggregate, Get-AVDTuneBenchmarkSystem, Get-AVDTuneBenchmarkIntegrityHash, Test-AVDTuneBenchmarkResult, Get-AVDTuneBenchmarkResultFolder,
    Get-AVDTuneBenchmarkResult, Set-AVDTuneBenchmarkBaseline, Get-AVDTuneBenchmarkBaseline, Compare-AVDTuneBenchmark, Invoke-AVDTuneBenchmark, Get-AVDTuneBenchmarkSummaryText, New-AVDTuneBenchmarkRunId,
    ConvertTo-AVDTuneBenchNumber, ConvertTo-AVDTuneBenchText, ConvertTo-AVDTuneBenchmarkRow, Get-AVDTuneBenchmarkSystemFolder, Get-AVDTuneBenchmarkSystems, Get-AVDTuneBenchmarkVersionComparison,
    ConvertTo-AVDTuneCsvCell, ConvertTo-AVDTuneBenchmarkComparisonText, Export-AVDTuneBenchmarkComparison, Test-AVDTuneBenchmarkLabel, Import-AVDTuneBenchmarkSystem, Export-AVDTuneBenchmarkResultFile
