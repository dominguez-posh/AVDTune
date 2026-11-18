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
      * Not in this stage (plan 3e, later issues): step screenshots with UI Automation, the notes window, process recording, PDF, SharePoint upload, watched source,
        "Neu installieren" from the recipe.
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
$script:DefaultLimits = @{ Files = 200000; Depth = 8; RegistryKeys = 150000; RegistryDepth = 5; Shortcuts = 3000; ListPerArea = 2000 }
$script:Areas = @('Programs', 'Files', 'Registry', 'Services', 'Shortcuts')
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
        @('\b[A-Za-z0-9]{4,8}(-[A-Za-z0-9]{4,8}){3,}\b', '(key removed)'),
        @('\b[A-Za-z0-9+/_\-]{32,}={0,2}', '(removed)')
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
    param([Parameter(Mandatory)]$Raw, [switch]$FromForm, [object[]]$Library)
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
    if ($a.TimeoutSeconds -lt 60 -or $a.TimeoutSeconds -gt 14400) { [void]$errors.Add('Timeout: 60 to 14400 seconds.') }
    [pscustomobject]@{ Valid = ($errors.Count -eq 0); Errors = @($errors); App = [pscustomobject]$a; Cleaned = $cleaned }
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
    [void]$sb.Append("<!doctype html><html><head><meta charset=""utf-8""><meta http-equiv=""Content-Security-Policy"" content=""default-src 'none'; style-src 'unsafe-inline'""><title>$(& $e $a.Name) $(& $e $a.Version)</title>")
    [void]$sb.Append('<style>body{font-family:Segoe UI,sans-serif;margin:24px;max-width:1100px}td,th{text-align:left;padding:2px 8px;vertical-align:top}table{border-collapse:collapse}tr:nth-child(even){background:#f3f3f3}code{word-break:break-all}</style></head><body>')
    [void]$sb.Append("<h1>$(& $e $a.Name) $(& $e $a.Version)</h1><table>")
    $rows = @(@('Vendor', $a.Vendor), @('Kind', $Record.Kind), @('Result', $Record.Result), @('Exit code', $Record.ExitCode), @('Installer', "$($a.Installer) (SHA256 $($a.Sha256))"), @('Signature', $Record.Signature),
        @('Arguments', $a.Arguments), @('Started', $Record.Started), @('Ended', $Record.Ended), @('Administrator', $Record.User), @('Image version', $Record.ImageVersion), @('Contact or ticket', $a.Contact),
        @('Dependencies', $a.Dependencies), @('Licence notes', $a.LicenseNotes),
        @('Detection', $(if ($Record.Detection) { "$($Record.Detection.Kind): $($Record.Detection.Key) $($Record.Detection.Version)" } else { 'none found' })), @('Silent install', $Record.Silent), @('Uninstall', $Record.Uninstall),
        @('Cut areas', (@($Record.Changes.Truncated) -join ', ')))
    foreach ($r in $rows) { [void]$sb.Append("<tr><th>$(& $e $r[0])</th><td>$(& $e $r[1])</td></tr>") }
    [void]$sb.Append('</table>')
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

function Save-AVDTuneRecordingRecord {
    # Writes record.json and documentation.html of a new recording number of the app. Returns the folder.
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)]$Record)
    if ([string]$Record.AppId -cnotmatch '\A[0-9a-f]{12}\z' -or $Record.Number -isnot [int] -or $Record.Number -lt 1 -or $Record.Number -gt 999) { throw 'The recording has no valid app id or number.' }
    $dir = New-AVDTuneRecordingFolder -Root $Root -Parts @($Record.AppId, $Record.Number.ToString('000'))
    if (Test-Path -LiteralPath (Join-Path $dir 'record.json')) { throw "$dir holds a recording already: not overwritten." }
    Write-AVDTuneFile (Join-Path $dir 'documentation.html') (ConvertTo-AVDTuneRecordingHtml -Record $Record)
    Write-AVDTuneFile (Join-Path $dir 'record.json') ($Record | ConvertTo-Json -Depth 8)
    $dir
}

function ConvertFrom-AVDTuneRecordingRecord {
    # Typed reading of one record.json: Schema 1, the app validated again, numbers exact. Returns the record or throws with the reason.
    param([Parameter(Mandatory)]$Json, [Parameter(Mandatory)][string]$AppId, [Parameter(Mandatory)][int]$Number)
    if ((Get-AVDTuneProp $Json 'Schema') -ne 1) { throw 'unknown schema' }
    if ([string](Get-AVDTuneProp $Json 'AppId') -cne $AppId -or (Get-AVDTuneProp $Json 'Number') -ne $Number -or (Get-AVDTuneProp $Json 'Number') -isnot [int]) { throw 'id or number does not match its folder' }
    $app = ConvertTo-AVDTuneRecordingApp -Raw (Get-AVDTuneProp $Json 'App')
    if (-not $app.Valid) { throw ($app.Errors -join ' ') }
    if ($app.App.Id -cne $AppId) { throw 'the app id does not match' }
    $kind = Get-AVDTuneProp $Json 'Kind'; if ($kind -cnotin 'Install', 'Update') { throw 'unknown kind' }
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
        Signature = Remove-AVDTuneControlCharacters ([string](Get-AVDTuneProp $Json 'Signature')) 400; Counts = Get-AVDTuneProp $Json 'Counts' }
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
        [ValidateSet('Install', 'Update')][string]$Kind = 'Install', [string]$User, [string]$SnapshotId, [hashtable]$Limits, $Progress)
    if (-not (Test-AVDTuneWriteAllowed)) { throw 'The snapshot gate is not confirmed: nothing is installed or recorded.' }
    $chk = ConvertTo-AVDTuneRecordingApp -Raw $App
    if (-not $chk.Valid) { throw "Not recorded: $($chk.Errors -join ' ')" }
    $a = $chk.App
    $known = @((Get-AVDTuneRecordedApps -Root $Root).Apps | Where-Object { $_.Id -eq $a.Id })
    if ($Kind -eq 'Update' -and -not $known.Count) { throw 'An update needs an app that has been recorded before.' }
    if ($Kind -eq 'Install' -and $known.Count) { throw 'This app has been recorded before: record an update instead.' }
    $number = if ($known.Count) { [int]$known[0].Versions[0].Number + 1 } else { 1 }
    $lim = Get-AVDTuneRecordingLimits; if ($Limits) { foreach ($k in $Limits.Keys) { $lim[$k] = $Limits[$k] } }
    $say = { param($t) if ($Progress) { $Progress.Text = $t } }
    $owner = Start-AVDTuneChange -Root $Root
    try {
        & $say 'snapshot'
        $before = & $R.Snapshot $lim
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
                    $res = & $rr.Install $st.Path (Get-AVDTuneRecordingCommand -App $a -Path $st.Path) $a.TimeoutSeconds
                }
                finally { & $rr.Release $hold }
                $state.ExitCode = [int]$res.ExitCode; $state.Output = Remove-AVDTuneControlCharacters ([string]$res.Output) 2000
                if ($state.ExitCode -eq -1) { throw "The installer did not end within $($a.TimeoutSeconds) seconds: it was ended with its whole process tree." }
                if ($state.ExitCode -notin 0, 3010, 1641) { throw "The installer ended with exit code $($state.ExitCode)." }
                $state.Done = $true
            }
            finally { & $rr.Unstage $st.Folder }
        }.GetNewClosure()
        $title = "$(if ($Kind -eq 'Update') { 'Update' } else { 'Install' }) $($a.Name) $($a.Version) ($($a.Installer), SHA256 $($a.Sha256.Substring(0, 12)))"
        $step = New-AVDTuneStep -Id "software.custom-$($a.Id)" -Section Software -Title $title -Why 'Own software of the customer, installed and recorded (Software page, custom software).' -Risk High -Test $test -Apply $apply
        $started = (& $Machine.Now).ToString('o')
        & $say 'install'
        $run = Invoke-AVDTune -Plan ([pscustomobject]@{ Name = "Custom software $($a.Name)"; Steps = @($step.Id) }) -Catalog @($step) -Machine $Machine -Root $Root -User $User -SnapshotId $SnapshotId
        & $say 'compare'
        $after = & $R.Snapshot $lim
        $changes = Compare-AVDTuneRecordingSnapshot -Before $before -After $after -Max ([int]$lim.ListPerArea)
        $prop = Get-AVDTuneRecordingProposal -App $a -Changes $changes
        $res0 = @($run.Results)[0]
        $counts = [ordered]@{}; foreach ($ar in $script:Areas) { $counts[$ar] = $changes.$ar.Counts }
        $record = [pscustomobject][ordered]@{
            Schema = 1; AppId = $a.Id; Number = $number; Kind = $Kind; App = $a; Result = $(if ($res0.Status -eq 'Changed') { 'Changed' } else { 'Failed' }); Message = Remove-AVDTuneControlCharacters ([string]$res0.Message) 500
            ExitCode = $state.ExitCode; Signature = $state.Signature; Output = $state.Output; Started = $started; Ended = (& $Machine.Now).ToString('o'); User = $User; ImageVersion = (Get-AVDTuneState $Root).ImageVersion; RunId = $run.Id
            Detection = $prop.Detection; Silent = $prop.Silent; Uninstall = $prop.Uninstall; Counts = [pscustomobject]$counts; Changes = $changes
        }
        $folder = Save-AVDTuneRecordingRecord -Root $Root -Record $record
        [pscustomobject]@{ Run = $run; Record = $record; Folder = $folder }
    }
    finally { Stop-AVDTuneChange -Root $Root -Owner $owner }
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
                $l = $shell.CreateShortcut($p); $s.Shortcuts[$p] = Remove-AVDTuneControlCharacters ("$($l.TargetPath) $($l.Arguments)".Trim()) 400; [void][Runtime.InteropServices.Marshal]::ReleaseComObject($l)
            }
        }
        finally { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
        if ($lt.Truncated -or $s.Shortcuts.Count -ge $Limits.Shortcuts) { $s.Truncated += 'Shortcuts' }
        $s
    }
    $a.Stage = {
        # A copy of the checked cache file in a new download folder (<root>\temp\rec-<guid>, admin-only), under its library name, made with CreateNew and an admin-only ACL
        param($Cached, $Name, $Sha256, $Root)
        $dir = New-AVDTuneDownloadFolder -Root $Root -Prefix 'rec'
        $dest = Join-Path $dir $Name
        $in = [IO.File]::Open($Cached, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try { $out = New-AVDTuneAdminFile -Path $dest; try { $in.CopyTo($out); $out.Flush($true) } finally { $out.Dispose() } } finally { $in.Dispose() }
        @{ Path = $dest; Folder = $dir }
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
        param($Path, $Command, $TimeoutSeconds)
        $u = New-AVDTuneUpdateAdapter
        if ($Command.Tool -eq 'msiexec.exe') {
            $r = Invoke-AVDTuneSoftwareTool -U $u -Tool 'msiexec.exe' -Arguments $Command.Arguments -TimeoutSeconds $TimeoutSeconds
            if (-not $r.Ok) { throw $r.Error }
            return [pscustomobject]@{ ExitCode = [int]$r.ExitCode; Output = [string]$r.Output }
        }
        $got = Invoke-AVDTuneLocked -U $u -Script { Invoke-AVDTuneProgram -File $Path -Arguments $Command.Arguments -TimeoutSeconds $TimeoutSeconds -WaitForTree }
        if (-not $got.Ok) { throw "Not started: $($got.Error)" }
        [pscustomobject]@{ ExitCode = [int]$got.Value.ExitCode; Output = [string]$got.Value.Output }
    }.GetNewClosure()   # like RunScript of the customizations: a step-like block (called only from the step of Invoke-AVDTuneRecording, under its marker); only exported functions inside (#78)
    $a.Unstage = { param($Folder) if ($Folder -and (Test-Path -LiteralPath $Folder)) { [void](Remove-AVDTuneTreeSafe -Path $Folder) } }
    $a.ReadProgram = { param($Key) Read-AVDTuneRecordingProgram $Key }
    $a.FileExists = { param($Path) $f = New-Object IO.FileInfo $Path; $f.Exists -and ($f.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0 }
    [pscustomobject]$a
}

#endregion

Export-ModuleMember -Function Get-AVDTuneRecordingProp, Remove-AVDTuneRecordingSecrets, ConvertTo-AVDTuneRecordingApp, Split-AVDTuneRecordingArguments, Get-AVDTuneRecordingCommand, Test-AVDTuneRecordingSignature,
    Get-AVDTuneRecordingLimits, Get-AVDTuneRecordingValueText, Compare-AVDTuneRecordingSnapshot, Get-AVDTuneRecordingProposal, ConvertTo-AVDTuneRecordingHtml,
    Get-AVDTuneRecordingRoot, New-AVDTuneRecordingFolder, Save-AVDTuneRecordingRecord, ConvertFrom-AVDTuneRecordingRecord, Get-AVDTuneRecordedApps, Get-AVDTuneRecordingStatus,
    Invoke-AVDTuneRecording, Get-AVDTuneRecordingFileTree, Get-AVDTuneRecordingRegistryTree, Read-AVDTuneRecordingProgram, New-AVDTuneRecordingAdapter
