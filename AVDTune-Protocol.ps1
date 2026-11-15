# AVDTune protocol: the shared PackTune protocol code (Shared\PackTune-Protocol.ps1, never edited here) with AVDTune's own groups and texts.
# Dot-source this file; set $script:WorkRoot (the state folder) first, protocols go to <WorkRoot>\Protocols.
# The shared functions read $script:ProtocolCategories and $script:ProtocolText at call time, so replacing them here changes the
# groups and wording without touching the copy. The field "Tenant" of the shared protocol holds the image (computer name and
# image version) and is labelled "Image".
. (Join-Path $PSScriptRoot 'Shared\PackTune-Protocol.ps1')

$script:ProtocolCategories = @('setup', 'update', 'software', 'optimization', 'fslogix', 'vdi', 'userexperience', 'updateblock', 'benchmark', 'seal', 'other')
$script:ProtocolText = @{
    en = @{
        title = 'AVDTune session protocol'; date = 'Date'; time = 'Time'; duration = 'Duration'; admin = 'Administrator'; tenant = 'Image'; actions = 'Actions'
        none = 'No actions in this session.'; unknown = 'unknown'; minutes = 'min'; hours = 'h'; seconds = 's'
        ok = 'done'; failed = 'failed'; skipped = 'skipped'; passed = 'passed'; testfailed = 'failed'
        setup = 'Setup'; update = 'Updates'; software = 'Software'; optimization = 'Optimization'; fslogix = 'FSLogix'; vdi = 'VDI components'
        userexperience = 'User experience'; updateblock = 'Update block for users'; benchmark = 'Benchmark'; seal = 'Cleanup and finish'; other = 'Other'
    }
    de = @{
        title = 'AVDTune-Sitzungsprotokoll'; date = 'Datum'; time = 'Zeit'; duration = 'Dauer'; admin = 'Administrator'; tenant = 'Image'; actions = 'Aktionen'
        none = 'Keine Aktionen in dieser Sitzung.'; unknown = 'unbekannt'; minutes = 'Min'; hours = 'Std'; seconds = 's'
        ok = 'erledigt'; failed = 'fehlgeschlagen'; skipped = '%uebersprungen'; passed = 'bestanden'; testfailed = 'nicht bestanden'
        setup = 'Einrichtung'; update = 'Updates'; software = 'Software'; optimization = 'Optimierung'; fslogix = 'FSLogix'; vdi = 'VDI-Komponenten'
        userexperience = 'Benutzererlebnis'; updateblock = 'Update-Sperre f%uer Benutzer'; benchmark = 'Benchmark'; seal = 'Aufr%aeumen und Abschliessen'; other = 'Sonstiges'
    }
}

# Step section (Modules\AVDTune.psm1) -> protocol group
$script:ProtocolSectionGroup = @{
    Setup = 'setup'; Updates = 'update'; Software = 'software'; Office = 'software'; Optimization = 'optimization'; FSLogix = 'fslogix'; AppMasking = 'fslogix'
    VdiComponents = 'vdi'; UserExperience = 'userexperience'; UpdateBlock = 'updateblock'; Benchmark = 'benchmark'; Seal = 'seal'
}

function Add-AVDTuneProtocolFromResult {
    <#
        The one hook of the window: a result of Invoke-AVDTuneStep (Id, Section, Title, Status, Message) becomes an action.
        Changed/Reverted = ok, Unchanged/Skipped/WhatIf/NoUndo = skipped (a dry run is marked in the note), Failed = failed.
        Test results (Compliant/NonCompliant) are reads and are not recorded. Returns the action or $null.
    #>
    param([Parameter(Mandatory = $true)]$Protocol, [Parameter(Mandatory = $true)]$Result)
    $Status = [string]$Result.Status
    if ($Status -in 'Compliant', 'NonCompliant') { return $null }
    $Group = $script:ProtocolSectionGroup[[string]$Result.Section]
    if (-not $Group) { $Group = 'other' }
    $Outcome = switch ($Status) { { $_ -in 'Changed', 'Reverted' } { 'ok' } 'Failed' { 'failed' } default { 'skipped' } }
    $Note = [string]$Result.Message
    if ($Status -eq 'WhatIf') { $Note = 'dry run' }
    elseif ($Status -eq 'Unchanged' -and -not $Note) { $Note = 'already as wanted' }
    $At = if ($Result.At) { [datetime]$Result.At } else { Get-Date }
    Add-PackTuneProtocolAction -Protocol $Protocol -Category $Group -Subject ([string]$Result.Title) -Result $Outcome -Note $Note -At $At
}

function Add-AVDTuneProtocolNote {
    # A manual entry (for example "image version started") in the group given
    param([Parameter(Mandatory = $true)]$Protocol, [string]$Group = 'other', [Parameter(Mandatory = $true)][string]$Subject, [string]$Note)
    if ($Group -notin $script:ProtocolCategories) { $Group = 'other' }
    Add-PackTuneProtocolAction -Protocol $Protocol -Category $Group -Subject $Subject -Result ok -Note $Note
}
