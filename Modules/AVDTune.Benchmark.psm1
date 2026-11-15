<#
    AVDTune benchmark orchestration (docs\benchmark-design.md, plan section 6). No UI: the GUI, Start-AVDTune.ps1 -Benchmark and the stand-alone
    script use this code.

    This round (issue #14, part 1): host categories CPU, memory, OS disk (diskspd), remote display and network; warm-up run, 3 runs, median, CV;
    index and score against a reference file; result file without secrets; storing in the state; change log entry; quiet mode with restore journal
    and crash repair; comparison with the baseline. NOT yet: applications and Speedometer, FSLogix score, GPU score, capacity simulation, HTML/PDF
    report, SharePoint, benchmark-only mode, stand-alone script, disturber watch, automatic repeat of unstable measures.

    All access to the machine goes through adapters, so the checks run against fakes (Tests\Fakes\FakeMachine.ps1, Tests\Fakes\FakeBench.ps1):
      Machine  = New-AVDTuneMachine (registry, services; Modules\AVDTune.psm1)
      Bench    = New-AVDTuneBenchAdapter (this file): measure program, diskspd, downloads, network, sessions, scheduled task, lock.
    The reference file Bench\data\references-B1.0.json holds PLACEHOLDER values until the reference VMs are measured: every result says so
    ("vorlaeufig, nicht gemessen").
#>

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'AVDTune.psm1')
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

function Get-AVDTuneBenchCategoryKey {
    # Category of a measure id by its prefix, or $null
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Id)
    foreach ($c in $Config.categories.PSObject.Properties) {
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
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Measures, [Parameter(Mandatory)]$Config, [double]$UnstableCv = 10)
    $cats = [ordered]@{}
    $missing = @()
    $unstableAny = $false
    foreach ($c in $Config.categories.PSObject.Properties) {
        $mine = @($Measures | Where-Object { (Get-AVDTuneBenchCategoryKey $Config $_.Id) -eq $c.Name -and $_.Status -eq 'ok' -and $null -ne (Get-AVDTuneProp $_ 'Index') })
        if ($mine.Count -eq 0) { $missing += $c.Name; continue }
        $idx = Get-AVDTuneBenchGeometricMean ([double[]]@($mine | ForEach-Object { [double]$_.Index }))
        $unstable = @($mine | Where-Object { Get-AVDTuneProp $_ 'Unstable' }).Count -gt 0
        if ($unstable) { $unstableAny = $true }
        $cats[$c.Name] = [ordered]@{ index = (Get-AVDTuneBenchRound $idx); weight = [double]$c.Value.weight; measures = $mine.Count; unstable = $unstable; title = [string]$c.Value.title }
    }
    $hostScore = $null
    if ($cats.Count -gt 0) {
        $values = [double[]]@($cats.Values | ForEach-Object { [double]$_.index })
        $weights = [double[]]@($cats.Values | ForEach-Object { [double]$_.weight })
        $hostScore = Get-AVDTuneBenchRound (Get-AVDTuneBenchWeightedGeometricMean $values $weights)
    }
    [pscustomobject]@{ Host = $hostScore; Categories = $cats; Missing = @($missing); Partial = ($missing.Count -gt 0); Unstable = $unstableAny }
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

$script:Limits = @{ BenchMs = 600000; DiskspdMs = 900000 }      # timeouts; the checks lower them in module scope
$script:Hooks = @{ AclReader = $null }   # test hook: a fake ACL reader for the TEMP folder check

function Initialize-AVDTuneBenchJob {
    if ('AVDTuneBenchNative.Job' -as [type]) { return }
    Add-Type -TypeDefinition @"
using System; using System.ComponentModel; using System.Runtime.InteropServices;
namespace AVDTuneBenchNative {
  public static class Job {
    [StructLayout(LayoutKind.Sequential)] struct BasicLimit { public long PerProcessUserTimeLimit, PerJobUserTimeLimit; public uint LimitFlags; public UIntPtr MinWs, MaxWs; public uint ActiveProcessLimit; public UIntPtr Affinity; public uint PriorityClass, SchedulingClass; }
    [StructLayout(LayoutKind.Sequential)] struct IoCounters { public ulong a, b, c, d, e, f; }
    [StructLayout(LayoutKind.Sequential)] struct ExtendedLimit { public BasicLimit Basic; public IoCounters Io; public UIntPtr ProcessMemory, JobMemory, PeakProcess, PeakJob; }
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr CreateJobObject(IntPtr attributes, string name);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetInformationJobObject(IntPtr job, int infoClass, ref ExtendedLimit info, int length);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool TerminateJobObject(IntPtr job, uint exitCode);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool CloseHandle(IntPtr handle);
    // a job whose processes are all ended when the last handle is closed (also when AVDTune itself dies)
    public static IntPtr Create() {
      IntPtr j = CreateJobObject(IntPtr.Zero, null); if (j == IntPtr.Zero) throw new Win32Exception();
      ExtendedLimit l = new ExtendedLimit(); l.Basic.LimitFlags = 0x2000;   // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
      if (!SetInformationJobObject(j, 9, ref l, Marshal.SizeOf(typeof(ExtendedLimit)))) { int e = Marshal.GetLastWin32Error(); CloseHandle(j); throw new Win32Exception(e); }
      return j;
    }
    public static void Assign(IntPtr job, IntPtr process) { if (!AssignProcessToJobObject(job, process)) throw new Win32Exception(); }
    public static void Terminate(IntPtr job) { TerminateJobObject(job, 0xFFFFFFFF); }
    public static void Close(IntPtr job) { CloseHandle(job); }
  }
}
"@
}

function Initialize-AVDTuneBenchTemp {
    <#
        TEMP of the measure program: <state>\temp\bench, administrators only. An existing folder is trusted only when it is no link (the folder and the ones above it) and has no
        owner or rule of someone else (Get-AVDTuneStateSecurityProblems); otherwise it is set aside (renamed to bench.untrusted-<stamp>, never repaired or deleted in place) and a new
        one is created in one step with the protected ACL.
    #>
    param([Parameter(Mandatory)][string]$StateRoot)
    $parent = Join-Path $StateRoot 'temp'
    $dir = Join-Path $parent 'bench'
    Assert-AVDTuneNoLinkInPath -Base $StateRoot -Rel 'temp'
    if (-not (Test-Path -LiteralPath $parent)) { [void][IO.Directory]::CreateDirectory($parent) }
    $info = New-Object IO.DirectoryInfo $dir
    $file = New-Object IO.FileInfo $dir
    if ($info.Exists -or $file.Exists) {
        $bad = $file.Exists -or (($info.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
        if (-not $bad) {
            $p = @{ Root = $dir }
            if ($script:Hooks.AclReader) { $p.ReadAcl = $script:Hooks.AclReader; $p.AdminSid = '' }
            $bad = @(Get-AVDTuneStateSecurityProblems @p).Count -gt 0
        }
        if (-not $bad) { return $dir }
        $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture)
        $aside = Join-Path $parent "bench.untrusted-$stamp"
        for ($n = 2; (Test-Path -LiteralPath $aside); $n++) { $aside = Join-Path $parent "bench.untrusted-$stamp-$n" }
        if ($file.Exists) { [IO.File]::Move($dir, $aside) } else { [IO.Directory]::Move($dir, $aside) }   # a rename: nothing inside is opened or followed
    }
    $elevated = Test-AVDTuneElevated
    $security = New-AVDTuneStateSecurity -WithOwner:$elevated
    # AVDTune runs the benchmark elevated only; a non-elevated process (the checks) must not lock itself out of its own folder
    if (-not $elevated) { $security.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule([Security.Principal.WindowsIdentity]::GetCurrent().User, 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow'))) }
    (New-Object IO.DirectoryInfo $dir).Create($security)
    $dir
}

function Get-AVDTuneChildEnvironment {
    # Allowlist of the environment of a child: only what Windows programs need to find the system, plus fixed PATH, TEMP and TMP. Everything else (DOTNET_*, COR*, __COMPAT_LAYER,
    # variables from the profile of the user) is not passed on.
    param([Parameter(Mandatory)][string]$TempDir)
    $names = @('SystemRoot', 'windir', 'ProgramData', 'ProgramFiles', 'ProgramFiles(x86)', 'CommonProgramFiles', 'NUMBER_OF_PROCESSORS', 'OS', 'COMSPEC')
    $env = [ordered]@{}
    foreach ($k in @([Environment]::GetEnvironmentVariables().Keys | ForEach-Object { [string]$_ })) {
        if ($k -in $names -or $k -like 'PROCESSOR_*') { $env[$k] = [Environment]::GetEnvironmentVariable($k) }
    }
    $env['PATH'] = [Environment]::GetFolderPath('System'); $env['TEMP'] = $TempDir; $env['TMP'] = $TempDir
    $env
}

function Invoke-AVDTuneChildProcess {
    <#
        Starts a program and waits for it: no window, output read asynchronously (stdout and stderr, so neither pipe can fill up and block it), a timeout, and the process in a
        job object (kill on close): on a timeout, or when this function ends, the whole tree is ended. -CleanEnvironment passes only the allowlist of Get-AVDTuneChildEnvironment
        and TEMP/TMP in -TempDir (Initialize-AVDTuneBenchTemp). If the process cannot be put into the job it is ended. Returns ExitCode, Output, Error, TimedOut.
    #>
    param([Parameter(Mandatory)][string]$FileName, [string]$Arguments = '', [int]$TimeoutMs = 600000, [switch]$CleanEnvironment, [string]$TempDir)
    Initialize-AVDTuneBenchJob
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FileName; $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
    if ($CleanEnvironment) {
        if (-not $TempDir) { throw 'A clean environment needs a TEMP folder.' }
        $psi.EnvironmentVariables.Clear()
        $clean = Get-AVDTuneChildEnvironment -TempDir $TempDir
        foreach ($k in $clean.Keys) { $psi.EnvironmentVariables[$k] = [string]$clean[$k] }
    }
    $job = [AVDTuneBenchNative.Job]::Create()
    $p = $null
    try {
        $p = [System.Diagnostics.Process]::Start($psi)
        try { [AVDTuneBenchNative.Job]::Assign($job, $p.Handle) } catch { try { $p.Kill() } catch { }; throw }
        $outTask = $p.StandardOutput.ReadToEndAsync(); $errTask = $p.StandardError.ReadToEndAsync()
        $timedOut = -not $p.WaitForExit($TimeoutMs)
        if ($timedOut) { [AVDTuneBenchNative.Job]::Terminate($job); [void]$p.WaitForExit(10000) }
        else { [void]$p.WaitForExit() }
        [void]$outTask.Wait(10000); [void]$errTask.Wait(10000)
        [pscustomobject]@{ ExitCode = $(if ($timedOut) { -1 } else { $p.ExitCode }); Output = $(if ($outTask.IsCompleted) { $outTask.Result } else { '' }); Error = $(if ($errTask.IsCompleted) { $errTask.Result } else { '' }); TimedOut = $timedOut }
    }
    finally {
        [AVDTuneBenchNative.Job]::Terminate($job); [AVDTuneBenchNative.Job]::Close($job)   # nothing of the tree outlives the call
        if ($p) { $p.Dispose() }
    }
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
        together with AVDTUNE_FAKE (the test mode).
    #>
    param([string]$AppRoot, [string]$InstallRoot, [string]$StateRoot, $Manifest)
    if (-not $AppRoot) { $AppRoot = Split-Path $PSScriptRoot -Parent }
    if (-not $InstallRoot) { $InstallRoot = Get-AVDTuneInstallRoot }
    if (-not $StateRoot) { $StateRoot = Get-AVDTuneRoot }
    if (($PSBoundParameters.ContainsKey('AppRoot') -or $PSBoundParameters.ContainsKey('Manifest') -or $PSBoundParameters.ContainsKey('StateRoot') -or $PSBoundParameters.ContainsKey('InstallRoot')) -and -not $env:AVDTUNE_FAKE) { throw 'The measure program is always the one of the release this copy runs from (the parameters are for the checks).' }
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
    $b.RunBench = {
        # Runs the measure program and parses its JSON. Arguments are fixed words and numbers made by this module, never user text
        param([string]$Command, [string[]]$Arguments)
        if ($Command -notmatch '^[a-z]+$') { throw "Invalid command '$Command'." }
        # checked against the release manifest right before this start, and held open (no write, delete or rename) until the process has started
        $verified = Open-AVDTuneVerifiedBenchExe -AppRoot $AppRoot -InstallRoot $InstallRoot -StateRoot $StateRoot -Manifest $Manifest
        $cmdLine = (@($Command) + @($Arguments) | ForEach-Object { ConvertTo-AVDTuneArgument ([string]$_) }) -join ' '
        # environment allowlist, TEMP in an administrators-only folder, timeout with the whole tree ended, kill on close
        # the verified file stays held (no write, delete, rename) until the process has ended
        try { $r = Invoke-AVDTuneChildProcess -FileName $verified.Path -Arguments $cmdLine -TimeoutMs $limits.BenchMs -CleanEnvironment -TempDir (Initialize-AVDTuneBenchTemp -StateRoot $StateRoot) }
        finally { $verified.Stream.Dispose() }
        if ($r.TimedOut) { throw "AVDTune.Bench $Command did not finish in time and was ended with everything it had started." }
        if ($r.ExitCode -ne 0) { throw "AVDTune.Bench $Command failed (exit $($r.ExitCode)): $($r.Error.Trim())" }
        $r.Output | ConvertFrom-Json
    }.GetNewClosure()
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
        $pool = [runspacefactory]::CreateRunspacePool(1, $Streams); $pool.Open()
        $jobs = @()
        $t0 = [DateTime]::UtcNow
        for ($i = 0; $i -lt $Streams; $i++) {
            $ps = [powershell]::Create(); $ps.RunspacePool = $pool
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
    finally { if (Test-Path -LiteralPath $x) { Remove-Item -LiteralPath $x -Recurse -Force -ErrorAction SilentlyContinue } }
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
    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
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

function ConvertFrom-AVDTuneBenchOutput {
    # Raw measures of a measure program command (parsed JSON) as plain objects
    param($Result)
    @($Result.measures | ForEach-Object { [pscustomobject]@{ id = [string]$_.id; unit = [string]$_.unit; better = [string]$_.better; value = $_.value; status = [string]$_.status; reason = (Get-AVDTuneProp $_ 'reason') } })
}

function Invoke-AVDTuneBenchRun {
    # One run: disk, CPU, memory, display, network, each group on its own so a failing group does not stop the rest. Returns @{ Measures; Errors }
    param([Parameter(Mandatory)]$Bench, [Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$WorkDir, [Parameter(Mandatory)][string]$DiskspdPath,
        [ValidateSet('Full', 'Quick')][string]$Mode = 'Full', [switch]$WarmUp, [switch]$Sustained, [scriptblock]$Progress)
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
    [pscustomobject]@{ Measures = @($all); Errors = @($errors) }
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
            if ($ref -and $med -gt 0) { $entry.reference = [double]$ref.value; $entry.index = Get-AVDTuneBenchRound (Get-AVDTuneBenchIndex $med ([double]$ref.value) ([string]$first.better)) }
            else { $entry.reference = $null; $entry.index = $null }
        }
        else {
            $entry.median = $null; $entry.cv = $null; $entry.unstable = $false; $entry.reference = $null; $entry.index = $null
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
        [ValidateSet('Full', 'Quick')][string]$Mode = 'Full', [ValidateSet('baseline', 'healthcheck', 'manual')][string]$Kind = 'manual',
        [string]$User, [scriptblock]$Progress, [string]$DataPath = $script:DataDefault, [switch]$SkipIdleCheck
    )
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
        $warm = Invoke-AVDTuneBenchRun -Bench $Bench -Config $config -Root $Root -WorkDir $work -DiskspdPath $diskspd -Mode $Mode -WarmUp -Progress ({ param($t, $p) & $say "Warm-up: $t" $null }.GetNewClosure())
        $errors += @($warm.Errors | ForEach-Object { "warm-up $_" })
        $results = @()
        for ($r = 1; $r -le $runs; $r++) {
            $pct = [int](12 + 80 * ($r - 1) / $runs)
            & $say "Run $r of $runs ..." $pct
            $run = Invoke-AVDTuneBenchRun -Bench $Bench -Config $config -Root $Root -WorkDir $work -DiskspdPath $diskspd -Mode $Mode -Sustained:($r -eq 1) -Progress ({ param($t, $p) & $say "Run ${r} of ${runs}: $t" $pct }.GetNewClosure())
            $results += , @($run.Measures)
            $errors += @($run.Errors | ForEach-Object { "run $r $_" })
        }
        & $say 'Calculating the score ...' 94
        $measures = ConvertTo-AVDTuneBenchAggregate -Runs $results -Reference $reference -Config $config
        $scores = Get-AVDTuneBenchmarkScores -Measures @($measures | ForEach-Object { [pscustomobject]@{ Id = $_.id; Status = $_.status; Index = (Get-AVDTuneProp $_ 'index'); Unstable = $_.unstable } }) -Config $config
        $categories = [ordered]@{}
        foreach ($k in $scores.Categories.Keys) { $c = $scores.Categories[$k]; $categories[$k] = [ordered]@{ index = $c.index; weight = $c.weight; measures = $c.measures; unstable = $c.unstable } }
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
            share = [ordered]@{ used = $false }
            scores = [ordered]@{
                host = [ordered]@{ value = $scores.Host; unstable = $scores.Unstable; partial = $scores.Partial; missingCategories = @($scores.Missing); categories = $categories; provisional = $reference.Provisional }
                fslogix = [ordered]@{ value = $null; status = 'skipped'; reason = 'not built yet' }
                gpu = [ordered]@{ value = $null; status = 'skipped'; reason = 'not built yet' }
            }
            measures = @($measures)
            info = [ordered]@{ warnings = @($warnings); errors = @($errors); quiet = [ordered]@{ stopped = @($quiet.Stopped); failed = @($quiet.Failed) }; user = $User }
            tools = [ordered]@{ engine = $(if ($engine) { [ordered]@{ version = [string]$engine.Version; sha256 = [string]$engine.Sha256 } } else { $null }); diskspd = [ordered]@{ version = [string]$config.diskspd.version; sha256 = [string]$config.diskspd.exeSha256 } }
            capacity = $null
        }
        $result.integrity = [ordered]@{ sha256 = '' }
    }
    finally {
        if ($quiet) {
            try { $back = Stop-AVDTuneBenchmarkQuiet -Machine $Machine -Bench $Bench -Root $Root; if ($result -and @($back.Failed).Count -gt 0) { $result.info.warnings = @($result.info.warnings) + "Quiet mode could not be fully restored: $($back.Failed -join '; ')" } } catch { $errors += "restore: $($_.Exception.Message)"; if ($result) { $result.info.errors = @($result.info.errors) + "restore: $($_.Exception.Message)" } }
        }
        if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
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
    if ($state.ImageVersion) {
        [void](Add-AVDTuneChangeLogEntry -Root $Root -Version ([string]$state.ImageVersion) -Category 'Benchmark' -Component 'Host' -ChangeType Note -Text $label -User $User -RunId $runId -Source Step)
        $logged = $true
    }
    & $say 'Done.' 100
    [pscustomobject]@{ RunId = $runId; Path = $path; Result = $obj; Summary = $label; ChangeLogged = $logged; Errors = @($errors); Warnings = @($warnings) }
}

function Get-AVDTuneBenchmarkSummaryText {
    # One line for the overview, the change log and the protocol
    param([Parameter(Mandatory)]$Result)
    $h = $Result.scores.host
    $cats = @($h.categories.PSObject.Properties | ForEach-Object { "$($_.Name) $($_.Value.index)" }) -join ', '
    $flags = @($Result.mode)
    if ($h.provisional) { $flags += 'vorlaeufige Referenz' }
    if ($h.partial) { $flags += 'Teilscore ohne ' + (@($h.missingCategories) -join '/') }
    if ($h.unstable) { $flags += 'instabil' }
    $val = if ($null -ne $h.value) { [string]$h.value } else { 'no score' }
    "Benchmark $($Result.benchmarkVersion): Host $val ($(($flags) -join ', ')); $cats"
}

#endregion

Export-ModuleMember -Function Get-AVDTuneBenchRound, Get-AVDTuneBenchmarkConfig, Invoke-AVDTuneChildProcess, Initialize-AVDTuneBenchTemp, Get-AVDTuneChildEnvironment, Get-AVDTuneBenchmarkReference, Get-AVDTuneBenchCategoryKey, Get-AVDTuneBenchMedian, Get-AVDTuneBenchCv, Get-AVDTuneBenchIndex,
    Get-AVDTuneBenchGeometricMean, Get-AVDTuneBenchWeightedGeometricMean, Get-AVDTuneBenchPercentile, Get-AVDTuneBenchmarkScores, ConvertFrom-AVDTuneDiskspdXml, New-AVDTuneBenchAdapter,
    Get-AVDTuneDiskspd, Test-AVDTuneBenchmarkPreconditions, Wait-AVDTuneUpdateIdle, Get-AVDTuneBenchmarkJournalPath, Get-AVDTuneBenchmarkRestoreScriptPath, New-AVDTuneBenchmarkRestoreScript,
    Start-AVDTuneBenchmarkQuiet, Stop-AVDTuneBenchmarkQuiet, Get-AVDTuneBenchmarkCrash, Repair-AVDTuneBenchmarkCrash, Test-AVDTuneBenchmarkClean, Get-AVDTuneBenchRestoreAction, Remove-AVDTuneDiskspdCache, Invoke-AVDTuneBenchDisk, Invoke-AVDTuneBenchNetwork,
    Invoke-AVDTuneBenchRun, ConvertTo-AVDTuneBenchAggregate, Get-AVDTuneBenchmarkSystem, Get-AVDTuneBenchmarkIntegrityHash, Test-AVDTuneBenchmarkResult, Get-AVDTuneBenchmarkResultFolder,
    Get-AVDTuneBenchmarkResult, Set-AVDTuneBenchmarkBaseline, Get-AVDTuneBenchmarkBaseline, Compare-AVDTuneBenchmark, Invoke-AVDTuneBenchmark, Get-AVDTuneBenchmarkSummaryText, New-AVDTuneBenchmarkRunId
