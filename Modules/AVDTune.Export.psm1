<#
    AVDTune export (docs\plans\avdtune.md phase 7 "export", section 1b "environment.json holds the answers and resource IDs, never secrets", issue #91):
    one ZIP with what an administrator hands over or keeps outside the master:
      * environment.html          the environment document (the same one the SharePoint card makes, AVDTune.SharePoint)
      * settings\environment.json the answers of the environment (environment.json), without anything that sounds or looks like a secret
      * settings\customizations.json, settings\printers.json, settings\masking.json   the saved customizations, printer drivers and App Masking rules
      * changelog\changelog.json and changelog\<version>.md   the change log (every version)
      * benchmark\comparison.csv / .json   the benchmark comparison per image version (when there is one)
      * README.txt                what is in it and what is left out
    Every file passes the one secret table of AVDTune.SharePoint (Invoke-AVDTuneSpSecretRules / Test-AVDTuneSpSecretFree): JSON values whose name sounds secret
    are not taken at all, every text value is filtered, and a file in which the table still finds something is left out (named in Skipped and in README.txt).
    The ZIP is built in memory, written to a new temp file next to the target (CreateNew) and moved over it in one step; no part of the target path may be a
    link (junction, symbolic link). The default folder is <state>\exports (AVDTune's own admin-only folder).
    Read only for the master: nothing of the state is changed. Importing an export is not part of the plan (only the benchmark result file of 6b is imported).
#>

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'AVDTune.psm1')
Import-Module (Join-Path $PSScriptRoot 'AVDTune.SharePoint.psm1')
Import-Module (Join-Path $PSScriptRoot 'AVDTune.Updates.psm1')   # Test-AVDTuneAdminOnlyPath for the target folder

$script:SecretName = '(?i)key|secret|password|passwort|kennwort|token|sas|credential|refresh|cert|pfx|connectionstring'
# A name/value pair (registry value, ini key, own steps of the customizations): its value is left out when the name ENDS like a secret, also inside a word
# (DefaultPassword, ApiPassword, ClientSecret; Finn's review of #91, M1). Names checked: ValueName, Key, IniKey, the last part of Path, Name when the object has a Value.
$script:SecretPairName = '(?i)(password|passwort|kennwort|pwd|secret|token|apikey|key|credential|credentials)\z'
$script:PairValueNames = @('Value', 'Data', 'Values')
$script:EntryNamePattern = '\A[A-Za-z0-9][A-Za-z0-9._-]{0,79}(/[A-Za-z0-9][A-Za-z0-9._-]{0,79}){0,3}\z'
$script:MaxEntry = 8MB
$script:MaxDepth = 8
$script:ConfigFiles = @(@('customizations.json', 'Customizations'), @('printers.json', 'Printers'), @('masking.json', 'App Masking'))

function ConvertTo-AVDTuneExportValue {
    <#
        Pure. A copy of parsed JSON for the export: a property whose name sounds secret (key, secret, password, token, SAS, credential, certificate ...) is left
        out (its name with a placeholder would be found by the table again), every string passes the secret table, numbers and booleans stay, nesting deeper than 8 levels becomes "(not shown: too deep)".
    #>
    param($Value, [int]$Depth = 0)
    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) { $t = Invoke-AVDTuneSpSecretRules $Value; if ($null -eq $t) { return '(removed)' }; return $t }
    if ($Value -is [ValueType]) { return $Value }
    if ($Depth -ge $script:MaxDepth) { return '(not shown: too deep)' }
    if ($Value -is [System.Collections.IDictionary] -or $Value -is [Management.Automation.PSCustomObject]) {
        $o = [ordered]@{}
        $props = if ($Value -is [System.Collections.IDictionary]) { @($Value.Keys | ForEach-Object { @{ Name = [string]$_; Value = $Value[$_] } }) } else { @($Value.PSObject.Properties | Where-Object { $_.MemberType -eq 'NoteProperty' } | ForEach-Object { @{ Name = $_.Name; Value = $_.Value } }) }
        $hasValue = @($props | Where-Object { $_.Name -in $script:PairValueNames }).Count -gt 0
        $pairSecret = $false
        if ($hasValue) {
            foreach ($p in $props) {
                $n = $null
                if ($p.Name -in 'ValueName', 'Key', 'IniKey', 'Name') { $n = [string]$p.Value }
                elseif ($p.Name -eq 'Path') { $n = ([string]$p.Value).TrimEnd([char]92, [char]47); $i = $n.LastIndexOfAny([char[]]@([char]92, [char]47)); if ($i -ge 0) { $n = $n.Substring($i + 1) } }
                if ($n -and $n.Length -le 300 -and $n -match $script:SecretPairName) { $pairSecret = $true }
            }
        }
        foreach ($p in $props) {
            if ($p.Name -match $script:SecretName) { continue }
            if ($pairSecret -and $p.Name -in $script:PairValueNames) { continue }
            $o[$p.Name] = ConvertTo-AVDTuneExportValue -Value $p.Value -Depth ($Depth + 1)
        }
        return $o
    }
    if ($Value -is [System.Collections.IEnumerable]) { return ,@(foreach ($i in $Value) { ConvertTo-AVDTuneExportValue -Value $i -Depth ($Depth + 1) }) }
    '(not shown)'
}

function ConvertTo-AVDTuneExportJson($Object) { (ConvertTo-AVDTuneExportValue -Value $Object) | ConvertTo-Json -Depth 12 }

function Get-AVDTuneExportEntries {
    <#
        Read only: the files of the export as Name (path inside the ZIP) and Text, plus Skipped (what was left out and why). -Machine for the Windows version of the
        document, -Recorded (Get-AVDTuneRecordedApps().Apps) for the custom software, -Comparison (Get-AVDTuneBenchmarkVersionComparison) and -ComparisonCsv /
        -ComparisonJson (its text, AVDTune.Benchmark) for the benchmark. A file that cannot be read is named in Skipped; nothing is asked from the network.
    #>
    param([string]$Root = (Get-AVDTuneRoot), $Machine, $Recorded, $Comparison, [string]$ComparisonCsv, [string]$ComparisonJson, [string]$Computer, [datetime]$Now = (Get-Date))
    $entries = New-Object System.Collections.ArrayList
    $skipped = New-Object System.Collections.ArrayList
    $add = { param($name, $text) [void]$entries.Add([pscustomobject]@{ Name = $name; Text = [string]$text; Json = ($name -like '*.json') }) }
    $state = Get-AVDTuneState $Root
    $version = [string](Get-AVDTuneProp $state 'ImageVersion')
    # the environment document
    try {
        $rows = @(); if ($Comparison) { $rows = @($Comparison.Rows) }
        $data = Get-AVDTuneEnvironmentDocumentData -Root $Root -Machine $Machine -Recorded $Recorded -Benchmark $rows -Computer $Computer
        & $add 'environment.html' (ConvertTo-AVDTuneEnvironmentDocument -Data $data)
    }
    catch { [void]$skipped.Add("environment.html: $($_.Exception.Message)") }
    # the settings: environment.json and the saved configurations
    $sources = @(, @('environment.json', 'settings/environment.json', 'Environment')) + @($script:ConfigFiles | ForEach-Object { , @("config\$($_[0])", "settings/$($_[0])", $_[1]) })
    foreach ($src in $sources) {
        $path = Join-Path $Root $src[0]
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        try {
            if ((Get-Item -LiteralPath $path).Length -gt $script:MaxEntry) { throw 'larger than 8 MB' }
            & $add $src[1] (ConvertTo-AVDTuneExportJson (Read-AVDTuneJson $path))
        }
        catch { [void]$skipped.Add("$($src[1]): $($src[2]) could not be read ($($_.Exception.Message))") }
    }
    # the change log: all entries as JSON, every version as Markdown
    try {
        $log = @(Get-AVDTuneChangeLog -Root $Root)
        & $add 'changelog/changelog.json' (ConvertTo-AVDTuneExportJson ([ordered]@{ Exported = $Now.ToString('o'); Entries = @($log) }))
        foreach ($v in @(Get-AVDTuneChangeLogVersions -Root $Root | Select-Object -First 100)) {
            if (-not (Test-AVDTuneImageVersion $v)) { continue }
            & $add "changelog/$v.md" (ConvertTo-AVDTuneChangeLogDocument -Root $Root -Version $v -Format Markdown -ImageName $Computer)
        }
    }
    catch { [void]$skipped.Add("changelog: $($_.Exception.Message)") }
    # the benchmark comparison
    if ($ComparisonCsv) { & $add 'benchmark/comparison.csv' $ComparisonCsv }
    if ($ComparisonJson) { & $add 'benchmark/comparison.json' $ComparisonJson }
    # every file through the secret table; what still looks like a secret afterwards stays out. JSON was filtered value by value above and is only checked here
    # (a replacement in the whole text could break its syntax): when the table still finds something in it, the file stays out.
    $safe = New-Object System.Collections.ArrayList
    foreach ($e in $entries) {
        $t = if ($e.Json) { $e.Text } else { Invoke-AVDTuneSpSecretRules $e.Text }
        if ($null -eq $t -or -not (Test-AVDTuneSpSecretFree $t)) { [void]$skipped.Add("$($e.Name): it holds something that looks like a password, key or token") ; continue }
        [void]$safe.Add([pscustomobject]@{ Name = $e.Name; Text = $t; Filtered = ($t -cne $e.Text) })
    }
    $readme = @(
        "AVDTune export $(Protect-AVDTuneSpText $Computer 80) $version".Trim()
        "Created $($Now.ToString('yyyy-MM-dd HH:mm')) by AVDTune $((Get-AVDTuneExportToolVersion))."
        ''
        'Files:'
    ) + @($safe | ForEach-Object { "  $($_.Name)$(if ($_.Filtered) { '  (values that could be secrets removed)' })" }) + @(
        ''
        'What is filtered: in the JSON files every property whose name sounds secret (key, secret, password, token, SAS, credential, certificate), and the value of'
        'a registry value, ini key or other name/value pair whose name ends like one (e.g. DefaultPassword, ApiPassword), are left out; every text passes the'
        'secret patterns of AVDTune (tokens, keys, SAS, name=value passwords). Patterns cannot find every secret: check the files before you pass them on.'
        'The export names Azure resources, the domain, print servers and user names: keep it where only administrators can read it.'
    ) + $(if ($skipped.Count) { @('', 'Left out:') + @($skipped | ForEach-Object { "  $_" }) } else { @() })
    [void]$safe.Insert(0, [pscustomobject]@{ Name = 'README.txt'; Text = (Protect-AVDTuneSpText ($readme -join "`r`n") 20000); Filtered = $false })
    [pscustomobject]@{ Entries = @($safe); Skipped = @($skipped); Version = $version }
}

function Get-AVDTuneExportToolVersion { try { $vf = Join-Path (Split-Path $PSScriptRoot -Parent) 'VERSION'; if (Test-Path -LiteralPath $vf) { return ([IO.File]::ReadAllText($vf)).Trim() } } catch { }; '' }

function Assert-AVDTuneExportPath {
    <# The target of an export: a full path ending .zip, its folder exists, no part of the path (from the drive root down, the file too) is a link. Returns the full path. #>
    param([Parameter(Mandatory)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    if ($full -notmatch '(?i)\.zip\z') { throw 'The export is a .zip file.' }
    if ($full.StartsWith('\\')) { throw 'The export is written to a local folder, not to a network path.' }
    # a mapped network drive (Z:) is no local folder either (Finn, #91 N1)
    $drive = $null; try { $drive = New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($full)) } catch { }
    if (-not $drive -or ($drive.DriveType -ne [IO.DriveType]::Fixed -and $drive.DriveType -ne [IO.DriveType]::Removable)) { throw 'The export is written to a local drive, not to a network drive.' }
    $dir = [IO.Path]::GetDirectoryName($full)
    if (-not $dir -or -not [IO.Directory]::Exists($dir)) { throw "The folder of $full does not exist." }
    if ([IO.Directory]::Exists($full)) { throw "$full is a folder." }
    $c = $dir
    while ($c) {
        if (([IO.File]::GetAttributes($c) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "$c is a link (junction or symbolic link): not exported there." }
        $parent = [IO.Path]::GetDirectoryName($c); if ($parent -eq $c) { break }; $c = $parent
    }
    if ([IO.File]::Exists($full) -and ([IO.File]::GetAttributes($full) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "$full is a link: not overwritten." }
    $full
}

function Get-AVDTuneExportFolder {
    # <state>\exports, created as AVDTune's own admin-only folder when missing; a link there is refused
    param([string]$Root = (Get-AVDTuneRoot))
    $dir = Join-Path $Root 'exports'
    $d = New-Object IO.DirectoryInfo $dir
    if ($d.Exists -and ($d.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "$dir is a link: not used." }
    if (-not $d.Exists) { New-AVDTuneOwnFolder -Path $dir }
    $dir
}

function Get-AVDTuneExportFileName {
    # avdtune-export-<version>-<yyyyMMdd-HHmm>.zip
    param([string]$Version, [datetime]$Now = (Get-Date))
    $v = if (Test-AVDTuneImageVersion $Version) { $Version } else { 'none' }
    "avdtune-export-$v-$($Now.ToString('yyyyMMdd-HHmm', [Globalization.CultureInfo]::InvariantCulture)).zip"
}

function Export-AVDTuneBundle {
    <#
        Writes the entries (Get-AVDTuneExportEntries) as one ZIP to -Path: names checked, at most 8 MB per file, built in memory, written to a new temp file next to
        the target (CreateNew, no sharing) and moved over the target in one step (a crash leaves the old or the new file). Returns Path, Files, Size, Sha256.
    #>
    param([Parameter(Mandatory)]$Export, [Parameter(Mandatory)][string]$Path, [datetime]$Now = (Get-Date))
    Add-Type -AssemblyName System.IO.Compression
    $full = Assert-AVDTuneExportPath -Path $Path
    $utf8 = New-Object Text.UTF8Encoding $false
    $names = @{}
    $ms = New-Object IO.MemoryStream
    try {
        $zip = New-Object IO.Compression.ZipArchive($ms, [IO.Compression.ZipArchiveMode]::Create, $true)
        try {
            foreach ($e in @($Export.Entries)) {
                $n = [string]$e.Name
                if ($n -cnotmatch $script:EntryNamePattern -or $n -match '\.\.') { throw "'$n' is not a valid name in the export." }
                if ($names.ContainsKey($n.ToLowerInvariant())) { throw "'$n' is twice in the export." }
                $names[$n.ToLowerInvariant()] = $true
                $bytes = $utf8.GetBytes([string]$e.Text)
                if ($bytes.Length -gt $script:MaxEntry) { throw "'$n' is larger than 8 MB." }
                $z = $zip.CreateEntry($n, [IO.Compression.CompressionLevel]::Optimal)
                $z.LastWriteTime = [DateTimeOffset]$Now
                $s = $z.Open(); try { $s.Write($bytes, 0, $bytes.Length) } finally { $s.Dispose() }
            }
        }
        finally { $zip.Dispose() }
        $data = $ms.ToArray()
    }
    finally { $ms.Dispose() }
    $temp = Join-Path ([IO.Path]::GetDirectoryName($full)) ('.' + [IO.Path]::GetFileName($full) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        # admin-only like Write-AVDTuneFile (#91 N1): the temp file and, moved in one step, the ZIP carry this ACL, not what the folder would give them
        $fs = New-Object IO.FileStream($temp, [IO.FileMode]::CreateNew, [Security.AccessControl.FileSystemRights]'Write, ReadPermissions', [IO.FileShare]::None, 4096, [IO.FileOptions]::None, (New-AVDTuneFileSecurity -AdminOnly))
        try { $fs.Write($data, 0, $data.Length); $fs.Flush($true) } finally { $fs.Dispose() }
        Move-AVDTuneFileReplace $temp $full
    }
    finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
    $sha = New-Object Security.Cryptography.SHA256Managed
    try { $hash = ([BitConverter]::ToString($sha.ComputeHash($data))).Replace('-', '') } finally { $sha.Dispose() }
    # a folder users can change is allowed (the administrator chose it) but named: the caller shows the warning (#91 N1)
    $folderAdminOnly = [bool](Test-AVDTuneAdminOnlyPath -Path ([IO.Path]::GetDirectoryName($full)))
    [pscustomobject]@{ Path = $full; Files = @($Export.Entries).Count; Size = $data.Length; Sha256 = $hash; Skipped = @($Export.Skipped); FolderAdminOnly = $folderAdminOnly }
}

Export-ModuleMember -Function ConvertTo-AVDTuneExportValue, ConvertTo-AVDTuneExportJson, Get-AVDTuneExportEntries, Assert-AVDTuneExportPath, Get-AVDTuneExportFolder, Get-AVDTuneExportFileName, Export-AVDTuneBundle
