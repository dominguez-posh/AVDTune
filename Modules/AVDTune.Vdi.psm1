<#
    AVDTune VDI components (docs\plans\avdtune.md, section 11 phase 6; issue 56 part 2; docs\vdi-components.md): the pieces a Windows 11 multi-session master needs for
    Microsoft Teams (new), multimedia redirection and OneDrive. Per component: detection of the actual state (version, installed, prerequisites), install or update, remove and
    undo where documented, registry settings with Test/Apply/Undo.

      * Components: teams (teamsbootstrapper.exe -p / -x, IsWVDEnvironment; disableAutoUpdate stays with the update block), webrtc (Remote Desktop WebRTC Redirector Service, MSI), mmr (Remote Desktop
        Multimedia Redirection Service, MSI, and the browser extension policy), onedrive (per machine, through winget with --scope machine, Run key and policies).
      * Every access to the master goes through the machine adapter ($m: registry) and the component adapter ($V: redirects, download, signature, files, run).
        Tests\Fakes\FakeVdi.ps1 has the fake; New-AVDTuneVdiAdapter is the real one and is NOT exercised by the checks (no download, no install).
      * Downloads only from fixed Microsoft hosts over https. The entry link (aka.ms or go.microsoft.com) is followed BY HAND, every hop is checked (https, fixed host list, no port,
        no user info), and the last hop has to be download.microsoft.com. The file lands in a new protected folder, is checked (Authenticode: Microsoft Corporation, issuer, original
        file name; an MSI carries none, which is checked as well), held open without write/delete share until its process ended, and checked again right before the start.
        Programs start through the central child environment (New-AVDTuneChildStartInfo, issue 47) in a job object.
      * Changes sit behind the write gate, set LastChange (also on failure), write a run record and a change log entry (category VDI). Undo goes back to the state found before the
        first change: remove when the component was not there; no undo for a component that was there (older builds are not offered by Microsoft).
#>

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'AVDTune.psm1')
Import-Module (Join-Path $PSScriptRoot 'AVDTune.Updates.psm1')
Import-Module (Join-Path $PSScriptRoot 'AVDTune.Trust.psm1')
Import-Module (Join-Path $PSScriptRoot 'AVDTune.Office.psm1')   # its adapter: protected folder, download from download.microsoft.com, hold file

$script:Learn = 'https://learn.microsoft.com/en-us'
$script:Src = @{
    TeamsAvd = "$script:Learn/azure/virtual-desktop/teams-on-avd"
    TeamsVdi = "$script:Learn/microsoftteams/teams-client-vdi-requirements-deploy"
    Mmr = "$script:Learn/azure/virtual-desktop/multimedia-redirection-video-playback-calls"
    OneDriveMachine = "$script:Learn/sharepoint/per-machine-installation"
    OneDriveVdi = "$script:Learn/sharepoint/sync-vdi-support"
}
$script:RedirectHosts = @('aka.ms', 'go.microsoft.com', 'download.microsoft.com')
$script:FinalHost = 'download.microsoft.com'
$script:MaxHops = 5
$script:Uninstall = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')
$script:EdgeExtension = 'joeclbldhdmoijbaagobkhlpfjglcihd'
$script:ChromeExtension = 'lfmemoeeciijgkjkgbgikoonlkabmlno'
$script:EdgeUpdateUrl = 'https://edge.microsoft.com/extensionwebstorebase/v1/crx'
$script:ChromeUpdateUrl = 'https://clients2.google.com/service/update2/crx'

#region catalog

# Kind Exe = a program that is run (Teams bootstrapper), Msi = installed with msiexec, Winget = per machine through winget. Entry = the first link (fixed host, followed by hand).
$script:Components = @(
    [pscustomobject]@{ Key = 'teams'; Title = 'Microsoft Teams (new) for VDI'; Kind = 'Exe'; Entry = 'https://go.microsoft.com/fwlink/?linkid=2243204'; File = 'teamsbootstrapper.exe'; MaxBytes = 60MB; Source = $script:Src.TeamsVdi
        Text = 'Installs new Teams for all users (teamsbootstrapper.exe -p, always the latest client) and sets IsWVDEnvironment so that media optimization loads. Automatic Teams updates are switched off by the update block. The WebRTC Redirector Service below is the fallback for clients without the new optimization.' }
    [pscustomobject]@{ Key = 'webrtc'; Title = 'Remote Desktop WebRTC Redirector Service'; Kind = 'Msi'; Entry = 'https://aka.ms/msrdcwebrtcsvc/msi'; File = 'webrtc-redirector.msi'; MaxBytes = 100MB; DisplayName = 'Remote Desktop WebRTC Redirector Service'; Source = $script:Src.TeamsAvd
        Text = 'Needed on every session host for Teams media optimization with WebRTC (and as the fallback of new Teams). Does not update itself: install the newer MSI over it.' }
    [pscustomobject]@{ Key = 'mmr'; Title = 'Multimedia redirection'; Kind = 'Msi'; Entry = 'https://aka.ms/avdmmr/msi'; File = 'mmr-host.msi'; MaxBytes = 100MB; DisplayName = 'Remote Desktop Multimedia Redirection Service'; Source = $script:Src.Mmr
        Text = 'Host component for video playback and call redirection, and the browser extension (force installed by a machine policy for Edge, optionally Chrome). The service does not update itself; the extension does. Edge and Chrome must be closed during the install.' }
    [pscustomobject]@{ Key = 'onedrive'; Title = 'OneDrive per machine'; Kind = 'Winget'; Entry = ''; File = ''; MaxBytes = 0; Source = $script:Src.OneDriveMachine
        Text = 'Installs the sync app once for all users (winget Microsoft.OneDrive, machine scope = OneDriveSetup.exe /allusers), starts it for every user at sign-in and sets the VDI policies of the Microsoft articles.' }
)
function Get-AVDTuneVdiComponents { @($script:Components) }
function Get-AVDTuneVdiComponent([string]$Key) { $c = @($script:Components | Where-Object { $_.Key -ceq $Key }); if ($c.Count -ne 1) { throw "Unknown VDI component '$Key'." }; $c[0] }

function New-AVDTuneVdiRow([string]$Id, [string]$Title, [string]$Status, [string]$Reason, [string]$Fix, [string]$Source, [bool]$Verified, [string]$Note = '') {
    [pscustomobject]@{ Id = $Id; Title = $Title; Status = $Status; Reason = $Reason; Fix = $Fix; Source = $Source; Verified = $Verified; Note = $Note }
}

#endregion

#region links (pure)

function Test-AVDTuneVdiUrl {
    # A https link on one of the fixed hosts: no port, no user info, no fragment. Returns the Uri or $null.
    param([string]$Url, [string[]]$Hosts = $script:RedirectHosts)
    if (-not $Url -or $Url.Length -gt 2000) { return $null }
    $uri = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri)) { return $null }
    if ($uri.Scheme -ne 'https' -or $uri.Host -cnotin $Hosts -or -not $uri.IsDefaultPort -or $uri.UserInfo -or $uri.Fragment) { return $null }
    $uri
}

function Get-AVDTuneVdiNextUrl {
    <#
        Pure: one hop of a redirect. $Current is the address that was asked, $Location the header of the answer (absolute or relative). The next address must be https on a fixed host
        (aka.ms, go.microsoft.com, download.microsoft.com). download.microsoft.com ends the chain: no query, a path under /download/ without dots-dots, a file with the extension of the kind.
        Returns @{ Ok; Url; Final; Error }.
    #>
    param([Parameter(Mandatory)][string]$Current, [string]$Location, [ValidateSet('Exe', 'Msi')][string]$Kind = 'Msi')
    $bad = { param($e) [pscustomobject]@{ Ok = $false; Url = ''; Final = $false; Error = $e } }
    if (-not $Location -or $Location.Length -gt 2000) { return & $bad 'The redirect has no usable address.' }
    $base = $null
    if (-not [Uri]::TryCreate($Current, [UriKind]::Absolute, [ref]$base)) { return & $bad 'The address that was asked is not valid.' }
    $next = $null
    if (-not [Uri]::TryCreate($base, $Location, [ref]$next)) { return & $bad 'The redirect address is not valid.' }
    $uri = Test-AVDTuneVdiUrl -Url $next.AbsoluteUri
    if (-not $uri) { return & $bad "The redirect leads to '$($next.Host)' (or is not https): only aka.ms, go.microsoft.com and download.microsoft.com are followed." }
    if ($uri.Host -ceq $script:FinalHost) {
        $ext = if ($Kind -eq 'Exe') { 'exe' } else { 'msi' }
        $ok = $false
        try { $ok = [regex]::IsMatch($uri.AbsolutePath, "\A/download/[A-Za-z0-9._%/-]{1,250}\.$ext\z", 'IgnoreCase', [TimeSpan]::FromMilliseconds(200)) -and $uri.AbsolutePath -notmatch '\.\.' -and -not $uri.Query } catch { $ok = $false }
        if (-not $ok) { return & $bad "The file address on download.microsoft.com is not the expected .$ext file." }
        return [pscustomobject]@{ Ok = $true; Url = $uri.AbsoluteUri; Final = $true; Error = '' }
    }
    [pscustomobject]@{ Ok = $true; Url = $uri.AbsoluteUri; Final = $false; Error = '' }
}

function Get-AVDTuneVdiVersionFromUrl {
    # The first dotted four-part version in the file name of a download address ('' when there is none)
    param([string]$Url)
    $name = ''; try { $name = [IO.Path]::GetFileName(([Uri]$Url).AbsolutePath) } catch { return '' }
    try { $m = [regex]::Match($name, '(?<![0-9])(\d{1,5}\.\d{1,5}\.\d{1,6}\.\d{1,6})(?![0-9])', 'None', [TimeSpan]::FromMilliseconds(200)); if ($m.Success) { return $m.Groups[1].Value } } catch { }
    ''
}

function Compare-AVDTuneVdiVersion([string]$A, [string]$B) {
    # -1, 0, 1; $null when one is not a version
    # 3 and 4 part versions are padded to 4 parts (missing parts = 0) first: [version] alone sees a 3 part version as lower than the same with a 0 appended
    $x = $null; $y = $null
    if (-not [version]::TryParse($A, [ref]$x) -or -not [version]::TryParse($B, [ref]$y)) { return $null }
    $x = New-Object Version $x.Major, $x.Minor, ([Math]::Max($x.Build, 0)), ([Math]::Max($x.Revision, 0))
    $y = New-Object Version $y.Major, $y.Minor, ([Math]::Max($y.Build, 0)), ([Math]::Max($y.Revision, 0))
    $x.CompareTo($y)
}

#endregion

#region detection

function Get-AVDTuneVdiUninstallEntry {
    # The Uninstall entry with exactly this DisplayName (both registry views): @{ Name; Version; ProductCode } or $null
    param([Parameter(Mandatory)]$Machine, [Parameter(Mandatory)][string]$DisplayName)
    foreach ($root in $script:Uninstall) {
        foreach ($sub in @(& $Machine.RegSubKeys $root)) {
            if ($sub -notmatch '^[A-Za-z0-9{}._-]{1,80}\z') { continue }
            $n = [string](& $Machine.RegGet "$root\$sub" 'DisplayName')
            if ($n -ceq $DisplayName) { return [pscustomobject]@{ Name = $n; Version = [string](& $Machine.RegGet "$root\$sub" 'DisplayVersion'); ProductCode = $(if ($sub -match '^\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}\z') { $sub } else { '' }) } }
        }
    }
    $null
}

function Get-AVDTuneVdiVcRuntime {
    # The Visual C++ 2015-2022 runtime (x64) as a version text or ''
    param([Parameter(Mandatory)]$Machine)
    $k = 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64'
    if ([string](& $Machine.RegGet $k 'Installed') -ne '1') { return '' }
    $maj = & $Machine.RegGet $k 'Major'; $min = & $Machine.RegGet $k 'Minor'; $bld = & $Machine.RegGet $k 'Bld'
    if ($null -eq $maj -or $null -eq $min -or $null -eq $bld) { return '' }
    "$maj.$min.$bld"
}

function Get-AVDTuneVdiState {
    # What is on the master now (read only): @{ Key; Installed; Version; ProductCode; PerMachine }
    param([Parameter(Mandatory)]$Machine, [Parameter(Mandatory)]$V, [Parameter(Mandatory)][string]$Key)
    $c = Get-AVDTuneVdiComponent $Key
    switch ($Key) {
        'teams' { $v = [string](& $V.AppxVersion 'MSTeams'); return [pscustomobject]@{ Key = $Key; Installed = [bool]$v; Version = $v; ProductCode = ''; PerMachine = $true } }
        'onedrive' {
            $path = [string](& $V.OneDrivePath)
            $present = [bool]($path -and (& $V.Exists $path))
            $v = if ($present) { [string](& $V.FileVersion $path) } else { '' }
            if (-not $v) { $v = [string](& $Machine.RegGet 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\OneDrive' 'Version') }
            return [pscustomobject]@{ Key = $Key; Installed = $present; Version = $(if ($present) { $v } else { '' }); ProductCode = ''; PerMachine = $present }
        }
        default {
            $e = Get-AVDTuneVdiUninstallEntry -Machine $Machine -DisplayName $c.DisplayName
            return [pscustomobject]@{ Key = $Key; Installed = [bool]$e; Version = $(if ($e) { $e.Version } else { '' }); ProductCode = $(if ($e) { $e.ProductCode } else { '' }); PerMachine = $true }
        }
    }
}

#endregion

#region settings (registry values with Test/Apply/Undo)

function Get-AVDTuneVdiSettingDefs {
    # The registry values per component. Optional ones are only set when asked for. Kind Value (DWord/String) or Extension (JSON of ExtensionSettings).
    param([Parameter(Mandatory)][string]$Key, $V)
    $odRun = if ($V -and $V.PSObject.Properties['OneDrivePath']) { [string](& $V.OneDrivePath) } else { 'C:\Program Files\Microsoft OneDrive\OneDrive.exe' }
    switch ($Key) {
        'teams' {
            @(
                [pscustomobject]@{ Id = 'vdi.teams.iswvdenvironment'; Kind = 'Value'; Path = 'HKLM:\SOFTWARE\Microsoft\Teams'; Name = 'IsWVDEnvironment'; Type = 'DWord'; Value = 1; Optional = $false; Title = 'Teams IsWVDEnvironment = 1'; Why = 'Without this value Teams does not load the media optimization on a session host.'; Source = $script:Src.TeamsAvd; Verified = $true }
            )
        }
        'mmr' {
            @(
                [pscustomobject]@{ Id = 'vdi.mmr.edge'; Kind = 'Extension'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; Name = 'ExtensionSettings'; Type = 'String'; Value = $null; ExtensionId = $script:EdgeExtension; UpdateUrl = $script:EdgeUpdateUrl; Optional = $false; Title = 'Edge: force install the multimedia redirection extension'; Why = 'Enables the browser extension silently for all users (policy ExtensionSettings, force_installed).'; Source = $script:Src.Mmr; Verified = $true; Note = 'The Learn article gives the JSON of the policy; that the machine policy is stored as the registry value ExtensionSettings (REG_SZ) under HKLM\SOFTWARE\Policies\Microsoft\Edge is the documented Edge policy layout, not stated on this page.' }
                [pscustomobject]@{ Id = 'vdi.mmr.chrome'; Kind = 'Extension'; Path = 'HKLM:\SOFTWARE\Policies\Google\Chrome'; Name = 'ExtensionSettings'; Type = 'String'; Value = $null; ExtensionId = $script:ChromeExtension; UpdateUrl = $script:ChromeUpdateUrl; Optional = $true; Title = 'Chrome: force install the multimedia redirection extension'; Why = 'The same for Google Chrome, only when Chrome is used on the master.'; Source = $script:Src.Mmr; Verified = $true; Note = 'Registry layout of the Chrome policy: see the Edge entry.' }
            )
        }
        'onedrive' {
            @(
                [pscustomobject]@{ Id = 'vdi.onedrive.run'; Kind = 'Value'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; Name = 'OneDrive'; Type = 'String'; Value = "`"$odRun`" /background"; Optional = $false; Title = 'OneDrive starts at sign-in for every user'; Why = 'The per-machine sync app is started for each user at sign-in (Run value of the Microsoft article for virtual desktops).'; Source = $script:Src.OneDriveVdi; Verified = $true }
                [pscustomobject]@{ Id = 'vdi.onedrive.filesondemand'; Kind = 'Value'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\OneDrive'; Name = 'FilesOnDemandEnabled'; Type = 'DWord'; Value = 1; Optional = $false; Title = 'OneDrive Files On-Demand on'; Why = 'Keeps the synced files out of the profile container until they are opened.'; Source = $script:Src.OneDriveVdi; Verified = $false; Note = 'FilesOnDemandEnabled is the documented OneDrive policy; the two Learn articles named here do not list it.' }
                [pscustomobject]@{ Id = 'vdi.onedrive.silent'; Kind = 'Value'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\OneDrive'; Name = 'SilentAccountConfig'; Type = 'DWord'; Value = 1; Optional = $true; Title = 'OneDrive silent sign-in'; Why = 'Signs users in with their Windows account. Only for a master that is Microsoft Entra joined: turn it off when it is not.'; Source = $script:Src.OneDriveVdi; Verified = $true }
            )
        }
        default { @() }
    }
}

function Get-AVDTuneVdiJsonSerializer {
    Add-Type -AssemblyName System.Web.Extensions
    $s = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $s.MaxJsonLength = 1MB; $s.RecursionLimit = 20
    $s
}

function Test-AVDTuneVdiKey($Dictionary, [string]$Key) { @($Dictionary.Keys) -ccontains $Key }

function Add-AVDTuneVdiExtensionEntry {
    <#
        The text of the ExtensionSettings policy with the extension force installed: other entries and other fields of this entry stay as they are. An empty policy gives a new one. Returns
        @{ Ok; Text; Error }. Refused (nothing is built) when the existing text is not a JSON object or the extension is set to blocked or removed by someone else.
    #>
    param([string]$Existing, [Parameter(Mandatory)][string]$ExtensionId, [Parameter(Mandatory)][string]$UpdateUrl)
    $fail = { param($e) [pscustomobject]@{ Ok = $false; Text = ''; Error = $e } }
    if ($ExtensionId -notmatch '^[a-p]{32}\z' -or -not (Test-AVDTuneVdiUrl -Url $UpdateUrl -Hosts @('edge.microsoft.com', 'clients2.google.com'))) { return & $fail 'The extension id or update address is not valid.' }
    $s = Get-AVDTuneVdiJsonSerializer
    $root = $null
    if ([string]::IsNullOrWhiteSpace($Existing)) { $root = [System.Collections.Generic.Dictionary[string,object]]::new() }
    else {
        try { $root = $s.DeserializeObject($Existing) } catch { return & $fail "The existing ExtensionSettings policy is not valid JSON ($($_.Exception.Message)); it is not changed." }
        if ($root -isnot [System.Collections.IDictionary]) { return & $fail 'The existing ExtensionSettings policy is not a JSON object; it is not changed.' }
    }
    $entry = $null
    if ((Test-AVDTuneVdiKey $root $ExtensionId)) {
        $entry = $root[$ExtensionId]
        if ($entry -isnot [System.Collections.IDictionary]) { return & $fail 'The existing entry of the extension is not a JSON object; it is not changed.' }
        $mode = if ((Test-AVDTuneVdiKey $entry 'installation_mode')) { [string]$entry['installation_mode'] } else { '' }
        if ($mode -cin 'blocked', 'removed') { return & $fail "The extension is set to '$mode' by an existing policy. Change that by hand if it is not meant." }
    }
    else { $entry = [System.Collections.Generic.Dictionary[string,object]]::new(); $root[$ExtensionId] = $entry }
    $entry['installation_mode'] = 'force_installed'; $entry['update_url'] = $UpdateUrl
    [pscustomobject]@{ Ok = $true; Text = $s.Serialize($root); Error = '' }
}

function Remove-AVDTuneVdiExtensionEntry {
    <#
        Undo of Add-AVDTuneVdiExtensionEntry by merge, only at our own entry: the entry goes back to what it was before the first apply (read from the earlier text) or is removed. Other entries, also
        those that came after the apply, stay. The whole value is removed only when it was not there before and nothing but our entry is left. Returns @{ Ok; Action Set|Remove|None; Text; Error }.
        Invalid JSON now: nothing is changed (Ok false).
    #>
    param([string]$Current, [bool]$PreviousExists, [string]$PreviousText, [Parameter(Mandatory)][string]$ExtensionId)
    $fail = { param($e) [pscustomobject]@{ Ok = $false; Action = 'None'; Text = ''; Error = $e } }
    if ($ExtensionId -notmatch '^[a-p]{32}\z') { return & $fail 'The extension id is not valid.' }
    if ([string]::IsNullOrWhiteSpace($Current)) { return [pscustomobject]@{ Ok = $true; Action = 'None'; Text = ''; Error = '' } }
    $s = Get-AVDTuneVdiJsonSerializer
    try { $root = $s.DeserializeObject($Current) } catch { return & $fail "The ExtensionSettings policy is not valid JSON now ($($_.Exception.Message)); it is not changed." }
    if ($root -isnot [System.Collections.IDictionary]) { return & $fail 'The ExtensionSettings policy is not a JSON object now; it is not changed.' }
    $before = $null
    if ($PreviousExists -and -not [string]::IsNullOrWhiteSpace($PreviousText)) {
        try { $p = $s.DeserializeObject($PreviousText) } catch { return & $fail 'The earlier ExtensionSettings text is not valid JSON; it is not changed.' }
        if ($p -is [System.Collections.IDictionary] -and (Test-AVDTuneVdiKey $p $ExtensionId)) { $before = $p[$ExtensionId] }
    }
    if ($null -ne $before) { $root[$ExtensionId] = $before } elseif (Test-AVDTuneVdiKey $root $ExtensionId) { [void]$root.Remove($ExtensionId) }
    if (@($root.Keys).Count -eq 0 -and -not $PreviousExists) { return [pscustomobject]@{ Ok = $true; Action = 'Remove'; Text = ''; Error = '' } }
    [pscustomobject]@{ Ok = $true; Action = 'Set'; Text = $s.Serialize($root); Error = '' }
}

function Test-AVDTuneVdiExtensionEntry {
    param([string]$Existing, [Parameter(Mandatory)][string]$ExtensionId, [Parameter(Mandatory)][string]$UpdateUrl)
    if ([string]::IsNullOrWhiteSpace($Existing)) { return $false }
    try { $root = (Get-AVDTuneVdiJsonSerializer).DeserializeObject($Existing) } catch { return $false }
    if ($root -isnot [System.Collections.IDictionary] -or -not (Test-AVDTuneVdiKey $root $ExtensionId)) { return $false }
    $e = $root[$ExtensionId]
    $e -is [System.Collections.IDictionary] -and (Test-AVDTuneVdiKey $e 'installation_mode') -and $e['installation_mode'] -ceq 'force_installed' -and (Test-AVDTuneVdiKey $e 'update_url') -and $e['update_url'] -ceq $UpdateUrl
}

function Get-AVDTuneVdiSteps {
    # Steps with Test/Apply/Undo for the chosen definitions. $Previous: id -> @{ Exists; Value; Type } (what was found before the first change).
    param([Parameter(Mandatory)]$Defs, [hashtable]$Previous = @{}, [switch]$ForUndo)
    foreach ($d in @($Defs)) {
        $def = $d; $prev = $Previous[$def.Id]
        $test = if ($def.Kind -eq 'Extension') {
            # for the undo a text that is not valid JSON counts as "applied" so that the engine runs the undo, which refuses and ends Failed (nothing is changed)
            { param($m) $v = & $m.RegGet $def.Path $def.Name; $ok = (Test-AVDTuneVdiExtensionEntry -Existing ([string]$v) -ExtensionId $def.ExtensionId -UpdateUrl $def.UpdateUrl); if (-not $ok -and $ForUndo -and -not [string]::IsNullOrWhiteSpace([string]$v)) { $ok = -not (Remove-AVDTuneVdiExtensionEntry -Current ([string]$v) -PreviousExists $false -PreviousText '' -ExtensionId $def.ExtensionId).Ok }; @{ Compliant = $ok; State = $v } }.GetNewClosure()
        }
        else { { param($m) $v = & $m.RegGet $def.Path $def.Name; @{ Compliant = ($null -ne $v -and [string]$v -ceq [string]$def.Value); State = $v } }.GetNewClosure() }
        $apply = if ($def.Kind -eq 'Extension') {
            { param($m) $cur = & $m.RegGet $def.Path $def.Name; $r = Add-AVDTuneVdiExtensionEntry -Existing ([string]$cur) -ExtensionId $def.ExtensionId -UpdateUrl $def.UpdateUrl; if (-not $r.Ok) { throw $r.Error }; & $m.RegSet $def.Path $def.Name $r.Text 'String' }.GetNewClosure()
        }
        else { { param($m) & $m.RegSet $def.Path $def.Name $def.Value $def.Type }.GetNewClosure() }
        $undo = if ($def.Kind -eq 'Extension') {
            {
                param($m)
                $cur = & $m.RegGet $def.Path $def.Name
                $r = Remove-AVDTuneVdiExtensionEntry -Current ([string]$cur) -PreviousExists ([bool]($prev -and $prev.Exists)) -PreviousText $(if ($prev -and $prev.Exists) { [string]$prev.Value } else { '' }) -ExtensionId $def.ExtensionId
                if (-not $r.Ok) { throw $r.Error }
                if ($r.Action -eq 'Remove') { & $m.RegRemove $def.Path $def.Name } elseif ($r.Action -eq 'Set') { & $m.RegSet $def.Path $def.Name $r.Text 'String' }
            }.GetNewClosure()
        }
        else { { param($m) if ($prev -and $prev.Exists) { & $m.RegSet $def.Path $def.Name $prev.Value $prev.Type } else { & $m.RegRemove $def.Path $def.Name } }.GetNewClosure() }
        New-AVDTuneStep -Id $def.Id -Section VdiComponents -Title $def.Title -Why $def.Why -SourceUrl $def.Source -Test $test -Apply $apply -Undo $undo
    }
}

function Get-AVDTuneVdiPrevious {
    # @{ Exists; Value; Type } of a value as stored; a type that cannot be put back is an error (nothing is changed)
    param([Parameter(Mandatory)]$Machine, [Parameter(Mandatory)]$Def)
    $raw = $null
    if ($Machine.PSObject.Properties['RegGetRaw'] -and $Machine.RegGetRaw) { $raw = & $Machine.RegGetRaw $Def.Path $Def.Name }
    if (-not $raw) { $v = & $Machine.RegGet $Def.Path $Def.Name; if ($null -eq $v) { return @{ Exists = $false; Value = $null; Type = '' } }; $raw = @{ Value = $v; Kind = $(if ($v -is [string]) { 'String' } elseif ($v -is [long]) { 'QWord' } else { 'DWord' }) } }
    $kind = [string]$raw.Kind
    if ($kind -cnotin 'DWord', 'QWord', 'String', 'ExpandString') { throw "The earlier value of $($Def.Name) has the registry type $kind, which AVDTune cannot put back; nothing was changed." }
    $val = $raw.Value
    if ($kind -ceq 'DWord') { $l = [int64]$val; if ($l -gt [int]::MaxValue) { $l -= 4294967296 }; $val = [int]$l }
    @{ Exists = $true; Value = $val; Type = $kind }
}

function Get-AVDTuneVdiSettingsUndoPath([string]$Root, [string]$Key) { Join-Path $Root "config\vdi-$Key-settings-undo.json" }

function Read-AVDTuneVdiSettingsUndo {
    # Typed read of the undo record: a record that is not exactly what the apply wrote is an error and changes nothing. Returns id -> @{ Exists; Value; Type }; $null when there is no record.
    param([string]$Root, [string]$Key)
    $u = Read-AVDTuneJson (Get-AVDTuneVdiSettingsUndoPath $Root $Key)
    if (-not $u) { return $null }
    $ids = @(Get-AVDTuneVdiSettingDefs -Key $Key | ForEach-Object Id)
    $pp = Get-AVDTuneProp $u 'Previous'
    if ($pp -isnot [System.Management.Automation.PSCustomObject]) { throw "The undo record of the $Key settings (config\vdi-$Key-settings-undo.json) is not usable. Nothing was changed." }
    $prev = @{}
    foreach ($p in $pp.PSObject.Properties) {
        $e = $p.Value; $exists = Get-AVDTuneProp $e 'Exists'; $type = Get-AVDTuneProp $e 'Type'; $val = Get-AVDTuneProp $e 'Value'
        $ok = ($p.Name -cin $ids) -and $exists -is [bool] -and ((-not $exists) -or ($type -is [string] -and (
                    ($type -ceq 'DWord' -and ($val -is [int] -or ($val -is [long] -and $val -ge [int]::MinValue -and $val -le [uint32]::MaxValue))) -or
                    ($type -ceq 'QWord' -and ($val -is [int] -or $val -is [long])) -or ($type -cin 'String', 'ExpandString' -and $val -is [string]))))
        if (-not $ok) { throw "The undo record of the $Key settings (config\vdi-$Key-settings-undo.json) is not usable: '$($p.Name)' has no typed value. Nothing was changed." }
        if ($exists -and $type -ceq 'DWord') { $l = [int64]$val; if ($l -gt [int]::MaxValue) { $l -= 4294967296 }; $val = [int]$l }
        $prev[$p.Name] = @{ Exists = $exists; Value = $val; Type = [string]$type }
    }
    $prev
}

function Get-AVDTuneVdiSettingsRows {
    param([Parameter(Mandatory)]$Machine, [Parameter(Mandatory)]$V, [Parameter(Mandatory)][string]$Key)
    foreach ($d in @(Get-AVDTuneVdiSettingDefs -Key $Key -V $V)) {
        $step = @(Get-AVDTuneVdiSteps -Defs @($d))[0]
        $t = & $step.Test $Machine
        $ok = ($t -is [System.Collections.IDictionary]) -and [bool]$t.Compliant
        if ($ok) { New-AVDTuneVdiRow $d.Id $d.Title 'green' 'Set as recommended.' '' $d.Source ([bool]$d.Verified) ([string](Get-AVDTuneProp $d 'Note')) }
        else { New-AVDTuneVdiRow $d.Id $d.Title $(if ($d.Optional) { 'info' } else { 'yellow' }) $(if ($d.Optional) { 'Not set (optional).' } else { 'Not set.' }) 'Press "Set recommended settings".' $d.Source ([bool]$d.Verified) ([string](Get-AVDTuneProp $d 'Note')) }
    }
}

function Invoke-AVDTuneVdiSettings {
    <#
        Mode Apply: the recommended values of the component (plus the optional ones named in -Optional), Mode Undo: the values found before the first apply. Behind the write gate; LastChange is set
        before the attempt (a failed write may have changed the master) and after; run record and change log entry per changed step. WhatIf changes nothing and needs no gate.
        The undo record keeps the first values found and gets the values of definitions that were not in it yet (never overwritten).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Machine, [Parameter(Mandatory)]$V, [Parameter(Mandatory)][string]$Key, [ValidateSet('Apply', 'Undo')][string]$Mode = 'Apply', [string[]]$Optional = @(), [string]$Root = (Get-AVDTuneRoot), [string]$User, [string]$SnapshotId, [switch]$WhatIf)
    $comp = Get-AVDTuneVdiComponent $Key
    $all = @(Get-AVDTuneVdiSettingDefs -Key $Key -V $V)
    if ($all.Count -eq 0) { throw "$($comp.Title) has no settings." }
    foreach ($o in @($Optional)) { if ($o -cnotin @($all | ForEach-Object Id)) { throw "'$o' is not a setting of $($comp.Title)." } }
    $defs = @($all | Where-Object { -not $_.Optional -or $_.Id -cin @($Optional) })
    $undoPath = Get-AVDTuneVdiSettingsUndoPath $Root $Key
    $prev = @{}
    if ($Mode -eq 'Undo') {
        $rec = Read-AVDTuneVdiSettingsUndo -Root $Root -Key $Key
        if ($null -eq $rec) { throw "There is nothing to undo: no $($comp.Title) settings change was recorded." }
        $prev = $rec; $defs = @($all | Where-Object { $prev.ContainsKey($_.Id) })
    }
    else {
        $rec = Read-AVDTuneVdiSettingsUndo -Root $Root -Key $Key
        $known = if ($rec) { $rec } else { @{} }
        foreach ($d in $defs) { if ($known.ContainsKey($d.Id)) { $prev[$d.Id] = $known[$d.Id] } else { $prev[$d.Id] = Get-AVDTuneVdiPrevious -Machine $Machine -Def $d } }
        foreach ($k in @($known.Keys)) { if (-not $prev.ContainsKey($k)) { $prev[$k] = $known[$k] } }
    }
    $steps = @(Get-AVDTuneVdiSteps -Defs $defs -Previous $prev -ForUndo:($Mode -eq 'Undo'))
    $changeOwner = $false
    if (-not $WhatIf) {
        if (-not (Test-AVDTuneWriteAllowed)) { throw 'The snapshot gate is not confirmed: AVDTune is read only until a snapshot newer than its last change is confirmed on the Overview.' }
        $changeOwner = Start-AVDTuneChange -Root $Root   # marker while the master is written (snapshot gate, #27/#81), cleared in finally
    }
    try {
    if (-not $WhatIf) {
        [void](Set-AVDTuneState -Root $Root -Values @{ LastChange = (& $Machine.Now).ToString('o') })
        if ($Mode -eq 'Apply' -and $prev.Count -gt 0 -and (-not $rec -or @($defs | Where-Object { -not $rec.ContainsKey($_.Id) }).Count -gt 0)) {
            $out = [ordered]@{}; foreach ($k in $prev.Keys) { $out[$k] = [ordered]@{ Exists = $prev[$k].Exists; Value = $prev[$k].Value; Type = $prev[$k].Type } }
            Write-AVDTuneFile $undoPath ([ordered]@{ At = (& $Machine.Now).ToString('o'); Previous = $out } | ConvertTo-Json -Depth 6)
        }
    }
    $results = foreach ($s in $steps) { Invoke-AVDTuneStep -Step $s -Machine $Machine -Mode $Mode -WhatIf:$WhatIf }
    $plan = "$($comp.Title) settings$(if ($Mode -eq 'Undo') { ' undo' })"
    $run = [pscustomobject]@{ Plan = $plan; WhatIf = [bool]$WhatIf; Results = @($results) }
    if (-not $WhatIf) {
        $state = Get-AVDTuneState $Root
        $ended = (& $Machine.Now).ToString('o')
        [void](Set-AVDTuneState -Root $Root -Values @{ LastChange = $ended })
        $saved = [pscustomobject][ordered]@{ Id = $null; Plan = $plan; Started = $ended; Ended = $ended; User = $User; SnapshotId = $SnapshotId; WhatIf = $false; ImageVersion = $state.ImageVersion; Reboot = $false; Results = @($results) }
        [void](Add-AVDTuneRun -Root $Root -Run $saved)
        foreach ($r in @($results | Where-Object { $_.Status -in 'Changed', 'Reverted', 'Failed' })) {
            if (-not $state.ImageVersion) { break }
            $type = if ($r.Status -eq 'Failed') { 'Note' } else { 'Changed' }
            $text = switch ($r.Status) { 'Failed' { "$($r.Title): FAILED - $($r.Message)" } 'Reverted' { "Undo: $($r.Title)" } default { $r.Title } }
            [void](Add-AVDTuneChangeLogEntry -Root $Root -Version $state.ImageVersion -Category 'VDI' -Component $comp.Title -ChangeType $type -Text $text -User $User -SnapshotId $SnapshotId -RunId ([string]$saved.Id) -Source Step)
        }
        if ($Mode -eq 'Undo' -and @($results | Where-Object { $_.Status -eq 'Failed' }).Count -eq 0) { Remove-Item -LiteralPath $undoPath -Force -ErrorAction SilentlyContinue }
    }
    $run
    }
    finally { Stop-AVDTuneChange -Root $Root -Owner $changeOwner }
}

#endregion

#region rows (the test of the page)

function Get-AVDTuneVdiRows {
    <#
        The test of one component: installed (the pill of the component), version against the latest known one, prerequisites and settings. Status green | yellow | red | info (the pills of the
        FSLogix page): green = installed and current, yellow = an update or a setting is open, red = missing, info = cannot be told. $Latest: result of Get-AVDTuneVdiLatest or $null. Read only.
    #>
    param([Parameter(Mandatory)]$Machine, [Parameter(Mandatory)]$V, [Parameter(Mandatory)][string]$Key, $Latest)
    $c = Get-AVDTuneVdiComponent $Key
    $teamsKeyPath = 'HKLM:\SOFTWARE\Microsoft\Teams'
    $s = Get-AVDTuneVdiState -Machine $Machine -V $V -Key $Key
    $rows = New-Object System.Collections.ArrayList
    $add = { param($r) [void]$rows.Add($r) }
    $id = "$Key.installed"
    if (-not $s.Installed) {
        & $add (New-AVDTuneVdiRow $id $c.Title 'red' 'Not installed on this master.' 'Press "Install or update".' $c.Source $true)
    }
    else {
        $detail = "Version $($s.Version)."
        $latestOk = $Latest -and (Get-AVDTuneProp $Latest 'Ok') -eq $true -and (Get-AVDTuneProp $Latest 'Version')
        if ($Key -eq 'teams') { & $add (New-AVDTuneVdiRow $id $c.Title 'info' "$detail Install or update always fetches the latest client (-p); whether it is the newest is not told by Microsoft in a way AVDTune can read." '' $c.Source $true) }
        elseif ($Key -eq 'onedrive') { & $add (New-AVDTuneVdiRow $id $c.Title 'info' "$detail Per machine. The Updates page updates it with winget; the newest version is not read here." '' $c.Source $true) }
        elseif ($latestOk) {
            $cmp = Compare-AVDTuneVdiVersion $s.Version ([string]$Latest.Version)
            if ($null -eq $cmp) { & $add (New-AVDTuneVdiRow $id $c.Title 'info' "$detail The version could not be compared with $($Latest.Version)." '' $c.Source $false) }
            elseif ($cmp -lt 0) { & $add (New-AVDTuneVdiRow $id $c.Title 'yellow' "$detail Update available: $($Latest.Version)." 'Press "Install or update" (the MSI replaces the installed one).' $c.Source $true) }
            else { & $add (New-AVDTuneVdiRow $id $c.Title 'green' "$detail Current ($($Latest.Version))." '' $c.Source $true) }
        }
        else { & $add (New-AVDTuneVdiRow $id $c.Title 'info' "$detail Whether it is current is only known after Check for updates." 'Press "Check for updates".' $c.Source $false 'The service does not update itself; the download address of Microsoft names the version only in some cases.') }
    }
    $vc = Get-AVDTuneVdiVcRuntime $Machine
    if ($Key -in 'teams', 'mmr') {
        $min = '14.32.31332'
        if (-not $vc) { & $add (New-AVDTuneVdiRow "$Key.vcredist" 'Visual C++ Redistributable' 'yellow' 'The 2015-2022 runtime (x64) was not found.' 'Install the latest supported Microsoft Visual C++ Redistributable (media optimization needs it).' $script:Src.TeamsAvd $false 'The registry layout (VisualStudio\14.0\VC\Runtimes\x64) is from experience, not from Learn.') }
        elseif ((Compare-AVDTuneVdiVersion $vc $min) -ge 0) { & $add (New-AVDTuneVdiRow "$Key.vcredist" 'Visual C++ Redistributable' 'green' "Version $vc." '' $script:Src.Mmr $false 'The registry layout (VisualStudio\14.0\VC\Runtimes\x64) is from experience, not from Learn.') }
        else { & $add (New-AVDTuneVdiRow "$Key.vcredist" 'Visual C++ Redistributable' 'yellow' "Version $vc, Learn names $min or later for multimedia redirection." 'Install the latest supported Microsoft Visual C++ Redistributable.' $script:Src.Mmr $false 'The registry layout (VisualStudio\14.0\VC\Runtimes\x64) is from experience, not from Learn.') }
    }
    if ($Key -eq 'teams') {
        $w = Get-AVDTuneVdiState -Machine $Machine -V $V -Key 'webrtc'
        if ($w.Installed) { & $add (New-AVDTuneVdiRow 'teams.webrtc' 'WebRTC Redirector Service' 'green' "Installed ($($w.Version)): new Teams can fall back to WebRTC." '' $script:Src.TeamsAvd $true) }
        else { & $add (New-AVDTuneVdiRow 'teams.webrtc' 'WebRTC Redirector Service' 'yellow' 'Not installed. With new Teams Learn advises to install it too, for clients without the new optimization.' 'Install it in the card below.' $script:Src.TeamsAvd $true) }
        $au = & $Machine.RegGet $teamsKeyPath 'disableAutoUpdate'
        if ($null -ne $au -and [string]$au -eq '1') { & $add (New-AVDTuneVdiRow 'teams.autoupdate' 'Teams updates itself' 'green' 'Off (disableAutoUpdate = 1): Teams comes with the image and is updated here or on the Updates page.' '' $script:Src.TeamsVdi $true 'Set by the update block (Update block page), which owns this value; AVDTune does not set it a second time here.') }
        else { & $add (New-AVDTuneVdiRow 'teams.autoupdate' 'Teams updates itself' 'yellow' 'On: Teams would update itself on a non-persistent session host (disableAutoUpdate is not 1).' 'Turn on the update block on the Update block page: it sets disableAutoUpdate = 1 for the image and puts the earlier value back when it is lifted.' $script:Src.TeamsVdi $true 'Only Teams builds above 23306.3314.2555.9628 read the value.') }
        $fsl = [string](& $Machine.RegGet 'HKLM:\SOFTWARE\FSLogix\Apps' 'InstallVersion')
        if ($fsl) {
            $cmp = Compare-AVDTuneVdiVersion $fsl '2.9.8716.30241'
            if ($null -ne $cmp -and $cmp -lt 0) { & $add (New-AVDTuneVdiRow 'teams.fslogix' 'FSLogix version for new Teams' 'yellow' "FSLogix $fsl is older than 2.9.8716.30241 (2210 hotfix 3)." 'Update FSLogix on the FSLogix page.' $script:Src.TeamsAvd $true) }
            elseif ($null -ne $cmp) { & $add (New-AVDTuneVdiRow 'teams.fslogix' 'FSLogix version for new Teams' 'green' "FSLogix $fsl (2.9.8716.30241 or later is needed with new Teams)." '' $script:Src.TeamsAvd $true) }
        }
        else { & $add (New-AVDTuneVdiRow 'teams.fslogix' 'FSLogix version for new Teams' 'info' 'FSLogix is not installed (or its version is not readable). With profile management and new Teams it must be 2.9.8716.30241 or later.' '' $script:Src.TeamsAvd $true) }
    }
    if ($Key -eq 'mmr') { & $add (New-AVDTuneVdiRow 'mmr.browsers' 'Edge and Chrome closed' 'info' 'Learn: make sure Edge and Chrome are not running during the install. AVDTune checks it before it starts.' '' $script:Src.Mmr $true) }
    if ($Key -eq 'onedrive') {
        $fsl = [string](& $Machine.RegGet 'HKLM:\SOFTWARE\FSLogix\Apps' 'InstallVersion')
        & $add (New-AVDTuneVdiRow 'onedrive.fslogix' 'FSLogix' $(if ($fsl) { 'green' } else { 'yellow' }) $(if ($fsl) { "FSLogix $fsl is installed (OneDrive on non-persistent hosts needs the latest FSLogix)." } else { 'FSLogix was not found. Non-persistent hosts need the latest FSLogix for OneDrive.' }) $(if ($fsl) { '' } else { 'Install FSLogix on the FSLogix page.' }) $script:Src.OneDriveVdi $true)
    }
    foreach ($r in @(Get-AVDTuneVdiSettingsRows -Machine $Machine -V $V -Key $Key)) { & $add $r }
    @($rows)
}

function Get-AVDTuneVdiSummaryStatus {
    # The pill of the component card: red when missing, yellow when anything is open, else the status of the installed row
    param($Rows)
    $r = @($Rows); if ($r.Count -eq 0) { return 'info' }
    if ($r[0].Status -eq 'red') { return 'red' }
    if (@($r | Where-Object { $_.Status -in 'yellow', 'red' }).Count -gt 0) { return 'yellow' }
    [string]$r[0].Status
}

#endregion

#region latest (network, read only)

function Get-AVDTuneVdiLatest {
    # The address Microsoft's entry link leads to now (followed by hand, nothing downloaded) and the version in its file name, if any. Not for Teams or OneDrive.
    param([Parameter(Mandatory)]$V, [Parameter(Mandatory)][string]$Key)
    $c = Get-AVDTuneVdiComponent $Key
    if ($c.Kind -ne 'Msi') { return [pscustomobject]@{ Ok = $false; Url = ''; Version = ''; Error = 'Not applicable.' } }
    try { $r = & $V.Resolve $c.Entry $c.Kind } catch { return [pscustomobject]@{ Ok = $false; Url = ''; Version = ''; Error = $_.Exception.Message } }
    if (-not $r.Ok) { return [pscustomobject]@{ Ok = $false; Url = ''; Version = ''; Error = [string]$r.Error } }
    if (-not (Test-AVDTuneVdiUrl -Url ([string]$r.Url) -Hosts @($script:FinalHost))) { return [pscustomobject]@{ Ok = $false; Url = ''; Version = ''; Error = 'The adapter returned an address that is not on download.microsoft.com.' } }
    [pscustomobject]@{ Ok = $true; Url = [string]$r.Url; Version = (Get-AVDTuneVdiVersionFromUrl ([string]$r.Url)); Error = '' }
}

#endregion

#region install, update, remove

function Test-AVDTuneVdiPackageTrust {
    # Pure: the signature of the downloaded file. The Teams bootstrapper: Microsoft Corporation and its original file name; an MSI: Microsoft Corporation and NO original file name (an MSI has none).
    param($Signature, [Parameter(Mandatory)]$Component)
    if ($Component.Kind -eq 'Exe') { return Test-AVDTuneToolTrust -Signature $Signature -Name $Component.File }
    Test-AVDTuneToolTrust -Signature $Signature -Name 'vdi-msi' -OriginalFilenamePattern '^\z'
}

function Test-AVDTuneMsiIdentity {
    <#
        Pure: the Property table of an MSI (ProductName, Manufacturer, ProductVersion) against the component: ProductName must be exactly the product of the component, Manufacturer exactly
        Microsoft Corporation, and the version must not be lower than the installed one (an unreadable version is refused when something is installed). Returns @{ Ok; Reason; Code }.
    #>
    param($Properties, [Parameter(Mandatory)]$Component, [bool]$Installed = $false, [string]$InstalledVersion)
    $bad = { param($r, $c) [pscustomobject]@{ Ok = $false; Reason = $r; Code = $c } }
    if ($null -eq $Properties -or $Properties -isnot [System.Collections.IDictionary]) { return & $bad 'The Property table of the MSI could not be read' 'BadPackage' }
    $get = { param($k) if (Test-AVDTuneVdiKey $Properties $k) { [string]$Properties[$k] } else { '' } }
    $name = & $get 'ProductName'; $man = & $get 'Manufacturer'; $ver = & $get 'ProductVersion'
    if ($name -cne $Component.DisplayName) { return & $bad "The MSI is the product '$name', not '$($Component.DisplayName)'" 'BadPackage' }
    if ($man -cne 'Microsoft Corporation') { return & $bad "The MSI names the manufacturer '$man'" 'BadPackage' }
    if ($Installed) {
        if (-not $InstalledVersion) { return & $bad 'Something is installed but its version is not readable, so the MSI cannot be checked against it' 'BadPackage' }
        $cmp = Compare-AVDTuneVdiVersion $ver $InstalledVersion
        if ($null -eq $cmp) { return & $bad "The MSI version '$ver' cannot be compared with the installed $InstalledVersion" 'BadPackage' }
        if ($cmp -lt 0) { return & $bad "The MSI is version $ver, older than the installed $InstalledVersion" 'Downgrade' }
    }
    [pscustomobject]@{ Ok = $true; Reason = ''; Code = '' }
}

function Test-AVDTuneMsiHeader {
    # An MSI is an OLE compound file: D0 CF 11 E0 A1 B1 1A E1
    param([byte[]]$Bytes)
    $m = [byte[]](0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1)
    if ($null -eq $Bytes -or $Bytes.Count -lt 8) { return $false }
    for ($i = 0; $i -lt 8; $i++) { if ($Bytes[$i] -ne $m[$i]) { return $false } }
    $true
}

function Invoke-AVDTuneVdiPackage {
    <#
        Install/update (Mode Install) or remove (Mode Remove) of an Exe or Msi component. Entry link -> followed by hand -> download into a new protected folder -> (MSI: header) -> file held open ->
        signature of the file and of msiexec.exe by full path -> start -> signature again right before the start -> result -> state check. The folder is removed at the end.
        Returns @{ Status Changed|Unchanged|Failed; Message; Code; Before; After; Reboot }. Never throws for expected problems.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Machine, [Parameter(Mandatory)]$V, [Parameter(Mandatory)][string]$Key, [ValidateSet('Install', 'Remove')][string]$Mode = 'Install', [string]$Root = (Get-AVDTuneRoot), [scriptblock]$Progress)
    $c = Get-AVDTuneVdiComponent $Key
    $say = { param($t) if ($Progress) { & $Progress $t } }
    $before = Get-AVDTuneVdiState -Machine $Machine -V $V -Key $Key
    $out = { param($st, $msg, $code, $reboot) [pscustomobject]@{ Status = $st; Message = $msg; Code = $code; Before = $before; After = (Get-AVDTuneVdiState -Machine $Machine -V $V -Key $Key); Reboot = [bool]$reboot } }
    if ($c.Kind -eq 'Winget') { return Invoke-AVDTuneVdiWinget -Machine $Machine -V $V -Key $Key -Mode $Mode }
    if ($Mode -eq 'Remove' -and -not $before.Installed) { return & $out 'Unchanged' "$($c.Title) is not installed." '' $false }
    if ($Key -eq 'mmr' -and $Mode -eq 'Install') {
        $busy = @(& $V.RunningProcesses @('msedge', 'chrome'))
        if ($busy.Count -gt 0) { return & $out 'Failed' "Microsoft Edge or Google Chrome is running ($($busy -join ', ')). Close it (also in the background) and try again: Learn requires that for the install." 'BrowserRunning' $false }
    }
    if ($Key -ne 'teams' -and $Mode -eq 'Remove' -and -not $before.ProductCode) { return & $out 'Failed' "The product code of $($c.Title) was not found in the registry: it is not removed." 'NoProductCode' $false }
    if ($c.Kind -eq 'Msi' -and $Mode -eq 'Remove') {
        # nothing is downloaded or held: only msiexec.exe (Windows file, by full path) is checked and started with the product code read from the registry
        try {
            $runner = [string](& $V.MsiexecPath)
            $tm = Test-AVDTuneToolTrust -Signature (& $V.VerifySignature $runner) -Name 'msiexec.exe'
            if (-not $tm.Ok) { return & $out 'Failed' "$($tm.Reason): it is not started." 'BadSignature' $false }
            & $say "Removing $($c.Title) ..."
            $tm2 = Test-AVDTuneToolTrust -Signature (& $V.VerifySignature $runner) -Name 'msiexec.exe'
            if (-not $tm2.Ok) { return & $out 'Failed' "$($tm2.Reason): it is not started." 'BadSignature' $false }
            $run = & $V.Run $runner @('/x', $before.ProductCode, '/qn', '/norestart') 1800
            if ($run.ExitCode -eq -1) { return & $out 'Failed' 'msiexec did not finish in time. The removal can still be running in the Windows Installer service: wait until it is done, then press Test.' 'Timeout' $false }
            if ($run.ExitCode -notin 0, 3010, 1641) { return & $out 'Failed' "msiexec returned $($run.ExitCode).$(if ($run.ExitCode -eq 1618) { ' Another installation is running; wait for it and try again.' }) $([string]$run.Output)".Trim() "Exit$($run.ExitCode)" $false }
            if ((Get-AVDTuneVdiState -Machine $Machine -V $V -Key $Key).Installed) { return & $out 'Failed' "The program finished but $($c.Title) is still there." 'StillInstalled' ($run.ExitCode -ne 0) }
            return & $out 'Changed' "Removed (was $($before.Version))." '' ($run.ExitCode -ne 0)
        }
        catch { return & $out 'Failed' $_.Exception.Message 'Error' $false }
    }
    $dir = $null
    try {
        & $say "Looking up $($c.Title) at Microsoft ..."
        $r = & $V.Resolve $c.Entry $c.Kind
        if (-not $r.Ok) { return & $out 'Failed' "The download address could not be followed: $($r.Error)" 'NoLink' $false }
        if (-not (Test-AVDTuneVdiUrl -Url ([string]$r.Url) -Hosts @($script:FinalHost))) { return & $out 'Failed' 'The download address is not on download.microsoft.com over https.' 'NoLink' $false }
        $dir = & $V.NewTempFolder $Root
        if (-not $dir -or -not (& $V.IsProtectedFolder $dir $Root)) { return & $out 'Failed' 'The download folder is not protected (Administrators and SYSTEM only): nothing was downloaded.' 'NotProtected' $false }
        & $say "Downloading $($c.File) ..."
        $file = Join-Path $dir $c.File
        $dl = & $V.Download ([string]$r.Url) $file $c.MaxBytes
        if (-not $dl.Ok) { return & $out 'Failed' "The download failed: $($dl.Error)" 'Download' $false }
        if ($c.Kind -eq 'Msi' -and -not (Test-AVDTuneMsiHeader -Bytes @(& $V.ReadHeader $file 8))) { return & $out 'Failed' 'The downloaded file is not an MSI package: it is not started.' 'BadPackage' $false }
        try { $hold = & $V.HoldFile $file } catch { return & $out 'Failed' "$($c.File) cannot be held for the check: $($_.Exception.Message)" 'NoHold' $false }
        try {
            if ($c.Kind -eq 'Msi') {
                # the Property table of the held MSI names the product: webrtc and mmr cannot be swapped, and nothing older than the installed version is installed
                $pin = Test-AVDTuneMsiIdentity -Properties (& $V.ReadMsiProperties $file) -Component $c -Installed ([bool]$before.Installed) -InstalledVersion ([string]$before.Version)
                if (-not $pin.Ok) { return & $out 'Failed' "$($pin.Reason): it is not started." $pin.Code $false }
            }
            $trust = Test-AVDTuneVdiPackageTrust -Signature (& $V.VerifySignature $file) -Component $c
            if (-not $trust.Ok) { return & $out 'Failed' "$($trust.Reason): it is not started." 'BadSignature' $false }
            $runner = $file; $cmdArgs = @()
            if ($c.Kind -eq 'Exe') { $cmdArgs = @($(if ($Mode -eq 'Remove') { '-x' } else { '-p' })) }
            else {
                $runner = [string](& $V.MsiexecPath)
                $tm = Test-AVDTuneToolTrust -Signature (& $V.VerifySignature $runner) -Name 'msiexec.exe'
                if (-not $tm.Ok) { return & $out 'Failed' "$($tm.Reason): it is not started." 'BadSignature' $false }
                $log = Join-Path $dir 'msi.log'
                $cmdArgs = if ($Mode -eq 'Remove') { @('/x', $before.ProductCode, '/qn', '/norestart', '/l*v', $log) } else { @('/i', $file, '/qn', '/norestart', '/l*v', $log) }
            }
            & $say $(if ($Mode -eq 'Remove') { "Removing $($c.Title) ..." } else { "Installing $($c.Title) ..." })
            $t2 = Test-AVDTuneVdiPackageTrust -Signature (& $V.VerifySignature $file) -Component $c   # again, right before the start
            if (-not $t2.Ok) { return & $out 'Failed' "$($t2.Reason): it is not started." 'BadSignature' $false }
            if ($c.Kind -eq 'Msi') { $t3 = Test-AVDTuneToolTrust -Signature (& $V.VerifySignature $runner) -Name 'msiexec.exe'; if (-not $t3.Ok) { return & $out 'Failed' "$($t3.Reason): it is not started." 'BadSignature' $false } }
            $run = & $V.Run $runner $cmdArgs 1800
        }
        finally { if ($hold) { $hold.Dispose() } }
        if ($run.ExitCode -eq -1) {
            # timeout: the install can still be running in the Windows Installer service, which reads the file: the folder is NOT deleted
            $left = $dir; $dir = $null
            return & $out 'Failed' "$($c.File) did not finish in time. The installation can still be running in the Windows Installer service; its files stay in $left until you have checked (Test) and removed the folder by hand." 'Timeout' $false
        }
        $reboot = $run.ExitCode -in 3010, 1641
        if ($run.ExitCode -notin 0, 3010, 1641) {
            $hint = if ($run.ExitCode -eq 1618) { ' Another installation is running; wait for it and try again.' } else { '' }
            return & $out 'Failed' "$($c.File) returned $($run.ExitCode).$hint $([string]$run.Output)".Trim() "Exit$($run.ExitCode)" $false
        }
        $after = Get-AVDTuneVdiState -Machine $Machine -V $V -Key $Key
        if ($Mode -eq 'Remove') {
            if ($after.Installed) { return & $out 'Failed' "The program finished but $($c.Title) is still there." 'StillInstalled' $reboot }
            return & $out 'Changed' "Removed (was $($before.Version))." '' $reboot
        }
        if (-not $after.Installed) { return & $out 'Failed' "The program finished but $($c.Title) is not found afterwards (Teams is registered per user at the first start; for the MSI the Uninstall entry is missing)." 'NotRegistered' $reboot }
        if ($before.Installed -and $before.Version -ceq $after.Version) { return & $out 'Unchanged' "$($c.Title) is up to date ($($after.Version))." '' $reboot }
        $msg = if ($before.Installed) { "Updated $($before.Version) -> $($after.Version)." } else { "Installed $($after.Version)." }
        & $out 'Changed' $msg '' $reboot
    }
    catch { & $out 'Failed' $_.Exception.Message 'Error' $false }
    finally { if ($dir) { try { & $V.RemoveFolder $dir } catch { } } }
}

function Invoke-AVDTuneVdiWinget {
    # OneDrive per machine through winget (machine scope): winget.exe is checked like everywhere (Resolve-AVDTuneTool) and runs inside the Global\PackTune lock.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Machine, [Parameter(Mandatory)]$V, [Parameter(Mandatory)][string]$Key, [ValidateSet('Install', 'Remove')][string]$Mode = 'Install')
    $c = Get-AVDTuneVdiComponent $Key
    $before = Get-AVDTuneVdiState -Machine $Machine -V $V -Key $Key
    $out = { param($st, $msg, $code, $reboot) [pscustomobject]@{ Status = $st; Message = $msg; Code = $code; Before = $before; After = (Get-AVDTuneVdiState -Machine $Machine -V $V -Key $Key); Reboot = [bool]$reboot } }
    if ($Mode -eq 'Remove' -and -not $before.Installed) { return & $out 'Unchanged' "$($c.Title) is not installed per machine." '' $false }
    $t = Resolve-AVDTuneTool -U $V.U -Name 'winget.exe'
    if (-not $t.Path) { return & $out 'Failed' $(if ($t.Code -eq 'ToolMissing') { 'winget was not found.' } else { [string]$t.Error }) ([string]$t.Code) $false }
    $tool = $t.Path
    $common = @('--id', 'Microsoft.OneDrive', '--exact', '--scope', 'machine', '--silent', '--disable-interactivity')
    $cmdArgs = if ($Mode -eq 'Remove') { @('uninstall') + $common } else { @('install') + $common + @('--source', 'winget', '--accept-package-agreements', '--accept-source-agreements') }
    $got = Invoke-AVDTuneLocked -U $V.U -Script { & $V.U.Run $tool $cmdArgs 3600 }
    if (-not $got.Ok) { return & $out 'Failed' "Not started: $($got.Error). Wait until the other winget or Chocolatey operation is done." 'Lock' $false }
    $r = $got.Value
    $reboot = $r.ExitCode -in 3010, 1641
    if ($r.ExitCode -notin 0, 3010, 1641) {
        $text = if (Get-Command Resolve-AVDTuneSoftwareError -ErrorAction SilentlyContinue) { Resolve-AVDTuneSoftwareError 'winget' $r.ExitCode ([string]$r.Output) } else { "winget returned $($r.ExitCode)." }
        return & $out 'Failed' $text "Exit$($r.ExitCode)" $false
    }
    $after = Get-AVDTuneVdiState -Machine $Machine -V $V -Key $Key
    if ($Mode -eq 'Remove') { if ($after.Installed) { return & $out 'Failed' 'winget finished but OneDrive is still installed per machine.' 'StillInstalled' $reboot }; return & $out 'Changed' "Removed (was $($before.Version))." '' $reboot }
    if (-not $after.Installed) { return & $out 'Failed' 'winget finished but OneDrive is not found in Program Files (per machine).' 'NotRegistered' $reboot }
    & $out 'Changed' $(if ($before.Installed) { "Updated $($before.Version) -> $($after.Version)." } else { "Installed $($after.Version) per machine." }) '' $reboot
}

function Get-AVDTuneVdiUndoPath([string]$Root, [string]$Key) { Join-Path $Root "config\vdi-$Key-undo.json" }

function Invoke-AVDTuneVdiRecorded {
    <#
        Install/update or remove behind the write gate with run record (Plan 'VDI <component> install|remove'), LastChange (also on failure) and a change log entry. Before the first change the state
        found is kept for Undo (never overwritten). Returns @{ Result; Setup; Run }.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Machine, [Parameter(Mandatory)]$V, [Parameter(Mandatory)][string]$Key, [string]$Root = (Get-AVDTuneRoot), [ValidateSet('Install', 'Remove')][string]$Mode = 'Install', [string]$User, [string]$SnapshotId, [scriptblock]$Progress, [string]$PlanName)
    if (-not (Test-AVDTuneWriteAllowed)) { throw 'The snapshot gate is not confirmed: AVDTune is read only until a snapshot newer than its last change is confirmed on the Overview.' }
    $c = Get-AVDTuneVdiComponent $Key
    $started = & $Machine.Now
    $pre = Get-AVDTuneVdiState -Machine $Machine -V $V -Key $Key
    # the early exits of the install (nothing to remove, a browser is running) change nothing: no LastChange, no undo record for them
    $analysisExit = ($Mode -eq 'Remove' -and -not $pre.Installed) -or ($Key -eq 'mmr' -and $Mode -eq 'Install' -and @(& $V.RunningProcesses @('msedge', 'chrome')).Count -gt 0)
    $createdUndo = $false; $undoPath = Get-AVDTuneVdiUndoPath $Root $Key
    # marker while the master is written (snapshot gate, #27/#81): set before the first write, cleared in finally (Stop stamps LastChange, also after an abort)
    $changeOwner = $false; if (-not $analysisExit) { $changeOwner = Start-AVDTuneChange -Root $Root }
    try {
    if (-not $analysisExit) {
        [void](Set-AVDTuneState -Root $Root -Values @{ LastChange = $started.ToString('o') })
        if (-not (Test-Path -LiteralPath $undoPath)) {
            Write-AVDTuneFile $undoPath ([ordered]@{ At = $started.ToString('o'); BeforeInstalled = [bool]$pre.Installed; BeforeVersion = [string]$pre.Version } | ConvertTo-Json -Depth 4)
            $createdUndo = $true
        }
    }
    $r = Invoke-AVDTuneVdiPackage -Machine $Machine -V $V -Key $Key -Mode $Mode -Root $Root -Progress $Progress
    $noEffect = ($r.Status -eq 'Unchanged') -or ($r.Status -eq 'Failed' -and $r.Code -cin 'BrowserRunning', 'NoProductCode', 'NoLink', 'NotProtected', 'Download', 'BadPackage', 'Downgrade', 'NoHold', 'BadSignature', 'ToolMissing', 'Lock')
    if ($noEffect -and $createdUndo) { Remove-Item -LiteralPath $undoPath -Force -ErrorAction SilentlyContinue }
    $id = "vdi.$Key.$(if ($Mode -eq 'Remove') { 'remove' } else { 'install' })"
    $title = if ($PlanName) { $PlanName } elseif ($Mode -eq 'Remove') { "$($c.Title) removal" } else { $c.Title }
    $res = [pscustomobject][ordered]@{ Id = $id; Section = 'VdiComponents'; Title = $title; Mode = 'Apply'; Status = $r.Status; Before = $pre.Version; After = $r.After.Version; Message = $r.Message; Reboot = ([bool]$r.Reboot -and $r.Status -eq 'Changed'); WhatIf = $false; At = $started.ToString('o'); Code = $r.Code }
    $state = Get-AVDTuneState $Root
    $run = [pscustomobject][ordered]@{ Id = $null; Plan = "VDI $($c.Title) $(if ($Mode -eq 'Remove') { 'remove' } else { 'install' })"; Started = $started.ToString('o'); Ended = (& $Machine.Now).ToString('o'); User = $User; SnapshotId = $SnapshotId; WhatIf = $false; ImageVersion = $state.ImageVersion; Reboot = $res.Reboot; Results = @($res) }
    [void](Add-AVDTuneRun -Root $Root -Run $run)
    if ($r.Status -eq 'Changed' -or ($r.Status -eq 'Failed' -and -not $analysisExit -and -not $noEffect)) { [void](Set-AVDTuneState -Root $Root -Values @{ LastChange = (& $Machine.Now).ToString('o') }) }
    if ($state.ImageVersion -and $r.Status -in 'Changed', 'Failed') {
        $text = if ($r.Status -eq 'Changed') { "$($c.Title): $($r.Message)" } else { "$($c.Title): $Mode FAILED ($($r.Code)) - $($r.Message)" }
        $type = if ($r.Status -ne 'Changed') { 'Note' } elseif ($Mode -eq 'Remove') { 'Removed' } elseif ($pre.Installed) { 'Updated' } else { 'Added' }
        [void](Add-AVDTuneChangeLogEntry -Root $Root -Version $state.ImageVersion -Category 'VDI' -Component $c.Title -ChangeType $type -Text $text -User $User -SnapshotId $SnapshotId -RunId ([string]$run.Id) -Source Step)
    }
    [pscustomobject]@{ Result = $res; Setup = $r; Run = $run }
    }
    finally { Stop-AVDTuneChange -Root $Root -Owner $changeOwner }
}

function Get-AVDTuneVdiUndoText {
    param([string]$Root = (Get-AVDTuneRoot), [Parameter(Mandatory)][string]$Key)
    $c = Get-AVDTuneVdiComponent $Key
    $u = Read-AVDTuneJson (Get-AVDTuneVdiUndoPath $Root $Key)
    $b = if ($u) { Get-AVDTuneProp $u 'BeforeInstalled' } else { $null }
    $goal = if ($b -is [bool] -and -not $b) { "$($c.Title) is removed again (it was not there before)" } elseif ($b -is [bool]) { 'there is no undo: it was there before and Microsoft offers no older builds, so AVDTune cannot put the earlier version back' } else { 'there is no usable record of the state before the first change' }
    "Undo the change of $($c.Title): $goal."
}

function Invoke-AVDTuneVdiUndo {
    # Back to the state found before the first change: removes the component when it was not there; no undo when it was there (older builds are not offered).
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Machine, [Parameter(Mandatory)]$V, [Parameter(Mandatory)][string]$Key, [string]$Root = (Get-AVDTuneRoot), [string]$User, [string]$SnapshotId, [scriptblock]$Progress)
    $c = Get-AVDTuneVdiComponent $Key
    $u = Read-AVDTuneJson (Get-AVDTuneVdiUndoPath $Root $Key)
    if (-not $u) { throw "There is nothing to undo: no change of $($c.Title) was recorded." }
    $b = Get-AVDTuneProp $u 'BeforeInstalled'
    if ($b -isnot [bool]) { throw "The undo record of $($c.Title) (config\vdi-$Key-undo.json) is not usable: BeforeInstalled must be true or false. Nothing was changed." }
    if ($b) { throw "There is no undo for $($c.Title): it was installed before AVDTune changed it and Microsoft offers no older builds. Remove it by hand if it is not wanted." }
    $run = Invoke-AVDTuneVdiRecorded -Machine $Machine -V $V -Key $Key -Root $Root -Mode Remove -User $User -SnapshotId $SnapshotId -Progress $Progress -PlanName "Undo: $($c.Title)"
    if ($run.Setup.Status -in 'Changed', 'Unchanged') { Remove-Item -LiteralPath (Get-AVDTuneVdiUndoPath $Root $Key) -Force -ErrorAction SilentlyContinue }
    $run
}

#endregion

#region session host cards (issue 77): RDP Shortpath, time zone redirection, Defender for Endpoint onboarding

<#
    Three cards next to the components: nothing to install, only the state of the session host and the settings Microsoft Learn names for it. Read only, except one value:
      * shortpath: the RDP transport protocols policy (SelectTransport, Learn names the value) must not be 1 = "Use only TCP"; the fix removes the local policy value (= Not configured, one of the two
        ways Learn gives) with undo. The listener for managed networks, the inbound firewall rule and the public network path (STUN/TURN) are shown only: Learn configures them through Intune or
        Group Policy and names no registry value for them.
      * timezone: fEnableTimeZoneRedirection is shown only. It belongs to the Optimization page (entry optimization.timezone-redirection, in the default preset) with its own undo; a second owner
        here would let two undo records fight over one value (the same rule as Teams disableAutoUpdate and the update block).
      * mde: status only (senseGuid, OnboardingState, the Sense service, the VDI onboarding scripts in the startup folder). No onboarding package in AVDTune (it is tenant specific) and no setting:
        the DeviceTagging VDI value of Learn is for legacy MMA-based servers only.
    Writes go through Start-/Stop-AVDTuneChange (marker and LastChange), the write gate, a run record, a change log entry (category VDI) and the undo record config\vdi-<key>-settings-undo.json
    (values found before the first change, never overwritten).
#>
$script:SrcHost = @{
    Shortpath = "$script:Learn/azure/virtual-desktop/configure-rdp-shortpath"
    ShortpathAbout = "$script:Learn/azure/virtual-desktop/rdp-shortpath"
    MasterImage = "$script:Learn/azure/virtual-desktop/set-up-customize-master-image"
    MdeVdi = "$script:Learn/defender-endpoint/configure-endpoints-vdi"
    MdeTrouble = "$script:Learn/defender-endpoint/troubleshoot-onboarding"
}
$script:TsPolicy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
$script:ShortpathPort = 3390
$script:MdeKey = 'HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection'
$script:MdeScripts = @('Onboard-NonPersistentMachine.ps1', 'WindowsDefenderATPOnboardingScript.cmd')
$script:HostCards = @(
    [pscustomobject]@{ Key = 'shortpath'; Title = 'RDP Shortpath'; Source = $script:SrcHost.Shortpath
        Text = 'UDP transport for the remote session. Public networks (STUN, TURN) work without a setting on the session host when UDP is allowed outbound; managed networks need the listener (policy) and an inbound port. Only the transport policy is changed here.' }
    [pscustomobject]@{ Key = 'timezone'; Title = 'Time zone redirection'; Source = $script:SrcHost.MasterImage
        Text = 'Sessions take the time zone of the client. The value is set and undone on the Optimization page (entry "Time zone redirection on"); this card only shows it.' }
    [pscustomobject]@{ Key = 'mde'; Title = 'Defender for Endpoint (non-persistent VDI)'; Source = $script:SrcHost.MdeVdi
        Text = 'Status only. The master must not be onboarded; non-persistent session hosts are onboarded at start by the VDI onboarding script from the Defender portal (tenant specific, not part of AVDTune).' }
)
function Get-AVDTuneVdiHostCards { @($script:HostCards) }
function Get-AVDTuneVdiHostCard([string]$Key) { $c = @($script:HostCards | Where-Object { $_.Key -ceq $Key }); if ($c.Count -ne 1) { throw "Unknown VDI card '$Key'." }; $c[0] }

function Get-AVDTuneVdiHostSettingDefs {
    # Kind NotValue: compliant when the value is absent or not BadValue; Apply removes the value (= policy Not configured); Undo puts the typed value found before back.
    param([Parameter(Mandatory)][string]$Key)
    switch ($Key) {
        'shortpath' {
            @([pscustomobject]@{ Id = 'vdi.shortpath.udp'; Kind = 'NotValue'; Path = $script:TsPolicy; Name = 'SelectTransport'; Type = 'DWord'; BadValue = 1; Optional = $false; Reboot = $true
                    Title = 'RDP transport: UDP allowed (policy not "Use only TCP")'; Why = 'With "Use only TCP" no RDP Shortpath connection is possible. Learn: set the policy Select RDP transport protocols to Not configured (or UDP and TCP).'
                    Source = $script:SrcHost.Shortpath; Verified = $true; Note = 'A Group Policy or Intune setting of the same policy writes the value again at the next refresh: change it there.' })
        }
        default { @() }
    }
}

function Test-AVDTuneVdiPortList {
    # Pure: does a firewall port list ("3390", "3000-4000,5000", "*" or "Any") contain the port
    param([string]$List, [int]$Port)
    if (-not $List -or $List.Length -gt 2000) { return $false }
    foreach ($p in $List.Split(',')) {
        $t = $p.Trim()
        if ($t -ceq '*' -or $t -eq 'Any') { return $true }
        $m = $null; try { $m = [regex]::Match($t, '\A(\d{1,5})(?:-(\d{1,5}))?\z', 'None', [TimeSpan]::FromMilliseconds(200)) } catch { continue }   # data of the firewall: timeout and length limit
        if (-not $m.Success) { continue }
        $lo = [int]$m.Groups[1].Value; $hi = if ($m.Groups[2].Success) { [int]$m.Groups[2].Value } else { $lo }
        if ($Port -ge $lo -and $Port -le $hi) { return $true }
    }
    $false
}

function Get-AVDTuneVdiHostSteps {
    param([Parameter(Mandatory)]$Defs, [hashtable]$Previous = @{})
    foreach ($d in @($Defs)) {
        $def = $d; $prev = $Previous[$def.Id]
        if ($def.Kind -cne 'NotValue') { throw "Unknown kind '$($def.Kind)' of $($def.Id)." }
        $test = { param($m) $v = & $m.RegGet $def.Path $def.Name; @{ Compliant = -not ($null -ne $v -and [string]$v -ceq [string]$def.BadValue); State = $v } }.GetNewClosure()
        $apply = { param($m) & $m.RegRemove $def.Path $def.Name }.GetNewClosure()
        $undo = { param($m) if ($prev -and $prev.Exists) { & $m.RegSet $def.Path $def.Name $prev.Value $prev.Type } }.GetNewClosure()
        New-AVDTuneStep -Id $def.Id -Section VdiComponents -Title $def.Title -Why $def.Why -SourceUrl $def.Source -Reboot ([bool]$def.Reboot) -Test $test -Apply $apply -Undo $undo
    }
}

function Read-AVDTuneVdiHostUndo {
    # Typed read of config\vdi-<key>-settings-undo.json (the same shape as the component settings); $null when there is none; anything not exactly typed is an error and changes nothing
    param([string]$Root, [string]$Key)
    $path = Get-AVDTuneVdiSettingsUndoPath $Root $Key
    $u = Read-AVDTuneJson $path
    if (-not $u) { return $null }
    $ids = @(Get-AVDTuneVdiHostSettingDefs -Key $Key | ForEach-Object Id)
    $bad = "The undo record of the $Key settings (config\vdi-$Key-settings-undo.json) is not usable"
    $pp = Get-AVDTuneProp $u 'Previous'
    if ($pp -isnot [System.Management.Automation.PSCustomObject]) { throw "$bad. Nothing was changed." }
    $prev = @{}
    foreach ($p in $pp.PSObject.Properties) {
        $e = $p.Value; $exists = Get-AVDTuneProp $e 'Exists'; $type = Get-AVDTuneProp $e 'Type'; $val = Get-AVDTuneProp $e 'Value'
        $ok = ($p.Name -cin $ids) -and $exists -is [bool] -and ((-not $exists) -or ($type -is [string] -and (
                    ($type -ceq 'DWord' -and ($val -is [int] -or ($val -is [long] -and $val -ge [int]::MinValue -and $val -le [uint32]::MaxValue))) -or
                    ($type -ceq 'QWord' -and ($val -is [int] -or $val -is [long])) -or ($type -cin 'String', 'ExpandString' -and $val -is [string]))))
        if (-not $ok) { throw "${bad}: '$($p.Name)' has no typed value. Nothing was changed." }
        if ($exists -and $type -ceq 'DWord') { $l = [int64]$val; if ($l -gt [int]::MaxValue) { $l -= 4294967296 }; $val = [int]$l }
        $prev[$p.Name] = @{ Exists = $exists; Value = $val; Type = [string]$type }
    }
    $prev
}

function Get-AVDTuneVdiHostConfirmText {
    # The confirmation: every value that would change, old -> new. '' when nothing would change.
    param([Parameter(Mandatory)]$Machine, [Parameter(Mandatory)][string]$Key, [ValidateSet('Apply', 'Undo')][string]$Mode = 'Apply', [string]$Root = (Get-AVDTuneRoot))
    $c = Get-AVDTuneVdiHostCard $Key
    $show = { param($x) if ($null -eq $x) { 'not set' } else { [string]$x } }
    $lines = @()
    if ($Mode -eq 'Apply') {
        foreach ($d in @(Get-AVDTuneVdiHostSettingDefs -Key $Key)) { $v = & $Machine.RegGet $d.Path $d.Name; if ($null -ne $v -and [string]$v -ceq [string]$d.BadValue) { $lines += "$($d.Name): $(& $show $v) -> not set (policy Not configured)" } }
        if ($lines.Count -eq 0) { return '' }
        return "Change the $($c.Title) setting(s) on this master? $($lines -join '; '). The earlier value is kept for Undo. Restart the master for it to take effect; a Group Policy or Intune setting of the same policy sets it again."
    }
    $prev = Read-AVDTuneVdiHostUndo -Root $Root -Key $Key
    if ($null -eq $prev) { return '' }
    foreach ($d in @(Get-AVDTuneVdiHostSettingDefs -Key $Key | Where-Object { $prev.ContainsKey($_.Id) })) { $p = $prev[$d.Id]; $lines += "$($d.Name): $(& $show (& $Machine.RegGet $d.Path $d.Name)) -> $(if ($p.Exists) { & $show $p.Value } else { 'not set' })" }
    if ($lines.Count -eq 0) { return '' }
    "Put back the $($c.Title) value(s) found before the first change? $($lines -join '; ')."
}

function Invoke-AVDTuneVdiHostSettings {
    <#
        Apply (the recommended values) or Undo (the values found before the first apply) of a session host card. Behind the write gate; marker and LastChange through Start-/Stop-AVDTuneChange,
        only when a step would change something (a test that finds everything set changes nothing and writes nothing). Run record, change log entry (category VDI) per changed, undone or failed step.
        The undo record keeps the values found first and only gets ids that were not in it yet. WhatIf changes nothing and needs no gate.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Machine, [Parameter(Mandatory)][string]$Key, [ValidateSet('Apply', 'Undo')][string]$Mode = 'Apply', [string]$Root = (Get-AVDTuneRoot), [string]$User, [string]$SnapshotId, [switch]$WhatIf)
    $card = Get-AVDTuneVdiHostCard $Key
    $all = @(Get-AVDTuneVdiHostSettingDefs -Key $Key)
    if ($all.Count -eq 0) { throw "$($card.Title) has no settings to change: it only shows the state." }
    if (-not $WhatIf -and -not (Test-AVDTuneWriteAllowed)) { throw 'The snapshot gate is not confirmed: AVDTune is read only until a snapshot newer than its last change is confirmed on the Overview.' }
    $undoPath = Get-AVDTuneVdiSettingsUndoPath $Root $Key
    $rec = Read-AVDTuneVdiHostUndo -Root $Root -Key $Key   # a damaged record stops here, before anything is changed
    $prev = @{}
    if ($Mode -eq 'Undo') {
        if ($null -eq $rec) { throw "There is nothing to undo: no $($card.Title) settings change was recorded." }
        $prev = $rec; $defs = @($all | Where-Object { $prev.ContainsKey($_.Id) })
    }
    else {
        $defs = @($all | Where-Object { -not $_.Optional })
        foreach ($d in $defs) { if ($rec -and $rec.ContainsKey($d.Id)) { $prev[$d.Id] = $rec[$d.Id] } else { $prev[$d.Id] = Get-AVDTuneVdiPrevious -Machine $Machine -Def $d } }
    }
    $steps = @(Get-AVDTuneVdiHostSteps -Defs $defs -Previous $prev)
    $plan = "VDI $($card.Title) settings$(if ($Mode -eq 'Undo') { ' undo' })"
    $dry = @(foreach ($s in $steps) { Invoke-AVDTuneStep -Step $s -Machine $Machine -Mode $Mode -WhatIf })
    if ($WhatIf -or @($dry | Where-Object { $_.Status -eq 'WhatIf' }).Count -eq 0) { return [pscustomobject]@{ Plan = $plan; WhatIf = [bool]$WhatIf; Results = @($dry) } }
    $owner = Start-AVDTuneChange -Root $Root   # marker and LastChange through the central helpers: also a failed write may have changed the master
    try {
        if ($Mode -eq 'Apply') {
            $would = @($dry | Where-Object { $_.Status -eq 'WhatIf' } | ForEach-Object Id)   # only what is changed now: a value found as wanted needs no record
            $new = @($defs | Where-Object { $_.Id -cin $would -and (-not $rec -or -not $rec.ContainsKey($_.Id)) })
            if ($new.Count -gt 0) {
                $out = [ordered]@{}
                if ($rec) { foreach ($k in $rec.Keys) { $out[$k] = [ordered]@{ Exists = $rec[$k].Exists; Value = $rec[$k].Value; Type = $rec[$k].Type } } }
                foreach ($d in $new) { $out[$d.Id] = [ordered]@{ Exists = $prev[$d.Id].Exists; Value = $prev[$d.Id].Value; Type = $prev[$d.Id].Type } }
                $at = if ($rec) { [string](Get-AVDTuneProp (Read-AVDTuneJson $undoPath) 'At') } else { (& $Machine.Now).ToString('o') }
                Write-AVDTuneFile $undoPath ([ordered]@{ At = $at; Previous = $out } | ConvertTo-Json -Depth 6)
            }
        }
        $results = @(foreach ($s in $steps) { Invoke-AVDTuneStep -Step $s -Machine $Machine -Mode $Mode })
        $state = Get-AVDTuneState $Root
        $ended = (& $Machine.Now).ToString('o')
        $saved = [pscustomobject][ordered]@{ Id = $null; Plan = $plan; Started = $ended; Ended = $ended; User = $User; SnapshotId = $SnapshotId; WhatIf = $false; ImageVersion = $state.ImageVersion; Reboot = [bool](@($results | Where-Object { $_.Reboot }).Count); Results = @($results) }
        [void](Add-AVDTuneRun -Root $Root -Run $saved)
        if ($state.ImageVersion) {
            foreach ($r in @($results | Where-Object { $_.Status -in 'Changed', 'Reverted', 'Failed' })) {
                $type = if ($r.Status -eq 'Failed') { 'Note' } else { 'Changed' }
                $text = switch ($r.Status) { 'Failed' { "$($r.Title): FAILED - $($r.Message)" } 'Reverted' { "Undo: $($r.Title)" } default { $r.Title } }
                [void](Add-AVDTuneChangeLogEntry -Root $Root -Version $state.ImageVersion -Category 'VDI' -Component $card.Title -ChangeType $type -Text $text -User $User -SnapshotId $SnapshotId -RunId ([string]$saved.Id) -Source Step)
            }
        }
        if ($Mode -eq 'Undo' -and @($results | Where-Object { $_.Status -eq 'Failed' }).Count -eq 0) { Remove-Item -LiteralPath $undoPath -Force -ErrorAction SilentlyContinue }
        [pscustomobject]@{ Plan = $plan; WhatIf = $false; Results = @($results) }
    }
    finally { Stop-AVDTuneChange -Root $Root -Owner $owner }
}

function Get-AVDTuneVdiHostRows {
    # The test of a session host card (read only). Status green | yellow | red | info like the component cards.
    param([Parameter(Mandatory)]$Machine, [Parameter(Mandatory)]$V, [Parameter(Mandatory)][string]$Key)
    $card = Get-AVDTuneVdiHostCard $Key
    $rows = New-Object System.Collections.ArrayList
    $add = { param($r) [void]$rows.Add($r) }
    switch ($Key) {
        'shortpath' {
            $sp = $script:SrcHost.Shortpath; $port = $script:ShortpathPort
            $t = & $Machine.RegGet $script:TsPolicy 'SelectTransport'
            if ($null -eq $t) { & $add (New-AVDTuneVdiRow 'shortpath.udp' 'UDP transport' 'green' 'The policy Select RDP transport protocols is not configured: UDP and TCP are used (the Windows default).' '' $sp $true) }
            elseif ([string]$t -ceq '1') { & $add (New-AVDTuneVdiRow 'shortpath.udp' 'UDP transport' 'yellow' 'The policy Select RDP transport protocols is "Use only TCP" (SelectTransport = 1): no RDP Shortpath connection is possible.' 'Press "Set recommended settings" (removes the local value = Not configured), or change the Group Policy or Intune setting that sets it.' $sp $true) }
            elseif ([string]$t -ceq '2') { & $add (New-AVDTuneVdiRow 'shortpath.udp' 'UDP transport' 'green' 'The policy Select RDP transport protocols allows UDP or TCP (SelectTransport = 2).' '' $sp $true) }
            else { & $add (New-AVDTuneVdiRow 'shortpath.udp' 'UDP transport' 'info' "SelectTransport = $t. Learn describes only 1 (Use only TCP) and 2 (UDP or TCP); only 1 switches UDP off."'' $sp $false) }
            $listen = $null; try { $listen = & $V.UdpListener $port } catch { $listen = $null }
            if ($listen -eq $true) { & $add (New-AVDTuneVdiRow 'shortpath.managed' 'Managed networks: listener' 'green' "A UDP listener is open on port $port (the default port of RDP Shortpath for managed networks)." '' $sp $false 'Learn names the port and the policy, not a way to read the listener; AVDTune reads the open UDP ports of Windows.') }
            elseif ($listen -eq $false) { & $add (New-AVDTuneVdiRow 'shortpath.managed' 'Managed networks: listener' 'info' "No UDP listener on port $port. Only needed for RDP Shortpath for managed networks (ExpressRoute private peering or VPN); turn on the policy Enable RDP Shortpath for managed networks through Intune or Group Policy (Azure Virtual Desktop administrative template) and restart. A different port set in the policy is not read here." '' $sp $false 'Learn names the port and the policy, not a way to read the listener; AVDTune reads the open UDP ports of Windows.') }
            else { & $add (New-AVDTuneVdiRow 'shortpath.managed' 'Managed networks: listener' 'info' 'The open UDP ports could not be read.' '' $sp $false) }
            $fw = $null; try { $fw = & $V.FirewallUdpIn $port } catch { $fw = $null }
            $fwNote = 'Read from the rules of Windows Firewall (enabled, inbound, allow, UDP, local port); the profile of the rule and other firewalls (NSG) are not checked.'
            if ($null -eq $fw) { & $add (New-AVDTuneVdiRow 'shortpath.firewall' 'Managed networks: inbound port' 'info' 'The Windows Firewall rules could not be read.' '' $sp $false $fwNote) }
            elseif ($fw) { & $add (New-AVDTuneVdiRow 'shortpath.firewall' 'Managed networks: inbound port' 'green' "An enabled inbound rule allows UDP port $port." '' $sp $true $fwNote) }
            elseif ($listen -eq $true) { & $add (New-AVDTuneVdiRow 'shortpath.firewall' 'Managed networks: inbound port' 'yellow' "The listener is on but no enabled inbound rule allows UDP port ${port}: clients cannot reach it." "Allow the port inbound through the firewall policy of Intune or Group Policy (Learn)." $sp $true $fwNote) }
            else { & $add (New-AVDTuneVdiRow 'shortpath.firewall' 'Managed networks: inbound port' 'info' "No inbound rule for UDP port $port. Only needed together with the listener for managed networks (allow it through the firewall policy of Intune or Group Policy)." '' $sp $true $fwNote) }
            & $add (New-AVDTuneVdiRow 'shortpath.public' 'Public networks (STUN, TURN)' 'info' 'Nothing to set on the session host: works when UDP is allowed outbound from the session host subnet (to any address on ports 1024-65535, and to the TURN relay 51.5.0.0/16 on 3478) and the host pool networking settings are Default or Enabled. Test from a client with avdnettest.exe.' '' $script:SrcHost.ShortpathAbout $true)
            $ter = $null; try { $ter = & $V.TeredoType } catch { $ter = $null }
            & $add (New-AVDTuneVdiRow 'shortpath.teredo' 'Teredo (optional)' 'info' $(if ($ter) { "Teredo type: $ter. Learn: optional, adds NAT traversal candidates in IPv4-only networks (Set-NetTeredoConfiguration -Type Enterpriseclient on hosts and clients)." } else { 'The Teredo setting could not be read. Learn: optional, adds NAT traversal candidates in IPv4-only networks.' }) '' $sp $true)
        }
        'timezone' {
            $v = & $Machine.RegGet $script:TsPolicy 'fEnableTimeZoneRedirection'
            if ($null -ne $v -and [string]$v -ceq '1') { & $add (New-AVDTuneVdiRow 'timezone.redirect' 'Allow time zone redirection' 'green' 'On (fEnableTimeZoneRedirection = 1): sessions use the time zone of the client.' '' $card.Source $true) }
            else { & $add (New-AVDTuneVdiRow 'timezone.redirect' 'Allow time zone redirection' 'yellow' "Off$(if ($null -ne $v) { " (fEnableTimeZoneRedirection = $v)" }): every user sees the time zone of the session host." 'Turn on "Time zone redirection on" on the Optimization page (it keeps the earlier value for Undo), or the policy Allow time zone redirection through Group Policy or Intune.' $card.Source $true) }
            $tz = [string](& $Machine.RegGet 'HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation' 'TimeZoneKeyName')
            & $add (New-AVDTuneVdiRow 'timezone.host' 'Time zone of the master' 'info' $(if ($tz) { "$tz. Sysprep and new session hosts can reset it; with redirection the users do not depend on it. Set it on the Language and region page." } else { 'Not readable.' }) '' $card.Source $false)
        }
        'mde' {
            $guid = [string](& $Machine.RegGet $script:MdeKey 'senseGuid')
            $os = & $Machine.RegGet "$script:MdeKey\Status" 'OnboardingState'
            $svc = & $Machine.ServiceGet 'Sense'
            $run = $svc -and [string]$svc.Status -eq 'Running'
            if ($guid.Trim()) { & $add (New-AVDTuneVdiRow 'mde.master' 'Master not onboarded' 'red' 'This master is onboarded (senseGuid is set). Clones carry the same identifier and do not show up as new devices.' 'Offboard the master and remove the local registration data as Learn describes (Update VDI images), then take a new snapshot.' $script:SrcHost.MdeVdi $true) }
            elseif ($null -ne $os -and [string]$os -ceq '1') { & $add (New-AVDTuneVdiRow 'mde.master' 'Master not onboarded' 'red' 'OnboardingState = 1: the sensor reports this master as onboarded.' 'Offboard the master and remove the local registration data as Learn describes (Update VDI images).' $script:SrcHost.MdeTrouble $true) }
            elseif ($run) { & $add (New-AVDTuneVdiRow 'mde.master' 'Master not onboarded' 'yellow' 'The sensor service (Sense) is running although no onboarding is stored: the master may be onboarding right now.' 'Check the Defender portal and the Sense event log; do not onboard the master.' $script:SrcHost.MdeVdi $true) }
            else { & $add (New-AVDTuneVdiRow 'mde.master' 'Master not onboarded' 'green' 'No onboarding on this master (no senseGuid, OnboardingState not 1, Sense not running).' '' $script:SrcHost.MdeVdi $true) }
            $sText = if (-not $svc) { 'The Sense service is not present (Feature on Demand Microsoft.Windows.Sense.Client missing?): the onboarding script cannot start it on the session hosts.' } else { "Sense: $($svc.Status), start type $($svc.StartType). OnboardingState: $(if ($null -eq $os) { 'not set' } else { $os })." }
            & $add (New-AVDTuneVdiRow 'mde.sense' 'Sensor service (Sense)' $(if ($svc) { 'info' } else { 'yellow' }) $sText $(if ($svc) { '' } else { 'Install the Sense Feature on Demand (Learn: troubleshoot onboarding, event 15).' }) $script:SrcHost.MdeTrouble $true)
            $dir = Join-Path (Get-AVDTuneSystemFolder System) 'GroupPolicy\Machine\Scripts\Startup'
            $found = @($script:MdeScripts | Where-Object { & $V.Exists (Join-Path $dir $_) })
            $model = if ($found -contains 'Onboard-NonPersistentMachine.ps1') { 'single entry for each device' } elseif ($found.Count -gt 0) { 'multiple entries for each device' } else { '' }
            if ($model) { & $add (New-AVDTuneVdiRow 'mde.script' 'VDI onboarding script' 'green' "In the startup folder ($($found -join ', ')): $model. The script onboards each session host when it starts." '' $script:SrcHost.MdeVdi $true 'Only the files are checked; whether the startup script is registered in Group Policy (Scripts, Startup) is not read.') }
            else { & $add (New-AVDTuneVdiRow 'mde.script' 'VDI onboarding script' 'info' "Not in the startup folder. For non-persistent session hosts download the package 'VDI onboarding scripts for non-persistent endpoints' in the Defender portal, copy the script(s) to $dir and add them as startup script (Learn). Not needed when the hosts are onboarded another way (Intune, for persistent hosts)." '' $script:SrcHost.MdeVdi $true 'The package is tenant specific: AVDTune does not ship or download it.') }
            $tag = & $Machine.RegGet 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Advanced Threat Protection\DeviceTagging' 'VDI'
            & $add (New-AVDTuneVdiRow 'mde.tag' 'VDI device tag' 'info' "$(if ($null -ne $tag) { "DeviceTagging VDI = $tag. " })Learn names this value (VDI = NonPersistent) only for legacy MMA-based servers; Windows 11 multi-session does not need it, so AVDTune does not set it." '' $script:SrcHost.MdeVdi $true)
        }
    }
    @($rows)
}

function Get-AVDTuneVdiHostSummary {
    # The pill of a session host card: red, yellow, green or info (nothing could be told)
    param($Rows)
    $r = @($Rows)
    foreach ($s in 'red', 'yellow', 'green') { if (@($r | Where-Object { $_.Status -eq $s }).Count -gt 0) { return $s } }
    'info'
}

#endregion

#region real adapter

function New-AVDTuneVdiAdapter {
    <#
        The real adapter. NOT exercised by the checks beyond construction: the redirects, the download and the programs are written from the documentation and have to be tried on a
        throw-away VM (docs\vdi-components.md, "not verified"). Reuses the Office adapter (protected folder, download from download.microsoft.com only without redirects, hold file) and the update
        adapter (signature, run through the central child environment in a job object, Appx and file versions).
    #>
    $o = New-AVDTuneOfficeAdapter
    $u = New-AVDTuneUpdateAdapter
    $a = [ordered]@{ Kind = 'Real'; U = $u }
    $a.Resolve = {
        param($Entry, $Kind)
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            $cur = [string]$Entry
            if (-not (Test-AVDTuneVdiUrl -Url $cur -Hosts @('aka.ms', 'go.microsoft.com'))) { return @{ Ok = $false; Url = ''; Error = 'The entry link is not on aka.ms or go.microsoft.com over https.' } }
            for ($hop = 1; $hop -le $script:MaxHops; $hop++) {
                $req = [System.Net.HttpWebRequest]::Create([Uri]$cur); $req.AllowAutoRedirect = $false; $req.Timeout = 30000; $req.ReadWriteTimeout = 30000; $req.Method = 'GET'
                try { $resp = $req.GetResponse() } catch [System.Net.WebException] { $resp = $_.Exception.Response; if (-not $resp) { throw } }
                try {
                    $code = [int]$resp.StatusCode; $loc = [string]$resp.Headers['Location']
                    if ($code -notin 301, 302, 303, 307, 308) { return @{ Ok = $false; Url = ''; Error = "HTTP $code at $(([Uri]$cur).Host) instead of a redirect." } }
                }
                finally { $resp.Close() }
                $n = Get-AVDTuneVdiNextUrl -Current $cur -Location $loc -Kind $Kind
                if (-not $n.Ok) { return @{ Ok = $false; Url = ''; Error = $n.Error } }
                if ($n.Final) { return @{ Ok = $true; Url = $n.Url; Error = '' } }
                $cur = $n.Url
            }
            @{ Ok = $false; Url = ''; Error = "More than $script:MaxHops redirects." }
        }
        catch { @{ Ok = $false; Url = ''; Error = $_.Exception.Message } }
    }
    $a.NewTempFolder = { param($Root) $dir = Join-Path (Join-Path $Root 'temp') ('vdi-' + [guid]::NewGuid().ToString('N')); [void][IO.Directory]::CreateDirectory($dir); $dir }
    $a.IsProtectedFolder = $o.IsProtectedFolder
    $a.Download = $o.Download
    $a.HoldFile = $o.HoldFile
    $a.RemoveFolder = $o.RemoveFolder
    $a.VerifySignature = $u.VerifySignature
    $a.Run = $u.Run
    $a.ReadHeader = { param($Path, $Count) $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read); try { $b = New-Object byte[] $Count; $n = $fs.Read($b, 0, $Count); if ($n -lt $Count) { [byte[]]@() } else { $b } } finally { $fs.Dispose() } }
    $a.RunningProcesses = { param($Names) @(foreach ($n in $Names) { if (@(Get-Process -Name $n -ErrorAction SilentlyContinue).Count -gt 0) { $n } }) }
    $a.ReadMsiProperties = {
        # Property table of the (held) MSI through the Windows Installer COM object, read only (tried live on a local Microsoft MSI: the reflection route gives a type mismatch, the direct COM calls work);
        # every record is released at once and the view is closed, so the file is free again without waiting for the garbage collection. $null when it cannot be read.
        param($Path)
        $inst = $null; $db = $null; $view = $null
        try {
            $inst = New-Object -ComObject WindowsInstaller.Installer
            $db = $inst.OpenDatabase($Path, 0)
            $view = $db.OpenView('SELECT `Property`, `Value` FROM `Property`')
            [void]$view.Execute()
            $h = @{}
            while ($true) {
                $rec = $view.Fetch()
                if ($null -eq $rec) { break }
                try {
                    $k = [string]$rec.StringData(1); $v = [string]$rec.StringData(2)
                    if ($k -in 'ProductName', 'Manufacturer', 'ProductVersion', 'UpgradeCode') { $h[$k] = $v }
                }
                finally { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($rec) }
            }
            [void]$view.Close()
            $h
        }
        catch { $null }
        finally { foreach ($o in $view, $db, $inst) { if ($o) { try { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($o) } catch { } } } }
    }
    $a.MsiexecPath = { Join-Path (Get-AVDTuneSystemFolder System) 'msiexec.exe' }
    # registered for a user, or only provisioned for all users (what teamsbootstrapper.exe -p leaves until the first sign-in)
    $a.AppxVersion = {
        param($Name)
        $v = [string](& $u.AppxVersion $Name)
        if ($v) { return $v }
        try { $p = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop | Where-Object { $_.DisplayName -ceq $Name } | Select-Object -First 1); if ($p.Count -gt 0) { return [string]$p[0].Version } } catch { }
        $null
    }.GetNewClosure()
    $a.FileVersion = $u.FileVersion
    $a.Exists = $u.Exists
    $a.OneDrivePath = { & $u.Path 'OneDrive' }.GetNewClosure()
    # session host cards (issue 77), read only: open UDP ports of Windows, inbound allow rules of Windows Firewall, Teredo type. $null when it cannot be read.
    $a.UdpListener = { param($Port) try { @([System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveUdpListeners() | Where-Object { $_.Port -eq [int]$Port }).Count -gt 0 } catch { $null } }
    $a.FirewallUdpIn = {
        param($Port)
        $fw = $null
        try {
            $fw = New-Object -ComObject HNetCfg.FwPolicy2
            foreach ($r in @($fw.Rules)) {
                # Enabled, inbound (1), allow (1), UDP (17), the local port in the list
                if ($r.Enabled -and $r.Direction -eq 1 -and $r.Action -eq 1 -and $r.Protocol -eq 17 -and (Test-AVDTuneVdiPortList -List ([string]$r.LocalPorts) -Port ([int]$Port))) { return $true }
            }
            $false
        }
        catch { $null }
        finally { if ($fw) { try { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($fw) } catch { } } }
    }
    $a.TeredoType = { try { [string](Get-NetTeredoConfiguration -ErrorAction Stop).Type } catch { $null } }
    [pscustomobject]$a
}

#endregion

Export-ModuleMember -Function Get-AVDTuneVdiComponents, Get-AVDTuneVdiComponent, Test-AVDTuneVdiUrl, Get-AVDTuneVdiNextUrl, Get-AVDTuneVdiVersionFromUrl, Compare-AVDTuneVdiVersion, Get-AVDTuneVdiUninstallEntry,
    Get-AVDTuneVdiVcRuntime, Get-AVDTuneVdiState, Get-AVDTuneVdiSettingDefs, Get-AVDTuneVdiJsonSerializer, Add-AVDTuneVdiExtensionEntry, Remove-AVDTuneVdiExtensionEntry, Test-AVDTuneVdiExtensionEntry, Get-AVDTuneVdiSteps, Get-AVDTuneVdiSettingsRows, Invoke-AVDTuneVdiSettings,
    Get-AVDTuneVdiRows, Get-AVDTuneVdiSummaryStatus, Get-AVDTuneVdiLatest, Test-AVDTuneVdiPackageTrust, Test-AVDTuneMsiIdentity, Test-AVDTuneMsiHeader, Invoke-AVDTuneVdiPackage, Invoke-AVDTuneVdiWinget, Invoke-AVDTuneVdiRecorded,
    Get-AVDTuneVdiUndoText, Invoke-AVDTuneVdiUndo, New-AVDTuneVdiAdapter
# session host cards (issue 77): a second list, so that the list above stays as it is
Export-ModuleMember -Function Get-AVDTuneVdiHostCards, Get-AVDTuneVdiHostCard, Get-AVDTuneVdiHostSettingDefs, Test-AVDTuneVdiPortList, Get-AVDTuneVdiHostSteps, Read-AVDTuneVdiHostUndo, Get-AVDTuneVdiHostConfirmText,
    Invoke-AVDTuneVdiHostSettings, Get-AVDTuneVdiHostRows, Get-AVDTuneVdiHostSummary
