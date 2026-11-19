<#
    Custom software with recording (docs\plans\avdtune.md, section 3e; issue #87), first stage: the installer of an app the customer installs by hand is taken from the
    library (AVDTune-Assets in the PackTune store, SHA256 pinned when the wizard reads the form, like the customizations of #85), run on the master while AVDTune records
    what changed, and the recording is kept as documentation and recipe (detection rule, silent command, uninstall command) under <root>\software\custom\<app>\<nnn>.

      * Recording = a read-only before/after comparison of installed programs (uninstall keys, 64 and 32 bit), files (Program Files, Program Files (x86), ProgramData,
        Public Desktop), HKLM\SOFTWARE keys (and WOW6432Node), services and drivers, and the shortcuts of the Public Desktop and the Start menu. Every area is bounded
        (entries, depth); a cut area is named in the record. Links are listed, never followed. Everything read is data: control characters out, lengths limited, the
        documentation HTML-encodes every value and runs no script.
      * The install is one step through Invoke-AVDTune (write gate, change marker, run record, LastChange, change log); the snapshots run under the same marker.
        The installer: fetched against its pinned SHA256 (New-AVDTuneCustomFetch, cache <root>\custom\files), copied into a new download folder (New-AVDTuneDownloadFolder),
        held open without write/delete sharing and checked against the pin through that handle, its Authenticode signature read (a broken one stops it; unsigned is
        allowed because the pin is the anchor, and recorded), started with its full path inside the lock Global\PackTune, in a job object with a timeout (an .msi through
        the checked msiexec of System32). The download folder is removed afterwards with Remove-AVDTuneTreeSafe.
      * Second stage (#93): the comparison also covers scheduled tasks, firewall rules, ODBC data sources, the machine environment, hosts entries and fonts;
        "Reinstall" runs the recipe (the newest successful recording: same pinned file, same arguments, every check again); notes of the administrator written while
        the recording runs (text only, bounded, cleaned of secrets); step images of the installer's windows (only when asked for: PrintWindow of the windows of the
        installer's process tree, never the screen, never a window with a password field, bounded in number and size, kept in the admin-only record folder).
      * Still open (plan 3e): click-exact steps with UI Automation names, blurring, process recording, PDF, watched source, the review before saving.
      * Every access to the master goes through the recording adapter ($R): New-AVDTuneRecordingAdapter is the real one (NOT exercised by the checks beyond construction,
        to be tried on a throw-away VM); Tests\Fakes\FakeRecording.ps1 is the fake.
#>

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'AVDTune.psm1')
Import-Module (Join-Path $PSScriptRoot 'AVDTune.Updates.psm1')
Import-Module (Join-Path $PSScriptRoot 'AVDTune.Software.psm1')
Import-Module (Join-Path $PSScriptRoot 'AVDTune.Custom.psm1')   # Test-AVDTuneCustomText/-Match, New-AVDTuneCustomFetch (the pinned library files)

$script:Fields = @('Name', 'Vendor', 'Version', 'Contact', 'Installer', 'Sha256', 'Arguments', 'Dependencies', 'LicenseNotes', 'TimeoutSeconds')
$script:Extensions = @('.msi', '.exe')
$script:ArgPattern = '\A[A-Za-z0-9 _.,:;/=+@()\\"''-]{0,512}\z'   # no % & | < > ^ ` $ ! : the arguments are data, quoted per token
$script:BrokenSignature = @('HashMismatch', 'NotSupportedFileFormat', 'Incompatible')
$script:DefaultLimits = @{ Files = 200000; Depth = 8; RegistryKeys = 150000; RegistryDepth = 5; Shortcuts = 3000; ListPerArea = 2000; Tasks = 2000; Firewall = 5000; Odbc = 500; Environment = 500; Hosts = 2000; Fonts = 5000; Notes = 50; NoteLength = 500; StepImages = 40; StepImageBytes = 2097152; StepIntervalMs = 1500 }
$script:Areas = @('Programs', 'Files', 'Registry', 'Services', 'Shortcuts', 'Tasks', 'Firewall', 'Odbc', 'Environment', 'Hosts', 'Fonts')   # Tasks..Fonts: #93
$script:CleanedAreas = @('Services', 'Shortcuts', 'Tasks', 'Firewall', 'Odbc')   # string values that can hold a command line or a connection: cleaned by Protect-AVDTuneRecordingSnapshot
$script:SecretName = '(?i)(passwor[dt]|passwd|pwd|kennwort|secret|token|api_?key|licen[cs]e|lizenz|serial|credential|(\A|_)(key|pat|sas)(\z|_))'   # an environment variable with such a name: its value is never stored
$script:Kinds = @('Install', 'Update', 'Reinstall')
$script:StepFilePattern = '\A[0-9a-f]{12}-[0-9]{3}-step-[0-9]{3}\.png\z'   # the only file names that become step images (unique per app and recording, so one folder can hold many)
$script:RegexTimeout = [TimeSpan]::FromMilliseconds(200)

#region details (pure)

function Get-AVDTuneRecordingProp($Object, [string]$Name) {
    # A property of an object or a key of a dictionary (the adapters return hashtables, the state pscustomobjects); $null when it is not there
    if ($Object -is [System.Collections.IDictionary]) { if ($Object.Contains($Name)) { return $Object[$Name] }; return $null }
    Get-AVDTuneProp $Object $Name
}

function Remove-AVDTuneRecordingSecrets {
    <# Pure. Licence notes and other free text: passwords, keys and product keys go out before anything is stored. Returns Text and Cleaned (something was taken out). #>
    param([AllowEmptyString()][string]$Text)
    if (-not $Text) { return [pscustomobject]@{ Text = ''; Cleaned = $false } }
    $t = $Text
    $rules = @(
        @('(?i)\b(password|passwort|kennwort|pwd|pass|secret|token|pin|key|schl(ü|ue)ssel|licen[cs]e\s*key|lizenzschl(ü|ue)ssel|serial|seriennummer)\s*[=:]\s*\S+', '$1=(removed)'),
        # a GUID (product code, {xxxxxxxx-xxxx-...}) is no key: it stays (uninstall strings, keys of the registry)
        @('\b(?![0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-)[A-Za-z0-9]{4,8}(-[A-Za-z0-9]{4,8}){3,}\b', '(key removed)'),
        @('\b(?![0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b)[A-Za-z0-9+/_\-]{32,}={0,2}', '(removed)')
    )
    foreach ($r in $rules) { try { $t = [regex]::Replace($t, $r[0], $r[1], [Text.RegularExpressions.RegexOptions]::None, $script:RegexTimeout) } catch { return [pscustomobject]@{ Text = ''; Cleaned = $true } } }
    [pscustomobject]@{ Text = $t; Cleaned = ($t -cne $Text) }
}

function ConvertTo-AVDTuneRecordingApp {
    <#
        Validates the details of an app (from the form with -FromForm: the timeout as text is parsed, an id is made, text is trimmed, the licence notes are cleaned;
        from the state: types must be exact). -Library (the files of the manifest) pins Sha256 from the manifest when the form names a library file.
        Returns Valid, Errors, App, Cleaned.
    #>
    param([Parameter(Mandatory)]$Raw, [switch]$FromForm, [object[]]$Library, [switch]$Stored)
    $errors = New-Object System.Collections.ArrayList
    $get = { param($n) Get-AVDTuneProp $Raw $n }
    if ($Raw -is [System.Collections.IDictionary]) { $get = { param($n) if ($Raw.Contains($n)) { $Raw[$n] } else { $null } }.GetNewClosure() }
    $id = & $get 'Id'
    if (($null -eq $id -or '' -eq $id) -and $FromForm) { $id = [guid]::NewGuid().ToString('N').Substring(0, 12) }
    if ($id -isnot [string] -or $id -cnotmatch '\A[0-9a-f]{12}\z') { [void]$errors.Add('The id is not valid.'); $id = '' }
    $a = [ordered]@{ Id = $id }
    foreach ($f in $script:Fields) {
        $v = & $get $f
        if ($f -eq 'TimeoutSeconds') {
            if ($FromForm -and $v -is [string] -and $v.Trim() -match '\A[0-9]{1,6}\z') { $v = [int]$v.Trim() }
            if ($FromForm -and ($null -eq $v -or ($v -is [string] -and -not $v.Trim()))) { $v = 3600 }
            if (-not ($v -is [int] -or $v -is [long])) { [void]$errors.Add('Timeout must be a whole number.'); $v = 0 }
            $a[$f] = [int]$v; continue
        }
        if ($null -eq $v) { $v = '' }
        if ($v -isnot [string]) { [void]$errors.Add("$f must be text."); $v = '' }
        if ($FromForm) { $v = $v.Trim() }
        $a[$f] = $v
    }
    $cleaned = $false
    if ($FromForm) { foreach ($f in 'LicenseNotes', 'Contact', 'Dependencies') { $c = Remove-AVDTuneRecordingSecrets $a[$f]; if ($c.Cleaned) { $a[$f] = $c.Text; $cleaned = $true } } }
    elseif ((Remove-AVDTuneRecordingSecrets $a.LicenseNotes).Cleaned) { [void]$errors.Add('Licence notes: they contain something that looks like a key or password.') }
    if (-not (Test-AVDTuneCustomText $a.Name 1 80)) { [void]$errors.Add('Name: 1 to 80 characters, one line.') }
    if (-not (Test-AVDTuneCustomText $a.Vendor 0 80)) { [void]$errors.Add('Vendor: at most 80 characters, one line.') }
    if (-not (Test-AVDTuneCustomMatch $a.Version '\A[A-Za-z0-9._ ()+-]{0,40}\z' 40)) { [void]$errors.Add('Version: at most 40 letters, digits and . _ ( ) + -.') }
    foreach ($p in @(@('Contact', 200), @('Dependencies', 400), @('LicenseNotes', 1000))) { if (-not (Test-AVDTuneCustomText $a[$p[0]] 0 $p[1])) { [void]$errors.Add("$($p[0]): at most $($p[1]) characters, one line.") } }
    if (-not (Test-AVDTuneAssetName $a.Installer) -or [IO.Path]::GetExtension($a.Installer).ToLowerInvariant() -notin $script:Extensions) { [void]$errors.Add('Installer: choose an .msi or .exe of the library.') }
    elseif ($Library) { $hit = @(foreach ($l in $Library) { if ($l -and $l.Name -ceq $a.Installer) { $l } }); if ($hit.Count -eq 1) { $a.Sha256 = [string]$hit[0].Sha256 } }
    if ($a.Sha256 -notmatch '\A[0-9a-fA-F]{64}\z') { [void]$errors.Add('Installer: the SHA256 of the library file is missing (read the library first).') } else { $a.Sha256 = $a.Sha256.ToLowerInvariant() }
    if (-not (Test-AVDTuneCustomMatch $a.Arguments $script:ArgPattern 512) -or (@($a.Arguments.ToCharArray() | Where-Object { $_ -eq [char]34 }).Count % 2) -ne 0) { [void]$errors.Add('Arguments: at most 512 letters, digits, spaces and _ . , : ; / = + @ ( ) \ '' " - with closed quotes.') }
    # the rules for what the arguments may do (review #87): checked for every new recording, also for the arguments "Record update" takes over; a stored record
    # (-Stored, history) keeps the arguments it was made with as data
    $warnings = @()
    if (-not $Stored -and $errors.Count -eq 0) { $ar = Test-AVDTuneRecordingArguments -Installer $a.Installer -Arguments $a.Arguments; foreach ($e in $ar.Errors) { [void]$errors.Add($e) }; $warnings = @($ar.Warnings) }
    if ($a.TimeoutSeconds -lt 60 -or $a.TimeoutSeconds -gt 14400) { [void]$errors.Add('Timeout: 60 to 14400 seconds.') }
    [pscustomobject]@{ Valid = ($errors.Count -eq 0); Errors = @($errors); App = [pscustomobject]$a; Cleaned = $cleaned; Warnings = @($warnings) }
}

function Test-AVDTuneRecordingArguments {
    <#
        Pure apart from the program folders (-ProgramFolders, default Program Files and Program Files (x86)). What the arguments of an installer may do (review #87):
          * .msi: only the switches /qn /qb /qb- /quiet /passive /norestart and NAME=value with NAME of [A-Z0-9_]; TRANSFORMS and PATCH (they load more code) and every
            other switch (/p /a /x /y /z /j /f /l* /update /uninstall /package ...) are refused; a value that starts with \\ (UNC) is refused, a path value only below the
            program folders.
          * .exe: no UNC path anywhere; a path outside the program folders is a warning.
          * both: nothing that looks like a key or a password (PIDKEY, SERIALNUMBER, LICENSEKEY, PASSWORD, /password=, token patterns): refused, not cleaned; a key
            comes later through the vault.
        Returns Errors and Warnings.
    #>
    param([Parameter(Mandatory)][string]$Installer, [AllowEmptyString()][string]$Arguments, [string[]]$ProgramFolders)
    if (-not $ProgramFolders) { $ProgramFolders = @((Get-AVDTuneSystemFolder ProgramFiles), (Get-AVDTuneSystemFolder ProgramFilesX86)) }
    $errors = New-Object System.Collections.ArrayList; $warnings = New-Object System.Collections.ArrayList
    $inPrograms = { param($p) if ($p -match '\.\.|~\d') { return $false }; foreach ($f in $ProgramFolders) { if ($f -and $p.StartsWith($f.TrimEnd([char]92) + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true } }; $false }
    $secret = '(?i)(\A|[/\-\s])(PIDKEY|SERIALNUMBER|SERIAL|LICENSEKEY|LICENSE_KEY|LICENCEKEY|PRODUCTKEY|PRODUCT_KEY|PASSWORD|PASSWD|PWD|PASS|SECRET|TOKEN|APIKEY|API_KEY)\s*[=:]'
    $msi = [IO.Path]::GetExtension($Installer) -ieq '.msi'
    foreach ($t in @(Split-AVDTuneRecordingArguments $Arguments)) {
        $show = Remove-AVDTuneControlCharacters $t 60
        if ((Test-AVDTuneCustomMatch $t $secret 600) -or (Remove-AVDTuneRecordingSecrets $t).Cleaned) { [void]$errors.Add("Arguments: '$(($t -split '[=:]')[0])' looks like a key or password. Keys and passwords do not belong in the arguments; they will come later through the vault."); continue }
        if ($msi) {
            if ($t -match '\A[/-]') { if ($t -notin '/qn', '/qb', '/qb-', '/quiet', '/passive', '/norestart') { [void]$errors.Add("Arguments: the msiexec switch '$show' is not allowed (only /qn /qb /qb- /quiet /passive /norestart).") }; continue }
            $m = [regex]::Match($t, '\A([A-Z0-9_]{1,64})=(.*)\z', [Text.RegularExpressions.RegexOptions]::None, $script:RegexTimeout)
            if (-not $m.Success) { [void]$errors.Add("Arguments: '$show' is neither an allowed switch nor PROPERTY=value (property in capitals, digits and _)."); continue }
            if ($m.Groups[1].Value -in 'TRANSFORMS', 'PATCH') { [void]$errors.Add("Arguments: $($m.Groups[1].Value) is not allowed (it loads more code into the install).") ; continue }
            $v = $m.Groups[2].Value
            if ($v.StartsWith('\\') -or $v.StartsWith('//')) { [void]$errors.Add("Arguments: $($m.Groups[1].Value) points to a network path; not allowed.") }
            elseif ($v -match '\A[A-Za-z]:' -and -not (& $inPrograms $v)) { [void]$errors.Add("Arguments: the path of $($m.Groups[1].Value) must lie below Program Files.") }
        }
        else {
            if ($t.Contains('\\') -or $t.Contains('//')) { [void]$errors.Add("Arguments: '$show' contains a network path; not allowed."); continue }
            foreach ($p in [regex]::Matches($t, '[A-Za-z]:\\[^"]*', [Text.RegularExpressions.RegexOptions]::None, $script:RegexTimeout)) { if (-not (& $inPrograms $p.Value)) { [void]$warnings.Add("Arguments: $($p.Value) lies outside Program Files: check that the installer may write there.") } }
        }
    }
    [pscustomobject]@{ Errors = @($errors); Warnings = @($warnings) }
}

function Split-AVDTuneRecordingArguments {
    # Pure: the arguments of the form as tokens ("a b" is one token, without its quotes); each token is quoted again by the central start (ConvertTo-AVDTuneArgument)
    param([AllowEmptyString()][string]$Text)
    if (-not $Text) { return @() }
    $m = [regex]::Matches($Text, '(?:"[^"]*"|[^\s"])+', [Text.RegularExpressions.RegexOptions]::None, $script:RegexTimeout)
    @(foreach ($x in $m) { $x.Value.Replace('"', '') })
}

function Get-AVDTuneRecordingCommand {
    # Pure: what is started. An .msi through msiexec (/i <file> and the arguments), an .exe itself with the arguments. Returns Tool (msiexec.exe | installer) and Arguments.
    param([Parameter(Mandatory)]$App, [Parameter(Mandatory)][string]$Path)
    $tokens = @(Split-AVDTuneRecordingArguments $App.Arguments)
    if ([IO.Path]::GetExtension($App.Installer) -ieq '.msi') { return [pscustomobject]@{ Tool = 'msiexec.exe'; Arguments = @(@('/i', $Path) + $tokens) } }
    [pscustomobject]@{ Tool = 'installer'; Arguments = $tokens }
}

function Test-AVDTuneRecordingSignature {
    <#
        Pure: may the installer start with this Authenticode result (Status, Subject)? A broken signature (hash mismatch, a format that is not what it claims) stops it.
        Unsigned or not trusted is allowed, because the SHA256 pinned from the library is the anchor; it is named in the record and the documentation. Returns Ok and Text.
    #>
    param($Signature)
    $status = [string](Get-AVDTuneRecordingProp $Signature 'Status'); $subject = Remove-AVDTuneControlCharacters ([string](Get-AVDTuneRecordingProp $Signature 'Subject')) 300
    if (-not $status) { return [pscustomobject]@{ Ok = $false; Text = 'The signature could not be read.' } }
    if ($status -in $script:BrokenSignature) { return [pscustomobject]@{ Ok = $false; Text = "The signature of the installer is broken ($status)." } }
    if ($status -eq 'Valid') { return [pscustomobject]@{ Ok = $true; Text = "Signed: $subject" } }
    if ($status -eq 'NotSigned') { return [pscustomobject]@{ Ok = $true; Text = 'Not signed (only the pinned SHA256 vouches for it).' } }
    [pscustomobject]@{ Ok = $true; Text = "Signature not trusted ($status)$(if ($subject) { ": $subject" }); only the pinned SHA256 vouches for it." }
}

#endregion

#region recording (pure)

function Get-AVDTuneRecordingLimits { $script:DefaultLimits.Clone() }
function Get-AVDTuneRecordingAreas { @($script:Areas) }

function Get-AVDTuneRecordingValueText($Value) {
    if ($null -eq $Value) { return '' }
    if ($Value -is [string]) { return $Value }
    "$(Get-AVDTuneRecordingProp $Value 'DisplayName')|$(Get-AVDTuneRecordingProp $Value 'DisplayVersion')|$(Get-AVDTuneRecordingProp $Value 'Publisher')"
}

function Compare-AVDTuneRecordingSnapshot {
    <#
        Pure. Before and After: @{ <area> = @{ key = value }; Truncated = @(areas) }. Returns per area Added and Removed (Key, Value), Changed (Key, Before, After), each
        sorted and cut at -Max, and Counts (the full numbers); Truncated names every area that a snapshot or the list cut.
    #>
    param([Parameter(Mandatory)]$Before, [Parameter(Mandatory)]$After, [int]$Max = 2000)
    $out = [ordered]@{}; $cut = New-Object System.Collections.ArrayList
    foreach ($s in @($Before, $After)) { foreach ($t in @(Get-AVDTuneRecordingProp $s 'Truncated')) { if ($t -and -not $cut.Contains([string]$t)) { [void]$cut.Add([string]$t) } } }
    foreach ($area in $script:Areas) {
        $b = Get-AVDTuneRecordingProp $Before $area; $a = Get-AVDTuneRecordingProp $After $area
        if ($null -eq $b) { $b = @{} }; if ($null -eq $a) { $a = @{} }
        $added = New-Object System.Collections.ArrayList; $removed = New-Object System.Collections.ArrayList; $changed = New-Object System.Collections.ArrayList
        foreach ($k in @($a.Keys | Sort-Object)) {
            if (-not $b.ContainsKey($k)) { [void]$added.Add([pscustomobject]@{ Key = [string]$k; Value = $a[$k] }) }
            elseif ((Get-AVDTuneRecordingValueText $a[$k]) -cne (Get-AVDTuneRecordingValueText $b[$k])) { [void]$changed.Add([pscustomobject]@{ Key = [string]$k; Before = $b[$k]; After = $a[$k] }) }
        }
        foreach ($k in @($b.Keys | Sort-Object)) { if (-not $a.ContainsKey($k)) { [void]$removed.Add([pscustomobject]@{ Key = [string]$k; Value = $b[$k] }) } }
        $counts = [ordered]@{ Added = $added.Count; Removed = $removed.Count; Changed = $changed.Count }
        if (($added.Count -gt $Max -or $removed.Count -gt $Max -or $changed.Count -gt $Max) -and -not $cut.Contains($area)) { [void]$cut.Add($area) }
        $out[$area] = [pscustomobject]@{ Added = @($added | Select-Object -First $Max); Removed = @($removed | Select-Object -First $Max); Changed = @($changed | Select-Object -First $Max); Counts = [pscustomobject]$counts }
    }
    $out['Truncated'] = @($cut)
    [pscustomobject]$out
}

function Protect-AVDTuneRecordingSnapshot {
    <#
        Pure. Before anything of a snapshot is compared and stored (review #87): the command lines of services, the targets and arguments of shortcuts and the
        uninstall strings of programs lose what looks like a key, a password or a token (Remove-AVDTuneRecordingSecrets). Returns the cleaned snapshot.
    #>
    param([Parameter(Mandatory)]$Snapshot)
    $out = @{ Truncated = @(Get-AVDTuneRecordingProp $Snapshot 'Truncated') }
    foreach ($area in $script:Areas) {
        $src = Get-AVDTuneRecordingProp $Snapshot $area; $dst = @{}
        if ($src) {
            foreach ($k in @($src.Keys)) {
                $v = $src[$k]
                if ($area -eq 'Programs') {
                    $o = [ordered]@{}; foreach ($n in 'DisplayName', 'DisplayVersion', 'Publisher', 'UninstallString', 'QuietUninstallString') { $o[$n] = [string](Get-AVDTuneRecordingProp $v $n) }
                    foreach ($n in 'UninstallString', 'QuietUninstallString') { $o[$n] = (Remove-AVDTuneRecordingSecrets $o[$n]).Text }
                    $v = [pscustomobject]$o
                }
                elseif ($area -eq 'Environment' -and $v -is [string]) {
                    # a variable whose name says secret loses its value whatever it looks like (#93); the others are cleaned like every command line
                    $named = $false; try { $named = [regex]::IsMatch([string]$k, $script:SecretName, [Text.RegularExpressions.RegexOptions]::None, $script:RegexTimeout) } catch { $named = $true }
                    $v = if ($named) { '(removed)' } else { (Remove-AVDTuneRecordingSecrets $v).Text }
                }
                elseif ($area -in $script:CleanedAreas -and $v -is [string]) { $v = (Remove-AVDTuneRecordingSecrets $v).Text }
                $dst[$k] = $v
            }
        }
        $out[$area] = $dst
    }
    $out
}

function Get-AVDTuneRecordingShortcutMode {
    <#
        Pure. A shortcut is opened (WScript.Shell, target and arguments) only when its folder and the file belong to Administrators, SYSTEM or TrustedInstaller;
        a shortcut someone else prepared is only listed by its name (review #87). Returns Parse or Name.
    #>
    param([string[]]$Owners)
    $trusted = @('S-1-5-32-544', 'S-1-5-18', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
    foreach ($o in @($Owners)) { if (-not $o -or $o -notin $trusted) { return 'Name' } }
    if (@($Owners).Count -eq 0) { return 'Name' }
    'Parse'
}

function Get-AVDTuneRecordingLongValue {
    # Pure: a value for the comparison, one line, at most -Max characters; a longer one (PATH) is cut and gets its length and the start of its SHA256, so a change behind the cut still shows
    param([AllowEmptyString()][string]$Text, [int]$Max = 600)
    $clean = Remove-AVDTuneControlCharacters $Text 100000
    if ($clean.Length -le $Max) { return $clean }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $h = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($clean))) -replace '-', '').Substring(0, 12).ToLowerInvariant() } finally { $sha.Dispose() }
    "$($clean.Substring(0, $Max))... ($($clean.Length) characters, sha256 $h)"
}

function ConvertFrom-AVDTuneRecordingHosts {
    <#
        Pure: the entries of a hosts file as name -> address(es). Comments and lines that are no "address name [name ...]" are left out; the address must parse as an
        IP address, a name is letters, digits and . _ -. At most -Limit names and 512 KB of text (Truncated). The text is data: nothing of it is resolved or contacted.
    #>
    param([AllowEmptyString()][string]$Text, [int]$Limit = 2000)
    $map = @{}; $cut = $false
    if (-not $Text) { return @{ Map = $map; Truncated = $false } }
    if ($Text.Length -gt 524288) { $Text = $Text.Substring(0, 524288); $cut = $true }
    foreach ($line in $Text.Split([char[]]"`r`n", [StringSplitOptions]::RemoveEmptyEntries)) {
        $l = $line; $i = $l.IndexOf('#'); if ($i -ge 0) { $l = $l.Substring(0, $i) }
        $parts = @($l.Split([char[]]" `t", [StringSplitOptions]::RemoveEmptyEntries))
        if ($parts.Count -lt 2 -or $parts[0].Length -gt 45) { continue }
        $ip = $null; if (-not [Net.IPAddress]::TryParse($parts[0], [ref]$ip)) { continue }
        foreach ($n in @($parts | Select-Object -Skip 1)) {
            if ($n.Length -gt 255 -or $n -cnotmatch '\A[A-Za-z0-9._-]+\z') { continue }
            $key = $n.ToLowerInvariant()
            if ($map.ContainsKey($key)) { if (@($map[$key] -split ', ') -notcontains $ip.ToString()) { $map[$key] = Remove-AVDTuneControlCharacters "$($map[$key]), $ip" 200 }; continue }
            if ($map.Count -ge $Limit) { $cut = $true; break }
            $map[$key] = $ip.ToString()
        }
        if ($cut -and $map.Count -ge $Limit) { break }
    }
    @{ Map = $map; Truncated = $cut }
}

function ConvertFrom-AVDTuneRecordingTaskXml {
    <#
        Pure: what a scheduled task starts, from its definition (the XML of the task folder): "as <account>: <command> <arguments>" per program action, joined with ' ; '.
        Parsed without DTD and without a resolver, at most 512 KB; a definition that does not parse is '(not readable)'. Nothing of it is run; the text is cleaned of
        secrets by Protect-AVDTuneRecordingSnapshot like every command line.
    #>
    param([AllowEmptyString()][string]$Xml)
    if (-not $Xml -or $Xml.Length -gt 524288) { return '(not readable)' }
    $settings = New-Object Xml.XmlReaderSettings
    $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit; $settings.XmlResolver = $null; $settings.MaxCharactersInDocument = 524288
    $acts = New-Object System.Collections.ArrayList; $user = ''; $path = New-Object System.Collections.Stack; $cur = $null
    $sr = New-Object IO.StringReader ($Xml.TrimStart([char]0xFEFF))
    try {
        $rd = [Xml.XmlReader]::Create($sr, $settings)
        try {
            while ($rd.Read()) {
                if ($rd.NodeType -eq [Xml.XmlNodeType]::Element) {
                    $name = $rd.LocalName
                    if (-not $rd.IsEmptyElement) { $path.Push($name) }
                    if ($name -ceq 'Exec') { $cur = @{ Command = ''; Arguments = '' }; if ($rd.IsEmptyElement) { $cur = $null } }
                    elseif ($name -cin 'ComHandler', 'SendEmail', 'ShowMessage' -and $path.Count -le 3) { [void]$acts.Add("($name)") }
                }
                elseif ($rd.NodeType -eq [Xml.XmlNodeType]::Text -and $path.Count) {
                    $top = [string]$path.Peek()
                    if ($cur -and $top -cin 'Command', 'Arguments') { $cur[$top] = [string]$rd.Value }
                    elseif (-not $user -and $top -cin 'UserId', 'GroupId') { $user = [string]$rd.Value }
                }
                elseif ($rd.NodeType -eq [Xml.XmlNodeType]::EndElement) {
                    if ($path.Count) { [void]$path.Pop() }
                    if ($rd.LocalName -ceq 'Exec' -and $cur) { [void]$acts.Add("$($cur.Command) $($cur.Arguments)".Trim()); $cur = $null }
                }
                if ($acts.Count -ge 20) { break }
            }
        }
        finally { $rd.Dispose() }
    }
    catch { return '(not readable)' }
    finally { $sr.Dispose() }
    $text = if ($acts.Count) { $acts -join ' ; ' } else { '(no program action)' }
    Remove-AVDTuneControlCharacters "$(if ($user) { "as $user`: " })$text" 600
}

function ConvertTo-AVDTuneRecordingNotes {
    <#
        Pure (#93, the notes window): the notes of a recording as data. Each note: Text (one line, control characters out, at most -MaxLength characters, cleaned by
        Remove-AVDTuneRecordingSecrets), At (a time stamp, else '') and Step (the number of the step image that was the last one when it was written, 0..999).
        Empty notes are left out, at most -Max notes are taken. Returns Notes, Cleaned (notes that lost something) and Dropped (over the limit, not text or empty).
    #>
    param($Notes, [int]$Max = $script:DefaultLimits.Notes, [int]$MaxLength = $script:DefaultLimits.NoteLength)
    $out = New-Object System.Collections.ArrayList; $cleaned = 0; $dropped = 0
    foreach ($n in @($Notes)) {
        if ($null -eq $n) { continue }
        $text = Get-AVDTuneRecordingProp $n 'Text'
        if ($text -isnot [string]) { $dropped++; continue }
        if ($out.Count -ge $Max) { $dropped++; continue }
        $c = Remove-AVDTuneRecordingSecrets (Remove-AVDTuneControlCharacters $text $MaxLength)
        if (-not $c.Text.Trim()) { $dropped++; continue }
        if ($c.Cleaned) { $cleaned++ }
        $at = Get-AVDTuneRecordingProp $n 'At'
        if ($at -is [datetime]) { $at = $at.ToString('o') }   # ConvertFrom-Json turns a time stamp into a date
        if ($at -isnot [string] -or $at -cnotmatch '\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]{5,20}(Z|[+-][0-9]{2}:[0-9]{2})?\z') { $at = '' }
        $step = Get-AVDTuneRecordingProp $n 'Step'; if (-not ($step -is [int] -or $step -is [long]) -or $step -lt 0 -or $step -gt 999) { $step = 0 }
        [void]$out.Add([pscustomobject][ordered]@{ At = $at; Step = [int]$step; Text = $c.Text.Trim() })
    }
    [pscustomobject]@{ Notes = $out.ToArray(); Cleaned = $cleaned; Dropped = $dropped }
}

function Add-AVDTuneRecordingNote {
    <#
        A note of the administrator while the recording runs (#93): into -Progress (the synchronized table the page shares with the job), under its lock. The text is
        checked like at the end (ConvertTo-AVDTuneRecordingNotes: one line, length, secrets out). Refused when the job has taken the notes already (Reason closed),
        when the limit is reached (full) or nothing is left of the text (empty). Returns Accepted, Reason, Text (as stored) and Cleaned.
    #>
    param([Parameter(Mandatory)][hashtable]$Progress, [AllowEmptyString()][string]$Text, [datetime]$At = (Get-Date))
    $one = ConvertTo-AVDTuneRecordingNotes -Notes @(@{ Text = $Text; At = $At.ToString('o'); Step = 0 })
    if (@($one.Notes).Count -ne 1) { return [pscustomobject]@{ Accepted = $false; Reason = 'empty'; Text = ''; Cleaned = $false } }
    $note = $one.Notes[0]
    [Threading.Monitor]::Enter($Progress.SyncRoot)
    try {
        if ($Progress['NotesClosed']) { return [pscustomobject]@{ Accepted = $false; Reason = 'closed'; Text = $note.Text; Cleaned = [bool]$one.Cleaned } }
        if ($Progress['Notes'] -isnot [System.Collections.ArrayList]) { $Progress['Notes'] = New-Object System.Collections.ArrayList }
        if ($Progress['Notes'].Count -ge $script:DefaultLimits.Notes) { return [pscustomobject]@{ Accepted = $false; Reason = 'full'; Text = $note.Text; Cleaned = [bool]$one.Cleaned } }
        $s = $Progress['Steps']; if ($s -is [int] -and $s -ge 0 -and $s -le 999) { $note.Step = $s }
        [void]$Progress['Notes'].Add($note)
    }
    finally { [Threading.Monitor]::Exit($Progress.SyncRoot) }
    [pscustomobject]@{ Accepted = $true; Reason = ''; Text = $note.Text; Cleaned = [bool]$one.Cleaned }
}

function Close-AVDTuneRecordingNotes {
    # The job takes the notes once, under the lock, and closes the list: a note that comes later is refused by Add-AVDTuneRecordingNote, not lost silently
    param($Progress)
    if ($Progress -isnot [hashtable]) { return @() }
    [Threading.Monitor]::Enter($Progress.SyncRoot)
    try { $Progress['NotesClosed'] = $true; $got = @(); if ($Progress['Notes'] -is [System.Collections.ArrayList]) { $got = @($Progress['Notes'].ToArray()) } }
    finally { [Threading.Monitor]::Exit($Progress.SyncRoot) }
    @((ConvertTo-AVDTuneRecordingNotes -Notes $got).Notes)
}

function ConvertTo-AVDTuneRecordingSteps {
    <#
        Pure (#93, step images): the steps of a record as data. Each step: Number (1..999), File (only <app id>-<nnn>-step-<kkk>.png of this app and recording),
        Title (the window title: one line, 200 characters, cleaned of secrets), At and Process (the name of the program the window belongs to). Anything else is left out;
        at most -Max steps.
    #>
    param($Steps, [Parameter(Mandatory)][string]$AppId, [Parameter(Mandatory)][int]$Number, [int]$Max = $script:DefaultLimits.StepImages)
    $out = New-Object System.Collections.ArrayList; $prefix = "$AppId-$($Number.ToString('000'))-step-"
    foreach ($s in @($Steps)) {
        if ($null -eq $s -or $out.Count -ge $Max) { continue }
        $n = Get-AVDTuneRecordingProp $s 'Number'; $file = Get-AVDTuneRecordingProp $s 'File'
        if (-not ($n -is [int] -or $n -is [long]) -or $n -lt 1 -or $n -gt 999) { continue }
        if ($file -isnot [string] -or $file -cnotmatch $script:StepFilePattern -or -not $file.StartsWith($prefix, [StringComparison]::Ordinal)) { continue }
        $at = Get-AVDTuneRecordingProp $s 'At'; if ($at -is [datetime]) { $at = $at.ToString('o') }
        [void]$out.Add([pscustomobject][ordered]@{ Number = [int]$n; File = $file
                Title = (Remove-AVDTuneRecordingSecrets (Remove-AVDTuneControlCharacters ([string](Get-AVDTuneRecordingProp $s 'Title')) 200)).Text
                At = Remove-AVDTuneControlCharacters ([string]$at) 40; Process = Remove-AVDTuneControlCharacters ([string](Get-AVDTuneRecordingProp $s 'Process')) 80 })
    }
    $out.ToArray()
}

function Select-AVDTuneRecordingProcessTree {
    <#
        Pure (#93): the processes whose windows may become step images: the descendants of -RootId (the AVDTune process that starts the installer) in -Processes
        (Id, Parent, Start as ticks). A child counts only when it started after its parent (a reused process id of an ended parent is no parent) and both start
        times are known. The root itself is never in the result: AVDTune's own windows (the notes window too) are never captured. At most 500 processes.
    #>
    param([Parameter(Mandatory)][int]$RootId, $Processes)
    $byId = @{}; foreach ($p in @($Processes)) { if ($p) { $byId[[int](Get-AVDTuneRecordingProp $p 'Id')] = $p } }
    if (-not $byId.ContainsKey($RootId)) { return @() }
    $in = @{ $RootId = $true }; $out = New-Object System.Collections.ArrayList; $grew = $true
    while ($grew -and $out.Count -lt 500) {
        $grew = $false
        foreach ($id in @($byId.Keys)) {
            if ($in.ContainsKey($id) -or $out.Count -ge 500) { continue }
            $p = $byId[$id]; $par = [int](Get-AVDTuneRecordingProp $p 'Parent')
            if (-not $in.ContainsKey($par) -or $par -eq $id) { continue }
            $s = Get-AVDTuneRecordingProp $p 'Start'; $ps = Get-AVDTuneRecordingProp $byId[$par] 'Start'
            if (-not ($s -is [long] -or $s -is [int]) -or -not ($ps -is [long] -or $ps -is [int]) -or $s -lt $ps) { continue }
            $in[$id] = $true; [void]$out.Add($id); $grew = $true
        }
    }
    @($out | Sort-Object)
}

function Get-AVDTuneRecordingProposal {
    <#
        Pure. From the changes: a detection rule (a new or changed uninstall key with its version, the one whose name contains the app name first; otherwise a new .exe
        below Program Files), the silent install command (an .msi: /qn /norestart; an .exe only with the arguments the administrator gave) and the uninstall command
        (msiexec /x {product code}, else the quiet or plain uninstall string of the vendor, as text). Commands are documentation only: nothing is run from them.
    #>
    param([Parameter(Mandatory)]$App, [Parameter(Mandatory)]$Changes)
    $flat = { param($k, $v) [pscustomobject]@{ Key = [string]$k; DisplayName = [string](Get-AVDTuneRecordingProp $v 'DisplayName'); DisplayVersion = [string](Get-AVDTuneRecordingProp $v 'DisplayVersion'); QuietUninstallString = [string](Get-AVDTuneRecordingProp $v 'QuietUninstallString'); UninstallString = [string](Get-AVDTuneRecordingProp $v 'UninstallString') } }
    $cands = @(@(foreach ($x in @($Changes.Programs.Added)) { & $flat $x.Key $x.Value }) + @(foreach ($x in @($Changes.Programs.Changed)) { & $flat $x.Key $x.After }))
    $pick = $null
    if ($cands.Count) { $pick = @(@($cands | Where-Object { $_.DisplayName.IndexOf($App.Name, [StringComparison]::OrdinalIgnoreCase) -ge 0 }) + $cands)[0] }
    $detection = $null; $uninstall = ''
    if ($pick) {
        $detection = [pscustomobject][ordered]@{ Kind = 'Uninstall'; Key = $pick.Key; DisplayName = $pick.DisplayName; Version = $pick.DisplayVersion }
        $leaf = Split-Path $pick.Key -Leaf
        if ($leaf -match '\A\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}\z') { $uninstall = "msiexec.exe /x $($leaf.ToUpperInvariant()) /qn /norestart" }
        elseif ($pick.QuietUninstallString) { $uninstall = $pick.QuietUninstallString }
        elseif ($pick.UninstallString) { $uninstall = "$($pick.UninstallString) (not silent: the vendor names no quiet uninstall)" }
    }
    else {
        $exe = @($Changes.Files.Added | Where-Object { $_.Key -match '(?i)\\Program Files( \(x86\))?\\.+\.exe\z' } | Select-Object -First 1)
        if ($exe.Count) { $detection = [pscustomobject][ordered]@{ Kind = 'File'; Key = [string]$exe[0].Key; DisplayName = ''; Version = '' } }
    }
    $silent = if ([IO.Path]::GetExtension($App.Installer) -ieq '.msi') { "msiexec.exe /i $($App.Installer) /qn /norestart" } elseif ($App.Arguments) { "$($App.Installer) $($App.Arguments)" } else { '' }
    [pscustomobject]@{ Detection = $detection; Silent = $silent; Uninstall = (Remove-AVDTuneControlCharacters $uninstall 600) }
}

function ConvertTo-AVDTuneRecordingHtml {
    # Pure: the documentation of one recording. Every value HTML-encoded, no script, a policy that loads nothing (default-src 'none').
    param([Parameter(Mandatory)]$Record)
    $e = { param($v) [Net.WebUtility]::HtmlEncode([string]$v) }
    $a = $Record.App
    $sb = New-Object Text.StringBuilder
    [void]$sb.Append("<!doctype html><html><head><meta charset=""utf-8""><meta http-equiv=""Content-Security-Policy"" content=""default-src 'none'; style-src 'unsafe-inline'; img-src 'self' data:""><title>$(& $e $a.Name) $(& $e $a.Version)</title>")
    [void]$sb.Append('<style>body{font-family:Segoe UI,sans-serif;margin:24px;max-width:1100px}td,th{text-align:left;padding:2px 8px;vertical-align:top}table{border-collapse:collapse}tr:nth-child(even){background:#f3f3f3}code{word-break:break-all}img{max-width:100%;border:1px solid #999;margin:4px 0 12px}</style></head><body>')
    [void]$sb.Append("<h1>$(& $e $a.Name) $(& $e $a.Version)</h1><table>")
    $rows = @(@('Vendor', $a.Vendor), @('Kind', $Record.Kind), @('Result', $Record.Result), @('Exit code', $Record.ExitCode), @('Installer', "$($a.Installer) (SHA256 $($a.Sha256))"), @('Signature', $Record.Signature),
        @('Arguments', $a.Arguments), @('Started', $Record.Started), @('Ended', $Record.Ended), @('Administrator', $Record.User), @('Image version', $Record.ImageVersion), @('Contact or ticket', $a.Contact),
        @('Dependencies', $a.Dependencies), @('Licence notes', $a.LicenseNotes),
        @('Detection', $(if ($Record.Detection) { "$($Record.Detection.Kind): $($Record.Detection.Key) $($Record.Detection.Version)" } else { 'none found' })), @('Silent install', $Record.Silent), @('Uninstall', $Record.Uninstall),
        @('Cut areas', (@($Record.Changes.Truncated) -join ', ')))
    foreach ($r in $rows) { [void]$sb.Append("<tr><th>$(& $e $r[0])</th><td>$(& $e $r[1])</td></tr>") }
    [void]$sb.Append('</table>')
    # the notes of the administrator (#93): text only, encoded like every value
    $notes = @(Get-AVDTuneRecordingProp $Record 'Notes' | Where-Object { $_ })
    if ($notes.Count) {
        [void]$sb.Append("<h2>Notes of the administrator ($($notes.Count))</h2><table>")
        foreach ($n in $notes) { [void]$sb.Append("<tr><td>$(& $e $n.At)</td><td>$(if ([int]$n.Step -gt 0) { "at step $([int]$n.Step)" })</td><td>$(& $e $n.Text)</td></tr>") }
        [void]$sb.Append('</table>')
    }
    # the step images (#93): local files of the record folder, only names of the fixed pattern become an <img> (a relative link below steps\, nothing else is loaded)
    $steps = @(Get-AVDTuneRecordingProp $Record 'Steps' | Where-Object { $_ })
    if ($steps.Count) {
        [void]$sb.Append("<h2>Steps ($($steps.Count))</h2>")
        foreach ($st in $steps) {
            [void]$sb.Append("<h3>Step $([int]$st.Number): $(& $e $st.Title)</h3><p>$(& $e $st.At) $(& $e $st.Process)</p>")
            if ([string]$st.File -cmatch $script:StepFilePattern) { [void]$sb.Append("<img src=""steps/$(& $e $st.File)"" alt=""Step $([int]$st.Number)"">") }
            foreach ($n in @($notes | Where-Object { [int]$_.Step -eq [int]$st.Number })) { [void]$sb.Append("<p><b>Note:</b> $(& $e $n.Text)</p>") }
        }
    }
    $stepNote = [string](Get-AVDTuneRecordingProp $Record 'StepNote'); if ($stepNote) { [void]$sb.Append("<p>$(& $e $stepNote)</p>") }
    foreach ($area in $script:Areas) {
        $c = $Record.Changes.$area
        [void]$sb.Append("<h2>$(& $e $area): $($c.Counts.Added) added, $($c.Counts.Changed) changed, $($c.Counts.Removed) removed</h2><table>")
        foreach ($x in @($c.Added)) { [void]$sb.Append("<tr><td>+</td><td><code>$(& $e $x.Key)</code></td><td>$(& $e (Get-AVDTuneRecordingValueText $x.Value))</td></tr>") }
        foreach ($x in @($c.Changed)) { [void]$sb.Append("<tr><td>~</td><td><code>$(& $e $x.Key)</code></td><td>$(& $e (Get-AVDTuneRecordingValueText $x.Before)) -&gt; $(& $e (Get-AVDTuneRecordingValueText $x.After))</td></tr>") }
        foreach ($x in @($c.Removed)) { [void]$sb.Append("<tr><td>-</td><td><code>$(& $e $x.Key)</code></td><td>$(& $e (Get-AVDTuneRecordingValueText $x.Value))</td></tr>") }
        [void]$sb.Append('</table>')
    }
    [void]$sb.Append('</body></html>')
    $sb.ToString()
}

#endregion

#region storage

function Get-AVDTuneRecordingRoot([string]$Root) { Join-Path $Root 'software\custom' }

function New-AVDTuneRecordingFolder {
    # <root>\software\custom\<id>\<nnn>, level by level with New-AVDTuneOwnFolder (an existing level must be AVDTune's own, no link): AVDTune's own state, no change of the master
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string[]]$Parts)
    $cur = $Root
    foreach ($p in @('software', 'custom') + $Parts) { $cur = Join-Path $cur $p; New-AVDTuneOwnFolder -Path $cur }
    $cur
}

function Test-AVDTuneRecordingPng {
    # Pure: do these bytes start like a PNG file (signature and the IHDR chunk)? Only such files become step images.
    param([byte[]]$Bytes)
    if (-not $Bytes -or $Bytes.Length -lt 33) { return $false }
    $sig = 137, 80, 78, 71, 13, 10, 26, 10
    for ($i = 0; $i -lt 8; $i++) { if ($Bytes[$i] -ne $sig[$i]) { return $false } }
    ([Text.Encoding]::ASCII.GetString($Bytes, 12, 4) -ceq 'IHDR')
}

function Import-AVDTuneRecordingSteps {
    <#
        The captured windows of a recording (#93) become its step images: <record folder>\steps\<app id>-<nnn>-step-<kkk>.png, the folder made with New-AVDTuneOwnFolder
        (admin-only, like the record folder), each file with CreateNew and an admin-only ACL. -Captured: Path, Title, At, Process per image, in order. An image is taken
        only when its source is a file (no link), not larger than the limit (StepImageBytes) and a PNG by its first bytes; at most StepImages images. What is left out
        is counted in Note. Returns Steps (ConvertTo-AVDTuneRecordingSteps) and Note.
    #>
    param([Parameter(Mandatory)][string]$Folder, [Parameter(Mandatory)][string]$AppId, [Parameter(Mandatory)][int]$Number, $Captured, [hashtable]$Limits)
    $lim = Get-AVDTuneRecordingLimits; if ($Limits) { foreach ($k in $Limits.Keys) { $lim[$k] = $Limits[$k] } }
    $steps = New-Object System.Collections.ArrayList; $left = 0; $dir = $null
    foreach ($c in @($Captured)) {
        if (-not $c) { continue }
        if ($steps.Count -ge [int]$lim.StepImages) { $left++; continue }
        try {
            $f = New-Object IO.FileInfo ([string](Get-AVDTuneRecordingProp $c 'Path'))
            if (-not $f.Exists -or ($f.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $f.Length -lt 33 -or $f.Length -gt [int64]$lim.StepImageBytes) { $left++; continue }
            $fs = [IO.File]::Open($f.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
            try { $mem = New-Object IO.MemoryStream; $fs.CopyTo($mem); $bytes = $mem.ToArray() } finally { $fs.Dispose() }
            if ($bytes.Length -gt [int64]$lim.StepImageBytes -or -not (Test-AVDTuneRecordingPng $bytes)) { $left++; continue }
            if (-not $dir) { $dir = Join-Path $Folder 'steps'; New-AVDTuneOwnFolder -Path $dir }
            $k = $steps.Count + 1
            $name = "$AppId-$($Number.ToString('000'))-step-$($k.ToString('000')).png"
            $out = New-AVDTuneAdminFile -Path (Join-Path $dir $name)
            try { $out.Write($bytes, 0, $bytes.Length); $out.Flush($true) } finally { $out.Dispose() }
            [void]$steps.Add(@{ Number = $k; File = $name; Title = Get-AVDTuneRecordingProp $c 'Title'; At = Get-AVDTuneRecordingProp $c 'At'; Process = Get-AVDTuneRecordingProp $c 'Process' })
        }
        catch { $left++ }
    }
    [pscustomobject]@{ Steps = @(ConvertTo-AVDTuneRecordingSteps -Steps $steps.ToArray() -AppId $AppId -Number $Number -Max ([int]$lim.StepImages))
        Note = $(if ($left) { "$left captured window(s) were not taken as step images (limit of $($lim.StepImages) images or $($lim.StepImageBytes) bytes, or not a PNG file)." } else { '' }) }
}

function Save-AVDTuneRecordingRecord {
    # Writes record.json and documentation.html of a new recording number of the app. Returns the folder.
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)]$Record, $Captured, [hashtable]$Limits)
    if ([string]$Record.AppId -cnotmatch '\A[0-9a-f]{12}\z' -or $Record.Number -isnot [int] -or $Record.Number -lt 1 -or $Record.Number -gt 999) { throw 'The recording has no valid app id or number.' }
    $dir = New-AVDTuneRecordingFolder -Root $Root -Parts @($Record.AppId, $Record.Number.ToString('000'))
    if (Test-Path -LiteralPath (Join-Path $dir 'record.json')) { throw "$dir holds a recording already: not overwritten." }
    if (@($Captured).Count -and $Captured) {
        # the step images first (#93): the record and the documentation name only images that are in the folder
        $got = Import-AVDTuneRecordingSteps -Folder $dir -AppId $Record.AppId -Number $Record.Number -Captured $Captured -Limits $Limits
        $Record | Add-Member -NotePropertyName Steps -NotePropertyValue @($got.Steps) -Force
        if ($got.Note) { $Record | Add-Member -NotePropertyName StepNote -NotePropertyValue (("$(Get-AVDTuneRecordingProp $Record 'StepNote') $($got.Note)").Trim()) -Force }
    }
    Write-AVDTuneFile (Join-Path $dir 'documentation.html') (ConvertTo-AVDTuneRecordingHtml -Record $Record)
    Write-AVDTuneFile (Join-Path $dir 'record.json') ($Record | ConvertTo-Json -Depth 8)
    $dir
}

function ConvertFrom-AVDTuneRecordingRecord {
    # Typed reading of one record.json: Schema 1, the app validated again, numbers exact. Returns the record or throws with the reason.
    param([Parameter(Mandatory)]$Json, [Parameter(Mandatory)][string]$AppId, [Parameter(Mandatory)][int]$Number)
    if ((Get-AVDTuneProp $Json 'Schema') -ne 1) { throw 'unknown schema' }
    if ([string](Get-AVDTuneProp $Json 'AppId') -cne $AppId -or (Get-AVDTuneProp $Json 'Number') -ne $Number -or (Get-AVDTuneProp $Json 'Number') -isnot [int]) { throw 'id or number does not match its folder' }
    $app = ConvertTo-AVDTuneRecordingApp -Raw (Get-AVDTuneProp $Json 'App') -Stored
    if (-not $app.Valid) { throw ($app.Errors -join ' ') }
    if ($app.App.Id -cne $AppId) { throw 'the app id does not match' }
    $kind = Get-AVDTuneProp $Json 'Kind'; if ($kind -cnotin $script:Kinds) { throw 'unknown kind' }
    $result = Get-AVDTuneProp $Json 'Result'; if ($result -cnotin 'Changed', 'Failed') { throw 'unknown result' }
    $d = Get-AVDTuneProp $Json 'Detection'
    if ($null -ne $d) {
        $dk = Get-AVDTuneProp $d 'Kind'; $key = Get-AVDTuneProp $d 'Key'
        $ok = ($dk -ceq 'Uninstall' -and $key -is [string] -and (Test-AVDTuneCustomMatch $key '\AHKLM:\\SOFTWARE\\(WOW6432Node\\)?Microsoft\\Windows\\CurrentVersion\\Uninstall\\[^\\\x00-\x1F]{1,200}\z' 300)) -or ($dk -ceq 'File' -and (Test-AVDTuneCustomLocalPath $key))
        if (-not $ok) { throw 'the detection rule is not valid' }
    }
    [pscustomobject]@{ AppId = $AppId; Number = $Number; Kind = $kind; Result = $result; App = $app.App; Detection = $d
        Started = Remove-AVDTuneControlCharacters ([string](Get-AVDTuneProp $Json 'Started')) 40; User = Remove-AVDTuneControlCharacters ([string](Get-AVDTuneProp $Json 'User')) 80
        Silent = Remove-AVDTuneControlCharacters ([string](Get-AVDTuneProp $Json 'Silent')) 700; Uninstall = Remove-AVDTuneControlCharacters ([string](Get-AVDTuneProp $Json 'Uninstall')) 700
        Signature = Remove-AVDTuneControlCharacters ([string](Get-AVDTuneProp $Json 'Signature')) 400; Counts = Get-AVDTuneProp $Json 'Counts'
        Notes = @((ConvertTo-AVDTuneRecordingNotes -Notes (Get-AVDTuneProp $Json 'Notes')).Notes); Steps = @(ConvertTo-AVDTuneRecordingSteps -Steps (Get-AVDTuneProp $Json 'Steps') -AppId $AppId -Number $Number) }
}

function Get-AVDTuneRecordedApps {
    <# Read only: every recorded app (newest recording first in Versions) and Notes for records that are not used (their reason). Links are not followed. #>
    param([string]$Root = (Get-AVDTuneRoot))
    $apps = New-Object System.Collections.ArrayList; $notes = New-Object System.Collections.ArrayList
    $base = New-Object IO.DirectoryInfo (Get-AVDTuneRecordingRoot $Root)
    if (-not $base.Exists) { return [pscustomobject]@{ Apps = @(); Notes = @() } }
    if (($base.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return [pscustomobject]@{ Apps = @(); Notes = @("$($base.FullName) is a link: not read.") } }
    foreach ($d in @($base.GetDirectories() | Sort-Object Name)) {
        if (($d.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $d.Name -cnotmatch '\A[0-9a-f]{12}\z') { [void]$notes.Add("$($d.Name): not a recording folder (or a link), left out."); continue }
        $versions = New-Object System.Collections.ArrayList
        foreach ($n in @($d.GetDirectories() | Sort-Object Name -Descending)) {
            if (($n.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $n.Name -notmatch '\A[0-9]{3}\z') { [void]$notes.Add("$($d.Name)\$($n.Name): left out."); continue }
            $f = New-Object IO.FileInfo (Join-Path $n.FullName 'record.json')
            try {
                if (-not $f.Exists -or ($f.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $f.Length -gt 8MB) { throw 'record.json is missing, a link or larger than 8 MB' }
                $r = ConvertFrom-AVDTuneRecordingRecord -Json (Read-AVDTuneJson $f.FullName) -AppId $d.Name -Number ([int]$n.Name)
                $r | Add-Member -NotePropertyName Folder -NotePropertyValue $n.FullName
                [void]$versions.Add($r)
            }
            catch { [void]$notes.Add("$($d.Name)\$($n.Name): not used ($(Remove-AVDTuneControlCharacters $_.Exception.Message 200)).") }
        }
        if ($versions.Count) { [void]$apps.Add([pscustomobject]@{ Id = $d.Name; Name = $versions[0].App.Name; Vendor = $versions[0].App.Vendor; Latest = $versions[0]; Versions = @($versions) }) }
    }
    [pscustomobject]@{ Apps = @($apps); Notes = @($notes) }
}

function Get-AVDTuneRecordingRecipe {
    # Read only (#93): the recipe of an app = its newest successful recording (the pinned installer, the checked arguments, the timeout); $null when there is none
    param([string]$Root = (Get-AVDTuneRoot), [Parameter(Mandatory)][string]$AppId)
    $app = @((Get-AVDTuneRecordedApps -Root $Root).Apps | Where-Object { $_.Id -ceq $AppId })
    if (-not $app.Count) { return $null }
    @($app[0].Versions | Where-Object { $_.Result -eq 'Changed' } | Select-Object -First 1)[0]
}

function Get-AVDTuneRecordingStatus {
    # Read only: the recorded apps with the installed version found by the detection rule of the newest successful recording (Installed: $true/$false/$null = no rule)
    param([Parameter(Mandatory)]$R, [string]$Root = (Get-AVDTuneRoot))
    $list = Get-AVDTuneRecordedApps -Root $Root
    $rows = foreach ($a in $list.Apps) {
        $ok = @($a.Versions | Where-Object { $_.Result -eq 'Changed' -and $_.Detection } | Select-Object -First 1)
        $inst = $null; $ver = ''
        if ($ok.Count) {
            $d = $ok[0].Detection
            if ($d.Kind -eq 'Uninstall') { $p = & $R.ReadProgram ([string]$d.Key); $inst = [bool]$p; if ($p) { $ver = [string]$p.DisplayVersion } }
            else { $inst = [bool](& $R.FileExists ([string]$d.Key)) }
        }
        $a | Add-Member -NotePropertyName Installed -NotePropertyValue $inst -PassThru | Add-Member -NotePropertyName InstalledVersion -NotePropertyValue $ver -PassThru
    }
    [pscustomobject]@{ Apps = @($rows); Notes = @($list.Notes) }
}

#endregion

#region the recording

function Invoke-AVDTuneRecording {
    <#
        Records one install or update: behind the write gate and under the change marker the whole time; snapshot before, the installer as one step through Invoke-AVDTune,
        snapshot after (also when the install failed), the changes, the proposal, and the record saved as the next number of the app. -Context opens the library for an
        installer that is not cached yet. -Progress (a synchronized hashtable) gets Text = snapshot | install | compare. Returns Run, Record and Folder.
    #>
    param([Parameter(Mandatory)]$Machine, [Parameter(Mandatory)]$R, [Parameter(Mandatory)]$C, [Parameter(Mandatory)]$App, [string]$Root = (Get-AVDTuneRoot), $Context,
        [ValidateSet('Install', 'Update', 'Reinstall')][string]$Kind = 'Install', [string]$User, [string]$SnapshotId, [hashtable]$Limits, $Progress, [switch]$StepImages)
    if (-not (Test-AVDTuneWriteAllowed)) { throw 'The snapshot gate is not confirmed: nothing is installed or recorded.' }
    $chk = ConvertTo-AVDTuneRecordingApp -Raw $App
    if (-not $chk.Valid) { throw "Not recorded: $($chk.Errors -join ' ')" }
    $a = $chk.App
    $known = @((Get-AVDTuneRecordedApps -Root $Root).Apps | Where-Object { $_.Id -eq $a.Id })
    if ($Kind -eq 'Update' -and -not $known.Count) { throw 'An update needs an app that has been recorded before.' }
    if ($Kind -eq 'Install' -and $known.Count) { throw 'This app has been recorded before: record an update instead.' }
    if ($Kind -eq 'Reinstall') {
        # "Reinstall" (#93) runs the recipe and nothing else: the same pinned file with the same arguments as the newest successful recording; the app above went
        # through today's rules for the arguments like every new recording, and the fetch, the hold and the signature check below are the same as when it was recorded
        $recipe = Get-AVDTuneRecordingRecipe -Root $Root -AppId $a.Id
        if (-not $recipe) { throw 'Reinstall needs a successful recording of this app (the recipe): there is none.' }
        foreach ($f in $script:Fields) { if ([string]$a.$f -cne [string]$recipe.App.$f) { throw "Reinstall takes the recipe as it was recorded: $f is not the one of recording $($recipe.Number.ToString('000')). Record an update for something new." } }
    }
    $number = if ($known.Count) { [int]$known[0].Versions[0].Number + 1 } else { 1 }
    $lim = Get-AVDTuneRecordingLimits; if ($Limits) { foreach ($k in $Limits.Keys) { $lim[$k] = $Limits[$k] } }
    $say = { param($t) if ($Progress) { $Progress.Text = $t } }
    $capture = $null
    $owner = Start-AVDTuneChange -Root $Root
    try {
        & $say 'snapshot'
        $before = Protect-AVDTuneRecordingSnapshot (& $R.Snapshot $lim)
        $fetch = New-AVDTuneCustomFetch -C $C -Root $Root -Context $Context
        $state = @{ Done = $false; ExitCode = $null; Signature = ''; Output = '' }
        $rr = $R; $root = $Root
        $test = { param($m) @{ Compliant = $state.Done; State = $(if ($null -eq $state.ExitCode) { 'not run' } else { "installer exit code $($state.ExitCode)" }) } }.GetNewClosure()
        $apply = { param($m)
            $cached = & $fetch $a.Installer $a.Sha256
            $st = & $rr.Stage $cached $a.Installer $a.Sha256 $root
            try {
                $hold = & $rr.Hold $st.Path $a.Sha256
                try {
                    $sig = Test-AVDTuneRecordingSignature $hold.Signature
                    $state.Signature = $sig.Text
                    if (-not $sig.Ok) { throw "$($sig.Text) It is not started." }
                    $res = & $rr.Install $st.Path (Get-AVDTuneRecordingCommand -App $a -Path $st.Path) $a.TimeoutSeconds $st.TempDir
                }
                finally { & $rr.Release $hold }
                $state.ExitCode = [int]$res.ExitCode; $state.Output = (Remove-AVDTuneRecordingSecrets (Remove-AVDTuneControlCharacters ([string]$res.Output) 2000)).Text
                if ($state.ExitCode -eq -1) { throw "The installer did not end within $($a.TimeoutSeconds) seconds: it was ended with its whole process tree." }
                if ($state.ExitCode -notin 0, 3010, 1641) { throw "The installer ended with exit code $($state.ExitCode)." }
                $state.Done = $true
            }
            finally { & $rr.Unstage $st.Folder }
        }.GetNewClosure()
        $title = "$(if ($Kind -eq 'Update') { 'Update' } elseif ($Kind -eq 'Reinstall') { 'Reinstall' } else { 'Install' }) $($a.Name) $($a.Version) ($($a.Installer), SHA256 $($a.Sha256.Substring(0, 12)))"
        $step = New-AVDTuneStep -Id "software.custom-$($a.Id)" -Section Software -Title $title -Why 'Own software of the customer, installed and recorded (Software page, custom software).' -Risk High -Test $test -Apply $apply
        $started = (& $Machine.Now).ToString('o')
        & $say 'install'
        # step images (#93, only when asked for): the windows of the installer's process tree while the step runs. A capture that cannot start or fails never stops
        # the install; the record says why there are no images. The capture folder is removed in the finally below.
        $captured = @(); $stepNote = ''
        if ($StepImages) {
            if ((Get-AVDTuneRecordingProp $R 'StartCapture') -is [scriptblock]) { try { $capture = & $R.StartCapture $Root $lim $Progress } catch { $stepNote = "No step images: the capture did not start ($(Remove-AVDTuneControlCharacters $_.Exception.Message 200))." } }
            else { $stepNote = 'No step images: this adapter cannot capture windows.' }
        }
        try { $run = Invoke-AVDTune -Plan ([pscustomobject]@{ Name = "Custom software $($a.Name)"; Steps = @($step.Id) }) -Catalog @($step) -Machine $Machine -Root $Root -User $User -SnapshotId $SnapshotId }
        finally {
            if ($capture) {
                try { $shots = & $R.StopCapture $capture; $captured = @(Get-AVDTuneRecordingProp $shots 'Shots'); $sn = [string](Get-AVDTuneRecordingProp $shots 'Note'); if ($sn) { $stepNote = Remove-AVDTuneControlCharacters $sn 300 } }
                catch { $stepNote = "No step images: the capture failed ($(Remove-AVDTuneControlCharacters $_.Exception.Message 200))." }
            }
        }
        & $say 'compare'
        $after = Protect-AVDTuneRecordingSnapshot (& $R.Snapshot $lim)
        $changes = Compare-AVDTuneRecordingSnapshot -Before $before -After $after -Max ([int]$lim.ListPerArea)
        $prop = Get-AVDTuneRecordingProposal -App $a -Changes $changes
        $res0 = @($run.Results)[0]
        $counts = [ordered]@{}; foreach ($ar in $script:Areas) { $counts[$ar] = $changes.$ar.Counts }
        $record = [pscustomobject][ordered]@{
            Schema = 1; AppId = $a.Id; Number = $number; Kind = $Kind; App = $a; Result = $(if ($res0.Status -eq 'Changed') { 'Changed' } else { 'Failed' }); Message = Remove-AVDTuneControlCharacters ([string]$res0.Message) 500
            ExitCode = $state.ExitCode; Signature = $state.Signature; Output = $state.Output; Started = $started; Ended = (& $Machine.Now).ToString('o'); User = $User; ImageVersion = (Get-AVDTuneState $Root).ImageVersion; RunId = $run.Id
            Detection = $prop.Detection; Silent = $prop.Silent; Uninstall = $prop.Uninstall; Counts = [pscustomobject]$counts; Changes = $changes
            Notes = @(Close-AVDTuneRecordingNotes $Progress); Steps = @(); StepNote = $stepNote
        }
        $folder = Save-AVDTuneRecordingRecord -Root $Root -Record $record -Captured $captured -Limits $lim
        [pscustomobject]@{ Run = $run; Record = $record; Folder = $folder }
    }
    finally {
        try { if ($capture -and (Get-AVDTuneRecordingProp $capture 'Folder')) { & $R.Unstage ([string](Get-AVDTuneRecordingProp $capture 'Folder')) } }
        finally { Stop-AVDTuneChange -Root $Root -Owner $owner }
    }
}

#endregion

#region real adapter

function Get-AVDTuneRecordingFileTree {
    # Read only: files and folders below the roots up to -Depth, links listed but never entered, at most -Limit entries (Truncated). Value: d | f|<size>|<last write UTC ticks> | link
    param([string[]]$Roots, [string[]]$Exclude, [int]$Limit, [int]$Depth)
    $map = @{}; $cut = $false
    $stack = New-Object System.Collections.Stack
    foreach ($r in $Roots) { if ($r -and (Test-Path -LiteralPath $r -PathType Container)) { $stack.Push(@((New-Object IO.DirectoryInfo $r), 0)) } }
    while ($stack.Count -gt 0 -and -not $cut) {
        $top = $stack.Pop(); $dir = $top[0]; $lvl = $top[1]
        $entries = @(); try { $entries = $dir.GetFileSystemInfos() } catch { continue }
        foreach ($e in $entries) {
            if ($map.Count -ge $Limit) { $cut = $true; break }
            $full = $e.FullName
            $skip = $false; foreach ($x in $Exclude) { if ($x -and ($full -ieq $x -or $full.StartsWith($x + '\', [StringComparison]::OrdinalIgnoreCase))) { $skip = $true } }
            if ($skip) { continue }
            $key = Remove-AVDTuneControlCharacters $full 400
            if (($e.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $map[$key] = 'link'; continue }
            if ($e -is [IO.DirectoryInfo]) { $map[$key] = 'd'; if ($lvl + 1 -lt $Depth) { $stack.Push(@($e, ($lvl + 1))) } }
            else { $map[$key] = "f|$($e.Length)|$($e.LastWriteTimeUtc.Ticks)" }
        }
    }
    @{ Map = $map; Truncated = $cut }
}

function Get-AVDTuneRecordingRegistryTree {
    # Read only: key names below HKLM\<Path> (64-bit view) up to -Depth, at most -Limit; value: the number of values of the key. -Skip: subkeys (relative) not entered.
    param([string]$Path, [int]$Limit, [int]$Depth, [string[]]$Skip, [hashtable]$Map)
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
    $cut = $false
    try {
        $stack = New-Object System.Collections.Stack; $stack.Push(@($Path, 0))
        while ($stack.Count -gt 0 -and -not $cut) {
            $top = $stack.Pop(); $p = $top[0]; $lvl = $top[1]
            $k = $null; try { $k = $base.OpenSubKey($p, $false) } catch { }
            if (-not $k) { continue }
            try {
                if ($Map.Count -ge $Limit) { $cut = $true; break }
                $Map["HKLM:\$p"] = "v=$($k.ValueCount)"
                if ($lvl -lt $Depth) { foreach ($n in $k.GetSubKeyNames()) { $sub = "$p\$n"; if ($Skip -notcontains $sub) { $stack.Push(@($sub, ($lvl + 1))) } } }
            }
            finally { $k.Dispose() }
        }
    }
    finally { $base.Dispose() }
    $cut
}

function Read-AVDTuneRecordingProgram {
    # Read only: the values of one uninstall key (HKLM:\SOFTWARE\...\Uninstall\<k>, 64-bit view; the WOW6432Node path for 32 bit); $null when it is not there
    param([Parameter(Mandatory)][string]$Key)
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
    try {
        $k = $base.OpenSubKey(($Key -replace '\AHKLM:\\', ''), $false); if (-not $k) { return $null }
        try {
            $v = @{}; foreach ($n in 'DisplayName', 'DisplayVersion', 'Publisher', 'UninstallString', 'QuietUninstallString') { $v[$n] = Remove-AVDTuneControlCharacters ([string]$k.GetValue($n, '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)) 500 }
            [pscustomobject]$v
        }
        finally { $k.Dispose() }
    }
    finally { $base.Dispose() }
}

function Get-AVDTuneRecordingRegistryValues {
    <#
        Read only: the values of one key HKLM\<Path> (64-bit view) as name -> text (a string as it is, not expanded; a list joined with ';'; a number; anything else
        only as its kind and size), each cut by Get-AVDTuneRecordingLongValue, at most -Limit values (Truncated). -Names: only these values. A missing key is empty.
    #>
    param([Parameter(Mandatory)][string]$Path, [int]$Limit = 1000, [string[]]$Names, [int]$ValueMax = 600)
    $map = @{}; $cut = $false
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
    try {
        $k = $base.OpenSubKey($Path, $false)
        if ($k) {
            try {
                foreach ($n in @($k.GetValueNames() | Sort-Object)) {
                    if ($Names -and $Names -notcontains $n) { continue }
                    if ($map.Count -ge $Limit) { $cut = $true; break }
                    $v = $k.GetValue($n, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                    $text = if ($v -is [string]) { $v } elseif ($v -is [string[]]) { $v -join ';' } elseif ($v -is [int] -or $v -is [long]) { [string]$v } elseif ($v -is [byte[]]) { "(binary, $($v.Length) bytes)" } else { '(other)' }
                    $map[(Remove-AVDTuneControlCharacters $n 200)] = Get-AVDTuneRecordingLongValue $text $ValueMax
                }
            }
            finally { $k.Dispose() }
        }
    }
    finally { $base.Dispose() }
    @{ Map = $map; Truncated = $cut }
}

function Get-AVDTuneRecordingSystemArea {
    <#
        Read only (#93), one area of the snapshot of the real adapter, as Map and Truncated. Nothing is started and nothing is resolved:
          Tasks        the definitions below <System32>\Tasks (the task folder of Windows: files of SYSTEM and Administrators), key = the task path, value = what it starts
          Firewall     HKLM\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy\FirewallRules (name -> rule text of Windows)
          Odbc         the system data sources, 64 and 32 bit: driver, server and database; never the user name or password values of a data source
          Environment  HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment (not expanded)
          Hosts        <System32>\drivers\etc\hosts (no link, at most 512 KB), name -> address
          Fonts        HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts (name -> file)
    #>
    param([Parameter(Mandatory)][ValidateSet('Tasks', 'Firewall', 'Odbc', 'Environment', 'Hosts', 'Fonts')][string]$Area, [int]$Limit = 1000)
    $sys = Get-AVDTuneSystemFolder System
    switch ($Area) {
        'Tasks' {
            $root = Join-Path $sys 'Tasks'; $map = @{}; $cut = $false
            $t = Get-AVDTuneRecordingFileTree -Roots @($root) -Exclude @() -Limit ($Limit * 2) -Depth 8
            foreach ($p in @($t.Map.Keys | Sort-Object)) {
                if ($t.Map[$p] -notlike 'f|*') { continue }
                if ($map.Count -ge $Limit) { $cut = $true; break }
                $text = '(not readable)'
                try { $f = New-Object IO.FileInfo $p; if ($f.Length -le 524288 -and ($f.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) { $text = ConvertFrom-AVDTuneRecordingTaskXml ([IO.File]::ReadAllText($p)) } } catch { }
                $map[(Remove-AVDTuneControlCharacters $p.Substring($root.Length) 300)] = $text
            }
            return @{ Map = $map; Truncated = ($cut -or $t.Truncated) }
        }
        'Firewall' { return Get-AVDTuneRecordingRegistryValues -Path 'SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy\FirewallRules' -Limit $Limit -ValueMax 400 }
        'Environment' { return Get-AVDTuneRecordingRegistryValues -Path 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment' -Limit $Limit }
        'Fonts' { return Get-AVDTuneRecordingRegistryValues -Path 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts' -Limit $Limit -ValueMax 260 }
        'Odbc' {
            $map = @{}; $cut = $false
            foreach ($b in @(@('64-bit', 'SOFTWARE\ODBC\ODBC.INI'), @('32-bit', 'SOFTWARE\WOW6432Node\ODBC\ODBC.INI'))) {
                $src = Get-AVDTuneRecordingRegistryValues -Path "$($b[1])\ODBC Data Sources" -Limit $Limit -ValueMax 200
                if ($src.Truncated) { $cut = $true }
                foreach ($dsn in @($src.Map.Keys | Sort-Object)) {
                    if ($map.Count -ge $Limit) { $cut = $true; break }
                    $text = "Driver=$($src.Map[$dsn])"
                    if ($dsn -notmatch '[\\/]') { $d = (Get-AVDTuneRecordingRegistryValues -Path "$($b[1])\$dsn" -Limit 10 -Names @('Server', 'ServerName', 'Database', 'Port', 'Description') -ValueMax 120).Map; foreach ($n in @($d.Keys | Sort-Object)) { $text += ";$n=$($d[$n])" } }
                    $map["$($b[0])\$dsn"] = Remove-AVDTuneControlCharacters $text 600
                }
            }
            return @{ Map = $map; Truncated = $cut }
        }
        'Hosts' {
            $f = New-Object IO.FileInfo (Join-Path $sys 'drivers\etc\hosts')
            if (-not $f.Exists) { return @{ Map = @{}; Truncated = $false } }
            if (($f.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $f.Length -gt 524288) { return @{ Map = @{}; Truncated = $true } }
            return ConvertFrom-AVDTuneRecordingHosts -Text ([IO.File]::ReadAllText($f.FullName)) -Limit $Limit
        }
    }
}

$script:CaptureLoop = @'
param($Module, $Sync, $Folder, $RootId, $MaxImages, $MaxBytes, $IntervalMs)
$ErrorActionPreference = 'Stop'
try {
    Import-Module $Module
    Import-Module (Join-Path (Split-Path $Module -Parent) 'AVDTune.Recording.psm1')
    Initialize-AVDTuneRecordingCapture
    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
    $last = @{}; $n = 0
    $isPassword = New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::IsPasswordProperty), $true
    while (-not $Sync.Stop -and $n -lt $MaxImages) {
        try {
            $procs = @(foreach ($p in [AVDTune.Native.StepShot]::Processes()) { @{ Id = $p[0]; Parent = $p[1]; Start = $(try { ([Diagnostics.Process]::GetProcessById($p[0])).StartTime.Ticks } catch { $null }) } })
            $tree = @(Select-AVDTuneRecordingProcessTree -RootId $RootId -Processes $procs)
            if ($tree.Count) {
                foreach ($w in [AVDTune.Native.StepShot]::Windows([int[]]$tree)) {
                    if ($Sync.Stop -or $n -ge $MaxImages) { break }
                    $h = [IntPtr]$w[0]
                    # a window with a password field is never captured: the Win32 style of an edit control first, then UI Automation; a window that cannot be asked is left out
                    if ([AVDTune.Native.StepShot]::HasPasswordEdit($h)) { $Sync.Skipped = [int]$Sync.Skipped + 1; continue }
                    try { $el = [System.Windows.Automation.AutomationElement]::FromHandle($h); if ($el.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $isPassword)) { $Sync.Skipped = [int]$Sync.Skipped + 1; continue } } catch { continue }
                    $bytes = [AVDTune.Native.StepShot]::Capture($h, 2400, 1800)
                    if (-not $bytes -or $bytes.Length -gt $MaxBytes) { continue }
                    $sha = [Security.Cryptography.SHA256]::Create(); try { $hash = [BitConverter]::ToString($sha.ComputeHash($bytes)) } finally { $sha.Dispose() }
                    $key = [string]$w[0]; if ($last[$key] -ceq $hash) { continue }
                    $last[$key] = $hash; $n++
                    $path = Join-Path $Folder ('shot-' + $n.ToString('000') + '.png')
                    $out = New-AVDTuneAdminFile -Path $path
                    try { $out.Write($bytes, 0, $bytes.Length); $out.Flush($true) } finally { $out.Dispose() }
                    $name = ''; try { $name = ([Diagnostics.Process]::GetProcessById([int]$w[1])).ProcessName } catch { }
                    [void]$Sync.Shots.Add(@{ Path = $path; Title = [AVDTune.Native.StepShot]::Title($h); At = (Get-Date).ToString('o'); Process = $name })
                    if ($Sync.Progress) { $Sync.Progress['Steps'] = $n }
                }
            }
        }
        catch { $Sync.Error = $_.Exception.Message }
        [Threading.Thread]::Sleep($IntervalMs)
    }
}
catch { $Sync.Error = $_.Exception.Message }
'@

function Initialize-AVDTuneRecordingCapture {
    <#
        Loads the native part of the step images (#93) once per process: the process list (parent of every process), the visible top-level windows of given processes,
        the password style of edit controls and PrintWindow into a PNG (the window itself, also when it is covered; never the screen, so nothing else gets into the image).
        NOT exercised by the checks (no window on the developer's desktop): to be tried on a throw-away VM.
    #>
    if ('AVDTune.Native.StepShot' -as [type]) { return }
    Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @"
using System; using System.Collections.Generic; using System.Runtime.InteropServices; using System.Text;
namespace AVDTune.Native {
    public static class StepShot {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct PROCESSENTRY32 { public uint dwSize; public uint cntUsage; public uint th32ProcessID; public IntPtr th32DefaultHeapID; public uint th32ModuleID; public uint cntThreads; public uint th32ParentProcessID; public int pcPriClassBase; public uint dwFlags; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szExeFile; }
        [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }
        delegate bool EnumProc(IntPtr hwnd, IntPtr lParam);
        [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint pid);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool Process32FirstW(IntPtr snap, ref PROCESSENTRY32 e);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool Process32NextW(IntPtr snap, ref PROCESSENTRY32 e);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
        [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
        [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr lParam);
        [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hwnd);
        [DllImport("user32.dll")] static extern bool IsIconic(IntPtr hwnd);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
        [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hwnd, out RECT r);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowTextW(IntPtr hwnd, StringBuilder sb, int max);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassNameW(IntPtr hwnd, StringBuilder sb, int max);
        [DllImport("user32.dll", EntryPoint = "GetWindowLongW")] static extern int GetWindowLong(IntPtr hwnd, int index);
        [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr hwnd, IntPtr hdc, uint flags);
        public static List<int[]> Processes() {
            var list = new List<int[]>(); IntPtr snap = CreateToolhelp32Snapshot(2, 0);
            if (snap == IntPtr.Zero || snap == new IntPtr(-1)) return list;
            try { var e = new PROCESSENTRY32(); e.dwSize = (uint)Marshal.SizeOf(typeof(PROCESSENTRY32)); if (Process32FirstW(snap, ref e)) { do { list.Add(new int[] { (int)e.th32ProcessID, (int)e.th32ParentProcessID }); } while (Process32NextW(snap, ref e) && list.Count < 20000); } }
            finally { CloseHandle(snap); }
            return list;
        }
        public static List<long[]> Windows(int[] pids) {
            var set = new HashSet<int>(pids); var list = new List<long[]>();
            EnumWindows(delegate(IntPtr h, IntPtr l) {
                uint pid; GetWindowThreadProcessId(h, out pid); RECT r;
                if (set.Contains((int)pid) && IsWindowVisible(h) && !IsIconic(h) && GetWindowRect(h, out r) && r.Right - r.Left >= 160 && r.Bottom - r.Top >= 80 && list.Count < 20) list.Add(new long[] { h.ToInt64(), pid });
                return true; }, IntPtr.Zero);
            return list;
        }
        public static bool HasPasswordEdit(IntPtr hwnd) {
            bool found = false;
            EnumChildWindows(hwnd, delegate(IntPtr h, IntPtr l) {
                var sb = new StringBuilder(64); GetClassNameW(h, sb, 64); string c = sb.ToString();
                if ((c.IndexOf("Edit", StringComparison.OrdinalIgnoreCase) >= 0) && (GetWindowLong(h, -16) & 0x20) != 0) { found = true; return false; }
                return true; }, IntPtr.Zero);
            return found;
        }
        public static string Title(IntPtr hwnd) { var sb = new StringBuilder(260); GetWindowTextW(hwnd, sb, 260); return sb.ToString(); }
        public static byte[] Capture(IntPtr hwnd, int maxWidth, int maxHeight) {
            RECT r; if (!GetWindowRect(hwnd, out r)) return null;
            int w = r.Right - r.Left, h = r.Bottom - r.Top; if (w < 1 || h < 1 || w > maxWidth || h > maxHeight) return null;
            using (var bmp = new System.Drawing.Bitmap(w, h, System.Drawing.Imaging.PixelFormat.Format24bppRgb)) {
                using (var g = System.Drawing.Graphics.FromImage(bmp)) { IntPtr dc = g.GetHdc(); bool ok; try { ok = PrintWindow(hwnd, dc, 2); } finally { g.ReleaseHdc(dc); } if (!ok) return null; }
                using (var ms = new System.IO.MemoryStream()) { bmp.Save(ms, System.Drawing.Imaging.ImageFormat.Png); return ms.ToArray(); }
            }
        }
    }
}
"@
}

function New-AVDTuneRecordingAdapter {
    <# The real adapter. NOT exercised by the checks beyond construction: written from the documentation, to be tried on a throw-away VM. #>
    $a = [ordered]@{ Kind = 'Real' }
    $a.Snapshot = {
        param($Limits)
        $s = @{ Programs = @{}; Files = @{}; Registry = @{}; Services = @{}; Shortcuts = @{}; Truncated = @() }
        foreach ($u in 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall') {
            $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
            try { $k = $base.OpenSubKey($u, $false); if ($k) { try { foreach ($n in $k.GetSubKeyNames()) { $p = Read-AVDTuneRecordingProgram "HKLM:\$u\$n"; if ($p) { $s.Programs[(Remove-AVDTuneControlCharacters "HKLM:\$u\$n" 300)] = $p } } } finally { $k.Dispose() } } } finally { $base.Dispose() }
        }
        $pd = Get-AVDTuneSystemFolder ProgramData
        $exclude = @((Get-AVDTuneRoot), "$pd\Microsoft\Windows Defender", "$pd\Microsoft\Windows\WER", "$pd\Microsoft\Diagnosis", "$pd\Microsoft\Search", "$pd\Microsoft\Windows\AppRepository", "$pd\USOShared", "$pd\USOPrivate", "$pd\Microsoft\Network\Downloader")
        $t = Get-AVDTuneRecordingFileTree -Roots @((Get-AVDTuneSystemFolder ProgramFiles), (Get-AVDTuneSystemFolder ProgramFilesX86), $pd, [Environment]::GetFolderPath('CommonDesktopDirectory')) -Exclude $exclude -Limit $Limits.Files -Depth $Limits.Depth
        $s.Files = $t.Map; if ($t.Truncated) { $s.Truncated += 'Files' }
        $cut = Get-AVDTuneRecordingRegistryTree -Path 'SOFTWARE' -Limit $Limits.RegistryKeys -Depth $Limits.RegistryDepth -Skip @('SOFTWARE\Classes', 'SOFTWARE\WOW6432Node\Classes') -Map $s.Registry
        if ($cut) { $s.Truncated += 'Registry' }
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
        try {
            $k = $base.OpenSubKey('SYSTEM\CurrentControlSet\Services', $false)
            try { foreach ($n in $k.GetSubKeyNames()) { $sk = $k.OpenSubKey($n, $false); if (-not $sk) { continue }; try { $img = $sk.GetValue('ImagePath', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames); if ($img) { $s.Services[(Remove-AVDTuneControlCharacters $n 200)] = "Start=$($sk.GetValue('Start', ''));Type=$($sk.GetValue('Type', ''));ImagePath=$(Remove-AVDTuneControlCharacters ([string]$img) 300)" } } finally { $sk.Dispose() } } }
            finally { $k.Dispose() }
        }
        finally { $base.Dispose() }
        $lt = Get-AVDTuneRecordingFileTree -Roots @([Environment]::GetFolderPath('CommonDesktopDirectory'), [Environment]::GetFolderPath('CommonPrograms')) -Exclude @() -Limit ($Limits.Shortcuts * 4) -Depth 4
        $shell = New-Object -ComObject WScript.Shell
        try {
            foreach ($p in @($lt.Map.Keys | Where-Object { $_ -match '(?i)\.lnk\z' -and $lt.Map[$_] -like 'f|*' } | Select-Object -First $Limits.Shortcuts)) {
                # a shortcut in a folder (or a file) of another owner is listed by its name only, never opened (review #87)
                $own = @(foreach ($x in @((Split-Path $p -Parent), $p)) { try { (Get-Acl -LiteralPath $x -ErrorAction Stop).GetOwner([Security.Principal.SecurityIdentifier]).Value } catch { '' } })
                if ((Get-AVDTuneRecordingShortcutMode -Owners $own) -ne 'Parse') { $s.Shortcuts[$p] = "(not opened: owner $(($own | Select-Object -Unique) -join ', '))"; continue }
                $l = $shell.CreateShortcut($p); $s.Shortcuts[$p] = Remove-AVDTuneControlCharacters ("$($l.TargetPath) $($l.Arguments)".Trim()) 400; [void][Runtime.InteropServices.Marshal]::ReleaseComObject($l)
            }
        }
        finally { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
        if ($lt.Truncated -or $s.Shortcuts.Count -ge $Limits.Shortcuts) { $s.Truncated += 'Shortcuts' }
        # #93: scheduled tasks, firewall rules, ODBC data sources, machine environment, hosts entries, fonts. Read only, bounded; an area that cannot be read is named as cut.
        foreach ($area in 'Tasks', 'Firewall', 'Odbc', 'Environment', 'Hosts', 'Fonts') {
            try { $got = Get-AVDTuneRecordingSystemArea -Area $area -Limit ([int]$Limits[$area]); $s[$area] = $got.Map; if ($got.Truncated) { $s.Truncated += $area } }
            catch { $s[$area] = @{}; $s.Truncated += $area }
        }
        $s
    }
    $a.Stage = {
        # A copy of the checked cache file in a new download folder (<root>\temp\rec-<guid>, admin-only), under its library name, made with CreateNew and an admin-only ACL
        param($Cached, $Name, $Sha256, $Root)
        $dir = New-AVDTuneDownloadFolder -Root $Root -Prefix 'rec'
        $dest = Join-Path $dir $Name
        $in = [IO.File]::Open($Cached, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try { $out = New-AVDTuneAdminFile -Path $dest; try { $in.CopyTo($out); $out.Flush($true) } finally { $out.Dispose() } } finally { $in.Dispose() }
        $temp = Join-Path $dir 'tmp'; New-AVDTuneOwnFolder -Path $temp   # the own TEMP of this recording (review #87), removed with the download folder
        @{ Path = $dest; Folder = $dir; TempDir = $temp }
    }
    $a.Hold = {
        # Held open with read sharing only until Release (no swap between the check and the end of the run); the hash through that handle, then the signature
        param($Path, $Sha256)
        $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            if ((Get-AVDTuneStreamHash $fs) -ne $Sha256) { throw 'The installer does not match its pinned SHA256: not started.' }
            $sig = Get-AuthenticodeSignature -LiteralPath $Path
            @{ Stream = $fs; Signature = @{ Status = [string]$sig.Status; Subject = $(if ($sig.SignerCertificate) { [string]$sig.SignerCertificate.Subject } else { '' }) } }
        }
        catch { $fs.Dispose(); throw }
    }
    $a.Release = { param($Hold) if ($Hold -and $Hold.Stream) { $Hold.Stream.Dispose() } }
    $a.Install = {
        # Inside the lock Global\PackTune: an .msi through the checked msiexec of System32, an .exe with its full path through the central start (job object, timeout, whole tree)
        # with a clean environment (profile apps: a profile for installers with windows) and TEMP/TMP in the own folder of this recording (review #87)
        param($Path, $Command, $TimeoutSeconds, $TempDir)
        $u = New-AVDTuneUpdateAdapter
        if ($Command.Tool -eq 'msiexec.exe') {
            $r = Invoke-AVDTuneSoftwareTool -U $u -Tool 'msiexec.exe' -Arguments $Command.Arguments -TimeoutSeconds $TimeoutSeconds
            if (-not $r.Ok) { throw $r.Error }
            return [pscustomobject]@{ ExitCode = [int]$r.ExitCode; Output = [string]$r.Output }
        }
        if (-not $TempDir) { throw 'The installer has no own TEMP folder: not started.' }
        $line = (@($Command.Arguments | ForEach-Object { ConvertTo-AVDTuneArgument ([string]$_) }) -join ' ')
        $got = Invoke-AVDTuneLocked -U $u -Script { Invoke-AVDTuneChildProcess -FileName $Path -Arguments $line -TimeoutMs ($TimeoutSeconds * 1000) -CleanEnvironment -TempDir $TempDir -Tool apps -WaitForTree }
        if (-not $got.Ok) { throw "Not started: $($got.Error)" }
        [pscustomobject]@{ ExitCode = $(if ($got.Value.TimedOut) { -1 } else { [int]$got.Value.ExitCode }); Output = [string]$got.Value.Output + [string]$got.Value.Error }
    }.GetNewClosure()   # like RunScript of the customizations: a step-like block (called only from the step of Invoke-AVDTuneRecording, under its marker); only exported functions inside (#78)
    $a.Unstage = { param($Folder) if ($Folder -and (Test-Path -LiteralPath $Folder)) { [void](Remove-AVDTuneTreeSafe -Path $Folder) } }
    $a.StartCapture = {
        # Step images (#93): a worker (New-AVDTunePowerShell) looks every StepIntervalMs at the windows of the processes this AVDTune process started (the installer and
        # its children; never AVDTune's own windows) and writes each new picture of a window into a new admin-only download folder (<root>\temp\shots-<guid>).
        param($Root, $Limits, $Progress)
        Initialize-AVDTuneRecordingCapture
        $dir = New-AVDTuneDownloadFolder -Root $Root -Prefix 'shots'
        $sync = [hashtable]::Synchronized(@{ Stop = $false; Shots = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList)); Error = ''; Skipped = 0; Progress = $Progress })
        $ps = New-AVDTunePowerShell
        [void]$ps.AddScript($script:CaptureLoop).AddArgument((Join-Path $PSScriptRoot 'AVDTune.psm1')).AddArgument($sync).AddArgument($dir).AddArgument([int]$PID).AddArgument([int]$Limits.StepImages).AddArgument([int]$Limits.StepImageBytes).AddArgument([int]$Limits.StepIntervalMs)
        @{ Folder = $dir; Sync = $sync; PS = $ps; Handle = $ps.BeginInvoke() }
    }
    $a.StopCapture = {
        # Ends the worker (it sees Stop within one interval; after 15 seconds it is stopped) and returns what it wrote: Shots (Path, Title, At, Process) and a Note
        param($Capture)
        $Capture.Sync.Stop = $true
        try { if (-not $Capture.Handle.AsyncWaitHandle.WaitOne(15000)) { $Capture.PS.Stop() } } finally { $Capture.PS.Dispose() }
        $note = @(); if ($Capture.Sync.Skipped) { $note += "$($Capture.Sync.Skipped) look(s) at a window with a password field were not captured." }
        if ($Capture.Sync.Error) { $note += "The capture reported: $($Capture.Sync.Error)" }
        @{ Shots = @($Capture.Sync.Shots.ToArray()); Note = ($note -join ' ') }
    }
    $a.ReadProgram = { param($Key) Read-AVDTuneRecordingProgram $Key }
    $a.FileExists = { param($Path) $f = New-Object IO.FileInfo $Path; $f.Exists -and ($f.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0 }
    [pscustomobject]$a
}

#endregion

Export-ModuleMember -Function Get-AVDTuneRecordingProp, Test-AVDTuneRecordingArguments, Protect-AVDTuneRecordingSnapshot, Get-AVDTuneRecordingShortcutMode, Remove-AVDTuneRecordingSecrets, ConvertTo-AVDTuneRecordingApp, Split-AVDTuneRecordingArguments, Get-AVDTuneRecordingCommand, Test-AVDTuneRecordingSignature,
    Get-AVDTuneRecordingLimits, Get-AVDTuneRecordingValueText, Compare-AVDTuneRecordingSnapshot, Get-AVDTuneRecordingProposal, ConvertTo-AVDTuneRecordingHtml,
    Get-AVDTuneRecordingRoot, New-AVDTuneRecordingFolder, Save-AVDTuneRecordingRecord, ConvertFrom-AVDTuneRecordingRecord, Get-AVDTuneRecordedApps, Get-AVDTuneRecordingStatus,
    Get-AVDTuneRecordingAreas, Get-AVDTuneRecordingLongValue, ConvertFrom-AVDTuneRecordingHosts, ConvertFrom-AVDTuneRecordingTaskXml, ConvertTo-AVDTuneRecordingNotes, Add-AVDTuneRecordingNote,
    Close-AVDTuneRecordingNotes, ConvertTo-AVDTuneRecordingSteps, Select-AVDTuneRecordingProcessTree, Test-AVDTuneRecordingPng, Import-AVDTuneRecordingSteps, Get-AVDTuneRecordingRecipe,
    Get-AVDTuneRecordingRegistryValues, Get-AVDTuneRecordingSystemArea, Initialize-AVDTuneRecordingCapture,
    Invoke-AVDTuneRecording, Get-AVDTuneRecordingFileTree, Get-AVDTuneRecordingRegistryTree, Read-AVDTuneRecordingProgram, New-AVDTuneRecordingAdapter
