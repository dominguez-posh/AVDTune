<#
    AVDTune FSLogix side (docs\plans\avdtune.md, sections 5a and 5d; issue 10): install and update, profile settings, include and exclude groups,
    redirections.xml, Microsoft Defender exclusions, and the function test ("FSLogix-Test", part of the healthcheck).

      * Every access to the master goes through the machine adapter ($m, registry, services, native commands) and the FSLogix adapter ($F:
        download, zip, files, DNS, TCP, share, Defender, local groups). Tests\Fakes\FakeFSLogix.ps1 has the fake; New-AVDTuneFSLogixAdapter is the real one
        and is NOT exercised by the checks (no download, no change of this computer's Defender or groups, no share).
      * Changes are steps behind the write gate (snapshot confirmed), through Invoke-AVDTune: Test/Apply, run record, LastChange, change log entry.
        Undo is a second plan that puts back the values that were found before (kept in config\fslogix-undo.json).
      * Every value, every Defender entry and every test has a Learn source and a Verified flag (the Source/Verified fields). What Learn does not state is
        marked Verified=false with the reason; nothing is guessed silently.
      * The installer comes only from download.microsoft.com (https, the redirect of aka.ms/fslogix_download is resolved, never followed blindly), lands in a
        new folder below the protected state folder (Administrators and SYSTEM only), its Authenticode signature is checked exactly like every tool of
        AVDTune (Test-AVDTuneToolTrust: Microsoft Corporation, Microsoft code signing CA, original file name) directly before it starts.
#>

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'AVDTune.psm1')
Import-Module (Join-Path $PSScriptRoot 'AVDTune.Updates.psm1')
Import-Module (Join-Path $PSScriptRoot 'AVDTune.Trust.psm1')

$script:ProfilesKey = 'HKLM:\SOFTWARE\FSLogix\Profiles'
$script:OdfcKey = 'HKLM:\SOFTWARE\Policies\FSLogix\ODFC'
$script:AppsKey = 'HKLM:\SOFTWARE\FSLogix\Apps'
$script:Learn = 'https://learn.microsoft.com/en-us/fslogix'
$script:IncludeGroup = 'FSLogix Profile Include List'
$script:ExcludeGroup = 'FSLogix Profile Exclude List'
$script:AdminsSid = 'S-1-5-32-544'
$script:DownloadHost = 'download.microsoft.com'
$script:MaxDownloadBytes = 400MB

#region settings catalog

function New-FsSetting([string]$Name, [string]$Type, $Recommended, $Default, [string]$Explain, [bool]$Verified, [string]$Source, [string]$Note = '', $Min = $null, $Max = $null, [string]$Scope = 'Profile') {
    [pscustomobject]@{ Name = $Name; Type = $Type; Recommended = $Recommended; Default = $Default; Explain = $Explain; Verified = $Verified; Source = $Source; Note = $Note; Min = $Min; Max = $Max; Scope = $Scope }
}

function Get-AVDTuneFSLogixSettingCatalog {
    <#
        The profile container settings of the form (HKLM\SOFTWARE\FSLogix\Profiles) and the ODFC container (HKLM\SOFTWARE\Policies\FSLogix\ODFC).
        Recommended = what Microsoft recommends (Learn tutorial-configure-profile-containers, page date 2026-03-30); Verified=false where Learn states no
        recommendation (the value is the documented default and the note says so).
    #>
    $ref = "$script:Learn/reference-configuration-settings"
    $tut = "$script:Learn/tutorial-configure-profile-containers"
    @(
        (New-FsSetting 'Enabled' 'DWord' 1 0 'Turns the profile container on. Without it FSLogix does nothing.' $true $tut '' 0 1)
        (New-FsSetting 'VHDLocations' 'MultiString' $null $null 'The SMB share (UNC path) where the profile containers live, e.g. \\<account>.file.core.windows.net\<share>. Required. Not together with Cloud Cache (CCDLocations).' $true $ref 'No recommended value: it is your share.')
        (New-FsSetting 'VolumeType' 'String' 'vhdx' 'vhd' 'Container file type. VHDX is preferred over VHD because of its supported size and fewer corruption cases.' $true $tut)
        (New-FsSetting 'IsDynamic' 'DWord' 1 1 'Dynamic container: it only uses as much space on the share as the profile needs, up to SizeInMBs. 1 is the default.' $false $ref 'Learn gives the default (1) and no separate recommendation; AVDTune recommends the default.' 0 1)
        (New-FsSetting 'SizeInMBs' 'DWord' 30000 30000 'Maximum size of one container in MB. It can be raised later but never lowered; existing containers do not shrink.' $true $tut '' 100 1000000)
        (New-FsSetting 'DeleteLocalProfileWhenVHDShouldApply' 'DWord' 1 0 'Deletes an existing local profile when the user should get a container, so users do not keep working in a local profile and lose data. Careful: the local profile is deleted for good.' $true $tut '' 0 1)
        (New-FsSetting 'FlipFlopProfileDirectoryName' 'DWord' 1 0 'Names the folder <username>_<SID> instead of <SID>_<username>: easier to browse. Changing it on an existing environment makes users get new profiles.' $true $tut '' 0 1)
        (New-FsSetting 'LockedRetryCount' 'DWord' 3 12 'How often FSLogix retries when the container file is locked (open elsewhere). Fewer retries fail faster.' $true $tut '' 0 100)
        (New-FsSetting 'LockedRetryInterval' 'DWord' 15 5 'Seconds between the retries of a locked container.' $true $tut '' 1 600)
        (New-FsSetting 'ReAttachRetryCount' 'DWord' 3 60 'How often FSLogix tries to re-attach a container that disconnected unexpectedly.' $true $tut '' 0 1000)
        (New-FsSetting 'ReAttachIntervalSeconds' 'DWord' 15 10 'Seconds between the re-attach attempts.' $true $tut '' 1 600)
        (New-FsSetting 'PreventLoginWithFailure' 'DWord' 0 0 'When 1: a user whose container fails to attach gets a message to call support and can only sign out, instead of a temporary or local profile.' $false $ref 'Learn states the behavior and the default (0), no recommendation either way.' 0 1)
        (New-FsSetting 'PreventLoginWithTempProfile' 'DWord' 0 0 'When 1: a user who would get a temporary profile gets the same message and can only sign out.' $false $ref 'Learn states the behavior and the default (0), no recommendation either way.' 0 1)
        (New-FsSetting 'ProfileType' 'DWord' 0 0 'Normal profile behavior (0): one connection per container reduces complexity and increases performance. 1 to 3 are for concurrent use and need advance knowledge.' $true $tut '' 0 3)
        (New-FsSetting 'RedirXMLSourceFolder' 'String' $null $null 'Folder (not the file name) that holds redirections.xml. FSLogix copies the file from there into every profile at sign-in. Users need read access to it.' $true "$script:Learn/tutorial-redirections-xml" 'Set by the redirections.xml editor.')
        (New-FsSetting 'Enabled' 'DWord' 0 0 'Office container (ODFC). Learn recommends the single profile container, which already holds the Microsoft 365 data: leave this off unless you really run two containers.' $true "$script:Learn/tutorial-configure-profile-containers" '' 0 1 'ODFC')
        (New-FsSetting 'VHDLocations' 'MultiString' $null $null 'SMB location of the Office containers (only with ODFC on).' $true $ref '' $null $null 'ODFC')
        (New-FsSetting 'VolumeType' 'String' 'vhdx' 'vhd' 'File type of the Office containers.' $false $ref 'Learn recommends VHDX for the profile container; the ODFC page has no separate statement.' $null $null 'ODFC')
        (New-FsSetting 'IsDynamic' 'DWord' 1 1 'Dynamic Office containers.' $false $ref 'Default only.' 0 1 'ODFC')
        (New-FsSetting 'SizeInMBs' 'DWord' 30000 30000 'Maximum size of an Office container in MB.' $false $ref 'Default only.' 100 1000000 'ODFC')
    )
}

function Get-FsSettingKey($Setting) { if ($Setting.Scope -eq 'ODFC') { $script:OdfcKey } else { $script:ProfilesKey } }

function Test-AVDTuneFSLogixUncPath([string]$Path) {
    # \\host\share[\folder ...]: no file name check, no wildcard or control character, no trailing backslash or blank
    if (-not $Path) { return $false }
    $Path -match '^\\\\[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?\\[^\\/:*?"<>|\x00-\x1F\s][^\\/:*?"<>|\x00-\x1F]*(\\[^\\/:*?"<>|\x00-\x1F\s][^\\/:*?"<>|\x00-\x1F]*)*$' -and $Path -notmatch '\s$'
}

function Test-AVDTuneFSLogixValue {
    <# '' when the value is valid for the setting, else the reason. Value of a multi-string is an array. #>
    param([Parameter(Mandatory)]$Setting, $Value)
    switch ($Setting.Type) {
        'DWord' {
            if ($null -eq $Value -or [string]$Value -notmatch '^\d{1,10}$') { return "$($Setting.Name) must be a whole number." }
            $n = [int64]$Value
            if ($null -ne $Setting.Min -and $n -lt $Setting.Min) { return "$($Setting.Name) must be at least $($Setting.Min)." }
            if ($null -ne $Setting.Max -and $n -gt $Setting.Max) { return "$($Setting.Name) must be at most $($Setting.Max)." }
            ''
        }
        'MultiString' {
            $list = @(@($Value) | Where-Object { $_ })
            if ($list.Count -eq 0) { return "$($Setting.Name) needs at least one path." }
            foreach ($p in $list) { if (-not (Test-AVDTuneFSLogixUncPath ([string]$p))) { return "'$p' is not a UNC path like \\server\share (no trailing backslash, no blanks, no wildcards)." } }
            ''
        }
        default {
            $v = [string]$Value
            if ($Setting.Name -eq 'VolumeType') { if ($v -notin 'vhd', 'vhdx') { return 'VolumeType must be vhd or vhdx.' }; return '' }
            if ($Setting.Name -eq 'RedirXMLSourceFolder') {
                if ($v -match '\.xml$') { return 'Enter the folder only, not the file name.' }
                if (@($v -split '[\\/]') -contains '..') { return "The folder must not contain '..'." }
                if (-not ((Test-AVDTuneFSLogixUncPath $v) -or $v -match '^[A-Za-z]:\\[^<>:"|?*\x00-\x1F]*[^\\\s]$')) { return 'The folder must be a UNC path (\\server\share) or a local path (C:\folder).' }
            }
            ''
        }
    }
}

#endregion

#region state of the installation and the settings

function Get-AVDTuneFSLogixInfo {
    <# Installed version, the two services, the filter drivers. Read only. #>
    param([Parameter(Mandatory)]$Machine)
    $version = [string](& $Machine.RegGet $script:AppsKey 'InstallVersion')
    $svc = { param($n) $s = & $Machine.ServiceGet $n; if ($s) { [pscustomobject]@{ Name = $n; Present = $true; Status = [string]$s.Status; StartType = [string]$s.StartType } } else { [pscustomobject]@{ Name = $n; Present = $false; Status = ''; StartType = '' } } }
    $fltmc = Join-Path (Get-AVDTuneSystemFolder System) 'fltmc.exe'
    $r = & $Machine.Run $fltmc @('filters') 30
    $drivers = @()
    if ($r.ExitCode -eq 0) { $drivers = @('frxdrv', 'frxdrvvt', 'frxccd' | Where-Object { $r.Output -match "(?im)^\s*$_(\s|\.)" }) }
    [pscustomobject]@{
        Installed = [bool]$version; Version = $version
        Frxsvc = (& $svc 'frxsvc'); Frxccds = (& $svc 'frxccds')
        DriversRead = ($r.ExitCode -eq 0); Drivers = @($drivers)
    }
}

function Get-AVDTuneFSLogixSettingsState {
    <# Per catalog entry: Current (from the registry), Recommended, Status ok | differs | missing | default, plus the catalog fields. #>
    param([Parameter(Mandatory)]$Machine)
    foreach ($s in (Get-AVDTuneFSLogixSettingCatalog)) {
        $cur = & $Machine.RegGet (Get-FsSettingKey $s) $s.Name
        $status = if ($null -eq $cur) { 'missing' } elseif ($null -eq $s.Recommended) { 'ok' } elseif ([string]@($cur)[0] -ieq [string]$s.Recommended) { 'ok' } else { 'differs' }
        [pscustomobject]@{ Name = $s.Name; Scope = $s.Scope; Type = $s.Type; Current = $cur; Recommended = $s.Recommended; Default = $s.Default; Status = $status; Explain = $s.Explain; Verified = $s.Verified; Source = $s.Source; Note = $s.Note; Min = $s.Min; Max = $s.Max }
    }
}

#endregion

#region steps and undo

function New-AVDTuneFSLogixRegStep {
    <# One registry value as a step. $Value $null = the value must be absent. Id fslogix.<scope>.<name> (lower case). #>
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name, $Value, [Parameter(Mandatory)][string]$Type, [string]$Title, [string]$SourceUrl, [string]$Why)
    $same = { param($cur, $want) if ($null -eq $want) { return ($null -eq $cur) }; if ($null -eq $cur) { return $false }; (@($cur) -join "`n") -ieq (@($want) -join "`n") }
    $test = { param($m) $cur = & $m.RegGet $Path $Name; @{ Compliant = [bool](& $same $cur $Value); State = $cur } }.GetNewClosure()
    $apply = { param($m) if ($null -eq $Value) { & $m.RegRemove $Path $Name } else { & $m.RegSet $Path $Name $Value $Type } }.GetNewClosure()
    New-AVDTuneStep -Id $Id -Section FSLogix -Title $(if ($Title) { $Title } else { "FSLogix: $Name" }) -Why $Why -Risk Low -SourceUrl $SourceUrl -Test $test -Apply $apply
}

function Get-FsRegType([string]$Type) { switch ($Type) { 'DWord' { 'DWord' } 'MultiString' { 'MultiString' } default { 'String' } } }

function Get-AVDTuneFSLogixUndoPath([string]$Root) { Join-Path $Root 'config\fslogix-undo.json' }

function Set-AVDTuneFSLogixSettings {
    <#
        Writes settings. -Values: hashtable 'Profile:Name' or 'ODFC:Name' (a bare name is Profile) -> value; $null removes the value. Validates every value first
        (nothing is written when one is invalid), keeps the previous values for Undo, runs the steps through Invoke-AVDTune (gate, run record, LastChange,
        change log). -WhatIf changes nothing and returns what would change.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Machine, [string]$Root = (Get-AVDTuneRoot), [Parameter(Mandatory)][hashtable]$Values, [string]$User, [string]$SnapshotId, [switch]$WhatIf)
    $catalog = @(Get-AVDTuneFSLogixSettingCatalog)
    $steps = New-Object System.Collections.ArrayList
    $undo = New-Object System.Collections.ArrayList
    foreach ($k in $Values.Keys) {
        $scope = 'Profile'; $name = [string]$k
        if ($name -match '^(Profile|ODFC):(.+)$') { $scope = $Matches[1]; $name = $Matches[2] }
        $s = @($catalog | Where-Object { $_.Name -eq $name -and $_.Scope -eq $scope })
        if ($s.Count -eq 0) { throw "Unknown FSLogix setting '$k'." }
        $s = $s[0]
        $v = $Values[$k]
        if ($null -ne $v) { $err = Test-AVDTuneFSLogixValue -Setting $s -Value $v; if ($err) { throw $err } }
        if ($s.Type -eq 'DWord' -and $null -ne $v) { $v = [int]$v }
        if ($s.Type -eq 'String' -and $s.Name -eq 'VolumeType' -and $null -ne $v) { $v = ([string]$v).ToLowerInvariant() }
        if ($s.Type -eq 'MultiString' -and $null -ne $v) { $v = @(@($v) | Where-Object { $_ } | ForEach-Object { [string]$_ }) }
        $path = Get-FsSettingKey $s
        $prev = & $Machine.RegGet $path $s.Name
        $id = "fslogix.$($scope.ToLowerInvariant()).$($s.Name.ToLowerInvariant())"
        [void]$steps.Add((New-AVDTuneFSLogixRegStep -Id $id -Path $path -Name $s.Name -Value $v -Type (Get-FsRegType $s.Type) -Title "FSLogix $scope setting $($s.Name)" -SourceUrl $s.Source -Why $s.Explain))
        [void]$undo.Add([ordered]@{ Id = $id; Path = $path; Name = $s.Name; Type = (Get-FsRegType $s.Type); Previous = $prev; Title = "FSLogix $scope setting $($s.Name)" })
    }
    if ($steps.Count -eq 0) { throw 'Nothing to write.' }
    if (-not $WhatIf -and (Test-AVDTuneWriteAllowed)) { Write-AVDTuneFile (Get-AVDTuneFSLogixUndoPath $Root) ([ordered]@{ At = (& $Machine.Now).ToString('o'); Items = @($undo) } | ConvertTo-Json -Depth 6) }
    Invoke-AVDTune -Plan ([pscustomobject]@{ Name = 'FSLogix settings'; Steps = @($steps | ForEach-Object { $_.Id }) }) -Catalog @($steps) -Machine $Machine -Root $Root -User $User -SnapshotId $SnapshotId -WhatIf:$WhatIf
}

function Undo-AVDTuneFSLogixSettings {
    <# Puts back the values found before the last Set-AVDTuneFSLogixSettings (a value that was absent is removed again). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Machine, [string]$Root = (Get-AVDTuneRoot), [string]$User, [string]$SnapshotId, [switch]$WhatIf)
    $u = Read-AVDTuneJson (Get-AVDTuneFSLogixUndoPath $Root)
    if (-not $u -or @($u.Items).Count -eq 0) { throw 'There is nothing to undo: no FSLogix settings change was recorded.' }
    $steps = @(foreach ($i in @($u.Items)) {
            $prev = Get-AVDTuneProp $i 'Previous'
            if ($i.Type -eq 'MultiString' -and $null -ne $prev) { $prev = @(@($prev) | ForEach-Object { [string]$_ }) }
            if ($i.Type -eq 'DWord' -and $null -ne $prev) { $prev = [int]$prev }
            New-AVDTuneFSLogixRegStep -Id "$($i.Id).undo" -Path $i.Path -Name $i.Name -Value $prev -Type $i.Type -Title "Undo: $($i.Title)"
        })
    $run = Invoke-AVDTune -Plan ([pscustomobject]@{ Name = 'FSLogix settings undo'; Steps = @($steps | ForEach-Object { $_.Id }) }) -Catalog $steps -Machine $Machine -Root $Root -User $User -SnapshotId $SnapshotId -WhatIf:$WhatIf
    if (-not $WhatIf -and @($run.Results | Where-Object { $_.Status -eq 'Failed' }).Count -eq 0) { Remove-Item -LiteralPath (Get-AVDTuneFSLogixUndoPath $Root) -Force -ErrorAction SilentlyContinue }
    $run
}

function Get-AVDTuneFSLogixLastChange {
    # "LastChange" of the FSLogix side: when the last FSLogix run was made and by whom (from the run records), for the form
    param([string]$Root = (Get-AVDTuneRoot))
    $runs = @(Get-AVDTuneRun -Root $Root | Where-Object { [string]$_.Plan -like 'FSLogix*' -and -not $_.WhatIf })
    if ($runs.Count -eq 0) { return $null }
    $r = $runs | Sort-Object { [datetime]$_.Ended } | Select-Object -Last 1
    [pscustomobject]@{ At = [string]$r.Ended; User = [string]$r.User; Plan = [string]$r.Plan }
}

#endregion

#region include and exclude groups

function Test-AVDTuneSid([string]$Sid) { $Sid -match '^S-1-\d{1,3}(-\d{1,10}){1,15}$' }

function Get-AVDTuneFSLogixGroupMembers($F, [string]$Name) { $r = & $F.LocalGroupMembers $Name; if (-not $r.Exists) { return $null }; , @(@($r.Members) | Where-Object { $_ }) }

function Get-AVDTuneFSLogixGroups {
    <#
        Members of the two local groups (SIDs). Learn (concepts-include-exclude-groups): the exclude groups have no members by default, the include groups
        include Everyone. $null for a group that does not exist (FSLogix not installed). The group NAMES are not printed on that Learn page
        (Verified=false): they are the names the installer creates.
    #>
    param([Parameter(Mandatory)]$F)
    [pscustomobject]@{
        IncludeName = $script:IncludeGroup; ExcludeName = $script:ExcludeGroup
        Include = (Get-AVDTuneFSLogixGroupMembers $F $script:IncludeGroup); Exclude = (Get-AVDTuneFSLogixGroupMembers $F $script:ExcludeGroup)
        Verified = $false; Source = "$script:Learn/concepts-include-exclude-groups"
    }
}

function Get-AVDTuneFSLogixGroupChoices {
    <# Groups to pick for the lists. With a domain controller (Directory info of the start sequence, config\directory.json): the groups with SIDs. Without: a hint. #>
    param([string]$Root = (Get-AVDTuneRoot), $Answers)
    $dir = Read-AVDTuneJson (Join-Path $Root 'config\directory.json')
    $dc = $Answers -and [string](Get-AVDTuneProp $Answers 'DomainController') -notin '', 'None'
    if ($dir -and (Get-AVDTuneProp $dir 'Directory')) {
        return [pscustomobject]@{ Source = 'Directory'; Groups = @(@($dir.Directory.Groups) | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ Name = [string]$_.Name; Sid = [string]$_.Sid } }); Hint = '' }
    }
    $hint = if ($dc) { 'The groups come from the domain controller: connect to it in the start sequence first.' } else { 'Entra ID only: groups are referenced by their SID (S-1-12-1-...). Copy the object ID from Entra ID and use the SID form; AVDTune does not list Entra groups here.' }
    [pscustomobject]@{ Source = 'None'; Groups = @(); Hint = $hint }
}

function Set-AVDTuneFSLogixGroupMember {
    <# Adds or removes a SID in the include or exclude list: a step (gate, change log). Add of an existing member and Remove of a missing one change nothing. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Machine, [Parameter(Mandatory)]$F, [string]$Root = (Get-AVDTuneRoot), [Parameter(Mandatory)][ValidateSet('Include', 'Exclude')][string]$List,
        [Parameter(Mandatory)][ValidateSet('Add', 'Remove')][string]$Action, [Parameter(Mandatory)][string]$Sid, [string]$User, [string]$SnapshotId, [switch]$WhatIf)
    if (-not (Test-AVDTuneSid $Sid)) { throw "'$Sid' is not a SID (S-1-...)." }
    $group = if ($List -eq 'Include') { $script:IncludeGroup } else { $script:ExcludeGroup }
    $want = $Action -eq 'Add'
    $test = { param($m) $mem = Get-AVDTuneFSLogixGroupMembers $F $group; if ($null -eq $mem) { throw "The local group '$group' does not exist: FSLogix is not installed." }; @{ Compliant = (([bool](@($mem) -contains $Sid)) -eq $want); State = (@($mem) -join ', ') } }.GetNewClosure()
    $apply = { param($m) if ($want) { & $F.LocalGroupAdd $group $Sid } else { & $F.LocalGroupRemove $group $Sid } }.GetNewClosure()
    $step = New-AVDTuneStep -Id "fslogix.group.$($List.ToLowerInvariant()).$($Action.ToLowerInvariant())" -Section FSLogix -Title "FSLogix $List list: $Action $Sid" -Why 'Controls which users FSLogix processes.' -SourceUrl "$script:Learn/concepts-include-exclude-groups" -Test $test -Apply $apply
    Invoke-AVDTune -Plan ([pscustomobject]@{ Name = 'FSLogix groups'; Steps = @($step.Id) }) -Catalog @($step) -Machine $Machine -Root $Root -User $User -SnapshotId $SnapshotId -WhatIf:$WhatIf
}

#endregion

#region redirections.xml

function Get-AVDTuneRedirectionTemplate {
    <#
        The cache template: groups of folders (relative to the profile, Copy=0: empty local folder, nothing copied). Only Teams comes from Learn
        (tutorial-redirections-xml); the other groups follow the usual cache folders of these programs and are Verified=false: check them before use.
    #>
    $t = "$script:Learn/tutorial-redirections-xml"
    $own = 'Usual cache folder of this program; not listed on Microsoft Learn. Check it before you use it.'
    @(
        [pscustomobject]@{ Group = 'Teams'; Verified = $true; Source = $t; Note = 'Learn: the recommended Teams folders for VDI.'; Paths = @(
                'AppData\Roaming\Microsoft\Teams\media-stack', 'AppData\Local\Microsoft\Teams\meeting-addin\Cache'
                'AppData\Local\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\Logs', 'AppData\Local\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\PerfLogs'
                'AppData\Local\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView\WV2Profile_tfw\WebStorage') }
        [pscustomobject]@{ Group = 'Edge'; Verified = $false; Source = "$script:Learn/concepts-redirections-xml"; Note = $own; Paths = @('AppData\Local\Microsoft\Edge\User Data\Default\Cache', 'AppData\Local\Microsoft\Edge\User Data\Default\Code Cache', 'AppData\Local\Microsoft\Edge\User Data\Default\GPUCache') }
        [pscustomobject]@{ Group = 'Chrome'; Verified = $false; Source = "$script:Learn/concepts-redirections-xml"; Note = $own; Paths = @('AppData\Local\Google\Chrome\User Data\Default\Cache', 'AppData\Local\Google\Chrome\User Data\Default\Code Cache', 'AppData\Local\Google\Chrome\User Data\Default\GPUCache') }
        [pscustomobject]@{ Group = 'Windows'; Verified = $false; Source = "$script:Learn/concepts-redirections-xml"; Note = "$own FSLogix already redirects TEMP and INetCache locally by default (SetTempToLocalPath=3)."; Paths = @('AppData\Local\CrashDumps', 'AppData\Local\Microsoft\Windows\WER') }
        [pscustomobject]@{ Group = 'Office'; Verified = $false; Source = "$script:Learn/concepts-redirections-xml"; Note = $own; Paths = @('AppData\Local\Microsoft\Office\16.0\OfficeFileCache', 'AppData\Local\Microsoft\Office\16.0\Wef') }
    )
}

# Never excluded: the folders of the Web Account Manager (WAM) and its token broker. Excluding them breaks single sign-on (reason from the change log of a
# real Golden Master build: SSO broke; Learn has no statement, so this is AVDTune's own safety rule, Verified=false). Compared case-insensitively as path parts.
$script:ProtectedParts = @('TokenBroker', 'Microsoft.AAD.BrokerPlugin', 'AAD.BrokerPlugin', 'Microsoft.AccountsControl', 'Microsoft.Windows.CloudExperienceHost')

function Test-AVDTuneRedirectionPath {
    <# '' when a relative profile path is acceptable for an Exclude or Include element, else the reason #>
    param([string]$Path)
    if (-not $Path -or -not $Path.Trim()) { return 'An empty path.' }
    if ($Path -ne $Path.Trim()) { return "'$Path' starts or ends with a blank." }
    if ($Path -match '^[A-Za-z]:' -or $Path.StartsWith('\') -or $Path.StartsWith('/')) { return "'$Path' must be relative to the profile (no drive, no leading backslash; Learn: it must NOT include C:\Users\%username%)." }
    if ($Path -match '[<>"|?*\x00-\x1F]' -or $Path -match '(^|\\)\.\.?(\\|$)') { return "'$Path' has characters or parts that are not allowed (. .. * ? < > | quotes)." }
    if ($Path -match '/') { return "'$Path' must use backslashes." }
    if ($Path -match '%') { return "'$Path' must not contain variables." }
    $parts = @($Path.Split('\') | Where-Object { $_ })
    foreach ($p in $parts) { foreach ($prot in $script:ProtectedParts) { if ($p -like "$prot*") { return "'$Path' touches ${prot}: the token broker and the Web Account Manager (WAM) are never excluded, because that breaks single sign-on." } } }
    ''
}

function New-AVDTuneRedirectionsXml {
    <# redirections.xml text. Excludes: strings (Copy 0) or @{ Path; Copy }; Includes: strings. ExcludeCommonFolders: bitmask 0..255 (Learn). Paths are validated; XML-encoded. #>
    param([object[]]$Excludes = @(), [string[]]$Includes = @(), [int]$ExcludeCommonFolders = 0)
    if ($ExcludeCommonFolders -lt 0 -or $ExcludeCommonFolders -gt 255) { throw 'ExcludeCommonFolders is a bitmask of 0 to 255.' }
    $enc = { param($t) [Net.WebUtility]::HtmlEncode([string]$t) }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<?xml version="1.0" encoding="UTF-8"?>')
    [void]$sb.AppendLine("<FrxProfileFolderRedirection ExcludeCommonFolders=`"$ExcludeCommonFolders`">")
    [void]$sb.AppendLine('<Excludes>')
    $seen = @{}
    foreach ($e in @($Excludes)) {
        $path = if ($e -is [string]) { $e } else { [string]$e.Path }; $copy = if ($e -is [string]) { 0 } else { [int]$e.Copy }
        $why = Test-AVDTuneRedirectionPath $path; if ($why) { throw $why }
        if ($copy -notin 0, 1, 2, 3) { throw "Copy must be 0 to 3 ($path)." }
        if ($seen.ContainsKey($path.ToLowerInvariant())) { continue }; $seen[$path.ToLowerInvariant()] = $true
        [void]$sb.AppendLine("<Exclude Copy=`"$copy`">$(& $enc $path)</Exclude>")
    }
    [void]$sb.AppendLine('</Excludes>')
    [void]$sb.AppendLine('<Includes>')
    foreach ($i in @($Includes | Where-Object { $_ })) { $why = Test-AVDTuneRedirectionPath $i; if ($why) { throw $why }; [void]$sb.AppendLine("<Include>$(& $enc $i)</Include>") }
    [void]$sb.AppendLine('</Includes>')
    [void]$sb.AppendLine('</FrxProfileFolderRedirection>')
    $sb.ToString()
}

function Test-AVDTuneRedirectionsXml {
    <# Validates a redirections.xml text: well formed (no DTD, no entities), the elements and attributes Learn lists, valid paths. Returns @{ Ok; Problems; Excludes; Includes; ExcludeCommonFolders }. #>
    param([string]$Xml)
    $problems = New-Object System.Collections.ArrayList
    $ex = New-Object System.Collections.ArrayList; $inc = New-Object System.Collections.ArrayList; $common = 0
    if (-not $Xml -or -not $Xml.Trim()) { return [pscustomobject]@{ Ok = $false; Problems = @('The file is empty.'); Excludes = @(); Includes = @(); ExcludeCommonFolders = 0 } }
    $settings = New-Object System.Xml.XmlReaderSettings
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit; $settings.XmlResolver = $null
    $doc = New-Object System.Xml.XmlDocument; $doc.XmlResolver = $null
    try { $reader = [System.Xml.XmlReader]::Create((New-Object IO.StringReader $Xml), $settings); try { $doc.Load($reader) } finally { $reader.Close() } }
    catch { return [pscustomobject]@{ Ok = $false; Problems = @("The XML is not well formed: $($_.Exception.Message)"); Excludes = @(); Includes = @(); ExcludeCommonFolders = 0 } }
    $root = $doc.DocumentElement
    if ($root.Name -ne 'FrxProfileFolderRedirection') { [void]$problems.Add("The root element must be FrxProfileFolderRedirection, not $($root.Name).") }
    else {
        $a = $root.GetAttribute('ExcludeCommonFolders')
        if ($a) { if ($a -match '^\d+$' -and [int]$a -le 255) { $common = [int]$a } else { [void]$problems.Add("ExcludeCommonFolders must be a bitmask of 0 to 255, not '$a'.") } }
        foreach ($child in $root.ChildNodes) {
            if ($child.NodeType -ne 'Element') { continue }
            if ($child.Name -notin 'Excludes', 'Includes') { [void]$problems.Add("Unknown element $($child.Name)."); continue }
            foreach ($item in $child.ChildNodes) {
                if ($item.NodeType -ne 'Element') { continue }
                $path = [string]$item.InnerText
                if ($child.Name -eq 'Excludes' -and $item.Name -ne 'Exclude') { [void]$problems.Add("Unknown element $($item.Name) in Excludes."); continue }
                if ($child.Name -eq 'Includes' -and $item.Name -ne 'Include') { [void]$problems.Add("Unknown element $($item.Name) in Includes."); continue }
                $why = Test-AVDTuneRedirectionPath $path; if ($why) { [void]$problems.Add($why) }
                if ($item.Name -eq 'Exclude') {
                    $c = $item.GetAttribute('Copy'); if ($c -and $c -notin '0', '1', '2', '3') { [void]$problems.Add("Copy must be 0 to 3 ($path).") }
                    [void]$ex.Add([pscustomobject]@{ Path = $path; Copy = $(if ($c -match '^[0-3]$') { [int]$c } else { 0 }) })
                }
                else { [void]$inc.Add($path) }
            }
        }
    }
    [pscustomobject]@{ Ok = ($problems.Count -eq 0); Problems = @($problems); Excludes = @($ex); Includes = @($inc); ExcludeCommonFolders = $common }
}

function Write-AVDTuneUndoFile {
    <# Writes an undo record; an older one is kept under a versioned name (the first record holds the state before AVDTune touched anything), never overwritten. #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Text)
    if (Test-Path -LiteralPath $Path) {
        $old = [IO.File]::ReadAllText($Path)
        $arch = [IO.Path]::ChangeExtension($Path, ([datetime]::UtcNow.ToString('yyyyMMddHHmmssfff') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.json'))
        Write-AVDTuneFile $arch $old
    }
    Write-AVDTuneFile $Path $Text
}

function Assert-AVDTuneRedirectionsPath {
    <# A redirections.xml path: no '..', and a local path only where the file and every folder above it are admin-only (a share is the administrator's choice). #>
    param([Parameter(Mandatory)][string]$Path)
    if (@($Path -split '[\\/]') -contains '..') { throw "The path $Path contains '..'." }
    if ($Path -like '\\*') { return }
    if ($Path -notmatch '^[A-Za-z]:\\') { throw "The path $Path is neither a UNC nor a local drive path." }
    $dir = Split-Path $Path -Parent
    if (-not (Test-AVDTuneAdminOnlyPath -Path $dir -Base ([IO.Path]::GetPathRoot($dir)))) { throw "The local folder $dir can be changed by users (or is not readable): redirections.xml is only written to a folder that only administrators can change." }
}

function Get-AVDTuneRedirectionsTarget {
    <# Where redirections.xml is written: <RedirXMLSourceFolder>\redirections.xml; $null when the setting is not there. #>
    param([Parameter(Mandatory)]$Machine)
    $folder = [string](& $Machine.RegGet $script:ProfilesKey 'RedirXMLSourceFolder')
    if (-not $folder) { return $null }
    $folder.TrimEnd('\') + '\redirections.xml'
}

function Save-AVDTuneRedirections {
    <#
        Writes the redirections.xml (validated again) to the folder of RedirXMLSourceFolder (-Folder sets that setting too, as part of the same plan),
        a step with Undo through the previous content. Returns the run. Needs the write gate unless -WhatIf.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Machine, [Parameter(Mandatory)]$F, [string]$Root = (Get-AVDTuneRoot), [Parameter(Mandatory)][string]$Xml, [string]$Folder, [string]$User, [string]$SnapshotId, [switch]$WhatIf)
    $v = Test-AVDTuneRedirectionsXml $Xml
    if (-not $v.Ok) { throw "The redirections.xml is not valid: $($v.Problems -join ' ')" }
    if ($Folder) { $why = Test-AVDTuneFSLogixValue -Setting (@(Get-AVDTuneFSLogixSettingCatalog | Where-Object Name -eq 'RedirXMLSourceFolder')[0]) -Value $Folder; if ($why) { throw $why } }
    $target = if ($Folder) { $Folder.TrimEnd('\') + '\redirections.xml' } else { Get-AVDTuneRedirectionsTarget $Machine }
    if (-not $target) { throw 'No target folder: set RedirXMLSourceFolder or enter a folder.' }
    $before = & $F.ReadText $target
    $steps = New-Object System.Collections.ArrayList
    if ($Folder) { [void]$steps.Add((New-AVDTuneFSLogixRegStep -Id 'fslogix.profile.redirxmlsourcefolder' -Path $script:ProfilesKey -Name 'RedirXMLSourceFolder' -Value $Folder.TrimEnd('\') -Type String -Title 'FSLogix profile setting RedirXMLSourceFolder' -SourceUrl "$script:Learn/tutorial-redirections-xml")) }
    $test = { param($m) $cur = & $F.ReadText $target; @{ Compliant = ($null -ne $cur -and $cur -ceq $Xml); State = $(if ($null -eq $cur) { 'absent' } else { "$($cur.Length) characters" }) } }.GetNewClosure()
    $apply = { param($m) & $F.WriteText $target $Xml }.GetNewClosure()
    [void]$steps.Add((New-AVDTuneStep -Id 'fslogix.redirections.file' -Section FSLogix -Title "redirections.xml ($($v.Excludes.Count) excludes, $($v.Includes.Count) includes)" -Why 'Keeps stateless cache folders out of the profile container.' -SourceUrl "$script:Learn/concepts-redirections-xml" -Test $test -Apply $apply))
    if (-not $WhatIf -and (Test-AVDTuneWriteAllowed)) { Write-AVDTuneUndoFile (Join-Path $Root 'config\redirections-undo.json') ([ordered]@{ Target = $target; Before = $before } | ConvertTo-Json) }
    Invoke-AVDTune -Plan ([pscustomobject]@{ Name = 'FSLogix redirections'; Steps = @($steps | ForEach-Object { $_.Id }) }) -Catalog @($steps) -Machine $Machine -Root $Root -User $User -SnapshotId $SnapshotId -WhatIf:$WhatIf
}

function Undo-AVDTuneRedirections {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Machine, [Parameter(Mandatory)]$F, [string]$Root = (Get-AVDTuneRoot), [string]$User, [string]$SnapshotId)
    $u = Read-AVDTuneJson (Join-Path $Root 'config\redirections-undo.json')
    if (-not $u) { throw 'There is nothing to undo: no redirections.xml change was recorded.' }
    $target = [string]$u.Target; $before = Get-AVDTuneProp $u 'Before'
    $test = { param($m) $cur = & $F.ReadText $target; @{ Compliant = ($cur -ceq $before -or ($null -eq $cur -and $null -eq $before)); State = '' } }.GetNewClosure()
    $apply = { param($m) if ($null -eq $before) { & $F.DeleteFile $target } else { & $F.WriteText $target $before } }.GetNewClosure()
    $step = New-AVDTuneStep -Id 'fslogix.redirections.undo' -Section FSLogix -Title 'Undo: redirections.xml' -Test $test -Apply $apply
    Invoke-AVDTune -Plan ([pscustomobject]@{ Name = 'FSLogix redirections undo'; Steps = @($step.Id) }) -Catalog @($step) -Machine $Machine -Root $Root -User $User -SnapshotId $SnapshotId
}

#endregion

#region Defender exclusions

function Split-AVDTuneLogonName {
    <# DOMAIN\user or user@domain into Domain and Name (a plain name has no domain). Length limited. #>
    param([string]$User)
    $domain = ''; $name = [string]$User
    if ($name.Length -le 256) {
        if ($name -match '^([^\\]+)\\(.+)$') { $domain = $Matches[1]; $name = $Matches[2] }
        elseif ($name -match '^(.+)@([^@]+)$') { $name = $Matches[1]; $domain = $Matches[2] }
    }
    [pscustomobject]@{ Domain = $domain; Name = $name }
}

function Get-AVDTuneFSLogixDefenderList {
    <#
        Microsoft's antivirus exclusions for FSLogix (Learn overview-prerequisites, page date 2026-03-30), mapped to what Microsoft Defender Antivirus accepts
        (processes and paths). Returns items @{ Kind (Process|Path); Value; Reason; Verified; Source; Note }. Registry keys and the profile mount points are in
        Learn's list but are not Defender exclusion types: they are returned in .NotDefender (for other AV or DLP tools). VHD locations (the shares of
        VHDLocations) add the container patterns. The mapping of %TEMP% and %username% to wildcards is AVDTune's own (Verified=false for those entries).
    #>
    param([string[]]$VhdLocations = @())
    $src = "$script:Learn/overview-prerequisites"
    $items = New-Object System.Collections.ArrayList
    $risk1 = 'Users can write here: a file placed in this folder would not be scanned.'
    $add = { param($k, $v, $why, $ok, $note, $risk) [void]$items.Add([pscustomobject]@{ Kind = $k; Value = $v; Reason = $why; Verified = $ok; Source = $src; Note = $(if ($risk) { "RISK: $risk $note".Trim() } else { $note }); Risk = [string]$risk }) }
    # processes only with the full path (a bare name would exclude any process of that name from anywhere); frxccd.exe is not on Learn's list and is not added
    foreach ($p in 'frxsvc.exe', 'frxccds.exe') { & $add 'Process' "C:\Program Files\FSLogix\Apps\$p" 'FSLogix service or Cloud Cache process (Learn names the file, AVDTune gives the full path)' $true 'Learn lists the file name only; the full path is the install folder of FSLogix.' '' }
    foreach ($d in 'frxdrv.sys', 'frxdrvvt.sys', 'frxccd.sys') { & $add 'Path' "C:\Program Files\FSLogix\Apps\$d" 'FSLogix filter driver' $true 'Learn lists the driver files; Defender excludes them as paths.' }
    & $add 'Path' 'C:\Program Files\FSLogix\Apps\' 'FSLogix binaries and utilities' $true ''
    & $add 'Path' 'C:\ProgramData\FSLogix\' 'FSLogix configuration and logs' $true '' $risk1
    & $add 'Path' 'C:\Users\*\AppData\Local\FSLogix\' 'Per-user FSLogix data (Learn: C:\Users\%username%\AppData\Local\FSLogix\)' $false 'Learn names %username%; Defender takes a wildcard for the user folder (AVDTune''s own mapping: the folder of every user).' 'Every user can write to their own folder.'
    & $add 'Path' 'C:\ProgramData\FSLogix\Cache\*' 'Cloud Cache cache files' $true '' $risk1
    & $add 'Path' 'C:\ProgramData\FSLogix\Proxy\*' 'Cloud Cache proxy files' $true '' $risk1
    foreach ($ext in 'VHD', 'VHDX') {
        & $add 'Path' "C:\Users\*\AppData\Local\Temp\*\*.$ext" "User temp $ext files (difference disks); Learn: %TEMP%\*\*.$ext" $false 'Learn names %TEMP% (the user temp path); mapped to a wildcard for every user.' 'Every user can write to their own temp folder.'
        & $add 'Path' "C:\Windows\Temp\*\*.$ext" "System temp $ext files; Learn: %WINDIR%\TEMP\*\*.$ext" $true '' 'Users can create folders in the system temp folder: a file there would not be scanned.'
    }
    foreach ($loc in @($VhdLocations | Where-Object { $_ })) {
        $base = ([string]$loc).TrimEnd('\')
        foreach ($ext in 'VHD', 'VHDX') { foreach ($suffix in '', '.lock', '.meta', '.metadata') { & $add 'Path' "$base\*\*.$ext$suffix" "Containers on the share $base" $true 'Learn: \\{SMB or UNC path}\*\*.VHD(X) with .lock, .meta, .metadata.' 'Users write their own container here: a .vhd(x) file they put there would not be scanned.' } }
    }
    [pscustomobject]@{
        Items = @($items)
        NotDefender = @(
            [pscustomobject]@{ Value = 'HKLM\SOFTWARE\FSLogix\'; Reason = 'FSLogix profile registry keys' }
            [pscustomobject]@{ Value = 'HKLM\SOFTWARE\Policies\FSLogix\'; Reason = 'FSLogix ODFC registry keys' }
            [pscustomobject]@{ Value = 'FSLogix profile mount points (VHD(x) attach points)'; Reason = 'Attach points of the containers' })
        Source = $src
    }
}

function Get-AVDTuneFSLogixDefenderState {
    <# Each item of the list with Present (already an exclusion). $null Defender (not readable: policy, tamper protection, not Defender) is reported as Readable=$false. #>
    param([Parameter(Mandatory)]$F, [string[]]$VhdLocations = @())
    $list = Get-AVDTuneFSLogixDefenderList -VhdLocations $VhdLocations
    $cur = & $F.DefenderGet
    if (-not $cur) { return [pscustomobject]@{ Readable = $false; Items = @($list.Items | ForEach-Object { $_ | Add-Member -NotePropertyName Present -NotePropertyValue $false -PassThru }); NotDefender = $list.NotDefender; Source = $list.Source } }
    $paths = @(@($cur.Paths) | ForEach-Object { ([string]$_).ToLowerInvariant() }); $procs = @(@($cur.Processes) | ForEach-Object { ([string]$_).ToLowerInvariant() })
    $items = @(foreach ($i in $list.Items) {
            $present = if ($i.Kind -eq 'Process') { $procs -contains $i.Value.ToLowerInvariant() } else { $paths -contains $i.Value.ToLowerInvariant() -or $paths -contains $i.Value.TrimEnd('\').ToLowerInvariant() }
            $i | Add-Member -NotePropertyName Present -NotePropertyValue ([bool]$present) -PassThru
        })
    [pscustomobject]@{ Readable = $true; Items = $items; NotDefender = $list.NotDefender; Source = $list.Source }
}

function Set-AVDTuneFSLogixDefender {
    <# Adds the missing Defender exclusions (one step, Undo removes exactly the ones that were added). Needs the write gate unless -WhatIf. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Machine, [Parameter(Mandatory)]$F, [string]$Root = (Get-AVDTuneRoot), [string[]]$VhdLocations = @(), [string]$User, [string]$SnapshotId, [string[]]$Skip = @(), [switch]$WhatIf)
    $state = Get-AVDTuneFSLogixDefenderState -F $F -VhdLocations $VhdLocations
    if (-not $state.Readable) { throw 'The Defender exclusions cannot be read here (another antivirus, or Defender is managed by a policy that hides them). Nothing was changed.' }
    $skipSet = @(@($Skip) | Where-Object { $_ } | ForEach-Object { ([string]$_).ToLowerInvariant() })   # deselected by the administrator: not set, not in the undo list
    $skipped = @($state.Items | Where-Object { -not $_.Present -and $skipSet -contains $_.Value.ToLowerInvariant() })
    $todo = @($state.Items | Where-Object { -not $_.Present -and $skipSet -notcontains $_.Value.ToLowerInvariant() })
    $undoList = @($todo | ForEach-Object { [ordered]@{ Kind = $_.Kind; Value = $_.Value } })
    $test = { param($m) $s = Get-AVDTuneFSLogixDefenderState -F $F -VhdLocations $VhdLocations; $open = @($s.Items | Where-Object { -not $_.Present -and $skipSet -notcontains $_.Value.ToLowerInvariant() }); @{ Compliant = ($open.Count -eq 0); State = "$(@($s.Items).Count - $open.Count - $skipped.Count) of $(@($s.Items).Count) present$(if ($skipped.Count -gt 0) { ", $($skipped.Count) deselected" })" } }.GetNewClosure()
    $apply = { param($m) foreach ($i in $todo) { & $F.DefenderAdd $i.Kind $i.Value } }.GetNewClosure()
    $step = New-AVDTuneStep -Id 'fslogix.defender.exclusions' -Section FSLogix -Title "FSLogix Defender exclusions ($($todo.Count) to add$(if ($skipped.Count -gt 0) { ", $($skipped.Count) deselected and not set: " + (($skipped | ForEach-Object { $_.Value }) -join '; ') }))" -Why 'Microsoft asks to exclude FSLogix from antivirus scanning; scanning causes slow logons and locked containers.' -SourceUrl $state.Source -Test $test -Apply $apply
    if (-not $WhatIf -and $todo.Count -gt 0 -and (Test-AVDTuneWriteAllowed)) { Write-AVDTuneUndoFile (Join-Path $Root 'config\fslogix-defender-undo.json') ([ordered]@{ Added = $undoList } | ConvertTo-Json -Depth 4) }
    Invoke-AVDTune -Plan ([pscustomobject]@{ Name = 'FSLogix Defender exclusions'; Steps = @($step.Id) }) -Catalog @($step) -Machine $Machine -Root $Root -User $User -SnapshotId $SnapshotId -WhatIf:$WhatIf
}

function Undo-AVDTuneFSLogixDefender {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Machine, [Parameter(Mandatory)]$F, [string]$Root = (Get-AVDTuneRoot), [string]$User, [string]$SnapshotId)
    $u = Read-AVDTuneJson (Join-Path $Root 'config\fslogix-defender-undo.json')
    if (-not $u -or @($u.Added).Count -eq 0) { throw 'There is nothing to undo: no exclusion was added by AVDTune.' }
    $added = @($u.Added)
    $test = { param($m) $cur = & $F.DefenderGet; $left = @($added | Where-Object { $v = $_.Value.ToLowerInvariant(); (@($cur.Paths) + @($cur.Processes) | ForEach-Object { ([string]$_).ToLowerInvariant() }) -contains $v }); @{ Compliant = ($left.Count -eq 0); State = "$($left.Count) left" } }.GetNewClosure()
    $apply = { param($m) foreach ($i in $added) { & $F.DefenderRemove ([string]$i.Kind) ([string]$i.Value) } }.GetNewClosure()
    $step = New-AVDTuneStep -Id 'fslogix.defender.undo' -Section FSLogix -Title 'Undo: FSLogix Defender exclusions' -Test $test -Apply $apply
    Invoke-AVDTune -Plan ([pscustomobject]@{ Name = 'FSLogix Defender undo'; Steps = @($step.Id) }) -Catalog @($step) -Machine $Machine -Root $Root -User $User -SnapshotId $SnapshotId
}

#endregion

#region install and update

function Get-AVDTuneFSLogixLatest {
    <# What the Microsoft download link points to now: @{ Ok; FileName; Version (e.g. 26.08 from FSLogix_26.08.zip); Url; Error }. No download. #>
    param([Parameter(Mandatory)]$F)
    $r = & $F.LatestRelease
    if (-not $r.Ok) { return [pscustomobject]@{ Ok = $false; FileName = ''; Version = ''; Url = ''; Error = [string]$r.Error } }
    $uri = $null
    if (-not [Uri]::TryCreate([string]$r.Url, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https' -or $uri.Host -ne $script:DownloadHost) {
        return [pscustomobject]@{ Ok = $false; FileName = ''; Version = ''; Url = ''; Error = "The download link does not point to $script:DownloadHost over https; it is not used." }
    }
    $name = [IO.Path]::GetFileName($uri.AbsolutePath)
    $ver = if ($name -match '^FSLogix_(\d{2}\.\d{2}(\.\d+)?)\.zip$') { $Matches[1] } else { '' }
    [pscustomobject]@{ Ok = $true; FileName = $name; Version = $ver; Url = $uri.AbsoluteUri; Error = '' }
}

function ConvertTo-AVDTuneVersion([string]$Text) { $v = $null; if ([version]::TryParse(($Text -replace '[^0-9.].*$', ''), [ref]$v)) { $v } else { $null } }

function Invoke-AVDTuneFSLogixInstall {
    <#
        Installs or updates FSLogix Apps: latest release from Microsoft -> a new folder below the protected state folder -> unzip -> the installer's
        Authenticode signature (Test-AVDTuneToolTrust) -> compare with the installed version (nothing to do when it is not newer) -> signature again
        right before the start -> FSLogixAppsSetup.exe /install /quiet /norestart (the switches are from Learn install-ht) -> check the installed version.
        The folder is removed at the end. Returns @{ Status Changed|Unchanged|Failed; Message; Code; Before; After; Reboot }. Never throws for expected problems.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Machine, [Parameter(Mandatory)]$F, [string]$Root = (Get-AVDTuneRoot), [scriptblock]$Progress)
    $say = { param($t) if ($Progress) { & $Progress $t } }
    $out = { param($s, $msg, $code, $before, $after, $reboot) [pscustomobject]@{ Status = $s; Message = $msg; Code = $code; Before = $before; After = $after; Reboot = [bool]$reboot } }
    $before = [string](& $Machine.RegGet $script:AppsKey 'InstallVersion')
    $latest = Get-AVDTuneFSLogixLatest -F $F
    if (-not $latest.Ok) { return & $out 'Failed' "The newest FSLogix release could not be found: $($latest.Error)" 'NoRelease' $before '' $false }
    $dir = $null
    try {
        & $say "Downloading $($latest.FileName) ..."
        $dir = & $F.NewTempFolder $Root
        if (-not $dir -or -not (& $F.IsProtectedFolder $dir $Root)) { return & $out 'Failed' 'The download folder is not protected (Administrators and SYSTEM only): nothing was downloaded.' 'NotProtected' $before '' $false }
        $zip = Join-Path $dir 'FSLogix.zip'
        $dl = & $F.Download $latest.Url $zip $script:MaxDownloadBytes
        if (-not $dl.Ok) { return & $out 'Failed' "The download failed: $($dl.Error)" 'Download' $before '' $false }
        & $say 'Unpacking ...'
        $ex = & $F.Expand $zip (Join-Path $dir 'x')
        if (-not $ex.Ok) { return & $out 'Failed' "The package could not be unpacked: $($ex.Error)" 'Unpack' $before '' $false }
        $setup = & $F.FindInstaller (Join-Path $dir 'x')
        if (-not $setup) { return & $out 'Failed' 'FSLogixAppsSetup.exe (x64\Release) is not in the package.' 'NoInstaller' $before '' $false }
        $trust = Test-AVDTuneToolTrust -Signature (& $F.VerifySignature $setup) -Name 'FSLogixAppsSetup.exe'
        if (-not $trust.Ok) { return & $out 'Failed' "$($trust.Reason): it is not started." 'BadSignature' $before '' $false }
        $new = [string](& $F.FileVersion $setup)
        $nv = ConvertTo-AVDTuneVersion $new; $ov = ConvertTo-AVDTuneVersion $before
        if ($nv -and $ov -and $ov -ge $nv) { return & $out 'Unchanged' "FSLogix $before is up to date (the newest release carries $new)." '' $before $before $false }
        & $say "Installing FSLogix $new ..."
        $trust = Test-AVDTuneToolTrust -Signature (& $F.VerifySignature $setup) -Name 'FSLogixAppsSetup.exe'   # again, right before the start
        if (-not $trust.Ok) { return & $out 'Failed' "$($trust.Reason): it is not started." 'BadSignature' $before '' $false }
        $r = & $Machine.Run $setup @('/install', '/quiet', '/norestart') 900
        if ($r.ExitCode -notin 0, 3010, 1641) { return & $out 'Failed' "The installer returned $($r.ExitCode). $($r.Output)".Trim() "Exit$($r.ExitCode)" $before '' $false }
        $after = [string](& $Machine.RegGet $script:AppsKey 'InstallVersion')
        if (-not $after) { return & $out 'Failed' 'The installer finished but FSLogix is not registered (no InstallVersion).' 'NotRegistered' $before '' $false }
        & $out 'Changed' $(if ($before) { "Updated from $before to $after." } else { "Installed $after." }) '' $before $after $true
    }
    finally { if ($dir) { try { & $F.RemoveFolder $dir } catch { } } }
}

function Invoke-AVDTuneFSLogixInstallRecorded {
    <# The install or update of the FSLogix page: behind the write gate, with a run record (Plan 'FSLogix install'), LastChange and a change log entry. Returns the step-like Result and the Install answer. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Machine, [Parameter(Mandatory)]$F, [string]$Root = (Get-AVDTuneRoot), [string]$User, [string]$SnapshotId, [scriptblock]$Progress)
    if (-not (Test-AVDTuneWriteAllowed)) { throw 'The snapshot gate is not confirmed: AVDTune is read only until a snapshot newer than its last change is confirmed on the Overview.' }
    $started = & $Machine.Now
    [void](Set-AVDTuneState -Root $Root -Values @{ LastChange = $started.ToString('o') })
    $r = Invoke-AVDTuneFSLogixInstall -Machine $Machine -F $F -Root $Root -Progress $Progress
    $res = [pscustomobject][ordered]@{ Id = 'fslogix.install'; Section = 'FSLogix'; Title = 'FSLogix Apps'; Mode = 'Apply'; Status = $r.Status; Before = $r.Before; After = $r.After; Message = $r.Message; Reboot = [bool]$r.Reboot -and $r.Status -eq 'Changed'; WhatIf = $false; At = $started.ToString('o'); Code = $r.Code }
    $state = Get-AVDTuneState $Root
    $run = [pscustomobject][ordered]@{ Id = $null; Plan = 'FSLogix install'; Started = $started.ToString('o'); Ended = (& $Machine.Now).ToString('o'); User = $User; SnapshotId = $SnapshotId; WhatIf = $false; ImageVersion = $state.ImageVersion; Reboot = $res.Reboot; Results = @($res) }
    [void](Add-AVDTuneRun -Root $Root -Run $run)
    if ($r.Status -in 'Changed', 'Failed') { [void](Set-AVDTuneState -Root $Root -Values @{ LastChange = (& $Machine.Now).ToString('o') }) }
    if ($state.ImageVersion -and $r.Status -in 'Changed', 'Failed') {
        $text = if ($r.Status -eq 'Changed') { "FSLogix Apps: $($r.Message)" } else { "FSLogix Apps: install FAILED ($($r.Code)) - $($r.Message)" }
        [void](Add-AVDTuneChangeLogEntry -Root $Root -Version $state.ImageVersion -Category 'FSLogix' -Component 'FSLogix' -ChangeType $(if ($r.Status -eq 'Changed') { 'Updated' } else { 'Note' }) -Text $text -User $User -SnapshotId $SnapshotId -RunId ([string]$run.Id) -Source Step)
    }
    [pscustomobject]@{ Result = $res; Install = $r; Run = $run }
}

#endregion

#region ACL (NTFS) of the share root against Microsoft's recommendation

$script:AclModify = 0x1301bf
$script:AclFull = 0x1f01ff

function ConvertFrom-AVDTuneSddl {
    <# Allow and Deny entries of an SDDL (aliases like BA, SY, CO are resolved by Windows): @{ Sid; Type; Mask; ObjectInherit; ContainerInherit; InheritOnly; NoPropagate; Inherited } #>
    param([Parameter(Mandatory)][string]$Sddl)
    $sd = New-Object System.Security.AccessControl.RawSecurityDescriptor $Sddl
    $owner = if ($sd.Owner) { $sd.Owner.Value } else { '' }
    $aces = @(foreach ($a in @($sd.DiscretionaryAcl)) {
            if ($a -isnot [System.Security.AccessControl.CommonAce]) { continue }
            $fl = [int]$a.AceFlags
            [pscustomobject]@{ Sid = $a.SecurityIdentifier.Value; Type = [string]$a.AceType; Mask = [int]$a.AccessMask; ObjectInherit = [bool]($fl -band 1); ContainerInherit = [bool]($fl -band 2); NoPropagate = [bool]($fl -band 4); InheritOnly = [bool]($fl -band 8); Inherited = [bool]($fl -band 16) }
        })
    [pscustomobject]@{ Owner = $owner; Aces = $aces }
}

function Format-AVDTuneAce($A) {
    $applies = if ($A.InheritOnly -and ($A.ObjectInherit -or $A.ContainerInherit)) { 'subfolders and files only' } elseif ($A.ObjectInherit -and $A.ContainerInherit) { 'this folder, subfolders and files' } elseif ($A.ContainerInherit) { 'this folder and subfolders' } elseif ($A.ObjectInherit) { 'this folder and files' } else { 'this folder only' }
    $rights = if (($A.Mask -band $script:AclFull) -eq $script:AclFull) { 'Full' } elseif (($A.Mask -band $script:AclModify) -eq $script:AclModify) { 'Modify' } else { ('0x{0:x}' -f $A.Mask) }
    "$($A.Type) $($A.Sid): $rights, $applies"
}

function New-AVDTuneFSLogixRecommendedSddl {
    <# The recommended SDDL of the share root (Learn how-to-configure-storage-permissions): CREATOR OWNER modify on subfolders and files only, admins full on all, users modify on this folder only; SYSTEM full (from Learn's SIDDirSDDL example). #>
    param([Parameter(Mandatory)][string]$UsersSid, [Parameter(Mandatory)][string]$AdminsSid)
    foreach ($s in $UsersSid, $AdminsSid) { if (-not (Test-AVDTuneSid $s)) { throw "'$s' is not a SID." } }
    "O:BAG:DUD:PAI(A;OICIIO;0x1301bf;;;CO)(A;OICI;FA;;;$AdminsSid)(A;;0x1301bf;;;$UsersSid)(A;OICI;FA;;;SY)"
}

function Compare-AVDTuneFSLogixAcl {
    <#
        Compares the SDDL of a share root with the recommendation. Returns @{ Compliant; Findings (Id, Status red|yellow, Text); Found (lines); Expected (lines) }.
        Required: CREATOR OWNER modify on subfolders and files only; an admins group (one of -AdminsSids) full on this folder, subfolders and files; a users group
        (one of -UsersSids) modify on this folder only. Red when someone broad (Everyone, Authenticated Users, BUILTIN\Users, a users group) can reach the subfolders
        of other users. Without -UsersSids/-AdminsSids the groups are not known: yellow "check by hand".
    #>
    param([Parameter(Mandatory)][string]$Sddl, [string[]]$UsersSids = @(), [string[]]$AdminsSids = @())
    $p = ConvertFrom-AVDTuneSddl $Sddl
    $findings = New-Object System.Collections.ArrayList
    $allow = @($p.Aces | Where-Object { $_.Type -eq 'AccessAllowed' })
    $hasMask = { param($a, $m) ($a.Mask -band $m) -eq $m }
    $co = @($allow | Where-Object { $_.Sid -eq 'S-1-3-0' -and (& $hasMask $_ $script:AclModify) -and $_.InheritOnly -and $_.ObjectInherit -and $_.ContainerInherit })
    if ($co.Count -eq 0) { [void]$findings.Add([pscustomobject]@{ Id = 'creator-owner'; Status = 'red'; Text = 'CREATOR OWNER needs Modify on subfolders and files only: it gives each user his own folder and nobody else.' }) }
    if ($AdminsSids.Count -gt 0) {
        $ad = @($allow | Where-Object { $_.Sid -in $AdminsSids -and (& $hasMask $_ $script:AclFull) -and $_.ObjectInherit -and $_.ContainerInherit -and -not $_.InheritOnly })
        if ($ad.Count -eq 0) { [void]$findings.Add([pscustomobject]@{ Id = 'admins'; Status = 'red'; Text = 'The administrators group needs Full Control on this folder, subfolders and files.' }) }
    }
    else { [void]$findings.Add([pscustomobject]@{ Id = 'admins'; Status = 'yellow'; Text = 'The administrators group is not known (no domain information): check by hand that it has Full Control on this folder, subfolders and files.' }) }
    if ($UsersSids.Count -gt 0) {
        $us = @($allow | Where-Object { $_.Sid -in $UsersSids -and (& $hasMask $_ $script:AclModify) -and -not $_.ObjectInherit -and -not $_.ContainerInherit })
        if ($us.Count -eq 0) { [void]$findings.Add([pscustomobject]@{ Id = 'users'; Status = 'red'; Text = 'The users group needs Modify on this folder only (so users can create their folder, not browse others).' }) }
    }
    else { [void]$findings.Add([pscustomobject]@{ Id = 'users'; Status = 'yellow'; Text = 'The users group is not known (no domain information): check by hand that it has Modify on this folder only.' }) }
    $broad = @('S-1-1-0', 'S-1-5-11', 'S-1-5-32-545') + @($UsersSids)
    foreach ($a in @($allow | Where-Object { $_.Sid -in $broad -and ($_.ObjectInherit -or $_.ContainerInherit) })) {
        [void]$findings.Add([pscustomobject]@{ Id = "broad-$($a.Sid)"; Status = 'red'; Text = "$($a.Sid) reaches the subfolders and files ($(Format-AVDTuneAce $a)): users could see the containers of others." })
    }
    $red = @($findings | Where-Object Status -eq 'red').Count; $yellow = @($findings | Where-Object Status -eq 'yellow').Count
    $expected = @('Allow CREATOR OWNER (S-1-3-0): Modify, subfolders and files only', 'Allow <administrators group>: Full, this folder, subfolders and files', 'Allow <users group>: Modify, this folder only', 'Allow SYSTEM: Full, this folder, subfolders and files')
    [pscustomobject]@{ Compliant = ($red -eq 0 -and $yellow -eq 0); Findings = @($findings); Found = @($p.Aces | ForEach-Object { Format-AVDTuneAce $_ }); Expected = $expected; Owner = $p.Owner }
}

#endregion

#region function test

function New-AVDTuneFsRow {
    param([string]$Id, [int]$Step, [string]$Title, [ValidateSet('green', 'yellow', 'red', 'info')][string]$Status, [string]$Reason, [string]$Fix = '', [string]$Source = "$script:Learn/reference-configuration-settings", [bool]$Verified = $true, [string]$Note = '')
    if (-not $Verified -and -not $Note) { $Note = 'Not stated on Microsoft Learn: the check is AVDTune''s own (the source is the nearest Learn page).' }
    [pscustomobject]@{ Id = $Id; Step = $Step; Title = $Title; Status = $Status; Reason = $Reason; Fix = $Fix; Source = $Source; Verified = $Verified; Note = $Note }
}

function Get-AVDTuneFSLogixLocations {
    param([Parameter(Mandatory)]$Machine)
    $v = & $Machine.RegGet $script:ProfilesKey 'VHDLocations'
    @(@($v) | Where-Object { $_ } | ForEach-Object { [string]$_ })
}

function Get-AVDTuneUncHost([string]$Unc) { if ($Unc -match '^\\\\([^\\]+)\\') { $Matches[1] } else { '' } }

function Invoke-AVDTuneFSLogixTest {
    <#
        The function test of docs\plans\avdtune.md section 5a, steps 1 to 6 (step 7, a real sign-in, runs on a session host after rollout and is shown as info).
        Reads the master; with -RunWriteTests it also creates a test folder and file on the share and a test VHDX with frx (the caller asks the administrator first).
        Result: Rows (green/yellow/red/info with Reason and Fix), Counts, Overall, Passed (Overall is green), At. Never throws for a failing check: a check that throws is red.
        -UsersSids/-AdminsSids: the groups of the share root ACL (from the domain information), for the comparison with the recommendation.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Machine, [Parameter(Mandatory)]$F, [switch]$RunWriteTests, [string[]]$UsersSids = @(), [string[]]$AdminsSids = @())
    $rows = New-Object System.Collections.ArrayList
    function Add([object]$Row) { [void]$rows.Add($Row) }
    function Guard([string]$Id, [int]$Step, [string]$Title, [scriptblock]$Body) { try { & $Body } catch { Add (New-AVDTuneFsRow $Id $Step $Title 'red' "The check failed: $($_.Exception.Message)") } }
    $info = Get-AVDTuneFSLogixInfo -Machine $Machine
    $cc = [bool](& $Machine.RegGet $script:ProfilesKey 'CCDLocations')
    $svcSrc = "$script:Learn/reference-service-drivers-components"

    # 1 version, services, driver
    Guard 'fs.version' 1 'FSLogix installed' {
        if ($info.Installed) { Add (New-AVDTuneFsRow 'fs.version' 1 'FSLogix installed' 'green' "FSLogix $($info.Version) is installed." -Source "$script:Learn/install-ht") }
        else { Add (New-AVDTuneFsRow 'fs.version' 1 'FSLogix installed' 'red' 'FSLogix is not installed.' 'Install it on the Updates page (FSLogix Apps) or on the FSLogix page.' -Source "$script:Learn/install-ht") }
    }
    Guard 'fs.services' 1 'Services frxsvc and frxccds' {
        $s = $info.Frxsvc
        if (-not $s.Present) { Add (New-AVDTuneFsRow 'fs.services' 1 'Services frxsvc and frxccds' 'red' 'The service frxsvc (FSLogix Apps Services) does not exist.' 'Install or repair FSLogix.' -Source $svcSrc) }
        elseif ($s.Status -ne 'Running') { Add (New-AVDTuneFsRow 'fs.services' 1 'Services frxsvc and frxccds' 'red' "frxsvc is $($s.Status), it must run (startup type Automatic)." 'Start the service (or restart the master) and run the test again.' -Source $svcSrc) }
        elseif ($cc -and (-not $info.Frxccds.Present -or $info.Frxccds.Status -ne 'Running')) { Add (New-AVDTuneFsRow 'fs.services' 1 'Services frxsvc and frxccds' 'red' 'Cloud Cache is configured (CCDLocations) but frxccds is not running.' 'Start frxccds.' -Source $svcSrc) }
        else { Add (New-AVDTuneFsRow 'fs.services' 1 'Services frxsvc and frxccds' 'green' "frxsvc runs$(if ($cc) { ', frxccds runs (Cloud Cache)' } else { '; frxccds is only needed for Cloud Cache' })." -Source $svcSrc -Note 'That frxccds may be stopped without Cloud Cache is read from its description on Learn (Cloud Cache process); Learn does not say it explicitly.' -Verified $false) }
    }
    Guard 'fs.driver' 1 'Filter drivers loaded' {
        if (-not $info.DriversRead) { Add (New-AVDTuneFsRow 'fs.driver' 1 'Filter drivers loaded' 'yellow' 'fltmc could not be read.' 'Run fltmc filters in an elevated prompt by hand.' -Source $svcSrc) }
        elseif ($info.Drivers -contains 'frxdrv' -and $info.Drivers -contains 'frxdrvvt') { Add (New-AVDTuneFsRow 'fs.driver' 1 'Filter drivers loaded' 'green' 'frxdrv and frxdrvvt are loaded (fltmc filters).' -Source $svcSrc) }
        else { Add (New-AVDTuneFsRow 'fs.driver' 1 'Filter drivers loaded' 'red' "Not loaded: $((@('frxdrv', 'frxdrvvt') | Where-Object { $_ -notin $info.Drivers }) -join ', '). Without them no container can be attached." 'Restart the master; repair FSLogix if it stays.' -Source $svcSrc) }
    }

    # 2 registry
    $locations = @(Get-AVDTuneFSLogixLocations -Machine $Machine)
    Guard 'fs.registry' 2 'Registry values' {
        $problems = New-Object System.Collections.ArrayList
        $enabled = & $Machine.RegGet $script:ProfilesKey 'Enabled'
        if ([string]$enabled -ne '1') { [void]$problems.Add("Enabled is '$enabled' (must be 1).") }
        if ($locations.Count -eq 0 -and -not $cc) { [void]$problems.Add('VHDLocations is not set.') }
        foreach ($l in $locations) { if (-not (Test-AVDTuneFSLogixUncPath $l)) { [void]$problems.Add("VHDLocations entry '$l' is not a clean UNC path (\\server\share, no trailing backslash or blank).") } }
        $vt = & $Machine.RegGet $script:ProfilesKey 'VolumeType'; if ($null -ne $vt -and [string]$vt -notin 'vhd', 'vhdx') { [void]$problems.Add("VolumeType is '$vt' (vhd or vhdx).") }
        foreach ($s in (Get-AVDTuneFSLogixSettingCatalog | Where-Object { $_.Scope -eq 'Profile' -and $_.Type -eq 'DWord' })) { $v = & $Machine.RegGet $script:ProfilesKey $s.Name; if ($null -ne $v) { $e = Test-AVDTuneFSLogixValue -Setting $s -Value $v; if ($e) { [void]$problems.Add($e) } } }
        $known = @(Get-AVDTuneFSLogixSettingCatalog | ForEach-Object { $_.Name.ToLowerInvariant() }) + @('ccdlocations', 'siddirnamematch', 'siddirnamepattern', 'vhdnamematch', 'vhdnamepattern', 'noprofilecontainingfolder', 'accessnetworkascomputerobject', 'cleanoutnotifications', 'diffdiskparentfolderpath', 'grouppolicystate', 'ignorenonwvd', 'installappxpackages', 'keeplocaldir', 'outlookcachedmode', 'rebootonuserlogoff', 'redirecttype', 'removeorphanedostfilesonlogoff', 'roamidentity', 'roamsearch', 'settemptolocalpath', 'shutdownonuserlogoff', 'volumewaittimems', 'vhdxsectorsize', 'attachvhdsddl', 'profiledirsddl', 'siddirsddl', 'cleaninvalidsessions', 'vhdcompactdisk')
        $names = @(& $Machine.RegNames $script:ProfilesKey)
        $unknown = @($names | Where-Object { $_ -and ($_.ToLowerInvariant() -notin $known) })
        if ($problems.Count -gt 0) { Add (New-AVDTuneFsRow 'fs.registry' 2 'Registry values' 'red' ($problems -join ' ') 'Correct the values on the FSLogix page.') }
        elseif ($unknown.Count -gt 0) { Add (New-AVDTuneFsRow 'fs.registry' 2 'Registry values' 'yellow' "Values AVDTune does not know (typo?): $($unknown -join ', ')." 'Compare the names with the reference settings on Learn; remove a misspelled value.' -Note 'Compared with the list of settings on the Learn reference page and the extra names AVDTune knows.' -Verified $false) }
        else { Add (New-AVDTuneFsRow 'fs.registry' 2 'Registry values' 'green' 'The required values are there and plausible.') }
    }
    Guard 'fs.conflict' 2 'Cloud Cache and VHDLocations' {
        if ($cc -and $locations.Count -gt 0) { Add (New-AVDTuneFsRow 'fs.conflict' 2 'Cloud Cache and VHDLocations' 'red' 'CCDLocations and VHDLocations are both set: Cloud Cache and a plain profile container conflict.' 'Keep one of the two.' -Source "$script:Learn/concepts-fslogix-cloud-cache") }
        else { Add (New-AVDTuneFsRow 'fs.conflict' 2 'Cloud Cache and VHDLocations' 'green' 'No conflict between Cloud Cache and VHDLocations.' -Source "$script:Learn/concepts-fslogix-cloud-cache") }
    }

    # 3 to 5 per location
    $n = 0
    foreach ($loc in $locations) {
        $n++; $h = Get-AVDTuneUncHost $loc; $tag = "fs.loc$n"; $t = "Share $loc"
        if (-not $h) { continue }
        $st = @{ Dns = $false; Smb = $false }
        Guard "$tag.dns" 3 "$t : DNS" {
            $d = & $F.Dns $h
            if ($d.Ok -and @($d.Addresses).Count -gt 0) { $st.Dns = $true; Add (New-AVDTuneFsRow "$tag.dns" 3 "$t : DNS" 'green' "$h resolves to $(@($d.Addresses) -join ', ')." -Source "$script:Learn/overview-prerequisites" -Verified $false -Note 'The test itself is AVDTune''s; Learn has no statement per check.') }
            else { Add (New-AVDTuneFsRow "$tag.dns" 3 "$t : DNS" 'red' "$h does not resolve ($($d.Error))." 'Check the DNS server of the VNet; for a private endpoint the zone privatelink.file.core.windows.net must resolve to the private IP.' -Verified $false) }
        }
        Guard "$tag.tcp" 3 "$t : TCP 445" {
            if (-not $st.Dns) { Add (New-AVDTuneFsRow "$tag.tcp" 3 "$t : TCP 445" 'info' 'Not tested: the name does not resolve.'); return }
            $c = & $F.Tcp $h 445
            if ($c.Ok) { Add (New-AVDTuneFsRow "$tag.tcp" 3 "$t : TCP 445" 'green' "Port 445 on $h is reachable." -Verified $false) }
            else { Add (New-AVDTuneFsRow "$tag.tcp" 3 "$t : TCP 445" 'red' "Port 445 on $h is not reachable ($($c.Error))." 'Open outbound 445 (firewall, NSG, ISP) or use the private endpoint.' -Verified $false) }
        }
        Guard "$tag.smb" 3 "$t : SMB session" {
            if (-not $st.Dns) { Add (New-AVDTuneFsRow "$tag.smb" 3 "$t : SMB session" 'info' 'Not tested: the name does not resolve.'); return }
            $p = & $F.ShareProbe $loc
            if ($p.Ok) { $st.Smb = $true; Add (New-AVDTuneFsRow "$tag.smb" 3 "$t : SMB session" 'green' 'The share can be opened from this master.' -Verified $false) }
            elseif ($p.Kind -eq 'Denied') { Add (New-AVDTuneFsRow "$tag.smb" 3 "$t : SMB session" 'yellow' 'The share refused this account. The master is not domain joined, so that is expected: the real access test is the storage check as a domain user.' 'Run the storage check (Azure sign-in) with a domain account.' -Verified $false) }
            else { Add (New-AVDTuneFsRow "$tag.smb" 3 "$t : SMB session" 'red' "The share could not be opened: $($p.Error)" 'Check the share name, the storage account and the network.' -Verified $false) }
        }
        Guard "$tag.kerberos" 3 "$t : Kerberos ticket" {
            $tickets = @(& $F.KerberosTickets)
            if ($tickets | Where-Object { $_ -like "*cifs/$h*" }) { Add (New-AVDTuneFsRow "$tag.kerberos" 3 "$t : Kerberos ticket" 'green' "A Kerberos ticket for cifs/$h exists." -Verified $false) }
            else { Add (New-AVDTuneFsRow "$tag.kerberos" 3 "$t : Kerberos ticket" 'info' "No ticket for cifs/$h in this session. A not joined master has none; the session hosts get it at the user's sign-in." -Verified $false) }
        }
        Guard "$tag.rw" 4 "$t : write test" {
            if (-not $RunWriteTests) { Add (New-AVDTuneFsRow "$tag.rw" 4 "$t : write test" 'info' 'Not run (it creates and deletes a test folder on the share; start it with the write tests).'); return }
            if (-not $st.Smb) { Add (New-AVDTuneFsRow "$tag.rw" 4 "$t : write test" 'yellow' 'Not run: this master has no access to the share. The storage check does it as a domain user.'); return }
            $r = & $F.ShareWriteTest $loc
            $failed = @($r.Steps | Where-Object { -not $_.Ok })
            if ($failed.Count -eq 0) { Add (New-AVDTuneFsRow "$tag.rw" 4 "$t : write test" 'green' 'Create folder, write, read and delete worked.' -Verified $false) }
            else { Add (New-AVDTuneFsRow "$tag.rw" 4 "$t : write test" 'red' "Failed at $($failed[0].Name): $($failed[0].Error)" 'Check the share permission (role) and the NTFS rights of the account.' -Verified $false) }
        }
        Guard "$tag.acl" 4 "$t : NTFS rights of the root" {
            if (-not $st.Smb) { Add (New-AVDTuneFsRow "$tag.acl" 4 "$t : NTFS rights of the root" 'info' 'Not read from the master. The storage check reads the ACL over Azure (REST, no key).'); return }
            $sddl = & $F.ShareAcl $loc
            if (-not $sddl) { Add (New-AVDTuneFsRow "$tag.acl" 4 "$t : NTFS rights of the root" 'yellow' 'The rights of the root could not be read.'); return }
            $c = Compare-AVDTuneFSLogixAcl -Sddl $sddl -UsersSids $UsersSids -AdminsSids $AdminsSids
            if ($c.Compliant) { Add (New-AVDTuneFsRow "$tag.acl" 4 "$t : NTFS rights of the root" 'green' 'The root matches Microsoft''s recommendation.' -Source "$script:Learn/how-to-configure-storage-permissions") }
            else { $worst = if (@($c.Findings | Where-Object Status -eq 'red').Count -gt 0) { 'red' } else { 'yellow' }; Add (New-AVDTuneFsRow "$tag.acl" 4 "$t : NTFS rights of the root" $worst (($c.Findings | ForEach-Object { $_.Text }) -join ' ') 'Set the recommended ACL in the storage check (shown as a diff first).' -Source "$script:Learn/how-to-configure-storage-permissions") }
        }
        Guard "$tag.vhdx" 5 "$t : VHDX test with frx" {
            if (-not $RunWriteTests) { Add (New-AVDTuneFsRow "$tag.vhdx" 5 "$t : VHDX test with frx" 'info' 'Not run (it creates a small VHDX on the share and deletes it).'); return }
            if (-not $st.Smb) { Add (New-AVDTuneFsRow "$tag.vhdx" 5 "$t : VHDX test with frx" 'yellow' 'Not run: this master has no access to the share. The storage check runs it as a domain user.'); return }
            $r = Invoke-AVDTuneFSLogixVhdxTest -Machine $Machine -F $F -Share $loc
            if ($r.Ok) { Add (New-AVDTuneFsRow "$tag.vhdx" 5 "$t : VHDX test with frx" 'green' $r.Message -Source "$script:Learn/utilities/frx/frx" -Verified $true -Note 'create-vhd and begin-/end-edit-profile are on the Learn frx page; writing inside the attached volume is not tested (the page does not say how the volume is addressed).') }
            else { Add (New-AVDTuneFsRow "$tag.vhdx" 5 "$t : VHDX test with frx" 'red' $r.Message 'Check the filter driver, the share rights and the free space on the share.' -Source "$script:Learn/utilities/frx/frx") }
        }
    }
    if ($locations.Count -eq 0 -and -not $cc) { Add (New-AVDTuneFsRow 'fs.loc' 3 'Share checks' 'info' 'No VHDLocations to check.') }

    # 6 redirections, Defender, admins
    Guard 'fs.redir' 6 'redirections.xml' {
        $target = Get-AVDTuneRedirectionsTarget $Machine
        if (-not $target) { Add (New-AVDTuneFsRow 'fs.redir' 6 'redirections.xml' 'info' 'No RedirXMLSourceFolder: no redirections.xml is used.' -Source "$script:Learn/concepts-redirections-xml"); return }
        $text = & $F.ReadText $target
        if ($null -eq $text) { Add (New-AVDTuneFsRow 'fs.redir' 6 'redirections.xml' 'yellow' "RedirXMLSourceFolder is set but $target cannot be read from this master." 'Write it with the editor or check the share.' -Source "$script:Learn/concepts-redirections-xml"); return }
        $v = Test-AVDTuneRedirectionsXml $text
        if ($v.Ok) { Add (New-AVDTuneFsRow 'fs.redir' 6 'redirections.xml' 'green' "$target is valid ($($v.Excludes.Count) excludes, $($v.Includes.Count) includes)." -Source "$script:Learn/concepts-redirections-xml") }
        else { Add (New-AVDTuneFsRow 'fs.redir' 6 'redirections.xml' 'red' ($v.Problems -join ' ') 'Correct the file in the editor.' -Source "$script:Learn/concepts-redirections-xml") }
    }
    Guard 'fs.defender' 6 'Defender exclusions' {
        $s = Get-AVDTuneFSLogixDefenderState -F $F -VhdLocations $locations
        if (-not $s.Readable) { Add (New-AVDTuneFsRow 'fs.defender' 6 'Defender exclusions' 'yellow' 'The Defender exclusions cannot be read (another antivirus, or a policy hides them). Check by hand against Microsoft''s list.' -Source $s.Source); return }
        $open = @($s.Items | Where-Object { -not $_.Present })
        if ($open.Count -eq 0) { Add (New-AVDTuneFsRow 'fs.defender' 6 'Defender exclusions' 'green' "All $(@($s.Items).Count) exclusions of Microsoft's list are set." -Source $s.Source) }
        else { Add (New-AVDTuneFsRow 'fs.defender' 6 'Defender exclusions' 'yellow' "$($open.Count) of $(@($s.Items).Count) exclusions are missing (e.g. $($open[0].Value))." 'Add them on the FSLogix page (Defender exclusions).' -Source $s.Source) }
    }
    Guard 'fs.admins' 6 'Local administrators excluded' {
        $g = Get-AVDTuneFSLogixGroups -F $F
        if ($null -eq $g.Exclude) { Add (New-AVDTuneFsRow 'fs.admins' 6 'Local administrators excluded' 'red' "The local group '$($g.ExcludeName)' does not exist: FSLogix is not installed." -Source $g.Source -Verified $false); return }
        if (@($g.Exclude) -contains $script:AdminsSid) { Add (New-AVDTuneFsRow 'fs.admins' 6 'Local administrators excluded' 'green' 'The local Administrators group is in the exclude list.' -Source $g.Source -Verified $false -Note 'Learn: the exclude list has no members by default; the group names are not printed on that page.') }
        else { Add (New-AVDTuneFsRow 'fs.admins' 6 'Local administrators excluded' 'yellow' 'The local Administrators group is not in the exclude list: administrators who sign in to a session host get a profile container (and can lock it).' 'Add the group to the exclude list on the FSLogix page.' -Source $g.Source -Verified $false) }
    }
    Add (New-AVDTuneFsRow 'fs.logon' 7 'Real sign-in of a test user' 'info' 'Not possible on the master (it is not domain joined). Test it on a session host after the rollout: sign in, then read the FSLogix log and frx list-redirects.' -Source "$script:Learn/tutorial-configure-profile-containers")
    $arr = @($rows)
    $c = [pscustomobject]@{ Green = @($arr | Where-Object Status -eq 'green').Count; Yellow = @($arr | Where-Object Status -eq 'yellow').Count; Red = @($arr | Where-Object Status -eq 'red').Count; Info = @($arr | Where-Object Status -eq 'info').Count }
    $overall = if ($c.Red -gt 0) { 'red' } elseif ($c.Yellow -gt 0) { 'yellow' } else { 'green' }
    [pscustomobject]@{ At = (& $Machine.Now).ToString('o'); Overall = $overall; Counts = $c; Rows = $arr; Passed = ($overall -eq 'green'); WriteTests = [bool]$RunWriteTests }
}

function Invoke-AVDTuneFSLogixVhdxTest {
    <# frx create-vhd on the share, attach (begin-edit-profile), detach (end-edit-profile), delete. The cookie is read from the output of begin-edit-profile (the format is not documented: Verified=false). #>
    param([Parameter(Mandatory)]$Machine, [Parameter(Mandatory)]$F, [Parameter(Mandatory)][string]$Share)
    $frx = & $F.FindFrx
    if (-not $frx) { return [pscustomobject]@{ Ok = $false; Message = 'frx.exe was not found in the FSLogix folder.' } }
    $trust = Test-AVDTuneToolTrust -Signature (& $F.VerifySignature $frx) -Name 'frx.exe'
    if (-not $trust.Ok) { return [pscustomobject]@{ Ok = $false; Message = "$($trust.Reason): it is not started." } }
    $file = $Share.TrimEnd('\') + '\avdtune-test-' + [guid]::NewGuid().ToString('N').Substring(0, 12) + '.vhdx'
    $created = $false; $attached = $false; $cookie = ''
    try {
        $r = & $Machine.Run $frx @('create-vhd', '-filename', $file, '-size-mbs', '50', '-dynamic', '1', '-label', 'AVDTuneTest') 120
        if ($r.ExitCode -ne 0) { return [pscustomobject]@{ Ok = $false; Message = "frx create-vhd failed ($($r.ExitCode)): $(([string]$r.Output).Trim())" } }
        $created = $true
        $r = & $Machine.Run $frx @('begin-edit-profile', '-filename', $file) 120
        if ($r.ExitCode -ne 0) { return [pscustomobject]@{ Ok = $false; Message = "The VHDX was created but could not be attached ($($r.ExitCode)): $(([string]$r.Output).Trim())" } }
        $attached = $true
        if ([string]$r.Output -match '(?i)cookie\D{0,6}(\d+)') { $cookie = $Matches[1] }
        if (-not $cookie) { return [pscustomobject]@{ Ok = $false; Message = 'The VHDX was attached but frx printed no cookie, so it cannot be detached by AVDTune: detach it by hand (frx end-edit-profile) and delete the test file.' } }
        $r = & $Machine.Run $frx @('end-edit-profile', '-cookie', $cookie, '-filename', $file) 120
        if ($r.ExitCode -ne 0) { return [pscustomobject]@{ Ok = $false; Message = "The VHDX could not be detached ($($r.ExitCode)): $(([string]$r.Output).Trim())" } }
        $attached = $false
        [pscustomobject]@{ Ok = $true; Message = 'A 50 MB test VHDX was created, attached, detached and deleted on the share (the driver and the locking work).' }
    }
    finally {
        if ($attached -and $cookie) { try { [void](& $Machine.Run $frx @('end-edit-profile', '-cookie', $cookie, '-filename', $file) 120) } catch { } }
        if ($created -and -not $attached) { try { & $F.DeleteFile $file } catch { } }
    }
}

function Save-AVDTuneFSLogixTestRun {
    <# Stores a test result: a run record (Plan 'FSLogix-Test'), state.json (FSLogixTest, read by the healthcheck) and a change log note. The test does not change the master: LastChange stays. #>
    [CmdletBinding()]
    param([string]$Root = (Get-AVDTuneRoot), [Parameter(Mandatory)]$Result, [string]$User, [string]$SnapshotId, [Parameter(Mandatory)]$Machine)
    $state = Get-AVDTuneState $Root
    $slim = @($Result.Rows | ForEach-Object { [pscustomobject]@{ Id = $_.Id; Section = 'FSLogix'; Title = $_.Title; Mode = 'Test'; Status = $(switch ($_.Status) { 'green' { 'Compliant' } 'info' { 'Compliant' } default { 'NonCompliant' } }); Before = $_.Status; After = $null; Message = $_.Reason; Reboot = $false; WhatIf = $false; At = $Result.At } })
    $run = [pscustomobject][ordered]@{ Id = $null; Plan = 'FSLogix-Test'; Kind = 'FSLogix-Test'; Started = $Result.At; Ended = $Result.At; User = $User; SnapshotId = $SnapshotId; WhatIf = $false; ImageVersion = $state.ImageVersion; Reboot = $false; Results = $slim; Overall = $Result.Overall }
    $saved = Add-AVDTuneRun -Root $Root -Run $run
    $rec = [ordered]@{ At = $Result.At; Overall = $Result.Overall; Red = $Result.Counts.Red; Yellow = $Result.Counts.Yellow; Green = $Result.Counts.Green; RunId = [string]$run.Id; User = $User; WriteTests = $Result.WriteTests
        OpenIds = @($Result.Rows | Where-Object { $_.Status -in 'red', 'yellow' } | ForEach-Object { $_.Id }) }
    [void](Set-AVDTuneState -Root $Root -Values @{ FSLogixTest = $rec })
    if ($state.ImageVersion) { [void](Add-AVDTuneChangeLogEntry -Root $Root -Version $state.ImageVersion -Category 'FSLogix' -Component 'FSLogix-Test' -ChangeType Note -Text "FSLogix function test: $($Result.Overall) ($($Result.Counts.Red) red, $($Result.Counts.Yellow) yellow, $($Result.Counts.Green) green)" -User $User -SnapshotId $SnapshotId -RunId ([string]$run.Id) -Source Note) }
    [pscustomobject]$rec
}

function Get-AVDTuneFSLogixTestRecord { param([string]$Root = (Get-AVDTuneRoot)) Get-AVDTuneProp (Get-AVDTuneState $Root) 'FSLogixTest' }

#endregion

#region real adapter

function New-AVDTuneFSLogixAdapter {
    <#
        The real adapter. NOT exercised by the checks beyond construction: the download, the share, Defender and local group calls are written from the
        documentation and have to be tried on a throw-away VM (docs\test-vm.md). Download only from download.microsoft.com over https, no redirect followed.
    #>
    $a = [ordered]@{ Kind = 'Real' }
    $a.LatestRelease = {
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            $req = [System.Net.HttpWebRequest]::Create('https://aka.ms/fslogix_download')
            $req.Method = 'HEAD'; $req.AllowAutoRedirect = $false; $req.Timeout = 30000
            try { $resp = $req.GetResponse() } catch [System.Net.WebException] { $resp = $_.Exception.Response; if (-not $resp) { throw } }
            try { $loc = [string]$resp.Headers['Location'] } finally { $resp.Close() }
            if (-not $loc) { return @{ Ok = $false; Url = ''; Error = 'aka.ms returned no redirect.' } }
            @{ Ok = $true; Url = $loc; Error = '' }
        }
        catch { @{ Ok = $false; Url = ''; Error = $_.Exception.Message } }
    }
    $a.NewTempFolder = {
        param($Root)
        $dir = Join-Path (Join-Path $Root 'temp') ('fslogix-' + [guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($dir); $dir
    }
    $a.IsProtectedFolder = { param($Dir, $Root) Test-AVDTuneAdminOnlyPath -Path $Dir -Base (Split-Path $Root -Parent) }
    $a.Download = {
        param($Url, $Dest, $MaxBytes)
        try {
            $uri = [Uri]$Url
            if ($uri.Scheme -ne 'https' -or $uri.Host -ne 'download.microsoft.com') { return @{ Ok = $false; Error = 'Only https://download.microsoft.com is allowed.' } }
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            $req = [System.Net.HttpWebRequest]::Create($uri); $req.AllowAutoRedirect = $false; $req.Timeout = 120000; $req.ReadWriteTimeout = 120000
            $resp = $req.GetResponse()
            try {
                if ($resp.ContentLength -gt $MaxBytes) { return @{ Ok = $false; Error = 'The file is larger than expected.' } }
                $in = $resp.GetResponseStream(); $out = [IO.File]::Create($Dest); $total = 0
                try { $buf = New-Object byte[] 81920; while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) { $total += $n; if ($total -gt $MaxBytes) { throw 'The download is larger than expected.' }; $out.Write($buf, 0, $n) } } finally { $out.Dispose(); $in.Dispose() }
            }
            finally { $resp.Close() }
            @{ Ok = $true; Error = ''; Bytes = $total }
        }
        catch { @{ Ok = $false; Error = $_.Exception.Message } }
    }
    $a.Expand = {
        param($Zip, $Dir)
        try {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $base = [IO.Path]::GetFullPath($Dir).TrimEnd('\') + '\'
            [void][IO.Directory]::CreateDirectory($Dir)
            $z = [IO.Compression.ZipFile]::OpenRead($Zip)
            try {
                foreach ($e in $z.Entries) {
                    $target = [IO.Path]::GetFullPath((Join-Path $Dir $e.FullName))
                    if (-not $target.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) { throw "The package has an entry outside the folder ($($e.FullName))." }
                    if ($e.FullName.EndsWith('/')) { [void][IO.Directory]::CreateDirectory($target); continue }
                    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
                    [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $target, $true)
                }
            }
            finally { $z.Dispose() }
            @{ Ok = $true; Error = '' }
        }
        catch { @{ Ok = $false; Error = $_.Exception.Message } }
    }
    $a.FindInstaller = { param($Dir) $p = Join-Path $Dir 'x64\Release\FSLogixAppsSetup.exe'; if (Test-Path -LiteralPath $p -PathType Leaf) { $p } else { $null } }
    $a.FindFrx = { $p = Join-Path (Get-AVDTuneSystemFolder ProgramFiles) 'FSLogix\Apps\frx.exe'; if ((Test-Path -LiteralPath $p -PathType Leaf) -and (Test-AVDTuneAdminOnlyPath -Path $p -Base (Get-AVDTuneSystemFolder ProgramFiles))) { $p } else { $null } }
    $a.FileVersion = { param($Path) [string](Get-Item -LiteralPath $Path).VersionInfo.ProductVersion }
    $a.VerifySignature = {
        param($Path)
        $s = Get-AuthenticodeSignature -LiteralPath $Path
        $orig = ''; try { $orig = [string](Get-Item -LiteralPath $Path).VersionInfo.OriginalFilename } catch { }
        [pscustomobject]@{ Valid = ($s.Status -eq 'Valid'); Status = [string]$s.Status; Subject = $(if ($s.SignerCertificate) { [string]$s.SignerCertificate.Subject } else { '' }); Issuer = $(if ($s.SignerCertificate) { [string]$s.SignerCertificate.Issuer } else { '' }); OriginalFilename = $orig }
    }
    $a.RemoveFolder = { param($Dir) Remove-AVDTuneFolderNoFollowSafe $Dir }
    $a.ReadText = { param($Path) Assert-AVDTuneRedirectionsPath $Path; if (Test-Path -LiteralPath $Path -PathType Leaf) { [IO.File]::ReadAllText($Path) } else { $null } }
    $a.WriteText = {
        param($Path, $Text)
        Assert-AVDTuneRedirectionsPath $Path
        $dir = Split-Path $Path -Parent
        if (-not (Test-Path -LiteralPath $dir)) { throw "The folder $dir does not exist." }
        $tmp = "$Path.avdtune.tmp"
        [IO.File]::WriteAllText($tmp, $Text, (New-Object Text.UTF8Encoding $false))
        if (Test-Path -LiteralPath $Path) { [IO.File]::Delete($Path) }
        [IO.File]::Move($tmp, $Path)
    }
    $a.DeleteFile = { param($Path) Assert-AVDTuneRedirectionsPath $Path; if (Test-Path -LiteralPath $Path) { [IO.File]::Delete($Path) } }
    $a.Dns = { param($H) try { @{ Ok = $true; Addresses = @([Net.Dns]::GetHostAddresses($H) | ForEach-Object { $_.IPAddressToString }); Error = '' } } catch { @{ Ok = $false; Addresses = @(); Error = $_.Exception.Message } } }
    $a.Tcp = {
        param($H, $Port)
        $c = New-Object Net.Sockets.TcpClient
        try { $w = $c.BeginConnect($H, $Port, $null, $null); if (-not $w.AsyncWaitHandle.WaitOne(5000)) { return @{ Ok = $false; Error = 'timeout' } }; $c.EndConnect($w); @{ Ok = $true; Error = '' } }
        catch { @{ Ok = $false; Error = $_.Exception.Message } } finally { $c.Close() }
    }
    $a.ShareProbe = {
        param($Unc)
        try { [void][IO.Directory]::GetFileSystemEntries($Unc); @{ Ok = $true; Kind = ''; Error = '' } }
        catch [UnauthorizedAccessException] { @{ Ok = $false; Kind = 'Denied'; Error = 'access denied' } }
        catch { @{ Ok = $false; Kind = 'Failed'; Error = $_.Exception.Message } }
    }
    $a.ShareWriteTest = {
        param($Unc)
        $steps = New-Object System.Collections.ArrayList
        $dir = Join-Path $Unc ('avdtune-test-' + [guid]::NewGuid().ToString('N').Substring(0, 12)); $file = Join-Path $dir 'test.txt'
        $try = { param($n, $b) try { & $b; [void]$steps.Add(@{ Name = $n; Ok = $true; Error = '' }); $true } catch { [void]$steps.Add(@{ Name = $n; Ok = $false; Error = $_.Exception.Message }); $false } }
        if (& $try 'create folder' { [void][IO.Directory]::CreateDirectory($dir) }) {
            if (& $try 'write file' { [IO.File]::WriteAllText($file, 'avdtune') }) { [void](& $try 'read file' { if ([IO.File]::ReadAllText($file) -ne 'avdtune') { throw 'the content differs' } }); [void](& $try 'delete file' { [IO.File]::Delete($file) }) }
            [void](& $try 'delete folder' { [IO.Directory]::Delete($dir) })
        }
        @{ Steps = @($steps) }
    }
    $a.ShareAcl = { param($Unc) try { (Get-Acl -LiteralPath $Unc -ErrorAction Stop).Sddl } catch { $null } }
    $a.KeyMapAdd = {
        # Maps the share with the storage account key (fallback, confirmed by the administrator for one run): WNetAddConnection2, so the key is never on a command line
        param($Unc, $User, $Key)
        if (-not ('AVDTune.Mpr' -as [type])) { Add-Type -Namespace AVDTune -Name Mpr -MemberDefinition @"
[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] public class NETRESOURCE { public int dwScope; public int dwType; public int dwDisplayType; public int dwUsage; public string lpLocalName; public string lpRemoteName; public string lpComment; public string lpProvider; }
[DllImport("mpr.dll", CharSet = CharSet.Unicode)] public static extern int WNetAddConnection2(NETRESOURCE r, string password, string user, int flags);
[DllImport("mpr.dll", CharSet = CharSet.Unicode)] public static extern int WNetCancelConnection2(string name, int flags, bool force);
"@ }
        $nr = New-Object AVDTune.Mpr+NETRESOURCE; $nr.dwType = 1; $nr.lpRemoteName = $Unc
        $rc = [AVDTune.Mpr]::WNetAddConnection2($nr, $Key, $User, 0)
        if ($rc -ne 0) { throw "WNetAddConnection2 returned $rc" }
    }
    $a.KeyMapRemove = { param($Unc) if ('AVDTune.Mpr' -as [type]) { [void][AVDTune.Mpr]::WNetCancelConnection2($Unc, 0, $true) } }
    $a.ShareTestAsUser = {
        # The access test as a domain user: LogonUser with new credentials (network only, like runas /netonly), then the folder test as that identity. The password
        # stays a SecureString until the call and is zeroed. Written from the API documentation: to be tried on the test VM.
        param($Unc, $User, [System.Security.SecureString]$Password, $Dc)
        if (-not ('AVDTune.Logon' -as [type])) { Add-Type -Namespace AVDTune -Name Logon -MemberDefinition @"
[DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)] public static extern bool LogonUser(string user, string domain, IntPtr password, int logonType, int provider, out IntPtr token);
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool CloseHandle(IntPtr handle);
"@ }
        $ln = Split-AVDTuneLogonName $User; $domain = $ln.Domain; $name = $ln.Name
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($Password); $token = [IntPtr]::Zero
        try { $ok = [AVDTune.Logon]::LogonUser($name, $domain, $bstr, 9, 3, [ref]$token); $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error() }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocUnicode($bstr) }
        if (-not $ok) { return @{ LogonFailed = $true; Error = "Windows error $err"; Steps = @() } }
        $id = $null
        try {
            $steps = New-Object System.Collections.ArrayList
            $dir = Join-Path $Unc ('avdtune-test-' + [guid]::NewGuid().ToString('N').Substring(0, 12)); $file = Join-Path $dir 'test.txt'
            $id = New-Object Security.Principal.WindowsIdentity($token)
            [Security.Principal.WindowsIdentity]::RunImpersonated($id.AccessToken, [Action]{
                    $try = { param($n, $b) try { & $b; [void]$steps.Add(@{ Name = $n; Ok = $true; Error = '' }); $true } catch { [void]$steps.Add(@{ Name = $n; Ok = $false; Error = $_.Exception.Message }); $false } }
                    if (& $try 'create folder' { [void][IO.Directory]::CreateDirectory($dir) }) {
                        if (& $try 'write file' { [IO.File]::WriteAllText($file, 'avdtune') }) { [void](& $try 'read file' { if ([IO.File]::ReadAllText($file) -ne 'avdtune') { throw 'the content differs' } }); [void](& $try 'delete file' { [IO.File]::Delete($file) }) }
                        [void](& $try 'delete folder' { [IO.Directory]::Delete($dir) })
                    }
                }.GetNewClosure())
            # LogonType 9 (new credentials, network only) accepts any password here: it is only checked when the share is accessed
            @{ LogonFailed = $false; Error = ''; Steps = @($steps); PasswordCheckedAtAccess = $true }
        }
        finally { if ($id) { $id.Dispose() }; [void][AVDTune.Logon]::CloseHandle($token) }
    }
    $a.KerberosTickets = { try { @((& (Join-Path (Get-AVDTuneSystemFolder System) 'klist.exe') 2>$null) | Where-Object { $_ -match 'cifs/' }) } catch { @() } }
    $a.DefenderGet = { try { $p = Get-MpPreference -ErrorAction Stop; @{ Paths = @($p.ExclusionPath | Where-Object { $_ -and $_ -notmatch 'Administrators' }); Processes = @($p.ExclusionProcess | Where-Object { $_ -and $_ -notmatch 'Administrators' }) } } catch { $null } }
    $a.DefenderAdd = { param($Kind, $Value) if ($Kind -eq 'Process') { Add-MpPreference -ExclusionProcess $Value -ErrorAction Stop } else { Add-MpPreference -ExclusionPath $Value -ErrorAction Stop } }
    $a.DefenderRemove = { param($Kind, $Value) if ($Kind -eq 'Process') { Remove-MpPreference -ExclusionProcess $Value -ErrorAction Stop } else { Remove-MpPreference -ExclusionPath $Value -ErrorAction Stop } }
    $a.LocalGroupMembers = {
        param($Name)
        try { $g = [ADSI]"WinNT://./$Name,group"; if (-not $g.Path) { return @{ Exists = $false; Members = @() } }; @{ Exists = $true; Members = @($g.Invoke('Members') | ForEach-Object { $b = New-Object Security.Principal.SecurityIdentifier(([ADSI]$_).InvokeGet('objectSid'), 0); $b.Value }) } }
        catch { @{ Exists = $false; Members = @() } }
    }
    $a.LocalGroupAdd = { param($Name, $Sid) $g = [ADSI]"WinNT://./$Name,group"; $g.Add("WinNT://$Sid") }
    $a.LocalGroupRemove = { param($Name, $Sid) $g = [ADSI]"WinNT://./$Name,group"; $g.Remove("WinNT://$Sid") }
    [pscustomobject]$a
}

function Remove-AVDTuneFolderNoFollowSafe([string]$Dir) { Remove-AVDTuneFolderNoFollow $Dir }

#endregion

Export-ModuleMember -Function Get-AVDTuneFSLogixSettingCatalog, Test-AVDTuneFSLogixUncPath, Test-AVDTuneFSLogixValue, Get-AVDTuneFSLogixInfo, Get-AVDTuneFSLogixSettingsState,
    New-AVDTuneFSLogixRegStep, Get-AVDTuneFSLogixGroupMembers, Get-AVDTuneFSLogixUndoPath, Set-AVDTuneFSLogixSettings, Undo-AVDTuneFSLogixSettings, Get-AVDTuneFSLogixLastChange, Test-AVDTuneSid, Get-AVDTuneFSLogixGroups,
    Get-AVDTuneFSLogixGroupChoices, Set-AVDTuneFSLogixGroupMember, Get-AVDTuneRedirectionTemplate, Test-AVDTuneRedirectionPath, New-AVDTuneRedirectionsXml,
    Test-AVDTuneRedirectionsXml, Get-AVDTuneRedirectionsTarget, Assert-AVDTuneRedirectionsPath, Write-AVDTuneUndoFile, Split-AVDTuneLogonName, Save-AVDTuneRedirections, Undo-AVDTuneRedirections, Get-AVDTuneFSLogixDefenderList,
    Get-AVDTuneFSLogixDefenderState, Set-AVDTuneFSLogixDefender, Undo-AVDTuneFSLogixDefender, Get-AVDTuneFSLogixLatest, Invoke-AVDTuneFSLogixInstall, Invoke-AVDTuneFSLogixInstallRecorded,
    ConvertFrom-AVDTuneSddl, New-AVDTuneFSLogixRecommendedSddl, Compare-AVDTuneFSLogixAcl, Get-AVDTuneFSLogixLocations, Format-AVDTuneAce, Invoke-AVDTuneFSLogixTest,
    Invoke-AVDTuneFSLogixVhdxTest, Save-AVDTuneFSLogixTestRun, Get-AVDTuneFSLogixTestRecord, New-AVDTuneFSLogixAdapter
