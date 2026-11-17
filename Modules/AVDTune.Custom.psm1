<#
    AVDTune customizations (docs\plans\avdtune.md, section 3d; issue #85): shortcuts for all users (Public Desktop and/or Start menu), fonts for all users from the
    library, and own steps without code in AVDTune (registry value, ini value, hosts entry, folder with permissions, file from the library, script from the library).

      * The list lives in config\customizations.json (state folder, admin-only). Every item is validated when it is saved AND when it is read (types checked: a
        number in quotes or "false" is not taken); an invalid item is listed with its errors and never run.
      * Every item is one step (New-AVDTuneStep: Test / Apply / Undo) and runs through Invoke-AVDTune (write gate, change marker, run record, LastChange, change log).
        Undo is a plan of its own steps through Invoke-AVDTune as well. The steps are desired state: after a rollback of the master they test as missing and
        "Apply all" puts them back.
      * The undo record (config\customizations-undo.json) is written AFTER a run and only for items whose step changed something; an older record of an item is
        never overwritten, so undo goes back to the state before AVDTune touched it. Undo never deletes a file, line, rule or shortcut AVDTune did not create.
      * Library files (fonts, icons, files, scripts) come from <library>\AVDTune-Assets in the PackTune store (read only, AVDTune.Software.psm1). The SHA256 of
        the manifest is pinned in the item when it is saved; every use checks the file against that pin (cache <root>\custom\files, admin-only). A script runs
        only when it matches the pin, with a signature that is not broken, through the signed Windows PowerShell from System32, inside a job object with a timeout,
        with -AVDTuneMode Test|Apply|Undo (exit code 0 = in place / done, 1 = missing).
      * Every access to the master goes through the customization adapter ($C): New-AVDTuneCustomAdapter is the real one (NOT exercised by the checks beyond
        construction, to be tried on a throw-away VM); Tests\Fakes\FakeCustom.ps1 is the fake.
#>

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'AVDTune.psm1')
Import-Module (Join-Path $PSScriptRoot 'AVDTune.Updates.psm1')
Import-Module (Join-Path $PSScriptRoot 'AVDTune.Software.psm1')
Import-Module (Join-Path $PSScriptRoot 'AVDTune.FSLogix.psm1')   # Test-AVDTuneBroadSid (one list of broad groups, #83)
Import-Module (Join-Path $PSScriptRoot 'AVDTune.Masking.psm1')

$script:Kinds = @('Shortcut', 'Font', 'Registry', 'Ini', 'Hosts', 'Folder', 'FileCopy', 'Script')
$script:Fields = @{
    Shortcut = @('Name', 'Location', 'Target', 'Arguments', 'WorkingDirectory', 'IconSource', 'IconFile', 'IconSha256', 'IconIndex', 'Visibility')
    Font     = @('Name', 'File', 'Sha256')
    Registry = @('Name', 'Path', 'ValueName', 'ValueType', 'Value')
    Ini      = @('Name', 'Path', 'Section', 'Key', 'Value')
    Hosts    = @('Name', 'Address', 'HostName')
    Folder   = @('Name', 'Path', 'Principal', 'Rights')
    FileCopy = @('Name', 'File', 'Sha256', 'Destination')
    Script   = @('Name', 'File', 'Sha256', 'TimeoutSeconds', 'Undo')
}
$script:IntFields = @('IconIndex', 'TimeoutSeconds')
$script:BoolFields = @('Undo')
$script:Rights = [ordered]@{ ReadAndExecute = 131241; Modify = 197055; FullControl = 2032127 }
$script:PrincipalAlias = [ordered]@{ 'Users' = 'S-1-5-32-545'; 'Authenticated Users' = 'S-1-5-11'; 'Administrators' = 'S-1-5-32-544' }   # Remote Desktop Users is not offered (review #85, M2)
$script:ValueTypes = @('String', 'ExpandString', 'DWord', 'QWord')
$script:Locations = @('Desktop', 'StartMenu', 'Both')
$script:Marker = 'AVDTune shortcut'
$script:HostsMarker = '# AVDTune'
$script:FontKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
$script:Reserved = @('CON', 'PRN', 'AUX', 'NUL', 'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9', 'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9')
$script:RegexTimeout = [TimeSpan]::FromMilliseconds(200)
$script:StartupPattern = '(?i)\\Start Menu\\Programs\\Startup(\\|\z)'   # every autostart folder: all users, Default user, each profile
$script:AppPackageSids = @('S-1-15-2-1', 'S-1-15-2-2')   # ALL APPLICATION PACKAGES, ALL RESTRICTED APPLICATION PACKAGES

#region validation (pure)

function Test-AVDTuneCustomMatch {
    # Every pattern of this module goes through here: a length limit first, then the regex with a timeout (a timeout counts as no match)
    param([string]$Text, [Parameter(Mandatory)][string]$Pattern, [int]$MaxLength = 1024)
    if ($null -eq $Text -or $Text.Length -gt $MaxLength) { return $false }
    try { [regex]::IsMatch($Text, $Pattern, [Text.RegularExpressions.RegexOptions]::None, [TimeSpan]::FromMilliseconds(200)) } catch [Text.RegularExpressions.RegexMatchTimeoutException] { $false }
}

function Test-AVDTuneCustomText {
    # Single line, no control characters, length within the limits
    param($Value, [int]$Min = 1, [int]$Max = 256)
    ($Value -is [string]) -and $Value.Length -ge $Min -and $Value.Length -le $Max -and -not (Test-AVDTuneCustomMatch $Value '[\x00-\x1F\x7F]' ($Max + 1))
}

function Test-AVDTuneCustomPathSegments([string[]]$Segments) {
    foreach ($s in $Segments) {
        if (-not $s -or $s -eq '.' -or $s -eq '..' -or $s.Length -gt 120) { return $false }
        if ($s -match '[. ]\z' -or $s -match '\A ') { return $false }
        if ($s.Split('.')[0].ToUpperInvariant() -in $script:Reserved) { return $false }
        if ($s -match '~\d') { return $false }   # an 8.3 short name (PROGRA~1) would get round the folder rules (review #85, M1)
    }
    $true
}

function Test-AVDTuneCustomLocalPath {
    # An absolute local path: drive letter, backslashes, no characters Windows forbids, no '.'/'..' segments, no stream (a second colon), no device names
    param([string]$Path)
    if (-not (Test-AVDTuneCustomMatch $Path '\A[A-Za-z]:\\[^/:*?"<>|\x00-\x1F]+\z' 240)) { return $false }
    Test-AVDTuneCustomPathSegments @($Path.Substring(3).Split([char]92))
}

function Test-AVDTuneCustomUncPath {
    # \\server\share\... : the server a host name or IPv4 address, the share a plain name, the rest like a local path
    param([string]$Path)
    if (-not (Test-AVDTuneCustomMatch $Path '\A\\\\[A-Za-z0-9][A-Za-z0-9.-]{0,252}\\[A-Za-z0-9$ ._-]{1,80}(\\[^/:*?"<>|\x00-\x1F]+)*\z' 240)) { return $false }
    $parts = @($Path.Substring(2).Split([char]92))
    if ($parts[0] -match '\.\.' -or $parts[0] -match '\.\z') { return $false }
    Test-AVDTuneCustomPathSegments @($parts | Select-Object -Skip 1)
}

function ConvertTo-AVDTuneCustomRegPath {
    # HKLM only: HKLM:\, HKLM\ or HKEY_LOCAL_MACHINE\ become HKLM:\. No SAM, SECURITY or BCD. Returns the path or '' when it is not allowed.
    param([string]$Path)
    if (-not (Test-AVDTuneCustomText $Path 6 400)) { return '' }
    $m = [regex]::Match($Path, '\A(?:HKLM:?|HKEY_LOCAL_MACHINE)\\(.+)\z', [Text.RegularExpressions.RegexOptions]::IgnoreCase, $script:RegexTimeout)
    if (-not $m.Success) { return '' }
    $rest = $m.Groups[1].Value.TrimEnd([char]92)
    $segs = @($rest.Split([char]92))
    if ($segs.Count -gt 32) { return '' }
    foreach ($s in $segs) { if (-not $s -or $s.Length -gt 255 -or $s.Trim() -ne $s -or (Test-AVDTuneCustomMatch $s '[*?]' 255)) { return '' } }
    if ($segs[0].ToUpperInvariant() -in 'SAM', 'SECURITY', 'BCD00000000', 'HARDWARE') { return '' }
    $joined = $segs -join '\'
    if (Test-AVDTuneCustomMatch $joined '(?i)\ASYSTEM\\(CurrentControlSet|ControlSet\d{3})\\Control\\(Lsa|SecurityProviders)(\\|\z)' 400) { return '' }   # authentication packages (review #85, I1)
    'HKLM:\' + $joined
}

function Get-AVDTuneCustomRegRisk {
    # A visible risk note for registry places that start code or change security (review #85, I1): '' when there is none
    param([string]$Path, [string]$ValueName)
    $rest = $Path -replace '\AHKLM:\\', ''
    $rules = @(
        @('(?i)\ASOFTWARE\\(WOW6432Node\\)?Microsoft\\Windows\\CurrentVersion\\(Run|RunOnce|RunOnceEx|RunServices|RunServicesOnce)(\\|\z)', 'autostart (Run/RunOnce)'),
        @('(?i)\\Image File Execution Options(\\|\z)', 'Image File Execution Options (debugger of a program)'),
        @('(?i)\\Windows NT\\CurrentVersion\\Winlogon(\\|\z)', 'Winlogon'),
        @('(?i)\ASYSTEM\\(CurrentControlSet|ControlSet\d{3})\\Services(\\|\z)', 'services'),
        @('(?i)(\A|\\)Policies(\\|\z)', 'policies')
    )
    $hits = @(foreach ($r in $rules) { if (Test-AVDTuneCustomMatch $rest $r[0] 400) { $r[1] } })
    if ($ValueName -ieq 'AppInit_DLLs' -or $ValueName -ieq 'LoadAppInit_DLLs') { $hits += 'AppInit_DLLs' }
    if ($hits.Count) { 'RISK: ' + ($hits -join ', ') } else { '' }
}

function Test-AVDTuneCustomHostName([string]$Name) { Test-AVDTuneCustomMatch $Name '\A(?=.{1,253}\z)[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*\z' 253 }

function Test-AVDTuneCustomAddress([string]$Address) {
    if (-not (Test-AVDTuneCustomMatch $Address '\A[0-9A-Fa-f:.]{2,45}\z' 45)) { return $false }
    $ip = $null; [Net.IPAddress]::TryParse($Address, [ref]$ip)
}

function ConvertTo-AVDTuneCustomSid {
    # A SID, or one of the well-known names that every Windows has (no lookup of names: a name could be a different account on another domain)
    param([string]$Principal)
    if (-not $Principal) { return '' }
    foreach ($k in $script:PrincipalAlias.Keys) { if ($k -ieq $Principal) { return $script:PrincipalAlias[$k] } }
    if (Test-AVDTuneCustomMatch $Principal '\AS-1-[0-9]{1,3}(-[0-9]{1,10}){1,14}\z' 200) { return $Principal.ToUpperInvariant() }
    ''
}

function ConvertTo-AVDTuneCustomLong([string]$Path) {
    # The long form (no 8.3 short names) of the existing part of a path; the path as given when Windows cannot say (review #85, M1)
    if (-not $Path) { return '' }
    try { (Get-AVDTuneLongPath $Path).TrimEnd([char]92) } catch { $Path.TrimEnd([char]92) }
}

function Get-AVDTuneCustomForbiddenFolders {
    <#
        Folders a customization may never write into or change the permissions of, as themselves (Exact) or anywhere below (Below), and the program folders (Programs)
        where broad groups get at most ReadAndExecute and no .exe.config/.dll.config may be put. Every entry in its long form.
    #>
    param([string]$Root = (Get-AVDTuneRoot))
    $win = Get-AVDTuneSystemFolder Windows
    @{
        Exact = @(([IO.Path]::GetPathRoot($win)), (Get-AVDTuneSystemFolder ProgramFiles), (Get-AVDTuneSystemFolder ProgramFilesX86), (Get-AVDTuneSystemFolder ProgramData), (Join-Path ([IO.Path]::GetPathRoot($win)) 'Users')) | ForEach-Object { ConvertTo-AVDTuneCustomLong $_ }
        Below = @($win, $Root) | ForEach-Object { ConvertTo-AVDTuneCustomLong $_ }
        Programs = @((Get-AVDTuneSystemFolder ProgramFiles), (Get-AVDTuneSystemFolder ProgramFilesX86), (Get-AVDTuneSystemFolder ProgramData)) | ForEach-Object { ConvertTo-AVDTuneCustomLong $_ }
    }
}

function Test-AVDTuneCustomUnder([string]$Path, [string]$Folder) { [bool]($Folder -and ($Path -ieq $Folder -or $Path.StartsWith($Folder + '\', [StringComparison]::OrdinalIgnoreCase))) }

function Test-AVDTuneCustomForbidden {
    # Compared in the given and in the long form: C:\PROGRA~1 is Program Files (review #85, M1)
    param([string]$Path, $Forbidden)
    foreach ($p in @($Path.TrimEnd([char]92), (ConvertTo-AVDTuneCustomLong $Path)) | Select-Object -Unique) {
        foreach ($x in @($Forbidden.Exact)) { if ($x -and $p -ieq $x.TrimEnd([char]92)) { return $true } }
        foreach ($x in @($Forbidden.Below)) { if (Test-AVDTuneCustomUnder $p $x) { return $true } }
    }
    $false
}

function Test-AVDTuneCustomInPrograms([string]$Path, $Forbidden) {
    foreach ($p in @($Path.TrimEnd([char]92), (ConvertTo-AVDTuneCustomLong $Path)) | Select-Object -Unique) { foreach ($x in @($Forbidden.Programs)) { if (Test-AVDTuneCustomUnder $p $x) { return $true } } }
    $false
}

function Test-AVDTuneCustomStartup([string]$Path) {
    # Any autostart folder (all users, Default user, a profile), also through a short name
    foreach ($p in @($Path, (ConvertTo-AVDTuneCustomLong $Path)) | Select-Object -Unique) { if (Test-AVDTuneCustomMatch $p $script:StartupPattern 400) { return $true } }
    $false
}

function Test-AVDTuneCustomBroadSid([string]$Sid) { (Test-AVDTuneBroadSid $Sid) -or $Sid -in $script:AppPackageSids }

function Get-AVDTuneCustomRuleProblem {
    # Broad groups (users, Authenticated Users, INTERACTIVE, Domain Users, Remote Desktop Users, app packages ...) get at most ReadAndExecute in the program folders and the autostart folders (review #85, M2)
    param([string]$Path, [string]$Sid, [string]$Rights, $Forbidden)
    if ($Rights -eq 'ReadAndExecute' -or -not (Test-AVDTuneCustomBroadSid $Sid)) { return '' }
    if ((Test-AVDTuneCustomInPrograms $Path $Forbidden) -or (Test-AVDTuneCustomStartup $Path)) { return "Rights: $Sid is a broad group; in Program Files, ProgramData and the autostart folders it gets at most ReadAndExecute." }
    ''
}

function ConvertTo-AVDTuneCustomItem {
    <#
        Pure apart from the forbidden folders. Validates one item (from the form with -FromForm: numbers and yes/no as text are parsed; from the state: types must be exact).
        -Library (the files of the manifest) fills Sha256/IconSha256 from the manifest when the form names a library file. Returns Valid, Errors, Item.
    #>
    param([Parameter(Mandatory)]$Raw, [switch]$FromForm, [object[]]$Library, $Forbidden)
    $errors = New-Object System.Collections.ArrayList
    $get = { param($n) Get-AVDTuneProp $Raw $n }
    if ($Raw -is [System.Collections.IDictionary]) { $get = { param($n) if ($Raw.Contains($n)) { $Raw[$n] } else { $null } }.GetNewClosure() }
    $kind = & $get 'Kind'
    if ($kind -isnot [string] -or $kind -cnotin $script:Kinds) { return [pscustomobject]@{ Valid = $false; Errors = @("Unknown kind '$kind'."); Item = $null } }
    $id = & $get 'Id'
    if ($null -eq $id -and $FromForm) { $id = [guid]::NewGuid().ToString('N').Substring(0, 12) }
    if ($id -isnot [string] -or $id -cnotmatch '\A[0-9a-f]{12}\z') { [void]$errors.Add('The id is not valid.'); $id = '' }
    $item = [ordered]@{ Id = $id; Kind = $kind }
    foreach ($f in $script:Fields[$kind]) {
        $v = & $get $f
        if ($f -in $script:IntFields) {
            if ($FromForm -and $v -is [string] -and $v.Trim() -match '\A[0-9]{1,6}\z') { $v = [int]$v.Trim() }
            if ($FromForm -and ($null -eq $v -or ($v -is [string] -and -not $v.Trim()))) { $v = $(if ($f -eq 'IconIndex') { 0 } else { 600 }) }
            if (-not ($v -is [int] -or $v -is [long])) { [void]$errors.Add("$f must be a whole number."); $v = 0 }
            $item[$f] = [int]$v; continue
        }
        if ($f -in $script:BoolFields) {
            if ($FromForm -and $v -is [string]) { $v = $(if ($v -in 'Yes', 'Ja', 'True') { $true } elseif ($v -in 'No', 'Nein', 'False', '') { $false } else { $v }) }
            if ($FromForm -and $null -eq $v) { $v = $false }
            if ($v -isnot [bool]) { [void]$errors.Add("$f must be yes or no."); $v = $false }
            $item[$f] = [bool]$v; continue
        }
        if ($null -eq $v) { $v = '' }
        if ($v -isnot [string]) { [void]$errors.Add("$f must be text."); $v = '' }
        if ($FromForm) { $v = $v.Trim() }
        $item[$f] = $v
    }
    $i = $item
    $lib = { param($name, $exts, $label)
        if (-not (Test-AVDTuneAssetName $name)) { [void]$errors.Add("$label`: choose a file of the library."); return '' }
        if ([IO.Path]::GetExtension($name).ToLowerInvariant() -notin $exts) { [void]$errors.Add("$label`: only $($exts -join ', ') files."); return '' }
        if ($Library) { $hit = @($Library | Where-Object { $_.Name -ceq $name }); if ($hit.Count -eq 1) { return [string]$hit[0].Sha256 } }
        ''
    }
    if (-not (Test-AVDTuneCustomText $i.Name 1 80)) { [void]$errors.Add('Name: 1 to 80 characters, one line.') }
    if (-not $Forbidden) { $Forbidden = Get-AVDTuneCustomForbiddenFolders }
    switch ($kind) {
        'Shortcut' {
            if (-not (Test-AVDTuneCustomMatch $i.Name '\A[A-Za-z0-9][A-Za-z0-9 ._&()+-]{0,79}\z' 80) -or $i.Name -match '[. ]\z' -or $i.Name.Split('.')[0].ToUpperInvariant() -in $script:Reserved) { [void]$errors.Add('Name: letters, digits, space and . _ & ( ) + - (it becomes the file name of the shortcut).') }
            if ($i.Location -cnotin $script:Locations) { [void]$errors.Add('Location: Desktop, StartMenu or Both.') }
            if (-not ((Test-AVDTuneCustomLocalPath $i.Target) -or (Test-AVDTuneCustomUncPath $i.Target))) { [void]$errors.Add('Target: a full local path (C:\...) or a UNC path (\\server\share\...).') }
            if ($i.Arguments -and -not (Test-AVDTuneCustomText $i.Arguments 0 1024)) { [void]$errors.Add('Arguments: one line, at most 1024 characters.') }
            if ($i.WorkingDirectory -and -not ((Test-AVDTuneCustomLocalPath $i.WorkingDirectory) -or (Test-AVDTuneCustomUncPath $i.WorkingDirectory))) { [void]$errors.Add('Working folder: empty, a full local path or a UNC path.') }
            if ($i.IconSource -cnotin 'Target', 'Library') { [void]$errors.Add('Icon: from the target or from the library.') }
            elseif ($i.IconSource -eq 'Library') { $h = & $lib $i.IconFile @('.ico') 'Icon'; if ($h) { $i.IconSha256 = $h } }
            else { $i.IconFile = ''; $i.IconSha256 = '' }
            if ($i.IconSource -eq 'Library' -and $i.IconSha256 -notmatch '\A[0-9a-f]{64}\z') { [void]$errors.Add('Icon: the SHA256 of the library file is missing (read the library first).') }
            if ($i.IconIndex -lt 0 -or $i.IconIndex -gt 9999) { [void]$errors.Add('Icon index: 0 to 9999.') }
            if ($i.Visibility -and $i.Visibility -cne 'Admins' -and -not (Test-AVDTuneCustomMatch $i.Visibility '\AS-1-[0-9]{1,3}(-[0-9]{1,10}){1,14}\z' 200)) { [void]$errors.Add('Visible for: everyone, administrators only or a group (SID).') }
            if ($i.Visibility -and $i.Location -eq 'StartMenu') { [void]$errors.Add('Visible for: App Masking rules are set for the Public Desktop only; choose Desktop or Both.') }
        }
        'Font' {
            if (-not (Test-AVDTuneCustomMatch $i.Name '\A[A-Za-z0-9][A-Za-z0-9 ._&()+-]{0,79}\z' 80)) { [void]$errors.Add('Name: the font name (letters, digits, space and . _ & ( ) + -).') }
            $h = & $lib $i.File @('.ttf', '.otf') 'Font file'; if ($h) { $i.Sha256 = $h }
            if ($i.Sha256 -notmatch '\A[0-9a-f]{64}\z') { [void]$errors.Add('Font file: the SHA256 of the library file is missing (read the library first).') }
        }
        'Registry' {
            $p = ConvertTo-AVDTuneCustomRegPath $i.Path
            if (-not $p) { [void]$errors.Add('Registry path: HKLM only (HKLM:\SOFTWARE\...), no SAM, SECURITY, BCD or HARDWARE.') } else { $i.Path = $p }
            if (-not (Test-AVDTuneCustomText $i.ValueName 0 255)) { [void]$errors.Add('Value name: at most 255 characters, one line (empty = the default value).') }
            if ($i.ValueType -cnotin $script:ValueTypes) { [void]$errors.Add("Type: $($script:ValueTypes -join ', ').") }
            elseif ($i.ValueType -in 'DWord', 'QWord') {
                $max = if ($i.ValueType -eq 'DWord') { [decimal][uint32]::MaxValue } else { [decimal][uint64]::MaxValue }
                $n = $null
                if (Test-AVDTuneCustomMatch $i.Value '\A0x[0-9A-Fa-f]{1,16}\z' 18) { $n = [decimal][Convert]::ToUInt64($i.Value.Substring(2), 16) }
                elseif (Test-AVDTuneCustomMatch $i.Value '\A[0-9]{1,20}\z' 20) { try { $n = [decimal]$i.Value } catch { } }
                if ($null -eq $n -or $n -gt $max) { [void]$errors.Add("Value: a $($i.ValueType) number (decimal or 0x hex).") }
            }
            elseif (-not (Test-AVDTuneCustomText $i.Value 0 2048)) { [void]$errors.Add('Value: one line, at most 2048 characters.') }
        }
        'Ini' {
            if (-not (Test-AVDTuneCustomLocalPath $i.Path) -or [IO.Path]::GetExtension($i.Path) -ine '.ini') { [void]$errors.Add('Ini file: a full local path of an .ini file.') }
            elseif (Test-AVDTuneCustomForbidden (Split-Path $i.Path -Parent) $Forbidden) { [void]$errors.Add('Ini file: not in the Windows folder, the state folder of AVDTune or the root of a system folder.') }
            if (-not (Test-AVDTuneCustomText $i.Section 1 100) -or (Test-AVDTuneCustomMatch $i.Section '[\[\]]' 100) -or $i.Section.Trim() -ne $i.Section) { [void]$errors.Add('Section: 1 to 100 characters without [ ].') }
            if (-not (Test-AVDTuneCustomText $i.Key 1 100) -or (Test-AVDTuneCustomMatch $i.Key '[=;\[\]]' 100) -or $i.Key.Trim() -ne $i.Key) { [void]$errors.Add('Key: 1 to 100 characters without = ; [ ].') }
            if (-not (Test-AVDTuneCustomText $i.Value 0 1000)) { [void]$errors.Add('Value: one line, at most 1000 characters.') }
        }
        'Hosts' {
            if (-not (Test-AVDTuneCustomAddress $i.Address)) { [void]$errors.Add('Address: an IPv4 or IPv6 address.') }
            if (-not (Test-AVDTuneCustomHostName $i.HostName)) { [void]$errors.Add('Host name: letters, digits, - and dots (DNS name).') }
        }
        'Folder' {
            if (-not (Test-AVDTuneCustomLocalPath $i.Path)) { [void]$errors.Add('Folder: a full local path.') }
            elseif (Test-AVDTuneCustomForbidden $i.Path $Forbidden) { [void]$errors.Add('Folder: not the root of a drive or system folder, nothing in the Windows folder or the state folder of AVDTune.') }
            $sid = ConvertTo-AVDTuneCustomSid $i.Principal
            if (-not $sid) { [void]$errors.Add("Who: a SID (S-1-...) or one of $($script:PrincipalAlias.Keys -join ', ').") } else { $i.Principal = $sid }
            if ($sid -in 'S-1-1-0', 'S-1-5-7') { [void]$errors.Add('Who: Everyone and Anonymous are not allowed.') }
            if ($i.Rights -cnotin @($script:Rights.Keys)) { [void]$errors.Add("Rights: $(@($script:Rights.Keys) -join ', ').") }
            elseif ($sid -and (Test-AVDTuneCustomLocalPath $i.Path)) { $rp = Get-AVDTuneCustomRuleProblem -Path $i.Path -Sid $sid -Rights $i.Rights -Forbidden $Forbidden; if ($rp) { [void]$errors.Add($rp) } }
        }
        'FileCopy' {
            $h = & $lib $i.File @('.txt', '.ini', '.xml', '.json', '.cfg', '.config', '.ico', '.png', '.jpg', '.bmp', '.reg', '.pdf', '.url') 'File'; if ($h) { $i.Sha256 = $h }
            if ($i.Sha256 -notmatch '\A[0-9a-f]{64}\z') { [void]$errors.Add('File: the SHA256 of the library file is missing (read the library first).') }
            if (-not (Test-AVDTuneCustomLocalPath $i.Destination)) { [void]$errors.Add('Destination: the full local path of the new file.') }
            elseif (Test-AVDTuneCustomForbidden (Split-Path $i.Destination -Parent) $Forbidden) { [void]$errors.Add('Destination: not in the Windows folder, the state folder of AVDTune or the root of a system folder.') }
            elseif (Test-AVDTuneCustomStartup $i.Destination) { [void]$errors.Add('Destination: no autostart folder (Startup).') }
            elseif ($i.Destination -match '(?i)\.(exe|dll)\.config\z' -and (Test-AVDTuneCustomInPrograms $i.Destination $Forbidden)) { [void]$errors.Add('Destination: no .exe.config or .dll.config in the program folders (it changes how a program loads).') }
        }
        'Script' {
            $h = & $lib $i.File @('.ps1') 'Script'; if ($h) { $i.Sha256 = $h }
            if ($i.Sha256 -notmatch '\A[0-9a-f]{64}\z') { [void]$errors.Add('Script: the SHA256 of the library file is missing (read the library first).') }
            if ($i.TimeoutSeconds -lt 10 -or $i.TimeoutSeconds -gt 7200) { [void]$errors.Add('Timeout: 10 to 7200 seconds.') }
        }
    }
    foreach ($k in 'Sha256', 'IconSha256') { if ($i.Contains($k) -and $i[$k]) { $i[$k] = ([string]$i[$k]).ToLowerInvariant() } }
    [pscustomobject]@{ Valid = ($errors.Count -eq 0); Errors = @($errors); Item = [pscustomobject]$i }
}

#endregion

#region ini and hosts (pure text)

function Split-AVDTuneCustomLines([string]$Text) { if (-not $Text) { return , @() }; , @($Text -split "`r?`n") }

function Get-AVDTuneIniValue {
    # The value of Key in [Section] (case-insensitive, first hit), $null when it is not there. Comments (; #) are not values.
    param([string]$Text, [Parameter(Mandatory)][string]$Section, [Parameter(Mandatory)][string]$Key)
    $in = $false
    foreach ($line in (Split-AVDTuneCustomLines $Text)) {
        $t = $line.Trim()
        if ($t.StartsWith('[') -and $t.EndsWith(']')) { $in = ($t.Substring(1, $t.Length - 2).Trim() -ieq $Section); continue }
        if (-not $in -or $t.StartsWith(';') -or $t.StartsWith('#')) { continue }
        $eq = $t.IndexOf('='); if ($eq -lt 1) { continue }
        if ($t.Substring(0, $eq).Trim() -ieq $Key) { return $t.Substring($eq + 1).Trim() }
    }
    $null
}

function Set-AVDTuneIniValue {
    # The text with Key=Value in [Section]: the first existing line is replaced, otherwise added at the end of the section, otherwise a new section at the end. -Remove takes the key out.
    param([string]$Text, [Parameter(Mandatory)][string]$Section, [Parameter(Mandatory)][string]$Key, [string]$Value, [switch]$Remove)
    $lines = New-Object System.Collections.ArrayList
    foreach ($l in (Split-AVDTuneCustomLines $Text)) { [void]$lines.Add($l) }
    while ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') { $lines.RemoveAt($lines.Count - 1) }
    $in = $false; $sectionEnd = -1; $found = $false
    for ($n = 0; $n -lt $lines.Count; $n++) {
        $t = ([string]$lines[$n]).Trim()
        if ($t.StartsWith('[') -and $t.EndsWith(']')) {
            if ($in -and $sectionEnd -lt 0) { $sectionEnd = $n }
            $in = ($t.Substring(1, $t.Length - 2).Trim() -ieq $Section); continue
        }
        if (-not $in -or $t.StartsWith(';') -or $t.StartsWith('#')) { continue }
        $eq = $t.IndexOf('=')
        if ($eq -ge 1 -and $t.Substring(0, $eq).Trim() -ieq $Key) {
            if ($Remove) { $lines.RemoveAt($n) } else { $lines[$n] = "$Key=$Value" }
            $found = $true; break
        }
    }
    if (-not $found -and -not $Remove) {
        $hasSection = $false
        foreach ($l in $lines) { $t = ([string]$l).Trim(); if ($t.StartsWith('[') -and $t.EndsWith(']') -and $t.Substring(1, $t.Length - 2).Trim() -ieq $Section) { $hasSection = $true } }
        if ($hasSection) {
            if ($sectionEnd -lt 0) { $sectionEnd = $lines.Count }
            $at = $sectionEnd; while ($at -gt 0 -and ([string]$lines[$at - 1]).Trim() -eq '') { $at-- }
            $lines.Insert($at, "$Key=$Value")
        }
        else { if ($lines.Count -gt 0) { [void]$lines.Add('') }; [void]$lines.Add("[$Section]"); [void]$lines.Add("$Key=$Value") }
    }
    (@($lines) -join "`r`n") + "`r`n"
}

function Test-AVDTuneHostsEntry {
    # Is there an active line (not a comment) that maps HostName to Address? Host names ignore case.
    param([string]$Text, [Parameter(Mandatory)][string]$Address, [Parameter(Mandatory)][string]$HostName)
    foreach ($line in (Split-AVDTuneCustomLines $Text)) {
        $t = $line; $c = $t.IndexOf('#'); if ($c -ge 0) { $t = $t.Substring(0, $c) }
        $parts = @($t.Trim() -split '\s+' | Where-Object { $_ })
        if ($parts.Count -ge 2 -and $parts[0] -eq $Address -and @($parts | Select-Object -Skip 1 | Where-Object { $_ -ieq $HostName }).Count -gt 0) { return $true }
    }
    $false
}

function Get-AVDTuneHostsLine([string]$Address, [string]$HostName) { "$Address $HostName $($script:HostsMarker)" }

function Set-AVDTuneHostsEntry {
    # Adds the line of AVDTune (address, host, marker) at the end, or with -Remove takes out exactly that line (nothing else, lines of others stay)
    param([string]$Text, [Parameter(Mandatory)][string]$Address, [Parameter(Mandatory)][string]$HostName, [switch]$Remove)
    $ours = Get-AVDTuneHostsLine $Address $HostName
    $lines = @((Split-AVDTuneCustomLines $Text) | Where-Object { -not ($Remove -and $_.Trim() -ieq $ours) })
    while ($lines.Count -gt 0 -and $lines[-1] -eq '') { $lines = @($lines | Select-Object -First ($lines.Count - 1)) }
    if (-not $Remove) { $lines += $ours }
    (@($lines) -join "`r`n") + "`r`n"
}

#endregion

#region storage

function Get-AVDTuneCustomPath([string]$Root) { Join-Path $Root 'config\customizations.json' }
function Get-AVDTuneCustomUndoPath([string]$Root) { Join-Path $Root 'config\customizations-undo.json' }

function Get-AVDTuneCustomizations {
    <# The saved items, each validated again (types exact). Returns Items (valid ones), Invalid (@{ Id; Kind; Name; Errors }) and Problem (the file itself). #>
    param([string]$Root = (Get-AVDTuneRoot), $Forbidden)
    $j = $null; $problem = ''
    try { $j = Read-AVDTuneJson (Get-AVDTuneCustomPath $Root) } catch { $problem = "The list of customizations cannot be read: $($_.Exception.Message)" }
    $items = New-Object System.Collections.ArrayList; $invalid = New-Object System.Collections.ArrayList
    if ($j -and (Get-AVDTuneProp $j 'Schema') -ne 1) { $problem = 'The list of customizations has an unknown schema: not used.'; $j = $null }
    if (-not $Forbidden) { $Forbidden = Get-AVDTuneCustomForbiddenFolders -Root $Root }
    $ids = @{}
    foreach ($raw in @(Get-AVDTuneProp $j 'Items')) {
        if ($null -eq $raw) { continue }
        $r = ConvertTo-AVDTuneCustomItem -Raw $raw -Forbidden $Forbidden
        $id = [string](Get-AVDTuneProp $raw 'Id')
        if ($r.Valid -and $ids.ContainsKey($id)) { $r = [pscustomobject]@{ Valid = $false; Errors = @('The id is used twice.'); Item = $r.Item } }
        if ($r.Valid) { $ids[$id] = $true; [void]$items.Add($r.Item) }
        else { [void]$invalid.Add([pscustomobject]@{ Id = (Remove-AVDTuneControlCharacters $id 20); Kind = (Remove-AVDTuneControlCharacters ([string](Get-AVDTuneProp $raw 'Kind')) 20); Name = (Remove-AVDTuneControlCharacters ([string](Get-AVDTuneProp $raw 'Name')) 80); Errors = @($r.Errors) }) }
    }
    [pscustomobject]@{ Items = @($items); Invalid = @($invalid); Problem = $problem }
}

function Save-AVDTuneCustomizations {
    # Writes only valid items (validated again here). AVDTune's own state: no change of the master, no write gate.
    param([string]$Root = (Get-AVDTuneRoot), [object[]]$Items = @())
    $clean = @(); $forbidden = Get-AVDTuneCustomForbiddenFolders -Root $Root
    foreach ($i in @($Items)) { if ($null -eq $i) { continue }; $r = ConvertTo-AVDTuneCustomItem -Raw $i -Forbidden $forbidden; if (-not $r.Valid) { throw "Not saved: $($r.Errors -join ' ')" }; $clean += $r.Item }
    Write-AVDTuneFile (Get-AVDTuneCustomPath $Root) ([ordered]@{ Schema = 1; Items = @($clean) } | ConvertTo-Json -Depth 5)
}

function Add-AVDTuneCustomItem {
    # Validates the form (-Library: the manifest files, for the SHA256) and appends the item. Returns the result of the validation; nothing is written when it is not valid.
    param([string]$Root = (Get-AVDTuneRoot), [Parameter(Mandatory)]$Raw, [object[]]$Library)
    $r = ConvertTo-AVDTuneCustomItem -Raw $Raw -FromForm -Library $Library -Forbidden (Get-AVDTuneCustomForbiddenFolders -Root $Root)
    if (-not $r.Valid) { return $r }
    $cur = Get-AVDTuneCustomizations -Root $Root
    if ($cur.Problem) { throw $cur.Problem }
    $same = @($cur.Items | Where-Object { $_.Kind -eq $r.Item.Kind -and $_.Name -ieq $r.Item.Name })
    if ($same.Count -gt 0) { return [pscustomobject]@{ Valid = $false; Errors = @("There is already a $($r.Item.Kind) named '$($r.Item.Name)'."); Item = $r.Item } }
    Save-AVDTuneCustomizations -Root $Root -Items (@($cur.Items) + $r.Item)
    $r
}

function Remove-AVDTuneCustomItem {
    # Takes an item out of the list (AVDTune's state only). The page undoes it on the master first; an item with an open undo record is refused unless -Force.
    param([string]$Root = (Get-AVDTuneRoot), [Parameter(Mandatory)][string]$Id, [switch]$Force)
    $undo = Read-AVDTuneCustomUndo $Root
    if (-not $Force -and $undo.ContainsKey($Id)) { throw 'This item changed the master and has not been undone: undo it first.' }
    $cur = Get-AVDTuneCustomizations -Root $Root
    if ($cur.Problem) { throw $cur.Problem }
    Save-AVDTuneCustomizations -Root $Root -Items @($cur.Items | Where-Object { $_.Id -ne $Id })
}

function Read-AVDTuneCustomUndo([string]$Root) {
    $h = @{}
    $j = Read-AVDTuneJson (Get-AVDTuneCustomUndoPath $Root)
    foreach ($e in @(Get-AVDTuneProp $j 'Entries')) { $id = [string](Get-AVDTuneProp $e 'Id'); if ($id -cmatch '\A[0-9a-f]{12}\z') { $h[$id] = $e } }
    $h
}

function Write-AVDTuneCustomUndo([string]$Root, [hashtable]$Entries) {
    if ($Entries.Count -eq 0) { Remove-Item -LiteralPath (Get-AVDTuneCustomUndoPath $Root) -Force -ErrorAction SilentlyContinue; return }
    Write-AVDTuneFile (Get-AVDTuneCustomUndoPath $Root) ([ordered]@{ Schema = 1; Entries = @($Entries.Values) } | ConvertTo-Json -Depth 6)
}

#endregion

#region steps

function Get-AVDTuneCustomStepId($Item) { "customizations.$($Item.Kind.ToLowerInvariant())-$($Item.Id)" }

function Get-AVDTuneCustomTitle($Item) {
    switch ($Item.Kind) {
        'Shortcut' { "Shortcut $($Item.Name) ($($Item.Location))" }
        'Font' { "Font $($Item.Name) ($($Item.File))" }
        'Registry' { $risk = Get-AVDTuneCustomRegRisk $Item.Path $Item.ValueName; "Registry $($Item.Path)\$(if ($Item.ValueName) { $Item.ValueName } else { '(Default)' }) = $($Item.Value)$(if ($risk) { " [$risk]" })" }
        'Ini' { "Ini $($Item.Path) [$($Item.Section)] $($Item.Key)=$($Item.Value)" }
        'Hosts' { "Hosts entry $($Item.Address) $($Item.HostName)" }
        'Folder' { "Folder $($Item.Path) with $($Item.Rights) for $($Item.Principal)" }
        'FileCopy' { "File $($Item.File) to $($Item.Destination)" }
        'Script' { "Script $($Item.File)" }
    }
}

function Get-AVDTuneCustomShortcutPaths {
    param([Parameter(Mandatory)]$Item, [Parameter(Mandatory)]$C)
    $file = "$($Item.Name).lnk"
    $p = @()
    if ($Item.Location -in 'Desktop', 'Both') { $p += (Join-Path (& $C.Folder 'PublicDesktop') $file) }
    if ($Item.Location -in 'StartMenu', 'Both') { $p += (Join-Path (& $C.Folder 'StartMenu') $file) }
    $p
}

function Get-AVDTuneCustomIconPath {
    # The icon as the shortcut names it: "<file>,<index>". From the target, or the library icon copied to C:\ProgramData\AVDTune-Public\Icons (read only for users).
    param([Parameter(Mandatory)]$Item, [Parameter(Mandatory)]$C)
    if ($Item.IconSource -eq 'Library') { return ((Join-Path (& $C.Folder 'PublicIcons') ($Item.IconSha256.Substring(0, 16) + '.ico')) + ",$($Item.IconIndex)") }
    "$($Item.Target),$($Item.IconIndex)"
}

function ConvertTo-AVDTuneCustomRegValue {
    # The value as it is written: DWord/QWord as numbers (unsigned text -> the signed type Windows stores), strings as they are
    param([string]$Type, [string]$Value)
    switch ($Type) {
        'DWord' { $u = if ($Value -match '\A0x') { [Convert]::ToUInt32($Value.Substring(2), 16) } else { [uint32]$Value }; [BitConverter]::ToInt32([BitConverter]::GetBytes($u), 0) }
        'QWord' { $u = if ($Value -match '\A0x') { [Convert]::ToUInt64($Value.Substring(2), 16) } else { [uint64]$Value }; [BitConverter]::ToInt64([BitConverter]::GetBytes($u), 0) }
        default { $Value }
    }
}

function Test-AVDTuneCustomRegEqual {
    param($Raw, [string]$Type, $Want)
    if ($null -eq $Raw) { return $false }
    if ([string]$Raw.Kind -ne $Type) { return $false }
    if ($Type -in 'DWord', 'QWord') { return ([int64]$Raw.Value -eq [int64]$Want) }
    [string]$Raw.Value -ceq [string]$Want
}

function Get-AVDTuneCustomFontValueName($Item) { "$($Item.Name) ($(if ([IO.Path]::GetExtension($Item.File) -ieq '.otf') { 'OpenType' } else { 'TrueType' }))" }

function Get-AVDTuneCustomBefore {
    # What is there before Apply, for the undo record (read only)
    param([Parameter(Mandatory)]$Item, [Parameter(Mandatory)]$C)
    switch ($Item.Kind) {
        'Registry' { $r = & $C.RegGet $Item.Path $Item.ValueName; if ($r) { @{ Exists = $true; Value = $r.Value; Kind = [string]$r.Kind } } else { @{ Exists = $false } } }
        'Ini' { $f = & $C.ReadText $Item.Path; $v = if ($f) { Get-AVDTuneIniValue -Text $f.Text -Section $Item.Section -Key $Item.Key } else { $null }; @{ FileExisted = [bool]$f; Exists = ($null -ne $v); Value = [string]$v } }
        'Folder' {
            $d = & $C.DirInfo $Item.Path
            $own = @(@($d.Rules) | Where-Object { $_ -and $_.Sid -eq $Item.Principal -and -not $_.Inherited } | ForEach-Object { @{ Rights = [int]$_.Rights; Inherit = $(if ($null -ne $_.Inherit) { [int]$_.Inherit } else { 3 }); Propagate = $(if ($null -ne $_.Propagate) { [int]$_.Propagate } else { 0 }) } })
            @{ Existed = [bool]$d.Exists; Rules = $own }
        }
        'Font' { $r = & $C.RegGet $script:FontKey (Get-AVDTuneCustomFontValueName $Item); @{ FileExisted = ($null -ne (& $C.FileHash (Join-Path (& $C.Folder 'Fonts') $Item.File))); ValueExisted = [bool]$r; Value = $(if ($r) { [string]$r.Value } else { '' }) } }
        default { @{} }
    }
}

function New-AVDTuneCustomStep {
    <#
        The step of one item. -Fetch is a scriptblock (Name, Sha256) that returns the path of the checked library file (New-AVDTuneCustomFetch); -Before is the undo record
        of the item (for Undo). Test/Apply/Undo only talk to the adapter $C and the fetch block.
    #>
    param([Parameter(Mandatory)]$Item, [Parameter(Mandatory)]$C, [scriptblock]$Fetch, $Before, $Forbidden)
    $i = $Item
    $fb = if ($Forbidden) { $Forbidden } else { Get-AVDTuneCustomForbiddenFolders }
    $nofetch = { param($n, $h) throw "The library file $n is not available (not signed in or no library): read the library first." }
    $get = if ($Fetch) { $Fetch } else { $nofetch }
    $undo = $null
    switch ($i.Kind) {
        'Registry' {
            $want = ConvertTo-AVDTuneCustomRegValue $i.ValueType $i.Value
            $test = { param($m) $r = & $C.RegGet $i.Path $i.ValueName; @{ Compliant = (Test-AVDTuneCustomRegEqual $r $i.ValueType $want); State = $(if ($r) { "$($r.Kind) $($r.Value)" } else { 'absent' }) } }.GetNewClosure()
            $apply = { param($m) & $C.RegSet $i.Path $i.ValueName $want $i.ValueType }.GetNewClosure()
            if ($Before) {
                $b = $Before
                $undo = { param($m) if ($b.Exists) { & $C.RegSet $i.Path $i.ValueName $b.Value $b.Kind } else { & $C.RegRemove $i.Path $i.ValueName } }.GetNewClosure()
            }
        }
        'Ini' {
            $test = { param($m) $f = & $C.ReadText $i.Path; $v = if ($f) { Get-AVDTuneIniValue -Text $f.Text -Section $i.Section -Key $i.Key } else { $null }; @{ Compliant = ($null -ne $v -and $v -ceq $i.Value); State = $(if ($null -eq $f) { 'no file' } elseif ($null -eq $v) { 'absent' } else { $v }) } }.GetNewClosure()
            $apply = { param($m) $f = & $C.ReadText $i.Path; $text = if ($f) { $f.Text } else { '' }; & $C.WriteText $i.Path (Set-AVDTuneIniValue -Text $text -Section $i.Section -Key $i.Key -Value $i.Value) $(if ($f) { $f.Encoding } else { 'utf-8' }) }.GetNewClosure()
            if ($Before) {
                $b = $Before
                $undo = { param($m)
                    $f = & $C.ReadText $i.Path; if (-not $f) { return }
                    if (-not $b.FileExisted) { $rest = Set-AVDTuneIniValue -Text $f.Text -Section $i.Section -Key $i.Key -Remove; if (-not ($rest -replace '(?m)^\s*\[[^\]]*\]\s*$', '').Trim()) { & $C.FileDelete $i.Path; return } }
                    $new = if ($b.Exists) { Set-AVDTuneIniValue -Text $f.Text -Section $i.Section -Key $i.Key -Value ([string]$b.Value) } else { Set-AVDTuneIniValue -Text $f.Text -Section $i.Section -Key $i.Key -Remove }
                    & $C.WriteText $i.Path $new $f.Encoding
                }.GetNewClosure()
            }
        }
        'Hosts' {
            $test = { param($m) $f = & $C.ReadText (& $C.Folder 'Hosts'); $ok = [bool]($f -and (Test-AVDTuneHostsEntry -Text $f.Text -Address $i.Address -HostName $i.HostName)); @{ Compliant = $ok; State = $(if ($ok) { 'present' } else { 'absent' }) } }.GetNewClosure()
            $apply = { param($m) $p = & $C.Folder 'Hosts'; $f = & $C.ReadText $p; if (-not $f) { throw "$p is missing." }; & $C.WriteText $p (Set-AVDTuneHostsEntry -Text $f.Text -Address $i.Address -HostName $i.HostName) $f.Encoding }.GetNewClosure()
            $undo = { param($m) $p = & $C.Folder 'Hosts'; $f = & $C.ReadText $p; if ($f) { & $C.WriteText $p (Set-AVDTuneHostsEntry -Text $f.Text -Address $i.Address -HostName $i.HostName -Remove) $f.Encoding } }.GetNewClosure()
        }
        'Folder' {
            $mask = [int]$script:Rights[$i.Rights]
            $test = { param($m) $d = & $C.DirInfo $i.Path
                if (-not $d.Exists) { return @{ Compliant = $false; State = 'no folder' } }
                if ($d.Link) { return @{ Compliant = $false; State = 'is a link' } }
                $has = @($d.Rules | Where-Object { $_.Sid -eq $i.Principal -and -not $_.Inherited -and (([int]$_.Rights -band $mask) -eq $mask) }).Count -gt 0
                @{ Compliant = $has; State = $(if ($has) { "$($i.Rights) for $($i.Principal)" } else { "no $($i.Rights) for $($i.Principal)" }) } }.GetNewClosure()
            $apply = { param($m) $d = & $C.DirInfo $i.Path; if ($d.Link) { throw "$($i.Path) is a link: not changed." }; if (-not $d.Exists) { & $C.DirCreate $i.Path }; & $C.DirAddRule $i.Path $i.Principal $mask }.GetNewClosure()
            if ($Before) {
                $b = $Before
                # the rules of this SID from before are put back (an added rule merges with an existing one of the same SID, review #85, L3)
                $undo = { param($m) & $C.DirRemoveRule $i.Path $i.Principal $mask
                    foreach ($r in @($b.Rules)) { if ($r) { & $C.DirAddRule $i.Path $i.Principal ([int]$r.Rights) ([int]$r.Inherit) ([int]$r.Propagate) } }
                    if (-not $b.Existed) { & $C.DirRemoveEmpty $i.Path } }.GetNewClosure()
            }
        }
        'FileCopy' {
            $test = { param($m) $h = & $C.FileHash $i.Destination; @{ Compliant = ($h -eq $i.Sha256); State = $(if ($null -eq $h) { 'absent' } elseif ($h -eq $i.Sha256) { 'in place' } else { 'a different file' }) } }.GetNewClosure()
            $apply = { param($m) $h = & $C.FileHash $i.Destination; if ($null -ne $h) { throw "$($i.Destination) exists already with other content: it is not overwritten." }; & $C.CopyFile (& $get $i.File $i.Sha256) $i.Destination 'Default' }.GetNewClosure()
            $undo = { param($m) if ((& $C.FileHash $i.Destination) -eq $i.Sha256) { & $C.FileDelete $i.Destination } }.GetNewClosure()
        }
        'Font' {
            $valueName = Get-AVDTuneCustomFontValueName $i
            $fontKey = $script:FontKey
            $test = { param($m) $dest = Join-Path (& $C.Folder 'Fonts') $i.File; $h = & $C.FileHash $dest; $r = & $C.RegGet $fontKey $valueName
                $ok = ($h -eq $i.Sha256 -and $r -and [string]$r.Value -ieq $i.File)
                @{ Compliant = [bool]$ok; State = $(if ($ok) { 'installed' } elseif ($null -ne $h -and $h -ne $i.Sha256) { 'a different font file of that name' } elseif ($h) { 'file without registration' } else { 'not installed' }) } }.GetNewClosure()
            $apply = { param($m) $dest = Join-Path (& $C.Folder 'Fonts') $i.File; $h = & $C.FileHash $dest
                if ($null -ne $h -and $h -ne $i.Sha256) { throw "$dest exists with other content: not overwritten." }
                $cur = & $C.RegGet $fontKey $valueName
                if ($cur -and [string]$cur.Value -ine $i.File) { throw "The font registration '$valueName' points to $($cur.Value): not replaced." }
                if ($null -eq $h) { & $C.CopyFile (& $get $i.File $i.Sha256) $dest 'Default' }
                & $C.RegSet $fontKey $valueName $i.File 'String' }.GetNewClosure()
            if ($Before) {
                # the registration as it was; the file is deleted only when AVDTune put it there (review #85, M4)
                $b = $Before
                $undo = { param($m) $dest = Join-Path (& $C.Folder 'Fonts') $i.File
                    $r = & $C.RegGet $fontKey $valueName
                    if ($b.ValueExisted) { if (-not $r -or [string]$r.Value -cne [string]$b.Value) { & $C.RegSet $fontKey $valueName ([string]$b.Value) 'String' } }
                    elseif ($r -and [string]$r.Value -ieq $i.File) { & $C.RegRemove $fontKey $valueName }
                    if (-not $b.FileExisted -and (& $C.FileHash $dest) -eq $i.Sha256) { & $C.FileDelete $dest } }.GetNewClosure()
            }
        }
        'Shortcut' {
            $paths = @(Get-AVDTuneCustomShortcutPaths -Item $i -C $C)
            $icon = Get-AVDTuneCustomIconPath -Item $i -C $C
            $desc = "$($script:Marker) $($i.Id)"
            $test = { param($m) $miss = @()
                foreach ($p in $paths) { $s = & $C.ShortcutRead $p; if (-not ($s -and $s.Target -ieq $i.Target -and $s.Arguments -ceq $i.Arguments -and [string]$s.WorkingDirectory -ieq $i.WorkingDirectory -and $s.Icon -ieq $icon -and $s.Description -ceq $desc)) { $miss += (Split-Path (Split-Path $p -Parent) -Leaf) } }
                @{ Compliant = ($miss.Count -eq 0); State = $(if ($miss.Count) { 'missing or different: ' + ($miss -join ', ') } else { 'in place' }) } }.GetNewClosure()
            $apply = { param($m)
                foreach ($p in $paths) { $s = & $C.ShortcutRead $p; if ($s -and $s.Description -cne $desc) { throw "$p exists and was not made by AVDTune for this item: it is not replaced." } }
                if ($i.IconSource -eq 'Library') {
                    $ico = Join-Path (& $C.Folder 'PublicIcons') ($i.IconSha256.Substring(0, 16) + '.ico')
                    $h = & $C.FileHash $ico
                    if ($null -ne $h -and $h -ne $i.IconSha256) { throw "$ico exists with other content." }
                    if ($null -eq $h) { & $C.CopyFile (& $get $i.IconFile $i.IconSha256) $ico 'UsersRead' }
                }
                foreach ($p in $paths) { & $C.ShortcutWrite $p $i.Target $i.Arguments $icon $i.WorkingDirectory $desc } }.GetNewClosure()
            $undo = { param($m) foreach ($p in $paths) { $s = & $C.ShortcutRead $p; if ($s -and $s.Description -ceq $desc) { & $C.ShortcutDelete $p } } }.GetNewClosure()
        }
        'Script' {
            $run = { param($mode) $path = & $get $i.File $i.Sha256; & $C.RunScript $path $i.Sha256 $mode $i.TimeoutSeconds }.GetNewClosure()
            $test = { param($m) $r = & $run 'Test'; if ($r.ExitCode -notin 0, 1) { throw "The script answered the test with exit code $($r.ExitCode) (0 = in place, 1 = missing)." }; @{ Compliant = ($r.ExitCode -eq 0); State = "exit code $($r.ExitCode)" } }.GetNewClosure()
            $apply = { param($m) $r = & $run 'Apply'; if ($r.ExitCode -ne 0) { throw "The script ended with exit code $($r.ExitCode)." } }.GetNewClosure()
            if ($i.Undo) { $undo = { param($m) $r = & $run 'Undo'; if ($r.ExitCode -ne 0) { throw "The undo of the script ended with exit code $($r.ExitCode)." } }.GetNewClosure() }
        }
    }
    # checked again directly before Apply (the forbidden folders in their long form now, review #85, M1)
    $inner = $apply
    $apply = { param($m) $chk = ConvertTo-AVDTuneCustomItem -Raw $i -Forbidden $fb; if (-not $chk.Valid) { throw "Refused before Apply: $($chk.Errors -join ' ')" }; & $inner $m }.GetNewClosure()
    New-AVDTuneStep -Id (Get-AVDTuneCustomStepId $i) -Section Customizations -Title (Get-AVDTuneCustomTitle $i) -Why 'Own customization of this master (Customizations page).' -Risk Medium -Test $test -Apply $apply -Undo $undo
}

function New-AVDTuneCustomUndoStep {
    # Undo as a step that Invoke-AVDTune can apply: in place when the item is NOT in place any more; Apply runs the undo of the item
    param([Parameter(Mandatory)]$Step)
    $s = $Step
    $test = { param($m) $r = & $s.Test $m; $c = if ($r -is [bool]) { $r } elseif ($r -is [System.Collections.IDictionary]) { [bool]$r['Compliant'] } else { [bool]$r.Compliant }; $st = if ($r -is [System.Collections.IDictionary]) { $r['State'] } elseif ($r -isnot [bool]) { $r.State } else { $null }; @{ Compliant = (-not $c); State = $st } }.GetNewClosure()
    $apply = { param($m) & $s.Undo $m }.GetNewClosure()
    New-AVDTuneStep -Id ($s.Id -replace '^customizations\.', 'customizations.undo-') -Section Customizations -Title "Undo: $($s.Title)" -Why 'Puts back what AVDTune changed for this customization.' -Risk Medium -Test $test -Apply $apply
}

function New-AVDTuneCustomFetch {
    <#
        The fetch block of a run: the library file from the cache (<root>\custom\files, admin-only), checked against the pinned SHA256 every time; downloaded with
        -Context when it is missing or different (Save-AVDTuneAssetFile checks the hash again). Without -Context only the cache is used.
    #>
    param([Parameter(Mandatory)]$C, [Parameter(Mandatory)][string]$Root, $Context)
    $ctx = $Context; $r = $Root
    { param($Name, $Sha256)
        $dir = & $C.CacheFolder $r
        $path = Join-Path $dir ($Sha256 + [IO.Path]::GetExtension($Name).ToLowerInvariant())
        $h = & $C.FileHash $path
        if ($h -eq $Sha256) { return $path }
        if ($null -ne $h) { & $C.FileDelete $path }
        if (-not $ctx) { throw "The library file $Name is not in the cache and the library is not open (sign in on the Overview and read the library)." }
        $part = "$path.$([guid]::NewGuid().ToString('N').Substring(0, 8)).part"
        try { & $C.Download $ctx $Name $Sha256 $part; & $C.FileMove $part $path } finally { if ($null -ne (& $C.FileHash $part)) { & $C.FileDelete $part } }
        if ((& $C.FileHash $path) -ne $Sha256) { throw "The library file $Name does not match its SHA256 after the download." }
        $path
    }.GetNewClosure()
}

#endregion

#region status and runs

function Get-AVDTuneCustomStatus {
    <#
        Read only: every saved item with its test result and, for shortcuts, whether target, working folder and icon are reachable. Library files are taken from
        the cache only (no download): a script that is not cached yet says so. Returns Items (Id, Kind, Name, Title, Status, State, Message, Reach, Undo) and Invalid.
    #>
    param([Parameter(Mandatory)]$Machine, [Parameter(Mandatory)]$C, [string]$Root = (Get-AVDTuneRoot), [switch]$NoScripts, [switch]$CheckUnc)
    $forbidden = Get-AVDTuneCustomForbiddenFolders -Root $Root
    $list = Get-AVDTuneCustomizations -Root $Root -Forbidden $forbidden
    $undo = Read-AVDTuneCustomUndo $Root
    $fetch = New-AVDTuneCustomFetch -C $C -Root $Root
    $rows = foreach ($i in $list.Items) {
        $row = [ordered]@{ Id = $i.Id; Kind = $i.Kind; Name = $i.Name; Title = (Get-AVDTuneCustomTitle $i); Status = 'Unknown'; State = ''; Message = ''; Reach = @(); Undo = $undo.ContainsKey($i.Id); Item = $i }
        if ($i.Kind -eq 'Script' -and $NoScripts) { $row.Message = 'Not tested (scripts are tested on request).' }
        else {
            $r = Invoke-AVDTuneStep -Step (New-AVDTuneCustomStep -Item $i -C $C -Fetch $fetch -Forbidden $forbidden) -Machine $Machine -Mode Test
            $row.Status = $r.Status; $row.State = [string]$r.Before; $row.Message = [string]$r.Message
        }
        if ($i.Kind -eq 'Shortcut') {
            # a UNC path is only asked on request: asking sends the administrator's NTLM credentials to that host (review #85, L2). Ok = $null: not checked.
            $ask = { param($p) if ($p.StartsWith('\\') -and -not $CheckUnc) { $null } else { [bool](& $C.Reachable $p) } }
            $reach = @(@{ What = 'Target'; Path = $i.Target; Ok = (& $ask $i.Target) })
            if ($i.WorkingDirectory) { $reach += @{ What = 'Working folder'; Path = $i.WorkingDirectory; Ok = (& $ask $i.WorkingDirectory) } }
            if ($i.IconSource -eq 'Library') {
                $ico = (Get-AVDTuneCustomIconPath -Item $i -C $C) -replace ',\d+\z', ''
                $ok = ((& $C.FileHash $ico) -eq $i.IconSha256)
                if (-not $ok) { try { [void](& $fetch $i.IconFile $i.IconSha256); $ok = $true } catch { } }
                $reach += @{ What = 'Icon'; Path = $(if ($ok) { $ico } else { "library file $($i.IconFile) (not in the cache yet)" }); Ok = $ok }
            }
            else { $reach += @{ What = 'Icon'; Path = $i.Target; Ok = $reach[0].Ok } }
            $row.Reach = @($reach | ForEach-Object { [pscustomobject]$_ })
        }
        [pscustomobject]$row
    }
    [pscustomobject]@{ Items = @($rows); Invalid = @($list.Invalid); Problem = $list.Problem }
}

function Invoke-AVDTuneCustomRun {
    <#
        Apply or Undo of the chosen items (-Ids; all valid items when empty) through Invoke-AVDTune. Apply: the state before is read first, and after the run an undo
        record is kept for every item whose step Changed (an older record of the item stays). Undo: only items with a record; a reverted item loses its record.
        -Context opens the library for files that are not cached. Returns the run plus Skipped (items without anything to undo).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Machine, [Parameter(Mandatory)]$C, [string]$Root = (Get-AVDTuneRoot), [ValidateSet('Apply', 'Undo')][string]$Mode = 'Apply', [string[]]$Ids = @(), $Context,
        [string]$User, [string]$SnapshotId, [switch]$WhatIf)
    $forbidden = Get-AVDTuneCustomForbiddenFolders -Root $Root
    $list = Get-AVDTuneCustomizations -Root $Root -Forbidden $forbidden
    if ($list.Problem) { throw $list.Problem }
    $items = @($list.Items | Where-Object { $Ids.Count -eq 0 -or $_.Id -in $Ids })
    $unknown = @($Ids | Where-Object { $_ -notin @($list.Items | ForEach-Object { $_.Id }) })
    if ($unknown.Count -gt 0) { throw "Not in the list (or not valid): $($unknown -join ', ')." }
    $fetch = New-AVDTuneCustomFetch -C $C -Root $Root -Context $Context
    $undo = Read-AVDTuneCustomUndo $Root
    $steps = New-Object System.Collections.ArrayList; $skipped = New-Object System.Collections.ArrayList; $before = @{}; $byStep = @{}
    foreach ($i in $items) {
        if ($Mode -eq 'Apply') {
            $before[$i.Id] = Get-AVDTuneCustomBefore -Item $i -C $C
            $s = New-AVDTuneCustomStep -Item $i -C $C -Fetch $fetch -Forbidden $forbidden
        }
        else {
            if (-not $undo.ContainsKey($i.Id)) { [void]$skipped.Add([pscustomobject]@{ Id = $i.Id; Title = (Get-AVDTuneCustomTitle $i); Message = 'Nothing to undo: AVDTune has not changed this on the master.' }); continue }
            $b = Get-AVDTuneProp $undo[$i.Id] 'Before'
            $bh = @{}; if ($b) { foreach ($p in $b.PSObject.Properties) { $bh[$p.Name] = $p.Value } }
            $orig = New-AVDTuneCustomStep -Item $i -C $C -Fetch $fetch -Before $bh -Forbidden $forbidden
            if (-not $orig.Undo) { [void]$skipped.Add([pscustomobject]@{ Id = $i.Id; Title = $orig.Title; Message = 'This customization has no undo (a script without an undo part).' }); continue }
            $s = New-AVDTuneCustomUndoStep -Step $orig
        }
        [void]$steps.Add($s); $byStep[$s.Id] = $i
    }
    if ($steps.Count -eq 0) { return [pscustomobject]@{ Run = $null; Skipped = @($skipped) } }
    $run = Invoke-AVDTune -Plan ([pscustomobject]@{ Name = "Customizations $($Mode.ToLower())"; Steps = @($steps | ForEach-Object { $_.Id }) }) -Catalog @($steps) -Machine $Machine -Root $Root -User $User -SnapshotId $SnapshotId -WhatIf:$WhatIf
    if (-not $WhatIf) {
        $changed = $false
        foreach ($r in @($run.Results)) {
            $i = $byStep[$r.Id]; if (-not $i) { continue }
            if ($Mode -eq 'Apply' -and $r.Status -eq 'Changed' -and -not $undo.ContainsKey($i.Id)) { $undo[$i.Id] = [ordered]@{ Id = $i.Id; Kind = $i.Kind; At = (& $Machine.Now).ToString('o'); Before = $before[$i.Id] }; $changed = $true }
            if ($Mode -eq 'Undo' -and $r.Status -in 'Changed', 'Unchanged' -and $undo.ContainsKey($i.Id)) { $undo.Remove($i.Id); $changed = $true }
        }
        if ($changed) { Write-AVDTuneCustomUndo $Root $undo }
    }
    [pscustomobject]@{ Run = $run; Skipped = @($skipped) }
}

function Invoke-AVDTuneCustomScriptTest {
    <#
        The test of the library scripts runs code of the customer as administrator: behind the write gate and like a run that changes the master (change marker, LastChange,
        run record), because nobody can say what a test part does (review #85, L5). Returns the status with the scripts tested.
    #>
    param([Parameter(Mandatory)]$Machine, [Parameter(Mandatory)]$C, [string]$Root = (Get-AVDTuneRoot), [switch]$CheckUnc)
    if (-not (Test-AVDTuneWriteAllowed)) { throw 'The snapshot gate is not confirmed: the library scripts are not tested.' }
    $started = & $Machine.Now
    $owner = Start-AVDTuneChange -Root $Root
    try {
        $st = Get-AVDTuneCustomStatus -Machine $Machine -C $C -Root $Root -CheckUnc:$CheckUnc
        $ended = (& $Machine.Now).ToString('o')
        $state = Get-AVDTuneState $Root
        $results = @($st.Items | Where-Object { $_.Kind -eq 'Script' } | ForEach-Object { [pscustomobject]@{ Id = (Get-AVDTuneCustomStepId $_.Item); Section = 'Customizations'; Title = $_.Title; Mode = 'Test'; Status = $_.Status; Before = $_.State; After = $null; Message = $_.Message; Reboot = $false; WhatIf = $false; At = $ended } })
        [void](Add-AVDTuneRun -Root $Root -Run ([pscustomobject][ordered]@{ Id = $null; Plan = 'Customizations script test'; Started = $started.ToString('o'); Ended = $ended; User = ''; SnapshotId = ''; WhatIf = $false; ImageVersion = $state.ImageVersion; Reboot = $false; Results = $results }))
        [void](Set-AVDTuneState -Root $Root -Values @{ LastChange = $ended; FirstChange = $started.ToString('o') })
        $st
    }
    finally { Stop-AVDTuneChange -Root $Root -Owner $owner }
}

function Get-AVDTuneCustomPreview {
    # What the administrator confirms before a library file or script is saved (review #85, M3/L1): name, size, SHA256 and, for text, the first lines. The file comes through the fetch (pinned hash).
    param([Parameter(Mandatory)]$C, [Parameter(Mandatory)][string]$Root, $Context, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Sha256, [int]$Lines = 12)
    $path = & (New-AVDTuneCustomFetch -C $C -Root $Root -Context $Context) $Name $Sha256
    $text = [IO.Path]::GetExtension($Name).ToLowerInvariant() -in '.ps1', '.txt', '.ini', '.xml', '.json', '.cfg', '.config', '.reg', '.url'
    $first = @()
    if ($text) { $f = & $C.ReadText $path; if ($f) { $first = @((Split-AVDTuneCustomLines $f.Text) | Select-Object -First $Lines | ForEach-Object { Remove-AVDTuneControlCharacters $_ 200 }) } }
    [pscustomobject]@{ Name = $Name; Sha256 = $Sha256; Size = [int64](& $C.FileSize $path); Lines = @($first) }
}

function Get-AVDTuneCustomMaskingRequest {
    # Pure: what the App Masking mechanism (#69) is asked for after a Desktop shortcut was made: the file name on the Public Desktop, the mode and the group SID; $null when nothing is asked
    param([Parameter(Mandatory)]$Item)
    if ($Item.Kind -ne 'Shortcut' -or -not $Item.Visibility -or $Item.Location -notin 'Desktop', 'Both') { return $null }
    if ($Item.Visibility -eq 'Admins') { return [pscustomobject]@{ FileName = "$($Item.Name).lnk"; Mode = 'Nobody except administrators'; GroupSid = '' } }
    [pscustomobject]@{ FileName = "$($Item.Name).lnk"; Mode = 'Only members of a group'; GroupSid = $Item.Visibility }
}

function Get-AVDTuneCustomKinds { @($script:Kinds) }
function Get-AVDTuneCustomFields([string]$Kind) { @($script:Fields[$Kind]) }
function Get-AVDTuneCustomChoices { [pscustomobject]@{ Locations = @($script:Locations); ValueTypes = @($script:ValueTypes); Rights = @($script:Rights.Keys); Principals = @($script:PrincipalAlias.Keys) } }

#endregion

#region real adapter

function Assert-AVDTuneCustomNoLink {
    # No component of the path, from the drive root down, may be a link (junction, symbolic link); a missing tail is fine
    param([Parameter(Mandatory)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path).TrimEnd([char]92)
    $root = [IO.Path]::GetPathRoot($full)
    $cur = $root.TrimEnd([char]92)
    foreach ($p in @($full.Substring($root.Length).Split([char]92) | Where-Object { $_ })) {
        $cur = "$cur\$p"
        $info = New-Object IO.FileInfo $cur
        if (-not $info.Exists -and -not (New-Object IO.DirectoryInfo $cur).Exists) { return }
        if (($info.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "$cur is a link: nothing is written through it." }
    }
}

function New-AVDTuneCustomAdapter {
    <# The real adapter. NOT exercised by the checks beyond construction: written from the documentation, to be tried on a throw-away VM. #>
    $u = New-AVDTuneUpdateAdapter
    $a = [ordered]@{ Kind = 'Real' }
    $a.Folder = {
        param($Name)
        switch ($Name) {
            'PublicDesktop' { [Environment]::GetFolderPath('CommonDesktopDirectory') }
            'StartMenu' { [Environment]::GetFolderPath('CommonPrograms') }
            'Fonts' { Join-Path (Get-AVDTuneSystemFolder Windows) 'Fonts' }
            'Hosts' { Join-Path (Get-AVDTuneSystemFolder System) 'drivers\etc\hosts' }
            'PublicIcons' { Join-Path (Get-AVDTuneSystemFolder ProgramData) 'AVDTune-Public\Icons' }
            default { throw "Unknown folder $Name." }
        }
    }
    $a.RegGet = {
        param($Path, $Name)
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
        try {
            $k = $base.OpenSubKey(($Path -replace '^HKLM:\\', ''), $false); if (-not $k) { return $null }
            try { if (@($k.GetValueNames() | Where-Object { $_ -ieq $Name }).Count -eq 0) { return $null }; @{ Value = $k.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames); Kind = [string]$k.GetValueKind($Name) } } finally { $k.Dispose() }
        }
        finally { $base.Dispose() }
    }
    $a.RegSet = {
        param($Path, $Name, $Value, $Type)
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
        try { $k = $base.CreateSubKey(($Path -replace '^HKLM:\\', '')); try { $k.SetValue($Name, $Value, [Microsoft.Win32.RegistryValueKind]$Type) } finally { $k.Dispose() } } finally { $base.Dispose() }
    }
    $a.RegRemove = {
        param($Path, $Name)
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
        try { $k = $base.OpenSubKey(($Path -replace '^HKLM:\\', ''), $true); if ($k) { try { $k.DeleteValue($Name, $false) } finally { $k.Dispose() } } } finally { $base.Dispose() }
    }
    $a.FileHash = {
        param($Path)
        $f = New-Object IO.FileInfo $Path
        if (-not $f.Exists) { return $null }
        if (($f.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "$Path is a link." }
        $s = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try { Get-AVDTuneStreamHash $s } finally { $s.Dispose() }
    }
    $a.ReadText = {
        param($Path)
        $f = New-Object IO.FileInfo $Path
        if (-not $f.Exists) { return $null }
        if (($f.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "$Path is a link: not read." }
        if ($f.Length -gt 4MB) { throw "$Path is larger than 4 MB: not read." }
        $bytes = [IO.File]::ReadAllBytes($Path)
        $enc = if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) { 'utf-16' } elseif ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { 'utf-8-bom' } else { 'ansi' }
        $text = switch ($enc) { 'utf-16' { [Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2) } 'utf-8-bom' { [Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3) } default { [Text.Encoding]::Default.GetString($bytes) } }
        @{ Text = $text; Encoding = $enc }
    }
    $a.WriteText = {
        # The new content atomically next to the old file, or a new file in an existing folder; no component of the path may be a link
        param($Path, $Text, $Encoding)
        Assert-AVDTuneCustomNoLink $Path
        if (-not (Test-Path -LiteralPath (Split-Path $Path -Parent) -PathType Container)) { throw "The folder of $Path does not exist." }
        $pre = switch ($Encoding) { 'utf-16' { [byte[]](0xFF, 0xFE) } 'utf-8-bom' { [byte[]](0xEF, 0xBB, 0xBF) } default { [byte[]]@() } }
        $body = switch ($Encoding) { 'utf-16' { [Text.Encoding]::Unicode.GetBytes($Text) } 'ansi' { [Text.Encoding]::Default.GetBytes($Text) } default { (New-Object Text.UTF8Encoding $false).GetBytes($Text) } }
        # atomic (review #85, L4): a temp file next to the target that takes the ACL and owner of the target on purpose (CreateNew with that security), then
        # Move-AVDTuneFileReplace; a missing file is made new in its existing folder (it inherits)
        $exists = Test-Path -LiteralPath $Path -PathType Leaf
        $temp = if ($exists) { "$Path.$([guid]::NewGuid().ToString('N').Substring(0, 8)).tmp" } else { $Path }
        try {
            $s = if ($exists) {
                $sec = (New-Object IO.FileInfo $Path).GetAccessControl([Security.AccessControl.AccessControlSections]'Access, Owner')
                New-Object IO.FileStream($temp, [IO.FileMode]::CreateNew, [Security.AccessControl.FileSystemRights]'Write, ReadPermissions', [IO.FileShare]::None, 4096, [IO.FileOptions]::None, $sec)
            } else { New-Object IO.FileStream($temp, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None) }
            try { $s.Write($pre, 0, $pre.Length); $s.Write($body, 0, $body.Length); $s.Flush($true) } finally { $s.Dispose() }
            if ($exists) { Move-AVDTuneFileReplace $temp $Path }
        }
        finally { if ($exists -and (Test-Path -LiteralPath $temp)) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue } }
    }
    $a.FileSize = { param($Path) (New-Object IO.FileInfo $Path).Length }
    $a.FileDelete = { param($Path) if ((Test-Path -LiteralPath $Path -PathType Leaf) -and -not (Remove-AVDTuneTreeSafe -Path $Path).Gone) { throw "$Path could not be deleted (in use)." } }
    $a.FileMove = { param($From, $To) [IO.File]::Move($From, $To) }
    $a.CopyFile = {
        # A new file (CreateNew, never over an existing one) with the ACL of New-AVDTuneFileSecurity (Administrators/SYSTEM full, Users read); UsersRead creates a missing folder read only for users
        param($From, $To, $Access)
        Assert-AVDTuneCustomNoLink $To
        $dir = Split-Path $To -Parent
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
            if ($Access -eq 'UsersRead') { Assert-AVDTuneCustomNoLink $dir; (New-Object IO.DirectoryInfo $dir).Create((New-AVDTuneUsersReadSecurity)) } else { throw "The folder $dir does not exist." }
        }
        if ($Access -eq 'UsersRead') { $p = @(Get-AVDTuneAclProblems (Read-AVDTuneAclReport $dir)); if ($p.Count -gt 0) { throw "$dir is not safe ($($p -join '; ')): nothing was written." } }
        $in = [IO.File]::Open($From, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            $out = New-Object IO.FileStream($To, [IO.FileMode]::CreateNew, [Security.AccessControl.FileSystemRights]'Write, ReadPermissions', [IO.FileShare]::None, 81920, [IO.FileOptions]::None, (New-AVDTuneFileSecurity))
            try { $in.CopyTo($out); $out.Flush($true) } finally { $out.Dispose() }
        }
        finally { $in.Dispose() }
    }
    $a.DirInfo = {
        param($Path)
        $d = New-Object IO.DirectoryInfo $Path
        if (-not $d.Exists) { return @{ Exists = $false; Link = $false; Rules = @() } }
        $acl = $d.GetAccessControl([Security.AccessControl.AccessControlSections]::Access)
        @{ Exists = $true; Link = (($d.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
            Rules = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | Where-Object { $_.AccessControlType -eq 'Allow' } | ForEach-Object { @{ Sid = [string]$_.IdentityReference.Value; Rights = [int]$_.FileSystemRights; Inherited = [bool]$_.IsInherited; Inherit = [int]$_.InheritanceFlags; Propagate = [int]$_.PropagationFlags } }) }
    }
    $a.DirCreate = { param($Path) Assert-AVDTuneCustomNoLink $Path; $parent = Split-Path $Path -Parent; if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw "The folder $parent does not exist." }; [void](New-Object IO.DirectoryInfo $Path).Create() }
    $a.DirAddRule = {
        param($Path, $Sid, $Rights, $Inherit = 3, $Propagate = 0)
        Assert-AVDTuneCustomNoLink $Path
        if ([int]$Rights -ne [int]$script:Rights['ReadAndExecute']) { $rp = Get-AVDTuneCustomRuleProblem -Path $Path -Sid $Sid -Rights 'Write' -Forbidden (Get-AVDTuneCustomForbiddenFolders); if ($rp) { throw $rp } }   # the adapter checks again (review #85, M2)
        $d = New-Object IO.DirectoryInfo $Path
        $acl = $d.GetAccessControl([Security.AccessControl.AccessControlSections]::Access)
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier $Sid), [Security.AccessControl.FileSystemRights]$Rights, [Security.AccessControl.InheritanceFlags][int]$Inherit, [Security.AccessControl.PropagationFlags][int]$Propagate, 'Allow')))
        $d.SetAccessControl($acl)
    }
    $a.DirRemoveRule = {
        param($Path, $Sid, $Rights)
        $d = New-Object IO.DirectoryInfo $Path
        if (-not $d.Exists) { return }
        Assert-AVDTuneCustomNoLink $Path
        $acl = $d.GetAccessControl([Security.AccessControl.AccessControlSections]::Access)
        [void]$acl.RemoveAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier $Sid), [Security.AccessControl.FileSystemRights]$Rights, 'ContainerInherit, ObjectInherit', 'None', 'Allow')))
        $d.SetAccessControl($acl)
    }
    $a.DirRemoveEmpty = { param($Path) $d = New-Object IO.DirectoryInfo $Path; if ($d.Exists -and ($d.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0 -and @($d.GetFileSystemInfos()).Count -eq 0) { $d.Delete() } }
    $a.ShortcutRead = {
        param($Path)
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
        $shell = New-Object -ComObject WScript.Shell
        try { $l = $shell.CreateShortcut($Path); $o = [pscustomobject]@{ Target = [string]$l.TargetPath; Arguments = [string]$l.Arguments; Icon = [string]$l.IconLocation; Description = [string]$l.Description; WorkingDirectory = [string]$l.WorkingDirectory }; [void][Runtime.InteropServices.Marshal]::ReleaseComObject($l); $o }
        finally { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
    }
    $a.ShortcutWrite = {
        # Made in the admin-only state folder with the strict ACL, then moved atomically into place (Public Desktop: the Windows default write access of users is accepted, everything else stops)
        param($Path, $Target, $Arguments, $Icon, $WorkingDirectory, $Description)
        $folder = Split-Path $Path -Parent
        $problems = if ($folder -ieq [Environment]::GetFolderPath('CommonDesktopDirectory')) { @((Get-AVDTunePublicDesktopFindings -Path $Path).Problems) } else { @(Get-AVDTuneWriteChainProblems -Path $Path -AllowMissingLeaf) }
        if (@($problems).Count -gt 0) { throw "The folder of $Path is not safe ($(@($problems) -join '; ')): no shortcut was written." }
        $tempDir = Join-Path (Get-AVDTuneRoot) 'temp'
        [void][IO.Directory]::CreateDirectory($tempDir)
        $tp = @(Get-AVDTuneAclProblems (Read-AVDTuneAclReport $tempDir)); if ($tp.Count -gt 0) { throw "$tempDir is not safe ($($tp -join '; '))." }
        $temp = Join-Path $tempDir ([guid]::NewGuid().ToString('N').Substring(0, 8) + '.tmp.lnk')
        $shell = New-Object -ComObject WScript.Shell
        try {
            $l = $shell.CreateShortcut($temp); $l.TargetPath = $Target; $l.Arguments = $Arguments; $l.IconLocation = $Icon; $l.Description = $Description; $l.WorkingDirectory = $WorkingDirectory; $l.Save(); [void][Runtime.InteropServices.Marshal]::ReleaseComObject($l)
            (New-Object IO.FileInfo $temp).SetAccessControl((New-AVDTuneFileSecurity))
            Move-AVDTuneFileReplace $temp $Path
        }
        finally { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell); if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue } }
    }
    $a.ShortcutDelete = { param($Path) if (Test-Path -LiteralPath $Path) { $r = Read-AVDTuneAclReport $Path; if ($r.Link) { throw "$Path is a link." }; if (-not (Remove-AVDTuneTreeSafe -Path $Path).Gone) { throw "$Path could not be deleted (in use)." } } }
    $a.Reachable = { param($Path) try { [IO.File]::Exists($Path) -or [IO.Directory]::Exists($Path) } catch { $false } }
    $a.CacheFolder = { param($Root) $d = Join-Path $Root 'custom\files'; New-AVDTuneWorkFolder -Path $d -Base $Root; $d }
    $a.Download = { param($Context, $Name, $Sha256, $Destination) [void](Save-AVDTuneAssetFile -Context $Context -Name $Name -Sha256 $Sha256 -Destination $Destination) }
    $a.RunScript = {
        # The signed Windows PowerShell from System32 (never PATH), the script held open (read sharing only) and checked against its pin through that handle while it runs,
        # a broken signature stops it, the tree runs in a job object (update adapter Run) and ends at the timeout
        param($Path, $Sha256, $Mode, $TimeoutSeconds)
        $ps = Join-Path (Get-AVDTuneSystemFolder System) 'WindowsPowerShell\v1.0\powershell.exe'
        $trust = Test-AVDTuneToolTrust -Signature (& $u.VerifySignature $ps) -Name 'powershell.exe'
        if (-not $trust.Ok) { throw "Windows PowerShell is not trusted: $($trust.Reason)" }
        $hold = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            if ((Get-AVDTuneStreamHash $hold) -ne $Sha256) { throw 'The script does not match its pinned SHA256: not started.' }
            $sig = Get-AuthenticodeSignature -LiteralPath $Path
            if ([string]$sig.Status -in 'HashMismatch', 'NotSupportedFileFormat', 'Incompatible') { throw "The signature of the script is broken ($($sig.Status)): not started." }
            $r = & $u.Run $ps @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $Path, '-AVDTuneMode', $Mode) $TimeoutSeconds
        }
        finally { $hold.Dispose() }
        [pscustomobject]@{ ExitCode = [int]$r.ExitCode; Output = (Remove-AVDTuneControlCharacters ([string]$r.Output) 2000) }
    }.GetNewClosure()   # keeps $u (the update adapter); only exported functions inside (#78)
    [pscustomobject]$a
}

#endregion

Export-ModuleMember -Function Test-AVDTuneCustomMatch, Test-AVDTuneCustomText, Test-AVDTuneCustomPathSegments, Test-AVDTuneCustomLocalPath, Test-AVDTuneCustomUncPath, ConvertTo-AVDTuneCustomRegPath,
    Test-AVDTuneCustomHostName, Test-AVDTuneCustomAddress, ConvertTo-AVDTuneCustomSid, Get-AVDTuneCustomForbiddenFolders, Test-AVDTuneCustomForbidden, ConvertTo-AVDTuneCustomItem,
    Split-AVDTuneCustomLines, Get-AVDTuneIniValue, Set-AVDTuneIniValue, Test-AVDTuneHostsEntry, Get-AVDTuneHostsLine, Set-AVDTuneHostsEntry,
    Get-AVDTuneCustomPath, Get-AVDTuneCustomUndoPath, Get-AVDTuneCustomizations, Save-AVDTuneCustomizations, Add-AVDTuneCustomItem, Remove-AVDTuneCustomItem, Read-AVDTuneCustomUndo, Write-AVDTuneCustomUndo,
    Get-AVDTuneCustomStepId, Get-AVDTuneCustomTitle, Get-AVDTuneCustomShortcutPaths, Get-AVDTuneCustomIconPath, ConvertTo-AVDTuneCustomRegValue, Test-AVDTuneCustomRegEqual, Get-AVDTuneCustomBefore,
    New-AVDTuneCustomStep, New-AVDTuneCustomUndoStep, New-AVDTuneCustomFetch, Get-AVDTuneCustomStatus, Invoke-AVDTuneCustomRun, Get-AVDTuneCustomMaskingRequest,
    Get-AVDTuneCustomKinds, Get-AVDTuneCustomFields, Get-AVDTuneCustomChoices, Assert-AVDTuneCustomNoLink, New-AVDTuneCustomAdapter,
    Get-AVDTuneCustomRegRisk, ConvertTo-AVDTuneCustomLong, Test-AVDTuneCustomUnder, Test-AVDTuneCustomInPrograms, Test-AVDTuneCustomStartup, Test-AVDTuneCustomBroadSid, Get-AVDTuneCustomRuleProblem,
    Get-AVDTuneCustomFontValueName, Invoke-AVDTuneCustomScriptTest, Get-AVDTuneCustomPreview
