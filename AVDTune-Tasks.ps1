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
# RelJob is the release job (install, repair, back change AVDTune itself; the checks only read, #49). CustJob: customizations (#85), Status only reads. PrnJob: printers (#86), Servers and Read only read. EnvJob: environment page (#44), Plan and UndoPlan only read Azure. CswJob: custom software (#87), Status only reads.
$script:WriterJobVariables = @('OptRun', 'UpdJob', 'BenchJob', 'SealJob', 'SwJob', 'FslJob', 'OffJob', 'LangJob', 'VdiJob', 'ReadyJob', 'RelJob', 'CustJob', 'PrnJob', 'CswJob', 'EnvJob', 'SpJob')
$script:WriterReadOnlyKinds = @{ UpdJob = @('Scan'); SwJob = @('Scan'); VdiJob = @('Latest'); ReadyJob = @('Start', 'Erstanalyse', 'Healthcheck', 'Manual'); RelJob = @('Start', 'Check'); CustJob = @('Status', 'Reach', 'Preview'); PrnJob = @('Servers', 'Read'); CswJob = @('Status'); EnvJob = @('Plan', 'UndoPlan') }
# #49 (3): the central lock. An operation that is not one of the jobs above (inline on the window thread: watermark, benchmark repair, finish repair, new version)
# takes it with Enter-AVDTuneWriter (kind and title; the check of Assert-NoOtherWriter first) and gives it back with Exit-AVDTuneWriter in its finally.
# Get-AVDTuneRunningWriter reads the held entries first (their title), then the job variables; the write buttons follow both.
$script:WriterHolds = New-Object System.Collections.ArrayList
function Enter-AVDTuneWriter {
    param([Parameter(Mandatory)][string]$Kind, [Parameter(Mandatory)][string]$Title, [switch]$AllowSealed)
    Assert-NoOtherWriter -AllowSealed:$AllowSealed
    $hold = @{ Kind = $Kind; Title = $Title; Since = (Get-Date) }   # a hashtable: Remove finds it by reference ([pscustomobject] compare equal to each other)
    [void]$script:WriterHolds.Add($hold)
    if ($script:WriterLockCommand) { $script:WriterLockCommand.Busy = $true }   # the buttons lock at once, not only at the next tick of the timer
    $hold
}
function Exit-AVDTuneWriter {
    # gives the lock back (a second call or $null does nothing); called in finally
    param($Hold)
    if ($null -ne $Hold) { $script:WriterHolds.Remove($Hold) }
    if ($script:WriterLockCommand) { $script:WriterLockCommand.Busy = [bool](Get-AVDTuneRunningWriter) }
}
function Get-AVDTuneWriterHold { @($script:WriterHolds) }   # kind, title and start of the held entries (the job writers are not in it)
function Get-AVDTuneRunningWriter {
    # The title of the held lock or the name of the running job that changes the master, '' when there is none
    foreach ($hold in @($script:WriterHolds)) { if ($hold) { return [string]$hold.Title } }
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
    # #50: a finished version (Sealed) takes no further change until "Start new version"; only the repairs of a crash (they put back what was lifted) pass -AllowSealed.
    # The engine refuses as well (Start-AVDTuneChange); this gives the clear message before anything starts.
    param([switch]$AllowSealed)
    $w = Get-AVDTuneRunningWriter
    if ($w) { throw "Another operation that changes the master is still running ($w). Wait until it is done." }
    if (-not $AllowSealed -and $script:StateRoot -and (Test-AVDTuneSealed -Root $script:StateRoot)) { throw (T 'shell.sealed') }   # the window always has a state root; the engine refuses on its own as well
}

# #49 (4): one global lock of the write buttons while a writer job runs, in one place instead of on every page. Each button below gets the one command
# AVDTune.WriterLockCommand (it does nothing on a click); WPF disables a button whose command cannot execute, on top of what the page sets itself, so the
# page keeps its own state and gets it back when the writer has ended. The window timer sets Busy from Get-AVDTuneRunningWriter and wires buttons that
# pages build later (Masking, Customizations, Language, Optimization); buttons of code rows get it through Set-AVDTuneWriterButton. A click that comes through anyway is still refused by Assert-NoOtherWriter.
$script:WriterButtons = @(
    'BtnMaskApply', 'BtnMaskUndo', 'BtnMaskLogoff', 'BtnBenchFull', 'BtnBenchQuick', 'BtnBenchRepair', 'BtnCustApplyAll', 'BtnEnvApply', 'BtnEnvUndo', 'BtnEnvMasterApply',
    'BtnFslSettingsApply', 'BtnFslSettingsUndo', 'BtnFslListsApply', 'BtnFslListsUndo', 'BtnFslGroupAdd', 'BtnFslGroupRemove', 'BtnFslExcludeAdmins', 'BtnFslRedirSave',
    'BtnFslRedirUndo', 'BtnFslDefAdd', 'BtnFslDefUndo', 'BtnFslInstall', 'BtnFslAclSet', 'BtnFslTestWrite', 'BtnFslStorage', 'BtnLangInstall', 'BtnLangApply', 'BtnLangUndo',
    'BtnOffInstall', 'BtnOffRemove', 'BtnOffUndo', 'BtnOffPolicies', 'BtnOffPoliciesUndo', 'BtnOffFixUndo', 'BtnOptApply', 'BtnOptUndo', 'BtnRelInstall', 'BtnRelRepair',
    'BtnRelBack', 'BtnSealRun', 'BtnSealRepair', 'BtnSwUpdateAll', 'BtnUpdAll', 'BtnUpdSelected', 'BtnRepairDism', 'BtnRepairSfc', 'BtnBlockOn', 'BtnBlockOff',
    'BtnBlockRepair', 'BtnWmInstall', 'BtnWmRemove', 'BtnWmLegacy', 'BtnSnapDelete')
function New-AVDTuneWriterLockCommand {
    if (-not ('AVDTune.WriterLockCommand' -as [type])) {
        Add-Type -TypeDefinition @'
namespace AVDTune {
    public sealed class WriterLockCommand : System.Windows.Input.ICommand {
        private bool busy;
        public event System.EventHandler CanExecuteChanged;
        public bool Busy {
            get { return busy; }
            set { if (busy == value) return; busy = value; System.EventHandler h = CanExecuteChanged; if (h != null) h(this, System.EventArgs.Empty); }
        }
        public bool CanExecute(object parameter) { return !busy; }
        public void Execute(object parameter) { }
    }
}
'@
    }
    New-Object AVDTune.WriterLockCommand
}
function Get-AVDTuneWriterLockCommand {
    # the one command of the window (created once): the timer and Enter/Exit-AVDTuneWriter set Busy, the buttons get it
    if (-not $script:WriterLockCommand) { $script:WriterLockCommand = New-AVDTuneWriterLockCommand }
    $script:WriterLockCommand
}
function Set-AVDTuneWriterButton {
    # #49: a write button a page builds in a row (software, VDI, masking, customizations, Office fix, readiness fix) is locked by the same command while a writer runs
    param([Parameter(Mandatory)]$Button)
    $Button.Command = Get-AVDTuneWriterLockCommand
    $Button
}
function Update-AVDTuneWriterLock {
    # One tick of the window timer: wire the listed buttons that exist (once each) and set Busy. $Ui is the element table of the window.
    param([Parameter(Mandatory)]$Command, [Parameter(Mandatory)]$Ui)
    foreach ($name in $script:WriterButtons) {
        $b = $Ui[$name]
        if ($b -and -not [object]::ReferenceEquals($b.Command, $Command)) { $b.Command = $Command }
    }
    $Command.Busy = [bool](Get-AVDTuneRunningWriter)
}
