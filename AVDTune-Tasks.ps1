# The tasks of this session: one list for everything AVDTune does in the background (sign-in, snapshot, readiness analysis, update search and run,
# repair, maintenance mode, benchmark, self update, watermark ...), shown in the bar at the bottom of the window (AVDTune-TaskBar.ps1).
# Dot-sourced by Start-AVDTune.ps1 after AVDTune-Protocol.ps1 (the cleaning of texts comes from there); no UI code in this file, so Tests\Check-Tasks.ps1 can load it alone.
#
# A task is a synchronized hashtable: Id, Kind, Title, Step (what happens now), Percent ($null = unknown, the bar runs indeterminate), Status (running |
# succeeded | failed), Summary (the result in one line), Started, Finished, Log (list of Time/Level/Text), Retry (a command name and its arguments, never a
# script block: it runs on the UI thread and must not be bound to another runspace). Updates may come from any thread or runspace: every change
# takes the lock of the task and raises the counter of the list. The window reads the state on its timer (the Dispatcher of the UI thread), so a runspace never
# touches a control. Every text is cleaned of tokens, passwords and keys (Remove-PackTuneProtocolSecrets) before it is stored.

$script:UiTasks = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
$script:UiTaskState = [hashtable]::Synchronized(@{ Version = 0; Counter = 0 })
$script:UiTaskMaxLog = 400          # entries per task; older ones are dropped
$script:UiTaskMaxTasks = 100        # tasks kept for the session; the oldest finished ones are dropped
$script:UiTaskResultSeconds = 8     # how long the bar shows the result of a task that just ended

function Step-UiTaskVersion { [System.Threading.Monitor]::Enter($script:UiTaskState.SyncRoot); try { $script:UiTaskState.Version = [int]$script:UiTaskState.Version + 1 } finally { [System.Threading.Monitor]::Exit($script:UiTaskState.SyncRoot) } }
function Get-AVDTuneUiTaskVersion { [int]$script:UiTaskState.Version }
function Get-UiTaskText([string]$Text, [int]$Max = 300) { Remove-PackTuneProtocolSecrets $Text $Max }

function Add-AVDTuneUiTaskLog {
    # One line into the log of a task. Level: Info | Warning | Error
    param([Parameter(Mandatory)]$Task, [AllowEmptyString()][string]$Text, [ValidateSet('Info', 'Warning', 'Error')][string]$Level = 'Info')
    $clean = Get-UiTaskText $Text 300
    if (-not $clean) { return }
    [System.Threading.Monitor]::Enter($Task.SyncRoot)
    try {
        [void]$Task.Log.Add(@{ Time = (Get-Date).ToString('HH:mm:ss'); Level = $Level; Text = $clean })
        while ($Task.Log.Count -gt $script:UiTaskMaxLog) { $Task.Log.RemoveAt(0) }
    }
    finally { [System.Threading.Monitor]::Exit($Task.SyncRoot) }
    Step-UiTaskVersion
}

function Start-AVDTuneUiTask {
    # Registers a task that runs now. -Retry @{ Command = 'Start-Something'; Arguments = @('a') } offers a Retry button after a failure (only for what is safe to run again).
    param(
        [Parameter(Mandatory)][string]$Kind, [Parameter(Mandatory)][string]$Title,
        [string]$Step = '', $Percent = $null, [hashtable]$Retry
    )
    [System.Threading.Monitor]::Enter($script:UiTaskState.SyncRoot)
    try { $script:UiTaskState.Counter = [int]$script:UiTaskState.Counter + 1; $id = [int]$script:UiTaskState.Counter } finally { [System.Threading.Monitor]::Exit($script:UiTaskState.SyncRoot) }
    $task = [hashtable]::Synchronized(@{
            Id = $id; Kind = $Kind; Title = (Get-UiTaskText $Title 120); Step = (Get-UiTaskText $Step 200)
            Percent = $(if ($null -ne $Percent) { [math]::Max(0, [math]::Min(100, [int]$Percent)) } else { $null })
            Status = 'running'; Summary = ''; Started = (Get-Date); Finished = $null; Retry = $Retry
            Log = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
        })
    [void]$script:UiTasks.Add($task)
    # the list stays small: the oldest finished tasks go first
    while ($script:UiTasks.Count -gt $script:UiTaskMaxTasks) {
        $old = @($script:UiTasks.ToArray() | Where-Object { $_.Status -ne 'running' } | Select-Object -First 1)
        if ($old.Count -eq 0) { break }
        $script:UiTasks.Remove($old[0])
    }
    if ($task.Step) { Add-AVDTuneUiTaskLog $task $task.Step }
    Step-UiTaskVersion
    $task
}

function Update-AVDTuneUiTask {
    # What happens now (a new step is also a log line) and how far it is. -Percent $null keeps the value, -Indeterminate clears it.
    param($Task, [AllowEmptyString()][string]$Step, $Percent = $null, [switch]$Indeterminate)   # a task that is not there ($null) is ignored: callers need no check
    if (-not $Task -or $Task.Status -ne 'running') { return }
    $changed = $false
    $clean = if ($PSBoundParameters.ContainsKey('Step')) { Get-UiTaskText $Step 200 } else { $null }
    [System.Threading.Monitor]::Enter($Task.SyncRoot)
    try {
        if ($null -ne $clean -and $clean -ne $Task.Step) { $Task.Step = $clean; $changed = $true }
        if ($Indeterminate -and $null -ne $Task.Percent) { $Task.Percent = $null; $changed = $true }
        elseif ($null -ne $Percent) {
            $p = [math]::Max(0, [math]::Min(100, [int]$Percent))
            if ($Task.Percent -ne $p) { $Task.Percent = $p; $changed = $true }
        }
    }
    finally { [System.Threading.Monitor]::Exit($Task.SyncRoot) }
    if ($changed -and $clean) { Add-AVDTuneUiTaskLog $Task $clean }
    elseif ($changed) { Step-UiTaskVersion }
}

function Complete-AVDTuneUiTask {
    # The end of a task: succeeded, or failed with the cause (-Failed). The summary is the result in one line, shown in the bar for a few seconds.
    param($Task, [switch]$Failed, [AllowEmptyString()][string]$Summary = '')
    if (-not $Task -or $Task.Status -ne 'running') { return }
    $clean = Get-UiTaskText $Summary 240
    [System.Threading.Monitor]::Enter($Task.SyncRoot)
    try {
        $Task.Status = $(if ($Failed) { 'failed' } else { 'succeeded' })
        $Task.Summary = $clean
        $Task.Finished = Get-Date
        if (-not $Failed) { $Task.Percent = 100 }
        $Task.Step = ''
    }
    finally { [System.Threading.Monitor]::Exit($Task.SyncRoot) }
    if ($clean) { Add-AVDTuneUiTaskLog $Task $clean $(if ($Failed) { 'Error' } else { 'Info' }) }
    Step-UiTaskVersion
}

# a copy of the list (callers wrap it in @() to get an array for 0 or 1 entries)
function Get-AVDTuneUiTasks { $script:UiTasks.ToArray() }
function Get-AVDTuneUiTaskLog($Task) { [System.Threading.Monitor]::Enter($Task.SyncRoot); try { $Task.Log.ToArray() } finally { [System.Threading.Monitor]::Exit($Task.SyncRoot) } }

function Format-AVDTuneUiTaskDuration {
    param([datetime]$From, $To = $null)
    if (-not $From) { return '' }
    $end = if ($To) { [datetime]$To } else { Get-Date }
    $span = $end - $From; if ($span.TotalSeconds -lt 0) { $span = [timespan]::Zero }
    if ($span.TotalMinutes -ge 60) { return '{0} h {1} min' -f [int][math]::Floor($span.TotalHours), $span.Minutes }
    if ($span.TotalMinutes -ge 1) { return '{0} min {1} s' -f [int][math]::Floor($span.TotalMinutes), $span.Seconds }
    '{0} s' -f [int][math]::Floor($span.TotalSeconds)
}

function Get-AVDTuneUiTaskBar {
    # What the bar shows, decided in one place. Kind: Running (the oldest running task is the shown one, Count tasks run) | Result (a task ended less than
    # ResultSeconds ago, none runs) | Idle. Percent is $null while the shown task cannot say how far it is.
    param($Tasks = (Get-AVDTuneUiTasks), [datetime]$Now = (Get-Date), [int]$ResultSeconds = $script:UiTaskResultSeconds)
    $all = @($Tasks)
    $running = @($all | Where-Object { $_.Status -eq 'running' } | Sort-Object { [int]$_.Id })
    $failedCount = @($all | Where-Object { $_.Status -eq 'failed' }).Count
    $bar = @{ Kind = 'Idle'; Count = $all.Count; Running = $running.Count; Failed = $failedCount; Task = $null; Title = ''; Step = ''; Percent = $null; Result = ''; Ok = $true }
    if ($running.Count -gt 0) {
        $t = $running[0]
        $bar.Kind = 'Running'; $bar.Task = $t; $bar.Title = [string]$t.Title; $bar.Step = [string]$t.Step; $bar.Percent = $t.Percent
        return $bar
    }
    $last = @($all | Where-Object { $_.Finished } | Sort-Object { [datetime]$_.Finished } | Select-Object -Last 1)
    if ($last.Count -gt 0 -and ($Now - [datetime]$last[0].Finished).TotalSeconds -lt $ResultSeconds) {
        $t = $last[0]
        $bar.Kind = 'Result'; $bar.Task = $t; $bar.Title = [string]$t.Title; $bar.Ok = ($t.Status -eq 'succeeded')
        $bar.Result = $(if ($t.Summary) { [string]$t.Summary } elseif ($bar.Ok) { 'Done' } else { 'Failed' })
    }
    $bar
}

function Get-AVDTuneUiTaskLabel([string]$Status) { switch ($Status) { 'running' { 'Running' } 'succeeded' { 'Done' } default { 'Failed' } } }

# Who may change the master at the same time: nobody. The operations that change it run in the background (their jobs, one script variable each) or inline on the window
# thread, and state.json, the snapshot gate marker and the machine itself are not made for two writers at once (#66). Every start of such an operation (and every inline writer)
# calls Assert-NoOtherWriter first. A new job adds the name of its script variable to the list; a job that is read only in some of its kinds names them.
# RelJob is the release job (install, repair, back change AVDTune itself; the checks only read, #49).
$script:WriterJobVariables = @('OptRun', 'UpdJob', 'BenchJob', 'SealJob', 'SwJob', 'FslJob', 'OffJob', 'LangJob', 'VdiJob', 'ReadyJob', 'RelJob')
$script:WriterReadOnlyKinds = @{ UpdJob = @('Scan'); SwJob = @('Scan'); VdiJob = @('Latest'); ReadyJob = @('Start', 'Erstanalyse', 'Healthcheck', 'Manual'); RelJob = @('Start', 'Check') }
function Get-AVDTuneRunningWriter {
    # The name of the running job that changes the master, '' when there is none
    foreach ($name in $script:WriterJobVariables) {
        $job = Get-Variable -Scope Script -Name $name -ValueOnly -ErrorAction SilentlyContinue
        if (-not $job) { continue }
        $kind = $null; try { $kind = [string]$job.Kind } catch { }
        if ($kind -and $script:WriterReadOnlyKinds.ContainsKey($name) -and $kind -in $script:WriterReadOnlyKinds[$name]) { continue }
        return $name
    }
    ''
}
function Assert-NoOtherWriter {
    $w = Get-AVDTuneRunningWriter
    if ($w) { throw "Another operation that changes the master is still running ($w). Wait until it is done." }
}
