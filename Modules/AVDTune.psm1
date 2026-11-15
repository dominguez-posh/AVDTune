<#
    AVDTune engine: no UI. Used by Start-AVDTune.ps1, by the command line (Invoke-AVDTune -Plan x.json -WhatIf) and by the checks.

    Parts
      1. Machine adapters (registry, services, tasks, native commands, instance metadata). Every access to the machine goes through
         one adapter object, so the checks run against a fake (Tests\Fakes\FakeMachine.ps1) and never touch a real system.
      2. State under C:\ProgramData\AVDTune (override: environment variable AVDTUNE_ROOT, used by checks and the smoke test):
         state.json (current), runs\ (one record per run, append only), changelog.json, protocols\, config\, benchmark\, logs\.
         Written atomically, ACL Administrators/SYSTEM. No secrets, no tokens.
      3. Step contract: Id, Section, Title, Why, Risk, Reboot, SourceUrl, Test, Apply, Undo. Idempotent; WhatIf changes nothing.
      4. Change log per image version (YYYY.MM.NNN) with export to Markdown and HTML.
      5. Overview data: image identity (source image from the instance metadata), builds, health checks.
#>

Set-StrictMode -Version 2.0

$script:StateSchema = 1
$script:ImageVersionPattern = '^\d{4}\.(0[1-9]|1[0-2])\.\d{3}$'
$script:ChangeTypes = @('Added', 'Changed', 'Updated', 'Removed', 'Note')
$script:StepSections = @('Setup', 'Updates', 'Software', 'Office', 'Optimization', 'FSLogix', 'AppMasking', 'VdiComponents', 'UserExperience', 'UpdateBlock', 'Benchmark', 'Seal')
$script:StepModes = @('Test', 'Apply', 'Undo')

#region elevation, root

function Get-AVDTuneProp($Object, [string]$Name) {
    # Optional property of parsed json: $null when it is not there (strict mode would throw)
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { $p.Value } else { $null }
}

function Test-AVDTuneElevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-AVDTuneRoot {
    if ($env:AVDTUNE_ROOT) { return $env:AVDTUNE_ROOT }
    Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'AVDTune'
}

function Test-AVDTuneDefaultRoot([string]$Root) {
    # True for the real state folder: the only place where the ACL is enforced
    $default = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'AVDTune'
    [string]::Equals($Root.TrimEnd('\'), $default.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)
}

#endregion

#region machine adapters

function ConvertTo-AVDTuneArgument([string]$Value) {
    # One argument of a command line, quoted the way CommandLineToArgvW reads it. Arguments are data: never joined by hand elsewhere.
    if ($Value -ne '' -and $Value -notmatch '[\s"]') { return $Value }
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    '"' + $escaped + '"'
}

function New-AVDTuneMachine {
    <#
        The real machine. Registry paths use the PowerShell form (HKLM:\SOFTWARE\...). Reads work everywhere; the writing members change
        the system and are only used by Apply of a step after a visible selection. Tests use New-AVDTuneFakeMachine instead.
    #>
    $m = [ordered]@{ Kind = 'Real' }
    $m.ComputerName = { [Environment]::MachineName }
    $m.Now = { Get-Date }
    $m.RegKeyExists = { param($Path) Test-Path -LiteralPath $Path }
    $m.RegGet = {
        param($Path, $Name)
        if (-not (Test-Path -LiteralPath $Path)) { return $null }
        $item = Get-ItemProperty -LiteralPath $Path -ErrorAction SilentlyContinue
        if ($null -eq $item) { return $null }
        $prop = $item.PSObject.Properties[$Name]
        if ($prop) { $prop.Value } else { $null }
    }
    $m.RegSet = {
        param($Path, $Name, $Value, $Type)
        if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
        Set-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -Type $Type
    }
    $m.RegRemove = {
        param($Path, $Name)
        if (Test-Path -LiteralPath $Path) { Remove-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue }
    }
    $m.ServiceGet = {
        param($Name)
        $s = Get-Service -Name $Name -ErrorAction SilentlyContinue
        if (-not $s) { return $null }
        [pscustomobject]@{ Name = $s.Name; Status = [string]$s.Status; StartType = [string]$s.StartType }
    }
    $m.ServiceSetStartup = { param($Name, $Startup) Set-Service -Name $Name -StartupType $Startup }
    $m.ServiceStop = { param($Name) Stop-Service -Name $Name -Force }
    $m.ServiceStart = { param($Name) Start-Service -Name $Name }
    $m.TaskGet = {
        param($Path, $Name)
        $t = Get-ScheduledTask -TaskPath $Path -TaskName $Name -ErrorAction SilentlyContinue
        if (-not $t) { return $null }
        [pscustomobject]@{ Path = $t.TaskPath; Name = $t.TaskName; Enabled = ($t.State -ne 'Disabled') }
    }
    $m.TaskList = {
        # Names of the tasks directly in a folder (for tasks whose name carries a GUID, like the Edge update tasks)
        param($Path)
        @(Get-ScheduledTask -TaskPath $Path -ErrorAction SilentlyContinue | ForEach-Object { $_.TaskName })
    }
    $m.TaskSetEnabled = {
        param($Path, $Name, $Enabled)
        if ($Enabled) { Enable-ScheduledTask -TaskPath $Path -TaskName $Name | Out-Null } else { Disable-ScheduledTask -TaskPath $Path -TaskName $Name | Out-Null }
    }
    $m.Run = {
        # File and arguments are separate; the command line is built here with quoting per argument, never from free text
        param($File, [string[]]$Arguments, [int]$TimeoutSeconds = 120)
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $File
        $psi.Arguments = (@($Arguments | ForEach-Object { ConvertTo-AVDTuneArgument ([string]$_) }) -join ' ')
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $out = $p.StandardOutput.ReadToEndAsync(); $err = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit($TimeoutSeconds * 1000)) { try { $p.Kill() } catch { }; return [pscustomobject]@{ ExitCode = -1; Output = 'timeout' } }
        [pscustomobject]@{ ExitCode = $p.ExitCode; Output = ($out.Result + $err.Result) }
    }
    $m.Imds = {
        # Azure instance metadata: only reachable inside Azure; $null elsewhere
        try {
            $request = [System.Net.HttpWebRequest]::Create('http://169.254.169.254/metadata/instance?api-version=2021-02-01')
            $request.Headers.Add('Metadata', 'true'); $request.Timeout = 2500; $request.Proxy = $null
            $response = $request.GetResponse()
            try { (New-Object IO.StreamReader($response.GetResponseStream())).ReadToEnd() | ConvertFrom-Json } finally { $response.Close() }
        }
        catch { $null }
    }
    [pscustomobject]$m
}

function Invoke-AVDTuneMachine {
    # Calls a member of the adapter: Invoke-AVDTuneMachine $m RegGet 'HKLM:\...' 'Name'
    param([Parameter(Mandatory)]$Machine, [Parameter(Mandatory)][string]$Member, [Parameter(ValueFromRemainingArguments)]$Arguments)
    $block = $Machine.$Member
    if ($null -eq $block) { throw "The machine adapter has no member '$Member'." }
    & $block @Arguments
}

#endregion

#region state

function New-AVDTuneStateSecurity {
    # Administrators and SYSTEM only, no inheritance from ProgramData (which lets every user read)
    $security = New-Object System.Security.AccessControl.DirectorySecurity
    $security.SetAccessRuleProtection($true, $false)
    foreach ($sid in 'S-1-5-32-544', 'S-1-5-18') {
        $account = New-Object System.Security.Principal.SecurityIdentifier $sid
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($account, 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow')
        $security.AddAccessRule($rule)
    }
    $security
}

function Write-AVDTuneFile {
    # Written next to the target, then moved over it: a crash leaves the old or the new file, never half of one
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Text)
    $folder = Split-Path $Path -Parent
    if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
    $temp = "$Path.$([guid]::NewGuid().ToString('N').Substring(0, 8)).tmp"
    try {
        [IO.File]::WriteAllText($temp, $Text, (New-Object Text.UTF8Encoding $false))
        if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temp, $Path, [NullString]::Value) } else { [IO.File]::Move($temp, $Path) }
    }
    finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue } }
}

function Read-AVDTuneJson([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $text = [IO.File]::ReadAllText($Path).TrimStart([char]0xFEFF)
    if (-not $text.Trim()) { return $null }
    $text | ConvertFrom-Json
}

function Initialize-AVDTuneState {
    <#
        Creates the folders and the empty state.json / changelog.json when they are not there. -Protect sets the ACL (Administrators/SYSTEM);
        it is the default for the real folder and off for a test root.
    #>
    [CmdletBinding()]
    param([string]$Root = (Get-AVDTuneRoot), [switch]$Protect)
    if (-not (Test-Path -LiteralPath $Root)) { New-Item -ItemType Directory -Path $Root -Force | Out-Null }
    foreach ($sub in 'runs', 'protocols', 'config', 'benchmark', 'logs') {
        $path = Join-Path $Root $sub
        if (-not (Test-Path -LiteralPath $path)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
    }
    if ($Protect -or (Test-AVDTuneDefaultRoot $Root)) {
        $security = New-AVDTuneStateSecurity
        Set-Acl -LiteralPath $Root -AclObject $security
    }
    $statePath = Join-Path $Root 'state.json'
    if (-not (Test-Path -LiteralPath $statePath)) {
        Write-AVDTuneFile $statePath ([ordered]@{
                Schema = $script:StateSchema; ImageVersion = $null; Versions = @(); LastUpdate = $null; LastBenchmark = $null
                UpdateBlock = $null; Sealed = $false; Identity = $null; LastRunId = $null
            } | ConvertTo-Json -Depth 6)
    }
    $changePath = Join-Path $Root 'changelog.json'
    if (-not (Test-Path -LiteralPath $changePath)) {
        Write-AVDTuneFile $changePath ([ordered]@{ Schema = $script:StateSchema; Entries = @() } | ConvertTo-Json -Depth 6)
    }
    $Root
}

function Get-AVDTuneState([string]$Root = (Get-AVDTuneRoot)) {
    $state = Read-AVDTuneJson (Join-Path $Root 'state.json')
    if ($null -eq $state) { throw "No state in $Root (Initialize-AVDTuneState first)." }
    if ([int]$state.Schema -gt $script:StateSchema) { throw "The state in $Root is from a newer AVDTune (schema $($state.Schema))." }
    $state
}

function Set-AVDTuneState {
    # Changes single values of state.json: Set-AVDTuneState -Values @{ UpdateBlock = 'On' }
    param([string]$Root = (Get-AVDTuneRoot), [Parameter(Mandatory)][hashtable]$Values)
    $state = Get-AVDTuneState $Root
    foreach ($key in $Values.Keys) {
        if ($state.PSObject.Properties[$key]) { $state.$key = $Values[$key] } else { Add-Member -InputObject $state -NotePropertyName $key -NotePropertyValue $Values[$key] }
    }
    Write-AVDTuneFile (Join-Path $Root 'state.json') ($state | ConvertTo-Json -Depth 6)
    $state
}

function Test-AVDTuneImageVersion([string]$Version) { $Version -match $script:ImageVersionPattern }

function Get-AVDTuneNextImageVersion {
    # YYYY.MM.NNN: NNN counts per month, starting at 001
    param([string]$Root = (Get-AVDTuneRoot), [datetime]$Date = (Get-Date))
    $prefix = $Date.ToString('yyyy.MM', [Globalization.CultureInfo]::InvariantCulture)
    $highest = 0
    $state = Get-AVDTuneState $Root
    foreach ($v in @($state.Versions)) {
        if ($v -and ([string]$v.Version) -like "$prefix.*") { $n = [int]($v.Version.Substring(8)); if ($n -gt $highest) { $highest = $n } }
    }
    '{0}.{1:000}' -f $prefix, ($highest + 1)
}

function Start-AVDTuneImageVersion {
    # "Start new version": raises the version, clears the seal, keeps the list of versions with their start time
    param([string]$Root = (Get-AVDTuneRoot), [datetime]$Date = (Get-Date), [string]$User)
    $version = Get-AVDTuneNextImageVersion -Root $Root -Date $Date
    $state = Get-AVDTuneState $Root
    $list = @(@($state.Versions) | Where-Object { $_ }) + [pscustomobject]@{ Version = $version; Started = $Date.ToString('o'); User = $User }
    [void](Set-AVDTuneState -Root $Root -Values @{ ImageVersion = $version; Versions = $list; Sealed = $false })
    $version
}

function Add-AVDTuneRun {
    <#
        One record per run, append only: a record is created with CreateNew and never replaced. $Run needs Id (made here when missing),
        Started, Ended, User, SnapshotId, WhatIf, Results.
    #>
    param([string]$Root = (Get-AVDTuneRoot), [Parameter(Mandatory)]$Run)
    $folder = Join-Path $Root 'runs'
    if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
    $id = [string]$Run.Id
    if (-not $id) { $id = (Get-Date).ToString('yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture) + '-' + [guid]::NewGuid().ToString('N').Substring(0, 4); $Run.Id = $id }
    if ($id -notmatch '^[A-Za-z0-9._-]{1,60}$') { throw "Invalid run id '$id'." }
    $path = Join-Path $folder "$id.json"
    $stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)   # throws when the record exists
    try {
        $bytes = (New-Object Text.UTF8Encoding $false).GetBytes(($Run | ConvertTo-Json -Depth 8))
        $stream.Write($bytes, 0, $bytes.Length)
    }
    finally { $stream.Dispose() }
    [void](Set-AVDTuneState -Root $Root -Values @{ LastRunId = $id })
    $path
}

function Get-AVDTuneRun {
    param([string]$Root = (Get-AVDTuneRoot), [string]$Id)
    $folder = Join-Path $Root 'runs'
    if (-not (Test-Path -LiteralPath $folder)) { return @() }
    $files = Get-ChildItem -LiteralPath $folder -Filter '*.json' -File | Sort-Object Name
    if ($Id) { $files = @($files | Where-Object { $_.BaseName -eq $Id }) }
    @($files | ForEach-Object { Read-AVDTuneJson $_.FullName })
}

#endregion

#region write gate

# The snapshot gate (AVDTune.Snapshot.psm1) opens this when a snapshot of today is confirmed by name. Until then the engine refuses every
# change of the master (Apply and Undo without -WhatIf); reading and dry runs always work. The gate is held in memory only: a new
# start of AVDTune starts closed.
$script:WriteGate = $null

function Open-AVDTuneWriteGate {
    param([Parameter(Mandatory)][string]$SnapshotId, [Parameter(Mandatory)][string]$ConfirmedBy)
    $script:WriteGate = [pscustomobject]@{ SnapshotId = $SnapshotId; ConfirmedBy = $ConfirmedBy; At = (Get-Date).ToString('o') }
}
function Close-AVDTuneWriteGate { $script:WriteGate = $null }
function Get-AVDTuneWriteGate { $script:WriteGate }
function Test-AVDTuneWriteAllowed { $null -ne $script:WriteGate }

#endregion

#region steps

function New-AVDTuneStep {
    <#
        A step is data plus small scriptblocks that only talk to the machine adapter ($m).
          Test  { param($m) @{ Compliant = $true/$false; State = <what was found> } }   (a plain $true/$false works too)
          Apply { param($m) ... }       makes the machine compliant; the engine tests before and after
          Undo  { param($m) ... }       optional
    #>
    param(
        [Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$Section, [Parameter(Mandatory)][string]$Title,
        [string]$Why, [ValidateSet('Low', 'Medium', 'High')][string]$Risk = 'Low', [bool]$Reboot = $false, [string]$SourceUrl,
        [Parameter(Mandatory)][scriptblock]$Test, [Parameter(Mandatory)][scriptblock]$Apply, [scriptblock]$Undo
    )
    if ($Id -notmatch '^[a-z0-9]+(\.[a-z0-9-]+)+$') { throw "Step id '$Id' must look like section.name (lower case)." }
    if ($Section -notin $script:StepSections) { throw "Unknown section '$Section'." }
    if ($SourceUrl -and $SourceUrl -notmatch '^https://') { throw "The source of step $Id must be an https URL." }
    [pscustomobject]@{ Id = $Id; Section = $Section; Title = $Title; Why = $Why; Risk = $Risk; Reboot = $Reboot; SourceUrl = $SourceUrl; Test = $Test; Apply = $Apply; Undo = $Undo }
}

function ConvertTo-AVDTuneTestResult($Raw) {
    if ($Raw -is [bool]) { return [pscustomobject]@{ Compliant = $Raw; State = $null } }
    if ($Raw -is [System.Collections.IDictionary]) { return [pscustomobject]@{ Compliant = [bool]$Raw['Compliant']; State = $Raw['State'] } }
    if ($null -ne $Raw -and $Raw.PSObject.Properties['Compliant']) { return [pscustomobject]@{ Compliant = [bool]$Raw.Compliant; State = $Raw.State } }
    throw 'A step test must return $true/$false or @{ Compliant; State }.'
}

function Invoke-AVDTuneStep {
    <#
        Mode Test:  Compliant | NonCompliant | Failed
        Mode Apply: Unchanged (already compliant) | Changed | Failed (after the change the test still fails) | WhatIf (would change)
        Mode Undo:  Reverted | Unchanged | NoUndo | Failed | WhatIf
        Before and After are the states found by the test. Nothing is changed with -WhatIf.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Step, [Parameter(Mandatory)]$Machine, [ValidateSet('Test', 'Apply', 'Undo')][string]$Mode = 'Test', [switch]$WhatIf)
    if (($Mode -in 'Apply', 'Undo') -and -not $WhatIf -and -not (Test-AVDTuneWriteAllowed)) {
        throw 'The snapshot gate is not confirmed: AVDTune is read only until a snapshot of today is confirmed on the Overview.'
    }
    $started = & $Machine.Now
    $result = [ordered]@{
        Id = $Step.Id; Section = $Step.Section; Title = $Step.Title; Mode = $Mode; Status = 'Failed'; Before = $null; After = $null; Message = ''
        Reboot = $false; WhatIf = [bool]$WhatIf; At = $started.ToString('o')
    }
    try {
        $before = ConvertTo-AVDTuneTestResult (& $Step.Test $Machine)
        $result.Before = $before.State
        switch ($Mode) {
            'Test' { $result.Status = if ($before.Compliant) { 'Compliant' } else { 'NonCompliant' } }
            'Apply' {
                if ($before.Compliant) { $result.Status = 'Unchanged'; $result.After = $before.State }
                elseif ($WhatIf) { $result.Status = 'WhatIf'; $result.Message = 'Would change.' }
                else {
                    [void](& $Step.Apply $Machine)
                    $after = ConvertTo-AVDTuneTestResult (& $Step.Test $Machine)
                    $result.After = $after.State
                    if ($after.Compliant) { $result.Status = 'Changed'; $result.Reboot = [bool]$Step.Reboot }
                    else { $result.Status = 'Failed'; $result.Message = 'The test still fails after Apply.' }
                }
            }
            'Undo' {
                if (-not $Step.Undo) { $result.Status = 'NoUndo'; $result.Message = 'This step has no undo.' }
                elseif (-not $before.Compliant) { $result.Status = 'Unchanged'; $result.After = $before.State; $result.Message = 'The step was not applied.' }
                elseif ($WhatIf) { $result.Status = 'WhatIf'; $result.Message = 'Would undo.' }
                else {
                    [void](& $Step.Undo $Machine)
                    $after = ConvertTo-AVDTuneTestResult (& $Step.Test $Machine)
                    $result.After = $after.State
                    if (-not $after.Compliant) { $result.Status = 'Reverted'; $result.Reboot = [bool]$Step.Reboot }
                    else { $result.Status = 'Failed'; $result.Message = 'The test still passes after Undo.' }
                }
            }
        }
    }
    catch { $result.Status = 'Failed'; $result.Message = $_.Exception.Message }
    [pscustomobject]$result
}

function New-AVDTuneStepFromData {
    <#
        Declarative steps (AVDTune\steps\*.json) for the usual cases, so most steps need no scriptblock:
          Kind Registry        Path, Name, Value, Type (DWord/String/...)         Undo: Previous (value) or remove when absent
          Kind ServiceStartup  Name, Startup (Disabled/Manual/Automatic)
          Kind TaskDisabled    TaskPath, TaskName
    #>
    param([Parameter(Mandatory)]$Data)
    function P([string]$n) { Get-AVDTuneProp $Data $n }
    $common = @{ Id = [string](P Id); Section = [string](P Section); Title = [string](P Title); Why = [string](P Why); Risk = $(if (P Risk) { [string](P Risk) } else { 'Low' }); Reboot = [bool](P Reboot); SourceUrl = [string](P SourceUrl) }
    switch ([string](P Kind)) {
        'Registry' {
            $path = [string](P Path); $name = [string](P Name); $want = P Value; $type = $(if (P Type) { [string](P Type) } else { 'DWord' })
            if ($path -notmatch '^(HKLM|HKCU):[\\]') { throw "Step $(P Id): registry path must start with HKLM: or HKCU: and a backslash" }
            $previous = P Previous
            $test = { param($m) $v = & $m.RegGet $path $name; @{ Compliant = ($null -ne $v -and [string]$v -eq [string]$want); State = $v } }.GetNewClosure()
            $apply = { param($m) & $m.RegSet $path $name $want $type }.GetNewClosure()
            $undo = { param($m) if ($null -ne $previous) { & $m.RegSet $path $name $previous $type } else { & $m.RegRemove $path $name } }.GetNewClosure()
        }
        'ServiceStartup' {
            $name = [string](P Name); $startup = [string](P Startup); $previous = [string](P Previous)
            $test = { param($m) $s = & $m.ServiceGet $name; if (-not $s) { @{ Compliant = $true; State = 'absent' } } else { @{ Compliant = ($s.StartType -eq $startup); State = $s.StartType } } }.GetNewClosure()
            $apply = { param($m) & $m.ServiceSetStartup $name $startup }.GetNewClosure()
            $undo = { param($m) if ($previous) { & $m.ServiceSetStartup $name $previous } }.GetNewClosure()
        }
        'TaskDisabled' {
            $taskPath = [string](P TaskPath); $taskName = [string](P TaskName)
            $test = { param($m) $t = & $m.TaskGet $taskPath $taskName; if (-not $t) { @{ Compliant = $true; State = 'absent' } } else { @{ Compliant = (-not $t.Enabled); State = $(if ($t.Enabled) { 'enabled' } else { 'disabled' }) } } }.GetNewClosure()
            $apply = { param($m) & $m.TaskSetEnabled $taskPath $taskName $false }.GetNewClosure()
            $undo = { param($m) & $m.TaskSetEnabled $taskPath $taskName $true }.GetNewClosure()
        }
        default { throw "Step $(P Id): unknown kind '$($Data.Kind)'." }
    }
    New-AVDTuneStep @common -Test $test -Apply $apply -Undo $undo
}

function Get-AVDTuneStepCatalog {
    # All steps of a folder with *.json files (each a step or an array of steps); duplicate ids are an error
    param([Parameter(Mandatory)][string]$Path)
    $steps = [ordered]@{}
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    foreach ($file in Get-ChildItem -LiteralPath $Path -Filter '*.json' -File | Sort-Object Name) {
        # PowerShell 5.1 hands a json array over as one object: flatten it
        foreach ($item in @(Read-AVDTuneJson $file.FullName)) {
            foreach ($data in @($item)) {
                $step = New-AVDTuneStepFromData $data
                if ($steps.Contains($step.Id)) { throw "Step id '$($step.Id)' is defined twice ($($file.Name))." }
                $steps[$step.Id] = $step
            }
        }
    }
    @($steps.Values)
}

function Invoke-AVDTune {
    <#
        Runs a plan (an object or a .json file: { Name, Steps = [ids] }) against a machine: dry run with -WhatIf, otherwise Apply.
        Stops at the first failed step (the rest is Skipped). Writes one run record, an automatic change log entry for every
        change, and returns the run. With -WhatIf nothing is written at all.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Plan, [Parameter(Mandatory)][object[]]$Catalog, $Machine = (New-AVDTuneMachine),
        [string]$Root = (Get-AVDTuneRoot), [string]$User, [string]$SnapshotId, [switch]$WhatIf
    )
    if ($Plan -is [string]) { $Plan = Read-AVDTuneJson $Plan }
    $byId = @{}; foreach ($s in $Catalog) { $byId[$s.Id] = $s }
    $selected = @(@($Plan.Steps) | ForEach-Object { [string]$_ })
    foreach ($id in $selected) { if (-not $byId.ContainsKey($id)) { throw "The plan names the unknown step '$id'." } }
    $started = & $Machine.Now
    $results = New-Object System.Collections.ArrayList
    $stopped = $false
    foreach ($id in $selected) {
        $step = $byId[$id]
        if ($stopped) {
            [void]$results.Add([pscustomobject]@{ Id = $id; Section = $step.Section; Title = $step.Title; Mode = 'Apply'; Status = 'Skipped'; Before = $null; After = $null; Message = 'An earlier step failed.'; Reboot = $false; WhatIf = [bool]$WhatIf; At = $null })
            continue
        }
        $r = Invoke-AVDTuneStep -Step $step -Machine $Machine -Mode Apply -WhatIf:$WhatIf
        [void]$results.Add($r)
        if ($r.Status -eq 'Failed') { $stopped = $true }
    }
    $run = [pscustomobject][ordered]@{
        Id = $null; Plan = [string]$Plan.Name; Started = $started.ToString('o'); Ended = ((& $Machine.Now).ToString('o')); User = $User; SnapshotId = $SnapshotId
        WhatIf = [bool]$WhatIf; ImageVersion = $null; Reboot = [bool](@($results | Where-Object { $_.Reboot }).Count); Results = @($results)
    }
    if (-not $WhatIf) {
        $state = Get-AVDTuneState $Root
        $run.ImageVersion = $state.ImageVersion
        [void](Add-AVDTuneRun -Root $Root -Run $run)
        foreach ($r in @($results | Where-Object { $_.Status -eq 'Changed' })) {
            $step = $byId[$r.Id]
            if ($state.ImageVersion) {
                [void](Add-AVDTuneChangeLogEntry -Root $Root -Version $state.ImageVersion -Category $step.Section -Component $step.Id -ChangeType Changed -Text $step.Title -User $User -SnapshotId $SnapshotId -RunId $run.Id -Source Step)
            }
        }
    }
    $run
}

#endregion

#region change log

function Remove-AVDTuneControlCharacters([string]$Text, [int]$MaxLength) {
    # Free text of the change log: single line, no control characters, limited length. Secrets are cleaned by the caller (protocol cleaner).
    if (-not $Text) { return '' }
    $clean = [regex]::Replace($Text, '[\x00-\x1F\x7F]+', ' ').Trim()
    if ($clean.Length -gt $MaxLength) { $clean = $clean.Substring(0, $MaxLength - 3) + '...' }
    $clean
}

function Add-AVDTuneChangeLogEntry {
    <#
        One entry of the change log (Version, date, category, component, change type, text, user, snapshot, run).
        Source is Step (automatic) or Note (free note of the administrator).
    #>
    [CmdletBinding()]
    param(
        [string]$Root = (Get-AVDTuneRoot), [Parameter(Mandatory)][string]$Version, [Parameter(Mandatory)][string]$Category, [string]$Component,
        [Parameter(Mandatory)][string]$ChangeType, [Parameter(Mandatory)][string]$Text, [string]$User, [string]$SnapshotId, [string]$RunId,
        [ValidateSet('Step', 'Note')][string]$Source = 'Note', [datetime]$At = (Get-Date)
    )
    if (-not (Test-AVDTuneImageVersion $Version)) { throw "Invalid image version '$Version' (YYYY.MM.NNN)." }
    if ($ChangeType -notin $script:ChangeTypes) { throw "Unknown change type '$ChangeType' ($($script:ChangeTypes -join ', '))." }
    $path = Join-Path $Root 'changelog.json'
    $log = Read-AVDTuneJson $path
    if ($null -eq $log) { $log = [pscustomobject]@{ Schema = $script:StateSchema; Entries = @() } }
    $entry = [pscustomobject][ordered]@{
        Id = [guid]::NewGuid().ToString('N').Substring(0, 12); Version = $Version; At = $At.ToString('o')
        Category = (Remove-AVDTuneControlCharacters $Category 40); Component = (Remove-AVDTuneControlCharacters $Component 80); ChangeType = $ChangeType
        Text = (Remove-AVDTuneControlCharacters $Text 500); User = (Remove-AVDTuneControlCharacters $User 80); SnapshotId = (Remove-AVDTuneControlCharacters $SnapshotId 300)
        RunId = (Remove-AVDTuneControlCharacters $RunId 60); Source = $Source
    }
    $log.Entries = @(@($log.Entries) | Where-Object { $_ }) + $entry
    Write-AVDTuneFile $path ($log | ConvertTo-Json -Depth 6)
    $entry
}

function Get-AVDTuneChangeLog {
    param([string]$Root = (Get-AVDTuneRoot), [string]$Version)
    $log = Read-AVDTuneJson (Join-Path $Root 'changelog.json')
    if ($null -eq $log) { return @() }
    $entries = @(@($log.Entries) | Where-Object { $_ })
    if ($Version) { $entries = @($entries | Where-Object { $_.Version -eq $Version }) }
    @($entries | Sort-Object { [datetime]$_.At })
}

function Get-AVDTuneChangeLogVersions {
    # Versions that have entries or were started, newest first
    param([string]$Root = (Get-AVDTuneRoot))
    $names = @(@(Get-AVDTuneChangeLog -Root $Root) | ForEach-Object { [string]$_.Version })
    $state = Get-AVDTuneState $Root
    $names += @(@($state.Versions) | Where-Object { $_ } | ForEach-Object { [string]$_.Version })
    if ($state.ImageVersion) { $names += [string]$state.ImageVersion }
    @($names | Where-Object { $_ } | Sort-Object -Unique -Descending)
}

function ConvertTo-AVDTuneHtmlText([string]$Text) { [Net.WebUtility]::HtmlEncode($Text) }

function ConvertTo-AVDTuneChangeLogDocument {
    # The change log of one version as Markdown or as a self-contained HTML page (all text encoded)
    param([string]$Root = (Get-AVDTuneRoot), [Parameter(Mandatory)][string]$Version, [ValidateSet('Markdown', 'Html')][string]$Format = 'Markdown', [string]$ImageName)
    $entries = @(Get-AVDTuneChangeLog -Root $Root -Version $Version)
    $title = if ($ImageName) { "Change log $ImageName $Version" } else { "Change log $Version" }
    $header = 'Date', 'Category', 'Component', 'Change', 'Text', 'User'
    $rows = @($entries | ForEach-Object {
            , @(([datetime]$_.At).ToString('yyyy-MM-dd HH:mm'), [string]$_.Category, [string]$_.Component, [string]$_.ChangeType, [string]$_.Text, [string]$_.User)
        })
    if ($Format -eq 'Markdown') {
        $out = New-Object System.Collections.Generic.List[string]
        $out.Add("# $title"); $out.Add('')
        if ($rows.Count -eq 0) { $out.Add('No entries.') }
        else {
            $out.Add('| ' + ($header -join ' | ') + ' |'); $out.Add('|' + (('---|') * $header.Count))
            foreach ($row in $rows) { $out.Add('| ' + (@($row | ForEach-Object { ([string]$_).Replace('|', '\|') }) -join ' | ') + ' |') }
        }
        return (($out -join "`r`n") + "`r`n")
    }
    $html = New-Object System.Text.StringBuilder
    [void]$html.AppendLine('<!DOCTYPE html>')
    [void]$html.AppendLine('<html lang="en"><head><meta charset="utf-8"><title>' + (ConvertTo-AVDTuneHtmlText $title) + '</title>')
    [void]$html.AppendLine('<style>body{font-family:"Segoe UI",sans-serif;margin:32px;color:#1b1b1b}table{border-collapse:collapse;width:100%}th,td{border-bottom:1px solid #e5e5e5;padding:8px 10px;text-align:left;vertical-align:top}th{background:#f3f3f3}</style></head><body>')
    [void]$html.AppendLine('<h1>' + (ConvertTo-AVDTuneHtmlText $title) + '</h1>')
    if ($rows.Count -eq 0) { [void]$html.AppendLine('<p>No entries.</p>') }
    else {
        [void]$html.AppendLine('<table><thead><tr>' + (@($header | ForEach-Object { '<th>' + (ConvertTo-AVDTuneHtmlText $_) + '</th>' }) -join '') + '</tr></thead><tbody>')
        foreach ($row in $rows) { [void]$html.AppendLine('<tr>' + (@($row | ForEach-Object { '<td>' + (ConvertTo-AVDTuneHtmlText ([string]$_)) + '</td>' }) -join '') + '</tr>') }
        [void]$html.AppendLine('</tbody></table>')
    }
    [void]$html.AppendLine('</body></html>')
    $html.ToString()
}

function Export-AVDTuneChangeLog {
    # Writes the document (UTF-8 with BOM, opens in every editor) and returns the path
    param([string]$Root = (Get-AVDTuneRoot), [Parameter(Mandatory)][string]$Version, [Parameter(Mandatory)][string]$Path, [ValidateSet('Markdown', 'Html')][string]$Format, [string]$ImageName)
    if (-not $Format) { $Format = if ($Path -match '\.html?$') { 'Html' } else { 'Markdown' } }
    $text = ConvertTo-AVDTuneChangeLogDocument -Root $Root -Version $Version -Format $Format -ImageName $ImageName
    $folder = Split-Path $Path -Parent
    if ($folder -and -not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
    [IO.File]::WriteAllText($Path, $text, (New-Object Text.UTF8Encoding $true))
    $Path
}

#endregion

#region overview

$script:OfficeChannels = @{
    '492350f6-3a01-4f97-b9c0-c7c6ddf67d60' = 'Current Channel'
    '64256afe-f5d9-4f86-8936-8840a6a4f5be' = 'Current Channel (Preview)'
    '55336b82-a18d-4dd6-b5f6-9e5095c314a6' = 'Monthly Enterprise Channel'
    '7ffbc6bf-bc32-4f92-8982-f9dd17fd3114' = 'Semi-Annual Enterprise Channel'
    'b8f9b850-328d-4355-9145-c59439a0c4cf' = 'Beta Channel'
}

function Get-AVDTuneWindowsInfo {
    param([Parameter(Mandatory)]$Machine)
    $key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $build = [string](& $Machine.RegGet $key 'CurrentBuildNumber')
    $ubr = & $Machine.RegGet $key 'UBR'
    $edition = [string](& $Machine.RegGet $key 'EditionID')
    $display = [string](& $Machine.RegGet $key 'DisplayVersion')
    $product = [string](& $Machine.RegGet $key 'ProductName')
    # ProductName still says "Windows 10" on Windows 11: the build number decides
    $family = 'Windows'
    if ($build -match '^\d+$') { $family = if ([int]$build -ge 22000) { 'Windows 11' } else { 'Windows 10' } }
    $kind = switch ($edition) { 'ServerRdsh' { 'Enterprise multi-session' } 'Enterprise' { 'Enterprise' } 'Professional' { 'Pro' } default { $edition } }
    $name = (@($family, $kind) | Where-Object { $_ }) -join ' '
    if (-not $name) { $name = $product }
    [pscustomobject]@{
        Name = $name; Edition = $edition; DisplayVersion = $display; Build = $build; Ubr = $(if ($null -ne $ubr) { [string]$ubr } else { '' })
        FullBuild = $(if ($build) { if ($null -ne $ubr) { "$build.$ubr" } else { $build } } else { '' })
        MultiSession = ($edition -eq 'ServerRdsh')
    }
}

function Get-AVDTuneOfficeInfo {
    param([Parameter(Mandatory)]$Machine)
    $key = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'
    $version = & $Machine.RegGet $key 'VersionToReport'
    if (-not $version) { return [pscustomobject]@{ Installed = $false; Build = ''; Channel = ''; Platform = ''; SharedLicensing = $false; UpdatesEnabled = $null } }
    $cdn = [string](& $Machine.RegGet $key 'CDNBaseUrl')
    $channel = ''
    if ($cdn -match '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\s*$') { $channel = $script:OfficeChannels[$Matches[1].ToLowerInvariant()] }
    if (-not $channel) { $channel = 'unknown channel' }
    $updates = & $Machine.RegGet $key 'UpdatesEnabled'
    [pscustomobject]@{
        Installed = $true; Build = [string]$version; Channel = $channel; Platform = [string](& $Machine.RegGet $key 'Platform')
        SharedLicensing = ([string](& $Machine.RegGet $key 'SharedComputerLicensing') -eq '1'); UpdatesEnabled = $(if ($null -ne $updates) { ([string]$updates).ToUpperInvariant() -eq 'TRUE' } else { $null })
    }
}

function Get-AVDTuneSourceImage {
    <#
        The image this master was created from, read from the instance metadata (Azure only). A marketplace image shows
        publisher:offer:sku:version, a gallery or managed image its resource name.
    #>
    param([Parameter(Mandatory)]$Machine)
    $imds = & $Machine.Imds
    if (-not $imds -or -not (Get-AVDTuneProp $imds 'compute')) { return [pscustomobject]@{ Available = $false; Text = ''; VmName = ''; ResourceGroup = ''; Location = ''; VmSize = ''; OsDisk = '' } }
    $c = $imds.compute
    $profile = Get-AVDTuneProp $c 'storageProfile'
    $ref = Get-AVDTuneProp $profile 'imageReference'
    $text = ''
    if ($ref) {
        if ((Get-AVDTuneProp $ref 'publisher') -and (Get-AVDTuneProp $ref 'offer')) { $text = '{0}:{1}:{2}:{3}' -f $ref.publisher, $ref.offer, (Get-AVDTuneProp $ref 'sku'), (Get-AVDTuneProp $ref 'version') }
        elseif (Get-AVDTuneProp $ref 'id') { $text = [string]$ref.id; $parts = $text.TrimEnd('/') -split '/'; if ($parts.Count -ge 2) { $text = $parts[-1] } }
    }
    $disk = [string](Get-AVDTuneProp (Get-AVDTuneProp $profile 'osDisk') 'name')
    [pscustomobject]@{
        Available = $true; Text = $text; VmName = [string](Get-AVDTuneProp $c 'name'); ResourceGroup = [string](Get-AVDTuneProp $c 'resourceGroupName')
        Location = [string](Get-AVDTuneProp $c 'location'); VmSize = [string](Get-AVDTuneProp $c 'vmSize'); OsDisk = $disk
    }
}

function Get-AVDTuneHealth {
    <#
        Health checks of the Overview. Status: ok, warn, bad, info. "Must not be" items (AVD agent, join) are bad when present:
        a master with an agent or a join cannot be sealed.
    #>
    param([Parameter(Mandatory)]$Machine, [Parameter(Mandatory)]$State, $UpdateBlock)
    $rows = New-Object System.Collections.ArrayList
    function Add-Health($Id, $Title, $Status, $Detail) { [void]$rows.Add([pscustomobject]@{ Id = $Id; Title = $Title; Status = $Status; Detail = $Detail }) }

    $pending = New-Object System.Collections.ArrayList
    if (& $Machine.RegKeyExists 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { [void]$pending.Add('servicing') }
    if (& $Machine.RegKeyExists 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { [void]$pending.Add('Windows Update') }
    $rename = & $Machine.RegGet 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' 'PendingFileRenameOperations'
    if ($rename -and @($rename).Count -gt 0) { [void]$pending.Add('file operations') }
    if ($pending.Count -gt 0) { Add-Health 'reboot' 'Restart pending' 'warn' ('Waiting for a restart: ' + ($pending -join ', ') + '.') } else { Add-Health 'reboot' 'Restart pending' 'ok' 'No restart is waiting.' }

    # UpdateBlock is the live status of Get-AVDTuneUpdateBlockStatus (AVDTune.UpdateBlock.psm1) when the caller has it, else only what the state remembers
    $maint = Get-AVDTuneProp $State 'Maintenance'
    if ($maint -and (Get-AVDTuneProp $maint 'Active')) {
        Add-Health 'updateblock' 'Update block for users' 'bad' 'Maintenance mode was interrupted: the update block is lifted or only partly back. Repair it on the Update block page.'
    }
    elseif ($UpdateBlock) {
        $expected = [string]$State.UpdateBlock
        if ($UpdateBlock.State -eq 'On') { Add-Health 'updateblock' 'Update block for users' 'ok' ('On: ' + $UpdateBlock.Compliant + ' of ' + $UpdateBlock.Applicable + ' settings are in place, users see and run no updates.') }
        elseif ($expected -eq 'On') { Add-Health 'updateblock' 'Update block for users' 'bad' ('Changed from outside: only ' + $UpdateBlock.Compliant + ' of ' + $UpdateBlock.Applicable + ' settings are in place (' + $UpdateBlock.Missing + '). Switch the block on again.') }
        elseif ($UpdateBlock.State -eq 'Partial') { Add-Health 'updateblock' 'Update block for users' 'warn' ('Partly on: ' + $UpdateBlock.Compliant + ' of ' + $UpdateBlock.Applicable + ' settings. Switch the block on before seal.') }
        else { Add-Health 'updateblock' 'Update block for users' 'warn' 'Off: users can see and run updates. Switch the block on before seal.' }
    }
    else {
        switch ([string]$State.UpdateBlock) {
            'On' { Add-Health 'updateblock' 'Update block for users' 'ok' 'On: users see and run no updates (maintenance mode off).' }
            'Off' { Add-Health 'updateblock' 'Update block for users' 'warn' 'Off: maintenance mode, updates are possible. Switch the block on before seal.' }
            default { Add-Health 'updateblock' 'Update block for users' 'info' 'Not set up yet.' }
        }
    }
    if ($State.Sealed) { Add-Health 'sealed' 'Seal' 'info' 'Sealed: the master is ready for capture.' } else { Add-Health 'sealed' 'Seal' 'info' 'Not sealed.' }

    $agent = @('RDAgentBootLoader', 'RDAgent' | Where-Object { & $Machine.ServiceGet $_ })
    $agentKey = & $Machine.RegKeyExists 'HKLM:\SOFTWARE\Microsoft\RDInfraAgent'
    if ($agent.Count -gt 0 -or $agentKey) { Add-Health 'avdagent' 'AVD agent' 'bad' 'The AVD agent is installed. It must not be on the master: the host pool installs it on the session hosts.' }
    else { Add-Health 'avdagent' 'AVD agent' 'ok' 'Not installed (as it should be on a master).' }

    $dsreg = $null
    try { $dsreg = & $Machine.Run 'dsregcmd.exe' @('/status') } catch { }
    if ($dsreg -and $dsreg.ExitCode -eq 0 -and $dsreg.Output) {
        $entra = $dsreg.Output -match '(?im)^\s*AzureAdJoined\s*:\s*YES'
        $domain = $dsreg.Output -match '(?im)^\s*DomainJoined\s*:\s*YES'
        $joined = @(); if ($entra) { $joined += 'Microsoft Entra ID' }; if ($domain) { $joined += 'a domain' }
        if ($joined.Count -gt 0) { Add-Health 'join' 'Join' 'bad' ('Joined to ' + ($joined -join ' and ') + '. A master must not be joined (sysprep).') }
        else { Add-Health 'join' 'Join' 'ok' 'Not joined to a domain or Microsoft Entra ID.' }
    }
    else { Add-Health 'join' 'Join' 'warn' 'The join state could not be read (dsregcmd).' }
    @($rows)
}

function Get-AVDTuneOverview {
    # Everything the Overview page shows, from the machine adapter and the state
    param([Parameter(Mandatory)]$Machine, [string]$Root = (Get-AVDTuneRoot), $UpdateBlock)
    $state = Get-AVDTuneState $Root
    $source = Get-AVDTuneSourceImage $Machine
    [pscustomobject]@{
        ComputerName = [string](& $Machine.ComputerName)
        ImageVersion = $(if ($state.ImageVersion) { [string]$state.ImageVersion } else { '' })
        SourceImage = $source
        Windows = Get-AVDTuneWindowsInfo $Machine
        Office = Get-AVDTuneOfficeInfo $Machine
        LastUpdate = $(if ($state.LastUpdate) { [string]$state.LastUpdate } else { '' })
        LastBenchmark = $(if ($state.LastBenchmark) { [string]$state.LastBenchmark } else { '' })
        Health = @(Get-AVDTuneHealth $Machine $state $UpdateBlock)
        UpdateBlock = $(if ($UpdateBlock) { [string]$UpdateBlock.State } else { [string]$state.UpdateBlock })
        Sealed = [bool]$state.Sealed
    }
}

#endregion

Export-ModuleMember -Function Get-AVDTuneProp, Test-AVDTuneElevated, Get-AVDTuneRoot, Test-AVDTuneDefaultRoot, ConvertTo-AVDTuneArgument, New-AVDTuneMachine, Invoke-AVDTuneMachine,
    New-AVDTuneStateSecurity, Initialize-AVDTuneState, Get-AVDTuneState, Set-AVDTuneState, Test-AVDTuneImageVersion, Get-AVDTuneNextImageVersion, Start-AVDTuneImageVersion,
    Add-AVDTuneRun, Get-AVDTuneRun, New-AVDTuneStep, Invoke-AVDTuneStep, New-AVDTuneStepFromData, Get-AVDTuneStepCatalog, Invoke-AVDTune,
    Add-AVDTuneChangeLogEntry, Get-AVDTuneChangeLog, Get-AVDTuneChangeLogVersions, ConvertTo-AVDTuneChangeLogDocument, Export-AVDTuneChangeLog,
    Get-AVDTuneWindowsInfo, Get-AVDTuneOfficeInfo, Get-AVDTuneSourceImage, Get-AVDTuneHealth, Get-AVDTuneOverview, Write-AVDTuneFile, Read-AVDTuneJson,
    Open-AVDTuneWriteGate, Close-AVDTuneWriteGate, Get-AVDTuneWriteGate, Test-AVDTuneWriteAllowed, Remove-AVDTuneControlCharacters, ConvertTo-AVDTuneTestResult
