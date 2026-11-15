<#
    AVDTune optimization list (docs\plans\avdtune.md, section 5d): a selectable list of optimizations for a Windows 11 multi-session master, based on the
    configuration data of the Windows Desktop Optimization Tool (WDOT, MIT) and the Defender VDI preset of Microsoft Learn.

    The data is our own: data\optimization.json (declarative entries, each with reason, source, risk and default). WDOT is never downloaded or run, no WDOT code is
    used. The file is data, never code: Read-AVDTuneOptimizationData checks every type and every value against a fixed schema and refuses the whole file on any error.

    Kinds (the only things an entry can do):
      Registry        HKLM value (DWord or String). Undo restores the value that was there before (or removes it).
      ServiceStartup  start type of a service (Disabled or Manual). Undo restores the earlier start type.
      TaskDisabled    scheduled task disabled. Undo enables it again.
      AppxRemove      AppX package removed for all users and from the provisioning list. CANNOT be undone; needs -ConfirmIrreversible.
      DefenderPref    Microsoft Defender preference (Set-MpPreference, names on a fixed list). Undo restores the earlier value.

    Every change goes through Invoke-AVDTuneStep (write gate, Test before and after). The value found before Apply is saved in config\optimization-backup.json of the
    state folder (only when there is no backup for the entry yet, an older backup is never overwritten) and used by Undo; without a backup there is no undo, so nothing
    that AVDTune did not set is ever turned back. Run record, change log entry per change and LastChange (snapshot gate) are written for Apply and Undo alike.
    All access to the machine goes through the machine adapter (Tests\Fakes\FakeMachine.ps1 plus Tests\Fakes\FakeOptimization.ps1 for the checks).
#>

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'AVDTune.psm1')

$script:DataFile = Join-Path (Split-Path $PSScriptRoot -Parent) 'data\optimization.json'
$script:MaxDataBytes = 2MB
$script:MaxEntries = 1000
$script:CategoryKind = @{ Service = 'ServiceStartup'; Task = 'TaskDisabled'; Appx = 'AppxRemove'; Registry = 'Registry'; Autologger = 'Registry'; Defender = 'DefenderPref' }
$script:CategoryOrder = @('Defender', 'Registry', 'Autologger', 'Service', 'Task', 'Appx')
$script:CategoryLabel = @{ Defender = 'Defender for VDI'; Registry = 'Registry policies'; Autologger = 'Autologgers'; Service = 'Services'; Task = 'Scheduled tasks'; Appx = 'AppX removal (cannot be undone)' }
$script:Risks = @('Low', 'Medium', 'High')
$script:SourceHosts = @('learn.microsoft.com', 'github.com', 'chromeenterprise.google')
$script:CommonProps = @('Id', 'Category', 'Kind', 'Title', 'Why', 'Source', 'Origin', 'Risk', 'Default', 'Reboot', 'Irreversible')
$script:KindProps = @{
    Registry = @('Path', 'Name', 'Type', 'Value', 'OnlyIfKeyExists'); ServiceStartup = @('Name', 'Startup'); TaskDisabled = @('TaskPath', 'TaskName')
    AppxRemove = @('PackageName'); DefenderPref = @('Parameter', 'Value')
}
# Set-MpPreference parameters an entry may use, with the type and the values that are allowed (the name is data, so only this list goes to the cmdlet)
$script:DefenderParams = @{
    PUAProtection = @{ Type = 'int'; Allowed = @(0, 1, 2) }; DisableLocalAdminMerge = @{ Type = 'bool' }; RandomizeScheduleTaskTimes = @{ Type = 'bool' }
    MAPSReporting = @{ Type = 'int'; Allowed = @(0, 1, 2) }; CloudBlockLevel = @{ Type = 'int'; Allowed = @(0, 2, 4, 6) }; CloudExtendedTimeout = @{ Type = 'int'; Min = 0; Max = 50 }
    ScanAvgCPULoadFactor = @{ Type = 'int'; Min = 5; Max = 100 }; SignatureUpdateInterval = @{ Type = 'int'; Min = 0; Max = 24 }; DisableCatchupQuickScan = @{ Type = 'bool' }
    CheckForSignaturesBeforeRunningScan = @{ Type = 'bool' }; UILockdown = @{ Type = 'bool' }
    LowThreatDefaultAction = @{ Type = 'int'; Allowed = @(1, 2, 3, 6, 8, 9, 10) }; ModerateThreatDefaultAction = @{ Type = 'int'; Allowed = @(1, 2, 3, 6, 8, 9, 10) }
    HighThreatDefaultAction = @{ Type = 'int'; Allowed = @(1, 2, 3, 6, 8, 9, 10) }; SevereThreatDefaultAction = @{ Type = 'int'; Allowed = @(1, 2, 3, 6, 8, 9, 10) }
}
$script:RegexCache = @{}

#region data: read and check

function Get-AVDTuneOptimizationDataPath { $script:DataFile }

function Test-OptPattern([string]$Text, [string]$Pattern) {
    # Every regular expression here has a timeout (checklist "Input and data"); a timeout counts as no match
    if (-not $script:RegexCache.ContainsKey($Pattern)) { $script:RegexCache[$Pattern] = New-Object System.Text.RegularExpressions.Regex($Pattern, [System.Text.RegularExpressions.RegexOptions]::CultureInvariant, [TimeSpan]::FromMilliseconds(250)) }
    try { $script:RegexCache[$Pattern].IsMatch($Text) } catch [System.Text.RegularExpressions.RegexMatchTimeoutException] { $false }
}
function Test-OptText($Value, [int]$Min, [int]$Max) {
    # a real string (not a number, not $null), length in range, no control characters
    ($Value -is [string]) -and $Value.Length -ge $Min -and $Value.Length -le $Max -and -not (Test-OptPattern $Value '[\x00-\x1F\x7F]')
}
function Test-OptInt($Value) { ($Value -is [int]) -or ($Value -is [long]) }
function Test-OptUrl($Value) {
    if (-not (Test-OptText $Value 12 300)) { return $false }
    if (Test-OptPattern $Value '\s') { return $false }
    $u = $null
    if (-not [uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$u)) { return $false }
    ($u.Scheme -eq 'https') -and -not $u.UserInfo -and ($u.Host -in $script:SourceHosts)
}
function Test-OptProps($Object, [string[]]$Allowed, [string[]]$Required) {
    # exactly these property names: no unknown ones, all required ones there
    $names = @($Object.PSObject.Properties | ForEach-Object { $_.Name })
    $extra = @($names | Where-Object { $_ -cnotin $Allowed })
    $missing = @($Required | Where-Object { $_ -cnotin $names })
    @{ Extra = $extra; Missing = $missing }
}

function ConvertTo-OptEntry {
    # One entry of the file: returns @{ Entry; Errors }. The entry is a new, typed object (nothing of the parsed json is passed on as it was).
    param($Raw, [int]$Index, [hashtable]$SourceIds)
    $errors = New-Object System.Collections.ArrayList
    $label = "entry #$Index"
    if ($Raw -isnot [System.Management.Automation.PSCustomObject]) { return @{ Entry = $null; Errors = @("$label is not an object.") } }
    $id = Get-AVDTuneProp $Raw 'Id'
    if ((Test-OptText $id 3 80) -and (Test-OptPattern $id '^optimization\.[a-z0-9]+(-[a-z0-9]+)*$')) { $label = [string]$id } else { [void]$errors.Add("$label has no valid Id (optimization.lower-case-name).") }
    $kind = Get-AVDTuneProp $Raw 'Kind'; $cat = Get-AVDTuneProp $Raw 'Category'
    if (-not ((Test-OptText $kind 3 20) -and (@($script:KindProps.Keys) -ccontains [string]$kind))) { [void]$errors.Add("${label}: unknown Kind."); return @{ Entry = $null; Errors = @($errors) } }
    $allowed = @($script:CommonProps) + @($script:KindProps[[string]$kind])
    $required = @($script:CommonProps) + @($script:KindProps[[string]$kind] | Where-Object { $_ -ne 'OnlyIfKeyExists' })
    $p = Test-OptProps $Raw $allowed $required
    foreach ($x in $p.Extra) { [void]$errors.Add("${label}: unknown property '$x'.") }
    foreach ($x in $p.Missing) { [void]$errors.Add("${label}: property '$x' is missing.") }
    if ($p.Missing.Count -gt 0) { return @{ Entry = $null; Errors = @($errors) } }
    if (-not ((Test-OptText $cat 3 20) -and (@($script:CategoryKind.Keys) -ccontains [string]$cat) -and $script:CategoryKind[[string]$cat] -eq [string]$kind)) { [void]$errors.Add("${label}: Category '$cat' does not match Kind '$kind'.") }
    if (-not (Test-OptText (Get-AVDTuneProp $Raw 'Title') 3 120)) { [void]$errors.Add("${label}: Title must be text of 3 to 120 characters.") }
    if (-not (Test-OptText (Get-AVDTuneProp $Raw 'Why') 10 900)) { [void]$errors.Add("${label}: Why must be text of 10 to 900 characters.") }
    if (-not (Test-OptUrl (Get-AVDTuneProp $Raw 'Source'))) { [void]$errors.Add("${label}: Source must be an https URL on $($script:SourceHosts -join ', ').") }
    $origin = Get-AVDTuneProp $Raw 'Origin'
    if (-not ((Test-OptText $origin 2 40) -and $SourceIds.ContainsKey([string]$origin))) { [void]$errors.Add("${label}: Origin '$origin' is not one of the Sources.") }
    $risk = Get-AVDTuneProp $Raw 'Risk'
    if (-not ((Test-OptText $risk 3 10) -and ([string]$risk -cin $script:Risks))) { [void]$errors.Add("${label}: Risk must be Low, Medium or High.") }
    foreach ($b in 'Default', 'Reboot', 'Irreversible') { if ((Get-AVDTuneProp $Raw $b) -isnot [bool]) { [void]$errors.Add("${label}: $b must be true or false (a real boolean, not text).") } }
    # AppX removal is the one kind that cannot be undone, and only that kind says so
    if ((Get-AVDTuneProp $Raw 'Irreversible') -is [bool] -and ([bool](Get-AVDTuneProp $Raw 'Irreversible')) -ne ([string]$kind -eq 'AppxRemove')) { [void]$errors.Add("${label}: Irreversible must be true exactly for AppxRemove.") }
    $e = [ordered]@{ Id = [string]$id; Category = [string]$cat; Kind = [string]$kind; Title = [string](Get-AVDTuneProp $Raw 'Title'); Why = [string](Get-AVDTuneProp $Raw 'Why'); Source = [string](Get-AVDTuneProp $Raw 'Source')
        Origin = [string]$origin; Risk = [string]$risk; Default = [bool](Get-AVDTuneProp $Raw 'Default'); Reboot = [bool](Get-AVDTuneProp $Raw 'Reboot'); Irreversible = ([string]$kind -eq 'AppxRemove')
        Path = $null; Name = $null; Type = $null; Value = $null; OnlyIfKeyExists = $false; Startup = $null; TaskPath = $null; TaskName = $null; PackageName = $null; Parameter = $null }
    switch ([string]$kind) {
        'Registry' {
            $path = Get-AVDTuneProp $Raw 'Path'; $name = Get-AVDTuneProp $Raw 'Name'; $type = Get-AVDTuneProp $Raw 'Type'; $value = Get-AVDTuneProp $Raw 'Value'
            $okPath = (Test-OptText $path 8 260) -and (Test-OptPattern $path '^HKLM:\\[A-Za-z0-9 _.{}()\-]+(\\[A-Za-z0-9 _.{}()\-]+)*$') -and -not (@(([string]$path).Split('\')) -contains '..') -and -not (@(([string]$path).Split('\')) -contains '.')
            if (-not $okPath) { [void]$errors.Add("${label}: Path must be a key below HKLM:\ (letters, digits, space and _ . { } ( ) - only).") }
            if (-not ((Test-OptText $name 1 100) -and (Test-OptPattern $name '^[A-Za-z0-9 _.\-]+$'))) { [void]$errors.Add("${label}: Name is not a valid value name.") }
            if (-not ((Test-OptText $type 3 10) -and ([string]$type -cin @('DWord', 'String')))) { [void]$errors.Add("${label}: Type must be DWord or String.") }
            elseif ([string]$type -eq 'DWord' -and -not ((Test-OptInt $value) -and [int64]$value -ge 0 -and [int64]$value -le 2147483647)) { [void]$errors.Add("${label}: a DWord Value must be a whole number from 0 to 2147483647 (a number, not text).") }
            elseif ([string]$type -eq 'String' -and -not (Test-OptText $value 0 260)) { [void]$errors.Add("${label}: a String Value must be text of up to 260 characters.") }
            $only = Get-AVDTuneProp $Raw 'OnlyIfKeyExists'
            if ($null -ne $only -and $only -isnot [bool]) { [void]$errors.Add("${label}: OnlyIfKeyExists must be true or false.") }
            if ($cat -eq 'Autologger' -and $only -ne $true) { [void]$errors.Add("${label}: an autologger entry must say OnlyIfKeyExists true (no logger is created).") }
            $e.Path = [string]$path; $e.Name = [string]$name; $e.Type = [string]$type; $e.Value = $(if ([string]$type -eq 'DWord' -and (Test-OptInt $value)) { [int64]$value } else { [string]$value }); $e.OnlyIfKeyExists = [bool]($only -eq $true)
        }
        'ServiceStartup' {
            $name = Get-AVDTuneProp $Raw 'Name'; $startup = Get-AVDTuneProp $Raw 'Startup'
            if (-not ((Test-OptText $name 1 80) -and (Test-OptPattern $name '^[A-Za-z0-9_.\-]+$'))) { [void]$errors.Add("${label}: Name is not a valid service name.") }
            if (-not ((Test-OptText $startup 5 10) -and ([string]$startup -cin @('Disabled', 'Manual')))) { [void]$errors.Add("${label}: Startup must be Disabled or Manual.") }
            $e.Name = [string]$name; $e.Startup = [string]$startup
        }
        'TaskDisabled' {
            $tp = Get-AVDTuneProp $Raw 'TaskPath'; $tn = Get-AVDTuneProp $Raw 'TaskName'
            if (-not ((Test-OptText $tp 2 200) -and (Test-OptPattern $tp '^\\([A-Za-z0-9 _.\-]+\\)+$') -and -not (@(([string]$tp).Split('\')) -contains '..'))) { [void]$errors.Add("${label}: TaskPath must start and end with a backslash (letters, digits, space, _ . - only).") }
            if (-not ((Test-OptText $tn 1 100) -and (Test-OptPattern $tn '^[A-Za-z0-9 _.\-]+$') -and $tn -ne '.' -and $tn -ne '..')) { [void]$errors.Add("${label}: TaskName is not valid (no wildcards, no path).") }
            $e.TaskPath = [string]$tp; $e.TaskName = [string]$tn
        }
        'AppxRemove' {
            $pk = Get-AVDTuneProp $Raw 'PackageName'
            if (-not ((Test-OptText $pk 3 100) -and (Test-OptPattern $pk '^[A-Za-z0-9._\-]+$'))) { [void]$errors.Add("${label}: PackageName is not a valid package name (no wildcards).") }
            $e.PackageName = [string]$pk
        }
        'DefenderPref' {
            $param = Get-AVDTuneProp $Raw 'Parameter'; $value = Get-AVDTuneProp $Raw 'Value'
            if (-not ((Test-OptText $param 3 60) -and (@($script:DefenderParams.Keys) -ccontains [string]$param))) { [void]$errors.Add("${label}: Parameter is not on the list of allowed Defender settings.") }
            else {
                $d = $script:DefenderParams[[string]$param]
                if ($d.Type -eq 'bool') { if ($value -isnot [bool]) { [void]$errors.Add("${label}: Value of $param must be true or false (a real boolean).") } }
                elseif (-not (Test-OptInt $value)) { [void]$errors.Add("${label}: Value of $param must be a whole number.") }
                elseif ($d.ContainsKey('Allowed') -and ([int64]$value -notin $d.Allowed)) { [void]$errors.Add("${label}: Value of $param must be one of $($d.Allowed -join ', ').") }
                elseif ($d.ContainsKey('Min') -and ([int64]$value -lt $d.Min -or [int64]$value -gt $d.Max)) { [void]$errors.Add("${label}: Value of $param must be from $($d.Min) to $($d.Max).") }
            }
            $e.Parameter = [string]$param; $e.Value = $(if ($value -is [bool]) { $value } elseif (Test-OptInt $value) { [int64]$value } else { $null })
        }
    }
    @{ Entry = [pscustomobject]$e; Errors = @($errors) }
}

function Read-AVDTuneOptimizationData {
    <#
        Reads and checks the data file. Returns Valid, Errors, Entries (typed objects of the entries that passed) and Sources. A file with any error is not Valid:
        nothing from it is applied (Get-AVDTuneOptimizationStatus and Invoke-AVDTuneOptimization refuse). Strings are never taken for booleans or numbers.
    #>
    param([string]$Path = $script:DataFile)
    $errors = New-Object System.Collections.ArrayList
    $result = { param($entries, $sources) [pscustomobject]@{ Valid = ($errors.Count -eq 0); Errors = @($errors); Entries = @($entries); Sources = @($sources); Path = $Path } }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { [void]$errors.Add("The optimization data file is missing: $Path"); return (& $result @() @()) }
    if ((Get-Item -LiteralPath $Path).Length -gt $script:MaxDataBytes) { [void]$errors.Add('The optimization data file is larger than 2 MB.'); return (& $result @() @()) }
    $doc = $null
    try { $doc = ([IO.File]::ReadAllText($Path).TrimStart([char]0xFEFF)) | ConvertFrom-Json } catch { [void]$errors.Add("The optimization data file is not valid JSON: $($_.Exception.Message)"); return (& $result @() @()) }
    if ($doc -isnot [System.Management.Automation.PSCustomObject]) { [void]$errors.Add('The optimization data file must contain one object.'); return (& $result @() @()) }
    $p = Test-OptProps $doc @('SchemaVersion', 'Title', 'Updated', 'Sources', 'Entries') @('SchemaVersion', 'Sources', 'Entries')
    foreach ($x in $p.Extra) { [void]$errors.Add("Unknown top-level property '$x'.") }
    foreach ($x in $p.Missing) { [void]$errors.Add("Top-level property '$x' is missing.") }
    if ($p.Missing.Count -gt 0) { return (& $result @() @()) }
    if (-not ((Test-OptInt $doc.SchemaVersion) -and [int64]$doc.SchemaVersion -eq 1)) { [void]$errors.Add('SchemaVersion must be the number 1.') }
    $sources = New-Object System.Collections.ArrayList; $ids = @{}
    if ($doc.Sources -isnot [System.Array] -or @($doc.Sources).Count -lt 1) { [void]$errors.Add('Sources must be a list with at least one source.') }
    else {
        $i = 0
        foreach ($s in @($doc.Sources)) {
            $i++
            if ($s -isnot [System.Management.Automation.PSCustomObject]) { [void]$errors.Add("Source #$i is not an object."); continue }
            $sp = Test-OptProps $s @('Id', 'Name', 'Url', 'License', 'Copyright', 'Checked', 'Note') @('Id', 'Name', 'Url', 'License', 'Copyright', 'Checked')
            foreach ($x in $sp.Extra) { [void]$errors.Add("Source #${i}: unknown property '$x'.") }
            foreach ($x in $sp.Missing) { [void]$errors.Add("Source #${i}: property '$x' is missing.") }
            if ($sp.Missing.Count -gt 0) { continue }
            if (-not ((Test-OptText $s.Id 2 40) -and (Test-OptPattern $s.Id '^[a-z0-9-]+$'))) { [void]$errors.Add("Source #${i}: Id is not valid."); continue }
            if ($ids.ContainsKey([string]$s.Id)) { [void]$errors.Add("Source '$($s.Id)' is listed twice."); continue }
            foreach ($t in 'Name', 'License', 'Copyright', 'Checked') { if (-not (Test-OptText $s.$t 1 300)) { [void]$errors.Add("Source '$($s.Id)': $t must be text.") } }
            if (-not (Test-OptUrl $s.Url)) { [void]$errors.Add("Source '$($s.Id)': Url must be an https URL on an allowed host.") }
            $note = Get-AVDTuneProp $s 'Note'; if ($null -ne $note -and -not (Test-OptText $note 0 500)) { [void]$errors.Add("Source '$($s.Id)': Note must be text.") }
            $ids[[string]$s.Id] = $true
            [void]$sources.Add([pscustomobject]@{ Id = [string]$s.Id; Name = [string]$s.Name; Url = [string]$s.Url; License = [string]$s.License; Copyright = [string]$s.Copyright; Checked = [string]$s.Checked; Note = [string]$note })
        }
    }
    $entries = New-Object System.Collections.ArrayList; $seen = @{}
    if ($doc.Entries -isnot [System.Array] -or @($doc.Entries).Count -lt 1) { [void]$errors.Add('Entries must be a list with at least one entry.') }
    elseif (@($doc.Entries).Count -gt $script:MaxEntries) { [void]$errors.Add("Entries has more than $($script:MaxEntries) items.") }
    else {
        $i = 0
        foreach ($raw in @($doc.Entries)) {
            $i++
            $r = ConvertTo-OptEntry -Raw $raw -Index $i -SourceIds $ids
            foreach ($x in $r.Errors) { [void]$errors.Add($x) }
            if ($r.Entry) {
                if ($seen.ContainsKey($r.Entry.Id)) { [void]$errors.Add("Id '$($r.Entry.Id)' is used twice."); continue }
                $seen[$r.Entry.Id] = $true
                if ($r.Errors.Count -eq 0) { [void]$entries.Add($r.Entry) }
            }
        }
    }
    & $result $entries $sources
}

function Get-AVDTuneOptimizationPresetIds {
    <#
        recommended  = every entry that is switched on by default
        conservative = default entries with risk Low, without AppX removal (nothing irreversible)
        all          = every entry
    #>
    param([Parameter(Mandatory)][object[]]$Entries, [Parameter(Mandatory)][ValidateSet('recommended', 'conservative', 'all')][string]$Preset)
    switch ($Preset) {
        'recommended' { @($Entries | Where-Object { $_.Default } | ForEach-Object { $_.Id }) }
        'conservative' { @($Entries | Where-Object { $_.Default -and $_.Risk -eq 'Low' -and $_.Kind -ne 'AppxRemove' } | ForEach-Object { $_.Id }) }
        'all' { @($Entries | ForEach-Object { $_.Id }) }
    }
}

function Get-AVDTuneOptimizationCategoryLabel([string]$Category) { if ($script:CategoryLabel.ContainsKey($Category)) { $script:CategoryLabel[$Category] } else { $Category } }
function Get-AVDTuneOptimizationCategoryOrder { @($script:CategoryOrder) }

#endregion

#region backup (the value before Apply)

function Get-OptBackupPath([string]$Root) { Join-Path $Root 'config\optimization-backup.json' }
function Read-OptBackupFile([string]$Root) {
    # Id -> record. A file that cannot be read is an error (never replaced by an empty one: that would drop the older backups)
    $path = Get-OptBackupPath $Root
    $items = @{}
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $items }
    $doc = Read-AVDTuneJson $path
    if ($null -eq $doc) { return $items }
    $list = Get-AVDTuneProp $doc 'Items'
    if ($null -eq $list) { return $items }
    foreach ($prop in $list.PSObject.Properties) { $items[[string]$prop.Name] = $prop.Value }
    $items
}
function Save-AVDTuneOptimizationBackup {
    # Only when there is none for the entry: the first value found is the one that was there before AVDTune. Returns $true when written.
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][hashtable]$Record)
    $items = Read-OptBackupFile $Root
    if ($items.ContainsKey($Id)) { return $false }
    $items[$Id] = [pscustomobject]$Record
    $ordered = [ordered]@{}; foreach ($k in ($items.Keys | Sort-Object)) { $ordered[$k] = $items[$k] }
    Write-AVDTuneFile (Get-OptBackupPath $Root) ([ordered]@{ Schema = 1; Items = $ordered } | ConvertTo-Json -Depth 5)
    $true
}
function Get-AVDTuneOptimizationBackup {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Id)
    $items = Read-OptBackupFile $Root
    if ($items.ContainsKey($Id)) { $items[$Id] } else { $null }
}
function Remove-AVDTuneOptimizationBackup {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Id)
    $items = Read-OptBackupFile $Root
    if (-not $items.ContainsKey($Id)) { return }
    $items.Remove($Id)
    $ordered = [ordered]@{}; foreach ($k in ($items.Keys | Sort-Object)) { $ordered[$k] = $items[$k] }
    Write-AVDTuneFile (Get-OptBackupPath $Root) ([ordered]@{ Schema = 1; Items = $ordered } | ConvertTo-Json -Depth 5)
}
function ConvertTo-OptScalar($Value) {
    # A value read from the machine as something json can hold: bool stays, numbers become whole numbers, everything else text
    if ($null -eq $Value) { return $null }
    if ($Value -is [bool]) { return $Value }
    if ($Value -is [byte] -or $Value -is [int16] -or $Value -is [uint16] -or $Value -is [int] -or $Value -is [uint32] -or $Value -is [long]) { return [int64]$Value }
    [string]$Value
}
function ConvertTo-OptCompare($Value) {
    if ($null -eq $Value) { return $null }
    if ($Value -is [bool]) { return $(if ($Value) { 'true' } else { 'false' }) }
    ([string](ConvertTo-OptScalar $Value)).ToLowerInvariant()
}

#endregion

#region machine members and steps

function Add-AVDTuneOptimizationMachineMembers {
    <#
        The machine adapter has no AppX and Defender preference members of its own. This adds them to a real machine (checks add fakes:
        Tests\Fakes\FakeOptimization.ps1). A machine that is neither real nor has the members is refused. Names are checked again here before they reach a cmdlet.
    #>
    param([Parameter(Mandatory)]$Machine)
    $defenderNames = @($script:DefenderParams.Keys)
    $appx = @{ At = [datetime]::MinValue; Prov = @(); Inst = @() }
    $real = @{
        AppxState = {
            # The two package lists are read once and kept for 10 seconds (the status asks about dozens of packages; each call of the cmdlets takes seconds)
            param($Name)
            if ($Name -notmatch '^[A-Za-z0-9._-]{3,100}$') { throw 'Invalid package name.' }
            if (((Get-Date) - $appx.At).TotalSeconds -gt 10) {
                $appx.Prov = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop | ForEach-Object { [string]$_.DisplayName })
                $appx.Inst = @(Get-AppxPackage -AllUsers -ErrorAction Stop | ForEach-Object { [string]$_.Name })
                $appx.At = Get-Date
            }
            [pscustomobject]@{ Provisioned = ($appx.Prov -contains $Name); Installed = ($appx.Inst -contains $Name) }
        }.GetNewClosure()
        AppxRemove = {
            param($Name)
            if ($Name -notmatch '^[A-Za-z0-9._-]{3,100}$') { throw 'Invalid package name.' }
            try {
                foreach ($p in @(Get-AppxProvisionedPackage -Online -ErrorAction Stop | Where-Object { $_.DisplayName -eq $Name })) { [void](Remove-AppxProvisionedPackage -Online -PackageName $p.PackageName -ErrorAction Stop) }
                foreach ($p in @(Get-AppxPackage -AllUsers -Name $Name -ErrorAction Stop)) { Remove-AppxPackage -Package $p.PackageFullName -AllUsers -ErrorAction Stop }
            }
            finally { $appx.At = [datetime]::MinValue }
        }.GetNewClosure()
        MpGet = {
            param($Name)
            if ($Name -notin $defenderNames) { throw 'Defender setting is not on the list.' }
            $pref = Get-MpPreference -ErrorAction Stop
            $prop = $pref.PSObject.Properties[$Name]
            if ($prop) { $prop.Value } else { $null }
        }.GetNewClosure()
        MpSet = {
            param($Name, $Value)
            if ($Name -notin $defenderNames) { throw 'Defender setting is not on the list.' }
            $splat = @{ $Name = $Value }
            Set-MpPreference @splat -ErrorAction Stop
        }.GetNewClosure()
    }
    foreach ($name in 'AppxState', 'AppxRemove', 'MpGet', 'MpSet') {
        if ($null -ne $Machine.PSObject.Properties[$name]) { continue }
        if ($Machine.Kind -ne 'Real') { throw "The machine adapter has no member '$name'." }
        $Machine | Add-Member -NotePropertyName $name -NotePropertyValue $real[$name]
    }
    $Machine
}

function New-AVDTuneOptimizationStep {
    <#
        One entry as a step (Test/Apply/Undo for Invoke-AVDTuneStep) plus Present (is there anything to change on this machine). The scriptblocks only talk to the
        machine adapter and the backup file; nothing of the entry is evaluated as code.
    #>
    param([Parameter(Mandatory)]$Entry, [Parameter(Mandatory)][string]$Root)
    $id = $Entry.Id

    switch ($Entry.Kind) {
        'Registry' {
            $path = $Entry.Path; $name = $Entry.Name; $type = $Entry.Type; $want = $Entry.Value; $onlyKey = $Entry.OnlyIfKeyExists
            $present = { param($m) if ($onlyKey) { [bool](& $m.RegKeyExists $path) } else { $true } }.GetNewClosure()
            $test = { param($m) $v = & $m.RegGet $path $name; @{ Compliant = ($null -ne $v -and [string]$v -eq [string]$want); State = $(if ($null -eq $v) { 'not set' } else { [string]$v }) } }.GetNewClosure()
            $apply = {
                param($m)
                $v = & $m.RegGet $path $name
                [void](Save-AVDTuneOptimizationBackup -Root $Root -Id $id -Record @{ Kind = 'Registry'; Exists = ($null -ne $v); Value = (ConvertTo-OptScalar $v); At = (& $m.Now).ToString('o') })
                & $m.RegSet $path $name $want $type
            }.GetNewClosure()
            $undo = {
                param($m)
                $b = Get-AVDTuneOptimizationBackup -Root $Root -Id $id
                if ($null -eq $b) { throw 'There is no saved earlier value for this entry (AVDTune did not set it), so there is nothing to undo.' }
                if ((Get-AVDTuneProp $b 'Exists') -isnot [bool]) { throw 'The saved earlier value is damaged.' }
                if ($b.Exists) {
                    $old = Get-AVDTuneProp $b 'Value'
                    if ($type -eq 'DWord' -and -not (Test-OptInt $old)) { throw 'The saved earlier value is damaged (not a number).' }
                    if ($type -eq 'String' -and $old -isnot [string]) { throw 'The saved earlier value is damaged (not text).' }
                    & $m.RegSet $path $name $old $type
                }
                else { & $m.RegRemove $path $name }
            }.GetNewClosure()
        }
        'ServiceStartup' {
            $name = $Entry.Name; $startup = $Entry.Startup
            $present = { param($m) $null -ne (& $m.ServiceGet $name) }.GetNewClosure()
            $test = { param($m) $s = & $m.ServiceGet $name; if (-not $s) { @{ Compliant = $true; State = 'not present' } } else { @{ Compliant = ([string]$s.StartType -eq $startup); State = [string]$s.StartType } } }.GetNewClosure()
            $apply = {
                param($m)
                $s = & $m.ServiceGet $name
                [void](Save-AVDTuneOptimizationBackup -Root $Root -Id $id -Record @{ Kind = 'ServiceStartup'; StartType = [string]$s.StartType; At = (& $m.Now).ToString('o') })
                & $m.ServiceSetStartup $name $startup
            }.GetNewClosure()
            $undo = {
                param($m)
                $b = Get-AVDTuneOptimizationBackup -Root $Root -Id $id
                if ($null -eq $b) { throw 'There is no saved earlier value for this entry (AVDTune did not set it), so there is nothing to undo.' }
                $old = Get-AVDTuneProp $b 'StartType'
                if (-not ((Test-OptText $old 4 10) -and ([string]$old -cin @('Automatic', 'Manual', 'Disabled')))) { throw "The saved earlier start type '$old' cannot be restored (only Automatic, Manual or Disabled)." }
                & $m.ServiceSetStartup $name ([string]$old)
            }.GetNewClosure()
        }
        'TaskDisabled' {
            $tp = $Entry.TaskPath; $tn = $Entry.TaskName
            $present = { param($m) $null -ne (& $m.TaskGet $tp $tn) }.GetNewClosure()
            $test = { param($m) $t = & $m.TaskGet $tp $tn; if (-not $t) { @{ Compliant = $true; State = 'not present' } } else { @{ Compliant = (-not [bool]$t.Enabled); State = $(if ($t.Enabled) { 'enabled' } else { 'disabled' }) } } }.GetNewClosure()
            $apply = {
                param($m)
                $t = & $m.TaskGet $tp $tn
                [void](Save-AVDTuneOptimizationBackup -Root $Root -Id $id -Record @{ Kind = 'TaskDisabled'; Enabled = [bool]$t.Enabled; At = (& $m.Now).ToString('o') })
                & $m.TaskSetEnabled $tp $tn $false
            }.GetNewClosure()
            $undo = {
                param($m)
                $b = Get-AVDTuneOptimizationBackup -Root $Root -Id $id
                if ($null -eq $b) { throw 'There is no saved earlier value for this entry (AVDTune did not set it), so there is nothing to undo.' }
                if ((Get-AVDTuneProp $b 'Enabled') -isnot [bool]) { throw 'The saved earlier state is damaged.' }
                & $m.TaskSetEnabled $tp $tn ([bool]$b.Enabled)
            }.GetNewClosure()
        }
        'AppxRemove' {
            $pkg = $Entry.PackageName
            $present = { param($m) $true }
            $test = {
                param($m)
                $s = & $m.AppxState $pkg
                $parts = @(); if ($s.Installed) { $parts += 'installed' }; if ($s.Provisioned) { $parts += 'provisioned for new users' }
                @{ Compliant = (-not $s.Installed -and -not $s.Provisioned); State = $(if ($parts.Count -eq 0) { 'removed or not on this image' } else { $parts -join ', ' }) }
            }.GetNewClosure()
            $apply = { param($m) & $m.AppxRemove $pkg }.GetNewClosure()
            $undo = $null   # AppX removal cannot be undone
        }
        'DefenderPref' {
            $param = $Entry.Parameter; $want = $Entry.Value; $dp = $script:DefenderParams[$param]
            $present = { param($m) try { $null -ne (& $m.MpGet $param) } catch { $false } }.GetNewClosure()
            $test = { param($m) $v = & $m.MpGet $param; @{ Compliant = ($null -ne $v -and (ConvertTo-OptCompare $v) -eq (ConvertTo-OptCompare $want)); State = $(if ($null -eq $v) { 'not available' } else { [string](ConvertTo-OptCompare $v) }) } }.GetNewClosure()
            $apply = {
                param($m)
                $v = & $m.MpGet $param
                [void](Save-AVDTuneOptimizationBackup -Root $Root -Id $id -Record @{ Kind = 'DefenderPref'; Value = (ConvertTo-OptScalar $v); At = (& $m.Now).ToString('o') })
                & $m.MpSet $param $want
            }.GetNewClosure()
            $undo = {
                param($m)
                $b = Get-AVDTuneOptimizationBackup -Root $Root -Id $id
                if ($null -eq $b) { throw 'There is no saved earlier value for this entry (AVDTune did not set it), so there is nothing to undo.' }
                $old = Get-AVDTuneProp $b 'Value'

                if ($dp.Type -eq 'bool') { if ($old -isnot [bool]) { throw 'The saved earlier value is damaged (not true or false).' } }
                elseif (-not (Test-OptInt $old)) { throw 'The saved earlier value is damaged (not a number).' }
                & $m.MpSet $param $old
            }.GetNewClosure()
        }
        default { throw "Unknown kind '$($Entry.Kind)'." }
    }
    $step = New-AVDTuneStep -Id $id -Section Optimization -Title $Entry.Title -Why $Entry.Why -Risk $Entry.Risk -Reboot $Entry.Reboot -SourceUrl $Entry.Source -Test $test -Apply $apply -Undo $undo
    [pscustomobject]@{ Entry = $Entry; Step = $step; Present = $present }
}

#endregion

#region status and run

function Get-AVDTuneOptimizationStatus {
    <#
        Live state of every entry: Id, Category, Kind, Title, Why, Source, Origin, Risk, Default, Reboot, Irreversible, Present (is there anything on this machine),
        Compliant, State, HasBackup (an Undo is possible), Failed/Message when the state cannot be read. DataValid/DataErrors say whether the data file is usable.
        Reading only: nothing is written, the write gate is not needed.
    #>
    param([Parameter(Mandatory)]$Machine, [string]$Root = (Get-AVDTuneRoot), [string]$DataPath = $script:DataFile)
    $data = Read-AVDTuneOptimizationData -Path $DataPath
    $out = [pscustomobject]@{ DataValid = $data.Valid; DataErrors = @($data.Errors); Sources = @($data.Sources); Rows = @(); BackupError = $null }
    if (-not $data.Valid) { return $out }
    [void](Add-AVDTuneOptimizationMachineMembers -Machine $Machine)
    $backups = @{}
    try { $backups = Read-OptBackupFile $Root } catch { $out.BackupError = "The file of saved earlier values cannot be read: $($_.Exception.Message) Undo is not offered." }
    $rows = New-Object System.Collections.ArrayList
    foreach ($e in $data.Entries) {
        $s = New-AVDTuneOptimizationStep -Entry $e -Root $Root
        $present = $true; $compliant = $false; $state = ''; $failed = $false; $msg = ''
        try {
            $present = [bool](& $s.Present $Machine)
            if ($present) { $t = ConvertTo-AVDTuneTestResult (& $s.Step.Test $Machine); $compliant = [bool]$t.Compliant; $state = [string]$t.State } else { $state = 'not present on this machine' }
        }
        catch { $failed = $true; $msg = $_.Exception.Message; $state = 'cannot be read' }
        [void]$rows.Add([pscustomobject]@{
                Id = $e.Id; Category = $e.Category; Kind = $e.Kind; Title = $e.Title; Why = $e.Why; Source = $e.Source; Origin = $e.Origin; Risk = $e.Risk; Default = $e.Default; Reboot = $e.Reboot
                Irreversible = $e.Irreversible; Present = $present; Compliant = $compliant; State = $state; HasBackup = ($backups.ContainsKey($e.Id) -and -not $e.Irreversible); Failed = $failed; Message = $msg
            })
    }
    $out.Rows = @($rows)
    $out
}

function Invoke-AVDTuneOptimization {
    <#
        Applies or undoes the chosen entries (ids) on the machine. Needs the open write gate unless -WhatIf. Entries are independent: one that fails does not stop the others.
        Apply of an AppX removal needs -ConfirmIrreversible, else nothing at all is changed and an error is thrown (WhatIf is exempt: it changes nothing).
        Writes a run record, one change log entry per change (Apply and Undo) and LastChange (also after a failed attempt). Returns the summary with the results.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Machine, [string]$Root = (Get-AVDTuneRoot), [string]$DataPath = $script:DataFile, [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Ids,
        [ValidateSet('Apply', 'Undo')][string]$Mode = 'Apply', [switch]$ConfirmIrreversible, [string]$User, [string]$SnapshotId, [switch]$WhatIf
    )
    $data = Read-AVDTuneOptimizationData -Path $DataPath
    if (-not $data.Valid) { throw ('The optimization data is not valid, nothing is applied: ' + (@($data.Errors | Select-Object -First 3) -join ' ')) }
    if (-not $WhatIf -and -not (Test-AVDTuneWriteAllowed)) { throw 'The snapshot gate is not confirmed: AVDTune is read only until a snapshot newer than its last change is confirmed on the Overview.' }
    $byId = @{}; foreach ($e in $data.Entries) { $byId[$e.Id] = $e }
    $selected = @($Ids | Where-Object { $_ } | Select-Object -Unique)
    if ($selected.Count -eq 0) { throw 'No entry is selected.' }
    foreach ($id in $selected) { if (-not $byId.ContainsKey($id)) { throw "Unknown entry '$id'." } }
    [void](Add-AVDTuneOptimizationMachineMembers -Machine $Machine)
    $items = @($selected | ForEach-Object { New-AVDTuneOptimizationStep -Entry $byId[$_] -Root $Root })
    if ($Mode -eq 'Apply' -and -not $WhatIf -and -not $ConfirmIrreversible) {
        $pending = @($items | Where-Object { $_.Entry.Irreversible -and (& $_.Present $Machine) -and -not (ConvertTo-AVDTuneTestResult (& $_.Step.Test $Machine)).Compliant })
        if ($pending.Count -gt 0) { throw "$($pending.Count) AppX removal(s) cannot be undone and need their own confirmation (ConfirmIrreversible). Nothing was changed." }
    }
    $results = New-Object System.Collections.ArrayList
    foreach ($it in $items) {
        $step = $it.Step
        $present = $true; $presentError = $null
        try { $present = [bool](& $it.Present $Machine) } catch { $present = $false; $presentError = $_.Exception.Message }
        if (-not $present) {
            [void]$results.Add([pscustomobject]@{ Id = $step.Id; Section = $step.Section; Title = $step.Title; Mode = $Mode; Status = 'Skipped'; Before = $null; After = $null; Message = $(if ($presentError) { "Cannot be read: $presentError" } else { 'Not present on this machine.' }); Reboot = $false; WhatIf = [bool]$WhatIf; At = $null })
            continue
        }
        $hadBackup = $false; try { $hadBackup = ($null -ne (Get-AVDTuneOptimizationBackup -Root $Root -Id $step.Id)) } catch { }
        $r = Invoke-AVDTuneStep -Step $step -Machine $Machine -Mode $Mode -WhatIf:$WhatIf
        [void]$results.Add($r)
        if ($WhatIf) { continue }
        try {
            if ($Mode -eq 'Undo' -and $r.Status -eq 'Reverted') { Remove-AVDTuneOptimizationBackup -Root $Root -Id $step.Id }
            # an Apply that failed before it changed anything leaves no backup behind (the value is still what it was)
            elseif ($Mode -eq 'Apply' -and $r.Status -eq 'Failed' -and -not $hadBackup -and $r.Message -ne 'The test still fails after Apply.') { Remove-AVDTuneOptimizationBackup -Root $Root -Id $step.Id }
        }
        catch { $r.Message = (($r.Message + ' ' + "The file of saved values could not be updated: $($_.Exception.Message)").Trim()) }
    }
    $changed = @($results | Where-Object { $_.Status -in 'Changed', 'Reverted' })
    $failed = @($results | Where-Object { $_.Status -eq 'Failed' })
    $summary = [pscustomobject]@{
        Mode = $Mode; Changed = $changed.Count; Failed = $failed.Count; Skipped = @($results | Where-Object { $_.Status -eq 'Skipped' }).Count; NoUndo = @($results | Where-Object { $_.Status -eq 'NoUndo' }).Count
        Unchanged = @($results | Where-Object { $_.Status -eq 'Unchanged' }).Count; Reboot = [bool](@($results | Where-Object { $_.Reboot }).Count); Results = @($results); WhatIf = [bool]$WhatIf; RunId = $null
    }
    if ($WhatIf) { return $summary }
    $state = Get-AVDTuneState $Root
    $now = (& $Machine.Now)
    $run = [pscustomobject][ordered]@{
        Id = $null; Plan = "Optimization $($Mode.ToLowerInvariant())"; Started = $now.ToString('o'); Ended = $now.ToString('o'); User = $User; SnapshotId = $SnapshotId
        WhatIf = $false; ImageVersion = $state.ImageVersion; Reboot = $summary.Reboot; Results = @($results)
    }
    [void](Add-AVDTuneRun -Root $Root -Run $run)
    $summary.RunId = $run.Id
    # A failed attempt may have changed something half-way: it counts for the snapshot gate like a change
    if ($changed.Count -gt 0 -or $failed.Count -gt 0) { [void](Set-AVDTuneState -Root $Root -Values @{ LastChange = $now.ToString('o') }) }
    if ($state.ImageVersion) {
        foreach ($r in $changed) {
            $e = $byId[$r.Id]
            $type = if ($Mode -eq 'Undo') { 'Changed' } elseif ($e.Kind -eq 'AppxRemove') { 'Removed' } else { 'Changed' }
            $text = if ($Mode -eq 'Undo') { "Undone: $($e.Title)" } else { $e.Title }
            [void](Add-AVDTuneChangeLogEntry -Root $Root -Version $state.ImageVersion -Category 'Optimization' -Component $e.Id -ChangeType $type -Text $text -User $User -SnapshotId $SnapshotId -RunId $run.Id -Source Step)
        }
        foreach ($r in $failed) {
            $e = $byId[$r.Id]
            [void](Add-AVDTuneChangeLogEntry -Root $Root -Version $state.ImageVersion -Category 'Optimization' -Component $e.Id -ChangeType 'Note' -Text "Failed ($Mode): $($e.Title) - $($r.Message)" -User $User -SnapshotId $SnapshotId -RunId $run.Id -Source Step)
        }
    }
    $summary
}

#endregion

Export-ModuleMember -Function Get-AVDTuneOptimizationDataPath, Read-AVDTuneOptimizationData, Get-AVDTuneOptimizationPresetIds, Get-AVDTuneOptimizationCategoryLabel, Get-AVDTuneOptimizationCategoryOrder,
    Add-AVDTuneOptimizationMachineMembers, New-AVDTuneOptimizationStep, Get-AVDTuneOptimizationStatus, Invoke-AVDTuneOptimization,
    Get-AVDTuneOptimizationBackup, Save-AVDTuneOptimizationBackup, Remove-AVDTuneOptimizationBackup, ConvertTo-OptScalar, ConvertTo-OptCompare, Test-OptInt, Test-OptText
